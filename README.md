# org-wiki: an Org-native LLM Wiki

`org-wiki` is an Emacs Lisp implementation of the read side of an
Org-native LLM Wiki: a curated, interlinked knowledge layer inside an
existing Org-roam corpus that LLMs can search, read, and cite through
structured tools.

The larger LLM Wiki idea is simple: do not make the model rediscover
the same structure from raw documents on every query. Ingest sources
once, synthesize them into stable wiki nodes, connect those nodes with
links and metadata, and answer later questions from the accumulated
wiki. The wiki becomes a durable memory of prior synthesis rather than
another transient retrieval result.

This repository is the first working slice of that design. It is
intentionally read-only: it exposes search, read, metadata, and backlink
operations over wiki nodes, and it provides those operations to three
callers:

- MCP clients, through `mcp-server-lib`
- Emacs users, through minibuffer commands
- gptel conversations, through direct gptel tools and an `org-wiki`
  preset

The full architecture, including planned ingest and mutation workflows,
lives in [`../docs/org-llm-wiki.md`](../docs/org-llm-wiki.md). This
package is the implementation-backed core that validates the read model
and is already useful against a real Org-roam corpus.

## The Concept

A conventional RAG system searches raw source material at query time and
asks the model to synthesize an answer on the spot. That works, but the
synthesis is ephemeral. The next question pays the same cost again, and
the system has no durable place to record concepts, disagreements,
cross-source links, or open questions.

An LLM Wiki moves synthesis into the knowledge base itself:

1. Sources are read and integrated into wiki nodes.
2. Nodes are organized by kind, linked by stable IDs, and cited back to
   sources.
3. Query-time answers are composed from wiki nodes, not from raw source
   documents.
4. Coverage gaps become explicit: if the wiki does not know enough, the
   answer should say what is missing and suggest a source to ingest.

In Org-wiki, the storage layer is plain Org. A wiki node is an Org
heading with an `:ID:` and a `:WIKI_KIND:` property. Org-roam supplies
stable IDs, backlinks, and graph structure; org-ql supplies fast
property-based selection; optional `org-ql-semantic` supplies semantic
search. LLM access is mediated through tools rather than arbitrary file
edits.

## Current Scope

This repository implements the read-only surface of the wiki. It does
not yet implement source ingest, node creation, node mutation, lint
repair, transaction logging, raw artifact registration, embedding sync,
or recovery. Those are mutation-side concerns described in the
architecture document.

What is implemented here:

- wiki-node identity and discovery
- semantic-first search with literal fallback
- node body reads by ID
- metadata reads with tool-maintained hash properties stripped
- backlink reads through org-roam
- MCP tool registration
- interactive Emacs commands
- gptel tools, preset, one-shot ask command, and persistent chat command
- tests, fuzzing, coverage gates, benchmarks, formatting, linting, and
  Nix/CI integration

The read-only boundary is deliberate. It makes the package safe to use
against a personal corpus while proving the assumptions the write side
will depend on.

## Data Model

Wiki identity is property-based. Any Org heading with `:WIKI_KIND:` is a
wiki node, regardless of its file path:

```org
* Content-Addressed Storage
:PROPERTIES:
:ID:            4f1c3b8e-9ad2-4b7e-9d04-1a5e6f7c8b91
:WIKI_KIND:     Concept
:CONFIDENCE:    high
:END:

** Summary
Content-addressed storage names data by the hash of its content.
```

`org-wiki-root` defaults to `~/org/wiki/`. That directory is the
canonical home for new wiki files, but it is not the read identity
predicate. Reads can find any Org-roam node whose properties mark it as
part of the wiki. Path boundaries matter later for writes: a future
mutation tool can refuse to edit a drifted node outside `org-wiki-root`
while read tools continue to see it.

Supported `:WIKI_KIND:` values are:

- `Concept`
- `Entity`
- `Topic`
- `Comparison`
- `Question`
- `Source-Record`
- `Frozen`
- `Index`

Org-wiki also handles the two-ID convention common in this corpus:
files may have a top-level file ID while the real wiki node has a
heading ID. Read tools accept the file-level ID as an alias and return
the canonical heading ID so callers learn what to cite next time.

## Implementation

The package is split into four modules.

| File | Role |
| --- | --- |
| `org-wiki.el` | Data core: node predicates, candidate discovery, search, reads, metadata, backlinks, ID normalization, and structured errors. |
| `org-wiki-mcp.el` | Read-only MCP tool registration around the data core. |
| `org-wiki-commands.el` | Interactive Emacs commands with optional consult previews and embark actions. |
| `org-wiki-gptel.el` | Direct gptel tools, the `org-wiki` preset, `org-wiki-ask`, and `org-wiki-chat`. |

### Search

`org-wiki--search` returns node summaries with `:id`, `:title`,
`:kind`, `:file`, and `:summary`.

When `org-ql-semantic` is available, search is semantic-first and ranks
matches by score. If the semantic backend is absent, misconfigured,
errors, or returns no results, Org-wiki falls back to literal text
search over headings and body text. This keeps the tools useful when an
embedding service is down and keeps literal hits from disappearing
behind a failed semantic path.

Candidate discovery unions files under `org-wiki-root` with org-roam DB
entries whose properties include `WIKI_KIND`, so property-based identity
is honored across the corpus.

### Reads

`org-wiki-read-node` returns the full Org subtree for a node ID.
`org-wiki-node-metadata` returns a plist of property values and removes
hash-maintenance properties such as `HASH_*`.
`org-wiki--backlinks` returns backlink plists with source ID, title, and
file, using org-roam when available.

Errors use the `org-wiki-error` condition with stable payloads such as
`:unknown_id`, `:id_not_in_file`, and `:not_a_wiki_node`. The MCP and
gptel layers convert these into JSON-shaped tool results.

### MCP Tools

`org-wiki-mcp-enable` registers four read-only tools:

| Tool | Arguments | Result |
| --- | --- | --- |
| `wiki_search` | `query`, `k` | Matching node summaries. |
| `wiki_read_node` | `id` | Full Org body plus canonical ID. |
| `wiki_node_metadata` | `id` | Property drawer as JSON, hash properties omitted. |
| `wiki_backlinks` | `id` | Nodes that link to the target node. |

The default MCP `server-id` is `"default"` and can be customized with
`org-wiki-mcp-server-id`. Tool names are prefixed with `wiki_` to avoid
generic names on a shared endpoint. Registration is guarded so
double-enable fails clearly instead of silently keeping stale handlers.

The MCP wrapper preserves structured tool errors. This matters because
`mcp-server-lib-tool-error` is a subtype of `error`; a generic
`condition-case` clause placed first would accidentally catch and
rewrite it.

### Emacs Commands

`org-wiki-commands.el` adds user-facing commands for the same read-only
operations:

| Command | Behavior |
| --- | --- |
| `org-wiki-search` | Search wiki nodes and visit a selected result. With a prefix argument, force literal search. |
| `org-wiki-find` | Pick a wiki node by title and visit it. |
| `org-wiki-backlinks` | Show nodes linking to the node at point or a chosen node. |
| `org-wiki-show-metadata` | Display node metadata in a transient buffer. |

The commands work with plain `completing-read`. If `consult` is loaded,
candidates get live previews. If `embark` is loaded, wiki candidates and
`id:` links at point get actions for visiting, copying/inserting links,
showing backlinks, and showing metadata.

The package provides an unbound prefix keymap:

```elisp
(keymap-set global-map "C-c w" 'org-wiki-command-map)
```

This gives `C-c w s`, `C-c w f`, `C-c w b`, and `C-c w m` for search,
find, backlinks, and metadata.

### gptel Integration

`org-wiki-gptel.el` exposes the same four operations as direct gptel
tools. This avoids an MCP hop when the LLM conversation is already
inside Emacs.

User-facing entry points:

- `M-x org-wiki-ask` asks one question and streams an Org-formatted
  answer into `*org-wiki-ask*`.
- `M-x org-wiki-chat` opens a persistent gptel chat buffer with the
  `org-wiki` preset applied.
- `@org-wiki <question>` can be used in gptel prompt transforms once
  the preset is registered.
- `ob-gptel` blocks can use `:preset org-wiki`.

The preset does not set a backend or model; it inherits the active gptel
backend. `org-wiki-ask` and `org-wiki-chat` still resolve and pin a
concrete model buffer-locally so a nil global `gptel-model` is not sent
to a provider.

The system prompt enforces the query discipline: search first, read
every relied-upon node, cite claims with Org `[[id:...][title]]` links,
and report coverage gaps instead of answering from general knowledge.

## Installation

The package is developed inside the dot-emacs tree, but it can be loaded
directly from this directory:

```elisp
(use-package org-wiki
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :commands (org-wiki-read-node
             org-wiki-node-metadata
             org-wiki-canonical-id))

(use-package org-wiki-commands
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :after org-wiki
  :commands (org-wiki-search
             org-wiki-find
             org-wiki-backlinks
             org-wiki-show-metadata)
  :config
  (keymap-set global-map "C-c w" 'org-wiki-command-map))
```

To expose the read tools to MCP clients:

```elisp
(use-package org-wiki-mcp
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :after (org-wiki mcp-server-lib)
  :config
  (org-wiki-mcp-enable))
```

To use the gptel integration:

```elisp
(use-package org-wiki-gptel
  :load-path "~/src/dot-emacs/lisp/org-wiki"
  :after org-wiki
  :commands (org-wiki-ask org-wiki-chat org-wiki-gptel-register))
```

Create `~/org/wiki/`, add Org nodes with `:ID:` and `:WIKI_KIND:`, and
ensure org-roam has indexed them. The read tools will then operate over
the wiki subset of the corpus.

## What This Proves

The test suite is not just regression coverage; it records empirical
answers to design questions from the architecture document:

- `(property "WIKI_KIND")` is a sound org-ql identity predicate.
- Read identity can be property-only while future write permission can
  remain path-bounded.
- Semantic search can degrade cleanly to literal search.
- Hits on child headings can surface the enclosing wiki node.
- File-level IDs can be accepted as aliases while canonical heading IDs
  remain the citation target.
- `mcp-server-lib` parses `MCP Parameters:` docstrings into schemas for
  positional handlers.
- Structured MCP tool errors must be caught before generic `error`
  clauses.
- The gptel preset must store category-qualified tool objects so
  duplicate `wiki_*` names from another category cannot shadow the
  direct Org-wiki tools.

## Not Yet Implemented

The following are intentionally outside this repository's current
surface:

- source ingest and raw artifact management
- creation, patching, merging, or deletion of wiki nodes
- validator and lint-repair tools
- write-ahead logging, crash recovery, file locks, and transaction
  replay
- hash refresh and tamper-evidence on mutation
- embedding queue maintenance and sync repair
- privacy/read filtering beyond the `:WIKI_KIND:` read predicate
- publication workflows

Those features require a mutation discipline. The current package keeps
the useful, safe read path small and well tested before that complexity
is added.

## Development

The Nix dev shell provides Emacs and the package dependencies:

```sh
nix develop
make check
```

Common targets:

| Target | Purpose |
| --- | --- |
| `make build` | Byte-compile package and tests with warnings as errors. |
| `make test` | Run the ERT suite. |
| `make lint` | Run checkdoc, package-lint, relint, and check-declare. |
| `make format` | Format Elisp, shell scripts, and Nix files. |
| `make format-check` | Verify formatting without modifying files. |
| `make coverage-check` | Run coverage and compare against the baseline. |
| `make bench-check` | Run benchmarks and compare against the baseline. |
| `make fuzz` | Run the seeded random-input harness. |
| `make check` | Run the aggregate local gate. |

Pre-commit hooks run the same gates in parallel through lefthook:

```sh
nix develop --command lefthook install
```

GitHub Actions runs `nix flake check`, `nix build`, and report
generation for coverage and benchmarks.

## License

BSD 3-clause; see [LICENSE.md](LICENSE.md).
