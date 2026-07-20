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

@test "rtt_stats parses min/avg/max/mdev" {
  run rtt_stats "${FIXTURES}/ping_clean.txt"
  [ "$status" -eq 0 ]
  [ "$output" = $'0.412\t0.891\t2.104\t0.301' ]
}

@test "rtt_stats fails without an rtt summary" {
  run rtt_stats "${FIXTURES}/mtr_report.txt"
  [ "$status" -ne 0 ]
}

@test "bucket_loss reports lossy 60s buckets with offsets" {
  # Fixture drops seqs 61-63 (bucket at offset 60) and 150 (offset 120);
  # the seq-10 DUP reply must count once.
  run bucket_loss "${FIXTURES}/ping_timeline.txt" 60
  [ "$status" -eq 0 ]
  [ "$output" = $'60\t3\t60\n120\t1\t60' ]
}

@test "bucket_loss is silent on a clean log" {
  run bucket_loss "${FIXTURES}/ping_timeline_clean.txt" 60
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "bucket_loss fails on a summary-only log" {
  # No -D reply lines to bucket; must fail rather than fabricate loss.
  run bucket_loss "${FIXTURES}/ping_clean.txt" 60
  [ "$status" -ne 0 ]
}
