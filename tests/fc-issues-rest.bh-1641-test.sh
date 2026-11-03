#!/bin/bash
# tests/fc-issues.bh-1641-test.sh — BH-1650: the issues lane reads and parks the parent over REST.
#
# Drives the real bin/run-decompose.sh (which sources bin/lib/fc-issues.sh).
# The gh stub answers `gh api -i` for the parent/child issue reads and the label
# DELETE itself, and delegates the comment POST to tests/lib/gh-rest-stub.sh.
#   HARNESS_TEST_SANDBOX=1 bash tests/fc-issues-rest.bh-1641-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -  9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"

cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics","after":[],"body":"Create the table and the read endpoint.\n\nFiles: src/db/metrics.ts, src/api/metrics.ts\nTests: tests/metrics.test.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile against the read API.\n\nFiles: src/app/dashboard/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly digest email","after":[],"body":"Send the digest.\n\nFiles: src/jobs/digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

export TITLE0='TK-552.0: contract — metrics table + read API'
export TITLE1='TK-552.1: dashboard tile'
export TITLE2='TK-552.2: weekly digest email'
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_CALLS"
. "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1  # BH-8962: the child create is a REST POST
gh_cli_rest_create "$0" "$@" && exit 0
_env() { printf 'HTTP/2.0 %s\r\n\r\n%s\n' "$1" "$2"; }
case "$*" in
  *"-i -X GET repos/example-org/scoutish/issues/552"*)
    _env "${ST_PARENT:-200}" "${PARENT_JSON:-{\"labels\":[]}}"; exit 0 ;;
  *"-i -X GET repos/example-org/scoutish/issues/"*)
    a="$*"; n="${a##*issues/}"; n="${n%% *}"
    case "$n" in 701) t="$TITLE0" ;; 702) t="$TITLE1" ;; 703) t="$TITLE2" ;; *) t=unknown ;; esac
    _env "${ST_TITLE:-200}" "$(jq -nc --arg t "$t" '{title:$t}')"; exit 0 ;;
  *"-i -X DELETE "*) _env "${ST_DELETE:-200}" '[]'; exit 0 ;;
  *"-i -X "*) GHT="$GHT"; . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub "$@"; exit 0 ;;
esac
case "$1 $2" in
  "issue create")
    TITLE=""
    while [ $# -gt 0 ]; do case "$1" in --title) TITLE="$2"; shift 2 ;; *) shift ;; esac; done
    case "$TITLE" in
      "$TITLE0") echo "https://github.com/example-org/scoutish/issues/701" ;;
      "$TITLE1") echo "https://github.com/example-org/scoutish/issues/702" ;;
      "$TITLE2") echo "https://github.com/example-org/scoutish/issues/703" ;;
    esac ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
mkdir -p "$T/ght"

_drive() {
  mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"; : > "$T/gh.calls"; : > "$T/b/pipeline.log"; : > "$T/b/decompose-run.txt"
  rm -f "$T/ght/"*
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" GH_CALLS="$T/gh.calls" \
      DIR="$DIR" GHT="$T/ght" GH_ETAG=0 PATH="$T/fakebin:$PATH" "$@" \
      "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}
_legacy() { grep -cE '^issue (comment|edit|view|list)' "$T/gh.calls"; }

# 1. parent answers 200 with labels: they are inherited, the parent is parked over REST
rm -f "$T/b/children.txt"
OUT=$(_drive PARENT_JSON='{"labels":[{"name":"ai-build"},{"name":"hotfix"}]}'); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1: rc=$RC: $OUT"
[ "$(grep -c '^issue create.*hotfix' "$T/gh.calls")" -eq 3 ] && ok || bad "1: hotfix must be inherited by all 3 children ($(grep '^issue create' "$T/gh.calls"))"
grep -q 'api -i -X POST repos/example-org/scoutish/issues/552/comments' "$T/gh.calls" && ok || bad "1: split comment must POST over REST"
grep -q 'api -i -X DELETE repos/example-org/scoutish/issues/552/labels/ai-build' "$T/gh.calls" && ok || bad "1: label must be DELETEd over REST"
[ "$(_legacy)" -eq 0 ] && ok || bad "1: no legacy gh issue comment/edit/view calls (got $(_legacy))"
grep -q '^gh api -X POST repos/example-org/scoutish/issues/552/comments' "$T/b/decompose-gh.log" && ok || bad "1: GHLOG must record the REST comment"
grep -q '^gh api -X DELETE repos/example-org/scoutish/issues/552/labels/ai-build$' "$T/b/decompose-gh.log" && ok || bad "1: GHLOG must record the REST DELETE"
grep -q 'unlabelled (master of split)' "$T/b/pipeline.log" && ok || bad "1: unlabel logged"
grep -q 'WARN.*label' "$T/b/pipeline.log" && bad "1: no WARN on a clean run: $(grep WARN "$T/b/pipeline.log")" || ok

# 2. parent read 403: nothing inherited
rm -f "$T/b/children.txt"
OUT=$(_drive ST_PARENT=403 PARENT_JSON='{"labels":[{"name":"hotfix"}]}'); RC=$?
[ "$RC" -eq 0 ] && ok || bad "2: rc=$RC"
grep -q '^issue create.*hotfix' "$T/gh.calls" && bad "2: a 403 label read must inherit nothing" || ok

# 2b. complete rerun, parent read 403: nothing removed
printf 'TK-701\nTS-702\nTS-703\n' > "$T/b/children.txt"
OUT=$(_drive ST_PARENT=403 PARENT_JSON='{"labels":[{"name":"ai-build"}]}'); RC=$?; echo "$OUT" >"$T/o2b"
[ "$RC" -eq 0 ] && ok || bad "2b: rc=$RC $(cat $T/b/decompose-run.txt) $(tail -3 $T/b/pipeline.log)"
grep -q -- '-X DELETE' "$T/gh.calls" && bad "2b: a failed read must remove nothing" || ok
# 2c. complete rerun, parent labelled: re-parked over REST
OUT=$(_drive PARENT_JSON='{"labels":[{"name":"ai-build"}]}')
[ "$(grep -c -- '-X DELETE .*labels/ai-build' "$T/gh.calls")" -eq 1 ] && ok || bad "2c: re-park must DELETE once"

# 3. title read 403 on resume: rc 1, FC_ERROR names HTTP 403, children.txt untouched
printf 'TK-701\n' > "$T/b/children.txt"; cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive ST_TITLE=403); RC=$?
[ "$RC" -ne 0 ] && ok || bad "3: a failed title read must fail the split"
grep -q 'issue read failed: HTTP 403' "$T/b/pipeline.log" "$T/b/decompose-run.txt" && ok || bad "3: FC_ERROR must name HTTP 403 ($(cat "$T/b/decompose-run.txt"))"
cmp -s "$T/b/children.txt" "$T/ref.txt" && ok || bad "3: children.txt must be byte-identical"
[ "$(grep -c '^issue create' "$T/gh.calls")" -eq 0 ] && ok || bad "3: nothing filed"
# 3b. matching title: reused, not re-created
OUT=$(_drive); RC=$?
[ "$RC" -eq 0 ] && ok || bad "3b: rc=$RC"
grep -q '^issue create.*TK-552.0' "$T/gh.calls" && bad "3b: child 0 must be reused" || ok
grep -q 'resumed from existing #701' "$T/b/pipeline.log" && ok || bad "3b: reuse logged"

# 4. DELETE 75 (500) -> WARN, rc 0; DELETE 404 -> success, no WARN
rm -f "$T/b/children.txt"
OUT=$(_drive ST_DELETE=500); RC=$?
[ "$RC" -eq 0 ] && ok || bad "4: rc must stay 0 on a failed DELETE ($RC)"
grep -q 'WARN: could not remove the ai-build label' "$T/b/pipeline.log" && ok || bad "4: failed DELETE must WARN"
rm -f "$T/b/children.txt"
OUT=$(_drive ST_DELETE=404); RC=$?
[ "$RC" -eq 0 ] && ok || bad "4b: rc=$RC"
grep -q 'WARN.*label' "$T/b/pipeline.log" && bad "4b: a 404 DELETE is success, not WARN" || ok
grep -q 'was not labelled ai-build' "$T/b/pipeline.log" && ok || bad "4b: 404 logged as not labelled"

echo "fc-issues-rest.bh-1641: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
