# Hotfix go-live (a `hotfix` PR's schema change applies with its code)

**What it is:** the go-live half of the hotfix lane (#370, BH-375). A ticket
labelled `hotfix` wants its migration live WITH its code, not at the next `*/15`
cron tick. `bin/hotfix-migrate.sh` waits for the PR's checks, then applies the files the
PR ADDED in one of TWO shapes — through the project's own migration endpoint, or
by dispatching its GitHub Actions migration workflow — and posts one proof
comment on the PR saying exactly what ran. The build's tier is the only thing it
can change: a hotfix that could not prove itself drops to tier 2, which withholds
the unattended merge — it never blocks the PR.

| half | where it lives | when it acts |
|---|---|---|
| the stage itself (gate, checks wait, apply, proof comment, ledger) | `bin/hotfix-migrate.sh` | called once per build, from run-build |
| the caller | the `# >>> hotfix migrate stage` block of `bin/run-build.sh`, between `STAGE_END settle` and the tier-1 merge gate | after the PR is open, before the tier-1 merge gate reads `TIER` |
| the apply driver, ENDPOINT shape | `bin/apply-migrations.sh <project> --files <basename>…` (same `apply_one` the `*/15` cron tick runs) | per requested file, in the order given |
| the apply driver, WORKFLOW shape | `bin/lib/hotfix-migrate-workflow.sh` (`hm_workflow`), sourced by the stage and called when `HOTFIX_MIGRATE_MODE` resolves to `workflow` | once per build: quiet-window check, then ONE `gh workflow run`, then watch that run |
| whether this build is the emergency one | `HOTFIX`, settled earlier by `# >>> hotfix detect` and the pr-open second opinion (#368), plus `hotfix_meta_is` / `hotfix_lane_on` in `bin/lib/hotfix-lib.sh` | the stage READS that answer and never writes it |

**How an operator reaches it:** no cron line and no UI — it runs inside the build
that opened the PR. By hand, on the box that built it:
`PR_URL=… WT=… BRANCH=… BASE=… SLUG=… bin/hotfix-migrate.sh <project> <build-dir>`.
`docs/DB-COORDINATION-SPEC.md` § "Hotfix go-live (BH-370)" is the ops page.

**How to drive it:**

| what | how |
|---|---|
| the whole stage against stubs (apply order, gate, checks, proof, ledger, exit codes) | `bash tests/hotfix-migrate-endpoint-test.sh` |
| the run-build block itself, extracted verbatim by its markers | section 6 of that suite — including lane-off, `HOTFIX_LABEL`, and that the block leaves `HOTFIX` exactly as it found it |
| `--files` mode and the unchanged no-arg cron path | section 5 of that suite |
| the WORKFLOW shape against stubs (dedupe, quiet window, dispatch, run watch, proof, exit codes) | `HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-workflow-test.sh` |
| a REAL proof (stubs prove the shape, not the endpoint) | run the by-hand command above on a hotfix PR of an endpoint project once its checks are green |
| a REAL proof of the workflow shape | on the project-5 box, against a `hotfix`-labelled PR carrying a manual migration: `HOTFIX_MIGRATE_MODE=workflow HOTFIX_WORKFLOW_FILES_INPUT=file HOTFIX_WORKFLOW_FILES_SEP=" " HOTFIX_WORKFLOW_MAX_FILES=1 PR_URL=… WT=… BRANCH=… SLUG=example-org/project-5 bin/hotfix-migrate.sh project-5 <build-dir>` — expect one proof comment with the run URL, the per-file quiet-window line and the last 60 log lines, and `$BUILD/hotfix-migrate.json` with `run_id` set. **Those three knobs are not optional on project-5**: its `migrate-manual.yml` declares `mode`, `file`, `ref`, `force` and no `files`, so the DEFAULTS answer 422 "Unexpected inputs provided" and the stage records `dispatch-failed` and holds. That is fail-closed — nothing applies — but it never reaches `decision=applied`. Put the three lines in `env/project-5.env` before switching the lane on. |

**Files it writes:**

- `$BUILD/hotfix-migrate.json` — the ledger, keyed on the content fingerprint of
  the added `.sql` files: `{fp, mode, decision, files[], posted_comment_id,
  after_deploy}`. Written AFTER the side effect it records, so a crash costs a
  re-post and never a false "applied".
- `$BUILD/hotfix-migrate.txt` — the stage's own output, verbatim.
- the WORKFLOW shape additionally: `$BUILD/hotfix-dispatch.txt` (what `gh workflow
  run` said), `$BUILD/hotfix-quiet.err` (needs-quiet and probe read errors),
  `$BUILD/hotfix-run-watch.txt` (the watch's own output) and
  `$BUILD/hotfix-run-log.txt` (the run log's last 60 lines, capped at 8000 bytes
  so a verbose runner cannot push the proof past GitHub's comment limit).
- one comment on the PR — the proof, first-person, naming every file, its result,
  the quiet window and the revert line (or `REVERT: none declared in file …`).
- `logs/migrations.log`, `state/migrations-refused-<project>.txt` — the same
  lines `apply_one` writes for the cron tick, shared unchanged between the modes.

**Knobs:** `HOTFIX_MIGRATE_MODE`, `HOTFIX_CI_WAIT`, `HOTFIX_MIGRATE_WORKFLOW`,
`HOTFIX_MIGRATE_GLOB` (all in `env/<project>.env`, all with defaults); plus the
lane's own `HOTFIX_LABEL` and `HOTFIX_LANE=0` / `flags/hotfix-lane-off`, owned by
`bin/lib/hotfix-lib.sh`.

The WORKFLOW shape adds its own, all with defaults, all read inside
`hm_workflow` (its file header is the reference copy):

| knob | default | what it does |
|---|---|---|
| `HOTFIX_MIGRATE_WORKFLOW` | `migrate-manual.yml` | the workflow file to dispatch |
| `HOTFIX_WORKFLOW_FILES_INPUT` | `files` | the `-f` input carrying the file list; set it EMPTY to dispatch with no `-f` at all. The workflow owns this name — project-5's is `file`. |
| `HOTFIX_WORKFLOW_FILES_SEP` | `,` | what joins the file list on that input; the workflow's own parser owns it (a `file` input that takes one path wants a space, or a cap of 1 below) |
| `HOTFIX_WORKFLOW_MAX_FILES` | (unset = no cap) | how many files that input can carry. A PR adding more HOLDS before the dispatch instead of handing the run a token it cannot parse. |
| `HOTFIX_NEEDS_QUIET_CMD` | `node scripts/migration-sql.mjs --needs-quiet` | asked once per file, in `$WT`, with the file appended as its last argument; must print `yes` or `no`. A command and its arguments, word-split once and run as argv — never a shell line, so no migration path is ever shell source. |
| `HOTFIX_QUIET_PROBE_CMD` | (unset) | run in `$WT`; must print the active-writer count, and exactly `0` opens the window |
| `HOTFIX_QUIET_MAX_WAIT` | `900` | seconds to wait for that `0` |
| `HOTFIX_QUIET_POLL` | `30` | seconds between probes |
| `HOTFIX_RUN_WAIT` | `1800` | seconds to watch the dispatched run |
| `HOTFIX_RUN_LOCATE_WAIT` | `60` | seconds to find the run we just dispatched |

A non-integer value falls back to the default, the same way `HOTFIX_CI_WAIT` does.

**Before-merge apply for NORMAL PRs (BH-9403).** The settings row
`hotfix_migrate.conf.<project>` (one JSON object, read by
`bin/lib/hotfix-migrate-knobs.sh`) beats the env knobs above. With
`"before_merge":1` the `# >>> hotfix migrate stage` block also runs the stage for
a PR that is NOT a hotfix, when this build's verdict is APPROVE and that verdict
judged the head the worktree holds. Seeded on: `project-6-os` (dispatch
`migrate-branch.yml` from `main` with `-f file=<basename> -f ref=<branch>`, one
file per dispatch, an APPROVED review on the reviewed head first) and
`project-5` (Migrate Manual SQL, `migrate-manual.yml -f file=<path>` from the PR
branch). No row: hotfix PRs only, as before. Kill switch: `"before_merge":0`.
The keys and their validation are in the lib's header. In per-file mode
(`"per_file":1`) the stage reads the run log for one word per file: `applied` /
`already-applied` go on to the next file; `refused` stops with 0 retries, one
ALERTS line (`--id hotfix-migrate-refused-<project>-<pr>-<fp12>`) and a `hold`
proof; `inert` stops with one alert per project per UTC day (the day is in the
alert id; no state/ file); `failed` stops.
Those three are terminal for the fingerprint: a re-run never dispatches them.
Before EVERY dispatch, under the dispatch lock, the stage reads the PR's live
head and dispatches nothing if it is not the reviewed sha (both projects, every
file). A stop before any dispatch (checks not green, the quiet window, the
dispatch lock, a failed dispatch call, the approval POST, a moved head) writes a
`retry` proof, not `hold`.
The merge conductor (fragment `bin/merge-conductor.d/bh-9403-before-merge-proof.sh`,
called from `mc_mig_hold`) reads the proof of a normal PR: an `applied` proof
is logged and production (`mmh_decide`) still decides; a `hold` proof parks the
PR BLOCKED_HUMAN, so it gets no merge-queue label; a `retry` proof parks
nothing, and the PR takes the ordinary path.

| what | how |
|---|---|
| the row, the dispatch argv, the approval gate, the per-file loop, the outcome words, the checks wait that ignores the migration gate, the run-build trigger and the conductor proof read, against stubs | `HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-before-merge.bh-9403-test.sh` |
| a REAL proof | the first add-only project-6 PR after the merge: its proof comment carries the run link; record it in `example-org/project-6#3687` (`docs/notes/2026-11-12-BH-9403-before-merge-apply.md`) |

**What must never regress:**

- **The stage never blocks the PR and never merges.** Its only lever is `TIER`
  and the note beside it; no `gh pr merge|close|edit` may ever come from here.
- **The block reads `HOTFIX`, it does not write it.** The merged announcement
  below it reads the same global. A re-derivation here either steps over
  `flags/hotfix-lane-off` or loses the announcement on a resumed Fly build.
- **The kill flag beats everything, including `HOTFIX_ISSUE=1`.**
- **A failure word is never a success.** Only the endpoint's literal `applied` /
  `already-applied` count; `refused`, `request failed`, an unparseable `/status`
  and a mismatched result line all HOLD, and a hold is rc 3 + tier 2.
- **Nothing queues.** Both locks are `flock -n` with an immediate rc 75; the
  `*/15` tick owning the project lock means hold and be re-offered, never wait.
- **Idempotence.** A ledger that already says `applied` for this fingerprint
  re-posts the proof at most; it never POSTs the SQL again.

And for the workflow shape specifically:

- **Every refusal happens BEFORE `gh workflow run`.** A dispatch is a
  production write we cannot take back: checks not green, an unreadable
  needs-quiet answer, a needed quiet window with no probe configured, or a probe
  that never printed `0` inside the window all hold with ZERO dispatches.
- **An unreadable answer is never a `no`.** Only the literal `yes` and `no` are
  answers; anything else (and any nonzero exit) holds. Only a literal `0` from
  the probe opens the window — `00`, `0 scans` and an empty line do not.
- **One fingerprint, one run.** A ledger with a `run_id` for this fingerprint
  re-attaches and watches that run; it never dispatches a second one. Only a word
  GitHub itself finished badly (`failure`, `cancelled`, `timed_out`,
  `startup_failure`, `action_required`, `dispatch-failed`) is dispatched again —
  the words written when the WATCH misfired rather than the run (`success` after
  a transient watch error, `exit <rc>` when watch and view both failed) re-attach,
  because re-watching a finished run is free and re-dispatching it applies the
  SQL twice. The ledger lives in `$BUILD`, so this holds within a build dir and
  across a resume of it; a REBUILD of the same ticket starts with no ledger, and
  what stops that one is the proof comment already on the PR plus the merge
  gate — not this check.
- **The lane arms its own identity.** `hm_workflow` takes a repo-scoped App
  token for `$SLUG` (`gh_auth_for`, `bin/lib/gh-app-auth.sh`) before its first
  `gh` call and puts the caller's token back when it returns, so the dispatch and
  the watch do not spend the fleet PAT's one shared 5000/h bucket (#425). A box
  that mints none gets rc 1, with no fork, and the lane runs exactly as before.
- **`applied` comes only from a green watch.** `gh run watch --exit-status`
  returning 0 is the only thing that writes `applied`. Our own watch deadline
  records the run's real in-flight word AND its id so a re-run re-attaches; a
  run we could not locate says so and warns that a re-run would dispatch again.
