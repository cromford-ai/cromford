#!/bin/bash
# tests/dora-subagent-share.bh-10209-test.sh — the DORA digest's
# subagent_share block (BH-10209): the subagent share of execute $ per project
# and fleet over the last N days, from the `sub_usd:` note tokens in
# state/cost/fleet-cost.csv.
#
#   U1  hand-counted figures per project and fleet (stages, window, tokens).
#   U2  execute rows with no token: share None, the line says n/a.
#   U3  stages execute+fix count both.
#   U4  a measured zero is a share of 0.0, not None.
#   U5  no file: status absent, n/a, never 0.
#   U6  a header without `note`: status error, n/a.
#   U7  parse_sub_usd: the YES/NO table of the plan's failure modes.
#   D1  bin/dora-digest.sh DRIVEN: the json has fleet.subagent_share ok and the
#       message has one `subagent share of execute $, 7d:` line.
#   D2  DORA_SUBAGENT_SHARE_DAYS=abc: a logged fallback to 7, the file is still
#       written.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
# TEST-CHANGE BH-6052: D1-D3 read today's UTC date (the digest's file name);
# the guard above keeps the run inside one UTC day.
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq/python3 missing — skipping"; exit 0; }
[ -r "$DIR/bin/dora_subagent.py" ] || { echo "FAIL: bin/dora_subagent.py is missing"; echo "dora-subagent-share.bh-10209: 0 passed, 1 failed"; exit 1; }

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# row <ts> <project> <stage> <cost_usd> <note>
row() { printf '%s,box,%s,%s,claude,test-model,0,10,1,1,0,0,%s,subscription,fp,acct,sid,transcript,,,,,,%s,,\n' "$1" "$2" "$3" "$4" "$5"; }

PYOUT=$(python3 - "$DIR/bin" "$T" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
T = sys.argv[2]
import dora_subagent as ds
P = F = 0
def check(name, got, want):
    global P, F
    if got == want:
        P += 1
    else:
        F += 1
        print("FAIL: %s: expected %r, got %r" % (name, want, got))

HDR = ("ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,"
       "cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,"
       "ticket,job_id,pr,run_id,note,lane_id,guard_fp")
def row(ts, p, st, c, note):
    return ("%s,box,%s,%s,claude,test-model,0,10,1,1,0,0,%s,subscription,fp,acct,sid,transcript,"
            ",,,,,%s,,") % (ts, p, st, c, note)
def write(name, rows, hdr=HDR):
    p = os.path.join(T, name)
    with open(p, "w") as fh:
        fh.write(hdr + "\n" + "".join(r + "\n" for r in rows))
    return p

U = "2026-11-26T12:00:00Z"
IN, IN2, OUT = "2026-11-25T08:00:00Z", "2026-11-20T08:00:00+00:00", "2026-11-10T08:00:00Z"
p = write("u1.csv", [
    row(IN, "alpha", "execute", "10.00", "sub_usd:2.5;price_v:3"),
    row(IN2, "alpha", "execute", "6.00", "price_v:3"),
    row(IN, "alpha", "execute", "4.00", "sub_usd:0.5"),
    row(IN, "alpha", "review", "100", "sub_usd:50"),
    row(OUT, "alpha", "execute", "99", "sub_usd:99"),
    row(IN, "beta", "execute", "20.00", "acct=x;sub_usd:5"),
    row(IN, "beta", "execute", "", ""),
    row(IN, "gamma", "execute", "3.00", "price_v:3"),
])
b = ds.block(p, U, 7, ["execute"])
check("U1 status", b["status"], "ok")
a = b["projects"]["alpha"]
check("U1 alpha execute_rows", a["execute_rows"], 3)
check("U1 alpha execute_usd", a["execute_usd"], 20.0)
check("U1 alpha measured_rows", a["measured_rows"], 2)
check("U1 alpha measured_usd", a["measured_usd"], 14.0)
check("U1 alpha sub_usd", a["sub_usd"], 3.0)
check("U1 alpha share", a["share"], round(3.0 / 14.0, 4))
check("U1 alpha coverage", a["coverage"], 0.7)
be = b["projects"]["beta"]
check("U1 beta (an empty cost row counts as a row, $0)", (be["execute_rows"], be["execute_usd"], be["measured_rows"], be["sub_usd"], be["share"]), (2, 20.0, 1, 5.0, 0.25))
fl = b["fleet"]
check("U1 fleet", (fl["execute_rows"], fl["execute_usd"], fl["measured_rows"], fl["measured_usd"], fl["sub_usd"]), (6, 43.0, 3, 34.0, 8.0))
check("U1 fleet share", fl["share"], round(8.0 / 34.0, 4))
check("U1 fleet coverage", fl["coverage"], round(34.0 / 43.0, 4))
check("U1 source rows_read", b["source"]["rows_read"], 8)
check("U1 source rows_in_window", b["source"]["rows_in_window"], 7)
check("U1 source rows_counted (the stage rows)", b["source"]["rows_counted"], 6)
check("U1 source names the window", (b["source"]["since"], b["source"]["until"]), ("2026-11-19T12:00:00Z", U))
check("U1 source names the columns", b["source"]["columns"], ["ts", "project", "stage", "cost_usd", "note"])

# U2: gamma has execute rows and no token.
check("U2 gamma share None", b["projects"]["gamma"]["share"], None)
lines = ds.text_lines(b, 12)
check("U2 one line", len(lines), 1)
check("U2 the line", lines[0],
      "subagent share of execute $, 7d: fleet 23.5% ($8.00 of $34.00 measured, 3 of 6 rows); "
      "alpha 21.4%, beta 25.0%, gamma n/a")
check("U2 max_rows cuts projects", ds.text_lines(b, 1)[0].endswith("; alpha 21.4%"), True)
p = write("u2.csv", [row(IN, "gamma", "execute", "3.00", "price_v:3")])
b2 = ds.block(p, U, 7, ["execute"])
check("U2 fleet share None", b2["fleet"]["share"], None)
check("U2 fleet line", ds.text_lines(b2, 12)[0],
      "subagent share of execute $, 7d: n/a (no execute row carries sub_usd yet; 1 rows, $3.00)")

# U3: two stages.
p = write("u3.csv", [row(IN, "alpha", "execute", "10", "sub_usd:1"),
                     row(IN, "alpha", "fix", "10", "sub_usd:3"),
                     row(IN, "alpha", "review", "10", "sub_usd:9")])
b3 = ds.block(p, U, 7, ["execute", "fix"])
check("U3 two stages", (b3["fleet"]["execute_rows"], b3["fleet"]["sub_usd"], b3["fleet"]["share"]), (2, 4.0, 0.2))
check("U3 line names the stages", ds.text_lines(b3, 12)[0].startswith("subagent share of execute+fix $, 7d: fleet 20.0%"), True)
check("U3 one stage", ds.block(p, U, 7, ["execute"])["fleet"]["sub_usd"], 1.0)

# U4: a measured zero.
p = write("u4.csv", [row(IN, "alpha", "execute", "10", "sub_usd:0.000000;price_v:3")])
b4 = ds.block(p, U, 7, ["execute"])
check("U4 measured zero share", b4["fleet"]["share"], 0.0)
check("U4 measured zero line", ds.text_lines(b4, 12)[0].split(": ", 1)[1].startswith("fleet 0.0% ($0.00 of $10.00 measured, 1 of 1 rows)"), True)

# U5: no file.
b5 = ds.block(os.path.join(T, "nope.csv"), U, 7, ["execute"])
check("U5 status", b5["status"], "absent")
check("U5 no figure", (b5["fleet"], b5["projects"]), (None, None))
check("U5 unavailable", b5["unavailable"], "n/a (source state/cost/fleet-cost.csv absent)")
check("U5 line", ds.text_lines(b5, 12), ["subagent share of execute $, 7d: n/a (source state/cost/fleet-cost.csv absent)"])

# U6: no note column.
p = write("u6.csv", ["2026-11-25T08:00:00Z,alpha,execute,10"], hdr="ts,project,stage,cost_usd")
b6 = ds.block(p, U, 7, ["execute"])
check("U6 status", b6["status"], "error")
check("U6 no figure", b6["fleet"], None)
check("U6 unavailable names the column", "note" in (b6["unavailable"] or ""), True)
check("U6 line is n/a", ds.text_lines(b6, 12)[0].split(": ", 1)[1].startswith("n/a ("), True)

# U7: the token decision table.
for s, want in [("sub_usd:1.5", 1.5), ("sub_usd:0.000000", 0.0), ("sub_usd:2;price_v:3", 2.0),
                ("price_v:3;sub_usd:2", 2.0), ("killed.x.sub_usd:2", 2.0),
                ("", None), (None, None), ("sub_usd:", None), ("sub_usd:-1", None),
                ("sub_usd:abc", None), ("xsub_usd:1", None), ("subusd:1", None),
                ("SUB_USD:1", None), ("sub_usd:1x", None)]:
    check("U7 parse_sub_usd(%r)" % s, ds.parse_sub_usd(s), want)
print("PY %d %d" % (P, F))
PY
)
printf '%s\n' "$PYOUT" | grep '^FAIL' || true
PYP=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $2}'); PYF=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $3}')
if [ -z "$PYP" ]; then bad "the python cases did not finish: $PYOUT"; else PASS=$((PASS+PYP)); FAIL=$((FAIL+PYF)); fi

# ── D1/D2: bin/dora-digest.sh driven ────────────────────────────────────────
TODAY=$(date -u +%F)
IN_TS=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
OLD_TS=$(date -u -d '10 days ago' '+%Y-%m-%dT%H:%M:%SZ')
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/env" "$H/flags" "$H/state/cost" "$H/state/quota"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf 'alpha  Org/alpha  https://alpha.test  /api/board  1 box-a 192.0.2.1\n' > "$T/fleet.conf"
{ echo "$HDR"
  row "$IN_TS" alpha execute 10.00 "sub_usd:2.000000;price_v:3"
  row "$IN_TS" alpha execute 10.00 "price_v:3"
  row "$OLD_TS" alpha execute 50.00 "sub_usd:50"
} > "$H/state/cost/fleet-cost.csv"
digest() {
  ( unset DORA_SUBAGENT_SHARE_DAYS DORA_SUBAGENT_STAGES
    for kv in "$@"; do export "${kv?}"; done
    HARNESS="$H" FLEET_CONF="$T/fleet.conf" DORA_LEDGER=0 DORA_GH_BUDGET=0 \
      "$DIR/bin/dora-digest.sh" --no-send --print --out-dir "$H/state/dora" > "$H/stdout" 2> "$H/stderr" )
}
echo "--- D1. bin/dora-digest.sh driven"
digest; RC=$?
eq "D1 rc" "$RC" 0
JF="$H/state/dora/$TODAY.json"
eq "D1 status" "$(jq -r '.fleet.subagent_share.status' "$JF" 2>/dev/null)" ok
eq "D1 fleet share (2 of 10 measured, the 10-day-old row out)" "$(jq -r '.fleet.subagent_share.fleet.share' "$JF" 2>/dev/null)" 0.2
eq "D1 the window is 7 days" "$(jq -r '.fleet.subagent_share.days' "$JF" 2>/dev/null)" 7
eq "D1 stages" "$(jq -c '.fleet.subagent_share.source.stages' "$JF" 2>/dev/null)" '["execute"]'
eq "D1 one line in the message" "$(grep -c '^subagent share of execute \$, 7d:' "$H/state/dora/latest.txt" 2>/dev/null)" 1
grep -q '^subagent share of execute \$, 7d: fleet 20.0% (\$2.00 of \$10.00 measured, 1 of 2 rows); alpha 20.0%$' "$H/stdout" \
  && ok || bad "D1 --print must show the line: $(grep 'subagent share' "$H/stdout")"

echo "--- D2. a bad DORA_SUBAGENT_SHARE_DAYS"
rm -f "$JF"
digest DORA_SUBAGENT_SHARE_DAYS=abc; RC=$?
eq "D2 rc" "$RC" 0
[ -s "$JF" ] && ok || bad "D2 the digest file must still be written"
grep -q "DORA_SUBAGENT_SHARE_DAYS='abc' is not a number — using 7" "$H/logs/dora-digest.log" 2>/dev/null \
  && ok || bad "D2 the fallback must be logged: $(tail -3 "$H/logs/dora-digest.log" 2>/dev/null)"
eq "D2 the fallback window" "$(jq -r '.fleet.subagent_share.days' "$JF" 2>/dev/null)" 7
echo "--- D3. DORA_SUBAGENT_SHARE_DAYS=30 and stages execute+review"
digest DORA_SUBAGENT_SHARE_DAYS=30; RC=$?
eq "D3 a 30-day window takes the old row" "$(jq -r '.fleet.subagent_share.fleet.sub_usd' "$JF" 2>/dev/null)" 52.0
digest DORA_SUBAGENT_STAGES=review
eq "D3 another stage: no rows" "$(jq -r '.fleet.subagent_share.fleet.execute_rows' "$JF" 2>/dev/null)" 0

echo "dora-subagent-share.bh-10209: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
