# Shared tool metadata for netpack: which tools want root, what traffic they
# generate, and how they are described. Sourced by bin/netpack (menu, list,
# help) and bin/doctor (readiness report) so those views cannot drift apart.
# shellcheck shell=bash

# Tool metadata — one row per tool, and the only place these facts live. The
# menu, `list` and `help` all render from here, so a new tool needs one row
# below plus its name in SECTIONS; nothing else.
#
#   root     (blank)  runs unprivileged
#            sudo?    better with root; the menu offers it at launch
#            sudo     needs root to do anything useful; the menu elevates
#   traffic  (blank)  passive or read-only
#            probe    light diagnostic traffic
#            loud     heavy traffic, active probing, or link disruption —
#                     needs an impact line
#   impact   consequence shown at the point of run; required for loud, else blank
#
# Columns are pipe-separated: name | root | traffic | description | impact
TOOL_ROWS=(
  "doctor     |       |       | Dependency and readiness checks               |"
  "dhcpprobe  | sudo  | probe | DHCP servers on the local segment             |"
  "linkstat   |       |       | Link counters; physical vs congestion signals |"
  "cabletest  | sudo  | loud  | TDR cable test: per-pair faults and distance  | drops the link on the interface while it measures; planned tests only"
  "segscan    | sudo? | loud  | Segment inventory (LLDP, gateway, ARP)        | sweeps every address on the subnet — can read as recon; planned tests only"
  "wifiscan   | sudo  | probe | Wi-Fi AP survey and channel usage             |"
  "discover   |       | probe | SSDP/mDNS service discovery                   |"
  "splitloss  |       | probe | Concurrent gateway vs WAN loss comparison     |"
  "dnscheck   |       | probe | Configured vs public DNS resolver comparison  |"
  "webcheck   |       | probe | Captive portal / HTTP + TLS interception check|"
  "portcheck  |       | probe | TCP service reachability by port              |"
  "mtucheck   |       | probe | Path MTU probe to gateway and WAN             |"
  "path3      | sudo? | loud  | mtr over ICMP, UDP, and TCP                   | sends continuous ICMP, UDP, and TCP probes along the path; planned tests only"
  "udp-loss   |       | probe | UDP loss via DNS queries with real replies    |"
  "mcastcheck |       | probe | Multicast delivery (AV, IPTV, sACN)           |"
  "ringcap    | sudo  |       | Rotating packet capture ring buffer           |"
  "testsrv    | sudo? | loud  | iperf3 server with timed firewall open        | opens a firewall port and serves full-rate iperf3 load; planned tests only"
  "testcli    |       | loud  | iperf3 client companion to testsrv            | drives full-rate iperf3 load at the target; planned tests only"
)

# -g so the tables stay global even when this file is sourced from a function
# (the bats suite does exactly that to inspect the metadata).
declare -gA TOOL_ROOT=() TOOL_TRAFFIC=() TOOL_DESC=() TOOL_IMPACT=()

# Strip the padding that keeps TOOL_ROWS readable in the source.
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# The TOOL_* tables are this file's public surface: sourcing scripts read them
# directly (bin/netpack's tool_row, bin/doctor's tool_header), which shellcheck
# cannot see from here.
# shellcheck disable=SC2034
load_tool_meta() {
  local row name root traffic desc impact
  for row in "${TOOL_ROWS[@]}"; do
    IFS='|' read -r name root traffic desc impact <<<"$row"
    name="$(trim "$name")"
    [[ -n "$name" ]] || continue
    TOOL_ROOT["$name"]="$(trim "$root")"
    TOOL_TRAFFIC["$name"]="$(trim "$traffic")"
    TOOL_DESC["$name"]="$(trim "$desc")"
    TOOL_IMPACT["$name"]="$(trim "${impact:-}")"
  done
}
load_tool_meta

describe() {
  printf '%s\n' "${TOOL_DESC[$1]:-}"
}

# True for tools with any root affinity; needs_root tools auto-elevate in the
# menu, the rest are offered sudo at launch. Rendered as the sudo column.
wants_root() {
  [[ -n "${TOOL_ROOT[$1]:-}" ]]
}

# True only for tools that cannot do anything useful without root.
needs_root() {
  [[ "${TOOL_ROOT[$1]:-}" == "sudo" ]]
}

# One-line consequence notice for loud tools, shown at the point of run.
impact_note() {
  printf '%s\n' "${TOOL_IMPACT[$1]:-}"
}

# Tools that can write JSON evidence with --dump. capture_run consults this to
# collect JSON alongside the terminal log while -o capture is active.
TOOL_JSON=(cabletest dhcpprobe discover linkstat mcastcheck)

supports_dump() {
  local t
  for t in "${TOOL_JSON[@]}"; do
    if [[ "$t" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}
