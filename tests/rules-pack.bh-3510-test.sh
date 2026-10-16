#!/bin/bash
# tests/rules-pack.bh-3510-test.sh — the rules pack engine, its local runner
# and its built-in checks (BH-3510, BH-3477.1).
#
# Every case runs the real bin/rules-pack.sh against ONE hermetic fixture repo
# (a git archive of this checkout, reset per case) with --runner local, and
# the violation for the case committed on `work`:
#   R1.  lib-root: a new bin/lib literal root fallback is a finding naming it.
#   R2.  grep-q: a tests/*.sh file-grep piped into grep -q is a finding.
#   R3.  alert-writers: a raw ALERTS.log write is a finding naming the file.
#   R4.  jobs-client-modules: a module function the map does not name.
#   R5.  jobs-client-modules: a fixture copying the real client.
#   R6.  model-id-delta: an added model id literal; the price map is exempt.
#        R6c-g: schema.sql + schema.d/ read as one logical file (BH-4987).
#   R7.  date-bomb: its findings are routed, and it gets `--base <fork> .`.
#   R8.  a clean full pack under a 300 s budget: rc 0, empty stdout,
#        summary.json and suites.txt; every component ran to an answer (none
#        hit its timeout); the budget fields agree (runner speed is never
#        asserted, BH-4220, BH-5544).
#   R9.  the stdout contract: `<id>: ` lines, stderr summary, findings.txt.
#   R10. a tree component red on main and on HEAD is pre-existing, rc 0.
#   R11. a delta component cancels what main landed.
#   R12. a missing `needs` binary is could-not-run; all could-not-run is 125.
#   R13. an unresolvable base is rc 2.
#   R14. RULES_PACK_BUDGET_S: lane_knob > env > 60, junk falls back.
#   R15. --runner isolated calls the snapshot lib as documented (stub lib).
#   R16. a hung component times out at 2x the budget: could-not-run.
#   R17. local as root beside a harness without the sandbox var: suites
#        could-not-run, builtins still judged (root only).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/rules-pack.bh-3510-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RP="$DIR/bin/rules-pack.sh"
CHK="$DIR/bin/lib/rules-pack-checks.sh"
unset RULES_PACK_BUDGET_S RULES_PACK_JOBS PROJECT
# R8 judges the work the pack did, never the runner's clock. 300 s makes the
# per-component timeout 600 s (bin/rules-pack.sh: 2x the budget), 15x the
# slowest component measured on a box (40 s). The hang guard is R16 (a 2 s cap
# on a component that never ends) plus the runner's per-suite bound.
# RP_R8_BUDGET_S exists only so a red-first check can shrink the cap.
R8_BUDGET_S="${RP_R8_BUDGET_S:-300}"
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1
mkdir -p "$T/nolg"

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
# pack <outname> <args...> — the real pack on the fixture, local runner, and
# no live lane-gate.sh (HARNESS is an empty dir).
pack() {
  local o="$1"; shift
  run env HARNESS="$T/nolg" bash "$RP" --tree "$R" --runner local --out "$T/$o" "$@"
}
js() { jq -r "$2" "$T/$1/summary.json" 2>/dev/null; }
# has_line <prefix> <substring> — some stdout line starts with prefix and holds substring
has_line() { awk -v p="$1" -v s="$2" 'index($0, p) == 1 && index($0, s) { f = 1 } END { exit !f }' <<< "$OUT"; }
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "$1"; }

# --- the fixture ----------------------------------------------------------
R="$T/r"
mkdir -p "$R"
git -C "$DIR" archive HEAD | tar -x -C "$R" || { echo "FAIL: cannot archive HEAD"; exit 1; }
# TEST-CHANGE (BH-6005.4): worker/jobs/schema.sql is not in git any more. The
# R6c-g cases model the BH-4987 split, a tree that COMMITS the render, so the
# fixture composes it and tracks it (the .gitignore line is dropped here only).
"$R/bin/schema-build.sh" --root "$R" --worker jobs --to "$R/worker/jobs/schema.sql" 2>/dev/null \
  || { echo "FAIL: cannot compose the fixture's worker/jobs/schema.sql"; exit 1; }
sed -i '/^worker\/jobs\/schema\.sql$/d' "$R/.gitignore"
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0; rd_git "$R" config maintenance.auto false
B0=$(rd_git "$R" rev-parse HEAD)
reset_fx() {
  rd_git "$R" checkout -qf -B work "$B0"
  rd_git "$R" update-ref refs/remotes/origin/main "$B0"
  rd_git "$R" clean -fdxq
}
add_libroot() { printf '#!/bin/bash\n: "${H:=/root/harness}"\n' > "$1/bin/lib/x.sh"; }
# Written in pieces: the literal shape would trip this suite's own lints.
add_grepq() { printf 'grep foo "$F" %s grep -q bar\n' '|' > "$1/tests/x-test.sh"; }

# --- R13 bad base ---------------------------------------------------------
reset_fx
pack o13 --base nosuchref --only grep-q
[ "$RC" -eq 2 ] && ok || bad "R13 --base nosuchref rc $RC (want 2): $ERR"
case "$ERR" in *nosuchref*) ok ;; *) bad "R13 stderr does not name nosuchref: $ERR" ;; esac
[ -z "$OUT" ] && ok || bad "R13 wrote stdout: $OUT"

# --- R14 knob resolution --------------------------------------------------
mkdir -p "$T/lg/bin/lib" "$T/lg2/bin/lib"
echo 'lane_knob() { [ "$2" = RULES_PACK_BUDGET_S ] && echo 30; }' > "$T/lg/bin/lib/lane-gate.sh"
echo 'lane_knob() { [ "$2" = RULES_PACK_BUDGET_S ] && echo abc; }' > "$T/lg2/bin/lib/lane-gate.sh"
run env HARNESS="$T/lg" bash "$RP" --tree "$R" --runner local --out "$T/o14a" --only grep-q
[ "$(js o14a .budget_s)" = 30 ] && ok || bad "R14 settings-row tier budget_s $(js o14a .budget_s) (want 30), rc $RC: $ERR"
run env HARNESS="$T/lg2" bash "$RP" --tree "$R" --runner local --out "$T/o14b" --only grep-q
[ "$(js o14b .budget_s)" = 60 ] && ok || bad "R14 junk knob budget_s $(js o14b .budget_s) (want 60)"
run env HARNESS="$T/nolg" RULES_PACK_BUDGET_S=45 bash "$RP" --tree "$R" --runner local --out "$T/o14c" --only grep-q
[ "$(js o14c .budget_s)" = 45 ] && ok || bad "R14 env tier budget_s $(js o14c .budget_s) (want 45)"

# --- R2 grep-q ------------------------------------------------------------
reset_fx; add_grepq "$R"; commit grepq
pack o2 --only grep-q
[ "$RC" -eq 1 ] && ok || bad "R2 grep-q rc $RC (want 1): $ERR"
case "$OUT" in *"grep-q: tests/x-test.sh: pipes a file-grep into grep -q"*) ok ;;
  *) bad "R2 stdout lacks the grep-q finding: $OUT" ;; esac

# --- R6 model-id-delta ----------------------------------------------------
reset_fx; printf '#!/bin/bash\nM=claude-opus-9\n' > "$R/bin/z.sh"; commit model
pack o6 --only model-id-delta
[ "$RC" -eq 1 ] && ok || bad "R6 model id rc $RC (want 1): $ERR"
case "$OUT" in *"model-id-delta: bin/z.sh: adds a model id literal"*) ok ;;
  *) bad "R6 stdout lacks the model-id-delta finding: $OUT" ;; esac
reset_fx; echo 'M=claude-opus-9' >> "$R/catalog/model-prices.json"; commit prices
pack o6b --only model-id-delta
[ "$RC" -eq 0 ] && ok || bad "R6 price-map literal rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "R6 price-map literal wrote stdout: $OUT"
# R6c-R6g (BH-4987): a worker whose schema is composed from schema.d/
# fragments is read as ONE logical file per side (the fragments in name order,
# else schema.sql), and its model-id lines are compared as a multiset: a seed
# row moved from schema.sql into a fragment, or between fragments, cancels
# out; a line new on the logical file is one finding, on its fragment, with or
# without a re-rendered schema.sql. The fixtures build their own schema.d/, so
# they hold whether or not the tree under test already has one.
SQ="$R/worker/jobs/schema.sql"; SD="$R/worker/jobs/schema.d"
# split_fx — the split commit: schema.d/ holds schema.sql's bytes in two files.
split_fx() {
  local n; n=$(($(wc -l < "$SQ") / 2))
  mkdir -p "$SD"
  head -n "$n" "$SQ" > "$SD/0000-head.sql"; tail -n +"$((n + 1))" "$SQ" > "$SD/0001-tail.sql"
}
# render — schema.sql as the plain concatenation of the fragments.
render() { cat "$SD"/*.sql > "$SQ.new" && mv "$SQ.new" "$SQ"; }
grep -Eq 'claude-[a-z]+-[0-9]' "$SQ" || bad "R6c-g fixture: schema.sql carries no model id, the cases would prove nothing"
# R6f the split itself: every seed row "appears" in a new file; none is new.
reset_fx; scratch_rm "$SD"; split_fx; commit split
pack o6f --only model-id-delta
[ "$RC" -eq 0 ] && ok || bad "R6f the split (seed rows moved into schema.d/) rc $RC (want 0): $(head -3 <<< "$OUT") $ERR"
# R6g the split plus one genuinely new literal in a fragment: exactly that one.
printf -- '-- seed: claude-opus-9\n' >> "$SD/0001-tail.sql"; commit splitnew
pack o6g --only model-id-delta
[ "$RC" -eq 1 ] && [ "$(grep -c . <<< "$OUT")" = 1 ] && ok \
  || bad "R6g the split plus one new literal must be one finding, rc $RC: $OUT $ERR"
case "$OUT" in *"model-id-delta: worker/jobs/schema.d/0001-tail.sql: adds a model id literal (R6/S7): -- seed: claude-opus-9"*) ok ;;
  *) bad "R6g the finding must name the fragment and quote the literal: $OUT" ;; esac
# From here main already has the split: it is the base.
reset_fx; scratch_rm "$SD"; split_fx; commit splitbase
rd_git "$R" update-ref refs/remotes/origin/main "$(rd_git "$R" rev-parse HEAD)"
SPLIT=$(rd_git "$R" rev-parse HEAD)
# R6d moving every seed row between fragments (schema.sql unchanged): clean.
cat "$SD/0001-tail.sql" >> "$SD/0000-head.sql"; rm "$SD/0001-tail.sql"
cmp -s <(cat "$SD"/*.sql) "$SQ" || bad "R6d fixture: the move changed the composition"
commit fragmove
pack o6d --only model-id-delta
[ "$RC" -eq 0 ] && ok || bad "R6d a fragment move rc $RC (want 0): $OUT $ERR"
# R6c a new literal in a fragment, rendered into schema.sql: one finding, on the fragment.
rd_git "$R" checkout -qf -B work "$SPLIT"
printf -- '-- seed: claude-opus-9\n' >> "$SD/0001-tail.sql"; render; commit fragnew
pack o6c --only model-id-delta
[ "$RC" -eq 1 ] && ok || bad "R6c a new fragment literal rc $RC (want 1): $ERR"
case "$OUT" in *"model-id-delta: worker/jobs/schema.d/0001-tail.sql: adds a model id literal"*) ok ;;
  *) bad "R6c stdout lacks the finding on the fragment: $OUT" ;; esac
[ "$(grep -c . <<< "$OUT")" = 1 ] && ok || bad "R6c the literal must be judged once, got: $OUT"
# R6e the same literal committed WITHOUT the render: still one finding.
rd_git "$R" checkout -qf -B work "$SPLIT"
printf -- '-- seed: claude-opus-9\n' >> "$SD/0001-tail.sql"; commit fragnorender
pack o6e --only model-id-delta
[ "$RC" -eq 1 ] && [ "$(grep -c . <<< "$OUT")" = 1 ] && ok \
  || bad "R6e a new fragment literal with no render must be one finding, rc $RC: $OUT $ERR"

# --- R7 date-bomb routing -------------------------------------------------
reset_fx
printf '#!/bin/bash\necho "tests/w-test.sh:3: fixture-timebomb: next_recheck_at"\nexit 1\n' > "$R/bin/test-date-bomb-lint.sh"
commit datebomb
pack o7 --only date-bomb
[ "$RC" -eq 1 ] && ok || bad "R7 date-bomb rc $RC (want 1): $ERR"
[ "$OUT" = "date-bomb: tests/w-test.sh:3: fixture-timebomb: next_recheck_at" ] && ok \
  || bad "R7 stdout [$OUT] is not the routed date-bomb line"
reset_fx
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s"\n' "$T/argv" > "$R/bin/test-date-bomb-lint.sh"
commit argv
pack o7b --only date-bomb
[ "$(cat "$T/argv" 2>/dev/null)" = "--base $B0 ." ] && ok \
  || bad "R7 date-bomb argv [$(cat "$T/argv" 2>/dev/null)] (want --base $B0 .)"

# --- R12 could-not-run ----------------------------------------------------
mkdir -p "$T/pathbin"
IFS=: read -ra _pd <<< "$PATH"
for d in "${_pd[@]}"; do
  for f in "$d"/*; do
    b=${f##*/}
    [ "$b" = node ] && continue
    [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$T/pathbin/$b" ] && ln -s "$f" "$T/pathbin/$b"
  done
done
reset_fx
run env PATH="$T/pathbin" HARNESS="$T/nolg" bash "$RP" --tree "$R" --runner local --out "$T/o12" --only route-fragments
[ "$RC" -eq 125 ] && ok || bad "R12 no node rc $RC (want 125): $ERR"
[ "$(js o12 '.could_not_run|join(",")')" = route-fragments ] && ok || bad "R12 could_not_run $(js o12 .could_not_run)"
[ "$(js o12 .state)" = could-not-run ] && ok || bad "R12 state $(js o12 .state) (want could-not-run)"
run env PATH="$T/pathbin" HARNESS="$T/nolg" bash "$RP" --tree "$R" --runner local --out "$T/o12b" --only route-fragments,grep-q
[ "$RC" -eq 0 ] && ok || bad "R12 mixed rc $RC (want 0): $ERR"
[ "$(js o12b '.could_not_run|join(",")')" = route-fragments ] && ok || bad "R12 mixed could_not_run $(js o12b .could_not_run)"

# --- R1 lib-root, R9 the stdout contract ----------------------------------
reset_fx; add_libroot "$R"; commit libroot
pack o1 --only lib-root
[ "$RC" -eq 1 ] && ok || bad "R1 lib-root rc $RC (want 1): $ERR"
has_line "lib-root: " "bin/lib/x.sh" && ok || bad "R1 no lib-root: line names bin/lib/x.sh: $OUT"
badl=$(awk '!/^[a-z0-9-]+: /' <<< "$OUT")
[ -n "$OUT" ] && [ -z "$badl" ] && ok || bad "R9 stdout lines not shaped <id>: [$badl]"
case "$ERR" in *"rules-pack: red:"*) ok ;; *) bad "R9 stderr lacks the 'rules-pack: red:' summary: $ERR" ;; esac
cmp -s "$T/out" "$T/o1/findings.txt" && ok || bad "R9 findings.txt differs from stdout"

# --- R15 isolated wiring (a tool copy with a stub snapshot lib) -----------
TL="$T/tool"
mkdir -p "$TL/bin/lib" "$TL/catalog"
cp "$RP" "$TL/bin/rules-pack.sh"; cp "$CHK" "$TL/bin/lib/rules-pack-checks.sh" 2>/dev/null
cp "$DIR/catalog/rules-pack.tsv" "$TL/catalog/rules-pack.tsv"
printf 'slow\ttree\tcmd\tbin/slow.sh\t-\thangs\n' >> "$TL/catalog/rules-pack.tsv"
printf 'gone\thead\tsuite\ttests/not-at-this-head-test.sh\t-\tadded on main after the PR branched\n' >> "$TL/catalog/rules-pack.tsv"
cat > "$TL/bin/lib/rules-pack-snapshot.sh" <<'EOF'
rp_snapshot_probe() { return "${STUB_PROBE_RC:-125}"; }
rp_snapshot_reachable() { return 0; }
rp_snapshot_build() {
  printf '%s\n' "$@" > "$STUB_LOG"
  git clone -q "$1" "$4/repo" || return 125
  git -C "$4/repo" update-ref refs/remotes/origin/main "$2" || return 125
  mkdir -p "$4/base" && git -C "$1" archive "$2" | tar -x -C "$4/base" || return 125
  printf '%s\n' "$2"
}
rp_snapshot_run() { local d="$1"; shift; ( cd "$d" && "$@" ); }
EOF
HEAD1=$(rd_git "$R" rev-parse HEAD)
run env HARNESS="$T/nolg" STUB_PROBE_RC=125 STUB_LOG="$T/build-a" bash "$TL/bin/rules-pack.sh" --tree "$R" --runner isolated --out "$T/o15a" --only lib-root
[ "$RC" -eq 125 ] && ok || bad "R15a probe 125 rc $RC (want 125): $ERR"
[ "$(js o15a '.could_not_run|join(",")')" = lib-root ] && ok || bad "R15a could_not_run $(js o15a .could_not_run)"
[ ! -e "$T/build-a" ] && ok || bad "R15a snapshot build ran after a failed probe"
run env HARNESS="$T/nolg" STUB_PROBE_RC=0 STUB_LOG="$T/build-b" bash "$TL/bin/rules-pack.sh" --tree "$R" --runner isolated --out "$T/o15b" --only lib-root
[ "$RC" -eq 1 ] && ok || bad "R15b isolated lib-root rc $RC (want 1): $ERR"
has_line "lib-root: " "bin/lib/x.sh" && ok || bad "R15b no lib-root: line names bin/lib/x.sh: $OUT"
args=$(head -n 3 "$T/build-b" 2>/dev/null | tr '\n' ' ')
[ "$args" = "$R $B0 $HEAD1 " ] && ok || bad "R15b snapshot build args [$args] (want $R $B0 $HEAD1)"
w4=$(sed -n 4p "$T/build-b" 2>/dev/null)
[ -n "$w4" ] && [ ! -e "$w4" ] && ok || bad "R15b workdir [$w4] missing or not cleaned up"

# --- R3 alert-writers -----------------------------------------------------
reset_fx; printf '#!/bin/bash\necho "x" >> "$H/logs/ALERTS%s"\n' .log > "$R/bin/x.sh"; commit alert
pack o3 --only alert-writers
[ "$RC" -eq 1 ] && ok || bad "R3 alert-writers rc $RC (want 1): $ERR"
has_line "alert-writers: " "bin/x.sh" && ok || bad "R3 no alert-writers: line names bin/x.sh: $OUT"

# --- R4 + R5 jobs-client-modules ------------------------------------------
reset_fx
echo 'jobs_bh3510_probe() { :; }' >> "$R/bin/lib/jobs/flags.sh"
printf 'cp "$DIR/bin/jobs-client%s" "$H2/bin/"\n' .sh > "$R/tests/y-test.sh"
commit modules
pack o4 --only jobs-client-modules
[ "$RC" -eq 1 ] && ok || bad "R4 jobs-client-modules rc $RC (want 1): $ERR"
has_line "jobs-client-modules: " "jobs_bh3510_probe" && ok || bad "R4 no line names jobs_bh3510_probe: $OUT"
has_line "jobs-client-modules: " "y-test.sh" && ok || bad "R5 no line names y-test.sh: $OUT"

# --- R10 pre-existing tree red --------------------------------------------
reset_fx
rd_main_commit "$R" "main adds x-test" add_grepq
rd_git "$R" merge -q --no-edit refs/remotes/origin/main
echo unrelated > "$R/docs/bh3510.txt"; commit unrelated
pack o10 --only grep-q
[ "$RC" -eq 0 ] && ok || bad "R10 pre-existing rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "R10 pre-existing wrote stdout: $OUT"
case "$(cat "$T/o10/preexisting.txt" 2>/dev/null)" in *tests/x-test.sh*) ok ;; *) bad "R10 preexisting.txt lacks tests/x-test.sh" ;; esac
case "$ERR" in *pre-existing*) ok ;; *) bad "R10 stderr lacks pre-existing: $ERR" ;; esac
[ "$(js o10 '.components[]|select(.id=="grep-q").state')" = pre-existing ] && ok || bad "R10 grep-q state $(js o10 '.components[0].state')"

# --- R11 delta cancels main drift -----------------------------------------
reset_fx
rd_main_commit "$R" "main adds x.sh" add_libroot
rd_git "$R" merge -q --no-edit refs/remotes/origin/main
echo unrelated > "$R/docs/bh3510.txt"; commit unrelated
pack o11 --only lib-root
[ "$RC" -eq 0 ] && ok || bad "R11 main drift rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "R11 main drift wrote stdout: $OUT"

# --- R16 timeout ----------------------------------------------------------
reset_fx
printf '#!/bin/bash\nexec tail -f /dev/null\n' > "$R/bin/slow.sh"; chmod +x "$R/bin/slow.sh"
run env HARNESS="$T/nolg" RULES_PACK_BUDGET_S=1 bash "$TL/bin/rules-pack.sh" --tree "$R" --runner local --out "$T/o16" --only slow
[ "$RC" -eq 125 ] && ok || bad "R16 hung component rc $RC (want 125): $ERR"
[ "$(js o16 '.components[0]|"\(.rc) \(.state)"')" = "124 could-not-run" ] && ok || bad "R16 component $(js o16 '.components[0]')"

# --- R18 (BH-5793) a suite the PR head does not carry is could-not-run ----
# The catalog names a suite main added after this PR branched. That is the
# runner's environment, not a finding about the PR: never a red line.
reset_fx
run env HARNESS="$T/nolg" bash "$TL/bin/rules-pack.sh" --tree "$R" --runner local --out "$T/o18" --only gone
[ "$RC" -eq 125 ] && ok || bad "R18 a missing suite rc $RC (want 125, could-not-run): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "R18 a missing suite printed a finding: $OUT"
[ "$(js o18 '.could_not_run|join(",")')" = gone ] && ok || bad "R18 could_not_run $(js o18 .could_not_run)"
case "$ERR" in *"could-not-run: gone: suite missing at the PR head: tests/not-at-this-head-test.sh"*) ok ;;
  *) bad "R18 stderr does not name the missing suite: $ERR" ;; esac
run env HARNESS="$T/nolg" bash "$TL/bin/rules-pack.sh" --tree "$R" --runner local --out "$T/o18b" --only gone,grep-q
[ "$RC" -eq 0 ] && ok || bad "R18 mixed rc $RC (want 0, the present components judged): $OUT $ERR"

# --- R17 local as root, no sandbox var ------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  reset_fx; mkdir -p "$T/fakeh"
  run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX= HARNESS_ROOT_OVERRIDE="$T/fakeh" bash "$RP" --tree "$R" --runner local --out "$T/o17" --only lib-root,grep-q
  [ "$RC" -eq 0 ] && ok || bad "R17 rc $RC (want 0): $OUT $ERR"
  [ "$(js o17 '.could_not_run|join(",")')" = lib-root ] && ok || bad "R17 could_not_run $(js o17 .could_not_run)"
  case "$ERR" in *HARNESS_TEST_SANDBOX=1*) ok ;; *) bad "R17 stderr does not name HARNESS_TEST_SANDBOX=1: $ERR" ;; esac
else
  echo "R17: skipped (not root)"
fi

# --- R8 a clean full pack -------------------------------------------------
reset_fx
RULES_PACK_BUDGET_S=$R8_BUDGET_S pack o8
[ "$RC" -eq 0 ] && ok || bad "R8 full pack rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "R8 full pack wrote stdout: $OUT"
[ "$(js o8 .state)" = clean ] && ok || bad "R8 state $(js o8 .state) (want clean)"
[ "$(js o8 '"\(.budget_s) \(.over_budget == (.elapsed_s > .budget_s)) \((.elapsed_s|type) == "number" and .elapsed_s >= 0)"')" = "$R8_BUDGET_S true true" ] && ok \
  || bad "R8 budget fields $(js o8 '"over=\(.over_budget) elapsed=\(.elapsed_s) budget=\(.budget_s)"') (want budget $R8_BUDGET_S and over_budget == elapsed > budget)"
if [ "$(js o8 .over_budget)" = true ]; then
  case "$ERR" in *"rules-pack: over budget ("*) ok ;; *) bad "R8 over budget but no stderr note: $ERR" ;; esac
fi
to=$(js o8 '[.components[]|select(.rc == 124)|.id]|join(",")')
[ -z "$to" ] && ok || bad "R8 component(s) hit the ${R8_BUDGET_S}x2 s timeout: $to (a component that cannot finish, not runner speed)"
[ "$(js o8 '"\(.base) \(.head)"')" = "$B0 $B0" ] && ok || bad "R8 base/head $(js o8 '"\(.base) \(.head)"') (want $B0 $B0)"
# TEST-CHANGE (BH-5797): the pack gained fast-lints-data and marker-reason, and
# (BH-5789) fixture-hygiene; (BH-4582) tier-wording; (BH-4987) lanes-knob-delta,
# so the real catalog has 20 components. The assertion still pins the exact count.
# TEST-CHANGE (BH-5788): schema-fragment, schema-fragment-name and
# discipline-dupes make it 23.
# TEST-CHANGE (BH-6730): 24 with index-on-create-table.
# TEST-CHANGE (BH-6293): 25 with split-host-growth.
[ "$(js o8 '.components|length')" = 25 ] && ok || bad "R8 $(js o8 '.components|length') components (want 25)"
cnr=$(js o8 '.could_not_run - ["date-bomb"] | join(",")')
[ -z "$cnr" ] && ok || bad "R8 could_not_run beyond date-bomb: $cnr"
[ "$(js o8 '.components[]|select(.id=="route-fragments").state')" = green ] && ok \
  || bad "R8 route-fragments state $(js o8 '.components[]|select(.id=="route-fragments").state') (want green)"
want_suites=$(grep -v '^#' "$DIR/catalog/rules-pack.tsv" | awk -F'\t' '$3 == "suite" { print $4 }')
[ -n "$want_suites" ] && [ "$(cat "$T/o8/suites.txt" 2>/dev/null)" = "$want_suites" ] && ok \
  || bad "R8 suites.txt [$(cat "$T/o8/suites.txt" 2>/dev/null)] (want [$want_suites])"

echo "rules-pack.bh-3510: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
