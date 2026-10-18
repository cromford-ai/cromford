#!/bin/bash
# tests/render-cron.bh-1185-test.sh — the four renderer behaviours BH-1185 adds
# to bin/render-cron.sh, each driven through the real renderer.
#
# WHY (BH-1185 — the three BH-559/#812 behaviours that #1182 did not carry over
# when it superseded that grammar, plus one review nit from the same round):
#
#   1. @WATCHDOG@. cron/lanes/260-watchdog-ping.cron was ten literal lines, and
#      the DEFAULT one carried no `# @box` header — so any box newly added to
#      the lane's .boxes silently pinged the watchdog under project-4's name, and a
#      ping under another box's name is indistinguishable from the box being
#      down. The name now comes out of fleet.conf through
#      cron_watchdog_name_for, and a box the registry cannot name REFUSES the
#      render rather than guessing one.
#   2. Duplicate line. Two fragments emitting the same schedule line for one box
#      is that box running a lane twice, every tick, with every --check green
#      because both fragments are exactly what their authors wrote.
#   3. Owned project. A cron/boxes/<box>.d line invoking a managed script for a
#      project fleet.conf does not assign to this box is a lane with no registry
#      row and no kill switch, running for a project (or a parked one) the box
#      does not own.
#   4. `# @ungated` with no reason. The directive's whole job is to say WHY a
#      hub-scoped lane fires on every box; bare, it is a typo that reads as a
#      decision, and the regex used to accept it.
#
# HOW IT IS PROVED. Every case runs bin/render-cron.sh itself over a scratch
# copy of this repo — and through it bin/render-crontab.sh, which is what a box
# actually installs. No case re-implements a renderer rule; the one source-text
# assertion (W6, the fragment no longer names a box literally) is paired with W5,
# which proves the requirement it stands for by adding a NEW box and rendering
# its ping with the fragment untouched.
#
# Run from anywhere: tests/render-cron.bh-1185-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "render-cron.bh-1185: jq is required"; exit 1; }
REG=$(rendered_registry)

# A scratch copy every mutation case works in, so no case can disturb the next.
# Same shape as tests/registry-render-test.sh: the renders are GENERATED and
# git-ignored, so the clone starts without them even if this tree carries some.
scratch_repo() {
  local d="$T/$1"
  scratch_rm "$d" || exit 1
  mkdir -p "$d"
  cp -R "$DIR/bin" "$DIR/cron" "$DIR/catalog" "$DIR/env-templates" "$d/"
  cp "$DIR/fleet.conf" "$d/fleet.conf"
  cp "$DIR/.gitignore" "$d/.gitignore" 2>/dev/null || :
  rm -f "$d/catalog/lanes.json" "$d/catalog/.lanes.json.stamp" \
        "$d/env-templates/global.env.example"
  rm -f "$d"/cron/*.cron
}

# render <repo> <box> — the PRODUCTION entry point, never a paraphrase.
# Leaves stdout in $ROUT, the exit code in $RRC and stderr in $T/last.err.
render() {
  ROUT=$("$1/bin/render-cron.sh" --root "$1" "$2" 2>"$T/last.err"); RRC=$?
}

# register_lane <repo> <id> <scope> <cadence> <boxes-json> — a lane the way a
# build adds one: one catalog/lanes.d file, then the registry recomposed.
register_lane() {
  jq -n --arg i "$2" --arg s "$3" --arg c "$4" --argjson b "$5" '{
      id:$i, name:$i, scope:$s, script:("bin/"+$i+".sh"), cadence:$c, boxes:$b,
      switch:{kind:"flag",name:("lane-off-"+$i),aliases:[]}, wired:false, knobs:[],
      stats:{cost_stage:null,cost_project_filter:null,lanes_row:false,log:("logs/"+$i+".log")}}' \
    > "$1/catalog/lanes.d/$2.json"
  "$1/bin/lanes-build.sh" --root "$1" --write >/dev/null 2>&1
}

# add_watchdog_box <repo> <box-id> — put a box in the ping lane's .boxes and
# give it the fleet-managed placeholder every box carries. The FRAGMENT is never
# touched, which is the whole claim.
add_watchdog_box() {
  jq --arg b "$2" '.boxes += [$b]' "$1/catalog/lanes.d/watchdog-ping.json" > "$T/wp.json"
  mv "$T/wp.json" "$1/catalog/lanes.d/watchdog-ping.json"
  mkdir -p "$1/cron/boxes/$2.d"
  printf '# @fleet-managed\n' > "$1/cron/boxes/$2.d/001-fleet-managed.cron"
  "$1/bin/lanes-build.sh" --root "$1" --write >/dev/null 2>&1
}

# ---- W. the watchdog name comes from the registry ---------------------------

# The expectation is computed from fleet.conf HERE, by string surgery over the
# box column, so it is an INDEPENDENT reading of the registry rather than a
# second call to the function under test.
wd_expect() {
  awk -v b="$1" '!/^[[:space:]]*(#|$)/ && NF>=6 {
      v=$6; id=v; sub(/^box-/,"",id); sub(/-[0-9]+$/,"",id)
      if (id == b) { print v; exit }
    }
    # A box with no project row: its `# @boxrole <box> <box_id> <role>` line.
    $1 == "#" && $2 == "@boxrole" && NF >= 5 && $4 == b && r == "" { r = $3 }
    END { if (r != "") print r }' "$DIR/fleet.conf" | head -1
}

# --- W1. every box in the lane pings under the name fleet.conf gives it ------
WB=$(jq -r '.lanes[]|select(.id=="watchdog-ping")|.boxes[]' "$REG")
NW=0
for B in $WB; do
  NW=$((NW+1))
  # "hub" has no fleet.conf row of its own; box-hub is the ping name
  # bin/lib/cron-lines.sh already writes down for it.
  if [ "$B" = hub ]; then EXP=box-hub; else EXP=$(wd_expect "$B"); fi
  if [ -z "$EXP" ]; then bad "W1 fleet.conf names no box for watchdog box '$B'"; continue; fi
  GOT=$(grep -h 'watchdog-ping\.sh' "$(rendered_cron "$B")" | awk '{print $NF}')
  [ "$GOT" = "$EXP" ] && ok || bad "W1 box $B pings as '$GOT'; fleet.conf says '$EXP'"
done
[ "$NW" -ge 9 ] && ok || bad "W1z only $NW boxes in watchdog-ping .boxes — the loop would prove nothing"

# --- W2. the machine GENERATION suffix survives ------------------------------
# cron_box_id_for DROPS it (a "-2" hostname is the same box), so this is the
# case string surgery on the box id cannot produce.
W2LINE=$(grep -h 'watchdog-ping\.sh' "$(rendered_cron project-3)")
[ "$W2LINE" = '*/5 * * * * /root/harness/bin/watchdog-ping.sh box-project-3-2' ] \
  && ok || bad "W2 project-3's ping line is '$W2LINE'"

# --- W3. a box the registry cannot name REFUSES ------------------------------
scratch_repo "r-nope"
add_watchdog_box "$T/r-nope" nope           # ...and no fleet.conf row for it
render "$T/r-nope" nope
[ "$RRC" -ne 0 ] && ok || bad "W3a a box fleet.conf cannot name rendered a ping anyway (rc 0)"
[ -z "$ROUT" ] && ok || bad "W3b the refused render wrote $(printf '%s' "$ROUT" | wc -l) lines to stdout"
grep -q '@WATCHDOG@' "$T/last.err" && ok || bad "W3c the refusal does not say what it could not expand: $(head -1 "$T/last.err")"
grep -q 'nope' "$T/last.err" && ok || bad "W3d the refusal does not name the box: $(head -1 "$T/last.err")"

# --- W4. resolution is LAZY --------------------------------------------------
# project-10 is parked: no fleet.conf row, and not in the ping lane's
# .boxes. Refusing every nameless box would take its render down for a lane it
# does not run.
render "$DIR" project-10
[ "$RRC" -eq 0 ] && ok || bad "W4 a box with no fleet.conf row and no @WATCHDOG@ stopped rendering: $(head -1 "$T/last.err")"

# --- W5. A NEW BOX NEEDS NO FRAGMENT EDIT. This is the ticket. ---------------
scratch_repo "r-zeta"
printf 'zeta-os Acme/zeta - - 7 box-zeta-3 10.0.0.13\n' >> "$T/r-zeta/fleet.conf"
add_watchdog_box "$T/r-zeta" zeta
render "$T/r-zeta" zeta
[ "$RRC" -eq 0 ] && ok || bad "W5a a new fleet.conf box does not render: $(head -1 "$T/last.err")"
grep -q 'watchdog-ping\.sh box-zeta-3' <<<"$ROUT" \
  && ok || bad "W5b the new box's ping does not carry its own name: $(printf '%s\n' "$ROUT" | grep watchdog-ping || echo '<no ping line>')"
cmp -s "$T/r-zeta/cron/lanes/260-watchdog-ping.cron" "$DIR/cron/lanes/260-watchdog-ping.cron" \
  && ok || bad "W5c the fixture had to edit the watchdog fragment after all"

# --- W6. and the fragment is one line, with no box named in it ---------------
WF="$DIR/cron/lanes/260-watchdog-ping.cron"
[ "$(wc -l < "$WF")" -eq 1 ] && ok || bad "W6a the watchdog fragment is $(wc -l < "$WF") lines, not 1"
# Guarded (D3): the grep for the placeholder must HIT, so an empty file fails
# rather than passing the two absence checks below.
grep -q '@WATCHDOG@' "$WF" && ok || bad "W6b the watchdog fragment carries no @WATCHDOG@"
grep -q 'box-' "$WF" && bad "W6c the watchdog fragment still names a box literally" || ok
grep -q '^# @box' "$WF" && bad "W6d the watchdog fragment still carries # @box sections" || ok

# ---- D. two fragments, one line ---------------------------------------------

# --- D1. two lane fragments emitting the same line ---------------------------
scratch_repo "r-dup"
DUPLINE='7 * * * * /root/harness/bin/zz-same.sh >/dev/null 2>&1'
register_lane "$T/r-dup" zz-a box "7 * * * *" '["small"]'
register_lane "$T/r-dup" zz-b box "7 * * * *" '["small"]'
printf '%s\n' "$DUPLINE" > "$T/r-dup/cron/lanes/615-zz-a.cron"
printf '%s\n' "$DUPLINE" > "$T/r-dup/cron/lanes/616-zz-b.cron"
render "$T/r-dup" small
[ "$RRC" -ne 0 ] && ok || bad "D1a two fragments emitting the same line rendered anyway (rc 0)"
[ -z "$ROUT" ] && ok || bad "D1b the refused render wrote to stdout"
{ grep -q '615-zz-a\.cron' "$T/last.err" && grep -q '616-zz-b\.cron' "$T/last.err"; } \
  && ok || bad "D1c the refusal does not name both fragments: $(head -1 "$T/last.err")"
grep -qF 'zz-same.sh' "$T/last.err" && ok || bad "D1d the refusal does not quote the line: $(head -1 "$T/last.err")"

# --- D2. a boxes file colliding with a lane fragment -------------------------
scratch_repo "r-dup2"
printf '47 4 * * * /root/harness/bin/disk-clean.sh >/dev/null 2>&1\n' \
  > "$T/r-dup2/cron/boxes/small.d/900-dup.cron"
render "$T/r-dup2" small
[ "$RRC" -ne 0 ] && ok || bad "D2a a boxes file duplicating a lane line rendered anyway (rc 0)"
{ grep -q '900-dup\.cron' "$T/last.err" && grep -q '610-disk-clean\.cron' "$T/last.err"; } \
  && ok || bad "D2b the refusal does not name both files: $(head -1 "$T/last.err")"

# --- D3. a `# @box` variant is NOT a duplicate of its own default ------------
# The adversarial negative: a variant REPLACES the default, so the two are never
# both emitted and a renderer that compared them would refuse the whole fleet.
scratch_repo "r-var"
register_lane "$T/r-var" zz-var box "7 * * * *" '["small","project-4"]'
printf '7 * * * * /root/harness/bin/zz-var.sh\n# @box small\n7 * * * * /root/harness/bin/zz-var.sh\n' \
  > "$T/r-var/cron/lanes/615-zz-var.cron"
render "$T/r-var" small
[ "$RRC" -eq 0 ] && ok || bad "D3a a # @box variant equal to its default was refused: $(head -1 "$T/last.err")"
[ "$(printf '%s\n' "$ROUT" | grep -c 'zz-var\.sh')" = 1 ] \
  && ok || bad "D3b the variant rendered $(printf '%s\n' "$ROUT" | grep -c 'zz-var\.sh') times, not once"

# ---- O. a boxes file may not run a lane for a project the box does not own ---

# --- O1. a foreign project is refused, by file:line --------------------------
scratch_repo "r-own"
printf '2,12 * * * * /root/harness/bin/run-triage.sh project-3\n' \
  > "$T/r-own/cron/boxes/small.d/900-foreign.cron"
render "$T/r-own" small
[ "$RRC" -ne 0 ] && ok || bad "O1a a managed lane for a foreign project rendered anyway (rc 0)"
[ -z "$ROUT" ] && ok || bad "O1b the refused render wrote to stdout"
grep -q '900-foreign\.cron:1' "$T/last.err" && ok || bad "O1c the refusal does not name file:line: $(head -1 "$T/last.err")"
grep -q 'project-3' "$T/last.err" && ok || bad "O1d the refusal does not name the project: $(head -1 "$T/last.err")"

# --- O2. a project the box DOES own is not refused, and is absorbed once -----
scratch_repo "r-own2"
printf '3,13 * * * * /root/harness/bin/run-triage.sh cromford\n' \
  > "$T/r-own2/cron/boxes/small.d/900-owned.cron"
render "$T/r-own2" small
[ "$RRC" -eq 0 ] && ok || bad "O2a a managed lane for an OWNED project was refused: $(head -1 "$T/last.err")"
[ "$(printf '%s\n' "$ROUT" | grep -c 'run-triage\.sh cromford')" = 1 ] \
  && ok || bad "O2b the owned line is in the render $(printf '%s\n' "$ROUT" | grep -c 'run-triage\.sh cromford') times, not once"

# --- O3. a COMMENT naming a managed script is not a line ---------------------
scratch_repo "r-own3"
printf '# 2 * * * * /root/harness/bin/run-triage.sh project-3\n' \
  > "$T/r-own3/cron/boxes/small.d/900-comment.cron"
render "$T/r-own3" small
[ "$RRC" -eq 0 ] && ok || bad "O3 a commented-out managed line was refused: $(head -1 "$T/last.err")"

# --- O4. a script that is deliberately NOT managed is not refused ------------
# security-scan.sh takes a project argument and is enabled per box by hand;
# cron_managed_scripts documents it as out of the set on purpose.
scratch_repo "r-own4"
printf '0 3 * * 0 /root/harness/bin/security-scan.sh project-3\n' \
  > "$T/r-own4/cron/boxes/small.d/900-scan.cron"
render "$T/r-own4" small
[ "$RRC" -eq 0 ] && ok || bad "O4 a non-managed script with a foreign project was refused: $(head -1 "$T/last.err")"

# ---- U. `# @ungated` must carry a reason ------------------------------------

# <repo-name> <fragment body, with \n and \t escapes> — the bodies differ only
# in what follows the directive, so they are written as escapes rather than as
# source-file whitespace a linter or an editor would quietly trim.
ung_fixture() {
  scratch_repo "$1"
  register_lane "$T/$1" zz-hub-lane hub "5 * * * *" '["hub"]'
  printf '%b' "$2" > "$T/$1/cron/lanes/615-zz-hub-lane.cron"
}
UNG_LINE='5 * * * * /root/harness/bin/zz-hub-lane.sh >/dev/null 2>&1\n'

# --- U1. bare directive, refused by file:line --------------------------------
ung_fixture "r-ung" "# @ungated\n$UNG_LINE"
render "$T/r-ung" hub
[ "$RRC" -ne 0 ] && ok || bad "U1a a bare '# @ungated' rendered anyway (rc 0)"
[ -z "$ROUT" ] && ok || bad "U1b the refused render wrote to stdout"
grep -q '615-zz-hub-lane\.cron:1' "$T/last.err" && ok || bad "U1c the refusal does not name file:line: $(head -1 "$T/last.err")"
grep -q 'reason' "$T/last.err" && ok || bad "U1d the refusal does not say a reason is what is missing: $(head -1 "$T/last.err")"

# --- U2. whitespace only is still bare ---------------------------------------
ung_fixture "r-ung2" "# @ungated \t \n$UNG_LINE"
render "$T/r-ung2" hub
[ "$RRC" -ne 0 ] && ok || bad "U2 a whitespace-only '# @ungated' rendered anyway (rc 0)"

# --- U3. and a bare one can never count as the declaration -------------------
# Even beside a real `# @hub-lanes`, which satisfies the gate check: the reason
# rule fires first, so the bare directive cannot ride along as "declared".
ung_fixture "r-ung3" "# @ungated\n# @hub-lanes\n$UNG_LINE"
render "$T/r-ung3" hub
[ "$RRC" -ne 0 ] && ok || bad "U3a a bare '# @ungated' beside '# @hub-lanes' rendered anyway (rc 0)"
[ -z "$ROUT" ] && ok || bad "U3b the refused render wrote to stdout"

# --- U4. with a reason, it renders -------------------------------------------
ung_fixture "r-ung4" "# @ungated a test lane\n$UNG_LINE"
render "$T/r-ung4" hub
[ "$RRC" -eq 0 ] && ok || bad "U4a a declared-ungated hub lane does not render: $(head -1 "$T/last.err")"
grep -q 'zz-hub-lane\.sh' <<<"$ROUT" && ok || bad "U4b the declared-ungated line is not in the render"

# ---- N1. the adversarial negative: the real fleet still renders -------------
# Every new refusal above is a way to turn a green fleet red. All ten boxes must
# still render, and render to the same bytes twice.
NB=0
for B in $(rendered_boxes); do
  NB=$((NB+1))
  if N1A=$("$DIR/bin/render-cron.sh" --root "$DIR" "$B" 2>"$T/n1.err"); then
    N1B=$("$DIR/bin/render-cron.sh" --root "$DIR" "$B" 2>/dev/null)
    [ "$N1A" = "$N1B" ] && ok || bad "N1 box $B does not render to the same bytes twice"
  else
    bad "N1 box $B no longer renders: $(head -2 "$T/n1.err" | tr '\n' ' ')"
  fi
done
[ "$NB" -ge 10 ] && ok || bad "N1z only $NB boxes found — the negative would prove nothing"

echo "render-cron.bh-1185: PASS=$PASS FAIL=$FAIL  ($NW watchdog boxes, $NB fleet boxes)"
[ "$FAIL" -eq 0 ]
