"""The dump's assessment_code must equal the status the process exited with.

The README documents it as "the exit code the run produced", but the other
tests check that only at source level. This runs a tool for real and compares.

portcheck is the one tool that measures without leaving the machine: a listener
on loopback and a closed port give both outcomes deterministically, with no
network and no root. It exercises the shared take_dump_opt / dump_write /
finish_with path every bash tool uses.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PORTCHECK = ROOT / "bin" / "portcheck"

pytestmark = pytest.mark.skipif(
    shutil.which("timeout") is None,
    reason="portcheck requires GNU timeout",
)


@contextmanager
def listener() -> Iterator[int]:
    """A bound, listening TCP socket on loopback; yields its port."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        yield sock.getsockname()[1]
    finally:
        sock.close()


def closed_port() -> int:
    """A port nothing is listening on: bound to claim it, then released."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def run_portcheck(port: int, dump: Path) -> tuple[int, dict]:
    proc = subprocess.run(
        [str(PORTCHECK), "-t", "2", "--dump", str(dump), "127.0.0.1", str(port)],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert dump.is_file(), f"no dump written; stderr: {proc.stderr}"
    return proc.returncode, json.loads(dump.read_text())


def test_open_port_exits_zero_and_records_zero(tmp_path: Path) -> None:
    with listener() as port:
        code, payload = run_portcheck(port, tmp_path / "open.json")
    assert code == 0
    assert payload["assessment_code"] == code
    assert payload["ports_failed"] == 0
    assert payload["interrupted"] is False


def test_closed_port_exits_two_and_records_two(tmp_path: Path) -> None:
    code, payload = run_portcheck(closed_port(), tmp_path / "closed.json")
    assert code == 2, "a refused connection is a condition found, not an error"
    assert payload["assessment_code"] == code
    assert payload["ports_failed"] == 1


def test_dump_carries_the_contract_keys(tmp_path: Path) -> None:
    with listener() as port:
        _, payload = run_portcheck(port, tmp_path / "keys.json")
    for key in ("tool", "timestamp", "assessment_code"):
        assert key in payload, f"dump is missing the required key {key!r}"
    assert payload["tool"] == "portcheck"


def test_probed_count_never_exceeds_the_total(tmp_path: Path) -> None:
    """ports_probed is what was actually tried; ports_total is what was asked
    for. A completed run has them equal."""
    with listener() as port:
        _, payload = run_portcheck(port, tmp_path / "counts.json")
    assert payload["ports_probed"] == payload["ports_total"] == 1


def test_usage_error_exits_one_not_two(tmp_path: Path) -> None:
    """2 already means "condition found", so a typo must not read as one."""
    proc = subprocess.run(
        [str(PORTCHECK), "127.0.0.1", "not-a-port"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert proc.returncode == 1
    assert not (tmp_path / "unused.json").exists()


def test_explicit_dump_path_is_honoured(tmp_path: Path) -> None:
    """capture appends its own --dump; an explicit one must win, and the file
    must land exactly where it was asked for."""
    target = tmp_path / "nested" / "deep" / "evidence.json"
    with listener() as port:
        code, _ = run_portcheck(port, target)
    assert code == 0
    assert target.is_file(), "write_dump did not create parent directories"


# --- interrupted runs --------------------------------------------------------


def _interrupt_portcheck(dump: Path, ports: list[str]) -> tuple[int, str]:
    """Start portcheck against an address that never answers, interrupt it.

    192.0.2.1 is TEST-NET-1 (RFC 5737), so the probe blocks on its timeout and
    there is a window to signal. start_new_session puts the tool in its own
    process group: a background child of a non-interactive shell inherits
    SIGINT ignored, and bash cannot trap a signal ignored on entry.
    """
    proc = subprocess.Popen(
        [str(PORTCHECK), "-t", "30", "--dump", str(dump), "192.0.2.1", *ports],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        time.sleep(2)
        os.killpg(proc.pid, signal.SIGINT)
        out, _ = proc.communicate(timeout=60)
    except subprocess.TimeoutExpired:  # pragma: no cover - only on a hang
        os.killpg(proc.pid, signal.SIGKILL)
        raise
    return proc.returncode, out


def test_interrupt_writes_the_dump_and_exits_130(tmp_path: Path) -> None:
    dump = tmp_path / "interrupted.json"
    code, out = _interrupt_portcheck(dump, ["9", "10"])
    assert code == 130, f"expected 130, got {code}\n{out}"
    assert "ASSESSMENT:" in out, f"report not printed\n{out}"
    assert "finished:" in out, f"report not closed\n{out}"
    assert dump.is_file(), f"no dump written\n{out}"

    payload = json.loads(dump.read_text())
    assert payload["assessment_code"] == code
    assert payload["interrupted"] is True
    assert payload["ports_probed"] < payload["ports_total"]


def test_unprobed_ports_are_not_counted_as_closed(tmp_path: Path) -> None:
    """A port the run never tried must not reach ports_failed; that would name
    filtering the tool never observed."""
    dump = tmp_path / "unprobed.json"
    _, out = _interrupt_portcheck(dump, ["9", "10", "11"])
    payload = json.loads(dump.read_text())
    assert payload["ports_failed"] <= payload["ports_probed"]
    assert "not probed" in out


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
