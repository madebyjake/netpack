# Contributing

Working notes for developing netpack. For usage see [README.md](README.md).

## Layout

```
bin/            One executable per tool, plus the netpack launcher (npk -> netpack)
lib/netpack.sh  Shared bash helpers: reporting, validation, interface resolution
lib/netpack/    Python package, and the bash pieces shared beyond one tool
tests/          pytest for Python, bats for bash
```

Two data tables in `lib/netpack/` drive the launcher and are the only place
their facts live: `tools.sh` (root/traffic tags, descriptions, impact notes) and
`playbooks.sh` (guided sequences and the reason for each step).

The split is deliberate: **anything that parses or decides lives in `lib/` as a
pure function, and `bin/` does the I/O.** That is what makes the logic testable
without a network, a switch, or root — `link.py` parses the `ethtool` text that
`bin/linkstat` and `bin/cabletest` captured, `mcast.py` decodes probe datagrams,
and `parsers.sh` holds the same for the bash tools: ping and mtr summaries,
resolver enumeration, ARP duplicate detection, `iw scan` records, and the
classifiers behind the HTTP, MTU and loss verdicts.

New logic follows the same shape. A verdict computed inline in `bin/` cannot be
tested, and that is exactly where the resolver bug in `dnscheck` lived.

## Development setup

Python tooling comes from pip; `shellcheck` and `bats` are system packages
(bats is not on PyPI, so it cannot live in `requirements-dev.txt`).

```bash
pip install -r requirements-dev.txt

# Debian/Ubuntu
sudo apt install shellcheck bats
# Fedora
sudo dnf install ShellCheck bats
```

## Running the checks

These are the same steps CI runs, in the same order. Run them before opening a
pull request.

```bash
# Python tests. PYTHONPATH is required: lib/ is not an installed package.
PYTHONPATH=lib pytest -q tests

# Bash tests (parsers, launcher metadata, exit-code contracts)
bats tests/*.bats

# Lint
ruff check lib/netpack tests bin/dhcpprobe bin/linkstat bin/discover bin/mcastcheck

# Shellcheck every bash script, selected by shebang
mapfile -t scripts < <(
  find bin -type f -exec awk 'FNR == 1 && /^#!.*bash/ { print FILENAME }' {} + | sort
  find lib -type f -name '*.sh' | sort
)
shellcheck --source-path=SCRIPTDIR -x -e SC1091,SC2317,SC2329 "${scripts[@]}"

# Smoke: every tool must answer --help
bin/netpack list
for t in $(bin/netpack list | awk 'NR > 2 { if (NF == 0) exit; if ($1 ~ /^[a-z0-9-]+$/) print $1 }'); do
  bin/netpack "$t" --help >/dev/null || echo "FAIL: $t"
done
```

`ruff` is pinned to a minor series in `requirements-dev.txt` because its default
rule set changes between minors, which would turn CI red with no code change.

## Adding a tool

1. Write `bin/<tool>`, executable, with `--help` and documented exit codes.
2. Add one row to `TOOL_ROWS` in `lib/netpack/tools.sh`.
3. Add the tool name to the right section of `SECTIONS` in `bin/netpack`.
4. Add a `tool_header <tool>` block to `bin/doctor` for its dependencies.
5. Add it to the tools table and an example in `README.md`.

Steps 2–5 are enforced: `tests/test_launcher.bats` and `tests/test_docs.py` fail
if a tool is missing metadata, has an unknown tag, is absent from `doctor`, or
disagrees with the README. That is deliberate — those facts were previously
restated in five places and silently drifted apart.

## Adding a playbook

Playbooks are the ordered sequences the menu's `p` key and `netpack playbook`
walk. Add one row to `PLAYBOOK_ROWS` in `lib/netpack/playbooks.sh`, its steps to
`PLAYBOOK_STEPS`, and the matching `npk playbook <id>` pointer to the README
sequence it corresponds to.

A step's "why" is required, and it is the point: it says what the operator
should conclude from the result they are about to see. Steps run through the
same path as a hand-picked run, so privilege, prompting, impact notices and
capture all behave identically — leave arguments off a step when the launcher
already knows how to prompt for them (`portcheck`, `ringcap`, `mcastcheck`).

Only single-machine sequences belong here; anything needing a second host stays
prose in the README. `tests/test_launcher.bats` fails on a step naming an
unknown tool, a playbook with fewer than two steps, or a step without a reason.

## Conventions

**Exit codes.** `0` clean, `1` usage/dependency/permission, `2+` a
tool-specific condition found, `130` interrupted. Never return `2` for a usage
mistake: `2` already means "condition found", so a typo would read as a
diagnostic result. Python tools get this from `netpack.cli.ArgumentParser`.

**Reject unknown input.** Tools must not fall back to defaults when handed
something they do not understand — `no_extra_args "$@"` in bash, and reject
options that do not apply to the selected mode. A silently ignored argument
produces confident, wrong evidence.

**Report shape.** `header <tool>` first, `section` per block, `verdict`
(rendered as `ASSESSMENT:`) with an optional next step, `finished` last. Bash
uses `lib/netpack.sh`, Python uses `netpack.report`; keep the two in step.

**Colour.** Only when stdout is a TTY and `NO_COLOR` is unset, so redirected
evidence stays plain text.

**Safety.** Tools that generate meaningful load carry the `LOUD` tag and an
impact line. Anything that could disrupt production traffic must be guarded in
code, not just documented — see `mcastcheck send` refusing Dante's default
media range without `-y`, and `segscan` refusing sweeps larger than /22
without `-y`.

**Evidence survives interruption.** Ctrl-C is a normal way to end a field test.
Print the report and write `--dump` anyway, and say in the assessment that the
run was cut short.

## Releasing

The version lives in `lib/netpack/__init__.py` and nowhere else; the launcher
and `lib/netpack.sh` both read it from there. Bump it, then tag with the bare
version (`x.x.x`), matching the existing tags. Release notes are kept in the
GitHub release for the tag.
