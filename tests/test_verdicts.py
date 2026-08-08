"""Verdict selection, including the branches an interrupted run reaches.

These decisions used to live inline in bin/, where exercising them needed real
hardware — so the interrupted paths, added precisely because they are easy to
get wrong, had no coverage. The assertions below are as much about wording as
about exit codes: a cut-short run that reads like a clean one is the failure
mode these branches exist to prevent.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from netpack import verdicts


# --- linkstat ---------------------------------------------------------------


def test_errors_outrank_drops_and_flaps() -> None:
    v = verdicts.link_counters(errors=5, drops=3, flaps=2, wireless=False, window_s=30)
    assert v.code == verdicts.EXIT_PHYSICAL
    # The lower-priority findings still appear rather than being dropped.
    assert "drop/fifo counters also increased" in v.message
    assert "carrier also flapped 2 time(s)" in v.message


def test_flaps_outrank_drops_on_wired_links() -> None:
    v = verdicts.link_counters(errors=0, drops=4, flaps=3, wireless=False, window_s=30)
    assert v.code == verdicts.EXIT_FLAP
    assert "carrier also flapped 3 time(s)" in v.message


def test_wireless_flaps_are_not_a_flap_fault() -> None:
    """Wi-Fi carrier changes move on roam and reassoc, so they must not raise
    the flap verdict the way a wired link's do."""
    v = verdicts.link_counters(errors=0, drops=0, flaps=6, wireless=True, window_s=30)
    assert v.code == verdicts.EXIT_OK
    v_wired = verdicts.link_counters(
        errors=0, drops=0, flaps=6, wireless=False, window_s=30
    )
    assert v_wired.code == verdicts.EXIT_FLAP


def test_drops_alone_are_congestion() -> None:
    v = verdicts.link_counters(errors=0, drops=7, flaps=0, wireless=False, window_s=30)
    assert v.code == verdicts.EXIT_CONGESTION
    assert "congestion or policy" in v.message


def test_clean_window_reads_clean() -> None:
    v = verdicts.link_counters(errors=0, drops=0, flaps=0, wireless=False, window_s=30)
    assert v.code == verdicts.EXIT_OK
    assert "no error or drop growth during the sample window." == v.message


def test_interrupted_clean_window_does_not_claim_the_link_is_healthy() -> None:
    """The branch that matters: a 2s sample that saw nothing must not read the
    same as a completed one, or an operator banks a clean result they did not
    get."""
    v = verdicts.link_counters(
        errors=0, drops=0, flaps=0, wireless=False, window_s=2.0, interrupted=True
    )
    assert v.code == verdicts.EXIT_OK
    assert "2.0s" in v.message
    assert "interrupted" in v.message
    assert v.next_step is not None
    assert "re-run to completion" in v.next_step.lower()


def test_interrupted_run_still_reports_a_fault_it_saw() -> None:
    """Counters that grew are evidence regardless of when the window ended, so
    interruption must not soften a real finding."""
    v = verdicts.link_counters(
        errors=9, drops=0, flaps=0, wireless=False, window_s=3.0, interrupted=True
    )
    assert v.code == verdicts.EXIT_PHYSICAL
    assert "physical layer" in v.message


# --- dhcpprobe ---------------------------------------------------------------


def test_single_offer_is_clean() -> None:
    v = verdicts.dhcp_offers(1)
    assert v.code == verdicts.EXIT_OK
    assert v.message == "single DHCP server responded."
    assert v.next_step is None


def test_multiple_offers_are_the_finding() -> None:
    v = verdicts.dhcp_offers(3)
    assert v.code == verdicts.EXIT_MULTI
    assert "3 DHCP servers" in v.message


def test_interrupted_single_offer_does_not_rule_out_a_second_server() -> None:
    """A truncated window is the one way to reach the clean result wrongly."""
    v = verdicts.dhcp_offers(1, interrupted=True)
    assert v.code == verdicts.EXIT_OK
    assert v.next_step is not None
    assert "does not rule out a second server" in v.next_step


def test_interrupted_silence_concludes_nothing() -> None:
    v = verdicts.dhcp_offers(0, interrupted=True)
    assert v.code == verdicts.EXIT_NONE
    assert "Too short to conclude anything" in (v.next_step or "")
    # The completed-run wording names causes; the interrupted one must not.
    assert "wrong VLAN" not in v.message


def test_offer_without_ack_outranks_interruption() -> None:
    """The server answered and then refused: that was observed, not merely
    not-yet-contradicted, so it stands over the cut-short wording."""
    v = verdicts.dhcp_offers(1, dora_state="timeout", interrupted=True)
    assert v.code == verdicts.EXIT_NOACK
    assert "did not ACK" in v.message


def test_dora_ack_is_still_clean() -> None:
    v = verdicts.dhcp_offers(1, dora_state="ack")
    assert v.code == verdicts.EXIT_OK


# --- discover ----------------------------------------------------------------


def test_hosts_seen_on_both_protocols_count_once() -> None:
    """host_count is the union, not the sum: one device answering SSDP and mDNS
    is one host on the segment."""
    v = verdicts.discovery(host_count=1, ssdp_count=1, mdns_count=1)
    assert v.message.startswith("1 host(s)")
    assert "SSDP 1, mDNS 1" in v.message


def test_quiet_segment_names_its_causes() -> None:
    v = verdicts.discovery(host_count=0, ssdp_count=0, mdns_count=0)
    assert v.code == verdicts.EXIT_OK
    assert "client isolation" in (v.next_step or "")


def test_interrupted_silence_is_not_a_quiet_segment() -> None:
    v = verdicts.discovery(host_count=0, ssdp_count=0, mdns_count=0, interrupted=True)
    assert "Too short to call the segment quiet" in (v.next_step or "")


def test_unsearched_mdns_is_named_in_the_scope() -> None:
    """Reporting "mDNS 0" for a window that never opened would claim a search
    that did not happen."""
    v = verdicts.discovery(
        host_count=2, ssdp_count=2, mdns_count=0, mdns_searched=False, interrupted=True
    )
    assert "SSDP only" in v.message
    assert "mDNS 0" not in v.message


def test_interrupted_inventory_is_not_exhaustive() -> None:
    v = verdicts.discovery(host_count=4, ssdp_count=3, mdns_count=2, interrupted=True)
    assert "not exhaustive" in (v.next_step or "")
    assert v.message.startswith("4 host(s)")


# --- zero responders is never a condition ------------------------------------


def test_discovery_never_returns_a_condition_code() -> None:
    """Finding nothing is a valid result for discover, unlike dhcpprobe where
    silence is exit 2. Every path here stays 0."""
    every_path = [
        verdicts.discovery(0, 0, 0),
        verdicts.discovery(0, 0, 0, interrupted=True),
        verdicts.discovery(5, 5, 0),
        verdicts.discovery(5, 5, 0, mdns_searched=False),
        verdicts.discovery(5, 5, 0, mdns_searched=False, interrupted=True),
    ]
    assert all(v.code == verdicts.EXIT_OK for v in every_path)
