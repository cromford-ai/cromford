# The shipped console gets a browser QA run after each Pages deploy (BH-5909, slice 3)

Doc: MERGE-CONDUCTOR

## What runs, and when

`bin/console-pages-deploy.sh` ships a console-ui commit to Pages production.
After its two anonymous probes, when `CONSOLE_POSTMERGE_QA` is 1, it does two
things:

1. It copies the `dist/` it just uploaded to
   `state/console-postmerge-qa/dist-<40 hex sha>/` (a temp name, then a rename).
2. It starts `bin/console-postmerge-qa.sh <sha> <that dir>` detached, in its own
   session, under `timeout -k 30 $CONSOLE_POSTMERGE_QA_TIMEOUT_S`. The output
   goes to `logs/console-postmerge-qa.log`. The deploy log says
   `post-merge QA launched at <c7>`. That line means only that the run started.

The QA run:

1. Refuses a sha that is not 40 hex, and any dist path other than
   `state/console-postmerge-qa/dist-<sha>`.
2. Reads the knob again. If it is off, it removes the kept dist and stops.
3. Takes `locks/console-postmerge-qa.lock` with `flock -n`. If the lock is held,
   it stops and keeps the dist. A later run prunes a dist older than 1 day.
4. Stops before any network call when `state/console-postmerge-qa/<sha>/verdict`
   exists.
5. Builds a deploy tree from the kept `dist/` and the `functions/` and `src/` of
   the same commit (`git archive`).
6. Uploads it with the pinned wrangler (`CONSOLE_PREVIEW_WRANGLER`, 3.114.17) to
   the branch alias `postmerge-qa`. It never uses `--branch main`.
7. Mints a read-only QA session (`POST /api/qa/session`, the same route as
   slice 1).
8. Runs `bin/console-qa-run.mjs` with `CONSOLE_QA_WIDTHS=1280,375` over
   `CONSOLE_POSTMERGE_QA_SCREENS`.
9. Writes the verdict, then posts one comment on the merged PR, then raises or
   resolves one alert.

## Why an alias and not the production host

`console-ui/functions/qa-login/[token].js` refuses the production host, every
`<8 hex>` deployment URL and the `main.` alias. So the QA session never signs in
on production, and a drive there sees only the sign-in wall. This slice does not
loosen that guard. It deploys the same shipped bytes a second time to the fixed
alias `postmerge-qa`, which passes the guard. `cpv_alias` in
`bin/lib/console-preview.sh` refuses `postmerge-qa`, so no PR branch can deploy
over it.

The limit: an alias runs in the Pages PREVIEW environment, not the production
one. Slice 1's preview QA runs in the same environment. The PR comment states
this in one line.

## The verdict, the marker, the alerts

`state/console-postmerge-qa/<sha>/verdict` holds one line:

- `PASS`: the driver exited 0, printed `QA: PASS`, and its `QA COVERAGE` line
  has screens and shots of 1 or more.
- `FAIL`: the driver observed at least one screen, and the result is not PASS.
- `NOT_COVERED <reason>`: nothing was observed. The reason is one of these:
  the deploy tree failed, the alias deploy failed, no QA session was minted,
  the drive printed no `QA COVERAGE` line, or the drive observed no screen.

The comment goes on the PR whose `merge_commit_sha` is the console-ui sha. It
carries `POST-MERGE QA: <result> at <sha>` and the marker
`<!-- console-postmerge-qa sha=<sha> result=<result> -->`. A marker for the sha
on the PR stops a second comment. The comment never has a line that starts
`QA: PASS` or `QA: FAIL`, so the slice 2 gate (`bin/lib/console-qa-gate.sh`)
never reads it as a QA result.

Alerts, lane `fleet-propagate`:

| Result | Alert |
|---|---|
| FAIL | warn `console-postmerge-qa` (the sha, the first failure, the qa.md path) |
| NOT_COVERED | warn `console-postmerge-qa-notcovered` (the reason) |
| PASS | resolves both |
| GitHub rejected the comment | warn `console-postmerge-qa-post` |

The report directories are pruned after 14 days.

## Knobs

Three settings rows, as fragments in `catalog/lanes.d/fleet-propagate.knobs.d/`:

- `CONSOLE_POSTMERGE_QA`: default 0, which is off.
- `CONSOLE_POSTMERGE_QA_SCREENS`: default
  `/ /now /kanban /jobs /t/BH-5909 /machines /lead-reviews`. The paths are
  space-separated and never globbed. `/machines` is the fleet screen.
- `CONSOLE_POSTMERGE_QA_TIMEOUT_S`: default 900. A value outside 120..3600
  writes one log line and uses 900.

`bin/console-qa-run.mjs` reads `CONSOLE_QA_WIDTHS` (from 1440, 1280, 390 and
375). With no value it keeps 1440 and 390, so slice 1's preview lane does not
change.

## Turning it on

1. Deploy cromford-console #46 (the `POST /api/qa/session` route). Until
   then every run ends `NOT_COVERED no QA session minted`.
2. Set `lane.fleet-propagate.console_postmerge_qa` to 1.
3. Read the first post-merge comment on the next console PR that merges.
