# Shared helpers for netpack bash tools.
# shellcheck shell=bash

netpack_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${here}/.." && pwd
}

netpack_bin() {
  echo "$(netpack_root)/bin"
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

private_tmpdir() {
  local prefix=${1:-netpack}
  umask 077
  mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

verdict() {
  echo "--"
  echo "VERDICT: $1"
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
