#!/bin/bash
# bin/hub-load-sample.sh — BH-6882 (part of #6881): the hub load sampler. Hub
# only, every 10 min (cron/lanes/732-hub-load-sample.cron, behind
# bin/hub-lease.sh check). No LLM call, no paid call.
#
# One run:
#   1. HUB_LOAD_SAMPLES (30) `ps` samples, HUB_LOAD_INTERVAL_S (1) apart. Each
#      R-state process counts once per sample, under the nearest process in its
#      own parent chain (itself first) whose args hold bin/<name>.sh, else
#      (<comm>). This sampler's own process tree is not counted.
#   2. One `vmstat 5 2`: us sy id wa st of the LAST data line, by header column.
#      The `processes` line of /proc/stat, read twice HUB_LOAD_FORK_WINDOW_S
#      (10) apart, gives forks per second.
#   3. One line appended to state/hub-load/<YYYY-MM-DD UTC>.tsv:
#      <ISO time> runnable= steal= forks_s= cpu= samples= <name>=<share %> x15
#      (tab separated). A value that could not be read is NA, never 0.
#   4. One ledger row, kind hub-load, key <box>:<HH>:<M0> (the 10-min slot of
#      the UTC day, so at most 144 rows per box): job_ledger_put, upsert.
#   5. tsv files whose filename date is older than settings row
#      hub_load.keep_days (default 14) are deleted.
#   6. If the p90 of the last 6 runnable values (today's file, then
#      yesterday's) is over settings row hub_load.max_runnable (default 8):
#      one bin/lane-alert.sh --log-only line per UTC hour
#      (latch: state/hub-load/alert-hour).
#   7. After the summary line: bin/hub-load-baseline.sh, which posts the 24 h
#      baseline once (its own log, logs/hub-load-baseline.log).
#
# Summary line (logs/hub-load-sample.log), exit 0 on every path:
#   <ts> runnable= steal= forks_s= samples=<ok>/<want> push=<ok|failed|
#   not-configured|not-loaded> pruned=<n> alert=<written|latched|under|
#   insufficient(<n>)> keep_days=<n>(row|default) max_runnable=<n>(row|default)
#   | <ts> skipped (running)
#
# Test seams (catalog/lanes.d/hub-load-sample.json, not settable):
#   HUB_LOAD_SAMPLES, HUB_LOAD_INTERVAL_S, HUB_LOAD_FORK_WINDOW_S,
#   HUB_LOAD_PROC_STAT (default /proc/stat), HUB_LOAD_NOW (epoch seconds).
#
# OFF: flags/lane-off-hub-load-sample (bin/harness-ctl.sh off hub-load-sample).
# Doc: docs/notes/2026-10-15-BH-6882-hub-load-sample.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit hub-load-sample
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply hub-load-sample

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/hub-load-sample.log"
if [[ "${HUB_LOAD_NOW:-}" =~ ^[0-9]+$ ]]; then NOW=$HUB_LOAD_NOW; else NOW=$(date -u +%s); fi
STAMP=$(date -u -d "@$NOW" +%FT%TZ)
summary() { printf '%s %s\n' "$STAMP" "$1" >> "$LOG"; }

exec 8> "$H/locks/hub-load-sample.lock" 2>/dev/null || { summary "skipped (no lock file)"; exit 0; }
flock -n 8 || { summary "skipped (running)"; exit 0; }

# shellcheck source=bin/jobs-client.sh
LOADED=1; . "$SELF/jobs-client.sh" 2>/dev/null || LOADED=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hls.XXXXXX") || { summary "skipped (mktemp)"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '%s' "$2"; }
SAMPLES=$(num "${HUB_LOAD_SAMPLES:-}" 30)
{ [ "$SAMPLES" -ge 1 ] && [ "$SAMPLES" -le 300 ]; } 2>/dev/null || SAMPLES=30
INTERVAL=$(num "${HUB_LOAD_INTERVAL_S:-}" 1)
WINDOW=$(num "${HUB_LOAD_FORK_WINDOW_S:-}" 10)
PSTAT="${HUB_LOAD_PROC_STAT:-/proc/stat}"

# knob <var> <key> <default> — a positive-integer settings row, else the
# default. Sets <var> and <var>_SRC (row|default).
knob() {
  local v=""
  [ "$LOADED" = 1 ] && v=$(setting_get "$2" 2>/dev/null | tr -d '[:space:]')
  if [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]]; then printf -v "$1" '%s' "$v"; printf -v "$1_SRC" row
  else printf -v "$1" '%s' "$3"; printf -v "$1_SRC" default; fi
}
knob KEEP hub_load.keep_days 14
knob MAXR hub_load.max_runnable 8

# ── 1. ps samples ────────────────────────────────────────────────────────────
OK=0
: > "$TMP/names"
for ((i = 1; i <= SAMPLES; i++)); do
  if ps -eo pid=,ppid=,stat=,comm=,args= > "$TMP/ps" 2>/dev/null && [ -s "$TMP/ps" ]; then
    OK=$((OK + 1))
    awk -v self="$$" '
      { pid = $1; pp[pid] = $2; st[pid] = $3; cm[pid] = $4
        a = $0; for (k = 1; k <= 4; k++) sub(/^[ \t]*[^ \t]+/, "", a); sub(/^[ \t]+/, "", a)
        ar[pid] = a; order[++n] = pid }
      function harness(p,   m) {
        if (match(ar[p], /bin\/[A-Za-z0-9._-]+\.sh/)) { m = substr(ar[p], RSTART + 4, RLENGTH - 4); return m }
        return ""
      }
      END {
        for (j = 1; j <= n; j++) {
          p = order[j]
          if (substr(st[p], 1, 1) != "R") continue
          # walk self, parent, grandparent ... (depth 64, stop at 0/1 or a repeat)
          split("", seen); name = ""; mine = 0; q = p
          for (d = 0; d < 64; d++) {
            if (q == "" || q == 0 || (q in seen)) break
            seen[q] = 1
            if (q == self) { mine = 1; break }
            if (name == "" && (q in ar)) name = harness(q)
            if (q == 1 || !(q in pp)) break
            q = pp[q]
          }
          if (mine) continue
          if (name == "") name = "(" cm[p] ")"
          gsub(/[^A-Za-z0-9._:\/()-]/, "_", name)
          print name
        }
      }' "$TMP/ps" >> "$TMP/names"
  fi
  [ "$i" -lt "$SAMPLES" ] && [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
TOTAL=$(wc -l < "$TMP/names" | tr -d ' ')
if [ "$OK" -gt 0 ]; then
  RUNNABLE=$(awk -v t="$TOTAL" -v n="$OK" 'BEGIN { printf "%.2f", t / n }')
else
  RUNNABLE=NA
fi
# top 15: count desc, then name asc; share of all R counts, 1 decimal
LC_ALL=C sort "$TMP/names" | uniq -c | awk '{ print $1 "\t" $2 }' \
  | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -15 \
  | awk -F '\t' -v t="$TOTAL" '{ printf "%s\t%.1f\n", $2, $1 * 100 / t }' > "$TMP/top"

# ── 2. vmstat and forks per second ───────────────────────────────────────────
US=NA; SY=NA; ID=NA; WA=NA; ST=NA; CPU=NA
if command -v vmstat >/dev/null 2>&1; then
  vmstat 5 2 > "$TMP/vm" 2>/dev/null
  read -r US SY ID WA ST < <(awk '
    NR == 2 { for (k = 1; k <= NF; k++) col[$k] = k }
    NR > 2 && NF { for (k = 1; k <= NF; k++) v[k] = $k; nf = NF }
    END {
      split("us sy id wa st", want, " ")
      out = ""
      for (w = 1; w <= 5; w++) {
        c = col[want[w]]; x = (c && c <= nf) ? v[c] : ""
        out = out (x ~ /^[0-9]+$/ ? x : "NA") (w < 5 ? " " : "")
      }
      print out
    }' "$TMP/vm")
  : "${US:=NA}" "${SY:=NA}" "${ID:=NA}" "${WA:=NA}" "${ST:=NA}"
  CPU="us:$US,sy:$SY,id:$ID,wa:$WA"
fi

procs() { awk '$1 == "processes" && $2 ~ /^[0-9]+$/ { print $2; f = 1; exit } END { if (!f) exit 1 }' "$PSTAT" 2>/dev/null; }
FORKS=NA
if [ "$WINDOW" -gt 0 ] && P0=$(procs); then
  sleep "$WINDOW"
  if P1=$(procs) && [ "$P1" -ge "$P0" ]; then
    FORKS=$(awk -v d="$((P1 - P0))" -v w="$WINDOW" 'BEGIN { printf "%.1f", d / w }')
  fi
fi

# ── 3. tsv line ──────────────────────────────────────────────────────────────
DIR_HL="$H/state/hub-load"
mkdir -p "$DIR_HL" 2>/dev/null
TODAY=$(date -u -d "@$NOW" +%F)
LINE=$(printf '%s\trunnable=%s\tsteal=%s\tforks_s=%s\tcpu=%s\tsamples=%s/%s' \
  "$STAMP" "$RUNNABLE" "$ST" "$FORKS" "$CPU" "$OK" "$SAMPLES")
while IFS=$'\t' read -r n s; do
  [ -n "$n" ] && LINE="$LINE"$'\t'"$n=$s"
done < "$TMP/top"
printf '%s\n' "$LINE" >> "$DIR_HL/$TODAY.tsv"

# ── 4. ledger row ────────────────────────────────────────────────────────────
PUSH=not-loaded
if [ "$LOADED" = 1 ]; then
  BOX=$(_jobs_box_name 2>/dev/null)
  [[ "$BOX" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || BOX=hub
  HH=$(date -u -d "@$NOW" +%H); MM=$(date -u -d "@$NOW" +%M)
  KEY="$BOX:$HH:${MM:0:1}0"
  TOPJ=$(jq -Rn '[inputs | split("\t") | {n: .[0], share: (.[1] | tonumber)}]' < "$TMP/top")
  DETAIL=$(jq -nc --arg ts "$STAMP" --arg r "$RUNNABLE" --arg st "$ST" --arg f "$FORKS" \
    --arg us "$US" --arg sy "$SY" --arg id "$ID" --arg wa "$WA" --arg sm "$OK/$SAMPLES" \
    --argjson top "${TOPJ:-[]}" '
    def n: if . == "NA" then null else tonumber end;
    {ts: $ts, runnable: ($r|n), steal: ($st|n), forks_s: ($f|n), us: ($us|n),
     sy: ($sy|n), id: ($id|n), wa: ($wa|n), samples: $sm, top: $top}
    | until((tojson | length) <= 3900 or (.top | length) == 0; .top |= .[:-1])')
  export JOBS_STATUS_FILE="$TMP/status"
  if [ -n "$DETAIL" ] && job_ledger_put hub-load "$KEY" ok "$DETAIL" >/dev/null 2>&1; then
    PUSH=ok
  else
    case "$(cat "$TMP/status" 2>/dev/null)" in
      no-url|no-secret) PUSH=not-configured ;;
      *) PUSH=failed ;;
    esac
  fi
fi

# ── 5. retention by filename date ────────────────────────────────────────────
PRUNED=0
TODAY_S=$((NOW - NOW % 86400))
for f in "$DIR_HL"/????-??-??.tsv; do
  [ -f "$f" ] || continue
  d=${f##*/}; d=${d%.tsv}
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  ds=$(date -u -d "${d}T00:00:00Z" +%s 2>/dev/null) || continue
  [ "$(date -u -d "@$ds" +%F)" = "$d" ] || continue
  if [ $(((TODAY_S - ds) / 86400)) -gt "$KEEP" ]; then
    rm -f "$f" 2>/dev/null && [ ! -e "$f" ] && PRUNED=$((PRUNED + 1))
  fi
done

# ── 6. p90 alert, once per UTC hour ──────────────────────────────────────────
YDAY=$(date -u -d "@$((NOW - 86400))" +%F)
VALS=$(cat "$DIR_HL/$YDAY.tsv" "$DIR_HL/$TODAY.tsv" 2>/dev/null \
  | awk -F '\t' '{ for (k = 2; k <= NF; k++) if (index($k, "runnable=") == 1) { v = substr($k, 10); if (v ~ /^[0-9]+(\.[0-9]+)?$/) print v; break } }' \
  | tail -6)
NV=$(printf '%s' "$VALS" | grep -c .)
if [ "$NV" -lt 6 ]; then
  ALERT="insufficient($NV)"
else
  P90=$(printf '%s\n' "$VALS" | LC_ALL=C sort -g | awk '
    { v[NR - 1] = $1 }
    END { p = 0.9 * (NR - 1); lo = int(p); hi = (lo + 1 < NR) ? lo + 1 : lo
          x = v[lo] + (p - lo) * (v[hi] - v[lo]); s = sprintf("%.2f", x); sub(/\.?0+$/, "", s); print s }')
  if awk -v p="$P90" -v m="$MAXR" 'BEGIN { exit !(p > m) }'; then
    HOUR=$(date -u -d "@$NOW" +%Y-%m-%dT%H)
    if [ "$(cat "$DIR_HL/alert-hour" 2>/dev/null)" = "$HOUR" ]; then
      ALERT=latched
    else
      printf '%s\n' "$HOUR" > "$DIR_HL/alert-hour"
      TOP3=$(head -3 "$TMP/top" | awk -F '\t' '{ printf "%s%s %s%%", (NR > 1 ? ", " : ""), $1, $2 }')
      "$SELF/lane-alert.sh" --log-only hub-load-sample \
        "Hub runnable p90 $P90 over the last 6 runs is over hub_load.max_runnable $MAXR. Steal $ST. Top: ${TOP3:-none}." \
        >/dev/null 2>&1
      ALERT=written
    fi
  else
    ALERT=under
  fi
fi

summary "runnable=$RUNNABLE steal=$ST forks_s=$FORKS samples=$OK/$SAMPLES push=$PUSH pruned=$PRUNED alert=$ALERT keep_days=$KEEP($KEEP_SRC) max_runnable=$MAXR($MAXR_SRC)"
[ -x "$SELF/hub-load-baseline.sh" ] && "$SELF/hub-load-baseline.sh" >/dev/null 2>&1
exit 0
