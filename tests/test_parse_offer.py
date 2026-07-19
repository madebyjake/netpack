"""Tests for dhcpprobe offer parsing, using scapy packets built in-memory."""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path

import pytest

pytest.importorskip("scapy")

ROOT = Path(__file__).resolve().parents[1]


def _load_dhcpprobe():
    path = ROOT / "bin" / "dhcpprobe"
    loader = importlib.machinery.SourceFileLoader("dhcpprobe", str(path))
    spec = importlib.util.spec_from_loader("dhcpprobe", loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


dhcpprobe = _load_dhcpprobe()


def make_offer(options: list, yiaddr: str = "192.168.1.50"):
    """Build a DHCPOFFER and round-trip it through bytes to mimic a sniffed packet."""
    from scapy.layers.dhcp import BOOTP, DHCP
    from scapy.layers.inet import IP, UDP
    from scapy.layers.l2 import Ether

    pkt = (
        Ether(src="02:00:00:aa:bb:cc", dst="ff:ff:ff:ff:ff:ff")
        / IP(src="192.168.1.1", dst="255.255.255.255")
        / UDP(sport=67, dport=68)
        / BOOTP(yiaddr=yiaddr, xid=0x1234)
        / DHCP(options=options)
    )
    return Ether(bytes(pkt))


def test_parse_offer_full() -> None:
    offer = make_offer(
        [
            ("message-type", "offer"),
            ("server_id", "192.168.1.1"),
            ("subnet_mask", "255.255.255.0"),
            ("router", "192.168.1.1"),
            ("name_server", "1.1.1.1", "8.8.8.8"),
            ("domain", b"lan.example"),
            ("lease_time", 3600),
            "end",
        ]
    )
    parsed = dhcpprobe.parse_offer(offer)
    assert parsed["server_id"] == "192.168.1.1"
    assert parsed["server_mac"] == "02:00:00:aa:bb:cc"
    assert parsed["src_ip"] == "192.168.1.1"
    assert parsed["offered_ip"] == "192.168.1.50"
    assert parsed["offered_cidr"] == "192.168.1.50/24"
    assert parsed["routers"] == ["192.168.1.1"]
    assert parsed["dns"] == ["1.1.1.1", "8.8.8.8"]
    assert parsed["domain"] == "lan.example"
    assert parsed["lease_seconds"] == 3600


def test_parse_offer_no_mask() -> None:
    offer = make_offer(
        [
            ("message-type", "offer"),
            ("server_id", "192.168.1.1"),
            "end",
        ]
    )
    parsed = dhcpprobe.parse_offer(offer)
    assert parsed["offered_ip"] == "192.168.1.50"
    assert parsed["offered_cidr"] == "192.168.1.50"
    assert parsed["subnet_mask"] is None


def test_parse_offer_server_id_falls_back_to_src_ip() -> None:
    offer = make_offer(
        [
            ("message-type", "offer"),
            "end",
        ]
    )
    parsed = dhcpprobe.parse_offer(offer)
    assert parsed["server_id"] == "192.168.1.1"


def test_parse_offer_zero_yiaddr() -> None:
    offer = make_offer(
        [
            ("message-type", "offer"),
            ("server_id", "192.168.1.1"),
            "end",
        ],
        yiaddr="0.0.0.0",
    )
    parsed = dhcpprobe.parse_offer(offer)
    assert parsed["offered_ip"] is None
    assert parsed["offered_cidr"] is None
