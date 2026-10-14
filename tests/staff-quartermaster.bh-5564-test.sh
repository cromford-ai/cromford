#!/bin/bash
# tests/staff-quartermaster.bh-5564-test.sh — BH-5564 (BH-5556.7): the
# Quartermaster collector, bin/staff/quartermaster-collect.sh, and its lanes.
#
#   Q1   project-4 shape (2127 paid calls, 22 distinct inputs) -> one cost-multiplier
#        line, 96.7x in the title, no number in the item
#   Q2   grok shape (12 rc-0 calls with a blank cost) -> one cost-parity line
#   Q3   a clean fixture holding every no-fire case -> no line, rc 0
#   Q4   the edges: 100/10 fires, 99/1 and 100/11 do not; 3 blanks fire, 2 do
#        not; billing_mode=metered on an unlisted runner counts
#   Q5   an unreadable cost_rows route -> rc 1, no output, cache untouched
#   Q6   knobs: env, a settings row (lib.staff-quartermaster.*), a bad value
#        falls back to the default with one warn line, QM_METERED_RUNNERS
#   Q7   the production entry point: bin/staff.sh tick quartermaster with the
#        real collector claims the finding and makes one model call; with the
#        collector gone it claims nothing
#   Q8   every lane the seed gives quartermaster has a lane registry file
#   Q9   the composed schema gives quartermaster exactly the 7 cost lanes
#   Q10  the read cache: a second run inside QM_READ_EVERY_S re-prints the
#        cache with no read; QM_READ_EVERY_S=0 reads; a moving count keeps the
#        item (the fingerprint) the same
#   Q11  the collector names no model string and makes no gh call
#
# MUTATIONS (D1), each tried by hand once against the collector: drop the
# MIN_CALLS test -> Q3/Q4 red; read cost_usd 0 as blank -> Q3 red; drop the
# rc filter -> Q3 red; put the call count in the item -> Q1/Q10 red; skip
# the refused filter -> Q3/Q6 red; count every runner as metered -> Q3 red;
# skip the cache write -> Q5/Q10 red.
#
# Fixtures are cost-rows route pages ({"cost_rows":[{ts,box,raw}]}, raw the
# 26-column line a box writes) served by a QM_FIXTURE _jobs_req stub, so the
# REAL cost_rows_fetch pages and parses them.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-quartermaster.bh-5564-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-quartermaster: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "staff-quartermaster: python3 is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

COL_REL=bin/staff/quartermaster-collect.sh
COL_SRC="$DIR/bin/staff/quartermaster-collect.sh"
LIBF="$DIR/catalog/lanes.d/_lib.staff-quartermaster.json"
[ -r "$COL_SRC" ] || bad "missing $COL_SRC"
[ -r "$LIBF" ] || bad "missing $LIBF"

# 2026-10-14T12:00:00Z, pinned (D60).
NOW=1791979200
DAY=2026-10-14

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H" "$FXT" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$H" >/dev/null || bad "scratch_install_closure $COL_REL failed"
fi
COL="$H/$COL_REL"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done

# Rows: one JSON spec per group -> $FXT/rows.json. Each row gets its own ts
# (NOW - age - n, n counting across the whole fixture) and run id.
cat > "$T/gen.py" <<'PY'
import json, sys
now = int(sys.argv[2]); out = []; n = 0
def iso(t):
    import time
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
for g in json.load(open(sys.argv[1])):
    for i in range(g["n"]):
        n += 1
        k = g.get("fps", 0)
        fp = ("fp-%s-%d" % (g.get("tag", g["stage"]), i % k)) if k else ""
        ts = iso(now - g.get("age", 60) - n)
        cols = [ts, "fx-box", g.get("project", "fx-proj"), g["stage"], g["runner"], "fx-model",
                str(g.get("rc", 0)), "3", "10", "20", "", "", g.get("cost", "0.12"),
                g.get("bm", "subscription"), "", "", "sess-%d" % n, g.get("src", ""), "", "",
                "", "", "run-%d" % n, "", "", fp]
        out.append({"ts": ts, "box": "fx-box", "raw": ",".join(cols)})
json.dump(out, open(sys.argv[3], "w"))
PY
cat > "$T/pager.py" <<'PY'
import json, sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
lim = int(q.get("limit", ["2000"])[0]); since = q.get("since", [""])[0]; until = q.get("until", [""])[0]
rows = [r for r in json.load(open(sys.argv[2]))
        if (not since or r["ts"] >= since) and (not until or r["ts"] <= until)]
rows.sort(key=lambda r: r["ts"], reverse=True)
print(json.dumps({"cost_rows": rows[:lim]}))
PY
cat > "$T/qmfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  [ -f "$FXT/route.fail" ] && return 1
  case "$1 $2" in
    "GET /api/metrics/cost-rows?"*) python3 "$FXT_PAGER" "$2" "$FXT/rows.json"; return $? ;;
  esac
  return 1
}
SH
rows() { printf '%s' "$1" > "$T/spec.json"; python3 "$T/gen.py" "$T/spec.json" "$NOW" "$FXT/rows.json"; }
reset() { scratch_rm "$H/state" || exit 1; scratch_rm "$H/logs" || exit 1; : > "$FXT/req.log"; rm -f "$FXT/route.fail"; }
# qm [VAR=value ...] — run the collector as shipped, sandboxed. Out: $T/out, RC.
qm() {
  env HARNESS="$H" FXT="$FXT" FXT_PAGER="$T/pager.py" QM_FIXTURE="$T/qmfx.sh" HARNESS_TEST_SANDBOX=1 \
    QM_NOW="$NOW" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= PATH="$T/fakebin:$PATH" "$@" \
    bash "$COL" > "$T/out" 2> "$T/err"
  RC=$?
}
reads() { grep -c 'cost-rows' "$FXT/req.log"; }

project-4='[{"n":2127,"project":"project-4","stage":"triage","runner":"claude","fps":22,"tag":"project-4"}]'

# ═════ Q1: project-4 -> one multiplier finding ════════════════════════════════════
reset; rows "$project-4"; qm
eq "Q1 rc" "$RC" 0
eq "Q1 lines" "$(lines "$T/out")" 1
eq "Q1 class" "$(jq -r .class "$T/out" 2>/dev/null)" cost-multiplier
eq "Q1 item" "$(jq -c .item "$T/out" 2>/dev/null)" \
  "{\"check\":\"cost-multiplier\",\"project\":\"project-4\",\"stage\":\"triage\",\"runner\":\"claude\",\"day\":\"$DAY\"}"
TITLE=$(jq -r .title "$T/out" 2>/dev/null)
for s in "2127 paid calls" "22 distinct inputs" "(96.7x)" "in 24h" "project-4 triage on claude"; do
  case "$TITLE" in *"$s"*) ok ;; *) bad "Q1 title lacks '$s': $TITLE" ;; esac
done
jq -e '.item and .title and .source.kind == "cost_rows" and .source.url == "/costs"
       and (.source.labels | type == "array") and .observedAt == "2026-10-14T12:00:00Z"' "$T/out" >/dev/null 2>&1 \
  && ok || bad "Q1 line shape: $(cat "$T/out")"
[ "$(reads)" -ge 2 ] && ok || bad "Q1: 2127 rows must take two pages, read $(reads)"

# ═════ Q2: grok blanks -> one parity finding ═════════════════════════════════
reset; rows '[{"n":12,"stage":"triage","runner":"grok","cost":"","bm":"metered","fps":12}]'
qm CONSOLE_URL=https://console.example.com/
eq "Q2 rc" "$RC" 0
eq "Q2 lines" "$(lines "$T/out")" 1
eq "Q2 class" "$(jq -r .class "$T/out" 2>/dev/null)" cost-parity
eq "Q2 item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"cost-parity\",\"stage\":\"triage\",\"runner\":\"grok\",\"day\":\"$DAY\"}"
case "$(jq -r .title "$T/out" 2>/dev/null)" in
  *"triage on grok made 12 metered calls with a blank cost (12 of 12 metered calls) in 24h"*) ok ;;
  *) bad "Q2 title: $(jq -r .title "$T/out" 2>/dev/null)" ;;
esac
eq "Q2 url" "$(jq -r .source.url "$T/out" 2>/dev/null)" https://console.example.com/costs

# ═════ Q3: the clean fixture -> nothing ══════════════════════════════════════
CLEAN='[
 {"n":99,"stage":"s-under","runner":"claude","fps":1},
 {"n":120,"stage":"s-low","runner":"claude","fps":60},
 {"n":2127,"stage":"s-nofp","runner":"claude","fps":0},
 {"n":200,"stage":"s-refused","runner":"claude","fps":1,"src":"refused"},
 {"n":10,"stage":"p-sub","runner":"claude","cost":"","fps":10},
 {"n":10,"stage":"p-rc1","runner":"grok","rc":1,"cost":"","fps":10},
 {"n":5,"stage":"p-zero","runner":"grok","cost":"0","fps":5},
 {"n":5,"stage":"p-zero2","runner":"grok","cost":"0.00","fps":5},
 {"n":10,"stage":"p-refused","runner":"grok","cost":"","src":"refused","fps":10},
 {"n":5,"stage":"p-old","runner":"grok","cost":"","fps":5,"age":90000},
 {"n":1,"stage":"ladder","runner":"claude","rc":1,"cost":"","fps":1,"tag":"lad"},
 {"n":1,"stage":"ladder","runner":"grok","cost":"0.01","fps":1,"tag":"lad"}
]'
reset; rows "$CLEAN"; qm
eq "Q3 rc" "$RC" 0
eq "Q3 lines" "$(lines "$T/out")" 0
[ "$(lines "$T/out")" = 0 ] || cat "$T/out"

# ═════ Q4: the edges, table-driven ═══════════════════════════════════════════
EDGES='[
 {"n":100,"project":"p100","stage":"m","runner":"claude","fps":10},
 {"n":99,"project":"p99","stage":"m","runner":"claude","fps":1},
 {"n":100,"project":"p911","stage":"m","runner":"claude","fps":11},
 {"n":3,"stage":"b3","runner":"grok","cost":"","fps":3},
 {"n":2,"stage":"b2","runner":"grok","cost":"","fps":2},
 {"n":5,"stage":"bm","runner":"custom","cost":"","bm":"metered","fps":5},
 {"n":3,"stage":"or","runner":"openrouter","cost":" ","fps":3}
]'
reset; rows "$EDGES"; qm
eq "Q4 rc" "$RC" 0
eq "Q4 lines" "$(lines "$T/out")" 4
eq "Q4 keys" "$(jq -r '[.item.check, (.item.project // ""), .item.stage, .item.runner] | join("/")' "$T/out" 2>/dev/null | paste -sd' ')" \
  "cost-multiplier/p100/m/claude cost-parity//b3/grok cost-parity//bm/custom cost-parity//or/openrouter"
case "$(jq -r 'select(.item.project == "p100") | .title' "$T/out" 2>/dev/null)" in
  *"100 paid calls for 10 distinct inputs (10.0x)"*) ok ;; *) bad "Q4 100/10 title" ;; esac

# ═════ Q5: an unreadable route -> rc 1, nothing, cache untouched ═════════════
reset; rows "$project-4"; qm
CACHE="$H/state/staff/quartermaster/last.jsonl"
[ -s "$CACHE" ] && ok || bad "Q5: a good read wrote no cache"
cp -p "$CACHE" "$T/cache.before" 2>/dev/null
touch -d '2026-01-01T00:00:00Z' "$CACHE" "$T/cache.before" 2>/dev/null
touch "$FXT/route.fail"
qm QM_READ_EVERY_S=0
eq "Q5 rc" "$RC" 1
eq "Q5 stdout" "$(lines "$T/out")" 0
cmp -s "$CACHE" "$T/cache.before" && ok || bad "Q5: the cache changed on a failed read"
eq "Q5 cache mtime" "$(stat -c %Y "$CACHE" 2>/dev/null)" "$(stat -c %Y "$T/cache.before" 2>/dev/null)"

# ═════ Q6: knobs ═════════════════════════════════════════════════════════════
reset; rows "$project-4"; qm QM_MULT_MAX=200
eq "Q6 QM_MULT_MAX=200 lines" "$(lines "$T/out")" 0
reset; qm QM_MULT_MIN_CALLS=3000
eq "Q6 QM_MULT_MIN_CALLS=3000 lines" "$(lines "$T/out")" 0
reset; qm QM_MULT_MAX=abc
eq "Q6 QM_MULT_MAX=abc lines" "$(lines "$T/out")" 1
grep -q 'warn: QM_MULT_MAX=abc is outside .*; using the default 10' "$H/logs/staff.log" 2>/dev/null \
  && ok || bad "Q6: no warn line for QM_MULT_MAX=abc: $(cat "$H/logs/staff.log" 2>/dev/null)"
reset; qm QM_MULT_MAX=0
eq "Q6 QM_MULT_MAX=0 (out of range) lines" "$(lines "$T/out")" 1
# The settings row, through lib_env_apply and the real registry.
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --to "$REG" >/dev/null 2>&1 || bad "Q6: cannot render the lane registry"
jq -e '.libs[] | select(.id == "staff-quartermaster")' "$REG" >/dev/null 2>&1 \
  && ok || bad "Q6: catalog/lanes.json has no lib staff-quartermaster "
reset; mkdir -p "$H/state"
printf '{"fetched_at":%s,"values":{"lib.staff-quartermaster.qm_mult_max":"200"},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
qm LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW"
eq "Q6 settings row qm_mult_max=200 lines" "$(lines "$T/out")" 0
reset; mkdir -p "$H/state"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
qm LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW"
eq "Q6 no settings row lines" "$(lines "$T/out")" 1
# The window knob: a 1 h window drops a 2 h old blank row group.
reset; rows '[{"n":4,"stage":"w","runner":"grok","cost":"","fps":4,"age":7200}]'; qm
eq "Q6 default window sees a 2h old group" "$(lines "$T/out")" 1
reset; qm QM_WINDOW_H=1
eq "Q6 QM_WINDOW_H=1 drops it" "$(lines "$T/out")" 0
# QM_METERED_RUNNERS: claude counts once it is listed (mixed separators).
reset; rows "$CLEAN"; qm "QM_METERED_RUNNERS=Claude, fireworks"
eq "Q6 metered=claude lines" "$(lines "$T/out")" 1
eq "Q6 metered=claude runner" "$(jq -r '.item.runner + "/" + .item.stage' "$T/out" 2>/dev/null)" claude/p-sub
reset; qm QM_METERED_RUNNERS=claude QM_PARITY_MIN_CALLS=11
eq "Q6 QM_PARITY_MIN_CALLS=11 with claude listed" "$(lines "$T/out")" 0

# ═════ Q7: the production entry point ════════════════════════════════════════
S="$T/s"
mkdir -p "$S/prompts/staff" "$S/catalog/prompts"
scratch_install_closure bin/staff.sh "$S" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
scratch_install_closure bin/jobs-client.sh "$S" >/dev/null || bad "Q7 closure of bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$S" >/dev/null || bad "Q7 closure of the collector failed"
fi
cp "$DIR/bin/staff-core.mjs" "$S/bin/"
cp -r "$DIR/agent-core" "$S/agent-core"
cp "$DIR/prompts/staff/quartermaster-soul.md" "$S/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$S/catalog/prompts/"
cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit 0
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/beats.log"\n' > "$S/bin/lane-alert.sh"
chmod +x "$S/bin/agent-call.sh" "$S/bin/lane-alert.sh"
cat > "$T/stafffx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/staff-req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=quartermaster")
      printf '{"agent":{"name":"quartermaster","autonomy":"automation","cap":"augmentation","status":"active","soul":"prompts/staff/quartermaster-soul.md"}}'
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/staff-req.log"
  case "$2" in
    /api/staff/findings/claim)
      printf '{"claimed":true,"fingerprint":"%s","finding":{"agent":"quartermaster","status":"claimed"}}' \
        "$(jq -cS .item "$3" | sha256sum | cut -c1-64)"; return 0 ;;
    /api/staff/findings/record) printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
gh_rest() { printf 'gh_rest %s\n' "$*" >> "$FXT/gh.log"; return 75; }
gh_rest_issue_list() { printf 'list %s\n' "$*" >> "$FXT/gh.log"; return 75; }
lane_role_model() { printf 'stub-model\n'; }
SH
q7() {
  scratch_rm "$S/state" || exit 1; scratch_rm "$S/logs" || exit 1
  : > "$FXT/staff-req.log"; : > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/req.log"
  env HARNESS="$S" FXT="$FXT" FXT_PAGER="$T/pager.py" STAFF_FIXTURE="$T/stafffx.sh" QM_FIXTURE="$T/qmfx.sh" \
    HARNESS_TEST_SANDBOX=1 QM_NOW="$NOW" LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= CONSOLE_URL= PATH="$T/fakebin:$PATH" \
    bash "$S/bin/staff.sh" tick quartermaster > "$T/q7.out" 2>&1
  RC=$?
}
reset; rows "$project-4"; q7
eq "Q7 rc" "$RC" 0
eq "Q7 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 1
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '(96.7x)' && ok || bad "Q7: the claim title lacks 96.7x: $(cat "$FXT/staff-req.log")"
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '"agent":"quartermaster"' && ok || bad "Q7: the claim is not quartermaster's"
eq "Q7 agent-calls" "$(lines "$FXT/ac.log")" 1
eq "Q7 agent-call" "$(cat "$FXT/ac.log")" "staff-tick|quartermaster"
eq "Q7 digest lines" "$(lines "$S/logs/staff-digest.log")" 1
grep -q 'agent=quartermaster level=automation verdict=refuse .*(96.7x)' "$S/logs/staff-digest.log" 2>/dev/null \
  && ok || bad "Q7 digest: $(cat "$S/logs/staff-digest.log" 2>/dev/null)"
eq "Q7 gh calls" "$(lines "$FXT/gh.log")" 0
grep -q 'collected=1 new=1 .* model_calls=1 digested=1' "$S/logs/staff.log" 2>/dev/null \
  && ok || bad "Q7 summary: $(cat "$S/logs/staff.log" 2>/dev/null)"
# With the collector gone, the tick claims nothing (D2).
rm -f "$S/$COL_REL"; q7
eq "Q7 no collector rc" "$RC" 0
eq "Q7 no collector claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 0
eq "Q7 no collector agent-calls" "$(lines "$FXT/ac.log")" 0

# ═════ Q8/Q9: the lane seed ══════════════════════════════════════════════════
LANES7="cap-loss-detector ci-minutes-watch cost-local-brake cost-reconcile extra-usage-track orchestrator-burn vendor-spend-pull"
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-5564-*.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && ok || bad "Q8: no worker/jobs/schema.d/*-bh-5564-*.sql fragment"
SEEDED=$( [ -n "$SEED" ] && sed -n "s/^[[:space:]]*('quartermaster','\([a-z0-9-]*\)',.*/\1/p" "$SEED" | LC_ALL=C sort | paste -sd' ')
eq "Q8 seeded lanes" "$SEEDED" "$LANES7"
for L in $SEEDED; do
  [ -r "$DIR/catalog/lanes.d/$L.json" ] && ok || bad "Q8: seeded lane $L has no catalog/lanes.d/$L.json"
done
if [ -n "$SEED" ] && grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED"; then
  bad "Q8: the seed fragment holds DDL or a destructive statement"
else ok; fi
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "Q9: bin/schema-build.sh --to failed"
  GOT=$(node --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(":memory:");
    db.exec(require("node:fs").readFileSync(process.argv[1], "utf8"));
    db.exec(require("node:fs").readFileSync(process.argv[2], "utf8"));
    const r = db.prepare("SELECT agent, lane FROM staff_lanes ORDER BY agent, lane").all();
    console.log(r.map((x) => x.agent + ":" + x.lane).join(" "));
  ' "$T/schema.sql" "${SEED:-/dev/null}" 2>&1)
  eq "Q9 staff_lanes after the seed applies twice" "$GOT" "$(for L in $LANES7; do printf 'quartermaster:%s ' "$L"; done | sed 's/ $//')"
else
  echo "Q9 skipped: node:sqlite is not available in this node"
fi

# ═════ Q10: the read cache and a stable item ═════════════════════════════════
reset; rows "$project-4"; qm
cp "$T/out" "$T/out.first"; R1=$(reads)
qm
cmp -s "$T/out" "$T/out.first" && ok || bad "Q10: the cached run printed different lines"
eq "Q10 reads on the cached run" "$(( $(reads) - R1 ))" 0
qm QM_READ_EVERY_S=0
[ "$(( $(reads) - R1 ))" -ge 1 ] && ok || bad "Q10: QM_READ_EVERY_S=0 did not read"
cmp -s "$T/out" "$T/out.first" && ok || bad "Q10: the same input twice is not byte-identical"
rows '[{"n":2128,"project":"project-4","stage":"triage","runner":"claude","fps":22,"tag":"project-4"}]'
qm QM_READ_EVERY_S=0
eq "Q10 a moving count keeps the item" "$(jq -c .item "$T/out" 2>/dev/null)" "$(jq -c .item "$T/out.first" 2>/dev/null)"
case "$(jq -r .title "$T/out" 2>/dev/null)" in *"2128 paid calls"*) ok ;; *) bad "Q10: the title did not move" ;; esac
# An empty window is a good read: rc 0, no line, an empty cache.
reset; rows '[]'; qm
eq "Q10 empty rc" "$RC" 0
eq "Q10 empty lines" "$(lines "$T/out")" 0
[ -f "$CACHE" ] && [ ! -s "$CACHE" ] && ok || bad "Q10: an empty window did not write an empty cache"

# ═════ Q11: no model string, no gh ═══════════════════════════════════════════
if [ -r "$COL_SRC" ]; then
  eq "Q11 claude- strings" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -c 'claude-')" 0
  eq "Q11 gh calls" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -cE '(^|[^a-z_])gh( |_rest)')" 0
else
  bad "Q11: no collector to scan"
fi

[ -e "$T/net.log" ] && bad "a stub let a real curl/gh run: $(cat "$T/net.log")" || ok

echo "staff-quartermaster.bh-5564: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
