# Guardrail: doc-monolith-edit

**Principle:** a contract doc holds what is TRUE now — state tables, invariants,
commands. What *changed* goes in its own dated note. A doc that accumulates
"since 2026-09-1x this changed" paragraphs stops being readable and starts being
a merge conflict every build wants to have.

**What it catches:** a diff that edits one of the guarded contract docs
(`docs/MERGE-CONDUCTOR.md`, `docs/BUILD-CONCURRENCY.md`, `docs/RUN-BUILD-GRAPH.md`,
`docs/OPERATOR-SETUP.md`, `docs/EVENTS.md` by default) outside its rendered
Changes region, under a PR title that is not a `docs:` pass.

**Why it was worth a check:** in the 100 PRs merged 2026-09-13..15 those five
files were edited 18/14/9/9/9 times, they hold 5,625 lines between them, and on
2026-09-16 nine of seventeen cromford builds were deferred on file overlap
in exactly them. The rule had been prose in the plan contract for weeks. Prose
does not stop a build that is already appending.

**Tool:** shell (`check.sh`). The other half of the change is
`bin/render-doc-index.sh`, which renders `docs/notes/INDEX.md` over the notes
this check pushes work toward. The index is a git-ignored render (BH-8254); a
PR never commits it.

```bash
PR_TITLE="$(gh pr view --json title -q .title)" \
  guardrails/doc-monolith-edit/check.sh origin/main        # CI form
PR_TITLE='feat: x' DOC_MONOLITH_DIFF=pr.diff \
  guardrails/doc-monolith-edit/check.sh                    # testable form
```

## Three ways through

1. **Write a note instead.** `docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md`, one per
   change, with a `Doc: <NAME>[, <NAME>]` line naming the docs it belongs to.
   Nothing in the guarded docs changes, so the check has nothing to judge.
2. **Title the PR `docs:`.** A documentation pass may rewrite the contract text;
   that is its job. The match is a PREFIX, after leading whitespace, and
   case-insensitive: `Docs: rewrite the state table` passes,
   `feat: docs for the new lane`, `fix(docs): typo` and
   `refactor: docs: rewrite` do not.
3. **Stay inside the Changes region.** Every changed line of a guarded doc sits
   strictly between that doc's `<!-- changes:begin -->` and
   `<!-- changes:end -->` markers. Added lines are judged at their new-side line
   number; removed lines at the number they sat on — so shortening the pointer
   text is fine and deleting a marker is not. Line text that reads like a diff
   header is still body text: removing `-- worker/jobs/schema.sql` arrives as
   `--- worker/jobs/schema.sql` and is judged, because a file header only ever
   appears outside a hunk.

Renaming or deleting a guarded doc never satisfies route 3: those carry no hunk
to judge, so the check reads the `rename from` / `rename to` / `deleted file
mode` headers instead and reports `renamed-away`, `renamed-onto` or `deleted`.
Moving the whole file is the largest change outside the region there is. A
`docs:` title or the escape hatch still lets a real doc reshuffle through.

## Configuration (env)

| var | default | what |
|---|---|---|
| `DOC_MONOLITHS` | the five `docs/*.md` above | the guarded paths |
| `DOC_MONOLITH_DIFF` | — | a file holding a unified diff; set it and no git call is made |
| `PR_TITLE` | — | the pull request title |

The changed-file list is derived FROM the diff (its `diff --git a/X b/X` lines),
not from a second input, so a deletion (`+++ /dev/null`) and a rename are seen
the same way an edit is. One seam, not two: a separate file list could name a
path the diff has no hunks for, and that state is unjudgeable.

**Two honest no-ops, each printed rather than silent:** none of the guarded docs
exist in this checkout (not adopted), or the diff could not be read (not
checked). Each exits 0 saying which — a check that cannot run must never look
like a check that passed. Adoption is read off the CHECKOUT, never off the diff,
for the same reason `verification-map-freshness` does it: reading it off the
changed-file list would make a PR that deletes the docs report "not adopted".

**Two limitations, stated rather than hidden:** the markers are read from the
working tree (in CI, the head commit the diff produced), not from the diff; and
a guarded doc with no markers has an EMPTY region, so every edit to it fails
until someone adds the region. That direction is deliberate — the alternative is
a doc that opts itself out by losing three lines.

## CI step

```yaml
      - name: doc-monolith-edit
        if: github.event_name == 'pull_request'
        env:
          PR_TITLE: ${{ github.event.pull_request.title }}
          PR_LABELS: ${{ join(github.event.pull_request.labels.*.name, ',') }}
          PR_BODY: ${{ github.event.pull_request.body }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          set -uo pipefail
          # The hatch reads ONE line, so hand it ONE line. Wiring the raw body to
          # GUARDRAIL_JUSTIFICATION is the line every drafted check copies, and it
          # makes any body a justification — bin/guardrail-promote.sh refuses a PR
          # that does it and tests/guardrails-test.sh greps this catalog for it.
          JUST=$(printf '%s\n' "$PR_BODY" \
                 | grep -i -m1 '^[[:space:]]*Guardrail-Justification:' || true)
          git diff "$BASE_SHA"...HEAD > "$RUNNER_TEMP/pr.diff"
          GUARDRAIL_JUSTIFICATION="$JUST" DOC_MONOLITH_DIFF="$RUNNER_TEMP/pr.diff" \
            guardrails/doc-monolith-edit/check.sh
```

`actions/checkout` needs `fetch-depth: 0` for the base sha to be present.

**Applicability:** any repo with contract docs that have become a changelog —
the symptom is a doc whose last third is dated paragraphs, or a file that shows
up in every third PR's diff for reasons unrelated to that PR. Adopt it in the
same PR that adds the `<!-- changes:begin -->` / `<!-- changes:end -->` region
to each guarded doc, or the check fails the next PR to touch one.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`). The real case for it here is a revert: restoring a paragraph
someone removed is an edit to the body that no note should have to describe.
