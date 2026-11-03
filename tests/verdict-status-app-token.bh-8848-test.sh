#!/bin/bash
# tests/verdict-status-app-token.bh-8848-test.sh — BH-8848: vs_publish posted
# the lead-verdict / prequeue-verdict / landing-path status on a non-App token
# when the App mint failed, and logged a bare `(HTTP 403)`. Pinned here, driven
# through the real bin/lib/verdict-status.sh, gh-rest.sh, gh-rest-ledger.sh and
# gh-app-auth.sh against a stub `gh` (GitHub) and a stub bin/gh-token.sh (the
# minter). No network: 0 vendor calls.
#   A  armed box: POST only on a ghs_ App token; one re-mint, then one
#      "no App token" line, rc 1 and no POST. Unarmed box: unchanged.
#   M  gh_rest sets GH_REST_MESSAGE to GitHub's .message on a non-2xx, clears it.
#   K  the failure line names the token kind (never the value) and the message.
#   E  the failure line is one line; `head -1` keeps prefix, kind and message.
#   R  a rate-limit 403/429 with Retry-After 1..VS_RETRY_AFTER_MAX_S is retried
#      once; nothing else is.
#   G  no fixture token value reaches stderr or logs/.
#   S  a bad argument is rc 2 with no mint and no POST.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/verdict-status-app-token.bh-8848-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-8848
SHA=cccccccc33333333333333333333333333333333
TOK_APP=ghs_fixtureAppToken8848
TOK_PAT=ghp_fixturePatToken8848
TOK_FG=github_pat_fixtureFineGrained8848
TOK_INH=ghp_inheritedToken8848
mkdir -p "$T/fakebin" "$T/tmp" "$T/err"

# The stub gh. Every call appends "<kind> <args>" to $G/calls (a kind, never
# the token). The Nth call prints $G/resp.N (a full HTTP answer), else a 201.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
G="${STUB_G:?}"
case "${GH_TOKEN:-}" in ghs_*) k=app ;; ghp_*|github_pat_*) k=pat ;; '') k=none ;; *) k=other ;; esac
n=$(( $(cat "$G/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$G/n"
printf '%s %s\n' "$k" "$*" >> "$G/calls"
if [ -f "$G/resp.$n" ]; then cat "$G/resp.$n"; else printf 'HTTP/1.1 201 Created\r\nServer: stub\r\n\r\n{"id":1}'; fi
exit 0
EOF
chmod +x "$T/fakebin/gh"

# The scratch harness: the four libs, and (armed only) the App env file and a
# stub minter that prints $MINTDIR/mint.N (or mint) and counts its calls; a
# file holding `RC1` makes that call rc 1 with no output.
mkh() { # mkh <dir> <armed 0|1>
  local h="$1"
  mkdir -p "$h/bin/lib" "$h/env" "$h/logs" "$h/state"
  scratch_install_closure bin/lib/verdict-status.sh "$h" >/dev/null || { echo "closure install of bin/lib/verdict-status.sh failed"; exit 1; }
  for f in verdict-status gh-rest gh-rest-ledger gh-app-auth; do [ -r "$h/bin/lib/$f.sh" ] || { echo "closure lacks bin/lib/$f.sh"; exit 1; }; done
  cat > "$h/bin/gh-token.sh" <<'EOF'
#!/bin/bash
D="${MINTDIR:?}"
n=$(( $(cat "$D/mints" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/mints"
# The identity this call ran under, as a marker: the inherited one or not.
case "${GH_TOKEN:-}" in ghp_inherited*) echo "$n inherited" ;; *) echo "$n other" ;; esac >> "$D/env"
f="$D/mint.$n"; [ -f "$f" ] || f="$D/mint"
v=$(cat "$f" 2>/dev/null)
[ "$v" = RC1 ] && exit 1
printf '%s\n' "$v"
EOF
  chmod +x "$h/bin/gh-token.sh"
  [ "$2" = 1 ] && printf 'GH_APP_ID=1\n' > "$h/env/github-app.env"
  return 0
}

export PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp"
unset LEAD_VERDICT_CONTEXT GH_TOKEN VS_RETRY_AFTER_MAX_S GH_APP_TOKENS

CASE=""
# setup <id> <armed 0|1> — a fresh harness, stub dir and minter dir per case.
setup() {
  CASE="$1"; G="$T/c-$1/gh"; MD="$T/c-$1/mint"; H="$T/c-$1/h"
  mkdir -p "$G" "$MD"; mkh "$H" "$2"
}
resp() { # resp <n> <status> <body> [retry-after]
  { printf 'HTTP/1.1 %s Stub\r\nServer: stub\r\n' "$2"
    [ -n "${4:-}" ] && printf 'Retry-After: %s\r\n' "$4"
    printf '\r\n%s' "$3"; } > "$G/resp.$1"
}
# vsp [env assignments...] -- <vs_publish args...>: rc in RC, stderr in $ERR.
vsp() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ERR="$T/err/$CASE"
  env ${envs[@]+"${envs[@]}"} STUB_G="$G" MINTDIR="$MD" HARNESS="$H" \
    bash -c '. "$HARNESS/bin/lib/verdict-status.sh"
             _vs_sleep() { printf "%s\n" "$1" >> "$STUB_G/slept"; }
             vs_publish "$@"' vsp "$@" 2>"$ERR"
  RC=$?
}
posts() { cat "$G/calls" 2>/dev/null | grep -c -- '-X POST repos/.*/statuses/'; }
mints() { cat "$MD/mints" 2>/dev/null || echo 0; }
lines() { cat "$ERR" 2>/dev/null | grep -c .; }

# ============================================================================
# A. App-only identity on an armed box
# ============================================================================
setup A1 1; echo "$TOK_APP" > "$MD/mint"
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && grep -q '^app .*statuses' "$G/calls" && ok \
  || bad "A1 armed + ghs_ mint: one POST on app, rc 0 (rc $RC, posts $(posts), err $(cat "$ERR"))"

setup A2 1; echo "$TOK_PAT" > "$MD/mint.1"; echo "$TOK_APP" > "$MD/mint.2"
vsp GH_TOKEN="$TOK_INH" -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && grep -q '^app .*statuses' "$G/calls" && ! grep -q 'no App token' "$ERR" && ok \
  || bad "A2 PAT then ghs_: one POST on app, rc 0 (rc $RC, posts $(posts), calls $(cat "$G/calls" 2>/dev/null), err $(cat "$ERR"))"

setup A3 1; echo "$TOK_PAT" > "$MD/mint"
vsp GH_TOKEN="$TOK_INH" -- "$SLUG" "$SHA" success "MERGE"
WANT="vs_publish: no App token for $SLUG; lead-verdict=success NOT published on $SLUG@${SHA:0:12}"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [ "$(mints)" = 2 ] && [ "$(lines)" = 1 ] && [ "$(cat "$ERR")" = "$WANT" ] && ok \
  || bad "A3 armed + PAT twice: 0 POST, 2 mints, rc 1, one 'no App token' line (rc $RC, posts $(posts), mints $(mints), err '$(cat "$ERR")')"
grep -qx '2 inherited' "$MD/env" 2>/dev/null && ok \
  || bad "A3 the re-mint runs with the caller's own token back, not the first mint's PAT: $(cat "$MD/env" 2>/dev/null)"

setup A4 1; echo RC1 > "$MD/mint"
vsp GH_TOKEN="$TOK_INH" -- "$SLUG" "$SHA" failure "BLOCK"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [ "$(mints)" = 2 ] && [ "$(lines)" = 1 ] && grep -q "^vs_publish: no App token for $SLUG; lead-verdict=failure NOT published" "$ERR" && ok \
  || bad "A4 armed + mint rc 1 twice: 0 POST, rc 1 (rc $RC, posts $(posts), mints $(mints), err '$(cat "$ERR")')"

setup A5 1; echo "x$TOK_APP" > "$MD/mint"
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && grep -q 'no App token' "$ERR" && ok \
  || bad "A5 xghs_ is not an App token (rc $RC, posts $(posts), err '$(cat "$ERR")')"

setup A5b 1; echo "" > "$MD/mint"
vsp GH_TOKEN="$TOK_INH" -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [ "$(mints)" = 2 ] && ok \
  || bad "A5b armed + empty mint: 0 POST, 2 mints (rc $RC, posts $(posts), mints $(mints))"

setup A6 1; echo "$TOK_APP" > "$MD/mint"
vsp GH_APP_TOKENS=0 GH_TOKEN="$TOK_PAT" -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && grep -q '^pat .*statuses' "$G/calls" && [ "$(mints)" = 0 ] && ok \
  || bad "A6 unarmed (GH_APP_TOKENS=0) + PAT: one POST on the PAT, no mint (rc $RC, posts $(posts), mints $(mints))"

setup A6b 0
vsp GH_TOKEN="$TOK_PAT" -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && grep -q '^pat .*statuses' "$G/calls" && ok \
  || bad "A6b unarmed (no env file) + PAT: one POST on the PAT (rc $RC, posts $(posts))"

# A7: a caller's gh_auth_for stub with no gh_auth_armed (landing-path suite shape).
setup A7 1; rm -f "$H/bin/lib/gh-app-auth.sh"
ERR="$T/err/A7"
STUB_G="$G" MINTDIR="$MD" HARNESS="$H" GH_TOKEN="$TOK_PAT" bash -c '
  gh_auth_for() { return 0; }
  . "$HARNESS/bin/lib/verdict-status.sh"
  vs_publish "$@"' vsp "$SLUG" "$SHA" success MERGE 2>"$ERR"; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok \
  || bad "A7 a gh_auth_for stub with no gh_auth_armed posts as today (rc $RC, posts $(posts), err '$(cat "$ERR")')"

# ============================================================================
# M. GH_REST_MESSAGE in gh_rest
# ============================================================================
setup M 0
LONG=$(printf 'line one\nline two %s' "$(printf 'y%.0s' {1..500})")
resp 1 403 '{"message":"Resource not accessible by integration","documentation_url":"x"}'
resp 2 404 '{"message":"Not Found"}'
resp 4 403 'not json at all'
resp 5 422 "$(jq -cn --arg m "$LONG" '{message:$m}')"
OUT=$(STUB_G="$G" HARNESS="$H" bash -c '
  . "$HARNESS/bin/lib/gh-rest.sh"
  gh_rest POST repos/a/b/statuses/x >/dev/null; printf "1[%s]\n" "${GH_REST_MESSAGE-UNSET}"
  gh_rest GET repos/a/b/pulls/1 >/dev/null; printf "2[%s]\n" "${GH_REST_MESSAGE-UNSET}"
  gh_rest GET repos/a/b/pulls/2 >/dev/null; printf "3[%s]\n" "${GH_REST_MESSAGE-UNSET}"
  gh_rest POST repos/a/b/statuses/x >/dev/null; printf "4[%s]\n" "${GH_REST_MESSAGE-UNSET}"
  gh_rest POST repos/a/b/statuses/x >/dev/null; printf "5[%s]\n" "${GH_REST_MESSAGE-UNSET}"' 2>/dev/null)
grep -qx '1\[Resource not accessible by integration\]' <<<"$OUT" && ok || bad "M1 a 403 JSON body sets GH_REST_MESSAGE: $OUT"
grep -qx '2\[\]' <<<"$OUT" && grep -qx '3\[\]' <<<"$OUT" && ok || bad "M2/M3 a 404 and a later 2xx leave GH_REST_MESSAGE empty: $OUT"
grep -qx '4\[\]' <<<"$OUT" && ok || bad "M4 a non-JSON body gives an empty GH_REST_MESSAGE: $OUT"
L5=$(grep '^5\[' <<<"$OUT"); M5=${L5#5[}; M5=${M5%]}
[ "$(grep -c . <<<"$OUT")" = 5 ] && [ "${#M5}" = 200 ] && case "$M5" in "line one line two y"*) true ;; *) false ;; esac && ok \
  || bad "M4 a 500-char multi-line message is one line of 200 chars (len ${#M5}): $OUT"

# ============================================================================
# K / E. token kind and message on the failure line
# ============================================================================
setup K1 1; echo "$TOK_APP" > "$MD/mint"
resp 1 403 '{"message":"Resource not accessible by integration"}'
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(lines)" = 1 ] && grep -qF "NOT published on $SLUG@${SHA:0:12} (HTTP 403" "$ERR" \
  && grep -qF 'token=app' "$ERR" && grep -qF 'GitHub: Resource not accessible by integration' "$ERR" && ok \
  || bad "K1 a 403 line names token=app and GitHub's message (rc $RC, err '$(cat "$ERR")')"
E1=$(head -1 "$ERR")
grep -qF "NOT published on $SLUG@${SHA:0:12} (HTTP 403" <<<"$E1" && grep -qF 'token=app' <<<"$E1" && grep -qF 'GitHub: Resource' <<<"$E1" && ok \
  || bad "E1 head -1 keeps the prefix, kind and message: '$E1'"
setup K2 0; resp 1 403 '{"message":"Must have admin rights"}'
vsp GH_TOKEN="$TOK_PAT" -- "$SLUG" "$SHA" success "MERGE"
grep -qF 'token=pat' "$ERR" && ok || bad "K2 ghp_ is token=pat: '$(cat "$ERR")'"
setup K3 0; resp 1 403 '{"message":"Must have admin rights"}'
vsp GH_TOKEN="$TOK_FG" -- "$SLUG" "$SHA" success "MERGE"
grep -qF 'token=pat' "$ERR" && ok || bad "K3 github_pat_ is token=pat: '$(cat "$ERR")'"
setup K4 0; resp 1 422 '{"message":"Validation Failed"}'
vsp -- "$SLUG" "$SHA" success "MERGE"
grep -qF "NOT published on $SLUG@${SHA:0:12} (HTTP 422; token=gh-auth; GitHub: Validation Failed)" "$ERR" && ok \
  || bad "K4 an empty GH_TOKEN is token=gh-auth: '$(cat "$ERR")'"
setup K5 0; resp 1 403 '{"message":"x"}'
vsp GH_TOKEN=gho_fixtureOauth8848 -- "$SLUG" "$SHA" success "MERGE"
grep -qF 'token=other' "$ERR" && ok || bad "K5 gho_ is token=other: '$(cat "$ERR")'"

# ============================================================================
# R. one bounded retry on a secondary rate limit
# ============================================================================
RLMSG='You have exceeded a secondary rate limit. Please wait a few minutes before you try again.'
RL="{\"message\":\"$RLMSG\"}"
slept() { cat "$G/slept" 2>/dev/null | paste -sd, -; }

setup R1 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 7; resp 2 201 '{"id":2}'
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && [ "$(slept)" = 7 ] && [ "$(lines)" = 1 ] \
  && grep -qF "vs_publish: lead-verdict=success published on $SLUG@${SHA:0:12} after one retry (HTTP 403, rate-limit; token=app; GitHub: $RLMSG; Retry-After 7s)" "$ERR" && ok \
  || bad "R1 403 rate-limit + Retry-After 7 then 201: 2 POSTs, slept 7, rc 0 (rc $RC, posts $(posts), slept '$(slept)', err '$(cat "$ERR")')"

setup R2 1; echo "$TOK_APP" > "$MD/mint"; resp 1 429 "$RL" 7; resp 2 201 '{"id":2}'
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && [ "$(slept)" = 7 ] && grep -qF '(HTTP 429, rate-limit' "$ERR" && ok \
  || bad "R2 429 the same (rc $RC, posts $(posts), slept '$(slept)', err '$(cat "$ERR")')"

setup R3 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL"
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && grep -qF '(HTTP 403, rate-limit; token=app; GitHub: You have exceeded' "$ERR" && ok \
  || bad "R3 no Retry-After: 1 POST, no sleep, rc 1 (rc $RC, posts $(posts), slept '$(slept)', err '$(cat "$ERR")')"

setup R4 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 121
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && ok \
  || bad "R4 Retry-After 121 over the default cap: no retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R4b 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 30; resp 2 201 '{"id":2}'
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && [ "$(slept)" = 30 ] && ok \
  || bad "R4b Retry-After 30 = the default cap: one retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R5 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 0
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && ok \
  || bad "R5 Retry-After 0: no retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R6 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 '{"message":"Resource not accessible by integration"}' 7
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && ok \
  || bad "R6 a permission 403 with Retry-After: no retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R6b 1; echo "$TOK_APP" > "$MD/mint"; resp 1 422 "$RL" 7
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && ok \
  || bad "R6b a 422 with Retry-After: no retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R7 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 7; resp 2 403 "$RL" 7; resp 3 201 '{"id":3}'
vsp -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 2 ] && [ "$(slept)" = 7 ] && [ "$(lines)" = 1 ] \
  && grep -qE 'NOT published on .*\(HTTP 403, rate-limit; token=app; GitHub: .*; retried once after 7s\)$' "$ERR" && ok \
  || bad "R7 the retry also 403: exactly 2 POSTs, rc 1, 'retried once after 7s' (rc $RC, posts $(posts), err '$(cat "$ERR")')"

setup R8 1; echo "$TOK_APP" > "$MD/mint"; resp 1 403 "$RL" 7
vsp VS_RETRY_AFTER_MAX_S=0 -- "$SLUG" "$SHA" success "MERGE"
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && [ -z "$(slept)" ] && ok \
  || bad "R8 VS_RETRY_AFTER_MAX_S=0: never retry (rc $RC, posts $(posts), slept '$(slept)')"

setup R9 0
R9=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/verdict-status.sh"; _vs_retry_max' 2>/dev/null)
[ "$R9" = 30 ] && ok || bad "R9 _vs_retry_max with no env and no row is 30 (got '$R9')"
R9b=$(HARNESS="$H" VS_RETRY_AFTER_MAX_S=abc bash -c '. "$HARNESS/bin/lib/verdict-status.sh"; _vs_retry_max' 2>/dev/null)
[ "$R9b" = 30 ] && ok || bad "R9b a non-number VS_RETRY_AFTER_MAX_S is 30 (got '$R9b')"

# ============================================================================
# S. bad args: rc 2, no mint, no POST
# ============================================================================
setup S1 1; echo "$TOK_APP" > "$MD/mint"
vsp -- "$SLUG" not-a-sha success "MERGE"
[ "$RC" = 2 ] && [ "$(posts)" = 0 ] && [ "$(mints)" = 0 ] && ok \
  || bad "S1 a bad sha: rc 2, 0 mint, 0 POST (rc $RC, posts $(posts), mints $(mints))"

# ============================================================================
# G. no fixture token value in any stderr capture or log file
# ============================================================================
HITS=$(grep -rlF -e "$TOK_APP" -e "$TOK_PAT" -e "$TOK_FG" -e "$TOK_INH" -e gho_fixtureOauth8848 "$T/err" "$T"/c-*/h/logs "$T"/c-*/h/state "$T"/c-*/gh/calls 2>/dev/null)
[ -z "$HITS" ] && ok || bad "G1 a fixture token value leaked into: $HITS"

echo "verdict-status-app-token.bh-8848: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
