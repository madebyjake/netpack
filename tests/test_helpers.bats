#!/usr/bin/env bats
# Contracts for the shared bash helpers in lib/netpack.sh.
#
# parsers.sh was covered; the helpers that wrap it were not, so the argument
# validation and interface attribution every tool depends on went unchecked.
#
# The route and address helpers shell out to ip. A stub on PATH feeds them the
# captured fixtures, so they run on a machine without iproute2.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  FIXTURES="${REPO}/tests/fixtures"
  # shellcheck source=../lib/netpack/parsers.sh
  source "${REPO}/lib/netpack/parsers.sh"
  # shellcheck source=../lib/netpack.sh
  source "${REPO}/lib/netpack.sh"
  STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netpack-stub.XXXXXX")"
  PATH="${STUB_DIR}:${PATH}"
}

teardown() {
  [ -n "${STUB_DIR:-}" ] && rm -rf "$STUB_DIR"
}

# stub_ip FILE — make `ip` print FILE regardless of arguments.
stub_ip() {
  cat >"${STUB_DIR}/ip" <<EOF
#!/usr/bin/env bash
cat "$1"
EOF
  chmod +x "${STUB_DIR}/ip"
}

# stub_ip_empty — make `ip` fail with no output, as it does with no route.
stub_ip_empty() {
  cat >"${STUB_DIR}/ip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_DIR}/ip"
}

# --- numeric validation -------------------------------------------------------

@test "is_uint accepts digits and rejects everything else" {
  for good in 0 1 60 000 1500; do
    run is_uint "$good"
    [ "$status" -eq 0 ] || { echo "rejected: $good"; return 1; }
  done
  for bad in "" -1 1.5 60s abc " 1" "1 "; do
    run is_uint "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "require_uint enforces the lower bound" {
  run require_uint duration 0 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid duration: 0"* ]]
  run require_uint duration 1 1
  [ "$status" -eq 0 ]
}

@test "require_uint enforces the upper bound when given" {
  run require_uint port 65536 1 65535
  [ "$status" -ne 0 ]
  run require_uint port 65535 1 65535
  [ "$status" -eq 0 ]
  run require_uint count 99999 1
  [ "$status" -eq 0 ]
}

@test "require_uint reads leading zeros as decimal, not octal" {
  # 08 and 09 are invalid octal; without 10# the bounds check would error out
  # instead of accepting a valid value.
  run require_uint streams 08 1 128
  [ "$status" -eq 0 ]
  run require_uint streams 09 1 128
  [ "$status" -eq 0 ]
  run require_uint duration 0120 1
  [ "$status" -eq 0 ]
}

@test "require_uint rejects non-numeric values" {
  run require_uint duration 60s 1
  [ "$status" -ne 0 ]
  run require_uint duration "" 1
  [ "$status" -ne 0 ]
}

# --- argument and dependency guards -------------------------------------------

@test "no_extra_args accepts nothing and rejects any leftover" {
  run no_extra_args
  [ "$status" -eq 0 ]
  run no_extra_args 8.8.8.8
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument: 8.8.8.8"* ]]
}

@test "no_extra_args names the first leftover argument" {
  run no_extra_args first second
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument: first"* ]]
}

@test "die writes to stderr and exits 1" {
  run bash -c "source '${REPO}/lib/netpack.sh'; die 'boom' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run bash -c "source '${REPO}/lib/netpack.sh'; die 'boom' 2>&1"
  [[ "$output" == *"error: boom"* ]]
}

@test "require_cmd passes for present commands and dies for missing ones" {
  run require_cmd bash
  [ "$status" -eq 0 ]
  run require_cmd definitely-not-a-real-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in PATH"* ]]
}

@test "validate_iface rejects names outside the permitted charset" {
  # Rejected on the pattern, before the /sys lookup, so this holds anywhere.
  for bad in "eth 0" "eth/0" 'eth;rm' 'eth$0'; do
    run validate_iface "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *"invalid interface name"* ]] || { echo "wrong error: $output"; return 1; }
  done
}

@test "validate_iface reports a well-formed name that does not exist" {
  run validate_iface "definitely-not-an-iface"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interface not found"* ]]
}

# --- version and paths --------------------------------------------------------

@test "netpack_version reads the single source of truth" {
  run netpack_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  grep -q "__version__ = \"${output}\"" "${REPO}/lib/netpack/__init__.py"
}

@test "netpack_root and netpack_bin resolve to the repo" {
  run netpack_root
  [ "$output" = "$REPO" ]
  run netpack_bin
  [ "$output" = "${REPO}/bin" ]
}

@test "private_tmpdir creates an owner-only directory" {
  local d
  d="$(private_tmpdir bats)"
  [ -d "$d" ]
  [[ "$d" == *"/bats."* ]]
  rm -rf "$d"
}

# --- report shape -------------------------------------------------------------

@test "header names the tool and an ISO-8601 local timestamp" {
  run header linkstat
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^linkstat\ —\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
}

@test "finished closes with a matching timestamp" {
  run finished
  [[ "$output" =~ ^finished:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
}

@test "timestamp_local punctuates the offset, matching the Python helper" {
  run timestamp_local
  [[ "$output" =~ [+-][0-9]{2}:[0-9]{2}$ ]]
}

@test "verdict renders as ASSESSMENT with an optional next step" {
  run verdict "both targets were clean."
  [ "$output" = "--
ASSESSMENT: both targets were clean." ]
  run verdict "loss to gateway." "Inspect the local switch."
  [[ "$output" == *"Next: Inspect the local switch."* ]]
}

@test "section prints a blank line then the delimited title" {
  run section "access points"
  [ "$output" = "
=== access points ===" ]
}

@test "note and warning carry their prefixes" {
  run note "multi-homed"
  [ "$output" = "note: multi-homed" ]
  run warning "clock skew"
  [ "$output" = "warning: clock skew" ]
}

@test "report helpers emit no escape codes off a TTY" {
  # Redirected evidence must stay plain text.
  run bash -c "source '${REPO}/lib/netpack.sh'; header t; section s; note n; warning w; verdict v; finished"
  [[ "$output" != *$'\033'* ]]
}

@test "color_status returns bare tokens off a TTY" {
  run color_status ok
  [ "$output" = "OK" ]
  run color_status bad
  [ "$output" = "MISSING" ]
  run color_status warn "REDIRECT"
  [ "$output" = "REDIRECT" ]
  run color_status ok "PASS"
  [ "$output" = "PASS" ]
}

@test "color_loss_pct treats the 1 percent threshold as clean" {
  run color_loss_pct 1
  [ "$output" = "1%" ]
  run color_loss_pct 1.1
  [ "$output" = "1.1%" ]
  run color_loss_pct 0
  [ "$output" = "0%" ]
}

# --- route and address helpers ------------------------------------------------

@test "default_gateway picks the preferred-metric default route" {
  stub_ip "${FIXTURES}/ip_route_default.txt"
  run default_gateway
  [ "$output" = "10.9.8.1" ]
}

@test "iface_gateway reads the dev-filtered form" {
  stub_ip "${FIXTURES}/ip_route_default_dev.txt"
  run iface_gateway wlan0
  [ "$output" = "192.168.4.1" ]
}

@test "default_gateway is empty when there is no default route" {
  stub_ip_empty
  run default_gateway
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "route_iface names the egress interface" {
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run route_iface 1.1.1.1
  [ "$output" = "eno1" ]
}

@test "route_iface is empty and succeeds for an unroutable target" {
  # It runs inside $( ) under set -e; a failure here would kill the tool
  # mid-report rather than reading as "unknown".
  stub_ip_empty
  run route_iface 203.0.113.1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "via_for resolves IPv4 literals only" {
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run via_for 1.1.1.1
  [ "$output" = "eno1" ]
  # A hostname must not be resolved here: that would stall the tools whose job
  # is to diagnose broken DNS.
  run via_for example.com
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "global_ifaces emits one row per global address" {
  stub_ip "${FIXTURES}/ip_addr_global.txt"
  run global_ifaces
  [ "$output" = "eno1	10.24.10.157/23
wt0	100.100.8.136/24
wt0	100.100.9.10/24" ]
}

@test "iface_ipv4 returns the first address without its prefix" {
  stub_ip "${FIXTURES}/ip_addr_global.txt"
  run iface_ipv4 eno1
  [ "$output" = "10.24.10.157" ]
}

@test "multihomed_note names every addressed interface and the egress" {
  stub_ip "${FIXTURES}/ip_addr_global.txt"
  run multihomed_note eno1
  [[ "$output" == *"multi-homed"* ]]
  [[ "$output" == *"eno1 10.24.10.157/23"* ]]
  [[ "$output" == *"wt0 100.100.8.136/24"* ]]
  [[ "$output" == *"probes leave via eno1"* ]]
}

@test "multihomed_note says probes follow the routing table with no egress" {
  stub_ip "${FIXTURES}/ip_addr_global.txt"
  run multihomed_note ""
  [[ "$output" == *"probes follow the routing table"* ]]
}

@test "multihomed_note appends the caller's hint" {
  stub_ip "${FIXTURES}/ip_addr_global.txt"
  run multihomed_note eno1 "pass -i IFACE to target another uplink"
  [[ "$output" == *"— pass -i IFACE to target another uplink"* ]]
}

@test "uplink_unroutable is silent when the policy route sends SRC out IFACE" {
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run uplink_unroutable eno1 10.24.10.157 1.1.1.1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uplink_unroutable names the interface the kernel would use instead" {
  # Binding sets the source address, but without an ip rule the replies come
  # back on the other uplink and rp_filter eats them, reading as loss.
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run uplink_unroutable wlan0 192.168.4.20 1.1.1.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no policy route sends 192.168.4.20 out wlan0"* ]]
  [[ "$output" == *"kernel would use eno1"* ]]
}

@test "uplink_unroutable reports no route when the target is unreachable" {
  stub_ip_empty
  run uplink_unroutable eth0 10.0.0.1 203.0.113.1
  [[ "$output" == *"kernel would use no route"* ]]
}

@test "require_uplink dies rather than binding a probe that cannot answer" {
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run bash -c "
    source '${REPO}/lib/netpack/parsers.sh'
    source '${REPO}/lib/netpack.sh'
    validate_iface() { :; }
    iface_ipv4() { echo 192.168.4.20; }
    require_uplink wlan0 1.1.1.1 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot probe via wlan0"* ]]
  [[ "$output" == *"add an ip rule"* ]]
}

@test "require_uplink prints the source address when the binding is honest" {
  stub_ip "${FIXTURES}/ip_route_get.txt"
  run bash -c "
    source '${REPO}/lib/netpack/parsers.sh'
    source '${REPO}/lib/netpack.sh'
    validate_iface() { :; }
    iface_ipv4() { echo 10.24.10.157; }
    require_uplink eno1 1.1.1.1
  "
  [ "$status" -eq 0 ]
  [ "$output" = "10.24.10.157" ]
}

@test "require_uplink dies when the interface has no address to bind" {
  run bash -c "
    source '${REPO}/lib/netpack/parsers.sh'
    source '${REPO}/lib/netpack.sh'
    validate_iface() { :; }
    iface_ipv4() { echo; }
    require_uplink eth9 1.1.1.1 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"no IPv4 address on eth9"* ]]
}

@test "multihomed_note is silent on a single-homed host" {
  # Two rows for one interface is still single-homed; the note must count
  # distinct interfaces, not addresses.
  printf '2: eno1    inet 10.0.0.1/24 scope global eno1\n2: eno1    inet 10.0.0.2/24 scope global secondary eno1\n' \
    >"${STUB_DIR}/one.txt"
  stub_ip "${STUB_DIR}/one.txt"
  run multihomed_note eno1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
