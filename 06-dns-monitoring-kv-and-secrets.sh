#!/usr/bin/env bash
# §6.5-equivalent for dns-monitoring — mirrors 03-enable-kv-and-write-secrets.sh.
# Enable a KV v2 engine at path "dns-monitoring" (its own mount, not shared
# with snipeit's "snipeit" mount) and write the actual secret values.
# Replace every <generated> placeholder before running.
# Run once, by hand, using the root token from vault-init-output.txt (or a
# suitably scoped admin token — the root token should ideally be revoked
# after initial setup per Vault's own hardening guidance, in which case use
# whatever admin auth path you've since set up instead).
set -euo pipefail

ROOT_TOKEN="<root-token>"   # from vault-init-output.txt — never hard-code for real use

kubectl exec -n vault vault-0 -- vault login "$ROOT_TOKEN"

kubectl exec -n vault vault-0 -- vault secrets enable -path=dns-monitoring kv-v2

# POC MODE: no "dns-monitoring/postgres" secret anymore — Postgres was
# removed since Grafana is back to a single pod persisting via its own
# PVC (see values.yaml). If you re-enable the HA Postgres pattern later,
# re-add: vault kv put dns-monitoring/postgres POSTGRES_PASSWORD="<generated>"

kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/grafana-admin \
  GRAFANA_ADMIN_USER="admin" \
  GRAFANA_ADMIN_PASSWORD="<generated>"

kubectl exec -n vault vault-0 -- vault kv put dns-monitoring/alertmanager \
  SMTP_PASSWORD="<office365-app-password>"   # app password if MFA is on this mailbox, else its login password
