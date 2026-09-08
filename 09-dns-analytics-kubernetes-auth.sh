#!/usr/bin/env bash
# §6.6-equivalent, part 2 — extends the existing dns-monitoring-eso Vault
# policy to cover the two new secrets from 08-dns-analytics-kv-and-secrets.sh.
#
# IMPORTANT: `vault policy write` REPLACES the named policy wholesale, it
# does not merge. This script's heredoc therefore includes BOTH the two
# original paths from 07-dns-monitoring-kubernetes-auth.sh AND the two new
# ones — running this after 07 gives you the union; running 07 again
# *after* this would wipe the additions back out, so don't.
#
# No new role or ServiceAccount needed. The existing dns-monitoring-eso
# ServiceAccount, in the existing dns-monitoring namespace, already
# authenticates via the existing auth/kubernetes/role/dns-monitoring-eso
# role — none of that changes, only the policy body it maps to.
set -euo pipefail

kubectl exec -i -n vault vault-0 -- vault policy write dns-monitoring-eso - <<'EOF'
path "dns-monitoring/data/grafana-admin"    { capabilities = ["read"] }
path "dns-monitoring/data/alertmanager"     { capabilities = ["read"] }
path "dns-monitoring/data/postgres-rollup"  { capabilities = ["read"] }
path "dns-monitoring/data/metabase-admin"   { capabilities = ["read"] }
EOF
