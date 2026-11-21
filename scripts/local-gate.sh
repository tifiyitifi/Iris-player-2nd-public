#!/bin/sh
# Local privacy gate shim: the four hooks source this, and it calls the
# PowerShell checker. Keeping the probe in one place means the hooks stay tiny
# and the fail-open behaviour is identical everywhere.
#
# It returns (rather than exits) so a hook that has other work - the version
# bump in pre-commit - still runs when the gate is skipped or has no shell.
set -u

run_check() {
    "$PS" -NoProfile -ExecutionPolicy Bypass -File scripts/check-local-paths.ps1 "$@"
}

main() {
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    cd "$root" || return 0

    if command -v powershell >/dev/null 2>&1; then
        PS=powershell
    elif command -v pwsh >/dev/null 2>&1; then
        PS=pwsh
    else
        echo "check-local-paths: no PowerShell found, the change was not checked" >&2
        return 0
    fi

    mode=${IRIS_GATE_MODE:-${1:-}}
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    # A CR can survive a Windows pipe feeding the hook; the range validation is
    # hex-only. `printf` is a shell built-in, so this needs no PATH entry.
    CR=$(printf '\r')

    case "$mode" in
        staged | message)
            # Record branches are a local audit trail and are never pushed. A
            # checkpoint must be able to capture work in progress; pre-push
            # still checks the range if such a branch is ever pushed.
            case "$branch" in
                *-ai-tmp-commit*)
                    echo "check-local-paths: record branch '$branch' is local-only; gate skipped" >&2
                    return 0
                    ;;
            esac
            if [ "$mode" = "message" ]; then
                # The hook passes the message file as $1; use it so a merge
                # (MERGE_MSG) is checked instead of a stale COMMIT_EDITMSG.
                if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
                    run_check -Message -MessageFile "$1"
                else
                    run_check -Message
                fi
            else
                run_check
            fi
            return $?
            ;;
        pushed)
            status=0
            if [ -t 0 ]; then
                run_check -Pushed || status=1
            else
                while read -r local_ref local_sha remote_ref remote_sha; do
                    [ -z "${local_sha:-}" ] && continue
                    local_sha=${local_sha%$CR}
                    remote_sha=${remote_sha%$CR}
                    case "$local_sha" in
                        *[!0]*) ;;
                        *) continue ;;
                    esac
                    case "$remote_sha" in
                        *[!0]*) run_check -Pushed -Range "$remote_sha..$local_sha" || status=1 ;;
                        *) run_check -Pushed || status=1 ;;
                    esac
                done
            fi
            return $status
            ;;
        *)
            echo "usage: $0 staged|message|pushed" >&2
            return 2
            ;;
    esac
}

main "$@"
