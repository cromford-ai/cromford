# Triage shards settle a no-signal ticket change without a session

Doc: COST

## What was wrong

The per-ticket fingerprint (BH-1015) hashes the ticket's live board entry. On
an in-app board that entry carries `commentCount`, `lastActivityAt`,
`waitingOn` and `triageVerdict`; on a GitHub board it carries `comments` and
`updatedAt`. Our own comment, a label edit, or the `waitingOn` /
`triageVerdict` a triage session writes all move it. The tick-level absorbers
(`bin/gate-selfwrite.py`, `bin/lib/gate-self-comments.sh`) only help when every
change on the board is ours. So once one real change made a tick RUN, every
other key whose only change was that churn bought a session again.

## What changed

- `bin/triage-signal.py --kind inapp|gh` hashes one thread down to what a human
  wrote: title, body/description, status/state, and every comment that is not
  ours as (id, author, body), plus priority (in-app field, GitHub priority
  labels) and the ticket's attachments by identity (never a signed URL's query
  string). Other labels, assignees, milestone, counts, timestamps, `waitingOn`,
  `triageVerdict`, `turn` and our own comments are left out. "Ours" is decided
  by the AUTHOR only: in-app, an author equal to the gate's `SELF_ACTORS` or our
  `author_actor` marker (`agent:build-harness`), never a human-settable
  `displayName` or an `authorName` beside an author object; GitHub, one of our Apps
  (`HARNESS_SELF_APPS`, the BH-2133 rule). `isInternal` is NOT a reason: on the
  project-9 contract it also marks a human on the delivery team. A comment a
  machine recorded for a person (`author.recordedBy`), the PAT login and other
  bots count as human. An unknown shape, or more than 300 GitHub comments, is
  rc 1.
- The turn: a key whose `waitingOn` came back to the team since its stamp
  (stamp line 4) is never settled, so a person handing the ticket back gets
  its session now. A flip away from the team settles; our own sessions write it.
- Every settle appends one priced-$0 row to `logs/cost.csv` (stage
  `triage-precheck`, row_source `refused`, note `settled:no-signal`, the ticket
  in its column, lane `run-triage`), so fleet-cost and the per-stage views count
  the sessions not bought.
- A GitHub board with `HARNESS_SELF_APPS` empty never settles: one project-log
  line per tick and one ALERTS line per project per day say so.
- `bin/triage-gate.sh <p> --signal <key>` reads the whole thread
  (`board-fetch.sh --full`, or the GitHub issue plus up to three comment pages)
  and prints that digest. It writes no state, takes no lock and never prints
  RUN/SKIP.
- `bin/lib/triage-signal.sh` builds the SIGNAL fingerprint: `triage_shard_fp`
  with the live board entry replaced by the digest (its new optional 6th
  argument), so the queue line, PR states and build dirs still count.
- `bin/lib/rt/shards.sh`: when a key's fingerprint moved and its stamp is inside
  `TRIAGE_SHARD_FP_TTL_S`, an equal signal fingerprint settles the key. No
  session; the stamp takes the new world fingerprint and keeps the old epoch,
  so the 4-hour backstop still fires. A dispatch stores the signal fingerprint
  as stamp line 3 of `state/triage-shards/<p>/<key>.fp`. The dispatch summary
  gains ` — no-signal: <keys>` when any key settled.
- It fails open: knob off, no board line, a `pr-*` key, a ticket that left the
  board, the read cap spent, a low GitHub budget or a failed read all dispatch
  exactly as before.

## Knobs

`catalog/lanes.d/_lib.triage-signal.json`, env then `env/global.env`:

- `TRIAGE_SIGNAL_SETTLE` (default 1). 0 = off, today's behaviour byte for byte.
- `TRIAGE_SIGNAL_MAX_READS` (default 10 per tick per project). 0 = no reads.

## Probe

```
grep 'no-signal' /root/harness/logs/<p>.log | tail
sed -n 3p /root/harness/state/triage-shards/<p>/<key>.fp
```

The `stage=triage` rows in `logs/cost.csv` should fall on ticks where only
our own writes moved, and every settle is a `triage-precheck` row:

```
awk -F, '$4=="triage-precheck" && $24=="settled:no-signal"' /root/harness/logs/cost.csv | wc -l
``` `tests/triage-signal.bh-2542-test.sh` pins it.
