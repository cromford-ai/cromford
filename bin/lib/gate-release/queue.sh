#!/bin/bash
# bin/lib/gate-release/queue.sh — BH-3828 (slice 2 of #3825): release
# merge-gated READY-QUEUE lines. A part file of bin/lib/gate-release.sh, which
# sources it; bin/gate-release.sh calls gr_release_queue once per triage tick.
#
# WHY. TK-2186's queue line said `LAUNCH-QUEUE gate: TK-2185 ... merged`.
# TK-2185 merged at 16:03Z and the line sat there until an operator launched
# TK-2186 by hand at 17:47Z. This pass does what the operator did: notice every
# blocker merged, check nobody owns the key, launch run-build.sh, take the line
# off the queue and say so.
#
# SHIPS DARK. GATE_RELEASE_MAX_LAUNCHES falls back to 0, and at 0 the pass
# returns before it reads the queue: no GitHub read, no write, no log line. One
# settings row (lib.gate-release.GATE_RELEASE_MAX_LAUNCHES) turns it on.
#
# PER LINE, every check fails closed (anything unreadable = leave the line):
#   own project only; gr_parse_gate rc 0 (prose is skipped silently); not
#   already released for this exact line (released/<KEY> holds the sha of the
#   timestamp-normalised line); gr_owned (builds pause, build-key flock,
#   INFLIGHT, an owner RESULT, closed ticket); every blocker gr_key_merged;
#   triage-gate.sh --buildable-strict says OK; free-slots.sh has a slot
#   (else GATE_RELEASE_WAIT once per GATE_RELEASE_REMIND_S); under the cap.
# RELEASE ORDER: marker, launch, queue-line-drop.sh, GATE_RELEASED log line
# (also printed, so the driver counts one action). A failed marker write
# launches nothing. Over the cap the line is kept for the next pass.
#
# STATE under state/gate-release/<p>/: released/<KEY> (sha), noted/<KEY>
# (log-once for SKIP), wait/<KEY> (WAIT window, by mtime). Root comes only
# from the <harness> argument.
# shellcheck shell=bash

for _grq_f in ready-queue.sh lock-hygiene.sh pause.sh; do
  case "$_grq_f" in
    ready-queue.sh) declare -F rq_lines >/dev/null 2>&1 && continue ;;
    lock-hygiene.sh) declare -F lock_spawn_unheld >/dev/null 2>&1 && continue ;;
    pause.sh) declare -F pause_active >/dev/null 2>&1 && continue ;;
  esac
  # shellcheck source=/dev/null
  [ -r "$_GR_LIBDIR/$_grq_f" ] && . "$_GR_LIBDIR/$_grq_f"
done
unset _grq_f

# _grq_log <harness> <project> <text> — one line in logs/<p>.log.
_grq_log() {
  local now="${GR_NOW:-$(date +%s)}"
  printf '%s [%s] %s\n' "$(date -u -d "@$now" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null)" "$2" "$3" \
    >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

# _grq_note_once <state-dir> <KEY> <tag> <harness> <project> <text> — log
# <text> unless noted/<KEY> already holds <tag> (key + line sha + reason).
_grq_note_once() {
  local f="$1/noted/$2"
  [ "$(cat "$f" 2>/dev/null)" = "$3" ] && return 0
  mkdir -p "$1/noted" 2>/dev/null && printf '%s\n' "$3" > "$f" 2>/dev/null
  _grq_log "$4" "$5" "$6"
}

# gr_owned <harness> <project> <KEY> <fallback-id> <sha> — rc 0 when the key is
# FREE, with the board ticket id in _GRQ_ID; rc 1 when anything owns it or a
# check cannot be read.
gr_owned() {
  local h="$1" p="$2" k="$3" fb="$4" sha="$5" s nr word
  _GRQ_ID=""
  s=$(gr_state_dir "$h" "$p") || return 1
  declare -F pause_active >/dev/null 2>&1 || return 1
  pause_active "$p" builds && return 1
  command -v flock >/dev/null 2>&1 || return 1
  # Probe only: the lock is released as the subshell exits, never held across
  # the launch (locks are dedupe, not a queue).
  ( flock -n 7 ) 7>"$h/locks/build-key-$p-$k.lock" 2>/dev/null || return 1
  if nr=$(gr_newest_result "$h" "$p" "$k"); then
    word="${nr#*$'\t'}"; word="${word%% *}"
    case "$word" in
      INFLIGHT) return 1 ;;
      PR_CREATED|PR_MERGED|DECOMPOSED|ROLLOUT_FILED|WEBTASK_QUEUED)
        _grq_note_once "$s" "$k" "$sha owner $word" "$h" "$p" "GATE_RELEASE_SKIP $k: $word already owns it"
        return 1 ;;
    esac
  fi
  if ! _GRQ_ID=$(gr_ticket_id "$h" "$p" "$k" "$fb"); then
    _GRQ_ID=""
    if jq -e 'type == "object"' "$h/state/$p.keymap.json" >/dev/null 2>&1; then
      _grq_note_once "$s" "$k" "$sha closed" "$h" "$p" "GATE_RELEASE_SKIP $k: ticket closed"
    fi
    return 1
  fi
  [ -n "$_GRQ_ID" ] || return 1
  return 0
}

# gr_release_queue <harness> <project> — one pass over the ready queue.
gr_release_queue() {
  local h="${1:-}" p="${2:-}" s lines line lp key fb blockers b sha n=0 out mo pr why
  local now slots wf mt tmp
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _gr_knobs
  [ "$_GR_MAXLAUNCH" -gt 0 ] 2>/dev/null || return 0
  declare -F rq_lines >/dev/null 2>&1 && declare -F lock_spawn_unheld >/dev/null 2>&1 || return 0
  command -v setsid >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || return 0
  s=$(gr_state_dir "$h" "$p") && [ -d "$s" ] || return 0
  now="${GR_NOW:-$(date +%s)}"
  lines=$(rq_lines "$h" "$p" 2>/dev/null) || lines=""
  while IFS= read -r line; do
    [ "$n" -lt "$_GR_MAXLAUNCH" ] || break
    [[ $line =~ ^[A-Z]+-[0-9]+[[:space:]] ]] || continue
    if [[ $line =~ project=([a-z-]+) ]]; then lp="${BASH_REMATCH[1]}"
    else lp=$("$h/bin/project-of.sh" "$line" 2>/dev/null) || lp=""; fi
    [ "$lp" = "$p" ] || continue
    read -r key fb _ <<<"$line"
    blockers=$(gr_parse_gate "$line") || continue
    sha=$(printf '%s' "$line" | sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g' \
      | sha256sum | awk '{print $1}')
    [ -n "$sha" ] || continue
    [ "$(cat "$s/released/$key" 2>/dev/null)" = "$sha" ] && continue
    gr_owned "$h" "$p" "$key" "$fb" "$sha" || continue
    # gr_key_merged runs in THIS shell (its lookup cap spans the pass), so its
    # answer goes through a file, not $( ).
    mkdir -p "$s/.tmp" 2>/dev/null || continue
    tmp="$s/.tmp/merged.$$"
    why=""
    for b in $blockers; do
      gr_key_merged "$h" "$p" "$b" > "$tmp" 2>/dev/null || { why=""; break; }
      mo=$(cat "$tmp" 2>/dev/null); pr="${mo%%$'\t'*}"
      why="${why:+$why, }$b merged${pr:+ (#$pr)}"
    done
    rm -f "$tmp"
    [ -n "$why" ] || continue
    out=$("$h/bin/triage-gate.sh" "$p" --buildable-strict "$_GRQ_ID" 2>/dev/null) || out=""
    [ "$out" = OK ] || continue
    slots=$("$h/bin/free-slots.sh" "$p" 2>/dev/null) || slots=""
    read -r slots _ <<<"$slots"
    case "$slots" in
      unlimited) ;;
      ''|*[!0-9]*|0)
        wf="$s/wait/$key"
        mt=$(stat -c %Y "$wf" 2>/dev/null) || mt=0
        if [ ! -e "$wf" ] || [ $(( now - mt )) -ge "$_GR_REMIND" ] 2>/dev/null; then
          mkdir -p "$s/wait" 2>/dev/null && : > "$wf" && touch -d "@$now" "$wf" 2>/dev/null
          _grq_log "$h" "$p" "GATE_RELEASE_WAIT $key: no free slot"
        fi
        continue ;;
    esac
    mkdir -p "$s/released" 2>/dev/null && printf '%s\n' "$sha" > "$s/released/$key" 2>/dev/null || continue
    HARNESS="$h" lock_spawn_unheld setsid "$h/bin/run-build.sh" "$p" "$_GRQ_ID" "$key" \
      > "$h/logs/$p.${key,,}-gate-release.out" 2>&1
    HARNESS="$h" "$h/bin/queue-line-drop.sh" "$key" >/dev/null 2>&1
    _grq_log "$h" "$p" "GATE_RELEASED $key: $why"
    printf 'GATE_RELEASED %s: %s\n' "$key" "$why"
    n=$((n + 1))
  done <<<"$lines"
  return 0
}
