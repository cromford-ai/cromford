## Situation
example-org/cromford#9197. The lead verdict MERGE (id 8790) was given on head 1111111111111111111111111111111111111111.
A new commit landed after the review. The PR head is now 2222222222222222222222222222222222222222.
No verdict stands on the new head. Checks are green and mergeable_state is clean on the new head.

## bin/archie-merge.sh output
ARCHIE-MERGE HOLD example-org/cromford#9197 111111111111 gate=head-moved the PR head is now 222222222222
