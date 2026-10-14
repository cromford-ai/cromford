# Triage state: in-app queue and close-out work is the session's, in enforce and in the scorecard (BH-3774)

Doc: TRIAGE-STATE

## What changed

The pre-check (`ts_precheck`, `bin/lib/triage-state.sh`) now decides once per
ticket whether the tick has launch or close-out work for it: a queue line, a
queue dir or a finished build. It writes that as `decisions.tsv` column 9
(`work`, 1 or 0). A ticket matches on its key OR its board label, as whole
tokens.

- `ts_tick` (enforce) builds the do-not-touch list from column 9 and no longer
  recomputes the work keys itself.
- `bin/triage-state.py record` scores an effecting DECISION on a skipped work
  ticket as `work`, not `missed`. `ts_after_session` logs it in shadow as
  `triage-state shadow: work-on-skip N: <KEY> (<action>)`.
- A real miss now also logs `triage-state shadow: miss-detail: <KEY>=<gate
  reason>` and leaves `state/triage-state/<p>/misses/<stamp>-<KEY>/` (the
  world row, the thread and the decisions line the pre-check hashed). The
  newest 50 are kept, in shadow only.

## Why

On an in-app board the work key is the board label (`TK-2182`), and
`decisions.tsv` column 1 is the ticket id. The old `ts_tick` match compared the
label with the id, so it never matched. In enforce, an in-app ticket with a
close-out or a queue line went onto the "must NOT comment on them or change
their status" list. In shadow, the scorecard counted every such action as
`would-have-missed`, which is how project-4 showed 7 misses (launch ×2, comment
×1, status ×2, defer ×2) where project-5 showed 0. GitHub boards were never
affected, because there the work key is the issue number and so is column 1.

The input hash is unchanged. These 7 shapes are close-out and queue work, not
a field the hash is missing. If a miss survives this fix, its `misses/`
snapshot shows what the pre-check hashed.

## Operator steps after merge

- Leave project-4 in shadow for 24h. Then check `grep -E 'would-have-missed|miss-detail'`
  in `logs/project-4.log` and `ls state/triage-state/project-4/misses/`. When there are
  zero real misses, set `lib.triage-state.project-4.triage_state_mode=enforce`.
- Run the same check on the other in-app boards (project-2, project-9, project-3)
  before you enforce them.
