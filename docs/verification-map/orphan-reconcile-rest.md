# Orphan reconciliation over REST (`bin/orphan-reconcile.sh`)

**What it is:** the reconciler that answers "is every open `ai-build` issue
actually being worked" now reads the board entirely over REST, through
`bin/lib/gh-rest-list.sh` and the rc 0/44/75 contract in `bin/lib/gh-rest.sh`
(see [gh-rest.md](gh-rest.md)). The file carries the `# gh-rest: no-graphql`
marker, so a `gh pr` / `gh issue` / `gh run` call cannot come back here.

It exists because of #768 (2026-09-18). `gh issue list --json`, `gh issue view`
and `gh pr list` all speak GraphQL and draw on the 5000/h bucket the whole hub
shares — the bucket that emptied that morning and made the dependency gate read
silence as fact. This lane runs on EVERY tick of every GitHub-Issues project and
spent three list reads plus a per-blocker read each time, which made it the
hottest spender on the bucket with no headroom. REST's bucket is per token and
per installation, and is not the one the decision gates are fighting over.

**What did NOT change:** the owner rule (docs/EVENTS.md §5.4), the five owner
classes, the caps, the grace window, the launch path, the log lines and the
alert. This is a transport change and the JSON the classifier reads is reshaped
by `jq` back into the field names it has always used.

**The one thing that is not a transport swap.** `gh issue list --json comments`
returned every comment BODY in one GraphQL answer; REST's issue list carries a
comment COUNT. Reading every open issue's thread each tick would be roughly 76
extra reads a tick on a board that size and would break this file's own "cheap
by construction" promise. So the classifier runs twice over the same data:

1. pass `needs` applies owner classes (a) ledger and (b) open PR, then prints
   one `<kind>\t<number>` line per read it cannot decide without — the blockers
   the `ai-build` list does not carry, and the comment threads of issues that
   are still ownerless and have at least one comment. It deliberately skips
   class (c), so its need set is a SUPERSET of what pass 2 can ask for.
2. bash fetches exactly those, capped by `ORPHAN_BLOCKER_FETCH_MAX` (20) and
   `ORPHAN_THREAD_FETCH_MAX` (200, the settings row
   `lib.orphan-reconcile.<project>.orphan_thread_fetch_max` since BH-8497).
   Threads are taken in issue-number order from past a cursor the last capped
   run wrote (the `ledgers` row kind `orphan-thread-cursor`), so a thread the cap cut is read first on the next run, and a cut
   writes one ALERTS line per project per UTC day with the count.
3. pass `decide` is the classifier as it always was, reading those answers off
   disk.

**Fail closed, in every direction.** A list read that answers 44 or 75 exits 0
having enqueued nothing and says which it was — `answered HTTP 404` for absent,
`unverifiable (HTTP <status> <reason>)` plus one `gh_rest_alert` line for
unknown. A blocker whose read was declined or capped reads OPEN. An issue whose
thread was declined or capped is `OWNED :: unverifiable:thread` and is not
launched: "nobody could see the thread" and "nobody held it" are different
sentences and only one of them may spend a build.

**A read that stopped short is not the thread, and neither is silent.** The row
cap in `gh_rest_issue_comments` trims OLDEST-first, so a thread longer than the
cap loses its NEWEST comments — the decisive end of the BH-408 walk, where a
HOLD written today lives. The list payload carries the issue's own comment
count, so pass 2 compares it against the bodies it actually got and parks the
ticket `OWNED :: unverifiable:thread-truncated` rather than reading the gap as
"nobody held it". Both parked shapes are named in the tick's log, not only under
`--explain`: `ORPHAN_THREAD_FETCH_MAX=<n> bound — #a,#b parked
unverifiable:thread` when the cap is what bound, and one
`parked unread — <KEY>(<why>)` line listing every verdict reached on an answer
nobody got. On a board inside the cap with every thread read, neither line
appears.

**How an operator reaches it:** `bin/run-triage.sh` calls it on every tick,
ahead of the gate's SKIP (that ordering is what the lane is for), and it can be
run by hand as `bin/orphan-reconcile.sh <project> --explain`.

**Primary lanes / scripts:**
- `bin/orphan-reconcile.sh` — the three list reads, the `rest_decline` logger,
  the pass-1 fetch loop and the two-pass `classify` runner.
- `bin/lib/gh-rest-list.sh` — `gh_rest_issue_list`, `gh_rest_pr_list_all` and
  `gh_rest_issue_comments` over one paging engine. REST caps `per_page` at 100
  and the CLI's cap was `--limit 200`, so a one-page helper would silently halve
  the board. A page that answers 44 or 75 fails the WHOLE read: half a board
  returned as the board is #768 with a longer fuse.
- `bin/lib/gh-rest.sh` — the contract. HARD-required here: a reconciler whose
  readers are undefined functions answers rc 127 on every one of them, and 127
  is neither 44 nor 75.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/orphan-reconcile-test.sh` — 95 assertions
  over the real script against a REST `gh` shim that answers with a status line,
  a blank line and a body: the whole owner rule, the launch, the caps, the
  switches, a 429 and a 404 on the board read being logged as different things
  and neither spending a launch, an unreadable thread parking its own ticket
  while the rest of the board keeps moving, a pull request returned by
  `GET /issues` never being classified as a ticket, the thread cap naming itself
  and the tickets it parked, and a 201-comment thread whose newest comment is a
  HOLD being parked as truncated rather than launched over.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-rest-list-lib-test.sh` — 46 assertions
  on the list library alone: one short page is one request, a full page is
  followed and concatenated in order, a declined page poisons the whole read
  rather than trimming it, `[]` under a 200 stays a fact, a 2xx non-list is not
  an empty board, pull requests are filtered out of `/issues` and kept on
  `/pulls`, the row cap trims and stops the paging, bad arguments spend no
  request, no temp file survives either path, plus four mutants.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-no-graphql-decision-guard-test.sh` — the
  marker guard, which now scans `bin/orphan-reconcile.sh` too.

**Preconditions / seed needs:** `jq` and `python3` on PATH. The suites need no
token and no network.

**Verify it works on a live box** (read-only):

```bash
# 1. the marker is on the file
grep -qx '# gh-rest: no-graphql' /root/harness/bin/orphan-reconcile.sh && echo marked

# 2. no GraphQL reader survives
grep -cE '(^|[^a-zA-Z_])gh (pr|issue|run) ' /root/harness/bin/orphan-reconcile.sh   # 0

# 3. the lane still reconciles every tick, and says what it decided
grep -o 'reconcile: open=.*' /root/harness/logs/<project>.log | tail -5

# 4. what a declined read looks like when it happens
grep -nE 'reconcile: .*(unverifiable|parked unread|answered HTTP 404|bound —)' \
  /root/harness/logs/<project>.log | tail -5
```

A line in (4) is the lane declining to decide. It must be followed, on a later
tick, by a normal `reconcile: open=… owned=… orphans=…` line — never by a launch
taken on the strength of an answer nobody got.
