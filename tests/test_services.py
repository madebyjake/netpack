"""Tests for mDNS service-type labeling."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack.services import (
    describe_service,
    label_service,
    media_services,
    normalize_service,
)


def test_normalize_strips_local_suffix_and_case() -> None:
    assert normalize_service("_NDI._TCP.local") == "_ndi._tcp"
    assert normalize_service("_ndi._tcp.local.") == "_ndi._tcp"
    assert normalize_service("_ndi._tcp") == "_ndi._tcp"
    assert normalize_service("  _ndi._tcp  ") == "_ndi._tcp"


def test_labels_av_transports() -> None:
    assert label_service("_ndi._tcp") == "NDI video"
    assert label_service("_netaudio-arc._udp") == "Dante (routing control)"
    assert label_service("_netaudio-cmc._udp") == "Dante (device control)"


def test_labels_survive_the_form_discover_produces() -> None:
    # bin/discover strips '.local' from PTR targets before we ever see them,
    # but the lookup must not depend on that having happened.
    assert label_service("_ndi._tcp.local") == "NDI video"


def test_unknown_services_are_not_labelled_or_hidden() -> None:
    assert label_service("_totally-made-up._tcp") is None
    assert describe_service("_totally-made-up._tcp") == "_totally-made-up._tcp"


def test_describe_annotates_without_losing_the_raw_type() -> None:
    described = describe_service("_ndi._tcp")
    assert described == "_ndi._tcp (NDI video)"
    assert "_ndi._tcp" in described


def test_media_services_selects_only_real_time_av() -> None:
    found = media_services(
        [
            "_ndi._tcp",
            "_netaudio-arc._udp",
            "_printer._tcp",
            "_googlecast._tcp",
            "_unknown._tcp",
        ]
    )
    assert found == ["_ndi._tcp", "_netaudio-arc._udp"]


def test_media_services_empty_when_no_av_present() -> None:
    assert media_services(["_printer._tcp", "_ssh._tcp"]) == []
    assert media_services([]) == []
