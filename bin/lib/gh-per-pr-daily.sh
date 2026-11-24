#!/bin/bash
# bin/lib/gh-per-pr-daily.sh — the daily "GitHub calls per merged PR" figure
# per repo (BH-9933, BH-9926.1). Sourced, never executed. Functions only.
#
#   gpd_run <now-epoch>
#       Once per PH_GH_PER_PR_EVERY_S, runs
#         bin/gh-ledger-report.sh --fleet --last <PH_GH_PER_PR_WINDOW_H>h --per-merged-pr --by-repo
#       under `timeout PH_GH_PER_PR_TIMEOUT_S`, writes the per_merged_pr_repo=
#       lines to state/gh-per-merged-pr.json (tmp + mv):
#         {generated_at, window_h, source:"fleet", error:null,
#          repos:[{repo, counted, merged, per_merged_pr}]}
#       (merged and per_merged_pr are strings when not numbers: ?, n/a,
#       unknown (...)), and appends one line per repo to
#       logs/pipeline-health.log:
#         <UTC> gh per merged PR (<w>h): <repo> counted=<c> merged=<m> per_merged_pr=<n>
#       A failed report (timeout, rc != 0, no repo line, a fleet `unknown`
#       line) writes repos [] and error "<why>", and one log line. generated_at
#       is set on every run, so a broken read is tried again the next day, not
#       every tick. It never alerts. Always rc 0.
#       Due: no file, a stamp that is not a number, now - stamp >= EVERY_S, or
#       a stamp more than EVERY_S in the future (the clock went back).
#
#   gpd_snap_add <state-file> <snap-json>
#       Prints <snap-json> + {gh_per_merged_pr: <file>}, rc 0, when the file
#       parses as an object. Else rc 1 and nothing printed (the caller keeps
#       its snapshot). bin/fleet-status-push.sh section 13.
#
# Knobs (catalog/lanes.d/pipeline-health.knobs.d/): PH_GH_PER_PR_EVERY_S
# (86400, 0 = off), PH_GH_PER_PR_WINDOW_H (168, 1..336), PH_GH_PER_PR_TIMEOUT_S
# (120, 10..600). A value out of range or not a whole number is the fallback
# plus one log line. Root: ${HARNESS:-${H:-}}; no root, no run.
[ -n "${_GPD_LOADED:-}" ] && return 0
_GPD_LOADED=1
_GPD_EVERY_S=86400   # fallback only: the knob is PH_GH_PER_PR_EVERY_S (catalog/lanes.d/pipeline-health.knobs.d/)
_GPD_WINDOW_H=168    # fallback only: the knob is PH_GH_PER_PR_WINDOW_H
_GPD_TIMEOUT_S=120   # fallback only: the knob is PH_GH_PER_PR_TIMEOUT_S

_gpd_log() { # _gpd_log <root> <text>
  mkdir -p "$1/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" >> "$1/logs/pipeline-health.log" 2>/dev/null || true
}

# _gpd_knob <root> <ENV> <fallback> <min> <max> — a whole number in range.
_gpd_knob() {
  local v="${!2:-}"
  [ -n "$v" ] || { printf '%s' "$3"; return 0; }
  if ! [[ "$v" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$v))" -lt "$4" ] || [ "$((10#$v))" -gt "$5" ]; then
    _gpd_log "$1" "$2='$v' is not a whole number in $4..$5 — using $3"
    printf '%s' "$3"; return 0
  fi
  printf '%s' "$((10#$v))"
}

gpd_run() {
  local now="${1:-}" root="${HARNESS:-${H:-}}" every win to st gen age out rc why="" tsv tmp
  [ -n "$root" ] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  every=$(_gpd_knob "$root" PH_GH_PER_PR_EVERY_S "$_GPD_EVERY_S" 0 604800)
  [ "$every" = 0 ] && return 0
  st="$root/state/gh-per-merged-pr.json"
  gen=$(jq -r '.generated_at // empty' "$st" 2>/dev/null)
  if [[ "$gen" =~ ^[0-9]+$ ]]; then
    age=$(( now - gen ))
    [ "$age" -lt "$every" ] && [ "$age" -ge "$(( -every ))" ] && return 0
  fi
  win=$(_gpd_knob "$root" PH_GH_PER_PR_WINDOW_H "$_GPD_WINDOW_H" 1 336)
  to=$(_gpd_knob "$root" PH_GH_PER_PR_TIMEOUT_S "$_GPD_TIMEOUT_S" 10 600)
  out=$(timeout "$to" "$root/bin/gh-ledger-report.sh" --fleet --last "${win}h" --per-merged-pr --by-repo 2>/dev/null); rc=$?
  # repo<TAB>counted<TAB>merged<TAB>per_merged_pr, from the report's lines.
  tsv=$(printf '%s\n' "$out" | sed -nE \
    -e 's/^per_merged_pr_repo=([^ ]+) counted=([^ ]+) merged=([^ ]+) per_merged_pr=(.+)$/\1\t\2\t\3\t\4/p' \
    -e 's/^per_merged_pr_repo=(\(other\)) counted=([0-9]+)$/\1\t\2\t\t/p')
  if [ "$rc" = 124 ]; then why="timeout after ${to}s"
  elif [ "$rc" != 0 ]; then why="report rc=$rc"
  elif grep -q '^per_merged_pr_repo=unknown (' <<<"$out"; then
    why=$(sed -n 's/^per_merged_pr_repo=\(unknown (.*)\)$/\1/p' <<<"$out" | head -1)
  elif [ -z "$tsv" ]; then why="no repo line"
  fi
  # state/ is the harness's own dir (the hub makes it at install). A missing
  # dir makes the write below fail, and the tmp is removed: nothing is lost
  # but one daily figure.
  tmp="$st.tmp.$$"
  if [ -n "$why" ]; then
    jq -nc --argjson g "$now" --argjson w "$win" --arg e "$why" \
      '{generated_at:$g, window_h:$w, source:"fleet", error:$e, repos:[]}' > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$st" 2>/dev/null || rm -f "$tmp"
    _gpd_log "$root" "gh per merged PR (${win}h): $why"
    return 0
  fi
  printf '%s\n' "$tsv" | jq -Rsc --argjson g "$now" --argjson w "$win" '
    def val: if test("^[0-9]+$") then tonumber elif . == "" then null else . end;
    {generated_at:$g, window_h:$w, source:"fleet", error:null,
     repos: [split("\n")[] | select(length > 0) | split("\t")
             | {repo: .[0], counted: (.[1] | val), merged: (.[2] | val), per_merged_pr: (.[3] | val)}]}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$st" 2>/dev/null || rm -f "$tmp"
  while IFS=$'\t' read -r r c m n; do
    [ -n "$r" ] || continue
    if [ -n "$m" ]; then _gpd_log "$root" "gh per merged PR (${win}h): $r counted=$c merged=$m per_merged_pr=$n"
    else _gpd_log "$root" "gh per merged PR (${win}h): $r counted=$c"
    fi
  done <<<"$tsv"
  return 0
}

gpd_snap_add() {
  local f="${1:-}" snap="${2:-}" out
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 1
  out=$(jq -c --slurpfile g "$f" '. + {gh_per_merged_pr: $g[0]}' <<<"$snap" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
