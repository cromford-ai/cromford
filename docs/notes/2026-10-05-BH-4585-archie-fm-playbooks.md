# BH-4585 (BH-4574.3): Archie's rebase-repair playbook

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC, FLAKY-TESTS

## What changed

Archie's factory-manager lane (`bin/archie-fm.sh`, wave 1 in BH-4583) gets a second
playbook, `rebase-repair`, in `bin/lib/archie-fm-repair.sh`. It turns the
2026-10-04 hand fixes into code:

- `50dc38c3`: `worker/jobs/src/index.js` import and spread lists, both sides appending.
- `b6dfe339`, `9989d35d`: `worker/jobs/schema.sql` tail appends.
- `6f3fcaba`: a `catalog/context-budgets.json` array append that needed a joining `},`
  neither side had.
- `8a32af87`: a stale `docs/config-inventory/deployment.*` render.

**What it acts on.** A conductor park that a merge of main could not get past. That
means `pr-state.tsv` says `BLOCKED_HUMAN` with a reason starting
`conflict-unresolvable` or `rebase-gate-red`, on the PR's current head, and the PR is
based on the project's base. A `stacked child of parent=` park belongs to the restack.
Iron-law, `red-ci-twice`, prequeue-red and review parks are left alone (#4474, the
conductor's own flake re-run and BH-4549 own those). `tests/archie-fm-conflicts.bh-4585-test.sh`
C8 pins that.

**What it does, mode on, on one scratch worktree.** Inside the conductor's PR lock
(`flock -n`), after the `archie_actions` row is claimed:

1. `git merge origin/<base>`.
2. It tries every conflicted path. The conductor's own resolvers run first
   (deleted-but-ignored, per-ticket generated files, `package.json` test scripts,
   `*.md` union). A path in `config/regenerated-paths.conf` takes main's side and is
   rendered again in step 3. It never goes through `mc_resolve_by_regen`, which runs
   the PR's generator as root. A path on the `archie.fm.union_globs` allowlist goes to
   `bin/lib/archie-fm-union.py resolve`:
   - A lines file is accepted only when both sides inserted at the same point and
     neither changed a base line. It then has to pass `node --check`, sqlite under an
     authorizer that denies ATTACH/DETACH/PRAGMA, or `bash -n`.
   - A JSON file keeps both sides' own text, gets a junction comma, and is accepted only
     when it parses to an append-only structural three-way merge.
   - A validator that rejects main's own copy refuses the path.
3. It regenerates drift in place. The commands come from main's Generated-files table
   and the `archie.fm.regen` row, never from the PR's diff. Each one runs as `nobody`
   in a snapshot (`afm_isolated`). Its declared, tracked paths come back as a tar, and
   `archie-fm-union.py untar` refuses the whole tar on a symlink, a `..` or an
   undeclared path. A failing generator is evidence (`regen_failed`), not an outcome.
4. It runs the selected suites. A red made only of `flaky_gate_set` names is run once
   more before it is blamed (`afm_suites_flaky`). Wave 1's restack uses the same call.
5. Green: ONE `hold_push` with the lease on the listed head, and the row closes
   `done` / `repair`.

Anything else means no push. An unresolved path or red suites close the row
`requested` / `fix_round`. Its `evidence.diagnosis` is deterministic text, with no
model involved: per path, the shape, the hunk's lines, the enclosing definition and up
to 20 lines a side. "Could not run" closes the row `deferred`, and wave 1's retry
ladder picks it up from there.

**The resolver reads it.** `bin/blocked-resolver.sh` sources both libs. Before it spends
a fix round on the hub, `br_archie_first` asks `afm_first`:

- No row yet, and the park is younger than `archie.fm.first_s` (1200 s): one log line,
  and the park is offered again next tick with nothing spent.
- A `requested` row: its diagnosis is copied onto the resolver record as
  `archie_diagnosis` / `archie_diagnosis_head`. A hopped round carries a copy of that
  record to the owning box (the `prequeue_reason` precedent). `br_fix_round` appends
  `ARCHIE'S DIAGNOSIS (…)` to the brief, but only when that head is the round's head.
- A `started` or `deferred` row is offered again next tick only while its `updated_at`
  is younger than `max(first_s, ARCHIE_FM_RETRY_S) + first_s` (3000 s by default).
  Archie's retry ladder runs only inside its own tick, so a row it stopped revisiting
  must not hold the park. An older or unreadable `updated_at` is today's round.
- Observe, off, an unreadable route or settings, a `failed` row: today's behaviour. So
  is the archie-fm lane switched off (`ARCHIE_FM_ENABLED=0`, or
  `flags/lane-off-archie-fm` / all-off through `lane_paused`). Nothing would ever
  finish that repair.

The defer is bounded and fail-open. It is never a wait on another process.

**Ledger and knobs.** `worker/jobs/src/routes/archie-actions.js` accepts playbook
`rebase-repair` and actions `repair` / `would_repair`. `summary=1` gains `repaired`.
`worker/jobs/schema.sql` seeds `archie.cap.rebase-repair` (10), `archie.fm.first_s`
(1200), `archie.fm.union_globs` and `archie.fm.regen`. There is no new table. The
digest's `Factory manager:` line gains `N repaired`. The tick line gains
`repaired=<n>` at its end.

## Deliberate choices

- The `archie.fm.regen` seed names `docs/config-inventory/deployment.md` and
  `deployment.json`. Those are the files CI checks
  (`tests/no-hardcoded-deployment.bh-4080-test.sh` R1). It does not name the whole
  directory, because `inventory.json` is unchecked and about 88k lines stale on main.
  Regenerating it would hang an unrelated diff that size on every repaired PR.
  `deployment.json` carries `generated_at_commit`, which in the isolated snapshot is
  a throwaway commit's sha. A regenerated `.json` whose only change is that field is
  put back to the merged tree's copy (`afm_rr_stamp_only`), the same field R1
  ignores, so a repair with no real drift neither commits nor conflicts on it.
- A `verdict-contradiction` park whose head moved since the contradicting verdict
  (#4620) is head-moved: `mc_classify` answers `HEAD_MOVED`, the conductor buys the
  head-bound re-review, and `mc_verdict` lets that re-review's verdict on the sha
  stand over the old contradiction. A contradiction on the current head still parks,
  with both verdicts in the reason (`ledger <V> vs record <V> on <sha>`).
- Regenerated paths (`config/regenerated-paths.conf`, e.g. `docs/notes/INDEX.md`) are
  re-rendered only when they conflicted, which is the conductor's semantic. Rendering
  them on every repair would put every PR's note into the index (D37 says the index is
  a docs pass).
- `worker/jobs/src/lib/core.js` is not on the default allowlist. An insertion-only
  union inside an arbitrary function body is exactly the semantic merge the ticket sends
  to a fix round. An operator can add it through `archie.fm.union_globs`.
- The iron-law shape is not built. #4474 already re-records acceptance when the hit set
  is unchanged (`ilc_covered` / `ilc_record`).

## Operator

- Off: `archie.cap.rebase-repair=0` (the playbook only), `archie.manage[.<project>]=off`
  or `observe` (the whole lane), `archie.fm.first_s=0` (the resolver never waits for
  Archie).
- Probe: `GET /api/archie/actions?day=<today>&playbook=rebase-repair` on the jobs
  worker, and the tick line in `logs/archie-fm.log`.
