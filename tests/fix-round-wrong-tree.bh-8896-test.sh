#!/bin/bash
# tests/fix-round-wrong-tree.bh-8896-test.sh — a fix round checks that its
# worktree is the PR's before any agent call, and stops FIX_ROUND_WRONG_TREE
# when it is not (BH-8896).
#
#   W1-W6 frt_check (bin/lib/fix-round-tree.sh) on real git repos: HEAD == lease
#         on brfix/<ck> is ok; a reused checkpoint that descends the lease is
#         ok; another HEAD, another branch, a checkpoint that does not descend
#         the lease are wrong (rc 1, `FIX_ROUND_WRONG_TREE:`); a HEAD that
#         cannot be read is not checked (rc 0, one stderr line). A HEAD that
#         shares the lease's first 8 hex is still another HEAD.
#   W7  the REAL bin/blocked-resolver.sh --fix-here, with a post-checkout hook
#       that moves the new worktree to another commit: FIX_RESULT setup-blocked
#       `FIX_ROUND_WRONG_TREE: …`, 0 agent calls, no fix round counted, the
#       worktree removed
#   W8  the same with no hook: the round reaches the agent (unchanged)
#   W9  the REAL bin/fix-round-claim.sh --run-pool: a round that answers that
#       setup-blocked prints `FIX_ROUND_WRONG_TREE … finish=ok`, and the lifted
#       run_fixround_job writes it to RESULT; W9b a `done` round still prints
#       `FIX_ROUND_FINISHED done finish=ok`
# 0 network calls: every remote is file://, curl and flyctl are recording stubs,
# the jobs API is a shell stub.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-wrong-tree.bh-8896-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/fix-round-tree.sh"

# ── W1-W6: frt_check on real repos ───────────────────────────────────────────
R="$T/w"; git init -q "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'a\n' > "$R/a"; git -C "$R" add -A; git -C "$R" commit -qm one
L=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b brfix/ck
# frt <wt> <want> <lease> <reuse> -> RC, OUT, ERR
frt() { OUT=$( ( . "$LIB" && frt_check "$@" ) 2>"$T/frt.err" ); RC=$?; ERR=$(cat "$T/frt.err"); }
[ -r "$LIB" ] && ok || bad "W0: bin/lib/fix-round-tree.sh is missing"
frt "$R" brfix/ck "$L" 0
[ "$RC" = 0 ] && ok || bad "W1: HEAD == lease on brfix/ck must pass (rc=$RC out=$OUT)"
printf 'b\n' > "$R/a"; git -C "$R" commit -qam two
frt "$R" brfix/ck "$L" 1
[ "$RC" = 0 ] && ok || bad "W2: a reused checkpoint that descends the lease must pass (rc=$RC out=$OUT)"
frt "$R" brfix/ck "$L" 0
[ "$RC" = 1 ] && ok || bad "W3: HEAD != lease on a fresh tree must fail (rc=$RC)"
[[ "$OUT" == "FIX_ROUND_WRONG_TREE: "* ]] && ok || bad "W3: the reason starts FIX_ROUND_WRONG_TREE: (got '$OUT')"
[[ "$OUT" == *"${L:0:8}"* ]] && ok || bad "W3: the reason names the lease (got '$OUT')"
# W3b near miss: the same first 8 hex, another sha.
frt "$R" brfix/ck "${L:0:8}$(printf '%032d' 0)" 0
[ "$RC" = 1 ] && ok || bad "W3b: a lease that shares 8 hex with nothing on this tree must fail (rc=$RC)"
git -C "$R" checkout -q -b brfix/other
frt "$R" brfix/ck "$(git -C "$R" rev-parse HEAD)" 0
[ "$RC" = 1 ] && ok || bad "W4: another brfix branch must fail (rc=$RC)"
[[ "$OUT" == *"brfix/other"* ]] && ok || bad "W4: the reason names the branch (got '$OUT')"
git -C "$R" checkout -q --detach
frt "$R" brfix/ck "$(git -C "$R" rev-parse HEAD)" 0
[ "$RC" = 1 ] && ok || bad "W4b: a detached HEAD must fail (rc=$RC out=$OUT)"
mkdir -p "$T/notgit"
frt "$T/notgit" brfix/ck "$L" 0
[ "$RC" = 0 ] && ok || bad "W5: an unreadable HEAD is not proof of a wrong tree (rc=$RC)"
[[ "$ERR" == *"not checked"* ]] && ok || bad "W5: one stderr line says it was not checked (got '$ERR')"
[ -z "$OUT" ] && ok || bad "W5: no FIX_ROUND_WRONG_TREE on stdout (got '$OUT')"
git -C "$R" checkout -q brfix/ck
git -C "$R" checkout -q --orphan tmp; git -C "$R" commit -qm unrelated --allow-empty
U=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q brfix/ck; git -C "$R" reset -q --hard "$U"
frt "$R" brfix/ck "$L" 1
[ "$RC" = 1 ] && ok || bad "W6: a reused checkpoint that does not descend the lease must fail (rc=$RC)"

# ── W7, W8: the real --fix-here, the bh-8458 rig ─────────────────────────────
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin/blocked-resolver.d" "$H/bin/lib"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh bin/lib/token-redact.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
[ -r "$LIB" ] && { scratch_install_closure bin/lib/fix-round-tree.sh "$H" >/dev/null || bad "W7: closure of bin/lib/fix-round-tree.sh"; }
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes (fx_br_harness installs it)
fx_br_ladder_git "$DIR" "$T" || exit 1
for v in curl flyctl; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/vendor-calls.txt"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
: > "$T/vendor-calls.txt"
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf 'both sides, resolved\n' > a.txt
git add -A >/dev/null 2>&1
git commit -q -m "fix round: resolved the merge" >/dev/null 2>&1
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"
PR88="https://github.com/o/tproj/pull/88"
LOGF="$H/logs/blocked-resolver.log"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj sfr-1 conflict-unresolvable "$PR88" - - < "$T/rec-in.json" ) > "$T/run.out" 2>&1; }
RESET() { # RESET <branch> <base>
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf '%s\n' "$2" > "$T/prbase"
  printf 'conductor: conflict-unresolvable\n' > "$T/findings"
  jq -nc '{project:"tproj",rkey:"sfr-1",fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
SETUP_DETAIL() { sed -n 's/^FIX_RESULT setup-blocked //p' "$T/run.out" | tail -n 1 | base64 -d 2>/dev/null; }
AGENTS() { grep -c . "$T/agent.txt" 2>/dev/null || true; }
WTS() { find "$H/tmp/brfix" -mindepth 1 -maxdepth 1 -name 'brfix-*' 2>/dev/null | wc -l; }
HOOK="$T/repos/tproj/.git/hooks/post-checkout"

# W7: the tree the round gets is not the PR head.
RESET ticket/TK-88 main
MAINSHA=$(osha main)
printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\ngit reset -q --hard %s\n' "$MAINSHA" > "$HOOK"; chmod +x "$HOOK"
C0=$(osha ticket/TK-88)
FIXHERE
rm -f "$HOOK"
D7=$(SETUP_DETAIL)
[[ "$D7" == "FIX_ROUND_WRONG_TREE: "* ]] && ok || bad "W7 THE POINT: the round must stop setup-blocked 'FIX_ROUND_WRONG_TREE:' (got '$D7'; out: $(tail -3 "$T/run.out"); log: $(tail -3 "$LOGF"))"
[ "$(AGENTS)" = 0 ] && ok || bad "W7 THE POINT: a wrong tree spent $(AGENTS) agent call(s)"
[ "$(osha ticket/TK-88)" = "$C0" ] && ok || bad "W7: the PR branch moved"
[ "$(WTS)" = 0 ] && ok || bad "W7: the worktree was left behind: $(ls "$H/tmp/brfix")"
[ "$(sed -n 's/^FIX_RECORD //p' "$T/run.out" | tail -n 1 | base64 -d 2>/dev/null | jq -r '.fixrounds // 0' 2>/dev/null)" = 0 ] && ok \
  || bad "W7: a wrong tree counts no fix round"

# W8: no hook — the normal round, unchanged.
RESET ticket/TK-88 main
FIXHERE
[ "$(AGENTS)" -ge 1 ] && ok || bad "W8: the normal round must reach the agent (detail: $(SETUP_DETAIL); log: $(tail -3 "$LOGF"))"
grep -q 'FIX_ROUND_WRONG_TREE' "$T/run.out" "$LOGF" && bad "W8: the guard fired on the PR's own tree" || ok
[ -s "$T/vendor-calls.txt" ] && bad "Z: a vendor was called: $(cat "$T/vendor-calls.txt")" || ok

# ── W9: --run-pool and run_fixround_job carry the word ───────────────────────
FH="$T/fh"; mkdir -p "$FH/bin/lib" "$FH/env" "$FH/logs" "$FH/locks" "$FH/state"
scratch_install_closure bin/fix-round-claim.sh "$FH" >/dev/null || { echo "FAIL: closure of bin/fix-round-claim.sh"; exit 1; }
: > "$FH/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$FH/bin/fleet-conf.sh"
cat > "$FH/bin/jobs-client.sh" <<EOF
jobs_configured() { return 0; }
_jobs_req() {
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/fh.calls"
  case "\$1 \$2" in
    "GET /api/fix-rounds"*) printf '{"fix_round_jobs":[{"id":12,"project":"p","cap_key":"ck","box":"b1","status":"claimed","claimed_by":"b1","attempt":1,"args":"[\\\\"p\\\\",\\\\"rk\\\\",\\\\"r\\\\",\\\\"https://u/1\\\\",\\\\"rec\\\\",\\\\"tk\\\\"]","record_in":null}]}' ;;
    "POST /api/fix-rounds/finish") echo '{}' ;;
  esac
  return 0
}
EOF
# brmode <FIX_RESULT text> — the round's one answer
brmode() { printf '#!/bin/bash\necho "FIX_RESULT %s"\nexit 0\n' "$1" > "$FH/bin/blocked-resolver.sh"; chmod +x "$FH/bin/blocked-resolver.sh"; }
RUNPOOL() { ( export HARNESS="$FH" HARNESS_SECRET=fixture BR_FIX_LANE_TIMEOUT=60 PATH="$T/fakebin:$PATH"
             bash "$FH/bin/fix-round-claim.sh" --run-pool 12 b1 p ck 2>/dev/null | head -1 ); }
WT64=$(printf '%s' "FIX_ROUND_WRONG_TREE: /x is on brfix/other, not brfix/ck" | base64 -w0)
: > "$T/fh.calls"; brmode "setup-blocked $WT64"
L9=$(RUNPOOL)
[[ "$L9" == "FIX_ROUND_WRONG_TREE "* ]] && ok || bad "W9 THE POINT: --run-pool must print FIX_ROUND_WRONG_TREE, got '$L9' (calls: $(cat "$T/fh.calls"))"
[[ "$L9" == *" finish=ok" ]] && ok || bad "W9: the word line ends finish=ok, got '$L9'"
[[ "$L9" == *"brfix/other"* ]] && ok || bad "W9: the word line carries the decoded reason, got '$L9'"
grep -q '^POST /api/fix-rounds/finish .*setup-blocked' "$T/fh.calls" && ok || bad "W9: the finish is setup-blocked: $(cat "$T/fh.calls")"
# The machine side: run_fixround_job writes the word to RESULT.
RF="$T/runner-fns.sh"
awk '/^run_fixround_job\(\) \{/,/^\}/; /^fixround_setup_result\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$RF"
jq -nc '{key:"FXR-12-fixture1",fixround:{id:"12",box:"b1",project:"p",cap_key:"ck"}}' > "$T/job.json"
RUNJOB() { ( export PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture BR_FIX_LANE_TIMEOUT=60
             JOB="$T/job.json" RESULT_FILE="$T/RESULT" HARNESS="$FH" PROJECT=p REPO="$T/repos/p" ENVDIR="$FH/env"
             log() { :; }; beat() { :; }; warm_up() { return 0; }
             . "$RF"; run_fixround_job FXR-12-fixture1 ); }
rm -f "$T/RESULT"; RUNJOB
[[ "$(head -1 "$T/RESULT" 2>/dev/null)" == "FIX_ROUND_WRONG_TREE "* ]] && ok || bad "W9: RESULT must carry FIX_ROUND_WRONG_TREE, got '$(cat "$T/RESULT" 2>/dev/null)'"
bash "$DIR/bin/result-prefix-ok.sh" "$(head -1 "$T/RESULT" 2>/dev/null)" && ok || bad "W9: the pool gates must admit the word"
# W9b a normal round: unchanged.
brmode done
L9b=$(RUNPOOL)
[ "$L9b" = "FIX_ROUND_FINISHED done finish=ok" ] && ok || bad "W9b: a done round prints FIX_ROUND_FINISHED done finish=ok, got '$L9b'"
OT64=$(printf '%s' "worktree add failed for origin/x" | base64 -w0)
brmode "setup-blocked $OT64"
L9c=$(RUNPOOL)
[ "$L9c" = "FIX_ROUND_FINISHED setup-blocked finish=ok" ] && ok || bad "W9c: another setup-blocked is unchanged, got '$L9c'"

echo "fix-round-wrong-tree.bh-8896: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
