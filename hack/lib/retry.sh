# shellcheck shell=bash
# Shared by hack/ci-e2e-aws.sh and its test. Sourced, never run.

# AWS reports "not ready yet" as IncorrectState rather than as a
# retryable error code, and the describe APIs answer optimistically: a
# resource still deleting is already absent from the "what is left"
# queries. Polling those for "has it gone" returned true on the first
# attempt in CI, and the disassociate that followed was rejected.
#
# So do not predict readiness. Issue the call and let AWS say when it
# is ready. This also means the teardown does not have to know the
# dependency order exactly -- the order below only helps it converge
# sooner.
retry_on_incorrect_state() {
    local what="$1" budget="$2"; shift 2
    local deadline=$((SECONDS + budget)) out
    local interval="${RETRY_INTERVAL_SECS:-10}"

    while true; do
        if out="$("$@" 2>&1)"; then
            printf '%s\n' "${out}"
            return 0
        fi
        if [[ "${out}" != *IncorrectState* ]]; then
            echo "${what}: ${out}" >&2
            return 1
        fi
        if (( SECONDS >= deadline )); then
            echo "${what}: still IncorrectState after ${budget}s: ${out}" >&2
            return 1
        fi
        sleep "${interval}"
    done
}
