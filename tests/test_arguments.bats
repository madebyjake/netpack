#!/usr/bin/env bats
# Every tool rejects input it does not understand.
#
# CONTRIBUTING requires this of every tool, but nothing enforced it: a tool that
# falls back to defaults on a typo'd flag produces confident, wrong evidence.
# Argument parsing runs before any network access or privilege check, so these
# execute on any platform.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  NETPACK_SOURCE_ONLY=1 source "${REPO}/bin/netpack"
}

# Tools that take positional arguments of their own; every other tool must
# reject any positional it is handed.
takes_positional() {
  case "$1" in
    portcheck|path3|testcli|mcastcheck) return 0 ;;
    *) return 1 ;;
  esac
}

@test "every tool rejects an unknown flag with exit 1" {
  for t in "${TOOLS[@]}"; do
    run "${REPO}/bin/${t}" --definitely-not-a-flag
    if [ "$status" -ne 1 ]; then
      echo "${t}: exit ${status}, expected 1"
      return 1
    fi
  done
}

@test "tools that take no positional arguments reject one" {
  for t in "${TOOLS[@]}"; do
    if takes_positional "$t"; then
      continue
    fi
    run "${REPO}/bin/${t}" definitely-not-an-argument
    if [ "$status" -ne 1 ]; then
      echo "${t}: exit ${status}, expected 1"
      return 1
    fi
  done
}

@test "tools that take positional arguments reject a surplus one" {
  run "${REPO}/bin/path3" 198.51.100.1 surplus
  [ "$status" -eq 1 ]
  run "${REPO}/bin/testcli" 198.51.100.1 surplus
  [ "$status" -eq 1 ]
}

@test "unknown flags are rejected before the network is touched" {
  # A rejection that needed a route or a resolver would hang in the field and
  # would not run in CI. Bounded so a regression fails rather than stalls.
  for t in "${TOOLS[@]}"; do
    run timeout 5 "${REPO}/bin/${t}" --definitely-not-a-flag
    if [ "$status" -eq 124 ]; then
      echo "${t}: timed out rejecting an unknown flag"
      return 1
    fi
  done
}

@test "usage errors never exit 2, which means condition found" {
  # 2+ is a diagnostic result in every tool; a typo returning 2 would read as
  # one. This is the specific mistake CONTRIBUTING calls out.
  for t in "${TOOLS[@]}"; do
    run "${REPO}/bin/${t}" --definitely-not-a-flag
    if [ "$status" -ge 2 ]; then
      echo "${t}: exit ${status} for a usage error"
      return 1
    fi
  done
}
