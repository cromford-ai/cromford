#!/bin/bash
# tests/br-verify-baseline.bh-9437-test.sh — a fix round's verify is scored
# against the same commands on current main, the next round reads the last
# round's red verify, and a review park gets BR_REVIEW_FIX_ROUNDS rounds
# (BH-9437 item 3). bin/blocked-resolver.d/bh-9437-verify-baseline.sh:
#   brlad_fail_ids          the failure identities of one verify step
#   brlad_vb_rescore        rc 0 = every red step is red on main with the same
#                           failures, so the round counts as verified
#   brlad_prev_verify_brief the last round's red verify, for the next brief
#   brlad_round_failed      the review park's rounds-remaining exit
#   §V1 branch {x} red, main {x, y} red -> rc 0 and a BASELINE line
#   §V2 branch {x, y} vs main {x} -> rc 1
#   §V3 a red step with no parseable failure -> rc 1
#   §V4 main green -> rc 1
#   §V5 a closure-lint red beside the unit red -> rc 1
#   §V6 TS2322 vs TS2345 in one file -> rc 1; the same code -> rc 0; the
#       baseline is reused for one main sha and rebuilt for a new one
#   §V7 the brief: the last round's tail after a failed round, nothing after a push
#   §V8 review park, cap 2: round 1 fails -> head un-marked, rc 0; round 2
#       fails -> rc 1 (the terminal runs); agent rc 124 -> rc 1; external -> rc 1
#   §V9 the driver call sites
#   §K  BR_VERIFY_ON_MAIN=0 -> rc 1; BR_VERIFY_PREV_BYTES=0 -> no brief
#   §Z  0 vendor calls
# The baseline runs in a real scratch git repo with a stub npm (no network).
# Run: bash tests/br-verify-baseline.bh-9437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-verify-baseline.bh-9437: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$DIR/tests/lib/br-9437.sh" || exit 1
FRAG="$DIR/bin/blocked-resolver.d/bh-9437-verify-baseline.sh"
[ -r "$FRAG" ] && ok || bad "V0 $FRAG is missing"
for k in BR_VERIFY_ON_MAIN BR_VERIFY_BASELINE_TIMEOUT_S BR_VERIFY_PREV_BYTES; do
  [ -r "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/$k.json" ] && ok || bad "V0 the $k knob row is missing"
done

bl9_extract "$DIR" "$T" br_fix_round br_fix_cap br_cap_key br_rkey br_file br_load br_save br_record br_num \
  br_json_edit br_set_field br_has_field_value br_push_field || exit 1
bl9_tripwire "$T" || exit 1
# The stub npm: `npm run <script>` / `npm test` prints <script>.out from the
# tree it runs in and exits with <script>.rc. Every call is logged.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
s="\$1"; [ "\$s" = run ] && s="\$2"
printf '%s %s\n' "\$PWD" "\$s" >> "$T/npm.txt"
[ -f "\$s.out" ] && cat "\$s.out"
exit "\$(cat "\$s.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/fakebin/npm"
export GIT_CONFIG_GLOBAL="$T/gitconfig"; printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
ORIGIN="$T/origin.git"; SEED="$T/seed"; WT="$T/wt"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"; git -C "$SEED" remote add origin "$ORIGIN"
printf '{"scripts":{"typecheck":"tsc","test:unit":"vitest"}}\n' > "$SEED/package.json"
# main <unit.out> <unit.rc> <typecheck.out> <typecheck.rc> — a new commit on origin main
main() { printf '%s' "$1" > "$SEED/test:unit.out"; printf '%s' "$2" > "$SEED/test:unit.rc"
  printf '%s' "$3" > "$SEED/typecheck.out"; printf '%s' "$4" > "$SEED/typecheck.rc"
  git -C "$SEED" add -A; MAINN=$((${MAINN:-0} + 1)); git -C "$SEED" commit -qm "main $MAINN" --allow-empty; git -C "$SEED" branch -M main; git -C "$SEED" push -q -f origin main
  git -C "$WT" fetch -q origin 2>/dev/null; }
main "" 0 "" 0
git clone -q "$ORIGIN" "$WT" || exit 1
git -C "$WT" checkout -q -b ticket/tp-9
HH=$(printf 'e%.0s' {1..40})
ST="$T/st"; mkdir -p "$ST/tproj"
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$T/h"; ST="$ST"; LOG="$T/say.txt"; OBSERVE=0; REPOS="$T/repos"
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
br_wt_drop() { printf 'wt_drop %s\n' "\$*" >> "$T/drops.txt"; }
mc_git_auth_clear() { :; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
. "$T/fns.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
OUT="$T/fix-verify.txt"
# verify <unit lines> <unit exit> [<typecheck lines> <typecheck exit>] [<extra marker line>] — the round's $out
verify() { { echo "== typecheck =="; [ -n "${3:-}" ] && printf '%s\n' "$3"; echo "TYPECHECK_EXIT: ${4:-0}"
  echo "== unit =="; [ -n "$1" ] && printf '%s\n' "$1"; echo "UNIT_EXIT: $2"
  echo "== scratch-closure =="; echo "CLOSURE_LINT_EXIT: ${5:-skipped (no pack)}"; } > "$OUT"; }
RESCORE() { ( . "$T/drv.sh"; brlad_vb_rescore tproj tproj-TP-9 "$WT" "$OUT" origin/main ); }
NPM() { cat "$T/npm.txt" 2>/dev/null | grep -c .; }

# ── §V1: the same failure on main counts as verified ──────────────────────
X=' FAIL  src/a.test.ts > suite > x'; Y=' FAIL  src/b.test.ts > y'
main "$X"$'\n'"$Y"$'\n'' Test Files  2 failed' 1 "" 0
verify "$X"$'\n'' Test Files  1 failed (1)' 1
RESCORE; RC=$?
[ "$RC" = 0 ] && ok || bad "V1 a unit failure red on main too must count as verified, rc $RC ($(tail -3 "$OUT"))"
grep -qE '^BASELINE: unit red on origin/main [0-9a-f]{8} with the same 1 failure' "$OUT" && ok || bad "V1 a BASELINE line per red step: $(grep BASELINE "$OUT")"
[ "$(head -1 "$ST/tproj/tproj-TP-9.verify-baseline.txt")" = "MAIN $(git -C "$WT" rev-parse origin/main)" ] && ok || bad "V1 the baseline file is keyed on the main sha"
[ "$(git -C "$WT" worktree list --porcelain | grep -c '^worktree ')" = 1 ] && ok || bad "V1 the baseline worktree is removed: $(git -C "$WT" worktree list)"
# jest and node:test shapes parse too
J=$'  \xe2\x9c\x95 adds two numbers (5 ms)'
main "$J"$'\n'"not ok 3 - tap case"$'\n' 1 "" 0
verify "$J"$'\n'"not ok 3 - tap case # time=3ms" 1
RESCORE; RC=$?
[ "$RC" = 0 ] && ok || bad "V1 jest ✕ (durations stripped) and TAP not ok lines parse, rc $RC (ids: $( . "$T/drv.sh"; brlad_fail_ids "$OUT" unit | tr '\n' '|'))"

# ── §V2: a failure only the branch has stays red ──────────────────────────
main "$X" 1 "" 0
verify "$X"$'\n'"$Y" 1
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V2 branch {x,y} vs main {x} stays red, rc $RC"
grep -q '^BASELINE: unit' "$OUT" && bad "V2 no BASELINE line when the branch adds a failure" || ok

# ── §V3: nothing parseable stays red ──────────────────────────────────────
verify "Segmentation fault" 1
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V3 an unparseable red step stays red, rc $RC"

# ── §V4: main green ───────────────────────────────────────────────────────
main "" 0 "" 0
verify "$X" 1
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V4 main green: the branch caused it, rc $RC"

# ── §V5: another red marker ───────────────────────────────────────────────
main "$X" 1 "" 0
verify "$X" 1 "" 0 1
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V5 a closure-lint red beside a baseline unit red stays red, rc $RC"
verify "$X" 1; echo "AUTHOR_MISMATCH: abc" >> "$OUT"
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V5 an author mismatch stays red, rc $RC"

# ── §V6: tsc codes, and the cache ─────────────────────────────────────────
main "" 0 "src/a.ts(3,5): error TS2345: Argument of type x." 2
verify "" 0 "src/a.ts(3,5): error TS2322: Type x is not assignable." 2
RESCORE; RC=$?
[ "$RC" = 1 ] && ok || bad "V6 TS2322 on the branch vs TS2345 on main is a new failure, rc $RC"
N0=$(NPM)
verify "" 0 "src/a.ts:9:1 - error TS2345: Argument of type y." 2
RESCORE; RC=$?
[ "$RC" = 0 ] && ok || bad "V6 the same file and code (another line, the pretty shape) is the main failure, rc $RC"
[ "$(NPM)" = "$N0" ] && ok || bad "V6 the baseline is reused for the same main sha (npm calls $N0 -> $(NPM))"
main "" 0 "src/a.ts(3,5): error TS2345: Argument of type x." 2
verify "" 0 "src/a.ts(3,5): error TS2345: Argument of type x." 2
RESCORE
[ "$(NPM)" -gt "$N0" ] && ok || bad "V6 a new main sha rebuilds the baseline (npm calls $N0 -> $(NPM))"
# a baseline that cannot be built fails closed
verify "$X" 1
( . "$T/drv.sh"; brlad_vb_rescore tproj tproj-TP-9 "$WT" "$OUT" origin/nope ); RC=$?
[ "$RC" = 1 ] && grep -q '^BASELINE: could-not-run' "$OUT" && ok || bad "V6 an unbuildable baseline: rc 1 and a could-not-run line (rc $RC)"

# ── §V7: the next round reads the last red verify ─────────────────────────
mkdir -p "$ST/tproj"
jq -nc --arg h "$HH" '{project:"tproj",rkey:"tproj-TP-9",fixrounds:1,review_fix_heads:[$h],outcome:"",attempts:[]}' > "$ST/tproj/tproj-TP-9.json"
verify "$X"$'\n'"THE-LAST-LINE-OF-ROUND-1" 1
( . "$T/drv.sh"; brlad_round_failed tproj tproj-TP-9 o-r-9 review-changes-requested https://github.com/o/r/pull/9 "$HH" 0 "$WT" 0 "$OUT" )
B=$( . "$T/drv.sh"; brlad_prev_verify_brief tproj tproj-TP-9 )
case "$B" in *"PRODUCED NO VERIFIED COMMIT"*THE-LAST-LINE-OF-ROUND-1*) ok ;; *) bad "V7 the brief carries the last round's verify tail: '$B'" ;; esac
B=$( export BR_VERIFY_PREV_BYTES=0; . "$T/drv.sh"; brlad_prev_verify_brief tproj tproj-TP-9 )
[ -z "$B" ] && ok || bad "K BR_VERIFY_PREV_BYTES=0 gives no brief"
( . "$T/drv.sh"; _jobs_req() { return 0; }; brlad_rereview_ask tproj tproj-TP-9 o/r https://github.com/o/r/pull/9 "$HH" review-changes-requested ) >/dev/null 2>&1
B=$( . "$T/drv.sh"; brlad_prev_verify_brief tproj tproj-TP-9 )
[ -z "$B" ] && ok || bad "V7 a green push clears the brief: '$B'"

# ── §V8: the review park's real cap ───────────────────────────────────────
RF() { ( . "$T/drv.sh"; brlad_round_failed tproj tproj-TP-9 o-r-9 "${1:-review-changes-requested}" https://github.com/o/r/pull/9 "$HH" "${2:-0}" "$WT" "${3:-0}" "$OUT" ); }
recset() { jq -nc --arg h "$HH" --argjson f "$1" '{project:"tproj",rkey:"tproj-TP-9",fixrounds:$f,review_fix_heads:[$h],outcome:"",attempts:[]}' > "$ST/tproj/tproj-TP-9.json"; }
: > "$T/say.txt"; : > "$T/drops.txt"
recset 1; RF review-changes-requested 0 0; RC=$?
[ "$RC" = 0 ] && ok || bad "V8 round 1 of 2 failed: rc 0 (round 2 next tick), got $RC"
[ "$(jq -c '.review_fix_heads' "$ST/tproj/tproj-TP-9.json")" = '[]' ] && ok || bad "V8 the head is un-marked so round 2 can run on it: $(jq -c .review_fix_heads "$ST/tproj/tproj-TP-9.json")"
grep -q 'fix round 2 next tick' "$T/say.txt" && ok || bad "V8 the log says round 2 is next: $(tail -1 "$T/say.txt")"
[ "$(grep -c . "$T/drops.txt")" = 1 ] && ok || bad "V8 the worktree is dropped once"
recset 2; RF review-changes-requested 0 1; RC=$?
[ "$RC" = 1 ] && ok || bad "V8 round 2 of 2 failed: rc 1 (the terminal runs), got $RC"
[ "$(jq -c '.review_fix_heads | length' "$ST/tproj/tproj-TP-9.json")" = 1 ] && ok || bad "V8 the last round keeps its mark"
recset 1; RF review-changes-requested 124 0; RC=$?
[ "$RC" = 1 ] && ok || bad "V8 an agent timeout (rc 124) is left to BH-9404, rc $RC"
recset 1; ( export BR_XPR_ACTIVE=1; RF review-changes-requested 0 0 ); RC=$?
[ "$RC" = 1 ] && ok || bad "V8 an external PR keeps its own wait line, rc $RC"
recset 1; RF red-twice 0 0; RC=$?
[ "$RC" = 1 ] && ok || bad "V8 a ladder reason keeps the driver's own exit, rc $RC"
recset 1; ( export BR_REVIEW_FIX_ROUNDS=1; RF review-changes-requested 0 0 ); RC=$?
[ "$RC" = 1 ] && ok || bad "V8 BR_REVIEW_FIX_ROUNDS=1: the first failed round is the terminal, rc $RC"

# ── §V9: the driver call sites ────────────────────────────────────────────
BODY=$(bl9_fn_body "$T" br_fix_round)
LB=$(grep -n '# <<< br ci-local brief' <<<"$BODY" | cut -d: -f1); LPB=$(grep -n 'brlad_prev_verify_brief' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LPB" ] && [ "$LPB" -gt "$LB" ] && [ "$LPB" -lt "$(grep -n '^  prompt="FIX ROUND' <<<"$BODY" | cut -d: -f1)" ] && ok || bad "V9 the previous-verify brief is added after the ci-local brief and before the prompt (${LPB:-absent})"
LV=$(grep -n 'grep -qE .\^(TYPECHECK|UNIT|CLOSURE_LINT)_EXIT' <<<"$BODY" | head -1 | cut -d: -f1); LR=$(grep -n 'brlad_vb_rescore' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LR" ] && [ "$LR" = $((LV + 1)) ] && ok || bad "V9 the re-score sits right after the verify grep (verify $LV, rescore ${LR:-absent})"
LT=$(grep -n 'if \[ "\$reason" != review-changes-requested \] && \[ "\$((n+1))" -lt "\$cap" \]; then' <<<"$BODY" | head -1 | cut -d: -f1); LF=$(grep -n 'brlad_round_failed' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LF" ] && [ "$LF" = $((LT - 1)) ] && ok || bad "V9 brlad_round_failed sits right before the rounds-remaining test (test $LT, hook ${LF:-absent})"

# ── §K: the knob ──────────────────────────────────────────────────────────
main "$X" 1 "" 0
verify "$X" 1
( export BR_VERIFY_ON_MAIN=0; RESCORE ); RC=$?
[ "$RC" = 1 ] && ok || bad "K BR_VERIFY_ON_MAIN=0: no re-score, rc $RC"

# ── §Z: no vendor ─────────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"

echo "br-verify-baseline.bh-9437: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
