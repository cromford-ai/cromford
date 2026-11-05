#!/bin/bash
# tests/gh-app-builders-profile.bh-1578-test.sh — BH-1578: the Fly builders mint
# their GitHub tokens from their OWN App, so they spend their own 6,600/h
# installation bucket and not the hub's.
#
# THE INCIDENT (2026-09-23 02:23-03:23Z). bin/fly-pool.sh minted every pool
# machine's token through the hub's bin/gh-token.sh, so every builder clone, push
# and gh read drew on the hub App installation (161623167) — the bucket the
# merge lanes need — and it ran dry again an hour after the small box moved to
# its own App. the operator approved a separate App; it is provisioned as
# `cromford-builders` (App 5041988, installation 163957841) with its key
# at env/github-app-builders.pem and its env at env/github-app-builders.env.
#
# What is proved here, driven through the REAL bin/gh-token.sh against a stubbed
# GitHub whose every request is logged with the App id (JWT `iss`) that signed it:
#   1. `gh-token.sh --app builders` reads ONLY env/github-app-builders.env, signs
#      with the builders key, mints on the builders installation and caches in
#      its OWN directory; the default (hub) profile is byte-for-byte today's —
#      its own env, its own installation, its own cache — and neither ever
#      answers from the other's cache.
#   2. a hub owner variable can NOT leak into the builders profile: with no
#      GH_APP_INSTALLATION_<OWNER> in the builders env, discovery runs with the
#      BUILDERS JWT and its answer is cached per profile; an owner the builders
#      App is not installed on gets the HUB App's token, never the PAT.
#   3. --app with no env file behind it answers from the hub App (never worse
#      than today); a malformed profile name is a usage error.
#   4. bin/fly-pool.sh: with the builders env present a pool SPAWN ships a
#      builders token (and the bundle names its installation for the ledger);
#      without it the machine gets a hub token and the log carries ONE line
#      saying so. The pool's own hub-lane read is the hub App in both cases.
#      The ROTATION path mints from the same profile.
#   5. the profile is a registered settings knob (POOL_GH_APP_PROFILE, default
#      `builders`, required) that lane_env_apply exports, and an operator row
#      moves it.
#   6. the #1484 ledger labels a builders token `app-163957841` — from the
#      builders cache on the hub, and from the bundle's installation hint on a
#      builder that has no cache at all.
#   7. (#1590 review) the builders App BREAKS after a success: the hub App
#      answers, and then the token, --expires-at, --installation-id, the bundle
#      hint and the pool log ALL say hub; the retry is counted in gh-rate.log and
#      pages ALERTS once an hour; a dying builders machine still rotates. The
#      retry carries no builders variable into the hub mint (I1), and
#      GH_APP_TOKENS=0 in env/github-app.env stops the profile too (I2).
# Run from anywhere: tests/gh-app-builders-profile.bh-1578-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "openssl missing — bin/gh-token.sh itself needs it, so this is a real skip"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX GH_APP_TOKENS GH_APP_ROTATE POOL_GH_APP_PROFILE \
      GH_APP_ID GH_APP_PRIVATE_KEY_FILE GH_TOKEN_INSTALLATION_ID 2>/dev/null

# The installation ids and the builders App id are the REAL ones (the ticket's
# provisioning comment, the #1509 suite); the hub App id is a stand-in.
HUB_APP=880011; HUB_INST=161623167
BLD_APP=5041988; BLD_INST=163957841

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" "$H/state/build-queue/project-5" \
         "$H/builds" "$T/fakebin" "$T/rec"
cp "$DIR/bin/gh-token.sh" "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-token-live.sh" "$DIR/bin/lib/gh-repo-token.sh" \
   "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"

# Two THROWAWAY keys, one per App, generated here and deleted with $T.
for a in hub builders; do
  openssl genrsa -out "$H/env/$a.pem" 2048 2>/dev/null; chmod 600 "$H/env/$a.pem"
  openssl rsa -in "$H/env/$a.pem" -pubout -out "$T/$a.pub" 2>/dev/null
done
hub_env() {
  printf 'GH_APP_ID=%s\nGH_APP_PRIVATE_KEY_FILE=%s\nGH_APP_INSTALLATION_TESTOWNER=%s\n' \
    "$HUB_APP" "$H/env/hub.pem" "$HUB_INST" > "$H/env/github-app.env"
}
builders_env() { # builders_env [no-owner]
  { printf 'GH_APP_ID=%s\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$BLD_APP" "$H/env/builders.pem"
    [ "${1:-}" = no-owner ] || printf 'GH_APP_INSTALLATION_TESTOWNER=%s\n' "$BLD_INST"
  } > "$H/env/github-app-builders.env"
}
hub_env; builders_env
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"

# --- the GitHub stub ---------------------------------------------------------
# One line per request: "<iss>|<url>". <iss> is the App id out of the JWT that
# signed it (`-` for a token-authenticated call), so WHICH App asked is read off
# the request itself, never off a variable the script might have set. A mint
# answers `ghs_<iss>_<n>`, so the token that reaches a machine names its App.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Authorization:*) AUTH="${2#Authorization: }" ;; esac; shift 2 ;;
    -d|-X|-m) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
ISS=-
case "$AUTH" in
  Bearer\ *) P=$(printf '%s' "${AUTH#Bearer }" | cut -d. -f2 | tr '_-' '/+')
             case $(( ${#P} % 4 )) in 2) P="$P==" ;; 3) P="$P=" ;; esac
             ISS=$(printf '%s' "$P" | openssl base64 -d -A 2>/dev/null | jq -r '.iss // "-"' 2>/dev/null) ;;
esac
printf '%s|%s\n' "${ISS:--}" "$URL" >> "$CURL_LOG"
[ "$ISS" != - ] && printf '%s' "${AUTH#Bearer }" > "$CURL_LOG.jwt-$ISS"
case "$URL" in
  */app/installations)
    case "$ISS" in
      "$BLD_APP") printf '[{"id":%s,"account":{"login":"TestOwner"}}]\n' "$BLD_INST" ;;
      *)          printf '[{"id":%s,"account":{"login":"TestOwner"}},{"id":777,"account":{"login":"OtherOwner"}}]\n' "$HUB_INST" ;;
    esac ;;
  */access_tokens)
    # FAIL_BLD (a file) = the builders App is broken: its mints answer 401.
    if [ -n "${FAIL_BLD:-}" ] && [ -f "$FAIL_BLD" ] && [ "$ISS" = "$BLD_APP" ]; then echo '{"message":"Bad credentials"}'; exit 0; fi
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_%s_%s","expires_at":"%s"}\n' "$ISS" "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit) printf '{"rate":{"remaining":6000,"limit":6600}}\n' ;;
  *) echo '{}' ;;
esac
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$T/fakebin"/* "$H/bin"/*.sh
printf '0' > "$T/tokseq"; : > "$T/curl.log"

GHT() { # GHT <args...> — the real bin/gh-token.sh under the fixture; stdout only
  env PATH="$T/fakebin:$PATH" HARNESS="$H" GH_APP_API_BASE="http://api.test" \
      CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" BLD_APP="$BLD_APP" BLD_INST="$BLD_INST" \
      HUB_INST="$HUB_INST" FAIL_BLD="$T/fail-bld" GH_TOKEN=pattok ${GHT_ENV:-} "$H/bin/gh-token.sh" "$@" 2>"$T/ght.err"
}
mints_by() { grep -c "^$1|.*access_tokens" "$T/curl.log" 2>/dev/null; }
reset_state() {
  local d
  for d in "$H"/state/gh-app-tokens* "$H"/state/gh-app-installations*; do
    [ -e "$d" ] && scratch_rm "$d"
  done
  : > "$T/curl.log"
}

# ══ 1. the builders profile is its own App, installation and cache ══════════
reset_state
TB=$(GHT --app builders TestOwner/widget)
case "$TB" in "ghs_${BLD_APP}_"*) ok ;; *) bad "1a --app builders must mint from App $BLD_APP, got '$TB' ($(cat "$T/curl.log"))" ;; esac
grep -q "^$BLD_APP|http://api.test/app/installations/$BLD_INST/access_tokens$" "$T/curl.log" \
  && ok || bad "1b the builders mint must POST to installation $BLD_INST signed by App $BLD_APP: $(cat "$T/curl.log")"
[ "$(mints_by "$HUB_APP")" = 0 ] && ok || bad "1c a builders mint must never sign with the hub App"
BC="$H/state/gh-app-tokens-builders/TestOwner-widget.json"
[ "$(jq -r '.token' "$BC" 2>/dev/null)" = "$TB" ] && ok || bad "1d the builders token must be cached in state/gh-app-tokens-builders/"
[ "$(jq -r '.installation_id' "$BC" 2>/dev/null)" = "$BLD_INST" ] && ok || bad "1e the builders cache row must carry installation $BLD_INST"
[ ! -e "$H/state/gh-app-tokens/TestOwner-widget.json" ] && ok || bad "1f a builders mint must not write the hub cache"
# The builders JWT really is signed by the builders key: verify it against that
# App's PUBLIC key (the iss check above proves the id; this proves the key).
JWT=$(cat "$T/curl.log.jwt-$BLD_APP" 2>/dev/null)
printf '%s' "$(cut -d. -f1,2 <<<"$JWT")" > "$T/si.txt"
S=$(cut -d. -f3 <<<"$JWT" | tr '_-' '/+'); case $(( ${#S} % 4 )) in 2) S="$S==" ;; 3) S="$S=" ;; esac
printf '%s' "$S" | openssl base64 -d -A > "$T/sig.bin" 2>/dev/null
openssl dgst -sha256 -verify "$T/builders.pub" -signature "$T/sig.bin" "$T/si.txt" >/dev/null 2>&1 \
  && ok || bad "1f2 the builders JWT must verify against the builders App's public key"

# The hub lane: no --app, exactly today's answer, from today's files.
TH=$(GHT TestOwner/widget)
case "$TH" in "ghs_${HUB_APP}_"*) ok ;; *) bad "1g the default profile must mint from the hub App $HUB_APP, got '$TH'" ;; esac
grep -q "^$HUB_APP|http://api.test/app/installations/$HUB_INST/access_tokens$" "$T/curl.log" \
  && ok || bad "1h the hub mint must POST to installation $HUB_INST: $(cat "$T/curl.log")"
[ "$(jq -r '.installation_id' "$H/state/gh-app-tokens/TestOwner-widget.json" 2>/dev/null)" = "$HUB_INST" ] \
  && ok || bad "1i the hub cache row must carry installation $HUB_INST"
# Separate caches, both directions: each answers from its own file, no mint.
TB=$(GHT --app builders TestOwner/widget); : > "$T/curl.log"
[ "$(GHT --app builders TestOwner/widget)" = "$TB" ] && ok || bad "1j a second builders ask must be the cached builders token"
[ "$(GHT TestOwner/widget)" = "$TH" ] && ok || bad "1k a second hub ask must be the cached hub token"
grep -q access_tokens "$T/curl.log" && bad "1l cache hits must cost no mint: $(cat "$T/curl.log")" || ok
[ "$TB" != "$TH" ] && ok || bad "1m the two profiles must never share a token"
# --expires-at / --installation-id answer per profile.
[ "$(GHT --app builders --installation-id TestOwner/widget)" = "$BLD_INST" ] \
  && ok || bad "1n --app builders --installation-id must be $BLD_INST, got '$(GHT --app builders --installation-id TestOwner/widget)'"
[ "$(GHT --installation-id TestOwner/widget)" = "$HUB_INST" ] \
  && ok || bad "1o --installation-id (hub) must be $HUB_INST"
[ "$(GHT --app builders --expires-at TestOwner/widget)" = "$(jq -r .expires_at "$H/state/gh-app-tokens-builders/TestOwner-widget.json")" ] \
  && ok || bad "1p --app builders --expires-at must read the builders cache"
# `--app hub` is the default profile, spelled out.
[ "$(GHT --app hub TestOwner/widget)" = "$TH" ] && ok || bad "1q --app hub must be the default (hub) profile"

# ══ 2. no hub owner variable leaks into the builders profile ════════════════
reset_state; builders_env no-owner
TB2=$(GHT --app builders TestOwner/gadget)
grep -q "^$BLD_APP|http://api.test/app/installations$" "$T/curl.log" \
  && ok || bad "2a with no owner var, the builders profile must DISCOVER with the builders JWT: $(cat "$T/curl.log")"
grep -q "^$BLD_APP|http://api.test/app/installations/$BLD_INST/access_tokens$" "$T/curl.log" \
  && ok || bad "2b the builders mint must use the discovered builders installation, never the hub's $HUB_INST: $(cat "$T/curl.log")"
case "$TB2" in "ghs_${BLD_APP}_"*) ok ;; *) bad "2c got '$TB2'" ;; esac
[ "$(jq -r '.testowner // empty' "$H/state/gh-app-installations-builders.json" 2>/dev/null)" = "$BLD_INST" ] \
  && ok || bad "2d builders discovery must be cached per profile (state/gh-app-installations-builders.json)"
[ ! -e "$H/state/gh-app-installations.json" ] && ok || bad "2e builders discovery must not write the hub's installation cache"
builders_env
# An owner the builders App is NOT installed on (it is on example-org only): the
# hub App answers, never the PAT — a pool project owned elsewhere keeps today's
# hub token — and the expiry/installation reads follow the same rung.
: > "$T/curl.log"
T2O=$(GHT --app builders OtherOwner/thing)
case "$T2O" in "ghs_${HUB_APP}_"*) ok ;; *) bad "2f an owner the builders App cannot see must get a hub App token, got '$T2O' ($(cat "$T/curl.log"))" ;; esac
grep -q "^$HUB_APP|http://api.test/app/installations/777/access_tokens$" "$T/curl.log" \
  && ok || bad "2g the fallback mint must be the hub App on the hub's installation: $(cat "$T/curl.log")"
[ "$(GHT --app builders --installation-id OtherOwner/thing)" = 777 ] \
  && ok || bad "2h --installation-id must follow the hub fallback, got '$(GHT --app builders --installation-id OtherOwner/thing)'"
[ -n "$(GHT --app builders --expires-at OtherOwner/thing)" ] && ok || bad "2i --expires-at must follow the hub fallback"

# ══ 3. no env file = the hub App; a bad name is a usage error ═══════════════
reset_state; mv "$H/env/github-app-builders.env" "$T/bld.env.off"
T3=$(GHT --app builders TestOwner/widget)
case "$T3" in "ghs_${HUB_APP}_"*) ok ;; *) bad "3a --app builders with no env file must answer from the hub App, got '$T3'" ;; esac
grep -q 'builders' "$T/ght.err" && ok || bad "3b the fallback must say so on stderr: '$(cat "$T/ght.err")'"
mv "$T/bld.env.off" "$H/env/github-app-builders.env"
GHT --app '../etc' TestOwner/widget >/dev/null; [ "$?" = 2 ] && ok || bad "3c a profile name outside [a-z0-9-] must be a usage error (rc 2)"

# ══ 4. bin/fly-pool.sh: spawn and rotation mint from the profile ════════════
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
: > "$H/flags/fly-pool-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/builder-project-5:deployment-01\n' > "$H/state/fly/project-5.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\n[ "$2" = repo ] && { echo TestOwner/project-5; exit 0; }\nexit 1\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nmkdir -p "$2"; printf "GH_TOKEN=pattok\\n" > "$2/global.env"; printf "REPO_SLUG=TestOwner/project-5\\n" > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# flyctl: records the gh-token push and the bundle's global.env push, decoded.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
MID=""; CMD=""
case "$1 $2" in
  "machine status") echo "State: started"; exit 0 ;;
  "machines list")  echo '[]'; exit 0 ;;
  "machine run")    printf 'Machine ID: %s\n' "$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')"; exit 0 ;;
  "ssh console")    ;;
  *) exit 0 ;;
esac
shift 2
while [ $# -gt 0 ]; do
  case "$1" in --machine) MID="$2"; shift 2 ;; -C) CMD="$2"; shift 2 ;; -a) shift 2 ;; *) shift ;; esac
done
dec() { printf '%s' "$CMD" | grep -oE 'echo\\? [A-Za-z0-9+/=]+' | head -1 | awk '{print $2}' | base64 -d 2>/dev/null; }
case "$CMD" in
  *harness-env/gh-token*)   dec > "$PREC/token-$MID"; printf '%s\n' "$MID" >> "$PREC/token-pushes" ;;
  *harness-env/global.env*) dec > "$PREC/global-$MID" ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/fly" "$H/bin"/*.sh

tick() { # tick [VAR=VAL ...] — one bin/fly-pool.sh pass over the scratch tree
  : > "$H/logs/fly-pool.log"; : > "$T/curl.log"; rm -f "$T/rec"/*
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_PROJECT_5=tok PREC="$T/rec" GH_APP_API_BASE="http://api.test" \
           CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" BLD_APP="$BLD_APP" BLD_INST="$BLD_INST" \
           HUB_INST="$HUB_INST" FAIL_BLD="$T/fail-bld" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
spawn_tick() {
  rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
  jq -nc '{ticket_id:"1",key:"TK-1",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/build-queue/project-5/TK-1.json"
  tick "$@"
}
pushed() { cat "$T/rec"/token-* 2>/dev/null | head -1; }
fallback_lines() { grep -c 'github-app-builders.env' "$H/logs/fly-pool.log" 2>/dev/null; }

# 4a — builders env present, the knob says builders (what lane_env_apply exports).
reset_state
spawn_tick POOL_GH_APP_PROFILE=builders
case "$(pushed)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "4a a spawn with the builders env must ship a builders token, pushed '$(pushed)' (log: $(cat "$H/logs/fly-pool.log"))" ;; esac
grep -q "^$BLD_APP|http://api.test/app/installations/$BLD_INST/access_tokens$" "$T/curl.log" \
  && ok || bad "4b the spawn mint must hit installation $BLD_INST as App $BLD_APP: $(cat "$T/curl.log")"
[ "$(fallback_lines)" = 0 ] && ok || bad "4c no fallback line when the builders env is present: $(cat "$H/logs/fly-pool.log")"
grep -qx "GH_TOKEN_INSTALLATION_ID=$BLD_INST" "$T/rec"/global-* 2>/dev/null \
  && ok || bad "4d the bundle must name the builders installation for the ledger: $(cat "$T/rec"/global-* 2>/dev/null | sed 's/=.*/=…/' | tr '\n' ' ')"
[ "$(grep -c '^GH_TOKEN=' "$T/rec"/global-* 2>/dev/null)" = 1 ] && ok || bad "4e the bundle must carry exactly one GH_TOKEN line"
# The hub lane in the same tick (the default-auth read) is still the hub App.
case "$(jq -r '.token // ""' "$H/state/gh-app-tokens/TestOwner-project-5.json" 2>/dev/null)" in
  "ghs_${HUB_APP}_"*) ok ;; *) bad "4f the pool's own hub-lane read must stay on the hub App (hub cache: $(cat "$H/state/gh-app-tokens/TestOwner-project-5.json" 2>/dev/null))" ;; esac
case "$(jq -r '.token // ""' "$H/state/gh-app-tokens-builders/TestOwner-project-5.json" 2>/dev/null)" in
  "ghs_${BLD_APP}_"*) ok ;; *) bad "4g the machine's token must live in the builders cache" ;; esac
grep -qE 'ghs_[0-9]+_[0-9]+' "$H/logs/fly-pool.log" && bad "4h a token value reached logs/fly-pool.log" || ok

# 4i — builders env ABSENT: the hub App, and exactly one line saying so.
reset_state; mv "$H/env/github-app-builders.env" "$T/bld.env.off"
spawn_tick POOL_GH_APP_PROFILE=builders
case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "4i without the builders env the machine must get a hub token, pushed '$(pushed)'" ;; esac
[ "$(fallback_lines)" = 1 ] && ok || bad "4j the fallback must be logged exactly once, got $(fallback_lines): $(cat "$H/logs/fly-pool.log")"
[ "$(mints_by "$BLD_APP")" = 0 ] && ok || bad "4k no builders mint may happen without its env"
grep -qx "GH_TOKEN_INSTALLATION_ID=$HUB_INST" "$T/rec"/global-* 2>/dev/null \
  && ok || bad "4l the bundle's installation hint must be the hub's when the hub App minted"
mv "$T/bld.env.off" "$H/env/github-app-builders.env"

# 4m — the knob set to the hub: hub App, and no fallback line (it was asked for).
reset_state
spawn_tick POOL_GH_APP_PROFILE=hub
case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "4m POOL_GH_APP_PROFILE=hub must mint from the hub App, pushed '$(pushed)'" ;; esac
[ "$(fallback_lines)" = 0 ] && ok || bad "4n an explicit hub profile is not a fallback and must log none"

# 4o — ROTATION mints from the same profile.
reset_state
MID=aa11bb22cc33dd; MF="$H/state/fly-pool/project-5/$MID.json"
rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
jq -nc --arg m "$MID" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg e "$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ')" \
  '{machine:$m,key:"TK-1",ticket_id:"1",attempt:0,deferrals:0,deaths:0,spawned_at:$ts,gh_token_expires_at:$e}' > "$MF"
tick POOL_GH_APP_PROFILE=builders
case "$(cat "$T/rec/token-$MID" 2>/dev/null)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "4o a rotation must push a builders token, got '$(cat "$T/rec/token-$MID" 2>/dev/null)' (log: $(cat "$H/logs/fly-pool.log"))" ;; esac
rm -f "$H/state/fly-pool/project-5"/*.json

# ══ 5. the profile is a registered, required settings knob ══════════════════
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "5- could not render the lane registry"
[ "$(jq -r '.lanes[]|select(.id=="fly-pool")|.knobs[]|select(.env=="POOL_GH_APP_PROFILE")|.default' "$REG")" = builders ] \
  && ok || bad "5a fly-pool must register POOL_GH_APP_PROFILE with default 'builders'"
[ "$(jq -r '.lanes[]|select(.id=="fly-pool")|.knobs[]|select(.env=="POOL_GH_APP_PROFILE")|.required' "$REG")" = true ] \
  && ok || bad "5b POOL_GH_APP_PROFILE must be required (the script carries no literal of its own)"
grep -qE '\$\{POOL_GH_APP_PROFILE:?[-=][^}]' <<<"$(grep -v '^[[:space:]]*#' "$DIR/bin/fly-pool.sh")" \
  && bad "5c bin/fly-pool.sh must not carry a literal default for POOL_GH_APP_PROFILE" || ok
mkdir -p "$T/lg/bin/lib" "$T/lg/logs" "$T/lg/state" "$T/lg/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$T/lg/bin/lib/"
cat > "$T/lg/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  [ -n "${UNREACHABLE:-}" ] && return 1
  local out="[]" kv
  for kv in ${ROWS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]')
  done
  printf '{"settings":%s}' "$out"
}
SH
knob() { # knob [ROWS] [UNREACHABLE] — POOL_GH_APP_PROFILE as fly-pool's lane_env_apply leaves it
  # Each ask starts cold: a settings answer cached by the previous one would
  # otherwise be served instead of this call's rows.
  rm -rf "$T/lg/state/lane-gate" "$T/lg/state/settings-cache.json"
  env -u POOL_GH_APP_PROFILE HARNESS="$T/lg" LANE_REGISTRY="$REG" ROWS="${1:-}" UNREACHABLE="${2:-}" bash -c '
    . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
    lane_env_apply fly-pool project-5; printf "%s" "${POOL_GH_APP_PROFILE-UNSET}"' 2>/dev/null
}
[ "$(knob)" = builders ] && ok || bad "5d with no row the registry default 'builders' must reach the lane, got '$(knob)'"
[ "$(knob '' 1)" = builders ] && ok || bad "5e with the worker down the default must still reach the lane, got '$(knob '' 1)'"
[ "$(knob 'lane.fly-pool.project-5.pool_gh_app_profile=hub')" = hub ] \
  && ok || bad "5f an operator row must move the profile, got '$(knob 'lane.fly-pool.project-5.pool_gh_app_profile=hub')'"

# ══ 7. the builders App BREAKS after a success (review of #1590, B2/I1/I2) ══
# The realistic failure: a builders token was minted, its row ages toward expiry,
# then every builders mint fails (key rotated, App suspended). The hub App may
# answer — but then EVERY read must say hub (token, expiry, installation, log),
# the retry must be visible and counted, and rotation must not stall on the
# stale builders row.
reset_state; : > "$H/logs/gh-rate.log"; rm -f "$H/logs/ALERTS.log" "$H/flags"/alerted-gh-app-profile-retry-*
# Section 2f already retried once this hour; the count here starts from zero.
[ -d "$H/state/gh-app-profile-retry" ] && scratch_rm "$H/state/gh-app-profile-retry"
GHT --app builders TestOwner/project-5 >/dev/null
BC="$H/state/gh-app-tokens-builders/TestOwner-project-5.json"
STALE=$(date -u -d '+4 minutes' '+%Y-%m-%dT%H:%M:%SZ')
jq --arg e "$STALE" '.expires_at=$e' "$BC" > "$BC.t" && mv "$BC.t" "$BC"
: > "$T/fail-bld"; : > "$T/curl.log"
T7=$(GHT --app builders --min-life 900 TestOwner/project-5)
case "$T7" in "ghs_${HUB_APP}_"*) ok ;; *) bad "7a a broken builders App must be answered by the hub App, got '$T7'" ;; esac
HUBEXP=$(jq -r '.expires_at' "$H/state/gh-app-tokens/TestOwner-project-5.json" 2>/dev/null)
[ "$(GHT --app builders --min-life 900 --installation-id TestOwner/project-5)" = "$HUB_INST" ] \
  && ok || bad "7b --installation-id must name the installation that ANSWERED ($HUB_INST), not the stale builders row: got '$(GHT --app builders --min-life 900 --installation-id TestOwner/project-5)'"
E7=$(GHT --app builders --min-life 900 --expires-at TestOwner/project-5)
[ -n "$E7" ] && [ "$E7" = "$HUBEXP" ] && [ "$E7" != "$STALE" ] \
  && ok || bad "7c --expires-at must be the hub row's ($HUBEXP), never the stale builders one ($STALE): got '$E7'"
grep -qE 'gh-app-profile-retry profile=builders->hub TestOwner/project-5 .*count=1' "$H/logs/gh-rate.log" \
  && ok || bad "7d the retry must leave a counted line in logs/gh-rate.log: $(cat "$H/logs/gh-rate.log")"
grep -qE 'ghs_[0-9]+_[0-9]+' "$H/logs/gh-rate.log" && bad "7d2 a token value reached logs/gh-rate.log" || ok
# Rotation of a live machine whose builders token is dying: it must rotate.
MID=aa11bb22cc33dd; MF="$H/state/fly-pool/project-5/$MID.json"
rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
jq -nc --arg m "$MID" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg e "$STALE" \
  '{machine:$m,key:"TK-1",ticket_id:"1",attempt:0,deferrals:0,deaths:0,spawned_at:$ts,gh_token_expires_at:$e}' > "$MF"
tick POOL_GH_APP_PROFILE=builders
case "$(cat "$T/rec/token-$MID" 2>/dev/null)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "7e a dying builders machine must be rotated (onto the hub token) while the builders App is broken, pushed '$(cat "$T/rec/token-$MID" 2>/dev/null)' (log: $(cat "$H/logs/fly-pool.log"))" ;; esac
grep -q 'rotated App token on .* from the hub App' "$H/logs/fly-pool.log" \
  && ok || bad "7f the rotation line must name the App that answered (hub): $(cat "$H/logs/fly-pool.log")"
grep -q 'hub-retry' "$H/logs/fly-pool.log" \
  && ok || bad "7g fly-pool must log the hub retry, not drop it with stderr: $(cat "$H/logs/fly-pool.log")"
rm -f "$H/state/fly-pool/project-5"/*.json
# Spawn while broken: the hint and the log both say hub.
spawn_tick POOL_GH_APP_PROFILE=builders
grep -qx "GH_TOKEN_INSTALLATION_ID=$HUB_INST" "$T/rec"/global-* 2>/dev/null \
  && ok || bad "7h a hub-answered spawn must ship the HUB installation hint: $(grep -h GH_TOKEN_INSTALLATION_ID "$T/rec"/global-* 2>/dev/null)"
grep -q 'gets a repo-scoped App token .* from the hub App' "$H/logs/fly-pool.log" \
  && ok || bad "7i the spawn line must name the App that answered (hub): $(grep 'gets a repo-scoped' "$H/logs/fly-pool.log")"
grep -q 'from the builders App' "$H/logs/fly-pool.log" && bad "7j nothing may claim the builders App minted a hub token" || ok
# Rate-limited alert: several retries this hour, ONE ALERTS line naming builders.
[ "$(grep -c 'gh-app-profile-retry' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "7k the retry must page ONCE per profile per hour, got $(grep -c 'gh-app-profile-retry' "$H/logs/ALERTS.log" 2>/dev/null): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(grep -c 'gh-app-profile-retry profile=builders->hub' "$H/logs/gh-rate.log")" -ge 3 ] \
  && ok || bad "7l every retry is counted in gh-rate.log (3 so far), got $(grep -c 'gh-app-profile-retry' "$H/logs/gh-rate.log")"
rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
# I1 — the retry must not carry builders variables into the hub mint. A hub env
# with ONLY its App id (default key path, owner discovered) must still sign as
# the hub and mint on the hub installation.
reset_state
printf 'GH_APP_ID=%s\n' "$HUB_APP" > "$H/env/github-app.env"; cp "$H/env/hub.pem" "$H/env/github-app.pem"
T7I=$(GHT --app builders TestOwner/widget)
case "$T7I" in "ghs_${HUB_APP}_"*) ok ;; *) bad "7m the hub retry must mint a hub token with a minimal hub env, got '$T7I' ($(cat "$T/curl.log"))" ;; esac
grep -q "^$HUB_APP|http://api.test/app/installations/$HUB_INST/access_tokens$" "$T/curl.log" \
  && ok || bad "7n the hub JWT must hit the HUB installation: $(cat "$T/curl.log")"
grep -q "^$HUB_APP|.*/installations/$BLD_INST/" "$T/curl.log" && bad "7o a hub JWT was sent to the builders installation" || ok
rm -f "$H/env/github-app.pem" "$T/fail-bld"; hub_env
# I2 — GH_APP_TOKENS=0 in env/github-app.env stops the builders profile too.
reset_state; printf 'GH_APP_TOKENS=0\n' >> "$H/env/github-app.env"
[ "$(GHT --app builders TestOwner/widget)" = pattok ] && ok || bad "7p GH_APP_TOKENS=0 in the hub env must stop the builders profile (PAT), got '$(GHT --app builders TestOwner/widget)'"
[ "$(mints_by "$BLD_APP")" = 0 ] && ok || bad "7q no builders mint may happen with the hub kill switch set"
hub_env

# ══ 6. the #1484 ledger names the builders bucket ═══════════════════════════
L="$T/led"; mkdir -p "$L/state/gh-app-tokens" "$L/state/gh-app-tokens-builders"
printf '{"repo":"o/r","token":"ghs_hubtok","installation_id":"%s"}\n' "$HUB_INST" > "$L/state/gh-app-tokens/o-r.json"
printf '{"repo":"o/r","token":"ghs_bldtok","installation_id":"%s"}\n' "$BLD_INST" > "$L/state/gh-app-tokens-builders/o-r.json"
bucket() { # bucket <token> [installation hint] [harness]
  env -u GH_TOKEN_INSTALLATION_ID HARNESS="${3:-$L}" GH_TOKEN="$1" ${2:+GH_TOKEN_INSTALLATION_ID=$2} \
    bash -c '. "$0"; gh_quota_bucket' "$DIR/bin/lib/gh-rest-ledger.sh" 2>/dev/null
}
[ "$(bucket ghs_bldtok)" = "app-$BLD_INST" ] && ok || bad "6a a builders-cached token must be bucket app-$BLD_INST, got '$(bucket ghs_bldtok)'"
[ "$(bucket ghs_hubtok)" = "app-$HUB_INST" ] && ok || bad "6b a hub-cached token must stay app-$HUB_INST, got '$(bucket ghs_hubtok)'"
[ "$(bucket ghs_elsewhere '' "$T/nohome")" = app ] && ok || bad "6c an unknown token with no hint stays the legacy 'app'"
[ "$(bucket ghs_elsewhere "$BLD_INST" "$T/nohome")" = "app-$BLD_INST" ] \
  && ok || bad "6d on a builder (no cache) the bundle's installation hint must name the bucket, got '$(bucket ghs_elsewhere "$BLD_INST" "$T/nohome")'"
[ "$(bucket ghs_hubtok "$BLD_INST")" = "app-$HUB_INST" ] && ok || bad "6e a cache row must beat the hint"
[ "$(bucket ghs_elsewhere '12x' "$T/nohome")" = app ] && ok || bad "6f a non-numeric hint must be ignored"
[ "$(bucket pattok "$BLD_INST" "$T/nohome" | cut -c1-4)" = pat- ] && ok || bad "6g a PAT is never labelled by the App hint"

echo "gh-app-builders-profile: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
