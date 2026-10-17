# A merge-queue batch drops the always-suites the pre-push gate already ran (BH-7289)

Doc: MERGE-CONDUCTOR

Wave 3 of #7033. The pre-push gate (`bin/prepush-gate.sh`, BH-7187) runs the fast always-suites
(`bin/fast-lints.sh --run`) and the rules-pack suite components on the builder, on the head it
pushes. Every merge-queue batch then ran all 76 always-suites again.

**The list.** `catalog/test-impact-always-prepush.txt` holds the 65 always-suites the gate runs
(63 fast-lints suites at the seed durations c9063c6b9, plus 2 rules-pack suites). Regenerate it
with `ppr_list_build` (`bin/lib/prepush-record.sh`). The suites keep their lines in
`catalog/test-impact-always.txt`, because that file feeds the gate's own list.

**The record.** After the gate, `bin/lib/rb/pr.sh` (the `prepush gate` span) writes a
`prepush-gate-record v1 head=<sha>` block into the PR body. It names each suite the gate ran
green on that head: a fast-lints row with rc 0, and a green rules-pack suite component when the
rules-pack row is green. No lib, no readable HEAD or no green suite writes no record.

**The drop.** In the plan job of a batch, `bin/ci-plan.sh` reads each member's PR reply that
`member_full` already fetched (no new gh call). It drops the list ∩ every member's record ∩ the
run's list, minus the quarantine. The regression list adds a suite back. A member with no record,
a record for another head (a fix round or a rebase moved it), the `full` label or unreadable
members turn it off: `ci-plan: prepush: off (<why>)`. When it runs: `ci-plan: prepush: dropped
<k> of <m> listed suites (<n> members, …)`, the output `prepush=<k>` and `; prepush -<k>` in the
reason. The plan job writes `prepush-drop.txt` into the `ci-durations` artifact. Each shard
subtracts exactly that file, and an unreadable file is rc 1.

**The knob.** `CI_ALWAYS_PREPUSH_SKIP` on the `ci-plan-settings` lane (the master's
`ci.cromford.always_prepush_skip`), default 1. `bin/ci-plan-settings.sh` projects it into the
repo variable (tick field ` prepush=<r>`, alert `ci-plan-settings-prepush:<slug>`). Set it to 0 to
roll back.

**Known risk.** Two members can each be green on their own head and red on the merged tree for a
whole-tree ratchet. The batch does not catch that red now. The nightly full run still runs the
whole corpus.
