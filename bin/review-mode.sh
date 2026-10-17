#!/bin/bash
# bin/review-mode.sh — THE review strictness dial (BH-7123 wave B).
#
#   bin/review-mode.sh <project|fleet> <strict|shadow|levels|cowboy|off> [--for <Nm|Nh|Nd|forever>] [--why "<text>"]
#   bin/review-mode.sh show [project|fleet]
#
# One row per project (review.mode.<project>) or for the fleet (review.mode),
# plus its expiry (review.mode_until[.<project>], an ISO-8601 UTC time, or
# `never`), written through setting_set so every flip is a config_changes
# audit row. The readers are rl_mode / rl_cap (bin/lib/review-level.sh) on the
# next review: no deploy, no restart. The modes
# (worker/jobs/schema.d/202610161500-bh-7123-review-levels.sql):
#   strict  every model BLOCK stands        shadow  compute, log, change nothing
#   levels  the default: ALWAYS-BLOCK floor only, everything else a NOTE
#   cowboy  levels + no fix rounds + no follow-ups; the floor never comes off
#   off     no review verdict gates a merge; green CI merges
# TIME-BOXED BY DEFAULT: cowboy and off expire after 6h unless --for says
# otherwise; bin/review-mode-expire.sh (hub, every 15 min) flips an expired
# row back to levels and announces it. levels, strict and shadow carry no
# expiry unless --for is given. `--for forever` means it.
# `never` and not an empty string for "no expiry": PUT /api/settings refuses an
# empty value, and a stale until row must be CLEARED, not left to fire.
# A refused call (unknown mode, project or --for) writes and announces nothing.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

MODES='strict|shadow|levels|cowboy|off'
usage() {
  cat >&2 <<EOF
usage: bin/review-mode.sh <project|fleet> <${MODES}> [--for <Nm|Nh|Nd|forever>] [--why "<text>"]
       bin/review-mode.sh show [project|fleet]
  cowboy and off default to --for 6h; levels, strict and shadow to no expiry.
  Projects are the fleet.conf registry (bin/fleet-conf.sh --projects).
EOF
  exit 2
}
die() { echo "review-mode: $*" >&2; exit "${RC_DIE:-2}"; }

[ $# -ge 1 ] || usage
[ -r "$H/bin/jobs-client.sh" ] || { RC_DIE=1 die "bin/jobs-client.sh is missing; nothing written"; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || { RC_DIE=1 die "bin/jobs-client.sh did not load; nothing written"; }
command -v jq >/dev/null 2>&1 || { RC_DIE=1 die "jq is required"; }

projects() {
  local fc
  for fc in "$H/bin/fleet-conf.sh" "$(dirname "$0")/fleet-conf.sh"; do
    [ -x "$fc" ] || continue
    "$fc" --projects 2>/dev/null; return $?
  done
  return 1
}
project_ok() { # project_ok <name> — fleet, or a fleet.conf project
  local p="$1" list
  [ "$p" = fleet ] && return 0
  [[ "$p" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || return 1
  list=$(projects) || { echo "review-mode: the project registry (fleet.conf) could not be read; refusing to guess '$p'" >&2; return 1; }
  grep -qx -- "$p" <<<"$list"
}
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
keys_for() { # keys_for <project|fleet> -> MK UK
  if [ "$1" = fleet ]; then MK=review.mode; UK=review.mode_until; else MK="review.mode.$1"; UK="review.mode_until.$1"; fi
}

# ── show ─────────────────────────────────────────────────────────────────────
if [ "$1" = show ]; then
  FILTER="${2:-}"
  [ -z "$FILTER" ] || project_ok "$FILTER" || die "unknown project '$FILTER'"
  RESP=$(_jobs_req GET /api/settings) || { RC_DIE=1 die "settings unreadable (http ${JOBS_HTTP:-none})"; }
  # knob, project, value, expiry — the until rows are folded onto their mode row.
  printf '%s' "$RESP" | jq -r --arg f "$FILTER" '
    (.settings // []) | map(select(.key | startswith("review.")))
    | map(. + {m: ((.key | capture("^review\\.(?<knob>mode_until|mode|perf_block_ms|perf_block_stmt_pct|fix_rounds_max|followup_min_level|followup_chain|golive_gates_merge|core_flows)(\\.(?<p>.+))?$")?) // {knob: (.key | sub("^review\\."; "")), p: null})})
    | map(. + {p: (.m.p // "fleet"), knob: .m.knob})
    | (map(select(.knob == "mode_until")) | map({key: .p, value: .value}) | from_entries) as $until
    | map(select(.knob != "mode_until"))
    | map(select($f == "" or .p == $f))
    | sort_by(.knob, .p)
    | (["KEY", "PROJECT", "VALUE", "EXPIRY"] | @tsv),
      (.[] | [.key, .p, .value, (if .knob == "mode" then ($until[.p] // "-") else "-" end)] | @tsv)' \
    | awk -F'\t' '{ printf "%-36s %-18s %-10s %s\n", $1, $2, $3, $4 }'
  exit 0
fi

# ── set ──────────────────────────────────────────────────────────────────────
[ $# -ge 2 ] || usage
TARGET="$1"; MODE="$2"; shift 2
FOR=""; WHY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --for) FOR="${2:-}"; shift 2 ;;
    --why) WHY="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$MODE" =~ ^($MODES)$ ]] || die "unknown mode '$MODE' (one of ${MODES//|/, })"
project_ok "$TARGET" || die "unknown project '$TARGET' (fleet, or a project in fleet.conf)"
if [ -z "$FOR" ]; then
  case "$MODE" in cowboy|off) FOR=6h ;; *) FOR=forever ;; esac
fi
UNTIL=never
if [ "$FOR" != forever ]; then
  [[ "$FOR" =~ ^([0-9]{1,5})([mhd])$ ]] || die "--for wants <N>m, <N>h, <N>d or forever, got '$FOR'"
  N="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in m) SECS=$((N * 60)) ;; h) SECS=$((N * 3600)) ;; d) SECS=$((N * 86400)) ;; esac
  [ "$SECS" -gt 0 ] || die "--for must be more than 0"
  UNTIL=$(iso_at $(( $(date -u +%s) + SECS )))
fi
keys_for "$TARGET"
WHO="${USER:-${LOGNAME:-$(id -un 2>/dev/null)}}@$(hostname -s 2>/dev/null || hostname)"
NOTE="BH-7123 review-mode: $WHO${WHY:+ $WHY}"
NOTE="${NOTE:0:200}"

setting_set "$MK" "$MODE" "$NOTE" || { RC_DIE=1 die "could not write $MK=$MODE (http ${JOBS_HTTP:-none}); nothing announced"; }
if ! setting_set "$UK" "$UNTIL" "$NOTE"; then
  echo "review-mode: wrote $MK=$MODE but could not write $UK=$UNTIL (http ${JOBS_HTTP:-none}); set it by hand: bin/jobs-client.sh setting-set $UK $UNTIL" >&2
  exit 1
fi
EXP="until $UNTIL"; [ "$UNTIL" = never ] && EXP="no expiry"
printf '%s=%s\n%s=%s\n' "$MK" "$MODE" "$UK" "$UNTIL"
printf 'review mode for %s: %s (%s)%s\n' "$TARGET" "$MODE" "$EXP" "${WHY:+ — $WHY}"
LINE="[review-mode] $TARGET: review.mode -> $MODE ($EXP) by $WHO${WHY:+ ($WHY)}. Readers pick it up on the next review; bin/review-mode-expire.sh flips an expired row back to levels."
if [ -x "$H/bin/alert-line.sh" ]; then
  HARNESS="$H" "$H/bin/alert-line.sh" --severity info --id "review-mode-$TARGET" ${TARGET:+--project "$TARGET"} "$LINE" >/dev/null 2>&1 || true
fi
exit 0
