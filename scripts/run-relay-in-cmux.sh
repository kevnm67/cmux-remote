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

# One runner only. cmux wraps every terminal in a tmux session that outlives a
# closed workspace, so a second runner can start while the first is still alive;
# the extra one must exit instead of fighting for the port.
if ! acquire_runner_lock; then
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) runner: another runner holds $RUNNER_LOCK; exiting" >>"$log_dir/stderr.log"
  exit 0
fi
child=""
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi
  release_runner_lock
}
trap cleanup EXIT
trap 'exit 143' HUP TERM INT

backoff="$delay"
while true; do
  # The watchdog dies with a stale cmux capability or a manual kill; this runner
  # lives inside cmux, so it can always bring the watchdog back (idempotent).
  "$here/ensure-relay.sh" >/dev/null 2>&1 || true
  waited=0
  # Re-read relay.json each pass so a corrected listen address is picked up.
  until read -r host port < <(relay_listen) && host_is_up "$host"; do
    [ $((waited % 60)) -eq 0 ] && echo "$(date +%Y-%m-%dT%H:%M:%S%z) waiting for $host to be assigned (Tailscale down?)" >>"$log_dir/stderr.log"
    sleep 5; waited=$((waited + 5))
  done
  # A held port is not a crash to loop on: clear an orphaned relay, otherwise
  # back off (capped) without launching a process that can only fail to bind.
  holder="$(port_holder "$port")"
  if [ -n "$holder" ]; then
    if [ "$(ps -o ppid= -p "$holder" 2>/dev/null | tr -d ' ')" = "1" ]; then
      echo "$(date +%Y-%m-%dT%H:%M:%S%z) runner: killing orphan pid $holder holding $host:$port" >>"$log_dir/stderr.log"
      kill "$holder" 2>/dev/null || true
    else
      echo "$(date +%Y-%m-%dT%H:%M:%S%z) runner: $host:$port held by pid $holder; retrying in ${backoff}s" >>"$log_dir/stderr.log"
      backoff=$((backoff * 2 > 60 ? 60 : backoff * 2))
    fi
    sleep "$backoff"
    continue
  fi
  backoff="$delay"
  "$relay" serve --config "$RELAY_CONFIG" >>"$log_dir/stdout.log" 2>>"$log_dir/stderr.log" &
  child=$!
  wait "$child" || echo "cmux-relay exited with status $?; restarting in ${delay}s" >&2
  child=""
  sleep "$delay"
done
