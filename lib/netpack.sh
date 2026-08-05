# Shared helpers for netpack bash tools.
# shellcheck shell=bash
# Interface naming/validation rules are mirrored in lib/netpack/net.py; keep the
# two in sync. Report helpers here mirror lib/netpack/report.py.

netpack_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${here}/.." && pwd
}

netpack_bin() {
  echo "$(netpack_root)/bin"
}

# Single source of truth for the version is lib/netpack/__init__.py.
netpack_version() {
  local init
  init="$(netpack_root)/lib/netpack/__init__.py"
  if [[ -f "$init" ]]; then
    sed -n 's/^__version__ = "\(.*\)"/\1/p' "$init" | head -1
  else
    echo "unknown"
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' not found in PATH"
  done
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "root privileges required; re-run with sudo"
  fi
}

validate_iface() {
  local iface=$1
  if [[ ! "$iface" =~ ^[A-Za-z0-9._@:+=-]+$ ]]; then
    die "invalid interface name: ${iface}"
  fi
  if [[ ! -d "/sys/class/net/${iface}" ]]; then
    die "interface not found: ${iface}"
  fi
}

# The route/addr helpers below parse via lib/netpack/parsers.sh, which every
# bash tool sources alongside this file.

default_iface() {
  local iface
  # || true: a box with no default route makes `ip route get` fail, and under
  # pipefail that would abort the tool here instead of reaching the fallback.
  iface="$(ip -o route get 1.1.1.1 2>/dev/null | parse_route_dev)" || true
  if [[ -n "${iface}" && -d "/sys/class/net/${iface}" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi
  local d name
  for d in /sys/class/net/*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ "$name" != "lo" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  die "no usable interface found"
}

resolve_iface() {
  local explicit=${1:-}
  if [[ -n "$explicit" ]]; then
    validate_iface "$explicit"
    printf '%s\n' "$explicit"
  else
    default_iface
  fi
}

default_gateway() {
  ip -o route show default 2>/dev/null | parse_default_via
}

# Gateway of IFACE's own default route (multi-homed boxes keep one per uplink
# at different metrics); empty when the interface has none.
iface_gateway() {
  ip -o route show default dev "$1" 2>/dev/null | parse_default_via
}

# Interface the kernel would use to reach TARGET; empty when unroutable (or
# when TARGET is an unresolvable name). The || true guards matter: these run
# inside $( ) assignments in tools under set -e, and an unroutable target or a
# missing ip must read as "unknown", not kill the tool mid-report.
route_iface() {
  ip -o route get "$1" 2>/dev/null | parse_route_dev || true
}

# route_iface, but only for IPv4 literals — resolving a hostname here would
# stall the very tools whose job is to diagnose broken DNS. Empty for names.
via_for() {
  if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    route_iface "$1"
  fi
}

# uplink_unroutable IFACE SRC TARGET — empty when a policy route steers SRC out
# IFACE toward TARGET; otherwise a reason naming the interface the kernel would
# use instead.
#
# This is the honesty check for every -i binding. Binding a probe to an uplink
# sets its source address, but replies follow the main routing table unless an
# `ip rule` steers that address back out the same interface. Without one,
# rp_filter drops the replies and the tool reads it as loss, blocking, or a
# portal — evidence about the wrong thing.
uplink_unroutable() {
  local iface=$1 src=$2 target=$3 dev
  dev="$(ip -o route get "$target" from "$src" 2>/dev/null | parse_route_dev)" || true
  if [[ "$dev" != "$iface" ]]; then
    printf 'no policy route sends %s out %s (kernel would use %s)\n' \
      "$src" "$iface" "${dev:-no route}"
  fi
}

# require_uplink IFACE TARGET — validate IFACE, print its source address, and
# die when probes bound to it could not reach TARGET honestly.
#
# For tools whose every target is off-link, an unroutable binding makes the
# whole run meaningless, so this exits rather than reporting. splitloss and
# mtucheck call uplink_unroutable directly instead: their gateway leg is
# on-link and stays honest, so only the WAN leg is dropped.
require_uplink() {
  local iface=$1 target=$2 src reason
  validate_iface "$iface"
  src="$(iface_ipv4 "$iface")"
  [[ -n "$src" ]] || die "no IPv4 address on ${iface}"
  reason="$(uplink_unroutable "$iface" "$src" "$target")"
  if [[ -n "$reason" ]]; then
    die "cannot probe via ${iface}: ${reason}; add an ip rule for ${src}, or run without -i"
  fi
  printf '%s\n' "$src"
}

# "iface<TAB>cidr" rows for every global IPv4 address on the system.
global_ifaces() {
  ip -o -4 addr show scope global 2>/dev/null | parse_global_ifaces || true
}

# First global IPv4 address (no prefix) on IFACE; empty when none.
# Mirrors lib/netpack/net.py iface_ipv4.
iface_ipv4() {
  local row
  row="$(ip -o -4 addr show dev "$1" scope global 2>/dev/null \
    | parse_global_ifaces | head -1)" || true
  row="${row#*$'\t'}"
  printf '%s\n' "${row%%/*}"
}

# multihomed_note VIA [HINT] — amber note when more than one interface holds a
# global IPv4 address: name them all and which one this run's probes ride, so
# evidence collected on the wrong network says so on its face.
multihomed_note() {
  local via=$1 hint=${2:-} rows n list
  rows="$(global_ifaces)"
  [[ -n "$rows" ]] || return 0
  n="$(printf '%s\n' "$rows" | awk -F'\t' '!seen[$1]++ { n++ } END { print n }')"
  (( n > 1 )) || return 0
  list="$(printf '%s\n' "$rows" \
    | awk -F'\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }')"
  if [[ -n "$via" ]]; then
    note "multi-homed (${list}); probes leave via ${via}${hint:+ — ${hint}}"
  else
    note "multi-homed (${list}); probes follow the routing table${hint:+ — ${hint}}"
  fi
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# Validate an unsigned-integer option value within [MIN, MAX]; die otherwise.
# Usage: require_uint LABEL VALUE MIN [MAX]
require_uint() {
  local label=$1 val=$2 min=$3 max=${4:-}
  if ! is_uint "$val"; then
    die "invalid ${label}: ${val}"
  fi
  # 10# guards against leading zeros being read as octal
  if (( 10#$val < min )); then
    die "invalid ${label}: ${val}"
  fi
  if [[ -n "$max" ]] && (( 10#$val > max )); then
    die "invalid ${label}: ${val}"
  fi
}

# Reject leftover positional arguments. Tools that take none, and tools that
# have already consumed the ones they expect, call this so a typo'd invocation
# fails loudly instead of silently running against the defaults.
no_extra_args() {
  if [[ $# -gt 0 ]]; then
    die "unexpected argument: $1"
  fi
}

private_tmpdir() {
  local prefix=${1:-netpack}
  umask 077
  mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

# Stdout report-content colors: only when stdout is a TTY, so redirected or
# piped evidence stays plain text. Honor NO_COLOR.
# Green = ok, red = bad/missing, amber = warn/note, blue = ASSESSMENT label.
NP_C_OK='' NP_C_BAD='' NP_C_WARN='' NP_C_VERDICT='' NP_C_OFF=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  NP_C_OK=$'\033[32m'
  NP_C_BAD=$'\033[31m'
  NP_C_WARN=$'\033[38;5;214m'
  NP_C_VERDICT=$'\033[34m'
  NP_C_OFF=$'\033[0m'
fi

# Separate palette for stderr-only progress: colored when stderr is a TTY even
# if stdout is piped (keeps `tool | tee` progress amber without leaking codes
# into the captured stdout).
NP_CE_WARN='' NP_CE_OFF=''
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  NP_CE_WARN=$'\033[38;5;214m'
  NP_CE_OFF=$'\033[0m'
fi

# color_status ok|bad|warn [text] — colored status token.
# Defaults: OK / MISSING / (text required for warn).
color_status() {
  local kind=$1 text
  case "$kind" in
    ok)   text=${2:-OK};      printf '%s%s%s' "$NP_C_OK" "$text" "$NP_C_OFF" ;;
    bad)  text=${2:-MISSING}; printf '%s%s%s' "$NP_C_BAD" "$text" "$NP_C_OFF" ;;
    warn) text=${2:?};        printf '%s%s%s' "$NP_C_WARN" "$text" "$NP_C_OFF" ;;
    *)    printf '%s' "${2:-$1}" ;;
  esac
}

# Amber note: / warning: lines. Colored by stdout's TTY state (NP_C_WARN); when
# a caller redirects these to stderr the color is dropped rather than risk
# leaking codes into a redirected stdout.
note() {
  printf '%snote: %s%s\n' "$NP_C_WARN" "$*" "$NP_C_OFF"
}

warning() {
  printf '%swarning: %s%s\n' "$NP_C_WARN" "$*" "$NP_C_OFF"
}

# Amber progress text (no trailing newline); caller supplies \\r / newline.
# Written only to stderr, so it uses the stderr palette.
progress() {
  printf '%s%s%s' "$NP_CE_WARN" "$*" "$NP_CE_OFF"
}

# pulse MESSAGE — one-line liveness ticker for long waits. A star at the head
# of the line steps through the splash's twinkle characters each call, so the
# animation advances only when the tool is really making progress. Drawn only
# when stderr is an interactive terminal: logs, pipes, and captured evidence
# never see ticker frames. Callers end the line with pulse_done.
NP_PULSE_FRAMES=('.' '+' '*' '+')
NP_PULSE_I=0
pulse() {
  [[ -t 2 ]] || return 0
  printf '\r%s%s %s%s\033[K' \
    "$NP_CE_WARN" "${NP_PULSE_FRAMES[NP_PULSE_I]}" "$*" "$NP_CE_OFF" >&2
  NP_PULSE_I=$(( (NP_PULSE_I + 1) % ${#NP_PULSE_FRAMES[@]} ))
}

# pulse_done [MESSAGE] — clear the ticker line, then print MESSAGE (if given)
# as an ordinary progress line. The message prints even without a TTY, so the
# final state of a long run still lands in logs and captured evidence.
pulse_done() {
  if [[ -t 2 ]]; then
    printf '\r\033[K' >&2
  fi
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$(progress "$*")" >&2
  fi
}

# Color a loss percentage: green if <=1, red if >1 (matches tool thresholds).
color_loss_pct() {
  local p=$1
  if awk -v p="$p" 'BEGIN { exit !(p > 1) }'; then
    color_status bad "${p}%"
  else
    color_status ok "${p}%"
  fi
}

section() {
  echo
  echo "=== $1 ==="
}

verdict() {
  echo "--"
  printf '%sASSESSMENT:%s %s\n' "$NP_C_VERDICT" "$NP_C_OFF" "$1"
  if [[ -n "${2:-}" ]]; then
    echo "Next: $2"
  fi
}

# Local timezone ISO-8601 timestamp with seconds (matches Python report.timestamp_local).
timestamp_local() {
  date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
}

# Print a standard tool report header: "name — <iso-local>"
header() {
  echo "$1 — $(timestamp_local)"
}

# Closing line for a completed run (matches Python report.finished).
finished() {
  echo "finished: $(timestamp_local)"
}
