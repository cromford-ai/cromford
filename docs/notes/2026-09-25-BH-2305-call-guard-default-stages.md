# The call guard is on by default for plan, preplan, execute, fix, triage, prodqa and lead-review

Doc: CALL-GUARD

## What changed

- `bin/lib/call-guard.sh`: `CALL_GUARD_STAGES_DEFAULT` goes from
  `review triage-shard mc-rereview` to those three plus `plan preplan execute
  fix triage prodqa lead-review`. `CALL_GUARD_MAX_MAP_DEFAULT` keeps every K it
  had and adds explicit `prodqa=2` and `lead-review=2`, so no enabled stage
  rides `default=`.
- `catalog/lanes.d/_lib.call-guard.json` documents the same two defaults.
- `bin/lib/rb/execute.sh`: when `execute-run.txt` starts with
  `AGENT_CALL_REFUSED call-guard `, run-build answers
  `BUILD_DEFERRED execute refused by the call-guard: <marker>` (exit 3) instead
  of `EXECUTE_EMPTY no changes produced`. Nothing ran, so "no changes produced"
  was not true.
- `bin/lib/rb/plan.sh`: the empty-plan verdict names a call-guard refusal
  instead of "model limit/failure?". The RESULT stays `BUILD_DEFERRED`.

## Why

Issue #2305: the limits map already had K values for these stages, but the
stage list left them unguarded. preplan-tick runs every 2 minutes, and the
09-19 audit counted 152 stale re-plans a day.

## What to know

- A box with a `lib.call-guard.call_guard_stages` row keeps that row. The new
  default only reaches boxes without one.
- lead-review is K=2 on purpose: its one retry has the identical prompt, so the
  identical fallback fingerprint.
- Plan, execute and fix use the fallback fingerprint, and their prompts embed
  the build dir. They are capped inside one build, not across builds.
- A worker 5xx or timeout now fails CLOSED for these stages on a METERED
  runner (K3's existing rule). Escape hatches: `CALL_GUARD_FAIL_CLOSED_METERED=0`
  or a narrower stages row.
- `tests/agent-call-call-guard.k3-test.sh` 11a asserted that plain `triage` was
  unguarded by default. It now asserts the opposite, since the ticket names
  triage.

Tests: `tests/agent-call-call-guard.bh-2305-test.sh`.
