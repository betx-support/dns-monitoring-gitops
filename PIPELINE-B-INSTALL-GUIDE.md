# Pipeline B Install Guide — Fresh Cluster

This deploys **only** the daily top-domains analytics pipeline
(collector → Loki → rollup → Postgres → Metabase). Pipeline A
(kube-prometheus-stack) is not part of this guide — it's not being
installed at all, so there's nothing to skip or remove later.

Every fix discovered during the original rollout is already baked into
the file contents referenced below — you're not re-discovering any of
these bugs, just deploying the corrected versions. For the *why* behind
each one, see `dns-monitoring-architecture-and-runbook.md`; this guide is
deliberately just the *what*, in order.

## Final file list for this stack

```
00-namespace.yaml                     # ResourceQuota/LimitRange, right-sized for Pipeline B only
serviceaccount-eso.yaml               # ServiceAccount ESO authenticates to Vault as
vault-secretstore.yaml                # SecretStore
vault-kv-secrets.sh                   # Vault KV writes: postgres-rollup, metabase-admin, pihole-api
vault-kubernetes-auth-role.sh         # Vault k8s-auth role registration (run once)
dns-monitoring-eso-policy.sh          # Vault policy (canonical, all 3 paths)
10-external-secrets-analytics.yaml    # ExternalSecrets: postgres-rollup-credentials, metabase-admin-credentials
15-external-secret-pihole.yaml        # ExternalSecret: pihole-api-credentials
02-networkpolicy.yaml                 # default-deny-ingress + allow-intra-namespace
14-networkpolicy-analytics.yaml       # Metabase ingress + collector egress rules
11-postgres-rollup.yaml               # Postgres StatefulSet + Service + schema ConfigMap
12-domain-collector-cronjob.yaml      # collect.py + rollup.py CronJobs (v6 — all fixes applied)
13-metabase.yaml                      # Metabase Deployment (liveness probe + resource fix applied)
values-loki.yaml                      # Loki Helm values
helm-repo-grafana.yaml                # Helm repo secret for Loki's chart source
dns-monitoring-project.yaml           # AppProject (trimmed — no prometheus-community, no cluster resources)
argocd-application-manifests.yaml     # ArgoCD Application for everything above except values-loki.yaml
argocd-application-loki.yaml          # ArgoCD Application for Loki
03-rbac-optional-native-k8s.yaml      # Optional — native k8s RBAC, not the primary access mechanism
argocd-rbac-policy-snippet.csv        # Lines to append to the existing argocd-rbac-cm ConfigMap
```

**Not part of this stack:** `values.yaml`, `argocd-application-helm.yaml`,
`prometheusrule.yaml`, `helm-repo-prometheus-community.yaml`,
`01-external-secrets.yaml` — these are Pipeline A only.

**Before you begin**, edit these placeholders:
- `12-domain-collector-cronjob.yaml`'s `pihole-branch-hosts` ConfigMap — replace the single `"test": "192.168.3.12"` entry with your real 25 branch name→IP pairs
- `vault-kv-secrets.sh` — every `<generated>`/`<your-real-...>` value
- `13-metabase.yaml` / `14-networkpolicy-analytics.yaml` — confirm `dns-insights.internal.lan` is the hostname you actually want
- `argocd-application-manifests.yaml` / any Application manifest's `repoURL`/`path` — point at your actual GitOps repo layout

---

## Step 1 — Vault (run by hand, never via CI/CD)

```bash
chmod +x vault-kv-secrets.sh vault-kubernetes-auth-role.sh dns-monitoring-eso-policy.sh
./vault-kv-secrets.sh
./vault-kubernetes-auth-role.sh
./dns-monitoring-eso-policy.sh
```

**Verify:**
```bash
kubectl exec -n vault vault-0 -- vault kv list dns-monitoring/
# expect: postgres-rollup, metabase-admin, pihole-api

kubectl exec -n vault vault-0 -- vault policy read dns-monitoring-eso
# expect all three paths listed with ["read"]

kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/dns-monitoring-eso
# expect bound_service_account_names: dns-monitoring-eso,
# bound_service_account_namespaces: dns-monitoring
```

---

## Step 2 — Foundational Kubernetes objects

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f serviceaccount-eso.yaml
kubectl apply -f vault-secretstore.yaml
kubectl apply -f 10-external-secrets-analytics.yaml
kubectl apply -f 15-external-secret-pihole.yaml
```

**Verify — do not proceed until every ExternalSecret is `SYNCED`:**
```bash
kubectl get externalsecret -n dns-monitoring
```
If any show an error condition instead, check
`kubectl describe externalsecret <name> -n dns-monitoring` — a permission
error here almost always means Step 1's policy or role registration
didn't take, not a problem with the ExternalSecret manifest itself.

---

## Step 3 — NetworkPolicies

```bash
kubectl apply -f 02-networkpolicy.yaml
kubectl apply -f 14-networkpolicy-analytics.yaml
```

**Before applying**, confirm your ingress-nginx controller's actual
namespace/label match what `14-networkpolicy-analytics.yaml` expects:
```bash
kubectl get pods -n ingress-nginx --show-labels
```
If it lives elsewhere or uses different labels, edit the
`namespaceSelector`/labels in that file first — this was never actually
confirmed during the original rollout (see the README's original
"still unconfirmed" note) and is exactly the kind of thing that silently
breaks Metabase's ingress path if wrong, with no error message pointing
at the real cause.

**Verify:**
```bash
kubectl get networkpolicy -n dns-monitoring
# expect: default-deny-ingress, allow-intra-namespace,
# allow-ingress-from-nginx-metabase, allow-egress-domain-collector
```

---

## Step 4 — Postgres

```bash
kubectl apply -f 11-postgres-rollup.yaml
```

**Verify — wait for this before continuing, everything downstream
depends on it:**
```bash
kubectl get pod postgres-rollup-0 -n dns-monitoring -w
# wait for 1/1 Running

kubectl exec -n dns-monitoring postgres-rollup-0 -- pg_isready
# expect: accepting connections

kubectl exec -n dns-monitoring postgres-rollup-0 -- \
  psql -U dns_rollup -d dns_rollup -c "\dt"
# expect: top_domains_daily table already created by the init ConfigMap
```

---

## Step 5 — ArgoCD project + RBAC

```bash
kubectl apply -f dns-monitoring-project.yaml
# then append argocd-rbac-policy-snippet.csv's contents into the
# existing argocd-rbac-cm ConfigMap's policy.csv key
```

**Verify:**
```bash
kubectl get appproject dns-monitoring-project -n argocd -o yaml
```

---

## Step 6 — ArgoCD Applications

```bash
kubectl apply -f argocd-application-manifests.yaml
kubectl apply -f argocd-application-loki.yaml
```

**Verify:**
```bash
kubectl get application -n argocd
# expect: dns-monitoring-manifests, dns-monitoring-loki — both Synced/Healthy

kubectl get pods -n dns-monitoring
# expect: postgres-rollup-0, dns-monitoring-loki-0, metabase-<hash>
# (collector/rollup CronJob pods only appear when scheduled/triggered)
```

If either Application shows `OutOfSync` and doesn't self-correct, check
`argocd app get <name>` for the specific resource it's stuck on before
assuming anything is broken — this is normal briefly while PVCs
provision.

---

## Step 7 — Metabase first-run setup (manual, one-time, human)

Metabase has no env-var-based bootstrap mechanism. Once its pod is
`1/1 Running` and the ingress resolves:

1. Open `https://dns-insights.internal.lan`
2. Walk through the setup wizard
3. Use the email/password from `dns-monitoring/metabase-admin` in Vault
   (`kubectl exec -n vault vault-0 -- vault kv get dns-monitoring/metabase-admin`)
4. Connect it to `postgres-rollup` as a data source using the same
   credentials from `postgres-rollup-credentials`

---

## Step 8 — End-to-end verification

```bash
./15-test-collector-run.sh 2>&1 | tee /tmp/collector-log.txt
# expect [ok] for every branch
```

```bash
kubectl port-forward -n dns-monitoring svc/dns-monitoring-loki 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="pihole-domain-collector"}' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=50' | python3 -m json.tool
# expect real domain entries, not an empty result array
```

```bash
kubectl create job dns-analytics-rollup-manual-$(date +%s) \
  --from=cronjob/dns-analytics-rollup -n dns-monitoring
# wait for it to Complete, then:
kubectl exec -n dns-monitoring postgres-rollup-0 -- \
  psql -U dns_rollup -d dns_rollup -c \
  "SELECT * FROM top_domains_daily ORDER BY query_count DESC LIMIT 10;"
# expect real ranked domain rows
```

Finally, open Metabase and confirm you can browse the `dns_rollup`
database and see `top_domains_daily` with data in it.

**Once all four of those pass, the stack is fully operational — this
matches exactly the verification chain that confirmed the pipeline worked
on the original cluster.**

---

## Known gaps to resolve before treating this as more than a POC

Carried over from the original README, still genuinely unresolved:
- `ingress-nginx` controller's namespace/labels — confirm, don't assume (Step 3)
- 25 real branch IPs in `pihole-branch-hosts` — still placeholders until you fill them in
- `03-rbac-optional-native-k8s.yaml`'s group names — placeholders, and optional (ArgoCD RBAC via the `.csv` is the real access-control mechanism)
- `rollup.py`'s `pip install` at every run start — fine for a POC, worth a dedicated image with `psycopg2-binary` preinstalled before this becomes permanent
- No data retention/pruning on `top_domains_daily` — will grow indefinitely
