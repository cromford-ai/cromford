# BH-5526: a day spend cap never stops a ticket midway (slice C0)

Doc: RUN-BUILD-GRAPH, COST

**What changed.** A day spend cap now refuses only at the ticket boundary. The
boundary is the `# >>> budget launch gate` block of `bin/lib/rb/gates.sh`.

- The launch gate runs `bs_launch_check` as before. It also checks the
  `fly-pool` lane's `LLM_USD_CAP_DAY` through `llm_gate_precall`.
- A refusal writes `RESULT BUILD_DEFERRED <reason>` with the spend and the cap,
  one `pipeline.log` line, and one alert per (project, UTC day). Alert flags:
  `flags/alerted-budget-launch-<project>-<YYYYMMDD>` and
  `flags/alerted-llm-cap-launch-<project>-<YYYYMMDD>`.
- When both checks pass, the gate writes `$BUILD/ADMITTED` (`<stamp> <KEY>`).
- A `RESUME_BUILD` of a dir that holds `ADMITTED` skips both checks. The ticket
  is in progress.
- "In progress" means the build dir holds `ADMITTED` and no `RESULT`
  (`RESULT()` writes it at ticket end; a resume removes it). `bs_admitted`
  tests both, and also refuses the exemption when `AGENT_CALL_LANE` is set to a
  lane other than `fly-pool`.
- `bs_gate` (`bin/lib/budget-stop.sh`) never returns 2 (day refusal) or 3
  (unreadable day cap) for a call of an in-progress admitted build. It allows
  the call and writes ONE line per build to `pipeline.log`:
  `day cap over/unreadable during an admitted ticket — call ALLOWED (BH-5526): <refusal text>`.
  The marker is `<build>/.cap-overrun-noted`.
- `bin/agent-call.sh` sets `LLM_GATE_IN_TICKET=1` (not exported) when
  `AGENT_CALL_LANE=fly-pool` and `$OUT` is in an in-progress admitted build
  dir. `llm_gate_precall` then skips both `LLM_USD_CAP_DAY` scopes of the
  `fly-pool` lane, the only lane the launch gate checked. It writes the "was not
  applied" line to `logs/lane-gate.log` only when one of those caps is set.
- `pool_lane_failure` in `bin/fly-pool.sh` reads ` usd-cap-day ` as the lane's
  condition, so a launch refusal on that cap is not counted against the ticket.

**What did not change.**

- The build-stage caps (`budget.stage.<s>.max_calls|max_usd|max_tokens`) still
  stop an admitted build. They are the in-ticket runaway guard.
- `LLM_LANE_ENABLED=0` still refuses every call. It is a kill switch.
- Calls outside a build dir, and build dirs without `ADMITTED` (builds that
  started before this change), behave as before.
- `budget-stop-off` still turns off every scope, the launch gate included.
- A lane that writes into a build dir after the ticket ended
  (`bin/postmerge-qa.sh`, lane `postmerge-qa`; `bin/replan-check.sh`, lane
  `fly-pool`) is its own start. Its day caps still refuse it.

**Why.** Before this change a day cap refused the execute or review call of a
ticket whose plan already ran. `CC()` then deferred the build, and the money
spent on the earlier stages was lost.

Verified by `tests/budget-midway.bh-5526-test.sh`.
