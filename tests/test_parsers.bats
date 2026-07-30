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

@test "parse_resolvectl_dns pairs each server with its link" {
  # Trims the DoT pin on 1.1.1.1 and the link scope on fe80::1; the link with
  # no servers (enp0s20f0u2u1c2) contributes no row.
  run parse_resolvectl_dns "${FIXTURES}/resolvectl_dns.txt"
  [ "$status" -eq 0 ]
  [ "$output" = $'eno1\t8.8.8.8\neno1\t1.1.1.1\nwt0\t100.100.8.136\ntun0\tfe80::1\ntun0\t8.8.8.8' ]
}

@test "parse_resolvectl_dns ignores output with no link lines" {
  output="$(printf 'Global:\n' | parse_resolvectl_dns)"
  [ "$output" = "" ]
}

@test "parse_resolv_conf reads nameservers and skips comments" {
  run parse_resolv_conf "${FIXTURES}/resolv_conf_real.txt"
  [ "$status" -eq 0 ]
  [ "$output" = $'192.168.1.1\n8.8.8.8\n192.168.1.1' ]
}

@test "parse_resolv_conf reads the systemd-resolved stub" {
  run parse_resolv_conf "${FIXTURES}/resolv_conf_stub.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.53" ]
}

@test "is_stub_addr recognizes loopback forwarders" {
  run is_stub_addr 127.0.0.53
  [ "$status" -eq 0 ]
  run is_stub_addr 127.0.0.1
  [ "$status" -eq 0 ]
  run is_stub_addr ::1
  [ "$status" -eq 0 ]
}

@test "is_stub_addr does not flag real upstreams" {
  run is_stub_addr 8.8.8.8
  [ "$status" -ne 0 ]
  run is_stub_addr 192.168.1.1
  [ "$status" -ne 0 ]
}

@test "dedupe_by_value keeps the first row per server" {
  output="$(printf 'eno1\t8.8.8.8\nwt0\t8.8.8.8\nwt0\t9.9.9.9\n' | dedupe_by_value)"
  [ "$output" = $'eno1\t8.8.8.8\nwt0\t9.9.9.9' ]
}
