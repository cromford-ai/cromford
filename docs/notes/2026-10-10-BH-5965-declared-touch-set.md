# The overlap guard claims only the files a plan declares (BH-5965)

Doc: docs/verification-map/entries/BH-5965.md

## The bug

`bin/planned-files.sh` lists every path token in `plan.md`. The overlap guard
(`bin/plan-overlap.sh`) and the claim (`bin/lib/rb/plan.sh`) used that list.
So a path that a plan names only as caller evidence, as a check, or under
"Not touched" was on both sides of every compare. TK-35, TK-36, TK-37, TK-45
and TK-46 deferred 1 to 8 times each on `scripts/checks/company-query.mjs`.
No slice changed that file.

## What changed

1. `bin/touch-files.sh <build-dir> [project]` reads ONLY the plan's
   `Files to touch` section. It writes three files beside `plan.md`:
   - `touch-files.txt`: the declared paths, one per line, `sort -u`.
   - `touch-files.src`: `path<TAB>L<n><TAB>touch|excluded`, one row per path
     in the section. This is the trace.
   - `touch-source`: `declared`, `none` or `off`.
   When the source is not `declared`, `touch-files.txt` is removed.
2. `bin/plan-overlap.sh` judges a declared candidate on `touch-files.txt`. It
   does not add the BH-5268 hotspot mentions to it. A local in-flight build
   that declares its files is judged on its own `touch-files.txt`.
3. The `# >>> touch claim` region of `bin/lib/rb/plan.sh` publishes
   `touch-files.txt` as the claim: the local file in `state/claims/<p>/<KEY>`
   and the `job_claims` row (through `CLAIM_FILES`). It applies a test reroute
   (`test-reroute.txt`, `th_apply`) to the list first. It logs
   `TOUCH_CLAIM source=<src> n=<count> excluded=<count>` to `pipeline.log`.
4. `bin/plan-sibling.sh check` and `bin/conflict-check.sh` use
   `touch-files.txt` for a side whose `touch-source` is `declared`.

## The section rules

- The section starts at a heading whose text contains `files to touch`. It
  ends at the next heading of the same or a higher level. A deeper heading
  stays inside. A negative deeper heading (`### Not touched`) sets exclude
  mode until the next deeper heading.
- Only item lines claim paths:
  - A table row: paths from the first cell only. The header row and the
    separator row are skipped.
  - A list item: a `<words>: ` label with no backtick and no `/` is removed.
    Paths come from the lead segment, up to the first ` — `, ` – `, ` -- `,
    ` - ` or `: `.
- Negative means `not touched`, `untouched`, `do not edit`, `don't touch`,
  `never edit`, `no change`, `unchanged`, `read only`, `reference only`,
  `not edited` or `not modified`.
- An item is excluded when exclude mode is on, or its label is negative, or
  the text after its lead STARTS with a negative (`— not touched; read only`).
  For a table row, the text is the cells after the first one.
- One path is excluded when the note right after it, up to the next backtick
  span, starts with a negative: `` `x` (read only) ``.
- A negative that comes later in a note does not count. It is about something
  else: `` `x` — keep `helper()` unchanged `` claims `x`. The plan's first
  draft judged the whole lead and the first 40 characters after it. Against
  the 1330 committed plans in `.harness/specs/` that dropped real files, for
  example both docs paths of BH-5915 item 5, because the item ends with
  "never edit the BH-2532 entry". A dropped file costs a merge conflict, so the
  rule only reads the start of a note.
- A prose line that starts with `Not touched`, `Untouched`, `Do not`,
  `Don't` or `Never` records its paths as excluded. A prose line that ends in
  `:` (`Product:`, `**Not touched:**`) sets exclude mode to whether it is
  negative. Other prose lines claim nothing.
- A path that is claimed by one item and excluded by another stays claimed.
  Both rows stay in `touch-files.src`.
- Paths are normalised: `./` and a `:NN` or `:NN-MM` suffix are removed, and
  so are a trailing `/**` and a trailing `/`. A token with `://`, `<`, `>`,
  `*`, `{`, `}` or a space is dropped. So is an absolute path, a path with a
  `..` segment, and a token with no `/` and no extension.
- There is no directory allowlist: `bin/deploy.sh` and a root
  `next.config.js` are claimed. A bare directory with fewer than 3 segments is
  dropped (the planned-files.sh rule). A plan that wants a directory claim
  names a directory with 3 or more segments.
- Lines inside a fenced code block are never read.

## The trace on a defer

The stdout line `OVERLAP_DEFER <KEY> vs <KEY2> files=[...]` did not change.
Four readers parse it. Before it, `bin/plan-overlap.sh` appends one line to
the build's `pipeline.log`. It writes the file directly and not to stderr:
`tests/claims-cross-box.bh-5002-test.sh` C6 pins that stderr carries nothing
else, and gates.sh sends stderr to the same file anyway.

```
OVERLAP_DEFER_SRC <KEY> vs <KEY2> touch=<declared|none|off|absent> src=[<path>@L<n>:<declared|hotspot|mention>,...]
```

`L<n>` is the plan.md line of the path's touch row, or else the first plan.md
line that names it (`?` when no line does). The `plan_overlap` job artifact
has the same tags in `src` and the source in `touch_source`.

## The switch and the fallback

- `touch-source=none` (no section, or a section with no touch path) keeps the
  old behaviour: the mention superset and the BH-5268 hotspot union.
- Switch `plan-touch-off` (settings row `switch.plan-touch-off[.<box>]`,
  `catalog/switches.d/plan-touch-off.json`) or env `PLAN_TOUCH_DECLARED=0`
  turns the touch set off. `bin/touch-files.sh` then writes `off`.
  `bin/plan-overlap.sh` reads the switch too, so it ignores every
  `touch-files.txt` at once. `bin/conflict-check.sh` and
  `bin/plan-sibling.sh` read `touch-source`. They follow the switch when the
  next run of `bin/touch-files.sh` rewrites that file.

## Transition

A build on old code publishes the broad claim until it ends. A candidate on
new code compares only its declared paths with that claim. So it stops
deferring on its own mentions at once. It can still defer on an old sibling's
mentions until that sibling's claim clears.

## What still reads the mention superset

`bin/planned-files.sh` did not change. The size gate, the scope gate, the
evidence summary, test-home, decompose and the pre-plan guards
(`bin/overlap-guard.sh`, `bin/overlap-schedule.sh`) still read
`planned-files.txt`.

## Check on a box

```
cat /root/harness/builds/<project>-<KEY>-*/touch-source
grep -E 'TOUCH_CLAIM|OVERLAP_DEFER_SRC' /root/harness/builds/<project>-<KEY>-*/pipeline.log
```

Suites: `tests/touch-files.bh-5965-test.sh`,
`tests/plan-overlap-touch.bh-5965-test.sh`.
