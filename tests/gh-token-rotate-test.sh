#!/bin/bash
# tests/gh-token-rotate-test.sh — a builder's GitHub token must outlive its build.
#
# THE INCIDENT (2026-09-14 13:44-14:15Z, project-5 pool). bin/fly-pool.sh swaps the
# fleet PAT for a repo-scoped GitHub App installation token in each pool machine's
# env bundle. An installation token lives exactly ONE HOUR; the cache hands one out
# until 5 minutes before that; a pool build takes 40-75 minutes. TK-680/681/682
# were spawned 13:29Z on a token minted 12:42Z, finished, and their pre-PR push at
# 13:53-14:01Z answered `remote: Invalid username or token. Password authentication
# is not supported for Git operations.` Three finished builds were thrown away and
# requeued; seven more machines were destroyed and the orchestrator fell the whole
# fleet back to the PAT with flags/gh-app-tokens-off.
#
# What is proved here, in the order a reader cares about it:
#   1. SPAWN ships a token with a life the build can spend, records WHEN it dies on
#      the machine record, and writes it to /run/harness-env/gh-token as well as to
#      the bundle's GH_TOKEN= line.
#   2. The tick ROTATES a live machine inside POOL_GH_TOKEN_ROTATE_BEFORE of expiry
#      — and leaves alone one that is not due, one rotated in the last 30 minutes,
#      and one whose record carries no expiry at all.
#   3. A replacement is shipped ONLY when it is genuinely newer, which is what keeps
#      the PAT (what bin/gh-token.sh prints when a mint fails) off the machine.
#   4. gh_token_live prefers the file and leaves the environment alone without it,
#      and fly/gh-credential.sh speaks git-credential over the same file.
#   5. Every kill flag: GH_APP_TOKENS=0 / flags/gh-app-tokens-off is the whole path
#      off, GH_APP_ROTATE=0 / flags/gh-app-rotate-off is the rotation only.
# Run from anywhere: tests/gh-token-rotate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX GH_APP_TOKENS GH_APP_ROTATE 2>/dev/null

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" "$H/state/build-queue/project-5" \
         "$H/builds" "$T/fakebin" "$T/rec"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-token-live.sh" "$H/bin/lib/"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
# Armed: gh_auth_armed wants this file to exist and bin/gh-token.sh to be runnable.
# No key and no App id — the mint itself is stubbed, and tests/gh-token-test.sh is
# where the real signing is driven.
printf 'GH_APP_ID=778899\n' > "$H/env/github-app.env"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
: > "$H/flags/fly-pool-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/builder-project-5:deployment-01\n' > "$H/state/fly/project-5.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\n[ "$2" = repo ] && { echo TestOwner/project-5; exit 0; }\nexit 1\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nmkdir -p "$2"; printf "GH_TOKEN=pattok\\n" > "$2/global.env"; printf "REPO_SLUG=TestOwner/project-5\\n" > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# bin/gh-token.sh, stubbed: every argv is logged so the --min-life ask is an
# assertion, and the expiry it reports is controllable per case.
cat > "$H/bin/gh-token.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GHTOK_LOG"
case "$*" in
  *--expires-at*) date -u -d "${GHTOK_EXP:-+1 hour}" '+%Y-%m-%dT%H:%M:%SZ'; exit 0 ;;
esac
[ "${GHTOK_FAILS:-0}" = 1 ] && { printf 'pattok\n'; exit 0; }
printf '%s\n' "${GHTOK_VALUE:-ghs_rotated}"
SH
# `gh`, stubbed: THERE IS NO GITHUB IN THIS FIXTURE, and until BH-469 nothing
# said so. bin/fly-pool.sh's spawn gates (BH-1075) are applicable only when
# gh_rest_read comes back with an HTTP status line, and gh_rest_read runs `gh
# api -i`, which prints that line on stdout even on a 4xx. So whether section 1
# spawns AT ALL depended on the host: no gh on PATH (this repo's docker image)
# -> no status line -> gates inactive -> spawn; a real gh WITH a token (a
# GitHub Actions runner, once the tick has armed one) -> `HTTP/2.0 401` on
# stdout -> gates ACTIVE -> the HOLD gate reads TestOwner/project-5 as a held
# ticket and the row is skipped, so no machine record is written and six
# assertions fail. Measured both ways on THIS tree and on origin/main: a gh
# stub that emits a status line reproduces the same 54 pass / 6 fail on both,
# so the fixture, not either branch, is what was wrong. A client that cannot
# reach GitHub is the truth here, and it is now stated rather than inherited.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# flyctl, stubbed. `ssh console -C` is the one that matters: mput rides it, so the
# stub decodes the base64 the pool pushed and records both the bytes and the path.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
MID=""; CMD=""; MODE=""
case "$1 $2" in
  "machine status") MID="$3"; echo "State: ${FLY_STATE:-started}"; exit 0 ;;
  "machines list")  echo '[]'; exit 0 ;;
  "machine run")    printf 'Machine ID: %s\n' "$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')"; exit 0 ;;
  "ssh console")    MODE=console ;;
  "ssh sftp")       exit 0 ;;
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
# mexec quotes its payload with printf %q, so the recorder matches the PATH (which
# survives the quoting intact) and keeps the command verbatim — the caller asserts
# on the base64 it expects to find in it rather than re-implementing the decode.
# PREC, not REC: bin/fly-pool.sh's SPAWN section has its own `REC=` (the recorded
# image ref), and an exported REC is overwritten by it halfway through the tick —
# which showed up here as a recorder that worked for the reap and not for the spawn.
case "$CMD" in
  *harness-env/gh-token*)
    printf '%s' "$CMD" > "$PREC/token-$MID"
    printf '%s\n' "$MID" >> "$PREC/token-pushes"; exit 0 ;;
  *) exit 0 ;;                       # every other mput, the RESULT read, the heartbeat
esac
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

ts() { date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
MID=aa11bb22cc33dd
MF="$H/state/fly-pool/project-5/$MID.json"
machine() { # machine <expires-at-offset|-> [rotated-at-offset]
  rm -f "$H/state/fly-pool/project-5"/*.json
  jq -nc --arg m "$MID" --arg ts "$(ts now)" \
     --arg e "$([ "$1" = - ] || ts "$1")" --arg r "$([ -z "${2:-}" ] && echo "" || ts "$2")" \
    '{machine:$m,key:"TK-1",ticket_id:"1",attempt:0,deferrals:0,deaths:0,spawned_at:$ts}
     + (if $e == "" then {} else {gh_token_expires_at:$e} end)
     + (if $r == "" then {} else {gh_token_rotated_at:$r} end)' > "$MF"
}
tick() { # tick [VAR=VAL ...] — one bin/fly-pool.sh pass over the scratch tree
  : > "$H/logs/fly-pool.log"; : > "$T/ghtok.log"; rm -f "$T/rec"/*
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_project-5=tok PREC="$T/rec" GHTOK_LOG="$T/ghtok.log" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
rotated() { grep -c '^rotated App token' <(grep -o 'rotated App token.*' "$H/logs/fly-pool.log"); }

# ══ 1. SPAWN: freshness asked for, expiry recorded, token file pushed ════════
B64_ROTATED=$(printf 'ghs_rotated\n' | base64 -w0)
spawn_tick() { # spawn_tick [VAR=VAL ...] — one queued job, an empty pool, one tick
  rm -f "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json
  jq -nc '{ticket_id:"1",key:"TK-1",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/build-queue/project-5/TK-1.json"
  tick "$@"
}
spawn_tick
SPAWNED=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | head -1)
[ -n "$SPAWNED" ] && ok || bad "the spawn did not write a machine record"
grep -q -- '--min-life 3300 TestOwner/project-5' "$T/ghtok.log" \
  && ok || bad "spawn must ask for POOL_GH_TOKEN_MIN_LIFE of life (asked: $(cat "$T/ghtok.log"))"
[ -n "$(jq -r '.gh_token_expires_at // ""' "$SPAWNED" 2>/dev/null)" ] \
  && ok || bad "the machine record must carry the shipped token's expiry: $(cat "$SPAWNED")"
[ -s "$T/rec/token-pushes" ] && ok || bad "spawn must write the token to /run/harness-env/gh-token as well as the bundle"
grep -q "$B64_ROTATED" "$T/rec"/token-* 2>/dev/null \
  && ok || bad "the pushed token file does not carry the minted token"
# ...and with the whole path killed, neither happens and the bundle is today's.
spawn_tick GH_APP_TOKENS=0
[ ! -e "$T/rec/token-pushes" ] && ok || bad "GH_APP_TOKENS=0 must push no token file"
SPAWNED=$(ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | head -1)
[ -z "$(jq -r '.gh_token_expires_at // ""' "$SPAWNED" 2>/dev/null)" ] \
  && ok || bad "GH_APP_TOKENS=0 must record no expiry — there is no App token to expire"
[ -s "$T/ghtok.log" ] && bad "GH_APP_TOKENS=0 must not call bin/gh-token.sh at all" || ok
rm -f "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json

# Since BH-470's `# >>> gh default auth` region, every fly-pool tick reads the
# project's DEFAULT identity through bin/gh-token.sh — a bare `<owner/repo>`
# argv, which is a cache read in production and one logged line here, because
# the stub logs every argv. That read is not a rotation mint. Anything ELSE in
# the log (a `--min-life` ask, an `--expires-at` read) is a purchase the
# assertions below still forbid.
bought() { grep -qvx 'TestOwner/project-5' "$T/ghtok.log" 2>/dev/null; }

# ══ 2. ROTATE-DUE IS COMPUTED FROM expires_at ═══════════════════════════════
machine '+10 minutes'          # inside the 20-minute window
tick
[ "$(rotated)" = 1 ] && ok || bad "a token 10 minutes from expiry must be rotated (log: $(cat "$H/logs/fly-pool.log"))"
grep -qE 'rotated App token on aa11bb22cc33dd for TestOwner/project-5 \(expires [0-9]{2}:[0-9]{2}Z\)' "$H/logs/fly-pool.log" \
  && ok || bad "the rotation line must name the machine, the repo and the new expiry: $(grep -o 'rotated.*' "$H/logs/fly-pool.log")"
grep -q "$B64_ROTATED" "$T/rec/token-$MID" 2>/dev/null \
  && ok || bad "the rotated token was not pushed to the machine"
[ "$(jq -r '.gh_token_expires_at' "$MF")" != "$(ts '+10 minutes')" ] \
  && ok || bad "the machine record must carry the NEW expiry after a rotation"
[ -n "$(jq -r '.gh_token_rotated_at // ""' "$MF")" ] \
  && ok || bad "a rotation must stamp gh_token_rotated_at, or the 30-minute floor cannot hold"
grep -qE 'ghs_rotated|pattok' "$H/logs/fly-pool.log" \
  && bad "a token value reached logs/fly-pool.log" || ok

machine '+45 minutes'          # plenty of life: nothing to do, nothing bought
tick
[ "$(rotated)" = 0 ] && ok || bad "a token 45 minutes from expiry must NOT be rotated"
bought && bad "a machine that is not due must cost no mint" || ok

machine -                      # no expiry recorded: a PAT machine, or a pre-change record
tick
[ "$(rotated)" = 0 ] && ok || bad "a machine record with no expiry must be left entirely alone"
bought && bad "a record with no expiry must cost no mint" || ok

# ══ 3. NEVER TWICE IN 30 MINUTES ════════════════════════════════════════════
machine '+10 minutes' '-10 minutes'
EXP0=$(jq -r '.gh_token_expires_at' "$MF")
tick
[ "$(rotated)" = 0 ] && ok || bad "a machine rotated 10 minutes ago must not be rotated again"
[ "$(jq -r '.gh_token_expires_at' "$MF")" = "$EXP0" ] \
  && ok || bad "a skipped rotation must not rewrite the record"
machine '+10 minutes' '-40 minutes'
tick
[ "$(rotated)" = 1 ] && ok || bad "40 minutes after the last rotation, a due machine rotates again"
# The floor is a knob, not a constant.
machine '+10 minutes' '-10 minutes'
tick POOL_GH_TOKEN_ROTATE_EVERY=300
[ "$(rotated)" = 1 ] && ok || bad "POOL_GH_TOKEN_ROTATE_EVERY must move the 30-minute floor"
machine '+45 minutes'
tick POOL_GH_TOKEN_ROTATE_BEFORE=3600
[ "$(rotated)" = 1 ] && ok || bad "POOL_GH_TOKEN_ROTATE_BEFORE must move the due window"

# ══ 4. ONLY A GENUINELY NEWER TOKEN IS SHIPPED ══════════════════════════════
# bin/gh-token.sh prints the fleet PAT rather than nothing when a mint fails, and a
# PAT has no cache entry — so the expiry does not move. Shipping that to the
# machine would put the fleet's permanent credential back on a builder.
machine '+10 minutes'
EXP0=$(jq -r '.gh_token_expires_at' "$MF")
tick GHTOK_FAILS=1 GHTOK_EXP='+5 minutes'
[ "$(rotated)" = 0 ] && ok || bad "a mint that answered the PAT must not be logged as a rotation"
[ ! -e "$T/rec/token-$MID" ] && ok || bad "a PAT must never be pushed to the machine as a rotated App token"
grep -q 'no fresher App token' "$H/logs/fly-pool.log" \
  && ok || bad "a refused rotation must say so: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.gh_token_expires_at' "$MF")" = "$EXP0" ] \
  && ok || bad "a refused rotation must leave the record alone"

# ══ 5. KILL FLAGS ═══════════════════════════════════════════════════════════
machine '+10 minutes'
tick GH_APP_ROTATE=0
[ "$(rotated)" = 0 ] && ok || bad "GH_APP_ROTATE=0 must stop the rotation"
bought && bad "GH_APP_ROTATE=0 must cost no mint either" || ok
touch "$H/flags/gh-app-rotate-off"; machine '+10 minutes'; tick
[ "$(rotated)" = 0 ] && ok || bad "flags/gh-app-rotate-off must stop the rotation"
rm -f "$H/flags/gh-app-rotate-off"
machine '+10 minutes'; tick GH_APP_TOKENS=0
[ "$(rotated)" = 0 ] && ok || bad "GH_APP_TOKENS=0 must stop the rotation too — it stops everything"
touch "$H/flags/gh-app-tokens-off"; machine '+10 minutes'; tick
[ "$(rotated)" = 0 ] && ok || bad "flags/gh-app-tokens-off must stop the rotation"
rm -f "$H/flags/gh-app-tokens-off"
# ...and the rotation-only flag leaves the SPAWN swap armed, which is the whole
# point of it being a second flag.
spawn_tick GH_APP_ROTATE=0
grep -q -- '--min-life 3300 TestOwner/project-5' "$T/ghtok.log" \
  && ok || bad "GH_APP_ROTATE=0 must leave the spawn-time swap on"
rm -f "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json

# ══ 6. gh_token_live: the file wins, and without it nothing moves ═══════════
LIVE="$T/gh-token-file"
drive() { # drive <token-file-path> <snippet>
  ( export HARNESS="$H" GH_TOKEN_LIVE_FILE="$1" GH_TOKEN=bundletok
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-token-live.sh"; eval "$2" ) 2>/dev/null
}
printf 'ghs_rotated\n' > "$LIVE"
[ "$(drive "$LIVE" 'gh_token_live; printf %s "$GH_TOKEN"')" = ghs_rotated ] \
  && ok || bad "gh_token_live must prefer the file over the bundle's GH_TOKEN"
[ "$(drive "$T/nosuchfile" 'gh_token_live; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=bundletok" ] \
  && ok || bad "no file must be rc 1 with the environment untouched"
: > "$T/emptyfile"
[ "$(drive "$T/emptyfile" 'gh_token_live; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=bundletok" ] \
  && ok || bad "an empty token file must be rc 1, never an empty GH_TOKEN"
# A trailing newline in a credential is the CRON_SECRET class of bug.
printf '  ghs_rotated \n\n' > "$T/spacey"
[ "$(drive "$T/spacey" 'gh_token_live; printf %s "$GH_TOKEN"')" = ghs_rotated ] \
  && ok || bad "gh_token_live must strip whitespace from the file"
# The kill flags reach here too: a box that turns App tokens off stops reading one.
[ "$(drive "$LIVE" 'GH_APP_TOKENS=0 gh_token_live; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=bundletok" ] \
  && ok || bad "GH_APP_TOKENS=0 must make gh_token_live a no-op"
touch "$H/flags/gh-app-tokens-off"
[ "$(drive "$LIVE" 'gh_token_live; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=bundletok" ] \
  && ok || bad "flags/gh-app-tokens-off must make gh_token_live a no-op"
rm -f "$H/flags/gh-app-tokens-off"

# ══ 7. the git credential helper speaks the protocol, over the same file ════
cred() { ( export GH_TOKEN_LIVE_FILE="$1" GH_TOKEN="${2:-}"; "$DIR/fly/gh-credential.sh" get </dev/null ) 2>/dev/null; }
OUT=$(cred "$LIVE")
[ "$OUT" = "$(printf 'username=x-access-token\npassword=ghs_rotated')" ] \
  && ok || bad "the helper must print git-credential lines, got: $(printf '%s' "$OUT" | tr '\n' '/')"
[ "$(cred "$T/nosuchfile" bundletok | sed -n 's/^password=//p')" = bundletok ] \
  && ok || bad "with no file the helper must fall back to GH_TOKEN — that is today's behaviour"
[ -z "$(cred "$T/nosuchfile")" ] && ok || bad "no file and no GH_TOKEN must print nothing, not an empty password"
[ "$(cred "$LIVE" | grep -c .)" = 2 ] \
  && ok || bad "the helper must print exactly the two credential lines, got $(cred "$LIVE" | grep -c .)"
# store/erase are answered with silence: nothing here caches, so nothing forgets.
[ -z "$( ( export GH_TOKEN_LIVE_FILE="$LIVE"; "$DIR/fly/gh-credential.sh" store </dev/null ) 2>/dev/null )" ] \
  && ok || bad "the helper must print nothing for 'store'"
[ -x "$DIR/fly/gh-credential.sh" ] && ok || bad "fly/gh-credential.sh must be executable — it ships in the harness tarball"

# ══ 8. the wiring, asserted rather than trusted ═════════════════════════════
# bin/run-build.sh is a 3600-line pipeline that cannot be driven end to end here,
# and a call site that quietly disappears in a later edit is exactly the regression
# this change has to survive. So the ORDER is checked: the token is re-read
# immediately before each place this build spends it.
rbline() { grep -n -- "$1" "$RB_ALL" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
grep -q 'lib/gh-token-live.sh' "$RB_ALL" && ok || bad "run-build.sh does not source bin/lib/gh-token-live.sh"
grep -q 'command -v gh_token_live' "$RB_ALL" \
  && ok || bad "run-build.sh must guard the helper with command -v, for a box whose sync has not landed it"
for pat in 'RB_PUSH -u pr-push && track_pushed' 'gh pr create --head'; do
  L=$(rbline "$pat"); P=$(grep -n '^GH_LIVE$' "$RB_ALL" | cut -d: -f1 | awk -v l="$L" '$1 < l {v=$1} END {print v}')
  [ -n "$P" ] && [ "$P" -lt "$L" ] && ok || bad "no GH_LIVE before '$pat' (line $L)"
done
grep -qE '^\s*GH_LIVE$' "$RB_ALL" && ok || bad "run-build.sh never calls GH_LIVE"
[ "$(grep -cE '^\s*GH_LIVE$' "$RB_ALL")" -ge 5 ] \
  && ok || bad "run-build.sh must re-read the token at every spend point (found $(grep -cE '^\s*GH_LIVE$' "$RB_ALL"))"
grep -q 'lib/gh-token-live.sh' "$DIR/bin/board-closeout.sh" \
  && ok || bad "bin/board-closeout.sh must resolve the live token before its gh call"
# (BH-781) The issues-lane comment is gh_rest_comment, not gh issue comment.
CL=$(grep -n 'gh_rest_comment' "$DIR/bin/board-closeout.sh" | head -1 | cut -d: -f1)
GL=$(grep -n 'gh_token_live' "$DIR/bin/board-closeout.sh" | tail -1 | cut -d: -f1)
[ -n "$CL" ] && [ -n "$GL" ] && [ "$GL" -lt "$CL" ] \
  && ok || bad "board-closeout must read the live token BEFORE it comments (gh at $CL, read at $GL)"
grep -q 'gh-credential.sh' "$DIR/fly/builder-runner.sh" \
  && ok || bad "fly/builder-runner.sh does not install the call-time credential helper"
grep -q 'ENVDIR/gh-token' "$DIR/fly/builder-runner.sh" \
  && ok || bad "the helper install must be gated on the token file, so an unarmed machine keeps gh auth setup-git"
grep -q 'gh auth setup-git' "$DIR/fly/builder-runner.sh" \
  && ok || bad "gh auth setup-git must stay — it is the unarmed path"
# `gh auth setup-git` REPLACES credential.https://github.com.helper, so every call
# to it after load_env has to put the live helper back or the clone paths quietly
# hand the static token back for the rest of the build.
[ "$(grep 'gh auth setup-git' "$DIR/fly/builder-runner.sh" | grep -v '^[[:space:]]*#' | grep -cv live_git_credentials)" = 1 ] \
  && ok || bad "every gh auth setup-git after load_env must re-install the live credential helper"
grep -q 'live_git_credentials$' "$DIR/fly/builder-runner.sh" \
  && ok || bad "load_env must install the live credential helper"
grep -q -- '--min-life "$POOL_GH_TOKEN_MIN_LIFE"' "$DIR/bin/fly-pool.sh" \
  && ok || bad "bin/fly-pool.sh must ask bin/gh-token.sh for a minimum life"
grep -q 'gh_token_expires_at' "$DIR/bin/fly-pool.sh" \
  && ok || bad "bin/fly-pool.sh must record the shipped token's expiry on the machine record"

echo "gh-token-rotate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
