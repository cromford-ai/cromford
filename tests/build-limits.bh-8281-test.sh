#!/bin/bash
# tests/build-limits.bh-8281-test.sh — bin/lib/build-limits.sh: a build session
# and a fix round run with CARGO_BUILD_JOBS capped and a lower CPU priority
# (BH-8281).
#
# WHY. On 2026-10-24 box-project-6-os-1 reached load 92 after it took the
# project-6-desktop cargo build. The hub could not ssh to it for 7 hours, so
# the project-6-os pool could not copy its env bundle, and six project-6 fix
# rounds on the box ended rc=137.
#
# WHAT IS DRIVEN. The real lib through the real lane-gate.sh, against a
# registry composed from this checkout's catalog/lanes.d and a hand-written
# box settings cache. Stubs: nproc ($T/nproc), renice (records its argv, exits
# $T/renice.rc) — except B7, which uses the real renice. B8 runs the marked
# region of the real bin/run-build.sh; B9 runs the real bin/fix-round-claim.sh
# --run with a stub blocked-resolver.sh and a fake jobs worker (curl).
#
#   B1  no rows, nproc 8: CARGO_BUILD_JOBS=4, renice asked for 10 on the caller
#   B2  row BUILD_CARGO_JOBS=2 for project-6-desktop: 2; project-6-os: still 4
#   B3  a preset CARGO_BUILD_JOBS=3 stays 3
#   B4  nproc 1: 1; env BUILD_CARGO_JOBS=abc: auto
#   B5  row BUILD_NICE=0: no renice; already at nice 15: no renice
#   B6  renice fails: rc 0, CARGO_BUILD_JOBS still exported, stdout empty
#   B7  real renice: a child started after bl_apply runs at the new niceness
#   B8  bin/run-build.sh: the env load line plus the build-limits region export
#       the cap and print the stderr line; a project env CARGO_BUILD_JOBS wins;
#       the same lines without the bl_apply call export nothing (D1)
#   B9  bin/fix-round-claim.sh --run: the round sees the cap and nice 10, reads
#       its record on stdin, the row finishes done, and the runner's own nice
#       after the round is unchanged
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/build-limits.bh-8281-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/build-limits.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq nice base64; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

unset CARGO_BUILD_JOBS BUILD_CARGO_JOBS BUILD_NICE JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE LANE_GATE_CACHE_S
NOW=$(date +%s)
export LANE_GATE_NOW=$NOW
BASE=$(nice)
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: could not compose the lane registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json"
[ -r "$LIB" ] || bad "fixture: no $LIB"

FAKE="$T/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/bash\ncat "%s/nproc"\n' "$T" > "$FAKE/nproc"
printf '#!/bin/bash\necho "$*" >> "%s/renice.calls"\nexit "$(cat "%s/renice.rc" 2>/dev/null || echo 0)"\n' "$T" "$T" > "$FAKE/renice"
chmod +x "$FAKE"/*

H="$T/h"
# settings <json values> — a FRESH box settings cache, so lane-gate makes no GET.
settings() { mkdir -p "$H/state"; printf '{"fetched_at":%s,"values":%s,"seeded":{}}' "$NOW" "$1" > "$H/state/settings-cache.json"; }
reset() { rm -f "$T/renice.calls" "$T/renice.rc" "$T/out" "$T/err" "$T/blout"; echo 8 > "$T/nproc"; settings '{}'; }
# bl <project> [shell prefix] — bl_apply in a fresh shell; stdout: "<jobs> <pid>".
bl() {
  ( export PATH="$FAKE:$PATH"
    ${3:+export $3}
    bash -c '. "$1" || exit 9; bl_apply "$2" "$3" > "$4"; echo "${CARGO_BUILD_JOBS:-unset} $$"' _ "$LIB" "$H" "$1" "$T/blout" ) 2>"$T/err"
}
renice_calls() { local n; n=$(grep -c . "$T/renice.calls" 2>/dev/null) || n=0; printf '%s' "$n"; }

# B1 — registry defaults.
reset
read -r jobs pid < <(bl project-6-desktop)
[ "$jobs" = 4 ] && ok || bad "B1 nproc 8 with no row: want CARGO_BUILD_JOBS=4, got $jobs ($(cat "$T/err"))"
if [ "$BASE" -lt 10 ]; then
  [ "$(cat "$T/renice.calls" 2>/dev/null)" = "-n 10 -p $pid" ] && ok \
    || bad "B1 want one renice '-n 10 -p $pid', got '$(cat "$T/renice.calls" 2>/dev/null)'"
fi
grep -q '^build-limits: project-6-desktop CARGO_BUILD_JOBS=4 nice=' "$T/err" && ok || bad "B1 stderr line: $(cat "$T/err")"
d=$(jq -c '[.libs[0].knobs[] | {(.env): .default}] | add' "$DIR/catalog/lanes.d/_lib.build-limits.json")
[ "$d" = '{"BUILD_CARGO_JOBS":0,"BUILD_NICE":10}' ] && ok || bad "B1 registry defaults: $d"

# B2 — a per-project row.
reset; settings '{"lib.build-limits.project-6-desktop.build_cargo_jobs":"2"}'
read -r jobs _ < <(bl project-6-desktop)
[ "$jobs" = 2 ] && ok || bad "B2 row 2 for project-6-desktop: got $jobs ($(cat "$T/err"))"
read -r jobs _ < <(bl project-6-os)
[ "$jobs" = 4 ] && ok || bad "B2 project-6-os has no row: want 4, got $jobs"

# B3 — a preset value wins.
reset
read -r jobs _ < <(bl project-6-desktop "" CARGO_BUILD_JOBS=3)
[ "$jobs" = 3 ] && ok || bad "B3 preset CARGO_BUILD_JOBS=3: got $jobs"

# B4 — one core, and a bad env value.
reset; echo 1 > "$T/nproc"
read -r jobs _ < <(bl project-6-desktop)
[ "$jobs" = 1 ] && ok || bad "B4 nproc 1: want 1, got $jobs"
reset
read -r jobs _ < <(bl project-6-desktop "" BUILD_CARGO_JOBS=abc)
[ "$jobs" = 4 ] && ok || bad "B4 env BUILD_CARGO_JOBS=abc: want auto 4, got $jobs"

# B5 — off, and never raise priority.
reset; settings '{"lib.build-limits.build_nice":"0"}'
read -r jobs _ < <(bl project-6-desktop)
[ "$(renice_calls)" = 0 ] && [ "$jobs" = 4 ] && ok || bad "B5 BUILD_NICE=0: renice calls $(renice_calls), jobs $jobs"
reset
( export PATH="$FAKE:$PATH"; nice -n $((15 - BASE)) bash -c '. "$1" && bl_apply "$2" project-6-desktop' _ "$LIB" "$H" ) 2>"$T/err"
[ "$(renice_calls)" = 0 ] && ok || bad "B5 at nice 15 with BUILD_NICE=10: renice called: $(cat "$T/renice.calls")"
grep -q 'nice=15$' "$T/err" && ok || bad "B5 stderr reads the real nice 15: $(cat "$T/err")"

# B6 — renice fails.
reset; echo 1 > "$T/renice.rc"
out=$( export PATH="$FAKE:$PATH"; bash -c '. "$1"; bl_apply "$2" project-6-desktop > "$3"; echo "rc=$? jobs=${CARGO_BUILD_JOBS:-unset}"' _ "$LIB" "$H" "$T/blout" 2>"$T/err")
[ "$out" = "rc=0 jobs=4" ] && ok || bad "B6 renice fails: want 'rc=0 jobs=4', got '$out'"
[ ! -s "$T/blout" ] && ok || bad "B6 bl_apply printed on stdout: $(cat "$T/blout")"
[ "$BASE" -ge 10 ] || { grep -q "nice=$BASE\$" "$T/err" && ok || bad "B6 a failed renice is not reported as applied: $(cat "$T/err")"; }

# B7 — the real renice.
reset
REAL_RENICE=0; bash -c 'renice -n '"$((BASE + 1))"' -p $$ >/dev/null 2>&1' && REAL_RENICE=1
if [ "$BASE" -ge 10 ]; then echo "B7 skipped: this test already runs at nice $BASE"
elif [ "$REAL_RENICE" = 0 ]; then echo "B7 skipped: renice does not work for $(id -un)"
else
  out=$( export PATH="$FAKE:$PATH"; rm -f "$FAKE/renice"
         bash -c '. "$1"; bl_apply "$2" project-6-desktop; bash -c nice' _ "$LIB" "$H" 2>"$T/err")
  printf '#!/bin/bash\necho "$*" >> "%s/renice.calls"\nexit "$(cat "%s/renice.rc" 2>/dev/null || echo 0)"\n' "$T" "$T" > "$FAKE/renice"; chmod +x "$FAKE/renice"
  [ "$out" = 10 ] && ok || bad "B7 a child after bl_apply: want nice 10, got '$out' ($(cat "$T/err"))"
fi

# B8 — the production entry point: bin/run-build.sh.
# The pipeline as one text (tests/lib/rb-all.sh, BH-478): the region is read,
# not the raw driver, so the BH-478 split can move it into bin/lib/rb/.
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "B8 setup: rb_all could not flatten bin/run-build.sh"; RB=/dev/null; }
REGION=$(awk '/^set -a; \. "\$HENV\/global.env"/{on=1} on{print} /^# <<< build limits/{if(on)exit}' "$RB")
if grep -q '^# >>> build limits (BH-8281)' <<<"$REGION" && grep -q '^# <<< build limits' <<<"$REGION" \
   && grep -q 'bl_apply "\$HARNESS" "\$PROJECT"' <<<"$REGION"; then ok
else bad "B8 run-build.sh has no build-limits region right after the env load line"; REGION='set -a; . "$HENV/global.env"; set +a'; fi
RBH="$T/rbh"; mkdir -p "$RBH/state" "$RBH/env"; ln -sfn "$DIR/bin" "$RBH/bin"
cp "$H/state/settings-cache.json" "$RBH/state/"
: > "$RBH/env/global.env"
rb_region() { # rb_region <region text> <project> — stdout: CARGO_BUILD_JOBS
  ( export PATH="$FAKE:$PATH"
    HARNESS="$RBH" HENV="$RBH/env" PROJECT="$2" bash -c "$1"'
echo "${CARGO_BUILD_JOBS:-unset}"' ) 2>"$T/err"
}
reset; cp "$H/state/settings-cache.json" "$RBH/state/"
out=$(rb_region "$REGION" project-6-desktop)
[ "$out" = 4 ] && grep -q '^build-limits: project-6-desktop CARGO_BUILD_JOBS=4 nice=' "$T/err" && ok \
  || bad "B8 run-build region: want CARGO_BUILD_JOBS=4 and the stderr line, got '$out' ($(cat "$T/err"))"
echo 'CARGO_BUILD_JOBS=3' > "$RBH/env/project-6-desktop.env"
out=$(rb_region "$REGION" project-6-desktop)
[ "$out" = 3 ] && ok || bad "B8 a project env CARGO_BUILD_JOBS=3 must win (region after the env load): got '$out'"
rm -f "$RBH/env/project-6-desktop.env"
out=$(rb_region "$(sed 's/bl_apply "\$HARNESS" "\$PROJECT"/:/' <<<"$REGION")" project-6-desktop)
[ "$out" = unset ] && ok || bad "B8 mutation: without the bl_apply call the region must export nothing, got '$out'"

# B9 — the production entry point: bin/fix-round-claim.sh --run.
FH="$T/fh"
mkdir -p "$FH/bin/lib/jobs" "$FH/env" "$FH/logs" "$FH/state" "$FH/locks" "$FH/catalog/lanes.d"
cp "$DIR/catalog/lanes.d/_lib.build-limits.json" "$FH/catalog/lanes.d/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$FH/env/global.env"
printf '{"fetched_at":%s,"values":{"lib.build-limits.project-6-desktop.build_cargo_jobs":"2"},"seeded":{}}' "$NOW" \
  > "$FH/state/settings-cache.json"
printf '#!/bin/bash\necho b1\n' > "$FH/bin/box-name.sh"
printf '#!/bin/bash\n[ "${2:-}" = repo ] && echo o/r\n' > "$FH/bin/fleet-conf.sh"
printf '#!/bin/bash\necho tok\n' > "$FH/bin/gh-token.sh"
cat > "$FH/bin/blocked-resolver.sh" <<EOF
#!/bin/bash
printf '%s %s\n' "\${CARGO_BUILD_JOBS:-unset}" "\$(nice)" > "$T/br.seen"
cat > "$T/br.stdin"
echo "FIX_RESULT done"
EOF
cat > "$FAKE/curl" <<EOF
#!/bin/bash
body=""
while [ \$# -gt 0 ]; do case "\$1" in --data-binary) body="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
printf '%s %s\n' "\$(nice)" "\$body" >> "$T/curl.log"
printf '{"job":{"id":7,"status":"done"}}'; printf 200
EOF
chmod +x "$FH"/bin/*.sh "$FAKE/curl"
# The real script and what it sources; the stubs above are kept (no-clobber).
for s in bin/fix-round-claim.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$FH" ) >/dev/null \
    || { echo "FAIL: setup: could not install the $s closure"; exit 1; }
done
[ -r "$FH/bin/lib/build-limits.sh" ] && ok || bad "B9 setup: the fix-round-claim.sh closure must carry bin/lib/build-limits.sh"
jq -nc --arg rin '{"project":"project-6-desktop","attempts":[]}' \
  '{id:7, project:"project-6-desktop", cap_key:"ck", box:"b1", attempt:1, record_in:$rin,
    args:["project-6-desktop","rk","why","https://u/1","rec","tk"]}' > "$T/row.json"
# The real renice here: the round's niceness and the runner's are both read.
WANT_NICE=$BASE; [ "$REAL_RENICE" = 1 ] && [ "$BASE" -lt 10 ] && WANT_NICE=10
( unset CARGO_BUILD_JOBS BR_FIX_LANE_TIMEOUT GH_TOKEN BOX_NAME
  rm -f "$FAKE/renice"
  export HARNESS="$FH" PATH="$FAKE:$PATH"; echo 8 > "$T/nproc"
  bash "$FH/bin/fix-round-claim.sh" --run 7 "$T/row.json" >/dev/null 2>&1 )
[ "$(cat "$T/br.seen" 2>/dev/null)" = "2 $WANT_NICE" ] && ok \
  || bad "B9 the round must see CARGO_BUILD_JOBS=2 and nice $WANT_NICE, saw '$(cat "$T/br.seen" 2>/dev/null)'"
[ "$(cat "$T/br.stdin" 2>/dev/null)" = '{"project":"project-6-desktop","attempts":[]}' ] && ok \
  || bad "B9 the round must read its record on stdin, read '$(cat "$T/br.stdin" 2>/dev/null)'"
fin=$(grep 'fix-rounds\|"result"' "$T/curl.log" 2>/dev/null | tail -n 1)
grep -q '"result":"done"' <<<"$fin" && ok || bad "B9 the row must finish done: $(cat "$T/curl.log" 2>/dev/null) / $(cat "$FH/logs/fix-round-claim.log" 2>/dev/null)"
[ "${fin%% *}" = "$BASE" ] && ok || bad "B9 the runner's own nice after the round must stay $BASE, the finish ran at '${fin%% *}'"
grep -q '^build-limits: project-6-desktop CARGO_BUILD_JOBS=2' "$FH/logs/fix-round-claim.log" && ok \
  || bad "B9 the lane log must carry the build-limits line: $(cat "$FH/logs/fix-round-claim.log" 2>/dev/null)"

echo "build-limits: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
