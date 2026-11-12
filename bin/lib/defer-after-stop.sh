# shellcheck shell=bash
# bin/lib/defer-after-stop.sh — BH-8880: the pool spawns no machine for a key
# whose newest hub record waits on another key's open PR.
# Sourced, never run. Defining functions (and the empty _DFS_SWCAP cache) is its
# only effect at source time.
#
# WHY. project-5 TK-3786 waits on TK-3785 (PR #3958, open since 2026-10-20).
# Each machine planned, saw the same overlap, stood down BUILD_DEFERRED and was
# destroyed; the next tick spawned again, up to the 12-per-24 h cap, every day:
# 196 DEFERRED records, 189 spawns, $14.22 of machine time, 0 builds.
# pool_after_gate holds a row only while its QUEUE FILE carries `after`; a row
# released at the ceiling, or written again, has none, and nothing read the
# BUILD_DEFERRED record before the spawn.
#
# THE RULE
#   dfs_stop_check <project> <key> <ticket>  rc 0 may spawn, rc 1 held this
#       tick (the row stays queued: no QROW write, no deferral, no cap count).
#       The key's NEWEST record (builds/pool-<p>-<key>-*/RESULT, by mtime) must
#       start `BUILD_DEFERRED ` and name a blocker: `After: <KEY>` (the
#       defer_after_key rule), else `OVERLAP_DEFER <key> vs <OTHER>` (any -rN
#       dropped). The blocker is another plain key (no child N.M). The row is
#       held while the blocker has an open PR in the tick's open-PR list
#       (pr_open_for_key_any_rest, one list read per tick). Released when that
#       PR merges or closes, or when a person commented on the ticket since the
#       record (GitHub-Issues projects; <record>/defer-after.released). A mutual
#       wait (the blocker's newest record names this key) is not held here:
#       pool_after_gate and the machine's plan-after decide it. An unreadable
#       list holds the row this tick.
#   Markers in the record dir: defer-after.released (empty; the key may spawn),
#   defer-after.seen (the issue updated_at already read with no person comment,
#   so the same listing reads no comments again).
#   Knob: POOL_DEFER_AFTER_STOP (1; 0 = the gate is off), a fly-pool lane knob
#   (catalog/lanes.d/fly-pool.knobs.d/POOL_DEFER_AFTER_STOP.json).
#
# BH-9283 (project-6 TK-3660: 6 spawns in 50 min on a stack-wait; TK-3577: held
# 5498 min with no limit and counted as queued on the fleet page):
#   - The blocker is read with defer_wait_key (bin/lib/deferral-after.sh), so a
#     `stack-wait: ... ticket/<key>` line and a `Blocked-by #N` line hold too.
#     _dfs_blocker prints a third field, the wait kind: after, stack, blocked.
#   - Wait line state/pool/<p>/<KEY>.dfs-wait, one line:
#     <blocker>\t<kind>\t<since>\t<checks>\t<next_at>\t<alerted_at> (epochs).
#     The clock starts at the first held tick; a new blocker restarts it.
#   - Re-checks of the open-PR list grow: after check c the next is due
#     min(POOL_WAIT_RECHECK_MIN * 2^(c-1), POOL_WAIT_RECHECK_MAX_MIN) minutes
#     later (10, 20, 40, 80, 160, 240, 240 ...). A tick that is not due holds
#     with no read. The person-comment release runs on every held tick.
#   - Time limit: kind stack STACK_WAIT_CAP_H hours (sw_cap), kind after and
#     blocked POOL_AFTER_MAX_MIN minutes (360; 0 = no limit). At the limit the
#     record gets defer-after.released, the clock restarts and the row spawns.
#     One WAIT LIMIT ALERTS line per key and blocker.
#   - A held row writes the BH-1461 <KEY>.held marker (why `defer-after: ...`)
#     and the pool_holds row, so the fleet page counts it as held. A release
#     removes only a marker whose why starts `defer-after:`.
#   The clock is ${DFS_NOW:-now} (tests set DFS_NOW).
# The root is ${HARNESS:-${H:-}}; with none, the gate passes.

_dfs_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }
_DFS_KEY_RE='^[A-Z][A-Z0-9]*-[0-9]+$'

# _dfs_newest <root> <p> <key> -> the record dir whose RESULT mtime is greatest.
_dfs_newest() {
  local f mt nt=-1 newest=""
  for f in "$1/builds/pool-$2-$3-"*/RESULT; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mt" -ge "$nt" ] && { nt=$mt; newest="${f%/RESULT}"; }
  done
  printf '%s' "$newest"
}

# _dfs_blocker <key> <RESULT line 1> -> "<BLK>\t<PR number or empty>\t<kind>";
# rc 1 when the line is not a deferral that names another plain key.
_dfs_blocker() {
  local key="$1" l="$2" b="" kind="" rest n="" w
  case "$l" in "BUILD_DEFERRED "*) ;; *) return 1 ;; esac
  command -v defer_wait_key >/dev/null 2>&1 && w=$(defer_wait_key "$l" "$key" 2>/dev/null) \
    && IFS=$'\t' read -r b kind <<<"$w"
  if [ -z "$b" ] && [[ "$l" =~ ^BUILD_DEFERRED\ OVERLAP_DEFER\ ([^ ]+)\ vs\ ([^ ]+) ]] \
     && [ "${BASH_REMATCH[1]}" = "$key" ]; then
    b="${BASH_REMATCH[2]}"; kind=after
    [[ "$b" =~ ^(.*)-r[0-9]+$ ]] && b="${BASH_REMATCH[1]}"
  fi
  [[ "$b" =~ $_DFS_KEY_RE ]] && [ "$b" != "$key" ] || return 1
  rest="${l#*"$b"}"
  [[ "$rest" =~ PR\ \#([0-9]+) ]] && n="${BASH_REMATCH[1]}"
  printf '%s\t%s\t%s\n' "$b" "$n" "${kind:-after}"
}

_dfs_now() { local n="${DFS_NOW:-}"; case "$n" in ''|*[!0-9]*) n=$(date -u +%s) ;; esac; printf '%s\n' "$n"; }
_dfs_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac; }
# _dfs_pdir <p> -> <root>/state/pool/<p>; rc 1 with no root (nothing is written).
_dfs_pdir() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] && [ -n "${1:-}" ] || return 1; printf '%s/state/pool/%s' "$r" "$1"; }

# _dfs_wait_get <p> <key> -> the .dfs-wait line; rc 1 when there is none.
_dfs_wait_get() {
  local d f; d="$(_dfs_pdir "$1")" || return 1; f="$d/$2.dfs-wait"
  [ -s "$f" ] || return 1
  head -n 1 "$f" 2>/dev/null
}
# _dfs_wait_put <p> <key> <blk> <kind> <since> <checks> <next_at> <alerted_at>
_dfs_wait_put() {
  local d f; d="$(_dfs_pdir "$1")" || return 0; f="$d/$2.dfs-wait"
  mkdir -p "$d" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" "$7" "${8:-}" > "$f.$$" 2>/dev/null \
    && mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$" 2>/dev/null
  return 0
}
_dfs_wait_del() { local d; d="$(_dfs_pdir "$1")" || return 0; rm -f "$d/$2.dfs-wait" 2>/dev/null; return 0; }
# _dfs_wait_load <p> <key> <blk> <kind> <now> — sets _DFS_W_SINCE, _CHECKS,
# _NEXT, _ALERTED and _NEW (1 = no line for this blocker: the clock starts now).
_dfs_wait_load() {
  local v ob ok os oc on oa
  _DFS_W_SINCE="$5"; _DFS_W_CHECKS=0; _DFS_W_NEXT=0; _DFS_W_ALERTED=""; _DFS_W_NEW=1
  v=$(_dfs_wait_get "$1" "$2") || return 0
  # Fields split by hand: tab is IFS white space, so `read` folds empty fields.
  ob="${v%%$'\t'*}"; v="${v#*$'\t'}"; ok="${v%%$'\t'*}"; v="${v#*$'\t'}"
  os="${v%%$'\t'*}"; v="${v#*$'\t'}"; oc="${v%%$'\t'*}"; v="${v#*$'\t'}"
  on="${v%%$'\t'*}"; oa=""; case "$v" in *$'\t'*) oa="${v#*$'\t'}" ;; esac
  [ "$ob" = "$3" ] || return 0
  case "$os" in ''|*[!0-9]*) return 0 ;; esac
  _DFS_W_SINCE="$os"; _DFS_W_CHECKS=$(_dfs_num "$oc" 0); _DFS_W_NEXT=$(_dfs_num "$on" 0)
  _DFS_W_ALERTED=$(_dfs_num "$oa" ""); _DFS_W_NEW=0
}

# _dfs_gap <checks> -> minutes to the next re-check after check <checks>.
_dfs_gap() {
  local c="${1:-1}" b m g i=1
  b=$(_dfs_num "${POOL_WAIT_RECHECK_MIN:-10}" 10)      # knob POOL_WAIT_RECHECK_MIN (catalog/lanes.d/fly-pool.knobs.d)
  m=$(_dfs_num "${POOL_WAIT_RECHECK_MAX_MIN:-240}" 240) # knob POOL_WAIT_RECHECK_MAX_MIN (catalog/lanes.d/fly-pool.knobs.d)
  g=$b
  while [ "$i" -lt "$c" ] && [ "$g" -lt "$m" ]; do g=$((g * 2)); i=$((i + 1)); done
  [ "$g" -gt "$m" ] && g=$m
  printf '%s\n' "$g"
}

# _dfs_limit <p> <kind> -> "<seconds>\t<knob>=<value>"; 0 seconds = no limit.
_dfs_limit() {
  local v
  if [ "$2" = stack ]; then
    if [ -z "${_DFS_SWCAP[$1]:-}" ]; then
      command -v sw_cap >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/stack-wait.sh" 2>/dev/null
      v=""; command -v sw_cap >/dev/null 2>&1 && v=$(sw_cap "$1" 2>/dev/null)
      _DFS_SWCAP[$1]=$(_dfs_num "$v" 24)   # sw_cap's own fallback (knob STACK_WAIT_CAP_H)
    fi
    printf '%s\tSTACK_WAIT_CAP_H=%sh\n' "$(( _DFS_SWCAP[$1] * 3600 ))" "${_DFS_SWCAP[$1]}"
  else
    v=$(_dfs_num "${POOL_AFTER_MAX_MIN:-360}" 360)       # knob POOL_AFTER_MAX_MIN, the pool_after_gate fallback
    printf '%s\tPOOL_AFTER_MAX_MIN=%s\n' "$((v * 60))" "$v"
  fi
}
declare -gA _DFS_SWCAP 2>/dev/null || true

_dfs_stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null; }

# _dfs_held_put <p> <key> <ticket> <why> <now> — the BH-1461 .held marker and,
# once per hold, the pool_holds row. A marker another gate wrote is left alone.
_dfs_held_put() {
  local d mk w first now had=0
  d="$(_dfs_pdir "$1")" || return 0; mk="$d/$2.held"; now=$(_dfs_stamp "$5"); first="$now"
  if [ -f "$mk" ]; then
    w=$(jq -r '.why // empty' "$mk" 2>/dev/null)
    case "$w" in defer-after:*) had=1 ;; *) return 0 ;; esac
    first=$(jq -r '.first_seen // empty' "$mk" 2>/dev/null); [ -n "$first" ] || first="$now"
  fi
  mkdir -p "$d" 2>/dev/null
  jq -nc --arg k "$2" --arg t "$3" --arg w "$4" --arg f "$first" --arg s "$now" \
    '{key:$k,ticket_id:$t,why:$w,first_seen:$f,last_seen:$s}' > "$mk.$$" 2>/dev/null \
    && mv -f "$mk.$$" "$mk" 2>/dev/null || rm -f "$mk.$$" 2>/dev/null
  [ "$had" = 1 ] || { command -v psr_hold_put >/dev/null 2>&1 && { psr_hold_put "$1" ticket "$2" "$3" "" "$4" "$first" || true; }; }
  return 0
}
# _dfs_held_clear <p> <key> — remove the marker this gate wrote, and its row.
_dfs_held_clear() {
  local d mk; d="$(_dfs_pdir "$1")" || return 0; mk="$d/$2.held"
  [ -f "$mk" ] || return 0
  case "$(jq -r '.why // empty' "$mk" 2>/dev/null)" in defer-after:*) ;; *) return 0 ;; esac
  rm -f "$mk" 2>/dev/null
  command -v psr_hold_clear >/dev/null 2>&1 && { psr_hold_clear "$1" ticket "$2" || true; }
  return 0
}

# _dfs_released <p> <key> <ticket> <rec> <blk> <pr text> — rc 0 when a person
# commented on the ticket after the record (marker written), rc 1 otherwise.
_dfs_released() {
  local p="$1" key="$2" ticket="$3" rec="$4" blk="$5" prt="$6" mt u="" ue ans
  case "$ticket" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${POOL_SLUG:-}" ] || return 1
  command -v tracker_kind >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/tracker.sh" 2>/dev/null
  command -v tracker_kind >/dev/null 2>&1 || return 1
  # In this shell first, so the per-process cache is warm for the $( ) read.
  tracker_kind "$p" >/dev/null 2>&1 || return 1
  [ "$(tracker_kind "$p" 2>/dev/null)" = github-issues ] || return 1
  mt=$(stat -c %Y "$rec/RESULT" 2>/dev/null) || return 1
  # The tick's ai-build listing gives "<updated_at>|<comments>" per issue.
  if declare -p _POOL_HOLD_LKEY >/dev/null 2>&1; then u="${_POOL_HOLD_LKEY[$ticket]:-}"; u="${u%%|*}"; fi
  if [ -n "$u" ]; then
    ue=$(date -u -d "$u" +%s 2>/dev/null) || ue=""
    [ -n "$ue" ] && [ "$ue" -le "$mt" ] && return 1
    [ "$u" = "$(head -1 "$rec/defer-after.seen" 2>/dev/null)" ] && return 1
  fi
  command -v _gh_rest_field >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-rest.sh" 2>/dev/null
  command -v _pb_answers_since >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/plan-blocked.sh" 2>/dev/null
  command -v _pb_answers_since >/dev/null 2>&1 && command -v _gh_rest_field >/dev/null 2>&1 || return 1
  ans=$(_pb_answers_since "$POOL_SLUG" "$ticket" "$mt" 2>/dev/null) || ans=""
  case "$ans" in
    ''|*[!0-9]*) return 1 ;;
    0) [ -n "$u" ] && printf '%s\n' "$u" > "$rec/defer-after.seen" 2>/dev/null; return 1 ;;
  esac
  : > "$rec/defer-after.released"
  _dfs_say "RELEASED $key: waits on $blk $prt, but a person commented on #$ticket since the stand-down"
  return 0
}

dfs_stop_check() { # dfs_stop_check <project> <key> <ticket>
  local p="${1:-}" key="${2:-}" ticket="${3:-}" r on rec l1 bl blk n kind prt brec bl2 rc=0
  local now lim lsec lknob waited due why nxt
  r="${HARNESS:-${H:-}}"; [ -n "$r" ] && [ -n "$p" ] && [ -n "$key" ] || return 0
  on="${POOL_DEFER_AFTER_STOP:-1}" # knob POOL_DEFER_AFTER_STOP (catalog/lanes.d/fly-pool.knobs.d)
  [ "$on" = 0 ] && return 0
  [[ "$key" =~ $_DFS_KEY_RE ]] || return 0
  command -v defer_wait_key >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/deferral-after.sh" 2>/dev/null
  rec=$(_dfs_newest "$r" "$p" "$key"); [ -n "$rec" ] || return 0
  l1=$(head -1 "$rec/RESULT" 2>/dev/null)
  bl=$(_dfs_blocker "$key" "$l1") || return 0
  # Split by hand: tab is IFS white space, so `read` folds the empty PR field.
  blk="${bl%%$'\t'*}"; bl="${bl#*$'\t'}"; n="${bl%%$'\t'*}"; kind="${bl#*$'\t'}"
  [ -e "$rec/defer-after.released" ] && return 0
  brec=$(_dfs_newest "$r" "$p" "$blk")
  if [ -n "$brec" ] && bl2=$(_dfs_blocker "$blk" "$(head -1 "$brec/RESULT" 2>/dev/null)") \
     && [ "${bl2%%$'\t'*}" = "$key" ]; then
    _dfs_say "$key: waits on $blk, and $blk waits on $key — not held here"
    return 0
  fi
  command -v pr_open_for_key_any_rest >/dev/null 2>&1 || return 0
  if [ -n "$n" ]; then prt="PR #$n open"; else prt="PR open"; fi
  why="defer-after: waits on $blk $prt ($kind)"
  now=$(_dfs_now)
  _dfs_wait_load "$p" "$key" "$blk" "$kind" "$now"
  # THE TIME LIMIT (BH-9283): no read needed, so it runs before the due check.
  lim=$(_dfs_limit "$p" "$kind"); IFS=$'\t' read -r lsec lknob <<<"$lim"
  if [ "$_DFS_W_NEW" = 0 ] && [ "${lsec:-0}" -gt 0 ] && [ $((now - _DFS_W_SINCE)) -ge "$lsec" ]; then
    waited=$(( (now - _DFS_W_SINCE) / 60 ))
    : > "$rec/defer-after.released"
    if [ -z "$_DFS_W_ALERTED" ]; then
      [ -x "$r/bin/alert-line.sh" ] && HARNESS="$r" "$r/bin/alert-line.sh" "[pool/$p] $key: WAIT LIMIT — waited $waited min for $blk ($prt, kind $kind, $lknob); the hold is released and the ticket is offered again. If $blk is stuck, that is the thing to move." >/dev/null 2>&1
      _DFS_W_ALERTED="$now"
    fi
    _dfs_wait_put "$p" "$key" "$blk" "$kind" "$now" 0 0 "$_DFS_W_ALERTED"
    _dfs_held_clear "$p" "$key"
    _dfs_say "RELEASED $key: wait limit — waited $waited min for $blk ($prt, kind $kind, $lknob); offered again"
    return 0
  fi
  due=1; [ "$_DFS_W_NEW" = 0 ] && [ "$now" -lt "$_DFS_W_NEXT" ] && due=0
  if [ "$due" = 1 ]; then
    pr_open_for_key_any_rest "$blk" || rc=$?
    case "$rc" in
      0) ;;
      1) _dfs_wait_del "$p" "$key"; _dfs_held_clear "$p" "$key"; return 0 ;;
      *) # Unreadable: hold; the wait line and any marker are left as they are,
         # so the next tick reads again.
         _dfs_say "skipping $key: waits on $blk, and the open-PR list did not answer — retried next tick, no machine"
         return 1 ;;
    esac
    _DFS_W_CHECKS=$((_DFS_W_CHECKS + 1))
    _DFS_W_NEXT=$((now + $(_dfs_gap "$_DFS_W_CHECKS") * 60))
    _dfs_wait_put "$p" "$key" "$blk" "$kind" "$_DFS_W_SINCE" "$_DFS_W_CHECKS" "$_DFS_W_NEXT" "$_DFS_W_ALERTED"
  fi
  if _dfs_released "$p" "$key" "$ticket" "$rec" "$blk" "$prt"; then
    _dfs_held_clear "$p" "$key"
    return 0
  fi
  _dfs_held_put "$p" "$key" "$ticket" "$why" "$now"
  nxt=$(date -u -d "@$_DFS_W_NEXT" '+%H:%MZ' 2>/dev/null)
  _dfs_say "skipping $key: waits on $blk $prt — no machine; next re-check ${nxt:-?}"
  return 1
}
