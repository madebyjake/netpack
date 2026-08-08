"""Argument parsing shared by the Python tools."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Mapping
from typing import NoReturn

EXIT_USAGE = 1


# Mapping, not dict: dict is invariant in its value type, so a caller holding a
# dict[str, str | None] — which is what argparse hands back — is not a
# dict[str, object] and would be rejected. Mapping is covariant, and read-only
# is all this needs.
def foreign_options(
    mode: str,
    supplied: Mapping[str, object],
    owners: Mapping[str, tuple[str, str]],
) -> list[str]:
    """Flags that were supplied but belong to a different mode.

    `supplied` maps option dest to value, with None meaning "not given" (so the
    parser must declare these options without defaults). `owners` maps dest to
    (owning_mode, flag_text). Returns the offending flags in declaration order,
    empty when everything supplied applies to `mode`.

    A tool with modes should reject these rather than ignore them: silently
    dropping `-t 300` from a send run leaves the operator believing they set a
    duration they did not set.
    """
    return [
        flag
        for dest, (owner, flag) in owners.items()
        if owner != mode and supplied.get(dest) is not None
    ]


class ArgumentParser(argparse.ArgumentParser):
    """argparse exits 2 on a bad argument, but 2 already means 'condition
    found' in every netpack tool (physical-layer growth in linkstat, no DHCP
    response in dhcpprobe, ...). A typo must not be readable as a diagnostic
    result, so usage errors exit 1 here, matching the bash die() helper.
    """

    def error(self, message: str) -> NoReturn:
        print(f"error: {message}", file=sys.stderr)
        print(f"hint: {self.prog} --help", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)
