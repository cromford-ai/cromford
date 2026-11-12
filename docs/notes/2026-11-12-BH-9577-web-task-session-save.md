# The web-task lane saves the browser session after a sign-in (BH-9577)

Doc: DB-COORDINATION-SPEC

## What changed

This is R1b of #7597 (S4, saved browser sessions): "Hook the save after a
successful sign-in". #8908 (BH-7597 C0) added the store: the routes
`POST /api/web-session/save|load` and the client `bin/lib/web-session.sh`.
It did not call the save, because the sign-in step had no production caller
then. BH-8250 wired `sign_in` and `type_otp` into the agent, so the hook
can now go in.

1. `bin/web-task-agent.mjs` has a new flag `--session-dir <dir>`. When the run
   ends `done` and at least one `sign_in` action has an `ok:` outcome, the
   agent writes `ctx.storageState()` (cookies and local storage) to
   `<dir>/storage-state.json`, mode 600, before the browser closes.
   - The export waits at most `--close-timeout-s` (knob
     `WEB_TASK_CLOSE_TIMEOUT_S`). No new knob.
   - No file when the flag is absent, the path is not an existing directory,
     the directory is `--out` or inside it (real paths, so a symlink into
     `--out` is refused), the file exists already, or the export fails.
   - A `step-cap`, `time-cap`, `refused-spend` or `error` run writes nothing,
     also after an ok sign-in. A 2FA site is saved only after the run is done,
     so the session holds the state after `type_otp`.
   - The session is never in `result.json`, the result line, stdout or stderr.
2. `bin/lib/web-task/session.sh`: `wt_session_save <project> <site> <file>` is
   `wsess_save` of `bin/lib/web-session.sh` (it sources that lib on the first
   call). Same return codes. If the lib cannot be sourced: "not available",
   rc 69. `wt_session_load` is still the stub.
3. `bin/web-task.sh` step 8:
   - Before the agent: `mktemp -d ${TMPDIR:-/tmp}/web-session.XXXXXX` (mode
     700) and `--session-dir <that dir>`. If mktemp fails, the agent gets no
     flag and the run goes on. An EXIT trap removes the dir.
   - After the agent and the unlabel: when the status is `done`, `VAULT_SITE`
     is a host (a `sign_in` ended ok) and the file is not empty,
     `wt_session_save "$P" "$VAULT_SITE" <file>`. Its output goes nowhere.
     One line in `logs/web-task.log`: `session: saved <site>` on rc 0, else
     `session: not saved (rc N)`. Then the dir is removed.
   - The comment, the status, the labels and the exit code do not change. A
     failed save only means the next run signs in again. No alert.

## What is still open

A saved session is not used yet. No run loads it. These items of #7597 are
not in this change:

- R2: a new run loads the saved session first (`wt_session_load`, then
  `browser.newContext({storageState})`).
- R2b: the run lands on a sign-in page anyway, so it signs in again.
- R5: the 3-run test (sign in, reuse, expiry).
- R6: the real 2FA proof on a live site.

Until R2 ships, each save replaces the one `web_vault` row of
(project, site, `session_state`) and nothing reads it.

## Tests

`tests/web-task-session.bh-9577-test.sh`: A1-A6 drive the real agent and
chromium on the fixture sign-in site, S1-S3 the seam (S1 is a round trip
through the real jobs worker), L1-L7 the real lane with a stub save client.
`tests/web-task-route.bh-7594-test.sh` Z no longer pins `wt_session_save` as a
stub; it pins that a bad call never answers rc 0.
