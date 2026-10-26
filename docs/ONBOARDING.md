# Onboarding runs (BH-7934)

An onboarding run adds one project to the fleet. The console's "add a project"
form creates the run. The `onboard-run` hub lane runs it, one station at a
time, and the setup screen shows each station's state.

- Tables: `onboarding_runs` and `onboarding_steps`
  (`worker/jobs/schema.d/202610220114-bh-7934-onboarding-runs.sql`).
- Create and read: `POST /api/onboarding/runs`, `GET /api/onboarding/runs/:id`
  (`worker/jobs/src/routes/onboarding.js`, BH-7934.0).
- Runner reads and writes: `GET /api/onboarding/runs?state=|?project=` and
  `POST /api/onboarding/runs/:id/beat`
  (`worker/jobs/src/routes/onboarding-runner.js`, BH-7934.2).
- Runner: `bin/onboard-run.sh [run-id]`, lane `onboard-run`
  (`catalog/lanes.d/onboard-run.json`, `cron/lanes/745-onboard-run.cron`).
- Station functions: `bin/lib/onboard-stations.sh` (BH-7934.1).

## Run model

```
create -> queued -> (claim) -> running -> done
                                       -> failed    (a station failed)
                     any state not done -> cancelled (the cancel action)
                     failed -> (retry) -> queued
```

1. The form posts the inputs. The worker writes the run `queued` and its 7
   steps `queued`. The Idempotency-Key names the run, so a double submit makes
   one run.
2. The lane runs every minute on the hub. It picks the oldest `queued` run and
   claims it: `UPDATE ... SET state='running' WHERE id=? AND state='queued'`.
   A second runner gets 409 `not_queued` and stops.
3. For each `queued` step in `ord`, the runner beats `running`, runs the
   station, then beats `done` or `failed`.
4. The `done` beat of station `ready` sets the run `done`. A `failed` beat
   sets the run `failed` and every later `queued` step `skipped`.

## States

| Run state | Meaning |
|---|---|
| `queued` | Created or retried. No runner has it. |
| `running` | A runner claimed it. `station` is the last station beaten. |
| `done` | Every station is done. `finished_at` is set. |
| `failed` | One station failed. `station` names it. `finished_at` is set. |
| `cancelled` | Cancelled by an operator. A runner stops at its next beat. |

| Step state | Meaning |
|---|---|
| `queued` | Not run yet, or set back by a retry. |
| `running` | The runner beat `running` and the station has not ended. |
| `done` | The station returned 0. Never run again. |
| `failed` | The station returned non-zero. `error_code` and `log_excerpt` say why. |
| `skipped` | A station before it failed. A retry sets it back to `queued`. |

`log_excerpt` is the last 4096 bytes of the station's output (stdout and
stderr), cut on a UTF-8 character boundary. The worker cap is the settings row
`onboarding.log_excerpt_max_bytes`; the runner sends the tail size of its lane
knob `ONBOARD_RUN_EXCERPT_BYTES`.

## Stations

| ord | Station | Function | What it runs |
|---|---|---|---|
| 1 | `register` | `obs_register` | `bin/registry.sh add-project` (REGISTRY_SOURCE=db) or the `fleet.conf` row |
| 2 | `prompt` | `obs_prompt` | renders `prompts/<project>.md`, commits and pushes it |
| 3 | `label` | `obs_label` | `gh label create ai-build` on the repo (tracker `github-issues`) |
| 3 | `tracker` | none | fails `tracker_not_built` until the tracker connect ships (wave 3) |
| 4 | `box` | `obs_box` | the env stub and the crontab block on the box |
| 5 | `clone` | `obs_clone` | `bin/bootstrap-machine.sh <project> --repos-only` |
| 6 | `smoke` | `obs_smoke` (in `bin/onboard-run.sh`) | reads only: see below |
| 7 | `ready` | none | beats `done`, which sets the run `done` |

Station 3 is `label` when the tracker is `github-issues`, else `tracker`.

The runner sets these globals from the run's inputs before it sources the
station lib: `PROJECT`, `SLUG` and `REPO` (the repo), `PROD` (`-` when
absent), `BOX`, `PREFIX` and `PREFIX_LC`, `BASE`, `TRACKER`, `ROOT`.
`REGISTRY_SOURCE` comes from `env/global.env`. `box=shared` resolves to the
lane knob `ONBOARD_SHARED_BOX`, or to `${HARNESS_BOX_PREFIX}small` when the
knob is empty. A missing `prefix` is derived the way `bin/load-project.sh`
derives it (the initials of the project name's segments). The runner arms the
repo's App token with `gh_auth_for` (`bin/lib/gh-app-auth.sh`).

If the station lib does not define a station's function, the step fails with
`station_failed` and its excerpt says `obs_<station> is not defined`. It is
never `done`.

`obs_smoke` runs every check, prints one line per check, and returns 1 if one
check fails:

1. `prompts/<project>.md` exists.
2. `bin/fleet-conf.sh <project> offset` prints an integer.
3. A one-page REST issue list (`gh_rest_issue_list` in `bin/lib/gh-rest-list.sh`) answers 2xx (the App token).
4. `bin/postmerge-qa.sh <project> --dry-run` returns 0.
5. If `prod` is set: `bin/healthcheck.sh <project>` returns 0.

## Retry and cancel

- Retry (the setup screen's action, BH-7950) sets a `failed` run back to
  `queued`, and its `failed` and `skipped` steps back to `queued`. The next
  tick claims it and runs only the `queued` steps, so the retry starts at the
  failed station. A `done` step is never run again. The worker refuses a
  `running` beat on a `done` step (409 `bad_transition`).
- Each station is idempotent: a registry row that exists is kept, an empty
  prompt diff is not committed, `gh label create` accepts "already exists",
  the env stub and the crontab block are written whole, and `--repos-only`
  skips a clone that exists. So a retry after a partial station is safe.
- Cancel (BH-7950) sets the run `cancelled`. Every beat on a cancelled run
  answers 409 `cancelled`. The beat's writes and the run write are one batch,
  each guarded by "the run is running", so a cancel that lands between the
  runner's read and its write wins. The runner logs `cancelled <id> at
  <station>` and exits 0 at its next beat. A station that is already running
  ends first; its step stays `running`.
- A run that stays `running` with no beat for `ONBOARD_RUN_STALE_MIN` (30)
  minutes gets one warn alert per run per UTC day, id
  `onboard-run:stale_run:<id>:<date>`. A runner that crashed mid-station
  leaves its step `running`, never `done`.

## error_code and the fix link

`obs_error_code` in `bin/onboard-run.sh` reads the station's output and gives
the step one code. The first row that matches wins. The code only picks the
fix link on the setup screen. It never starts an action.

| error_code | Matches | Fix |
|---|---|---|
| `app_no_issues_write` | `HTTP 403` or `Resource not accessible by integration` on a line that names `label` or `issues` | Give the GitHub App issues write on the repo: https://github.com/settings/installations |
| `box_unreachable` | `Could not resolve hostname` | Check the box name and that it is up: `bin/fleet-conf.sh <project> box`, `docs/ADDING-A-BOX.md` |
| `registry_token_missing` | `REGISTRY_ADMIN_TOKEN is unset` | Set `REGISTRY_ADMIN_TOKEN` in the hub's `env/global.env`, then retry |
| `prompt_push_rejected` | `failed to push some refs` or `! [rejected]` | Pull the harness repo on the hub, then retry |
| `repo_not_found` | `Repository not found` or `Could not resolve to a Repository` | Check the repo name and that the App is installed on it |
| `tracker_not_built` | the `tracker` station, always | The tracker connect is wave 3. Use tracker `github-issues` until then |
| `station_failed` | anything else | Read the step's log excerpt |

These near misses are `station_failed`, on purpose: `label "ai-build" already
exists`, `API rate limit exceeded`, `ssh: connect to host ... port 22:
Connection timed out`, and an `HTTP 403` on a line with neither `label` nor
`issues`.

## The runner lane

`bin/onboard-run.sh [run-id]`. With no argument it picks the oldest queued run.

| Exit | When |
|---|---|
| 0 | idle, done, claim lost, or cancelled |
| 1 | a station failed (the run is `failed`) |
| 2 | the worker is not configured, did not answer after `ONBOARD_RUN_TRIES` attempts, or refused a request; one alert |
| 64 | the argument is not `ob_<20 hex>` |

Log lines, `logs/onboard-run.log`: `idle`, `claim-lost <id>`, `not-found <id>`,
`step <id> <station> <done|failed> rc=<n> secs=<n>`, `failed <id> at <station>
code=<code>`, `cancelled <id> at <station>`, `done <id> <project>`, `stale
<id>`, `worker-failed (<status>)`, `not-configured (<why>)`.

Knobs (settings rows `lane.onboard-run.<env lowercased>`): `ONBOARD_RUN_TRIES`
(3), `ONBOARD_RUN_STALE_MIN` (30), `ONBOARD_RUN_STALE_LIST` (20),
`ONBOARD_RUN_EXCERPT_BYTES` (4096). `ONBOARD_SHARED_BOX` is set in
`env/global.env` only. Off: `bin/harness-ctl.sh off onboard-run`
(`flags/lane-off-onboard-run`).

Cron: `hub-lease.sh check && flock -n locks/onboard-run.lock`. The flock is
dedupe: a long run makes the next ticks skip, it never queues them.

## Relation to bin/load-project.sh

`bin/load-project.sh` is the operator's CLI for the same work. It and the
runner call the same station functions from `bin/lib/onboard-stations.sh`, so
a CLI run and a lane run of one project give the same rows. The CLI stays the
operator path for a project the form cannot express (a dedicated box, a
readiness gate). The lane writes no file of its own: all run state is in D1.

## Retention

| Settings row | Default | Rule |
|---|---|---|
| `onboarding_runs_retention_days` | 30 | `onboarding_runs.finished` in `worker/jobs/src/routes/retention.js` |

The `d1-retention` lane (hourly) deletes a `done`, `failed` or `cancelled` run
and its 7 steps once its `updated_at` is older than the window. A `queued` or
`running` run is never deleted. The step delete and the run delete re-check
the state, so a run a retry set back to `queued` keeps its rows. The rule
writes one `retention_runs` row per run. While `retention.dry_run` is 1 (the
seed) it only counts.

Other settings rows: `onboarding.log_excerpt_max_bytes` (4096) and
`onboarding.list_limit_max` (20), read by the runner routes.
