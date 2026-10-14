## Driving conventions

- **Drive the real script, never a paraphrase of it.** The suites under `tests/`
  extract the production block VERBATIM by its `# >>> name` / `# <<< name`
  markers, or run the whole script against a scratch `$HARNESS`. A test that
  restates the logic passes while the lane is broken.
- **Assert on artifacts, never on source text.** What a check is worth is the
  contents of `logs/ALERTS.log`, `logs/pipeline-health.log` and the files under
  `state/` — grepping the script for a string proves only that somebody typed it.
- **Pin the clock.** Every fixture age comes from one `NOW=$(date +%s)` read
  (`bin/test-determinism-lint.sh` enforces this). A suite that reads the wall
  clock twice picks its own red day.
- **Fail-open is the property under test.** For anything that can SUPPRESS an
  alert, the negatives carry the weight: an API outage, a missing row, an
  unparseable record must all still page. Test those before the happy path.
- **Non-destructive only.** These lanes write to the coordination DB and the
  console. Fixtures run against a `mktemp -d` tree with stubbed `curl`/`ssh`/`gh`;
  nothing in `tests/` may touch a real box or a real ledger.
- **run-build's marker blocks live in `bin/lib/rb/`.** Since the BH-572 cut
  `bin/run-build.sh` runs its stages as bare `rb_<name>` calls, so its marker
  blocks live in `bin/lib/rb/` and suites read them through `tests/lib/rb-all.sh`
  (`$RB_ALL`, the pipeline as one text), never by grepping the driver.
- **Run the suite the safe way.** [tests/README.md](../../tests/README.md) has the runners, the root guard, and how to read the two safety lanes above.

## Generated files

Machine-written; regenerate, never hand-edit. `bin/batch-resolve.sh` and
`mc_regen_table` read this table **from this file** — since BH-1175 the index
below is not committed, so a parser pointed only at the rendered README would
find nothing and the batch merge train would switch itself off. Nothing may
follow this table in this file but more rows.

The index is git-ignored: a regenerate refreshes the working tree and stages
nothing, which is the point. What a build commits is its own
`docs/verification-map/entries/<TICKET-KEY>.md`.

**And since BH-1247 so is every other row below.** The ten crontabs,
`catalog/lanes.json` and `env-templates/global.env.example` were committed
renders until that ticket, which made each of them a shared mutable cell every
build wrote: a PR that edited a lane and did not re-render turned red, and once
it merged every other open PR inherited the red on a file its ticket never
mentioned (three merge trains, 2026-09-21). They are git-ignored now. The rows
stay here because this table is also where an operator reads how to rebuild one
— and because the table is what switches this repo's batch merge train on
(BH-865) — but nothing in it can conflict any more, so the train never has to
resolve one. Adding a lane is a file under `catalog/lanes.d/` and a file under
`cron/lanes/`, and nothing else.

**Every path here is literal — no globs.** `bin/batch-resolve.sh`'s
`regen_cmd_for` and `path_allowed` match with shell `case`, where `*` crosses
`/`, so a `cron/*.cron` row would also claim `cron/lanes/<lane>.cron`. A
conflicted path with a regenerate command is resolved by taking one side
(`git checkout --theirs`), which for a hand-written FRAGMENT would drop one
approved PR's cron change with the render and every check still green. The ten
crontabs are therefore written out one by one; they all rebuild with the same
command.

**But do not run that command inside a box checkout** (BH-1247). It writes the
ten git-ignored `cron/<box>.cron` into the tree, where `git status` will not
show them and `git pull` will never remove them. `bin/render-crontab.sh` refuses
to use such a file while `cron/lanes/` is present, so a box still installs the
right crontab — but the files have no reason to exist there. To SEE a render,
use `bin/render-cron.sh <box>`, `bin/render-cron.sh --out-dir <dir>` or
`bin/render-diff.sh`.

**Three rows here are still COMMITTED. The first is `rules/CLAUDE.md`** (BH-1336). It is rendered
from `rules/topics/` by `bin/render-rules.sh`, and five scripts copy it verbatim
onto every box and every builder — `bin/update-runners.sh`,
`bin/sync-agent-rules.sh`, `fly/builder-runner.sh`, `bin/rules-drift-check.sh`
and `bin/context-signature.sh` — so it cannot leave git until they render it
themselves (BH-1336 workstream B). It is in this table anyway, because a
committed render is exactly the file a train or a rebase would otherwise HAND
MERGE: with the row, a conflict on it is resolved by taking one side and running
`bin/render-rules.sh --write` over the merged topics, which is drift-free and
keeps both siblings' edits. It needs no merge attribute for the same reason —
union-concatenating a document with a generated table of contents produces a
file nobody wrote. `docs/PR-OWNERSHIP.md` (BH-5235.2) is the second committed
render, for the same reason: `bin/pr-owner-sweep.sh`, `bin/lib/pr-health.sh`
and the docs link it by path and readers browse it on GitHub, so it stays in git, and a conflict on it is resolved
by `bin/render-doc-sections.sh --write` over the merged `docs/PR-OWNERSHIP.d/`.

**`worker/jobs/schema.sql` is NOT in git** (BH-6005). It is composed from
`worker/jobs/schema.d/NNNN-<name>.sql` by `bin/schema-build.sh` and is
git-ignored: committed, it was the factory's most frequent merge conflict. Each
reader composes it where it reads it: `bin/harness-sync.sh`'s deploy (`--to`
into its snapshot, before the D1 apply and `wrangler deploy`), CI and the lints
(`--ref` for a base revision), and the test corpus (`tests/lib/jobs-schema.sh`,
`worker/jobs/test/lib/jobs-schema.js`). `bin/schema-build.sh --check` refuses it
back in git. Its row below is unmarked, so a build's diff never carries it.

The third column says so. A row marked `committed` is a render this repo's CI
checks, so a build commits it; an unmarked row is reset out of a build's diff
by the `# >>> generated no-commit` block of `bin/run-build.sh` (unless the diff
is nothing but declared files), because the conductor regenerates it on merge
(BH-1680). The merge readers ignore the
column.

| path | regenerate with | committed |
| --- | --- | --- |
| `docs/verification-map/README.md` | `bin/verification-map-build.sh` |
| `cron/project-4.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/hub.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-6.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-1.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-3.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-10.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-9.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/small.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-2.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `cron/project-5.cron` | `bin/render-crontab.sh --from-fragments --all --write` |
| `env-templates/global.env.example` | `bin/render-env-example.sh --write` |
| `catalog/lanes.json` | `bin/lanes-build.sh --write` |
| `rules/CLAUDE.md` | `bin/render-rules.sh --write` | committed |
| `docs/PR-OWNERSHIP.md` | `bin/render-doc-sections.sh --write` | committed |
| `worker/jobs/schema.sql` | `bin/schema-build.sh --write` |  |
