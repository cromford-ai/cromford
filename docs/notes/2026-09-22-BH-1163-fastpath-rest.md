# 2026-09-22 — BH-1163 part 2: the fast-path launcher reads GitHub over REST

Doc: EVENTS

## What changed

All four GitHub reads in `bin/launch-fastpath.sh` now go through
`bin/lib/gh-rest.sh` / `bin/lib/gh-rest-list.sh`, and the file carries the
`# gh-rest: no-graphql` marker. Part 1 (#1167) did the same to
`bin/orphan-reconcile.sh`; these were the last two GraphQL decision readers in
the wake path.

| the read | was | is |
|---|---|---|
| the open PR list, once per run | `gh pr list -R … --state open --limit 200 --json number,title,headRefName,body,isDraft` | `gh_rest_pr_list_all <slug> open 200`, reshaped by jq into the same field names (`head.ref` → `headRefName`, `draft` → `isDraft`) |
| the `ai-build` state list, lazily, once per run | `gh issue list --label ai-build --state all --limit 200 --json number,state` | `gh_rest_issue_list <slug> all ai-build 200` — `.pull_request` rows are dropped inside the helper, which `gh issue list` did for free |
| the issue, per key | `gh issue view <n> --json number,state,title,body,labels,comments,createdAt` | `GET repos/<slug>/issues/<n>` **plus** `gh_rest_issue_comments <slug> <n> 200`, merged into `.comments` by jq |
| a blocker the state list does not carry, ≤2 per key | `subprocess.run(["gh","issue","view", …])` inside the embedded classifier | `gh_rest GET repos/<slug>/issues/<b>` in BASH, pre-fetched between two classifier passes |

`createdAt` was fetched and read by nothing; it is not fetched now.

## Why

The three CLI verbs speak GraphQL and share one rate-limit bucket. On
2026-09-18 (#768) a rate-limited `gh pr view` answered an EMPTY STRING, a
decision path read that as "no such PR", five real PRs were rewritten
`RESULT_UNVERIFIED` and TK-2302 was launched three times. The library's three
exit codes exist so that silence can never again be read as a state: rc 0 act on
the body, rc 44 the thing is absent, rc 75 GitHub did not answer.

## Decisions worth knowing

- **The blocker read moved from python to bash, through a two-pass classifier.**
  The blocker SET is only knowable after `line_re`/`refs()` have parsed the
  body, and those regexes are pinned byte-identical to `bin/orphan-reconcile.sh`'s
  (T1.32 diffs the two ranges). So the classifier gained `FP_MODE`: `needs`
  prints `NEEDS <b1> <b2>` and stops, bash reads those numbers over REST into
  `$TD/extra/blocker-<b>.json`, and `decide` is the classifier exactly as it was,
  reading the answers off disk. A body with no `Blocked-by` line — the common
  wake — still costs ONE python process, and everything added sits outside the
  pinned range. A python `gh api` would have bypassed the rc contract and the
  ETag cache both.
- **A 404 and an unverifiable read are different sentences** (D10), because a
  log full of `absent (HTTP 404)` and a log full of
  `unverifiable (HTTP 429 rate-limit)` are two different mornings. Both decline
  the key; only the 75 writes an `ALERTS.log` line.
- **The thread is a second read, and only when the issue says there is one.**
  REST's issue payload carries `comments` as an integer COUNT where `gh issue
  view --json comments` carried the bodies. A comment-less key therefore still
  costs exactly one read. A thread that comes back SHORTER than that count
  declines `thread truncated (<got> of <count>)`: the row cap trims OLDEST-first,
  so the bodies missing are the newest, which is where a HOLD written today
  lives and where the newest-comment-wins walk starts (BH-408).
- **The libs are a hard requirement**, not a best-effort source like the others
  around them: an undefined reader answers rc 127, which is neither 44 nor 75,
  and a box mid-sync reading that as an empty board is exactly how a duplicate
  build happens. Missing → every key declines `gh-rest lib missing`.
- **`timeout 30` is gone from these reads.** `gh_rest` runs `gh api` bare, as
  the reconciler has since #1167; wrapping a shell function in `timeout` needs a
  subshell, and a subshell is where `GH_REST_STATUS` goes to die (BH-781). The
  file header's "every gh call under `timeout 30`" sentence was rewritten in the
  same commit rather than left standing (D5).
- **No new env var, no new state, no schema.** The run's scratch holds the
  reads; the only durable marker is still
  `state/orphan-reconcile/<p>/<KEY>.enqueued`, written before the spawn.

## Which contract lines this makes stale

`docs/EVENTS.md` §5.7 is a guarded monolith (`guardrails/doc-monolith-edit`), so
it is not edited here — three of its lines now describe a transport that is gone:

- **:661** — "It never writes to GitHub: only `gh issue view`, `gh issue list`,
  `gh pr list` and the libs' `gh api` reads." Still never writes; the reads are
  all `gh api` now.
- **:679** — condition 7's `gh pr list --state open --json …,isDraft`. The
  reason `pr list unreadable` survives only for a 2xx body jq cannot reshape; a
  failed READ now says `pr list absent (HTTP 404)` or
  `pr list unverifiable (HTTP <status>)`.
- **:680** — condition 8's `gh issue view <n>`, now `GET /issues/<n>` plus
  `GET /issues/<n>/comments`, with `issue #<n> absent (HTTP 404)` /
  `issue #<n> unverifiable (HTTP …)` / `thread #<n> …` / `thread truncated (a of
  b)` beside the kept `issue unreadable`.

The per-key bound in the same section moves from "at most 4 gh calls per key" to
"at most 5 REST reads per key" (the issue, its thread, the lazy state list and
≤2 blockers), which is what the file header and
[launch-fastpath.md](../verification-map/launch-fastpath.md) now say.

## How to check it

`HARNESS_TEST_SANDBOX=1 bash tests/launch-fastpath-test.sh` — 160 assertions
driving the real script against a REST shim that answers status lines, including
the T1.33 section this ticket added (404 vs 429 on the issue, the PR list and
the thread; a truncated thread; a blocker read capped at two per key; the libs
moved aside) and a tail assertion that no `gh (pr|issue|run) (list|view)` call
survives anywhere in a whole run. The marker itself is
`HARNESS_TEST_SANDBOX=1 bash tests/gh-no-graphql-decision-guard-test.sh`.
