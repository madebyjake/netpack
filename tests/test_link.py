"""Tests for the ethtool / iw parsers behind the linkstat link section."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.link import (
    eee_is_enabled,
    format_pause,
    parse_eee,
    parse_ethtool,
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
