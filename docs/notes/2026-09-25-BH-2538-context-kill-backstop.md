# Context kill as a runaway backstop: sized from p99, unmeasured lanes unarmed, repeat kills escalated

Doc: CONTEXT-COMPOSITION

## What changed

`catalog/context-budgets.json` arms project-triage and re-sizes the fifteen
BH-2309 lanes plus decompose, qa and prompt-eval, every number a **runaway
backstop**, not a budget. The first round of this PR sized kills at the p95,
which stops about one session in twenty by design (about 260 triage shards a
week); the lead review replaced that spec. alert-triage (400K), responder (6M)
and rule-miner (1.5M) keep the numbers their own tickets set.

`bin/agent-call.sh` gained two things:

- **The resolver lets the most specific matching lane decide first**, key or no
  key. Before, a pinned lane with no `context_kill_tokens` fell through to its
  unpinned sibling's number, so an unarmed `alerts-medic` (stage `triage`,
  project `medic`) would have been killed at project-triage's.
- **Repeat kills go to a person.** A killed row's note now names its work
  (`context-kill:ceiling=<n>:total=<m>:tk=<ticket>:fp=<16 hex of the caller's K3
  fingerprint>`). When the same work (project, stage, and the same ticket AND
  fingerprint when the call declares both, so a ticket whose thread moved is
  new work) reaches `CONTEXT_KILL_REPEAT_MAX` kills (default 2) inside
  `CONTEXT_KILL_REPEAT_WINDOW_S` (default 86400), ONE `CONTEXT KILL REPEATED`
  alert goes out through `bin/lane-alert.sh --critical` (one alert id per piece
  of work), and every later call for that work is refused rc 74 before anything
  is bought, leaving a `refused:context-kill-repeat` cost row. The count is read
  from the newest `CONTEXT_KILL_REPEAT_SCAN_ROWS` (50,000) rows of `logs/cost.csv`; no state file. The three knobs are `lib.agent-call.*`
  settings rows. `bin/triage-shard.sh` handles the refusal like a call-guard
  repeat (stamp kept, no per-tick ALERTS line).

- **Every kill is a settings knob.** `catalog/lanes.d/_lib.context-kill.json`
  registers one knob per manifest lane with a kill or a basis (28), so the
  console can set it: the row `lib.context-kill.context_kill_tokens_<lane>`
  overrides that lane's manifest number (`_ctx_kill_row`, applied by
  `lib_env_apply context-kill`). 0 unarms; a positive row arms an unarmed lane.
  In a settings outage the box's cached row applies, else the manifest number,
  never "no kill". Each knob's registry default mirrors the manifest, and
  section S of the bh-2538 suite fails if they drift.

The priced cost row that names the limit that fired is unchanged apart from the
two work tokens appended to its note.

## The rule

kill = max(ceil(1.25 x p99 / 100K) x 100K, 2 x `ceiling_tokens`), over each
lane's claude cost rows in the 7 days 2026-09-18T21:31:27Z..2026-09-25T21:31:27Z. Unit `input_toks + cache_read`,
rows above 0; p95 = `sorted[min(n-1, int(n*0.95))]` as in `bin/cost-rollup.sh`
`runner_input_stats`, and p99 = `sorted[min(n-1, int(n*0.99))]`, so under 100
rows the p99 is the sample max. The first round's pull recorded only p95 and
max, so the six lanes with more than 100 rows (project-triage, build-plan,
build-execute, build-review, build-fix, preplan) take their p99 from a second
pull: the hub's `state/cost/fleet-cost.csv`, claude rows by stage, 7 days to
2026-09-25T23:20Z (`p99_source`, `p99_window`, `p99_calls` in their basis). Its
triage p99 is by stage, pinned siblings included. `product-revise` and `lead-review` have no rows
of their own and keep their BH-2309 analog (`product-prd`, `build-review`),
which now carries a p99-sized number.

**A small sample never tightens a lane** (r2 review). Under 100 rows a lane
keeps main's number when 1.25 x p99 comes out lower (rule `main-floor`:
product-prd, product-mockup, product-signals, product-synth, preplan-map,
product-ideation; product-revise follows product-prd), and under 30 rows a
lane main left unarmed stays unarmed (rule `small-sample-unarmed`: prompt-eval,
10 rows). Every basis records `main_kill`. Only 100+ rows may size a lane below
main, and none of those does.

**No measured rows = UNARMED.** alerts-medic, orchestrator-turn, box-chat,
prebuild-repro, trap-eval and feature-map-draft had no claude rows in the
window. They carry no kill, a `context_kill_basis` with rule `unmeasured`, and
a note saying they get armed once measured. A kill sized off no data (the first
round's 2 x ceiling) would stop nearly every session: measured lanes run at
6.7-52x their declared ceiling.

## Numbers

| lane | claude rows | p95 | p99 | max | rule | main | first round (p95) | now |
|---|---|---|---|---|---|---|---|---|
| `orchestrator-turn` | 0 | - | - | - | unmeasured | none | 300,000 | **UNARMED** |
| `project-triage` | 5201 | 1,205,171 | 2,127,424 | 6,382,996 | p99x1.25 | none | 1,300,000 | 2,700,000 |
| `alerts-medic` | 0 | - | - | - | unmeasured | none | 160,000 | **UNARMED** |
| `box-chat` | 0 | - | - | - | unmeasured | none | 300,000 | **UNARMED** |
| `build-plan` | 972 | 4,312,794 | 5,988,455 | 8,578,020 | p99x1.25 | 6,600,000 | 4,400,000 | 7,500,000 |
| `build-execute` | 876 | 26,122,879 | 42,846,970 | 65,236,122 | p99x1.25 | 40,500,000 | 26,200,000 | 53,600,000 |
| `build-review` | 2369 | 3,399,686 | 6,373,226 | 28,445,306 | p99x1.25 | 4,900,000 | 3,400,000 | 8,000,000 |
| `build-fix` | 222 | 14,475,072 | 47,224,678 | 73,778,970 | p99x1.25 | 20,600,000 | 14,500,000 | 59,100,000 |
| `preplan` | 822 | 5,177,278 | 9,100,725 | 16,659,703 | p99x1.25 | 8,300,000 | 5,200,000 | 11,400,000 |
| `preplan-files` | 4 | 17,601 | 17,601 | 17,601 | p99x1.25 | 100,000 | 100,000 | 100,000 |
| `decompose` | 100 | 2,176,496 | 3,644,881 | 3,644,881 | p99x1.25 | none | 2,200,000 | 4,600,000 |
| `product-ideation` | 34 | 2,386,216 | 3,408,996 | 3,408,996 | main-floor | 5,200,000 | 2,400,000 | 5,200,000 |
| `prompt-eval` | 10 | 248,746 | 248,746 | 248,746 | small-sample-unarmed | none | 300,000 | **UNARMED** |
| `qa` | 72 | 4,279,916 | 6,629,800 | 6,629,800 | p99x1.25 | none | 4,300,000 | 8,300,000 |
| `postmerge-prodqa` | 69 | 4,126,215 | 27,976,894 | 27,976,894 | p99x1.25 | 6,200,000 | 4,200,000 | 35,000,000 |
| `prebuild-repro` | 0 | - | - | - | unmeasured | none | 400,000 | **UNARMED** |
| `product-prd` | 12 | 996,836 | 996,836 | 996,836 | main-floor | 3,300,000 | 1,000,000 | 3,300,000 |
| `product-mockup` | 12 | 632,443 | 632,443 | 632,443 | main-floor | 4,700,000 | 700,000 | 4,700,000 |
| `product-revise` | 0 | - | - | - | analog:product-prd | 3,300,000 | 1,000,000 | 3,300,000 |
| `product-signals` | 4 | 1,405,534 | 1,405,534 | 1,405,534 | main-floor | 5,800,000 | 1,500,000 | 5,800,000 |
| `product-synth` | 4 | 1,465,507 | 1,465,507 | 1,465,507 | main-floor | 4,700,000 | 1,500,000 | 4,700,000 |
| `preplan-map` | 1 | 914,612 | 914,612 | 914,612 | main-floor | 2,700,000 | 1,000,000 | 2,700,000 |
| `trap-eval` | 0 | - | - | - | unmeasured | none | 400,000 | **UNARMED** |
| `lead-review` | 0 | - | - | - | analog:build-review | 4,900,000 | 3,400,000 | 8,000,000 |
| `feature-map-draft` | 0 | - | - | - | unmeasured | none | 500,000 | **UNARMED** |

## How to check it

`bash tests/context-kill-lanes.bh-2538-test.sh` (A: resolution and the unarmed
six; B: every number against its basis; R: a shard at the first round's 1.3M
triage kill runs clean; E: a runaway shard is killed with the priced row; K:
the same ticket killed twice escalates once and the third call is refused) and
`bash tests/context-kill-lanes.bh-2309-test.sh`. On a board box after deploy:
`grep 'CONTEXT KILL' logs/ALERTS.log`, `grep 'context-kill:ceiling=' logs/cost.csv`
and `grep 'CONTEXT-KILL REPEAT REFUSED' logs/failovers.log`.
