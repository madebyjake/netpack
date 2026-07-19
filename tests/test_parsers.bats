#!/usr/bin/env bats
# bats tests for pure bash parsers

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../../lib/netpack/parsers.sh
  source "${ROOT}/lib/netpack/parsers.sh"
  FIXTURES="${ROOT}/tests/fixtures"
}

@test "loss_pct parses integer percent" {
  run loss_pct "${FIXTURES}/ping_integer.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "20" ]
}

@test "loss_pct parses fractional percent" {
  run loss_pct "${FIXTURES}/ping_fractional.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "25.5" ]
}

@test "loss_pct parses zero loss" {
  run loss_pct "${FIXTURES}/ping_clean.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "summarize_final extracts last hop" {
  run summarize_final "${FIXTURES}/mtr_report.txt"
  [ "$status" -eq 0 ]
  [ "$output" = $'8.8.8.8\t4.0%\t19.5ms' ]
}
