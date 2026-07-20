"""Pure parsers for SSDP and mDNS discovery (no sockets; unit-testable).

SSDP responses are HTTPU text; mDNS uses the DNS wire format with name
compression. Keep these functions I/O-free so bin/discover can be tested
against captured bytes.
"""

from __future__ import annotations

import struct


def parse_ssdp(payload: bytes) -> dict[str, str]:
    """Parse an SSDP/HTTPU response into a lowercased-key header dict."""
    text = payload.decode("utf-8", errors="replace")
    headers: dict[str, str] = {}
    for line in text.split("\r\n")[1:]:  # skip the status line
        if ":" in line:
            key, _, val = line.partition(":")
            headers[key.strip().lower()] = val.strip()
    return headers


def encode_name(name: str) -> bytes:
    """Encode a dotted DNS name as length-prefixed labels (no compression)."""
    out = bytearray()
    for label in name.split("."):
        if not label:
            continue
        raw = label.encode("utf-8")
        out.append(len(raw))
        out += raw
    out.append(0)
    return bytes(out)


def decode_name(data: bytes, offset: int) -> tuple[str, int]:
    """Decode a DNS name at offset, following compression pointers.

    Returns (name, next_offset), where next_offset is the position immediately
    after the name in the record stream (past the first pointer, if any).
    """
    labels: list[str] = []
    next_offset = offset
    pos = offset
    jumped = False
    hops = 0
    while 0 <= pos < len(data):
        length = data[pos]
        if length == 0:
            if not jumped:
                next_offset = pos + 1
            break
        if (length & 0xC0) == 0xC0:  # compression pointer
            if pos + 1 >= len(data):
                break
            if not jumped:
                next_offset = pos + 2
            pos = ((length & 0x3F) << 8) | data[pos + 1]
            jumped = True
            hops += 1
            if hops > 128:  # malformed / loop guard
                break
            continue
        pos += 1
        labels.append(data[pos : pos + length].decode("utf-8", errors="replace"))
        pos += length
    return ".".join(labels), next_offset


def parse_mdns(data: bytes) -> list[tuple[int, str, str]]:
    """Parse mDNS/DNS answers into (rtype, owner_name, target) tuples.

    target is the PTR/SRV name, "a.b.c.d" for A, or "host:port" for SRV.
    Malformed records stop parsing and return what was decoded so far.
    """
    if len(data) < 12:
        return []
    qdcount, ancount = struct.unpack(">HH", data[4:8])
    pos = 12
    for _ in range(qdcount):
        _, pos = decode_name(data, pos)
        pos += 4  # qtype + qclass
    answers: list[tuple[int, str, str]] = []
    for _ in range(ancount):
        if pos >= len(data):
            break
        name, pos = decode_name(data, pos)
        if pos + 10 > len(data):
            break
        rtype, _rclass, _ttl, rdlen = struct.unpack(">HHIH", data[pos : pos + 10])
        pos += 10
        rdata_end = pos + rdlen
        if rdata_end > len(data):
            break
        target = ""
        if rtype == 12:  # PTR
            target, _ = decode_name(data, pos)
        elif rtype == 1 and rdlen == 4:  # A
            target = ".".join(str(b) for b in data[pos : pos + 4])
        elif rtype == 33 and rdlen >= 6:  # SRV
            port = struct.unpack(">H", data[pos + 4 : pos + 6])[0]
            host, _ = decode_name(data, pos + 6)
            target = f"{host}:{port}"
        answers.append((rtype, name, target))
        pos = rdata_end
    return answers
