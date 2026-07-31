#!/usr/bin/env bats
# Contracts for the menu splash: it must never leak ANSI into a pipe, and the
# opt-out must hold, so captured evidence and CI parsing stay animation-free.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  NETPACK_SOURCE_ONLY=1 source "${REPO}/bin/netpack"
}

@test "splash_play is silent when stdout is not a TTY" {
  run splash_play
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "splash_maybe honors the NETPACK_NO_SPLASH opt-out" {
  NETPACK_NO_SPLASH=1
  run splash_maybe
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "netpack list stays clean of splash escape codes" {
  # The splash draws only in the interactive menu; scripted output must be
  # byte-identical to what it was before the animation existed.
  run bash -c "NO_COLOR=1 '${REPO}/bin/netpack' list | grep -c $'\033'"
  [ "$output" = "0" ]
}

@test "pulse is silent when stderr is not a TTY" {
  # Ticker frames must never reach logs, pipes, or captured evidence.
  source "${REPO}/lib/netpack.sh"
  run pulse "waiting on something"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pulse_done still prints its final message without a TTY" {
  # The end state of a long run is evidence; only the animation is TTY-only.
  source "${REPO}/lib/netpack.sh"
  run pulse_done "server: 100/100 done"
  [ "$status" -eq 0 ]
  [ "$output" = "server: 100/100 done" ]
}
