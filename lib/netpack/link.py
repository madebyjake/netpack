"""Pure parsers for ethtool and iw output (no subprocess; unit-testable).

bin/linkstat runs the commands and passes their text here, so the parsing that
decides what the link report says can be tested against captured output.
"""

from __future__ import annotations


def _value_after(line: str, label: str) -> str:
    return line.split(label, 1)[1].strip()


def parse_ethtool(text: str) -> dict[str, str]:
    """Speed, duplex and carrier state from `ethtool IFACE`."""
    info: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("Speed:"):
            info["speed"] = _value_after(s, "Speed:")
        elif s.startswith("Duplex:"):
            info["duplex"] = _value_after(s, "Duplex:")
        elif s.startswith("Link detected:"):
            info["link_detected"] = _value_after(s, "Link detected:")
    return info


def parse_eee(text: str) -> str | None:
    """EEE status from `ethtool --show-eee IFACE`, e.g. 'enabled - active'.

    Returns None when the output carries no status line at all (an ethtool too
    old for --show-eee, or a driver that does not report it).
    """
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("EEE status:"):
            return _value_after(s, "EEE status:")
    return None


def eee_is_enabled(status: str | None) -> bool:
    """True when EEE is negotiated on the link.

    Both 'enabled - active' and 'enabled - inactive' count: inactive only means
    the link is not in low-power idle *right now*, so it can still enter LPI and
    disturb a real-time stream. 'disabled' and 'not supported' are safe.
    """
    return bool(status) and status.strip().lower().startswith("enabled")


def parse_pause(text: str) -> dict[str, str]:
    """Autonegotiate/RX/TX flow control from `ethtool -a IFACE`."""
    out: dict[str, str] = {}
    keys = {"autonegotiate": "autoneg", "rx": "rx", "tx": "tx"}
    for line in text.splitlines():
        s = line.strip()
        if ":" not in s:
            continue
        label, _, value = s.partition(":")
        key = keys.get(label.strip().lower())
        if key and value.strip():
            out[key] = value.strip()
    return out


def format_pause(pause: dict[str, str]) -> str | None:
    """Render the pause dict as 'rx on / tx off (autoneg on)'."""
    if not pause:
        return None
    rx = pause.get("rx")
    tx = pause.get("tx")
    if rx is None and tx is None:
        return None
    text = f"rx {rx or '?'} / tx {tx or '?'}"
    if pause.get("autoneg"):
        text += f" (autoneg {pause['autoneg']})"
    return text


def parse_iw_link(text: str) -> dict[str, str]:
    """Association details from `iw dev IFACE link`."""
    info: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        low = s.lower()
        if low.startswith("ssid:"):
            info["ssid"] = _value_after(s, ":")
        elif "freq:" in low:
            info["freq"] = s
        elif "signal:" in low:
            info["signal"] = s
        elif "tx bitrate:" in low or "bitrate:" in low:
            info["bitrate"] = s
    return info
