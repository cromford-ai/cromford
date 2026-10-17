#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/flags.sh — the box's flags. BH-4153: the three ported families are harness_flags ROWS read DB-first; every other name keeps BH-5004's pause_flags row-first answer with the flags/ file as mirror and fallback. Sourced by bin/jobs-client.sh (JC_MODULES), never run. Public entry: bin/lib/flags.sh.

# --- BH-4153: the ported families ----------------------------------------------
# `paused-*`, `automerge-disabled`, `automerge-disabled-*`, `lanedown-*` and
# `dispatch-mode-*` (BH-6350, bin/lib/dispatch-mode.sh) (FLAG_PORTED_RE, the same list as worker/jobs/src/lib/harness-flags.js) are
# ROWS. On a box with a worker configured no flags/ file is written for them:
#
#   flag_has   [--scope S] [--cached] <name>        rc 0 on, 1 off, 2 UNKNOWN
#   flag_set   [--scope S] [--hold-local|--local-only] <name> [on|off|<value>] [reason]
#                                                   rc 0 written and read back, 1 not
#   flag_clear [--scope S] [--local-only] <name> [reason]
#                                                   rc 0 cleared (or no row), 1 not
#   flag_list  [--scope S] [--cached] <prefix>      active names; rc 0, 2 no answer
#   flag_fetch [--scope S] <name>                   rc 0 row, 1 outage/unreadable, 2 no row
#
# rc 2 is a read error with nothing to fall back on, never "off". flag_active
# reads it as ON for a stop switch (paused-*, automerge-disabled*): a fleet that
# cannot read its pauses stands down rather than run through one. FLAG_SRC says
# which source answered: db, cache (the last good answer, worker unreachable),
# local (a --hold-local write, or a legacy file not yet imported), file (no
# worker configured, or a non-ported name) or unknown.
#
# The last-good cache is state/flags-cache/<scope>/<name>, one JSON line
# {on,value,set_at,cleared_at,src,stamp}, written tmp+mv by every good read. It
# has no age cap on purpose: an expiring cache turns a long outage into rc 2,
# which for a stop switch stops the fleet.
#
# A LOCAL HOLD (src local) is the one thing written without the worker:
# flag_set --hold-local when the PUT fails (cost-local-brake, quiesce), or a
# legacy flags/<name> seen while the import cannot run (stamped with its mtime).
# It keeps BH-1370's recency rule: a row whose cleared_at // set_at is at or
# after the hold's stamp wins and drops it (a console RESUME); an older row, or
# no row, leaves the hold standing. A hold seeded from a file goes when the file
# does (an operator's `rm` still resumes). Without --hold-local a failed write
# leaves nothing behind (BH-2599).
#
# --local-only never touches the worker: flag_set writes the local hold and
# nothing else, flag_clear drops a local hold and re-reads the row. It is for a
# pause that means THIS box and no other (quiesce-for-resize): a fleet row would
# stop every box. No worker configured: the flags/ file, which is box-local.
#
# THE IMPORT PUBLISHES ONLY WHAT THIS BOX OWNS. A legacy flags/ file only ever
# paused the box it sat on, so it becomes a fleet row only when the box is
# where that flag acted anyway: paused-<p> and automerge-disabled-<p> for a <p>
# fleet.conf puts on this box, the fleet automerge-disabled on the hub, and
# lanedown-* (box-scoped by construction). Any other file is reported
# kept-local and stays a local hold on this box, exactly as it behaved before;
# a row at or after its mtime still wins and removes it.
#
# Scope is `fleet`, or for lanedown-* this box (JOBS_BOX): the canary that
# writes a lanedown row is the only reader of it.
#
# NO WORKER CONFIGURED (JOBS_URL or HARNESS_SECRET empty) is not an outage:
# there is no DB to be DB-first against, so every verb keeps the legacy file
# path below exactly. A worker that predates harness_flags answers the legacy
# pause_flags shape ({active, updated_at}); _flag_norm reads it as the same row,
# so a box that updates before its worker keeps reading its pauses.

# --- Phase 3: pause flags, every NON-ported name (BH-5004) --------------------
# the operator, 2026-10-09: BH-4153's harness_flags model governs the ported families
# above; this model stays for every other name. flag_sync, flag_active and
# flag_set below dispatch here for a non-ported name.
# THE ROW IS THE FLAG (BH-5004). flag_active answers from the pause_flags row it
# read, and flags/<name> is that row's MIRROR and the FALLBACK. A mirror write
# that fails (flags/ unwritable, a stale file rm cannot remove) no longer
# changes a single answer. The file decides only when there is no row to read:
#
#   row read                    answer
#   active=1                    ON, whatever the file is
#   active=0                    ON only when flags/<name> is STRICTLY newer than
#                               the row (a local touch made after it), else OFF
#   no row (404)                the file, silently (most flags never had a row)
#   unreadable (outage, 5xx,    the file, plus one jobs-client.log line when a
#     malformed row)            worker IS configured; silent when JOBS_URL is
#                               empty (no DB here on purpose)
#
# The row read is memoised per process for FLAG_ROW_TTL_S seconds (default 10,
# 0 disables), all three outcomes included, so 101 call sites cost one GET per
# name per TTL and an outage costs one failed request, not one per call.
#
# The mirror is reconciled LAST-WRITER-WINS on the row's updated_at against the
# file's mtime (BH-1370), and the row wins ties:
#
#   row                file                action
#   active             absent              create empty, mtime set to the row's updated_at
#   active             present             nothing (re-touching would churn the mtime)
#   active + value     absent              write the value (tmp + mv), mtime = row's updated_at
#   active + value     present, same text  nothing
#   active + value     present, other text rewrite iff row_epoch >= file mtime, else keep
#   inactive           present             remove iff row_epoch >= file mtime, else keep
#   inactive           absent              nothing
#
# BH-5635: `value` is the file's content (a WIP limit, say). A value outside
# 1-64 chars of A-Za-z0-9._- is refused (rc 1, one jobs-client.log line) and the
# box is left alone; only a direct DB write can produce one.
#
# A file this reconcile (or flag_set) writes carries the row's own time, so a
# row and its file are equal by construction and a later console write always
# wins. A later local `touch` — pipeline-health's autohalt, an operator over
# ssh, quiesce-for-resize, harness-ctl all-off, none of which write a row — is
# newer than the row and holds until a row written after it.
# A kill switch read through lane_switch (bin/lib/lane-switch.sh, BH-2320) is
# settled by its `switch.*` settings row first; without one it reads the row and
# the file without reconciling either (BH-2412).
#
# A row without a readable `active`, or with an `updated_at` not in the
# worker's shape, is UNREADABLE (one jobs-client.log line, never an ALERTS
# page) and never reads as "inactive". The rows are worker-stamped and the
# mtime is box-stamped: a genuine local touch compared against a row is the one
# cross-clock comparison, bounded by bin/clock-sync.sh and bin/lib/tz-check.sh.
_flag_dir()  { printf '%s' "$JOBS_HARNESS/flags"; }

# _flag_epoch <updated_at> -> epoch seconds. ONLY the worker's shape is accepted
# (YYYY-MM-DDTHH:MM:SS[.fff]Z): GNU date happily parses "yesterday" and "", and
# a row this client cannot read is a non-action, never a guess.
_flag_epoch() {
  case "${1:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9]*Z) ;;
    *) return 1 ;;
  esac
  date -u -d "$1" +%s 2>/dev/null # determinism: ok date-empty-stamp case above admits only YYYY-MM-DDTHH:MM:SSZ
}

# The row cache: one plain global per flag name, _FLAG_ROW_CACHE_<name with
# every non-[A-Za-z0-9_] byte as _> = "<rc> <active> <epoch> <fetched-at>
# <updated_at> <value> <name>" (process memory, dies with the process). Not an
# associative array: this file is in bin/lead-verdict.sh's closure, which must
# run on bash 3.2 (BH-3565, tests/lead-verdict-bash32.bh-3565-test.sh). The
# name rides in the entry, so two names that map to one variable never answer
# for each other. Plain assignments in the caller's shell are globals, as the
# old `declare -gA` was. A value never holds a space (the alphabet below), so
# the entry stays one word per field.
_FLAG_ROW_RC=1; _FLAG_ROW_ACTIVE=""; _FLAG_ROW_EPOCH=""; _FLAG_ROW_UPD=""; _FLAG_ROW_VALUE=""; _FLAG_ROW_FETCHED=0
_FLAG_SRC=""

_flag_ttl() { # the cache TTL in seconds: FLAG_ROW_TTL_S, a non-integer means 10
  case "${FLAG_ROW_TTL_S:-}" in ''|*[!0-9]*) printf 10 ;; *) printf '%s' "$FLAG_ROW_TTL_S" ;; esac
}

_flag_cache_var() { printf '_FLAG_ROW_CACHE_%s' "${1//[^A-Za-z0-9_]/_}"; } # <name> -> the cache variable's name

_flag_cache_put() { # _flag_cache_put <name> — store the current _FLAG_ROW_* for <name>
  local now
  now=$(date -u +%s)
  printf -v "$(_flag_cache_var "$1")" '%s' "$_FLAG_ROW_RC ${_FLAG_ROW_ACTIVE:--} ${_FLAG_ROW_EPOCH:--} $now ${_FLAG_ROW_UPD:--} ${_FLAG_ROW_VALUE:--} $1"
}

_flag_cache_drop() { unset "$(_flag_cache_var "$1")"; } # <name>

# _flag_parse_row <name> <resp-json> — the row a GET already returned, into
# _FLAG_ROW_ACTIVE (0|1), _FLAG_ROW_EPOCH, _FLAG_ROW_UPD and _FLAG_ROW_VALUE
# (BH-5635: the file's content, empty for a plain on/off flag). rc 0 readable, 1
# unreadable: no readable active, an updated_at not in the worker's shape, or a
# value outside 1-64 chars of A-Za-z0-9._-. The worker ANSWERED, so a malformed
# row is logged, never paged: _jobs_log's ALERTS line says "harness-jobs
# unreachable", which this is not (JOBS_ALERT=0).
_flag_parse_row() {
  local name="$1" resp="$2" active upd value epoch
  _FLAG_ROW_ACTIVE=""; _FLAG_ROW_EPOCH=""; _FLAG_ROW_UPD=""; _FLAG_ROW_VALUE=""
  # `// empty`, never `// 0`: a row with no active must not read as inactive.
  active=$(printf '%s' "$resp" | jq -r '.flag.active // empty' 2>/dev/null)
  upd=$(printf '%s' "$resp" | jq -r '.flag.updated_at // empty' 2>/dev/null)
  value=$(printf '%s' "$resp" | jq -r '.flag.value // empty' 2>/dev/null)
  case "$active" in
    0|1) ;;
    *) JOBS_ALERT=0 _jobs_log "flag $name: row without a readable active ('$active') — box left alone"; return 1 ;;
  esac
  epoch=$(_flag_epoch "$upd") \
    || { JOBS_ALERT=0 _jobs_log "flag $name: updated_at '$upd' unreadable — box left alone"; return 1; }
  if [ -n "$value" ] && ! [[ "$value" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    JOBS_ALERT=0 _jobs_log "flag $name: value refused (not 1-64 chars of A-Za-z0-9._-) — box left alone"; return 1
  fi
  _FLAG_ROW_ACTIVE=$active; _FLAG_ROW_EPOCH=$epoch; _FLAG_ROW_UPD=$upd; _FLAG_ROW_VALUE=$value
  return 0
}

# _flag_row <name> [force] — read the pause_flags row into _FLAG_ROW_RC (0 a
# readable row, 1 unreadable, 2 no row), _FLAG_ROW_ACTIVE (0|1), _FLAG_ROW_EPOCH,
# _FLAG_ROW_UPD and _FLAG_ROW_VALUE. Served from the cache inside the TTL unless
# `force`. _FLAG_ROW_FETCHED is 1 when this call made the request. Runs in the
# CALLER's shell (never in a $(...)), or the cache would die with the subshell.
# Returns _FLAG_ROW_RC.
_flag_row() {
  local name="$1" force="${2:-}" ttl now ent resp rc active upd epoch at value ename cvar
  _FLAG_ROW_FETCHED=0
  ttl=$(_flag_ttl)
  cvar=$(_flag_cache_var "$name"); ent="${!cvar:-}"
  if [ -z "$force" ] && [ "$ttl" -gt 0 ] && [ -n "$ent" ]; then
    now=$(date -u +%s)
    read -r rc active epoch at upd value ename <<<"$ent"
    if [ "$ename" = "$name" ] && [ $((now - at)) -lt "$ttl" ]; then
      _FLAG_ROW_RC=$rc; _FLAG_ROW_ACTIVE=${active#-}; _FLAG_ROW_EPOCH=${epoch#-}; _FLAG_ROW_UPD=${upd#-}
      _FLAG_ROW_VALUE=${value#-}
      return "$_FLAG_ROW_RC"
    fi
  fi
  _FLAG_ROW_FETCHED=1; _FLAG_ROW_ACTIVE=""; _FLAG_ROW_EPOCH=""; _FLAG_ROW_UPD=""; _FLAG_ROW_VALUE=""
  resp=$(_jobs_req GET "/api/flags/$name"); rc=$?
  if [ "$rc" -eq 0 ]; then
    _flag_parse_row "$name" "$resp" || rc=1
  else
    [ "$rc" -eq 2 ] || rc=1
  fi
  _FLAG_ROW_RC=$rc
  _flag_cache_put "$name"
  return "$rc"
}

# _flag_mirror <name> — reconcile flags/<name> to the row _flag_row (or
# _flag_apply_row) just read (no request of its own). rc 0 reconciled, 1 the
# file could not be written or read. Only meaningful when _FLAG_ROW_RC is 0.
# A value row (BH-5635) writes its value as the file's content, tmp + mv.
_flag_mirror() {
  local name="$1" f file_epoch
  [ "$_FLAG_ROW_RC" = 0 ] || return 1
  f="$(_flag_dir)/$name"
  if [ "$_FLAG_ROW_ACTIVE" = 1 ] && [ -z "$_FLAG_ROW_VALUE" ]; then
    [ -e "$f" ] && return 0
    mkdir -p "$(_flag_dir)" 2>/dev/null
    touch -d "@$_FLAG_ROW_EPOCH" "$f" 2>/dev/null || return 1
    return 0
  fi
  if [ "$_FLAG_ROW_ACTIVE" = 1 ]; then
    if [ -e "$f" ]; then
      [ "$(cat "$f" 2>/dev/null)" = "$_FLAG_ROW_VALUE" ] && return 0
      file_epoch=$(stat -c %Y "$f" 2>/dev/null) || return 1
      [ "$_FLAG_ROW_EPOCH" -ge "$file_epoch" ] || return 0
    fi
    mkdir -p "$(_flag_dir)" 2>/dev/null
    { printf '%s\n' "$_FLAG_ROW_VALUE" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; } 2>/dev/null || { rm -f "$f.tmp.$$"; return 1; }
    touch -d "@$_FLAG_ROW_EPOCH" "$f" 2>/dev/null
    return 0
  fi
  [ -e "$f" ] || return 0
  file_epoch=$(stat -c %Y "$f" 2>/dev/null) || return 1
  if [ "$_FLAG_ROW_EPOCH" -ge "$file_epoch" ]; then rm -f "$f" 2>/dev/null; fi
  return 0
}

# _flag_apply_row <name> <resp-json> — reconcile flags/<name> to a row already
# fetched (bin/lib/flag-on.sh, BH-5635; a non-ported name only, BH-4153). Same rc as _flag_sync_file for that body: 0
# reconciled, 1 unreadable row or a mirror write that failed. The row seeds this
# process's cache, so a flag_active right after it needs no GET.
_flag_apply_row() {
  local name="$1" resp="$2"
  _FLAG_ROW_FETCHED=0
  if _flag_parse_row "$name" "$resp"; then _FLAG_ROW_RC=0; else _FLAG_ROW_RC=1; fi
  _flag_cache_put "$name"
  [ "$_FLAG_ROW_RC" = 0 ] || return 1
  _flag_mirror "$name"
}

# _flag_sync_file <name> [cached] (flag_sync for a non-ported name) — rc 0 reconciled, 1 outage/unreadable row (or a
# touch that failed), 2 no row (1 and 2 leave the box untouched). A
# fresh GET by default; `cached` (flag_active's read) takes the TTL cache.
_flag_sync_file() {
  local name="${1:-}" rc
  [ -n "$name" ] || return 1
  case "$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "${2:-}" = cached ]; then _flag_row "$name"; else _flag_row "$name" force; fi; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _flag_mirror "$name"
}

# _flag_active_file <name> (flag_active for a non-ported name) — rc 0 when the
# flag is ON (paused). Decides from the row
# (table above); the file is reconciled best-effort and decides only when there
# is no row to read. Sets _FLAG_SRC (row | file-newer | no-row | unreadable) for
# the CLI's source line.
_flag_active_file() {
  local name="${1:-}" f fe ans
  [ -n "$name" ] || return 1
  f="$(_flag_dir)/$name"
  case "$name" in *[!A-Za-z0-9._-]*) _FLAG_ROW_RC=1; _FLAG_SRC=unreadable; [ -f "$f" ]; return ;; esac
  # The read and the best-effort mirror; its rc is not the answer, the row is.
  _FLAG_ROW_RC=1; _FLAG_ROW_FETCHED=0
  _flag_sync_file "$name" cached >/dev/null 2>&1
  case "$_FLAG_ROW_RC" in
    0)
      _FLAG_SRC=row
      [ "$_FLAG_ROW_ACTIVE" = 1 ] && return 0
      fe=$(stat -c %Y "$f" 2>/dev/null) || return 1
      [ "$fe" -gt "$_FLAG_ROW_EPOCH" ] || return 1
      _FLAG_SRC=file-newer; return 0 ;;
    2) _FLAG_SRC=no-row; [ -f "$f" ] ;;
    *)
      _FLAG_SRC=unreadable
      if [ -f "$f" ]; then ans=active; else ans=inactive; fi
      # Once per fetch, not per call: a cached outage answers silently until the
      # TTL runs out. _jobs_req already owns the day's ALERTS line.
      [ "$_FLAG_ROW_FETCHED" = 1 ] && jobs_configured \
        && JOBS_ALERT=0 _jobs_log "flag $name: pause_flags row unreadable — decided from flags/$name ($ans)"
      [ "$ans" = active ] ;;
  esac
}

# _flag_set_file <name> on|off [reason] (flag_set for a non-ported name, or
# any name with no worker configured) — the ROW first, then the file. A landed PUT
# seeds the cache, so this process's next flag_active needs no GET. A failed
# PUT (outage, or no worker configured) STILL writes the file and returns 1:
# that file is the local brake during the outage (bin/cost-local-brake.sh), and
# the callers read rc 1 as "not published".
_flag_set_file() {
  local name="${1:-}" state="${2:-}" reason="${3:-}" f body resp upd row_epoch active
  [ -n "$name" ] && [ -n "$state" ] || return 1
  case "$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$state" in
    on|1|true)  state=1 ;;
    off|0|false) state=0 ;;
    *) return 1 ;;
  esac
  f="$(_flag_dir)/$name"
  body=$(jq -nc --arg n "$name" --argjson a "$state" --arg act "$JOBS_BOX" --arg r "$reason" \
    '{name:$n,active:$a,actor:$act} + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null)
  if [ -z "$body" ] || ! resp=$(_jobs_req PUT /api/flags "$body"); then
    _flag_cache_drop "$name"
    mkdir -p "$(_flag_dir)" 2>/dev/null
    if [ "$state" = 1 ]; then touch "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
    return 1
  fi
  # Stamp the row's time onto the file, so the file and its row are equal and
  # a later console write wins. No readable updated_at, or a failed touch, is
  # NOT a failure: the file then carries "now", and any later row is later still.
  upd=$(printf '%s' "$resp" | jq -r '.flag.updated_at // empty' 2>/dev/null)
  active=$(printf '%s' "$resp" | jq -r '.flag.active // empty' 2>/dev/null)
  if row_epoch=$(_flag_epoch "$upd") && [ "$active" = "$state" ]; then
    _FLAG_ROW_RC=0; _FLAG_ROW_ACTIVE=$state; _FLAG_ROW_EPOCH=$row_epoch; _FLAG_ROW_UPD=$upd; _FLAG_ROW_VALUE=""
    _flag_cache_put "$name"
  else
    # The answer is not the row we wrote: let the next read ask.
    _flag_cache_drop "$name"; row_epoch=""
  fi
  mkdir -p "$(_flag_dir)" 2>/dev/null
  if [ "$state" = 1 ]; then
    if [ -n "$row_epoch" ]; then touch -d "@$row_epoch" "$f" 2>/dev/null || touch "$f" 2>/dev/null
    else touch "$f" 2>/dev/null; fi
  else
    rm -f "$f" 2>/dev/null
  fi
  return 0
}


# --- BH-4153: harness_flags verbs ---------------------------------------------
FLAG_PORTED_RE='^(paused-.+|automerge-disabled|automerge-disabled-.+|lanedown-.+|dispatch-mode-.+)$'

_flag_ported()        { [[ "${1:-}" =~ $FLAG_PORTED_RE ]]; }
_flag_name_ok()       { [ -n "${1:-}" ] && [[ "$1" != *[!A-Za-z0-9._-]* ]]; }
_flag_scope_ok()      { [ -n "${1:-}" ] && [ "${#1}" -le 64 ] && [[ "$1" != *[!A-Za-z0-9._-]* ]]; }
_flag_db_configured() { [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]; }
_flag_now()           { date -u +%s; }
_flag_uri()           { jq -rn --arg v "${1:-}" '$v|@uri'; }
# _flag_row_path <name> <scope> — the GET path; fleet is the worker's default,
# so it rides no query (and every pre-BH-4153 caller's URL is unchanged).
_flag_row_path() { if [ "$2" = fleet ]; then printf '/api/flags/%s' "$1"; else printf '/api/flags/%s?scope=%s' "$1" "$(_flag_uri "$2")"; fi; }

# _flag_default_scope <name> — fleet, or this box for lanedown-*. rc 1 when the
# box is unknown: a lanedown row is never written under the wrong box.
_flag_default_scope() {
  case "${1:-}" in
    lanedown-*) _flag_scope_ok "${JOBS_BOX:-}" || return 1; printf '%s' "$JOBS_BOX" ;;
    *) printf fleet ;;
  esac
}

_flag_cache_dir()  { printf '%s/state/flags-cache/%s' "$JOBS_HARNESS" "$1"; }
_flag_cache_path() { printf '%s/%s' "$(_flag_cache_dir "$1")" "$2"; }
_flag_cache_read() { # _flag_cache_read <scope> <name> -> the JSON line, or nothing
  local f; f=$(_flag_cache_path "$1" "$2")
  [ -s "$f" ] || return 1
  jq -ce 'select(type == "object" and (.on | type) == "boolean")' "$f" 2>/dev/null
}
_flag_cache_write() { # _flag_cache_write <scope> <name> <on true|false> <src> <stamp> [row-json] [from]
  local d f row="${6:-}" from="${7:-}"; [ -n "$row" ] || row='{}'
  d=$(_flag_cache_dir "$1"); f="$d/$2"
  mkdir -p "$d" 2>/dev/null || return 1
  jq -nc --argjson on "$3" --arg src "$4" --argjson st "$5" --argjson r "$row" --arg from "$from" \
    '{on:$on, value:($r.value // null), set_at:($r.set_at // null), cleared_at:($r.cleared_at // null), src:$src, stamp:$st}
     + (if $from == "" then {} else {from:$from} end)' \
    > "$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f"
}

# _flag_written (stdin: the worker's answer) — rc 0 when a 200 says the write
# committed but the read-back had no row: writePorted's {flag:null, written:true}
# under a D1 overload (BH-6805). A landed write, never re-sent.
_flag_written() { jq -e '(.written == true) and (.flag == null)' >/dev/null 2>&1; }

# _flag_norm <name> <scope>  (stdin: the worker's answer) -> {name,scope,value,set_at,cleared_at}
# for .flag, or nothing. A legacy pause_flags row (no set_at) is projected the
# way the worker projects one; anything else is unreadable.
_flag_norm() {
  jq -ce --arg n "$1" --arg s "$2" '.flag // empty
    | if (.set_at | type) == "string" then
        {name, scope:(.scope // "fleet"), value:(.value // null), set_at, cleared_at:(.cleared_at // null)}
      elif ((.active == 0 or .active == 1) and (.updated_at | type) == "string") then
        {name, scope:"fleet", value:null, set_at:.updated_at, cleared_at:(if .active == 1 then null else .updated_at end)}
      else empty end
    | select(.name == $n and .scope == $s)' 2>/dev/null
}
# _flag_row_epoch <norm-row> -> epoch of cleared_at // set_at; rc 1 unreadable.
_flag_row_epoch() {
  local set_at cl
  set_at=$(jq -r '.set_at // empty' <<<"$1" 2>/dev/null); cl=$(jq -r '.cleared_at // empty' <<<"$1" 2>/dev/null)
  _flag_epoch "$set_at" >/dev/null || return 1
  if [ -n "$cl" ]; then _flag_epoch "$cl"; else _flag_epoch "$set_at"; fi
}

# _flag_args: the shared [--scope S] [--cached] [--hold-local] [--local-only]
# parse. Sets _FA_SCOPE _FA_CACHED _FA_HOLD _FA_LOCAL and _FA_REST (an array).
_flag_args() {
  _FA_SCOPE=""; _FA_CACHED=0; _FA_HOLD=0; _FA_LOCAL=0; _FA_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) _FA_SCOPE="${2:-}"; shift 2 || return 1 ;;
      --cached) _FA_CACHED=1; shift ;;
      --hold-local) _FA_HOLD=1; shift ;;
      --local-only) _FA_LOCAL=1; shift ;;
      *) _FA_REST+=("$1"); shift ;;
    esac
  done
}
# _flag_scope_for <name> — the scope a verb uses: --scope, else the default.
_flag_scope_for() {
  if [ -n "$_FA_SCOPE" ]; then _flag_scope_ok "$_FA_SCOPE" && printf '%s' "$_FA_SCOPE"; return; fi
  _flag_default_scope "$1"
}

# _flag_store <scope> <name> <norm-row> — a row the worker answered goes into
# the cache, unless a local hold is NEWER than the row (BH-1370: ties go to the
# row). rc 0 always.
_flag_store() {
  local scope="$1" name="$2" row="$3" cur stamp rt on
  rt=$(_flag_row_epoch "$row") || return 0
  cur=$(_flag_cache_read "$scope" "$name")
  if [ "$(jq -r '.src' <<<"$cur" 2>/dev/null)" = local ]; then
    stamp=$(jq -r '.stamp // 0' <<<"$cur" 2>/dev/null)
    [ "${stamp%.*}" -gt "$rt" ] 2>/dev/null && return 0
  fi
  on=$(jq -r 'if .cleared_at == null then "true" else "false" end' <<<"$row")
  _flag_cache_write "$scope" "$name" "$on" db "$(_flag_now)" "$row"
  return 0
}

flag_fetch() { # flag_fetch [--scope S] <name>
  _flag_args "$@" || return 1
  local name="${_FA_REST[0]:-}" scope resp rc row cur
  _flag_name_ok "$name" || return 1
  scope=$(_flag_scope_for "$name") || return 1
  resp=$(_jobs_req GET "$(_flag_row_path "$name" "$scope")"); rc=$?
  case "$rc" in
    0) row=$(printf '%s' "$resp" | _flag_norm "$name" "$scope")
       if [ -z "$row" ] || ! _flag_row_epoch "$row" >/dev/null; then
         JOBS_ALERT=0 _jobs_log "flag $name: row unreadable ($(head -c 120 <<<"$resp")) — answered from the cache, never as off"
         return 1
       fi
       _flag_store "$scope" "$name" "$row"; return 0 ;;
    2) cur=$(_flag_cache_read "$scope" "$name")
       # No row is a real "off", but never over a local hold: nothing written
       # after the hold contradicts it.
       [ "$(jq -r '.src' <<<"$cur" 2>/dev/null)" = local ] \
         || _flag_cache_write "$scope" "$name" false db "$(_flag_now)"
       return 2 ;;
    *) return 1 ;;
  esac
}

# _flag_seed_file <scope> <name> — a legacy flags/<name> the import could not
# move yet is still a pause: a local hold stamped with the file's mtime, unless
# the cache already holds something at least as new. The hold is marked
# from:"file" because the FILE is its only evidence: once the file is gone (an
# operator's `rm`, which resumed the box before BH-4153 and still does), the
# hold goes with it.
_flag_seed_file() {
  local scope="$1" name="$2" f mt cur ct
  f="$(_flag_dir)/$name"
  if [ ! -f "$f" ]; then
    cur=$(_flag_cache_read "$scope" "$name")
    if [ "$(jq -r '.src + ":" + (.from // "")' <<<"$cur" 2>/dev/null)" = local:file ]; then
      rm -f "$(_flag_cache_path "$scope" "$name")"
      JOBS_ALERT=0 _jobs_log "flag $name: flags/$name is gone, so the local hold seeded from it is dropped"
    fi
    return 0
  fi
  mt=$(stat -c %Y "$f" 2>/dev/null) || return 0
  cur=$(_flag_cache_read "$scope" "$name")
  if [ -n "$cur" ]; then
    if [ "$(jq -r .src <<<"$cur")" = local ]; then ct=$(jq -r '.stamp // 0' <<<"$cur")
    else ct=$(_flag_row_epoch "$cur") || ct=0; fi
    [ "${ct%.*}" -ge "$mt" ] 2>/dev/null && return 0
  fi
  _flag_cache_write "$scope" "$name" true local "$mt" "" file
}

flag_has() { # flag_has [--scope S] [--cached] <name>
  _flag_args "$@" || return 1
  local name="${_FA_REST[0]:-}" cached="$_FA_CACHED" scope frc=1 irc=0 cur src out
  FLAG_SRC=unknown
  _flag_name_ok "$name" || return 1
  if ! _flag_ported "$name" || ! _flag_db_configured; then
    FLAG_SRC=file
    if [ "$cached" = 1 ]; then [ -f "$(_flag_dir)/$name" ]; return; fi
    _flag_active_file "$name"; return
  fi
  scope=$(_flag_scope_for "$name") || return 2
  if [ -f "$(_flag_dir)/$name" ]; then
    # The lazy import: a box that still sees a legacy file moves it first, so
    # no pause waits for the daily import to be honoured.
    # A file this box does not own stays a local hold (kept-local), and is
    # not logged on every read.
    if [ "$cached" = 0 ]; then
      out=$(_flag_import_one "$name" 2>/dev/null); irc=$?
      case "$out" in ""|kept-local\ *) ;; *) JOBS_ALERT=0 _jobs_log "flag import: $out" ;; esac
    fi
  fi
  _flag_seed_file "$scope" "$name"
  if [ "$cached" = 0 ] && [ "$irc" != 75 ]; then
    flag_fetch --scope "$scope" "$name" >/dev/null 2>&1; frc=$?
  fi
  cur=$(_flag_cache_read "$scope" "$name") || return 2
  src=$(jq -r .src <<<"$cur")
  if [ "$src" = local ]; then FLAG_SRC=local
  elif [ "$frc" = 0 ] || [ "$frc" = 2 ]; then FLAG_SRC=db
  else FLAG_SRC=cache; fi
  [ "$(jq -r .on <<<"$cur")" = true ]
}

flag_set() { # flag_set [--scope S] [--hold-local] <name> [on|off|<value>] [reason]
  _flag_args "$@" || return 1
  local name="${_FA_REST[0]:-}" state="${_FA_REST[1]:-on}" reason="${_FA_REST[2]:-}" hold="$_FA_HOLD" scope value="" body resp row
  _flag_name_ok "$name" || return 1
  case "$state" in
    off|0|false)
      if [ "$_FA_LOCAL" = 1 ]; then flag_clear ${_FA_SCOPE:+--scope "$_FA_SCOPE"} --local-only "$name" "$reason"
      else flag_clear ${_FA_SCOPE:+--scope "$_FA_SCOPE"} "$name" "$reason"; fi
      return ;;
  esac
  if [ "$_FA_LOCAL" = 1 ]; then
    if ! _flag_ported "$name" || ! _flag_db_configured; then
      mkdir -p "$(_flag_dir)" 2>/dev/null; touch "$(_flag_dir)/$name" 2>/dev/null; return
    fi
    scope=$(_flag_scope_for "$name") || return 1
    _flag_cache_write "$scope" "$name" true local "$(_flag_now)"; return
  fi
  if ! _flag_ported "$name" || ! _flag_db_configured; then
    _flag_set_file "$name" "${_FA_REST[1]:-}" "$reason"; return
  fi
  case "$state" in on|1|true) ;; *) value="$state" ;; esac
  scope=$(_flag_scope_for "$name") || return 1
  body=$(jq -nc --arg n "$name" --arg s "$scope" --arg act "${JOBS_BOX:-}" --arg r "$reason" --arg v "$value" \
    '{name:$n,active:1,scope:$s,actor:$act} + (if $r == "" then {} else {reason:$r} end) + (if $v == "" then {} else {value:$v} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req PUT /api/flags "$body")
  if [ $? -eq 0 ]; then
    row=$(printf '%s' "$resp" | _flag_norm "$name" "$scope")
    if [ -n "$row" ] && [ "$(jq -r '.cleared_at' <<<"$row")" = null ]; then
      _flag_cache_write "$scope" "$name" true db "$(_flag_now)" "$row"
      rm -f "$(_flag_dir)/$name" 2>/dev/null
      return 0
    fi
    if _flag_written <<<"$resp"; then
      _flag_cache_write "$scope" "$name" true db "$(_flag_now)"
      rm -f "$(_flag_dir)/$name" 2>/dev/null
      JOBS_ALERT=0 _jobs_log "flag $name: written, read-back overloaded — cached without a row"
      return 0
    fi
    JOBS_ALERT=0 _jobs_log "flag $name: PUT answered without an active row — not written"
  fi
  [ "$hold" = 1 ] && _flag_cache_write "$scope" "$name" true local "$(_flag_now)"
  return 1
}

flag_clear() { # flag_clear [--scope S] <name> [reason]
  _flag_args "$@" || return 1
  local name="${_FA_REST[0]:-}" reason="${_FA_REST[1]:-}" scope q resp rc row cur
  _flag_name_ok "$name" || return 1
  if [ "$_FA_LOCAL" = 1 ]; then
    rm -f "$(_flag_dir)/$name" 2>/dev/null
    _flag_ported "$name" && _flag_db_configured || return 0
    scope=$(_flag_scope_for "$name") || return 1
    # Only a LOCAL hold goes; a row-backed answer is the row's to change. The
    # re-read puts the row back in the cache; with the worker down there is
    # nothing, which a stop switch reads as ON, never a guessed "off".
    cur=$(_flag_cache_read "$scope" "$name")
    [ "$(jq -r '.src' <<<"$cur" 2>/dev/null)" = local ] && rm -f "$(_flag_cache_path "$scope" "$name")"
    flag_fetch --scope "$scope" "$name" >/dev/null 2>&1
    return 0
  fi
  if ! _flag_ported "$name" || ! _flag_db_configured; then
    _flag_set_file "$name" off "$reason"; return
  fi
  scope=$(_flag_scope_for "$name") || return 1
  q="name=$(_flag_uri "$name")&scope=$(_flag_uri "$scope")&actor=$(_flag_uri "${JOBS_BOX:-}")"
  [ -n "$reason" ] && q="$q&reason=$(_flag_uri "$reason")"
  resp=$(_jobs_req DELETE "/api/flags?$q"); rc=$?
  if [ "$rc" = 2 ]; then
    # 404: no row — or a worker that predates DELETE. A row a GET can still see
    # is cleared through the legacy PUT; no row at all is already off.
    if _jobs_req GET "$(_flag_row_path "$name" "$scope")" >/dev/null; then
      resp=$(_jobs_req PUT /api/flags "$(jq -nc --arg n "$name" --arg s "$scope" --arg act "${JOBS_BOX:-}" --arg r "$reason" \
        '{name:$n,active:0,scope:$s,actor:$act} + (if $r == "" then {} else {reason:$r} end)')"); rc=$?
    elif [ "${JOBS_HTTP:-}" = 404 ]; then
      _flag_cache_write "$scope" "$name" false db "$(_flag_now)"
      rm -f "$(_flag_dir)/$name" 2>/dev/null
      return 0
    fi
  fi
  if [ "$rc" = 0 ]; then
    row=$(printf '%s' "$resp" | _flag_norm "$name" "$scope")
    if [ -n "$row" ] && [ "$(jq -r '.cleared_at' <<<"$row")" != null ]; then
      _flag_cache_write "$scope" "$name" false db "$(_flag_now)" "$row"
      rm -f "$(_flag_dir)/$name" 2>/dev/null
      return 0
    fi
    if _flag_written <<<"$resp"; then
      _flag_cache_write "$scope" "$name" false db "$(_flag_now)"
      rm -f "$(_flag_dir)/$name" 2>/dev/null
      JOBS_ALERT=0 _jobs_log "flag $name: written, read-back overloaded — cached without a row"
      return 0
    fi
    JOBS_ALERT=0 _jobs_log "flag $name: DELETE answered without a cleared row — not cleared"
  fi
  # A clear that cannot reach the worker undoes a LOCAL hold only (an explicit
  # local resume, stamped now, under the same recency rule). A row-backed ON
  # stays on: nothing local may contradict a row nobody changed.
  cur=$(_flag_cache_read "$scope" "$name")
  [ "$(jq -r '.src' <<<"$cur" 2>/dev/null)" = local ] && _flag_cache_write "$scope" "$name" false local "$(_flag_now)"
  return 1
}

flag_list() { # flag_list [--scope S] [--cached] <prefix>
  _flag_args "$@" || return 1
  local prefix="${_FA_REST[0]:-}" cached="$_FA_CACHED" scope resp rc rows trunc d f n got=0
  [[ "$prefix" != *[!A-Za-z0-9._-]* ]] || return 1
  if ! _flag_ported "${prefix}x" || ! _flag_db_configured; then
    for f in "$(_flag_dir)/$prefix"*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done
    return 0
  fi
  scope=$(_flag_scope_for "${prefix}x") || return 2
  d=$(_flag_cache_dir "$scope")
  if [ "$cached" = 0 ]; then
    resp=$(_jobs_req GET "/api/flags?prefix=$(_flag_uri "$prefix")&scope=$(_flag_uri "$scope")&active=1"); rc=$?
    # A legacy worker ignores the filters, so they are applied here too.
    rows=$( [ "$rc" = 0 ] && printf '%s' "$resp" | jq -c --arg p "$prefix" --arg s "$scope" '.flags[]?
      | if (.set_at | type) == "string" then {name, scope:(.scope // "fleet"), value:(.value // null), set_at, cleared_at:(.cleared_at // null)}
        elif ((.active == 0 or .active == 1) and (.updated_at | type) == "string") then
          {name, scope:"fleet", value:null, set_at:.updated_at, cleared_at:(if .active == 1 then null else .updated_at end)}
        else empty end
      | select((.name | startswith($p)) and .scope == $s and .cleared_at == null)' 2>/dev/null)
    if [ "$rc" = 0 ] && printf '%s' "$resp" | jq -e '.flags | type == "array"' >/dev/null 2>&1; then
      got=1
      trunc=$(printf '%s' "$resp" | jq -r '.truncated // false' 2>/dev/null)
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        _flag_store "$scope" "$(jq -r .name <<<"$f")" "$f"
      done <<<"$rows"
      # A cached ON the worker no longer lists is off now, unless the list was
      # capped (then it is not evidence) or the entry is a local hold.
      if [ "$trunc" != true ]; then
        for f in "$d/$prefix"*; do
          [ -f "$f" ] || continue; n=${f##*/}
          case "$n" in *.tmp.*) continue ;; esac
          jq -e '.on == true and .src == "db"' "$f" >/dev/null 2>&1 || continue
          jq -e --arg n "$n" 'select(.name == $n)' >/dev/null 2>&1 <<<"$rows" && continue
          _flag_cache_write "$scope" "$n" false db "$(_flag_now)"
        done
      fi
      mkdir -p "$d" 2>/dev/null && : > "$d/.list-$prefix" 2>/dev/null
    elif [ "$rc" = 0 ]; then
      JOBS_ALERT=0 _jobs_log "flag list $prefix: answer unreadable — answered from the cache"
    fi
  fi
  # No good answer now and none ever for this prefix: unknown, not empty.
  [ "$got" = 1 ] || [ -e "$d/.list-$prefix" ] || return 2
  {
    for f in "$d/$prefix"*; do
      [ -f "$f" ] || continue
      case "${f##*/}" in *.tmp.*) continue ;; esac
      _flag_seed_file "$scope" "${f##*/}"      # a hold whose legacy file is gone goes
      jq -e '.on == true' "$f" >/dev/null 2>&1 && printf '%s\n' "${f##*/}"
    done
    # A legacy file not imported yet is still honoured, in its own scope.
    for f in "$(_flag_dir)/$prefix"*; do
      [ -f "$f" ] && [ "$(_flag_default_scope "${f##*/}" 2>/dev/null)" = "$scope" ] && printf '%s\n' "${f##*/}"
    done
  } | sort -u
  return 0
}

# _flag_box_projects — the projects fleet.conf puts on this box (JOBS_BOX), the
# hub's "local" rows included on the hub; rc 1 when the registry cannot say.
# hub-box.sh is read in a subshell so its functions never land in the caller.
_flag_on_hub() { ( . "$JOBS_HARNESS/bin/lib/hub-box.sh" 2>/dev/null && is_hub_box "${JOBS_BOX:-}" ); }
_flag_box_projects() {
  local fc="$JOBS_HARNESS/bin/fleet-conf.sh" out
  [ -r "$fc" ] && [ -n "${JOBS_BOX:-}" ] || return 1
  # fleet-conf.sh looks at /root/harness/fleet.conf before its own tree; the
  # registry that matters is the one beside this harness (cost-local-brake).
  out=$(FLEET_CONF="${FLEET_CONF:-$JOBS_HARNESS/fleet.conf}" bash "$fc" --projects-on-box "$JOBS_BOX" 2>/dev/null) || return 1
  if _flag_on_hub; then
    out="$out"$'\n'$(FLEET_CONF="${FLEET_CONF:-$JOBS_HARNESS/fleet.conf}" bash "$fc" --projects-on-box local 2>/dev/null)
  fi
  printf '%s\n' "$out"
}
# _flag_owned <name> — rc 0 when a legacy flags/<name> on this box may be
# published as its row: the flag acted here, and here is where it acts.
# Anything the registry cannot confirm is not owned (it stays a local hold).
_flag_owned() {
  local p projs
  case "${1:-}" in
    lanedown-*) return 0 ;;
    automerge-disabled) _flag_on_hub; return ;;
    paused-*) p=${1#paused-} ;;
    automerge-disabled-*) p=${1#automerge-disabled-} ;;
    *) return 1 ;;
  esac
  # Captured, never piped into grep -q: under a caller's pipefail, grep's early
  # exit is a SIGPIPE upstream, and an owned flag would read as not owned.
  projs=$(_flag_box_projects) || return 1
  grep -qxF -- "$p" <<<"$projs"
}

# _flag_import_one <name> [--dry-run] — move one legacy flags/<name> into its
# row (bin/flags-import.sh, and flag_has's lazy import). One line on stdout:
#   imported <name> <scope> | kept-row <name> | kept-local <name> not-owned
#   | failed <name> <why> | would-import <name> <scope>
# rc 0 done (or no file, or kept-local), 1 failed, 75 worker unreachable
# (nothing touched). A file this box does not own (_flag_owned) is never PUT:
# a row at or after its mtime still removes it, otherwise it stays.
# The row wins a tie (BH-1370). The PUT carries expected_set_at, the row time
# the GET saw (or "" for none), so a console write between the GET and the PUT
# is a 409 and a re-read, never a blind overwrite of a fresh clear.
_flag_import_one() {
  local name="${1:-}" dry="${2:-}" f scope mt iso resp rc row rt body tries=0 head
  _flag_name_ok "$name" && _flag_ported "$name" || return 1
  f="$(_flag_dir)/$name"; [ -f "$f" ] || return 0
  scope=$(_flag_default_scope "$name") || { echo "failed $name no-box-scope"; return 1; }
  if [ "$dry" = --dry-run ]; then
    if _flag_owned "$name"; then echo "would-import $name $scope"; else echo "kept-local $name not-owned"; fi
    return 0
  fi
  _flag_db_configured || { echo "failed $name no-jobs-client"; return 75; }
  mt=$(stat -c %Y "$f" 2>/dev/null) || { echo "failed $name unreadable-file"; return 1; }
  iso=$(date -u -d "@$mt" +%Y-%m-%dT%H:%M:%SZ)
  head=$(head -c 200 "$f" 2>/dev/null | tr '\n' ' ')
  while [ "$tries" -lt 2 ]; do
    tries=$((tries + 1))
    resp=$(_jobs_req GET "$(_flag_row_path "$name" "$scope")"); rc=$?
    case "$rc" in
      0) row=$(printf '%s' "$resp" | _flag_norm "$name" "$scope")
         rt=$(_flag_row_epoch "$row") || { echo "failed $name unreadable-row"; return 1; }
         if [ "$rt" -ge "$mt" ]; then
           _flag_store "$scope" "$name" "$row"; rm -f "$f"; echo "kept-row $name"; return 0
         fi
         rt=$(jq -r '.cleared_at // .set_at' <<<"$row") ;;
      2) rt="" ;;
      *) echo "failed $name worker-unreachable"; return 75 ;;
    esac
    _flag_owned "$name" || { echo "kept-local $name not-owned"; return 0; }
    body=$(jq -nc --arg n "$name" --arg s "$scope" --arg act "flags-import:${JOBS_BOX:-}" --arg e "$rt" \
      --arg r "imported from flags/$name on ${JOBS_BOX:-} (mtime $iso)${head:+: $head}" \
      '{name:$n,active:1,scope:$s,actor:$act,reason:$r,expected_set_at:$e}') || { echo "failed $name body"; return 1; }
    resp=$(_jobs_req PUT /api/flags "$body"); rc=$?
    [ "$rc" = 9 ] && continue    # the row moved: read it again, decide again
    [ "$rc" = 0 ] || { echo "failed $name put-rc-$rc"; return 1; }
    row=$(printf '%s' "$resp" | _flag_norm "$name" "$scope")
    if [ -n "$row" ] && [ "$(jq -r .cleared_at <<<"$row")" = null ]; then
      _flag_cache_write "$scope" "$name" true db "$(_flag_now)" "$row"; rm -f "$f"
      echo "imported $name $scope"; return 0
    fi
    if _flag_written <<<"$resp"; then
      _flag_cache_write "$scope" "$name" true db "$(_flag_now)"; rm -f "$f"
      JOBS_ALERT=0 _jobs_log "flag $name: written, read-back overloaded — cached without a row"
      echo "imported $name $scope"; return 0
    fi
    echo "failed $name not-read-back"; return 1
  done
  echo "failed $name moved-twice"; return 1
}

# The two pre-BH-4153 entry points dispatch: a ported name takes the row path,
# every other name the BH-1370 reconcile above, unchanged. Every existing
# `flag_active "paused-$P"` reader is therefore ported with no edit.
flag_sync() { # flag_sync <name> [cached] — rc 0 row read/reconciled, 1 outage/unreadable, 2 no row
  local name="${1:-}"
  if _flag_ported "$name" && _flag_db_configured; then flag_fetch "$name"; return; fi
  _flag_sync_file "$@"
}

flag_active() { # flag_active <name> — rc 0 when the flag is ON
  local name="${1:-}" rc
  [ -n "$name" ] || return 1
  if ! _flag_ported "$name"; then _flag_active_file "$name"; return; fi
  flag_has "$name"; rc=$?
  [ "$rc" = 2 ] || return "$rc"
  case "$name" in
    paused-*|automerge-disabled|automerge-disabled-*)
      JOBS_ALERT=0 _jobs_log "flag $name: unknown (worker unreachable, no cache) — read as ON (stop switch fails closed)"
      return 0 ;;
  esac
  return 2
}
