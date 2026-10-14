# The remote-gate cert reissue is bounded, off the live key, and locked

Doc: REMOTE-GATE

## What was wrong

`bin/remote-gate.sh` reissued its test-host ssh cert with
`flyctl ssh issue <org> <key> --hours 72 --overwrite`. On 2026-09-23 that call
hung: two issuers sat for 37 and 52 minutes and every agent's gate stalled behind
them. It had no stdin redirect, no time bound and no lock, and a fast failure
exited 125 even when the current cert still had hours left.

## What it does now

- flyctl writes into `mktemp -d <key dir>/.testhost-issue.XXXXXX` and never gets
  `--overwrite`. Once both files exist the key (chmod 600) and then the cert are
  renamed into place. A failed issue never touches the pair in use.
- The issue runs with stdin/stdout/stderr on `/dev/null` under a shell watchdog
  (`_rg_bounded`, no `timeout(1)` so Macs work): TERM past
  `REMOTE_GATE_CERT_ISSUE_TIMEOUT_S`, KILL 5 s later.
- Timed out, flyctl non-zero, or no key/cert written: the gate goes on with the
  current cert if it has more than 0 seconds left (one `WARNING` line) and exits
  125 only when it is missing or expired. Validity is decided in seconds
  (`_rg_cert_secs_left`), because integer hours read "expired 30 minutes ago" as 0.
- `flock` on `<TESTHOST_KEY>.issue.lock`. With a still-valid cert the gate takes
  it with `-n` and, if it is held, uses the current cert without waiting. With no
  usable cert it waits at most the timeout + 15 s, re-reads the cert, and issues
  only if nobody else just did. No `flock` on PATH: issue unlocked, with a note.

## Knob

`REMOTE_GATE_CERT_ISSUE_TIMEOUT_S`, settings row
`lib.remote-gate.remote_gate_cert_issue_timeout_s`, registry default 60 s
(5..600) in `catalog/lanes.d/_lib.json`, resolved by `lib_env_apply remote-gate`
in `_rg_knobs`. A value that is not a whole number ≥ 1 is exit 125 before any
flyctl call.

Pinned by `tests/remote-gate.bh-1836-test.sh`; `tests/remote-gate-test.sh` 2b now
asserts `--overwrite` is never passed.
