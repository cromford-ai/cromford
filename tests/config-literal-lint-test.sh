#!/bin/bash
# tests/config-literal-lint-test.sh — tests/config-literal-lint.sh (BH-1511.1)
# finds exactly the redundant literal defaults of REGISTERED knobs, and nothing
# else, on a fixture tree whose every line is a case:
#   1. `${KNOB:-5}` for a registered knob is listed, file:line:NAME:literal;
#   2. an unregistered name, `${KNOB:-}`, a computed `${KNOB:-$Y}` and a
#      commented line are NOT;
#   3. a nested `${A:-${KNOB:-7}}` lists the inner literal once;
#   4. a lib-scope knob (registry `libs`) counts the same as a lane's;
#   5. WARN mode exits 0 with the count; --strict exits 1 on any finding and 0
#      on a clean tree;
#   6. the real repo scans (the lint is alive on this tree, not only a fixture);
#   7. --drift names a read whose default is not the registry's (review M4).
# Run from anywhere: tests/config-literal-lint-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LINT="$DIR/tests/config-literal-lint.sh"

R="$T/repo"; mkdir -p "$R/bin/lib" "$R/tests"
cat > "$T/reg.json" <<'JSON'
{ "lanes": [ { "id": "demo", "script": "bin/demo.sh", "knobs": [ { "env": "DEMO_N", "default": 5 }, { "env": "DEMO_S", "default": "x" } ] } ],
  "libs":  [ { "id": "demo-lib", "file": "bin/lib/demo.sh", "knobs": [ { "env": "DEMO_LIB_S", "default": 900 } ] } ] }
JSON
cat > "$R/bin/demo.sh" <<'SH'
#!/bin/bash
a="${DEMO_N:-5}"
b="${OTHER_THING:-5}"
[ -n "${DEMO_N:-}" ] && echo set
c="${DEMO_N:-$Y}"
# d="${DEMO_N:-9}"
e="${DEMO_S:-${DEMO_N:-7}}"
SH
cat > "$R/bin/lib/demo.sh" <<'SH'
w="${DEMO_LIB_S:=900}"
SH
# A fixture under tests/ is exempt: it is a fixture, not a call site.
printf 'x="${DEMO_N:-3}"\n' > "$R/tests/t.sh"
( cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1

OUT=$(LANE_REGISTRY="$T/reg.json" bash "$LINT" "$R" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "5a WARN mode must exit 0 with findings, got $RC: $OUT"
grep -qx 'bin/demo.sh:2:DEMO_N:5' <<<"$OUT" && ok || bad "1 the registered literal was not listed: $OUT"
grep -q 'OTHER_THING' <<<"$(printf '%s\n' "$OUT")" && bad "2a an unregistered name was listed: $OUT" || ok
grep -qE 'bin/demo.sh:(4|5|6):' <<<"$(printf '%s\n' "$OUT")" && bad "2b an empty/computed/commented default was listed: $OUT" || ok
grep -qx 'bin/demo.sh:7:DEMO_N:7' <<<"$OUT" && ok || bad "3a the nested inner literal was not listed: $OUT"
grep -q 'bin/demo.sh:7:DEMO_S' <<<"$(printf '%s\n' "$OUT")" && bad "3b a computed outer default was listed: $OUT" || ok
grep -qx 'bin/lib/demo.sh:1:DEMO_LIB_S:900' <<<"$OUT" && ok || bad "4 a lib-scope knob was not listed: $OUT"
grep -q '^tests/' <<<"$(printf '%s\n' "$OUT")" && bad "fixtures under tests/ must be exempt: $OUT" || ok
grep -q 'config-literal-lint: 3 redundant literal' <<<"$OUT" && ok || bad "5b the count line must say 3: $OUT"
LANE_REGISTRY="$T/reg.json" bash "$LINT" --strict "$R" >/dev/null 2>&1
[ $? = 1 ] && ok || bad "5c --strict must exit 1 while findings remain"
# 7 — drift: DEMO_N's registry default is 5; the nested read says 7.
DR=$(LANE_REGISTRY="$T/reg.json" bash "$LINT" --drift "$R" 2>/dev/null)
grep -qxF "$(printf 'READ_DIFFERS\tlane:demo\tDEMO_N\tbin/demo.sh\tread=7 registry=5')" <<<"$DR" && ok \
  || bad "7a --drift must list DEMO_N read=7 vs registry=5: $DR"
grep -q "DEMO_N.*read=5 " <<<"$(printf '%s\n' "$DR")" && bad "7b a read equal to the registry is not drift: $DR" || ok
# Clean the tree: every read in the contract form.
printf '#!/bin/bash\na="$DEMO_N"\n' > "$R/bin/demo.sh"; printf 'w="$DEMO_LIB_S"\n' > "$R/bin/lib/demo.sh"
( cd "$R" && git add -A && git -c user.email=t@t -c user.name=t commit -qm clean ) >/dev/null 2>&1
LANE_REGISTRY="$T/reg.json" bash "$LINT" --strict "$R" >/dev/null 2>&1
[ $? = 0 ] && ok || bad "5d --strict must exit 0 on a clean tree"

# 6 — the real repo.
OUT=$(bash "$LINT" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "6a the lint must run clean (WARN) on this repo, rc=$RC: $(printf '%s' "$OUT" | tail -2)"
grep -qE '^config-literal-lint: [0-9]+ redundant literal' <<<"$OUT" && ok || bad "6b no count line on this repo: $(printf '%s' "$OUT" | tail -2)"
grep -q ':WAKE_BACKSTOP_S:' <<<"$(printf '%s\n' "$OUT")" && bad "6c the worked example's literal is back: $(printf '%s\n' "$OUT" | grep WAKE_BACKSTOP_S)" || ok

echo "config-literal-lint-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
