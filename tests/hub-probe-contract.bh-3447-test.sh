#!/bin/bash
# tests/hub-probe-contract.bh-3447-test.sh — the hub-probe contract slice
# (BH-3447, BH-3434.0): the seven hp_* client verbs, the probe allowlist
# validator, the fixed-case dispatcher, the on-pass hook and the two worker
# route stubs. The client verbs are reached through the REAL bin/jobs-client.sh
# (JC_MODULES) from a scratch harness copy, with _jobs_req redefined after the
# source to log `METHOD PATH BODY` and hand back a canned answer.
#   C1-C7  each verb: method, path, body, stdout, rc 0
#   C8     every verb: rc 1 + empty stdout on outage, on a 2xx without the
#          field, on a bad arg count; bad args never reach _jobs_req
#   V1-V7  hp_run rejects (rc 2) with an EMPTY call log: gh_rest, _jobs_req and
#          curl are all stubbed to append to it
#   V8     a valid call with no probe file -> `not-implemented`, rc 1
#   V9     a probe file present -> its stdout, HP_HTTP_STATUS, rc 0; rc 5 -> 1
#   V10    the three allowlists equal the ticket's strings
#   P1     hp_on_pass is a silent rc-0 no-op
#   K1     no hp_ name collides across the client modules and hub-probes/
#   W1     worker/jobs/src/index.js still imports, and ROUTES carries every hub-probe route
# Run from anywhere: tests/hub-probe-contract.bh-3447-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

for f in "$DIR/bin/lib/jobs/hub-probe.sh" "$DIR/bin/lib/hub-probes/common.sh" "$DIR/bin/lib/hub-probes/on-pass.sh" \
         "$DIR/worker/jobs/src/routes/hub-probe.js" "$DIR/worker/jobs/src/routes/hub-probe-count.js"; do
  case "$f" in *.sh) [ -f "$f" ] && bash -n "$f" 2>/dev/null ;; *) [ -f "$f" ] ;; esac && ok || bad "missing or unparseable $f"
done

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/hub-probes" "$H/logs" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" && cp "$DIR"/bin/lib/*.sh "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/hub-probes/*.sh "$H/bin/lib/hub-probes/" 2>/dev/null
CALLS="$T/calls.log"; ANS="$T/answer"; RCF="$T/rc"
printf '#!/bin/bash\necho "curl $*" >> "%s"\nexit 7\n' "$CALLS" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export CALLS ANS RCF H

# The stubs every case runs under: the transport, the REST helper and curl all
# append to the call log, so "nothing was called" is an empty file.
STUBS='_jobs_req() { printf "%s %s %s\n" "$1" "$2" "${3:-}" >> "$CALLS"; [ "$(cat "$RCF")" = 0 ] || return 1; cat "$ANS"; }
gh_rest() { echo "gh_rest $*" >> "$CALLS"; return 1; }'
export STUBS

# hpc <answer> <jobs_req rc> <verb args...> — one client verb through the real
# client. stdout -> $T/out, rc -> $T/vrc, call log reset first.
hpc() {
  printf '%s' "$1" > "$ANS"; echo "$2" > "$RCF"; shift 2; : > "$CALLS"
  PATH="$T/fakebin:$PATH" HARNESS="$H" JOBS_URL="" HARNESS_SECRET="" bash -c '
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 99
    eval "$STUBS"
    "$@"' _ "$@" > "$T/out" 2>/dev/null
  echo $? > "$T/vrc"
}
out() { cat "$T/out"; }
vrc() { cat "$T/vrc"; }
calls() { cat "$CALLS"; }
body() { sed -n '1s/^[A-Z]* [^ ]* //p' "$CALLS"; }

# --- C1-C7 ------------------------------------------------------------------
hpc '{"created":true,"row":{"id":1}}' 0 hp_request p BH-1 d1-count '["jobs","all"]' me
[ "$(vrc)" = 0 ] && [ "$(out)" = '{"created":true,"row":{"id":1}}' ] && ok || bad "C1 hp_request rc=$(vrc) out=$(out)"
[ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/hub-probe" ] && ok || bad "C1 path: $(calls)"
[ "$(body | jq -c '[.project,.ticket_key,.probe,.args,.requested_by]')" = '["p","BH-1","d1-count",["jobs","all"],"me"]' ] && ok || bad "C1 body: $(body)"

hpc '{"rows":[{"id":1}]}' 0 hp_claim box 3
[ "$(vrc)" = 0 ] && [ "$(out)" = '[{"id":1}]' ] && ok || bad "C2 hp_claim rc=$(vrc) out=$(out)"
[ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/hub-probe/claim" ] && ok || bad "C2 path: $(calls)"
[ "$(body | jq -c .)" = '{"claimed_by":"box","n":3}' ] && ok || bad "C2 body: $(body)"

printf 'line one\nline "two" & $x\n' > "$T/probe-out"
hpc '{"ok":true}' 0 hp_result 7 pass 201 "$T/probe-out"
[ "$(vrc)" = 0 ] && ok || bad "C3 hp_result rc=$(vrc)"
[ "$(head -1 "$CALLS" | cut -d' ' -f1-2)" = "POST /api/hub-probe/result" ] && ok || bad "C3 path: $(calls)"
[ "$(sed -n '1s/^POST [^ ]* //p' "$CALLS" | jq -r '.output')" = "$(cat "$T/probe-out")" ] \
  && [ "$(sed -n '1s/^POST [^ ]* //p' "$CALLS" | jq -c '[.id,.result,.http_status]')" = '[7,"pass",201]' ] && ok || bad "C3 body: $(calls)"
hpc '{"ok":false}' 0 hp_result 7 pass 201 "$T/probe-out"
[ "$(vrc)" = 1 ] && [ -z "$(out)" ] && ok || bad "C3 ok:false must be rc 1, got $(vrc)"

hpc '{"ok":true}' 0 hp_commented 7
[ "$(vrc)" = 0 ] && [ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/hub-probe/commented" ] && [ "$(body | jq -c .)" = '{"id":7}' ] && ok || bad "C4 hp_commented rc=$(vrc) $(calls)"

hpc '{"rows":[]}' 0 hp_list 'a&b' BH-1
[ "$(vrc)" = 0 ] && [ "$(out)" = '[]' ] && ok || bad "C5 hp_list rc=$(vrc) out=$(out)"
[ "$(calls)" = "GET /api/hub-probe?project=a%26b&ticket=BH-1 " ] && ok || bad "C5 path: $(calls)"

hpc '{"count":4}' 0 hp_count_today d1-count
[ "$(vrc)" = 0 ] && [ "$(out)" = 4 ] && [ "$(calls)" = "GET /api/hub-probe/count-today?probe=d1-count " ] && ok || bad "C6 hp_count_today rc=$(vrc) out=$(out) $(calls)"

hpc '{"count":0}' 0 hp_d1_count jobs all
[ "$(vrc)" = 0 ] && [ "$(out)" = 0 ] && [ "$(calls)" = "GET /api/hub-probe/count?table=jobs&template=all " ] && ok || bad "C7 hp_d1_count rc=$(vrc) out=$(out) $(calls)"

# --- C8 failures --------------------------------------------------------------
VERBS=(
  "hp_request p BH-1 d1-count [] me"
  "hp_claim box 3"
  "hp_result 7 fail 500 $T/probe-out"
  "hp_commented 7"
  "hp_list p BH-1"
  "hp_count_today d1-count"
  "hp_d1_count jobs all"
)
for v in "${VERBS[@]}"; do
  read -ra a <<<"$v"
  hpc '{"created":true,"row":{},"rows":[],"ok":true,"count":1}' 1 "${a[@]}"
  [ "$(vrc)" = 1 ] && [ -z "$(out)" ] && [ -s "$CALLS" ] && ok || bad "C8 outage: $v rc=$(vrc) out=$(out)"
  hpc '{}' 0 "${a[@]}"
  [ "$(vrc)" = 1 ] && [ -z "$(out)" ] && ok || bad "C8 2xx without the field: $v rc=$(vrc) out=$(out)"
  hpc '<html>oops</html>' 0 "${a[@]}"
  [ "$(vrc)" = 1 ] && [ -z "$(out)" ] && ok || bad "C8 garbage 2xx: $v rc=$(vrc) out=$(out)"
  hpc '{"ok":true,"count":1,"rows":[]}' 0 "${a[@]}" extra
  [ "$(vrc)" = 1 ] && [ -z "$(out)" ] && [ ! -s "$CALLS" ] && ok || bad "C8 extra arg: $v rc=$(vrc) calls=$(calls)"
done
# wrong-typed fields are failures too, never an empty success
hpc '{"count":"4"}' 0 hp_count_today d1-count
[ "$(vrc)" = 1 ] && [ -z "$(out)" ] && ok || bad "C8 string count accepted: $(out)"
hpc '{"created":"yes","row":{}}' 0 hp_request p BH-1 d1-count '[]' me
[ "$(vrc)" = 1 ] && [ -z "$(out)" ] && ok || bad "C8 non-boolean created accepted: $(out)"
for v in "hp_request p BH-1 d1-count {nope me" "hp_claim box x" "hp_claim box -1" \
         "hp_result 7 maybe 200 $T/probe-out" "hp_result 7 pass 200 /nope/missing"; do
  read -ra a <<<"$v"
  hpc '{"ok":true,"created":true,"row":{},"rows":[]}' 0 "${a[@]}"
  [ "$(vrc)" = 1 ] && [ -z "$(out)" ] && [ ! -s "$CALLS" ] && ok || bad "C8 bad arg reached the wire: $v rc=$(vrc) calls=$(calls)"
done

# --- hp_run / hp_validate --------------------------------------------------------
# hr <hub-probes dir> <fn args...> — source common.sh from that dir in a fresh
# shell under the stubs; stdout -> $T/out, rc -> $T/vrc, HP_HTTP_STATUS -> $T/st.
hr() {
  local d="$1"; shift; : > "$CALLS"; echo 1 > "$RCF"; : > "$ANS"
  PATH="$T/fakebin:$PATH" D="$d" ST="$T/st" bash -c '
    eval "$STUBS"
    . "$D/common.sh" || exit 99
    HP_HTTP_STATUS=unset
    "$@"; rc=$?
    printf "%s" "$HP_HTTP_STATUS" > "$ST"
    exit $rc' _ "$@" > "$T/out" 2>/dev/null
  echo $? > "$T/vrc"
}
HPD="$H/bin/lib/hub-probes"
# HP0: common.sh and on-pass.sh alone, no probe file (BH-3449 ships the probes into HPD)
HP0="$T/hp0"; mkdir -p "$HP0"; cp "$HPD/common.sh" "$HPD/on-pass.sh" "$HP0/"
SHA=0123456789abcdef0123456789abcdef01234567
rej() { # rej <label> <hp_run args...> — rc 2, nothing called, nothing printed
  local l="$1"; shift
  hr "$HPD" hp_run "$@"
  [ "$(vrc)" = 2 ] && [ ! -s "$CALLS" ] && [ -z "$(out)" ] && ok || bad "$l: hp_run $* rc=$(vrc) calls=$(calls) out=$(out)"
}
rej V1 nope x
rej V2 app-status-write 'a/b;rm' "$SHA"
rej V3 app-status-write a/b abc
rej V4 d1-count secrets all
rej V5 d1-count jobs "1=1"
rej V6 app-status-write example-org/cromford '$(id)'
rej V7-upper-sha app-status-write a/b "${SHA^^}"
rej V7-39hex app-status-write a/b "${SHA:1}"
rej V7-41hex app-status-write a/b "${SHA}0"
rej V7-3part app-status-write a/b/c "$SHA"
rej V7-dotdot app-status-write ../x "$SHA"
rej V7-dotdot-name app-status-write a/.. "$SHA"
rej V7-dot app-status-write ./x "$SHA"
rej V7-sha-count app-status-write a/b
rej V7-slug-dash app-permissions -bad
rej V7-slug-upper app-permissions Bad
rej V7-slug-64 app-permissions "a$(printf 'b%.0s' $(seq 63))"
rej V7-slug-count app-permissions
rej V7-inst-extra app-installation-repos x
rej V7-d1-one d1-count jobs
rej V7-d1-space d1-count 'jobs ledgers' all
rej V7-d1-empty d1-count jobs ''
rej V7-d1-semi d1-count 'jobs;' all
rej V7-d1-template d1-count jobs 'all last-24h'
rej V7-name-semi 'd1-count;x' jobs all
rej V7-fn-name hp_probe_d1_count
rej V7-empty ''
rej V7-noargs
rej V7-newline app-status-write $'a/b\nc' "$SHA"
rej V7-newline-sha app-status-write a/b "$SHA"$'\n'
hr "$HPD" hp_validate app-permissions "a$(printf 'b%.0s' $(seq 62))"
[ "$(vrc)" = 0 ] && [ -z "$(out)" ] && ok || bad "V7 63-char slug must validate, rc=$(vrc)"
hr "$HPD" hp_validate app-installation-repos
[ "$(vrc)" = 0 ] && ok || bad "V7 app-installation-repos with no args must validate, rc=$(vrc)"
hr "$HPD" hp_validate d1-count hub_probe_requests last-24h
[ "$(vrc)" = 0 ] && ok || bad "V7 d1-count hub_probe_requests last-24h must validate, rc=$(vrc)"
hr "$HPD" hp_validate app-status-write example-org/cromford "$SHA"
[ "$(vrc)" = 0 ] && ok || bad "V7 a real repo + sha must validate, rc=$(vrc)"
hr "$HPD" hp_validate app-status-write example-org/.github "$SHA"
[ "$(vrc)" = 0 ] && ok || bad "V7 owner/.github (a dot-led name, not a dot segment) must validate, rc=$(vrc)"

# V8: valid, but no probe file present
for args in "app-status-write example-org/cromford $SHA" "d1-count jobs all" \
            "app-permissions my-app" "app-installation-repos"; do
  read -ra a <<<"$args"
  hr "$HP0" hp_run "${a[@]}"
  [ "$(vrc)" = 1 ] && [ "$(out)" = not-implemented ] && [ ! -s "$CALLS" ] && [ -z "$(cat "$T/st")" ] \
    && ok || bad "V8 hp_run $args rc=$(vrc) out=$(out) status=$(cat "$T/st")"
done

# V9: a probe file dropped beside a scratch copy of common.sh is dispatched to
HP2="$T/hp2"; mkdir -p "$HP2"; cp "$HP0"/*.sh "$HP2/"
cat > "$HP2/d1-count.sh" <<'EOF'
hp_probe_d1_count() { echo "n=3 $1 $2"; HP_HTTP_STATUS=200; return "${PROBE_RC:-0}"; }
EOF
hr "$HP2" hp_run d1-count jobs all
[ "$(vrc)" = 0 ] && [ "$(out)" = "n=3 jobs all" ] && [ "$(cat "$T/st")" = 200 ] && ok || bad "V9 PASS probe rc=$(vrc) out=$(out) status=$(cat "$T/st")"
PROBE_RC=5 hr "$HP2" hp_run d1-count jobs all
[ "$(vrc)" = 1 ] && [ "$(out)" = "n=3 jobs all" ] && ok || bad "V9 probe rc 5 must be FAIL rc 1, got $(vrc)"
PROBE_RC=2 hr "$HP2" hp_run d1-count jobs all
[ "$(vrc)" = 1 ] && ok || bad "V9 probe rc 2 must not pass through as a validation reject, got $(vrc)"
# a probe file for another name is never reached from d1-count
cat > "$HP2/app-permissions.sh" <<'EOF'
hp_probe_app_permissions() { echo WRONG; HP_HTTP_STATUS=200; return 0; }
EOF
hr "$HP2" hp_run app-permissions my-app
[ "$(vrc)" = 0 ] && [ "$(out)" = WRONG ] && ok || bad "V9 app-permissions dispatch rc=$(vrc) out=$(out)"
hr "$HP2" hp_run app-status-write a/b "$SHA"
[ "$(vrc)" = 1 ] && [ "$(out)" = not-implemented ] && ok || bad "V9 app-status-write must not hit another probe's file, out=$(out)"

# V10
V10=$(bash -c '. "$1/common.sh" && printf "%s|%s|%s" "$HP_PROBES" "$HP_D1_TABLES" "$HP_D1_TEMPLATES"' _ "$HPD")
[ "$V10" = "app-status-write app-permissions app-installation-repos d1-count|jobs ledgers split_watchdog_actions hub_probe_requests|all last-24h" ] \
  && ok || bad "V10 allowlists: $V10"

# P1
: > "$CALLS"
P1=$(PATH="$T/fakebin:$PATH" bash -c 'eval "$STUBS"; . "$1/on-pass.sh" || exit 99; hp_on_pass a BH-1 d1-count "[]"' _ "$HPD"); P1RC=$?
[ "$P1RC" = 0 ] && [ -z "$P1" ] && [ ! -s "$CALLS" ] && ok || bad "P1 hp_on_pass rc=$P1RC out=$P1 calls=$(calls)"

# --- K1: no collision -------------------------------------------------------------
# Every hp_/_hp_ name the client defines WITHOUT the hub-probe module must be
# none; with it, exactly the seven verbs + the four _hp_ helpers; hub-probes/ disjoint.
H2="$T/h2"; mkdir -p "$H2/bin/lib/jobs"
cp "$H"/bin/lib/*.sh "$H2/bin/lib/"; cp "$H"/bin/lib/jobs/*.sh "$H2/bin/lib/jobs/"
# hub-probe is struck wherever it sits in the list (BH-3726 appended a module after it).
sed -E '/^JC_MODULES=/s/ hub-probe( |")/\1/' "$H/bin/jobs-client.sh" > "$H2/bin/jobs-client.sh"
grep -q '^JC_MODULES=.* hub-probe[ "]' "$DIR/bin/jobs-client.sh" && ok || bad "K1 JC_MODULES does not name hub-probe"
grep -q '^JC_MODULES=.* hub-probe[ "]' "$H2/bin/jobs-client.sh" && bad "K1 the copy still names hub-probe: $(grep '^JC_MODULES=' "$H2/bin/jobs-client.sh")" || ok
names() { HARNESS="$1" JOBS_URL="" bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 99; declare -F' \
  | awk '{print $3}' | grep -E '^_?hp_' | LC_ALL=C sort > "$2"; }
names "$H2" "$T/k-without"; names "$H" "$T/k-with"
[ ! -s "$T/k-without" ] && ok || bad "K1 existing modules already define: $(tr '\n' ' ' < "$T/k-without")"
[ "$(tr '\n' ' ' < "$T/k-with")" = "_hp_count _hp_ok _hp_rows _hp_uri hp_claim hp_commented hp_count_today hp_d1_count hp_list hp_request hp_result " ] \
  && ok || bad "K1 client hp_ set: $(tr '\n' ' ' < "$T/k-with")"
bash -c '. "$1/common.sh"; . "$1/on-pass.sh"; declare -F' _ "$HPD" | awk '{print $3}' | grep -E '^_?hp_' | LC_ALL=C sort > "$T/k-probes"
[ "$(tr '\n' ' ' < "$T/k-probes")" = "_hp_in hp_on_pass hp_run hp_validate " ] && ok || bad "K1 hub-probes set: $(tr '\n' ' ' < "$T/k-probes")"
[ -z "$(LC_ALL=C comm -12 "$T/k-with" "$T/k-probes")" ] && ok || bad "K1 collision: $(LC_ALL=C comm -12 "$T/k-with" "$T/k-probes")"

# --- W1: index.js imports, and every hub-probe route is in its ROUTES (BH-3448 filled the stubs) --
if command -v node >/dev/null 2>&1; then
  if [ ! -f "$DIR/catalog/lanes.json" ]; then
    HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 || bad "W1 lanes.json: $(cat "$T/lb.out")"
  fi
  W1=$(node --input-type=module -e "
    const m = await import('$DIR/worker/jobs/src/index.js');
    const hp = await import('$DIR/worker/jobs/src/routes/hub-probe.js');
    const hc = await import('$DIR/worker/jobs/src/routes/hub-probe-count.js');
    const wired = (r) => Array.isArray(r) && r.length > 0 && r.every((e) => m.default.ROUTES.includes(e));
    console.log(Array.isArray(m.default.ROUTES), wired(hp.routes), wired(hc.routes));" 2>&1)
  [ "$W1" = "true true true" ] && ok || bad "W1 worker import: $W1"
  # TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
  [ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-hub-probe.txt 2>/dev/null | wc -l)" = 1 ] && ok \
    || bad "hub-probe has no route-table.d fragment (BH-4607: the fragment IS the registration)"
  # TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
  [ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-hub-probe-count.txt 2>/dev/null | wc -l)" = 1 ] && ok \
    || bad "hub-probe-count has no route-table.d fragment (BH-4607: the fragment IS the registration)"
else
  echo "hub-probe-contract: W1 SKIPPED, no node on this box (CI's worker/jobs job runs vitest)"
fi

echo "hub-probe-contract.bh-3447: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
