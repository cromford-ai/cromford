#!/bin/bash
# shellcheck shell=bash
# module: cap after: record
# bin/lib/br/cap.sh — BH-7123 wave B: the review fix-round CAP layer of the
# blocked-resolver: the per-project registry knobs (br_env_for_project), the
# ALWAYS-BLOCK floor read over the standing reviews (br_floor_stands) and the
# at-cap terminal that merges with notes instead of abandoning (br_cap_notes).
# Sourced by bin/blocked-resolver.sh after record.sh, never run. Reads $H, $ST
# and the say/br_* helpers at CALL time; nothing at source time. Moved here
# from the driver so tests/br/driver-ceiling.tsv keeps falling (BH-5241).

# THE PER-PROJECT ROWS, PER PROJECT (BH-7123 wave B). The line above reads the
# FLEET rows (lane.blocked-resolver.<knob>) once, with no project, so a project
# row (lane.blocked-resolver.<project>.<knob>, e.g. br_review_fix_rounds) was
# never read: a tick walks many projects, and lane_env_apply exports into one
# environment. br_env_for_project <p> is called by the candidate loop as the
# row's project changes (and by the --fix-here entry for its project): it puts
# every registry knob back to the fleet value read above, applies the project's
# rows, then re-derives the bare aliases the rungs read (MAX_FIXROUNDS and its
# kin, assigned from BR_* at startup), so a row for p1 is never p2's cap. The
# tick-budget knobs stay fleet-wide whatever a project row says: a budget is
# the TICK's, not a project's (BR_PER_TICK, BR_REBUILDS_PER_TICK,
# BR_TICK_MAX_SECS), and the module switch, the dispatch spread, the PR-list
# cache and the LLM lane caps are read at startup for the whole run.
_BR_ENV_FLEET=""; _BR_ENV_LAST=""
br_env_for_project() {
  local p="${1:-}" e v line reg
  # The fleet-wide set lives here, not in a global, so a suite that lifts this
  # function alone (tests/br-fix-cap-row.bh-7123-test.sh) runs it under set -u.
  local fleetwide=" BR_PER_TICK BR_REBUILDS_PER_TICK BR_TICK_MAX_SECS BR_OPT_OFF BR_DISPATCH_SPREAD_SECS BR_PRS_CACHE_SECS BR_STARVE_ALERT_SECS BR_UNTOUCHED_ALERT_MIN LLM_USD_CAP_DAY LLM_LANE_ENABLED LLM_RUNNER_ALLOWED "
  case "$p" in ''|-) p="" ;; esac
  [ "$p" = "${_BR_ENV_LAST:-}" ] && [ -n "${_BR_ENV_FLEET:-}" ] && return 0
  command -v lane_env_apply >/dev/null 2>&1 || return 0
  reg="$H/catalog/lanes.d/blocked-resolver.json"
  [ -r "$reg" ] && command -v jq >/dev/null 2>&1 || return 0
  if [ -z "${_BR_ENV_FLEET:-}" ]; then
    # The snapshot: every registry knob's value after the fleet apply above,
    # `NAME=value` or `NAME` (unset) one per line, taken once per run.
    _BR_ENV_FLEET=$(while IFS= read -r e; do
      case "$e" in ''|*[!A-Z0-9_]*|[0-9]*) continue ;; esac
      if [ -n "${!e+x}" ]; then printf '%s=%s\n' "$e" "${!e}"; else printf '%s\n' "$e"; fi
    done < <(jq -r '.knobs[]? | .env // empty' "$reg" 2>/dev/null))
    [ -n "$_BR_ENV_FLEET" ] || _BR_ENV_FLEET=" "
  fi
  # 1. back to the fleet values, 2. this project's rows, 3. the fleet-wide set
  #    again, so a project row for a tick budget is read and then overruled.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    e="${line%%=*}"
    case "$line" in *=*) export "$e=${line#*=}" ;; *) unset "$e" ;; esac
  done <<<"$_BR_ENV_FLEET"
  [ -n "$p" ] && lane_env_apply blocked-resolver "$p"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    e="${line%%=*}"
    case "$fleetwide" in *" $e "*) ;; *) continue ;; esac
    case "$line" in *=*) export "$e=${line#*=}" ;; *) unset "$e" ;; esac
  done <<<"$_BR_ENV_FLEET"
  # The bare aliases the rungs read, re-derived exactly as the startup block
  # assigns them (search `MAX_FIXROUNDS=` below), so a per-project cap reaches
  # br_fix_cap and br_rebuild_cap without a second spelling of the default.
  MAX_REBUILDS="${BR_MAX_REBUILDS:-3}"
  MAX_MECHANICAL="${BR_MAX_MECHANICAL:-1}"
  MAX_FIXROUNDS="${BR_MAX_FIXROUNDS:-1}"
  MAX_FIXROUNDS_SMALL="${BR_CONFLICT_FIX_ROUNDS:-${BR_MAX_FIXROUNDS_SMALL:-2}}"
  MAX_REBUILDS_SMALL="${BR_MAX_REBUILDS_SMALL:-1}"
  SMALL_CONFLICT_LINES="${RESOLVER_SMALL_CONFLICT_LINES:-300}"
  CI_LOG_BYTES="${BR_CI_LOG_BYTES:-6000}"
  CI_LOG_RUNS="${BR_CI_LOG_RUNS:-3}"
  FIX_LANE_TIMEOUT="${BR_FIX_LANE_TIMEOUT:-5400}"
  FIX_HOP_MARGIN="${BR_FIX_HOP_MARGIN:-300}"
  FIX_AGENT_TIMEOUT="${BR_FIX_AGENT_TIMEOUT:-3600}"
  ADJ_TIMEOUT="${BR_ADJ_TIMEOUT:-1200}"
  # The review cap memo (bin/lib/br/record.sh br_review_fix_cap) is keyed on
  # the project, so nothing to clear here.
  _BR_ENV_LAST="$p"
  [ -n "$p" ] && say "$p: lane env applied for the project (registry rows lane.blocked-resolver.$p.*; tick budgets stay fleet-wide)"
  return 0
}


# br_floor_stands <bodies-file> — rc 0 when a finding line in the standing
#   review bodies stands under rl_line_blocks (an ALWAYS-BLOCK class tag or a
#   catalog ERE: a tenant leak the model called [LOW] still counts). Finding
#   lines are the RL_FIND_RE shapes and NEEDS_HUMAN: lines; prose, [NOTE] lines
#   and already-demoted lines are not read. A `[BLOCK needs-human]` go-live step
#   is not a floor: it rides to the ticket as a hold (wave B, C3). rc 1 none.
br_floor_stands() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    grep -qiE "$RL_FIND_RE|^[[:space:]]*NEEDS_HUMAN:" <<<"$line" || continue
    grep -qiE '\[NOTE|not verified here' <<<"$line" && continue
    grep -qiE '\[BLOCK needs-human\]' <<<"$line" && continue
    rl_line_blocks "$line" && return 0
  done < "$1"
  return 1
}

# br_cap_notes <project> <rkey> <reason> <pr-url> <record> <ticket-key> — the
#   review terminal when the fix-round cap is spent (BH-7123 wave B, C2):
#   MERGE WITH NOTES, NOT ABANDON, when nothing left on the PR's standing
#   REQUEST_CHANGES review(s) is on the ALWAYS-BLOCK floor.
#   rc 0  handled this tick, the caller abandons nothing: the notes-only
#         re-review was requested now (or on an earlier tick for this head), or
#         a read failed and the row is retried next tick, or observe mode.
#   rc 1  not this path: a floor line stands, a PERSON's CHANGES_REQUESTED
#         stands (never dismissed by this lane), no standing review at all, no
#         PR url, or the review-level lib is missing — today's abandon runs.
#   What it does, in order (D16: the record first, so nothing repeats):
#     1. outcome CAP_NOTES + cap_notes_head=<head> on the ticket's record, one
#        `cap-notes` attempt row;
#     2. the ledger row review_cap "<slug>#<pr>@<head>" = cap-reached, the
#        carrier bin/lead-review.sh reads when the request row below cannot
#        carry a scope note (a done row with other notes already holds the head);
#     3. dismisses the stale harness REQUEST_CHANGES review(s) (the lead's and
#        the review lane's own; the builder's in-build review is one of them),
#        so the park stops re-offering itself and Mergify's
#        changes-requested gate opens once the lead-verdict status does;
#     4. ONE notes-only lead re-review of this head: bin/lead-verdict.sh request
#        with the scope token review-level:cap-reached, else (409: the head's
#        request row is done) bin/lead-verdict.sh reset <id>. bin/lead-review.sh
#        runs rl_cap in cowboy mode for that review, so every finding without an
#        ALWAYS-BLOCK class is a NOTE and the verdict lands MERGE-WITH-NOTES;
#     5. ONE warn alert naming the ticket (cap_notes_alerted=<head>): the
#        operator is told once, nothing waits on a person.
#   A second tick on the same head (outcome CAP_NOTES, same cap_notes_head) is
#   quiet; a new standing review on the same head with a floor line is rc 1.
br_cap_notes() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}"
  local ck st slug num head rows standing n cap bodies ids id login lr rc out rid ref
  command -v rl_line_blocks >/dev/null 2>&1 || return 1
  case "$url" in https://github.com/*/pull/*) ;; *) return 1 ;; esac
  slug=$(br_slug_of_url "$url") || return 1
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 1
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  head=$(br_pr_field "$url" '.head.sha' "pr head"); rc=$?
  if [ "$rc" != 0 ] || [ -z "$head" ]; then
    say "$p/$rkey [$reason]: at the fix cap, the PR's head could not be read (rc $rc) — nothing closed on a head nobody saw, retried next tick"
    return 0
  fi
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  rows=$(br_review_rows "$slug" "$num") || {
    say "$p/$rkey [$reason]: at the fix cap, the reviews list would not read — nothing closed or abandoned on a list nobody saw, retried next tick"
    return 0
  }
  # The newest review per login that still says CHANGES_REQUESTED.
  standing=$(printf '%s' "$rows" | jq -c '[group_by(.l) | .[] | last | select(.s == "CHANGES_REQUESTED")]' 2>/dev/null) || return 1
  [ "$(printf '%s' "$standing" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null || return 1
  # Ours: a Bot row (BH-8419: the review's user.type is Bot, or a `[bot]`
  # login) that is a verdict author's review or carries the lead lane's marker.
  # The operator login (a lane on the default PAT posts as it, BH-8466) is ours
  # only when the body carries the harness footer or starts with the lead
  # marker (harness_own_review_row). Any other row is a person's, and a
  # person's REQUEST_CHANGES is never dismissed by this lane: today's path,
  # before any record write or dismissal.
  while IFS=$'\t' read -r login lr bot b64; do
    [ -n "$login" ] || continue
    if [ "$bot" = true ]; then
      [ "$lr" = true ] && continue
      command -v harness_verdict_author_match >/dev/null 2>&1 && harness_verdict_author_match "$login" && continue
    elif command -v harness_own_review_row >/dev/null 2>&1 \
         && harness_own_review_row "$login" "$(printf '%s' "${b64:-}" | base64 -d 2>/dev/null)"; then
      continue
    fi
    say "$p/$rkey [$reason]: at the fix cap, a person's CHANGES_REQUESTED by $login stands — not this lane's to dismiss"
    return 1
  done < <(printf '%s' "$standing" | jq -r '.[] | [.l, ((.b // "") | startswith("<!-- lead-review:")), (((.t // "") == "Bot") or ((.l // "") | endswith("[bot]"))), ((.b // "") | @base64)] | @tsv' 2>/dev/null)
  bodies=$(mktemp "${TMPDIR:-/tmp}/br-capnotes.XXXXXX") || return 1
  printf '%s' "$standing" | jq -r '.[] | .b // ""' 2>/dev/null | tr -d '\r' > "$bodies"
  if br_floor_stands "$bodies"; then
    rm -f "$bodies"
    say "$p/$rkey [$reason]: at the fix cap, an ALWAYS-BLOCK finding still stands on ${head:0:12} — the review terminal is today's"
    return 1
  fi
  rm -f "$bodies"
  st=$(br_load "$p" "$ck")
  if [ "$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)" = CAP_NOTES ] \
     && [ "$(printf '%s' "$st" | jq -r '.cap_notes_head // ""' 2>/dev/null)" = "$head" ]; then
    br_quiet cap-notes 2>/dev/null || true
    return 0
  fi
  n=$(br_num "$st" fixrounds); cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null); case "$cap" in ''|*[!0-9]*) cap="?" ;; esac
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD request a notes-only lead re-review of ${head:0:12} (fix cap $n/$cap, no ALWAYS-BLOCK finding stands) and merge with notes — observe mode"
    return 0
  fi
  # 1. the record, first.
  br_record "$p" "$ck" cap-notes "$reason" "fix cap $n/$cap reached on ${head:0:12}: no ALWAYS-BLOCK finding stands; notes-only lead re-review requested, the PR merges with notes" "" "$url" "$head"
  br_set_outcome "$p" "$ck" CAP_NOTES
  br_set_field "$p" "$ck" cap_notes_head "$head"
  # 2. the carrier the lead reads.
  command -v job_ledger_put >/dev/null 2>&1 \
    && { job_ledger_put review_cap "$slug#$num@$head" cap-reached "fix rounds $n/$cap spent on $tkey; notes-only re-review: every finding without an ALWAYS-BLOCK class is a NOTE" >/dev/null 2>&1 </dev/null \
         || say "$p/$rkey [$reason]: the review_cap ledger row did not write — the scope token on the request is the only carrier"; }
  # 3. the stale harness REQUEST_CHANGES reviews.
  while IFS= read -r id; do
    [ -n "$id" ] && [ "$id" != 0 ] || continue
    if gh_rest PUT "repos/$slug/pulls/$num/reviews/$id/dismissals" -f event=DISMISS \
         -f message="Dismissed by bin/blocked-resolver.sh (BH-7123): the fix-round cap ($n/$cap) is spent and none of these findings is an ALWAYS-BLOCK class, so they ride as notes; a notes-only lead re-review of ${head:0:12} decides the merge." >/dev/null 2>&1; then
      say "$p/$rkey [$reason]: dismissed the stale harness REQUEST_CHANGES review $id on $slug#$num"
    else
      say "$p/$rkey [$reason]: could not dismiss review $id on $slug#$num (HTTP ${GH_REST_STATUS:-000}) — the lead's MERGE-WITH-NOTES landing dismisses it (lead-review-land step 2d)"
    fi
  done < <(printf '%s' "$standing" | jq -r '.[] | .id // 0' 2>/dev/null)
  # 4. one notes-only re-review.
  if out=$("$H/bin/lead-verdict.sh" request "$slug" "$num" "$head" --notes "review-level:cap-reached fix-rounds:$n/$cap" 2>&1 </dev/null); then
    say "$p/$rkey [$reason]: notes-only lead re-review requested for ${head:0:12} ($(head -1 <<<"$out" | tr -d '\n' | cut -c1-120))"
  else
    rid=""
    if command -v _jobs_req >/dev/null 2>&1; then
      rid=$(_jobs_req GET "/api/lead-reviews?repo=$slug&status=done,failed,superseded" 2>/dev/null </dev/null \
        | jq -r --argjson pr "$num" --arg h "$head" '[.requests[]? | select(.pr == $pr and .head_sha == $h)] | first | .id // empty' 2>/dev/null)
    fi
    if [ -n "$rid" ] && "$H/bin/lead-verdict.sh" reset "$rid" >/dev/null 2>&1 </dev/null; then
      say "$p/$rkey [$reason]: the head's lead review request $rid was done — reset for the notes-only re-review (the review_cap ledger row carries the mode)"
    else
      say "$p/$rkey [$reason]: the notes-only re-review could not be requested or reset ($(head -1 <<<"$out" | tr -d '\n' | cut -c1-160)) — the review_cap ledger row stands for the next lead review of ${head:0:12}"
    fi
  fi
  # 5. the operator, once.
  if [ "$(br_load "$p" "$ck" | jq -r '.cap_notes_alerted // ""' 2>/dev/null)" != "$head" ]; then
    br_set_field "$p" "$ck" cap_notes_alerted "$head"
    ref="$tkey"; case "$url" in https://github.com/*/pull/*) ref="$num" ;; esac
    "$H/bin/lane-alert.sh" --id "review-cap-notes:$p:$ref:${head:0:12}" --severity warn blocked-resolver \
      "[$p] review cap: $tkey ($url) spent $n of $cap fix round(s) on review findings, none of which is an ALWAYS-BLOCK class. A notes-only lead re-review of ${head:0:12} was requested and the PR merges with notes. Nothing was abandoned or closed, and nothing waits on a person." >/dev/null 2>&1 </dev/null || true
  fi
  say "$p/$rkey [$reason]: CAP_NOTES — fix cap $n/$cap spent on ${head:0:12}, no ALWAYS-BLOCK finding stands; merging with notes, not abandoning"
  return 0
}
