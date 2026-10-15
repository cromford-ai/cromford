# The project-3 pre-merge gate refuses a head whose Vercel preview failed (BH-6501)

Doc: MERGE-CONDUCTOR

Slice C1 of #6160. PR #6479 (C0) saves the revert reason. This slice adds the
missing check.

## Why

project-3 merged 7 PR heads with a FAILED Vercel preview between 10-01 and 10-13.
Each one turned the production build red and was reverted. No merge path read
the preview: the box token gets 403 on commit statuses, so the failed status
showed only as mergeState `UNSTABLE`, and `mc_discount` turns `UNSTABLE` with
green runs into `CLEAN`.

## What changed

- `bin/pre-arm-guards.sh` runs a preview gate before its workflow lookup. The
  merge conductor (READY arm) and `merge-sweep` call this script before a merge.
  Neither caller changed.
- `bin/lib/pre-arm-preview.sh` reads the PR head (one `GET repos/<slug>/pulls/<n>`)
  and the preview rows that `bin/vercel-deploy-snapshot.sh` writes:
  `state/vercel-deploys/<project>.json`, else `state/vercel-deploy-status.json`
  `.projects[<project>].previews`. It makes no Vercel call.

| Head preview state | Answer | Caller |
|---|---|---|
| newest row for the exact head sha is `ERROR` | rc 1, stdout `vercel-preview: Vercel preview ERROR on <head12> (<url>)` | conductor parks `static-guards-red`; merge-sweep parks |
| newest row `BUILDING`/`QUEUED`/`INITIALIZING`, younger than `PRE_ARM_PREVIEW_WAIT_MIN` | rc 3 | retry next tick |
| `READY`, `CANCELED`, an old build, no row for the head (`unseen`) | stderr line, then the old workflow check | as before |
| no snapshot, unreadable, older than `PRE_ARM_PREVIEW_STALE_MIN`, or the PR read failed (`blind`) | stderr line, then the old workflow check | as before (fail open) |
| head branch matches `PRE_ARM_PREVIEW_EXEMPT_BRANCHES` (`exempt`) | stderr line, then the old workflow check | as before |
| repo not gated (`off`) | nothing; no PR read | as before |

When a head has two rows with the same `createdAt`, `ERROR` wins. A redeploy of
the same head that turns `READY` clears the park on the next tick.

Every answer except `off` writes one line `pre-arm preview: <word> <slug>#<pr> — <detail>`
to stderr. Both callers append it to their log (`logs/merge-conductor.log`, the
merge-sweep log).

## Knobs (`catalog/lanes.d/_lib.pre-arm-preview.json`, lib id `pre-arm-preview`)

| env | default | meaning |
|---|---|---|
| `PRE_ARM_PREVIEW_PROJECTS` | `project-3` | fleet.conf projects the gate checks, a space list |
| `PRE_ARM_PREVIEW_EXEMPT_BRANCHES` | `rollback/* revert-*` | head branch globs the gate never holds (rollback PRs #486/#499/#501 had a FAILED preview) |
| `PRE_ARM_PREVIEW_WAIT_MIN` | `20` | a preview still building younger than this answers rc 3; 0 = never wait |
| `PRE_ARM_PREVIEW_STALE_MIN` | `30` | a snapshot older than this is `blind` |

Kill switch: set the settings row `lib.pre-arm-preview.pre_arm_preview_projects`
to `off` (any value that names no project). To gate another Vercel project, add
its fleet.conf name to the same row.

## Known limits

- The park reason is the existing `static-guards-red`. It is not resolver-owned,
  so a preview park pages once per PR per state and waits for a push or a
  redeploy. A `preview-red` park class owned by the resolver is a follow-up if
  this page is too noisy. It needs edits to `bin/merge-conductor.sh` and
  `bin/blocked-resolver.sh`.
- The conductor publishes its `mc-merge-verdict` row before it runs the pre-arm
  guards, so `cv_hold` readers do not see this hold. `static-guards-red` has the
  same gap today.
- Both callers skip the pre-arm guards on a repo with a merge queue.
- The 3 project-3 reverts with a READY preview are not caught by this gate.

## Live check

After deploy, on the hub:
`grep 'pre-arm preview:' /root/harness/logs/merge-conductor.log | grep project-3 | tail -3`
must show at least one line within 24 h. If it shows none, the gate is not reached.

Test: `tests/pre-arm-preview.bh-6501-test.sh`.
