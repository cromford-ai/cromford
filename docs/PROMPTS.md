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

## Hub render and build note (BH-7940.3)

Owner: BH-7940.3.

## Markers, versions and restore (BH-7940.4)

Owner: BH-7940.4.

## Console (BH-7940.5)

Owner: BH-7940.5.
