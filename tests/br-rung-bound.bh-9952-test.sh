#!/bin/bash
# tests/br-rung-bound.bh-9952-test.sh — BH-9952 scope 3 and 4: one rung has a
# time bound from a knob row, and the builds/ retention lane is wired on the hub.
#
# THE BUG (hub, 2026-11-24). One rung (#9700) took 569 s of a 581 s loop, and
# the tick ended on tick-budget with rungs=0/100.
#
#   R1  BR_RUNG_MAX_SECS=2, grace 1, a rung that sleeps 300 s: the whole tick
#       ends inside `timeout 60`, the log names reason=rung-bound, the profile
#       row records rc 124, prof says rung_bound=1, and the second candidate ran
#   R4  (in R1) a child the rung put in another session (setsid) survives
#   R5  (in R1) the key locks are free after the kill
#   R2  bound 0 (the seed): no watchdog process, the slow rung (4 s) runs to
#       its end, no rung-bound line
#   R3  a fast rung under the bound: the watchdog exists during the rung, is
#       gone after brrb_end, no line, no marker file left
#   R7  a bound that is not a number: one say line, no bound
#   R6  the retention lane: the hub block of cron/lanes/737-builds-retention.cron
#       runs bin/builds-retention.sh, and catalog/lanes.d/builds-retention.json
#       lists hub
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, in observe
# mode, against a scratch $HARNESS (the rig of tests/br-discovery-incremental.
# bh-9467-test.sh). br_one is replaced by a scratch-only fragment
# (zz-test-br-one.sh in $T, never in the repo). No vendor is called
# (BH-7563): gh is a local stub, GH_TOKEN is empty.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/br-rung-bound.bh-9952-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }

NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9952-rung-bound.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; _ghs_send 200 '[]'; exit 0 ;;
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

# THE br_one STUB. br_one is defined in the driver after the fragment block,
# so a fragment cannot replace it: the SCRATCH copy of the driver calls
# br_test_one on its one dispatch line instead (checked: exactly one line), and
# a scratch-only fragment defines it. The FIRST rung of a tick sleeps SLOW_SECS (after it starts a setsid child when
# SETSID_PID is set); every later rung returns at once. Each rung writes its
# key to $RUNGS and the non-ps children of its subshell to $KIDS.
n=$(grep -c '^    br_one "\$SRC" "\$P" "\$RKEY"' "$H/bin/blocked-resolver.sh")
[ "$n" = 1 ] || { echo "setup: the driver has $n dispatch lines, want 1"; exit 1; }
sed -i 's/^    br_one "\$SRC" "\$P" "\$RKEY"/    br_test_one "$SRC" "$P" "$RKEY"/' "$H/bin/blocked-resolver.sh"
cat > "$H/bin/blocked-resolver.d/zz-test-br-one.sh" <<'EOF'
br_test_one() {
  printf '%s\n' "$3" >> "$RUNGS"
  ps -o pid=,comm= --ppid "$BASHPID" > "$KIDS.tmp" 2>/dev/null
  grep -v ' ps$' "$KIDS.tmp" >> "$KIDS"
  # What each child holds open, once it has had a second to start.
  if [ -n "${KIDFDS:-}" ] && grep -qv ' ps$' "$KIDS.tmp"; then
    sleep 1
    while read -r k _; do readlink /proc/"$k"/fd/* 2>/dev/null; done < <(grep -v ' ps$' "$KIDS.tmp") >> "$KIDFDS"
  fi
  if [ "$(grep -c . "$RUNGS")" = 1 ]; then
    [ -n "${SETSID_PID:-}" ] && { setsid sleep 300 </dev/null >/dev/null 2>&1 & printf '%s\n' "$!" > "$SETSID_PID"; }
    sleep "${SLOW_SECS:-0}"
  fi
  return 0
}
EOF

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
U="https://github.com/o/p1/pull"
RUNGS="$T/rungs.txt"; KIDS="$T/kids.txt"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" RUNGS="$RUNGS" KIDS="$KIDS" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           timeout 60 bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ); RUNRC=$?; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
PROFROWS() { cat "$ST"/profile/p1.*.tsv 2>/dev/null; }
CLEAN() { scratch_rm "$ST" 2>/dev/null; mkdir -p "$ST"
          rm -f "$H"/locks/blocked-resolver-p1-* "$T/setsid.pid"
          : > "$LOGF"; : > "$ROWS"; : > "$RUNGS"; : > "$KIDS"; : > "$T/gh.txt"
          touch "$H/flags/blocked-resolver-observe"
          for n in 9001 9002; do
            printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s/%s\n' "$n" "$((NOW - 7200))" "$U" "$n" >> "$ROWS"
          done
          BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=5); }

[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9952-rung-bound.sh must exist"
for k in BR_RUNG_MAX_SECS BR_RUNG_KILL_GRACE_SECS; do
  [ -f "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/$k.json" ] && ok || bad "0: knob row catalog/lanes.d/blocked-resolver.knobs.d/$k.json must exist"
done

# ============================================================================
# R1 / R4 / R5. A rung past its bound ends; the tick goes on.
# ============================================================================
CLEAN
BRENV+=(BR_RUNG_MAX_SECS=2 BR_RUNG_KILL_GRACE_SECS=1 SLOW_SECS=300 SETSID_PID="$T/setsid.pid")
RUN p1
[ "$RUNRC" != 124 ] && ok || bad "R1: THE BUG: the tick did not end inside timeout 60 (the slow rung was not bounded)"
grep -q 'reason=rung-bound' "$LOGF" && ok || bad "R1: the log names reason=rung-bound (log: $(grep -E 'rung|tick:' "$LOGF" | tail -3))"
grep -q 'the rung ran past BR_RUNG_MAX_SECS=2' "$LOGF" && ok || bad "R1: the line names the knob and its value"
[ "$(grep -c . "$RUNGS")" = 2 ] && ok || bad "R1: the second candidate's rung ran ($(grep -c . "$RUNGS") rungs: $(tr '\n' ' ' < "$RUNGS"))"
first=$(head -1 "$RUNGS")
PROFROWS | awk -F'\t' -v k="$first" '$2 == k && $5 == 124 { f = 1 } END { exit !f }' && ok \
  || bad "R1: the profile row of $first records rc 124 ($(PROFROWS | cut -f1-6 | tr '\n' ';'))"
[ "$(PFIELD rung_bound)" = 1 ] && ok || bad "R1: prof says rung_bound=1 ($(LASTPROF))"
LASTPROF | grep -qE ' top=\[[^]]*\]$' && ok || bad "R1: top=[...] stays the last field of the prof line"
ls "$ST"/.rung-bound* >/dev/null 2>&1 && bad "R1: no marker file is left ($(ls "$ST"/.rung-bound*))" || ok
sp=$(cat "$T/setsid.pid" 2>/dev/null)
if [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null; then ok; kill "$sp" 2>/dev/null
else bad "R4: the setsid child of the rung must survive the bound kill (pid '${sp:-none}')"; fi
lk=0; for f in "$H"/locks/blocked-resolver-p1-*.lock; do
  [ -f "$f" ] || continue; lk=$((lk+1))
  flock -n "$f" true && ok || bad "R5: the key lock $(basename "$f") is still held after the tick"
done
[ "$lk" -ge 2 ] && ok || bad "R5: the tick took 2 key locks ($lk)"

# ============================================================================
# R2. Bound 0 (the seed): nothing starts, the slow rung runs to its end.
# ============================================================================
CLEAN
BRENV+=(SLOW_SECS=4)
RUN p1
[ "$(grep -c . "$RUNGS")" = 2 ] && ok || bad "R2: both rungs ran ($(grep -c . "$RUNGS"))"
[ -s "$KIDS" ] && bad "R2: no watchdog with no bound (rung children: $(tr '\n' ';' < "$KIDS"))" || ok
grep -q 'rung-bound' "$LOGF" && bad "R2: no rung-bound line with no bound" || ok
PROFROWS | awk -F'\t' '$5 == 124 { f = 1 } END { exit !f }' && bad "R2: no rc 124 with no bound" || ok
PROFROWS | awk -F'\t' -v k="$(head -1 "$RUNGS")" '$2 == k && $6 >= 4 { f = 1 } END { exit !f }' && ok \
  || bad "R2: the slow rung ran its 4 s to the end ($(PROFROWS | cut -f1-6 | tr '\n' ';'))"
[ "$(PFIELD rung_bound)" = 0 ] && ok || bad "R2: prof says rung_bound=0 ($(LASTPROF))"

# ============================================================================
# R3. A fast rung under the bound: a watchdog during the rung, none after.
# ============================================================================
CLEAN
BRENV+=(BR_RUNG_MAX_SECS=30)
BRENV+=(KIDFDS="$T/kidfds.txt"); : > "$T/kidfds.txt"
RUN p1
[ "$(grep -c . "$RUNGS")" = 2 ] && ok || bad "R3: both rungs ran"
[ -s "$T/kidfds.txt" ] && ok || bad "R3: the watchdog's open files were read"
grep -q '/locks/' "$T/kidfds.txt" && bad "R3: the watchdog holds no lock fd ($(grep '/locks/' "$T/kidfds.txt" | tr '\n' ' '))" || ok
[ "$(grep -c . "$KIDS")" = 2 ] && ok || bad "R3: one watchdog per rung while it runs ($(tr '\n' ';' < "$KIDS"))"
alive=0; while read -r wp _; do [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null && alive=$((alive+1)); done < "$KIDS"
[ "$alive" = 0 ] && ok || bad "R3: brrb_end ends the watchdog ($alive still alive)"
grep -q 'rung-bound' "$LOGF" && bad "R3: no rung-bound line for a fast rung" || ok
ls "$ST"/.rung-bound* >/dev/null 2>&1 && bad "R3: no marker file is left" || ok

# ============================================================================
# R7. A bound that is not a number: one line, the fallback 0.
# ============================================================================
CLEAN
BRENV+=(BR_RUNG_MAX_SECS=abc)
RUN p1
[ "$(grep -c "BR_RUNG_MAX_SECS is 'abc', not a number" "$LOGF")" = 1 ] && ok || bad "R7: one say line for a bad bound ($(grep -c 'BR_RUNG_MAX_SECS' "$LOGF"))"
[ -s "$KIDS" ] && bad "R7: no watchdog with a bad bound" || ok

# ============================================================================
# R6. builds/ retention is wired on the hub.
# ============================================================================
CRON="$DIR/cron/lanes/737-builds-retention.cron"
awk '/^# @box hub/ { on = 1; next } on && /^[0-9*]/ && /bin\/builds-retention\.sh/ { f = 1 } END { exit !f }' "$CRON" && ok \
  || bad "R6: the hub block of cron/lanes/737-builds-retention.cron runs bin/builds-retention.sh"
jq -e '.boxes | index("hub")' "$DIR/catalog/lanes.d/builds-retention.json" >/dev/null && ok \
  || bad "R6: catalog/lanes.d/builds-retention.json lists hub in boxes"
[ -x "$DIR/bin/builds-retention.sh" ] && ok || bad "R6: bin/builds-retention.sh exists and is executable"

printf 'br-rung-bound.bh-9952: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
