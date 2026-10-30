# Design collisions at PLAN, and the caller list after the main merge (BH-5791)

Doc: RUN-BUILD-GRAPH, PLAN-CONTRACT

## Why

Plans changed functions that another ticket changed after the plan's base.
Review or the merge found it late:

- #4332 (BH-4153) and #5163 (BH-5004) both rewrote `flag_active` and
  `flag_set`. That cost a rebuild and a decision from the operator.
- After #4332 merged main, `bin/data-lane-apply.sh` still read the old pause
  file. That was a safety BLOCK.

## What changed

### The plan lists what it changes

The plan prompt and the pre-plan prompt carry a note (`pc_plan_note` in
`bin/lib/plan-collisions.sh`). It asks for a `## Changed symbols` section:

```
## Changed symbols

- function `flag_active`: the check becomes strict. callers: left alone: <reason>
- verb `plan-collisions.sh`: a new CLI.
- route `GET /api/flags`: answers 2.
- format `## Interface callers`: a new PR body section.
```

The kinds are `function`, `verb`, `route` and `format`. `None.` means the plan
changes no symbol. `callers: left alone: <reason>` is the reason the caller
check prints for a caller the plan leaves alone on purpose.

If a listed symbol collides, the plan carries `## Design collisions`, one
bullet per symbol:

```
## Design collisions

- `flag_active`: combine — <how the two designs combine, 20+ characters>
- `flag_set`: needs-human — <the question a person must answer>
```

The first word after the name decides: `combine` or `needs-human`. The same
word later on the line does not count (BH-8813).

### The check (plan stage)

The `# >>> design collisions (BH-5791)` block in `bin/lib/rb/plan.sh` runs
after the plan gate, outside the checkpoint, so adopted pre-plans and resumed
plans are checked too. It runs `bin/plan-collisions.sh`:

- The base is `$BUILD/collision-base` (an earlier run of this build), else the
  pre-plan's `base-sha` when it was adopted, else `git merge-base HEAD
  origin/$BASE`. The first run writes the value to `$BUILD/collision-base`.
- Main: for a located function, `git log -L <start>,<end>:<file>
  <base>..origin/$BASE`, so a change to another function in the same file is
  not a hit. A def that is gone on main is `removed or renamed on main`. A
  verb, route, format or unlocated function is a `-G` text match.
- Open PRs: one `gh_rest_pr_list_all` read, then one `git fetch` of every PR
  head into `refs/collision-check/<key>/pr/<n>` (deleted after), then the same
  rules over `merge-base..PR head`. Our own PRs (head `$BRANCH`,
  `ticket/<key>`, `ticket/<key>-r<n>`, a title that starts with the key) and
  the stack parent are skipped.
- No `## Changed symbols` section: backticked identifiers in the plan that
  have a function definition at the base are checked as `derived`. They give a
  note only.

`$BUILD/collisions.txt`:

```
SYMBOLS: listed=<n> derived=<m> dropped=<d> cap=<c>
MAIN: checked <base12>..<main12> | unread (<why>)
OPEN_PRS: checked <k> | unread (<why>) | off
SYMBOL<TAB>listed|derived<TAB><kind><TAB><name><TAB><reason>
COLLISION<TAB>listed|derived<TAB><name><TAB>main|#<n><TAB><sha12><TAB><reason>
```

An unread main (base not in the clone) or an unread PR list (rc 44/75, not an
array, fetch failed) is written as unread. It is never "none", and it never
refuses a plan.

The block writes `## Design collision check (BH-5791)` into plan.md, in front
of `## Size` (the size gate and the XL split read the end of the file). A
second run replaces it. The note names symbols, shas and PR numbers only, never
a path, because `bin/planned-files.sh` turns a path in plan.md into this
build's file claim. It has no VALIDATE or SATISFIES line, so the plan gate
scores the plan the same.

Verdicts, one `design collisions: … verdict=<v>` line in `pipeline.log`:

| verdict | when | the build |
|---|---|---|
| `none` | no hit | continues |
| `resolved` | every listed hit has a `combine` line | continues |
| `note-only` | only derived hits, or `PLAN_COLLISION_ENFORCE=0` | continues |
| `blocked` | a listed hit with no line after one repair pass, or a `needs-human` line | `PLAN_BLOCKED`, rc 4 |
| `could-not-run` | no lib on the box, or the CLI answered rc 3 | continues |

The repair is one `CC plan` call. `$BUILD/collision-repair-done` is written
before the call, so a resume never pays twice. A blocked plan gets
`BLOCKED-NEEDS-CLARIFICATION`, `needs-human: design collision (BH-5791)` and
one question per symbol at the top, and the plan-blocked path (BB
`plan_blocked`) parks it.

### The caller check (PR stage)

The `# >>> caller check (BH-5791)` block in `bin/lib/rb/pr.sh` runs after the
rebase verify, so it reads the tree after the build's main merge. It runs
`bin/caller-check.sh` over `git merge-base origin/$BASE HEAD`..`HEAD`.

- Interfaces: the plan's listed symbols, plus each function whose def line
  differs between base and head in a changed `*.sh`/`*.js`/`*.mjs`/`*.ts`
  file, plus each def that is gone at head (`definition gone`).
- Callers: `git grep -w -F <name> HEAD`, without `*.md` files, the def lines
  and comment lines. A name under 4 characters is `skipped (name too short)`.
- `ported`: the call line is an added line in this diff. `left alone`: it is
  not; the reason is `definition gone at head; this caller still names it`,
  the plan's `callers: left alone:` reason, or `no reason in the plan`.

It writes `$BUILD/callers.txt` and `CALLERS_SECTION`, which `PR_BODY_FOR`
prints after the needs-human section as `## Interface callers (BH-5791)`. It
never fails the build. Item 13 of `prompts/lead-review-checklist.md` tells the
lead to check the list.

## Knobs

Settings rows through the knob registry (`catalog/lanes.d/_lib.design-collisions.json`,
`catalog/lanes.d/_lib.caller-check.json`), read with `lib_env_apply`:

| knob | default | meaning |
|---|---|---|
| `PLAN_COLLISION_ENFORCE` | 1 | 0/false/no/off: note only, never refuse. Another value is ON plus one ALERTS line. |
| `PLAN_COLLISION_MAX_PRS` | 100 | open PRs listed; 0 = the PR check is off, no GitHub call |
| `PLAN_COLLISION_MAX_SYMBOLS` | 40 | symbols read from the plan; the note says how many it dropped |
| `CALLER_CHECK_MAX_LINES` | 60 | caller bullets in the PR body; 0 = the caller check is off |

## Not in this change

Lanes that merge main into an open PR later (land-rebase, resolver fix rounds)
do not refresh the caller list.
