#!/bin/bash
# tests/closeout-owed-gate.bh-9879-test.sh — BH-9879 item 2: an unmarked
# PR_CREATED / PR_MERGED RESULT wakes the triage gate and reaches the sweep,
# also when the project has a ready queue and the key is not in the
# triage-state list.
#
# THE INCIDENT. project-3 TK-747 (2026-11-21) was staged as
# builds/project-3-TK-747-remote<ts>/ with `PR_CREATED https://… | MIGRATION GATE: …`
# and no COMMENTED. project-3 always has a ready queue, so bin/triage-gate.sh step 2
# always exited first: `RUN queue-pending` on the staging tick (a scope with no
# result dirs) and `SKIP queue-unchanged` for the next 45 minutes. Step 3, the
# results sweep, was never reached.
#
# THE FIX: step 1f (bin/lib/closeout-owed.sh) answers `RUN results-sweep`
# before step 2 when a young unmarked PR close-out is owed, under step 3's own
# sweepfp brake.
#   G1-G4  the REAL bin/triage-gate.sh, gh stubbed (tests/ready-queue-scope §G)
#   D1-D13 co_owed_dirs, one decision-table row each
#   K1-K2  knob fallbacks and the off switch
#   S1-S4  the sweep scope and the triage-state skip reach the key
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/closeout-owed-gate.bh-9879-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date +%s)
unset CLOSEOUT_OWED_WAKE CLOSEOUT_OWED_MAX_AGE_S CLOSEOUT_OWED_BRAKE_S

# ── the scratch harness: the real gate, a GitHub-issues project ────────────
G="$T/g"; P=cromford
mkdir -p "$G/bin/lib" "$G/logs" "$G/state" "$G/plans" "$G/flags" "$G/env" \
         "$G/builds" "$G/locks" "$G/prompts" "$T/fakebin" "$T/ctl"
scratch_install_closure bin/triage-gate.sh "$G" >/dev/null || bad "setup: cannot install the gate closure"
[ -r "$G/bin/lib/closeout-owed.sh" ] || bad "setup: the gate closure has no bin/lib/closeout-owed.sh"
for f in fleet-conf.sh project-of.sh; do cp "$DIR/bin/$f" "$G/bin/"; done
export FLEET_CONF="$G/fleet.conf"
printf 'cromford o/bh - - 3 small 1.1.1.1\n' > "$FLEET_CONF"
echo 'setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > x' > "$G/prompts/$P.md"
export GH_CTL="$T/ctl"
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift; inc=0; path=""
while [ $# -gt 0 ]; do
  case "$1" in -i) inc=1; shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) path="$1"; break ;; esac
done
key=other
case "$path" in repos/*/pulls*) key=pulls ;; repos/*/issues*) key=issues ;; esac
body=""; [ -f "$GH_CTL/$key.body" ] && body=$(cat "$GH_CTL/$key.body")
[ "$inc" = 1 ] && printf 'HTTP/2.0 200\r\ncontent-type: application/json\r\n\r\n'
[ -n "$body" ] && printf '%s\n' "$body"
exit 0
GH
chmod +x "$T/fakebin/gh"
printf '%s' '[{"number":7,"state":"open","title":"t","body":"b","comments":1,"updated_at":"2026-09-19T10:00:00Z","labels":[]}]' > "$T/ctl/issues.body"
printf '%s' '[]' > "$T/ctl/pulls.body"

# rm_each <path>... — scratch_rm every path a glob expanded to
rm_each() { local x; for x in "$@"; do scratch_rm "$x" || return 1; done; }
gate() { OUT=$(HARNESS="$G" PATH="$T/fakebin:$PATH" "$G/bin/triage-gate.sh" "$P" ${1:+"$1"} 2>/dev/null); }
# reset — a seeded board, a fresh full-sweep clock, one ready queue line, no dirs
reset() {
  rm_each "$G/state/$P".* "$G/builds/"*
  printf 'BH-9 9 — ready project=cromford\n' > "$G/logs/READY-QUEUE.log"
  gate --seed
  printf '%s\n' "$NOW" > "$G/state/$P.gate-meta"
}
# res <dir> <result-line> [age-seconds]
res() {
  mkdir -p "$G/builds/$1"; printf '%s\nline two\n' "$2" > "$G/builds/$1/RESULT"
  touch -d "@$(( NOW - ${3:-60} ))" "$G/builds/$1/RESULT"
}
FR='PR_CREATED https://github.com/o/r/pull/1269 | large diff | MIGRATION GATE: apply 0042 by hand'
D747="$P-BH-747-remote20261121080600"
step2() { case "$1" in "SKIP queue-unchanged"*|"RUN queue-pending"|"SKIP queue-gates-unchanged"*) return 0 ;; esac; return 1; }

# ── G1: the repro — a ready queue and a staged unmarked PR_CREATED dir ─────
reset
res "$D747" "$FR"
gate; O1=$OUT; gate; O2=$OUT
[ "$O1" = "RUN results-sweep" ] && ok \
  || bad "G1: the first gate call after the dir is staged must RUN results-sweep, got: '$O1' then '$O2'"
[ -s "$G/state/$P.sweepfp" ] && ok || bad "G1: step 1f must write the sweepfp brake"

# ── G2: same set inside the brake → today's step-2 answer ──────────────────
step2 "$O2" && ok || bad "G2: the second call (brake held) must be step 2's answer, got: $O2"
gate
step2 "$OUT" && ok || bad "G2: a third call must still be step 2's answer, got: $OUT"
[ "$OUT" != "RUN results-sweep" ] && ok || bad "G2: no second RUN results-sweep inside the brake"

# ── G3: brake stamp older than CLOSEOUT_OWED_BRAKE_S → wakes again ─────────
printf '%s\n%s\n' "$(head -1 "$G/state/$P.sweepfp")" "$(( NOW - 3000 ))" > "$G/state/$P.sweepfp"
gate
[ "$OUT" = "RUN results-sweep" ] && ok || bad "G3: an expired brake must RUN results-sweep again, got: $OUT"

# ── G4: the dir marked COMMENTED → step 2's answer ─────────────────────────
reset
res "$D747" "$FR"; touch "$G/builds/$D747/COMMENTED"
gate
step2 "$OUT" && ok || bad "G4: a COMMENTED dir must not wake step 1f, got: $OUT"

# ── K2: CLOSEOUT_OWED_WAKE=0 → step 2's answer ─────────────────────────────
reset
res "$D747" "$FR"
OUT=$(CLOSEOUT_OWED_WAKE=0 HARNESS="$G" PATH="$T/fakebin:$PATH" "$G/bin/triage-gate.sh" "$P" 2>/dev/null)
step2 "$OUT" && ok || bad "K2: CLOSEOUT_OWED_WAKE=0 must give step 2's answer, got: $OUT"
[ ! -e "$G/state/$P.sweepfp" ] && ok || bad "K2: switched off, step 1f must write no sweepfp"

# ── D1-D13: co_owed_dirs ───────────────────────────────────────────────────
owed() { HARNESS="$G" bash -c '. "$HARNESS/bin/lib/closeout-owed.sh"; '"${1:-}"' co_knobs cromford; co_owed_dirs "$HARNESS" cromford' 2>/dev/null; }
isowed() { grep -qx "$G/builds/$1" <<<"$2"; }
rm_each "$G/builds/"*
res "$P-BH-801-remote1" "$FR"                                                    # D1
res "$P-BH-802-remote1" 'PR_MERGED https://github.com/o/r/pull/7'                # D2
res "pool-$P-BH-803-20261121" 'PR_CREATED https://github.com/o/r/pull/803'       # D3
res "$P-BH-804-remote1" 'PR_CREATED https://github.com/o/r/pull/804 | CLOSEOUT-NOT-POSTED: rc=4 client-court, not posting'  # D4
res "$P-BH-805-remote1" "$FR"; touch "$G/builds/$P-BH-805-remote1/COMMENTED"     # D5
res "$P-BH-806-remote1" 'PR_CREATED https://github.com/o/r/pull/806 | CLOSED-OUT: the builder posted the board close-out on x'  # D6
res "$P-BH-807-remote1" 'RESULT_UNVERIFIED PR_CREATED https://github.com/o/r/pull/807'  # D7
res "$P-BH-808-remote1" 'PR_CREATED'                                             # D8
res "$P-BH-809-remote1" 'BUILD_DEFERRED slots full'                              # D9
res "$P-BH-810-remote1" 'PLAN_BLOCKED see plan.md'                               # D10
res "$P-BH-811-remote1" 'PR_CREATED https://github.com/o/r/pull/811' 30000       # D11 (> 6 h)
res "$P-BH-812-remote1" 'PR_MERGED https://github.com/o/r/pull/812'              # D12 (prod red)
res "other-$P-BH-813-remote1" 'PR_CREATED https://github.com/o/r/pull/813'       # D13 (another prefix)
res "cromfordx-BH-814-remote1" 'PR_CREATED https://github.com/o/r/pull/814' # D13b
LIST=$(owed 'prod_red_defers_dir() { case "$3" in *BH-812*) return 0 ;; esac; return 1; };')
for k in "$P-BH-801-remote1" "$P-BH-802-remote1" "pool-$P-BH-803-20261121" "$P-BH-804-remote1"; do
  isowed "$k" "$LIST" && ok || bad "D1-D4: $k must be owed, list: $LIST"
done
for k in 805 806 807 808 809 810 811 812; do
  isowed "$P-BH-$k-remote1" "$LIST" && bad "D5-D12: BH-$k must NOT be owed, list: $LIST" || ok
done
grep -q 'BH-81[34]' <<<"$LIST" && bad "D13: a dir of another project prefix must not be owed: $LIST" || ok
[ "$(grep -c . <<<"$LIST")" = 4 ] && ok || bad "D: exactly 4 dirs owed, got: $LIST"
# without the prod-red stub (no red snapshot) a PR_MERGED dir is owed
isowed "$P-BH-812-remote1" "$(owed)" && ok || bad "D12b: with production not red, PR_MERGED is owed"
# the age knob moves the bound
LIST=$(CLOSEOUT_OWED_MAX_AGE_S=40000 owed)
isowed "$P-BH-811-remote1" "$LIST" && ok || bad "D11b: CLOSEOUT_OWED_MAX_AGE_S=40000 must take a 30000 s old dir"

# ── K1: fallbacks ──────────────────────────────────────────────────────────
kn() { HARNESS="$G" bash -c '. "$HARNESS/bin/lib/closeout-owed.sh"; co_knobs cromford; echo "$_CO_WAKE $_CO_MAX_AGE $_CO_BRAKE"' 2>/dev/null; }
[ "$(kn)" = "1 21600 2700" ] && ok || bad "K1: code fallbacks must be '1 21600 2700', got: $(kn)"
[ "$(CLOSEOUT_OWED_WAKE=x CLOSEOUT_OWED_MAX_AGE_S=abc CLOSEOUT_OWED_BRAKE_S=-5 kn)" = "1 21600 2700" ] && ok \
  || bad "K1: junk values must fall back, got: $(CLOSEOUT_OWED_WAKE=x CLOSEOUT_OWED_MAX_AGE_S=abc CLOSEOUT_OWED_BRAKE_S=-5 kn)"
[ "$(CLOSEOUT_OWED_WAKE=0 CLOSEOUT_OWED_MAX_AGE_S=5 CLOSEOUT_OWED_BRAKE_S=99999 kn)" = "0 600 14400" ] && ok \
  || bad "K1: values must clamp to 600..604800 and 600..14400, got: $(CLOSEOUT_OWED_WAKE=0 CLOSEOUT_OWED_MAX_AGE_S=5 CLOSEOUT_OWED_BRAKE_S=99999 kn)"

# ── S1: the sweep scope lists the dir ──────────────────────────────────────
rm_each "$G/builds/"*; res "$D747" "$FR"
LIST=$( HARNESS="$G" PROJECT="$P"; . "$DIR/bin/lib/rt/scope.sh" 2>/dev/null; rt_unswept_dirs )
[ "$LIST" = "$G/builds/$D747 :: $FR" ] && ok || bad "S1: rt_unswept_dirs must list the TK-747 dir with its first line, got: $LIST"

# ── S2-S4: the triage-state skip never drops a result unit ─────────────────
printf 'BH-747\tresult\t%s\nBH-9\tboard\tx\n' "$G/builds/$D747" > "$T/units.tsv"
sk() { HARNESS="$G" bash -c '. "'"$DIR"'/bin/lib/triage-state.sh"; TS_ENFORCING=1; TS_SKIPSET="$1"; ts_unit_skip "$2" "$3"' _ "$1" "$T/units.tsv" "$2" >/dev/null 2>&1; echo $?; }
[ "$(sk ' ' BH-747)" = 1 ] && ok || bad "S2: a key not in TS_SKIPSET with a result unit must dispatch (rc 1)"
[ "$(sk ' BH-747 ' BH-747)" = 1 ] && ok || bad "S3: a key in TS_SKIPSET with a result unit must still dispatch (rc 1)"
[ "$(sk ' BH-9 ' BH-9)" = 0 ] && ok || bad "S4: a key in TS_SKIPSET with only a board unit must be skipped (rc 0)"

echo "closeout-owed-gate.bh-9879: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
