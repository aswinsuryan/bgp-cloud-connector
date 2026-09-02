#!/usr/bin/env bash
#
# Enable FRR and route advertisements on the cluster's Network CR, then
# wait until the APIs the operator needs actually exist.
#
# Without frrk8s.metallb.io and RouteAdvertisements the manager does not
# start at all: controller-runtime gives up waiting for those caches
# after two minutes and the process exits. The operator applies this same
# patch itself during reconcile, but it never reaches reconcile, so
# something has to go first.
#
# The patch mirrors internal/controller/network_operator.go.
#
# Called by hack/ci-e2e-aws.sh. Standalone against a cluster you already
# have:
#
#   KUBECONFIG=<cluster>/auth/kubeconfig hack/enable-frr.sh
#   hack/enable-frr.sh --wait-only
#
# --wait-only skips the patch and waits for the rollout somebody else
# started -- another shell, or a run of this that was interrupted after
# it patched. The patch is idempotent, so re-running is safe either way;
# what --wait-only buys you is watching without touching.
#
# It gives up after 900s and prints what it last saw, which is the whole
# point of bounding it here rather than exposing a knob: an external
# timeout(1) kills it and leaves you with exit 124 and no idea whether
# CNO never started, stalled, or finished while co/network never settled.
# Wrap it in `timeout` if you want a shorter bound and do not need the
# diagnostic.
#
# Applying it rolls out OVN-Kubernetes across the cluster and stands up
# an frr-k8s daemonset. Measured at 122s on 4.22.9. hack/disable-frr.sh
# is the counterpart and does unwind.

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=hack/lib/frr.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/frr.sh"

timeout_secs=900
wait_only=false

for arg in "$@"; do
    case "${arg}" in
        --wait-only) wait_only=true ;;
        *) die "unknown option: ${arg}" "Usage: ${0##*/} [--wait-only]" ;;
    esac
done

require_cmd oc
require_cluster

# Re-applying the same values is a no-op, so this is safe to rerun.
if [[ "${wait_only}" == false ]]; then
    oc patch network.operator.openshift.io cluster --type=merge -p "${FRR_ENABLE_PATCH}"
else
    intent="$(frr_intent)"
    case "${intent}" in
        enabled) ;;
        unknown) die "--wait-only, but the Network CR could not be read" \
                     "The error is above. Nothing was changed." ;;
        *)       die "--wait-only, but the Network CR asks for ${intent}" \
                     "There is no enable to watch. Run without --wait-only to start one." ;;
    esac
fi

info "waiting for frr-k8s and the network rollout (up to ${timeout_secs}s)..."

# Bare, this would trip errexit before the case could read it.
rc=0
wait_until "${timeout_secs}" 10 "frr-k8s to become ready" frr_enabled_done || rc=$?
case ${rc} in
    0) ;;
    2) die "gave up: the cluster is no longer heading for FRR enabled" ;;
    *) oc get co network >&2
       die "timed out after ${timeout_secs}s waiting for frr-k8s" ;;
esac

oc get ds -n openshift-frr-k8s frr-k8s
ok "frr enabled"
