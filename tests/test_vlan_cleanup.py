"""dhcpprobe -V must not leave the VLAN sub-interface it created behind.

The tool creates eth0.<vid> and promises to remove it on exit. SIGTERM's
default action ends the process outright, skipping the finally that removes it,
so a `kill` would leave the box with an interface the run created.

`ip` is stubbed on PATH and its calls recorded, so this runs anywhere.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def ip_stub(tmp_path: Path) -> tuple[Path, Path]:
    """A fake `ip` on PATH that records its arguments and always succeeds."""
    calls = tmp_path / "ip.log"
    stub = tmp_path / "ip"
    stub.write_text(f'#!/usr/bin/env bash\necho "$@" >> {calls}\nexit 0\n')
    stub.chmod(0o755)
    return tmp_path, calls


_DRIVER = """\
import sys, signal, time, importlib.util
from importlib.machinery import SourceFileLoader
sys.path.insert(0, {lib!r})
loader = SourceFileLoader("dhcpprobe", {tool!r})
spec = importlib.util.spec_from_loader("dhcpprobe", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.list_ifaces = lambda: ["eth0"]
created = False
try:
    _sub, created = m.vlan_setup("eth0", 100)
{handler}    print("READY", flush=True)
    time.sleep(30)
finally:
    if created:
        m.vlan_teardown("eth0.100")
"""

_HANDLER = "    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(128 + s))\n"


def _driver(install_handler: bool) -> str:
    return _DRIVER.format(
        lib=str(ROOT / "lib"),
        tool=str(ROOT / "bin" / "dhcpprobe"),
        handler=_HANDLER if install_handler else "",
    )


def _run_and_terminate(driver: str, stub_dir: Path) -> None:
    env = dict(os.environ, PATH=f"{stub_dir}:{os.environ['PATH']}")
    proc = subprocess.Popen(
        [sys.executable, "-c", driver],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert proc.stdout is not None and proc.stderr is not None
        ready = False
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:  # child exited; do not spin to the deadline
                break
            if line.strip() == "READY":
                ready = True
                break
        assert ready, f"driver never reached READY: {proc.stderr.read()}"
        proc.send_signal(signal.SIGTERM)
        proc.communicate(timeout=20)
    finally:
        if proc.poll() is None:  # pragma: no cover - only on a hang
            proc.kill()
            proc.wait(timeout=10)


def test_sigterm_removes_a_vlan_the_run_created(ip_stub: tuple[Path, Path]) -> None:
    stub_dir, calls = ip_stub
    _run_and_terminate(_driver(install_handler=True), stub_dir)
    log = calls.read_text()
    assert "link add link eth0 name eth0.100" in log, "setup did not run"
    assert "link del eth0.100" in log, "SIGTERM left the sub-interface behind"


def test_without_the_handler_the_interface_would_leak(
    ip_stub: tuple[Path, Path],
) -> None:
    """Pins why the handler exists: the same driver without it leaks."""
    stub_dir, calls = ip_stub
    _run_and_terminate(_driver(install_handler=False), stub_dir)
    log = calls.read_text()
    assert "link add link eth0 name eth0.100" in log
    assert "link del eth0.100" not in log


def test_an_existing_sub_interface_is_reused_and_left_alone(
    ip_stub: tuple[Path, Path],
) -> None:
    """Reuse must not create, and must not delete on the way out: the operator
    configured that interface, so the tool has no business removing it."""
    stub_dir, calls = ip_stub
    driver = textwrap.dedent(f"""
        import sys, importlib.util
        from importlib.machinery import SourceFileLoader
        sys.path.insert(0, {str(ROOT / "lib")!r})
        loader = SourceFileLoader("dhcpprobe", {str(ROOT / "bin" / "dhcpprobe")!r})
        spec = importlib.util.spec_from_loader("dhcpprobe", loader)
        m = importlib.util.module_from_spec(spec); loader.exec_module(m)
        m.list_ifaces = lambda: ["eth0", "eth0.100"]
        sub, created = m.vlan_setup("eth0", 100)
        assert sub == "eth0.100" and created is False, (sub, created)
    """)
    env = dict(os.environ, PATH=f"{stub_dir}:{os.environ['PATH']}")
    subprocess.run(
        [sys.executable, "-c", driver], env=env, check=True, capture_output=True
    )
    log = calls.read_text() if calls.exists() else ""
    assert "link add" not in log
    assert "link del" not in log
