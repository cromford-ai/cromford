#!/bin/bash
# bin/test-impact-workflow.sh <base> <head> [--root <dir>] — DOES THIS DIFF OF
# .github/workflows/harness-ci.yml TOUCH A JOB THAT DECIDES A SUITE VERDICT?
# (BH-6688)
#
# A merge-queue batch escalated to the whole corpus on ANY change to the
# workflow (the `.github/` row of the rules in catalog/ci-batch-escalate.d/, and
# `^\.github/workflows/` in bin/test-impact.sh's infra list). Most of those
# changes are a lint step: the corpus proves nothing about them. This script
# reads the diff line by line and names the job each changed line is in, on
# the side it is in (a removed line on <base>'s file, an added line on
# <head>'s). Since BH-6876 a batch selects a workflow file's readers on any
# answer (an allow row in the rules in catalog/ci-batch-escalate.d/); bin/ci-plan.sh still
# asks this script, and on rc 1 its reason names the non-test jobs.
#
#   rc 1  every changed line is in a NON-TEST job below, or is a column-0 `#`
#         comment: `workflow: non-test jobs only (<jobs>)`
#   rc 0  any other line: a job not in the list (tests-shard, plan, a new or
#         renamed job), or a line outside `jobs:` (on:, env:, concurrency:):
#         `workflow: test job <job>` or `workflow: top-level line <n> (<side>)`
#   rc 2  the base or head cannot be read, the file is added or deleted on
#         that range, or the diff is empty: `workflow: unreadable (<why>)`
#
# A job starts at a two-space `<name>:` line after column-0 `jobs:` and ends at
# the next one, or at the next column-0 key. Unknown is a test job, so the list
# fails closed: a job someone adds runs the corpus until it is named here.
WF_PATH=.github/workflows/harness-ci.yml
# The jobs whose steps cannot change what a suite answers:
#   lint          syntax, shellcheck, config integrity and fast lints; it runs
#                 no suite the shards run, and its own verdict is its own check
#   determinism   bin/test-determinism-lint.sh over test sources, no suite run
#   prompt-evals  prompt replay; reads prompts/, never a suite verdict
#   ci-timings    posts green shards' timings after the fact, continue-on-error
WF_NONTEST_JOBS=(lint determinism prompt-evals ci-timings)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=""; HEAD_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "workflow: unreadable (--root needs a dir)"; exit 2; }; ROOT="$2"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) if [ -z "$BASE" ]; then BASE="$1"; elif [ -z "$HEAD_REF" ]; then HEAD_REF="$1"
       else echo "workflow: unreadable (unknown argument $1)"; exit 2; fi ;;
  esac
  shift
done
unreadable() { echo "workflow: unreadable ($1)"; exit 2; }
[ -n "$BASE" ] && [ -n "$HEAD_REF" ] || unreadable "usage: <base> <head> [--root <dir>]"
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || unreadable "cannot resolve the base ${BASE:0:12}"
git -C "$ROOT" cat-file -e "$HEAD_REF^{commit}" 2>/dev/null || unreadable "cannot resolve the head ${HEAD_REF:0:12}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ti-wf.XXXXXX") || unreadable "no temp dir"
trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" show "$BASE:$WF_PATH" > "$TMP/old" 2>/dev/null || unreadable "$WF_PATH is not in the base ${BASE:0:12}"
git -C "$ROOT" show "$HEAD_REF:$WF_PATH" > "$TMP/new" 2>/dev/null || unreadable "$WF_PATH is not in the head ${HEAD_REF:0:12}"
git -C "$ROOT" diff -U0 --no-renames "$BASE" "$HEAD_REF" -- "$WF_PATH" > "$TMP/diff" 2>/dev/null || unreadable "cannot diff $WF_PATH"
grep -q '^@@' "$TMP/diff" || unreadable "the diff is empty"

# The awk reads each side's file into a line -> region map (`top`, `#`, or the
# job name), then classifies every changed line of each hunk on its own side.
awk -v nontest=" ${WF_NONTEST_JOBS[*]} " '
  function region(f, side,   l, n, injobs, job) {
    n = 0; injobs = 0; job = ""
    while ((getline l < f) > 0) {
      n++
      if (l ~ /^#/) { R[side, n] = "#"; continue }
      if (l ~ /^[^ \t]/) { injobs = (l ~ /^jobs:[ \t]*(#.*)?$/); job = ""; R[side, n] = "top"; continue }
      if (injobs && match(l, /^  [A-Za-z0-9_-]+:/)) job = substr(l, 3, RLENGTH - 3)
      R[side, n] = (injobs && job != "") ? job : "top"
    }
    close(f)
  }
  function take(side, start, cnt,   i, r) {
    for (i = start; i < start + cnt; i++) {
      r = R[side, i]
      if (r == "#") { add("comment"); continue }
      if (r == "" || r == "top") { print "workflow: top-level line " i " (" side ")"; bad = 1; exit 0 }
      if (index(nontest, " " r " ") == 0) { print "workflow: test job " r; bad = 1; exit 0 }
      add(r)
    }
  }
  function add(j) { if (!(j in seen)) { seen[j] = 1; jobs = jobs (jobs == "" ? "" : ",") j } }
  BEGIN { region(ARGV[1], "base"); region(ARGV[2], "head"); ARGV[1] = ""; ARGV[2] = "" }
  /^@@ / {
    split($2, o, ","); split($3, h, ",")
    os = substr(o[1], 2) + 0; oc = (2 in o) ? o[2] + 0 : 1
    hs = substr(h[1], 2) + 0; hc = (2 in h) ? h[2] + 0 : 1
    take("base", os, oc); if (bad) exit 0
    take("head", hs, hc); if (bad) exit 0
  }
  END {
    if (bad) exit 0
    if (jobs == "") { print "workflow: unreadable (no changed line)"; exit 2 }
    print "workflow: non-test jobs only (" jobs ")"; exit 1
  }
' "$TMP/old" "$TMP/new" "$TMP/diff"
