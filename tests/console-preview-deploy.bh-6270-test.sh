#!/bin/bash
# tests/console-preview-deploy.bh-6270-test.sh — the streak head, the retry and
# the 401/403/429 classifier of bin/console-preview-deploy.sh (BH-6270, the
# four NOTEs of lead review lr-6056-72e007976067).
#
# Drives the REAL hub lane against a scratch harness (scratch_install_closure),
# a scratch origin with refs/pull/<n>/head, and stubs for gh, npm, npx
# (wrangler), curl and node.
#
#   S1  after a charge `failed 1`, the streak survives: the next run with a new
#       later head raises no console-preview-box alert, deploys the later head,
#       and charges the streak head `failed 2` with its terminal comment
#   S2  a retry that uploads runs QA and posts the comment: record done, the
#       preview marker and `QA: PASS for head <sha>`, no upload on the next run
#   S3a the loop stopped on a later head's box fault: no retry, no charge
#   S3b a build-stage box fault (npm ci leaves a build-uid process) on the retry: one
#       console-preview-box alert naming the pending PR, no record
#   S3c only an EARLIER head uploaded: no retry, no alert, no record, and that
#       upload does not clear the streak
#   S4  an upload error is the head's or the box's by its error text: a status
#       code inside a file name (dist/403.html) is the head's
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-preview-deploy.bh-6270-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git jq flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
[ -f "$DIR/bin/console-preview-deploy.sh" ] && [ -f "$DIR/bin/lib/console-preview.sh" ] \
  || { echo "FAIL: bin/console-preview-deploy.sh or bin/lib/console-preview.sh does not exist"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONSOLE_PREVIEW_DEPLOY CONSOLE_PREVIEW_MAX_PER_RUN CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN \
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_QA_SCREENS CONSOLE_PREVIEW_WRANGLER CONSOLE_PREVIEW_MAX_ATTEMPTS
SLUG=o/console-fixture
AUTH='✘ [ERROR] A request to the Cloudflare API failed. Authentication error [code: 10000]'

# ── fixture: origin with PR refs, a hub checkout, a scratch harness ───────────
O="$T/origin.git"; W="$T/work"; CK="$T/ck"; HB="$T/h"
git init -q --bare -b main "$O"; git init -q -b main "$W"
mkdir -p "$W/console-ui/src" "$W/console-ui/functions/api" "$W/worker/jobs" "$W/catalog"
echo '{"name":"console-ui"}' > "$W/console-ui/package.json"
echo 'export const who = "main";' > "$W/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$W/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$W/worker/jobs/wrangler.jsonc"
echo '{}' > "$W/catalog/x.json"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
pr() { # pr <n> -> head sha of a PR that changes console-ui/src/app.js
  git -C "$W" checkout -q -B "pr$1" main
  echo "change $1" >> "$W/console-ui/src/app.js"; git -C "$W" commit -qam "pr $1"
  git -C "$W" push -q "$O" "HEAD:refs/pull/$1/head"
  git -C "$W" rev-parse HEAD
}
S11=$(pr 11); S14=$(pr 14); S16=$(pr 16)
git clone -q "$O" "$CK"

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin"
scratch_install_closure bin/console-preview-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-preview-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=%s\n' tok-fixture-6270 > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=%s\n' hsec-fixture-6270-not-real > "$HB/env/global.env"
QATOK="1791700000.$(printf 'cd%.0s' $(seq 1 32))"
CLEAN_PROJECT='{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"VITE_X":{"value":"1"}}}}}}'

cat > "$T/sbin/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/calls.log"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    all="\$*"; n=\${all#*/issues/}; n=\${n%%/*}
    for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" > "$T/posted-\$n" ;; esac; done
    send 201 '{"id":1}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*) send 200 '[]' ;;
  *"-X GET repos/"*"/pulls"*) send 200 "\$(cat "$T/openprs")" ;;
esac
exit 0
EOF
# npm: npm.ci125 <k> makes the k-th npm ci (counted in npm.cicnt) leave a
# process of the build uid behind (npm.busy, read by the pgrep stub), so
# cpv_run_unpriv returns 125 from its post-check and the lane reads a build that
# cannot be isolated (a box fault). A command's own rc 125 is the head's
# (BH-6073), so the fixture does not exit 125.
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  ci) echo x >> "$T/npm.cicnt"
      [ -f "$T/npm.ci125" ] && [ "\$(wc -l < "$T/npm.cicnt")" = "\$(cat "$T/npm.ci125")" ] && touch "$T/npm.busy"
      exit 0 ;;
  run) [ "\$2" = build ] && { mkdir -p dist; echo '<html>' > dist/index.html; exit 0; } ;;
esac
exit 1
EOF
# npx: every sha listed in npx.failshas fails its upload with npx.failmsg.
# npx.failn.<sha> <k> makes that sha fail only its first k uploads.
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
all=" \$* "; sha=\${all#* --commit-hash }; sha=\${sha%% *}
if grep -qx "\$sha" "$T/npx.failshas" 2>/dev/null; then
  if [ -f "$T/npx.failn.\$sha" ]; then
    echo x >> "$T/npx.cnt.\$sha"
    [ "\$(wc -l < "$T/npx.cnt.\$sha")" -le "\$(cat "$T/npx.failn.\$sha")" ] && { cat "$T/npx.failmsg"; exit 1; }
  else
    cat "$T/npx.failmsg"; exit 1
  fi
fi
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit 0
EOF
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/calls.log"
case "\$*" in
  *"/pages/projects/"*) cat "$T/cfproject" ;;
  *"/api/qa/session"*) printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'node %s\n' "\$*" >> "$T/calls.log"
printf 'SCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: PASS\n'; exit 0
STUB
# pgrep: for -u/-U $BU (the build uid of every run) it answers 4270 once
# npm.busy exists and nothing before; anything else goes to the real pgrep.
BU=61270; REALPG=$(command -v pgrep)
cat > "$T/sbin/pgrep" <<EOF
#!/bin/bash
if [ "\$#" = 2 ] && { [ "\$1" = -u ] || [ "\$1" = -U ]; } && [ "\$2" = "$BU" ]; then
  [ -f "$T/npm.busy" ] && { echo 4270; exit 0; }
  exit 1
fi
exec "$REALPG" "\$@"
EOF
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
chmod +x "$T/sbin/"* "$HB/bin/lane-alert.sh"

prjson() { # prjson <n> <branch> <sha>
  jq -nc --argjson n "$1" --arg b "$2" --arg s "$3" --arg r "$SLUG" \
    '{number:$n, head:{ref:$b, sha:$s, repo:{full_name:$r}}, base:{ref:"main"}}'
}
setprs() { printf '%s\n' "$@" | jq -sc . > "$T/openprs"; }
P11=$(prjson 11 ticket/bh-11 "$S11"); P14=$(prjson 14 ticket/bh-14 "$S14"); P16=$(prjson 16 ticket/bh-16 "$S16")
reset() {
  rm -f "$T"/posted-* "$T"/npx.* "$T"/npm.*
  printf '%s\n' "$CLEAN_PROJECT" > "$T/cfproject"
  scratch_rm "$HB/state/console-preview-deploy"; : > "$T/calls.log"
}
# run: one lane tick; calls.log holds THIS tick's calls only.
run() {
  : > "$T/calls.log"
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T" \
      HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CPV_TEST_UID="$BU" CONSOLE_PREVIEW_BUILD_TMP="$T" \
      CONSOLE_PREVIEW_DEPLOY=1 CONSOLE_PAGES_URL=https://pages-fixture.example.invalid \
      bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
  RC=$?
}
rec()     { cat "$HB/state/console-preview-deploy/$1" 2>/dev/null; }
uploads() { grep -c "^npx .*pages deploy .*--commit-hash $1 " "$T/calls.log"; }
alerts()  { grep -c '^alert .*--id console-preview-box ' "$T/calls.log"; }
URL11=https://ticket-bh-11.pages-fixture.example.invalid

# ── S1: the streak survives a charge ──────────────────────────────────────────
reset; setprs "$P11" "$P14"; echo "$S11" > "$T/npx.failshas"; echo "$AUTH" > "$T/npx.failmsg"
run; run; run
[ "$(rec "$S11")" = "failed 1" ] && [ "$(rec "$S14")" = done ] && ok \
  || bad "S1 setup: run 3 charges 11 once and deploys 14: 11='$(rec "$S11")' 14='$(rec "$S14")' $(cat "$T/out")"
setprs "$P11" "$P14" "$P16"; run
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC"
[ "$(alerts)" = 0 ] && ok || bad "S1 run 4 must raise no console-preview-box alert: $(grep '^alert' "$T/calls.log")"
[ "$(uploads "$S16")" = 1 ] && [ "$(rec "$S16")" = done ] && [ -s "$T/posted-16" ] && ok \
  || bad "S1 run 4 deploys and comments PR 16: uploads=$(uploads "$S16") rec='$(rec "$S16")' $(cat "$T/out")"
[ "$(rec "$S11")" = "failed 2" ] && ok || bad "S1 run 4 charges 11 a second time: '$(rec "$S11")'"
grep -q "Console preview: not deployed for head $S11" "$T/posted-11" 2>/dev/null \
  && grep -q "<!-- console-preview-failed sha=$S11 -->" "$T/posted-11" && ok \
  || bad "S1 the terminal comment for 11: $(cat "$T/posted-11" 2>/dev/null)"
[ -e "$HB/state/console-preview-deploy/.box-streak" ] && bad "S1 a terminal charge must remove the streak: $(cat "$HB/state/console-preview-deploy/.box-streak")" || ok
run
[ "$(uploads "$S11")" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "S1 a terminal head is not tried again: uploads=$(uploads "$S11") $(grep '^alert' "$T/calls.log")"

# ── S2: a retry that uploads runs QA and posts the comment ────────────────────
reset; setprs "$P11" "$P14"; echo "$S11" > "$T/npx.failshas"; echo "$AUTH" > "$T/npx.failmsg"; echo 3 > "$T/npx.failn.$S11"
run; run; run
[ "$(uploads "$S11")" = 2 ] && ok || bad "S2 run 3 tries 11 in the loop and once more in the retry: $(uploads "$S11")"
[ "$(rec "$S11")" = done ] && ok || bad "S2 a retry that uploads records done: '$(rec "$S11")' $(cat "$T/out")"
grep -qx "<!-- console-preview sha=$S11 url=$URL11 -->" "$T/posted-11" 2>/dev/null && ok || bad "S2 the preview marker: $(cat "$T/posted-11" 2>/dev/null)"
grep -q "^QA: PASS for head $S11\." "$T/posted-11" 2>/dev/null && ok || bad "S2 QA: PASS for the head: $(cat "$T/posted-11" 2>/dev/null)"
grep -qF "node $HB/bin/console-qa-run.mjs $URL11 " "$T/calls.log" && ok || bad "S2 the QA driver ran for PR 11: $(grep '^node' "$T/calls.log")"
grep -q 'deploys 2 ' "$T/out" && ok || bad "S2 the summary counts the retry deploy: $(tail -n 1 "$T/out")"
run
[ "$(uploads "$S11")" = 0 ] && ok || bad "S2 run 4 must not upload 11 again: $(grep '^npx' "$T/calls.log")"

# ── S3a: no retry after the loop stopped on a box fault ───────────────────────
reset; setprs "$P11" "$P14" "$P16"; printf '%s\n' "$S11" "$S16" > "$T/npx.failshas"; echo "$AUTH" > "$T/npx.failmsg"
run; run; run
[ "$(uploads "$S14")" = 1 ] && [ "$(uploads "$S16")" = 1 ] && [ "$(alerts)" = 1 ] && ok \
  || bad "S3a setup: run 3 deploys 14 and stops at 16: 14=$(uploads "$S14") 16=$(uploads "$S16") alerts=$(alerts)"
[ "$(uploads "$S11")" = 1 ] && ok || bad "S3a no retry of 11 after a box stop: $(uploads "$S11") uploads"
[ -z "$(rec "$S11")" ] && ok || bad "S3a 11 must not be charged after a box stop: '$(rec "$S11")'"

# ── S3b: a build-stage box fault on the retry raises the alert ────────────────
reset; setprs "$P11" "$P14"; echo "$S11" > "$T/npx.failshas"; echo "$AUTH" > "$T/npx.failmsg"
run; run
rm -f "$T/npm.cicnt"; echo 3 > "$T/npm.ci125"; run
[ "$(grep -c '^npm ci' "$T/calls.log")" = 3 ] && ok || bad "S3b setup: three npm ci calls in run 3: $(grep -c '^npm ci' "$T/calls.log")"
[ "$(alerts)" = 1 ] && ok || bad "S3b one console-preview-box alert: $(grep '^alert' "$T/calls.log")"
grep '^alert .*--id console-preview-box ' "$T/calls.log" | grep -q "build not isolated.*(PR #11 head ${S11:0:12})" && ok \
  || bad "S3b the alert names the build fault and PR #11: $(grep '^alert' "$T/calls.log")"
[ -z "$(rec "$S11")" ] && ok || bad "S3b a box fault charges no head: '$(rec "$S11")'"

# ── S3c: only a LATER head proves the box ─────────────────────────────────────
reset; setprs "$P11"; echo "$S11" > "$T/npx.failshas"; echo "$AUTH" > "$T/npx.failmsg"
run; run
setprs "$P16" "$P11"; run
[ "$(uploads "$S16")" = 1 ] && [ "$(rec "$S16")" = done ] && [ -s "$T/posted-16" ] && ok \
  || bad "S3c PR 16 deploys and is commented: uploads=$(uploads "$S16") rec='$(rec "$S16")'"
[ "$(alerts)" = 0 ] && ok || bad "S3c an earlier upload must not clear the streak (no box alert): $(grep '^alert' "$T/calls.log")"
[ "$(uploads "$S11")" = 1 ] && ok || bad "S3c no retry when only an earlier head uploaded: $(uploads "$S11") uploads"
[ -z "$(rec "$S11")" ] && ok || bad "S3c 11 is not charged: '$(rec "$S11")'"

# ── S4: the error text says whose fault an upload failure is ──────────────────
s4() { # s4 <want head|box> <wrangler error line>
  reset; setprs "$P11" "$P14"; echo "$S11" > "$T/npx.failshas"; printf '%s\n' "$2" > "$T/npx.failmsg"; run
  if [ "$1" = head ]; then
    [ "$(rec "$S11")" = "failed 1" ] && [ "$(alerts)" = 0 ] && [ "$(uploads "$S14")" = 1 ] && ok \
      || bad "S4 head: '$2': rec='$(rec "$S11")' alerts=$(alerts) 14 uploads=$(uploads "$S14")"
  else
    [ -z "$(rec "$S11")" ] && [ "$(alerts)" = 1 ] && [ "$(uploads "$S14")" = 0 ] && ok \
      || bad "S4 box: '$2': rec='$(rec "$S11")' alerts=$(alerts) 14 uploads=$(uploads "$S14")"
  fi
}
s4 head '✘ [ERROR] Error: Pages only supports files up to 25 MiB in size. dist/403.html is 31 MiB in size'
s4 head '✘ [ERROR] Invalid _redirects: line 3 /old /errors/429.html 301'
s4 head '✘ [ERROR] dist/401.html is too large'
# A file name with no extension: only the error-word anchor keeps this the head's.
s4 head '✘ [ERROR] Error: Pages only supports files up to 25 MiB in size. dist/assets/403 is 31 MiB in size'
s4 box  "$AUTH"
s4 box  '✘ [ERROR] Received a bad response from the API: HTTP 403'
s4 box  '✘ [ERROR] upload failed with status: 429'
s4 box  '✘ [ERROR] Error 401.'

[ -n "${DEBUG_T:-}" ] && cat "$T/calls.log"
echo "console-preview-deploy.bh-6270: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
