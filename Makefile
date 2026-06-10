# Makefile for org-wiki.  Every check that lefthook, `nix flake check',
# and CI run goes through here, so the gates are identical everywhere.
#
# Run from the dev shell (`nix develop'), which provides an Emacs with
# all dependencies plus shfmt and nixfmt.

EMACS ?= emacs
BATCH := $(EMACS) -Q --batch -L .

PKG_FILES   := org-wiki.el org-wiki-mcp.el
TEST_FILES  := org-wiki-test.el
SCRIPT_EL   := $(wildcard scripts/*.el)
SH_FILES    := $(wildcard scripts/*.sh)
NIX_FILES   := $(wildcard *.nix)
EL_FILES    := $(PKG_FILES) $(TEST_FILES) $(SCRIPT_EL)

.DEFAULT_GOAL := build

# --- Build (byte-compile, all warnings enabled and fatal) -----------

.PHONY: build
build:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(PKG_FILES) $(TEST_FILES)

# --- Tests -----------------------------------------------------------

.PHONY: test
test:
	$(BATCH) -l org-wiki.el -l org-wiki-mcp.el -l $(TEST_FILES) \
	  -f ert-run-tests-batch-and-exit

# --- Lint ------------------------------------------------------------

.PHONY: lint lint-checkdoc lint-package lint-regexps lint-declare
lint: lint-checkdoc lint-package lint-regexps lint-declare

lint-checkdoc:
	$(BATCH) -l scripts/checkdoc.el $(PKG_FILES)

lint-package:
	$(BATCH) -l scripts/lint-package.el $(PKG_FILES)

lint-regexps:
	$(BATCH) --eval "(require 'relint)" -f relint-batch \
	  $(PKG_FILES) $(TEST_FILES)

lint-declare:
	$(BATCH) --eval "(require 'check-declare)" \
	  --eval '(kill-emacs (if (check-declare-files $(patsubst %,"%",$(PKG_FILES))) 1 0))'

# --- Formatting ------------------------------------------------------

.PHONY: format format-check
format:
	$(BATCH) -l scripts/format.el $(EL_FILES)
	shfmt -w -i 2 -ci $(SH_FILES)
	nixfmt $(NIX_FILES)

format-check:
	$(BATCH) -l scripts/format.el --check $(EL_FILES)
	shfmt -d -i 2 -ci $(SH_FILES)
	nixfmt --check $(NIX_FILES)

# --- Coverage --------------------------------------------------------

.PHONY: coverage coverage-check coverage-baseline coverage-html
coverage:
	rm -rf coverage
	rm -f *.elc
	mkdir -p coverage
	UNDERCOVER_FORCE=true $(BATCH) -l scripts/coverage.el \
	  -l $(TEST_FILES) -f ert-run-tests-batch-and-exit

coverage-check: coverage
	scripts/coverage-check.sh

coverage-baseline: coverage
	scripts/coverage-check.sh --update

coverage-html: coverage
	genhtml -o coverage/html coverage/lcov.info
	@echo "open coverage/html/index.html"

# --- Benchmarks ------------------------------------------------------

.PHONY: bench bench-check bench-baseline
bench: build
	mkdir -p bench
	$(BATCH) -l scripts/bench.el -f org-wiki-bench-run > bench/current.tsv
	@cat bench/current.tsv

# A real regression reproduces on a fresh run; one-off scheduler skew
# (e.g. landing on efficiency cores) does not, so retry once before
# failing.
bench-check: bench
	@scripts/bench-check.sh || { \
	  echo "bench-check: retrying once to rule out scheduling noise"; \
	  $(MAKE) bench && scripts/bench-check.sh; \
	}

bench-baseline: bench
	scripts/bench-check.sh --update

# --- Fuzzing ---------------------------------------------------------

.PHONY: fuzz
fuzz:
	$(BATCH) -l scripts/fuzz.el -f org-wiki-fuzz-run

# --- Aggregate gate (mirrors lefthook / nix flake check) -------------

.PHONY: check
check: build test lint format-check coverage-check bench-check fuzz

# --- Housekeeping ----------------------------------------------------

.PHONY: clean
clean:
	rm -f *.elc scripts/*.elc
	rm -rf coverage bench dist .eask
