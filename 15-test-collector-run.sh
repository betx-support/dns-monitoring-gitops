#!/usr/bin/env bash
# One-off manual trigger for pihole-domain-collector, so you can see
# [ok]/[warn] output immediately instead of waiting up to 15 minutes for
# the schedule to fire — meant for the "verify end to end" step of the
# implementation guide, not for regular use.
#
# Usage: ./15-test-collector-run.sh
set -euo pipefail

NAMESPACE="dns-monitoring"
CRONJOB="pihole-domain-collector"
JOB_NAME="pihole-domain-collector-manual-$(date +%s)"

echo "Creating one-off Job '$JOB_NAME' from CronJob '$CRONJOB'..."
kubectl create job "$JOB_NAME" \
  --from="cronjob/$CRONJOB" \
  -n "$NAMESPACE"

echo "Waiting for the pod to start..."
kubectl wait --for=condition=Ready pod \
  -l "job-name=$JOB_NAME" \
  -n "$NAMESPACE" \
  --timeout=60s || true   # don't hard-fail here — a fast pod may already be Completed

echo "--- logs ---"
kubectl logs -n "$NAMESPACE" -l "job-name=$JOB_NAME" --tail=-1 --follow || true

echo "--- job status ---"
kubectl get job "$JOB_NAME" -n "$NAMESPACE"

echo ""
echo "If every branch printed [ok], the pipeline's collection leg is"
echo "working end to end. If you see [warn] <branch> failed: ..., that's"
echo "almost always one of: wrong IP in pihole-branch-hosts, the shared"
echo "password not matching what's in Vault (dns-monitoring/pihole-api),"
echo "or a NetworkPolicy blocking egress (see allow-egress-domain-collector"
echo "in 14-networkpolicy-analytics.yaml)."
echo ""
echo "Clean up the test Job once you're satisfied:"
echo "  kubectl delete job $JOB_NAME -n $NAMESPACE"
