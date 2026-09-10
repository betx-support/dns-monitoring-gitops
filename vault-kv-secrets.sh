#!/usr/bin/env bash
# Canonical Vault KV write script for the dns-monitoring stack,
# Pipeline B only (no grafana-admin/alertmanager — Pipeline A was never
# deployed on this cluster). Writes all three secrets Pipeline B needs
# into the "dns-monitoring" KV v2 mount in one place, rather than split
# across multiple scripts as in the original rollout.
#
# Replace every <generated>/<your-real-...> placeholder before running.
# Run once, by hand, using the root token from vault-init-output.txt (or
# a suitably scoped admin token).
set -euo pipefail

ROOT_TOKEN="<root-token>"   # from vault-init-output.txt — never hard-code for real use

kubectl exec -n vault vault-0 -- vault login "$ROOT_TOKEN"

kubectl exec -n vault vault-0 -- vault secrets enable -path=dns-monitoring kv-v2

# Postgres backing the daily "top sites" rollup table Metabase reads from.
kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/postgres-rollup \
  POSTGRES_USER="dns_rollup" \
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  POSTGRES_DB="dns_rollup"

# Metabase's own admin bootstrap login. Not consumed by any container env
# var — Metabase has no supported "create this admin on first boot"
# mechanism via env vars (see 13-metabase.yaml's comment). A human still
# has to walk through Metabase's setup wizard once and type this in by
# hand; it's tracked here so the value lives in Vault rather than only in
# someone's head.
kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/metabase-admin \
  METABASE_ADMIN_EMAIL="it@betxchange.co.za" \
  METABASE_ADMIN_PASSWORD="$METABASE_ADMIN_PASSWORD"

# Shared Pi-hole v6 admin password, used by pihole-domain-collector to
# authenticate against each branch's API before pulling top_domains.
# This is the SAME password configured on every branch Pi-hole instance —
# see the design discussion for why it's shared rather than per-branch.
kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/pihole-api \
  PIHOLE_API_PASSWORD="$PIHOLE_API_PASSWORD"

echo "Confirming all three secrets are present..."
kubectl exec -n vault vault-0 -- vault kv list dns-monitoring/
