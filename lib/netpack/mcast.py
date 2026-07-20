"""Multicast probe-packet format and receiver statistics (no sockets; unit-testable).

Probe datagrams carry MAGIC, a version byte, a 32-bit sequence number, and the
sender's wall-clock send time. Jitter is RFC 3550 interarrival jitter, which
uses only clock *differences* on each side, so sender and receiver clocks do
not need to be synchronized.
"""

from __future__ import annotations

import struct

MAGIC = b"NPKM"
VERSION = 1
_HEADER = struct.Struct(">4sBId")
HEADER_LEN = _HEADER.size


def encode_probe(seq: int, send_time: float, size: int) -> bytes:
    """Build a probe datagram of `size` bytes (zero-padded past the header)."""
    hdr = _HEADER.pack(MAGIC, VERSION, seq & 0xFFFFFFFF, send_time)
    if size <= len(hdr):
        return hdr
    return hdr + b"\x00" * (size - len(hdr))


def decode_probe(data: bytes) -> tuple[int, float] | None:
    """Return (seq, send_time) for a netpack probe datagram, else None."""
    if len(data) < HEADER_LEN:
        return None
    magic, version, seq, send_time = _HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        return None
    return seq, send_time


class ProbeStats:
    """Loss, duplicate, and jitter accounting for received probe datagrams."""

    def __init__(self) -> None:
        self.seqs: set[int] = set()
        self.duplicates = 0
        self.jitter = 0.0  # RFC 3550 interarrival jitter, seconds
        self._prev_transit: float | None = None

    def add(self, seq: int, send_time: float, recv_time: float) -> None:
        if seq in self.seqs:
            self.duplicates += 1
            return
        self.seqs.add(seq)
        transit = recv_time - send_time
        if self._prev_transit is not None:
            d = abs(transit - self._prev_transit)
            self.jitter += (d - self.jitter) / 16.0
        self._prev_transit = transit

    def summary(self) -> dict[str, float | int]:
        """Loss is judged against the observed seq span, so a receiver started
        mid-stream is not charged for probes sent before it joined."""
        if not self.seqs:
            return {
                "expected": 0,
                "received": 0,
                "lost": 0,
                "loss_pct": 0.0,
                "duplicates": self.duplicates,
                "jitter_ms": 0.0,
            }
        expected = max(self.seqs) - min(self.seqs) + 1
        received = len(self.seqs)
        lost = expected - received
        return {
            "expected": expected,
            "received": received,
            "lost": lost,
            "loss_pct": round(lost * 100 / expected, 1),
            "duplicates": self.duplicates,
            "jitter_ms": round(self.jitter * 1000, 2),
        }
