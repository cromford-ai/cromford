#!/bin/bash
# bin/ci-plan-settings.sh [owner/repo] [--dry-run] — hourly projection of the
# settings row CI_FULL_TRIGGERS into the repo Actions variable of the same name
# (BH-6838). bin/ci-plan.sh reads the variable as the full-trigger delta over
# catalog/ci-batch-escalate.tsv (grammar: bin/lib/ci-batch-escalate.sh). It
# projects the shard sizing rows CI_MAX_SHARDS and CI_SHARD_BUDGET_S the same
# way (BH-6876), which bin/ci-plan.sh reads as its cap and per-shard budget.
#
# One tick:
#   1 value       CI_FULL_TRIGGERS from the settings row (lane_env_apply), cut
#                 to the kept tokens by cbe_delta_norm, the same parser the
#                 reader uses. Empty = `-` (GitHub refuses an empty variable;
#                 the reader treats `-` as no delta). A row over 256 chars is
#                 refused: nothing is read or written.
#   2 projection  GET repos/<slug>/actions/variables/CI_FULL_TRIGGERS with the
#                 admin token. Same value = no write (`same`). 404 = POST,
#                 differs = PATCH (`set`).
#   3 alert       no admin token, a refused value or a failed call = one warn
#                 alert ci-plan-settings-projection:<slug>; CI keeps the old
#                 variable. A good tick resolves it.
#   4 sizing      BH-6876. Per name, CI_MAX_SHARDS (1..64) then
#                 CI_SHARD_BUDGET_S (60..3600), the registry's ranges: an
#                 empty env is `unset` (no call); a value that is not a whole
#                 number in range is `refused` (no call); else GET, and `same`,
#                 or POST (404) / PATCH (differs) and `set`; a failed call is
#                 `failed`. A refused or failed name is one warn alert
#                 ci-plan-settings-sizing:<slug>; both configured and
#                 same/set resolves it; anything else sends no alert call.
#   4b prepush    BH-7289. CI_ALWAYS_PREPUSH_SKIP (0..1), which bin/ci-plan.sh
#                 reads as the switch of the batch's prepush drop (unset = 1).
#                 Same rules as one sizing name: `unset` (no call), `refused`,
#                 `same`, `set`, `failed`. A refused or failed value is one warn
#                 alert ci-plan-settings-prepush:<slug>; same/set resolves it.
#   5 one tick line in logs/ci-plan-settings.log, ending in
#                 ` prepush=<r> sizing=CI_MAX_SHARDS:<r>,CI_SHARD_BUDGET_S:<r>`.
#
# --dry-run: prints `would: <POST|PATCH> <NAME>=<value>` and writes
# nothing (no variable, alert or log line other than the tick line). Exit 0 on
# every path. Knobs: catalog/lanes.d/ci-plan-settings.json.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

case "${1:-}" in -h|--help) sed -n '2,39p' "$0"; exit 0 ;; esac
# >>> lane gate (BH-1165): flags/lane-off-ci-plan-settings or all-off exits 0;
# the settings rows land in the env the knob read below uses. Both fail OPEN.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-plan-settings
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    ci-plan-settings
export HARNESS="$H"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# Again below the env load: global.env re-assigns the names it carries (BH-1165).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    ci-plan-settings

TARGET=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in --dry-run|-n) DRY=1 ;; *) [ -n "$TARGET" ] || TARGET="$1" ;; esac
  shift
done
# shellcheck source=bin/lib/deployment.sh
# BH-4080: the repo default is HARNESS_REPO from the deployment defaults home.
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 2
case "$TARGET" in */*) SLUG="$TARGET" ;; *) SLUG="$HARNESS_REPO" ;; esac

mkdir -p "$H/locks" "$H/logs" 2>/dev/null
exec 9>"$H/locks/ci-plan-settings.lock" || exit 0
flock -n 9 || exit 0

LOG="$H/logs/ci-plan-settings.log"
ID="ci-plan-settings-projection:$SLUG"
RAW="${CI_FULL_TRIGGERS:-}"; WANT="?"; PROJ=failed; why=""; note=""; SIZ=""; PPR=""

_cps_alert() {   # _cps_alert <lane-alert opts…> <text>
  if [ "$DRY" = 1 ]; then echo "would: alert ${*:1:$#-1}: ${!#}"; return 0; fi
  "$H/bin/lane-alert.sh" "${@:1:$#-1}" ci-plan-settings "${!#}" > /dev/null 2>&1 || true
}
_cps_tick() {
  printf '%s ci-plan-settings %s: value=%s projection=%s%s%s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$SLUG" "$WANT" "$PROJ" "${why:+ ($why)}${note:+ [$note]}" \
    "$([ "$DRY" = 1 ] && echo ' [dry-run]')${PPR:+ prepush=$PPR}${SIZ:+ sizing=$SIZ}" | tee -a "$LOG"
}
trap _cps_tick EXIT

# ── 1. the value ─────────────────────────────────────────────────────────────
# shellcheck source=bin/lib/ci-batch-escalate.sh
if [ "${#RAW}" -gt 256 ]; then
  PROJ=refused; why="CI_FULL_TRIGGERS is ${#RAW} chars, over the 256 cap"
elif ! . "$H/bin/lib/ci-batch-escalate.sh" 2>/dev/null || ! command -v cbe_delta_norm >/dev/null 2>&1; then
  why="cannot load bin/lib/ci-batch-escalate.sh"
else
  WANT=$(cbe_delta_norm "$RAW" 2>/dev/null)
  DROPS=$(cbe_delta_norm "$RAW" 2>&1 >/dev/null)   # one line per dropped token
  [ -n "$DROPS" ] && { printf '%s\n' "$DROPS" >&2; note="dropped $(printf '%s\n' "$DROPS" | grep -c .) token(s)"; }
fi

# ── 2. the projection ────────────────────────────────────────────────────────
ADM="${GH_ADMIN_TOKEN:-}"
[ -n "$ADM" ] || ADM=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$HENV/github-admin.env" 2>/dev/null | tr -d "\"'" | head -n 1)
if [ "$PROJ" != refused ] && [ "$WANT" != "?" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  if [ -z "$ADM" ]; then why="no admin token"
  elif ! . "$H/bin/lib/gh-rest.sh" 2>/dev/null || ! command -v gh_rest_var >/dev/null 2>&1; then
    why="cannot load bin/lib/gh-rest.sh"
  else
    V="repos/$SLUG/actions/variables"; rc=0; CUR=""
    GH_ETAG=0 GH_TOKEN="$ADM" gh_rest_var CUR GET "$V/CI_FULL_TRIGGERS" || rc=$?
    if [ "$rc" = 0 ] && [ "$(printf '%s' "$CUR" | jq -r '.value // empty' 2>/dev/null)" = "$WANT" ]; then PROJ=same
    elif [ "$rc" = 0 ] || [ "$rc" = 44 ]; then
      if [ "$rc" = 44 ]; then m=POST; p="$V"; a=(-f name=CI_FULL_TRIGGERS); else m=PATCH; p="$V/CI_FULL_TRIGGERS"; a=(); fi
      if [ "$DRY" = 1 ]; then echo "would: $m CI_FULL_TRIGGERS=$WANT"; PROJ="would-$m"
      elif GH_ETAG=0 GH_TOKEN="$ADM" gh_rest "$m" "$p" ${a[@]+"${a[@]}"} -f "value=$WANT" > /dev/null; then PROJ="set"
      else why="variable $m HTTP ${GH_REST_STATUS:-000}"; fi
    else why="variable read HTTP ${GH_REST_STATUS:-000}"; fi
  fi
fi

# ── 2b. the sizing knobs (BH-6876) ──────────────────────────────────────────
# _cps_size <name> <value> — project one value; sets R to same|set|would-<M>|failed
# and appends the reason of a failure to SWHY.
_cps_size() {
  local nm="$1" v="$2" rc=0 cur m p a=()
  R=failed
  [ -n "$ADM" ] || { SWHY="$SWHY${SWHY:+; }no admin token"; return; }
  # shellcheck source=bin/lib/gh-rest.sh
  { . "$H/bin/lib/gh-rest.sh" && command -v gh_rest_var; } > /dev/null 2>&1 \
    || { SWHY="$SWHY${SWHY:+; }cannot load bin/lib/gh-rest.sh"; return; }
  GH_ETAG=0 GH_TOKEN="$ADM" gh_rest_var cur GET "repos/$SLUG/actions/variables/$nm" || rc=$?
  if [ "$rc" = 0 ] && [ "$(printf '%s' "$cur" | jq -r '.value // empty' 2>/dev/null)" = "$v" ]; then R=same; return; fi
  [ "$rc" = 0 ] || [ "$rc" = 44 ] || { SWHY="$SWHY${SWHY:+; }$nm read HTTP ${GH_REST_STATUS:-000}"; return; }
  if [ "$rc" = 44 ]; then m=POST; p="repos/$SLUG/actions/variables"; a=(-f "name=$nm"); else m=PATCH; p="repos/$SLUG/actions/variables/$nm"; fi
  if [ "$DRY" = 1 ]; then echo "would: $m $nm=$v"; R="would-$m"; return; fi
  if GH_ETAG=0 GH_TOKEN="$ADM" gh_rest "$m" "$p" ${a[@]+"${a[@]}"} -f "value=$v" > /dev/null; then R=set
  else SWHY="$SWHY${SWHY:+; }$nm $m HTTP ${GH_REST_STATUS:-000}"; fi
}
SID="ci-plan-settings-sizing:$SLUG"; SWHY=""; SGOOD=0
for spec in CI_MAX_SHARDS:1:64 CI_SHARD_BUDGET_S:60:3600; do
  IFS=: read -r nm lo hi <<<"$spec"; v="${!nm:-}"
  if [ -z "$v" ]; then R=unset
  elif ! [[ $v =~ ^[0-9]{1,6}$ ]] || [ "$((10#$v))" -lt "$lo" ] || [ "$((10#$v))" -gt "$hi" ]; then
    R=refused; SWHY="$SWHY${SWHY:+; }$nm='${v:0:40}' is not a whole number in $lo..$hi"
  else
    _cps_size "$nm" "$((10#$v))"
    case "$R" in same|set|would-*) SGOOD=$((SGOOD + 1)) ;; esac
  fi
  SIZ="$SIZ${SIZ:+,}$nm:$R"
done
if [ -n "$SWHY" ]; then
  _cps_alert --id "$SID" --severity warn \
    "ci-plan-settings $SLUG: shard sizing not projected ($SWHY); CI keeps the old variables, retry next tick"
elif [ "$SGOOD" = 2 ]; then
  _cps_alert --resolve --id "$SID" "ci-plan-settings $SLUG: shard sizing projected again"
fi

# ── 2c. the prepush switch (BH-7289) ────────────────────────────────────────
PID="ci-plan-settings-prepush:$SLUG"; SWHY=""; v="${CI_ALWAYS_PREPUSH_SKIP:-}"
if [ -z "$v" ]; then PPR=unset
elif ! [[ $v =~ ^[01]$ ]]; then
  PPR=refused; SWHY="CI_ALWAYS_PREPUSH_SKIP='${v:0:40}' is not 0 or 1"
else
  _cps_size CI_ALWAYS_PREPUSH_SKIP "$v"; PPR="$R"
fi
if [ -n "$SWHY" ]; then
  _cps_alert --id "$PID" --severity warn \
    "ci-plan-settings $SLUG: CI_ALWAYS_PREPUSH_SKIP not projected ($SWHY); CI keeps the old variable, retry next tick"
else
  case "$PPR" in same|set|would-*)
    _cps_alert --resolve --id "$PID" "ci-plan-settings $SLUG: CI_ALWAYS_PREPUSH_SKIP projected again" ;; esac
fi

# ── 3. the alert ─────────────────────────────────────────────────────────────
case "$PROJ" in
  same|set|would-*)
    _cps_alert --resolve --id "$ID" "ci-plan-settings $SLUG: CI_FULL_TRIGGERS projected again" ;;
  *)
    _cps_alert --id "$ID" --severity warn \
      "ci-plan-settings $SLUG: CI_FULL_TRIGGERS not projected ($why); CI keeps the old variable, retry next tick" ;;
esac
exit 0
