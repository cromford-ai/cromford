#!/bin/bash
# tests/run-decompose-fresh-token-test.sh — the child filer mints a token that is
# alive NOW (2026-09-15 20:34Z: BH-390..BH-403).
#
# The lane inherits GH_TOKEN from build start. That is a GitHub App installation
# token with a one-hour life; planning a 12-file-cap split takes longer than
# that, and on a watcher box nothing refreshes it (gh-token-live.sh only knows
# pool machines). So `gh issue create` on child 1 answered "Try authenticating
# with: gh auth login" and eight resilience tickets parked DECOMPOSE_FAILED.
# run-decompose.sh must mint a fresh token through bin/gh-token.sh right before
# it files, and fall back to the old path only when no minter exists.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
CONF
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# the minter every box has: answers with a token that is alive now
printf '#!/bin/bash\necho ghs_fresh_%s\n' '$1' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"
# gh stub: records the token each call ran with, answers `issue create` with a URL
# BH-8962: the create is a REST POST, answered from the issue create arm, which
# runs in the POST's own environment and so logs the token the POST ran with.
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$1 $2 token=${GH_TOKEN:-<unset>}" >> "$GH_CALLS"
. "${GH_CLI_REST_ADAPTER:?}" || exit 1
gh_cli_rest_create "$0" "$@" && exit 0
case "$1 $2" in
  "issue create") n=$(( $(grep -c '^issue create' "$GH_CALLS") )); echo "https://github.com/example-org/scoutish/issues/$((900+n))" ;;
  "issue comment"|"issue edit"|"issue view") echo '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow, readMetrics()","after":[],"body":"Create the table.\n\nFiles: src/db/metrics.ts\nTests: tests/metrics.test.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile.\n\nFiles: src/app/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
rm -rf "$T/b"; mkdir -p "$T/b"; printf '%s\n' "$SPEC" > "$T/b/children.json"
printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
: > "$T/gh.calls"
# the stale minute-0 token is what the lane inherited
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_CALLS="$T/gh.calls" GH_TOKEN=ghs_fixture_stale_minute0 \
         PATH="$T/fakebin:$PATH" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a filing run must exit 0 (rc=$RC): $(tail -3 <<<"$OUT")"
CREATES=$(grep -c '^issue create' "$T/gh.calls")
[ "$CREATES" -eq 2 ] && ok || bad "two children = two issue create calls (got $CREATES)"
grep -q '^issue create token=ghs_fresh_example-org/scoutish' "$T/gh.calls" \
  && ok || bad "issue create must run with the freshly minted token, got: $(grep '^issue create' "$T/gh.calls" | head -1)"
grep -q '^issue create token=ghs_fixture_stale_minute0' "$T/gh.calls" \
  && bad "issue create ran with the stale inherited token" || ok

# no minter on this tree -> the old path (gh_repo_use_token / inherited env) still works
rm -f "$T/h/bin/gh-token.sh"; : > "$T/gh.calls"; rm -rf "$T/b"; mkdir -p "$T/b"; printf '%s\n' "$SPEC" > "$T/b/children.json"
printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_CALLS="$T/gh.calls" GH_TOKEN=ghs_only_one \
         PATH="$T/fakebin:$PATH" "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "without a minter the run must still exit 0 (rc=$RC)"
grep -q '^issue create token=ghs_only_one' "$T/gh.calls" && ok || bad "without a minter the inherited token is used: $(grep '^issue create' "$T/gh.calls" | head -1)"

echo "run-decompose-fresh-token: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
