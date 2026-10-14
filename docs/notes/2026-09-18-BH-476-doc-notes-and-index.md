# Dated notes replace appending to the five contract docs

Doc: MERGE-CONDUCTOR, BUILD-CONCURRENCY, RUN-BUILD-GRAPH, OPERATOR-SETUP, EVENTS

**What changed.** Documentation of a change now goes in its own file here,
`docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md`, instead of being appended to the doc
it relates to. `bin/render-doc-index.sh` renders `INDEX.md` over these notes,
newest first, grouped by the `Doc:` tag each note carries. The five contract
docs each got a three-line Changes region under their H1 pointing here, and
nothing else in them moved — no existing prose was migrated.

**Why.** Those five files were edited in 18, 14, 9, 9 and 9 of the 100 PRs
merged 2026-09-13..15, they hold 5,625 lines between them (most of it dated
prose about changes), and on 2026-09-16 nine of seventeen cromford builds
answered `BUILD_DEFERRED file overlap` on exactly them. Two builds documenting
two unrelated things were colliding on the same paragraph boundary.

**What it touches.**

- `bin/render-doc-index.sh` — reads `docs/notes/`, writes `docs/notes/INDEX.md`.
  Deterministic by construction: no clock, no hostname, no counts, so a
  re-render over an unchanged directory produces an empty diff. A docs pass runs
  it; a feature PR does not.
- `guardrails/doc-monolith-edit/` — fails a diff that edits one of the five docs
  outside its `<!-- changes:begin -->` / `<!-- changes:end -->` region, or that
  renames or deletes one of them, unless the PR title starts with `docs:`.
  Shipped with fixtures and a copy-ready CI step; arming it in
  `.github/workflows/harness-ci.yml` is a separate PR, the way
  `guardrails/README.md` prescribes for adoption.
- `prompts/plan-contract.md` §8 and `prompts/build-discipline.md` D37 — what
  "document it" means now, for planners and builders respectively.

**The rule this note is itself an instance of:** one note per change, never
edited after merge. A correction is a later note.
