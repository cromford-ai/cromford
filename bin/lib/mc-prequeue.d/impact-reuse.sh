#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/impact-reuse.sh — A GREEN VERDICT STAYS GREEN WHEN MAIN
# MOVED SOMEWHERE THE PR CANNOT SEE (BH-6924). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source
# time.
#
# WHY. pq_resolve reuses an older main's verdict only inside FRESH_S and
# FRESH_COMMITS. Main moves many times an hour, so most READY heads paid for a
# second prequeue run whose answer could not differ: the new main commits
# touched nothing the PR's suites read.
#
# THE RULE (knob MC_PREQUEUE_IMPACT_REUSE, default 1; MC_PREQUEUE_REUSE=0 turns
# it off too). Asked by pq_resolve after the fresh rules found nothing and no
# sibling run is pending, before the dispatch veto. Harness repo only
# (HARNESS_REPO): only that repo has the impact map. The candidate is the
# newest terminal entry for this (PR, head) on an older main, by the time it
# was read (mtime), dispatched at or after PQ_MIN_AT and less than
# MC_PREQUEUE_IMPACT_MAX_S ago. It must be green or no-selection; a newer red,
# conflict or could-not-run is never stepped over. Then:
#   - the main move's files come from ONE compare read <verdict-main>...<main>
#     (status ahead, 1..299 files; anything else is unusable);
#   - the PR's files come from mc_pr_files;
#   - each list goes through bin/test-impact.sh select --why as a batch select
#     (TI_BATCH_SELECT=1, the rules bin/lib/mc-batch-impact.sh uses);
#   - a .github/workflows/ path on either side is `full` (BH-6876: the batch
#     select narrows it to its readers, the reuse does not);
#   - either side `full`, a shared file or a shared suite (`always` rows and a
#     regression `*` row excluded: every diff reaches them): dispatch;
#   - disjoint: the merge test. Clean: the candidate's line is written as the
#     entry for (head, current main), with a `.reuse` sidecar
#     `reused-from main=<vm> run=<id> commits=<n> files=<k> reason=impact-disjoint`,
#     and the answer is reuse. Conflict: rebase. A busy git lock: busy, and
#     pq_resolve holds (BH-7376: never a dispatch the reuse may cover). Any
#     other no-answer: dispatch.
# Any read, map or select that fails answers dispatch, never reuse. One
# `PREQUEUE reuse ... -> impact-<word> (<why>)` line per decision on a
# candidate. The word is in _pq_ir: reuse, rebase, busy, dispatch or none.
#
#   pq_ir_root                     the checkout the map is built in, or rc 1
#   pq_ir_map <root>               the map path, built once per tick and root sha
#   pq_ir_reach <files> <map> <root>   the suites, or `*`; rc 1 unknown
#   pq_impact_reuse <slug> <num> <url> <head> <main> <pre>

# pq_ir_root — _bim_root's answer (a checkout with bin/test-impact.sh and a
#   tests/ dir), else _fr_ti_root's under the same test. rc 1 when none.
pq_ir_root() {
  local r=""
  if declare -F _bim_root >/dev/null; then r=$(_bim_root 2>/dev/null)
  elif declare -F _fr_ti_root >/dev/null; then r=$(_fr_ti_root 2>/dev/null); fi
  [ -n "$r" ] && [ -f "$r/bin/test-impact.sh" ] && [ -d "$r/tests" ] || return 1
  printf '%s\n' "$r"
}

# pq_ir_map <root> — the map path. MC_PREQUEUE_IMPACT_MAP replaces it under
#   HARNESS_TEST_SANDBOX=1 only. rc 1 when it cannot be built or is empty.
pq_ir_map() {
  local root="$1" sha m
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MC_PREQUEUE_IMPACT_MAP:-}" ]; then
    [ -s "$MC_PREQUEUE_IMPACT_MAP" ] || return 1
    printf '%s\n' "$MC_PREQUEUE_IMPACT_MAP"; return 0
  fi
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] || return 1
  sha=$(git -C "$root" rev-parse HEAD 2>/dev/null) || return 1
  m="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-ti-map.${sha:0:12}"
  if [ ! -s "$m" ]; then
    mkdir -p "$MC_TICK_DIR" 2>/dev/null || return 1
    bash "$root/bin/test-impact.sh" map --root "$root" --out "$m.tmp.$$" >/dev/null 2>&1 \
      && [ -s "$m.tmp.$$" ] && mv -f "$m.tmp.$$" "$m" 2>/dev/null || { rm -f "$m.tmp.$$"; return 1; }
  fi
  printf '%s\n' "$m"
}

# pq_ir_reach <files> <map> <root> — `*` for any `full` row (its reason goes to
#   <files>.full), else the suites the files reach whose kind is not `always`
#   and whose row is not a regression `*` row, plus each tests/*.sh path in the
#   list (BH-5373), sorted and unique. rc 1 when the list is empty or the
#   select fails or answers nothing.
pq_ir_reach() {
  local files="$1" map="$2" root="$3" rows rc=0
  [ -s "$files" ] || return 1
  rm -f "$files.full"
  # A .github/workflows/ path is full here (BH-6876). A batch select narrows a
  # workflow edit to its readers, but a green verdict from an older workflow
  # says nothing about the new one, so a reuse never steps over one.
  rows=$(grep -m1 -E '^\.github/workflows/' "$files" 2>/dev/null) && {
    printf 'full: infra change (%s)\n' "$rows" > "$files.full" 2>/dev/null || :
    echo '*'; return 0
  }
  rows=$(TI_BATCH_SELECT=1 bash "$root/bin/test-impact.sh" select --why --changed "$files" --map "$map" --root "$root" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] && [ -n "$rows" ] || return 1
  if awk -F'\t' '$2 == "full" { f = 1 } END { exit !f }' <<<"$rows"; then
    awk -F'\t' '$2 == "full" { print $3; exit }' <<<"$rows" > "$files.full" 2>/dev/null || :
    echo '*'; return 0
  fi
  { awk -F'\t' '$1 != "" && $2 != "always" && !($2 == "regression" && $3 == "*") { print $1 }' <<<"$rows"
    grep -E '^tests/(mc/)?[^/]+\.sh$' "$files" || :; } | LC_ALL=C sort -u
}

# pq_impact_reuse <slug> <num> <url> <head> <main> <pre> — sets _pq_ir (see
#   the header); a rebase also sets PQ_WHY.
pq_impact_reuse() {
  local slug="$1" num="$2" url="$3" head="$4" main="$5" pre="$6"
  local f m st at id rest vt now max bvt=-1 bst="" bm="" bat="" bid="" bsu="" age
  local root map w raw n k hit mt mrc path lk rc=0
  _pq_ir=none
  [ "$(pq_knob MC_PREQUEUE_IMPACT_REUSE)" = 1 ] && [ "$(pq_knob MC_PREQUEUE_REUSE)" != 0 ] || return 0
  [ -n "$slug" ] && [ "$slug" = "${HARNESS_REPO:-}" ] || return 0
  root=$(pq_ir_root) || return 0
  now=$(date +%s); max=$(pq_knob MC_PREQUEUE_IMPACT_MAX_S)
  for f in "$pre"*; do
    m="${f#"$pre"}"; [[ "$m" =~ ^[0-9a-f]{40}$ ]] && [ "$m" != "$main" ] || continue
    read -r st at id rest <<<"$(pq_cache_get "$f")"
    case "$st" in green|no-selection|red|conflict|could-not-run) ;; *) continue ;; esac
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ "${PQ_MIN_AT:-0}" -gt 0 ] 2>/dev/null && [ "$at" -lt "$PQ_MIN_AT" ] && continue
    [ $((now - at)) -lt "$max" ] || continue
    vt=$(stat -c %Y "$f" 2>/dev/null); case "$vt" in ''|*[!0-9]*) continue ;; esac
    [ "$vt" -gt "$bvt" ] && { bvt="$vt"; bst="$st"; bm="$m"; bat="$at"; bid="$id"; bsu="$rest"; }
  done
  [ -n "$bm" ] || return 0
  age=$((now - bvt))
  _pq_ir_log() { pq_reuse_log "$num" "$head" "$bm" "$main" "$age" "$bst" "impact-$_pq_ir ($1)"; }
  case "$bst" in green|no-selection) ;; *) _pq_ir=none; _pq_ir_log "the newest verdict is $bst"; return 0 ;; esac
  _pq_ir=dispatch
  map=$(pq_ir_map "$root") || { _pq_ir_log "no impact map"; return 0; }
  w=$(mktemp -d "${TMPDIR:-/tmp}/pq-ir.XXXXXX" 2>/dev/null) || { _pq_ir_log "no temp dir"; return 0; }
  # The main move: one compare read. A list GitHub capped (300) is not complete.
  if ! mc_rest_var raw gh_rest GET "repos/$slug/compare/$bm...$main"; then
    rm -rf "$w"; _pq_ir_log "compare-unusable: unreadable"; return 0
  fi
  read -r st n k <<<"$(jq -r '"\(.status // "-") \(.ahead_by // "-") \(.files // [] | length)"' <<<"$raw" 2>/dev/null)"
  jq -r '.files[]? | .filename // empty, .previous_filename // empty' <<<"$raw" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u > "$w/main.files"
  if [ "$st" != ahead ] || [[ ! "$k" =~ ^[0-9]+$ ]] || [ "$k" -lt 1 ] || [ "$k" -ge 300 ] || [ ! -s "$w/main.files" ]; then
    rm -rf "$w"; _pq_ir_log "compare-unusable: status=${st:--} files=${k:--}"; return 0
  fi
  if ! mc_rest_var raw mc_pr_files "$slug" "$num" "$url" "$head" || [ -z "$raw" ]; then
    rm -rf "$w"; _pq_ir_log "pr-files-unreadable"; return 0
  fi
  printf '%s\n' "$raw" | sed '/^$/d' | LC_ALL=C sort -u > "$w/pr.files"
  if ! pq_ir_reach "$w/main.files" "$map" "$root" > "$w/main.reach"; then rm -rf "$w"; _pq_ir_log "main-reach-unknown"; return 0; fi
  if [ "$(cat "$w/main.reach")" = '*' ]; then
    hit=$(head -n1 "$w/main.files.full" 2>/dev/null); rm -rf "$w"; _pq_ir_log "main-full: ${hit:-full}"; return 0
  fi
  if ! pq_ir_reach "$w/pr.files" "$map" "$root" > "$w/pr.reach"; then rm -rf "$w"; _pq_ir_log "pr-reach-unknown"; return 0; fi
  if [ "$(cat "$w/pr.reach")" = '*' ]; then
    hit=$(head -n1 "$w/pr.files.full" 2>/dev/null); rm -rf "$w"; _pq_ir_log "pr-full: ${hit:-full}"; return 0
  fi
  hit=$(LC_ALL=C comm -12 "$w/main.files" "$w/pr.files" | head -n1)
  [ -z "$hit" ] && hit=$(LC_ALL=C comm -12 "$w/main.reach" "$w/pr.reach" | head -n1)
  if [ -n "$hit" ]; then rm -rf "$w"; _pq_ir_log "impact-hit $hit"; return 0; fi
  rm -rf "$w"
  mt=$(pq_merge_test "$slug" "$num" "$head"); mrc=$?
  case "$mrc" in
    1) _pq_ir=rebase; PQ_WHY="head ${head:0:8} conflicts with main ${main:0:12}: ${mt:-paths not named}"
       _pq_ir_log "disjoint, conflict"; return 0 ;;
    0) ;;
    3) _pq_ir=busy; PQ_WHY="prequeue impact-reuse merge test not run: ${mt:-the git lock was busy}; asked next run"
       _pq_ir_log "merge-test-busy: $mt"; return 0 ;;
    *) _pq_ir_log "merge-test-unanswered: $mt"; return 0 ;;
  esac
  # Write before answer, under the pq_dispatch lock and only into an empty
  # entry: a reuse without a record cannot happen.
  path="$pre$main"
  lk="$MC_H/locks/prequeue-${slug//\//_}-$num-$head.lock"
  mkdir -p "${lk%/*}" 2>/dev/null; { : >> "$lk"; } 2>/dev/null || { _pq_ir_log "lock unwritable"; return 0; }
  (
    flock -n 9 || exit 3
    [ -n "$(pq_cache_get "$path")" ] && exit 3
    printf 'reused-from main=%s run=%s commits=%s files=%s reason=impact-disjoint\n' "$bm" "${bid:--}" "$n" "$k" > "$path.reuse.tmp.$$" 2>/dev/null \
      && mv -f "$path.reuse.tmp.$$" "$path.reuse" 2>/dev/null || { rm -f "$path.reuse.tmp.$$"; exit 4; }
    pq_cache_put "$path" "$bst" "$bat" "$bid" "$bsu" || { rm -f "$path.reuse"; exit 4; }
    exit 0
  ) 9>"$lk" || rc=$?
  case "$rc" in
    0) _pq_ir=reuse; _pq_ir_log "disjoint, commits=$n files=$k" ;;
    3) _pq_ir_log "the entry is in another worker's hands" ;;
    *) _pq_ir_log "the reused entry could not be written" ;;
  esac
  return 0
}
