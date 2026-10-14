#!/bin/bash
# tests/registry-render-test.sh — cron/<box>.cron and env-templates/
# global.env.example are RENDERS, and adding a lane is one file (BH-1178).
#
# WHY. Those eleven files were the fleet's shared append targets: every new lane
# added a line to up to ten crontabs and every new knob a paragraph to one
# template, always at the end, so two branches that had nothing to say to each
# other conflicted anyway. cron/hub.cron was touched by 6 of the last 200
# merges and env-templates/global.env.example by 25. The fix is a file per lane
# and a file per topic, with the monolith as their render — and the only thing
# that keeps that true is a check that the committed file still IS the render.
#
# AND SINCE BH-1247 THE RENDERS ARE NOT COMMITTED. Keeping them in git left
# each one a shared mutable cell every build wrote: a PR that edited a lane and
# did not re-render turned red, and once it merged every other open PR inherited
# the red on a file its ticket never mentioned (three merge trains, 2026-09-21).
# So case 1 stopped being "the committed file equals the render" — there is no
# committed file — and became the property that comparison stood in for: every
# box RENDERS, and renders to the same bytes twice. tests/registry-no-commit-test.sh
# carries the rest of that ticket.
#
# What is proved here:
#   1. every box renders, and renders DETERMINISTICALLY — the whole fleet, for
#      all ten, not a sample;
#   2. a registry lane with an EMPTY cadence fails the render, by name, with an
#      empty stdout (a crontab nobody wrote is worse than no crontab);
#   3. a registry lane the box claims with no fragment fails the render — the
#      2026-08-30 project-7 failure in the other direction: registered, on the
#      settings page, and scheduled nowhere;
#   4. TWO BRANCHES EACH ADDING A LANE MERGE CLEAN and the render carries both.
#      This is the ticket. It merges two real branches in a scratch clone;
#   5. the env template equals its topic files, and a NEW topic file lands in
#      the render at its filename position without editing anything else;
#   6. every fragment filename is <NNN>-<id>.cron and every lane id it names is
#      in the registry — a fragment for a lane nobody registered is automation
#      with no kill switch, which is what catalog/lanes.json exists to end;
#   7. catalog/lanes.d/ composes deterministically and nothing commits the
#      composition (case 4g), so the registry a box reads at runtime is the one
#      the per-lane files describe and only that;
#   8. a CRLF fragment is REFUSED rather than rendered — the CR would reach the
#      crontab, cron would hand bash a redirect target `1\r`, the lane would
#      fail every tick and every --check would stay green because the committed
#      file was rendered from the same bytes;
#   9. a hub-scoped lane whose fragment declares neither `# @hub-lanes` nor
#      `# @ungated` is refused — a hub lane with no lease check fires on every
#      box at once, and nothing downstream says so;
#  10. an unknown box id refuses with a reason, not a blank line.
# Run from anywhere: tests/registry-render-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "registry-render: jq is required"; exit 1; }

# --- 1. every box renders, and renders to the same bytes twice ---------------
# The box list is cron/boxes/<box>.d — the COMMITTED sources. Globbing the
# rendered cron/*.cron (what this did until BH-1247) is empty in a fresh
# checkout, so the loop would run zero times and every case below would pass
# having asserted nothing about any box.
BOXES=$(rendered_boxes)
NB=0
for B in $BOXES; do
  NB=$((NB+1))
  if OUT=$("$DIR/bin/render-cron.sh" --root "$DIR" "$B" 2>"$T/err"); then
    OUT2=$("$DIR/bin/render-cron.sh" --root "$DIR" "$B" 2>/dev/null)
    if [ "$OUT" = "$OUT2" ]; then ok
    else bad "1 box $B does not render to the same bytes twice: $(printf '%s\n' "$OUT" | diff - <(printf '%s\n' "$OUT2") | head -4 | tr '\n' ' ')"; fi
  else
    bad "1 render-cron.sh $B failed: $(head -2 "$T/err" | tr '\n' ' ')"
  fi
done
[ "$NB" -ge 2 ] && ok || bad "1z only $NB boxes found — the check would pass on an empty tree"

# A scratch copy every mutation case works in, so no case can disturb the next.
scratch_repo() {
  local d="$T/$1"
  scratch_rm "$d" || exit 1
  mkdir -p "$d"
  cp -R "$DIR/bin" "$DIR/cron" "$DIR/catalog" "$DIR/env-templates" "$d/"
  cp "$DIR/fleet.conf" "$d/fleet.conf"
  # The renders are GENERATED (BH-1247) and go with .gitignore, so a scratch
  # clone starts WITHOUT them even if the developer's tree happens to carry
  # some: a fixture that inherited a stale render would grade a tree nobody
  # ships, and case 4 would merge clean on files it had copied in rather than
  # on files that are not in git.
  cp "$DIR/.gitignore" "$d/.gitignore" 2>/dev/null || :
  rm -f "$d/catalog/lanes.json" "$d/catalog/.lanes.json.stamp" \
        "$d/env-templates/global.env.example"
  rm -f "$d"/cron/*.cron
}

# --- 2. a lane with no cadence fails the render, with nothing on stdout ------
scratch_repo "r2"
# The mutation goes into the SOURCE, catalog/lanes.d/<id>.json, not into the
# composed catalog/lanes.json. Since BH-1247 the composition is generated on
# demand by bin/lib/lanes-registry.sh, which re-composes whenever the sources'
# hash does not match its stamp — so editing the composed file directly is
# edited right back out from under the case before render-cron.sh reads it.
jq '.cadence = ""' "$T/r2/catalog/lanes.d/disk-clean.json" > "$T/r2/catalog/lanes.d/disk-clean.json.tmp"
mv "$T/r2/catalog/lanes.d/disk-clean.json.tmp" "$T/r2/catalog/lanes.d/disk-clean.json"
OUT2=$("$T/r2/bin/render-cron.sh" --root "$T/r2" project-4 2>"$T/e2"); RC2=$?
[ "$RC2" -ne 0 ] && ok || bad "2a a lane with no cadence rendered anyway (rc 0)"
[ -z "$OUT2" ] && ok || bad "2b a failed render wrote $(printf '%s' "$OUT2" | wc -l) lines to stdout"
grep -q 'disk-clean' "$T/e2" && ok || bad "2c the refusal does not name the lane: $(head -1 "$T/e2")"

# --- 3. a registered lane with no fragment fails the render ------------------
scratch_repo "r3"
rm -f "$T/r3"/cron/lanes/*-disk-clean.cron
OUT3=$("$T/r3/bin/render-cron.sh" --root "$T/r3" project-4 2>"$T/e3"); RC3=$?
[ "$RC3" -ne 0 ] && ok || bad "3a a registry lane with no fragment rendered anyway (rc 0)"
[ -z "$OUT3" ] && ok || bad "3b a failed render wrote to stdout"
grep -q 'disk-clean' "$T/e3" && ok || bad "3c the refusal does not name the lane: $(head -1 "$T/e3")"

# --- 4. two branches, two lanes, one clean merge -----------------------------
# The whole point of the change, tested the way it is actually used: two builds
# add two unrelated lanes at the same time. Before BH-1178 both appended to
# cron/project-4.cron and git called it a conflict; now they write two files.
# Adding a lane, the way a build does it: ONE registry file, ONE cron fragment,
# then the two generated files recomposed. No shared file is edited by hand.
add_lane() { # <repo> <id> <cadence> <minute>
  local r="$1" id="$2" cad="$3" min="$4"
  jq -n --arg i "$id" --arg c "$cad" '{
      id: $i, name: $i, scope: "box", script: ("bin/" + $i + ".sh"), cadence: $c,
      boxes: ["project-4"], switch: {kind: "flag", name: ("lane-off-" + $i), aliases: []},
      wired: false, knobs: [], stats: {cost_stage: null, cost_project_filter: null,
      lanes_row: false, log: ("logs/" + $i + ".log")}}' > "$r/catalog/lanes.d/$id.json"
  printf '%s * * * * /root/harness/bin/%s.sh >/dev/null 2>&1\n' "$min" "$id" \
    > "$r/cron/lanes/615-$id.cron"
  # ...and its knob, which is the other half of the ticket: two knobs documented
  # at the same time used to land in the same trailing lines of one 541-line file.
  printf '\n# ---- %s ----\n#%s_CAP=1\n' "$id" "$(printf '%s' "$id" | tr 'a-z-' 'A-Z_')" \
    > "$r/env-templates/lanes/900-$id.env.example"
  "$r/bin/lanes-build.sh" --root "$r" --write >/dev/null
  "$r/bin/render-cron.sh" --root "$r" --all >/dev/null
  "$r/bin/render-env-example.sh" --root "$r" --write >/dev/null
}
G="git -C $T/r4 -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false"
scratch_repo "r4"
( cd "$T/r4" && git init -q . && git add -A \
  && git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
$G checkout -q -b lane-a
add_lane "$T/r4" "zz-lane-a" "7 * * * *" "7"
$G add -A && $G commit -qm "lane a" >/dev/null
$G checkout -q main 2>/dev/null || $G checkout -q master
$G checkout -q -b lane-b
add_lane "$T/r4" "zz-lane-b" "9 * * * *" "9"
$G add -A && $G commit -qm "lane b" >/dev/null
if $G merge --no-edit lane-a >"$T/m4" 2>&1; then ok
else bad "4a two branches each adding a lane CONFLICTED: $(head -3 "$T/m4" | tr '\n' ' ')"; fi

# Then the generated files come back from their own builders over the merged
# tree — the same two commands bin/batch-resolve.sh runs off the `## Generated
# files` table. A union-merged artifact is never read as-is by anyone.
"$T/r4/bin/lanes-build.sh" --root "$T/r4" --write >"$T/b4" 2>&1 \
  && ok || bad "4b the registry would not recompose after the merge: $(head -2 "$T/b4" | tr '\n' ' ')"
"$T/r4/bin/render-cron.sh" --root "$T/r4" --all >"$T/c4" 2>&1 \
  && ok || bad "4c the crontabs would not re-render after the merge: $(head -2 "$T/c4" | tr '\n' ' ')"
grep -c 'zz-lane-[ab]\.sh' "$T/r4/cron/project-4.cron" | grep -qx 2 && ok \
  || bad "4d the merged render does not carry BOTH lanes ($(grep -c 'zz-lane' "$T/r4/cron/project-4.cron") of 2)"
[ "$(jq -r '[.lanes[]|select(.id|startswith("zz-lane-"))]|length' "$T/r4/catalog/lanes.json")" = 2 ] \
  && ok || bad "4e the merged registry does not carry both lanes"
"$T/r4/bin/render-env-example.sh" --root "$T/r4" --write >/dev/null 2>&1
[ "$(grep -c 'ZZ_LANE_[AB]_CAP' "$T/r4/env-templates/global.env.example")" = 2 ] \
  && ok || bad "4f the merged env template does not carry both knobs"

# --- 4g. and catalog/lanes.d/ composes, deterministically, uncommitted -------
"$DIR/bin/lanes-build.sh" --root "$DIR" --check >/dev/null 2>"$T/e4g" \
  && ok || bad "4g catalog/lanes.d/ is not valid, does not compose twice the same, or a copy is committed: $(head -2 "$T/e4g" | tr '\n' ' ')"

# --- 5. the env template is its topic files ----------------------------------
# --check validates the SOURCES and the determinism of the render (BH-1247); it
# no longer compares against a committed template, because there is none.
"$DIR/bin/render-env-example.sh" --root "$DIR" --check >/dev/null 2>"$T/e5" \
  && ok || bad "5a env-templates/lanes/ is not valid or does not render twice the same: $(head -2 "$T/e5" | tr '\n' ' ')"
scratch_repo "r5"
printf '\n# ---- zz probe ----\n#ZZ_PROBE=1\n' > "$T/r5/env-templates/lanes/999-zz-probe.env.example"
"$T/r5/bin/render-env-example.sh" --root "$T/r5" 2>/dev/null | tail -3 | grep -q 'ZZ_PROBE' \
  && ok || bad "5b a new topic file does not reach the render"
# --check-committed keeps the OLD byte comparison for a repo that still commits
# its template, and a stale committed copy must still fail it. (The scratch repo
# has no committed copy at all here, which is itself stale — a missing file is a
# mismatch, and rf_check has said so since BH-1178.)
"$T/r5/bin/render-env-example.sh" --root "$T/r5" --check-committed >/dev/null 2>&1 \
  && bad "5c --check-committed passed while the committed template was stale" || ok

# --- 6a. a CRLF fragment is refused, not rendered ----------------------------
scratch_repo "r6"
printf '47 4 * * * /root/harness/bin/disk-clean.sh >/dev/null 2>&1\r\n' \
  > "$T/r6/cron/lanes/610-disk-clean.cron"
OUT6=$("$T/r6/bin/render-cron.sh" --root "$T/r6" project-4 2>"$T/e6"); RC6=$?
[ "$RC6" -ne 0 ] && ok || bad "6a a CRLF fragment rendered anyway (rc 0)"
grep -q $'\r' <<<"$(printf '%s' "$OUT6")" && bad "6a2 a CR byte reached the rendered crontab" || ok
grep -qi 'CR' "$T/e6" && ok || bad "6a3 the refusal does not say what it refused: $(head -1 "$T/e6")"
printf '# ---- zz ----\r\n#ZZ=1\r\n' > "$T/r6/env-templates/lanes/999-zz.env.example"
"$T/r6/bin/render-env-example.sh" --root "$T/r6" >"$T/o6b" 2>"$T/e6b" \
  && bad "6a4 a CRLF env topic rendered anyway (rc 0)" || ok

# --- 6b. a hub lane must declare whether it is gated -------------------------
# The three that are legitimately ungated say so with `# @ungated <why>`; a
# fourth that simply forgot `# @hub-lanes` must not render silently.
scratch_repo "r7"
jq -n '{id:"zz-hub-lane",name:"zz",scope:"hub",script:"bin/zz-hub-lane.sh",
  cadence:"5 * * * *",boxes:["hub"],switch:{kind:"flag",name:"lane-off-zz",aliases:[]},
  wired:false,knobs:[],stats:{cost_stage:null,cost_project_filter:null,lanes_row:false,log:"logs/zz.log"}}' \
  > "$T/r7/catalog/lanes.d/zz-hub-lane.json"
printf '5 * * * * /root/harness/bin/zz-hub-lane.sh >/dev/null 2>&1\n' \
  > "$T/r7/cron/lanes/615-zz-hub-lane.cron"
"$T/r7/bin/lanes-build.sh" --root "$T/r7" --write >/dev/null
OUT7=$("$T/r7/bin/render-cron.sh" --root "$T/r7" hub 2>"$T/e7"); RC7=$?
[ "$RC7" -ne 0 ] && ok || bad "7a an ungated hub lane rendered anyway (rc 0)"
grep -q 'zz-hub-lane' <<<"$(printf '%s\n' "$OUT7")" && bad "7b the ungated hub line reached stdout" || ok
grep -q 'zz-hub-lane' "$T/e7" && ok || bad "7c the refusal does not name the lane: $(head -1 "$T/e7")"
# ...and declaring it, either way, renders
printf '# @ungated a test lane\n5 * * * * /root/harness/bin/zz-hub-lane.sh >/dev/null 2>&1\n' \
  > "$T/r7/cron/lanes/615-zz-hub-lane.cron"
"$T/r7/bin/render-cron.sh" --root "$T/r7" hub 2>/dev/null | grep -q 'zz-hub-lane' \
  && ok || bad "7d a declared-ungated hub lane does not render"

# --- 6c. an unknown box says why -------------------------------------------
E8=$("$DIR/bin/render-cron.sh" --root "$DIR" zz-no-such-box 2>&1 >/dev/null); RC8=$?
[ "$RC8" -ne 0 ] && ok || bad "8a an unknown box rendered (rc 0)"
grep -q 'no registry lane lists this box' <<<"$E8" \
  && ok || bad "8b an unknown box refuses with a blank reason: '$E8'"

# --- 6. every fragment names a registered lane -------------------------------
STRAY=""
for F in "$DIR"/cron/lanes/*.cron; do
  BN=$(basename "$F" .cron); N=${BN%%-*}; ID=${BN#*-}
  case "$N" in ''|*[!0-9]*) STRAY="$STRAY $BN(bad-name)"; continue ;; esac
  jq -e --arg i "$ID" '.lanes[]|select(.id==$i)' "$REG" >/dev/null 2>&1 || STRAY="$STRAY $ID"
done
[ -z "${STRAY// /}" ] && ok || bad "6 cron fragments for lanes the registry does not carry:$STRAY"

echo "registry-render: $PASS passed, $FAIL failed  ($NB boxes, $(ls "$DIR"/cron/lanes/*.cron | wc -l | tr -d ' ') lane fragments, $(ls "$DIR"/env-templates/lanes/*.env.example | wc -l | tr -d ' ') env topics)"
[ "$FAIL" -eq 0 ]
