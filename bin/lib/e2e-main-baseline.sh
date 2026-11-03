#!/bin/bash
# shellcheck shell=bash
# bin/lib/e2e-main-baseline.sh — the lead review's `## Main E2E` section
# (BH-7941). Sourced, functions only; nothing runs at source time.
#
#   emb_section <repo> <head-sha> [project]   prints the section, sets EMB_STATE
#   emb_prompt_file <repo> <head-sha> <project> <out>
#                                             writes the section to <out> and logs
#                                             `main e2e <state>` (bin/lead-review.sh)
#
# WHY. In the lead review, E2E is a ratchet: a failing E2E test is a BLOCK only
# when it is a regression (it passes on main's latest full E2E run, or the
# nightly, and fails on this head). The lead model runs with no tools, so the
# harness reads both runs and hands it the comparison (checklist item 17).
#
# LIMITS. Each one is a settings row read through rl_knob (env
# REVIEW_LEVEL_<KEY> wins; a per-project row is <key>.<project>), seeded by
# worker/jobs/schema.d/202611031509-bh-7941-e2e-ratchet-knobs.sql:
#   review.e2e_baseline_runs       N   completed runs per list read   (50)
#   review.e2e_baseline_jobs       J   failed-job logs read per review (2)
#   review.e2e_baseline_ids        I   spec ids kept per run           (30)
#   review.e2e_baseline_timeout_s  T   seconds per REST call           (15)
#   review.e2e_baseline_calls      C   REST calls per review           (6)
#
# WHAT IT READS (GitHub REST, gh_rest, never GraphQL; each call bounded by T;
# at most C calls per review):
#   1. repos/<repo>/actions/runs?branch=main&status=completed&per_page=N:
#      the newest run whose name is E2E-class (bin/lib/e2e-paths.sh
#      E2E_CHECK_RE) with event push or schedule, conclusion success, failure
#      or timed_out. A run of the head's own workflow file wins over a newer
#      run of another E2E-class workflow.
#   2. repos/<repo>/actions/runs?head_sha=<sha>&status=completed&per_page=N:
#      the head's newest E2E-class run, any event, same conclusions (a
#      cancelled run is no evidence either way).
#   3. For each failed run: its jobs, then the logs of its failed jobs (2 when
#      J when one run failed, J/2 (at least 1) each when both did). The failing spec ids come from
#      the Playwright list reporter's numbered failure headers
#      (`  1) [project] › path/x.spec.ts:12:5 › suite › title ───`). The id is
#      `path › suite › title`, with no line:col, so a moved line does not read
#      as a new failure. At most I ids per run.
#
# EMB_STATE:
#   yes      both run lists were read and every failed run gave spec ids
#   none     no E2E-class run on main in the last N completed runs
#   off      review.e2e_ratchet=0 (bin/lib/review-level.sh rl_e2e_ratchet_on)
#   unknown  a read failed, or a failed run gave no spec ids
# A failed read is `COULD NOT READ (<why>)`, never "no failures". rc is 0 on
# every path: the section never stops a review.

EMB_STATE=""
# The limits of one emb_section call, read from the knobs above on each call.
# The values here are the code fallbacks of those rows.
EMB_MAX_RUNS=50      # row review.e2e_baseline_runs
EMB_MAX_JOBS=2       # row review.e2e_baseline_jobs
EMB_MAX_IDS=30       # row review.e2e_baseline_ids
EMB_TIMEOUT_S=15     # row review.e2e_baseline_timeout_s
EMB_MAX_CALLS=6      # row review.e2e_baseline_calls
_EMB_CALLS=0
_EMB_WHY=""

_emb_deps() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  if [ -z "${E2E_CHECK_RE:-}" ]; then
    # shellcheck source=bin/lib/e2e-paths.sh
    . "$root/bin/lib/e2e-paths.sh" 2>/dev/null || return 1
  fi
  if ! command -v gh_rest >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "$root/bin/lib/gh-rest.sh" 2>/dev/null || return 1
  fi
  if ! command -v rl_e2e_ratchet_on >/dev/null 2>&1; then
    # shellcheck source=bin/lib/review-level.sh
    . "$root/bin/lib/review-level.sh" 2>/dev/null || true
  fi
  [ -n "${E2E_CHECK_RE:-}" ] && command -v gh_rest >/dev/null 2>&1
}

# _emb_knobs [project] — sets the EMB_* limits from their settings rows. With
# no rl_knob (bin/lib/review-level.sh not loaded) the code fallbacks stand.
_emb_knobs() {
  local p="${1:-}"
  EMB_MAX_RUNS=50; EMB_MAX_JOBS=2; EMB_MAX_IDS=30; EMB_TIMEOUT_S=15; EMB_MAX_CALLS=6
  command -v rl_knob >/dev/null 2>&1 || return 0
  EMB_MAX_RUNS=$(rl_knob review.e2e_baseline_runs "$p" 50 '^([1-9]|[1-9][0-9])$|^100$')   # row review.e2e_baseline_runs (GitHub per_page max 100)
  EMB_MAX_JOBS=$(rl_knob review.e2e_baseline_jobs "$p" 2 '^[1-9][0-9]*$')                 # row review.e2e_baseline_jobs
  EMB_MAX_IDS=$(rl_knob review.e2e_baseline_ids "$p" 30 '^[1-9][0-9]*$')                  # row review.e2e_baseline_ids
  EMB_TIMEOUT_S=$(rl_knob review.e2e_baseline_timeout_s "$p" 15 '^[1-9][0-9]*$')          # row review.e2e_baseline_timeout_s
  EMB_MAX_CALLS=$(rl_knob review.e2e_baseline_calls "$p" 6 '^[0-9]+$')                    # row review.e2e_baseline_calls
  return 0
}

# _emb_get <api-path> <out-file> — one counted, bounded read. rc 0 = a body;
# else _EMB_WHY says why.
_emb_get() {
  local rc=0
  if [ "$_EMB_CALLS" -ge "$EMB_MAX_CALLS" ]; then _EMB_WHY="call budget of $EMB_MAX_CALLS spent"; return 75; fi
  _EMB_CALLS=$((_EMB_CALLS + 1))
  GH_REST_TIMEOUT_S=$EMB_TIMEOUT_S gh_rest GET "$1" > "$2" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && return 0
  _EMB_WHY="HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"
  return "$rc"
}

# _emb_ids <log-file> — the failing spec ids of one job log, one per line.
_emb_ids() {
  local ids
  ids=$(LC_ALL=C sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//' "$1" \
    | LC_ALL=C sed -nE 's/^[[:space:]]*[0-9]+\) (.*)$/\1/p' \
    | LC_ALL=C sed -E 's/^\[[^]]*\] › //; s/[[:space:]]*(─)+[[:space:]]*$//; s/[[:space:]]+$//' \
    | LC_ALL=C grep -E '^[^ ]+:[0-9]+:[0-9]+ › ')
  ids=$(LC_ALL=C sed -E 's/^([^ ]+):[0-9]+:[0-9]+ › /\1 › /' <<<"$ids") # emb-mutate: line-col
  [ -n "$ids" ] && printf '%s\n' "$ids"
  return 0
}

# _emb_side <repo> <run-json> <log-cap> <tmp-prefix> — reads one run's failing
# ids into <tmp-prefix>.ids. Sets _EMB_SIDE (known | unknown), _EMB_NOTE (the
# run line's tail) and _EMB_UNKNOWN (the unknown: line, or empty).
_emb_side() {
  local repo="$1" run="$2" cap="$3" pf="$4" id c fj n=0 j r=0
  id=$(jq -r '.id' <<<"$run"); c=$(jq -r '.conclusion' <<<"$run")
  : > "$pf.ids"; _EMB_SIDE=known; _EMB_NOTE=""; _EMB_UNKNOWN=""
  case "$c" in failure|timed_out) ;; *) return 0 ;; esac
  if ! _emb_get "repos/$repo/actions/runs/$id/jobs" "$pf.jobs" \
     || ! fj=$(jq -er '[.jobs[]? | select(.conclusion == "failure" or .conclusion == "timed_out") | .id] | map(tostring) | join(" ")' "$pf.jobs" 2>/dev/null); then
    _EMB_SIDE=unknown; _EMB_UNKNOWN="run $id failed and its jobs could not be read (${_EMB_WHY:-wrong shape})"; return 0
  fi
  for j in $fj; do
    n=$((n + 1))
    [ "$r" -lt "$cap" ] || continue
    if _emb_get "repos/$repo/actions/jobs/$j/logs" "$pf.log"; then
      r=$((r + 1)); _emb_ids "$pf.log" >> "$pf.ids"
    else
      _EMB_NOTE="${_EMB_NOTE:+$_EMB_NOTE; }job $j log COULD NOT READ ($_EMB_WHY)"
    fi
  done
  LC_ALL=C sort -u "$pf.ids" > "$pf.ids.s" && mv -f "$pf.ids.s" "$pf.ids"
  local all; all=$(grep -c . "$pf.ids" 2>/dev/null); all="${all:-0}"
  if [ "$all" -gt "$EMB_MAX_IDS" ]; then
    head -n "$EMB_MAX_IDS" "$pf.ids" > "$pf.ids.s" && mv -f "$pf.ids.s" "$pf.ids"
    _EMB_NOTE="${_EMB_NOTE:+$_EMB_NOTE; }first $EMB_MAX_IDS of $all spec ids kept"
  fi
  [ "$n" -gt "$r" ] && _EMB_NOTE="${_EMB_NOTE:+$_EMB_NOTE; }$r of $n failed jobs read"
  if [ ! -s "$pf.ids" ]; then
    _EMB_SIDE=unknown; _EMB_UNKNOWN="run $id failed and no spec ids were read"
  fi
  return 0
}

_emb_runline() { # _emb_runline <side> <run-json> <ids-file> <note>
  local n; n=$(grep -c . "$3" 2>/dev/null); n="${n:-0}"
  jq -r --arg side "$1" --arg n "$n" --arg note "$4" \
    '"\($side): \(.name) run \(.id) (\(.event), \(.head_sha[0:8]), \(.created_at)) \(.conclusion); \($n) failing spec(s)" + (if $note == "" then "" else "; " + $note end)' <<<"$2"
}

_emb_list() { # _emb_list <heading> <ids>
  printf '%s\n' "$1"
  if [ -n "$2" ]; then sed 's/^/  - /' <<<"$2"; else printf '  (none)\n'; fi
}

emb_section() {
  local repo="${1:-}" sha="${2:-}" p="${3:-}" tmp mrun hrun hread hwhy mruns path r fcount cap mknown hknown mnote hnote munk hunk pre reg
  EMB_STATE=unknown; _EMB_CALLS=0; _EMB_WHY=""
  if ! _emb_deps; then
    echo 'COULD NOT READ: bin/lib/e2e-paths.sh or bin/lib/gh-rest.sh is not loaded (tool failure, not "no failures").'; return 0
  fi
  if command -v rl_e2e_ratchet_on >/dev/null 2>&1 && ! rl_e2e_ratchet_on "$p"; then
    EMB_STATE=off; echo 'off (review.e2e_ratchet=0)'; return 0
  fi
  _emb_knobs "$p"
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "COULD NOT READ: bad repo or head sha ('$repo' '$sha')"; return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/emb.XXXXXX") || { echo 'COULD NOT READ: no temp dir'; return 0; }
  echo 'source: GitHub Actions REST, completed runs whose workflow name is E2E-class (bin/lib/e2e-paths.sh E2E_CHECK_RE); main = event push or schedule (nightly)'
  if ! _emb_get "repos/$repo/actions/runs?branch=main&status=completed&per_page=$EMB_MAX_RUNS" "$tmp/main.json" \
     || ! mruns=$(jq -ec --arg re "$E2E_CHECK_RE" '[.workflow_runs | arrays | .[]
          | select((.event == "push" or .event == "schedule") and ((.name // "") | test($re; "i"))
                   and (.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out"))]' "$tmp/main.json" 2>/dev/null); then
    echo "main: COULD NOT READ (${_EMB_WHY:-wrong shape})"
    echo 'comparison: not possible; judge an E2E failure from the PR body and thread (checklist item 17)'
    rm -rf "$tmp"; return 0
  fi
  if [ "$(jq 'length' <<<"$mruns")" = 0 ]; then
    EMB_STATE=none; echo 'none: no E2E-class workflow run on main in the last '"$EMB_MAX_RUNS"' completed runs'
    rm -rf "$tmp"; return 0
  fi
  hrun=""; hread=0; hwhy=""
  if _emb_get "repos/$repo/actions/runs?head_sha=$sha&status=completed&per_page=$EMB_MAX_RUNS" "$tmp/head.json" \
     && jq -e '.workflow_runs | arrays' "$tmp/head.json" >/dev/null 2>&1; then
    hread=1
    hrun=$(jq -c --arg re "$E2E_CHECK_RE" --arg s "$sha" '[.workflow_runs[]
          | select((.head_sha // "" | startswith($s)) and ((.name // "") | test($re; "i"))
                   and (.conclusion == "success" or .conclusion == "failure" or .conclusion == "timed_out"))] | .[0] // empty' "$tmp/head.json" 2>/dev/null)
  else
    hwhy="${_EMB_WHY:-wrong shape}"
  fi
  path=""; [ -n "$hrun" ] && path=$(jq -r '.path // ""' <<<"$hrun")
  mrun=$(jq -c --arg p "$path" '(map(select($p != "" and .path == $p)) + .) | .[0]' <<<"$mruns")
  fcount=0
  for r in "$mrun" "$hrun"; do
    [ -n "$r" ] && case "$(jq -r '.conclusion' <<<"$r")" in failure|timed_out) fcount=$((fcount + 1)) ;; esac
  done
  cap=$EMB_MAX_JOBS; [ "$fcount" -ge 2 ] && cap=$(( EMB_MAX_JOBS / 2 )); [ "$cap" -ge 1 ] || cap=1
  _emb_side "$repo" "$mrun" "$cap" "$tmp/m"; mknown=$_EMB_SIDE; mnote=$_EMB_NOTE; munk=$_EMB_UNKNOWN
  _emb_runline main "$mrun" "$tmp/m.ids" "$mnote"
  hknown=""; hunk=""
  if [ -n "$hrun" ]; then
    _emb_side "$repo" "$hrun" "$cap" "$tmp/h"; hknown=$_EMB_SIDE; hnote=$_EMB_NOTE; hunk=$_EMB_UNKNOWN
    _emb_runline head "$hrun" "$tmp/h.ids" "$hnote"
  elif [ "$hread" = 1 ]; then
    echo "head: no completed E2E-class run for ${sha:0:8} in the last $EMB_MAX_RUNS completed runs"
  else
    echo "head: COULD NOT READ ($hwhy)"
  fi
  [ -n "$munk" ] && echo "unknown: main $munk"
  [ -n "$hunk" ] && echo "unknown: head $hunk"
  if [ "$mknown" = known ] && [ "$hknown" = known ]; then
    pre=$(LC_ALL=C comm -12 "$tmp/m.ids" "$tmp/h.ids")
    reg=$(LC_ALL=C comm -13 "$tmp/m.ids" "$tmp/h.ids")
    _emb_list 'pre-existing (red on main and head):' "$pre"
    _emb_list 'regression (red on head, not on main):' "$reg"
    case "$mnote" in *"failed jobs read"*|*"spec ids kept"*|*"COULD NOT READ"*) echo 'note: not every failing spec on main was read; a regression id may be red on main too.' ;; esac
    EMB_STATE=yes
  elif [ -n "$hrun" ] || [ "$hread" = 0 ] || [ "$mknown" != known ]; then
    echo 'comparison: not possible; judge an E2E failure from the PR body and thread (checklist item 17)'
  else
    # Main was read, the head has no E2E-class run: nothing to compare.
    EMB_STATE=yes
  fi
  rm -rf "$tmp"
  return 0
}

# emb_prompt_file <repo> <head-sha> <project> <out> — the `## Main E2E` body
# for bin/lead-review.sh review_one: writes emb_section to <out> (stderr to
# $LOG when set) and logs one `<key>: main e2e <state>` line through `log` when
# the caller has one. rc 0 on every path but a missing <out> argument.
emb_prompt_file() {
  local repo="${1:-}" sha="${2:-}" p="${3:-}" out="${4:-}"
  [ -n "$out" ] || return 1
  emb_section "$repo" "$sha" "$p" > "$out" 2>>"${LOG:-/dev/null}"
  command -v log >/dev/null 2>&1 && log "${key:-$repo@${sha:0:8}}: main e2e ${EMB_STATE:-unknown}"
  return 0
}
