#!/bin/bash
# tests/project-secrets.bh-8317-test.sh — BH-8317 (MKF-2): bin/project-secrets.sh,
# the operator verb that keeps a project's build secrets in Fly app secrets
# (write-only) and only their NAMES in the jobs worker (project_secret_names).
#
# DRIVEN: the real verb against a scratch $HARNESS, under env -i, on a PATH of
# stubs plus a dir of links to local tools only. fly/flyctl, curl (a tiny
# router over a JSON file standing in for the worker routes), ssh, gh, timeout
# and alert-line.sh are stubs. No real network tool is reachable (S-B1).
# PINNED:
#   S-A1 set stages the value into every manifest app (HBUNDLE_P_<NAME> on the
#        pool app, <NAME> elsewhere); the value is in no argv, output, log or
#        alert: only the fly stdin sink holds it. Order: PUT, imports, stamp PUT.
#   S-A2 verify: MISSING / ok / OPTIONAL-MISSING / UNKNOWN / INCOMPLETE / no rows
#   S-A4 a value with a single quote is refused with the key name only
#   S-R1 the NAME rule (accept / refuse, 0 calls on a refusal)
#   S-R4 empty and two-line values refused; dotenv quoting of the rest
#   S-X1..S-X7 exit paths       S-U1 S-U2 unset       S-L1 list
#   S-I1 import (names only)    S-Q1 a first set      S-K1 timeout knob
#   S-RT the staged line round-trips through fly/entrypoint.sh's compose arm
#   S-B1 budget: 0 real network calls
#   S-W  the worker routes are bearer-gated; the node suites pass, 0 skipped
# Each case resets its own capture dir; no order dependence.
# Run from anywhere: bash tests/project-secrets.bh-8317-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

P=project-6-os
POOL=pool-project-6-os
VERB="$DIR/bin/project-secrets.sh"
H="$T/h"; STUB="$T/stub"; TOOLS="$T/tools"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state/fly" "$STUB" "$TOOLS" "$T/tmp" "$T/home" "$T/nofly"
for s in bin/jobs-client.sh bin/project-secrets.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "closure install failed for $s"
done
printf 'FLY_API_TOKEN_project-6_OS=tok-fixture-fly\n' > "$H/env/fly.env"
printf '{"app":"%s"}\n' "$POOL" > "$H/state/fly/$P.json"
cat > "$H/bin/alert-line.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP/alerts.txt"
EOF

# Local tools only: no curl, ssh, fly, flyctl, gh, wget or nc.
for b in bash sh jq awk grep sed cut sort comm tr mktemp rm cat date head tail chmod mkdir find wc env \
         dirname basename tee touch stat id ls uniq mv cp ln sleep true false expr xargs od readlink tac printf; do
  p=$(command -v "$b" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$TOOLS/$b" ;; esac
done

# fly / flyctl: argv to fly.argv, import stdin to fly.stdin ("<app> <line>"),
# the per-app secret NAMES in flystate/<app>. Failure switches per app.
cat > "$STUB/fly" <<'EOF'
#!/bin/bash
echo "fly $*" >> "$CAP/fly.argv"
app=""; prev=""; names=()
for a in "$@"; do
  if [ "$prev" = -a ]; then app="$a"; elif [ -n "$app" ] && [[ "$a" != -* ]]; then names+=("$a"); fi
  prev="$a"
done
mkdir -p "$CAP/flystate"; S="$CAP/flystate/$app"; touch "$S"
case "$*" in
  *"secrets import"*)
    echo "fly import $app" >> "$CAP/events"
    while IFS= read -r l || [ -n "$l" ]; do
      printf '%s %s\n' "$app" "$l" >> "$CAP/fly.stdin"
      [ "$app" = "${IMPORT_FAIL_APP:-}" ] || [ "${IMPORT_NOLIST:-0}" = 1 ] && continue
      k="${l%%=*}"; grep -qx "$k" "$S" || echo "$k" >> "$S"
    done
    [ "$app" = "${IMPORT_FAIL_APP:-}" ] && { echo "Error: fixture import failure" >&2; exit 1; } ;;
  *"secrets list"*)
    echo "fly list $app" >> "$CAP/events"
    [ "$app" = "${LIST_FAIL_APP:-}" ] && { echo "Error: fixture list failure" >&2; exit 1; }
    jq -R -s -c 'split("\n") | map(select(length > 0)) | map({Name: ., Digest: ("dg-fixture-" + .)})' "$S" ;;
  *"secrets unset"*)
    echo "fly unset $app" >> "$CAP/events"
    [ "$app" = "${UNSET_FAIL_APP:-}" ] && { echo "Error: fixture unset failure" >&2; exit 1; }
    [ "$app" = "${UNSET_NOTFOUND_APP:-}" ] && { echo "Error: secret not found" >&2; exit 1; }
    for n in "${names[@]}"; do grep -vx "$n" "$S" > "$S.x"; mv "$S.x" "$S"; done ;;
esac
exit 0
EOF
cp "$STUB/fly" "$STUB/flyctl"
# curl: the jobs worker routes over rows.json (the GET answer shape).
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
a="$*"; printf 'curl %s\n' "${a//$'\n'/\\n}" >> "$CAP/curl.argv"
m=GET; body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#http://jobs.invalid}"
DB="$CAP/rows.json"; [ -s "$DB" ] || echo '[]' > "$DB"
reply() { printf '%s\n%s' "$2" "$1"; exit 0; }
q() { sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p" <<<"$path"; }
echo "curl $m ${path%%\?*}" >> "$CAP/events"
case "$m $path" in
  "GET /api/settings/project_secrets.fly_timeout_s")
    [ "${SETTINGS_FAIL:-0}" = 1 ] && reply 503 '{"error":"fixture down"}'
    [ -n "${TIMEOUT_ROW:-}" ] && reply 200 "{\"setting\":{\"key\":\"project_secrets.fly_timeout_s\",\"value\":\"$TIMEOUT_ROW\"}}"
    reply 404 '{"error":"no such setting"}' ;;
  "GET /api/project-secrets/names?"*)
    [ "${GET_FAIL:-0}" = 1 ] && reply 503 '{"error":"fixture down"}'
    reply 200 "$(jq -c --arg p "$(q project)" --argjson tr "${TRUNC:-false}" \
      '[.[] | select(.project == $p)] | sort_by(.name) as $r
       | {project: $p, names: $r, pending: ([$r[] | select(.set_at == null)] | length), limit: 500, truncated: $tr}' "$DB")" ;;
  "PUT /api/project-secrets/names")
    printf '%s\n' "$body" >> "$CAP/put.log"
    [ "${PUT_FAIL:-0}" = 1 ] && reply 503 '{"error":"fixture down"}'
    [ "${PUT_FAIL_STAMP:-0}" = 1 ] && jq -e '.stamp == true' >/dev/null <<<"$body" && reply 503 '{"error":"fixture down"}'
    jq -c --argjson b "$body" '
      (map(select(.project == $b.project and .name == $b.name)) | .[0]) as $old
      | map(select((.project == $b.project and .name == $b.name) | not))
      + [{project: $b.project, name: $b.name, apps: $b.apps, need: ($b.need // "required"),
          set_at: (if $b.stamp == true then "2026-10-25T23:00:00Z" else ($old.set_at // null) end),
          set_by: $b.set_by, digest: ($b.digest // $old.digest // null)}]' "$DB" > "$DB.x" && mv "$DB.x" "$DB"
    reply 200 "$(jq -c --argjson b "$body" '.[] | select(.project == $b.project and .name == $b.name) | {project, name, set_at}' "$DB")" ;;
  "DELETE /api/project-secrets/names?"*)
    echo "$path" >> "$CAP/del.log"
    n=$(q name); p=$(q project)
    jq -e --arg p "$p" --arg n "$n" 'any(.[]; .project == $p and .name == $n)' "$DB" >/dev/null || reply 404 '{"error":"no such name"}'
    jq -c --arg p "$p" --arg n "$n" 'map(select((.project == $p and .name == $n) | not))' "$DB" > "$DB.x" && mv "$DB.x" "$DB"
    reply 200 '{"deleted":true}' ;;
esac
reply 404 '{"error":"no route"}'
EOF
for s in ssh gh; do printf '#!/bin/bash\necho "%s $*" >> "%s/net.calls"\nexit 1\n' "$s" "$T" > "$STUB/$s"; done
printf '#!/bin/bash\necho "timeout $1" >> "$CAP/timeout.log"\nshift; exec "$@"\n' > "$STUB/timeout"
chmod +x "$STUB"/* "$H/bin/alert-line.sh"
: > "$T/net.calls"

reset() { CAP="$T/cap"; scratch_rm "$CAP"; mkdir -p "$CAP/flystate"; : > "$CAP/fly.argv"; : > "$CAP/put.log"; : > "$CAP/del.log"; : > "$CAP/alerts.txt"; echo '[]' > "$CAP/rows.json"; }
seed() { printf '%s\n' "$1" > "$CAP/rows.json"; }
flyhas() { local app="$1"; shift; printf '%s\n' "$@" > "$CAP/flystate/$app"; }
rowj() { # rowj <name> <apps-json> [need] [set_at-json]
  printf '{"project":"%s","name":"%s","apps":%s,"need":"%s","set_at":%s,"set_by":"fixture-op","digest":null}' \
    "$P" "$1" "$2" "${3:-required}" "${4:-null}"
}
# run <stdin> <verb args...> [-- VAR=val ...]: RC, OUT, ERR
run() {
  local input="$1"; shift
  local args=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  printf '%s' "$input" | env -i PATH="$STUB:$TOOLS" HOME="$T/home" HARNESS="$H" TMPDIR="$T/tmp" CAP="$CAP" \
    JOBS_URL=http://jobs.invalid HARNESS_SECRET=tok-fixture-jobs JOBS_RETRY_SLEEP=0 JOBS_SETTINGS_CACHE_S=0 \
    FLY_BIN_DIR="$T/nofly" FLY_SYSTEM_DIRS= "$@" \
    bash "$VERB" "${args[@]}" > "$CAP/out" 2> "$CAP/err"
  RC=$?; OUT=$(cat "$CAP/out"); ERR=$(cat "$CAP/err")
}
n_of() { grep -c -- "$1" "$2" 2>/dev/null; }
tmp_clean() { [ -z "$(find "$T/tmp" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; }
rowf() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$CAP/rows.json"; }

# ══ S-A1 set stages into every manifest app; the value goes nowhere else ═════
reset
seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\",\"lane-run-mk\"]")]"
run 'fixture-val-1' set "$P" QA_CLERK_SECRET_KEY
[ "$RC" = 0 ] && ok || bad "S-A1: rc 0, got $RC: $ERR"
grep -qxF "$POOL HBUNDLE_P_QA_CLERK_SECRET_KEY=fixture-val-1" "$CAP/fly.stdin" 2>/dev/null && ok || bad "S-A1: the pool app gets HBUNDLE_P_<NAME>: $(cat "$CAP/fly.stdin" 2>/dev/null | cut -d= -f1)"
grep -qxF "lane-run-mk QA_CLERK_SECRET_KEY=fixture-val-1" "$CAP/fly.stdin" 2>/dev/null && ok || bad "S-A1: another app gets the plain <NAME>"
[ "$(n_of 'secrets import --stage' "$CAP/fly.argv")" = 2 ] && ok || bad "S-A1: exactly 2 import --stage calls: $(cat "$CAP/fly.argv")"
grep -q "secrets import --stage -a $POOL\$" "$CAP/fly.argv" && grep -q 'secrets import --stage -a lane-run-mk$' "$CAP/fly.argv" && ok || bad "S-A1: one import per app"
LEAK=$(grep -rl 'fixture-val-1' "$T" 2>/dev/null | sort)
[ "$LEAK" = "$CAP/fly.stdin" ] && ok || bad "S-A1: only the fly stdin sink may hold the value, found in: $LEAK"
[ "$(grep -c . "$CAP/put.log")" = 2 ] && ok || bad "S-A1: two PUTs (intent, stamp): $(cat "$CAP/put.log")"
jq -e 'has("stamp") | not' >/dev/null 2>&1 <<<"$(sed -n 1p "$CAP/put.log")" && ok || bad "S-A1: the first PUT carries no stamp"
jq -e --arg a "$POOL" '.stamp == true and .digest[$a] == "dg-fixture-HBUNDLE_P_QA_CLERK_SECRET_KEY" and .digest["lane-run-mk"] == "dg-fixture-QA_CLERK_SECRET_KEY"' >/dev/null 2>&1 <<<"$(sed -n 2p "$CAP/put.log")" \
  && ok || bad "S-A1: the stamp PUT has stamp:true and the digest map: $(sed -n 2p "$CAP/put.log")"
EV=$(grep -E '^(curl PUT|fly import)' "$CAP/events" | tr '\n' '|')
[ "$EV" = "curl PUT /api/project-secrets/names|fly import $POOL|fly import lane-run-mk|curl PUT /api/project-secrets/names|" ] && ok || bad "S-A1: order PUT, imports, stamp PUT: $EV"
grep -qx "project-secrets/$P: QA_CLERK_SECRET_KEY staged on 2 app(s): $POOL,lane-run-mk" <<<"$OUT" && ok || bad "S-A1: the staged line: $OUT"
[ "$(rowf QA_CLERK_SECRET_KEY | jq -r .set_at)" != null ] && ok || bad "S-A1: the row is stamped"
[ ! -s "$CAP/alerts.txt" ] && ok || bad "S-A1: a good set alerts nothing"
tmp_clean && ok || bad "S-X6: the temp dir is removed after set"

# ══ S-A2 verify ══════════════════════════════════════════════════════════════
va_seed() {
  reset
  seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\",\"lane-run-mk\"]" required '"2026-10-25T00:00:00Z"'),$(rowj OPT_X "[\"$POOL\"]" optional '"2026-10-25T00:00:00Z"')]"
}
va_seed; flyhas "$POOL" HBUNDLE_P_QA_CLERK_SECRET_KEY HBUNDLE_P_OPT_X; flyhas lane-run-mk HBUNDLE_P_QA_CLERK_SECRET_KEY
run '' verify "$P"
[ "$RC" = 1 ] && ok || bad "S-A2: a missing required name is rc 1, got $RC"
grep -qx 'MISSING lane-run-mk QA_CLERK_SECRET_KEY' <<<"$OUT" && ok || bad "S-A2: names the app and the staged name (the plain name off the pool app): $OUT"
grep -q "MISSING $POOL" <<<"$OUT" && bad "S-A2: the pool app is complete" || ok
grep -q 'verify/.*: ok' <<<"$OUT" && bad "S-A2: no ok line on rc 1" || ok
[ "$(n_of 'secrets list' "$CAP/fly.argv")" = 2 ] && ok || bad "S-A2: one list per distinct app: $(cat "$CAP/fly.argv")"
va_seed; flyhas "$POOL" HBUNDLE_P_QA_CLERK_SECRET_KEY HBUNDLE_P_OPT_X; flyhas lane-run-mk QA_CLERK_SECRET_KEY
run '' verify "$P"
[ "$RC" = 0 ] && grep -qx "verify/$P: ok (2 names, 2 apps)" <<<"$OUT" && ok || bad "S-A2: all present is rc 0 and ok: rc $RC $OUT $ERR"
va_seed; flyhas "$POOL" HBUNDLE_P_QA_CLERK_SECRET_KEY; flyhas lane-run-mk QA_CLERK_SECRET_KEY
run '' verify "$P"
[ "$RC" = 0 ] && grep -qx "OPTIONAL-MISSING $POOL HBUNDLE_P_OPT_X" <<<"$OUT" && grep -q "verify/$P: ok" <<<"$OUT" && ok || bad "S-A2: an optional name missing is rc 0 with OPTIONAL-MISSING: rc $RC $OUT"
va_seed; flyhas "$POOL" HBUNDLE_P_QA_CLERK_SECRET_KEY HBUNDLE_P_OPT_X
run '' verify "$P" -- LIST_FAIL_APP=lane-run-mk
[ "$RC" = 1 ] && grep -qx 'UNKNOWN lane-run-mk' <<<"$OUT" && ok || bad "S-A2: a failed list is UNKNOWN rc 1: rc $RC $OUT"
grep -q 'MISSING lane-run-mk' <<<"$OUT" && bad "S-A2: an unread app is UNKNOWN, never MISSING" || ok
va_seed
run '' verify "$P" -- TRUNC=true
[ "$RC" = 1 ] && grep -q '^INCOMPLETE' <<<"$OUT" && [ ! -s "$CAP/fly.argv" ] && ok || bad "S-A2: truncated is INCOMPLETE rc 1, no fly call: rc $RC $OUT"
reset
run '' verify "$P"
[ "$RC" = 1 ] && grep -q "no manifest rows for $P" <<<"$OUT$ERR" && ok || bad "S-A2: no rows is rc 1: rc $RC $OUT"
tmp_clean && ok || bad "S-X6: the temp dir is removed after verify"

# ══ S-A4 a single quote is refused with the key name only ═══════════════════
reset
run "it's" set "$P" QA_CLERK_SECRET_KEY
[ "$RC" = 1 ] && ok || bad "S-A4: rc 1, got $RC"
grep -q 'QA_CLERK_SECRET_KEY' <<<"$ERR" && grep -q 'single quote' <<<"$ERR" && ok || bad "S-A4: stderr names the key: $ERR"
grep -q "it's\|'s" <<<"$OUT$ERR" && bad "S-A4: the value is never printed" || ok
[ ! -s "$CAP/fly.argv" ] && [ ! -s "$CAP/put.log" ] && ok || bad "S-A4: 0 fly calls, 0 PUT"

# ══ S-R1 the NAME rule ═══════════════════════════════════════════════════════
for n in QA_CLERK_SECRET_KEY _X FLYWHEEL_KEY GH_TOKENS GH_TOKEN_X "$(printf 'A%.0s' $(seq 1 128))"; do
  reset; run 'fixture-v' set "$P" "$n"
  [ "$RC" = 0 ] && grep -qxF "$POOL HBUNDLE_P_$n=fixture-v" "$CAP/fly.stdin" 2>/dev/null && ok || bad "S-R1: accept ${n:0:24}: rc $RC $ERR"
done
for n in qa_clerk 1ABC HBUNDLE_P_X SEED_A FLY_API_TOKEN GH_TOKEN GH_TOKEN_INSTALLATION_ID '' A-B "$(printf 'A%.0s' $(seq 1 129))"; do
  reset; run 'fixture-v' set "$P" "$n"
  [ "$RC" = 2 ] && [ ! -s "$CAP/fly.argv" ] && [ ! -s "$CAP/curl.argv" ] && ok || bad "S-R1: refuse '${n:0:24}' rc 2 with 0 calls: rc $RC"
done
reset; run 'fixture-v' set "$P" X --need sometimes
[ "$RC" = 2 ] && [ ! -s "$CAP/curl.argv" ] && ok || bad "S-R1: a bad --need is rc 2"
reset; run 'fixture-v' set "$P" X --apps 'Bad_App!'
[ "$RC" = 2 ] && [ ! -s "$CAP/curl.argv" ] && ok || bad "S-R1: a bad --apps is rc 2"
reset; run 'fixture-v' set 'Bad/Proj' X
[ "$RC" = 2 ] && ok || bad "S-R1: a bad project is rc 2"
reset; run '' frobnicate "$P"
[ "$RC" = 2 ] && ok || bad "S-R1: an unknown verb is rc 2"

# ══ S-R4 the value rule and dotenv quoting ═══════════════════════════════════
reset; run '' set "$P" X
[ "$RC" = 1 ] && grep -q 'X' <<<"$ERR" && [ ! -s "$CAP/fly.argv" ] && [ ! -s "$CAP/put.log" ] && ok || bad "S-R4: an empty value is refused: rc $RC"
reset; run "$(printf 'fixture-a\nfixture-b')" set "$P" X
[ "$RC" = 1 ] && [ ! -s "$CAP/fly.argv" ] && [ ! -s "$CAP/put.log" ] && ok || bad "S-R4: a two-line value is refused: rc $RC"
grep -q 'fixture-a\|fixture-b' <<<"$OUT$ERR" && bad "S-R4: a refused value is never printed" || ok
reset; run 'fixture a b#c$d"e' set "$P" X
[ "$RC" = 0 ] && grep -qxF "$POOL HBUNDLE_P_X='fixture a b#c\$d\"e'" "$CAP/fly.stdin" && ok || bad "S-R4: a value outside the plain set is single-quoted: $(cat "$CAP/fly.stdin" 2>/dev/null)"
reset; run '=x=' set "$P" X
[ "$RC" = 0 ] && grep -qxF "$POOL HBUNDLE_P_X==x=" "$CAP/fly.stdin" && ok || bad "S-R4: a plain value is written as is"
reset; run "$(printf 'fixture-nl\n')"$'\n' set "$P" X
[ "$RC" = 0 ] && grep -qxF "$POOL HBUNDLE_P_X=fixture-nl" "$CAP/fly.stdin" && ok || bad "S-R4: one line with its newline is accepted: rc $RC $ERR"

# ══ S-X exit paths ═══════════════════════════════════════════════════════════
reset; seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\",\"lane-run-mk\"]")]"
run 'fixture-val-2' set "$P" QA_CLERK_SECRET_KEY -- PUT_FAIL=1
[ "$RC" = 1 ] && [ ! -s "$CAP/fly.argv" ] && ok || bad "S-X1: a failed first PUT is rc 1 with 0 fly calls: rc $RC $(cat "$CAP/fly.argv")"
[ "$(grep -c . "$CAP/alerts.txt")" = 1 ] && ok || bad "S-X1: one alert"

reset; seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\",\"lane-run-mk\"]")]"
run 'fixture-val-3' set "$P" QA_CLERK_SECRET_KEY -- IMPORT_FAIL_APP=lane-run-mk
[ "$RC" = 1 ] && ok || bad "S-X2: a failed import on app 2 is rc 1, got $RC"
[ "$(n_of 'secrets import --stage' "$CAP/fly.argv")" = 2 ] && ok || bad "S-X2: app 1 was staged, app 2 tried"
[ "$(grep -c . "$CAP/put.log")" = 1 ] && ok || bad "S-X2: no stamp PUT: $(cat "$CAP/put.log")"
[ "$(rowf QA_CLERK_SECRET_KEY | jq -r .set_at)" = null ] && ok || bad "S-X2: set_at unchanged"
[ "$(grep -c . "$CAP/alerts.txt")" = 1 ] && grep -q 'lane-run-mk' "$CAP/alerts.txt" && grep -q 'QA_CLERK_SECRET_KEY' "$CAP/alerts.txt" \
  && ok || bad "S-X4: exactly one alert naming the app and the NAME: $(cat "$CAP/alerts.txt")"
grep -q 'fixture-val-3' "$CAP/alerts.txt" "$CAP/out" "$CAP/err" && bad "S-X4: no value in the alert or output" || ok
grep -q 'staged on' <<<"$OUT" && bad "S-X2: no staged line on a failure" || ok

reset; seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\"]")]"
run 'fixture-val-4' set "$P" QA_CLERK_SECRET_KEY -- PUT_FAIL_STAMP=1
[ "$RC" = 1 ] && [ "$(rowf QA_CLERK_SECRET_KEY | jq -r .set_at)" = null ] && ok || bad "S-X3: a failed stamp PUT is rc 1 and leaves the row pending: rc $RC"
grep -q 'staged on' <<<"$OUT" && bad "S-X3: no staged line when the stamp failed" || ok

reset; seed "[$(rowj QA_CLERK_SECRET_KEY "[\"$POOL\"]")]"
run 'fixture-val-5' set "$P" QA_CLERK_SECRET_KEY -- IMPORT_NOLIST=1
[ "$RC" = 1 ] && [ "$(grep -c . "$CAP/put.log")" = 1 ] && ok || bad "S-X7: an app that does not list the name after the import is rc 1, no stamp: rc $RC"

reset; seed "[$(rowj X "[\"$POOL\",\"lane-run-mk\"]" required '"2026-10-25T00:00:00Z"')]"; flyhas "$POOL" HBUNDLE_P_X; flyhas lane-run-mk X
run '' unset "$P" X -- UNSET_FAIL_APP=lane-run-mk
[ "$RC" = 1 ] && [ ! -s "$CAP/del.log" ] && [ -n "$(rowf X)" ] && ok || bad "S-X5: a failed fly unset keeps the row (no DELETE): rc $RC"

reset; mv "$H/env/fly.env" "$T/fly.env.off"
run 'fixture-val-6' set "$P" X
[ "$RC" = 1 ] && [ ! -s "$CAP/fly.argv" ] && [ ! -s "$CAP/curl.argv" ] && ok || bad "S-X6: no Fly token is rc 1 before any call: rc $RC"
mv "$T/fly.env.off" "$H/env/fly.env"
tmp_clean && ok || bad "S-X6: no temp dir survives the exit paths: $(ls "$T/tmp")"

# ══ S-U unset ════════════════════════════════════════════════════════════════
reset; seed "[$(rowj X "[\"$POOL\",\"lane-run-mk\"]" required '"2026-10-25T00:00:00Z"')]"
flyhas "$POOL" HBUNDLE_P_X HBUNDLE_P_XY; flyhas lane-run-mk X XY; flyhas other-app X
run '' unset "$P" X
[ "$RC" = 0 ] && ok || bad "S-U1: rc 0, got $RC: $ERR"
grep -qx "fly secrets unset --stage -a $POOL HBUNDLE_P_X" "$CAP/fly.argv" && grep -qx 'fly secrets unset --stage -a lane-run-mk X' "$CAP/fly.argv" \
  && ok || bad "S-U1: one unset per app with the staged name: $(cat "$CAP/fly.argv")"
[ "$(n_of 'secrets unset' "$CAP/fly.argv")" = 2 ] && ok || bad "S-U2: no other unset call"
grep -q 'XY\|other-app' <<<"$(grep 'secrets unset' "$CAP/fly.argv")" && bad "S-U2: the unset argv holds no other name or app" || ok
[ "$(grep -c . "$CAP/del.log")" = 1 ] && grep -q 'name=X' "$CAP/del.log" && [ -z "$(rowf X)" ] && ok || bad "S-U1: then one DELETE: $(cat "$CAP/del.log")"
grep -qx 'HBUNDLE_P_XY' "$CAP/flystate/$POOL" && grep -qx X "$CAP/flystate/other-app" && ok || bad "S-U2: other names and apps keep their secrets"
reset; seed "[$(rowj X "[\"$POOL\",\"lane-run-mk\"]")]"
run '' unset "$P" X -- UNSET_NOTFOUND_APP=lane-run-mk
[ "$RC" = 0 ] && [ "$(grep -c . "$CAP/del.log")" = 1 ] && ok || bad "S-U1: a 'not found' unset counts as done: rc $RC $ERR"
reset
run '' unset "$P" X
[ "$RC" = 1 ] && grep -q 'no manifest row' <<<"$ERR" && [ ! -s "$CAP/fly.argv" ] && ok || bad "S-U1: no row is rc 1 with 0 fly calls: rc $RC $ERR"

# ══ S-L1 list ════════════════════════════════════════════════════════════════
reset
seed "[$(rowj BETA "[\"$POOL\"]"),{\"project\":\"$P\",\"name\":\"ALPHA\",\"apps\":[\"$POOL\",\"lane-run-mk\"],\"need\":\"optional\",\"set_at\":\"2026-10-25T01:00:00Z\",\"set_by\":\"fixture-op\",\"digest\":{\"$POOL\":\"dg-fixture-secretish\"}},$(rowj OTHER "[\"x\"]" | sed 's/"project-6-os"/"other-proj"/')]"
run '' list "$P"
[ "$RC" = 0 ] && ok || bad "S-L1: rc 0, got $RC: $ERR"
[ "$(sed -n 1p <<<"$OUT")" = "$(printf 'name\tapps\tneed\tset_at\tset_by')" ] && ok || bad "S-L1: the TSV header: $(sed -n 1p <<<"$OUT")"
grep -qxF "$(printf 'ALPHA\t%s,lane-run-mk\toptional\t2026-10-25T01:00:00Z\tfixture-op' "$POOL")" <<<"$OUT" && ok || bad "S-L1: a stamped row: $OUT"
grep -qxF "$(printf 'BETA\t%s\trequired\t-\tfixture-op' "$POOL")" <<<"$OUT" && ok || bad "S-L1: a pending row shows - for set_at"
grep -qx 'pending=1' <<<"$OUT" && grep -qx 'truncated=false' <<<"$OUT" && ok || bad "S-L1: pending= and truncated="
grep -q 'OTHER\|dg-fixture' <<<"$OUT" && bad "S-L1: no other project's row, no digest" || ok
[ ! -s "$CAP/fly.argv" ] && ok || bad "S-L1: list makes no fly call"

# ══ S-I1 import ══════════════════════════════════════════════════════════════
reset; seed "[$(rowj MK_API_BASE "[\"$POOL\"]")]"
flyhas "$POOL" HBUNDLE_P_BOARD_TOKEN HBUNDLE_P_bad-name HBUNDLE_G_X HBUNDLE_SYNCED_AT
run '' import "$P"
[ "$RC" = 0 ] && grep -qx 'imported=1 kept=0 skipped=1' <<<"$OUT" && ok || bad "S-I1: imported=1 kept=0 skipped=1: rc $RC $OUT $ERR"
[ "$(grep -c . "$CAP/put.log")" = 1 ] && jq -e --arg a "$POOL" '.name == "BOARD_TOKEN" and .apps == [$a] and .need == "required" and .set_by == "import" and .stamp == true and .digest[$a] == "dg-fixture-HBUNDLE_P_BOARD_TOKEN"' "$CAP/put.log" >/dev/null \
  && ok || bad "S-I1: one PUT for BOARD_TOKEN: $(cat "$CAP/put.log")"
grep -q 'secrets import\|secrets unset' "$CAP/fly.argv" && bad "S-I1: import reads names only, writes no secret" || ok
reset; seed "[$(rowj MK_API_BASE "[\"$POOL\",\"lane-run-mk\"]")]"
flyhas "$POOL" HBUNDLE_P_BOARD_TOKEN HBUNDLE_P_MK_API_BASE HBUNDLE_P_bad-name
run '' import "$P"
[ "$RC" = 0 ] && grep -qx 'imported=1 kept=1 skipped=1' <<<"$OUT" && [ "$(rowf MK_API_BASE | jq -c .apps)" = "[\"$POOL\",\"lane-run-mk\"]" ] \
  && ok || bad "S-I1: an existing row is kept as it is: rc $RC $OUT"

# ══ S-Q1 a first set creates the row on the pool app, need required ══════════
reset
run 'fixture-user-1' set "$P" QA_TEST_USER_ID
jq -e --arg a "$POOL" '.name == "QA_TEST_USER_ID" and .apps == [$a] and .need == "required"' <<<"$(sed -n 1p "$CAP/put.log")" >/dev/null 2>&1 \
  && [ "$RC" = 0 ] && [ "$(rowf QA_TEST_USER_ID | jq -r .set_at)" != null ] && ok || bad "S-Q1: the row is created on the pool app, required: rc $RC $(cat "$CAP/put.log")"
reset
run 'fixture-v' set "$P" NEW_X --apps "$POOL,lane-run-mk" --need optional
jq -e --arg a "$POOL" '.apps == [$a, "lane-run-mk"] and .need == "optional"' <<<"$(sed -n 1p "$CAP/put.log")" >/dev/null 2>&1 && [ "$RC" = 0 ] \
  && ok || bad "S-Q1: --apps and --need set a new row: $(cat "$CAP/put.log")"

# ══ S-K1 the Fly timeout knob ════════════════════════════════════════════════
reset; run 'fixture-v' set "$P" X -- SETTINGS_FAIL=1
[ "$RC" = 0 ] && grep -qx 'timeout 120' "$CAP/timeout.log" && ok || bad "S-K1: a failed row read uses the fallback 120: $(cat "$CAP/timeout.log" 2>/dev/null)"
reset; run 'fixture-v' set "$P" X -- TIMEOUT_ROW=45
grep -qx 'timeout 45' "$CAP/timeout.log" && ! grep -qx 'timeout 120' "$CAP/timeout.log" && ok || bad "S-K1: the row value is the timeout: $(cat "$CAP/timeout.log" 2>/dev/null)"
reset; run 'fixture-v' set "$P" X -- TIMEOUT_ROW=bogus
grep -qx 'timeout 120' "$CAP/timeout.log" && ok || bad "S-K1: a bad row value uses the fallback"

# ══ S-RT the staged line round-trips through fly/entrypoint.sh ═══════════════
BLOCK=$(sed -n '/^if \[ -n "\${HBUNDLE_SYNCED_AT:-}" \]; then$/,/^fi$/p' "$DIR/fly/entrypoint.sh")
grep -q 'HBUNDLE_P_?\*)' <<<"$BLOCK" && ok || bad "S-RT: the compose arm was not found in fly/entrypoint.sh"
for v in 'fixture-plain-1' 'fixture a b#c$d"e'; do
  reset; run "$v" set "$P" QA_CLERK_SECRET_KEY
  line=$(sed -n "s/^$POOL //p" "$CAP/fly.stdin")
  val="${line#*=}"
  # dotenv as `fly secrets import` reads it: a single-quoted value is literal.
  case "$val" in \'*\') val="${val:1:${#val}-2}" ;; esac
  scratch_rm "$T/rt"; mkdir -p "$T/rt"
  env -i PATH="$TOOLS" ENV_DIR="$T/rt" PROJECT="$P" HBUNDLE_SYNCED_AT=2026-10-25T00:00:00Z "${line%%=*}=$val" \
    bash -c "log() { :; }; $BLOCK" 2>/dev/null
  grep -qxF "QA_CLERK_SECRET_KEY=$v" "$T/rt/$P.env" 2>/dev/null && ok || bad "S-RT: the composed env holds the value verbatim for '${v:0:12}'"
done
scratch_rm "$T/rt"

# ══ S-B1 budget: 0 real network calls ═══════════════════════════════════════
for c in curl ssh fly flyctl gh wget nc; do
  w=$(env -i PATH="$STUB:$TOOLS" bash -c "command -v $c" 2>/dev/null)
  case "$w" in ''|"$T"/*) ok ;; *) bad "S-B1: $c resolves outside the scratch dir: $w" ;; esac
done
[ ! -s "$T/net.calls" ] && ok || bad "S-B1: 0 ssh and gh calls: $(cat "$T/net.calls")"
reset; run '' list "$P"
grep -q . <<<"$(grep -v 'http://jobs.invalid' "$CAP/curl.argv")" && bad "S-B1: every curl call goes to http://jobs.invalid" || ok

# ══ S-W the worker half: sources, bearer-gated routes, node suites ═══════════
for f in "$DIR/worker/jobs/src/routes/project-secrets.js" \
         "$DIR/worker/jobs/schema.d/202610260157-bh-8317-project-secret-names.sql" \
         "$DIR/worker/jobs/test/route-table.d/bh-8317-project-secrets.txt" \
         "$DIR/worker/jobs/test/project-secrets.bh-8317.test.js" \
         "$DIR/worker/jobs/test/project-secrets-explain.bh-8317.test.js"; do
  [ -f "$f" ] && ok || bad "S-W: missing ${f#"$DIR/"}"
done
if ! command -v node >/dev/null 2>&1; then
  echo "project-secrets: node suites SKIPPED — node is not installed on this box"
else
  . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
  worker_catalogs "$DIR" || exit 1
  ROUTED=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { ROUTES, OPEN_ROUTES } from './src/index.js';
import { matchRoute } from './src/lib/router.js';
const q = [['GET', '/api/project-secrets/names'], ['PUT', '/api/project-secrets/names'], ['DELETE', '/api/project-secrets/names']];
console.log(q.map(([m, p]) => (matchRoute(ROUTES, m, p) ? 'bearer' : 'none') + '/' + (matchRoute(OPEN_ROUTES, m, p) ? 'open' : 'closed')).join(' '));" 2>&1)
  [ "$ROUTED" = 'bearer/closed bearer/closed bearer/closed' ] && ok || bad "S-W: the three routes are in ROUTES, not OPEN_ROUTES: $ROUTED"
  # A skipped test gates nothing.
  WOUT=$(cd "$DIR/worker/jobs" && node --test test/project-secrets.bh-8317.test.js test/project-secrets-explain.bh-8317.test.js 2>&1); WRC=$?
  WSKIP=$(sed -n 's/^# skipped \([0-9][0-9]*\)$/\1/p' <<<"$WOUT" | tail -1)
  if [ "$WRC" -eq 0 ] && [ "$WSKIP" = 0 ]; then ok
  else bad "S-W: the worker suites failed (rc=$WRC, skipped=$WSKIP)"; grep -E '^not ok|^# (pass|fail|skip)|expected|actual' <<<"$WOUT" | head -30; fi
fi

echo "project-secrets (BH-8317): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
