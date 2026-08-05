"""Build JSON evidence for the bash tools.

The bash tools accumulate NUL-separated (kind, array, key, value) records and
pipe them here, which assembles the payload and hands it to report.write_dump.
Serialization stays in one place, so a bash dump and a Python dump are
byte-identical and escaping is never hand-rolled in shell.

Record kinds:
    s  string
    S  string, or null when empty (not determined, as distinct from "")
    n  number, or null when the value is empty (unmeasured, not zero)
    b  boolean
    r  start a new object in the named array
"""

from __future__ import annotations

import sys
from typing import Any

from netpack import report

FIELDS_PER_RECORD = 4


class DumpError(Exception):
    """Raised for a malformed record stream."""


def _number(value: str) -> float | int | None:
    # Empty means the tool could not measure this, which is not the same as
    # zero: a dump that records an unmeasured target as 0 reads as clean.
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        raise DumpError(f"not a number: {value!r}") from None


def _boolean(value: str) -> bool:
    low = value.strip().lower()
    if low in {"1", "true", "yes"}:
        return True
    if low in {"0", "false", "no", ""}:
        return False
    raise DumpError(f"not a boolean: {value!r}")


def _coerce(kind: str, value: str) -> Any:
    if kind == "s":
        return value
    if kind == "S":
        # Distinguishes "not determined" from an empty measurement, the same
        # way an empty number is null rather than zero.
        return value or None
    if kind == "n":
        return _number(value)
    if kind == "b":
        return _boolean(value)
    raise DumpError(f"unknown record kind: {kind!r}")


def build(fields: list[str]) -> dict[str, Any]:
    """Assemble a payload from a flat record stream."""
    if len(fields) % FIELDS_PER_RECORD:
        raise DumpError(
            f"record stream is not a multiple of {FIELDS_PER_RECORD} fields "
            f"({len(fields)} given)"
        )
    payload: dict[str, Any] = {}
    arrays: dict[str, list[dict[str, Any]]] = {}
    for i in range(0, len(fields), FIELDS_PER_RECORD):
        kind, array, key, value = fields[i : i + FIELDS_PER_RECORD]
        if kind == "r":
            if not array:
                raise DumpError("row record without an array name")
            arrays.setdefault(array, [])
            arrays[array].append({})
            payload[array] = arrays[array]
            continue
        if array:
            if not arrays.get(array):
                raise DumpError(f"field {key!r} for array {array!r} before its first row")
            arrays[array][-1][key] = _coerce(kind, value)
        else:
            if not key:
                raise DumpError("top-level record without a key")
            payload[key] = _coerce(kind, value)
    return payload


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 3:
        print("usage: dump.py PATH TOOL ASSESSMENT_CODE", file=sys.stderr)
        return 1
    path, tool, code = args
    raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    # printf '%s\0' leaves a trailing separator; an empty stream has no fields.
    fields = raw.split("\0")[:-1] if raw else []
    try:
        payload = build(fields)
        payload["tool"] = tool
        payload["assessment_code"] = _number(code)
        out = report.write_dump(path, payload)
    except DumpError as exc:
        print(f"error: dump: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"error: cannot write dump: {exc}", file=sys.stderr)
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
