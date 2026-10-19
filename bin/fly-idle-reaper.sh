#!/bin/bash
# bin/fly-idle-reaper.sh — stop a Fly machine that has been idle too long, in
# any app of the org, every 5 minutes (BH-6061), and destroy a machine that has
# been stopped for a week (BH-6877). Hub cron, `2-59/5 * * * *`.
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
# prefix; no match is `metrics`):
#   pool, builder  idle = now - the newer of the last work time and the newest
#                  `start`/`launch` event (no such event: the oldest listed
#                  event). Other events (update, exec) are not work. The last
#                  work time is the pass that last saw a witness hold the
#                  machine (state/fly-idle-reaper/work/<app>__<mid>): a pool
#                  tracking file state/fly-pool/*/<mid>.json (pool), an active
#                  dispatcher record state/fly/<p>.json + <p>-active.json
#                  (builder), or a claimed jobs-queue row naming the machine;
#   lane-run       GET /api/lane-fleet/machines, read once: busy or in_flight
#                  is busy, else idle = its idle_s (now - the newer of the last
#                  claim activity and started_at). Fly events are not used. The
#                  lane_fleet.warm_floor (1; above 100 is 1) machines with
#                  the lowest idle (busy first) are kept as `floor`. An
#                  unreadable or `incomplete` answer, an unreadable warm_floor
#                  row, or a machine with no lane_machines row is `unknown`;
#   testhost       `bin/testhost-tick.sh idle <mid>`, the same two witnesses the
#                  test host's own idle stop uses;
#   metrics        Fly's Prometheus API (bin/lib/fly-metrics.sh), read once per
#                  pass over fly.idle_stop_after_s: busy CPU % under
#                  fly.metrics_idle_cpu_pct (2) and net bytes/s under
#                  fly.metrics_idle_net_bps (2048) is quiet, and idle = now -
#                  the newer of the last work time and the newest start event.
#                  With no org slug (FLY_ORG or the apps list) it is `nosignal`;
#   exempt         never stopped, listed (an app meant to stay up, with a reason).
# A `started` machine idle MORE than the settings row fly.idle_stop_after_s
# (default 900; a per-app row fly.idle_stop_after_s.<app> wins) is stopped with
# `flyctl machine stop`. A pool, builder or lane-run machine is first PROBED:
# `flyctl machine exec <mid> 'ps -eo pcpu=,args='`, read against
# catalog/fly-work-procs.json. A work process, or an unlisted process at
# fly.probe_busy_cpu_pct (5) CPU or more, is busy: no stop, last work = now. At
# most fly.idle_max_stops_per_pass (10) probes and 10 stops per pass; the rest
# are reported `over`. Each stop that flyctl accepts (rc 0) writes a row to
# the jobs worker (POST /api/fly-idle/stops: app, machine, size, idle seconds,
# $/h saved). Every pass PUTs the started-machine snapshot, with the last work
# time, to /api/fly-idle/machines, which Mission Control shows on /machines.
#
# DESTROY. A machine of a pool, builder or lane-run app in state `stopped` for
# MORE than fly.destroy_after_stopped_s (604800; under 86400 is refused) is
# destroyed with `flyctl machine destroy` (no --force). Stopped since = the
# newest stop/exit event, else updated_at; unparseable is never destroyed. A
# machine with a mounted volume, or one whose id is the machine_id of a
# state/fly/<p>.json record, is never destroyed: that is a project's persistent
# builder (bin/fly-provision.sh), only an operator creates it, and
# bin/fly-dispatch.sh starts that id and nothing else. A state/fly record we
# cannot read is no destroy that pass. At most fly.destroy_max_per_pass (10);
# fly.destroy_enabled=0 turns it off. Each rc-0 destroy writes a row
# (POST /api/fly-idle/destroys) with the size's compute $/h (what a restart
# costs, not a saving).
#
# BOOT WITHOUT A CLAIM. A started lane-run machine whose lane row is still
# `starting` (no claim since its start) for more than fly.no_claim_alert_s (600)
# raises fly-no-claim-<first 12 hex of its image digest> (warn), one per
# digest; it clears when no machine of that digest is in that state. Alert only.
#
# FAILURE IS NEVER IDLE. A witness we cannot read (the queue, state/fly-pool,
# state/fly, the lane-fleet route, the metrics query), a machine with no
# parseable timestamp, a testhost answer that is not a number, a probe that
# fails: the machine is `unknown`, not stopped, and counted in
# state/fly-idle-reaper/fail/<app>__<mid>. At fly.idle_fail_alert_after (3)
# passes in a row, fly-idle-fail-<app> (warn). An app with no signal is never
# stopped; after fly.idle_nosignal_alert_s (3600) with a started machine,
# fly-idle-nosignal-<app> (warn). A settings row we cannot read, or a registry
# that does not validate, turns every stop and destroy off for the pass
# (nostop=1) and the pass still reports. A procs catalog that does not validate
# turns probe-based stops off (fly-idle-reaper-procs). No token: log `not
# configured`, one alert, rc 0. No flyctl, or the apps list fails: one alert,
# rc 1, no snapshot.
#
# WHAT IT NEVER DOES. It never deletes an app and never resizes. It never
# destroys a started machine, nor one of an exempt, testhost or metrics app.
# Its writes to Fly are `machine stop` and `machine destroy`; `machine exec` runs
# ps only. The token (env FLY_API_TOKEN, the org token fly-idle-check reads)
# goes to flyctl as FLY_ACCESS_TOKEN, the same mechanism the pool uses, and to
# curl in a header file, never into a log, an alert or a row.
#
# One line per pass in logs/fly-idle-reaper.log:
#   pass apps=N read=R failed=F partial=0|1 started=S busy=B idle=I over=O
#   stopping=X stop_failed=Y unknown=U nosignal=Z exempt=E threshold=T(src) nostop=0|1
#   probed=P probe_busy=Q destroying=D destroy_failed=G noclaim=C metrics=M floor=K
# `floor` counts lane-run machines kept for lane_fleet.warm_floor (BH-6714;
# their snapshot rows say exempt).
# `stopping` and `destroying` are calls flyctl accepted, not results observed.
#
# ACT. `bin/fly-idle-reaper.sh act probe|stop|destroy|keep <app> <mid> [reason]`
# is one action on one machine, for Quartermaster (prompts/staff/
# quartermaster-soul.md) or an operator: the same flyctl calls, rows and log
# lines as a pass, under the same lock (waits up to 60 s). `probe` prints
# busy|idle|unknown. `stop` stops a started machine (row source `act`, idle_s =
# seconds since its newest start event); it refuses when the settings are
# unreadable, refuses (one log line and one alert) for an app with no registry
# entry, and for a pool, builder, lane-run or metrics machine it probes first
# and refuses unless the probe answers idle (and, for lane-run, unless the lane
# record says not busy and not in flight). `destroy` obeys the pass's destroy
# rule. `keep <reason>` writes one log line and no row. Never for an exempt or
# testhost app. A stop or destroy sends one beat (kind fly_idle_action) with
# the $/h. rc 0 done, rc 1 refused or flyctl failed, rc 2 usage.
#
# Knob (catalog/lanes.d/fly-idle-reaper.json): FLY_IDLE_REAPER_NOW (epoch
# seconds; test seam). Off with flags/lane-off-fly-idle-reaper.
#
# Usage: bin/fly-idle-reaper.sh [--help] | act probe|stop|destroy|keep <app> <mid> [reason]
set -uo pipefail
MODE=pass; ACT=""; ACT_APP=""; ACT_MID=""; ACT_WHY=""
case "${1:-}" in
  -h|--help) sed -n '2,117p' "$0"; exit 0 ;;
  act)
    MODE=act; ACT="${2:-}"; ACT_APP="${3:-}"; ACT_MID="${4:-}"; ACT_WHY="${5:-}"
    case "$ACT" in probe|stop|destroy|keep) ;; *) echo "usage: $0 act probe|stop|destroy|keep <app> <mid> [reason]" >&2; exit 2 ;; esac
    [[ "$ACT_APP" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { echo "act: app '${ACT_APP:0:40}' is not [a-z0-9-]" >&2; exit 2; }
    [[ "$ACT_MID" =~ ^[0-9a-f]{6,32}$ ]] || { echo "act: machine id '${ACT_MID:0:40}' is not hex" >&2; exit 2; }
    [ "$ACT" = keep ] && [ -z "$ACT_WHY" ] && { echo "act keep needs a reason" >&2; exit 2; } ;;
esac
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165). Registry: catalog/lanes.d/fly-idle-reaper.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# An act is one command a caller waits on: a paused lane refuses it (rc 1)
# rather than answering 0 with nothing done.
if [ "$MODE" = act ]; then
  if command -v lane_paused >/dev/null 2>&1 && lane_paused fly-idle-reaper; then echo "act: the fly-idle-reaper lane is paused" >&2; exit 1; fi
else
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-idle-reaper
fi
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
# shellcheck source=bin/lib/fly-metrics.sh
. "$(dirname "$0")/lib/fly-metrics.sh" 2>/dev/null || true
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
PROCS="$H/catalog/fly-work-procs.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" "$SDIR/fail" "$SDIR/nosignal" "$SDIR/outbox" "$SDIR/outbox-destroy" "$SDIR/fired" "$SDIR/work" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }
NOW="${FLY_IDLE_REAPER_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac

exec 9>"$H/locks/fly-idle-reaper.lock" || { say "cannot open locks/fly-idle-reaper.lock — skipped"; [ "$MODE" = act ] && exit 1; exit 0; }
if [ "$MODE" = act ]; then
  flock -w 60 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && { echo "act: a reaper pass held the lock for 60 s" >&2; exit 1; }; }
else
  flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }
fi

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
PROBE_CPU=5; M_CPU=2; M_NET=2048; FLOOR=1; NOCLAIM_S=600
int_setting PROBE_CPU fly.probe_busy_cpu_pct 5 || NOSTOP=1
int_setting M_CPU fly.metrics_idle_cpu_pct 2 || NOSTOP=1
int_setting M_NET fly.metrics_idle_net_bps 2048 || NOSTOP=1
# An unreadable alert age is no alert decision this pass, never a default.
int_setting NOCLAIM_S fly.no_claim_alert_s 600 || NOCLAIM_S=""
[ "$FAILN" -ge 1 ] 2>/dev/null || FAILN=1
[ "$NOSTOP" = 1 ] && say "settings unreadable — no stops this pass"
NODESTROY=0; DESTROY_AFTER=604800; DESTROY_MAX=10; DESTROY_ON=1
int_setting DESTROY_AFTER fly.destroy_after_stopped_s 604800 || NODESTROY=1
int_setting DESTROY_MAX fly.destroy_max_per_pass 10 || NODESTROY=1
int_setting DESTROY_ON fly.destroy_enabled 1 || NODESTROY=1
# A destroy cannot be undone: a window under a day is refused, not clamped.
if [ "$NODESTROY" = 0 ] && [ "$DESTROY_AFTER" -lt 86400 ]; then
  NODESTROY=1; say "fly.destroy_after_stopped_s=$DESTROY_AFTER is under 86400 — no destroys this pass"
fi
[ "$DESTROY_ON" = 1 ] || NODESTROY=1
[ "$NOSTOP" = 1 ] && NODESTROY=1

# ── 3. the signal registry ───────────────────────────────────────────────────
REG_OK=1
if ! jq -e '
    (.apps | type == "object") and (.prefixes | type == "object")
    and ([.apps[], .prefixes[]] | all(
          (.source | IN("pool","builder","lane-run","testhost","metrics","exempt"))
          and (if .source == "exempt" then ((.reason // "") | length > 0) else true end)))
  ' "$REG" >/dev/null 2>&1; then
  REG_OK=0; NOSTOP=1
  say "catalog/fly-idle-signals.json does not validate — no stops this pass"
  cond_fire fly-idle-reaper-registry "fly-idle-reaper: catalog/fly-idle-signals.json is missing or does not validate (apps/prefixes objects, source pool|builder|lane-run|testhost|metrics|exempt, a reason on exempt). No machine is stopped until it does."
else
  cond_clear fly-idle-reaper-registry "catalog/fly-idle-signals.json validates again."
fi
signal_for() { # signal_for <app> -> a registry source; `metrics` when no entry matches
  [ "$REG_OK" = 1 ] || return 0
  jq -r --arg a "$1" '
    if .apps[$a] then .apps[$a].source
    else [.prefixes | to_entries[] | .key as $k | select($k != "" and ($a | startswith($k)))]
         | sort_by(.key | length) | last | .value.source // "metrics" end' "$REG" 2>/dev/null
}
# has_entry <app>: rc 0 when the registry names the app (an exact key or a
# prefix). signal_for answers `metrics` for an app with no entry; `act stop`
# needs to know the difference.
has_entry() {
  [ "$REG_OK" = 1 ] || return 1
  jq -e --arg a "$1" '.apps[$a] != null
    or ([.prefixes | keys[] as $k | select($k != "" and ($a | startswith($k)))] | length > 0)' "$REG" >/dev/null 2>&1
}
# The probe's process lists. A file that does not validate is no probe, so no
# probe-based stop: those machines are reported `over`.
PROCS_OK=1
if ! jq -e '(.work | type == "array") and (.idle | type == "array")
    and ([.work[], .idle[]] | all(type == "string" and length > 0))' "$PROCS" >/dev/null 2>&1; then
  PROCS_OK=0
  say "catalog/fly-work-procs.json does not validate — no probe, no probe-based stop this pass"
  cond_fire fly-idle-reaper-procs "fly-idle-reaper: catalog/fly-work-procs.json is missing or does not validate (work and idle arrays of non-empty strings). No pool, builder or lane-run machine is stopped until it does."
else
  cond_clear fly-idle-reaper-procs "catalog/fly-work-procs.json validates again."
fi

# ── 4. the outbox: rows from a pass whose POST failed ────────────────────────
post_row() { # post_row <outbox-file> [route] -> rc 0 when the worker took it
  command -v _jobs_req >/dev/null 2>&1 || return 1
  JOBS_ALERT=0 _jobs_req POST "${2:-/api/fly-idle/stops}" "$(cat "$1")" >/dev/null 2>&1
}
for f in "$SDIR"/outbox/*.json; do
  [ -f "$f" ] || continue
  if post_row "$f"; then rm -f "$f"; else say "outbox $(basename "$f") still not posted — kept"; fi
done
for f in "$SDIR"/outbox-destroy/*.json; do
  [ -f "$f" ] || continue
  if post_row "$f" /api/fly-idle/destroys; then rm -f "$f"; else say "outbox-destroy $(basename "$f") still not posted — kept"; fi
done
ISO_NOW=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)

# ── 4b. helpers shared by a pass and an act ──────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fly-idle-reaper.XXXXXX") || { say "mktemp failed — skipped"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
jq -r '.work[]?' "$PROCS" > "$WORK/procs-work.txt" 2>/dev/null
jq -r '.idle[]?' "$PROCS" > "$WORK/procs-idle.txt" 2>/dev/null
# size_usd <kind> <cpus> <mem> -> SIZE, USDH (empty when not known)
size_usd() {
  SIZE=""; USDH=""
  case "$1" in performance) SIZE="performance-${2}x" ;; shared) SIZE="shared-cpu-${2}x" ;; esac
  command -v fly_price_per_s >/dev/null 2>&1 && USDH=$(fly_price_per_s "$PRICES" "$1" "$2" "$3" 2>/dev/null | awk '{printf "%.6f", $1 * 3600}')
}
# Machine rows from a `machine list --json` file, one TSV line each:
#   started: id kind cpus mem start-epoch|- image|-
#   stopped: id kind cpus mem stopped-since-epoch|- mounts (count)
# start = the newest start/launch event, else the oldest listed event (the
# start is older than every event listed, so idle is never over-counted).
machines_tsv() { # machines_tsv <m.json> started|stopped
  jq -r --arg want "$2" '.[] | select(.state == $want)
    | ((.config.guest // .guest) // {}) as $g
    | [.events[]? | {t: (.type // ""), ts: (.timestamp | numbers | if . > 100000000000 then . / 1000 else . end | floor)}] as $ev
    | (if $want == "started" then
         (([$ev[] | select(.t == "start" or .t == "launch") | .ts] | max) // ([$ev[].ts] | min))
       else
         (([$ev[] | select(.t == "stop" or .t == "exit") | .ts] | max)
          // (try (.updated_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null))
       end) as $ts
    | [(.id // ""), ($g.cpu_kind // ""), ($g.cpus // "" | tostring), ($g.memory_mb // "" | tostring),
       (if $ts == null then "-" else ($ts | tostring) end)]
      + (if $want == "started" then [((.image_ref.digest // .config.image // "-") | tostring)]
         else [((.config.mounts // []) | length | tostring)] end)
    | @tsv' "$1" 2>/dev/null
}
stamp_work() { echo "$NOW" > "$SDIR/work/$1__$2" 2>/dev/null; }
work_at() { # work_at <app> <mid> -> the last work epoch, or nothing
  local v; v=$(cat "$SDIR/work/$1__$2" 2>/dev/null); case "$v" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$v"
}
# probe <app> <mid> -> PROBE_STATE busy|idle|unknown, PROBE_WHY
probe() {
  local out rc
  PROBE_STATE=unknown; PROBE_WHY=""
  out=$(FLY_ACCESS_TOKEN="$TOK" FLY_API_TOKEN="$TOK" timeout 30 "$FLY" machine exec "$2" 'ps -eo pcpu=,args=' -a "$1" \
    2>"$WORK/exec.err" </dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    PROBE_WHY="machine exec answered rc $rc: $(sed -n '/[^[:space:]]/{p;q;}' "$WORK/exec.err" | redact)"; return 0
  fi
  # A work match, or an unlisted process at the CPU line, is busy (and busy
  # wins). A line that is not "<pcpu> <args>", or no line, is unknown.
  out=$(printf '%s\n' "$out" | awk -v cpu="$PROBE_CPU" -v wf="$WORK/procs-work.txt" -v idf="$WORK/procs-idle.txt" '
    BEGIN { while ((getline l < wf) > 0) if (l != "") W[++nw] = l
            while ((getline l < idf) > 0) if (l != "") I[++ni] = l }
    /^[[:space:]]*$/ { next }
    { line = $0; sub(/^[[:space:]]+/, "", line); p = index(line, " ")
      if (p == 0) { bad = 1; next }
      c = substr(line, 1, p - 1); a = substr(line, p + 1); sub(/^[[:space:]]+/, "", a)
      if (c !~ /^[0-9]+(\.[0-9]+)?$/) { bad = 1; next }
      n++
      for (i = 1; i <= nw; i++) if (index(a, W[i])) { busy = 1; if (why == "") why = a; next }
      for (i = 1; i <= ni; i++) if (index(a, I[i])) next
      if (c + 0 >= cpu + 0) { busy = 1; if (why == "") why = c "% " a } }
    END { if (busy) print "busy\t" substr(why, 1, 80); else if (bad || n == 0) print "unknown\tps printed no readable line"; else print "idle" }')
  PROBE_STATE="${out%%$'\t'*}"; [ "$PROBE_STATE" = "$out" ] || PROBE_WHY="${out#*$'\t'}"
}
# stop_row <app> <mid> <size> <source> <idle> <threshold> <usd> -> the outbox
# file (path in ROWF), then the POST; a failed POST keeps the file.
stop_row() {
  local sid="$2-$NOW"
  ROWF="$SDIR/outbox/$sid.json"
  jq -nc --arg sid "$sid" --arg app "$1" --arg mid "$2" --arg size "$3" --arg src "$4" \
    --argjson idle "$5" --argjson th "$6" --arg usd "$7" --arg box "$BOX" --arg at "$ISO_NOW" '
    {rows: [{stop_id: $sid, app: $app, machine_id: $mid, size: (if $size == "" then null else $size end),
             source: $src, idle_s: $idle, threshold_s: $th,
             usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end),
             status: "requested", box: (if $box == "" then null else $box end), stopped_at: $at}]}' > "$ROWF"
  if post_row "$ROWF"; then rm -f "$ROWF"
  else say "$1/$2: the stop row did not post — kept in outbox/$sid.json for the next pass"; fi
}
destroy_row() { # destroy_row <app> <mid> <size> <source> <stopped_s> <usd>
  local did="$2-$NOW"
  ROWF="$SDIR/outbox-destroy/$did.json"
  jq -nc --arg did "$did" --arg app "$1" --arg mid "$2" --arg size "$3" --arg src "$4" \
    --argjson st "$5" --arg usd "$6" --arg box "$BOX" --arg at "$ISO_NOW" '
    {rows: [{destroy_id: $did, app: $app, machine_id: $mid, size: (if $size == "" then null else $size end),
             source: $src, stopped_s: $st, usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end),
             kind: "destroy", status: "requested", box: (if $box == "" then null else $box end), destroyed_at: $at}]}' > "$ROWF"
  if post_row "$ROWF" /api/fly-idle/destroys; then rm -f "$ROWF"
  else say "$1/$2: the destroy row did not post — kept in outbox-destroy/$did.json for the next pass"; fi
}
# The recorded persistent builders: the machine_id of each state/fly/<p>.json
# (not <p>-active.json). bin/fly-provision.sh is the only thing that creates
# one, by hand, with a volume; bin/fly-dispatch.sh starts that id and nothing
# else. A record we cannot read is RECOK=0: no destroy at all.
RECOK=1; : > "$WORK/recorded.txt"
if [ -e "$H/state/fly" ] && { [ ! -d "$H/state/fly" ] || [ ! -r "$H/state/fly" ] || [ ! -x "$H/state/fly" ]; }; then RECOK=0; fi
for f in "$H"/state/fly/*.json; do
  [ -e "$f" ] || continue
  case "$f" in *-active.json) continue ;; esac
  jq -r '.machine_id // empty' "$f" >> "$WORK/recorded.txt" 2>/dev/null || { RECOK=0; say "state/fly/$(basename "$f") does not parse — no destroys this pass"; }
done
# destroy_ok <sig> <since> <mid> <mounts> -> rc 0 when the destroy rule holds;
# DSTOPPED = seconds. DKEEP names why a machine past the window is kept.
destroy_ok() {
  DSTOPPED=""; DKEEP=""
  case "$1" in pool|builder|lane-run) ;; *) return 1 ;; esac
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  DSTOPPED=$((NOW - $2)); [ "$DSTOPPED" -lt 0 ] && DSTOPPED=0
  [ "$NODESTROY" = 0 ] && [ "$DSTOPPED" -gt "$DESTROY_AFTER" ] || return 1
  if [ "$RECOK" != 1 ]; then DKEEP="a state/fly record is unreadable"
  elif grep -qxF -- "$3" "$WORK/recorded.txt"; then DKEEP="it is the recorded builder of a state/fly record"
  elif [ "$4" != 0 ]; then DKEEP="it has a mounted volume (${4:-unknown mounts})"
  fi
  [ -z "$DKEEP" ]
}

# The lane-run record, read once, at the first lane-run app. LROK: "" not read,
# 1 read, 0 unreadable or incomplete (every lane-run machine is unknown).
LROK=""
lane_read() {
  local why=""
  [ -n "$LROK" ] && return 0
  if ! command -v _jobs_req >/dev/null 2>&1; then why="no jobs client"
  elif ! JOBS_ALERT=0 _jobs_req GET /api/lane-fleet/machines > "$WORK/lane.json" 2>/dev/null; then why="request failed"
  elif ! jq -e '.machines | type == "array"' "$WORK/lane.json" >/dev/null 2>&1; then why="no machines array"
  elif ! jq -e '.incomplete != true' "$WORK/lane.json" >/dev/null 2>&1; then why="incomplete: more rows than one page"
  elif ! int_setting FLOOR lane_fleet.warm_floor 1; then why="settings row lane_fleet.warm_floor unreadable"
  fi
  if [ -n "$why" ]; then
    LROK=0; : > "$WORK/lane.tsv"
    say "lane-run: /api/lane-fleet/machines unreadable ($why) — lane-run machines are unknown this pass"
    return 0
  fi
  # The range bin/lane-fleet.sh applies (lf_int warm_floor 1 0 100).
  { [ "${#FLOOR}" -le 6 ] && [ "$FLOOR" -le 100 ]; } 2>/dev/null || FLOOR=1
  FLOOR=$((10#$FLOOR))
  LROK=1
  # id state started_at busy in_flight idle_s
  jq -r '.machines[] | [(.machine_id // ""), (.state // ""), (.started_at // ""), (.busy == true | tostring),
    (.in_flight == true | tostring), (.idle_s // "-" | tostring)] | @tsv' "$WORK/lane.json" > "$WORK/lane.tsv" 2>/dev/null
}
# The group warm floors (BH-7498), read once, at the first lane-run-<group> app.
# GRPOK: "" not read, 1 read, 0 unreadable (every group keeps the global floor).
GRPOK=""
groups_read() {
  [ -n "$GRPOK" ] && return 0
  GRPOK=0
  if ! command -v _jobs_req >/dev/null 2>&1; then
    say "lane-run groups: no jobs client — group apps keep the global floor"
  elif ! JOBS_ALERT=0 _jobs_req GET /api/lane-fleet/groups > "$WORK/groups.json" 2>/dev/null \
    || ! jq -e '.groups | type == "array"' "$WORK/groups.json" >/dev/null 2>&1; then
    say "lane-run groups: /api/lane-fleet/groups unreadable — group apps keep the global floor"
  else GRPOK=1
  fi
  return 0
}
# app_floor <app> -> AFLOOR: the group's warm_floor (0..100) for a lane-run-<group>
# app; the global FLOOR for the default app, an unknown app or an unreadable route.
app_floor() {
  local g
  AFLOOR="$FLOOR"
  case "$1" in lane-run-*) ;; *) return 0 ;; esac
  groups_read
  [ "$GRPOK" = 1 ] || return 0
  g=$(jq -r --arg a "$1" '[.groups[] | select(.app == $a) | .warm_floor][0] // empty | tostring' "$WORK/groups.json" 2>/dev/null)
  if [[ "$g" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$g))" -le 100 ]; then AFLOOR=$((10#$g))
  elif [ -n "$g" ]; then say "$1: group warm_floor '$g' is not 0..100 — the global floor applies"
  fi
  return 0
}
# ── 4c. act: one action on one machine, then exit ────────────────────────────
# act_beat <action> <app> <mid> <size> <usd> <detail> — a failed beat is one log line.
act_beat() {
  [ -x "$H/bin/beat.sh" ] || { say "act $1 $2/$3: no bin/beat.sh — no beat"; return 0; }
  "$H/bin/beat.sh" "$(jq -nc --arg a "$1" --arg app "$2" --arg mid "$3" --arg size "$4" --arg usd "$5" \
    --arg why "$ACT_WHY" --arg d "$6" --arg box "$BOX" '
    {kind: "fly_idle_action", action: $a, app: $app, machine_id: $mid, size: (if $size == "" then null else $size end),
     usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end), reason: $why, box: $box, detail: $d}')" \
    >/dev/null 2>&1 || say "act $1 $2/$3: the beat did not send"
}
act_main() {
  local sig line mid kind cpus mem ts img st out idle lr
  [ "$REG_OK" = 1 ] || { echo "act: catalog/fly-idle-signals.json does not validate"; return 1; }
  sig=$(signal_for "$ACT_APP")
  if [ "$ACT" = keep ]; then
    say "act keep $ACT_APP/$ACT_MID: $ACT_WHY"; echo "kept: $ACT_APP/$ACT_MID"; return 0
  fi
  case "$sig" in exempt|testhost)
    say "act $ACT $ACT_APP/$ACT_MID refused: the app's source is $sig"; echo "refused: $ACT_APP is $sig"; return 1 ;;
  esac
  if ! fly machine list -a "$ACT_APP" --json > "$WORK/m.json" 2>"$WORK/m.err" || ! jq -e 'type == "array"' "$WORK/m.json" >/dev/null 2>&1; then
    say "act $ACT $ACT_APP/$ACT_MID: machine list failed: $(sed -n '/[^[:space:]]/{p;q;}' "$WORK/m.err" | redact)"
    echo "act: machine list failed"; return 1
  fi
  st=started; [ "$ACT" = destroy ] && st=stopped
  line=$(machines_tsv "$WORK/m.json" "$st" | awk -F'\t' -v m="$ACT_MID" '$1 == m' | head -n 1)
  [ -n "$line" ] || { say "act $ACT $ACT_APP/$ACT_MID refused: no $st machine with that id"; echo "refused: $ACT_MID is not $st in $ACT_APP"; return 1; }
  IFS=$'\t' read -r mid kind cpus mem ts img <<< "$line"
  size_usd "$kind" "$cpus" "$mem"
  case "$ACT" in
    probe)
      if [ "$PROCS_OK" != 1 ]; then echo "unknown catalog/fly-work-procs.json does not validate"; return 1; fi
      probe "$ACT_APP" "$mid"
      [ "$PROBE_STATE" = busy ] && stamp_work "$ACT_APP" "$mid"
      say "act probe $ACT_APP/$mid: $PROBE_STATE${PROBE_WHY:+ ($PROBE_WHY)}"
      echo "$PROBE_STATE${PROBE_WHY:+ $PROBE_WHY}"
      [ "$PROBE_STATE" != unknown ] ;;
    stop)
      if [ "$NOSTOP" = 1 ]; then
        say "act stop $ACT_APP/$mid refused: settings unreadable (nostop=1)"; echo "refused: settings unreadable"; return 1
      fi
      [[ "$ts" =~ ^[0-9]+$ ]] || { say "act stop $ACT_APP/$mid refused: no parseable start time"; echo "refused: no start time"; return 1; }
      # An app the registry does not name has no work probe anyone chose for
      # it: never stopped by hand (lead review BLOCK on 83ca230c). Log and alert;
      # an operator adds an entry (metrics, exempt, ...) to settle it.
      if ! has_entry "$ACT_APP"; then
        say "act stop $ACT_APP/$mid refused: $ACT_APP has no entry in catalog/fly-idle-signals.json — not stopped${ACT_WHY:+ (asked: $ACT_WHY)}"
        "$H/bin/lane-alert.sh" --severity warn --id "fly-idle-act-unregistered-$ACT_APP" "$LANE" \
          "fly-idle-reaper act stop refused for $ACT_APP/$mid: the app has no entry in catalog/fly-idle-signals.json, so nothing proves the machine is idle. Add an entry (a metrics, pool, builder or exempt source with a reason), then ask again." \
          >/dev/null 2>&1 || say "act stop $ACT_APP/$mid: the unregistered-app alert did not send"
        echo "refused: $ACT_APP has no registry entry"; return 1
      fi
      # Probe first, in code: the prompt is not the guard. A metrics app is
      # probed too: a quiet CPU line is not proof, and a machine without ps is
      # refused.
      case "$sig" in pool|builder|lane-run|metrics)
        if [ "$sig" = lane-run ]; then
          lane_read
          lr=$(awk -F'\t' -v m="$mid" '$1 == m { print $4 "\t" $5; exit }' "$WORK/lane.tsv")
          if [ "$LROK" != 1 ] || [ -z "$lr" ]; then
            say "act stop $ACT_APP/$mid refused: no lane-fleet record for it"; echo "refused: no lane-fleet record"; return 1
          fi
          case "$lr" in *true*)
            say "act stop $ACT_APP/$mid refused: the lane record says busy or in flight"; echo "refused: busy or in flight"; return 1 ;;
          esac
        fi
        if [ "$PROCS_OK" != 1 ]; then
          say "act stop $ACT_APP/$mid refused: catalog/fly-work-procs.json does not validate, so no probe"; echo "refused: no probe"; return 1
        fi
        probe "$ACT_APP" "$mid"
        [ "$PROBE_STATE" = busy ] && stamp_work "$ACT_APP" "$mid"
        if [ "$PROBE_STATE" != idle ]; then
          say "act stop $ACT_APP/$mid refused: the probe answered $PROBE_STATE${PROBE_WHY:+ ($PROBE_WHY)}"
          echo "refused: probe $PROBE_STATE${PROBE_WHY:+ $PROBE_WHY}"; return 1
        fi ;;
      esac
      idle=$((NOW - ts)); [ "$idle" -lt 0 ] && idle=0
      if ! out=$(fly machine stop "$mid" -a "$ACT_APP" 2>&1); then
        say "act stop $ACT_APP/$mid: flyctl machine stop failed: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}' | redact)"
        echo "act: flyctl machine stop failed"; return 1
      fi
      stop_row "$ACT_APP" "$mid" "$SIZE" act "$idle" "$THRESH" "$USDH"
      say "act stop $ACT_APP/$mid: stopped (${SIZE:-size unknown}, \$${USDH:-?}/h)${ACT_WHY:+: $ACT_WHY}"
      act_beat stop "$ACT_APP" "$mid" "$SIZE" "$USDH" "Stopped $ACT_APP/$mid (${SIZE:-size unknown}). It saves \$${USDH:-?}/h.${ACT_WHY:+ Why: $ACT_WHY}"
      echo "stopped $ACT_APP/$mid" ;;
    destroy)
      if ! destroy_ok "$sig" "$ts" "$mid" "$img"; then
        say "act destroy $ACT_APP/$mid refused: the destroy rule does not hold (source ${sig:-none}, stopped ${DSTOPPED:-?}s, limit ${DESTROY_AFTER}s, nodestroy=$NODESTROY${DKEEP:+, kept: $DKEEP})"
        echo "refused: the destroy rule does not hold"; return 1
      fi
      if ! out=$(fly machine destroy "$mid" -a "$ACT_APP" 2>&1); then
        say "act destroy $ACT_APP/$mid: flyctl machine destroy failed: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}' | redact)"
        echo "act: flyctl machine destroy failed"; return 1
      fi
      destroy_row "$ACT_APP" "$mid" "$SIZE" "$sig" "$DSTOPPED" "$USDH"
      say "act destroy $ACT_APP/$mid: destroyed after ${DSTOPPED}s stopped (${SIZE:-size unknown}, \$${USDH:-?}/h)${ACT_WHY:+: $ACT_WHY}"
      act_beat destroy "$ACT_APP" "$mid" "$SIZE" "$USDH" "Destroyed $ACT_APP/$mid (${SIZE:-size unknown}), stopped for $((DSTOPPED / 86400)) d. A restart would cost \$${USDH:-?}/h.${ACT_WHY:+ Why: $ACT_WHY}"
      echo "destroyed $ACT_APP/$mid" ;;
  esac
}
if [ "$MODE" = act ]; then act_main; exit $?; fi

# ── 5. apps ──────────────────────────────────────────────────────────────────
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
# app<TAB>org slug, for the metrics query (FLY_ORG wins when it is set).
printf '%s' "$APPS_OUT" | jq -r '.[] | [(.Name // .name // ""), (.Organization.Slug // .organization.slug // "")] | @tsv' \
  > "$WORK/app-org.tsv" 2>/dev/null

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
# The metrics read, once per org. metrics_read <org> -> MOK off|0|1, and the
# TSV in $WORK/mx-<org>.tsv when 1. No org slug is `off`: no signal at all.
metrics_read() {
  MOK=off; MXF=""
  [[ "$1" =~ ^[a-z0-9-]+$ ]] || return 0
  MXF="$WORK/mx-$1.tsv"
  if [ ! -f "$MXF.ok" ]; then
    if command -v fly_metrics_fetch >/dev/null 2>&1 && fly_metrics_fetch "$1" "$THRESH" "$TOK" "$MXF"; then echo 1 > "$MXF.ok"
    else echo 0 > "$MXF.ok"; say "the Fly metrics query for org $1 failed — metrics machines are unknown this pass"; fi
  fi
  MOK=$(cat "$MXF.ok" 2>/dev/null)
}

# ── 7-8. per app, per started machine ────────────────────────────────────────
APPS=0; READ=0; FAILED=0
STARTED=0; BUSY=0; IDLE=0; OVER=0; STOPPING=0; STOPFAIL=0; UNKNOWN=0; NOSIG=0; EXEMPT=0
STOPS=0; PROBED=0; PROBEBUSY=0; DESTROYS=0; DESTROYING=0; DESTROYFAIL=0; NOCLAIM=0; METRICS=0; FLOOR_KEPT=0; LR_APP_READ=0
: > "$WORK/noclaim.tsv"; : > "$WORK/apps-nosig.txt"
: > "$WORK/rows.jsonl"; : > "$WORK/seen.txt"; : > "$WORK/apps-read.txt"; : > "$WORK/apps-started.txt"; : > "$WORK/failing.txt"

# fail_count <app> <mid> <why> — one more failed read or stop for this machine;
# FAIL_N is the new streak. fail_note also logs it.
fail_count() {
  FAIL_N=$(count_up "$SDIR/fail/$1__$2")
  UNKNOWN_WHY="$3"
}
fail_note() {
  fail_count "$@"
  say "$1/$2: $3 (fail $FAIL_N in a row)"
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
  machines_tsv "$WORK/m.json" started > "$WORK/started.tsv"
  # The warm floor: the FLOOR lane-run machines with the lowest idle (busy and
  # in flight count as 0) are kept, whatever their idle.
  : > "$WORK/floor.txt"
  # A lane-run app with no started machine does not read the route (BH-6714 L12).
  [ "$sig" = lane-run ] && LR_APP_READ=1
  if [ "$sig" = lane-run ] && [ -s "$WORK/started.tsv" ]; then
    lane_read
    AFLOOR="$FLOOR"; [ "$LROK" = 1 ] && app_floor "$app"
    [ "$LROK" = 1 ] && [ "$AFLOOR" -gt 0 ] && cut -f1 "$WORK/started.tsv" | while IFS= read -r m; do
      awk -F'\t' -v m="$m" '$1 == m { i = ($4 == "true" || $5 == "true") ? 0 : $6; if (i !~ /^[0-9]+$/) i = 0; print i "\t" m; exit }' "$WORK/lane.tsv"
    done | sort -k1,1n -k2,2 | head -n "$AFLOOR" | cut -f2 > "$WORK/floor.txt"
  fi
  aorg="$ORG"; [ -n "$aorg" ] || aorg=$(awk -F'\t' -v a="$app" '$1 == a { print $2; exit }' "$WORK/app-org.tsv")
  while IFS=$'\t' read -r mid kind cpus mem ts img; do
    [ -n "$mid" ] || continue
    STARTED=$((STARTED + 1)); echo "$app" >> "$WORK/apps-started.txt"
    echo "$app __$mid" >> "$WORK/seen.txt"
    size_usd "$kind" "$cpus" "$mem"; size="$SIZE"; usdh="$USDH"
    state=""; idle=""; UNKNOWN_WHY=""; floored=0; noclaim=null
    case "$mid" in *[!0-9a-f]*|'') state=unknown; fail_note "$app" "$mid" "machine id is not hex — not stoppable" ;; esac
    if [ -n "$state" ]; then :
    # A registry that does not validate is not "no signal": the registry alert
    # already says so, and a nosignal streak per app would page once per app.
    elif [ "$REG_OK" = 0 ]; then state=unknown
    elif [ -z "$sig" ]; then state=nosignal
    elif [ "$sig" = exempt ]; then state=exempt
    elif [ "$sig" = lane-run ]; then
      lr=""; [ "$LROK" = 1 ] && lr=$(awk -F'\t' -v m="$mid" '$1 == m' "$WORK/lane.tsv" | head -n 1)
      if [ "$LROK" != 1 ]; then
        # lane_read logged the reason once for the pass; count, do not log per machine.
        state=unknown; fail_count "$app" "$mid" "GET /api/lane-fleet/machines is unreadable or incomplete"
      elif [ -z "$lr" ]; then
        state=unknown; fail_note "$app" "$mid" "no lane_machines row for a started machine (lane-fleet adopts it)"
      else
        IFS=$'\t' read -r _ lst lat lbusy lfl lidle <<< "$lr"
        # A `starting` row has made no claim since its start (lane-fleet.js).
        noclaim=false
        if [ "$lst" = starting ] && [ -n "$NOCLAIM_S" ] && [ -n "$lat" ] && lse=$(date -u -d "$lat" +%s 2>/dev/null) \
          && [ $((NOW - lse)) -gt "$NOCLAIM_S" ]; then
          noclaim=true; NOCLAIM=$((NOCLAIM + 1))
          printf '%s\t%s\t%s\n' "$img" "$mid" "$((NOW - lse))" >> "$WORK/noclaim.tsv"
        fi
        grep -qxF -- "$mid" "$WORK/floor.txt" && floored=1
        if [ "$lbusy" = true ] || [ "$lfl" = true ]; then state=busy; idle=0; [ "$lbusy" = true ] && stamp_work "$app" "$mid"
        elif [[ ! "$lidle" =~ ^[0-9]+$ ]]; then state=unknown; fail_note "$app" "$mid" "the lane row has no idle_s"
        else idle="$lidle"
          # A kept machine is `floor` (the snapshot shows exempt), never stopped.
          [ "$floored" = 1 ] && state=floor
        fi
      fi
    elif [ "$sig" = metrics ]; then
      metrics_read "$aorg"
      if [ "$MOK" = off ]; then state=nosignal
      elif [ "$MOK" != 1 ]; then state=unknown; fail_note "$app" "$mid" "the Fly metrics query failed"
      else
        mx=$(awk -F'\t' -v m="$mid" '$1 == m { print $2 "\t" $3; exit }' "$MXF")
        mcpu="${mx%%$'\t'*}"; mnet="${mx#*$'\t'}"
        if [ -z "$mx" ] || [[ ! "$mcpu" =~ ^[0-9.eE+-]+$ ]] || [[ ! "$mnet" =~ ^[0-9.eE+-]+$ ]]; then
          state=unknown; fail_note "$app" "$mid" "no metrics series for the machine (cpu '${mcpu:-}', net '${mnet:-}')"
        elif awk -v c="$mcpu" -v n="$mnet" -v mc="$M_CPU" -v mn="$M_NET" 'BEGIN { exit !((c + 0) >= mc || (n + 0) >= mn) }'; then
          METRICS=$((METRICS + 1)); state=busy; idle=0; stamp_work "$app" "$mid"
        elif [ "$ts" = - ] || [[ ! "$ts" =~ ^[0-9]+$ ]]; then
          state=unknown; fail_note "$app" "$mid" "no parseable start time in events"
        else
          METRICS=$((METRICS + 1))
          base="$ts"; w=$(work_at "$app" "$mid") && [ "$w" -gt "$base" ] && base="$w"
          idle=$((NOW - base)); [ "$idle" -lt 0 ] && idle=0
        fi
      fi
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
        state=busy; idle=0; stamp_work "$app" "$mid"
      elif [ "$ts" = - ] || [[ ! "$ts" =~ ^[0-9]+$ ]]; then
        state=unknown; fail_note "$app" "$mid" "no parseable timestamp in events"
      else
        base="$ts"; w=$(work_at "$app" "$mid") && [ "$w" -gt "$base" ] && base="$w"
        idle=$((NOW - base)); [ "$idle" -lt 0 ] && idle=0
      fi
    fi
    if [ -z "$state" ]; then
      if [ "$idle" -le "$athresh" ]; then state=idle
      elif [ "$anostop" = 1 ] || [ "$STOPS" -ge "$MAXSTOPS" ]; then state=over
      else
        # pool, builder and lane-run are probed first; a probe counts against the cap.
        case "$sig" in pool|builder|lane-run)
          if [ "$PROCS_OK" != 1 ] || [ "$PROBED" -ge "$MAXSTOPS" ]; then state=over
          else
            PROBED=$((PROBED + 1)); probe "$app" "$mid"
            case "$PROBE_STATE" in
              idle) ;;
              busy) state=busy; idle=0; PROBEBUSY=$((PROBEBUSY + 1)); stamp_work "$app" "$mid"
                    say "$app/$mid: idle ${idle}s by its witness, but the probe shows work: $PROBE_WHY — not stopped" ;;
              *) state=unknown; fail_note "$app" "$mid" "probe: ${PROBE_WHY:-no answer}" ;;
            esac
          fi ;;
        esac
      fi
      if [ -z "$state" ]; then
        STOPS=$((STOPS + 1))
        if out=$(fly machine stop "$mid" -a "$app" 2>&1); then
          state=stopping; STOPPING=$((STOPPING + 1))
          say "$app/$mid: stopped after ${idle}s idle (limit ${athresh}s, ${size:-size unknown}, \$${usdh:-?}/h, source $sig)"
          stop_row "$app" "$mid" "$size" "$sig" "$idle" "$athresh" "$usdh"
        else
          state=over; STOPFAIL=$((STOPFAIL + 1))
          fail_note "$app" "$mid" "flyctl machine stop failed: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}' | redact)"
        fi
      fi
    fi
    [ "$state" = nosignal ] && echo "$app" >> "$WORK/apps-nosig.txt"
    case "$state" in
      busy) BUSY=$((BUSY + 1)) ;; idle) IDLE=$((IDLE + 1)) ;; over) OVER=$((OVER + 1)) ;;
      unknown) UNKNOWN=$((UNKNOWN + 1)) ;; nosignal) NOSIG=$((NOSIG + 1)) ;; exempt) EXEMPT=$((EXEMPT + 1)) ;;
      floor) FLOOR_KEPT=$((FLOOR_KEPT + 1)) ;;
    esac
    # A known answer (and a stop flyctl took) ends this machine's fail streak.
    if [ -n "$UNKNOWN_WHY" ]; then echo "$app" >> "$WORK/failing.txt"; else rm -f "$SDIR/fail/${app}__$mid"; fi
    # The worker takes hex machine ids only; one bad row would refuse the whole
    # snapshot. The machine is still counted unknown and logged above.
    case "$mid" in *[!0-9a-f]*) continue ;; esac
    # A floor machine is kept on purpose: the worker and the panel call that exempt.
    th_json="$athresh"; st_json="$state"
    case "$state" in nosignal|exempt) th_json=null ;; floor) th_json=null; st_json=exempt ;; esac
    lw=""; w=$(work_at "$app" "$mid") && lw=$(date -u -d "@$w" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    jq -nc --arg app "$app" --arg mid "$mid" --arg size "$size" --arg src "${sig:-none}" --arg idle "$idle" \
      --arg st "$st_json" --argjson th "$th_json" --arg usd "$usdh" --arg lw "$lw" --argjson nc "$noclaim" '
      {app: $app, machine_id: $mid, size: (if $size == "" then null else $size end), source: $src,
       idle_s: (if $idle == "" then null else ($idle | tonumber) end), idle_state: $st, threshold_s: $th,
       usd_per_hour: (if $usd == "" then null else ($usd | tonumber) end),
       last_work_at: (if $lw == "" then null else $lw end), no_claim: $nc}' >> "$WORK/rows.jsonl"
  done < "$WORK/started.tsv"

  # Stopped machines of a pool, builder or lane-run app: the destroy step.
  case "$sig" in pool|builder|lane-run) ;; *) continue ;; esac
  machines_tsv "$WORK/m.json" stopped > "$WORK/stopped.tsv"
  while IFS=$'\t' read -r mid kind cpus mem since mnt; do
    case "$mid" in *[!0-9a-f]*|'') continue ;; esac
    if [[ ! "$since" =~ ^[0-9]+$ ]]; then say "$app/$mid: stopped, with no parseable stop time — not destroyed"; continue; fi
    if ! destroy_ok "$sig" "$since" "$mid" "${mnt:-?}"; then
      [ -n "$DKEEP" ] && say "$app/$mid: stopped ${DSTOPPED}s, not destroyed: $DKEEP"
      continue
    fi
    if [ "$DESTROYS" -ge "$DESTROY_MAX" ]; then say "$app/$mid: stopped ${DSTOPPED}s — over the destroy cap $DESTROY_MAX, next pass"; continue; fi
    DESTROYS=$((DESTROYS + 1))
    size_usd "$kind" "$cpus" "$mem"
    if out=$(fly machine destroy "$mid" -a "$app" 2>&1); then
      DESTROYING=$((DESTROYING + 1))
      say "$app/$mid: destroyed after ${DSTOPPED}s stopped (limit ${DESTROY_AFTER}s, ${SIZE:-size unknown}, \$${USDH:-?}/h)"
      destroy_row "$app" "$mid" "$SIZE" "$sig" "$DSTOPPED" "$USDH"
      rm -f "$SDIR/fail/${app}__$mid"
    else
      DESTROYFAIL=$((DESTROYFAIL + 1))
      echo "$app __$mid" >> "$WORK/seen.txt"; echo "$app" >> "$WORK/failing.txt"
      fail_note "$app" "$mid" "flyctl machine destroy failed: $(printf '%s\n' "$out" | sed -n '/[^[:space:]]/{p;q;}' | redact)"
    fi
  done < "$WORK/stopped.tsv"
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
# work/<app>__<mid>: the same prune; a stopped machine starts from its start event.
for f in "$SDIR"/work/*__*; do
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
[ "$REG_OK" = 1 ] && for app in $(sort -u "$WORK/apps-nosig.txt"); do
  f="$SDIR/nosignal/$app"
  [ -f "$f" ] || echo "$NOW" > "$f"
  first=$(cat "$f" 2>/dev/null); case "$first" in ''|*[!0-9]*) first="$NOW"; echo "$NOW" > "$f" ;; esac
  if [ $((NOW - first)) -ge "$NOSIG_S" ]; then
    cond_fire "fly-idle-nosignal-$app" "Fly app $app has had a started machine for $(( (NOW - first) / 60 ))m and has no idle signal, so fly-idle-reaper never stops it. Its metrics signal needs an org slug (FLY_ORG, or the apps list). Or register its source in catalog/fly-idle-signals.json (pool, builder, lane-run, testhost, metrics, or exempt with a reason)."
  fi
done
[ "$REG_OK" = 1 ] && for f in "$SDIR"/nosignal/*; do
  [ -f "$f" ] || continue
  app=$(basename "$f")
  grep -qxF -- "$app" "$WORK/apps-nosig.txt" && continue
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

# fly-no-claim-<digest>: one alert per image digest with a lane-run machine
# that has made no claim since it booted. Cleared only on a pass that read the
# lane-fleet route, and never decided while fly.no_claim_alert_s is unreadable.
if { [ "$LROK" = 1 ] || { [ -z "$LROK" ] && [ "$LR_APP_READ" = 1 ]; }; } && [ -n "$NOCLAIM_S" ]; then
  : > "$WORK/noclaim-ids.txt"
  while IFS=$'\t' read -r img mid age; do
    [ -n "$img" ] || continue
    case "$img" in
      sha256:*) did=$(printf '%s' "${img#sha256:}" | tr -cd '0-9a-f' | cut -c1-12) ;;
      *) did=$(printf '%s' "$img" | sha256sum | cut -c1-12) ;;
    esac
    [ -n "$did" ] || continue
    grep -qxF -- "$did" "$WORK/noclaim-ids.txt" && continue
    echo "$did" >> "$WORK/noclaim-ids.txt"
    n=$(awk -F'\t' -v i="$img" '$1 == i' "$WORK/noclaim.tsv" | wc -l)
    cond_fire "fly-no-claim-$did" "Fly app lane-run has $n started machine(s) of image ${img:0:80} with no claim since boot, the oldest for over $(( NOCLAIM_S / 60 ))m (e.g. $mid, ${age}s). The image may not start bin/lane-run-worker.sh. Check flyctl logs -a lane-run -i $mid. This is an alert only; nothing is stopped for it."
  done < "$WORK/noclaim.tsv"
  for f in "$SDIR"/fired/fly-no-claim-*; do
    [ -f "$f" ] || continue
    did="${f##*/fly-no-claim-}"
    grep -qxF -- "$did" "$WORK/noclaim-ids.txt" || cond_clear "fly-no-claim-$did" "No lane-run machine of image digest $did is without a claim any more."
  done
fi

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
say "pass apps=$APPS read=$READ failed=$FAILED partial=$PARTIAL started=$STARTED busy=$BUSY idle=$IDLE over=$OVER stopping=$STOPPING stop_failed=$STOPFAIL unknown=$UNKNOWN nosignal=$NOSIG exempt=$EXEMPT threshold=$THRESH($TSRC) nostop=$NOSTOP probed=$PROBED probe_busy=$PROBEBUSY destroying=$DESTROYING destroy_failed=$DESTROYFAIL noclaim=$NOCLAIM metrics=$METRICS floor=$FLOOR_KEPT"
exit 0
