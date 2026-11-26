#!/bin/bash
# bin/lib/selection-gate-retry.sh — step 7 of bin/selection-gate.sh (BH-9779):
# one retry for reds outside this change's impact set. Sourced by
# bin/selection-gate.sh, never executed.
#
# WHY. BH-9718 went to NEEDS-HUMAN after 3 builds, each red on a different
# suite its diff does not reach (tests/headbound-outcome-test.sh,
# tests/fixround-closure-lint.bh-5064-test.sh). A red the diff cannot reach,
# that passes when it runs again, is a flake, not this change's red.
#
# sgr7_retry — called after step 6 with SELECTION_GATE_RETRY_OUTSIDE=1 and a
#   non-empty `keep`. It reads keep, TREE, MB, HEAD_SHA, RUNNER, PAR, OUT, H,
#   REPO_SLUG, SGR7_TO and SGR7_MAX; it rewrites keep and sets RETRY_LINE
#   (gate.txt `retry:`).
#   1. The impact set: `${SELECTION_GATE_IMPACT:-$TREE/bin/test-impact.sh}
#      select --why --map-only --changed <git diff --name-only MB HEAD>`, run
#      in TREE. A suite is INSIDE when a row of kind self, reads, named,
#      source, learned, closure or regression names it. A `full` row, a failed
#      command (rc != 0) or no tab-separated row: every red is inside.
#   2. Any red inside: no retry (`skipped: inside <n>`). More outside reds than
#      SGR7_MAX: no retry (`skipped: <n> > <max>`).
#   3. One run: `REMOTE_GATE_P=$PAR timeout -k 30 $SGR7_TO $RUNNER $TREE
#      <the outside reds>`, output in $OUT/retry-run.txt. The timeout, an rc of
#      124 or more, or a RUNNER-FAILURE line: `could-not-run: <why>`, and every
#      red stays red. Else each suite is classified by bl_class (bin/selection-
#      gate.sh): green only on a `PASS <suite>` line and nothing else for it.
#   4. Each green suite leaves keep and gets one ci_flakes row:
#      `bin/jobs-client.sh metric-flake <REPO_SLUG> selection-gate <suite>
#      <head> "" flake` (an upsert on repo, workflow, test, head; the day is the
#      worker's). No REPO_SLUG, no client or rc != 0 adds ` flake-record:
#      failed <suite>`; the green stands, because the verdict rests on the run.
#   RETRY_LINE: `ran <n>: green <list|->; red <list|->[ flake-record: ...]`.
[ -n "${_SGR7_LIB_LOADED:-}" ] && return 0
_SGR7_LIB_LOADED=1

# _sgr7_join <item…> — comma-joined, `-` when none.
_sgr7_join() { if [ "$#" -gt 0 ]; then (IFS=,; printf '%s' "$*"); else printf -- -; fi; }

# sgr7_outside <changed-file> — prints the reds of keep that are outside the
#   impact set, one a line. rc 1 (and SGR7_WHY set) when every red is inside.
sgr7_outside() {
  local ch="$1" imp rows irc=0 s kind inside=0
  local -A in=()
  local -a out=()
  SGR7_WHY=""
  imp="${SELECTION_GATE_IMPACT:-$TREE/bin/test-impact.sh}"
  rows=$(cd "$TREE" && "$imp" select --why --map-only --changed "$ch" 2>/dev/null) || irc=$?
  if [ "$irc" != 0 ] || ! grep -q $'\t' <<<"$rows" || awk -F'\t' '$2 == "full" { f = 1 } END { exit !f }' <<<"$rows"; then
    SGR7_WHY="inside ${#keep[@]} (impact set unreadable or full)"; return 1
  fi
  while IFS=$'\t' read -r s kind _; do
    case "$kind" in self|reads|named|source|learned|closure|regression) in[$s]=1 ;; esac
  done <<<"$rows"
  for s in "${keep[@]}"; do
    if [ -n "${in[$s]:-}" ]; then inside=$((inside + 1)); else out+=("$s"); fi
  done
  [ "$inside" = 0 ] || { SGR7_WHY="inside $inside"; return 1; }
  printf '%s\n' "${out[@]}"
}

# sgr7_flake_put <suite> — one ci_flakes row; rc != 0 when it was not written.
sgr7_flake_put() {
  [ -n "${REPO_SLUG:-}" ] && [ -r "$H/bin/jobs-client.sh" ] || return 1
  bash "$H/bin/jobs-client.sh" metric-flake "$REPO_SLUG" selection-gate "$1" "$HEAD_SHA" "" flake >/dev/null 2>&1
}

sgr7_retry() {
  local ch s v tok rrc=0 t0 el sfx=""
  local -a out=() green=() red=() still=()
  ch="$OUT/retry-changed.txt"
  if ! git -C "$TREE" diff --name-only "$MB" HEAD > "$ch" 2>/dev/null; then
    RETRY_LINE="skipped: inside ${#keep[@]} (no diff)"; return 0
  fi
  # Into a file, not a process substitution, so SGR7_WHY and the rc stay here.
  if ! sgr7_outside "$ch" > "$OUT/retry-outside.txt"; then
    RETRY_LINE="skipped: ${SGR7_WHY:-inside ${#keep[@]}}"; return 0
  fi
  mapfile -t out < <(grep -v '^$' "$OUT/retry-outside.txt")
  [ "${#out[@]}" -gt 0 ] || { RETRY_LINE="skipped: inside ${#keep[@]}"; return 0; }
  if [ "${#out[@]}" -gt "$SGR7_MAX" ]; then RETRY_LINE="skipped: ${#out[@]} > $SGR7_MAX"; return 0; fi
  t0=$SECONDS
  # -k 30: the same kill grace as the main run (step 3) and the base run (step 6).
  REMOTE_GATE_P="$PAR" timeout -k 30 "$SGR7_TO" "$RUNNER" "$TREE" "${out[@]}" > "$OUT/retry-run.txt" 2>&1 || rrc=$?
  el=$((SECONDS - t0)); tok=""
  if [ "$el" -ge "$SGR7_TO" ] && [ "$rrc" != 0 ]; then tok=timeout
  elif [ "$rrc" -gt 123 ]; then tok="runner-rc-$rrc"
  elif grep -q '^RUNNER-FAILURE ' "$OUT/retry-run.txt" 2>/dev/null; then tok=runner-failure
  fi
  if [ -n "$tok" ]; then RETRY_LINE="could-not-run: $tok"; return 0; fi
  for s in "${out[@]}"; do
    v=$(bl_class "$OUT/retry-run.txt" "$s")
    if [ "$v" = green ]; then green+=("$s"); else red+=("$s"); fi
  done
  for s in ${green[@]+"${green[@]}"}; do sgr7_flake_put "$s" || sfx+=" flake-record: failed $s"; done
  for s in "${keep[@]}"; do
    case " ${green[*]-} " in *" $s "*) ;; *) still+=("$s") ;; esac
  done
  keep=(${still[@]+"${still[@]}"})
  RETRY_LINE="ran ${#out[@]}: green $(_sgr7_join ${green[@]+"${green[@]}"}); red $(_sgr7_join ${red[@]+"${red[@]}"})$sfx"
}
