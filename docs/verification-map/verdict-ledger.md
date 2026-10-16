# The verdict ledger (when the judgement is recorded, and what `settled` means)

**What it is:** one `verdict` artifact row per job — the word a review settled
on, the tier a merge lane may act under, the provenance of the lane that
authored it, and the sha the approval is BOUND to. It is the ledger's copy of
"did a reviewer say yes, and to what", and it is what lets a merge decision
happen on a machine that never saw the build record.

BH-858: until this shipped there was ONE write of that row and it sat behind
`[ -n "$PR_URL" ]`, five hundred lines after the review settled. A build whose
`gh pr create` died on the App installation's GraphQL cap wrote
`PR_CREATE_FAILED` and no verdict at all — a reviewer had read the diff and
answered, and the answer was thrown away. Fifteen records fleet-wide in one day.
The judgement is now recorded where it is MADE, and the old write became the
update that settles it.

**How an operator reaches it:** no UI. The row is written by builds and read by
cron lanes; the observable surfaces are the ledger API and the build's own
`pipeline.log`.

## The writes

| where | block | guard | what it writes |
|---|---|---|---|
| `bin/run-build.sh`, right after `STAGE_END tier` | `# >>> verdict at review` | `JOB_ID` + a ledger client. **No `PR_URL` guard** | `tier`, `provenance`, `record`, `reviewed_sha` (omitted when `review-head` is empty), **`settled:false`** |
| `bin/run-build.sh`, phase 7 after the PR is open | `# >>> verdict artifact` | `PR_URL` + `JOB_ID` + a client | the same fields plus `note`, `repairs`, `repair_rounds`, `scope`, `scope_counts`, `kind`, `kind_repro`, `headbound`, and **`settled:true`** |
| `bin/review-rescue.sh` `verdict_backfill` | — | a strandee whose `review.md` ends `VERDICT: APPROVE` — line 1 `PR_CREATE_FAILED`, **or** `PR_CREATED … \| RECONCILED …` over a preserved `RECONCILED_FROM: PR_CREATE_FAILED` | `tier:"2"` ALWAYS, `provenance`, `record`, `reviewed_sha`, `settled:true`, `source:"review-rescue-backfill"` |
| `bin/review-prs.sh`, immediately after the `rp_state_write` that records the verdict | `# >>> review verdict ledger` | **the flag** (`verdict_single_home_on`) + a client. Below the no-verdict `continue`, so an unparsed review is never stamped | `tier`, `provenance` (`claude` when `rp_prov_is_claude`, else the served string), `served_by` (the raw `rp_out_prov` word), `reviewed_sha`, `settled:true`, `source:"review-prs"`, `pr` |

**Both line-1 shapes, and the second one is the common case.**
`bin/pr-url-reconcile.sh` ticks every 10 minutes and `bin/review-rescue.sh` every
30, so a strandee whose PR already exists on its branch has had line 1 rewritten
to `PR_CREATED … | RECONCILED …` long before the backfill first sees it. The
create failure survives one line down as `RECONCILED_FROM:`, and that line is
what the backfill keys on — a build that opened its own PR never carries one. A
backfill that walked only `PR_CREATE_FAILED` would reach none of the records this
mechanism exists for.

The artifact upserts on `(job_id, artifact_kind)`, so the second write REPLACES
the first in place. There is never more than one verdict row per job, and a
second run of any of these changes nothing.

### The third writer: `bin/review-prs.sh` (BH-1024)

Until this shipped, the verdict of an EXTERNAL PR review lived in one place:
`state/<project>.pr-reviews.json`, on the box that ran the tick. `job_verdict`
could not see it, so the merge conductor, the merge sweep and
`bin/review-autopilot.sh` all behaved as if nobody had read the diff — and the
autopilot's own dedupe had to reach into that project's state file to find out
otherwise.

The block writes a row per REVIEW EVENT, not on the lane's `JOB_ID`:
`/api/verdict?pr=` resolves through a `pr_url` artifact and artifacts key on
`(job_id, artifact_kind)`, while this lane reviews many PRs under one row. So
each reviewed head opens a short-lived job of kind **`review-verdict`** (ticket
id `<slug>#<num>`), writes `pr_url` and then `verdict`, and closes itself.
`JOB_ID` is never touched — that row carries the lane's spend.

Both job kinds this lane opens are excluded from `/api/metrics/dora`: the
`review` claim `review_claim` opens per (PR, sha) and the `review-verdict` row
are each minutes old and built nothing, so attributing an external PR's merge to
either would report a one-minute lead time for a week of somebody else's work.

**Which job a PR resolves to, once several of them write `pr_url`.** THREE jobs
can carry one reviewed head's `pr_url`, and a single `bin/review-prs.sh` tick
writes two of them within a second:

| job | kind | verdict it carries |
|---|---|---|
| the build that opened the PR | `build` | its settled verdict, `source: run-build` |
| the review lane claim (`review_claim`, BH-1064) | `review` | the RAW `APPROVE`/`REQUEST_CHANGES`, detail with **no `source`** |
| this block's own row | `review-verdict` | the BLOCK vocabulary, `source: review-prs`, `served_by` |

So `/api/verdict` and `/api/verdict/history` resolve the PR through a RANKING of
those `pr_url` artifacts rather than through the newest one:
**a `build` job first, then a `review-verdict` job, then newest wins.** It is a
tie-break, not a filter — each row is still the answer when it is the only one,
which is the whole point for an external PR.

Newest-wins, or a carve-out naming only `review-verdict`, would hand EVERY
reviewed PR to the lane claim (it is neither a build nor a review-verdict, and
it is newer than the build's row), and that costs in both directions:

- on a harness PR — and `bin/review-prs.sh` skips harness-generated PRs on two
  checks that both fail OPEN into "review it" (a local `builds/*/RESULT` grep,
  which a pool build relayed to the hub may not have on this box, and a
  `gh pr view` whose pipe a 429 or a token error empties) — the sweep's
  `LEDGER_V/PROV/RSHA`, `mc_verdict`, every rebind and the history route would
  answer from the lane row, a disagreeing pair would park the PR through
  `sweep_record … parked` (terminal — `sweep_seen` never re-evaluates it), and
  the build's own settled row would sit there unreachable through the only key
  the fleet uses;
- on an external PR the answering row would carry no `source`, and `source` is
  the one field `job_verdict_covers <pr> <sha> review-prs` filters on — so the
  autopilot skip below would return rc 2 on every call and never fire at all.

The consequence for the autopilot skip is the honest one: on a PR that HAS a
build job, `job_verdict_covers … review-prs` cannot match (the build's row is
what resolves, and it carries no `source: review-prs`), so that lane falls
through to its `.sha` file read and behaves exactly as it does today. The ledger
skip is the answer for the PRs review-prs is actually for — external ones, which
have no build job.

Every failure is ONE log line in `logs/pr-reviews.log` and the tick continues:
a refused `job_open` says `ledger verdict NOT written (job_open …)`, a failed
artifact put says `(artifact put failed, job …)`, and in both cases the JSON
file is the only copy that tick.

## The flag (`verdict_single_home`)

A `settings` row, seeded `0` by `worker/jobs/schema.sql`. `1` makes the ledger
the FIRST reader in three places; `0` is today's behaviour byte for byte, and
flipping it back is the whole rollback.

| lane | with the flag on | with it off |
|---|---|---|
| `bin/review-prs.sh` | writes the verdict row above | writes nothing, logs nothing |
| `bin/review-autopilot.sh` (`# >>> autopilot ledger skip`) | not gated by this flag since BH-3939: the block asks `review_bought <slug> <n> <sha> --except-builder` (`bin/lib/review-bought.sh`, kill switch `REVIEW_DEDUPE=0`) | the same; on a miss the `.sha` read from `state/<p>.pr-reviews.json` decides, as always |
| `mc_ap_consumed` (`bin/lib/mc/classify.sh`, sourced via the `bin/lib/merge-conductor-lib.sh` shim) | an APPROVE already bound to this head means no autopilot read is owed — see the limit below | the `apverdict <key> <head>` line in `attempts.txt` decides |

Resolution order is the gh-budget pattern: `settings('verdict_single_home')`,
then `$VERDICT_SINGLE_HOME`, then the literal `0`. Memoised per process, and an
outage is NEVER cached — it reads the same env fallback a missing row does (`0`
unless a box sets `VERDICT_SINGLE_HOME=1`), and every ledger call under it then
answers rc 1, which every caller treats as "buy the read".

**What `mc_ap_consumed` can and cannot answer.** Its only caller is the
conductor's `HEAD_MOVED` arm, and `mc_classify` reaches `HEAD_MOVED` only when
the verdict IT read was not an APPROVE bound to this head. So on a tick whose
classification and this read see the same row, the ledger arm answers "no" by
construction and the `apverdict` line decides, exactly as before BH-1024. The
ledger arm is the answer where the two DISAGREE — `mc_verdict` fell back to the
record's `reviewed-sha` file because its own ledger read failed, or another lane
(`bin/blocked-resolver.sh`'s re-review, a rebase train's rebind) bound an
approval to this head between that read and this one. It asks for the WORD as
well as the sha: a settled BLOCK bound to this head is NOT "consumed", because
the caller parks a BLOCK for free and a wrongly-skipped park buys a paid
re-review instead.

**The `source` filter on the autopilot skip is deliberate.** Today's skip means
"review-prs covered this head", not "some verdict names this head". A harness
build's own verdict row must not stand that lane down — reading the adversarial
second opinion on harness PRs is the whole reason it exists.

**And the same ranking runs the other way.** If `review-prs.sh` reviews a
harness PR it should have skipped (both halves of that filter fail OPEN — a `gh`
429 is enough) and BLOCKS it, the build's own row outranks the lane's, so every
LEDGER reader still sees the build's verdict and the block does not park the PR.
That block is not lost: GitHub carries the review comment,
`state/<p>.pr-reviews.json` carries the record, the conductor's head-bound review
reads GitHub, and since BH-1024 fix round 5 `/api/verdict/history?pr=` lists it
as a round of its own, attributed to the job that wrote it. What the ledger
refuses is to let it become the STANDING verdict of a build it does not own.

**Next cycle.** The files stay write-through caches for one full cycle with the
flag on. After that the `echo "apverdict …" >> "$MC_ATTEMPTS"` writes and the
`.sha` field in `state/<p>.pr-reviews.json` are deleted, which is the ticket's
end state. Nothing in this slice removes a file write or a fallback read.

## Verdict history

The artifact upserts on `(job_id, artifact_kind)`, so a second review round
overwrote the first in place and "what did round one say, and about which sha"
was unanswerable minutes later. `verdict_history` (BH-1024) is the append-only
record beside it. The STANDING verdict is still the `job_artifacts` row and is
still what a merge acts on — nothing here competes with that.

A row is appended inside the same request as the artifact PUT, and only when the
`(verdict, reviewed_sha, tier, provenance)` tuple differs from the latest row
for that job. So a lane that re-puts the same verdict every tick writes ONE row,
and a rebind onto a new head writes the next one. The PUT response carries
`history_appended: true|false`.

The round is read off the STANDING ROW after the upsert, never off the request.
A PUT with no `detail` KEEPS the old one (`detail=COALESCE(?5, detail)`) — which
is what the operator verb `jobs-client.sh artifact-put verdict APPROVE` sends —
and a round taken from that request would say the approval lost its sha while
the standing row still carried it.

```
GET /api/verdict/history?pr=<url>   ->  {pr, job_id, rounds:[…], truncated, as_of}
                                        oldest first, capped at 200 rounds (`truncated`
                                        says so); 404 = no job recorded this PR
/root/harness/bin/jobs-client.sh verdict-history <pr-url>
   -> TSV per round: verdict, reviewed_sha, tier, provenance, source, created_at, job_id
```

**A D1 overload is a 503, not a 500 (BH-6807).** When the BH-6690 D1 retry
gives up after 5 attempts (BH-6813), `/api/verdict` and `/api/verdict/history` answer
`503 {error:"…overloaded…", retryable:true, d1_attempts:5}` with one warn line
and one Sentry event, and `bin/lib/jobs/req.sh` retries that answer once
(`cd worker/jobs && node --test test/verdict-overload.bh-6807.test.js`).

**`job_id` is the standing owner; the ROUNDS are keyed on the PR.** The top-level
`job_id` is resolved exactly the way `/api/verdict` resolves it — the ranking
above, build job first — so the history answers for the same row a merge gate
acts on. The rounds themselves come from EVERY job that carries this `pr_url`,
because `bin/review-prs.sh` opens a fresh `review-verdict` job per reviewed
(PR, sha): a BLOCK → rebase → APPROVE cycle on one external PR lives on two
jobs, and a job-keyed read answered "one round, APPROVE" about a PR the table
held the BLOCK for. Every round names its own `job_id` and `source`, so a build's
rounds are still tellable from a review lane's — and a harness PR with a stray
review-lane BLOCK shows both, standing verdict unchanged.

**The append is best effort; the standing verdict is not.** `verdict_history` is
in the worker's `CREATED_TABLES`, so it creates itself on the deploy rather than
waiting for a hand-applied `schema.sql` (the fleet's deploy is `wrangler deploy`
and nothing else). If the append fails regardless, the PUT still answers `200`
with `history_appended:false` and a named `history_error`: a 500 on a `verdict`
PUT is a failed `job_verdict_rebind`, an `mc_rebase` rc 5, and a rebased approved
PR parked in `NEEDS_REBASE "rebind-failed"` until a human intervenes.

## Why the early row is provisional

Writing the row at review time cannot make a PR mergeable earlier, and must not
try. After the review settles, QA, E2E, red/VALIDATE, reopen-trust, repairs,
size, scope, kind and the head-bound gate can all still demote the tier, and a QA
fix round can move the head. An early tier-1 APPROVE that the merge readers could
see — plus the `pr_url` row written seconds after the PR opens — would let
`bin/merge-sweep.sh` merge a PR whose QA is still running.

So the early row says `settled:false`, and:

| reader | how it reads a provisional row |
|---|---|
| `job_verdict` (`bin/jobs-client.sh`) | **rc 2** — "the ledger has nothing to say about this one". Every caller already handles rc 2 by scraping its build record, which is byte-identical to the pre-BH-858 path |
| `bin/merge-sweep.sh`, `bin/merge-queue.sh`, `bin/pipeline-health.sh`, `bin/batch-resolve.sh` | through `job_verdict` — the record scrape, exactly as before |
| `mc_job_running` (`bin/lib/mc/classify.sh`) | "no verdict yet", so the double-review guard STAYS ARMED. Without this the conductor would buy a second Fable read of a head the build's own reviewer had just finished with |
| `job_verdict_headbound`, `job_verdict_rebind` | unchanged — a provisional row carries no `headbound` field and makes no claim to rebind |
| `job_verdict_covers` (the autopilot skip, `mc_ap_consumed`) | **not covered.** Same rule, for the same reason: a tier the demoters have not judged cannot stand a paid read down |
| the worker's DORA read on `job_artifacts(kind='verdict').updated_at` | the settle write refreshes `updated_at`, so review→merge lead time is unchanged for builds that reach settle |

**Absent `settled`, absent `.artifacts`, and an unparseable `detail` ALL read as
SETTLED.** That is what makes the change additive: every row already in the
ledger keeps exactly the meaning it had. Only the JSON boolean `false` is
provisional — the string `"false"` is not.

A strandee's row stays provisional until `bin/review-rescue.sh`'s backfill
settles it at tier 2 — whether the record still reads `PR_CREATE_FAILED` or
`bin/pr-url-reconcile.sh` has since relinked it, because the backfill walks both
shapes. Tier 2 always, because the demoters never ran on that build and tier 1
means auto-merge.

## The four rcs you will meet

- `job_verdict <pr-url>` — `0` the ledger holds a settled verdict; `2` nothing to
  say (no row, no verdict, or a provisional one); `1` outage.
- `job_verdict_state <job-id>` — `0` prints `settled` or `provisional`, a TAB and
  the bound sha (`-` when none); `2` the job has no verdict artifact; `1` outage.
- `job_for_record <project> <record>` — `0` prints the job id; `2` the `result`
  feed names no such build dir; `1` outage. Memoised per process, and an outage
  is never cached.
- `job_verdict_covers <pr-url> <sha> [source] [word]` — `0` a SETTLED row whose
  `reviewed_sha` is exactly this sha (and, when asked, whose `source` matches and
  whose verdict IS that word); `2` a real no (no row, no verdict, provisional, a
  different sha, a different source, a different word); `1` outage. Exact string
  equality on the sha: an abbreviated head is not a match, or a head-bound gate
  would quietly widen into a branch-bound one. The word filter is what tells
  "somebody judged this head" from "somebody approved it" — `mc_ap_consumed`
  asks for `APPROVE`, the autopilot skip asks for neither word (its file-based
  predecessor skipped on a reviewed sha whatever the verdict said).
- `job_verdict_history <pr-url>` — TSV of verdict, reviewed_sha, tier,
  provenance, source, created_at, oldest first. `2` when no job recorded the PR.
- `verdict_single_home_on` — `0` when the flag row is on. Never rc-bearing: an
  unreachable worker falls to the documented env fallback (`0` on every box that
  has not set it) and is never cached.
- An outage is NEVER "no verdict". Every lane that writes on the back of these
  reads marks nothing on rc 1 and comes back next tick.

## How to drive it

- `bash tests/verdict-at-review.bh-858-test.sh` — the two `bin/run-build.sh`
  blocks extracted verbatim and run with a stubbed ledger call (§1, §2), the
  three client functions against a stub worker (§3), `mc_job_running` through the
  real `/api/verdict` body shape (§4), and the reproduction end to end: a stubbed
  `gh` that fails every create rung leaves one provisional row bound to the
  reviewed head and a `PR_CREATE_FAILED` RESULT (§5).
- `bash tests/review-rescue.bh-858-test.sh` — the backfill pass: one settled
  tier-2 row per strandee in BOTH line-1 shapes (`PR_CREATE_FAILED` and the
  relinked `PR_CREATED … | RECONCILED …` over a `RECONCILED_FROM:`), the BLOCK
  negative, a quoted-APPROVE review that is not a judgement, a build that opened
  its own PR and is not walked, the alert when no path can produce a verdict, the
  cap, and the outage that marks nothing.
- `bash tests/verdict-single-home.bh-1024-test.sh` — the three new readers
  against a stub worker (§0), the rebind and the sweep's stale-file case as
  regression pins (§1, §2), `bin/review-autopilot.sh` driven as the REAL script
  with the ledger answering first (§3), `bin/review-prs.sh`'s
  `# >>> review verdict ledger` block through the real client (§4),
  `mc_ap_consumed` (§5), and the negative the slice rests on: with the flag off
  nothing makes a request beyond the one settings read (§6).
- `cd worker/jobs && node --test test/verdict-history.bh-1024.test.js` — the
  real `schema.sql` applied into `node:sqlite` behind a D1 shim, so the history
  append, its content dedupe, the oldest-first read and the flag seed are proved
  against the SQL that ships rather than against a regex-routed stub.
- `bash tests/pr-url-reconcile.bh-858-test.sh` — the `pr_url` bind and the
  re-review hand-off (see [pr-url-reconcile.md](pr-url-reconcile.md)).
- The six suites that extract `# >>> verdict artifact` verbatim —
  `tests/head-bound-approval-test.sh`, `tests/headbound-outcome-test.sh`,
  `tests/kind-flow-test.sh`, `tests/plan-gate-test.sh`,
  `tests/repair-rounds-test.sh`, `tests/scope-gate-test.sh` — pin that the settle
  write kept every field it had.

## On a live hub

```
grep 'VERDICT:' /root/harness/builds/<record>/pipeline.log    # provisional, then settled
/root/harness/bin/jobs-client.sh artifact-feed verdict <project> | head
/root/harness/bin/jobs-client.sh verdict <pr-url>             # rc 2 while provisional
grep -c '"settled":false' <(/root/harness/bin/jobs-client.sh artifact-feed verdict <project>)
tail -20 /root/harness/logs/review-rescue.log                 # the backfill's lines
/root/harness/bin/jobs-client.sh setting-get verdict_single_home   # 0 until an operator flips it
/root/harness/bin/jobs-client.sh verdict-history <pr-url>          # every round, oldest first
grep 'recorded in the ledger' /root/harness/logs/pr-reviews.log    # review-prs's own writes
grep '(ledger)' /root/harness/logs/review-autopilot.log            # skips the ledger answered
```

A build that reached the review stage writes, before the PR exists:

```
2026-09-18 12:00:00Z [cromford/BH-858] VERDICT: APPROVE recorded provisionally (tier 1, provenance claude, reviewed sha deadbee) — the judgement is in the ledger before the PR exists
```

**Knobs:** `VERDICT_BACKFILL_MAX` (default 25) bounds the backfill pass per tick;
`JOB_FOR_RECORD_LIMIT` (default 500) bounds the `result` feed page
`job_for_record` reads; `verdict_single_home` is a settings ROW (default `0`,
`VERDICT_SINGLE_HOME` only as the documented fallback). All three documented in
`env-templates/global.env.example`.

**Manual-only / not automatable:** nothing here un-provisions a row or deletes
one — a verdict the fleet should not act on is a policy call (close the PR, or
flip the tier through the normal gates), never a ledger edit. There is no
endpoint for it on purpose.
