# shellcheck shell=bash
#
# What the prow jobs need and a developer running the same scripts does
# not. Source this, do not run it.
#
# The job is two steps -- the test, and a teardown that runs whatever
# the test did -- so both entry points need the same bootstrap and it
# lives here rather than in whichever one was written first.

# shellcheck source=hack/aws/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../aws" && pwd)/lib.sh"

ci_workdir=""

# Put a usable aws CLI on PATH. hack/aws/ensure-cli.sh decides whether
# that means the one already installed or a download, and is also what
# `make bin/aws` runs, so there is one implementation of it.
#
# Installing into the repository's bin rather than a scratch directory
# is what keeps the sequencer's two children sharing a single download
# instead of fetching sixty megabytes each.
ci_ensure_aws_cli() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../aws" && pwd)/ensure-cli.sh"
    dir="$("${dir}")" || die "could not provide an aws CLI"
    export PATH="${dir}:${PATH}"
}

# In prow the cluster profile supplies the credentials and the install
# leaves a kubeconfig behind. Run outside prow and whatever is already
# in the environment is used instead, which is what makes these testable
# without waiting forty minutes for a cluster.
#
# The caller owns the trap that removes the workdir: these scripts have
# their own cleanup to order it against, and a trap set here would be
# replaced by theirs without either of us noticing.
#
# The workdir is scratch space only. Nothing that must outlive the run
# goes in it, and nothing created in the cloud is tracked there.
ci_bootstrap() {
    if [[ -n "${CLUSTER_PROFILE_DIR:-}" ]]; then
        [[ -f "${CLUSTER_PROFILE_DIR}/.awscred" ]] \
            || die "CLUSTER_PROFILE_DIR is set but has no .awscred" \
                   "Looked in ${CLUSTER_PROFILE_DIR}"
        export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    fi

    if [[ -n "${SHARED_DIR:-}" ]]; then
        [[ -f "${SHARED_DIR}/kubeconfig" ]] \
            || die "SHARED_DIR is set but has no kubeconfig" \
                   "Looked in ${SHARED_DIR}"
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    ci_workdir="$(mktemp -d)"
    ci_ensure_aws_cli
}

ci_remove_workdir() {
    [[ -n "${ci_workdir}" ]] && rm -rf "${ci_workdir}"
    return 0
}
