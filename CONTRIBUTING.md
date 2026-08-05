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
# macOS — bash because the tools use declare -g and ${var^^} (bash 4+) while
# macOS ships 3.2, and coreutils because portcheck needs GNU timeout. Both must
# come first on PATH.
brew install shellcheck bats-core bash coreutils
```

CI runs the checks on Linux and on macOS. Debian is the target; the macOS job
exists because its older userland catches portability slips the Linux job
cannot see, and it is not a required check.

## Running the checks

Run `make check` before opening a pull request.

```bash
make check          # everything, in CI's order
make test           # pytest only
make bats           # bats only
make lint           # ruff + shellcheck
make compile        # py_compile the Python tools
make smoke          # every tool answers --help
make help           # all targets
```

`.github/workflows/ci.yml` invokes these same targets, one step per target, so
the Makefile is the single definition of what a check is — a green `make check`
locally means a green CI run, and the two cannot drift. Change a check in the
Makefile, not in both places.

`ruff` is pinned to a minor series in `requirements-dev.txt` because its default
rule set changes between minors, which would turn CI red with no code change.
`pyproject.toml` pins the rules themselves for the same reason — 0.16 dropped
E402 from its defaults, so an unpinned ruff flagged every `sys.path.insert`
before a `netpack` import.

That file is configuration only; there is no Python package to build. It also
tells pytest and any type checker where `lib/` is, so bare `pytest` works and
editors resolve `netpack` imports.

## Adding a tool

1. Write `bin/<tool>`, executable, with `--help` and documented exit codes.
2. Add one row to `TOOL_ROWS` in `lib/netpack/tools.sh`.
3. Add the tool name to the right section of `SECTIONS` in `bin/netpack`.
4. Add a `tool_header <tool>` block to `bin/doctor` for its dependencies.
5. Add it to the tools table and an example in `README.md`.
6. If it is a Python tool, add it to `PY_TOOLS` in the `Makefile` so `ruff` and
   `py_compile` cover it. Bash tools are found by shebang and need nothing.

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

**Safety.** Tools that generate meaningful load carry the `loud` tag and an
impact line. Anything that could disrupt production traffic must be guarded in
code, not just documented — see `mcastcheck send` refusing Dante's default
media range without `-y`, and `segscan` refusing sweeps larger than /22
without `-y`.

**Evidence survives interruption.** Ctrl-C is a normal way to end a field test.
Print the report and write `--dump` anyway, and say in the assessment that the
run was cut short.

## Commits and branches

Commits follow [Conventional Commits
1.0.0](https://www.conventionalcommits.org/en/v1.0.0/#specification):
`type(scope): subject`. Scope is the tool or area it touches; omit it for
repo-wide changes.

```
feat(mtucheck): -i binds DF probes to an uplink and tests its gateway
fix(dnscheck): reject record types dig would silently query as A
docs(readme): multi-homed behavior and -i in the production notes
chore(version): bump version to 0.7.0
```

Branches follow [Conventional Branch
1.0.0](https://conventionalbranch.org/v1.0.0/#specification):
`<type>/<description>`, where type is `feature`, `bugfix`, `hotfix`, `release`,
or `chore`, and the description is lowercase alphanumeric and hyphens.

```
bugfix/discover-dump-assessment-code
feature/bash-json-dump
chore/document-commit-conventions
```

One logical change per branch: a `chore:` commit does not belong on a `bugfix/`
branch. Branches created before this was adopted (`feat/menu-polish`,
`release-0.7.0`) do not match and are not precedent.

Do not add `Co-Authored-By` or other trailers.

Comments, commit messages, and documentation stay concise and neutral —
state the fact, not the rationale around it.

## Releasing

The version lives in `lib/netpack/__init__.py` and nowhere else; the launcher
and `lib/netpack.sh` both read it from there. Bump it, then tag with the bare
version (`x.x.x`), matching the existing tags. Release notes are kept in the
GitHub release for the tag.
