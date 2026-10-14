# 2026-09-22 — BH-1327: cliff-parked rows leave the claim queue, and the triaged miss line names what it missed

Doc: ALERTS-STATE-MACHINE

The three non-blocking follow-ups from the BH-1071 review (#1109), all inside
`bin/alert-triage.sh`'s `flags/alerts-db` path.

## What changed

**1. A cliff-parked family is stamped `parked` in the table.** The CPARK branch
(the one reached after `TRIAGE_CLIFF_MAX_REFUSALS` refusals) already appended the
family's lines to `state/alert-triage-cliff-parked.tsv` and stopped re-spooling
them. It now also calls `alert_state_set <id> parked alert-triage` for every
`"dbrow":true` id in the family, immediately AFTER the park file append.

Why: the row stayed `quarantined` and claimed, so the worker's 900 s lease
(`worker/jobs/src/routes/alerts.js`) re-offered it to
`alert_claim alert-triage quarantined`, the lane refused it again, and the same
lines were appended to the park file again — every other tick, forever, at no
cost to anyone but the operator reading the file. `quarantined -> parked` is an
allowed edge and the claim query filters on `state=quarantined`, so a parked row
is out of the queue by construction.

Scope and ordering are both deliberate. Only rows this lane CLAIMED are stamped:
a beat `alertid` served over ssh has no lease to lapse, and parking it would be
this lane acting on a row it never claimed. The park FILE is written first and
the PATCH only mirrors it — the same write-after-record ordering the medic's own
park mirror uses at `bin/alerts-medic.sh:391`. A failed PATCH is logged with its
rc and never retried.

**2. The triaged miss line is true for the id it names.** The write-through
PATCHes every `alertid` in the family, and `bin/lane-alert.sh` /
`bin/claude-auth-check.sh` emit `alertid` beats that only have a table row when
THAT box's writer side is on. A 404 for such an id used to log "the row is
re-offered when its lease lapses" — there is no row and no lease. The loop now
computes the family's claimed (`dbrow`) ids once and branches: a claimed row
keeps the old line unchanged; a 404 for a beat alertid says there is nothing to
stamp and nothing to re-offer; any other rc for a beat alertid says there is no
lease here to re-offer it.

The write-through stays WIDE on purpose. Scoping it to `dbrow` ids would leave a
row from a writer-on box `new` after triage handled its family, and
`bin/alerts-medic.sh:154` lists `--state new --older-than 1200` — a second paid
session on a family already handled, which is the opposite of what BH-1071 was
for.

**3. Rollout ordering is written down.** `docs/verification-map/alerts-claims.md`
now says box writer side first, hub flag second, what "starved" looks like in
`logs/medic.log` when it is done the other way round, and the two acknowledged
limits (a non-refusal failed session is stamped `triaged`, parity with the file
path; a failed `parked` PATCH is not retried).

## The grep an operator uses

```
grep -E 'parked stamp|no table row|CLIFF REFUSED' /root/harness/logs/alert-triage.log
```

`parked stamp rc=` means the park did not reach the table: the local park file
stands, and the lease will re-offer that row once more.

## Verified by

`HARNESS_TEST_SANDBOX=1 bash tests/alerts-claims.bh-1327-test.sh` — runs the real
`bin/alert-triage.sh` through four cliff refusals and one ordinary tick, and
asserts the wire bodies, the write-after-record ordering (the fake curl stamps
`PARKFILE=<1|0>` next to every `parked` request), the dbrow scope, the flag-off
silence, and each of the three miss-line renderings.
