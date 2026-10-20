#!/bin/bash
# shellcheck shell=bash
# bin/lib/pool-record.sh — BH-7429 (BH-6896 S2): a pool machine's build record,
# kept OFF the machine. Sourced, never run. fly/builder-runner.sh posts the
# record; the hub reap in bin/fly-pool.sh reads it. One file, so the file list
# cannot drift between the two sides.
#
# WHY. The reap pulled each build-dir file through its own `ssh console` call
# (30 Fly calls and ~1.2 hub CPU s per reaped machine), and a machine that had
# already autostopped answered none of them. The record is the runner's full
# RESULT, every POOL_RECORD_FILES file present in its build dir and the
# failovers.log tail, posted once to POST /api/pool/records
# (worker/jobs/src/routes/pool-records.js). The ssh pull stays the fallback for
# a machine with no usable record.
#
# A RECORD IS ONLY THIS MACHINE'S WHEN IT SAYS SO. The reader asks for this
# machine's newest record posted at or after its spawned_at less
# POOL_RESULT_ROW_SKEW_S (the BH-2643 rule), checks the machine id, and needs a
# RESULT whose line 1 passes bin/result-prefix-ok.sh. It writes only the names
# on the list below, RESULT and failovers.log; any other name is dropped.
#
# ROLLOUT. The lane knob POOL_RECORD_READ (settings row
# lane.fly-pool[.<project>].pool_record_read, default 0). The machine posts and
# the hub reads only where it is 1. A drift between the two reads is safe: hub
# on and machine off is the ssh path; hub off and machine on leaves rows the
# unread retention rule deletes.
#
# Root: ${HARNESS:-${H:-}}; with neither set every function answers rc 1.

# The build-dir files the reap relays to the hub, in the reap's order. The
# reasons for each one are at the ssh pull in bin/fly-pool.sh.
# shellcheck disable=SC2034  # read by bin/fly-pool.sh
POOL_RECORD_FILES=(plan.md review.md security-review.md security-review-run.txt refute-review.md
  merged-review2.md harness-suite-fix.txt
  qa.md e2e.md evidence.md changed-files.txt
  reviewed-sha headbound-outcome headbound-review.md headbound-review-run.txt harness-suite-head.txt
  pipeline.log cost.csv validate.txt red.txt green.txt mutation-check.txt context.json gh-stderr.log
  execute-transcript.md stop-reason.txt ticket-meta.json)

# The machine's own paths. The hub uses them for a skipped file's ssh pull.
POOL_RECORD_MACHINE_BUILDS=/data/harness/builds
POOL_RECORD_MACHINE_FAILOVERS=/data/harness/logs/failovers.log

_pool_record_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_pool_record_name_ok() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }

# pool_record_enabled <project> -> prints 1 or 0. The machine's read of the
# knob: the project row, else the lane-wide row, else 0. A row that is not a
# number, or a read that fails, is 0.
pool_record_enabled() {
  local p="${1:-}" root jc k v
  root=$(_pool_record_root); jc="$root/bin/jobs-client.sh"
  if [ -z "$root" ] || [ ! -x "$jc" ] || ! _pool_record_name_ok "$p"; then echo 0; return 0; fi
  p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  for k in "lane.fly-pool.$p.pool_record_read" lane.fly-pool.pool_record_read; do
    v=$(timeout 30 "$jc" setting-get "$k" 2>/dev/null); case $? in 0) ;; 2) continue ;; *) echo 0; return 0 ;; esac
    v=$(printf '%s' "$v" | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*|0|00) echo 0 ;; *) echo 1 ;; esac
    return 0
  done
  echo 0
}

# pool_record_put <project> <KEY> <machine-id> <result-file> <build-dir|""> <failovers-log|"">
#   One POST of the whole record. A file over POOL_RECORD_FILE_MAX_BYTES
#   (default 1,400,000: base64 then stays under D1's 2 MB row) goes as
#   {name, skipped:true, bytes}; an absent or empty file is left out, as the
#   ssh pull leaves it out. failovers.log is the last POOL_RECORD_FAILOVERS_BYTES
#   (default POOL_RELAY_FAILOVERS_BYTES, else 65536).
#   rc 0 written; rc 9 refused (already reaped); rc 1 anything else. Never fatal.
#   A failed POST is tried up to 3 times with a short backoff (BH-7429 review).
pool_record_put() {
  local p="${1:-}" key="${2:-}" mid="${3:-}" rf="${4:-}" bd="${5:-}" fl="${6:-}"
  local root max fob tmp bdn n f sz rc
  root=$(_pool_record_root)
  [ -n "$root" ] && _pool_record_name_ok "$p" && _pool_record_name_ok "$key" && _pool_record_name_ok "$mid" && [ -s "$rf" ] || return 1
  max="${POOL_RECORD_FILE_MAX_BYTES:-1400000}"; case "$max" in ''|*[!0-9]*) max=1400000 ;; esac
  fob="${POOL_RECORD_FAILOVERS_BYTES:-${POOL_RELAY_FAILOVERS_BYTES:-65536}}"; case "$fob" in ''|*[!0-9]*) fob=65536 ;; esac
  [ "$(wc -c < "$rf")" -le "$max" ] || return 1
  bdn=none
  if [ -n "$bd" ] && [ -d "$bd" ]; then bdn=$(basename "$bd"); else bd=""; fi
  case "$bdn" in [A-Za-z0-9]*) ;; *) bdn=none; bd="" ;; esac
  case "$bdn" in *[!A-Za-z0-9._-]*) bdn=none; bd="" ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pool-record-put.XXXXXX") || return 1
  : > "$tmp/files.jsonl"
  _pool_record_entry() { # <name> <path>
    sz=$(wc -c < "$2" 2>/dev/null) || return 0
    [ "$sz" -gt 0 ] || return 0
    if [ "$sz" -gt "$max" ]; then
      jq -nc --arg n "$1" --argjson b "$sz" '{name:$n,skipped:true,bytes:$b}' >> "$tmp/files.jsonl"
    else
      base64 -w0 "$2" > "$tmp/b64" && jq -nc --arg n "$1" --rawfile b "$tmp/b64" '{name:$n,b64:$b}' >> "$tmp/files.jsonl"
    fi
  }
  _pool_record_entry RESULT "$rf"
  if [ -n "$bd" ]; then
    for n in "${POOL_RECORD_FILES[@]}"; do
      [ -f "$bd/$n" ] && _pool_record_entry "$n" "$bd/$n"
    done
  fi
  if [ -n "$fl" ] && [ -s "$fl" ]; then
    tail -c "$fob" "$fl" > "$tmp/failovers.log" 2>/dev/null && _pool_record_entry failovers.log "$tmp/failovers.log"
  fi
  unset -f _pool_record_entry
  f="$tmp/body.json"
  if ! jq -sc --arg p "$p" --arg k "$key" --arg m "$mid" --arg d "$bdn" \
       '{project:$p,key:$k,machine:$m,build_dir:$d,files:.}' "$tmp/files.jsonl" > "$f" 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  _pool_record_post_retry "$f"; rc=$?
  rm -rf "$tmp"
  case "$rc" in 0) return 0 ;; 9) return 9 ;; *) return 1 ;; esac
}

# _pool_record_post_once <body-file> — one POST. rc 0 written; rc 9 refused
#   (409 already_reaped); rc 1 anything else.
_pool_record_post_once() {
  local root; root=$(_pool_record_root)
  (
    # A record can be several MB: the transport's 8 s default is too short.
    export JOBS_TIMEOUT="${POOL_RECORD_TIMEOUT_S:-60}"
    if ! command -v _jobs_req_file >/dev/null 2>&1; then
      # shellcheck source=bin/jobs-client.sh
      . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
    fi
    _jobs_req_file POST /api/pool/records "$1" >/dev/null
  )
}

# _pool_record_backoff_s — the base wait between POST attempts (default 5 s).
_pool_record_backoff_s() {
  local b="${POOL_RECORD_BACKOFF_S:-5}"; case "$b" in ''|*[!0-9]*) b=5 ;; esac
  echo "$b"
}

# pool_record_post_budget_s — the longest the three attempts can take: each at
#   its timeout, plus the waits between them (1x and 2x the base). A test holds
#   it under the runner's 600 s idle window (fly/builder-runner.sh
#   IDLE_TIMEOUT): the post runs before the idle wait starts.
pool_record_post_budget_s() {
  local t="${POOL_RECORD_TIMEOUT_S:-60}"; case "$t" in ''|*[!0-9]*) t=60 ;; esac
  echo $((3 * t + 3 * $(_pool_record_backoff_s)))
}

# _pool_record_post_retry <body-file> — up to 3 attempts, waiting 1x then 2x the
#   base between them. A 409 (rc 9) is the hub's final answer: not retried.
_pool_record_post_retry() {
  local n rc=1 b; b=$(_pool_record_backoff_s)
  for n in 1 2 3; do
    _pool_record_post_once "$1"; rc=$?
    [ "$rc" = 1 ] || return "$rc"
    [ "$n" = 3 ] || sleep $((b * n))
  done
  return 1
}

# pool_record_get <project> <KEY> <machine-id> <spawned_at> <stage-dir>
#   rc 0 -> this machine's record from this run is written into <stage-dir>
#           (created here), and `<build_dir>\t<skipped names, comma-separated>`
#           is printed. A skipped file is named, not written.
#   rc 2 -> no usable record: none (404), another machine's, no RESULT, or a
#           RESULT line 1 that is not a RESULT. No stage dir is left.
#   rc 1 -> could not tell: worker unreachable, an answer that does not parse
#           or decode, a write that failed, or a spawned_at not in the shape
#           bin/fly-pool.sh writes. No stage dir is left.
pool_record_get() {
  local p="${1:-}" key="${2:-}" mid="${3:-}" spat="${4:-}" stage="${5:-}"
  local root skew sp since ans rc bd allow f sk skipped=""
  root=$(_pool_record_root)
  [ -n "$root" ] && [ -n "$stage" ] && _pool_record_name_ok "$p" && _pool_record_name_ok "$key" && _pool_record_name_ok "$mid" || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  skew="${POOL_RESULT_ROW_SKEW_S:-60}"; case "$skew" in ''|*[!0-9]*) skew=60 ;; esac
  # STAMP's shape ('%Y-%m-%d %H:%M:%SZ'), or the ISO one; nothing else reaches
  # date(1), which would read "" as today.
  case "$spat" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][\ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  sp=$(date -u -d "${spat/T/ }" +%s 2>/dev/null) || return 1
  since=$(date -u -d "@$((sp - skew))" +%Y-%m-%dT%H:%M:%SZ) || return 1
  ans=$(mktemp "${TMPDIR:-/tmp}/pool-record-get.XXXXXX") || return 1
  _jobs_req GET "/api/pool/records?project=$p&key=$key&machine=$mid&since=$since" > "$ans"; rc=$?
  case "$rc" in 0) ;; 2) rm -f "$ans"; return 2 ;; *) rm -f "$ans"; return 1 ;; esac
  if ! jq -e '.record.files | type == "array"' "$ans" >/dev/null 2>&1; then rm -f "$ans"; return 1; fi
  if [ "$(jq -r '.record.machine // ""' "$ans")" != "$mid" ]; then rm -f "$ans"; return 2; fi
  bd=$(jq -r '.record.build_dir // ""' "$ans")
  case "$bd" in [A-Za-z0-9]*) ;; *) rm -f "$ans"; return 1 ;; esac
  case "$bd" in *[!A-Za-z0-9._-]*) rm -f "$ans"; return 1 ;; esac
  # One jq pass: the allowed files as `name<TAB>skipped<TAB>body`. base64 has
  # no tab or newline, and a name off the list never gets this far. One awk
  # writes each body to <name>.b64 and the bodiless index; one base64 -d each.
  allow=$(printf '%s\n' RESULT failovers.log "${POOL_RECORD_FILES[@]}")
  mkdir -p "$stage" || { rm -f "$ans"; return 1; }
  if ! jq -r --arg allow "$allow" '($allow | split("\n")) as $a | .record.files[]
        | select((.name | type) == "string" and (.name as $n | any($a[]; . == $n)))
        | [.name, (if (.skipped // 0) == 0 and (.body | type) == "string" then "0" else "1" end), (.body // "")] | @tsv' \
        "$ans" > "$stage/.tsv" 2>/dev/null \
     || ! awk -F'\t' -v d="$stage" '{ print $1 "\t" $2 > (d "/.index") }
          $2 == "0" { f = d "/" $1 ".b64"; printf "%s", $3 > f; close(f) }' "$stage/.tsv"; then
    rm -f "$ans"; rm -rf "$stage"; return 1
  fi
  rm -f "$ans" "$stage/.tsv"
  touch "$stage/.index"
  while IFS=$'\t' read -r f sk; do
    if [ "$sk" = 1 ]; then skipped="${skipped:+$skipped,}$f"; continue; fi
    if ! base64 -d "$stage/$f.b64" > "$stage/$f" 2>/dev/null; then rm -rf "$stage"; return 1; fi
    rm -f "$stage/$f.b64"
  done < "$stage/.index"
  rm -f "$stage/.index"
  if [ ! -s "$stage/RESULT" ] || ! "$root/bin/result-prefix-ok.sh" "$(head -1 "$stage/RESULT")"; then
    rm -rf "$stage"; return 2
  fi
  printf '%s\t%s\n' "$bd" "$skipped"
}

# pool_record_install <stage-dir> <local-dir> <machine-id> <machine-state> <get-output>
#   Moves the staged files into the hub build dir, then fetches each skipped
#   file the ssh way when the machine is `started` (the caller's mexec). Prints
#   `<files now in local-dir> <skipped count> <names left absent, comma-separated>`.
#   The stage dir is removed. rc 1 when a move failed.
pool_record_install() {
  local stage="${1:-}" local_dir="${2:-}" mid="${3:-}" mstate="${4:-}" info="${5:-}"
  local bd skipped f n=0 m=0 absent="" t rc=0
  [ -d "$stage" ] && [ -d "$local_dir" ] || return 1
  bd="${info%%$'\t'*}"; skipped="${info#*$'\t'}"; [ "$skipped" = "$info" ] && skipped=""
  for f in "$stage"/*; do
    [ -f "$f" ] || continue
    mv -f "$f" "$local_dir/" || rc=1
  done
  rm -rf "$stage"
  local -a names=()
  [ -n "$skipped" ] && IFS=, read -r -a names <<<"$skipped"
  for f in "${names[@]}"; do
    m=$((m+1))
    if [ "$mstate" = started ] && command -v mexec >/dev/null 2>&1 && t=$(mktemp "${TMPDIR:-/tmp}/pool-record-pull.XXXXXX"); then
      if [ "$f" = failovers.log ]; then
        mexec "$mid" "tail -c ${POOL_RELAY_FAILOVERS_BYTES:-65536} $POOL_RECORD_MACHINE_FAILOVERS 2>/dev/null | base64 -w0" > "$t"
      else
        mexec "$mid" "base64 -w0 $POOL_RECORD_MACHINE_BUILDS/$bd/$f 2>/dev/null" > "$t"
      fi
      if [ -s "$t" ]; then base64 -d "$t" > "$local_dir/$f" 2>/dev/null || rm -f "$local_dir/$f"; fi
      rm -f "$t"
    fi
    [ -s "$local_dir/$f" ] || { rm -f "$local_dir/$f"; absent="${absent:+$absent,}$f"; }
  done
  for f in "$local_dir"/*; do [ -f "$f" ] && n=$((n+1)); done
  printf '%s %s %s\n' "$n" "$m" "$absent"
  return "$rc"
}

# pool_record_reaped <project> <KEY> <machine-id> <build_dir> — the stamp.
#   rc 0 stamped (or nothing left to stamp); rc 1 not. The caller says a
#   failure once; the unread retention rule deletes the rows either way.
pool_record_reaped() {
  local body
  command -v _jobs_req >/dev/null 2>&1 || return 1
  body=$(jq -nc --arg p "${1:-}" --arg k "${2:-}" --arg m "${3:-}" --arg d "${4:-}" \
    '{project:$p,key:$k,machine:$m,build_dir:$d}' 2>/dev/null) || return 1
  _jobs_req POST /api/pool/records/reaped "$body" >/dev/null
}
