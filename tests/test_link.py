"""Tests for the ethtool / iw parsers behind the linkstat link section."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.link import (
    cable_faults,
    cable_is_ok,
    cable_test_error,
    eee_is_enabled,
    format_pause,
    parse_cable_test,
    parse_eee,
    parse_ethtool,
    parse_ethtool_driver,
    parse_iw_link,
    parse_pause,
)

ETHTOOL = """\
Settings for enp3s0:
\tSupported ports: [ TP ]
\tSupported link modes:   10baseT/Half 10baseT/Full
\t                        1000baseT/Full
\tSpeed: 1000Mb/s
\tDuplex: Full
\tPort: Twisted Pair
\tLink detected: yes
"""

EEE_ACTIVE = """\
EEE settings for enp3s0:
\tEEE status: enabled - active
\tTx LPI: 250 (us)
\tSupported EEE link modes:  100baseT/Full
\t                           1000baseT/Full
"""

EEE_INACTIVE = """\
EEE settings for enp3s0:
\tEEE status: enabled - inactive
\tTx LPI: disabled
"""

EEE_DISABLED = """\
EEE settings for enp3s0:
\tEEE status: disabled
\tTx LPI: disabled
"""

EEE_UNSUPPORTED = """\
EEE settings for enp3s0:
\tEEE status: not supported
"""

PAUSE = """\
Pause parameters for enp3s0:
Autonegotiate:\ton
RX:\t\ton
TX:\t\toff
"""

IW_LINK = """\
Connected to 02:00:00:aa:bb:cc (on wlp2s0)
\tSSID: venue-wifi
\tfreq: 5180
\tsignal: -47 dBm
\ttx bitrate: 433.3 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 1
"""


def test_parse_ethtool_extracts_link_facts() -> None:
    info = parse_ethtool(ETHTOOL)
    assert info == {"speed": "1000Mb/s", "duplex": "Full", "link_detected": "yes"}


def test_parse_ethtool_tolerates_unrelated_output() -> None:
    assert parse_ethtool("Settings for eth0:\n\tPort: Twisted Pair\n") == {}


def test_parse_eee_reads_each_status() -> None:
    assert parse_eee(EEE_ACTIVE) == "enabled - active"
    assert parse_eee(EEE_INACTIVE) == "enabled - inactive"
    assert parse_eee(EEE_DISABLED) == "disabled"
    assert parse_eee(EEE_UNSUPPORTED) == "not supported"


def test_parse_eee_returns_none_without_a_status_line() -> None:
    # ethtool too old for --show-eee, or a driver that does not report it.
    assert parse_eee("") is None
    assert parse_eee("EEE settings for eth0:\n") is None


def test_eee_is_enabled_flags_inactive_too() -> None:
    # 'inactive' only means not in low-power idle right now; the link can still
    # enter LPI mid-stream, so it must still be flagged.
    assert eee_is_enabled("enabled - active")
    assert eee_is_enabled("enabled - inactive")
    assert not eee_is_enabled("disabled")
    assert not eee_is_enabled("not supported")
    assert not eee_is_enabled(None)
    assert not eee_is_enabled("")


def test_parse_and_format_pause() -> None:
    pause = parse_pause(PAUSE)
    assert pause == {"autoneg": "on", "rx": "on", "tx": "off"}
    assert format_pause(pause) == "rx on / tx off (autoneg on)"


def test_format_pause_handles_missing_pieces() -> None:
    assert format_pause({}) is None
    assert format_pause({"autoneg": "on"}) is None
    assert format_pause({"rx": "on"}) == "rx on / tx ?"


def test_parse_iw_link_extracts_association() -> None:
    info = parse_iw_link(IW_LINK)
    assert info["ssid"] == "venue-wifi"
    assert info["freq"] == "freq: 5180"
    assert info["signal"] == "signal: -47 dBm"
    assert info["bitrate"].startswith("tx bitrate: 433.3 MBit/s")


def test_parse_iw_link_when_not_associated() -> None:
    assert parse_iw_link("Not connected.\n") == {}


CABLE_FAULT = """\
Cable test started for device enp3s0.
Cable test completed for device enp3s0.
Pair A code OK
Pair B code OK
Pair C code Open Circuit
Pair C, fault length: 25.40m
Pair D code Short within Pair
Pair D, fault length: 1.20m
"""

CABLE_CLEAN = """\
Cable test started for device enp3s0.
Cable test completed for device enp3s0.
Pair A code OK
Pair B code OK
Pair C code OK
Pair D code OK
"""


def test_parse_cable_test_merges_code_and_fault_length() -> None:
    rows = parse_cable_test(CABLE_FAULT)
    assert [r["pair"] for r in rows] == ["A", "B", "C", "D"]
    assert rows[2] == {"pair": "C", "code": "Open Circuit", "fault_length_m": 25.4}
    assert rows[3]["code"] == "Short within Pair"
    assert rows[3]["fault_length_m"] == 1.2
    # Passing pairs carry no distance.
    assert "fault_length_m" not in rows[0]


def test_parse_cable_test_ignores_the_progress_lines() -> None:
    assert len(parse_cable_test(CABLE_CLEAN)) == 4
    assert parse_cable_test("Cable test started for device enp3s0.\n") == []


def test_cable_faults_selects_only_failing_pairs() -> None:
    faults = cable_faults(parse_cable_test(CABLE_FAULT))
    assert [f["pair"] for f in faults] == ["C", "D"]
    assert cable_faults(parse_cable_test(CABLE_CLEAN)) == []


def test_cable_is_ok_does_not_treat_silence_as_a_pass() -> None:
    # A pair with no code reported must not count as healthy: an unreported
    # pair is missing evidence, not good evidence.
    assert cable_is_ok("OK")
    assert cable_is_ok("ok")
    assert not cable_is_ok("")
    assert not cable_is_ok(None)
    assert not cable_is_ok("Open Circuit")


ETHTOOL_I = """\
driver: e1000e
version: 7.0.9-205.fc44.x86_64
firmware-version: 0.2-4
bus-info: 0000:00:1f.6
supports-statistics: yes
"""


def test_parse_ethtool_driver_names_the_driver() -> None:
    assert parse_ethtool_driver(ETHTOOL_I) == "e1000e"
    assert parse_ethtool_driver("") is None


def test_cable_test_error_separates_unsupported_from_denied() -> None:
    # These are the two failures an operator actually hits, and the next step
    # differs: one means use another port, the other means fix privileges.
    assert cable_test_error("netlink error: Operation not supported") == "unsupported"
    assert cable_test_error("netlink error: Operation not permitted") == "permission"
    assert cable_test_error("netlink error: No such device") == "unknown"
    assert cable_test_error("") == "unknown"
