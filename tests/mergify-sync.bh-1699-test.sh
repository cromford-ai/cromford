#!/bin/bash
# tests/mergify-sync.bh-1699-test.sh — bin/mergify-sync.sh (BH-1699, BH-1673.2).
#
# The REAL script runs against a HARNESS=$T/h sandbox holding its own
# config/mergify/repos/*.conf. `gh` is a stub first on PATH: it answers the
# gh_repo_use_token probe from $T/fx/visible, logs every `METHOD path` (and any
# --input body) to $T/gh.log, and replies from $T/fx/<METHOD>_<path> fixtures
# (.code/.body/.rc; no fixture is a 404). The comparator is a stub through
# MERGIFY_TEMPLATE_BIN that really compares the DECODED live file with
# $T/fx/render.out, so IN_SYNC here proves the decode too. S8c also runs the
# production bin/mergify-template.sh, which BH-1698 made a real comparator:
# IN_SYNC against its own render, DRIFT against a drifted file, and
# cannot-compare only where python3 has no PyYAML.
#
# D1 MUTATION (run by the builder, not by CI): point MERGIFY_SYNC_BIN at a copy
# of bin/mergify-sync.sh (with its bin/lib beside it) whose non-2xx branch sets
# IN_SYNC, and S8 goes red.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
SUT="${MERGIFY_SYNC_BIN:-$DIR/bin/mergify-sync.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
DEFB=trunk
TODAY=$(date -u +%Y%m%d)

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
FX="$STUB_FX"
if [ "${1:-}" = api ] && [ "${2:-}" != -i ]; then   # gh_repo_use_token's probe
  grep -qxF "${2#repos/}" "$FX/visible" 2>/dev/null && { echo 1; exit 0; }
  exit 1
fi
m="$4"; p="$5"; shift 5
inp=""
while [ $# -gt 0 ]; do [ "$1" = --input ] && inp="$2"; shift; done
echo "$m $p" >> "$STUB_LOG"
[ -n "$inp" ] && { printf 'INPUT '; tr -d '\n' < "$inp"; echo; } >> "$STUB_LOG"
k="$FX/${m}_$(printf '%s' "$p" | tr -c 'A-Za-z0-9' '_')"
if [ -f "$k.rc" ] && [ ! -f "$k.body" ]; then exit "$(cat "$k.rc")"; fi
if [ -f "$k.body" ]; then
  printf 'HTTP/2.0 %s X\r\n\r\n' "$(cat "$k.code")"; cat "$k.body"; echo
else
  printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'
fi
exit "$(cat "$k.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/tpl" <<'EOF'
#!/bin/bash
FX="$STUB_FX"
case "$1" in
  marker)  r=$(sed -n 's/^# harness-mergify: override //p' "$2" | head -n 1)
           [ -n "$r" ] && { echo "$r"; exit 0; }; exit 1 ;;
  compare) [ -f "$FX/cmp.rc" ] && exit "$(cat "$FX/cmp.rc")"
           cmp -s "$FX/render.out" "$3" && exit 0
           diff -u "$FX/render.out" "$3"; exit 1 ;;
  render)  cat "$FX/render.out" ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/tpl"

key() { printf '%s/%s_%s' "$T/fx" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"; }
fx()  { local k; k=$(key "$1" "$2"); printf '%s' "$3" > "$k.code"; printf '%s' "$4" > "$k.body"; [ -n "${5:-}" ] && printf '%s' "$5" > "$k.rc"; return 0; }
unfx() { rm -f "$(key "$1" "$2")".*; }
live() { # live <slug> <yaml text>
  fx GET "repos/$1/contents/.mergify.yml?ref=$DEFB" 200 \
    "$(jq -nc --arg c "$(printf '%s' "$2" | base64)" '{sha:"blobmain",content:$c}')"
}
RENDER=$'queue_rules:\n  - name: default\n'
DRIFTED=$'queue_rules:\n  - name: other\n'
reset() {
  rm -rf "$T/h" "$T/fx"; mkdir -p "$T/h/config/mergify/repos" "$T/fx"
  printf '# a\nslug=example-org/a\ncheck=ci\n' > "$T/h/config/mergify/repos/a.conf"
  printf 'example-org/a\nexample-org/b\nexample-org/c\n' > "$T/fx/visible"
  printf '%s' "$RENDER" > "$T/fx/render.out"
  for s in a b c; do
    fx GET "repos/example-org/$s" 200 "{\"default_branch\":\"$DEFB\"}"
    live "example-org/$s" "$RENDER"
  done
  : > "$T/gh.log"
}
run() {
  : > "$T/gh.log"
  OUT=$(env HARNESS="$T/h" PATH="$T/bin:$PATH" GH_ETAG=0 MERGIFY_TEMPLATE_BIN="${TPLBIN:-$T/tpl}" \
        STUB_FX="$T/fx" STUB_LOG="$T/gh.log" bash "$SUT" "$@" 2>"$T/err"); RC=$?
  cat "$T/gh.log" >> "$T/gh.all"
}
writes() { grep -cE '^(POST|PUT|PATCH|DELETE) ' "$T/gh.log"; }
alerts() { if [ -f "$T/h/logs/ALERTS.log" ]; then grep -c . "$T/h/logs/ALERTS.log"; else echo 0; fi; }

# --- S1 in sync -------------------------------------------------------------
reset; run check
[ "$OUT" = "example-org/a IN_SYNC" ] && ok || bad "S1 stdout: $OUT ($(cat "$T/err"))"
[ "$RC" = 0 ] && ok || bad "S1 rc $RC"
[ "$(alerts)" = 0 ] && ok || bad "S1 alerts $(alerts)"
grep -q 'example-org/a IN_SYNC' "$T/h/logs/mergify-sync.log" 2>/dev/null && ok || bad "S1 log line"
grep -qxF "GET repos/example-org/a/contents/.mergify.yml?ref=$DEFB" "$T/gh.log" && ok || bad "S1 contents GET not on default branch"
run; [ "$OUT" = "example-org/a IN_SYNC" ] && [ "$RC" = 0 ] && ok || bad "S1 default mode: $OUT rc $RC"
run apply; [ "$OUT" = "example-org/a IN_SYNC" ] && [ "$RC" = 0 ] && [ "$(writes)" = 0 ] && ok || bad "S1 apply: $OUT rc $RC"

# --- S2 drift, one alert per repo per day -----------------------------------
reset; live example-org/a "$DRIFTED"; run check
[ "$OUT" = "example-org/a DRIFT" ] && ok || bad "S2 stdout: $OUT"
[ "$RC" = 1 ] && ok || bad "S2 rc $RC"
[ "$(alerts)" = 1 ] && ok || bad "S2 alerts $(alerts)"
grep -q 'bin/mergify-sync.sh apply example-org/a' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "S2 alert has no fix command"
grep -q 'name: other' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "S2 alert does not name the drift"
[ -e "$T/h/state/mergify-sync/example-org_a.$TODAY" ] && ok || bad "S2 no marker"
[ "$(writes)" = 0 ] && ok || bad "S2 check wrote"
run check; [ "$(alerts)" = 1 ] && [ "$OUT" = "example-org/a DRIFT" ] && ok || bad "S2 second run alerts $(alerts)"
# S2b: the append fails -> no marker
reset; live example-org/a "$DRIFTED"; mkdir -p "$T/h/logs/ALERTS.log"; run check
[ "$RC" = 1 ] && [ ! -e "$T/h/state/mergify-sync/example-org_a.$TODAY" ] && ok || bad "S2b marker written without an alert"

# --- S3 missing -------------------------------------------------------------
reset; unfx GET "repos/example-org/a/contents/.mergify.yml?ref=$DEFB"; run check
[ "$OUT" = "example-org/a MISSING" ] && [ "$RC" = 1 ] && ok || bad "S3 check: $OUT rc $RC"
grep -q 'docs/MERGIFY.md' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "S3 alert"
run apply
[ "$OUT" = "example-org/a MISSING" ] && [ "$RC" = 1 ] && ok || bad "S3 apply: $OUT rc $RC"
[ "$(writes)" = 0 ] && ok || bad "S3 apply wrote"

# --- S4 override ------------------------------------------------------------
reset; live example-org/a $'# harness-mergify: override hand-tuned\nqueue_rules: []\n'
run check; [ "$OUT" = "example-org/a OVERRIDE hand-tuned" ] && [ "$RC" = 0 ] && ok || bad "S4 check: $OUT rc $RC"
[ "$(alerts)" = 0 ] && ok || bad "S4 alerted"
run apply; [ "$OUT" = "example-org/a OVERRIDE hand-tuned" ] && [ "$RC" = 0 ] && [ "$(writes)" = 0 ] && ok || bad "S4 apply: $OUT rc $RC"
reset; echo 'override=legacy' >> "$T/h/config/mergify/repos/a.conf"; live example-org/a "$DRIFTED"
run apply; [ "$OUT" = "example-org/a OVERRIDE legacy" ] && [ "$RC" = 0 ] && ok || bad "S4b: $OUT rc $RC"
grep -q contents "$T/gh.log" && bad "S4b read the live file" || ok

# --- S5 apply on drift ------------------------------------------------------
SHA8=$(printf '%s' "$RENDER" | sha256sum | cut -c1-8)
BR="harness/mergify-sync-$SHA8"
apply_fx() {
  reset; live example-org/a "$DRIFTED"
  fx GET "repos/example-org/a/pulls?state=open&head=example-org:$BR" 200 '[]'
  fx GET "repos/example-org/a/git/ref/heads/$DEFB" 200 '{"object":{"sha":"headsha"}}'
  fx POST repos/example-org/a/git/refs 201 "{\"ref\":\"refs/heads/$BR\"}"
  fx GET "repos/example-org/a/contents/.mergify.yml?ref=$BR" 200 '{"sha":"blobbr","content":""}'
  fx PUT repos/example-org/a/contents/.mergify.yml 200 '{"content":{}}'
  fx POST repos/example-org/a/pulls 201 '{"number":7,"html_url":"https://github.com/example-org/a/pull/7"}'
}
apply_fx; run apply example-org/a
[ "$OUT" = "example-org/a PR_CREATED https://github.com/example-org/a/pull/7" ] && ok || bad "S5 stdout: $OUT ($(cat "$T/err"))"
[ "$RC" = 0 ] && ok || bad "S5 rc $RC"
ORDER=$(grep -E '^(POST|PUT|PATCH|DELETE) ' "$T/gh.log" | tr '\n' '|')
[ "$ORDER" = "POST repos/example-org/a/git/refs|PUT repos/example-org/a/contents/.mergify.yml|POST repos/example-org/a/pulls|" ] && ok || bad "S5 write order: $ORDER"
grep -A1 -xF 'POST repos/example-org/a/git/refs' "$T/gh.log" | grep -qF "\"ref\":\"refs/heads/$BR\"" && ok || bad "S5 ref name"
grep -A1 -xF 'POST repos/example-org/a/git/refs' "$T/gh.log" | grep -qF '"sha":"headsha"' && ok || bad "S5 ref not from the default head"
PUTIN=$(grep -A1 -xF 'PUT repos/example-org/a/contents/.mergify.yml' "$T/gh.log" | tail -n 1)
case "$PUTIN" in *"\"branch\":\"$BR\""*) ok ;; *) bad "S5 PUT branch: $PUTIN" ;; esac
case "$PUTIN" in *'"sha":"blobbr"'*) ok ;; *) bad "S5 PUT blob sha: $PUTIN" ;; esac
case "$PUTIN" in *"\"content\":\"$(printf '%s' "$RENDER" | base64 -w0)\""*) ok ;; *) bad "S5 PUT content: $PUTIN" ;; esac
PRIN=$(grep -A1 -xF 'POST repos/example-org/a/pulls' "$T/gh.log" | tail -n 1)
case "$PRIN" in *'"title":"Sync .mergify.yml from the harness template"'*) ok ;; *) bad "S5 PR title: $PRIN" ;; esac
case "$PRIN" in *max_parallel_checks*) ok ;; *) bad "S5 PR body lacks the runner note" ;; esac
case "$PRIN" in *"name: other"*) ok ;; *) bad "S5 PR body lacks the diff" ;; esac
case "$PRIN" in *"\"base\":\"$DEFB\""*"\"head\":\"$BR\""*|*"\"head\":\"$BR\""*"\"base\":\"$DEFB\""*) ok ;; *) bad "S5 PR head/base: $PRIN" ;; esac
[ "$(alerts)" = 0 ] && ok || bad "S5 apply alerted"
# S5b: the ref exists already (422) and reads back -> reuse
apply_fx; fx POST repos/example-org/a/git/refs 422 '{"message":"Reference already exists"}' 1
fx GET "repos/example-org/a/git/ref/heads/$BR" 200 '{"object":{"sha":"x"}}'
run apply; [ "$OUT" = "example-org/a PR_CREATED https://github.com/example-org/a/pull/7" ] && [ "$RC" = 0 ] && ok || bad "S5b: $OUT rc $RC"
# S5c: 422 and the ref does NOT read back -> fail, no PUT
unfx GET "repos/example-org/a/git/ref/heads/$BR"
run apply; [ "$OUT" = "example-org/a PR_FAILED ref 422" ] && [ "$RC" = 1 ] && ok || bad "S5c: $OUT rc $RC"
grep -q '^PUT ' "$T/gh.log" && bad "S5c PUT after a failed ref" || ok

# --- S6 an open PR already on the branch ------------------------------------
apply_fx; fx GET "repos/example-org/a/pulls?state=open&head=example-org:$BR" 200 '[{"html_url":"https://github.com/example-org/a/pull/3"}]'
run apply; [ "$OUT" = "example-org/a PR_OPEN https://github.com/example-org/a/pull/3" ] && [ "$RC" = 0 ] && ok || bad "S6: $OUT rc $RC"
[ "$(writes)" = 0 ] && ok || bad "S6 wrote"

# --- S7 create answered with no html_url ------------------------------------
apply_fx; fx POST repos/example-org/a/pulls 201 '{}'
run apply; case "$OUT" in "example-org/a PR_FAILED"*) ok ;; *) bad "S7: $OUT" ;; esac
[ "$RC" = 1 ] && ok || bad "S7 rc $RC"
case "$OUT" in *PR_CREATED*) bad "S7 printed PR_CREATED" ;; *) ok ;; esac

# --- S8 unreadable reads are never IN_SYNC ----------------------------------
C=".mergify.yml?ref=$DEFB"
reset; fx GET "repos/example-org/a/contents/$C" 403 '{"message":"API rate limit exceeded for user"}' 75
run check; [ "$OUT" = "example-org/a UNREADABLE rate-limited" ] && ok || bad "S8 stdout: $OUT"
[ "$RC" != 0 ] && ok || bad "S8 rc $RC"
case "$OUT" in *IN_SYNC*) bad "S8 IN_SYNC on a failed read" ;; *) ok ;; esac
grep -q 're-run bin/mergify-sync.sh check' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "S8 alert"
run apply; [ "$OUT" = "example-org/a UNREADABLE rate-limited" ] && [ "$(writes)" = 0 ] && ok || bad "S8 apply: $OUT"
# S8d: gh exits 75 and prints nothing
reset; unfx GET "repos/example-org/a/contents/$C"; printf 75 > "$(key GET "repos/example-org/a/contents/$C").rc"
run check; [ "$OUT" = "example-org/a UNREADABLE http 000 network" ] && [ "$RC" = 1 ] && ok || bad "S8d: $OUT rc $RC"
# S8e: a 2xx with an empty body, and content that will not decode
reset; fx GET "repos/example-org/a/contents/$C" 200 ''
run check; [ "$OUT" = "example-org/a UNREADABLE http 200 empty" ] && [ "$RC" = 1 ] && ok || bad "S8e empty: $OUT rc $RC"
reset; fx GET "repos/example-org/a/contents/$C" 200 '{"sha":"s","content":"!!!not base64!!!"}'
run check; [ "$OUT" = "example-org/a UNREADABLE undecodable" ] && [ "$RC" = 1 ] && ok || bad "S8e undecodable: $OUT rc $RC"
# S8b: no token can see the repo
reset; : > "$T/fx/visible"
run check; [ "$OUT" = "example-org/a UNREADABLE no token" ] && [ "$RC" = 1 ] && ok || bad "S8b: $OUT rc $RC"
grep -q contents "$T/gh.log" && bad "S8b read without a token" || ok
# S8c: the comparator cannot compare (stub rc 3), and rc 2
reset; echo 3 > "$T/fx/cmp.rc"
run check; [ "$OUT" = "example-org/a UNREADABLE cannot-compare" ] && [ "$RC" = 1 ] && ok || bad "S8c stub: $OUT rc $RC"
# ...and the PRODUCTION CLI end to end. Since BH-1698 it is a real comparator,
# so its contract here is the real one: the file it renders reads IN_SYNC (rc 0),
# a drifted file reads DRIFT (rc 1), and only a python3 with no PyYAML is
# cannot-compare (its rc 3), which must still surface as UNREADABLE, never IN_SYNC.
REALTPL="$DIR/bin/mergify-template.sh"
if python3 -c 'import yaml' 2>/dev/null; then
  reset; live example-org/a "$("$REALTPL" render "$T/h/config/mergify/repos/a.conf")"
  TPLBIN="$REALTPL" run check
  [ "$OUT" = "example-org/a IN_SYNC" ] && [ "$RC" = 0 ] && ok || bad "S8c real comparator, its own render: $OUT rc $RC"
  reset; live example-org/a "$DRIFTED"; TPLBIN="$REALTPL" run check
  [ "$OUT" = "example-org/a DRIFT" ] && [ "$RC" = 1 ] && ok || bad "S8c real comparator, a drifted file: $OUT rc $RC"
else
  echo "note: python3 has no PyYAML — S8c checks the real comparator's cannot-compare arm only"
  reset; TPLBIN="$REALTPL" run check
  [ "$OUT" = "example-org/a UNREADABLE cannot-compare" ] && [ "$RC" = 1 ] && ok || bad "S8c real comparator without PyYAML: $OUT rc $RC"
fi
reset; echo 2 > "$T/fx/cmp.rc"
run check; [ "$OUT" = "example-org/a UNREADABLE comparator rc 2" ] && [ "$RC" = 1 ] && ok || bad "S8c rc 2: $OUT rc $RC"
reset; live example-org/a "$DRIFTED"; echo 3 > "$T/fx/cmp.rc"
run apply; [ "$OUT" = "example-org/a UNREADABLE cannot-compare" ] && [ "$(writes)" = 0 ] && ok || bad "S8c apply: $OUT"

# --- S10 mixed registry, S11 unknown slug, S12 no confs ----------------------
reset; printf 'slug=example-org/c\n' > "$T/h/config/mergify/repos/c.conf"; live example-org/a "$DRIFTED"
run check
[ "$OUT" = $'example-org/a DRIFT\nexample-org/c IN_SYNC' ] && [ "$RC" = 1 ] && ok || bad "S10: $OUT rc $RC"
reset; run apply example-org/zzz
[ "$OUT" = "example-org/zzz UNREADABLE no conf" ] && [ "$RC" = 1 ] && ok || bad "S11: $OUT rc $RC"
[ -s "$T/gh.log" ] && bad "S11 made a request" || ok
reset; rm -f "$T/h/config/mergify/repos/"*.conf; run check
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$T/gh.log" ] && ok || bad "S12 no confs: $OUT rc $RC"
reset; run bogus; [ "$RC" = 2 ] && ok || bad "usage rc $RC"

# --- S9 across every case ----------------------------------------------------
grep -q '/merge' "$T/gh.all" && bad "S9 a merge call" || ok
grep -qE '^(PATCH|DELETE) ' "$T/gh.all" && bad "S9 a PATCH/DELETE" || ok
grep -qF "\"ref\":\"refs/heads/$DEFB\"" "$T/gh.all" && bad "S9 a ref write to the default branch" || ok
NPUT=$(grep -c '^PUT ' "$T/gh.all"); NPUTB=$(grep -A1 '^PUT ' "$T/gh.all" | grep -c '"branch":"harness/mergify-sync-')
[ "$NPUT" -gt 0 ] && [ "$NPUT" = "$NPUTB" ] && ok || bad "S9 PUTs $NPUT, on a harness branch $NPUTB"
grep -q 'example-org/b' "$T/gh.all" && bad "S9 a conf-less repo was requested" || ok

echo "mergify-sync.bh-1699: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
