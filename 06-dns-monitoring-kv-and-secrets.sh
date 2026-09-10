#!/usr/bin/env bash
# UPDATED: Pipeline A (grafana-admin, alertmanager) removed — those
# secrets no longer have any consumer. This script is kept (rather than
# deleted outright) only because 08-dns-analytics-kv-and-secrets.sh's
# header comment describes itself as "part 2" of this one and references
# it by name — deleting this file entirely would orphan that reference.
# If you've already run the original version of this script, the live
# Vault entries at dns-monitoring/grafana-admin and dns-monitoring/
# alertmanager still exist and are NOT removed by re-running this —
# `vault kv put` only writes/updates, it doesn't delete other paths.
# Remove them explicitly, once, by hand:
#   kubectl exec -n vault vault-0 -- vault kv delete dns-monitoring/grafana-admin
#   kubectl exec -n vault vault-0 -- vault kv delete dns-monitoring/alertmanager
#
# Nothing left for this script to actually do for a fresh setup — kept
# as a placeholder/pointer only. Safe to delete once 08's header comment
# is updated to stop referencing it.
set -euo pipefail

echo "Pipeline A removed — this script no longer writes any secrets."
echo "See this file's header comment for the one-time manual cleanup"
echo "commands for the old grafana-admin/alertmanager Vault entries."
