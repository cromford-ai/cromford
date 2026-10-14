# The dep gate's reads are ledgered, and an issue is read once per conductor tick

Doc: MERGE-CONDUCTOR

## What was wrong

`pdg_hold` (`bin/lib/pr-dep-gate.sh`) made two raw `gh api` reads: the PR body
(when a lane hands it none) and one `repos/<slug>/issues/<n>` per declared
dependency. Neither went through `gh_rest`, so the quota gate never saw them
and the GitHub-call ledger never recorded them. Its memo, `_PDG_MEMO`, lives in
the calling shell, and every lane calls `pdg_hold` inside `$(...)`, so the memo
died with each PR. N held PRs naming the same dependency paid N reads of it on
every 5-minute conductor tick.

## What it does now

- Both reads go through `gh_rest_var … GET` whenever `bin/lib/gh-rest.sh` is
  loaded (every lane that sources `merge-conductor-lib.sh`). Each one writes a
  ledger row to `state/gh-rest-ledger/<hour>.tsv`, including 404s and failures.
  `GH_REST_OPTIONAL` is shadowed empty for these reads, so the reserve gate can
  never refuse the merge gate.
- Under a conductor tick (`MC_TICK_ID` set), the issue JSON is memoised in
  `tick_memo_file pdg-issue "<slug>#<n>"` under `$MC_TICK_DIR`. A new tick is a
  new file, so a dependency that closes is seen on the next tick. The conductor
  runs PR workers concurrently, so read-then-store runs under a short per-key
  `flock` (20 s bound, then an unlocked read, never a failure). A failed read
  and a torn memo file are never served. `mc_tick_gc` collects the files and
  their `.lock`s.
- `MC_READ_MEMO=0`, the conductor's existing read-memo kill switch, turns the
  memo off. Outside the conductor (merge-sweep, merge-queue, the run-build tier-1
  gate) there is no tick id and no file memo; those reads are ledgered only.
- Without `gh-rest.sh` in the tree, both reads fall back to the old raw
  `gh api … -q` call, unchanged.

The rc contract (0 HOLD, 1 pass, 2 could not read) and the log lines are
unchanged.

## The ticket half (BH-1678, #1725)

#1725 merged while this was being built, so the branch was rebased onto it.

- `pdg_ticket_deps` reads the linked issue's body through the same
  `_pdg_issue_json`: ledgered, and memoised per tick under the same
  `pdg-issue` key, so the body and a `Blocked-by` lookup of that number share
  one read.
- `_pdg_lists`' two paginated reads (the open `ai-build` issues and the open
  PRs) are memoised per tick under `pdg-ilist` / `pdg-plist` `"<slug>"`, with
  the same lock and the same never-store-a-failure rule. An empty list is a
  successful read and is stored.
- Those two list reads go through `bin/lib/gh-rest-list.sh`
  (`gh_rest_issue_list <slug> open ai-build 1000`, `gh_rest_pr_list_all <slug>
  open 1000`, BH-1163), which pages through `gh_rest`: each page passes the
  quota gate and writes a ledger row, and a failed page fails the whole read.
  `GH_REST_OPTIONAL` is shadowed empty there too. The raw `gh api --paginate`
  line is kept only as the fallback for a tree without the library.

## Where

- `bin/lib/pr-dep-gate.sh`: `_pdg_rest_get`, `_pdg_memo_lock`/`_pdg_memo_unlock`/
  `_pdg_memo_put`, `_pdg_issue_json`, `_pdg_list_read`; the reads in
  `_pdg_resolve`, `pdg_ticket_deps`, `_pdg_lists` and the PR-body read in
  `pdg_hold`.
- `tests/pr-dep-gate-memo.bh-1735-test.sh` (new).
- `tests/pr-dep-gate-rest.bh-994-test.sh`: its stub now answers the REST issue
  shape, and its argv assertions pin `api -i -X GET`.
- `tests/pr-dep-gate-order.bh-1678-test.sh`: its stub answers
  `api -i -X GET <path>` with a whole HTTP response from the same fixtures.

## The shared issue read at build enqueue (lead remainder, 2026-09-24)

After #1664 and #1448 every build enqueue made two GETs of `repos/<slug>/issues/<n>`:
once in the closed-issue skip (`issue_state`, bin/lib/issue-state-lib.sh)
and again, a few hundred lines later, for the created-at stamp. #1772 shipped
the pdg half and left this one owed.

- `issue_memo_file <dir> <slug> <n>` names the memo:
  `$BUILD/issue-memo.<slug, lowercased, / as +>.<n>.json`. The key is
  (repo, issue), so a project whose `GH_ISSUES_REPO` differs from its build
  slug is never served the other repo's issue.
- `issue_state` / `issue_is_closed` take the path as an optional 4th argument.
  With it, the same one GET keeps the whole JSON (tmp + mv), only when the
  answer is OPEN or CLOSED. The file is removed before the read, so a failed
  read leaves no memo and a resumed build is never served an earlier run's.
  Without it, or when the dir cannot be written, the call is the old one.
- The created-at block reads `created_at` from the memo when it is there (it
  never changes) and removes the file. Only when there is no memo (skip
  switched off, skip read failed, another repo) does it arm the live token
  and GET for itself, exactly as before.
- Both copies (bin/run-build.sh and the define-only bin/lib/rb/gates.sh) carry
  the same text; `tests/run-build-issue-rest.bh-1641-test.sh` §3 pins that.

`tests/run-build-issue-stamp-test.sh` now pins ONE GET per enqueue (it pinned
two), plus §1b (the skip's read failed, so the metric reads for itself, armed)
and §1c (a split issues repo is two reads, never a cross-served stamp).
`tests/issue-state-memo.bh-1735-test.sh` pins the library half: answers are
unchanged, a failed read clears a stale memo, the key separates repos and
numbers, the kill switch reads and writes nothing, and the read is ledgered.

The TICKET_META read at plan time (the plan stage of bin/run-build.sh) is a third GET of the
same issue. It is deliberately NOT served from this memo: it reads the body and
labels, which can change between enqueue and plan, while created_at cannot.
