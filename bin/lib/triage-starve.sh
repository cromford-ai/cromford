#!/bin/bash
# bin/lib/triage-starve.sh — the triage starvation guard (BH-8475). Sourced by
# bin/lib/triage-state.sh, never executed. Defines functions only: no `set -e`,
# no `exit`, nothing runs or prints at source time. Doc: docs/TRIAGE-STATE.md,
# "Starvation guard (BH-8475)".
#
# WHY. project-6-os TK-2601 was in the triage-state "to the model" list on every
# enforce pass for 27 h (2026-10-25 18:06Z to 2026-10-26 21:05Z) and no shard
# ever ran for it. The shard loop walks the scope in scope order and every cap
# cuts the same tail; a listed key outside a scoped tick's scope waits for a
# full tick. Nothing counted how long a key was listed, and nothing acted.
#
# THE LEDGER. state/triage-state/<p>/starve.tsv, one row per key in the CURRENT
# model set (decisions.tsv column 3 = llm), tab-separated:
#   key label first_listed passes last_run fastpath_epoch fastpath_outcome alerted
# Rewritten whole on each pass under flock (starve.lock, fd 7). A key that
# leaves the model set is dropped: its listing episode ends, and a relisting
# starts again at passes=1. The rows never outnumber the open model set, which
# is the retention rule.
#
#   tsv_pass <harness> <project>
#     ts_tick, enforce only. Counts the pass; a key ELIGIBLE (passes >= N, listed
#     >= the window, no triage run since first listed, no fastpath attempt yet)
#     gets ONE bin/launch-fastpath.sh attempt (GitHub boards; an in-app board
#     records `n/a: in-app board`), one TRIAGE-STARVE lane-log line and one warn
#     alert per pass for all of them. A live builds pause withholds the attempt.
#     A TRIAGE RUN is read from the shard's own files, so bin/lib/rt/shards.sh
#     is not edited (BH-3418 B1): logs/<p>.triage-<KEY>.out written since the
#     key was first listed (bin/triage-shard.sh writes it at launch), or a held
#     locks/triage-key-<p>-<KEY>.lock (a shard running now).
#   tsv_order_scope <harness> <project>
#     stdin TICK_SCOPE, stdout the same lines reordered: `[HOTFIX] ` lines
#     first, then lines whose key has a ledger row by oldest first_listed, then
#     every other line; ties keep the input order. TICK_SCOPE is the order the
#     shard units are built in, so a cap cuts the youngest keys, not the same
#     old ones every pass. Off, no ledger or any error: the input unchanged.
#   tsv_ran_all <harness> <project>
#     Mark every listed key run (a full-scope tick's single session).
#
# FAIL-OPEN: every function returns 0, and a ledger it cannot read or lock
# leaves the tick exactly as it was before this lib.
#
# KNOBS (catalog/lanes.d/_lib.triage-starve.json, through lib_env_apply; the
# numbers below are the documented fallback only):
#   TRIAGE_STARVE_PASSES (3, 0 = off)  TRIAGE_STARVE_WINDOW_S (7200)
#   TRIAGE_STARVE_FASTPATH_MAX (10)    TRIAGE_STARVE_FASTPATH_TIMEOUT_S (300)
#   TRIAGE_STARVE_LOCK_WAIT_S (5)
# shellcheck shell=bash
if [ -n "${TRIAGE_STARVE_LIB:-}" ]; then return 0 2>/dev/null; fi
TRIAGE_STARVE_LIB=1
_TSV_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_TSV_APPLIED=0

# TSV_NOW is a test seam, read only inside the test sandbox.
_tsv_now() {
  if [ "${HARNESS_TEST_SANDBOX:-0}" = 1 ] && [ -n "${TSV_NOW:-}" ]; then printf '%s' "$TSV_NOW"; else date -u +%s; fi
}
_tsv_int() { # _tsv_int <value> <default> <min> <max>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  if [ "$1" -lt "$3" ]; then printf '%s' "$3"; elif [ "$1" -gt "$4" ]; then printf '%s' "$4"; else printf '%s' "$1"; fi
}

# _tsv_knobs <project> — _TSV_PASSES/_TSV_WINDOW/_TSV_FPMAX/_TSV_FPTO/_TSV_WAIT in THIS
# shell; the settings contract is applied once per process (_tp_knobs' idiom).
_tsv_knobs() {
  if [ "$_TSV_APPLIED" = 0 ]; then
    _TSV_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_TSV_LIBDIR/lane-gate.sh" ] && . "$_TSV_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-starve "${1:-}"
  fi
  # Fallbacks name their rows: lib.triage-starve[.<p>].triage_starve_passes etc.
  _TSV_PASSES=$(_tsv_int "${TRIAGE_STARVE_PASSES:-3}" 3 0 100)
  _TSV_WINDOW=$(_tsv_int "${TRIAGE_STARVE_WINDOW_S:-7200}" 7200 600 604800)
  _TSV_FPMAX=$(_tsv_int "${TRIAGE_STARVE_FASTPATH_MAX:-10}" 10 1 50)
  _TSV_FPTO=$(_tsv_int "${TRIAGE_STARVE_FASTPATH_TIMEOUT_S:-300}" 300 30 1800)
  _TSV_WAIT=$(_tsv_int "${TRIAGE_STARVE_LOCK_WAIT_S:-5}" 5 1 60)
  return 0
}

_tsv_dir() { printf '%s/state/triage-state/%s' "$1" "$2"; }

_tsv_log() { # _tsv_log <harness> <project> <text> — the project's lane log
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  printf '%s [%s] %s\n' "${STAMP:-$(date -u '+%Y-%m-%d %H:%M:%SZ')}" "$2" "$3" >> "${LOG:-$1/logs/$2.log}" 2>/dev/null
  return 0
}

# _tsv_locked <dir> <cmd...> — <cmd> under the ledger lock, in a subshell; its
# stdout. rc 75 when the lock is not taken within TRIAGE_STARVE_LOCK_WAIT_S.
_tsv_locked() {
  local d="$1"; shift
  ( flock -w "${_TSV_WAIT:-5}" 7 || exit 75; "$@" ) 7>"$d/starve.lock"
}

# _tsv_set <dir> <awk-assignments> — rewrite starve.tsv with one awk program
# applied to every row (run under _tsv_locked). The program sees the row as
# $1..$8 and the -v variables passed after it.
_tsv_set() {
  local d="$1" prog="$2" tmp; shift 2
  [ -s "$d/starve.tsv" ] || return 0
  tmp=$(mktemp "$d/starve.tsv.XXXXXX" 2>/dev/null) || return 1
  if awk -F'\t' -v OFS='\t' "$@" "$prog"' {print}' "$d/starve.tsv" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$d/starve.tsv"
  else
    rm -f "$tmp"; return 1
  fi
}

# _tsv_held <lockfile> — rc 0 when some process holds this flock (the shard
# dispatcher's own census, triage_shard_held, when it is loaded).
_tsv_held() {
  command -v triage_shard_held >/dev/null 2>&1 && { triage_shard_held "$1"; return; }
  [ -e "$1" ] || return 1
  ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null && return 1
  return 0
}

# _tsv_runs <harness> <project> <dir> <now> — the triage-run evidence for every
# key in this pass's model set, one `key<TAB>epoch` line each: the mtime of its
# shard out file, or <now> when its shard lock is held. A key with neither has
# no line. Builtin tests per key; one stat per out file that exists.
_tsv_runs() {
  local h="$1" p="$2" d="$3" now="$4" k f
  awk -F'\t' '$3 == "llm" { print $1; if ($2 != $1) print $2 }' "$d/decisions.tsv" 2>/dev/null | sort -u |
  while IFS= read -r k; do
    case "$k" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    if [ -e "$h/locks/triage-key-$p-$k.lock" ] && _tsv_held "$h/locks/triage-key-$p-$k.lock"; then
      printf '%s\t%s\n' "$k" "$now"
    else
      f="$h/logs/$p.triage-$k.out"
      [ -e "$f" ] && printf '%s\t%s\n' "$k" "$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    fi
  done
  return 0
}

# _tsv_count <dir> <now> <passes> <window> <runs-file> — one pass over
# decisions.tsv (run under _tsv_locked). Writes the new ledger; prints
# `E<TAB>key<TAB>label<TAB>passes<TAB>first` per eligible key, oldest first,
# and `B<TAB>n` when n malformed rows were dropped. A run (from _tsv_runs) at
# or after first_listed moves last_run; an older one is a past episode's.
_tsv_count() {
  local d="$1" now="$2" n="$3" w="$4" runs="${5:-/dev/null}" old="$1/starve.tsv" tmp
  [ -r "$old" ] || old=/dev/null
  [ -r "$runs" ] || runs=/dev/null
  tmp=$(mktemp "$d/starve.tsv.XXXXXX" 2>/dev/null) || return 1
  awk -F'\t' -v OFS='\t' -v old="$old" -v runs="$runs" -v now="$now" -v N="$n" -v W="$w" -v out="$tmp" '
    BEGIN { while ((getline l < runs) > 0) { split(l, a, "\t"); if (a[2] ~ /^[0-9]+$/ && a[2] + 0 > ran[a[1]] + 0) ran[a[1]] = a[2] } }
    FILENAME == old {
      if (NF != 8 || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $8 !~ /^[01]$/) { bad++; next }
      row[$1] = $0; next
    }
    $3 == "llm" && $1 != "" && !seen[$1]++ {
      lab = $2; gsub(/[\t\r\n]/, "", lab)
      if ($1 in row) { split(row[$1], r, "\t"); first = r[3]; p = r[4] + 1; run = r[5]; fe = r[6]; fo = r[7]; al = r[8] }
      else { first = now; p = 1; run = 0; fe = 0; fo = "-"; al = 0 }
      mt = ran[$1] + 0; if (ran[lab] + 0 > mt) mt = ran[lab] + 0
      if (mt >= first && mt > run) run = mt
      print $1, lab, first, p, run, fe, fo, al > out
      if (p >= N && now - first >= W && run < first && fe == 0) print "E", $1, lab, p, first
    }
    END { close(out); if (bad) print "B", bad }' "$old" "$d/decisions.tsv" | sort -t "$(printf '\t')" -k1,1 -k5,5n -s
  mv -f "$tmp" "$d/starve.tsv"
}

# _tsv_decline_reason <logfile> <offset> <key> <label> — the newest
# `FASTPATH-DECLINED <key|label> :: <reason>` line fastpath wrote after <offset>.
_tsv_decline_reason() {
  local r
  r=$(tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | awk -v k="$3" -v l="$4" '
    { i = index($0, "FASTPATH-DECLINED "); if (!i) next
      s = substr($0, i + 18); j = index(s, " :: "); if (!j) next
      key = substr(s, 1, j - 1); if (key == k || key == l) why = substr(s, j + 4) }
    END { print why }')
  printf '%s' "${r:-reason not logged}" | tr -d '\t\r'
}

tsv_pass() {
  local h="${1:-}" p="${2:-}" d now out bad e k lab n first keys="" labels="" i=0 gh=0 rc fp dec off
  local outcome rows="" alert_txt="" alert_n=0 hrs
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _tsv_knobs "$p"
  [ "$_TSV_PASSES" -gt 0 ] || return 0
  d=$(_tsv_dir "$h" "$p")
  [ -r "$d/decisions.tsv" ] || return 0
  now=$(_tsv_now)
  local runs; runs=$(mktemp "$d/starve.runs.XXXXXX" 2>/dev/null) || runs=""
  [ -n "$runs" ] && _tsv_runs "$h" "$p" "$d" "$now" > "$runs"
  out=$(_tsv_locked "$d" _tsv_count "$d" "$now" "$_TSV_PASSES" "$_TSV_WINDOW" "${runs:-/dev/null}"); rc=$?
  [ -n "$runs" ] && rm -f "$runs"
  if [ "$rc" = 75 ]; then
    _tsv_log "$h" "$p" "TRIAGE-STARVE: ledger lock busy for ${_TSV_WAIT}s — this pass is not counted"
    return 0
  fi
  [ "$rc" = 0 ] || { _tsv_log "$h" "$p" "TRIAGE-STARVE: could not write $d/starve.tsv — this pass is not counted"; return 0; }
  bad=$(printf '%s\n' "$out" | awk -F'\t' '$1=="B"{print $2}')
  [ -n "$bad" ] && _tsv_log "$h" "$p" "TRIAGE-STARVE: $bad malformed ledger row(s) in starve.tsv dropped — the ledger was rebuilt from this pass"
  # The eligible keys, oldest first, at most TRIAGE_STARVE_FASTPATH_MAX this pass.
  while IFS=$'\t' read -r e k lab n first; do
    [ "$e" = E ] || continue
    [ "$i" -lt "$_TSV_FPMAX" ] || break
    i=$((i+1)); keys="$keys $k"; labels="$labels $lab"
    rows="$rows$k	$lab	$n	$first
"
  done <<<"$out"
  [ -n "$keys" ] || return 0
  jq -e 'has("issues")' "$d/world.json" >/dev/null 2>&1 && gh=1
  if [ "$gh" = 1 ] && command -v pause_active >/dev/null 2>&1 && pause_active "$p" builds 2>/dev/null; then
    _tsv_log "$h" "$p" "TRIAGE-STARVE withheld$labels: builds pause"
    return 0
  fi
  # The call, with the board labels (TK-2601, the form a person passes), under
  # TRIAGE_STARVE_FASTPATH_TIMEOUT_S: it runs inside the tick. Its stdout is the
  # DECLINED keys, echoed as given (bin/launch-fastpath.sh contract).
  fp="$h/bin/launch-fastpath.sh"; dec=""; rc=0
  if [ "$gh" = 1 ] && [ -x "$fp" ]; then
    off=$(stat -c %s "$h/logs/$p.log" 2>/dev/null || echo 0)
    # shellcheck disable=SC2086 # labels are a word list of ticket labels
    dec=$(timeout "$_TSV_FPTO" "$fp" "$p" $labels </dev/null 2>/dev/null 7>&- 8>&- 9>&-); rc=$?
  fi
  # Outcome per key, written to the ledger BEFORE anything is told.
  local marks=""
  while IFS=$'\t' read -r k lab n first; do
    [ -n "$k" ] || continue
    if [ "$gh" != 1 ]; then outcome="n/a: in-app board"
    elif [ ! -x "$fp" ]; then outcome="n/a: fastpath not executable"
    elif [ "$rc" != 0 ] && [ "$rc" != 1 ]; then outcome="declined: fastpath exit $rc"
    elif grep -qxF -e "$k" ${lab:+-e "$lab"} <<<"$dec"; then
      outcome="declined: $(_tsv_decline_reason "$h/logs/$p.log" "$off" "$k" "$lab")"
    else outcome="launched"; fi
    marks="$marks$k	$outcome
"
  done <<<"$rows"
  local mf; mf=$(mktemp "$d/starve.marks.XXXXXX" 2>/dev/null) && printf '%s' "$marks" > "$mf"
  _tsv_locked "$d" _tsv_set "$d" 'BEGIN { while ((getline l < mf) > 0) { split(l, a, "\t"); o[a[1]] = a[2] } } ($1 in o) { $6 = now; $7 = o[$1] }' \
    -v mf="$mf" -v now="$now" \
    || _tsv_log "$h" "$p" "TRIAGE-STARVE: could not record the fastpath outcome in $d/starve.tsv"
  rm -f "$mf"
  while IFS=$'\t' read -r k lab n first; do
    [ -n "$k" ] || continue
    outcome=$(printf '%s' "$marks" | awk -F'\t' -v k="$k" '$1==k{print $2; exit}')
    hrs=$(awk -v s="$(( now - first ))" 'BEGIN{printf "%.1f", s/3600}')
    case "$outcome" in launched) outcome="fastpath launched" ;; declined:*) outcome="fastpath $outcome" ;; esac
    _tsv_log "$h" "$p" "TRIAGE-STARVE $lab listed $n passes over ${hrs}h with no triage run — $outcome"
    alert_txt="$alert_txt $lab=${outcome#fastpath }"; alert_n=$((alert_n+1))
  done <<<"$rows"
  # ONE alert per project per pass, for the keys tried this pass (each key is
  # tried once per listing episode, so it is alerted once per episode).
  local win; win=$(awk -v s="$_TSV_WINDOW" 'BEGIN{printf "%gh", s/3600}')
  if [ -x "$h/bin/lane-alert.sh" ] && "$h/bin/lane-alert.sh" --severity warn --id "triage-starve-$p" triage-starve \
       "[$p] triage starvation: $alert_n ticket(s) listed to the model past $win with no triage run:$alert_txt. Read: logs/$p.log (TRIAGE-STARVE) and state/triage-state/$p/starve.tsv." \
       </dev/null >/dev/null 2>&1 7>&- 8>&- 9>&-; then :
  else
    "$h/bin/alert-line.sh" --severity warn --id "triage-starve-$p" --project "$p" \
      "[$p] triage starvation: bin/lane-alert.sh did not run; $alert_n ticket(s) listed past $win with no triage run:$alert_txt" \
      </dev/null >/dev/null 2>&1 7>&- 8>&- 9>&-
  fi
  _tsv_locked "$d" _tsv_set "$d" 'BEGIN { n = split(ks, a, " "); for (i = 1; i <= n; i++) m[a[i]] = 1 } ($1 in m) { $8 = 1 }' -v ks="$keys"
  return 0
}

# _tsv_line_key <harness> <project> <gh> <line> — the shard key of one scope
# line (triage_shard_key, the dispatcher's own parser); rc 1 when unplaceable.
_tsv_line_key() {
  if ! command -v triage_shard_key >/dev/null 2>&1; then
    # shellcheck source=bin/lib/triage-shards-lib.sh
    [ -r "$1/bin/lib/triage-shards-lib.sh" ] && . "$1/bin/lib/triage-shards-lib.sh" 2>/dev/null
  fi
  command -v triage_shard_key >/dev/null 2>&1 || return 1
  triage_shard_key board "$2" "$3" "${4#'[HOTFIX] '}" 2>/dev/null
}

tsv_order_scope() {
  local h="${1:-}" p="${2:-}" d in gh=0 i k first sorted out
  local -a lines=()
  local -A age=()
  in=$(cat)
  _tsv_emit() { [ -n "$in" ] && printf '%s\n' "$in"; return 0; }
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$in" ] || { _tsv_emit; return 0; }
  _tsv_knobs "$p"
  d=$(_tsv_dir "$h" "$p")
  [ "$_TSV_PASSES" -gt 0 ] && [ -s "$d/starve.tsv" ] || { _tsv_emit; return 0; }
  jq -e 'has("issues")' "$d/world.json" >/dev/null 2>&1 && gh=1
  while IFS=$'\t' read -r k _ first _; do
    [ -n "$k" ] && [[ "$first" =~ ^[0-9]+$ ]] && age[$k]=$first
  done < "$d/starve.tsv"
  mapfile -t lines <<<"$in"
  # One sort key per line: hotfix (0 first), aged (0 = has a ledger row),
  # first_listed, input position. Then the lines in that order.
  sorted=$(for i in "${!lines[@]}"; do
      k=$(_tsv_line_key "$h" "$p" "$gh" "${lines[$i]}") || k=""
      first=""; [ -n "$k" ] && first=${age[$k]:-}
      printf '%d\t%d\t%s\t%d\n' "$([ "${lines[$i]#'[HOTFIX] '}" != "${lines[$i]}" ] && echo 0 || echo 1)" \
        "$([ -n "$first" ] && echo 0 || echo 1)" "${first:-0}" "$i"
    done | sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n | cut -f4) || sorted=""
  out=$(for i in $sorted; do printf '%s\n' "${lines[$i]}"; done)
  # Fail-open: anything but the same lines, as a multiset, is the input order.
  if [ -n "$sorted" ] && [ "$(printf '%s\n' "$out" | sort)" = "$(printf '%s\n' "$in" | sort)" ]; then
    printf '%s\n' "$out"
  else
    _tsv_log "$h" "$p" "TRIAGE-STARVE: the scope reorder did not keep the same lines — the scope order is unchanged"
    _tsv_emit
  fi
  return 0
}

tsv_ran_all() {
  local h="${1:-}" p="${2:-}" d
  [ -n "$h" ] && [ -n "$p" ] || return 0
  d=$(_tsv_dir "$h" "$p")
  [ -s "$d/starve.tsv" ] || return 0
  _tsv_knobs "$p"
  _tsv_locked "$d" _tsv_set "$d" '{ $5 = now }' -v now="$(_tsv_now)" || true
  return 0
}
