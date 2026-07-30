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

# --- segscan -----------------------------------------------------------------

@test "arp_duplicates flags only IPs claimed by two or more MACs" {
  # .10 has two MACs and .30 has three: real conflicts. .20 appears twice with
  # the same MAC in different case (an arp-scan retry), which is one host.
  run arp_duplicates "${FIXTURES}/arp_scan_dup.txt"
  [ "$status" -eq 0 ]
  [ "$output" = $'192.168.1.10\n192.168.1.30' ]
}

@test "arp_duplicates is silent on a sweep with no conflicts" {
  run arp_duplicates "${FIXTURES}/ping_clean.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- wifiscan ----------------------------------------------------------------

@test "parse_iw_scan derives channel and encryption per BSS" {
  run parse_iw_scan "${FIXTURES}/iw_scan.txt"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'aa:bb:cc:00:00:01\t1\t-42.00\twpa2/3\tVenueWiFi' ]
  # capability without Privacy and no RSN/WPA is an open network.
  [ "${lines[1]}" = $'aa:bb:cc:00:00:02\t6\t-67.00\topen\tGuestOpen' ]
  # Privacy alone, with no RSN or WPA element, is WEP.
  [ "${lines[2]}" = $'aa:bb:cc:00:00:03\t6\t-71.00\twep\tOldWEP' ]
  [ "${lines[3]}" = $'aa:bb:cc:00:00:04\t36\t-55.00\twpa2/3\tVenueWiFi-5G' ]
  # An empty SSID line leaves the hidden placeholder in place.
  [ "${lines[4]}" = $'aa:bb:cc:00:00:05\t6\t-80.00\twpa\t<hidden>' ]
}

@test "parse_iw_scan labels 6 GHz by band, keeping it out of the histograms" {
  # 6 GHz channel numbers collide with 2.4/5 GHz numbering, so they must not
  # appear as an integer channel that a histogram would bucket.
  run parse_iw_scan "${FIXTURES}/iw_scan.txt"
  [ "${lines[5]}" = $'aa:bb:cc:00:00:06\t6G\t-60.00\twpa2/3\tSixGig' ]
}

@test "wifi_busiest_channel picks the most crowded channel in the band" {
  parse_iw_scan "${FIXTURES}/iw_scan.txt" > "${BATS_TEST_TMPDIR}/aps.tsv"
  run wifi_busiest_channel "${BATS_TEST_TMPDIR}/aps.tsv" 1 14
  [ "$output" = "6 3" ]
  # 5 GHz has a single AP on 36; the 6 GHz BSS is excluded by its band label.
  run wifi_busiest_channel "${BATS_TEST_TMPDIR}/aps.tsv" 32 177
  [ "$output" = "36 1" ]
}

@test "wifi_busiest_channel prints nothing when the band is empty" {
  parse_iw_scan "${FIXTURES}/iw_scan.txt" > "${BATS_TEST_TMPDIR}/aps.tsv"
  run wifi_busiest_channel "${BATS_TEST_TMPDIR}/aps.tsv" 100 140
  [ "$output" = "" ]
}

@test "wifi_channel_hist lists occupied channels in ascending order" {
  parse_iw_scan "${FIXTURES}/iw_scan.txt" > "${BATS_TEST_TMPDIR}/aps.tsv"
  run wifi_channel_hist "${BATS_TEST_TMPDIR}/aps.tsv" 1 14
  [ "${lines[0]}" = "  ch 1   1" ]
  [ "${lines[1]}" = "  ch 6   3" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- webcheck ----------------------------------------------------------------

@test "classify_http_probe names the portal evidence" {
  run classify_http_probe 204 204 "" ""
  [ "$output" = "ok" ]
  # Wrong status with a redirect target: that target is the portal.
  run classify_http_probe 302 204 "" "" "http://portal.example/login"
  [ "$output" = "redirect" ]
  # Wrong status, no redirect to point at.
  run classify_http_probe 403 204 "" ""
  [ "$output" = "status" ]
  # Right status, wrong body: interception that preserved the status code.
  run classify_http_probe 200 200 "loginhere" "success"
  [ "$output" = "body" ]
}

# --- mtucheck ----------------------------------------------------------------

@test "mtu_total adds the IPv4 and ICMP headers, and keeps zero as zero" {
  run mtu_total 1472
  [ "$output" = "1500" ]
  run mtu_total 0
  [ "$output" = "0" ]
  run mtu_total ""
  [ "$output" = "0" ]
}

@test "classify_mtu separates a small MTU from blocked probes" {
  run classify_mtu 1460 1500 1500
  [ "$output" = "ok" ]
  run classify_mtu 1460 1500 1400
  [ "$output" = "reduced" ]
  # One path answering and the other not is still an MTU finding.
  run classify_mtu 1460 1500 0
  [ "$output" = "reduced" ]
  # Neither answering is ICMP filtering, not a measured MTU.
  run classify_mtu 1460 0 0
  [ "$output" = "blocked" ]
}
