# Pure parsers shared by bash tools (and bats fixtures).
# shellcheck shell=bash
# Sourced by bin/splitloss, bin/path3, and tests.

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
