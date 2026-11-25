#!/bin/bash
# bin/lib/prr-ci-state.sh — the CI word of a PR head from the PR record
# (BH-9926 wave 4). Sourced, never executed. Defines functions only: no set -e,
# no exit.
#
#   prr_ci_state <owner/repo> <number> <head-sha>
#       Prints one word, rc 0: green, red, pending or unknown. It reads the
#       record's `checks` field (pr_record_peek: one jobs GET, no GitHub call).
#       unknown means "read GitHub": no row, a row whose head_sha is another
#       sha, no check entry for the head, or a checks object with
#       PRR_CI_CHECKS_MAX names or more (the worker refuses a new name at
#       CHECKS_MAX, so a check of this head can be missing). unknown is never
#       green.
#       The rule, over the entries whose .sha is the head (lowercase compare)
#       and whose name does not match PRR_CI_IGNORE_RE:
#         1. drop completed entries that ended cancelled, timed_out, skipped
#            or neutral (the mc_ci_state rule);
#         2. none left: unknown;
#         3. any entry not completed: pending;
#         4. any conclusion failure, startup_failure or action_required: red;
#         5. else green.
#
#   The missed-event guard (a pending word only, PRR_CI_GUARD not 0): when the
#   oldest pending entry is older than PRR_CI_PENDING_MAX_S, it reads GitHub
#   ONE time (gh_rest GET repos/<repo>/actions/runs?head_sha=<head>&per_page=50,
#   the mc_ci_state URL) and writes the result back with one
#   pr_record_put <repo> <n> github '{"checks":{...}}' <start>: one entry
#   `workflow:<name>` per workflow (the latest per name), {status,
#   conclusion, sha: <head>, at: <start>}. The PUT replaces the whole checks
#   object. Then it prints the word of the written entries. A failed read
#   prints unknown and writes nothing. The worker keeps a newer webhook value
#   (fields_at compare), so the PUT never overwrites a newer event.
#
# Knobs (catalog/lanes.d/_lib.pr-record.knobs.d/), each read through lane_knob
# pr-record (libs scope) when the caller has it, else from the environment,
# else the code fallback; a bad value is the fallback plus one log line:
#   PRR_CI_PENDING_MAX_S  int, default 900, 0..86400
#   PRR_CI_IGNORE_RE      regex (jq test) on the WHOLE check name: the code
#                         adds the anchors ^(?:<value>)$, so the value holds
#                         no dollar sign (lanes-registry 20a refuses a default
#                         with one as shell); empty = ignore nothing
#   PRR_CI_CHECKS_MAX     int, default 100, 1..1000
# PRR_CI_GUARD=0 turns the guard off (the merge-conductor seam sets it in step
# shadow). PRR_CI_NOW (epoch) is the test clock seam.
#
# Log: <root>/logs/prr-shadow.log, root ${HARNESS:-${H:-}} (no root, no line):
#   <UTC> PRR_CI_GUARD repo=<r> n=<n> head=<h8> age_s=<a> gh_rc=<rc> put=<ok|failed|skipped> word=<w>
#   <UTC> PRR_CI_KNOB <ENV>='<value>' <why>: using <fallback>
[ -n "${_PRR_CI_STATE_LOADED:-}" ] && return 0
_PRR_CI_STATE_LOADED=1
_PRR_CI_DIR="${BASH_SOURCE[0]%/*}"
if ! command -v pr_record_peek >/dev/null 2>&1 && [ -r "$_PRR_CI_DIR/pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "$_PRR_CI_DIR/pr-record.sh"
fi

_PRR_CI_DEFAULT_PENDING_MAX_S=900   # fallback only: the knob is PRR_CI_PENDING_MAX_S in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRR_CI_DEFAULT_CHECKS_MAX=100      # fallback only: the knob is PRR_CI_CHECKS_MAX in catalog/lanes.d/_lib.pr-record.knobs.d/ (the worker's CHECKS_MAX)
# fallback only: the knob is PRR_CI_IGNORE_RE in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRR_CI_DEFAULT_IGNORE_RE='Summary|Mergify Merge Queue|suite:mergify|suite:vercel|Vercel.*|Rule: .*|Queue: .*'

_prr_ci_log() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$root/logs/prr-shadow.log" 2>/dev/null || true
}

_prr_ci_ignore_default() { printf '%s' "$_PRR_CI_DEFAULT_IGNORE_RE"; }

# _prr_ci_raw <ENV> — the knob's raw value: lane_knob, else the environment.
# rc 1 when neither has one.
_prr_ci_raw() {
  local v="" _LG_KIND=libs
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob pr-record "$1" 2>/dev/null); fi
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  [ -n "${!1+x}" ] || return 1
  printf '%s' "${!1}"
}

# _prr_ci_int <ENV> <fallback> <min> <max>
_prr_ci_int() {
  local v
  v=$(_prr_ci_raw "$1") || v=""
  [ -n "$v" ] || { printf '%s' "$2"; return 0; }
  if ! [[ "$v" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$v))" -lt "$3" ] || [ "$((10#$v))" -gt "$4" ]; then
    _prr_ci_log "PRR_CI_KNOB $1='$v' is not an integer in $3..$4: using $2"
    printf '%s' "$2"; return 0
  fi
  printf '%s' "$((10#$v))"
}

# _prr_ci_ignore_re — the regex; empty = ignore nothing.
_prr_ci_ignore_re() {
  local v
  v=$(_prr_ci_raw PRR_CI_IGNORE_RE) || { _prr_ci_ignore_default; return 0; }
  [ -n "$v" ] || return 0
  if ! jq -en --arg r "$v" '"x" | test("^(?:" + $r + ")$") | type == "boolean"' >/dev/null 2>&1; then
    _prr_ci_log "PRR_CI_KNOB PRR_CI_IGNORE_RE='$v' is not a regex jq accepts: using the default"
    _prr_ci_ignore_default; return 0
  fi
  printf '%s' "$v"
}

# _prr_ci_reduce <checks-json> <head-lower> <ignore-re> -> "<word>\t<oldest pending at, epoch or 0>"
_prr_ci_reduce() {
  jq -rn --argjson c "$1" --arg h "$2" --arg re "$3" '
    [($c // {}) | to_entries[]
      | select(((.value.sha // "") | ascii_downcase) == $h)
      | select($re == "" or ((.key | test("^(?:" + $re + ")$")) | not))
      | .value
      | select((.status == "completed" and ((.conclusion // "") | IN("cancelled", "timed_out", "skipped", "neutral"))) | not)] as $e
    | if ($e | length) == 0 then "unknown\t0"
      elif any($e[]; .status != "completed") then
        "pending\t\([$e[] | select(.status != "completed") | ((.at // "") | (try fromdateiso8601 catch 0))] | min)"
      elif any($e[]; (.conclusion // "") | IN("failure", "startup_failure", "action_required")) then "red\t0"
      else "green\t0" end' 2>/dev/null
}

prr_ci_state() {
  local repo="${1:-}" n="${2:-}" head="${3:-}" hl row rhead checks cmax re out word oldest
  local now age maxp start runs grc put obj res rf
  hl=$(printf '%s' "$head" | tr 'A-Z' 'a-z')
  [[ "$hl" =~ ^[0-9a-f]{7,64}$ ]] || { echo unknown; return 0; }
  command -v pr_record_peek >/dev/null 2>&1 || { echo unknown; return 0; }
  row=$(pr_record_peek "$repo" "$n" 2>/dev/null) || { echo unknown; return 0; }
  rhead=$(jq -r '.head_sha // "" | ascii_downcase' <<<"$row" 2>/dev/null) || { echo unknown; return 0; }
  if [ -n "$rhead" ] && [ "$rhead" != "$hl" ]; then echo unknown; return 0; fi
  checks=$(jq -c '.checks // {} | if type == "object" then . else {} end' <<<"$row" 2>/dev/null) || { echo unknown; return 0; }
  cmax=$(_prr_ci_int PRR_CI_CHECKS_MAX "$_PRR_CI_DEFAULT_CHECKS_MAX" 1 1000)
  if [ "$(jq 'length' <<<"$checks")" -ge "$cmax" ]; then echo unknown; return 0; fi
  re=$(_prr_ci_ignore_re)
  out=$(_prr_ci_reduce "$checks" "$hl" "$re") || out=""
  IFS=$'\t' read -r word oldest <<<"$out"
  case "$word" in green|red|pending|unknown) ;; *) echo unknown; return 0 ;; esac
  if [ "$word" != pending ] || [ "${PRR_CI_GUARD:-1}" = 0 ]; then echo "$word"; return 0; fi

  # The missed-event guard.
  now="${PRR_CI_NOW:-}"; [[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s)
  [[ "$oldest" =~ ^[0-9]+$ ]] || oldest=0
  age=$((now - oldest)); [ "$age" -ge 0 ] || age=0
  maxp=$(_prr_ci_int PRR_CI_PENDING_MAX_S "$_PRR_CI_DEFAULT_PENDING_MAX_S" 0 86400)
  if [ "$age" -le "$maxp" ] && [ "$maxp" -gt 0 ]; then echo pending; return 0; fi
  start=$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ')
  if ! command -v gh_rest >/dev/null 2>&1 && [ -r "$_PRR_CI_DIR/gh-rest.sh" ]; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "$_PRR_CI_DIR/gh-rest.sh" >/dev/null 2>&1
  fi
  grc=0
  if command -v gh_rest >/dev/null 2>&1; then
    # A plain call with `> file`, never `$(gh_rest ...)`: GH_REST_STATUS and
    # GH_REST_REASON are set in the calling shell (tests/gh-rest-no-subshell-lint.sh).
    rf=$(mktemp "${TMPDIR:-/tmp}/prr-ci-runs.XXXXXX") || grc=73
    if [ "$grc" = 0 ]; then
      gh_rest GET "repos/$repo/actions/runs?head_sha=$head&per_page=50" > "$rf" || grc=$?
      runs=$(cat "$rf" 2>/dev/null); rm -f "$rf"
    fi
  else
    grc=127
  fi
  if [ "$grc" = 0 ]; then
    obj=$(jq -c --arg h "$hl" --arg at "$start" '[.workflow_runs[]? | {n: ((.name // .workflow_id // "?") | tostring),
                              t: ((.run_started_at // .created_at) // ""),
                              a: (.run_attempt // 1), s: (.status // ""), c: .conclusion}]
        | group_by(.n) | map(sort_by(.t, .a) | last)
        | map({key: "workflow:\(.n)", value: {status: .s, conclusion: .c, sha: $h, at: $at}}) | from_entries' <<<"$runs" 2>/dev/null) || grc=65
  fi
  if [ "$grc" != 0 ]; then
    _prr_ci_log "PRR_CI_GUARD repo=$repo n=$n head=${hl:0:8} age_s=$age gh_rc=$grc put=skipped word=unknown"
    echo unknown; return 0
  fi
  put=failed
  if res=$(pr_record_put "$repo" "$n" github "{\"checks\":$obj}" "$start" 2>/dev/null) \
     && jq -e '.applied | index("checks") != null' <<<"$res" >/dev/null 2>&1; then
    put=ok
  fi
  out=$(_prr_ci_reduce "$obj" "$hl" "$re") || out=""
  IFS=$'\t' read -r word oldest <<<"$out"
  case "$word" in green|red|pending|unknown) ;; *) word=unknown ;; esac
  _prr_ci_log "PRR_CI_GUARD repo=$repo n=$n head=${hl:0:8} age_s=$age gh_rc=0 put=$put word=$word"
  echo "$word"
}
