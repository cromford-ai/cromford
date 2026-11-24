#!/bin/bash
# tests/fixround-verify-budget.bh-9906-test.sh — BH-9906: a fix round's
# verification has its own budget, a verification timeout keeps the agent's
# paid work, and a retry of the same (PR, head) runs verification only.
#
# THE INCIDENT (2026-11-23, project-3). Four rounds on one box ran together; each
# agent finished, the typecheck plus the unit suite ran past the one shared
# lane timeout, the round was killed, its worktree removed under live vitest
# workers, and the next round bought the agent call again.
#
#   V1      the REAL --fix-here: the agent ends, the unit step runs past
#           BR_FIX_VERIFY_TIMEOUT -> FIX_RESULT verify-timeout, .agent_done and
#           refs/harness/fixround/<ck>/<head> written, no fixrounds count
#   T1/A1   the retry with V1's record: 0 agent calls, pushed, record+ref gone
#   A2      the Fly case: a fresh clone, the retry fetches the ref
#   A3      a head change: the record and ref are dropped, the agent runs
#   A4      equal head, neither branch nor ref: the agent runs, one line
#   A5-A6   brvb_agent_done: another project's record; upper-case head hex
#   B1      UNIT_EXIT: 124 never starts the main baseline
#   R1      a RED verify (no timeout) drops .agent_done: the next round on the
#           same head runs the agent again (review of #9930)
#   D1      the brvb_is_timeout table
#   X6      the TERM trap with FRC_WT_OWNER=1 leaves the worktree
#   X7      a spent budget skips the next step (VERIFY_TIMEOUT: unit)
#   H1-H3   the hub: br_fix_adopt, br_fix_unclaimed, br_fix_stale_claim
#   Z1-Z2   no vendor call; the agent's prompt carries no new text
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fixround-verify-budget.bh-9906-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
FRAG="$DIR/bin/blocked-resolver.d/bh-9906-verify-budget.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
export GIT_CONFIG_NOSYSTEM=1
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$2"; }

# ============================================================================
# The fixture: the REAL driver, --fix-here, a real local git origin
# ============================================================================
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# fx_br_harness runs br_modules_install, so bin/lib/br/ travels with the copy.
[ -d "$H/bin/lib/br" ] || bad "setup: bin/lib/br/ was not installed beside the copied lane"
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh \
           bin/blocked-resolver.d/bh-9404-timeout-retry.sh bin/blocked-resolver.d/bh-9437-verify-baseline.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
[ -f "$FRAG" ] && { scratch_install_closure bin/blocked-resolver.d/bh-9906-verify-budget.sh "$H" >/dev/null || { echo "FAIL: closure of the fragment"; exit 1; }; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# The PR under test carries the repo's own typecheck and unit scripts.
git -C "$SEED" checkout -q main
git -C "$SEED" checkout -q -b ticket/TK-92 "$(git -C "$SEED" rev-list --max-parents=0 HEAD)"
printf '{"name":"t","scripts":{"typecheck":"tsc","test:unit":"vitest"}}\n' > "$SEED/package.json"
printf 'TK-92\n' > "$SEED/g.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on TK-92"; git -C "$SEED" push -q origin ticket/TK-92
git -C "$T/repos/tproj" fetch -q origin
# npm: records "<cwd> <args>", plays $T/npm-mode: ok | unit-sleep | unit-124 | tc-sleep
# | unit-red (exit 1 only in a tree with the agent's file: main's baseline is green)
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
printf '%s %s\n' "\$PWD" "\$*" >> "$T/npm.log"
m=\$(cat "$T/npm-mode" 2>/dev/null)
case "\$*" in
  "run typecheck") [ "\$m" = tc-sleep ] && sleep 20; exit 0 ;;   # determinism: ok a slow step the verify budget must kill; nothing waits on it
  "run test:unit") [ "\$m" = unit-sleep ] && sleep 20; [ "\$m" = unit-124 ] && { echo " FAIL  a.test.ts"; exit 124; }; [ "\$m" = unit-red ] && [ -e agent-fix.txt ] && { echo " FAIL  a.test.ts"; exit 1; }; exit 0 ;;   # determinism: ok a slow step the verify budget must kill; nothing waits on it
esac
exit 0
EOF
chmod +x "$T/fakebin/npm"
# The "agent": records its call, commits one file in the round's tree, writes
# the commit to $T/agent-commit, exits with $T/agent-rc. $T/agent-mode sleep
# holds it for 30 s first.
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
[ "\$(cat "$T/agent-mode" 2>/dev/null)" = sleep ] && sleep 30   # determinism: ok an agent the TERM case signals; nothing waits on it
printf 'fix %s\n' "\$(date +%s%N)" >> agent-fix.txt
git add agent-fix.txt && git commit -qm "agent fix" && git rev-parse HEAD > "$T/agent-commit"
exit "\$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
AGENT
chmod +x "$H/bin/agent-call.sh"
PR="https://github.com/o/tproj/pull/92"
LOGF="$H/logs/blocked-resolver.log"
CK=vb-1
FIXHERE() { # FIXHERE [env...] — one hopped round; stdout in $T/fh.out
  ( for e in "$@"; do export "${e?}"; done
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
      bash "$H/bin/blocked-resolver.sh" --fix-here tproj "$CK" red-ci-twice "$PR" - - < "$T/rec-in.json" ) > "$T/fh.out" 2>>"$T/run.log"
  sed -n 's/^FIX_RECORD //p' "$T/fh.out" | base64 -d > "$T/rec-out.json" 2>/dev/null
}
RESULT() { sed -n 's/^FIX_RESULT //p' "$T/fh.out" | head -1; }
OUTJ() { jq -r "$1" "$T/rec-out.json" 2>/dev/null; }
NAGENT() { grep -c "^execute " "$T/agent.txt"; }
NPM() { grep -c . "$T/npm.log" 2>/dev/null || true; }
REF() { git -C "$ORIGIN" rev-parse --verify -q "refs/harness/fixround/$CK/$1" 2>/dev/null; }
RRESET() { # RRESET — a clean box: no record, no checkpoint, the stub modes ok
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; : > "$T/npm.log"; rm -f "$T/fh.out" "$T/rec-out.json" "$T/agent-commit" "$T/agent-mode"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname)' refs/heads/brfix/ refs/harness/ \
    | while read -r b; do git -C "$T/repos/tproj" update-ref -d "$b" >/dev/null 2>&1; done
  git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/harness/ | while read -r b; do git -C "$ORIGIN" update-ref -d "$b"; done
  printf 'ticket/TK-92\n' > "$T/prbranch"; osha ticket/TK-92 | tr -d '\n' > "$T/prhead"; printf 'main\n' > "$T/prbase"
  printf 0 > "$T/agent-rc"; echo ok > "$T/npm-mode"
  jq -nc --arg k "$CK" '{project:"tproj",rkey:$k,fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
RECLONE() { # a Fly machine: a fresh clone of the PR's repo, nothing local
  scratch_rm "$T/repos/tproj"
  git clone -q --no-local "$ORIGIN" "$T/repos/tproj"   # --no-local: a local clone copies unreachable objects too
  git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
}
V1RUN() { # the V1 round: the agent ends, the unit step runs past a 3 s budget
  RRESET; echo unit-sleep > "$T/npm-mode"
  FIXHERE BR_FIX_VERIFY_TIMEOUT=3
}

# ── V1 ───────────────────────────────────────────────────────────────────────
V1RUN
HD=$(osha ticket/TK-92); AC=$(cat "$T/agent-commit" 2>/dev/null)
[ "$(NAGENT)" = 1 ] && ok || bad "V1 the agent ran once (log: $(tail -4 "$LOGF"))"
case "$(RESULT)" in "verify-timeout "*) ok ;; *) bad "V1 FIX_RESULT verify-timeout, not '$(RESULT)' (log: $(grep -i 'verif\|did not' "$LOGF" | tail -3))" ;; esac
[ "$(OUTJ .agent_done.head)" = "$HD" ] && ok || bad "V1 .agent_done.head is the PR head: $(OUTJ .agent_done)"
[ -n "$AC" ] && [ "$(OUTJ .agent_done.commit)" = "$AC" ] && ok || bad "V1 .agent_done.commit is the agent's commit ($AC): $(OUTJ .agent_done.commit)"
[ -n "$AC" ] && [ "$(REF "$HD")" = "$AC" ] && ok || bad "V1 refs/harness/fixround/$CK/<head> on origin is the agent's commit: $(REF "$HD")"
[ "$(OUTJ '.fixrounds // 0')" = 0 ] && ok || bad "V1 no fixrounds count: $(OUTJ .fixrounds)"
[ "$(OUTJ '[.attempts[].action] | join(",")')" = "fix-round-agent-done,fix-round-verify-timeout" ] && ok \
  || bad "V1 one agent-done row and one verify-timeout row: $(OUTJ '[.attempts[].action]')"
[ "$(osha ticket/TK-92)" = "$HD" ] && ok || bad "V1 nothing is pushed"
grep -q '^UNIT_EXIT: 124$' "$H/state/blocked-resolver/tproj/$CK.fix-verify.txt" && ok || bad "V1 the verify file ends the unit step at 124: $(tail -3 "$H/state/blocked-resolver/tproj/$CK.fix-verify.txt" 2>/dev/null)"
[ "$(NPM)" = 2 ] && ok || bad "V1 no baseline after the timeout: npm calls $(NPM): $(cat "$T/npm.log")"
grep -q 'FIX_WT ' "$T/fh.out" && ok || bad "V1 the round names its worktree on stdout (FIX_WT)"
cp "$T/rec-out.json" "$T/v1.json"

# ── T1/A1: the retry with V1's record runs verification only ────────────────
cp "$T/v1.json" "$T/rec-in.json"; : > "$T/agent.txt"; : > "$T/npm.log"; echo ok > "$T/npm-mode"
FIXHERE
[ "$(NAGENT)" = 0 ] && ok || bad "T1 the retry makes 0 agent calls ($(NAGENT))"
[ "$(RESULT)" = done ] && ok || bad "T1 the retry is a normal round: '$(RESULT)' (log: $(tail -4 "$LOGF"))"
[ -n "$AC" ] && [ "$(osha ticket/TK-92)" = "$AC" ] && ok || bad "T1 the PR branch is the agent's commit: $(osha ticket/TK-92) vs $AC"
[ "$(OUTJ '.agent_done // "gone"')" = gone ] && ok || bad "T1 .agent_done is deleted after the push: $(OUTJ .agent_done)"
[ -z "$(REF "$HD")" ] && ok || bad "T1 the ref is deleted after the push"
grep -q 'verify-only retry' "$LOGF" && ok || bad "T1 one line says verify-only: $(tail -5 "$LOGF")"

# ── A2: the Fly case: a fresh clone reads the ref ────────────────────────────
# TK-92 moved in T1: put it back for the next rounds.
git -C "$ORIGIN" update-ref refs/heads/ticket/TK-92 "$HD"
V1RUN; AC=$(cat "$T/agent-commit" 2>/dev/null)
cp "$T/rec-out.json" "$T/rec-in.json"; RECLONE; : > "$T/agent.txt"; echo ok > "$T/npm-mode"
FIXHERE
[ "$(NAGENT)" = 0 ] && [ "$(RESULT)" = done ] && ok || bad "A2 a fresh clone fetches the ref: agent calls $(NAGENT), result '$(RESULT)' (log: $(tail -4 "$LOGF"))"
[ -n "$AC" ] && [ "$(osha ticket/TK-92)" = "$AC" ] && ok || bad "A2 the agent's commit is pushed"

# ── A3: the head moved between the timeout and the retry ────────────────────
git -C "$ORIGIN" update-ref refs/heads/ticket/TK-92 "$HD"
V1RUN
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/agent.txt"; echo ok > "$T/npm-mode"
git -C "$SEED" checkout -q ticket/TK-92; git -C "$SEED" reset -q --hard "$HD"
printf 'a person pushed\n' > "$SEED/h.txt"; git -C "$SEED" add -A; git -C "$SEED" commit -qm "person"; git -C "$SEED" push -q -f origin ticket/TK-92
H3D=$(osha ticket/TK-92); osha ticket/TK-92 | tr -d '\n' > "$T/prhead"
FIXHERE
[ "$(NAGENT)" = 1 ] && ok || bad "A3 a new head buys the agent: $(NAGENT) calls"
[ -z "$(REF "$HD")" ] && ok || bad "A3 the ref of the old head is deleted"
[ "$(OUTJ '.agent_done.head // "gone"')" != "$HD" ] && ok || bad "A3 the old .agent_done is gone"
git -C "$ORIGIN" update-ref refs/heads/ticket/TK-92 "$HD"

# ── A4: equal head, neither the branch nor the ref has the commit ───────────
V1RUN
cp "$T/rec-out.json" "$T/rec-in.json"; git -C "$ORIGIN" update-ref -d "refs/harness/fixround/$CK/$HD"
RECLONE; : > "$T/agent.txt"; echo ok > "$T/npm-mode"
FIXHERE
[ "$(NAGENT)" = 1 ] && ok || bad "A4 an unreadable commit buys the agent: $(NAGENT) calls"
[ "$(grep -c 'is not readable here' "$LOGF")" = 1 ] && ok || bad "A4 one line says why: $(grep -i readable "$LOGF")"
git -C "$ORIGIN" update-ref refs/heads/ticket/TK-92 "$HD"

# ── B1: UNIT_EXIT: 124 (agent rc 0) never starts the baseline ───────────────
RRESET; echo unit-124 > "$T/npm-mode"
FIXHERE
[ "$(NPM)" = 2 ] && ok || bad "B1 no baseline after a 124: npm calls $(NPM): $(cut -d' ' -f2- "$T/npm.log" | tr '\n' ';')"
[ ! -e "$H/state/blocked-resolver/tproj/$CK.verify-baseline.txt" ] && ok || bad "B1 no baseline file"
case "$(RESULT)" in "verify-timeout "*) ok ;; *) bad "B1 the result is verify-timeout: '$(RESULT)'" ;; esac

# ── R1: a red verify (no timeout) is not kept: the next round runs the agent ─
RRESET; echo unit-red > "$T/npm-mode"
# fixround_bonus 1: a cap of 2, so the red round leaves a round owed on this head
jq -c '.fixround_bonus = 1' "$T/rec-in.json" > "$T/rec-in.tmp" && mv "$T/rec-in.tmp" "$T/rec-in.json"
FIXHERE
grep -q '^UNIT_EXIT: 1$' "$H/state/blocked-resolver/tproj/$CK.fix-verify.txt" && ok || bad "R1 the first round's unit step is red: $(grep -E '_EXIT' "$H/state/blocked-resolver/tproj/$CK.fix-verify.txt" 2>/dev/null | tr '\n' ';')"
[ "$(osha ticket/TK-92)" = "$HD" ] && ok || bad "R1 the red round pushes nothing"
[ "$(OUTJ '.agent_done // "gone"')" = gone ] && ok || bad "R1 a red verify drops .agent_done: $(OUTJ .agent_done)"
[ -z "$(REF "$HD")" ] && ok || bad "R1 a red verify deletes refs/harness/fixround/$CK/<head>"
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/agent.txt"
FIXHERE
[ "$(NAGENT)" = 1 ] && ok || bad "R1 the retry on the same head after a red verify makes exactly 1 agent call ($(NAGENT); log: $(tail -4 "$LOGF"))"
grep -q 'verify-only retry' "$LOGF" && bad "R1 the retry is not verify-only" || ok
git -C "$ORIGIN" update-ref refs/heads/ticket/TK-92 "$HD"

# B1b — brlad_vb_rescore itself: a 124 line never reaches brlad_vb_build
VB="$T/vb"; mkdir -p "$VB/st"
lift brlad_vb_rescore "$DIR/bin/blocked-resolver.d/bh-9437-verify-baseline.sh" > "$VB/rescore.sh"
b1b() { # b1b <name> <verify-text> <want-build-calls>
  printf '%b' "$2" > "$VB/out.txt"; : > "$VB/build.calls"
  ( ST="$VB/st"; brlad_knob() { echo 1; }; brlad_vb_build() { echo x >> "$VB/build.calls"; BRLAD_VB_WHY=stub; return 1; }
    brlad_fail_ids() { echo a.test.ts; }
    . "$VB/rescore.sh"; brlad_vb_rescore tproj "$CK" "$T/repos/tproj" "$VB/out.txt" origin/main ) >/dev/null 2>&1
  [ "$(grep -c . "$VB/build.calls")" = "$3" ] && ok || bad "B1b $1: brlad_vb_build calls $(grep -c . "$VB/build.calls"), want $3"
}
b1b unit-124     'TYPECHECK_EXIT: 0\nUNIT_EXIT: 124\n' 0
b1b tc-124       'TYPECHECK_EXIT: 124\nUNIT_EXIT: 1\n' 0
b1b spent        'TYPECHECK_EXIT: 1\nVERIFY_TIMEOUT: unit\n' 0
b1b unit-red     'TYPECHECK_EXIT: 0\nUNIT_EXIT: 1\n' 1

# ── X7: a spent budget skips the next step ──────────────────────────────────
RRESET; echo tc-sleep > "$T/npm-mode"
FIXHERE BR_FIX_VERIFY_TIMEOUT=2
VF="$H/state/blocked-resolver/tproj/$CK.fix-verify.txt"
grep -q '^VERIFY_TIMEOUT: unit' "$VF" && ok || bad "X7 VERIFY_TIMEOUT: unit is written: $(grep -E '_EXIT|VERIFY' "$VF" 2>/dev/null | tr '\n' ';')"
grep -q 'run test:unit' "$T/npm.log" && bad "X7 the unit step did not start" || ok

# ── X6: the TERM trap with FRC_WT_OWNER=1 leaves the worktree ────────────────
x6() { # x6 <owner 0|1> — prints the worktree path the round named
  RRESET; echo sleep > "$T/agent-mode"
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj
    [ "$1" = 1 ] && export FRC_WT_OWNER=1
    exec setsid bash "$H/bin/blocked-resolver.sh" --fix-here tproj "$CK" red-ci-twice "$PR" - - < "$T/rec-in.json" > "$T/fh.out" 2>>"$T/run.log" ) &
  local pid=$!
  for _ in $(seq 1 150); do [ -s "$T/agent.txt" ] && break; sleep 0.1; done
  kill -TERM -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sed -n 's/^FIX_WT //p' "$T/fh.out" | head -1
}
W=$(x6 1)
[ -n "$W" ] && [ -d "$W" ] && ok || bad "X6 FRC_WT_OWNER=1: the signalled round leaves its worktree for the runner ('$W')"
[ -n "$W" ] && { git -C "$T/repos/tproj" worktree remove --force "$W" >/dev/null 2>&1; scratch_rm "$W"; }
W=$(x6 0)
[ -n "$W" ] && [ ! -e "$W" ] && ok || bad "X6 without it: the trap removes the worktree, as today ('$W')"
rm -f "$T/agent-mode"

# ============================================================================
# Unit level: the fragment's matchers
# ============================================================================
U="$T/u"; mkdir -p "$U"
cat > "$U/stubs.sh" <<EOF
H="$H"; ST="$U/st"; REPOS="$T/repos"; LOG="$U/br.log"
say() { printf '%s\n' "\$*" >> "$U/say.log"; }
br_load() { cat "$U/rec.json" 2>/dev/null || echo '{}'; }
br_json_edit() { local f="\$3"; shift 2; :; }
EOF
UB() { ( . "$U/stubs.sh"; . "$FRAG" 2>/dev/null || exit 9; "$@" ) >/dev/null 2>&1; echo $?; }
# D1 — brvb_is_timeout
d1() { printf '%b' "$2" > "$U/v.txt"; [ "$(UB brvb_is_timeout "$U/v.txt")" = "$3" ] && ok || bad "D1 $1: want rc $3"; }
d1 unit-124      'UNIT_EXIT: 0\nUNIT_EXIT: 124\n' 0
d1 tc-124        'TYPECHECK_EXIT: 124\n' 0
d1 spent         'VERIFY_TIMEOUT: closure-lint\n' 0
d1 unit-1        'UNIT_EXIT: 1\n' 1
d1 unit-1240     'UNIT_EXIT: 1240\n' 1
d1 oom-137       'UNIT_EXIT: 137\n' 1
d1 inside-text   '  expected UNIT_EXIT: 124 to be 0\n' 1
d1 green         'TYPECHECK_EXIT: 0\nUNIT_EXIT: 0\n' 1
d1 baseline-only 'BASELINE: TYPECHECK_EXIT: 124 on main\n' 1

# A5 / A6 — brvb_agent_done over a real clone
RECLONE
W6="$T/u-wt"; git -C "$T/repos/tproj" worktree add -q "$W6" -B "brfix/u6" origin/ticket/TK-92 2>/dev/null
printf 'x\n' > "$W6/u.txt"; git -C "$W6" add -A; git -C "$W6" -c user.email=t@t -c user.name=t commit -qm u
UC=$(git -C "$W6" rev-parse HEAD); git -C "$W6" reset -q --hard "$HD"
jq -nc --arg h "$HD" --arg c "$UC" '{project:"other",agent_done:{head:$h,commit:$c}}' > "$U/rec.json"
[ "$(UB brvb_agent_done tproj u6 "$HD" "$W6")" = 1 ] && ok || bad "A5 another project's record is not used"
jq -nc --arg h "$(printf '%s' "$HD" | tr a-f A-F)" --arg c "$UC" '{project:"tproj",agent_done:{head:$h,commit:$c}}' > "$U/rec.json"
[ "$(UB brvb_agent_done tproj u6 "$HD" "$W6")" = 0 ] && [ "$(git -C "$W6" rev-parse HEAD)" = "$UC" ] && ok \
  || bad "A6 an upper-case head matches and the tree is put on the agent's commit"

# ============================================================================
# The hub: br_fix_adopt, br_fix_unclaimed, br_fix_stale_claim
# ============================================================================
HB="$T/hub"; mkdir -p "$HB/rec"
cat > "$HB/stubs.sh" <<EOF
H="$HB"; ST="$HB/st"; LOG="$HB/br.log"
FIX_LANE_TIMEOUT=5400; FIX_HOP_MARGIN=300; FIX_AGENT_TIMEOUT=3600; FIX_VERIFY_TIMEOUT=2700
say() { printf '%s\n' "\$*" >> "$HB/say.log"; }
br_load() { cat "$HB/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_save() { printf '%s\n' "\$3" > "$HB/rec/\$2.json"; }
br_event() { printf '%s\n' "\$*" >> "$HB/events.log"; }
fix_round_adopt() { return 0; }
br_setup_blocked() { printf '%s\n' "\$6" >> "$HB/setup.log"; }
br_fix_terminal() { printf 'terminal\n' >> "$HB/terminal.log"; }
br_fix_terminal_word() { printf terminal; }
br_rebuild_fresh() { printf 'rebuild\n' >> "$HB/terminal.log"; }
fix_round_box_claims() { [ -e "$HB/claims.down" ] && return 1; cat "$HB/claims.json"; }
EOF
mkdir -p "$HB/bin"; printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$HB" > "$HB/bin/lane-alert.sh"; chmod +x "$HB/bin/lane-alert.sh"
{ lift br_fix_bound "$DIR/bin/lib/br/cap.sh"; lift br_fix_adopt "$DRIVER"; lift br_fix_unclaimed "$DIR/bin/lib/br/cap.sh"; lift br_fix_stale_claim "$DIR/bin/lib/br/cap.sh"; } > "$HB/hub.sh"
HUB() { ( . "$HB/stubs.sh"; . "$HB/hub.sh"; "$@" ) >/dev/null 2>&1; }
HRESET() { rm -f "$HB"/*.log "$HB/claims.down"; echo '[]' > "$HB/claims.json"; jq -nc '{project:"tproj",fixrounds:0,attempts:[]}' > "$HB/rec/$CK.json"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date -u +%s)

# H1 — a verify-timeout row: no rung, "verification owed", one setup-blocked
HRESET
ROW=$(jq -nc --arg r "verify-timeout $(printf 'unit ran out' | base64 -w0)" '{id:7, claimed_by:"box-tproj", result:$r, record_out:null}')
HUB br_fix_adopt tproj "$CK" red-ci-twice "$PR" - - "$CK" "$ROW"
[ ! -s "$HB/terminal.log" ] && ok || bad "H1 no terminal or rebuild for a verify-timeout row"
[ "$(grep -c . "$HB/setup.log" 2>/dev/null)" = 1 ] && grep -q 'the agent is done, verification owed: unit ran out' "$HB/setup.log" && ok \
  || bad "H1 one setup-blocked naming the owed verification: $(cat "$HB/setup.log" 2>/dev/null)"
grep -q 'resolver_fix_verify_timeout' "$HB/events.log" 2>/dev/null && ok || bad "H1 the hub beats resolver_fix_verify_timeout"
[ "$(jq -r '.fixrounds' "$HB/rec/$CK.json")" = 0 ] && ok || bad "H1 no rung counted"

# H2 — the unclaimed page table (bound A+V+M = 6600 s)
h2() { # h2 <name> <row-age-s> <claims-json|down> <want: page|quiet>
  HRESET
  [ "$3" = down ] && touch "$HB/claims.down" || printf '%s' "$3" > "$HB/claims.json"
  local r; r=$(jq -nc --arg e "$(iso $((NOW - $2)))" '{id:5, box:"box-tproj", enqueued_at:$e}')
  HUB br_fix_unclaimed tproj "$CK" "$CK" "$r"
  if [ "$4" = page ]; then [ -s "$HB/alerts.log" ] && ok || bad "H2 $1: a page"
  else [ ! -s "$HB/alerts.log" ] && ok || bad "H2 $1: no page ($(cat "$HB/alerts.log"))"; fi
}
FRESHC=$(jq -nc --arg u "$(iso $((NOW - 600)))" '[{id:4, status:"claimed", box:"box-tproj", updated_at:$u}]')
OLDC=$(jq -nc --arg u "$(iso $((NOW - 9000)))" '[{id:4, status:"claimed", box:"box-tproj", updated_at:$u}]')
BIGC=$(jq -nc --arg u "$(iso $((NOW - 600)))" '[range(500) | {id:., status:"claimed", box:"box-tproj", updated_at:$u}]')
h2 young        600  '[]'     quiet
h2 draining     7000 "$FRESHC" quiet
h2 no-claim     7000 '[]'     page
h2 dead-runner  7000 "$OLDC"  page
h2 read-fails   7000 down     page
h2 truncated    7000 "$BIGC"  page
HRESET; printf '%s' "$FRESHC" > "$HB/claims.json"
HUB br_fix_unclaimed tproj "$CK" "$CK" "$(jq -nc --arg e "$(iso $((NOW - 7000)))" '{id:5, box:"box-tproj", enqueued_at:$e}')"
grep -q 'held behind 1 running round(s) on box-tproj' "$HB/say.log" && ok || bad "H2 the draining line: $(cat "$HB/say.log")"

# H3 — the stale-claim page fires only past A + V + M
HRESET
HUB br_fix_stale_claim tproj "$CK" "$CK" "$(jq -nc --arg u "$(iso $((NOW - 6000)))" '{id:5, claimed_by:"box-tproj", updated_at:$u}')"
[ ! -s "$HB/alerts.log" ] && ok || bad "H3 6000 s (over the old 5700 bound, under 6600) is not paged"
HUB br_fix_stale_claim tproj "$CK" "$CK" "$(jq -nc --arg u "$(iso $((NOW - 6700)))" '{id:5, claimed_by:"box-tproj", updated_at:$u}')"
grep -q 'BR_FIX_AGENT_TIMEOUT + BR_FIX_VERIFY_TIMEOUT + BR_FIX_HOP_MARGIN' "$HB/alerts.log" 2>/dev/null && ok || bad "H3 6700 s is paged and names the three knobs: $(cat "$HB/alerts.log" 2>/dev/null)"

# ── Z1 / Z2 ──────────────────────────────────────────────────────────────────
[ ! -s "$T/ssh.txt" ] && ok || bad "Z1 no ssh"
grep -qi 'verify-only\|BH-9906' "$T/agent.txt" && bad "Z2 the agent's prompt carries new text" || ok

echo "fixround-verify-budget.bh-9906: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
