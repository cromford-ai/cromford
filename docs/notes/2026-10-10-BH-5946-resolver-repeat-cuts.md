# The blocked resolver profiles its run and cuts repeat reads (BH-5946)

Doc: bin/lib/br/opt/README.md, docs/verification-map/entries/BH-5946.md

## Why

On 2026-10-09 18:44Z..22:26Z the hub's `bin/blocked-resolver.sh` ran 4 times
with `secs=2991..3498`, 600+ candidates and `reason=tick-budget`. The `tick:`
line said how long a run took. It did not say where the time went, how many
GitHub calls the run made or how many of them repeated.

## What one row read before this change

Every candidate row runs `br_one` in a `( … )` subshell, so a shell memo set in
`br_one` dies with the row. The calls one row made before any rung:

| step | call | per row |
|---|---|---|
| discovery `br_conductor_emit` | GET `pulls/<n>` (head branch) | 1 |
| `br_one` (hub only) | `fix_round_get` → D1 `/api/fix-rounds` | 1 |
| `br_use_token` → `gh_repo_use_token` | raw `gh api repos/<slug>` visibility probe (the per-shell cache dies with the row) | 1 |
| keyless rows, `br_derive_ticket_key` | GET `pulls/<n>` twice (branch, title) | 2 |
| `br_one` | `job_ticket_abandoned` → D1 `/api/jobs` | 1 |
| `br_already_merged` | GET `pulls/<n>` (state) | 1 |
| `br_merged_prs_for` | 2 × GET `search/issues` (search API: 30 requests/min) | 2 |
| review-blocked class | GET `pulls/<n>` (live head) + `mc_hv_override` → D1 `/api/verdicts` | 1 + 1 |
| `br_hold_recheck` / `br_rung_hold_gate` → `hold_read` | GET `issues/<n>` + 1-10 comment pages; `br_hold_gate` reads them again | 2-22 |

Measured in the fixture of `tests/blocked-resolver-readmemo.bh-5946-test.sh`
(R1): one keyless `head-not-reapproved` conductor row read `pulls/<n>` 5 times
in one run. At 600+ rows a run makes 1200+ merged-PR searches; at the search
API's 30 requests/min that alone is about 40 minutes. That is the leading
hypothesis for the 55-minute run. The first hub `prof:` lines after deploy
confirm or refute it (`search=` against `secs=`).

Model calls were already deduped before the spend (`adjudications >= 1`,
`review_bought`, the call-guard fingerprint). This change adds no model call
and changes no model-call path.

## What changed

Three optional modules of the BH-1468 seam, listed last in `BR_OPT_MODULES`:

- `bin/lib/br/opt/profile.sh`. One `prof:` line after the `tick:` line:
  `secs discovery prepass order loop rows gh gh_rows search pulls issues raw d1
  llm memo_hits unchanged top=[<p>/<rkey>:<s>s …]`. One TSV row per dispatched
  candidate in `state/blocked-resolver/profile/<UTC stamp>.<pid>.tsv` (columns
  `p rkey src reason rc secs gh_total gh_search gh_pulls gh_issues d1 llm
  memo_hit unchanged`), the newest `BR_PROFILE_KEEP` (24) files kept. It counts
  through the tick's own `TICK_COUNTS` ledger, by wrapping the lane's `gh` and
  `_jobs_req` functions, so a call made before that ledger exists (the lane
  gate at the top of the script, the contested-hold sweep) is not counted.
  `gh_rows=` is the GitHub calls made inside the rows; the rest are discovery's.
  The `tick:` line is unchanged.
- `bin/lib/br/opt/readmemo.sh`. It wraps `gh_rest`. A repeat GET of
  `repos/<slug>/(pulls|issues)/<n>`, `…/issues/<n>/comments[?…]` or
  `search/issues` in the same run is answered from
  `${TMPDIR}/br-read-memo.<pid>/` when the entry is younger than
  `BR_READMEMO_MAX_AGE_S` (300). Only rc 0 answers are stored. A read with `-H`,
  a `GH_ETAG=0` read, `/files`, `/reviews`, `/commits` and `compare` stay live.
  A write to a PR drops its entries. At the dispatch line `br_one` drops the
  PR's entries and every search and sets `BR_READMEMO_LIVE=0`, so every read a
  rung makes is live. `br_close_pr` drops the PR after a close. `br_pr_ref`
  reads through the memo first and keeps its raw two-try read and its
  `BR_PR_REF_ERR` text for any read the memo path cannot make.
- `bin/lib/br/opt/unchanged.sh`. At a quiet exit `br_one` calls
  `br_quiet <class>` and the module writes `$ST/<p>/.looks/<rkey>`
  (`fp<TAB>class<TAB>epoch`). The next run asks `br_opt_unchanged_skip` at the
  top of `br_one`, before the repo token and every read. It returns 3 at once
  when the line exists, the class is on `BR_UNCHANGED_CLASSES`, the look is
  younger than `BR_UNCHANGED_RECHECK_S` (1800) and a fresh fingerprint is equal.

## The fingerprint (local files only)

- reason, source, PR url, ticket key, build record path;
- the whole state json `$ST/<p>/<cap-key>.json` as `jq -S -c .`;
- for a PR url: the conductor's `pr-state.tsv` line (key, state, since, head,
  reviewed sha, alerted, reason, url) and the mtime of its hand-off file; with
  no conductor line, the PR's `headRefOid` from `br_open_prs`;
- the newest mtime among the build record's top-level files;
- the mtimes of `state/build-queue/<p>/<key>.json` and `<key>.failed.json`.

A changed head, verdict (reviewed sha), park reason or record re-arms the row
on the next run (`tests/blocked-resolver-unchanged.bh-5946-test.sh` U2-U5).

## The allowlist, and what is never marked

Marked (the default `BR_UNCHANGED_CLASSES`): `held` (hold read rc 1, not an
ABANDON), `escalated`, `stalled` (same stall fingerprint), `job-abandoned`,
`hv-stands`, `rung-hold`, `needs-human` (rc 3), `ci-parked` (rc 3). Each of
these quiet looks writes nothing to the state json, so the fingerprint stays
equal (U9 pins it for the first four).

Never marked, because each one waits on a state the fingerprint does not see or
is transient: a fix round queued or claimed, a fix-round queue that is not
readable, merged-state UNVERIFIABLE, an unreadable hold (rc 2), a held key lock,
the `TICK_DONE` dedupe, the rebuild cap, `BR_REBUILD_WAITING`,
`BR_XPR_PARKED`, every `external-*` row, a contested loser, a stale-replan row
and every rc 0 path. Any row that reaches the dispatch line loses its ledger
line (`br_opt_unchanged_forget`). Lines older than twice
`BR_UNCHANGED_RECHECK_S` are pruned once per `BR_UNCHANGED_RECHECK_S` per
project, so a row no source offers any more leaves no file behind.

The TTL is the bound on what the fingerprint cannot see: a RESUME comment on a
held issue, a person's answer on a needs-human hold, a newer job row for an
abandoned ticket. Each is seen at most `BR_UNCHANGED_RECHECK_S` late. Today's
pass is about 55 minutes, so the default 1800 s does not make that worse.

## Not in this change

- Discovery cost: `br_conductor_emit`'s one head-branch read per conductor row,
  and the review source's reads per open PR.
- The per-row repo visibility probe (`gh_repo_use_token`'s cache is per shell).
  A row the unchanged skip answers makes no probe; every other row still does.
- An incremental merged-PR index in place of the per-row search.
- #5913 (one run per project).

If the hub's `prof:` lines show one of these dominates, it gets its own ticket
with those numbers.

## Measuring on the hub (owed after deploy)

Before (the gh-calls files keep 180 minutes):

```bash
awk '$2=="blocked-resolver.sh"' /root/harness/logs/gh-calls/*.log | wc -l
grep ' tick: ' /root/harness/logs/blocked-resolver.log | tail -4
```

After:

```bash
grep ' prof: ' /root/harness/logs/blocked-resolver.log | tail -4
ls -t /root/harness/state/blocked-resolver/profile | head -3
```
