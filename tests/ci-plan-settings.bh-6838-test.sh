#!/bin/bash
# tests/ci-plan-settings.bh-6838-test.sh — BH-6838 Task 5: the hub lane
# bin/ci-plan-settings.sh projects the settings row CI_FULL_TRIGGERS (the
# full-trigger delta over catalog/ci-batch-escalate.tsv) into the repo Actions
# variable of the same name, and bin/ci-plan.sh reads that value back.
#
# The real lane runs against a scratch $HARNESS (its closure installed with
# scratch_install_closure). The seams are stubbed, and nothing else is:
#   gh (on PATH)        answers `gh api -i` with an HTTP status line and a body
#                       per route, so the real bin/lib/gh-rest*.sh parse it
#   bin/lane-alert.sh   records its argv
# Every call lands in calls.log, one line each, in order.
#
#   S1  --dry-run prints `would: PATCH CI_FULL_TRIGGERS=<normalised>`, writes nothing
#   S2  round trip: 404 then POST of `+bin/foo.sh -.mergify.yml`; the stored
#       value fed to the REAL bin/ci-plan.sh as a merge-queue batch escalates
#       bin/foo.sh and no longer escalates .mergify.yml
#   S2b a stored value that differs is PATCHed, log `set`
#   S3  no admin token: one warn alert ci-plan-settings-projection:<slug>,
#       rc 0, no gh call; the next good tick resolves it
#   S4  the same value already set: no write, log `same`
#   S5  a value over 256 chars is refused: warn alert, no gh call
#   S6  a failed read (HTTP 500): warn alert, no write, rc 0
#   S7  flags/lane-off-ci-plan-settings: no gh call, no tick line
#
# Run from anywhere: tests/ci-plan-settings.bh-6838-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

LANE="$DIR/bin/ci-plan-settings.sh"
PLAN="$DIR/bin/ci-plan.sh"
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
case "\$M \$P" in
  "GET repos/$SLUG/actions/variables/CI_FULL_TRIGGERS")
    [ -f "$FX/get.fail" ] && { reply 500 '{"message":"fixture server error"}'; exit 0; }
    if [ -f "$FX/var" ]; then jq -cn --rawfile v "$FX/var" '{name: "CI_FULL_TRIGGERS", value: \$v}' > "$FX/get.json"; reply 200 "\$(cat "$FX/get.json")"
    else reply 404 '{"message":"Not Found"}'; fi ;;
  "POST repos/$SLUG/actions/variables")
    [ "\$name" = CI_FULL_TRIGGERS ] || { reply 422 '{}'; exit 0; }
    printf '%s' "\$val" > "$FX/var"; reply 201 '{}' ;;
  "PATCH repos/$SLUG/actions/variables/CI_FULL_TRIGGERS") printf '%s' "\$val" > "$FX/var"; reply 204 '' ;;
  *) reply 500 '{}' ;;
esac
EOF
chmod +x "$H/bin/lane-alert.sh" "$T/stubbin/gh"

# reset — a fresh world: the admin token, no variable, no calls, no log, no flags.
reset() {
  local d; for d in "$FX" "$H/logs" "$H/locks" "$H/flags" "$H/state"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FX" "$H/flags"; : > "$CALLS"
  printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"
}
# run [VAR=val ...] [-- args] — one tick of the real lane; stdout+stderr to $T/out, RC set.
run() {
  local vars=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; args=("$@")
  env -u GH_ADMIN_TOKEN -u GH_TOKEN -u HARNESS_ENV_DIR -u CI_FULL_TRIGGERS HARNESS="$H" PATH="$T/stubbin:$PATH" \
    LANE_GATE_DISABLE=1 HARNESS_REPO="$SLUG" ${vars[@]+"${vars[@]}"} \
    bash "$LANE" ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  RC=$?
}
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
writes() { grep -cE '^GH (POST|PATCH)' "$CALLS" 2>/dev/null || true; }
ticks() { [ -f "$LOG" ] || { echo 0; return; }; grep -c ' ci-plan-settings ' "$LOG"; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
ALERT_ID="ci-plan-settings-projection:$SLUG"

# ── S1: --dry-run against a stored value that differs ───────────────────────
reset; printf 'old-fixture' > "$FX/var"
run 'CI_FULL_TRIGGERS=+bin/foo.sh  +bin/foo.sh -bin/ci-plan.sh +a..b' -- --dry-run
check "S1 rc 0" '[ "$RC" = 0 ]'
check "S1 prints would: PATCH with the normalised value" 'grep -qx "would: PATCH CI_FULL_TRIGGERS=+bin/foo.sh" "$T/out"'
check "S1 writes nothing (no POST/PATCH)" '[ "$(writes)" = 0 ]'
check "S1 the variable is unchanged" '[ "$(cat "$FX/var")" = old-fixture ]'
check "S1 the read used the admin token" '[ "$(cnt "^GH GET repos/$SLUG/actions/variables/CI_FULL_TRIGGERS tok=admin")" = 1 ]'
check "S1 no alert is sent on a dry run" '[ "$(cnt "^ALERT")" = 0 ]'
check "S1 one tick line, marked dry-run" '[ "$(ticks)" = 1 ] && lastlog | grep -q "dry-run"'
check "S1 the refused self row and the .. token are said" 'grep -q "bin/ci-plan.sh refused" "$T/out" && grep -q "a..b ignored" "$T/out"'

# ── S2: round trip through 404 + POST, then the real planner ───────────────
reset
run 'CI_FULL_TRIGGERS=+bin/foo.sh -.mergify.yml'
check "S2 rc 0" '[ "$RC" = 0 ]'
check "S2 a 404 is answered with one POST (admin token)" '[ "$(cnt "^GH POST repos/$SLUG/actions/variables tok=admin")" = 1 ] && [ "$(writes)" = 1 ]'
check "S2 the POST body carries the normalised value" '[ "$(cat "$FX/var" 2>/dev/null)" = "+bin/foo.sh -.mergify.yml" ]'
check "S2 log says set" 'lastlog | grep -q "projection=set"'
check "S2 a good tick resolves the projection alert" '[ "$(cnt "^ALERT --resolve --id $ALERT_ID ")" = 1 ]'
STORED=$(cat "$FX/var" 2>/dev/null)

"$DIR/bin/test-impact.sh" map --out "$T/map" > /dev/null 2>&1 || { echo "FAIL: S2 the impact map could not be built"; exit 1; }
cat > "$T/impact.sh" <<EOF
#!/bin/bash
exec "$DIR/bin/test-impact.sh" "\$@" --map "$T/map"
EOF
chmod +x "$T/impact.sh"
: > "$T/notiers.tsv"
BASESHA=$(git -C "$DIR" rev-parse HEAD)
# bplan <delta> <path> — one merge-queue batch plan of the real bin/ci-plan.sh; sets RC MODE ESC
bplan() {
  printf '%s\n' "$2" > "$T/changed"; rm -f "$T/go" "$T/list"
  env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x TI_BASE="$BASESHA" \
    CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_FULL_TRIGGERS="$1" CI_PLAN_IMPACT="$T/impact.sh" \
    CI_PLAN_CHANGED_FILE="$T/changed" CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" \
    GITHUB_STEP_SUMMARY="$T/sum" "$PLAN" --out "$T/list" > "$T/plan.out" 2>&1; RC=$?
  MODE=$(sed -n 's/^mode=//p' "$T/go" 2>/dev/null | tail -1); ESC=$(sed -n 's/^escalation=//p' "$T/go" 2>/dev/null | tail -1)
}
bplan "" bin/foo.sh
check "S2 control: with no delta bin/foo.sh is not escalated (got '$ESC')" '[ "$RC" = 0 ] && [ "$ESC" != "selection input: bin/foo.sh" ]'
bplan "" .mergify.yml
check "S2 control: with no delta .mergify.yml escalates (got '$ESC')" '[ "$RC" = 0 ] && [ "$ESC" = "selection input: .mergify.yml" ]'
bplan "$STORED" bin/foo.sh
check "S2 the stored value escalates bin/foo.sh (mode=$MODE escalation='$ESC')" '[ "$RC" = 0 ] && [ "$MODE" = full ] && [ "$ESC" = "selection input: bin/foo.sh" ]'
bplan "$STORED" .mergify.yml
check "S2 the stored value un-escalates .mergify.yml (mode=$MODE escalation='$ESC')" '[ "$RC" = 0 ] && [ "$ESC" != "selection input: .mergify.yml" ]'

# ── S2b: a stored value that differs is PATCHed ────────────────────────────
reset; printf 'old-fixture' > "$FX/var"
run 'CI_FULL_TRIGGERS=+bin/foo.sh'
check "S2b rc 0" '[ "$RC" = 0 ]'
check "S2b one PATCH, no POST" '[ "$(cnt "^GH PATCH repos/$SLUG/actions/variables/CI_FULL_TRIGGERS tok=admin")" = 1 ] && [ "$(writes)" = 1 ]'
check "S2b the variable holds the new value" '[ "$(cat "$FX/var")" = "+bin/foo.sh" ]'
check "S2b log says set" 'lastlog | grep -q "projection=set"'

# ── S3: no admin token, then a good tick resolves ──────────────────────────
reset; rm -f "$H/env/github-admin.env"
run 'CI_FULL_TRIGGERS=+bin/foo.sh'
check "S3 rc 0" '[ "$RC" = 0 ]'
check "S3 one warn alert with the projection id" '[ "$(cnt "^ALERT --id $ALERT_ID --severity warn ci-plan-settings ")" = 1 ] && [ "$(cnt "^ALERT --id")" = 1 ]'
check "S3 no gh call at all" '[ "$(cnt "^GH ")" = 0 ]'
check "S3 one tick line, projection=failed" '[ "$(ticks)" = 1 ] && lastlog | grep -q "projection=failed"'
printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"; : > "$CALLS"
run 'CI_FULL_TRIGGERS=+bin/foo.sh'
check "S3 the next good tick resolves the alert" '[ "$(cnt "^ALERT --resolve --id $ALERT_ID ")" = 1 ] && [ "$(cnt "^ALERT --id")" = 0 ]'

# ── S4: the same value already set ─────────────────────────────────────────
reset; printf '+bin/foo.sh -.mergify.yml' > "$FX/var"
run 'CI_FULL_TRIGGERS=  +bin/foo.sh   -.mergify.yml '
check "S4 rc 0" '[ "$RC" = 0 ]'
check "S4 no write" '[ "$(writes)" = 0 ] && [ "$(cnt "^GH GET")" = 1 ]'
check "S4 log says same" '[ "$(ticks)" = 1 ] && lastlog | grep -q "projection=same"'
reset; printf -- '-' > "$FX/var"
run
check "S4 an empty row is stored as - and is the same as -" '[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && lastlog | grep -q "projection=same"'

# ── S5: a value over 256 chars is refused ──────────────────────────────────
reset; printf 'old-fixture' > "$FX/var"
LONG="+bin/$(printf 'x%.0s' $(seq 1 260)).sh"
run "CI_FULL_TRIGGERS=$LONG"
check "S5 rc 0" '[ "$RC" = 0 ]'
check "S5 no gh call, the variable is unchanged" '[ "$(cnt "^GH ")" = 0 ] && [ "$(cat "$FX/var")" = old-fixture ]'
check "S5 one warn alert with the projection id" '[ "$(cnt "^ALERT --id $ALERT_ID --severity warn ")" = 1 ]'
check "S5 log says refused" 'lastlog | grep -q "projection=refused"'

# ── S6: a failed read ───────────────────────────────────────────────────────
reset; printf 'old-fixture' > "$FX/var"; : > "$FX/get.fail"
run 'CI_FULL_TRIGGERS=+bin/foo.sh'
check "S6 rc 0" '[ "$RC" = 0 ]'
check "S6 no write" '[ "$(writes)" = 0 ] && [ "$(cat "$FX/var")" = old-fixture ]'
check "S6 one warn alert naming the HTTP status" '[ "$(cnt "^ALERT --id $ALERT_ID --severity warn ")" = 1 ] && grep -q "HTTP 500" "$CALLS"'

# ── S7: the lane is off ─────────────────────────────────────────────────────
reset; printf 'old-fixture' > "$FX/var"; : > "$H/flags/lane-off-ci-plan-settings"
run 'CI_FULL_TRIGGERS=+bin/foo.sh' LANE_GATE_DISABLE=0
check "S7 rc 0" '[ "$RC" = 0 ]'
check "S7 no gh call, no alert, no tick line" '[ "$(cnt "^GH ")" = 0 ] && [ "$(cnt "^ALERT")" = 0 ] && [ "$(ticks)" = 0 ]'
rm -f "$H/flags/lane-off-ci-plan-settings"
run 'CI_FULL_TRIGGERS=+bin/foo.sh' LANE_GATE_DISABLE=0
check "S7 control: the gate on with no flag runs the tick" '[ "$RC" = 0 ] && [ "$(writes)" = 1 ]'

# No token anywhere in the output or the log.
check "no admin token in output or log" '! grep -qF "$TOKEN" "$T/out" "$LOG" 2>/dev/null'

echo "ci-plan-settings: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
