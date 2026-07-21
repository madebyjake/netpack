# netpack (npk)

Network tools for on-site troubleshooting and evidence collection.

## Setup

```bash
# Clone
git clone https://github.com/madebyjake/netpack.git ~/netpack

# Persist PATH (bash; use ~/.zshrc on zsh)
echo 'export PATH="$HOME/netpack/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Dependencies (Debian; Python >= 3.10 required)
sudo apt update
sudo apt install python3 python3-scapy iproute2 iputils-ping dnsutils \
  ethtool iw mtr-tiny tcpdump arp-scan lldpd iperf3 nftables iputils-tracepath \
  curl

# Verify
npk doctor
```

`bin/npk` is a symlink to `netpack`; both names work once `bin/` is on PATH.

Update later with `git -C ~/netpack pull`.

Alternatively for Scapy only: `pip install -r ~/netpack/requirements.txt`

## Launcher

```text
netpack | npk                 Interactive menu
netpack | npk list            List tools
netpack | npk help            Show this help (includes tool list)
netpack | npk --version       Print version
netpack | npk <tool> [args]   Run a tool
```

Tools are also invocable directly (`dhcpprobe`, `linkstat`, …). Use `-h` / `--help` on any tool.

When you pick a root-requiring tool from the menu without being root, the menu invokes sudo for you (tools where root is optional ask first). Direct invocation never adds sudo.

## Field playbook

Use these sequences while the symptom is present.

**Wrong IP / cannot reach the local LAN**

1. `linkstat` — physical errors vs drops
2. `sudo dhcpprobe` — one vs many DHCP servers (use VLAN iface if tagged)
3. `sudo segscan` — LLDP neighbor, gateway, ARP, duplicate IPs
4. `discover` — name the devices found (media servers, TVs, printers, AV gear)

**Wi-Fi is unreliable or slow**

1. `linkstat` — current association: signal, bitrate, carrier flaps
2. `sudo wifiscan` — channel congestion and overlapping APs nearby

**“Internet is down” but the link is up**

1. `splitloss` — gateway vs WAN ICMP
2. `dnscheck` — configured resolvers vs a public resolver
3. `webcheck` — captive portal or HTTP interception (ICMP/DNS clean, HTTP hijacked)
4. `mtucheck` — path MTU black holes
5. `path3` / `udp-loss` — path and UDP delivery evidence

**A specific service is unreachable (server, ingest, VPN)**

1. `portcheck <host> <ports>` — REFUSED (host up, service down) vs TIMEOUT (filtered)
2. `dnscheck -n <service-name>` — resolution for that name
3. `path3 <host>` — path evidence toward the service

**Intermittent dropouts or bursts**

1. `sudo ringcap -d /path/to/dir` — start before or during the window; note wall-clock time
2. `linkstat -t 30` — while the symptom is active
3. Stop capture; open the matching ring file in Wireshark/tshark

**Prove local throughput or one-way UDP loss**

1. On the uConsole: `sudo testsrv`
2. On the machine under test: `testcli <uconsole-ip>` (TCP) or `testcli -u <uconsole-ip>` (UDP)

**Prove latency and jitter under load (bufferbloat)**

1. `splitloss -t 60` — idle baseline; note rtt avg/mdev per target
2. Start a planned load across the path under test (`testsrv`/`testcli` pair, or `testcli -P 4 <wan-host>` for the uplink)
3. `splitloss -t 60` again while the load runs — rising avg/mdev with clean loss is buffering (bufferbloat); loss growth is saturation drops
4. `testcli -u -b 5M <host>` — iperf3's UDP jitter line for a game-like stream under the same load

**Dante/NDI multicast missing at a position**

1. `discover` — is the device still advertising (mDNS)?
2. `mcastcheck recv -g GROUP -p PORT` at the affected drop — is the flow arriving? (group/port from Dante Controller or the NDI sender)
3. `mcastcheck recv` at the drop + `mcastcheck send` from the source's switch position — pair test of the path with loss and jitter (IGMP snooping/querier check)

**Prove WAN uplink throughput**

netpack has no public throughput target by design; use a host you control across the WAN (cloud VM running `iperf3 -s`, or a provider-blessed server).

1. `testcli -P 4 <wan-host>` — upload direction (parallel streams to fill fat pipes)
2. `testcli -R -P 4 <wan-host>` — download direction
3. `splitloss -t 60` concurrently — latency under that load (see the bufferbloat playbook)

Saturating the venue uplink disrupts everything on it — planned tests only.

## Tools

| Tool | Purpose | Impact |
|------|---------|--------|
| `doctor` | Check dependencies and readiness | Read-only |
| `dhcpprobe` | List DHCP servers on the segment (DISCOVER only) | Broadcast; requires root |
| `linkstat` | Sample link counters; physical vs congestion | Read-only |
| `segscan` | Interface, LLDP, gateway, ARP sweep, duplicate IPs | Active ARP; root for sweep |
| `wifiscan` | Nearby Wi-Fi APs, signal, channel congestion | Active scan; requires root |
| `discover` | SSDP/mDNS service discovery on the segment | Light multicast queries |
| `splitloss` | Concurrent gateway vs WAN loss, rtt, loss timeline | ICMP load for duration |
| `dnscheck` | Configured vs public DNS resolver comparison | DNS query load |
| `webcheck` | Captive portal / HTTP + TLS interception check; clock skew | Few small HTTP(S) GETs |
| `portcheck` | TCP service reachability by port | A few TCP connects |
| `mtucheck` | Path MTU probe to gateway and WAN | Low ICMP load |
| `path3` | mtr over ICMP, UDP, and TCP | Probe load (count × 3); sudo if CAP_NET_RAW needed |
| `udp-loss` | UDP delivery via DNS queries with replies | DNS query load |
| `mcastcheck` | Multicast group delivery; Dante/NDI flow check | recv joins group (IGMP); send is light UDP |
| `ringcap` | Rotating pcap ring (headers by default) | Capture; requires root; `-d DIR` required |
| `testsrv` | iperf3 server; optional nft set open/close | High traffic when clients connect |
| `testcli` | iperf3 client companion to `testsrv` | High traffic; planned tests only |

### Exit codes (common pattern)

| Code | Meaning |
|------|---------|
| 0 | Clean / expected / single DHCP server |
| 1 | Usage, dependency, or permission error |
| 2+ | Condition found (tool-specific; see `--help`) |

## Production notes

- All tools are IPv4-only (DHCP, ARP, MTU header math, default targets). Dual-stack faults on the v6 side are out of scope.
- Prefer least privilege: tools that need root say so and exit cleanly.
- Tool reports include a local ISO-8601 start timestamp in the header (`tool — 2026-07-18T18:30:00-07:00`). Longer runs also print `finished: …` when the summary completes. JSON `--dump` files include a `timestamp` field.
- JSON `--dump` evidence is currently available only on the Python tools (`dhcpprobe`, `linkstat`, `discover`, `mcastcheck`). Bash tools print terminal evidence only; attach that output (or retained logs via `-d`) to an incident timeline.
- `wifiscan` triggers an active scan that briefly interrupts the interface's current Wi-Fi association; run it when a short drop is acceptable.
- `discover` requests unicast mDNS replies (QU); responders that only multicast are not captured, so it is best-effort, not an exhaustive inventory.
- `webcheck` fetches public connectivity endpoints over plain HTTP by design (portals intercept HTTP) and never follows redirects; the redirect target is the evidence. Its final HTTPS probe validates the chain against the system trust store (untrusted chain = TLS interception) and its clock line compares the local clock with the HTTP Date header.
- `dhcpprobe` does not complete DORA by default (no REQUEST/ACK) and does not bind a lease. `--full` completes DORA against the first offer and immediately RELEASEs; it briefly binds an address and appears in server lease logs.
- For tagged DHCP, pass `dhcpprobe -V <vid>` to create a temporary VLAN sub-interface (removed on exit; an existing sub-interface is reused and left in place), or run on the sub-interface directly (for example `eth0.100`).
- `udp-loss` sends queries sequentially with a 1s timeout, so a heavily lossy path can take up to COUNT seconds per server (~100s per server at the defaults).
- `splitloss` reports rtt min/avg/max/mdev per target alongside loss. Runs of 120s+ also print a loss timeline: each 60s interval with loss, stamped with its wall-clock start (derived from the run's start time and the 1s send interval).
- `mcastcheck recv` is passive apart from the IGMP join — but the join makes snooping switches forward the group to that port, which is the behavior under test. The default group `239.192.77.77:7788` (organization-local scope) avoids Dante's `239.255.0.0/16` media range; never `send` to a group carrying live audio/video. `send` defaults to TTL 1 (local segment only). Probe loss/jitter needs `mcastcheck send` as the source; rate/byte counts work against any flow.
- `ringcap` requires `-d DIR` and defaults to snaplen 96. Headers may still identify hosts.
- `segscan` refuses ARP sweeps larger than /22 unless `-y` is passed.
- `testsrv` only touches nftables sets `inet filter test_tcp` and `test_udp` when those sets exist; they are cleared on EXIT/INT/TERM. `SIGKILL` or power loss skips cleanup — remove the port manually if needed. Non-root runs refuse to guess whether sets exist (nft list needs privileges).
- Use load-generating tools (`path3`, `splitloss`, `udp-loss`, `mtucheck`, `testsrv`, `testcli`) only during planned tests on live networks.

## Examples

```bash
npk doctor
npk --version
netpack dhcpprobe -i eth0 --dump /tmp/dhcp.json
netpack linkstat -t 30 --dump /tmp/linkstat.json
sudo netpack segscan -i eth0
sudo netpack wifiscan
netpack discover -t 3 --dump /tmp/discover.json
netpack splitloss -t 60 -w 1.1.1.1 -d /tmp/splitloss-logs
netpack dnscheck
netpack webcheck
netpack portcheck 192.168.1.50 22 443 5201
sudo netpack dhcpprobe -V 100 --full
netpack mtucheck
netpack path3 -c 50 8.8.8.8
netpack udp-loss -c 100
netpack splitloss -t 3600 -d /tmp/splitloss-logs
netpack mcastcheck recv -g 239.255.12.34 -p 4321 -t 10
netpack mcastcheck send -c 500 -r 50
netpack testcli -R -P 4 192.168.1.50
sudo netpack ringcap -d /tmp/ringcap -i eth0 -s 20 -n 10
sudo netpack testsrv -p 5201
netpack testcli 192.168.1.50
netpack testcli -u -b 5M 192.168.1.50
```
