#!/bin/bash
# bin/staff/watchman-collect.sh — Watchman's collector. bin/staff.sh runs it
# at step 6 of `staff.sh tick watchman` and claims what it prints. No model
# call. GitHub only through gh_rest, and only to close a rotated credential's
# filed issue.
#
# Three checks:
#
#   history-secret  The git history of each fleet repo on this box
#                   (bin/fleet-conf.sh --projects, each at
#                   WM_REPOS_ROOT/<project>), scanned by the pinned gitleaks
#                   (bin/lib/gitleaks-pin.sh) with --redact=100. A project is
#                   DUE when its last attempt (state/staff/watchman/scan/<p>.at)
#                   is older than WM_SCAN_INTERVAL_H, or absent. At most
#                   WM_SCAN_REPOS_PER_TICK repos are scanned per tick, oldest
#                   attempt first. Ref tips equal to the saved cursor
#                   (scan/<p>.tips) = no gitleaks run. Otherwise gitleaks reads
#                   the unscanned commits, oldest first, at most
#                   WM_SCAN_CHUNK_COMMITS per run, while the tick budget
#                   (STAFF_COLLECT_TIMEOUT_S - 20 s) lasts; the cursor moves
#                   after each good chunk, and a timeout halves the chunk.
#                   Read-only: no fetch, no checkout. The repo's own
#                   .gitleaksignore applies. Only RuleID, File, StartLine and
#                   Commit are read from the report; never Secret, Match or
#                   Message. A first scan is held (first/<p>.jsonl) until its
#                   last chunk; over WM_FIRST_SCAN_MAX locations it becomes a
#                   baseline (base/<p>.jsonl) and ONE history-baseline
#                   finding. A location not in the leak cache (leaks/<p>.jsonl)
#                   or the baseline is NEW: it is appended, then ONE beat per
#                   scan run with new locations (bin/lane-alert.sh --id
#                   staff-watchman-leak-<p>-<scan epoch> --severity
#                   WM_PAGE_SEVERITY), then the cursor is saved. A failed scan
#                   (rc != 0, one commit that times out, a report that is not
#                   a list) saves nothing, so the next due scan repeats the
#                   range; the WM_SCAN_FAIL_ALERT-th in a row is one warn beat.
#                   Every tick prints every cached location that is not
#                   allowlisted (below).
#   chat-secret     BH-10122: the Archie chat log (WM_CHAT_LOG, default
#                   /root/orchestrator/conversation-log.md, the record file of
#                   bin/orc-context.sh). Runs first, once a tick. Each record
#                   not in state/staff/watchman/chat/scanned is copied to a
#                   private temp dir and ONE gitleaks `dir` run (--redact=100)
#                   reads them. Only RuleID, File and StartLine are read. A
#                   location {at, record (sha12), part message|reply, line,
#                   rule} not in chat/leaks.jsonl is appended, then ONE beat
#                   (staff-watchman-chat-<epoch>), then the records are marked
#                   scanned. A failed scan marks nothing (`fails _chat`).
#                   Empty WM_CHAT_LOG = off; sandbox with it unset = off.
#   rotation-due    catalog/staff-rotations.d/<id>.json, one file per
#                   credential: {id, where, owner, due} or {id, where, owner,
#                   rotated_at, every_days}. `where` names the file and the
#                   variable, never a value. Fires when now >= due + 1 day,
#                   and writes the latch state/staff/watchman/due/<id> = due.
#
# PATH ALLOWLIST (BH-9423, bin/lib/watchman-allow.sh): a location whose file
# matches WM_PATH_ALLOWLIST (default tests/, __tests__/, e2e/, fixtures/,
# .harness/specs/, *.md), or whose first WM_DUMMY_LINES lines at its commit say
# DUMMY VALUES, stays in the leak cache but makes no beat, does not count toward
# WM_FIRST_SCAN_MAX and is not printed. A baseline whose non-allowlisted count
# is at or under WM_FIRST_SCAN_MAX prints those locations one by one, not its
# baseline finding. One `allowlist skipped=<n> path=<n> dummy=<n>` log line a
# tick. A missing lib = no filter and no rotation register, one warn line.
#
# A ROTATED credential (the register's due is later than the latch, and not
# yet past) closes its finding as merged: GET /api/staff/findings?agent=watchman
# (once, only on a tick with such a latch); a `filed` row with that
# fingerprint gets gh_rest PATCH {"state":"closed","state_reason":"completed"}
# on its issue, then POST /api/staff/outcomes outcome merged, then the latch
# is deleted. A failed PATCH or POST keeps the latch, so the next tick tries
# again; bin/staff-outcomes.sh also maps a closed issue to merged. Not filed
# (digested, already closed) = the latch is deleted and nothing is posted.
#
# Print order: rotation-due by id, then history-baseline, then history-secret and chat-secret by the time each was
# last in the first STAFF_MAX_ITEMS lines (state/staff/watchman/printed.tsv),
# then by location. staff.sh claims only the first STAFF_MAX_ITEMS lines, so a
# backlog cycles through the claim window and nothing is starved.
#
# rc 0: lines or none. rc 1: jq, git or the jobs client missing; nothing
# printed, no beat, no close. A failed scan, install, read, PATCH or POST is a
# log line in logs/staff.log inside rc 0.
#
# Knobs: catalog/lanes.d/_lib.staff-watchman.json, applied with lib_env_apply
# staff-watchman. Out of range is one warn line in logs/staff.log and the
# default, never a clamp.
# Note: docs/notes/2026-10-15-BH-5565-watchman.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
{
  . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  . "$BIN/jobs-client.sh" 2>/dev/null || true
  . "$BIN/lib/gh-rest.sh" 2>/dev/null || true
  . "$BIN/lib/gitleaks-pin.sh" 2>/dev/null || true
  . "$BIN/lib/watchman-allow.sh" 2>/dev/null || true
}
# The suite's seams. Sandbox only, and settable:false in the registry.
NOW_S=""; GL_SEAM=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${WM_FIXTURE:-}" ] && . "$WM_FIXTURE"
  [[ ${WM_NOW:-} =~ ^[0-9]+$ ]] && NOW_S=$WM_NOW
  GL_SEAM="${WM_GITLEAKS:-}"
fi
[ -n "$NOW_S" ] || NOW_S=$(date -u +%s)
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 || exit 1
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-watchman

log()  { mkdir -p "$H/logs" 2>/dev/null; printf '%s agent=watchman %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$H/logs/staff.log" 2>/dev/null; }
warn() { log "warn: $*"; }
# knob_int <name> <value> <default> <min> <max>
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    warn "$1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
INTERVAL_H=$(knob_int WM_SCAN_INTERVAL_H "${WM_SCAN_INTERVAL_H:-24}" 24 1 720)
PER_TICK=$(knob_int WM_SCAN_REPOS_PER_TICK "${WM_SCAN_REPOS_PER_TICK:-1}" 1 1 20)
SCAN_TO=$(knob_int WM_SCAN_TIMEOUT_S "${WM_SCAN_TIMEOUT_S:-90}" 90 10 540)
CHUNK=$(knob_int WM_SCAN_CHUNK_COMMITS "${WM_SCAN_CHUNK_COMMITS:-400}" 400 1 100000)
FIRST_MAX=$(knob_int WM_FIRST_SCAN_MAX "${WM_FIRST_SCAN_MAX:-100}" 100 1 100000)
FAIL_ALERT=$(knob_int WM_SCAN_FAIL_ALERT "${WM_SCAN_FAIL_ALERT:-3}" 3 1 30)
ROOT="${WM_REPOS_ROOT:-/root/repos}"
SEV="${WM_PAGE_SEVERITY:-critical}"
case "$SEV" in
  critical|warn|info|off) ;;
  *) warn "WM_PAGE_SEVERITY=$SEV is not critical, warn, info or off; using the default critical"; SEV=critical ;;
esac
# staff.sh's own claim window (lane_env_apply staff exports it); quiet default.
MAX_ITEMS="${STAFF_MAX_ITEMS:-20}"
[[ $MAX_ITEMS =~ ^[0-9]+$ ]] && [ "$MAX_ITEMS" -ge 1 ] && [ "$MAX_ITEMS" -le 100 ] || MAX_ITEMS=20

WMS="$H/state/staff/watchman"
REGDIR="$H/catalog/staff-rotations.d"
# The chat source (BH-10122). In the sandbox the chat scan is off unless the
# suite names a log, so no suite reads a real hub log. CHAT_GO = scan this
# tick; CHAT_WHY = the one log line when the scan is on but has no log.
CHAT_LOG=""; CHAT_GO=""; CHAT_WHY=""
if [ "${HARNESS_TEST_SANDBOX:-}" != 1 ] || [ -n "${WM_CHAT_LOG+x}" ]; then
  CHAT_LOG="${WM_CHAT_LOG-/root/orchestrator/conversation-log.md}"
  if [ -z "$CHAT_LOG" ]; then CHAT_WHY="WM_CHAT_LOG is empty"
  elif [ -L "$CHAT_LOG" ] || { [ -e "$CHAT_LOG" ] && [ ! -f "$CHAT_LOG" ]; }; then CHAT_WHY="$CHAT_LOG is not a regular file"
  elif [ ! -e "$CHAT_LOG" ]; then CHAT_WHY="no chat log at $CHAT_LOG"
  else CHAT_GO=1; fi
fi
mkdir -p "$WMS/scan" "$WMS/leaks" "$WMS/due" ${CHAT_GO:+"$WMS/chat"} 2>/dev/null || warn "cannot create $WMS; nothing is saved this tick"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wm-collect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# The path allowlist (BH-9423): an allowlisted location stays in the leak
# cache, and is never beaten, counted toward a baseline or printed.
if command -v wm_allow_load >/dev/null 2>&1; then
  wm_allow_load 2> "$TMP/allow.warn"
  while IFS= read -r l; do warn "${l#watchman-allow: warn: }"; done < "$TMP/allow.warn"
else
  warn "bin/lib/watchman-allow.sh is missing; no path allowlist and no rotation register this tick"
  wm_allow_split() { WM_ALLOW_N_PATH=0; WM_ALLOW_N_DUMMY=0; cp "$1" "$2"; }
  wm_register_read() { : > "$2"; }
fi
URL="${CONSOLE_URL:-}"; URL="${URL%/}/staff/watchman"
OBS=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ) || exit 1
# put <file> <content>: temp + rename; rc 1 when it cannot be written.
put() { { printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"; } 2>/dev/null || { rm -f "$1.tmp.$$" 2>/dev/null; return 1; }; }

# ═════ history-secret: which projects are due ════════════════════════════════
: > "$TMP/due"
"$BIN/fleet-conf.sh" --projects 2>/dev/null > "$TMP/projects" || warn "bin/fleet-conf.sh --projects failed; no scan this tick"
while IFS= read -r p; do
  [[ $p =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || continue
  at=$(cat "$WMS/scan/$p.at" 2>/dev/null)
  [[ $at =~ ^[0-9]+$ ]] || at=0
  [ $((NOW_S - at)) -gt $((INTERVAL_H * 3600)) ] && printf '%s\t%s\n' "$at" "$p" >> "$TMP/due"
done < "$TMP/projects"

GL=""; GL_TRIED=0
gitleaks_bin() { # sets GL once per tick; rc 1 = unavailable
  if [ "$GL_TRIED" = 0 ]; then
    GL_TRIED=1
    if [ -n "$GL_SEAM" ]; then
      [ -x "$GL_SEAM" ] && GL=$GL_SEAM
    elif command -v gitleaks_pin_ensure >/dev/null 2>&1 && mkdir -p "$TMP/gl" && gitleaks_pin_ensure "$TMP/gl" 2>/dev/null; then
      GL="$TMP/gl/gitleaks"
    fi
    [ -n "$GL" ] || warn "gitleaks unavailable (the pinned install failed); no scan this tick"
  fi
  [ -n "$GL" ]
}

# The report rows, projected to the location only, validated one by one.
JQ_ROWS='
  if type != "array" then error("not a list") else . end
  | .[] | {rule: .RuleID, file: .File, line: .StartLine, commit: .Commit}
  | if (.commit | type) != "string" or (.commit | test("^[0-9a-f]{40}$") | not) then {bad: "commit"}
    elif (.rule | type) != "string" or (.rule | test("^[A-Za-z0-9_.-]{1,64}$") | not) then {bad: "rule"}
    elif (.line | type) != "number" or .line < 1 or .line != (.line | floor) then {bad: "line"}
    elif (.file | type) != "string" then {bad: "file"}
    else (.file | gsub("[[:cntrl:]]"; "")) as $f
      | if ($f | length) < 1 or ($f | length) > 200 then {bad: "file"}
        else {check: "history-secret", project: $p, commit, file: $f, line, rule} end
    end'

# The time this tick may spend on scans: staff.sh kills the collector at
# STAFF_COLLECT_TIMEOUT_S, and RESERVE_S stays for the rest of the tick. FULL
# is the longest one gitleaks run can get.
BUDGET=$(knob_int STAFF_COLLECT_TIMEOUT_S "${STAFF_COLLECT_TIMEOUT_S:-120}" 120 10 600)
RESERVE_S=20
DEADLINE=$((BUDGET - RESERVE_S))
FULL=$SCAN_TO
if [ "$FULL" -gt "$DEADLINE" ]; then
  FULL=$DEADLINE; [ "$FULL" -lt 10 ] && FULL=10
  warn "WM_SCAN_TIMEOUT_S=$SCAN_TO does not fit STAFF_COLLECT_TIMEOUT_S=$BUDGET; one scan gets at most $FULL s"
fi
HOST=$(hostname 2>/dev/null || echo box)
mkdir -p "$WMS/first" "$WMS/base" 2>/dev/null

# beat <id> <text>: one bin/lane-alert.sh call at WM_PAGE_SEVERITY.
beat() { [ "$SEV" = off ] || "$H/bin/lane-alert.sh" --id "$1" --severity "$SEV" staff "$2" >/dev/null 2>&1; }

# baseline <project> <all locations file> <non-allowlisted locations file>: a
# first scan with more than WM_FIRST_SCAN_MAX non-allowlisted locations. All
# locations go to base/<p>.jsonl, and base/<p>.item is ONE finding that names
# the non-allowlisted count; one beat.
baseline() {
  local p=$1 f=$2 hf=$3 n slug url item title
  n=$(grep -c . "$hf")
  put "$WMS/base/$p.jsonl" "$(cat "$f")" || { warn "cannot write the baseline of $p; its tips are not saved"; return 1; }
  slug=$("$BIN/fleet-conf.sh" "$p" repo 2>/dev/null)
  [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && url="https://github.com/$slug" || url=$URL
  item=$(jq -s -c --arg p "$p" --argjson n "$n" --argjson at "$NOW_S" --arg url "$url" --arg host "$HOST" --arg obs "$OBS" '
    (map(.file) | unique | length) as $files
    | (group_by(.rule) | map({r: .[0].rule, n: length}) | sort_by(-.n, .r) | .[0:3] | map("\(.r) \(.n)") | join(", ")) as $top
    | {item: {check: "history-baseline", project: $p, locations: $n, at: $at},
       title: "Critical: \($n) secret-shaped locations in the git history of \($p) at its first scan (\($files) files; \($top)). Too many to file one by one: review state/staff/watchman/base/\($p).jsonl on \($host), and allowlist test fixtures in the repo .gitleaksignore",
       source: {kind: "staff-security", url: $url, labels: []}, observedAt: $obs, class: "history-baseline"}' "$hf") || return 1
  put "$WMS/base/$p.item" "$item" || { warn "cannot write the baseline finding of $p"; return 1; }
  title=$(jq -r .title <<<"$item")
  beat "staff-watchman-baseline-$p-$NOW_S" "$title"
  log "baseline $p locations=$n (over WM_FIRST_SCAN_MAX=$FIRST_MAX); one finding, beat severity $SEV"
}

# scan <project> <repo>: one gitleaks run over at most the saved chunk size of
# the unscanned commits, oldest first.
#   rc 0 = done: every commit is scanned and the tips are saved.
#   rc 1 = a failed scan (WHY says why); nothing saved.
#   rc 2 = no gitleaks (not an attempt: the project is not stamped).
#   rc 3 = progress: a chunk is saved (or the chunk was halved); more is left.
#   rc 4 = the tick budget is spent; resumed next tick.
# The cursor (scan/<p>.tips) is a set of commits whose whole history is
# scanned. Done = the cursor is the ref tips. The chunk is the first N commits
# of `rev-list --reverse --topo-order --all --not <cursor>`, so it holds the
# parents of each of its commits, and `<its heads> --not <cursor>` reads it
# exactly.
scan() {
  local p=$1 repo=$2 tips saved t notl="" opts grc=0 new sl total n chunk complete heads eff t0 first=0 cur
  local -a args nots
  WHY=""
  tips=$(git -C "$repo" for-each-ref --format='%(objectname)' 2>/dev/null | LC_ALL=C sort -u) \
    || { WHY="git for-each-ref"; log "scan $p failed (git for-each-ref)"; return 1; }
  saved=$(cat "$WMS/scan/$p.tips" 2>/dev/null)
  if [ -f "$WMS/scan/$p.tips" ] && [ "$tips" = "$saved" ]; then
    log "scanned $p unchanged"; return 0
  fi
  gitleaks_bin || return 2
  for t in $saved; do
    [[ $t =~ ^[0-9a-f]{40}$ ]] && git -C "$repo" cat-file -e "$t^{commit}" 2>/dev/null && notl="$notl $t"
  done
  args=(--all); [ -n "$notl" ] && read -ra nots <<<"--not$notl" && args+=("${nots[@]}")
  git -C "$repo" rev-list --reverse --topo-order --parents "${args[@]}" > "$TMP/todo" 2>/dev/null \
    || { WHY="git rev-list"; log "scan $p failed (git rev-list)"; return 1; }
  total=$(grep -c . "$TMP/todo")
  [ -f "$WMS/scan/$p.based" ] || first=1
  if [ "$total" = 0 ] && [ "$first" = 0 ]; then
    put "$WMS/scan/$p.tips" "$tips" || warn "cannot save the tips of $p"
    log "scanned $p new=0 (no new commits)"; return 0
  fi
  chunk=$(cat "$WMS/scan/$p.chunk" 2>/dev/null)
  [[ $chunk =~ ^[0-9]+$ ]] && [ "$chunk" -ge 1 ] && [ "$chunk" -le "$CHUNK" ] || chunk=$CHUNK
  if [ "$total" -le "$chunk" ]; then
    complete=1; n=$total
    opts="--all"; [ -n "$notl" ] && opts="--all --not$notl"
  else
    complete=0; n=$chunk
    head -n "$chunk" "$TMP/todo" > "$TMP/batch"
    heads=$(awk '{ o[NR] = $1; for (i = 2; i <= NF; i++) par[$i] = 1 } END { for (i = 1; i <= NR; i++) if (!(o[i] in par)) print o[i] }' "$TMP/batch" | paste -sd' ')
    opts=$heads; [ -n "$notl" ] && opts="$heads --not$notl"
  fi
  eff=$((DEADLINE - SECONDS)); [ "$eff" -gt "$FULL" ] && eff=$FULL
  [ "$eff" -lt 10 ] && return 4
  rm -f "$TMP/r.json"
  t0=$SECONDS
  timeout "$eff" "$GL" git "$repo" --log-opts "$opts" --redact=100 --gitleaks-ignore-path "$repo" --report-format json \
    --report-path "$TMP/r.json" --exit-code 0 --no-banner >/dev/null 2>&1 || grc=$?
  if [ "$grc" = 124 ]; then
    rm -f "$TMP/r.json"
    if [ "$eff" -lt "$FULL" ]; then log "scan $p stopped at the tick budget ($eff s on $n commits); resumed next tick"; return 4; fi
    if [ "$n" -gt 1 ]; then
      put "$WMS/scan/$p.chunk" "$((n / 2))" || warn "cannot save the chunk size of $p"
      log "scan $p failed (timeout after $eff s on $n commits); the next run reads $((n / 2)) commits"; return 3
    fi
    WHY="timeout after $eff s on 1 commit, $(head -1 "$TMP/todo" | cut -c1-12)"
    log "scan $p failed ($WHY)"; return 1
  fi
  if [ "$grc" != 0 ]; then WHY="gitleaks rc=$grc"; log "scan $p failed ($WHY)"; return 1; fi
  if ! jq -c --arg p "$p" "$JQ_ROWS" "$TMP/r.json" > "$TMP/rows" 2>/dev/null; then
    rm -f "$TMP/r.json"; WHY="the report is not a gitleaks report"; log "scan $p failed ($WHY)"; return 1
  fi
  rm -f "$TMP/r.json"
  # A fast chunk doubles the chunk size again, up to WM_SCAN_CHUNK_COMMITS.
  if [ "$chunk" -lt "$CHUNK" ] && [ $((SECONDS - t0)) -lt $((FULL / 4)) ]; then
    put "$WMS/scan/$p.chunk" "$(( chunk * 2 > CHUNK ? CHUNK : chunk * 2 ))" 2>/dev/null
  fi
  jq -r 'select(.bad) | .bad' "$TMP/rows" | while IFS= read -r b; do log "scan $p: report row skipped ($b fails validation)"; done
  # NEW = not in the cache, the baseline or the held first scan. One canonical line per location.
  touch "$WMS/leaks/$p.jsonl" 2>/dev/null
  jq -c 'select(.bad | not)' "$TMP/rows" | LC_ALL=C sort -u > "$TMP/found"
  cat "$WMS/leaks/$p.jsonl" "$WMS/base/$p.jsonl" "$WMS/first/$p.jsonl" 2>/dev/null | LC_ALL=C sort -u > "$TMP/cached"
  LC_ALL=C comm -23 "$TMP/found" "$TMP/cached" > "$TMP/new"
  sl=1
  if [ "$first" = 1 ]; then
    # The first scan is held in first/<p>.jsonl until its last chunk: no line, no beat.
    if [ -s "$TMP/new" ]; then
      { { cat "$WMS/first/$p.jsonl" 2>/dev/null; cat "$TMP/new"; } > "$WMS/first/$p.jsonl.tmp.$$" && mv -f "$WMS/first/$p.jsonl.tmp.$$" "$WMS/first/$p.jsonl"; } 2>/dev/null \
        || { warn "cannot write the first scan of $p; its tips are not saved"; return 1; }
    fi
    if [ "$complete" = 0 ]; then
      cur=$(git -C "$repo" merge-base --independent $notl $heads 2>/dev/null) || cur="$notl $heads"
      put "$WMS/scan/$p.tips" "$(printf '%s\n' $cur | LC_ALL=C sort -u)" || { warn "cannot save the cursor of $p"; return 1; }
      log "scanned $p chunk of $n of $total commits, first scan held=$(cat "$WMS/first/$p.jsonl" 2>/dev/null | grep -c .)"
      return 3
    fi
    LC_ALL=C sort -u "$WMS/first/$p.jsonl" 2>/dev/null > "$TMP/all"
    wm_allow_split "$TMP/all" "$TMP/allhit" "$ROOT"
    if [ "$(grep -c . "$TMP/allhit")" -gt "$FIRST_MAX" ]; then
      baseline "$p" "$TMP/all" "$TMP/allhit" || return 1
      : > "$TMP/new"
    else
      LC_ALL=C comm -23 "$TMP/all" <(LC_ALL=C sort -u "$WMS/leaks/$p.jsonl") > "$TMP/new"
    fi
  fi
  new=$(grep -c . "$TMP/new")
  if [ "$new" -gt 0 ]; then
    { cat "$WMS/leaks/$p.jsonl" "$TMP/new" > "$WMS/leaks/$p.jsonl.tmp.$$" && mv -f "$WMS/leaks/$p.jsonl.tmp.$$" "$WMS/leaks/$p.jsonl"; } 2>/dev/null \
      || { sl=0; cat "$TMP/new" >> "$TMP/unsaved"; warn "cannot write the leak cache of $p; its tips are not saved"; }
    # Only the non-allowlisted new locations beat (BH-9423).
    local hits
    wm_allow_split "$TMP/new" "$TMP/newhit" "$ROOT"
    hits=$(grep -c . "$TMP/newhit")
    if [ "$hits" = 0 ]; then
      log "scan $p: $new new locations, all allowlisted; no beat"
    elif [ "$SEV" != off ]; then
      local firstt more=""
      firstt=$(jq -s -r 'sort_by(.commit, .file, .line, .rule) | .[0]
        | "Critical: secret in git history: \(.rule) in \(.project) \(.file):\(.line) (commit \(.commit[0:12]))"' "$TMP/newhit")
      [ "$hits" -gt 1 ] && more=" (+$((hits - 1)) more)"
      beat "staff-watchman-leak-$p-$NOW_S" "$firstt$more"
      log "beat $p severity $SEV new=$hits"
    fi
  fi
  [ "$sl" = 1 ] || { WHY="cannot write the leak cache"; return 1; }
  if [ "$first" = 1 ]; then
    put "$WMS/scan/$p.based" "$NOW_S" || { warn "cannot mark the first scan of $p done"; return 1; }
    rm -f "$WMS/first/$p.jsonl"
  fi
  if [ "$complete" = 1 ]; then
    put "$WMS/scan/$p.tips" "$tips" || warn "cannot save the tips of $p"
    log "scanned $p new=$new"
    return 0
  fi
  cur=$(git -C "$repo" merge-base --independent $notl $heads 2>/dev/null) || cur="$notl $heads"
  put "$WMS/scan/$p.tips" "$(printf '%s\n' $cur | LC_ALL=C sort -u)" || warn "cannot save the cursor of $p"
  log "scanned $p chunk of $n of $total commits, new=$new"
  return 3
}

# fails <name> <rc> <why> [<what> <not covered>]: count failed attempts in a
# row; the WM_SCAN_FAIL_ALERT-th one is one warn beat (a repo that is not
# covered is an alert, not a log line). Anything else resets the count.
fails() {
  local f="$WMS/scan/$1.fail" c what="${4:-the history scan of $1}" gap="${5:-its git history is not covered}"
  if [ "$2" != 1 ]; then rm -f "$f" 2>/dev/null; return 0; fi
  c=$(cat "$f" 2>/dev/null); [[ $c =~ ^[0-9]+$ ]] || c=0; c=$((c + 1))
  put "$f" "$c" || warn "cannot count the failures of $1"
  if [ "$c" = "$FAIL_ALERT" ]; then
    "$H/bin/lane-alert.sh" --id "staff-watchman-scanfail-$1-$NOW_S" --severity warn staff \
      "Watchman: $what failed $c times in a row (last: $3); $gap. See logs/staff.log on $HOST" >/dev/null 2>&1
    log "scanfail $1 count=$c; one warn beat"
  fi
}

# ═════ chat-secret (BH-10122): keys pasted into the Archie chat ══════════════
# The chat log is bin/orc-context.sh's record file: `### <iso> · <lane>`, then
# `OPERATOR: <message>`, then `REPLY: <reply>`. A record is a valid header line up
# to its last non-blank line before the next valid header. A `### ` line that
# is not a valid header stays in its record. Text before the first valid
# header is skipped. Each record is scanned once (chat/scanned holds the sha256
# of each scanned record that is still in the log). gitleaks reads a copy of
# each record body (the lines after its header) with --redact=100; only
# RuleID, File and StartLine are read from its report.
# No {n} interval in the regex: mawk has none.
CHAT_RE='^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z · '
JQ_CHAT='
  if type != "array" then error("not a list") else . end
  | .[] | {rule: .RuleID, file: .File, line: .StartLine}
  | if (.rule | type) != "string" or (.rule | test("^[A-Za-z0-9_.-]{1,64}$") | not) then {bad: "rule"}
    elif (.line | type) != "number" or .line < 1 or .line != (.line | floor) then {bad: "line"}
    elif (.file | type) != "string" then {bad: "file"}
    else (.file | split("/") | last) as $b
      | if ($b | test("^r[0-9]+\\.txt$") | not) or ((.file == $b or .file == ($d + "/" + $b)) | not) or ($idx[0][$b] == null) then {bad: "file"}
        else $idx[0][$b] as $i
          | (if $i.reply > 0 and .line >= $i.reply then "reply" else "message" end) as $part
          | {check: "chat-secret", at: $i.at, record: $i.record, part: $part,
             line: (if $part == "reply" then .line - $i.reply + 1 else .line end), rule}
        end
    end'
# wm_chat_scan <log>: rc 0 always; a failure goes through `fails _chat`.
wm_chat_scan() {
  local clog=$1 cd="$WMS/chat" all="$TMP/chatall" sd="$TMP/chat" pre n sha rf rl total=0 todo=0 grc=0 eff new rows why=""
  [ -d "$cd" ] || { warn "cannot create $cd; no chat scan this tick"; return 0; }
  mkdir -p "$all" "$sd" 2>/dev/null || { warn "cannot create a temp dir for the chat scan; no chat scan this tick"; return 0; }
  # Split: a<N>.txt = the whole record (hashed), b<N>.txt = its body (scanned).
  pre=$(awk -v d="$all" -v re="$CHAT_RE" '
    function flush(  i, a, b) {
      if (!n) return
      while (k > 0 && buf[k] == "") k--
      a = d "/a" n ".txt"; b = d "/b" n ".txt"
      printf "%s\n", hdr > a
      printf "" > b
      for (i = 1; i <= k; i++) { printf "%s\n", buf[i] > a; printf "%s\n", buf[i] > b }
      close(a); close(b)
      print n "\t" at > (d "/index")
    }
    $0 ~ re { flush(); n++; hdr = $0; at = substr($0, 5, 20); k = 0; next }
    { if (!n) { pre++; next } buf[++k] = $0 }
    END { flush(); close(d "/index"); print pre + 0 }' "$clog") || { warn "cannot read the chat log $clog; no chat scan this tick"; return 0; }
  [ "$pre" -gt 0 ] 2>/dev/null && log "chat: skipped $pre lines before the first record"
  : > "$TMP/chat.cur"; : > "$TMP/chat.todo"; : > "$TMP/chat.idx"
  if [ -s "$all/index" ]; then
    while IFS=$'\t' read -r n at; do
      sha=$(sha256sum "$all/a$n.txt" | cut -c1-64)
      printf '%s\n' "$sha" >> "$TMP/chat.cur"; total=$((total + 1))
      grep -qxF "$sha" "$cd/scanned" 2>/dev/null && continue
      rf="$sd/r$n.txt"; cp "$all/b$n.txt" "$rf" || { warn "cannot copy a chat record; no chat scan this tick"; return 0; }
      rl=$(grep -n -m1 '^REPLY: ' "$rf" | cut -d: -f1); [ -n "$rl" ] || rl=0
      printf '%s\n' "$sha" >> "$TMP/chat.todo"; todo=$((todo + 1))
      jq -cn --arg b "r$n.txt" --arg at "$at" --arg r "${sha:0:12}" --argjson rl "$rl" '{($b): {at: $at, record: $r, reply: $rl}}' >> "$TMP/chat.idx"
    done < "$all/index"
  fi
  # The scanned set holds only records still in the log.
  LC_ALL=C sort -u "$TMP/chat.cur" -o "$TMP/chat.cur"
  if [ "$todo" = 0 ]; then
    LC_ALL=C sort -u "$cd/scanned" 2>/dev/null | LC_ALL=C comm -12 - "$TMP/chat.cur" > "$TMP/chat.keep"
    cmp -s "$TMP/chat.keep" <(LC_ALL=C sort -u "$cd/scanned" 2>/dev/null) || put "$cd/scanned" "$(cat "$TMP/chat.keep")" \
      || warn "cannot prune $cd/scanned"
    log "chat: scanned 0 new records ($total in the log)"; return 0
  fi
  gitleaks_bin || return 0
  eff=$((DEADLINE - SECONDS)); [ "$eff" -gt "$FULL" ] && eff=$FULL
  if [ "$eff" -lt 10 ]; then log "chat: $todo new records not scanned (the tick budget is spent); scanned next tick"; return 0; fi
  rm -f "$TMP/chat.json"
  timeout "$eff" "$GL" dir "$sd" --redact=100 --gitleaks-ignore-path "$sd" --report-format json \
    --report-path "$TMP/chat.json" --exit-code 0 --no-banner >/dev/null 2>&1 || grc=$?
  if [ "$grc" = 124 ]; then why="timeout after $eff s on $todo records"
  elif [ "$grc" != 0 ]; then why="gitleaks rc=$grc"
  elif ! jq -c --arg d "$sd" --slurpfile idx <(jq -s 'add // {}' "$TMP/chat.idx") "$JQ_CHAT" "$TMP/chat.json" > "$TMP/chat.rows" 2>/dev/null; then
    why="the report is not a gitleaks report"
  fi
  rm -f "$TMP/chat.json"
  if [ -n "$why" ]; then
    log "chat scan failed ($why); nothing marked scanned"
    fails _chat 1 "$why" "the chat scan" "the Archie chat is not covered"; return 0
  fi
  jq -r 'select(.bad) | .bad' "$TMP/chat.rows" | while IFS= read -r b; do log "chat: report row skipped ($b fails validation)"; done
  jq -c 'select(.bad | not)' "$TMP/chat.rows" | LC_ALL=C sort -u > "$TMP/chat.found"
  rows=$(grep -c . "$TMP/chat.found")
  LC_ALL=C comm -23 "$TMP/chat.found" <(LC_ALL=C sort -u "$cd/leaks.jsonl" 2>/dev/null) > "$TMP/chat.new"
  new=$(grep -c . "$TMP/chat.new")
  if [ "$new" -gt 0 ]; then
    if ! put "$cd/leaks.jsonl" "$(cat "$cd/leaks.jsonl" "$TMP/chat.new" 2>/dev/null | LC_ALL=C sort -u)"; then
      log "chat scan failed (cannot write the chat cache); nothing marked scanned"
      fails _chat 1 "cannot write the chat cache" "the chat scan" "the Archie chat is not covered"; return 0
    fi
    if [ "$SEV" != off ]; then
      local firstt more=""
      firstt=$(jq -s -r 'sort_by(.at, .part, .line, .rule) | .[0]
        | "Critical: key-shaped value in the Archie chat: \(.rule) in the \(.part) of \(.at) line \(.line)"' "$TMP/chat.new")
      [ "$new" -gt 1 ] && more=" (+$((new - 1)) more)"
      beat "staff-watchman-chat-$NOW_S" "$firstt$more. Rotate it."
      log "chat: beat severity $SEV new=$new"
    fi
  fi
  if ! put "$cd/scanned" "$(cat "$cd/scanned" "$TMP/chat.todo" 2>/dev/null | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$TMP/chat.cur")"; then
    warn "cannot write $cd/scanned; the new records are scanned again next tick"
  fi
  fails _chat 0 ""
  log "chat: scanned $todo records new=$new rows=$rows"
}

if [ -n "$CHAT_GO" ]; then wm_chat_scan "$CHAT_LOG"
elif [ -n "$CHAT_WHY" ]; then log "chat: $CHAT_WHY; no chat scan"; fi

SCANNED=0
while IFS=$'\t' read -r at p; do
  [ -n "$p" ] || continue
  repo="$ROOT/$p"
  if [ ! -d "$repo/.git" ] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    log "$p has no repo at $repo; not scanned"
    put "$WMS/scan/$p.at" "$NOW_S" || warn "cannot stamp $p"
    continue
  fi
  [ "$SCANNED" -ge "$PER_TICK" ] && break
  SCANNED=$((SCANNED+1))
  # Chunks of one repo run while the tick budget lasts.
  while :; do
    src=0; scan "$p" "$repo" || src=$?
    [ "$src" = 3 ] || break
  done
  if [ "$src" = 2 ]; then fails _gitleaks 1 "the pinned gitleaks install failed"; break; fi
  fails _gitleaks 0 ""
  fails "$p" "$src" "$WHY"
  # Not done (rc 3 or 4) = due again at once, queued behind the projects that
  # waited longer.
  if [ "$src" = 3 ] || [ "$src" = 4 ]; then
    put "$WMS/scan/$p.at" "$((NOW_S - INTERVAL_H * 3600 - 1))" || warn "cannot stamp $p"
  else
    put "$WMS/scan/$p.at" "$NOW_S" || warn "cannot stamp $p"
  fi
  [ "$src" = 4 ] && break
done < <(LC_ALL=C sort -t$'\t' -k1,1n -k2,2 "$TMP/due")

# ═════ rotation register ═════════════════════════════════════════════════════
wm_register_read "$REGDIR" "$TMP/reg" 2> "$TMP/reg.bad"
while IFS= read -r l; do log "watchman: register $l; skipped"; done < "$TMP/reg.bad"
dsec() { date -u -d "$1T00:00:00Z" +%s; }

# ═════ rotated -> merged, before any new latch is written ════════════════════
LISTED=0
findings_list() { # once per tick; rc 1 = unreadable
  if [ "$LISTED" = 0 ]; then
    LISTED=2
    if _jobs_req GET "/api/staff/findings?agent=watchman" > "$TMP/findings" 2>/dev/null \
       && jq -e '.findings | type == "array"' "$TMP/findings" >/dev/null 2>&1; then
      LISTED=1
    else
      log "watchman: findings list unreadable; no close this tick"
    fi
  fi
  [ "$LISTED" = 1 ]
}
ISSUE_RE='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+)$'
for lf in "$WMS/due"/*; do
  [ -f "$lf" ] || continue
  id=$(basename "$lf"); old=$(cat "$lf" 2>/dev/null)
  if [ ! -e "$REGDIR/$id.json" ]; then
    log "watchman: $id is no longer in the register; latch dropped, nothing closed"; rm -f "$lf"; continue
  fi
  new=$(jq -r --arg i "$id" 'select(.id == $i) | .due' "$TMP/reg")
  [ -n "$new" ] && [[ $old =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ $new > $old ]] && [ "$NOW_S" -lt $(( $(dsec "$new") + 86400 )) ] || continue
  fp=$(node --input-type=module -e "import { fingerprint } from '$BIN/../agent-core/src/index.js'; console.log(fingerprint(JSON.parse(process.argv[1])));" \
    "{\"check\":\"rotation-due\",\"credential\":\"$id\",\"due\":\"$old\"}" 2>/dev/null)
  [[ $fp =~ ^[0-9a-f]{64}$ ]] || { log "watchman: cannot compute the fingerprint of $id (node or agent-core missing); retried next tick"; continue; }
  findings_list || break
  row=$(jq -c --arg f "$fp" '[.findings[] | select(.fingerprint == $f)] | .[0] // empty' "$TMP/findings")
  if [ -z "$row" ]; then
    if [ "$(jq -r '.truncated // false' "$TMP/findings")" = true ]; then
      log "watchman: $id rotated; the findings list is truncated and does not hold it; retried next tick"; continue
    fi
    log "watchman: $id rotated; no open finding ${fp:0:12}; latch dropped, nothing posted"; rm -f "$lf"; continue
  fi
  st=$(jq -r '.status // ""' <<<"$row"); url=$(jq -r '.ticket_url // ""' <<<"$row")
  if [ "$st" != filed ] || ! [[ $url =~ $ISSUE_RE ]]; then
    log "watchman: $id rotated; finding ${fp:0:12} is $st, not filed with an issue; latch dropped, nothing posted"; rm -f "$lf"; continue
  fi
  command -v gh_rest >/dev/null 2>&1 || { log "watchman: gh_rest missing; $id not closed; retried next tick"; continue; }
  printf '{"state":"closed","state_reason":"completed"}\n' > "$TMP/patch.json"
  grc=0
  gh_rest PATCH "repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/issues/${BASH_REMATCH[3]}" --input "$TMP/patch.json" > /dev/null 2>&1 || grc=$?
  if [ "$grc" != 0 ]; then
    log "watchman: close of $url failed (rc=$grc HTTP ${GH_REST_STATUS:-}); latch kept, retried next tick"; continue
  fi
  jq -cn --arg f "$fp" --arg u "$url" '{agent: "watchman", fingerprint: $f, outcome: "merged", ticket_url: $u}' > "$TMP/post.json"
  orc=0
  ans=$(_jobs_req_file POST /api/staff/outcomes "$TMP/post.json" 2>/dev/null) || orc=$?
  if [ "$orc" = 0 ] && [ "$(jq -r '.ok // false' <<<"$ans" 2>/dev/null)" = true ]; then
    rm -f "$lf"; log "closed $id as merged ($url)"
  elif [ "$orc" = 9 ]; then
    rm -f "$lf"; log "watchman: $id outcome answered 409 $(jq -r '.error // ""' <<<"$ans" 2>/dev/null); latch dropped"
  else
    log "watchman: $id outcome POST failed (rc=$orc); latch kept, retried next tick"
  fi
done

# ═════ rotation-due lines ════════════════════════════════════════════════════
: > "$TMP/rot"
while IFS= read -r r; do
  id=$(jq -r .id <<<"$r"); due=$(jq -r .due <<<"$r")
  ds=$(dsec "$due") || continue
  [ "$NOW_S" -ge $((ds + 86400)) ] || continue
  jq -c --argjson now "$NOW_S" --argjson ds "$ds" --arg url "$URL" --arg obs "$OBS" '
    {item: {check: "rotation-due", credential: .id, due},
     title: "Rotation past due: \(.id) was due \(.due) (\((($now - $ds) / 86400) | floor) days ago); it lives in \(.where); owner \(.owner)",
     source: {kind: "staff-security", url: $url, labels: []}, observedAt: $obs, class: "rotation-due"}' <<<"$r" >> "$TMP/rot"
  [ "$(cat "$WMS/due/$id" 2>/dev/null)" = "$due" ] || put "$WMS/due/$id" "$due" || warn "cannot write the latch of $id"
done < <(jq -c . "$TMP/reg" | LC_ALL=C sort)

# ═════ history-secret lines, rotated through the claim window ════════════════
declare -A SLUG
: > "$TMP/hist"
for cf in "$WMS/leaks"/*.jsonl "$TMP/unsaved"; do
  [ -s "$cf" ] || continue
  cat "$cf" >> "$TMP/hist"
done
# One baseline finding per project whose first scan held too many
# non-allowlisted locations. A baseline whose non-allowlisted count is now at
# or under WM_FIRST_SCAN_MAX prints those locations one by one instead.
: > "$TMP/basel"
SKIP_PATH=0; SKIP_DUMMY=0
for bf in "$WMS/base"/*.item; do
  [ -s "$bf" ] || continue
  bp=$(basename "$bf" .item)
  wm_allow_split "$WMS/base/$bp.jsonl" "$TMP/basehit" "$ROOT"
  SKIP_PATH=$((SKIP_PATH + WM_ALLOW_N_PATH)); SKIP_DUMMY=$((SKIP_DUMMY + WM_ALLOW_N_DUMMY))
  if [ "$(grep -c . "$TMP/basehit")" -gt "$FIRST_MAX" ]; then
    jq -c . "$bf" >> "$TMP/basel" 2>/dev/null
  else
    cat "$TMP/basehit" >> "$TMP/hist"
  fi
done
LC_ALL=C sort -u "$TMP/hist" -o "$TMP/hist"
wm_allow_split "$TMP/hist" "$TMP/histhit" "$ROOT"
SKIP_PATH=$((SKIP_PATH + WM_ALLOW_N_PATH)); SKIP_DUMMY=$((SKIP_DUMMY + WM_ALLOW_N_DUMMY))
mv -f "$TMP/histhit" "$TMP/hist"
log "allowlist skipped=$((SKIP_PATH + SKIP_DUMMY)) path=$SKIP_PATH dummy=$SKIP_DUMMY"
: > "$TMP/keyed"
while IFS= read -r it; do
  p=$(jq -r .project <<<"$it")
  if [ -z "${SLUG[$p]+x}" ]; then
    s=$("$BIN/fleet-conf.sh" "$p" repo 2>/dev/null)
    [[ $s =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || s=""
    SLUG[$p]=$s
  fi
  k=$(printf '%s' "$it" | sha256sum | cut -c1-64)
  st=$(awk -F'\t' -v k="$k" '$1 == k {print $2; exit}' "$WMS/printed.tsv" 2>/dev/null)
  [[ $st =~ ^[0-9]+$ ]] || st=0
  jq -c --arg k "$k" --argjson st "$st" --arg slug "${SLUG[$p]}" --arg url "$URL" --arg obs "$OBS" '
    {k: $k, st: $st, o: {item: ., title: "Critical: secret in git history: \(.rule) in \(.project) \(.file):\(.line) (commit \(.commit[0:12]))",
      source: {kind: "staff-security", url: (if $slug == "" then $url else "https://github.com/\($slug)/commit/\(.commit)" end), labels: []},
      observedAt: $obs, class: "history-secret"}}' <<<"$it" >> "$TMP/keyed"
done < "$TMP/hist"
# chat-secret lines (BH-10122): every cached chat location, never allowlisted
# (the allowlist is about repo paths). Same printed key and claim window.
if [ -s "$WMS/chat/leaks.jsonl" ]; then
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    k=$(printf '%s' "$it" | sha256sum | cut -c1-64)
    st=$(awk -F'\t' -v k="$k" '$1 == k {print $2; exit}' "$WMS/printed.tsv" 2>/dev/null)
    [[ $st =~ ^[0-9]+$ ]] || st=0
    jq -c --arg k "$k" --argjson st "$st" --arg url "$URL" --arg obs "$OBS" '
      select(.check == "chat-secret")
      | {k: $k, st: $st, o: {item: ., title: "Critical: key-shaped value pasted in the Archie chat: \(.rule) in the \(.part) of \(.at) line \(.line) (record \(.record)). Rotate the credential.",
        source: {kind: "staff-security", url: $url, labels: []}, observedAt: $obs, class: "chat-secret"}}' <<<"$it" >> "$TMP/keyed" 2>/dev/null \
      || log "chat: a line of chat/leaks.jsonl is not JSON; not printed"
  done < "$WMS/chat/leaks.jsonl"
fi
jq -s -c 'sort_by(.st, .o.item.project, .o.item.commit, .o.item.file, .o.item.line, .o.item.rule, .o.item.at, .o.item.record, .o.item.part) | .[]' "$TMP/keyed" > "$TMP/ordered"

ROTN=$(cat "$TMP/rot" "$TMP/basel" | grep -c .)
WIN=$((MAX_ITEMS - ROTN)); [ "$WIN" -lt 0 ] && WIN=0
jq -r --argjson w "$WIN" --argjson now "$NOW_S" -s 'to_entries[] | "\(.value.k)\t\(if .key < $w then $now else .value.st end)"' "$TMP/ordered" > "$TMP/printed" 2>/dev/null
if [ -s "$TMP/ordered" ] || [ -f "$WMS/printed.tsv" ]; then
  { cp "$TMP/printed" "$WMS/printed.tsv.tmp.$$" && mv -f "$WMS/printed.tsv.tmp.$$" "$WMS/printed.tsv"; } 2>/dev/null \
    || warn "cannot write $WMS/printed.tsv; the print order does not rotate this tick"
fi

cat "$TMP/rot" "$TMP/basel"
jq -c '.o' "$TMP/ordered"
exit 0
