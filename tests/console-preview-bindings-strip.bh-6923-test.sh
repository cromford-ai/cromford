#!/bin/bash
# tests/console-preview-bindings-strip.bh-6923-test.sh — the console preview
# lane removes production bindings from the Pages PREVIEW environment itself
# (one PATCH that touches only deployment_configs.preview), re-reads the
# project, and deploys only when the re-read is clean (BH-6923).
#
# Drives the REAL hub lane bin/console-preview-deploy.sh against a scratch
# harness (scratch_install_closure), a scratch origin with refs/pull/<n>/head,
# and stubs for gh, npm, npx, node and curl. The curl stub answers the Pages
# project GET from $T/cfproject and records each PATCH body.
#
#   S1 CONSOLE_DB + HARNESS_SECRET + a plain VITE_X, knob unset: exactly one
#      PATCH with the null body, the re-read is clean, 1 deploy, 1 log-only
#      notice naming both, 1 resolve, no bindings alert
#   S2 CONSOLE_PREVIEW_STRIP_BINDINGS=0: no PATCH, no deploy, 1 bindings alert
#   S3 no PATCH body carries a production key or VITE_X
#   S4 Cloudflare answers success but keeps the bindings: 1 PATCH (not 2), no
#      deploy, an alert that says "after the lane removed them"
#   S5 the PATCH fails (curl rc 22, or success:false): no deploy, no build, an
#      alert that says "could not remove"
#   S6 the only finding is an array-typed binding: no PATCH, no deploy, alert
#   S7 round trip: the PATCH body applied as a merge patch gives a clean
#      re-read, and the lane deploys
#   S8 a clean config: no PATCH, no notice, 1 deploy
#   S9 the driver prints a PREVIEW GAP: line; the PR comment carries it
#   S10 the API token is in no log line and no PATCH body
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-preview-bindings-strip.bh-6923-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git jq flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
[ -f "$DIR/bin/console-preview-deploy.sh" ] || { echo "FAIL: bin/console-preview-deploy.sh does not exist"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONSOLE_PREVIEW_DEPLOY CONSOLE_PREVIEW_MAX_PER_RUN CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN \
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_QA_SCREENS CONSOLE_PREVIEW_WRANGLER CONSOLE_PREVIEW_STRIP_BINDINGS
SLUG=o/console-fixture
TOK=tok-fixture-6923

# ── fixture: origin with one console PR, a hub checkout, a scratch harness ────
O="$T/origin.git"; W="$T/work"; CK="$T/ck"; HB="$T/h"
git init -q --bare -b main "$O"; git init -q -b main "$W"
mkdir -p "$W/console-ui/src" "$W/console-ui/functions/api" "$W/worker/jobs" "$W/catalog"
echo '{"name":"console-ui"}' > "$W/console-ui/package.json"
echo 'export const who = "main";' > "$W/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$W/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$W/worker/jobs/wrangler.jsonc"
echo '{}' > "$W/catalog/x.json"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
git -C "$W" checkout -q -B pr21 main
echo 'change 21' >> "$W/console-ui/src/app.js"; git -C "$W" commit -qam "pr 21"
git -C "$W" push -q "$O" "HEAD:refs/pull/21/head"; S21=$(git -C "$W" rev-parse HEAD)
git clone -q "$O" "$CK"

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin"
scratch_install_closure bin/console-preview-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-preview-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=%s\n' hsec-fixture-6923-not-real > "$HB/env/global.env"
QATOK="1791700000.$(printf 'cd%.0s' $(seq 1 32))"
# The live refusal on 2026-10-15: CONSOLE_DB + HARNESS_SECRET in the preview.
DIRTY='{"success":true,"result":{"deployment_configs":{
  "preview":{"env_vars":{"VITE_X":{"type":"plain_text","value":"1"},"HARNESS_SECRET":{"type":"secret_text"}},"d1_databases":{"CONSOLE_DB":{"id":"db-fixture"}},"compatibility_date":"2024-01-01"},
  "production":{"env_vars":{"HARNESS_SECRET":{"type":"secret_text"}},"d1_databases":{"CONSOLE_DB":{"id":"db-fixture"}}}}}}'
CLEAN='{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{"VITE_X":{"value":"1"}}},"production":{"d1_databases":{"CONSOLE_DB":{"id":"x"}}}}}}'

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
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  ci) exit 0 ;;
  run) mkdir -p dist; echo '<html>' > dist/index.html; exit 0 ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit 0
EOF
# curl: the Pages project GET and PATCH, and the console worker's QA mint.
# patch.mode: apply (merge patch onto cfproject), keep (success, no change),
# rc22 (curl fails), sfalse (success:false).
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
args="\$*"
case "\$args" in
  *"/pages/projects/"*)
    if [[ " \$args " == *" -X PATCH "* ]]; then
      printf 'curl PATCH\n' >> "$T/calls.log"
      body=""; prev=""
      for a in "\$@"; do [ "\$prev" = --data-binary ] && body="\${a#@}"; prev="\$a"; done
      k=\$(( \$(ls "$T"/patch.*.json 2>/dev/null | wc -l) + 1 ))
      cp "\$body" "$T/patch.\$k.json"
      case "\$(cat "$T/patch.mode" 2>/dev/null || echo apply)" in
        rc22) exit 22 ;;
        sfalse) echo '{"success":false,"errors":[{"code":8000000,"message":"fixture"}]}'; exit 0 ;;
        keep) cat "$T/cfproject"; exit 0 ;;
        apply)
          jq --slurpfile p "\$body" 'def mp(\$q): if (\$q|type) == "object" then reduce (\$q|to_entries[]) as \$e ((if type == "object" then . else {} end);
               if \$e.value == null then del(.[\$e.key]) else .[\$e.key] = (.[\$e.key] | mp(\$e.value)) end) else \$q end;
             .result |= mp(\$p[0])' "$T/cfproject" > "$T/cfproject.new" && mv "$T/cfproject.new" "$T/cfproject"
          cat "$T/cfproject"; exit 0 ;;
      esac
    fi
    printf 'curl GET project\n' >> "$T/calls.log"
    cat "$T/cfproject" ;;
  *"/api/qa/session"*) printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'node %s\n' "\$*" >> "$T/calls.log"
[ -f "$T/gapline" ] && echo 'PREVIEW GAP: GET /api/coord/whoami — HARNESS_SECRET not bound in the preview environment'
printf 'SCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: PASS\n'; exit 0
STUB
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
chmod +x "$T/sbin/"* "$HB/bin/lane-alert.sh"

jq -nc --arg s "$S21" '[{number:21, head:{ref:"ticket/bh-6923", sha:$s, repo:{full_name:"o/console-fixture"}}, base:{ref:"main"}}]' > "$T/openprs"
reset() {
  rm -f "$T/calls.log" "$T"/posted-* "$T"/patch.*.json "$T/patch.mode" "$T/gapline"
  printf '%s\n' "$1" > "$T/cfproject"
  scratch_rm "$HB/state/console-preview-deploy"; scratch_rm "$HB/state/console-preview-qa"; touch "$T/calls.log"
}
run() {
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="$T/sbin:$PATH" LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T" \
      HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CONSOLE_PREVIEW_BUILD_TMP="$T" \
      CONSOLE_PREVIEW_DEPLOY=1 \
      CONSOLE_PAGES_URL=https://pages-fixture.example.invalid "$@" bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
  RC=$?
}
deploys() { grep -c '^npx .*pages deploy' "$T/calls.log"; }
patches() { grep -c '^curl PATCH' "$T/calls.log"; }
WANT='{"deployment_configs":{"preview":{"d1_databases":{"CONSOLE_DB":null},"env_vars":{"HARNESS_SECRET":null}}}}'
ALLPATCH=()

# ── S1: the two live findings are removed, then the head deploys ─────────────
reset "$DIRTY"; run
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC $(cat "$T/out")"
[ "$(patches)" = 1 ] && ok || bad "S1 want exactly 1 PATCH, got $(patches): $(cat "$T/calls.log")"
jq -e '.deployment_configs.preview | (keys == ["d1_databases","env_vars"]) and (.d1_databases == {"CONSOLE_DB":null}) and (.env_vars == {"HARNESS_SECRET":null})' "$T/patch.1.json" >/dev/null 2>&1 \
  && ok || bad "S1 PATCH body, want $WANT: $(cat "$T/patch.1.json" 2>/dev/null)"
[ "$(deploys)" = 1 ] && ok || bad "S1 want 1 deploy, got $(deploys): $(cat "$T/out")"
grep -q 'deploys 1' "$T/out" && ok || bad "S1 run summary: $(tail -1 "$T/out")"
n=$(grep -c '^alert .*--log-only' "$T/calls.log")
[ "$n" = 1 ] && grep '^alert .*--log-only' "$T/calls.log" | grep -q 'CONSOLE_DB' \
  && grep '^alert .*--log-only' "$T/calls.log" | grep -q 'HARNESS_SECRET' && ok || bad "S1 want 1 log-only notice naming both: $(grep alert "$T/calls.log")"
[ "$(grep -c '^alert --resolve --id console-preview-bindings ' "$T/calls.log")" = 1 ] && ok || bad "S1 want 1 resolve: $(grep alert "$T/calls.log")"
grep -q '^alert --id console-preview-bindings ' "$T/calls.log" && bad "S1 a bindings alert fired: $(grep alert "$T/calls.log")" || ok
# Status evidence: the "removed" line is printed after the re-read, not before.
grep -q 'removed from the preview environment: .*CONSOLE_DB.*HARNESS_SECRET' "$T/out" && ok || bad "S1 no removed line: $(cat "$T/out")"
order=$(grep -E '^curl (PATCH|GET project)' "$T/calls.log" | head -3 | tr '\n' '|')
[ "$order" = 'curl GET project|curl PATCH|curl GET project|' ] && ok || bad "S1 call order: $order"
cp "$T/patch.1.json" "$T/keep.s1.json"; ALLPATCH=("$T/keep.s1.json")
# The production environment still binds both.
jq -e '.result.deployment_configs.production | (.d1_databases.CONSOLE_DB != null) and (.env_vars.HARNESS_SECRET != null)' "$T/cfproject" >/dev/null \
  && ok || bad "S1 production lost a binding: $(cat "$T/cfproject")"
grep -qF "$TOK" "$T/out" "$HB"/logs/* 2>/dev/null && bad "S10 the token reached a log line" || ok

# ── S2: knob 0 = main's behaviour ────────────────────────────────────────────
reset "$DIRTY"; run CONSOLE_PREVIEW_STRIP_BINDINGS=0
[ "$(patches)" = 0 ] && [ "$(deploys)" = 0 ] && ok || bad "S2 knob 0: patches=$(patches) deploys=$(deploys)"
[ "$(grep -c '^alert --id console-preview-bindings ' "$T/calls.log")" = 1 ] && ok || bad "S2 want 1 bindings alert: $(grep alert "$T/calls.log")"
grep -q '^alert .*--log-only' "$T/calls.log" && bad "S2 a notice with knob 0" || ok
grep '^alert --id console-preview-bindings ' "$T/calls.log" | grep -q 'CONSOLE_PREVIEW_STRIP_BINDINGS=0' && ok || bad "S2 alert names the knob: $(grep alert "$T/calls.log")"

# ── S4: Cloudflare keeps the bindings ─────────────────────────────────────────
reset "$DIRTY"; echo keep > "$T/patch.mode"; run
[ "$(patches)" = 1 ] && ok || bad "S4 want 1 PATCH (one per run), got $(patches)"
[ "$(deploys)" = 0 ] && ok || bad "S4 deployed on a dirty re-read"
grep '^alert --id console-preview-bindings ' "$T/calls.log" | grep -q 'after the lane removed them' && ok || bad "S4 alert text: $(grep alert "$T/calls.log")"
grep -q 'removed from the preview environment' "$T/out" && bad "S4 claimed removal on a dirty re-read" || ok
grep -q '^alert .*--log-only' "$T/calls.log" && bad "S4 a notice on a dirty re-read" || ok
cp "$T/patch.1.json" "$T/keep.s4.json"; ALLPATCH+=("$T/keep.s4.json")

# ── S5: the PATCH fails ───────────────────────────────────────────────────────
for mode in rc22 sfalse; do
  reset "$DIRTY"; echo "$mode" > "$T/patch.mode"; run
  [ "$(patches)" = 1 ] && [ "$(deploys)" = 0 ] && ok || bad "S5 ($mode) patches=$(patches) deploys=$(deploys)"
  grep '^alert --id console-preview-bindings ' "$T/calls.log" | grep -q 'could not remove' && ok || bad "S5 ($mode) alert text: $(grep alert "$T/calls.log")"
  grep -q '^npm ci' "$T/calls.log" && bad "S5 ($mode) the build ran" || ok
done

# ── S6: an array-typed binding cannot be nulled ──────────────────────────────
reset '{"success":true,"result":{"deployment_configs":{"preview":{"queue_producers":[{"x":1}]}}}}'; run
[ "$(patches)" = 0 ] && [ "$(deploys)" = 0 ] && ok || bad "S6 patches=$(patches) deploys=$(deploys)"
grep -q '^alert --id console-preview-bindings ' "$T/calls.log" && ok || bad "S6 no alert"

# ── S7: round trip with a third binding kind ─────────────────────────────────
reset '{"success":true,"result":{"deployment_configs":{"preview":{"kv_namespaces":{"K":{"namespace_id":"n"}},"env_vars":{"API_TOKEN":{"type":"plain_text","value":"x"},"PLAIN":{"value":"y"}}},"production":{}}}}'
run
[ "$(patches)" = 1 ] && [ "$(deploys)" = 1 ] && ok || bad "S7 patches=$(patches) deploys=$(deploys): $(cat "$T/out")"
jq -e '.result.deployment_configs.preview | (.kv_namespaces == {}) and (.env_vars | keys == ["PLAIN"])' "$T/cfproject" >/dev/null \
  && ok || bad "S7 re-read: $(cat "$T/cfproject")"
cp "$T/patch.1.json" "$T/keep.s7.json" 2>/dev/null; ALLPATCH+=("$T/keep.s7.json")

# ── S3 + S10 over every PATCH body sent above ───────────────────────────────
for p in "${ALLPATCH[@]}"; do
  jq -e '(.deployment_configs | has("production") | not) and (keys == ["deployment_configs"]) and (.deployment_configs | keys == ["preview"])' "$p" >/dev/null 2>&1 \
    && ok || bad "S3 $p carries more than the preview: $(cat "$p")"
  grep -q 'VITE_X\|PLAIN' "$p" && bad "S3 $p names a plain env var: $(cat "$p")" || ok
  grep -qF "$TOK" "$p" && bad "S10 the token is in $p" || ok
done

# ── S8: a clean config ───────────────────────────────────────────────────────
reset "$CLEAN"; run
[ "$(patches)" = 0 ] && [ "$(deploys)" = 1 ] && ok || bad "S8 patches=$(patches) deploys=$(deploys)"
grep -q '^alert ' "$T/calls.log" && bad "S8 an alert or notice on a clean config: $(grep alert "$T/calls.log")" || ok

# ── S9: the PREVIEW GAP line reaches the PR comment ──────────────────────────
reset "$CLEAN"; touch "$T/gapline"; run
grep -qx 'PREVIEW GAP: GET /api/coord/whoami — HARNESS_SECRET not bound in the preview environment' "$T/posted-21" 2>/dev/null \
  && ok || bad "S9 the comment has no PREVIEW GAP line: $(cat "$T/posted-21" 2>/dev/null)"
grep -qx "<!-- console-qa sha=$S21 result=PASS -->" "$T/posted-21" 2>/dev/null && ok || bad "S9 the QA marker: $(cat "$T/posted-21" 2>/dev/null)"
# Inside the code block: after the first ``` and before the second.
awk '/^```$/{f++} f==1 && /^PREVIEW GAP: /{print "in"}' "$T/posted-21" | grep -q in && ok || bad "S9 the gap line is outside the code block"

echo "console-preview-bindings-strip.bh-6923: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
