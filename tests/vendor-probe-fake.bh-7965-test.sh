#!/bin/bash
# tests/vendor-probe-fake.bh-7965-test.sh — BH-7965 (BH-7937.2): the vendor
# proof-call seams bin/lib/vendor/<v>.sh probe, one per vendor, for claude,
# codex, openrouter, fireworks and xai. The key comes on stdin, never argv.
# Exit 0 = proved, 1 = refused, 75 = unreachable, 99 = unimplemented verb.
#
#   V1 HARNESS_VENDOR_FAKE=1: each seam proves its fixture key (0)
#   V2 a bad key is refused (1); a fixture `unreachable` key is 75; a missing
#      fixture is 99; a key that fails the format is 1 with no call
#   V3 an unknown verb exits 99 with `unimplemented: <verb>`
#   V4 decision rule 3 (the classifier) through PATH shims for curl, claude
#      and codex (HARNESS_VENDOR_FAKE unset; the shims are local, 0 network)
#   V5 claude and codex take their model from model_for (the box cache that
#      tests/lib/model-route-stub.sh writes); no route = 75
#   V6 the settings row vendor.<v>.base_url is used only on the fallback's host;
#      a non-https row or another host falls back (the key never leaves the
#      vendor's host); openrouter probes /key, not the public /models
#   V7 no key on any shim's argv, and no key in stdout, stderr or a log
#   V8 the contract suite with no keys prints 25 SKIP lines and exits 0
#   V9 the probe timeout knob: out of range is 1 and no call
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vendor-probe-fake.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

VENDORS="claude codex openrouter fireworks xai"
H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/env" "$H/tests/fixtures"
for f in "$DIR/bin/lib/vendor/_common.sh" "$DIR/bin/lib/vendor/fake.sh" "$DIR/bin/lib/vendor/claude.sh" \
         "$DIR/bin/lib/vendor/codex.sh" "$DIR/bin/lib/vendor/openrouter.sh" "$DIR/bin/lib/vendor/fireworks.sh" \
         "$DIR/bin/lib/vendor/xai.sh" "$DIR/tests/contract/vendor-probe.bh-7965-contract.sh" \
         "$DIR/tests/fixtures/vendor-fake/claude.json" "$DIR/tests/fixtures/vendor-fake/codex.json" \
         "$DIR/tests/fixtures/vendor-fake/openrouter.json" "$DIR/tests/fixtures/vendor-fake/fireworks.json" \
         "$DIR/tests/fixtures/vendor-fake/xai.json"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
for v in $VENDORS; do
  ( cd "$DIR" && scratch_install_closure "bin/lib/vendor/$v.sh" "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/vendor/$v.sh"
done
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/jobs-client.sh"
[ -d "$DIR/tests/fixtures/vendor-fake" ] && cp -r "$DIR/tests/fixtures/vendor-fake" "$H/tests/fixtures/vendor-fake"
export HARNESS="$H" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
unset HARNESS_VENDOR_FAKE HARNESS_VENDOR_FAKE_DIR SECRETS_APPLY_PROBE_TIMEOUT_S

# probe <vendor> <key> [verb] — the key on stdin; rc in RC, output in $T/out, $T/err.
probe() {
  local v="$1" k="$2" verb="${3:-probe}"
  printf '%s' "$k" | "$H/bin/lib/vendor/$v.sh" "$verb" > "$T/out" 2> "$T/err"; RC=$?
  cat "$T/out" "$T/err" >> "$T/all-output"
}
: > "$T/all-output"

# --- the shims (V4-V7): a local curl, claude and codex, never the network ----
SHIM="$T/shim"; mkdir -p "$SHIM"
export SHIM_LOG="$T/shim-argv.log" SHIM_CFG="$T/shim-cfg.log" SHIM_ENV="$T/shim-env.log" SHIM_CALLS="$T/shim-calls.log"
: > "$SHIM_LOG"; : > "$SHIM_CFG"; : > "$SHIM_ENV"; : > "$SHIM_CALLS"
cat > "$SHIM/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$SHIM_LOG"
last="${!#}"
case "$last" in
  http://*/api/settings/*)
    key="${last##*/api/settings/}"
    if [ -s "$SHIM_SETTINGS/$key" ]; then printf '{"setting":{"key":"%s","value":"%s"}}\n200' "$key" "$(cat "$SHIM_SETTINGS/$key")"
    else printf '{"error":"no such setting"}\n404'; fi
    exit 0 ;;
esac
echo curl >> "$SHIM_CALLS"
cfg=$(cat)
printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p' >> "$SHIM_CFG"
grep -q '^header = "Authorization: Bearer ' <<<"$cfg" && echo "auth-header" >> "$SHIM_ENV"
printf '%s' "${SHIM_CODE:-200}"
exit "${SHIM_RC:-0}"
EOF
for cli in claude codex; do
  cat > "$SHIM/$cli" <<'EOF'
#!/bin/bash
me=$(basename "$0")
printf '%s %s\n' "$me" "$*" >> "$SHIM_LOG"
echo "$me" >> "$SHIM_CALLS"
in=$(cat)
[ "$in" = ping ] && echo "$me stdin=ping" >> "$SHIM_ENV"
if [ "$me" = claude ]; then
  [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$SHIM_WANT_KEY" ] && echo "claude token=match" >> "$SHIM_ENV"
  [ -z "${ANTHROPIC_API_KEY+set}" ] && echo "claude anthropic=unset" >> "$SHIM_ENV"
else
  [ "${CODEX_API_KEY:-}" = "$SHIM_WANT_KEY" ] && echo "codex token=match" >> "$SHIM_ENV"
fi
[ "$PWD" != "$SHIM_HOME_CWD" ] && echo "$me cwd=temp" >> "$SHIM_ENV"
printf '%s' "${SHIM_OUT:-}"
printf '%s' "${SHIM_ERR:-}" >&2
exit "${SHIM_RC:-0}"
EOF
done
chmod +x "$SHIM/curl" "$SHIM/claude" "$SHIM/codex"
export SHIM_SETTINGS="$T/settings"; mkdir -p "$SHIM_SETTINGS"
export SHIM_HOME_CWD="$PWD"

echo "V1: the fake proves each fixture key"
for v in $VENDORS; do
  : > "$SHIM_CALLS"
  HARNESS_VENDOR_FAKE=1 PATH="$SHIM:$PATH" probe "$v" "tok-fixture-$v-good"
  [ "$RC" = 0 ] && ok "V1 $v good key: 0" || bad "V1 $v good key: rc $RC ($(cat "$T/err"))"
  [ ! -s "$SHIM_CALLS" ] && ok "V1 $v: 0 vendor calls in fake mode" || bad "V1 $v: fake mode called $(sort "$SHIM_CALLS" | uniq -c | tr '\n' ' ')"
done

echo "V2: the fake refuses, answers unreachable, and a missing fixture is 99"
for v in $VENDORS; do
  HARNESS_VENDOR_FAKE=1 probe "$v" "tok-fixture-$v-bad"
  [ "$RC" = 1 ] && ok "V2 $v bad key: 1" || bad "V2 $v bad key: rc $RC"
  HARNESS_VENDOR_FAKE=1 probe "$v" "tok-fixture-$v-down"
  [ "$RC" = 75 ] && ok "V2 $v unreachable key: 75" || bad "V2 $v unreachable key: rc $RC"
  # Another vendor's good key is not this vendor's proof.
  HARNESS_VENDOR_FAKE=1 probe "$v" "tok-fixture-other-good"
  [ "$RC" = 1 ] && ok "V2 $v foreign key: 1" || bad "V2 $v foreign key: rc $RC"
done
mkdir -p "$T/empty-fixtures"
HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/empty-fixtures" probe xai tok-fixture-xai-good
[ "$RC" = 99 ] && ok "V2 missing fixture: 99" || bad "V2 missing fixture: rc $RC"
printf 'not json' > "$T/empty-fixtures/xai.json"
HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/empty-fixtures" probe xai tok-fixture-xai-good
[ "$RC" = 99 ] && ok "V2 unreadable fixture: 99" || bad "V2 unreadable fixture: rc $RC"
HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake" probe codex tok-fixture-codex-good
[ "$RC" = 0 ] && ok "V2 HARNESS_VENDOR_FAKE_DIR is read" || bad "V2 HARNESS_VENDOR_FAKE_DIR: rc $RC"
# The key format: 8..512 of [A-Za-z0-9._-], else 1 before any call (fake or real).
: > "$SHIM_CALLS"
for k in "" "short7x" "tok fixture spaced" 'tok-fixture-$(id)' "tok-fixture-\"q" "$(printf 'a%.0s' $(seq 1 513))"; do
  PATH="$SHIM:$PATH" probe openrouter "$k"
  [ "$RC" = 1 ] && ok "V2 key format refused (${#k} chars)" || bad "V2 key format (${#k} chars): rc $RC"
  HARNESS_VENDOR_FAKE=1 probe claude "$k"
  [ "$RC" = 1 ] && ok "V2 fake mode: key format refused (${#k} chars)" || bad "V2 fake key format (${#k} chars): rc $RC"
done
[ ! -s "$SHIM_CALLS" ] && ok "V2 a refused key format makes no call" || bad "V2 refused key format still called: $(tr '\n' ' ' < "$SHIM_CALLS")"
K512="tok-fixture-$(printf 'b%.0s' $(seq 1 500))"
SHIM_CODE=200 PATH="$SHIM:$PATH" probe openrouter "$K512"
[ "${#K512}" = 512 ] && [ "$RC" = 0 ] && ok "V2 a 512-char key is accepted" || bad "V2 512-char key: len ${#K512} rc $RC"
SHIM_CODE=200 PATH="$SHIM:$PATH" probe openrouter "tok-fx-8"
[ "$RC" = 0 ] && ok "V2 an 8-char key is accepted" || bad "V2 8-char key: rc $RC"

echo "V3: an unknown verb"
for v in $VENDORS; do
  probe "$v" tok-fixture-x-good frob
  [ "$RC" = 99 ] && grep -q '^unimplemented: frob$' "$T/err" && ok "V3 $v frob: 99 unimplemented" \
    || bad "V3 $v frob: rc $RC err=$(cat "$T/err")"
done
printf '%s' tok-fixture-x-good | "$H/bin/lib/vendor/xai.sh" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 99 ] && ok "V3 no verb: 99" || bad "V3 no verb: rc $RC"
# fake.sh takes a vendor name; an unknown one is 99, never a proof.
printf '%s' tok-fixture-frob-good | HARNESS_VENDOR_FAKE_DIR="$H/tests/fixtures/vendor-fake" "$H/bin/lib/vendor/fake.sh" frob 2>/dev/null; RC=$?
[ "$RC" = 99 ] && ok "V3 fake.sh unknown vendor: 99" || bad "V3 fake.sh unknown vendor: rc $RC"

echo "V4: decision rule 3, the classifier"
# API vendors: 200 = 0; 400 401 403 404 = 1; 429 5xx 000 = 75.
for v in openrouter fireworks xai; do
  for row in 200:0:0 401:0:1 403:0:1 404:0:1 400:0:1 429:0:75 500:0:75 503:0:75 000:7:75 000:28:75; do
    code="${row%%:*}"; rest="${row#*:}"; crc="${rest%%:*}"; want="${rest#*:}"
    : > "$SHIM_CALLS"
    SHIM_CODE="$code" SHIM_RC="$crc" PATH="$SHIM:$PATH" probe "$v" "tok-fixture-$v-real"
    [ "$RC" = "$want" ] && ok "V4 $v http $code (curl rc $crc) -> $want" || bad "V4 $v http $code (curl rc $crc): want $want got $RC"
    [ "$(grep -c '^curl$' "$SHIM_CALLS")" = 1 ] || bad "V4 $v http $code: want ONE curl call, got $(grep -c '^curl$' "$SHIM_CALLS")"
  done
  grep -q 'auth-header' "$SHIM_ENV" && ok "V4 $v: the bearer header rides in the curl config" || bad "V4 $v: no bearer header in the curl config"
  : > "$SHIM_ENV"
done
# claude/codex: the box cache gives a model route (no worker: JOBS_URL is empty).
mrs_cache_1523 "$H"
for cli in claude codex; do
  export SHIM_WANT_KEY="tok-fixture-$cli-real"
  for row in "0|pong||0" "0|||1" "124|||75" "1||Error: 401 Unauthorized|1" "1||Invalid API key provided|1" \
             "1||Not authenticated. Please run /login|1" "1||getaddrinfo ENOTFOUND api.example.test|75" \
             "1||connect ECONNREFUSED 192.0.2.1:443|75" "1||API Error: 529 overloaded|75" "1||network error|75" \
             "1||something else broke|1" "2|partial out||1"; do
    IFS='|' read -r rc out err want <<<"$row"
    : > "$SHIM_ENV"
    SHIM_RC="$rc" SHIM_OUT="$out" SHIM_ERR="$err" PATH="$SHIM:$PATH" probe "$cli" "$SHIM_WANT_KEY"
    [ "$RC" = "$want" ] && ok "V4 $cli rc=$rc out='$out' err='$err' -> $want" || bad "V4 $cli rc=$rc out='$out' err='$err': want $want got $RC"
  done
  SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe "$cli" "$SHIM_WANT_KEY"
  grep -q "^$cli token=match$" "$SHIM_ENV" && ok "V4 $cli: the key rides in the env" || bad "V4 $cli: the key is not in the env"
  grep -q "^$cli stdin=ping$" "$SHIM_ENV" && ok "V4 $cli: the prompt rides on stdin" || bad "V4 $cli: no ping on stdin"
  grep -q "^$cli cwd=temp$" "$SHIM_ENV" && ok "V4 $cli: runs in a temp cwd" || bad "V4 $cli: not in a temp cwd"
done
SHIM_WANT_KEY=tok-fixture-claude-real
: > "$SHIM_ENV"
ANTHROPIC_API_KEY=tok-fixture-anthropic SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe claude "$SHIM_WANT_KEY"
grep -q '^claude anthropic=unset$' "$SHIM_ENV" && ok "V4 claude: ANTHROPIC_API_KEY is unset for the call" || bad "V4 claude: ANTHROPIC_API_KEY reached the call"

echo "V5: the model comes from model_for"
WANT_CLAUDE=$(awk -F'\t' '$1==0{print $2}' "$H/state/model-routes/claude.ladder.tsv")
WANT_CODEX=$(awk -F'\t' '$1==0{print $2}' "$H/state/model-routes/codex.default.tsv")
[ -n "$WANT_CLAUDE" ] && [ -n "$WANT_CODEX" ] || bad "V5 setup: no cached route"
: > "$SHIM_LOG"
SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe claude tok-fixture-claude-real
grep -qx -- "claude -p --model $WANT_CLAUDE" "$SHIM_LOG" && ok "V5 claude -p --model <claude.ladder rung 0>" || bad "V5 claude argv: $(cat "$SHIM_LOG")"
: > "$SHIM_LOG"
SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe codex tok-fixture-codex-real
grep -qx -- "codex exec -m $WANT_CODEX --skip-git-repo-check -" "$SHIM_LOG" && ok "V5 codex exec -m <codex.default> --skip-git-repo-check -" || bad "V5 codex argv: $(cat "$SHIM_LOG")"
# A second model in the cache moves the probe with it (no literal in the seam).
printf '0\tfixture-model-x\tclaude\n' > "$H/state/model-routes/claude.ladder.tsv"
: > "$SHIM_LOG"
SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe claude tok-fixture-claude-real
grep -qx -- "claude -p --model fixture-model-x" "$SHIM_LOG" && ok "V5 a changed route changes the model" || bad "V5 changed route argv: $(cat "$SHIM_LOG")"
rm -f "$H/state/model-routes/claude.ladder.tsv" "$H/state/model-routes/codex.default.tsv"
: > "$SHIM_CALLS"
for cli in claude codex; do
  SHIM_RC=0 SHIM_OUT=pong PATH="$SHIM:$PATH" probe "$cli" "tok-fixture-$cli-real"
  [ "$RC" = 75 ] && ok "V5 $cli: no model route -> 75" || bad "V5 $cli no route: rc $RC"
done
[ ! -s "$SHIM_CALLS" ] && ok "V5 no route: the CLI is never run" || bad "V5 no route still ran: $(tr '\n' ' ' < "$SHIM_CALLS")"
mrs_cache_1523 "$H"

echo "V6: the base URL settings row"
declare -A DEF=([openrouter]=https://openrouter.ai/api/v1/key [fireworks]=https://api.fireworks.ai/inference/v1/models [xai]=https://api.x.ai/v1/models)
for v in openrouter fireworks xai; do
  : > "$SHIM_CFG"; rm -f "$SHIM_SETTINGS"/*
  SHIM_CODE=200 PATH="$SHIM:$PATH" probe "$v" "tok-fixture-$v-real"
  [ "$(cat "$SHIM_CFG")" = "${DEF[$v]}" ] && ok "V6 $v no worker: the default ${DEF[$v]}" || bad "V6 $v default: $(cat "$SHIM_CFG")"
done
for row in "https://api.x.ai/v2|https://api.x.ai/v2/models" "https://API.X.AI/v1/|https://API.X.AI/v1/models" \
           "https://api.x.ai|https://api.x.ai/models" \
           "https://api.example.test/v1|${DEF[xai]}" "https://api.x.ai.example.test/v1|${DEF[xai]}" \
           "https://x.ai/v1|${DEF[xai]}" "http://api.x.ai/v1|${DEF[xai]}" "http://x|${DEF[xai]}" \
           "https://api.x.ai/v1?x=1|${DEF[xai]}" "https://api.x.ai@api.example.test/v1|${DEF[xai]}" \
           "https://api.x.ai:8443/v1|${DEF[xai]}" "https://|${DEF[xai]}"; do
  val="${row%%|*}"; want="${row#*|}"
  printf '%s' "$val" > "$SHIM_SETTINGS/vendor.xai.base_url"
  : > "$SHIM_CFG"
  JOBS_URL=http://jobs.fixture.invalid HARNESS_SECRET=tok-fixture-harness SHIM_CODE=200 PATH="$SHIM:$PATH" probe xai tok-fixture-xai-real
  [ "$RC" = 0 ] && [ "$(cat "$SHIM_CFG")" = "$want" ] && ok "V6 row '$val' -> $want" || bad "V6 row '$val': rc $RC url $(cat "$SHIM_CFG")"
done
printf '%s' "https://attacker.example.test/v1" > "$SHIM_SETTINGS/vendor.openrouter.base_url"
: > "$SHIM_CFG"
JOBS_URL=http://jobs.fixture.invalid HARNESS_SECRET=tok-fixture-harness SHIM_CODE=200 PATH="$SHIM:$PATH" probe openrouter tok-fixture-openrouter-real
[ "$(cat "$SHIM_CFG")" = "${DEF[openrouter]}" ] && ok "V6 openrouter: a row on another host is refused, the key stays on openrouter.ai" || bad "V6 openrouter foreign row: $(cat "$SHIM_CFG")"
rm -f "$SHIM_SETTINGS"/*
: > "$SHIM_CFG"
JOBS_URL=http://jobs.fixture.invalid HARNESS_SECRET=tok-fixture-harness SHIM_CODE=200 PATH="$SHIM:$PATH" probe xai tok-fixture-xai-real
[ "$(cat "$SHIM_CFG")" = "${DEF[xai]}" ] && ok "V6 worker with no row: the default" || bad "V6 no row: $(cat "$SHIM_CFG")"

echo "V7: no key on argv, stdout, stderr or a log"
leak=0
for v in $VENDORS; do
  for k in "tok-fixture-$v-real" "tok-fixture-$v-good" "tok-fixture-$v-bad" "$K512"; do
    if grep -qF -- "$k" "$SHIM_LOG" 2>/dev/null; then leak=1; bad "V7 $k on a shim argv"; fi
    if grep -qF -- "$k" "$T/all-output"; then leak=1; bad "V7 $k in seam output"; fi
    if grep -rqF -- "$k" "$H/logs" 2>/dev/null; then leak=1; bad "V7 $k in $H/logs"; fi
  done
done
[ -s "$SHIM_LOG" ] || { leak=1; bad "V7 the shim argv log is empty (the check read nothing)"; }
[ "$leak" = 0 ] && ok "V7 no key in any argv, output or log"

echo "V8: the contract suite with no keys"
OUT=$(env -u VENDOR_CONTRACT_CLAUDE_KEY -u VENDOR_CONTRACT_CODEX_KEY -u VENDOR_CONTRACT_OPENROUTER_KEY \
      -u VENDOR_CONTRACT_FIREWORKS_KEY -u VENDOR_CONTRACT_XAI_KEY PATH="$SHIM:$PATH" \
      bash "$DIR/tests/contract/vendor-probe.bh-7965-contract.sh" 2>&1); RC=$?
NSKIP=$(grep -c '^SKIP ' <<<"$OUT")
[ "$RC" = 0 ] && [ "$NSKIP" = 25 ] && ok "V8 25 SKIP lines, rc 0" || bad "V8 contract: rc $RC skips $NSKIP"
grep -q '::warning::' <<<"$OUT" && bad "V8 a missing key alerted" || ok "V8 a missing key is not an alert"

echo "V9: the probe timeout knob"
: > "$SHIM_CALLS"
for bad_t in 4 301 abc ""; do
  [ -z "$bad_t" ] && continue
  SECRETS_APPLY_PROBE_TIMEOUT_S="$bad_t" SHIM_CODE=200 PATH="$SHIM:$PATH" probe xai tok-fixture-xai-real
  [ "$RC" = 1 ] && ok "V9 timeout '$bad_t' -> 1" || bad "V9 timeout '$bad_t': rc $RC"
done
[ ! -s "$SHIM_CALLS" ] && ok "V9 a bad knob makes no call" || bad "V9 bad knob still called"
: > "$SHIM_LOG"
SECRETS_APPLY_PROBE_TIMEOUT_S=7 SHIM_CODE=200 PATH="$SHIM:$PATH" probe xai tok-fixture-xai-real
[ "$RC" = 0 ] && grep -q -- '-m 7 ' "$SHIM_LOG" && ok "V9 timeout 7 reaches curl -m 7" || bad "V9 timeout 7: rc $RC argv $(cat "$SHIM_LOG")"

echo "vendor-probe-fake.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
