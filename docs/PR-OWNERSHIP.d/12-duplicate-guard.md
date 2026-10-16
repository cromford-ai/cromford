## 12. The duplicate-close guard (BH-6929)

Every close of a PR as a DUPLICATE runs `po_dup_guard`
(`bin/lib/pr-owner/dup-guard.sh`) first. The three duplicate close paths are
`po_superseded` rule 1 (the key merged in another PR), `po_superseded` rule 3
(an older duplicate of the keeper) and the sweep's own `close-duplicate` arm
(§3). Rule 2 (the ticket is done or rejected) is not a duplicate close.

The guard keeps the PR when any of these hold. The first match wins:

| tag | the PR is kept when |
|---|---|
| `slice` | its title says `slice` or `part N` |
| `blocked-by` | another open PR's body has a `Blocked-by:` line that names `#<n>` or `/pull/<n>` |
| `armed` | the merge conductor has it `READY`, `QUEUED` or `MERGING` |
| `approved` | a latest review (`latestReviews` in the open-PR list) is `APPROVED` |
| `reopened` | its issue events hold a `reopened` event |
| `not-a-duplicate` | a PR comment says "not a duplicate" |
| `stacked` | its head is an ancestor of the head of another open PR with the same key, or that head is an ancestor of its head |

`stacked` uses `git merge-base --is-ancestor` in `$PR_OWNER_REPO_ROOT/<project>`
(default `/root/repos`) when that checkout has both commits. Otherwise it uses
REST `compare/<this>...<other>`: `ahead`, `behind` and `identical` keep the PR,
`diverged` does not.

A kept PR gets one log line, `<slug>#<n>: duplicate close refused — <tag>:
<detail>`, and `held=#<n>:<tag>` in the repo summary. It spends none of
`PR_OWNER_MAX_ACTIONS`.

**Fail closed.** A read that fails or does not parse keeps the PR as
`guard-unread`. The same applies to an open-PR list with no `latestReviews`,
a full page of events or comments, and a key with more than 10 other open PRs.
The next sweep tries again.

`reopened` and `not-a-duplicate` are GitHub's own records. A reopen, or a
comment that says "not a duplicate", stops the duplicate close for that PR on
every later sweep.

**The close itself is unchanged.** The comment still says to reopen the PR if
it has something the other PR does not. When a run closes a PR as a
duplicate, the repo's one alert of the run (§4) goes out as critical
(`bin/lane-alert.sh --severity critical`, Telegram now, not the digest). It
names every PR closed as a duplicate. A dry run never makes it critical.
