#!/bin/bash
# tests/gh-app-builders-followups.bh-1602-test.sh — BH-1602: the three follow-ups
# the #1590 review left on the builders App (BH-1578).
#
#   1. bin/gh-token.sh's hourly flags/alerted-gh-app-profile-retry-* were never
#      deleted; profile_retry_record now prunes them past 180 min, the bound
#      bin/lib/gh-quota.sh uses for its own alerted-gh-quota-* flags.
#   2. a rotation that changed App (builders -> hub retry, or back) left the
#      machine's spawn-time GH_TOKEN_INSTALLATION_ID naming the wrong bucket.
#      bin/fly-pool.sh's rotation now pushes /run/harness-env/gh-installation-id
#      beside the token, and bin/lib/gh-token-live.sh exports it with the token,
#      so the #1484 ledger on a builder names the installation that minted.
#   3. a pool project owned where the builders App is not installed took the hub
#      retry on every mint and paged every hour. POOL_GH_APP_OWNERS (a registered
#      settings row, default example-org) names the owners the App is on; any other
#      owner mints from the hub App directly and pages once per owner per day.
# Driven through the real bin/gh-token.sh, a real bin/fly-pool.sh tick, the real
# gh_token_live and the real ledger reader, against a stubbed GitHub and fly.
# Run from anywhere: tests/gh-app-builders-followups.bh-1602-test.sh (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: clear_boundary around the hour stamp
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 41 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "openssl missing — bin/gh-token.sh itself needs it, so this is a real skip"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX GH_APP_TOKENS GH_APP_ROTATE POOL_GH_APP_PROFILE POOL_GH_APP_OWNERS \
      GH_APP_ID GH_APP_PRIVATE_KEY_FILE GH_TOKEN_INSTALLATION_ID GH_TOKEN 2>/dev/null

# The installation ids and the builders App id are the REAL ones (the ticket's
# provisioning comment, the #1509 suite); the hub App id is a stand-in.
HUB_APP=880011; HUB_INST=161623167
BLD_APP=5041988; BLD_INST=163957841

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" "$H/state/build-queue/project-5" \
         "$H/builds" "$T/fakebin" "$T/rec"
cp "$DIR/bin/gh-token.sh" "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
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
      *)          printf '[{"id":%s,"account":{"login":"TestOwner"}},{"id":777,"account":{"login":"OtherOwner"}},{"id":778,"account":{"login":"example-org-labs"}}]\n' "$HUB_INST" ;;
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


# ══ 1. the hourly profile-retry flags are pruned ════════════════════════════
: > "$T/fail-bld"; rm -f "$H/logs/ALERTS.log"
OLDHR=$(date -u -d '5 hours ago' +%Y%m%d%H)
OLDF="$H/flags/alerted-gh-app-profile-retry-builders-$OLDHR"
: > "$OLDF"; touch -d '5 hours ago' "$OLDF"
QF="$H/flags/alerted-gh-quota-x"; : > "$QF"; touch -d '5 hours ago' "$QF"
# BH-6049: bin/gh-token.sh stamps its own hour (no clock knob) and 1b/1b3 recompute
# it, so the case must not straddle HH:00. Step past the hour when it is near.
clear_boundary 3600 30
T1=$(GHT --app builders TestOwner/x)
case "$T1" in "ghs_${HUB_APP}_"*) ok ;; *) bad "1- the broken builders App must be answered by the hub, got '$T1' ($(cat "$T/ght.err"))" ;; esac
[ ! -e "$OLDF" ] && ok || bad "1a a retry flag 5 h old must be pruned by the next retry"
NOWF="$H/flags/alerted-gh-app-profile-retry-builders-$(date -u +%Y%m%d%H)"
[ -e "$NOWF" ] && ok || bad "1b the current hour's retry flag must exist after a retry"
GHT --app builders TestOwner/y >/dev/null
[ -e "$NOWF" ] && ok || bad "1b2 a second retry in the same hour must not prune the current hour's flag"
[ "$(grep -c 'gh-app-profile-retry' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "1b3 two retries in one hour must still page once, got $(grep -c 'gh-app-profile-retry' "$H/logs/ALERTS.log" 2>/dev/null)"
[ -e "$QF" ] && ok || bad "1c the prune must not touch another family's flags (alerted-gh-quota-*)"
rm -f "$T/fail-bld" "$QF" "$H/flags"/alerted-gh-app-profile-retry-*

# ══ fly-pool scaffold (from the BH-1578 suite) ══════════════════════════════
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
: > "$H/flags/fly-pool-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/builder-project-5:deployment-01\n' > "$H/state/fly/project-5.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
set_owner() { # set_owner <Owner> — the fleet.conf slug and the bundle's REPO_SLUG
  printf '#!/bin/bash\n[ "$2" = repo ] && { echo %s/project-5; exit 0; }\nexit 1\n' "$1" > "$H/bin/fleet-conf.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; printf "GH_TOKEN=pattok\\n" > "$2/global.env"; printf "REPO_SLUG=%s/project-5\\n" > "$2/$1.env"; exit 0\n' "$1" > "$H/bin/fly-envbundle.sh"
  chmod +x "$H/bin/fleet-conf.sh" "$H/bin/fly-envbundle.sh"
}
set_owner TestOwner
# flyctl: records the token push, the installation-hint push and the bundle's
# global.env, decoded. The hint case comes FIRST so it is never read as a token.
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
  *harness-env/gh-installation-id*) dec > "$PREC/hint-$MID" ;;
  *harness-env/gh-token*)   dec > "$PREC/token-$MID"; printf '%s\n' "$MID" >> "$PREC/token-pushes" ;;
  *harness-env/global.env*) dec > "$PREC/global-$MID" ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/fly" "$H/bin"/*.sh

tick() { # tick [VAR=VAL ...] — one bin/fly-pool.sh pass over the scratch tree
  : > "$H/logs/fly-pool.log"; : > "$T/curl.log"; rm -f "$T/rec"/*
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_project-5=tok PREC="$T/rec" GH_APP_API_BASE="http://api.test" \
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
MID=aa11bb22cc33dd; MF="$H/state/fly-pool/project-5/$MID.json"
machine() { # machine <expiry offset> — one live machine record, no queue row
  rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
  jq -nc --arg m "$MID" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg e "$(date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ')" \
    '{machine:$m,key:"TK-1",ticket_id:"1",attempt:0,deferrals:0,deaths:0,spawned_at:$ts,gh_token_expires_at:$e}' > "$MF"
}

# ══ 2. the rotation pushes the installation hint beside the token ═══════════
reset_state; : > "$T/fail-bld"
machine '+10 minutes'
tick POOL_GH_APP_PROFILE=builders
case "$(cat "$T/rec/token-$MID" 2>/dev/null)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "2a- the rotation with the builders App broken must push a hub token, got '$(cat "$T/rec/token-$MID" 2>/dev/null)' (log: $(cat "$H/logs/fly-pool.log"))" ;; esac
[ "$(tr -d '\n' 2>/dev/null < "$T/rec/hint-$MID")" = "$HUB_INST" ] \
  && ok || bad "2a the rotation must push gh-installation-id=$HUB_INST (the hub answered), got '$(cat "$T/rec/hint-$MID" 2>/dev/null || echo '<no push>')'"
grep -q "rotated App token on $MID .*installation $HUB_INST" "$H/logs/fly-pool.log" \
  && ok || bad "2a2 the rotation line must name the installation: $(grep rotated "$H/logs/fly-pool.log")"
rm -f "$T/fail-bld"; reset_state
machine '+10 minutes'
tick POOL_GH_APP_PROFILE=builders
case "$(cat "$T/rec/token-$MID" 2>/dev/null)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "2b- a healthy builders rotation must push a builders token" ;; esac
[ "$(tr -d '\n' 2>/dev/null < "$T/rec/hint-$MID")" = "$BLD_INST" ] \
  && ok || bad "2b the rotation must push gh-installation-id=$BLD_INST, got '$(cat "$T/rec/hint-$MID" 2>/dev/null || echo '<no push>')'"
reset_state
machine '+50 minutes'
tick POOL_GH_APP_PROFILE=builders
[ ! -e "$T/rec/hint-$MID" ] && [ ! -e "$T/rec/token-$MID" ] \
  && ok || bad "2c a machine not due for rotation must get neither a token nor a hint"
rm -f "$H/state/fly-pool/project-5"/*.json

# ══ 3. gh_token_live moves the hint with the token ══════════════════════════
LV="$T/live"; mkdir -p "$LV"; printf 'tokX\n' > "$LV/gh-token"
live() { # live — the real gh_token_live over $LV; prints GH_TOKEN|GH_TOKEN_INSTALLATION_ID
  env -u GH_APP_TOKENS HARNESS="$T/nohome" GH_TOKEN_LIVE_FILE="$LV/gh-token" GH_TOKEN_INSTALLATION_ID=161623167 \
    bash -c '. "$0"; gh_token_live || exit 9; printf "%s|%s" "$GH_TOKEN" "${GH_TOKEN_INSTALLATION_ID-UNSET}"' \
    "$DIR/bin/lib/gh-token-live.sh" 2>/dev/null
}
printf '163957841\n' > "$LV/gh-installation-id"
[ "$(live)" = "tokX|163957841" ] && ok || bad "3a a sidecar with an id must become GH_TOKEN_INSTALLATION_ID, got '$(live)'"
rm -f "$LV/gh-installation-id"
[ "$(live)" = "tokX|161623167" ] && ok || bad "3b no sidecar must leave the spawn-time hint untouched, got '$(live)'"
: > "$LV/gh-installation-id"
[ "$(live)" = "tokX|UNSET" ] && ok || bad "3c an empty sidecar must unset the hint, got '$(live)'"
printf 'abc\n' > "$LV/gh-installation-id"
[ "$(live)" = "tokX|UNSET" ] && ok || bad "3c2 a non-numeric sidecar must unset the hint, got '$(live)'"
# 3d — the production reader: the ledger bucket after gh_token_live, no cache.
printf '163957841\n' > "$LV/gh-installation-id"
B3=$(env -u GH_APP_TOKENS HARNESS="$T/nohome" GH_TOKEN_LIVE_FILE="$LV/gh-token" GH_TOKEN_INSTALLATION_ID=161623167 \
  bash -c '. "$0"; . "$1"; gh_token_live || exit 9; _gh_app_install_of_token' \
  "$DIR/bin/lib/gh-token-live.sh" "$DIR/bin/lib/gh-rest-ledger.sh" 2>/dev/null)
[ "$B3" = "app-163957841" ] && ok || bad "3d the ledger must file the live token under the sidecar's installation, got '$B3'"

# ══ 4. POOL_GH_APP_OWNERS is a registered, required settings row ════════════
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "4- could not render the lane registry"
[ "$(jq -r '.lanes[]|select(.id=="fly-pool")|.knobs[]|select(.env=="POOL_GH_APP_OWNERS")|.default' "$REG" 2>/dev/null)" = example-org ] \
  && ok || bad "4a fly-pool must register POOL_GH_APP_OWNERS with default 'example-org'"
[ "$(jq -r '.lanes[]|select(.id=="fly-pool")|.knobs[]|select(.env=="POOL_GH_APP_OWNERS")|.required' "$REG" 2>/dev/null)" = true ] \
  && ok || bad "4a2 POOL_GH_APP_OWNERS must be required"
grep -qE '\$\{POOL_GH_APP_OWNERS:?[-=][^}]' <<<"$(grep -v '^[[:space:]]*#' "$DIR/bin/fly-pool.sh")" \
  && bad "4b bin/fly-pool.sh must not carry a literal default for POOL_GH_APP_OWNERS" || ok

# ══ 5. an owner the builders App is not on mints from the hub, pages daily ══
owner_alerts() { grep -c "POOL_GH_APP_OWNERS" "$H/logs/ALERTS.log" 2>/dev/null; }
reset_state; rm -f "$H/logs/ALERTS.log"; : > "$H/logs/gh-rate.log"
STALEF="$H/flags/alerted-gh-app-profile-owner-builders-gone-20000101"
: > "$STALEF"; touch -d '3 days ago' "$STALEF"
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=example-org
case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "5a an owner outside POOL_GH_APP_OWNERS must get a hub token, pushed '$(pushed)' (log: $(cat "$H/logs/fly-pool.log"))" ;; esac
[ "$(mints_by "$BLD_APP")" = 0 ] && ok || bad "5a2 no builders mint may be attempted for an owner the App is not on"
grep -q "^$BLD_APP|" "$T/curl.log" && bad "5a3 no request may be signed by the builders App: $(grep "^$BLD_APP|" "$T/curl.log")" || ok
[ "$(grep -c 'gh-app-profile-retry' "$H/logs/gh-rate.log" 2>/dev/null)" = 0 ] \
  && ok || bad "5a4 no hub retry may be counted: $(cat "$H/logs/gh-rate.log")"
grep -q "owner 'TestOwner' is not in POOL_GH_APP_OWNERS" "$H/logs/fly-pool.log" \
  && ok || bad "5a5 the tick must say why it minted from the hub: $(cat "$H/logs/fly-pool.log")"
[ "$(owner_alerts)" = 1 ] && grep -q "owner 'TestOwner'" "$H/logs/ALERTS.log" \
  && ok || bad "5b exactly one ALERTS line naming the owner, got $(owner_alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=example-org
[ "$(owner_alerts)" = 1 ] && ok || bad "5c a second tick the same day must not page again, got $(owner_alerts)"
[ -e "$H/flags/alerted-gh-app-profile-owner-builders-testowner-$(date -u +%Y%m%d)" ] \
  && ok || bad "5c2 the per-day owner flag must exist: $(ls "$H/flags")"
[ ! -e "$STALEF" ] && ok || bad "5c3 an owner flag 3 days old must be pruned"
set_owner OtherOwner
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=example-org
[ "$(owner_alerts)" = 2 ] && grep -q "owner 'OtherOwner'" "$H/logs/ALERTS.log" \
  && ok || bad "5d a second owner must page separately, got $(owner_alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
set_owner TestOwner
reset_state
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS="example-org, testowner"
case "$(pushed)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "5e an owner in the row (any case, comma+space) must get a builders token, pushed '$(pushed)'" ;; esac
[ "$(owner_alerts)" = 2 ] && ok || bad "5e2 an installed owner must not page"
grep -q 'is not in POOL_GH_APP_OWNERS' "$H/logs/fly-pool.log" && bad "5e3 an installed owner must not be reported as missing" || ok
reset_state
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS='*'
case "$(pushed)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "5f '*' must match every owner, pushed '$(pushed)'" ;; esac
reset_state
spawn_tick POOL_GH_APP_PROFILE=builders
case "$(pushed)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "5f2 an unset row must be today's behaviour (builders), pushed '$(pushed)'" ;; esac
reset_state
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=' example-org ,  TESTOWNER '
case "$(pushed)" in "ghs_${BLD_APP}_"*) ok ;; *) bad "5f3 padded upper-case entries must match, pushed '$(pushed)'" ;; esac
for row in Test 'TestOwner-x Other' 'TestOwner-x,Other' testowne; do
  reset_state
  spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS="$row"
  case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "5g row '$row' must not match owner TestOwner (hub token), pushed '$(pushed)'" ;; esac
done
set_owner example-org-labs; reset_state
spawn_tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=example-org
case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "5g2 owner example-org-labs must not match row example-org, pushed '$(pushed)'" ;; esac
set_owner TestOwner
N5=$(owner_alerts)
reset_state
spawn_tick POOL_GH_APP_PROFILE=hub POOL_GH_APP_OWNERS=example-org
case "$(pushed)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "5h profile hub must mint from the hub, pushed '$(pushed)'" ;; esac
[ "$(owner_alerts)" = "$N5" ] && ok || bad "5h the hub profile must never page about owners"
# The rotation obeys the row too: a dying machine of a non-installed owner
# rotates onto the hub App with no builders request at all.
reset_state; machine '+10 minutes'
tick POOL_GH_APP_PROFILE=builders POOL_GH_APP_OWNERS=example-org
case "$(cat "$T/rec/token-$MID" 2>/dev/null)" in "ghs_${HUB_APP}_"*) ok ;; *) bad "5i the rotation must mint from the hub for a non-installed owner, got '$(cat "$T/rec/token-$MID" 2>/dev/null)'" ;; esac
grep -q "^$BLD_APP|" "$T/curl.log" && bad "5i2 the rotation must not ask the builders App" || ok
rm -f "$H/state/fly-pool/project-5"/*.json

grep -qE 'ghs_[0-9]+_[0-9]+' "$H/logs/fly-pool.log" "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "no-leak a token value reached a log" || ok

echo "gh-app-builders-followups: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
