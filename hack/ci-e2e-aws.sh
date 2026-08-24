#!/usr/bin/env bash
#
# Entry point for the e2e-aws prow job.
#
# The job definition in openshift/release is deliberately one line --
# it runs this file and nothing else -- so that everything about what
# the test does can be changed here, with a normal pull request in this
# repository, instead of a round trip through the release repo.
#
# What runs today: stand up the AWS VPC route server estate the
# operator expects to discover, report it, and tear it down again. The
# operator discovers route servers and endpoints, it never creates
# them, so something has to go first. Enabling FRR, deploying the
# operator and running the e2e suite are the next things to land here.
#
# Locally, against a cluster you already have:
#
#   KUBECONFIG=<cluster>/auth/kubeconfig AWS_PROFILE=<profile> hack/ci-e2e-aws.sh

set -o nounset
set -o errexit
set -o pipefail

# In prow the cluster profile supplies the credentials and the install
# leaves a kubeconfig behind. Run outside prow and whatever is already
# in the environment is used instead, which is what makes this testable
# without waiting forty minutes for a cluster.
if [[ -n "${CLUSTER_PROFILE_DIR:-}" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# shellcheck source=hack/lib/retry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/retry.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# The src image carries the Go toolchain and, with cli: latest, oc. It
# has no aws CLI, and the route server commands need v2.34.7 or newer,
# so v1 from pip will not do. Fetching it here rather than asking for a
# different image keeps the release-repo side unaware of the
# dependency.
install_aws_cli() {
    local zip="${workdir}/awscliv2.zip"

    echo "Fetching the aws CLI..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${zip}"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "${zip}" -d "${workdir}"
    elif command -v python3 >/dev/null 2>&1; then
        # The builder image is not guaranteed to carry unzip, and the
        # failure would otherwise be a bare "command not found" a long
        # way from the cause.
        python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
            "${zip}" "${workdir}"
        chmod -R +x "${workdir}/aws"
    else
        echo "neither unzip nor python3 is available to unpack the aws CLI" >&2
        exit 1
    fi

    "${workdir}/aws/install" -i "${workdir}/aws-cli" -b "${workdir}/bin"
    export PATH="${workdir}/bin:${PATH}"
}

if ! command -v aws >/dev/null 2>&1; then
    install_aws_cli
fi

command -v oc >/dev/null 2>&1 || { echo "oc is not on PATH" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not connected to a cluster; set KUBECONFIG" >&2; exit 1; }

infra="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"
region="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')"
export AWS_REGION="${region}"
export AWS_DEFAULT_REGION="${region}"

echo "cluster:  ${infra}"
echo "region:   ${region}"
# Called but not printed. Prow logs for openshift repositories are
# public, and the ARN carries the account id and the principal name.
# It still has to succeed: it is the cheapest check that the
# credentials work at all, and it is what the operator itself does.
aws sts get-caller-identity >/dev/null
echo "aws cli:  $(aws --version 2>&1)"

# Ask before creating anything. An API the region does not offer and an
# API this account may not call are different answers, and a failed
# create cannot tell them apart. The error text is the distinction.
if ! describe_out="$(aws ec2 describe-route-servers 2>&1)"; then
    echo "FAIL describe-route-servers"
    echo "${describe_out}"
    exit 1
fi
echo "OK   describe-route-servers"

vpc="$(aws ec2 describe-vpcs \
    --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned" \
    --query 'Vpcs[0].VpcId' --output text)"
if [[ "${vpc}" == "None" || -z "${vpc}" ]]; then
    echo "no VPC tagged kubernetes.io/cluster/${infra}=owned" >&2
    exit 1
fi

subnet="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" \
    --query 'Subnets[0].SubnetId' --output text)"
route_table="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc}" \
    --query 'RouteTables[0].RouteTableId' --output text)"

if [[ "${subnet}" == "None" || "${route_table}" == "None" ]]; then
    echo "vpc ${vpc} has no usable subnet (${subnet}) or route table (${route_table})" >&2
    exit 1
fi

echo "vpc:      ${vpc}"
echo "subnet:   ${subnet}"
echo "table:    ${route_table}"

# None of these resources has an aws ec2 wait, so every wait polls
# describe. A failed describe is a failed poll, never an empty answer,
# or expired credentials read as "it has gone" and the delete that
# follows hits a resource still standing.
wait_until() {
    local what="$1" attempts="$2"; shift 2
    local i
    for (( i = 1; i <= attempts; i++ )); do
        if "$@"; then
            return 0
        fi
        sleep 10
    done
    echo "timed out waiting for ${what}" >&2
    return 1
}

route_server_available() {
    local state
    state="$(aws ec2 describe-route-servers --route-server-ids "${1}" \
        --query 'RouteServers[0].State' --output text 2>/dev/null)" || return 1
    [[ "${state}" == "available" ]]
}

# Deleting an endpoint that is still pending is rejected as
# IncorrectState, so the teardown needs it to have settled first, and
# an endpoint that comes up is a stronger answer than one that was
# merely accepted.
endpoint_available() {
    local state
    state="$(aws ec2 describe-route-server-endpoints --route-server-endpoint-ids "${1}" \
        --query 'RouteServerEndpoints[0].State' --output text 2>/dev/null)" || return 1
    [[ "${state}" == "available" ]]
}

route_server=""
endpoint=""
propagated=false
associated=false
cleaned_up=false

# Endpoints bill hourly and belong to the VPC rather than the cluster,
# so the deprovision step will not reclaim them. Prow signals rather
# than exits, and bash does not run an EXIT trap when an untrapped
# signal kills the shell, hence TERM and INT here -- and hence the
# guard, now that cleanup can be reached both ways.
cleanup() {
    local rc=${1:-$?}
    if [[ "${cleaned_up}" == true ]]; then
        return
    fi
    cleaned_up=true
    set +o errexit

    local teardown_rc=0
    echo "--- teardown ---"
    if [[ -n "${endpoint}" ]]; then
        retry_on_incorrect_state "delete endpoint ${endpoint}" 300 \
            aws ec2 delete-route-server-endpoint --route-server-endpoint-id "${endpoint}" \
            || teardown_rc=1
    fi
    if [[ "${propagated}" == true ]]; then
        retry_on_incorrect_state "disable propagation to ${route_table}" 300 \
            aws ec2 disable-route-server-propagation \
            --route-server-id "${route_server}" --route-table-id "${route_table}" \
            || teardown_rc=1
    fi
    # Blocked by both the propagation and the endpoint, so it gets the
    # largest budget: it is where the wait actually lands.
    if [[ "${associated}" == true ]]; then
        retry_on_incorrect_state "disassociate from ${vpc}" 600 \
            aws ec2 disassociate-route-server \
            --route-server-id "${route_server}" --vpc-id "${vpc}" \
            || teardown_rc=1
    fi
    if [[ -n "${route_server}" ]]; then
        retry_on_incorrect_state "delete route server ${route_server}" 300 \
            aws ec2 delete-route-server --route-server-id "${route_server}" \
            || teardown_rc=1
    fi
    if (( teardown_rc != 0 )); then
        echo "--- teardown FAILED: cloud resources may have been left behind ---" >&2
        if (( rc == 0 )); then
            rc=1
        fi
    else
        echo "--- teardown done ---"
    fi

    rm -rf "${workdir}"
    exit "${rc}"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# 65000 is what the hacks scripts use for the Amazon side, and it has
# to differ from the localASN a CUDNBgpConfig carries or the session is
# not eBGP. Nothing peers yet, so it only has to be well formed.
echo "creating route server..."
route_server="$(aws ec2 create-route-server \
    --amazon-side-asn 65000 \
    --tag-specifications "ResourceType=route-server,Tags=[{Key=Name,Value=${infra}-rs}]" \
    --query 'RouteServer.RouteServerId' --output text)"
echo "OK   create-route-server ${route_server}"
wait_until "route server to become available" 60 route_server_available "${route_server}"

retry_on_incorrect_state "associate with ${vpc}" 300 \
    aws ec2 associate-route-server --route-server-id "${route_server}" --vpc-id "${vpc}"
associated=true
echo "OK   associate-route-server ${vpc}"

endpoint="$(retry_on_incorrect_state "create endpoint" 300 \
    aws ec2 create-route-server-endpoint \
    --route-server-id "${route_server}" \
    --subnet-id "${subnet}" \
    --tag-specifications "ResourceType=route-server-endpoint,Tags=[{Key=Name,Value=${infra}-rs-ep}]" \
    --query 'RouteServerEndpoint.RouteServerEndpointId' --output text)"
echo "OK   create-route-server-endpoint ${endpoint}"
wait_until "endpoint to become available" 60 endpoint_available "${endpoint}"

# Propagation is the one that hides: without it every peer reaches
# available and every session establishes while nothing in the VPC can
# reach a pod.
retry_on_incorrect_state "enable propagation to ${route_table}" 300 \
    aws ec2 enable-route-server-propagation \
    --route-server-id "${route_server}" --route-table-id "${route_table}"
propagated=true
echo "OK   enable-route-server-propagation ${route_table}"

echo "--- the estate the operator would discover ---"
aws ec2 describe-route-servers --route-server-ids "${route_server}" --output table
aws ec2 describe-route-server-endpoints \
    --query "RouteServerEndpoints[?RouteServerId=='${route_server}']" --output table
aws ec2 get-route-server-associations --route-server-id "${route_server}" --output table
aws ec2 get-route-server-propagations --route-server-id "${route_server}" --output table

echo "estate stood up successfully"
