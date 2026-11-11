#!/bin/bash
# tests/endpoints-vendor.bh-1941-test.sh — endpoints wave 1 (BH-1941,
# BH-1511.4): four scripts take their vendor API base URL from the endpoint
# resolver (bin/lib/endpoints.sh endpoint_url) instead of a literal.
#
# THE RULE (the design note on #1941, from the #2001 review): an endpoint knob
# registers `settable: false` and `required: true`, so it resolves from the env,
# else the registry default, and NO settings row can move it (a URL a root lane
# sends `Bearer $SECRET` to is not editable from the console, BH-1165). The
# registry default is today's URL, so nothing changes.
#
# WHAT IS DRIVEN. The real scripts, from a scratch $HARNESS, against the REAL
# composed registry (lanes_json_path over catalog/lanes.d, via LANE_REGISTRY),
# with a stub `curl` on PATH that records every URL it is asked for.
#   V1  no env: each script calls exactly today's URL (registry default + path)
#   V2  ENDPOINT_<SERVICE> in the env: each script calls <env value><path>
#   V3  an EMPTY resolver (the same registry with the endpoint defaults nulled):
#       each script exits NONZERO and the stub logs ZERO calls
#   V4  the four scripts carry none of the four vendor hosts as a literal
#   V5  the four knobs are registered settable:false, required:true, with
#       today's URL as the default
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/endpoints-vendor.bh-1941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset ENDPOINT_FLY_MACHINES ENDPOINT_CLERK ENDPOINT_OPENROUTER ENDPOINT_OPENAI CLERK_API LANE_REGISTRY
export ETC_HARNESS_ENV="$T/no-such-etc"

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state/fly" "$H/logs" "$H/flags" "$H/catalog" "$T/fakebin" "$T/ck/catalog"
for s in fly-api.sh qa-clerk-ban.sh vendor-spend-pull.sh update-model-prices.sh; do cp "$DIR/bin/$s" "$H/bin/"; done
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"

# The real registry, composed exactly as production composes it.
REG=$(bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR")
[ -s "$REG" ] && ok || { echo "FAIL: could not compose the registry"; exit 1; }
cp "$REG" "$T/reg.json"
# The EMPTY resolver: the same registry, every endpoint knob's default nulled.
jq '(.libs[]? | select(.id | startswith("endpoint-")) | .knobs[].default) = null' "$T/reg.json" > "$T/reg-empty.json"

# The stub curl: every URL (the last argument) goes to $T/urls; a canned answer
# per vendor; `-o <file>` gets the body, `-w` prints 200.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
url="${!#}"; out=""; w=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$url" >> "$URLS"
case "$url" in
  */v1/credits)                 body='{"data":{"total_credits":100,"total_usage":1}}' ;;
  */api/v1/keys*)               body='{"data":[]}' ;;
  */v1/organization/costs*)     body='{"data":[]}' ;;
  */v1/apps\?org_slug=*)        body='{"apps":[]}' ;;
  */v1/apps/*/machines/*)       body='{"state":"started"}' ;;
  */v1/users/*)                 body='{"banned":false}' ;;
  */api/v1/models)              body='{"data":[]}' ;;
  *)                            body='{}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ -n "$w" ] && printf '200'
exit 0
STUB
chmod +x "$T/fakebin/curl"

# Fixtures each script needs to reach its first call.
printf 'FLY_API_TOKEN_DEMO=tok-FIXTURE\n' > "$H/env/fly.env"
printf '{"app":"demo-app","machine_id":"m123"}\n' > "$H/state/fly/demo.json"
printf 'OPENROUTER_API_KEY=or-FIXTURE\nOPENAI_ADMIN_KEY=oa-FIXTURE\nFLY_API_TOKEN=fly-FIXTURE\nFLY_ORG=personal\n' > "$H/env/global.env"
printf '{"some-model":"vendor/some-model"}\n' > "$T/ck/catalog/model-slugs.json"

# run <registry> <script> [args…] — one script, a fresh URL log; the env the
# caller put in front of it passes through (ENDPOINT_* for V2).
run() {
  local reg="$1" script="$2"; shift 2
  : > "$T/urls"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_CHECKOUT="$T/ck" MODEL_SLUGS="$T/ck/catalog/model-slugs.json" \
      LANE_REGISTRY="$reg" URLS="$T/urls" QA_CLERK_SECRET_KEY=sk_test_FIXTURE HARNESS_TEST_SANDBOX=1 \
      bash "$H/bin/$script" "$@" >"$T/out" 2>"$T/err" )
}
urls() { cat "$T/urls" 2>/dev/null; }
calls() { local n; n=$(grep -c . "$T/urls" 2>/dev/null); echo "${n:-0}"; }

# case <label> <expected-url> <script> [args…]
expect_url() {
  local label="$1" want="$2"; shift 2
  run "$T/reg.json" "$@"
  grep -qxF -- "$want" "$T/urls" && ok || bad "$label: want exactly $want (called: $(urls | tr '\n' ' '); err: $(head -c 300 "$T/err"))"
}

# ── V1: no env, today's URLs ─────────────────────────────────────────────────
expect_url "V1 fly-api"          "https://api.machines.dev/v1/apps/demo-app/machines/m123" fly-api.sh demo state
expect_url "V1 qa-clerk-ban"     "https://api.clerk.com/v1/users/user_1"                   qa-clerk-ban.sh demo user_1 status
expect_url "V1 update-prices"    "https://openrouter.ai/api/v1/models"                      update-model-prices.sh
expect_url "V1 spend openrouter" "https://openrouter.ai/api/v1/credits"                     vendor-spend-pull.sh --vendor openrouter --dry-run
run "$T/reg.json" vendor-spend-pull.sh --vendor codex --dry-run
grep -q '^https://api.openai.com/v1/organization/costs?start_time=' "$T/urls" && ok || bad "V1 spend codex: want https://api.openai.com/v1/organization/costs?start_time=… (called: $(urls))"
expect_url "V1 spend fly"        "https://api.machines.dev/v1/apps?org_slug=personal"       vendor-spend-pull.sh --vendor fly --dry-run

# ── V2: ENDPOINT_<SERVICE> in the env moves each call ───────────────────────
export ENDPOINT_FLY_MACHINES=https://fly.proxy.example.test ENDPOINT_CLERK=https://clerk.proxy.example.test \
       ENDPOINT_OPENROUTER=https://or.proxy.example.test ENDPOINT_OPENAI=https://oa.proxy.example.test
expect_url "V2 fly-api"          "https://fly.proxy.example.test/v1/apps/demo-app/machines/m123" fly-api.sh demo state
expect_url "V2 qa-clerk-ban"     "https://clerk.proxy.example.test/v1/users/user_1"              qa-clerk-ban.sh demo user_1 status
expect_url "V2 update-prices"    "https://or.proxy.example.test/api/v1/models"                   update-model-prices.sh
expect_url "V2 spend openrouter" "https://or.proxy.example.test/api/v1/credits"                  vendor-spend-pull.sh --vendor openrouter --dry-run
run "$T/reg.json" vendor-spend-pull.sh --vendor codex --dry-run
grep -q '^https://oa.proxy.example.test/v1/organization/costs?start_time=' "$T/urls" && ok || bad "V2 spend codex (called: $(urls))"
expect_url "V2 spend fly"        "https://fly.proxy.example.test/v1/apps?org_slug=personal"      vendor-spend-pull.sh --vendor fly --dry-run
unset ENDPOINT_FLY_MACHINES ENDPOINT_CLERK ENDPOINT_OPENROUTER ENDPOINT_OPENAI

# ── V3: an empty resolver — nonzero exit, ZERO calls ─────────────────────────
for c in "fly-api.sh demo state" "qa-clerk-ban.sh demo user_1 status" "update-model-prices.sh" \
         "vendor-spend-pull.sh --vendor openrouter --dry-run" "vendor-spend-pull.sh --vendor codex --dry-run" \
         "vendor-spend-pull.sh --vendor fly --dry-run" "vendor-spend-pull.sh --dry-run"; do
  # shellcheck disable=SC2086
  run "$T/reg-empty.json" $c; rc=$?
  [ "$rc" != 0 ] && ok || bad "V3 $c: an unresolvable endpoint must exit NONZERO (rc 0; err: $(head -c 300 "$T/err"))"
  [ "$(calls)" = 0 ] && ok || bad "V3 $c: an unresolvable endpoint must make ZERO calls (called: $(urls | tr '\n' ' '))"
done

# ── V4: no vendor host literal left in the four scripts ─────────────────────
L=$(cd "$DIR" && grep -nE 'https://(api\.machines\.dev|api\.clerk\.com|openrouter\.ai|api\.openai\.com)' \
      bin/fly-api.sh bin/qa-clerk-ban.sh bin/vendor-spend-pull.sh bin/update-model-prices.sh)
[ -z "$L" ] && ok || bad "V4: vendor base URL literals remain: $L"

# ── V5: the four knobs, registered the BH-1165 way ───────────────────────────
for kv in "fly-machines|ENDPOINT_FLY_MACHINES|https://api.machines.dev" "clerk|ENDPOINT_CLERK|https://api.clerk.com" \
          "openrouter|ENDPOINT_OPENROUTER|https://openrouter.ai" "openai|ENDPOINT_OPENAI|https://api.openai.com"; do
  IFS='|' read -r svc var def <<<"$kv"
  [ -f "$DIR/catalog/lanes.d/_lib.endpoint-$svc.json" ] && ok || bad "V5: catalog/lanes.d/_lib.endpoint-$svc.json missing"
  jq -e --arg id "endpoint-$svc" --arg v "$var" --arg d "$def" \
    '[.libs[] | select(.id == $id) | .knobs[] | select(.env == $v and .settable == false and .required == true and .default == $d)] | length == 1' \
    "$T/reg.json" >/dev/null && ok || bad "V5: $var must be registered in endpoint-$svc, settable:false, required:true, default $def (got $(jq -c --arg id "endpoint-$svc" '[.libs[]|select(.id==$id)]' "$T/reg.json"))"
done

echo "endpoints-vendor.bh-1941-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
