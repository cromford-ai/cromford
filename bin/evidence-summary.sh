#!/bin/bash
# bin/evidence-summary.sh — the deterministic evidence block for one build.
#
# usage: evidence-summary.sh [--json] <build-dir> [tier] [why-note] [tier-state]
#        --json      the same facts as one compact JSON object (for the ledger
#                    row), carrying a `digest` field: the one-line summary used
#                    as the artifact ref.
#        tier-state  `settled` (default) or `provisional`. The PR body is
#                    rendered once BEFORE QA and the tier demoters run, and a
#                    row headed "settled tier" at that point would be a claim
#                    the pipeline has not earned yet.
#
# WHY (SDLC item 2, 2026-09-06). The PR body's whole verification section read
# "validate.txt (4812B), red.txt (212B)" — a byte count, from files nobody
# reading the PR page can open. the operator merges tier-2 PRs from that page, so the
# harness was asking a human to take its word for the checks it ran, which is
# exactly the claim-discipline rule the harness enforces on every agent it runs.
# This renders what ACTUALLY ran: the suite's own exit code, each mechanical
# gate's verdict, the QA counts (screens claimed, screenshots on disk), the
# declared INTENT line, which fix rounds fired, planned-vs-changed files, and
# the tier the build settled at with the reason it settled there.
#
# NO MODEL CALL, NO NETWORK, NO REPO ACCESS. Every fact comes from a file the
# pipeline already wrote into the build dir, so this is re-runnable months later
# against an archived record and returns the same block.
#
# NEVER EXECUTE AGENT TEXT. qa.md, intent-gate.txt and validate.txt are written
# by models steered by client-authored ticket text. Everything here is grep,
# awk, sed and printf '%s' — no eval, no sourcing of the build dir, no command
# substitution on file content. Extracted text is stripped of control chars and
# pipes (a stray `|` would split the markdown table row) and length-bounded.
#
# Inputs, all optional — an absent file is reported as "not recorded", never as
# a pass:
#   gates.json          the mechanical gates' own verdicts, written by
#                       bin/run-build.sh at PR time (tamper/repro/intent rc,
#                       e2e word, migration state)
#   test-tamper.txt, repro-gate.txt   those two gates' own output, read only to
#                       tell a gate that reached its verdict from one that
#                       crashed — the two share exit code 1
#   harness-suite.txt   the repo suite the HARNESS ran (HARNESS_EXIT line)
#   harness-suite-fix.txt   the same suite re-run after the merged lens fix round
#   harness-suite-head.txt  the same suite re-run on a moved head (item 1)
#                       The newest of the three that carries `HARNESS_EXIT: 0`,
#                       a 40-hex `HARNESS_HEAD:` and the gate's `ran X of N
#                       ... passed` line adds one `<!-- builder-gate: head=<sha>
#                       green=<X> -->` line after the table (BH-6968)
#   intent-gate.txt     INTENT_VERDICT + the declared INTENT line
#   qa.md, qa-shots/    the preview QA verdict, its counts, its files on disk
#   red.txt, validate.txt   the test evidence the review stage reads
#   evidence.json       the acceptance-claim scorer's verdicts (the contract in
#                       bin/lib/evidence.sh, #527) — read here, never sourced
#   planned-files.txt, changed-files.txt   the plan's file set vs the diff's
#                       (run-build.sh refreshes changed-files.txt at the settle
#                       render, so a fix round's commits are in the count)
#   size-gate.txt       the plan's own size declaration and the limits it was
#                       judged against, compared here with the product files the
#                       diff actually carries (SIZE_DECLARATION_EXCEEDED — a
#                       warning, never a block; BH-612)
#   egress-state.txt, egress.log   the egress allowlist's per-call state lines
#                       and its refusals (bin/lib/egress.sh, BH-4492); the
#                       `egress allowlist` row prints only when the state file
#                       exists
#   RESULT              the terminal, when the build already reached one. In the
#                       pipeline both renders happen BEFORE the build writes
#                       RESULT, so the row appears only when an operator (or the
#                       console) re-renders a finished record; the terminal a PR
#                       closes is named in the board comment, per the SOPs.
#
# Env: EVIDENCE_MAX_UNPLANNED (default 8) — how many unplanned paths are named
# before the list says "+N more". Counts are never truncated, only the listing.
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && { JSON=1; shift; }
BUILD="${1:-}"; TIER="${2:-}"; WHY="${3:-}"; TSTATE="${4:-settled}"
case "$TSTATE" in settled|provisional) ;; *) TSTATE=settled ;; esac
[ -n "$BUILD" ] && [ -d "$BUILD" ] || {
  echo "usage: evidence-summary.sh [--json] <build-dir> [tier] [why-note] [tier-state]" >&2; exit 2; }
MAX_UNPLANNED="${EVIDENCE_MAX_UNPLANNED:-8}"
case "$MAX_UNPLANNED" in ''|*[!0-9]*) MAX_UNPLANNED=8 ;; esac

# One line, table-safe, bounded. `|` becomes `/` because a pipe inside a cell
# splits the row; control characters are dropped outright.
clean() { # clean <max-chars> <string>
  local n="$1" s="$2"
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037' | tr '\n\r\t|`' "   /'")
  # n is the BOUND, so the ellipsis has to fit inside it, not be appended past
  # it: a 512-char digest that renders 513 chars is a bound that is not one.
  [ "${#s}" -le "$n" ] || s="${s:0:$((n-1))}…"
  printf '%s' "$s"
}

gate() { # gate <key> — one value out of gates.json, "" when absent
  [ -s "$BUILD/gates.json" ] || return 0
  jq -r --arg k "$1" '.[$k] // "" | tostring' "$BUILD/gates.json" 2>/dev/null
}

# --- the repo's own suite, run BY the harness ---------------------------------
suite_of() { # suite_of <file>
  local f="$BUILD/$1" v
  [ -s "$f" ] || { printf 'not-recorded'; return 0; }
  v=$(grep -a '^HARNESS_EXIT:' "$f" 2>/dev/null | tail -1 | sed 's/^HARNESS_EXIT:[[:space:]]*//')
  [ -n "$v" ] || v="no HARNESS_EXIT line"
  clean 40 "$v"
}
SUITE=$(suite_of harness-suite.txt)
# Which build prelude ran before that suite (BH-1955): the last
# HARNESS_PRELUDE line, or nothing at all on a record written before it
# existed, so an older record renders byte-identically.
prelude_of() { # prelude_of <file>
  local v
  v=$(grep -a '^HARNESS_PRELUDE:' "$BUILD/$1" 2>/dev/null | tail -1 | sed 's/^HARNESS_PRELUDE:[[:space:]]*//')
  [ -n "$v" ] && clean 60 "$v"
  return 0
}
PRELUDE=$(prelude_of harness-suite.txt)
# The suite as it stood on the head that is actually going to merge, when one of
# the two later runs happened. `harness-suite.txt` is the run the LENSES read,
# and a fix round after it makes that number stale — printing only it on a PR a
# human merges is a claim about a tree that no longer exists. The head-bound
# gate's re-run wins where both exist: it is the later of the two by
# construction (the merged lens fix round commits before `review-head` is
# written, the head-bound gate fires on drift after it).
SUITE_HEAD=""
[ -s "$BUILD/harness-suite-fix.txt" ]  && SUITE_HEAD=$(suite_of harness-suite-fix.txt)
[ -s "$BUILD/harness-suite-head.txt" ] && SUITE_HEAD=$(suite_of harness-suite-head.txt)

# --- the mechanical gates -----------------------------------------------------
# The rc -> word mapping is the one in bin/run-build.sh's own case arms, with
# ONE thing the rc alone cannot say: rc=1 out of either gate means "blocked"
# only when the gate REACHED ITS VERDICT, because a crash inside the gate exits
# 1 too. run-build.sh decides that same question by grepping the gate's own
# output (JUSTIFICATION: NONE + a nonzero BLOCKING_COUNT for tamper, GATE FAILED
# for repro) and does NOT block on the crash — it logs "scan_failed — NOT
# blocking" and carries on to open the PR. So an rc=1 that survives to a PR page
# is, by construction, the crash: rendering it as `blocked` would print a verdict
# on a PR that was never blocked, and the block would be citing a gate that fell
# over. The same greps are used here, against the files the gates wrote into the
# build dir, so an archived record renders the same verdict months later.
TAMPER_RC=$(gate tamper); REPRO_RC=$(gate repro); INTENT_RC=$(gate intent)
case "$TAMPER_RC" in
  0)  TAMPER=clean ;;
  1)  if grep -qa 'JUSTIFICATION: NONE' "$BUILD/test-tamper.txt" 2>/dev/null \
         && grep -qaE '^BLOCKING_COUNT: [1-9]' "$BUILD/test-tamper.txt" 2>/dev/null; then
        TAMPER=blocked
      else
        TAMPER='scan-failed(rc=1, no verdict)'
      fi ;;
  2)  TAMPER=justified ;;
  3)  TAMPER=scan-failed ;;
  '') TAMPER=not-recorded ;;
  *)  TAMPER="could-not-run(rc=$(clean 8 "$TAMPER_RC"))" ;;
esac
case "$REPRO_RC" in
  0)  REPRO=proven ;;
  1)  if grep -qa 'GATE FAILED' "$BUILD/repro-gate.txt" 2>/dev/null; then
        REPRO=blocked
      else
        REPRO='could-not-run(rc=1, no verdict)'
      fi ;;
  2)  REPRO=no-new-tests ;;
  3)  REPRO=unavailable ;;
  4)  REPRO=head-red ;;
  '') REPRO=not-recorded ;;
  *)  REPRO="could-not-run(rc=$(clean 8 "$REPRO_RC"))" ;;
esac
# The intent gate prints its own verdict word; prefer it over the rc, and fall
# back to the rc so a build dir with no intent-gate.txt still reports honestly.
INTENT=$(grep -a '^INTENT_VERDICT:' "$BUILD/intent-gate.txt" 2>/dev/null | tail -1 \
          | sed 's/^INTENT_VERDICT:[[:space:]]*//')
if [ -z "$INTENT" ]; then
  case "$INTENT_RC" in
    0)  INTENT=declared ;;
    1)  INTENT=missing ;;
    2)  INTENT=malformed ;;
    4)  INTENT=conflict ;;
    5)  INTENT=none ;;
    '') INTENT=not-recorded ;;
    *)  INTENT="could-not-run(rc=$(clean 8 "$INTENT_RC"))" ;;
  esac
fi
INTENT=$(clean 24 "$INTENT")
# The declared line itself, as the gate already sanitized and bounded it.
# The gate REPORTS EVERY candidate it saw, each tagged with that line's own kind,
# and its verdict is a precedence over them (a declared conflict outranks an
# agree elsewhere in the same file). So `head -1` shows whichever line came
# first, which on a conflict build is usually an unrelated `[agree]` — a row
# reading "conflict — <a line that agrees>". Prefer the candidate carrying the
# kind the verdict is about; `declared` is the gate's verdict word for the
# `agree` kind. Fall back to the first line when the file predates the tags or
# the verdict is not one of the four kinds.
INTENT_KIND="$INTENT"; [ "$INTENT_KIND" = declared ] && INTENT_KIND=agree
INTENT_LINE=""
case "$INTENT_KIND" in
  agree|conflict|none|malformed)
    INTENT_LINE=$(grep -a -m1 -oE "^[[:space:]]*\[$INTENT_KIND\] INTENT: .*" \
                    "$BUILD/intent-gate.txt" 2>/dev/null \
                  | sed 's/^[[:space:]]*\[[a-z]*\][[:space:]]*//') ;;
esac
[ -n "$INTENT_LINE" ] || INTENT_LINE=$(grep -a -o 'INTENT: .*' "$BUILD/intent-gate.txt" 2>/dev/null | head -1)
INTENT_LINE=$(clean 200 "$INTENT_LINE")

E2E=$(gate e2e);           [ -n "$E2E" ] || E2E=not-recorded
MIGRATION=$(gate migration); [ -n "$MIGRATION" ] || MIGRATION=not-recorded
E2E=$(clean 24 "$E2E"); MIGRATION=$(clean 24 "$MIGRATION")
# The migration-shaped files themselves (BH-1355). The word alone said `none` on
# a PR that added prisma/migrations/manual/…sql; naming the files is what tells a
# reviewer WHICH schema rode along. Absent on records written before this ticket,
# which is what `// []` renders as the row it always rendered.
MIG_FILES_TXT=""
[ -s "$BUILD/gates.json" ] \
  && MIG_FILES_TXT=$(jq -r '(.migration_files // []) | join(", ")' "$BUILD/gates.json" 2>/dev/null)
# A Prisma folder rename can carry dozens of paths, so the list is bounded like
# every other extracted string here — and table-safe, because these come from a
# branch name a ticket author chose.
MIG_FILES_TXT=$(clean 400 "$MIG_FILES_TXT")

# --- preview QA: the claim, and the files behind it ---------------------------
# The verdict is the LAST `QA: PASS`/`QA: FAIL` line, NOT the last line of the
# file. The pipeline appends its own sentence AFTER the verdict on exactly the
# builds this block exists for: `QA still failing after fix round — demoted to
# tier 2.` (bin/run-build.sh, the QA fix round) and `GATE: PASS claimed with
# screens=… ` (the empty-pass demoter). Read off tail -1, both of those rendered
# as `skipped` — a QA session that loaded three screens and FAILED twice was
# reported to the PR page and to the ledger as never having run, and the
# empty-pass build contradicted its own tier row.
QA_LAST=$(tail -1 "$BUILD/qa.md" 2>/dev/null)
QA_VERDICT=$(grep -a -E '^QA: (PASS|FAIL)$' "$BUILD/qa.md" 2>/dev/null | tail -1)
case "$QA_VERDICT" in
  "QA: PASS") QA=PASS ;;
  "QA: FAIL") QA=FAIL ;;
  *) if [ -s "$BUILD/qa.md" ]; then QA=skipped; else QA=none; fi ;;
esac
# The appended sentence is itself evidence — it names the demotion — so the row
# says it is there. It stays OUT of the verdict word: qa.verdict is the field
# the outcome metrics group on, and "FAIL (pipeline note appended)" is not a
# verdict anything can count.
QA_APPENDED=false
[ -n "$QA_VERDICT" ] && [ "$QA_LAST" != "$QA_VERDICT" ] && QA_APPENDED=true
# Screens is read with the EXACT expression the QA demoter in bin/run-build.sh
# uses, because the two read the same qa.md and a block rendering "screens=0"
# beside a tier the demoter granted on screens=3 is precisely the disagreement
# this item exists to remove. Requiring all three keys on one line was stricter
# than the demoter: `QA COVERAGE: screens=3` passed the gate and rendered zero.
# Flows is informational, so it is read off the coverage line on its own rather
# than being made to depend on screens being there.
QA_SCREENS=$(grep -a -oE 'QA COVERAGE:[[:space:]]*screens=[0-9]+' "$BUILD/qa.md" 2>/dev/null | tail -1 | grep -oE '[0-9]+$'); QA_SCREENS="${QA_SCREENS:-0}"
QA_FLOWS=$(grep -a -oE 'QA COVERAGE:.*' "$BUILD/qa.md" 2>/dev/null | grep -oE 'flows=[0-9]+' | tail -1 | grep -oE '[0-9]+$'); QA_FLOWS="${QA_FLOWS:-0}"
# Shots are COUNTED ON DISK, never taken from the coverage line: the files are
# the one piece of QA evidence a session cannot assert its way past.
QA_SHOTS=$(find "$BUILD/qa-shots" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

# --- fix rounds: which lenses had to send the code back -----------------------
FIX_ROUNDS=""; FIX_N=0
for R in review:fix-run.txt security:security-fix-run.txt refute:refute-fix-run.txt qa:qa-fix-run.txt; do
  [ -s "$BUILD/${R#*:}" ] || continue
  FIX_N=$((FIX_N + 1))
  FIX_ROUNDS="$FIX_ROUNDS${FIX_ROUNDS:+, }${R%%:*}"
done
[ -n "$FIX_ROUNDS" ] || FIX_ROUNDS=none

# --- test evidence ------------------------------------------------------------
RED_B=$(stat -c %s "$BUILD/red.txt" 2>/dev/null || echo 0)
RED=absent; grep -qs '[^[:space:]]' "$BUILD/red.txt" && RED=present
VAL_B=$(stat -c %s "$BUILD/validate.txt" 2>/dev/null || echo 0)
VAL_NOTRUN=$(grep -a -c 'NOT RUN' "$BUILD/validate.txt" 2>/dev/null || true)
case "$VAL_NOTRUN" in ''|*[!0-9]*) VAL_NOTRUN=0 ;; esac

# --- acceptance claims (the evidence contract, #527) --------------------------
# <build>/evidence.json is the scorer's structured output. This is a READER: jq
# -r only, every cell through clean(), nothing under the build dir sourced or
# evaluated — the claim text came from a model steered by client-authored ticket
# text. THREE STATES, never interchangeable (D11/D13): `recorded` renders one row
# per claim; `none` (total=0) renders "none named in the plan"; `absent` — no
# file, or one whose counts this script cannot read as numbers — renders
# "not recorded" and adds NO digest field and NO JSON key, so a record written
# before the contract existed renders exactly as it did. An unreadable file is
# never reported as zero claims; that is what evidence_counts() in the contract
# prints for the same file.
CL_STATE=absent; CL_C=0; CL_R=0; CL_I=0; CL_T=0; CL_ROWS=""
if [ -s "$BUILD/evidence.json" ]; then
  CL_COUNTS=$(jq -r '[.confirmed,.refuted,.inconclusive,.total]
                     | map(if type == "number" then (floor|tostring) else "" end) | @tsv' \
                "$BUILD/evidence.json" 2>/dev/null)
  IFS=$'\t' read -r CL_C CL_R CL_I CL_T <<<"$CL_COUNTS"
  CL_STATE=recorded
  for CL_N in "$CL_C" "$CL_R" "$CL_I" "$CL_T"; do
    case "$CL_N" in ''|*[!0-9]*) CL_STATE=absent ;; esac
  done
fi
if [ "$CL_STATE" = absent ]; then
  CL_C=0; CL_R=0; CL_I=0; CL_T=0
else
  [ "$CL_T" -gt 0 ] || CL_STATE=none
  # One claim, one line, five fields. Control characters — newlines and tabs
  # included — are flattened to spaces INSIDE jq, so a multi-line claim can never
  # smuggle in a row of its own and \001 is a separator no claim text can carry.
  # It is \001 and not a tab because bash `read` collapses runs of IFS
  # WHITESPACE: with tabs, a claim with an empty artifact shifted its own note
  # left by one cell and rendered the note as the artifact.
  CL_ROWS=$(jq -r '.claims[]? | [(.n|tostring),(.verdict|tostring),(.claim|tostring),
                                 (.artifact|tostring),(.note|tostring)]
                   | map(gsub("[[:cntrl:]]"; " ")) | join("\u0001")' \
              "$BUILD/evidence.json" 2>/dev/null)
fi
CL_DIGEST=""
[ "$CL_STATE" = absent ] || CL_DIGEST=" claims=$CL_C/$CL_R/$CL_I"

# --- planned vs actual --------------------------------------------------------
# planned-files.txt carries file paths AND directory scopes (bin/planned-files.sh),
# so a changed file counts as planned when it is listed or sits under a listed
# directory. The spec artifact is the PIPELINE's own commit, not the builder's
# scope creep, so it never counts as unplanned.
N_PLANNED=$(grep -c . "$BUILD/planned-files.txt" 2>/dev/null || true)
case "$N_PLANNED" in ''|*[!0-9]*) N_PLANNED=0 ;; esac
# An ABSENT changed-files.txt is not a diff of zero files: it is a record whose
# pipeline never wrote one (every build before this renderer existed, and any box
# whose harness sync lags it). The script's own rule is that absence is reported,
# never scored, so the files row says so instead of claiming "0 changed".
N_CHANGED=0; UNPLANNED_LIST=""; N_UNPLANNED=0; FILES_RECORDED=0
if [ -s "$BUILD/changed-files.txt" ]; then
  FILES_RECORDED=1
  N_CHANGED=$(grep -c . "$BUILD/changed-files.txt" 2>/dev/null || true)
  case "$N_CHANGED" in ''|*[!0-9]*) N_CHANGED=0 ;; esac
  # The plan file is read ONLY when it has content. An empty planned-files.txt
  # is a real case (bin/planned-files.sh writes one whenever the plan's task list
  # names no paths — copy, docs, S-size plans), and an absent one is older still.
  # Fed to the awk below, either one made NR==FNR stay true across the SECOND
  # file, loading every changed path into the plan set and printing nothing: a
  # row reading "2 changed, 0 planned, 0 unplanned". With no plan, every changed
  # file is unplanned, which is what the row now says.
  if [ -s "$BUILD/planned-files.txt" ]; then
    UNPLANNED=$(awk '
      FILENAME==ARGV[1] { if (length($0)) plan[$0]=1; next }
      !length($0) { next }
      index($0, ".harness/specs/") == 1 { next }
      {
        if ($0 in plan) next
        for (p in plan) if (index($0, p "/") == 1) next
        print $0
      }' "$BUILD/planned-files.txt" "$BUILD/changed-files.txt" 2>/dev/null)
  else
    UNPLANNED=$(grep -v -e '^$' -e '^\.harness/specs/' "$BUILD/changed-files.txt" 2>/dev/null)
  fi
  N_UNPLANNED=$(grep -c . <<<"$UNPLANNED"); [ -n "$UNPLANNED" ] || N_UNPLANNED=0
  UNPLANNED_LIST=$(head -"$MAX_UNPLANNED" <<<"$UNPLANNED" | tr '\n' ' ')
  UNPLANNED_LIST=$(clean 300 "${UNPLANNED_LIST% }")
  [ "$N_UNPLANNED" -gt "$MAX_UNPLANNED" ] \
    && UNPLANNED_LIST="$UNPLANNED_LIST +$((N_UNPLANNED - MAX_UNPLANNED)) more"
fi

# --- did this build use the plan it had already paid for? ---------------------
# BH-658. $BUILD/preplan-outcome is written by the adopt block on EVERY branch
# (HIT / STALE / MISS / OFF, each with its reason), so the PR page can answer
# "did the pre-plan reach this machine" — the question that was invisible while
# every Fly build silently re-planned. ABSENT FILE, NO ROW: a record written
# before this existed looks exactly as it did, the same posture the size
# declaration takes.
PP_OUTCOME=""; PP_WHY_TXT=""
if [ -s "$BUILD/preplan-outcome" ]; then
  PP_LINE=$(clean 200 "$(head -1 "$BUILD/preplan-outcome" 2>/dev/null)")
  case "$PP_LINE" in
    HIT*|STALE*|MISS*|OFF*)
      PP_OUTCOME="${PP_LINE%% *}"
      PP_WHY_TXT=$(printf '%s' "${PP_LINE#"$PP_OUTCOME"}" | sed 's/^[[:space:]]*//') ;;
  esac
fi

# --- the size declaration vs the diff that actually shipped -------------------
# WHY (BH-612, 2026-09-16). bin/size-gate.sh judges a plan's FILE axis on what
# the plan DECLARES, because the only other list available at plan time
# (planned-files.txt) is a deliberate over-listing of every path the plan
# MENTIONS and decomposed 45-line fixes whose prose named eighteen callers
# (project-5 #1906, #1907). Removing that check needs the honest half put back
# somewhere, and this is the only place reality exists: the declaration against
# the product files the build actually changed.
#
# IT WARNS, IT NEVER BLOCKS. By the time this renders, the code is written and
# the PR is open — refusing it here strands the work on a branch nobody merges,
# which is the same reasoning the post-hoc 2x demoter in run-build.sh follows.
#
# THE LIMIT IS READ, NEVER RECOMPUTED. The tolerated file figure comes off the
# gate's own SIZE_TOLERANCE line (falling back to the nominal SIZE_LIMITS), so
# the row and the gate cannot disagree about one number.
#
# ABSENCE IS NOT "WITHIN". No size-gate.txt, or one whose gate could not read a
# declaration, renders NO row and no JSON field — a record written before this
# existed looks exactly as it did. A declaration with no changed-files.txt reads
# `not recorded`.
SD_VERDICT=""; SD_DECLARED=""; SD_LIMIT=""; SD_SHIPPED=""
if [ -s "$BUILD/size-gate.txt" ]; then
  SD_DECLARED=$(grep -a '^SIZE_DECLARED:' "$BUILD/size-gate.txt" 2>/dev/null | tail -1 \
                 | sed -n 's/^.*files=\([0-9]*\).*$/\1/p')
  case "$SD_DECLARED" in ''|*[!0-9]*) SD_DECLARED="" ;; esac
fi
if [ -n "$SD_DECLARED" ]; then
  SD_LIMIT=$(grep -a '^SIZE_TOLERANCE:' "$BUILD/size-gate.txt" 2>/dev/null | tail -1 \
              | sed -n 's/^.*files<=\([0-9]*\).*$/\1/p')
  case "$SD_LIMIT" in ''|*[!0-9]*) SD_LIMIT="" ;; esac
  if [ -z "$SD_LIMIT" ]; then
    SD_LIMIT=$(grep -a '^SIZE_LIMITS:' "$BUILD/size-gate.txt" 2>/dev/null | tail -1 \
                | sed -n 's/^.*files=\([0-9]*\).*$/\1/p')
    case "$SD_LIMIT" in ''|*[!0-9]*) SD_LIMIT="" ;; esac
  fi
fi
if [ -n "$SD_DECLARED" ] && [ -n "$SD_LIMIT" ]; then
  # Product files only, through the ONE definition of product code the gate
  # measured the plan with. Pure string work on a list this build already wrote,
  # so the block keeps its no-repo-access promise. (.harness/specs/ is already
  # in size-scope's exclusion list, so the pipeline's own spec commit never
  # counts as scope creep here either.)
  SCOPE_BIN="$(dirname "$0")/size-scope.sh"
  if [ "$FILES_RECORDED" = 1 ] && [ -x "$SCOPE_BIN" ]; then
    SD_SHIPPED=$("$SCOPE_BIN" --filter < "$BUILD/changed-files.txt" 2>/dev/null | grep -c . || true)
    case "$SD_SHIPPED" in ''|*[!0-9]*) SD_SHIPPED="" ;; esac
  fi
  if [ -z "$SD_SHIPPED" ]; then
    SD_VERDICT=not-recorded
  elif [ "$SD_DECLARED" -le "$SD_LIMIT" ] && [ "$SD_SHIPPED" -gt "$SD_LIMIT" ]; then
    # The plan said it fits and the diff does not. The reverse (an honest
    # over-declaration that shipped wide) was already split or tolerated by the
    # gate, and reporting it here would flag the planner's honesty as a defect.
    SD_VERDICT=exceeded
  else
    SD_VERDICT=within
  fi
fi

# --- review depth: which tier the lenses were bought at (BH-485) --------------
# review-tier.txt is one line, written by the lens stage before any lens
# launched: `REVIEW-TIER T0 reason=… lenses=… cap=N`. ABSENCE RENDERS NOTHING —
# an archived record written before this existed looks exactly as it did, and a
# line this cannot parse is reported by its silence, never as a tier it guessed.
RT_TIER=""; RT_REASON=""; RT_LENSES=""; RT_CAP=""
if [ -s "$BUILD/review-tier.txt" ]; then
  RT_RAW=$(grep -a -m1 'REVIEW-TIER T[012] reason=' "$BUILD/review-tier.txt" 2>/dev/null)
  if [ -n "$RT_RAW" ]; then
    RT_TIER=$(printf '%s' "$RT_RAW" | grep -oE 'T[012]' | head -1)
    RT_LENSES=$(printf '%s' "$RT_RAW" | grep -oE 'lenses=[a-z,]+' | tail -1 | sed 's/^lenses=//; s/,/, /g')
    RT_CAP=$(printf '%s' "$RT_RAW" | grep -oE 'cap=[0-9]+$' | tail -1 | sed 's/^cap=//')
    # The reason is everything between `reason=` and the trailing lenses/cap
    # fields, anchored at the END so a reason containing the word lenses cannot
    # eat the rest of the row.
    RT_REASON=$(printf '%s' "${RT_RAW#*reason=}" | sed -E 's/ lenses=[a-z,]+ cap=[0-9]+$//')
    RT_REASON=$(clean 200 "$RT_REASON")
  fi
fi

# --- how this build settled ---------------------------------------------------
TIER=$(clean 8 "$TIER"); [ -n "$TIER" ] || TIER=unsettled
WHY=$(clean 400 "$WHY")
# Every demoter in run-build.sh builds its note as " | QA: …" so the notes
# concatenate; passed straight through, the row would open on a separator that
# clean() has already turned into a stray slash.
WHY="${WHY#"${WHY%%[![:space:]/]*}"}"
RESULT_TERM=$(head -1 "$BUILD/RESULT" 2>/dev/null | grep -oE '^[A-Z_]+' || true)
RECORD=$(basename "$BUILD")

CHANGED_D="$N_CHANGED"; UNPLANNED_D="$N_UNPLANNED"; CHANGED_J="${N_CHANGED:-0}"; UNPLANNED_J="${N_UNPLANNED:-0}"
[ "$FILES_RECORDED" = 1 ] || { CHANGED_D=not-recorded; UNPLANNED_D=not-recorded; CHANGED_J=null; UNPLANNED_J=null; }
DIGEST=$(printf 'suite=%s tamper=%s repro=%s intent=%s e2e=%s migration=%s qa=%s(screens=%s shots=%s) fixes=%s files=%s/%s unplanned=%s red=%s tier=%s%s' \
  "$SUITE" "$TAMPER" "$REPRO" "$INTENT" "$E2E" "$MIGRATION" "$QA" "$QA_SCREENS" "$QA_SHOTS" \
  "$FIX_N" "$CHANGED_D" "$N_PLANNED" "$UNPLANNED_D" "$RED" "$TIER" "$CL_DIGEST")
DIGEST=$(clean 512 "$DIGEST")

if [ "$JSON" = 1 ]; then
  jq -nc \
    --arg record "$RECORD" --arg suite "$SUITE" --arg suite_head "$SUITE_HEAD" \
    --arg tamper "$TAMPER" --arg repro "$REPRO" --arg intent "$INTENT" \
    --arg intent_line "$INTENT_LINE" --arg e2e "$E2E" --arg migration "$MIGRATION" \
    --arg migration_files "$MIG_FILES_TXT" \
    --arg qa "$QA" --argjson screens "${QA_SCREENS:-0}" --argjson flows "${QA_FLOWS:-0}" \
    --argjson shots "${QA_SHOTS:-0}" --argjson qa_appended "$QA_APPENDED" \
    --argjson fixes "$FIX_N" --arg fix_rounds "$FIX_ROUNDS" \
    --arg red "$RED" --argjson red_bytes "${RED_B:-0}" --argjson validate_bytes "${VAL_B:-0}" \
    --argjson validate_not_run "${VAL_NOTRUN:-0}" \
    --argjson planned "${N_PLANNED:-0}" --argjson changed "$CHANGED_J" \
    --argjson unplanned "$UNPLANNED_J" --arg unplanned_files "$UNPLANNED_LIST" \
    --arg tier "$TIER" --arg tier_state "$TSTATE" --arg why "$WHY" \
    --arg result "$RESULT_TERM" --arg digest "$DIGEST" \
    --arg sd_verdict "$SD_VERDICT" --argjson sd_declared "${SD_DECLARED:-null}" \
    --argjson sd_shipped "${SD_SHIPPED:-null}" --argjson sd_limit "${SD_LIMIT:-null}" \
    --arg cl_state "$CL_STATE" --argjson cl_c "$CL_C" --argjson cl_r "$CL_R" \
    --argjson cl_i "$CL_I" --argjson cl_t "$CL_T" \
    --arg pp_outcome "$PP_OUTCOME" --arg pp_why "$PP_WHY_TXT" \
    '{record:$record,suite:$suite,tamper:$tamper,repro:$repro,intent:$intent,
      e2e:$e2e,migration:$migration,
      qa:{verdict:$qa,screens:$screens,flows:$flows,shots:$shots,note_appended:$qa_appended},
      fixes:$fixes,fix_rounds:$fix_rounds,
      red:$red,red_bytes:$red_bytes,validate_bytes:$validate_bytes,
      validate_not_run:$validate_not_run,
      files:{planned:$planned,changed:$changed,unplanned:$unplanned},
      tier:$tier,tier_state:$tier_state,digest:$digest}
     + (if $suite_head == "" then {} else {suite_head:$suite_head} end)
     + (if $intent_line == "" then {} else {intent_line:$intent_line} end)
     + (if $unplanned_files == "" then {} else {unplanned_files:$unplanned_files} end)
     + (if $migration_files == "" then {} else {migration_files:$migration_files} end)
     + (if $why == "" then {} else {why:$why} end)
     + (if $result == "" then {} else {result:$result} end)
     + (if $cl_state == "absent" then {} else
          {claims:{confirmed:$cl_c,refuted:$cl_r,inconclusive:$cl_i,total:$cl_t}} end)
     + (if $sd_verdict == "" then {} else
          {size_declaration:{verdict:$sd_verdict,declared_files:$sd_declared,
                             shipped_files:$sd_shipped,limit_files:$sd_limit}} end)
     + (if $pp_outcome == "" then {} else
          {preplan:{outcome:$pp_outcome,why:$pp_why}} end)' 2>/dev/null
  exit 0
fi

# --- the block a human reads on the PR page -----------------------------------
printf '## Evidence\n\n'
printf 'Deterministic — no model wrote this block. Every row is a file this build already produced, on the build box at `%s`.\n\n' "$RECORD"
printf '| check | result |\n|---|---|\n'
printf '| repo suite, run by the harness | `HARNESS_EXIT: %s` |\n' "$SUITE"
[ -n "$PRELUDE" ] && printf '| repo suite prelude, run by the harness | `%s` |\n' "$PRELUDE"
[ -n "$SUITE_HEAD" ] && printf '| repo suite, re-run on the settled head | `HARNESS_EXIT: %s` |\n' "$SUITE_HEAD"
# The rules pack (BH-3513): the late pre-PR pass's summary, else the first
# pass's, else HARNESS_SUITE_RUN's. No summary.json, no row. The state is the
# pre-PR gate's own `pack=` verdict when it recorded one (it includes the fix
# turn), else the pack's. jq and grep only; every value through clean().
RP_SUM=""
for RP_F in "$BUILD/prepr-late/rules-pack/summary.json" "$BUILD/rules-pack/summary.json" "$BUILD/rules-pack-lenses/summary.json"; do
  [ -r "$RP_F" ] && { RP_SUM="$RP_F"; break; }
done
if [ -n "$RP_SUM" ]; then
  RP_STATE=$(sed -n 's/^pack=//p' "$BUILD/prepr-late/prepr.txt" 2>/dev/null | head -1)
  [ -n "$RP_STATE" ] || RP_STATE=$(sed -n 's/^pack=//p' "$BUILD/prepr.txt" 2>/dev/null | head -1)
  [ -n "$RP_STATE" ] || RP_STATE=$(jq -r '.state // "?"' "$RP_SUM" 2>/dev/null)
  RP_N=$(jq -r '.components | length' "$RP_SUM" 2>/dev/null)
  RP_E=$(jq -r '.elapsed_s' "$RP_SUM" 2>/dev/null)
  RP_B=$(jq -r '.budget_s' "$RP_SUM" 2>/dev/null)
  for RP_V in RP_N RP_E RP_B; do
    case "${!RP_V}" in ''|*[!0-9]*) printf -v "$RP_V" '%s' '?' ;; esac
  done
  RP_TAIL=""
  [ "$(jq -r '.over_budget == true' "$RP_SUM" 2>/dev/null)" = true ] && RP_TAIL=", over budget"
  RP_CNR=$(jq -r '(.could_not_run // []) | join(", ")' "$RP_SUM" 2>/dev/null)
  [ -n "$RP_CNR" ] && RP_TAIL="$RP_TAIL; could not run: $RP_CNR"
  RP_PRE=$(grep -c . "$(dirname "$RP_SUM")/preexisting.txt" 2>/dev/null)
  [ "${RP_PRE:-0}" -gt 0 ] 2>/dev/null && RP_TAIL="$RP_TAIL; pre-existing: $RP_PRE"
  printf '| rules pack (bin/rules-pack.sh) | %s |\n' \
    "$(clean 240 "$(clean 20 "$RP_STATE") — $RP_N components, ${RP_E}s of ${RP_B}s budget$RP_TAIL")"
fi
printf '| test-tamper gate | %s |\n' "$TAMPER"
printf '| reproduction gate | %s |\n' "$REPRO"
if [ -n "$INTENT_LINE" ]; then
  printf '| intent gate | %s — `%s` |\n' "$INTENT" "$INTENT_LINE"
else
  printf '| intent gate | %s |\n' "$INTENT"
fi
printf '| e2e smoke | %s |\n' "$E2E"
if [ -n "$MIG_FILES_TXT" ]; then
  printf '| migration gate | %s — %s |\n' "$MIGRATION" "$MIG_FILES_TXT"
else
  printf '| migration gate | %s |\n' "$MIGRATION"
fi
QA_APPENDED_TXT=""
[ "$QA_APPENDED" = true ] && QA_APPENDED_TXT=", pipeline note appended after the verdict"
# A skip says WHY on the page (BH-3438): the fail-open line carries the reason
# wait-preview.sh gave, and "skipped — screens=0" alone told nobody what to fix.
if [ "$QA" = skipped ]; then
  QA_SKIP_WHY=$(grep -a -m1 '^preview unavailable' "$BUILD/qa.md" 2>/dev/null)
  [ -n "$QA_SKIP_WHY" ] && QA_APPENDED_TXT="$QA_APPENDED_TXT ($(clean 160 "$QA_SKIP_WHY"))"
fi
printf '| preview QA | %s — screens=%s flows=%s claimed, %s screenshot(s) on disk%s |\n' \
  "$QA" "$QA_SCREENS" "$QA_FLOWS" "$QA_SHOTS" "$QA_APPENDED_TXT"
printf '| fix rounds | %s (%s) |\n' "$FIX_N" "$FIX_ROUNDS"
printf '| red-before-green proof | %s (red.txt %sB) |\n' "$RED" "$RED_B"
printf '| plan VALIDATE checks | validate.txt %sB, %s recorded as NOT RUN |\n' "$VAL_B" "$VAL_NOTRUN"
case "$CL_STATE" in
  absent) printf '| acceptance claims | not recorded |\n' ;;
  none)   printf '| acceptance claims | none named in the plan |\n' ;;
  recorded)
    while IFS=$'\001' read -r CL_ROW_N CL_ROW_V CL_ROW_C CL_ROW_A CL_ROW_NOTE; do
      [ -n "$CL_ROW_N$CL_ROW_V$CL_ROW_C" ] || continue
      CL_ROW_A=$(clean 120 "$CL_ROW_A");   [ -n "$CL_ROW_A" ] || CL_ROW_A='(none)'
      CL_ROW_NOTE=$(clean 80 "$CL_ROW_NOTE"); [ -n "$CL_ROW_NOTE" ] || CL_ROW_NOTE='(none)'
      printf '| claim %s: %s | %s — %s — %s |\n' \
        "$(clean 8 "$CL_ROW_N")" "$(clean 70 "$CL_ROW_C")" "$(clean 24 "$CL_ROW_V")" \
        "$CL_ROW_A" "$CL_ROW_NOTE"
    done <<<"$CL_ROWS" ;;
esac
if [ "$FILES_RECORDED" != 1 ]; then
  printf '| files | not recorded (%s planned) |\n' "$N_PLANNED"
elif [ -n "$UNPLANNED_LIST" ]; then
  printf '| files | %s changed, %s planned, %s unplanned: `%s` |\n' \
    "$N_CHANGED" "$N_PLANNED" "$N_UNPLANNED" "$UNPLANNED_LIST"
else
  printf '| files | %s changed, %s planned, %s unplanned |\n' "$N_CHANGED" "$N_PLANNED" "$N_UNPLANNED"
fi
if [ -n "$PP_OUTCOME" ]; then
  if [ -n "$PP_WHY_TXT" ]; then
    printf '| pre-plan | %s — %s |\n' "$PP_OUTCOME" "$PP_WHY_TXT"
  else
    printf '| pre-plan | %s |\n' "$PP_OUTCOME"
  fi
fi
case "$SD_VERDICT" in
  exceeded)
    printf '| size declaration | SIZE_DECLARATION_EXCEEDED — declared files=%s, shipped %s product file(s), tolerated limit %s (warn, not a block) |\n' \
      "$SD_DECLARED" "$SD_SHIPPED" "$SD_LIMIT" ;;
  within)
    printf '| size declaration | within — declared files=%s, shipped %s product file(s), tolerated limit %s |\n' \
      "$SD_DECLARED" "$SD_SHIPPED" "$SD_LIMIT" ;;
  not-recorded)
    printf '| size declaration | not recorded (declared files=%s) |\n' "$SD_DECLARED" ;;
esac
if [ -n "$RT_TIER" ]; then
  RT_CAP_TXT="uncapped"
  [ -n "$RT_CAP" ] && [ "$RT_CAP" != 0 ] && RT_CAP_TXT="$RT_CAP"
  printf '| review depth | %s — %s (lenses: %s, fix-round cap %s) |\n' \
    "$RT_TIER" "$RT_REASON" "${RT_LENSES:-not recorded}" "$RT_CAP_TXT"
fi
# --- egress allowlist (BH-4492) -------------------------------------------------
# egress-state.txt is one line per stage call, written by bin/lib/egress.sh;
# egress.log holds the proxy's refusals. ABSENCE RENDERS NOTHING. A stage the
# box could not fence is printed in capitals: it ran with open network.
if [ -s "$BUILD/egress-state.txt" ]; then
  EG_STAGES=$(awk '
    { st=""; s=""; src=""; why=""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^stage=/)  st  = substr($i, 7)
        if ($i ~ /^state=/)  s   = substr($i, 7)
        if ($i ~ /^source=/) src = substr($i, 8)
        if ($i ~ /^reason=/) why = substr($i, 8)
      }
      if (st == "" || s == "") next
      if (s == "enforced")          l = (src == "row" ? "enforced" : "enforced (" src ")")
      else if (s == "not-enforced") l = "NOT ENFORCED (" why ")"
      else                          l = "not armed (" why ")"
      if (!(st in seen)) { seen[st] = 1; order[++n] = st }
      if (!((st SUBSEP l) in had)) { had[st SUBSEP l] = 1; lab[st] = (lab[st] == "" ? l : lab[st] " / " l) }
    }
    END { for (i = 1; i <= n; i++) printf "%s%s: %s", (i > 1 ? "; " : ""), order[i], lab[order[i]] }' \
    "$BUILD/egress-state.txt" 2>/dev/null)
  EG_N=$(awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^(deny|direct)=[0-9]+$/) { split($i, kv, "="); t += kv[2] } }
              END { print t + 0 }' "$BUILD/egress-state.txt" 2>/dev/null)
  EG_LIST=""; EG_SHOWN=0; EG_MORE=0
  while IFS=' ' read -r EG_T EG_S; do
    [ -n "$EG_T" ] || continue
    if [ "$EG_SHOWN" -lt 10 ]; then
      EG_LIST="${EG_LIST:+$EG_LIST, }\`$(clean 80 "$EG_T")\` ($(clean 40 "$EG_S"))"
      EG_SHOWN=$((EG_SHOWN + 1))
    else
      EG_MORE=$((EG_MORE + 1))
    fi
  done < <(awk '($3 == "DENY" || $3 == "DENY-DIRECT") && $2 ~ /^stage=/ {
                  k = $4 " " substr($2, 7); if (!(k in seen)) { seen[k] = 1; print k } }' "$BUILD/egress.log" 2>/dev/null)
  [ "$EG_MORE" -gt 0 ] && EG_LIST="$EG_LIST +$EG_MORE more"
  printf '| egress allowlist | %s — %s refused%s |\n' \
    "$(clean 400 "${EG_STAGES:-no parsable state line}")" "${EG_N:-0}" "${EG_LIST:+: $EG_LIST}"
fi
TIER_LABEL="settled tier"
[ "$TSTATE" = provisional ] && TIER_LABEL="tier so far (not settled)"
if [ -n "$WHY" ]; then
  printf '| %s | %s — %s |\n' "$TIER_LABEL" "$TIER" "$WHY"
else
  printf '| %s | %s — no demotion recorded |\n' "$TIER_LABEL" "$TIER"
fi
[ -n "$RESULT_TERM" ] && printf '| RESULT | `%s` |\n' "$RESULT_TERM"
# The builder gate's head-bound count (BH-6968), for rule 2c of
# bin/lib/risk-tier.sh: only from the newest suite file, only when that run
# exited 0 on a clean head and printed its `ran X of N` line. X counts only the
# suites run on this head; ledger reuses are not in it.
for BG_F in harness-suite-head.txt harness-suite-fix.txt harness-suite.txt; do
  [ -s "$BUILD/$BG_F" ] && break
done
BG_HEAD=$(grep -a '^HARNESS_HEAD:' "$BUILD/$BG_F" 2>/dev/null | tail -1 | sed 's/^HARNESS_HEAD:[[:space:]]*//')
BG_N=$(grep -a '^impact-gate: ran [0-9]* of [0-9]* selected suites via [^ ]*: passed' "$BUILD/$BG_F" 2>/dev/null | tail -1 | sed 's/^impact-gate: ran \([0-9]*\) .*/\1/')
if [[ "$BG_HEAD" =~ ^[0-9a-f]{40}$ ]] && [ -n "$BG_N" ] \
   && [ "$(grep -a '^HARNESS_EXIT:' "$BUILD/$BG_F" 2>/dev/null | tail -1 | sed 's/^HARNESS_EXIT:[[:space:]]*//')" = 0 ]; then
  printf '\n<!-- builder-gate: head=%s green=%s -->\n' "$(clean 40 "$BG_HEAD")" "$(clean 10 "$BG_N")"
fi

# --- QA flows per persona -----------------------------------------------------
# The two persona lanes print the same row shape into different files: the
# preview lane into e2e.md, the production lane into qa-prod.md. Rendered side
# by side with a source column, because "the dashboard loaded" means something
# different on a preview of this diff than it does against production, and a
# table that blurred the two would be read as twice the evidence.
#
# Cells go through clean() like every other cell here: these rows carry reasons
# written by a model that was steered by client ticket text, and one `|` in a
# reason would split the row. Nothing is eval'd, nothing is sourced.
FLOW_ROWS=$( { grep -a '^FLOW ' "$BUILD/e2e.md" 2>/dev/null | awk '{print "preview\t" $0}'
               grep -a '^FLOW ' "$BUILD/qa-prod.md" 2>/dev/null | awk '{print "production\t" $0}'; } )
if [ -n "$FLOW_ROWS" ]; then
  printf '\n## QA flows per persona\n\n'
  printf '| persona | flow | verdict | screenshot | source |\n|---|---|---|---|---|\n'
  while IFS=$'\t' read -r F_SRC F_ROW; do
    [ -n "$F_ROW" ] || continue
    F_PERSONA=$(printf '%s' "$F_ROW" | awk '{print $2}')
    F_FLOW=$(printf '%s' "$F_ROW" | awk '{print $3}')
    F_VERDICT=$(printf '%s' "$F_ROW" | awk '{print $4}')
    F_SHOT=$(printf '%s' "$F_ROW" | grep -oE 'shot=[^ ]+' | head -1 | sed 's/^shot=//')
    [ -n "$F_SHOT" ] || F_SHOT='-'
    # Everything the grammar does not claim for itself is the reason a fail or
    # a blocked row carries — the only part of the row that tells a reviewer
    # anything they could act on.
    F_DETAIL=$(printf '%s' "$F_ROW" | awk '{for (i=5; i<=NF; i++) { if ($i ~ /^steps=/ || $i ~ /^shot=/) continue
                                             printf "%s%s", (n++ ? " " : ""), $i }}')
    F_CELL=$(clean 120 "$F_VERDICT")
    [ -n "$F_DETAIL" ] && F_CELL="$F_CELL — $(clean 120 "$F_DETAIL")"
    printf '| %s | %s | %s | %s | %s |\n' \
      "$(clean 40 "$F_PERSONA")" "$(clean 40 "$F_FLOW")" "$F_CELL" \
      "$(clean 160 "$F_SHOT")" "$F_SRC"
  done <<EOF
$FLOW_ROWS
EOF
fi
printf '\nDigest: `%s`\n' "$DIGEST"
# BH-6485: bin/reference-shots.sh writes this section (preview next to
# reference, or Missing / Could not publish with no images). It is the
# harness's own output, never agent text, so it is printed verbatim.
if [ -f "$BUILD/reference-shots.md" ] && [ -r "$BUILD/reference-shots.md" ]; then
  printf '\n'; cat "$BUILD/reference-shots.md"
fi
exit 0
