# 2026-09-19 — BH-1037: agent-call.sh gets a choke point (the prompt ledger)

> **Rebased 2026-09-20.** BH-1037's second half — `AGENT_CALL_RUNNERS` and the
> `mc_rereview` consumer — landed first, as BH-1019 (#1074), while this build
> was in review. Both are now on `main` and this build no longer carries them:
> what ships here is the prompt ledger alone, sitting beside BH-1019's intent.
> The sections below that describe the intent are kept as the record of the
> judgement call, and are marked.

> **Round 2, 2026-09-20.** Three findings from the round-1 review changed the
> product, and all three are about the same thing: a cache in front of a lane is
> only safe where the key describes the question AND the body is the answer.
>
> 1. **An rc-0 claude error envelope is `failed`, not `ok`.** The CLI can wrap a
>    429 as `{"is_error":true,"api_error_status":429,"result":"session limit …"}`
>    and exit 0, so the error TEXT landed in `$OUT` and was recorded as a
>    successful review — while the replay deleted `$OUT.json`, the one file
>    `mc_review_lane_failure` reads to tell a dead lane from a real one. Every
>    re-spawn inside the TTL then parsed the vendor's apology as a review with no
>    verdict: a strike, a park, and `bin/blocked-resolver.sh` closing a finished
>    PR. That is project-5 #1621 with a cache in front of it, which is precisely
>    the shape this ticket exists to stop. `choke_error_envelope` classifies it
>    `failed`, gated on the runner marker so a stale envelope never condemns the
>    answer a later rung gave.
> 2. **The ledger is opt-in per caller, not on box-wide for stage `review`.**
>    "A review's deliverable IS its text" is true of `mc_rereview` and of nothing
>    else on that stage: `bin/run-build.sh`'s review lenses and
>    `bin/review-rescue.sh` run prompts that name a branch and a build dir but no
>    head sha, and their deliverable is the `review.md` file the agentic session
>    writes. A box rolled mid-fix-round and resumed inside the TTL would have
>    replayed the pre-fix BLOCK onto the fixed head, never rewritten `review.md`,
>    and bought a fix round against findings the fix had already answered.
>    `AGENT_CALL_LEDGER` now defaults to `0`; `mc_rereview` exports `=1` beside
>    the `AGENT_CALL_RUNNERS=claude` it already exported.
> 3. **A replay is not "a Claude model answered on this box".** `mc_lane_up`
>    clears the conductor's lane-down marker and re-arms every parked head-bound
>    re-review; a cached body says nothing about the account. It is skipped when
>    `$out.replay` is present, and `$out.replay` joins the sidecars the next
>    attempt clears.
>
> Also: a row whose `runner` the caller's `AGENT_CALL_RUNNERS` excludes is now a
> MISS (serving it would hand back a read the caller's own provenance gate
> rejects, on every re-spawn, for the whole window).

Doc: ACCOUNT-ROUTING, MERGE-CONDUCTOR

## What changed

`bin/agent-call.sh` now reads a prompt ledger before it spends anything.

**1. A prompt ledger, read before the first runner is invoked.** Right after the
prompt sha is computed (it was already computed pre-call — nothing moved), the
script looks up `state/agent-call-ledger/<project>/<stage>/<promptsha>.json`.
Inside the TTL, a row recorded `ok` or `empty` is replayed: the cached body into
`$OUT`, the row's runner/model into `$OUT.runner`/`$OUT.model`, `<outcome>
<row-path>` into `$OUT.replay`, one line into `logs/agent-call-ledger.log`, and
the script exits with the row's rc. No vendor call, no cost row, no provenance
row, no phase row, no account pick, no cooldown stamp. The stale `$OUT.json`,
`.err` and `.events` are removed, because they would describe a run that did not
happen.

On the way out, `choke_record` writes the row: `ok` (rc 0 and a non-whitespace
byte in `$OUT`), `empty` (rc 0 and blank), or `failed` (anything else, including
our own 2/75/76/78/79). Body first, row last. `failed` rows are recorded and
never replayed. A prune runs at most once an hour, mtime-based, bounded to the
ledger directory, at 2× the TTL.

**2. `AGENT_CALL_RUNNERS` — NOT IN THIS BUILD ANY MORE.** It shipped in
BH-1019 (#1074): the parse and `runner_allowed` near the top of
`bin/agent-call.sh`, the restricted-primary refusal beside the runner promotion,
`runner_allowed` on the Grok tier-2, OpenRouter and Fireworks rungs, and
`mc_rereview` passing `AGENT_CALL_RUNNERS="${MC_RR_RUNNERS-claude}"`. The
rebase of this PR dropped its duplicate implementation rather than shadowing
BH-1019's.

## Why

The ledger is about money that has already left the building by the time
anything downstream can have an opinion. The conductor re-spawns the same
head-bound re-review of the same unchanged head whenever a tick finds its job
gone, and every re-spawn bought the read again.

## The judgement call a reviewer should rule on (settled by BH-1019, kept as the record)

`AGENT_CALL_RUNNERS=claude` at `mc_rereview` is narrower than what that caller
actually accepts. `bin/lib/review-provenance.sh` counts **openrouter serving an
`anthropic/claude-*` slug** as a Claude read — that is the whole #1621 fix, and
`tests/review-provenance-test.sh` pins it. So with claude-only set, a 429'd
Claude account now makes the re-review answer rc 2 (lane failure) where it would
previously have bought an accepted Claude-via-OpenRouter read.

The ticket names openrouter explicitly among the lanes not to descend to, so
that is the side taken here. The cost of taking it is bounded: rc 2 is a LANE
failure, which `mc_review_lane_failure` is built to keep off the PR's strike
count — the PR is re-offered on a later tick rather than parked on a verdict
nobody gave. The other reading is one token: `AGENT_CALL_RUNNERS="claude
openrouter"`, which keeps the tier-3 Claude read and still refuses grok and
Fireworks — at the price of also permitting OpenRouter's deepseek floor, since
the knob's granularity is the runner and that floor is the same runner.

## Knobs, defaults, where they go

Every one is documented in `env-templates/global.env.example`; the code constants
are the documented fallback.

| knob | default | note |
|---|---|---|
| `AGENT_CALL_LEDGER` | `1` | `0`, or `flags/agent-call-ledger-off`, disables read AND write |
| `AGENT_CALL_LEDGER_TTL_S` | `1800` | non-numeric falls back to 1800 |
| `AGENT_CALL_LEDGER_STAGES` | `review` | space/comma separated, `*` = all |
| `AGENT_CALL_RUNNERS` | unset | space/comma separated runner list — **BH-1019's**, documented here only because the template groups them |

No new env var needs setting anywhere for this to ship: every default is the
code's.

`AGENT_CALL_LEDGER_STAGES` defaults to `review` alone because these are AGENTIC
sessions — an `execute` replay would return the transcript while performing none
of the edits, and a `triage` replay would skip the comments and launches the
first run made. A review's deliverable IS its text.

## Two existing suites had to opt out

`tests/agent-call-provider-order-test.sh` and
`tests/agent-call-large-prompt-test.sh` both drive the real script on stage
`review` with an IDENTICAL prompt several times inside one scratch tree. With the
ledger on, the second call replays the first and the ladder-order assertions
those suites exist for go red on the cache rather than on the ladder. Both now
pass `AGENT_CALL_LEDGER=0` — their subject is the ladder, not the cache. No
assertion was weakened.

## What is NOT in this change

- Pricing every row at write time (the cost-capture gap) — separate ticket.
- `AGENT_CALL_RUNNERS`, the `mc_rereview` export, and the conductor's
  lane-health epoch / `BLOCKED_HUMAN` re-arm logic — all of that is #1019's, and
  all of it is already on `main`.
- In-flight dedup: two concurrent misses on the same key both spend. the operator,
  2026-09-13 — "we never lock and serialize".

## Where it is verified

`tests/agent-call-choke-guard.bh-1037-test.sh`, plus the
verification-map entry `docs/verification-map/agent-call-ledger.md`.
