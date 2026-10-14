# The config inventory answers five questions differently, and its slices no longer share files

Doc: config-inventory

## What changed

One product file: `bin/config-inventory.py`, the generator behind
`bin/config-inventory.sh`. Its committed outputs
(`docs/config-inventory/inventory.json` and `index.html`) are regenerated from
it, and `tests/config-inventory.bh-1530-test.sh` is a new suite that pins every
one of the changes below. The 1511 suite is untouched and still green — it is
the regression guard for what already worked.

Nothing else moves: no lane behaviour, no knob registered, no default removed
from any script. This sharpens the map the `#1511.1 … .N` conversion slices are
cut from.

## The five classification fixes

**The self-init skip is counted, not blanket (R2-N2).** `NAME="${NAME:-5}"` is
how a knob declares itself, so it must not count as the file assigning the
name. The old code collected those names into a SET and then dropped *every*
assignment of a name in it — so on `X=$(wc -l < f); X="${X:-0}"` the real
`X=$(…)` vanished with it and X looked like a knob. `self_init_counts()` now
returns how many self-inits a line carries and the caller skips exactly that
many assignments. Fifteen computed locals moved out of CONFIG: `BEFORE`,
`BOX_TAG`, `DEFER`, `FIX`, `LN0`, `NFAILED`, `NLIVE`, `NROUTES`, `NSURV`,
`QA_FLOWS`, `QN`, `RUNNING`, `STRIKES`, `VCUR`, `WARN_SHOW` (and `Z`).

**#1510 deferral stops eating CI runners and a file path (R2-N3).** Three
narrowings inside `is_deferred_to_1510()`: a shell/CI builtin is never
deferred (`RUNNER_TEMP` is the Actions scratch directory); a whole `CI_RUNNERS`
segment or a `_RUNNER_LABEL` suffix short-circuits the runner check
(`CI_RUNNERS`, `CI_RUNNERS_LABEL`, `CI_RUNNERS_SLUG`,
`CI_RUNNERS_ALERT_HOLD_MIN`, `BATCH_CI_RUNNERS`, `SUITE_RUNNER_LABEL` are
GitHub Actions machine labels, not model runners); and a model-id default now
has to look like a model VERSION
(`claude-(opus|sonnet|haiku|fable)`, `gpt-\d`, `grok-\d`, `gemini-\d`,
`kimi-k\d`, `deepseek-(v\d|r\d|chat|reasoner)`) instead of `<vendor>-anything`,
which had been deferring `MC_LANE_DOWN_FILE` because its default names
`claude-auth-down.txt`. Every real model default on main still matches.
Deferred count 81 → 73.

**A name its own file assigns is never a test hook (R2-N4, locals).** Round 1
had that guard; round 2's rewrite dropped it, so a production local a test also
sets came back TEST_HOOK — a seam a slice author would go looking for and never
find. `same_file_assigned` is computed before the TEST_HOOK rule again.
`ADDED_SQL`, `REPRO_RC`, `TOK`, `MSGF`, `OFF`, `GH_REST_LIB`, `QA_NOTE` and
~60 more are PLUMBING/self-assigned.

**An in-code fallback is knob evidence (R2-N4, knobs).** A read with an empty
literal default is not automatically a seam: the real default is often the next
argument or the clamp below. Exactly three shapes count, per read site —
a knob-helper call (`br_knob_num X "${X:-}" 12`, `num_or "${X:-}" 14`), a
validation clamp (`case "${X:-}" in`), and a validation message
(`X='${X:-}' is not a number — treating as 600`). Deliberately narrow: a plain
equality compare is how `HARNESS_TEST_SANDBOX` is read too, and a helper handed
a `$X` expansion is a value a caller passed in. `GROK_BILLING` is the one real
lever read with an equality compare, so it is listed by hand in
`MANUAL_KNOB_EVIDENCE` rather than by widening the rule. Newly CONFIG:
`BACKUP_STALE_MIN`, `E2E_JOIN_MAX_S`, `GH_BUDGET_MIN_REMAINING`,
`GROK_BILLING`, `LADDER_CLIFF_REFUSE`, `MC_STACK`, `OVERLAP_WAIT_SECS`,
`PR_OWNER_DRY_RUN`, `PR_OWNER_MAX_ACTIONS`, `PR_OWNER_STALE_DAYS`,
`TSC_HEAP_MB`. TEST_HOOK 143 → 70.

**Endpoints: two more call shapes, one fewer false one (R2-N1).** A URL that
is the DEFAULT of a variable read (`X="${X:-https://…}"`) is a call target the
variable side already carries — 11 of them, every worker URL the harness talks
to each tick, had been filed as documentation. So is bash's own
`api_get "https://…"` (six in `bin/vendor-spend-pull.sh`); only the Python
`api_get(` form was known. Going the other way, an interpolated `github.com`
link to a pull/issue/run/commit PAGE is a link a human clicks, not an address
this code calls — the 11 `github.com/$slug/pull/$num` display-link builders are
DOC now. A `.git` remote has no such path and stays a call target. Endpoint
call targets 42 → 48.

## One file, one slice

`build_slices()` grouped vars by their primary file's subsystem and packed in
name order, but a slice's `files` is the union of ALL files reading its vars —
so a file read by vars of different subsystems landed in several slices. On
main that was 38 files, `bin/agent-call.sh` in 9 of them. Nine conversion PRs
cutting the same file in parallel is nine conflicts on a hunk no ticket is
about.

Vars are now partitioned into file-connected components first (share a read
file, share a slice), each component takes the subsystem most of its vars
resolve to, and whole components are packed into slices under the same ≤40-knob
/ ≤12-file caps. Two independent slices can no longer touch the same file.

The two components that are too big for those caps (the `bin/agent-call.sh` hub
at 108 knobs across 20 files, and the build one) cannot be both file-disjoint
and reviewable. They are cut into a SERIAL chain instead: each link carries
`serial_group`, `order` ("2 of 4") and `blocked_by`, plus a note saying the
links are cut one PR after another and never in parallel. Files repeat only
inside one chain. Nothing is dropped to make a slice fit — a var reading more
files than the cap allows would ship flagged `over_cap_files` (none does
today). 26 var slices, two of them chains; files in more than one independent
slice: 38 → 0.

The HTML summary grew a sortable "serial" column so the page and the JSON say
the same thing, and its lede describes the new grouping.

## Not a class: context and output variables (R2-N5)

Two families look like settings and are not, and this change mints no class for
them — they land in CONFIG or TEST_HOOK like anything else and a slice author
drops them on sight. Caller-supplied context: `COST_KEY`, `COST_JOB`,
`COST_PROJECT`, `COST_STAGE`, `COST_ACCT_NAME`, `BUILD_ATTEMPT`, `COST_RUN_ID`
— what the caller hands the script for this invocation. Output/status:
`JOBS_BODY`, `JOBS_TRANSCRIPT_TRUNCATED`, `JOB_REFUSED`, `LLM_GATE_REASON`,
`SRC` — what the code computes and passes back out. A settings row for either
is a row nobody can usefully set. A class of their own would change the
`by_class` schema every consumer reads, so if one is ever wanted it is its own
slice, not a side effect of this one.

## What to run

```
bin/config-inventory.sh                       # regenerate docs/config-inventory/
bash tests/config-inventory.bh-1530-test.sh   # this ticket's suite
bash tests/config-inventory.bh-1511-test.sh   # the regression guard
```

Section 7 of the 1530 suite asserts against the COMMITTED `inventory.json`, and
those are hard failures rather than the 1511 suite's WARN — a later `bin/` edit
that re-breaks one of these classifications should turn a PR red, not quietly
re-file a knob as a test seam. If it fires and the change was intentional,
re-run the generator and commit its output in the same PR.
