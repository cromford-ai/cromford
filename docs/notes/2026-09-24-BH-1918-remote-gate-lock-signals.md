# The remote-gate mkdir lock exits on a signal, keeps a torn owner, and reclaims one at a time

Doc: REMOTE-GATE

## What changed

These are the #1910 review follow-ups to BH-1854, all in `bin/remote-gate.sh`.

- **INT and TERM end the gate.** The old `trap _rg_cleanup EXIT INT TERM`
  released the lock and then kept going. A TERM during `flyctl ssh issue` made
  `wait` return 143, which the gate read as "flyctl exited 143". It then fell
  back to the current cert and ran the job with no lock held, and the hung
  flyctl lived on. Now `_rg_on_signal` sends the signal to the issue's process
  group. For INT it also sends a TERM, because a non-interactive wrapper starts
  its background helpers with INT ignored. It stops the watchdog and exits 130
  (INT) or 143 (TERM), and the EXIT trap does the cleanup. A signal that lands
  while a foreground child runs (`flock -w`, the final `ssh … bash -s`) still
  waits for that child to return. Bash has always done that.
- **An owner that does not parse is live.** A torn read like `"12345"` (no
  space) used to make the lock look ancient, and a garbled owner counted as
  "no one's". Either way a live lock got stolen. `_rg_mlock_owner` now reads
  the owner up to three times. An owner that still isn't `<digits> <digits>`
  gets the no-owner-yet rule: live until the lock dir is older than twice the
  issuer's bound. So a garbled lock can't wedge reissues forever.
- **Reclaims are serialized.** A reclaim now takes a second `mkdir` lock,
  `<TESTHOST_KEY>.issue.lock.d.reclaim`, and holds it only for the reclaim.
  Under it the gate re-reads and re-judges the owner, renames the stale lock
  to a tomb unique to that attempt (`.tomb.<pid>.<random>`), removes the tomb,
  makes the lock again and reads its own owner back. Every plain take reads its
  owner back too. The old per-pid tomb and check-then-act put-back could end
  with two holders when three gates raced on any stale lock. A reclaim mutex
  older than a minute belongs to a reclaimer that died mid-reclaim, so the gate
  removes it and the next poll retries.

## Residual risk, accepted

Two gaps remain. Both need a stale-mutex removal racing a fresh mutex, or a
wedged over-age holder that releases in the exact instant between another
gate's re-judge and its rename. And the first also needs a reclaimer killed
with SIGKILL inside a few statements.

## Tests

`tests/remote-gate.bh-1918-test.sh`: S1/S2 (signals), O1-O4 (owner reads),
R1/R2 (stress: 6×8 gates without a cert wait, 3×6 with one, zero overlapping
issues). R1/R2 are probabilistic. A green run is evidence, not proof.
