# shellcheck shell=bash
# bin/lib/prod-red-defer.sh — A COMPLETION COMMENT WAITS WHILE PRODUCTION IS RED
# (BH-8859, item 3 of BH-8781). Sourced, never run; functions only, no side
# effect at source time, `set -u` safe.
#
# "Triage never posts a completion comment to a client while the project's
# production is red. The comment waits for the green deploy, then goes out with
# the live URL." The completion close-out is the one a `PR_MERGED http…` RESULT
# gets (merged, ticket to done). A `PR_CREATED` close-out ("built and open for
# review") still goes out. The readers:
#   bin/board-closeout.sh   builder-direct close-out: exit 4 before any POST
#   bin/lib/rt/scope.sh     rt_unswept_dirs leaves the dir off the sweep list
#   bin/triage-gate.sh      step 3 buys no results-sweep for a waiting dir
#   bin/run-triage.sh       the session and every shard get the directive
# A waiting dir keeps no COMMENTED marker, so the first tick after a green
# snapshot sweeps it as today, and the SOP's direct production links go with it.
#
# THE RED RECORD is .projects[<p>].prod_red in state/vercel-deploy-status.json
# (bin/vercel-deploy-snapshot.sh writes it). It is read through the BH-8781
# reader mc_prod_red_state (bin/merge-conductor.d/bh-8781-prod-red-hold.sh),
# with the same staleness knob MC_PROD_RED_MAX_AGE_S. No second parser.
#
# FAIL OPEN. No file, junk, a stale file or no reader reads "not red": a dead
# snapshot push must not freeze every close-out.
#
# Knob: TRIAGE_PROD_RED_DEFER (1 on, 0 off; per project
# lane.run-triage.<project>.triage_prod_red_defer).
# Test seams: MC_PROD_RED_SNAPSHOT (the file), MC_PROD_RED_NOW (the clock).
# Tests: tests/prod-red-defer.bh-8859-test.sh.
#
# The harness root is the <harness> argument and nothing else (BH-2613).

# prod_red_defer_on <harness> <project> — prints 1 (on) or 0 (off).
prod_red_defer_on() {
  local p="${2:-}" v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob run-triage TRIAGE_PROD_RED_DEFER "$p" 2>/dev/null); fi
  [ -n "$v" ] || v="${TRIAGE_PROD_RED_DEFER:-}"
  # fallback 1: settings row lane.run-triage.triage_prod_red_defer (catalog/lanes.d/run-triage.knobs.d/TRIAGE_PROD_RED_DEFER.json)
  case "$v" in 0) printf 0 ;; *) printf 1 ;; esac
}

# _prd_reader <harness> — define mc_prod_red_state once. rc 1 = no reader.
_prd_reader() {
  command -v mc_prod_red_state >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/../merge-conductor.d/bh-8781-prod-red-hold.sh" ${1:+"$1/bin/merge-conductor.d/bh-8781-prod-red-hold.sh"}; do
    # shellcheck source=bin/merge-conductor.d/bh-8781-prod-red-hold.sh
    [ -r "$f" ] && { . "$f"; break; }
  done
  command -v mc_prod_red_state >/dev/null 2>&1
}

# prod_red_defer_state <harness> <project>
#   rc 0 red: prints `since<TAB>sha8<TAB>id`
#   rc 1 otherwise (green, unknown, stale, no reader, knob off)
# Memoised per process and project: a loop over 30 dirs reads the file once.
prod_red_defer_state() {
  local h="${1:-}" p="${2:-}" k st rc
  [ -n "$h" ] && [ -n "$p" ] || return 1
  k="_PRD_MEMO_${p//[^A-Za-z0-9_]/_}"
  if [ -z "${!k:-}" ]; then
    st=""; rc=1
    if [ "$(prod_red_defer_on "$h" "$p")" = 1 ] && _prd_reader "$h"; then
      st=$(MC_PROD_RED_SNAPSHOT="${MC_PROD_RED_SNAPSHOT:-$h/state/vercel-deploy-status.json}" P="$p" mc_prod_red_state "$p" 2>/dev/null); rc=$?
    fi
    if [ "$rc" = 0 ]; then printf -v "$k" 'red\t%s' "$st"; else printf -v "$k" 'no'; fi
  fi
  case "${!k}" in
    red$'\t'*) printf '%s' "${!k#red$'\t'}"; return 0 ;;
  esac
  return 1
}

# prod_red_defers_dir <harness> <project> <build-dir> — rc 0 when the dir's
# close-out waits for green: the first RESULT line is `PR_MERGED http…` and
# production is red. Every other RESULT line is rc 1.
prod_red_defers_dir() {
  local d="${3:-}" l
  [ -r "$d/RESULT" ] || return 1
  l=$(head -1 "$d/RESULT" 2>/dev/null)
  case "$l" in PR_MERGED\ http*) ;; *) return 1 ;; esac
  prod_red_defer_state "${1:-}" "${2:-}" >/dev/null
}

# prod_red_triage_note <harness> <project> — the session directive while red;
# prints nothing otherwise.
prod_red_triage_note() {
  local p="${2:-}" st since sha id
  st=$(prod_red_defer_state "${1:-}" "$p") || return 0
  IFS=$'\t' read -r since sha id <<<"$st"
  printf '%s' "PRODUCTION RED (BH-8859): the newest production deploy of $p failed (Vercel ${id:-unknown}, commit ${sha:-unknown}, red since $since). Merged work is not live. This tick, post NO completion, \"shipped\", \"live\" or \"done\" comment for any merged PR of $p, and move no ticket to done. Leave every PR_MERGED result dir un-COMMENTED: it comes back after the next green deploy, and then its close-out carries the live production link. A PR_CREATED close-out (\"built and open for review\") may still go out, and it must not say the work is live."
}
