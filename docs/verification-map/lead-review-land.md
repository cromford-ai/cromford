# Lead review promotion (BH-1951)

**What it is:** a hub lane, `bin/lead-review-land.sh`, that turns each finished
lead review request (`lead_review_requests`, written `done` by the box lane
`bin/lead-review.sh`) into a `source=lead` row in `/api/verdicts`, which is what
every merge lane reads (`bin/lib/verdicts.sh`). Then it stamps the request
promoted. It also raises one ALERTS line per failed or overdue request. It makes
no agent call and no SSH.

**How a user reaches it:** there is **no UI route**. It runs from hub cron
(`cron/lanes/715-lead-review-land.cron`, every 15 minutes as a backstop, behind
`bin/hub-lease.sh check`). It also runs as soon as a box finishes a lead review:
`bin/lead-review.sh` rings `lead-land` through the wakes doorbell
(`POST /api/wakes/lane`, dedupe `lead-land:<pr>@<sha12>`, BH-5317), and
`bin/wake-loop.sh` on the hub launches this lane. The box's
`logs/lead-review.log` says `lead-land doorbell rung for <repo>#<pr>@<sha12>`
for each ring. By hand on the hub:

```bash
/root/harness/bin/lead-review-land.sh
tail -5 /root/harness/logs/lead-review-land.log
```

The promoted row shows in the console's PR screen VERDICTS table (BH-1952) as
source `lead`, reviewer `box:<hub>`, with the note `lead-review:<id>`. The CLI
view is `bin/lead-verdict.sh show <owner/repo> <pr> <head-sha>`.

**What to look at:**

- `logs/lead-review-land.log`: one `seen=N promoted=N stamped=N alerted=N` line
  per tick, plus one line per request it acted on or skipped (verdict row NOT
  posted, promoted stamp failed, unknown verdict, verdicts read failed).
- `logs/ALERTS.log`: `[lead-review-land] <repo>#<pr> @<head12> lead review <id>
  <status>: <reason> — <what to do>`, once per request id
  (`state/lead-review-land/alerted-<id>`). There is also one line per UTC day
  for a truncated list (`truncated-<YYYYMMDD>`) and one for a missing lead token
  file (`no-token-<YYYYMMDD>`).

**Protected paths (BH-3683):** on a repo with live `lead_protected_paths`
rows (BH-4148: `GET /api/lead-protected-paths?repo=`, with a last-good cache in
`state/lead-authority/globs-<owner_name>.cache`; unreadable rows hold every lead
MERGE), a lead MERGE on a PR that touches a
protected path (or on any PR once the repo's `lead_authority` row reads `human`
or `human:precision`) is posted as advice: `bin/lead-verdict.sh post` exits 5,
the row's note carries `authority:human-required`, no `lead-verdict` status is
published, and the log says `recorded as advice; lead-verdict status withheld`.
The request is still stamped promoted, is never spot-checked, and one warn beat
`lead-human-needed-<owner_name>-<pr>-<sha12>` names the command that publishes
the status: `bin/lead-verdict.sh post <repo> <pr> <sha> MERGE --source human`.
A beat that could not be sent leaves the request unstamped until a later tick
sends it. `bin/lead-verdict.sh authority <repo> [<pr> <head>]` shows the rule in force.

**Preconditions:** the hub (`is_hub_box`; any other box logs `runs on the hub
only` and stops), `LEAD_VERDICT_TOKEN_FILE` readable, and the
`/api/lead-reviews` routes deployed (without them the tick logs `not deployed`
and does nothing).

**Knobs** (`catalog/lanes.d/lead-review-land.json`): `LEAD_REVIEW_OVERDUE_MIN`
(120). Off switch: `flags/lane-off-lead-review-land`.

**Suites:** `HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land.bh-1951-test.sh`
runs the real lane against a stateful stub worker, then reads its row back
through the real `vd_block_line`.
`HARNESS_TEST_SANDBOX=1 bash tests/verdict-files-retired.bh-1951-test.sh` covers
the autopilot's box rows and the conductor reading rows instead of files.

## Re-landing after a reset (BH-5400)

A request can be sent back to `requested` and reviewed again. Every review run
claims with a new job id, so the lane keys "already landed" on (request id, job
id), never on the id alone:

- the verdict row note is `lead-review:<id> lead-job:<job>`, plus
  `supersedes:<rowid>` when it replaces an earlier landing of the same request;
- the findings review keeps `<!-- lead-review:<id> -->` on line 1 (what
  `br_lead_pick` reads) and adds `<!-- lead-job:<job> -->` on line 2;
- `state/lead-review-land/findings-<id>`, `dismissed-<id>`, `superseded-<id>`,
  `nh-<id>` and `trip-<id>` hold the job they were written for.

A landing with no job token, or an empty flag (both from before BH-5400), counts
as the current result only while the request's `reset_count` is 0.

When the request holds a newer result, the lane posts a new row (and so a new
`lead-verdict` status; the newest lead row on a head stands). On MERGE it
dismisses the earlier landing's CHANGES_REQUESTED on the same head as well as
the older-commit ones. On BLOCK it posts the new findings as a REQUEST_CHANGES
first, and only then dismisses the earlier landing's review, so the head never
has no standing review. The stamp is `POST /api/lead-reviews/<id>/promoted`
with `{"job_id":"<job>"}`; the worker answers 409 when the request now holds
another job, and the lane logs it and lands the newer result on the next tick.

**Resetting a request:** `bin/lead-verdict.sh reset <request-id>`
(`POST /api/lead-reviews/<id>/reset`, lead token). It works from done, failed or
superseded, clears the result and the promoted stamp, and bumps `reset_count` /
stamps `reset_at`. A request already `requested` answers 200 unchanged; a
`running` one is refused. A raw-SQL reset is still recorded: the claim that
takes a `requested` row that was worked before (job, verdict or promoted stamp
still set) bumps `reset_count`, stamps `reset_at` and clears the promoted
stamp. One case it cannot see is a raw reset that nulls the job, the verdict
and the promoted stamp of a row landed before BH-5400; use the CLI.

Failed and overdue alerts follow the reset too: the overdue age runs from
`reset_at` when it is set, and `alerted-<id>` holds `r<reset_count>`, so a reset
request alerts once more.

**Not covered:** on a PR opened by the lane's own App (`cromford[bot]`),
GitHub refuses a REQUEST_CHANGES from the PR's author (422). A re-landed BLOCK
there is posted as a COMMENT with the `lead-block-nobrief-<id>` warn, as a first
landing is, and no fix round is briefed from it.

**Evidence on the hub:** `logs/lead-review-land.log` lines `re-landing: newer
result job <job> replaces lead row #<n>`, `dismissed <n> earlier landing
review(s) of lead review <id>`, and `promoted stamp for job <job> refused, a
newer result on the request`; on the PR, the old lead review DISMISSED and the
new one standing.

**Suites:** `HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-reland.bh-5400-test.sh`
(the real lane, CLI and `br_lead_pick` against stub worker and GitHub) and
`cd worker/jobs && node --test test/lead-reviews-reset.bh-5400.test.js` (the
reset route, the claim's bookkeeping and the job-bound stamp over the shipped
schema).
