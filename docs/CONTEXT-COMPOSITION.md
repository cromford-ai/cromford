# Context Composition Contract

Every LLM lane in this harness composes its context deliberately. None accumulates it.

This document is the contract. `catalog/context-budgets.json` is the manifest that
makes it enforceable, and `tests/context-budget-manifest-test.sh` is what stops a
lane shipping without a row in it.

The manifest is composed, not committed (BH-6487). Its sources are in
`catalog/context-budgets.d/`: `_head.json` and `_tail.json` hold the top-level
keys, and each `NNNN-<lane>.json` is a JSON array of lane objects. A new lane is
a new file, NNNN = its ticket number. `bin/context-budgets-build.sh` composes
them into `catalog/context-budgets.json`, and `--check` names a bad fragment.

It argues from measurements taken on 2026-08-24, not from taste. Where a rule cites
a number, that number came off the hub.

---

## The evidence this is built on

One day of measurement across the fleet, in the order it was found:

| finding | measurement |
|---|---|
| Orchestrator sessions grew without bound | one session: 5,070 api calls, 27MB on disk, 2,436 tool results totalling 4.3MB, individual results 171–216KB, peak `cache_read` **999,307 tokens** — about $666/day |
| The composed briefing was never the problem | first `cache_write` per turn: **21,912 tokens**. STATE.md + CLAUDE.md files + rendered history ≈ 66KB. Fine. |
| Turn count was never the problem | 53 turns in a day. Real conversations. A wake-gate would have saved nothing. |
| grok project-triage ran hot | 267 calls, **482K mean** input, p95 1.7M, max 3.7M, 62% over xAI's 200K cliff |
| …but its assembled prompt is tiny | largest SOP 17,219 bytes; queue `head -40`; dirs `head -20`. **Under ~25K tokens all in** — 25–150x too small to explain the mean |
| A healthy lane exists, and it is not special | **alerts-medic: 30K mean**, comparable judgement, 6% of the context |
| The account overage nobody could see | **$18,863** in one weekly window, reported by the rollup as **$4.33** |

Two conclusions follow, and every rule below is one of them applied:

1. **The bytes come from the agent's own reads, not from what we hand it.** Tool
   results enter the context and then ride every remaining call of the turn. A cap
   on the composed prompt cannot touch them.
2. **medic proves the target is reachable.** 482K is not what triage costs; it is
   what triage costs when nobody decided what it should read.

---

## Rule 1 — State the job, then size the context to the job

Every lane's manifest row opens with a one-sentence job: the decision or output it
produces. The budget follows from that job, not from what data happens to be
reachable.

The test is medic. It makes comparable judgements to project-triage at 6% of the
context, because it fetches only what it names. Any lane far above its declared
target is not "a big job" until someone has said why it is bigger than medic's.

A lane whose job cannot be stated in one sentence does not have a budget problem.
It has a scope problem, and the budget will not be fixable until the scope is.

## Rule 2 — Declare a budget, or the lane does not ship

Two numbers per lane in `catalog/context-budgets.json`:

- **target** — what it should cost on a normal call.
- **ceiling** — where a bound trips.

**No row means review-blocking.** Not because the number will be right first time —
several were guesses on 2026-08-24 and will move — but because an undeclared lane
cannot be over budget. That is exactly how the $18,863 accumulated: not a wrong
number, an unwatched one.

Ceilings are chosen against real economics, not roundness. Board lanes sit under
**180K** because xAI bills the entire request at double rate past 200K prompt
tokens: staying under the cliff halves the rate *and* the trim cuts the tokens, so
it is a step function rather than a slope.

## Rule 3 — Itemize the composition, and keep the delta whole

Every row lists its components, each with a purpose, a cap and a source. Four kinds:

1. **Identity / SOP** — static, small, versioned in the repo. The decision table,
   the reply style, the allow-list.
2. **Curated working state** — already digested. `STATE.md` is the reference
   pattern: the turn maintains it, so the next turn reads a summary rather than a
   history.
3. **The scoped delta — WHOLE, always.** The changed-ticket set from a fingerprint
   diff, the diff under review, the beats being judged, the message being answered.
   **This is never trimmed.** A truncated delta is the one failure that produces a
   confident wrong answer rather than an expensive right one.
4. **Reference reads — capped.** Logs by `tail -c`, threads by last-N, everything
   jq-trimmed at fetch.

The asymmetry in 3 and 4 is the whole design. Trim what the lane *consults*; never
trim what it is *deciding about*.

## Rule 4 — Curate rather than accumulate

Rolling data gets a curator that produces a capped digest. The model reads the
digest; it never reads the raw rolling file.

`orc-context.sh render` is the reference: `conversation-log.md` is ~400KB and grows,
its render is ~20KB and does not. `STATE.md` is the same idea one step further — the
turn writes the summary, so nothing downstream has to re-derive it.

A lane that reads a growing file directly has a cost that grows with the file, which
means its budget is a countdown rather than a number.

## Rule 5 — Trim deterministically, before the model sees the bytes

Prompt instructions are layer two and never sufficient alone. The first layer is a
fetch recipe that cannot return the bytes in the first place.

`bin/board-fetch.sh` is the reference: first comment + last N + every decision field,
jq-trimmed at fetch. Measured on a realistic 21-comment ticket: **11,553 → 1,197
bytes**, with the original ask and the client's answer both intact.

Two properties are not optional:

- **Declare the gap.** A trimmed thread carries `{_omitted: N}` and a note saying how
  to re-fetch. The standing rule is "read the whole thread before deciding", and it
  exists because of an early engagement — a ticket that looked obvious, a triage
  question the client never answered, a build on an unconfirmed mechanism. **A
  declared gap the agent can act on and a silent one are different things**, and
  saving money by reintroducing that incident is not a trade anyone agreed to.
- **Fail open.** An unrecognised response shape passes through whole. An unknown
  shape must cost tokens, never lose a client's answer: the expensive failure is
  recoverable and the silent one is not.

## Rule 6 — Growth bounds are backstops, not the design

These catch regressions. They are not how a lane gets to its target:

| bound | where | catches |
|---|---|---|
| fresh-by-default | `orchestrate.sh` | sessions that would otherwise never rotate |
| session ceiling | `session-size.sh` + breaker | a session that outgrew its briefing |
| `--max-budget-usd` | claude lanes | a turn that runs away in dollars |
| `--max-turns` | grok lanes | a tool loop that will not stop |
| `prompt_guard` | `agent-call.sh` | an assembly that drifted over the cliff |

**A flag whose absence costs money is backwards.** Fresh-context turns used to
require a flag to be *present*, with "rm the flag to fall back" written next to it —
so $666/day was one deleted file away, and an absent flag on a rebuilt box silently
restored it. The safe path has to be what you get when nobody remembers anything.

**Ship the unverified thing with the instrument that will convict it.** Neither
`--max-budget-usd` under subscription OAuth nor grok's `--max-turns` semantics could
be verified from a laptop. Both shipped anyway — each paired with a check that
reports its own inertness on real traffic. An unenforced cap is worse than a known
absent one, because it stops people looking.

**Both of those instruments returned a conviction, so the bound moved in-house
(`context_kill_tokens`, BH-653).** Every bound in the table above that a VENDOR
enforces was measured not to fire: a $4.67 turn completed against a $2.00 cap, and
three grok sessions ran 32/38/56 tool calls against `--max-turns 25`. Both are
recorded INERT in the manifest with their evidence. The replacement is the one
bound the harness enforces itself:

- **The number** is `context_kill_tokens` on a lane in `catalog/context-budgets.json`
  — same unit as every other number in this file (cumulative `input_toks + cache_read`
  over the session, de-duplicated per API response), resolved with the same
  specificity ladder as the ceiling and the dollar budget. **A lane without the key
  is unbounded, exactly as every lane was before it existed** — this is a per-lane
  opt-in, not a fleet default, and today only `alert-triage` (2,000,000) and
  `responder` (6,000,000) carry it.
- **The mechanism** is `bin/agent-call.sh`'s `context_meter`: a sidecar that polls the
  running session's own transcript through `bin/transcript-cost.sh` every
  `CONTEXT_KILL_POLL_S` seconds (default 15) and sends TERM to the CLI when the sum
  crosses the ceiling. A failed read never kills — fail-open toward the work — and
  says so once in `logs/claude-cost.log`.
- **The evidence a kill happened** is threefold and deliberately not the rc alone:
  `$OUT` ends with a `CONTEXT KILL:` truncation marker (so a session we cut in half
  can never be read as a finished one — that is the point of the whole feature), the
  rc is forced nonzero even if the CLI answered anyway, and exactly one lane alert
  names the lane, the ceiling and the API call count at the kill.
- **The stop is policy**, on the same footing as a budget stop: no model escalation,
  no same-lane retry, no grok/OpenRouter/Fireworks. A failover would re-buy, uncached,
  precisely the context the ceiling just refused.
- **Knobs:** `CONTEXT_KILL_TOKENS` (operator override of the manifest number),
  `CONTEXT_KILL_POLL_S`, and the kill switch — `flags/context-kill-off` or
  `CONTEXT_KILL=0`, either of which restores the previous foreground invocation
  verbatim. Per the rule above, the safe path is what you get when nobody remembers
  anything: no key, no kill.
- **A ceiling it cannot enforce is not allowed to look enforced.** The meter reads the
  session's transcript by id, so a box with `COST_TRANSCRIPT_ROWS=0` (or
  `flags/transcript-cost-off`), or without an executable `bin/transcript-cost.sh`,
  mints no id and runs the lane UNBOUNDED. The first such call of the day writes one
  `CONTEXT KILL UNENFORCEABLE` line naming the lane, the ceiling and the reason. The
  whole complaint above is about bounds that read as enforcement and are not; this
  one had to be built so it cannot become one.
- **The unit is the SESSION, not the attempt.** A `--resume`d attempt inherits the whole
  prior session's reads, so its kill total can exceed what that attempt bought on its
  own. That is correct: one session is one context.

## Rule 7 — Placement is a composition decision

> The hub coordinates; boxes work. Any lane making an LLM call ABOUT a specific
> project runs on that project's box — its account, its context, its ledger. Hub
> LLM lanes are only the inherently fleet-scoped: orchestrator chat, true
> cross-project digests.
> — the operator, 2026-08-24

This belongs in a context document rather than an ops one. A lane on the wrong
box has **the wrong account, the wrong local state and the wrong ledger** — three
kinds of wrong context before anyone counts a token. Rules 1–6 size what a lane
reads; this one decides where reading happens, and it changes who pays and what
is visible.

**One owner per project, and two owners is worse than either.** Measured
2026-08-24: project-1 was triaged by the hub *and* by `10.0.0.1`
simultaneously, ~$328/7d against ~$185/7d. The duplicated spend was the smaller
half. Two agents on one board is a **race** — both fetch the same changed
tickets, both decide, both comment, both move — and because neither knows the
other exists, **nothing errors**. The symptom reaches the client before it
reaches a log.

So placement is asserted, not assumed: one owner per project, both directions,
by the set-equality pattern that already guards the watchdog boxes and the
per-box overage meters. A lane that moves off the hub and onto no box is worse
than one that never moved — it stops running silently, and the symptom is
absence.

**What placement costs, stated because it is not free:** moving a lane to a
project box moves its spend from the hub's account to that project's. Truer
attribution — and a larger bill on an account that may have just had extra usage
enabled, on a box that **cannot poll its own vendor meter** (the boxes' tokens
lack the `user:profile` scope). Migration is therefore blocked on account-side
spend caps existing, not merely sequenced after them.

## Rule 8 — Invisible is not absent

**A lane with no recorded tokens is unmeasured, never free. Prove capture before
trusting a low mean.**

Three lanes looked cheap this wave for the same reason, and none of them were:

| lane | looked like | actually |
|---|---|---|
| codex | no tokens, weightless | busiest runner in the fleet; blank until #72 |
| fireworks / openrouter | no tokens, $0 | real metered cash; blank until #60 |
| alerts-medic (grok) | 30K mean, the counterexample | 32 calls with `rc=0`, 126–1794s durations and **zero captured tokens** — real work the parser never found (all 32 dated 2026-08-19/20; repaired) |

The first two were caught by a bill. The third was caught by asking why a lane
that did minutes of work reported nothing, which is the cheaper question.

**Date a defect before you carry it forward.** Those 32 medic rows all fall
between `2026-08-19T12:56Z` and `2026-08-20T16:24Z`, inside the window the
nested-usage path fix closed on 2026-08-20; grok capture has run 42/42, 33/33
and 15/15 on the days since, and medic has not touched grok at all in that time.
The finding was real and the fix was real, but it was quoted in the present
tense for five days after it stopped being true — the same error as the project-1
double-triage. **A defect with no last-seen date reads as current forever**, and
a wave that ends by fixing things that are already fixed is not being careful,
it is being slow.

This is the token-side twin of the billing rule that **unmeasured is not zero**.
Both say the same thing about different columns: *a blank field is a statement
about our instruments, not about the world.*

**The manifest consequence is direct.** A `measured_before` is trustworthy only
if that lane's capture is PROVEN. Otherwise the number is a **floor**, and a
floor presented as a measurement is how a benchmark becomes wrong in the
flattering direction. medic anchors this entire contract — "comparable judgement
at 6% of the context" — so its number gets fixed before it gets quoted again:
repair the capture, re-measure, *then* set the anchor. Done, 2026-08-25: medic's
post-repair figure is **2.20M mean per call against a declared ceiling of 80K**
— 27.5x — and every other measured lane in the manifest runs 3.1x–33x over its
own.

Measuring it also caught a third way to be invisible. Medic's lane was pinned to
`runner: claude`, and in the last 24h medic ran **14 calls entirely on
fireworks** (4.37M mean, 12.27M p95) while `claude/triage/medic` ran **zero**.
Read through the pin, the anchor lane looked like 570K; read as a workload, it
is 2.20M. **A pin that names the executor cannot describe a workload that fails
over** — the counterexample the whole contract argues against was measuring the
half of itself that had gone quiet.

**Two claims, two kinds of evidence — never quote them as one.**

| claim | what proves it | status |
|---|---|---|
| *both resolvers agree which lane a row belongs to* | the cross-check test driving the Python `ceiling_for` and the jq port over one fixture (#90) | **proven**, and it goes red when either side drifts |
| *that lane's ceiling is the right number* | a real measurement in the combined unit, compared against the declared ceiling | **not proven for any lane** — the ceilings are policy numbers, and the first comparison (2026-08-25) says every measured one is wrong |

The moment those are said together as "the budgets are verified," the manifest
makes a claim nobody checked. Agreement is a property of the *resolver*;
correctness is a property of the *number*. A perfectly consistent pair of
resolvers routing every row to a ceiling that is 33x too small is exactly what
this repo has today, and it is also what it would have if both were right — the
two states are indistinguishable from inside the code, which is why only a
measurement can tell them apart.

**And a measurement is evidence, not a target.** The answer to "medic measured
570K against an 80K ceiling" is not to write 570K into the ceiling. That
converts a finding into policy and blesses whatever the lane happens to do
today. Record the observation next to the ceiling, let the gap be loud, and make
the ceiling a decision someone takes on purpose.

**Matching a row to its lane.** A lane may leave `runner` or `project` unpinned,
meaning "any", and the most specific match wins — with **project weighted above
runner**, because project identifies the *workload* while runner only names the
*executor*. A workload keeps its budget when the failover fires.

Weighting them equally is not neutral: it makes a runner-only lane and a
project-only lane tie, and a tie resolves to the strictest ceiling, so a strict
lane silently governs a workload it does not describe. **Equal weights are a
tie-break nobody designed — a default that looks like a decision**, which is the
same family as an empty collection standing in for a stated negative.

**No lane pins a runner any more, and that is a claim about the code, not the
week's rows.** The failover ladder in `agent-call.sh` is stage-agnostic — tier-3
openrouter, tier-3b fireworks and tier-4 grok fire on `rc!=0` for *any* stage —
and the orchestrator carries `ORC_SURVIVAL="codex grok"`. So every lane in this
manifest is reachable by every runner, and a pin was never a fact about the
lane; it was a guess about which rung would answer. Three of those guesses were
false when anyone finally checked: build-execute pinned to codex while claude
ran it 132/134, alert-triage pinned to claude while grok ran 94/125, medic
pinned to claude while fireworks ran 14/14.

A week of rows cannot establish the opposite, either. medic looked
single-runner for its whole life until the day it wasn't, and "no other runner
appeared in the last 7 days" is absence of evidence in a system whose failover
is designed to be invisible. **The ladder is the proof; the ledger is only the
symptom.**

Three consequences, all now enforced rather than described:

1. **When a lane's runner changes, everything keyed to the old runner is
   stale — bounds first.** build-execute's bounds read "none — codex exposes no
   cap flag" while the lane ran on claude, *denying* two bounds it had carried
   since #88 (`prompt_guard`, `--max-budget-usd $13.12`). That is the mirror of
   declaring a bound that was never wired: same distance from the truth, other
   direction, and it reads as diligence either way.
2. **A fact about the executor gets a per-runner number, not the job's.** xAI
   bills the whole request double past 200K prompt tokens; that is not a
   property of "implement the plan and open a PR". Lanes over the cliff declare
   `runner_ceilings: {"grok": 200000}`, honoured by **both** resolvers and
   cross-checked — because a per-runner cap only one side honours would judge
   the lane at 200K and fund it at 400K, which is the exact fault the
   cross-check exists to catch, arriving through the feature meant to prevent
   it.

   **And it is labelled for the unit it is actually in.** 200,000 is a
   *per-request* prompt threshold; the resolver compares it against this
   manifest's *cumulative* per-call context. A 25-turn grok session averaging
   60K per request reads 1.5M and breaches the bound with **zero** requests over
   the cliff. The cap still binds in the safe direction — a session containing a
   real crossing always exceeds it — so it is a **conservative** bound, and a
   breach means *over the conservative bound*, never *a confirmed doubled bill*.
   `over_200k_share` carries the same caveat for the same reason.

   **A bound and the thing it protects against must be in the same unit, or the
   guard is a coincidence that happens to hold.** This is Rule 8's lesson —
   *a number in the wrong unit is not a measurement* — arriving at a BOUND for
   the first time, and the deliverable is the label: the fleet captures
   per-request prompt tokens from no runner, so there is nothing to recompute
   until someone instruments it.
3. **A stage with no lane is declared debt, not silence — and this debt is now
   paid.** Seven stages ran in production with no row here (`mockup` and `prd`,
   `signals`, `synth`, `probe`, `map`, plus the operator-invoked `takeover`), so
   `ceiling_for` returned `None` for every one of their rows. They were listed
   in `_unbudgeted_stages` with counts so the hole stayed reviewable rather than
   exempted. On 2026-08-27 each got its own lane and `stages` is now empty — an
   emptiness the completeness check re-tests on every run, not a claim anyone
   has to remember. The sharpest of them was `product-ideation`, whose notes say
   it "covers the ideate/prd/mockup/signals/synth stage family" while its `stage`
   field holds one value and the resolver matches exactly — the runner-pin fault
   one field over, a row that says one thing in prose and another in its key.
   The fix was four sibling lanes carrying product-ideation's own numbers, not a
   looser resolver: the key is what binds.

   One-shot runs also need rows after they finish: the hub completeness check
   reads the historical cost ledger, so a done marker does not remove a lane.
   The `misc/project-2-migration` confirmation and `cost_rows_db/cromford` build
   now have project-specific, runner-agnostic rows and committed fixture keys.
   Their ceilings use the existing triage and build-execute budgets; the single
   observed call for each remains recorded as over budget, rather than raising
   the ceilings to fit past usage. `cost_rows_db` uses the build funding floor;
   unrelated `misc` projects still need their own declaration.

And the property that ties them together, now asserted in CI against a
committed snapshot of the fleet's real `(runner, stage, project)` keys:
**a runner must never be the reason a lane is unbudgeted.** That check already
existed — and only ran on the hub, where nobody runs the suite, so it had never
once spoken. A guard whose only execution path is a machine no one executes it
on is this document's own subject wearing a test's clothes.

## Rule 9 — Measurement is part of the lane

`runner_input_stats_7d` in `summary.json` carries calls, mean, p95 and max per
**(runner, stage, project)** — not per runner. Runner alone collides: medic and
alert-triage are both claude/triage with very different jobs, and a runner-keyed
join judges every claude lane against the strictest ceiling any claude lane
declares, reporting a build lane legitimately at 400K as a breach.

**The unit is `input_toks + cache_read`**, because for a claude lane the context
lives in `cache_read` and `input_toks` reads ~57 fleet-wide — a join on
`input_toks` alone compares 57 against an 80,000 ceiling and can never fire.

`over_200k_share` is reported **for grok only, computed on `input_toks` alone**:
it measures xAI's prompt cliff, `cache_read` is not prompt, and under the
combined unit a normal claude lane read 1.0 — "100% over a cliff it does not
have". `orchestrator-burn.csv` carries `peak_cache_read`
beside the daily total — the sum rises with legitimate volume too, so only the peak
distinguishes a busy day from a session that ran away.

**A measurement's CURRENCY follows the lane's billing mode, and the runner mix
is part of the number.** On metered lanes (grok / fireworks / openrouter) the
verdict currency is **cash** — that is the claim anyone is actually making. On
subscription lanes, cash is notional and **context** is the honest proxy. Context
comparisons are the *mechanism* metric and must be quoted **runner-constant**:
the first split-tick read "the tiering is the problem" in context and "the
tiering saved money" in cash, opposite verdicts from one tick, because a
cross-runner context comparison put a 14–17x cheaper model beside a dearer one.

And **every tick reports its runner mix beside the number**, because a
subscription-funded rung makes a tick look cheap in cash and unchanged in
context — two ticks with different mixes are not comparable in either currency
until the mix is stated. The baseline that taught this: its headline cash was
spent on a grok session that FAILED, while the codex session that did the work
was subscription and cost $0.

**Price metered rows from `catalog/model-prices.json`, never from the ledger's
cost column** — fireworks rows leave that column blank and price at rollup, so
reading the column as authoritative undercounts the lane silently. That is the
same blank-means-zero mistake this document warns about, arriving in the
scoreboard rather than the code.

The manifest is joined against actuals so a lane over its declared ceiling says so.
That is what makes this document live rather than documentation.

---

## Standing rules this wave produced

Earned the expensive way, and they generalise past context:

**A fixture is a claim about the producer's output.** Every fixture in the overage
suite wrote reset stamps as `...Z`, a format the producer never emits. The real one
is tz-aware with an offset, which raised `TypeError` and killed the whole rollup on
first deploy — behind nineteen green assertions. Seed fixtures from a real sample,
never from memory of the schema.

**Assert the mutation applied before believing any green.** A silently no-op'd
mutation is indistinguishable from an unpinned property, and skipping the check
files false findings with total confidence. Three people hit this in one day.

**For any new function, assert something calls it.** Four times in one session, a
unit was fully covered while nothing tested that anything invoked it — and
"extract a function" is not automatically the remedy. Extracting between the
*choice* and the *arithmetic* relocates the blind spot: when the bug is "the wrong
source feeds the right field", the test must exercise the code that **chooses**.

**A guard that switches itself off when the subject comes up is worse than no
guard, because it reads as covered.** `budget_hit` matched the word "budget"
anywhere in a reply, so an orchestrator discussing client engagements would prefix
a complete answer with "I stopped partway" — *and* skip the inert-flag self-check on
exactly the turns most likely to be expensive.

**An assertion whose input could never have failed proves nothing while looking
thorough.** Two decoy fixtures shipped in one day: a "hostile" string containing no
trigger words, and a big-tree fixture whose decoys carried no tokens. Write the
input that would catch you, not the one you intend.

**A lesson recorded in one file's comment is not a lesson the codebase has.**
`test-tamper-scan-test.sh` documented the pipefail/SIGPIPE hazard and six other
tests kept flaking on it. That is why this document ships with a manifest and a
test rather than alone.
