## 3. What happens to an ORPHAN

At most `PR_OWNER_MAX_ACTIONS` (default 5) writes per repo per run; the rest are
logged as `held=#N:cap` and picked up next run.

| arm | when | what it does |
|---|---|---|
| **close-duplicate** | another PR carrying the same ticket key MERGED AFTER this PR was opened (BH-6717). A PR opened after every merge of its key is a later part of the ticket: it falls through to the next arm, and the summary line lists it as `spared-later=#n`. An unreadable `createdAt` closes nothing | comment naming the newest such merge, then close. The work is not lost — the comment says to reopen if something in the diff did not make it across. |
| **stale-conflict** | the head has been `CONFLICTING` for more than `PR_OWNER_STALE_DAYS` (default 14) | one comment, then the `stale-conflict` label. **The label is the memory**: a PR that already carries it is never commented on again. It is not closed — a conflicting branch may still be somebody's work in progress. |
| **handback** | the ticket is still live and nothing is building it | the key goes back to the box that owns the project, the same way `bin/blocked-resolver.sh`'s `br_enqueue_fresh` does it: flip the `ledgers(kind=commented)` row `blocked <project> <KEY>` to `cleared` (BH-2317; a cleared row outvotes any stamp left on the box), and that box's next triage tick re-claims the ticket. When the jobs DB refuses that write nothing is handed back: the PR is held `handback-failed` and the next sweep retries (BH-2673). A pool-routed project is held `pool-routed` and a repo with no fleet project `no-project` (BH-5124); neither is a failure, and neither spends an action. |

**A HELD TICKET IS NEVER REBUILT, RE-ENQUEUED OR REOPENED.** Since BH-408
(2026-09-18) `bin/blocked-resolver.sh`'s rebuild rung and
`bin/orphan-reconcile.sh`'s owner class (d) both run `bin/lib/hold.sh` FIRST: an
issue that is closed, that has lost its `ai-build` label, or whose newest
decisive human comment is a `HOLD` gets one
`[resolver] HOLD respected <ticket>` line, keeps its PR exactly as it was, and
parks at the `HELD` terminal without spending a rung. A later comment that lifts
the hold releases it on the next tick with its counters intact — nothing here
waits on a person to clear state by hand. Console alert 6726 is why: project-5
#414 was de-labelled and put on HOLD by the operator at 07:03Z and rebuilt three times
that morning anyway. This sweep's own **handback** arm is NOT gated yet (it
clears the `blocked-commented-*` stamps, a third re-offer path) — one call of
`hold_check` wires it, and that is the named follow-up. See
docs/verification-map/resolver-hold.md.

**A pool-routed project is not handed back from here.** Its re-offer is a queue
row with attempt counters behind it, which is `bin/blocked-resolver.sh`'s rung;
the sweep says so in its log rather than writing a second copy of that routing,
and the summary holds the PR as `#N:pool-routed`, never `handback-failed`. That
refusal writes nothing, so it does not count against `PR_OWNER_MAX_ACTIONS`.

### The ticket key of a PR, and why it is narrow
Letters 2-8, a dash, digits 1-6, at the **front** of the last segment of the
head branch (`ticket/TK-902` → `TK-902`) or of the title (`TK-902: …`,
`[TK-1617] …`), upper-cased.

This is byte-for-byte the shape `bin/blocked-resolver.sh`'s `br_key_shape` uses
(#358, merged 2026-09-15). Two lanes that both close PRs have to agree on which
ticket a PR *is*, or one of them closes the wrong one. That function is not
sourceable from a script today, so the shape is copied deliberately and said out
loud in both places — see the fold-in about lifting it into `bin/lib/`.

Anchoring matters as much as the character classes. A loose `[A-Z]+-[0-9]+`
anywhere in the text would read `UTF-8` out of `fix/utf-8-encoding` and then
close a PR because some other "UTF-8" merged; a key mid-title is usually a
reference to a different ticket ("supersedes TK-700"). **No key is a fine
answer**: it costs that PR the close-duplicate and hand-back arms and nothing
else — it is still recorded, and still labelled if its head is stale.

