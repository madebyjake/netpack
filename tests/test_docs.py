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
# "id | title" inside PLAYBOOK_ROWS.
_PB_ROW = re.compile(r'^\s*"([a-z0-9-]+)\s*\|([^|]*)"\s*$')
# TOOL_JSON=(tool tool ...) — the tools that write --dump JSON evidence.
_JSON_TOOLS = re.compile(r"^TOOL_JSON=\(([^)]*)\)", re.MULTILINE)


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


def playbook_ids() -> list[str]:
    """Playbook ids from lib/netpack/playbooks.sh, in declaration order."""
    out: list[str] = []
    text = (ROOT / "lib" / "netpack" / "playbooks.sh").read_text()
    # Stop at the steps table, whose rows have three fields, not two.
    head = text.split("PLAYBOOK_STEPS", 1)[0]
    for line in head.splitlines():
        m = _PB_ROW.match(line)
        if m:
            out.append(m.group(1))
    return out


def test_playbook_table_is_parseable() -> None:
    ids = playbook_ids()
    assert len(ids) >= 4
    assert "wan" in ids


def test_readme_points_at_every_runnable_playbook() -> None:
    # A playbook nobody can find is prose. Each runnable one names its command
    # next to the sequence it walks.
    readme = (ROOT / "README.md").read_text()
    for pid in playbook_ids():
        assert f"npk playbook {pid}" in readme, f"README does not offer: npk playbook {pid}"


# header/verdict/finished, in either the bash or the Python spelling.
# finish_with counts as a closer: it calls finished before exiting, downgrading
# the status to 130 when the run was interrupted.
_REPORT_CALLS = {
    "header": re.compile(r"^\s*header\s+\S|report\.header\(", re.MULTILINE),
    "verdict": re.compile(r"^\s*verdict\s+\S|report\.verdict\(", re.MULTILINE),
    "finished": re.compile(
        r"^\s*finished\s*$|^\s*finish_with\s+\S|report\.finished\(\)", re.MULTILINE
    ),
}


def test_every_tool_opens_and_closes_its_report() -> None:
    """The README states a report always carries its own start and end times.
    ringcap, testsrv and testcli exec'd into their child process and never
    reached a verdict or finished line."""
    for name in tool_metadata():
        src = (ROOT / "bin" / name).read_text()
        for call, pattern in _REPORT_CALLS.items():
            assert pattern.search(src), f"{name} never calls {call}"


# "title | requirement" inside PLAYBOOK_PROSE_ROWS.
_PROSE_ROW = re.compile(r'^\s*"([^|"]+)\|([^|"]*)"\s*$')


def prose_procedures() -> list[str]:
    """Titles of the procedures that need a second machine."""
    text = (ROOT / "lib" / "netpack" / "playbooks.sh").read_text()
    # Closes on a ")" at the start of a line: a title may contain one, as
    # "Prove latency and jitter under load (bufferbloat)" does.
    m = re.search(r"^PLAYBOOK_PROSE_ROWS=\((.*?)^\)", text, re.DOTALL | re.MULTILINE)
    assert m, "PLAYBOOK_PROSE_ROWS not found in playbooks.sh"
    return [
        row.group(1).strip()
        for line in m.group(1).splitlines()
        if (row := _PROSE_ROW.match(line))
    ]


def test_prose_procedures_are_listed_and_documented() -> None:
    """The launcher lists these so an operator sees the whole procedure set,
    but their steps live in the README. A title that drifts leaves the operator
    hunting for a procedure under a name the README does not use."""
    readme = (ROOT / "README.md").read_text()
    titles = prose_procedures()
    assert len(titles) >= 3
    for title in titles:
        assert f"**{title}**" in readme, f"README has no section titled: {title}"


def json_tools() -> list[str]:
    """Tools that write --dump JSON, from TOOL_JSON in lib/netpack/tools.sh."""
    text = (ROOT / "lib" / "netpack" / "tools.sh").read_text()
    m = _JSON_TOOLS.search(text)
    assert m, "TOOL_JSON not found in lib/netpack/tools.sh"
    return m.group(1).split()


def test_json_tools_are_tools_that_exist() -> None:
    assert set(json_tools()) <= set(tool_metadata())


def test_every_dump_payload_carries_the_required_keys() -> None:
    """Python tools name tool and assessment_code in each payload; bash tools
    pass them to dump_write, which supplies them. Python payloads are counted
    per write_dump call so a tool building one per mode (mcastcheck) cannot
    pass on a single occurrence."""
    for name in json_tools():
        src = (ROOT / "bin" / name).read_text()
        py_dumps = src.count("report.write_dump(")
        sh_dumps = len(re.findall(r"^\s*dump_write\s", src, re.MULTILINE))
        assert py_dumps or sh_dumps, f"{name} is in TOOL_JSON but writes no dump"
        for key in ("tool", "assessment_code"):
            found = src.count(f'"{key}":')
            assert found >= py_dumps, (
                f"{name} builds {py_dumps} dump payload(s) but names {key!r} "
                f"{found} time(s); every payload must carry it"
            )


def test_bash_dumping_tools_accept_the_capture_spelling() -> None:
    """capture_run appends "--dump PATH"; getopts cannot parse it, so a bash
    tool that skips take_dump_opt would reject its own capture arguments."""
    for name in json_tools():
        src = (ROOT / "bin" / name).read_text()
        if "report.write_dump(" in src:
            continue
        assert "take_dump_opt" in src, f"{name} does not accept --dump"
