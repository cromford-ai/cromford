# pr-owner-sweep's hand-back is the row, and only the row (BH-2530.3, BH-2673)

Doc: PR-OWNERSHIP

## What changed

`bin/pr-owner-sweep.sh` `handback` used to clear the `ledgers(kind=commented)`
row `blocked <project> <KEY>` and then, depending on where the project lived:

- on a locally owned project, rm the stamp files a second time and answer 0
  whether or not the row write landed;
- on a remote box with the row unwritten, look up `fleet.conf`'s `tailnet_ip`
  and ssh `rm -f` the stamps there.

Since BH-2317, `cm_clear` already removes this box's own stamps, and `cm_has`
lets a `cleared` row outvote any stamp left on any box. So the hand-back is now
the row write alone:

- row written: rc 0 and one line naming the cleared row;
- row not written: one line,
  `<project>/<KEY>: row not written; jobs DB unreachable; the hand-back is retried next sweep`,
  and rc 1. The caller records `held=#N:handback-failed`, and the next sweep
  classifies the same ORPHAN again and retries. There is no file fallback.
- DRY-RUN: `DRY-RUN would: clear row blocked <project> <KEY>`, nothing written.

The `PR_OWNER_SSH` knob is gone with the ssh call. A locally owned project with
the jobs DB down now answers rc 1 where it used to answer 0. The stamp file is
still removed, but the un-cleared row still reads as "already commented", so
the ticket was never re-offered and rc 0 was not true.

`docs/config-inventory/inventory.json` still lists `PR_OWNER_SSH` until the
next inventory regenerate. That file is generated, and this change does not
regenerate it.

## Verified by

`tests/marker-rm-gone.pr-owner.bh-2530-test.sh` drives the real sweep over one
ORPHAN with the worker up, down (remote and local), and in DRY-RUN.
`tests/pr-owner-sweep-test.sh` section 3 and `tests/comment-mark.bh-2317-test.sh`
A9/A10/A10l pin the same behavior.
