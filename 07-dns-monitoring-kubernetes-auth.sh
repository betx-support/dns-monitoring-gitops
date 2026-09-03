#!/usr/bin/env bash
# §6.6-equivalent for dns-monitoring — mirrors 04-kubernetes-auth.sh.
# Kubernetes auth is already enabled cluster-wide (done once, for snipeit) —
# this just adds a new policy scoped to exactly the three dns-monitoring
# paths, and a new role binding it to the dns-monitoring-eso ServiceAccount
# in the dns-monitoring namespace only. Does not touch snipeit's existing
# policy/role.
set -euo pipefail

kubectl exec -i -n vault vault-0 -- vault policy write dns-monitoring-eso - <<'EOF'
path "dns-monitoring/data/postgres"      { capabilities = ["read"] }
path "dns-monitoring/data/grafana-admin" { capabilities = ["read"] }
path "dns-monitoring/data/alertmanager"  { capabilities = ["read"] }
EOF

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/dns-monitoring-eso \
  bound_service_account_names=dns-monitoring-eso \
  bound_service_account_namespaces=dns-monitoring \
  policy=dns-monitoring-eso \
  ttl=1h
