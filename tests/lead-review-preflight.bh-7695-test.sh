#!/bin/bash
# tests/lead-review-preflight.bh-7695-test.sh — BH-7695: a lead review on a box
# that cannot run the repo suite records `could-not-run: <item>` for the host
# suite, never a red suite, and the review still finishes with a verdict.
#
# The lead review runs the host suite in a fresh worktree that never has
# node_modules. PR #7780 failed the request there, so a lead review on an npm
# repo never finished (the operator, comment 6522650981). This pins the rebuild: no
# install, no fail, no alert; the report header names the missing item.
#
# Drives the REAL bin/lead-review.sh tick in the fixture shape of
# tests/lead-review-rules-pack.bh-3546-test.sh (curl = the jobs worker, gh = the
# REST reads, bin/agent-call.sh and bin/rules-pack.sh stubs), with
# LEAD_REVIEW_HOST_SUITE=always and a Verification Contract of `npm test`:
#   H1 deps, no node_modules -> no `npm test`, the model IS called, outcome
#      done, report `- host suite: could-not-run: node_modules ...`, the prompt's
#      Host suite section says `[NOTE] not verified here`
#   H2 prisma, no DATABASE_URL, the suite prints P1001 and exits 1 ->
#      `- host suite: could-not-run: DATABASE_URL (suite rc 1): npm test`
#   H3 prisma, no DATABASE_URL, green suite -> today's line; H3b a real red
#      (no DB signature) -> today's line
#   H4 deps, contract `bash t.sh` -> the suite runs (today's path)
#   H5 deps, contract `npm ci && npm test` -> the suite runs
#   H6 no suite-preflight.sh on the harness -> the tick still runs, the suite
#      runs, today's line
#   H7 the #2084-shaped fixture -> could-not-run: node_modules, verdict recorded
#   H8 bin/lead-review.sh calls sp_lead_suite, and its no-lib fallback keeps
#      today's two lines byte for byte
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-preflight.bh-7695-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset DATABASE_URL SUITE_PREFLIGHT_ENV

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || { echo "closure install of bin/lead-review.sh failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
cromford example-org/cromford https://bh.test    /api/board 1 box-demo
EOF

DEPS='{"scripts":{"test":"vitest run"},"dependencies":{"a":"1"},"devDependencies":{"vitest":"1"}}'
NODEPS='{"scripts":{"test":"vitest run"}}'
MK='{"name":"project-6","private":true,"scripts":{"test":"vitest run --reporter=agent"},"dependencies":{"@prisma/client":"6","next":"15"},"devDependencies":{"prisma":"6","vitest":"4"}}'
contract() { printf '# demo\n\n## Verification Contract\n\n```bash\n%s\n```\n' "$1"; }
# mk_repo <claude-md> <package.json|-> [prisma|prisma-dir] -> prints the PR head sha
mk_repo() {
  local o="$T/origin/bh.git" w="$T/work/bh"
  scratch_rm "$T/origin"; scratch_rm "$T/work"; scratch_rm "$T/repos/cromford"; mkdir -p "$T/origin" "$T/work"
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '%s\n' "$1" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  printf 'echo t.sh ran\n' > "$w/t.sh"
  [ "$2" = - ] || printf '%s\n' "$2" > "$w/package.json"
  case "${3:-}" in
    prisma)     mkdir -p "$w/prisma"; echo 'generator client {}' > "$w/prisma/schema.prisma" ;;
    prisma-dir) mkdir -p "$w/prisma/schema"; echo 'model A {}' > "$w/prisma/schema/a.prisma" ;;
  esac
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$w" push -q "$o" main
  echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/41/head"
  git clone -q "$o" "$T/repos/cromford"
  git -C "$w" rev-parse HEAD
}

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body, no ticket named."}' ;;
esac
exit 0
EOF
# the repo suite: `npm test` leaves a mark, prints $T/suite.out, exits $T/suite.rc;
# `npm ci` is a no-op install (it makes nothing).
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
echo "npm \$*" >> "$T/log/npm"
case "\$1" in ci|install|i) exit 0 ;; esac
touch "$T/suite-ran"; cat "$T/suite.out" 2>/dev/null; exit "\$(cat "$T/suite.rc")"
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt"
cp "$T/answer" "\$5"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/rules-pack.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/npm" "$H/bin/agent-call.sh" "$H/bin/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_HOST_SUITE=always
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

[ -r "$H/bin/lib/suite-preflight.sh" ] && ok || bad "bin/lib/suite-preflight.sh is not in bin/lead-review.sh's closure"
[ -r "$H/bin/lib/lead-review/libs.d/202611131555-bh-7695-suite-preflight.sh" ] && ok \
  || bad "bin/lib/lead-review/libs.d/202611131555-bh-7695-suite-preflight.sh is not in the closure"
# case1 <claude-md> <package.json|-> <prisma|prisma-dir|-> <suite rc> [<suite output>] [nolib]
case1() {
  rm -f "${T:?}"/log/* "${T:?}/jobstate" "${T:?}/suite-ran" "${T:?}/suite.out" "$H/logs/lead-review.log"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
  # nolib: the lib is moved aside for this tick only
  [ "${6:-lib}" = nolib ] && mv "$H/bin/lib/suite-preflight.sh" "$T/suite-preflight.off"
  SHA=$(mk_repo "$1" "$2" "$3"); echo "$SHA" > "$T/livehead"; echo "$4" > "$T/suite.rc"
  [ -n "${5:-}" ] && printf '%s\n' "$5" > "$T/suite.out"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,scope_notes:"",prior_verdict_ref:null,status:"requested"}],truncated:false}' > "$T/requests.json"
  printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES\n' > "$T/answer"
  ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
  [ -e "$T/suite-preflight.off" ] && mv "$T/suite-preflight.off" "$H/bin/lib/suite-preflight.sh"
  return 0
}
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { grep -qE "$1" <<<"$(wlog)"; }
line() { cat "$H"/state/lead-reviews/*.md 2>/dev/null | sed -n 's/^- \(host suite: .*\)$/\1/p' | head -n 1; }
done_ok() { has '/result .*"outcome":"done"'; }
diag() { printf 'line=[%s] rc=%s log: %s' "$(line)" "$RC" "$(tail -3 "$H/logs/lead-review.log" 2>/dev/null)"; }

# H1
case1 "$(contract 'npm test')" "$DEPS" - 0
[ "$RC" = 0 ] && ok || bad "H1 rc=$RC: $(tail -5 "$T/out")"
[ -e "$T/suite-ran" ] && bad "H1 the suite ran on a box with no node_modules" || ok
grep -qE 'npm (ci|install|i)( |$)' "$T/log/npm" 2>/dev/null && bad "H1 the lead path installed: $(cat "$T/log/npm")" || ok
[ "$(agents)" = 1 ] && ok || bad "H1 the model must still be called: $(agents); $(diag)"
done_ok && ok || bad "H1 the review must finish done: $(wlog | grep result); $(diag)"
has '"outcome":"failed"' && bad "H1 the request failed: $(wlog | grep result)" || ok
case "$(line)" in 'host suite: could-not-run: node_modules '*'npm test') ok ;; *) bad "H1 report line: $(diag)" ;; esac
grep -q '\[NOTE\] not verified here' "$T/log/prompt" 2>/dev/null && ok || bad "H1 the prompt must carry the NOTE text: $(grep -A4 '## Host suite' "$T/log/prompt" 2>/dev/null)"
grep -q 'host suite: could-not-run: node_modules.*the review goes on' "$H/logs/lead-review.log" 2>/dev/null && ok || bad "H1 the log does not name it: $(tail -3 "$H/logs/lead-review.log" 2>/dev/null)"
# H1, second tick on the same request: the report is replayed from disk (the
# BH-8945 reader, `^- (host suite: .*)$`), no model call, the same suite text.
h1line=$(line)
rm -f "$T/log/agent-count" "$T/suite-ran"
( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out2" 2>&1
grep -q 'reusing .*no agent call' "$H/logs/lead-review.log" 2>/dev/null && ok || bad "H1 the second tick did not replay the report: $(tail -4 "$H/logs/lead-review.log" 2>/dev/null)"
[ "$(agents)" = 0 ] && ok || bad "H1 the replay called the model: $(agents)"
[ "$(grep -cF "($h1line)" "$H/logs/lead-review.log" 2>/dev/null)" = 2 ] && ok || bad "H1 the replay must log the same host suite text twice: $(grep -F 'done ' "$H/logs/lead-review.log" 2>/dev/null)"
[ -s "$H/logs/ALERTS.log" ] && grep -q 'suite-preflight' "$H/logs/ALERTS.log" && bad "H1 the lead path alerted" || ok
# H2
case1 "$(contract 'npm test')" "$NODEPS" prisma 1 "Error: P1001: Can't reach database server at localhost:5432"
[ -e "$T/suite-ran" ] && ok || bad "H2 a soft miss must still run the suite"
[ "$(line)" = 'host suite: could-not-run: DATABASE_URL (suite rc 1): npm test' ] && ok || bad "H2 report line: $(diag)"
[ "$(agents)" = 1 ] && ok || bad "H2 the model must be called: $(agents)"
done_ok && ok || bad "H2 not done: $(wlog | grep result)"
# H3
case1 "$(contract 'npm test')" "$NODEPS" prisma 0
[ "$(line)" = 'host suite: npm test rc=0' ] && ok || bad "H3 report line: $(diag)"
case1 "$(contract 'npm test')" "$NODEPS" prisma 1 'AssertionError: expected 2 to be 3'
[ "$(line)" = 'host suite: npm test rc=1' ] && ok || bad "H3b a real red stays red: $(diag)"
# H4
case1 "$(contract 'bash t.sh')" "$DEPS" - 0
[ "$(line)" = 'host suite: bash t.sh rc=0' ] && ok || bad "H4 a non-node suite must run: $(diag)"
# H5
case1 "$(contract 'npm ci && npm test')" "$DEPS" - 0
[ -e "$T/suite-ran" ] && ok || bad "H5 a contract that installs must run"
[ "$(line)" = 'host suite: npm ci && npm test rc=0' ] && ok || bad "H5 report line: $(diag)"
# H6
case1 "$(contract 'npm test')" "$DEPS" - 0 "" nolib
[ -e "$T/suite-ran" ] && ok || bad "H6 with no lib the suite runs as before"
[ "$(line)" = 'host suite: npm test rc=0' ] && ok || bad "H6 report line: $(diag)"
done_ok && ok || bad "H6 with no lib the tick must finish: $(wlog | grep result)"
# H7: the #2084 shape
case1 "$(contract 'npm test')" "$MK" prisma-dir 127 'sh: 1: vitest: not found'
[ -e "$T/suite-ran" ] && bad "H7 the #2084 replay ran the suite" || ok
case "$(line)" in 'host suite: could-not-run: node_modules '*) ok ;; *) bad "H7 report line: $(diag)" ;; esac
done_ok && ok || bad "H7 the verdict must be recorded: $(wlog | grep result)"

# H8: the hotspot only calls the lib (D55); with no lib, today's two lines.
LR="$DIR/bin/lead-review.sh"
grep -qF 'sp_lead_suite "$WT" "$suite_cmd" "$((left / 2))" "$project" "$WT.suite"' "$LR" && ok || bad "H8 bin/lead-review.sh does not call sp_lead_suite"
grep -qF '( cd "$WT" && timeout "$((left / 2))" bash -c "$suite_cmd" ) 7>&- 8>&- > "$WT.suite" 2>&1; suite_rc=$?' "$LR" && ok || bad "H8 the fallback run line changed"
grep -qF 'suite_line="host suite: $suite_cmd rc=$suite_rc"' "$LR" && ok || bad "H8 the fallback suite line changed"

echo "lead-review-preflight.bh-7695: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
