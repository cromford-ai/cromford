#!/bin/bash
# tests/load-project-qa-wiring.bh-6254-test.sh — bin/load-project.sh prints a
# `== browser QA ==` block after `== LOADED`, from the REAL bin/qa-wiring-check.sh.
#
# Runs the `# >>> browser QA` … `# <<< browser QA` block out of
# bin/load-project.sh in a scratch dir whose bin/ holds the real check.
#   L3  each marker exists once; the block sits after `== LOADED` and outside
#       the doorbell banner markers
#   L1  a project with prod `-` -> `== browser QA ==`, `OWED: prod URL`, the
#       "not wired" sentence, and block rc 0 (never fatal)
#   L2  a fully wired project -> five `ok:` lines and no "not wired" sentence
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/load-project-qa-wiring.bh-6254-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

LP="$DIR/bin/load-project.sh"
# L3
nb=$(grep -c '^# >>> browser QA' "$LP"); ne=$(grep -c '^# <<< browser QA' "$LP")
lb=$(grep -n '^# >>> browser QA' "$LP" | head -1 | cut -d: -f1)
ll=$(grep -n -m1 'echo "== LOADED: \$PROJECT =="' "$LP" | cut -d: -f1)
db=$(grep -n '^# >>> doorbell banner' "$LP" | head -1 | cut -d: -f1)
de=$(grep -n '^# <<< doorbell banner' "$LP" | head -1 | cut -d: -f1)
sed -n '/^# >>> browser QA/,/^# <<< browser QA/p' "$LP" > "$T/block.sh"
if [ "$nb" = 1 ] && [ "$ne" = 1 ] && [ -n "$ll" ] && [ "${lb:-0}" -gt "$ll" ] \
   && { [ "$lb" -lt "${db:-0}" ] || [ "$lb" -gt "${de:-0}" ]; } && grep -q 'qa-wiring-check.sh' "$T/block.sh"; then ok
else bad "L3 markers begin=$nb end=$ne at=${lb:-none} loaded=${ll:-none} doorbell=${db:-}-${de:-}"; fi

# The scratch checkout: the real check and its closure, stubbed edges.
R="$T/run"; H="$T/h"
mkdir -p "$R" "$H/bin" "$H/env" "$T/web"
for s in bin/qa-wiring-check.sh bin/fleet-conf.sh bin/prod-url.sh; do
  scratch_install_closure "$s" "$R" >/dev/null || { echo "FAIL: cannot install $s closure"; exit 1; }
done
printf 'setting_get() { [ "$1" = deploy.qa-good.kind ] && { printf github-deployment; return 0; }; return 2; }\n' > "$H/bin/jobs-client.sh"
cat > "$T/fleet.conf" <<EOF
qa-good    Test/qa-good    https://app.example.test  -  1  box-test 192.0.2.1
qa-noprod  Test/qa-noprod  -                         -  2  box-test 192.0.2.1
EOF
printf 'qa-good team_fixture prj_fixture app.example.test\n' > "$T/vercel.conf"
printf 'QA_TEST_USER_ID=user_fixture1\nQA_CLERK_SECRET_KEY=sk_test_fixture2\n' > "$H/env/qa-good.env"
printf '{"qa-good":{"member":{"user_id":"user_fixture1"}}}\n' > "$T/accounts.json"
PK="pk_test_$(printf 'clerk.example.test$' | base64 | tr -d '=\n')"
cat > "$T/curl" <<EOF
#!/bin/bash
out=""; fmt=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift 2 ;; -w) fmt="\$2"; shift 2 ;; -H|--max-time) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac
done
case "\$url" in
  */v1/environment) printf '{}' > "\$out"; printf 200 ;;
  *) printf '<html>%s</html>\n' "$PK" > "\$out" ;;
esac
EOF
chmod +x "$T/curl"
export HARNESS="$H" FLEET_CONF="$T/fleet.conf" VERCEL_CONF="$T/vercel.conf" \
  QA_ACCOUNTS="$T/accounts.json" QA_WIRING_CURL="$T/curl"
block() { OUT=$(cd "$R" && PROJECT="$1" bash "$T/block.sh" 2>&1); RC=$?; }

# L1
block qa-noprod
if [ "$RC" = 0 ] && grep -qx '== browser QA ==' <<< "$OUT" && grep -q '^OWED: prod URL' <<< "$OUT" \
   && grep -q 'browser QA is not wired for qa-noprod' <<< "$OUT"; then ok
else bad "L1 rc=$RC: $OUT"; fi

# L2
block qa-good
if [ "$RC" = 0 ] && grep -qx '== browser QA ==' <<< "$OUT" && [ "$(grep -c '^ok: ' <<< "$OUT")" = 5 ] \
   && ! grep -q 'not wired' <<< "$OUT"; then ok
else bad "L2 rc=$RC: $OUT"; fi

echo "load-project-qa-wiring (BH-6254): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
