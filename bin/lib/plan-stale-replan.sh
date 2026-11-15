#!/bin/bash
# bin/lib/plan-stale-replan.sh — END THE PLAN_STALE LOOP ON A RESUMED TICKET
# (BH-9672). Sourced; functions only. Knobs are resolved when a caller asks
# (psr_knob).
#
# THE LOOP. A build on a branch that already carries commits adopted the DB
# pre-plan (PREPLAN_HIT .../preplan-db). The plan thread gate
# (bin/lib/plan-thread.sh) refused it for an uncited newer comment, and the run
# ended PLAN_STALE (exit 3), because planning fresh there would ship the old
# diff under a plan that never saw the comment. The gate removed only the hub
# plans/ dir, so the coordination DB row stayed and the next build adopted it
# and ended the same way. BH-8841 did this 4 times, BH-9513 2 times, and no
# plan stage ran in any of them.
#
# WHAT THIS LIB ADDS, one function per rule:
#   psr_retire       a refused pre-plan is retired at its source: the hub dir
#                    (as before) AND the DB row (POST /api/preplans/retire,
#                    guarded by the refused plan's stamp).
#   psr_adopt_check  the adopt step runs the gate's own classifier (ptg_check)
#                    BEFORE it adopts. A refused pre-plan is PREPLAN_STALE and
#                    the plan stage runs in the same build.
#   psr_prior_stale  has an earlier build of this ticket already ended
#                    `PLAN_STALE uncited comment(s) newer than the plan: <ids>`
#                    for the same id set? (the jobs ledger, then local dirs)
#   psr_alert_once   one ALERTS line per (ticket, id set).
#   psr_branch_note  the note a fresh plan on a branch with commits gets: the
#                    commits, the diffstat and the refused ids. It writes the
#                    $BUILD/replan-on-branch marker.
#   psr_exec_note    the execute note: keep / revert / undecided, read from the
#                    plan's `## Existing branch commits` section.
#
# FAIL OPEN, EVERY PATH. An unreadable thread, an unreachable worker or an
# unreadable ledger gives today's behaviour plus one pipeline.log line. A
# retire failure is said in the RESULT, never written as "retired".
#
# Root: ${HARNESS:-${H:-}}. Needs jq and git.
# shellcheck shell=bash

# shellcheck source=bin/lib/plan-thread.sh
command -v ptg_check >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/plan-thread.sh" 2>/dev/null

PSR_EPOCH='1970-01-01T00:00:00Z'
PSR_ID_PREFIX='PLAN_STALE uncited comment(s) newer than the plan: '

_psr_stamp() { if command -v STAMP >/dev/null 2>&1; then STAMP; else date -u '+%Y-%m-%d %H:%M:%SZ'; fi; }
_psr_log() { # _psr_log <line> — one pipeline.log line, when there is a build dir
  [ -n "${BUILD:-}" ] && [ -d "$BUILD" ] || return 0
  printf '%s [%s/%s] %s\n' "$(_psr_stamp)" "${PROJECT:-?}" "${KEY:-?}" "$1" >> "$BUILD/pipeline.log"
}
_psr_iso() { [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }
# _psr_idset <ids...> -> the ids as a sorted, de-duplicated, space-joined set
_psr_idset() { printf '%s\n' $* | grep -E '^[0-9]+$' | sort -u | paste -sd' ' -; }

# _psr_client <harness> — load the jobs client (bin/jobs-client.sh) when
#   _jobs_req is not defined yet. No client is not an error here: the callers
#   say what they could not read.
_psr_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  if command -v _preplan_client >/dev/null 2>&1; then _preplan_client "${1:-}" >/dev/null 2>&1
  elif [ -r "${1:-}/bin/jobs-client.sh" ]; then . "${1:-}/bin/jobs-client.sh" >/dev/null 2>&1; fi
  command -v _jobs_req >/dev/null 2>&1
}

# psr_knob <PSR_ADOPT_THREAD_CHECK|PSR_REPEAT_FRESH|PSR_LOOKBACK|PSR_COMMITS_MAX>
#   The knobs are registered in catalog/lanes.d/_lib.plan-stale-replan.json and
#   resolved through lib_env_apply plan-stale-replan in a subshell, the way
#   ptg_enforce does it. A value outside the row's range, or no registry, is
#   the code fallback below, which is the registry default of the same row.
psr_knob() {
  local n="$1" v def min max
  case "$n" in
    PSR_ADOPT_THREAD_CHECK) def=1; min=0; max=1 ;;   # fallback of lib plan-stale-replan knob PSR_ADOPT_THREAD_CHECK
    PSR_REPEAT_FRESH) def=1; min=0; max=1 ;;         # fallback of lib plan-stale-replan knob PSR_REPEAT_FRESH
    PSR_LOOKBACK) def=5; min=1; max=50 ;;            # fallback of lib plan-stale-replan knob PSR_LOOKBACK
    PSR_COMMITS_MAX) def=30; min=1; max=200 ;;       # fallback of lib plan-stale-replan knob PSR_COMMITS_MAX
    *) return 1 ;;
  esac
  v=$(
    exec 3>&1
    trap 'printf "%s" "${!n:-}" >&3' EXIT
    [ -n "${!n:-}" ] && exit 0
    _PSR_R=$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd) || exit 0
    command -v lib_env_apply >/dev/null 2>&1 || . "$_PSR_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_PSR_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_PSR_R" 2>/dev/null) && export LANE_REGISTRY
    fi
    lib_env_apply plan-stale-replan >/dev/null 2>&1)
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$min" ] && [ "$((10#$v))" -le "$max" ]; then
    echo "$((10#$v))"
  else
    echo "$def"
  fi
}

# psr_retire_row <harness> <project> <key> <stamp>
#   POST /api/preplans/retire {project, ticket_key, thread_at_max}. Prints one
#   word group: `db row retired`, `db row already gone`, or
#   `db retire failed (http <code>|unreachable)`. rc 0 retired or gone, rc 2
#   failed.
psr_retire_row() {
  local h="${1:-}" p="${2:-}" k="${3:-}" s="${4:-}" body out rc n
  _psr_iso "$s" || s=$PSR_EPOCH
  _psr_client "$h"
  command -v _jobs_req >/dev/null 2>&1 || { echo "db retire failed (unreachable)"; return 2; }
  body=$(jq -nc --arg p "$p" --arg k "$k" --arg s "$s" '{project:$p, ticket_key:$k, thread_at_max:$s}') \
    || { echo "db retire failed (unreachable)"; return 2; }
  out=$(mktemp "${TMPDIR:-/tmp}/psr-retire.XXXXXX") || { echo "db retire failed (unreachable)"; return 2; }
  JOBS_HTTP=""
  _jobs_req POST /api/preplans/retire "$body" > "$out" 2>/dev/null; rc=$?
  n=$(jq -r '.retired // empty' "$out" 2>/dev/null); rm -f "$out"
  if [ "$rc" = 0 ] && [[ "$n" =~ ^[0-9]+$ ]]; then
    if [ "$n" -gt 0 ]; then echo "db row retired"; else echo "db row already gone"; fi
    return 0
  fi
  case "$rc" in 2) JOBS_HTTP=${JOBS_HTTP:-404} ;; esac
  if [ -n "${JOBS_HTTP:-}" ]; then echo "db retire failed (http $JOBS_HTTP)"; else echo "db retire failed (unreachable)"; fi
  return 2
}

# psr_retire <harness> <project> <key> <pp_dir> <stamp>
#   Retire a refused pre-plan at its source. The hub plans/ dir goes (the old
#   rule, moved here). The relay dir and $BUILD/preplan-db are copies and stay.
#   Then the DB row (psr_retire_row). Prints the outcome for the RESULT, logs
#   one `preplan-retire:` line. rc 0 retired or gone, rc 2 the row could not be
#   retired; every rc lets the build continue.
psr_retire() {
  local h="${1:-}" p="${2:-}" k="${3:-}" d="${4:-}" s="${5:-}" hub="" row rc
  case "$d" in "$h/plans/"?*) rm -rf "$d" && hub="hub dir removed, " ;; esac
  row=$(psr_retire_row "$h" "$p" "$k" "$s"); rc=$?
  _psr_log "preplan-retire: ${hub}${row} (thread_at_max ${s:-none})"
  printf '%s%s\n' "$hub" "$row"
  return "$rc"
}

# psr_adopt_check <pp_dir> <build>
#   The plan thread gate, BEFORE the adopt. Not for $(...): it sets PP_OUTCOME
#   and PSR_RETIRED in the caller. rc 0 adopt (as today); rc 1 refused:
#   PP_OUTCOME is `STALE uncited comment(s) newer than the pre-plan: <ids>`,
#   <build>/plan-stale-ids holds the ids and the row is retired.
psr_adopt_check() {
  local d="${1:-}" b="${2:-}" s out rc det ids
  command -v ptg_check >/dev/null 2>&1 || return 0
  [ "$(psr_knob PSR_ADOPT_THREAD_CHECK)" = 1 ] || return 0
  s=$(head -1 "$d/plan-thread-at" 2>/dev/null)
  _psr_iso "$s" || s=$PTG_EPOCH
  out=$(ptg_check "${PROJECT:-}" "${KEY:-}" "$d/plan.md" "$s" "$b/own-comments.sha256"); rc=$?
  det=${out#*$'\t'}
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) _psr_log "plan-thread: adopt check fails open ($det)"; return 0 ;;
  esac
  ids=$(ptg_ids "$det")
  if [ "$(ptg_enforce)" != 1 ]; then
    _psr_log "plan-thread: adopt check found uncited comment(s) $ids — PLAN_THREAD_GATE_ENFORCE=0, adopting"
    return 0
  fi
  PP_OUTCOME="STALE uncited comment(s) newer than the pre-plan: $ids"
  printf '%s\n' "$ids" > "$b/plan-stale-ids" 2>/dev/null
  PSR_RETIRED=$(psr_retire "${HARNESS:-${H:-}}" "${PROJECT:-}" "${KEY:-}" "$d" "$s")
  return 1
}

# _psr_result_ids <result-line> -> the id set of a
#   `PLAN_STALE uncited comment(s) newer than the plan: <ids> ...` line, or
#   nothing (rc 1) for any other line. The old `— re-plan` suffix and the new
#   `— refused plan retired ...` suffix both parse.
_psr_result_ids() {
  local l="${1%%$'\n'*}" rest w ids=""
  case "$l" in "$PSR_ID_PREFIX"*) ;; *) return 1 ;; esac
  rest=${l#"$PSR_ID_PREFIX"}
  for w in $rest; do [[ "$w" =~ ^[0-9]+$ ]] || break; ids="$ids $w"; done
  [ -n "$ids" ] || return 1
  _psr_idset $ids
}

# psr_prior_stale <project> <key> <ids> <job_id> <build>
#   rc 0 seen (prints where), rc 1 not seen, rc 2 unknown (prints why): no
#   store could be read. The stores: the newest PSR_LOOKBACK kind=build rows of
#   (project, key) in the jobs ledger, this build's own JOB_ID excluded, and
#   the newest PSR_LOOKBACK local dirs $HARNESS/builds/<project>-<key>-*
#   (this build's own dir excluded). The id sets must be EQUAL as sets: a
#   superset or a subset is another question and does not match.
psr_prior_stale() {
  local p="${1:-}" k="${2:-}" want job="${4:-}" b="${5:-}" h n q resp rows line d self known=0 why=""
  want=$(_psr_idset ${3:-})
  [ -n "$want" ] || { echo "no comment ids"; return 2; }
  n=$(psr_knob PSR_LOOKBACK)
  h=${HARNESS:-${H:-}}
  _psr_client "$h"
  if command -v _jobs_req >/dev/null 2>&1; then
    q=$(jq -nr --arg p "$p" --arg k "$k" '"project="+($p|@uri)+"&ticket_id="+($k|@uri)+"&kind=build"')
    if resp=$(_jobs_req GET "/api/jobs?$q&limit=$((n+1))" 2>/dev/null) \
      && rows=$(printf '%s' "$resp" | jq -r --arg p "$p" --arg k "$k" --arg job "$job" --argjson n "$n" '
        def result_line:
          (.meta // "") as $m
          | if ($m|type) == "string" then
              ((try ($m|fromjson) catch null) as $j
               | if ($j|type) == "object" then ($j.result // "" | tostring) else $m end)
            elif ($m|type) == "object" then ($m.result // "" | tostring)
            else "" end;
        if (.jobs|type) != "array" then error("no jobs array") else
        [.jobs[] | select(type == "object")
          | select((.id // "" | tostring) != $job or $job == "")
          | select((.kind // "build") == "build")] | .[:$n][]
          | select(.ticket_id == $k and ((.project // $p) == $p))
          | (result_line | split("\n")[0] | @base64)
        end' 2>/dev/null); then
      known=1
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        line=$(printf '%s' "$line" | base64 -d 2>/dev/null)
        [ "$(_psr_result_ids "$line")" = "$want" ] && { echo "seen in the jobs ledger"; return 0; }
      done <<<"$rows"
    else
      why="the jobs ledger did not answer"
    fi
  else
    why="no jobs client"
  fi
  if [ -n "$h" ] && [ -d "$h/builds" ]; then
    self=$(cd "$b" 2>/dev/null && pwd -P)
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      known=1
      [ -r "$d/RESULT" ] || continue
      [ "$(_psr_result_ids "$(head -1 "$d/RESULT")")" = "$want" ] && { echo "seen in $d/RESULT"; return 0; }
    done < <(for d in "$h/builds/$p-$k-"*/; do
               [ -d "$d" ] || continue
               d=${d%/}
               [ "$(cd "$d" 2>/dev/null && pwd -P)" = "$self" ] && continue
               # The KEY must end at the dash: BH-1 must not read BH-10's dirs.
               case "${d##*/}" in "$p-$k-"[0-9]*) printf '%s\n' "$d" ;; esac
             done | sort -r | head -n "$n")
  fi
  [ "$known" = 1 ] && return 1
  echo "${why:-no store}; no earlier build dir"
  return 2
}

# psr_alert_once <alerts> <project> <key> <ids> <tail>
#   `<stamp> PLAN_STALE_REPEAT [<project>/<key>] ids=<ids>: <tail>`, appended
#   only when no line for the same (ticket, id set) is in <alerts> yet.
psr_alert_once() {
  local f="${1:-}" p="${2:-}" k="${3:-}" ids tail="${5:-}" tag
  [ -n "$f" ] || return 1
  ids=$(_psr_idset ${4:-})
  tag="PLAN_STALE_REPEAT [$p/$k] ids=$ids:"
  grep -qF -- "$tag" "$f" 2>/dev/null && return 0
  printf '%s %s %s\n' "$(_psr_stamp)" "$tag" "$tail" >> "$f" 2>/dev/null
}

# psr_branch_note <base> <build>
#   Writes <build>/replan-on-branch (line 1 `ids <ids or ->`, then one
#   `<sha40><TAB><subject>` per commit of <base>..HEAD, at most PSR_COMMITS_MAX)
#   and prints the plan-prompt note. Prints nothing and writes nothing when the
#   branch has no commit over <base>.
psr_branch_note() {
  local base="${1:-main}" b="${2:-}" max ids all n more stat list
  max=$(psr_knob PSR_COMMITS_MAX)
  all=$(git log --format='%H%x09%s' "$base"..HEAD 2>/dev/null)
  [ -n "$all" ] || return 0
  n=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
  ids=$(_psr_idset $(cat "$b/plan-stale-ids" 2>/dev/null))
  { printf 'ids %s\n' "${ids:--}"; head -n "$max" <<<"$all"; } > "$b/replan-on-branch"
  more=""; [ "$n" -gt "$max" ] && more=" (+$((n-max)) more)"
  list=$(head -n "$max" <<<"$all" | awk -F'\t' '{printf "%s%s %s", (NR>1 ? "; " : ""), substr($1,1,12), $2}')
  stat=$(git diff --stat "$base"...HEAD 2>/dev/null); stat=$(head -n "$max" <<<"$stat" | sed 's/^ *//' | paste -sd';' - | sed 's/;/; /g')
  printf ' THIS BRANCH ALREADY CARRIES WORK (BH-9672). It has %s commit(s) over %s from an earlier build of %s, and that work was planned before ' "$n" "$base" "${KEY:-this ticket}"
  if [ -n "$ids" ]; then printf 'comment(s) %s, which this plan must apply and cite each by id. ' "$ids"; else printf 'the newest comments on the thread. '; fi
  printf 'Commits: %s%s. Diffstat: %s. Your plan MUST carry a section titled ## Existing branch commits with one line per commit: - <sha> keep|drop: <reason>. EXECUTE runs under your plan on this branch: it keeps each keep commit, reverts each drop commit and finishes the plan.' "$list" "$more" "${stat:-none}"
}

# psr_exec_note <plan.md> <marker>
#   The execute note for a branch that carries work planned without the
#   comment. Reads `- <sha> keep|drop: <reason>` lines (case-insensitive) from
#   the plan's `## Existing branch commits` section only. A sha that is not a
#   commit of the marker is ignored; a commit with no line is undecided.
psr_exec_note() {
  local plan="${1:-}" m="${2:-}" decl sha full keep="" drop="" und="" d
  decl=$(awk '
    /^##[[:space:]]/ { s = (tolower($0) ~ /^##[[:space:]]+existing branch commits[[:space:]]*$/); next }
    s && match($0, /^[[:space:]]*[-*][[:space:]]+[0-9A-Fa-f]+[[:space:]]+[A-Za-z]+/) {
      split(substr($0, RSTART, RLENGTH), w, /[[:space:]]+/)
      i = (w[1] == "") ? 2 : 1
      v = tolower(w[i+2]); sub(/:$/, "", v)
      if ((v == "keep" || v == "drop") && length(w[i+1]) >= 7) print tolower(w[i+1]) "\t" v
    }' "$plan" 2>/dev/null)
  while IFS=$'\t' read -r full _; do
    [[ "$full" =~ ^[0-9a-f]{40}$ ]] || continue
    d=""
    while IFS=$'\t' read -r sha v; do
      [ -n "$sha" ] || continue
      case "$full" in "$sha"*) d=$v ;; esac
    done <<<"$decl"
    case "$d" in
      keep) keep="$keep ${full:0:12}" ;;
      drop) drop="$drop ${full:0:12}" ;;
      *) und="$und ${full:0:12}" ;;
    esac
  done < <(tail -n +2 "$m" 2>/dev/null)
  printf 'THE PLAN WAS WRITTEN AGAIN ON A BRANCH THAT ALREADY CARRIES WORK (BH-9672). Run this execute stage under the new plan at %s. ' "$plan"
  printf 'Keep these commits:%s. ' "${keep:- none}"
  printf 'Revert each of these with git revert --no-edit <sha>, or with an edit that undoes it:%s. ' "${drop:- none}"
  [ -n "$und" ] && printf 'The plan gives no keep or drop for:%s. Check each one against the plan, keep only what the plan asks for, and undo the rest. ' "$und"
  printf 'Then finish the plan. '
}
