#!/bin/bash
# tests/rebase-verify.bh-9406-test.sh — BH-9406 (TK-3738): the pre-PR rebase
# fails closed.
#
# THE DEFECT. bin/lib/rb/pr.sh `# >>> pre-pr rebase` fetched origin/$BASE with
# `|| true`, so a fetch that failed read as "main did not move", and a rebase
# that CONFLICTED or typechecked RED only set REBASE_NOTE and went on to open
# the PR on the old base (TK-3738: a DIRTY PR on outdated code).
#
# THE FIX UNDER TEST.
#   F: the fetch is retried `rebase_verify.fetch_attempts` times. All failed and
#      mode block: BUILD_DEFERRED rebase-fetch:, exit 3, no PR.
#   G: a CONFLICT or a FAILED typecheck gets `rebase_verify.fix_rounds` fix
#      rounds (CC) on the box. No round lands a clean, green update:
#      REVIEW_BLOCKED rebase-verify:, exit 6, HEAD back at the pre-rebase sha,
#      no PR. `rebase_verify.mode=note` is the rollback to the old note.
#
# DRIVEN, NOT GREPPED (D2). The whole `# >>> pre-pr rebase` block is extracted
# from the flattened pipeline (tests/lib/rb-all.sh) and sourced in a shell, as
# production does, against real git: a bare origin and a clone per case under
# $T. After the block the same shell writes a sentinel that stands for the PR
# open that follows. Faked: npx (tsc), CC (the fix model: it runs a per-case
# script), setting_get (a per-case file), alert-line.sh, escalate_block,
# PUSH_BRANCH, sleep. No network: a failing origin is a missing local path.
# No vendor call: 0 gh, 0 model calls.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/rebase-verify.bh-9406-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> pre-pr rebase/{f=1;next} /^# <<< pre-pr rebase/{exit} f' "$RB_ALL" > "$T/rebase.sh"
[ -s "$T/rebase.sh" ] && ok || { bad "could not extract the pre-PR rebase block — markers missing?"; exit 1; }

REAL_GIT=$(command -v git)
mkdir -p "$T/fakebin" "$T/gitwrap"
# Fake tsc. Pops one mode per call from $NPX_SEQ; the last line is sticky.
cat > "$T/fakebin/npx" <<'EOF'
#!/bin/bash
n=$(cat "$NPX_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$NPX_COUNT"
mode=$(sed -n "${n}p" "$NPX_SEQ" 2>/dev/null); [ -n "$mode" ] || mode=$(tail -1 "$NPX_SEQ" 2>/dev/null)
case "$mode" in
  green) exit 0 ;;
  red)   echo "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'."; exit 1 ;;
  crash) echo "FATAL ERROR: Reached heap limit Allocation failed" >&2; exit 134 ;;
  *)     echo "fake npx: no mode armed" >&2; exit 99 ;;
esac
EOF
chmod +x "$T/fakebin/npx"
# A git wrapper for F2/F6: `fetch` fails while the counter is below $GIT_FETCH_FAILS.
cat > "$T/gitwrap/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = fetch ]; then
  n=\$(cat "\$GIT_FETCH_COUNT" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$GIT_FETCH_COUNT"
  [ "\$n" -le "\${GIT_FETCH_FAILS:-0}" ] && { echo "fatal: fake fetch failure \$n" >&2; exit 128; }
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/gitwrap/git"

g() { "$REAL_GIT" -C "$@" >/dev/null 2>&1; }

# fixture <name> <shape> — prints the clone dir. Shapes:
#   conflict   main and the branch both change a.txt
#   moved      main adds b.txt, the branch changes a.txt (clean rebase)
#   still      main has not moved
#   unrelated  the branch shares no history with origin/main
fixture() {
  local d="$T/c-$1" shape="$2"
  mkdir -p "$d"
  "$REAL_GIT" init -q "$d/seed" || return 1
  g "$d/seed" config user.email t@t; g "$d/seed" config user.name t
  echo base > "$d/seed/a.txt"; echo '{}' > "$d/seed/tsconfig.json"
  g "$d/seed" add .; g "$d/seed" commit -qm A; g "$d/seed" branch -M main
  "$REAL_GIT" clone -q --bare "$d/seed" "$d/origin.git" || return 1
  "$REAL_GIT" clone -q "$d/origin.git" "$d/wt" || return 1
  g "$d/wt" config user.email t@t; g "$d/wt" config user.name t
  if [ "$shape" = unrelated ]; then
    g "$d/wt" checkout -q --orphan ticket/bh-1; echo other > "$d/wt/a.txt"
    g "$d/wt" add .; g "$d/wt" commit -qm orphan
  else
    g "$d/wt" checkout -q -b ticket/bh-1
    echo branch > "$d/wt/a.txt"; g "$d/wt" commit -qam "BH-1 branch work"
  fi
  case "$shape" in
    conflict) echo main > "$d/seed/a.txt"; g "$d/seed" commit -qam "main moves a.txt" ;;
    moved)    echo b > "$d/seed/b.txt"; g "$d/seed" add b.txt; g "$d/seed" commit -qm "main adds b.txt" ;;
  esac
  case "$shape" in conflict|moved) g "$d/seed" push -q "$d/origin.git" main || return 1 ;; esac
  "$REAL_GIT" -C "$d/wt" rev-parse HEAD > "$d/prebase"
  "$REAL_GIT" -C "$d/origin.git" rev-parse main > "$d/main"
  echo "$d"
}

# run_case <dir> [VAR=value ...] — runs the block in <dir>/wt; prints its rc.
# Per-case knobs: <dir>/settings (key=value; the line OUTAGE makes every read rc 1),
# <dir>/cc.sh (what the fake fix model does in the worktree), <dir>/npx.seq.
run_case() {
  local d="$1"; shift
  mkdir -p "$d/h/bin" "$d/h/state" "$d/b"
  : > "$d/b/pipeline.log"; touch "$d/settings"; [ -f "$d/npx.seq" ] || echo green > "$d/npx.seq"
  cat > "$d/h/bin/alert-line.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$d/alerts"
EOF
  chmod +x "$d/h/bin/alert-line.sh"
  ( cd "$d/wt" || exit 99
    export HARNESS="$d/h" PROJECT=p KEY=BH-1 BUILD="$d/b" BRANCH=ticket/bh-1 \
           NPX_SEQ="$d/npx.seq" NPX_COUNT="$d/npx.count" GIT_FETCH_COUNT="$d/fetch.count" \
           CASE_DIR="$d" TSC_HEAP_MB=512 PATH="$T/fakebin:$PATH"
    for kv in "$@"; do export "${kv?}"; done
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }; STAGE_START() { echo 0; }; STAGE_END() { :; }
      RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
      sleep() { echo "$1" >> "$CASE_DIR/sleeps"; }
      PUSH_BRANCH() { echo "$1" >> "$CASE_DIR/pushes"; }
      escalate_block() { echo "$1" >> "$CASE_DIR/escalations"; }
      setting_get() {
        grep -qx OUTAGE "$CASE_DIR/settings" && return 1
        local v; v=$(grep -m1 "^$1=" "$CASE_DIR/settings") || return 2
        printf "%s" "${v#*=}"
      }
      if [ "${NO_CC:-}" != 1 ]; then
        CC() { echo "$1|$3|$4" >> "$CASE_DIR/cc.calls"; [ -f "$CASE_DIR/cc.sh" ] && bash "$CASE_DIR/cc.sh" >> "$CASE_DIR/cc.out" 2>&1; return 0; }
      fi
      BASE="${BASE_IN:-main}"; STACK_ON="${STACK_IN:-}"; PREPR_SECTION=""; FIX_MODEL=""
      [ "${TBR_IN:-}" = 1 ] && TBR_PUBLISHED=1
      . "$1"
      echo PR-OPEN-REACHED > "$CASE_DIR/sentinel"
      printf "%s" "$REBASE_NOTE" > "$CASE_DIR/note"
      printf "%s" "$PREPR_SECTION" > "$CASE_DIR/prepr"' _ "$T/rebase.sh" )
  echo $?
}
cnt() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
head_is() { [ "$("$REAL_GIT" -C "$1/wt" rev-parse HEAD)" = "$(cat "$1/$2")" ]; }
clean_tree() { [ -z "$("$REAL_GIT" -C "$1/wt" status --porcelain)" ] && [ ! -e "$1/wt/.git/MERGE_HEAD" ] && [ ! -d "$1/wt/.git/rebase-merge" ] && [ ! -d "$1/wt/.git/rebase-apply" ]; }
knobs() { printf '%s\n' "rebase_verify.fetch_sleep_s=0" "$@" > "$1/settings.tmp"; mv "$1/settings.tmp" "$1/settings"; }
# Two fix-model scripts that resolve the conflict properly.
CC_REBASE_RESOLVE='git rebase origin/main >/dev/null 2>&1 || { echo resolved > a.txt; git add a.txt; GIT_EDITOR=true git rebase --continue; }'
CC_MERGE_RESOLVE='git merge --no-edit origin/main >/dev/null 2>&1 || { echo resolved > a.txt; git add a.txt; git commit -qm "merge origin/main"; }'

# ============================================================================
# F. the fetch
# ============================================================================
# F1 — attempt 1 succeeds: proceed (clean rebase, green), 0 failed-attempt lines.
D=$(fixture f1 moved); knobs "$D"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "F1: a good fetch must reach the PR open (rc=$RC)"
[ -z "$(cat "$D/note" 2>/dev/null)" ] && ok || bad "F1: a clean green rebase leaves no note (got '$(cat "$D/note" 2>/dev/null)')"
"$REAL_GIT" -C "$D/wt" merge-base --is-ancestor "$(cat "$D/main")" HEAD && ok || bad "F1: HEAD must contain the moved origin/main"
[ "$(grep -c 'rebase fetch attempt' "$D/b/pipeline.log")" = 0 ] && ok || bad "F1: no failed-attempt line on a good fetch"

# F2 — attempts 1-2 fail, 3 succeeds: proceed, 2 failed-attempt lines, 2 sleeps.
D=$(fixture f2 moved); knobs "$D"
RC=$(run_case "$D" PATH="$T/gitwrap:$T/fakebin:$PATH" GIT_FETCH_FAILS=2)
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "F2: a fetch that lands on attempt 3 must proceed (rc=$RC, RESULT=$(cat "$D/b/RESULT" 2>/dev/null))"
[ "$(grep -c 'rebase fetch attempt' "$D/b/pipeline.log")" = 2 ] && ok || bad "F2: 2 failed-attempt lines expected (got $(grep -c 'rebase fetch attempt' "$D/b/pipeline.log"))"
[ "$(cat "$D/fetch.count" 2>/dev/null)" = 3 ] && ok || bad "F2: exactly 3 fetch calls expected (got $(cat "$D/fetch.count" 2>/dev/null))"
[ "$(cnt "$D/sleeps")" = 2 ] && ok || bad "F2: one sleep between attempts (2 expected, got $(cnt "$D/sleeps"))"
"$REAL_GIT" -C "$D/wt" merge-base --is-ancestor "$(cat "$D/main")" HEAD && ok || bad "F2: the third fetch's main must be in HEAD"

# F3 — every attempt fails, mode block: BUILD_DEFERRED rebase-fetch:, rc 3, no PR.
D=$(fixture f3 moved); knobs "$D"
"$REAL_GIT" -C "$D/wt" remote set-url origin "$D/missing.git"
RC=$(run_case "$D")
[ "$RC" = 3 ] && ok || bad "F3: a fetch that never lands must exit 3 (got $RC)"
[ ! -f "$D/sentinel" ] && ok || bad "F3: a failed fetch must NOT reach the PR open (stale origin/main read as 'main did not move')"
case "$(head -1 "$D/b/RESULT" 2>/dev/null)" in
  "BUILD_DEFERRED rebase-fetch: git fetch of origin/main failed 3 time(s)"*) ok ;;
  *) bad "F3: RESULT must be 'BUILD_DEFERRED rebase-fetch: git fetch of origin/main failed 3 time(s) …' (got '$(head -1 "$D/b/RESULT" 2>/dev/null)')" ;;
esac
[ "$(cnt "$D/pushes")" = 1 ] && ok || bad "F3: PUSH_BRANCH must run once before the defer (got $(cnt "$D/pushes"))"
[ "$(cnt "$D/alerts")" = 0 ] && ok || bad "F3: a fetch defer writes no ALERTS line (got $(cnt "$D/alerts"))"
[ "$(grep -c 'rebase fetch attempt' "$D/b/pipeline.log")" = 3 ] && ok || bad "F3: 3 failed-attempt lines expected (got $(grep -c 'rebase fetch attempt' "$D/b/pipeline.log"))"

# F4 — every attempt fails, mode note: proceed as before, no defer.
D=$(fixture f4 moved); knobs "$D" "rebase_verify.mode=note"
"$REAL_GIT" -C "$D/wt" remote set-url origin "$D/missing.git"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "F4: mode note must keep the old fail-open fetch (rc=$RC)"
[ ! -f "$D/b/RESULT" ] && ok || bad "F4: mode note must write no RESULT (got '$(cat "$D/b/RESULT" 2>/dev/null)')"
grep -q 'mode note' "$D/b/pipeline.log" && ok || bad "F4: mode note must log that it went on"

# F5 — stacked: the STACK_ON refspec fetch fails: defer too.
D=$(fixture f5 moved); knobs "$D"
"$REAL_GIT" -C "$D/wt" remote set-url origin "$D/missing.git"
RC=$(run_case "$D" BASE_IN=ticket/parent STACK_IN=ticket/parent)
[ "$RC" = 3 ] && [ ! -f "$D/sentinel" ] && ok || bad "F5: a stacked fetch that never lands must defer (rc=$RC)"
grep -q '^BUILD_DEFERRED rebase-fetch: git fetch of origin/ticket/parent failed' "$D/b/RESULT" 2>/dev/null \
  && ok || bad "F5: RESULT must name origin/ticket/parent (got '$(cat "$D/b/RESULT" 2>/dev/null)')"

# F6 — fetch_attempts=abc and fetch_sleep_s=-1: the defaults (3 attempts, 10 s).
D=$(fixture f6 moved)
printf '%s\n' "rebase_verify.fetch_attempts=abc" "rebase_verify.fetch_sleep_s=-1" > "$D/settings"
"$REAL_GIT" -C "$D/wt" remote set-url origin "$D/missing.git"
RC=$(run_case "$D")
[ "$RC" = 3 ] && ok || bad "F6: bad knobs still fail closed (rc=$RC)"
[ "$(grep -c 'rebase fetch attempt' "$D/b/pipeline.log")" = 3 ] && ok || bad "F6: a bad fetch_attempts falls back to 3 (got $(grep -c 'rebase fetch attempt' "$D/b/pipeline.log"))"
[ "$(sort -u "$D/sleeps" 2>/dev/null)" = 10 ] && [ "$(cnt "$D/sleeps")" = 2 ] && ok || bad "F6: a bad fetch_sleep_s falls back to 10 s (got: $(tr '\n' ' ' < "$D/sleeps" 2>/dev/null))"

# ============================================================================
# G. the gate
# ============================================================================
# G1 — CONFLICT, the fix model does nothing: block.
D=$(fixture g1 conflict); knobs "$D"; : > "$D/cc.sh"
RC=$(run_case "$D")
MB12=$("$REAL_GIT" -C "$D/wt" merge-base origin/main HEAD | cut -c1-12); M12=$(cut -c1-12 "$D/main")
[ "$RC" = 6 ] && ok || bad "G1: an unfixed conflict must exit 6 (got $RC)"
[ ! -f "$D/sentinel" ] && ok || bad "G1: an unfixed conflict must NOT reach the PR open"
case "$(head -1 "$D/b/RESULT" 2>/dev/null)" in
  "REVIEW_BLOCKED rebase-verify: conflict vs origin/main (base=$MB12 main=$M12) after 1 fix round(s)"*) ok ;;
  *) bad "G1: RESULT wrong (got '$(head -1 "$D/b/RESULT" 2>/dev/null)')" ;;
esac
head_is "$D" prebase && ok || bad "G1: HEAD must be back at the pre-rebase sha"
clean_tree "$D" && ok || bad "G1: the worktree must be clean (no merge or rebase in progress)"
grep -q 'a.txt' "$D/b/rebase-verify-block.txt" 2>/dev/null && ok || bad "G1: rebase-verify-block.txt must name the conflict path a.txt"
[ "$(cnt "$D/cc.calls")" = 1 ] && ok || bad "G1: exactly 1 fix round (got $(cnt "$D/cc.calls"))"
[ "$(cnt "$D/alerts")" = 1 ] && ok || bad "G1: exactly 1 alert line (got $(cnt "$D/alerts"))"
[ "$(cat "$D/escalations" 2>/dev/null)" = rebase-verify ] && ok || bad "G1: escalate_block rebase-verify once (got '$(cat "$D/escalations" 2>/dev/null)')"
grep -q '^fix|1800|' "$D/cc.calls" 2>/dev/null && ok || bad "G1: the fix round runs as stage fix with the 1800 s default timeout (got '$(cat "$D/cc.calls" 2>/dev/null)')"

# G2 — FAILED (red typecheck), the fix model does nothing: block.
D=$(fixture g2 moved); knobs "$D"; : > "$D/cc.sh"; echo red > "$D/npx.seq"
RC=$(run_case "$D")
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G2: an unfixed red typecheck must exit 6 with no PR (rc=$RC)"
grep -q '^REVIEW_BLOCKED rebase-verify: typecheck-red vs origin/main' "$D/b/RESULT" 2>/dev/null \
  && ok || bad "G2: RESULT must say typecheck-red (got '$(cat "$D/b/RESULT" 2>/dev/null)')"
head_is "$D" prebase && ok || bad "G2: HEAD must be back at the pre-rebase sha"
grep -q 'error TS2322' "$D/b/rebase-verify-block.txt" 2>/dev/null && ok || bad "G2: rebase-verify-block.txt must carry the tsc output"

# G3 — CONFLICT, no CC function: block, 0 fix rounds.
D=$(fixture g3 conflict); knobs "$D"
RC=$(run_case "$D" NO_CC=1)
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G3: no CC must still block (rc=$RC)"
grep -q 'after 0 fix round(s)' "$D/b/RESULT" 2>/dev/null && ok || bad "G3: RESULT must say 0 fix rounds (got '$(cat "$D/b/RESULT" 2>/dev/null)')"

# G4 — fix_rounds=0: block, 0 CC calls.
D=$(fixture g4 conflict); knobs "$D" "rebase_verify.fix_rounds=0"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G4: fix_rounds=0 must block at once (rc=$RC)"
[ "$(cnt "$D/cc.calls")" = 0 ] && ok || bad "G4: fix_rounds=0 means 0 CC calls (got $(cnt "$D/cc.calls"))"

# G5 — CONFLICT, the fix model resolves it, tsc green: pass, the PR opens.
D=$(fixture g5 conflict); knobs "$D"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G5: a resolved conflict must reach the PR open (rc=$RC, RESULT=$(cat "$D/b/RESULT" 2>/dev/null))"
[ -z "$(cat "$D/note" 2>/dev/null)" ] && ok || bad "G5: a resolved, green update leaves no note (got '$(cat "$D/note" 2>/dev/null)')"
"$REAL_GIT" -C "$D/wt" merge-base --is-ancestor "$(cat "$D/main")" HEAD && ok || bad "G5: origin/main must be an ancestor of HEAD"
grep -q '## Pre-PR rebase fix round' "$D/prepr" 2>/dev/null && ok || bad "G5: PREPR_SECTION must carry '## Pre-PR rebase fix round'"
grep -q 'rebase fix round 1 landed' "$D/b/pipeline.log" && ok || bad "G5: the landed line must be logged"
[ "$(cnt "$D/alerts")" = 0 ] && ok || bad "G5: a landed fix round alerts nobody"
[ "$(cat "$D/npx.count" 2>/dev/null)" = 1 ] && ok || bad "G5: the recheck runs tsc once (a conflict runs no tsc before it; got $(cat "$D/npx.count" 2>/dev/null))"

# G6 — FAILED, the fix model updates and fixes, tsc green on the recheck: pass.
D=$(fixture g6 moved); knobs "$D"; printf '%s\n' red green > "$D/npx.seq"
printf '%s\n' 'git rebase origin/main >/dev/null 2>&1 && echo fix > fix.ts && git add fix.ts && git commit -qm fix' > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G6: a fixed red must reach the PR open (rc=$RC, RESULT=$(cat "$D/b/RESULT" 2>/dev/null))"
[ -z "$(cat "$D/note" 2>/dev/null)" ] && ok || bad "G6: no note after a fix round that landed (got '$(cat "$D/note" 2>/dev/null)')"
[ -f "$D/wt/fix.ts" ] && ok || bad "G6: the fix commit must be in HEAD"

# G7 (near miss) — the tsc CRASHES: INCONCLUSIVE note, no fix round, PR opens.
D=$(fixture g7 moved); knobs "$D"; echo crash > "$D/npx.seq"; : > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G7: a tsc crash must still open the PR (rc=$RC)"
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$D/note" 2>/dev/null && ok || bad "G7: the INCONCLUSIVE note must stand (got '$(cat "$D/note" 2>/dev/null)')"
[ "$(cnt "$D/cc.calls")" = 0 ] && ok || bad "G7: an INCONCLUSIVE gets no fix round"

# G8 (near miss) — merge-base unresolvable: INCONCLUSIVE, no action.
D=$(fixture g8 unrelated); knobs "$D"; : > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G8: an unresolvable merge-base must still open the PR (rc=$RC)"
grep -q 'merge-base of origin/main and HEAD is unresolvable' "$D/note" 2>/dev/null && ok || bad "G8: the unresolvable note must stand"
[ "$(cnt "$D/cc.calls")" = 0 ] && ok || bad "G8: no fix round"

# G9 (near miss) — red, but every error is in the cached main baseline: empty note, PR opens.
D=$(fixture g9 moved); knobs "$D"; echo red > "$D/npx.seq"; : > "$D/cc.sh"
mkdir -p "$D/h/state"; echo "src/a.ts(1,1): error TS2322: Type 'string' is not assignable to type 'number'." > "$D/h/state/tsc-baseline-p.txt"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && [ -z "$(cat "$D/note" 2>/dev/null)" ] && ok || bad "G9: a red the baseline accepts must open the PR with no note (rc=$RC note='$(cat "$D/note" 2>/dev/null)')"
[ "$(cnt "$D/cc.calls")" = 0 ] && ok || bad "G9: no fix round for a baseline-accepted red"

# G10 — mode note + CONFLICT: the old note, the PR opens, 0 CC calls.
D=$(fixture g10 conflict); knobs "$D" "rebase_verify.mode=note"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G10: mode note must open the PR as before (rc=$RC)"
grep -q '^ | REBASE_CONFLICT vs origin/main' "$D/note" 2>/dev/null && ok || bad "G10: mode note keeps the REBASE_CONFLICT note (got '$(cat "$D/note" 2>/dev/null)')"
[ "$(cnt "$D/cc.calls")" = 0 ] && ok || bad "G10: mode note runs no fix round"
# per-project mode row wins over the global one
D=$(fixture g10p conflict); knobs "$D" "rebase_verify.mode=block" "rebase_verify.mode.p=note"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G10: rebase_verify.mode.<project>=note must win over the global row (rc=$RC)"

# G11 — mode row 'bogus', and setting_get rc 1: block.
D=$(fixture g11a conflict); knobs "$D" "rebase_verify.mode=bogus"; : > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G11: a bogus mode row is block (rc=$RC)"
D=$(fixture g11b conflict); echo OUTAGE > "$D/settings"; : > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G11: an unreadable settings store is block (rc=$RC)"
[ "$(cnt "$D/cc.calls")" = 1 ] && ok || bad "G11: an unreadable fix_rounds falls back to 1 (got $(cnt "$D/cc.calls"))"

# G12 — the fix model leaves a mess: conflict markers / MERGE_HEAD / an uncommitted change: fail, reset.
i=0
for SCRIPT in \
  'git rebase origin/main >/dev/null 2>&1; true' \
  'git merge --no-edit origin/main >/dev/null 2>&1; true' \
  "$CC_REBASE_RESOLVE"'; echo dirty >> a.txt' ; do
  i=$((i+1))
  D=$(fixture "g12-$i" conflict); knobs "$D"; printf '%s\n' "$SCRIPT" > "$D/cc.sh"
  RC=$(run_case "$D")
  [ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G12.$i: a fix round that left a mess must block (rc=$RC)"
  head_is "$D" prebase && ok || bad "G12.$i: HEAD must be reset to the pre-rebase sha"
  clean_tree "$D" && ok || bad "G12.$i: the worktree must be clean after the reset ($("$REAL_GIT" -C "$D/wt" status --porcelain | tr '\n' ' '))"
done

# G13 — a published branch (RB_UPDATE=merge), the fix model REBASES it: fail (PREBASE not an ancestor).
D=$(fixture g13 conflict); knobs "$D"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"
RC=$(run_case "$D" TBR_IN=1)
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G13: rewriting a merge-update branch must block (rc=$RC)"
# the same branch, resolved by MERGE: pass
D=$(fixture g13m conflict); knobs "$D"; printf '%s\n' "$CC_MERGE_RESOLVE" > "$D/cc.sh"
RC=$(run_case "$D" TBR_IN=1)
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G13: a merge-update branch resolved by merge must pass (rc=$RC, RESULT=$(cat "$D/b/RESULT" 2>/dev/null))"
"$REAL_GIT" -C "$D/wt" merge-base --is-ancestor "$(cat "$D/prebase")" HEAD && ok || bad "G13: the merge keeps PREBASE an ancestor"

# G14 — the fix model resolves, but tsc stays red: block, no landed line.
D=$(fixture g14 conflict); knobs "$D"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"; echo red > "$D/npx.seq"
RC=$(run_case "$D")
[ "$RC" = 6 ] && [ ! -f "$D/sentinel" ] && ok || bad "G14: a resolved conflict that typechecks red must block (rc=$RC)"
grep -q 'fix round 1 landed' "$D/b/pipeline.log" && bad "G14: no landed line when tsc stays red" || ok
head_is "$D" prebase && ok || bad "G14: HEAD must be reset to the pre-rebase sha"

# G15 — the fix model resolves, tsc crashes: pass with an INCONCLUSIVE note.
D=$(fixture g15 conflict); knobs "$D"; printf '%s\n' "$CC_REBASE_RESOLVE" > "$D/cc.sh"; echo crash > "$D/npx.seq"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && ok || bad "G15: a fix round with a crashed tsc still opens the PR (rc=$RC)"
grep -q 'REBASE_VERIFY_INCONCLUSIVE' "$D/note" 2>/dev/null && ok || bad "G15: the note must say INCONCLUSIVE (got '$(cat "$D/note" 2>/dev/null)')"
"$REAL_GIT" -C "$D/wt" merge-base --is-ancestor "$(cat "$D/main")" HEAD && ok || bad "G15: the fix round's update must stay in HEAD"

# G16 — main did not move: nothing happens, nothing is claimed.
D=$(fixture g16 still); knobs "$D"; : > "$D/cc.sh"
RC=$(run_case "$D")
[ "$RC" = 0 ] && [ -f "$D/sentinel" ] && [ -z "$(cat "$D/note" 2>/dev/null)" ] && [ "$(cnt "$D/cc.calls")" = 0 ] \
  && ok || bad "G16: main not moved must be a no-op (rc=$RC)"

# ============================================================================
# RT. the two new RESULT shapes against their readers
# ============================================================================
. "$DIR/bin/lib/pool-push-rejected.sh" || { bad "RT1: could not source pool-push-rejected.sh"; }
if command -v ppr_rejected_line >/dev/null 2>&1; then
  ppr_rejected_line "BUILD_DEFERRED rebase-fetch: git fetch of origin/main failed 3 time(s) — the branch is pushed, no PR opened" \
    && bad "RT1: ppr_rejected_line must NOT read a fetch defer as a push rejection" || ok
fi
grep -m1 '^is_tamper_block()' "$DIR/bin/review-rescue.sh" > "$T/itb.sh"
if [ -s "$T/itb.sh" ] && . "$T/itb.sh"; then
  is_tamper_block "REVIEW_BLOCKED rebase-verify: conflict vs origin/main (base=a main=b) after 1 fix round(s)" \
    && bad "RT2: is_tamper_block must NOT read a rebase-verify block as test-tamper" || ok
else
  bad "RT2: could not extract is_tamper_block from bin/review-rescue.sh"
fi

echo "rebase-verify.bh-9406: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
