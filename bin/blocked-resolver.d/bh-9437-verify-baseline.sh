# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9437-verify-baseline.sh — a fix round's verify is
# scored against current main, the next round reads the last round's verify,
# and a review park gets the rounds BR_REVIEW_FIX_ROUNDS documents (BH-9437
# item 3). Sourced by the driver's blocked-resolver.d block; functions only,
# no exit.
#
# Files, one per key, overwritten, never appended (they retire with the record):
#   $ST/<p>/<ck>.verify-baseline.txt  the typecheck + unit output of current
#                                     main, first line `MAIN <sha>`; reused
#                                     while main is the same sha
#   $ST/<p>/<ck>.fix-verify.prev.txt  the last failed round's verify output;
#                                     a green push removes it (bh-9437-rereview.sh)
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/): BR_VERIFY_ON_MAIN (1),
# BR_VERIFY_BASELINE_TIMEOUT_S (1800), BR_VERIFY_PREV_BYTES (4000).

# brlad_fail_ids <verify-file> <typecheck|unit> — the failure identities of one
#   step section, sorted and unique: `<file> TSnnnn` for tsc, `FAIL <file …>`
#   and `x <name>` for vitest/jest/node:test, `not ok <name>` for TAP. Colour
#   codes and durations are stripped, so a rerun of the same failure matches.
brlad_fail_ids() {
  local f="$1" start end
  case "$2" in
    typecheck) start='== typecheck =='; end='^TYPECHECK_EXIT:' ;;
    unit)      start='== unit =='; end='^UNIT_EXIT:' ;;
    *) return 1 ;;
  esac
  [ -r "$f" ] || return 1
  awk -v s="$start" -v e="$end" '$0 == s {f=1; next} f && $0 ~ e {exit} f' "$f" \
    | LC_ALL=C sed -E 's/\x1b\[[0-9;]*m//g' \
    | LC_ALL=C sed -nE \
        -e 's/^[[:space:]]*([^[:space:]()]+)\([0-9]+,[0-9]+\): error (TS[0-9]+).*/\1 \2/p' \
        -e 's/^[[:space:]]*([^[:space:]]+):[0-9]+:[0-9]+ - error (TS[0-9]+).*/\1 \2/p' \
        -e 's/^[[:space:]]*FAIL[[:space:]]+(.*[^[:space:]])[[:space:]]*$/FAIL \1/p' \
        -e 's/^[[:space:]]*(×|✗|✕|✖)[[:space:]]+(.*[^[:space:]])[[:space:]]*$/x \2/p' \
        -e 's/^[[:space:]]*not ok [0-9]+ (- )?(.*[^[:space:]])[[:space:]]*$/not ok \2/p' \
    | LC_ALL=C sed -E -e 's/[[:space:]]+#[[:space:]]*time=.*$//' -e 's/[[:space:]]+\(?[0-9]+(\.[0-9]+)?[[:space:]]?m?s\)?$//' \
    | LC_ALL=C sort -u
}

# brlad_vb_build <wt> <main-sha> <baseline-file> — run the round's typecheck and
#   unit commands on <main-sha> in a detached worktree, into the baseline file.
#   rc 1 with BRLAD_VB_WHY set when it cannot run or a command timed out.
#   The worktree is removed on every path.
brlad_vb_build() {
  local wt="$1" msha="$2" base="$3" tmp w to r
  BRLAD_VB_WHY=""
  # BR_VERIFY_BASELINE_TIMEOUT_S: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERIFY_BASELINE_TIMEOUT_S.json (fallback 1800)
  to=$(brlad_knob BR_VERIFY_BASELINE_TIMEOUT_S "${BR_VERIFY_BASELINE_TIMEOUT_S:-1800}" 1800 60 3600)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/br-vbase.XXXXXX") || { BRLAD_VB_WHY="mktemp failed"; return 1; }
  w="$tmp/main"
  if ! git -C "$wt" worktree add -q --detach "$w" "$msha" >/dev/null 2>&1; then
    rm -rf "$tmp"; git -C "$wt" worktree prune >/dev/null 2>&1
    BRLAD_VB_WHY="worktree add of ${msha:0:8} failed"; return 1
  fi
  [ -d "$wt/node_modules" ] && [ ! -e "$w/node_modules" ] && ln -s "$wt/node_modules" "$w/node_modules"
  # A blank line before each exit marker: an output with no final newline must
  # not swallow the marker the step sections end on.
  {
    echo "MAIN $msha"
    echo "== typecheck =="
    if grep -q '"typecheck"' "$w/package.json" 2>/dev/null; then
      ( cd "$w" && timeout "$to" npm run typecheck 2>&1 ); r=$?; echo; echo "TYPECHECK_EXIT: $r"
    else echo "TYPECHECK_EXIT: no-typecheck-script"; fi
    echo "== unit =="
    if grep -q '"test:unit"' "$w/package.json" 2>/dev/null; then
      ( cd "$w" && timeout "$to" npm run test:unit 2>&1 ); r=$?; echo; echo "UNIT_EXIT: $r"
    elif grep -q '"test"' "$w/package.json" 2>/dev/null; then
      ( cd "$w" && timeout "$to" npm test 2>&1 ); r=$?; echo; echo "UNIT_EXIT: $r"
    else echo "UNIT_EXIT: no-test-script"; fi
  } > "$base.tmp" 2>&1 </dev/null
  git -C "$wt" worktree remove --force "$w" >/dev/null 2>&1 || git -C "$wt" worktree remove --force --force "$w" >/dev/null 2>&1
  rm -rf "$tmp"; git -C "$wt" worktree prune >/dev/null 2>&1
  if grep -qE '^(TYPECHECK|UNIT)_EXIT: 124$' "$base.tmp"; then
    rm -f "$base.tmp"; BRLAD_VB_WHY="a command on main timed out after ${to}s"; return 1
  fi
  mv -f "$base.tmp" "$base" || { BRLAD_VB_WHY="the baseline file could not be written"; return 1; }
  return 0
}

# brlad_vb_rescore <p> <ck> <wt> <verify-out> <main-ref>
#   rc 0 every red step (typecheck, unit) is red on <main-ref> with the same
#        failures: the round counts as verified, and one BASELINE line per
#        step is appended to <verify-out>
#   rc 1 no change (the knob is 0, another check is red, a failure only the
#        branch has, an unparseable red step, main green, no baseline)
brlad_vb_rescore() {
  local p="$1" ck="$2" wt="$3" out="$4" mref="$5" on steps="" s msha base bset mset extra lines=""
  # BR_VERIFY_ON_MAIN: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERIFY_ON_MAIN.json (fallback 1)
  on=$(brlad_knob BR_VERIFY_ON_MAIN "${BR_VERIFY_ON_MAIN:-1}" 1 0 1)
  [ "$on" = 1 ] || return 1
  [ -r "$out" ] || return 1
  # The other checks already read the diff against origin/main: their red is this branch's.
  grep -qE '^CLOSURE_LINT_EXIT: [1-9]|SELECTION_GATE_EXIT: 1|^CI_LOCAL_EXIT: 1|^UNRESOLVED_PATHS|^AUTHOR_' "$out" && return 1
  grep -qE '^TYPECHECK_EXIT: [1-9]' "$out" && steps="typecheck"
  grep -qE '^UNIT_EXIT: [1-9]' "$out" && steps="$steps unit"
  [ -n "$steps" ] || return 1
  if ! msha=$(git -C "$wt" rev-parse --verify -q "$mref^{commit}" 2>/dev/null) || [ -z "$msha" ]; then
    echo "BASELINE: could-not-run ($mref does not resolve in the round's tree)" >> "$out"; return 1
  fi
  mkdir -p "$ST/$p" 2>/dev/null
  base="$ST/$p/$ck.verify-baseline.txt"
  if [ "$(head -1 "$base" 2>/dev/null)" != "MAIN $msha" ]; then
    brlad_vb_build "$wt" "$msha" "$base" || { echo "BASELINE: could-not-run ($BRLAD_VB_WHY)" >> "$out"; return 1; }
  fi
  for s in $steps; do
    case "$s" in
      typecheck) grep -qE '^TYPECHECK_EXIT: [1-9]' "$base" || return 1 ;;
      unit)      grep -qE '^UNIT_EXIT: [1-9]' "$base" || return 1 ;;
    esac
    bset=$(brlad_fail_ids "$out" "$s"); [ -n "$bset" ] || return 1
    mset=$(brlad_fail_ids "$base" "$s")
    extra=$(LC_ALL=C comm -23 <(printf '%s\n' "$bset") <(printf '%s\n' "$mset"))
    [ -z "$extra" ] || return 1
    lines="${lines}BASELINE: $s red on $mref ${msha:0:8} with the same $(printf '%s\n' "$bset" | grep -c .) failure(s) — not caused by this branch"$'\n'
  done
  printf '%s' "$lines" >> "$out"
  return 0
}

# brlad_prev_verify_brief <p> <ck> — the brief paragraph with the tail of the
#   last failed round's verify output, or nothing.
brlad_prev_verify_brief() {
  local f="$ST/$1/$2.fix-verify.prev.txt" b
  [ -s "$f" ] || return 0
  # BR_VERIFY_PREV_BYTES: catalog/lanes.d/blocked-resolver.knobs.d/BR_VERIFY_PREV_BYTES.json (fallback 4000)
  b=$(brlad_knob BR_VERIFY_PREV_BYTES "${BR_VERIFY_PREV_BYTES:-4000}" 4000 0 20000)
  [ "$b" -gt 0 ] || return 0
  printf '\n\nTHE LAST FIX ROUND ON THIS PR PRODUCED NO VERIFIED COMMIT. The harness re-ran typecheck and unit after it and did not push. Start from what it left; do not repeat it unchanged. THE HARNESS VERIFY OUTPUT OF THAT ROUND (tail):\n%s' "$(tail -c "$b" "$f")"
}

# brlad_round_failed <p> <ck> <rkey> <reason> <url> <head> <agent-rc> <wt> <n> <verify-out>
#   The no-verified-commit exit of br_fix_round. The verify output is always
#   kept for the next round's brief.
#   rc 0 a review park with a round still owed: the head is un-marked so the
#        next tick runs round n+2 on it, the checkpoint branch is kept
#   rc 1 the driver's own path (another reason, an external PR, an agent
#        timeout — BH-9404 —, the cap reached, or the un-mark failed)
brlad_round_failed() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" head="$6" arc="$7" wt="$8" n="$9" out="${10}" st cap
  mkdir -p "$ST/$p" 2>/dev/null
  [ -s "$out" ] && cp -f "$out" "$ST/$p/$ck.fix-verify.prev.txt" 2>/dev/null
  [ "$reason" = review-changes-requested ] || return 1
  [ "${BR_XPR_ACTIVE-}" = 1 ] && return 1
  [ "$arc" = 124 ] && return 1
  [ -n "$head" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  st=$(br_load "$p" "$ck"); cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((n + 1))" -lt "$cap" ] || return 1
  # shellcheck disable=SC2016  # $h is a jq variable
  if ! br_json_edit "$p" "$ck" '.review_fix_heads = ((.review_fix_heads // []) - [$h])' --arg h "$head"; then
    say "$p/$rkey [$reason]: could NOT un-mark ${head:0:8} on $(br_file "$p" "$ck") — the review terminal runs instead (BH-9437)"
    return 1
  fi
  say "$p/$rkey [$reason]: fix round $((n + 1)) of $cap did not land — fix round $((n + 2)) next tick on ${head:0:8} (agent rc=$arc, BH-9437)"
  br_wt_drop "the round did not land and another one is owed"
  # A foreign-authored checkpoint is never reused: the next round would start
  # from the same commit and fail on it again.
  grep -q '^AUTHOR_' "$out" 2>/dev/null && git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
  mc_git_auth_clear 2>/dev/null
  return 0
}
