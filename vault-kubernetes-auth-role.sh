#!/usr/bin/env bash
# One-time Vault Kubernetes-auth role registration for dns-monitoring.
# Run this ONCE, before the first sync of anything that depends on
# ExternalSecrets in this namespace. Separate from
# dns-monitoring-eso-policy.sh deliberately — this defines WHICH
# ServiceAccount/namespace can assume the role at all, while that script
# defines WHAT the role is allowed to read once assumed. Re-running this
# script is safe and idempotent; it does not need to change when the
# policy's path list changes.
#
# Assumes Kubernetes auth is already enabled cluster-wide in Vault
# (`vault auth enable kubernetes`) — if this is a genuinely fresh Vault
# instance rather than one already used by another app (e.g. snipeit),
# confirm that first:
#   kubectl exec -n vault vault-0 -- vault auth list
set -euo pipefail

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/dns-monitoring-eso \
  bound_service_account_names=dns-monitoring-eso \
  bound_service_account_namespaces=dns-monitoring \
  policy=dns-monitoring-eso \
  ttl=1h

echo "Verifying the role..."
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/dns-monitoring-eso
