#!/bin/bash
# tests/ci-plan-settings-prepush.bh-7289-test.sh — bin/ci-plan-settings.sh also
# projects CI_ALWAYS_PREPUSH_SKIP (a settings row on the ci-plan-settings lane,
# the master #7033 row ci.cromford.always_prepush_skip) into the repo
# Actions variable of the same name, which bin/ci-plan.sh reads as the switch
# of a batch's prepush drop (BH-7289).
#
# The stub world is tests/ci-plan-settings-sizing.bh-6876-test.sh's: a gh on
# PATH that answers `gh api -i` per route (each variable is $FX/var.<NAME>) and
# a bin/lane-alert.sh that records its argv.
#
#   S1  =0 with no variable: one POST, the tick has ` prepush=set sizing=` in
#       that order; =1 stored as 0: one PATCH; the alert is resolved
#   S2  =2 and =x: `prepush=refused`, no call for it, one warn alert
#       ci-plan-settings-prepush:<slug>
#   S3  unset: `prepush=unset`, no call, no prepush alert call
#   S4  a 500 on the PATCH: `failed`, a warn alert, rc 0; the next good tick
#       resolves it
#   S5  the registry default: lane_env_apply exports CI_ALWAYS_PREPUSH_SKIP=1
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-plan-settings-prepush.bh-7289-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

LANE="$DIR/bin/ci-plan-settings.sh"
SLUG=fixture-org/fixture-repo
TOKEN=ghp_fixture_admin_token
H="$T/h"; FX="$T/fx"; CALLS="$T/calls.log"; LOG="$H/logs/ci-plan-settings.log"
mkdir -p "$H/env" "$H/flags" "$T/stubbin"
( cd "$DIR" && scratch_install_closure bin/ci-plan-settings.sh "$H" ) >/dev/null \
  || { echo "FAIL: setup: could not install the bin/ci-plan-settings.sh closure"; exit 1; }

cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "ALERT \$*" >> "$CALLS"
EOF

cat > "$T/stubbin/gh" <<EOF
#!/bin/bash
# gh api -i -X <M> <path> [args...]
shift; M=; P=
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
tok=other; [ "\${GH_TOKEN:-}" = "$TOKEN" ] && tok=admin
echo "GH \$M \$P tok=\$tok | \$*" >> "$CALLS"
val=; name=
for a in "\$@"; do case "\$a" in value=*) val="\${a#value=}" ;; name=*) name="\${a#name=}" ;; esac; done
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
V="repos/$SLUG/actions/variables"
case "\$M \$P" in
  "GET \$V/"*)
    n="\${P#\$V/}"
    if [ -f "$FX/var.\$n" ]; then reply 200 "\$(jq -cn --arg n "\$n" --rawfile v "$FX/var.\$n" '{name: \$n, value: \$v}')"
    else reply 404 '{"message":"Not Found"}'; fi ;;
  "POST \$V")
    [ -f "$FX/write.fail.\$name" ] && { reply 500 '{}'; exit 0; }
    printf '%s' "\$val" > "$FX/var.\$name"; reply 201 '{}' ;;
  "PATCH \$V/"*)
    n="\${P#\$V/}"
    [ -f "$FX/write.fail.\$n" ] && { reply 500 '{"message":"fixture server error"}'; exit 0; }
    printf '%s' "\$val" > "$FX/var.\$n"; reply 204 '' ;;
  *) reply 500 '{}' ;;
esac
EOF
chmod +x "$H/bin/lane-alert.sh" "$T/stubbin/gh"

reset() {
  local d; for d in "$FX" "$H/logs" "$H/locks" "$H/flags" "$H/state"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FX" "$H/flags"; : > "$CALLS"
  printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"
  printf -- '-' > "$FX/var.CI_FULL_TRIGGERS"
}
run() {
  local vars=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; args=("$@")
  env -u GH_ADMIN_TOKEN -u GH_TOKEN -u HARNESS_ENV_DIR -u CI_FULL_TRIGGERS -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_ALWAYS_PREPUSH_SKIP \
    HARNESS="$H" PATH="$T/stubbin:$PATH" LANE_GATE_DISABLE=1 HARNESS_REPO="$SLUG" ${vars[@]+"${vars[@]}"} \
    bash "$LANE" ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  RC=$?
}
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
pwrites() { grep -cE '^GH (POST|PATCH) .*CI_ALWAYS_PREPUSH_SKIP' "$CALLS" 2>/dev/null || true; }
preads() { grep -cE '^GH GET .*/CI_ALWAYS_PREPUSH_SKIP ' "$CALLS" 2>/dev/null || true; }
ticks() { [ -f "$LOG" ] || { echo 0; return; }; grep -c ' ci-plan-settings ' "$LOG"; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
PID="ci-plan-settings-prepush:$SLUG"
N=CI_ALWAYS_PREPUSH_SKIP

# ── S1. =0, no variable: POST; =1 over a stored 0: PATCH.
reset
run CI_ALWAYS_PREPUSH_SKIP=0
check "S1 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "S1 one POST with the admin token, value 0" '[ "$(grep -c "^GH POST repos/$SLUG/actions/variables tok=admin .*name=$N" "$CALLS")" = 1 ] && [ "$(cat "$FX/var.$N" 2>/dev/null)" = 0 ]'
check "S1 the tick has prepush=set before sizing=: $(lastlog)" '[ "$(ticks)" = 1 ] && lastlog | grep -qE " prepush=set sizing=CI_MAX_SHARDS:unset,CI_SHARD_BUDGET_S:unset$"'
check "S1 the prepush alert is resolved" '[ "$(cnt "^ALERT --resolve --id $PID ")" = 1 ]'
reset; printf 0 > "$FX/var.$N"
run CI_ALWAYS_PREPUSH_SKIP=1
check "S1 a stored 0 is PATCHed to 1" '[ "$(grep -c "^GH PATCH repos/$SLUG/actions/variables/$N tok=admin" "$CALLS")" = 1 ] && [ "$(cat "$FX/var.$N")" = 1 ] && lastlog | grep -q " prepush=set "'
reset; printf 1 > "$FX/var.$N"
run CI_ALWAYS_PREPUSH_SKIP=1
check "S1 the same value: no write, :same" '[ "$(pwrites)" = 0 ] && [ "$(preads)" = 1 ] && lastlog | grep -q " prepush=same "'

# ── S2. refused values.
for v in 2 x; do
  reset; printf 1 > "$FX/var.$N"
  run CI_ALWAYS_PREPUSH_SKIP="$v"
  check "S2 ($v) rc 0" '[ "$RC" = 0 ]'
  check "S2 ($v) prepush=refused, no call for it: $(lastlog)" 'lastlog | grep -q " prepush=refused " && [ "$(preads)" = 0 ] && [ "$(pwrites)" = 0 ] && [ "$(cat "$FX/var.$N")" = 1 ]'
  check "S2 ($v) one warn alert $PID" '[ "$(cnt "^ALERT --id $PID --severity warn ")" = 1 ] && [ "$(cnt "--id $PID")" = 1 ]'
done

# ── S3. unset.
reset
run
check "S3 rc 0, prepush=unset, no call, no alert call: $(lastlog)" '[ "$RC" = 0 ] && lastlog | grep -q " prepush=unset " && [ "$(preads)" = 0 ] && [ "$(pwrites)" = 0 ] && [ "$(cnt "$PID")" = 0 ]'

# ── S4. a failed PATCH, then a good tick.
reset; printf 1 > "$FX/var.$N"; : > "$FX/write.fail.$N"
run CI_ALWAYS_PREPUSH_SKIP=0
check "S4 rc 0, prepush=failed: $(lastlog)" '[ "$RC" = 0 ] && lastlog | grep -q " prepush=failed "'
check "S4 one warn alert naming HTTP 500, the variable unchanged" '[ "$(cnt "^ALERT --id $PID --severity warn ")" = 1 ] && grep -q "HTTP 500" "$CALLS" && [ "$(cat "$FX/var.$N")" = 1 ]'
rm -f "$FX/write.fail.$N"; : > "$CALLS"
run CI_ALWAYS_PREPUSH_SKIP=0
check "S4 the next good tick sets it and resolves the alert" 'lastlog | grep -q " prepush=set " && [ "$(cnt "^ALERT --resolve --id $PID ")" = 1 ]'
check "S4 no admin token in output or log" '! grep -qF "$TOKEN" "$T/out" "$LOG" 2>/dev/null'

# ── S5. the registry default.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  || bad "S5 setup: bin/lanes-build.sh failed: $(head -c 300 "$T/lanes.err")"
S5=$(env -u CI_ALWAYS_PREPUSH_SKIP -u JOBS_URL -u HARNESS_SECRET -u LANE_GATE_DISABLE \
       HARNESS="$H" LANE_REGISTRY="$T/lanes.json" bash -c '
  . "$1/bin/lib/lane-gate.sh" || exit 9
  lane_env_apply ci-plan-settings
  printf "%s\n" "${CI_ALWAYS_PREPUSH_SKIP:-unset}"' _ "$DIR" 2>/dev/null | tail -1)
check "S5 lane_env_apply exports CI_ALWAYS_PREPUSH_SKIP=1 with no row: '$S5'" '[ "$S5" = 1 ]'

echo "ci-plan-settings-prepush.bh-7289: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
