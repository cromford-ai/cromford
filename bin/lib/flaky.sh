#!/bin/bash
# bin/lib/flaky.sh — what a flaky CI run IS, in one place. Sourced, never executed.
#
# THE PROBLEM THIS EXISTS FOR (the operator, 2026-09-12). Nothing in the harness today
# separates "red because broken" from "red because flaky". Both read as a red
# strike, and a red strike costs a fix round, a re-review, or — once PRs go
# through a merge queue in batches — an ejection that re-builds everything
# behind it. The fleet has been paying that bill blind: no count, no name, no
# rate, so "CI is flaky lately" has never been a number anyone could act on.
#
# THE SIGNAL, AND WHY IT IS THE SHA. A head sha is a tree. Two runs of the SAME
# workflow on the SAME sha are the same code, the same lockfile, the same
# workflow file, run twice — so if one concluded failure and one concluded
# success, the code did not change between them and the difference is the test,
# the runner, or the network. That is the definition of a flake, and the sha is
# what makes "with no push in between" a fact rather than a heuristic: a push
# produces a different sha and therefore a different group. (Mergify's CI
# Insights draws exactly the same line — same commit, differing results — which
# is the confirmation that this is the right primitive, not a shortcut.)
#
# WHAT WE DELIBERATELY DO NOT DO. Mergify already handles the merge-queue half:
# `max_checks_retries` retries a queue entry's CI on a fresh draft before
# ejecting it, and CI Insights does plugin-based rerun/quarantine off uploaded
# JUnit. Neither covers the PR's OWN checks before it is ever enqueued, which is
# where the harness's red strikes are counted, and CI Insights needs a per-repo
# plugin and an upload the product repos do not have. So: this reads run history
# that GitHub already keeps, for free, in every repo, and stops at the queue
# boundary. See docs/FLAKY-TESTS.md.
#
#   flaky_since_date [days]             -> YYYY-MM-DD, `days` ago (default window)
#   flaky_parse_tests                   <- a --log-failed stream on stdin
#                                       -> one failing TEST name per line (vitest/jest
#                                          tests, then cromford tests/<x>.sh suites)
#   flaky_failed_runs <slug> <sha>      -> "<run-id>|<workflow-path>|<workflow-name>|<head_sha>"
#                                          for each red run on that head
#   flaky_run_tests <slug> <run-id>     -> that run's failing test names; falls back
#                                          to "job:<failed job name>" when the log
#                                          carries none we can read
#   flaky_run_tests_strict <slug> <id>  -> the same names for a DECISION (BH-3776):
#                                          rc 2 when the log cannot be read, is
#                                          empty, is over FLAKY_LOG_MAX bytes, or
#                                          names more than FLAKY_TESTS_MAX tests,
#                                          or when a failed job names nothing and
#                                          is no fan-in over jobs that did;
#                                          job:<name> only for a log that was read
#                                          and named no test
#   flaky_known_set <slug> [since] [min]-> the test names the LEDGER says are flaky
#                                          (>= min distinct heads inside the window),
#                                          cached per process
#   flaky_quarantined_set <slug>        -> the test names an operator quarantined for
#                                          that repo (the flaky_quarantine table, via
#                                          metric_flake_quarantine_list), cached per
#                                          process; unreadable is the EMPTY set
#   flaky_gate_set <slug>               -> flaky_known_set plus flaky_quarantined_set,
#                                          deduped: what the merge conductor forgives
#   flaky_all_known <slug>              <- names on stdin; rc 0 only when there is at
#                                          least one name and EVERY one is in the gate set
#
# Every read here is a read. Nothing in this file writes to GitHub.

# The Actions read below goes through bin/lib/gh-ci-read.sh (sibling file): the
# default token first, and a read-only App token only when the box's PAT 403s on
# actions/runs. Without it, a plain `gh api` — today's read, unchanged.
# shellcheck source=bin/lib/gh-ci-read.sh
if [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-ci-read.sh" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-ci-read.sh"
elif ! command -v gh_ci_api >/dev/null 2>&1; then
  gh_ci_api() { shift; gh api "$@"; }
fi

FLAKY_WINDOW_DAYS="${FLAKY_WINDOW_DAYS:-14}"
# How many DISTINCT heads a test must have flaked on inside the window before it
# counts as a known flake. Distinct heads, not rows and not runs: one bad head
# that was re-run nine times is one piece of evidence, not nine.
FLAKY_MIN="${FLAKY_MIN:-3}"
# Bytes of --log-failed we are willing to read per run. A failed job's log can be
# tens of MB (a browser suite with traces); the failing-test lines are at the
# top of the reporter output. 0 disables log reading entirely and leaves only
# the job-name fallback.
FLAKY_LOG_MAX="${FLAKY_LOG_MAX:-2000000}"
FLAKY_TESTS_MAX="${FLAKY_TESTS_MAX:-20}"

flaky_since_date() { # flaky_since_date [days]
  local d="${1:-$FLAKY_WINDOW_DAYS}" now
  case "$d" in ''|*[!0-9]*) d=14 ;; esac
  now=$(date -u +%s)
  date -u -d "@$(( now - d * 86400 ))" +%Y-%m-%d 2>/dev/null \
    || date -u -r "$(( now - d * 86400 ))" +%Y-%m-%d 2>/dev/null \
    || date -u +%Y-%m-%d
}

# flaky_parse_tests — the only place that knows what a test runner's failure
# line looks like. stdin is a raw Actions log (every line prefixed with the
# step's UTC timestamp); stdout is one failing test name per line, deduped.
#
# Covered, because these are what the fleet's repos actually run:
#   vitest   "  × suite > name 42ms"   /  "✕"  /  "✗"
#   vitest   " FAIL  src/x.test.ts > suite > name"
#   jest     "  ● Suite › test name"
#   cromford "--- tests/x-test.sh rc=1 3s"  (bin/test-trace-safety.sh --gate,
#            its `echo "--- ${TEST_PATH#"$ROOT"/} rc=$RC …"` line; BH-3700)
# A PASSING marker (✓, ↓) is never matched — the whole value of the ledger is
# that a name in it flaked, and one pass line captured by a sloppy regex would
# quarantine a test that never failed. For the same reason the harness shape
# matches a nonzero rc only: rc=0 is a suite that passed.
#
# Both branches read the SAME stdin (spooled to a temp file); runner names come
# first, suite names after, and the union is deduped. If mktemp fails it parses
# vitest/jest straight off stdin, exactly as before BH-3700.
flaky_parse_tests() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/flaky-parse.XXXXXX" 2>/dev/null) || { _flaky_parse_runner; return; }
  cat > "$tmp"
  { _flaky_parse_runner < "$tmp"; _flaky_parse_harness < "$tmp"; } | awk '!seen[$0]++'
  rm -f "$tmp"
}

# The vitest/jest pipeline, unchanged since before BH-3700.
_flaky_parse_runner() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*//' 2>/dev/null \
  | grep -aE '(×|✕|✗|●)[[:space:]]|(^|[[:space:]])FAIL[[:space:]]' \
  | sed -E 's/.*(×|✕|✗|●)[[:space:]]+//' \
  | sed -E 's/^[[:space:]]*FAIL[[:space:]]+[^[:space:]]+[[:space:]]+>[[:space:]]+//; s/^[[:space:]]*FAIL[[:space:]]+//' \
  | sed -E 's/[[:space:]]+[0-9]+(\.[0-9]+)?[mun]?s$//' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | tr -d '\t\r' \
  | grep -avE '^$|^Console$|^Test suite failed to run$|^Deprecation Warning' \
  | cut -c1-300 \
  | awk '!seen[$0]++'
}

# The cromford runner line. Unanchored: --log-failed prefixes every line
# with "job<TAB>step<TAB>timestamp ". [1-9] first keeps rc=0 out.
_flaky_parse_harness() {
  grep -aoE -- '--- tests/[A-Za-z0-9._/-]+\.sh rc=[1-9][0-9]*' \
  | sed -E 's/^--- ([^ ]+) rc=.*/\1/'
}

# _flaky_parse_harness_strict (BH-3857) — the strict path's harness marker:
# only the line bin/test-trace-safety.sh itself prints,
# `--- tests/<x>.sh rc=<N> <secs>s`, at the start of the line once gh's
# job/step prefix and the timestamp are gone. The timestamp's ONE separating
# space is all that is stripped, so an indented echo stays indented and never
# matches. _flaky_parse_harness stays unanchored for flaky_run_tests' callers.
_flaky_parse_harness_strict() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/\r$//' \
  | sed -nE 's/^--- (tests\/[A-Za-z0-9._\/-]+\.sh) rc=[1-9][0-9]* [0-9]+s$/\1/p'
}

# flaky_failed_runs <owner/repo> <sha> -> "<id>|<path>|<name>|<head_sha>" per red run.
# The head_sha lets a dispatcher refuse a run listed for another sha (BH-3804).
# The -q expression is what tells this read apart from mc_ci_state's read of the
# same endpoint; keep the select() in it.
flaky_failed_runs() {
  gh_ci_api "$1" "repos/$1/actions/runs?head_sha=$2&per_page=50" \
    -q '.workflow_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | "\(.id)|\(.path)|\(.name)|\(.head_sha // "")"' \
    2>/dev/null
}

# flaky_run_tests <owner/repo> <run-id>
# The log first, the failed JOB names second. The fallback is not a guess: a row
# that says job:unit is honest about the fact that we could not read the test
# names, and it is still a countable red for the rate. What it can never do is
# become a quarantine entry, because "job:unit" is not a test name any runner
# will match.
flaky_run_tests() {
  local slug="$1" id="$2" out=""
  if [ "${FLAKY_LOG_MAX:-0}" -gt 0 ] 2>/dev/null; then
    out=$(gh run view "$id" -R "$slug" --log-failed 2>/dev/null \
          | head -c "$FLAKY_LOG_MAX" | flaky_parse_tests)
  fi
  if [ -z "$out" ]; then
    out=$(gh api "repos/$slug/actions/runs/$id/jobs" \
            -q '.jobs[] | select(.conclusion=="failure") | .name' 2>/dev/null \
          | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -d '\t' \
          | grep -av '^$' | awk '!seen[$0]++' | sed 's/^/job:/')
  fi
  [ -n "$out" ] || return 1
  head -n "${FLAKY_TESTS_MAX:-20}" <<<"$out"
}

# flaky_run_tests_strict <owner/repo> <run-id> (BH-3776) — flaky_run_tests for a
# caller that DECIDES on the answer (the merge conductor's foreign-red
# attribution), where a partial list is worse than none. Same parse, but:
#   rc 2  the log could not be read (gh failed), came back empty, was longer
#         than FLAKY_LOG_MAX bytes (a cut log can drop the suite that matters),
#         or named more than FLAKY_TESTS_MAX tests (a capped list can too);
#         the run's jobs could not be read in full (the read failed, or the
#         page did not hold every job), or no job of the failed run failed;
#         or SOME failed job is not attributed (#3798 round 3, N2): the log
#         names tests, but a failed job's own section of it (--log-failed
#         prefixes every line with the job's name) names none and is not a
#         fan-in check pointing at failed jobs that did (_flaky_jobs_attributed).
#         A red SPA build next to a shard that named an untouched suite is NOT
#         "the batch failed that suite".
#   rc 0  every failing name, one per line, TAGGED by where it came from
#         (#3798 round 5: provenance, not shape):
#           P<TAB><path>     a harness `--- tests/<x>.sh rc=N` line, or the
#                            file token of a jest/vitest `FAIL <file>` line
#                            (has an extension, no spaces): a real file
#           T<TAB><title>    any other runner name (×/✕/✗/● lines, the title
#                            after `FAIL <file> >`): a test, not a file, even
#                            when it looks like one (`works`, `api/health`)
#           J<TAB>job:<name> ONLY when the log was read in full and named no
#                            test at all: the failed jobs are all we know. A
#                            log that could not be read never turns into job:.
# flaky_run_tests is unchanged for its other callers (flaky-detect, classify).
flaky_run_tests_strict() {
  local slug="$1" id="$2" max="${FLAKY_LOG_MAX:-0}" cap="${FLAKY_TESTS_MAX:-20}" tmp out jraw failed sz
  case "$max" in ''|*[!0-9]*) return 2 ;; esac
  [ "$max" -gt 0 ] || return 2
  case "$cap" in ''|*[!0-9]*) cap=20 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/flaky-strict.XXXXXX" 2>/dev/null) || return 2
  if ! gh run view "$id" -R "$slug" --log-failed > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 2; fi
  sz=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*|0) rm -f "$tmp"; return 2 ;; esac
  [ "$sz" -le "$max" ] || { rm -f "$tmp"; return 2; }
  out=$(_flaky_strip_gh_prefix < "$tmp" | _flaky_parse_tagged) || { rm -f "$tmp"; return 2; }
  # Every job that did not pass. A page that does not hold them all is no answer.
  jraw=$(gh api "repos/$slug/actions/runs/$id/jobs?per_page=100" 2>/dev/null) || { rm -f "$tmp"; return 2; }
  failed=$(jq -r '(.jobs // null) as $j
    | if ($j | type) != "array" or (.total_count // 0) > ($j | length) then error("partial")
      else $j[] | select((.conclusion // "") | IN("success","skipped","neutral") | not) | (.name // "") end' \
      <<<"$jraw" 2>/dev/null) || { rm -f "$tmp"; return 2; }
  failed=$(printf '%s\n' "$failed" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -d '\t' \
           | grep -av '^$' | awk '!seen[$0]++')
  [ -n "$failed" ] || { rm -f "$tmp"; return 2; }
  if [ -z "$out" ]; then
    out=$(printf '%s\n' "$failed" | sed 's/^/J\tjob:/')
  elif ! _flaky_jobs_attributed "$tmp" "$failed"; then
    rm -f "$tmp"; return 2
  fi
  rm -f "$tmp"
  [ "$(printf '%s\n' "$out" | grep -c .)" -le "$cap" ] || return 2
  printf '%s\n' "$out"
}

# _flaky_strip_gh_prefix — `gh run view --log-failed` prints every line as
# "<job>\t<step>\t<timestamp> <text>"; the runner parse strips a LEADING
# timestamp only, so a vitest/jest FAIL line kept "<job><step><ts> FAIL" glued
# to its name (#3798 round 4, F3). Strict path only: flaky_run_tests is
# byte-identical for its other callers. Lines without two tabs pass unchanged.
# It also drops ANSI CSI escapes (BH-3857): vitest and jest colour their FAIL
# lines in Actions logs (`\e[31m FAIL \e[39m src/x.test.ts`), and a coloured
# line matched no runner shape, so a coloured log named nothing at all.
_flaky_strip_gh_prefix() {
  local t=$'\t' e=$'\033'
  sed -E "s/^[^${t}]*${t}[^${t}]*${t}//; s/${e}\[[0-9;]*[A-Za-z]//g"
}

# _flaky_parse_tagged — the strict path's parse (stdin: a log with gh's
# job/step prefix already stripped). The same names flaky_parse_tests finds,
# plus the file token of every `FAIL <file>` line, each tagged P (a file, by
# where it came from) or T (anything else). Shape never decides: a one-word or
# slashed title is T. rc 1 when the spool cannot be made.
# P is only what a RUNNER printed (BH-3857): the harness marker in the exact
# shape bin/test-trace-safety.sh prints it (_flaky_parse_harness_strict), and a
# `FAIL <file>` token that is a vitest/jest test file (`.test.`/`.spec.` or
# under `__tests__/`). A test's own stdout echoing either (`  --- tests/b.sh
# rc=1`, `FAIL notes.txt`) still reaches T through flaky_parse_tests: a name
# nobody can check against the PR, so never lifted and never ledgered.
_flaky_parse_tagged() {
  local tmp t=$'\t'
  tmp=$(mktemp "${TMPDIR:-/tmp}/flaky-tag.XXXXXX" 2>/dev/null) || return 1
  cat > "$tmp"
  {
    { _flaky_parse_harness_strict < "$tmp"
      sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*//' "$tmp" \
        | sed -nE 's/^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+).*/\1/p' \
        | grep -aE '^[A-Za-z0-9._/@+-]+\.[A-Za-z0-9]+$' \
        | grep -aE '(\.(test|spec)\.[cm]?[jt]sx?|(^|/)__tests__/.+\.[cm]?[jt]sx?)$'
    } | awk '!s[$0]++' | sed "s/^/P$t/"
    flaky_parse_tests < "$tmp" | sed "s/^/T$t/"
  } | awk -F'\t' '$2 != "" && !s[$2]++'
  rm -f "$tmp"
}

# What a FAN-IN check prints when the shards it judges failed: bin/ci-verdicts.sh
# pure, the step behind `Pure-logic gate fixtures`, says per red shard
#   ::error::shard <i>/<n>: <k> of <m> tests failed. Open '<shard job name>' — …
# (rendered `##[error]…` in the log). Derived from that script's own output, not
# from a list of job names: tests/mc/requeue-after-foreign-red.bh-3776-test.sh
# runs the real script and fails if the wording moves away from this pattern.
FLAKY_FANIN_RE="^shard [0-9]+/[0-9]+: [0-9]+ of [0-9]+ tests failed\. Open '([^']+)'"

# _flaky_jobs_attributed <log-file> <failed job names> — rc 0 when EVERY failed
# job is attributed: its own --log-failed section (lines whose first tab field
# is the job's name) names a test, or it is a fan-in whose error lines are all
# FLAKY_FANIN_RE pointers at jobs that named theirs (plus the runner's
# "Process completed with exit code N." line). Anything else is rc 1.
_flaky_jobs_attributed() {
  local log="$1" failed="$2" j named="" pending="" errs e ptr
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    if [ -n "$(FLAKY_J="$j" awk -F'\t' '$1 == ENVIRON["FLAKY_J"]' "$log" | _flaky_strip_gh_prefix | flaky_parse_tests)" ]; then
      named="$named$j"$'\n'
    else
      pending="$pending$j"$'\n'
    fi
  done <<<"$failed"
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    errs=$(FLAKY_J="$j" awk -F'\t' '$1 == ENVIRON["FLAKY_J"]' "$log" \
           | grep -aE '##\[error\]|::error::' | sed -E 's/.*(##\[error\]|::error::)//')
    [ -n "$errs" ] || return 1
    ptr=0
    while IFS= read -r e; do
      e=$(printf '%s' "$e" | tr -d '\r')
      case "$e" in "Process completed with exit code "*) continue ;; esac
      [[ "$e" =~ $FLAKY_FANIN_RE ]] || return 1
      grep -qxF -- "${BASH_REMATCH[1]}" <<<"$named" || return 1
      ptr=1
    done <<<"$errs"
    [ "$ptr" = 1 ] || return 1
  done <<<"$pending"
  return 0
}

# The known-flake set, read from the ci_flakes ledger and cached per process.
# A cache miss and an unreachable worker are the SAME answer here — the empty
# set — and that is deliberate: with no evidence, nothing is a known flake and
# every red counts, which is the direction a failure has to fall.
# Memoised for ONE slug, not a map: the merge conductor handles a repo to
# completion before moving to the next, so a one-entry cache is every hit a map
# would have given, without needing bash 4.
_FLAKY_KNOWN_SLUG=""
_FLAKY_KNOWN_SET=""
flaky_known_set() { # flaky_known_set <owner/repo> [since] [min]
  local slug="$1" since="${2:-}" min="${3:-$FLAKY_MIN}" rows=""
  [ -n "$since" ] || since=$(flaky_since_date)
  case "$min" in ''|*[!0-9]*) min=3 ;; esac
  if [ "$_FLAKY_KNOWN_SLUG" != "$slug" ]; then
    command -v metric_flakes_list >/dev/null 2>&1 && \
      rows=$(metric_flakes_list 2000 "$slug" "$since" 2>/dev/null || true)
    _FLAKY_KNOWN_SET=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$since" -v r="$slug" -v m="$min" '
      $6=="flake" && $1>=s && $2==r && $4!="" && $4 !~ /^job:/ {
        k=$4 SUBSEP $5; if (!(k in seen)) { seen[k]=1; n[$4]++ }
      }
      END { for (t in n) if (n[t] >= m) print t }' 2>/dev/null)
    _FLAKY_KNOWN_SLUG="$slug"
  fi
  printf '%s\n' "$_FLAKY_KNOWN_SET" | grep -av '^$' || true
}

# flaky_quarantined_set <owner/repo> — the active quarantine rows for one repo
# (BH-2632). A quarantine is an operator's audited "this test is a known flake"
# (PUT /api/metrics/flakes/quarantine). It is kept OUT of flaky_known_set on
# purpose: bin/flaky-quarantine.sh proposes ci/flaky.txt entries from that set,
# and a manual switch in the harness must not leak into product-repo PRs. A read
# that fails, or no client at all, is the empty set: it forgives nothing extra,
# so the gate falls back to exactly the ledger.
_FLAKY_QUAR_SLUG=""
_FLAKY_QUAR_SET=""
flaky_quarantined_set() { # flaky_quarantined_set <owner/repo>
  local slug="$1" rows=""
  if [ "$_FLAKY_QUAR_SLUG" != "$slug" ]; then
    command -v metric_flake_quarantine_list >/dev/null 2>&1 && \
      rows=$(metric_flake_quarantine_list "$slug" 2>/dev/null || true)
    _FLAKY_QUAR_SET=$(printf '%s\n' "$rows" | grep -av '^$' || true)
    _FLAKY_QUAR_SLUG="$slug"
  fi
  printf '%s\n' "$_FLAKY_QUAR_SET" | grep -av '^$' || true
}

# flaky_gate_set <owner/repo> — what the merge conductor's red gate treats as a
# known flake: the ledger's set plus the operator's quarantine, deduped.
flaky_gate_set() { # flaky_gate_set <owner/repo>
  { flaky_known_set "$1"; flaky_quarantined_set "$1"; } | grep -av '^$' | sort -u
}

# flaky_all_known <owner/repo>  — names on stdin.
# rc 0 ONLY when there is at least one name and every single one is in the gate
# set (flaky_gate_set). An empty name list is rc 1 on purpose: "we could not
# read what failed" must never read as "nothing real failed".
flaky_all_known() {
  local slug="$1" known n any=0
  known=$(flaky_gate_set "$slug")
  [ -n "$known" ] || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    any=1
    grep -qxF -- "$n" <<<"$known" || return 1
  done
  [ "$any" = 1 ]
}
