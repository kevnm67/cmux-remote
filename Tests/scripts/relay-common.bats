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
