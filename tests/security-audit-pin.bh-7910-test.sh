#!/bin/bash
# tests/security-audit-pin.bh-7910-test.sh — BH-7910: bin/security-audit.sh
# installs the skill only at the sha pinned in its conf.
#
#   P1  the upstream moved past the pin (the pin is an older commit): the pin is
#       checked out and installed, and the installed SKILL.md is the pinned one
#   P2  the pin is not in the upstream: rc 3, stderr names the sha it found (the
#       upstream HEAD), 0 npx calls, 0 claude calls, summary stopped failed
#   P3  a stubbed git whose rev-parse HEAD in the skill clone lies: rc 3, the
#       message names the lying sha, 0 npx calls
#   P4  a stub npx that installs a modified SKILL.md: rc 4, 0 claude calls
#   P5  the shipped catalog/security-audit.conf pins a 40-hex sha
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/security-audit-pin.bh-7910-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/security-audit-fixture.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git; do command -v "$c" >/dev/null 2>&1 || { echo "$c missing — skipping"; exit 0; }; done

PJ=fixture-pin
sa_fixture_setup "$PJ" || { echo "FAIL: fixture setup"; exit 1; }
OUT="$T/out"
last_summary() { echo "$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json"; }
OLD_PIN="$SA_PIN"

# ── P1: upstream moved on; the pin still installs the pinned file ───────────
( cd "$T/skill-up" && echo 'upstream changed later' >> skills/security-audit/SKILL.md && git commit -qam "later upstream" )
NEW_HEAD=$(git -C "$T/skill-up" rev-parse HEAD)
RC=$(sa_run "$PJ" --out "$OUT")
[ "$RC" = 0 ] && ok || bad "P1 rc $RC: $(cat "$T/run.out")"
[ "$(jq -r .skill_sha "$(last_summary)")" = "$OLD_PIN" ] && ok || bad "P1 skill_sha is not the pin"
[ "$(sa_calls npx)" = 1 ] && [ "$(sa_calls claude)" = 1 ] && ok || bad "P1 npx $(sa_calls npx) claude $(sa_calls claude), want 1/1"

# ── P2: the pin is not in the upstream ───────────────────────────────────────
GONE=2222222222222222222222222222222222222222
sed "s/^skill_sha=.*/skill_sha=$GONE/" "$T/sa.conf" > "$T/sa-gone.conf"
RC=$(SA_CONF_OVERRIDE="$T/sa-gone.conf" sa_run "$PJ" --out "$OUT")
[ "$RC" = 3 ] && ok || bad "P2 rc $RC, want 3: $(cat "$T/run.out")"
grep -q "pin refused: .* pin $GONE, found $NEW_HEAD" "$T/run.out" && ok || bad "P2 the message does not name the found sha $NEW_HEAD: $(cat "$T/run.out")"
[ "$(sa_calls npx)" = 1 ] && [ "$(sa_calls claude)" = 1 ] && ok || bad "P2 a refused pin installed or called (npx $(sa_calls npx), claude $(sa_calls claude))"
[ "$(jq -r .stopped "$(last_summary)")" = failed ] && ok || bad "P2 summary stopped $(jq -r .stopped "$(last_summary)")"
[ "$(jq -r .cost_usd "$(last_summary)")" = null ] && ok || bad "P2 a refused run has a cost"

# ── P3: a stubbed git that lies about the skill clone's HEAD ─────────────────
LIE=3333333333333333333333333333333333333333
REAL_GIT=$(command -v git)
mkdir -p "$T/gitstub"
cat > "$T/gitstub/git" <<SH
#!/bin/bash
if [ "\${1:-}" = -C ] && [[ "\${2:-}" == */.skill-* ]] && [ "\${3:-}" = rev-parse ] && [ "\${4:-}" = HEAD ]; then
  echo $LIE; exit 0
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$T/gitstub/git"
RC=$(PATH="$T/gitstub:$PATH" sa_run "$PJ" --out "$OUT" --again)
[ "$RC" = 3 ] && ok || bad "P3 rc $RC, want 3: $(cat "$T/run.out")"
grep -q "found $LIE" "$T/run.out" && ok || bad "P3 the message does not name $LIE: $(cat "$T/run.out")"
[ "$(sa_calls npx)" = 1 ] && ok || bad "P3 npx ran after a refused pin"

# ── P4: the installed SKILL.md is not the verified one ───────────────────────
echo tamper > "$T/npx-mode"
RC=$(sa_run "$PJ" --out "$OUT" --again)
[ "$RC" = 4 ] && ok || bad "P4 rc $RC, want 4: $(cat "$T/run.out")"
grep -q 'installed SKILL.md differs' "$T/run.out" && ok || bad "P4 message: $(cat "$T/run.out")"
[ "$(sa_calls claude)" = 1 ] && ok || bad "P4 claude ran after a tampered install"
rm -f "$T/npx-mode"

# ── P5: the shipped pin ──────────────────────────────────────────────────────
. "$REPO_DIR/bin/lib/security-audit.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
[[ "$(sa_conf_get "$REPO_DIR/catalog/security-audit.conf" skill_sha)" =~ ^[0-9a-f]{40}$ ]] && ok || bad "P5 the shipped skill_sha is not 40-hex"

echo "security-audit-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
