# The flaky F1d was a real lock leak in remote-gate's mkdir lock, not a test race

Doc: REMOTE-GATE

## What changed

- **`_rg_mlock_try` in `bin/remote-gate.sh` no longer reclaims a lock that was
  just released.** When a gate's `mkdir` fails and the lock dir is gone by the
  time it looks, the gate returns "not taken". A waiter polls again a second
  later and takes the free lock. A gate with a still-valid cert uses it, and
  that's right because the holder that released has just reissued.
- **A reclaim tomb goes back only when it carries an owner.** A tomb with no
  owner file belongs to a gate that was between `mkdir` and its owner write.
  That write targets the lock path, which is no longer its dir, so it fails,
  and the gate retries. The tomb is dropped. A tomb with an owner (a live gate
  that re-took the lock) still goes back, unchanged.
- New suite `tests/remote-gate.bh-2049-test.sh`, which pins both races and the
  put-back that must stay.

## Why

`tests/remote-gate.bh-1854-test.sh` F1d failed on CI ("the lock dir ... is still
there after every gate returned", 21 passed, 1 failed). The test isn't racy. F1
`wait`s every gate pid, and a gate's EXIT trap (which releases the lock) runs
before that pid returns. The leak came from two interleavings in `_rg_mlock_try`:

1. Gate B's `mkdir` fails because A holds the lock. A releases before B's
   `[ -d ]` check, so B fell through into the stale-reclaim path. Gate C
   `mkdir`s the free lock. B moves C's not-yet-owned dir to its tomb, sees
   the tomb's empty owner doesn't match what it read, and puts it back. That
   leaves an owner-less lock nobody holds.
2. Two reclaimers of one stale lock. The second moves the first's fresh
   owner-less dir to its tomb and puts it back the same way.

An owner-less lock only reads as stale once it is twice one issuer's worst case
old (`2 * (REMOTE_GATE_CERT_ISSUE_TIMEOUT_S + 15)` s). Until then every gate with
no usable cert waits its full bound and exits 125. Only hosts without `flock`
(the Macs running lead fix agents) take this path. The flock branch is untouched.
