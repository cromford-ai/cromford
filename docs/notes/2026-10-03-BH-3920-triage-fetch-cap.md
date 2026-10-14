# The triage-state fetch cap rotates, defers instead of dropping, and a silent session is held (BH-3920)

Doc: TRIAGE-STATE

## What changed

- `ts_precheck` (`bin/lib/triage-state.sh`) ranks every ticket that needs a
  thread read by tier (webhook-named first) and last read attempt
  (`state/triage-state/<p>/<key>.tried`), and reads the first
  `TRIAGE_STATE_MAX_FETCH`. N tickets needing a read are all read within
  `ceil(N / cap)` ticks.
- A ticket past the cap no longer loses its entry stamp. It is hashed from its
  cached thread and decided `llm <reason>:stale-raw` (never skip), or
  `llm fetch-deferred` with nothing cached. `unhashable` now means only a read
  that failed or a thread the hash pass cannot parse.
- An rc-0 session with no DECISION line and no `tickets=` summary writes a
  `handed-no-decision <marker>` reason and `next_recheck_at = now + backoff`
  (new knob `TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S`, default 7200) on each
  model-set ticket it was handed. No verdict is written. The next tick decides
  it `skip handed-no-decision` while its inputs still hash to the marker.
- `rt_gate_fail_consume` (`bin/lib/rt/gate.sh`) writes one `triage-stuck:<p>`
  alert when the consumed failures were call-guard refusals, naming the keys in
  the model set and why.

## Why

On project-4 (2026-10-03), 84 open keys all needed a read at cap 30. The same 30
were read every tick, the other 54 lost their entry stamp and were
`llm unhashable` forever, the sessions returned no DECISION lines so nothing
was recorded, and the call-guard refused the identical prompt until triage
stopped with only a generic alert.

## Rules, state, commands

- New state files: `<key>.tried`, `deferred.keys`, `need.tsv`, `hnd.last` under
  `state/triage-state/<p>/`.
- Settings row: `lib.triage-state[.<project>].triage_state_handed_no_decision_backoff_s`.
- Suite: `tests/triage-state-fetch-cap.bh-3920-test.sh`.
