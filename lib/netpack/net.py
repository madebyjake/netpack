"""Network helpers: interface resolution, gateway lookup, privilege checks.

Keep iface/gateway/validation in sync with lib/netpack.sh.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

_IFACE_RE = re.compile(r"^[A-Za-z0-9._@:+=-]+$")


class NetError(Exception):
    """Raised for interface or privilege problems."""


def require_root() -> None:
    if os.geteuid() != 0:
        raise NetError("root privileges required; re-run with sudo")


def list_ifaces() -> list[str]:
    base = Path("/sys/class/net")
    if not base.is_dir():
        return []
    return sorted(p.name for p in base.iterdir() if p.is_dir())


def validate_iface(iface: str) -> str:
    if not iface or not _IFACE_RE.match(iface):
        raise NetError(f"invalid interface name: {iface!r}")
    if iface not in list_ifaces():
        raise NetError(f"interface not found: {iface}")
    return iface


def iface_is_up(iface: str) -> bool:
    """Return True if the interface is usable (operstate up, or unknown with IFF_UP)."""
    flags_path = Path(f"/sys/class/net/{iface}/flags")
    flags_up = False
    if flags_path.is_file():
        try:
            flags_up = bool(int(flags_path.read_text(encoding="utf-8").strip(), 0) & 0x1)
        except ValueError:
            flags_up = False

    oper = Path(f"/sys/class/net/{iface}/operstate")
    if oper.is_file():
        state = oper.read_text(encoding="utf-8").strip()
        if state == "up":
            return True
        if state == "unknown":
            return flags_up
        return False

    return flags_up


def default_iface() -> str:
    """Return the default-route interface, or the first non-loopback iface."""
    try:
        out = subprocess.check_output(
            ["ip", "-o", "route", "get", "1.1.1.1"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        parts = out.split()
        if "dev" in parts:
            iface = parts[parts.index("dev") + 1]
            return validate_iface(iface)
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        IndexError,
        NetError,
        PermissionError,
        OSError,
    ):
        pass

    for name in list_ifaces():
        if name == "lo":
            continue
        return name
    raise NetError("no usable interface found")


def default_gateway() -> str | None:
    try:
        out = subprocess.check_output(
            ["ip", "-o", "route", "show", "default"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        PermissionError,
        OSError,
    ):
        return None
    for line in out.splitlines():
        parts = line.split()
        if "via" in parts:
            return parts[parts.index("via") + 1]
    return None


def iface_ipv4(iface: str) -> str | None:
    """First IPv4 address on the interface, or None."""
    try:
        out = subprocess.check_output(
            ["ip", "-o", "-4", "addr", "show", "dev", iface],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        PermissionError,
        OSError,
    ):
        return None
    for line in out.splitlines():
        parts = line.split()
        if "inet" in parts:
            try:
                return parts[parts.index("inet") + 1].split("/")[0]
            except IndexError:
                return None
    return None


def resolve_iface(explicit: str | None) -> str:
    if explicit:
        return validate_iface(explicit)
    return default_iface()
