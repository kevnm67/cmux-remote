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
