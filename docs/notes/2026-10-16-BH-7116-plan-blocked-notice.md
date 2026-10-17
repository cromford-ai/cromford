# A PLAN_BLOCKED build says why, and the stranded watch waits for an answer (BH-7116)

Doc: EVENTS, OPERATING

## What changed

- A pool builder (`BUILDER_EXEC` set, builder-direct on) that ends
  `PLAN_BLOCKED` posts one issue comment from `_job_finish`. The comment
  quotes the plan's blocked section: the text after a leading `BLOCKED` marker,
  else a `BLOCKED` / `Open questions` / `Questions` heading, else the top of
  the plan. The text goes through `bin/transcript-scrub.sh` first (no
  scrubber, no comment) and is cut at 40 lines and 3000 bytes.
- After a 2xx answer, RESULT line 1 gets the builder-direct marker
  (`| CLOSED-OUT: …`), so the owning box's staging marks the dir COMMENTED and
  the triage sweep does not post a second comment. A failed POST leaves the
  RESULT unmarked, and the sweep posts as before.
- One comment per distinct reason: the comment-mark key is
  `plan-blocked <project> <KEY>`, and the token is the first 16 hex characters
  of the excerpt's sha256.
- GitHub-Issues boards only. In-app boards and watcher builds keep today's path.
- The fly-pool reap copies plan.md from the ledger's `plan_md` transcript into
  the hub record `builds/pool-<p>-<KEY>-<stamp>/` when the RESULT came from the
  pool-result row (the machine was already gone).
- `orphan-reconcile.sh --stranded` skips a ticket whose queue row reason has
  `PLAN_BLOCKED` as its first word, and that has no human comment created or
  edited after the row's `updated_at`. The run summary names it
  `<KEY>:plan-blocked`. The skip is not counted toward NEEDS_HUMAN. A human
  comment is one whose `user.type` is not `Bot` and that is not one of the
  harness Apps (`hs_ours`).

## Why

On 2026-10-16 eight tickets went PLAN_BLOCKED 2-4 times each. The stranded
watch re-offered each one, the planner blocked it again, and no reason reached
the ticket: plan.md lived only on the reaped pool machine.

## Knobs and files

- `STRANDED_SKIP_PLAN_BLOCKED` (stranded-watch lane row, default 1). 0
  re-offers PLAN_BLOCKED tickets as before.
- The notice has no knob of its own. It follows `BUILDER_DIRECT` and
  `flags/builder-direct-off`.
- Code: `bin/lib/plan-blocked.sh`. Tests:
  `tests/plan-blocked-notice.bh-7116-test.sh`,
  `tests/orphan-reconcile-plan-blocked.bh-7116-test.sh`.
