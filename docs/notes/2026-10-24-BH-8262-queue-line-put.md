# READY-QUEUE lines are written key first, through one script (BH-8262)

Doc: OPERATING

## What changed

Triage sessions wrote `logs/READY-QUEUE.log` lines by hand. On the project-3 box 23
of 23 lines were timestamp-first. Every reader keys on `^[A-Z]+-[0-9]`, so the
lines were dead and TK-319 waited about 45 h. The readers now re-lead such a
line (`_rq_norm`, #8257). This change fixes the writer side.

The line shape:

    <KEY> <ticket-id> size=<S|M|L|XL> kind=<bug|feature|copy|migration|infra> :: <reason> project=<p>

- `bin/queue-line-put.sh <project> <KEY> <ticket-id> <size> <kind> <reason...>`
  writes that line under the `READY-QUEUE.log.lock` sidecar lock and mirrors
  the ready row through `rq_put` (after both locks are released). One line per
  key: a new key is appended, a changed line replaces all `^<KEY> ` lines
  (`harden-state.sh --release`/`--rearm` around the `mv`, lock order as in
  `queue-line-drop.sh`), the same line is left alone.

  | rc | meaning | stdout |
  |----|---------|--------|
  | 0 | written | `queued <line>` / `replaced <line>` / `unchanged <line>` |
  | 1 | lock timeout or write failure; file untouched; no row | none |
  | 2 | bad argument (stderr names the field); no lock, file untouched, no row | none |

  Refused: a key that is not `^[A-Z]+-[0-9]+$`, a size or kind outside the
  lists, a project that is not lowercase letters and dashes, a ticket-id with
  whitespace or `=`, an empty reason, a reason with its own `project=` token.
  Tabs and newlines in the reason become single spaces.
- `bin/queue-line-lint.sh [file]` prints `NOT-KEY-FIRST <lineno>: <line>` for
  each live line (not blank, not `#`) that does not start with `^[A-Z]+-[0-9]`,
  and exits 1. rc 0 when clean or when the file does not exist.
- `bin/decision-log.sh` (after every triage session, single and shard) runs the
  lint. When the set of bad lines changes it writes one line to
  `logs/ready-queue.log`:
  `<stamp> [ready-queue] [<p>] QUEUE LINE NOT KEY-FIRST: <n> line(s) in READY-QUEUE.log; first: <line>. Writers use bin/queue-line-put.sh (BH-8262).`
  The fingerprint is `state/queue-line-lint.fp`; a clean file removes it. No
  ALERTS line.
- The triage contract (`catalog/agent-contracts/triage-system-append.txt`,
  QUEUE LINE TAGS) and the project prompts state the shape and name the
  script. The PLAN_MALFORMED sentence in 19 prompts names the script instead
  of "write the ticket's queue line into READY-QUEUE.log".

## Knob

`QUEUE_LINE_PUT_LOCK_S` (settings row `lib.queue-line-put.queue_line_put_lock_s`,
registry `catalog/lanes.d/_lib.queue-line-put.json`): seconds the writer waits
for each lock. Fallback 30, the wait `queue-line-drop.sh` uses.

## Tests

`tests/queue-line-put.bh-8262-test.sh`.
