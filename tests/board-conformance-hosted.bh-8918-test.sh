#!/bin/bash
# tests/board-conformance-hosted.bh-8918-test.sh — BH-8918: the origin probe
# on a hosted board. bc_probe_origin takes an optional 5th arg, the board
# prefix. Under /api/hosted-board/ the jobs worker serves the board and has no
# app internals, so internal.version and internal.migrations are recorded
# unverified with no GET for them. A 4-arg call (every other project) is the
# probe it always was: 3 GETs, the same items.
#
# Sources the REAL common.sh and origin.sh with a stub curl that logs each URL
# and answers 200 with a fixture body. No network, no clock.
#
# Point it at another origin.sh to prove it bites:
#   git show origin/main:bin/lib/board-conformance/origin.sh > /tmp/o.sh
#   HARNESS_TEST_SANDBOX=1 ORIGIN_UNDER_TEST=/tmp/o.sh bash tests/board-conformance-hosted.bh-8918-test.sh
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/board-conformance-hosted.bh-8918-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
COMMON="$DIR/bin/lib/board-conformance/common.sh"
ORIGIN="${ORIGIN_UNDER_TEST:-$DIR/bin/lib/board-conformance/origin.sh}"
ENTRY="$DIR/bin/board-conformance.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "board-conformance-hosted: jq missing" >&2; exit 1; }

mkdir -p "$T/bin"
cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\$1" ;;
    -w|-H|-m) shift ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift
done
printf '%s\n' "\$URL" >> "$T/curl.log"
printf '%s' '{"sha":"abc123def456fixture","applied":[],"pending":[]}' > "\$OUT"
printf '200'
EOC
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# shellcheck source=bin/lib/board-conformance/common.sh
. "$COMMON" || { echo "cannot source $COMMON" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ORIGIN" || { echo "cannot source $ORIGIN" >&2; exit 1; }

# probe <args...> — one bc_probe_origin call; ITEMS and the curl log are fresh.
probe() {
  BC_ITEMS="$T/items.jsonl"; : > "$BC_ITEMS"; : > "$T/curl.log"
  export BC_ITEMS
  bc_probe_origin "$@"
}
item() { jq -r --arg n "$1" 'select(.name==$n) | "\(.status)|\(.note)"' "$T/items.jsonl"; }
gets() { wc -l < "$T/curl.log" | tr -d ' '; }
logged() { local u; while IFS= read -r u; do [ "$u" = "$1" ] && return 0; done < "$T/curl.log"; return 1; }

# H1 the hosted prefix: both internal items unverified, no GET for either.
probe "-" "http://127.0.0.1:9" "tok-fixture-h1" "mt-fixture-h1" "/api/hosted-board/hbtrace"
want="unverified|hosted board: the jobs worker serves no app internals"
[ "$(item internal.version)" = "$want" ] && ok || bad "H1 internal.version: got [$(item internal.version)]"
[ "$(item internal.migrations)" = "$want" ] && ok || bad "H1 internal.migrations: got [$(item internal.migrations)]"
[ "$(item origin.health)" = "unverified|no prod origin" ] && ok || bad "H1 origin.health: got [$(item origin.health)]"
[ "$(gets)" -eq 0 ] && ok || bad "H1 hosted probe sent $(gets) GET(s): $(tr '\n' ' ' < "$T/curl.log")"
[ "$(wc -l < "$T/items.jsonl" | tr -d ' ')" -eq 3 ] && ok || bad "H1 want exactly 3 items"

# H2 a hosted board with a prod origin still probes /api/health, and only that.
probe "https://app.example.invalid" "http://127.0.0.1:9" "tok-fixture-h2" "" "/api/hosted-board/p2"
[ "$(gets)" -eq 1 ] && logged "https://app.example.invalid/api/health" && ok || bad "H2 want 1 GET of /api/health, got: $(tr '\n' ' ' < "$T/curl.log")"
[ "$(item origin.health)" = "ok|" ] && ok || bad "H2 origin.health: got [$(item origin.health)]"

# H3 a 4-arg call is the probe it always was: 3 GETs, internals judged.
probe "https://app.example.invalid" "https://app.example.invalid" "tok-fixture-h3" "mt-fixture-h3"
[ "$(gets)" -eq 3 ] && ok || bad "H3 want 3 GETs, got $(gets)"
logged "https://app.example.invalid/api/internal/version" && ok || bad "H3 no GET of /api/internal/version"
logged "https://app.example.invalid/api/internal/migrations/status" && ok || bad "H3 no GET of the migrations status"
[ "$(item internal.version)" = "ok|sha abc123def456" ] && ok || bad "H3 internal.version: got [$(item internal.version)]"
[ "$(item internal.migrations)" = "ok|" ] && ok || bad "H3 internal.migrations: got [$(item internal.migrations)]"

# H4 an in-app prefix as the 5th arg is not hosted: the internals are probed.
probe "https://app.example.invalid" "https://app.example.invalid" "tok-fixture-h4" "mt-fixture-h4" "/api/board"
[ "$(gets)" -eq 3 ] && ok || bad "H4 /api/board want 3 GETs, got $(gets)"
probe "https://app.example.invalid" "https://app.example.invalid" "tok-fixture-h4" "mt-fixture-h4" "/api/hosted-boardx/p"
[ "$(gets)" -eq 3 ] && ok || bad "H4 a near-miss prefix is not hosted, got $(gets) GET(s)"

# H5 the entry passes the board prefix (column 4) as the 5th arg.
if grep -qE 'bc_probe_origin "\$prod" "\$base" "\$tok" "\$mt" "\$bp"' "$ENTRY"; then ok; else bad "H5 $ENTRY does not pass the board prefix to bc_probe_origin"; fi

echo "board-conformance-hosted.bh-8918: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS
