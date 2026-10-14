# BH-2544 (BH-2572): the alert-family registry runner

Doc: ALERT-REMEDIATION, ALERTS-STATE-MACHINE

`bin/triage-family-scripts.sh` used to be a no-op stub. It now runs the registry
pass that `bin/alert-triage.sh` calls once per tick, between FIX-PR ANSWERED and
DETERMINISTIC SETTLEMENT. The protocol is in the script's own header. This note
covers what the runner decides and what it still depends on.

## What it does

1. It reads the enabled rows of D1 `alert_family_scripts` once through
   `alert_family_scripts` (`bin/lib/jobs/alerts.sh`). The client prints TSV
   (`id match_kind match verify on_clear on_repro priority`), sorts by
   priority,id itself, and passes `_jobs_req`'s rc through: 404 is 2, an outage
   is 1, and a 200 without a `rows` array is 1. It never returns an empty list
   for a failure.
2. A family is handled only when every one of its lines has the same winner.
   The winner is the first row, in priority,id order, that matches the line.
   `akey_prefix` looks at the beat's `akey` only. `line_regex` is Python
   `re.match` (anchored) on `.line`. Rows with a bad id, an unknown match_kind,
   an empty match, a verify name outside `^[a-z0-9-]{1,48}$`, a bad
   on_clear/on_repro, or a regex that does not compile are refused with one log
   line each. The tick goes on.
3. It runs `timeout <s> $HARNESS/bin/alert-verify/<verify>.sh` with the family's
   raw quarantine lines on stdin. The outcomes are:
   - cleared: rc 0 with a first stdout line, which becomes the proof
   - repro: rc 1
   - unknown: anything else, including rc 0 with no output, a missing script,
     or a row with no verify
4. What each outcome does:
   - **Cleared with `on_clear=settle`.** It appends `verify:<id>: <proof><TAB><line>`
     to `$SETTLED` and the family key to `<removed-fams-out>`, and only then
     atomically rewrites `$FILTERED`. A crash in between leaves the family both
     settled-logged and sessioned, which is handled twice but never dropped.
   - **Repro with `on_repro=park`.** It logs `PARKED by registry row <id>`
     first, then calls `alert_state_set <alertid> parked alert-triage` for
     each `"dbrow":true` line. The family leaves `$FILTERED` only when every
     one of those comes back parked. A refused write (a 409 on an
     already-parked row included) keeps the session. So does a beat-only
     family with no alerts row.
   - **`model`.** Either outcome with `model` changes nothing.
5. Bounds. It runs at most `TRIAGE_VERIFY_MAX` verifies (0 turns the pass off:
   no fetch, one `REGISTRY off` line). The whole pass gets
   `TRIAGE_VERIFY_DEADLINE_S`, and each verify's `TRIAGE_VERIFY_TIMEOUT_S` is
   clamped to what is left of that deadline. Matched families past a bound
   keep their session and are counted `unchecked=`.
6. One summary line goes to the lane log:
   `triage pass: REGISTRY rows=N matched=N cleared=N parked=N repro=N unknown=N unchecked=N`.

It fails open. With no jobs client, no route (404), or an unreachable worker,
the runner logs one line, `triage pass: REGISTRY unavailable rc=<n> — every
family kept for a session`, touches no file and exits 0. It makes no model call
of any kind.

## Choices made here

- The park is written first and the family removed second, so a failed write
  keeps today's session instead of losing the family.
- A matched row with no `verify` is `unknown`. A match alone never settles.
- A regex that is slow rather than broken is bounded only by Python, not by
  the verify timeout. Rows are operator-authored, and the runner re-checks every
  field it relies on rather than trusting the route (#2575) to have done it.

## Still owed by siblings

- #2570: the real `triage_settled_ids` / `triage_close_ids`. Until it lands, a
  `verify:` settled line is logged NOISE-STALE but its D1 row is not resolved.
- #2575: the worker route `GET /api/alert-family-scripts`. Until it is
  deployed, every tick logs `REGISTRY unavailable rc=2` and behaves as before.
- #2577: the seed rows and the `bin/alert-verify/*.sh` scripts. Until then the
  registry is empty and the summary reads `rows=0 matched=0`.

Tests: `tests/alert-family-scripts.bh-2544-test.sh` drives the real lane with a
fake worker and stub verify scripts. `tests/alert-triage-hooks.bh-2544-test.sh`
case 11 now counts the runner's one fail-open line.
