# BH-1131 — the two defects that deadlocked PR #728, and the silence around them

PR #728 sat unmerged for 7h40m on 2026-09-20 with CI green (7/7), `mergeState=CLEAN`
and a head-bound `VERDICT: APPROVE` sitting on the PR. Every conductor tick from
04:35Z to 12:14Z refused it. It was merged by hand. Two defects in
`bin/lib/block-gate.sh` produced that, and a third gap kept either of them from
being noticed.

## 1. A same-author APPROVE never cleared its own earlier BLOCK

At 04:33:22Z the review autopilot (`cromford[bot]`) posted a BLOCK on head
`94e6bf91`. At 07:51:11Z the SAME author, on the SAME head, posted a full
re-review that downgraded the finding to `PLAUSIBLE` and ended `VERDICT: APPROVE`.
`BG_CLEAR_RE` only recognises `UNBLOCK` / `UNBLOCKED` / `CLEARED`, and the
autopilot never writes any of them — so once it blocked a head, that head could
only be freed by pushing a commit, which buys another review. A merge deadlock
the pipeline enters on its own.

`BG_APPROVE_RE` + `bg_marker_approve` now recognise a TERMINAL VERDICT LINE
(`VERDICT: APPROVE` / `MERGE-WITH-NOTES` / `MERGE`), and `bg_scan_read` treats one
as a clear of that author's own pending block, on exactly the ordering rule
UNBLOCK already obeys.

### …under three conditions, not one (r1 review of PR #1153)

The first cut of this fix scoped the clear by LOGIN alone, and that was wrong in
a way the live fleet would have found within a day. `bin/review-prs.sh` ends its
review body with `VERDICT: APPROVE` and posts it with `gh pr review --approve` on
whatever token the lane armed; `gh_default_auth_for_project … || true` falls back
to the fleet PAT, whose login is **`operator`** — the same login the operator's own
comments carry. Every machine APPROVE on the OS repos today is authored by it
(project-3 #355 2026-09-20, project-1 #691, project-2 #525/#526). So: a
person comments `BLOCK — hold this` on a head, the review lane reviews that same
head on its next tick and approves, the approval lands as `operator`, and a
login-scoped clear would drop the person's block and merge the PR they had just
blocked. That is the exact invariant the deleted comment ("a bot's approve must
never clear a person's block") protected.

`bg_verdict_clears` is now the whole predicate, in one seam the six lanes cannot
forget to call, and it wants FOUR things:

1. a terminal verdict line — the machine vocabulary, not prose;
2. no BLOCK marker anywhere in the same body — the fail-closed reading of an
   ambiguous comment;
3. a MACHINE author (`bg_bot_login`: `<name>[bot]` or `app/<name>`). GitHub
   refuses `[`, `]` and `/` in a user name, so that login class cannot be worn by
   a person — and because the drop is per login, a human's BLOCK has no machine
   twin whose verdict could reach it;
4. THIS HEAD, named in the body (`bg_headbound`). Every lane that posts a
   terminal verdict writes the head into its own footer
   (`<!-- harness-review-autopilot <head12> -->`, `… re-review (Fable) of <sha>:
   APPROVE`, `Automated harness review (Fable) of <sha>`); the gate matches the
   SHA, not those sentences, so a footer's wording changing cannot quietly bring
   the deadlock back. An empty or non-sha head fails closed.

What did NOT change, and is pinned test by test:

- `bg_marker_clear` is byte-for-byte what it was. `bg_marker_clear "VERDICT: APPROVE"`
  is still false, so nothing that consults the clear vocabulary alone moved.
- A BARE approval (`LGTM`, `APPROVED`, `approve`, and any lowercase spelling of
  the verdict word) still clears nothing.
- A verdict from a different login clears nothing.
- A later `VERDICT: BLOCK` blocks again — the newest verdict wins.
- A comment carrying a BLOCK marker ANYWHERE blocks, whatever its last line
  says. An ambiguous comment is read the fail-closed way.

What is still open, named rather than papered over: the harness's lanes share one
App login, so a head-bound verdict from any of them clears a machine BLOCK from
any other. That IS the #728 path — the autopilot blocked, the conductor's own
head-bound re-review (which is handed the earlier review to re-adjudicate)
cleared it — so it is the designed escalation, and narrowing it further needs a
per-lane credential, not a per-login rule.

## 2. `bg_head_time` read GraphQL, so an exhausted budget blinded the gate

`gh pr view --json commits` is GraphQL. The App token's GraphQL budget is capped
and invisible in `rate_limit`; when it ran out the read failed, `bg_scan`
answered rc 2 `head-time`, and the conductor logged "block gate could not read
head-time — nothing written, the next tick tries again" **81 times in one day**.
rc 2 was the right answer to a failed read; reaching for GraphQL at all was the
bug.

It is now `repos/<slug>/pulls/<num>/commits` over REST (verified on PR #728:
GraphQL and REST both answer `2026-09-20T04:11:16Z`), with two changes the
straight translation does not have:

- **The max is taken in the shell, not in jq.** `gh api --paginate -q` runs the
  jq program once per PAGE, so `[.[]…] | max` prints one maximum per page and
  the "newest" becomes whichever page came last. Printing every date and sorting
  is the same answer on one page and the right one on five.
- **An answer that is not a date is a failed read.** A rate-limited `gh` has
  answered an empty string before (#768) and a decision path read that silence
  as fact.

## 3. 81 identical refusals raised nothing

`bg_streak_note` counts consecutive non-zero gate answers for one
`(PR, head, reason)` in `state/block-gate/streak/<slug>-<num>` — one line,
rewritten in place — and raises ONE `bin/lane-alert.sh` line when the count
reaches `BLOCK_GATE_STREAK_K` (default 6). It does not repeat until the head or
the reason changes, and a clean scan deletes the counter.

Two things to know about that number and that line. The file is per (box, PR)
and not per lane, so on the hub the conductor (`*/5`) and the merge sweep
(`6,16,…`) share it: when both refuse the same PR, six ticks is about **20
minutes**, not 30, and the in-place rewrite is not atomic between those two cron
lanes — worst case one alert early or one extra, which is the right way round for
a counter whose job is to break a silence. And it is `--severity warn`, which
`bin/lane-alert.sh` routes to the BATCHED DIGEST, not to a Telegram page: a PR
going nowhere for twenty minutes with CI green is something to read in the next
digest. If that ever has to page, the severity word is the whole change.

It lives inside `bg_scan` (now a thin wrapper over `bg_scan_read`) rather than in
the six lanes: a lane that has to remember to call the counter is a lane that
forgets, and the gate is the one place every refusal already passes through.
`bg_scan`'s stdout IS the gate's answer — every lane reads it as
`out=$(bg_scan …)` — so the alert is redirected to `/dev/null`, and a test with a
deliberately noisy alerter pins that.

## Files

- `bin/lib/block-gate.sh`
- `tests/block-gate.bh-1131-test.sh`, `tests/fixtures/bh-1131-pr728-thread.tsv`
  (PR #728's real five comments, 04:11Z–07:55Z, verbatim)
- `tests/block-gate-lib-test.sh`, `tests/conductor-block-gate-test.sh`,
  `tests/block-gate-lanes-test.sh` — the gh stubs and the "happy path buys no
  commit read" assertions re-pointed at the REST endpoint
- `docs/MERGE-CONDUCTOR.md` section 17, `docs/verification-map/block-gate.md`,
  `docs/verification-map/entries/BH-1131.md`
- `.harness/specs/BH-1131/plan.md` — the plan this built from
