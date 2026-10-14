#!/bin/bash
# tests/price-db-parity.bh-5652-test.sh — the DB path and the file path give the
# same price for every model in catalog/model-prices.json (BH-5652).
#
# The price table is the jobs worker's `model_prices`; the file a box prices
# from is its cache, written by bin/model-prices-sync.sh from GET
# /api/model-prices. If the round trip through the worker dropped or changed a
# rate, a box would price differently from the catalog it was seeded from, and
# no reader would see why.
#
#   P1  the body comes from the REAL worker: a node driver over node:sqlite
#       POSTs what the real model_prices_put builds from the catalog
#       (source=catalog, the seeder's call) and GETs it back through
#       worker.fetch. No node:sqlite -> SKIP, and a python stand-in serves the
#       catalog in the GET shape instead
#   P2  the real bin/model-prices-sync.sh writes that body to
#       state/model-prices.json, and for EVERY catalog model
#       cost_price_tokens and cost_model_cliff answer the same from the cache as
#       from the catalog. The compared count must equal the catalog's count.
#   P3  MUTATION (D1): the same body with cache_read dropped -> the suite sees
#       at least one model differ
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }
CAT="$DIR/catalog/model-prices.json"

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fakebin"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=http://jobs.fixture.invalid\n' > "$H/env/global.env"
printf 'lane_gate_or_exit() { :; }\nlane_env_apply() { :; }\n' > "$H/bin/lib/lane-gate.sh"
scratch_install_closure bin/model-prices-sync.sh "$H" >/dev/null || bad "could not install the sync closure"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "could not install the jobs client closure"

# ── P1: the body the worker serves ───────────────────────────────────────────
# The POST body exactly as the real client builds it: only the transport is cut.
( set +u; export HARNESS="$H"; . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  _jobs_req_file() { cp "$3" "$T/post.json"; }
  model_prices_put "$CAT" catalog ) || bad "P1 model_prices_put refused the committed catalog"
[ -s "$T/post.json" ] && ok || bad "P1 model_prices_put built no body"

cat > "$T/drive.mjs" <<'JS'
import { readFileSync } from 'node:fs';
const [, , dir, bodyFile] = process.argv;
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${dir}/worker/jobs/src/index.js`)).default;
const { d1 } = await import(`${dir}/worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const env = { DB: d1(new DatabaseSync(':memory:')), HARNESS_SECRET: 'fixture-secret' };
const req = (method, body) => new Request('https://jobs.fixture.invalid/api/model-prices', {
  method, headers: { authorization: 'Bearer fixture-secret', 'content-type': 'application/json' },
  body: body === undefined ? undefined : body });
const post = await worker.fetch(req('POST', readFileSync(bodyFile, 'utf8')), env);
if (post.status !== 200) { console.error(`POST ${post.status}: ${await post.text()}`); process.exit(1); }
const get = await worker.fetch(req('GET'), env);
if (get.status !== 200) { console.error(`GET ${get.status}: ${await get.text()}`); process.exit(1); }
process.stdout.write(await get.text());
JS
node "$T/drive.mjs" "$DIR" "$T/post.json" > "$T/served.json" 2>"$T/drive.err"; RC=$?
if [ "$RC" = 3 ] || ! command -v node >/dev/null 2>&1; then
  echo "P1: SKIP — node:sqlite unavailable; serving the catalog through the python GET stand-in"
  python3 - "$CAT" > "$T/served.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
per = {}
for m, r in t["per_token"].items():
    if not isinstance(r, dict): continue
    e = {k: r.get(k) for k in ("prompt", "completion", "cache_read", "cache_write")}
    if r.get("slug"): e["slug"] = r["slug"]
    if r.get("cliff_tokens") is not None: e["cliff_tokens"] = r["cliff_tokens"]
    per[m] = e
print(json.dumps({"updated_at": t.get("updated_at"), "source": "catalog", "models": len(per), "per_token": per}))
PY
else
  [ "$RC" = 0 ] && ok || bad "P1 the worker round trip failed (rc $RC): $(cat "$T/drive.err")"
fi
WANTN=$(jq '[.per_token[] | select(type == "object")] | length' "$CAT")
[ "$(jq '.per_token | length' "$T/served.json" 2>/dev/null)" = "$WANTN" ] && ok \
  || bad "P1 the worker served $(jq '.per_token | length' "$T/served.json" 2>/dev/null) models, the catalog has $WANTN"

# ── P2: the sync's cache prices like the catalog ─────────────────────────────
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
cat "$SERVED"; printf '\n200'
SH
chmod +x "$T/fakebin/curl"

# compare <served-body> — prints "<compared> <differing>" and each difference.
compare() {
  rm -f "$H/state/model-prices.json"
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH" SERVED="$1"; bash "$H/bin/model-prices-sync.sh" ) >/dev/null 2>&1 \
    || { echo "SYNC-FAILED"; return; }
  ( . "$DIR/bin/lib/cost-row.sh"
    n=0 d=0
    while IFS= read -r m; do
      n=$((n+1))
      a=$(MODEL_PRICES="$H/state/model-prices.json" cost_price_tokens "$m" 1000000 1000000 1000000 1000000)
      b=$(MODEL_PRICES="$CAT" cost_price_tokens "$m" 1000000 1000000 1000000 1000000)
      ca=$(MODEL_PRICES="$H/state/model-prices.json" cost_model_cliff "$m")
      cb=$(MODEL_PRICES="$CAT" cost_model_cliff "$m")
      if [ -z "$b" ] || [ "$a" != "$b" ] || [ "$ca" != "$cb" ]; then
        d=$((d+1)); echo "  differs: $m cache='$a' cliff='$ca' catalog='$b' cliff='$cb'" >&2
      fi
    done < <(jq -r '.per_token | to_entries[] | select(.value | type == "object") | .key' "$CAT")
    echo "$n $d" )
}
read -r CMP DIFF < <(compare "$T/served.json" 2>"$T/diff.txt")
[ "$CMP" = "$WANTN" ] && ok || bad "P2 compared $CMP models, the catalog has $WANTN — a silent skip"
[ "$DIFF" = 0 ] && ok || bad "P2 $DIFF model(s) price differently from the cache than from the catalog: $(cat "$T/diff.txt")"

# ── P3: mutation (D1) ────────────────────────────────────────────────────────
jq 'del(.per_token[].cache_read)' "$T/served.json" > "$T/served-mut.json"
read -r CMP DIFF < <(compare "$T/served-mut.json" 2>/dev/null)
[ "$CMP" = "$WANTN" ] && [ "${DIFF:-0}" -gt 0 ] && ok \
  || bad "P3 a body with cache_read dropped must make at least one model differ: compared=$CMP differing=$DIFF"

echo "price-db-parity.bh-5652-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
