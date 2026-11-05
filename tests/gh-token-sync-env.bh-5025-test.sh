#!/bin/bash
# tests/gh-token-sync-env.bh-5025-test.sh — a pool machine's global.env follows the
# rotated GitHub token (BH-5045, split 1 of #5025).
#
# THE INCIDENT (2026-10-07, hub probe 00:39Z). bin/fly-pool.sh's rotate_gh_token
# pushed a fresh App token to /run/harness-env/gh-token only. global.env kept the
# GH_TOKEN= the machine was spawned with, which dies an hour later, and
# fly/builder-runner.sh's load_env sources global.env at the top of every job. On
# 17 machines the global.env token answered 401 while the gh-token file beside it
# answered 200, so every prelude gh read of every job after the first hour failed.
#
# What is proved here:
#   S1-S6 gh_token_live_sync_env: rewrites GH_TOKEN= from the live file, whole and
#         atomically; leaves the file untouched (rc 1) on a kill switch, a missing
#         or empty live file, a missing env file, or a token sh would not read as
#         one plain word; carries the installation id by gh_token_live's rule.
#   S7    load_env (lifted from the real runner) syncs before it sources, so a real
#         gh_rest read answers 200 where the tree without the lib answers 401.
#   S8    rotate_gh_token (the real bin/fly-pool.sh tick) asks the machine to sync
#         after a pushed token, never after a failed push, and never sends the
#         token a second time; the payload it sends works once unquoted.
#   S9    load_env's shape the rotate suite also pins.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gh-token-sync-env.bh-5025-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export LANE_GATE_DISABLE=1
unset GH_APP_TOKENS GH_TOKEN_LIVE_FILE GH_TOKEN_INSTALLATION_LIVE_FILE HARNESS_ENV_DIR 2>/dev/null

H="$T/h"
mkdir -p "$H/flags" "$T/env"
scratch_install_closure bin/lib/gh-token-live.sh "$H" >/dev/null || { echo "FAIL: cannot install the gh-token-live closure"; exit 1; }
ENVF="$T/env/global.env"

# fixture <global.env body|-> <live body|-> [sidecar body|-] — a fresh env dir.
# "-" means the file does not exist.
fixture() {
  rm -rf "$T/env"; mkdir -p "$T/env"
  [ "$1" = - ] || printf '%b' "$1" > "$ENVF"
  [ "$2" = - ] || printf '%b' "$2" > "$T/env/gh-token"
  [ "${3:--}" = - ] || printf '%b' "$3" > "$T/env/gh-installation-id"
  [ -f "$ENVF" ] && cp -p "$ENVF" "$T/env.before"
  return 0
}
# sync [VAR=VAL ...] — the real function on the scratch env file; output to $T/out.
sync() {
  ( export HARNESS="$H" "$@"
    . "$DIR/bin/lib/gh-token-live.sh" || exit 99
    gh_token_live_sync_env "$ENVF" ) > "$T/out" 2>&1
}
unchanged() { cmp -s "$T/env.before" "$ENVF"; }

# ══ S1 stale token rewritten ════════════════════════════════════════════════
fixture 'HARNESS_SECRET=x\nGH_TOKEN=stale-tok\nGH_TOKEN_INSTALLATION_ID=111\nOTHER=y\n' 'fresh-tok\r\n' '222\n'
chmod 644 "$ENVF"
sync; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 a stale GH_TOKEN must sync with rc 0 (rc $rc: $(cat "$T/out"))"
[ "$(grep -c '^GH_TOKEN=' "$ENVF")" = 1 ] && ok || bad "S1 exactly one GH_TOKEN= line: $(grep '^GH_TOKEN=' "$ENVF" | tr '\n' ' ')"
grep -qx 'GH_TOKEN=fresh-tok' "$ENVF" && ok || bad "S1 GH_TOKEN= must be the live token"
grep -qx 'GH_TOKEN_INSTALLATION_ID=222' "$ENVF" && ok || bad "S1 the installation id must follow the sidecar"
[ "$(grep -c '^GH_TOKEN_INSTALLATION_ID=' "$ENVF")" = 1 ] && ok || bad "S1 exactly one installation-id line"
[ "$(grep -v '^GH_TOKEN' "$ENVF" | tr '\n' ' ')" = "HARNESS_SECRET=x OTHER=y " ] \
  && ok || bad "S1 every other line kept, in order: $(tr '\n' ' ' < "$ENVF")"
[ "$(stat -c %a "$ENVF")" = 600 ] && ok || bad "S1 the rewritten file must be mode 600 (is $(stat -c %a "$ENVF"))"
grep -q 'bh5025' <<<"$(ls "$T/env")" && bad "S1 a tmp file was left behind: $(ls "$T/env")" || ok
grep -qE 'fresh-tok|stale-tok' "$T/out" && bad "S1 the call printed a token" || ok

# ══ S2 already equal: no write at all ═══════════════════════════════════════
fixture 'A=1\nGH_TOKEN=fresh-tok\nGH_TOKEN_INSTALLATION_ID=222\n' 'fresh-tok\n' '222\n'
touch -d '-1 min' "$ENVF"; S0=$(stat -c '%i %Y' "$ENVF")
sync; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 an equal token answers rc 0 (rc $rc)"
[ "$(stat -c '%i %Y' "$ENVF")" = "$S0" ] && ok || bad "S2 an equal token must not rewrite the file (inode/mtime moved)"

# ══ S3 nothing to sync ══════════════════════════════════════════════════════
fixture 'GH_TOKEN=stale-tok\n' -
sync; rc=$?; [ "$rc" = 1 ] && unchanged && ok || bad "S3a no live file: rc 1 and untouched (rc $rc)"
fixture 'GH_TOKEN=stale-tok\n' ''
sync; rc=$?; [ "$rc" = 1 ] && unchanged && ok || bad "S3b empty live file: rc 1 and untouched (rc $rc)"
fixture 'GH_TOKEN=stale-tok\n' ' \t\r\n\n'
sync; rc=$?; [ "$rc" = 1 ] && unchanged && ok || bad "S3c whitespace-only live file: rc 1 and untouched (rc $rc)"
fixture - 'fresh-tok\n'
sync; rc=$?; [ "$rc" = 1 ] && [ ! -e "$ENVF" ] && ok || bad "S3d missing env file: rc 1 and not created (rc $rc)"
grep -q 'bh5025' <<<"$(ls "$T/env")" && bad "S3d a tmp file was left behind" || ok

# ══ S4 kill switch ══════════════════════════════════════════════════════════
fixture 'GH_TOKEN=stale-tok\n' 'fresh-tok\n'
touch "$H/flags/gh-app-tokens-off"
sync; rc=$?; [ "$rc" = 1 ] && unchanged && ok || bad "S4a flags/gh-app-tokens-off: rc 1 and untouched (rc $rc)"
rm -f "$H/flags/gh-app-tokens-off"
sync GH_APP_TOKENS=0; rc=$?; [ "$rc" = 1 ] && unchanged && ok || bad "S4b GH_APP_TOKENS=0: rc 1 and untouched (rc $rc)"
# No harness root at all: refuse rather than guess one (D43).
( unset HARNESS H; . "$DIR/bin/lib/gh-token-live.sh"; gh_token_live_sync_env "$ENVF" ) >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && unchanged && ok || bad "S4c no HARNESS root: rc 1 and untouched (rc $rc)"

# ══ S5 injection ════════════════════════════════════════════════════════════
for evil in 'x$(touch '"$T"'/PWNED)' 'a"b' "a'b" 'a`id`' 'a;b' 'a&b' 'a\b'; do
  fixture 'GH_TOKEN=stale-tok\n' -
  printf '%s' "$evil" > "$T/env/gh-token"
  sync; rc=$?
  [ "$rc" = 1 ] && unchanged && ok || bad "S5 a live token '$evil' must be refused untouched (rc $rc)"
  ( set -a; . "$ENVF" ) >/dev/null 2>&1
  [ -e "$T/PWNED" ] && bad "S5 sourcing global.env ran the token '$evil'" || ok
done

# Whitespace inside the file is stripped first, the rule gh_token_live applies, so
# global.env carries the same token a running build reads from the file.
fixture 'GH_TOKEN=stale-tok\n' 'fresh -tok\n'
sync; rc=$?
LIVE=$( export HARNESS="$H" GH_TOKEN_LIVE_FILE="$T/env/gh-token"; . "$DIR/bin/lib/gh-token-live.sh"; gh_token_live; printf '%s' "${GH_TOKEN:-}" )
[ "$rc" = 0 ] && grep -qx "GH_TOKEN=$LIVE" "$ENVF" && [ "$LIVE" = fresh-tok ] \
  && ok || bad "S5 global.env must hold what gh_token_live reads (rc $rc, live '$LIVE'): $(cat "$ENVF")"

# ══ S6 sidecar rules ════════════════════════════════════════════════════════
fixture 'GH_TOKEN=stale-tok\nGH_TOKEN_INSTALLATION_ID=111\n' 'fresh-tok\n'
sync; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^GH_TOKEN_INSTALLATION_ID=111$' "$ENVF")" = 1 ] \
  && ok || bad "S6a no sidecar keeps the existing installation id exactly once (rc $rc): $(tr '\n' ' ' < "$ENVF")"
fixture 'GH_TOKEN=stale-tok\nGH_TOKEN_INSTALLATION_ID=111\n' 'fresh-tok\n' '\n'
sync; rc=$?
[ "$rc" = 0 ] && ! grep -q '^GH_TOKEN_INSTALLATION_ID=' "$ENVF" \
  && ok || bad "S6b an empty sidecar drops the installation id (rc $rc): $(tr '\n' ' ' < "$ENVF")"
fixture 'GH_TOKEN=stale-tok\nGH_TOKEN_INSTALLATION_ID=111\n' 'fresh-tok\n' 'abc\n'
sync; rc=$?
[ "$rc" = 0 ] && ! grep -q '^GH_TOKEN_INSTALLATION_ID=' "$ENVF" \
  && ok || bad "S6c a non-numeric sidecar drops the installation id (rc $rc)"
# A last line with no newline survives the rewrite.
fixture 'GH_TOKEN=stale-tok\nLAST=z' 'fresh-tok\n'
sync; rc=$?
[ "$rc" = 0 ] && grep -qx 'LAST=z' "$ENVF" && ok || bad "S6d a last line with no newline must be kept (rc $rc)"

# ══ S7 end to end through load_env ══════════════════════════════════════════
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
[ "$1 $2" = "auth setup-git" ] && exit 0
if [ "$1" = api ]; then
  if [ "${GH_TOKEN:-}" = fresh-tok ]; then printf 'HTTP/2.0 200 OK\r\n\r\n[]\n'; exit 0; fi
  printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'; exit 1
fi
exit 0
SH
chmod +x "$T/fakebin/gh"
sed -n '/^load_env() {/,/^}/p' "$DIR/fly/builder-runner.sh" > "$T/load_env.sh"
grep -q '^load_env() {' "$T/load_env.sh" || bad "S7 could not lift load_env from fly/builder-runner.sh"
# s7 <harness-root> — run load_env then a real gh_rest read; prints "rc status".
s7() {
  fixture 'HARNESS_SECRET=x\nGH_TOKEN=stale-tok\n' 'fresh-tok\n'
  : > "$T/env/p.env"; : > "$T/runner.log"
  ( export PATH="$T/fakebin:$PATH" HOME="$T" HARNESS_DEPLOYMENT_FILE=/dev/null
    unset GH_TOKEN
    HARNESS="$1" ENVDIR="$T/env" PROJECT=p
    log() { printf '%s\n' "$*" >> "$T/runner.log"; }
    live_git_credentials() { :; }
    . "$T/load_env.sh"
    load_env
    . "$DIR/bin/lib/gh-rest.sh" || exit 98
    gh_rest GET repos/o/r/issues/1/events >/dev/null 2>&1; rc=$?
    printf '%s %s\n' "$rc" "$GH_REST_STATUS" ) 2>/dev/null
}
R=$(s7 "$H")
[ "$R" = "0 200" ] && ok || bad "S7 after load_env a gh_rest read must answer rc 0 / 200 (got '$R')"
grep -qx 'GH_TOKEN=fresh-tok' "$ENVF" && ok || bad "S7 load_env must leave global.env holding the live token"
grep -qx 'load_env: GH_TOKEN in global.env synced from the rotated token file' "$T/runner.log" \
  && ok || bad "S7 load_env must log the sync: $(cat "$T/runner.log")"
# Control: a synced tree that predates the lib skips quietly, and that is the 401.
mkdir -p "$T/old/bin/lib"
R=$(s7 "$T/old")
[ "$R" = "75 401" ] && ok || bad "S7 control without the lib must answer rc 75 / 401 (got '$R')"
[ -s "$T/runner.log" ] && bad "S7 control must log nothing: $(cat "$T/runner.log")" || ok

# ══ S8 hub rotation payload (the rotate suite's scaffold, copied) ═══════════
command -v jq >/dev/null || { echo "jq missing — skipping S8"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit; }
unset POOL_AUTOSCALE POOL_CAP_MAX GH_APP_TOKENS GH_APP_ROTATE 2>/dev/null
P="$T/p"
mkdir -p "$P/bin/lib" "$P/logs" "$P/flags" "$P/locks" "$P/env" "$P/fly" \
         "$P/state/fly" "$P/state/fly-pool/project-5" "$P/state/build-queue/project-5" \
         "$P/builds" "$T/rec"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$P/bin/"
scratch_install_closure bin/lib/gh-app-auth.sh "$P" >/dev/null || bad "S8 cannot install the gh-app-auth closure"
scratch_install_closure bin/lib/gh-token-live.sh "$P" >/dev/null || bad "S8 cannot install the gh-token-live closure"
printf 'HARNESS_SECRET=test-secret\n' > "$P/env/global.env"
: > "$P/env/fly.env"
printf 'GH_APP_ID=778899\n' > "$P/env/github-app.env"
printf 'pool-project-5\n' > "$P/flags/fly-pool-app-project-5"
: > "$P/flags/fly-pool-project-5"
printf '{"app":"pool-project-5"}\n' > "$P/state/fly/project-5.json"
printf 'registry.fly.io/builder-project-5:deployment-01\n' > "$P/state/fly/project-5.image"
printf '#!/bin/bash\nexit 0\n' > "$P/bin/beat.sh"
printf '#!/bin/bash\n[ "$2" = repo ] && { echo TestOwner/project-5; exit 0; }\nexit 1\n' > "$P/bin/fleet-conf.sh"
printf '#!/bin/bash\nmkdir -p "$2"; printf "GH_TOKEN=pattok\\n" > "$2/global.env"; printf "REPO_SLUG=TestOwner/project-5\\n" > "$2/$1.env"; exit 0\n' > "$P/bin/fly-envbundle.sh"
cat > "$P/bin/gh-token.sh" <<'SH'
#!/bin/bash
case "$*" in
  *--expires-at*) date -u -d "+1 hour" '+%Y-%m-%dT%H:%M:%SZ'; exit 0 ;;
  *--installation-id*) echo 4242; exit 0 ;;
esac
printf 'ghs_rotated\n'
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# flyctl, stubbed. Every console payload is UNQUOTED the way /bin/sh would read
# it (mexec quotes it with printf %q) and recorded one per line, in order.
# The unquoting is a declare, not `eval "set -- $CMD"`: an eval traces with the
# %q text as its argument, and bin/test-trace-safety.sh reads a literal
# `2\>/dev/null\ ` in an interpreter's argument as a redirect to `/dev/null\ `
# (a path outside the scratch tree), though nothing is ever redirected here.
# declare does the same quote removal on the same %q text without being one.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
MID=""; CMD=""
case "$1 $2" in
  "machine status") echo "State: started"; exit 0 ;;
  "machines list")  echo '[]'; exit 0 ;;
  "ssh console")    ;;
  *) exit 0 ;;
esac
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --machine) MID="$2"; shift 2 ;;
    -C) CMD="$2"; shift 2 ;;
    -a) shift 2 ;;
    *) shift ;;
  esac
done
declare -a ARGV="($CMD)"
printf '%s\t%s\n' "$MID" "${ARGV[2]}" >> "$PREC/console.log"
case "${ARGV[2]}" in
  *harness-env/gh-token*) [ "${FLY_PUSH_FAIL:-0}" = 1 ] && exit 1 ;;
  *gh_token_live_sync_env*) [ "${FLY_SYNC_FAIL:-0}" = 1 ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$P/bin"/*.sh "$T/fakebin"/*
ts() { date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
MID=aa11bb22cc33dd
MF="$P/state/fly-pool/project-5/$MID.json"
machine() {
  rm -f "$P/state/fly-pool/project-5"/*.json
  jq -nc --arg m "$MID" --arg ts "$(ts now)" --arg e "$(ts "$1")" \
    '{machine:$m,key:"TK-1",ticket_id:"1",attempt:0,deferrals:0,deaths:0,spawned_at:$ts,gh_token_expires_at:$e}' > "$MF"
}
tick() {
  : > "$P/logs/fly-pool.log"; rm -f "$T/rec"/*; : > "$T/rec/console.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$P" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_PROJECT_5=tok PREC="$T/rec" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
SYNC='gh_token_live_sync_env /run/harness-env/global.env'
nsync() { grep -cF "$SYNC" "$T/rec/console.log"; }
B64_ROTATED=$(printf 'ghs_rotated\n' | base64 -w0)

machine '+10 minutes'; tick
grep -q 'rotated App token on' "$P/logs/fly-pool.log" && ok || bad "S8 the due machine must rotate: $(cat "$P/logs/fly-pool.log")"
[ "$(nsync)" = 1 ] && ok || bad "S8 one sync payload after a pushed token (got $(nsync)): $(cut -c1-160 "$T/rec/console.log")"
LPUSH=$(grep -n 'harness-env/gh-token' "$T/rec/console.log" | head -1 | cut -d: -f1)
LSYNC=$(grep -nF "$SYNC" "$T/rec/console.log" | head -1 | cut -d: -f1)
[ -n "$LPUSH" ] && [ -n "$LSYNC" ] && [ "$LSYNC" -gt "$LPUSH" ] \
  && ok || bad "S8 the sync must come after the gh-token push (push line ${LPUSH:-none}, sync line ${LSYNC:-none})"
SPAY=$(grep -F "$SYNC" "$T/rec/console.log" | head -1 | cut -f2-)
grep -qE "ghs_rotated|$B64_ROTATED" <<< "$SPAY" && bad "S8 the sync payload carries the token a second time" || ok
grep -F "$SYNC" "$T/rec/console.log" | cut -f1 | grep -qx "$MID" && ok || bad "S8 the sync must target the rotated machine"
grep -q 'could not sync GH_TOKEN' "$P/logs/fly-pool.log" && bad "S8 a clean sync must say nothing about failing" || ok
# The payload as delivered works: run it with the machine paths pointed at scratch.
MH="$T/mh"; ME="$T/menv"; mkdir -p "$MH/flags" "$ME"
scratch_install_closure bin/lib/gh-token-live.sh "$MH" >/dev/null || bad "S8 cannot install the machine closure"
printf 'A=1\nGH_TOKEN=pattok\n' > "$ME/global.env"; printf 'ghs_live\n' > "$ME/gh-token"
RUN=$(sed "s#/data/harness#$MH#g; s#/run/harness-env#$ME#g" <<< "$SPAY")
/bin/sh -c "$RUN" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx 'GH_TOKEN=ghs_live' "$ME/global.env" \
  && ok || bad "S8 the delivered sync payload must work under /bin/sh (rc $rc): $(cat "$ME/global.env")"

machine '+10 minutes'; tick FLY_PUSH_FAIL=1
[ "$(nsync)" = 0 ] && ok || bad "S8 a failed push must send no sync payload (got $(nsync))"
grep -q 'could not push the rotated App token' "$P/logs/fly-pool.log" && ok || bad "S8 a failed push must say so"

machine '+10 minutes'; tick FLY_SYNC_FAIL=1
grep -q "$MID: pushed a fresh App token but could not sync GH_TOKEN in its global.env" "$P/logs/fly-pool.log" \
  && ok || bad "S8 a failed sync must say so: $(cat "$P/logs/fly-pool.log")"
grep -q 'rotated App token on' "$P/logs/fly-pool.log" && ok || bad "S8 a failed sync must not stop the rotation"
[ -n "$(jq -r '.gh_token_rotated_at // ""' "$MF")" ] && ok || bad "S8 a failed sync still stamps the record"

# ══ S9 load_env's shape ═════════════════════════════════════════════════════
[ "$(grep -v '^[[:space:]]*#' "$T/load_env.sh" | grep -v '^}' | tail -1 | tr -d ' ')" = live_git_credentials ] \
  && ok || bad "S9 load_env must still end with live_git_credentials"
[ "$(grep -v '^[[:space:]]*#' "$T/load_env.sh" | grep -c 'gh auth setup-git')" = 1 ] \
  && ok || bad "S9 load_env must keep exactly one gh auth setup-git"
SL=$(grep -n 'gh_token_live_sync_env' "$T/load_env.sh" | head -1 | cut -d: -f1)
AL=$(grep -n 'set -a' "$T/load_env.sh" | head -1 | cut -d: -f1)
[ -n "$SL" ] && [ -n "$AL" ] && [ "$SL" -lt "$AL" ] && ok || bad "S9 the sync must run before set -a sources global.env"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
