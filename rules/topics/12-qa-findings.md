## QA findings: collect first, one ticket per screen or flow (the operator, 2026-10-15)

When the factory tests, it must act like one engineer who reads every problem before opening a ticket. Ten tickets for one screen is ten PRs that collide on one file.

1. A QA pass never files a ticket per finding. It writes every finding to one ledger for the run, grouped by screen or flow (route or flow name), with severity, repro and cause.
2. After the pass, the lane files ONE ticket per screen or flow, with all its items as a checklist. One PR then fixes the whole screen or flow.
3. Before it files, the lane reads the open issues and open PRs of that board for the same screen or flow. If one exists, the lane adds the new items to it as a comment. It never adds scope to a ticket whose PR is already approved: those items go to a new follow-up ticket, `Blocked-by:` that PR.
4. Exceptions. A HIGH that blocks a launch flow or leaks data is filed (or alerted) at once, and it still goes in the ledger and in its group. If two groups edit one file, the second group's ticket gets `Blocked-by:` the first.
- A build or review files a follow-up only for a core-flow defect a user would notice, one per screen or flow with every item as a checklist; smoke-level findings stay as [NOTE] lines in the review, and a follow-up ticket's own review files no follow-up (BH-7123).
- In cromford, lanes call `bin/lib/group-findings.sh` (`gf_run`) and never file per finding. The switch is the settings row `lib.group-findings.<board>.group_findings` (default 0, off).
