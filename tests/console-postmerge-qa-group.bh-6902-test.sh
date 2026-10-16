#!/bin/bash
# tests/console-postmerge-qa-group.bh-6902-test.sh — BH-6902 slice C1: a FAIL of
# the console post-merge QA (bin/console-postmerge-qa.sh) hands the driver's
# observed.json to bin/lib/group-findings.sh, which files one issue per screen
# on HARNESS_REPO under the board `cromford`.
#
#   C1  knob unset, FAIL: the ledger is in the sha dir, every row `off`, no
#       issue POST; the verdict is FAIL and the warn alert fires
#   C2  knob on, FAIL with 3 findings on /kanban (2 widths) and /jobs: exactly
#       2 issue POSTs, one per screen, and the summary line in the log
#   C3  knob on, an open issue already carries the /kanban group marker: one
#       comment on it, one new issue for /jobs only
#   C4  PASS and NOT_COVERED: no qa-findings.jsonl, no ledger; the QA token is
#       in no file of the sha dir and in no POST body (FAIL run)
#   C5  the real bin/console-qa-run.mjs with a fake playwright: observed.json
#       keeps the TypeError and drops each preview-gap 503; gf_from_observed
#       yields findings for / only
#   C6  knob on, the issue POST answers 500: ledger rows `failed`, exit 0, the
#       verdict stays FAIL, and the FAIL alert text carries `failed 1`
#   C7  FAIL with no readable observed.json: never "0 findings" — the log and
#       the FAIL alert say it is unreadable, no issue is filed
#   C8  HARNESS_REPO empty (no bin/lib/deployment.sh): the helper is not called, the verdict is FAIL
#
# Drives the REAL bin/console-postmerge-qa.sh in a scratch harness, with the
# stub set of tests/console-postmerge-qa.bh-5909-test.sh and the gh REST stub
# of tests/lib/gh-rest-fx.sh.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-postmerge-qa-group.bh-6902-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git jq flock timeout; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# BH-7123 wave B: this suite pins the grouping and filing mechanics with medium
# console findings. The follow-up floor (review.followup_min_level, seeded
# `core`) would hold those groups; it has its own cases in
# tests/followup-chain-guard.bh-7123-test.sh, so here it reads `always`.
export REVIEW_LEVEL_FOLLOWUP_MIN_LEVEL=always
unset CONSOLE_POSTMERGE_QA CONSOLE_POSTMERGE_QA_SCREENS CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN \
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_WRANGLER CONSOLE_QA_WIDTHS CONSOLE_WORKER_URL GROUP_FINDINGS GROUP_FINDINGS_URGENT_RANK
SLUG=o/console-fixture
QATOK="1791700000.$(printf 'cd%.0s' $(seq 1 32))"
REG=$(rendered_registry)

# ── C5: the real driver records the record it judged ─────────────────────────
if command -v node >/dev/null; then
  FR="$T/fakeroot"; mkdir -p "$FR/node_modules/playwright"
  cat > "$FR/node_modules/playwright/index.js" <<'FAKE'
// A fake playwright: `/` answers one preview-gap 503 and logs a TypeError;
// `/now` answers one preview-gap 503 only.
const E503 = "Failed to load resource: the server responded with a status of 503 ()";
const GAP = JSON.stringify({ error: "HARNESS_SECRET is not set on this Pages project" });
function resp(base, status, path, body) {
  return { status: () => status, url: () => base + path, request: () => ({ method: () => "GET" }), text: () => Promise.resolve(body) };
}
exports.chromium = {
  launch: async () => ({
    close: async () => {},
    newContext: async () => {
      const rl = [];
      return {
        on: (ev, fn) => { if (ev === "response") rl.push(fn); },
        request: { get: async () => ({ status: () => 200 }) },
        newPage: async () => {
          const pl = {}; let cur = "about:blank";
          return {
            setViewportSize: () => {},
            on: (ev, fn) => { (pl[ev] = pl[ev] || []).push(fn); },
            goto: async (u) => {
              cur = u; const url = new URL(u);
              if (u.includes("/qa-login/")) return { status: () => 200 };
              for (const fn of rl) fn(resp(url.origin, 503, "/api/coord/whoami", GAP));
              const errs = url.pathname === "/" ? [E503, "TypeError: x is undefined"] : [E503];
              for (const t of errs) for (const fn of pl.console || []) fn({ type: () => "error", text: () => t });
              return { status: () => 200 };
            },
            waitForTimeout: async () => {},
            url: () => cur,
            evaluate: async () => false,
            screenshot: async () => {},
            close: async () => {},
          };
        },
      };
    },
  }),
};
FAKE
  mkdir -p "$T/c5"
  CONSOLE_QA_TOKEN="$QATOK" CONSOLE_QA_WIDTHS=1280 node "$DIR/bin/console-qa-run.mjs" \
    https://postmerge-qa.fixture.example.invalid "$FR" "$T/c5" / /now > "$T/c5.out" 2>&1
  C5RC=$?
  [ "$C5RC" = 1 ] && grep -qx 'QA: FAIL' "$T/c5.out" && ok || bad "C5 the TypeError fails the drive (rc=$C5RC): $(cat "$T/c5.out")"
  [ "$(jq -c '.screens[0].consoleErrors' "$T/c5/observed.json" 2>/dev/null)" = '["TypeError: x is undefined"]' ] \
    && ok || bad "C5 / keeps the TypeError and drops the gap 503: $(jq -c '.screens' "$T/c5/observed.json" 2>/dev/null)"
  [ "$(jq -c '.screens[1].consoleErrors' "$T/c5/observed.json" 2>/dev/null)" = '[]' ] \
    && ok || bad "C5 /now drops its gap 503: $(jq -c '.screens' "$T/c5/observed.json" 2>/dev/null)"
  jq -e '.gaps | length == 1' "$T/c5/observed.json" >/dev/null 2>&1 && ok || bad "C5 the gap stays on record in .gaps"
  ( . "$DIR/bin/lib/group-findings.sh" || exit 9; gf_from_observed cromford "$T/c5/observed.json" ) > "$T/c5.jsonl" 2>"$T/c5.err"
  [ "$(jq -s -c '[.[].screen_or_flow] | unique' "$T/c5.jsonl" 2>/dev/null)" = '["/"]' ] \
    && ok || bad "C5 findings for / only: $(cat "$T/c5.jsonl" "$T/c5.err")"
  grep -qF "$QATOK" "$T/c5/observed.json" && bad "C5 the QA token is in observed.json" || ok
else
  echo "node missing — C5 skipped"
fi

# ── fixture: a hub checkout and a scratch harness ────────────────────────────
CK="$T/ck"; HB="$T/h"; QD="$HB/state/console-postmerge-qa"
git init -q -b main "$CK"
mkdir -p "$CK/console-ui/src" "$CK/console-ui/functions/api" "$CK/worker/jobs"
echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
echo 'export const who = "shipped";' > "$CK/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$CK/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$CK/worker/jobs/wrangler.jsonc"
git -C "$CK" add -A; git -C "$CK" commit -qm base
SA=$(git -C "$CK" rev-parse HEAD)

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin"
scratch_install_closure bin/console-postmerge-qa.sh "$HB" >/dev/null || bad "closure of bin/console-postmerge-qa.sh"
[ -f "$HB/bin/lib/group-findings.sh" ] && ok || bad "the closure of bin/console-postmerge-qa.sh does not carry bin/lib/group-findings.sh"
printf 'CLOUDFLARE_API_TOKEN=tok-fixture-cf\n' > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=hsec-fixture-not-real\n' > "$HB/env/global.env"
printf '#!/bin/bash\nexit 2\n' > "$HB/bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
cat > "$T/sbin/npx" <<'EOF'
#!/bin/bash
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
EOF
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
case "\$*" in
  *"/api/qa/session"*) printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
# node: the QA driver. Its observed.json is the fixture (the real driver writes
# it through clean(), so it carries no token); it echoes the token on stdout.
cat > "$T/sbin/node" <<STUB
#!/bin/bash
echo "signing in with \$CONSOLE_QA_TOKEN"
OUT="\$4"
case "\$(cat "$T/drive.mode" 2>/dev/null || echo fail)" in
  pass) printf 'SCREEN /kanban 1280 ok\nQA COVERAGE: screens=6 flows=0 shots=6\nQA: PASS\n'; exit 0 ;;
  zero) cp "$T/observed.json" "\$OUT/observed.json"
        printf 'FAIL: the QA session did not hold\nQA COVERAGE: screens=0 flows=0 shots=0\nQA: FAIL\n'; exit 1 ;;
  noobs) printf 'FAIL: drive: crashed\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: FAIL\n'; exit 1 ;;
  fail) cp "$T/observed.json" "\$OUT/observed.json"
        printf 'FAIL: /kanban@1280: 1 console error(s): TypeError: a\nQA COVERAGE: screens=6 flows=0 shots=6\nQA: FAIL\n'; exit 1 ;;
esac
STUB
chmod +x "$T/sbin/"* "$HB/bin/jobs-client.sh" "$HB/bin/lane-alert.sh"
rec() { # rec <path> <viewport> [jq update]
  jq -nc --arg p "$1" --arg v "$2" '{path:$p, viewport:$v, url:null, status:200, landedOnAuthWall:false,
    consoleErrors:[], failedRequests:[], horizontalScroll:false, nativeDialog:null, shot:"x.png", error:null}' | jq -c "${3:-.}"
}
{ rec / 1280; rec / 375
  rec /kanban 1280 '.consoleErrors = ["TypeError: a"]'; rec /kanban 375 '.horizontalScroll = true'
  rec /jobs 1280 '.status = 500'; rec /jobs 375; } | jq -s '{base:"https://x", paths:["/","/kanban","/jobs"], screens:., failures:[], gaps:[]}' > "$T/observed.json"

# gh: the REST stub; every POST is recorded (path, body) by the extra hook.
( ghfx_init )
GHFX="$T"
ghfx_extra <<'SH'
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  n=$(( $(cat "$GHFX/post.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHFX/post.n"
  mkdir -p "$GHFX/posts"; printf '%s\n' "$5" > "$GHFX/posts/$n.path"
  for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$GHFX/posts/$n.body" ;; title=*) printf '%s\n' "${a#title=}" > "$GHFX/posts/$n.title" ;; esac; done
  case "$5" in
    */issues) st=$(cat "$GHFX/issue-post.st" 2>/dev/null || echo 201)
      case "$st" in 2*) printf 'HTTP/1.1 %s Created\r\n\r\n{"number":%s,"html_url":"https://github.com/o/console-fixture/issues/%s"}' "$st" $((500+n)) $((500+n)) ;;
        *) printf 'HTTP/1.1 %s Error\r\n\r\n{"message":"stub"}' "$st" ;; esac ;;
    *) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":%s,"html_url":"https://github.com/o/console-fixture/issues/1#c%s"}' "$n" "$n" ;;
  esac
  exit 0
fi
SH
jq -nc --arg s "$SA" '[{number:4242, merge_commit_sha:$s, merged_at:"2026-10-16T00:00:00Z"}]' > "$T/rest-bodies/pulls"
printf '[]' > "$T/rest-bodies/empty"

routes() { # routes [issues-body] — the reads the lane and the helper make
  printf '[]' > "$T/rest-bodies/issues"; [ -n "${1:-}" ] && printf '%s' "$1" > "$T/rest-bodies/issues"
  { echo "GET|repos/$SLUG/commits/*/pulls|200|pulls"
    echo "GET|repos/$SLUG/issues/*/comments*|200|empty"
    echo "GET|repos/$SLUG/issues|200|issues"
    echo "GET|repos/$SLUG/pulls|200|empty"; } > "$T/routes"
}
knob() { # knob [value] — the settings row for cromford; none = no row
  jq -nc --arg v "${1:-}" '{fetched_at:2000000000, seeded:{},
      values:(if $v == "" then {} else {"lib.group-findings.cromford.group_findings":$v} end)}' \
    > "$HB/state/settings-cache.json"
}
reset() {
  rm -f "$T/calls.log" "$T/drive.mode" "$T/issue-post.st" "$T/post.n"; rm -rf "$T/posts"
  : > "$T/gh-argv.log"; : > "$T/calls.log"
  scratch_rm "$QD"; mkdir -p "$QD/dist-$SA"; echo '<html>shipped</html>' > "$QD/dist-$SA/index.html"
  routes; knob
}
runq() {
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/fakebin:$T/sbin:$PATH" GHFX="$T" GH_ETAG=0 TMPDIR="$T" \
      LANE_REGISTRY="$REG" LANE_GATE_NOW=2000000000 \
      CONSOLE_PAGES_URL=https://pages-fixture.example.invalid CONSOLE_POSTMERGE_QA=1 "$@" \
      bash "$HB/bin/console-postmerge-qa.sh" "$SA" "$QD/dist-$SA" ) > "$T/out" 2>&1
  RC=$?
}
npost() { # npost <path-glob> — POSTs to a matching path
  local f n=0
  for f in "$T"/posts/*.path; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) n=$((n+1)) ;; esac
  done
  echo "$n"
}
LEDGER="$QD/$SA/findings-ledger.jsonl"
rows() { jq -s --arg a "$1" '[.[] | select(.action == $a)] | length' "$LEDGER" 2>/dev/null || echo -1; }

# ── C1: knob unset ───────────────────────────────────────────────────────────
reset; runq
[ "$RC" = 0 ] && [ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "C1 rc=$RC verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)': $(cat "$T/out")"
[ -s "$LEDGER" ] && ok || bad "C1 no ledger in the sha dir: $(ls "$QD/$SA" 2>/dev/null | tr '\n' ' ') $(cat "$T/out")"
[ "$(rows off)" = 3 ] && [ "$(jq -s 'length' "$LEDGER" 2>/dev/null)" = 6 ] && ok \
  || bad "C1 want 3 findings, each pending then off: $(cat "$LEDGER" 2>/dev/null)"
[ "$(npost "repos/$SLUG/issues")" = 0 ] && ok || bad "C1 knob off filed an issue"
grep -q "^alert --severity warn --id console-postmerge-qa fleet-propagate " "$T/calls.log" && ok || bad "C1 the FAIL alert: $(cat "$T/calls.log")"
[ "$(npost "repos/$SLUG/issues/4242/comments")" = 1 ] && ok || bad "C1 the PR comment is still posted"

# A row for another board does not turn cromford on.
reset
jq -nc '{fetched_at:2000000000, seeded:{}, values:{"lib.group-findings.project-3.group_findings":"1"}}' > "$HB/state/settings-cache.json"
runq
[ "$(rows off)" = 3 ] && [ "$(npost "repos/$SLUG/issues")" = 0 ] && ok || bad "C1 project-3's row turned cromford on: $(cat "$LEDGER" 2>/dev/null)"

# ── C2: knob on, two failing screens ─────────────────────────────────────────
reset; knob 1; runq
[ "$RC" = 0 ] && [ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "C2 rc=$RC verdict: $(cat "$T/out")"
[ "$(npost "repos/$SLUG/issues")" = 2 ] && ok || bad "C2 want 2 issue POSTs, got $(npost "repos/$SLUG/issues"): $(cat "$T/out")"
cat "$T"/posts/*.title 2>/dev/null | sort > "$T/titles"
printf '%s\n' 'QA findings: /jobs (1 items)' 'QA findings: /kanban (2 items)' | diff -q - "$T/titles" >/dev/null \
  && ok || bad "C2 titles: $(cat "$T/titles")"
grep -h '<!-- findings-group:' "$T"/posts/*.body 2>/dev/null | sort > "$T/markers"
printf '%s\n' '<!-- findings-group: cromford|/jobs -->' '<!-- findings-group: cromford|/kanban -->' | diff -q - "$T/markers" >/dev/null \
  && ok || bad "C2 markers: $(cat "$T/markers")"
grep -q 'console-postmerge-qa: group-findings: 3 findings, 2 groups, filed 2, .* (rc=0)$' "$T/out" && ok || bad "C2 the log summary: $(grep group-findings "$T/out")"
[ "$(rows filed)" = 3 ] && ok || bad "C2 ledger rows filed: $(cat "$LEDGER" 2>/dev/null)"
grep -q 'filed 2' "$T/calls.log" && bad "C2 a clean filing must not lengthen the alert" || ok

# ── C3: an open issue already holds /kanban ──────────────────────────────────
reset; knob 1
routes "$(jq -nc '[{number:77, state:"open", title:"QA findings: /kanban (1 items)", body:"<!-- findings-group: cromford|/kanban -->\nold"}]')"
runq
[ "$(npost "repos/$SLUG/issues/77/comments")" = 1 ] && ok || bad "C3 want one comment on #77: $(cat "$T"/posts/*.path 2>/dev/null | tr '\n' ' ')"
[ "$(npost "repos/$SLUG/issues")" = 1 ] && grep -qx 'QA findings: /jobs (1 items)' "$T"/posts/*.title 2>/dev/null \
  && ok || bad "C3 want one new issue, for /jobs: $(cat "$T"/posts/*.title 2>/dev/null)"

# ── C4: PASS and NOT_COVERED never call the helper; no token ─────────────────
for m in pass zero; do
  reset; knob 1; echo "$m" > "$T/drive.mode"; runq
  case "$m:$(cat "$QD/$SA/verdict" 2>/dev/null)" in pass:PASS|zero:NOT_COVERED*) ok ;; *) bad "C4 $m verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'" ;; esac
  [ ! -e "$QD/$SA/qa-findings.jsonl" ] && [ ! -e "$LEDGER" ] && ok || bad "C4 $m called the helper: $(ls "$QD/$SA" | tr '\n' ' ')"
  [ "$(npost "repos/$SLUG/issues")" = 0 ] && ok || bad "C4 $m filed an issue"
done
reset; knob 1; runq
[ -s "$LEDGER" ] && ok || bad "C4 the FAIL run wrote no ledger"
grep -rqF "$QATOK" "$QD/$SA" "$T/posts" && bad "C4 the QA token is in the sha dir or a POST body: $(grep -rlF "$QATOK" "$QD/$SA" "$T/posts")" || ok
grep -qF "$QATOK" "$T/out" && bad "C4 the QA token is in the log" || ok

# ── C6: the issue POST fails ─────────────────────────────────────────────────
reset; knob 1
routes "$(jq -nc '[{number:77, state:"open", title:"x", body:"<!-- findings-group: cromford|/kanban -->"}]')"
echo 500 > "$T/issue-post.st"; runq
[ "$RC" = 0 ] && [ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "C6 rc=$RC verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'"
[ "$(rows failed)" = 1 ] && [ "$(rows commented)" = 2 ] && ok || bad "C6 ledger: $(cat "$LEDGER" 2>/dev/null)"
grep '^alert --severity warn --id console-postmerge-qa fleet-propagate ' "$T/calls.log" | grep -q 'group-findings: 3 findings, 2 groups, filed 0, commented 1, .*failed 1' \
  && ok || bad "C6 the FAIL alert carries the failed filing: $(cat "$T/calls.log")"
[ "$(grep -c '^alert --severity warn --id console-postmerge-qa fleet-propagate ' "$T/calls.log")" = 1 ] && ok || bad "C6 one FAIL alert only"

# ── C7: observed.json unreadable ─────────────────────────────────────────────
reset; knob 1; echo noobs > "$T/drive.mode"; runq
[ "$RC" = 0 ] && [ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "C7 rc=$RC verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'"
grep -q 'console-postmerge-qa: observed.json unreadable (rc=1), nothing grouped; group-findings: 0 findings' "$T/out" \
  && ok || bad "C7 the log names the unreadable observed.json: $(grep -i 'group-findings\|observed' "$T/out")"
grep '^alert --severity warn --id console-postmerge-qa fleet-propagate ' "$T/calls.log" | grep -q 'observed.json unreadable' \
  && ok || bad "C7 the FAIL alert names the unreadable observed.json: $(cat "$T/calls.log")"
[ "$(npost "repos/$SLUG/issues")" = 0 ] && ok || bad "C7 filed an issue from nothing"

# ── C8: HARNESS_REPO empty ───────────────────────────────────────────────────
# bin/lib/deployment.sh defaults an empty HARNESS_REPO, so the slug is empty
# only on a box without that file.
reset; knob 1; runq HARNESS_REPO= HARNESS_DEPLOYMENT_FILE="$T/no-deployment.sh"
[ "$RC" = 0 ] && [ "$(cat "$QD/$SA/verdict" 2>/dev/null)" = FAIL ] && ok || bad "C8 rc=$RC verdict '$(cat "$QD/$SA/verdict" 2>/dev/null)'"
[ ! -e "$QD/$SA/qa-findings.jsonl" ] && [ ! -e "$LEDGER" ] && ok || bad "C8 the helper ran with no repo: $(ls "$QD/$SA" | tr '\n' ' ')"
grep -q 'HARNESS_REPO unset — comment NOT posted' "$T/out" && ok || bad "C8 the log says why: $(cat "$T/out")"
grep -q '^alert --severity warn --id console-postmerge-qa fleet-propagate ' "$T/calls.log" && ok || bad "C8 the FAIL alert still fires"

echo "console-postmerge-qa-group.bh-6902: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
