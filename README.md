# `org-wiki` — read-only spike

This package is the **read-only spike** for the architecture specified in
[`../docs/org-llm-wiki.md`](../docs/org-llm-wiki.md). Its purpose is *not*
to be the final implementation — it's to empirically validate the
load-bearing assumptions of the design before the mutation tools are
built.

The spike exists because four rounds of adversarial document review on
the parent architecture doc kept finding subtle bugs in *implementation
details* that prose alone couldn't catch reliably. Each round resolved
the bugs it found but introduced new ones. The pattern suggested that
the next revision shouldn't be more prose — it should be running code.

This package is that code.

## What it does

Read-only MCP tools exposing four wiki operations:

| Tool                | Args         | Returns                                                    |
|---------------------|--------------|------------------------------------------------------------|
| `wiki_search`       | `query, k`   | Top-K matching wiki nodes (semantic-first if available)    |
| `wiki_read_node`    | `id`         | Full body of the node                                      |
| `wiki_node_metadata`| `id`         | Property drawer as a plist (hash property stripped)        |
| `wiki_backlinks`    | `id`         | Nodes that link to this one (via `org-roam-backlinks-get`) |

None of these mutate anything. None need a WAL, a file lock, recovery, or
sandboxing. They're the safe subset of the architecture's MCP surface,
and they're enough to exercise every load-bearing assumption the
mutation slice would depend on.

## What it verified

All 21 ERT tests pass (one is skipped when the optional `org-hash`
isn't present) against Emacs 30.2 with `mcp-server-lib` 0.4.0,
`org-roam`, and `org-ql`. The tests double as empirical verification
of architecture-doc claims.

### ✅ `(property "WIKI_KIND")` matches by existence

The architecture doc's §2.1 identity predicate (and the dblock queries
in §11) use a one-arg `(property "WIKI_KIND")` form. The test
`org-wiki-test-property-predicate-matches-existence` constructs two
fixture files — one with `:WIKI_KIND: Concept`, one without — and runs
`(org-ql-select files '(property "WIKI_KIND") ...)`. The matcher
correctly returns the wiki node and excludes the non-wiki node.

**Conclusion:** the predicate is sound. The doc's claim survives. Use
`(property "WIKI_KIND")` as the wiki-node identity predicate everywhere.

### ✅ Multi-positional-arg handlers register cleanly

The test `org-wiki-test-mcp-register-tool-accepts-multi-arg` registers a
two-argument handler and verifies the tool appears in the registry. The
auto-generated schema is built from the arglist with parameter
descriptions parsed from the `MCP Parameters:` docstring block.
(Registration goes through `mcp-server-lib-register-server` — the
per-tool `mcp-server-lib-register-tool` this spike originally used is
obsolete as of 0.3.0, and the package was ported accordingly.)

**Conclusion:** multi-arg defuns are the right pattern for typed
parameters. The doc's Appendix C signature shape is sound. Note that
all schema-level types are `"string"` (verified by reading the
generator at `mcp-server-lib.el:323–340`); complex args must be
JSON-encoded strings the handler parses, as the doc already documents.

### ✅ Schema-from-docstring parsing works

The test `org-wiki-test-mcp-schema-from-docstring` verifies that an
`MCP Parameters:` block in the docstring is correctly parsed into JSON-
schema parameter descriptions. Both parameter names and descriptions
appear in the generated schema.

**Conclusion:** the doc's `MCP Parameters:` discipline is verified.
The format requirement (2–4 space indent for `name - description`, 6+
spaces for continuation) matches the regex at `mcp-server-lib.el:233`.

### ✅ Tool-error type catch-up bug (v2.2's fix is necessary)

The test `org-wiki-test-tool-error-survives-rewrap-pattern` runs two
patterns of `condition-case`:

```elisp
;; Pattern A — v2.2 originally recommended (BUG)
(condition-case _err
    (signal 'mcp-server-lib-tool-error '("structured"))
  (error                'caught-by-generic-error)
  (mcp-server-lib-tool-error 'caught-by-specific))
;; => 'caught-by-generic-error    (the tool-error gets eaten by generic)

;; Pattern B — this spike's fix
(condition-case _err
    (signal 'mcp-server-lib-tool-error '("structured"))
  (mcp-server-lib-tool-error 'caught-by-specific)
  (error                'caught-by-generic-error))
;; => 'caught-by-specific         (the tool-error is preserved)
```

`mcp-server-lib-tool-error` inherits from `user-error` which inherits
from `error`. `condition-case` walks clauses in order, so a generic
`(error ...)` placed first absorbs the tool-error before the specific
clause can match. The fix is to place the specific clause first.

`org-wiki-mcp--with-error-handling` does exactly this — it re-signals
tool errors before catching the generic `error`. The tests
`org-wiki-test-with-error-handling-preserves-tool-error` and
`...-converts-generic-error` verify both halves.

**Conclusion:** the architecture doc's §7.0 error-handling pattern is
necessary and correct *only when written in the order this spike
demonstrates*. Implementations that copy v2.2's prose without paying
attention to clause order will silently lose tool-error payloads.

### ✅ Enable/disable round-trip

Registering all four tools, then disabling, leaves the registry clean.
Double-enable signals a clear `user-error`. The preflight via
`org-wiki-mcp--registered` prevents `mcp-server-lib`'s silent
ref-counted re-registration (which keeps the *original* handler and
ignores the new one — documented in the `register-server` docstring).

### ✅ Identity predicate corner cases

Per §2.1 of the architecture doc, **identity is property-only**: a
`:WIKI_KIND:` property is necessary and sufficient. The directory is
a placement convention, not part of identity. Four tests cover the
relevant predicates:

- `org-wiki-node-p` on a heading with `:WIKI_KIND:` under wiki-root → t.
- `org-wiki-node-p` on a heading without `:WIKI_KIND:` (anywhere) → nil.
- `org-wiki-node-p` on a heading with `:WIKI_KIND:` *outside* wiki-root
  → **t** (it's a valid wiki node; just not in the canonical location).
- `org-wiki-writable-p` on the same outside-root node → **nil**. Write
  tools refuse it even though read tools accept it.

The write-allowlist (§3.5) is the only place where path matters for
wiki semantics.

### ✅ `org-hash-property` accessor

When `org-hash` is loaded, `(org-hash-property)` returns
`"HASH_sha512_256"` (lowercase suffix; verified by the actual returned
string against `(format "HASH_%s" 'sha512_256)`). The architecture
doc's recommendation to always go through this accessor rather than
hardcoding a literal is sound.

### ✅ Read-path error semantics

`org-wiki-read-node` signals `org-wiki-error` (a fresh error class)
for: unknown IDs, IDs not present in the named file, and entries that
exist but aren't wiki nodes (lack `:WIKI_KIND:`). All three are tested.

## What it did *not* verify (out of scope)

The read-only spike intentionally does not exercise — and therefore
does not validate — the following parts of the architecture doc, which
remain 🔴 in the document status badges:

- **§7.6 transaction discipline** — file locks, WAL pending/committed
  rows, `unwind-protect` discipline. No mutation, no need to lock or
  log.
- **§7.6.1 mutation discipline** — `org-element-cache-reset`,
  back-to-front edits. No mutation.
- **§9.4 hook ordering** — `org-hash--inhibit-on-save` discipline.
  No saves.
- **§13.3 journal schema** — `pending`/`committed` rows,
  `intended_hash`, `file_path`. No journal needed.
- **§13.4 concurrent edits** — `org-wiki-mode` save-guard. No saves.
- **§5.3 Option B** — `org-attach`-based raw storage. The spike
  doesn't ingest anything, so it doesn't attach anything.
- **§10 embedding backend** — the spike falls back to text search
  when `org-ql-semantic-files` isn't loaded; semantic-path is exercised
  only when the user has the backend configured.

These will be the subjects of subsequent spikes when the mutation slice
is built.

## How to run the tests

The dev shell provides an Emacs with every dependency already on the
load path:

```sh
nix develop --command make test
```

Expected output: `Ran 21 tests, 20 results as expected, 0 unexpected,
1 skipped`. (The `org-hash` test is skipped unless that package is
present; it is optional and not part of the pinned toolchain.)

## How to use it interactively

Add to `~/org/init.org`:

```elisp
(use-package org-wiki
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :commands (org-wiki-search org-wiki-read-node
             org-wiki-node-metadata org-wiki-backlinks
             org-wiki-mcp-enable org-wiki-mcp-disable))

(use-package org-wiki-mcp
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :after (org-wiki mcp-server-lib)
  :config (org-wiki-mcp-enable))
```

Then create `~/org/wiki/` and start adding wiki nodes. From Claude
Code (connected via MCP), the four tools should appear under the
configured server-id (`"default"` by default; see
`org-wiki-mcp-server-id`).

## Empirical implications for the architecture doc

Sections of `../docs/org-llm-wiki.md` that this spike has *verified or
corrected*:

| Section | Status before spike | Status after spike |
|---------|---------------------|--------------------|
| §2.1 `(property "WIKI_KIND")` identity | 🟢 (claimed correct) | ✓ verified |
| §7.0 MCP register-tool signature | 🟡 | ✓ verified |
| §7.0 `MCP Parameters:` docstring schema | 🟡 | ✓ verified |
| §7.0 error-handling clause order | 🟡 | ✓ verified — bug fix in spike is required |
| §4.1 `(org-hash-property)` accessor | 🟢 | ✓ verified |
| Appendix C signatures (read-only subset) | 🔴 | ✓ verified for these four |

Sections that the spike *cannot* address by construction (no mutation
in the read-only slice) remain 🟡/🔴 pending a mutation spike.

## Next steps

1. Run this spike interactively against the user's real wiki when the
   user creates `~/org/wiki/`.
2. Document any surprises (LLM behavior, performance, ergonomics) in a
   short addendum below.
3. Build the mutation slice — *only after* the read-only slice has been
   exercised long enough that the user has a concrete sense of what
   they actually need.

## Development

Every check runs through the Makefile, and the Makefile expects the
Nix dev shell, so there is exactly one toolchain to argue with:

```sh
nix develop          # Emacs + org-roam/org-ql/mcp-server-lib, eask, lefthook, shfmt, nixfmt
make check           # the full gate
```

| Target              | What it does                                                        |
|---------------------|---------------------------------------------------------------------|
| `make build`        | Byte-compile with all warnings enabled and treated as errors        |
| `make test`         | Run the ERT suite                                                   |
| `make lint`         | checkdoc, package-lint, relint, and `check-declare`                 |
| `make format`       | Canonical indentation for Elisp; `shfmt` and `nixfmt` for the rest  |
| `make format-check` | Same, but verify only — non-zero exit on any diff                   |
| `make coverage`     | ERT suite under `undercover`, lcov report in `coverage/lcov.info`   |
| `make coverage-check` | Fail if line coverage drops below `baselines/coverage.txt`        |
| `make coverage-html` | Render the lcov report with `genhtml`                              |
| `make bench`        | Calibrated CPU-time benchmarks, TSV report in `bench/current.tsv`   |
| `make bench-check`  | Fail if any benchmark regresses more than 5% against the baseline   |
| `make fuzz`         | Seeded random-input harness against the public API and MCP handlers |
| `make check`        | All of the above, in dependency order                               |

A few notes on the corners of this:

- **Baselines** live in `baselines/`. Coverage is deterministic for a
  pinned toolchain, so its gate has zero slack. Benchmark numbers are
  minimum CPU times expressed as a ratio of an in-process calibration
  loop, so scheduler placement and frequency scaling cancel out
  instead of producing false regressions; regenerate with `make
  bench-baseline` when the Emacs toolchain changes. A failed gate
  re-runs the harness once before failing, since one-off noise does
  not reproduce but a real regression does.
- **Fuzzing**: Emacs Lisp has no coverage-guided fuzzer, so
  `scripts/fuzz.el` is the practical equivalent — a seeded
  random-input harness that asserts the API's error contract. Set
  `FUZZ_SEED`/`FUZZ_ITERATIONS` to vary the run.
- **No sanitizer target**: Elisp is garbage-collected and has no
  manual memory management, so there is nothing for an ASan/MSan
  analogue to check.
- **Docs**: this README is the documentation; there is no separate
  build step for it.

Pre-commit hooks run all of these in parallel via
[lefthook](https://github.com/evilmartians/lefthook):

```sh
nix develop --command lefthook install
```

GitHub Actions runs `nix flake check` (which executes the same
Makefile targets in the sandbox), `nix build`, and uploads the
coverage and benchmark reports as artifacts.

## License

BSD 3-clause; see [LICENSE.md](LICENSE.md).
