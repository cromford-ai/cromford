# BH-9025: the repo-activity block has a time budget and logs what it could not parse

Doc: VERIFICATION-MAP

## What changed

- `archie_repo_activity_block` (`bin/lib/archie-repo-activity.sh`) starts one
  `bin/repo-activity.sh` reader per repo, all at once. Each reader gets
  `GH_REST_TIMEOUT_S=<REPO_ACTIVITY_TIMEOUT_S>`, so every GitHub read it makes
  is bounded. The block polls every 0.2 s until every reader is done or
  `REPO_ACTIVITY_BUDGET_S` has passed. It sends TERM to a reader that is still
  running and does not wait for it.
- The block classifies each repo:
  - ok: the reader exited 0. Its events go in the block as before.
  - timed out: a read ran past the per-call timeout
    (`<repo> UNREADABLE timed out after <n>s`), or the reader was still
    running at the budget (`<repo> UNREADABLE not finished in <n>s`, plus one
    `(not finished in <n>s: <repo> ...)` line after the notes).
  - unreadable: every other failure, with the reader's own UNREADABLE line as
    before.
- `(no events in the last <n>h)` still prints only when the block has no event
  and no note. A repo that was not read is never "no events".
- `bin/repo-activity.sh` writes one stderr line when a 2xx body does not parse:
  `repo-activity: <slug> <endpoint> HTTP <code> unparseable; first 200 bytes: <text>`.
  Every byte outside printable ASCII is a space. A read that hit
  `GH_REST_TIMEOUT_S` prints `UNREADABLE <endpoint> HTTP 000 (timeout)`. A
  network error with no timeout prints `HTTP 000` as before.
- The block appends to `logs/repo-activity.log`:
  - one line per call:
    `<iso> repo-activity: N repos, M ok, K unreadable, J timed out, took S s (caller <script>)`.
    J counts both kinds of timed out. The caller is `orchestrate.sh` for a chat
    turn and `archie.sh` for a check tick.
  - at most one line per unreadable repo per call, with the first 200 bytes:
    `<iso> repo-activity: <repo> <endpoint> HTTP <code> unparseable; first 200 bytes: <text>`.
- Two knobs, lib id `orchestrate` in `catalog/lanes.d/_lib.orchestrate.json`:
  `REPO_ACTIVITY_TIMEOUT_S` (default 5, 1..60, row
  `lib.orchestrate.repo_activity_timeout_s`) and `REPO_ACTIVITY_BUDGET_S`
  (default 10, 1..120, row `lib.orchestrate.repo_activity_budget_s`). The
  ticket named the rows `orchestrate.repo_activity_*`. The lib knob mechanism
  names a row `lib.<id>.<env lowercased>`, so the rows carry the `lib.` prefix.
  `archie_repo_activity_knobs` resolves them through `lib_env_apply
  orchestrate` in a subshell. An operator row wins over the env. A value
  outside the range is the default.

## Why

On 2026-11-03 at 16:48Z the block took 34.9 s on the hub, and every repo was
`HTTP 200 (unparseable)`. The block added about 35 s to every fresh chat turn
and no repo activity.

- The wall time: the block read every repo in sequence, with no bound.
  `bin/fleet-conf.sh --projects` lists 17 projects. One live read of
  `example-org/cromford` from a build box took 2.66 s. 17 x about 2 s is
  about 35 s.
- The parse failure: not reproduced from a build box. A plain `gh` read and
  a read through the `bin/gh-ledger` shim cache (fresh, then replayed) both
  parse. The hub is not reachable from a build box, and before this change
  `bin/repo-activity.sh` dropped the body that did not parse. Candidate
  causes: (H1) a 200 HTML or redirect page from a proxy; (H2) a `gh-ledger`
  cache replay of an `-i` answer (`ghc_replay`, `bin/lib/gh-cache.sh`) in a
  shape that `gh_rest`'s body split cannot read; (H3) a different `jq` on the
  hub.

## How to read the cause on the hub

1. Send one Telegram message to the orchestrator.
2. Run `tail -n 20 /root/harness/logs/repo-activity.log`.
3. Read the summary line. `took` must be under 10 s.
4. If a repo is unreadable, read its `unparseable; first 200 bytes:` line.
   `<!DOCTYPE html>` or `<html` is H1. `HTTP/` or `X-Gh-Cache-Served` at the
   start of the bytes is H2. A valid JSON start (`[{"url":` or
   `{"total_count":`) is H3.

## Test

`tests/repo-activity-budget.bh-9025-test.sh`. `tests/repo-activity.bh-8417-test.sh`
is unchanged and still passes.
