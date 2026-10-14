# The remote-gate cert reissue is locked on a Mac too, and its watchdog kills the group

Doc: REMOTE-GATE

## What was wrong

The lead review of #1851 (BH-1836) left two gaps in `bin/remote-gate.sh`:

- Where `flock` is missing (macOS, which is where lead fix agents run the gate,
  several at once) the reissue ran unlocked. The key and the cert move in two
  separate renames, so two issuers finishing together could leave one issuer's
  key beside the other's cert: a pair that reads valid for 72 h and fails every
  ssh auth.
- The watchdog in `_rg_bounded` killed only the flyctl pid, so any helper
  flyctl had started lived on past the gate.

## What it does now

- No `flock`: the lock is `mkdir <TESTHOST_KEY>.issue.lock.d`, with an `owner`
  file of `<pid> <epoch>`, and the same two modes as the flock branch: a gate
  whose cert is still valid tries once and never waits; a gate with none polls
  for at most the timeout plus 15 s, then falls back or exits 125. Either way
  the cert is re-read under the lock, so N concurrent gates issue once.
- A lock is stale when its pid is gone or when it is older than twice the
  timeout plus 15 s (a recycled pid, a wedged holder). Twice, so a waiter's
  own bounded wait ends first and a live holder is never stolen from. It is renamed to a tomb and
  dropped only when the tomb's owner is the one judged stale. The gate's EXIT
  trap releases a lock it holds, and only while the owner is still its own.
- `_rg_bounded` starts the command in its own process group (`set -m` for that
  one fork) and the watchdog signals the group, falling back to the pid where
  the group cannot be made.

Tests: `tests/remote-gate.bh-1854-test.sh` hides `flock` from PATH and drives
four concurrent gates through the real CLI.
