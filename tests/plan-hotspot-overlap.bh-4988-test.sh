#!/bin/bash
# tests/plan-hotspot-overlap.bh-4988-test.sh — BH-4988 (BH-4975.3): the planner
# holds a plan that needs a file an in-flight build claims until that build is
# finished and has no open PR (`After: <KEY>`, never `Blocked-by:`), and never
# holds a plan whose only overlap is on fragment files.
#
# One scratch harness $H serving the REAL bin/plan-overlap.sh and
# bin/plan-after.sh, plus a fixture target repo whose `## Generated files`
# table declares `catalog/lanes.json` and the glob `cron/*.cron`. Stubs: the
# open-PR precheck answers from $H/open-pr.<KEY> ("<rc> [#n]"), a jobs-client
# only in the fleet case, and a `gh` on PATH that records any call (this
# change must never touch an issue). The gates.sh blocks are driven in case 13.
#
# No network, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/builds" "$H/state/claims/proj" "$T/stub"
printf 'proj  example-org/proj   -  -  0 local -\n' > "$H/fleet.conf"

# The open-PR precheck stub, written BEFORE the closure install (which never
# clobbers a file already there). It refuses any slug but the fleet.conf one,
# so a wrong slug resolution reads as unreadable, not as "no PR".
cat > "$H/bin/lib/open-pr-precheck.sh" <<'SH'
open_pr_for_key() {
  local f="$HARNESS/open-pr.$2" a="" n=""
  [ "$1" = example-org/proj ] || return 2
  [ -r "$f" ] || return 2
  read -r a n < "$f"
  [ "$a" = 0 ] && printf '%s\n' "$n"
  return "$a"
}
SH
cat > "$T/stub/gh" <<SH
#!/bin/bash
echo "\$*" >> "$T/gh-called"
exit 99
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

# gates.sh runs both only behind `[ -x ]`.
for f in "$DIR/bin/plan-overlap.sh" "$DIR/bin/plan-after.sh"; do
  [ -x "$f" ] && ok || bad "$f must be executable"
done
scratch_install_closure bin/plan-overlap.sh "$H" >/dev/null || bad "closure install: plan-overlap.sh"
scratch_install_closure bin/plan-after.sh "$H" >/dev/null || bad "closure install: plan-after.sh"
for f in planned-files.sh fleet-conf.sh; do
  [ -e "$H/bin/$f" ] || cp "$DIR/bin/$f" "$H/bin/$f"
done

# The fixture target repo: the table lives where gen_table_paths reads it.
R="$T/repo"
mkdir -p "$R/docs/verification-map/index"
cat > "$R/docs/verification-map/index/tail.md" <<'MD'
## Generated files

| Path | Regenerate with |
|---|---|
| `catalog/lanes.json` | `bin/lanes-build.sh` |
| `cron/*.cron` | `bin/render-cron.sh` |
MD
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.email=t@t -c user.name=t commit -qm fixture || bad "fixture repo commit"

STAMPD=20261007000000
bdir() { printf '%s/builds/proj-%s-%s' "$H" "$1" "$STAMPD"; }
mkbuild() { # mkbuild <KEY> <file>... — a live build dir for that key
  local K="$1" D; shift
  D=$(bdir "$K"); mkdir -p "$D"
  printf '# plan for %s\n' "$K" > "$D/plan.md"
  printf '%s\n' "$@" > "$D/planned-files.txt"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
}
claimf() { local K="$1"; shift; printf '%s\n' "$@" > "$H/state/claims/proj/$K"; }
marker() { mkdir -p "$H/state/overlap-after/proj"; printf '%s\t%s\n' "$2" "$3" > "$H/state/overlap-after/proj/$1"; }
openpr() { printf '%s\n' "$2" > "$H/open-pr.$1"; }
reset() {
  scratch_rm "$H/builds"; scratch_rm "$H/state"; scratch_rm "$H/logs"
  mkdir -p "$H/builds" "$H/state/claims/proj" "$H/logs"
  rm -f "$H"/open-pr.* "$H/bin/jobs-client.sh" "$H/flags/plan-overlap-off"
}
po() { # po <KEY> — plan-overlap for that key's build; sets RC OUT ERR
  OUT=$(HARNESS="$H" PLAN_OVERLAP_REPO="$R" bash "$H/bin/plan-overlap.sh" proj "$(bdir "$1")" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
pa() { # pa <args>... — plan-after; sets RC OUT ERR
  OUT=$(HARNESS="$H" bash "$H/bin/plan-after.sh" "$@" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
hlog() { cat "$H/logs/plan-hotspot.log" 2>/dev/null; }
now() { date -u +%s; }

# ---------- 1. a claimed non-splittable file -> After:, no Blocked-by -------
reset
claimf BH-A bin/x.sh; mkbuild BH-B bin/x.sh
po BH-B
[ "$RC" = 1 ] && ok || bad "case 1: plan-overlap must defer BH-B, rc=$RC out=$OUT"
[ "$OUT" = "OVERLAP_DEFER BH-B vs BH-A files=[bin/x.sh,bin/x.sh]" ] && ok \
  || bad "case 1: the OVERLAP_DEFER line changed shape: $OUT"
pa record proj BH-B "$OUT"
[ "$RC" = 0 ] && ok || bad "case 1: record must rc 0, rc=$RC err=$ERR"
[ "$(cut -f1 "$H/state/overlap-after/proj/BH-B" 2>/dev/null)" = BH-A ] && ok \
  || bad "case 1: marker must name BH-A: $(cat "$H/state/overlap-after/proj/BH-B" 2>&1)"
case "$OUT" in "PLAN_HOTSPOT BH-B choice=after after=BH-A fold=not-offered files=[bin/x.sh,bin/x.sh]") ok ;;
  *) bad "case 1: record stdout: $OUT" ;; esac
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=after after=BH-A fold=not-offered' && ok \
  || bad "case 1: logs/plan-hotspot.log lacks the after line: $(hlog)"
if grep -rq 'Blocked-by' "$H/state" "$H/logs" || grep -q 'Blocked-by' <<<"$OUT"; then
  bad "case 1: something wrote Blocked-by"; else ok; fi

# ---------- 2. fragment-only overlap is not held ----------------------------
reset
claimf BH-A catalog/lanes.d/a.json catalog/lanes.json catalog/lanes.d
mkbuild BH-B catalog/lanes.d/b.json catalog/lanes.json catalog/lanes.d
po BH-B
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "case 2: generated+fragment overlap must not defer, rc=$RC out=$OUT"
case "$ERR" in *"PLAN_HOTSPOT BH-B choice=build vs BH-A fragment-only files=[catalog/lanes.json,catalog/lanes.json]"*) ok ;;
  *) bad "case 2: stderr lacks the choice=build line: $ERR" ;; esac
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=build vs BH-A fragment-only' && ok \
  || bad "case 2: logs/plan-hotspot.log lacks the build line: $(hlog)"
# 2b. a bare fragment dir on one side and a file under it; a glob row
reset
claimf BH-A catalog/lanes.d cron/box1.cron
mkbuild BH-B catalog/lanes.d/b.json cron/box1.cron
po BH-B
[ "$RC" = 0 ] && ok || bad "case 2b: bare fragment dir + glob-declared render must not defer, rc=$RC out=$OUT"
# 2c. the knob widens the set; a trailing slash is stripped
reset
claimf BH-A docs/frag; mkbuild BH-B docs/frag/b.md
OUT=$(HARNESS="$H" PLAN_OVERLAP_REPO="$R" PLAN_OVERLAP_FRAGMENT_DIRS="docs/frag/" \
      bash "$H/bin/plan-overlap.sh" proj "$(bdir BH-B)" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "case 2c: PLAN_OVERLAP_FRAGMENT_DIRS must be read, rc=$RC out=$OUT"
po BH-B
[ "$RC" = 1 ] && ok || bad "case 2c: without the knob docs/frag is not a fragment dir, rc=$RC"
printf 'export PLAN_OVERLAP_FRAGMENT_DIRS="docs/frag catalog/lanes.d"\n' > "$H/env/global.env"
po BH-B
[ "$RC" = 0 ] && ok || bad "case 2c: env/global.env must be read, rc=$RC out=$OUT"
rm -f "$H/env/global.env"

# ---------- 3. the same fragment entry on both sides is a real overlap ------
reset
claimf BH-A catalog/lanes.d/a.json; mkbuild BH-B catalog/lanes.d/a.json
po BH-B
[ "$OUT" = "OVERLAP_DEFER BH-B vs BH-A files=[catalog/lanes.d/a.json,catalog/lanes.d/a.json]" ] && [ "$RC" = 1 ] && ok \
  || bad "case 3: same fragment file must defer, rc=$RC out=$OUT"
# 3b. adversarial negatives: never fragment-safe
for f in worker/jobs/schema.sql bin/plan-overlap.sh cron/x.cron.bak; do
  reset; claimf BH-A "$f"; mkbuild BH-B "$f"; po BH-B
  [ "$RC" = 1 ] && ok || bad "case 3b: $f on both sides must defer, rc=$RC out=$OUT"
done
# 3c. prefix without a / boundary is not an overlap at all, and logs nothing
reset; claimf BH-A catalog/lanes.d; mkbuild BH-B catalog/lanes.d.bak/x; po BH-B
[ "$RC" = 0 ] && [ -z "$(hlog)" ] && ok || bad "case 3c: lanes.d vs lanes.d.bak/x, rc=$RC log=$(hlog)"

# ---------- 4. three safe pairs then a real one: still a defer --------------
reset
claimf BH-A catalog/lanes.json cron/a.cron cron/b.cron bin/x.sh
mkbuild BH-B catalog/lanes.json cron/a.cron cron/b.cron bin/x.sh
po BH-B
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-B vs BH-A files=[bin/x.sh,bin/x.sh]" ] && ok \
  || bad "case 4: the 4th (real) pair must defer, rc=$RC out=$OUT"

# ---------- 5. check holds while the claim is live --------------------------
reset
marker BH-B BH-A "$(now)"; claimf BH-A bin/x.sh; openpr BH-A 1
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A in flight" ] && ok || bad "case 5: claim must hold, rc=$RC out=$OUT"
[ -f "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 5: a hold must keep the marker"
# 5b. a live build dir, no claim, holds; one with a RESULT does not
reset
marker BH-B BH-A "$(now)"; openpr BH-A 1; mkbuild BH-A bin/x.sh
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A in flight" ] && ok || bad "case 5b: live build dir must hold, rc=$RC out=$OUT"
echo BUILT > "$(bdir BH-A)/RESULT"
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 5b: a finished build dir must not hold, rc=$RC out=$OUT"
# 5c. a build dir of a DIFFERENT key that shares the prefix does not hold
reset
marker BH-B BH-A "$(now)"; openpr BH-A 1; mkbuild BH-A-1 bin/x.sh
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 5c: proj-BH-A-1-* is not BH-A's build, rc=$RC out=$OUT"

# ---------- 6. open PR holds ------------------------------------------------
reset
marker BH-B BH-A "$(now)"; openpr BH-A "0 #42"
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A PR #42 open" ] && ok || bad "case 6: open PR must hold, rc=$RC out=$OUT"

# ---------- 7. finished and no open PR -> released --------------------------
reset
marker BH-B BH-A "$(now)"; openpr BH-A 1
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 7: must release, rc=$RC out=$OUT"
[ ! -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 7: release must remove the marker"
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=released after=BH-A' && ok || bad "case 7: no released line: $(hlog)"

# ---------- 8. expiry --------------------------------------------------------
reset
marker BH-B BH-A "$(( $(now) - 120 ))"; claimf BH-A bin/x.sh
OUT=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=1 bash "$H/bin/plan-after.sh" check proj BH-B 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "case 8: an expired marker must not hold, rc=$RC out=$OUT"
[ ! -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 8: expiry must remove the marker"
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=expired after=BH-A' && ok || bad "case 8: no expired line: $(hlog)"
# 8a. the same ceiling from env/global.env
marker BH-B BH-A "$(( $(now) - 120 ))"
printf 'PLAN_AFTER_MAX_MIN=1\n' > "$H/env/global.env"
pa check proj BH-B
[ "$RC" = 0 ] && [ ! -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 8a: env/global.env ceiling must be read, rc=$RC out=$OUT"
rm -f "$H/env/global.env"
# 8b. 0 = never expire
marker BH-B BH-A 1
OUT=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=0 bash "$H/bin/plan-after.sh" check proj BH-B 2>/dev/null); RC=$?
[ "$RC" = 3 ] && ok || bad "case 8b: PLAN_AFTER_MAX_MIN=0 must never expire, rc=$RC out=$OUT"
# 8c. a malformed marker is absent, never a hold
reset; mkdir -p "$H/state/overlap-after/proj"; echo garbage > "$H/state/overlap-after/proj/BH-B"
claimf garbage bin/x.sh
pa check proj BH-B
[ "$RC" = 0 ] && [ ! -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 8c: malformed marker, rc=$RC out=$OUT"

# ---------- 9. fleet: job_claims through the REAL file-claims lib -----------
reset
FLEET="$T/fleet.json"
printf '%s\n' '{"claims":[{"ticket_id":"BH-A","files_claimed_at":"2026-10-07T00:00:00Z","planned_files":"bin/x.sh"}]}' > "$FLEET"
cat > "$H/bin/jobs-client.sh" <<SH
_jobs_req() { [ "\$1" = GET ] || return 1; case "\$2" in /api/file-claims\?project=proj) cat "$FLEET" ;; *) return 1 ;; esac; }
SH
mkbuild BH-B bin/x.sh; openpr BH-A 1
po BH-B
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-B vs BH-A files=[bin/x.sh,bin/x.sh]" ] && ok \
  || bad "case 9: a fleet claim must defer BH-B, rc=$RC out=$OUT err=$ERR"
pa record proj BH-B "$OUT"
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A in flight" ] && ok || bad "case 9: fleet-listed key must hold, rc=$RC out=$OUT"
printf '%s\n' '{"claims":[]}' > "$FLEET"
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 9: an empty fleet answer + no PR must release, rc=$RC out=$OUT"

# ---------- 10. mutual: the smaller key is released, the larger holds -------
reset
marker BH-A BH-B "$(now)"; marker BH-B BH-A "$(now)"; openpr BH-A 1; openpr BH-B 1
pa check proj BH-B
[ "$RC" = 3 ] && ok || bad "case 10: the larger key must hold, rc=$RC out=$OUT"
pa check proj BH-A
[ "$RC" = 0 ] && [ ! -e "$H/state/overlap-after/proj/BH-A" ] && ok || bad "case 10: the smaller key must release, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_HOTSPOT BH-A choice=released after=BH-B mutual' && ok || bad "case 10: no mutual line: $(hlog)"

# ---------- 11. unreadable PR answer fails open, marker kept ----------------
reset
marker BH-B BH-A "$(now)"; openpr BH-A 2
pa check proj BH-B
[ "$RC" = 0 ] && [ -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 11: rc 2 must fail open and keep the marker, rc=$RC"
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=unjudged after=BH-A' && ok || bad "case 11: no unjudged line: $(hlog)"
# 11b. no open-PR stub file at all = the same unreadable answer
rm -f "$H/open-pr.BH-A"; pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 11b: no answer must fail open, rc=$RC"

# ---------- 12. a hostile key is refused ------------------------------------
reset
pa record proj BH-B "OVERLAP_DEFER BH-B vs ../evil files=[x,x]"
[ "$RC" = 1 ] && ok || bad "case 12: ../evil must be refused, rc=$RC"
[ -z "$(ls -A "$H/state/overlap-after/proj" 2>/dev/null)" ] && [ ! -e "$H/state/overlap-after/evil" ] && ok \
  || bad "case 12: something was written: $(find "$H/state" -type f)"
pa record proj ../BH-B "OVERLAP_DEFER ../BH-B vs BH-A files=[x,x]"
[ "$RC" = 1 ] && ok || bad "case 12: a hostile own key must be refused, rc=$RC"
pa record proj BH-B "OVERLAP_DEFER BH-B vs .. files=[x,x]"
[ "$RC" = 1 ] && ok || bad "case 12: .. must be refused, rc=$RC"

# ---------- 13. production entry: the gates.sh blocks ------------------------
blk() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$DIR/bin/lib/rb/gates.sh"; }
for b in "overlap not-before" "plan overlap"; do
  [ "$(blk "$b" | wc -l)" -gt 5 ] && ok || bad "case 13: gates.sh block '$b' not found"
done
{ echo 'set -uo pipefail'
  echo 'STAMP() { date -u +%FT%TZ; }'
  echo 'RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT.gate"; }'
  blk "overlap not-before"; blk "plan overlap"
  echo 'echo FELL_THROUGH'; } > "$T/gate-run.sh"
gate() { # gate — run the two blocks for BH-B; sets RC OUT RES
  rm -f "$(bdir BH-B)/RESULT.gate"
  OUT=$(HARNESS="$H" PROJECT=proj KEY=BH-B BUILD="$(bdir BH-B)" REPO="$R" bash "$T/gate-run.sh" 2>/dev/null); RC=$?
  RES=$(cat "$(bdir BH-B)/RESULT.gate" 2>/dev/null)
}
reset
claimf BH-A bin/x.sh; mkbuild BH-B bin/x.sh; openpr BH-A 1
gate
[ "$RC" = 3 ] && ok || bad "case 13: first run must defer (exit 3), rc=$RC out=$OUT"
case "$RES" in "BUILD_DEFERRED OVERLAP_DEFER BH-B vs BH-A"*"After: BH-A"*) ok ;;
  *) bad "case 13: first RESULT must carry After: BH-A: $RES" ;; esac
case "$RES" in *Blocked-by*) bad "case 13: RESULT says Blocked-by" ;; *) ok ;; esac
[ "$(cut -f1 "$H/state/overlap-after/proj/BH-B" 2>/dev/null)" = BH-A ] && ok || bad "case 13: the writer must record the marker"
grep -q 'choice=after after=BH-A' "$(bdir BH-B)/pipeline.log" 2>/dev/null && ok || bad "case 13: pipeline.log lacks the after line"
# the 10-minute floor passes; BH-A is still in flight -> free hold, no plan
echo 1 > "$H/state/overlap-defer/proj/BH-B"
gate
[ "$RC" = 3 ] && ok || bad "case 13: re-run must hold, rc=$RC out=$OUT"
case "$RES" in "BUILD_DEFERRED After: BH-A in flight"*) ok ;; *) bad "case 13: re-run RESULT: $RES" ;; esac
# BH-A finished, no PR -> released, plan-overlap re-judges and proceeds
rm -f "$H/state/claims/proj/BH-A"
gate
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && ok || bad "case 13: released run must proceed, rc=$RC out=$OUT res=$RES"

# ---------- 14. kill switches: no read, no write ----------------------------
reset
OUT=$(HARNESS="$H" OVERLAP_SCHED=0 bash "$H/bin/plan-after.sh" record proj BH-B "OVERLAP_DEFER BH-B vs BH-A files=[x,x]" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$H/state/overlap-after" ] && [ -z "$(hlog)" ] && ok || bad "case 14: OVERLAP_SCHED=0 record wrote, rc=$RC"
marker BH-B BH-A "$(( $(now) - 99999 ))"; claimf BH-A bin/x.sh
OUT=$(HARNESS="$H" OVERLAP_SCHED=0 bash "$H/bin/plan-after.sh" check proj BH-B 2>&1); RC=$?
[ "$RC" = 0 ] && [ -e "$H/state/overlap-after/proj/BH-B" ] && [ -z "$(hlog)" ] && ok || bad "case 14: OVERLAP_SCHED=0 check acted, rc=$RC"
touch "$H/flags/plan-overlap-off"
pa check proj BH-B
[ "$RC" = 0 ] && [ -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 14: flags/plan-overlap-off check acted, rc=$RC"

# ---------- 15. no marker file: the hold is read back from the fleet --------
# A pool machine is a fresh rootfs on every re-offer, so the marker file is
# never there. The REAL job_artifact_feed (bin/lib/jobs/jobs.sh) parses a stub
# /api/artifacts answer; a stub /api/file-claims answers the job_claims read.
FLEET="$T/fleet.json"; ARTS="$T/arts.json"
fleet_client() { # the jobs-client stub shared by cases 15 and 16
  cat > "$H/bin/jobs-client.sh" <<SH
. "$DIR/bin/lib/jobs/jobs.sh"
JOBS_BOX=box
_jobs_req() {
  case "\$1 \$2" in
    "GET /api/file-claims?project=proj") cat "$FLEET" ;;
    "GET /api/artifacts?"*) printf '%s\n' "\$2" >> "$T/feed-asks"; [ -e "$T/feed-down" ] && return 1; cat "$ARTS" ;;
    "PUT /api/jobs/"*/artifacts)
      printf '%s' "\$3" | jq -c --arg t "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{artifacts:[{job_id:"j1",artifact_kind:.artifact_kind,artifact_ref:.artifact_ref,box:"m1",ticket_id:"BH-B",updated_at:\$t,detail:.detail}]}' > "$ARTS" ;;
    *) return 1 ;;
  esac
}
SH
}
art() { # art <ticket> <ref> <updated_at> <detail-json> ... — newest first, as the worker orders them
  local rows="" t r u d
  while [ $# -ge 4 ]; do
    t=$1 r=$2 u=$3 d=$4; shift 4
    rows="$rows${rows:+,}$(jq -nc --arg t "$t" --arg r "$r" --arg u "$u" --arg d "$d" \
      '{job_id:("j-"+$t),artifact_kind:"overlap_defer",artifact_ref:$r,box:"m9",ticket_id:$t,updated_at:$u,detail:$d}')"
  done
  printf '{"artifacts":[%s]}\n' "$rows" > "$ARTS"
}
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
AFTER_A='{"scope":"fleet","conflict":"OVERLAP_DEFER BH-B vs BH-A files=[bin/x.sh,bin/x.sh]","not_before_s":600,"choice":"after","after":"BH-A"}'
claims_a() { printf '%s\n' '{"claims":[{"ticket_id":"BH-A","files_claimed_at":"2026-10-07T00:00:00Z","planned_files":"bin/x.sh"}]}' > "$FLEET"; }
claims_none() { printf '%s\n' '{"claims":[]}' > "$FLEET"; }

# 15a. fleet row names BH-A, BH-A still claims in the fleet -> hold, no file written
reset; rm -f "$T/feed-asks" "$T/feed-down"; fleet_client; claims_a; openpr BH-A 1
art BH-B deferred "$(iso "$(now)")" "$AFTER_A"
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A in flight" ] && ok || bad "case 15a: fleet After: row must hold, rc=$RC out=$OUT err=$ERR"
[ ! -e "$H/state/overlap-after/proj/BH-B" ] && ok || bad "case 15a: a fleet read must not write a marker"
grep -q "kind=overlap_defer&project=proj&limit=500&since=" "$T/feed-asks" 2>/dev/null && ok \
  || bad "case 15a: the feed must be asked for overlap_defer within the ceiling window: $(cat "$T/feed-asks" 2>&1)"
# 15b. PR open -> hold
claims_none; openpr BH-A "0 #42"
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A PR #42 open" ] && ok || bad "case 15b: fleet hold + open PR, rc=$RC out=$OUT"
# 15c. finished, no PR -> released, logged src=fleet
openpr BH-A 1
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 15c: must release, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=released after=BH-A (finished, no open PR) src=fleet' && ok \
  || bad "case 15c: no src=fleet released line: $(hlog)"
# 15d. a NEWER row for the key that is not an After: hold ends it
reset; fleet_client; claims_a; openpr BH-A 1
art BH-B proceeded "$(iso "$(now)")" '{"scope":"fleet"}' BH-B deferred "$(iso "$(( $(now) - 60 ))")" "$AFTER_A"
pa check proj BH-B
[ "$RC" = 0 ] && [ -z "$(hlog)" ] && ok || bad "case 15d: a newer proceeded row must end the hold, rc=$RC out=$OUT log=$(hlog)"
art BH-B deferred "$(iso "$(now)")" '{"scope":"fleet","not_before_s":600,"choice":"defer","after":"BH-A"}'
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 15d: a choice=defer row is not an After: hold, rc=$RC out=$OUT"
# 15e. another key's row is not this key's hold
art BH-C deferred "$(iso "$(now)")" "$AFTER_A"
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 15e: BH-C's row must not hold BH-B, rc=$RC out=$OUT"
# 15f. a fleet row past the ceiling expires
art BH-B deferred "$(iso "$(( $(now) - 7200 ))")" "$AFTER_A"
OUT=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=60 bash "$H/bin/plan-after.sh" check proj BH-B 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "case 15f: an expired fleet row must not hold, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_HOTSPOT BH-B choice=expired after=BH-A .* src=fleet' && ok || bad "case 15f: no expired src=fleet line: $(hlog)"
# 15g. ledger down -> no hold (the not-before floor is what remains)
reset; fleet_client; claims_a; : > "$T/feed-down"
art BH-B deferred "$(iso "$(now)")" "$AFTER_A"
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 15g: a feed outage is not a hold, rc=$RC out=$OUT"
rm -f "$T/feed-down"
# 15h. mutual in the fleet: the smaller key is released; the larger is NOT held
# on OTHER's row (it outlives OTHER's release) but on OTHER's own build
reset; fleet_client; claims_none; openpr BH-A 1; openpr BH-B 1
art BH-A deferred "$(iso "$(now)")" '{"choice":"after","after":"BH-B"}' BH-B deferred "$(iso "$(now)")" "$AFTER_A"
pa check proj BH-A
[ "$RC" = 0 ] && ok || bad "case 15h: the smaller key must release, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_HOTSPOT BH-A choice=released after=BH-B mutual src=fleet' && ok || bad "case 15h: no fleet mutual line: $(hlog)"
pa check proj BH-B
[ "$RC" = 0 ] && ok || bad "case 15h: the larger key with OTHER not building must not stay held on a fleet row, rc=$RC out=$OUT"
claims_a
pa check proj BH-B
[ "$RC" = 3 ] && [ "$OUT" = "AFTER BH-A in flight" ] && ok || bad "case 15h: the larger key must hold while OTHER builds, rc=$RC out=$OUT"

# ---------- 16. production entry across machines -----------------------------
# The writer block defers BH-B on machine 1 and writes its overlap_defer
# artifact. Machine 2 has no state at all (no marker, no claim file, no
# not-before file): the reader block must still hold BH-B for free.
reset; rm -f "$ARTS"; fleet_client; claims_a; openpr BH-A 1; mkbuild BH-B bin/x.sh
gate16() {
  rm -f "$(bdir BH-B)/RESULT.gate"
  OUT=$(HARNESS="$H" PROJECT=proj KEY=BH-B BUILD="$(bdir BH-B)" REPO="$R" JOB_ID=j1 bash "$T/gate-run.sh" 2>/dev/null); RC=$?
  RES=$(cat "$(bdir BH-B)/RESULT.gate" 2>/dev/null)
}
gate16
[ "$RC" = 3 ] && ok || bad "case 16: machine 1 must defer, rc=$RC out=$OUT res=$RES"
[ "$(jq -r '.artifacts[0].detail | fromjson | .choice + " " + .after' "$ARTS" 2>/dev/null)" = "after BH-A" ] && ok \
  || bad "case 16: the overlap_defer artifact must carry choice=after after=BH-A: $(cat "$ARTS" 2>&1)"
# machine 2: a fresh rootfs
scratch_rm "$H/state"; scratch_rm "$H/builds"; mkdir -p "$H/state/claims/proj" "$H/builds"; mkbuild BH-B bin/x.sh
gate16
[ "$RC" = 3 ] && ok || bad "case 16: machine 2 must hold with no local state, rc=$RC out=$OUT res=$RES"
case "$RES" in "BUILD_DEFERRED After: BH-A in flight"*) ok ;; *) bad "case 16: machine 2 RESULT: $RES" ;; esac
# BH-A finishes and has no PR: machine 2 goes on to PLAN
claims_none
gate16
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && ok || bad "case 16: released run must proceed, rc=$RC out=$OUT res=$RES"

[ ! -e "$T/gh-called" ] && ok || bad "gh was called: $(cat "$T/gh-called")"

echo "plan-hotspot-overlap.bh-4988: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
