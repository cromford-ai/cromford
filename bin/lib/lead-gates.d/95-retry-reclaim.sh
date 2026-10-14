#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/95-retry-reclaim.sh — gate 11 of
# bin/lead-review-enqueue.sh (BH-5779): the reclaim of stale running rows and
# the bounded retry of a failed lead review, ported to the worklist.
#
#   lg_tick_reclaim <slug>   ONCE a process (not once a repo): POST
#       /api/lead-reviews/reclaim-stale with the lead token (lr_post_lead). One
#       log line per reclaimed row (the enqueue's text, redacted), plus one when
#       the answer was truncated. No answer, or no token: one `reclaim-stale not
#       answered (...)` line. Always rc 0: nothing depends on it.
#   lg_gate_retry <slug> <n> <head>   the `failed` rung. The repo's failed rows
#       are read ONCE a process, and only when a head reaches this gate:
#       lr_list_all ?status=failed&repo=<slug>, filtered to status failed.
#       Page 1 unreadable = rc 11 for every head of that repo this process (one
#       log line). A partial read uses the rows it got (one log line): a failed
#       row it missed costs nothing, lr_start answers terminal on it.
#       No failed row for (pr, head)                       rc 0.
#       An environment failure (exactly checkout, no-checkout, empty, or a
#         `review-failed: env:` prefix) while bin/lead-review-land.sh requeues
#         them (its lane file registers LEAD_REVIEW_ENV_RETRY_MAX)
#                                                          `[skip env-failed]`, rc 10.
#       LEAD_REVIEW_FAILED_RETRY_MAX resets already made on the head (rows
#         `reset` in state/lead-review-enqueue/failed-retry.tsv, the enqueue's
#         ledger and format: <epoch>\t<slug>\t<n>\t<head>\t<id>\t<reset|alerted>\t<detail>)
#                                                          ONE lane-alert warn
#         lead-failed-<slug_>-<n>-<h12> (marker state/lead-review-enqueue/
#         alerted-<id>, written after rc 0, then an `alerted` row),
#         `[skip failed-exhausted]`, rc 10.
#       Otherwise POST /api/lead-reviews/<id>/reset. An answer with status
#         requested: a `reset` row, one log line, rc 0, and lr_start takes the
#         row. A 409 (a review in flight): `[skip reset-refused]`, rc 11. Any
#         other failure, no token included: one log line, rc 11. A failed
#         reset is never recorded as one.
# The ledger keeps 30 days; lg_tick_reclaim prunes it once a process (the
# enqueue, its other writer, runs on the hub, where this lane runs no tick).
# Sourced by bin/lib/lead-gates.sh, never run.

declare -g _LGR_RECLAIMED="" _LGR_PRUNED=""
declare -gA _lgr_list_rc=()

# _lgr_redact — URL credentials and GitHub tokens masked (the enqueue's redact).
_lgr_redact() { sed -E 's#://[^/@[:space:]]*@#://***@#g; s#gh[pousr]_[A-Za-z0-9]{20,}#gh*_***#g'; }

# _lgr_env_failure <detail> — the enqueue's lr_env_failure: the same `case` as
#   bin/lead-review-land.sh's lrl_env_failure, so the lanes never disagree.
_lgr_env_failure() {
  case "${1:-}" in
    checkout|no-checkout|empty|"review-failed: env:"*) return 0 ;;
  esac
  return 1
}

# _lgr_land_owns_env — the enqueue's lr_land_owns_env.
_lgr_land_owns_env() {
  grep -q '"LEAD_REVIEW_ENV_RETRY_MAX"' "${HARNESS:-${H:-}}/catalog/lanes.d/lead-review-land.json" 2>/dev/null
}

lg_tick_reclaim() {
  local d out rc=0 n why root="${HARNESS:-${H:-}}" f id repo pr head to beat
  [ -n "$_LGR_RECLAIMED" ] && return 0
  _LGR_RECLAIMED=1
  if [ -z "$_LGR_PRUNED" ] && [ -n "$root" ]; then
    _LGR_PRUNED=1
    f="$root/state/lead-review-enqueue/failed-retry.tsv"
    [ -f "$f" ] && awk -F'\t' -v c=$(( $(date +%s) - 2592000 )) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null \
      && mv -f "$f.tmp.$$" "$f"
  fi
  command -v lr_post_lead >/dev/null 2>&1 || { _lgt_log "reclaim-stale not answered (no lr_post_lead); stale running rows are not reclaimed this tick"; return 0; }
  d=$(lgs_dir 2>/dev/null) || d="${TMPDIR:-/tmp}"
  out=$(lr_post_lead /reclaim-stale '{}' 2>"$d/reclaim.err") || rc=$?
  if [ "$rc" = 0 ] && jq -e '(.reclaimed | type) == "array"' <<<"$out" >/dev/null 2>&1; then
    n=$(jq '.reclaimed | length' <<<"$out")
    while IFS=$'\t' read -r id repo pr head to beat; do
      _lgt_log "$repo#$pr @${head:0:12}: lead review $id ran with no heartbeat since $beat; reclaimed to $to (deadline $(jq -r '.deadline_s // "?"' <<<"$out") s)"
    done < <(jq -r '.reclaimed[] | [(.id // "?"), (.repo // "?"), (.pr // "?" | tostring), (.head_sha // ""), (.to // "?"), (.last_beat // "never")] | @tsv' <<<"$out" | _lgr_redact)
    [ "$(jq -r '.truncated == true' <<<"$out")" = true ] && _lgt_log "reclaim-stale reclaimed $n rows and was truncated; the next tick takes the rest"
  else
    why=$(tr '\n' ' ' < "$d/reclaim.err" 2>/dev/null | _lgr_redact | head -c 200); why="${why% }"
    _lgt_log "reclaim-stale not answered (${why:-unparseable answer}); stale running rows are not reclaimed this tick"
  fi
  rm -f "$d/reclaim.err"
  return 0
}

# _lgr_failed_list <slug> — the repo's failed rows, read once a process into
#   $(lgs_dir)/failed-<slug_>.json (an array). rc = the read's rc.
_lgr_failed_list() {
  local slug="$1" d safe f rc=0 stop
  d=$(lgs_dir 2>/dev/null) || return 1
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  f="$d/failed-$safe.json"; LGR_FAILED="$f"
  [ -n "${_lgr_list_rc[$slug]+x}" ] && return "${_lgr_list_rc[$slug]}"
  if ! command -v lr_list_all >/dev/null 2>&1; then
    rc=1; _lgt_log "failed lead reviews of $slug unreadable (no lr_list_all); its worklist heads are held this tick"
  elif ! lr_list_all "?status=failed&repo=$(jq -rn --arg s "$slug" '$s|@uri')" "${PAGES:-20}" > "$f.all" 2>/dev/null; then
    rc=1; _lgt_log "failed lead reviews of $slug unreadable (GET /api/lead-reviews?status=failed); its worklist heads are held this tick"
  else
    jq -c '[.requests[]? | select(.status == "failed")]' "$f.all" > "$f" 2>/dev/null || rc=1
    stop=$(jq -r '.stop // ""' "$f.all" 2>/dev/null)
    [ "$rc" = 0 ] || _lgt_log "failed lead reviews of $slug unparseable; its worklist heads are held this tick"
    [ "$rc" = 0 ] && [ -n "$stop" ] && _lgt_log "failed lead reviews of $slug read in part (stop=$stop); a failed row past it is not reset this tick"
  fi
  _lgr_list_rc[$slug]=$rc
  return "$rc"
}

lg_gate_retry() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" row id detail k safe st fretry text rrc rresp d
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  _lgr_failed_list "$slug" || return 11
  row=$(jq -c --arg r "$slug" --argjson n "$n" --arg h "$head" \
    '[.[] | select(.repo == $r and .pr == $n and ((.head_sha // "") | ascii_downcase) == $h)] | last // empty' "$LGR_FAILED" 2>/dev/null)
  [ -n "$row" ] || return 0
  [ -n "$root" ] || { _lgt_log "$slug#$n @$h12: a failed lead review and no harness root; held"; return 11; }
  st="$root/state/lead-review-enqueue"; fretry="$st/failed-retry.tsv"
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  id=$(jq -r '.id // empty | tostring' <<<"$row")
  detail=$(jq -j '(.detail // "no detail") | tostring | gsub("[\\n\\t]"; " ")' <<<"$row" 2>/dev/null | _lgr_redact | head -c 300)
  [ -n "$detail" ] || detail="no detail"
  if [ -z "$id" ]; then _lgt_log "$slug#$n @$h12: a failed lead review with no id; held"; return 11; fi
  if _lgr_env_failure "$detail" && _lgr_land_owns_env; then
    lgs_skip_once "$slug" "$n" "$head" env-failed \
      "lead review $id failed on the environment ($detail); bin/lead-review-land.sh requeues it (LEAD_REVIEW_ENV_RETRY_MAX)"
    return 10
  fi
  command -v lgk_load >/dev/null 2>&1 && lgk_load
  mkdir -p "$st" 2>/dev/null
  k=$(awk -F'\t' -v s="$slug" -v n="$n" -v h="$head" '$2 == s && $3 == n && tolower($4) == h && $6 == "reset"' "$fretry" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$k" -ge "${LGK_RETRYMAX:-2}" ]; then
    if [ ! -e "$st/alerted-lead-failed-$safe-$n-$h12" ]; then
      text="$slug#$n @$h12: the lead review request $id failed $((k + 1)) times on this head; last reason: $detail. Nothing is retried. Read the owning box's logs/lead-review.log, then review by hand: bin/lead-verdict.sh post $slug $n $head <VERDICT>"
      if "$root/bin/lane-alert.sh" --severity warn --id "lead-failed-$safe-$n-$h12" lead-review "$text" >/dev/null 2>&1; then
        : > "$st/alerted-lead-failed-$safe-$n-$h12" 2>/dev/null || _lgt_log "alerted lead-failed-$safe-$n-$h12 but could not write its marker; this may alert again"
        printf '%s\t%s\t%s\t%s\t%s\talerted\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" "${detail:0:200}" >> "$fretry"
      else
        _lgt_log "lane-alert.sh failed for lead-failed-$safe-$n-$h12; the next tick retries"
      fi
    fi
    lgs_skip_once "$slug" "$n" "$head" failed-exhausted \
      "lead review $id failed ($detail); $k resets used of ${LGK_RETRYMAX:-2}, not retried"
    return 10
  fi
  if ! command -v lr_post_lead >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: lead review $id failed and no lr_post_lead to reset it; held"; return 11
  fi
  d=$(lgs_dir 2>/dev/null) || d="${TMPDIR:-/tmp}"
  rrc=0; rresp=$(lr_post_lead "/$id/reset" '{}' 2>"$d/reset.err") || rrc=$?
  if [ "$rrc" = 0 ] && [ "$(jq -r '.request.status // empty' <<<"$rresp" 2>/dev/null)" = requested ]; then
    printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" "${detail:0:200}" >> "$fretry"
    _lgt_log "$slug#$n @$h12: lead review $id failed ($detail); reset $((k + 1))/${LGK_RETRYMAX:-2} for a new review"
    rm -f "$d/reset.err"
    return 0
  fi
  if grep -q 'HTTP 409' "$d/reset.err" 2>/dev/null; then
    lgs_skip_once "$slug" "$n" "$head" reset-refused \
      "reset of $id refused (a review is in flight): $(printf '%s' "$rresp" | tr '\n' ' ' | _lgr_redact | head -c 200)"
  else
    _lgt_log "$slug#$n @$h12: reset of $id failed ($(tr '\n' ' ' < "$d/reset.err" 2>/dev/null | _lgr_redact | head -c 200)); held, the next tick retries"
  fi
  rm -f "$d/reset.err"
  return 11
}
