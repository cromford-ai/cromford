#!/bin/bash
# bin/lib/ci-test-value/rules.d/20-flake.sh — rule group flake F1. Owner: BH-6618.1.
#   F1.same-head-green  the same workflow went green on the same head sha:
#     a) a run in `runs?head_sha=` with the row's workflow id, status completed,
#        conclusion success, and another run id or a later attempt of this run;
#     b) the row's job name with conclusion success on another attempt of this
#        run (attempts up to the latest completed one, at most 5 read).
#   A cancelled, skipped or neutral conclusion is not green.
#
# It also holds the rule read helper, which 50-main-flake.sh uses too.
#
# THE RULE READ LEDGER. ctv_classify_row runs each rule in `$( )`, so a read in
# a rule never reaches the driver's CTV_GH_READS. _ctv_rr_get appends one line
# per network read to <out>/.rules-scratch/<runid>/reads and adds that count to
# CTV_GH_READS before each read, so ctv_gh_get's --max-reads check sees every
# rule read of the run. coverage.gh_reads stays the driver's own count.

# _ctv_rr_dir — print this run's scratch dir, <out>/.rules-scratch/<runid>.
# runid = the driver's pid ($$ in every rule subshell) and its start time, so a
# reused pid is a new run. The first creation in a run removes every other
# runid dir. rc 1 when there is no CTV_OUT or the dir cannot be made.
_ctv_rr_dir() {
  local base st d x
  [ -n "${CTV_OUT:-}" ] || return 1
  st=$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | cut -d' ' -f20)
  [ -n "$st" ] || st=$(ps -o lstart= -p "$$" 2>/dev/null | tr -cd '0-9A-Za-z')
  [ -n "$st" ] || return 1
  base="$CTV_OUT/.rules-scratch"; d="$base/$$-$st"
  if [ ! -d "$d/memo" ]; then
    mkdir -p "$d/memo" 2>/dev/null || return 1
    for x in "$base"/*; do [ "$x" = "$d" ] || rm -rf "$x"; done
  fi
  printf '%s\n' "$d"
}

# _ctv_rr_get <api-path> <cache-key|-> <memo-name> — one JSON read for a rule,
# body on stdout. rc 0 read, 44 absent, 75 unread. The per-run memo answers a
# repeat without a read (a `.rc` memo replays 44 or 75). A body that is not
# JSON is 75 and its cache file is removed. Run it as a plain command.
_ctv_rr_get() {
  local p="${1:-}" key="${2:-}" memo="${3:-}" d m n base rc=0
  [ -n "$p" ] && [ -n "$key" ] && [[ "$memo" =~ ^[A-Za-z0-9._-]+$ ]] || return 75
  d=$(_ctv_rr_dir) || return 75
  m="$d/memo/$memo"
  if [ -f "$m.rc" ]; then rc=$(cat "$m.rc"); return "${rc:-75}"; fi
  if [ -f "$m" ]; then cat "$m"; return 0; fi
  n=0; [ -f "$d/reads" ] && n=$(grep -c . "$d/reads")
  base=${CTV_GH_READS:-0}
  local CTV_GH_READS=$((base + n))
  ctv_gh_get "$p" "$key" > "$m.tmp" || rc=$?
  [ "$CTV_GH_READS" -gt $((base + n)) ] && printf '%s\n' "$p" >> "$d/reads"
  if [ "$rc" = 0 ] && ! jq -e . "$m.tmp" >/dev/null 2>&1; then
    rc=75
    [ "$key" = - ] || rm -f "$CTV_OUT/cache/$key"
  fi
  case "$rc" in
    0) mv -f "$m.tmp" "$m" && cat "$m"; return 0 ;;
    44) rm -f "$m.tmp"; echo 44 > "$m.rc"; return 44 ;;
    *) rm -f "$m.tmp"; echo 75 > "$m.rc"; return 75 ;;
  esac
}

ctv_rule_flake() {
  local R="${CTV_REPO:-}" sha="${CTV_HEAD_SHA:-}" W="${CTV_WORKFLOW_ID:-}" run="${CTV_RUN_ID:-}" A="${CTV_ATTEMPT:-}"
  local d f hit M n tried=0
  [ -n "${CTV_OUT:-}" ] && [[ "$R" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
    && [[ "$W" =~ ^[0-9]+$ ]] && [[ "$run" =~ ^[0-9]+$ ]] && [[ "$A" =~ ^[0-9]+$ ]] || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/f1.$BASHPID.json"
  M=$A
  # a) another green run, or a later green attempt of this run, on the same head.
  if _ctv_rr_get "repos/$R/actions/runs?head_sha=$sha&per_page=100" - "f1-head-$sha" > "$f"; then
    hit=$(jq -r --argjson w "$W" --arg sha "$sha" --argjson run "$run" --argjson a "$A" '
      [.workflow_runs[]? | select(.workflow_id == $w and .head_sha == $sha and .status == "completed"
        and .conclusion == "success" and (.id != $run or .run_attempt > $a))] | first // empty
      | "\(.id) \(.run_attempt)"' "$f" 2>/dev/null)
    if [ -n "$hit" ]; then
      rm -f "$f"
      printf 'flake\tF1.same-head-green\trun %s attempt %s green on the same head\n' "${hit% *}" "${hit#* }"
      return 0
    fi
    n=$(jq -r --argjson w "$W" --arg sha "$sha" --argjson run "$run" '
      [.workflow_runs[]? | select(.id == $run and .workflow_id == $w and .head_sha == $sha and .status == "completed")
        | .run_attempt] | first // empty' "$f" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && M=$n
  fi
  # b) the same job green on another attempt of this run, latest attempt first.
  if [ -n "${CTV_JOB_NAME:-}" ]; then
    for ((n = M; n >= 1 && tried < 5; n--)); do
      [ "$n" = "$A" ] && continue
      tried=$((tried + 1))
      _ctv_rr_get "repos/$R/actions/runs/$run/attempts/$n/jobs?per_page=100&page=1" "run/$run-a$n-jobs.json" \
        "f1-jobs-$run-a$n" > "$f" || continue
      if jq -e --arg name "$CTV_JOB_NAME" 'any(.jobs[]?; .name == $name and .conclusion == "success")' "$f" >/dev/null 2>&1; then
        rm -f "$f"
        printf 'flake\tF1.same-head-green\tjob %s green on attempt %s of this run\n' "$CTV_JOB_NAME" "$n"
        return 0
      fi
    done
  fi
  rm -f "$f"
  return 1
}
