"""DHCP offer comparison helpers."""

from __future__ import annotations

from typing import Any


def diff_offers(offers: list[dict[str, Any]]) -> list[str]:
    """Return labeled lines for fields that differ across offers."""
    if len(offers) < 2:
        return []
    fields = [
        ("subnet_mask", "subnet_mask"),
        ("routers", "gateway"),
        ("dns", "dns"),
        ("domain", "domain"),
        ("lease_seconds", "lease"),
    ]
    lines: list[str] = []
    for key, label in fields:
        values = []
        for o in offers:
            val = o.get(key)
            if isinstance(val, list):
                values.append(", ".join(val) if val else "-")
            elif val is None or val == "":
                values.append("-")
            else:
                values.append(str(val))
        if len(set(values)) > 1:
            lines.append(f"  {label}: " + " | ".join(values))
    return lines
