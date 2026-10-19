#!/bin/bash
# tests/untriaged-wake-hub-only.bh-7425-test.sh — BH-7425: untriaged-wake stays
# on the hub. The schema fragment
# worker/jobs/schema.d/202610191454-bh-7425-untriaged-wake-hub-only.sql seeds
# lane_placement.untriaged-wake.hub_only, so the REAL lp_decide keeps the lane
# on the hub even when lane_placement.untriaged-wake says fly.
#
# Driven over real curl against the REAL jobs worker on node:sqlite with the
# composed schema (tests/lib/lane-runs-worker.bh-6124.mjs).
#
#   U1  GET /api/settings/lane_placement.untriaged-wake.hub_only: non-empty,
#       names pl_dispatch and parent-close, actor seed
#   U2  lane_placement.untriaged-wake=fly: lp_decide gives hub, LP_WHY hub_only:
#   U3  near miss: a fly row for a lane with no hub_only row gives fly
#   U4  an operator value of the row survives a re-apply of the fragment
#   U5  premise pin: bin/untriaged-wake.sh has no pl_dispatch call and no
#       catalog/lane-run-inputs.d/untriaged-wake.ro exists
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/untriaged-wake-hub-only.bh-7425-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
FRAG="$REPO/worker/jobs/schema.d/202610191454-bh-7425-untriaged-wake-hub-only.sql"
KEY=lane_placement.untriaged-wake.hub_only

# ── U5 first: it needs no worker ────────────────────────────────────────────
PREMISE="the BH-7425 hub_only premise changed: revisit $KEY"
n=$(grep -v '^[[:space:]]*#' "$REPO/bin/untriaged-wake.sh" | grep -c 'pl_dispatch')
[ "$n" = 0 ] && ok "U5 bin/untriaged-wake.sh has no pl_dispatch call" \
  || bad "U5 $PREMISE (bin/untriaged-wake.sh calls pl_dispatch $n time(s))"
[ ! -e "$REPO/catalog/lane-run-inputs.d/untriaged-wake.ro" ] && ok "U5 no untriaged-wake input manifest" \
  || bad "U5 $PREMISE (catalog/lane-run-inputs.d/untriaged-wake.ro exists)"

command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "SKIP: node or jq missing (U5 ran: $PASS passed, $FAIL failed)"; [ "$FAIL" -eq 0 ]; exit; }
# The worker imports catalog/lanes.json and catalog/llm-sites.json (composed, git-ignored).
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SRV="$REPO/tests/lib/lane-runs-worker.bh-6124.mjs"

# ── the scratch hub: the real placement lib and jobs client ─────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env"
for L in bin/lib/lane-placement.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
: > "$H/env/global.env"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=30 BOX_NAME=fixture-box

SPID=""
: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
SPID=$!
trap '[ -n "$SPID" ] && kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 600); do [ -s "$T/w.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable (U5 ran: $PASS passed, $FAIL failed)"; [ "$FAIL" -eq 0 ]; exit; }
  echo "setup: worker did not start (rc $src): $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
setting() { curl -fsS -m 15 -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null || bad "setup: PUT __setting $1"; }
get_row() { curl -sS -m 15 -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings/$1"; }
# One fresh shell per decision, so no LP_* value leaks between cases.
decide() {
  bash -c '. "$HARNESS/bin/lib/lane-placement.sh" || exit 9; lp_decide "$1"; printf "%s\t%s\n" "$LP_PLACE" "$LP_WHY"' _ "$1"
}

# ── U1 the composed schema seeds the row ────────────────────────────────────
R=$(get_row "$KEY")
V=$(jq -r '.setting.value // ""' <<<"$R" 2>/dev/null)
A=$(jq -r '.setting.actor // ""' <<<"$R" 2>/dev/null)
[ -n "$V" ] && ok "U1 $KEY is seeded" || bad "U1 no $KEY row: $R"
case "$V" in *pl_dispatch*) ok "U1 the reason names pl_dispatch" ;; *) bad "U1 the reason does not name pl_dispatch: '$V'" ;; esac
case "$V" in *parent-close*) ok "U1 the reason names parent-close" ;; *) bad "U1 the reason does not name parent-close: '$V'" ;; esac
[ "$A" = seed ] && ok "U1 actor seed" || bad "U1 actor '$A', want seed"

# ── U2 a fly lane row still answers hub ─────────────────────────────────────
setting lane_placement.untriaged-wake fly
D=$(decide untriaged-wake)
[ "${D%%$'\t'*}" = hub ] && ok "U2 lp_decide untriaged-wake: hub" || bad "U2 lp_decide untriaged-wake: '$D', want hub"
case "${D#*$'\t'}" in "hub_only: "?*) ok "U2 LP_WHY starts hub_only:" ;; *) bad "U2 LP_WHY '${D#*$'\t'}'" ;; esac

# ── U3 near miss: another lane with no hub_only row goes fly ────────────────
setting lane_placement.demo-7425 fly
D=$(decide demo-7425)
[ "${D%%$'\t'*}" = fly ] && ok "U3 lp_decide demo-7425: fly" || bad "U3 lp_decide demo-7425: '$D', want fly"

# ── U4 the operator wins over a re-apply of the fragment ────────────────────
if [ -f "$FRAG" ]; then
  U4=$(node --input-type=module -e '
    const { DatabaseSync } = await import("node:sqlite");
    const { readFileSync } = await import("node:fs");
    const { jobsSchemaSql } = await import(process.argv[1] + "/worker/jobs/test/lib/jobs-schema.js");
    const db = new DatabaseSync(":memory:");
    db.exec(jobsSchemaSql());
    db.prepare("UPDATE settings SET value=?1 WHERE key=?2").run("operator text", process.argv[3]);
    db.exec(readFileSync(process.argv[2], "utf8"));
    const r = db.prepare("SELECT value FROM settings WHERE key=?1").get(process.argv[3]);
    console.log(r ? r.value : "<no row>");
  ' "$REPO" "$FRAG" "$KEY" 2>"$T/u4.err")
  [ "$U4" = "operator text" ] && ok "U4 the operator value survives a re-apply" || bad "U4 value after re-apply: '$U4' $(head -3 "$T/u4.err")"
else
  bad "U4 no fragment $FRAG"
fi

echo "untriaged-wake-hub-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
