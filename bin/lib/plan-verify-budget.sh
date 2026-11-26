#!/bin/bash
# bin/lib/plan-verify-budget.sh — the plan's `## Verify` list has a budget, or
# the plan gate refuses it (bin/plan-gate.sh, the same one repair pass).
# Sourced, never executed: functions only, no output at source time.
#
# WHY (BH-9779). The BH-7921 plan's `## Verify (run, not edited)` list held a
# `grep -l ... tests/*.sh | while read t; do ... >/dev/null 2>&1; done` loop
# (279 suites), "run on the head AND on main" (558 runs), and the instruction
# "run both with no timeout" for a suite measured at 488 s. One execute call
# then ran 6,716 s and ended rc 124, six rounds in a row. The gate stage
# already selects and runs the affected suites; the agent does not need to.
#
# WHAT IS READ. The first heading whose text (markup stripped, lowercased)
# matches `^verify([^a-z]|$)`, up to the next heading of the same or a higher
# level. Fenced blocks inside it ARE read: a command in a fence is still a
# command. Nothing outside the section is read. No section: n/a.
#
# A SUITE is a distinct `tests/<name>` token, normalized: trailing `.` `,` `)`
# cut, then `-test.sh`, `.test.js`, `.test.ts` or `.sh` stripped, so
# `tests/x.bh-1` and `tests/x.bh-1-test.sh` are one suite. A token with `*` or
# `?` is a glob, not a suite. `tests/lib/...` and `tests/fixtures/...` are not
# suites.
#
# THE RULES (each hit is one `  UNTRACED: verify budget — line <n>: <rule>: ...`
# line, <n> the plan's own line number):
#   suite-count  more than PLAN_VERIFY_MAX_SUITES distinct suites (one hit)
#   loop         a glob over tests/ (tests/*.sh), `for <v> in ... tests/`,
#                `find ... tests`, `ls ... tests/`, or `grep -l ... tests/`
#                piped into `while read` or `xargs`
#   main-runs    the suites the plan asks to run on main, summed over the lines
#                that say so (`run ... on main`, `head and main`, `main and
#                head`, `on main to compare`); a loop line is unbounded. Over
#                PLAN_VERIFY_MAX_MAIN_SUITES: one hit per such line
#   no-timeout   `no timeout`, `without a timeout|time limit`, `timeout 0`,
#                `--timeout=0`
#   slow-suite   a named suite whose recorded duration is over
#                PLAN_VERIFY_SLOW_SUITE_S seconds
# loop, main-runs and no-timeout skip a match when a negation (`never`, `do
# not`, `don't`, `not`) comes before it in the same sentence of that line.
#
# DURATIONS, first readable: env PLAN_VERIFY_DURATIONS, then under the root
# state/ci-durations/api.tsv, catalog/ci-suite-durations.tsv,
# state/test-impact-durations.tsv; `<suite>\t<seconds>` rows, `#` lines
# skipped. None readable: `PLAN_VERIFY_DURATIONS: unread` and the slow-suite
# rule does not run. No network.
#
# THE FUNCTIONS
#   pvb_plan_check <plan>          prints the lines; rc 0 ok|off|n/a, rc 2 over
#   pvb_repair_note <gate-out>     the repair pass's paragraph, or nothing
#
# THE KNOBS (catalog/lanes.d/_lib.plan-verify-budget.json, id
# plan-verify-budget), read through `_LG_KIND=libs lane_knob` in a subshell,
# else the env, else the fallback named on each read. The root is
# ${HARNESS:-${H:-}} only (D43).
[ -n "${_PVB_LIB_LOADED:-}" ] && return 0
_PVB_LIB_LOADED=1

# _pvb_knob <ENV> <fallback> — a whole number: the lib lane row, else the env,
# else <fallback>.
_pvb_knob() {
  local root="${HARNESS:-${H:-}}" v=""
  if [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=/dev/null
    v=$( . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1 && _LG_KIND=libs lane_knob plan-verify-budget "$1" "${PROJECT:-}" 2>/dev/null )
  fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}

# _pvb_durations — the path of the first readable durations file, or rc 1.
_pvb_durations() {
  local root="${HARNESS:-${H:-}}" f
  for f in "${PLAN_VERIFY_DURATIONS:-}" \
           ${root:+"$root/state/ci-durations/api.tsv"} \
           ${root:+"$root/catalog/ci-suite-durations.tsv"} \
           ${root:+"$root/state/test-impact-durations.tsv"}; do
    [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

pvb_plan_check() {
  local plan="${1:-}" on maxs maxm slow dur="" durline
  [ -n "$plan" ] && [ -r "$plan" ] || { echo "PLAN_VERIFY_BUDGET: n/a"; return 0; }
  on=$(_pvb_knob PLAN_VERIFY_BUDGET 1)                 # lib.plan-verify-budget.plan_verify_budget
  [ "$on" = 0 ] && { echo "PLAN_VERIFY_BUDGET: off"; return 0; }
  maxs=$(_pvb_knob PLAN_VERIFY_MAX_SUITES 30)          # lib.plan-verify-budget.plan_verify_max_suites
  maxm=$(_pvb_knob PLAN_VERIFY_MAX_MAIN_SUITES 3)      # lib.plan-verify-budget.plan_verify_max_main_suites
  slow=$(_pvb_knob PLAN_VERIFY_SLOW_SUITE_S 300)       # lib.plan-verify-budget.plan_verify_slow_suite_s
  if dur=$(_pvb_durations); then durline="PLAN_VERIFY_DURATIONS: $dur"; else dur=""; durline="PLAN_VERIFY_DURATIONS: unread"; fi
  local out
  out=$(awk -v maxs="$maxs" -v maxm="$maxm" -v slow="$slow" -v durf="$dur" -v durline="$durline" '
    function norm(s) {
      sub(/[.,)]+$/, "", s)
      if (s ~ /-test\.sh$/) sub(/-test\.sh$/, "", s)
      else if (s ~ /\.test\.(js|ts)$/) sub(/\.test\.(js|ts)$/, "", s)
      else if (s ~ /\.sh$/) sub(/\.sh$/, "", s)
      return s
    }
    function excerpt(s) { gsub(/[\001-\037\177]/, " ", s); sub(/^[ \t]+/, "", s); return substr(s, 1, 120) }
    # The three rules are read one sentence at a time (a sentence ends at
    # ". " or "; "). A match is skipped when a negation comes before it in its
    # sentence. The patterns are strings (an awk /re/ argument would be a match
    # against $0), one array per rule, set in BEGIN.
    BEGIN {
      NL = 0; LP[++NL] = "tests/[a-z0-9_.@/-]*[*?]"
      LP[++NL] = "(^|[^a-z])for [a-z_][a-z0-9_]* in .*tests/"
      LP[++NL] = "(^|[^a-z])find [^|]*tests"
      LP[++NL] = "(^|[^a-z])ls [^|]*tests/"
      LP[++NL] = "grep -[a-z]*l[a-z]* [^|]*tests/[^|]*[|][ ]*(while read|xargs)"
      NT = 0; TP[++NT] = "(^|[^a-z])no time ?out([^a-z]|$)"
      TP[++NT] = "(^|[^a-z])without (a )?time ?(out|limit)"
      TP[++NT] = "(^|[^a-z-])timeout 0([^0-9.]|$)"
      TP[++NT] = "--timeout[= ]0([^0-9.]|$)"
      NM = 0; MP[++NM] = "(^|[^a-z])(re-?)?runs?([^a-z].*)?[^a-z]on (origin/)?main([^a-z]|$)"
      MP[++NM] = "(^|[^a-z])head and (on )?main([^a-z]|$)"
      MP[++NM] = "(^|[^a-z])main and (the )?head([^a-z]|$)"
      MP[++NM] = "(^|[^a-z])on main to compare"
      NEG = "(^|[^a-z])(never|do not|don.t|not)([^a-z]|$)"
    }
    # okm(s, re) — 1 when re matches s and no negation comes before the match.
    function okm(s, re) { return (match(s, re) && substr(s, 1, RSTART - 1) !~ NEG) }
    function any(s, kind,   i) {
      if (kind == "l") { for (i = 1; i <= NL; i++) if (okm(s, LP[i])) return 1 }
      else if (kind == "t") { for (i = 1; i <= NT; i++) if (okm(s, TP[i])) return 1 }
      else { for (i = 1; i <= NM; i++) if (okm(s, MP[i])) return 1 }
      return 0
    }
    # scan(l) sets LH, TH, MH (the line has a loop / no-timeout / main-run
    # hit) and LS, TS: the first sentence of l that holds the loop / the
    # no-timeout hit, in its own case (tolower keeps the length).
    function scan(l,   s, k, low) {
      LH = 0; TH = 0; MH = 0; LS = ""; TS = ""
      while (l != "") {
        k = match(l, /[.;] /)
        if (k) { s = substr(l, 1, k); l = substr(l, k + 2) } else { s = l; l = "" }
        low = tolower(s)
        if (any(low, "l")) { LH = 1; if (LS == "") LS = s }
        if (any(low, "t")) { TH = 1; if (TS == "") TS = s }
        if (any(low, "m")) MH = 1
      }
    }
    function hit(n, rule, line) { hits[++nh] = sprintf("  UNTRACED: verify budget — line %d: %s: %s", n, rule, excerpt(line)) }
    FILENAME == durf {
      if ($0 ~ /^#/ || NF < 2) next
      split($0, c, "\t"); if (c[2] ~ /^[0-9]+(\.[0-9]+)?$/) dsec[norm(c[1])] = c[2] + 0
      next
    }
    {
      raw = $0; sub(/\r$/, "", raw)
      t = raw; sub(/^[ \t]+/, "", t); m = substr(t, 1, 3)
      if (m == "```" || m == "~~~") { if (fence == "") fence = m; else if (fence == m) fence = ""; next }
      if (fence == "" && raw ~ /^#+[ \t]/) {
        match(raw, /^#+/); lvl = RLENGTH
        if (open && lvl <= olvl) { open = 0; done = 1 }
        if (!open && !done) {
          h = raw; sub(/^#+[ \t]*/, "", h); gsub(/[*_`]/, "", h); h = tolower(h)
          if (h ~ /^verify([^a-z]|$)/) { open = 1; olvl = lvl; found = 1 }
        }
        next
      }
      if (!open) next
      # the suites named on this line
      ns = 0; rest = raw
      while (match(rest, /tests\/[A-Za-z0-9_.@\/*?-]+/)) {
        tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (tok ~ /[*?]/ || tok ~ /^tests\/(lib|fixtures)\//) continue
        s = norm(tok); if (s == "tests" || s == "tests/") continue
        if (!(s in seen)) { seen[s] = FNR; order[++nd] = s; firstline[s] = raw; if (nd == maxs + 1) countline = FNR }
        if (!((FNR SUBSEP s) in online)) { online[FNR SUBSEP s] = 1; ns++ }
      }
      scan(raw)
      if (LH) hit(FNR, "loop", LS)
      if (TH) hit(FNR, "no-timeout", TS)
      if (MH && (ns > 0 || LH)) {
        mlines[++nm] = FNR; mtext[nm] = raw
        if (LH) unb = 1; else msum += ns
      }
    }
    END {
      if (!found) { print "PLAN_VERIFY_BUDGET: n/a"; exit 0 }
      print durline
      if (nd > maxs) hits[++nh] = sprintf("  UNTRACED: verify budget — line %d: suite-count: %d distinct suites named, over the limit of %d", countline, nd, maxs)
      if (unb || msum > maxm)
        for (i = 1; i <= nm; i++) hit(mlines[i], "main-runs: " (unb ? "an unbounded number of" : msum) " suites to run on main, over the limit of " maxm, mtext[i])
      if (durf != "")
        for (i = 1; i <= nd; i++) { s = order[i]
          if ((s in dsec) && dsec[s] > slow + 0) hit(seen[s], "slow-suite: " s " recorded " dsec[s] " s, over the limit of " slow " s", firstline[s]) }
      for (i = 1; i <= nh; i++) print hits[i]
      printf "PLAN_VERIFY_SUITES: %d\n", nd
      print "PLAN_VERIFY_BUDGET: " (nh ? "over" : "ok")
    }' ${dur:+"$dur"} "$plan" 2>/dev/null) || out=""
  if [ -z "$out" ]; then echo "PLAN_VERIFY_BUDGET: n/a"; return 0; fi
  printf '%s\n' "$out"
  case "$out" in *"PLAN_VERIFY_BUDGET: over") return 2 ;; esac
  return 0
}

# pvb_repair_note <plan-gate-out> — one paragraph for the repair prompt when
# the gate output holds `verify budget —` lines; nothing otherwise.
pvb_repair_note() {
  local f="${1:-}" hits n m s
  [ -r "$f" ] || return 0
  hits=$(sed -n 's/^  UNTRACED: verify budget — //p' "$f" 2>/dev/null | head -n 8 | tr '\n' ';' | sed 's/;$//')
  [ -n "$hits" ] || return 0
  n=$(_pvb_knob PLAN_VERIFY_MAX_SUITES 30)        # lib.plan-verify-budget.plan_verify_max_suites
  m=$(_pvb_knob PLAN_VERIFY_MAX_MAIN_SUITES 3)    # lib.plan-verify-budget.plan_verify_max_main_suites
  s=$(_pvb_knob PLAN_VERIFY_SLOW_SUITE_S 300)     # lib.plan-verify-budget.plan_verify_slow_suite_s
  printf ' VERIFY BUDGET: the plan'"'"'s %s list is over its budget: %s. Rewrite that list: name only the suites this change can break, one command per suite, at most %s suites; no loop or glob over tests/; a run on main for at most %s suites; no instruction to run with no timeout; no suite slower than %s s. Leave the wide run to the gate: bin/test-impact-gate.sh and the selection gate already select and run the affected suites.' \
    "'## Verify (run, not edited)'" "$hits" "$n" "$m" "$s"
}
