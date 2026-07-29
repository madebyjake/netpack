"""Documentation must agree with the shared tool metadata.

Tool facts live in lib/netpack/tools.sh. The README table and doctor's per-tool
sections restate them for human readers, so these tests keep the restatements
honest — that duplication is exactly how the sudo/probe tags drifted before.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# "name | root | traffic | description | impact" inside TOOL_ROWS.
_ROW = re.compile(r'^\s*"([a-z0-9-]+)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)"\s*$')
# "| `tool` | purpose | root | traffic |" in the README tools table.
_MD_ROW = re.compile(r"^\|\s*`([a-z0-9-]+)`\s*\|([^|]*)\|([^|]*)\|([^|]*)\|")


def tool_metadata() -> dict[str, tuple[str, str]]:
    """tool -> (root tag, traffic tag) from lib/netpack/tools.sh."""
    out: dict[str, tuple[str, str]] = {}
    for line in (ROOT / "lib" / "netpack" / "tools.sh").read_text().splitlines():
        m = _ROW.match(line)
        if m:
            name, root, traffic = (m.group(i).strip() for i in (1, 2, 3))
            out[name] = (root, traffic)
    return out


def readme_table() -> dict[str, tuple[str, str]]:
    """tool -> (root tag, traffic tag) from the README tools table."""
    out: dict[str, tuple[str, str]] = {}
    for line in (ROOT / "README.md").read_text().splitlines():
        m = _MD_ROW.match(line)
        if m:
            name = m.group(1)
            root = m.group(3).strip().strip("`").strip()
            traffic = m.group(4).strip().strip("`").strip()
            out[name] = (root, traffic)
    return out


def test_metadata_table_is_parseable_and_populated() -> None:
    meta = tool_metadata()
    assert len(meta) >= 12
    assert "mcastcheck" in meta
    assert meta["dhcpprobe"] == ("sudo", "probe")


def test_readme_lists_exactly_the_tools_that_exist() -> None:
    assert set(readme_table()) == set(tool_metadata())


def test_readme_root_and_traffic_tags_match_the_menu() -> None:
    meta = tool_metadata()
    for name, (root, traffic) in sorted(readme_table().items()):
        assert (root, traffic) == meta[name], (
            f"README says {name} is root={root!r} traffic={traffic!r}, "
            f"metadata says {meta[name]}"
        )


def test_doctor_covers_every_tool() -> None:
    doctor = (ROOT / "bin" / "doctor").read_text()
    covered = set(re.findall(r"^tool_header ([a-z0-9-]+)", doctor, re.MULTILINE))
    # doctor reports on the other tools, not on itself.
    expected = set(tool_metadata()) - {"doctor"}
    assert covered == expected, f"missing from doctor: {sorted(expected - covered)}"


def test_readme_documents_every_tool_in_an_example_or_playbook() -> None:
    readme = (ROOT / "README.md").read_text()
    for name in tool_metadata():
        assert re.search(rf"\b{re.escape(name)}\b", readme), f"{name} unmentioned"
