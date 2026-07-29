"""Tests for shared CLI helpers."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.cli import ArgumentParser, foreign_options

# Mirrors bin/mcastcheck: dest -> (owning mode, flag text).
OWNERS = {
    "timeout": ("recv", "-t/--timeout"),
    "count": ("send", "-c/--count"),
    "rate": ("send", "-r/--rate"),
    "size": ("send", "-s/--size"),
    "ttl": ("send", "-T/--ttl"),
}


def test_nothing_foreign_when_only_shared_options_given() -> None:
    supplied = {"group": "239.192.77.77", "timeout": None, "count": None}
    assert foreign_options("recv", supplied, OWNERS) == []
    assert foreign_options("send", supplied, OWNERS) == []


def test_send_options_are_foreign_to_recv() -> None:
    supplied = {"timeout": None, "count": 999, "rate": 4000, "size": None, "ttl": 200}
    assert foreign_options("recv", supplied, OWNERS) == [
        "-c/--count",
        "-r/--rate",
        "-T/--ttl",
    ]


def test_recv_options_are_foreign_to_send() -> None:
    supplied = {"timeout": 300.0, "count": None, "rate": None, "size": None, "ttl": None}
    assert foreign_options("send", supplied, OWNERS) == ["-t/--timeout"]


def test_own_mode_options_are_never_foreign() -> None:
    supplied = {"timeout": None, "count": 10, "rate": 5, "size": 200, "ttl": 1}
    assert foreign_options("send", supplied, OWNERS) == []


def test_falsy_but_supplied_values_still_count() -> None:
    # 0 is a supplied value, not an absent one; only None means "not given".
    supplied = {"timeout": 0.0, "count": None}
    assert foreign_options("send", supplied, OWNERS) == ["-t/--timeout"]


def test_usage_errors_exit_1_not_argparse_default_2() -> None:
    # Exit 2 already means "condition found" in the tools, so a typo must not
    # be readable as a diagnostic result.
    parser = ArgumentParser(prog="demo", add_help=False)
    parser.add_argument("-t", "--timeout", type=int)
    with pytest.raises(SystemExit) as excinfo:
        parser.parse_args(["--nope"])
    assert excinfo.value.code == 1
