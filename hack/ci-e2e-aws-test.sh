#!/usr/bin/env bash
#
# Tests for the retry that hack/ci-e2e-aws.sh tears down with.
#
# The teardown has two claims behind it. That AWS answers "not ready
# yet" with IncorrectState is established by observation -- a prow run
# on 2026-08-24 was rejected with "Route Server has non-deleted
# propagation to Route Table" and leaked a route server. That the
# retry handles it is what this checks, with a stub rather than AWS,
# so it does not depend on a live run happening to hit the race. An
# earlier fix passed against a real cluster and still leaked in CI
# precisely because a green run proves nothing when the bug is a race.
#
#   hack/ci-e2e-aws-test.sh

set -o nounset
set -o pipefail

# shellcheck source=hack/lib/retry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/retry.sh"

# Real sleeps would make this too slow to sit in the unit job.
export RETRY_INTERVAL_SECS=1

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

passed=0
failed=0

check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS $1"
        passed=$((passed + 1))
    else
        echo "FAIL $1: got '$2', want '$3'"
        failed=$((failed + 1))
    fi
}

# The retry runs its command in a command substitution, so a counter
# kept in a variable would be incremented in a subshell and lost.
attempts() { cat "${workdir}/$1" 2>/dev/null || echo 0; }
record() {
    local n
    n=$(( $(attempts "$1") + 1 ))
    echo "${n}" > "${workdir}/$1"
    echo "${n}"
}

incorrect_state() {
    echo "An error occurred (IncorrectState) when calling the DisassociateRouteServer operation" >&2
    return 255
}

# Rejected twice, then accepted: the shape of a disassociate waiting on
# a propagation to finish deleting.
settles() {
    local n
    n="$(record settles)"
    if [[ "${n}" -lt 3 ]]; then
        incorrect_state
        return
    fi
    echo "disassociated"
}

out="$(retry_on_incorrect_state "settles" 60 settles 2>&1)"
check "retried until accepted" "$?" "0"
check "retried the right number of times" "$(attempts settles)" "3"
check "output of the accepted call is returned" "${out}" "disassociated"

# A permissions problem must surface at once. Retrying it for ten
# minutes and then reporting a timeout would hide the actual cause.
denied() {
    record denied >/dev/null
    echo "An error occurred (UnauthorizedOperation) when calling the DeleteRouteServer operation" >&2
    return 255
}

retry_on_incorrect_state "denied" 60 denied >/dev/null 2>&1
check "a non-IncorrectState error fails immediately" "$?" "1"
check "a non-IncorrectState error is not retried" "$(attempts denied)" "1"

# Something genuinely stuck has to give up rather than run until the
# step's grace period kills it mid-teardown.
stuck() {
    record stuck >/dev/null
    incorrect_state
}

started=${SECONDS}
retry_on_incorrect_state "stuck" 3 stuck >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - started))
check "a permanent IncorrectState gives up" "${rc}" "1"
if (( elapsed >= 3 && elapsed <= 15 )); then
    echo "PASS gave up near its budget (${elapsed}s for a 3s budget)"
    passed=$((passed + 1))
else
    echo "FAIL gave up after ${elapsed}s, expected near 3s"
    failed=$((failed + 1))
fi

# The overwhelmingly common case, and it must not sleep at all.
accepted() { echo "fine"; }

started=${SECONDS}
out="$(retry_on_incorrect_state "accepted" 60 accepted 2>&1)"
rc=$?
elapsed=$((SECONDS - started))
check "a call accepted first time succeeds" "${rc}" "0"
check "a call accepted first time returns its output" "${out}" "fine"
if (( elapsed <= 2 )); then
    echo "PASS accepted first time did not sleep (${elapsed}s)"
    passed=$((passed + 1))
else
    echo "FAIL accepted first time slept ${elapsed}s"
    failed=$((failed + 1))
fi

echo "---"
echo "passed=${passed} failed=${failed}"
[[ "${failed}" -eq 0 ]]
