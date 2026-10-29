#!/bin/bash
# tests/onboard-repo-detect.bh-7935-test.sh — BH-7997 (BH-7935 wave 2, order 1):
# the onboarding repo-detect tracer on the hub side.
#   G1-G7  bin/lib/onboard-github.sh og_get / og_install_url: the fake reads
#          fixtures and counts calls, bad paths read nothing, an unarmed box
#          runs no process, the armed path mints, reads once and releases
#   V1-V6  bin/lib/hub-probes/common.sh: the three screen probes' validators,
#          the placeholder dispatch (not-implemented), and the board allowlist
#          (request.sh) that stays closed to them
#   R1-R6  bin/lib/hub-probes/repo-detect.sh through the REAL hp_run, and one
#          REAL bin/hub-probe.sh tick that claims a repo-detect row
#   N1     the worker route and console files this slice ships, run under node
# Every case copies its fixture dir into its own scratch dir, so the fake's
# .calls file is never shared. A recording curl and gh are first on PATH for
# the whole suite; tests/onboard-github-vendor-budget.bh-7935-test.sh asserts
# they were never run.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-repo-detect.bh-7935-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "onboard-repo-detect: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SEAM="$DIR/bin/lib/onboard-github.sh"
HPD="$DIR/bin/lib/hub-probes"
FX="$DIR/tests/fixtures/onboard-github"
# The golden probe line lives in the worker tree, so the worker test reads it
# without leaving worker/jobs/ (ci-plan X2). This suite reads the same file.
GOLDEN="$DIR/worker/jobs/test/fixtures/onboard-repo/visible-probe.json"
for f in "$DIR/bin/lib/onboard-github.sh" "$DIR/bin/lib/hub-probes/common.sh" "$DIR/bin/lib/hub-probes/repo-detect.sh" \
         "$DIR/bin/lib/hub-probes/repo-detect-extra.sh" "$DIR/bin/lib/hub-probes/ready-facts.sh" \
         "$DIR/bin/lib/hub-probes/repo-create.sh" "$DIR/bin/lib/hub-probes/request.sh"; do
  if [ -f "$f" ] && bash -n "$f" 2>/dev/null; then ok; else bad "missing or unparseable $f"; fi
done

# The recording vendor binaries. VENDOR_LOG may be set by the budget suite.
VLOG="${VENDOR_LOG:-$T/vendor.log}"
: >> "$VLOG"
mkdir -p "$T/fakebin" "$T/env" "$T/h"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$b" "$VLOG" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
export PATH="$T/fakebin:$PATH"
unset GH_APP_SLUG GH_APP_NAME GH_TOKEN 2>/dev/null || true

# fx <name>: a fresh copy of one fixture dir at $T/fx; prints the path.
fx() { rm -rf "$T/fx"; mkdir -p "$T/fx"; cp -R "$FX/$1"/. "$T/fx/"; printf '%s' "$T/fx"; }
calls() { local n; n=$(grep -c . "$T/fx/.calls" 2>/dev/null); printf '%s' "${n:-0}"; }

# run_sh <fake dir or ""> <bash code>: a clean bash with the seam's environment.
# stdout -> $T/out, stderr -> $T/err, rc -> $T/rc.
run_sh() {
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" HARNESS_SECRET="" \
    ONBOARD_GITHUB_FAKE="$1" SEAM="$SEAM" HPD="$HPD" bash -c "$2" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
out() { cat "$T/out"; }

# ── G1-G3: the fake ─────────────────────────────────────────────────────────
F=$(fx visible)
run_sh "$F" '. "$SEAM"; og_get repos/example-org/project-11; r=$?; echo "status=$OG_HTTP_STATUS" >&2; exit $r'
check "G1 rc 0" '[ "$(rc)" = 0 ]'
check "G1 body is the fixture" '[ "$(out)" = "$(cat "$FX/visible/repos__example-org__project-11.json")" ]'
check "G1 one call recorded" '[ "$(calls)" = 1 ] && [ "$(cat "$F/.calls")" = repos/example-org/project-11 ]'
check "G1 OG_HTTP_STATUS=200" 'grep -qx "status=200" "$T/err"'

F=$(fx invisible)
run_sh "$F" '. "$SEAM"; og_get repos/example-org/ghost'
check "G2 a .status.txt 404 is rc 44" '[ "$(rc)" = 44 ]'
check "G2 no stdout" '[ ! -s "$T/out" ]'

F=$(fx visible)
run_sh "$F" '. "$SEAM"; og_get repos/example-org/unknown'
check "G3 an unknown path is rc 3" '[ "$(rc)" = 3 ]'
check "G3 the call is still counted" '[ "$(calls)" = 1 ]'

# ── G4: not armed, no fake: rc 4, no process ────────────────────────────────
: > "$VLOG.g4"
run_sh "" 'export VL='"'$VLOG.g4'"'; gh_auth_armed() { return 1; }; gh_app_only_for() { echo mint >> "$VL"; return 0; }
  gh_app_only_release() { :; }; gh_rest() { echo rest >> "$VL"; }
  . "$SEAM"; og_get repos/example-org/project-11'
check "G4 stubbed unarmed is rc 4" '[ "$(rc)" = 4 ] && [ ! -s "$T/out" ]'
check "G4 no mint and no REST call" '[ ! -s "$VLOG.g4" ]'
# The real gh_auth_armed: HARNESS has no env/github-app.env, so it is unarmed.
run_sh "" '. "$SEAM"; og_get repos/example-org/project-11'
check "G4 real unarmed box is rc 4" '[ "$(rc)" = 4 ] && [ ! -s "$T/out" ]'

# ── G5: og_install_url ──────────────────────────────────────────────────────
run_sh "" '. "$SEAM"; og_install_url'
check "G5 default slug" '[ "$(out)" = "https://github.com/apps/cromford/installations/new" ]'
printf 'GH_APP_ID=1\nexport GH_APP_SLUG="My App"\n' > "$T/env/github-app.env"
run_sh "" '. "$SEAM"; og_install_url'
check "G5 GH_APP_SLUG is slugged" '[ "$(out)" = "https://github.com/apps/my-app/installations/new" ]'
printf 'GH_APP_NAME=example-org Bot\n' > "$T/env/github-app.env"
run_sh "" '. "$SEAM"; og_install_url'
check "G5 GH_APP_NAME is the fallback" '[ "$(out)" = "https://github.com/apps/example-org-bot/installations/new" ]'
rm -f "$T/env/github-app.env"

# ── G6: bad paths read nothing ──────────────────────────────────────────────
for p in 'repos/a/../b' 'user' 'repos/a' 'repos/a b/c' 'repos/example-org/.' 'repos/example-org/..' \
         'repos/o_x/r' '/repos/a/b' 'repos/a/b/./c' "repos/$(printf 'o%.0s' {1..40})/r" ''; do
  F=$(fx visible)
  # The path rides an env var, so no shell quoting touches it.
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$F" SEAM="$SEAM" P="$p" \
    bash -c '. "$SEAM"; og_get "$P"' > "$T/out" 2>/dev/null; echo $? > "$T/rc"
  check "G6 '$p' is rc 2" '[ "$(rc)" = 2 ] && [ ! -s "$T/out" ]'
  check "G6 '$p' reads nothing" '[ ! -e "$F/.calls" ]'
done
run_sh "$(fx visible)" '. "$SEAM"; og_get repos/a/b extra'
check "G6 two arguments is rc 2" '[ "$(rc)" = 2 ]'

# ── G7: the armed path (stubbed mint and REST) ──────────────────────────────
ARMED='gh_auth_armed() { return 0; }
gh_app_only_for() { echo "mint $1" >> "$L"; [ "${MINT:-0}" = 0 ] || return 1; export GH_TOKEN=ghs_FAKE; }
gh_app_only_release() { echo release >> "$L"; export GH_TOKEN=prior; }
gh_rest() { echo "rest $1 $2 token=$GH_TOKEN" >> "$L"; GH_REST_STATUS=${ST:-200}; [ "${RRC:-0}" = 0 ] && echo "{\"ok\":1}"; return "${RRC:-0}"; }
. "$SEAM"; GH_TOKEN=prior; og_get repos/example-org/project-11; r=$?
echo "status=$OG_HTTP_STATUS token=$GH_TOKEN" >> "$L"; exit $r'
export L="$T/armed.log"
: > "$L"; run_sh "" "$ARMED"
check "G7 armed read is rc 0 with the body" '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"ok\":1}" ]'
check "G7 mints for owner/repo, reads with the App token, releases" \
  '[ "$(sed -n 1p "$L")" = "mint example-org/project-11" ] && [ "$(sed -n 2p "$L")" = "rest GET repos/example-org/project-11 token=ghs_FAKE" ] && [ "$(sed -n 3p "$L")" = release ]'
check "G7 token restored, status set" 'grep -qx "status=200 token=prior" "$L"'
: > "$L"; MINT=1 run_sh "" "$ARMED"
check "G7 a refused mint is rc 44 and no REST call" '[ "$(rc)" = 44 ] && ! grep -q "^rest" "$L"'
: > "$L"; RRC=75 ST=503 run_sh "" "$ARMED"
check "G7 rc 75 passes through, token restored" '[ "$(rc)" = 75 ] && grep -q release "$L" && grep -qx "status=503 token=prior" "$L"'
: > "$L"; RRC=44 ST=404 run_sh "" "$ARMED"
check "G7 a 404 is rc 44" '[ "$(rc)" = 44 ]'
: > "$L"; RRC=1 ST=000 run_sh "" "$ARMED"
check "G7 any other rc reads as 75" '[ "$(rc)" = 75 ]'
check "G4/G7 the recording vendor binaries never ran" '[ ! -s "$VLOG" ]'

# ── V1-V4: the validator table (Decision rule 2) ────────────────────────────
v() { bash -c '. "$1/common.sh" && shift && hp_validate "$@"' _ "$HPD" "$@" >/dev/null 2>&1; echo $?; }
for good in "repo-detect example-org/project-11" "repo-detect a/b" "repo-detect my.org-x/re_po.js" \
            "ready-facts project-11" "ready-facts a" "ready-facts $(printf 'a%.0s' {1..19})" \
            "repo-create example-org project-11 nextjs" "repo-create o r empty" "repo-create o r worker"; do
  # shellcheck disable=SC2086
  check "V1 good: $good" '[ "$(v $good)" = 0 ]'
done
for badv in "repo-detect" "repo-detect a/b c" "repo-detect ../x" "repo-detect a/.." "repo-detect a/." \
            "repo-detect ./a" "repo-detect a" "repo-detect a/b/c"; do
  # shellcheck disable=SC2086
  check "V2 bad: $badv" '[ "$(v $badv)" = 2 ]'
done
check "V2 bad: repo-detect 'a b/c'" '[ "$(v repo-detect "a b/c")" = 2 ]'
for badv in "ready-facts Realtor" "ready-facts -x" "ready-facts $(printf 'a%.0s' {1..20})" "ready-facts" \
            "ready-facts a b" "ready-facts a_b"; do
  # shellcheck disable=SC2086
  check "V3 bad: $badv" '[ "$(v $badv)" = 2 ]'
done
for badv in "repo-create o r rails" "repo-create o .. nextjs" "repo-create o . nextjs" "repo-create o_x r nextjs" \
            "repo-create o r" "repo-create o r nextjs x" "repo-create $(printf 'o%.0s' {1..40}) r nextjs" \
            "repo-create o $(printf 'r%.0s' {1..101}) nextjs" "repo-create o r/x nextjs"; do
  # shellcheck disable=SC2086
  check "V4 bad: ${badv:0:60}" '[ "$(v $badv)" = 2 ]'
done
check "V4 bad: repo-create o 'r x' nextjs" '[ "$(v repo-create o "r x" nextjs)" = 2 ]'
SCR=$(bash -c '. "$1/common.sh" && printf "%s|%s|%s" "$HP_SCREEN_PROBES" "$HP_TEMPLATE_KEYS" "$HP_PROBES"' _ "$HPD")
check "V4 HP_SCREEN_PROBES, HP_TEMPLATE_KEYS, HP_PROBES" \
  '[ "$SCR" = "tracker-test repo-detect ready-facts repo-create|nextjs worker empty|app-status-write app-permissions app-installation-repos d1-count" ]'

# ── V5: the placeholders answer not-implemented ─────────────────────────────
hr() { env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="${FAKE:-}" HPD="$HPD" \
  bash -c '. "$HPD/common.sh" && hp_run "$@"' _ "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"; }
hr ready-facts project-11
check "V5 ready-facts prints not-implemented, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = not-implemented ]'
hr repo-create example-org x nextjs
check "V5 repo-create prints not-implemented, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = not-implemented ]'
hr repo-create example-org x rails
check "V5 a bad template is rc 2 before dispatch" '[ "$(rc)" = 2 ] && [ ! -s "$T/out" ]'

# ── V6: a build's HUB_PROBE: line still cannot file a screen probe ──────────
printf '%s\n' 'HUB_PROBE: repo-detect example-org/project-11' 'HUB_PROBE: repo-create example-org x nextjs' \
  'HUB_PROBE: ready-facts project-11' "HUB_PROBE: tracker-test linear $(printf '%032d' 0)" \
  'HUB_PROBE: app-installation-repos' > "$T/req.txt"
REQ=$(bash -c '. "$1/request.sh" && hp_parse_request_lines "$2"' _ "$HPD" "$T/req.txt" 2> "$T/req.err")
check "V6 only the board probe is parsed" '[ "$REQ" = "$(printf "app-installation-repos\t")" ]'
check "V6 the four screen probes are logged as dropped" '[ "$(grep -c "dropped invalid request line" "$T/req.err")" = 4 ]'

# ── R1-R5: hp_probe_repo_detect through the real hp_run ─────────────────────
FAKE=$(fx visible) hr repo-detect example-org/project-11
check "R1 rc 0" '[ "$(rc)" = 0 ]'
check "R1 one line equal to visible-probe.json" '[ "$(grep -c . "$T/out")" = 1 ] && [ "$(out)" = "$(jq -c . "$GOLDEN")" ]'
check "R1 the five tracer facts" 'jq -e ".visible == true and .default_branch == \"main\" and .has_issues == true and .open_issues == 3 and (.install_url | endswith(\"/apps/cromford/installations/new\"))" "$T/out" >/dev/null'
check "R1 the four extra facts" 'jq -e ".ci_workflow == true and .package_manager == \"npm\" and .test_runner == \"vitest\" and (.readiness_level | type == \"number\")" "$T/out" >/dev/null'
# The base read, then the extra's three reads and its clone (BH-7998).
SEAM_CALLS=$(printf "%s\n" repos/example-org/project-11 repos/example-org/project-11/actions/workflows \
  repos/example-org/project-11/contents repos/example-org/project-11/contents/package.json "clone repos/example-org/project-11")
check "R1 five seam calls, in order" '[ "$(cat "$T/fx/.calls")" = "$SEAM_CALLS" ]'

FAKE=$(fx invisible) hr repo-detect example-org/ghost
check "R2 a 404 is a pass with visible:false and the install url" \
  '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"visible\":false,\"install_url\":\"https://github.com/apps/cromford/installations/new\"}" ]'

FAKE=$(fx visible) HPD="$HPD" env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$T/fx" \
  bash -c 'hp_repo_detect_extra() { echo "{\"readiness\":\"x\"}"; }; . "$HPD/common.sh" && hp_run repo-detect example-org/project-11' \
  > "$T/out" 2>/dev/null; echo $? > "$T/rc"
check "R3 an extra object is merged" '[ "$(rc)" = 0 ] && jq -e ".readiness == \"x\" and .visible == true and .open_issues == 3" "$T/out" >/dev/null'
fx visible >/dev/null
env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$T/fx" HPD="$HPD" \
  bash -c 'hp_repo_detect_extra() { echo nope; echo "oops" >&2; }; . "$HPD/common.sh" && hp_run repo-detect example-org/project-11' \
  > "$T/out" 2>&1; echo $? > "$T/rc"
check "R3 an extra that is not an object is ignored (stderr too)" '[ "$(rc)" = 0 ] && [ "$(out)" = "$(jq -c "{visible, default_branch, has_issues, open_issues, install_url}" "$GOLDEN")" ]'
fx visible >/dev/null
env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$T/fx" HPD="$HPD" \
  bash -c 'hp_repo_detect_extra() { echo "[1,2]"; }; . "$HPD/common.sh" && hp_run repo-detect example-org/project-11' \
  > "$T/out" 2>&1; echo $? > "$T/rc"
check "R3 an extra array is ignored" '[ "$(out)" = "$(jq -c "{visible, default_branch, has_issues, open_issues, install_url}" "$GOLDEN")" ]'
fx visible >/dev/null
check "R3 the shipped extra prints exactly the four keys" \
  '[ "$(env TMPDIR="$T" ONBOARD_GITHUB_FAKE="$T/fx" HARNESS="$T/h" JOBS_URL="" bash -c ". \"\$1/repo-detect-extra.sh\" && hp_repo_detect_extra example-org/project-11" _ "$HPD" | jq -c keys)" = "[\"ci_workflow\",\"package_manager\",\"readiness_level\",\"test_runner\"]" ]'

FAKE=$(fx issues-off) hr repo-detect example-org/no-issues
check "R4 has_issues:false" '[ "$(rc)" = 0 ] && jq -e ".has_issues == false and .default_branch == \"trunk\" and .open_issues == 0" "$T/out" >/dev/null'
FAKE=$(fx issues-off) hr repo-detect example-org/half
check "R4 a body without the three fields is unparseable, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = unparseable ]'

FAKE=$(fx visible) hr repo-detect example-org/unknown
check "R5 fake rc 3 is unverifiable, rc 1, one word" '[ "$(rc)" = 1 ] && [ "$(out)" = unverifiable ]'
FAKE="" hr repo-detect example-org/project-11
check "R5 an unarmed box is not-configured, rc 1, one word" '[ "$(rc)" = 1 ] && [ "$(out)" = not-configured ]'
check "R1-R5 no stderr leaks into a probe's output" '[ ! -s "$T/err" ]'

# ── R6: one REAL bin/hub-probe.sh tick claims a repo-detect row ─────────────
H="$T/lane"
mkdir -p "$H"
cp -rs "$DIR/bin" "$H/bin"
rm -f "$H/bin/alert-line.sh"
printf '#!/bin/bash\necho "alert-line $*" >> "%s/alerts"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
printf 'bp   o/r   -   -   5  local\n' > "$H/fleet.conf"
mkdir -p "$T/jobs"
jq -nc '{rows:[{id:41, project:"onboarding", ticket_key:"onb-repo-29000000", probe:"repo-detect", args:["example-org/project-11"]}]}' > "$T/jobs/claim"
echo '{"count":0}' > "$T/jobs/count"
cat > "$T/lane-fx.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_switch() { return 1; }
_jobs_req() {
  local name
  case "$2" in
    /api/hub-probe/claim) name=claim ;;
    /api/hub-probe/result) name=result ;;
    /api/hub-probe/count-today*) name=count ;;
    *) name=other ;;
  esac
  [ -n "${3:-}" ] && printf '%s\n' "$3" >> "$FXT/body-$name"
  cat "$FXT/jobs/$name" 2>/dev/null || echo '{"ok":true}'
}
gh_rest() { echo "gh_rest $*" >> "$VLOG"; return 75; }
gh_rest_issue_comments() { echo "gh_rest_issue_comments $*" >> "$VLOG"; return 75; }
hp_on_pass() { echo "$*" >> "$FXT/onpass"; }
SH
F=$(fx visible)
HARNESS="$H" HARNESS_ENV_DIR="$T/env" FLEET_CONF="$H/fleet.conf" FXT="$T" VLOG="$VLOG" HUB_PROBE_FIXTURE="$T/lane-fx.sh" \
  ONBOARD_GITHUB_FAKE="$F" HARNESS_TEST_SANDBOX=1 bash "$H/bin/hub-probe.sh" > "$T/lane.out" 2>&1
echo $? > "$T/rc"
check "R6 the tick exits 0" '[ "$(rc)" = 0 ]'
check "R6 the row is stored pass with the R1 line" \
  '[ "$(jq -r .result "$T/body-result" 2>/dev/null)" = pass ] && [ "$(jq -r .output "$T/body-result" | tr -d "\n")" = "$(jq -c . "$GOLDEN")" ]'
check "R6 http_status 200" '[ "$(jq -r .http_status "$T/body-result")" = 200 ]'
check "R6 five seam calls through the fake" '[ "$(cat "$T/fx/.calls")" = "$SEAM_CALLS" ]'
check "R6 no spool file left" '[ -z "$(ls -A "$H/state/hub-probe/owed" 2>/dev/null)" ]'
check "R6 no comment posted, no vendor call" '[ ! -s "$VLOG" ]'
check "R6 summary counts one pass" '[[ "$(tail -1 "$H/logs/hub-probe.log")" == *"claimed=1 ran=1 pass=1 fail=0"* ]]'

# ── N1: the worker and console halves, by path, under node ──────────────────
ROUTE="$DIR/worker/jobs/src/routes/onboarding-repo.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-7935-onboarding-repo.txt"
WTEST="$DIR/worker/jobs/test/onboarding-repo.bh-7935.test.js"
CTEST="$DIR/console-ui/tests/onboard-api.bh-7935.test.js"
SCREENS=("$DIR/console-ui/src/screens/Onboard.js" "$DIR/console-ui/src/screens/onboard/NewRepoPanel.js" \
         "$DIR/console-ui/src/screens/ProjectReady.js" "$DIR/console-ui/src/api.js" "$DIR/console-ui/src/app.js")
for f in "$ROUTE" "$FRAG" "$WTEST" "$CTEST" "${SCREENS[@]}"; do
  check "N1 $f exists" '[ -f "$f" ]'
done
check "N1 the fragment lists both GET routes" \
  'grep -qx "GET /api/onboarding/repo" "$FRAG" && grep -qx "GET /api/onboarding/repos" "$FRAG"'
if command -v node >/dev/null 2>&1; then
  check "N1 the route module parses" 'node --check "$ROUTE"'
  if [ -d "$DIR/worker/jobs/node_modules" ] || [ -z "$(jq -r '.dependencies // {} | keys[]' "$DIR/worker/jobs/package.json" 2>/dev/null)" ]; then
    (cd "$DIR/worker/jobs" && node --test test/onboarding-repo.bh-7935.test.js) > "$T/node-w.out" 2>&1; NRC=$?
    check "N1 worker node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-w.out"; false; }'
  fi
  if [ -d "$DIR/console-ui/node_modules" ]; then
    (cd "$DIR/console-ui" && node --test tests/onboard-api.bh-7935.test.js) > "$T/node-c.out" 2>&1; NRC=$?
    check "N1 console node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-c.out"; false; }'
  fi
fi

echo "onboard-repo-detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
