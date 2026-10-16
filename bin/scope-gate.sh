#!/bin/bash
# bin/scope-gate.sh <build-dir> <base-sha> [repo-dir]
#
# Mechanize the plan's own bounce rule. prompts/plan-contract.md already says it
# in prose — "needing a file outside scope = stop and report, never improvise" —
# and nothing has ever checked it. This diffs what the build ACTUALLY changed
# against the file set the plan named (bin/planned-files.sh writes
# planned-files.txt at PLAN time, before a single line was edited) and reports
# what the builder reached for that nobody asked it to touch.
#
# WHY (SDLC item 4, 2026-09-06). TK-70 was an eager platform-binary import in a
# route the ticket never named: every attachment save 500'd. The diff said so
# before the review did, and the pipeline had no reader for that fact — it went
# to a paid reviewer as one file among many. Unplanned files are also where the
# two expensive fraud classes live (scope-creep and unauthorized-action), and
# they are the cheapest thing on this box to count.
#
# NOT EVERY UNPLANNED FILE IS A PROBLEM, which is why this classifies rather
# than counting. Four kinds, checked in this order, first match wins:
#
#   protected  an unplanned file in the set where a surprise is expensive:
#              .github/workflows/, package manifests and lockfiles, prisma/,
#              env files, and scripts/migrations/ (plus the project's
#              migrations_glob dir) ONLY when the plan named no migration of its
#              own (a planned migration wave obviously writes there). This is the one class that can move a tier. It is
#              reported as a SUBSET of foreign, never as a fifth bucket.
#   test       a test file for the work — the shape we WANT and never planned
#              in advance, so counting it as creep would punish the discipline
#              the repro gate exists to enforce.
#   spec       docs, markdown, READMEs: "update the docs in the same PR" is a
#              standing rule in every repo CLAUDE.md.
#   adjacent   an unplanned file in a directory the plan DID name. The plan's
#              file list is a heuristic superset (planned-files.sh scrapes
#              paths out of markdown), so a sibling in a named directory is
#              usually the plan being imprecise, not the builder wandering.
#   foreign    everything else: a file in a part of the repo the plan never
#              mentioned. This is the number a reviewer should read.
#
# WARN FIRST. This script never blocks and has no opinion about tiers; it
# reports. bin/run-build.sh owns the consequence, behind SCOPE_GATE_ENFORCE
# (default 0 = warn only: the counts reach the reviewer, the PR body and the
# ledger, the tier is untouched). Set it to 1 in env/global.env — the env file
# run-build.sh sources `set -a`, NOT fleet.conf, which is a positional project
# registry whose first column would read a key=value line as a project name.
#
# NO PLAN, NO VERDICT. An absent or empty planned-files.txt means the planner
# named no files at all; every changed file would then score as unplanned and
# every such build would be demoted for the planner's silence. That is exit 3,
# and the note says the gate did not run — never "this diff is out of scope".
#
# THE PLAN LIST IS SHORT BY EXACTLY THE FAMILIES THAT MATTER MOST HERE.
# bin/planned-files.sh keeps only paths under src|prisma|scripts|e2e|tests|app|
# lib|components|pages|public|docs|content|middleware, so `package.json`,
# `pnpm-lock.yaml`, `.github/workflows/*.yml` and `.env*` are dropped from
# planned-files.txt NO MATTER WHAT THE PLAN SAYS. Widening that scraper is not
# the fix: bin/conflict-check.sh DEFERS a build whose planned files overlap a live
# sibling's, so listing `package.json` there would send every build that mentions
# a manifest back to the queue behind every other one. So this gate re-reads plan.md for those
# families ONLY (PLAN_EXTRA below) and adds them to its own plan set. Without
# it three of the five protected families could never test as planned, "unplanned
# AND protected" would collapse to "protected", and a dependency or CI ticket
# would be demoted — and told "the plan named none of them" — for doing exactly
# what it was asked.
#
# THE PLAN IS READ FOR POSITIVE MENTIONS ONLY, and has to be, because
# prompts/plan-contract.md:19 REQUIRES every sub-ticket to carry non-goals. A
# planner writing "non-goals: do not modify package.json or the CI workflows" is
# the expected shape, and a context-free grep would read that sentence as the
# plan naming those files — exempting exactly the class this gate exists to
# catch, and reporting `in-scope` for the worst case. So exclusion SENTENCES are
# dropped before the scrape, and a bare `.github/workflows` with no filename is
# NOT a scope: a directory mention would make every workflow file planned.
#
# THE SAME READING FILTERS THE TWO PROTECTED FAMILIES planned-files.txt DOES
# carry. bin/planned-files.sh scrapes every prisma/*.prisma and
# scripts/migrations/* token regardless of the sentence around it, so "do not
# touch prisma/schema.prisma" arrived here as a PLAN ENTRY and a schema change
# scored in-scope. An entry in those two families survives only if the plan's
# positive text names it too (PLAN_POS/PLAN_KEPT below). planned-files.txt
# itself is left alone: bin/conflict-check.sh defers overlapping builds on that
# list, and narrowing it there would change which builds get deferred.
#
# TWO READERS, ONE RULE, DELIBERATELY NOT ONE IMPLEMENTATION.
# bin/evidence-summary.sh's "files" row counts planned-vs-changed too, with the
# same "listed, or under a listed directory" matcher and the same
# .harness/specs exclusion. It is NOT refactored into a call to this script,
# because it answers a different question with different inputs: it renders from
# changed-files.txt with NO repo access at all, so an archived record months
# later still produces the same block. The two numbers can legitimately differ
# by two things: the spec artifact this excludes and that block counts, and the
# PLAN_EXTRA scrape, which only this gate has plan.md to read. (The fix rounds'
# own files were a third, until run-build.sh started re-running this gate at
# settle time when SCOPE_HEAD no longer matches HEAD.) What must never differ is
# the MATCHER — "listed, or under a listed directory" — change one and change
# the other.
#
# NEVER BUILD A COMMAND STRING FROM A FILENAME. Paths come from a diff produced
# by a builder steered by client-authored ticket text, and this runs as root.
# Every path is handled inside awk; no eval, no `bash -c`, no glob expansion,
# and the listing is bounded (SCOPE_GATE_MAX_LIST, default 12) so a 400-file
# rebase cannot flood the review prompt.
#
# exit 0  every changed file was planned (or is the pipeline's own spec commit)
# exit 1  unplanned files land in the PROTECTED set — the tier-2 demotion case
# exit 2  unplanned files, none protected — record, never block
# exit 3  gate could not run honestly (no plan file, no diff, base unresolvable)
set -uo pipefail
BUILD="${1:-}"
BASE="${2:-}"
REPO="${3:-.}"
MAXLIST="${SCOPE_GATE_MAX_LIST:-12}"
case "$MAXLIST" in ''|*[!0-9]*) MAXLIST=12 ;; esac
HARNESS="${HARNESS:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"

# The project's migrations dir (migrations_glob.<project>, bin/lib/migrations-glob.sh).
# It is protected IN ADDITION to scripts/migrations, never instead of it, so no
# file loses its class. The project comes from the build's job.json; no file, no
# jq or no lib leaves MIGDIR at scripts/migrations and every test below as before.
MIGDIR=scripts/migrations
# shellcheck source=bin/lib/migrations-glob.sh
if [ -n "$BUILD" ] && [ -s "$BUILD/job.json" ] && . "$(dirname "$0")/lib/migrations-glob.sh" 2>/dev/null; then
  MIGDIR=$(mg_dir "$(jq -r '.project // empty' "$BUILD/job.json" 2>/dev/null)")
fi
MIG_ERE=$(printf '%s' "$MIGDIR" | sed 's/\./\\./g')

[ -n "$BUILD" ] && [ -d "$BUILD" ] || {
  echo "SCOPE_VERDICT: unavailable"
  echo "usage: scope-gate.sh <build-dir> <base-sha> [repo-dir]" >&2; exit 3; }
PLAN_FILES="$BUILD/planned-files.txt"
if [ ! -s "$PLAN_FILES" ]; then
  echo "GATE_UNAVAILABLE the plan named no files — planned-files.txt is absent or empty, so there is nothing to score this diff against"
  echo "SCOPE_VERDICT: unavailable"; exit 3
fi
cd "$REPO" 2>/dev/null || { echo "GATE_UNAVAILABLE cannot enter $REPO"; echo "SCOPE_VERDICT: unavailable"; exit 3; }
[ -n "$BASE" ] && git rev-parse --verify "$BASE" >/dev/null 2>&1 || {
  echo "GATE_UNAVAILABLE base ${BASE:-<none>} not resolvable"; echo "SCOPE_VERDICT: unavailable"; exit 3; }

# core.quotePath=false: git's default C-quotes any non-ASCII path
# ("src/lib/caf\303\251.ts", quotes included), and a quoted string matches no
# plan entry — a planned file would read as foreign, and dirof() would carry the
# leading quote into the adjacent test.
# WHICH HEAD WAS SCORED. The gate runs before the review, and the review, QA and
# security fix rounds all commit after it. bin/run-build.sh re-runs this gate at
# settle time when HEAD has moved (item 1's rule: the verdict describes the head
# that merges, not the one that was scored), and this line is how it tells.
echo "SCOPE_HEAD: $(git rev-parse HEAD 2>/dev/null || echo -)"
CHANGED=$(git -c core.quotePath=false diff --name-only "$BASE"...HEAD 2>/dev/null)
if [ -z "$CHANGED" ]; then
  echo "GATE_UNAVAILABLE no diff against $BASE — nothing to classify"
  echo "SCOPE_VERDICT: unavailable"; exit 3
fi

# ---- the plan's POSITIVE text: exclusion SENTENCES dropped, once, for both
# readers below. prompts/plan-contract.md:19 REQUIRES every sub-ticket to carry
# non-goals, so "do not modify package.json", "leave prisma/schema.prisma
# alone" and "never touch the CI workflows" are the shape the contract ASKS
# for, and a context-free grep reads them as the plan naming those files —
# exempting exactly the class this gate exists to catch.
#
# SENTENCES, NOT LINES, and WORD-ANCHORED. Dropping whole lines threw away the
# positive half of the sentences this fleet actually writes: "`package.json` —
# append the runner to the test:notify line. Never delete or reorder any
# entry." is ONE line that both plans the manifest and carries the mandated
# caveat, and dropping it demoted a dependency ticket for doing what it was
# asked. And unanchored words matched inside other words: `never` inside
# "whenever", `don.?t` inside "donate". So: split on sentence ends, then drop
# only the segments whose exclusion word is a WORD (grep -w). NOT split on ':'
# and NOT on the em-dash, both of which usually
# carry the exclusion AFTER the filename ("Non-goals: package.json, prisma/…",
# "`prisma/schema.prisma` — do not touch"): splitting there would strand the
# path in a segment with no exclusion word and re-open the hole. So a caveat
# with no sentence break before it ("append X, never deleting entries") still
# drops its whole segment — conservative, which under the warn-first default
# costs a flag, not a demotion.
#
# UNWRAP FIRST, because plan.md is hard-wrapped markdown and a sentence that
# wraps left its exclusion word on line 1 while the paths it forbids sat on
# lines 2 and 3, reading as positive mentions. Real shape, from a plan on this
# box: "NOT touched (explicit non-goals per the ticket): the scorer, / `scripts/
# migrations/2026-07-20-live-coach.sql`, or `prisma/schema.prisma` (TK-82 / owns
# the alias)." So every hard-wrapped CONTINUATION line is folded back onto the
# line it continues before the sentence split. Continuation, not whole
# paragraph: a line that opens a new markdown block (blank, bullet, numbered
# item, heading, quote, table row, fence) starts a new unit, so one bullet's
# "do not reorder" cannot swallow the sibling bullet that plans a file — which
# would be the previous round's false-demotion bug back again in list form.
# plan.md is absent on an archived or hand-built build dir; that leaves both
# lists empty and the narrow planned-files.txt stands alone.
PLAN_TOKENS=""
if [ -s "$BUILD/plan.md" ]; then
  # Split, filter, then split again on every character a path cannot contain,
  # so both greps below can anchor at BOTH ends (grep -x): "mypackage.json" in
  # prose is not the manifest, and ".env-loader.js" is not ".env".
  # `./package.json` is the same file as `package.json`; bin/planned-files.sh
  # strips the prefix, so this reader must too or the anchored grep below misses
  # a manifest the plan DID name and reports it as a protected surprise.
  PLAN_TOKENS=$(awk '
      function flush() { if (length(buf)) print buf; buf = "" }
      /^[[:space:]]*$/ { flush(); next }
      /^[[:space:]]*(([-*+>]|[0-9]+[.)])[[:space:]]|#|```|\|)/ { flush(); buf = $0; next }
      { buf = (length(buf) ? buf " " $0 : $0) }
      END { flush() }' "$BUILD/plan.md" 2>/dev/null \
    | sed -E 's/[.;!?] +/\n/g' \
    | grep -viwE 'non-?goals?|do not|don.?t|never|must not|should not|not touched|out of scope|untouched|leave .* alone' \
    | tr -c 'A-Za-z0-9_./-' '\n' | sed -E 's|^(\./)+||; s|^/+||; s|[./-]+$||')
fi

# The protected families planned-files.sh drops on the floor (see the header).
# Path-prefixed so a monorepo's "apps/web/package.json" is captured whole. A
# FILENAME is required under .github/workflows/: a bare directory mention must
# not become a scope that plans every workflow file at once.
PLAN_EXTRA=$(printf '%s\n' "$PLAN_TOKENS" \
  | grep -xE '(\.github/workflows/[A-Za-z0-9_.-]+|([A-Za-z0-9_.-]+/)*(package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|requirements\.txt|pyproject\.toml|Cargo\.toml|Cargo\.lock|go\.mod|go\.sum|Gemfile\.lock|Gemfile)|([A-Za-z0-9_.-]+/)*\.env(\.[A-Za-z0-9_-]+)?)' \
  | sort -u)

# ...and the two protected families that planned-files.txt DOES carry, because
# bin/planned-files.sh scrapes every prisma/*.prisma and scripts/migrations/*
# token regardless of the sentence it sits in. Without this the non-goal read
# above is closed for manifests, workflows and env files but still open for
# prisma/ and scripts/migrations/: "Do not touch prisma/schema.prisma" would
# score a schema change as PLANNED, in-scope. So an entry in one of those two
# families survives only if the positive text names it too. Only these two
# families are filtered — bin/planned-files.sh itself stays untouched, because
# bin/conflict-check.sh defers overlapping builds on that same list.
PLAN_POS=$(printf '%s\n' "$PLAN_TOKENS" \
  | grep -xE "(prisma|scripts/migrations|$MIG_ERE)/[A-Za-z0-9_./-]+" | sort -u)
if [ -s "$BUILD/plan.md" ]; then
  PLAN_KEPT=$(awk -v pos="$PLAN_POS" -v migdir="$MIGDIR/" '
    BEGIN { n = split(pos, a, "\n"); for (i = 1; i <= n; i++) if (length(a[i])) keep[a[i]] = 1 }
    /^(prisma|scripts\/migrations)\// || index($0, migdir) == 1 { if ($0 in keep) print; next }
    { print }' "$PLAN_FILES")
else
  PLAN_KEPT=$(cat "$PLAN_FILES")
fi

# A planned migration makes scripts/migrations/ the plan's own territory; a diff
# that writes there when the plan named nothing under it is the surprise. Read
# off the KEPT list, never planned-files.txt itself: a "leave
# scripts/migrations/2026-07-17-x.sql alone" sentence must not hand the builder
# the whole directory.
MIG_PLANNED=0
grep -qE "^(scripts/migrations|$MIG_ERE)/" <<<"$PLAN_KEPT" && MIG_PLANNED=1

# A temp file, never an artifact in the build dir — the build dir is copied into
# the record and this is a derived intermediate, not evidence.
PLAN_ALL=$(mktemp) || PLAN_ALL=""
if [ -n "$PLAN_ALL" ]; then
  { printf '%s\n' "$PLAN_KEPT"; [ -n "$PLAN_EXTRA" ] && printf '%s\n' "$PLAN_EXTRA"; } > "$PLAN_ALL"
else
  PLAN_ALL="$PLAN_FILES"   # degrade to the narrow list rather than not run
fi

REPORT=$(printf '%s\n' "$CHANGED" | awk -v maxlist="$MAXLIST" -v migplanned="$MIG_PLANNED" -v migdir="$MIGDIR/" '
  function dirof(p,   d) { d = p; if (sub(/\/[^\/]*$/, "", d)) return d; return "." }
  # ---- pass 1: the plan. Entries are file paths AND directory scopes. ----
  NR==FNR {
    if (!length($0)) next
    plan[$0] = 1
    if ($0 ~ /\/[^\/]*\.[^\/]+$/) pdir[dirof($0)] = 1; else pdir[$0] = 1
    next
  }
  !length($0) { next }
  # The spec artifact is the PIPELINE own commit, not the builder reaching
  # outside its plan (same exclusion bin/evidence-summary.sh makes).
  index($0, ".harness/specs/") == 1 { next }
  {
    changed++
    if ($0 in plan) { planned++; next }
    for (p in plan) if (index($0, p "/") == 1) { planned++; next }
    unplanned++
    prot = 0
    if ($0 ~ /^\.github\/workflows\//) prot = 1
    # A manifest UNDER a test or fixture directory is a fixture, not the
    # dependency set of the build: tests/fixtures/package.json installs nothing and
    # demoting a build for adding one would fire the gate on the discipline it
    # is meant to reward. Only the manifest family is excused there — a workflow,
    # a root-anchored prisma/ path and an env file stay protected wherever they
    # sit, because those are dangerous no matter which directory holds them.
    else if ($0 ~ /(^|\/)(package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|requirements\.txt|pyproject\.toml|Cargo\.toml|Cargo\.lock|go\.mod|go\.sum|Gemfile|Gemfile\.lock)$/ \
             && $0 !~ /(^|\/)(tests?|__tests__|e2e|fixtures)\//) prot = 1
    else if ($0 ~ /^prisma\//) prot = 1
    # Anchored: `.env`, `.env.production`, `src/.env` — but NOT `.envrc`,
    # `.env-loader.js` or `.environment.ts`, which are code, not secrets.
    else if ($0 ~ /(^|\/)\.env(\.[A-Za-z0-9_-]+)?$/) prot = 1
    else if (migplanned == 0 && ($0 ~ /^scripts\/migrations\// || index($0, migdir) == 1)) prot = 1
    if (prot) { protected++; foreign++; cls = "protected"
                if (nprot < maxlist) { nprot++; protlist = protlist (protlist ? " " : "") $0 } }
    else if ($0 ~ /(^|\/)(tests?|__tests__|e2e|spec|specs)\// || $0 ~ /(^|\/)[^\/]*[._-](test|spec)\.[A-Za-z0-9]+$/ || $0 ~ /(^|\/)test_[^\/]*\.py$/) { test++; cls = "test" }
    else if ($0 ~ /\.(md|mdx|rst|txt)$/ || $0 ~ /^(docs|\.agents)\// || $0 ~ /(^|\/)(README|CHANGELOG|LICENSE)/) { spec++; cls = "spec" }
    else if (dirof($0) in pdir) { adjacent++; cls = "adjacent" }
    else { foreign++; cls = "foreign" }
    if (nlist < maxlist) { nlist++; lines = lines sprintf("  [%s] %s\n", cls, $0) }
  }
  END {
    # Everything the diff carried was the pipeline own spec commit, which this
    # skips. The builder changed nothing this gate can judge, and that is the
    # same answer as an empty diff — rc 3, never "the diff stayed in scope".
    if (changed+0 == 0) {
      print "GATE_UNAVAILABLE the diff carries nothing but the pipeline own spec artifact — no builder file to classify"
      printf "%s\t%s\n", "SCOPE_RC_HINT", 3
      exit
    }
    printf "SCOPE_COUNTS: changed=%d planned=%d unplanned=%d adjacent=%d test=%d spec=%d foreign=%d protected=%d\n",
      changed+0, planned+0, unplanned+0, adjacent+0, test+0, spec+0, foreign+0, protected+0
    if (unplanned+0 > 0) {
      printf "UNPLANNED FILES (foreign includes the protected ones):\n%s", lines
      if (unplanned+0 > nlist) printf "  ... and %d more\n", unplanned - nlist
    }
    if (protected+0 > 0) printf "SCOPE_PROTECTED: %s%s\n", protlist, (protected > nprot ? " ..." : "")
    printf "%s\t%s\n", "SCOPE_RC_HINT", (protected+0 > 0 ? 1 : (unplanned+0 > 0 ? 2 : 0))
  }
' "$PLAN_ALL" - 2>/dev/null)
[ "$PLAN_ALL" = "$PLAN_FILES" ] || rm -f "$PLAN_ALL"

[ -n "$REPORT" ] || { echo "GATE_UNAVAILABLE the classifier produced no report"; echo "SCOPE_VERDICT: unavailable"; exit 3; }
RC=$(printf '%s\n' "$REPORT" | sed -n 's/^SCOPE_RC_HINT\t//p' | tail -1)
case "$RC" in
  0|1|2) ;;
  # The classifier said so itself and printed its own reason; don't overwrite it.
  3) printf '%s\n' "$REPORT" | grep -v '^SCOPE_RC_HINT'
     echo "SCOPE_VERDICT: unavailable"; exit 3 ;;
  *) printf '%s\n' "$REPORT" | grep -v '^SCOPE_RC_HINT'
     echo "GATE_UNAVAILABLE the classifier reached no verdict"; echo "SCOPE_VERDICT: unavailable"; exit 3 ;;
esac

printf '%s\n' "$REPORT" | grep -v '^SCOPE_RC_HINT'
case "$RC" in
  0) echo "SCOPE_VERDICT: in-scope" ;;
  1) echo "SCOPE_VERDICT: protected" ;;
  2) echo "SCOPE_VERDICT: unplanned" ;;
esac
exit "$RC"
