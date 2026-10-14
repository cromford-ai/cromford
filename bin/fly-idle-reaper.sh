#!/bin/bash
# bin/fly-idle-reaper.sh — stop a Fly machine that has been idle too long, in
# any app of the org, every 5 minutes (BH-6061). Hub cron, `2-59/5 * * * *`.
#
# WHY. testhost-tick could not stop an idle test host for 13 days (a cron PATH
# bug), and nothing else would: fly-idle-check (BH-4020) only names idle
# machines once a day. On 2026-10-11 the org had 4 idle performance-16x test
# hosts, stopped by hand. Each lane that stops its own machines has its own way
# to fail quietly; this lane is the one pass over every app that does not
# depend on any of them.
#
# WHAT IT DOES. Lists every app the org token sees (`flyctl apps list`), then
# each app's machines. Each app gets an idle SIGNAL from the registry
# catalog/fly-idle-signals.json (an exact app name wins, then the longest
# prefix):
#   pool, builder  idle = now - newest of events[].timestamp and updated_at, and
#                  only when no witness holds the machine: a pool tracking file
#                  state/fly-pool/*/<mid>.json (pool), an active dispatcher
#                  record state/fly/<p>.json + <p>-active.json (builder), or a
#                  claimed jobs-queue row naming the machine (both);
#   testhost       `bin/testhost-tick.sh idle <mid>`, the same two witnesses the
#                  test host's own idle stop uses;
#   exempt         never stopped, listed (an app meant to stay up, with a reason).
# A `started` machine idle MORE than the settings row fly.idle_stop_after_s
# (default 900; a per-app row fly.idle_stop_after_s.<app> wins) is stopped with
# `flyctl machine stop`. At most fly.idle_max_stops_per_pass (10) per pass; the
# rest are reported `over`. Each stop that flyctl accepts (rc 0) writes a row to
# the jobs worker (POST /api/fly-idle/stops: app, machine, size, idle seconds,
# $/h saved). Every pass PUTs the started-machine snapshot to
# /api/fly-idle/machines, which Mission Control shows on /machines.
#
# FAILURE IS NEVER IDLE. A witness we cannot read (the queue, state/fly-pool,
# state/fly), a machine with no parseable timestamp, a testhost answer that is
# not a number: the machine is `unknown`, not stopped, and counted in
# state/fly-idle-reaper/fail/<app>__<mid>. At fly.idle_fail_alert_after (3)
# passes in a row, fly-idle-fail-<app> (warn). An app with no signal is never
# stopped; after fly.idle_nosignal_alert_s (3600) with a started machine,
# fly-idle-nosignal-<app> (warn). A settings row we cannot read, or a registry
# that does not validate, turns every stop off for the pass (nostop=1) and the
# pass still reports. No token: log `not configured`, one alert, rc 0. No
# flyctl, or the apps list fails: one alert, rc 1, no snapshot.
#
# WHAT IT NEVER DOES. It never destroys a machine or deletes an app; `machine
# stop` is its only write to Fly. It never resizes. The token (env FLY_API_TOKEN,
# the org token fly-idle-check reads) goes to flyctl as FLY_ACCESS_TOKEN, the
# same mechanism the pool uses, and never into a log, an alert or a row.
#
# One line per pass in logs/fly-idle-reaper.log:
#   pass apps=N read=R failed=F partial=0|1 started=S busy=B idle=I over=O
#   stopping=X stop_failed=Y unknown=U nosignal=Z exempt=E threshold=T(src) nostop=0|1
# `stopping` is a stop flyctl accepted, not a stop observed; the next pass sees
# the machine gone from `started`.
#
# Knob (catalog/lanes.d/fly-idle-reaper.json): FLY_IDLE_REAPER_NOW (epoch
# seconds; test seam). Off with flags/lane-off-fly-idle-reaper.
#
# Usage: bin/fly-idle-reaper.sh [--help]
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,57p' "$0"; exit 0 ;; esac
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165). Registry: catalog/lanes.d/fly-idle-reaper.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-idle-reaper
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-idle-reaper
# global.env is sourced HERE because cron does not; applied again below it so a
# settings row is not dropped by a knob the file also sets.
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-idle-reaper

# shellcheck source=bin/lib/fly-bin.sh
. "$(dirname "$0")/lib/fly-bin.sh" || exit 1
# shellcheck source=bin/lib/fly-cost-row.sh
. "$(dirname "$0")/lib/fly-cost-row.sh" 2>/dev/null || true
# shellcheck disable=SC1091
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$(dirname "$0")/jobs-client.sh" 2>/dev/null || true

LANE=fly-idle-reaper
# The box name the jobs client gives this box (state/box-name, else hostname).
BOX=$(hostname 2>/dev/null)
command -v _jobs_box_name >/dev/null 2>&1 && BOX=$(_jobs_box_name)
LOG="$H/logs/fly-idle-reaper.log"
SDIR="$H/state/fly-idle-reaper"
REG="$H/catalog/fly-idle-signals.json"
PRICES="$H/catalog/fly-prices.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" "$SDIR/fail" "$SDIR/nosignal" "$SDIR/outbox" "$SDIR/fired" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }
NOW="${FLY_IDLE_REAPER_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac

exec 9>"$H/locks/fly-idle-reaper.lock" || { say "cannot open locks/fly-idle-reaper.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }

# ── conditions: SEND FIRST, STAMP SECOND ─────────────────────────────────────
# state/fly-idle-reaper/fired/<id> says the condition was announced. A resolve
# is sent only for an announced one, so a healthy pass costs no alert call.
cond_fire() { # cond_fire <id> <text>
  [ -e "$SDIR/fired/$1" ] && return 0
  if "$H/bin/lane-alert.sh" --severity warn --id "$1" "$LANE" "$2" >/dev/null 2>&1; then
    : > "$SDIR/fired/$1" 2>/dev/null || say "alert $1 went out but fired/$1 was not stamped (--id dedup catches a repeat)"
  else
    say "alert $1 did not send — the next pass tries again"
  fi
}
cond_clear() { # cond_clear <id> <text>
  [ -e "$SDIR/fired/$1" ] || return 0
  if "$H/bin/lane-alert.sh" --resolve --id "$1" "$LANE" "$2" >/dev/null 2>&1; then
    rm -f "$SDIR/fired/$1"
  else
    say "resolve $1 did not send — the next pass tries again"
  fi
}
# count_up <file> -> prints the new count (a file holding one integer)
count_up() { local n; n=$(cat "$1" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac; n=$((n + 1)); echo "$n" > "$1" 2>/dev/null; echo "$n"; }

# The token, by NAME, trimmed but not squeezed: a Fly token is "FlyV1 fm2_..."
# with a space inside it (the reader bin/fly-idle-check.sh uses).
env_get() { # env_get <VAR_NAME> -> prints the value, or nothing
  local want="$1" f val
  case "$want" in *[!A-Z0-9_]*) return 1 ;; esac
  for f in "$HENV/global.env" "$HENV"/*.env; do
    [ -r "$f" ] || continue
    val=$(sed -n "s/^\(export \)\{0,1\}$want=//p" "$f" 2>/dev/null | head -1 \
      | tr -d "\"'" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 1
}
redact() { sed -E 's/FlyV1 [^ ]*/[redacted]/g; s/fm[0-9]_[A-Za-z0-9_-]*/[redacted]/g' | cut -c1-160; }

# ── 1. credentials and flyctl ────────────────────────────────────────────────
if ! TOK=$(env_get FLY_API_TOKEN); then
  say "not configured: FLY_API_TOKEN unset — nothing read, nothing stopped"
  cond_fire fly-idle-reaper-unconfigured "fly-idle-reaper is not configured: FLY_API_TOKEN is not set in the env files on $(hostname 2>/dev/null). No Fly machine is checked or stopped for idle until it is."
  exit 0
fi
if ! FLY=$(fly_bin); then
  say "flyctl not found (PATH, \$HOME/.fly/bin, /root/.fly/bin) — nothing read, nothing stopped"
  cond_fire fly-idle-reaper-unconfigured "fly-idle-reaper cannot run: flyctl not found (PATH, \$HOME/.fly/bin, /root/.fly/bin) on $(hostname 2>/dev/null). No Fly machine is checked or stopped for idle."
  exit 1
fi
cond_clear fly-idle-reaper-unconfigured "fly-idle-reaper has FLY_API_TOKEN and flyctl again."
ORG=$(env_get FLY_ORG) || ORG=""
fly() { FLY_ACCESS_TOKEN="$TOK" FLY_API_TOKEN="$TOK" timeout 60 "$FLY" "$@" </dev/null; }

# ── 2. settings, once per pass ───────────────────────────────────────────────
NOSTOP=0
# int_setting <var> <key> <fallback> — set <var> to the row's value (SRC=row) or
# the fallback when there is no row (SRC=fallback). rc 1 = unreadable or not an
# integer, and <var> is left alone: an answer we cannot trust is not a default.
SRC=""
int_setting() {
  local v rc
  v=$(setting_get "$2" 2>/dev/null); rc=$?
  case "$rc" in
    0) case "$v" in ''|*[!0-9]*) say "settings row $2='${v:0:16}' is not an integer"; return 1 ;; esac
       SRC=row ;;
    2) SRC=fallback; v="$3" ;;
    *) return 1 ;;
  esac
  printf -v "$1" '%s' "$v"
}
THRESH=900; TSRC=unreadable; NOSIG_S=3600; FAILN=3; MAXSTOPS=0
if int_setting THRESH fly.idle_stop_after_s 900; then TSRC="$SRC"; else NOSTOP=1; fi
int_setting NOSIG_S fly.idle_nosignal_alert_s 3600 || NOSTOP=1
int_setting FAILN fly.idle_fail_alert_after 3 || NOSTOP=1
int_setting MAXSTOPS fly.idle_max_stops_per_pass 10 || NOSTOP=1
[ "$FAILN" -ge 1 ] 2>/dev/null || FAILN=1
[ "$NOSTOP" = 1 ] && say "settings unreadable — no stops this pass"

# ── 3. the signal registry ───────────────────────────────────────────────────
REG_OK=1
if ! jq -e '
    (.apps | type == "object") and (.prefixes | type == "object")
    and ([.apps[], .prefixes[]] | all(
          (.source | IN("pool","builder","testhost","exempt"))
          and (if .source == "exempt" then ((.reason // "") | length > 0) else true end)))
  ' "$REG" >/dev/null 2>&1; then
  REG_OK=0; NOSTOP=1
  say "catalog/fly-idle-signals.json does not validate — no stops this pass"
  cond_fire fly-idle-reaper-registry "fly-idle-reaper: catalog/fly-idle-signals.json is missing or does not validate (apps/prefixes objects, source pool|builder|testhost|exempt, a reason on exempt). No machine is stopped until it does."
else
  cond_clear fly-idle-reaper-registry "catalog/fly-idle-signals.json validates again."
fi
signal_for() { # signal_for <app> -> pool|builder|testhost|exempt, or nothing
  [ "$REG_OK" = 1 ] || return 0
  jq -r --arg a "$1" '
    if .apps[$a] then .apps[$a].source
    else [.prefixes | to_entries[] | .key as $k | select($k != "" and ($a | startswith($k)))]
         | sort_by(.key | length) | last | .value.source // empty end' "$REG" 2>/dev/null
}

# ── 4. the outbox: rows from a pass whose POST failed ────────────────────────
post_row() { # post_row <outbox-file> -> rc 0 when the worker took it
  command -v _jobs_req >/dev/null 2>&1 || return 1
  JOBS_ALERT=0 _jobs_req POST /api/fly-idle/stops "$(cat "$1")" >/dev/null 2>&1
}
for f in "$SDIR"/outbox/*.json; do
  [ -f "$f" ] || continue
  if post_row "$f"; then rm -f "$f"; else say "outbox $(basename "$f") still not posted — kept"; fi
done

# ── 5. apps ──────────────────────────────────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fly-idle-reaper.XXXXXX") || { say "mktemp failed — skipped"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
APPS_OUT=$(fly apps list ${ORG:+--org "$ORG"} --json 2>"$WORK/apps.err"); arc=$?
if [ "$arc" != 0 ] || ! printf '%s' "$APPS_OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
  why=$( { cat "$WORK/apps.err"; printf '%s\n' "$APPS_OUT"; } | sed -n '/[^[:space:]]/{p;q;}' | redact)
  n=$(count_up "$SDIR/list-fail")
  say "apps list failed (rc $arc, $n in a row): ${why:-no output} — nothing read, nothing stopped, no snapshot"
  [ "$n" -ge "$FAILN" ] && cond_fire fly-idle-reaper-list "fly-idle-reaper could not list Fly apps on $n passes in a row: ${why:-no output}. No machine is checked or stopped for idle."
  exit 1
fi
rm -f "$SDIR/list-fail"
cond_clear fly-idle-reaper-list "fly-idle-reaper lists Fly apps again."
printf '%s' "$APPS_OUT" | jq -r '.[] | (.Name // .name // empty)' > "$WORK/apps.txt" 2>/dev/null

# ── 6. witnesses, read once ──────────────────────────────────────────────────
QOK=1; : > "$WORK/claimed.txt"
if command -v _jobs_req >/dev/null 2>&1 \
  && JOBS_ALERT=0 _jobs_req GET "/api/queue?status=claimed&limit=500" > "$WORK/q.json" 2>/dev/null \
  && jq -e '.queue | type == "array"' "$WORK/q.json" >/dev/null 2>&1 \
  && [ "$(jq '.queue | length' "$WORK/q.json")" -lt 500 ]; then
  jq -r '.queue[]?.machine // empty' "$WORK/q.json" > "$WORK/claimed.txt" 2>/dev/null
  rm -f "$SDIR/queue-fail"
  cond_clear fly-idle-reaper-queue "fly-idle-reaper reads the claimed jobs queue again."
else
  # Truncated (500 rows) counts as unread: a claim past the page is a claim we
  # did not see.
  QOK=0
  n=$(count_up "$SDIR/queue-fail")
  say "claimed queue unreadable ($n in a row) — pool and builder machines are unknown this pass"
  [ "$n" -ge "$FAILN" ] && cond_fire fly-idle-reaper-queue "fly-idle-reaper could not read the claimed jobs queue on $n passes in a row. Pool and builder machines are not stopped while it cannot."
fi
# A read only: the pool dir tells whether a pool machine holds a build here.
_pool_dir_ok() { [ -d "$H/state/fly-pool" ]; }
POOLOK=1; _pool_dir_ok || POOLOK=0
DISPOK=1; [ -d "$H/state/fly" ] || DISPOK=0
: > "$WORK/disp.txt"
for f in "$H"/state/fly/*.json; do
  [ -f "$f" ] || continue
  case "$f" in *-active.json) continue ;; esac
  [ -e "${f%.json}-active.json" ] || continue
  jq -r '.machine_id // empty' "$f" >> "$WORK/disp.txt" 2>/dev/null
done
held_pool() { local f; for f in "$H"/state/fly-pool/*/"$1".json; do [ -e "$f" ] && return 0; done; grep -qxF -- "$1" "$WORK/claimed.txt"; }
held_builder() { grep -qxF -- "$1" "$WORK/disp.txt" || grep -qxF -- "$1" "$WORK/claimed.txt"; }

# ── 7-8. per app, per started machine ────────────────────────────────────────
APPS=0; READ=0; FAILED=0
STARTED=0; BUSY=0; IDLE=0; OVER=0; STOPPING=0; STOPFAIL=0; UNKNOWN=0; NOSIG=0; EXEMPT=0
STOPS=0
: > "$WORK/rows.jsonl"; : > "$WORK/seen.txt"; : > "$WORK/apps-read.txt"; : > "$WORK/apps-started.txt"; : > "$WORK/failing.txt"

# fail_note <app> <mid> <why> — one more failed read or stop for this machine
fail_note() {
  local n; n=$(count_up "$SDIR/fail/$1__$2")
  UNKNOWN_WHY="$3"
  say "$1/$2: $3 (fail $n in a row)"
}

while IFS= read -r app; do
  [ -n "$app" ] || continue
  APPS=$((APPS + 1))
  case "$app" in *[!a-z0-9-]*|-*) FAILED=$((FAILED + 1)); say "app name '${app:0:40}' is not [a-z0-9-] — not read"; continue ;; esac
  if ! fly machine list -a "$app" --json > "$WORK/m.json" 2>"$WORK/m.err" \
     || ! jq -e 'type == "array"' "$WORK/m.json" >/dev/null 2>&1; then
    FAILED=$((FAILED + 1))
    say "$app: machine list failed: $(sed -n '/[^[:space:]]/{p;q;}' "$WORK/m.err" | redact) — no stop in this app"
    continue
  fi
  READ=$((READ + 1)); echo "$app" >> "$WORK/apps-read.txt"
  sig=$(signal_for "$app")
  athresh="$THRESH"; anostop="$NOSTOP"
  key="fly.idle_stop_after_s.$app"
  if [ "${#key}" -gt 64 ]; then
    [ -n "$sig" ] && say "$app: $key is over 64 characters — not read, the default threshold applies"
  elif [ -n "$sig" ] && [ "$sig" != exempt ] && int_setting athresh "$key" "$THRESH"; then
    :
  elif [ -n "$sig" ] && [ "$sig" != exempt ]; then
    anostop=1; say "$app: $key unreadable — no stops in this app this pass"
  fi
  # id<TAB>kind<TAB>cpus<TAB>mem<TAB>newest-epoch|-  for every STARTED machine
  jq -r '.[] | select(.state == "started")
    | ((.config.guest // .guest) // {}) as $g
    | ([(.events[]?.timestamp | numbers | if . > 100000000000 then . / 1000 else . end | floor),
        (try (.updated_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch empty)] | max) as $ts
    | [(.id // ""), ($g.cpu_kind // ""), ($g.cpus // "" | tostring), ($g.memory_mb // "" | tostring),
       (if $ts == null then "-" else ($ts | tostring) end)] | @tsv' "$WORK/m.json" > "$WORK/started.tsv" 2>/dev/null
  while IFS=$'\t' read -r mid kind cpus mem ts; do
    [ -n "$mid" ] || continue
    STARTED=$((STARTED + 1)); echo "$app" >> "$WORK/apps-started.txt"
    echo "$app __$mid" >> "$WORK/seen.txt"
    size=""; case "$kind" in performance) size="performance-${cpus}x" ;; shared) size="shared-cpu-${cpus}x" ;; esac
    usdh=""
    command -v fly_price_per_s >/dev/null 2>&1 && usdh=$(fly_price_per_s "$PRICES" "$kind" "$cpus" "$mem" 2>/dev/null | awk '{printf "%.6f", $1 * 3600}')
    state=""; idle=""; UNKNOWN_WHY=""
    case "$mid" in *[!0-9a-f]*|'') state=unknown; fail_note "$app" "$mid" "machine id is not hex — not stoppable" ;; esac
    if [ -n "$state" ]; then :
    # A registry that does not validate is not "no signal": the registry alert
    # already says so, and a nosignal streak per app would page once per app.
    elif [ "$REG_OK" = 0 ]; then state=unknown
    elif [ -z "$sig" ]; then state=nosignal
    elif [ "$sig" = exempt ]; then state=exempt
    elif [ "$sig" = testhost ]; then
      idle=$(TESTHOST_APP="$app" timeout 120 "$H/bin/testhost-tick.sh" idle "$mid" 2>/dev/null </dev/null); trc=$?
      if [ "$trc" != 0 ] || [[ ! "$idle" =~ ^[0-9]+$ ]]; then
        state=unknown; idle=""; fail_note "$app" "$mid" "testhost-tick.sh idle answered rc $trc '${idle:0:20}'"
      elif [ "$idle" = 0 ]; then state=busy
      fi
    else # pool, builder
      if [ "$QOK" = 0 ] || { [ "$sig" = pool ] && [ "$POOLOK" = 0 ]; } || { [ "$sig" = builder ] && [ "$DISPOK" = 0 ]; }; then
        state=unknown; fail_note "$app" "$mid" "a $sig witness is unreadable (queue=$QOK pool=$POOLOK dispatch=$DISPOK)"
      elif { [ "$sig" = pool ] && held_pool "$mid"; } || { [ "$sig" = builder ] && held_builder "$mid"; }; then
        state=busy; idle=0
      elif [ "$ts" = - ] || [[ ! "$ts" =~ ^[0-9]+$ ]]; then
        state=unknown; fail_note "$app" "$mid" "no parseable timestamp in events or updated_at"
      else
        idle=$((NOW - ts)); [ "$idle" -lt 0 ] && idle=0
      fi
    fi
    if [ -z "$state" ]; then
      if [ "$idle" -le "$athresh" ]; then state=idle
      elif [ "$anostop" = 1 ] || [ "$STOPS" -ge "$MAXSTOPS" ]; then state=over
      else
        STOPS=$((STOPS + 1))
        if out=$(fly machine stop "$mid" -a "$app" 2>&1); then
          state=stopping; STOPPING=$((STOPPING + 1))
          sid="$mid-$NOW"
          jq -nc --arg sid "$sid" --arg app "$app" --arg mid "$mid" --arg size "$size" --arg src "$sig" \
            --argjson idle "$idle" --argjson th "$athresh" --arg usd "$usdh" --arg box "$BOX" \
            --arg at "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" '
            {rows: [{stop_id: $sid, app: $app, machine_id: $mid, size: (if $size == "" then null else $size end),
                     source: $src, idle_s: $idle, threshold_s: $th,
                     usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end),
                     status: "requested", box: (if $box == "" then null else $box end), stopped_at: $at}]}' \
            > "$SDIR/outbox/$sid.json"
          say "$app/$mid: stopped after ${idle}s idle (limit ${athresh}s, ${size:-size unknown}, \$${usdh:-?}/h)"
          if post_row "$SDIR/outbox/$sid.json"; then rm -f "$SDIR/outbox/$sid.json"
          else say "$app/$mid: the stop row did not post — kept in outbox/$sid.json for the next pass"; fi
        else
          state=over; STOPFAIL=$((STOPFAIL + 1))
          fail_note "$app" "$mid" "flyctl machine stop failed: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}' | redact)"
        fi
      fi
    fi
    case "$state" in
      busy) BUSY=$((BUSY + 1)) ;; idle) IDLE=$((IDLE + 1)) ;; over) OVER=$((OVER + 1)) ;;
      unknown) UNKNOWN=$((UNKNOWN + 1)) ;; nosignal) NOSIG=$((NOSIG + 1)) ;; exempt) EXEMPT=$((EXEMPT + 1)) ;;
    esac
    # A known answer (and a stop flyctl took) ends this machine's fail streak.
    if [ -n "$UNKNOWN_WHY" ]; then echo "$app" >> "$WORK/failing.txt"; else rm -f "$SDIR/fail/${app}__$mid"; fi
    # The worker takes hex machine ids only; one bad row would refuse the whole
    # snapshot. The machine is still counted unknown and logged above.
    case "$mid" in *[!0-9a-f]*) continue ;; esac
    th_json="$athresh"; case "$state" in nosignal|exempt) th_json=null ;; esac
    jq -nc --arg app "$app" --arg mid "$mid" --arg size "$size" --arg src "${sig:-none}" --arg idle "$idle" \
      --arg st "$state" --argjson th "$th_json" --arg usd "$usdh" '
      {app: $app, machine_id: $mid, size: (if $size == "" then null else $size end), source: $src,
       idle_s: (if $idle == "" then null else ($idle | tonumber) end), idle_state: $st, threshold_s: $th,
       usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end)}' >> "$WORK/rows.jsonl"
  done < "$WORK/started.tsv"
done < "$WORK/apps.txt"

# ── 9. streaks ───────────────────────────────────────────────────────────────
# fail/<app>__<mid>: a machine of an app READ this pass that is no longer
# started is gone from the streak. An app whose list failed keeps its files.
for f in "$SDIR"/fail/*__*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); app="${b%%__*}"; mid="${b#*__}"
  grep -qxF -- "$app __$mid" "$WORK/seen.txt" && continue
  if grep -qxF -- "$app" "$WORK/apps-read.txt" || ! grep -qxF -- "$app" "$WORK/apps.txt"; then rm -f "$f"; fi
done
for app in $(sort -u "$WORK/apps.txt"); do
  case "$app" in *[!a-z0-9-]*|-*) continue ;; esac
  grep -qxF -- "$app" "$WORK/apps-read.txt" || continue
  worst=0
  for f in "$SDIR"/fail/"$app"__*; do
    [ -f "$f" ] || continue
    n=$(cat "$f" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt "$worst" ] && worst="$n"
  done
  if [ "$worst" -ge "$FAILN" ]; then
    cond_fire "fly-idle-fail-$app" "fly-idle-reaper could not read the idle signal of a started machine in $app (or could not stop it) on $worst passes in a row. It is not stopped while that holds. See logs/fly-idle-reaper.log."
  elif [ "$worst" = 0 ]; then
    cond_clear "fly-idle-fail-$app" "fly-idle-reaper reads every started machine in $app again."
  fi
done
# nosignal/<app>: first-seen epoch of a started machine in an app with no signal.
# Untouched while the registry does not validate (every app would look unsignalled).
[ "$REG_OK" = 1 ] && for app in $(sort -u "$WORK/apps-started.txt"); do
  [ -z "$(signal_for "$app")" ] || continue
  f="$SDIR/nosignal/$app"
  [ -f "$f" ] || echo "$NOW" > "$f"
  first=$(cat "$f" 2>/dev/null); case "$first" in ''|*[!0-9]*) first="$NOW"; echo "$NOW" > "$f" ;; esac
  if [ $((NOW - first)) -ge "$NOSIG_S" ]; then
    cond_fire "fly-idle-nosignal-$app" "Fly app $app has had a started machine for $(( (NOW - first) / 60 ))m and has no idle signal in catalog/fly-idle-signals.json, so fly-idle-reaper never stops it. Register its source there (pool, builder, testhost, or exempt with a reason)."
  fi
done
[ "$REG_OK" = 1 ] && for f in "$SDIR"/nosignal/*; do
  [ -f "$f" ] || continue
  app=$(basename "$f")
  if grep -qxF -- "$app" "$WORK/apps-started.txt" && [ -z "$(signal_for "$app")" ]; then continue; fi
  # An app whose list failed this pass is not evidence its machine stopped.
  grep -qxF -- "$app" "$WORK/apps.txt" && ! grep -qxF -- "$app" "$WORK/apps-read.txt" && continue
  cond_clear "fly-idle-nosignal-$app" "Fly app $app has no started machine without an idle signal any more."
  [ -e "$SDIR/fired/fly-idle-nosignal-$app" ] || rm -f "$f"
done
# A fail condition for an app that left the org.
for f in "$SDIR"/fired/fly-idle-fail-*; do
  [ -f "$f" ] || continue
  app="${f##*/fly-idle-fail-}"
  grep -qxF -- "$app" "$WORK/apps.txt" || cond_clear "fly-idle-fail-$app" "Fly app $app is gone from the org."
done

# ── 10. the snapshot ─────────────────────────────────────────────────────────
PARTIAL=0; [ "$FAILED" -gt 0 ] && PARTIAL=1
NROWS=$(wc -l < "$WORK/rows.jsonl")
if [ "$NROWS" -gt 500 ]; then
  say "snapshot has $NROWS rows; the worker takes 500 — the rest are not shown"
  PARTIAL=1
fi
if command -v _jobs_req >/dev/null 2>&1; then
  body=$(head -n 500 "$WORK/rows.jsonl" | jq -sc --arg at "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson total "$APPS" --argjson failed "$FAILED" --arg box "$BOX" \
    '{pass_at: $at, apps_total: $total, apps_failed: $failed, box: $box, rows: .}')
  JOBS_ALERT=0 _jobs_req PUT /api/fly-idle/machines "$body" >/dev/null 2>&1 \
    || say "snapshot PUT failed — Mission Control shows the last one until the next pass"
else
  say "no jobs client — snapshot not sent"
fi

# ── 11. one line ─────────────────────────────────────────────────────────────
say "pass apps=$APPS read=$READ failed=$FAILED partial=$PARTIAL started=$STARTED busy=$BUSY idle=$IDLE over=$OVER stopping=$STOPPING stop_failed=$STOPFAIL unknown=$UNKNOWN nosignal=$NOSIG exempt=$EXEMPT threshold=$THRESH($TSRC) nostop=$NOSTOP"
exit 0
