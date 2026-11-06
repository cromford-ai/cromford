# shellcheck shell=bash
# bin/merge-conductor.d/bh-9071-e2e-red-hold.sh - A RED END-TO-END CHECK ON
# THE HEAD HOLDS THE ENQUEUE (BH-9071). Sourced by bin/merge-conductor.sh (the
# BH-7453 fragment block); no side effect at source time.
#
# Mergify gates only on the checks .mergify.yml requires (Unit, Type, Coverage,
# Drift), and mc_cireq_apply (BH-8012) turns the CI word green when those are
# green. End-to-end shards are not required, so a PR with a red shard reached
# the READY arm and got the `merge-queue` label. This gate reads the check runs
# of the head commit before that label is added. It adds no Mergify gate and
# starts no test run: it only reads what already ran.
#
# mc_e2e_red_hold — pr_worker calls it in the READY arm right after the
# production-red hold, with P KEY HEAD SLUG NUM URL RAWLBL QUEUE PROVIDER PREV
# ACTIONS KILL MERGES in scope. rc 0 = HELD (the row stays READY, pr_worker
# returns), rc 1 = go on. Only a not-yet-queued row on a Mergify repo is read.
#   red      a latest E2E-class run completed with conclusion `failure`: one
#            log line and one PR comment per (PR, head); ready-why e2e-red.
#   running  a latest E2E-class run is not completed: wait; ready-why e2e-running.
#   unread   the read failed, did not parse, or the pages did not hold
#            total_count runs: held this tick, no comment; ready-why e2e-unread.
#   green / none  rc 1, nothing written: the arm goes on as before.
# A PR labelled $MC_MAIN_RED_LABEL (fix-main-red) is not read and goes on.
# Every mark carries the head, so a new commit clears the block.
#
# Knobs (lane merge-conductor, per project): MC_E2E_RED_HOLD (1 on, 0 off),
# MC_E2E_CHECK_RE (the check-name regex, case-insensitive; empty = E2E_CHECK_RE
# of bin/lib/e2e-paths.sh). The page cap and the read timeout are the existing
# MC_REST_PAGES_MAX and MC_CI_READ_TIMEOUT_S. Test seam only: MC_E2E_NOW (the
# clock of the bad-regex hour mark).
# Tests: tests/merge-conductor-e2e-red-hold.bh-9071-test.sh.

# _mc_e2e_knob <ENV> <fallback> [int] — lane.merge-conductor[.<p>].<env>, else
# the env var, else the fallback. With `int`, not a whole number reads as the
# fallback.
_mc_e2e_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  if [ "${3:-}" = int ]; then case "$v" in ''|*[!0-9]*) v="$2" ;; esac; fi
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# mc_e2e_check_re — prints the check-name regex for project $P; rc 1 when no
# regex is known at all (no row and no bin/lib/e2e-paths.sh).
mc_e2e_check_re() {
  local re root now mark
  # fallback "": settings row lane.merge-conductor[.<project>].mc_e2e_check_re (catalog/lanes.d/merge-conductor.knobs.d/MC_E2E_CHECK_RE.json); empty = E2E_CHECK_RE below
  re=$(_mc_e2e_knob MC_E2E_CHECK_RE "")
  if [ -z "${E2E_CHECK_RE:-}" ]; then
    root="${H:-${HARNESS:-}}"
    # shellcheck source=bin/lib/e2e-paths.sh
    [ -n "$root" ] && [ -r "$root/bin/lib/e2e-paths.sh" ] && . "$root/bin/lib/e2e-paths.sh"
  fi
  if [ -n "$re" ] && ! jq -n --arg re "$re" '"" | test($re; "i")' >/dev/null 2>&1; then
    now="${MC_E2E_NOW:-$(date -u +%s)}"
    case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
    mark="e2erebad ${P:-?} $(date -u -d "@$now" +%Y%m%d%H 2>/dev/null)"
    mc_attempt_has "$mark" 2>/dev/null \
      || { mc_attempt_put "$mark"
           mc_log "e2e-red: the mc_e2e_check_re regex for ${P:-?} does not compile ($re); the fallback E2E_CHECK_RE is used"; }
    re=""
  fi
  [ -n "$re" ] || re="${E2E_CHECK_RE:-}"
  [ -n "$re" ] || return 1
  printf '%s' "$re"
}

# mc_e2e_read <slug> <sha> <out-file> — every check run of the head, as one
#   `{total_count, check_runs}` object in <out-file>. rc 0 read, rc 1 unread
#   (MC_E2E_WHY says why). Pages are bounded by MC_REST_PAGES_MAX; a read that
#   stops short of total_count is unread, never a short list (D12).
mc_e2e_read() {
  local slug="$1" sha="$2" out="$3" max p=1 t pages tot=-1 got=0 len GH_REST_TIMEOUT_S rc
  MC_E2E_WHY=""
  max="${MC_REST_PAGES_MAX:-30}"; case "$max" in ''|*[!0-9]*|0) max=30 ;; esac
  GH_REST_TIMEOUT_S=30
  command -v mc_ci_read_timeout_s >/dev/null 2>&1 && GH_REST_TIMEOUT_S=$(mc_ci_read_timeout_s)
  [ "${GH_REST_TIMEOUT_S:-0}" -gt 0 ] 2>/dev/null || GH_REST_TIMEOUT_S=
  command -v gh_rest >/dev/null 2>&1 || { MC_E2E_WHY="no gh_rest"; return 1; }
  t=$(mktemp "${TMPDIR:-/tmp}/mc-e2e.XXXXXX") || { MC_E2E_WHY="no temp file"; return 1; }
  pages="$t.pages"; : > "$pages"
  while [ "$p" -le "$max" ]; do
    rc=0; gh_rest GET "repos/$slug/commits/$sha/check-runs?filter=latest&per_page=100&page=$p" > "$t" || rc=$?
    if [ "$rc" != 0 ]; then MC_E2E_WHY="check-runs read failed (HTTP ${GH_REST_STATUS:-000})"; rm -f "$t" "$pages"; return 1; fi
    if ! len=$(jq -er 'if (.total_count | type) == "number" and (.check_runs | type) == "array"
                       then "\(.total_count) \(.check_runs | length)" else error("shape") end' "$t" 2>/dev/null); then
      MC_E2E_WHY="check-runs page $p unreadable"; rm -f "$t" "$pages"; return 1
    fi
    # total_count of page 1 is the count to reach; a later page cannot lower it.
    [ "$p" = 1 ] && tot="${len% *}"
    len="${len#* }"
    jq -c '.check_runs' "$t" >> "$pages"
    got=$((got + len))
    { [ "$got" -ge "$tot" ] || [ "$len" = 0 ]; } && break
    p=$((p + 1))
  done
  if [ "$got" -lt "$tot" ]; then
    MC_E2E_WHY="check-runs pages held $got of $tot runs"; rm -f "$t" "$pages"; return 1
  fi
  jq -sc --argjson tot "$tot" '{total_count: $tot, check_runs: (add // [])}' "$pages" > "$out" 2>/dev/null; rc=$?
  rm -f "$t" "$pages"
  [ "$rc" = 0 ] || { MC_E2E_WHY="check-runs pages did not join"; return 1; }
  return 0
}

# mc_e2e_state <runs-file> <regex> — pure, no network. Line 1 is the state
#   (red|running|green|none); then one `name<TAB>html_url` line per run it is
#   about (the failed runs for red, the unfinished ones for running). The latest
#   run of each E2E-class name by started_at counts (the crs_word rule). Only
#   conclusion `failure` is red. rc 1 when jq cannot read the file.
mc_e2e_state() {
  jq -r --arg re "$2" '
    [.check_runs[]? | select(((.name // "") | test($re; "i")))]
    | group_by(.name) | map(sort_by(.started_at // "") | last)
    | (map(select(.status == "completed" and .conclusion == "failure"))) as $red
    | (map(select(.status != "completed"))) as $run
    | if length == 0 then "none"
      elif ($red | length) > 0 then (["red"] + ($red | map("\(.name)\t\(.html_url // "")"))) | join("\n")
      elif ($run | length) > 0 then (["running"] + ($run | map("\(.name)\t\(.html_url // "")"))) | join("\n")
      else "green" end' "$1" 2>/dev/null
}

# mc_e2e_red_comment <runs> — the one PR comment per (PR, head) for a red
#   head; <runs> is the `name<TAB>url` lines of mc_e2e_state. Posts only when
#   the tick takes actions; otherwise one WOULD line per (PR, head). The
#   e2eredcmt mark is written only after the POST returned 0, so a failed POST
#   is tried again next tick. A crash between the 2xx and the mark can post a
#   second comment once.
mc_e2e_red_comment() {
  local runs="$1" list="" name url body rc
  mc_attempt_has "e2eredcmt $KEY $HEAD" 2>/dev/null && return 0
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ] || [ "${MERGES:-0}" != 1 ]; then
    mc_attempt_has "e2eredwould $KEY $HEAD" 2>/dev/null \
      || { mc_attempt_put "e2eredwould $KEY $HEAD"; mc_log "E2E_RED_COMMENT WOULD $KEY ${HEAD:0:8}"; }
    return 0
  fi
  while IFS=$'\t' read -r name url; do
    [ -n "$name" ] || continue
    list="${list:+$list, }$name${url:+ ($url)}"
  done <<<"$runs"
  body="The merge conductor did not queue this PR. These end-to-end checks failed on commit \`${HEAD:0:8}\`: $list.

Push a fix and the conductor checks the new commit. Label the PR \`${MC_MAIN_RED_LABEL:-fix-main-red}\` only if it must reach main while main is red.

<!-- bh-e2e-red:$HEAD -->"
  rc=0; mc_issue_comment "$SLUG" "$NUM" "$body" || rc=$?
  if [ "$rc" = 0 ]; then
    mc_attempt_put "e2eredcmt $KEY $HEAD"
    mc_log "$KEY posted e2e-red comment on ${HEAD:0:8}"
  else
    mc_log "$KEY e2e-red comment NOT posted on ${HEAD:0:8} (rc $rc, HTTP ${GH_REST_STATUS:-000}); the next tick tries again"
  fi
  return 0
}

# mc_e2e_red_hold — rc 0 HELD, rc 1 go on. See the header.
mc_e2e_red_hold() {
  [ -n "${P:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] || return 1
  [ "${QUEUE:-0}" = 1 ] && [ "${PROVIDER:-}" = mergify ] && [ "${PREV:-}" != QUEUED ] || return 1
  # fallback 1: settings row lane.merge-conductor[.<project>].mc_e2e_red_hold (catalog/lanes.d/merge-conductor.knobs.d/MC_E2E_RED_HOLD.json)
  [ "$(_mc_e2e_knob MC_E2E_RED_HOLD 1 int)" = 0 ] && return 1
  local lbl="${MC_MAIN_RED_LABEL:-fix-main-red}" re t out st runs names
  case ",${RAWLBL:-}," in
    *",$lbl,"*)
      mc_attempt_has "e2eredpass $KEY $HEAD" 2>/dev/null \
        || { mc_attempt_put "e2eredpass $KEY $HEAD"
             mc_log "$KEY is labelled $lbl — the end-to-end check gate is skipped on ${HEAD:0:8}"; }
      return 1 ;;
  esac
  if ! re=$(mc_e2e_check_re); then
    mc_ready_why "$KEY" "$HEAD" e2e-unread "not queued: no end-to-end check name pattern is known on this box (bin/lib/e2e-paths.sh missing); the next tick reads again"
    return 0
  fi
  t=$(mktemp "${TMPDIR:-/tmp}/mc-e2e-runs.XXXXXX") || return 0
  if ! mc_e2e_read "$SLUG" "$HEAD" "$t"; then
    rm -f "$t"
    mc_ready_why "$KEY" "$HEAD" e2e-unread "not queued: the end-to-end check read failed on ${HEAD:0:8} ($MC_E2E_WHY); the next tick reads again"
    return 0
  fi
  if ! out=$(mc_e2e_state "$t" "$re") || [ -z "$out" ]; then
    rm -f "$t"
    mc_ready_why "$KEY" "$HEAD" e2e-unread "not queued: the end-to-end check runs on ${HEAD:0:8} could not be judged; the next tick reads again"
    return 0
  fi
  rm -f "$t"
  st="${out%%$'\n'*}"; runs=""; [ "$st" = "$out" ] || runs="${out#*$'\n'}"
  names=$(cut -f1 <<<"$runs" | paste -sd, - | sed 's/,/, /g')
  case "$st" in
    red)
      mc_attempt_has "e2eredhold $KEY $HEAD" 2>/dev/null \
        || { mc_attempt_put "e2eredhold $KEY $HEAD"
             mc_log "$KEY READY and HELD: end-to-end check(s) $names failed on ${HEAD:0:8} — not queued; a new commit clears it"; }
      mc_ready_why "$KEY" "$HEAD" e2e-red "end-to-end check(s) $names failed on ${HEAD:0:8}; a new commit clears it" logged
      mc_e2e_red_comment "$runs"
      return 0 ;;
    running)
      mc_ready_why "$KEY" "$HEAD" e2e-running "waiting for end-to-end check(s) $names on ${HEAD:0:8}"
      return 0 ;;
  esac
  return 1
}
