#!/bin/bash
# bin/lib/triage-repeat-park.sh — BH-9818: the first `call-guard repeat`
# refusal of a triage shard parks its key, releases its queue line and posts
# one plain board comment. The dispatcher then starts no shard for that key
# until the ticket's board entry changes. Sourced, never executed: functions
# only, no `set -e`, no `exit`, nothing runs or prints at source time.
#
# WHY. project-6-os, 2026-11-18: shards 3788, 3797, 3814, 3819 ... ended
# rc 74 `AGENT_CALL_REFUSED call-guard repeat` on 7 of 10 runs for 7 days.
# The paid calls gave a result ("skip"), but a `queued` build_queue row (QDIRS)
# kept the key in shard scope on every tick. The BH-3949 park (triage_state
# `hold`) stops board-only keys only (bin/lib/triage-state.sh ts_unit_skip),
# and the BH-9286 in-a-row counter hashes queue text that changes on every
# watchdog re-queue. This park is local files, read by the dispatcher itself
# for every unit class (bin/lib/rt/shards.sh, block `repeat park`).
#
#   trp_on_repeat <harness> <project> <KEY> <cg_fp> <mark> <queue-text> <gh>
#     bin/triage-shard.sh's `call-guard repeat` arm only, after the BH-9286
#     note. In order: write the park file FIRST; drop the READY line(s) and
#     ready row(s) through bin/queue-line-drop.sh; one D1 lifecycle_note; one
#     comment per (KEY, board identity) through the tracker seam
#     (bin/lib/tracker.sh), `.commented` only after rc 0, else one warn
#     bin/alert-line.sh line; one project-log line. Always rc 0.
#   trp_parked <harness> <project> <KEY> <gh>
#     The dispatcher. rc 0 = parked, start no shard; rc 1 = dispatch. Local
#     files only (0 network reads). The board identity moved: with rebase=1
#     (our own comment on an in-app board) the move is absorbed once; else the
#     park and `.commented` are deleted and the key dispatches.
#     BH-9863: the board identity is unchanged but the queue-state signature
#     (column 6, triage_shard_qsig) moved: the blocker's build ended, its PR
#     merged or closed, or this key got a new record. The park is deleted,
#     `.commented` stays (the same board state gets no second comment), and
#     the key dispatches. An equal, `-` or missing column 6 stays parked.
#   trp_prune <harness> <project>
#     Deletes park and commented files older than TRIAGE_REPEAT_PARK_KEEP_S.
#   trp_reason <harness> <project> <KEY>
#     The park's reason column, or rc 1 (bin/lib/stuckqueue-escalate.sh).
#
# FILE state/triage-repeat/<p>/<KEY>.park, one TSV line:
#   <bid>\t<cg_fp>\t<epoch>\t<rebase 0|1>\ttriage-repeat-refused: <mark>\t<qsig>
# <qsig> (BH-9863) is triage_shard_qsig (bin/lib/triage-shards-lib.sh) at the
# park, or `-`; a park written before BH-9863 has 5 columns.
# <bid> is the first 16 hex of the sha256 of this ticket's own entry in the
# live board fingerprint (_tsh_fp_pending, bin/lib/triage-shards-lib.sh), or
# `unknown`. Not the call-guard fp: that one also hashes the queue line, which
# this park drops, so a park keyed on it would release itself at once.
#
# KNOBS (catalog/lanes.d/_lib.triage-repeat-park.json, through lib_env_apply;
# the numbers below are the documented fallback only):
#   TRIAGE_REPEAT_PARK (1, 0 = off)   TRIAGE_REPEAT_PARK_KEEP_S (2592000)
# shellcheck shell=bash
if [ -n "${TRIAGE_REPEAT_PARK_LIB:-}" ]; then return 0 2>/dev/null; fi
TRIAGE_REPEAT_PARK_LIB=1
_TRP_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_TRP_APPLIED=0

# _trp_knobs <project> — sets _TRP_ON/_TRP_KEEP in THIS shell; the settings
# contract is applied once per process (queue-closed.sh's idiom).
_trp_knobs() {
  if [ "$_TRP_APPLIED" = 0 ]; then
    _TRP_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_TRP_LIBDIR/lane-gate.sh" ] && . "$_TRP_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-repeat-park "${1:-}"
  fi
  # Fallbacks name their rows in catalog/lanes.d/_lib.triage-repeat-park.json.
  _TRP_ON="${TRIAGE_REPEAT_PARK:-1}"
  _TRP_KEEP="${TRIAGE_REPEAT_PARK_KEEP_S:-2592000}"
  case "$_TRP_ON" in 0|1) ;; *) _TRP_ON=1 ;; esac
  case "$_TRP_KEEP" in ''|*[!0-9]*) _TRP_KEEP=2592000 ;; esac
  # The catalog min/max: lib_env_apply clamps only operator rows, so an
  # env-file value lands here raw. 10# reads "08" as 8, not as octal.
  _TRP_KEEP=$((10#$_TRP_KEEP))
  [ "$_TRP_KEEP" -lt 86400 ] && _TRP_KEEP=86400
  [ "$_TRP_KEEP" -gt 7776000 ] && _TRP_KEEP=7776000
  return 0
}

_trp_log() { # _trp_log <harness> <project> <text>
  mkdir -p "$1/logs" 2>/dev/null
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" "$3" >> "$1/logs/$2.log" 2>/dev/null || true
}

_trp_key_ok() { [[ ${1:-} =~ ^[A-Za-z0-9._-]+$ ]]; }

# _trp_bid <harness> <project> <KEY> <gh> -> 16 hex, or rc 1. The ticket's own
# entry in state/<p>.gate.pending (gate.json as the fallback); `pend absent`
# is a stable answer, so a ticket that left the board has a bid too.
_trp_bid() {
  local pend
  if ! command -v _tsh_fp_pending >/dev/null 2>&1; then
    # shellcheck source=bin/lib/triage-shards-lib.sh
    [ -r "$1/bin/lib/triage-shards-lib.sh" ] && . "$1/bin/lib/triage-shards-lib.sh" 2>/dev/null
  fi
  command -v _tsh_fp_pending >/dev/null 2>&1 || return 1
  pend=$(_tsh_fp_pending "$1" "$2" "$3" "${4:-0}" 2>/dev/null) || return 1
  [ -n "$pend" ] || return 1
  printf '%s' "$pend" | sha256sum 2>/dev/null | cut -c1-16
}

# _trp_qsig <harness> <project> <KEY> <gh> -> 16 hex (triage_shard_qsig), or rc 1.
_trp_qsig() {
  local q
  if ! command -v triage_shard_qsig >/dev/null 2>&1; then
    # shellcheck source=bin/lib/triage-shards-lib.sh
    [ -r "$1/bin/lib/triage-shards-lib.sh" ] && . "$1/bin/lib/triage-shards-lib.sh" 2>/dev/null
  fi
  command -v triage_shard_qsig >/dev/null 2>&1 || return 1
  q=$(triage_shard_qsig "$1" "$2" "$3" "${4:-0}" 2>/dev/null) || return 1
  [[ "$q" =~ ^[0-9a-f]{16}$ ]] || return 1
  printf '%s' "$q"
}

# _trp_write <file> <line> — tmp + mv; rc 1 when it could not be written.
_trp_write() {
  mkdir -p "${1%/*}" 2>/dev/null || return 1
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null && return 0
  rm -f "$1.tmp.$$" 2>/dev/null
  return 1
}

# _trp_tracker_id <harness> <project> <KEY> <gh> -> the id tracker_comment takes
_trp_tracker_id() {
  local id=""
  if [ "${4:-0}" = 1 ]; then
    id=$(printf '%s' "$3" | sed -nE 's/^([A-Za-z]+-)?([0-9]+)$/\2/p')
  elif [ -s "$1/state/$2.keymap.json" ] && command -v jq >/dev/null 2>&1; then
    id=$(jq -r --arg k "$3" '.[$k] // "" | tostring' "$1/state/$2.keymap.json" 2>/dev/null)
  fi
  case "$id" in ''|null|-|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$id"
}

trp_on_repeat() {
  local h="${1:-}" p="${2:-}" k="${3:-}" cgfp="${4:-}" mark="${5:-}" qtext="${6-}" gh="${7:-0}"
  local d bid why now old keys label drop cm cmf id paid max tag ln rc qsig
  [ -n "$h" ] && [ -n "$p" ] && _trp_key_ok "$k" || return 0
  _trp_knobs "$p"
  [ "$_TRP_ON" = 1 ] || return 0
  d="$h/state/triage-repeat/$p"
  bid=$(_trp_bid "$h" "$p" "$k" "$gh") || bid=""
  case "$bid" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) bid=unknown ;; esac
  case "$cgfp" in ''|*[!A-Za-z0-9]*) cgfp=- ;; esac
  why="triage-repeat-refused: $(printf '%s' "$mark" | tr -d '\t\r\n' | cut -c1-160)"
  qsig=$(_trp_qsig "$h" "$p" "$k" "$gh") || qsig=-
  # 1. THE PARK, WRITTEN FIRST. A park already on this board identity is kept
  # as it is (its rebase flag and epoch too): a second refusal is not a change.
  now=$(date +%s)
  old=$(cut -f1 "$d/$k.park" 2>/dev/null | head -1)
  if [ "$old" != "$bid" ] || [ ! -s "$d/$k.park" ]; then
    _trp_write "$d/$k.park" "$(printf '%s\t%s\t%s\t0\t%s\t%s' "$bid" "$cgfp" "$now" "$why" "$qsig")" \
      || { _trp_log "$h" "$p" "triage-repeat: $k NOT parked: could not write state/triage-repeat/$p/$k.park"; return 0; }
  fi
  # 2. THE QUEUE LINE. The raw line keys of this shard's queue text (the BH-38
  # key-first rule, as _qc_rawkeys), else the KEY itself. bin/queue-line-drop.sh
  # removes the READY-QUEUE line(s) and the D1 `ready` row(s); a `queued`
  # build_queue row stays for its lifecycle owner, and the park above keeps it
  # out of shard scope.
  keys=$(printf '%s\n' "$qtext" | sed 's/^\[HOTFIX\] //' \
    | sed -nE 's/^([A-Za-z]+-[0-9]+)([^0-9].*)?$/\1/p' | awk '!s[$0]++' | tr '\n' ' ')
  keys=${keys% }
  [ -n "$keys" ] || keys="$k"
  label=${keys%% *}
  # shellcheck disable=SC2086 # keys is a list of validated ticket keys
  if drop=$(HARNESS="$h" "$h/bin/queue-line-drop.sh" $keys 2>&1); then :; else drop="drop failed (${drop:-no output})"; fi
  drop=$(printf '%s' "$drop" | tr '\n' ' ' | cut -c1-200)
  # 3. THE D1 RECORD of the park (ticket_events, deduped by the worker on the
  # same reason). rc 2 (no row) and rc 1 (outage) are logged, nothing else.
  paid=$(printf '%s' "$mark" | sed -nE 's#.* paid=([0-9]+)/([0-9]+).*#\1#p')
  max=$(printf '%s' "$mark" | sed -nE 's#.* paid=([0-9]+)/([0-9]+).*#\2#p')
  rc=$( { command -v _jobs_req >/dev/null 2>&1 || command -v lifecycle_note >/dev/null 2>&1 \
          || . "$h/bin/jobs-client.sh"; } >/dev/null 2>&1 </dev/null
        # lifecycle.sh is not a jobs-client module (bin/jobs-watchdog.sh loads it the same way).
        # shellcheck source=bin/lib/jobs/lifecycle.sh
        command -v lifecycle_note >/dev/null 2>&1 || . "$h/bin/lib/jobs/lifecycle.sh" >/dev/null 2>&1
        command -v lifecycle_note >/dev/null 2>&1 || { echo skip; exit 0; }
        lifecycle_note "$p" "$label" triage "triage-repeat-refused: call-guard paid=${paid:-?}/${max:-?} fp=$cgfp" >/dev/null 2>&1 </dev/null
        echo $? )
  case "$rc" in 0|skip) ;; *) _trp_log "$h" "$p" "triage-repeat: $k lifecycle note not recorded (rc $rc)" ;; esac
  # 4. ONE COMMENT per (KEY, board identity). `.commented` only after rc 0.
  if [ "$(head -1 "$d/$k.commented" 2>/dev/null)" = "$bid" ]; then
    cm="skipped (already posted)"
  else
    cm=FAILED; tag=""
    if id=$(_trp_tracker_id "$h" "$p" "$k" "$gh"); then
      cmf=$(mktemp "${TMPDIR:-/tmp}/trp-comment.XXXXXX" 2>/dev/null) || cmf=""
      if [ -n "$cmf" ]; then
        cat > "$cmf" <<'BODY'
<!-- harness-status: results-sweep -->
We paused triage on this ticket. Triage already ran twice on this exact ticket state and could not move it forward, so our cost guard refused a third run.
No code was written and no build started.
To start it again, add a comment with the next step, or edit the ticket body. Either change gives the ticket a new state, and triage then runs one more time.
BODY
        if ( HARNESS="$h"
             command -v tracker_comment >/dev/null 2>&1 || . "$h/bin/lib/tracker.sh" >/dev/null 2>&1
             tracker_context "$p" triage-repeat-park >/dev/null 2>&1 </dev/null \
               && tracker_comment "$id" "$cmf" >/dev/null 2>&1 </dev/null ); then
          cm=posted
          _trp_write "$d/$k.commented" "$bid" || :
          # An in-app board counts our comment in the board entry, so the next
          # look absorbs one move. GitHub boards hide our App's own comment
          # already (gate_self_absorb), so there is nothing to absorb there.
          if [ "$gh" != 1 ] && [ "$(cut -f1 "$d/$k.park" 2>/dev/null)" = "$bid" ]; then
            ln=$(head -1 "$d/$k.park")
            _trp_write "$d/$k.park" "$(printf '%s' "$ln" | awk -F'\t' 'BEGIN{OFS="\t"} {$4=1; print}')" || :
          fi
        else
          tag="the tracker refused the comment"
        fi
        rm -f "$cmf"
      else
        tag="no temp file for the comment body"
      fi
    else
      tag="no tracker id for $k"
    fi
    if [ "$cm" = FAILED ]; then
      HARNESS="$h" "$h/bin/alert-line.sh" --severity warn --id "triage-repeat-comment-$p-$k" --project "$p" \
        "[triage-repeat] $p $k parked (call-guard repeat), but the board comment was NOT posted: $tag. The ticket gets no shard until its board entry changes; post the note by hand if the client must know." \
        >/dev/null 2>&1 </dev/null || :
    fi
  fi
  _trp_log "$h" "$p" "triage-repeat: $k parked (triage-repeat-refused, fp $cgfp, board $bid) — queue: $drop; comment: $cm"
  return 0
}

trp_parked() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" d f ln pb rb cur pq cq
  [ -n "$h" ] && [ -n "$p" ] && _trp_key_ok "$k" || return 1
  _trp_knobs "$p"
  [ "$_TRP_ON" = 1 ] || return 1
  d="$h/state/triage-repeat/$p"; f="$d/$k.park"
  [ -f "$f" ] || return 1
  ln=$(head -1 "$f" 2>/dev/null)
  pb=$(printf '%s' "$ln" | cut -f1); rb=$(printf '%s' "$ln" | cut -f4)
  case "$pb" in
    unknown) ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) rm -f "$f" "$d/$k.commented" 2>/dev/null
       _trp_log "$h" "$p" "triage-repeat: $k park file unreadable (state/triage-repeat/$p/$k.park) — deleted, dispatching"
       return 1 ;;
  esac
  # No current board identity (no gate file): dispatch. A park nobody can
  # compare must never read as "unchanged".
  cur=$(_trp_bid "$h" "$p" "$k" "$gh") || return 1
  [ -n "$cur" ] || return 1
  if [ "$cur" = "$pb" ]; then
    # BH-9863: the same board entry, but the queue state moved (column 6).
    pq=$(printf '%s' "$ln" | cut -f6)
    if [[ "$pq" =~ ^[0-9a-f]{16}$ ]] && cq=$(_trp_qsig "$h" "$p" "$k" "$gh") && [ "$cq" != "$pq" ]; then
      rm -f "$f" 2>/dev/null
      if [ ! -e "$f" ]; then
        _trp_log "$h" "$p" "triage-repeat: $k unparked: queue state changed (blocker or build record moved)"
        return 1
      fi
    fi
    return 0
  fi
  if [ "$rb" = 1 ]; then
    # Our own comment moved the entry: absorb this one move, keep the park.
    _trp_write "$f" "$(printf '%s' "$ln" | awk -F'\t' -v b="$cur" 'BEGIN{OFS="\t"} {$1=b; $4=0; print}')" || :
    [ -f "$d/$k.commented" ] && _trp_write "$d/$k.commented" "$cur"
    _trp_log "$h" "$p" "triage-repeat: $k still parked: the board entry moved once after our own comment (absorbed)"
    return 0
  fi
  rm -f "$f" "$d/$k.commented" 2>/dev/null
  _trp_log "$h" "$p" "triage-repeat: $k unparked: board entry changed"
  return 1
}

trp_prune() {
  local h="${1:-}" p="${2:-}" d
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _trp_knobs "$p"
  d="$h/state/triage-repeat/$p"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f \( -name '*.park' -o -name '*.commented' \) \
    -mmin +"$(( (_TRP_KEEP + 59) / 60 ))" -delete 2>/dev/null
  return 0
}

trp_reason() {
  local h="${1:-}" p="${2:-}" k="${3:-}" r
  _trp_key_ok "$k" || return 1
  r=$(head -1 "$h/state/triage-repeat/$p/$k.park" 2>/dev/null | cut -f5)
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}
