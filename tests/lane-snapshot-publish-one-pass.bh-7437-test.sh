#!/bin/bash
# tests/lane-snapshot-publish-one-pass.bh-7437-test.sh — BH-7437 part 1b.
#
# After part 1 (old dirs skipped by name) a publisher run on the hub still did
# not finish in 900 s: every listed file went through lri_member_ok in a bash
# `while read` loop (about 25,000 files for 2,500 young build dirs at load5 100
# on 4 vCPU), and cron runs stacked (7 processes, up to 814 s old). The member
# filter is now ONE awk plus ONE grep pass over the listing, and a run takes
# locks/lane-snapshot-publish.lock.
#
#   P1  parity: 2,000+ listing lines (members, non-members, odd names, other
#       projects, oversize-looking names) through the frozen per-line bash loop
#       and through _lri_member_filter: same lines, ro and rw, two lanes
#   P2  parity end to end: a seeded tree of 2,000+ files (old dirs, young dirs,
#       members, non-members, oversize files): _lri_list and its skip file equal
#       an oracle built from lri_member_ok per path
#   C1  cost: the bulk path calls lri_member_ok no more than 20 times for 2,000+
#       files (it was once per file)
#   L1  lock: a second concurrent run exits 0 with ONE "already running" line,
#       the first run finishes normally, and a run after both works
#   L2  the lock is per lane: a pipeline-health run is not turned away while a
#       blocked-resolver run holds its lock
#   L3  the lock does not silence stderr: a bad --lane still prints its error
#
# Run from anywhere (exit 0 = pass). Needs GNU find, touch, date, awk and flock.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
find /dev/null -maxdepth 0 -printf '' 2>/dev/null || { echo "SKIP: find is not GNU find"; exit 0; }
NOW=$(date -u +%s)
DAY=86400
TAB=$'\t'
ts() { date -u -d "@$1" "+$2"; }

R="$T/r"
mkdir -p "$R/bin/lib" "$R/catalog" "$R/builds" "$R/logs" "$R/state" "$R/locks"
( cd "$DIR" && scratch_install_closure bin/lib/lane-run-inputs.sh "$R" ) >/dev/null \
  || { echo "setup: could not install bin/lib/lane-run-inputs.sh"; exit 1; }
cp -r "$DIR/catalog/lane-run-inputs.d" "$R/catalog/"

# run_lib <code> — runs <code> in a subshell with the lib sourced, the jobs
# client stubbed and lane_snapshot.file_max = 2000 bytes.
run_lib() {
  (
    export HARNESS="$R"
    setting_get() { case "$1" in lane_snapshot.file_max) echo 2000 ;; *) return 1 ;; esac; }
    _jobs_req() { JOBS_HTTP=200; echo '{}'; }
    _jobs_req_file() { JOBS_HTTP=200; echo '{}'; }
    . "$R/bin/lib/lane-run-inputs.sh"
    eval "$1"
  )
}

# ============================================================================
echo "P1: the member filter equals the per-line bash loop"
LISTING="$T/listing.tsv"
{
  for i in $(seq 1 300); do
    e=$((NOW - i * 3600)); st=$(ts "$e" %Y%m%d%H%M)
    d="builds/p1-BH-$i-$st"
    printf 'd\t%s\n' "$d"
    printf -- '-\t%s/RESULT\n-\t%s/job.json\n-\t%s/plan.md\n' "$d" "$d" "$d"
    printf -- '-\t%s/notes.txt\n-\t%s/secret.env\n' "$d" "$d"                 # not record files
    printf 'd\tbuilds/p2-BH-%s-%s\n-\tbuilds/p2-BH-%s-%s/RESULT\n' "$i" "$st" "$i" "$st"  # another project
    printf 'd\tbuilds/pool-p1-BH-%s-%s\n-\tbuilds/pool-p1-BH-%s-%s/review.md\n' "$i" "$st" "$i" "$st"
  done
  # Odd names: every one of these is refused or accepted by the same rule in both.
  printf -- '-\t/builds/p1-BH-1-202610010000/RESULT\n'
  printf -- '-\tbuilds//p1-BH-1-202610010000/RESULT\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/RESULT/\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/../p1-BH-2-202610010000/RESULT\n'
  printf -- '-\tbuilds/./p1-BH-1-202610010000/RESULT\n'
  printf -- '-\t./builds/p1-BH-1-202610010000/RESULT\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/RE SULT\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/RES$ULT\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/RESULT*\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000/RESULT\textra\n'
  printf -- '-\t\n-\n-\t.\n-\t..\n-\t...\n-\t.hidden\n'
  printf -- 'x\tbuilds/p1-BH-1-202610010000/RESULT\n'
  printf -- 'l\tbuilds/p1-BH-1-202610010000/RESULT\n'
  printf -- 'd\tbuilds/p1-BH-1-202610010000/RESULT\n'
  printf -- '-\tbuilds/p1-BH-1-202610010000\n'
  printf -- '-\tfleet.conf\n-\tflags/all-off\n-\tflags/lane-off-x\n-\tstate/build-queue/p1/a.json\n-\tstate/build-queue/p1/a.txt\n'
  printf -- '-\tstate/pool/p1/x.terminal\n-\tplans/p1-BH-1/planned-files.txt\n-\tstate/merge-conductor/pr-state.tsv\n'
  printf -- '-\tlogs/merge-conductor.log\n-\tlogs/other.log\n'
} > "$LISTING"
N=$(wc -l < "$LISTING" | tr -d ' ')
[ "$N" -ge 2000 ] && ok "P1 the listing has $N lines" || bad "P1 the listing has only $N lines"

old_filter() { # <p> <mode> — the frozen pre-BH-7437-1b loop
  local p="$1" mode="$2" d rel
  while IFS=$'\t' read -r d rel; do
    lri_member_ok "$p" "$rel" "$d" "$mode" && printf '%s\t%s\n' "$d" "$rel"
  done | LC_ALL=C sort -t$'\t' -k2,2 -u
}
declare -f old_filter > "$T/old_filter.sh"
for lane in blocked-resolver pipeline-health; do
  for mode in ro rw; do
    run_lib "LRI_LANE=$lane; . $T/old_filter.sh; old_filter p1 $mode < $LISTING" > "$T/old.out" 2>"$T/old.err"
    run_lib "LRI_LANE=$lane; _lri_member_filter p1 $mode < $LISTING | LC_ALL=C sort -t\$'\t' -k2,2 -u" > "$T/new.out" 2>"$T/new.err"
    NOLD=$(wc -l < "$T/old.out" | tr -d ' ')
    # pipeline-health has no rw record paths: an empty answer must match too.
    if cmp -s "$T/old.out" "$T/new.out" && { [ "$NOLD" -gt 100 ] || [ "$lane/$mode" = pipeline-health/rw ]; }; then
      ok "P1 $lane $mode: $NOLD accepted lines identical"
    else
      bad "P1 $lane $mode: old=$NOLD lines, new=$(wc -l < "$T/new.out" | tr -d ' ') ($(head -c 200 "$T/new.err"))"
    fi
  done
done
run_lib "_lri_member_filter p1 xx < $LISTING" > "$T/bad-mode.out" 2>/dev/null
[ ! -s "$T/bad-mode.out" ] && ok "P1 an unknown mode accepts nothing" || bad "P1 an unknown mode accepted lines"
run_lib "_lri_member_filter '../x' ro < $LISTING" > "$T/bad-p.out" 2>/dev/null
[ ! -s "$T/bad-p.out" ] && ok "P1 a path-unsafe project accepts nothing" || bad "P1 a path-unsafe project accepted lines"

# ============================================================================
echo "P2: _lri_list on a seeded tree equals the per-path oracle"
rec() { # <name> <mtime> — a record dir with six files; plan.md of every 7th over the cap
  local d="$R/builds/$1" i="$3"
  mkdir -p "$d"
  printf 'PR_CREATED\n' > "$d/RESULT"; printf '{"key":"x"}\n' > "$d/job.json"
  printf 'plan\n' > "$d/plan.md"; printf 'n\n' > "$d/notes.txt"; printf 'S=1\n' > "$d/secret.env"
  printf 'rev\n' > "$d/review.md"
  [ $((i % 7)) = 0 ] && head -c 5000 /dev/zero | tr '\0' 'x' > "$d/plan.md"
  touch -d "@$2" "$d"/* "$d"
}
for i in $(seq 1 200); do   # old: 40+ days
  e=$((NOW - (39 + i) * DAY - 3600)); rec "p1-BH-$i-$(ts "$e" %Y%m%d%H%M)" "$e" "$i"
done
for i in $(seq 201 330); do # young: 1-19 days
  e=$((NOW - ((i % 19) + 1) * DAY)); rec "p1-BH-$i-$(ts "$e" %Y%m%d%H%M)" "$e" "$i"
done
for i in $(seq 331 360); do # a pool dir and another project's dir
  e=$((NOW - 2 * DAY)); rec "pool-p1-BH-$i-$(ts "$e" %Y%m%d%H%M)" "$e" "$i"
  rec "p2-BH-$i-$(ts "$e" %Y%m%d%H%M)" "$e" "$i"
done
NFILES=$(find "$R/builds" -type f | wc -l | tr -d ' ')
[ "$NFILES" -ge 2000 ] && ok "P2 the tree has $NFILES files" || bad "P2 the tree has only $NFILES files"

oracle() { # <mode> <days> <skipfile> — the old semantics, path by path
  local mode="$1" days="$2" skips="$3" d rel size
  cd "$R" || return 1
  for d in builds/*; do
    [ -d "$d" ] || continue
    lri_member_ok p1 "$d" d "$mode" || continue
    if [ "$days" -gt 0 ] && [ -z "$(find "$d" -maxdepth 0 -mtime "-$days")" ]; then
      printf 'dir\t%s\t%s\n' "$d" "$days" >> "$skips"; continue
    fi
    printf 'd\t%s\n' "$d"
    for rel in "$d"/* "$d"/.[!.]*; do
      [ -f "$rel" ] || continue
      lri_member_ok p1 "$rel" - "$mode" || continue
      size=$(stat -c %s "$rel")
      if [ "$size" -gt 2000 ]; then printf 'file\t%s\t%s\t2000\n' "$rel" "$size" >> "$skips"
      else printf -- '-\t%s\n' "$rel"; fi
    done
  done | LC_ALL=C sort -t$'\t' -k2,2 -u
}
declare -f oracle > "$T/oracle.sh"
for spec in "ro 30" "rw 0"; do
  set -- $spec; mode=$1; days=$2
  : > "$T/skips.got"; : > "$T/skips.want"
  run_lib "_lri_list p1 $mode $days $T/skips.got" | grep -E '^[-d]'"$TAB"'builds/' > "$T/list.got"
  run_lib ". $T/oracle.sh; oracle $mode $days $T/skips.want" > "$T/list.want"
  LC_ALL=C sort -u "$T/skips.got" -o "$T/skips.got"; LC_ALL=C sort -u "$T/skips.want" -o "$T/skips.want"
  NL=$(wc -l < "$T/list.want" | tr -d ' ')
  if cmp -s "$T/list.got" "$T/list.want" && [ "$NL" -gt 100 ]; then ok "P2 $mode days=$days: $NL listed lines identical"
  else bad "P2 $mode days=$days: got $(wc -l < "$T/list.got" | tr -d ' ') lines, oracle $NL"; fi
  if cmp -s "$T/skips.got" "$T/skips.want"; then ok "P2 $mode days=$days: $(wc -l < "$T/skips.want" | tr -d ' ') skip lines identical"
  else bad "P2 $mode days=$days: skip file differs ($(wc -l < "$T/skips.got" | tr -d ' ') vs $(wc -l < "$T/skips.want" | tr -d ' '))"; fi
done
grep -q '^file' "$T/skips.want" 2>/dev/null; GF=$?
{ [ "$GF" = 0 ] || [ "$(grep -c '^file' "$T/skips.got")" -gt 0 ]; } && ok "P2 the seeded oversize files reach the skip file" || bad "P2 no oversize skip line was seeded"

# ============================================================================
echo "C1: the bulk path does not call lri_member_ok once per file"
: > "$T/calls"
run_lib "
  eval \"\$(declare -f lri_member_ok | sed '1s/lri_member_ok/_lri_member_ok_orig/')\"
  lri_member_ok() { echo x >> '$T/calls'; _lri_member_ok_orig \"\$@\"; }
  _lri_list p1 ro 30 $T/skips.c1 >/dev/null
" 2>/dev/null
CALLS=$(wc -l < "$T/calls" | tr -d ' ')
[ "$CALLS" -le 20 ] && ok "C1 $CALLS lri_member_ok calls for $NFILES files" || bad "C1 $CALLS lri_member_ok calls for $NFILES files (once per file)"

# ============================================================================
echo "L1: a second concurrent run exits 0 with one 'already running' line"
P="$T/p"; mkdir -p "$P/bin/lib" "$P/logs"
cp "$DIR/bin/lane-snapshot-publish.sh" "$P/bin/"
cat > "$P/bin/jobs-client.sh" <<'EOF'
# shellcheck shell=bash
setting_get() { return 1; }
EOF
cat > "$P/bin/lib/project-lanes.sh" <<'EOF'
# shellcheck shell=bash
pl_name_ok() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
EOF
cat > "$P/bin/lib/lane-placement.sh" <<'EOF'
# shellcheck shell=bash
lp_decide() { LP_PLACE=hub; LP_WHY="fixture"; }
EOF
cat > "$P/bin/lib/lane-run-inputs.sh" <<'EOF'
# shellcheck shell=bash
lri_apply_pending() { [ -z "${STARTED:-}" ] || : > "$STARTED"; sleep "${APPLY_SLEEP:-0}"; echo "applied=0 conflicts=0 rejected=0"; }
EOF
cat > "$P/bin/lib/alert-line-remote.sh" <<'EOF'
# shellcheck shell=bash
alr_apply() { echo "alert lines: 0 replayed, 0 already applied, ack none"; }
EOF
printf '#!/bin/bash\nexit 0\n' > "$P/bin/lane-alert.sh"
chmod +x "$P/bin/"*.sh
GOOD="lane-snapshot-publish: 0 published, 0 unchanged, 0 write-backs applied, 0 conflicts, 0 rejected, 0 failed; blocked-resolver placed hub (fixture); alert lines: 0 replayed, 0 already applied, ack none"

rm -f "$T/started"
HARNESS="$P" STARTED="$T/started" APPLY_SLEEP=3 bash "$P/bin/lane-snapshot-publish.sh" p1 > "$T/first.out" 2>&1 &
FIRST=$!
for _ in $(seq 1 60); do [ -e "$T/started" ] && break; sleep 0.1; done
[ -e "$T/started" ] && ok "L1 the first run is inside its work" || bad "L1 the first run never started"
out=$(HARNESS="$P" bash "$P/bin/lane-snapshot-publish.sh" p1 2>&1); rc=$?
[ "$rc" = 0 ] && ok "L1 the second run exits 0" || bad "L1 the second run rc=$rc: $out"
NA=$(grep -c 'already running' <<<"$out")
[ "$NA" = 1 ] && ok "L1 the second run prints one 'already running' line" || bad "L1 the second run printed $NA 'already running' lines: $out"
wait "$FIRST"; frc=$?
[ "$frc" = 0 ] && [ "$(cat "$T/first.out")" = "$GOOD" ] && ok "L1 the first run finishes with its normal line" || bad "L1 the first run rc=$frc: $(cat "$T/first.out")"
LN=$(grep -c 'already running' "$P/logs/lane-snapshot-publish.log")
[ "$LN" = 1 ] && ok "L1 the log holds one 'already running' line" || bad "L1 the log holds $LN 'already running' lines"
[ -f "$P/locks/lane-snapshot-publish.blocked-resolver.lock" ] && ok "L1 the lock is locks/lane-snapshot-publish.blocked-resolver.lock" || bad "L1 no lock file at locks/lane-snapshot-publish.blocked-resolver.lock"
out=$(HARNESS="$P" bash "$P/bin/lane-snapshot-publish.sh" p1 2>&1); rc=$?
[ "$rc:$out" = "0:$GOOD" ] && ok "L1 a run after both finished runs normally" || bad "L1 a later run rc=$rc: $out"

# ============================================================================
echo "L2: a pipeline-health run is not turned away by a blocked-resolver run"
rm -f "$T/started"
HARNESS="$P" STARTED="$T/started" APPLY_SLEEP=3 bash "$P/bin/lane-snapshot-publish.sh" p1 > "$T/first.out" 2>&1 &
FIRST=$!
for _ in $(seq 1 60); do [ -e "$T/started" ] && break; sleep 0.1; done
out=$(HARNESS="$P" bash "$P/bin/lane-snapshot-publish.sh" --lane pipeline-health p1 2>&1); rc=$?
wait "$FIRST"
case "$out" in *"already running"*) bad "L2 the pipeline-health run was turned away: $out" ;; *) ok "L2 the pipeline-health run is not turned away" ;; esac
[ "$rc" = 0 ] && [ "${out#*pipeline-health placed hub}" != "$out" ] && ok "L2 the pipeline-health run finishes normally" || bad "L2 the pipeline-health run rc=$rc: $out"

# ============================================================================
echo "L3: the lock does not silence the script's stderr"
err=$(HARNESS="$P" bash "$P/bin/lane-snapshot-publish.sh" --lane '../x' p1 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && ok "L3 a bad lane exits 2" || bad "L3 a bad lane rc=$rc"
case "$err" in *"is not a path-safe name"*) ok "L3 the bad-lane error reaches stderr" ;; *) bad "L3 stderr lost after the lock: '$err'" ;; esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
