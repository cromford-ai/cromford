#!/bin/bash
# tests/size-threshold-hotfix-tier.size-hotfix-test.sh — a hotfix ticket gets a
# bigger size gate so it builds as ONE PR instead of being split (the operator,
# 2026-10-07).
#
# With SIZE_TIER=hotfix, bin/size-threshold.sh resolves each axis first from
# size_gate.<axis>.hotfix.<project>, then size_gate.<axis>.hotfix (seeded
# 1500/30 in worker/jobs/schema.sql), and only then the normal chain. The src it
# prints names the tier (row:hotfix). Every other ticket resolves exactly as
# before. Rows come from a state/settings-cache.json fixture through
# bin/lib/lane-gate.sh with JOBS_URL= and no jobs client in the tree: nothing
# reaches the network.
#
#   T1 hotfix + hotfix rows            -> 1500 30 row:hotfix
#   T2 hotfix + project hotfix row     -> the project row wins
#   T3 not a hotfix, same rows         -> 700 20 row (unchanged)
#   T4 hotfix with no hotfix rows      -> the normal chain (700 20 row)
#   T5 junk hotfix row                 -> rejected, falls back
#   T6 plan.sh's size gate passes SIZE_TIER=hotfix for a hotfix build only
#   T7 the split comment names the tier ("hotfix budget of 1500 lines ... 30 files")
#   T8 the seed rows exist in worker/jobs/schema.sql, insert-only-when-missing
#
#   HARNESS_TEST_SANDBOX=1 bash tests/size-threshold-hotfix-tier.size-hotfix-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

THRESH="$DIR/bin/size-threshold.sh"
h="$T/h"
mkdir -p "$h/state" "$h/flags" "$h/catalog" "$h/logs"
cache() { jq -n --argjson fa 1900000000 --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$h/state/settings-cache.json"; }
th()  { LANE_GATE_NOW=1900000000 HARNESS="$h" JOBS_URL= "$THRESH" "$@" 2>/dev/null; }
thf() { LANE_GATE_NOW=1900000000 HARNESS="$h" JOBS_URL= SIZE_TIER=hotfix "$THRESH" "$@" 2>/dev/null; }
reset() { rm -f "$h/state/settings-cache.json" "$h/flags/size-gate-widget-os" "$h/catalog/size-thresholds.conf"; scratch_rm "$h/state/lane-gate"; }
FLEET='"size_gate.lines":"700","size_gate.files":"20"'
HF='"size_gate.lines.hotfix":"1500","size_gate.files.hotfix":"30"'

# T1. hotfix + the hotfix rows
reset; cache "{$FLEET,$HF}"
[ "$(thf widget-os all)" = "1500 30 row:hotfix" ] && ok || bad "T1: hotfix must read 1500 30 row:hotfix, got '$(thf widget-os all)'"
# The tier as an argument, not only the env.
[ "$(th widget-os all hotfix)" = "1500 30 row:hotfix" ] && ok || bad "T1: tier as the 3rd arg must read 1500 30 row:hotfix, got '$(th widget-os all hotfix)'"

# T2. the project's own hotfix row wins over the fleet hotfix row, per axis
reset; cache "{$FLEET,$HF,\"size_gate.lines.hotfix.widget-os\":\"2400\"}"
[ "$(thf widget-os all)" = "2400 30 row:hotfix" ] && ok || bad "T2: project hotfix row must win, got '$(thf widget-os all)'"
[ "$(thf other-os all)" = "1500 30 row:hotfix" ] && ok || bad "T2: another project keeps the fleet hotfix row, got '$(thf other-os all)'"
# A hotfix row outranks the project's NORMAL row too: the tier comes first.
reset; cache "{$FLEET,$HF,\"size_gate.lines.widget-os\":\"900\"}"
[ "$(thf widget-os lines)" = 1500 ] && ok || bad "T2: the hotfix tier must outrank the normal project row, got '$(thf widget-os lines)'"

# T3. not a hotfix: exactly today's answer, hotfix rows ignored
reset; cache "{$FLEET,$HF,\"size_gate.lines.hotfix.widget-os\":\"2400\"}"
[ "$(th widget-os all)" = "700 20 row" ] && ok || bad "T3: a plain ticket must stay 700 20 row, got '$(th widget-os all)'"
[ "$(SIZE_TIER= th widget-os all)" = "700 20 row" ] && ok || bad "T3: an empty tier is no tier, got '$(SIZE_TIER= th widget-os all)'"
[ "$(SIZE_TIER=banana th widget-os all)" = "700 20 row" ] && ok || bad "T3: an unknown tier is no tier, got '$(SIZE_TIER=banana th widget-os all)'"
[ "$(th widget-os)" = "700 20" ] && ok || bad "T3: the 2-field shape must not change, got '$(th widget-os)'"

# T4. hotfix, but no hotfix rows: the normal chain answers
reset; cache "{$FLEET}"
[ "$(thf widget-os all)" = "700 20 row" ] && ok || bad "T4: no hotfix rows must fall to the normal chain, got '$(thf widget-os all)'"
reset
[ "$(thf widget-os all)" = "700 20 default" ] && ok || bad "T4: no cache at all must be 700 20 default, got '$(thf widget-os all)'"
[ "$(LANE_GATE_DISABLE=1 thf widget-os all)" = "700 20 default" ] && ok || bad "T4: LANE_GATE_DISABLE=1 ignores hotfix rows too"
# Only one axis has a hotfix row: src names each axis.
reset; cache "{$FLEET,\"size_gate.lines.hotfix\":\"1500\"}"
[ "$(thf widget-os all)" = "1500 20 lines:row:hotfix,files:row" ] && ok || bad "T4: a half-set tier must name each axis, got '$(thf widget-os all)'"

# T5. junk in a hotfix row is rejected exactly as in a normal row
for J in banana 0 -5 7e2 '1500 30' '$(id)' ''; do
  reset; cache "$(jq -n --arg j "$J" '{"size_gate.lines":"700","size_gate.files":"20","size_gate.lines.hotfix":$j,"size_gate.files.hotfix":"30"}')"
  [ "$(thf widget-os all)" = "700 30 lines:row,files:row:hotfix" ] && ok || bad "T5: fleet hotfix row '$J' must fall back to the normal chain, got '$(thf widget-os all)'"
  reset; cache "$(jq -n --arg j "$J" '{"size_gate.lines.hotfix":"1500","size_gate.lines.hotfix.widget-os":$j}')"
  [ "$(thf widget-os lines)" = 1500 ] && ok || bad "T5: project hotfix row '$J' must fall back to the fleet hotfix row, got '$(thf widget-os lines)'"
done

# T6. plan.sh hands the tier to size-threshold.sh for a hotfix build, and only then
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> size threshold call/{f=1;next} /^# <<< size threshold call/{exit} f' "$RB_ALL" > "$T/tcall.sh"
if [ -s "$T/tcall.sh" ]; then
  ok
  mkdir -p "$T/p/bin"
  cat > "$T/p/bin/size-threshold.sh" <<'EOS'
#!/bin/bash
echo "tier=${SIZE_TIER:-} args=$*" >> "$TCALL_LOG"
if [ "${SIZE_TIER:-}" = hotfix ]; then echo "1500 30 row:hotfix"; else echo "700 20 row"; fi
EOS
  chmod +x "$T/p/bin/size-threshold.sh"
  pdrive() { # pdrive <HOTFIX value>  -> prints "L F SRC"
    : > "$T/tcall.log"
    env -u SIZE_TIER HARNESS="$T/p" PROJECT=widget-os TCALL_LOG="$T/tcall.log" HOTFIX="$1" \
      bash -c '. "$1"; printf "%s %s %s\n" "$SG_MAXL" "$SG_MAXF" "$SG_SRC"' _ "$T/tcall.sh" 2>/dev/null
  }
  [ "$(pdrive 1)" = "1500 30 row:hotfix" ] && ok || bad "T6: a HOTFIX=1 build must get the hotfix limits, got '$(pdrive 1)'"
  pdrive 1 >/dev/null; grep -q '^tier=hotfix args=widget-os all$' "$T/tcall.log" && ok || bad "T6: HOTFIX=1 must pass SIZE_TIER=hotfix: $(cat "$T/tcall.log")"
  [ "$(pdrive '')" = "700 20 row" ] && ok || bad "T6: a plain build must get the normal limits, got '$(pdrive '')'"
  pdrive '' >/dev/null; grep -q '^tier= args=widget-os all$' "$T/tcall.log" && ok || bad "T6: a plain build must pass no tier: $(cat "$T/tcall.log")"
else
  bad "T6: no '# >>> size threshold call' block in bin/lib/rb/plan.sh"
fi

# T7. the split comment names the tier it was split against
MOD="$DIR/bin/lib/fc-issues.sh"; LIB="$DIR/bin/lib/file-children.sh"
FIX="$DIR/tests/fixtures/fc-issues"
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
mkdir -p "$T/f/bin/lib" "$T/f/logs" "$T/f/env" "$T/f/prompts"
cp "$DIR/bin/fleet-conf.sh" "$T/f/bin/"
printf 'scoutish   example-org/scoutish   https://scoutish.example  -  9 box-1 10.0.0.9\n' > "$T/f/fleet.conf"
scratch_install_closure bin/lib/file-children.sh "$T/f" >/dev/null || bad "T7: could not install file-children.sh's closure"
split_comment() { # split_comment <build> <SIZE_LIMITS src or ""> <maxl> <maxf>
  scratch_rm "$1"; mkdir -p "$1"
  cp "$FIX/two-plain/children.json" "$1/children.json"
  { printf 'SIZE_DECLARED: files=40 lines=2100\n'
    printf 'SIZE_LIMITS: lines=%s files=%s%s\n' "$3" "$4" "${2:+ src=$2}"
    printf 'SIZE_OVER: lines=2100>%s; files=40>%s\nSIZE_VERDICT: over\n' "$3" "$4"; } > "$1/size-gate.txt"
  env HARNESS="$T/f" FLEET_CONF="$T/f/fleet.conf" MAXL="$3" MAXF="$4" FILE_CHILDREN_DRY_RUN=1 \
    bash -c 'set -u; . "$1"; file_children "$2" "$3" "$4" "$5" "$5/children.json" --kind decompose' \
    _ "$LIB" scoutish 552 TK-552 "$1" >/dev/null 2>&1
  cat "$1/decompose-comment.md" 2>/dev/null
}
C=$(split_comment "$T/b1" row:hotfix 1500 30)
grep -qF 'against a hotfix budget of 1500 lines of product code across 30 files' <<<"$C" && ok \
  || bad "T7: a hotfix split must name the hotfix budget: $C"
C=$(split_comment "$T/b2" lines:row:hotfix,files:row 1500 20)
grep -qF 'against a hotfix budget of 1500 lines of product code across 20 files' <<<"$C" && ok \
  || bad "T7: a half-hotfix split still names the tier: $C"
C=$(split_comment "$T/b3" row 700 20)
grep -qF 'against a budget of 700 lines of product code across 20 files' <<<"$C" && ok \
  || bad "T7: a plain split must read exactly as before: $C"
grep -q 'hotfix' <<<"$C" && bad "T7: a plain split must not say hotfix: $C" || ok

# T8. the seed rows: insert-only-when-missing, 1500 / 30, the normal 700/20 untouched
SCH="$DIR/worker/jobs/schema.sql"
SEED=$(grep -A1 "('size_gate.lines.hotfix'" "$SCH")
grep -q "('size_gate.lines.hotfix','1500'" <<<"$SEED" && ok || bad "T8: schema.sql must seed size_gate.lines.hotfix=1500"
grep -q "('size_gate.files.hotfix','30'" <<<"$SEED" && ok || bad "T8: schema.sql must seed size_gate.files.hotfix=30"
B=$(grep -B4 "('size_gate.lines.hotfix'" "$SCH" | grep -c 'INSERT OR IGNORE INTO settings')
[ "$B" -ge 1 ] && ok || bad "T8: the hotfix seed must be INSERT OR IGNORE"
grep -q "('size_gate.lines','700'" "$SCH" && grep -q "('size_gate.files','20'" "$SCH" && ok || bad "T8: the 700/20 seeds must stay"
# The statement applies twice cleanly and never resets an operator's edit.
HSEED=$(awk '/^INSERT OR IGNORE INTO settings/{buf=$0; inseed=1; next}
             inseed{buf=buf"\n"$0; if ($0 ~ /;[[:space:]]*$/) { if (buf ~ /\x27size_gate\.lines\.hotfix\x27,/) print buf; inseed=0 } }' "$SCH")
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sqlite3' 2>/dev/null; then
  sq() { python3 -I -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); q=sys.argv[2] if len(sys.argv)>2 else sys.stdin.read()
if q.lstrip().upper().startswith("SELECT"):
    print("\n".join("|".join(str(x) for x in r) for r in c.execute(q)))
else:
    c.executescript(q); c.commit()' "$@"; }
  DB="$T/hseed.db"
  sq "$DB" "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT);
            INSERT INTO settings VALUES ('size_gate.lines.hotfix','2000','raised','operator','2026-10-07T00:00:00Z');"
  printf '%s\n' "$HSEED" | sq "$DB" && printf '%s\n' "$HSEED" | sq "$DB" && ok || bad "T8: the hotfix seed must apply twice cleanly"
  [ "$(sq "$DB" "SELECT value FROM settings WHERE key='size_gate.lines.hotfix'")" = 2000 ] && ok || bad "T8: a re-apply must not reset an edit"
  [ "$(sq "$DB" "SELECT value||'/'||actor FROM settings WHERE key='size_gate.files.hotfix'")" = 30/seed ] && ok || bad "T8: files.hotfix must seed 30 by seed"
else
  echo "note: no python3 sqlite — hotfix seed double-apply case skipped"
fi

echo "size-threshold-hotfix-tier: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
