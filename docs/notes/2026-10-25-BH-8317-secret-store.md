# BH-8317 (MKF-2): a Fly-secret store for project build secrets

Ticket: BH-8317 (MKF-2, part of #8315, order 2 of 10). Decision D1-a (the operator,
2026-10-25): Fly app secrets are the store. The hub can set a secret and can
never read it back.
Spec: `docs/notes/2026-10-19-BH-7430-pool-secrets-sync.md` (the HBUNDLE_* pull path),
`docs/notes/2026-10-25-MKF-1-pull-path-project-6.md` (the ssh-off guard).
Doc: none

## What changed

- `bin/project-secrets.sh` (new operator verb, run on the hub):
  `set <project> <NAME> [--apps a,b] [--need required|optional]`, `unset`,
  `list`, `verify` and `import`. The usage, the exit codes and the rules are in
  its header.
- The jobs worker keeps only the NAMES: D1 table `project_secret_names`
  (`worker/jobs/schema.d/202610260157-bh-8317-project-secret-names.sql`, PRIMARY
  KEY (project, name), INDEX (project, set_at)) and the routes
  `GET`, `PUT` and `DELETE /api/project-secrets/names` (`worker/jobs/src/routes/project-secrets.js`).
  No column and no route body can hold a value; a PUT with a `value` or
  `secret` field is a 400.
- Every PUT that changes a row and every DELETE writes one `config_changes` row
  of the new kind `project_secret` (name `<project>/<NAME>`) in the same D1
  batch. The console Config screen lists them under that kind.
- `bin/fly-pool-secrets-sync.sh <project> --no-box` rewrites only `HBUNDLE_G_*`
  on the pool app, from the hub's own `env/global.env`, through the one
  whitelist in `bin/fly-envbundle.sh` (new third argument `--hub-global`). It
  makes 0 ssh calls and 0 `gh-token.sh` calls, it reads no `<project>.env`, and
  it never imports or unsets an `HBUNDLE_P_*` name. The default (ssh) mode does
  not change.
- Two settings rows: `project_secrets.list_limit` (500) and
  `project_secrets.fly_timeout_s` (120).

## The rules

- The value goes only to flyctl's stdin, through the bash `printf` builtin. It is
  in no argv, output, log, alert or worker row. One line, not empty, no single
  quote. A value outside `[A-Za-z0-9_./:@+,=-]` is written in single quotes.
- Staged name: `HBUNDLE_P_<NAME>` on the pool app (`state/fly/<p>.json .app`),
  which `fly/entrypoint.sh` turns back into `<NAME>` in `<project>.env`; the
  plain `<NAME>` on any other app.
- `set` order: PUT the row without a stamp, stage into each app, read each
  digest back with `fly secrets list`, then PUT with `stamp:true`. A failure at
  any step leaves `set_at` as it was, so `verify` and `list` show the gap.
- `verify` exits 0 only when the manifest has rows, is not truncated, every
  app's list was read, and no required name is missing.

## QA_CLERK_* (which stages read them)

`QA_CLERK_SECRET_KEY` and `QA_TEST_USER_ID` are read by three stages that run
on a pull-path pool machine, from the `<project>.env` that `fly/entrypoint.sh`
composes from `HBUNDLE_P_*`:

1. `bin/lib/rb/pr.sh` (`QA_PROMPT_FOR`): the preview QA stage of a build.
2. `bin/e2e-smoke.sh`: the lead-review e2e smoke, called from `bin/lib/rb/review.sh`.
3. `bin/lib/prebuild-repro/drive.sh`: the pre-build repro drive.

`bin/postmerge-qa.sh` reads them too, but `catalog/lanes.d/postmerge-qa.json`
puts that lane on no project-6 box, so it is inert for project-6-os.
`bin/qa-session.sh`, `bin/qa-clerk-ban.sh` and `bin/qa-wiring-check.sh` are hub
operator tools that read `env/<p>.env` on the hub; this change does not touch
them. So both names must be `HBUNDLE_P_*` on `pool-project-6-os`. Steps 4 and 6
of the runbook below put them there. Removing the plaintext copy from the hub's
`env/project-6-os.env` is a later MKF child.

## Operator runbook (project-6-os, one time)

1. If `pool.envbundle_ssh.project-6-os` is `off`, set it to `on` for the import.
2. Run `bin/fly-pool-secrets-sync.sh project-6-os` (ssh mode, the last ssh to project-6-os).
3. Run `bin/project-secrets.sh import project-6-os`. Expect `imported=<n> kept=0 skipped=0`.
4. Run `grep '^QA_CLERK_SECRET_KEY=' env/project-6-os.env | cut -d= -f2- | bin/project-secrets.sh set project-6-os QA_CLERK_SECRET_KEY`.
   Run the same for `QA_TEST_USER_ID`.
5. Set `pool.envbundle_ssh.project-6-os` back to `off`.
6. Run `bin/fly-pool-secrets-sync.sh project-6-os --no-box`, then
   `bin/project-secrets.sh verify project-6-os`. Expect rc 0 and
   `verify/project-6-os: ok (...)`.

## Retention

A `project_secret_names` row lives while its secret exists. `unset` deletes the
row; the `config_changes` audit row stays (append-only, never deleted). The
table holds tens of rows per project and does not grow with traffic, so it has
no sweep.

## Tests

`tests/project-secrets.bh-8317-test.sh`, `tests/fly-pool-secrets-sync-no-box.bh-8317-test.sh`,
`worker/jobs/test/project-secrets.bh-8317.test.js`,
`worker/jobs/test/project-secrets-explain.bh-8317.test.js` (EXPLAIN at 10,000 rows).
No test calls real Fly, GitHub, Orgo or Claude: fly, flyctl, curl, ssh and gh
are stubs, and the suites assert that no real network tool is on their PATH.
