# Guided playbooks: the ordered sequences that turn a box of tools into a
# procedure. Sourced by bin/netpack (the `p` menu key and the `playbook`
# subcommand) and restated in README.md, which tests/test_docs.py enforces.
# shellcheck shell=bash
#
# These are the sequences to run while the symptom is present. The value is the
# order and the reason for each step, so a step's "why" is not decoration —
# it is what tells the operator whether the result they just saw matters.
#
# Only single-machine sequences belong here. Throughput and bufferbloat
# procedures need a second machine running testsrv, so they stay in README.md
# as prose rather than pretending to be a runnable list.

# id | title
PLAYBOOK_ROWS=(
  "lan       | Wrong IP, or cannot reach the local LAN"
  "cable     | Errors or link flaps on a wired port"
  "wifi      | Wi-Fi is unreliable or slow"
  "wan       | 'Internet is down' but the link is up"
  "service   | A specific service is unreachable"
  "dropouts  | Intermittent dropouts or bursts"
  "multicast | Dante/NDI multicast missing at a position"
)

# id | command (with args, or bare to be prompted for) | why this step, now
PLAYBOOK_STEPS=(
  "lan       | linkstat              | Physical errors vs drops: rule out the cable and NIC before chasing addressing."
  "lan       | dhcpprobe             | One DHCP server or several. A second server is the classic wrong-IP cause. Use the VLAN sub-interface if the drop is tagged."
  "lan       | segscan               | LLDP neighbour, gateway, and an ARP sweep for duplicate IPs on the segment."
  "lan       | discover              | Name what is actually on the segment — media servers, TVs, printers, AV gear."

  "cable     | linkstat -t 30        | Establish that the fault is physical: errors, CRC and collisions growing, or the carrier flapping."
  "cable     | cabletest             | Measure the cable itself — which pair failed and how far along. This drops the link, so run it once the counters justify it."

  "wifi      | linkstat              | The current association: signal, bitrate, and whether the carrier is flapping."
  "wifi      | wifiscan              | Channel congestion and overlapping APs nearby. Briefly interrupts the association."

  "wan       | splitloss             | Split the fault domain: loss to the gateway is access-layer, loss beyond it is the uplink."
  "wan       | dnscheck              | Configured resolvers vs a public one. DNS failure reads as 'the internet is down' while ICMP stays clean."
  "wan       | webcheck              | Captive portal or HTTP/TLS interception — the case where ICMP and DNS both look fine."
  "wan       | mtucheck              | Path MTU black holes: small pings work, real transfers stall."
  "wan       | path3                 | Per-protocol path evidence when the earlier steps point beyond the gateway."

  "service   | portcheck             | REFUSED means the host is up and the service is down; TIMEOUT means filtered or unreachable."
  "service   | dnscheck              | Resolution for the service name itself — pass -n <name> if it differs from the default."
  "service   | path3                 | Path evidence toward the service once reachability is established."

  "dropouts  | ringcap               | Start the ring, reproduce the symptom, then Ctrl-C. Note the wall-clock time of the event."
  "dropouts  | linkstat -t 30        | Counter growth across the window you just captured."
  "dropouts  | splitloss -t 300      | A long window with a loss timeline, to place the dropouts against wall-clock time."

  "multicast | discover              | Is the device still advertising over mDNS at all?"
  "multicast | mcastcheck            | Choose recv, and use the group and port from Dante Controller or the NDI sender: is the flow arriving at this drop? If it is not, pair this with mcastcheck send from the source's switch position — that needs a second machine, so it is a README procedure."
)

# Procedures that need a second machine and so cannot be walked as a
# single-machine sequence. They are listed by `npk playbooks` anyway: an
# operator on site should see the whole field procedure set, not only the part
# the launcher can drive. The steps stay in README.md, which tests/test_docs.py
# checks still carries each title.
#
# title | what the second machine provides
PLAYBOOK_PROSE_ROWS=(
  "Prove local throughput or one-way UDP loss | a second machine running testsrv"
  "Prove latency and jitter under load (bufferbloat) | a planned load across the path under test"
  "Prove WAN uplink throughput | an iperf3 host you control across the WAN"
)

# -g so the tables survive being sourced from inside a function, as the bats
# suite does when it inspects them.
declare -gA PLAYBOOK_TITLE=()
declare -ga PLAYBOOK_IDS=()

# Reuses trim() from tools.sh, which the launcher sources first.
load_playbook_meta() {
  local row id title
  PLAYBOOK_IDS=()
  for row in "${PLAYBOOK_ROWS[@]}"; do
    IFS='|' read -r id title <<<"$row"
    id="$(trim "$id")"
    [[ -n "$id" ]] || continue
    PLAYBOOK_TITLE["$id"]="$(trim "$title")"
    PLAYBOOK_IDS+=("$id")
  done
}
load_playbook_meta

# Emit "command<TAB>why" rows for one playbook, in order.
playbook_steps() {
  local want=$1 row id cmd why
  for row in "${PLAYBOOK_STEPS[@]}"; do
    IFS='|' read -r id cmd why <<<"$row"
    [[ "$(trim "$id")" == "$want" ]] || continue
    printf '%s\t%s\n' "$(trim "$cmd")" "$(trim "$why")"
  done
}

playbook_title() {
  printf '%s\n' "${PLAYBOOK_TITLE[$1]:-}"
}

# Emit "title<TAB>requirement" rows for the procedures that need a second
# machine, in declaration order.
playbook_prose() {
  local row title need
  for row in "${PLAYBOOK_PROSE_ROWS[@]}"; do
    IFS='|' read -r title need <<<"$row"
    printf '%s\t%s\n' "$(trim "$title")" "$(trim "$need")"
  done
}
