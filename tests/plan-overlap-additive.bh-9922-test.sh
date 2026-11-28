#!/bin/bash
# tests/plan-overlap-additive.bh-9922-test.sh — BH-9922 scope 2: a collision on
# an additive shared file alone does not serialize two builds.
#
# THE CASE (project-3, 2026-11-23). Seven plans stood down behind TK-797 (PR
# #1326) for 2 hours. PR #1326 adds two fields inside model Application. The
# seven tickets were about recordings, credits and events. The probable shared
# file was prisma/schema.prisma, a file both sides only add to.
#
# The REAL scripts run in scratch harnesses. No network: the jobs client is a
# stub, gh_rest is a fixture lib, and a fake gh and a fake curl on PATH record
# any call (the budget check B0 asserts 0).
#   L1-L9  bin/lib/additive-overlap.sh: ao_entry, ao_patch_blocks,
#          ao_plan_blocks, ao_pair_judge and the per-project settings row
#   P1-P5  bin/plan-overlap.sh: different models build (additive-only), the same
#          model defers and names it (symbols=), the line through the existing
#          readers, more=, an unreadable other side, a code file, knob off
#   S1-S5  bin/plan-sibling.sh inflight against PR #1326's real file shape:
#          other model builds, same model defers, no patch defers, the .models
#          cache makes 0 files GETs, a code file still defers
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/bh-9922-project-3"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/additive-overlap.sh"
SCH=prisma/schema.prisma

# The budget seam: a gh or curl that is ever run is a real vendor call.
mkdir -p "$T/stub"
printf '#!/bin/bash\necho "gh $*" >> "%s/vendor-calls"\nexit 99\n' "$T" > "$T/stub/gh"
printf '#!/bin/bash\necho "curl $*" >> "%s/vendor-calls"\nexit 99\n' "$T" > "$T/stub/curl"
chmod +x "$T/stub/gh" "$T/stub/curl"
: > "$T/vendor-calls"

# The target repo: main's schema.
R="$T/repo"; mkdir -p "$R/prisma"
cp "$FX/schema.prisma" "$R/prisma/schema.prisma"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m fixture || bad "fixture repo"

# ============================== L. the lib ==============================
mkdir -p "$T/lh"
lib() { env -u PLAN_OVERLAP_ADDITIVE_FILES HARNESS="$T/lh" LANE_GATE_DISABLE=1 AO_REPO_DIR="$R" PATH="$T/stub:$PATH" \
  bash -c '. "$1" || exit 90; shift; eval "$*"' _ "$LIB" "$@"; }
jq -r '.[] | select(.filename=="prisma/schema.prisma") | .patch' "$FX/pr-1326-files.json" > "$T/pr1326.patch"

# L1 / L2 the entry and its near miss
out=$(lib "ao_entry $SCH"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$SCH" ] && ok || bad "L1: ao_entry $SCH must match the default list, rc=$rc out=[$out]"
lib "ao_entry prisma/schema.prisma.bak" >/dev/null && bad "L2: prisma/schema.prisma.bak is not the schema entry" || ok
lib "ao_entry src/lib/forms/service.ts" >/dev/null && bad "L2: a source file is not on the list" || ok
# L3 PR #1326's schema patch edits one model
out=$(lib "ao_patch_blocks '$T/pr1326.patch'")
[ "$out" = model:Application ] && ok || bad "L3: the PR #1326 patch must print model:Application only, got [$out]"
# L4 a patch inside datasource db
printf '@@ -1,4 +1,4 @@\n datasource db {\n-  provider = "postgresql"\n+  provider = "postgres"\n   url      = env("DATABASE_URL")\n }\n' > "$T/ds.patch"
out=$(lib "ao_patch_blocks '$T/ds.patch'")
[ "$out" = datasource:db ] && ok || bad "L4: a datasource edit must print datasource:db, got [$out]"
# L4b a new model added after a block closes, and a comment line is not a change
printf '@@ -40,3 +40,8 @@ model Event {\n   startAt DateTime\n }\n+\n+// credits\n+model CreditLedger {\n+  id String @id\n+}\n' > "$T/new.patch"
out=$(lib "ao_patch_blocks '$T/new.patch'")
[ "$out" = model:CreditLedger ] && ok || bad "L4b: an added model prints model:CreditLedger only, got [$out]"
# L5 an empty patch
: > "$T/empty.patch"
out=$(lib "ao_patch_blocks '$T/empty.patch'")
[ "$out" = '?' ] && ok || bad "L5: an empty patch must print ?, got [$out]"
# L6 docs/API.md is safe; L7 a change-log fragment against its directory
lib "ao_pair_judge 'docs/API.md ~ docs/API.md' '$FX/plan-TK-815.md' -" && ok || bad "L6: docs/API.md ~ docs/API.md must be safe"
lib "ao_pair_judge 'changelog.d/TK-815.md ~ changelog.d' '$FX/plan-TK-815.md' -" && ok || bad "L7: changelog.d/TK-815.md ~ changelog.d must be safe"
lib "ao_pair_judge 'changelog.d/TK-815.md ~ changelog.d/' '$FX/plan-TK-815.md' -" && ok || bad "L7: changelog.d/TK-815.md ~ changelog.d/ must be safe"
lib "ao_pair_judge 'src/lib/forms/service.ts ~ src/lib/forms/service.ts' '$FX/plan-TK-815.md' -"; rc=$?
[ "$rc" = 1 ] && ok || bad "L7: a source file pair is a collision (rc 1), rc=$rc"
lib "ao_pair_judge '$SCH ~ prisma/schema.prisma.bak' '$FX/plan-TK-815.md' -"; rc=$?
[ "$rc" = 1 ] && ok || bad "L7: two different entries are a collision, rc=$rc"
# L8 whole words, case-sensitive
printf 'Add a field to Application.\n' > "$T/p-app.md"
printf 'Touch ApplicationForm only; the application flow is unchanged.\n' > "$T/p-form.md"
printf 'Add model CreditLedger.\n' > "$T/p-new.md"
out=$(lib "ao_plan_blocks '$T/p-app.md' '$R/$SCH'")
[ "$out" = model:Application ] && ok || bad "L8: a plan sentence naming Application must give model:Application, got [$out]"
out=$(lib "ao_plan_blocks '$T/p-form.md' '$R/$SCH'")
[ "$out" = model:ApplicationForm ] && ok || bad "L8: ApplicationForm must not match Application, got [$out]"
out=$(lib "ao_plan_blocks '$T/p-new.md' '$R/$SCH'")
[ "$out" = new:CreditLedger ] && ok || bad "L8: a model main has not got is new:CreditLedger, got [$out]"
# Pair rule table (Failure modes (1))
printf 'model:Application\n' > "$T/b-app"; printf 'model:Application\ndatasource:db\n' > "$T/b-ds"
printf '?\n' > "$T/b-q"; printf 'model:CreditLedger\n' > "$T/b-cl"
lib "ao_pair_judge '$SCH ~ $SCH' '$FX/plan-TK-815.md' '$T/b-app'" && ok || bad "L8t: Recording vs model:Application must be safe"
out=$(lib "ao_pair_judge '$SCH ~ $SCH' '$T/p-app.md' '$T/b-app'; echo \"rc=\$? sym=\$AO_SYMBOLS\"")
[ "$out" = "rc=1 sym=model:Application" ] && ok || bad "L8t: Application on both sides is rc 1 with model:Application, got [$out]"
out=$(lib "ao_pair_judge '$SCH ~ $SCH' '$FX/plan-TK-815.md' '$T/b-ds'; echo \"rc=\$? sym=\$AO_SYMBOLS\"")
[ "$out" = "rc=1 sym=datasource:db" ] && ok || bad "L8t: a datasource edit on the other side is rc 1, got [$out]"
# L8g the candidate side's datasource/generator edit (plan text names the block
# kind and its name); the word `client` alone is not the generator block.
printf 'Add previewFeatures to the generator client.\n' > "$T/p-gen.md"
printf 'Show the client list on the page.\n' > "$T/p-cli.md"
out=$(lib "ao_plan_blocks '$T/p-gen.md' '$R/$SCH'")
[ "$out" = generator:client ] && ok || bad "L8g: a plan naming the generator client block must give generator:client, got [$out]"
out=$(lib "ao_plan_blocks '$T/p-cli.md' '$R/$SCH'")
[ -z "$out" ] && ok || bad "L8g: the word client alone is not the generator block, got [$out]"
out=$(lib "ao_pair_judge '$SCH ~ $SCH' '$T/p-gen.md' '$T/b-app'; echo \"rc=\$? sym=\$AO_SYMBOLS\"")
[ "$out" = "rc=1 sym=generator:client" ] && ok || bad "L8g: a generator edit on the candidate side is rc 1, got [$out]"
lib "ao_pair_judge '$SCH ~ $SCH' '$FX/plan-TK-815.md' '$T/b-q'"; rc=$?
[ "$rc" = 2 ] && ok || bad "L8t: an unknown patch (?) is unjudged rc 2, rc=$rc"
lib "ao_pair_judge '$SCH ~ $SCH' '$FX/plan-TK-815.md' -"; rc=$?
[ "$rc" = 2 ] && ok || bad "L8t: no other side (-) is unjudged rc 2, rc=$rc"
out=$(lib "ao_pair_judge '$SCH ~ $SCH' '$T/p-new.md' '$T/b-cl'; echo \"rc=\$? sym=\$AO_SYMBOLS\"")
[ "$out" = "rc=1 sym=model:CreditLedger" ] && ok || bad "L8t: both sides add model CreditLedger: rc 1, got [$out]"
out=$(env -u PLAN_OVERLAP_ADDITIVE_FILES HARNESS="$T/lh" LANE_GATE_DISABLE=1 AO_REPO_DIR="$T/nowhere" \
  bash -c '. "$1"; ao_pair_judge "prisma/schema.prisma ~ prisma/schema.prisma" "$2" "$3"; echo "rc=$?"' _ "$LIB" "$FX/plan-TK-815.md" "$T/b-app")
[ "$out" = rc=2 ] && ok || bad "L8t: main's schema unreadable is unjudged rc 2, got [$out]"
lib_off=$(env HARNESS="$T/lh" LANE_GATE_DISABLE=1 AO_REPO_DIR="$R" PLAN_OVERLAP_ADDITIVE_FILES=off \
  bash -c '. "$1"; ao_entry prisma/schema.prisma; echo "rc=$?"' _ "$LIB")
[ "$lib_off" = rc=1 ] && ok || bad "L8t: knob off empties the list, got [$lib_off]"
# global.env fallback
mkdir -p "$T/lg/env"; printf 'PLAN_OVERLAP_ADDITIVE_FILES="docs/API.md"\n' > "$T/lg/env/global.env"
out=$(env -u PLAN_OVERLAP_ADDITIVE_FILES HARNESS="$T/lg" LANE_GATE_DISABLE=1 bash -c '. "$1"; ao_entry prisma/schema.prisma; echo "rc=$?"' _ "$LIB")
[ "$out" = rc=1 ] && ok || bad "L8t: env/global.env sets the list, got [$out]"

# L9 a per-project settings row replaces the fleet default for that project only
mkdir -p "$T/l9/state" "$T/l9/logs"
if bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1; then
  jq -n --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:{"lib.plan-hotspot.project-3.plan_overlap_additive_files":"docs/API.md"},seeded:{}}' \
    > "$T/l9/state/settings-cache.json"
  l9() { env -u PLAN_OVERLAP_ADDITIVE_FILES HARNESS="$T/l9" LANE_REGISTRY="$T/lanes.json" AO_PROJECT="$1" PATH="$T/stub:$PATH" \
    bash -c '. "$2/bin/lib/lane-gate.sh" || exit 90; . "$3" || exit 91; ao_entry prisma/schema.prisma >/dev/null; echo "rc=$?"' _ "$1" "$DIR" "$LIB"; }
  out=$(l9 project-3)
  [ "$out" = rc=1 ] && ok || bad "L9: the project-3 row (docs/API.md) must drop the schema entry for project-3, got [$out]"
  out=$(l9 project-1)
  [ "$out" = rc=0 ] && ok || bad "L9: another project keeps the fleet default, got [$out]"
else
  bad "L9: bin/lanes-build.sh could not render the registry"
fi

# ============================== P. plan-overlap.sh ==============================
W="$T/W"
STUB="$T/jobs-client.stub.sh"
cat > "$STUB" <<SH
JOBS_BOX=box-test
[ -r "\$HARNESS/bin/lib/jobs/jobs.sh" ] && . "\$HARNESS/bin/lib/jobs/jobs.sh"
_jobs_req() {
  case "\$1 \$2" in
    "GET /api/file-claims?project=project-3") echo '{"claims":[],"truncated":false}' ;;
    "GET /api/conflict-hotspots?project=project-3&limit="*) echo '{"project":"project-3","run":null,"hotspots":[],"total":0,"truncated":false}' ;;
    "PUT /api/jobs/"*"/artifacts") echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
SH
scratch_rm "$W"
mkdir -p "$W/bin/lib" "$W/env" "$W/flags" "$W/logs" "$W/builds" "$W/state/claims/project-3"
cp "$STUB" "$W/bin/jobs-client.sh"
for L in bin/plan-overlap.sh bin/touch-files.sh bin/planned-files.sh bin/lib/jobs/jobs.sh; do
  scratch_install_closure "$L" "$W" >/dev/null || bad "setup: closure of $L"
done
printf 'project-3  example-org/project-3   ob  -  0 local -\n' > "$W/fleet.conf"
bdir() { echo "$W/builds/project-3-$1-20261123180000"; }
build() { # build <KEY> <plan.md> — a live build dir whose plan declares its files
  local K="$1" D; D=$(bdir "$K")
  scratch_rm "$D"; mkdir -p "$D"
  cp "$2" "$D/plan.md"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D" >/dev/null 2>&1
  env HARNESS="$W" bash "$W/bin/touch-files.sh" "$D" project-3 >/dev/null 2>&1
}
reset() { scratch_rm "$W/builds"; scratch_rm "$W/state"; scratch_rm "$W/logs"; mkdir -p "$W/builds" "$W/state/claims/project-3" "$W/logs"; }
po() { # po <KEY> [env...] -> RC OUT ERR
  local K="$1"; shift
  OUT=$(env -u PLAN_OVERLAP_ADDITIVE_FILES LANE_GATE_DISABLE=1 PATH="$T/stub:$PATH" HARNESS="$W" PLAN_OVERLAP_REPO="$R" "$@" \
        bash "$W/bin/plan-overlap.sh" project-3 "$(bdir "$K")" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
}
mkplan() { # mkplan <out> <model sentence> [extra file]...
  local o="$1" s="$2" f; shift 2
  { printf '# Plan\n\n## Files to touch\n\n- `prisma/schema.prisma` — %s\n' "$s"
    for f in "$@"; do printf -- '- `%s` — edit.\n' "$f"; done
    printf '\n## Tasks\n\n%s\n' "$s"; } > "$o"
}

# P1 two plans add different models (Recording vs CreditLedger) -> both build
reset; build TK-815 "$FX/plan-TK-815.md"; build TK-826 "$FX/plan-TK-826.md"
grep -qxF "$SCH" "$(bdir TK-815)/touch-files.txt" && grep -qxF "$SCH" "$(bdir TK-826)/touch-files.txt" && ok \
  || bad "P1 fixture: both touch lists must name $SCH"
po TK-815
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P1: THE BUG: two plans that add different models must both build, rc=$RC out=[$OUT]"
grep -q "PLAN_HOTSPOT TK-815 choice=build vs TK-826 additive-only files=\[$SCH,$SCH\]" "$W/logs/plan-hotspot.log" 2>/dev/null && ok \
  || bad "P1: logs/plan-hotspot.log must say additive-only, got [$(cat "$W/logs/plan-hotspot.log" 2>/dev/null)]"

# P2 both plans name model Application -> defer, and the line names the model
reset
mkplan "$T/p2a.md" "add a field to model Application."
mkplan "$T/p2b.md" "add an index to model Application."
build TK-815 "$T/p2a.md"; build TK-826 "$T/p2b.md"
po TK-815
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-815 vs TK-826 files=[$SCH,$SCH] symbols=[model:Application]" ] && ok \
  || bad "P2: the same model must defer and name it, rc=$RC out=[$OUT]"
# P2 the line through the existing readers
DLINE="BUILD_DEFERRED $OUT"
BL=$(bash -c '. "$1/bin/lib/deferral-after.sh"; . "$1/bin/lib/defer-after-stop.sh"; _dfs_blocker TK-815 "$2"' _ "$DIR" "$DLINE")
[ "${BL%%$'\t'*}" = TK-826 ] && ok || bad "P2: _dfs_blocker must still read the blocker off the line, got [$BL]"
grep -qF 'files=\[([^]]*)\]' "$DIR/bin/defer-report.sh" || bad "P2: bin/defer-report.sh no longer carries the regex this case copies"
if [[ $DLINE =~ ^BUILD_DEFERRED\ OVERLAP_DEFER\ [^\ ]+\ vs\ ([^\ ]+)\ files=\[([^]]*)\] ]] \
   && [ "${BASH_REMATCH[1]}" = TK-826 ] && [ "${BASH_REMATCH[2]}" = "$SCH,$SCH" ]; then ok
else bad "P2: defer-report.sh's regex must still give the blocker and the files"; fi
PA=$(printf '%s' "$OUT" | grep -o 'files=\[[^]]*\]' | head -1)
[ "$PA" = "files=[$SCH,$SCH]" ] && ok || bad "P2: plan-after.sh's files grep must still match, got [$PA]"
# P2b more than 3 real pairs: the line carries 3 and more=1
reset
mkplan "$T/p2c.md" "add a field to model Application." src/a.ts src/b.ts src/c.ts
mkplan "$T/p2d.md" "add an index to model Application." src/a.ts src/b.ts src/c.ts
build TK-815 "$T/p2c.md"; build TK-826 "$T/p2d.md"
po TK-815
[ "$RC" = 1 ] && [[ "$OUT" =~ ^OVERLAP_DEFER\ TK-815\ vs\ TK-826\ files=\[[^]]*\]\ symbols=\[model:Application\]\ more=1$ ]] \
  && [ "$(printf '%s' "$OUT" | sed -n 's/.*files=\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | grep -c .)" = 6 ] && ok \
  || bad "P2b: 4 real pairs must give 3 pairs on the line and more=1, rc=$RC out=[$OUT]"

# P3 the other build has no plan.md here -> kept (unjudged)
reset; build TK-815 "$FX/plan-TK-815.md"; build TK-826 "$FX/plan-TK-826.md"
rm -f "$(bdir TK-826)/plan.md"
po TK-815
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-815 vs TK-826 files=[$SCH,$SCH]" ] && ok \
  || bad "P3: an other side with no plan must stay a collision, rc=$RC out=[$OUT]"
# P4 a shared source file still defers
reset
mkplan "$T/p4a.md" "add a field to model Recording." src/lib/forms/service.ts
mkplan "$T/p4b.md" "add model CreditLedger." src/lib/forms/service.ts
build TK-815 "$T/p4a.md"; build TK-826 "$T/p4b.md"
po TK-815
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-815 vs TK-826 files=[src/lib/forms/service.ts,src/lib/forms/service.ts]" ] && ok \
  || bad "P4: src/lib/forms/service.ts must defer on itself alone, rc=$RC out=[$OUT]"
# P5 knob off -> P1's pair defers as before
reset; build TK-815 "$FX/plan-TK-815.md"; build TK-826 "$FX/plan-TK-826.md"
po TK-815 PLAN_OVERLAP_ADDITIVE_FILES=off
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-815 vs TK-826 files=[$SCH,$SCH]" ] && ok \
  || bad "P5: PLAN_OVERLAP_ADDITIVE_FILES=off must restore the defer, rc=$RC out=[$OUT]"

# ============================== S. plan-sibling.sh inflight ==============================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/fx"
printf 'project-3  example-org/project-3  -  -     0 local -\n' > "$H/fleet.conf"
cat > "$H/bin/lib/gh-rest-list.sh" <<'SH'
gh_rest_pr_list_all() { cat "$HARNESS/fx/pulls.json"; }
gh_rest() {
  local n
  case "$2" in repos/example-org/project-3/pulls/*/files) ;; *) return 75 ;; esac
  n=${2#repos/example-org/project-3/pulls/}; n=${n%/files}
  echo "$n" >> "$HARNESS/fx/files-gets"
  cat "$HARNESS/fx/files.$n.json"
}
gh_rest_comment() { return 0; }
SH
scratch_install_closure bin/plan-sibling.sh "$H" >/dev/null || bad "setup: closure of bin/plan-sibling.sh"
[ -e "$H/bin/fleet-conf.sh" ] || cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
B="$T/b"
SHA1=1326132613261326132613261326132613261326
smkb() { # smkb <plan.md> — TK-826's build dir, the schema hot
  scratch_rm "$B"; mkdir -p "$B"
  cp "$1" "$B/plan.md"
  jq -n '{key:"TK-826",body:""}' > "$B/ticket-meta.json"
  sed -n 's/^- `\([^`]*\)`.*/\1/p' "$1" > "$B/planned-files.txt"
  printf '%s\nsrc/lib/forms/service.ts\n' "$SCH" > "$B/.hotspots.txt"
  printf '2026-11-23T18:16:00Z [project-3/TK-826] HOTSPOT_CLAIM n=2 source=rows\n' > "$B/pipeline.log"
}
sreset() { # sreset [files json] — PR #1326 on ticket/TK-797 is the only open PR
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"; mkdir -p "$H/fx" "$H/logs"
  jq -nc --arg s "$SHA1" '[{number:1326,state:"open",head:{ref:"ticket/TK-797",sha:$s}}]' > "$H/fx/pulls.json"
  cp "${1:-$FX/pr-1326-files.json}" "$H/fx/files.1326.json"
}
ps() { # ps [env...] -> RC OUT ERR
  OUT=$(env -u PLAN_OVERLAP_ADDITIVE_FILES LANE_GATE_DISABLE=1 PATH="$T/stub:$PATH" FLEET_CONF="$H/fleet.conf" HARNESS="$H" PLAN_OVERLAP_REPO="$R" "$@" \
        bash "$H/bin/plan-sibling.sh" inflight project-3 "$B" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
gets() { awk 'NF' "$H/fx/files-gets" 2>/dev/null | wc -l | tr -d ' '; }

# S1 TK-826 (model CreditLedger) vs PR #1326 (model Application) -> build
sreset; smkb "$FX/plan-TK-826.md"
ps
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S1: THE BUG: TK-826 must not wait on PR #1326 for the schema alone, rc=$RC out=[$OUT] err=[$ERR]"
case "$ERR" in *"PLAN_INFLIGHT TK-826 choice=build vs TK-797 additive-only"*) ok ;; *) bad "S1: stderr must log additive-only, got [$ERR]" ;; esac
[ "$(cat "$H/state/plan-inflight/project-3/1326.$SHA1.models" 2>/dev/null)" = model:Application ] && ok \
  || bad "S1: the PR's blocks are cached in 1326.<sha>.models, got [$(cat "$H/state/plan-inflight/project-3/1326.$SHA1.models" 2>/dev/null)]"
# S4 a second run reads both caches: 0 files GETs
: > "$H/fx/files-gets"; ps
[ "$RC" = 0 ] && [ "$(gets)" = 0 ] && ok || bad "S4: a second run must read the .models cache and make 0 files GETs, rc=$RC gets=$(gets)"
# S4b a file-list cache with no .models file: one GET fills it
rm -f "$H/state/plan-inflight/project-3/1326.$SHA1.models"; : > "$H/fx/files-gets"; ps
[ "$RC" = 0 ] && [ "$(gets)" = 1 ] && [ -s "$H/state/plan-inflight/project-3/1326.$SHA1.models" ] && ok \
  || bad "S4b: a cached file list with no .models makes one GET, rc=$RC gets=$(gets)"
# S4c a .models file older than 7 days is deleted on the next write
mkdir -p "$H/state/plan-inflight/project-3"; : > "$H/state/plan-inflight/project-3/9.old.models"
touch -d '8 days ago' "$H/state/plan-inflight/project-3/9.old.models"
rm -f "$H/state/plan-inflight/project-3/1326.$SHA1.models"; ps
[ ! -e "$H/state/plan-inflight/project-3/9.old.models" ] && ok || bad "S4c: an 8-day-old .models file must be deleted on write"
# S2 a plan that names model Application -> defer and name it
mkplan "$T/s2.md" "add a field to model Application."
sreset; smkb "$T/s2.md"; ps
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-826 vs TK-797 files=[$SCH,$SCH] symbols=[model:Application]" ] && ok \
  || bad "S2: a plan on PR #1326's model must defer and name it, rc=$RC out=[$OUT] err=[$ERR]"
# S3 GitHub omits the patch -> kept
jq 'map(if .filename == "prisma/schema.prisma" then del(.patch) else . end)' "$FX/pr-1326-files.json" > "$T/nopatch.json"
sreset "$T/nopatch.json"; smkb "$FX/plan-TK-826.md"; ps
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-826 vs TK-797 files=[$SCH,$SCH]" ] && ok \
  || bad "S3: a schema patch GitHub omits must stay a collision, rc=$RC out=[$OUT]"
# S5 a shared hot source file still defers
mkplan "$T/s5.md" "add model CreditLedger." src/lib/forms/service.ts
sreset; smkb "$T/s5.md"; ps
[ "$RC" = 1 ] && [[ "$OUT" == "OVERLAP_DEFER TK-826 vs TK-797 files=["*"src/lib/forms/service.ts,src/lib/forms/service.ts"* ]] \
  && [[ "$OUT" != *"prisma/schema.prisma"* ]] && ok \
  || bad "S5: src/lib/forms/service.ts must defer, the schema pair dropped, rc=$RC out=[$OUT]"
# S5b knob off -> S1 defers as before
sreset; smkb "$FX/plan-TK-826.md"; ps PLAN_OVERLAP_ADDITIVE_FILES=off
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-826 vs TK-797 files=[$SCH,$SCH]" ] && ok \
  || bad "S5b: knob off must restore the defer, rc=$RC out=[$OUT]"

# B0 the budget: no real vendor call in the whole suite
[ ! -s "$T/vendor-calls" ] && ok || bad "B0: the suite made real vendor calls: $(head -3 "$T/vendor-calls")"

echo "plan-overlap-additive.bh-9922: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
