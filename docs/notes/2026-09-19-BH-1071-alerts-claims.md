# 2026-09-19 — BH-1071: the hub alert lanes claim rows

Doc: ALERTS-STATE-MACHINE

## What changed

`bin/alert-triage.sh`, `bin/alerts-medic.sh` and `bin/alerts-groom.sh` now read
and write the `alerts` table through the BH-1068 wrappers, behind the box flag
`flags/alerts-db`. Nothing else moved: no schema, no new files on disk beyond
two per-pass `mktemp`s in the medic, and both session prompts are byte-identical
because rows are rendered back into today's line shapes before a prompt is built.

- **triage** claims `quarantined` rows (`alert_claim alert-triage quarantined 0
  200`) after the deferral spool and before the ssh grab, renders each into the
  quarantine's own `source<TAB>epoch<TAB>payload` shape, and stamps each row
  `triaged` *after* its family's session returns. The ssh grab still drains every
  box's quarantine file — it just stops re-triaging entries carrying
  `"dbrow":true`, which the claim already handed us.
- **medic** adds unclaimed `alerts_list --state new --older-than 1200` rows to its
  candidate list, consults `alert_families medic 21600` alongside its local 6h
  brake, claims the rows it is about to dispatch and dispatches ONLY what the
  claim returned, and writes each park through with
  `alert_state_set <id> parked medic`.
- **groom** collects `alert_state_key "$LINE"` for every settled row and, after
  the console resolve POST, sends one `alert_resolve` for the batch.

## Why

The claim is the persisted "has anyone already paid for this row?" check, made
before any `agent-call.sh`. It closes two things: two lanes buying two sessions
for one condition, and the medic re-opening sessions on historic alerts. The
second thing it buys is a route to an alert whose box has dropped off the
tailnet — the row is in the table, so the hub claims and triages it instead of
waiting for that box's own 45-minute dead-man.

## The rules this touches

- **The flag is the whole switch.** `flags/alerts-db` absent ⇒ `alerts_db_on`
  returns 1, `ALERTS_DB=0`, and all three lanes are byte-for-byte what they were,
  with zero requests to the jobs worker.
- **Every DB call fails OPEN.** rc ≠ 0 anywhere ⇒ today's ssh/file path for that
  tick, plus one line in the lane's own log. rc 0 with an EMPTY answer is a real
  answer, not an outage: the medic then buys nothing, deliberately.
- **Write after buy.** Every state PATCH follows the thing it records — `triaged`
  after `agent-call.sh` returns, `parked` after `medic-parked.json` is written,
  the table resolve after the console resolve. A failed stamp costs at most one
  duplicate session when the 900s lease re-offers the row; it can never mark an
  alert handled that was not.
- **Claim after the split, not before it.** Claiming every candidate up front
  would stamp `claimed_at` on over-cap families, and the new fleet-wide brake
  would then drop them next pass — a deferral turned into a loss.

## Commands and log lines an operator greps

```
grep 'triage claim' /root/harness/logs/alert-triage.log
grep -E 'medic (db|claim)' /root/harness/logs/medic.log
grep 'resolved rows=' /root/harness/logs/alerts-groom.log
HARNESS_TEST_SANDBOX=1 bash tests/alerts-claims.bh-1071-test.sh
```

`resolved rows=0 (alerts table rc=…)` is a failure, said plainly; `resolved
rows=N` is only ever written after a successful call.

## A defect in the contract, fixed here

`alert_claim` (`bin/jobs-client.sh`, BH-1068) read `min_age_s` and `limit` out of
`$3`/`$4` and then did `shift 2`, so both were still in `"$@"` and were collected
into `ids`. Every call that passed them positionally put them on the wire as an
explicit id list, and the worker reads `ids` as a FILTER: `alert_claim
alert-triage quarantined 0 200` asked for the rows whose id is `"0"` or `"200"`,
matched none, and answered rc 0 with an empty set on every tick — which this
lane (correctly) treats as a real answer, so it would have filtered the ssh grab
down to nothing and left every table-backed row untriaged until its box's flush
dead-man escalated it at 45 minutes.

So `bin/jobs-client.sh` is in this diff after all, against the ticket's
do-not-touch list: the wrapper now consumes both positionals before reading ids.
Both call sites use the literal shape the ticket specifies (`alert_claim
alert-triage quarantined 0 200`, `alert_claim medic new 0 <n> <ids…>`), and two
tests pin it — `tests/alerts-client.bh-1068-test.sh` case 5b asserts the wire
body directly (no `ids` key without ids, `ids` exactly the trailing arguments),
and c1 in this slice's suite asserts the triage claim carries no `ids`.

## Known limits, written down rather than discovered later

- **A box with no `python3` has no derivable row id.** `alert_state_key` returns
  empty there, so a medic candidate the table never listed falls back to its
  candidate id. That id claims nothing on the worker, so the row is held back
  this pass instead of being dispatched behind the claim's back. The groom
  collects nothing on such a box and calls no resolve.
- **`line` arrives escaped.** The wrappers render rows with jq `@tsv`, which
  writes an embedded tab or backslash as a two-character escape. The medic's
  console-line match is exact equality, so a line containing either misses its
  console twin and joins the pass as its own candidate. The family split then
  groups the two, so the cost is one extra line in one session, never a second
  session — but the text the prompt carries for such a row is the escaped form.
- **Triage stamps every `alertid` in the family, not only the rows it claimed.**
  Quarantine payloads may carry an explicit `alertid` (`bin/beat.sh`), so an
  ssh-served entry this lane never claimed is stamped `triaged` too. It is in
  the session either way, so the stamp is true; it is just wider than "per
  claimed row". `new → triaged` is an allowed transition.
