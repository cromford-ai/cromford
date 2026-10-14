# Priority yield and lane reaper: the #717 review follow-ups

Doc: BUILD-CONCURRENCY

## A late yield throws the execute stage away

A build that yields at boundary 2 (`YIELD_CHECK execute`) or boundary 3
(`YIELD_CHECK review`) has a finished execute stage, pushed to origin, and the
next build of that ticket does not pick it up on its own. It starts again from
the plan. `# >>> checkpoint adopt` only adopts a tip that still carries
`wip: checkpoint` commits, and by then `CKPT_SQUASH_WIP` has squashed them.
The yield's RESULT names the way back: re-run the ticket with
`TARGET_BRANCH=<branch>` and the next build lands on the pushed work.

## Two new files in a build dir

- `priority-rank`: one digit, written once by the build itself right after its
  claim is published. It is `0` when `HOTFIX=1` is in the build's environment,
  otherwise the rank `priority_rank_meta` reads off its `ticket-meta.json`. A
  requester that finds a sibling holding its claim takes the LOWER of this file
  and the sibling's meta rank. Either source can make a build urgent, and
  neither can demote it. Anything that is not exactly `0`, `1` or `2` is
  ignored. Before this, a sibling whose urgency came from its environment read
  as rank 2, and a rank-1 build could evict a hotfix.
- `YIELD_CLOSED`: empty, written by `YIELD_CHECK review` before it looks for a
  marker. Nothing checks for a YIELD after that boundary, so a requester that
  sees it writes no marker, keeps the 4h-ageout wake sentence and logs
  `past its last yield checkpoint`. A requester that wrote its marker first
  re-reads `YIELD_CLOSED` after the write and promises nothing if it is there.
  One side always sees the other's write, so a "yields at its next checkpoint"
  sentence is only written about a build that will still check.

A missing file means what it meant before: meta rank, and the yield is allowed.

## Lane reaper: a same-KEY pgid mismatch is unsignalable

`bin/lane-reaper.sh` used to call a live pid `gone` when its command line was a
`run-build.sh` of the SAME key but its process group was not the recorded one.
On a retry dir (our `ABANDONED_TIMEOUT` verdict, no `REAPED`) that finished the
reap: claim released, ledger row closed, an alert saying the kill landed, all
for a lane that was still running. It is now `unsignalable`. The dir keeps its
claim and verdict with no `REAPED`, and the reaper logs
`... does not match the live process group N of a live KEY lane, not reaped`
once per tick until the pid is gone. A pid now running a different key, or
nothing at all, still finishes the reap as before.
