# One bounded entry point for a test-host cert by hand

Doc: REMOTE-GATE

## What happened

From 2026-10-05 to 2026-10-07 a session issued a Fly test-host ssh cert by
hand: the issue with --overwrite, into a scratch path that already held a
non-fly file, with its output redirected to a file. flyctl looped on
`File exists, but isn't a fly.io ed25519 private key` for 44 hours. The file
reached 596 GB and the disk ran out (ENOSPC).

The gate's own issue path was already bounded (BH-1836, BH-1854, BH-1918). The
hand path was not, because there was no hand path to take.

## What changed

- `bin/remote-gate.sh --issue-cert [--force]` issues (or keeps) the cert and
  exits. It runs the gate's knob resolution, lock, temp dir beside the key,
  watchdog and signal handling, and nothing after them. `--force` replaces a
  cert that is still fresh. Exit 0 = a cert is in place, 1 = the issue failed
  but the current cert is still valid, 125 = no valid cert, 2 = command line.
- The issue's output is no longer thrown away, and never unbounded. It goes
  through `head -c 1048576` into the temp dir, which is removed on every path,
  a signal included. A flyctl that loops is cut off by SIGPIPE at the cap, or
  by the watchdog. The one WARNING line now ends with `flyctl said: <its last
  line>`, and says when the output hit the 1024 KiB cap.
- `bin/issue-testhost-cert.sh [--key PATH] [--org ORG] [--hours N] [--force]`
  is the documented hand entry point. It validates its arguments and execs the
  gate's `--issue-cert`.
- `docs/REMOTE-GATE.md`, `skills/harness/SKILL.md` and the repo `CLAUDE.md` say
  never to run the issue directly, and name the wrapper.
- `tests/flyctl-issue-guard.bh-5210-test.sh` fails on a raw issue with
  --overwrite in `bin docs skills orchestrator prompts rules CLAUDE.md`, and on
  any script in `bin/` other than the gate that runs the issue.
  `tests/issue-testhost-cert.bh-5210-test.sh` drives the wrapper against a
  spewing, a SIGPIPE-ignoring, a dripping, a failing and a good flyctl.
