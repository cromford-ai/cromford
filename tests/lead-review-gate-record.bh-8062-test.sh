#!/bin/bash
# tests/lead-review-gate-record.bh-8062-test.sh — BH-8062 T4: the lead review
# refuses MERGE, with no agent call, when a builder PR's body carries no
# selection-gate record for its head, or a record for another head
# (bin/lib/lead-review/gate-record.sh and its call block in bin/lead-review.sh).
#
#   U1  lr_gate_record over the marker case table (plan "Failure modes", T4),
#       in a scratch git repo whose base commit HAS bin/selection-gate.sh
#   F1  where the check applies (r3): a base without the gate file is n/a, a
#       head that only adds it is n/a (this PR's own shape), an unreadable
#       merge base is a note, never a refusal
#   F2  a moved head (r3): marker for H on head = H + a clean main merge, or a
#       byte-exact rebase, is ok rebound=<how>; H + a code commit, a merge with
#       a hand-resolved conflict, or a head this box does not have is refused;
#       patch-same.sh unreadable keeps the refusal
#   U2  the knob: unset = block, note, off, an unknown value = block
#   U3  lr_gate_record_report: the deterministic BLOCK report shape
#   U4  the knob fragment and MODULES
#   LR1-LR6 the real bin/lead-review.sh block as the body of review(): a
#       ticket/* head with no marker or another head's marker is a BLOCK with
#       model none:gate-record and never reaches the sentinel (the agent call);
#       a matching marker and a hotfix/* head reach it, the hotfix one with the
#       [NOTE]; a second PR in the same run with a matching marker reaches it
#   LR7 a base without the gate: the sentinel, no [NOTE] (other projects, the
#       break-it fixture's shape)
#   M1-M4 mutants: the host block cut fails LR1; a head compare that ignores
#       the head fails U1-H1; the F1 file check cut fails F1-NOGATE; the F2
#       rebind cut fails F2-MERGE
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-gate-record.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset LEAD_REVIEW_GATE_RECORD

LR="$DIR/bin/lead-review.sh"
SRC_MOD="$DIR/bin/lib/lead-review/gate-record.sh"
[ -r "$SRC_MOD" ] || bad "setup: bin/lib/lead-review/gate-record.sh does not exist"
scratch_install_closure bin/lead-review.sh "$T/c" >/dev/null || { echo "FAIL: scratch_install_closure bin/lead-review.sh"; exit 1; }
MOD="$T/c/bin/lib/lead-review/gate-record.sh"
[ -r "$MOD" ] || bad "setup: no bin/lib/lead-review/gate-record.sh in the lead review's closure"

# ── scratch git repos ─────────────────────────────────────────────────────────
g() { git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "${@:2}"; }
# mkrepo <dir> <gate 0|1> — one base commit on main (with or without
# bin/selection-gate.sh), origin/main pointing at it, then branch ticket/x
# checked out with one code commit. Prints nothing.
mkrepo() {
  git init -q -b main "$1" >/dev/null 2>&1 || git init -q "$1"
  g "$1" checkout -q -B main 2>/dev/null
  mkdir -p "$1/bin"; printf 'a1\n' > "$1/a.txt"; printf 'b1\n' > "$1/b.txt"
  if [ "$2" = 1 ]; then printf '#!/bin/bash\n' > "$1/bin/selection-gate.sh"; chmod +x "$1/bin/selection-gate.sh"; fi
  g "$1" add -A && g "$1" commit -qm base && g "$1" update-ref refs/remotes/origin/main HEAD
  g "$1" checkout -qb ticket/x && printf 'a2\n' > "$1/a.txt" && g "$1" commit -qam code
}
head_of() { git -C "$1" rev-parse HEAD; }
GR="$T/repo-gate"; mkrepo "$GR" 1
SHA=$(head_of "$GR")
g "$GR" checkout -q main && g "$GR" checkout -qb other && printf 'b2\n' > "$GR/b.txt" && g "$GR" commit -qam other
OTHER=$(head_of "$GR"); g "$GR" checkout -q ticket/x
mk() { printf '<!-- selection-gate: head=%s suites=%s rc=%s -->' "$1" "$2" "$3"; }
GOOD=$(mk "$SHA" 412 0)
export HARNESS="$T/c"

# u1 <case> <want> <body> [head_ref] [mode] — one row in $GR; mode unset when absent.
u1() {
  local got
  got=$( . "$MOD" >/dev/null 2>&1 || exit 9
    if [ "$#" -ge 5 ]; then export LEAD_REVIEW_GATE_RECORD="$5"; fi
    lr_gate_record "$3" "$SHA" "${4:-ticket/bh-1}" "$(lr_gate_record_mode)" "$GR" main )
  [ "$got" = "$2" ] && ok || bad "U1-$1: got [$got], want [$2]"
}
# f <case> <want> <body> <sha> <repo> [head_ref] — one row in any repo.
f() {
  local got
  got=$( . "$MOD" >/dev/null 2>&1 || exit 9; lr_gate_record "$3" "$4" "${6:-ticket/bh-1}" block "$5" main )
  [ "$got" = "$2" ] && ok || bad "$1: got [$got], want [$2]"
}
# ── U1 the case table ─────────────────────────────────────────────────────────
u1 OK1 "ok 412 0" "Some text.
$GOOD
More."
u1 OK2 "ok 3 could-not-run" "$(mk "$SHA" 3 could-not-run)"
u1 OK3 "ok 0 no-selection" "$(mk "$SHA" 0 no-selection)"
u1 H1 "refuse head=$OTHER" "$(mk "$OTHER" 412 0)"
u1 UP "refuse malformed" "$(mk "${SHA^^}" 412 0)"
u1 FENCE "ok 412 0" "Gate:
\`\`\`
$GOOD
\`\`\`"
u1 TWO-SAME "ok 412 0" "$GOOD
$GOOD"
u1 TWO-DIFF "refuse malformed" "$GOOD
$(mk "$OTHER" 412 0)"
u1 TWO-SUITES "refuse malformed" "$GOOD
$(mk "$SHA" 411 0)"
u1 RC1 "refuse malformed" "$(mk "$SHA" 412 1)"
u1 BG "refuse missing" "<!-- builder-gate: head=$SHA green=40 -->"
u1 EMPTY "refuse missing" ""
u1 HEX39 "refuse malformed" "$(mk "${SHA:0:39}" 412 0)"
u1 TRAIL "refuse malformed" "<!-- selection-gate: head=$SHA suites=412 rc=0 extra=fixture -->"
u1 HOTFIX "note no selection-gate record for head ${SHA:0:12} (hotfix/x is not a builder branch)" "" hotfix/x
u1 HOTFIX-OTHER "note the selection-gate record names head $OTHER, not $SHA (fix/y is not a builder branch)" "$(mk "$OTHER" 1 0)" fix/y
u1 R2 "refuse missing" "" ticket/bh-1-r2
u1 MODE-NOTE "note no selection-gate record for head ${SHA:0:12} (LEAD_REVIEW_GATE_RECORD=note)" "" ticket/bh-1 note
u1 MODE-OFF "ok - off" "" ticket/bh-1 off
u1 MODE-OFF-OTHER "ok - off" "$(mk "$OTHER" 1 0)" ticket/bh-1 off
u1 MODE-BAD "refuse missing" "" ticket/bh-1 maybe-fixture

# ── F1 where the check applies ────────────────────────────────────────────────
NG="$T/repo-nogate"; mkrepo "$NG" 0
f F1-NOGATE "ok - n/a" "no marker" "$(head_of "$NG")" "$NG"
f F1-NOGATE-R2 "ok - n/a" "" "$(head_of "$NG")" "$NG" ticket/bh-1-r2
HA="$T/repo-headadds"; mkrepo "$HA" 0
printf '#!/bin/bash\n' > "$HA/bin/selection-gate.sh"; chmod +x "$HA/bin/selection-gate.sh"; g "$HA" add -A; g "$HA" commit -qm "adds the gate"
f F1-HEAD-ADDS "ok - n/a" "" "$(head_of "$HA")" "$HA"
f F1-GATE "refuse missing" "" "$SHA" "$GR" ticket/bh-1-r2
f F1-NO-REPO "note could not read the merge base of ${SHA:0:12} with origin/main, so the selection-gate record was not checked" "" "$SHA" "$T/no-such-repo"
f F1-UNKNOWN-SHA "note could not read the merge base of ffffffffffff with origin/main, so the selection-gate record was not checked" "" ffffffffffffffffffffffffffffffffffffffff "$GR"
f F1-HOTFIX "note no selection-gate record for head ${SHA:0:12} (hotfix/x is not a builder branch)" "" "$SHA" "$GR" hotfix/x

# ── F2 a moved head ───────────────────────────────────────────────────────────
MM="$T/repo-moved"; mkrepo "$MM" 1
H0=$(head_of "$MM")
g "$MM" checkout -q main && printf 'b2\n' > "$MM/b.txt" && g "$MM" commit -qam "main moves" && g "$MM" update-ref refs/remotes/origin/main HEAD
g "$MM" checkout -q ticket/x && g "$MM" merge -q --no-edit main >/dev/null 2>&1
S_MERGE=$(head_of "$MM")
f F2-MERGE "ok 412 0 rebound=main-merge" "$(mk "$H0" 412 0)" "$S_MERGE" "$MM"
printf 'c1\n' > "$MM/c.txt"; g "$MM" add -A; g "$MM" commit -qm "a code commit"
S_CODE=$(head_of "$MM")
f F2-CODE "refuse head=$H0" "$(mk "$H0" 412 0)" "$S_CODE" "$MM"
g "$MM" checkout -q -b rebased main && g "$MM" cherry-pick "$H0" >/dev/null 2>&1
S_REBASE=$(head_of "$MM")
f F2-REBASE "ok 9 could-not-run rebound=patch-id" "$(mk "$H0" 9 could-not-run)" "$S_REBASE" "$MM"
f F2-UNKNOWN "refuse head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$(mk eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 412 0)" "$S_MERGE" "$MM"
# patch-same.sh unreadable: the refusal stays.
got=$( HARNESS="$T/no-harness"; H=""; . "$MOD" >/dev/null 2>&1 || exit 9; lr_gate_record "$(mk "$H0" 412 0)" "$S_MERGE" ticket/bh-1 block "$MM" main )
[ "$got" = "refuse head=$H0" ] && ok || bad "F2-NO-LIB: got [$got], want [refuse head=$H0]"
# A merge whose conflict was resolved by hand is not a clean main merge.
HR="$T/repo-handmerge"; mkrepo "$HR" 1
HH=$(head_of "$HR")
g "$HR" checkout -q main && printf 'a3\n' > "$HR/a.txt" && g "$HR" commit -qam "main edits a" && g "$HR" update-ref refs/remotes/origin/main HEAD
g "$HR" checkout -q ticket/x; g "$HR" merge -q --no-edit main >/dev/null 2>&1
printf 'a-hand\n' > "$HR/a.txt"; g "$HR" add a.txt; g "$HR" commit -qm "resolved by hand" >/dev/null 2>&1
S_HAND=$(head_of "$HR")
[ "$(git -C "$HR" rev-list --parents -n 1 HEAD | wc -w)" = 3 ] && ok || bad "F2-HAND setup: HEAD is not a merge commit"
f F2-HAND "refuse head=$HH" "$(mk "$HH" 412 0)" "$S_HAND" "$HR"

# ── U2 the knob ───────────────────────────────────────────────────────────────
u2() {
  local got
  got=$( . "$MOD" >/dev/null 2>&1 || exit 9; if [ "$#" -ge 3 ]; then export LEAD_REVIEW_GATE_RECORD="$3"; fi; lr_gate_record_mode )
  [ "$got" = "$2" ] && ok || bad "U2-$1: mode [$got], want [$2]"
}
u2 unset block
u2 empty block ""
u2 note note note
u2 off off off
u2 block block block
u2 bad block yes-fixture

# ── U3 the report ─────────────────────────────────────────────────────────────
rep=$( . "$MOD" >/dev/null 2>&1 || exit 9; lr_gate_record_report "RVLINE-fixture
" lr-9-fixture example-org/demo 9 "$SHA" bfp-fixture "refuse head=$OTHER" )
grep -qx -- "- \[BLOCK core-flow-broken\] the selection-gate record names head $OTHER, not $SHA.*" <<<"$rep" && ok || bad "U3 other head: [$rep]"
grep -qx 'VERDICT: BLOCK' <<<"$rep" && grep -qx -- '- reviewer model: none:gate-record' <<<"$rep" && grep -qx -- '- pr body: bfp-fixture' <<<"$rep" && ok || bad "U3 shape: [$rep]"
[ "$(tail -n 1 <<<"$rep")" = "VERDICT: BLOCK" ] && ok || bad "U3: VERDICT is not the last line [$rep]"
rep=$( . "$MOD" >/dev/null 2>&1 || exit 9; lr_gate_record_report "" k r 1 "$SHA" b "refuse missing" )
grep -qx -- "- \[BLOCK core-flow-broken\] no selection-gate record for head ${SHA:0:12}.*" <<<"$rep" && ok || bad "U3 missing: [$rep]"
rep=$( . "$MOD" >/dev/null 2>&1 || exit 9; lr_gate_record_report "" k r 1 "$SHA" b "refuse malformed" )
grep -qx -- "- \[BLOCK core-flow-broken\] the selection-gate record for head ${SHA:0:12} is malformed.*" <<<"$rep" && ok || bad "U3 malformed: [$rep]"

# ── U4 the knob fragment and MODULES ──────────────────────────────────────────
KF="$DIR/catalog/lanes.d/lead-review.knobs.d/LEAD_REVIEW_GATE_RECORD.json"
jq -e '.env == "LEAD_REVIEW_GATE_RECORD" and .default == "block" and .type == "string"
       and .read_in == "bin/lib/lead-review/gate-record.sh"' "$KF" >/dev/null 2>&1 && ok || bad "U4: knob fragment [$(cat "$KF" 2>/dev/null)]"
grep -qx 'gate-record' "$DIR/bin/lib/lead-review/MODULES" && ok || bad "U4: MODULES does not list gate-record"

# ── LR the real host block ────────────────────────────────────────────────────
lr_cut() { awk '/^  # >>> selection gate record \(BH-8062\)/{f=1} f{print} /^  # <<< selection gate record$/{exit}' "$1" > "$2"; }
lr_cut "$LR" "$T/lr-block.sh"
grep -q 'lr_gate_record ' "$T/lr-block.sh" && ok || bad "LR: no selection gate record block in bin/lead-review.sh"
lrfn() {
  { printf '%s\n' 'review() {' '  local r="{}" id=5 job=j-fixture sha="$LR_SHA" repo=example-org/demo pr="$LR_PR" key="lr-$LR_PR-fixture" bfp=bfp-fixture'
    printf '%s\n' '  local body="$LR_BODY" pr_json="$LR_PRJSON" report="$C/report-$LR_PR.md" RVLINE="" REPO_DIR="$LR_RD" base=main'
    cat "$1"
    printf '%s\n' '  echo "SENTINEL_REACHED note=[${LR_GR_NOTE:-}]"' '}'; } > "$2"
}
lrfn "$T/lr-block.sh" "$T/lr-fn.sh"
# lr <case> <pr> <head_ref> <body> [fn] — review() with the modules loaded,
# over $GR (LR_SHA and LR_RD override the head and the repo).
lr() {
  local C="$T/lr-$1"; mkdir -p "$C"
  env C="$C" LR_SHA="${LR_SHA:-$SHA}" LR_RD="${LR_RD:-$GR}" LR_PR="$2" LR_BODY="$4" LR_PRJSON="$(jq -nc --arg r "$3" '{head:{ref:$r}}')" bash -c '
    . "$0" || exit 9
    log() { printf "%s\n" "$*" >> "$C/log"; }
    finish_done() { printf "%s\n" "$*" >> "$C/finish"; }
    job_update() { printf "%s\n" "$*" >> "$C/job"; }
    . "$1" || exit 9
    review' "$T/c/bin/lib/lead-review/load.sh" "${5:-$T/lr-fn.sh}" >> "$T/lr-$1/out" 2>&1
}
blocked() {  # <case> <pr> [sha] — a BLOCK through finish_done with none:gate-record, no sentinel
  local C="$T/lr-$1"
  ! grep -q SENTINEL_REACHED "$C/out" && [ "$(grep -c . "$C/finish" 2>/dev/null)" = 1 ] \
    && grep -q "^5 j-fixture ${3:-$SHA} BLOCK $C/report-$2.md none:gate-record " "$C/finish" \
    && grep -qx 'VERDICT: BLOCK' "$C/report-$2.md"
}
lr lr1 9 ticket/bh-1 "no marker here"
blocked lr1 9 && grep -q "no selection-gate record for head ${SHA:0:12}" "$T/lr-lr1/report-9.md" && ok \
  || bad "LR1 missing: out [$(cat "$T/lr-lr1/out")] finish [$(cat "$T/lr-lr1/finish" 2>/dev/null)] report [$(cat "$T/lr-lr1/report-9.md" 2>/dev/null)]"
lr lr2 9 ticket/bh-1 "$(mk "$OTHER" 412 0)"
blocked lr2 9 && grep -q "names head $OTHER, not $SHA" "$T/lr-lr2/report-9.md" && ok \
  || bad "LR2 other head: out [$(cat "$T/lr-lr2/out")] report [$(cat "$T/lr-lr2/report-9.md" 2>/dev/null)]"
lr lr3 9 ticket/bh-1 "$GOOD"
grep -qx 'SENTINEL_REACHED note=\[\]' "$T/lr-lr3/out" && [ ! -e "$T/lr-lr3/finish" ] && ok || bad "LR3 match: out [$(cat "$T/lr-lr3/out")]"
lr lr4 9 hotfix/x ""
grep -qx "SENTINEL_REACHED note=\[\[NOTE\] no selection-gate record for head ${SHA:0:12} (hotfix/x is not a builder branch)\]" "$T/lr-lr4/out" \
  && [ ! -e "$T/lr-lr4/finish" ] && ok || bad "LR4 hotfix: out [$(cat "$T/lr-lr4/out")]"
# LR5: two PRs in one run: the refused one is a BLOCK, the matching one reaches the sentinel.
lr lr5 9 ticket/bh-1 ""
lr lr5 10 ticket/bh-2 "$GOOD"
[ "$(grep -c . "$T/lr-lr5/finish" 2>/dev/null)" = 1 ] && grep -q ' none:gate-record ' "$T/lr-lr5/finish" \
  && [ "$(grep -c SENTINEL_REACHED "$T/lr-lr5/out")" = 1 ] && [ ! -e "$T/lr-lr5/report-10.md" ] && ok \
  || bad "LR5 two PRs: out [$(cat "$T/lr-lr5/out")] finish [$(cat "$T/lr-lr5/finish" 2>/dev/null)]"
# LR6: knob note on a ticket/* head: the sentinel, with the [NOTE].
( export LEAD_REVIEW_GATE_RECORD=note; lr lr6 9 ticket/bh-1 "" )
grep -q 'SENTINEL_REACHED note=\[\[NOTE\] no selection-gate record' "$T/lr-lr6/out" && [ ! -e "$T/lr-lr6/finish" ] && ok || bad "LR6 note mode: out [$(cat "$T/lr-lr6/out")]"
# LR7: a base without the gate (another project, the break-it fixture): the
# sentinel, and no [NOTE] in the prompt.
( LR_SHA=$(head_of "$NG") LR_RD="$NG" lr lr7 9 ticket/bh-9001 "" )
grep -qx 'SENTINEL_REACHED note=\[\]' "$T/lr-lr7/out" && [ ! -e "$T/lr-lr7/finish" ] && ok || bad "LR7 no gate in the base: out [$(cat "$T/lr-lr7/out")]"
# LR8: a moved head over a clean main merge reaches the sentinel; a code commit is a BLOCK.
( LR_SHA="$S_MERGE" LR_RD="$MM" lr lr8 9 ticket/bh-1 "$(mk "$H0" 412 0)" )
grep -qx 'SENTINEL_REACHED note=\[\]' "$T/lr-lr8/out" && [ ! -e "$T/lr-lr8/finish" ] && ok || bad "LR8 main merge: out [$(cat "$T/lr-lr8/out")]"
( LR_SHA="$S_CODE" LR_RD="$MM" lr lr9 9 ticket/bh-1 "$(mk "$H0" 412 0)" )
blocked lr9 9 "$S_CODE" && grep -q "names head $H0, not $S_CODE" "$T/lr-lr9/report-9.md" && ok \
  || bad "LR9 code commit: out [$(cat "$T/lr-lr9/out")] finish [$(cat "$T/lr-lr9/finish" 2>/dev/null)]"
# The block sits after the fetch, and before the replay and every paid step.
L_FE=$(grep -n -m 1 'git -C "\$REPO_DIR" fetch -q origin "\$base"' "$LR" | cut -d: -f1)
L_GR=$(grep -n '^  # >>> selection gate record (BH-8062)' "$LR" | cut -d: -f1)
L_RP=$(grep -n -m 1 'lw_replay "\$repo" "\$pr" "\$sha"' "$LR" | cut -d: -f1)
[ -n "$L_FE" ] && [ -n "$L_GR" ] && [ -n "$L_RP" ] && [ "$L_FE" -lt "$L_GR" ] && [ "$L_GR" -lt "$L_RP" ] && ok \
  || bad "LR order: fetch ${L_FE:-none} < gate record ${L_GR:-none} < replay ${L_RP:-none}"
# The note reaches the reviewer's prompt: lr_gate_record_section prints it.
sec=$( . "$MOD" >/dev/null 2>&1 || exit 9; LR_GR_NOTE="[NOTE] fixture note"; lr_gate_record_section )
[ "$sec" = "$(printf '\n## Selection gate\n[NOTE] fixture note')" ] && ok || bad "LR note section: [$sec]"
sec=$( . "$MOD" >/dev/null 2>&1 || exit 9; LR_GR_NOTE=""; lr_gate_record_section )
[ -z "$sec" ] && ok || bad "LR no note: section [$sec]"
grep -q '^    lr_gate_record_section$' "$LR" && ok || bad "LR: the prompt block does not print lr_gate_record_section"

# ── M mutants ─────────────────────────────────────────────────────────────────
# M1: the host block cut fails LR1.
printf '  # >>> selection gate record (BH-8062)\n  :\n  # <<< selection gate record\n' > "$T/m1-block.sh"
lrfn "$T/m1-block.sh" "$T/m1-fn.sh"
lr m1 9 ticket/bh-1 "no marker here" "$T/m1-fn.sh"
blocked m1 9 && bad "M1: LR1 passes with the host block cut" || ok
# M2: a compare that ignores the head fails U1-H1.
if [ -r "$MOD" ]; then
  got=$( . "$MOD"; eval "$(declare -f lr_gate_record | sed 's/\[ "\$mh" = "\$sha" \]/true/')"
    lr_gate_record "$(mk "$OTHER" 412 0)" "$SHA" ticket/bh-1 block "$GR" main )
  [ "$got" != "refuse head=$OTHER" ] && ok || bad "M2: the mutant did not bite (got [$got])"
  # M3: the F1 file check cut: a base without the gate is refused.
  got=$( . "$MOD"; eval "$(declare -f lr_gate_record | sed 's/git -C "\$rd" cat-file -e "\$mb:bin\/selection-gate.sh"/true/')"
    lr_gate_record "no marker" "$(head_of "$NG")" ticket/bh-1 block "$NG" main )
  [ "$got" != "ok - n/a" ] && ok || bad "M3: the F1 mutant did not bite (got [$got])"
  # M4: the F2 rebind cut: a clean main merge is refused.
  got=$( . "$MOD"; eval "$(declare -f lr_gate_record | sed 's/how=\$(patch_same /how=$(false /')"
    lr_gate_record "$(mk "$H0" 412 0)" "$S_MERGE" ticket/bh-1 block "$MM" main )
  [ "$got" = "refuse head=$H0" ] && ok || bad "M4: the F2 mutant did not bite (got [$got])"
fi

echo "lead-review-gate-record: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
