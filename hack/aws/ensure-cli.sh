#!/usr/bin/env bash
#
# Make sure an aws CLI new enough for the route server commands is
# available, and print the directory it is in.
#
#   hack/aws/ensure-cli.sh [<install-dir>]
#
# Install dir defaults to the repository's bin, which is what the
# Makefile passes and what .gitignore already covers.
#
# Nothing is downloaded when the one on PATH will do. That is the same
# rule the operator-sdk and opm targets use, and here it also keeps
# NixOS working: the archive AWS publishes is dynamically linked against
# a generic Linux, so its PT_INTERP points at /lib64/ld-linux-x86-64.so.2,
# which on NixOS is nix-ld's stub. Preferring the system CLI avoids the
# problem rather than patching around it.
#
# The archive is chosen by uname. AWS publishes linux-x86_64 and
# linux-aarch64, and openshift/release schedules arm64 jobs, so a
# hardcoded x86_64 would download an archive that unpacks cleanly and
# then fails on exec.
#
# The check is on the version, not on presence. The src image carries no
# aws at all today, but a v1 from pip would satisfy "is it installed?"
# and then fail on the route server subcommands with "Invalid choice",
# a long way from the cause.

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=hack/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

min_version="2.34.7"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
install_dir="${1:-${repo_root}/bin}"

case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "no aws CLI archive is published for $(uname -m)" ;;
esac

# aws --version prints "aws-cli/2.36.30 Python/3.14.6 Linux/... exe/..."
aws_version() {
    local out
    out="$("$1" --version 2>&1)" || return 1
    printf '%s' "${out}" | sed -n 's|^aws-cli/\([0-9.]*\).*|\1|p'
}

version_at_least() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

usable() {
    local candidate="$1" version
    version="$(aws_version "${candidate}")" || return 1
    [[ -n "${version}" ]] || return 1
    version_at_least "${version}" "${min_version}"
}

if command -v aws >/dev/null 2>&1 && usable aws; then
    dirname "$(command -v aws)"
    exit 0
fi

if [[ -x "${install_dir}/aws" ]] && usable "${install_dir}/aws"; then
    printf '%s' "${install_dir}"
    exit 0
fi

require_cmd curl

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Fetch and check in one step, so a retry covers a truncated download as
# well as a failed one. A corrupt archive otherwise fails later, in the
# unpack, where it reads as a broken image rather than a bad transfer.
fetch() {
    local zip="$1"
    rm -f "${zip}"
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "${zip}" \
        || return 1
    if command -v unzip >/dev/null 2>&1; then
        unzip -tq "${zip}" >/dev/null || return 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, zipfile; sys.exit(1 if zipfile.ZipFile(sys.argv[1]).testzip() else 0)" \
            "${zip}" || return 1
    fi
    return 0
}

zip="${workdir}/awscliv2.zip"

# Retried because in CI this runs after the cluster is up. Throwing away
# a forty-minute install because a CDN blipped once is the most
# expensive possible way to fail, and it is the first outside thing the
# job touches.
warn "no aws CLI ${min_version} or newer on PATH; fetching ${arch} into ${install_dir}"
retry 5 10 "fetch the aws CLI" fetch "${zip}" \
    || die "could not download a usable aws CLI archive"

if command -v unzip >/dev/null 2>&1; then
    unzip -q "${zip}" -d "${workdir}"
elif command -v python3 >/dev/null 2>&1; then
    # The builder image is not guaranteed to carry unzip, and the
    # failure would otherwise be a bare "command not found" a long way
    # from the cause.
    python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
        "${zip}" "${workdir}"
    chmod -R +x "${workdir}/aws"
else
    die "neither unzip nor python3 is available to unpack the aws CLI"
fi

mkdir -p "${install_dir}"
"${workdir}/aws/install" --install-dir "${install_dir}/aws-cli" --bin-dir "${install_dir}" --update >&2

usable "${install_dir}/aws" \
    || die "installed an aws CLI but it is not usable, or is older than ${min_version}"

printf '%s' "${install_dir}"
