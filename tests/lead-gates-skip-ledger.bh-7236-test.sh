#!/bin/bash
# tests/lead-gates-skip-ledger.bh-7236-test.sh — the worklist skip ledger
# (lgs_skip_once in bin/lib/lead-gates.d/05-skip-ledger.sh) writes a skip line
# once per (PR, head, class). The skips come from the retry gate
# (bin/lib/lead-gates.d/95-retry-reclaim.sh). bin/lead-review.sh tick runs
# WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh and lead-gates-fixture.bh-5876.sh.
#   D2  `[skip failed-exhausted]` on a head, then a second tick with another
#       failed reason on the same head: still one skip line for the head.
#   D3  `[skip failed-exhausted]` on a head, then `[skip env-failed]` on the
#       same head: two skip lines, the second one env-failed.
#   D4  `[skip failed-exhausted]` on a head, then the same class on a new head
#       of the PR: a second line, and it names the new head.
#   M1  a ledger copy whose marker drops the class: D3 goes red (D1).
#   M2  a ledger copy whose marker drops the head: D4 goes red (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-skip-ledger.bh-7236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
LEDGER="$H/bin/lib/lead-gates.d/05-skip-ledger.sh"
[ -r "$LEDGER" ] && [ -r "$H/bin/lib/lead-gates.d/95-retry-reclaim.sh" ] && ok || bad "setup: 05-skip-ledger.sh or 95-retry-reclaim.sh not installed"
cp "$LEDGER" "$T/05.orig"
BHR=example-org/cromford
H1=$(printf '%040d' 101); H2=$(printf 'f%039d' 102)
FR="$H/state/lead-review-enqueue/failed-retry.tsv"
LANDJ="$H/catalog/lanes.d/lead-review-land.json"
# exhausted <head> <detail> — PR 101 at <head>: one failed row, two resets spent
exhausted() {
  local e
  jq -nc --arg h "$1" --arg d "$2" '[{id:"r-s1", repo:"example-org/cromford", pr:101, head_sha:$h, status:"failed",
    detail:$d, created_at:"2026-10-10 03:00:00"}]' > "$FX/failed.json"
  mkdir -p "${FR%/*}"; e=$(( $(date +%s) - 600 ))
  printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$e" "$BHR" 101 "$1" r-s1 x "$((e + 60))" "$BHR" 101 "$1" r-s1 x >> "$FR"
}
# one — a clean state with PR 101 on the worklist at H1, no land-lane owner
one() { lg6_reset; rm -f "$LANDJ"; lgf_needs "101:$H1"; }
skipn() { lwf_cnt "\\[skip [a-z-]*\\] $BHR#101 @${1:0:12} " "$L"; }
allskips() { lwf_cnt "\\[skip [a-z-]*\\] $BHR#101 " "$L"; }

d2() { one; exhausted "$H1" "review-failed: timeout"; lwf_tick; rm -f "$FX/failed.json"; exhausted "$H1" "review-failed: crash"; lwf_tick; }
d2_ok() { [ "$(skipn "$H1")" = 1 ] && [ "$(lg6_skips failed-exhausted)" = 1 ]; }
d3() {
  one; exhausted "$H1" "review-failed: timeout"; lwf_tick
  printf '{"id":"lead-review-land","knobs":[{"env":"LEAD_REVIEW_ENV_RETRY_MAX","default":2}]}\n' > "$LANDJ"
  jq -nc --arg h "$H1" '[{id:"r-s1", repo:"example-org/cromford", pr:101, head_sha:$h, status:"failed",
    detail:"empty", created_at:"2026-10-10 03:00:00"}]' > "$FX/failed.json"
  lwf_tick
}
d3_ok() {
  [ "$(skipn "$H1")" = 2 ] && [ "$(lg6_skips failed-exhausted)" = 1 ] && [ "$(lg6_skips env-failed)" = 1 ] \
    && grep '\[skip ' "$L" | tail -1 | grep -qF "[skip env-failed] $BHR#101 @${H1:0:12} "
}
d4() { one; exhausted "$H1" "review-failed: timeout"; lwf_tick; lgf_needs "101:$H2"; exhausted "$H2" "review-failed: timeout"; lwf_tick; }
d4_ok() {
  [ "$(skipn "$H1")" = 1 ] && [ "$(skipn "$H2")" = 1 ] && [ "$(lg6_skips failed-exhausted)" = 2 ] \
    && grep '\[skip ' "$L" | tail -1 | grep -qF "[skip failed-exhausted] $BHR#101 @${H2:0:12} "
}

# ── D2: a changed reason on the same head and class stays quiet ──
d2
[ "$RC" = 0 ] && ok || bad "D2 rc=$RC: $(cat "$T/out")"
[ "$(skipn "$H1")" = 1 ] && ok || bad "D2 skip lines for the head=$(skipn "$H1") (want 1): $(grep skip "$L")"
[ "$(lg6_skips failed-exhausted)" = 1 ] && ok || bad "D2 failed-exhausted lines=$(lg6_skips failed-exhausted)"
grep -qF 'review-failed: crash' "$L" && bad "D2 the changed reason was written: $(grep -F crash "$L")" || ok
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "D2 a job for an exhausted head"
d2_ok && ok || bad "D2 d2_ok"

# ── D3: a new class on the same head is written ──
d3
[ "$(skipn "$H1")" = 2 ] && ok || bad "D3 skip lines for the head=$(skipn "$H1") (want 2): $(grep skip "$L")"
[ "$(lg6_skips env-failed)" = 1 ] && ok || bad "D3 env-failed lines=$(lg6_skips env-failed): $(cat "$L")"
grep '\[skip ' "$L" | tail -1 | grep -qF "[skip env-failed] $BHR#101 @${H1:0:12} " && ok || bad "D3 the last skip line is not env-failed on the head: $(grep skip "$L")"
d3_ok && ok || bad "D3 d3_ok"

# ── D4: a new head is written ──
d4
[ "$(allskips)" = 2 ] && ok || bad "D4 skip lines for #101=$(allskips) (want 2): $(grep skip "$L")"
[ "$(skipn "$H2")" = 1 ] && ok || bad "D4 no skip line names the new head: $(grep skip "$L")"
grep '\[skip ' "$L" | tail -1 | grep -qF "[skip failed-exhausted] $BHR#101 @${H2:0:12} " && ok || bad "D4 the last skip line is not on the new head: $(grep skip "$L")"
d4_ok && ok || bad "D4 d4_ok"

# mutate <sed expr> — the scratch ledger from the original, then the mutation; rc 0 when it changed
mutate() {
  cp "$T/05.orig" "$LEDGER"
  sed -i "$1" "$LEDGER"
  ! cmp -s "$LEDGER" "$T/05.orig"
}

# ── M1: the marker drops the class: D3 goes red ──
if mutate 's#gate-skip/\$safe-\$n-\$h12-\$class"#gate-skip/$safe-$n-$h12"#'; then
  d3; d3_ok && bad "M1 D3 stayed green with a marker that drops the class" || ok
else bad "M1 the mutation did not change the ledger"; fi

# ── M2: the marker drops the head: D4 goes red ──
if mutate 's#gate-skip/\$safe-\$n-\$h12-\$class"#gate-skip/$safe-$n-$class"#'; then
  d4; d4_ok && bad "M2 D4 stayed green with a marker that drops the head" || ok
else bad "M2 the mutation did not change the ledger"; fi
cp "$T/05.orig" "$LEDGER"

echo "lead-gates-skip-ledger.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
