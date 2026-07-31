#!/usr/bin/env bats
# Invariants for the launcher's tool metadata table.
#
# Every column the menu renders comes from TOOL_ROWS in bin/netpack. These tests
# guard the drift that a per-column lookup table invites: a tool added to a
# section but never given a description or tag, or a loud tool shipped without
# the consequence line the operator sees before it touches the network.

setup() {
  # REPO, not ROOT: sourcing the launcher defines its own BIN_DIR and would
  # clobber a variable named ROOT in older layouts.
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  NETPACK_SOURCE_ONLY=1 source "${REPO}/bin/netpack"
}

# A local port with nothing listening. Hardcoding a port (22, say) breaks on
# hosts that run the service: GitHub-hosted runners keep sshd up, so a "closed
# port" probe against 22 succeeds there and inverts the expected exit code.
closed_port() {
  local p
  for p in 47321 47322 47323 47324 47325; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  echo "no closed port found in probe range" >&2
  return 1
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
      ''|probe|loud) ;;
      *) echo "bad traffic tag for $t: ${TOOL_TRAFFIC[$t]}"; return 1 ;;
    esac
  done
}

@test "loud tools carry a consequence line, quiet tools do not" {
  for t in "${TOOLS[@]}"; do
    if [ "${TOOL_TRAFFIC[$t]:-}" = "loud" ]; then
      [ -n "${TOOL_IMPACT[$t]:-}" ] || { echo "loud without impact note: $t"; return 1; }
    else
      [ -z "${TOOL_IMPACT[$t]:-}" ] || { echo "impact note on non-loud tool: $t"; return 1; }
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
  local port
  port="$(closed_port)"
  # portcheck against a closed local port exits 2: a non-zero code that is a
  # diagnostic result, so it must survive the tee pipeline unchanged.
  run env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" portcheck 127.0.0.1 "$port"
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
  [ "$(printf '%s' "$row" | cut -f5)" = "portcheck 127.0.0.1 ${port}" ]
}

@test "capture auto-dumps JSON for tools that support it" {
  local dir="${BATS_TEST_TMPDIR}/cap-json"
  # linkstat against loopback: dump-capable, needs no root and no network.
  run env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" linkstat -i lo -t 1
  [ "$status" -eq 0 ]
  local dumps=("${dir}"/linkstat-*.json)
  [ "${#dumps[@]}" -eq 1 ]
  grep -q '"tool": "linkstat"' "${dumps[0]}"
}

@test "capture leaves an operator-chosen --dump path alone" {
  local dir="${BATS_TEST_TMPDIR}/cap-json2"
  run env NO_COLOR=1 "${REPO}/bin/netpack" -o "$dir" \
    linkstat -i lo -t 1 --dump "${dir}/custom.json"
  [ "$status" -eq 0 ]
  grep -q '"tool": "linkstat"' "${dir}/custom.json"
  # No second, auto-named dump alongside the chosen one.
  local dumps=("${dir}"/linkstat-*.json)
  [ ! -e "${dumps[0]}" ]
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

@test "every playbook step names a real tool" {
  for id in "${PLAYBOOK_IDS[@]}"; do
    while IFS=$'\t' read -r cmd why; do
      [ -n "$cmd" ] || { echo "empty step in playbook: $id"; return 1; }
      [ -n "$why" ] || { echo "step without a reason: $id / $cmd"; return 1; }
      # The step may carry arguments; the first field is the tool.
      local tool="${cmd%% *}" found=0 t
      for t in "${TOOLS[@]}"; do
        [ "$t" = "$tool" ] && found=1 && break
      done
      [ "$found" -eq 1 ] || { echo "playbook $id references unknown tool: $tool"; return 1; }
    done < <(playbook_steps "$id")
  done
}

@test "every playbook has a title and at least two steps" {
  for id in "${PLAYBOOK_IDS[@]}"; do
    [ -n "$(playbook_title "$id")" ] || { echo "no title: $id"; return 1; }
    local n
    n="$(playbook_steps "$id" | wc -l)"
    # A one-step playbook is just a tool; it should not be listed as a sequence.
    [ "$n" -ge 2 ] || { echo "playbook $id has $n step(s)"; return 1; }
  done
}

@test "no orphaned rows in the playbook step table" {
  local row id found x
  for row in "${PLAYBOOK_STEPS[@]}"; do
    IFS='|' read -r id _ <<<"$row"
    id="$(trim "$id")"
    found=0
    for x in "${PLAYBOOK_IDS[@]}"; do
      [ "$x" = "$id" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || { echo "step for undeclared playbook: $id"; return 1; }
  done
}

@test "resolve_playbook accepts a number or a name" {
  run resolve_playbook 1
  [ "$output" = "${PLAYBOOK_IDS[0]}" ]
  run resolve_playbook "${PLAYBOOK_IDS[0]}"
  [ "$output" = "${PLAYBOOK_IDS[0]}" ]
  run resolve_playbook "$(( ${#PLAYBOOK_IDS[@]} + 1 ))"
  [ "$output" = "" ]
  run resolve_playbook nosuchplaybook
  [ "$output" = "" ]
}

@test "an unknown playbook is a usage error" {
  run "${REPO}/bin/netpack" playbook nosuchplaybook
  [ "$status" -eq 1 ]
}
