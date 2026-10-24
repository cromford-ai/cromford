# docs/notes/INDEX.md is a git-ignored render; `--check` validates the notes (BH-8254)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

- `docs/notes/INDEX.md` is not in git any more. `.gitignore` covers it, in the
  shape of the BH-1175 block for `docs/verification-map/README.md`.
- Every reader renders its own copy with `bin/render-doc-index.sh`:
  - `bin/docs-sync.sh` renders it into the harness checkout on every box sync
    (about 4 s, niced, no key stamp). A failed render writes one line to
    `logs/update-runners.log`, and the sync continues.
  - `bin/publish-share.sh` renders it into the mirror source. A failed render
    prints a WARNING, and the publish continues.
  - CI runs `bin/render-doc-index.sh --check` in the lint job (step "notes index
    sources validate (BH-8254)"), from `config/harness-ci/120-lint/000-job.yml`.
- `bin/render-doc-index.sh --check` validates the SOURCES. It is not a byte
  comparison any more. It fails (rc 1) when:
  - a note's first `Doc:` line outside a fence names no doc (`Doc:`, `Doc: , ,`);
  - two notes render the same row (same tag, date and title);
  - two renders differ (the render is not deterministic);
  - `docs/notes/INDEX.md` is tracked in git (fix: `git rm --cached`).
  It is rc 2 when it cannot run (no notes dir, no writable `$TMPDIR`). A note
  with no `Doc:` line is still valid and lands under `untagged`.
- The old byte comparison is `bin/render-doc-index.sh --check-committed`, with
  the same rc contract as before.
- `docs/notes/INDEX.md` left `config/regenerated-paths.conf` and
  `MC_REGENERATED_PATHS_DEFAULT` in `bin/lib/mc/rebase.sh`. No branch based on
  the new main commits it, so the conductor has nothing to regenerate.

## Why

Every PR that added a note made the committed copy stale. PR #7181 (BH-7140)
put the byte `--check` into CI and could not land: Mergify draft #8239 dequeued
it, because #8060 merged first with one new note.

## Operator notes

- A PR never commits `docs/notes/INDEX.md`. To read the index on a laptop, run
  `bin/render-doc-index.sh`.
- An open PR that still changes `docs/notes/INDEX.md` gets a modify/delete
  conflict on its next rebase. The conductor treats it as a real conflict, as
  before. The fix is `git rm --cached docs/notes/INDEX.md` on that branch.
- The contract docs link `[docs/notes/](notes/INDEX.md)`. The link resolves on
  every box and on the share mirror, which render the file. On github.com it
  does not resolve.
