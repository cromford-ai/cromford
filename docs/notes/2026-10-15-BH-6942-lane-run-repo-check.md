# Lane-run machines: name the head-read error, check fleet repos at start, refuse unreadable repos at claim (BH-6942)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

## What changed

1. `bin/merge-conductor-pr.sh` names the head-read error. The UNVERIFIABLE
   prof reason was `head-read-rc<n>`. It is now
   `head-read-rc<n>-<GH_REST_STATUS>-<GH_REST_REASON|none>[-via-<rung>]`, for
   example `PROF mc-pr state=UNVERIFIABLE reason=head-read-rc75-403-rate-limit-via-app deferred=-`.
   The rung is `gh_repo_current_rung` (app, default, admin or unknown). The
   exit code stays 75. `mc_fly_failed_for` reads the rc, not this word.
2. `bin/lib/lane-run-repos.sh` (new) has the boot repo check. `lrr_check` reads
   each distinct fleet.conf repo once, with `gh_rest GET repos/<slug>` behind
   the conductor's own token path (`gh_repo_use_token`). The verdict comes
   from that read:
   - rc 0: readable.
   - rc 44 (404): unreadable `404`, or `404-no-token` when no rung of the
     token ladder sees the repo.
   - rc 75 with status 401 and reason `auth`: unreadable `401-auth`.
   - Any other rc 75 (rate limit, network, 5xx, quota reserve): unknown. The
     repo is NOT refused, so a transient error never strands rows.
   It writes `state/lane-run-worker/skip-prefixes`, one `<project>.` line per
   project whose repo is unreadable. It writes one line per unreadable or
   unknown repo and one summary line `repo check: <r> of <n> repos readable,
   <u> unreadable, <k> unknown` to `logs/lane-run-worker.log` and to stderr
   (the Fly log). Each refused project gets one
   `lane-alert.sh --severity warn --id lane-run-repo-unreadable-<project>`.
   When `fleet-conf.sh --projects` fails, it removes the old file, writes no
   new one and logs one line, so nothing is refused.
3. `bin/lane-run-worker.sh` runs `lrr_check` once per process start (step 0b)
   when `lrr_enabled`: `LANE_RUN_REPO_CHECK=1`, or `LANE_RUN_CODE_SYNC=1` with
   `LANE_RUN_REPO_CHECK` unset. Only the lane-run entrypoint sets
   `LANE_RUN_CODE_SYNC=1`, so the hub and other boxes do not change. A
   code-swap re-exec checks again. The claim body carries
   `skip_prefixes` only when the file is not empty, so a machine with nothing
   to skip sends the same body as before.
4. `POST /api/lane-runs/claim` takes an optional `skip_prefixes`: an array of
   at most 64 strings of `[A-Za-z0-9._-]{1,65}`. Anything else answers 400 and
   claims nothing. Absent, null or `[]` is the old claim. A row whose project
   starts with one of them (byte match with `substr`, not `LIKE`) is not
   claimed. It stays `queued` with its attempts unchanged, and the hub takes
   it back after `MC_FLY_QUEUE_STALE_S` (fallback `no-capacity`). `project-6.`
   does not match `project-6-os.5.abc` or the plain project `project-6`.
5. A refused row ends (lead review of #6960). Before it claims, a claim that
   carries `skip_prefixes` ends every `queued` row that its own skip and
   lanes filters refuse and that waited `lane_run.refused_max_wait_s` or
   longer (settings row, seed 600, 0 = never). The row becomes `died`, rc
   NULL, prof `withdrawn refused-at-claim machine=<m> waited>=<s>s`, at most
   100 rows per claim. The hub reads such a newest row as `no-capacity`
   (`mc_fly_stale_for` answers `withdrawn`), not as a machine failure, and
   works the PR itself. So a PR of an unreadable repo has at most 1 live row
   per head inside the wait, and none after it, also after the PR closes.

## Why

The rc 75 rows of 2026-10-15 all said `head-read-rc75` and nothing more, so
nobody could tell a rate limit from a missing token. A machine that cannot
read a repo claimed its rows, failed them, and the hub then repeated
`fallback=machine-failed` for those heads.

## Operator notes

- `LANE_RUN_REPO_CHECK=0` turns the check off on a machine. It is a process
  switch, not a settings row. `tests/lib/scratch.sh` exports it as 0 so no
  suite reaches GitHub through it.
- The check costs one REST read per distinct fleet repo per machine start.
- A refused row counts as queued work for `bin/lane-fleet.sh` only until a
  refusing claim ends it (`lane_run.refused_max_wait_s`). Then the oldest
  queued wait drops and the fleet can scale down.
- To stop ending refused rows, set `lane_run.refused_max_wait_s` to 0. To
  turn the whole refusal off, set `LANE_RUN_REPO_CHECK=0` in the lane-run
  machine env (`fly machine update <id> --env LANE_RUN_REPO_CHECK=0`, or the
  app's `[env]` in the Fly config, then restart the machines). A machine with
  the check off sends no `skip_prefixes`, so it refuses and ends nothing.
- Index use: the new predicate runs over `json_each` of at most 64 strings.
  `worker/jobs/test/lane-runs-skip.bh-6942.test.js` S7 checks with EXPLAIN
  QUERY PLAN on 20 000 rows that the claim keeps its `idx_lane_runs_claim`
  path.

## Tests

`tests/lane-run-head-read.bh-6942-test.sh` (H1-H9: the real worker against the
real jobs worker, with a gh stub per repo; H9 = 3 pushes leave at most 1 live
row) and `worker/jobs/test/lane-runs-skip.bh-6942.test.js` (S1-S11: the claim
route; S9-S11 = the refused rows end, only those, through the claim index).
