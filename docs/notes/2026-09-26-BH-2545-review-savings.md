# Review savings: a cheap route for trivial diffs, and every skipped review is counted

Doc: MERGE-CONDUCTOR, MODEL-ROUTES, EVENTS, COST

The two paid review lanes (`bin/review-prs.sh`, `bin/review-autopilot.sh`) bought the
`build.review` model for every head, lockfile bumps included. The three places that already skip a
review because the patch did not change (BH-2310) only said so in their own logs, so nobody could
count what that saved. BH-2545 adds `bin/lib/review-saving.sh` for both.

- **Classifier.** `review_diff_class <diff-file>` prints `<class> <lines>`. The class is `docs`
  (`*.md`, `*.rst`, `*.adoc`; `*.mdx` and `*.txt` are code), `lock` (package-lock.json, yarn.lock,
  pnpm-lock.yaml, bun.lockb, Cargo.lock, poetry.lock, uv.lock, composer.lock, Gemfile.lock, go.sum,
  requirements.lock) or `tests` (`tests/`, `test/`, `e2e/`, `__tests__/`, `__mocks__/`,
  `fixtures/`, `testdata/`, `__snapshots__/`, `*.test.*`, `*.spec.*`, `*_test.*`, `*.snap`) when
  EVERY path in the diff is in that one class. Anything else is `code`. So are agent instructions and
  guard inputs whatever their extension: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `RTK.md`,
  `SKILL.md`; any path containing `allowlist`, `denylist`, `baseline`, `by-design` or
  `known-*failures`; any `*lint*`, `*guard*` or `*ratchet*` file under `tests/` or `test/`; and
  anything under `rules/`, `prompts/`, `skills/`, `.claude/`, `.github/`, `.harness/`,
  `guardrails/`, `checks/`, `catalog/`, `docs/verification-map/` or `tests/lib/`. A mix of classes,
  a rename out of code, a quoted path, an empty diff, or no `diff --git` header is also `code`.
  Lines are the `+`/`-` lines, not counting the `---`/`+++` header pair.
- **Knobs.** Three settings rows (`catalog/lanes.d/_lib.review-saving.json`):
  - `lib.review-saving.review_trivial_mode` (`REVIEW_TRIVIAL_MODE`): `off`, `shadow` (the
    default) or `route`.
  - `lib.review-saving.review_trivial_max_lines` (`REVIEW_TRIVIAL_MAX_LINES`): default 200; 0
    means no diff is trivial.
  - `lib.review-saving.review_trivial_route_classes` (`REVIEW_TRIVIAL_ROUTE_CLASSES`): the classes
    route mode may route, a space-separated subset of `docs lock tests`. Default `docs`.

  A value outside those (a bad mode, a non-number max, a class token outside the three) turns the
  whole thing `off` and is named in `logs/review-saving.log`. It is never clamped.
- **Route (review-prs only).** In `shadow` nothing changes except one `TRIVIAL_SHADOW` event per
  trivial head. In `route`, a trivial head whose class is in the route classes is reviewed with
  `model_for review.trivial <project>`, a model_routes row seeded to Haiku in
  `worker/jobs/schema.sql` (INSERT OR IGNORE plus the BH-1572 tombstone guard). A trivial class
  outside the route classes, so `lock` and `tests` by default, stays `TRIVIAL_SHADOW` and keeps the
  lane's model: a lockfile or a test-dir edit can loosen a supply chain or a gate. With no route it
  keeps the lane's model and says `TRIVIAL_NO_ROUTE`.
- **A cheap read never merges anything.** review-prs has no tier-gated merge: `merge_step` merges
  any APPROVE whatever its tier. So a routed verdict is recorded at TIER 2 at most, but that is only a
  label. What stops the merge is that a routed APPROVE is **advisory**:
  - it posts as a COMMENT review, never a GitHub approval a merge queue could read, and carries no
    head marker, so the GitHub dedup rung cannot rehydrate it as a verdict;
  - it never reaches `merge_step`, dismisses none of the lane's older blocking reviews, and writes
    neither ledger verdict (`d1 artifacts`, `review verdict ledger`);
  - the state row gets `trivial:"1"` in the same write as the verdict. `merge_retry` refuses such a
    row (a replay onto a new head carries the flag), and on the next tick the already-reviewed gate
    re-reviews that head on the lane's default model, never routed again (`TRIVIAL_ESCALATED`). That
    verdict replaces the row and is the only one that can merge it.

  A routed REQUEST_CHANGES stands as posted, since a refusal merges nothing. So the saving is on
  heads the cheap read refuses; an approved trivial head costs the cheap read plus a full one.
  Probe counts: `TRIVIAL_ROUTED` minus `TRIVIAL_ESCALATED` is the number of full reviews saved.
  No head is ever skipped and no verdict is written without a model call. The agent-call line, K3 fingerprint and cost row are unchanged. review-prs restores the
  tick's model before each head, so a routed docs PR never leaks its model to the next PR. The lane
  log gets `trivial <class> <lines> lines: <shadow|routed|no-route> model=<m>`.
- **Autopilot is measured, never routed.** `bin/review-autopilot.sh` classifies and records
  `TRIVIAL_SHADOW` for any trivial head, in any mode but `off`, and keeps its model. Its MERGE word
  is landed by the conductor with no tier to cap.
- **Events.** `review_saving_event` opens its own jobs row (`kind=review-saving`, ticket
  `review-saving/<lane>/<slug>#<num>@<sha>`), posts one `stage_events` row with stage
  `review-saving`, then closes the row. Verdicts:
  - `REUSED`: the review-prs and autopilot verdict replays, and the conductor's
    `rebind_patch_id` (lane `merge-conductor`). The detail is `from=<sha12> to=<sha12> how=<how>`.
  - `TRIVIAL_SHADOW`, `TRIVIAL_ROUTED`, `TRIVIAL_NO_ROUTE`: the detail is `class= lines= model=`.
  - `TRIVIAL_ESCALATED`: the full-model re-review of an advisory APPROVE; the detail is `model=`.

  It is fail-open, runs after the local state write it describes, and never reads or sets `JOB_ID`.
  There is no dollar figure. What a routed review cost is on agent-call's own cost row.
- **Probe.** `SELECT e.verdict, count(DISTINCT j.ticket_id) FROM stage_events e JOIN jobs j ON j.id = e.job_id WHERE e.stage='review-saving' GROUP BY e.verdict`
  on the jobs D1. It counts distinct (lane, PR, head) keys, not events: a trivial event fires
  before the agent call, so a call that fails and retries next tick records the same head again on
  a new job row, and that repeat is not counted twice. The lane is part of the key, so when both
  review-prs and the conductor's `rebind_patch_id` rebind the same head it counts as two `REUSED`.
- **Arming it.** One settings row: `lib.review-saving.review_trivial_mode=route`. Writing `shadow`
  undoes it. Widening what is routed is `lib.review-saving.review_trivial_route_classes`. Know
  before arming that `docs` is any `.md`/`.rst`/`.adoc` outside the exclusions, and that covers
  markdown that is behavior: `docs/VMAP-BACKFILL-TICKET.md` and `docs/ARCH-AUDIT-TICKET.md` here
  become filed build tickets, and a client repo may render markdown to users or ship a prompt as
  `src/**/prompt.md`. A cheap read of those cannot merge them (see above), but its REQUEST_CHANGES
  is what the author sees first.
- **Not in this change.** There is no deterministic APPROVE for trivial diffs: a merge needs a
  reviewer TIER. review-rescue, lead-review and the conductor's own re-review get no trivial
  route.
