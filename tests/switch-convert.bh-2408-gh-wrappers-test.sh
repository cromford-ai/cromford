#!/bin/bash
# tests/switch-convert.bh-2408-gh-wrappers-test.sh — BH-2442 (BH-2408.2): the
# gh wrapper, ledger, gate-self, hotfix and model-prices kill switches read as
# `lane_switch <name> file`, a settings row first and flags/<name> second.
#
# Every case runs the REAL script or lib, copied into a scratch harness built by
# tests/lib/switch-convert-fixture.sh, and observes what it does:
#   site 1 gate-self-absorb-off   _gsc_is_on "$T/h" rc (1 = off)
#   site 2 gh-ledger-off          bin/gh-ledger/gh: the stub real gh prints
#                                 THROUGH and records GH_DEBUG; the ledger path
#                                 runs gh under GH_DEBUG=api, the switch does not
#   site 3 gh-ledger-push-off     bin/gh-ledger-push.sh: past the switch it takes
#                                 locks/gh-ledger-push.lock and POSTs the row;
#                                 switched off it exits before, with neither
#   site 4 gh-shim-off            bin/gh-rest-shim: an untranslated call writes
#                                 a logs/gh-passthrough.log line; switched off it
#                                 execs real gh with no line
#   site 5 hotfix-lane-off        hotfix_lane_on "$T/h" prints 0 (off) or 1
#   site 6 model-prices-sync-off  bin/model-prices-sync.sh: past the switch it
#                                 calls model_prices_get (a stub that records)
# For each site k: Rk a row switch.<n>=1 with no file is off; Fk a row
# switch.<n>=0 plus the file runs, with one `flags/<n> ignored` line; Lk with no
# rows the file is off and no file runs. Then the slice-owned cases:
#   L0  hotfix-lib.sh and gh-ledger/gh copied with no lib beside them fall back
#       to the file and never exit;
#   W1  a stale cache holding switch.gh-ledger-push-off=1, worker unreachable:
#       gh-ledger-push stops; W2 no cache, unreachable, file present: it stops;
#   N3  a row `yes please` is no row, so the file decides;
#   A4  with a stale cache the gh wrappers send no GET /api/settings;
#   E   neither wrapper adds a stderr line where the read cannot write its
#       miss stamp;
#   X   a row for another box, GH_SHIM_OFF=true, HARNESS unset in gh-ledger/gh;
#   C1/O1/X1 the registry over this slice's six files.
# DIR=<checkout> runs the suite against another tree (red-first on the base).
# Run from anywhere: bash tests/switch-convert.bh-2408-gh-wrappers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/switch-convert-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LANE_GATE_DISABLE GH_TOKEN GITHUB_TOKEN GH_DEBUG GH_LEDGER_OFF GH_LEDGER_DEPTH \
      GH_LEDGER_BY_CALLER GH_REST_SHIM_DEPTH GH_SHIM_OFF GH_SHIM_LIB GH_REAL \
      MODEL_PRICES_SYNC GATE_SELF_ABSORB HOTFIX_LANE H

H0="$T/h"
sc_harness "$H0" || { echo "FAIL: sc_harness"; exit 1; }
export HARNESS="$H0"
mkdir -p "$H0/bin/gh-ledger" "$H0/state/gh-rest-ledger" "$T/other" "$T/tmp" "$T/real"
export TMPDIR="$T/tmp"
for f in lib/gate-self-comments.sh lib/hotfix-lib.sh lib/env-path.sh lib/gh-rest-ledger.sh \
         gh-ledger/gh gh-ledger-push.sh gh-rest-shim model-prices-sync.sh; do
  cp "$DIR/bin/$f" "$H0/bin/$f" || { echo "FAIL: cannot copy bin/$f"; exit 1; }
done
# The fixture's stub client, plus the one call model-prices-sync makes past its switch.
cat >> "$H0/bin/jobs-client.sh" <<'SH'
model_prices_get() { echo "PRICES_GET" >> "$CALLS"; return 0; }
_jobs_req_file() { echo "$1 $2" >> "$CALLS"; return 1; }
SH
printf '2026-09-27T06:00:00Z\tlane\tGET\t/x\t200\t000\t1\n' > "$H0/state/gh-rest-ledger/2026-09-27T06.tsv"

# The real gh: records GH_DEBUG, prints THROUGH on stdout.
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
echo "GH_DEBUG=${GH_DEBUG:-}" >> "$GH_STUB_LOG"
echo THROUGH
exit 0
STUB
chmod +x "$T/real/gh"
export GH_STUB_LOG="$T/real.log"
RPATH="$T/real:$PATH"

fresh() {
  local p
  for p in "$H0/state/lane-gate" "$H0/logs"/* "$H0/locks"; do
    [ -e "$p" ] && { scratch_rm "$p" || exit 1; }
  done
  rm -f "$H0/state/settings-cache.json" "$H0/flags"/* "$GH_STUB_LOG"
  sc_rows
  : > "$CALLS"; UNREACHABLE=""; export UNREACHABLE
}

# site <k> — prints `off` when site k behaved switched off, `on` when it ran.
site() {
  local out rc
  case "$1" in
    1) HARNESS="$T/other" bash -c '. "$2/bin/lib/gate-self-comments.sh" 2>/dev/null; _gsc_is_on "$1"' _ "$H0" "$H0"
       [ $? -eq 1 ] && echo off || echo on ;;
    2) out=$(env -u HARNESS PATH="$H0/bin/gh-ledger:$RPATH" GH_TOKEN=x "$H0/bin/gh-ledger/gh" pr list 2>/dev/null); rc=$?
       [ "$out" = THROUGH ] && [ "$rc" = 0 ] || { echo "broken:rc=$rc:out=$out"; return; }
       grep -q '^GH_DEBUG=api$' "$GH_STUB_LOG" 2>/dev/null && echo on || echo off ;;
    3) bash "$H0/bin/gh-ledger-push.sh" hub-1 >/dev/null 2>&1
       if [ -e "$H0/locks/gh-ledger-push.lock" ]; then echo on
       elif grep -q 'POST /api/metrics/gh-ledger' "$CALLS"; then echo "broken:posted-without-lock"
       else echo off; fi ;;
    4) out=$(PATH="$RPATH" "$H0/bin/gh-rest-shim" pr view 1 2>/dev/null); rc=$?
       [ "$out" = THROUGH ] && [ "$rc" = 0 ] || { echo "broken:rc=$rc:out=$out"; return; }
       [ -s "$H0/logs/gh-passthrough.log" ] && echo on || echo off ;;
    5) out=$(HARNESS="$T/other" bash -c '. "$2/bin/lib/hotfix-lib.sh" 2>/dev/null; hotfix_lane_on "$1"' _ "$H0" "$H0")
       case "$out" in 0) echo off ;; 1) echo on ;; *) echo "broken:$out" ;; esac ;;
    6) bash "$H0/bin/model-prices-sync.sh" >/dev/null 2>&1
       grep -q '^PRICES_GET' "$CALLS" && echo on || echo off ;;
  esac
}
NAMES=(- gate-self-absorb-off gh-ledger-off gh-ledger-push-off gh-shim-off hotfix-lane-off model-prices-sync-off)

for k in 1 2 3 4 5 6; do
  n=${NAMES[$k]}
  fresh; sc_rows "switch.$n=1"
  eq "R$k $n row=1, no file" "$(site "$k")" off
  fresh; sc_rows "switch.$n=0"; touch "$H0/flags/$n"
  eq "F$k $n row=0 + file" "$(site "$k")" on
  eq "F$k $n ignored line" "$(sc_ignored_lines "$H0" "$n")" 1
  fresh; touch "$H0/flags/$n"
  eq "L$k $n no row, file" "$(site "$k")" off
  fresh
  eq "L$k $n no row, no file" "$(site "$k")" on
  # X: a row for ANOTHER box is not this box's row.
  fresh; sc_rows "switch.$n.other-box=1"
  eq "X$k $n row for other-box" "$(site "$k")" on
  # N3 shape on every site: an unreadable row is no row, so the file decides.
  fresh; sc_rows "switch.$n=yes please"; touch "$H0/flags/$n"
  eq "N$k $n row 'yes please' + file" "$(site "$k")" off
  fresh; sc_rows "switch.$n=yes please"
  eq "N$k $n row 'yes please', no file" "$(site "$k")" on
done

# ── W1/W2: the worker is down ────────────────────────────────────────────────
fresh; SC_CACHE_AT=0 sc_seed_cache switch.gh-ledger-push-off=1; export UNREACHABLE=1
eq "W1 stale cache row=1, unreachable" "$(site 3)" off
fresh; export UNREACHABLE=1; touch "$H0/flags/gh-ledger-push-off"
eq "W2 no cache, unreachable, file" "$(site 3)" off
fresh; export UNREACHABLE=1
eq "W2 no cache, unreachable, no file" "$(site 3)" on

# ── A4: the gh wrappers never ask the worker while a cache exists ───────────
fresh; SC_CACHE_AT=0 sc_seed_cache; sc_rows switch.gh-ledger-off=1 switch.gh-shim-off=1
eq "A4 gh-ledger with stale cache" "$(site 2)" on
eq "A4 gh-rest-shim with stale cache" "$(site 4)" on
eq "A4 GET /api/settings from the wrappers" "$(grep -c '/api/settings' "$CALLS")" 0

# ── E: the wrappers print nothing of their own, even where the switch read
# cannot write its bookkeeping (a harness whose state/ is a file) ────────────
mkdir -p "$T/ro"; : > "$T/ro/state"
out=$(HARNESS="$T/ro" PATH="$RPATH" "$H0/bin/gh-rest-shim" pr view 1 2>"$T/ro.err"); rc=$?
eq "E gh-rest-shim on an unwritable harness" "$out rc=$rc" "THROUGH rc=0"
eq "E gh-rest-shim stderr" "$(cat "$T/ro.err")" ""
out=$(HARNESS="$T/ro" PATH="$H0/bin/gh-ledger:$RPATH" GH_TOKEN=x "$H0/bin/gh-ledger/gh" pr list 2>"$T/ro.err"); rc=$?
eq "E gh-ledger on an unwritable harness" "$out rc=$rc" "THROUGH rc=0"
eq "E gh-ledger stderr" "$(cat "$T/ro.err")" ""

# ── X: GH_SHIM_OFF must be exactly 1 ─────────────────────────────────────────
fresh
eq "X GH_SHIM_OFF=true still translates" "$(export GH_SHIM_OFF=true; site 4)" on
fresh
eq "X GH_SHIM_OFF=1 passes through" "$(export GH_SHIM_OFF=1; site 4)" off

# ── L0: no lib beside the file — the fallback answers, nothing exits ────────
mkdir -p "$T/solo" "$T/solo2/bin/gh-ledger" "$T/solo2/flags"
cp "$DIR/bin/lib/hotfix-lib.sh" "$T/solo/"
cp "$DIR/bin/gh-ledger/gh" "$T/solo2/bin/gh-ledger/gh"
fresh; touch "$H0/flags/hotfix-lane-off"
eq "L0 solo hotfix-lib, file" "$(HARNESS="$T/other" bash -c '. "$2/hotfix-lib.sh"; hotfix_lane_on "$1"; echo "rc=$?"' _ "$H0" "$T/solo" 2>/dev/null | tr '\n' ' ')" "0 rc=0 "
fresh
eq "L0 solo hotfix-lib, no file" "$(HARNESS="$T/other" bash -c '. "$2/hotfix-lib.sh"; hotfix_lane_on "$1"; echo "rc=$?"' _ "$H0" "$T/solo" 2>/dev/null | tr '\n' ' ')" "1 rc=0 "
for st in file nofile; do
  rm -f "$T/solo2/flags/gh-ledger-off" "$GH_STUB_LOG"
  [ "$st" = file ] && touch "$T/solo2/flags/gh-ledger-off"
  out=$(env -u HARNESS PATH="$T/solo2/bin/gh-ledger:$RPATH" GH_TOKEN=x "$T/solo2/bin/gh-ledger/gh" pr list 2>/dev/null); rc=$?
  eq "L0 solo gh-ledger/gh ($st) prints THROUGH, rc 0" "$out rc=$rc" "THROUGH rc=0"
  dbg=$(grep -c '^GH_DEBUG=api$' "$GH_STUB_LOG" 2>/dev/null); dbg=${dbg:-0}
  if [ "$st" = file ]; then eq "L0 solo gh-ledger/gh file: no ledger" "$dbg" 0
  else [ "$dbg" -gt 0 ] && ok || bad "L0 solo gh-ledger/gh no file: ledger path did not run"; fi
done

# ── C1 / O1 / X1: the registry over this slice's files ──────────────────────
FILES=(bin/lib/gate-self-comments.sh bin/gh-ledger/gh bin/gh-ledger-push.sh bin/gh-rest-shim
       bin/lib/hotfix-lib.sh bin/model-prices-sync.sh)
for f in "${FILES[@]}"; do
  lits=$(grep -vE '^[[:space:]]*#' "$DIR/$f" | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort -u)
  [ -n "$lits" ] || { bad "C1 $f reads no switch with lane_switch"; continue; }
  for n in $lits; do
    c="$DIR/catalog/switches.d/$n.json"
    if [ "$(jq -r '.name // empty' "$c" 2>/dev/null)" = "$n" ] \
       && jq -e --arg f "$f" '.readers | index($f)' "$c" >/dev/null 2>&1 \
       && jq -e '.box_scoped == true and (.what | length > 0)' "$c" >/dev/null 2>&1; then ok
    else bad "C1 $f: lane_switch $n has no catalog/switches.d/$n.json naming it with $f in readers"; fi
  done
  low=$(head -1 <<<"$lits")
  case "$low" in [g-o]*) ok ;; *) bad "O1 $f: lowest switch '$low' is outside g-o" ;; esac
done
for n in "${NAMES[@]:1}"; do
  hits=$(grep -rnE "(touch|rm -[a-z]*f?|flag_set|flag_clear)[^;|&]*$n|>[[:space:]]*\"?[^[:space:]]*flags/$n" \
           "$DIR/bin" "$DIR/fly" "$DIR/worker" "$DIR/console-ui/src" 2>/dev/null \
         | grep -v node_modules | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
  [ -z "$hits" ] && ok || bad "X1 a code line writes flags/$n: $hits"
done

echo "switch-convert.bh-2408-gh-wrappers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
