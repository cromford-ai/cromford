# Pre-call guard (K3): never pay twice for the same work

Every paid LLM call in the fleet goes through `bin/agent-call.sh`. Before the
first rung runs, `bin/lib/call-guard.sh` asks the harness-jobs worker how many
paid calls this piece of work has already had in the last 24 hours. At the
stage's ceiling the call is refused and nothing is bought.

This is **not a budget**. There is no dollar figure anywhere in it (the operator: no
per-ticket dollar budgets). It counts paid CALLS of one piece of WORK, so a
loop that keeps re-buying an unchanged input stops at K instead of at 52.

## Why

The 2026-09-19 audit (`docs/HARNESS_SPEND_AND_STATE_AUDIT_2026-09-19.html`)
found the same shape in every runaway family: one PR reviewed 52 times on one
head, 460 verdicts on 122 distinct heads, triage shards re-run 60-153 times on
an unchanged ticket, 152 stale re-plans a day. Each loop had a dedup check that
ran before the call. What failed was the store: a plain file on one box, which a
wipe, a truncation or an rsync mid-write turns into "never paid". This guard
keeps its count in D1, at the one place every call already passes through, so a
lane's own file can be lost and the fleet still remembers.

## How it works

1. **Key.** `(project, guard stage, fingerprint)`.
   - The **guard stage** is `AGENT_CALL_GUARD_STAGE` when the caller names its
     family, else the agent-call stage. `bin/triage-shard.sh` says
     `triage-shard`, because stage `triage` is shared with alert-triage, the
     medic and the responder.
   - The **fingerprint** is `AGENT_CALL_FP` when the caller knows the work's
     identity. Otherwise it is `<ticket>:<cwd git HEAD>:p<prompt sha>`, which
     only matches the IDENTICAL prompt on the IDENTICAL checkout. The fallback
     can never fold two pieces of work together: a build's review lenses have
     different prompts, and a fix round's re-review runs on a moved HEAD.
2. **Claim, before the call.** `POST /api/call-guard/claim` counts the key's
   paid calls in the window and, in the same SQL statement, records this one or
   refuses it. Two boxes asking at the same instant cannot both slip under K. No
   lock, no queue.
3. **Refusal.** `agent-call.sh` exits **74**, the "the lane's own gate refused
   it: nothing was called and nothing was billed" code every caller already
   defers on. `$OUT` holds `AGENT_CALL_REFUSED call-guard repeat <stage>
   paid=<n>/<K> fp=<fp>`. A zero-cost `refused:call-guard:repeat` row goes into
   `logs/cost.csv`.
4. **Settle, after the call.** `POST /api/call-guard/settle` records what
   happened. `ok`, `failed` and **`empty`** (the vendor answered with nothing
   and billed for it) count as paid. `unbilled` (no rung ran) frees the slot. A
   claim that never settles (the box died) stays `claimed` and counts: that is
   the conservative way round.
   **A subscription failure that cost nothing is `unbilled` too.** When every
   runner that ran is a subscription lane and every failure the ladder
   classified was the account (quota, credits, no headroom), its credential,
   or a named 429 rate limit, the call settles `unbilled`. Two 429s on a head
   must not use up its slots and freeze it for a day (the project-5 #1621
   shape). Timeouts, vendor errors, real failures and any METERED failure
   still count.

## When the counter cannot be read

| Runner (`bin/billing-mode.sh`) | Counter unreadable (transport failure, timeout, 5xx) |
|---|---|
| `metered`: claude billed per token (an Anthropic API credential and no OAuth one), grok on its API wallet (the grok billing switch set to the API mode), openrouter, fireworks | **Fail closed.** The call is refused rc 74 (`call-guard counter-unreadable`). If the primary is a subscription lane and fails, a metered rung below it is refused too, so a flat-rate failure cannot descend into unguarded cash. |
| `subscription` / `unknown` | **Fail open.** Liveness over money. The call runs unguarded and `logs/call-guard.log` says so. |

**A 404 is not an outage.** A worker that answers `404 unknown endpoint` has no
call-guard route yet: a box synced ahead of the worker deploy. That is
`unconfigured` for EVERY runner: the call runs unguarded, and one warn line a
day says `[call-guard] ROUTE MISSING`. A box with no coordination DB at all (no
`bin/jobs-client.sh`, or `JOBS_URL` empty on purpose) is `unconfigured` too.

## Deploy order: the worker FIRST

1. Deploy `worker/jobs` (`bin/harness-sync.sh` applies the `call_guard` table
   from `schema.sql` before `wrangler deploy`; the route also self-creates it).
2. Probe it: `bin/jobs-client.sh call-guard` must answer `{"rows":[...]}`.
3. Then let the shell side ride fleet propagation.

A box that syncs first reads 404 and runs unguarded (ROUTE MISSING, warn),
never refused. It is timeouts and 5xx on a DEPLOYED route that fail metered
lanes closed.

## The guard's env never reaches the vendor

`AGENT_CALL_FP`, `AGENT_CALL_GUARD_STAGE`, `AGENT_CALL_TICKET` and
`AGENT_CALL_GUARD_FORCE` describe one call to `agent-call.sh`. They are unset
right after the claim, before any runner starts. Otherwise a triage session
that setsid-launches `bin/run-build.sh` would hand the shard's key to plan and
execute, and they would share the shard's slots and be refused.

## Overrides, per piece of work

- `AGENT_CALL_GUARD_FORCE=1` on a hand-run call: recorded as paid even at the
  ceiling (the override is never a free call), `FORCED` in `logs/call-guard.log`.
  **Ignored when `IS_SANDBOX=1`**: an LLM session cannot force its own calls
  through (`FORCE ignored` in the log).
- `bin/jobs-client.sh call-guard-reset <project> <stage> <fp> [reason]`:
  `DELETE /api/call-guard`. The key's paid rows become `reset:<status>` and stop
  counting, and one audit row (`status=reset`, the box, the reason) records it.

## Knobs

Settings rows `lib.call-guard.<env lowercased>` (registry:
`catalog/lanes.d/_lib.call-guard.json`), applied by `agent-call.sh` through
`lib_env_apply call-guard`.

| Knob | Default | Meaning |
|---|---|---|
| `CALL_GUARD` | `1` | Kill switch. `0`, or the file `flags/call-guard-off`, turns it off. |
| `CALL_GUARD_STAGES` | `review triage-shard mc-rereview plan preplan execute fix triage prodqa lead-review` | Enforced guard stages: a list, `all` or `none`. Ten stages are on by default (BH-2305), each with its own K. |
| `CALL_GUARD_MAX_MAP` | `review=2 triage-shard=2 mc-rereview=5 triage=2 plan=3 preplan=2 execute=3 fix=3 prodqa=2 lead-review=2 default=2` | K per stage. `0` turns that stage off. `default=` only applies to a stage `CALL_GUARD_STAGES` names without its own K (`all` does that). |
| `CALL_GUARD_WINDOW_S` | `86400` | Counting window. The worker clamps it to 60 s .. 7 days. |
| `CALL_GUARD_FAIL_CLOSED_METERED` | `1` | Refuse metered calls when the counter is unreadable. |
| `CALL_GUARD_TIMEOUT_S` | `5` | The claim's worker timeout. |

Narrowing the set is a row, not a deploy:
`lib.call-guard.call_guard_stages = "review triage-shard mc-rereview"` turns
the guard off for every stage the row does not name, and a box with the row
keeps it whatever the code default says. Plan, execute and fix carry the
build fingerprint (BH-2413, next table), so an unchanged ticket on an unchanged
main is capped across builds. Plan and size repairs, and a build with no build
fingerprint, use the fallback, whose prompt embeds the build dir, so they are
capped inside one build only. Pre-plan's prompt
is stable per key, so an unchanged stale re-plan is capped at K=2 a day; one
whose prompt changed needs a caller fingerprint (the plan hash) to be caught.

## Callers that name their work

| Caller | Guard stage | Fingerprint |
|---|---|---|
| `bin/review-prs.sh` | `review` | `review-prs:<repo>#<pr>@<head sha>` |
| `bin/review-autopilot.sh` (BH-3939) | `review-head` (K=1) | `review:<repo>#<pr>@<head sha>`, the shared per-head `review_fp` of `bin/lib/review-bought.sh` |
| `mc_rereview` (`bin/lib/mc/rebase.sh`) | `mc-rereview` (K=5) | `mc-rereview:<repo>#<pr>@<head sha>` |
| `bin/triage-shard.sh` | `triage-shard` | `<ticket>:<BH-1015 board-state digest>` (the dispatcher's stamp) |
| `bin/run-build.sh` `CC()` (`bin/lib/rb/plan.sh`, BH-2413) | `plan`, `execute`, `fix` | `<ticket>:th<title+body+thread hash>:m<origin/<base> sha>` for the plan and execute runs; a fix round appends `:<outfile>:t<HEAD tree>`. On a GitHub-issue project the thread is the whole comment thread, paged to 1000 comments (BH-2485); past 1000, or on any unread page, there is no fingerprint and the per-prompt fallback applies. No fingerprint when an input is missing |
| every other caller | its stage | the fallback above |

What a refusal means to each:
- `bin/review-prs.sh` treats rc 74..79 as "nothing was bought": no no-verdict
  strike, no page. The in-flight charge and a spent re-review request
  (`rereq_sha`) are handed back.
- `bin/review-autopilot.sh` already had that arm.
- `mc_rereview` returns its own rc 3 ("deferred by the call-guard"), asked
  BEFORE the lane-failure check: no `MC_RR_LANEFAIL_MAX` spent, no lane-down
  marker, no park. The job file is removed and a later tick asks again.
  `bin/blocked-resolver.sh` logs it and spends no counter. The conductor has its
  own guard stage, `mc-rereview`, with K=5 a day per head (its old per-head
  read cap), so review-prs' K=2 never starves it.
- `bin/triage-shard.sh` treats both `AGENT_CALL_REFUSED call-guard` markers as
  "nothing called": one project-log line, no ALERTS line per shard per tick
  (agent-call's once-a-day warn covers it). A `repeat` refusal KEEPS the stamp
  (this world was bought today; clearing it would re-offer the ticket every
  tick for 24h). A `counter-unreadable` refusal clears it with the re-arm.
- `bin/run-build.sh` execute (`bin/lib/rb/execute.sh`): a refused execute call
  is `BUILD_DEFERRED execute refused by the call-guard: <marker>`, never
  `EXECUTE_EMPTY` (nothing ran, so "no changes produced" would be false).
- `bin/run-build.sh` plan (`bin/lib/rb/plan.sh`): an empty plan was already
  `BUILD_DEFERRED`; a refusal is now named as the call-guard's in the RESULT.
- `bin/postmerge-qa.sh` (`prodqa`): the agent note says the call failed and
  its flows were not covered; the verdict is still the deterministic drive's.
- `bin/lead-review.sh` (`lead-review`, K=2 = the request plus its one retry,
  whose prompt is identical): rc 74..79 leaves the request for the next tick.

### Head-bound review stages (BH-3930)

Two more guard stages are on by default, both at K=1: `review-head` and
`lead-head`. Their fingerprint is the shared per-head one that
`bin/lib/review-bought.sh` builds, so every lane that reviews the same head
counts against the same key:

| Stage | K | Fingerprint (`review_fp` / `lead_fp`) |
|---|---|---|
| `review-head` | 1 | `review:<repo>#<n>@<sha>` |
| `lead-head` | 1 | `lead:<repo>#<n>@<sha>` |

One paid review per head. The paid exceptions are named: a retry that has a
real reason to buy again appends `~<reason>` (`^[a-z0-9]{1,24}$`), which makes
it its own fingerprint and so exactly one more paid call. The reasons are
`~rereq` (a re-review request on the same head), `~stepup` (a step-up to a
stronger review), `~noverdict` (the paid call returned no verdict),
`~unread` / `~unbody<D>` (BH-8081: a later claim of a lead head whose paid
round and its `~noverdict` retry had no readable verdict; one call, no retry,
and a second unreadable answer alerts, see `bin/lib/lead-unread.sh`) and
`~rebuy<epoch>` (the operator set `REVIEW_DEDUPE_REBUY_AFTER` after a prompt or
model change). The builder does not check a reason against that list; it
drops only a suffix outside `^[a-z0-9]{1,24}$`, with one line in
`logs/review-bought.log`, and returns the plain per-head fingerprint.

No lane uses these stages yet. Each one moves onto them in its own ticket by
setting `AGENT_CALL_GUARD_STAGE=review-head|lead-head`. Until it does, `review`,
`mc-rereview` and `lead-review` keep the K in the table above. A box with a
`lib.call-guard.call_guard_stages` or `lib.call-guard.call_guard_max_map` row
does not get the two stages from the code default; the row has to name them.

## Not here: operator-token hardening

`DELETE /api/call-guard`, `force:true` and the `lib.call-guard.*` settings
writes are authorised by `HARNESS_SECRET`, like every other worker route. An
operator-only token for them belongs to the security wave (C3, the
`HARNESS_SECRET` split), not to this change.

## Where to look

- `logs/call-guard.log`: one line per refusal or unguarded run.
- `ALERTS.log`: ONE line per (project, stage) per UTC day,
  `[call-guard] REPEAT CALLS REFUSED` naming the top fingerprints,
  `[call-guard] COUNTER UNREADABLE`, or `[call-guard] ROUTE MISSING`. Both route to the **warn digest**
  (`bin/lib/alert-state.sh` builtin rule), never an immediate page.
- `bin/jobs-client.sh call-guard [project] [stage] [hours]`: paid and refused
  counts per fingerprint from D1. `call-guard-reset` is the per-work reset.

## Verified by

- `worker/jobs/test/call-guard.k3.test.js`: the worker's real SQL on
  node:sqlite. K then refuse, a new head is new work, idempotent claims,
  unbilled frees the slot, empty keeps it, the window, validation, top
  fingerprints, and the table self-creating on an empty D1.
- `tests/agent-call-call-guard.k3-test.sh`: drives the real `agent-call.sh`
  against fake vendors and a fake worker. Covers parity, second call refused,
  a new head allowed, the review default K=2, one warn digest line, empty as
  paid, unbilled, metered fail-closed and subscription fail-open (worker down
  and HTTP 500), no metered descent, the kill switches, guard stages, and the
  real `bin/triage-shard.sh` wiring.
- `tests/review-prs-gh-dedup-test.sh` G18 and
  `tests/review-autopilot-post-retry-test.sh` (the PR+head keys and the
  before-billing arm).
