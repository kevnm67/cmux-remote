#!/usr/bin/env bash
# Keep the relay reachable: recreate its cmux workspace when closed, and restart
# the relay when it answers neither HTTP nor a WebSocket handshake (for example a
# socket left dead after Tailscale reconnects). Runs detached from a cmux shell
# so it inherits CMUX_SOCKET_CAPABILITY; it exits when cmux stops accepting it
# (cmux restarted -> capability stale) and the next cmux shell restarts it via
# ensure-relay.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=relay-common.sh
. "$here/relay-common.sh"

pidfile="$RELAY_HOME/watchdog.pid"
interval="${CMUX_RELAY_WATCHDOG_INTERVAL:-5}"
probe="$here/relay-probe.py"

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null && [ "$(cat "$pidfile")" != "$$" ]; then
    exit 0
fi
echo "$$" >"$pidfile"
trap 'rm -f "$pidfile"' EXIT
log "watchdog: started pid $$"

cmux_failures=0
probe_failures=0
while true; do
    if "$CMUX_CLI" ping >/dev/null 2>&1; then
        cmux_failures=0
        CMUX_RELAY_SETTLE=1 "$here/ensure-relay.sh" --no-watchdog || true

        read -r host port < <(relay_listen)
        # Orphaned relays (not under the runner) are rejected by cmux: kill them.
        for pid in $(pgrep -f "$RELAY_PATTERN" || true); do
            [ "$(ps -o ppid= -p "$pid" | tr -d ' ')" = "1" ] && { log "watchdog: killing orphan relay $pid"; kill "$pid" || true; }
        done
        if host_is_up "$host"; then
            if /usr/bin/python3 -I "$probe" "$host" "$port" >/dev/null 2>&1; then
                probe_failures=0
            else
                probe_failures=$((probe_failures + 1))
                if [ "$probe_failures" -ge 2 ]; then
                    log "watchdog: probe failed ${probe_failures}x on $host:$port; restarting relay"
                    pkill -f "$RELAY_PATTERN" || true   # the runner restarts it
                    probe_failures=0
                fi
            fi
        fi
    else
        cmux_failures=$((cmux_failures + 1))
        if [ "$cmux_failures" -ge 4 ]; then
            log "watchdog: cmux refused/unreachable ${cmux_failures}x; exiting (restarts with the next cmux shell)"
            exit 0
        fi
    fi
    sleep "$interval"
done
