#!/bin/bash
# tests/main-merge-need.bh-7042-test.sh — merge origin/main into a PR branch
# only on a real conflict (BH-7042).
#
# A clean merge of main makes a new head: the head loses its lead verdict, a
# running Mac gate stops as STALE and CI runs again. The merge queue already
# tests every PR on current main (#6988, 2026-10-16). This suite pins:
#
#   L1-L10  bin/lib/main-merge-need.sh pr_needs_main_merge, on real git repos
#           and a gh stub that serves one fixture PR object.
#   R1-R3   bin/review-rescue.sh (the real lane): a clean branch opens its PR
#           with no main merge; a conflict still gets no PR; a stale schema.d
#           stamp still gets the merge.
#   N1-N2   bin/lander.sh (the real lane): a clean PR is not merged into and buys
#           no session; a conflicting PR still reaches the agent.
#   M1-M6   bin/blocked-resolver.sh (the real lane), mechanical rung: a clean PR
#           gets no mc_rebase; a clean conflict park is cleared; a queued PR is
#           never merged into; a conflict, a stale stamp, the gate off and a
#           missing repo still call mc_rebase.
#   P1-P2   the execute and fix-round prompts carry the new sentence.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-merge-need.bh-7042-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GH_TOKEN="" GH_ETAG=0
NOHEAD=0000000000000000000000000000000000000bad

# ── the fixture origin ──────────────────────────────────────────────────────
# main: a.txt + one schema.d stamp. Branches cut from it:
#   ticket/bh-11     adds b.txt                         (clean against main)
#   ticket/bh-12  edits a.txt line 1                 (main edits it too)
#   ticket/bh-13     adds a schema.d stamp older than main's newest
# then main moves: a.txt line 1, and a newer stamp.
mkorigin() { # mkorigin <dir> -> <dir>/origin.git
  local O="$1/origin.git" W="$1/seed"
  git init -q --bare "$O"
  mkdir -p "$W/worker/jobs/schema.d"
  (
    cd "$W" || exit 1
    git init -q . && git checkout -q -b main
    printf 'one\ntwo\n' > a.txt
    echo base > worker/jobs/schema.d/202610010000-bh-1-base.sql
    git add -A && git commit -qm init && git remote add origin "$O" && git push -q origin main
    git checkout -q -b ticket/bh-11 main; echo b > b.txt
    git add -A && git commit -qm "BH-11: clean" && git push -q origin ticket/bh-11
    git checkout -q -b ticket/bh-12 main; printf 'branch\ntwo\n' > a.txt
    git add -A && git commit -qm "BH-12: conflict" && git push -q origin ticket/bh-12
    git checkout -q -b ticket/bh-13 main; echo x > worker/jobs/schema.d/202609150000-bh-13-x.sql
    git add -A && git commit -qm "BH-13: stale stamp" && git push -q origin ticket/bh-13
    git checkout -q main; printf 'main\ntwo\n' > a.txt
    echo y > worker/jobs/schema.d/202610020000-bh-3-y.sql
    git add -A && git commit -qm "main moves" && git push -q origin main
  ) >/dev/null 2>&1
  git -C "$O" symbolic-ref HEAD refs/heads/main
}
mkorigin "$T"
sha_of() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }
SH_CLEAN=$(sha_of ticket/bh-11); SH_CONF=$(sha_of ticket/bh-12); SH_STALE=$(sha_of ticket/bh-13)

# ── the gh stub ─────────────────────────────────────────────────────────────
# $T/pr.json is the PR object GitHub would answer (labels, mergeable,
# mergeable_state, head, base). $T/gh-fail makes the PR read fail. Every call
# is logged to $T/gh.txt. Routes it does not know go to tests/lib/gh-rest-stub.sh
# (-i) or answer nothing.
prj() { # prj <sha> <ref> <mergeable true|false|null> <mergeable_state> [label ...]
  jq -nc --arg sha "$1" --arg ref "$2" --argjson m "$3" --arg s "$4" --args \
    '{state:"open",title:"FIXTURE PR",head:{sha:$sha,ref:$ref},base:{ref:"main"},
      mergeable:$m,mergeable_state:$s,labels:[$ARGS.positional[]|{name:.}]}' "${@:5}" > "$T/pr.json"
}
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"[0-9]*)
    if [[ "\$*" =~ /pulls/[0-9]+( |\$) ]]; then
      { [ -f "$T/gh-fail" ] || [ ! -s "$T/pr.json" ]; } && { printf 'HTTP/2 502\r\n\r\n{}'; exit 1; }
      printf 'HTTP/2 200\r\n\r\n%s' "\$(cat "$T/pr.json")"; exit 0
    fi ;;
esac
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@"; exit 0 ;;
  *"pr view"*) [ -s "$T/pr.json" ] && jq -r '.head.ref + " " + .head.sha' "$T/pr.json"; exit 0 ;;
  *"actions/runs?head_sha="*) echo 555; exit 0 ;;
  *"/pulls/"[0-9]*) [ -s "$T/pr.json" ] && jq -r '.head.sha + " " + .head.ref' "$T/pr.json"; exit 0 ;;
  *"pr create"*) printf '%s\n' "\$*" >> "$T/pr-creates.txt"; echo "https://github.com/o/tproj/pull/777"; exit 0 ;;
esac
echo ""
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/gh" "$T/fakebin/flock"
export PATH="$T/fakebin:$PATH"

# ═══ L. pr_needs_main_merge ═════════════════════════════════════════════════
LREPO="$T/lrepo"
git clone -q "$T/origin.git" "$LREPO"
need() { # need <pr|-> <head> -> OUT, RC
  OUT=$(HARNESS="$T/lh" bash -c '. "$1" || exit 9; pr_needs_main_merge o/tproj "$2" "$3" "$4" origin/main' \
        _ "$DIR/bin/lib/main-merge-need.sh" "$1" "$LREPO" "$2" 2>/dev/null)
  RC=$?
}
mkdir -p "$T/lh"
lreset() { rm -f "$T/gh-fail" "$T/pr.json"; : > "$T/gh.txt"; }

lreset; prj "$SH_CLEAN" ticket/bh-11 true clean
need 5 "$SH_CLEAN"; eq "L1 clean, GitHub mergeable" "$OUT/$RC" "clean/1"
grep -q -- '-i -X GET repos/o/tproj/pulls/5' "$T/gh.txt" && ok || bad "L1: the PR must be read over REST: $(cat "$T/gh.txt")"
grep -qE 'pr view|graphql' "$T/gh.txt" && bad "L1: no GraphQL read: $(cat "$T/gh.txt")" || ok

lreset; prj "$SH_CONF" ticket/bh-12 null unknown
need 5 "$SH_CONF"; eq "L2 merge-tree conflict" "$OUT/$RC" "conflict-merge-tree/0"

lreset; prj "$SH_STALE" ticket/bh-13 true clean
need 5 "$SH_STALE"; eq "L3 stale schema.d stamp on a clean tree" "$OUT/$RC" "schema-stamp/0"

lreset; prj "$SH_CLEAN" ticket/bh-11 true clean
OUT=$(MAIN_MERGE_GATE=0 bash -c '. "$1"; pr_needs_main_merge o/tproj 5 "$2" "$3" origin/main' _ "$DIR/bin/lib/main-merge-need.sh" "$LREPO" "$SH_CLEAN"); RC=$?
eq "L4 MAIN_MERGE_GATE=0" "$OUT/$RC" "gate-off/0"

lreset; prj "$SH_CLEAN" ticket/bh-11 null dirty
need 5 "$SH_CLEAN"; eq "L5 GitHub dirty, tree clean (stale local main)" "$OUT/$RC" "conflict-github/0"
lreset; prj "$SH_CLEAN" ticket/bh-11 false unknown
need 5 "$SH_CLEAN"; eq "L5b GitHub mergeable=false" "$OUT/$RC" "conflict-github/0"

lreset; prj "$SH_CLEAN" ticket/bh-11 true clean; : > "$T/gh-fail"
need 5 "$SH_CLEAN"; eq "L6 GitHub read fails, tree clean" "$OUT/$RC" "clean/1"

lreset; prj "$SH_CONF" ticket/bh-12 false dirty queued
need 5 "$SH_CONF"; eq "L7 queued label wins over dirty" "$OUT/$RC" "queued/1"
lreset; prj "$SH_CLEAN" ticket/bh-11 true clean checking
need 5 "$SH_CLEAN"; eq "L7b checking label" "$OUT/$RC" "queued/1"

lreset; prj "$NOHEAD" ticket/bh-11 true clean
need 5 "$NOHEAD"; eq "L8 GitHub mergeable, head not in the repo" "$OUT/$RC" "clean/1"

lreset; : > "$T/gh-fail"
need 5 "$NOHEAD"; eq "L9 GitHub fails and head not in the repo" "$OUT/$RC" "unknown/2"
lreset
need - "$NOHEAD"; eq "L9b no PR and a bad head" "$OUT/$RC" "unknown/2"
[ -s "$T/gh.txt" ] && bad "L9b: no PR number, no GitHub read: $(cat "$T/gh.txt")" || ok

lreset; prj "$SH_CONF" ticket/bh-12 null unknown merge-queue
need 5 "$SH_CONF"; eq "L10 merge-queue request label only + conflict" "$OUT/$RC" "conflict-merge-tree/0"

# ═══ P. the prompts ═════════════════════════════════════════════════════════
EXB=$(sed -n '/^# >>> execute prompt/,/^# <<< execute prompt/p' "$DIR/bin/lib/rb/execute.sh")
[ -n "$EXB" ] && ok || bad "P1: the execute prompt block markers are gone"
# TEST-CHANGE (BH-7970): the block renders prompts/stages/execute.md; the sentence is read from that template.
grep -q 'sp_render execute ' <<<"$EXB" && ok || bad "P1: the execute prompt block no longer renders prompts/stages/execute.md"
eq "P1 the execute prompt says when not to merge main" \
  "$(grep -c 'Do not merge origin/main into this branch unless it conflicts with main: the merge queue tests every PR on current main' "$DIR/prompts/stages/execute.md")" 1
FRP=$(grep -m1 '^  prompt="FIX ROUND on an open pull request' "$DIR/bin/blocked-resolver.sh")
[ -n "$FRP" ] && ok || bad "P2: the fix-round prompt line is gone"
grep -qF 'do not merge origin/main again unless this branch still conflicts with main: the merge queue tests every PR on current main' <<<"$FRP" \
  && ok || bad "P2: the fix-round prompt must say when not to merge main"

# ═══ R. bin/review-rescue.sh ════════════════════════════════════════════════
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
RH="$T/rh"
mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/flags" "$RH/locks" "$RH/builds" "$RH/env" "$T/rrepos"
scratch_install_closure bin/review-rescue.sh "$RH" >/dev/null || { echo "FAIL: closure install (review-rescue)"; exit 1; }
for f in project-of.sh fleet-conf.sh fleet-projects-or-alert.sh test-tamper-scan.sh alert-line.sh; do
  scratch_install_closure "bin/$f" "$RH" >/dev/null || { echo "FAIL: closure install ($f)"; exit 1; }
done
printf 'tproj o/tproj - - 2 box-tproj\n' > "$RH/fleet.conf"
: > "$RH/env/global.env"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$RH" tproj
cat > "$RH/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2" >> "$T/review-calls.txt"
RM=\$(printf '%s' "\${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
[ -n "\$RM" ] && printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "\$RM"
[ -n "\${5:-}" ] && : > "\$5"
exit 0
EOF
chmod +x "$RH/bin/agent-call.sh"
ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }
TAMPER_RESULT="REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification; see x"
rrun() { # rrun <KEY> -> a fresh clone, one rescue candidate, one run
  scratch_rm "$T/rrepos"; scratch_rm "$RH/builds"; scratch_rm "$RH/logs"
  mkdir -p "$T/rrepos" "$RH/builds" "$RH/logs"
  scratch_rm "$T/ro"; mkdir -p "$T/ro"; git clone -q --bare "$T/origin.git" "$T/ro/origin.git"
  git clone -q "$T/ro/origin.git" "$T/rrepos/tproj"
  : > "$T/pr-creates.txt"; : > "$T/review-calls.txt"; : > "$T/gh.txt"; rm -f "$T/pr.json"
  RD="$RH/builds/pool-tproj-$1-202610170000"
  mkdir -p "$RD"; printf '%s\n' "$TAMPER_RESULT" > "$RD/RESULT"
  printf '# %s\n\n## Tasks\n' "$1" > "$RD/plan.md"
  touch -t "$(ago 200)" "$RD/RESULT"
  HARNESS="$RH" FLEET_CONF="$RH/fleet.conf" REPOS_ROOT="$T/rrepos" bash "$RH/bin/review-rescue.sh" >>"$T/rrun.log" 2>&1
}
rbr() { git -C "$T/ro/origin.git" rev-parse "refs/heads/$1"; }
anc() { git -C "$T/ro/origin.git" merge-base --is-ancestor main "$1"; }

# R1. a clean branch: no merge, no push, the PR opens on the pushed head.
rrun BH-11
B0=$(git -C "$T/rrepos/tproj" rev-parse origin/ticket/bh-11)
grep -q -- '--head ticket/bh-11' "$T/pr-creates.txt" && ok \
  || bad "R1: the PR must still be opened (creates: $(cat "$T/pr-creates.txt"); log: $(tail -3 "$RH/logs/review-rescue.log" 2>/dev/null))"
anc ticket/bh-11 && bad "R1: origin/main was merged into a branch that is clean against main" || ok
eq "R1 the branch head did not move" "$(rbr ticket/bh-11)" "$B0"
grep -q 'pool-tproj-BH-11-202610170000: main merge skipped: clean against main' "$RH/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "R1: the log must say the merge was skipped: $(tail -3 "$RH/logs/review-rescue.log" 2>/dev/null)"
[ -f "$RD/.conflicts-with-main" ] && bad "R1: a clean branch must not be marked conflicting" || ok

# R2. a conflicting branch: today's behaviour, no PR, the candidate marked.
rrun BH-12
[ -s "$T/pr-creates.txt" ] && bad "R2: no PR for a branch that conflicts with main" || ok
[ -f "$RD/.conflicts-with-main" ] && ok || bad "R2: the conflict marker must be written (log: $(tail -3 "$RH/logs/review-rescue.log" 2>/dev/null))"
grep -q 'main merge skipped' "$RH/logs/review-rescue.log" 2>/dev/null && bad "R2: a conflict is never a skip" || ok

# R3. a stale schema.d stamp on a clean tree: main IS merged and pushed.
rrun BH-13
anc ticket/bh-13 && ok || bad "R3: a stale schema.d stamp must still get the main merge (log: $(tail -3 "$RH/logs/review-rescue.log" 2>/dev/null))"
grep -q -- '--head ticket/bh-13' "$T/pr-creates.txt" && ok || bad "R3: the PR must be opened after the merge"

# ═══ N. bin/lander.sh ═══════════════════════════════════════════════════════
# bin/lander.sh hardcodes its two roots (tests/env-path-allowlist.d/port-b.txt),
# so the scratch copy rewrites both, the way tests/lander-fixture-modules.bh-1330-test.sh
# does, and asserts that the rewrites matched.
NH="$T/nh"
mkdir -p "$NH/bin/lib" "$NH/env" "$NH/flags" "$NH/logs" "$NH/state" "$NH/repos"
scratch_install_closure bin/lander.sh "$NH" >/dev/null || { echo "FAIL: closure install (lander)"; exit 1; }
scratch_install_closure bin/fleet-conf.sh "$NH" >/dev/null || { echo "FAIL: closure install (fleet-conf)"; exit 1; }
sed -e 's|^HARNESS=/root/harness$|HARNESS="${HARNESS:-/root/harness}"|' \
    -e 's|^REPO_DIR="/root/repos/\$PROJECT"$|REPO_DIR="$HARNESS/repos/$PROJECT"|' \
    "$DIR/bin/lander.sh" > "$NH/bin/lander.sh"
grep -qF 'HARNESS="${HARNESS:-/root/harness}"' "$NH/bin/lander.sh" && grep -qF 'REPO_DIR="$HARNESS/repos/$PROJECT"' "$NH/bin/lander.sh" \
  && ok || { echo "FAIL: N: the scratch-root rewrite of bin/lander.sh did not match"; exit 1; }
printf 'project-3 o/project-3\n' > "$NH/fleet.conf"
: > "$NH/env/global.env"
cat > "$NH/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2" >> "$T/lander-agent.txt"
printf 'LANDER_BLOCKED: fixture agent\n' > "\$5"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$NH/bin/beat.sh"
chmod +x "$NH/bin/lander.sh" "$NH/bin/agent-call.sh" "$NH/bin/beat.sh"
nrun() { # nrun <branch> <sha> <mergeable> <state> -> NRC
  scratch_rm "$NH/repos"; scratch_rm "$NH/state"; scratch_rm "$T/no"; mkdir -p "$NH/repos" "$NH/state" "$T/no"
  git clone -q --bare "$T/origin.git" "$T/no/origin.git"; git clone -q "$T/no/origin.git" "$NH/repos/project-3"
  : > "$T/lander-agent.txt"; : > "$T/gh.txt"; rm -f "$NH/logs/lander.log"
  prj "$2" "$1" "$3" "$4"
  HARNESS="$NH" LANDER_MODEL=fixture-model bash "$NH/bin/lander.sh" project-3 7 >"$T/nrun.log" 2>&1; NRC=$?
}

# N1. a clean PR: not merged into, no session bought, exit 1.
nrun ticket/bh-11 "$SH_CLEAN" true clean
eq "N1 the lander exits 1 on a clean PR" "$NRC" 1
[ -s "$T/lander-agent.txt" ] && bad "N1: no resolution session for a clean PR: $(cat "$T/lander-agent.txt")" || ok
eq "N1 the branch head did not move" "$(git -C "$T/no/origin.git" rev-parse refs/heads/ticket/bh-11)" "$SH_CLEAN"
grep -q '#7 lander: main merge skipped: clean against main' "$NH/logs/lander.log" 2>/dev/null && ok \
  || bad "N1: lander.log must say the merge was skipped: $(cat "$NH/logs/lander.log" 2>/dev/null; tail -3 "$T/nrun.log")"

# N2. a conflicting PR: the merge runs and the agent is asked, as before.
nrun ticket/bh-12 "$SH_CONF" false dirty
[ -s "$T/lander-agent.txt" ] && ok \
  || bad "N2: a conflicting PR must still reach the resolution agent: $(cat "$NH/logs/lander.log" 2>/dev/null; tail -3 "$T/nrun.log")"
grep -q 'main merge skipped' "$NH/logs/lander.log" 2>/dev/null && bad "N2: a conflict is never a skip" || ok

# ═══ M. bin/blocked-resolver.sh, the mechanical rung ════════════════════════
MH="$T/mh"
mkdir -p "$MH/bin/lib" "$MH/logs" "$MH/state/merge-conductor" "$MH/state/build-queue/tproj" "$MH/flags" \
         "$MH/locks" "$MH/env" "$MH/builds" "$T/mrepos"
for f in bin/blocked-resolver.sh bin/fleet-conf.sh bin/project-of.sh bin/box-for.sh; do
  scratch_install_closure "$f" "$MH" >/dev/null || { echo "FAIL: closure install ($f)"; exit 1; }
done
[ -f "$MH/bin/lib/br-main-merge.sh" ] && [ -f "$MH/bin/lib/main-merge-need.sh" ] && ok \
  || bad "M: bin/blocked-resolver.sh must source bin/lib/br-main-merge.sh (and it bin/lib/main-merge-need.sh)"
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$MH/fleet.conf"
: > "$MH/env/global.env"
mrs_fixture "$MH" tproj
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$MH/bin/$f"; chmod +x "$MH/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$1 $2" >> "%s/br-agent.txt"\nexit 0\n' "$T" > "$MH/bin/agent-call.sh"
chmod +x "$MH/bin/"*.sh
# mc_rebase, the rung's merge, is the one thing stubbed: it records its call and
# answers rc 1 (still conflicts), so a call is a fact the case reads.
cat >> "$MH/bin/lib/merge-conductor-lib.sh" <<EOF
# --- fixture override: mc_rebase records its call ---------------------------
mc_rebase() { printf '%s\n' "\$*" >> "$T/rebase.txt"; printf 'a.txt\n'; return 1; }
EOF
NOW=$(date -u +%s)
mrow() { # mrow <reason> <head> <num>
  printf 'o/tproj#%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$3" "$NOW" "$2" "$2" "$1" "https://github.com/o/tproj/pull/$3" \
    > "$MH/state/merge-conductor/pr-state.tsv"
}
mstate() { cat "$MH/state/blocked-resolver/tproj/"*.json 2>/dev/null; }
mrun() { # mrun <reason> <branch> <sha> <mergeable> <state> <num> [label ...]
  local reason="$1" brn="$2" sha="$3" m="$4" st="$5" num="$6"; shift 6
  scratch_rm "$MH/state/blocked-resolver"; scratch_rm "$T/mrepos"; scratch_rm "$T/mo"; mkdir -p "$T/mrepos" "$T/mo"
  git clone -q --bare "$T/origin.git" "$T/mo/origin.git"
  [ "${MRM_NOREPO:-0}" = 1 ] || git clone -q "$T/mo/origin.git" "$T/mrepos/tproj"
  rm -f "$MH/state/merge-conductor/handoff-released/"* 2>/dev/null
  : > "$T/rebase.txt"; : > "$T/reruns.txt"; : > "$T/br-agent.txt"; : > "$T/gh.txt"
  : > "$MH/logs/blocked-resolver.log"; : > "$T/closed.txt"
  prj "$sha" "$brn" "$m" "$st" "$@"
  printf '%s\n' "$sha" > "$T/prhead"; printf '%s\n' "$brn" > "$T/prbranch"
  mrow "$reason" "$sha" "$num"
  # The PR's build record: the park is dated from its RESULT (br_park_time).
  scratch_rm "$MH/builds"; mkdir -p "$MH/builds/pool-tproj-${brn#ticket/}-202610170000"
  printf 'PR_CREATED https://github.com/o/tproj/pull/%s\n' "$num" > "$MH/builds/pool-tproj-${brn#ticket/}-202610170000/RESULT"
  ( HARNESS="$MH" FLEET_CONF="$MH/fleet.conf" REPOS_ROOT="$T/mrepos" BR_SSH=/bin/true \
      BR_UNCHANGED_RECHECK_S=0 bash "$MH/bin/blocked-resolver.sh" >"$T/mrun.log" 2>&1 ) || true
}
mlog() { tail -6 "$MH/logs/blocked-resolver.log" 2>/dev/null; }
mech() { mstate | jq -r '.mechanicals // 0' 2>/dev/null || echo 0; }
mlast() { mstate | jq -r '.attempts[-1].action // ""' 2>/dev/null; }

# M1. a red-CI park on a clean PR: no mc_rebase; the failed CI is re-run.
mrun red-ci-twice ticket/bh-11 "$SH_CLEAN" true clean 91
[ -s "$T/rebase.txt" ] && bad "M1: mc_rebase must not merge main into a clean PR: $(cat "$T/rebase.txt")" || ok
grep -q 'actions/runs/555/rerun-failed-jobs' "$T/reruns.txt" && ok || bad "M1: the failed CI must be re-run: $(mlog)"
grep -q 'tproj/.*\[red-ci-twice\]: main merge skipped: clean against main' "$MH/logs/blocked-resolver.log" && ok \
  || bad "M1: the log must say the merge was skipped: $(mlog)"
eq "M1 the CI re-run is the rung (mechanicals)" "$(mech)" 1

# M2. a conflict park whose conflict is gone: cleared, no merge, no rung spent,
# the hand-off released to the conductor.
mrun conflict-unresolvable ticket/bh-11 "$SH_CLEAN" true clean 92
[ -s "$T/rebase.txt" ] && bad "M2: mc_rebase must not merge main into a PR that no longer conflicts: $(cat "$T/rebase.txt")" || ok
eq "M2 the record says conflict-cleared" "$(mlast)" conflict-cleared
eq "M2 no rung spent" "$(mech)" 0
grep -q 'main merge skipped: clean against main — the conflict park is cleared' "$MH/logs/blocked-resolver.log" && ok \
  || bad "M2: the log must say the park is cleared: $(mlog)"
grep -q 'EVENT conflict-cleared' "$MH/logs/blocked-resolver.log" && ok || bad "M2: one EVENT line: $(mlog)"
ls "$MH/state/merge-conductor/handoff-released/" 2>/dev/null | grep -q . && ok \
  || bad "M2: the conductor hand-off must be released: $(mlog)"
[ -s "$T/br-agent.txt" ] && bad "M2: no fix round on a cleared park: $(cat "$T/br-agent.txt")" || ok
[ -s "$T/closed.txt" ] && bad "M2: a cleared park closes nothing: $(cat "$T/closed.txt")" || ok
grep -qE 'REBUILD|ABANDONED' <<<"$(mstate | jq -r '.outcome // ""')" && bad "M2: a cleared park is no terminal" || ok

# M2b. a `rebase-gate-red` park on a clean tree: the merge is clean by
# definition for this park, so it is NOT a cleared conflict. It merges as
# before (mc_rebase once), so it keeps its path to the fix round.
mrun rebase-gate-red ticket/bh-11 "$SH_CLEAN" true clean 98
eq "M2b mc_rebase is called once on a rebase-gate-red park" "$(grep -c . "$T/rebase.txt")" 1
[ "$(mlast)" = conflict-cleared ] && bad "M2b: a rebase-gate-red park is never conflict-cleared: $(mlog)" || ok
grep -q 'conflict park is cleared' "$MH/logs/blocked-resolver.log" && bad "M2b: no cleared line on a rebase-gate-red park: $(mlog)" || ok
grep -q 'main merge skipped' "$MH/logs/blocked-resolver.log" && bad "M2b: a rebase-gate-red park is never a skip: $(mlog)" || ok

# M3. a conflicting PR: mc_rebase runs, once. M3b. a stale stamp: the same.
mrun conflict-unresolvable ticket/bh-12 "$SH_CONF" null unknown 93
eq "M3 mc_rebase is called once on a conflict" "$(grep -c . "$T/rebase.txt")" 1
grep -q 'main merge skipped' "$MH/logs/blocked-resolver.log" && bad "M3: a conflict is never a skip: $(mlog)" || ok
mrun red-ci-twice ticket/bh-13 "$SH_STALE" true clean 94
eq "M3b mc_rebase is called once on a stale schema.d stamp" "$(grep -c . "$T/rebase.txt")" 1

# M4. the gate off: today's merge.
MAIN_MERGE_GATE=0 mrun red-ci-twice ticket/bh-11 "$SH_CLEAN" true clean 95
eq "M4 MAIN_MERGE_GATE=0 merges as before" "$(grep -c . "$T/rebase.txt")" 1

# M5q. a PR in the Mergify queue, clean or dirty: never merged into, no rung.
mrun conflict-unresolvable ticket/bh-12 "$SH_CONF" false dirty 96 queued
[ -s "$T/rebase.txt" ] && bad "M5q: a queued PR must never be merged into: $(cat "$T/rebase.txt")" || ok
eq "M5q no rung spent" "$(mech)" 0
eq "M5q the record says queued-skip" "$(mlast)" queued-skip
grep -q 'main merge skipped: in the merge queue (queued label)' "$MH/logs/blocked-resolver.log" && ok \
  || bad "M5q: the log must say the PR is queued: $(mlog)"
[ -s "$T/br-agent.txt" ] && bad "M5q: no fix round on a queued PR: $(cat "$T/br-agent.txt")" || ok

# M6. no repo on this box and no answer from GitHub (mergeable null): the
# check cannot tell, so the rung merges as before and says nothing about a skip.
MRM_NOREPO=1 mrun red-ci-twice ticket/bh-11 "$SH_CLEAN" null unknown 97
eq "M6 cannot tell: mc_rebase is called as before" "$(grep -c . "$T/rebase.txt")" 1
grep -q 'main merge skipped' "$MH/logs/blocked-resolver.log" && bad "M6: cannot tell is never a skip: $(mlog)" || ok

echo "main-merge-need.bh-7042-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
