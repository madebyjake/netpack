"""Verdict selection for the Python tools (no I/O; unit-testable).

Takes measurements, returns the decision; `bin/` prints it. Decided inline in
`bin/` before, where exercising it needed real hardware — so the interrupted
branches had no coverage.

Those branches exist because a cut-short run must not read as a clean one.
"""

from __future__ import annotations

from dataclasses import dataclass

EXIT_OK = 0
EXIT_PHYSICAL = 2
EXIT_CONGESTION = 3
EXIT_FLAP = 4
EXIT_NONE = 2
EXIT_MULTI = 3
EXIT_NOACK = 4
EXIT_INTERRUPT = 130


@dataclass(frozen=True)
class Verdict:
    """What to print, and what to exit with.

    `code` is the tool's classification. The caller downgrades an interrupted
    run to 130, keeping the finding and the "did not complete" signal separate.
    """

    code: int
    message: str
    next_step: str | None = None


def _with_notes(message: str, notes: list[str]) -> str:
    return f"{message} Also: {'; '.join(notes)}." if notes else message


def link_counters(
    errors: int,
    drops: int,
    flaps: int,
    wireless: bool,
    window_s: float,
    interrupted: bool = False,
) -> Verdict:
    """Classify linkstat's counter deltas.

    Precedence: physical > carrier flap > congestion > clean. Lower-priority
    findings still appear as an "Also:" clause, so nothing observed is dropped.

    Wi-Fi carrier changes move on roam and reassoc, so they never reach the flap
    verdict; the caller notes them separately.
    """
    notes: list[str] = []
    if errors > 0 and drops > 0:
        notes.append("drop/fifo counters also increased")
    if errors > 0 and flaps > 0 and not wireless:
        notes.append(f"carrier also flapped {flaps} time(s)")
    if drops > 0 and flaps > 0 and not wireless and errors == 0:
        notes.append(f"carrier also flapped {flaps} time(s)")

    if errors > 0:
        return Verdict(
            EXIT_PHYSICAL,
            _with_notes(
                "error counters increased during the sample (physical layer).", notes
            ),
            "Inspect cabling, connectors, NIC, and duplex negotiation.",
        )

    if flaps > 0 and not wireless:
        return Verdict(
            EXIT_FLAP,
            _with_notes(f"carrier flapped {flaps} time(s) during the sample.", notes),
            "Inspect link stability (cable, SFP, switch port, power).",
        )

    if drops > 0:
        return Verdict(
            EXIT_CONGESTION,
            _with_notes(
                "drop/fifo counters increased during the sample "
                "(congestion or policy).",
                notes,
            ),
            "Check buffer pressure, QoS, and burst load on this port.",
        )

    if interrupted:
        return Verdict(
            EXIT_OK,
            f"no error or drop growth in the {window_s:.1f}s sampled before the "
            "run was interrupted.",
            "A short window sees little; re-run to completion while the symptom "
            "is present before reading this as clean.",
        )
    return Verdict(
        EXIT_OK,
        "no error or drop growth during the sample window.",
        "Re-run while the symptom is present.",
    )


def dhcp_offers(
    offer_count: int,
    dora_state: str | None = None,
    interrupted: bool = False,
) -> Verdict:
    """Classify dhcpprobe's offers.

    `dora_state` is None unless --full ran. An offer without an ACK outranks the
    interrupted wording: it was observed, not merely not-yet-contradicted.
    """
    if offer_count == 0:
        if interrupted:
            return Verdict(
                EXIT_NONE,
                "no DHCP response before the run was interrupted.",
                "Too short to conclude anything; re-run to completion.",
            )
        return Verdict(
            EXIT_NONE,
            "no DHCP response. Server unreachable, wrong VLAN, or no scope on "
            "this segment.",
            "Confirm interface/VLAN membership and that a DHCP service is "
            "expected here.",
        )

    if offer_count == 1:
        if dora_state is not None and dora_state != "ack":
            return Verdict(
                EXIT_NOACK,
                "server offered an address but did not ACK the REQUEST.",
                "Suspect a full pool, reservation conflict, or relay breakage; "
                "check the server's lease log.",
            )
        if interrupted:
            # The branch a truncated window reaches wrongly: a second server
            # answering later was never waited for.
            return Verdict(
                EXIT_OK,
                "one DHCP server responded before the run was interrupted.",
                "This does not rule out a second server; re-run to completion "
                "before treating the segment as clean.",
            )
        return Verdict(EXIT_OK, "single DHCP server responded.")

    suffix = " before the run was interrupted" if interrupted else ""
    return Verdict(
        EXIT_MULTI,
        f"{offer_count} DHCP servers responded on this segment{suffix}.",
        "Compare server identifiers and isolate unexpected responders.",
    )


def discovery(
    host_count: int,
    ssdp_count: int,
    mdns_count: int,
    mdns_searched: bool = True,
    interrupted: bool = False,
) -> Verdict:
    """Classify discover's responders.

    `host_count` is the union of the two protocols, not their sum: a device
    answering both is one host.

    Zero responders is a valid result, never a condition, so the code stays 0
    throughout; only the wording changes.
    """
    total = host_count
    scope = "SSDP only" if not mdns_searched else f"SSDP {ssdp_count}, mDNS {mdns_count}"

    if total == 0:
        if interrupted:
            # A silent segment and a half-second window are indistinguishable
            # here, so this must not read as "nothing there".
            return Verdict(
                EXIT_OK,
                "no responders seen before the run was interrupted.",
                "Too short to call the segment quiet; re-run to completion.",
            )
        return Verdict(
            EXIT_OK,
            "no SSDP or mDNS responders seen.",
            "Quiet segment, discovery filtered by client isolation, or nothing "
            "advertising.",
        )

    if interrupted:
        return Verdict(
            EXIT_OK,
            f"{total} host(s) announced services ({scope}) before the run was "
            "interrupted.",
            "Those seen are real; the list is not exhaustive. Re-run to "
            "completion for a full inventory.",
        )
    return Verdict(
        EXIT_OK,
        f"{total} host(s) announced services ({scope}).",
        "Cross-reference with segscan; unexpected advertisers may be rogue devices.",
    )
