#!/bin/bash
# tests/postmerge-qa-group.bh-6902-test.sh — BH-6902 through the production
# lane: "$DIR/bin/postmerge-qa.sh" hands a FAILED drive's observed.json to
# bin/lib/group-findings.sh, which files one issue per screen or flow.
#
#   P2  knob unset, FAIL verdict -> no REST write, ledger rows `off`
#   P3  knob on, FAIL with 2 failing screens -> 2 issues on the repo the PR URL
#       names; the existing ALERTS line is still written
#   P4  PASS verdict -> the helper is not called (no ledger file)
#
# The lane runs for real in a scratch harness (its whole source closure); gh,
# curl and node are fakes that record what they were asked.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa-group.bh-6902-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "postmerge-qa-group.bh-6902: jq is required"; exit 1; }
FIX="$DIR/tests/fixtures/bh-6902"
REG=$(rendered_registry)
BASE="$T"

new_harness() { # sets H: a scratch harness running the real lane
  local F
  H=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$H/fakebin" "$H/env" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/builds" "$H/clerk" "$H/repo"
  for F in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh qa-account.sh fleet-conf.sh prod-url.sh findings-log.sh; do
    scratch_install_closure "bin/$F" "$H" >/dev/null || { echo "FAIL: closure of $F"; exit 1; }
  done
  cp "$DIR/bin/alert_family.py" "$H/bin/"
  chmod +x "$H"/bin/*.sh
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$H/fleet.conf"
  : > "$H/env/global.env"
  mrs_fixture "$H" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fixture\nQA_TEST_USER_ID=user_QA\n' > "$H/env/project-3.env"
  echo active > "$H/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$H" > "$H/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/agent-calls.txt"\nexit 0\n' "$H" > "$H/bin/agent-call.sh"
  chmod +x "$H/bin/beat.sh" "$H/bin/agent-call.sh"
  # gh: the REST stub of tests/lib/gh-rest-fx.sh, plus the lane's non-REST argv.
  ( T="$H"; ghfx_init )
  cat > "$H/extra.sh" <<'SH'
case "$A" in
  *"pr view"*state,mergeCommit*) printf '%s\t%s\n' MERGED deadbeefcafe1234; exit 0 ;;
  "api repos/"*"/deployments/"*"/statuses"*) echo success; exit 0 ;;
  "api repos/"*"/deployments?"*) echo 99; exit 0 ;;
  *"pr comment"*) exit 0 ;;
esac
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  n=$(( $(cat "$GHFX/post.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHFX/post.n"
  mkdir -p "$GHFX/posts"; printf '%s\n' "$5" > "$GHFX/posts/$n.path"
  for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$GHFX/posts/$n.body" ;; esac; done
  printf 'HTTP/1.1 201 Created\r\n\r\n{"number":%s,"html_url":"https://github.com/fixture/issues/%s"}' $((300+n)) $((300+n))
  exit 0
fi
SH
  printf 'GET|repos/example-org/project-3/issues|200|issues\n' > "$H/routes"
  printf '[]' > "$H/rest-bodies/issues"
  cat > "$H/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  *"/v1/users/"*)
    UID_="${URL##*/v1/users/}"; UID_="${UID_%%/*}"
    SF="$CLERK_STATE_DIR/$UID_"; [ -f "$SF" ] || echo active > "$SF"
    case "$URL" in
      */ban)   echo banned > "$SF"; printf '200'; exit 0 ;;
      */unban) echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
    printf '{"id":"%s","banned":%s}' "$UID_" "$B" ;;
esac
exit 0
EOF
  # node stands in for qa-drive.mjs: it writes the observed.json the real drive
  # writes (a fixture of that shape) and the verdict lines it prints.
  cat > "$H/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT=""
for A in "$@"; do case "$A" in */qa-prod-shots) OUT="$A" ;; esac; done
[ -n "$OUT" ] && mkdir -p "$OUT" && cp "$OBSERVED" "$OUT/observed.json"
if [ "${NODE_RC:-0}" = 0 ]; then
  echo "QA COVERAGE: screens=2 flows=0 shots=2"; echo "QA: PASS"
else
  echo "FAIL: /clients@1280: HTTP 502"; echo "QA COVERAGE: screens=6 flows=1 shots=4"; echo "QA: FAIL"
fi
exit "${NODE_RC:-0}"
EOF
  chmod +x "$H/fakebin/"*
  B="$H/builds/project-3-TK-3-202608290000"; mkdir -p "$B"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$B/RESULT"
  printf '# plan\n\n## QA screens\n\n/clients\n/reports\n' > "$B/plan.md"
}
knob() { # knob [0|1] — the operator row for project-3; no argument = no row at all
  jq -nc --arg v "${1:-}" '{fetched_at:2000000000, seeded:{},
      values:(if $v == "" then {} else {"lib.group-findings.project-3.group_findings":$v} end)}' \
    > "$H/state/settings-cache.json"
}
run() { # run [ENV=VAL ...]
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$H/fakebin:/usr/bin:/bin" HOME="$H" \
      HARNESS="$H" FLEET_CONF="$H/fleet.conf" QA_ACCOUNTS="$H/state/qa-accounts.json" \
      CLERK_STATE_DIR="$H/clerk" GHFX="$H" NODE_SINK="$H/node.txt" QA_REPO_DIR="$H/repo" \
      LANE_REGISTRY="$REG" LANE_GATE_NOW=2000000000 GH_ETAG=0 TMPDIR="$H" \
      "$@" "$H/bin/postmerge-qa.sh" project-3 > "$H/out.txt" 2>&1
}
nposts() { # nposts <path-glob>
  local f n=0
  for f in "$H"/posts/*.path; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) n=$((n+1)) ;; esac
  done
  echo "$n"
}
ledger_rows() { jq -s --arg a "$1" '[.[] | select(.action == $a)] | length' "$B/findings-ledger.jsonl" 2>/dev/null || echo -1; }

# --- P2: knob unset (no row: the registry default, 0) ---------------------------------
new_harness; knob
run NODE_RC=1 OBSERVED="$FIX/observed-second.json"
grep -q 'QA: FAIL' "$B/qa-prod.md" && ok || bad "P2: the drive must be a FAIL: $(cat "$H/out.txt")"
grep -q -- '-X POST' "$H/gh-argv.log" 2>/dev/null && bad "P2: knob off must make no REST write: $(grep -- '-X' "$H/gh-argv.log")" || ok
grep -q 'api -i -X GET repos/example-org/project-3/issues' "$H/gh-argv.log" 2>/dev/null \
  && bad "P2: knob off must not even read the issue list" || ok
[ -s "$B/qa-findings.jsonl" ] && ok || bad "P2: the lane must write the run's findings to qa-findings.jsonl"
[ "$(grep -c '' "$B/qa-findings.jsonl" 2>/dev/null)" = 6 ] && ok || bad "P2: 6 findings from the observed.json, got $(grep -c '' "$B/qa-findings.jsonl" 2>/dev/null)"
[ "$(ledger_rows off)" = 6 ] && ok || bad "P2: the ledger must carry 6 rows off, got $(ledger_rows off)"
grep -q 'POST-MERGE PROD QA FAILED' "$H/logs/ALERTS.log" && ok || bad "P2: the FAIL alert must stay"

# --- P3: knob on, 2 failing screens --------------------------------------------------------
new_harness; knob 1
jq '.screens |= map(select(.path != "/settings")) | .flows = []' "$FIX/observed-second.json" > "$H/obs.json"
run NODE_RC=1 OBSERVED="$H/obs.json"
[ "$(nposts 'repos/example-org/project-3/issues')" = 2 ] && ok || bad "P3: want 2 issues on example-org/project-3, got $(nposts 'repos/example-org/project-3/issues'): $(cat "$H/gh-argv.log")"
grep -h '<!-- findings-group:' "$H"/posts/*.body 2>/dev/null | sort > "$H/markers.txt"
printf '%s\n' '<!-- findings-group: project-3|/clients -->' '<!-- findings-group: project-3|/reports -->' | sort | diff -q - "$H/markers.txt" >/dev/null \
  && ok || bad "P3: the two issues must be /clients and /reports: $(cat "$H/markers.txt")"
grep -q 'POST-MERGE PROD QA FAILED' "$H/logs/ALERTS.log" && ok || bad "P3: the FAIL alert must stay"
grep -q 'group-findings: 4 findings, 2 groups, filed 2' "$H/logs/postmerge-qa.log" \
  && ok || bad "P3: the lane log must carry the totals line: $(grep group-findings "$H/logs/postmerge-qa.log")"
grep -q ' FAIL$' "$H/state/postmerge-qa-done.txt" && ok || bad "P3: the build must still be marked done FAIL"

# P2b: an explicit 0 row is off too
new_harness; knob 0
run NODE_RC=1 OBSERVED="$FIX/observed-second.json"
[ "$(ledger_rows off)" = 6 ] && ok || bad "P2b: a 0 row must leave 6 rows off, got $(ledger_rows off)"

# --- P4: PASS -> no helper -------------------------------------------------------------------
new_harness; knob 1
run NODE_RC=0 OBSERVED="$FIX/observed-second.json"
grep -q 'QA: PASS' "$B/qa-prod.md" && ok || bad "P4: the drive must PASS: $(cat "$H/out.txt")"
[ ! -e "$B/findings-ledger.jsonl" ] && ok || bad "P4: a PASS must not call the helper"
grep -q -- '-X POST' "$H/gh-argv.log" 2>/dev/null && bad "P4: a PASS must make no REST write" || ok

echo "postmerge-qa-group.bh-6902: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
