# The pre-queue gate runs the whole-repo invariant suites (BH-5438, #5429 child 0)

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-08 five PRs passed the pre-queue gate and then failed whole merge
batches, about 1.5 h of them. `.github/workflows/prequeue-gate.yml` ran only
`bin/test-impact-gate.sh`, and that gate runs the suites a diff can reach on
the impact map. The suites that scan the whole tree (the share-mirror leak
checks, the lanes registry, the deployment inventory, the ratchets) are never on
that map, so a diff anywhere could break one, the pre-queue verdict still said
green, and the merge batch was the first thing to run it.

## What changed

- `catalog/prequeue-invariants.tsv` (new): one row per invariant, five
  TAB-separated columns `id kind argv budget_s guards`. Eleven seed rows:
  share-mirror-clean, share-publish-clean, lanes-registry, config-inventory,
  rules-pack-contract, hold-push-ratchet, gh-graphql-reads-lint,
  pr-trailers-sites, scratch-closure, determinism, triage-state-pr-contract.
- `bin/prequeue-invariants.sh --run --catalog F --out DIR [--overrides STR]`
  (new): runs every row serially from the repo root with
  `HARNESS_TEST_SANDBOX=1` and `RATCHET_BASE=$PQ_MAIN`. Exit 0 green, 1 red,
  2 bad args, bad catalog or empty set, 125 could not run. It writes
  `DIR/timings.tsv`, `suites.txt`, `failed.txt`, `fail/<id>.txt` (first 8
  `^FAIL` lines, else the last 8, token shapes redacted, cut at 300 chars) and
  `log/<id>.log`. A suite over its budget is reported `OVER BUDGET`, never
  killed. A suite missing from the tree is red (`suite missing on the merged
  tree`). A selected suite that looks for gitleaks gets the pinned one
  (`gitleaks_pin_ensure`, `GITLEAKS_REQUIRED=1`); if it cannot be installed
  nothing runs and the exit is 125. `--overrides id=off|<n>` is the seam the DB
  budgets (#5440) will feed; a malformed or unknown item is ignored with one
  stderr line.
- `prequeue-gate.yml`, the `verdict` step: before the merge it reads
  `catalog/prequeue-invariants.tsv` from MAIN (`git show $PQ_MAIN:…`), never
  from the PR, so a PR cannot drop a row to get past it. In plain-gate mode
  (no `suites` input) it runs the invariants inside the stop-commands window,
  then the impact gate with `--skip-suites DIR/suites.txt` so nothing runs
  twice. Without a catalog on main the step is exactly what it was.
- `pq_gate` exports `PQ_PATH`, the cache file it answered from (the sibling's on
  a fresh-sibling red). `pq_dispatch` appends `pq_invariants_args` when no
  suites are named and a sibling defines that function. Nothing defines it yet.

## The verdict

Still one `prequeue-verdict` line, still one of the five words:

| invariants | impact gate | verdict |
|---|---|---|
| rc 1 (a red row) | anything | `red … suites=<invariant paths>,<gate reds> why=invariant:<ids>` |
| not rc 1 | rc 1 with suites | `red`, as before |
| rc 125 or any rc but 0/1/2 | not a red with suites | `could-not-run … why=invariants-rc-<n>` |
| rc 0, rc 2 or none | rc 0 / 1 / 2 / other | as before (`green`, `could-not-run red-without-suites`, `no-selection`, `could-not-run rc-<n>`) |

After the resume token, and only when the invariants ran (rc 0 or 1):
`::notice title=prequeue-invariant-timing::` with the total line, one
`::warning title=prequeue-invariant-slow::` when a row ran over its budget, and
at most 5 `::notice title=prequeue-invariant-fail::<id>: <fail lines>`, with
`%`, CR and LF escaped so suite output cannot forge a second annotation. A
refused catalog on main (rc 2) prints one `prequeue-invariant-catalog` warning
and leaves the verdict to the impact gate.

## The cost, honestly

The set takes minutes, not seconds. Each suite was measured once on the build
box (`HARNESS_TEST_SANDBOX=1 RATCHET_BASE=<main> bash <argv>`), sharing the CPU
with this build's own test runs, and `budget_s` is that time x1.5, rounded up:

| id | measured | budget_s |
|---|---|---|
| share-mirror-clean | 318.4 s | 478 |
| share-publish-clean | 383.0 s | 575 |
| lanes-registry | 136.9 s | 206 |
| config-inventory | 34.0 s | 51 |
| rules-pack-contract | 20.2 s | 31 |
| hold-push-ratchet | 2.0 s | 3 |
| gh-graphql-reads-lint | 8.0 s | 13 |
| pr-trailers-sites | 16.1 s | 25 |
| scratch-closure | 4.0 s | 7 |
| determinism | 17.8 s | 27 |
| triage-state-pr-contract | 8.2 s | 13 |

That is about 950 s on this box. The shipped runner over the real catalog on
this tree (`PQ_MAIN=<main> bin/prequeue-invariants.sh --run --catalog
catalog/prequeue-invariants.tsv --out DIR`) agreed: 11 run, 0 red, `total 948s
wall 948s`, with the pinned gitleaks installed for share-publish-clean. On CI the two share suites are about 115 s and
170 s (the ticket's figures), so the CI run should be well under that, but it
was not measured there. The impact gate's budget (450 s) and checkout plus
merge come on top, against the job's `timeout-minutes: 25`. A run that times
out prints no verdict, and `pq_settle` records that as could-not-run, never
green. At this box's speed the invariants plus a full impact-gate budget come
to about 24 min, right at that limit; the CI figures leave room, but nobody has
measured it there. The timing notice on every run is where the real CI cost
shows up.

## Tests

`tests/prequeue-invariants.bh-5429-test.sh`: C1 (catalog, refusals), C5–C8
(runner on stub suites), C6b (overrides), K1 (no shell), E1 (env), E2 (conductor
hooks), G1 (gitleaks 125), D1–D5 (dry run of the real verdict step against a
scratch origin).

`tests/prequeue-invariants-real.bh-5429-test.sh`: A1–A4 (the real
share-mirror-clean, lanes-registry and config-inventory suites on a scratch copy
of the tree). The A cases run real suites, so the file takes several minutes.
They are a file of their own because the first file sources
`bin/lib/mc-prequeue.sh`, which makes it a suite
`tests/trap-target-safety-test.sh` traces; with the real suites nested inside
it, that guard passed its 900 s cap on every merge batch.
