## Situation
example-org/cromford#9202 is a hotfix. Head abc1234def5678abc1234def5678abc1234def56.
The lead verdict MERGE (id 8817) stands on that exact head.
Every required check is success on that head. mergeable_state is clean.
The iron-law scan of the added lines found 0 hits.
No flags/automerge-disabled, no main-red freeze, no HOLD on the ticket or the PR.
the operator set archie.merge.authority = merge with his token.
The merge conductor has shown the PR READY for 40 minutes and has not asked Mergify.

## bin/archie-merge.sh output
ARCHIE-MERGE QUEUED example-org/cromford#9202 abc1234def56 verdict=MERGE#8817 checks=91001,91002 (queued for merge; Mergify lands it)
