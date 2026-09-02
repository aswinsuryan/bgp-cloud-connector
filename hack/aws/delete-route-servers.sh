#!/usr/bin/env bash
#
# Tear down the estate hack/aws/create-route-servers.sh built.
#
#   hack/aws/delete-route-servers.sh --dry-run
#   hack/aws/delete-route-servers.sh
#
# Endpoints bill hourly and are VPC resources rather than cluster ones,
# so they outlive the cluster that prompted them: a QE cluster reaped
# after twelve hours leaves them behind, and its VPC cannot be deleted
# while they are attached.
#
# Normally it identifies what to delete from the running cluster. Once
# the cluster is gone there is nothing to ask, so name it:
#
#   INFRA=mycluster-abcde AWS_REGION=us-east-2 \
#       hack/aws/delete-route-servers.sh
#
# Only ever touches the route server tagged <infra>-rs, so it cannot
# take out somebody else's.

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=hack/aws/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

parse_args "$@"
require_cmd aws

# Predicates for wait_until. Each answers one question about current
# state and says nothing about what to do when the answer is no.
#
# A failed describe call is a failed poll, never an empty answer. These
# used to end in "|| echo 0", which turned expired credentials or
# throttling mid-wait into "nothing left": the wait reported success and
# the deletes that followed hit IncorrectState against resources that
# were still there.

no_pending_peers() {
    local n
    n="$(aws ec2 describe-route-server-peers \
        --query "length(RouteServerPeers[?RouteServerId=='$1' && State=='pending'])" \
        --output text 2>/dev/null)" \
        || { warn "  describe-route-server-peers failed"; return 1; }
    [[ "${n}" == "0" ]] && return 0
    info "  ${n} peer(s) still pending"
    return 1
}

peers_gone() {
    local n
    n="$(aws ec2 describe-route-server-peers \
        --query "length(RouteServerPeers[?RouteServerId=='$1' && State!='deleted'])" \
        --output text 2>/dev/null)" \
        || { warn "  describe-route-server-peers failed"; return 1; }
    [[ "${n}" == "0" ]] && return 0
    info "  ${n} peer(s) still deleting"
    return 1
}

no_pending_endpoints() {
    local n
    n="$(aws ec2 describe-route-server-endpoints \
        --query "length(RouteServerEndpoints[?RouteServerId=='$1' && State=='pending'])" \
        --output text 2>/dev/null)" \
        || { warn "  describe-route-server-endpoints failed"; return 1; }
    [[ "${n}" == "0" ]] && return 0
    info "  ${n} endpoint(s) still pending"
    return 1
}

endpoints_gone() {
    local n
    n="$(aws ec2 describe-route-server-endpoints \
        --query "length(RouteServerEndpoints[?RouteServerId=='$1' && State!='deleted'])" \
        --output text 2>/dev/null)" \
        || { warn "  describe-route-server-endpoints failed"; return 1; }
    [[ "${n}" == "0" ]]
}

# AWS reports "this route server has no associations" as an error rather
# than as an empty list:
#
#   InvalidRouteServerId.NotAssociated: Route Server rs-... is not
#   associated with a VPC.
#
# So the state being waited for is the state that makes the call fail.
# Reading every error as a failed poll meant this could never succeed: it
# burned the full timeout on every delete and then reported a failure
# that had not happened. Distinguish the two rather than swallowing all
# errors, so a genuine API problem still stops us.
associations_cleared() {
    local out
    if out="$(aws ec2 get-route-server-associations --route-server-id "$1" \
        --query 'length(RouteServerAssociations)' --output text 2>&1)"; then
        [[ "${out}" == "0" ]]
        return
    fi
    case "${out}" in
        *NotAssociated*) return 0 ;;
    esac
    warn "  get-route-server-associations failed: ${out}"
    return 1
}

# Same hazard: an empty result may come back as an error rather than a
# zero, so a "nothing left" answer must not read as a failed poll.
propagations_cleared() {
    local out
    if out="$(aws ec2 get-route-server-propagations --route-server-id "$1" \
        --query "length(RouteServerPropagations[?State!='deleted'])" \
        --output text 2>&1)"; then
        [[ "${out}" == "0" ]]
        return
    fi
    case "${out}" in
        *NotAssociated*|*NotFound*|*NoSuch*) return 0 ;;
    esac
    warn "  get-route-server-propagations failed: ${out}"
    return 1
}

# INFRA set means the cluster is gone, so there is nothing to ask and no
# platform to assert. Otherwise everything comes from the cluster.
infra="${INFRA:-}"
if [[ -n "${infra}" ]]; then
    [[ -n "${AWS_REGION:-}" ]] || die "INFRA is set, so AWS_REGION must be too" \
        "There is no cluster left to read the region from."
    export AWS_DEFAULT_REGION="${AWS_REGION}"
else
    require_cmd oc
    require_cluster
    require_platform AWS
    # The cluster wins over AWS_REGION. AWS_REGION is exported into
    # every shell, and everything below filters on a tag in one region,
    # so the wrong region finds no route server and reports "nothing to
    # do" -- which is indistinguishable from nothing being left. You
    # would then destroy the cluster believing the estate was clean and
    # leave a route server, six endpoints and seven propagations behind
    # in a VPC that no longer exists. Observed 2026-08-13.
    #
    # Say so when the environment disagreed rather than discarding it in
    # silence, because the one case that is not a stale shell is
    # somebody who meant it.
    if [[ -n "${AWS_REGION:-}" ]]; then
        cluster_region="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')"
        if [[ "${AWS_REGION}" != "${cluster_region}" ]]; then
            warn "AWS_REGION is ${AWS_REGION}, but the cluster reports ${cluster_region}."
            warn "Using ${cluster_region}, which is where its route servers are."
        fi
    fi
    aws_cluster_facts
fi

require_aws

# This one decides whether the teardown does anything at all, so a
# failed read here is the difference between "nothing to do" and a
# leaked estate reported as a success.
rs="$(route_server_for_cluster "${infra}")"

if [[ -z "${rs}" ]]; then
    info "nothing to do: no route server tagged ${infra}-rs in ${AWS_REGION}"
    exit 0
fi

info "region:       ${AWS_REGION}"
info "cluster:      ${infra}"
info "route server: ${rs}"

# An endpoint still coming up can be neither deleted (IncorrectState)
# nor skipped: leaving it out of the selection below deletes the route
# server out from under it and leaves the endpoint behind, billing. Wait
# for the state to settle before deciding what exists.
if [[ "${dry_run}" == false ]]; then
    wait_until 300 10 "endpoints to leave pending" no_pending_endpoints "${rs}" \
        || fail "endpoints still pending; they will be missed below"
fi

# DescribeRouteServerEndpoints and DescribeRouteServerPeers both reject
# route-server-id and route-server-endpoint-id as filters, so every
# selection here happens client-side. Anything not already deleted or
# deleting counts, endpoints that failed to come up included: AWS keeps
# listing them long after they go, so the dead states have to come out,
# but a failed endpoint is still holding an ENI in a subnet.
# Both reads happen before anything is deleted, so failing here costs
# nothing and leaves nothing half done. Failing later would.
endpoints="$(route_server_endpoints "${rs}")" \
    || die "cannot list the endpoints on ${rs}" \
           "Nothing has been deleted. Re-run when the API answers."
vpcs="$(route_server_vpcs "${rs}")" \
    || die "cannot read the associations for ${rs}" \
           "Nothing has been deleted. Re-run when the API answers."

info "will delete:"
[[ -n "${endpoints}" ]] || info "  (no live endpoints)"
for e in ${endpoints}; do info "  endpoint ${e}"; done
for v in ${vpcs}; do info "  association with ${v}"; done
info "  route server ${rs}"

# Peers hold endpoints open, so they go first. The operator creates
# these, which is why they may exist even though we never made any.
#
# AWS keeps listing peers for a long time after removing them, and
# rejects a delete of one already gone, or of one still coming up, with
# IncorrectState. So the dead states are filtered out, the wait below
# clears the ones still coming up, and the retry around each delete
# absorbs whatever raced through in between.
if [[ "${dry_run}" == false && -n "${endpoints}" ]]; then
    wait_until 300 10 "peers to leave pending" no_pending_peers "${rs}" \
        || fail "peers still pending; deletes below may hit IncorrectState"
fi

# Failures are recorded, not fatal: a delete that trips errexit here
# skips everything after it, including the summary, which is exactly how
# resources get left behind unreported.
for e in ${endpoints}; do
    # Recorded and skipped rather than fatal. An unguarded read here
    # aborts the teardown under errexit with some peers deleted and the
    # route server still standing, and the trap that called us has
    # already fired, so nothing tries again.
    if ! peers="$(endpoint_peers "${e}")"; then
        fail "list peers on ${e}"
        continue
    fi
    for p in ${peers}; do
        if aws_retry "delete peer ${p}" 300 aws ec2 delete-route-server-peer --route-server-peer-id "${p}"; then
            ok "delete-route-server-peer ${p}"
        else
            fail "delete peer ${p}"
        fi
    done
done

# Deleting a peer only moves it to "deleting", and an endpoint refuses
# to go while it still has a non-deleted peer. The wait above is for
# peers to leave "pending" before we delete them; this one is for them
# to finish leaving after we have. Both are needed, and only having the
# first is how this failed.
if [[ "${dry_run}" == false && -n "${endpoints}" ]]; then
    wait_until 600 10 "peers to finish deleting" peers_gone "${rs}" \
        || fail "peers did not finish deleting; endpoint deletes will fail"
fi

for e in ${endpoints}; do
    if aws_retry "delete endpoint ${e}" 300 aws ec2 delete-route-server-endpoint --route-server-endpoint-id "${e}"; then
        ok "delete-route-server-endpoint ${e}"
    else
        fail "delete endpoint ${e}"
    fi
done

# Not gated on whether we deleted any: an endpoint a previous run left
# in "deleting" still blocks the route server delete below, and if none
# ever existed the first poll answers instantly.
if [[ "${dry_run}" == false ]]; then
    wait_until 600 10 "endpoints to go away" endpoints_gone "${rs}" \
        || fail "endpoints did not go away"
fi

# Propagations before the association, mirroring the order Terraform
# destroys in: the propagation depends on the association, so removing
# the association first leaves a dependency pointing at something that
# has gone.
# A failed read here yields no propagations, so none are disabled, the
# disassociate below is then rejected with IncorrectState for its whole
# budget, and the route server delete fails -- the estate stays up. That
# is the shape of the leak this file's header describes.
propagations=""
if ! propagations="$(route_server_propagations "${rs}")"; then
    fail "read propagations for ${rs}"
fi

for rt in ${propagations}; do
    if aws_retry "disable propagation to ${rt}" 300 aws ec2 disable-route-server-propagation --route-server-id "${rs}" --route-table-id "${rt}"; then
        ok "disable-route-server-propagation ${rt}"
    else
        fail "disable propagation to ${rt}"
    fi
done

if [[ "${dry_run}" == false && -n "${propagations}" ]]; then
    wait_until 600 10 "propagations to clear" propagations_cleared "${rs}" \
        || fail "propagations did not clear"
fi

for v in ${vpcs}; do
    if aws_retry "disassociate from ${v}" 600 aws ec2 disassociate-route-server --route-server-id "${rs}" --vpc-id "${v}"; then
        ok "disassociate-route-server ${v}"
    else
        fail "disassociate from ${v}"
    fi
done

if [[ "${dry_run}" == false && -n "${vpcs}" ]]; then
    wait_until 600 10 "associations to clear" associations_cleared "${rs}" \
        || fail "associations did not clear"
fi

if aws_retry "delete route server ${rs}" 300 aws ec2 delete-route-server --route-server-id "${rs}"; then
    ok "delete-route-server ${rs}"
else
    fail "delete route server ${rs}"
fi

report
