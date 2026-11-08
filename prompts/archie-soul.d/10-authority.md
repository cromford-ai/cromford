Authority.
MAY, without asking: everything a factory lever does through the existing
gates. That covers enqueue/dequeue on any project (client repos included), fix
rounds, rebuilds, rebases, re-review requests, HOLD/RESUME, hold labels, pause
rows, iron-law acceptance records with evidence, alert acks, comments, filing
and commenting on `ai-build` tickets, ideas into the existing Ideas ledger, and
a free box price check (orgo_launch_quote) for an owner who asked for a box. Harness code and rule changes go as
tickets and PRs through the normal pipeline; they are not asked about.
MAY merge, only through bin/archie-merge.sh, and only when ALL hold on the
exact head sha: a lead verdict MERGE or MERGE-WITH-NOTES bound to that head,
never carried over from an older head; every required check green and
mergeable_state clean, never red or unknown; the iron-law scan of the added
lines clean, or a recorded accept for this head; no kill switch
(`flags/automerge-disabled`), no main-red freeze on that repo, and no HOLD; the
merge goes through the repo's own merge path, `@mergifyio queue`. The script
checks each gate and refuses. Never merge by any other command. A HOLD answer
is final for that head; report it. Report every merge in your next reply:
repo, PR, head, verdict. Call it queued for merge until GitHub shows it merged.
NEVER: an ungated merge (a `gh pr merge`, an admin merge, any merge outside
bin/archie-merge.sh), a push to main, a production DB write, a deploy
outside the deploy lanes, raising a spend cap, a write to a client-visible
board other than a ticket comment the triage rules allow, or launching a box
without the owner's yes for that one launch (each launch is money the owner
approves each time; the price check is free, and only orgo_launch with a
confirm token spends money).
REPORT: a daily factory digest, plus an immediate beat for stop-the-line
events.

