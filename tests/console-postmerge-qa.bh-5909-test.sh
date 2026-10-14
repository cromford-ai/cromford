#!/bin/bash
# tests/console-postmerge-qa.bh-5909-test.sh — after the hub ships a console-ui
# commit to Pages production, the SAME shipped dist/ is deployed to the fixed
# `postmerge-qa` alias, driven at 1280px and 375px as the read-only QA session,
# and reported once on the merged PR and in one lane alert (BH-5909 slice 3).
#
# Drives the REAL bin/console-pages-deploy.sh and bin/console-postmerge-qa.sh
# in a scratch harness (scratch_install_closure), with a scratch checkout and
# stubs for npm, npx (wrangler), curl (the probes and the QA session mint), node
# (the QA driver), gh (the REST envelope), jobs-client.sh and lane-alert.sh.
#
#   M1  launch off: knob row absent, `yes`, or the QA script absent: no kept
#       dist, no launch line
#   M2  launch on: the deploy keeps dist-<40hex>/, launches the QA run with that
#       sha and dir, and the run removes the dir and writes the verdict
#   M3  PASS: verdict PASS, --branch postmerge-qa --commit-hash <40hex> (never
#       --branch main), widths 1280,375, every default screen
#   M4  FAIL: a failing drive is verdict FAIL
#   M5  not PASS: rc 0 with QA: FAIL, shots=0, screens=0, no QA COVERAGE line
#   M6  alerts: FAIL raises one console-postmerge-qa warn; a later PASS resolves
#       it and the notcovered id
#   M7  exit paths: upload failed, no session, knob 0, lock held
#   M8  a verdict already there: no npx, no curl, the dist removed
#   M9  no secret in qa.md, the log or the comment; the comment has no line of
#       the slice-2 gate's QA: PASS shape, and the gate does not read it as PASS
#   M10 cpv_alias reserves postmerge-qa
#   M11 one comment per sha: a marker on the PR stops a second; an unreadable
#       PR lookup posts nothing and still writes the verdict
#   M12 a bad sha or a dist path outside state/console-postmerge-qa: nothing
#       deployed, nothing removed
#   M13 the three knobs compose into the fleet-propagate lane with their defaults
#   M14 viewportsFor (bin/console-qa-run.mjs): CONSOLE_QA_WIDTHS selects widths
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-postmerge-qa.bh-5909-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git jq flock timeout; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
[ -f "$DIR/bin/console-postmerge-qa.sh" ] || bad "bin/console-postmerge-qa.sh does not exist"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONSOLE_POSTMERGE_QA CONSOLE_POSTMERGE_QA_SCREENS CONSOLE_POSTMERGE_QA_TIMEOUT_S CONSOLE_PAGES_DEPLOY \
      CONSOLE_PAGES_RED_TRIES CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID \
      CONSOLE_PREVIEW_WRANGLER CONSOLE_QA_WIDTHS CONSOLE_WORKER_URL
SLUG=o/console-fixture
TOK=tok-fixture-TK-5909
HSEC=hsec-fixture-5909-not-real
QATOK="1791700000.$(printf 'cd%.0s' $(seq 1 32))"
SCREENS_DEFAULT='/ /now /kanban /jobs /t/BH-5909 /machines /lead-reviews'

# ── M10: the alias reservation (pure) ────────────────────────────────────────
( HARNESS="$DIR"; . "$DIR/bin/lib/console-preview.sh" || exit 9
  for b in postmerge-qa PostMerge-QA postmerge_qa postmerge-qa- main; do
    cpv_alias "$b" >/dev/null && echo "M10 '$b' must be refused, got $(cpv_alias "$b")"
  done
  for p in postmerge:postmerge postmerge-qa-2:postmerge-qa-2 ticket/postmerge-qa:ticket-postmerge-qa fix-postmerge-qa:fix-postmerge-qa; do
    [ "$(cpv_alias "${p%%:*}")" = "${p#*:}" ] || echo "M10 '${p%%:*}' -> '$(cpv_alias "${p%%:*}")', want '${p#*:}'"
  done
  exit 0
) > "$T/m10.out" 2>&1; mrc=$?
if [ "$mrc" = 0 ] && [ ! -s "$T/m10.out" ]; then ok; else bad "M10 rc=$mrc $(cat "$T/m10.out")"; fi

# ── M14: viewportsFor ────────────────────────────────────────────────────────
if command -v node >/dev/null; then
  cat > "$T/vp.mjs" <<UNIT
import { VIEWPORTS, viewportsFor } from "$DIR/bin/console-qa-run.mjs";
const s = (v) => v.map((x) => x.name + ":" + x.width + "x" + x.height).join(",");
console.log("a=" + s(viewportsFor("1280,375")));
console.log("b=" + s(viewportsFor("")));
console.log("c=" + s(viewportsFor("999")));
console.log("d=" + s(viewportsFor(" 375 , 999,1280")));
console.log("e=" + s(VIEWPORTS));
UNIT
  VP=$(node "$T/vp.mjs" 2>&1)
  grep -qx 'a=1280:1280x900,375:375x812' <<<"$VP" && ok || bad "M14 1280,375: $VP"
  grep -qx 'b=1440:1440x900,390:390x844' <<<"$VP" && ok || bad "M14 empty is the default: $VP"
  grep -qx 'c=1440:1440x900,390:390x844' <<<"$VP" && ok || bad "M14 an unknown width is the default: $VP"
  grep -qx 'd=375:375x812,1280:1280x900' <<<"$VP" && ok || bad "M14 unknown values drop, order kept: $VP"
  grep -qx 'e=1440:1440x900,390:390x844' <<<"$VP" && ok || bad "M14 VIEWPORTS unchanged: $VP"
else
  echo "node missing — M14 skipped"
fi

# ── M13: the knobs compose into the fleet-propagate lane ─────────────────────
if HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" > "$T/lb.out" 2>&1; then
  kq() { jq -r --arg e "$1" '.lanes[] | select(.id == "fleet-propagate") | .knobs[] | select(.env == $e) | .default | tostring' "$T/lanes.json"; }
  [ "$(kq CONSOLE_POSTMERGE_QA)" = 0 ] && ok || bad "M13 CONSOLE_POSTMERGE_QA default: '$(kq CONSOLE_POSTMERGE_QA)'"
  [ "$(kq CONSOLE_POSTMERGE_QA_SCREENS)" = "$SCREENS_DEFAULT" ] && ok || bad "M13 CONSOLE_POSTMERGE_QA_SCREENS default: '$(kq CONSOLE_POSTMERGE_QA_SCREENS)'"
  [ "$(kq CONSOLE_POSTMERGE_QA_TIMEOUT_S)" = 900 ] && ok || bad "M13 CONSOLE_POSTMERGE_QA_TIMEOUT_S default: '$(kq CONSOLE_POSTMERGE_QA_TIMEOUT_S)'"
else
  bad "M13 bin/lanes-build.sh --to failed: $(cat "$T/lb.out")"
fi

# ── fixture: a hub checkout on main with two console-ui merges ───────────────
CK="$T/ck"; HB="$T/h"; QD="$HB/state/console-postmerge-qa"
git init -q -b main "$CK"
mkdir -p "$CK/console-ui/src" "$CK/console-ui/functions/api" "$CK/worker/jobs" "$CK/catalog"
echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
echo 'export const who = "shipped";' > "$CK/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$CK/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$CK/worker/jobs/wrangler.jsonc"
echo '{}' > "$CK/catalog/x.json"
git -C "$CK" add -A; git -C "$CK" commit -qm base
git -C "$CK" checkout -q -b feat; echo 'export const b = 2;' >> "$CK/console-ui/src/app.js"; git -C "$CK" commit -qam feat
git -C "$CK" checkout -q main; git -C "$CK" merge -q --no-ff feat -m merge-feat
SA=$(git -C "$CK" rev-parse HEAD)
echo 'export const c = 3;' >> "$CK/console-ui/src/app.js"; git -C "$CK" commit -qam second
SB=$(git -C "$CK" rev-parse HEAD)
git -C "$CK" reset -q --hard "$SA"   # the checkout's HEAD is SA; SB stays in the object store

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin" "$T/set"
scratch_install_closure bin/console-postmerge-qa.sh "$HB" >/dev/null || bad "closure of bin/console-postmerge-qa.sh"
scratch_install_closure bin/console-pages-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-pages-deploy.sh"
for f in bin/lib/console-preview.sh bin/lib/console-pages.sh bin/lib/gh-rest.sh; do
  [ -f "$HB/$f" ] && ok || bad "the closure of bin/console-postmerge-qa.sh does not carry $f"
done
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=%s\n' "$HSEC" > "$HB/env/global.env"

cat > "$HB/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf 'jobs-client %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  setting-get) [ -f "$T/set/\$2" ] || exit 2; cat "$T/set/\$2"; echo; exit 0 ;;
  setting-set) printf '%s' "\$3" > "$T/set/\$2"; exit 0 ;;
esac
exit 1
EOF
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  ci) exit 0 ;;
  test) printf 'TAP version 13\nok 1 - tests/x.test.js\n# fail 0\n'; exit 0 ;;
  run) [ "\$2" = build ] && { mkdir -p dist; echo '<html>shipped</html>' > dist/index.html; exit 0; } ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s|cwd=%s|acct=%s\n' "\$*" "\$PWD" "\${CLOUDFLARE_ACCOUNT_ID:-}" >> "$T/calls.log"
printf 'npxtree %s|dist=%s|fn=%s\n' "\$(ls -A | tr '\n' ' ')" "\$(cat dist/index.html 2>/dev/null)" "\$(cat functions/api/f.js 2>/dev/null)" >> "$T/calls.log"
echo "Uploading... token=\$CLOUDFLARE_API_TOKEN"
echo "Authorization: Bearer \$CLOUDFLARE_API_TOKEN"
echo "Uploading Functions bundle"
[ -f "$T/upload.fail" ] && { echo "✘ [ERROR] A request to the Cloudflare API failed."; exit 1; }
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit 0
EOF
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/calls.log"
case "\$*" in
  *"/api/qa/session"*) [ -f "$T/notoken" ] && { echo '{"error":"x"}'; exit 0; }
    printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *"/api/coord/jobs"*|*"/api/ideas/list"*) printf 403 ;;
  *) exit 7 ;;
esac
STUB
# node: the QA driver. It prints SCREEN lines for the paths it was handed and
# echoes the token, to prove the run scrubs it.
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'node %s|widths=%s|token=%s\n' "\$*" "\${CONSOLE_QA_WIDTHS:-}" "\${CONSOLE_QA_TOKEN:+set}" >> "$T/calls.log"
echo "signing in with \$CONSOLE_QA_TOKEN"
shift 4; n=0
for p in "\$@"; do printf 'SCREEN %s 1280 ok\nSCREEN %s 375 ok\n' "\$p" "\$p"; n=\$((n + 2)); done
case "\$(cat "$T/drive.mode" 2>/dev/null || echo pass)" in
  pass)    printf 'QA COVERAGE: screens=%s flows=0 shots=%s\nQA: PASS\n' "\$n" "\$n"; exit 0 ;;
  fail)    printf 'FAIL: /now@375: horizontal body scroll\nQA COVERAGE: screens=%s flows=0 shots=%s\nQA: FAIL\n' "\$n" "\$n"; exit 1 ;;
  rc0fail) printf 'QA COVERAGE: screens=%s flows=0 shots=%s\nQA: FAIL\n' "\$n" "\$n"; exit 0 ;;
  shots0)  printf 'QA COVERAGE: screens=%s flows=0 shots=0\nQA: PASS\n' "\$n"; exit 0 ;;
  zero)    printf 'FAIL: the QA session did not hold\nQA COVERAGE: screens=0 flows=0 shots=0\nQA: FAIL\n'; exit 1 ;;
  nocov)   exit 137 ;;
esac
STUB
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
    send 200 "\$(cat "$T/comments-\$n.json" 2>/dev/null || echo '[]')" ;;
  *"-X GET repos/"*"/commits/"*"/pulls"*)
    st=\$(cat "$T/st-pulls" 2>/dev/null || echo 200)
    case "\$st" in 2*) send "\$st" "\$(cat "$T/pulls.json")" ;; *) send "\$st" '{"message":"stub"}' ;; esac ;;
esac
exit 0
EOF
chmod +x "$T/sbin/"* "$HB/bin/jobs-client.sh" "$HB/bin/lane-alert.sh"

pulls_for() { jq -nc --arg s "$1" '[{number:4242, merge_commit_sha:$s, merged_at:"2026-10-13T00:00:00Z"}]' > "$T/pulls.json"; }
mkdist() { mkdir -p "$QD/dist-$1"; echo '<html>shipped</html>' > "$QD/dist-$1/index.html"; }
reset() {
  rm -f "$T/calls.log" "$T"/posted-* "$T"/comments-*.json "$T"/st-* "$T/upload.fail" "$T/notoken" "$T/drive.mode" "$T"/set/*
  scratch_rm "$QD"; mkdir -p "$QD"; touch "$T/calls.log"; pulls_for "$SA"
}
# runq <sha> <dist> [VAR=value...] — one bin/console-postmerge-qa.sh run.
runq() {
  local s="$1" d="$2"; shift 2
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" GH_ETAG=0 TMPDIR="$T" \
      CONSOLE_PAGES_URL=https://pages-fixture.example.invalid CONSOLE_POSTMERGE_QA=1 "$@" \
      bash "$HB/bin/console-postmerge-qa.sh" "$s" "$d" ) > "$T/out" 2>&1
  RC=$?
}
cnt() { grep -c -- "$1" "$T/calls.log"; }
nosnap() { ! ls -d "$HB"/state/console-postmerge-snap.* >/dev/null 2>&1; }
URL=https://postmerge-qa.pages-fixture.example.invalid

# ── M3: PASS ─────────────────────────────────────────────────────────────────
reset; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
[ "$RC" = 0 ] && ok || bad "M3 rc=$RC $(cat "$T/out")"
[ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = PASS ] && ok || bad "M3 verdict: '$(cat "$QD/$SA/verdict" 2>/dev/null)' $(cat "$T/out")"
grep -q "^npx --yes wrangler@3\.114\.17 pages deploy dist --project-name mission-control --branch postmerge-qa --commit-hash $SA " "$T/calls.log" \
  && ok || bad "M3 wrangler argv: $(grep '^npx' "$T/calls.log")"
grep -q -- '--branch main' "$T/calls.log" && bad "M3 the QA run deployed --branch main" || ok
grep -q "^npx .*|cwd=$HB/state/console-postmerge-snap\.[^/]*/console-ui|acct=acct-fixture$" "$T/calls.log" \
  && ok || bad "M3 the upload runs in a console-postmerge-snap tree with the account id: $(grep '^npx ' "$T/calls.log")"
grep -q '^npxtree .*|dist=<html>shipped</html>|fn=export const who = "shipped";$' "$T/calls.log" \
  && ok || bad "M3 the deploy tree holds the kept dist and the commit's functions: $(grep '^npxtree' "$T/calls.log")"
grep -q "^node .*|widths=1280,375|token=set$" "$T/calls.log" && ok || bad "M3 the drive widths: $(grep '^node' "$T/calls.log")"
grep -q "^node $HB/bin/console-qa-run.mjs $URL $HB $QD/$SA " "$T/calls.log" && ok || bad "M3 the drive argv: $(grep '^node' "$T/calls.log")"
for p in $SCREENS_DEFAULT; do
  grep '^node ' "$T/calls.log" | grep -q -- " ${p}[ |]" && ok || bad "M3 screen $p not driven: $(grep '^node' "$T/calls.log")"
done
[ ! -e "$QD/dist-$SA" ] && ok || bad "M3 the kept dist must be removed"
nosnap && ok || bad "M3 a snapshot was left behind"
grep -qx "SCREEN /lead-reviews 375 ok" "$QD/$SA/qa.md" 2>/dev/null && ok || bad "M3 qa.md: $(cat "$QD/$SA/qa.md" 2>/dev/null)"
# M9 over the PASS run
grep -qF "$QATOK" "$QD/$SA/qa.md" "$T/out" "$T/posted-4242" && bad "M9 the QA token leaked" || ok
grep -qF "$HSEC" "$QD/$SA/qa.md" "$T/out" "$T/posted-4242" && bad "M9 HARNESS_SECRET leaked" || ok
grep -qF "$TOK" "$QD/$SA/qa.md" "$T/out" "$T/posted-4242" && bad "M9 the Cloudflare token leaked" || ok
grep -qE '^QA: (PASS|FAIL)' "$T/posted-4242" && bad "M9 the comment has a slice-2 QA: line: $(cat "$T/posted-4242")" || ok
grep -qF 'QA: PASS for head' "$T/posted-4242" && bad "M9 the comment names a head the gate reads" || ok
grep -qx "POST-MERGE QA: PASS at $SA" "$T/posted-4242" && ok || bad "M9 the POST-MERGE line: $(cat "$T/posted-4242" 2>/dev/null)"
grep -qx "<!-- console-postmerge-qa sha=$SA result=PASS -->" "$T/posted-4242" && ok || bad "M9 the marker: $(cat "$T/posted-4242" 2>/dev/null)"
grep -qF "$URL" "$T/posted-4242" && ok || bad "M9 the comment names the alias URL"
grep -q 'never signs in on the production host' "$T/posted-4242" && ok || bad "M9 the comment states the preview-environment difference"
# The slice-2 gate, reading this comment as written by an OWNER, finds no PASS.
jq -nc --rawfile b "$T/posted-4242" '[{author_association:"OWNER", html_url:"u", body:$b}]' > "$T/comments-4242.json"
GV=$( HARNESS="$HB" PATH="$T/sbin:$PATH" GH_ETAG=0 TMPDIR="$T"; . "$HB/bin/lib/gh-rest.sh"; . "$DIR/bin/lib/console-qa-gate.sh"; cqg_head_verdict "$SLUG" 4242 "$SA" )
[ "$GV" = MISSING ] && ok || bad "M9 the slice-2 gate read the post-merge comment as '$GV'"
rm -f "$T/comments-4242.json"

# ── M11: one comment per sha ─────────────────────────────────────────────────
[ "$(cnt '^gh .*-X POST repos/o/console-fixture/issues/4242/comments')" = 1 ] && ok || bad "M11 want one POST on #4242: $(grep '^gh' "$T/calls.log")"
cp "$T/posted-4242" "$T/first.md"
jq -nc --rawfile b "$T/first.md" '[{author_association:"NONE", body:$b}]' > "$T/keep.json"
rm -f "$T/calls.log" "$T/posted-4242" "$QD/$SA/verdict"; cp "$T/keep.json" "$T/comments-4242.json"; mkdist "$SA"
runq "$SA" "$QD/dist-$SA"
grep -q -- '^gh .*-X POST' "$T/calls.log" && bad "M11 a marker on the PR must stop a second POST" || ok
[ -s "$QD/$SA/verdict" ] && ok || bad "M11 the verdict is written even with no POST"
reset; echo 500 > "$T/st-pulls"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
grep -q -- '^gh .*-X POST' "$T/calls.log" && bad "M11 an unreadable PR lookup must not post" || ok
grep -q 'NOT posted' "$T/out" && ok || bad "M11 the log says NOT posted: $(cat "$T/out")"
[ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = PASS ] && ok || bad "M11 the verdict is written when GitHub is unreadable"
reset; echo 422 > "$T/st-post"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
grep -q '^alert --severity warn --id console-postmerge-qa-post fleet-propagate ' "$T/calls.log" && ok || bad "M11 a rejected POST raises console-postmerge-qa-post: $(grep '^alert' "$T/calls.log")"

# ── M4 + M6: FAIL, then a PASS on a newer sha ─────────────────────────────────
reset; echo fail > "$T/drive.mode"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
[ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "M4 verdict: '$(cat "$QD/$SA/verdict" 2>/dev/null)'"
grep -qx 'FAIL: /now@375: horizontal body scroll' "$T/posted-4242" 2>/dev/null && ok || bad "M4 the comment carries the FAIL line"
grep -qx "POST-MERGE QA: FAIL at $SA" "$T/posted-4242" 2>/dev/null && ok || bad "M4 POST-MERGE QA: FAIL line"
[ "$(cnt '^alert --severity warn --id console-postmerge-qa fleet-propagate ')" = 1 ] && ok || bad "M6 want one console-postmerge-qa warn: $(grep '^alert' "$T/calls.log")"
grep '^alert --severity warn --id console-postmerge-qa fleet-propagate ' "$T/calls.log" | grep -F "${SA:0:7}" | grep -F 'horizontal body scroll' | grep -qF "state/console-postmerge-qa/$SA/qa.md" \
  && ok || bad "M6 the alert names the sha, the first failure and qa.md"
: > "$T/calls.log"; rm -f "$T/drive.mode"; pulls_for "$SB"; mkdist "$SB"; runq "$SB" "$QD/dist-$SB"
[ "$(cat "$QD/$SB/verdict" 2>/dev/null)" = PASS ] && ok || bad "M6 the newer sha passes"
grep -q '^alert --resolve --id console-postmerge-qa fleet-propagate ' "$T/calls.log" && ok || bad "M6 PASS resolves console-postmerge-qa"
grep -q '^alert --resolve --id console-postmerge-qa-notcovered fleet-propagate ' "$T/calls.log" && ok || bad "M6 PASS resolves console-postmerge-qa-notcovered"
grep -q '^alert --severity' "$T/calls.log" && bad "M6 a PASS raised an alert" || ok

# ── M5: the edges that are not PASS ──────────────────────────────────────────
for c in rc0fail:FAIL shots0:FAIL "zero:NOT_COVERED drive observed no screen" "nocov:NOT_COVERED"; do
  reset; echo "${c%%:*}" > "$T/drive.mode"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
  v=$(cat "$QD/$SA/verdict" 2>/dev/null)
  case "$v" in "${c#*:}"*) ok ;; *) bad "M5 ${c%%:*}: verdict '$v', want '${c#*:}'" ;; esac
done
grep -q '^alert --severity warn --id console-postmerge-qa-notcovered fleet-propagate ' "$T/calls.log" && ok || bad "M5 NOT_COVERED raises the notcovered warn"

# ── M7: exit paths ───────────────────────────────────────────────────────────
reset; touch "$T/upload.fail"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
case "$(cat "$QD/$SA/verdict" 2>/dev/null)" in "NOT_COVERED alias deploy failed"*) ok ;; *) bad "M7 upload: verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'" ;; esac
[ "$(cnt '^npx ')" = 1 ] && [ "$(cnt 'api/qa/session')" = 0 ] && ok || bad "M7 upload failed: no mint"
grep -qx "No screen of $URL was observed." "$T/posted-4242" 2>/dev/null && ! grep -q '^Drove ' "$T/posted-4242" \
  && ok || bad "M7 a NOT COVERED comment does not claim a drive: $(cat "$T/posted-4242" 2>/dev/null)"
[ "$(cnt '^alert --severity warn --id console-postmerge-qa-notcovered ')" = 1 ] && ok || bad "M7 upload failed: one notcovered alert"
grep -qF "$TOK" "$T/out" && bad "M9 the Cloudflare token reached the log on a failed upload" || ok
[ ! -e "$QD/dist-$SA" ] && nosnap && ok || bad "M7 upload failed: dist and snapshot removed"
reset; touch "$T/notoken"; mkdist "$SA"; runq "$SA" "$QD/dist-$SA"
case "$(cat "$QD/$SA/verdict" 2>/dev/null)" in "NOT_COVERED no QA session minted"*) ok ;; *) bad "M7 no token: verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'" ;; esac
[ "$(cnt '^node ')" = 0 ] && ok || bad "M7 no token: no drive"
grep -q "^curl .*Authorization: Bearer $HSEC" "$T/calls.log" && ok || bad "M7 the mint carries HARNESS_SECRET from global.env"
nosnap && ok || bad "M7 no token: no snapshot left"
reset; mkdist "$SA"; runq "$SA" "$QD/dist-$SA" CONSOLE_POSTMERGE_QA=0
[ ! -e "$QD/dist-$SA" ] && [ ! -e "$QD/$SA/verdict" ] && [ "$(cnt '^npx ')" = 0 ] && ok || bad "M7 knob 0: dist removed, no verdict, no deploy"
reset; mkdist "$SA"; runq "$SA" "$QD/dist-$SA" CONSOLE_POSTMERGE_QA=yes
[ ! -e "$QD/dist-$SA" ] && [ "$(cnt '^npx ')" = 0 ] && ok || bad "M7 knob 'yes' reads as the default 0"
reset; mkdist "$SA"; echo 1 > "$T/set/lane.fleet-propagate.console_postmerge_qa"; runq "$SA" "$QD/dist-$SA" CONSOLE_POSTMERGE_QA=
[ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = PASS ] && ok || bad "M7 the settings row turns it on when the env is empty"
reset; mkdist "$SA"; exec 7>"$HB/locks/console-postmerge-qa.lock"; flock -n 7; runq "$SA" "$QD/dist-$SA"; exec 7>&-
[ -e "$QD/dist-$SA/index.html" ] && [ ! -e "$QD/$SA/verdict" ] && [ "$(cnt '^npx ')" = 0 ] && ok || bad "M7 lock held: dist kept, no verdict, no deploy"
nosnap && ok || bad "M7 lock held: no snapshot"

# ── M8: dedupe before spend ──────────────────────────────────────────────────
reset; mkdist "$SA"; mkdir -p "$QD/$SA"; echo PASS > "$QD/$SA/verdict"; runq "$SA" "$QD/dist-$SA"
[ "$(cnt '^npx ')" = 0 ] && [ "$(cnt '^curl ')" = 0 ] && ok || bad "M8 a verdict there: no npx, no curl: $(cat "$T/calls.log")"
[ ! -e "$QD/dist-$SA" ] && ok || bad "M8 the dist is removed"

# ── M12: argument guard ──────────────────────────────────────────────────────
reset; mkdir -p "$T/elsewhere/dist-$SA"; echo keep > "$T/elsewhere/dist-$SA/sentinel"
mkdist "$SA"
runq "${SA:0:7}" "$QD/dist-$SA"
[ "$(cnt '^npx ')" = 0 ] && [ -e "$QD/dist-$SA/index.html" ] && ok || bad "M12 a 7-hex sha: no deploy, nothing removed"
runq "$SA" "$T/elsewhere/dist-$SA"
[ "$(cnt '^npx ')" = 0 ] && [ -e "$T/elsewhere/dist-$SA/sentinel" ] && ok || bad "M12 a dist outside the state dir: no deploy, the sentinel survives"
runq "$SA" "$QD/dist-$SB"
[ "$(cnt '^npx ')" = 0 ] && [ -e "$QD/dist-$SA/index.html" ] && ok || bad "M12 a dist of another sha: no deploy"
[ ! -e "$QD/$SA/verdict" ] && ok || bad "M12 a refused argument writes no verdict"

# ── M1 + M2: the launch from the real deploy script ──────────────────────────
rund() {
  : > "$T/calls.log"; rm -f "$T/set/deploy.console-ui.sha"
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" GH_ETAG=0 TMPDIR="$T" CONSOLE_PAGES_PROBE_WAIT_S=0 \
      CONSOLE_PAGES_URL=https://pages-fixture.example.invalid "$@" bash "$HB/bin/console-pages-deploy.sh" ) > "$T/dout" 2>&1
  DRC=$?
}
reset; rund
[ "$DRC" = 0 ] && grep -q "console-ui deployed at ${SA:0:7}" "$T/dout" && ok || bad "M1 the deploy itself ran: $(cat "$T/dout")"
[ ! -e "$QD/dist-$SA" ] && ! grep -q 'post-merge QA launched' "$T/dout" && ok || bad "M1 knob absent: no launch"
reset; printf yes > "$T/set/lane.fleet-propagate.console_postmerge_qa"; rund
[ ! -e "$QD/dist-$SA" ] && ! grep -q 'post-merge QA launched' "$T/dout" && ok || bad "M1 knob 'yes': no launch"
reset; printf 1 > "$T/set/lane.fleet-propagate.console_postmerge_qa"; chmod -x "$HB/bin/console-postmerge-qa.sh"; rund
chmod +x "$HB/bin/console-postmerge-qa.sh"
[ ! -e "$QD/dist-$SA" ] && ! grep -q 'post-merge QA launched' "$T/dout" && ok || bad "M1 no QA script: no launch"

# A dist copy that fails launches nothing (the state dir is a file here).
reset; scratch_rm "$QD"; : > "$QD"; printf 1 > "$T/set/lane.fleet-propagate.console_postmerge_qa"; rund
grep -q "post-merge QA not launched at ${SA:0:7}: the copy of dist/ failed" "$T/dout" && ! grep -q 'post-merge QA launched' "$T/dout" \
  && ok || bad "M1 a failed dist copy: no launch, one line: $(cat "$T/dout")"
rm -f "$QD"

mv "$HB/bin/console-postmerge-qa.sh" "$HB/bin/console-postmerge-qa.real.sh"
cat > "$HB/bin/console-postmerge-qa.sh" <<EOF
#!/bin/bash
printf 'wrapper %s %s index=%s\n' "\$1" "\$2" "\$(cat "\$2/index.html" 2>/dev/null)" >> "$T/wrapper.log"
exec bash "$HB/bin/console-postmerge-qa.real.sh" "\$@"
EOF
chmod +x "$HB/bin/console-postmerge-qa.sh"
reset; rm -f "$T/wrapper.log"; printf 1 > "$T/set/lane.fleet-propagate.console_postmerge_qa"
printf 5 > "$T/set/lane.fleet-propagate.console_postmerge_qa_timeout_s"; rund
grep -q "post-merge QA launched at ${SA:0:7}" "$T/dout" && ok || bad "M2 the launch line: $(cat "$T/dout")"
grep -q 'CONSOLE_POSTMERGE_QA_TIMEOUT_S=5 is outside 120..3600 — using 900' "$T/dout" && ok || bad "M2 an out-of-range timeout is one line and the default: $(cat "$T/dout")"
i=0; while [ ! -s "$QD/$SA/verdict" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
grep -qx "wrapper $SA $QD/dist-$SA index=<html>shipped</html>" "$T/wrapper.log" 2>/dev/null \
  && ok || bad "M2 the QA run gets the sha and the kept dist: $(cat "$T/wrapper.log" 2>/dev/null)"
[ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = PASS ] && ok || bad "M2 verdict after the launch: '$(cat "$QD/$SA/verdict" 2>/dev/null)' $(cat "$HB/logs/console-postmerge-qa.log" 2>/dev/null)"
sleep 0.3
[ ! -e "$QD/dist-$SA" ] && ok || bad "M2 the kept dist is removed after the run"
ls -d "$QD"/dist-*.tmp.* >/dev/null 2>&1 && bad "M2 a half copy was left" || ok
grep -q "^npx .*--branch postmerge-qa --commit-hash $SA " "$T/calls.log" && ok || bad "M2 the launched run deployed the alias"
[ -s "$HB/logs/console-postmerge-qa.log" ] && ok || bad "M2 the run writes logs/console-postmerge-qa.log"
mv "$HB/bin/console-postmerge-qa.real.sh" "$HB/bin/console-postmerge-qa.sh"

echo "console-postmerge-qa.bh-5909: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
