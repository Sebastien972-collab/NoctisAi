#!/bin/sh
# Minimal POSIX terminal progress UI. No external package dependencies.
# Source this file; call noctis_ui_run "Step" command args...
noctis_ui_pid=
noctis_ui_active=false

noctis_ui_enabled() {
    [ -t 2 ] && [ -z "${CI:-}" ] && [ -z "${NO_COLOR:-}" ] &&
        [ "${TERM:-dumb}" != dumb ]
}

noctis_ui_stop() {
    if [ -n "$noctis_ui_pid" ]; then
        kill "$noctis_ui_pid" 2>/dev/null || :
        wait "$noctis_ui_pid" 2>/dev/null || :
        noctis_ui_pid=
    fi
    if [ "$noctis_ui_active" = true ]; then
        printf '\r\033[2K' >&2
        noctis_ui_active=false
    fi
}

noctis_ui_run() {
    label=$1
    shift
    started=$(date +%s)
    log=$(mktemp "${TMPDIR:-/tmp}/noctis-ui.XXXXXXXX") || return 1
    if noctis_ui_enabled; then
        noctis_ui_active=true
        (
            trap 'exit 0' TERM INT HUP
            while :; do
                for frame in '◐' '◓' '◑' '◒'; do
                    printf '\r\033[2K  %s %s…' "$frame" "$label" >&2
                    sleep 0.15
                done
            done
        ) &
        noctis_ui_pid=$!
    else
        printf '  … %s\n' "$label" >&2
    fi

    if "$@" >"$log" 2>&1; then
        result=0
    else
        result=$?
    fi
    noctis_ui_stop
    elapsed=$(($(date +%s) - started))
    if [ "$result" -eq 0 ]; then
        printf '  ✓ %s (%ss)\n' "$label" "$elapsed" >&2
    else
        printf '  ✗ %s (%ss)\n' "$label" "$elapsed" >&2
        cat "$log" >&2
    fi
    rm -f "$log"
    return "$result"
}
