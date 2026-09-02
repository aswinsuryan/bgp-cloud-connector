#!/usr/bin/env bash
#
# Show every route server in a region, with its endpoints, VPC
# associations, propagations and peers.
#
#   hack/aws/list-route-servers.sh
#   hack/aws/list-route-servers.sh --all
#   AWS_REGION=us-west-2 hack/aws/list-route-servers.sh
#
# Deliberately account-wide rather than scoped to your cluster. These are
# VPC resources that outlive the clusters they were made for, and they
# bill by the hour, so the useful question is "what is running here that
# nobody owns any more" rather than "what did I make". Anything whose VPC
# has gone is flagged as orphaned.
#
# AWS keeps returning route servers, endpoints and peers long after they
# are deleted. Those tombstones cannot be acted on and quickly outnumber
# everything else, so they are hidden by default and counted rather than
# dropped in silence. --all shows them.
#
# Read-only, and for you rather than for CI: it prints the account id,
# which must not reach a prow log. The e2e job does not call it.

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=hack/aws/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

show_all=false
case "${1:-}" in
    --all) show_all=true ;;
    "") ;;
    *) die "unknown option: $1" "Usage: ${0##*/} [--all]" ;;
esac

require_cmd aws jq
require_aws

# jq clause dropping tombstones, or keeping everything with --all.
if [[ "${show_all}" == true ]]; then
    live='true'
else
    live='.State != "deleted"'
fi

# A cluster is optional here: it only supplies a default region and
# decides whether a route server gets flagged as this one's. Optional
# means "we can work without one", not "we do not care what happened" --
# so ask whether there is a cluster first, and treat a failure after
# that as a failure rather than as an absent cluster.
mine=""
have_cluster=false
if oc whoami >/dev/null 2>&1; then
    have_cluster=true
fi

if [[ -z "${AWS_REGION:-}" ]]; then
    [[ "${have_cluster}" == true ]] \
        || die "set AWS_REGION, or connect to a cluster to borrow its region"
    AWS_REGION="$(oc get infrastructure cluster \
        -o jsonpath='{.status.platformStatus.aws.region}' 2>&1)" \
        || die "connected to a cluster but could not read its region" "${AWS_REGION}"
fi
[[ -n "${AWS_REGION}" ]] \
    || die "the cluster reported an empty region; set AWS_REGION"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

if [[ "${have_cluster}" == true ]]; then
    mine="$(oc get infrastructure cluster \
        -o jsonpath='{.status.infrastructureName}' 2>&1)" \
        || die "connected to a cluster but could not read its infrastructure name" "${mine}"
fi

info "region:  ${AWS_REGION}"
info "account: $(aws sts get-caller-identity --query Account --output text)"

# One describe per resource type, joined client-side with jq. The
# describe calls reject route-server-id as a filter anyway, so asking
# again per server and per endpoint is pure overhead: three calls in
# total carry everything. Only the associations and propagations lack a
# bulk call, so those stay per server.
servers_json="$(aws ec2 describe-route-servers --output json)"

servers="$(jq -r ".RouteServers[] | select(${live}) | .RouteServerId" <<<"${servers_json}")"
hidden_rs="$(jq '[.RouteServers[] | select(.State == "deleted")] | length' <<<"${servers_json}")"

if [[ -z "${servers}" ]]; then
    info "no live route servers"
    if [[ "${show_all}" == false && "${hidden_rs}" != "0" ]]; then
        info "(${hidden_rs} deleted, hidden; --all to show)"
    fi
    exit 0
fi

endpoints_json="$(aws ec2 describe-route-server-endpoints --output json)"
peers_json="$(aws ec2 describe-route-server-peers --output json)"

# Every VPC in the region, once, for the orphan check. describe-vpcs
# --vpc-ids with a deleted id fails outright rather than returning the
# survivors, so the alternative is one existence probe per association,
# which is the per-item shape again.
all_vpcs="$(aws ec2 describe-vpcs --query 'Vpcs[].VpcId' --output text | tr '\t' '\n')"
vpc_exists() { printf '%s\n' "${all_vpcs}" | grep -qx "$1"; }

read_failed=false

for rs in ${servers}; do
    read -r asn state name <<<"$(jq -r --arg rs "${rs}" \
        '.RouteServers[] | select(.RouteServerId == $rs)
         | [.AmazonSideAsn, .State, ((.Tags // []) | map(select(.Key == "Name"))[0].Value // "")]
         | @tsv' <<<"${servers_json}")"

    marker=""
    if [[ -n "${mine}" && "${name}" == "${mine}-rs" ]]; then
        marker="   <- this cluster"
    fi

    info "${rs}  asn=${asn}  state=${state}  name=${name:-<untagged>}${marker}"

    # This is a diagnostic tool, so an unreadable answer is reported as
    # unreadable. Saying "none" for a read that failed is worse here
    # than anywhere else: none is exactly the finding you would act on.
    if ! vpcs="$(route_server_vpcs "${rs}")"; then
        info "    associations: UNKNOWN, the read failed"
        vpcs=""
        read_failed=true
    elif [[ -z "${vpcs}" ]]; then
        info "    associations: none"
    fi
    for v in ${vpcs}; do
        if vpc_exists "${v}"; then
            info "    vpc ${v}"
        else
            info "    vpc ${v}  (GONE - orphaned)"
        fi
    done

    # Propagation is shown because its absence is silent: peers reach
    # available, sessions establish, and the routes never leave the route
    # server. A route server with none is almost certainly broken.
    if ! propagations="$(aws_query "read propagations for ${rs}" \
        aws ec2 get-route-server-propagations --route-server-id "${rs}" \
        --query "RouteServerPropagations[?State!='deleted'].[RouteTableId,State]" \
        --output text)"; then
        info "    propagation: UNKNOWN, the read failed"
        propagations=""
        read_failed=true
    elif [[ -z "${propagations}" ]]; then
        info "    propagation: NONE - learned routes reach no route table"
    else
        while read -r rt pstate; do
            [[ -n "${rt}" ]] || continue
            info "    propagates to ${rt}  ${pstate}"
        done <<<"${propagations}"
    fi

    endpoints="$(jq -r --arg rs "${rs}" \
        ".RouteServerEndpoints[] | select(.RouteServerId == \$rs) | select(${live}) | .RouteServerEndpointId" \
        <<<"${endpoints_json}")"

    [[ -n "${endpoints}" ]] || info "    endpoints: none"
    for e in ${endpoints}; do
        read -r subnet eni est <<<"$(jq -r --arg e "${e}" \
            '.RouteServerEndpoints[] | select(.RouteServerEndpointId == $e)
             | [.SubnetId, .EniAddress // "None", .State] | @tsv' <<<"${endpoints_json}")"
        info "    endpoint ${e}  ${subnet}  ${eni}  ${est}"

        while read -r pid paddr pstate; do
            [[ -n "${pid}" ]] || continue
            info "      peer ${pid}  ${paddr}  ${pstate}"
        done <<<"$(jq -r --arg e "${e}" \
            ".RouteServerPeers[] | select(.RouteServerEndpointId == \$e) | select(${live})
             | [.RouteServerPeerId, .PeerAddress // \"None\", .State] | @tsv" <<<"${peers_json}")"
    done
    info ""
done

# A listing that could not read part of what it was asked about is not
# a clean listing, and this one gets used to decide whether anything was
# left behind.
if [[ "${read_failed}" == true ]]; then
    warn "some reads failed; this listing is incomplete"
fi

if [[ "${show_all}" == false ]]; then
    dead_ep="$(jq '[.RouteServerEndpoints[] | select(.State == "deleted")] | length' <<<"${endpoints_json}")"
    dead_peer="$(jq '[.RouteServerPeers[] | select(.State == "deleted")] | length' <<<"${peers_json}")"
    if [[ "${hidden_rs}" != "0" || "${dead_ep}" != "0" || "${dead_peer}" != "0" ]]; then
        info "hidden: ${hidden_rs} deleted route server(s), ${dead_ep} endpoint(s), ${dead_peer} peer(s); --all to show"
    fi
fi

[[ "${read_failed}" == false ]]
