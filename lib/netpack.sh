# Shared helpers for netpack bash tools.
# shellcheck shell=bash
# Keep iface/gateway/validation in sync with lib/netpack/net.py.

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

list_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
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

default_iface() {
  local iface
  iface="$(ip -o route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
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
  ip -o route show default 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}'
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

private_tmpdir() {
  local prefix=${1:-netpack}
  umask 077
  mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

verdict() {
  echo "--"
  printf '%sVERDICT:%s %s\n' "$NP_C_VERDICT" "$NP_C_OFF" "$1"
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

# Status colors when stdout is a TTY; honor NO_COLOR.
# Green = ok, red = bad/missing, amber = warn/other, blue = VERDICT label.
NP_C_OK='' NP_C_BAD='' NP_C_WARN='' NP_C_VERDICT='' NP_C_OFF=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  NP_C_OK=$'\033[32m'
  NP_C_BAD=$'\033[31m'
  NP_C_WARN=$'\033[38;5;214m'
  NP_C_VERDICT=$'\033[34m'
  NP_C_OFF=$'\033[0m'
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
