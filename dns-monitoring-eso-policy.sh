#!/usr/bin/env bash
# Canonical, single source of truth for the dns-monitoring-eso Vault
# policy. REPLACES both 07-dns-monitoring-kubernetes-auth.sh and
# 09-dns-analytics-kubernetes-auth.sh — delete both of those files once
# this is in place.
#
# WHY THIS FILE EXISTS: `vault policy write` replaces the named policy
# wholesale, it does not merge. Having two separate scripts
# (07 and 09) each write their own partial view of this same policy was
# a real, live footgun — 09's version omitted the pihole-api path
# entirely, meaning if 09 were ever re-run after whatever script
# originally granted pihole-api access, that access would be silently
# wiped with no error at write time, only a later ExternalSecret sync
# failure. Keeping exactly one script that always writes the FULL
# current path list eliminates that class of bug permanently.
#
# Current paths, and why each is here:
#   postgres-rollup  — read by postgres-rollup's StatefulSet, the daily
#                       rollup CronJob, and Metabase's MB_DB_* env vars
#   metabase-admin   — tracked in Vault for reference only; not consumed
#                       by any running container (see 13-metabase.yaml)
#   pihole-api       — read by the pihole-domain-collector CronJob to
#                       authenticate against each branch's Pi-hole v6 API
#
# REMOVED as part of the Pipeline A cleanup (kube-prometheus-stack was
# decommissioned): grafana-admin, alertmanager. If Pipeline A is ever
# reinstated, add those two paths back here rather than recreating a
# separate script for them.
#
# No new role or ServiceAccount needed — the existing dns-monitoring-eso
# ServiceAccount/role from the original setup is unchanged, only the
# policy body it maps to.
set -euo pipefail

kubectl exec -i -n vault vault-0 -- vault policy write dns-monitoring-eso - <<'EOF'
path "dns-monitoring/data/postgres-rollup" { capabilities = ["read"] }
path "dns-monitoring/data/metabase-admin"  { capabilities = ["read"] }
path "dns-monitoring/data/pihole-api"      { capabilities = ["read"] }
EOF

echo "Verifying the policy actually contains what we expect..."
kubectl exec -n vault vault-0 -- vault policy read dns-monitoring-eso
