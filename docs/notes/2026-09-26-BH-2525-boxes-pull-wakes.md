# Every box pulls its own wakes

Doc: EVENTS

BH-2637 (BH-2525.2), the third slice of #2525. `bin/wake-loop.sh` now runs on
every box, claims its own wake rows, keeps its watermark in the `wake_cursors`
row and takes launch cooldowns from `wake_cooldowns`. It no longer sshes. The
contract (BH-2635) and the routes (BH-2636) shipped first.

## What changed

- **Placement.** `cron/lanes/020-wake-loop.cron` gives every box an ungated
  `* * * * * /root/harness/bin/wake-loop.sh`. The hub keeps its lease-gated line
  inside its hub-lanes block. `catalog/lanes.d/wake-loop.json` is now
  `scope: box` on all ten boxes, and registers `WAKE_CLAIM_LIMIT` (int, default
  200, 1..500).
- **Identity, once per invocation.** `BOX` comes from `bin/box-name.sh`,
  lowercased once, because the worker matches box names case-sensitively and the
  seeded cursor rows are lowercase. `IS_HUB` comes from `bin/lib/hub-box.sh`.
- **Ownership.** A project is this box's when `bin/box-for.sh` answers this box's
  name, or `local` on the hub. The claim asks for those repos, lowercased. The
  hub also asks for every repo's `pr`/`checks` rows, because the merge conductor
  is fleet-wide and hub-only. A box that owns nothing makes no request and logs
  `owns no fleet repo — nothing to claim`.
- **The claim.** `drain()` calls `wakes_claim` instead of `wakes_list`. A row
  whose repo is not a fleet project is dropped as before. A row for a project
  this box does not own is dropped too (the worker already filters; this is the
  second guard), except the hub's `pr`/`checks` rows. Only the hub sets
  `want_conductor`. A box's own `pr` rows still reach the wake classes, so
  `pr-ci` still drives `review-prs` on the owning box.
- **The cursor row.** No `state/wake-cursor`, and no `wake-cursor.<box>` settings
  mirror or seed. After the launches the loop PUTs `scanned_top` (only when it
  moved) and then acks. A failed PUT is one log line and the ack still runs. The
  claim rows are the guard against a second launch, not the cursor.
- **First-cutover seed.** Before the first claim, a box with no cursor row adopts
  the hub's row once (`cursor seeded from the hub's: N`). The schema seeded rows
  only from the hub's settings mirror, so without this every other box would
  claim 30 days of backlog on its first minute and launch a triage session or a
  deploy train per stale row. No hub row either: it claims from 0. An unreadable
  cursor GET claims nothing that cycle.
- **Cooldown rows.** `cooled <kind> <project> [window]` keeps its name and
  signature and calls `wake_cooldown_take`. Only `taken:true` launches. An
  unreachable row logs `cooldown row unreachable — cron covers <kind>[<project>]`
  once per (kind, project) per invocation. Before any request it decides whether
  this box may take the row at all:
  - project `fleet`: the hub only;
  - a kind that is a hub-scoped lane id in the registry: never off the hub;
  - another box's project: only for a lane this box's crontab already runs for it
    (`lane_runs_here`), or a hub lane on the hub. The rows are shared and keyed
    (kind, project), so a hub that took `review-prs X` and then declined to launch
    would leave the owning box `taken:false` every time.
  `state/wake-cooldown/` is gone. The cap-before-cooldown order at the conductor
  is unchanged, and it only runs on the hub.
- **Hub lanes stay on the hub.** `launch()` off the hub refuses any script the
  lane registry scopes to the hub, because the class libs launch hub lanes
  directly (`flaky-detect`, `prompt-eval`, `fleet-propagate`, `review-autopilot`,
  `alerts-groom`, `check-migration-prs`, `tickets-snapshot-push`). An unreadable
  registry refuses every launch off the hub, with one log line per invocation.
- **No ssh.** `ssh_triage()` and `remote_launch_ssh()` are deleted.
  `launch_triage` and `remote_launch` launch here when this box owns the project
  (or, for `remote_launch`, when its crontab runs the lane). Any other box is
  `owned by <box> — its own loop claims this wake` and nothing else. That box's
  own loop claims the same wake, and its cron covers it regardless.
- `bin/restore-merge.sh` stops listing `state/wake-cursor`.

## What it costs

- Every non-hub box now makes one claim request per 15-second cycle (four a
  minute), plus a cursor PUT only when its watermark moved.
- Wake shortcuts for HUB lanes on box-owned projects that only a push or deploy
  row can trigger now fall back to their hub cron lines: `prompt-eval` /
  `fleet-propagate` on a cromford push (cromford is owned by
  `box-small`) and `migration-autopilot` on a box project's deploy.
  The hub never claims those rows, and the owning box refuses hub lanes.

## Left in place

`state/wake-cursor` and `state/wake-cooldown/` on boxes that ran the old loop
are dead. Nothing reads them and nothing deletes them.
`state/wake-keys/pending-<project>` stays a local file, written by the owning box.

## Tests

- `tests/wake-loop-claims.bh-2637-test.sh`: the acceptance cases, and four
  mutations of the loop that each turn a case red.
- `tests/lib/wake-claim-stub.sh`: the wake routes over files, shared by every
  suite that drives the loop.
- `tests/wake-cursor-writethrough.bh-1034-test.sh` and
  `tests/wake-cursor-key-lowercase.bh-1267-test.sh` are rewritten to pin the
  cursor row and the lowercase box key.
