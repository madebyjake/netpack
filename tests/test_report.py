"""Tests for the terminal report and JSON dump helpers.

pytest captures stdout, so the module-level colour flag is off here — which is
the state that matters for evidence: redirected output must stay plain text.
The bash side is mirrored in lib/netpack.sh; keep the two in step.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack import report


def test_timestamp_local_is_iso_with_seconds_and_offset() -> None:
    stamp = report.timestamp_local()
    parsed = datetime.fromisoformat(stamp)
    assert parsed.utcoffset() is not None
    assert parsed.microsecond == 0


def test_header_names_the_tool_and_its_start(capsys) -> None:
    report.header("linkstat")
    out = capsys.readouterr().out.strip()
    tool, _, stamp = out.partition(" — ")
    assert tool == "linkstat"
    datetime.fromisoformat(stamp)


def test_finished_closes_with_a_timestamp(capsys) -> None:
    report.finished()
    out = capsys.readouterr().out.strip()
    assert out.startswith("finished: ")
    datetime.fromisoformat(out[len("finished: ") :])


def test_section_is_blank_line_then_delimited_title(capsys) -> None:
    report.section("access points")
    assert capsys.readouterr().out == "\n=== access points ===\n"


def test_verdict_renders_as_assessment(capsys) -> None:
    report.verdict("all pairs passed.")
    assert capsys.readouterr().out == "--\nASSESSMENT: all pairs passed.\n"


def test_verdict_appends_the_next_step(capsys) -> None:
    report.verdict("duplicate IPs detected.", "Isolate the unexpected host.")
    out = capsys.readouterr().out
    assert out.endswith("Next: Isolate the unexpected host.\n")


def test_note_and_warning_carry_their_prefixes(capsys) -> None:
    report.note("multi-homed")
    report.warning("clock skew exceeds 120s")
    out = capsys.readouterr().out
    assert "note: multi-homed\n" in out
    assert "warning: clock skew exceeds 120s\n" in out


def test_progress_goes_to_stderr_so_piped_evidence_stays_clean(capsys) -> None:
    report.progress("sampling 30s on eth0 ...")
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "sampling 30s on eth0 ..." in captured.err


def test_color_status_defaults() -> None:
    assert report.color_status("ok") == "OK"
    assert report.color_status("bad") == "MISSING"
    assert report.color_status("ok", "PASS") == "PASS"


def test_color_status_warn_requires_text() -> None:
    with pytest.raises(ValueError):
        report.color_status("warn")


def test_no_escape_codes_when_the_destination_is_not_a_tty(capsys) -> None:
    report.header("linkstat")
    report.section("counters")
    report.note("multi-homed")
    report.warning("skew")
    report.verdict("clean.", "Nothing to do.")
    report.finished()
    captured = capsys.readouterr()
    assert "\033" not in captured.out
    assert "\033" not in captured.err


def test_write_dump_creates_parents_and_returns_the_path(tmp_path) -> None:
    target = tmp_path / "evidence" / "nested" / "linkstat.json"
    out = report.write_dump(target, {"tool": "linkstat"})
    assert out == target
    assert target.is_file()


def test_write_dump_supplies_a_timestamp_when_absent(tmp_path) -> None:
    path = report.write_dump(tmp_path / "d.json", {"tool": "discover"})
    data = json.loads(path.read_text(encoding="utf-8"))
    datetime.fromisoformat(data["timestamp"])


def test_write_dump_keeps_an_explicit_timestamp(tmp_path) -> None:
    stamp = "2026-07-18T18:30:00-07:00"
    path = report.write_dump(tmp_path / "d.json", {"tool": "x", "timestamp": stamp})
    assert json.loads(path.read_text(encoding="utf-8"))["timestamp"] == stamp


def test_write_dump_does_not_mutate_the_caller_payload(tmp_path) -> None:
    payload = {"tool": "linkstat"}
    report.write_dump(tmp_path / "d.json", payload)
    assert payload == {"tool": "linkstat"}


def test_write_dump_sorts_keys_and_ends_with_a_newline(tmp_path) -> None:
    # Stable ordering is what makes two captures diffable.
    path = report.write_dump(
        tmp_path / "d.json", {"zeta": 1, "alpha": 2, "tool": "x", "timestamp": "t"}
    )
    text = path.read_text(encoding="utf-8")
    assert text.endswith("\n")
    assert list(json.loads(text)) == sorted(["zeta", "alpha", "tool", "timestamp"])


def test_write_dump_round_trips_the_payload(tmp_path) -> None:
    payload = {
        "tool": "linkstat",
        "deltas": {"rx_errors": 0, "tx_dropped": 3},
        "assessment_code": 2,
        "wireless": False,
        "rx_mbit_s": 12.5,
    }
    path = report.write_dump(tmp_path / "d.json", payload)
    data = json.loads(path.read_text(encoding="utf-8"))
    for key, value in payload.items():
        assert data[key] == value


def test_write_dump_accepts_a_string_path(tmp_path) -> None:
    path = report.write_dump(str(tmp_path / "d.json"), {"tool": "x"})
    assert path.is_file()
