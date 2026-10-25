#!/bin/bash
# tests/vendor-probe-budget.bh-7965-test.sh — BH-7965 (BH-7937.2): the PR path
# makes 0 vendor calls (scalable tests, rule 6). PATH shims `curl`, `claude` and
# `codex` count every call that is not to the local fixture worker on
# 127.0.0.1, and fail it. Under HARNESS_VENDOR_FAKE=1 the suite then runs what
# the PR-path suites run: bin/envelope-keygen.sh, bin/envelope-consume.sh for
# each vendor, bin/secrets-apply.sh, bin/secret-envelope-sweep.sh and every
# bin/lib/vendor/<v>.sh probe, against the REAL jobs worker
# (tests/lib/envelope-worker.bh-7965.mjs).
#   B0 the shim counts (a premise: an unfaked probe IS counted)
#   B1 the vendor-call counter is 0 and the flow still worked
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vendor-probe-budget.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or openssl missing"; exit 0; }
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }

REAL_CURL=$(command -v curl)
COUNT="$T/vendor-calls"; : > "$COUNT"
mkdir -p "$T/budgetbin"
cat > "$T/budgetbin/curl" <<EOF
#!/bin/bash
# fixture curl: the local worker passes, everything else is a counted vendor call.
cfg=""
for a in "\$@"; do [ "\$a" = - ] && cfg=\$(cat); done
urls=\$(grep -oE 'https?://[^" ]+' <<<"\$* \$cfg")
if [ -n "\$urls" ] && ! grep -qvE '^https?://127\.0\.0\.1[:/]' <<<"\$urls"; then
  if [ -n "\$cfg" ]; then printf '%s\n' "\$cfg" | "$REAL_CURL" "\$@"; exit \$?; fi
  exec "$REAL_CURL" "\$@"
fi
echo "curl \$*" >> "$COUNT"; exit 7
EOF
for c in claude codex; do printf '#!/bin/bash\necho %s >> "%s"\nexit 1\n' "$c" "$COUNT" > "$T/budgetbin/$c"; done
chmod +x "$T/budgetbin/"*
export PATH="$T/budgetbin:$PATH"

echo "B0: the shim counts"
printf 'tok-fixture-xai-good' | HARNESS_VENDOR_FAKE=0 "$H/bin/lib/vendor/xai.sh" probe >/dev/null 2>&1
[ "$(grep -c '^curl' "$COUNT")" -ge 1 ] && ok "B0 an unfaked xai probe is counted" || bad "B0 the shim did not count an unfaked probe"
: > "$COUNT"

echo "B1: 0 vendor calls on the PR path"
"$H/bin/envelope-keygen.sh" >/dev/null 2>&1 || bad "B1 keygen failed"
openssl pkey -in "$ENVELOPE_KEY" -pubout -out "$T/keys/pub.pem" 2>/dev/null
N=0
for v in claude codex openrouter fireworks xai; do
  id=$(es_seal "tok-fixture-$v-good" "ai-account:$v:budget-$v:project:demo")
  "$H/bin/envelope-consume.sh" "$id" >/dev/null 2>&1 && N=$((N + 1))
  printf 'tok-fixture-%s-good' "$v" | "$H/bin/lib/vendor/$v.sh" probe >/dev/null 2>&1 || bad "B1 $v fake probe did not prove"
done
[ "$N" = 5 ] && ok "B1 5 envelopes consumed through the fake seams" || bad "B1 consumed $N of 5"
es_seal tok-fixture-xai-good2 ai-account:xai:budget-tick:pool >/dev/null
"$H/bin/secrets-apply.sh" >/dev/null 2>&1
grep -q 'consumed=1' "$H/logs/secrets-apply.log" && ok "B1 secrets-apply consumed one" || bad "B1 secrets-apply: $(tail -1 "$H/logs/secrets-apply.log")"
"$H/bin/secret-envelope-sweep.sh" >/dev/null 2>&1 && ok "B1 the sweep ran" || bad "B1 sweep failed"
[ "$(wc -l < "$COUNT")" = 0 ] && ok "B1 vendor calls: 0" || bad "B1 vendor calls: $(head -3 "$COUNT")"

echo "vendor-probe-budget.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
