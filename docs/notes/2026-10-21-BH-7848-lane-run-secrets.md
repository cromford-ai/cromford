# The lane app's secret list (BH-7848, rest of BH-7432)

Doc: PROJECT-LANES

## What changed

The secrets a lane-run group app must hold for a lane are now data, not only
prose. Before this change they lived in two prose copies: the comment block in
`fly/lane-run.toml` and the `app-secrets` alert text in `bin/lane-fleet.sh`.

- `catalog/lane-run-secrets.d/<lane>.tsv` is the list. One file per lane. The
  first one is `fly-pool.tsv`. Tab-separated, `#` comments, 4 fields:
  `name need hub_source note`.
  - `name` holds one placeholder at most: `<PROJECT>` (upper case, `.` and `-`
    as `_`, the `bin/lib/fly-token.sh` rule) or `<OWNER>` (the fleet.conf repo
    owner, the same rule).
  - `need` is `required` or `optional`.
  - `hub_source` is `<envfile>:<VAR>` (a variable in a file in the hub env
    dir) or `file:<envfile>` (the text of a file in the hub env dir).
  - Values never go in the list.
- `bin/lane-run-secrets.sh` is the one reader. It never reads a value.
  - `bin/lane-run-secrets.sh fly-pool <project>...` prints one line per
    secret, `<NAME> <need> <hub_source>`, expanded for each project, sorted
    and de-duplicated.
  - `bin/lane-run-secrets.sh --stage-cmd <app> fly-pool <project>...` prints
    one command for the hub. The command sources the hub env files and pipes
    `NAME=value` lines into `flyctl secrets import -a <app> --stage`. A value
    is never in argv and never on screen. The command stops before it sends a
    line if a required variable is empty. An unset optional variable sends no
    line. A `file:` row (the multi-line App key) gets a `#` line: stage it by
    hand.
  - rc 2 on bad input (an unknown lane, a project with no fleet.conf repo, a
    row without 4 tab fields, a `need` other than `required`/`optional`). The
    message names the list line. stdout is empty.
- The toml comment and the `app-secrets` alert now point to the reader.

The `fly-pool` list for project-6-os:

```
FLY_API_TOKEN_project-6_OS required fly.env:FLY_API_TOKEN_project-6_OS
GH_APP_ID required github-app.env:GH_APP_ID
GH_APP_INSTALLATION_example-org optional github-app.env:GH_APP_INSTALLATION_example-org
GH_APP_PRIVATE_KEY required file:github-app.pem
HARNESS_SECRET required global.env:HARNESS_SECRET
JOBS_URL required global.env:JOBS_URL
```

Each `hub_source` comes from the hub's own readers: `fly.env` from
`bin/lib/fly-token.sh`, `github-app.env` and `github-app.pem` from
`bin/gh-token.sh`, and `global.env` from `bin/lib/jobs/req.sh`. The list does
not change the preflight words of `bin/fly-pool-project.sh` or any pool tick.

The agent CLI secrets (`CLAUDE_CODE_OAUTH_TOKEN`, `CODEX_AUTH_JSON`,
`CODEX_CONFIG_TOML`, BH-6260) are not on the `fly-pool` list. The pool tick
does not read them. `fly/lane-run.toml` still names them for the lane-run app.

## Operator steps

1. On the hub, print the list: `bin/lane-run-secrets.sh fly-pool project-6-os`.
2. On the hub, print the staging command:
   `bin/lane-run-secrets.sh --stage-cmd lane-run-mk fly-pool project-6-os`.
3. Read the command, then run it on the hub. No secret value is shown on
   screen.
4. Stage `GH_APP_PRIVATE_KEY` by hand from the hub's `github-app.pem`, as the
   `#` line says (`fly/lane-run.toml`).
5. Rebuild nothing. The entrypoint reads the secrets at boot.

## Metric owed (#7848 "metric over 24 h after the flip")

This is a measurement after a go-live step, not code. The numbers are not in
this change.

1. An operator sets `lane_placement.fly-pool.project-6-os = fly` when the
   lane-run-mk app passes `--preflight` (today it answers `missing
   env-bundle` until BH-6896 S3).
2. Record the flip time T.
3. After T + 24 h, read the #6882 samples (`state/hub-load/*.tsv`) from T to
   T + 24 h. Post on #7848 the hub CPU per project tick (target at most
   0.05 CPU s, from about 0.85) and the runnable share of the pool supervisor
   (target under 2 percent).
4. Close #7848 only after that comment.

## Tests

`tests/lane-run-secrets.bh-7848-test.sh`: L1-L2 (the list, and a round trip
with the real `fly/lane-run-entrypoint.sh`), R1-R6 (the reader, the refused
rows, the real reader over the real list), S1-S3 (the stage command run with a
fake flyctl against fixture env files; no value in any output).
