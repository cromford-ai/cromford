#!/bin/bash
# tests/cred-probe-contract.bh-2549-test.sh — the BH-2549 contract slice
# (BH-2558): bin/lib/cred-probe.sh's four signatures and the four endpoint
# registry rows the sibling slices resolve through endpoint_url.
#
#   C1 sourcing the lib prints nothing (stdout or stderr) and defines all four;
#   C2 the cred_probe stub prints exactly NO_ENDPOINT, rc 4;
#   C3 cred_account_fp claude over a fixture .credentials.json prints the first
#      16 hex of sha256(token), never the token itself;
#   C4 CLAUDE_CODE_OAUTH_TOKEN wins over the file; openrouter hashes its key;
#   C5 no credential (and an unknown runner): empty stdout, rc 1;
#   C6 with no coordination DB configured the claim is rc 2 (do NOT spend)
#      and the record rc 1, both silent on stdout (BH-2559 made them real);
#   C7 endpoint_url resolves xai, anthropic, anthropic-oauth, fireworks from
#      the registry defaults;
#   C8 the CRED_PROBE_LIB override shape resolves an injected stub lib, and
#      the default path reaches the real lib (no credential -> INCONCLUSIVE);
#   C9 the lib carries no URL literal (they live in the registry only).
# Run from anywhere: tests/cred-probe-contract.bh-2549-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/cred-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
sha16() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# Every credential the lib reads, so the box's own env never leaks in.
CLEAN=(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CONFIG_DIR -u CODEX_API_KEY -u OPENAI_API_KEY
       -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u XAI_API_KEY -u GROK_CODE_XAI_API_KEY)
fp() {  # fp <home> <runner> [VAR=val ...] -> stdout of cred_account_fp; rc in $FP_RC
  local home="$1" runner="$2"; shift 2
  FP_OUT=$("${CLEAN[@]}" HOME="$home" "$@" bash -c '. "$1" && cred_account_fp "$2"' _ "$LIB" "$runner" 2>&1)
  FP_RC=$?
}

# C1
[ -f "$LIB" ] || bad "C1 $LIB missing"
out=$(bash -c '. "$1" || echo SOURCE_FAILED; for f in cred_probe cred_account_fp cred_inference_claim cred_inference_record; do declare -F $f >/dev/null || echo MISSING:$f; done' _ "$LIB" 2>&1)
[ -z "$out" ] && ok || bad "C1 sourcing printed or missed something: $out"

# C2
out=$(bash -c '. "$1"; cred_probe x' _ "$LIB" 2>&1); rc=$?
[ "$out" = "NO_ENDPOINT" ] && [ "$rc" -eq 4 ] && ok || bad "C2 cred_probe x -> '$out' rc=$rc (want NO_ENDPOINT rc 4)"

# C3
SECRET=sk-ant-oat01-FIXTURESECRET
mkdir -p "$T/home/.claude" "$T/empty"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET" > "$T/home/.claude/.credentials.json"
fp "$T/home" claude
if [ "$FP_RC" -eq 0 ] && [[ "$FP_OUT" =~ ^[0-9a-f]{16}$ ]] && [[ "$FP_OUT" != *FIXTURESECRET* ]] \
   && [ "$FP_OUT" = "$(sha16 "$SECRET")" ]; then ok
else bad "C3 claude fp from file -> '$FP_OUT' rc=$FP_RC (want $(sha16 "$SECRET"))"; fi

# C4
fp "$T/home" claude CLAUDE_CODE_OAUTH_TOKEN=tokA
[ "$FP_RC" -eq 0 ] && [ "$FP_OUT" = "$(sha16 tokA)" ] && ok || bad "C4 env token should win: '$FP_OUT' rc=$FP_RC"
fp "$T/empty" openrouter OPENROUTER_API_KEY=sk-or-x
[ "$FP_RC" -eq 0 ] && [ "$FP_OUT" = "$(sha16 sk-or-x)" ] && ok || bad "C4 openrouter fp: '$FP_OUT' rc=$FP_RC"
fp "$T/empty" grok GROK_CODE_XAI_API_KEY=xk-2
[ "$FP_RC" -eq 0 ] && [ "$FP_OUT" = "$(sha16 xk-2)" ] && ok || bad "C4 grok fallback key fp: '$FP_OUT' rc=$FP_RC"

# C5
for r in claude grok codex fireworks nosuchrunner; do
  fp "$T/empty" "$r"
  [ "$FP_RC" -eq 1 ] && [ -z "$FP_OUT" ] && ok || bad "C5 $r with no credential -> '$FP_OUT' rc=$FP_RC (want empty, rc 1)"
done
fp "$T/home" nosuchrunner CLAUDE_CODE_OAUTH_TOKEN=tokA
[ "$FP_RC" -eq 1 ] && [ -z "$FP_OUT" ] && ok || bad "C5 unknown runner -> '$FP_OUT' rc=$FP_RC"

# C6
out=$(env JOBS_URL= HARNESS="$T/empty" bash -c '. "$1"; cred_inference_claim claude abc; echo "c=$?"; cred_inference_record claude abc ok; echo "r=$?"' _ "$LIB" 2>/dev/null)
[ "$out" = "$(printf 'c=2\nr=1')" ] && ok || bad "C6 claim/record with no coordination DB -> '$out' (want c=2 r=1)"

# C7
for pair in xai:https://api.x.ai anthropic:https://api.anthropic.com \
            anthropic-oauth:https://console.anthropic.com fireworks:https://api.fireworks.ai; do
  svc=${pair%%:*}; want=${pair#*:}
  out=$(cd "$DIR" && env -u "ENDPOINT_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')" HARNESS="$DIR" \
        bash -c '. bin/lib/endpoints.sh; endpoint_url "$1"' _ "$svc" 2>/dev/null)
  [ "$out" = "$want" ] && ok || bad "C7 endpoint_url $svc -> '$out' (want $want)"
done

# C8
printf 'cred_probe(){ echo ALIVE stub; }\n' > "$T/stub.sh"
out=$(CRED_PROBE_LIB="$T/stub.sh" HARNESS="$DIR" bash -c '. "${CRED_PROBE_LIB:-$HARNESS/bin/lib/cred-probe.sh}"; cred_probe claude' 2>&1)
[ "$out" = "ALIVE stub" ] && ok || bad "C8 CRED_PROBE_LIB override -> '$out'"
out=$("${CLEAN[@]}" -u CRED_PROBE_LIB HOME="$T/empty" HARNESS="$DIR" bash -c '. "${CRED_PROBE_LIB:-$HARNESS/bin/lib/cred-probe.sh}"; cred_probe claude' 2>&1)
[ "$out" = "INCONCLUSIVE no credential" ] && ok || bad "C8 default path -> '$out'"

# C9
n=$(grep -cE 'https?://' "$LIB" 2>/dev/null); n=${n:-missing}
[ "$n" = "0" ] && ok || bad "C9 URL literals in the lib: $n"

echo "cred-probe-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
