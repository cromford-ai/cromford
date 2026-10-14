# agent-call and orchestrate read and write fleet cooldown rows

Doc: ACCOUNT-ROUTING, MODEL-ROUTES

**What changed.** BH-2352 shipped the fleet cooldown seam, `bin/lib/fleet-cooldown.sh`.
This slice (BH-2356, part of BH-2319) wires the call sites to it. A cooldown one box
records is now also a fleet row, and the model and openrouter readers honour a row
another box put.

Two writers, both in `bin/agent-call.sh`:

- `ladder_recover`, after each account stamp, puts `account <runner> <account>`.
  The full branch's until is now + `ACCOUNT_COOLDOWN_SECS` (falling back to
  `MODEL_COOLDOWN_SECS`, then 21600). The overage branch's until is the same
  effective window its backdated stamp encodes, now + `ACCOUNT_OVERAGE_COOLDOWN_SECS`.
  The contract keeps the later until, so a short put never shortens a 6 h row.
  `<runner>` is the vendor, so a codex refusal writes `account codex …`, never a
  claude row.
- The fable "out of usage credits" stamp puts `model claude <model>[/<account>]`
  until now + `MODEL_COOLDOWN_SECS`.

Three readers:

- agent-call's model cooldown: the local `state/model-cooldown-<model>[-<account>]`
  stamp in its window OR `fcd_live model claude <model>[/<account>]` rc 0.
- `openrouter_lane_down`: a third reading after `state/lane-down/` and
  `state/claude-auth-down.txt`, `fcd_live lane openrouter ${LANE_DOWN_SELF:-hub}`.
  It runs before the headroom probe, so a live row also saves the GET.
- `bin/orchestrate.sh` `orc_model_ladder`: the stamp in its window OR
  `fcd_live model claude "$(orc_cdkey)"` sends the turn to the fallback only.

**Key format.** The file name suffixes the account with a dash
(`model-cooldown-claude-fable-5-1-max7`). The fleet key uses a slash
(`claude-fable-5-1/max7`), as the contract states. An empty account and `default`
take no suffix in both. Matching is exact: a row for `/b` never hits account `a`,
and an unsuffixed row never hits `a`.

**Unknown is not hot.** `fcd_live` rc 1 (no row) and rc 2 (unknown: no store, the
worker stub, `FLEET_COOLDOWN_DB=0`, a malformed key) both read as not cooling, so
an unreachable fleet never parks a model or a lane. A box whose sync has not
landed the lib gets stubs (`fcd_put` rc 0, `fcd_live` rc 2): it writes nothing
and reads as before. `fcd_put` is always rc 0 and runs after the local write, so
it never gates the stamp or the retry.

**Not changed.** Success still clears only the local stamp: a fleet model row
lives until its until. Orchestrate's own credits-out stamp stays file-only.
`bin/account-pick.sh`, `bin/lib/lane-down.sh`, `bin/claude-auth-check.sh`,
`bin/lane-reprobe.sh` and `worker/` are other slices.

Pinned by `tests/model-cooldown-fleet.bh-2319-test.sh`, which also mutates each
reader, writer and source line and checks a case goes red.
