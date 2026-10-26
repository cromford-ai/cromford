# BH-8386: web-task write approval (`bin/lib/web-task/approval.sh`)

BH-8386 carries the rest of BH-8360. It fills the approval stub of BH-7594 S1
(PR #7650) on main. #7650 was still open and conflicting on 2026-10-26, so the
file is new on main with the stub's exact names, arguments and shape.

## Contract

Sourced, never run; functions only. On source it sets `__wta_dir` and nothing
else. `bin/lib/web-human.sh` is sourced on the first request only.

`wt_approval_request <project> <KEY> <action-json>`

- `action-json`: `{"site": "...", "action": "...", "issue": "<owner/repo#n>"?, "shot": "<png>"?}`.
  `site` and `action` are required non-empty strings.
- It calls `wh_request_human <project> <site> approve "Approve write on <site> for <KEY>: <action>" [--shot <png>] [--issue <owner/repo#n>]`.
  Control characters in `action` become spaces. The worker's prompt bound
  refuses an over-long prompt, and the request then fails closed (rc 1).
- It blocks for the worker's wait, writes one record and prints the request id
  `<LANE_RUN_ID>-<n>`. The web-human stderr lines pass through.

| web-human outcome | `wt_approval_request` | record |
|---|---|---|
| rc 0, stdout exactly `done` | rc 0, id | `approved` |
| rc 3 (cancelled) | rc 0, id | `denied` |
| rc 4 (waiting on human (step N)) | rc 0, id | `pending N` |
| any other (rc 0 with other stdout, rc 1, rc 2) | rc 1, no id | none |
| `web-human.sh` absent or did not load | `not available`, rc 69 | none |
| usage, or no `LANE_RUN_ID` | rc 2, nothing asked | none |

`wt_approval_status <request-id>` reads the record, with no network call.
rc 0 with `approved`, `denied` or `pending` (pending also prints
`wt-approval: step <N>` on stderr: the step a resume run takes over with
`wh_resume_human`). rc 1 with `unknown` on stderr when there is no record.
rc 2 for an id that does not match `<run>-<n>`.

## Record format

One file per id in `${WT_APPROVAL_DIR:-${TMPDIR:-/tmp}/web-task-approval-<LANE_RUN_ID>}`
(mode 700). One line: `approved`, `denied` or `pending [<step>]`. The id is
claimed with a noclobber create, so two requests of one run never share an id.
The record holds no secret. The dir is per run and lives in the run's temp
space; no table, no knob.

## Merge instruction for #7650

On the add/add conflict of `bin/lib/web-task/approval.sh`, take main's file.
In #7650's seam test Z, drop the two `approval.sh` stub entries. The vault,
otp and session stubs stay. No caller wiring changes: `bin/web-task.sh` sources
the file and calls neither function.

## Phone proof (operator steps, not run by the build)

1. On a lane-run machine with a claimed web-task run (LANE_RUN_ID, machine,
   WEB_VAULT_RUN_TOKEN, JOBS_URL, HARNESS_SECRET set), run:
   `. bin/lib/web-task/approval.sh; id=$(wt_approval_request <project> <KEY> '{"site":"example.com","action":"click Submit","issue":"example-org/cromford#8386"}')`
2. the operator gets the Telegram message and the `NEEDS-HUMAN:` comment on #8386, and presses Done.
3. Run `wt_approval_status "$id"`. It must print `approved`.
4. Repeat steps 1-3 and press Cancel. `wt_approval_status "$id"` must print `denied`.

Test: `tests/web-task-approval.bh-8386-test.sh`.
