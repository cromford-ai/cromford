# Every triage tick counts what it paid for unchanged input (BH-3926)

Doc: TRIAGE-STATE

## What changed

- `bin/lib/triage-state-waste.sh` has bodies now (BH-3923 shipped the stubs).
  Every triage-state tick line ends its last bracket with
  ` paid_unchanged=N`: the in-scope, non-work tickets the model was paid to
  read whose input hash still matched their last verdict. `?` when the rows
  were unreadable, never 0.
- The single session's cost row carries `ts:new=N:chg=N:due=N:cap=N:unr=N:pu=N`
  (`bin/lib/rt/launch.sh`), and each shard's row carries `ts=<class>`
  (`bin/triage-shard.sh`, from its dispatch snapshot).
- Under enforce, `state/triage-state/<p>/paid-unchanged.streak` counts ticks in
  a row with a count > 0. At exactly 3, one warn alert
  `triage-paid-unchanged:<p>`. Shadow never touches it.
- New worker route `GET /api/metrics/triage-paid-unchanged` and the /costs
  section TRIAGE PAID UNCHANGED, each count drilling to that day's triage cost
  rows.

## Why

Triage-state decides which tickets go to the model, but nothing measured what
was still paid for unchanged input once it did. This is that number, per tick,
per cost row and per day.

Details: [docs/triage-state/paid-unchanged.md](../triage-state/paid-unchanged.md).
