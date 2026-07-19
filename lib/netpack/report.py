"""Terminal report and JSON dump helpers."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
_C_VERDICT = "\033[34m" if _USE_COLOR else ""
_C_OFF = "\033[0m" if _USE_COLOR else ""


def timestamp_local() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def timestamp_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def section(title: str) -> None:
    print()
    print(title)


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
