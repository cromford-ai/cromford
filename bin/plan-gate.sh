#!/bin/bash
# bin/plan-gate.sh <plan.md>
#
# Does every task in this plan carry its own proof and its own trace?
#
# WHY (SDLC item 5, 2026-09-06). The plan prompt has demanded two lines per task
# since 2026-08-14 — 'VALIDATE: <the exact command that proves this task is
# done>' and 'SATISFIES: <the ticket criterion this task delivers>' — and what
# checked it was `grep -q VALIDATE && grep -q SATISFIES` over the WHOLE FILE.
# One traced task in a ten-task plan passed that check. Then the repair pass
# ran at most once and the build continued into EXECUTE with a logged warning,
# so an untraced plan cost a paid execute session and a paid review before
# anybody read it. TK-143 #517 and the early-engagement incident are both the same family: work
# that reached a reviewer without a written trace back to what the client asked
# for.
#
# WHAT A TASK IS HERE. Plans are markdown written by a model, so the unit is
# recognized rather than declared:
#   - a heading (any level) that is not one of the contract's own sections;
#   - a TOP-LEVEL list item under a heading that is not itself a task (so
#     "## Tasks" + "1. ..." splits into tasks, while "### Task 1" + its own
#     sub-bullets stays ONE task and the bullets are its detail).
# A block is SCORED only if it is labelled a task ("Task 3", "T9", "task:") or
# carries a colon-anchored VALIDATE:/SATISFIES: line. Prose, a file list, an
# edge-case bullet: not scored, because a gate that invents tasks refuses good
# plans, and this one refuses.
#
# AND THE WHOLE-FILE FLOOR LIVES HERE TOO, because there must be exactly one
# definition of what a trace line looks like. The old floor in run-build.sh was
# `grep '^[[:space:]]*VALIDATE:'`, which does not match `- VALIDATE:` — the
# bullet form 27 of the last 150 plans actually use. It fired a repair session
# on every one of them, and as a REFUSAL it would have blocked them all.
#
# DELIBERATELY FORGIVING, in five places, measured against every plan on this
# box (637 of them: zero would be refused since the contract shipped on
# 2026-08-14, and every plan that predates it is refused, correctly):
#   - fenced code blocks are skipped whole (a sample command that says VALIDATE:
#     is not the trace of a task);
#   - the contract's own sections (## System invariants, ## Requirements
#     coverage, ## Acceptance tests, ## QA screens) and a ## Verification
#     checklist are skipped whole — none of them is a task, and all of them
#     name the keywords;
#   - a mere MENTION of the keywords never opens a task block, only a
#     colon-anchored line does: "D6: every VALIDATE command runs unpiped" is a
#     discipline note, and 30 historical plans carry one;
#   - once a block IS a task, the bare capitalised word anywhere in it counts as
#     the trace, so "VALIDATE (unpiped, D6): npm test" scores;
#   - a plan whose trace lines exist but whose tasks this parser cannot see is
#     `unavailable` (rc 3), never `untraced`. A gate that cannot run says so.
#
# NO NETWORK, NO REPO ACCESS, NO MODEL CALL — one markdown file in, a verdict
# out, so an operator can re-run it against an archived record and get the same
# answer bin/run-build.sh got.
#
# PLAN_GATE_MAX_LIST (default 8) bounds the UNTRACED listing, never the counts.
#
# SHARED FILES (prompts/plan-contract.md §11). PLAN_GATE_HOTSPOTS=<file> names
# a hotlist, one repo path per line (bin/lib/hotspot-context.sh writes it). A
# hotspot path the plan names outside fences, `## Sibling claims` and
# `## Shared files` must be listed under `## Shared files` on a line that also
# gives a reason. This is a REPORT: it never changes the exit code. Unset, the
# output is exactly the trace report.
#
# OUTCOME REPLAY (prompts/plan-contract.md §16). PLAN_GATE_PERF=1 says the
# ticket is perf/cost; then, or when the plan has a `## Target metric` heading,
# the plan needs a target line and an outcome-replay acceptance item.
#
# prints: PLAN_TASKS / PLAN_UNTRACED / PLAN_TRACE_LINES (the file-wide floor),
#         one "UNTRACED: <label> — <what is missing>" line per offender,
#         with PLAN_GATE_HOTSPOTS: PLAN_SHARED_NAMED, one "SHARED_UNLISTED:
#         <path>" / "SHARED_NOREASON: <path>" line per offender and
#         PLAN_SHARED: ok | unlisted | unread, PLAN_OUTCOME_REPLAY: ok |
#         missing | n/a with one "UNTRACED: outcome replay — <gap>" line per
#         gap, and last
#         PLAN_TRACE: ok | untraced | unavailable
#
# exit 0  every task block carries both lines
# exit 2  the plan is missing one of the lines entirely, or a task block is
#         missing one of them  (the refusal case)
# exit 3  no plan file, or a traced plan whose tasks this parser cannot see
set -uo pipefail
PLAN="${1:-}"
MAXLIST="${PLAN_GATE_MAX_LIST:-8}"
case "$MAXLIST" in ''|*[!0-9]*) MAXLIST=8 ;; esac

[ -n "$PLAN" ] && [ -s "$PLAN" ] || {
  echo "PLAN_GATE_UNAVAILABLE no readable plan at ${PLAN:-<none>}"
  echo "PLAN_TRACE: unavailable"; exit 3; }

REPORT=$(awk -v maxlist="$MAXLIST" '
  function strip(s) {
    gsub(/^[ \t]+/, "", s); sub(/^#+[ \t]*/, "", s)
    sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", s)
    sub(/^\*\*/, "", s); sub(/\*\*[ \t]*$/, "", s)
    gsub(/[ \t]+$/, "", s); return s
  }
  # A task DESIGNATOR: "Task 4", "Task:", "T9". Never "Tasks", which is a
  # section heading whose list items are the tasks, and never "Task creation
  # pattern ..." — project-3 TK-77 opens a codegraph-findings bullet exactly that
  # way, and reading it as a task block demoted a plan for a sentence.
  # The designator has to END the label or be followed by punctuation: project-1
  # TK-232 opens a dependency bullet with "Task 0 below gates the build on the
  # helper ...", which is prose ABOUT a task. "Task 4 — ", "Task 2:", "T9 —"
  # and a bare "Task 3" are labels; "Task 0 below" is a sentence.
  function istask(s,   t) {
    t = tolower(strip(s))
    return (t ~ /^task[ \t]*[:.)-]/ \
         || t ~ /^task[ \t]*[0-9]+[ \t]*([^0-9a-z ]|$)/ \
         || t ~ /^t[0-9]+[ \t]*([^0-9a-z ]|$)/)
  }
  # TWO STRENGTHS, ON PURPOSE, and mixing them up costs a good plan either way.
  #
  # STRICT (a colon-anchored VALIDATE:/SATISFIES:) is the only evidence that
  # makes an unlabelled block a TASK. Every plan carries prose bullets that
  # merely NAME the keywords — "Build-discipline rules that bite: D6, every
  # VALIDATE command runs unpiped" — and 30 historical project-4/project-3/project-2
  # plans turn into untraced tasks the moment a mention is enough to open one.
  #
  # LOOSE (the bare capitalised word anywhere in the block) is what SCORES a
  # block that is already a task. project-4 TK-1040 wrote "VALIDATE (each run
  # unpiped, true exit codes — D6): `npm run ...`", which is a real trace with
  # a parenthetical before its colon.
  function mark(l) {
    if (l ~ /VALIDATE[ \t]*:/)  { strictv = 1; nv++ }
    if (l ~ /SATISFIES[ \t]*:/) { stricts = 1; ns++ }
    if (l ~ /(^|[^A-Za-z])VALIDATE([^A-Za-z]|$)/)  hasv = 1
    if (l ~ /(^|[^A-Za-z])SATISFIES([^A-Za-z]|$)/) hass = 1
  }
  # The file-wide floor counts the trace lines of a skipped section too: the question
  # it answers is "does this plan carry the two contract lines AT ALL", and a plan
  # that put them under ## Acceptance tests carries them.
  function countonly(l) {
    if (l ~ /VALIDATE[ \t]*:/)  nv++
    if (l ~ /SATISFIES[ \t]*:/) ns++
  }
  function flush(   why) {
    if (!open) return
    if (task || strictv || stricts) {
      tasks++
      if (!(hasv && hass)) {
        untraced++
        why = (!hasv && !hass) ? "no VALIDATE and no SATISFIES" : (!hasv ? "no VALIDATE" : "no SATISFIES")
        if (nlist < maxlist) { nlist++; lines = lines sprintf("  UNTRACED: %s — %s\n", label, why) }
      }
    }
    # headtask/tasklvl reset TOGETHER: they are one piece of state ("a task
    # block is open at level N"), and leaving headtask armed after the block
    # closed makes the NEXT same-level heading fold into a closed block instead
    # of opening its own — which both swallows a real "## Task 2" and lets a
    # trace bullet under a skipped section open a phantom block.
    open = 0; task = 0; hasv = 0; hass = 0; strictv = 0; stricts = 0; label = ""; tasklvl = 0; headtask = 0
  }
  function start(l, t) { flush(); open = 1; label = substr(strip(l), 1, 60); task = t }
  {
    line = $0
    if (line ~ /^[ \t]*(```|~~~)/) { fence = 1 - fence; next }
    if (fence) next
    ishead = (line ~ /^#+[ \t]/)
    if (ishead) { match(line, /^#+/); lvl = RLENGTH }
    # A skipped contract section runs to the next heading at its own level or
    # above, so its sub-headings go with it.
    if (skiplvl > 0) { if (ishead && lvl <= skiplvl) skiplvl = 0; else { countonly(line); next } }
    if (ishead) {
      # A DEEPER heading inside a task block is part of that task, not the next
      # one: "### Task 1" / "#### Steps" / "- VALIDATE:" must score Task 1, or
      # the sub-heading steals the trace lines and Task 1 is refused untraced.
      if (headtask && lvl > tasklvl) { mark(line); next }
      # ...plus "## Verification checklist", which the plan prompt asks for by
      # name and which is a list of commands, not of tasks: every line in it
      # carries a check and none of them delivers a client criterion.
      if (tolower(strip(line)) ~ /^(system invariants|requirements coverage|acceptance tests|qa screens|verification|shared files|spec changes from comments)/) {
        flush(); skiplvl = lvl; next
      }
      start(line, istask(line)); headtask = task; if (task) tasklvl = lvl
      mark(line); next
    }
    # A VALIDATE/SATISFIES bullet belongs to the task above it; it never opens
    # one. Without this every trace line would become its own untraced task.
    if (line ~ /^[ \t]*(([-*+]|[0-9]+[.)])[ \t]+)?(\*\*)?(VALIDATE|SATISFIES)[ \t]*:/) {
      if (!open) start("(before the first heading)", 0)
      mark(line); next
    }
    # `-`, `*` and `1.` only: a wrapped prose line that happens to begin with
    # `+ ` is not a task (project-3 TK-72 wrapped a shell command that way, and the
    # phantom bullet stole the SATISFIES line of the real task).
    if (!headtask && line ~ /^[ ]?([-*]|[0-9]+[.)])[ \t]+/) { start(line, istask(line)); mark(line); next }
    mark(line)
  }
  END {
    flush()
    printf "PLAN_TASKS: %d\n", tasks + 0
    printf "PLAN_UNTRACED: %d\n", untraced + 0
    printf "PLAN_TRACE_LINES: validate=%d satisfies=%d\n", nv + 0, ns + 0
    if (nv + 0 == 0 || ns + 0 == 0)
      printf "  UNTRACED: the whole plan — %s\n",
        (nv + 0 == 0 && ns + 0 == 0 ? "no VALIDATE and no SATISFIES lines anywhere" \
         : (nv + 0 == 0 ? "no VALIDATE line anywhere" : "no SATISFIES line anywhere"))
    if (untraced + 0 > 0) {
      printf "%s", lines
      if (untraced > nlist) printf "  ... and %d more\n", untraced - nlist
    }
    printf "%s\t%s\n", "PLAN_RC_HINT",
      ((nv + 0 == 0 || ns + 0 == 0) ? 2 : (untraced + 0 > 0 ? 2 : (tasks + 0 == 0 ? 3 : 0)))
  }
' "$PLAN" 2>/dev/null)

[ -n "$REPORT" ] || { echo "PLAN_GATE_UNAVAILABLE the parser produced no report"
  echo "PLAN_TRACE: unavailable"; exit 3; }
RC=$(printf '%s\n' "$REPORT" | sed -n 's/^PLAN_RC_HINT\t//p' | tail -1)
printf '%s\n' "$REPORT" | grep -v '^PLAN_RC_HINT'

# ---- the failure-mode checklist (BH-5800, prompts/plan-contract.md §13) -------
# A plan that changes bin/ or worker/ answers the six questions in
# catalog/plan-failure-modes.tsv; bin/lib/plan-failure-modes.sh decides. A gap
# refuses the plan the way an untraced task does (rc 2, the same repair pass).
# No lib on this box, or no readable catalog: no check, and the trace decides.
PFM_LIB="$(cd "$(dirname "$0")" && pwd)/lib/plan-failure-modes.sh"
if [ -r "$PFM_LIB" ] && . "$PFM_LIB"; then
  pfm_check "$PLAN" "${PLAN_FAILURE_MODES_CATALOG:-$(cd "$(dirname "$0")/.." && pwd)/catalog/plan-failure-modes.tsv}"
  [ $? = 2 ] && [ "$RC" = 0 ] && RC=2
fi

# ---- the outcome replay (prompts/plan-contract.md §16) ------------------------
# A perf/cost plan (PLAN_GATE_PERF=1 from the plan stage, or a `## Target
# metric` heading in the plan) states its target and an outcome-replay
# acceptance item; bin/lib/perf-plan-rule.sh decides. A gap refuses the plan
# (rc 2, the same repair pass). No lib on this box: no check.
PPR_LIB="$(cd "$(dirname "$0")" && pwd)/lib/perf-plan-rule.sh"
if [ -r "$PPR_LIB" ] && . "$PPR_LIB" && command -v pt_plan_check >/dev/null 2>&1; then
  pt_plan_check "$PLAN"
  [ $? = 2 ] && [ "$RC" = 0 ] && RC=2
fi

# ---- the Shared-files report (prompts/plan-contract.md §11) -------------------
# A whole-path mention: the byte before and after the path is not a path byte
# ([A-Za-z0-9_./@-]), except one sentence-ending "." with no path byte after it.
if [ -n "${PLAN_GATE_HOTSPOTS:-}" ]; then
  if [ -r "$PLAN_GATE_HOTSPOTS" ] && [ -f "$PLAN_GATE_HOTSPOTS" ]; then
    awk '
      function strip(s) {
        gsub(/^[ \t]+/, "", s); sub(/^#+[ \t]*/, "", s); gsub(/[*`]/, "", s)
        gsub(/[ \t]+$/, "", s); return s
      }
      function pb(c) { return c ~ /[A-Za-z0-9_.\/@-]/ }
      # mentions(l, p) — how many whole-path mentions of p are in l; sets rest
      # to l with each of them cut out.
      function mentions(l, p,   n, i, b, a, a2, off, out) {
        n = 0; out = ""; off = 0
        while ((i = index(substr(l, off + 1), p)) > 0) {
          i += off
          b = (i > 1) ? substr(l, i - 1, 1) : ""
          a = substr(l, i + length(p), 1); a2 = substr(l, i + length(p) + 1, 1)
          if (!pb(b) && (!pb(a) || (a == "." && !pb(a2)))) {
            n++; out = out substr(l, off + 1, i - 1 - off); off = i + length(p) - 1
          } else {
            out = out substr(l, off + 1, i - off); off = i
          }
        }
        rest = out substr(l, off + 1)
        return n
      }
      # FILENAME, not FNR == NR: an EMPTY hotlist (measured, zero rows) would
      # make the plan itself read as the list.
      FILENAME == ARGV[1] { sub(/\r$/, ""); if ($0 != "" && !($0 in hot)) { hot[$0] = 1; order[++nh] = $0 }; next }
      {
        line = $0
        if (line ~ /^[ \t]*(```|~~~)/) { fence = 1 - fence; next }
        if (fence) next
        if (line ~ /^#+[ \t]/) {
          match(line, /^#+/); lvl = RLENGTH
          if (mode != "" && lvl <= modelvl) mode = ""
          t = tolower(strip(line))
          if (t ~ /^shared files/)   { mode = "shared"; modelvl = lvl; next }
          if (t ~ /^sibling claims/) { mode = "skip";   modelvl = lvl; next }
        }
        if (mode == "skip") next
        for (k = 1; k <= nh; k++) {
          p = order[k]
          if (!mentions(line, p)) continue
          if (mode == "shared") {
            r = rest
            for (j = 1; j <= nh; j++) if (mentions(r, order[j])) r = rest
            if (r ~ /[A-Za-z]/) listed[p] = 1; else noreason[p] = 1
          } else named[p] = 1
        }
      }
      END {
        nn = 0; for (k = 1; k <= nh; k++) if (order[k] in named) nn++
        printf "PLAN_SHARED_NAMED: %d\n", nn
        bad = 0
        for (k = 1; k <= nh; k++) {
          p = order[k]
          if ((p in named) && !(p in listed) && !(p in noreason)) { printf "  SHARED_UNLISTED: %s\n", p; bad++ }
        }
        for (k = 1; k <= nh; k++) {
          p = order[k]
          if ((p in noreason) && !(p in listed)) { printf "  SHARED_NOREASON: %s\n", p; bad++ }
        }
        print "PLAN_SHARED: " (bad ? "unlisted" : "ok")
      }
    ' "$PLAN_GATE_HOTSPOTS" "$PLAN" 2>/dev/null || echo "PLAN_SHARED: unread"
  else
    echo "PLAN_SHARED: unread"
  fi
fi
case "$RC" in
  0) echo "PLAN_TRACE: ok" ;;
  2) echo "PLAN_TRACE: untraced" ;;
  3) echo "PLAN_GATE_UNAVAILABLE nothing in this plan reads as a task block"
     echo "PLAN_TRACE: unavailable" ;;
  *) echo "PLAN_GATE_UNAVAILABLE the parser reached no verdict"
     echo "PLAN_TRACE: unavailable"; RC=3 ;;
esac
exit "$RC"
