# shellcheck shell=bash
# bin/lib/parks-write.sh — the WRITERS of the D1 `parks` table (BH-9075,
# BH-9067.3; docs/events-bh-9067/3-parks.md). SOURCED, never run. No side
# effect at source time. It sources bin/lib/jobs/parks.sh on demand.
#
# A park note never blocks a writer. pw_note writes ONE outbox file and tries a
# flush; every verb answers rc 0 whatever the worker did. The outbox
# (state/parks-outbox/, box-local) is the delivery guarantee: a file is deleted
# only after a 200 for exactly the batch it was in.
#
#   pw_note <project> <ck> <source> <state> <head> <reason> <url> <rec> <ticket> <writer> [parked_at]
#       One outbox row, stamped updated_at=now. A row the route would refuse
#       (a bad project, ck or state) is dropped with one log line, so one bad
#       note can never block the batch behind it.
#   pw_flush
#       flock -n locks/parks-outbox.lock (a held lock is rc 0, no send). The
#       oldest files first, PW_BATCH rows per PUT; a failed PUT keeps every
#       file (one throttled log line); a 400 moves that batch to .bad/. Over
#       PW_OUTBOX_MAX files the oldest go and every resolver cursor is deleted,
#       so the next resolver tick backfills from the file sources.
#   pw_queue_park <project> <queue-key> <reason-text> <hotfix true|false>
#       The fly-pool park sites. The reason text maps exactly as br_from_queue
#       maps it (bin/lib/br/discovery.sh); a text it does not park is no note.
#   pw_note_outcome <project> <ck> <outcome>
#       br_set_outcome: ABANDONED and RESOLVED_MERGED note `done`, nothing else.
#   pw_conductor_sync <project> <slug>
#       The conductor tick end: pr-state.tsv rows of <slug> in BLOCKED_HUMAN or
#       RED_TWICE that are new or changed note `parked`; a ck that left those
#       states notes `done`. state/parks-conductor/<project>.tsv holds the
#       fingerprints (ck, state|head|reason|url).
#
# Knobs (catalog/lanes.d/_lib.parks.knobs.d/): PW_ENABLED (1), PW_BATCH (100),
# PW_OUTBOX_MAX (10000); settings rows lib.parks.<env lowercased>.

_pw_root() { _PW_H="${HARNESS:-${H:-}}"; [ -n "$_PW_H" ]; }

# _pw_lib — bin/lib/jobs/parks.sh (pk_knob, parks_put), or rc 1.
_pw_lib() {
  command -v parks_put >/dev/null 2>&1 && return 0
  _pw_root || return 1
  # shellcheck source=jobs/parks.sh
  . "$_PW_H/bin/lib/jobs/parks.sh" 2>/dev/null || return 1
  command -v parks_put >/dev/null 2>&1
}

# _pw_knob <ENV> <fallback> <min> <max>; the fallbacks name their rows:
# PW_ENABLED 1 (lib.parks.pw_enabled), PW_BATCH 100 (lib.parks.pw_batch),
# PW_OUTBOX_MAX 10000 (lib.parks.pw_outbox_max).
_pw_knob() {
  if command -v pk_knob >/dev/null 2>&1; then pk_knob "$@"; return; fi
  local v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  { [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } 2>/dev/null || v=$2
  printf '%s' "$v"
}

_pw_log() {
  _pw_root || return 0
  mkdir -p "$_PW_H/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$_PW_H/logs/parks-write.log" 2>/dev/null
  return 0
}

# _pw_clean <text> [max] — tab, CR and newline as spaces; empty as `-`; cut to max chars.
_pw_clean() {
  local v="${1:-}"
  v=${v//$'\t'/ }; v=${v//$'\r'/ }; v=${v//$'\n'/ }
  v=${v:0:${2:-500}}
  printf '%s' "${v:--}"
}

pw_note() {
  _pw_lib >/dev/null 2>&1 || :
  [ "$(_pw_knob PW_ENABLED 1 0 1)" = 1 ] || return 0
  _pw_root || return 0
  local p ck st d f now pa="${11:--}" line
  p=$(_pw_clean "$1" 64); ck=$(_pw_clean "$2" 200); st="$4"
  case "$pa" in ''|*[!0-9]*) pa=- ;; esac
  if ! [[ $p =~ ^[a-z0-9._-]{1,64}$ && $ck =~ ^[A-Za-z0-9._-]{1,200}$ ]] \
     || { [ "$st" != parked ] && [ "$st" != hotfix ] && [ "$st" != done ]; }; then
    _pw_log "pw_note: dropped a note the route would refuse (project=$p ck=$ck state=$st)"
    return 0
  fi
  now=$(date -u +%s)
  line="$p	$ck	$(_pw_clean "$3" 24)	$st	$(_pw_clean "$5")	$(_pw_clean "$6")	$(_pw_clean "$7")	$(_pw_clean "$8")	$(_pw_clean "$9")	$now	$(_pw_clean "${10}" 64)	$pa"
  d="$_PW_H/state/parks-outbox"
  mkdir -p "$d" 2>/dev/null || return 0
  f="$d/$now-$$-$RANDOM$RANDOM.tsv"
  printf '%s\n' "$line" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
  # A caller that writes many notes (pw_conductor_sync) flushes once at its end.
  [ -n "${_PW_NOFLUSH:-}" ] || pw_flush
  return 0
}

pw_flush() {
  _pw_root || return 0
  local d="$_PW_H/state/parks-outbox" fd max batch n i tmp now last
  local -a files=() chunk=()
  [ -d "$d" ] || return 0
  mkdir -p "$_PW_H/locks" 2>/dev/null
  { exec {fd}>"$_PW_H/locks/parks-outbox.lock"; } 2>/dev/null || return 0
  if ! flock -n "$fd"; then exec {fd}>&-; return 0; fi
  mapfile -t files < <(set +f; LC_ALL=C ls "$d" 2>/dev/null | grep -E '^[0-9]+-[0-9]+-[0-9]+\.tsv$')
  max=$(_pw_knob PW_OUTBOX_MAX 10000 1 1000000)
  if [ "${#files[@]}" -gt "$max" ]; then
    n=$(( ${#files[@]} - max ))
    for ((i = 0; i < n; i++)); do rm -f "$d/${files[$i]}"; done
    files=("${files[@]:$n}")
    # The marker, not a delete in the resolver's state dir: _brp_cursor reads a
    # cursor older than this file as 0, so the next resolver tick backfills.
    date -u +%s > "$d/.dropped-at" 2>/dev/null
    _pw_log "pw_flush: outbox over PW_OUTBOX_MAX=$max — dropped the $n oldest notes and wrote state/parks-outbox/.dropped-at (the resolver reads cursor 0 next tick)"
  fi
  if [ "${#files[@]}" -gt 0 ] && _pw_lib; then
    batch=$(_pw_knob PW_BATCH 100 1 100)
    tmp=$(mktemp "${TMPDIR:-/tmp}/pw-batch.XXXXXX" 2>/dev/null) || tmp=""
    i=0
    while [ -n "$tmp" ] && [ "$i" -lt "${#files[@]}" ]; do
      chunk=("${files[@]:$i:$batch}")
      ( cd "$d" && cat -- "${chunk[@]}" ) > "$tmp" 2>/dev/null
      if parks_put "$tmp" >/dev/null 2>&1; then
        ( cd "$d" && rm -f -- "${chunk[@]}" )
      elif [ "${JOBS_HTTP:-}" = 400 ]; then
        mkdir -p "$d/.bad" 2>/dev/null && ( cd "$d" && mv -f -- "${chunk[@]}" .bad/ ) 2>/dev/null
        _pw_log "pw_flush: the worker refused a batch of ${#chunk[@]} notes (400) — moved to state/parks-outbox/.bad/"
      else
        # One line per hour, not one per note: an outage is many failed flushes.
        now=$(date -u +%s); last=$(tr -dc '0-9' 2>/dev/null < "$d/.fail-log")
        if [ -z "$last" ] || [ $((now - last)) -ge 3600 ] || [ $((now - last)) -lt 0 ]; then
          printf '%s\n' "$now" > "$d/.fail-log" 2>/dev/null
          _pw_log "pw_flush: PUT /api/parks failed (${JOBS_HTTP:+http=}${JOBS_HTTP:-no answer}) — ${#files[@]} notes kept in state/parks-outbox/ for the next flush"
        fi
        break
      fi
      i=$((i + batch))
    done
    [ -n "$tmp" ] && rm -f "$tmp"
  fi
  # .bad/ is bounded by the same cap.
  if [ -d "$d/.bad" ]; then
    mapfile -t files < <(LC_ALL=C ls "$d/.bad" 2>/dev/null)
    n=$(( ${#files[@]} - max ))
    for ((i = 0; i < n; i++)); do rm -f "$d/.bad/${files[$i]}"; done
  fi
  exec {fd}>&-
  return 0
}

# _pw_ck <text> — the resolver's record key shape (br_rkey, bin/lib/br/record.sh).
_pw_ck() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }

pw_queue_park() {
  local p="${1:-}" k="${2:-}" rsn="${3:-}" hf="${4:-false}" why st=parked
  [ -n "$p" ] && [ -n "$k" ] || return 0
  # The same case as br_from_queue, in the same order.
  case "$rsn" in *RUNNER_EXHAUSTED*|*" class=auth"*) return 0 ;; esac
  case "$rsn" in
    *"died "*times*|*"died twice"*) why=pool-died-twice ;;
    *"deferred "*times*) why=pool-deferred-max ;;
    *"spawn cap"*"deferred to a human"*) why=pool-deferred-max ;;
    *) return 0 ;;
  esac
  [ "$hf" = true ] && st=hotfix
  pw_note "$p" "$(_pw_ck "$p-$k")" queue "$st" - "$why" - - "$k" fly-pool -
  return 0
}

pw_note_outcome() {
  case "${3:-}" in
    ABANDONED|RESOLVED_MERGED) pw_note "${1:-}" "${2:-}" - done - - - - - blocked-resolver - ;;
  esac
  return 0
}

# _pw_tkey <project> <record> — the record's own ticket key (br_ticket_key's
# first source, bin/lib/br/keys.sh), or `-`. In a subshell: the conductor never
# gets the resolver's key functions defined in its own namespace.
_pw_tkey() {
  local kr
  case "${2:--}" in -) printf -- -; return 0 ;; esac
  _pw_root || { printf -- -; return 0; }
  # shellcheck source=br/keys.sh
  kr=$( . "$_PW_H/bin/lib/br/keys.sh" 2>/dev/null && br_ticket_key "$1" "$2" "" "" 2>/dev/null ) || kr=""
  printf '%s' "${kr%%$'\t'*}" | grep . || printf -- -
}

pw_conductor_sync() {
  local p="${1:-}" slug="${2:-}" rows="${MC_ROWS:-}" fpf d tmp key st since head _rev _al why url ck fp old rec tk pa
  local -A cur=() prev=()
  [ -n "$p" ] && [ -n "$slug" ] || return 0
  _pw_root || return 0
  [ "$(_pw_knob PW_ENABLED 1 0 1)" = 1 ] || return 0
  [ -n "$rows" ] || rows="$_PW_H/state/merge-conductor/pr-state.tsv"
  d="$_PW_H/state/parks-conductor"; fpf="$d/$p.tsv"
  if [ -r "$fpf" ]; then
    while IFS=$'\t' read -r ck fp; do [ -n "$ck" ] && prev[$ck]=$fp; done < "$fpf"
  fi
  if [ -r "$rows" ]; then
    while IFS=$'\t' read -r key st since head _rev _al why url; do
      case "$key" in "$slug#"*) ;; *) continue ;; esac
      case "$st" in BLOCKED_HUMAN|RED_TWICE) ;; *) continue ;; esac
      ck=$(_pw_ck "$key"); fp="$st|${head:--}|${why:--}|${url:--}"
      cur[$ck]=$fp
      old="${prev[$ck]:-}"
      [ "$old" = "$fp" ] && continue
      rec=-; command -v mc_record_for >/dev/null 2>&1 && rec=$(mc_record_for "$url" 2>/dev/null) && [ -n "$rec" ] || rec=-
      tk=$(_pw_tkey "$p" "$rec")
      case "$since" in ''|*[!0-9]*) pa=- ;; *) pa=$since ;; esac
      _PW_NOFLUSH=1 pw_note "$p" "$ck" conductor parked "${head:--}" "${why:--}" "${url:--}" "$rec" "$tk" merge-conductor "$pa"
    done < "$rows"
  fi
  for ck in "${!prev[@]}"; do
    [ -n "${cur[$ck]:-}" ] && continue
    _PW_NOFLUSH=1 pw_note "$p" "$ck" - done - - - - - merge-conductor -
  done
  pw_flush
  mkdir -p "$d" 2>/dev/null || return 0
  tmp="$fpf.tmp.$$"
  : > "$tmp" 2>/dev/null || return 0
  for ck in "${!cur[@]}"; do printf '%s\t%s\n' "$ck" "${cur[$ck]}"; done | LC_ALL=C sort > "$tmp"
  mv -f "$tmp" "$fpf" 2>/dev/null
  return 0
}
