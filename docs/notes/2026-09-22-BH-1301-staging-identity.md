# BH-1301: a staged result is consumed only on positive proof, and a rescue keeps the provenance that supplies it

**What happened.** BH-1284 gave `bin/lib/rt/staging.sh` a fallback for the
results that carry no cross-path identity (`machine_build_dir` on the relay json,
`detail.build_dir` on the ledger row — both written only by code newer than
BH-1041): read the markers each path stamps into the RESULTs it stages
(`BUILD_DIR:` from the relay loop, `JOB_ID:` from the ledger loop) and decide
from those whether the arriving result is the other path's copy of a build
already on disk. The condition it shipped was `RR_KEY_HAS_ANY <key> &&
! RR_KEY_HAS_MARK <key> <own marker>` — "this ticket has SOME staged dir and none
of them is mine". That is also true when NO dir carries either marker, and those
dirs exist: `bin/review-rescue.sh`'s APPROVE branch wrote `$CAND/RESULT` wholesale
from three echo lines (`PR_CREATED`, `TIER:`, `RESCUED:`), dropping `TICKET_ID:`,
`SOURCE:`, `JOB_ID:`, `BUILT_AS:` and `BUILD_DIR:`. Its candidate walk is
`find $H/builds -maxdepth 2 -name RESULT -mmin +90`, so relayed and
ledger-staged `<project>-<KEY>-remote*` dirs on a hub-local project are
candidates and lost their markers as a matter of course. A ticket whose only
history was such a dir therefore consumed the next result it saw, marked it
`.handled`, and posted no close-out at all — and nothing re-reads a `.handled`
json or a `.job`-marked row, so that close-out is gone.

**The fix.** Three changes, no new state and no change to the identity itself:

1. `bin/review-rescue.sh` rewrites RESULT ADDITIVELY: the new header, then
   `sed -e 1d -e '/^RESCUED: /d'` (plus `-e '/^TIER: /d'` when this rescue has a
   tier of its own) over the old file, written to `RESULT.tmp` and `mv -f`'d into
   place so a crash leaves the old file whole. A missing or unreadable old RESULT
   degrades to exactly the three-line file it wrote before.
2. Both loops in `bin/lib/rt/staging.sh` consume only on POSITIVE proof — a dir
   carrying the OTHER path's marker, with none carrying this path's. A ticket
   whose dirs carry neither marker is staged, and the project log says so.
3. The undecidable case — both markers present, arriving result identity-less —
   keeps today's outcome (stage) and stops being silent: a project-log line every
   tick and one `logs/ALERTS.log` line per project per day under a new
   `relay-bypass` flag tag, separate from `relay-consume` so neither eats the
   other's day.

The cross-path identity is unchanged. `machine_build_dir` ↔ `detail.build_dir`
(the machine's own build dir, written onto the staged RESULT as `BUILT_AS:`)
stays the key; making the rescue keep that line is what makes it carried by both
senders in practice rather than only in principle.

**Verification.** `tests/staging-identity.bh-1301-test.sh` drives the real
`rt_stage` against synthetic histories: §E1/§E2 (marker-less history + an
identity-less json / row → staged, not consumed), §E3/§E4 (both-path history →
staged, one log line per tick, one ALERTS line per day, own flag tag), §C (the
BH-1284 consume still fires on single-other-path history, both directions, and
project-3 TK-139 still stages), §I (an exact `BUILT_AS:` match short-circuits the
fallback entirely). `tests/review-rescue.bh-1301-test.sh` runs the real
`bin/review-rescue.sh` against a real bare origin and clone with a fake `gh` and
a stub reviewer, and asserts the ledger shape, the pool shape (`BUILD_DIR:`,
`WARM:`, `ARTIFACT:`, an old `TIER: 2`), a second rescue, and the degraded
one-line case. Mutation-checked: deleting either bypass alert, turning the ledger
consume back into a stage, and restoring the wholesale RESULT write each turn one
of the suites red.

**Not taken.** A second identity field (a job id on the RESULT and both relay
payloads), switching the own-path markers to `SOURCE:`, and consuming rather than
staging in the both-path case — all three are in the plan's ASSUMPTIONS with what
they would have cost.

Doc: remote-result-relay-once
