# The resolver's tick is spread across projects, and a project can be given a share

Doc: MERGE-CONDUCTOR

**What changed.** `bin/blocked-resolver.sh` still spends one fleet budget per
tick, `BR_PER_TICK` (default 4), and that number is unchanged. Two things around
it are new.

- `br_round_robin` sits between `br_candidates` and the drain loop
  (`done < <(br_candidates | br_round_robin)`). It reads the candidate TSV on
  stdin and prints the same lines interleaved by project: the project order is
  first appearance, the order within one project is preserved, and a line whose
  project field is empty keeps its own bucket. It is the awk shape BH-778 gave
  the merge sweep in `sweep_order` (`bin/merge-sweep.sh`), including the fail
  open: if awk cannot run, the function prints what it read in the order it read
  it, because a broken ordering must never be the reason a parked ticket is not
  looked at.
- `br_per_tick_for <project>` answers how many rungs one project may spend
  inside the tick. The loop takes that number after the `DONE_KEYS` dedupe,
  compares it with a per-tick counter (`NP`), and on a project that is at its
  share writes one line containing `share of this tick is spent` and skips the
  candidate. The line is written once per project per tick, guarded by a
  `CAPSAID` substring set, the same shape `DONE_KEYS` uses.

**Why.** Every candidate source emits in its own file order: `pr-state.tsv` rows
top to bottom, the builds glob, the queue. So the fleet budget was spent top to
bottom too. One repo with four parked PRs took all four rungs, every ten
minutes, for as long as it stayed parked, and the other six repos on the box
were invisible to this lane while nothing anywhere said so. Interleaving is the
fix for the order. The per-project share is the fix for the operator who wants a
noisy repo held to one rung while the rest of the fleet drains.

**What it touches.**

- Knobs: `BR_PER_TICK_<PROJECT>`, read through `br_per_tick_for`. The name is
  the project uppercased with every non-alphanumeric turned into an underscore,
  so `project-1` reads `BR_PER_TICK_project-1_OS`. Unset means the project's
  share is `BR_PER_TICK`, which is the whole tick, so an unset override is
  byte-for-byte today's spend: the only change on a box that sets nothing is the
  order candidates are offered in. A value that is not a number falls back to
  `BR_PER_TICK` and writes one `is not a number` line naming the variable,
  because a project silently stopped by a typo in `env/global.env` is the same
  invisible starvation this change exists to end.
- The fleet ceiling is unchanged and still first in the loop:
  `[ "$N" -lt "$PER_TICK" ] || break` runs before anything else, so a per-project
  override can only ever take less of the tick, never more of it.
- A HELD candidate (`br_one` rc 3) spends neither counter. That was already true
  of the fleet budget — it counts rungs, and a held row took none — and the
  project share counts the same thing for the same reason: a held ticket at the
  top of a capped project would otherwise be that project's entire tick, at zero
  cost and in silence. `tests/resolver-hold-test.sh` section 7 pins the fleet
  half, section 5 of the new file pins the project half.
- Log lines: `<project>: its share of this tick is spent (<n> rungs,
  BR_PER_TICK=<n>) — its remaining candidates wait for the next tick`, and
  `<project>: BR_PER_TICK_<NAME>='<value>' is not a number — using
  BR_PER_TICK=<n>`. On a box with no override set, neither line is ever written.
- No cross-run state. `NP` and `CAPSAID` live for the tick. A candidate the
  share skipped is not counted, not marked and not released — it comes back out
  of its own source on the next tick.

**Left alone on purpose.** `br_from_rebuilds` has its own
`[ "$n" -lt "$PER_TICK" ] || break` over the `$ST/*/*.json` glob. That caps how
many rebuild records that ONE source reads, in glob order, so it can still
favour alphabetically-early projects inside that source. It is not touched here:
the ticket asks for fairness in how the tick is SPENT, and widening that read is
a separate change with its own cost. Naming it is the point — if a project's
rebuild records are never read, this is where to look.

**How it is proven.** `tests/resolver-per-project-budget.bh-870-test.sh` drives
the real script against a scratch harness with two projects and a fake `gh`:
section 0 extracts both functions verbatim and drives them as pure functions,
section 1 puts three `tproj` candidates above one `uproj` candidate with
`BR_PER_TICK=2` and asserts `uproj` is reached, section 2 caps `tproj` at one
and asserts the line is written exactly once, section 3 asserts an unset
override acts on all four, section 4 asserts a bad value falls back, section 5
asserts a HELD candidate spends no share. Every assertion is on what the run did
— the queue rows it wrote, the lines in `logs/blocked-resolver.log` — never on
the script's source text.
