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
