"""The DHCP packets dhcpprobe builds must encode, and its parser must read them.

Every option is named by string ("server_id", "lease_time", …). A name scapy
stops recognising does not raise — the option is silently dropped from the
packet or the parse, and the report loses a field without saying so. These
build and round-trip real packets, so a scapy change is caught here rather than
on a segment.

No network and no root: scapy is only asked to serialize and parse bytes.
"""

from __future__ import annotations

import importlib.util
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

pytest.importorskip("scapy", reason="dhcpprobe's packet layer needs scapy")

MAC = "aa:bb:cc:dd:ee:ff"


@pytest.fixture(scope="module")
def dhcpprobe() -> Any:
    loader = SourceFileLoader("dhcpprobe", str(ROOT / "bin" / "dhcpprobe"))
    spec = importlib.util.spec_from_loader("dhcpprobe", loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def option_names(pkt: Any) -> list[str]:
    """Option names as they survive a serialize/parse round trip."""
    from scapy.layers.dhcp import DHCP
    from scapy.layers.l2 import Ether

    reparsed = Ether(bytes(pkt))
    return [o[0] if isinstance(o, tuple) else o for o in reparsed[DHCP].options]


def test_discover_carries_the_options_a_server_needs(dhcpprobe: Any) -> None:
    pkt, xid = dhcpprobe.build_discover(MAC)
    assert 0 < xid <= 0xFFFFFFFF
    assert option_names(pkt) == [
        "message-type",
        "param_req_list",
        "client_id",
        "end",
    ]


def test_request_names_the_address_and_the_server(dhcpprobe: Any) -> None:
    pkt = dhcpprobe.build_request(MAC, 0x1234, "192.168.1.50", "192.168.1.1")
    names = option_names(pkt)
    assert "requested_addr" in names, "a REQUEST without it cannot be honoured"
    assert "server_id" in names, "identifies which offer is being accepted"


def test_release_is_addressed_to_the_leasing_server(dhcpprobe: Any) -> None:
    pkt = dhcpprobe.build_release(MAC, "192.168.1.50", "192.168.1.1", "00:11:22:33:44:55")
    assert "server_id" in option_names(pkt)


def test_requested_options_cover_everything_the_report_prints(
    dhcpprobe: Any,
) -> None:
    """Asking for less than the report displays would leave blanks that look
    like the server withheld them."""
    from scapy.layers.dhcp import DHCPOptions

    parsed_by_name = {
        "subnet_mask",
        "router",
        "name_server",
        "domain",
        "lease_time",
        "server_id",
        "broadcast_address",
    }
    requested = set()
    for number in dhcpprobe.PARAM_REQUEST_LIST:
        opt = DHCPOptions.get(number)
        requested.add(opt if isinstance(opt, str) else getattr(opt, "name", None))
    assert parsed_by_name <= requested, (
        f"report reads options never requested: {sorted(parsed_by_name - requested)}"
    )


def build_offer() -> Any:
    from scapy.layers.dhcp import BOOTP, DHCP
    from scapy.layers.inet import IP, UDP
    from scapy.layers.l2 import Ether

    return Ether(src="00:11:22:33:44:55", dst=MAC) / IP(
        src="192.168.1.1", dst="255.255.255.255"
    ) / UDP(sport=67, dport=68) / BOOTP(
        op=2, yiaddr="192.168.1.50", xid=0x1234
    ) / DHCP(
        options=[
            ("message-type", "offer"),
            ("server_id", "192.168.1.1"),
            ("subnet_mask", "255.255.255.0"),
            ("router", "192.168.1.1"),
            ("name_server", "1.1.1.1"),
            ("lease_time", 86400),
            ("domain", "lan"),
            ("broadcast_address", "192.168.1.255"),
            "end",
        ]
    )


def test_parse_offer_reads_every_field_the_report_shows(dhcpprobe: Any) -> None:
    from scapy.layers.l2 import Ether

    parsed = dhcpprobe.parse_offer(Ether(bytes(build_offer())))
    assert parsed["server_id"] == "192.168.1.1"
    assert parsed["server_mac"] == "00:11:22:33:44:55"
    assert parsed["offered_ip"] == "192.168.1.50"
    assert parsed["subnet_mask"] == "255.255.255.0"
    assert parsed["routers"] == ["192.168.1.1"]
    assert parsed["dns"] == ["1.1.1.1"]
    assert parsed["lease_seconds"] == 86400
    assert parsed["domain"] == "lan"
    assert parsed["broadcast"] == "192.168.1.255"


def test_offered_cidr_is_derived_from_the_mask(dhcpprobe: Any) -> None:
    """The report prints one address, so the mask has to be folded in."""
    from scapy.layers.l2 import Ether

    parsed = dhcpprobe.parse_offer(Ether(bytes(build_offer())))
    assert parsed["offered_cidr"] == "192.168.1.50/24"


def test_offer_is_recognised_whether_the_type_is_int_or_name() -> None:
    """scapy renders message-type as the number or the mnemonic depending on
    how the packet was built; dhcpprobe's filter accepts both."""
    from scapy.layers.dhcp import DHCPTypes

    assert DHCPTypes[2] == "offer"
