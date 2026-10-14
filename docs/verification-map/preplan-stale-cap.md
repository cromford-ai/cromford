# Pre-plan stale re-plan cap (BH-1016)

**What it is:** the ceiling on how many times one ticket may re-buy its
pre-plan. `preplan_check` ([preplan-relay.md](preplan-relay.md)) calls a plan
STALE when main has moved in a file the plan named, and `bin/preplan-tick.sh`
acted on that the only way it could: drop the directory and buy another Fable
session. Nothing bounded how often that could happen, and the trigger is not the
ticket — it is main moving. On a busy night every merge touching a shared file
(`prisma/schema.prisma`, `tests/lib/scratch.sh`) re-bought a ~$4 plan for every
queued ticket that named it: **project-4 paid for 152 stale re-plans on
2026-09-18** ($1,037 of pre-plan spend that day), TK-1847 about 50 in three
days. Nothing errored, every script exited 0, and the bill was the only symptom.

A ticket now gets `PREPLAN_STALE_MAX` stale re-plans per 24h. Past that the key
is **terminal** (`PREPLAN_DEFER_TO_BUILD`) and the **build stage plans it from
scratch**, exactly as it did before pre-planning existed — so the cap costs
latency on a ticket that was already losing its plan to every merge, and never
correctness. Terminal is not forever: a changed queue line (the ticket itself
moved) clears the marker and re-arms the full budget, and a marker that ages out
of the window clears itself on the next read.

This is the fleet's metered-API doctrine (`~/.claude/rules/metered-api-dedup.md`)
applied to a pre-plan session: a **persisted** count read **before** the billable
call, terminal state written on the non-success exit, and a fingerprint of the
INPUT (the ticket) rather than of something that moves on its own (main's sha).

**How an operator reaches it:** one cron lane.

| Where | Lane | What it does here |
|---|---|---|
| a watcher box | `bin/preplan-tick.sh` (`cron/box.cron`, \*/2) | asks `preplan_deferred` for every candidate **before** anything else — a terminal key is skipped silently; on a STALE plan asks `preplan_replan_allow`, which persists the attempt and returns 0, or writes the marker and returns 1 |
| the same tick, housekeeping | `bin/preplan-tick.sh` tail | prunes `state/preplan/` files older than 48h beside the existing `plans/` sweep |
| the build | `bin/run-build.sh` `# >>> preplan adopt` | unchanged. A deferred key keeps its last (stale) plan dir; the adopt's own `preplan_check` answers `PREPLAN_STALE` and the build plans fresh |
| the lane itself (BH-1053) | `bin/run-preplan.sh` `# >>> preplan spend guard` | asks `preplan_deferred` beside `preplan_terminal`, **before** the worktree, the primer and `bin/agent-call.sh` — so a lane launched by hand, by the legacy path or by a launcher written next month cannot re-buy a terminalized key. One `PREPLAN_SKIP deferred` line, rc 0 |

**How to drive it:**

| what | how |
|---|---|
| the cap end to end, through the real tick, counting `agent-call.sh` | `bash tests/preplan-stale-cap-test.sh` |
| the knob, the fingerprint, the 24h window, the terminal marker | same suite, sections 1, 2 and 7 |
| the cap being OFF (unwritable `state/`, an unsynced lib) and the choke point | same suite, sections 10-13 |
| the neighbours this must not disturb | `bash tests/preplan-speculative-test.sh`, `bash tests/preplan-relay-test.sh`, `bash tests/preplan-adopt.bh-776-test.sh`, `bash tests/preplan-client-test.sh`, `bash tests/overlap-schedule-test.sh` |

Run every suite with `HARNESS_TEST_SANDBOX=1`. The suite drives the **real**
`bin/preplan-tick.sh` against a real git repo with a stub `run-preplan.sh` that
calls a recording `agent-call.sh` — the count that matters is sessions bought,
not branches taken, per the driving conventions in [README.md](README.md).

**Files it owns on a live box:**

- `state/preplan/<project>-<KEY>.replans` — one epoch stamp per stale re-plan,
  written BEFORE the session is launched. Stamps outside the 24h window are
  pruned on the next read rather than counted.
- `state/preplan/<project>-<KEY>.defer` — `PREPLAN_DEFER_TO_BUILD <fingerprint>
  <epoch>`. Its presence is the terminal state; its fingerprint is what it is
  terminal FOR.
- `logs/preplan.log` — one `PREPLAN_SKIP stale re-plan cap reached (fp <fp>,
  N/24h) — PREPLAN_DEFER_TO_BUILD, the build stage will plan (<why>)` line per
  key per ARMING, on the tick that terminalizes it and on no other.
  `PREPLAN_STALE` lines stay exactly what they were: one per re-plan that
  actually happened, so the two counts in that file now add up to the sessions
  bought. Two more lines live here since BH-1053: `PREPLAN_CAP_OFF <why>`, once
  per tick while the cap cannot work at all, and `PREPLAN_SKIP deferred` from
  `bin/run-preplan.sh` when a lane launched outside the tick meets a terminal
  key.

**Preconditions / seed needs:** none. No schema, no flag, no environment
variable required: `PREPLAN_STALE_MAX` defaults to 2, and every function fails
open when the library is absent (`bin/preplan-tick.sh` defines no-op fallbacks),
so a box whose sync has not landed behaves exactly as it does today.

**Knobs:** `PREPLAN_STALE_MAX` (env or `env/global.env`, default 2) — how many
stale re-plans one ticket may buy in 24h. `0` means the first stale answer
defers to the build stage; non-numeric text falls back to 2, never to unlimited.
`PREPLAN_SPECULATIVE=0` / `flags/preplan-speculative-off` still switches the
whole speculative path off, and the legacy 2026-07-23 path is untouched.

**What must never regress:**

- **The count is persisted BEFORE the launch.** A counter written after the
  session starts never reaches the cap when the session dies, is killed
  mid-plan, or the box reboots — which is the population the cap exists for.
- **The check runs before the billable call.** A guard consulted after
  `bin/run-preplan.sh` has been launched reviews as correct and costs the money
  anyway; the suite asserts the ORDER in the file, because no fixture can.
- **Terminal state is written on the deny path.** Nothing written means the
  dedup can never become true and the next tick re-buys — the failure shape of
  the project-4 Deepgram incident.
- **Fail OPEN, never closed.** A missing library, an unwritable `state/`, a
  corrupt or truncated ledger, an unreadable clock: each allows the re-plan and
  repairs what it can. The cost of failing open is one plan; the cost of failing
  closed is a lane that silently stops pre-planning and nobody notices for a
  week.
- **...and SAY SO when it fails open completely (BH-1053).** An unwritable
  `state/` or a library without the cap disables it for every key, and until
  BH-1053 that was indistinguishable in `logs/preplan.log` from a box where the
  cap was simply never reached — five of five stale answers allowed, zero log
  lines. `preplan_cap_trace` in `bin/preplan-tick.sh` writes one
  `PREPLAN_CAP_OFF <why>` line per tick, from the first key that tick judges, so
  an idle box still says nothing and a broken one says it every two minutes.
- **The `PREPLAN_SKIP` line survives a failed marker write.** The terminal
  marker is the memory that keeps that line once-per-key; when the marker write
  itself fails (a full disk, a path that is not a file) there is no memory, and
  the line came back every two minutes. The log is the fallback memory
  (`grep -qF` on a per-key, per-fingerprint prefix) — and it is keyed on the
  FINGERPRINT, so a ticket that really moved still gets its own line when it
  spends its new budget.
- **The cap is asked where the money is spent, not only where the slot is.**
  `bin/preplan-tick.sh` consulting `preplan_deferred` saves a
  `PREPLAN_PARALLEL` slot; `bin/run-preplan.sh` consulting it is what makes the
  answer true for every launcher, today's and tomorrow's. Same rule as
  `preplan_terminal`, same block, same fail-open.
- **A restamp is not a changed ticket.** ISO timestamps are stripped from the
  queue line before fingerprinting, for the reason `bin/triage-gate.sh` strips
  them from its queue hash: sessions restamp `Re-checked <ts>` on every
  no-action tick, and a restamp that cleared markers would make the cap
  unreachable.
- **A merge outside the planned files costs nothing.** The existing staleness
  diff decides; only a plan that actually went stale is ever counted.
- **The deferred key keeps its plan directory.** Deleting it would hand the next
  tick a MISSING plan — a fresh reason to buy one — and the build stage's own
  `preplan_check` is what judges it.
