#!/bin/bash
# tests/lead-review-fresh-conflict.bh-7816-test.sh — BH-7816: the lead review
# ends a head that conflicts with the freshly fetched origin/<base> as
# superseded, with no verdict and no agent call (bin/lib/lead-review/fresh-conflict.sh
# and its call block in bin/lead-review.sh).
#
#   U1  lr_fresh_conflict on real git repos: P1-P5 conflict (rc 0, LR_FC_WHY
#       names the paths); N1-N7 do not (rc 1, LR_FC_WHY empty)
#   U2  lr_fresh_applies: A1-A3 the lane's own requests; B1-B4 not; B5 a malformed
#       knob reads as 1 and is logged
#   U3  lr_fresh_supersede: one superseded post with the detail and no verdict, the
#       job done, R=superseded; a failed post leaves the job open
#   U4  the knob fragment and MODULES
#   LR1-LR4 the real bin/lead-review.sh block as the body of review(): a
#       conflicting enqueue head is superseded before the sentinel; a clean head
#       and a person's request reach it; a failed post claims nothing; after
#       LR1 the clone's merge-tree (what lg_gate_rebase_hold runs) still holds
#       the head; the block sits after the fetch and before the console qa gate
#   M1-M3 mutants: an lr_fresh_conflict that never conflicts fails U1-P1 and
#       LR1; a cut host block fails LR1; no requester check fails U2-B1
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-fresh-conflict.bh-7816-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LR="$DIR/bin/lead-review.sh"
export GIT_AUTHOR_DATE="2026-10-23T05:30:00Z" GIT_COMMITTER_DATE="2026-10-23T05:30:00Z"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
unset LEAD_REVIEW_FRESH_CONFLICT_HOLD

scratch_install_closure bin/lead-review.sh "$T/c" >/dev/null || { echo "FAIL: scratch_install_closure bin/lead-review.sh"; exit 1; }
MOD="$T/c/bin/lib/lead-review/fresh-conflict.sh"
[ -r "$MOD" ] || bad "setup: no bin/lib/lead-review/fresh-conflict.sh in the lead review's closure"

# mkrepo <case> <base-file> <base-text|-> — a clone at $T/r/<case> with
# <base-file> at <base-text> (- = no file) on the base commit. Prints the dir.
mkrepo() {
  local g="$T/r/$1"
  mkdir -p "$g"; git -C "$g" init -q -b main
  if [ "$3" != - ]; then mkdir -p "$g/$(dirname "$2")"; printf '%s\n' "$3" > "$g/$2"; git -C "$g" add -A; fi
  git -C "$g" commit -q --allow-empty -m base; git -C "$g" tag scratch-base
  printf '%s' "$g"
}
# side <dir> <branch> <file> <text|-> — a commit on <branch> from scratch-base
# that writes <file> (- = deletes it). The branch is created when it is absent.
side() {
  local g="$1"
  git -C "$g" checkout -q -B "$2" "$(git -C "$g" rev-parse -q --verify "refs/heads/$2" || echo scratch-base)"
  if [ "$4" = - ]; then git -C "$g" rm -q "$3"; else mkdir -p "$g/$(dirname "$3")"; printf '%s\n' "$4" > "$g/$3"; git -C "$g" add -A; fi
  git -C "$g" commit -q -m "$2 $3"
}
# fin <dir> — origin/main is the main branch; prints the pr head sha.
fin() {
  git -C "$1" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$1" rev-parse -q --verify refs/heads/pr || git -C "$1" rev-parse scratch-base
}
LINES20=$(seq 1 30 | sed 's/^/line /')

# u1 <case> <dir> <sha> <want-rc> [base] [path...] — one decision-table row.
u1() {
  local c="$1" g="$2" s="$3" want="$4" b="${5:-main}" p rc=0; shift 5 2>/dev/null || shift $#
  LR_FC_WHY=stale
  ( . "$MOD" || exit 9; log() { :; }; lr_fresh_conflict "$g" "$b" "$s"; rc=$?; printf '%s' "$LR_FC_WHY" > "$T/u1-$c.why"; exit "$rc" ) || rc=$?
  [ "$rc" = "$want" ] || { bad "U1-$c: rc $rc, want $want (why [$(cat "$T/u1-$c.why" 2>/dev/null)])"; return; }
  if [ "$want" = 0 ]; then
    grep -q '^needs rebase: conflicts with origin/main in ' "$T/u1-$c.why" || { bad "U1-$c: why [$(cat "$T/u1-$c.why")]"; return; }
    for p in "$@"; do grep -qF -- "$p" "$T/u1-$c.why" || { bad "U1-$c: why [$(cat "$T/u1-$c.why")] does not name $p"; return; }; done
  else
    [ ! -s "$T/u1-$c.why" ] || { bad "U1-$c: why [$(cat "$T/u1-$c.why")] is not empty"; return; }
  fi
  ok
}

# ── U1 the decision table ─────────────────────────────────────────────────────
# P1: main and the PR rewrite the same line of one function (#6648 _lri_list).
g=$(mkrepo p1 bin/lib/lane-run-inputs.sh '_lri_list() { echo old-fixture; }')
side "$g" main bin/lib/lane-run-inputs.sh '_lri_list() { echo main-fixture; }'
side "$g" pr bin/lib/lane-run-inputs.sh '_lri_list() { echo pr-fixture; }'
P1_SHA=$(fin "$g"); P1_DIR="$g"
u1 P1 "$g" "$P1_SHA" 0 main bin/lib/lane-run-inputs.sh
# P2: four files conflict (#5864 after BH-5800).
g=$(mkrepo p2 a/one.sh 'one fixture')
for f in a/two.sh a/three.sh a/four.sh; do printf 'base %s\n' "$f" > "$g/$f"; done; git -C "$g" add -A; git -C "$g" commit -q -m base2; git -C "$g" tag -f scratch-base >/dev/null
for f in a/one.sh a/two.sh a/three.sh a/four.sh; do side "$g" main "$f" "main $f"; side "$g" pr "$f" "pr $f"; done
u1 P2 "$g" "$(fin "$g")" 0 main a/one.sh a/two.sh a/three.sh a/four.sh
# P3: add/add of one new path with different content.
g=$(mkrepo p3 x - ); side "$g" main new/fixture.sh 'main fixture'; side "$g" pr new/fixture.sh 'pr fixture'
u1 P3 "$g" "$(fin "$g")" 0 main new/fixture.sh
# P4: main deletes a file the PR changes.
g=$(mkrepo p4 gone.sh 'gone fixture'); side "$g" main gone.sh -; side "$g" pr gone.sh 'pr fixture'
u1 P4 "$g" "$(fin "$g")" 0 main gone.sh
# P5: six files conflict: five are named, the sixth is counted.
g=$(mkrepo p5 - -)
for i in 1 2 3 4 5 6; do side "$g" main "c/f$i.sh" "main $i"; side "$g" pr "c/f$i.sh" "pr $i"; done
u1 P5 "$g" "$(fin "$g")" 0 main c/f1.sh c/f5.sh '(+1 more)'
grep -q 'c/f6.sh' "$T/u1-P5.why" && bad "U1-P5: the sixth path is named [$(cat "$T/u1-P5.why")]" || ok
# N1: main changed a different file.
g=$(mkrepo n1 a.sh 'a fixture'); side "$g" main b.sh 'b fixture'; side "$g" pr a.sh 'a pr fixture'
u1 N1 "$g" "$(fin "$g")" 1
# N2: the same file, hunks 20 lines apart (a clean 3-way merge).
g=$(mkrepo n2 f.sh "$LINES20")
side "$g" main f.sh "$(sed 's/^line 2$/line 2 main/' <<<"$LINES20")"
side "$g" pr f.sh "$(sed 's/^line 25$/line 25 pr/' <<<"$LINES20")"
N2_SHA=$(fin "$g"); N2_DIR="$g"
u1 N2 "$g" "$N2_SHA" 1
# N3: main already holds the PR's exact change.
g=$(mkrepo n3 f.sh 'old fixture'); side "$g" main f.sh 'same fixture'; side "$g" pr f.sh 'same fixture'
u1 N3 "$g" "$(fin "$g")" 1
# N4: main has not moved since the PR's base.
g=$(mkrepo n4 f.sh 'old fixture'); side "$g" pr f.sh 'pr fixture'
git -C "$g" branch -q -f main scratch-base
u1 N4 "$g" "$(fin "$g")" 1
# N5: the head object is not in the clone.
u1 N5 "$P1_DIR" 0123456789abcdef0123456789abcdef01234567 1
# N6: origin/<base> is missing.
u1 N6 "$P1_DIR" "$P1_SHA" 1 nope-fixture
# N7: merge-tree exits 128 (unrelated histories).
g=$(mkrepo n7 f.sh 'main fixture'); git -C "$g" update-ref refs/remotes/origin/main HEAD
git -C "$g" checkout -q --orphan pr; printf 'pr fixture\n' > "$g/f.sh"; git -C "$g" add -A; git -C "$g" commit -q -m orphan
N7_SHA=$(git -C "$g" rev-parse HEAD)
git -C "$g" merge-tree --write-tree --name-only --no-messages origin/main "$N7_SHA" >/dev/null 2>&1; n7rc=$?
[ "$n7rc" -gt 1 ] && ok || bad "U1-N7 setup: merge-tree rc $n7rc, want >1"
u1 N7 "$g" "$N7_SHA" 1

# ── U2 lr_fresh_applies ──────────────────────────────────────────────────────────
# u2 <case> <want-rc> <request-json> [knob] — knob unset when absent.
u2() {
  local rc=0 lf="$T/u2-$1.log"
  ( . "$MOD" || exit 9; log() { printf '%s\n' "$*" >> "$lf"; }
    if [ "$#" -ge 4 ]; then export LEAD_REVIEW_FRESH_CONFLICT_HOLD="$4"; fi
    lr_fresh_applies "$3"; a=$?; lr_fresh_applies "$3"; [ "$?" = "$a" ] || exit 8; exit "$a" ) || rc=$?
  [ "$rc" = "$2" ] && ok || bad "U2-$1: rc $rc, want $2 (log [$(cat "$T/u2-$1.log" 2>/dev/null)])"
}
u2 A1 0 '{"requested_by":"lead-review-enqueue:hub-fixture"}'
u2 A2 0 '{"requested_by":"lead-review-worklist"}'
u2 A3 0 '{"requested_by":"","src":"worklist"}'
u2 B1 1 '{"requested_by":"person-fixture"}'
u2 B2 1 '{"requested_by":""}'
u2 B3 1 '{"requested_by":"lead-review-enqueuer"}'
u2 B4 1 '{"requested_by":"lead-review-enqueue:hub-fixture"}' 0
u2 B5 0 '{"requested_by":"lead-review-enqueue:hub-fixture"}' yes
[ "$(grep -c "LEAD_REVIEW_FRESH_CONFLICT_HOLD='yes'" "$T/u2-B5.log" 2>/dev/null)" = 1 ] && ok \
  || bad "U2-B5: want one log line naming the bad value, got [$(cat "$T/u2-B5.log" 2>/dev/null)]"
[ ! -s "$T/u2-A1.log" ] && ok || bad "U2-A1: a good knob logged [$(cat "$T/u2-A1.log")]"

# ── U3 lr_fresh_supersede ────────────────────────────────────────────────────────
# u3 <case> <post-rc> — runs the supersede with stubbed post_result/job_update.
u3() {
  local C="$T/u3-$1"; mkdir -p "$C"
  ( . "$MOD" || exit 9
    post_result() { printf '%s\n' "$1" > "$C/id"; printf '%s\n' "$2" > "$C/post"; return "$POST_RC"; }
    job_update() { printf '%s\n' "$*" >> "$C/job"; }
    log() { printf '%s\n' "$*" >> "$C/log"; }
    R=skipped; LR_FC_WHY="needs rebase: conflicts with origin/main in a/fixture.sh"
    lr_fresh_supersede 7 j-fixture deadbeef0001deadbeef0001deadbeef00010000 lr-9-deadbeef0001
    printf '%s\n' "$R" > "$C/R" )
}
POST_RC=0 u3 ok 0
C="$T/u3-ok"
jq -e '.outcome == "superseded" and .detail == "needs rebase: conflicts with origin/main in a/fixture.sh" and (has("verdict") | not)
       and .job_id == "j-fixture" and .head_sha == "deadbeef0001deadbeef0001deadbeef00010000"' "$C/post" >/dev/null 2>&1 \
  && [ "$(cat "$C/id")" = 7 ] && ok || bad "U3: post [$(cat "$C/post" 2>/dev/null)]"
[ "$(cat "$C/R" 2>/dev/null)" = superseded ] && [ "$(grep -cx 'j-fixture status=done' "$C/job" 2>/dev/null)" = 1 ] && ok \
  || bad "U3: R [$(cat "$C/R" 2>/dev/null)] job [$(cat "$C/job" 2>/dev/null)]"
grep -qx 'superseded lr-9-deadbeef0001: needs rebase: conflicts with origin/main in a/fixture.sh; no agent call' "$C/log" && ok \
  || bad "U3: log [$(cat "$C/log" 2>/dev/null)]"
POST_RC=1 u3 fail 1
C="$T/u3-fail"
[ ! -e "$C/job" ] && [ "$(cat "$C/R" 2>/dev/null)" = skipped ] && ! grep -q superseded "$C/log" 2>/dev/null && ok \
  || bad "U3 post fails: R [$(cat "$C/R" 2>/dev/null)] job [$(cat "$C/job" 2>/dev/null)] log [$(cat "$C/log" 2>/dev/null)]"

# ── U4 the knob and MODULES ───────────────────────────────────────────────────
KF="$DIR/catalog/lanes.d/lead-review.knobs.d/LEAD_REVIEW_FRESH_CONFLICT_HOLD.json"
jq -e '.env == "LEAD_REVIEW_FRESH_CONFLICT_HOLD" and .default == 1 and .min == 0 and .max == 1
       and .read_in == "bin/lib/lead-review/fresh-conflict.sh"' "$KF" >/dev/null 2>&1 && ok || bad "U4: knob fragment [$(cat "$KF" 2>/dev/null)]"
grep -q 'LEAD_REVIEW_FRESH_CONFLICT_HOLD' "$DIR/bin/lib/lead-review/fresh-conflict.sh" 2>/dev/null && ok || bad "U4: the module does not read the knob"
grep -qx 'fresh-conflict' "$DIR/bin/lib/lead-review/MODULES" && ok || bad "U4: MODULES does not list fresh-conflict"

# ── LR the real host block ────────────────────────────────────────────────────
lr_cut() { awk '/^  # >>> fresh conflict hold \(BH-7816\)/{f=1} f{print} /^  # <<< fresh conflict hold$/{exit}' "$1" > "$2"; }
lr_cut "$LR" "$T/lr-block.sh"
grep -q 'lr_fresh_conflict "\$REPO_DIR" "\$base" "\$sha"' "$T/lr-block.sh" && ok || bad "LR: no fresh conflict hold block in bin/lead-review.sh"
lrfn() {
  { printf '%s\n' 'review() {' '  local r="$LR_REQ" REPO_DIR="$LR_DIR" base=main sha="$LR_SHA" id=5 job=j-fixture key=lr-9-fixture'
    cat "$1"
    printf '%s\n' '  echo SENTINEL_REACHED' '}'; } > "$2"
}
lrfn "$T/lr-block.sh" "$T/lr-fn.sh"
# lr <case> <dir> <sha> <request-json> <post-rc> [fn] — review() with the modules loaded.
lr() {
  local C="$T/lr-$1"; mkdir -p "$C"
  env C="$C" LR_DIR="$2" LR_SHA="$3" LR_REQ="$4" POST_RC="$5" bash -c '
    . "$0" || exit 9
    log() { printf "%s\n" "$*" >> "$C/log"; }
    post_result() { printf "%s\n" "$2" >> "$C/post"; return "$POST_RC"; }
    job_update() { printf "%s\n" "$*" >> "$C/job"; }
    R=skipped
    . "$1" || exit 9
    review; printf "%s\n" "$R" > "$C/R"' "$T/c/bin/lib/lead-review/load.sh" "${6:-$T/lr-fn.sh}" > "$C/out" 2>&1
}
ENQ='{"requested_by":"lead-review-enqueue:hub-fixture"}'
lr1_ok() {
  local C="$T/lr-$1"
  ! grep -q SENTINEL_REACHED "$C/out" && [ "$(grep -c . "$C/post" 2>/dev/null)" = 1 ] \
    && jq -e '.outcome == "superseded" and (has("verdict") | not)
              and (.detail | startswith("needs rebase: conflicts with origin/main in ")) and (.detail | contains("bin/lib/lane-run-inputs.sh"))' "$C/post" >/dev/null 2>&1 \
    && grep -qx 'j-fixture status=done' "$C/job" 2>/dev/null && [ "$(cat "$C/R" 2>/dev/null)" = superseded ]
}
lr lr1 "$P1_DIR" "$P1_SHA" "$ENQ" 0
lr1_ok lr1 && ok || bad "LR1: out [$(cat "$T/lr-lr1/out")] post [$(cat "$T/lr-lr1/post" 2>/dev/null)] job [$(cat "$T/lr-lr1/job" 2>/dev/null)] R [$(cat "$T/lr-lr1/R" 2>/dev/null)]"
# LR2: a clean head, and a person's request on a conflicting head, reach the sentinel.
lr lr2 "$N2_DIR" "$N2_SHA" "$ENQ" 0
grep -q SENTINEL_REACHED "$T/lr-lr2/out" && [ ! -e "$T/lr-lr2/post" ] && [ ! -e "$T/lr-lr2/job" ] && ok \
  || bad "LR2 clean: out [$(cat "$T/lr-lr2/out")] post [$(cat "$T/lr-lr2/post" 2>/dev/null)]"
lr lr2b "$P1_DIR" "$P1_SHA" '{"requested_by":"person-fixture"}' 0
grep -q SENTINEL_REACHED "$T/lr-lr2b/out" && [ ! -e "$T/lr-lr2b/post" ] && ok \
  || bad "LR2 person: out [$(cat "$T/lr-lr2b/out")] post [$(cat "$T/lr-lr2b/post" 2>/dev/null)]"
# LR3: the post fails: no superseded claim, the job stays open, no sentinel.
lr lr3 "$P1_DIR" "$P1_SHA" "$ENQ" 1
C="$T/lr-lr3"
! grep -q SENTINEL_REACHED "$C/out" && [ -s "$C/post" ] && [ ! -e "$C/job" ] && ! grep -q '^superseded' "$C/log" 2>/dev/null \
  && [ "$(cat "$C/R" 2>/dev/null)" = skipped ] && ok \
  || bad "LR3: out [$(cat "$C/out")] job [$(cat "$C/job" 2>/dev/null)] log [$(cat "$C/log" 2>/dev/null)] R [$(cat "$C/R" 2>/dev/null)]"
# LR4: the next tick's rebase hold (85-rebase-hold.sh) runs this merge-tree on
# the same clone: it still names the conflict, so no request restarts.
out=$(git -C "$P1_DIR" merge-tree --write-tree --name-only --no-messages origin/main "$P1_SHA" 2>/dev/null); mrc=$?
[ "$mrc" = 1 ] && grep -qx 'bin/lib/lane-run-inputs.sh' <<<"$out" && ok || bad "LR4: merge-tree rc $mrc [$out]"
grep -q 'merge-tree --write-tree --name-only --no-messages "origin/\$base" "\$head"' "$DIR/bin/lib/lead-gates.d/85-rebase-hold.sh" && ok \
  || bad "LR4: 85-rebase-hold.sh no longer runs the same merge-tree"
L_FE=$(grep -n -m 1 'git -C "\$REPO_DIR" fetch -q origin "\$base"' "$LR" | cut -d: -f1)
L_FC=$(grep -n '^  # >>> fresh conflict hold (BH-7816)' "$LR" | cut -d: -f1)
L_CQ=$(grep -n '^  # >>> console qa gate (BH-5909)' "$LR" | cut -d: -f1)
[ -n "$L_FE" ] && [ -n "$L_FC" ] && [ -n "$L_CQ" ] && [ "$L_FE" -lt "$L_FC" ] && [ "$L_FC" -lt "$L_CQ" ] && ok \
  || bad "LR4: order fetch ${L_FE:-none} < fresh conflict ${L_FC:-none} < console qa ${L_CQ:-none}"

# ── M mutants ─────────────────────────────────────────────────────────────────
# M1: an lr_fresh_conflict that never conflicts fails U1-P1 and LR1.
scratch_install_closure bin/lead-review.sh "$T/m1" >/dev/null || bad "M1 setup: scratch_install_closure bin/lead-review.sh"
if [ -r "$T/m1/bin/lib/lead-review/fresh-conflict.sh" ]; then
  printf '%s\n' 'lr_fresh_conflict() { LR_FC_WHY=""; return 1; }' >> "$T/m1/bin/lib/lead-review/fresh-conflict.sh"
  ( . "$T/m1/bin/lib/lead-review/fresh-conflict.sh"; log() { :; }; lr_fresh_conflict "$P1_DIR" main "$P1_SHA" ) && bad "M1: U1-P1 passes with no conflict check" || ok
  env C="$T/lr-m1" LR_DIR="$P1_DIR" LR_SHA="$P1_SHA" LR_REQ="$ENQ" POST_RC=0 bash -c 'mkdir -p "$C"; . "$0"; log() { :; }; post_result() { echo POST >> "$C/post"; }
    job_update() { :; }; R=skipped; . "$1"; review' "$T/m1/bin/lib/lead-review/load.sh" "$T/lr-fn.sh" > "$T/m1.out" 2>&1
  grep -q SENTINEL_REACHED "$T/m1.out" && ok || bad "M1: LR1 passes with no conflict check [$(cat "$T/m1.out")]"
else
  bad "M1 setup: no module to mutate"
fi
# M2: the host block cut fails LR1.
printf '  # >>> fresh conflict hold (BH-7816)\n  :\n  # <<< fresh conflict hold\n' > "$T/m2-block.sh"
lrfn "$T/m2-block.sh" "$T/m2-fn.sh"
lr m2 "$P1_DIR" "$P1_SHA" "$ENQ" 0 "$T/m2-fn.sh"
lr1_ok m2 && bad "M2: LR1 passes with the host block cut" || ok
# M3: no requester check fails U2-B1.
if [ -r "$MOD" ]; then
  ( . "$MOD"; log() { :; }; eval "$(declare -f lr_fresh_applies | sed 's/_lr_fresh_lane_request "\$1" || return 1/:/')"
    lr_fresh_applies '{"requested_by":"person-fixture"}' ) && ok || bad "M3: B1 is still refused with the requester check cut (the mutant did not bite)"
fi

echo "lead-review-fresh-conflict: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
