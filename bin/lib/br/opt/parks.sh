#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/parks.sh — BH-9075 (BH-9067.3): the resolver reads its queue
# parks as a DELTA of the D1 `parks` table (docs/events-bh-9067/3-parks.md).
#
# NOT a BR_OPT_MODULES word. br_candidates (bin/lib/br/discovery.sh) sources
# this file lazily, and only when BR_PARKS_MODE is not `off`. No side effect at
# source time. It reads $H, $ST, $ONLY and the BR_PARKS_* knobs at call time.
#
# THE MODES (lane knob BR_PARKS_MODE, settings row lane.blocked-resolver.br_parks_mode):
#   off     the file sources only; this file is not sourced, 0 requests.
#   shadow  the default. The tick uses the file sources. After them,
#           br_opt_parks_shadow compares their queue and conductor rows with
#           the parks mirror and writes ONE `parks-shadow:` line. 0 ALERTS.
#   on      the queue source is br_opt_parks_candidates; any failure prints
#           nothing, answers rc 1, and br_from_queue runs (the files fallback
#           for this tick). The conductor source still runs from its own read.
#
# THE MIRROR. A pure delta never re-offers a park the tick did not reach, so
# each project keeps a local copy of its non-done rows that the delta keeps
# current: state/blocked-resolver/parks/<p>.mirror (12-column TSV, sorted by
# ck) and <p>.cursor (one token, `<ts>` or `<ts>:<ck>`). They are a pair: a
# cursor with no mirror reads as cursor 0. Cursor 0 means backfill: the file
# sources' rows are PUT with updated_at=1 (so any real write wins over them)
# and the mirror is read again from 0.
#
# _brp_sync <p> pages GET /api/parks/changed until `truncated` is 0 or
# BR_PARKS_MAX_PAGES. A failed page changes nothing (rc 1). Then the rows are
# applied (done deletes, any other state upserts by ck) and the cursor moves to
# the last `next`, held back to now - BR_PARKS_LAG_S (writer clock skew and
# same-second writes; a re-read row applies idempotently). The cursor also
# stays one second below the oldest note of the project still in
# state/parks-outbox/ (_brp_outbox_oldest): a note whose flush failed reaches
# D1 later with its write-time updated_at, and the delta must still read it.
# A page-cap stop keeps that progress and answers rc 2: the tick is incomplete. The hotfix rows
# ride on every read, whatever the cursor, so a lost mirror can never hide a
# hotfix park (BH-646).
#
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/): BR_PARKS_MODE (read in
# discovery.sh), BR_PARKS_PAGE, BR_PARKS_MAX_PAGES, BR_PARKS_LAG_S,
# BR_PARKS_SHADOW_LIST_MAX, BR_PARKS_PRUNE_EVERY_S.

_brp_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }
_brp_dir() { printf '%s/parks' "${ST:-$H/state/blocked-resolver}"; }

# _brp_int <ENV> <fallback> <min> <max> — the lane knob (lane_env_apply exports
# it from the settings row or the registry), else the fallback; the fallbacks
# are the registry defaults, named at each call.
_brp_int() {
  local v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  { [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } 2>/dev/null || v=$2
  printf '%s' "$v"
}

# _brp_lib — bin/lib/parks-write.sh and the client, or rc 1.
_brp_lib() {
  command -v parks_changed >/dev/null 2>&1 && command -v pw_flush >/dev/null 2>&1 && return 0
  # shellcheck source=../../parks-write.sh
  . "$H/bin/lib/parks-write.sh" 2>/dev/null || return 1
  # shellcheck source=../../jobs/parks.sh
  command -v parks_changed >/dev/null 2>&1 || . "$H/bin/lib/jobs/parks.sh" 2>/dev/null || return 1
  command -v parks_changed >/dev/null 2>&1
}

_brp_projects() {
  if [ -n "${ONLY:-}" ]; then printf '%s\n' "$ONLY"; else "$H/bin/fleet-conf.sh" --projects 2>/dev/null; fi
}

# _brp_tmp — a per-tick scratch dir in $_BRP_TMP.
_brp_tmp() {
  [ -n "${_BRP_TMP:-}" ] && [ -d "$_BRP_TMP" ] && return 0
  _BRP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/br-parks.XXXXXX" 2>/dev/null)
}
_brp_cleanup() { [ -n "${_BRP_TMP:-}" ] && rm -rf "$_BRP_TMP"; _BRP_TMP=""; return 0; }

# _brp_cursor <p> — the cursor token, or 0 (no cursor, a bad token, no mirror).
_brp_cursor() {
  local d c=""
  d=$(_brp_dir)
  [ -f "$d/$1.mirror" ] && [ -r "$d/$1.mirror" ] && c=$(head -c 300 "$d/$1.cursor" 2>/dev/null | tr -d '\n ')
  [[ $c =~ ^[0-9]+(:[A-Za-z0-9._-]+)?$ ]] || c=0
  # pw_flush dropped outbox notes after this cursor was written: backfill.
  [ "${HARNESS:-$H}/state/parks-outbox/.dropped-at" -nt "$d/$1.cursor" ] && c=0
  printf '%s' "$c"
}

# _brp_outbox_oldest <p> — the smallest updated_at (column 10) of the notes of
# <p> still in state/parks-outbox/, or nothing. .bad/ is not read: the route
# refused those notes, so they never reach D1.
_brp_outbox_oldest() {
  local ob="${HARNESS:-$H}/state/parks-outbox"
  [ -d "$ob" ] || return 0
  find "$ob" -maxdepth 1 -type f -name '[0-9]*.tsv' -exec awk -F'\t' -v p="$1" \
    '$1 == p && $10 ~ /^[0-9]+$/ { print $10 }' {} + 2>/dev/null | sort -n | head -n 1
}

_brp_sync() {
  local p="$1" d cur page=0 maxp lim lag now pf acc nx tr ts ob rc=0
  _brp_lib || return 1
  _brp_tmp || return 1
  pw_flush
  d=$(_brp_dir); mkdir -p "$d" 2>/dev/null || return 1
  cur=$(_brp_cursor "$p")
  lim=$(_brp_int BR_PARKS_PAGE 500 1 1000)          # lane.blocked-resolver.br_parks_page
  maxp=$(_brp_int BR_PARKS_MAX_PAGES 20 1 200)      # lane.blocked-resolver.br_parks_max_pages
  lag=$(_brp_int BR_PARKS_LAG_S 120 0 3600)         # lane.blocked-resolver.br_parks_lag_s
  acc="$_BRP_TMP/$p.acc"; pf="$_BRP_TMP/$p.page"
  : > "$acc"; : > "$_BRP_TMP/$p.hotfix"
  while :; do
    page=$((page + 1))
    parks_changed "$p" "$cur" "$lim" 1 > "$pf" || return 1
    nx=$(tail -n 1 "$pf")
    case "$nx" in next$'\t'*) ;; *) return 1 ;; esac
    awk -F'\t' -v OFS='\t' '$1 == "row" { $1 = ""; sub(/^\t/, ""); print }' "$pf" >> "$acc"
    awk -F'\t' -v OFS='\t' '$1 == "hotfix" { $1 = ""; sub(/^\t/, ""); print }' "$pf" > "$_BRP_TMP/$p.hotfix"
    IFS=$'\t' read -r _ cur tr <<<"$nx"
    [ "$tr" = 1 ] || break
    [ "$page" -lt "$maxp" ] || { rc=2; break; }
  done
  # The mirror: done deletes, every other row upserts by ck. Rows of another
  # project are never applied.
  [ -f "$d/$p.mirror" ] || : > "$d/$p.mirror"
  awk -F'\t' -v p="$p" 'FILENAME == ARGV[1] { if (NF == 12) m[$2] = $0; next }
       NF != 12 || $1 != p { next }
       { if ($4 == "done") delete m[$2]; else m[$2] = $0 }
       END { for (k in m) print m[k] }' "$d/$p.mirror" "$_BRP_TMP/$p.hotfix" "$acc" \
    | LC_ALL=C sort -t $'\t' -k2,2 > "$d/$p.mirror.tmp.$$" || return 1
  mv -f "$d/$p.mirror.tmp.$$" "$d/$p.mirror" || return 1
  now=$(date -u +%s); ts=${cur%%:*}
  if [ "$ts" -gt $((now - lag)) ] 2>/dev/null; then cur=$((now - lag)); [ "$cur" -ge 0 ] || cur=0; fi
  # The outbox hold wins over the lag hold: a note not yet in D1 is read later.
  ob=$(_brp_outbox_oldest "$p")
  if [ -n "$ob" ] && [ "${cur%%:*}" -ge "$ob" ] 2>/dev/null; then cur=$((ob - 1)); [ "$cur" -ge 0 ] || cur=0; fi
  printf '%s\n' "$cur" > "$d/$p.cursor.tmp.$$" && mv -f "$d/$p.cursor.tmp.$$" "$d/$p.cursor"
  return "$rc"
}

# _brp_emit <p> — the 8-field queue rows of the mirror plus the hotfix rows, one per ck.
_brp_emit() {
  local d; d=$(_brp_dir)
  awk -F'\t' -v OFS='\t' '$3 == "queue" && !seen[$2]++ { print "queue", $1, $2, $6, $7, $8, $9, $12 }' \
    "$_BRP_TMP/$1.hotfix" "$d/$1.mirror"
}

# _brp_backfill <p> <files-out> — the file sources' queue and conductor rows of
# <p>, PUT in batches of PW_BATCH. rc 1 on the first failed batch.
_brp_backfill() {
  local p="$1" f="$2" all n batch i=0
  _brp_lib || return 1
  _brp_tmp || return 1
  all="$_BRP_TMP/$p.backfill"
  awk -F'\t' -v OFS='\t' -v p="$p" '($1 == "queue" || $1 == "conductor") && $2 == p && $3 != "" {
        pa = $8; if (pa !~ /^[0-9]+$/) pa = "-"
        print $2, $3, $1, "parked", "-", ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5), ($6 == "" ? "-" : $6),
              ($7 == "" ? "-" : $7), 1, "br-backfill", pa }' "$f" > "$all"
  n=$(wc -l < "$all")
  [ "$n" -gt 0 ] || return 0
  batch=$(pk_knob PW_BATCH 100 1 100)   # lib.parks.pw_batch
  while [ "$i" -lt "$n" ]; do
    sed -n "$((i + 1)),$((i + batch))p" "$all" > "$all.b"
    parks_put "$all.b" >/dev/null || return 1
    i=$((i + batch))
  done
  _brp_say "parks: backfilled $n rows of $p from the file sources"
  return 0
}

br_opt_parks_candidates() {
  local p s rc=0 out
  local -a ps=()
  _BRP_OWED=""
  _brp_tmp || return 1
  out="$_BRP_TMP/on.out"; : > "$out"
  mapfile -t ps < <(_brp_projects)
  for p in "${ps[@]}"; do
    [ -n "$p" ] || continue
    if [ "$(_brp_cursor "$p")" = 0 ]; then
      _BRP_OWED="$_BRP_OWED $p"; rc=1; continue
    fi
    _brp_sync "$p"; s=$?
    case "$s" in
      0) _brp_emit "$p" >> "$out" ;;
      2) _brp_say "parks: $p stopped at BR_PARKS_MAX_PAGES — progress kept, the file sources are used this tick"; rc=1 ;;
      *) _brp_say "parks: $p read failed — the file sources are used this tick"; rc=1 ;;
    esac
  done
  [ "$rc" = 0 ] && cat "$out"
  return "$rc"
}

# br_opt_parks_on_end <files-out> — mode on: backfill the projects that were at cursor 0.
br_opt_parks_on_end() {
  local p
  for p in ${_BRP_OWED:-}; do
    _brp_backfill "$p" "$1" || _brp_say "parks: backfill of $p failed — the file sources stay in use"
  done
  _BRP_OWED=""
  _brp_cleanup
}

br_opt_parks_shadow() {
  local f="$1" p s cap fn mn miss extra nm ne fq mq fc mc k=0 d r why url ck
  local -a ps=() synced=()
  _brp_tmp || return 0
  d=$(_brp_dir)
  mapfile -t ps < <(_brp_projects)
  for p in "${ps[@]}"; do
    [ -n "$p" ] || continue
    if [ "$(_brp_cursor "$p")" = 0 ] && ! _brp_backfill "$p" "$f"; then
      _brp_say "parks-shadow: read failed (backfill of $p) — files used"; continue
    fi
    _brp_sync "$p"; s=$?
    case "$s" in
      0) synced+=("$p") ;;
      2) _brp_say "parks-shadow: read failed ($p stopped at BR_PARKS_MAX_PAGES) — files used" ;;
      *) _brp_say "parks-shadow: read failed ($p changed read) — files used" ;;
    esac
  done
  if [ "${#synced[@]}" -eq 0 ]; then _brp_cleanup; return 0; fi
  # F: the file sources' queue and conductor rows. M: the mirror's, with the
  # conductor rows filtered the way br_from_conductor filters them first.
  : > "$_BRP_TMP/F"; : > "$_BRP_TMP/M"
  for p in "${synced[@]}"; do
    awk -F'\t' -v OFS='\t' -v p="$p" '($1 == "queue" || $1 == "conductor") && $2 == p { print $1, $3 }' "$f" >> "$_BRP_TMP/F"
    awk -F'\t' -v OFS='\t' '$3 == "queue" { print "queue", $2 }' "$d/$p.mirror" "$_BRP_TMP/$p.hotfix" >> "$_BRP_TMP/M"
    while IFS=$'\t' read -r ck why url; do
      r=""; command -v br_reason_of >/dev/null 2>&1 && r=$(br_reason_of "$why")
      [ -n "$r" ] || continue
      command -v bdi_url_retired >/dev/null 2>&1 && bdi_url_retired "$url" && continue
      printf 'conductor\t%s\n' "$ck" >> "$_BRP_TMP/M"
    done < <(awk -F'\t' -v OFS='\t' '$3 == "conductor" { print $2, $6, $7 }' "$d/$p.mirror")
  done
  sort -u "$_BRP_TMP/F" -o "$_BRP_TMP/F"; sort -u "$_BRP_TMP/M" -o "$_BRP_TMP/M"
  fn=$(wc -l < "$_BRP_TMP/F"); mn=$(wc -l < "$_BRP_TMP/M")
  fq=$(grep -c '^queue' "$_BRP_TMP/F"); mq=$(grep -c '^queue' "$_BRP_TMP/M")
  fc=$(grep -c '^conductor' "$_BRP_TMP/F"); mc=$(grep -c '^conductor' "$_BRP_TMP/M")
  cap=$(_brp_int BR_PARKS_SHADOW_LIST_MAX 20 0 200)   # lane.blocked-resolver.br_parks_shadow_list_max
  cut -f2 "$_BRP_TMP/F" | sort -u > "$_BRP_TMP/Fk"; cut -f2 "$_BRP_TMP/M" | sort -u > "$_BRP_TMP/Mk"
  nm=$(comm -23 "$_BRP_TMP/Fk" "$_BRP_TMP/Mk" | wc -l); ne=$(comm -13 "$_BRP_TMP/Fk" "$_BRP_TMP/Mk" | wc -l)
  miss=$(comm -23 "$_BRP_TMP/Fk" "$_BRP_TMP/Mk" | head -n "$cap" | paste -sd, -)
  extra=$(comm -13 "$_BRP_TMP/Fk" "$_BRP_TMP/Mk" | head -n "$cap" | paste -sd, -)
  [ "$nm" -gt "$cap" ] && miss="${miss}[+$((nm - cap))]"
  [ "$ne" -gt "$cap" ] && extra="${extra}[+$((ne - cap))]"
  k=${#synced[@]}
  _brp_say "parks-shadow: files=$fn parks=$mn missing=${miss:--} extra=${extra:--} queue=$fq/$mq conductor=$fc/$mc projects=$k"
  _brp_cleanup
  return 0
}

# br_opt_parks_prune — POST /api/parks/prune at most every BR_PARKS_PRUNE_EVERY_S
# (0 = never). flock -n is the dedupe; the stamp moves only after a 200.
br_opt_parks_prune() {
  local every d now last fd out
  every=$(_brp_int BR_PARKS_PRUNE_EVERY_S 86400 0 604800)   # lane.blocked-resolver.br_parks_prune_every_s
  [ "$every" -gt 0 ] || return 0
  d=$(_brp_dir); now=$(date -u +%s)
  last=$(tr -dc '0-9' 2>/dev/null < "$d/prune.last")
  if [ -n "$last" ] && [ $((now - last)) -lt "$every" ] && [ $((now - last)) -ge 0 ]; then return 0; fi
  _brp_lib || return 0
  mkdir -p "$d" "$H/locks" 2>/dev/null
  { exec {fd}>"$H/locks/parks-prune.lock"; } 2>/dev/null || return 0
  if ! flock -n "$fd"; then exec {fd}>&-; return 0; fi
  if out=$(parks_prune); then
    printf '%s\n' "$now" > "$d/prune.last.tmp.$$" && mv -f "$d/prune.last.tmp.$$" "$d/prune.last"
    _brp_say "parks-prune: $out"
  else
    _brp_say "parks-prune: failed (${JOBS_HTTP:+http=}${JOBS_HTTP:-no answer}) — retried next tick"
  fi
  exec {fd}>&-
  return 0
}
