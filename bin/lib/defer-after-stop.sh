# shellcheck shell=bash
# bin/lib/defer-after-stop.sh — BH-8880: the pool spawns no machine for a key
# whose newest hub record waits on another key's open PR.
# Sourced, never run. Defining functions is its only effect at source time.
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

# _dfs_blocker <key> <RESULT line 1> -> "<BLK>\t<PR number or empty>"; rc 1
# when the line is not a deferral that names another plain key.
_dfs_blocker() {
  local key="$1" l="$2" b="" rest n=""
  case "$l" in "BUILD_DEFERRED "*) ;; *) return 1 ;; esac
  command -v defer_after_key >/dev/null 2>&1 && b=$(defer_after_key "$l" 2>/dev/null)
  if [ -z "$b" ] && [[ "$l" =~ ^BUILD_DEFERRED\ OVERLAP_DEFER\ ([^ ]+)\ vs\ ([^ ]+) ]] \
     && [ "${BASH_REMATCH[1]}" = "$key" ]; then
    b="${BASH_REMATCH[2]}"
    [[ "$b" =~ ^(.*)-r[0-9]+$ ]] && b="${BASH_REMATCH[1]}"
  fi
  [[ "$b" =~ $_DFS_KEY_RE ]] && [ "$b" != "$key" ] || return 1
  rest="${l#*"$b"}"
  [[ "$rest" =~ PR\ \#([0-9]+) ]] && n="${BASH_REMATCH[1]}"
  printf '%s\t%s\n' "$b" "$n"
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
  local p="${1:-}" key="${2:-}" ticket="${3:-}" r on rec l1 bl blk n prt brec bl2 rc=0
  r="${HARNESS:-${H:-}}"; [ -n "$r" ] && [ -n "$p" ] && [ -n "$key" ] || return 0
  on="${POOL_DEFER_AFTER_STOP:-1}" # knob POOL_DEFER_AFTER_STOP (catalog/lanes.d/fly-pool.knobs.d)
  [ "$on" = 0 ] && return 0
  [[ "$key" =~ $_DFS_KEY_RE ]] || return 0
  command -v defer_after_key >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/deferral-after.sh" 2>/dev/null
  rec=$(_dfs_newest "$r" "$p" "$key"); [ -n "$rec" ] || return 0
  l1=$(head -1 "$rec/RESULT" 2>/dev/null)
  bl=$(_dfs_blocker "$key" "$l1") || return 0
  IFS=$'\t' read -r blk n <<<"$bl"
  [ -e "$rec/defer-after.released" ] && return 0
  brec=$(_dfs_newest "$r" "$p" "$blk")
  if [ -n "$brec" ] && bl2=$(_dfs_blocker "$blk" "$(head -1 "$brec/RESULT" 2>/dev/null)") \
     && [ "${bl2%%$'\t'*}" = "$key" ]; then
    _dfs_say "$key: waits on $blk, and $blk waits on $key — not held here"
    return 0
  fi
  command -v pr_open_for_key_any_rest >/dev/null 2>&1 || return 0
  pr_open_for_key_any_rest "$blk" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) _dfs_say "skipping $key: waits on $blk, and the open-PR list did not answer — retried next tick, no machine"
       return 1 ;;
  esac
  if [ -n "$n" ]; then prt="PR #$n open"; else prt="PR open"; fi
  _dfs_released "$p" "$key" "$ticket" "$rec" "$blk" "$prt" && return 0
  _dfs_say "skipping $key: waits on $blk $prt — no machine"
  return 1
}
