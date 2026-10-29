# shellcheck shell=bash
# bin/lib/plan-blocked-stop.sh — BH-8309: the pool stops relaunching a key
# whose newest hub build record is PLAN_BLOCKED.
# Sourced, never run. Defining functions is its only effect at source time.
#
# WHY. cromford, 2026-10-25: 12 tickets looped plan -> PLAN_BLOCKED ->
# re-queued by a board watcher -> plan again, until the per-key spawn cap (12 in
# 24 h). BH-7405, BH-7864 and BH-7865 stopped 20 times each in 2 days: 100 Fly
# runs in one day, plus a plan session each. The reap says "not requeued", but
# nothing read the PLAN_BLOCKED record before the next spawn.
#
# THE GATE
#   pbs_stop_check <project> <key> <ticket> [job-file]  rc 0 may spawn, rc 1
#       refused (the row stays queued: no QROW write, no deferral, no cap count).
#       Acts only on a GitHub-Issues project (tracker_kind github-issues, the
#       BH-7919 seam in bin/lib/tracker.sh) with a numeric ticket, and only
#       when the key's NEWEST record that has a RESULT
#       (builds/pool-<p>-<key>-*/RESULT, by mtime) starts PLAN_BLOCKED. That
#       record is classified ONCE (<record>/plan-blocked.class):
#   done <sha>   plan.md line 1 is a BLOCKED marker followed by "already done on
#       main by <sha>", and GitHub's compare <sha>...<base> answers ahead or
#       identical (an ancestor). The gate posts ONE comment and closes the issue
#       (state_reason completed); `closed` is written only after a re-read says
#       closed. The next tick passes and the HOLD gate parks the row. A key
#       whose window already holds a `closed` record (a person reopened it) is
#       never closed twice: the new record is `other`.
#   after <KEY...>  a line of the blocked excerpt (pb_excerpt) has a
#       prerequisite phrase and 1-5 prerequisite tokens (#N, or <PREFIX>-N with
#       the key's own prefix; never the ticket itself, never a child key N.M).
#       One <record>/plan-blocked.after file (`After: <KEY>` per line). Refused
#       while any named issue is open; released (<record>/plan-blocked.released)
#       when all read closed, or when a person commented on the ticket after the
#       RESULT (_pb_answers_since). An unreadable read refuses this tick.
#   other        anything else. POOL_PLAN_BLOCKED_MAX (2) `other` records younger
#       than POOL_PLAN_BLOCKED_WINDOW_S (86400) and newer than the newest
#       plan-blocked.lifted refuse, with ONE NEEDS_HUMAN hold through
#       bin/needs-human-hold.sh (<newest>/plan-blocked.asked). A RESUME after
#       the ask (_ee_lift_epoch, bin/lib/execute-empty.sh) writes
#       plan-blocked.lifted and the key may spawn again.
#   The knobs are fly-pool lane knobs (catalog/lanes.d/fly-pool.knobs.d):
#   POOL_PLAN_BLOCKED_STOP (1; 0 = the gate is off), POOL_PLAN_BLOCKED_MAX,
#   POOL_PLAN_BLOCKED_WINDOW_S. PBS_NOW pins the clock for tests.
# The root is ${HARNESS:-${H:-}}; with none, the gate passes.

_pbs_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_pbs_now() { if [ -n "${PBS_NOW:-}" ]; then printf '%s' "$PBS_NOW"; else date -u +%s; fi; }
_pbs_int() { # _pbs_int <value> <default> -> a non-negative integer, else the default
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}
_pbs_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }
_pbs_win() { _pbs_int "${POOL_PLAN_BLOCKED_WINDOW_S:-86400}" 86400; } # knob POOL_PLAN_BLOCKED_WINDOW_S
_pbs_is_pb() { case "$(head -1 "$1/RESULT" 2>/dev/null)" in "PLAN_BLOCKED "*|PLAN_BLOCKED) return 0 ;; esac; return 1; }

# _pbs_newest <root> <p> <key> -> the record dir whose RESULT mtime is greatest.
_pbs_newest() {
  local f mt nt=-1 newest=""
  for f in "$1/builds/pool-$2-$3-"*/RESULT; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mt" -ge "$nt" ] && { nt=$mt; newest="${f%/RESULT}"; }
  done
  printf '%s' "$newest"
}

# _pbs_base <root> <p> -> the repo's base branch: BASE_BRANCH, else the
# project env file's BASE_BRANCH (preplan_base_ref's rule), else main.
_pbs_base() {
  local r="$1" p="$2" b="${BASE_BRANCH:-}" ed="$1/env"
  if [ -z "$b" ]; then
    command -v harness_env_dir >/dev/null 2>&1 && ed=$(harness_env_dir "$r" 2>/dev/null)
    [ -r "$ed/$p.env" ] && b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BASE_BRANCH=//p' "$ed/$p.env" \
      | tr -d '"'"'"' \t' | tail -1)
  fi
  case "$b" in ''|*[!A-Za-z0-9._/-]*) b=main ;; esac
  printf '%s' "$b"
}

# _pbs_ancestor <slug> <sha> <base> -> rc 0 the sha is an ancestor of base
# (compare status ahead|identical), 1 it is not (other status, or 404), 75 the
# compare could not be read.
_pbs_ancestor() {
  # GH_REST_TIMEOUT_S only: POOL_GH_READ_TIMEOUT_S is a fly-pool lane-only knob and this
  # lib runs on the box lanes too (lane-scoped-knob-lint, BH-7436).
  local st rc=0 GH_REST_TIMEOUT_S="${GH_REST_TIMEOUT_S:-20}"
  command -v _gh_rest_field >/dev/null 2>&1 || return 75
  st=$(_gh_rest_field "repos/$1/compare/$2...$3" '.status') || rc=$?
  case "$rc" in 0) ;; 44) return 1 ;; *) return 75 ;; esac
  case "$st" in ahead|identical) return 0 ;; esac
  return 1
}

# _pbs_closed_in_window <root> <p> <key> <except-record> -> rc 0 when another
# record of the key whose RESULT is inside the window carries plan-blocked.closed.
_pbs_closed_in_window() {
  local d mt now win
  now=$(_pbs_now); win=$(_pbs_win)
  for d in "$1/builds/pool-$2-$3-"*; do
    [ "$d" = "$4" ] && continue
    [ -e "$d/plan-blocked.closed" ] && [ -f "$d/RESULT" ] || continue
    mt=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    [ $((now - mt)) -le "$win" ] && return 0
  done
  return 1
}

# _pbs_after_keys <key> <ticket> <excerpt> -> the prerequisite keys, space
# separated, in order of first mention, at most 5; nothing when none.
_pbs_after_keys() {
  local key="$1" ticket="$2" ex="$3" pfx line tok n out="" c=0
  pfx="${key%%-*}"
  [[ "$pfx" =~ ^[A-Z]{1,8}$ ]] || return 0
  while IFS= read -r line; do
    grep -qiE 'merged? first|lands? first|blocked[- ]by|depends? on|prerequisite|wait(s|ing)? (for|on|until)|on hold until|until .*(merge|merges|merged|lands|closes)' <<<"$line" || continue
    while IFS= read -r tok; do
      tok="${tok#?}"                       # the boundary char before the token
      case "$tok" in *.*) continue ;; esac # a child key (N.M) is not a prerequisite
      n="${tok##*[#-]}"
      case "$n" in ''|*[!0-9]*) continue ;; esac
      n=$((10#$n))
      [ "$n" = "$ticket" ] && continue
      tok="$pfx-$n"
      [ "$tok" = "$key" ] && continue
      case " $out " in *" $tok "*) continue ;; esac
      out="${out:+$out }$tok"; c=$((c + 1))
      [ "$c" -ge 5 ] && break 2
    done < <(printf ' %s\n' "$line" | grep -oE "[^A-Za-z0-9_](#|$pfx-)[0-9]+(\.[0-9]+)?" )
  done <<< "$ex"
  printf '%s' "$out"
}

# _pbs_classify <root> <p> <key> <record> <slug> <base> <ticket> -> one class
# line. Cached in <record>/plan-blocked.class; an unreadable compare caches
# nothing and reads `other` this tick.
_pbs_classify() {
  local r="$1" p="$2" key="$3" rec="$4" slug="$5" base="$6" ticket="$7" cf l1 sha ex keys arc re
  cf="$rec/plan-blocked.class"
  if [ -s "$cf" ]; then head -1 "$cf"; return 0; fi
  l1=$(head -1 "$rec/plan.md" 2>/dev/null)
  re='^[[:space:]]*([#*]+[[:space:]]*)*(PLAN[_ -])?BLOCKED(-NEEDS-CLARIFICATION)?[*]*[[:space:]]*(:|::|-|—|–|\.)?[[:space:]]*[Aa]lready done on main by ([0-9a-f]{7,40})([^0-9A-Za-z_]|$)'
  if [[ "$l1" =~ $re ]]; then
    sha="${BASH_REMATCH[5]}"
    if _pbs_closed_in_window "$r" "$p" "$key" "$rec"; then
      printf 'other\n' > "$cf" 2>/dev/null; printf 'other\n'; return 0
    fi
    arc=0; _pbs_ancestor "$slug" "$sha" "$base" || arc=$?
    case "$arc" in
      0) printf 'done %s\n' "$sha" > "$cf" 2>/dev/null; printf 'done %s\n' "$sha"; return 0 ;;
      1) printf 'other\n' > "$cf" 2>/dev/null; printf 'other\n'; return 0 ;;
      *) _pbs_say "$key: PLAN_BLOCKED says already done on main by $sha, but the compare against $base could not be read — counted as other this tick, classified again next tick"
         printf 'other\n'; return 0 ;;
    esac
  fi
  ex=$(HARNESS="$r" pb_excerpt "$rec/plan.md" 2>/dev/null)
  keys=$(_pbs_after_keys "$key" "$ticket" "$ex")
  if [ -n "$keys" ]; then
    printf 'after %s\n' "$keys" > "$cf" 2>/dev/null; printf 'after %s\n' "$keys"; return 0
  fi
  printf 'other\n' > "$cf" 2>/dev/null; printf 'other\n'
}

# _pbs_issue_state <slug> <n> — gh_rest_issue_state as a plain command (the
# gh-rest.sh rule, tests/gh-rest-no-subshell-lint.sh): its answer goes to a
# mktemp file and lands in _PBS_ST, so GH_REST_STATUS / GH_REST_REASON stay
# in this shell. rc is the helper's rc; 75 when no temp file could be made.
_pbs_issue_state() {
  local f rc=0
  _PBS_ST=""
  f=$(mktemp "${TMPDIR:-/tmp}/pbs-state.XXXXXX") || return 75
  gh_rest_issue_state "$1" "$2" > "$f" 2>/dev/null || rc=$?
  _PBS_ST=$(cat "$f" 2>/dev/null); rm -f "$f"
  return "$rc"
}

# _pbs_close_done <root> <p> <key> <record> <slug> <ticket> <sha> — rc 0 the
# issue was already closed (the HOLD gate parks the row), rc 1 refused this tick.
_pbs_close_done() {
  local r="$1" p="$2" key="$3" rec="$4" slug="$5" n="$6" sha="$7" st rc=0 line bf
  _pbs_issue_state "$slug" "$n" || rc=$?; st="$_PBS_ST"
  if [ "$rc" = 0 ] && [ "$st" = closed ]; then
    : > "$rec/plan-blocked.closed"
    _pbs_say "$key: PLAN_BLOCKED done $sha — ticket #$n is already closed; no comment, not re-queued"
    return 0
  fi
  # THE MARK BEFORE THE SEND (BH-2317): a client ticket commented twice is the
  # worse failure, so a POST that fails after this is not sent again.
  if [ ! -e "$rec/plan-blocked.close-commented" ]; then
    : > "$rec/plan-blocked.close-commented"
    line=$(HARNESS="$r" pb_excerpt "$rec/plan.md" 2>/dev/null | head -1)
    case "$line" in *"already done on main by $sha"*) ;; *) line="already done on main by $sha" ;; esac
    command -v _ee_defang >/dev/null 2>&1 && line=$(printf '%s' "$line" | _ee_defang)
    bf=$(mktemp "${TMPDIR:-/tmp}/pbs-close.XXXXXX") || bf=""
    if [ -n "$bf" ]; then
      {
        printf 'The plan stage found that this ticket is already shipped:\n\n> %s\n\n' "${line:0:300}"
        printf 'So we closed it as completed. If something is still missing, reopen it and the pool plans it again.\n'
      } > "$bf"
      gh_rest_comment "$slug" "$n" "$bf" >/dev/null 2>&1 \
        || _pbs_say "$key: the close comment on #$n was not posted (HTTP ${GH_REST_STATUS:-000}); it is not sent again"
      rm -f "$bf"
    fi
  fi
  rc=0
  TRK_SLUG="$slug" trk_gh_close_completed "$n" >/dev/null 2>&1 || rc=$?
  st=""
  if [ "$rc" = 0 ]; then _pbs_issue_state "$slug" "$n" && st="$_PBS_ST"; fi
  if [ "$st" = closed ]; then
    : > "$rec/plan-blocked.closed"
    _pbs_say "skipping $key: PLAN_BLOCKED done $sha — ticket #$n closed (completed), not re-queued"
    return 1
  fi
  _pbs_say "skipping $key: PLAN_BLOCKED done $sha — the close of #$n did not take (rc $rc, read '${st:-none}'); retried next tick, no machine"
  if [ ! -e "$rec/plan-blocked.alerted" ]; then
    [ -x "$r/bin/alert-line.sh" ] && HARNESS="$r" "$r/bin/alert-line.sh" \
      "[pool/$p] $key: PLAN_BLOCKED already done on main by $sha, but closing $slug#$n failed (rc $rc, read '${st:-none}'); retried each tick with no machine and no second comment" >/dev/null 2>&1
    : > "$rec/plan-blocked.alerted"
  fi
  return 1
}

# _pbs_after_state <root> <p> <key> <record> <slug> <ticket> <keys> — rc 0
# released, rc 1 refused this tick.
_pbs_after_state() {
  local r="$1" p="$2" key="$3" rec="$4" slug="$5" ticket="$6" keys="$7" k n st rc open="" unread="" mt ans
  if [ ! -e "$rec/plan-blocked.after" ]; then
    for k in $keys; do printf 'After: %s\n' "$k"; done > "$rec/plan-blocked.after" 2>/dev/null
  fi
  for k in $keys; do
    n="${k##*-}"; rc=0
    _pbs_issue_state "$slug" "$n" || rc=$?; st="$_PBS_ST"
    case "$rc:$st" in
      0:closed) ;;
      0:open) open="${open:+$open }$k" ;;
      44:*) _pbs_say "$key: prerequisite $k is not an issue on $slug (404) — not waited on" ;;
      *) unread="${unread:+$unread }$k" ;;
    esac
  done
  if [ -n "$unread" ]; then
    _pbs_say "skipping $key: PLAN_BLOCKED after $keys — could not read $unread; retried next tick, no machine"
    return 1
  fi
  if [ -z "$open" ]; then
    : > "$rec/plan-blocked.released"
    _pbs_say "RELEASED $key: PLAN_BLOCKED after $keys — all closed"
    return 0
  fi
  mt=$(stat -c %Y "$rec/RESULT" 2>/dev/null) || mt=""
  if [ -n "$mt" ] && command -v _pb_answers_since >/dev/null 2>&1; then
    ans=$(HARNESS="$r" _pb_answers_since "$slug" "$ticket" "$mt" 2>/dev/null) || ans=""
    case "$ans" in ''|*[!0-9]*|0) ;; *)
      : > "$rec/plan-blocked.released"
      _pbs_say "RELEASED $key: PLAN_BLOCKED after $keys — $open still open, but a person answered on #$ticket since the stop"
      return 0 ;;
    esac
  fi
  _pbs_say "skipping $key: PLAN_BLOCKED after $keys — waits, no machine ($open open)"
  return 1
}

# _pbs_cap <root> <p> <key> <ticket> <newest> <slug> <base> — rc 0 under the
# cap or lifted, rc 1 refused (with ONE NEEDS_HUMAN hold per episode).
_pbs_cap() {
  local r="$1" p="$2" key="$3" ticket="$4" newest="$5" slug="$6" base="$7" max win now n=0 d mt lifted=0 lf le
  local marker asked lep q body fp hrc
  max=$(_pbs_int "${POOL_PLAN_BLOCKED_MAX:-2}" 2) # knob POOL_PLAN_BLOCKED_MAX (catalog/lanes.d/fly-pool.knobs.d)
  [ "$max" -gt 0 ] || return 0
  win=$(_pbs_win); now=$(_pbs_now)
  for lf in "$r/builds/pool-$p-$key-"*/plan-blocked.lifted; do
    [ -f "$lf" ] || continue
    le=$(head -1 "$lf" 2>/dev/null); case "$le" in ''|*[!0-9]*) continue ;; esac
    [ "$le" -gt "$lifted" ] && lifted=$le
  done
  for d in "$r/builds/pool-$p-$key-"*; do
    _pbs_is_pb "$d" || continue
    mt=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    [ $((now - mt)) -le "$win" ] || continue
    [ "$mt" -gt "$lifted" ] || continue
    [ "$(_pbs_classify "$r" "$p" "$key" "$d" "$slug" "$base" "$ticket")" = other ] || continue
    n=$((n + 1))
  done
  [ "$n" -ge "$max" ] || return 0
  _pbs_say "skipping $key: PLAN_BLOCKED other ${n}x in ${win}s (cap $max) — NEEDS_HUMAN"
  command -v _ee_lift_epoch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/execute-empty.sh" 2>/dev/null
  marker="$newest/plan-blocked.asked"
  if [ -e "$marker" ]; then
    asked=$(head -1 "$marker" 2>/dev/null); case "$asked" in ''|*[!0-9]*) asked=$(stat -c %Y "$marker" 2>/dev/null || echo 0) ;; esac
    lep=""; command -v _ee_lift_epoch >/dev/null 2>&1 && lep=$(_ee_lift_epoch "$p" "$ticket" "$asked")
    [ -n "$lep" ] || return 1
    printf '%s\n' "$lep" > "$newest/plan-blocked.lifted" 2>/dev/null
    _pbs_say "$key: the NEEDS_HUMAN ask on ticket #$ticket was answered — the PLAN_BLOCKED count is reset and the key may spawn"
    return 0
  fi
  q=$(HARNESS="$r" pb_excerpt "$newest/plan.md" 2>/dev/null | head -1)
  command -v _ee_defang >/dev/null 2>&1 && q=$(printf '%s' "$q" | _ee_defang)
  q="${q:0:300}"; [ -n "$q" ] || q="(no blocked section in the plan; see plan.md in the hub record ${newest##*/})"
  # No hold or lift words of bin/lib/hold.sh in the ask (the BH-5911 rule):
  # the question is defanged, and the fixed text names none of them.
  body="NEEDS_HUMAN: the plan stage of $key stopped $n times in the last $((win / 3600)) h with a question the ticket does not answer, so the pool stops relaunching it. Last question: $q. Answer it on this ticket, then comment the word resume in capital letters."
  fp=$(printf '%s' "plan-blocked:$p:$key" | sha1sum 2>/dev/null | cut -c1-12)
  hrc=1
  [ -x "$r/bin/needs-human-hold.sh" ] && { hrc=0; HARNESS="$r" "$r/bin/needs-human-hold.sh" "$p" "$ticket" "$fp" "$body" plan-blocked >/dev/null 2>&1 || hrc=$?; }
  if [ "$hrc" = 0 ]; then
    printf '%s\n' "$now" > "$marker"; rm -f "$newest/plan-blocked.alerted" 2>/dev/null
  elif [ ! -e "$newest/plan-blocked.alerted" ]; then
    [ -x "$r/bin/alert-line.sh" ] && HARNESS="$r" "$r/bin/alert-line.sh" \
      "[pool/$p] $key: NEEDS_HUMAN — PLAN_BLOCKED $n times in ${win}s; the hold on ticket #$ticket could not be placed (rc $hrc), the key is still not relaunched. $body" >/dev/null 2>&1
    : > "$newest/plan-blocked.alerted"
  fi
  return 1
}

pbs_stop_check() { # pbs_stop_check <project> <key> <ticket> [job-file]
  local p="${1:-}" key="${2:-}" ticket="${3:-}" r on newest slug base cls
  r=$(_pbs_root); [ -n "$r" ] && [ -n "$p" ] && [ -n "$key" ] || return 0
  on=$(_pbs_int "${POOL_PLAN_BLOCKED_STOP:-1}" 1) # knob POOL_PLAN_BLOCKED_STOP (catalog/lanes.d/fly-pool.knobs.d)
  [ "$on" -gt 0 ] || return 0
  case "$ticket" in ''|*[!0-9]*) return 0 ;; esac
  newest=$(_pbs_newest "$r" "$p" "$key")
  [ -n "$newest" ] && _pbs_is_pb "$newest" || return 0
  [ -e "$newest/plan-blocked.released" ] || [ -e "$newest/plan-blocked.closed" ] && return 0
  command -v tracker_kind >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/tracker.sh" 2>/dev/null
  command -v tracker_kind >/dev/null 2>&1 || return 0
  # In this shell first, so the per-process cache is warm for the $( ) read.
  tracker_kind "$p" >/dev/null 2>&1 || return 0
  [ "$(tracker_kind "$p" 2>/dev/null)" = github-issues ] || return 0
  slug=$("$r/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
  command -v gh_rest_issue_state >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-rest.sh" 2>/dev/null
  command -v pb_excerpt >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/plan-blocked.sh" 2>/dev/null
  command -v trk_gh_close_completed >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/tracker/github-issues.sh" 2>/dev/null
  command -v gh_rest_issue_state >/dev/null 2>&1 && command -v pb_excerpt >/dev/null 2>&1 \
    && command -v trk_gh_close_completed >/dev/null 2>&1 || return 0
  base=$(_pbs_base "$r" "$p")
  cls=$(_pbs_classify "$r" "$p" "$key" "$newest" "$slug" "$base" "$ticket")
  case "$cls" in
    "done "*) _pbs_close_done "$r" "$p" "$key" "$newest" "$slug" "$ticket" "${cls#done }"; return $? ;;
    "after "*) _pbs_after_state "$r" "$p" "$key" "$newest" "$slug" "$ticket" "${cls#after }"; return $? ;;
  esac
  _pbs_cap "$r" "$p" "$key" "$ticket" "$newest" "$slug" "$base"
}
