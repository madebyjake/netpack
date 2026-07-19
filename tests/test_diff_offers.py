"""Tests for DHCP offer diff helper."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.dhcp import diff_offers  # noqa: E402


def test_diff_offers_empty_or_single() -> None:
    assert diff_offers([]) == []
    assert diff_offers([{"dns": ["1.1.1.1"]}]) == []


def test_diff_offers_same_values() -> None:
    a = {"dns": ["1.1.1.1"], "routers": ["10.0.0.1"], "subnet_mask": "255.255.255.0"}
    b = {"dns": ["1.1.1.1"], "routers": ["10.0.0.1"], "subnet_mask": "255.255.255.0"}
    assert diff_offers([a, b]) == []


def test_diff_offers_detects_conflicts() -> None:
    a = {
        "dns": ["1.1.1.1"],
        "routers": ["10.0.0.1"],
        "subnet_mask": "255.255.255.0",
        "domain": "a.example",
        "lease_seconds": 3600,
    }
    b = {
        "dns": ["8.8.8.8"],
        "routers": ["10.0.0.1"],
        "subnet_mask": "255.255.255.0",
        "domain": "b.example",
        "lease_seconds": 7200,
    }
    lines = diff_offers([a, b])
    assert any("dns:" in line for line in lines)
    assert any("domain:" in line for line in lines)
    assert any("lease:" in line for line in lines)
    assert not any("gateway:" in line for line in lines)
