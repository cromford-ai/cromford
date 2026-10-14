# Operating lessons, defaults and builder rules written down (BH-5289)

Doc: OPERATING, SELF-HOST, README

## What changed

- New `docs/OPERATING.md`: the lessons of the 2026-10-06/07 backlog push, one
  `###` lesson per item in eight sections (Merge throughput, Review throughput,
  Builds, Conflicts, Gates vs reports, Tests, Operations, Defaults). Each lesson
  says what goes wrong, what the factory does, and the knob or file. It names no
  project, box or person, carries no spend figure and no issue number, because
  it ships in the public copy as is. Linked from the README "Read next" table,
  from `docs/SELF-HOST.md` §7, from `CONTRIBUTING.md`, and from the public
  overlay's `CONTRIBUTING.md` and new `AGENTS.md`.
- New seed in `worker/jobs/schema.sql`: global `risk_tier.mode = off`
  (INSERT OR IGNORE). It changes no behavior: `rt_mode` already answered off
  with no row, a per-repo row still wins, and an operator's global row is kept.
  It makes the default a row an operator can see and edit, not only a code path.
  It is read only for repos in `RT_MODE_REPOS` (`bin/lib/risk-tier.sh`, today the
  harness's own repo); every other repo is off by that constant, not by this
  row. Per-repo opt-in for any other repo needs the constant extended first,
  which is outside this ticket.
- `prompts/build-discipline.md` gains D47-D50 (fixture marker, no `$RANDOM` and
  no `D`/`DIR`/`ROOT` with `find`, timing row with an always-run suite, report a
  harmless metric). `prompts/plan-contract.md` gains §10, Operating lessons.
  The conflict-discipline rules are left to #5269 (BH-5248 wave 3), and the new
  section links it.
- Two suites: `tests/operating-doc.bh-5289-test.sh` (sections, lesson keywords,
  links, `bin/share/leakcheck.py` over the doc with a planted-name negative
  control, no `$<digit>`, no `#NNN`, prompt cross-links) and
  `tests/default-seeds.bh-5289-test.sh` (a fresh schema's rows equal the code
  fallbacks and the catalog defaults, `rt_mode` over that schema, and the
  Defaults table's Default column).

## Where each OPERATING.md lesson came from

| Section | Lesson | Issues |
|---|---|---|
| Merge throughput | impact batches | #5010, #5053 |
| Merge throughput | separate lanes | #5049 |
| Merge throughput | culprit eject, no bisect (in progress) | #5110 |
| Merge throughput | fix-main-red first, timing rows | #5256 |
| Review throughput | parallel lead reviews | #5284 |
| Review throughput | risk tier, narrow low set | #5067, BH-5022 |
| Review throughput | stale CHANGES_REQUESTED dismissal (in progress) | #5213, #5258 |
| Builds | pre-push lint | #5111 |
| Builds | reused pool machines | #5021, #5070 |
| Builds | size gate 700/20 | #4985 |
| Conflicts | hotspots, fragments, module map, sequencing, stacks | #4987, #5229, #4988, #5248, #5234 |
| Conflicts | no changelog headers, closure helper | #5235 |
| Gates vs reports | no line limits, report-only fast-lint budget (in progress) | #5228, #5292, #5302 |
| Tests | trace gate eval/declare blind spot (in progress) | #5266 |
| Operations | console replies | #4995 |

## Defaults left as documentation only

- Fast-lint budget report-only: comes with #5302 (BH-5292), which has not
  landed. This PR documents the default; it does not deliver it.
- Stale-review dismissal: comes with #5258 (BH-5213), no knob, which has not
  landed. This PR documents the default; it does not deliver it.
- Merge-queue lanes (declared deviation: the ticket asked for lanes on by
  default; a fresh install stays serial, and OPERATING.md says so):
  `queue_partition.mode=enforce` is NOT seeded. Flipping it
  changes live conductor behavior and needs the live probe the 2026-09-19
  gating rule asks for, so it stays a per-repo flip (docs/MERGIFY.md).
- Impact CI: unconditional already, pinned by
  `tests/ci-plan-batch-impact.bh-4968-test.sh`.
