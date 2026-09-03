# DNS monitoring stack — integrated with your existing cluster platform

This wires the Prometheus/Grafana/Alertmanager stack into the same
Vault + External Secrets Operator + ArgoCD + cert-manager platform SnipeIT
already uses, following the **exact same conventions** confirmed from your
`snipeit-gitops` scripts and manifests — not guessed equivalents.

## What's now confirmed (not placeholders) vs. still genuinely unknown

Reviewing your actual Vault/ArgoCD/cert-manager setup corrected several
assumptions in the first draft of this stack:

| Item | Status |
|---|---|
| `cert-manager.io/cluster-issuer: internal-ca-issuer` | **Confirmed** — from `03-internal-ca-clusterissuer.yaml` |
| `ingressClassName: nginx` | **Confirmed** — matches every existing ingress |
| SecretStore is namespace-scoped (`SecretStore`, not `ClusterSecretStore`), one per app | **Confirmed** — from `vault-secretstore.yaml` |
| Each app gets its own dedicated Vault KV mount + Kubernetes-auth role | **Confirmed** — from `03-`/`04-kubernetes-auth.sh` |
| ArgoCD RBAC is `policy.csv`-based, scoped per-`AppProject`, with a real group `betx-platform-team` | **Confirmed** — from `rbac-policy.csv` |
| Each app gets its own `AppProject`, not `default` | **Confirmed** — from `project.yaml`, though `dns-monitoring-project`'s `clusterResourceWhitelist` deliberately differs from snipeit's empty one (see `dns-monitoring-project.yaml` comments) |
| `nginx-ingress` controller's own namespace/labels | **Still unconfirmed** — no install script for it was included; check with `kubectl get pods -n ingress-nginx --show-labels` before trusting `02-networkpolicy.yaml`'s rule |
| Branch VPN CIDR (`10.90.0.0/16` in `02-networkpolicy.yaml`) | **Still a placeholder** — your real site-to-site VPN range |
| Native K8s RBAC groups in `03-rbac-optional-native-k8s.yaml` | **Still placeholders, and optional** — no evidence this cluster uses native RoleBindings for app access; `argocd-rbac-policy-snippet.csv` is the real mechanism |
| Dedicated node pool taint/label (`workload=monitoring`) | **Your choice** — only relevant if you add nodes specifically for this |
| 25 branch exporter IPs in `values.yaml` | **Still placeholders** — your real branch IPs |

## Deployment order

1. **Vault side first** (run these by hand, same as your existing Vault
   scripts — never via CI/CD):
   ```bash
   # Fill in real secret values first, then:
   ./06-dns-monitoring-kv-and-secrets.sh
   ./07-dns-monitoring-kubernetes-auth.sh
   ```
2. **Kubernetes manifests**, in order:
   ```bash
   kubectl apply -f 00-namespace.yaml
   kubectl apply -f serviceaccount-eso.yaml
   kubectl apply -f vault-secretstore.yaml
   kubectl apply -f 01-external-secrets.yaml
   kubectl apply -f 02-networkpolicy.yaml   # after confirming the ingress-nginx namespace/labels
   kubectl get externalsecret -n dns-monitoring   # confirm SYNCED before moving on
   ```
3. **ArgoCD project + RBAC**:
   ```bash
   kubectl apply -f dns-monitoring-project.yaml
   # then append argocd-rbac-policy-snippet.csv's contents into the
   # existing argocd-rbac-cm ConfigMap's policy.csv key
   ```
4. **The two Applications** (edit `repoURL`/`path` to your actual GitOps
   repo layout first):
   ```bash
   kubectl apply -f argocd-application-manifests.yaml
   kubectl apply -f argocd-application-helm.yaml
   ```
5. Fill in the real branch IPs and VPN CIDR in `values.yaml` /
   `02-networkpolicy.yaml` before the first real sync.

## Should this get dedicated nodes?

Optional, same reasoning as before — recommended given it now shares a
cluster with something operationally important. If you add nodes for this:
```bash
kubectl taint nodes <new-node-name> workload=monitoring:NoSchedule
kubectl label nodes <new-node-name> workload=monitoring
```
Otherwise delete the `tolerations:`/`nodeSelector:` blocks in `values.yaml`
and `postgres.yaml`.

## One thing worth knowing, not a file change

Your `01-install.sh` notes Vault itself is single-replica, no HA, by
deliberate accepted tradeoff. That was already true before this stack
existed — but it's worth registering that Vault being down now affects
**two** apps' secret refreshes instead of one. ExternalSecrets keep serving
their last-known-good value if a refresh fails, so a brief Vault outage
doesn't immediately break already-running pods — but new secret rotations
or a fresh deploy would stall until Vault's back. Not necessarily a reason
to revisit Vault's HA tradeoff on its own, but worth folding into whatever
trigger condition `§7.6` already defines for reconsidering it.

## File map

```
00-namespace.yaml                   # Namespace, ResourceQuota, LimitRange
serviceaccount-eso.yaml             # ServiceAccount ESO authenticates to Vault as
vault-secretstore.yaml              # SecretStore, mirrors snipeit's exactly
06-dns-monitoring-kv-and-secrets.sh # Vault KV mount + secret values (run by hand)
07-dns-monitoring-kubernetes-auth.sh# Vault policy + k8s-auth role (run by hand)
01-external-secrets.yaml            # ExternalSecrets, corrected key/property paths
02-networkpolicy.yaml               # Default-deny + explicit allow rules
03-rbac-optional-native-k8s.yaml    # Optional extra hardening, not the primary mechanism
argocd-rbac-policy-snippet.csv      # Lines to append to argocd-rbac-cm
dns-monitoring-project.yaml         # AppProject, correctly scoped for kube-prometheus-stack
values.yaml                         # kube-prometheus-stack Helm values
postgres.yaml                       # Grafana's Postgres backend
prometheusrule.yaml                 # Branch-down / anomaly alert rules
argocd-application-helm.yaml        # ArgoCD Application for the Helm chart
argocd-application-manifests.yaml   # ArgoCD Application for everything else
```
