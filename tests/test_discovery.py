"""Tests for SSDP and mDNS discovery parsers."""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.discovery import (  # noqa: E402
    decode_name,
    encode_name,
    parse_mdns,
    parse_ssdp,
)


def test_parse_ssdp_headers() -> None:
    payload = (
        b"HTTP/1.1 200 OK\r\n"
        b"CACHE-CONTROL: max-age=1800\r\n"
        b"LOCATION: http://192.168.1.10:8060/\r\n"
        b"SERVER: Roku UPnP/1.0 MiniUPnPd/1.4\r\n"
        b"ST: roku:ecp\r\n"
        b"USN: uuid:roku:ecp:X001\r\n\r\n"
    )
    headers = parse_ssdp(payload)
    assert headers["location"] == "http://192.168.1.10:8060/"
    assert headers["server"] == "Roku UPnP/1.0 MiniUPnPd/1.4"
    assert headers["st"] == "roku:ecp"


def test_encode_decode_name_roundtrip() -> None:
    raw = encode_name("_http._tcp.local")
    name, offset = decode_name(raw, 0)
    assert name == "_http._tcp.local"
    assert offset == len(raw)


def test_decode_name_compression_pointer() -> None:
    # "local" at offset 0, then "_http._tcp" + pointer back to offset 0.
    base = encode_name("local")  # 6 c o m ... actually: 5 local 0
    suffix = b"\x05_http\x04_tcp\xc0\x00"
    data = base + suffix
    name, offset = decode_name(data, len(base))
    assert name == "_http._tcp.local"
    # next_offset is just past the 2-byte pointer
    assert offset == len(data)


def _mdns_response(owner: str, ptr_target: str) -> bytes:
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0)  # 1 answer
    rdata = encode_name(ptr_target)
    answer = (
        encode_name(owner)
        + struct.pack(">HHIH", 12, 0x8001, 120, len(rdata))  # PTR, cache-flush IN
        + rdata
    )
    return header + answer


def test_parse_mdns_ptr_answer() -> None:
    data = _mdns_response("_services._dns-sd._udp.local", "_airplay._tcp.local")
    answers = parse_mdns(data)
    assert answers == [(12, "_services._dns-sd._udp.local", "_airplay._tcp.local")]


def test_parse_mdns_truncated_is_safe() -> None:
    data = _mdns_response("_services._dns-sd._udp.local", "_ipp._tcp.local")[:20]
    # Should not raise; returns what it could decode (possibly empty).
    assert isinstance(parse_mdns(data), list)


def test_parse_mdns_a_record() -> None:
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0)
    rdata = bytes([192, 168, 1, 55])
    answer = encode_name("box.local") + struct.pack(">HHIH", 1, 0x8001, 120, 4) + rdata
    answers = parse_mdns(header + answer)
    assert answers == [(1, "box.local", "192.168.1.55")]
