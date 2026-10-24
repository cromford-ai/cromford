#!/bin/bash
# tests/console-preview-deploy.bh-5909-test.sh — a PR that changes console-ui/
# gets ONE Cloudflare Pages preview deploy of its head, under its branch alias,
# a browser QA run of that preview as a read-only QA session, and ONE PR comment
# with the preview URL, QA COVERAGE, QA: PASS|FAIL and the head sha.
#
# Drives the REAL hub lane bin/console-preview-deploy.sh against a scratch
# harness (scratch_install_closure), a scratch origin with refs/pull/<n>/head,
# and stubs for gh (the REST envelope), npm and npx (wrangler).
#
#   A  cpv_alias / cpv_url (bin/lib/console-preview.sh): the Pages alias rule,
#      the host from console_pages_url, never `main`
#   P1 a console-ui diff: exactly one `pages deploy --branch ticket-bh-5909`
#      and one comment with the URL and the marker for the head sha
#   P2 a diff outside console-ui/ (docs/console-ui/, console-ui-old/): no deploy
#   P3 a marker for the head already on the PR: no deploy, no comment
#   P4 wrangler rc 1, or rc 0 with no "Deployment complete": no comment;
#      P4b a failure with no `error` line names the last wrangler line (BH-8251)
#   P5 max_per_run=1 with two console PRs: one deploy and a "deferred 1" line
#   P6 a fork PR: no deploy (the hub never builds code from outside the repo)
#   P7 a comments read that fails: no deploy (absent is not "no marker")
#   P8 no cloudflare.env: exit 0, no gh call at all
#   P9 the API token never reaches the lane's output
#   P10 the lane's own snapshot prefix; the checkout is untouched
#   P11 the build: npm ci --ignore-scripts, in its own tree, with a clean env
#   P12 a build that cannot drop privilege, or a dist with a symlink: no deploy
#   P13 the deploy tree holds no PR file but dist/: functions/ are main's even
#       when the PR changes them, and no package.json or .npmrc is there
#   P14 npx runs the pinned wrangler with npm's user and global config off and
#       the registry pinned; the account id is main's even when the PR moves it
#   P15 a preview environment with a D1 binding or a secret-named env var, or a
#       project config that does not read: no deploy, one alert
#   P16 QA PASS: the worker mints a session, the driver loads "/", and the
#       comment carries QA COVERAGE, `QA: PASS for head <sha>` and its marker
#   P17 QA FAIL: the failure lines and `QA: FAIL for head <sha>`
#   P18 no session minted: QA: FAIL saying so, the comment still posts
#   P19 HARNESS_SECRET and the QA token reach neither the output nor the comment
#   P20 the lane is off by default (CONSOLE_PREVIEW_DEPLOY unset)
#   P22 a failing build ahead of a good PR (lead BLOCK at 9935bb529): the
#       failure takes no MAX_PER_RUN slot, the good PR still deploys, the head
#       gets a failed record, and after CONSOLE_PREVIEW_MAX_ATTEMPTS (2) the
#       head is terminal: one comment says so, and later runs build nothing
#   P23 a fault of the box, not the head (lead BLOCK at 54f3dfea9): a build
#       user that does not exist, or a wrangler error, across 3 runs leaves no
#       failed record and posts no comment; each run raises the
#       console-preview-box alert and tries no further head; the head deploys
#       once the box is fixed
#   P26 a dist Pages refuses is charged to the head and the next PR deploys;
#       an unknown error, an npm 10 `npm error` (ENOSPC, ETARGET) and rc 137
#       are the box's
#   P27 a head that is the run's upload box fault 3 runs in a row is skipped,
#       and charged only when a later head uploads in that run; an account-wide
#       fault charges no head however many runs it lasts
#   P24 failing heads are capped per run at 2 x CONSOLE_PREVIEW_MAX_PER_RUN
#       build attempts; the rest are deferred to the next tick
#   P25 a comment POST that fails (403) is retried from the kept body with no
#       rebuild, counted against CONSOLE_PREVIEW_MAX_ATTEMPTS, then stops with
#       one console-preview-post alert: 3 runs make exactly 1 deploy
#   P21 a PR build that emits dist/_worker.js (a file, or a directory), a
#       dist/_routes.json or a dist/functions/: none of them is deployed, and
#       the deployed Functions are main's (a _worker.js would replace them)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-preview-deploy.bh-5909-test.sh
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
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_QA_SCREENS CONSOLE_PREVIEW_WRANGLER
SLUG=o/console-fixture
TOK=tok-fixture-5909

# ── A. the alias and the URL ─────────────────────────────────────────────────
( HARNESS="$DIR"; . "$DIR/bin/lib/console-preview.sh" || exit 9
  a() { cpv_alias "$1"; }
  [ "$(a ticket/bh-5909)" = ticket-bh-5909 ] || echo "A1 ticket/bh-5909 -> $(a ticket/bh-5909)"
  [ "$(a Feature/X_Y)" = feature-x-y ] || echo "A2 Feature/X_Y -> $(a Feature/X_Y)"
  long=ticket/bh-5909-a-very-long-branch-name-here
  [ "$(a "$long")" = ticket-bh-5909-a-very-long-b ] || echo "A3 a 40-char branch -> $(a "$long")"
  [ "$(a ticket/bh-5909-a-very-long-)" = ticket-bh-5909-a-very-long ] || echo "A4 no trailing dash: $(a ticket/bh-5909-a-very-long-)"
  a main >/dev/null && echo "A5 the alias main must be refused"
  a MAIN >/dev/null && echo "A5 the alias MAIN must be refused"
  a '///' >/dev/null && echo "A6 an all-dash alias must be refused"
  [ "$(a deadbeef)" = br-deadbeef ] || echo "A9 an 8-hex alias looks like a deployment hash: $(a deadbeef)"
  [ "$(a 0A1B2C3D)" = br-0a1b2c3d ] || echo "A9 an 8-hex alias (upper case): $(a 0A1B2C3D)"
  [ "$(a deadbeef0)" = deadbeef0 ] || echo "A9 a 9-hex alias is not a hash: $(a deadbeef0)"
  [ "$(CONSOLE_PAGES_URL=https://pages-fixture.example.invalid/ cpv_url ticket-bh-5909)" = https://ticket-bh-5909.pages-fixture.example.invalid ] \
    || echo "A7 url from CONSOLE_PAGES_URL: $(CONSOLE_PAGES_URL=https://pages-fixture.example.invalid/ cpv_url ticket-bh-5909)"
  [ "$(cpv_url x1)" = "https://x1.$(console_pages_url | sed 's#^https://##')" ] || echo "A8 the default host must be console_pages_url's: $(cpv_url x1)"
  exit 0
) > "$T/a.out" 2>&1; arc=$?
if [ "$arc" = 0 ] && [ ! -s "$T/a.out" ]; then ok; else bad "A: rc=$arc $(cat "$T/a.out")"; fi

# ── fixture: origin with PR refs, a hub checkout, a scratch harness ───────────
O="$T/origin.git"; W="$T/work"; CK="$T/ck"; HB="$T/h"
git init -q --bare -b main "$O"; git init -q -b main "$W"
mkdir -p "$W/console-ui/src" "$W/console-ui/functions/api" "$W/worker/jobs" "$W/catalog" "$W/docs/console-ui" "$W/console-ui-old" "$W/bin"
echo '{"name":"console-ui"}' > "$W/console-ui/package.json"
echo 'export const who = "main";' > "$W/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$W/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$W/worker/jobs/wrangler.jsonc"
echo '{}' > "$W/catalog/x.json"; echo n > "$W/docs/console-ui/n.md"; echo o > "$W/console-ui-old/o.js"; echo b > "$W/bin/x.sh"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
pr() { # pr <n> <file> -> head sha of a PR that changes <file>
  git -C "$W" checkout -q -B "pr$1" main
  echo "change $1" >> "$W/$2"; git -C "$W" commit -qam "pr $1"
  git -C "$W" push -q "$O" "HEAD:refs/pull/$1/head"
  git -C "$W" rev-parse HEAD
}
S11=$(pr 11 console-ui/src/app.js)
S12=$(pr 12 docs/console-ui/n.md); echo more >> "$W/console-ui-old/o.js"; git -C "$W" commit -qam p12b
git -C "$W" push -q -f "$O" "HEAD:refs/pull/12/head"; S12=$(git -C "$W" rev-parse HEAD)
S13=$(pr 13 console-ui/package.json)
S14=$(pr 14 console-ui/src/app.js)
# PR 15 rewrites a Function and adds an .npmrc; PR 16 moves the account id.
git -C "$W" checkout -q -B pr15 main
echo 'export const who = "pr";' > "$W/console-ui/functions/api/f.js"; echo 'registry=https://evil.example.invalid/' > "$W/console-ui/.npmrc"
git -C "$W" add -A; git -C "$W" commit -qm "pr 15"; git -C "$W" push -q "$O" "HEAD:refs/pull/15/head"; S15=$(git -C "$W" rev-parse HEAD)
git -C "$W" checkout -q -B pr16 main
echo '{ "account_id": "acct-from-the-pr" }' > "$W/worker/jobs/wrangler.jsonc"; echo more >> "$W/console-ui/src/app.js"
git -C "$W" commit -qam "pr 16"; git -C "$W" push -q "$O" "HEAD:refs/pull/16/head"; S16=$(git -C "$W" rev-parse HEAD)
# PR 17's build fails every time (the npm stub fails on console-ui/FAILBUILD).
git -C "$W" checkout -q -B pr17 main
echo fail > "$W/console-ui/FAILBUILD"; echo more17 >> "$W/console-ui/src/app.js"
git -C "$W" add -A; git -C "$W" commit -qm "pr 17"; git -C "$W" push -q "$O" "HEAD:refs/pull/17/head"; S17=$(git -C "$W" rev-parse HEAD)
# PRs 18 and 19 fail their build too (P24).
for n in 18 19; do
  git -C "$W" checkout -q -B "pr$n" main
  echo fail > "$W/console-ui/FAILBUILD"; echo "more$n" >> "$W/console-ui/src/app.js"
  git -C "$W" add -A; git -C "$W" commit -qm "pr $n"; git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"
done
S18=$(git -C "$W" rev-parse pr18); S19=$(git -C "$W" rev-parse pr19)
git clone -q "$O" "$CK"

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin"
scratch_install_closure bin/console-preview-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-preview-deploy.sh"
for f in bin/lib/console-preview.sh bin/lib/console-pages.sh bin/lib/gh-rest.sh; do
  [ -f "$HB/$f" ] && ok || bad "the closure of bin/console-preview-deploy.sh does not carry $f"
done
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$HB/env/cloudflare.env"
HSEC=hsec-fixture-5909-not-real
printf 'HARNESS_SECRET=%s\n' "$HSEC" > "$HB/env/global.env"
QATOK="1791700000.$(printf 'ab%.0s' $(seq 1 32))"
CLEAN_PROJECT='{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"VITE_X":{"value":"1"}}},"production":{"d1_databases":{"CONSOLE_DB":{"id":"x"}}}}}}'

cat > "$T/sbin/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/calls.log"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    all="\$*"; n=\${all#*/issues/}; n=\${n%%/*}
    for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" > "$T/posted-\$n" ;; esac; done
    send "\$(cat "$T/st-post" 2>/dev/null || echo 201)" '{"id":1}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    all="\$*"; n=\${all#*/issues/}; n=\${n%%/*}
    st=\$(cat "$T/st-comments-\$n" 2>/dev/null || echo 200)
    case "\$st" in 2*) send "\$st" "\$(cat "$T/comments-\$n.json" 2>/dev/null || echo '[]')" ;; *) send "\$st" '{"message":"stub"}' ;; esac ;;
  *"-X GET repos/"*"/pulls"*) send 200 "\$(cat "$T/openprs")" ;;
esac
exit 0
EOF
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s|cwd=%s\n' "\$*" "\$PWD" >> "$T/calls.log"
printf 'npmenv home=%s harness=%s secret=%s\n' "\$HOME" "\${HARNESS:-}" "\${SECRET_5909:-}" >> "$T/calls.log"
case "\$1" in
  ci) exit 0 ;;
  run) [ "\$2" = build ] && [ -f FAILBUILD ] && { echo "vite: fixture build failure"; exit 1; }
       [ "\$2" = build ] && { mkdir -p dist; echo '<html>' > dist/index.html
       [ -f "$T/distlink" ] && ln -s "$HB/env/cloudflare.env" dist/leak.txt
       case "\$(cat "$T/distworker" 2>/dev/null)" in
         file) echo 'export default { fetch() {} }' > dist/_worker.js ;;
         dir)  mkdir -p dist/_worker.js; echo 'export default {}' > dist/_worker.js/index.js ;;
       esac
       if [ -f "$T/distworker" ]; then echo '{"version":1}' > dist/_routes.json; mkdir -p dist/functions/api; echo pr > dist/functions/api/f.js; fi
       exit 0; } ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s|cwd=%s\n' "\$*" "\$PWD" >> "$T/calls.log"
uc=\${npm_config_userconfig:-}; gc=\${npm_config_globalconfig:-}
cfg=bad; [ -n "\$uc" ] && [ -n "\$gc" ] && [ "\$uc" != "\$gc" ] && [ -f "\$uc" ] && [ ! -s "\$uc" ] && [ -f "\$gc" ] && [ ! -s "\$gc" ] && cfg=two-empty-files
printf 'npxenv npmconfig=%s registry=%s acct=%s\n' "\$cfg" "\${npm_config_registry:-}" "\${CLOUDFLARE_ACCOUNT_ID:-}" >> "$T/calls.log"
printf 'npxtree %s\n' "\$(ls -A | tr '\n' ' ')" >> "$T/calls.log"
printf 'npxdist %s\n' "\$(ls -A dist | tr '\n' ' ')" >> "$T/calls.log"
printf 'npxfn %s\n' "\$(cat functions/api/f.js 2>/dev/null)" >> "$T/calls.log"
echo "Uploading... token=\$CLOUDFLARE_API_TOKEN"
# wrangler 3.114.17 logs these two lines on every deploy (console-ui/public/
# has both files), after the asset upload and before the /deployments POST.
echo "✨ Uploading _headers"
echo "✨ Uploading _redirects"
# One head fails (npx.failsha), with the error text in npx.failmsg.
# npx.failsha "all" fails every head; npx.failrc is the exit code (default 1).
if [ "\$(cat "$T/npx.failsha" 2>/dev/null)" = all ]; then cat "$T/npx.failmsg"; exit "\$(cat "$T/npx.failrc" 2>/dev/null || echo 1)"; fi
case " \$* " in *" --commit-hash \$(cat "$T/npx.failsha" 2>/dev/null) "*)
  [ -s "$T/npx.failsha" ] && { cat "$T/npx.failmsg"; exit "\$(cat "$T/npx.failrc" 2>/dev/null || echo 1)"; } ;; esac
[ -f "$T/nocomplete" ] || echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit "\$(cat "$T/npx.rc" 2>/dev/null || echo 0)"
EOF
# curl: the Cloudflare project config, and the console worker's QA mint.
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/calls.log"
case "\$*" in
  *"/pages/projects/"*) [ -f "$T/cf.fail" ] && exit 7
    # cf.failafter <k>: the first k reads answer, later ones fail (the account
    # probe after a deploy failure, not the bindings check before it).
    if [ -f "$T/cf.failafter" ]; then echo x >> "$T/cf.n"; [ "\$(wc -l < "$T/cf.n")" -gt "\$(cat "$T/cf.failafter")" ] && exit 7; fi
    cat "$T/cfproject" ;;
  *"/api/qa/session"*) [ -f "$T/nomint" ] && { echo '{"error":"x"}'; exit 0; }; printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
# node: the QA driver. It echoes the token to prove the lane scrubs it.
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'node %s|token=%s\n' "\$*" "\${CONSOLE_QA_TOKEN:+set}" >> "$T/calls.log"
echo "signing in with \$CONSOLE_QA_TOKEN"
if [ "\$(cat "$T/qa-result" 2>/dev/null || echo PASS)" = PASS ]; then
  printf 'SCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: PASS\n'; exit 0
fi
printf 'FAIL: /@390: horizontal body scroll\nSCREEN / 1440 ok\nSCREEN / 390 fail\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: FAIL\n'; exit 1
STUB
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
chmod +x "$T/sbin/"* "$HB/bin/lane-alert.sh"

prjson() { # prjson <n> <branch> <sha> [head repo]
  jq -nc --argjson n "$1" --arg b "$2" --arg s "$3" --arg r "${4:-$SLUG}" \
    '{number:$n, head:{ref:$b, sha:$s, repo:{full_name:$r}}, base:{ref:"main"}}'
}
setprs() { printf '%s\n' "$@" | jq -sc . > "$T/openprs"; }
reset() {
  rm -f "$T/calls.log" "$T"/posted-* "$T"/comments-*.json "$T"/st-* "$T/npx.rc" "$T/nocomplete" "$T/distlink" "$T/cf.fail" "$T/nomint" "$T/qa-result" "$T/distworker" \
        "$T/npx.failsha" "$T/npx.failmsg" "$T/npx.failrc" "$T/cf.failafter" "$T/cf.n"
  printf '%s\n' "$CLEAN_PROJECT" > "$T/cfproject"
  scratch_rm "$HB/state/console-preview-deploy"; touch "$T/calls.log"
}
run() {
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T" \
      HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CONSOLE_PREVIEW_BUILD_TMP="$T" SECRET_5909=s-fixture \
      CONSOLE_PREVIEW_DEPLOY=1 \
      CONSOLE_PAGES_URL=https://pages-fixture.example.invalid "$@" bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
  RC=$?
}
deploys() { grep -c '^npx .*pages deploy' "$T/calls.log"; }
URL11=https://ticket-bh-5909.pages-fixture.example.invalid

# ── P1: one deploy with the alias, one comment with URL + marker ─────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC $(cat "$T/out")"
[ "$(deploys)" = 1 ] && ok || bad "P1 want 1 deploy, got $(deploys): $(cat "$T/calls.log")"
grep -q '^npx .*wrangler@3\.114\.17 pages deploy dist --project-name [^ ]* --branch ticket-bh-5909 .*--commit-hash '"$S11" "$T/calls.log" \
  && ok || bad "P1 deploy argv: $(grep '^npx' "$T/calls.log")"
grep -q -- '--branch main' "$T/calls.log" && bad "P1 a preview deployed with --branch main" || ok
grep -q "^npx .*|cwd=$HB/state/console-preview-snap\.[^/]*/console-ui$" "$T/calls.log" \
  && ok || bad "P1 the deploy must run in a state/console-preview-snap.* snapshot: $(grep '^npx' "$T/calls.log")"
grep -qx "Console preview: $URL11" "$T/posted-11" 2>/dev/null && ok || bad "P1 comment URL line: $(cat "$T/posted-11" 2>/dev/null)"
grep -qx "<!-- console-preview sha=$S11 url=$URL11 -->" "$T/posted-11" 2>/dev/null && ok || bad "P1 comment marker: $(cat "$T/posted-11" 2>/dev/null)"
[ "$(grep -c -- '^gh .*-X POST' "$T/calls.log")" = 1 ] && ok || bad "P1 want exactly one comment POST"
# P9: the token never reaches the lane's own output.
grep -qF "$TOK" "$T/out" && bad "P9 the API token reached the lane output" || ok
# P10: nothing written under the checkout, no snapshot left.
[ -z "$(git -C "$CK" status --porcelain)" ] && ok || bad "P10 the checkout is dirty: $(git -C "$CK" status --porcelain)"
ls -d "$HB"/state/console-preview-snap.* >/dev/null 2>&1 && bad "P10 a snapshot was left behind" || ok
# P11: the unreviewed head builds in its own tree, with no install scripts and
# a clean env (the BH-5909 review: no PR code as root beside the env dir).
grep -q '^npm ci --ignore-scripts ' "$T/calls.log" && ok || bad "P11 npm ci must run with --ignore-scripts: $(grep '^npm ci' "$T/calls.log")"
grep -qv "|cwd=$T/console-preview-build\.[^/]*/console-ui$" <<<"$(grep '^npm ' "$T/calls.log")" \
  && bad "P11 npm ran outside the build tree: $(grep '^npm ' "$T/calls.log")" || ok
grep -q "^npmenv home=$T/console-preview-build\.[^/]*/\.cpv-home harness= secret=$" "$T/calls.log" \
  && ok || bad "P11 the build env is not clean: $(grep '^npmenv' "$T/calls.log")"
ls -d "$T"/console-preview-build.* >/dev/null 2>&1 && bad "P11 a build tree was left behind" || ok
# A second tick on the same head: the local record stops it before any read.
: > "$T/calls.log"; run
[ "$(deploys)" = 0 ] && ! grep -q -- '^gh .*-X POST' "$T/calls.log" && ok || bad "P1 a second tick deployed or posted again"

# ── P2: no console-ui path, including the look-alikes ─────────────────────────
reset; setprs "$(prjson 12 docs-only "$S12")"; run
[ "$RC" = 0 ] && [ "$(deploys)" = 0 ] && ok || bad "P2 a non-console diff deployed: $(cat "$T/calls.log")"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P2 a non-console diff got a comment" || ok
grep -q 'issues/12/comments' "$T/calls.log" && bad "P2 a non-console PR's comments were read" || ok

# ── P3: a marker for the head is already there ─────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"
jq -nc --arg b "Console preview: $URL11"$'\n'"<!-- console-preview sha=$S11 url=$URL11 -->" \
  '[{user:{login:"cromford[bot]"},author_association:"NONE",body:$b}]' > "$T/comments-11.json"
run
[ "$(deploys)" = 0 ] && ok || bad "P3 a head with a marker deployed again"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P3 a head with a marker got a second comment" || ok
# A marker for an OLDER head does not count.
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"
jq -nc --arg b "<!-- console-preview sha=$S13 url=$URL11 -->" '[{user:{login:"x"},body:$b}]' > "$T/comments-11.json"
run
[ "$(deploys)" = 1 ] && ok || bad "P3 a marker for another sha must not stop the deploy"

# ── P4: a failed deploy posts nothing ─────────────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo 1 > "$T/npx.rc"; run
[ "$RC" = 0 ] && [ "$(deploys)" = 1 ] && ok || bad "P4 rc=$RC deploys=$(deploys)"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P4 a failed deploy posted a comment" || ok
grep -q 'deploy failed' "$T/out" && ok || bad "P4 no failure line: $(cat "$T/out")"
: > "$T/calls.log"; rm -f "$T/npx.rc"; run
[ "$(deploys)" = 1 ] && [ -s "$T/posted-11" ] && ok || bad "P4 the next tick must retry a failed deploy"
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; touch "$T/nocomplete"; run
ls "$T"/posted-* >/dev/null 2>&1 && bad "P4 rc 0 with no 'Deployment complete' posted a comment" || ok
# P4b (BH-8251): wrangler output with no `error` line still names its cause:
# npm's config refusal printed none, and 208 failures read `wrangler rc=1: `.
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo all > "$T/npx.failsha"
printf 'cause\ndouble-loading config "/dev/null" as "global", previously loaded as "user"\n\n' > "$T/npx.failmsg"; run
grep -q 'wrangler rc=1: double-loading config' "$T/out" && ok || bad "P4b the reason names the last wrangler line: $(grep 'wrangler rc=' "$T/out")"
rm -f "$T/npx.failsha" "$T/npx.failmsg"

# ── P5: the per-run cap defers, never drops ────────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 13 feat/two "$S13")"
run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(deploys)" = 1 ] && ok || bad "P5 want 1 deploy under max_per_run=1, got $(deploys)"
grep -q 'deferred 1' "$T/out" && ok || bad "P5 no 'deferred 1' line: $(cat "$T/out")"
: > "$T/calls.log"; run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(deploys)" = 1 ] && grep -q -- '--branch feat-two' "$T/calls.log" && ok || bad "P5 the deferred PR must deploy next tick: $(grep '^npx' "$T/calls.log")"
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run CONSOLE_PREVIEW_DEPLOY=0
[ "$(deploys)" = 0 ] && ok || bad "P5 CONSOLE_PREVIEW_DEPLOY=0 must deploy nothing"

# ── P6: a fork PR is never built on the hub ────────────────────────────────────
reset; setprs "$(prjson 14 fork-branch "$S14" someone/fork)"; run
[ "$(deploys)" = 0 ] && ok || bad "P6 a fork PR deployed"
grep -q 'npm ci' "$T/calls.log" && bad "P6 npm ci ran on a fork PR" || ok

# ── P7: an unreadable thread is not "no marker" ─────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo 403 > "$T/st-comments-11"; run
[ "$(deploys)" = 0 ] && ok || bad "P7 a failed comments read deployed"
grep -q 'comments unreadable' "$T/out" && ok || bad "P7 no log line: $(cat "$T/out")"

# ── P8: not the hub ─────────────────────────────────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; mv "$HB/env/cloudflare.env" "$T/cf.aside"; run
[ "$RC" = 0 ] && [ ! -s "$T/calls.log" ] && ok || bad "P8 no cloudflare.env: rc=$RC calls=$(cat "$T/calls.log")"
mv "$T/cf.aside" "$HB/env/cloudflare.env"

# ── P12: a build that cannot be isolated, or a dist that is not plain files ──
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run CONSOLE_PREVIEW_BUILD_USER=no-such-user-5909
[ "$RC" = 0 ] && [ "$(deploys)" = 0 ] && ok || bad "P12 a build that cannot drop privilege deployed: rc=$RC $(cat "$T/calls.log")"
grep -q '^npm ' "$T/calls.log" && bad "P12 npm ran without the privilege drop" || ok
grep -q 'build not isolated' "$T/out" && ok || bad "P12 no 'build not isolated' line: $(cat "$T/out")"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P12 an unisolated build posted a comment" || ok
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run HARNESS_TEST_SANDBOX=0
[ "$(deploys)" = 0 ] && ! grep -q '^npm ' "$T/calls.log" && ok || bad "P12 the self mode ran outside the test sandbox"
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; touch "$T/distlink"; run
[ "$(deploys)" = 0 ] && ok || bad "P12 a dist with a symlink deployed"
grep -q 'non-regular file (leak.txt)' "$T/out" && ok || bad "P12 no refusal line for the symlink: $(cat "$T/out")"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P12 a refused dist posted a comment" || ok

# ── P13: no PR file in the deploy tree but dist/ ─────────────────────────────
reset; setprs "$(prjson 15 ticket/bh-15 "$S15")"; run
[ "$(deploys)" = 1 ] && ok || bad "P13 want 1 deploy of PR 15, got $(deploys): $(cat "$T/out")"
grep -qx 'npxfn export const who = "main";' "$T/calls.log" && ok || bad "P13 the deployed Functions must be main's: $(grep '^npxfn' "$T/calls.log")"
grep -qE '(^| )(package\.json|\.npmrc|wrangler\.toml|node_modules)( |$)' <<<"$(grep '^npxtree' "$T/calls.log")" \
  && bad "P13 a PR config file is in the deploy cwd: $(grep '^npxtree' "$T/calls.log")" || ok
grep -qx 'npxtree dist functions src ' "$T/calls.log" && ok || bad "P13 the deploy cwd holds dist, functions and src only: $(grep '^npxtree' "$T/calls.log")"

# ── P14: pinned wrangler, npm config off, registry pinned, main's account ────
reset; setprs "$(prjson 16 ticket/bh-16 "$S16")"; run
grep -qx 'npxenv npmconfig=two-empty-files registry=https://registry.npmjs.org/ acct=acct-fixture' "$T/calls.log" \
  && ok || bad "P14 npx env: $(grep '^npxenv' "$T/calls.log")"
grep -q '^npx --yes wrangler@3\.114\.17 ' "$T/calls.log" && ok || bad "P14 an exact wrangler: $(grep '^npx ' "$T/calls.log")"

# ── P15: a preview environment with production bindings deploys nothing ──────
for bad_cfg in '{"success":true,"result":{"deployment_configs":{"preview":{"d1_databases":{"CONSOLE_DB":{"id":"x"}}}}}}' \
               '{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"HARNESS_SECRET":{"type":"secret_text"}}}}}}' \
               '{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"DSN":{"type":"secret_text"}}}}}}' \
               '{"success":true,"result":{"deployment_configs":{"preview":{"services":{"JOBS":{"service":"harness-jobs"}}}}}}' \
               '{"success":true,"result":{"deployment_configs":{"preview":{"durable_object_namespaces":{"DO":{"namespace_id":"x"}}}}}}' \
               '{"success":true,"result":{"deployment_configs":{"preview":{"some_new_binding":{"X":{"id":"x"}}}}}}' \
               '{"success":false,"errors":[{"code":10000}]}'; do
  reset; printf '%s\n' "$bad_cfg" > "$T/cfproject"; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
  [ "$(deploys)" = 0 ] && ok || bad "P15 deployed with config $bad_cfg"
  grep -q '^alert --id console-preview-bindings ' "$T/calls.log" && ok || bad "P15 no bindings alert for $bad_cfg: $(grep alert "$T/calls.log")"
  grep -q 'npm ci' "$T/calls.log" && bad "P15 the build ran with $bad_cfg" || ok
done
reset; touch "$T/cf.fail"; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
[ "$(deploys)" = 0 ] && grep -q 'did not read' "$T/out" && ok || bad "P15 an unreadable config must stop the deploy: $(cat "$T/out")"

# A preview config with only harmless settings still deploys.
reset; printf '%s\n' '{"success":true,"result":{"deployment_configs":{"preview":{"compatibility_date":"2024-01-01","compatibility_flags":[],"env_vars":{"VITE_X":{"type":"plain_text","value":"1"}},"d1_databases":{},"placement":{}}}}}' > "$T/cfproject"
setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
[ "$(deploys)" = 1 ] && ok || bad "P15 a preview config with no binding must deploy: $(cat "$T/out")"

# ── P21: the PR's own server code never deploys ──────────────────────────────
for form in file dir; do
  reset; echo "$form" > "$T/distworker"; setprs "$(prjson 15 ticket/bh-15 "$S15")"; run
  [ "$(deploys)" = 1 ] && ok || bad "P21 ($form) want 1 deploy, got $(deploys): $(cat "$T/out")"
  grep -qx 'npxdist index.html ' "$T/calls.log" && ok || bad "P21 ($form) the deployed dist must hold the static build only: $(grep '^npxdist' "$T/calls.log")"
  grep -qx 'npxfn export const who = "main";' "$T/calls.log" && ok || bad "P21 ($form) the deployed Functions must be main's: $(grep '^npxfn' "$T/calls.log")"
  grep -q 'stripped from the PR build output: _worker.js _routes.json functions' "$T/out" && ok || bad "P21 ($form) no line naming what was stripped: $(cat "$T/out")"
done

# ── P22: a failing build never blocks the lane ───────────────────────────────
nbuild17() { grep -c "^npm run build.*|cwd=.*" "$T/calls.log" 2>/dev/null; }
reset; setprs "$(prjson 17 ticket/bh-17 "$S17")" "$(prjson 11 ticket/bh-5909 "$S11")"; run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(deploys)" = 1 ] && grep -q -- '--branch ticket-bh-5909 ' "$T/calls.log" && ok \
  || bad "P22 the good PR behind a failing one must deploy in the same run under max_per_run=1: $(grep '^npx' "$T/calls.log"; cat "$T/out")"
grep -q 'deferred 0' "$T/out" && ok || bad "P22 nothing may be deferred: $(tail -1 "$T/out")"
[ "$(cat "$HB/state/console-preview-deploy/$S17" 2>/dev/null)" = "failed 1" ] && ok || bad "P22 the failing head's record: '$(cat "$HB/state/console-preview-deploy/$S17" 2>/dev/null)'"
[ -e "$T/posted-17" ] && bad "P22 a first failure posts no comment" || ok
rm -f "$T/calls.log"; touch "$T/calls.log"; run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(cat "$HB/state/console-preview-deploy/$S17" 2>/dev/null)" = "failed 2" ] && ok || bad "P22 second failure: '$(cat "$HB/state/console-preview-deploy/$S17" 2>/dev/null)'"
grep -q "Console preview: not deployed for head $S17" "$T/posted-17" 2>/dev/null && grep -q '<!-- console-preview-failed sha='"$S17"' -->' "$T/posted-17" \
  && ok || bad "P22 the terminal failure posts one comment naming the head: $(cat "$T/posted-17" 2>/dev/null)"
rm -f "$T/calls.log" "$T/posted-17"; touch "$T/calls.log"; run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(nbuild17)" = 0 ] && ok || bad "P22 a terminal head must not be built again: $(grep '^npm run build' "$T/calls.log")"
[ -e "$T/posted-17" ] && bad "P22 the terminal comment must not repeat" || ok

# ── P23: a box fault is never charged to the head ────────────────────────────
rec11() { cat "$HB/state/console-preview-deploy/$S11" 2>/dev/null; }
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 14 ticket/bh-14 "$S14")"
for i in 1 2 3; do run CONSOLE_PREVIEW_BUILD_USER=no-such-user-5909; done
[ -z "$(rec11)" ] && ok || bad "P23 a build user that does not exist must leave no record for the head, got '$(rec11)'"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P23 a box fault posted a comment: $(cat "$T"/posted-*)" || ok
[ "$(grep -c '^alert .*--id console-preview-box ' "$T/calls.log")" = 3 ] && ok \
  || bad "P23 each run must raise one console-preview-box alert: $(grep '^alert' "$T/calls.log")"
grep -q 'not charged to the head' "$T/out" && ok || bad "P23 no box-fault line: $(cat "$T/out")"
grep -q '#14 ' "$T/out" && bad "P23 a box fault must stop the run before the next head: $(cat "$T/out")" || ok
# TEST-CHANGE (lead BLOCK at 3e006f06c): a wrangler failure is now classified,
# so this case uses an AUTH error (the box); P26 and P27 pin the rest.
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo "$S11" > "$T/npx.failsha"
echo '✘ [ERROR] A request to the Cloudflare API failed. Authentication error [code: 10000]' > "$T/npx.failmsg"
for i in 1 2; do run; done
[ "$(deploys)" = 2 ] && [ -z "$(rec11)" ] && ok || bad "P23 a wrangler auth error twice: deploys=$(deploys) record='$(rec11)' (want 2 and none)"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P23 a wrangler error posted a comment" || ok
rm -f "$T/npx.failsha"; run
[ "$(rec11)" = done ] && [ -s "$T/posted-11" ] && ok || bad "P23 the head must deploy once the box is fixed: record='$(rec11)'"

# ── P26: an upload failure caused by the head's own dist is the HEAD's ───────
# (lead BLOCK at 3e006f06c) A dist Pages refuses is charged to the head, and the
# next PR still deploys.
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 14 ticket/bh-14 "$S14")"
echo "$S11" > "$T/npx.failsha"; echo '✘ [ERROR] Error: Pages only supports files up to 25 MiB in size. dist/big.bin is 31 MiB in size' > "$T/npx.failmsg"
run
[ "$(rec11)" = "failed 1" ] && ok || bad "P26 a refused dist is the head's: record='$(rec11)'"
grep -q -- '--branch ticket-bh-14 ' "$T/calls.log" && [ -s "$T/posted-14" ] && ok \
  || bad "P26 the next PR must deploy in the same run: $(grep '^npx .*pages' "$T/calls.log"; cat "$T/out")"
grep -q '^alert .*--id console-preview-box ' "$T/calls.log" && bad "P26 a head fault raised the box alert" || ok
run
[ "$(rec11)" = "failed 2" ] && grep -q "Console preview: not deployed for head $S11" "$T/posted-11" 2>/dev/null && ok \
  || bad "P26 the second failure is terminal: record='$(rec11)'"
# TEST-CHANGE (lead BLOCK at 1f9246916): an unknown error, npm 10's
# `npm error` lines (a full disk, a cache EACCES, a registry ETARGET) and a
# wrangler killed with no text (rc 137) are the BOX's: no record, one alert, the
# run stops. Only the streak guard (P27) can charge a head for them.
for c in unknown enospc etarget oom cf8000000 nocomplete; do
  reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 14 ticket/bh-14 "$S14")"; echo "$S11" > "$T/npx.failsha"
  case "$c" in
    unknown) echo '✘ [ERROR] something nobody has seen before' > "$T/npx.failmsg" ;;
    enospc)  printf 'npm error code ENOSPC\nnpm error syscall write\n' > "$T/npx.failmsg" ;;
    etarget) printf 'npm error code ETARGET\nnpm error notarget No matching version found for wrangler@3.114.17.\n' > "$T/npx.failmsg" ;;
    oom)     : > "$T/npx.failmsg"; echo 137 > "$T/npx.failrc" ;;
    # lead BLOCK at 72e007976: a failure after the `Uploading _redirects` line
    # that no box pattern names, and rc 0 with no "Deployment complete".
    cf8000000) echo '✘ [ERROR] A request to the Cloudflare API (/accounts/x/pages/projects/y/deployments) failed. Internal error [code: 8000000]' > "$T/npx.failmsg" ;;
    nocomplete) : > "$T/npx.failmsg"; echo 0 > "$T/npx.failrc" ;;
  esac
  run
  [ -z "$(rec11)" ] && grep -q '^alert .*--id console-preview-box ' "$T/calls.log" && ! grep -q -- '--branch ticket-bh-14 ' "$T/calls.log" && ok \
    || bad "P26 [$c] is a box fault (no record, alert, stop): record='$(rec11)' $(grep '^alert' "$T/calls.log")"
done

# ── P27: one head can never stall the lane, and an account-wide fault charges
# no head ──────────────────────────────────────────────────────────────────────
# (lead BLOCK at 1f9246916) The same head as the run's upload box fault more
# than MAX_ATTEMPTS (2) runs in a row is SKIPPED on the next run, and charged
# only when a later head uploads in that same run: that proves the box can
# upload. A head-specific fault is charged; an account-wide one is not.
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 14 ticket/bh-14 "$S14")"
echo "$S11" > "$T/npx.failsha"; echo '✘ [ERROR] A request to the Cloudflare API failed. Authentication error [code: 10000]' > "$T/npx.failmsg"
run; run
[ -z "$(rec11)" ] && ! grep -q -- '--branch ticket-bh-14 ' "$T/calls.log" && ok || bad "P27 two box-fault runs charge nothing yet: record='$(rec11)'"
run
[ "$(rec11)" = "failed 1" ] && ok || bad "P27 head-specific: the third run charges the head once PR 14 uploads: record='$(rec11)'"
grep -q -- '--branch ticket-bh-14 ' "$T/calls.log" && [ -s "$T/posted-14" ] && ok || bad "P27 the PR behind it deploys on that run: $(cat "$T/out")"
# Account-wide: every upload fails the same way (a token with Pages Read, no Edit).
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")" "$(prjson 14 ticket/bh-14 "$S14")"
echo all > "$T/npx.failsha"; echo '✘ [ERROR] A request to the Cloudflare API failed. Authentication error [code: 10000]' > "$T/npx.failmsg"
for i in 1 2 3 4 5 6 7; do run; done
rec14() { cat "$HB/state/console-preview-deploy/$S14" 2>/dev/null; }
[ -z "$(rec11)" ] && [ -z "$(rec14)" ] && ok || bad "P27 account-wide: 7 runs charge no head: 11='$(rec11)' 14='$(rec14)'"
ls "$T"/posted-* >/dev/null 2>&1 && bad "P27 account-wide: no head gets a failure comment: $(cat "$T"/posted-*)" || ok
grep -q -- '--branch ticket-bh-14 ' "$T/calls.log" && ok || bad "P27 account-wide: the skipped head lets PR 14 be tried"
# Once the token is fixed, both deploy on the next run: the streak head is
# still tried first, and nothing was charged while the token was broken.
rm -f "$T/npx.failsha"; run
[ "$(rec11)" = done ] && [ "$(rec14)" = done ] && ok || bad "P27 once the token is fixed both deploy: 11='$(rec11)' 14='$(rec14)'"

# ── P24: failing heads are capped per run ────────────────────────────────────
reset; setprs "$(prjson 17 ticket/bh-17 "$S17")" "$(prjson 18 ticket/bh-18 "$S18")" "$(prjson 19 ticket/bh-19 "$S19")"
run CONSOLE_PREVIEW_MAX_PER_RUN=1
[ "$(grep -c '^npm run build' "$T/calls.log")" = 2 ] && ok || bad "P24 max_per_run=1 allows 2 build attempts, got $(grep -c '^npm run build' "$T/calls.log")"
grep -q 'deferred 1' "$T/out" && ok || bad "P24 the third failing head must be deferred: $(tail -1 "$T/out")"

# ── P25: a failed comment POST never rebuilds ────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo 403 > "$T/st-post"
for i in 1 2 3; do run; done
[ "$(deploys)" = 1 ] && ok || bad "P25 a rejected POST must not redeploy: $(deploys) deploys"
[ "$(grep -c -- '^gh .*-X POST' "$T/calls.log")" = 2 ] && ok || bad "P25 the POST is tried MAX_ATTEMPTS (2) times, got $(grep -c -- '^gh .*-X POST' "$T/calls.log")"
[ "$(grep -c '^alert .*--id console-preview-post ' "$T/calls.log")" = 1 ] && ok || bad "P25 one console-preview-post alert: $(grep '^alert' "$T/calls.log")"
grep -q "QA: PASS for head $S11" "$T/posted-11" 2>/dev/null && ok || bad "P25 the retried body is the kept QA comment: $(cat "$T/posted-11" 2>/dev/null)"
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; echo 403 > "$T/st-post"; run; rm -f "$T/st-post" "$T/posted-11"; run
[ "$(deploys)" = 1 ] && [ "$(rec11)" = done ] && grep -q "QA: PASS for head $S11" "$T/posted-11" 2>/dev/null && ok \
  || bad "P25 a POST that works on retry: deploys=$(deploys) record='$(rec11)'"

# ── P16: QA PASS ─────────────────────────────────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
grep -q '^curl .*-X POST .*/api/qa/session' "$T/calls.log" && ok || bad "P16 the session must be minted from the worker: $(grep '^curl' "$T/calls.log")"
grep -qF "node $HB/bin/console-qa-run.mjs $URL11 $HB $HB/state/console-preview-qa/11-${S11:0:12} /|token=set" "$T/calls.log" \
  && ok || bad "P16 the driver call: $(grep '^node' "$T/calls.log")"
grep -qx 'QA COVERAGE: screens=2 flows=0 shots=2' "$T/posted-11" 2>/dev/null && ok || bad "P16 the comment carries QA COVERAGE: $(cat "$T/posted-11" 2>/dev/null)"
grep -q "^QA: PASS for head $S11\." "$T/posted-11" 2>/dev/null && ok || bad "P16 the comment says QA: PASS for the head: $(cat "$T/posted-11" 2>/dev/null)"
grep -qx "<!-- console-qa sha=$S11 result=PASS -->" "$T/posted-11" 2>/dev/null && ok || bad "P16 the QA marker"
[ -s "$HB/state/console-preview-qa/11-${S11:0:12}/qa.md" ] && ok || bad "P16 qa.md is kept on the hub"

# ── P17: QA FAIL ─────────────────────────────────────────────────────────────
reset; echo FAIL > "$T/qa-result"; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
grep -q '^FAIL: /@390: horizontal body scroll$' "$T/posted-11" 2>/dev/null && ok || bad "P17 the failure line: $(cat "$T/posted-11" 2>/dev/null)"
grep -q "^QA: FAIL for head $S11\." "$T/posted-11" 2>/dev/null && ok || bad "P17 QA: FAIL for the head"
grep -qx "<!-- console-qa sha=$S11 result=FAIL -->" "$T/posted-11" 2>/dev/null && ok || bad "P17 the FAIL marker"

# ── P18: no session minted ───────────────────────────────────────────────────
reset; touch "$T/nomint"; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
grep -q 'minted no QA session' "$T/posted-11" 2>/dev/null && grep -q "^QA: FAIL for head $S11\." "$T/posted-11" && ok \
  || bad "P18 no session is QA: FAIL, said: $(cat "$T/posted-11" 2>/dev/null)"
grep -q '^node ' "$T/calls.log" && bad "P18 the driver ran with no session" || ok

# ── P19: no secret reaches the output or the comment ─────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"; run
for sec in "$HSEC" "$QATOK" "$TOK"; do
  grep -qF "$sec" "$T/out" "$T/posted-11" && bad "P19 a secret reached the output or the comment (${sec:0:6}...)" || ok
done
grep -rqF "$QATOK" "$HB/state/console-preview-qa" && bad "P19 the QA token is in the kept qa.md" || ok

# ── P20: off by default ──────────────────────────────────────────────────────
reset; setprs "$(prjson 11 ticket/bh-5909 "$S11")"
( cd "$T" && env -u CONSOLE_PREVIEW_DEPLOY HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" HARNESS_REPO="$SLUG" \
    PATH="$T/sbin:$PATH" LANE_GATE_DISABLE=1 TMPDIR="$T" HARNESS_TEST_SANDBOX=1 bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
[ "$(deploys)" = 0 ] && grep -q 'CONSOLE_PREVIEW_DEPLOY=0 — off' "$T/out" && ok || bad "P20 the lane must be off by default: $(cat "$T/out")"

[ -n "${DEBUG_T:-}" ] && cat "$T/calls.log"
echo "console-preview-deploy.bh-5909: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
