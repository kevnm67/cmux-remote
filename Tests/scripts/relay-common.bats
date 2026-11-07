#!/usr/bin/env bats

setup() {
  export CMUX_RELAY_HOME="$BATS_TEST_TMPDIR"
  export CMUX_RELAY_CONFIG="$BATS_TEST_TMPDIR/relay.json"
  # shellcheck disable=SC1091
  . "$BATS_TEST_DIRNAME/../../scripts/relay-common.sh"
}

@test "relay_listen prints host and port only" {
  echo '{"listen":"100.64.1.2:4399","token":"SECRET"}' >"$CMUX_RELAY_CONFIG"
  run relay_listen
  [ "$status" -eq 0 ]
  [ "$output" = "100.64.1.2 4399" ]
}

@test "host_is_up accepts 0.0.0.0 and loopback, rejects an unassigned address" {
  host_is_up 0.0.0.0
  host_is_up 127.0.0.1
  run host_is_up 100.64.255.254
  [ "$status" -ne 0 ]
}

@test "runner revives the watchdog through ensure-relay before every relay start" {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$BATS_TEST_DIRNAME/../../scripts/run-relay-in-cmux.sh" "$BATS_TEST_DIRNAME/../../scripts/relay-common.sh" "$bin/"
  printf '#!/bin/sh\necho ensure >>"%s/ensure.log"\n' "$BATS_TEST_TMPDIR" >"$bin/ensure-relay.sh"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/fake-relay"
  chmod +x "$bin/ensure-relay.sh" "$BATS_TEST_TMPDIR/fake-relay"
  echo '{"listen":"0.0.0.0:4399"}' >"$CMUX_RELAY_CONFIG"
  CMUX_RELAY_BIN="$BATS_TEST_TMPDIR/fake-relay" CMUX_RELAY_RESTART_DELAY=0 \
    timeout 3 bash "$bin/run-relay-in-cmux.sh" || true
  [ "$(wc -l <"$BATS_TEST_TMPDIR/ensure.log")" -ge 2 ]
}

mk_runner() {
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$BATS_TEST_DIRNAME/../../scripts/run-relay-in-cmux.sh" "$BATS_TEST_DIRNAME/../../scripts/relay-common.sh" "$bin/"
  printf '#!/bin/sh\nexit 0\n' >"$bin/ensure-relay.sh"
  printf '#!/bin/sh\necho started >>"%s/relay.runs"\nexec sleep 30\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/fake-relay"
  chmod +x "$bin/ensure-relay.sh" "$BATS_TEST_TMPDIR/fake-relay"
}

@test "acquire_runner_lock refuses a live owner and retakes a dead one" {
  acquire_runner_lock
  [ "$(cat "$RUNNER_LOCK/pid")" = "$$" ]
  sleep 30 & live=$!
  echo "$live" >"$RUNNER_LOCK/pid"
  run acquire_runner_lock
  [ "$status" -eq 1 ]
  kill "$live"; wait "$live" 2>/dev/null || true
  acquire_runner_lock
  [ "$(cat "$RUNNER_LOCK/pid")" = "$$" ]
  release_runner_lock
  [ ! -d "$RUNNER_LOCK" ]
}

@test "a second runner exits at once and starts no relay" {
  mk_runner
  echo '{"listen":"0.0.0.0:47398"}' >"$CMUX_RELAY_CONFIG"
  export CMUX_RELAY_BIN="$BATS_TEST_TMPDIR/fake-relay" CMUX_RELAY_RESTART_DELAY=0
  bash "$bin/run-relay-in-cmux.sh" & first=$!
  sleep 1
  run timeout 5 bash "$bin/run-relay-in-cmux.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/relay.runs")" -eq 1 ]
  grep -q "another runner holds" "$BATS_TEST_TMPDIR/log/stderr.log"
  kill "$first"; wait "$first" 2>/dev/null || true
  sleep 0.5
  [ ! -d "$RUNNER_LOCK" ]
  [ -z "$(pgrep -f "$BATS_TEST_TMPDIR/fake-relay" || true)" ]
}

@test "a held port is backed off, not crash-looped" {
  mk_runner
  port=47399
  python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1',$port)); s.listen(1); time.sleep(8)" & holder=$!
  sleep 1
  echo "{\"listen\":\"127.0.0.1:$port\"}" >"$CMUX_RELAY_CONFIG"
  CMUX_RELAY_BIN="$BATS_TEST_TMPDIR/fake-relay" CMUX_RELAY_RESTART_DELAY=1 \
    timeout 4 bash "$bin/run-relay-in-cmux.sh" || true
  kill "$holder" 2>/dev/null || true
  [ ! -f "$BATS_TEST_TMPDIR/relay.runs" ]
  grep -q "held by pid" "$BATS_TEST_TMPDIR/log/stderr.log"
  [ "$(grep -c "held by pid" "$BATS_TEST_TMPDIR/log/stderr.log")" -le 3 ]
}

@test "ensure-relay does not recreate a workspace created within the grace window" {
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cp "$BATS_TEST_DIRNAME/../../scripts/ensure-relay.sh" "$BATS_TEST_DIRNAME/../../scripts/relay-common.sh" "$bin/"
  printf '#!/bin/sh\necho "$@" >>"%s/cmux.calls"\n' "$BATS_TEST_TMPDIR" >"$bin/cmux"
  chmod +x "$bin/cmux"
  touch "$BATS_TEST_TMPDIR/workspace.created"
  CMUX_BUNDLED_CLI_PATH="$bin/cmux" CMUX_RELAY_SETTLE=0 run bash "$bin/ensure-relay.sh" --no-watchdog
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/cmux.calls" ]
}
