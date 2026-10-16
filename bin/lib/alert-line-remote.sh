#!/bin/bash
# bin/lib/alert-line-remote.sh — alert lines through the jobs API (BH-6889,
# BH-6881.5). Defines functions only. Contract:
# docs/notes/2026-10-16-BH-6889-mc-manifest-alert-lines.md.
#
# A lane-run machine has no logs/ALERTS.log that anyone reads. With LANE_RUN_ID
# set, bin/alert-line.sh calls alr_post, which posts the line to
# POST /api/alert-lines (worker/jobs/src/routes/alert-lines.js). The hub's
# bin/lane-snapshot-publish.sh calls alr_apply once per tick, which replays
# each unapplied line through the hub's bin/alert-line.sh and marks it applied.
#
#   alr_post <line> <severity> <alertid> [project]
#       lane ${PL_LANE:-unknown}, project <project> or $PL_PROJECT, stamp
#       $ALR_STAMP, run $LANE_RUN_ID. rc 0 only when the worker answered 2xx
#       with a numeric id; rc 1 on any other answer (the caller then takes its
#       local path).
#   alr_apply
#       Prints ONE line and returns rc 0 or 1:
#         alert lines: <r> replayed, <s> already applied, ack <ok|failed|none>[, more]
#         alert lines: skipped (busy)                rc 0 (locks/alert-lines-apply.lock held)
#         alert lines: off (not configured)          rc 0, no request (JOBS_URL or HARNESS_SECRET empty)
#         alert lines: read failed                   rc 1, nothing replayed
#       A row whose marker state/alert-lines-applied/<dedup_key> exists is not
#       replayed again; it is acked again. The order per tick is replay
#       (alert-line.sh appends) -> marker -> one ack for every replayed or
#       marked id, so a failed ack never repeats a line. "ack failed" is rc 1.
#       ", more" means the worker holds more unapplied rows than
#       alert_lines.apply_max (settings row, 1..500, default 200).
#       The replay is `env -u LANE_RUN_ID ALERT_LINE_STAMP=<stamp>
#       bin/alert-line.sh [--severity s] [--id k] --project p <text>`, so the
#       hub line is byte-identical to the machine's and is never posted back.
#       Markers older than the larger retention window + 1 day are deleted.
#
# The root is ${HARNESS:-${H:-}}; with no root every function returns 1.

# _alr_root — the harness root, or rc 1.
_alr_root() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 1; printf '%s' "$r"; }

# _alr_client — rc 0 when _jobs_req and setting_get exist. Sources
# bin/jobs-client.sh when they do not, and restores nounset and pipefail,
# which the client switches on (the lib/lane-run-inputs.sh _lri_client pattern).
_alr_client() {
  local root pf nu=0
  command -v _jobs_req >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1 && return 0
  root=$(_alr_root) || return 1
  [ -r "$root/bin/jobs-client.sh" ] || return 1
  case $- in *u*) nu=1 ;; esac
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  [ "$nu" = 0 ] && set +u
  command -v _jobs_req >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1
}

alr_post() {
  local line="${1:-}" sev="${2:-}" aid="${3:-}" proj="${4:-${PL_PROJECT:-}}" body out
  [ -n "$line" ] && [ -n "${LANE_RUN_ID:-}" ] || return 1
  _alr_client || return 1
  body=$(jq -nc --arg lane "${PL_LANE:-unknown}" --arg p "$proj" --arg l "$line" --arg st "${ALR_STAMP:-}" \
    --arg s "$sev" --arg id "$aid" --arg r "$LANE_RUN_ID" \
    '{lane:$lane,project:$p,line:$l,run_id:$r}
     + (if $st != "" then {stamp:$st} else {} end)
     + (if $s != "" then {severity:$s} else {} end)
     + (if $id != "" then {alertid:$id} else {} end)' 2>/dev/null) || return 1
  out=$(_jobs_req POST /api/alert-lines "$body") || return 1
  jq -e '.id | numbers' <<<"$out" >/dev/null 2>&1
}

# _alr_int <key> <default> <max> — a settings row in 1..max, else the default.
_alr_int() {
  local v; v=$(setting_get "$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  { [ "$v" -ge 1 ] && [ "$v" -le "$3" ]; } 2>/dev/null || v="$2"
  printf '%s' "$v"
}

alr_apply() {
  local root fd rc
  root=$(_alr_root) || { echo "alert lines: off (no root)"; return 1; }
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || { echo "alert lines: off (not configured)"; return 0; }
  _alr_client || { echo "alert lines: off (no jobs client)"; return 1; }
  mkdir -p "$root/locks" 2>/dev/null
  exec {fd}>>"$root/locks/alert-lines-apply.lock" || { echo "alert lines: lock unwritable"; return 1; }
  if ! flock -n "$fd"; then exec {fd}>&-; echo "alert lines: skipped (busy)"; return 0; fi
  _alr_apply_locked "$root"; rc=$?
  exec {fd}>&-
  return "$rc"
}

_alr_apply_locked() {
  local root="$1" max keep out mk r=0 s=0 ids=() row id key stamp sev aid proj line text more="" ack args
  max=$(_alr_int alert_lines.apply_max 200 500)
  keep=$(_alr_int retention.alert_lines.applied_days 7 3650)
  r=$(_alr_int retention.alert_lines.unapplied_days 30 3650); [ "$r" -gt "$keep" ] && keep=$r; r=0
  mk="$root/state/alert-lines-applied"
  mkdir -p "$mk" 2>/dev/null
  find "$mk" -type f -mtime +"$((keep + 1))" -delete 2>/dev/null
  out=$(_jobs_req GET "/api/alert-lines?unapplied=1&limit=$max") \
    && jq -e '.lines | arrays' <<<"$out" >/dev/null 2>&1 || { echo "alert lines: read failed"; return 1; }
  [ "$(jq -r '.truncated' <<<"$out")" = true ] && more=", more"
  while IFS= read -r row; do
    id=$(jq -r '.id' <<<"$row"); key=$(jq -r '.dedup_key // ""' <<<"$row")
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [[ $key =~ ^[0-9a-f]{64}$ ]] || continue
    if [ -e "$mk/$key" ]; then s=$((s + 1)); ids+=("$id"); continue; fi
    stamp=$(jq -r '.stamp // ""' <<<"$row"); sev=$(jq -r '.severity // ""' <<<"$row")
    aid=$(jq -r '.alertid // ""' <<<"$row"); proj=$(jq -r '.project // ""' <<<"$row")
    line=$(jq -r '.line' <<<"$row")
    text="$line"; [ -n "$stamp" ] && [ "${line#"$stamp "}" != "$line" ] && text="${line#"$stamp "}"
    args=(); [ -n "$sev" ] && args+=(--severity "$sev"); [ -n "$aid" ] && args+=(--id "$aid")
    env -u LANE_RUN_ID HARNESS="$root" ALERT_LINE_STAMP="$stamp" "$root/bin/alert-line.sh" \
      "${args[@]}" --project "$proj" "$text" >/dev/null 2>&1
    touch "$mk/$key" 2>/dev/null
    r=$((r + 1)); ids+=("$id")
  done < <(jq -c '.lines[]' <<<"$out")
  ack=none
  if [ "${#ids[@]}" -gt 0 ]; then
    out=$(_jobs_req POST /api/alert-lines/applied "$(printf '%s\n' "${ids[@]}" | jq -sc '{ids: .}')") \
      && jq -e '.applied | numbers' <<<"$out" >/dev/null 2>&1 && ack=ok || ack=failed
  fi
  echo "alert lines: $r replayed, $s already applied, ack $ack$more"
  [ "$ack" != failed ]
}
