# A board pause says when it ends, and a flag flip leaves a trace

Doc: DB-COORDINATION-SPEC

The console's `pause_board` sent no `ttl_s`, so the jobs worker applied its generic `pause_default_ttl_s` (86400) and the triage pause row lapsed 24 hours after the last pause. Nothing on the command, the board or ALERTS said when.

- `bin/poll-commands.sh` `pause_board`: a payload `ttl_s` still wins. With none, it sends `PAUSE_BOARD_TTL_S`, a poll-commands settings row (default 604800, the worker's one-week ceiling; a value that is not a positive integer falls back to it). The RESULT is `paused until <expires_at>`, the expiry the worker stored after its clamp, read from `JOBS_BODY` and echoed only when it is an ISO time. With no expiry in the answer it stays `paused`.
- `bin/pipeline-health.sh` block 17 (`# >>> pause expiry warning`): after one `pause_refresh`, every live row in `state/pauses.json` whose `expires_at` is within `PAUSE_EXPIRY_WARN_S` (a pipeline-health settings row, default 7200, 0 = off) pages once as `pauseexpiry:<scope>:<what>:<expires_at>`, naming the actor, the reason and the minutes left. A renewed pause has a new key and warns again.
- `worker/jobs/src/routes/flags.js` `PUT /api/flags`: for a `paused-*` name the upsert and one `config_changes` row (kind `flag`, name = the flag, `before_json`/`after_json` = `{"active": 0|1}`, actor, reason) go in one `env.DB.batch`. A Mission Control RESUME (`setCoordFlag`) is now on record. A same-value write logs nothing. (BH-2377 since extends the same audit to every flag name; see docs/notes/2026-09-27-BH-2377-flag-write-audit.md.) No schema change: `config_changes` and the `flag` kind already exist.

Pinned by `tests/pause-board-expiry-test.sh`, `tests/pipeline-health-pause-expiry-test.sh`, `tests/poll-commands-pause.bh-1685-test.sh` and `worker/jobs/test/flags-pause-audit.test.js`.
