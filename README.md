# netpack (npk)

Network tools for on-site troubleshooting and evidence collection.

## Setup

```bash
# Clone
git clone https://github.com/madebyjake/netpack.git ~/netpack

# Dependencies (Debian; Python >= 3.10 required)
sudo apt update
sudo apt install python3 python3-scapy iproute2 iputils-ping dnsutils \
  ethtool iw mtr-tiny tcpdump arp-scan lldpd iperf3 nftables iputils-tracepath \
  curl

# Put netpack and npk on PATH, then report readiness. Symlinks into
# ~/.local/bin, so `git pull` updates them; PREFIX=/usr/local installs
# system-wide.
make -C ~/netpack install
```

`make install` links only the two launcher names — every tool is reachable
through them (`npk linkstat`), and the tools stay directly invocable if you put
`~/netpack/bin` on PATH yourself instead:

```bash
echo 'export PATH="$HOME/netpack/bin:$PATH"' >> ~/.bashrc   # optional
```

Update later with `git -C ~/netpack pull`; `make uninstall` removes the links.

Alternatively for Scapy only: `pip install -r ~/netpack/requirements.txt`

### Pinning to a release

The clone above tracks `main`, which moves. Pin a field box to a release tag
instead, so tool behaviour and evidence semantics stay fixed for the duration of
an engagement:

```bash
# Clone at a release
git clone --branch 0.8.0 https://github.com/madebyjake/netpack.git ~/netpack

# Or move an existing clone onto one
git -C ~/netpack fetch --tags
git -C ~/netpack checkout 0.8.0

npk --version          # confirm what is installed
```

Tags are the bare version (`0.8.0`) and match the GitHub release named
`netpack-vX.Y.Z-beta`. Because `make install` symlinks rather than copies,
checking out a different tag switches the installed tools immediately — there is
nothing to re-install.

A tag checkout leaves the clone on a detached HEAD, so `git pull` no longer
applies. Move to a later release with `fetch --tags` then `checkout <tag>`, and
return to tracking the branch with `git -C ~/netpack checkout main`.

List what is available with `git -C ~/netpack tag -l` or `gh release list`.
Every release is marked pre-release until 1.0.0, which means GitHub's
`/releases/latest` endpoint returns 404 — do not script against it.

For a machine without git, a release tarball carries the same tree:

```bash
curl -fsSL https://github.com/madebyjake/netpack/archive/refs/tags/0.8.0.tar.gz \
  | tar -xz -C ~ && mv ~/netpack-0.8.0 ~/netpack
```

Developing or running the test suite? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Launcher

```text
netpack | npk                 Interactive menu
netpack | npk list            List tools
netpack | npk help            Show this help (includes tool list)
netpack | npk --version       Print version
netpack | npk <tool> [args]   Run a tool
netpack | npk playbooks       List guided playbooks
netpack | npk playbook <id>   Run a guided playbook
netpack | npk -o DIR ...      Capture evidence into DIR
```

Tools are also invocable directly (`dhcpprobe`, `linkstat`, …). Use `-h` / `--help` on any tool.

When you pick a root-requiring tool from the menu without being root, the menu invokes sudo for you (tools where root is optional ask first). Direct invocation never adds sudo.

The menu opens with a short launch animation; any key skips it, and
`NETPACK_NO_SPLASH=1` disables it entirely (`npk splash` replays it on demand).
Neither ever appears in piped output or captured evidence.

### Evidence capture

`-o DIR` records every run started through the launcher — one run or a whole
session:

```bash
npk -o ~/evidence/site-visit               # menu; everything run is captured
npk -o ~/evidence/site-visit dnscheck      # capture a single run
```

Each run writes `DIR/<tool>-<timestamp>.log` (the terminal report and its
stderr, in plain text) and appends a row to `DIR/manifest.tsv` recording the
command as you would retype it, its start and end times, and its exit code. The
directory is created mode 700. This is how the tools without their own `--dump`
still leave evidence behind; tools that have `--dump` also write
`DIR/<tool>-<timestamp>.json` automatically (an explicit `--dump` path wins).

The menu shows `rec <dir>` in its status line while capture is active.

Privilege note: logs are written by the launcher, so a menu session run as your
user keeps them yours even when a tool is elevated — but that elevated tool
writes its JSON dump as root, and running the launcher itself under sudo makes
the whole directory root-owned. Keep one capture directory to one privilege
level, or `chown -R` it afterwards.

Capture covers runs started through the launcher — `npk <tool>`, the menu, and
playbooks. A tool invoked directly by name (`dhcpprobe -i eth0`, with `bin/` on
PATH) bypasses it and is not recorded. If you are collecting evidence, drive the
session through `npk`; `make install` links only the launcher names for that
reason.

## Field playbook

Use these sequences while the symptom is present.

The single-machine sequences are runnable: `npk playbooks` lists them, `npk
playbook <id>` walks one step by step (stating why each step is being run before
it runs), and `p` does the same from the menu. Combine with `-o DIR` and the
whole sequence lands in one evidence folder:

```bash
npk -o ~/evidence/site-visit playbook wan
```

The throughput and bufferbloat procedures need a second machine running
`testsrv`, so they are documented here rather than being runnable lists.

**Wrong IP / cannot reach the local LAN** — `npk playbook lan`

1. `linkstat` — physical errors vs drops
2. `sudo dhcpprobe` — one vs many DHCP servers (use VLAN iface if tagged)
3. `sudo segscan` — LLDP neighbor, gateway, ARP, duplicate IPs
4. `discover` — name the devices found (media servers, TVs, printers, AV gear)

**Errors or link flaps on a wired port** — `npk playbook cable`

1. `linkstat -t 30` — confirm the fault is physical (errors/CRC/collisions growing, or carrier flapping)
2. `sudo cabletest -y` — which pair failed, and how far along the run. Drops the link, so run it once the counters justify it

**Wi-Fi is unreliable or slow** — `npk playbook wifi`

1. `linkstat` — current association: signal, bitrate, carrier flaps
2. `sudo wifiscan` — channel congestion and overlapping APs nearby

**“Internet is down” but the link is up** — `npk playbook wan`

1. `splitloss` — gateway vs WAN ICMP
2. `dnscheck` — configured resolvers vs a public resolver
3. `webcheck` — captive portal or HTTP interception (ICMP/DNS clean, HTTP hijacked)
4. `mtucheck` — path MTU black holes
5. `path3` / `udp-loss` — path and UDP delivery evidence

**A specific service is unreachable (server, ingest, VPN)** — `npk playbook service`

1. `portcheck <host> <ports>` — REFUSED (host up, service down) vs TIMEOUT (filtered)
2. `dnscheck -n <service-name>` — resolution for that name
3. `path3 <host>` — path evidence toward the service

**Intermittent dropouts or bursts** — `npk playbook dropouts`

1. `sudo ringcap -d /path/to/dir` — start before or during the window; note wall-clock time
2. `linkstat -t 30` — while the symptom is active
3. Stop capture; open the matching ring file in Wireshark/tshark

**Prove local throughput or one-way UDP loss**

1. On the netpack box: `sudo testsrv`
2. On the machine under test: `testcli <server-ip>` (TCP) or `testcli -u <server-ip>` (UDP)

**Prove latency and jitter under load (bufferbloat)**

1. `splitloss -t 60` — idle baseline; note rtt avg/mdev per target
2. Start a planned load across the path under test (`testsrv`/`testcli` pair, or `testcli -P 4 <wan-host>` for the uplink)
3. `splitloss -t 60` again while the load runs — rising avg/mdev with clean loss is buffering (bufferbloat); loss growth is saturation drops
4. `testcli -u -b 5M <host>` — iperf3's UDP jitter line for a game-like stream under the same load

**Dante/NDI multicast missing at a position** — `npk playbook multicast`

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

Root and traffic columns use the same tags as `npk list` and the menu:
`sudo` needs root (the menu auto-elevates), `sudo?` is better with root (the menu
asks), `probe` sends light diagnostic traffic, `loud` is heavy traffic, active
probing, or link disruption — authorized, planned use only. A blank cell is
passive or read-only.

| Tool | Purpose | Root | Traffic |
|------|---------|------|---------|
| `doctor` | Check dependencies and readiness | | |
| `dhcpprobe` | List DHCP servers on the segment (DISCOVER only) | `sudo` | `probe` |
| `linkstat` | Sample link counters; physical vs congestion | | |
| `cabletest` | TDR cable test: per-pair faults and distance | `sudo` | `loud` |
| `segscan` | Interface, LLDP, gateway, ARP sweep, duplicate IPs | `sudo?` | `loud` |
| `wifiscan` | Nearby Wi-Fi APs, signal, channel congestion | `sudo` | `probe` |
| `discover` | SSDP/mDNS service discovery on the segment | | `probe` |
| `splitloss` | Concurrent gateway vs WAN loss, rtt, loss timeline | | `probe` |
| `dnscheck` | Configured vs public DNS resolver comparison | | `probe` |
| `webcheck` | Captive portal / HTTP + TLS interception check; clock skew | | `probe` |
| `portcheck` | TCP service reachability by port | | `probe` |
| `mtucheck` | Path MTU probe to gateway and WAN | | `probe` |
| `path3` | mtr over ICMP, UDP, and TCP | `sudo?` | `loud` |
| `udp-loss` | UDP delivery via DNS queries with replies | | `probe` |
| `mcastcheck` | Multicast group delivery (AV, IPTV, sACN, Dante/NDI) | | `probe` |
| `ringcap` | Rotating pcap ring (headers by default) | `sudo` | |
| `testsrv` | iperf3 server; optional nft set open/close | `sudo?` | `loud` |
| `testcli` | iperf3 client companion to `testsrv` | | `loud` |

`segscan` and `path3` run without root but lose their main evidence (the ARP
sweep; the UDP/TCP modes); `testsrv` needs root only to touch the nftables sets.

### Exit codes (common pattern)

| Code | Meaning |
|------|---------|
| 0 | Clean / expected / single DHCP server |
| 1 | Usage, dependency, or permission error |
| 2+ | Condition found (tool-specific; see `--help`) |
| 130 | Interrupted (except tools where Ctrl-C is the normal stop: `ringcap`, `splitloss`, `mcastcheck recv`) |

Ctrl-C is a normal way to end a field test, so a tool prints its report and
writes `--dump` anyway rather than discarding the run. Three rules hold across
every tool:

- Measurements are scaled to what was actually attempted, never to what was
  requested — loss is counted against the probes sent, not the count asked for.
- A target the run never reached is reported as not probed, never as clean. An
  unqueried resolver, an unswept address, and an untried port are absent from
  the evidence rather than present as passing.
- A probe cut off mid-flight is discarded, not recorded. Killing `curl` or `dig`
  looks exactly like a block, and a portal or a filtered port that was never
  observed must not appear in the report.

An interrupted assessment therefore leans against false confidence: a short
window that saw no fault has not shown the segment is clean, only that it did
not look for long enough.

## Production notes

- All tools are IPv4-only (DHCP, ARP, MTU header math, default targets). Dual-stack faults on the v6 side are out of scope.
- On a multi-homed machine (eth into the segment under test plus Wi-Fi for internet, or two uplinks) the routed tools follow the routing table and say so: the report names the interface the probes ride, a `note:` lists every addressed interface, and the menu's context line shows the others under `also`.
- `-i IFACE` binds probes to a chosen uplink instead: `splitloss`, `mtucheck`, `dnscheck`, `webcheck`, `udp-loss`, `path3` (and `discover`, `segscan`, `ringcap`, `dhcpprobe`, `linkstat`, `cabletest`, `wifiscan`, `mcastcheck`, which are interface-scoped anyway). Binding sets the probe's source address, but replies follow the main routing table unless a policy route (`ip rule`) steers that address back out the same interface — without one, rp_filter drops them and the tool would read it as loss, blocking, or a portal. Every `-i` run checks for that route first. `splitloss` and `mtucheck` keep their gateway leg (it is on-link and stays honest) and report only the WAN leg as untestable; the rest have no on-link target, so they exit 1 rather than measure the wrong thing.
- `portcheck` has no `-i`: its probe is a bash `/dev/tcp` connect(), which cannot bind a source address. Adding `nc` or `socat` to gain one would add a dependency and change what the probe proves. It still names the interface the connect went out on.
- Prefer least privilege: tools that need root say so and exit cleanly.
- Every tool rejects arguments it does not understand (exit 1) rather than
  falling back to defaults, so a typo like `splitloss -t 60 8.8.8.8` fails
  loudly instead of quietly testing the default target.
- Tool reports open with a local ISO-8601 start timestamp (`tool — 2026-07-18T18:30:00-07:00`) and close with `finished: …` once the summary is printed, so a report always carries its own start and end times.
- JSON `--dump` files carry the run's fields plus `tool`, `timestamp`, and `assessment_code` (the exit code the run produced). `dhcpprobe` also records `assessment` (`none`/`single`/`multiple`).
- Tools whose run can be cut short record `interrupted` — `dhcpprobe`, `discover`, `linkstat`, `mcastcheck send`, `portcheck`, and `webcheck`. When it is `true` the payload covers a shortened run, so a clean-looking result means "nothing seen yet", not "nothing there": `linkstat` scales its rates to the window that actually elapsed, `dhcpprobe` having seen one server does not rule out a second, `discover` reports an unopened mDNS window as `null` rather than as an empty list, and `portcheck` records how many ports it actually probed alongside the total.
- JSON `--dump` evidence is available on `cabletest`, `dhcpprobe`, `discover`, `dnscheck`, `linkstat`, `mcastcheck`, `mtucheck`, `portcheck`, `segscan`, `splitloss`, `udp-loss` and `webcheck`; under `-o DIR` capture those tools dump into the capture directory automatically. The rest print terminal evidence only — `path3` and `testcli` wrap `mtr` and `iperf3`, which emit their own JSON, and `doctor`, `ringcap` and `testsrv` produce a readiness check, pcap files and a server session rather than a measurement. Attach their output (or retained logs via `-d`) to an incident timeline.
- A dump distinguishes "measured" from "not measured" with a state field rather than a sentinel number: `mtucheck` records `gw_state`/`wan_state` (`measured`, `blocked`, `not_probed`, `untestable_via_iface`), `segscan` records `sweep_state` (`completed`, `partial`, `skipped_no_root`, `skipped_no_arp_scan`), and `udp-loss`, `dnscheck` and `splitloss` mark each target `queried`/`measured`. A leg that was never probed carries `null` figures, so it cannot be read as a clean zero.
- In a dump, `null` means "not determined" and is never interchangeable with `0` or `""`: an untestable leg, an unknown egress interface, or a measurement the tool could not take all serialize as `null`, so a consumer cannot read them as clean.
- `wifiscan` triggers an active scan that briefly interrupts the interface's current Wi-Fi association; run it when a short drop is acceptable.
- `discover` sends its queries via the default-route interface; on a multi-homed machine the segment under test is often not the default route, so pass `-i` to pin it (for example `discover -i eth0`).
- `discover` requests unicast mDNS replies (QU); responders that only multicast are not captured, so it is best-effort, not an exhaustive inventory.
- `discover` labels known mDNS service types (Dante, NDI, AirPlay, printers, …) and lists real-time AV advertisers separately. Unrecognized types print verbatim. Vendor service names change between product generations, so treat a label as convenience, not authority.
- `linkstat` reports Energy Efficient Ethernet and flow-control state on wired links. EEE lets the PHY enter low-power idle between frames, adding wake latency and jitter; it is a known cause of clock instability for Dante/AES67 and PTP, and of jitter for VoIP. Disable it on ports carrying those streams. These are settings rather than counters, so they never affect the exit code.
- `dnscheck` takes its resolver list from `resolvectl dns` when systemd-resolved is running, because `/etc/resolv.conf` on those systems holds only the `127.0.0.53` stub, and testing the stub proves nothing about the upstreams it forwards to. Without resolved, `resolv.conf` is used directly. If only a loopback stub can be identified, the run says so and exits 2 rather than reporting clean.
- `dnscheck`'s baseline defaults to the first of `1.1.1.1`, `9.9.9.9`, `8.8.8.8`, `208.67.222.222` that the system is not already using, so the control is independent by construction — a fixed default would compare a configured resolver against itself on any host that forwards to it, and agreement with itself is not evidence. An explicit `-p` is honoured as given; if it turns out to be configured too, the run warns and says so in the assessment, and exits 2 only when there was no second distinct resolver to compare against at all.
- `cabletest` runs ethtool's TDR cable test, reporting each pair as OK or faulted with the approximate distance to the break — the direct answer to "is the cable bad, and where", for when `linkstat` shows physical-layer growth or carrier flaps. It carries `loud` for disruption rather than traffic: the PHY drops the link to measure, so the port goes down for the duration. It requires root and `-y`, and the menu asks before running it.
- `cabletest` depends on the NIC driver exposing TDR, and most desktop and server NICs do not — `e1000e`, `igb` and `r8169` all reject the request, so it will not work against a typical workstation's onboard port. Support is common on embedded and switch PHYs. A driver that cannot run the test quotes ethtool's own message, names the driver, and exits 1 rather than reporting a pass; a rejected request never disturbs the link, and the report says so.
- `webcheck` fetches public connectivity endpoints over plain HTTP by design (portals intercept HTTP) and never follows redirects; the redirect target is the evidence. Its final HTTPS probe validates the chain against the system trust store (untrusted chain = TLS interception) and its clock line compares the local clock with the HTTP Date header.
- `dhcpprobe` does not complete DORA by default (no REQUEST/ACK) and does not bind a lease. `--full` completes DORA against the first offer and immediately RELEASEs; it briefly binds an address and appears in server lease logs.
- For tagged DHCP, pass `dhcpprobe -V <vid>` to create a temporary VLAN sub-interface (removed on exit; an existing sub-interface is reused and left in place), or run on the sub-interface directly (for example `eth0.100`).
- `udp-loss` sends queries sequentially with a 1s timeout, so a heavily lossy path can take up to COUNT seconds per server (~100s per server at the defaults).
- `splitloss` reports rtt min/avg/max/mdev per target alongside loss. Runs of 120s+ also print a loss timeline: each 60s interval with loss, stamped with its wall-clock start (derived from the run's start time and the 1s send interval).
- `mcastcheck recv` is passive apart from the IGMP join — but the join makes snooping switches forward the group to that port, which is the behavior under test. The default group `239.192.77.77:7788` sits in the RFC 2365 organization-local scope, outside `239.255.0.0/16` (the range Dante allocates media flows from by default). `send` refuses that range without `-y`, since transmitting into a live audio group disrupts it; the guard covers the common default only, so confirm a group is unused before sending. `send` defaults to TTL 1 (local segment only). Probe loss/jitter needs `mcastcheck send` as the source; rate/byte counts work against any flow.
- `ringcap` requires `-d DIR` and defaults to snaplen 96. Headers may still identify hosts.
- `segscan` refuses ARP sweeps larger than /22 unless `-y` is passed.
- `testsrv` only touches nftables sets `inet filter test_tcp` and `test_udp` when those sets exist; they are cleared on EXIT/INT/TERM. `SIGKILL` or power loss skips cleanup — remove the port manually if needed. Non-root runs refuse to guess whether sets exist (nft list needs privileges); `-n` skips firewall handling entirely and needs no root.
- Use load-generating tools (`path3`, `splitloss`, `udp-loss`, `mtucheck`, `testsrv`, `testcli`) only during planned tests on live networks.

## Examples

```bash
npk doctor
npk --version
netpack dhcpprobe -i eth0 --dump /tmp/dhcp.json
netpack linkstat -t 30 --dump /tmp/linkstat.json
sudo netpack cabletest -y -i eth0
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
