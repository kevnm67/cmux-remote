#!/usr/bin/env bash
# Run cmux-relay as a child of a cmux terminal and restart it if it exits.
#
# cmux's default socketControlMode (cmuxOnly) only accepts processes spawned
# inside cmux, so a launchd-started relay is rejected with "Access denied".
# Start this script from a cmux terminal (e.g. a dedicated workspace) instead
# of loading the launchd agent.
set -euo pipefail

relay="${CMUX_RELAY_BIN:-$HOME/.cmuxremote/bin/cmux-relay}"
config="${CMUX_RELAY_CONFIG:-$HOME/.cmuxremote/relay.json}"
log_dir="$HOME/.cmuxremote/log"
delay="${CMUX_RELAY_RESTART_DELAY:-2}"

mkdir -p "$log_dir"
while true; do
  "$relay" serve --config "$config" >>"$log_dir/stdout.log" 2>>"$log_dir/stderr.log" || \
    echo "cmux-relay exited with status $?; restarting in ${delay}s" >&2
  sleep "$delay"
done
