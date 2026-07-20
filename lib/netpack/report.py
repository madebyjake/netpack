"""Terminal report and JSON dump helpers."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal, TextIO

_USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
_C_OK = "\033[32m" if _USE_COLOR else ""
_C_BAD = "\033[31m" if _USE_COLOR else ""
_C_WARN = "\033[38;5;214m" if _USE_COLOR else ""
_C_VERDICT = "\033[34m" if _USE_COLOR else ""
_C_OFF = "\033[0m" if _USE_COLOR else ""

StatusKind = Literal["ok", "bad", "warn"]


def timestamp_local() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def timestamp_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def color_status(kind: StatusKind, text: str | None = None) -> str:
    """Colored status token. Defaults: OK / MISSING / (text required for warn)."""
    if kind == "ok":
        body = "OK" if text is None else text
        return f"{_C_OK}{body}{_C_OFF}"
    if kind == "bad":
        body = "MISSING" if text is None else text
        return f"{_C_BAD}{body}{_C_OFF}"
    if text is None:
        raise ValueError("warn status requires text")
    return f"{_C_WARN}{text}{_C_OFF}"


def section(title: str) -> None:
    # Title is printed as given (matches the bash section() helper); callers
    # pass the desired case — lowercase words, acronyms preserved.
    print()
    print(f"=== {title} ===")


def note(message: str) -> None:
    print(f"{_C_WARN}note: {message}{_C_OFF}")


def warning(message: str, file: TextIO | None = None) -> None:
    dest = file if file is not None else sys.stdout
    # Amber when the destination is a TTY (stderr progress/warnings included).
    use = dest.isatty() and not os.environ.get("NO_COLOR")
    c_warn = "\033[38;5;214m" if use else ""
    c_off = "\033[0m" if use else ""
    print(f"{c_warn}warning: {message}{c_off}", file=dest)


def progress(message: str, file: TextIO | None = None) -> None:
    """Amber progress / sampling line (stdout by default)."""
    dest = file if file is not None else sys.stdout
    use = dest.isatty() and not os.environ.get("NO_COLOR")
    c_warn = "\033[38;5;214m" if use else ""
    c_off = "\033[0m" if use else ""
    print(f"{c_warn}{message}{c_off}", file=dest)


def verdict(message: str, next_check: str | None = None) -> None:
    print("--")
    print(f"{_C_VERDICT}VERDICT:{_C_OFF} {message}")
    if next_check:
        print(f"Next: {next_check}")


def finished() -> None:
    print(f"finished: {timestamp_local()}")


def write_dump(path: str | Path, payload: dict[str, Any]) -> Path:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    data = dict(payload)
    data.setdefault("timestamp", timestamp_local())
    with out.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return out
