#!/bin/bash
# bin/cli-version-check.sh — HUB, daily at 05:40Z (23 minutes after every box's
# 05:17 update-runners tick): ssh each fleet.conf box, read the runner CLI
# versions (claude, codex and grok — the `clis` keys of the catalog, so the
# catalog is the one place a CLI is added) its CRON PATH resolves, the PATH the
# lanes actually run under, and its login PATH, and compare them against the
# hub's own versions and against
# the per-model floors in catalog/cli-min-versions.json. ONE ALERTS line per
# box that is behind the hub, below a floor for a model its env or the fleet
# defaults name, missing a CLI, or split between its two PATHs; a summary line
# in logs/cli-version-check.log otherwise. The whole fleet table also lands in
# the harness-jobs DB (cli_versions rows with source=check, box_status current
# state) — fail-soft, the log and state/cli-versions-fleet.tsv are the record
# when the worker is unreachable.
#
# Why (2026-09-06): the Fable 5.1 bump needed claude-code >= 2.1.251 and
# box-project-9-1 sat on 2.1.250 for days; its codex npm update failed
# every morning into its own log. Nothing compared versions across the fleet,
# so a stranded box looked exactly like a quiet one. Detection only — this
# script never installs or relinks anything on a box (that is
# bin/cli-update.sh, which every ALERT here names as the fix).
#
# SELF-REPORTS FIRST (BH-2626). Every box posts its claude/codex versions hourly
# (bin/box-self-report.sh). A box whose row is TRUSTED is judged from it and not
# ssh'd: fresher than CLI_CHECK_SELF_REPORT_FRESH_S (a settings row, default
# 7200), both versions present, and cli_checked_at == rules_reported_at on that
# row, i.e. the newest CLI stamp came from a self-report that saw both CLIs, not
# from cli-update.sh's per-CLI post or this script's own source=check post, and
# the box's last full ssh probe is younger than CLI_CHECK_FULL_PROBE_S (a
# settings row, default 604800 = a week). A DB-judged box is held to behind-hub
# and the fleet-default floors only (no grok, no per-box *_MODEL floors, no
# cron-vs-login split), and posts NO source=check row: the hub did not observe
# that version. Those three checks the row cannot answer run on the full probe:
# in steady state every row is trusted, and without it they would never run
# again. Its report line names what the row verified and when the rest last ran.
# Anything else, and the hub itself, is probed over ssh exactly as before; a box
# whose full probe is due and does not answer is UNREACHABLE, re-tried every
# run until it answers. 0 = ssh every box.
#
# Overrides (tests only): HARNESS, HARNESS_CHECKOUT, HARNESS_ALERTS,
# CLI_CHECK_BOXES ("local" = the hub), CLI_CHECK_SSH, CLI_CHECK_CATALOG; and,
# inside the probe (exported through the ssh stub): CLI_CHECK_ENV_FILE,
# CLI_CHECK_LOGIN_PATH, CLI_CHECK_HOME, CLI_CHECK_ETC, CLI_CHECK_UU_LOGS.
#
# OS SECURITY UPDATES (BH-6742). The probe also prints `sec <last-run|never>
# <pending|unknown> <setup 1|0>`: the newest unattended-upgrade log write, the
# security packages a read-only `apt-get -s upgrade` would still install, and
# whether bin/security-updates-ensure.sh's apt.conf and cron files exist. The
# report gets one line per box: "<id> security updates: last run <at>, <n>
# pending, setup yes|NO". It is a report, not an alert. A box judged from its
# self-report is not ssh'd, so its line says it was not probed today.
#
# NODE AND TAILSCALE (BH-6742). The probe prints `tool node <v>` and `tool
# tailscale <v>`. Each is compared with the vendor's release feed (cached, see
# feed_rows): "<id> tools: node <v> (current | latest <x>: <n> releases, <d>
# days behind | latest unknown ...)". One ALERTS line per box per UTC day when
# a tool is more than CLI_CHECK_TOOL_BEHIND_RELEASES (default 3) releases or
# CLI_CHECK_TOOL_BEHIND_DAYS (default 30) days behind; both are settable lane
# knobs. A feed it cannot read is "latest unknown" and never alerts. Test
# seams: CLI_CHECK_FEED_CURL, CLI_CHECK_FEED_NODE_URL,
# CLI_CHECK_FEED_TAILSCALE_URL, CLI_CHECK_FEED_TTL_S.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cli-version-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cli-version-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cli-version-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cli-version-check
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/cli-version.sh
. "$HERE/lib/cli-version.sh"
# shellcheck source=bin/lib/cron-lines.sh
[ -r "$HERE/lib/cron-lines.sh" ] && . "$HERE/lib/cron-lines.sh"
declare -F cron_box_id_for >/dev/null 2>&1 || cron_box_id_for() { local b="${1#box-}"; case "$b" in ''|local|1) echo hub ;; *) echo "${b%-[0-9]*}" ;; esac; }

LOG="$H/logs/cli-version-check.log"
ALERTS="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
TSV="$H/state/cli-versions-fleet.tsv"
CATALOG="${CLI_CHECK_CATALOG:-$CHECKOUT/catalog/cli-min-versions.json}"
[ -s "$CATALOG" ] || CATALOG="$H/catalog/cli-min-versions.json"
SSH_CMD="${CLI_CHECK_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/state" 2>/dev/null
AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cli-version-check
# shellcheck source=/dev/null
[ -f "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null

# --- which CLI a box is allowed to lack (BH-1636) ------------------------------
# CLI_CHECK_OPTIONAL is a settings row (lane.cli-version-check.cli_check_optional),
# a space-separated list of <cli>@<box-id> pairs, box ids as cron_box_id_for
# prints them. A listed pair whose CLI reads MISSING is not an alert: that box
# runs no lane that needs it. ONLY missing is waived. A listed CLI that IS
# installed still has to meet its floor, match the hub and agree across both
# PATHs, because a lane can still pick it up. Empty = every CLI required on
# every box, which is how the check behaved before the knob existed.
declare -A OPTIONAL=()
read -r -a _toks <<<"${CLI_CHECK_OPTIONAL:-}"   # split without globbing a stray '*'
for _tok in ${_toks[@]+"${_toks[@]}"}; do
  if [[ "$_tok" =~ ^[a-z0-9_-]+@[a-z0-9_-]+$ ]]; then
    OPTIONAL[$_tok]=1
  else
    echo "$(STAMP) CLI_CHECK_OPTIONAL: ignored malformed token '$_tok' (want <cli>@<box-id>, lowercase)" >> "$LOG"
  fi
done
unset _tok _toks

# --- the probe, run on each box via `bash -s` (and locally for the hub) -------
# Reads versions under the CRON PATH — the crontab's own PATH= line when it has
# one, cron's /usr/bin:/bin default otherwise — because that is the PATH
# run-triage/run-build/agent-call inherit, and under a LOGIN PATH, because a
# human at a shell sees that one. Model ids from the box's env (*_MODEL=) are
# model NAMES, not secrets, and are filtered to id-shaped characters anyway.
# The env file is sourced with set -a for the PATH-affecting variables it may
# carry; nothing from it is printed except those model ids.
read -r -d '' PROBE <<'PROBE_EOF'
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf '%s\n' /root/harness/env; }; E=$(harness_env_dir)
ENVF="${CLI_CHECK_ENV_FILE:-$E/global.env}"
set -a +u; . "$ENVF" 2>/dev/null; set +a -u
CRON_PATH=$(crontab -l 2>/dev/null | sed -n 's/^PATH=//p' | tail -1); CRON_PATH="${CRON_PATH:-/usr/bin:/bin}"
LOGIN_PATH="${CLI_CHECK_LOGIN_PATH:-/usr/local/bin:/usr/bin:/bin}"
GROK_LAUNCHER="${CLI_CHECK_HOME:-$HOME}/.grok/bin/grok"
ver() { local o; o=$(timeout 10 "$1" --version 2>/dev/null | head -1); printf '%s' "$o" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }
# grok's launcher before PATH, in BOTH views: xAI's installer never links into
# /usr/bin, and every lane prepends $HOME/.grok/bin (bin/agent-call.sh,
# bin/lane-probe.sh, bin/orchestrate.sh). PATH-only would report the whole
# fleet MISSING, and a box whose /usr/local/bin holds an older grok would read
# as a cron-vs-login split it does not have.
cli_in() { # cli_in <cli> <path-list> -> the binary the lanes would run
  [ "$1" = grok ] && [ -x "$GROK_LAUNCHER" ] && { printf '%s' "$GROK_LAUNCHER"; return 0; }
  ( PATH="$2"; command -v "$1" 2>/dev/null || true )
}
for c in $CLI_LIST; do
  p=$(cli_in "$c" "$CRON_PATH");  v="";  [ -n "$p" ]  && v=$(ver "$p")
  lp=$(cli_in "$c" "$LOGIN_PATH"); lv=""; [ -n "$lp" ] && lv=$(ver "$lp")
  echo "cli $c ${v:-missing} ${p:--} ${lv:-missing} ${lp:--}"
done
M=$(env | grep -E '^[A-Z_]*MODEL[A-Z_]*=' | cut -d= -f2- | tr -c 'A-Za-z0-9._/\n-' ' ' | tr '\n' ' ')
echo "models ${M:0:400}"
echo "box $(tr -dc 'a-z0-9-' < /root/harness/state/box-id 2>/dev/null) host $(hostname 2>/dev/null)"
# OS security updates (BH-6742): the newest unattended-upgrade log write, the
# security packages apt would still install (a read-only simulation), and
# whether bin/security-updates-ensure.sh's apt.conf and cron files are there.
SEC_ETC="${CLI_CHECK_ETC:-/etc}"; lm=0; last=never
for f in ${CLI_CHECK_UU_LOGS:-/var/log/harness-unattended.log /var/log/unattended-upgrades/unattended-upgrades.log}; do
  m=$(stat -c %Y "$f" 2>/dev/null) || continue; [ "$m" -gt "$lm" ] && lm=$m
done
[ "$lm" -gt 0 ] && last=$(date -u -d "@$lm" +%Y-%m-%dT%H:%M:%SZ)
pend=unknown
# A failed or timed-out simulation stays `unknown`, never a count of 0.
if command -v apt-get >/dev/null 2>&1 && sim=$(timeout 60 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null); then
  pend=$(printf '%s\n' "$sim" | grep -c '^Inst .*-security')
fi
setup=0
[ -s "$SEC_ETC/apt/apt.conf.d/52harness-security-only" ] && [ -s "$SEC_ETC/cron.d/harness-security-updates" ] && setup=1
echo "sec $last ${pend:-unknown} $setup"
# node and tailscale (BH-6742): the versions this box runs.
# Looked up on the login PATH first, then this shell's: a node installed under
# /usr/local/bin is still found from ssh's narrower PATH.
nb=$( PATH="$LOGIN_PATH:$PATH"; command -v node 2>/dev/null ); tb=$( PATH="$LOGIN_PATH:$PATH"; command -v tailscale 2>/dev/null )
nv=""; [ -n "$nb" ] && nv=$(timeout 10 "$nb" --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
tv=""; [ -n "$tb" ] && tv=$(timeout 10 "$tb" version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
echo "tool node ${nv:-missing}"
echo "tool tailscale ${tv:-missing}"
echo "probe-done"
PROBE_EOF

# The CLIs to probe are the catalog's `clis` keys, not a second hardcoded list:
# the floors already live there, and a CLI added to the catalog with nothing
# probing it is a floor nobody checks. Prepended as the probe's first line so
# the ssh'd copy carries it (the heredoc above is quoted, on purpose).
# Filtered to id-shaped characters because this string is interpolated into a
# single-quoted shell line that is then piped to `bash -s` on ten boxes: one
# quote in a catalog key would otherwise be a broken probe on the whole fleet.
CLI_LIST=""
[ -s "$CATALOG" ] && command -v jq >/dev/null 2>&1 \
  && CLI_LIST=$(jq -r '.clis | keys[]?' "$CATALOG" 2>/dev/null | tr -cd 'A-Za-z0-9_\n-' | tr '\n' ' ')
[ -n "${CLI_LIST// /}" ] || CLI_LIST="claude codex grok"
PROBE="CLI_LIST='$CLI_LIST'
$PROBE"

# --- the box list: fleet.conf column 6 plus the hub; PARKED rows are comments --
if [ -n "${CLI_CHECK_BOXES:-}" ]; then
  BOXES="$CLI_CHECK_BOXES"
else
  BOXES=$(printf 'local\n%s\n' \
    "$(awk '!/^[[:space:]]*(#|$)/ && NF>=6 {print $6}' "$CHECKOUT/fleet.conf" 2>/dev/null)" \
    | grep -v '^$' | sort -u)
fi

# --- the floors: fleet defaults + whatever a box's env names -----------------
DEFAULT_MODELS=""
[ -s "$CATALOG" ] && command -v jq >/dev/null 2>&1 \
  && DEFAULT_MODELS=$(jq -r '.fleet_defaults[]? // empty' "$CATALOG" 2>/dev/null | tr '\n' ' ')

probe() { # probe <box> -> probe output (empty when unreachable)
  if [ "$1" = local ]; then bash -c "$PROBE" 2>/dev/null
  else $SSH_CMD "root@$1" "bash -s" <<<"$PROBE" 2>/dev/null; fi
}

# --- self-reports (BH-2626) ---------------------------------------------------
# Rows are keyed by the cron box id, as the hub's own rows are; where two rows
# answer for one id (a generation suffix) the newest cli_checked_at wins.
FRESH="${CLI_CHECK_SELF_REPORT_FRESH_S:-7200}"
case "$FRESH" in ''|*[!0-9]*) FRESH=7200 ;; esac
FULL="${CLI_CHECK_FULL_PROBE_S:-604800}"
case "$FULL" in ''|*[!0-9]*) FULL=604800 ;; esac
FPDIR="$H/state/cli-version-check"
mkdir -p "$FPDIR" 2>/dev/null
NOW=$(date +%s)
# full_probe_age <id> — seconds since the box last answered a full ssh probe,
# stamped in $FPDIR/fullprobe-<id>; empty when it never has (or the stamp is bad).
full_probe_age() {
  local e
  e=$(cat "$FPDIR/fullprobe-$1" 2>/dev/null)
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  echo $((NOW - e))
}
# sr_fresh <at> — rc 0 when <at> is the exact UTC stamp shape, at most 300 s in
# the future (clock skew) and younger than FRESH. Anything else is stale.
sr_fresh() {
  local e
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ -n "$1" ] || return 1
  e=$(date -u -d "$1" +%s 2>/dev/null) || return 1
  [ $((NOW - e + 300)) -ge 0 ] && [ $((NOW - e)) -lt "$FRESH" ]
}
declare -A SR_CLI=()   # cron id -> cli \037 codex \037 cli_checked_at \037 rules_reported_at
if [ "$FRESH" -gt 0 ] && declare -F box_self_reports >/dev/null 2>&1; then
  if SR=$(box_self_reports 2>/dev/null); then
    # \037, not a tab, as the read separator: tab is IFS whitespace, so an empty
    # column would collapse and shift every field after it.
    while IFS=$'\037' read -r SB SC SX SCA _ SRA; do
      [ -n "$SB" ] && [ -n "$SCA" ] || continue
      SID=$(cron_box_id_for "$SB")
      IFS=$'\037' read -r _ _ PCA _ <<<"${SR_CLI[$SID]:-}"
      if [ -z "${SR_CLI[$SID]:-}" ] || [[ "$SCA" > "$PCA" ]]; then
        SR_CLI[$SID]="$SC"$'\037'"$SX"$'\037'"$SCA"$'\037'"$SRA"
      fi
    done < <(printf '%s\n' "$SR" | tr '\t' '\037')
  else
    echo "$(STAMP) cli-version-check: self-report read failed; ssh for every box" >> "$LOG"
  fi
fi

declare -A HUBV=()
OK=0; BEHIND=0; UNREACH=0; REPORT=""; ROWS="[]"
: > "$TSV.tmp"
# The hub first, so every other box has something to be behind.
# --- node and tailscale against the vendor's release feed (BH-6742) -----------
# feed_rows <tool> -> "<version>\t<epoch>" per stable release, from the cached
# feed: $H/state/tool-feeds/<tool>.tsv, fetched again when older than
# CLI_CHECK_FEED_TTL_S (default 86400). A failed fetch or an unparseable answer
# is rc 1 = "latest unknown", never "current": a stale cache is not used, and
# the failure is not cached, so the next run asks again. One fetch per tool per
# run, whatever the box count.
#   node       https://nodejs.org/dist/index.json (dated, every line)
#   tailscale  the GitHub releases of tailscale/tailscale (dated; no draft or
#              prerelease)
FEED_DIR="$H/state/tool-feeds"
FEED_TTL="${CLI_CHECK_FEED_TTL_S:-86400}"; [[ $FEED_TTL =~ ^[0-9]+$ ]] || FEED_TTL=86400
FEED_CURL="${CLI_CHECK_FEED_CURL:-curl}"
TOOL_BEHIND_REL="${CLI_CHECK_TOOL_BEHIND_RELEASES:-3}"; [[ $TOOL_BEHIND_REL =~ ^[0-9]+$ ]] || TOOL_BEHIND_REL=3
TOOL_BEHIND_DAYS="${CLI_CHECK_TOOL_BEHIND_DAYS:-30}"; [[ $TOOL_BEHIND_DAYS =~ ^[0-9]+$ ]] || TOOL_BEHIND_DAYS=30
declare -A FEED_FAILED=()
feed_url() {
  case "$1" in
    node)      printf '%s' "${CLI_CHECK_FEED_NODE_URL:-https://nodejs.org/dist/index.json}" ;;
    tailscale) printf '%s' "${CLI_CHECK_FEED_TAILSCALE_URL:-https://api.github.com/repos/tailscale/tailscale/releases?per_page=100}" ;;
  esac
}
feed_parse() { # feed_parse <tool> < raw JSON
  case "$1" in
    node) jq -r '.[] | select((.version // "") | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
            | [(.version | ltrimstr("v")), ((.date + "T00:00:00Z") | fromdateiso8601)] | @tsv' ;;
    tailscale) jq -r '.[] | select((.draft | not) and (.prerelease | not))
            | select((.tag_name // "") | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
            | [(.tag_name | ltrimstr("v")), (.published_at | fromdateiso8601)] | @tsv' ;;
    *) return 1 ;;
  esac
}
feed_rows() {
  local t="$1" f="$FEED_DIR/$1.tsv" m tmp
  # A file this run wrote is newer than NOW (taken at the start): age 0.
  if m=$(stat -c %Y "$f" 2>/dev/null) && [ -s "$f" ] && [ $(( NOW > m ? NOW - m : 0 )) -lt "$FEED_TTL" ]; then
    cat "$f"; return 0
  fi
  [ -n "${FEED_FAILED[$t]:-}" ] && return 1
  mkdir -p "$FEED_DIR" 2>/dev/null; tmp="$f.tmp.$$"
  if timeout 40 "$FEED_CURL" -fsSL --max-time 30 "$(feed_url "$t")" 2>/dev/null | feed_parse "$t" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$f"; cat "$f"; return 0
  fi
  rm -f "$tmp"; FEED_FAILED[$t]=1
  echo "$(STAMP) tool feed for $t unreadable ($(feed_url "$t")) — its latest is unknown this run" >> "$LOG"
  return 1
}
# ensure_feed <tool> — fills FEED_DATA[<tool>] (the rows) or FEED_FAILED[<tool>]
# ONCE per run. It must run in this shell, never in $( ): a memo set in a
# subshell is lost, and every box would fetch a dead feed again (lead review of
# #6787: 11 boxes, 11 fetches of up to 40 s, 11 log lines).
declare -A FEED_DATA=() FEED_DONE=()
ensure_feed() {
  local t="$1" r
  [ -n "${FEED_DONE[$t]:-}" ] && return 0
  FEED_DONE[$t]=1
  if r=$(feed_rows "$t"); then FEED_DATA[$t]="$r"; else FEED_FAILED[$t]=1; fi
}
# tool_gap <tool> <version> -> sets TG_LATEST, TG_REL (releases newer than
# <version>) and TG_DAYS (days since the oldest of them came out); rc 1 when the
# latest is unknown. node counts its own major line only: a new major is a
# migration, not an update.
tool_gap() {
  local t="$1" v="$2" rows line rv rd oldest=""
  TG_LATEST=""; TG_REL=0; TG_DAYS=0
  ensure_feed "$t"
  [ -z "${FEED_FAILED[$t]:-}" ] || return 1
  rows="${FEED_DATA[$t]:-}"
  [ "$t" = node ] && rows=$(awk -F'\t' -v m="${v%%.*}" 'index($1, m ".") == 1' <<<"$rows")
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r rv rd; do
    [ -n "$rv" ] || continue
    if [ -z "$TG_LATEST" ] || cli_version_gt "$rv" "$TG_LATEST"; then TG_LATEST="$rv"; fi
    if cli_version_gt "$rv" "$v"; then
      TG_REL=$((TG_REL + 1))
      if [ -z "$oldest" ] || [ "$rd" -lt "$oldest" ]; then oldest="$rd"; fi
    fi
  done <<<"$rows"
  [ -n "$oldest" ] && TG_DAYS=$(( (NOW - oldest) / 86400 ))
  [ "$TG_DAYS" -ge 0 ] || TG_DAYS=0
  return 0
}
TOOL_ALERTED="$H/state/tool-behind-alerted"
# The marks only need today's lines: keep those, drop the rest.
if [ -s "$TOOL_ALERTED" ]; then
  grep "^$(date -u -d "@$NOW" +%F) " "$TOOL_ALERTED" > "$TOOL_ALERTED.tmp" 2>/dev/null; mv -f "$TOOL_ALERTED.tmp" "$TOOL_ALERTED" 2>/dev/null
fi
TODAY=$(date -u -d "@$NOW" +%F)

ORDERED=$(printf '%s\n' "$BOXES" | grep -x local; printf '%s\n' "$BOXES" | grep -vx local)
for BOX in $ORDERED; do
  ID=$(cron_box_id_for "$BOX")
  SR_AT=""
  if [ "$BOX" != local ] && [ -n "${SR_CLI[$ID]:-}" ]; then
    IFS=$'\037' read -r SC SX SCA SRA <<<"${SR_CLI[$ID]}"
    if [ -n "$SC" ] && [ -n "$SX" ] && [ "$SC" != missing ] && [ "$SX" != missing ] \
       && [ "$SCA" = "$SRA" ] && sr_fresh "$SCA"; then
      AGE=$(full_probe_age "$ID")
      if [ -n "$AGE" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$FULL" ]; then
        SR_AT="$SCA"; FP_AT=$(date -u -d "@$((NOW - AGE))" +%Y-%m-%dT%H:%M:%SZ)
      fi
    fi
  fi
  if [ -n "$SR_AT" ]; then
    # Judged from the row: the same lines the probe prints, path "self-report@<at>".
    OUT=$(printf 'cli claude %s self-report@%s %s self-report@%s\ncli codex %s self-report@%s %s self-report@%s\nmodels \nprobe-done\n' \
      "$SC" "$SR_AT" "$SC" "$SR_AT" "$SX" "$SR_AT" "$SX" "$SR_AT")
  else
    OUT=$(probe "$BOX")
  fi
  if ! grep -q '^probe-done' <<<"$OUT"; then
    UNREACH=$((UNREACH+1)); REPORT="$REPORT\n  $ID UNREACHABLE"
    echo "$(STAMP) [$ID] cli-version-check could not probe $BOX over ssh — its runner CLI versions are unverified today. Check the box is up and ssh works from the hub." >> "$ALERTS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" "-" "unreachable" "-" "-" "-" >> "$TSV.tmp"
    continue
  fi
  [ "$BOX" = local ] || [ -n "$SR_AT" ] || echo "$NOW" > "$FPDIR/fullprobe-$ID"
  MODELS="$DEFAULT_MODELS $(awk '/^models /{$1=""; print}' <<<"$OUT")"
  REASONS=""
  while read -r _ CLI V P LV LP; do
    [ -n "$CLI" ] || continue
    CLI_REASONS=""
    [ "$BOX" = local ] && HUBV[$CLI]="$V"
    CLI_NOTE=""
    if [ "$V" = missing ] && [ -n "${OPTIONAL[$CLI@$ID]:-}" ]; then
      CLI_NOTE="not required on this box (CLI_CHECK_OPTIONAL)"
    elif [ "$V" = missing ]; then
      CLI_REASONS="$CLI MISSING on the cron PATH"
    else
      if [ "$BOX" != local ] && [ -n "${HUBV[$CLI]:-}" ] && [ "${HUBV[$CLI]}" != missing ] \
         && ! cli_version_ge "$V" "${HUBV[$CLI]}"; then
        CLI_REASONS="$CLI $V behind hub ${HUBV[$CLI]}"
      fi
      for M in $MODELS; do
        read -r MC MMIN < <(cli_min_for_model "$CATALOG" "$M" 2>/dev/null) || continue
        [ "$MC" = "$CLI" ] || continue
        if ! cli_version_ge "$V" "$MMIN"; then
          CLI_REASONS="${CLI_REASONS:+$CLI_REASONS; }$CLI $V below the $MMIN floor for $M"
        fi
      done
    fi
    if [ "$LV" != "$V" ]; then
      CLI_REASONS="${CLI_REASONS:+$CLI_REASONS; }$CLI split: cron PATH $V ($P) vs login PATH $LV ($LP)"
    fi
    CLI_OK=1; [ -z "$CLI_REASONS" ] || CLI_OK=0
    REASONS="${REASONS:+$REASONS; }$CLI_REASONS"; REASONS="${REASONS%; }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ID" "$CLI" "$V" "$P" "$LV" "${CLI_REASONS:-${CLI_NOTE:-ok}}" >> "$TSV.tmp"
    # A DB-judged box posts no source=check row: the hub did not observe it.
    [ -n "$SR_AT" ] && continue
    ROWS=$(jq -c --arg b "$ID" --arg c "$CLI" --arg v "$V" --arg p "$P" --arg n "${CLI_REASONS:-$CLI_NOTE}" --arg ok "$CLI_OK" --arg t "$AT" \
      '. + [{box:$b,cli:$c,at:$t,source:"check",version_before:$v,version_after:$v,method:"check",ok:$ok,path:$p,note:$n}]' <<<"$ROWS" 2>/dev/null || echo "$ROWS")
  done < <(grep '^cli ' <<<"$OUT")
  # OS security updates (BH-6742): reported per box, never an alert.
  read -r _ SEC_LAST SEC_PEND SEC_SETUP < <(grep '^sec ' <<<"$OUT"; echo)
  if [ -n "${SEC_LAST:-}" ]; then
    SECLINE="security updates: last run $SEC_LAST, $SEC_PEND pending, setup $([ "$SEC_SETUP" = 1 ] && echo yes || echo NO)"
  elif [ -n "$SR_AT" ]; then
    SECLINE="security updates: not probed today (judged from its self-report)"
  else
    SECLINE="security updates: not reported by the probe"
  fi
  if [ -n "$REASONS" ]; then
    BEHIND=$((BEHIND+1)); REPORT="$REPORT\n  $ID: $REASONS"
    FIX="/root/harness/bin/cli-update.sh on $ID"; [ "$BOX" = local ] || FIX="ssh root@$BOX /root/harness/bin/cli-update.sh"
    echo "$(STAMP) [$ID] CLI VERSIONS: $REASONS. Fix: $FIX, then re-run bin/cli-version-check.sh on the hub; details in logs/cli-version-check.log." >> "$ALERTS"
  else
    OK=$((OK+1))
    if [ -n "$SR_AT" ]; then
      REPORT="$REPORT\n  $ID ok (claude/codex via self-report $SR_AT; grok, model floors, PATH split via ssh $FP_AT)"
    else
      REPORT="$REPORT\n  $ID ok"
    fi
  fi
  REPORT="$REPORT\n  $ID $SECLINE"
  # node and tailscale (BH-6742): versions and the gap to the vendor's latest.
  TOOLLINE=""; TOOLALERT=""; TOOLMARKS=""
  while read -r _ TN TV; do
    [ -n "${TN:-}" ] || continue
    if [ "$TV" = missing ]; then TOOLLINE="$TOOLLINE, $TN missing"; continue; fi
    if ! tool_gap "$TN" "$TV"; then TOOLLINE="$TOOLLINE, $TN $TV (latest unknown: the feed could not be read)"; continue; fi
    if [ "$TG_REL" = 0 ]; then TOOLLINE="$TOOLLINE, $TN $TV (current)"; continue; fi
    TOOLLINE="$TOOLLINE, $TN $TV (latest $TG_LATEST: $TG_REL releases, $TG_DAYS days behind)"
    if [ "$TG_REL" -gt "$TOOL_BEHIND_REL" ] || [ "$TG_DAYS" -gt "$TOOL_BEHIND_DAYS" ]; then
      grep -qxF "$TODAY $ID $TN $TV" "$TOOL_ALERTED" 2>/dev/null && continue
      TOOLALERT="${TOOLALERT:+$TOOLALERT; }$TN $TV is $TG_REL releases and $TG_DAYS days behind $TG_LATEST"
      TOOLMARKS="${TOOLMARKS:+$TOOLMARKS
}$TODAY $ID $TN $TV"
    fi
  done < <(grep '^tool ' <<<"$OUT")
  if [ -n "$TOOLLINE" ]; then REPORT="$REPORT\n  $ID tools: ${TOOLLINE#, }"
  elif [ -n "$SR_AT" ]; then REPORT="$REPORT\n  $ID tools: not probed today (judged from its self-report)"
  fi
  # Through bin/alert-line.sh (the sanctioned writer), one row per box a day.
  [ -n "$TOOLALERT" ] && HARNESS="$H" "$HERE/alert-line.sh" --id "tool-behind-$ID" \
    "[$ID] TOOL VERSIONS: $TOOLALERT (limits: more than $TOOL_BEHIND_REL releases or $TOOL_BEHIND_DAYS days, settings rows lane.cli-version-check.cli_check_tool_behind_*). Fix: update it on the box; details in logs/cli-version-check.log." \
    && printf '%s\n' "$TOOLMARKS" >> "$TOOL_ALERTED"
done
mv -f "$TSV.tmp" "$TSV" 2>/dev/null

HUBLINE=""
for C in $CLI_LIST; do HUBLINE="$HUBLINE $C ${HUBV[$C]:-?}"; done
SUMMARY="fleet CLI versions: $OK ok, $BEHIND need attention, $UNREACH unreachable — hub${HUBLINE:- ?}; floors from $(basename "$CATALOG") for: ${DEFAULT_MODELS:-none}"
{ echo "$(STAMP) $SUMMARY"; printf '%b\n' "$REPORT" | sed "s/^/$(STAMP)   /"; } >> "$LOG"
echo "$SUMMARY"; printf '%b\n' "$REPORT"

# The fleet table into the DB, one request, fail-soft.
if declare -F metric_cli_versions >/dev/null 2>&1 && [ "$(jq 'length' <<<"$ROWS" 2>/dev/null || echo 0)" -gt 0 ]; then
  BODY=$(mktemp "${TMPDIR:-/tmp}/cli-versions.XXXXXX")
  jq -c '{rows: .}' <<<"$ROWS" > "$BODY" 2>/dev/null
  metric_cli_versions "$BODY" || echo "$(STAMP) DB push failed/skipped (http=${JOBS_HTTP:-none}); $TSV is the record" >> "$LOG"
  rm -f "$BODY"
fi
[ "$BEHIND" -eq 0 ] && [ "$UNREACH" -eq 0 ]
