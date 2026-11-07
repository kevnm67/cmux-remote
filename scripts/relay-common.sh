#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts
# Shared helpers for the always-on relay scripts. Sourced, not executed.
# Never reads or prints tokens: only the `listen` key of relay.json is parsed.

RELAY_HOME="${CMUX_RELAY_HOME:-$HOME/.cmuxremote}"
RELAY_CONFIG="${CMUX_RELAY_CONFIG:-$RELAY_HOME/relay.json}"
RELAY_WS_NAME="${CMUX_RELAY_WORKSPACE:-cmux-remote · relay}"
RELAY_LOG="$RELAY_HOME/log/watchdog.log"
CMUX_CLI="${CMUX_BUNDLED_CLI_PATH:-cmux}"

log() {
    mkdir -p "$RELAY_HOME/log"
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$RELAY_LOG"
}

# Prints "host port" from relay.json's listen value.
relay_listen() {
    /usr/bin/python3 -I -c '
import json, sys
host, _, port = json.load(open(sys.argv[1]))["listen"].rpartition(":")
print(host, port)' "$RELAY_CONFIG"
}

# True when $1 is 0.0.0.0 or an address currently assigned to an interface.
host_is_up() {
    [ "$1" = "0.0.0.0" ] && return 0
    ifconfig 2>/dev/null | grep -qF "inet $1 "
}

# The runner is the cmux child that keeps the relay alive.
# Anchored on argv[0] so a wrapper shell that merely mentions the script name never matches.
RUNNER_PATTERN='^(/[^ ]*/)?bash (/[^ ]*/)?run-relay-in-cmux\.sh'
RELAY_PATTERN='^/[^ ]*/cmux-relay serve'
runner_running() { pgrep -f "$RUNNER_PATTERN" >/dev/null 2>&1; }

# PID listening on TCP $1 (empty when free).
port_holder() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true
}

# Single-runner lock: an atomic mkdir plus a pid file. Returns 0 when this
# process now owns the lock, 1 when a live runner already does. A dead owner's
# lock is cleared and retaken.
RUNNER_LOCK="$RELAY_HOME/runner.lock"
acquire_runner_lock() {
    mkdir -p "$RELAY_HOME"
    local owner tries=0
    while [ "$tries" -lt 3 ]; do
        if mkdir "$RUNNER_LOCK" 2>/dev/null; then
            echo "$$" >"$RUNNER_LOCK/pid"
            return 0
        fi
        owner="$(cat "$RUNNER_LOCK/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null; then
            return 1
        fi
        rm -rf "$RUNNER_LOCK"
        tries=$((tries + 1))
    done
    return 1
}

release_runner_lock() {
    if [ "$(cat "$RUNNER_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$RUNNER_LOCK"; fi
    return 0
}
