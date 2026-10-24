#!/usr/bin/env bash
# Make sure the relay workspace and the watchdog exist. Idempotent, safe to run
# from every cmux shell (~/.zshrc) and from the watchdog.
#
#   ensure-relay.sh              recreate the relay workspace if needed, start the watchdog
#   ensure-relay.sh --no-watchdog  workspace only (used by the watchdog itself)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=relay-common.sh
. "$here/relay-common.sh"

runner="$here/run-relay-in-cmux.sh"
lock="$RELAY_HOME/ensure-relay.lock"
pidfile="$RELAY_HOME/watchdog.pid"
start_watchdog=1
[ "${1:-}" = "--no-watchdog" ] && start_watchdog=0

ensure_workspace() {
    runner_running && return 0

    # Single-flight: clear a stale lock (>60 s) left by a crashed run.
    if [ -d "$lock" ]; then
        age=$(($(date +%s) - $(stat -f %m "$lock")))
        [ "$age" -gt 60 ] && rmdir "$lock" 2>/dev/null || true
    fi
    mkdir "$lock" 2>/dev/null || return 0
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT

    # Let cmux finish restoring workspaces, then re-check.
    sleep "${CMUX_RELAY_SETTLE:-5}"
    runner_running && return 0

    # Close leftover relay workspaces (a runner-less shell left behind).
    # `|| true`: no match (grep exit 1) must not abort under pipefail.
    { "$CMUX_CLI" workspace list --id-format both 2>/dev/null |
        grep -F "$RELAY_WS_NAME" |
        awk '{for (i = 1; i <= NF; i++) if ($i ~ /^workspace:/) { print $i; break }}' |
        while read -r ref; do
            [ -n "$ref" ] && "$CMUX_CLI" workspace close "$ref" >/dev/null 2>&1 || true
        done; } || true

    "$CMUX_CLI" workspace create --name "$RELAY_WS_NAME" --cwd "$HOME" --command "$runner" --focus false >/dev/null
    log "ensure-relay: created workspace '$RELAY_WS_NAME'"
}

ensure_watchdog() {
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return 0
    fi
    # Detached, but it keeps this shell's CMUX_SOCKET_CAPABILITY, which is what
    # cmuxOnly authorises on; it survives its workspace being closed.
    nohup "$here/relay-watchdog.sh" >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
}

ensure_workspace
[ "$start_watchdog" -eq 1 ] && ensure_watchdog
exit 0
