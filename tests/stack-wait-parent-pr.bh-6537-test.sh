#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stack-wait-parent-pr.bh-6537-test.sh — BH-6537. The `stacked child
# builds` block decides "the parent is still open" from the parent PR's STATE,
# read through REST (sw_parent_pr in bin/lib/stack-wait.sh), not from whether
# the parent branch still exists. A repo that keeps merged branches
# (delete_branch_on_merge=false) made TK-260 defer 4 times after its parent PR
# #275 merged.
#   merged / closed      build on the base, no fetch, no stack-wait gate
#   open                 today's path (BH-5234 + BH-6389)
#   none / unchecked     branch existence decides, as before
#   unreadable           a live branch waits (BUILD_DEFERRED, exit 3); a merge is
#                        never assumed. A gone branch keeps the build-on-base fallback.
# L* call the lib directly; D* drive the real block, extracted from the
# flattened run-build pipeline, against a real bare origin that still carries
# the parent branch ticket/xx-41.
# Run from anywhere: tests/stack-wait-parent-pr.bh-6537-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset STACK_WAIT_PARENT_MERGE STACK_WAIT_CAP_H HOTFIX STACKED_BUILDS STACK_PARENT_PR
NOW=1760000000

# ---------------------------------------------------------------- scratch harness
mkdir -p "$T/b/flags" "$T/b/logs"
scratch_install_closure bin/fleet-conf.sh "$T/b" >/dev/null || bad "could not install bin/fleet-conf.sh into the scratch harness"
scratch_install_closure bin/lib/stale-parent.sh "$T/b" >/dev/null || bad "could not install bin/lib/stale-parent.sh into the scratch harness"
scratch_install_closure bin/lib/stack-wait.sh "$T/b" >/dev/null 2>&1 || bad "could not install bin/lib/stack-wait.sh into the scratch harness"
cat > "$T/b/fleet.conf" <<'CONF'
# project repo prod board_prefix offset box tailnet_ip
demo-os example-org/demo-os https://demo.example.com - 0 box1 192.0.2.1
CONF
export FLEET_CONF="$T/b/fleet.conf"

# ---------------------------------------------------------------- origin
# main has f.txt; ticket/xx-41 is the parent branch, KEPT after its PR merged.
git init -q --bare "$T/origin.git"
git init -q "$T/seed" && ( cd "$T/seed"
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add .; git commit -qm base
  git branch -M main; git remote add origin "$T/origin.git"; git push -q origin main
  git checkout -qb ticket/xx-41; echo parent >> f.txt; git commit -qam parent; git push -q origin ticket/xx-41 ) >/dev/null 2>&1
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
git -C "$T/repo" ls-remote --exit-code origin ticket/xx-41 >/dev/null 2>&1 && ok || bad "fixture: origin must carry the parent branch"

# ---------------------------------------------------------------- the gh_rest stub
# Logs "$*" to rest-calls.txt and answers the parent PR read per PR_MODE.
cat > "$T/stub.sh" <<'SH'
pr() { jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" '{number:$n, state:$s, merged_at:(if $m=="" then null else $m end), html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring))}'; }
gh_rest() {
  printf '%s\n' "$*" >> "$T/rest-calls.txt"
  case "$*" in
    *pulls*head=example-org:ticket/xx-41*)
      case "${PR_MODE:-open}" in
        merged)       printf '[%s]\n' "$(pr 900 closed 2026-10-13T10:00:00Z)" ;;
        open)         printf '[%s]\n' "$(pr 900 open '')" ;;
        closed)       printf '[%s]\n' "$(pr 900 closed '')" ;;
        none)         echo '[]' ;;
        fail)         return 75 ;;
        gone)         return 44 ;;
        junk)         echo '{"message":"x"}' ;;
        multi-open)   printf '[%s,%s]\n' "$(pr 8 closed '')" "$(pr 9 open '')" ;;
        multi-cm)     printf '[%s,%s]\n' "$(pr 8 closed '')" "$(pr 7 closed 2026-10-01T00:00:00Z)" ;;
        multi-merged) printf '[%s,%s]\n' "$(pr 5 closed 2026-09-01T00:00:00Z)" "$(pr 7 closed 2026-10-01T00:00:00Z)" ;;
      esac ;;
    *pulls*) [ "${PR_MODE:-open}" = fail ] && return 75; echo '[]' ;;
    *issues/42*) jq -nc '{number:42, body:"Blocked-by: #41 (hard)"}' ;;
    *) return 1 ;;
  esac
}
SH

# ---------------------------------------------------------------- lib
SW="$T/b/bin/lib/stack-wait.sh"
lib() { ( export T HARNESS="$T/b" PR_MODE="$1"; shift; . "$T/stub.sh"; . "$SW" 2>/dev/null || exit 9
          command -v sw_parent_pr >/dev/null 2>&1 || { echo "sw_parent_pr missing"; exit 0; }
          sw_parent_pr "$@" ); }
: > "$T/rest-calls.txt"
for pair in 'merged:merged 900 https://github.com/example-org/demo-os/pull/900' \
            'open:open 900 https://github.com/example-org/demo-os/pull/900' \
            'closed:closed 900 https://github.com/example-org/demo-os/pull/900' \
            'none:none' 'fail:unreadable 75' 'gone:unreadable 44' 'junk:unreadable 75' \
            'multi-open:open 9 https://github.com/example-org/demo-os/pull/9' \
            'multi-cm:merged 7 https://github.com/example-org/demo-os/pull/7' \
            'multi-merged:merged 7 https://github.com/example-org/demo-os/pull/7'; do
  M=$(lib "${pair%%:*}" example-org/demo-os ticket/xx-41)
  [ "$M" = "${pair#*:}" ] && ok || bad "L: PR_MODE=${pair%%:*} must print '${pair#*:}' (got '$M')"
done
# L9 — no gh_rest, or no slug: unchecked, and no read.
M=$( export HARNESS="$T/b"; . "$SW" 2>/dev/null || exit 9; command -v sw_parent_pr >/dev/null 2>&1 || { echo "sw_parent_pr missing"; exit 0; }; sw_parent_pr example-org/demo-os ticket/xx-41 )
[ "$M" = unchecked ] && ok || bad "L9: no gh_rest must print 'unchecked' (got '$M')"
: > "$T/rest-calls.txt"
M=$(lib merged '' ticket/xx-41)
[ "$M" = unchecked ] && ok || bad "L9: an empty slug must print 'unchecked' (got '$M')"
[ -s "$T/rest-calls.txt" ] && bad "L9: an empty slug must make no REST call (got: $(cat "$T/rest-calls.txt"))" || ok

# ---------------------------------------------------------------- the block
awk '/^# >>> stacked child builds/{f=1;next} /^# <<< stacked child builds/{exit} f' "$RB_ALL" > "$T/stack.sh"
[ -s "$T/stack.sh" ] && ok || bad "could not extract the stacked child builds block"

cat > "$T/driver.sh" <<'SH'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { printf '%s\n' "$*" > "$T/result"; }
. "$T/stub.sh"
gh() { printf '%s\n' "$*" >> "$T/gh-calls.txt"; return 1; }
gh_rest_comment() { printf '%s %s\n' "$1" "$2" >> "$T/comment-calls.txt"; return 0; }
job_ledger_row() {
  local line
  line=$(awk -F'\t' -v k="$1" -v v="$2" '$1==k && $2==v' "$T/ledger.tsv" 2>/dev/null | tail -1)
  [ -n "$line" ] || return 2
  jq -nc --arg s "$(cut -f3 <<<"$line")" --arg d "$(cut -f4 <<<"$line")" '{status:$s, detail:$d}'
}
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$T/ledger.tsv"; }
BASE=main
. "$1"
printf '%s|%s\n' "$BASE" "$STACK_ON"
SH

BLD="$T/b/builds/b"
RK='demo-os XX-42 ticket/xx-41'
reset_state() { rm -f "$T/ledger.tsv" "$T/comment-calls.txt" "$T/gh-calls.txt" "$T/b/logs/stack-wait.log"; scratch_rm "$T/b/state"; }
put_row() { printf 'stack-wait\t%s\t%s\tsince=%s why=fixture\n' "$1" "$2" "$3" >> "$T/ledger.tsv"; }
# run_gate <PR_MODE> [VAR=val...] — prints "rc|BASE|STACK_ON"
run_gate() {
  local mode="$1" out rc; shift
  rm -f "$T/result"; : > "$T/rest-calls.txt"; scratch_rm "$BLD"; mkdir -p "$BLD"; touch "$BLD/pipeline.log"
  out=$( export T PR_MODE="$mode" HARNESS="$T/b" PROJECT=demo-os KEY=XX-42 TICKET=42 GH_AUTH_SLUG=example-org/demo-os \
           BUILD="$BLD" REPO="$T/repo" STACK_BASE=ticket/xx-41 SW_NOW="$NOW"
         [ $# -gt 0 ] && { export "$@" 2>/dev/null || true; }
         bash "$T/driver.sh" "$T/stack.sh" 2>/dev/null ); rc=$?
  printf '%s|%s\n' "$rc" "$out"
}
res()  { cat "$T/result" 2>/dev/null; }
plog() { cat "$BLD/pipeline.log" 2>/dev/null; }
rows() { awk -F'\t' '$1=="stack-wait"' "$T/ledger.tsv" 2>/dev/null | grep -c .; }
swl_n() { grep -c . "$T/b/logs/stack-wait.log" 2>/dev/null || echo 0; }

# D1 (acceptance 1, the TK-260 shape) — merged, branch kept, a waiting row under the cap.
reset_state; put_row "$RK" waiting $((NOW - 3600))
R=$(run_gate merged)
[ "$R" = "0|main|" ] && ok || bad "D1: a merged parent with its branch kept must build on main (got '$R' / $(res))"
[ -e "$T/result" ] && bad "D1: no RESULT for a merged parent (got: $(res))" || ok
grep -q 'stack-wait: parent PR #900 is merged and its branch ticket/xx-41 still exists — building on main, not stacked' <<<"$(plog)" \
  && ok || bad "D1: pipeline.log must name the merged PR #900 (got: $(plog))"
[ "$(rows)" = 1 ] && ok || bad "D1: no stack-wait row is written for a merged parent (got $(rows) rows)"

# D2 — merged, no row: not stacked, no pending file.
reset_state
R=$(run_gate merged)
[ "$R" = "0|main|" ] && ok || bad "D2: a merged parent must not be stacked on (got '$R')"
[ -e "$BLD/stack-wait-pending" ] && bad "D2: a merged parent leaves no stack-wait-pending file" || ok
grep -q 'STACKED on' <<<"$(plog)" && bad "D2: a merged parent must not stack" || ok

# D3 — merged under STACK_WAIT_PARENT_MERGE=all: builds, no defer.
reset_state
R=$(run_gate merged STACK_WAIT_PARENT_MERGE=all)
[ "$R" = "0|main|" ] && ok || bad "D3: merged under =all must build on main (got '$R' / $(res))"

# D4 — closed without a merge.
reset_state
R=$(run_gate closed)
[ "$R" = "0|main|" ] && ok || bad "D4: a closed parent must build on main (got '$R')"
grep -q 'stack-wait: parent PR #900 is closed without a merge and its branch ticket/xx-41 still exists — building on main, not stacked' <<<"$(plog)" \
  && ok || bad "D4: pipeline.log must say closed without a merge (got: $(plog))"

# D5 (acceptance 2) — open, waiting row under the cap: waits, as today.
reset_state; put_row "$RK" waiting $((NOW - 3600))
R=$(run_gate open)
[ "${R%%|*}" = 3 ] && ok || bad "D5: an open parent with a waiting row must exit 3 (got '$R')"
grep -q '^BUILD_DEFERRED stack-wait: parent branch ticket/xx-41 is still open' <<<"$(res)" \
  && ok || bad "D5: RESULT must be the existing wait (got: $(res))"

# D6 (acceptance 2) — open, no row, STACK_PARENT_PR unset: stacks, url from the REST read.
reset_state
R=$(run_gate open)
[ "$R" = "0|ticket/xx-41|ticket/xx-41" ] && ok || bad "D6: an open parent with no row stacks (plan gate pending) (got '$R')"
grep -q 'STACKED on ticket/xx-41 (https://github.com/example-org/demo-os/pull/900)' <<<"$(plog)" \
  && ok || bad "D6: the STACKED line must name pull/900 from the REST read (got: $(plog))"
[ -s "$T/gh-calls.txt" ] && bad "D6: the REST url makes the raw gh lookup unnecessary (got: $(cat "$T/gh-calls.txt"))" || ok

# D7 (acceptance 3) — the read fails (rc 75): waits, logged, no row, no comment.
reset_state
R=$(run_gate fail)
[ "${R%%|*}" = 3 ] && ok || bad "D7: an unreadable parent PR state must exit 3 (got '$R')"
grep -q '^BUILD_DEFERRED stack-wait: the state of parent PR for branch ticket/xx-41 could not be read (rc 75)' <<<"$(res)" \
  && ok || bad "D7: RESULT must name the unreadable state and rc 75 (got: $(res))"
[ "$(swl_n)" = 1 ] && grep -q 'parent-pr=unreadable rc=75 parent=ticket/xx-41 (deferred)' "$T/b/logs/stack-wait.log" 2>/dev/null \
  && ok || bad "D7: exactly one logs/stack-wait.log line with parent-pr=unreadable rc=75 (got: $(cat "$T/b/logs/stack-wait.log" 2>/dev/null))"
grep -q 'could not be read (rc 75)' <<<"$(plog)" && ok || bad "D7: pipeline.log must carry the reason (got: $(plog))"
[ "$(rows)" = 0 ] && ok || bad "D7: no stack-wait row is written (got $(rows))"
[ -s "$T/comment-calls.txt" ] && bad "D7: no comment is posted" || ok

# D8 — rc 44 and a junk body wait the same way.
for m in gone:44 junk:75; do
  reset_state
  R=$(run_gate "${m%%:*}")
  [ "${R%%|*}" = 3 ] && grep -q "^BUILD_DEFERRED stack-wait: the state of parent PR for branch ticket/xx-41 could not be read (rc ${m##*:})" <<<"$(res)" \
    && ok || bad "D8: PR_MODE=${m%%:*} must defer with rc ${m##*:} (got '$R' / $(res))"
done

# D9 — unreadable waits under =off and for a hotfix too.
for kv in STACK_WAIT_PARENT_MERGE=off HOTFIX=1; do
  reset_state
  R=$(run_gate fail "$kv")
  [ "${R%%|*}" = 3 ] && ok || bad "D9: an unreadable state must wait under $kv (got '$R')"
done

# D10 — no PR has that head: branch existence decides (today's path).
reset_state
R=$(run_gate none)
[ "$R" = "0|ticket/xx-41|ticket/xx-41" ] && ok || bad "D10: no PR and a live branch stacks as today (got '$R')"
grep -q 'stack-wait: parent PR state none for ticket/xx-41 — branch existence decides' <<<"$(plog)" \
  && ok || bad "D10: the fallback must be logged (got: $(plog))"

# D11 — unreadable and the branch is gone: today's build-on-base fallback.
reset_state
R=$(run_gate fail STACK_BASE=ticket/xx-40)
[ "$R" = "0|main|" ] && ok || bad "D11: an unreadable state with a deleted branch builds on main (got '$R')"
grep -q 'could not be fetched' <<<"$(plog)" && ok || bad "D11: the fetch fallback must be logged (got: $(plog))"
[ -e "$T/result" ] && bad "D11: no RESULT (got: $(res))" || ok

# D12 — the REST path.
reset_state
run_gate merged >/dev/null
grep -qx 'GET repos/example-org/demo-os/pulls?state=all&head=example-org:ticket/xx-41&per_page=100' "$T/rest-calls.txt" \
  && ok || bad "D12: the read must be GET repos/example-org/demo-os/pulls?state=all&head=example-org:ticket/xx-41&per_page=100 (got: $(cat "$T/rest-calls.txt"))"

# D13 — the kill switch skips the read.
reset_state
R=$(run_gate merged STACKED_BUILDS=0)
[ "$R" = "0|main|" ] && ok || bad "D13: STACKED_BUILDS=0 builds on main (got '$R')"
grep -q pulls "$T/rest-calls.txt" && bad "D13: STACKED_BUILDS=0 must make no pulls call" || ok

# D14 — no slug in the shell (unchecked): today's path.
reset_state
R=$(run_gate merged GH_AUTH_SLUG=)
[ "$R" = "0|ticket/xx-41|ticket/xx-41" ] && ok || bad "D14: an unchecked state with a live branch stacks as today (got '$R')"
grep -q 'stack-wait: parent PR state unchecked for ticket/xx-41 — branch existence decides' <<<"$(plog)" \
  && ok || bad "D14: the unchecked fallback must be logged (got: $(plog))"

echo "stack-wait-parent-pr: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
