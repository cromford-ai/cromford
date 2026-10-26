# Prompts: versions and per-project overrides

A person can save an override of a build prompt for the whole fleet or for one
project. Each save is a new, immutable version. A head points at the version in
use. The hub reads the result with `bin/prompt-resolve.sh`. Parent ticket:
BH-7940. This page describes what BH-7940.0 ships; the sections at the end
belong to the later slices.

## Kinds

Seven kinds, in this order everywhere (`PROMPT_KINDS` in
`worker/jobs/src/lib/prompt-store.js`): `rules`, `watcher`, `plan`, `execute`,
`review`, `fix-round`, `qa`.

## Resolution order

For a project and a kind, the first of these wins:

1. The project head: scope `project`, that project.
2. The fleet head: scope `fleet` (stored with `project = ''`).
3. The repo file:
   - `rules`: `rules/CLAUDE.md`
   - `watcher`: `prompts/<project>.md`
   - `plan`, `execute`, `review`, `fix-round`, `qa`: `prompts/stages/<kind>.md`.
     These files do not exist yet (BH-7940.2), so the resolver exits 4 for them.

A head on project A never changes what project B gets.

## Version model

- Table `prompt_versions`: one row per save, keyed by `(scope, project, kind,
  version)` (unique index `prompt_versions_key`). No route updates or deletes a
  row.
- Table `prompt_heads`: one row per `(scope, project, kind)` (unique index
  `prompt_heads_key`). `version_id` is the `prompt_versions.id` in use.
- A save inserts version n+1 and moves the head in one D1 batch. Both rows are
  written, or neither.
- A save may send `base_version`: the version the editor started from. The save
  then succeeds only if the newest version is still `base_version`. Otherwise it
  is a 409 and nothing is written, so two people cannot both save on top of the
  same version. Without `base_version`, the save takes the next number.
- Settings rows: `prompts.body_max_bytes` (262144) is the largest body a save
  accepts, in UTF-8 bytes. `prompts.retention.keep_versions` (200) is seeded for
  the retention rule of BH-7940.4; nothing reads it yet.
- Schema: `worker/jobs/schema.d/202610221216-bh-7940-prompt-versions.sql`.

## Routes (harness-jobs, bearer-gated)

| Route | Answer |
|---|---|
| `GET /api/prompts?project=<p>` | 200 `{project, prompts: [{kind, source, version, version_id, author, set_at}], as_of}`: seven rows in kind order. `source` is `project`, `fleet` or `repo` (then the other fields are null). With no `project`, only fleet and repo rows. |
| `GET /api/prompts/<scope>/<kind>/<version>?project=<p>` | 200 `{prompt: {id, scope, project, kind, version, body, author, note, created_at}}`, or 404 `{error: "not_found"}`. |
| `POST /api/prompts/<scope>/<kind>?project=<p>` `{body, author, note?, base_version?}` | 201 `{id, version}`. |

Refusals, each of which writes nothing:

- 400: a bad scope, kind, project, version or field. `project` is required for
  scope `project` and must be absent for `fleet`. A project slug matches
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`.
- 401: no bearer or a wrong bearer.
- 409 `version_conflict`: a stale `base_version`, or a unique-index collision.
- 413 `body_too_large`: the body is over `prompts.body_max_bytes`.
- 422 `empty_body`: an empty or blank body, for every kind.
- 422 `missing_marker`: the body lacks a marker from
  `catalog/prompt-markers.json` (the lists are empty until BH-7940.4).
- 503: the tables are not applied (`<table> schema not applied`).

The console reaches these routes only through
`console-ui/functions/api/prompts/[[path]].js`. It adds the bearer on the
server, checks the console session, checks each path segment, and sets
`author` to the signed-in identity.

## bin/prompt-resolve.sh

`bin/prompt-resolve.sh <project> <kind> [--source]` prints the resolved body
byte for byte. It makes one list call and, for a fleet or project head, one
version call. With `PROMPT_RESOLVE_CACHE_DIR` set, the list answer is kept at
`<dir>/list-<project>.json` and reused for the rest of the run.

`--source` prints one line and no body: `<kind> <source> v<version>
<version_id>`, for example `watcher project v3 41`. For the repo file it prints
`<kind> repo v0 -`.

| Exit | Meaning |
|---|---|
| 0 | The body (or the `--source` line) is printed. |
| 2 | Usage: wrong argument count, unknown flag, bad project or kind. |
| 3 | The worker is configured and did not answer (curl error, HTTP not 200, an unreadable answer, no row for the kind, or `JOBS_URL` with no `HARNESS_SECRET`). Nothing is printed, never the repo file. |
| 4 | The repo file is the answer and it does not exist. Nothing is printed. |

With `JOBS_URL` unset, the script reads `JOBS_URL` and `HARNESS_SECRET` from
`global.env`. If `JOBS_URL` is still empty, the worker is not configured and
the script prints the repo file.

## Path convention

The hub render (BH-7940.3) writes each resolved prompt to
`state/prompts/<project>/<kind>.md`, with one `--source` line per kind in
`state/prompts/<project>/sources.tsv`. The fleet rules go to
`state/prompts/_fleet/rules.md`. The project slug rule above means a project can
never be named `_fleet`. BH-7940.0 ships the convention only; nothing writes
these files yet.

## Seams and owners

- `catalog/prompt-markers.json` and `worker/jobs/src/lib/prompt-markers.js`
  (`missingMarkers(kind, body)`): owner BH-7940.4.
- `console-ui/src/ui/PromptHistoryActions.js` (`PromptVersionsSheet`,
  `UseLevelAboveButton`, both render null today): owner BH-7940.4, imported by
  BH-7940.5.
- `console-ui/functions/api/prompts/[[path]].js`: used by BH-7940.4 and
  BH-7940.5.

## Stage prompt files (BH-7940.2)

Owner: BH-7940.2.

The five stage prompts are files now. Each build stage renders its file with
`sp_render <kind> [<outvar>]` from `bin/lib/stage-prompt.sh`, then calls the
runner `CC` with the result. The runner call does not change.

| Kind | File | Rendered in |
|---|---|---|
| `plan` | `prompts/stages/plan.md` | `bin/lib/rb/plan.sh`, block `plan prompt` |
| `execute` | `prompts/stages/execute.md` | `bin/lib/rb/execute.sh`, block `execute prompt` |
| `review` | `prompts/stages/review.md` | `bin/lib/rb/review.sh`, block `review prompt` |
| `fix-round` | `prompts/stages/fix-round.md` | the same block; `LENS_VARS` reads it as the review lens `L_FIX` |
| `qa` | `prompts/stages/qa.md` | `QA_PROMPT_FOR` in `bin/lib/rb/pr.sh` |

The T0 static-review prefix, the security and refute lens prompts and their
fix rounds stay inline in `bin/lib/rb/review.sh`.

Template format:

- A variable is written `${NAME}`. No other form is replaced: `$NAME`,
  `${NAME:-x}`, `${ NAME}` and `${1}` stay literal text. So a literal `$` with no
  braces, such as `$BUILD/validate.txt` in `execute.md`, stays as it is.
- `NAME` must be a word of the whitelist `SP_VARS` in `bin/lib/stage-prompt.sh`.
  A name that is not on the list stays literal, so a template cannot read
  `${HARNESS_SECRET}` or any other env value. An unset listed name renders empty.
- The render is one pass, left to right. A value is never scanned again and
  nothing is evaluated, so `${KEY}` or `$(id)` inside a value stays as text.
- The file's bytes are kept. No file ends in a newline today, and the render
  adds none and removes none.
- The `$(...)` parts of the old inline strings are computed by the stage before
  the render, as `SP_PLAN_*` and `SP_REVIEW_*` variables. `SP_PLAN_SIZE_SCOPE` is
  the output of `bin/size-scope.sh --rules`, run in the repo, because the old
  plan string ran that command through an unescaped backtick pair.
- `SP_PREVIEW_URL` is the preview URL that `QA_PROMPT_FOR` gets as `$1`.

Source order for `sp_render <kind>`:

1. `$HARNESS/state/prompts/$PROJECT/<kind>.md`, when it is readable and not
   empty (the hub-resolved copy, BH-7940.3).
2. Else `$SP_STAGES_DIR/<kind>.md`. `SP_STAGES_DIR` defaults to `prompts/stages`
   in the checkout that holds the lib.
3. Else no prompt: `stage-prompt: no template for <kind>` on stderr, rc 1.

On rc 0, `SP_SOURCE_<kind>` names the file read (a dash becomes an underscore:
`SP_SOURCE_fix_round`). An unknown kind is rc 2.

When `$HARNESS/state/prompts/$PROJECT/rules.md` is not empty, the render starts
with this line and one newline:

```
PROJECT RULES OVERRIDE: read <that path>; it replaces ~/.claude/CLAUDE.md for this build.
```

A missing template never sends an empty prompt:

- `plan`, `execute`, `review`, `fix-round`: the stage writes `BUILD_REFUSED
  prompt template missing (<kind>)` to `pipeline.log` and as the RESULT, and
  exits 3 before any `CC` call.
- `qa`: the PR is already open, so the build goes on. There is no QA session.
  `qa.md` gets the reason, `MAP ENTRIES: none`, `QA COVERAGE: screens=0 flows=0
  shots=0` and `QA: FAIL`. The PR is tier 2, and ALERTS.log gets one
  `BUILD_REFUSED prompt template missing (qa)` line.

`tests/stage-prompt.bh-7970-test.sh` pins the move: with no resolved file and
no `rules.md`, each rendered prompt is byte-equal to the old inline string in
`tests/fixtures/stage-prompt.bh-7970/`. A change to a template updates its
fixture in the same diff.

## Hub render and build note (BH-7940.3)

Owner: BH-7940.3.

The hub render now writes the files of `## Path convention`.

### The render: `bin/prompt-render.sh`

It runs on the hub only, on every `bin/fleet-propagate.sh` tick, and always
exits 0. For each project of `fleet-conf.sh --projects` and each kind (rules,
watcher, plan, execute, review, fix-round, qa), it reads the
`prompt-resolve.sh --source` line:

| Source | `state/prompts/<project>/<kind>.md` |
|---|---|
| `project` | holds the head body |
| `fleet`, a stage kind | holds the fleet head body |
| `fleet`, rules | removed: the fleet rules go to `_fleet/rules.md` only |
| `repo` | removed: the box uses its own repo file |
| rc 4 (no repo file) | removed, and the kind gets no `sources.tsv` line |

Then `state/prompts/<project>/sources.tsv` gets the `--source` lines, after
the kind files. Then `prompt-resolve.sh _fleet rules` decides
`state/prompts/_fleet/rules.md`: it holds the fleet `rules` head, or it is
removed. `_fleet` is the one reserved project name: it lists with no project,
so only the fleet and repo sources answer, and `_fleet watcher` is usage (rc 2).
A project dir that is not in `fleet.conf` is removed, but only when the project
list is not empty.

Each file is written to `<file>.tmp`, compared with `cmp`, and moved only when
it differs, so an unchanged file keeps its mtime. A run removes the `*.tmp`
files that a killed run left. A repo source reads the git checkout
(`PROMPT_RESOLVE_ROOT=$HARNESS_CHECKOUT`), and the per-run cache makes one list
call per project. Each run logs one line to `logs/prompt-render.log`:
`projects=N written=W removed=R unchanged=U down=0|1`.

- Not configured (no `JOBS_URL` in the env or `global.env`): the render logs
  one line and touches nothing.
- Worker down (rc 3): the run stops and keeps every file as it is, so builds
  use the last resolved prompts. The first down run of an outage writes ONE
  alert through `bin/alert-line.sh` (id `prompt-render-worker-down`, text
  `prompt-render: worker did not answer …`) and the marker
  `state/prompt-render.down-since`. Later down runs log only. The first run that
  answers removes the marker and resolves the alert.
- A timeout in the middle of a project leaves its new kind files and its old
  `sources.tsv` until the next run.

### The push: `fp_prompts_tick` in `bin/fleet-propagate.sh`

The step runs in deploy mode right after the lane lock, before the wake
backstop and before any "up to date" or "touches no fleet path" exit. So a head
that moves reaches the boxes on the next tick, with no merge. With no
`bin/prompt-render.sh` or no `state/prompts/`, it does nothing.

- Digest: `sha256sum` over the sorted paths and contents of `state/prompts/`,
  `*.tmp` excluded.
- Hub: when the digest differs from `state/fleet-propagate/prompts-hub.sha`,
  `sync-agent-rules.sh apply` runs, and the digest is written on rc 0.
- Boxes: for each box whose `state/fleet-propagate/prompts-<box>.sha` differs,
  one background job runs `rsync -a --delete --exclude='*.tmp'` of
  `state/prompts/` to the box, then `ssh -n … sync-agent-rules.sh apply`. The
  digest is written only when both return 0, so a failed box is pushed again
  on the next tick. One log line per tick that pushed:
  `prompts: <digest12> pushed to N/M box(es), failed: <boxes>`. There is no
  alert: a box that stays down is paged by the box-lag check (BH-6201).

| Knob | Default | Use |
|---|---|---|
| `PROMPT_RENDER_TIMEOUT_S` | 120 | `timeout` of the render on each tick |
| `PROMPT_PUSH_TIMEOUT_S` | 60 | `timeout` of each box step (rsync, then apply) |

Both are rows in `catalog/lanes.d/fleet-propagate.knobs.d/`. A value of 0 or a
non-number logs one line and uses the default.

### Fleet rules win (decision 7)

A non-empty regular file at `state/prompts/_fleet/rules.md` is the canon for
the box `~/.claude/CLAUDE.md` instead of the checkout's `rules/CLAUDE.md`. The
`CLAUDE.local.md` append is unchanged. A missing, empty or directory path, a
stray `.tmp` file or a project `rules.md` never picks the fleet file.
`rules_canon_path` in `bin/lib/rules-canon.sh` decides, and the four readers of
the canon use it:

- `bin/update-runners.sh` (the `machine rules` block, daily);
- `bin/sync-agent-rules.sh apply` (harness-sync, the context-gate self-heal,
  and this push);
- `bin/context-signature.sh` (the `machine_rules_in_sync` reference);
- `bin/rules-drift-check.sh` (the probe, with the same rule inline because it
  runs on the far box; its third column stays the checkout canon).

A project `rules` head goes to `state/prompts/<project>/rules.md`, and
`sp_render` points the build at it (see `## Stage prompt files`).

### The build note

`bin/lib/rb/result.sh` appends seven lines to `$BUILD/evidence.md` right after
it writes the file, before `job_evidence_put` and the pool fan-back read it
(`bin/lib/prompt-note.sh`, `prompt_note_append`). The lines are not in the PR
body. Kinds are in the fixed order:

```
PROMPT review: project v1 (7)
PROMPT rules: fleet v12 (40)
PROMPT plan: repo default (3f2a9c1b0d4e)
```

A `repo` line, a kind with no line, or a malformed line (not four fields, a
version that is not `v<n>`, an id that is not a number, a CR at the end) gives
`repo default (<sha12>)`: the first 12 hex digits of `git hash-object` of the
repo file (rules: `<checkout>/rules/CLAUDE.md`; watcher:
`<harness>/prompts/<project>.md`; a stage kind:
`<harness>/prompts/stages/<kind>.md`), or `repo default (no file)`. The first
line of a kind wins. With no `sources.tsv`, all seven lines are
`PROMPT <kind>: repo default`. A failure is one `pipeline.log` line and never
changes the build verdict.

Limit: a pool machine gets no `state/prompts/` in this slice. A pool build uses
the repo templates, and its note says `repo default` seven times.

## Markers, versions and restore (BH-7940.4)

Owner: BH-7940.4.

## Console (BH-7940.5)

Owner: BH-7940.5.

Two settings pages show the seven kinds and edit one:

- Settings · Fleet · Prompts, `/settings/fleet/prompts`: the fleet heads.
- Settings · `<project>` · Prompts, `/settings/p/<project>/prompts`: what the
  project gets, with the source of each row (`repo default`, `fleet override`
  or `project override`).

Click a kind to open the editor on the same page (`?kind=<kind>`). The editor
shows:

- The body in a full-width textarea. It starts from this scope's head. A
  project with no head starts from the fleet head, else empty.
- A line diff against the previous version of this scope.
- A line diff against the level above: the fleet head for a project. For the
  fleet, or a project with no fleet head, the level above is the repo file. The
  console has no route to read that file, so the panel names it and says so.
- The marker lint from `catalog/prompt-markers.json`. It shows only for a kind
  with markers. The server lint is the authority: a 422 names each missing
  marker.
- SAVE opens the confirm modal. A note is required. The save sends
  `base_version`, so a save on a stale version is a 409 and writes nothing.
  After a save the page goes back to the list.

The code is `console-ui/src/screens/Prompts.js`, `console-ui/src/ui/PromptEditor.js`
and `console-ui/src/lib/prompts.js`. The editor renders `PromptVersionsSheet` and
`UseLevelAboveButton` from `console-ui/src/ui/PromptHistoryActions.js`.
