#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/collectors/lifecycle.sh — the Tackler's ticket-lifecycle
# family (BH-8736, lifecycle 6/6). READ ONLY: 0 model calls, 0 GitHub or worker
# writes; the only file it writes is one line in logs/unblock.log.
#
# The other families start from open PRs, boxes and pools. A ticket with no
# open PR was invisible to the Tackler. This family starts from the ticket
# ledger (#8731): GET /api/lifecycle/stuck, through lifecycle_stuck
# (bin/lib/jobs/lifecycle.sh).
#
#   . lifecycle.sh; unblock_collect_lifecycle <project> <repo>
#   ub_collect_lifecycle <project> <repo>   the collect.sh contract entry
#
# THE READS, in order:
#   1. lifecycle_stuck <project>: rc != 0, or no .rows array = rc 1 (a cut list
#      is never "nothing stuck"). Only the phases ejected, abandoned and
#      plan_blocked make records; at most UNBLOCK_LIFECYCLE_ROWS_MAX of them,
#      oldest phase_at first. The rest are counted in the meta `truncated`.
#   2. ejected and abandoned: one GET /api/lifecycle/history?project=&ticket_key=.
#      abandons = the events with to_phase abandoned; pr = the row's pr, else
#      the newest event's non-null pr (events in id order, else route order).
#   3. ejected with a pr: one gh_rest GET repos/<repo>/pulls/<pr> -> head,
#      pr_state, merged, labels, merge_sha (.merge_commit_sha, 40 hex, else
#      null) and base_ref (.base.ref, else null). U14-MERGED reads the last two.
# UNKNOWN IS NOT FALSE: a failed read 2 or 3 sets its fields to null and names
# it in `unknown` (history, pull). A null never matches a U14 predicate.
#
# One record per kept row:
#   {kind: ticket-ejected | ticket-abandoned | ticket-plan-blocked,
#    family: "lifecycle", project, repo, subject_kind: "build",
#    subject: "<project>:<KEY>", ticket_key, phase, episode (= phase_at),
#    age_min, threshold_min, phase_actor, question, pr, head, pr_state,
#    merged, merge_sha, base_ref, labels, abandons, rebuild_max,
#    stall_at (= phase_at), unknown}
# The rules (catalog/unblock-rules.d/U14-*.json) key on project, ticket_key,
# episode and the rule id: one decision per stuck episode.
# unblock_collect_lifecycle prints one meta line last:
#   {kind: "collector-meta", family: "lifecycle", rows_seen, truncated, unreadable}
# ub_collect_lifecycle drops it (it is not a stall record).
#
# rc 0 = records printed; rc 1 = the lifecycle lib is not loaded or the stuck
# read failed (collect.sh counts the family FAILED and drops the output);
# rc 2 = bad args or no root ($HARNESS, then $H; D43, no default).
#
# Knobs (catalog/lanes.d/unblock.knobs.d/):
#   UNBLOCK_LIFECYCLE_ROWS_MAX (50, 1..200)   stuck rows turned into records
#   UNBLOCK_LIFECYCLE_REBUILD_MAX (1, 0..5)   copied to rebuild_max; U14-REBUILD
#                                             takes abandons <= rebuild_max
# gh-rest: no-graphql

_ucl_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s lifecycle: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

# _ucl_load <root> — gh_rest, _jobs_req and lifecycle_stuck. The tick has
# already loaded the last two in this shell; a file missing is not an error
# here, a function missing after the load is.
_ucl_load() {
  local lc="$1/bin/lib/jobs/lifecycle.sh"
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || . "$1/bin/lib/gh-rest.sh" >/dev/null 2>&1
  # shellcheck disable=SC1091
  declare -F _jobs_req >/dev/null || . "$1/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck disable=SC1090
  declare -F lifecycle_stuck >/dev/null || { [ -r "$lc" ] && . "$lc" >/dev/null 2>&1; }
  declare -F lifecycle_stuck >/dev/null && declare -F _jobs_req >/dev/null
}

# _ucl_uri <text> — percent-encode a query value.
_ucl_uri() { jq -rn --arg v "$1" '$v | @uri'; }

unblock_collect_lifecycle() {
  local h="${HARNESS:-${H:-}}" project="${1:-}" slug="${2:-}"
  [ -n "$h" ] || { echo "lifecycle.sh: no root (\$HARNESS or \$H)" >&2; return 2; }
  [[ $project =~ ^[A-Za-z0-9._-]+$ ]] && [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { echo "usage: unblock_collect_lifecycle <project> <owner/name>" >&2; return 2; }
  if ! _ucl_load "$h"; then
    _ucl_log "$project: bin/lib/jobs/lifecycle.sh (lifecycle_stuck) or jobs-client is not loaded; 0 reads"
    return 1
  fi
  local rmax="${UNBLOCK_LIFECYCLE_ROWS_MAX:-50}" rbmax="${UNBLOCK_LIFECYCLE_REBUILD_MAX:-1}"
  { [[ $rmax =~ ^[0-9]+$ ]] && [ "$rmax" -ge 1 ] && [ "$rmax" -le 200 ]; } || rmax=50
  { [[ $rbmax =~ ^[0-9]+$ ]] && [ "$rbmax" -le 5 ]; } || rbmax=1

  local stuck rc=0
  stuck=$(JOBS_ALERT=0 lifecycle_stuck "$project" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.rows | type) == "array"' >/dev/null 2>&1 <<<"$stuck"; then
    _ucl_log "$project: stuck read failed (rc $rc); 0 records"
    return 1
  fi
  local rows seen kept
  rows=$(jq -c --arg p "$project" '[.rows[] | select(type == "object")
      | select(.phase == "ejected" or .phase == "abandoned" or .phase == "plan_blocked")
      | select((.ticket_key | type) == "string" and (.phase_at | type) == "string")
      | select((.project // $p) == $p)] | sort_by(.phase_at)' <<<"$stuck")
  seen=$(jq 'length' <<<"$rows")
  rows=$(jq -c --argjson m "$rmax" '.[:$m]' <<<"$rows")
  kept=$(jq 'length' <<<"$rows")

  # gh_rest runs in this shell with its body in a file, never inside $( ): a
  # command substitution would lose GH_REST_STATUS (tests/gh-rest-no-subshell-lint.sh).
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ucl.XXXXXX") || { _ucl_log "$project: mktemp failed; 0 records"; return 1; }
  local -a unreadable=()
  local row key phase hist pull pr unk nhist=0 npull=0 out=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    key=$(jq -r .ticket_key <<<"$row"); phase=$(jq -r .phase <<<"$row")
    hist=null pull=null unk='[]'
    pr=$(jq -r 'if (.pr | type) == "number" then .pr else "" end' <<<"$row")
    if [ "$phase" != plan_blocked ]; then
      nhist=$((nhist + 1)); rc=0
      hist=$(JOBS_ALERT=0 _jobs_req GET "/api/lifecycle/history?project=$(_ucl_uri "$project")&ticket_key=$(_ucl_uri "$key")" 2>/dev/null) || rc=$?
      if [ "$rc" = 0 ] && jq -e '(.events | type) == "array"' >/dev/null 2>&1 <<<"$hist"; then
        hist=$(jq -c '.events' <<<"$hist")
        [ -n "$pr" ] || pr=$(jq -r '[.[] | select(type == "object" and (.pr | type) == "number")] | sort_by(.id // 0) | last | .pr // ""' <<<"$hist")
      else
        hist=null; unk=$(jq -c '. + ["history"]' <<<"$unk"); unreadable+=("history:$key")
      fi
    fi
    if [ "$phase" = ejected ] && [[ $pr =~ ^[1-9][0-9]*$ ]]; then
      npull=$((npull + 1)); rc=0
      gh_rest GET "repos/$slug/pulls/$pr" > "$tmp/pull.json" 2>/dev/null || rc=$?
      pull=$(cat "$tmp/pull.json" 2>/dev/null)
      if [ "$rc" != 0 ] || ! jq -e 'type == "object" and (.head.sha | type) == "string"' >/dev/null 2>&1 <<<"$pull"; then
        echo "lifecycle.sh: $project $key pull #$pr unread (rc $rc, status ${GH_REST_STATUS:-000}, reason ${GH_REST_REASON:-none})" >&2
        pull=null; unk=$(jq -c '. + ["pull"]' <<<"$unk"); unreadable+=("pull#$pr")
      fi
    fi
    out+=$(jq -c -n --argjson r "$row" --arg p "$project" --arg repo "$slug" --argjson ev "$hist" \
        --argjson pull "$pull" --arg pr "$pr" --argjson rb "$rbmax" --argjson unk "$unk" '
      {"ejected": "ticket-ejected", "abandoned": "ticket-abandoned", "plan_blocked": "ticket-plan-blocked"} as $kinds
      | {kind: $kinds[$r.phase], family: "lifecycle", project: $p, repo: $repo,
         subject_kind: "build", subject: "\($p):\($r.ticket_key)", ticket_key: $r.ticket_key,
         phase: $r.phase, episode: $r.phase_at, age_min: ($r.age_min // null),
         threshold_min: ($r.threshold_min // null), phase_actor: ($r.phase_actor // null),
         question: (if ($r.question | type) == "string" then $r.question else null end),
         pr: (if $pr == "" then null else ($pr | tonumber) end),
         head: (if $pull == null or ($pull.head.sha | test("^[0-9a-f]{40}$") | not) then null else $pull.head.sha end),
         pr_state: (if $pull == null then null else ($pull.state // null) end),
         merged: (if $pull == null or ($pull.merged | type) != "boolean" then null else $pull.merged end),
         merge_sha: (if $pull == null or (($pull.merge_commit_sha // "") | tostring | test("^[0-9a-f]{40}$") | not) then null else $pull.merge_commit_sha end),
         base_ref: (if $pull == null or ($pull.base.ref? | type) != "string" then null else $pull.base.ref end),
         labels: (if $pull == null then [] else [($pull.labels // [])[] | (.name? // .) | select(type == "string")] end),
         abandons: (if $ev == null then null else [$ev[] | select(type == "object" and .to_phase == "abandoned")] | length end),
         rebuild_max: $rb, stall_at: $r.phase_at, unknown: $unk}')$'\n'
  done < <(jq -c '.[]' <<<"$rows")
  rm -rf "$tmp"
  printf '%s' "$out"
  jq -nc --argjson n "$seen" --argjson t "$((seen - kept))" \
    --argjson u "$(printf '%s\n' ${unreadable[@]+"${unreadable[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{kind: "collector-meta", family: "lifecycle", rows_seen: $n, truncated: $t, unreadable: $u}'
  _ucl_log "$project rows=$seen records=$kept truncated=$((seen - kept)) history=$nhist pulls=$npull"
  return 0
}

# ub_collect_lifecycle <project> <repo> — the UNB-0 contract entry
# (bin/lib/unblock/collect.sh). The stall records only: the meta line is not a
# stall record. A non-zero rc is passed on, so the tick counts it FAILED.
ub_collect_lifecycle() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 2
  local out rc=0
  out=$(unblock_collect_lifecycle "$1" "$2") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$out" | grep -v -e '^{"kind":"collector-meta"' -e '^[[:space:]]*$' || true
  return 0
}
