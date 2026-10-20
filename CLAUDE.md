# cromford

The fleet build rules live in `rules/CLAUDE.md` — that file is rendered onto every
box as `~/.claude/CLAUDE.md` and is what a build in ANY repo reads. This file adds
only the thing the harness reads from a repo ROOT: the verification contract
below. Nothing here replaces or overrides `rules/CLAUDE.md`.


## Iron law: indexes and retention (BH-6730)

The fleet's iron laws live in `rules/topics/` (rendered to `rules/CLAUDE.md`). This one binds this repo's own D1 tables too (the harness-jobs lesson, #6727: tables of 25k-206k rows read 100-160M rows an hour, one correlated subquery read 1.29M rows per call, and D1 answered "overloaded" 875 times in 5 hours).

- Every new table ships with the indexes its queries need, in the same migration: name the index that serves each WHERE, JOIN, ORDER BY and GROUP BY.
- A test runs `EXPLAIN QUERY PLAN` (SQLite/D1) or `EXPLAIN` (Postgres) on seeded data at realistic volume and asserts the hot queries use an index (no full `SCAN` of a large table). A later index goes in a new additive migration (`CREATE INDEX IF NOT EXISTS`).
- No correlated subquery that re-runs per row over a large table. A poll or dashboard that recomputes an aggregate over all history gets a summary table or a short cache.
- Every growing table has a retention rule: what the rows are for, how long they keep value, and a scheduled job that deletes or archives the rest (window in a settings row, dry-run first, one audit row per run). Money and history rows are archived, never silently deleted.
- Reviews BLOCK on a new per-row correlated subquery over a large table; a missing index or retention rule is a review note that names the fix (BH-7123).

`bin/rules-pack.sh` component `index-on-create-table` refuses a diff that adds a `CREATE TABLE` with no `CREATE INDEX` on that table in the same diff (a handful-of-rows table carries `-- no-index: <table> <reason>`).

## Iron law: scalable tests (BH-7563)

The fleet rule lives in `rules/topics/14-scalable-tests.md` (rendered to `rules/CLAUDE.md`). It binds this repo's own suites too.

SCALABLE TESTS (iron law, BH-7563, 2026-10-19). If a test does not test an external service, the test must not call it. External services are auth (Clerk), mail, payments, LLMs, Composio, and any shared, rate-limited or metered service. The PR and merge-queue path must scale to any number of parallel runs and never stop because of a vendor.
1. One seam (adapter file) per vendor.
2. In test mode, the seam returns a local fake: seeded data, 0 network calls, and a throw on an unimplemented method.
3. Tests sign in through a test-only session route: test flag AND non-production AND a secret. A unit test proves 404 in production.
4. A small real-vendor contract suite (about 5 tests per vendor), 1 worker, runs on main and nightly. A PR runs it only when it changes that vendor's adapter or auth files.
5. Each test seeds its own data with unique ids. No order dependence. Parallel runs on one commit must pass.
6. A budget test asserts 0 vendor calls in the PR suite.
7. A vendor error in the contract suite is a vendor failure (skip with a reason plus an alert), never a code failure.
- PLAN must list, per vendor the code touches: the seam, the fake and the contract test.
- REVIEW tags each of these, when this diff adds it, `[BLOCK scalable-tests]`: a new PR-path test that calls a real vendor; a vendor client imported outside its seam; a test sign-in through the real provider outside the contract suite; a test-only route without the production-404 test; tests that share data or depend on order.

## Verification Contract

The FIRST fenced block is what `bin/batch-resolve.sh` runs once over a union
branch (`verify_cmd` takes its first non-comment line and `verify_union` evals it
in the union worktree). A union only ever changes files this repo declares
generated or union-mergeable — the two env templates, the ten `cron/<box>.cron`
and `catalog/lanes.json` (`.gitattributes`) and the paths in the
`## Generated files` table, which since BH-1175 is read from
`docs/verification-map/index/tail.md` rather than from the generated index it is
copied into. Every member already carries its own head-bound APPROVE and green
CI, and the train PR runs the full CI below in the merge queue before it lands.
So the union check is the source validation, the six render drift checks and
the three suites that pin this lane, not the whole corpus:

```bash
HARNESS_TEST_SANDBOX=1 bin/verification-map-build.sh --check && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check && HARNESS_TEST_SANDBOX=1 bin/render-cron.sh --check && HARNESS_TEST_SANDBOX=1 bin/render-env-example.sh --check && HARNESS_TEST_SANDBOX=1 bin/render-rules.sh --check && HARNESS_TEST_SANDBOX=1 bin/render-doc-sections.sh --check && HARNESS_TEST_SANDBOX=1 bin/schema-build.sh --check && HARNESS_TEST_SANDBOX=1 bash tests/verification-map-build-test.sh && HARNESS_TEST_SANDBOX=1 bash tests/verification-map-no-commit-test.sh && HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train-test.sh
```

`bin/verification-map-build.sh --check` is no longer a drift check.
`docs/verification-map/README.md` is generated and git-ignored (BH-1175: it was
in 105 of the last 200 merges to main and turned main red three times in one day
through its union merge driver), so there is no committed copy to drift from.
`--check` validates what IS committed: every `docs/verification-map/entries/*.md`
parses, no two of them produce the same row, every document link resolves, and
no README is tracked in git.

The other five `--check`s ARE drift checks, and they are in the union command
because BH-1178 put three more union-mergeable files in reach of it: git's union
driver concatenates both sides of a hunk, which for a JSON array or a crontab is
a file nobody wrote. `bin/batch-resolve.sh` regenerates all of them from the
`## Generated files` table BEFORE this command runs, so a green check means the
regenerate worked — and a red one stops a train that would otherwise land a
corrupt `catalog/lanes.json` on every box.

`bin/render-rules.sh --check` is the fourth (BH-1336), and its subject is the
first declared path that is still COMMITTED: `rules/CLAUDE.md`, the render five
box scripts copy verbatim into every `/root/.claude/CLAUDE.md`. A committed
render is the file a train would otherwise hand merge, so the table declares it
and this check is what proves the regenerate over the union actually ran — a
train that landed two siblings' renders glued together would put a file nobody
wrote on every box.

`bin/render-doc-sections.sh --check` is the fifth (BH-5235.2). Its subject is
the second committed declared path, `docs/PR-OWNERSHIP.md`, rendered from the
section files in `docs/PR-OWNERSHIP.d/` so two PRs that each add a section add
two files instead of conflicting on one.

`bin/schema-build.sh --check` is the sixth (BH-4987, BH-6005). It validates
`worker/jobs/schema.d/` and refuses the git-ignored render
`worker/jobs/schema.sql` back in git: schema.sql is not in git, so add or edit a
fragment, and every reader (the deploy, CI, the tests) composes its own.

`HARNESS_TEST_SANDBOX=1` is on each command on purpose: the hub runs this lane as
root next to a live `/root/harness`, and `tests/lib/scratch.sh` refuses to build a
scratch tree there without it. Without the prefix every train would be red on a
guard rather than on the code, which is the same as leaving the lane off.

The full suite is what `.github/workflows/harness-ci.yml` runs — `bash -n` on every
script, shellcheck at error severity, the verification-map generate-and-validate
step, the determinism lint, and every `tests/*.sh` in a loop:

```bash
for t in tests/*.sh tests/mc/*.sh; do bash "$t" || exit 1; done
```

PR lint now runs `bin/fast-lints.sh` (BH-3860), as two steps in the `lint` job
on ordinary PRs only. `fast always-lints` runs `bin/rules-pack.sh`, then
`--run` over the seconds-long always-suites minus the ones the rules pack
already ran, then `--assert-budget` on their timings against
`FAST_LINTS_BUDGET_S`. `share-mirror leakcheck pre-check` runs
`tests/share-publish-clean.bh-795-test.sh` only when the diff adds a file
outside `bin/share/mapping.py`'s text/font sets. Neither changes the
merge-queue batch, which still runs the whole corpus.

## Builder gate (BH-1524)

A build runs the ranked selection for its diff before it pushes, bounded:

```bash
bin/test-impact-gate.sh --base origin/main --table /tmp/gate.md
```

It ranks the selection by why each suite was picked (self > reads > always >
named > source > learned > closure), shortest suite first inside a tier by the wall time
this box last recorded for it. It runs that list until it hits its cap or its
time budget, both settings rows on the `fly-pool` lane
(`test_impact_gate_cap`, default 80; `test_impact_gate_budget_s`, default
450 s, BH-1554). Everything past either bound is named as left to CI. It is NOT every
suite the diff can reach, so check the left-to-CI list for a suite that pins
what you changed. `--table` is the PR body's gate table. The pool's
`HARNESS_SUITE_RUN` runs the same command for this repo. As root beside a live
harness it runs a snapshot of HEAD as `nobody`. A runner that cannot start, or
a stage that times out, is recorded `HARNESS_EXIT: could-not-run`. Use
`bin/test-impact.sh select origin/main..HEAD --why` to see the reasons without
running anything.

`learned` (BH-6459) is a path edge a failed merge-queue batch taught the map
(`catalog/test-impact-learned.d/`) that the suite text does not name. A learned
`*` row stays `always`.

With `--fresh-main on` (or env `TEST_IMPACT_GATE_FRESH_MAIN=1`; default off)
the gate fetches origin's main into a private ref, merges it onto HEAD with
`git merge-tree`, and runs the run list's `always` suites on that merged tree
instead of on HEAD (BH-6459). A whole-repo ratchet can be green on HEAD and on
main and red on their merge. The pool builder turns it on through the
`fly-pool` knob `TEST_IMPACT_GATE_FRESH_MAIN` (default 1). Look for
`impact-gate: fresh main <sha12>: ran X of M whole-repo suite(s) on HEAD merged
with it`, and the `(fresh main <sha8>)` tag in `--table`. If main is already in
HEAD, the merge conflicts, the fetch fails or the runner is `plan` or `remote`,
the gate prints one `impact-gate: fresh-main: off (<why>)` line and runs those
suites on HEAD as before. `--fresh-ref <ref>` uses a local ref and does not
fetch.

On the `local` and `isolated` runners the gate also asks the suite ledger
(`bin/suite-reuse.sh plan --class builder`, BH-5354.1) which selected suites,
fast tier excepted, already passed at the same input fingerprint. It does not
re-run those. It prints `impact-gate: reused <suite> from <run_id> (<d>s)` for
each, then `impact-gate: reused R of N selected suites from the suite ledger
(~Ss not re-run)` after the summary line, tags them `(reused <run_id>)` in
`--table`, and records what it ran. A ledger it cannot reach, no credential or
a dirty tree prints `suite-reuse: off (<why>)`, and then every suite runs. That
is not a failure. `SUITE_REUSE=off` turns it off. CI does not trust builder
greens (BH-5354 I1), so a builder reuse never skips a merge-queue suite.

## Fly test host cert (BH-5210)

Never run `flyctl ssh issue` directly. On 2026-10-05 a hand issue with
`--overwrite`, into an unbounded redirect, looped for 44 hours and wrote 596 GB. Get a test-host cert with `bin/issue-testhost-cert.sh [--key PATH]
[--force]`, which runs the remote gate's bounded issue path
(`docs/REMOTE-GATE.md`, "Issuing a cert by hand").
