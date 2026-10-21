#!/bin/bash
# bin/pool-tick-summary.sh — HUB only, every 2 minutes behind the hub lease
# (BH-7709): why do a pool project's queued rows not spawn? It reads the tail
# of logs/fly-pool.log ONCE, and in one awk pass finds each pool project's last
# tick, classifies that tick's row lines to one decision per key, decides what
# stopped the last tick or the last start, and counts the project's env bundle
# failures and max-ticks waits of the last hour and its respawns of today. Then
# it POSTs one row per project to /api/pool/tick-summary. GET /api/pool/status
# returns that row to the MCP pool_status tool and to the BH-7725 collector.
#
# On 2026-10-20 the project-6-os pool had 126 queued and 2 running for hours.
# The cause (env bundle ssh failures, max-ticks 4 of 4, a 600 s tick budget that
# decided 26 of 126 rows) took grep work on the hub. Every fact is already one
# `say` line in logs/fly-pool.log; this lane reads them, bin/fly-pool.sh is not
# changed. The line table is in docs/notes/2026-10-21-BH-7709-pool-status-mcp.md.
#
# THE RULES.
#   Tick window: a tick of P starts at its header line (`pool P: queued=…`) and
#   runs to the line before P's next header, or the tail end.
#   Attempt lines: `max-ticks: <n> of <cap> running — P waits` (the tick wrapper
#   refused a start), and P's own `load-shed … — no spawns this tick (reap ran)`
#   and `spawn hold: the runner lane failed (` (a start that exits before the
#   header). Each one proves P's tick lock was free, so the tick before it ended.
#   Last tick: the newest header H, when a line proves it ended: no line of P
#   in the last POOL_TICK_SUMMARY_QUIET_S seconds, a window stop line of P
#   after H, or an attempt line of P after H. Else the tick before H, with
#   in_progress_since = H's time. No header: tick null and a reason.
#   window_stop: budget, age or code from a stop line in the window, else done.
#   stop: the newest attempt line of P, when it comes after the last tick's end
#   and after the newest header (max-ticks | shed | hold; max-ticks carries its
#   cap and knob POOL_TICK_MAX_PARALLEL). Else the window_stop. This lane never
#   writes stop "cap": no log line proves a cap stop.
#   One decision per key: spawned if the key has a spawned line, else the class
#   of its FIRST classified line. A key token that is not [A-Za-z0-9._-]{1,64}
#   is dropped. At most 500 decisions are sent (decisions_truncated); the
#   rows_decided and rows_spawned totals count every key.
#   started_at is the header time; ended_at the time of the last decision or
#   stop line of the window, else the header time.
#   The hour counts read every line of P in the tail, not only the window.
#   Respawns: the `spawned <mid> for <K> (` lines of P dated today (UTC), keys
#   with 2 or more, at most 50 (respawns_truncated), count desc then key.
#   last_result is the first word of P's newest `reaped <K> from <mid>: ` line.
#   respawns_since is the later of today's 00:00Z and the first tail line.
#
# A RECORDER, NOT AN ALERTER. The one ALERTS line is a bad knob: exit 1, nothing
# read. No pool project: one log line, exit 0, nothing posted. A missing log:
# rows with tick null, reason "no pool log". A failed POST: one log line,
# exit 0; the next run sends again. DEDUPE: flock -n on
# locks/pool-tick-summary.lock, skip if held, never wait.
#
# Off: flags/lane-off-pool-tick-summary or bin/harness-ctl.sh off pool-tick-summary.
# Knobs (settings rows lane.pool-tick-summary.*): POOL_TICK_SUMMARY_TAIL_LINES
# (default 20000, 1000..200000), POOL_TICK_SUMMARY_QUIET_S (default 120, 30..1800).
# Test seams: HARNESS, POOL_TICK_SUMMARY_NOW (epoch seconds). Never set these in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-pool-tick-summary
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off pool-tick-summary.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pool-tick-summary
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pool-tick-summary

LOG="$HARNESS/logs/pool-tick-summary.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) pool-tick-summary: $*" >> "$LOG"; }
mkdir -p "$HARNESS/locks" "$HARNESS/logs"
exec 9>"$HARNESS/locks/pool-tick-summary.lock"
flock -n 9 || exit 0

# knob <NAME> <value> <min> <max>: a whole number inside the range, else one
# ALERTS line and exit 1. An out-of-range value is refused, never clamped.
knob() {
  case "$2" in
    ''|*[!0-9]*|0?*) ;;
    *) [ "${#2}" -le 7 ] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] && return 0 ;;
  esac
  "$HARNESS/bin/alert-line.sh" --id pool-tick-summary-knob \
    "[pool-tick-summary] $1='$2' is not a whole number from $3 to $4, so no pool tick summary was read. Set the settings row lane.pool-tick-summary.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') (or env/global.env) to a value in that range." \
    >/dev/null 2>&1 9>&-
  exit 1
}
TAIL_N="${POOL_TICK_SUMMARY_TAIL_LINES:-20000}"; knob POOL_TICK_SUMMARY_TAIL_LINES "$TAIL_N" 1000 200000
QUIET="${POOL_TICK_SUMMARY_QUIET_S:-120}";       knob POOL_TICK_SUMMARY_QUIET_S "$QUIET" 30 1800
NOW="${POOL_TICK_SUMMARY_NOW:-$(date -u +%s)}"

# The pool projects: the same flags/fly-pool-* list bin/fly-pool-tick.sh walks.
PROJECTS=()
for f in "$HARNESS"/flags/fly-pool-*; do
  [ -f "$f" ] || continue
  case "$f" in *fly-pool-app-*) continue ;; esac
  p="${f##*fly-pool-}"
  case "$p" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  [ "${#p}" -le 64 ] || continue
  PROJECTS+=("$p")
done
[ "${#PROJECTS[@]}" -gt 0 ] || { log "no pool project (flags/fly-pool-*); nothing posted"; exit 0; }
[ "${#PROJECTS[@]}" -le 200 ] || PROJECTS=("${PROJECTS[@]:0:200}")

# Times compare as "YYYY-MM-DD HH:MM:SS" strings, so the awk needs no clock.
C_HOUR=$(date -u -d "@$((NOW - 3600))" '+%Y-%m-%d %H:%M:%S')
C_QUIET=$(date -u -d "@$((NOW - QUIET))" '+%Y-%m-%d %H:%M:%S')
TODAY=$(date -u -d "@$NOW" '+%Y-%m-%d')
POOL_LOG="$HARNESS/logs/fly-pool.log"
HAVE_LOG=1; [ -f "$POOL_LOG" ] || HAVE_LOG=0

summarize() {
  awk -v projects="${PROJECTS[*]}" -v have_log="$HAVE_LOG" -v tail_n="$TAIL_N" \
      -v c_hour="$C_HOUR" -v c_quiet="$C_QUIET" -v today="$TODAY" -v max_dec=500 '
function starts(s, pre) { return substr(s, 1, length(pre)) == pre }
function before(s, sep,   i) { i = index(s, sep); return i ? substr(s, 1, i - 1) : "" }
function key_ok(k) { return length(k) <= 64 && k ~ /^[A-Za-z0-9._-]+$/ }
function iso(ts) { return substr(ts, 1, 10) "T" substr(ts, 12, 8) "Z" }
function q(s) { return s == "" ? "null" : "\"" s "\"" }
function num(v) { return v ~ /^[0-9]+$/ ? v + 0 : "null" }
# spawned_key(text): the key of a `spawned <mid> for <K> (` line, or "".
function spawned_key(s,   r, i, k) {
  if (!starts(s, "spawned ")) return ""
  r = substr(s, 9); i = index(r, " for "); if (!i) return ""
  k = before(substr(r, i + 5), " ("); return key_ok(k) ? k : ""
}
# attempt(text, p): "max-ticks" (cap in ACAP), "shed", "hold", or "".
function attempt(s, p,   r, w) {
  ACAP = ""
  if (starts(s, "max-ticks: ")) {
    r = substr(s, 12); split(r, w, " ")
    if (w[1] ~ /^[0-9]+$/ && w[2] == "of" && w[3] ~ /^[0-9]+$/ && index(r, " running — " p " waits")) { ACAP = w[3]; return "max-ticks" }
    return ""
  }
  if (starts(s, "load-shed p90=") && index(s, " — no spawns this tick (reap ran)")) return "shed"
  if (starts(s, "spawn hold: the runner lane failed (")) return "hold"
  return ""
}
# cls(text, p): the class of one line of P, with the key in K; "stop" with
# the reason in STOP; "" for a line that is not a decision.
function cls(s, p,   r, k, i) {
  K = ""; STOP = ""
  if (starts(s, "spawned ")) { k = spawned_key(s); if (k == "") return ""; K = k; return "spawned" }
  if (starts(s, "skipping ")) {
    r = substr(s, 10); k = before(r, ": "); if (!key_ok(k)) return ""
    K = k; r = substr(r, length(k) + 3)
    if (starts(r, "waits for ") || starts(r, "After: ")) return "waits_for"
    if (starts(r, "HOLD (")) return "hold"
    if (starts(r, "spawn cap reached (")) return "spawn_cap"
    return "other"
  }
  if (starts(s, "SIBLING_SERIAL ")) { k = before(substr(s, 16), " waits for "); if (!key_ok(k)) return ""; K = k; return "waits_for" }
  if (starts(s, "SCHED_WAIT "))     { k = before(substr(s, 12), " reason=");    if (!key_ok(k)) return ""; K = k; return "waits_for" }
  if (starts(s, "env bundle FAILED for ")) { k = before(substr(s, 23), ":"); if (!key_ok(k)) return ""; K = k; return "env_bundle" }
  if (starts(s, "account ") && index(s, " ran out on ") && (i = index(s, " during "))) {
    k = before(substr(s, i + 8) " ", " "); if (!key_ok(k)) return ""; K = k; return "quota"
  }
  if (starts(s, "pool " p ": ")) { k = before(substr(s, length(p) + 8), " not queued :: "); if (!key_ok(k)) return ""; K = k; return "not_queued" }
  if (starts(s, "machine run FAILED for ")) { k = before(substr(s, 24) " ", " "); if (!key_ok(k)) return ""; K = k; return "other" }
  if (starts(s, "harness sync FAILED to ") && (i = index(s, " for "))) { k = before(substr(s, i + 5) " ", " "); if (!key_ok(k)) return ""; K = k; return "other" }
  if (starts(s, "tick budget of ") && index(s, "s spent for " p ": ")) { STOP = "budget"; return "stop" }
  if (starts(s, "tick stopped at a row boundary: it has run ")) { STOP = "age"; return "stop" }
  if (starts(s, "tick stopped at a row boundary: the deployed pool code changed")) { STOP = "code"; return "stop" }
  i = index(s, ": "); if (!i) return ""
  k = substr(s, 1, i - 1); r = substr(s, i + 2); if (!key_ok(k)) return ""
  if (starts(r, "the queue row refused this claim") || starts(r, "the project lease is lost") \
      || starts(r, "no App token for ") || starts(r, "token swap produced an empty bundle")) { K = k; return "other" }
  return ""
}
BEGIN { np = split(projects, PL, " "); for (i = 1; i <= np; i++) WANT[PL[i]] = 1; first = "" }
{
  # "<YYYY-MM-DD> <HH:MM:SS>Z [pool/<P>] <text>", the say() shape of bin/fly-pool.sh
  if ($1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || $2 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) next
  ts = $1 " " substr($2, 1, 8)
  if (first == "") first = ts
  if (!starts($3, "[pool/")) next
  p = substr($3, 7, length($3) - 7)
  if (!(p in WANT) || substr($3, length($3)) != "]") next
  text = substr($0, index($0, "] ") + 2)
  n = ++N[p]; T[p, n] = ts; X[p, n] = text
  if (starts(text, "pool " p ": queued=")) H[p, ++NH[p]] = n
  a = attempt(text, p)
  if (a != "") { AI[p] = n; AK[p] = a; AC[p] = ACAP }
  LQ[p] = ts
  if (ts >= c_hour) {
    if (starts(text, "env bundle FAILED for ")) EB[p]++
    if (a == "max-ticks") { MT[p]++; LMT[p] = ts }
  }
  if (substr(ts, 1, 10) == today && (k = spawned_key(text)) != "") { RC[p, k]++; RL[p, k] = ts; if (RC[p, k] == 2) RK[p, ++NRK[p]] = k }
  if (starts(text, "reaped ") && (i = index(text, " from "))) {
    k = substr(text, 8, i - 8)
    if (key_ok(k) && (j = index(text, ": "))) { split(substr(text, j + 2), RW, " "); RR[p, k] = key_ok(RW[1]) ? RW[1] : "" }
  }
}
END {
  since_day = today " 00:00:00"
  rsince = (first == "") ? "" : iso(first > since_day ? first : since_day)
  for (pi = 1; pi <= np; pi++) {
    p = PL[pi]
    tick = 0; reason = ""; since = ""; ndec = 0; endj = 0; hi = 0
    if (!have_log) reason = "no pool log"
    else if (!(p in NH)) reason = "no tick header in the last " tail_n " log lines"
    else {
      h = NH[p]; hi = H[p, h]
      ended = (LQ[p] < c_quiet || ((p in AI) && AI[p] > hi))
      for (j = hi + 1; !ended && j <= N[p]; j++) if (cls(X[p, j], p) == "stop") ended = 1
      pick = h
      if (!ended) { since = iso(T[p, hi]); pick = h - 1 }
      if (pick < 1) reason = "the only tick in the last " tail_n " log lines is still in progress"
      else {
        tick = 1
        from = H[p, pick]; to = (pick < h) ? H[p, pick + 1] - 1 : N[p]
        split("", POS); split("", DK); split("", DC); split("", XC)
        wstop = ""; endj = from; total = 0; spawned = 0
        for (j = from + 1; j <= to; j++) {
          c = cls(X[p, j], p)
          if (c == "") continue
          endj = j
          if (c == "stop") { if (wstop == "") wstop = STOP; continue }
          if (K in POS) {
            if (c == "spawned" && DC[POS[K]] != "spawned") { DC[POS[K]] = "spawned"; spawned++ }
          } else if (K in XC) {
            if (c == "spawned" && XC[K] != "spawned") { XC[K] = "spawned"; spawned++ }
          } else {
            total++; if (c == "spawned") spawned++
            if (ndec < max_dec) { ndec++; DK[ndec] = K; DC[ndec] = c; POS[K] = ndec } else XC[K] = c
          }
        }
        if (wstop == "") wstop = "done"
        # the header: pool P: queued=N running=N spawning=N cap=N|unlimited[ hotfix=N]
        split("", HF); nw = split(X[p, from], W, " ")
        for (w = 3; w <= nw; w++) if ((e = index(W[w], "="))) HF[substr(W[w], 1, e - 1)] = substr(W[w], e + 1)
        dec = ""
        for (j = 1; j <= ndec; j++) dec = dec (j > 1 ? "," : "") "[\"" DK[j] "\",\"" DC[j] "\"]"
      }
    }
    # stop and at: the newest attempt line when it is newer than the last tick
    # and the newest header, else the window stop.
    if ((p in AI) && AI[p] > endj && AI[p] > hi) {
      stop = q(AK[p]); at = q(iso(T[p, AI[p]])); scap = (AK[p] == "max-ticks") ? num(AC[p]) : "null"
      knob = (AK[p] == "max-ticks") ? q("POOL_TICK_MAX_PARALLEL") : "null"
    } else if (tick) {
      stop = q(wstop); at = q(iso(T[p, endj])); scap = "null"
      knob = (wstop == "budget") ? q("POOL_TICK_BUDGET_S") : (wstop == "age") ? q("POOL_TICK_MAX_AGE_S") : "null"
    } else { stop = "null"; at = "null"; scap = "null"; knob = "null" }
    if (tick) {
      # cap=unlimited is null; bin/fly-pool.sh writes hotfix= only when it is above 0.
      hdr = "\"queued\":" num(HF["queued"]) ",\"running\":" num(HF["running"]) ",\"spawning\":" num(HF["spawning"]) \
        ",\"cap\":" num(HF["cap"]) ",\"hotfix\":" (("hotfix" in HF) ? num(HF["hotfix"]) : 0)
      win = "\"started_at\":\"" iso(T[p, from]) "\",\"ended_at\":\"" iso(T[p, endj]) "\",\"complete\":" (wstop == "done" ? "true" : "false") \
        ",\"rows_decided\":" total ",\"rows_spawned\":" spawned ",\"window_stop\":\"" wstop "\""
      decs = "\"decisions\":[" dec "],\"decisions_truncated\":" (total > ndec ? "true" : "false")
      TICKS++; DECS += ndec
    } else {
      hdr = "\"queued\":null,\"running\":null,\"spawning\":null,\"cap\":null,\"hotfix\":null"
      win = "\"started_at\":null,\"ended_at\":null,\"complete\":null,\"rows_decided\":null,\"rows_spawned\":null,\"window_stop\":null"
      decs = "\"decisions\":null,\"decisions_truncated\":null"
    }
    resp = ""
    for (j = 1; j <= NRK[p]; j++) {
      k = RK[p, j]
      resp = resp (j > 1 ? "," : "") "{\"key\":\"" k "\",\"count\":" RC[p, k] ",\"last_result\":" q(RR[p, k]) ",\"last_at\":\"" iso(RL[p, k]) "\"}"
    }
    printf "{\"project\":\"%s\",\"tail_lines\":%d,\"tick\":%s,\"reason\":%s,%s,\"last_tick\":{\"at\":%s,%s,\"stop\":%s,\"cap\":%s,\"knob\":%s,\"in_progress_since\":%s,\"max_ticks_waits_1h\":%d,\"last_max_ticks_at\":%s},%s,\"env_bundle_failures_1h\":%d,\"respawns\":[%s],\"respawns_since\":%s}\n", \
      p, tail_n, tick ? "\"ok\"" : "null", q(reason), hdr, at, win, stop, scap, knob, q(since), MT[p] + 0, \
      (p in LMT) ? q(iso(LMT[p])) : "null", decs, EB[p] + 0, resp, q(rsince)
  }
  printf "%d %d\n", TICKS + 0, DECS + 0 > "/dev/stderr"
}'
}

W=$(mktemp -d "${TMPDIR:-/tmp}/pool-tick-summary.XXXXXX") || { log "mktemp failed; nothing read"; exit 0; }
trap 'rm -rf "$W"' EXIT
if [ "$HAVE_LOG" = 1 ]; then tail -n "$TAIL_N" "$POOL_LOG"; fi | summarize > "$W/rows.jsonl" 2> "$W/counts"
# Respawns: count desc then key, at most 50, the cap visible as respawns_truncated.
BODY=$(jq -sc '{rows: map(.respawns_truncated = ((.respawns | length) > 50)
                         | .respawns |= (sort_by(-.count, .key) | .[:50]))}' "$W/rows.jsonl" 2>/dev/null) \
  || { log "the summary rows did not parse as JSON; nothing posted"; exit 0; }
[ "$(jq '.rows | length' <<<"$BODY")" = "${#PROJECTS[@]}" ] || { log "the summary has $(jq '.rows | length' <<<"$BODY") rows for ${#PROJECTS[@]} projects; nothing posted"; exit 0; }
read -r TICKS DECS < "$W/counts"

# shellcheck source=/dev/null
[ -f "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
SUM="projects=${#PROJECTS[@]} ticks=${TICKS:-0} decisions=${DECS:-0}"
if ! declare -F _jobs_req >/dev/null 2>&1; then log "$SUM; no jobs client, nothing posted"; exit 0; fi
_jobs_req POST /api/pool/tick-summary "$BODY" >/dev/null 9>&-; PRC=$?
log "$SUM POST rc=$PRC http=${JOBS_HTTP:-none}"
exit 0
