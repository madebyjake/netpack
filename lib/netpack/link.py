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
    # `is not None` rather than bool(): identical at runtime, but a type checker
    # cannot narrow str | None through a truthiness test in a boolean chain.
    return status is not None and status.strip().lower().startswith("enabled")


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


def parse_cable_test(text: str) -> list[dict[str, object]]:
    """Per-pair results from `ethtool --cable-test IFACE`.

    ethtool reports a code line per pair, and a separate fault-length line only
    for pairs that failed:

        Pair A code OK
        Pair C code Open Circuit
        Pair C, fault length: 25.40m

    Returns one dict per pair in the order first seen, each with 'pair', 'code',
    and 'fault_length_m' when a distance was reported. Pairs are keyed by name
    so the two line shapes merge regardless of the order they arrive in.
    """
    pairs: dict[str, dict[str, object]] = {}
    order: list[str] = []

    def slot(name: str) -> dict[str, object]:
        if name not in pairs:
            pairs[name] = {"pair": name, "code": ""}
            order.append(name)
        return pairs[name]

    for line in text.splitlines():
        s = line.strip()
        if not s.startswith("Pair "):
            continue
        rest = s[len("Pair ") :]
        if ", fault length:" in rest:
            name, _, value = rest.partition(", fault length:")
            value = value.strip().rstrip("m").strip()
            try:
                slot(name.strip())["fault_length_m"] = float(value)
            except ValueError:
                pass
        elif " code " in rest:
            name, _, code = rest.partition(" code ")
            slot(name.strip())["code"] = code.strip()
    return [pairs[name] for name in order]


def parse_ethtool_driver(text: str) -> str | None:
    """Driver name from `ethtool -i IFACE`."""
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("driver:"):
            return _value_after(s, "driver:") or None
    return None


def cable_test_error(stderr: str) -> str:
    """Why `ethtool --cable-test` refused: unsupported | permission | unknown.

    The distinction matters because the operator's next step differs. A driver
    that does not implement cable testing rejects the netlink request outright,
    which also means the link was never disturbed — worth saying, since the run
    announced that it would bounce.
    """
    low = stderr.lower()
    if "not supported" in low or "eopnotsupp" in low:
        return "unsupported"
    if "not permitted" in low or "operation not permitted" in low or "eperm" in low:
        return "permission"
    return "unknown"


def cable_is_ok(code: object) -> bool:
    """True for a pair ethtool reported as good.

    Anything else — Open Circuit, Short within Pair, Short to another pair — is
    a physical fault. An empty or unrecognized code is not treated as passing:
    silence about a pair is not evidence that the pair is fine.
    """
    return isinstance(code, str) and code.strip().lower() == "ok"


def cable_faults(results: list[dict[str, object]]) -> list[dict[str, object]]:
    """The subset of parse_cable_test rows that are not OK."""
    return [r for r in results if not cable_is_ok(r.get("code"))]


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
