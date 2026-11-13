# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9472-fixround-repro.sh — BH-9472 (BH-9285 Fix 4):
# a ci-red fix round reproduces the failing CI test before it spends an agent
# call, and pushes only after that test passes on the box.
#
# TWO RULES, two one-line call sites in br_fix_round:
#   brfr_pre    before the brief is sent to the agent. The failed CI jobs of
#               the PR head name their test files (frr_failing_tests). They run
#               once here (frr_reproduce: CI locale, throwaway Postgres,
#               budget), on the head CI ran. When the round's tree is not that
#               head (origin/main merged in, a reused checkpoint), a detached
#               worktree at the head is used, and a green there runs again on
#               the round's tree before anything is called NOT REPRODUCED.
#                 red here       the files go to $ST/<p>/<ck>.repro.txt and the
#                                round runs (rc 1).
#                 green          NOT REPRODUCED: fix-verify.txt gets
#                                `REPRO_EXIT: not-reproduced`, the record gets
#                                one fix-round attempt (fixrounds +1), then one
#                                PR comment. No agent call, no push (rc 0). At
#                                the fix cap the ordinary terminal runs.
#                 anything else  one say line, the round runs as before (rc 1):
#                                gate off, not a ci-red park, a conflicted
#                                merge, a red that names no test file, an
#                                unreadable CI, a could-not-run.
#   brfr_verify after the round's verify block (stdout appends to fix-verify.txt).
#               When brfr_pre wrote repro.txt, the same files run on the
#               round's tree: `REPRO_EXIT: passes | still-red | could-not-run`.
#               still-red and could-not-run say "not proven green here" and
#               return 1, and br_fix_round refuses the push.
# Fail-open: no lib, no call. The lib is bin/lib/fixround-repro.sh.
. "${H}/bin/lib/fixround-repro.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/../lib/fixround-repro.sh" 2>/dev/null || true

# _brfr_rt_drop <repo> <dir> — remove the detached worktree brfr_pre made.
_brfr_rt_drop() {
  [ -n "${2:-}" ] || return 0
  br_wt_drop "the repro run at the CI head is done" "$1" "$2" >/dev/null 2>&1 || true
}

# brfr_pre <p> <ck> <rkey> <reason> <url> <slug> <wt> <head> <rec> <tkey> <n>
#   rc 0 the round ended here (NOT REPRODUCED); rc 1 the round goes on.
brfr_pre() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" slug="$6" wt="$7" head="$8" rec="$9" tkey="${10}" n="${11:-0}"
  local sf="$ST/$p/$ck.repro.txt" out="$ST/$p/$ck.fix-verify.txt" log="$ST/$p/$ck.repro.log"
  local tmp rc rt="" tree moved=0 where list body st cap own
  local files=()
  rm -f "$sf" 2>/dev/null
  [ "$(br_ladder_class "$reason")" = ci-red ] || return 1
  command -v frr_failing_tests >/dev/null 2>&1 || return 1
  if ! frr_on; then
    say "$p/$rkey [$reason]: repro gate off (FIXROUND_REPRO_GATE=0) — the round runs as before"
    return 1
  fi
  if [ -z "$head" ]; then
    say "$p/$rkey [$reason]: repro gate: no PR head sha — not gated, the round runs as before"
    return 1
  fi
  if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    say "$p/$rkey [$reason]: repro gate: the merge left conflicted paths — not gated, the round runs as before"
    return 1
  fi
  mkdir -p "$ST/$p" 2>/dev/null
  tmp="$ST/$p/$ck.repro-files.txt"
  frr_failing_tests "$slug" "$head" "$wt" > "$tmp" 2>/dev/null; rc=$?
  mapfile -t files < "$tmp"; rm -f "$tmp"
  case "$rc" in
    0) [ "${#files[@]}" -gt 0 ] || rc=3 ;;
  esac
  case "$rc" in
    0) ;;
    3) say "$p/$rkey [$reason]: repro gate: the red on ${head:0:8} names no test file this gate can run (typecheck, lint, build, or a mixed red) — not gated, the round runs as before"; return 1 ;;
    *) say "$p/$rkey [$reason]: repro gate: the CI of ${head:0:8} could not be read — not gated, the round runs as before"; return 1 ;;
  esac
  list="${files[*]}"
  : > "$log"
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ]; then
    tree="$wt"
  else
    moved=1
    mkdir -p "$H/tmp/brfix"
    rt=$(mktemp -d "$H/tmp/brfix/repro-XXXX"); rmdir "$rt"
    if ! git -C "$REPOS/$p" worktree add -q --detach "$rt" "$head" >/dev/null 2>&1; then
      say "$p/$rkey [$reason]: repro gate: no worktree at the CI head ${head:0:8} — not gated, the round runs as before"
      _brfr_rt_drop "$REPOS/$p" "$rt"; return 1
    fi
    tree="$rt"
  fi
  VR_DEPS_FROM="$REPOS/$p" frr_reproduce "$tree" "$log" "${files[@]}" >/dev/null; rc=$?
  where="the CI head ${head:0:8}"
  if [ "$rc" = 0 ] && [ "$moved" = 1 ]; then
    # Green at the head, but the round's tree is not the head: main can carry
    # the break. Only a green on the round's tree too is NOT REPRODUCED.
    VR_DEPS_FROM="$REPOS/$p" frr_reproduce "$wt" "$log" "${files[@]}" >/dev/null; rc=$?
    where="the round's tree (${head:0:8} merged with origin/main)"
  fi
  _brfr_rt_drop "$REPOS/$p" "$rt"
  case "$rc" in
    1)
      { printf 'head %s\n' "$head"; printf 'file %s\n' "${files[@]}"; } > "$sf"
      say "$p/$rkey [$reason]: repro gate: $list REPRODUCED red on $where — the round runs and pushes only after they pass here"
      return 1 ;;
    2)
      say "$p/$rkey [$reason]: repro gate: $list could not run here (${FRR_WHY:-no reason}) — not gated, the round runs as before"
      return 1 ;;
  esac
  # NOT REPRODUCED. The record first, then the comment: a comment with no
  # record would be posted again on every tick.
  command -v ce_resolve >/dev/null 2>&1 && ce_resolve "$wt" >/dev/null 2>&1
  { echo "== repro =="; echo "REPRO_FILES: $list"; echo "REPRO_EXIT: not-reproduced"
    echo "REPRO_WHERE: $where"; } > "$out"
  if ! br_record "$p" "$ck" fix-round "$reason" "NOT REPRODUCED: $list pass locally on ${head:0:8} — no agent call, no push" fixrounds "$url" "$head"; then
    echo "record: failed" >> "$out"
    say "$p/$rkey [$reason]: NOT REPRODUCED ($list green on $where), and the record would not write — no comment, no push, retried next tick"
    _brfr_end "$p" "$ck" "$moved"; return 0
  fi
  body="NOT REPRODUCED: $list pass locally on ${head:0:8} with LC_ALL=${CE_LOCALE:-unknown} and a local Postgres (collation ${CE_COLLATION:-unknown}); CI run $(jq -r '.[0] // "unknown"' <<<"${FRR_CI_URLS:-[]}" 2>/dev/null) failed. No guess pushed.

The harness fix round ran the failing CI test file(s) on $where before it called an agent. They passed, so the CI red is not reproduced here and nothing was pushed. Look at the CI run for a cause outside these files (a flaky test, a runner difference, a step outside the test run)."
  if ! br_pr_comment "$url" "$body" >/dev/null 2>&1; then
    echo "comment: failed" >> "$out"
    say "$p/$rkey [$reason]: the NOT REPRODUCED comment on $url failed — recorded, nothing pushed"
  fi
  say "$p/$rkey [$reason]: NOT REPRODUCED — $list green on $where; no agent call, no push"
  _brfr_end "$p" "$ck" "$moved"
  st=$(br_load "$p" "$ck"); cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap=1 ;; esac
  if [ "$((n+1))" -ge "$cap" ]; then
    say "$p/$rkey [$reason]: fix round $((n+1)) of $cap ended NOT REPRODUCED — $(br_fix_terminal_word "$reason")"
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
  else
    say "$p/$rkey [$reason]: fix round $((n+1)) of $cap ended NOT REPRODUCED — fix round $((n+2)) next tick"
  fi
  return 0
}

# _brfr_end <p> <ck> <moved> — the round's worktree, its checkpoint branch
# (only when the tree was the CI head: a moved tree may hold earlier work),
# and the git credential.
_brfr_end() {
  br_wt_drop "the failing CI test did not reproduce"
  [ "${3:-0}" = 0 ] && git -C "$REPOS/$1" branch -D "brfix/$2" >/dev/null 2>&1
  mc_git_auth_clear 2>/dev/null
  return 0
}

# brfr_verify <wt> <state-prefix> — the repro lines of the round's verify.
brfr_verify() {
  local wt="$1" pre="$2" sf="$2.repro.txt" files=() rc w
  [ -f "$sf" ] || return 0
  mapfile -t files < <(sed -n 's/^file //p' "$sf")
  echo "== repro =="
  if [ "${#files[@]}" = 0 ] || ! command -v frr_confirm >/dev/null 2>&1; then
    w="could-not-run (no file or no lib)"
  else
    echo "REPRO_FILES: ${files[*]}"
    : > "$pre.repro-verify.log"
    VR_DEPS_FROM="${BR_FIX_REPO:-}" frr_confirm "$wt" "$pre.repro-verify.log" "${files[@]}" >/dev/null; rc=$?
    case "$rc" in
      0) echo "REPRO_EXIT: passes"; return 0 ;;
      1) w=still-red ;;
      *) w="could-not-run (${FRR_WHY:-no reason})" ;;
    esac
  fi
  echo "REPRO_EXIT: $w"
  [ "$w" = still-red ] && tail -c "$(frr_verify_tail_bytes)" "$pre.repro-verify.log"
  # p, rkey and reason are br_fix_round's locals (the caller's scope).
  say "$p/$rkey [$reason]: the failing CI test is not proven green here ($w) — not pushed"
  return 1
}
