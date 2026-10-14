# The pool's PR_CREATED gate and seven close-out writers read GitHub over REST

Doc: RUN-BUILD-GRAPH, MERGE-CONDUCTOR, EVENTS

**What changed.** Eight lanes now reach GitHub only through
`bin/lib/gh-rest.sh`, the contract #768 bought, and each of them carries the
`# gh-rest: no-graphql` marker that `tests/gh-no-graphql-decision-guard-test.sh`
polices.

- `bin/fly-pool.sh` — the reap-time `PR_CREATED` gate. Its file-local
  `pr_state_rest` is gone; the block that held it
  (`# >>> pr verify rest (BH-709)`) now holds only the guarded source of the
  library. `gh_rest_read` stays, one block lower and with its reason written
  over it: BH-1075 (#1097) landed three new callers of it — `branch_head_rest`,
  the open-PR probe and the spawn-gate repo probe — while this build was in
  review, and they pass an explicit `$POOL_SLUG_TOK` the library has no argument
  for. Porting them is a change to BH-1075's gates; #770 tracks it. Deleting the
  definition out from under them is what round 2 of this review caught: every
  `*/2` tick would hit `gh_rest_read: command not found`, all four spawn gates
  would switch off and `head_sha` would record `unknown`. The decide half is wrapped in new `# >>> PR_CREATED verify` /
  `# <<< PR_CREATED verify` markers and makes ONE read: `gh_rest_pr_state`, rc
  0 / 44 / 75. `open` or `merged` leaves the RESULT alone; `closed` and a 404
  over a repo the same identity can see are the only two relabels; everything
  else writes one `gh_rest_alert` line and leaves the RESULT byte-identical.
- `bin/run-build.sh` — the tier-1 close-out FALLBACK pair
  (`CLOSE_ISSUE_AFTER_MERGE`) and the blocked notice in `escalate_block`.
- `bin/batch-resolve.sh` — the batch close-out comment, the head-moved notice,
  and the member PR close in `settle_member`.
- `bin/decompose-parent-close.sh` — the parent close, split into a comment and
  a close because `gh issue close --comment` has no single REST equivalent.
- `bin/board-closeout.sh` — the issues-lane what-shipped comment.
- `bin/unblocked-children.sh` — the dep pass's paper trail comment.
- `bin/lib/hotfix-lib.sh` — `hotfix_issue_is`, now `GET
  /repos/{slug}/issues/{n}/labels`.
- `bin/hotfix-seen.sh` — the hotfix listing, now `GET /repos/{slug}/issues` with
  `labels=ai-build,<hotfix>&state=open`.

**Why.** On 2026-09-18 a rate-limited `gh pr view` answered an empty string, a
decision path read that silence as "no such PR", five real PRs were rewritten
`RESULT_UNVERIFIED` and TK-2302 was launched three times. The library's three
exit codes make "GitHub said no such thing" unreadable off the same silence as
"GitHub said come back later": rc 0 act on the body, rc 44 an affirmative 404,
rc 75 skip this tick. Every lane above was still deciding off the CLI.

**The rule all seven writers now obey.** Comment, then close, then the marker —
and a marker (a done-file, a ledger row, a line of stdout, a "closed" log line)
is written only after the library returned rc 0. `gh_rest_close` returns 0 only
once a fresh read says `closed`, so "stamped closed without being closed" is
impossible by construction. A refusal leaves the work exactly where it was and
the next tick is the retry: `bin/reconcile-prs.sh` and `bin/blocked-resolver.sh`
on `*/10`, the pool reap on `*/2`, the triage tick for the hotfix listing.

**What it touches.**

- **One read per tick, no in-tick retry.** The pool's two-try loop and its
  `POOL_PR_VERIFY_SLEEP` pause are RETIRED — the knob is removed from the code,
  from `catalog/lanes.json` (`tests/lanes-registry-test.sh` rule 6 refuses a
  registered knob nothing reads) and from
  `docs/verification-map/pr-verify-gate.md`. An operator line for it in
  `env/global.env` is inert, which is what an unread env var already was. A
  contended answer is always "next reap", never a wait (D33). So a RUN of
  `gh-rest: … PR_CREATED … HTTP 403 … unverifiable, left as-is this tick` lines
  across consecutive `*/2` reaps is RATE-LIMIT WEATHER, not a broken token: one
  line per tick per unread PR is exactly what one-read-per-tick looks like from
  the alert log, and the medic should read the burst's length, not its width.
- **The credential is armed for the whole verify block.** The library reads the
  ambient `gh` auth, so `gh_repo_use_token` runs before the read and
  `gh_repo_token_reset` after it. The gate used to capture a token and reset it
  immediately, which cannot work with a library that reads the environment.
- **Alert wording.** The pool's UNVERIFIABLE register is now the library's own
  one-liner: `gh-rest: <KEY> PR_CREATED <url> HTTP <code> (<reason>)
  token=<default|explicit>, unverifiable, left as-is this tick`. It names a
  token LABEL, never a value. The identity's WORD (app/default/admin) still
  rides the matching `logs/fly-pool.log` line.
- **The App-token ratchet.** Under BH-1177 the registry is one file per script,
  so this slice deletes `tests/gh-app-ratchet-baseline/hotfix-seen.sh.txt` and
  `tests/gh-app-ratchet-baseline/lib/hotfix-lib.sh.txt`, and drops the
  `# gh-identity: raw-pat (BH-425)` header line from `bin/hotfix-seen.sh` and
  `bin/lib/hotfix-lib.sh`: neither makes a raw `gh` call any more, so the marker
  would be a stale exception (rule 4) and the entries have nothing left to
  queue. NOT `app-token` — the scanner, not the sentence, decides "armed", and
  neither file names a token helper or calls `gh_auth_for`; a raw-free script
  carries no marker at all. `bin/batch-resolve.sh` keeps its `raw-pat` marker
  and its entry: it still has raw reads. The ratchet only ever goes down.
- **The GraphQL reads this slice does NOT own** — `gh pr list`, `gh issue list`,
  `gh pr view --json headRefOid`, the PR create/comment/edit/merge writes —
  carry `# gh-guard-allow: <reason>` in one of two honest forms: "a write, not a
  decision read", or "read not converted by BH-770.1; #770 tracks it". Nothing
  claims to have been converted that was not.
- **`bin/lib/issue-state-lib.sh` is still on GraphQL.** On an up-to-date box
  `CLOSE_ISSUE_AFTER_MERGE` prefers `issue_close_shipped` from that file, so the
  pair converted here is the FALLBACK path. That file is not in this ticket's
  declared set and a sibling PR has its test open; it stays a #770 decision read.

**How to drive it.** `HARNESS_TEST_SANDBOX=1 bash
tests/fly-pool-pr-verify.bh-781-test.sh` and `… tests/closeout-retry.bh-781-test.sh`
(both new), plus the re-pointed `tests/fly-pool-pr-verify-rest-test.sh` and the
two guards, `tests/gh-no-graphql-decision-guard-test.sh` and
`tests/gh-app-ratchet-test.sh`.
