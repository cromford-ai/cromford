# The wake loop owes a conductor run it could not launch, and a checks wake's sha names its PR

Doc: MERGE-CONDUCTOR, EVENTS

BH-3453, child 1 of BH-3436 (why the webhook wake missed project-5#3415). Only
`bin/wake-loop.sh` changed. The conductor, the worker and the cron lanes did not.

## What was wrong

- **Held or refused wakes were forgotten.** On the hub, a pr/checks wake held by
  the per-invocation cap (`WAKE_CONDUCTOR_PER_TICK`) or refused by the
  `pr/fleet` cooldown (taken:false, or the row unreachable) was acked and
  nothing remembered it. The comment said "cron */5 keeps firing", but
  `cron/lanes/410-merge-conductor.cron` has been `*/30` since BH-1389.
- **A checks wake's key was thrown away in keyed mode.** `check_suite` and
  `check_run` wakes carry the head sha as their key (`wakeOf` in
  `worker/jobs/src/lib/core.js`). With `WAKE_CONDUCTOR_KEYED=1` only all-digit
  keys were kept, so a batch of `pr A` plus the checks wake for #3415 launched
  `MC_ONLY_PR=<A>` and the conductor filtered #3415 out.

## What changed

- **The owed marker, `state/wake-conductor-owed`.** When a drain wants the
  conductor and does not launch it (cap or cooldown), it appends one
  `owner/repo#n` per key, or a single `*` when the batch held a wake that named
  no key, before the wake is acked. Log line:
  `pr/checks: conductor run owed — <n> line(s) in state/wake-conductor-owed (cap|cooldown)`.
  The existing "conductor launch held" line is unchanged.
- **The debt is paid once per drain**, right after a successful claim and before
  the empty-drain return, so a drain with no rows still pays. It respects the
  cap, takes `cooled pr fleet` with the same window as a batch launch
  (`conductor_window`), moves the file to `wake-conductor-owed.taking.<pid>`
  first, and launches keyed on its deduped lines. It launches unkeyed when a
  line is `*`, `WAKE_CONDUCTOR_KEYED=0`, or there are more than 50 keys. A
  launch that cannot start puts the lines back. A refused cooldown or
  `flags/wake-loop-off` leaves the file alone. The pay counts against the cap,
  so a batch in the same cycle is then owed for the next one.
- **Checks shas resolve to PR keys** (keyed mode only). A `checks` key of 7-64
  hex characters is looked up in `state/merge-conductor/pr-state.tsv` (column 1
  key, column 4 head) with one awk pass per drain: same repo, prefixes compared
  both ways, 7-character floor (the `mc_hb_blocks` rule). A match adds the key.
  No match, or no readable file, makes the launch unkeyed (the full tick, the
  safe direction). Other non-numeric keys (`-`, `abc12`, `zzzzzzz`) still add
  nothing and do not force unkeyed. `WAKE_CONDUCTOR_KEYED=0` is unchanged.

## Not in this change

- The `*/5` conductor backstop lane is sibling #3454, filed and not shipped.
- A stale `wake-conductor-owed.taking.<pid>` left by a crash between the move and
  the launch is not replayed. The `*/30` cron tick covers it.

## How to check on the hub

`grep 3415 /root/harness/logs/wake-loop.log /root/harness/logs/merge-conductor.log`
says which of the two causes fired for project-5#3415. The builder could not
read hub logs, so that is unconfirmed here. Suite:
`tests/wake-loop-conductor-owed.bh-3453-test.sh`.
