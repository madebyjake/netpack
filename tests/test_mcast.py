"""Tests for the multicast probe format and receiver statistics."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.mcast import (  # noqa: E402
    HEADER_LEN,
    ProbeStats,
    decode_probe,
    encode_probe,
)


def test_encode_decode_roundtrip() -> None:
    data = encode_probe(42, 1750000000.5, 200)
    assert len(data) == 200
    assert decode_probe(data) == (42, 1750000000.5)


def test_encode_never_truncates_header() -> None:
    data = encode_probe(1, 0.0, 1)
    assert len(data) == HEADER_LEN
    assert decode_probe(data) == (1, 0.0)


def test_decode_rejects_short_and_foreign_payloads() -> None:
    assert decode_probe(b"") is None
    assert decode_probe(b"NPKM") is None
    assert decode_probe(b"X" * 64) is None  # wrong magic (e.g., a Dante flow)


def test_decode_rejects_wrong_version() -> None:
    data = bytearray(encode_probe(1, 0.0, 32))
    data[4] = 99
    assert decode_probe(bytes(data)) is None


def test_stats_loss_and_duplicates() -> None:
    stats = ProbeStats()
    # seqs 1..10 with 4 and 7 missing; 2 arrives twice.
    for i, seq in enumerate([1, 2, 2, 3, 5, 6, 8, 9, 10]):
        stats.add(seq, send_time=i * 0.02, recv_time=i * 0.02 + 0.001)
    s = stats.summary()
    assert s["expected"] == 10
    assert s["received"] == 8
    assert s["lost"] == 2
    assert s["loss_pct"] == 20.0
    assert s["duplicates"] == 1


def test_stats_mid_stream_join_not_charged() -> None:
    stats = ProbeStats()
    for seq in range(50, 60):
        stats.add(seq, send_time=seq * 0.02, recv_time=seq * 0.02 + 0.001)
    s = stats.summary()
    assert s["expected"] == 10
    assert s["lost"] == 0


def test_stats_jitter_constant_transit_is_zero() -> None:
    stats = ProbeStats()
    for seq in range(1, 20):
        stats.add(seq, send_time=seq * 0.02, recv_time=seq * 0.02 + 0.005)
    assert stats.summary()["jitter_ms"] == 0.0


def test_stats_jitter_varying_transit_is_positive() -> None:
    stats = ProbeStats()
    for seq in range(1, 20):
        wobble = 0.010 if seq % 2 else 0.0
        stats.add(seq, send_time=seq * 0.02, recv_time=seq * 0.02 + 0.005 + wobble)
    assert stats.summary()["jitter_ms"] > 0.0


def test_stats_empty() -> None:
    s = ProbeStats().summary()
    assert s["received"] == 0
    assert s["loss_pct"] == 0.0
