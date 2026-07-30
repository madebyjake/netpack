# netpack — development and install targets.
#
# The check targets run the same commands as .github/workflows/ci.yml, in the
# same order, so a green `make check` means a green CI run. Keep the two in
# step when either changes.

SHELL := /bin/bash
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
REPO := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Bash tools are selected by shebang: bin/ also holds extensionless Python ones.
SHELL_SCRIPTS = $(shell \
	find $(REPO)/bin -type f -exec awk 'FNR == 1 && /^#!.*bash/ { print FILENAME }' {} + | sort; \
	find $(REPO)/lib -type f -name '*.sh' | sort)
PY_TOOLS = bin/dhcpprobe bin/linkstat bin/discover bin/mcastcheck bin/cabletest

.PHONY: help check test bats lint shellcheck ruff compile smoke install uninstall clean

help:
	@echo "netpack — make targets"
	@echo
	@echo "  make check       Everything CI runs (lint, compile, tests, smoke)"
	@echo "  make test        pytest only"
	@echo "  make bats        bats only"
	@echo "  make lint        ruff + shellcheck"
	@echo "  make compile     py_compile the Python tools"
	@echo "  make smoke       Every tool answers --help"
	@echo "  make install     Symlink netpack and npk into $(BINDIR)"
	@echo "  make uninstall   Remove those symlinks"
	@echo "  make clean       Remove caches and __pycache__"
	@echo
	@echo "Install elsewhere with: make install PREFIX=/usr/local"

check: lint compile test bats smoke
	@echo "all checks passed"

compile:
	cd $(REPO) && python3 -m py_compile lib/netpack/*.py $(PY_TOOLS)

# PYTHONPATH is required: lib/ is not an installed package.
test:
	PYTHONPATH=$(REPO)/lib pytest -q $(REPO)/tests

bats:
	bats $(REPO)/tests/*.bats

lint: ruff shellcheck

ruff:
	cd $(REPO) && ruff check lib/netpack tests $(PY_TOOLS)

# SC2317/SC2329: false positives on trap-invoked cleanup functions.
shellcheck:
	shellcheck --source-path=SCRIPTDIR -x -e SC1091,SC2317,SC2329 $(SHELL_SCRIPTS)

# Mirrors the CI smoke step. The awk sets a flag rather than exiting: exiting
# early closes its end of the pipe while netpack is still writing the legend,
# and under netpack's `set -o pipefail` that write fails with EPIPE.
smoke:
	@$(REPO)/bin/netpack --version
	@$(REPO)/bin/netpack help >/dev/null
	@$(REPO)/bin/npk list >/dev/null
	@$(REPO)/bin/netpack playbooks >/dev/null
	@set -e; \
	mapfile -t tools < <($(REPO)/bin/netpack list \
	  | awk 'NR > 2 { if (NF == 0) stop = 1; if (!stop && $$1 ~ /^[a-z0-9-]+$$/) print $$1 }'); \
	if (( $${#tools[@]} < 12 )); then \
	  echo "expected >= 12 tools, got $${#tools[@]}"; exit 1; \
	fi; \
	for t in "$${tools[@]}"; do \
	  $(REPO)/bin/netpack "$$t" --help >/dev/null || { echo "FAIL: $$t"; exit 1; }; \
	done; \
	echo "smoke: $${#tools[@]} tools answered --help"

# Symlinks rather than copies, so `git pull` updates an installed netpack.
# Only the two launcher names are linked: the tools resolve through it, and
# putting seventeen more names on PATH is not a favour to the user.
install:
	@mkdir -p $(BINDIR)
	@ln -sf $(REPO)/bin/netpack $(BINDIR)/netpack
	@ln -sf $(REPO)/bin/netpack $(BINDIR)/npk
	@echo "installed: $(BINDIR)/netpack"
	@echo "installed: $(BINDIR)/npk"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo; echo "note: $(BINDIR) is not on PATH. Add it with:"; \
	     echo "  echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.bashrc" ;; \
	esac
	@echo
	@$(REPO)/bin/doctor || true

uninstall:
	@rm -f $(BINDIR)/netpack $(BINDIR)/npk
	@echo "removed: $(BINDIR)/{netpack,npk}"

clean:
	@find $(REPO) -name __pycache__ -type d -prune -exec rm -rf {} +
	@rm -rf $(REPO)/.pytest_cache $(REPO)/.ruff_cache
	@echo "cleaned"
