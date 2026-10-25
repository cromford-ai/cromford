#!/bin/bash
# tests/br-selection-gate.bh-8062-test.sh — BH-8062 r3 (F3): a resolver fix
# round runs the selection gate in its verify step and refreshes the PR's
# selection-gate record after its push
# (bin/blocked-resolver.d/bh-8062-selection-gate.sh and its two call sites in
# bin/blocked-resolver.sh).
#
#   V1 green gate: SELECTION_GATE_EXIT: 0, and the REAL driver's verify regex
#      (read from bin/blocked-resolver.sh) does not match the block
#   V2 red gate: SELECTION_GATE_EXIT: 1 plus the suite name; the regex matches
#   V3 could-not-run and no-selection: no match
#   V4 no bin/selection-gate.sh in the worktree: skipped, the stub never ran
#   V5 SELECTION_GATE=0: skipped, the stub never ran
#   V6 a `FAIL: x` log line in the gate's output never reaches the block
#   A1 after_push with gate.txt head = the pushed head: one PATCH whose body
#      has exactly one marker, for the new head, and every other byte kept;
#      lr_gate_record answers ok for that body and head
#   A2 a body with no marker: the marker is appended, the rest kept
#   A3 gate.txt for another head, or rc 1: no PATCH
#   A4 the GET fails or answers no body: no PATCH (the body is never wiped)
#   D  both call sites are in the real driver, inside br_fix_round, in order;
#      the verify call is inside the `{ … } > "$out"` group; cutting either
#      call site fails this check (mutant)
#   M  mutants: the regex without SELECTION_GATE misses V2; a head compare
#      that ignores the head PATCHes A3
# Run: HARNESS_TEST_SANDBOX=1 bash tests/br-selection-gate.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset SELECTION_GATE SELECTION_GATE_TIMEOUT_S SELECTION_GATE_P

FRAG="$DIR/bin/blocked-resolver.d/bh-8062-selection-gate.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
[ -r "$FRAG" ] || { echo "FAIL: setup: $FRAG does not exist"; exit 1; }
# H: a scratch harness root with the real lib (the fragment sources it from $H).
mkdir -p "$T/h/logs"
for f in bin/lib/selection-gate.sh bin/lib/lead-review/gate-record.sh bin/lib/patch-same.sh bin/lib/gh-rest-var.sh; do
  scratch_install_closure "$f" "$T/h" >/dev/null || { echo "FAIL: setup: scratch_install_closure $f"; exit 1; }
done

# The driver's verify regex, read from the real driver.
RE=$(sed -n "s/^  grep -qE '\(\^(TYPECHECK[^']*\)' \"\$out\" && vrc=1$/\1/p" "$DRIVER" | head -n 1)
[ -n "$RE" ] && ok || bad "setup: no verify regex in bin/blocked-resolver.sh"

# A worktree: a git repo with a stub bin/selection-gate.sh that writes gate.txt
# from STUB_RC / STUB_RED and prints a log line with FAIL: in it.
WT="$T/wt"; mkdir -p "$WT/bin"
git -C "$WT" init -q 2>/dev/null; git -C "$WT" -c user.name=f -c user.email=f@x.invalid commit -q --allow-empty -m base
NH=$(git -C "$WT" rev-parse HEAD)
cat > "$WT/bin/selection-gate.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
echo ran >> "$STUB_LOG"
echo "FAIL: expected 3, got 4"
mkdir -p "$out"
printf 'head: %s\nbase: -\nsuites: 7\nrc: %s\nred: %s\nnoted: -\nmode: batch\nwhy: %s\nquarantine: env\n' \
  "${STUB_HEAD}" "${STUB_WORD}" "${STUB_RED:--}" "${STUB_WHY:--}" > "$out/gate.txt"
exit "$STUB_RC"
SH
chmod +x "$WT/bin/selection-gate.sh"

# vb <case> <rc> <word> [red] [why] — br_sg_verify's block into $T/<case>.out.
vb() {
  : > "$T/$1.stub"
  ( export H="$T/h" STUB_LOG="$T/$1.stub" STUB_RC="$2" STUB_WORD="$3" STUB_RED="${4:-}" STUB_WHY="${5:-}" STUB_HEAD="$NH"
    SAYF="$T/$1.say"; say() { printf '%s\n' "$*" >> "$SAYF"; }
    . "$FRAG" || exit 9
    br_sg_verify "$WT" origin/main "$T/$1.sg" demo ) > "$T/$1.out" 2>&1
}
matches() { grep -qE "$RE" "$1"; }

vb v1 0 0
grep -qx 'SELECTION_GATE_EXIT: 0' "$T/v1.out" && ! matches "$T/v1.out" && head -n 1 "$T/v1.out" | grep -qx '== selection-gate ==' && ok \
  || bad "V1 green: [$(cat "$T/v1.out")]"
vb v2 1 1 tests/x.sh,tests/y.sh
grep -qx 'SELECTION_GATE_EXIT: 1' "$T/v2.out" && grep -qx 'SELECTION_GATE_RED: tests/x.sh,tests/y.sh' "$T/v2.out" && matches "$T/v2.out" && ok \
  || bad "V2 red: [$(cat "$T/v2.out")] regex [$RE]"
grep -q "selection gate red on the fix round's head in wt: tests/x.sh,tests/y.sh" "$T/v2.say" 2>/dev/null && ok || bad "V2 red: say [$(cat "$T/v2.say" 2>/dev/null)]"
vb v3 3 could-not-run "" runner-rc-125
grep -qx 'SELECTION_GATE_EXIT: could-not-run runner-rc-125' "$T/v3.out" && ! matches "$T/v3.out" && ok || bad "V3 could-not-run: [$(cat "$T/v3.out")]"
vb v3b 4 no-selection "" empty-selection
grep -qx 'SELECTION_GATE_EXIT: no-selection' "$T/v3b.out" && ! matches "$T/v3b.out" && ok || bad "V3 no-selection: [$(cat "$T/v3b.out")]"
# V4: a worktree with no gate script.
mkdir -p "$T/wt2"
( export H="$T/h" STUB_LOG="$T/v4.stub"; . "$FRAG"; br_sg_verify "$T/wt2" origin/main "$T/v4.sg" demo ) > "$T/v4.out" 2>&1
grep -qx 'SELECTION_GATE_EXIT: skipped (no bin/selection-gate.sh)' "$T/v4.out" && ! matches "$T/v4.out" && [ ! -e "$T/v4.stub" ] && ok \
  || bad "V4 no gate script: [$(cat "$T/v4.out")]"
# V5: the knob at 0.
: > "$T/v5.stub"
( export H="$T/h" STUB_LOG="$T/v5.stub" SELECTION_GATE=0; . "$FRAG"; br_sg_verify "$WT" origin/main "$T/v5.sg" demo ) > "$T/v5.out" 2>&1
grep -qx 'SELECTION_GATE_EXIT: skipped (SELECTION_GATE=0)' "$T/v5.out" && [ ! -s "$T/v5.stub" ] && ok || bad "V5 knob 0: [$(cat "$T/v5.out")] stub [$(cat "$T/v5.stub")]"
# V6: the gate's own output stays in run.out.
! grep -q 'FAIL: expected' "$T/v2.out" && grep -q 'FAIL: expected' "$T/v2.sg/run.out" && ok || bad "V6 gate output leaked into the verify block"
[ "$(grep -c ran "$T/v2.stub")" = 1 ] && ok || bad "V2 the stub gate ran $(grep -c ran "$T/v2.stub") times, want 1"

# ── after_push ────────────────────────────────────────────────────────────────
OLD=1111111111111111111111111111111111111111
BODY0=$'## What\r\nThe change.\r\n\r\n<!-- selection-gate: head='"$OLD"$' suites=5 rc=0 -->\r\n<!-- builder-gate: head=x -->\r\nTail line.'
# ap <case> <body> <gate-head> <gate-rc> [get-fails] — br_sg_after_push with a
# stub gh_rest; the pushed head is $NH, or $PUSHED when set.
ap() {
  mkdir -p "$T/$1.sg"
  printf 'head: %s\nbase: -\nsuites: 7\nrc: %s\nred: -\nnoted: -\nmode: batch\nwhy: -\nquarantine: env\n' "$3" "$4" > "$T/$1.sg/gate.txt"
  printf '%s' "$2" > "$T/$1.body0"
  ( export H="$T/h" C="$T/$1" GETFAIL="${5:-}"
    say() { printf '%s\n' "$*" >> "$C.say"; }
    gh_rest() {
      printf '%s %s\n' "$1" "$2" >> "$C.calls"
      case "$1" in
        GET) case "$GETFAIL" in fail) GH_REST_STATUS=502; return 75 ;; nobody) echo '{"message":"x"}'; return 0 ;; esac
             jq -n --rawfile b "$C.body0" '{number:9, body:$b}' ;;
        PATCH) local a; for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$C.patched" ;; esac; done ;;
      esac
    }
    . "$FRAG" || exit 9
    br_sg_after_push example-org/demo https://github.com/example-org/demo/pull/9 "${PUSHED:-$NH}" "$T/$1.sg" ) > "$T/$1.out" 2>&1
}
ap a1 "$BODY0" "$NH" 0
WANT=$'## What\r\nThe change.\r\n\r\n<!-- selection-gate: head='"$NH"$' suites=7 rc=0 -->\r\n<!-- builder-gate: head=x -->\r\nTail line.'
[ "$(grep -c '^PATCH repos/example-org/demo/pulls/9$' "$T/a1.calls" 2>/dev/null)" = 1 ] && ok || bad "A1: PATCH calls [$(cat "$T/a1.calls" 2>/dev/null)]"
[ -r "$T/a1.patched" ] && cmp -s "$T/a1.patched" <(printf '%s' "$WANT") && ok || bad "A1: patched body differs: [$(od -c "$T/a1.patched" 2>/dev/null | head -20)]"
[ "$(grep -o 'selection-gate:' "$T/a1.patched" 2>/dev/null | wc -l)" = 1 ] && ok || bad "A1: not exactly one marker"
grep -q "record set to the pushed head ${NH:0:8}" "$T/a1.say" && ok || bad "A1: say [$(cat "$T/a1.say" 2>/dev/null)]"
# Writer/reader round trip: the PATCHed body is ok for the new head.
# $WT has no origin/main and no gate file in a base (F1 answers a note there),
# so the round trip runs against a repo whose base has the gate.
RT="$T/rt"; mkdir -p "$RT/bin"; git -C "$RT" init -q; printf '#!/bin/bash\n' > "$RT/bin/selection-gate.sh"
git -C "$RT" add -A; git -C "$RT" -c user.name=f -c user.email=f@x.invalid commit -qm base; git -C "$RT" update-ref refs/remotes/origin/main HEAD
RTH=$(git -C "$RT" rev-parse HEAD)
PUSHED="$RTH" ap rt "$BODY0" "$RTH" could-not-run
got=$( HARNESS="$T/h"; . "$T/h/bin/lib/lead-review/gate-record.sh"; lr_gate_record "$(cat "$T/rt.patched" 2>/dev/null)" "$RTH" ticket/bh-1 block "$RT" main )
[ "$got" = "ok 7 could-not-run" ] && ok || bad "A1 round trip: lr_gate_record [$got]"
# A2: no marker in the body: appended.
ap a2 $'Line one.\nLine two.' "$NH" 0
cmp -s "$T/a2.patched" <(printf 'Line one.\nLine two.\n<!-- selection-gate: head=%s suites=7 rc=0 -->' "$NH") && ok || bad "A2 append: [$(cat "$T/a2.patched" 2>/dev/null)]"
# A2b: two markers, one inline with text: the first becomes the new one, the second goes.
ap a2b $'Gate <!-- selection-gate: head='"$OLD"$' suites=5 rc=0 --> here\n<!-- selection-gate: head='"$OLD"$' suites=4 rc=0 -->\nEnd' "$NH" 0
cmp -s "$T/a2b.patched" <(printf 'Gate <!-- selection-gate: head=%s suites=7 rc=0 --> here\nEnd' "$NH") && ok || bad "A2b two markers: [$(cat "$T/a2b.patched" 2>/dev/null)]"
# A3: gate.txt for another head, or a red one: no PATCH.
ap a3 "$BODY0" "$OLD" 0
! grep -q '^PATCH' "$T/a3.calls" 2>/dev/null && grep -q 'not refreshed' "$T/a3.say" && ok || bad "A3 other head: calls [$(cat "$T/a3.calls" 2>/dev/null)]"
ap a3b "$BODY0" "$NH" 1
! grep -q '^PATCH' "$T/a3b.calls" 2>/dev/null && ok || bad "A3 red: calls [$(cat "$T/a3b.calls" 2>/dev/null)]"
# A4: the GET fails, or answers no body: no PATCH, the body is never wiped.
ap a4 "$BODY0" "$NH" 0 fail
! grep -q '^PATCH' "$T/a4.calls" 2>/dev/null && grep -q 'could not be read' "$T/a4.say" && ok || bad "A4 GET fails: calls [$(cat "$T/a4.calls" 2>/dev/null)]"
ap a4b "$BODY0" "$NH" 0 nobody
! grep -q '^PATCH' "$T/a4b.calls" 2>/dev/null && ok || bad "A4 GET with no body: calls [$(cat "$T/a4b.calls" 2>/dev/null)]"

# ── D the call sites in the real driver ───────────────────────────────────────
# sites <driver> — rc 0 when both call sites sit in br_fix_round: the verify
# call inside the verify group, before `} > "$out"`; the after-push call after
# br_preflight_after_push.
sites() {
  awk '
    /^br_fix_round\(\) \{/ {f=1}
    f && /^}/ {f=0}
    f && /br closure-lint verify \(BH-5064\)/ {grp=1}
    f && grp && /br_sg_verify "\$wt" "origin\/\$\{mref:-main\}" "\$ST\/\$p\/\$ck\.selection-gate"/ {v=NR}
    f && grp && /^  \} > "\$out" 2>&1$/ {grp=0; if (v) vin=1}
    f && /&& br_preflight_after_push / {pp=NR}
    f && /br_sg_after_push "\$slug" "\$url" "\$\(git -C "\$wt" rev-parse HEAD\)" "\$ST\/\$p\/\$ck\.selection-gate"/ {a=NR}
    END { exit !(vin && pp && a && a > pp) }' "$1"
}
sites "$DRIVER" && ok || bad "D: the two call sites are not where they belong in bin/blocked-resolver.sh"
sed '/br_sg_verify "\$wt"/d' "$DRIVER" > "$T/drv-m1"; sites "$T/drv-m1" && bad "D mutant: the verify call cut still passes" || ok
sed '/br_sg_after_push "\$slug"/d' "$DRIVER" > "$T/drv-m2"; sites "$T/drv-m2" && bad "D mutant: the after-push call cut still passes" || ok

# ── M mutants ─────────────────────────────────────────────────────────────────
RE_OLD=$(sed 's/|SELECTION_GATE//' <<<"$RE")
grep -qE "$RE_OLD" "$T/v2.out" && bad "M: the regex without SELECTION_GATE still matches V2" || ok
( export H="$T/h" C="$T/m2"; mkdir -p "$T/m2.sg"; cp "$T/a3.sg/gate.txt" "$T/m2.sg/"; printf '%s' "$BODY0" > "$T/m2.body0"
  say() { :; }
  gh_rest() { printf '%s\n' "$1" >> "$C.calls"; [ "$1" = GET ] && jq -n --rawfile b "$C.body0" '{body:$b}'; return 0; }
  . "$FRAG"; . "$T/h/bin/lib/selection-gate.sh"
  eval "$(declare -f br_sg_after_push | sed 's/\[ "\$(_sg_field "\$g" head)" != "\$nh" \]/false/')"
  br_sg_after_push example-org/demo https://github.com/example-org/demo/pull/9 "$NH" "$T/m2.sg" ) >/dev/null 2>&1
grep -q '^PATCH' "$T/m2.calls" 2>/dev/null && ok || bad "M: the head-compare mutant did not PATCH (the A3 check would not bite)"

echo "br-selection-gate.bh-8062: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
