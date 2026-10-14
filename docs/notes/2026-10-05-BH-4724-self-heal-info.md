# BH-4724: self-heal notices go info, and the daily digest counts them

Doc: ALERTS-STATE-MACHINE

## Why

Two notices report a fix the harness already made, and both paged as critical:
`[<project>] BUILD RESTARTED on the fresh harness` from `bin/context-gate.sh`
and `rescued review = APPROVE` from `bin/review-rescue.sh`. Neither passed a
`--severity`, and alert-line's default is critical. Nobody has to act on
either one. Split child 5 of 5 of #4717.

## What changed

- New `bin/lib/self-heal.sh`, `self_heal_note <source> <stable-key> <text>`.
  It writes the line through `alert-line.sh --severity info`, so beat.sh logs
  `info-only` and sends nothing. Then it fires a detached
  `jobs-client.sh ledger-put self_heal <source>:<stable-key> logged <text, 300 chars>`
  and never waits on it. The root is `${HARNESS:-${H:-}}` only; an empty
  root returns 1 before any write.
- `bin/context-gate.sh` calls it with key `<project>:<build-dir basename>`.
  `bin/review-rescue.sh` calls it with key `<project>/<KEY>:<candidate basename>`.
  Both keep the notice text byte for byte, and fall back to a raw
  `alert-line.sh --severity info` when the lib is not on the box yet. Exit
  codes are unchanged.
- The GIVING UP / hand-off lines in review-rescue and context-gate's
  DEFERRED / REFUSED lines are not self-heals and still page as critical.
- `GET /api/metrics/daily-digest` has a new state section,
  `self_heals {ok, n, by_source, rows, truncated}`, read from `ledgers` kind
  `self_heal` on `created_at`. A re-put of the same key keeps `created_at`,
  so one event is counted once, on its first day. A missing table is
  `ok:false`, never 0. It is not in the quiet-day sum.
- `bin/lib/daily-digest-render.sh` prints
  `Self-healed: <n> (<source> <n>, ...) <console>/alerts` after Tripwires. A
  digest JSON without the key (an older worker) prints no line.

## Not changed

If a beat fails, alert-line writes no sent-marker, and `poll-commands.sh`
re-beats the ALERTS.log line with no severity, so that one can still page.
Every `--severity` caller has that behavior today. Fixing it is a fleet-wide
alert-line change and is not part of this ticket.
