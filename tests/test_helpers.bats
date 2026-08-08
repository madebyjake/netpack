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

# --- JSON evidence ------------------------------------------------------------

@test "take_dump_opt pulls --dump out in both spellings" {
  take_dump_opt -t 3 --dump /tmp/a.json host 80
  [ "$DUMP_PATH" = "/tmp/a.json" ]
  [ "${NP_ARGS[*]}" = "-t 3 host 80" ]
  take_dump_opt -t 3 --dump=/tmp/b.json host 80
  [ "$DUMP_PATH" = "/tmp/b.json" ]
  [ "${NP_ARGS[*]}" = "-t 3 host 80" ]
}

@test "take_dump_opt leaves an untouched argument list alone" {
  take_dump_opt -t 3 host 80 443
  [ -z "$DUMP_PATH" ]
  [ "${NP_ARGS[*]}" = "-t 3 host 80 443" ]
  take_dump_opt
  [ -z "$DUMP_PATH" ]
  [ "${#NP_ARGS[@]}" -eq 0 ]
}

@test "take_dump_opt rejects --dump without a path" {
  run take_dump_opt -t 3 --dump
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dump requires a path"* ]]
  run take_dump_opt --dump=
  [ "$status" -ne 0 ]
}

@test "dump_opt_str writes null for an undetermined value" {
  # An unknown egress interface is not the same as an empty one.
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_opt_str via ""
  dump_opt_str iface eth0
  dump_write "$out" portcheck 0 >/dev/null
  run python3 -c "
import json
d = json.load(open('${out}'))
print(d['via'] is None, d['iface'])"
  [ "$output" = "True eth0" ]
}

@test "dump_write produces the required keys" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_str gateway 192.168.1.1
  run dump_write "$out" splitloss 2
  [ "$status" -eq 0 ]
  # Path only compared loosely: TMPDIR may end in a slash, and the writer
  # normalizes the doubled separator out of the path it reports.
  [[ "$output" == "dump: "*"/d.json" ]]
  [ -f "$out" ]
  run python3 -c "import json;d=json.load(open('${out}'));print(d['tool'],d['assessment_code'],'timestamp' in d)"
  [ "$output" = "splitloss 2 True" ]
}

@test "dump keeps declared types apart" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_str answer 10
  dump_num count 10
  dump_bool interrupted false
  dump_write "$out" udp-loss 0 >/dev/null
  run python3 -c "
import json
d = json.load(open('${out}'))
print(repr(d['answer']), repr(d['count']), repr(d['interrupted']))"
  [ "$output" = "'10' 10 False" ]
}

@test "an unmeasured number dumps as null, not zero" {
  # A target that could not be measured must not read as clean.
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_num wan_loss_pct ""
  dump_write "$out" splitloss 1 >/dev/null
  run python3 -c "import json;print(json.load(open('${out}'))['wan_loss_pct'] is None)"
  [ "$output" = "True" ]
}

@test "dump_row builds an array of objects in order" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_row targets s:name=gateway n:loss_pct=0
  dump_row targets s:name=wan n:loss_pct=4.2
  dump_write "$out" splitloss 3 >/dev/null
  run python3 -c "
import json
t = json.load(open('${out}'))['targets']
print([r['name'] for r in t], [r['loss_pct'] for r in t])"
  [ "$output" = "['gateway', 'wan'] [0, 4.2]" ]
}

@test "dump_row values may contain the delimiters" {
  # A BPF filter or an rdata field carries ':' and '='; only the first of each
  # is a delimiter.
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_row probes "s:url=http://example.com/x?a=1&b=2" "s:note=host:port"
  dump_write "$out" webcheck 0 >/dev/null
  run python3 -c "
import json
r = json.load(open('${out}'))['probes'][0]
print(r['url']); print(r['note'])"
  [ "${lines[0]}" = "http://example.com/x?a=1&b=2" ]
  [ "${lines[1]}" = "host:port" ]
}

@test "dump escapes values that would break hand-rolled JSON" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_str filter 'tcp port 53 and "quoted" \back'
  dump_write "$out" ringcap 0 >/dev/null
  run python3 -c "import json;print(json.load(open('${out}'))['filter'])"
  [ "$output" = 'tcp port 53 and "quoted" \back' ]
}

@test "dump_begin clears fields from a previous payload" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_str stale yes
  dump_begin
  dump_str fresh yes
  dump_write "$out" doctor 0 >/dev/null
  run python3 -c "import json;d=json.load(open('${out}'));print('stale' in d, d.get('fresh'))"
  [ "$output" = "False yes" ]
}

@test "dump_write reports a bad number instead of writing junk" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  dump_num loss_pct "n/a"
  run dump_write "$out" splitloss 0
  [ "$status" -ne 0 ]
  [ ! -f "$out" ]
}

@test "dump_write creates parent directories" {
  local out="${STUB_DIR}/nested/deeper/d.json"
  dump_begin
  dump_str tool_ran yes
  run dump_write "$out" doctor 0
  [ "$status" -eq 0 ]
  [ -f "$out" ]
}

@test "an empty payload still records the required keys" {
  local out="${STUB_DIR}/d.json"
  dump_begin
  run dump_write "$out" doctor 0
  [ "$status" -eq 0 ]
  run python3 -c "import json;d=json.load(open('${out}'));print(sorted(d))"
  [ "$output" = "['assessment_code', 'timestamp', 'tool']" ]
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

# --- interruption -------------------------------------------------------------
#
# catch_int keeps a tool alive through Ctrl-C so it can still print its report.
# A signal cannot be delivered realistically inside bats, so these drive the
# flag the trap sets; the trap wiring itself is asserted separately.

@test "interrupted is false until the flag is set" {
  catch_int
  run interrupted
  [ "$status" -ne 0 ]
}

@test "a real SIGINT sets the flag instead of killing the tool" {
  # Delivered for real rather than simulated: the whole point of the helper is
  # that the shell survives the signal, which only an actual SIGINT proves.
  run bash -c "
    source '${REPO}/lib/netpack.sh'
    catch_int
    kill -INT \$\$
    interrupted && echo CAUGHT
    echo STILL_RUNNING
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"CAUGHT"* ]]
  [[ "$output" == *"STILL_RUNNING"* ]]
}

@test "catch_int clears a flag left set by an earlier run" {
  NP_INTERRUPTED=1
  catch_int
  run interrupted
  [ "$status" -ne 0 ]
}

@test "release_int restores default SIGINT handling" {
  run bash -c "
    source '${REPO}/lib/netpack.sh'
    catch_int
    release_int
    kill -INT \$\$
    echo SHOULD_NOT_REACH
  "
  [ "$status" -eq 130 ]
  [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "finish_with returns its argument on a completed run" {
  catch_int
  run bash -c "source '${REPO}/lib/netpack.sh'; catch_int; finish_with 3"
  [ "$status" -eq 3 ]
  [[ "$output" == *"finished:"* ]]
}

@test "finish_with downgrades to 130 once interrupted, and still closes the report" {
  run bash -c "source '${REPO}/lib/netpack.sh'; catch_int; NP_INTERRUPTED=1; finish_with 2"
  [ "$status" -eq 130 ]
  # The report still has to close: the exit status changes, the evidence does not.
  [[ "$output" == *"finished:"* ]]
}

# --- locale ------------------------------------------------------------------
#
# awk and printf format decimals per LC_NUMERIC. Under a comma-decimal locale a
# loss of 1.5% became "1,5", which classify_loss_set read as 1 and reported as
# clean, and which dump_num rejected as not a number.

# Run SCRIPT under LOCALE with the inner shell's stderr discarded. A runner
# without de_DE installed makes bash warn "setlocale: cannot change locale" at
# startup, before the script runs, so the redirect belongs here rather than
# inside SCRIPT — and bats folds stderr into $output.
#
# The locale falling back to C on such a runner costs nothing: the first test
# asserts the export itself, which holds either way.
in_locale() {
  env LC_ALL="$1" bash -c "$2" 2>/dev/null
}

@test "sourcing netpack.sh pins LC_ALL to C" {
  run in_locale de_DE.UTF-8 "source '${REPO}/lib/netpack.sh'; printf '%s' \"\$LC_ALL\""
  [ "$output" = "C" ]
}

@test "decimal formatting stays dot-separated under a comma-decimal locale" {
  run in_locale de_DE.UTF-8 \
    "source '${REPO}/lib/netpack.sh'; awk 'BEGIN { printf \"%.1f\", 1.5 }'"
  [ "$output" = "1.5" ]
}

@test "loss above the threshold is not classified as clean under that locale" {
  run in_locale de_DE.UTF-8 "
    source '${REPO}/lib/netpack/parsers.sh'
    source '${REPO}/lib/netpack.sh'
    loss=\"\$(awk -v f=3 -v c=200 'BEGIN { printf \"%.1f\", f * 100 / c }')\"
    classify_loss_set 1 \"\$loss\""
  # 3 lost of 200 is 1.5%, over the 1% threshold.
  [ "$output" = "all" ]
}

@test "a locale-formatted decimal still serializes as a JSON number" {
  run in_locale de_DE.UTF-8 "
    source '${REPO}/lib/netpack.sh'
    dump_begin
    dump_num loss_pct \"\$(awk 'BEGIN { printf \"%.1f\", 1.5 }')\"
    dump_write '${BATS_TEST_TMPDIR:-/tmp}/locale.json' locmt 0"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not a number"* ]]
}
