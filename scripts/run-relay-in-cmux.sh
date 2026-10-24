#!/usr/bin/env bash
# Run cmux-relay as a child of a cmux terminal and restart it if it exits.
#
# cmux's default socketControlMode (cmuxOnly) only accepts processes spawned
# inside cmux, so a launchd-started relay is rejected with "Access denied".
# Start this script from a cmux terminal (e.g. a dedicated workspace) instead
# of loading the launchd agent. ensure-relay.sh does that automatically.
#
# The relay binds the Tailscale address from relay.json. Binding fails while
# Tailscale is down, so wait for the address to exist before every (re)start
# instead of crash-looping; Tailscale node IPs are stable across reconnects.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=relay-common.sh disable=SC1091
. "$here/relay-common.sh"

relay="${CMUX_RELAY_BIN:-$RELAY_HOME/bin/cmux-relay}"
delay="${CMUX_RELAY_RESTART_DELAY:-2}"
log_dir="$RELAY_HOME/log"

mkdir -p "$log_dir"
while true; do
  waited=0
  # Re-read relay.json each pass so a corrected listen address is picked up.
  until read -r host _ < <(relay_listen) && host_is_up "$host"; do
    [ $((waited % 60)) -eq 0 ] && echo "$(date +%Y-%m-%dT%H:%M:%S%z) waiting for $host to be assigned (Tailscale down?)" >>"$log_dir/stderr.log"
    sleep 5; waited=$((waited + 5))
  done
  "$relay" serve --config "$RELAY_CONFIG" >>"$log_dir/stdout.log" 2>>"$log_dir/stderr.log" || \
    echo "cmux-relay exited with status $?; restarting in ${delay}s" >&2
  sleep "$delay"
done
