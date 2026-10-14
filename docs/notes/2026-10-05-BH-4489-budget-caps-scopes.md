# BH-4489: hard caps on every stage and scope

Doc: AGENT-CALL, BUILD-TRIPWIRE, DB-COORDINATION-SPEC

**What changed.** BH-4488 capped one stage (execute) inside builds. Now every
model call is checked before it runs, against three scopes:

| scope | unit | settings rows | total read from |
|---|---|---|---|
| build-stage | (build dir, stage) | `budget.stage.<s>.max_calls`, `.max_usd`, `.max_tokens` | the build's own `cost.csv` |
| stage-day | (project, stage, UTC day) | `budget.stage.<s>.day_usd`, `.day_calls` | D1 `GET /api/metrics/llm-spend?project=<p>&stage=<s>` |
| project-day | (project, UTC day), all stages | `budget.project.<p>.day_usd` | D1 `GET /api/metrics/llm-spend?project=<p>` |

The build-stage scope applies to any call whose output lands in a build dir,
at any stage. The day scopes apply to any call that has a project and a
configured jobs client, in a build or not. Triage, lead-review and every other
lane outside a build are capped through them. So are Archie and research
(#3966, #4065) from their first call, through the `_default` rows.

Tokens are `input_toks + output_toks + cache_read + cache_write`, summed over
the same rows that count as calls. A blank token cell adds 0. Day calls are
billed calls: `calls - refused - settled`. A refusal costs no call.

**How a cap is found.** The specific row comes first
(`budget.stage.plan.max_calls`). With no specific row, the `_default` row is
used (`budget.stage._default.max_calls`, `budget.project._default.day_usd`).
With neither, that axis has no cap. `off` on the specific row unarms the axis
outright. `0` is a real cap that refuses everything on that axis, which is the
opposite of llm-gate's `0 = unlimited`. A stage or project whose name can't
make a legal key (uppercase, other characters, or over 64 chars) skips to
`_default`. One the spend query can't carry (outside `[A-Za-z0-9._-]`) has no
day scope at all, so a bad name is never a refusal. Rows come from the settings cache wave 1 already reads
(`state/settings-cache.json`, refreshed after `LANE_GATE_CACHE_S`). That is a
deliberate departure from the plan's D14 ("do not cache across invocations"):
it follows wave 1, so an operator's raise reaches a box up to one cache TTL
late, and a box with no cache file at all reads every cap as unarmed, inside a
build too (fail open, where D6 says a build fails closed). A cache file that
exists but is corrupt is the fail-closed case below.

**A terminal verdict wins, then the tightest.** Every scope that applies is
checked. If any build-stage axis is at or over its cap, build-stage decides,
even when a day scope is further over. A day deferral there would bring the
ticket back as a fresh build with fresh build-stage totals, and the overrun
would be forgotten. Otherwise, among the axes at or over their cap, the one
with the least headroom, `(cap - spent) / cap`, decides. A cap of 0 counts as
the least, and ties go stage-day, then project-day. The refusal names every
other over axis after `also over:`.

**What happens on a refusal.**

- build-stage wins: exactly BH-4488's terminal stop. `$BUILD/BUDGET_STOP`, one
  alert, `RESULT "BUILD_REFUSED BUDGET_STOP ..."`. The verdict line gains
  `tokens=<n> max_tokens=<cap>` when that axis is armed.
- a day scope wins: not terminal, because the day resets. agent-call exits 74
  with `AGENT_CALL_REFUSED budget-stage-day <stage> project=<p> stage=<s>
  usd=<x>/<cap> calls=<n>/<cap>` or `AGENT_CALL_REFUSED budget-project-day
  <stage> project=<p> usd=<x>/<cap>`. It writes a $0 refused cost row, a
  failovers line and one alert per (scope, name, UTC day). No terminal
  marker. Inside a build, `CC()` writes `$BUILD/BUDGET_DEFER` (the line) and
  answers `BUILD_DEFERRED <that line>`. Nothing resumes that build.
  `resume-dead.sh` leaves a first run's `BUILD_DEFERRED` to triage and skips
  pool dirs, so the ticket comes back as a fresh build, and checkpoint adopt
  keeps only its code. The calls the deferred run bought are lost. The launch
  gate below is what keeps the re-offer from buying them again. The marker is what carries the deferral out of a review lens
  that runs in a background subshell, where `exit 3` only ends the subshell:
  the parent checks it right after the lens join and defers before it buys a
  fix round or writes a lens BLOCK, and every later `CC()` call refuses on it.
  A resume clears it. `bin/fly-pool.sh`'s `pool_lane_failure` reads a
  `budget-project-day` / `budget-stage-day` deferral as the lane's condition.
  The ticket's deferral count does not move, and the project's spawns are held
  for `POOL_LANE_FAIL_HOLD_S`.

**A project at its day cap starts no new build.** The `budget launch gate`
block in `bin/lib/rb/gates.sh` runs right after the tripwire skip and before
the Fly enqueue. Over the project-day cap it answers `BUILD_DEFERRED
budget-project-day project=<p> usd=<x>/<cap> — re-offered next tick; the cap
resets at 00:00Z`, so it writes no queue row and spawns no machine. It also
checks the stage-day cap of every stage a build calls (`BS_BUILD_STAGES`:
plan, execute, review, fix, qa) and answers `BUILD_DEFERRED budget-stage-day
project=<p> stage=<s> usd=<x>/<cap> calls=<n>/<cap> — ...` when one is over.
That is the whole reason it checks the later stages: a build deferred at its
review cap is re-offered fresh, and without this every re-offer would buy plan
and execute again before being refused at review again.

**Which side fails open.**

- build-stage, unreadable: closed and terminal, as BH-4488 shipped it.
- a day scope inside a build, unreadable (junk row, corrupt cache, llm-spend
  down): closed, not terminal. `AGENT_CALL_REFUSED budget-cap-unreadable
  <stage> <reason>`, reason `budget-total-unreadable:stage-day|project-day`,
  `cap-unreadable:<key>` or `settings-unreadable`, and the build defers. The
  pool counts this deferral, because it's an outage and not a cap.
- a day scope outside a build, unreadable: open. The call runs, and one alert
  per (stage, project, UTC day) says so. Outside a build there's no job to
  defer. The lanes that report a worker outage have to keep running through
  one.
- the launch gate, unreadable: closed. `BUILD_DEFERRED budget-cap-unreadable
  launch <reason>`, counted by the pool like the call gate's own outage
  deferral. Open would let a build run plan and execute and then defer at the
  first later stage whose cap it can't read, on every re-offer.

**Finishes nothing mid-call.** Every check runs before the call. Nothing here
runs during a call or signals a running one. The call that crosses a cap
finishes and writes its row, and the next one is refused. D1 is fed by each
box's cost mirror push, so a day scope can overshoot by whatever was spent
inside that lag. That's the accepted bound. Two calls racing the same day cap
can both pass.

**Calls into a build dir from outside run-build count too.** The build-stage
scope keys on where `$OUT` lands, not on who called. `bin/replan-check.sh`
(stage `replan`), `bin/postmerge-qa.sh` (`prodqa`) and `bin/review-rescue.sh`
(`review`, in the candidate's dir) all write into a build dir, so their calls
add to that build's per-stage totals and are refused once it holds
`BUDGET_STOP`. Each one already reads rc 74 as "nothing was called".

**Three ceilings, the lowest binds.** `llm-gate` (BH-1141) runs first. Its
lane caps (`lane.<id>[.<p>].llm_usd_cap_day`) fail open and are independent of
these. `catalog/lane-caps.conf` (BH-1039, hub triage, box-local) is a third.
Hotfix builds are not exempt. The per-call `--max-budget-usd` handed to the CLI
is untouched.

**The defaults are on.** `worker/jobs/schema.sql` seeds one `INSERT OR IGNORE`
statement, applied by `bin/harness-sync.sh` before deploy. Each value is p99 x
2 of the 30 days of `cost_rows` before the seed's timestamp, from
`bin/budget-defaults.sh --days 30`:

- build-stage rows for stages with at least 20 build runs (build run ids
  only), plus `_default` pooled over every build stage;
- stage-day rows for stages with at least 30 (stage, project, day) totals,
  plus `_default` (a stage under 30 is capped by the pooled `_default`);
- project-day rows for projects with at least 14 days, plus `_default`.

An axis whose p99 x 2 comes out 0 (infra runs bill no tokens) gets no row,
because 0 would refuse everything. Re-run the generator any time with
`bin/budget-defaults.sh --days 30` (`--rows <cost.csv>` reads a file instead,
`-h` for usage). A failed read prints nothing and exits 1. Paste a new
statement as its own statement to re-seed keys that don't exist yet. INSERT OR
IGNORE never overwrites a value someone set.

These are ceilings for runaways, not budgets. Replayed against the same
30-day window (2026-09-05..2026-10-05, 64,934 rows), a handful of the window's
own outliers reach their cap, and nothing else does. The worst cases were
`plan` usd 13 of 4,465 build runs (max $42.71 against $19.13), `plan` calls 10
of 4,465 (6 against 6, so a 7th call would have been refused), `execute` usd 8
of 2,883, `review` tokens 5 of 2,748, `fix` usd 5 of 844, and `triage`
day_calls 2 of 363 stage-days (max 4,874 against 2,040). No project-day row and
no other stage-day row is reached. That is what 2x p99 means on a large sample:
the top 1% is not always under it. On a small sample it works the other way.
Under 100 samples a nearest-rank p99 is the sample max, so the row is 2x the
largest value the window saw and can still trip on real growth. The
project-day rows (14+ days) and the smaller build-stage rows (20+ runs) are the
ones it applies to most. Incident lanes are capped like any other project:
`responder` ($182.37) and `medic` ($16.24) come from 17 days each, so a heavy
incident day can reach them. When one trips, it sends one alert that day. The stage-day minimum is 30 because at 5 it seeded lane
stages off a few weeks of near-idle days (16 days of `synth` gave `day_calls`
2). Raise a row first if a lane trips on a normal day.

**How to raise or clear a cap.** `bin/jobs-client.sh setting-set
budget.project.project-5.day_usd 15000`, or the console Settings screen. `off`
unarms one axis. To turn every scope off at once, use the kill switch
`budget-stop-off` (settings row `switch.budget-stop-off`, or
`flags/budget-stop-off`, registered in `catalog/switches.d/`). A build that
already holds `BUDGET_STOP` stays stopped.

**Keys the self-host installer (#4081) writes.** `budget.stage._default.max_calls`,
`.max_usd`, `.max_tokens`, `.day_usd`, `.day_calls`;
`budget.project._default.day_usd`; and per stage or project the same suffixes
on `budget.stage.<stage>.` / `budget.project.<project>.`. Values: integers for
`*_calls` / `*_tokens`, decimals for `*_usd`, or `off`.

Pinned by `tests/budget-caps-scopes.bh-4489-test.sh` (the ticket calls it
`tests/budget-caps-scopes-test.sh`; the per-ticket naming rule renamed it),
`tests/budget-defaults.bh-4489-test.sh`,
`worker/jobs/test/budget-seeds.bh-4489.test.js`, and the edited
`tests/budget-stop-tracer-test.sh`.
