#!/bin/bash
# tests/blocked-resolver.bh-950-test.sh — BH-950.2 / BH-970: THE REGENERATE RUNG.
#
# THE DEFECT. A `ci-red` park whose mechanical rung is spent went straight to an
# agent fix round (bin/blocked-resolver.sh, the ladder block in br_one) even when
# one more merge of origin/main would have regenerated the generated-files table
# and cleared the red. `BR_REGEN_RUNG` existed and nothing read it. 12 open PRs
# in the #950 census sat exactly there, each one paying for an agent call to fix
# a drift a free merge answers.
#
# WHAT THIS FILE PINS, all on what a real run of bin/blocked-resolver.sh DID —
# the ledger it wrote, the argv mc_rebase and bin/agent-call.sh were handed, the
# lines it logged:
#   P1  a red-ci park with mechanicals=1 takes the regenerate rung: mc_rebase is
#       asked exactly once on the park's head, one `regen` attempt is recorded
#       against head8, and no fix round is launched.
#   P2  the same park on the same head next tick does NOT ask mc_rebase again,
#       and is not stuck — the displaced ladder answer runs in that tick.
#   P3  an mc_rebase that leaves the head alone records `regen-noop` and the
#       displaced answer runs in the SAME tick.
#   P4  the dispatch table: review-blocked, orphaned-parent and rebase-conflict
#       parks never take the rung, mechanicals=0 still takes rung 1, and
#       BR_REGEN_RUNG=0 restores the pre-BH-950 dispatch exactly.
#   P5  observe mode says what it would do and touches no state.
#   P6  br_regen_offered, driven directly over its own extracted source.
#   P7  mc_rebase rc 4 is a SETUP failure: nothing spent, one page per episode.
#   P8  the rung is BOUNDED: regens at BR_MAX_REGEN never asks again, even on a
#       head it has never seen.
#   P9  mc_rebase rc 6 (the pool took the rebase) is a rung that RAN: it counts
#       against the bound and the conductor row leaves the park for REBASING, so
#       the next tick cannot buy a fix round on a branch a pool machine is
#       rebasing right now. Mirrors rung 1's own rc-6 case in
#       tests/blocked-resolver.bh-541-test.sh.
#
# THE GIT IS REAL AND LOCAL (the tests/blocked-resolver-test.sh section 8
# pattern): a bare repo stands in for the remote so the displaced fix round has
# a branch to work in and its refusal is a real refusal. Only mc_rebase is
# stubbed, to its documented rc contract.
# Run from anywhere: tests/blocked-resolver.bh-950-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver.bh-950-test: SKIPPED — jq is required"; exit 0; }
command -v git >/dev/null || { echo "blocked-resolver.bh-950-test: SKIPPED — git is required"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
LOG="$H/logs/blocked-resolver.log"
RST="$H/state/blocked-resolver"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# main's resolver hard-sources rebuild-ledger.sh and merge-conductor-lib.sh off
# the harness lib path, so the copies are what the run reads — and what the
# mc_rebase fixture below is appended to.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too, or every
# resolver call dies at the loader and every assertion below reads empty state.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# THE AGENT AND THE ENQUEUE ARE RECORDED, never stubbed silent: "did this tick
# buy an agent call" is the whole question P1 asks.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent-call.txt"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/queue.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/run-build.sh" "$H/bin/lane-alert.sh"

HEADA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEWSHA="dddddddddddddddddddddddddddddddddddddddd"
OTHER8="bbbbbbbb"

# gh answers the head branch and sha from files, so each section decides for
# itself what the lane can see. Every call is recorded.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)  printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"/pulls/"*)   _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json baseRefName"*) echo main ;;
  *"--json state"*)       echo OPEN ;;
  *"--json comments"*)    cat "$T/findings" 2>/dev/null ;;
  *"actions/runs?head_sha="*) cat "$T/failedruns" 2>/dev/null ;;
  *"run view"*"--log-failed"*) cat "$T/joblog" 2>/dev/null ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# No credential reaches this run: every real git remote path refuses before it
# can touch a network.
export GH_TOKEN=""
printf '4242\n' > "$T/failedruns"
printf 'FAIL src/table.test.ts > the generated table is current\n  expected 3 to equal 4\n' > "$T/joblog"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/agent-call.txt"
: > "$T/lane-alert.txt"; : > "$T/comments.txt"; : > "$T/ssh.txt"

# ---- mc_rebase to its documented rc contract, driven by two files -----------
# 0 pushed (stdout: the new head) | 1 conflict | 2 gate red | 3 lease rejected
# | 4 setup failed. Its argv is recorded, so "was the rung asked, and about
# what" is a fact about the run.
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
# --- fixture override: mc_rebase ---------------------------------------------
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  local out; out=\$(cat "$T/rebase-out" 2>/dev/null)
  [ -n "\$out" ] && printf '%s' "\$out"
  return "\$(cat "$T/rebase-rc" 2>/dev/null || echo 4)"
}
EOF

# ---- a real remote, and a real local clone for the displaced fix round ------
ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm init
git -C "$SEED" branch -M main
for N in 70 71 72 73 74 75 76 77 78 79 80; do
  git -C "$SEED" checkout -q -B "ticket/ts-$N" main
  printf 'branch %s\n' "$N" > "$SEED/f.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on ts-$N"
done
git -C "$SEED" checkout -q main
# The bare "remote" is filled by a FETCH from the seed, never by a push: this
# box's act-time guard refuses any `git push` whose refspec names main, fixture
# or not, so a seed that pushed its own main would leave every branch below
# unresolvable (and that is exactly what a pre-existing suite hits here).
git -C "$ORIGIN" fetch -q "$SEED" '+refs/heads/*:refs/heads/*'
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
            BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
            bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>>"$T/run.err" ) || true; }
# ROWST <key> <STATE> <reason> <url> — the conductor's own row shape. The epoch
# column is derived from the file's single clock read.
ROWST() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$NOW" "$HEADA" "$HEADA" "$3" "$4" \
            > "$H/state/merge-conductor/pr-state.tsv"; }
JSON() { cat "$RST/tproj/tproj-TK-$1.json" 2>/dev/null; }
# The conductor row is read back off the same tsv the lane writes, never
# re-derived here (the bh-541 pattern).
row_state() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$H/state/merge-conductor/pr-state.tsv"; }
# seed_ledger <ticket-number> <mechanicals> <fixrounds> [regens] [attempt-head8]
seed_ledger() {
  mkdir -p "$RST/tproj"
  jq -nc --arg k "tproj-TK-$1" --argjson m "$2" --argjson f "$3" --argjson g "${4:-0}" --arg h "${5:-}" \
    '{project:"tproj",rkey:$k,mechanicals:$m,fixrounds:$f,regens:$g,rebuilds:0,adjudications:0,rereviews:0,outcome:"",
      attempts: (if $h == "" then [] else [{at:"2026-09-19T00:00:00Z",action:"regen",reason:"red-ci-twice",detail:("regenerated ticket: head8=" + $h)}] end)}' \
    > "$RST/tproj/tproj-TK-$1.json"
}
# park <ticket-number> <reason> [state]
park() {
  printf 'ticket/ts-%s\n' "$1" > "$T/prbranch"; printf '%s\n' "$HEADA" > "$T/prhead"
  ROWST "o/tproj#$1" "${3:-RED_TWICE}" "$2" "https://github.com/o/tproj/pull/$1"
}
reset_run() {
  : > "$T/rebase.txt"; : > "$T/agent-call.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
  : > "$T/gh.txt"; : > "$T/lane-alert.txt"; : > "$LOG"
  rm -f "$H/flags/blocked-resolver-observe"
}

# ════════════════════════════════════════════════════════════════════════════
# P1. THE RUNG ITSELF. mechanicals=1 on a red-ci park: the regenerate rung, not
#     an agent fix round.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"
seed_ledger 70 1 0
park 70 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
echo 0 > "$T/rebase-rc"; printf '%s' "$NEWSHA" > "$T/rebase-out"
reset_run
RUN
[ "$(grep -c . "$T/rebase.txt")" = 1 ] && ok \
  || bad "P1: the regenerate rung must ask mc_rebase exactly once (got $(grep -c . "$T/rebase.txt") call(s): $(cat "$T/rebase.txt"))"
grep -q 'ticket/TK-70' "$T/rebase.txt" && ok \
  || bad "P1: mc_rebase must be asked about the park's own branch (got '$(cat "$T/rebase.txt")')"
grep -q "$HEADA" "$T/rebase.txt" && ok \
  || bad "P1: mc_rebase must be asked on the park's head (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 70 | jq -r '[.attempts[] | select(.action=="regen")] | length')" = 1 ] && ok \
  || bad "P1: the ledger must record exactly one regen attempt (got $(JSON 70 | jq -c '.attempts'))"
JSON 70 | jq -r '[.attempts[] | select(.action=="regen") | .detail] | .[0]' | grep -q "head8=${HEADA:0:8}" && ok \
  || bad "P1: the regen attempt's detail must name the head8 it was taken on (got '$(JSON 70 | jq -r '.attempts[-1].detail')')"
[ "$(JSON 70 | jq -r .regens)" = 1 ] && ok || bad "P1: a regenerate that pushed must count (regens=$(JSON 70 | jq -r .regens))"
[ "$(JSON 70 | jq -r .fixrounds)" = 0 ] && ok \
  || bad "P1: the regenerate rung must not spend the fix round (fixrounds=$(JSON 70 | jq -r .fixrounds))"
[ -s "$T/agent-call.txt" ] && bad "P1: no agent call may be bought when the free rung was taken (got '$(cat "$T/agent-call.txt")')" || ok
[ -s "$T/closed.txt" ] && bad "P1: the regenerate rung must not close the PR" || ok
grep -q 'EVENT resolver_rung .*regenerate' "$LOG" && ok \
  || bad "P1: the rung transition must be an event line naming the regenerate rung (log: $(tail -4 "$LOG"))"

# ════════════════════════════════════════════════════════════════════════════
# P2. ONCE PER HEAD, AND NEVER STUCK. The same park on the same head next tick.
# ════════════════════════════════════════════════════════════════════════════
reset_run
park 70 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
RUN
[ ! -s "$T/rebase.txt" ] && ok \
  || bad "P2: a head the rung has already been offered on must not be regenerated again (got '$(cat "$T/rebase.txt")')"
grep -q 'already offered' "$LOG" && ok \
  || bad "P2: the second offer must say the rung was already spent on this head (log: $(tail -4 "$LOG"))"
{ [ "$(JSON 70 | jq -r .fixrounds)" != 0 ] || [ -s "$T/agent-call.txt" ]; } && ok \
  || bad "P2: the displaced ladder answer must run in the SAME tick — the park may not be delayed by the new rung (fixrounds=$(JSON 70 | jq -r .fixrounds), agent='$(cat "$T/agent-call.txt")')"

# ════════════════════════════════════════════════════════════════════════════
# P3. A NOOP REGENERATE. mc_rebase leaves the head where it was.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"
seed_ledger 71 1 0
park 71 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
echo 0 > "$T/rebase-rc"; printf '%s' "$HEADA" > "$T/rebase-out"
reset_run
RUN
[ "$(JSON 71 | jq -r '[.attempts[] | select(.action=="regen-noop")] | length')" = 1 ] && ok \
  || bad "P3: a regenerate that moved nothing must be recorded as regen-noop (got $(JSON 71 | jq -c '.attempts'))"
JSON 71 | jq -r '[.attempts[] | select(.action=="regen-noop") | .detail] | .[0]' | grep -q "head8=${HEADA:0:8}" && ok \
  || bad "P3: the regen-noop attempt must name the head8 (got '$(JSON 71 | jq -c '.attempts')')"
[ "$(JSON 71 | jq -r .regens)" = 0 ] && ok \
  || bad "P3: a regenerate that pushed nothing must not spend the bound (regens=$(JSON 71 | jq -r .regens))"
{ [ "$(JSON 71 | jq -r .fixrounds)" != 0 ] || [ -s "$T/agent-call.txt" ]; } && ok \
  || bad "P3: the displaced ladder answer must run in the same tick as the noop (fixrounds=$(JSON 71 | jq -r .fixrounds), agent='$(cat "$T/agent-call.txt")')"

# ════════════════════════════════════════════════════════════════════════════
# P4. THE DISPATCH TABLE. Which parks never take this rung.
# ════════════════════════════════════════════════════════════════════════════
echo 0 > "$T/rebase-rc"; printf '%s' "$NEWSHA" > "$T/rebase-out"

# (i) review-blocked: merging main answers nothing a reviewer asked for.
scratch_rm "$RST"; seed_ledger 72 1 0
park 72 "head-not-reapproved: the head moved after the approval" BLOCKED_HUMAN
reset_run; RUN
[ ! -s "$T/rebase.txt" ] && ok || bad "P4(i): a review-blocked park must never take the regenerate rung (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 72 | jq -r '[.attempts[] | select(.action|startswith("regen"))] | length')" = 0 ] && ok \
  || bad "P4(i): a review-blocked park must record no regen attempt (got $(JSON 72 | jq -c '.attempts'))"

# (ii) orphaned-parent: merging main does not take the dead parent's commits out.
scratch_rm "$RST"; seed_ledger 73 1 0
park 73 "orphaned-child: the parent PR closed without merging" BLOCKED_HUMAN
reset_run; RUN
[ ! -s "$T/rebase.txt" ] && ok || bad "P4(ii): an orphaned-parent park must never take the regenerate rung (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 73 | jq -r '[.attempts[] | select(.action|startswith("regen"))] | length')" = 0 ] && ok \
  || bad "P4(ii): an orphaned-parent park must record no regen attempt (got $(JSON 73 | jq -c '.attempts'))"

# (iii) rung 1 is still rung 1: mechanicals=0 takes the mechanical rung.
scratch_rm "$RST"; seed_ledger 74 0 0
park 74 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
reset_run; RUN
[ "$(JSON 74 | jq -r '[.attempts[] | select(.action=="mechanical")] | length')" = 1 ] && ok \
  || bad "P4(iii): with nothing spent, a red-ci park's first rung is still the mechanical one (got $(JSON 74 | jq -c '.attempts'))"
[ "$(JSON 74 | jq -r .regens)" = 0 ] && ok \
  || bad "P4(iii): rung 1 must not spend the regenerate bound (regens=$(JSON 74 | jq -r .regens))"

# (iv) BR_REGEN_RUNG=0 restores the pre-BH-950 dispatch exactly.
scratch_rm "$RST"; seed_ledger 75 1 0
park 75 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
reset_run; BRENV=(BR_REGEN_RUNG=0); RUN; BRENV=()
[ ! -s "$T/rebase.txt" ] && ok || bad "P4(iv): BR_REGEN_RUNG=0 must ask mc_rebase nothing (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 75 | jq -r '[.attempts[] | select(.action|startswith("regen"))] | length')" = 0 ] && ok \
  || bad "P4(iv): BR_REGEN_RUNG=0 must record no regen attempt (got $(JSON 75 | jq -c '.attempts'))"
{ [ "$(JSON 75 | jq -r .fixrounds)" != 0 ] || [ -s "$T/agent-call.txt" ]; } && ok \
  || bad "P4(iv): BR_REGEN_RUNG=0 must take the park to its fix round, as it did before (fixrounds=$(JSON 75 | jq -r .fixrounds))"

# (v) a rebase-conflict park is not a ci-red park.
scratch_rm "$RST"; seed_ledger 76 1 0
park 76 "conflict-unresolvable: CONFLICT (content): a.txt" BLOCKED_HUMAN
reset_run; RUN
[ ! -s "$T/rebase.txt" ] && ok || bad "P4(v): a rebase-conflict park must never take the regenerate rung (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 76 | jq -r '[.attempts[] | select(.action|startswith("regen"))] | length')" = 0 ] && ok \
  || bad "P4(v): a rebase-conflict park must record no regen attempt (got $(JSON 76 | jq -c '.attempts'))"

# ════════════════════════════════════════════════════════════════════════════
# P5. OBSERVE MODE takes no action and writes no state.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 77 1 0
park 77 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
reset_run
BEFORE=$(sha256sum "$RST/tproj/tproj-TK-77.json" | cut -d' ' -f1)
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'WOULD take the regenerate rung' "$LOG" && ok \
  || bad "P5: observe mode must log what the rung would do (log: $(tail -4 "$LOG"))"
[ "$(sha256sum "$RST/tproj/tproj-TK-77.json" | cut -d' ' -f1)" = "$BEFORE" ] && ok \
  || bad "P5: observe mode must not write the ledger (got $(JSON 77 | jq -c '.attempts'))"
[ ! -s "$T/rebase.txt" ] && ok || bad "P5: observe mode must not call mc_rebase (got '$(cat "$T/rebase.txt")')"
[ -s "$T/agent-call.txt" ] && bad "P5: observe mode must not buy an agent call" || ok
# THE RUNG's own read, which is br_pr_ref and is the only `--jq` call this lane
# makes. The merged guard reads the PR state before any rung, in observe mode as
# on every other tick — that read was `gh pr view --json state` when this line
# was written and is `gh api -i .../pulls/N` since #783, so naming the path would
# now forbid a read the lane has always made. What must not happen is the RUNG
# reading anything, and that is what this asserts.
grep -q -- '--jq' "$T/gh.txt" \
  && bad "P5: observe mode must answer before the rung reads the PR ref — no rung-level GitHub call (got '$(cat "$T/gh.txt")')" || ok

# ════════════════════════════════════════════════════════════════════════════
# P6. br_regen_offered, driven directly over its OWN source. Extracted rather
#     than paraphrased: a matcher rewritten in the test proves nothing.
# ════════════════════════════════════════════════════════════════════════════
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
awk '$0 ~ /^br_regen_offered\(\)/ {f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh" > "$T/offered.sh"
grep -q '^br_regen_offered()' "$T/offered.sh" && ok \
  || bad "P6: could not extract br_regen_offered from bin/blocked-resolver.sh"
offered() { bash -c '. "$0"; br_regen_offered "$1" "$2"' "$T/offered.sh" "$1" "$2"; }
J_REGEN=$(jq -nc --arg h "${HEADA:0:8}" '{attempts:[{action:"regen",detail:("pushed 1234 over head8=" + $h)}]}')
J_NOOP=$(jq -nc  --arg h "${HEADA:0:8}" '{attempts:[{action:"regen-noop",detail:("left head8=" + $h + " in place")}]}')
J_OTHER=$(jq -nc --arg h "$OTHER8"      '{attempts:[{action:"regen",detail:("pushed 1234 over head8=" + $h)}]}')
J_MECH=$(jq -nc  --arg h "${HEADA:0:8}" '{attempts:[{action:"mechanical",detail:("merged main at head8=" + $h)}]}')
offered "$J_REGEN" "$HEADA";  [ $? = 0 ] && ok || bad "P6: a regen attempt on this head8 must match"
offered "$J_NOOP"  "$HEADA";  [ $? = 0 ] && ok || bad "P6: a regen-noop attempt on this head8 must match"
offered "$J_OTHER" "$HEADA";  [ $? = 1 ] && ok || bad "P6: a regen attempt on a DIFFERENT head8 must not match"
offered "$J_MECH"  "$HEADA";  [ $? = 1 ] && ok || bad "P6: a mechanical attempt must never read as a regen offer"
offered "$J_REGEN" "";        [ $? = 1 ] && ok || bad "P6: an empty head must answer rc 1 — absent is not 'already offered'"
offered '{"attempts":[]}' "$HEADA"; [ $? = 1 ] && ok || bad "P6: an empty ledger must answer rc 1"

# ════════════════════════════════════════════════════════════════════════════
# P7. mc_rebase rc 4 is a SETUP failure, not an event: nothing spent, nothing
#     dispatched, ONE page per episode (br_setup_blocked's contract).
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 78 1 0
park 78 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
echo 4 > "$T/rebase-rc"; : > "$T/rebase-out"
reset_run; RUN
grep -q 'the regenerate rung could not START' "$LOG" && ok \
  || bad "P7: a rung that could not set up must say exactly that (log: $(tail -4 "$LOG"))"
[ "$(JSON 78 | jq -r '[.attempts[] | select(.action=="regen-blocked")] | length')" = 1 ] && ok \
  || bad "P7: the setup failure must be recorded as regen-blocked (got $(JSON 78 | jq -c '.attempts'))"
[ "$(JSON 78 | jq -r .regens)" = 0 ] && ok || bad "P7: a setup failure spends nothing (regens=$(JSON 78 | jq -r .regens))"
[ "$(JSON 78 | jq -r .fixrounds)" = 0 ] && ok || bad "P7: a setup failure must not cascade into the fix round (fixrounds=$(JSON 78 | jq -r .fixrounds))"
[ "$(grep -c . "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "P7: stopping is an alert — exactly one page (got $(grep -c . "$T/lane-alert.txt") line(s))"
: > "$T/lane-alert.txt"
RUN
[ ! -s "$T/lane-alert.txt" ] && ok || bad "P7: one page per EPISODE — the second tick must not page again (got '$(cat "$T/lane-alert.txt")')"

# ════════════════════════════════════════════════════════════════════════════
# P8. THE BOUND. regens at BR_MAX_REGEN never asks again, even on a head the
#     rung has never been offered on — main keeps moving and the loop must not.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 79 1 0 1 "$OTHER8"
park 79 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
echo 0 > "$T/rebase-rc"; printf '%s' "$NEWSHA" > "$T/rebase-out"
reset_run; RUN
[ ! -s "$T/rebase.txt" ] && ok \
  || bad "P8: a ticket whose regenerate bound is spent must not ask mc_rebase on a new head (got '$(cat "$T/rebase.txt")')"
[ "$(JSON 79 | jq -r .regens)" = 1 ] && ok || bad "P8: the bound must hold at BR_MAX_REGEN (regens=$(JSON 79 | jq -r .regens))"
{ [ "$(JSON 79 | jq -r .fixrounds)" != 0 ] || [ -s "$T/agent-call.txt" ]; } && ok \
  || bad "P8: a park past the bound must take its displaced ladder answer (fixrounds=$(JSON 79 | jq -r .fixrounds))"

# ════════════════════════════════════════════════════════════════════════════
# P9. THE POOL TOOK IT (mc_rebase rc 6). The only new state-mutating arm the
#     suite did not drive. The rung RAN: it counts, and the conductor row must
#     leave the park, or the next tick buys a fix round on a branch a pool
#     machine is rebasing right now.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 80 1 0
park 80 "red-ci-twice: still red on ${HEADA:0:8} after its failed jobs were re-run once"
echo 6 > "$T/rebase-rc"; : > "$T/rebase-out"
reset_run; RUN
[ "$(grep -c . "$T/rebase.txt")" = 1 ] && ok \
  || bad "P9: the pool arm must ask for exactly one rebase (got $(grep -c . "$T/rebase.txt"))"
[ "$(JSON 80 | jq -r '[.attempts[] | select(.action=="regen")] | length')" = 1 ] && ok \
  || bad "P9: a rebase the pool took is a regen attempt, not a noop (got $(JSON 80 | jq -c '.attempts'))"
JSON 80 | jq -r '[.attempts[] | select(.action=="regen") | .detail] | .[0]' | grep -q 'queued a pool rebase' && ok \
  || bad "P9: the attempt must say the rebase went to the pool (got $(JSON 80 | jq -c '.attempts'))"
JSON 80 | jq -r '[.attempts[] | select(.action=="regen") | .detail] | .[0]' | grep -q "head8=${HEADA:0:8}" && ok \
  || bad "P9: the pool attempt must name the head8 it was queued on (got $(JSON 80 | jq -c '.attempts'))"
[ "$(JSON 80 | jq -r .regens)" = 1 ] && ok \
  || bad "P9: a rebase the pool took is a rung that RAN and must count against BR_MAX_REGEN (regens=$(JSON 80 | jq -r .regens))"
[ "$(row_state "o/tproj#80")" = REBASING ] && ok \
  || bad "P9: the conductor row must leave the park for REBASING (got '$(row_state "o/tproj#80")')"
grep -q 'pool rebase queued' "$LOG" && ok \
  || bad "P9: the lane must say the rebase went to the pool (log: $(tail -4 "$LOG"))"
[ -s "$T/agent-call.txt" ] && bad "P9: a queued pool rebase must not also buy a fix round (got '$(cat "$T/agent-call.txt")')" || ok
[ -s "$T/closed.txt" ] && bad "P9: a queued pool rebase must not close the PR (got '$(cat "$T/closed.txt")')" || ok
[ "$(JSON 80 | jq -r .fixrounds)" = 0 ] && ok \
  || bad "P9: a queued pool rebase must not spend the fix round (fixrounds=$(JSON 80 | jq -r .fixrounds))"

echo "blocked-resolver.bh-950-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
