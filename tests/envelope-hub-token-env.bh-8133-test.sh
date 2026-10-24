#!/bin/bash
# tests/envelope-hub-token-env.bh-8133-test.sh — BH-8133 (BH-7964.1): the
# operator surfaces name ENVELOPE_HUB_TOKEN, where it must be set, and the name
# the jobs worker reads (worker/jobs/src/routes/secret-envelopes.js).
#
#   E1  the rendered env template has exactly one `#ENVELOPE_HUB_TOKEN=` line
#   E2  the render ships no value and no uncommented ENVELOPE_HUB_TOKEN line
#   E3  worker/jobs/wrangler.jsonc names it, and only on `//` comment lines
#   E4  the fragment names both places: global.env and
#       `wrangler secret put ENVELOPE_HUB_TOKEN`
#   E5  secret-envelopes.js still reads env.ENVELOPE_HUB_TOKEN
#
# Run from anywhere: tests/envelope-hub-token-env.bh-8133-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
FRAG="$DIR/env-templates/lanes/385-secret-envelope-hub-token.env.example"
WRANGLER="$DIR/worker/jobs/wrangler.jsonc"
ROUTE="$DIR/worker/jobs/src/routes/secret-envelopes.js"
NAME=ENVELOPE_HUB_TOKEN

fail() { echo "FAIL: $*"; exit 1; }

RENDER=$("$DIR/bin/render-env-example.sh") || fail "render-env-example.sh exited non-zero"

# E1
n=$(grep -c "^#${NAME}=\$" <<<"$RENDER")
[ "$n" = 1 ] || fail "E1: render has $n '#ENVELOPE_HUB_TOKEN=' lines, want 1"
echo "PASS E1: render has one commented ENVELOPE_HUB_TOKEN line"

# E2
if grep -qE "^[[:space:]]*(export[[:space:]]+)?${NAME}=|^#${NAME}=." <<<"$RENDER"; then
  fail "E2: render ships an uncommented or valued ENVELOPE_HUB_TOKEN line"
fi
echo "PASS E2: render ships no value"

# E3
grep -q 'ENVELOPE_HUB_TOKEN' "$WRANGLER" || fail "E3: wrangler.jsonc does not name ENVELOPE_HUB_TOKEN"
if grep -qvE '^[[:space:]]*//' < <(grep "$NAME" "$WRANGLER"); then
  fail "E3: wrangler.jsonc names ENVELOPE_HUB_TOKEN on a non-comment line"
fi
grep -q '^[[:space:]]*// secrets (wrangler secret put' "$WRANGLER" || fail "E3: secrets comment block missing"
awk '/\/\/ secrets \(wrangler secret put/{s=1} s && /ENVELOPE_HUB_TOKEN/{f=1} END{exit !f}' "$WRANGLER" \
  || fail "E3: ENVELOPE_HUB_TOKEN is not in the secrets comment block"
echo "PASS E3: wrangler.jsonc names it in the secrets comment block only"

# E4
[ -f "$FRAG" ] || fail "E4: fragment $FRAG missing"
grep -q '/etc/harness/env/global.env' "$FRAG" || fail "E4: fragment does not name /etc/harness/env/global.env"
grep -q 'wrangler secret put ENVELOPE_HUB_TOKEN' "$FRAG" || fail "E4: fragment does not name 'wrangler secret put ENVELOPE_HUB_TOKEN'"
echo "PASS E4: fragment names the hub env and the worker secret"

# E5
grep -q 'env\??\.ENVELOPE_HUB_TOKEN' "$ROUTE" || fail "E5: $ROUTE no longer reads env.ENVELOPE_HUB_TOKEN"
echo "PASS E5: the worker reads the same name"

echo "ALL PASS"
