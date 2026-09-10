# Pipeline B Install Guide — Fresh Cluster (Vault Agent Injector)

This supersedes the earlier ESO-based install guide. Same pipeline
(collector → Loki → rollup → Postgres → Metabase), same Vault backend —
only the mechanism that gets secrets into pods has changed: pods now
authenticate to Vault directly via their own ServiceAccount and an
injected sidecar/init-container writes secret values to a file inside
the pod, instead of External Secrets Operator materializing a Kubernetes
Secret object.

For the *why* behind each fix baked into these files, see
`dns-monitoring-architecture-and-runbook.md`. This guide is the *what*,
in order.

## Prerequisite — confirm the injector is actually running

This guide assumes the Vault Agent Injector (`vault-k8s`) is already
installed and healthy in the `vault` namespace. If you're not certain:

```bash
kubectl get pods -n vault -l app.kubernetes.io/name=vault-agent-injector
```

If nothing shows up, install it (typically via the `hashicorp/vault`
Helm chart with `injector.enabled=true`) before continuing — every step
below depends on it being up.

## Final file list for this stack

```
00-namespace.yaml                     # ResourceQuota/LimitRange
serviceaccount-eso.yaml               # ServiceAccount every workload pod now authenticates as directly
vault-kv-secrets.sh                   # Vault KV writes: postgres-rollup, metabase-admin, pihole-api
vault-kubernetes-auth-role.sh         # Vault k8s-auth role registration (run once)
dns-monitoring-eso-policy.sh          # Vault policy (canonical, all 3 paths)
02-networkpolicy.yaml                 # default-deny-ingress + allow-intra-namespace
14-networkpolicy-analytics.yaml       # Metabase ingress + collector egress (now includes Vault:8200)
11-postgres-rollup.yaml               # Postgres StatefulSet — injector annotations, wrapped entrypoint
12-domain-collector-cronjob.yaml      # collect.py + rollup.py CronJobs — injector annotations, pre-populate-only
13-metabase.yaml                      # Metabase Deployment — injector annotations, wrapped entrypoint
values-loki.yaml                      # Loki Helm values
helm-repo-grafana.yaml                # Helm repo secret for Loki's chart source
dns-monitoring-project.yaml           # AppProject (trimmed)
argocd-application-manifests.yaml     # ArgoCD Application for everything above except values-loki.yaml
argocd-application-loki.yaml          # ArgoCD Application for Loki
03-rbac-optional-native-k8s.yaml      # Optional — native k8s RBAC
argocd-rbac-policy-snippet.csv        # Lines to append to argocd-rbac-cm
```

**No longer part of this stack (ESO-only, delete if present):**
`vault-secretstore.yaml`, `10-external-secrets-analytics.yaml`,
`15-external-secret-pihole.yaml`.

**Before you begin**, edit these placeholders:
- `12-domain-collector-cronjob.yaml`'s `pihole-branch-hosts` ConfigMap — real branch IPs
- `vault-kv-secrets.sh` — every `<generated>`/`<your-real-...>` value
- `13-metabase.yaml`'s entrypoint path (`/app/run_metabase.sh`) — **confirm, don't assume:**
  ```bash
  docker inspect metabase/metabase:v0.51.4 --format='{{.Config.Entrypoint}} {{.Config.Cmd}}'
  ```
- `14-networkpolicy-analytics.yaml`'s Vault `namespaceSelector` — confirm Vault's namespace is actually labeled `vault`:
  ```bash
  kubectl get ns vault --show-labels
  ```

---

## Step 1 — Vault (run by hand, never via CI/CD)

Unchanged from the ESO version — the injector uses the same Kubernetes
auth role and policy mechanism.

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

No SecretStore, no ExternalSecrets — just the namespace and the
ServiceAccount every workload pod will authenticate as directly.

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f serviceaccount-eso.yaml
```

**Verify:**
```bash
kubectl get serviceaccount dns-monitoring-eso -n dns-monitoring
```

---

## Step 3 — NetworkPolicies

```bash
kubectl apply -f 02-networkpolicy.yaml
kubectl apply -f 14-networkpolicy-analytics.yaml
```

Before applying, confirm both selectors this stack depends on:
```bash
kubectl get pods -n ingress-nginx --show-labels
kubectl get ns vault --show-labels
```

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

**Verify — this is the first real test that the injector wiring works
at all, so check it carefully rather than just waiting for `Running`:**
```bash
kubectl get pod postgres-rollup-0 -n dns-monitoring -w
```

If it hangs in `Init:0/1` or `Init:Error`, the injector's init container
is the one failing — check its logs specifically, not the main
container's:
```bash
kubectl logs postgres-rollup-0 -n dns-monitoring -c vault-agent-init
```
Common causes at this stage: the role/policy from Step 1 didn't
actually apply, the ServiceAccount name doesn't match
`bound_service_account_names`, or (per §5 of the architecture doc's
audit finding) the policy is missing a path it should have.

Once it reaches `1/1 Running`:
```bash
kubectl exec -n dns-monitoring postgres-rollup-0 -- pg_isready
# expect: accepting connections

kubectl exec -n dns-monitoring postgres-rollup-0 -- \
  psql -U dns_rollup -d dns_rollup -c "\dt"
# expect: top_domains_daily table already created
```

If `pg_isready` fails but the pod is `Running`, the injector succeeded
but the entrypoint wrapper didn't — check:
```bash
kubectl logs postgres-rollup-0 -n dns-monitoring -c postgres
```
for a Postgres startup error about missing/empty `POSTGRES_USER` etc.,
which would mean `/vault/secrets/postgres-rollup` wasn't sourced
correctly.

---

## Step 5 — ArgoCD project + RBAC

Unchanged.

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
```

---

## Step 7 — Metabase first-run setup (manual, one-time, human)

Watch the pod come up first, specifically checking whether the
entrypoint-path assumption in `13-metabase.yaml` held:

```bash
kubectl get pod -n dns-monitoring -l app.kubernetes.io/name=metabase -w
kubectl logs -n dns-monitoring -l app.kubernetes.io/name=metabase
```

If it's `CrashLoopBackOff` with an error like `exec: no such file or
directory` referencing `/app/run_metabase.sh`, the entrypoint guess was
wrong — re-run the `docker inspect` command from the placeholder list
above and fix `13-metabase.yaml`'s `args:` to the real path.

Once it's `1/1 Running` and the ingress resolves:

1. Open `https://dns-insights.internal.lan`
2. Walk through the setup wizard
3. Use the email/password from Vault:
   ```bash
   kubectl exec -n vault vault-0 -- vault kv get dns-monitoring/metabase-admin
   ```
4. Connect it to `postgres-rollup` as a data source using the same
   credentials from `dns-monitoring/postgres-rollup`

---

## Step 8 — End-to-end verification

```bash
./15-test-collector-run.sh 2>&1 | tee /tmp/collector-log.txt
# expect [ok] for every branch
```

If a run instead shows the Job stuck `Running` well past when
`collect.py` should have finished, the injector's persistent sidecar
mode is active instead of pre-populate-only — check
`12-domain-collector-cronjob.yaml`'s
`vault.hashicorp.com/agent-pre-populate-only: "true"` annotation is
actually present and spelled correctly.

```bash
kubectl port-forward -n dns-monitoring svc/dns-monitoring-loki 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="pihole-domain-collector"}' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=50' | python3 -m json.tool
# expect real domain entries
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

Finally, confirm Metabase can browse `dns_rollup` → `top_domains_daily`
with data in it.

**Once all four pass, the stack is fully operational under the
injector** — functionally identical to the ESO version's verification
chain, just with different plumbing underneath.

---

## Injector-specific troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| Pod stuck `Init:0/1` or `Init:Error` | Vault role/policy/ServiceAccount mismatch — check `vault-agent-init` container logs specifically |
| Pod `1/1 Running` but app fails with missing/empty credentials | Entrypoint wrapper didn't source `/vault/secrets/<name>` correctly — check the app container's own logs |
| CronJob pod never reaches `Completed` | `agent-pre-populate-only: "true"` annotation missing or misspelled — the injector defaulted to a persistent sidecar |
| Collector's injector init container times out reaching Vault | `14-networkpolicy-analytics.yaml`'s Vault egress rule missing or the namespace selector doesn't match Vault's real namespace label |
| Any debug pod used to test the above "just works" when the real pod doesn't | The debug pod is missing `serviceAccountName: dns-monitoring-eso` — it's authenticating as `default` and proving nothing about the real pod's identity (same trap as testing NetworkPolicy with an unlabeled pod) |

---

## Known gaps to resolve before treating this as more than a POC

- `13-metabase.yaml`'s entrypoint path — confirm once, don't just trust the guess in production
- `14-networkpolicy-analytics.yaml`'s Vault namespace label — same caution
- 25 real branch IPs in `pihole-branch-hosts` — still placeholders
- `03-rbac-optional-native-k8s.yaml`'s group names — placeholders, optional
- `rollup.py`'s `pip install` at every run start — fine for POC, worth a dedicated image later
- No data retention/pruning on `top_domains_daily` — will grow indefinitely
