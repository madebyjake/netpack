#!/usr/bin/env bats
# testcli must not report a cut-short run as completed.
#
# iperf3 treats SIGINT as a normal end: iperf_got_sigend calls
# iperf_signormalexit, which exits 0 after printing partial results. The exit
# status therefore cannot distinguish an interrupted run from a finished one,
# and testcli's documented 130 branch was unreachable.
#
# iperf3 is stubbed so these run without it installed and without traffic.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STUB="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "$STUB"
}

# stub_iperf3 BODY — put a fake iperf3 first on PATH.
stub_iperf3() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"${STUB}/iperf3"
  chmod +x "${STUB}/iperf3"
}

# run_interrupted — start testcli in its own process group and SIGINT it.
# Job control is required: a background child of a non-interactive shell
# inherits SIGINT ignored, and bash cannot trap a signal ignored on entry.
run_interrupted() {
  local out="${BATS_TEST_TMPDIR}/out"
  STATUS=0
  # Single-quoted body: values arrive through the environment rather than being
  # interpolated, so the nested quoting stays readable.
  STUB="$STUB" REPO="$REPO" OUTFILE="$out" /usr/bin/env bash -c '
    set -m
    PATH="$STUB:$PATH" "$REPO/bin/testcli" -t 30 127.0.0.1 >"$OUTFILE" 2>&1 &
    P=$!
    sleep 1.5
    kill -INT -$P
    wait $P
  ' || STATUS=$?
  OUT="$(cat "$out")"
}

@test "an interrupted run exits 130 and says so" {
  # Mimics iperf3: prints partial results on SIGINT, then exits 0.
  stub_iperf3 'trap "echo partial-results; exit 0" INT; echo connecting; sleep 30'
  run_interrupted
  [ "$STATUS" -eq 130 ]
  [[ "$OUT" == *"run interrupted"* ]]
  # Not the completion verdict. Matched on "run against", because the
  # interrupted wording legitimately contains "completed portion".
  [[ "$OUT" != *"run against"* ]]
  # The partial figures are still evidence and must survive.
  [[ "$OUT" == *"partial-results"* ]]
  [[ "$OUT" == *"finished:"* ]]
}

@test "a completed run still reports completed and exits 0" {
  stub_iperf3 'echo "0.00-1.00 sec 118 MBytes 988 Mbits/sec"; exit 0'
  run env PATH="${STUB}:$PATH" "${REPO}/bin/testcli" -t 1 127.0.0.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"run against"* ]]
  [[ "$output" != *"run interrupted"* ]]
}

@test "an iperf3 failure still maps to exit 1" {
  stub_iperf3 'echo "iperf3: error - unable to connect to server" >&2; exit 1'
  run env PATH="${STUB}:$PATH" "${REPO}/bin/testcli" -t 1 127.0.0.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"iperf3 exited 1"* ]]
}
