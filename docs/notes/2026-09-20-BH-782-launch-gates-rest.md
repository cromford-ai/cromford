# 2026-09-20 — BH-782: launch gates read REST; an UNKNOWN answer skips the tick

Doc: gh-pr-list-rest, gh-rest, launch-gates-rest

## What changed

Five reads that gate a build launch now go through `bin/lib/gh-rest.sh`, so an
answer we could not read arrives as an HTTP status instead of as a fact about
GitHub's state.

The rule, one sentence: **a non-200, or a 2xx with an unusable body, is UNKNOWN
— the launch is skipped for this tick with a log line naming the status; a 200
with `[]` is a real empty and the launch proceeds.**

| file | before | after |
|---|---|---|
| `bin/lib/gh-pr-list.sh` | a failed REST page fell back to `gh pr list`; `acc="$acc${out:-[]}"` counted a silent author as an empty one | the REST failure is classified and RETURNED (44/75), never retried over GraphQL; an author must exit 0 **and** print something; `harness_pr_list` returns the classified rc instead of flattening it to 1 |
| `bin/preplan-candidates.sh` | `PRS=$(gh pr list …); [ -n "$PRS" ] \|\| PRS='[]'` | `gate_unknown`: queued rows still print, no candidate row does, one `launch gate UNKNOWN (HTTP <s>)` line in `logs/<project>.log`, exit 0. Both halves of each read go there — the rc AND a 2xx body the mapping jq cannot read |
| `bin/triage-gate.sh` | `gh issue list` / `gh pr list` / `gh pr view` | `GET /issues`, `gh_rest_pr_list`, `gh_rest_pr_state`; the documented fail-OPEN-to-RUN is unchanged, and an unreadable PR list now fails the whole fetch (`RUN gate-fetch-failed`) rather than substituting `prs:[]` |
| `bin/overlap-guard.sh` | a failed list fell through to an empty PR set = no overlap = LAUNCH | with no cache: `DEFER <KEY> gh unknown (HTTP <s>) …`, rc 1, plus one `ALERTS.log` line per project per UTC day. With a cache: judged from the cache, which a failed read never overwrites |
| `bin/dep-verify.sh` | a failed list read as "the blocker has no PR"; a failed body read as an empty body, dropping the author's `(hard)` hatch | both answer `UNKNOWN gh HTTP <s> …`, each answered at the point where it has actually cost something, and `RECORD` still refuses to cache UNKNOWN |
| `bin/run-triage.sh` | the SOP said "every error answers LAUNCH too" | that sentence now names the one exception, and the five `tests/fixtures/rt-split/prompt-*.txt` goldens were regenerated with it |

## Why

#768, 2026-09-18 02:49-03:05Z. A rate-limited GraphQL `gh pr list` exited 0 and
printed nothing. Five launch gates read that silence as `[]` — "this repo has no
open PRs" — and acted on it: five real PRs were rewritten RESULT_UNVERIFIED and
TK-2302 was launched three times on top of work that was already written.

## Decisions worth knowing

- **The per-author GraphQL list stays.** `files`, `mergeStateStatus`,
  `mergeable` and `isInMergeQueue` are GraphQL-only LIST fields and four live
  lanes ask for them. Only the GraphQL *retry after a REST failure* was removed;
  the launch-gate property is preserved from the other side by making a silent
  author a failed author. Consequence: `bin/overlap-guard.sh`'s DEFER normally
  reads `HTTP n/a`, because the per-author path saw no HTTP status and naming
  one it never got would be worse than saying so.
- **`prs[].mergeStateStatus` left the triage-gate fingerprint.** REST list
  responses do not carry it; buying it back is one `GET /pulls/{n}` per open PR
  per tick. A merge, close, rebase, new comment or state change all still wake
  the tick; a bare CHECK flip no longer does — the same argument the queue gate
  already made about that field. Knock-on: `bin/gate-diff.sh`'s NEW-PR line
  printed the field unconditionally and would have rendered a literal
  `mergeState None`, so that one token was dropped in the same commit that made
  the claim false. `describe()` still maps the key, for fingerprints written
  before this change.
- **An unreadable PR list fails the triage-gate fetch.** Substituting `prs:[]`
  looked like the fail-open and is not one: on a board with no open PRs the
  substitute fingerprint equals the stored one and the tick SKIPs off a read it
  never made, and on any board `bin/lib/rt/gate.sh` promotes `gate.pending` into
  the stored fingerprint after a session, so tick 2 of an outage matches tick
  1's substitute and SKIPs. `return 1` is the fail-open the file's header has
  always documented: `RUN gate-fetch-failed`, `--pending` exits 1, `--seed`
  says SEED-FAILED.
- **`bin/dep-verify.sh` answers each UNKNOWN where it costs something.** An
  unreadable child body is recorded AFTER the pre-plan `DEPENDS: … hard` check
  and the file-overlap check, not at the read: `RECORD` is terminal, both of
  those can still answer HARD (a hold) from a local file and from a PR list that
  was read fine, and UNKNOWN is not a hold — `DEP_UNKNOWN_MODE` defaults to
  `soft`, which RELEASES the child. So the outage costs the `Blocked-by … (hard)`
  marker and nothing else. Same reasoning as the PR-list UNKNOWN, one section
  further down.
- **`gh_rest_pr_state` returns lowercase** (`open`/`merged`) where `gh pr view`
  returned `OPEN`/`MERGED`, and the queue gate **upper-cases it back** before it
  writes line 3 of `state/<p>.queuefp`. That line is not private: BH-1015's
  `triage_prstates_ingest` folds the vector into the per-ticket PR-state ledger
  verbatim while `triage_prstates_refresh` writes the UPPER words, so the API's
  own spelling here would make the two producers disagree about the same PR and
  flip the shard fingerprint twice every 45-minute cycle — a paid session each
  way. With the `tr`, the stored vector is byte-identical to the one `gh pr
  view` produced, so the deploy costs no re-stamp at all.
- **No new env var, no new state store, no migration.** The three stores this
  touches keep their shapes; the rule added to each is "never write state from
  an unclassified read".

## How to check it

`HARNESS_TEST_SANDBOX=1 bash tests/launch-gate-unknown.bh-782-test.sh` (96
assertions over the four real scripts and the library, including four mutation
checks). The map entry
[launch-gates-rest.md](../verification-map/launch-gates-rest.md) has the
per-lane table and the read-only commands for a live box.
