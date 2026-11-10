#!/bin/bash
# tests/blocked-resolver.bh-9340-test.sh — BH-9340: THE REGENERATE RUNG MUST NOT
# LIVELOCK ON A STABLE rc 3.
#
# THE DEFECT. The BH-8021 push guard in mc_rebase returned rc 3 when a Mergify
# queue check stood on the head. br_regen_rung read rc 3 as "lease rejected,
# retry next tick, no rung spent". The refusal is stable, so every tick refused
# again and the fix round never ran (#9317, #8979, #9221, #9273).
#
# WHAT THIS FILE PINS, on a real run of bin/blocked-resolver.sh:
#   M1  the rung asks mc_rebase with `main distinct`; rc 9 (Mergify queue check)
#       records regen-noop on head8 and runs the fix round in the SAME tick.
#   M2  the next tick on the same head does not ask mc_rebase again.
#   M3  the fixture answers rc 3 without `distinct`, so M1 proves the ladder
#       passed it.
#   L1-L3 a plain rc 3 retries on ticks 1-2 of one head and falls through on
#       tick 3 (BR_REGEN_LEASE_TICKS default 3) with exactly one alert.
#   L4  the sidecar round trip: H, H, H2, garbage -> H\t1, H\t2, H2\t1, H\t1.
#   L5  tick 4 after the fall-through: no second alert, no mc_rebase.
#   L6  BR_REGEN_LEASE_TICKS=0 retries for ever; rc 7 never falls through and
#       never writes the sidecar.
# Only mc_rebase is stubbed, to its documented rc contract. 0 network calls.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver.bh-9340-test: SKIPPED — jq is required"; exit 0; }
command -v git >/dev/null || { echo "blocked-resolver.bh-9340-test: SKIPPED — git is required"; exit 0; }

NOW=$(date -u +%s)

H="$T/h"
LOG="$H/logs/blocked-resolver.log"
RST="$H/state/blocked-resolver"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# The lane's bin/lib source closure (BH-4552): merge-conductor-lib.sh and its
# mc/ modules, the REST contract, the ledger. The mc_rebase fixture below is
# appended to the copy, after the install.
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent-call.txt"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/queue.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/run-build.sh" "$H/bin/lane-alert.sh"
# The jobs DB seam (bin/jobs-client.sh is not a bin/lib file, so the closure does
# not copy it). An empty artifact feed is an answer, so br_park_time dates the
# park from the ledger file and does not read "unknown" (BH-2312).
cat > "$H/bin/jobs-client.sh" <<'EOF2'
job_artifact_feed() { return 0; }
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF2

HEADA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEADB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cat > "$T/fakebin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
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
EOF2
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
printf '4242\n' > "$T/failedruns"
printf 'FAIL src/table.test.ts > the generated table is current\n  expected 3 to equal 4\n' > "$T/joblog"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/agent-call.txt"
: > "$T/lane-alert.txt"; : > "$T/comments.txt"; : > "$T/ssh.txt"

# ---- mc_rebase fixture ------------------------------------------------------
# rebase-rc "mq": the Mergify queue check stands on the head. Like the real
# BH-8021 guard, it answers rc 9 only when the caller passed `distinct` as arg
# 7, and rc 3 otherwise. Any other value is returned as is. argv is recorded.
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF2
# --- fixture override: mc_rebase ---------------------------------------------
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  local want; want=\$(cat "$T/rebase-rc" 2>/dev/null || echo 4)
  if [ "\$want" = mq ]; then
    mc_log "\$5 rebase: SKIP_PUSH mergify-queue: In merge queue on \${4:0:8} — the rebase result is dropped, nothing pushed (BH-8021)" 2>/dev/null || true
    [ "\${7:-}" = distinct ] && return 9
    return 3
  fi
  return "\$want"
}
EOF2

ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm init
git -C "$SEED" branch -M main
for N in 90 91 92 93 94; do
  git -C "$SEED" checkout -q -B "ticket/ts-$N" main
  printf 'branch %s\n' "$N" > "$SEED/f.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on ts-$N"
done
git -C "$SEED" checkout -q main
git -C "$ORIGIN" fetch -q "$SEED" '+refs/heads/*:refs/heads/*'
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
            BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
            bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>>"$T/run.err" ) || true; }
CURHEAD="$HEADA"
ROWST() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$NOW" "$CURHEAD" "$CURHEAD" "$3" "$4" \
            > "$H/state/merge-conductor/pr-state.tsv"; }
JSON() { cat "$RST/tproj/tproj-TK-$1.json" 2>/dev/null; }
SIDE() { cat "$RST/tproj/tproj-TK-$1.regen-lease" 2>/dev/null; }
seed_ledger() {
  mkdir -p "$RST/tproj"
  jq -nc --arg k "tproj-TK-$1" --argjson m "$2" \
    '{project:"tproj",rkey:$k,mechanicals:$m,fixrounds:0,regens:0,rebuilds:0,adjudications:0,rereviews:0,outcome:"",attempts:[]}' \
    > "$RST/tproj/tproj-TK-$1.json"
}
# park <ticket-number> [head]
park() {
  CURHEAD="${2:-$HEADA}"
  printf 'ticket/ts-%s\n' "$1" > "$T/prbranch"; printf '%s\n' "$CURHEAD" > "$T/prhead"
  ROWST "o/tproj#$1" RED_TWICE "red-ci-twice: still red on ${CURHEAD:0:8} after its failed jobs were re-run once" \
    "https://github.com/o/tproj/pull/$1"
}
reset_run() {
  : > "$T/rebase.txt"; : > "$T/agent-call.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
  : > "$T/gh.txt"; : > "$T/lane-alert.txt"; : > "$LOG"
  rm -f "$H/flags/blocked-resolver-observe"
}
fixran() { [ "$(JSON "$1" | jq -r .fixrounds)" != 0 ] || [ -s "$T/agent-call.txt" ]; }
noops()  { JSON "$1" | jq -r '[.attempts[] | select(.action=="regen-noop")] | length'; }
TAB=$'\t'

# ════════════════════════════════════════════════════════════════════════════
# M1-M3. THE MERGIFY REFUSAL IS ITS OWN rc, AND THE FIX ROUND RUNS NOW.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 90 1
park 90; echo mq > "$T/rebase-rc"
reset_run; RUN; cp "$LOG" "$T/m1.log"
[ "$(grep -c . "$T/rebase.txt")" = 1 ] && ok || bad "M1: mc_rebase must be asked once (got '$(cat "$T/rebase.txt")')"
grep -q ' main distinct$' "$T/rebase.txt" && ok \
  || bad "M3: the regenerate rung must pass 'main distinct' to mc_rebase (got '$(cat "$T/rebase.txt")')"
[ "$(noops 90)" = 1 ] && ok || bad "M1: rc 9 must record one regen-noop (got $(JSON 90 | jq -c .attempts))"
JSON 90 | jq -r '[.attempts[] | select(.action=="regen-noop") | .detail] | .[0]' | grep -q "head8=${HEADA:0:8}" && ok \
  || bad "M1: the regen-noop must name head8 (got $(JSON 90 | jq -c .attempts))"
[ "$(JSON 90 | jq -r .regens)" = 0 ] && ok || bad "M1: rc 9 must not spend the regen bound (regens=$(JSON 90 | jq -r .regens))"
fixran 90 && ok || bad "M1: the fix round must run in the SAME tick as rc 9 (fixrounds=$(JSON 90 | jq -r .fixrounds))"
grep -q 'mc_rebase rc=9 (Mergify queue check' "$LOG" && ok \
  || bad "M1: the log must name rc=9 and the Mergify queue check (log: $(tail -5 "$LOG"))"
grep -q "lease was rejected" "$T/m1.log" && bad "M1: rc 9 must not take the lease-retry line ($(grep "lease was rejected" "$T/m1.log"))" || ok
[ -e "$RST/tproj/tproj-TK-90.regen-lease" ] && bad "M1: rc 9 must leave no lease sidecar" || ok
[ -s "$T/lane-alert.txt" ] && bad "M1: rc 9 must send no alert (got '$(cat "$T/lane-alert.txt")')" || ok

reset_run; park 90; RUN
[ ! -s "$T/rebase.txt" ] && ok || bad "M2: the next tick on the same head must not ask mc_rebase again (got '$(cat "$T/rebase.txt")')"

# ════════════════════════════════════════════════════════════════════════════
# L1-L3, L5. A PLAIN rc 3 RETRIES TWICE, THEN FALLS THROUGH ONCE.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 91 1
echo 3 > "$T/rebase-rc"
reset_run; park 91; RUN
[ "$(JSON 91 | jq -r '.attempts | length')" = 0 ] && ok || bad "L1: rc 3 tick 1 must record no attempt (got $(JSON 91 | jq -c .attempts))"
fixran 91 && bad "L1: rc 3 tick 1 must not run the fix round" || ok
[ "$(SIDE 91)" = "$HEADA${TAB}1" ] && ok || bad "L1: sidecar must hold '<head>\\t1' (got '$(SIDE 91)')"
grep -q '1 of 3 on this head' "$LOG" && ok || bad "L1: the say line must name '1 of 3' (log: $(tail -3 "$LOG"))"

reset_run; park 91; RUN
[ "$(SIDE 91)" = "$HEADA${TAB}2" ] && ok || bad "L2: sidecar must hold '<head>\\t2' (got '$(SIDE 91)')"
fixran 91 && bad "L2: rc 3 tick 2 must not run the fix round" || ok
[ "$(noops 91)" = 0 ] && ok || bad "L2: rc 3 tick 2 must record nothing (got $(JSON 91 | jq -c .attempts))"

reset_run; park 91; RUN
[ "$(noops 91)" = 1 ] && ok || bad "L3: tick 3 must record one regen-noop (got $(JSON 91 | jq -c .attempts))"
JSON 91 | jq -r '[.attempts[] | select(.action=="regen-noop") | .detail] | .[0]' | grep -q "head8=${HEADA:0:8}" && ok \
  || bad "L3: the regen-noop must name head8 (got $(JSON 91 | jq -c .attempts))"
fixran 91 && ok || bad "L3: tick 3 must run the fix round (fixrounds=$(JSON 91 | jq -r .fixrounds))"
[ "$(grep -c . "$T/lane-alert.txt")" = 1 ] && ok || bad "L3: exactly one alert (got '$(cat "$T/lane-alert.txt")')"
grep -q 'https://github.com/o/tproj/pull/91' "$T/lane-alert.txt" && ok || bad "L3: the alert must name the PR (got '$(cat "$T/lane-alert.txt")')"
grep -q "rc 3 for 3 ticks on head8=${HEADA:0:8}" "$LOG" && ok || bad "L3: the log must name the fall-through (log: $(tail -4 "$LOG"))"
[ -e "$RST/tproj/tproj-TK-91.regen-lease" ] && bad "L3: the sidecar must be removed after the fall-through" || ok

reset_run; park 91; RUN
[ ! -s "$T/rebase.txt" ] && ok || bad "L5: tick 4 must not ask mc_rebase (got '$(cat "$T/rebase.txt")')"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "L5: tick 4 must not alert again (got '$(cat "$T/lane-alert.txt")')"

# ════════════════════════════════════════════════════════════════════════════
# L2b / L4. THE COUNT IS PER HEAD, AND A BAD SIDECAR RESTARTS IT.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 92 1
echo 3 > "$T/rebase-rc"
reset_run; park 92 "$HEADA"; RUN
[ "$(SIDE 92)" = "$HEADA${TAB}1" ] && ok || bad "L4: H -> '<H>\\t1' (got '$(SIDE 92)')"
reset_run; park 92 "$HEADA"; RUN
[ "$(SIDE 92)" = "$HEADA${TAB}2" ] && ok || bad "L4: H,H -> '<H>\\t2' (got '$(SIDE 92)')"
reset_run; park 92 "$HEADB"; RUN
[ "$(SIDE 92)" = "$HEADB${TAB}1" ] && ok || bad "L2b/L4: a new head resets the count to 1 (got '$(SIDE 92)')"
fixran 92 && bad "L2b: a new head after 2 rc 3 must not fall through" || ok
printf 'garbage\tnot-a-number\n' > "$RST/tproj/tproj-TK-92.regen-lease"
reset_run; park 92 "$HEADA"; RUN
[ "$(SIDE 92)" = "$HEADA${TAB}1" ] && ok || bad "L4: a garbage sidecar restarts at '<H>\\t1' (got '$(SIDE 92)')"
printf '%s\tx9\n' "$HEADA" > "$RST/tproj/tproj-TK-92.regen-lease"
reset_run; park 92 "$HEADA"; RUN
[ "$(SIDE 92)" = "$HEADA${TAB}1" ] && ok || bad "L4: a non-number count restarts at 1 (got '$(SIDE 92)')"
# A non-rc-3 answer clears the counter: rc 1 after one rc 3.
echo 1 > "$T/rebase-rc"
seed_ledger 92 1; printf '%s\t2\n' "$HEADA" > "$RST/tproj/tproj-TK-92.regen-lease"
reset_run; park 92 "$HEADA"; RUN
[ -e "$RST/tproj/tproj-TK-92.regen-lease" ] && bad "L4: rc 1 must remove the sidecar (got '$(SIDE 92)')" || ok

# ════════════════════════════════════════════════════════════════════════════
# L6. THE KNOB AT 0 AND rc 7 KEEP TODAY'S RETRY.
# ════════════════════════════════════════════════════════════════════════════
scratch_rm "$RST"; seed_ledger 93 1
echo 3 > "$T/rebase-rc"
BRENV=(BR_REGEN_LEASE_TICKS=0)
for i in 1 2 3 4; do reset_run; park 93; RUN; done
BRENV=()
[ "$(noops 93)" = 0 ] && ok || bad "L6: BR_REGEN_LEASE_TICKS=0 must never fall through (got $(JSON 93 | jq -c .attempts))"
fixran 93 && bad "L6: BR_REGEN_LEASE_TICKS=0 must not run the fix round" || ok
[ -s "$T/lane-alert.txt" ] && bad "L6: BR_REGEN_LEASE_TICKS=0 must not alert" || ok
[ "$(grep -c . "$T/rebase.txt")" = 1 ] && ok || bad "L6: tick 4 with the knob at 0 still asks mc_rebase (got '$(cat "$T/rebase.txt")')"

scratch_rm "$RST"; seed_ledger 94 1
echo 7 > "$T/rebase-rc"
for i in 1 2 3 4; do reset_run; park 94; RUN; done
[ "$(noops 94)" = 0 ] && ok || bad "L6: rc 7 x4 must never fall through (got $(JSON 94 | jq -c .attempts))"
fixran 94 && bad "L6: rc 7 must not run the fix round" || ok
[ -e "$RST/tproj/tproj-TK-94.regen-lease" ] && bad "L6: rc 7 must not write the sidecar (got '$(SIDE 94)')" || ok
grep -q 'retried next tick' "$LOG" && ok || bad "L6: rc 7 keeps today's retry line (log: $(tail -3 "$LOG"))"

echo "blocked-resolver.bh-9340-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
