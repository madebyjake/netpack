"""Tests for the bash-tool JSON evidence builder."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.dump import DumpError, build, main


def rec(*records: tuple[str, str, str, str]) -> list[str]:
    """Flatten (kind, array, key, value) tuples into a record stream."""
    return [field for record in records for field in record]


def test_top_level_scalars_keep_their_declared_types() -> None:
    payload = build(
        rec(
            ("s", "", "gateway", "192.168.1.1"),
            ("n", "", "duration_s", "60"),
            ("n", "", "loss_pct", "0.4"),
            ("b", "", "interrupted", "false"),
        )
    )
    assert payload == {
        "gateway": "192.168.1.1",
        "duration_s": 60,
        "loss_pct": 0.4,
        "interrupted": False,
    }


def test_a_numeric_looking_string_stays_a_string() -> None:
    # Types are declared, not inferred: a DNS answer of "10" is not a number.
    assert build(rec(("s", "", "answer", "10"))) == {"answer": "10"}


def test_an_empty_number_is_null_not_zero() -> None:
    # An unmeasured target recorded as 0 would read as clean.
    assert build(rec(("n", "", "wan_loss_pct", ""))) == {"wan_loss_pct": None}


def test_a_non_numeric_number_is_rejected() -> None:
    with pytest.raises(DumpError):
        build(rec(("n", "", "loss_pct", "n/a")))


@pytest.mark.parametrize(
    ("value", "expected"),
    [("true", True), ("1", True), ("yes", True), ("false", False), ("0", False), ("", False)],
)
def test_boolean_spellings(value, expected) -> None:
    assert build(rec(("b", "", "flag", value))) == {"flag": expected}


def test_a_non_boolean_is_rejected() -> None:
    with pytest.raises(DumpError):
        build(rec(("b", "", "flag", "maybe")))


def test_rows_accumulate_into_an_array_in_order() -> None:
    payload = build(
        rec(
            ("r", "targets", "", ""),
            ("s", "targets", "name", "gateway"),
            ("n", "targets", "loss_pct", "0"),
            ("r", "targets", "", ""),
            ("s", "targets", "name", "wan"),
            ("n", "targets", "loss_pct", "4.2"),
        )
    )
    assert payload == {
        "targets": [
            {"name": "gateway", "loss_pct": 0},
            {"name": "wan", "loss_pct": 4.2},
        ]
    }


def test_two_arrays_stay_separate() -> None:
    payload = build(
        rec(
            ("r", "aps", "", ""),
            ("s", "aps", "bssid", "aa:bb"),
            ("r", "channels", "", ""),
            ("n", "channels", "ch", "6"),
            ("r", "aps", "", ""),
            ("s", "aps", "bssid", "cc:dd"),
        )
    )
    assert payload == {
        "aps": [{"bssid": "aa:bb"}, {"bssid": "cc:dd"}],
        "channels": [{"ch": 6}],
    }


def test_a_field_before_its_first_row_is_rejected() -> None:
    with pytest.raises(DumpError):
        build(rec(("s", "targets", "name", "gateway")))


def test_an_unknown_kind_is_rejected() -> None:
    with pytest.raises(DumpError):
        build(rec(("x", "", "key", "value")))


def test_a_truncated_record_stream_is_rejected() -> None:
    with pytest.raises(DumpError):
        build(["s", "", "key"])


def test_an_empty_stream_builds_an_empty_payload() -> None:
    assert build([]) == {}


def run_dump(tmp_path: Path, fields: list[str], code: str = "0") -> tuple[int, dict]:
    """Drive the module the way the bash helper does."""
    target = tmp_path / "out.json"
    payload = b"".join(f.encode() + b"\0" for f in fields)
    proc = subprocess.run(
        [sys.executable, "-m", "netpack.dump", str(target), "splitloss", code],
        input=payload,
        capture_output=True,
        env={"PYTHONPATH": str(ROOT / "lib"), "PATH": "/usr/bin:/bin"},
    )
    if proc.returncode != 0:
        return proc.returncode, {}
    return 0, json.loads(target.read_text(encoding="utf-8"))


def test_cli_writes_the_required_keys(tmp_path) -> None:
    rc, data = run_dump(tmp_path, rec(("s", "", "gateway", "192.168.1.1")), code="2")
    assert rc == 0
    assert data["tool"] == "splitloss"
    assert data["assessment_code"] == 2
    assert "timestamp" in data


def test_cli_escapes_values_that_would_break_hand_rolled_json(tmp_path) -> None:
    nasty = 'a "quote", a \\backslash, a \ttab, and a \nnewline'
    rc, data = run_dump(tmp_path, rec(("s", "", "filter", nasty)))
    assert rc == 0
    assert data["filter"] == nasty


def test_cli_rejects_a_malformed_stream(tmp_path) -> None:
    rc, _ = run_dump(tmp_path, ["s", "", "key"])
    assert rc == 1


def test_cli_requires_three_arguments() -> None:
    assert main([]) == 1
    assert main(["only-a-path"]) == 1
