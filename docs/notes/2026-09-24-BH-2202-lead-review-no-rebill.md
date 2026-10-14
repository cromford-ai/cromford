# A lead review retry replays the report on disk instead of paying again

Doc: lead-review

## What changed

- **`bin/lead-review.sh` checks what it already paid for before any agent
  call.** After the claim and the live-head check, a
  `state/lead-reviews/<key>.md` whose first line is
  `# Lead review <key> (<repo>#<pr> at <sha>)` for this request is replayed:
  its verdict, its `- reviewer model:` and its `- host suite:` line go through
  the same artifact → result → job done steps a fresh review uses
  (`finish_done`). No checkout, no suite, no agent call. The log says
  `reusing <report> for <key>; no agent call`.
- **A billed answer with no verdict leaves `state/lead-reviews/<key>.empty`**
  (one line, the model). A retry that finds it posts `outcome=failed
  detail=empty` with that model and makes no call.
- **rc 74..79 from `bin/agent-call.sh` (nothing billed) writes nothing**, so
  the next tick may call, as before.
- **`LEAD_REVIEW_DIFF_MAX_BYTES` registry max is 600000** (was 2000000). The
  lane's ceiling in `catalog/context-budgets.json` is 200K tokens, and 600000
  bytes at 3 bytes a token is that ceiling. A settings row above it is clamped
  and logged by `lane_env_apply`. A value in `env/global.env` is still used as
  is, per the lane-gate policy.

## Why

The #2085 (BH-1950) review: when the result post failed after a verdict, the
job stayed open, the watchdog requeued it, and the retake ran the whole review
again, paying for a second model call (four, for an empty answer) while the
report sat on disk. The metered-api-dedup rule is one paid attempt per request.

## Kept as is

- The in-attempt format retry: an answer whose last line is not
  `VERDICT: <word>` still gets one more call in the same attempt.
- A tick killed mid-call with nothing on disk calls again on the retake.
- A moved live head posts `superseded` before any reuse is considered.
