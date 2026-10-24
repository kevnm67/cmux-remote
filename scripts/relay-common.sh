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
