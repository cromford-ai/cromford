#!/bin/bash
# tests/disk-headroom.bh-9435-test.sh — BH-9435 (C3): the disk headroom step
# before a build (bin/lib/disk-headroom.sh, bin/lib/rb/gates.d/disk-headroom.sh).
#
# What is proved here (a stub df reads the free MB, 0 network):
#   H1 the real gates.d fragment writes exactly one
#      `disk: <MB> MB free on / at build start (<host>, builder_exec=<0|1>)` line;
#   H2 free over the knob: 0 removed, no delete, no audit line;
#   H3 free under the knob, dry run on (the default): 1 audit line, every
#      candidate still on disk;
#   H4 dry run off: the oldest settled archive dir is trimmed first (its work/
#      subdir goes, the dir, RESULT, job.json and plan.md stay, HEADROOM_TRIMMED
#      is written), and trims stop when free >= the knob (the stub df counts the
#      watched paths that are gone);
#   H5 a dir whose build-key lock is held stays on disk;
#   H6 the running $BUILD stays on disk, even when it is the oldest;
#   H7 a builds/ dir with no RESULT stays; RESULT without COMMENTED, RELAYED or
#      DEFERRED stays; a dir younger than KEEP_DAYS stays;
#   H8 a symlink, index.tsv, state/remote-results/ and a bad name stay; a name
#      with a space is handled;
#   H9 a df that fails: no deletion, one log line, rc 0 (the build goes on);
#   H10 the archive readers still answer after a trim (refute review): ba_has_key,
#      ba_dirs, ba_path and ba_merged_other give the same answer before and after
#      a non-dry-run dh_run, and index.tsv is unchanged;
#   H11 a trimmed dir is not trimmed again, and a dir with only top-level files
#      (no bulk) is kept (kept=trimmed:1, no-bulk:1).
# Run from anywhere: tests/disk-headroom.bh-9435-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/disk-headroom.sh"
FRAG="$DIR/bin/lib/rb/gates.d/disk-headroom.sh"

mkdir -p "$T/fakebin"
printf '#!/bin/bash\necho fixture-host\n' > "$T/fakebin/hostname"
# The stub df: free = DF_BASE + DF_STEP x (the dirs in DF_WATCH that are gone).
# DF_FAIL=1 makes it fail. It prints the -P shape: a header, then one row.
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
[ "${DF_FAIL:-0}" = 1 ] && { echo "df: cannot read" >&2; exit 1; }
gone=0
if [ -n "${DF_WATCH:-}" ] && [ -r "$DF_WATCH" ]; then
  while IFS= read -r d; do [ -n "$d" ] && [ ! -e "$d" ] && gone=$((gone + 1)); done < "$DF_WATCH"
fi
f=$(( ${DF_BASE:-4000} + ${DF_STEP:-0} * gone ))
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "none 100000 1000 $f 10% /"
SH
chmod +x "$T/fakebin/hostname" "$T/fakebin/df"

N=0
# newh — a fresh harness root under $T, with a unique name. Sets H.
newh() { N=$((N + 1)); H="$T/h$N-$$"; mkdir -p "$H/builds" "$H/builds-archive/202610" "$H/locks" "$H/logs" "$H/state/remote-results/p"; }
# mkb <path> <age-days> [marker...] — a build dir with RESULT, job.json, plan.md,
# the markers, and the bulk in a work/ subdir, aged.
mkb() {
  local d="$1" age="$2"; shift 2
  mkdir -p "$d/work/node_modules"; echo "PR_OPENED https://x/pr/1" > "$d/RESULT"
  echo '{"ticket_id":"42"}' > "$d/job.json"; echo "# plan" > "$d/plan.md"
  head -c 2048 /dev/zero > "$d/work/node_modules/blob"
  local m; for m in "$@"; do case "$m" in noresult) rm -f "$d/RESULT" ;; *) : > "$d/$m" ;; esac; done
  find "$d" -exec touch -d "-$age days" {} +
}
# run <env...> — dh_run in a clean shell, PATH with the stubs, default knobs.
run() {
  env -i PATH="$T/fakebin:$PATH" HOME="$T" "$@" bash -c '
    . "$1" || exit 99
    dh_run "$2" "$3"' _ "$LIB" "$H" "${OWN:-$H/builds/own-BH-1-202611100000}"
}
audit_n() { [ -f "$H/logs/disk-headroom.log" ] && wc -l < "$H/logs/disk-headroom.log" | tr -d ' ' || echo 0; }

# ══ H1: the real fragment, driven as the build sources it ═══════════════════
newh
scratch_install_closure bin/lib/disk-headroom.sh "$H" > /dev/null || bad "H1 cannot install bin/lib/disk-headroom.sh into the scratch harness"
B1="$H/builds/fixture-proj-BH-1-202611100000"; mkdir -p "$B1"
for be in 0 1; do
  : > "$B1/pipeline.log"
  env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$H" BUILD="$B1" PROJECT=fixture-proj KEY=BH-1 BUILDER_EXEC="$be" \
    DF_BASE=4000 DISK_HEADROOM_MIN_FREE_MB=1000 bash -c '
      STAMP() { echo 2026-11-11T00:00:00Z; }
      gate() { . "$1"; echo "after-fragment"; }
      gate "$1"' _ "$FRAG" > "$T/h1.out" 2>&1
  n=$(grep -c "disk: 4000 MB free on / at build start (fixture-host, builder_exec=$be)" "$B1/pipeline.log")
  [ "$n" = 1 ] && ok || bad "H1 builder_exec=$be: want 1 measure line in pipeline.log, got $n: $(cat "$B1/pipeline.log")"
  grep -qx after-fragment "$T/h1.out" && ok || bad "H1 builder_exec=$be: the fragment must not stop the build: $(cat "$T/h1.out")"
done

# ══ H2: free over the knob ══════════════════════════════════════════════════
newh
A1="$H/builds-archive/202610/p-BH-2-202610010000"; mkb "$A1" 40
run DF_BASE=9000 DISK_HEADROOM_MIN_FREE_MB=8192 DISK_HEADROOM_DRY_RUN=0 > "$T/h2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "H2 rc must be 0, got $rc"
[ -d "$A1/work" ] && ok || bad "H2 free 9000 >= 8192: nothing may be trimmed"
[ "$(audit_n)" = 0 ] && ok || bad "H2 no audit line when free is over the knob (got $(audit_n))"
grep -q 'headroom ok' "$T/h2.out" && ok || bad "H2 want a 'headroom ok' line: $(cat "$T/h2.out")"

# ══ H3: under the knob, dry run on (the default) ════════════════════════════
newh
A1="$H/builds-archive/202610/p-BH-3-202610010000"; mkb "$A1" 40
A2="$H/builds-archive/202610/p-BH-4-202610020000"; mkb "$A2" 39
P1="$H/builds/p-BH-5-202610030000"; mkb "$P1" 5 COMMENTED
run DF_BASE=1000 BUILDER_EXEC=1 > "$T/h3.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "H3 rc must be 0, got $rc"
[ -d "$A1/work" ] && [ -d "$A2/work" ] && [ -d "$P1/work" ] && ok || bad "H3 the default dry run must delete nothing"
[ ! -e "$A1/HEADROOM_TRIMMED" ] && ok || bad "H3 the dry run must write no HEADROOM_TRIMMED"
[ "$(audit_n)" = 1 ] && ok || bad "H3 want exactly 1 audit line, got $(audit_n)"
L=$(cat "$H/logs/disk-headroom.log" 2>/dev/null)
[[ "$L" == *" fixture-host dry_run=1 "*"before=1000 after=1000 removed=0 "* ]] && ok || bad "H3 audit line shape: $L"
[[ "$L" == *p-BH-3-202610010000* && "$L" == *p-BH-5-202610030000* ]] && ok || bad "H3 the dry run must list the candidates: $L"

# ══ H4: dry run off, oldest first, stop at the knob ═════════════════════════
newh
A1="$H/builds-archive/202610/p-BH-6-202610010000"; mkb "$A1" 40
A2="$H/builds-archive/202610/p-BH-7-202610020000"; mkb "$A2" 30
A3="$H/builds-archive/202610/p-BH-8-202610030000"; mkb "$A3" 20
printf '%s\n' "$A1/work" "$A2/work" "$A3/work" > "$T/watch4"
run DF_BASE=1000 DF_STEP=4000 DF_WATCH="$T/watch4" DISK_HEADROOM_MIN_FREE_MB=8192 DISK_HEADROOM_DRY_RUN=0 > "$T/h4.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "H4 rc must be 0, got $rc"
[ ! -e "$A1/work" ] && [ ! -e "$A2/work" ] && ok || bad "H4 the 2 oldest must be trimmed (1000+4000+4000 >= 8192)"
for x in "$A1" "$A2"; do
  [ -d "$x" ] && [ -f "$x/RESULT" ] && [ -f "$x/job.json" ] && [ -f "$x/plan.md" ] \
    && ok || bad "H4 a trimmed dir must keep itself and its top-level files: $(ls -A "$x" 2>&1)"
  grep -Eq '^[0-9T:-]+Z [0-9]+$' "$x/HEADROOM_TRIMMED" 2>/dev/null && ok || bad "H4 a trimmed dir must carry HEADROOM_TRIMMED '<stamp> <MB>'"
done
[ -d "$A3/work" ] && [ ! -e "$A3/HEADROOM_TRIMMED" ] && ok || bad "H4 trims must stop when free >= the knob: the newest must stay whole"
[ "$(audit_n)" = 1 ] && ok || bad "H4 want exactly 1 audit line, got $(audit_n)"
L=$(cat "$H/logs/disk-headroom.log" 2>/dev/null)
[[ "$L" == *"dry_run=0 "*"before=1000 after=9000 removed=2 dirs=p-BH-6-202610010000"* ]] && ok || bad "H4 audit line: $L"
n=$(grep -c 'trimming ' "$T/h4.out"); [ "$n" = 2 ] && ok || bad "H4 want 2 'trimming' lines before the trims, got $n"

# ══ H5: a held build-key lock ═══════════════════════════════════════════════
newh
A1="$H/builds-archive/202610/p-BH-9-202610010000"; mkb "$A1" 40
A2="$H/builds-archive/202610/p-BH-10-202610020000"; mkb "$A2" 30
: > "$H/locks/build-key-p-BH-9.lock"
exec 8<"$H/locks/build-key-p-BH-9.lock"; flock -n 8 || bad "H5 the test could not take the lock"
printf '%s\n' "$A1/work" "$A2/work" > "$T/watch5"
run DF_BASE=1000 DF_STEP=9000 DF_WATCH="$T/watch5" DISK_HEADROOM_DRY_RUN=0 > "$T/h5.out" 2>&1
exec 8<&-
[ -d "$A1/work" ] && ok || bad "H5 a dir whose build-key lock is held must stay whole"
[ ! -e "$A2/work" ] && [ -f "$A2/RESULT" ] && ok || bad "H5 the next candidate must be trimmed"
grep -q 'kept=.*live:1' "$H/logs/disk-headroom.log" && ok || bad "H5 the audit line must count live:1: $(cat "$H/logs/disk-headroom.log")"

# ══ H6: the running build's own dir ═════════════════════════════════════════
newh
OWN="$H/builds/p-BH-11-202610010000"; mkb "$OWN" 40 COMMENTED
P2="$H/builds/p-BH-12-202610020000"; mkb "$P2" 30 COMMENTED
printf '%s\n' "$OWN/work" "$P2/work" > "$T/watch6"
OWN="$OWN" run DF_BASE=1000 DF_STEP=9000 DF_WATCH="$T/watch6" BUILDER_EXEC=1 DISK_HEADROOM_DRY_RUN=0 > "$T/h6.out" 2>&1
[ -d "$H/builds/p-BH-11-202610010000/work" ] && ok || bad "H6 the running \$BUILD must stay whole, even when oldest"
[ ! -e "$P2/work" ] && [ -f "$P2/RESULT" ] && [ -f "$P2/COMMENTED" ] && ok || bad "H6 the next settled pool dir must be trimmed"
grep -q 'kept=.*own:1' "$H/logs/disk-headroom.log" && ok || bad "H6 the audit line must count own:1: $(cat "$H/logs/disk-headroom.log")"
OWN=""

# ══ H7: builds/ dirs that are not settled ═══════════════════════════════════
newh
N1="$H/builds/p-BH-13-202610010000"; mkb "$N1" 40 noresult COMMENTED
N2="$H/builds/p-BH-14-202610010000"; mkb "$N2" 40
echo "BUILD_DEFERRED disk" > "$N2/RESULT"; touch -d '-40 days' "$N2/RESULT" "$N2"
N3="$H/builds/p-BH-15-202611100000"; mkb "$N3" 0 COMMENTED
OK1="$H/builds/p-BH-16-202610010000"; mkb "$OK1" 40 RELAYED
OK2="$H/builds/p-BH-17-202610010000"; mkb "$OK2" 39 DEFERRED
printf '%s\n' "$N1/work" "$N2/work" "$N3/work" > "$T/watch7"
run DF_BASE=1000 BUILDER_EXEC=1 DISK_HEADROOM_DRY_RUN=0 DISK_HEADROOM_KEEP_DAYS=1 > "$T/h7.out" 2>&1
[ -d "$N1/work" ] && ok || bad "H7 a builds/ dir with no RESULT must stay whole"
[ -d "$N2/work" ] && ok || bad "H7 RESULT BUILD_DEFERRED with no COMMENTED/RELAYED/DEFERRED must stay whole"
[ -d "$N3/work" ] && ok || bad "H7 a dir younger than KEEP_DAYS must stay whole"
[ ! -e "$OK1/work" ] && [ ! -e "$OK2/work" ] && [ -f "$OK1/RELAYED" ] && [ -f "$OK2/DEFERRED" ] && ok || bad "H7 settled pool dirs (RELAYED, DEFERRED) past KEEP_DAYS must be trimmed"
[ "$(audit_n)" = 1 ] && ok || bad "H7 want exactly 1 audit line, got $(audit_n)"
# Not a pool machine: builds/ is never a candidate, archive only.
newh
P1="$H/builds/p-BH-18-202610010000"; mkb "$P1" 40 COMMENTED
run DF_BASE=1000 BUILDER_EXEC=0 DISK_HEADROOM_DRY_RUN=0 > "$T/h7b.out" 2>&1
[ -d "$P1/work" ] && ok || bad "H7 on a board box (BUILDER_EXEC!=1) builds/ is never a candidate"

# ══ H8: adversarial negatives ═══════════════════════════════════════════════
newh
mkdir -p "$T/outside-$N"; mkb "$T/outside-$N/p-BH-19-202610010000" 50
ln -s "$T/outside-$N/p-BH-19-202610010000" "$H/builds-archive/202610/p-BH-19-202610010000"
ln -s "$T/outside-$N/p-BH-19-202610010000" "$H/builds/p-BH-20-202610010000"
printf '#archived_at\tdir\n' > "$H/builds-archive/index.tsv"; touch -d '-60 days' "$H/builds-archive/index.tsv"
mkb "$H/state/remote-results/p/old" 60 COMMENTED
BADN="$H/builds-archive/202610/hand-made-dir"; mkb "$BADN" 60
SP="$H/builds-archive/202610/p-BH-21-a b-202610010000"; mkb "$SP" 45
run DF_BASE=1000 BUILDER_EXEC=1 DISK_HEADROOM_DRY_RUN=0 > "$T/h8.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "H8 rc must be 0, got $rc"
[ -d "$T/outside-$N/p-BH-19-202610010000" ] && [ -L "$H/builds-archive/202610/p-BH-19-202610010000" ] && [ -L "$H/builds/p-BH-20-202610010000" ] \
  && ok || bad "H8 a symlink (and its target outside builds/) must stay"
[ -f "$H/builds-archive/index.tsv" ] && ok || bad "H8 builds-archive/index.tsv must stay"
[ -d "$H/state/remote-results/p/old" ] && ok || bad "H8 state/remote-results/ must stay"
[ -d "$BADN/work" ] && ok || bad "H8 a name ba_parse rejects must stay whole"
[ ! -e "$SP/work" ] && [ -f "$SP/RESULT" ] && ok || bad "H8 a settled archive dir whose name has a space must be handled (trimmed)"
grep -q 'p-BH-21-a%20b-202610010000' "$H/logs/disk-headroom.log" && ok || bad "H8 a space in a name is written %20 in the audit line: $(cat "$H/logs/disk-headroom.log")"

# ══ H9: df fails ════════════════════════════════════════════════════════════
newh
A1="$H/builds-archive/202610/p-BH-22-202610010000"; mkb "$A1" 40
run DF_FAIL=1 DISK_HEADROOM_DRY_RUN=0 > "$T/h9.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "H9 a df failure must not fail the build (rc $rc)"
[ -d "$A1/work" ] && ok || bad "H9 a df failure must delete nothing"
n=$(grep -c 'free disk unreadable' "$T/h9.out"); [ "$n" = 1 ] && ok || bad "H9 want 1 'free disk unreadable' line, got $n: $(cat "$T/h9.out")"

# ══ H10: the archive readers still answer after a trim (refute review) ══════
newh
A1="$H/builds-archive/202610/p-BH-23-202610010000"; mkb "$A1" 40
echo "PR_MERGED https://x/pr/23" > "$A1/RESULT"; touch -d '-40 days' "$A1/RESULT" "$A1"
ln -s "$T/outside-h10-$N" "$A1/link-out"; mkdir -p "$T/outside-h10-$N"; : > "$T/outside-h10-$N/keepme"
printf '#archived_at\tdir\trelpath\tproject\tkey\tticket_id\tresult1\n2026-10-02T00:00:00Z\tp-BH-23-202610010000\t202610/p-BH-23-202610010000\tp\tBH-23\t42\tPR_MERGED https://x/pr/23\n' > "$H/builds-archive/index.tsv"
cp "$H/builds-archive/index.tsv" "$T/idx10"
readers() {
  bash -c '. "$1" || exit 99; h="$2"
    ba_has_key "$h" p BH-23 && echo has=yes || echo has=no
    echo "dirs=$(ba_dirs "$h" p BH-23)"
    echo "path=$(ba_path "$h" p-BH-23-202610010000)"
    echo "other=$(ba_merged_other "$h" p 42 bh-99 | cut -f1)"' _ "$DIR/bin/lib/build-archive.sh" "$H"
}
R0=$(readers)
[[ "$R0" == *has=yes* && "$R0" == *other=BH-23* && "$R0" == *"path=$A1"* ]] && ok || bad "H10 fixture: the readers must answer before the run: $R0"
printf '%s\n' "$A1/work" > "$T/watch10"
run DF_BASE=1000 DF_STEP=9000 DF_WATCH="$T/watch10" DISK_HEADROOM_DRY_RUN=0 > "$T/h10.out" 2>&1
[ ! -e "$A1/work" ] && [ ! -e "$A1/link-out" ] && ok || bad "H10 the run must trim the bulk: $(ls -A "$A1" 2>&1)"
[ -f "$T/outside-h10-$N/keepme" ] && ok || bad "H10 a trim removes a symlink as a link, never its target"
R1=$(readers)
[ "$R1" = "$R0" ] && ok || bad "H10 the archive readers must answer the same after a trim: before '$R0' after '$R1'"
cmp -s "$T/idx10" "$H/builds-archive/index.tsv" && ok || bad "H10 index.tsv must be unchanged"

# ══ H11: a trimmed dir is not trimmed again; a dir with no bulk is kept ═════
newh
A1="$H/builds-archive/202610/p-BH-24-202610010000"; mkb "$A1" 40
mkdir -p "$A1/work2"; echo "2026-10-01T00:00:00Z 5" > "$A1/HEADROOM_TRIMMED"
A2="$H/builds-archive/202610/p-BH-25-202610010000"; mkb "$A2" 40; scratch_rm "$A2/work" || bad "H11 fixture: cannot remove $A2/work"
run DF_BASE=1000 DISK_HEADROOM_DRY_RUN=0 > "$T/h11.out" 2>&1
[ -d "$A1/work2" ] && [ -f "$A2/RESULT" ] && ok || bad "H11 a trimmed or bulk-free dir must not be touched"
L=$(cat "$H/logs/disk-headroom.log" 2>/dev/null)
[[ "$L" == *"removed=0 "* && "$L" == *no-bulk:1* && "$L" == *trimmed:1* ]] && ok || bad "H11 audit must say removed=0 kept no-bulk:1,trimmed:1: $L"

# ══ static: the call line sits right above the disk gate ════════════════════
G="$DIR/bin/lib/rb/gates.sh"
nl=$(grep -nx '. "$RB_GATES_D/disk-headroom.sh"' "$G" | cut -d: -f1)
ng=$(grep -nx '. "$RB_GATES_D/disk-gate.sh"' "$G" | cut -d: -f1)
[ -n "$nl" ] && [ -n "$ng" ] && [ $((ng - nl)) -le 2 ] && [ "$nl" -lt "$ng" ] && ok || bad "S1 gates.sh must call disk-headroom.sh just above disk-gate.sh (lines '$nl' '$ng')"
for k in DISK_HEADROOM_MIN_FREE_MB DISK_HEADROOM_KEEP_DAYS DISK_HEADROOM_DRY_RUN; do
  f="$DIR/catalog/lanes.d/disk-guard.knobs.d/$k.json"
  jq -e '.env and (.default|type=="number")' "$f" >/dev/null 2>&1 && ok || bad "S2 knob fragment $f missing or malformed"
done
grep -q 'lane.disk-guard.disk_headroom_min_free_mb' "$LIB" 2>/dev/null && ok || bad "S3 the 8192 fallback comment must name its row"

echo "disk-headroom.bh-9435: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
