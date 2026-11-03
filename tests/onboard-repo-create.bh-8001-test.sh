#!/bin/bash
# tests/onboard-repo-create.bh-8001-test.sh — BH-8001 (BH-7935.4): New repo
# from a template, the hub side.
#   P1-P5  bin/lib/onboard-github.sh og_post: the fake reads fixtures and
#          records calls, bad input sends nothing, an unarmed box runs no
#          process, the armed path mints for the template, posts once, releases
#   C1-C6  bin/lib/hub-probes/repo-create.sh through the REAL hp_run
#   K1     one REAL bin/hub-probe.sh tick claims a repo-create row; a second
#          tick that claims nothing makes no second POST
#   B1     the recording curl and gh never ran (vendor_calls=0)
#   N1     the worker route and console files of this ticket, run under node
# Every case copies its fixture dir into its own scratch dir, so the fake's
# .calls file is never shared.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-repo-create.bh-8001-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "onboard-repo-create: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SEAM="$DIR/bin/lib/onboard-github.sh"
HPD="$DIR/bin/lib/hub-probes"
FX="$DIR/tests/fixtures/onboard-github-create"
PF=post__repos__T__tmpl__generate
for f in "$DIR/bin/lib/onboard-github.sh" "$DIR/bin/lib/hub-probes/repo-create.sh"; do
  if [ -f "$f" ] && bash -n "$f" 2>/dev/null; then ok; else bad "missing or unparseable $f"; fi
done

VLOG="$T/vendor.log"
: > "$VLOG"
mkdir -p "$T/fakebin" "$T/env" "$T/h" "$T/tmp"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$b" "$VLOG" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
export PATH="$T/fakebin:$PATH"
unset GH_APP_SLUG GH_APP_NAME GH_TOKEN 2>/dev/null || true

# fx <name>: a fresh copy of one fixture dir at $T/fx; prints the path.
fx() { rm -rf "$T/fx"; mkdir -p "$T/fx"; [ -z "${1:-}" ] || cp -R "$FX/$1"/. "$T/fx/"; printf '%s' "$T/fx"; }
calls() { local n; n=$(grep -c . "$T/fx/.calls" 2>/dev/null); printf '%s' "${n:-0}"; }
posts() { local n; n=$(grep -c '^POST ' "$T/fx/.calls" 2>/dev/null); printf '%s' "${n:-0}"; }

# run_sh <fake dir or ""> <bash code>: a clean bash with the seam's environment.
# TMPDIR is a scratch dir that each case checks is left empty (C6).
run_sh() {
  rm -rf "$T/tmp"; mkdir -p "$T/tmp"
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" HARNESS_SECRET="" TMPDIR="$T/tmp" \
    ONBOARD_GITHUB_FAKE="$1" SEAM="$SEAM" HPD="$HPD" bash -c "$2" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
out() { cat "$T/out"; }
printf '{"owner":"o","name":"n"}\n' > "$T/body.json"

# ── P1: the fake, 201 ───────────────────────────────────────────────────────
F=$(fx created)
run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"'; r=$?; echo "status=$OG_HTTP_STATUS" >&2; exit $r'
check "P1 rc 0" '[ "$(rc)" = 0 ]'
check "P1 body is the fixture" '[ "$(out)" = "$(cat "$FX/created/$PF.json")" ]'
check "P1 .calls holds one POST line" '[ "$(cat "$F/.calls")" = "POST repos/T/tmpl/generate" ]'
check "P1 the body sent is recorded" '[ "$(cat "$F/.post-body")" = "$(cat "$T/body.json")" ]'
check "P1 OG_HTTP_STATUS=201" 'grep -qx "status=201" "$T/err"'

# ── P2: 422 / 404 / 403 / 500 ───────────────────────────────────────────────
for pair in 422:22 404:44 403:44 500:75 502:75; do
  st=${pair%%:*}; want=${pair#*:}
  F=$(fx)
  echo "$st" > "$F/$PF.status.txt"
  run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"'; r=$?; echo "status=$OG_HTTP_STATUS" >&2; exit $r'
  check "P2 $st is rc $want" '[ "$(rc)" = "$want" ]'
  check "P2 $st sets OG_HTTP_STATUS" 'grep -qx "status=$st" "$T/err"'
  check "P2 $st one POST" '[ "$(posts)" = 1 ]'
done

# ── P3: bad input sends nothing ─────────────────────────────────────────────
for p in 'repos/T/tmpl' 'repos/T/tmpl/forks' 'repos/T/../generate' 'repos/T/./generate' 'repos/T/tmpl/x/generate' \
         'repos/T/../tmpl/generate' 'repos/T_x/tmpl/generate' "repos/$(printf 'o%.0s' {1..40})/tmpl/generate" \
         '/repos/T/tmpl/generate' 'repos/T/tmpl/generate/' 'user/repos' ''; do
  F=$(fx created)
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" ONBOARD_GITHUB_FAKE="$F" SEAM="$SEAM" P="$p" BODY="$T/body.json" \
    bash -c '. "$SEAM"; og_post "$P" "$BODY"' > "$T/out" 2>/dev/null; echo $? > "$T/rc"
  check "P3 '$p' is rc 2" '[ "$(rc)" = 2 ] && [ ! -s "$T/out" ]'
  check "P3 '$p' records nothing" '[ ! -e "$F/.calls" ]'
done
F=$(fx created)
run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/missing.json'"
check "P3 a missing body file is rc 2, nothing recorded" '[ "$(rc)" = 2 ] && [ ! -e "$F/.calls" ]'
run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate'
check "P3 one arg is rc 2" '[ "$(rc)" = 2 ] && [ ! -e "$F/.calls" ]'
run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"' extra'
check "P3 three args is rc 2" '[ "$(rc)" = 2 ] && [ ! -e "$F/.calls" ]'

# ── P4: an unknown fixture is rc 3 ──────────────────────────────────────────
F=$(fx)
run_sh "$F" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"
check "P4 no status and no json is rc 3" '[ "$(rc)" = 3 ] && [ "$(posts)" = 1 ]'

# ── P5: not armed, no fake: rc 4, no process ────────────────────────────────
: > "$T/p5.log"
run_sh "" 'export VL='"'$T/p5.log'"'; gh_auth_armed() { return 1; }; gh_app_only_for() { echo mint >> "$VL"; return 0; }
  gh_app_only_release() { :; }; gh_rest() { echo rest >> "$VL"; }
  . "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"
check "P5 stubbed unarmed is rc 4" '[ "$(rc)" = 4 ] && [ ! -s "$T/out" ]'
check "P5 no mint and no REST call" '[ ! -s "$T/p5.log" ]'
run_sh "" '. "$SEAM"; og_post repos/T/tmpl/generate '"'$T/body.json'"
check "P5 real unarmed box is rc 4" '[ "$(rc)" = 4 ] && [ ! -s "$T/out" ]'

# ── P5b: the armed path (stubbed mint and REST) ─────────────────────────────
ARMED='gh_auth_armed() { return 0; }
gh_app_only_for() { echo "mint $1" >> "$L"; [ "${MINT:-0}" = 0 ] || return 1; export GH_TOKEN=ghs_FIXTURE; }
gh_app_only_release() { echo release >> "$L"; export GH_TOKEN=prior; }
gh_rest() { echo "rest $* token=$GH_TOKEN" >> "$L"; GH_REST_STATUS=${ST:-201}; [ "${RRC:-0}" = 0 ] && echo "{\"ok\":1}"; return "${RRC:-0}"; }
. "$SEAM"; GH_TOKEN=prior; og_post repos/T/tmpl/generate "$BODY"; r=$?
echo "status=$OG_HTTP_STATUS token=$GH_TOKEN" >> "$L"; exit $r'
export L="$T/armed.log" BODY="$T/body.json"
: > "$L"; run_sh "" "$ARMED"
check "P5b armed post is rc 0 with the body" '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"ok\":1}" ]'
check "P5b mints for the template, posts the file with the App token, releases" \
  '[ "$(sed -n 1p "$L")" = "mint T/tmpl" ] && [ "$(sed -n 2p "$L")" = "rest POST repos/T/tmpl/generate --input $BODY token=ghs_FIXTURE" ] && [ "$(sed -n 3p "$L")" = release ]'
check "P5b token restored, status set" 'grep -qx "status=201 token=prior" "$L"'
: > "$L"; MINT=1 run_sh "" "$ARMED"
check "P5b a refused mint is rc 44 and no REST call" '[ "$(rc)" = 44 ] && ! grep -q "^rest" "$L"'
: > "$L"; RRC=75 ST=422 run_sh "" "$ARMED"
check "P5b a 422 is rc 22, token restored" '[ "$(rc)" = 22 ] && grep -q release "$L" && grep -qx "status=422 token=prior" "$L"'
: > "$L"; RRC=75 ST=403 run_sh "" "$ARMED"
check "P5b a 403 is rc 44" '[ "$(rc)" = 44 ]'
: > "$L"; RRC=44 ST=404 run_sh "" "$ARMED"
check "P5b a 404 is rc 44" '[ "$(rc)" = 44 ]'
: > "$L"; RRC=75 ST=000 run_sh "" "$ARMED"
check "P5b a network failure is rc 75, one POST" '[ "$(rc)" = 75 ] && [ "$(grep -c "^rest" "$L")" = 1 ]'

# ── C1-C6: hp_probe_repo_create through the real hp_run ─────────────────────
# hr <setting stub> <args...>: hp_run repo-create with setting_get stubbed.
# The stub is bash code for setting_get's body; SETTING_LOG records its key.
hr() {
  local stub="$1"; shift
  rm -rf "$T/tmp"; mkdir -p "$T/tmp"
  env HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" JOBS_URL="" HARNESS_SECRET="" TMPDIR="$T/tmp" \
    ONBOARD_GITHUB_FAKE="${FAKE:-}" HPD="$HPD" STUB="$stub" SETTING_LOG="$T/setting.log" \
    bash -c 'eval "setting_get() { echo \"\$1\" >> \"\$SETTING_LOG\"; $STUB; }"; . "$HPD/common.sh" && hp_run repo-create "$@"; r=$?; echo "http=$HP_HTTP_STATUS" >&2; exit $r' _ "$@" \
    > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
TMPL='printf %s T/tmpl'
: > "$T/setting.log"
FAKE=$(fx created) hr "$TMPL" o n nextjs
check "C1 rc 0" '[ "$(rc)" = 0 ]'
check "C1 one JSON line" '[ "$(out)" = "{\"slug\":\"o/n\",\"created\":true}" ]'
check "C1 HP_HTTP_STATUS=201" 'grep -qx "http=201" "$T/err"'
check "C1 reads the settings row of the template key" '[ "$(cat "$T/setting.log")" = onboarding.template.nextjs ]'
check "C1 exactly one POST and nothing else" '[ "$(cat "$T/fx/.calls")" = "POST repos/T/tmpl/generate" ]'
check "C1 the body: owner, name, private, include_all_branches" \
  'jq -e ".owner == \"o\" and .name == \"n\" and .private == true and .include_all_branches == false" "$T/fx/.post-body" >/dev/null'
check "C1 TMPDIR is empty after the probe" '[ -z "$(ls -A "$T/tmp")" ]'
: > "$T/setting.log"
FAKE=$(fx created) hr "$TMPL" o n worker
check "C1 the worker key reads its own row" '[ "$(rc)" = 0 ] && [ "$(cat "$T/setting.log")" = onboarding.template.worker ]'

for d in exists-same exists-same-case; do
  FAKE=$(fx "$d") hr "$TMPL" o n empty
  check "C2 $d is rc 0, created:false" '[ "$(rc)" = 0 ] && [ "$(out)" = "{\"slug\":\"o/n\",\"created\":false}" ]'
  check "C2 $d one POST, then one GET of the target" '[ "$(cat "$T/fx/.calls")" = "$(printf "POST repos/T/tmpl/generate\nrepos/o/n")" ]'
  check "C2 $d TMPDIR is empty" '[ -z "$(ls -A "$T/tmp")" ]'
done

for d in exists-other exists-plain exists-gone; do
  FAKE=$(fx "$d") hr "$TMPL" o n nextjs
  check "C3 $d is rc 1" '[ "$(rc)" = 1 ]'
  check "C3 $d says name already exists" '[ "$(out)" = "name already exists: o/n was not made from T/tmpl" ]'
  check "C3 $d one POST, one GET" '[ "$(posts)" = 1 ] && [ "$(calls)" = 2 ]'
done

FAKE=$(fx created) hr 'return 2' o n nextjs
check "C4 no row is no template repo set, rc 1" '[ "$(rc)" = 1 ] && [ "$(out)" = "no template repo set" ]'
check "C4 no row makes no GitHub call" '[ ! -e "$T/fx/.calls" ]'
for val in '-' 'x' 'a/../b' 'a/.' 'a/..' 'https://github.com/a/b' 'a/b/c' 'a b/c' 'a/b ' "$(printf 'o%.0s' {1..40})/r" 'a_b/c' ''; do
  FAKE=$(fx created) VAL="$val" hr 'printf %s "$VAL"' o n nextjs
  check "C4 value '$val' is no template repo set" '[ "$(rc)" = 1 ] && [ "$(out)" = "no template repo set" ]'
  check "C4 value '$val' makes no call" '[ ! -e "$T/fx/.calls" ]'
done
FAKE=$(fx created) hr 'return 1' o n nextjs
check "C4 an unreadable row is settings-unreadable, rc 1, no call" \
  '[ "$(rc)" = 1 ] && [ "$(out)" = settings-unreadable ] && [ ! -e "$T/fx/.calls" ]'

FAKE=$(fx refused) hr "$TMPL" o n nextjs
check "C5 403 is template repo not visible" '[ "$(rc)" = 1 ] && [ "$(out)" = "template repo not visible to the App: T/tmpl" ]'
check "C5 403 HP_HTTP_STATUS=403" 'grep -qx "http=403" "$T/err"'
FAKE=$(fx server-error) hr "$TMPL" o n nextjs
check "C5 500 is github error 500" '[ "$(rc)" = 1 ] && [ "$(out)" = "github error 500" ]'
check "C5 500 is never retried: one POST" '[ "$(cat "$T/fx/.calls")" = "POST repos/T/tmpl/generate" ]'
FAKE=$(fx) hr "$TMPL" o n nextjs
check "C5 an unknown fixture is github error, rc 1" '[ "$(rc)" = 1 ] && [[ "$(out)" == "github error"* ]]'
FAKE="" hr "$TMPL" o n nextjs
check "C5 an unarmed box is not-configured" '[ "$(rc)" = 1 ] && [ "$(out)" = not-configured ]'
check "C6 TMPDIR is empty after the failure paths" '[ -z "$(ls -A "$T/tmp")" ]'

# C6: no output line holds a token or a response body field.
: > "$T/all.out"
for d in created exists-same exists-other exists-gone refused server-error; do
  FAKE=$(fx "$d") hr "$TMPL" o n nextjs
  cat "$T/out" >> "$T/all.out"
  check "C6 $d prints exactly one line" '[ "$(grep -c . "$T/out")" = 1 ]'
  check "C6 $d leaves TMPDIR empty" '[ -z "$(ls -A "$T/tmp")" ]'
done
check "C6 no line says token" '! grep -qi token "$T/all.out"'
check "C6 no response body field leaks" '! grep -q "message\|errors\|Unprocessable\|private\|template_repository" "$T/all.out"'

# ── K1: one REAL bin/hub-probe.sh tick claims a repo-create row ─────────────
H="$T/lane"
mkdir -p "$H"
cp -rs "$DIR/bin" "$H/bin"
rm -f "$H/bin/alert-line.sh"
printf '#!/bin/bash\necho "alert-line $*" >> "%s/alerts"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
printf 'bp   o/r   -   -   5  local\n' > "$H/fleet.conf"
mkdir -p "$T/jobs"
jq -nc '{rows:[{id:51, project:"onboarding", ticket_key:"onb-create-0123456789abcdef", probe:"repo-create", args:["o","n","nextjs"]}]}' > "$T/jobs/claim"
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
setting_get() { [ "$1" = onboarding.template.nextjs ] && { printf %s T/tmpl; return 0; }; return 2; }
gh_rest() { echo "gh_rest $*" >> "$VLOG"; return 75; }
gh_rest_issue_comments() { echo "gh_rest_issue_comments $*" >> "$VLOG"; return 75; }
SH
F=$(fx created)
lane() {
  HARNESS="$H" HARNESS_ENV_DIR="$T/env" FLEET_CONF="$H/fleet.conf" FXT="$T" VLOG="$VLOG" HUB_PROBE_FIXTURE="$T/lane-fx.sh" \
    ONBOARD_GITHUB_FAKE="$F" HARNESS_TEST_SANDBOX=1 bash "$H/bin/hub-probe.sh" > "$T/lane.out" 2>&1
  echo $? > "$T/rc"
}
lane
check "K1 the tick exits 0" '[ "$(rc)" = 0 ] || { cat "$T/lane.out"; false; }'
check "K1 the row is stored pass with the created line" \
  '[ "$(jq -r .result "$T/body-result" 2>/dev/null)" = pass ] && [ "$(jq -r .output "$T/body-result" | tr -d "\n")" = "{\"slug\":\"o/n\",\"created\":true}" ]'
check "K1 http_status 201" '[ "$(jq -r .http_status "$T/body-result")" = 201 ]'
check "K1 one POST through the fake" '[ "$(cat "$F/.calls")" = "POST repos/T/tmpl/generate" ]'
check "K1 no comment posted, no alert" '[ ! -s "$VLOG" ] && [ ! -s "$T/alerts" ]'
check "K1 summary counts one pass" '[[ "$(tail -1 "$H/logs/hub-probe.log")" == *"claimed=1 ran=1 pass=1 fail=0"* ]]'
echo '{"rows":[]}' > "$T/jobs/claim"
lane
check "K1 a second tick that claims nothing exits 0" '[ "$(rc)" = 0 ]'
check "K1 still one POST after the second tick" '[ "$(grep -c "^POST " "$F/.calls")" = 1 ]'
check "K1 still one stored result" '[ "$(grep -c . "$T/body-result")" = 1 ]'

# ── B1: vendor_calls=0 ──────────────────────────────────────────────────────
VC=$(grep -c . "$VLOG" 2>/dev/null); VC=${VC:-0}
echo "vendor_calls=$VC"
check "B1 the recording vendor binaries never ran" '[ "$VC" = 0 ]'

# ── N1: the worker and console halves, by path, under node ──────────────────
ROUTE="$DIR/worker/jobs/src/routes/onboarding-repo-create.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-8001-onboarding-repo-create.txt"
WTEST="$DIR/worker/jobs/test/onboarding-repo-create.bh-8001.test.js"
COORD="$DIR/console-ui/functions/_lib/coord-writes.d/8001-onboarding-repo-create.js"
PANEL="$DIR/console-ui/src/screens/onboard/NewRepoPanel.js"
CTEST="$DIR/console-ui/tests/new-repo-panel.bh-8001.test.js"
SQL=$(ls "$DIR"/worker/jobs/schema.d/*-bh-8001-onboarding-templates.sql 2>/dev/null | head -n 1)
for f in "$ROUTE" "$FRAG" "$WTEST" "$COORD" "$PANEL" "$CTEST" "$SQL"; do
  check "N1 $f exists" '[ -n "$f" ] && [ -f "$f" ]'
done
check "N1 the fragment lists the three routes" \
  'grep -qx "POST /api/onboarding/repo-create" "$FRAG" && grep -qx "GET /api/onboarding/repo-create/templates" "$FRAG" && grep -q "^GET re:.*repo-create" "$FRAG"'
if command -v node >/dev/null 2>&1; then
  check "N1 the route module parses" 'node --check "$ROUTE"'
  if [ -d "$DIR/worker/jobs/node_modules" ] || [ -z "$(jq -r '.dependencies // {} | keys[]' "$DIR/worker/jobs/package.json" 2>/dev/null)" ]; then
    (cd "$DIR/worker/jobs" && node --test test/onboarding-repo-create.bh-8001.test.js) > "$T/node-w.out" 2>&1; NRC=$?
    check "N1 worker node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-w.out"; false; }'
  fi
  if [ -d "$DIR/console-ui/node_modules" ]; then
    (cd "$DIR/console-ui" && node --test tests/new-repo-panel.bh-8001.test.js) > "$T/node-c.out" 2>&1; NRC=$?
    check "N1 console node suite green" '[ "$NRC" = 0 ] || { tail -30 "$T/node-c.out"; false; }'
  fi
fi

echo "onboard-repo-create: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
