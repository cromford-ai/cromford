# fetch_artifact reads the pool build's remote dir, and a far box's answer reaches the beat (BH-3945)

Doc: HARNESS-COORDINATION

## What was wrong

Two separate defects made `fetch_artifact cromford BH-3859 review` (and
the 20259/20260/20281 requests) come back as a timeout or `missing`.

1. **Wrong build dir.** `build_dir` in `bin/fetch-artifact.sh` took the newest
   `builds/<p>-<k>-*` dir by mtime (`ls -dt ... | head -1`). A pool build leaves
   two dirs for one ticket: the local QUEUED_FLY stub (RESULT, job.json,
   COMMENTED) and the staged `-remote<ts>` dir that holds review.md. COMMENTED is
   written last, so the stub is newest and the answer was `missing=true` while
   the file sat one dir over.
2. **The answer never landed.** cromford is owned by a far box
   (box-small). For those projects the hub's handler in
   `bin/poll-commands.sh` (the far-box branch, around line 400) only queues a
   `box_console_commands` row. The box lane `bin/box-console-commands.sh` runs
   it and posts the artifact JSON as the row's body, and nothing ever sent the
   `artifact_tail` beat. The console UI reads the row (BH-2656), so it worked.
   `/api/dash/logs/<id>`, which the harness MCP polls, is fed only by the beat,
   so it waited until it timed out. The hub's local branch does beat, which is
   why only far boxes were hit. This is not the wake-claim crash class (#3944):
   no process died, the beat was simply never sent on that path.

## What changed

- `build_dir <project> <key> [file]` walks the candidates newest first and
  returns the first dir that holds `<file>`. When none does it returns the
  newest dir, so `missing=true` stays honest and `build_dir` still names a dir.
  No candidate is still rc 2, and a bad key or project is still rc 1. Both
  `--path` and the main call pass the filename.
- After posting a row result whose body has `kind` `artifact_tail` or
  `log_tail`, the box lane sends the same JSON through `bin/beat.sh` with
  `BEAT_STRICT=1` (rkey `artifact:<cid>` / `log:<cid>`, so it is idempotent).
  It beats even if the row post failed, because the beat is the only answer
  the beat-fed reader gets. A failed beat writes
  `beat failed id=<id> type=<type> rc=<n>` to `logs/box-console-commands.log`
  and does not change DONE/FAILED. Refusal and `fetch_failed` bodies are beaten
  too, so the poller sees `refused`/`fetch_failed` and not a timeout. The same
  fix covers `fetch_log` on far boxes.

## Tests

- `tests/fetch-artifact-pool-dir.bh-3945-test.sh`: stub + remote dir fixture,
  fallback, both-hold, TK-8 vs TK-88, refused key, a plain file in the glob.
- `tests/box-console-commands-beat.bh-3945-test.sh`: the real lane, row then
  strict beat for fetch_artifact and fetch_log, no beat for run_triage, a
  failing beat, and no beat.sh at all.

Still owed after deploy: the live probe `fetch_artifact cromford BH-3859 review`
returning the review text.
