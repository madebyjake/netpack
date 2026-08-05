"""Tests for interface resolution and privilege checks.

net.py reads /sys/class/net and shells out to ip, so the sysfs fixture below
redirects its path lookups into tmp_path and the subprocess calls are patched.
That keeps these runnable on a machine with neither.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack import net
from netpack.net import (
    NetError,
    default_iface,
    iface_ipv4,
    iface_is_up,
    is_wireless,
    list_ifaces,
    require_root,
    resolve_iface,
    validate_iface,
)


@pytest.fixture
def sysfs(tmp_path, monkeypatch):
    """Redirect net.py's /sys/class/net lookups into tmp_path."""
    root = tmp_path / "sys" / "class" / "net"
    root.mkdir(parents=True)

    def fake_path(p: str) -> Path:
        text = str(p)
        if text.startswith("/sys/class/net"):
            return Path(str(root) + text[len("/sys/class/net") :])
        return Path(text)

    monkeypatch.setattr(net, "Path", fake_path)
    return root


def make_iface(
    root: Path,
    name: str,
    *,
    operstate: str | None = None,
    flags: str | None = None,
    wireless: bool = False,
) -> None:
    d = root / name
    d.mkdir()
    if operstate is not None:
        (d / "operstate").write_text(operstate + "\n", encoding="utf-8")
    if flags is not None:
        (d / "flags").write_text(flags + "\n", encoding="utf-8")
    if wireless:
        (d / "wireless").mkdir()


def test_list_ifaces_is_sorted(sysfs) -> None:
    for name in ("wlan0", "eth0", "lo"):
        make_iface(sysfs, name)
    assert list_ifaces() == ["eth0", "lo", "wlan0"]


def test_list_ifaces_is_empty_without_sysfs(monkeypatch) -> None:
    monkeypatch.setattr(net, "Path", lambda p: Path("/nonexistent/class/net"))
    assert list_ifaces() == []


@pytest.mark.parametrize("name", ["", "eth 0", "eth/0", "eth;rm", "eth\n0"])
def test_validate_iface_rejects_names_outside_the_charset(sysfs, name) -> None:
    with pytest.raises(NetError):
        validate_iface(name)


def test_validate_iface_rejects_a_name_that_does_not_exist(sysfs) -> None:
    make_iface(sysfs, "eth0")
    with pytest.raises(NetError):
        validate_iface("eth1")


def test_validate_iface_accepts_vlan_and_bridge_forms(sysfs) -> None:
    for name in ("eth0.100", "br-lan", "en_p1s0", "eth0:1"):
        make_iface(sysfs, name)
        assert validate_iface(name) == name


def test_is_wireless_by_prefix_without_sysfs(sysfs) -> None:
    # Covers drivers that do not populate /sys/class/net/*/wireless.
    for name in ("wlan0", "wlp3s0", "wlx001122334455"):
        assert is_wireless(name)


def test_is_wireless_by_sysfs_entry(sysfs) -> None:
    make_iface(sysfs, "eth0", wireless=True)
    make_iface(sysfs, "eth1")
    assert is_wireless("eth0")
    assert not is_wireless("eth1")


@pytest.mark.parametrize(
    ("operstate", "flags", "expected"),
    [
        ("up", None, True),
        ("down", "0x1003", False),
        ("unknown", "0x1003", True),
        ("unknown", "0x1002", False),
        ("unknown", None, False),
        (None, "0x1003", True),
        (None, "0x1002", False),
    ],
)
def test_iface_is_up(sysfs, operstate, flags, expected) -> None:
    make_iface(sysfs, "eth0", operstate=operstate, flags=flags)
    assert iface_is_up("eth0") is expected


def test_iface_is_up_treats_unparseable_flags_as_down(sysfs) -> None:
    make_iface(sysfs, "eth0", operstate="unknown", flags="not-a-number")
    assert iface_is_up("eth0") is False


def test_default_iface_reads_the_route(sysfs, monkeypatch) -> None:
    make_iface(sysfs, "eth0")
    monkeypatch.setattr(
        net.subprocess,
        "check_output",
        lambda *a, **k: "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.5 uid 1000\n",
    )
    assert default_iface() == "eth0"


def test_default_iface_falls_back_to_the_first_non_loopback(sysfs, monkeypatch) -> None:
    # A box with no default route must still name an interface.
    make_iface(sysfs, "lo")
    make_iface(sysfs, "eth0")
    monkeypatch.setattr(
        net.subprocess,
        "check_output",
        lambda *a, **k: (_ for _ in ()).throw(subprocess.CalledProcessError(2, "ip")),
    )
    assert default_iface() == "eth0"


def test_default_iface_raises_when_only_loopback_exists(sysfs, monkeypatch) -> None:
    make_iface(sysfs, "lo")
    monkeypatch.setattr(
        net.subprocess,
        "check_output",
        lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError("ip")),
    )
    with pytest.raises(NetError):
        default_iface()


def test_default_iface_falls_back_when_the_route_names_an_unknown_iface(
    sysfs, monkeypatch
) -> None:
    # validate_iface rejects it, so the fallback runs rather than returning a
    # name that is not present.
    make_iface(sysfs, "eth0")
    monkeypatch.setattr(
        net.subprocess, "check_output", lambda *a, **k: "1.1.1.1 dev ghost0 src 10.0.0.1\n"
    )
    assert default_iface() == "eth0"


def test_iface_ipv4_returns_the_first_address(monkeypatch) -> None:
    monkeypatch.setattr(
        net.subprocess,
        "check_output",
        lambda *a, **k: (
            "2: eth0    inet 192.168.1.5/24 brd 192.168.1.255 scope global eth0\\ valid_lft forever\n"
        ),
    )
    assert iface_ipv4("eth0") == "192.168.1.5"


def test_iface_ipv4_is_none_without_an_address(monkeypatch) -> None:
    monkeypatch.setattr(net.subprocess, "check_output", lambda *a, **k: "")
    assert iface_ipv4("eth0") is None


def test_iface_ipv4_is_none_when_ip_is_missing(monkeypatch) -> None:
    monkeypatch.setattr(
        net.subprocess,
        "check_output",
        lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError("ip")),
    )
    assert iface_ipv4("eth0") is None


def test_resolve_iface_validates_an_explicit_name(sysfs) -> None:
    make_iface(sysfs, "eth0")
    assert resolve_iface("eth0") == "eth0"
    with pytest.raises(NetError):
        resolve_iface("eth1")


def test_resolve_iface_falls_back_to_the_default(sysfs, monkeypatch) -> None:
    make_iface(sysfs, "eth0")
    monkeypatch.setattr(net, "default_iface", lambda: "eth0")
    assert resolve_iface(None) == "eth0"
    assert resolve_iface("") == "eth0"


def test_require_root(monkeypatch) -> None:
    monkeypatch.setattr(net.os, "geteuid", lambda: 0)
    require_root()
    monkeypatch.setattr(net.os, "geteuid", lambda: 1000)
    with pytest.raises(NetError):
        require_root()
