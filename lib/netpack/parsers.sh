# Pure parsing and verdict logic for the bash tools (and the bats suite).
# shellcheck shell=bash
#
# Every bash tool that decides something sources this file: splitloss, path3,
# dnscheck, segscan, wifiscan, udp-loss, webcheck, mtucheck. The rule from
# CONTRIBUTING applies here — anything that parses or classifies lives in this
# file as a pure function so it can be tested against captured output, and
# bin/ is left doing I/O. Functions are grouped by the tool that drove them
# out, but several are shared (classify_loss_set serves path3 and udp-loss).

# Parse packet-loss percent from a ping summary file (supports fractional %).
loss_pct() {
  local file=$1 pct
  pct="$(awk '
    /packet loss/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+([.][0-9]+)?%$/) {
          gsub(/%/, "", $i)
          print $i
          exit
        }
      }
    }
  ' "$file")"
  if [[ -z "$pct" ]]; then
    return 1
  fi
  echo "$pct"
}

# Parse "rtt min/avg/max/mdev = a/b/c/d ms" from a ping summary file.
# Prints "min<TAB>avg<TAB>max<TAB>mdev"; fails when absent (e.g., 100% loss).
# Also accepts BSD ping's "round-trip min/avg/max/stddev" for dev boxes.
rtt_stats() {
  local file=$1 line
  line="$(awk -F' = ' '
    /^(rtt|round-trip) min\/avg\/max/ {
      split($2, a, " ")
      n = split(a[1], f, "/")
      if (n >= 3) printf "%s\t%s\t%s\t%s", f[1], f[2], f[3], (n >= 4 ? f[4] : "-")
      exit
    }
  ' "$file")"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# Per-bucket loss from a ping -D -i 1 log (1 packet/second, icmp_seq from 1).
# Buckets are BUCKET seconds wide, offset from the first transmitted packet.
# Prints "offset<TAB>lost<TAB>expected" for buckets with loss only; no output
# when clean. Fails when the log has no transmitted-count summary line.
# Replies are lines with " time=" (unreachable/error lines count as lost);
# duplicate replies for a seq count once.
bucket_loss() {
  local file=$1 bucket=${2:-60}
  awk -v B="$bucket" '
    / time=/ && match($0, /icmp_seq=[0-9]+/) {
      seq = substr($0, RSTART + 9, RLENGTH - 9) + 0
      if (!(seq in got)) { got[seq] = 1; ngot++ }
    }
    /packets transmitted/ { tx = $1 + 0; rx = $4 + 0 }
    END {
      if (tx == 0) exit 1
      # Summary says replies arrived but none were parsed: not a -D reply log.
      if (rx > 0 && ngot == 0) exit 1
      for (s = 1; s <= tx; s++) {
        b = int((s - 1) / B)
        expect[b]++
        if (s in got) recv[b]++
      }
      for (b = 0; b * B < tx; b++) {
        lost = expect[b] - recv[b]
        if (lost > 0) printf "%d\t%d\t%d\n", b * B, lost, expect[b]
      }
    }
  ' "$file"
}

# --- DNS resolver enumeration -------------------------------------------------
#
# /etc/resolv.conf is not a reliable list of upstream resolvers: under
# systemd-resolved it holds a single loopback stub (127.0.0.53) that forwards to
# servers the file never names. Comparing that stub against a public baseline
# proves nothing about the upstreams — and when resolved forwards to the same
# public resolver, it compares that resolver against itself and reads as clean.
# parse_resolvectl_dns recovers the real per-link upstreams; is_stub_addr lets
# dnscheck say so when only a stub could be found.

# Parse `resolvectl dns` output into "iface<TAB>server" rows, one per server.
# Input lines are "Global: 1.1.1.1" or "Link 2 (eth0): 8.8.8.8 1.1.1.1"; links
# with no servers produce no rows. DNS-over-TLS pins (1.1.1.1#cloudflare-dns.com)
# and link scopes (fe80::1%eth0) are trimmed to the bare address.
# Reads FILE when given, else stdin (dnscheck pipes resolvectl straight in).
parse_resolvectl_dns() {
  awk '
    {
      iface = ""
      rest = ""
      if ($0 ~ /^Global:/) {
        iface = "global"
        rest = substr($0, 8)
      } else if (match($0, /^Link [0-9]+ \([^)]*\):/)) {
        hdr = substr($0, 1, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        open_paren = index(hdr, "(")
        close_paren = index(hdr, ")")
        iface = substr(hdr, open_paren + 1, close_paren - open_paren - 1)
      } else {
        next
      }
      n = split(rest, fields, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        addr = fields[i]
        sub(/#.*$/, "", addr)
        sub(/%.*$/, "", addr)
        if (addr != "") print iface "\t" addr
      }
    }
  ' ${1:+"$1"}
}

# Parse nameserver addresses from resolv.conf text, one per line, in file order.
# Comments (; and #) are ignored, as resolv.conf(5) specifies.
# Reads FILE when given, else stdin.
parse_resolv_conf() {
  awk '
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*nameserver[[:space:]]+/ {
      addr = $2
      sub(/%.*$/, "", addr)
      if (addr != "") print addr
    }
  ' ${1:+"$1"}
}

# True for loopback addresses — the shape of a local forwarding stub
# (systemd-resolved 127.0.0.53, dnsmasq 127.0.0.1, ::1).
is_stub_addr() {
  [[ "${1:-}" =~ ^127\. || "${1:-}" == "::1" ]]
}

# True for a record type dnscheck can meaningfully query: a common mnemonic or
# the RFC 3597 TYPEn form (n <= 65535). dig silently falls back to A for a
# token it does not recognize, so an unvalidated typo would query the wrong
# type, match no answers, and read as a clean comparison of empty answer sets.
# Expects the caller to have uppercased the input.
is_dns_rrtype() {
  local t=${1:-}
  case "$t" in
    A|AAAA|ANY|CAA|CNAME|DNSKEY|DS|HINFO|HTTPS|MX|NAPTR|NS|NSEC|PTR|RRSIG|SOA|SPF|SRV|SSHFP|SVCB|TLSA|TXT)
      return 0
      ;;
    TYPE[0-9]*)
      [[ "${t#TYPE}" =~ ^[0-9]+$ ]] && (( 10#${t#TYPE} <= 65535 ))
      ;;
    *)
      return 1
      ;;
  esac
}

# Read "key<TAB>value" rows on stdin and drop rows whose value was already seen,
# keeping the first occurrence (and so its key). Order is preserved.
dedupe_by_value() {
  awk -F'\t' '!seen[$2]++'
}

# --- ip route / addr ----------------------------------------------------------
#
# Multi-homed awareness: the routed tools name the interface their probes ride,
# and splitloss/mtucheck can bind to a chosen uplink. These parse the iproute2
# output the lib/netpack.sh wrappers feed them.

# Print the first `dev` value from `ip route get` (or `ip route show`) output.
# Empty output when no dev field is present (unroutable target).
# Reads FILE when given, else stdin.
parse_route_dev() {
  awk '
    {
      for (i = 1; i < NF; i++) {
        if ($i == "dev") { print $(i + 1); exit }
      }
    }
  ' ${1:+"$1"}
}

# Print the gateway from `ip route show default [dev IFACE]` output: the `via`
# of the first default line (iproute2 lists them metric-ascending, so the first
# is the one the kernel prefers). A dev-filtered line omits the dev field but
# keeps `via`. Empty output when there is no default route.
# Reads FILE when given, else stdin.
parse_default_via() {
  awk '
    /^default / {
      for (i = 1; i < NF; i++) {
        if ($i == "via") { print $(i + 1); exit }
      }
    }
  ' ${1:+"$1"}
}

# "iface<TAB>cidr" rows from `ip -o -4 addr show scope global` output, one per
# address, in input order — an interface with two addresses yields two rows.
# Reads FILE when given, else stdin.
parse_global_ifaces() {
  awk '
    {
      for (i = 3; i < NF; i++) {
        if ($i == "inet") { print $2 "\t" $(i + 1); break }
      }
    }
  ' ${1:+"$1"}
}

# --- shared verdict helpers ---------------------------------------------------

# classify_loss_set THRESHOLD PCT... -> none | clean | mixed | all
#
# How a set of per-target loss percentages should read as one verdict. Values
# that are not numeric ("-", empty) are unmeasured and ignored rather than
# counted as clean. The distinction that matters is "every measured target is
# lossy" (a shared path fault) versus "only some are" (destination- or
# protocol-specific handling), which is why callers map `all` and `mixed` to
# different exit codes.
classify_loss_set() {
  local threshold=$1
  shift
  printf '%s\n' "$@" | awk -v t="$threshold" '
    /^[0-9]+([.][0-9]+)?$/ { n++; if ($1 + 0 > t + 0) over++ }
    END {
      if (n == 0) print "none"
      else if (over == 0) print "clean"
      else if (over == n) print "all"
      else print "mixed"
    }
  '
}

# --- segscan ------------------------------------------------------------------

# classify_sweep PREFIX THRESHOLD -> ok | large | unsized
#
# Whether an ARP sweep of the interface's subnet needs explicit confirmation.
# A prefix numerically below THRESHOLD covers more addresses than it, so it is
# the large case. An unreadable prefix is "unsized" rather than ok: the size
# guard cannot be applied at all, and running the disruptive path with the
# protection silently absent is worse than refusing.
classify_sweep() {
  local prefix=${1:-} threshold=$2
  if [[ ! "$prefix" =~ ^[0-9]+$ ]]; then
    printf 'unsized\n'
  elif (( 10#$prefix < threshold )); then
    printf 'large\n'
  else
    printf 'ok\n'
  fi
}

# IPs claimed by two or more distinct MACs in an arp-scan report, sorted.
# arp-scan's retries print the same IP+MAC repeatedly and annotate them with
# "(DUP: n)"; that is one host answering twice, not an address conflict, so
# pairs are deduplicated before an IP is counted as contested.
arp_duplicates() {
  awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]/ {
      ip = $1; mac = tolower($2)
      if (!(ip SUBSEP mac in seen)) {
        seen[ip SUBSEP mac] = 1
        macs[ip]++
      }
    }
    END { for (ip in macs) if (macs[ip] >= 2) print ip }
  ' "$1" | sort
}

# --- wifiscan -----------------------------------------------------------------

# One "bssid<TAB>channel<TAB>signal<TAB>encryption<TAB>ssid" row per BSS in an
# `iw dev IFACE scan` report. Channel is derived from the frequency; 6 GHz
# reports with a "6G:" prefix (6G:5 for 5975 MHz) because its channel numbers
# collide with the 2.4/5 GHz numbering, which would corrupt the shared numeric
# histograms; wifi_channel_hist_6g reads the prefixed rows on their own.
parse_iw_scan() {
  awk '
    function chan(f) {
      if (f == 2484) return 14
      if (f >= 2412 && f <= 2472) return (f - 2407) / 5
      if (f == 5935) return "6G:2"
      if (f >= 5955 && f <= 7115) return "6G:" (f - 5950) / 5
      if (f >= 5925) return "6G"
      if (f >= 5000) return (f - 5000) / 5
      return "?"
    }
    function flush() {
      if (bss != "") {
        enc = rsn ? "wpa2/3" : (wpa ? "wpa" : (priv ? "wep" : "open"))
        printf "%s\t%s\t%s\t%s\t%s\n", bss, chan(freq), sig, enc, ssid
      }
    }
    /^BSS / {
      flush()
      bss = $2; sub(/\(on.*/, "", bss)
      ssid = "<hidden>"; sig = "?"; freq = "?"; rsn = 0; wpa = 0; priv = 0
    }
    /^[[:space:]]*signal:/ { sig = $2 }
    /^[[:space:]]*freq:/ { freq = $2 }
    /^[[:space:]]*capability:.*Privacy/ { priv = 1 }
    /^[[:space:]]*RSN:/ { rsn = 1 }
    /^[[:space:]]*WPA:/ { wpa = 1 }
    /^[[:space:]]*SSID:/ {
      s = $0; sub(/^[[:space:]]*SSID:[[:space:]]*/, "", s)
      if (s != "") ssid = s
    }
    END { flush() }
  ' "$1"
}

# "channel count" for the busiest channel in [LO, HI] of a parse_iw_scan table.
# Prints nothing when no AP falls in the band, so callers can tell "no APs on
# this band" from "APs, none crowded".
wifi_busiest_channel() {
  local file=$1 lo=$2 hi=$3
  awk -F'\t' -v lo="$lo" -v hi="$hi" '
    $2 ~ /^[0-9]+$/ && $2 >= lo && $2 <= hi { c[$2]++ }
    END {
      bc = ""; bn = 0
      for (ch in c) if (c[ch] > bn || (c[ch] == bn && ch + 0 < bc + 0)) { bn = c[ch]; bc = ch }
      if (bn > 0) print bc, bn
    }
  ' "$file"
}

# "  ch N count" lines for every occupied channel in [LO, HI], ascending.
wifi_channel_hist() {
  local file=$1 lo=$2 hi=$3
  awk -F'\t' -v lo="$lo" -v hi="$hi" '
    $2 ~ /^[0-9]+$/ && $2 >= lo && $2 <= hi { c[$2]++ }
    END { for (ch = lo; ch <= hi; ch++) if (c[ch]) printf "  ch %-3s %d\n", ch, c[ch] }
  ' "$file"
}

# "  ch N count" lines for every occupied 6 GHz channel, ascending. Reads the
# 6G:-prefixed rows the numeric histograms exclude (channels 1-233).
wifi_channel_hist_6g() {
  awk -F'\t' '
    $2 ~ /^6G:[0-9]+$/ { sub(/^6G:/, "", $2); c[$2 + 0]++ }
    END { for (ch = 1; ch <= 233; ch++) if (c[ch]) printf "  ch %-3s %d\n", ch, c[ch] }
  ' "$1"
}

# --- webcheck -----------------------------------------------------------------

# classify_http_probe STATUS WANT_STATUS BODY WANT_BODY [REDIRECT]
#   -> ok | redirect | status | body
#
# A portal is identified by the response not matching its published answer. A
# wrong status with a redirect target names the portal; the right status with
# the wrong body is interception that kept the status intact.
classify_http_probe() {
  local status=$1 want_status=$2 body=$3 want_body=$4 redirect=${5:-}
  if [[ "$status" == "$want_status" && "$body" == "$want_body" ]]; then
    printf 'ok\n'
  elif [[ "$status" != "$want_status" && -n "$redirect" ]]; then
    printf 'redirect\n'
  elif [[ "$status" != "$want_status" ]]; then
    printf 'status\n'
  else
    printf 'body\n'
  fi
}

# --- mtucheck -----------------------------------------------------------------

# Total IPv4 size for a DF payload that got through (payload + 20 IP + 8 ICMP).
# 0 stays 0: no payload succeeded, so there is no size to report.
mtu_total() {
  local payload=${1:-0}
  if [[ ! "$payload" =~ ^[0-9]+$ ]] || (( payload == 0 )); then
    printf '0\n'
  else
    printf '%s\n' $((payload + 28))
  fi
}

# classify_mtu THRESHOLD GW_TOTAL WAN_TOTAL -> ok | reduced | blocked
# "blocked" is both paths failing outright, which is ICMP filtering rather than
# an MTU finding, so callers report it as an error instead of a small MTU.
classify_mtu() {
  local threshold=$1 gw=$2 wan=$3
  if (( gw == 0 && wan == 0 )); then
    printf 'blocked\n'
  elif (( gw == 0 || wan == 0 || gw < threshold || wan < threshold )); then
    printf 'reduced\n'
  else
    printf 'ok\n'
  fi
}

# --- path3 --------------------------------------------------------------------

# Extract final-hop host, loss, and avg from an mtr report file.
summarize_final() {
  local file=$1
  awk '
    BEGIN { host = "-"; loss = "-"; avg = "-" }
    /^HOST:/ { next }
    NF < 3 { next }
    {
      h = $2
      gsub(/^\.?\|--/, "", h)
      for (i = 1; i <= NF; i++) {
        if ($i ~ /%$/) {
          host = h
          loss = $i
          if ((i + 3) <= NF) avg = $(i + 3) "ms"
          break
        }
      }
    }
    END { printf "%s\t%s\t%s\n", host, loss, avg }
  ' "$file"
}
