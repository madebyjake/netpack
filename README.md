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

**“Internet is down” but the link is up**

1. `splitloss` — gateway vs WAN ICMP
2. `dnscheck` — configured resolvers vs a public resolver
3. `webcheck` — captive portal or HTTP interception (ICMP/DNS clean, HTTP hijacked)
4. `mtucheck` — path MTU black holes
5. `path3` / `udp-loss` — path and UDP delivery evidence

**Intermittent dropouts or bursts**

1. `sudo ringcap -d /path/to/dir` — start before or during the window; note wall-clock time
2. `linkstat -t 30` — while the symptom is active
3. Stop capture; open the matching ring file in Wireshark/tshark

**Prove local throughput or one-way UDP loss**

1. On the uConsole: `sudo testsrv`
2. On the machine under test: `testcli <uconsole-ip>` (TCP) or `testcli -u <uconsole-ip>` (UDP)

## Tools

| Tool | Purpose | Impact |
|------|---------|--------|
| `doctor` | Check dependencies and readiness | Read-only |
| `dhcpprobe` | List DHCP servers on the segment (DISCOVER only) | Broadcast; requires root |
| `linkstat` | Sample link counters; physical vs congestion | Read-only |
| `segscan` | Interface, LLDP, gateway, ARP sweep, duplicate IPs | Active ARP; root for sweep |
| `splitloss` | Concurrent gateway vs WAN ping loss | ICMP load for duration |
| `dnscheck` | Configured vs public DNS resolver comparison | DNS query load |
| `webcheck` | Captive portal / HTTP interception check | Few small HTTP GETs |
| `mtucheck` | Path MTU probe to gateway and WAN | Low ICMP load |
| `path3` | mtr over ICMP, UDP, and TCP | Probe load (count × 3); sudo if CAP_NET_RAW needed |
| `udp-loss` | UDP delivery via DNS queries with replies | DNS query load |
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
- JSON `--dump` evidence is currently available only on the Python tools (`dhcpprobe`, `linkstat`). Bash tools print terminal evidence only; attach that output (or retained logs via `-d`) to an incident timeline.
- `webcheck` fetches public connectivity endpoints over plain HTTP by design (portals intercept HTTP) and never follows redirects; the redirect target is the evidence.
- `dhcpprobe` never completes DORA (no REQUEST/ACK); it does not bind a lease.
- For tagged DHCP, run `dhcpprobe` on the VLAN sub-interface (for example `eth0.100`).
- `ringcap` requires `-d DIR` and defaults to snaplen 96. Headers may still identify hosts.
- `segscan` refuses ARP sweeps larger than /22 unless `-y` is passed.
- `testsrv` only touches nftables sets `inet filter test_tcp` and `test_udp` when those sets exist; they are cleared on EXIT/INT/TERM. `SIGKILL` or power loss skips cleanup — remove the port manually if needed. Non-root runs refuse to guess whether sets exist (nft list needs privileges).
- Use load-generating tools (`path3`, `splitloss`, `udp-loss`, `dnscheck`, `mtucheck`, `testsrv`, `testcli`) only during planned tests on live networks.

## Examples

```bash
npk doctor
npk --version
netpack dhcpprobe -i eth0 --dump /tmp/dhcp.json
netpack linkstat -t 30 --dump /tmp/linkstat.json
sudo netpack segscan -i eth0
netpack splitloss -t 60 -w 1.1.1.1 -d /tmp/splitloss-logs
netpack dnscheck
netpack webcheck
netpack mtucheck
netpack path3 -c 50 8.8.8.8
netpack udp-loss -c 100
sudo netpack ringcap -d /tmp/ringcap -i eth0 -s 20 -n 10
sudo netpack testsrv -p 5201
netpack testcli 192.168.1.50
netpack testcli -u -b 5M 192.168.1.50
```
