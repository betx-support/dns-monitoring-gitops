#!/usr/bin/env bash
# §6.5-equivalent, part 2 — adds the two new secrets needed by the
# marketing-analytics addition (Postgres rollup DB, Metabase admin).
# Uses the SAME "dns-monitoring" KV v2 mount created in
# 06-dns-monitoring-kv-and-secrets.sh — this is an addition to that app's
# existing mount, not a new one, since it's the same app/namespace.
# Replace every <generated> placeholder before running.
# Run once, by hand, same auth conventions as 06/07.
set -euo pipefail

ROOT_TOKEN="<root-token>"   # from vault-init-output.txt — never hard-code for real use

kubectl exec -n vault vault-0 -- vault login "$ROOT_TOKEN"

# Postgres backing the daily "top sites" rollup table Metabase reads from.
# NOT the same thing as the old (now-removed) dns-monitoring/postgres
# secret from the HA-Grafana era — that one no longer exists; this is a
# new, unrelated database for a different purpose.
kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/postgres-rollup \
  POSTGRES_USER="dns_rollup" \
  POSTGRES_PASSWORD="<generated>" \
  POSTGRES_DB="dns_rollup"

# Metabase's own admin bootstrap login. Note: Metabase has no env-based
# "create this admin on first boot" mechanism (see 13-metabase.yaml) — this
# secret exists so the value is tracked in Vault like everything else, but
# a human still has to type it into Metabase's first-run setup wizard once.
kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/metabase-admin \
  METABASE_ADMIN_EMAIL="<your-real-admin-email>" \
  METABASE_ADMIN_PASSWORD="<generated>"
