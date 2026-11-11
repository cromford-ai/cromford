#!/bin/bash
# tests/selfhost-install-api-key.bh-9335-test.sh — BH-9335 (slice C0): the
# self-host installer plans the per-project model-auth rows.
#
# Every case drives the real bin/selfhost-install.sh with the shipped
# env-templates/selfhost.conf.example, blanks filled with made-up values.
#
#   a  api-key + lock + caps: SETTING claude_auth/runner_lock/cost_ceiling per
#      project, and one SECRET ANTHROPIC_API_KEY_<PROJECT> per project
#   b  no key value is printed; a conf with ANTHROPIC_API_KEY=... is refused
#   c  oauth, no lock: the plan equals the golden captured from main's script
#   d  oauth + lock: claude_auth=oauth + lock rows, no ANTHROPIC_API_KEY_ line
#   e  SELFHOST_RUNNER_LOCK=codex (or Claude) is refused, naming the key
#   f  api-key + SELFHOST_CAPS_OFF=1: cost_ceiling is skip(caps off)
#   g  --help still prints the whole header, through the Exit line
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/selfhost-install-api-key.bh-9335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SH="$REPO/bin/selfhost-install.sh"
TPL="$REPO/env-templates/selfhost.conf.example"
GOLDEN="$REPO/tests/fixtures/selfhost/oauth-plan.bh-9335.golden"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# conf <file> [KEY=VAL ...] — the template with blanks filled, then each KEY=VAL
# replacing that key's line, or appended when the template has no such line.
conf() {
  local f="$1"; shift
  sed -e 's|^SELFHOST_CF_ACCOUNT_ID=$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|' \
      -e 's|^HARNESS_WORKERS_SUBDOMAIN=$|HARNESS_WORKERS_SUBDOMAIN=acme|' \
      -e 's|^CONSOLE_PAGES_PROJECT=$|CONSOLE_PAGES_PROJECT=acme-console|' \
      -e 's|^BACKUP_S3_BUCKET=$|BACKUP_S3_BUCKET=acme-backup|' \
      -e 's|^HARNESS_REPO=$|HARNESS_REPO=acme-org/acme-harness|' \
      -e 's|^HARNESS_OPERATOR_LOGIN=$|HARNESS_OPERATOR_LOGIN=acme-op|' \
      -e 's|^HARNESS_GIT_NAME=$|HARNESS_GIT_NAME=acme-op|' \
      -e 's|^HARNESS_GIT_EMAIL=$|HARNESS_GIT_EMAIL=op@acme.example|' \
      -e 's|^SELFHOST_GH_AUTH=$|SELFHOST_GH_AUTH=app|' \
      -e 's|^HARNESS_BOX_PREFIX=$|HARNESS_BOX_PREFIX=acme-|' \
      -e 's|^HARNESS_HUB_BOX=$|HARNESS_HUB_BOX=acme-hub|' \
      -e 's|^SELFHOST_HUB=$|SELFHOST_HUB=fly|' \
      -e 's|^FLY_ORG=$|FLY_ORG=acme-fly|' \
      -e 's|^SELFHOST_POOL=$|SELFHOST_POOL=fly|' \
      -e 's|^SELFHOST_PROJECTS=$|SELFHOST_PROJECTS=alpha=o/a beta-two=o/b|' \
      -e 's|^SELFHOST_MODEL_AUTH=$|SELFHOST_MODEL_AUTH=oauth|' \
      "$TPL" > "$f"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if grep -q "^$k=" "$f"; then
      awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k "=" v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
  done
}
run() { OUT=$(bash "$SH" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
has() { grep -qxF -- "$1" <<< "$OUT"; }

# ── a: api-key + lock + caps on ──────────────────────────────────────────────
conf "$T/a.conf" SELFHOST_MODEL_AUTH=api-key SELFHOST_RUNNER_LOCK=claude
run --config "$T/a.conf"
[ "$RC" = 0 ] && ok || bad "a rc=$RC want 0 ($ERR)"
for l in "SETTING claude_auth.alpha=api-key" "SETTING runner_lock.alpha=claude" "SETTING cost_ceiling.alpha=20" \
         "SETTING claude_auth.beta-two=api-key" "SETTING runner_lock.beta-two=claude" "SETTING cost_ceiling.beta-two=20" \
         "SECRET ANTHROPIC_API_KEY_ALPHA needed-by=claude_auth.alpha where=fly-secret" \
         "SECRET ANTHROPIC_API_KEY_BETA_TWO needed-by=claude_auth.beta-two where=fly-secret"; do
  has "$l" && ok || bad "a missing line: $l"
done
# SETTING lines sit after the CAP lines and before the first SECRET line.
order=$(grep -nE '^(CAP|SETTING|SECRET|SUMMARY)' <<< "$OUT" | cut -d: -f2- | awk '{print $1}' | uniq | tr '\n' ' ')
[ "$order" = "CAP SETTING SECRET SUMMARY " ] && ok || bad "a line-kind order is '$order'"
# The global catalog secret stays as it was (bh-4081 C8 pins it).
grep -q '^SECRET ANTHROPIC_API_KEY needed-by=' <<< "$OUT" && ok || bad "a the catalog SECRET ANTHROPIC_API_KEY line is gone"

# ── b: no key value printed, a key in the conf is refused ────────────────────
if grep -qE 'sk-ant-|=sk-' <<< "$OUT"; then bad "b a key-shaped value printed"; else ok; fi
if grep -E '^(SETTING|SECRET)' <<< "$OUT" | grep -qE '=[A-Za-z0-9_-]{20,}'; then bad "b a 20+ char value on a SETTING/SECRET line"; else ok; fi
conf "$T/b.conf" SELFHOST_MODEL_AUTH=api-key ANTHROPIC_API_KEY=sk-ant-fixture-not-a-key
run --config "$T/b.conf"
[ "$RC" = 1 ] && ok || bad "b conf with ANTHROPIC_API_KEY rc=$RC want 1"
grep -q 'ANTHROPIC_API_KEY looks like a secret' <<< "$ERR" && ok || bad "b refusal does not name ANTHROPIC_API_KEY: $ERR"
if grep -q 'sk-ant-' <<< "$OUT$ERR"; then bad "b the refused value was echoed"; else ok; fi

# ── c: oauth, no lock = byte-identical to main ───────────────────────────────
conf "$T/c.conf"
run --config "$T/c.conf"
[ "$RC" = 0 ] && ok || bad "c rc=$RC want 0 ($ERR)"
if [ -r "$GOLDEN" ] && [ "$OUT" = "$(grep -v '^# ' "$GOLDEN")" ]; then ok
else bad "c oauth/no-lock plan differs from $GOLDEN: $(diff <(grep -v '^# ' "$GOLDEN") <(printf '%s\n' "$OUT") | head -5)"; fi
# blank lock line in the conf is the same as no line
conf "$T/c2.conf" SELFHOST_RUNNER_LOCK=
run --config "$T/c2.conf"
[ "$RC" = 0 ] && [ "$OUT" = "$(grep -v '^# ' "$GOLDEN")" ] && ok || bad "c blank SELFHOST_RUNNER_LOCK changed the plan (rc=$RC)"

# ── d: oauth + lock ──────────────────────────────────────────────────────────
conf "$T/d.conf" SELFHOST_RUNNER_LOCK=claude
run --config "$T/d.conf"
[ "$RC" = 0 ] && ok || bad "d rc=$RC want 0 ($ERR)"
for l in "SETTING claude_auth.alpha=oauth" "SETTING runner_lock.alpha=claude" "SETTING cost_ceiling.alpha=20" \
         "SETTING claude_auth.beta-two=oauth" "SETTING runner_lock.beta-two=claude"; do
  has "$l" && ok || bad "d missing line: $l"
done
if grep -q 'ANTHROPIC_API_KEY_' <<< "$OUT"; then bad "d oauth printed a per-project API key secret"; else ok; fi
# api-key without the lock prints no runner_lock row
conf "$T/d2.conf" SELFHOST_MODEL_AUTH=api-key
run --config "$T/d2.conf"
has "SETTING claude_auth.alpha=api-key" && ok || bad "d2 api-key/no-lock: no claude_auth row"
if grep -q '^SETTING runner_lock' <<< "$OUT"; then bad "d2 api-key/no-lock printed a runner_lock row"; else ok; fi

# ── e: an invalid lock value is refused ──────────────────────────────────────
for v in codex Claude; do
  conf "$T/e.conf" SELFHOST_RUNNER_LOCK="$v"
  run --config "$T/e.conf"
  [ "$RC" = 1 ] && ok || bad "e lock=$v rc=$RC want 1"
  grep -q "SELFHOST_RUNNER_LOCK" <<< "$ERR" && ok || bad "e lock=$v refusal does not name SELFHOST_RUNNER_LOCK: $ERR"
  [ -z "$OUT" ] && ok || bad "e lock=$v printed a plan"
done

# ── f: caps off ──────────────────────────────────────────────────────────────
conf "$T/f.conf" SELFHOST_MODEL_AUTH=api-key SELFHOST_CAPS_OFF=1
run --config "$T/f.conf"
[ "$RC" = 0 ] && ok || bad "f rc=$RC want 0 ($ERR)"
has "SETTING cost_ceiling.alpha skip(caps off)" && ok || bad "f no skip(caps off) row for alpha"
if grep -q '^SETTING cost_ceiling.alpha=' <<< "$OUT"; then bad "f caps off still printed a ceiling value"; else ok; fi

# ── g: --help prints the whole header ────────────────────────────────────────
run --help
[ "$RC" = 0 ] && ok || bad "g --help rc=$RC"
[ "$(printf '%s\n' "$OUT" | tail -n 1 | cut -c1-5)" = "Exit:" ] && ok || bad "g --help last line is '$(printf '%s\n' "$OUT" | tail -n 1)'"
grep -q '^  SETTING ' <<< "$OUT" && ok || bad "g --help does not describe the SETTING line"

echo "selfhost-install-api-key.bh-9335: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
