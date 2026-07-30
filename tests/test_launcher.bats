#!/usr/bin/env bats
# Invariants for the launcher's tool metadata table.
#
# Every column the menu renders comes from TOOL_ROWS in bin/netpack. These tests
# guard the drift that a per-column lookup table invites: a tool added to a
# section but never given a description or tag, or a LOUD tool shipped without
# the consequence line the operator sees before it touches the network.

setup() {
  # REPO, not ROOT: sourcing the launcher defines its own BIN_DIR and would
  # clobber a variable named ROOT in older layouts.
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  NETPACK_SOURCE_ONLY=1 source "${REPO}/bin/netpack"
}

@test "every menu tool has metadata and an executable" {
  for t in "${TOOLS[@]}"; do
    [ -n "${TOOL_DESC[$t]:-}" ] || { echo "no description: $t"; return 1; }
    [ -x "${REPO}/bin/${t}" ] || { echo "not executable: bin/$t"; return 1; }
  done
}

@test "every table row is reachable from the menu" {
  for t in "${!TOOL_DESC[@]}"; do
    local found=0 x
    for x in "${TOOLS[@]}"; do
      [ "$x" = "$t" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || { echo "orphaned table row: $t"; return 1; }
  done
}

@test "root and traffic tags use only the documented vocabulary" {
  for t in "${TOOLS[@]}"; do
    case "${TOOL_ROOT[$t]:-}" in
      ''|'sudo?'|sudo) ;;
      *) echo "bad root tag for $t: ${TOOL_ROOT[$t]}"; return 1 ;;
    esac
    case "${TOOL_TRAFFIC[$t]:-}" in
      ''|probe|LOUD) ;;
      *) echo "bad traffic tag for $t: ${TOOL_TRAFFIC[$t]}"; return 1 ;;
    esac
  done
}

@test "LOUD tools carry a consequence line, quiet tools do not" {
  for t in "${TOOLS[@]}"; do
    if [ "${TOOL_TRAFFIC[$t]:-}" = "LOUD" ]; then
      [ -n "${TOOL_IMPACT[$t]:-}" ] || { echo "LOUD without impact note: $t"; return 1; }
    else
      [ -z "${TOOL_IMPACT[$t]:-}" ] || { echo "impact note on non-LOUD tool: $t"; return 1; }
    fi
  done
}

@test "needs_root implies wants_root" {
  for t in "${TOOLS[@]}"; do
    if needs_root "$t"; then
      wants_root "$t" || { echo "needs_root but not wants_root: $t"; return 1; }
    fi
  done
}

@test "menu numbering covers every sectioned tool exactly once" {
  build_menu_index
  # doctor is keyed 'd', so it is the one tool outside the numbered sections.
  [ "${#MENU_TOOLS[@]}" -eq "$(( ${#TOOLS[@]} - 1 ))" ]
  run resolve_selection "${#MENU_TOOLS[@]}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run resolve_selection "$(( ${#MENU_TOOLS[@]} + 1 ))"
  [ "$output" = "" ]
}

@test "list output keeps the tools-end-at-first-blank-line contract" {
  # CI parses `netpack list` this way; changing the format must not break it.
  # awk sets a flag rather than exiting: exiting early closes its end of the
  # pipe while netpack is still writing the legend that follows, and under
  # netpack's `set -o pipefail` that write fails with EPIPE and aborts the
  # script — nondeterministically, since it depends on whether the kernel
  # pipe buffer absorbed netpack's full output before awk got scheduled.
  run bash -c "NO_COLOR=1 '${REPO}/bin/netpack' list \
    | awk 'NR > 2 { if (NF == 0) stop = 1; if (!stop && \$1 ~ /^[a-z0-9-]+\$/) print \$1 }' | wc -l"
  [ "$status" -eq 0 ]
  [ "$output" -eq "${#TOOLS[@]}" ]
}

@test "capture writes a log, a manifest row, and preserves the exit code" {
  local dir="${BATS_TEST_TMPDIR}/cap"
  # portcheck against a closed local port exits 2: a non-zero code that is a
  # diagnostic result, so it must survive the tee pipeline unchanged.
  run env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" portcheck 127.0.0.1 22
  [ "$status" -eq 2 ]
  [ -f "${dir}/manifest.tsv" ]

  # One log, named for the tool.
  local logs=("${dir}"/portcheck-*.log)
  [ "${#logs[@]}" -eq 1 ]
  grep -q "ASSESSMENT:" "${logs[0]}"

  # Manifest row records the retypable command and the exit code.
  local row
  row="$(grep -v '^#' "${dir}/manifest.tsv")"
  [ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ]
  [ "$(printf '%s' "$row" | cut -f3)" = "2" ]
  [ "$(printf '%s' "$row" | cut -f5)" = "portcheck 127.0.0.1 22" ]
}

@test "capture appends across runs and keeps the directory owner-only" {
  local dir="${BATS_TEST_TMPDIR}/cap2"
  env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" portcheck 127.0.0.1 22 >/dev/null || true
  env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" portcheck 127.0.0.1 23 >/dev/null || true
  [ "$(grep -cv '^#' "${dir}/manifest.tsv")" -eq 2 ]
  [ "$(stat -c '%a' "$dir")" = "700" ]
}

@test "-o without a directory is a usage error" {
  run "${REPO}/bin/netpack" -o
  [ "$status" -eq 1 ]
}
