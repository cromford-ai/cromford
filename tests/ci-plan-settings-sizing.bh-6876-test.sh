#!/bin/bash
# tests/ci-plan-settings-sizing.bh-6876-test.sh — bin/ci-plan-settings.sh also
# projects the shard sizing knobs CI_MAX_SHARDS and CI_SHARD_BUDGET_S (settings
# rows on the ci-plan-settings lane) into the repo Actions variables of the
# same names, which bin/ci-plan.sh reads (BH-6876).
#
# The real lane runs against a scratch $HARNESS (closure installed with
# scratch_install_closure). The stub world is a copy of
# tests/ci-plan-settings.bh-6838-test.sh's, widened to any variable name:
#   gh (on PATH)        answers `gh api -i` with an HTTP status line and a body
#                       per route; each variable is a file $FX/var.<NAME>
#   bin/lane-alert.sh   records its argv
#
#   P1  both set (12, 480), no variables: two POSTs, the tick line ends
#       ` sizing=CI_MAX_SHARDS:set,CI_SHARD_BUDGET_S:set`, one tick line
#   P2  the same values already stored: zero sizing writes, `:same`
#   P3  CI_MAX_SHARDS=0, =65, =x: `:refused`, no write for it, one warn alert
#       ci-plan-settings-sizing:<slug>; the CI_FULL_TRIGGERS projection still runs
#   P4  both unset: no sizing read or write, `:unset`, no sizing alert call
#   P5  a 500 on the sizing PATCH: `:failed`, warn alert, rc 0
#   P6  --dry-run: `would: POST CI_MAX_SHARDS=12`, no write
#   P7  no admin token in output or log
#   P8  the registry default: lane_env_apply ci-plan-settings, with no
#       operator row and no env, exports CI_MAX_SHARDS=12 (the value the operator
#       approved, comment 6197071504) and CI_SHARD_BUDGET_S=480
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-plan-settings-sizing.bh-6876-test.sh
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
  env -u GH_ADMIN_TOKEN -u GH_TOKEN -u HARNESS_ENV_DIR -u CI_FULL_TRIGGERS -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S \
    HARNESS="$H" PATH="$T/stubbin:$PATH" LANE_GATE_DISABLE=1 HARNESS_REPO="$SLUG" ${vars[@]+"${vars[@]}"} \
    bash "$LANE" ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  RC=$?
}
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
swrites() { grep -cE '^GH (POST|PATCH) .*(CI_MAX_SHARDS|CI_SHARD_BUDGET_S)' "$CALLS" 2>/dev/null || true; }
sreads() { grep -cE '^GH GET .*/(CI_MAX_SHARDS|CI_SHARD_BUDGET_S) ' "$CALLS" 2>/dev/null || true; }
ticks() { [ -f "$LOG" ] || { echo 0; return; }; grep -c ' ci-plan-settings ' "$LOG"; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
SID="ci-plan-settings-sizing:$SLUG"

# ── P1. both set, no variables: two POSTs.
reset
run CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480
check "P1 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "P1 one POST per name with the admin token" '[ "$(grep -c "^GH POST repos/$SLUG/actions/variables tok=admin .*name=CI_MAX_SHARDS" "$CALLS")" = 1 ] && [ "$(grep -c "^GH POST repos/$SLUG/actions/variables tok=admin .*name=CI_SHARD_BUDGET_S" "$CALLS")" = 1 ]'
check "P1 the POSTs carry the values ($(cat "$FX/var.CI_MAX_SHARDS" 2>/dev/null)/$(cat "$FX/var.CI_SHARD_BUDGET_S" 2>/dev/null))" '[ "$(cat "$FX/var.CI_MAX_SHARDS" 2>/dev/null)" = 12 ] && [ "$(cat "$FX/var.CI_SHARD_BUDGET_S" 2>/dev/null)" = 480 ]'
check "P1 one tick line ending in the sizing results: $(lastlog)" '[ "$(ticks)" = 1 ] && lastlog | grep -qE " sizing=CI_MAX_SHARDS:set,CI_SHARD_BUDGET_S:set$"'
check "P1 the sizing alert is resolved" '[ "$(cnt "^ALERT --resolve --id $SID ")" = 1 ]'

# ── P2. the same values already stored: no write.
reset; printf 12 > "$FX/var.CI_MAX_SHARDS"; printf 480 > "$FX/var.CI_SHARD_BUDGET_S"
run CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480
check "P2 no sizing write, two reads" '[ "$(swrites)" = 0 ] && [ "$(sreads)" = 2 ]'
check "P2 :same: $(lastlog)" 'lastlog | grep -qE " sizing=CI_MAX_SHARDS:same,CI_SHARD_BUDGET_S:same$"'
reset; printf 8 > "$FX/var.CI_MAX_SHARDS"; printf 480 > "$FX/var.CI_SHARD_BUDGET_S"
run CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480
check "P2 a stored 8 is PATCHed to 12" '[ "$(grep -c "^GH PATCH repos/$SLUG/actions/variables/CI_MAX_SHARDS tok=admin" "$CALLS")" = 1 ] && [ "$(cat "$FX/var.CI_MAX_SHARDS")" = 12 ] && [ "$(swrites)" = 1 ]'
check "P2 :set,:same: $(lastlog)" 'lastlog | grep -qE " sizing=CI_MAX_SHARDS:set,CI_SHARD_BUDGET_S:same$"'

# ── P3. out-of-range values are refused, the trigger projection still runs.
for v in 0 65 x; do
  reset; printf 8 > "$FX/var.CI_MAX_SHARDS"
  run CI_MAX_SHARDS="$v" CI_SHARD_BUDGET_S=480 'CI_FULL_TRIGGERS=+bin/foo.sh'
  check "P3 ($v) rc 0" '[ "$RC" = 0 ]'
  check "P3 ($v) :refused, no write to CI_MAX_SHARDS: $(lastlog)" 'lastlog | grep -q "sizing=CI_MAX_SHARDS:refused," && [ "$(grep -cE "^GH (GET|POST|PATCH) .*CI_MAX_SHARDS" "$CALLS")" = 0 ] && [ "$(cat "$FX/var.CI_MAX_SHARDS")" = 8 ]'
  check "P3 ($v) one warn sizing alert" '[ "$(cnt "^ALERT --id $SID --severity warn ")" = 1 ] && [ "$(cnt "--id $SID")" = 1 ]'
  check "P3 ($v) the CI_FULL_TRIGGERS projection still runs" '[ "$(cat "$FX/var.CI_FULL_TRIGGERS")" = "+bin/foo.sh" ] && lastlog | grep -q "projection=set"'
done

# ── P4. both unset: nothing read, written or alerted for sizing.
reset
run
check "P4 rc 0" '[ "$RC" = 0 ]'
check "P4 no sizing read or write" '[ "$(sreads)" = 0 ] && [ "$(swrites)" = 0 ]'
check "P4 :unset: $(lastlog)" 'lastlog | grep -qE " sizing=CI_MAX_SHARDS:unset,CI_SHARD_BUDGET_S:unset$"'
check "P4 no sizing alert call" '[ "$(cnt "$SID")" = 0 ]'

# ── P5. a failed PATCH.
reset; printf 8 > "$FX/var.CI_MAX_SHARDS"; printf 480 > "$FX/var.CI_SHARD_BUDGET_S"; : > "$FX/write.fail.CI_MAX_SHARDS"
run CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480
check "P5 rc 0" '[ "$RC" = 0 ]'
check "P5 :failed, never :set: $(lastlog)" 'lastlog | grep -qE " sizing=CI_MAX_SHARDS:failed,CI_SHARD_BUDGET_S:same$"'
check "P5 one warn sizing alert naming the HTTP status" '[ "$(cnt "^ALERT --id $SID --severity warn ")" = 1 ] && grep -q "HTTP 500" "$CALLS"'
check "P5 the variable is unchanged" '[ "$(cat "$FX/var.CI_MAX_SHARDS")" = 8 ]'

# ── P6. --dry-run writes nothing.
reset
run CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480 -- --dry-run
check "P6 rc 0" '[ "$RC" = 0 ]'
check "P6 prints would: POST for both" 'grep -qx "would: POST CI_MAX_SHARDS=12" "$T/out" && grep -qx "would: POST CI_SHARD_BUDGET_S=480" "$T/out"'
check "P6 no write" '[ "$(swrites)" = 0 ] && [ ! -f "$FX/var.CI_MAX_SHARDS" ]'

# ── P7. no token anywhere.
check "P7 no admin token in output or log" '! grep -qF "$TOKEN" "$T/out" "$LOG" 2>/dev/null'

# ── P8. the registry defaults the lane gets with no operator row.
# The registry is composed from THIS checkout's catalog/lanes.d by the real
# bin/lanes-build.sh; the settings worker is not configured, so no row exists.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  || bad "P8 setup: bin/lanes-build.sh failed: $(head -c 300 "$T/lanes.err")"
P8=$(env -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u JOBS_URL -u HARNESS_SECRET -u LANE_GATE_DISABLE \
       HARNESS="$H" LANE_REGISTRY="$T/lanes.json" bash -c '
  . "$1/bin/lib/lane-gate.sh" || exit 9
  lane_env_apply ci-plan-settings
  printf "%s %s\n" "${CI_MAX_SHARDS:-unset}" "${CI_SHARD_BUDGET_S:-unset}"' _ "$DIR" 2>/dev/null | tail -1)
check "P8 lane_env_apply exports CI_MAX_SHARDS=12 CI_SHARD_BUDGET_S=480 with no row: '$P8'" '[ "$P8" = "12 480" ]'

echo "ci-plan-settings-sizing.bh-6876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
