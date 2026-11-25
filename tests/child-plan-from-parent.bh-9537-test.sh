#!/bin/bash
# tests/child-plan-from-parent.bh-9537-test.sh — a split child plans FROM its
# parent's plan (BH-9537): a complete context pack per child, the "pack is the
# survey" rule in the child's plan prompt, the PREPLAN_CHILD adopt arm, the
# pack relayed to the hub, and tokens on the tripwire line.
#
#   C1  bin/run-decompose.sh `# >>> context packs` (dcp_publish, extracted
#       verbatim) and the REAL bin/run-decompose.sh dry run: File map, Siblings,
#       Section line; the decision rule; the pack cap.
#   C2  the `# >>> context pack` + `# >>> plan prompt` blocks of the flattened
#       pipeline: the rule rides in a child's prompt; a non-child's prompt is
#       byte-identical to the plan prompt block alone.
#   C3  `# >>> child section adopt` + `# >>> preplan adopt` + the outcome event
#       + `# >>> context pack`: CHILD vs MISS/HIT/STALE/OFF/amended/resumed.
#   C4  changed-since-the-pack marks on a fixture git repo.
#   C5  context-pack.md in POOL_RECORD_FILES, in the fly-pool pull list, and
#       through the pool record put/get/install round trip.
#   C6  the `# >>> child plan tripwire` block: tokens child/parent/ratio.
#
# No network: _jobs_req, cp_fetch and preplan_fetch are shell stubs; git repos
# are local fixtures. Each case uses its own dirs under the scratch tree.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/child-plan-from-parent.bh-9537-test.sh
# scratch-closure-allow: the C2/C3/C6 cases run plan.sh blocks extracted verbatim (no script), which source exactly these libs from a scratch $HARNESS; some libs carry a stubbed cp_fetch/preplan_fetch and cases remove one lib to prove the fail-open path
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
LIB="$DIR/bin/lib/child-pack.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }
has() { grep -qF -- "$2" <<<"$3" && ok || bad "$1: missing [$2]"; }
hasnt() { grep -qF -- "$2" <<<"$3" && bad "$1: must not contain [$2]" || ok; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] && ok || bad "bin/lib/child-pack.sh does not exist"
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all"; exit 1; }
blk() { # blk <file> <open-marker-prefix> <close-marker-prefix> — verbatim, markers included
  awk -v o="$2" -v c="$3" 'index($0, o)==1 {f=1} f {print} f && index($0, c)==1 {exit}' "$1"
}
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# ============================================================================
# Fixtures: a parent plan with 5 files-to-touch rows, a spec of 3 children.
# ============================================================================
cat > "$T/parent-plan.md" <<'EOF'
# BH-100 — the parent

## Scope
Three slices.

## Files to touch
- `bin/a.sh` — adds the A step
- `bin/b.sh` — calls the A step
- `lib/dir/` — the helper modules
- `tests/a-test.sh` (NEW) — pins A
- `docs/x.md` — documents A

## Edge cases
- bin/a.sh with no input

## Sibling claims (not touched)
SIBTOKEN bin/other.sh
EOF
printf 'bin/a.sh\nbin/b.sh\nlib/dir/\ntests/a-test.sh\ndocs/x.md\n' > "$T/planned-files.txt"
cat > "$T/spec.json" <<'EOF'
[
 {"title":"one","contract":"bin/a.sh: a_step","after":[],"owns":["bin/a.sh","tests/a-test.sh"],"body":"Slice one adds A in bin/a.sh and docs/x.md.\n\n## Scope\nA only.\n\n## Acceptance tests\n- tests/a-test.sh: A runs.\n\n## Observable outcome\nA runs."},
 {"title":"two","after":[],"owns":["bin/b.sh","lib/dir/"],"body":"Slice two wires B.\n\n### Acceptance tests\n- B calls A.\n\n### Observable outcome\nB runs."},
 {"title":"three","after":[],"owns":[],"body":"Slice three is docs.\n\n## Acceptance tests\n- none\n\n## Observable outcome\nDocs."}
]
EOF
printf 'BH-101\nBH-102\nBH-103\n' > "$T/children.txt"
R1="$T/repo1"; mkdir -p "$R1"; gitc "$R1" init -q -b main; gitc "$R1" commit -q --allow-empty -m one
SHA1=$(git -C "$R1" rev-parse HEAD)

# ============================================================================
# C1. dcp_publish (the run-decompose block, verbatim) with DRY=1
# ============================================================================
blk "$DIR/bin/run-decompose.sh" "# >>> context packs" "# <<< context packs" > "$T/dcp-block.sh"
grep -q '^dcp_publish() {' "$T/dcp-block.sh" && ok || bad "C1: could not extract the context packs block"
cat > "$T/dcp-drive.sh" <<'EOF'
set -uo pipefail
LOG() { printf '%s\n' "$*" >> "$BUILD/pipeline.log"; }
. "$1"
cd "$2" || exit 9
dcp_publish "$3"
EOF
B1="$T/b1"; mkdir -p "$B1"
cp "$T/parent-plan.md" "$B1/plan.md"; cp "$T/planned-files.txt" "$B1/planned-files.txt"; cp "$T/children.txt" "$B1/children.txt"
env HARNESS="$DIR" BUILD="$B1" KEY=BH-100 PROJECT=proj DRY=1 bash "$T/dcp-drive.sh" "$T/dcp-block.sh" "$R1" "$T/spec.json" > "$T/c1.out" 2>&1
eq C1.rc "$?" 0
for c in BH-101 BH-102 BH-103; do [ -s "$B1/context-packs/$c.md" ] && ok || bad "C1: no pack for $c ($(cat "$T/c1.out"))"; done
P1="$B1/context-packs/BH-101.md"; P2="$B1/context-packs/BH-102.md"; P3="$B1/context-packs/BH-103.md"
. "$LIB"
# the child scope, byte for byte
for i in 0 1 2; do
  f="$B1/context-packs/BH-10$((i + 1)).md"
  eq "C1.scope.$i" "$(cpk_section "$f" | sed 1d)" "$(jq -r ".[$i].body" "$T/spec.json")"
done
# the file map: the commit, the owned paths, then body-named inventory paths, with the parent rows
MAP1=$(awk '$0=="## File map"{f=1} f&&$0=="## Siblings"{exit} f' "$P1")
eq C1.map1 "$MAP1" "## File map
Read at: $SHA1
- bin/a.sh :: - \`bin/a.sh\` — adds the A step
- tests/a-test.sh :: - \`tests/a-test.sh\` (NEW) — pins A
- docs/x.md :: - \`docs/x.md\` — documents A"
MAP2=$(awk '$0=="## File map"{f=1} f&&$0=="## Siblings"{exit} f' "$P2")
has C1.map2.b "- bin/b.sh :: - \`bin/b.sh\` — calls the A step" "$MAP2"
has C1.map2.dir "- lib/dir/ :: - \`lib/dir/\` — the helper modules" "$MAP2"
hasnt C1.map2.not-sibling "bin/a.sh ::" "$MAP2"
SIB1=$(awk '$0=="## Siblings"{f=1;next} f&&/^Section: /{exit} f&&NF' "$P1")
eq C1.siblings1 "$SIB1" "- BH-102 (2 of 3): bin/b.sh, lib/dir/
- BH-103 (3 of 3): (no owns list)"
SIB2=$(awk '$0=="## Siblings"{f=1;next} f&&/^Section: /{exit} f&&NF' "$P2")
eq C1.siblings2 "$SIB2" "- BH-101 (1 of 3): bin/a.sh, tests/a-test.sh
- BH-103 (3 of 3): (no owns list)"
eq C1.last1 "$(tail -n1 "$P1")" "Section: complete"
eq C1.last2 "$(tail -n1 "$P2")" "Section: complete"
eq C1.last3 "$(tail -n1 "$P3")" "Section: incomplete (no owns list)"
cpk_complete "$P1" && ok || bad "C1: cpk_complete refused a complete pack"
cpk_complete "$P3" && bad "C1: cpk_complete accepted an incomplete pack" || ok
hasnt C1.no-sibling-claims SIBTOKEN "$(cat "$B1/context-packs/"*.md)"
# cp_compose's bytes are the prefix, unchanged
( . "$DIR/bin/lib/context-pack-compose.sh"; jq -r '.[0].body' "$T/spec.json" > "$T/body0"
  cp_compose "$B1/plan.md" "$B1/planned-files.txt" "$T/body0" BH-101 BH-100 1 3 ) > "$T/composed1.md"
N=$(wc -c < "$T/composed1.md")
cmp -s "$T/composed1.md" <(head -c "$N" "$P1") && ok || bad "C1: cp_compose's bytes are not the pack's prefix"
eq C1.dry-log "$(grep -c 'context pack dry-run for BH-10[123]$' "$B1/pipeline.log")" 3
eq C1.no-skip-log "$(grep -c 'extend skipped' "$B1/pipeline.log")" 0

# C1 board lane (no spec): incomplete (no spec entry), empty map, sibling list
B1b="$T/b1b"; mkdir -p "$B1b"
cp "$T/parent-plan.md" "$B1b/plan.md"; cp "$T/planned-files.txt" "$B1b/planned-files.txt"; cp "$T/children.txt" "$B1b/children.txt"
env HARNESS="$DIR" BUILD="$B1b" KEY=BH-100 PROJECT=proj DRY=1 bash "$T/dcp-drive.sh" "$T/dcp-block.sh" "$R1" "" > /dev/null 2>&1
eq C1.board.last "$(tail -n1 "$B1b/context-packs/BH-102.md" 2>/dev/null)" "Section: incomplete (no spec entry)"
has C1.board.sib "- BH-101 (1 of 3): (no owns list)" "$(cat "$B1b/context-packs/BH-102.md" 2>/dev/null)"

# C1 decision rule, on a tiny pack
mkpack() { printf '# Context pack\n\n## Child scope\nthe body\n\n## Parent file inventory\nunfiltered (0 paths)\n' > "$1"; }
rule() { # rule <name> <spec-json|""> <want-last-line>
  local sp=""
  mkpack "$T/rp.md"
  [ -n "$2" ] && { printf '%s' "$2" > "$T/rs.json"; sp="$T/rs.json"; }
  cpk_extend "$T/rp.md" "$sp" 0 "$T/children.txt" "$T/parent-plan.md" "$SHA1" >/dev/null
  eq "C1.rule.$1" "$(tail -n1 "$T/rp.md")" "$3"
}
rule owns1-h2 '[{"owns":["a.sh"],"body":"x\n## Acceptance tests\n- t\n## Observable outcome\no"}]' "Section: complete"
rule owns2-h3 '[{"owns":["a.sh","b.sh"],"body":"x\n### Acceptance tests\n- t\n### Observable outcome\no"}]' "Section: complete"
rule owns-empty '[{"owns":[],"body":"x\n## Acceptance tests\n## Observable outcome"}]' "Section: incomplete (no owns list)"
rule owns-missing '[{"body":"x\n## Acceptance tests\n## Observable outcome"}]' "Section: incomplete (no owns list)"
rule prose-only '[{"owns":["a.sh"],"body":"the acceptance tests are below\n## Observable outcome\no"}]' "Section: incomplete (no Acceptance tests heading)"
rule singular '[{"owns":["a.sh"],"body":"## Acceptance test\n## Observable outcome"}]' "Section: incomplete (no Acceptance tests heading)"
rule level4 '[{"owns":["a.sh"],"body":"#### Acceptance tests\n## Observable outcome"}]' "Section: incomplete (no Acceptance tests heading)"
rule no-outcome '[{"owns":["a.sh"],"body":"## Acceptance tests\n- t"}]' "Section: incomplete (no Observable outcome heading)"
rule no-spec "" "Section: incomplete (no spec entry)"
rule no-entry '[]' "Section: incomplete (no spec entry)"
mkpack "$T/rp.md"; printf '\nSection: complete (x)\n' >> "$T/rp.md"
cpk_complete "$T/rp.md" && bad "C1: 'Section: complete (x)' was read as complete" || ok
mkpack "$T/rp.md"; printf 'Section: complete\n' >> "$T/rp.md"; sed -i 's/^the body$//' "$T/rp.md"
cpk_complete "$T/rp.md" && bad "C1: an empty child scope was read as complete" || ok

# C1 the pack cap: never over CP_MAX_BYTES, cp_compose's bytes always the prefix
BASEB=$(wc -c < "$T/composed1.md")
LEVELS=""
for extra in 0 60 160 260 400 100000; do
  cp "$T/composed1.md" "$T/cap.md"
  CP_MAX_BYTES=$((BASEB + extra)) cpk_extend "$T/cap.md" "$T/spec.json" 0 "$T/children.txt" "$T/parent-plan.md" "$SHA1" >/dev/null
  SZ=$(wc -c < "$T/cap.md")
  [ "$SZ" -le $((BASEB + extra)) ] && ok || bad "C1.cap: $SZ bytes over a cap of $((BASEB + extra))"
  cmp -s "$T/composed1.md" <(head -c "$BASEB" "$T/cap.md") && ok || bad "C1.cap: prefix changed at +$extra"
  if [ "$SZ" = "$BASEB" ]; then LEVELS="${LEVELS}none,"
  elif grep -q '^omitted: siblings (pack cap)$' "$T/cap.md"; then LEVELS="${LEVELS}nosib,"
  elif grep -q '^- bin/a.sh$' "$T/cap.md"; then LEVELS="${LEVELS}bare,"
  else LEVELS="${LEVELS}full,"; fi
done
case "$LEVELS" in none,*full,) ok ;; *) bad "C1.cap: levels $LEVELS" ;; esac
has C1.cap.nosib nosib "$LEVELS"; has C1.cap.bare bare "$LEVELS"

# C1 the production entry point: the REAL bin/run-decompose.sh, issues-lane dry run
H="$T/hd"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" scoutish || exit 1
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
printf 'scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 192.0.2.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\necho call >> "$AGENT_LOG"\nexit 0\n' > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\necho ghs_fresh\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
B1c="$T/b1c"; mkdir -p "$B1c"
cp "$T/spec.json" "$B1c/children.json"; cp "$T/parent-plan.md" "$B1c/plan.md"; cp "$T/planned-files.txt" "$B1c/planned-files.txt"
( cd "$R1" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_LOG="$T/agent.log" PATH="$T/fakebin:$PATH" \
    GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh" DECOMPOSE_DRY_RUN=1 \
    "$DIR/bin/run-decompose.sh" scoutish 552 TK-552 "$B1c" 300 12 ) > "$T/c1c.out" 2>&1 </dev/null
C1RC=$?; [ "$C1RC" = 0 ] || { cat "$T/c1c.out"; cat "$B1c/pipeline.log" "$B1c/decompose-run.txt"; }
eq C1.real.rc "$C1RC" 0
eq C1.real.packs "$(ls "$B1c/context-packs" 2>/dev/null | paste -sd, -)" "TK-553.md,TK-554.md,TK-555.md"
eq C1.real.last1 "$(tail -n1 "$B1c/context-packs/TK-553.md" 2>/dev/null)" "Section: complete"
eq C1.real.last3 "$(tail -n1 "$B1c/context-packs/TK-555.md" 2>/dev/null)" "Section: incomplete (no owns list)"
has C1.real.sib "- TK-554 (2 of 3): bin/b.sh, lib/dir/" "$(cat "$B1c/context-packs/TK-553.md" 2>/dev/null)"
has C1.real.sha "Read at: $SHA1" "$(cat "$B1c/context-packs/TK-553.md" 2>/dev/null)"

# ============================================================================
# C2. the child's plan prompt: the rule rides; a non-child is byte-identical
# ============================================================================
blk "$RB" "# >>> context pack (BH-3478)" "# <<< context pack" > "$T/cp-block.sh"
blk "$RB" "# >>> plan prompt" "# <<< plan prompt" > "$T/prompt-block.sh"
[ -s "$T/cp-block.sh" ] && [ -s "$T/prompt-block.sh" ] && ok || bad "C2: could not extract the blocks"
H2="$T/h2"; mkdir -p "$H2/bin/lib"
cp "$LIB" "$H2/bin/lib/child-pack.sh"
# The real context-pack lib with cp_fetch replaced: STUB_CP 0 copies $CPK_FIXTURE, 2 no row, else 1.
{ cat "$DIR/bin/lib/context-pack.sh"; cat <<'EOF'
cp_fetch() {
  echo "$*" >> "$T/cp-calls"
  case "${STUB_CP:-2}" in
    0) cp "$CPK_FIXTURE" "$3"; echo "${CPK_PARENT:-BH-100}" > "$3.parent"; return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}
EOF
} > "$H2/bin/lib/context-pack.sh"
cat > "$T/c2-drive.sh" <<'EOF'
set -uo pipefail
STAMP() { echo TS; }
CC() { printf '%s' "$5" > "$T/cc.prompt"; return 0; }
PROJECT=cromford KEY=BH-101 TICKET=101 BUILD="$T/b2" PLAN_MODEL=model-plan
PLAN_AMBIGUITY_RULE=AMBIG KIND_HINT_LINE= CARRIED_NOTE_LINE=
. "$SPLIB" || exit 9
for f in "$@"; do . "$f"; done
EOF
c2run() { # c2run [VAR=val...] -- blocks...
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  rm -rf "$T/b2" "$T/cc.prompt" "$T/cp-calls"; mkdir -p "$T/b2"; : > "$T/b2/pipeline.log"
  env -u CP_PARENT -u CP_PREAMBLE -u CPK_ADOPT -u CPK_FETCH_RC HARNESS="$H2" T="$T" SPLIB="$DIR/bin/lib/stage-prompt.sh" \
    WT="$R1" BASE=main JOBS_URL= ${e[@]+"${e[@]}"} bash "$T/c2-drive.sh" "$@" > "$T/c2.out" 2>&1
}
c2run -- "$T/prompt-block.sh"; cp "$T/cc.prompt" "$T/baseline.prompt"
[ -s "$T/baseline.prompt" ] && ok || bad "C2: no baseline prompt ($(cat "$T/c2.out"))"
gitc "$R1" update-ref refs/remotes/origin/main HEAD
c2run STUB_CP=0 CPK_FIXTURE="$P1" -- "$T/cp-block.sh" "$T/prompt-block.sh"
PR=$(cat "$T/cc.prompt" 2>/dev/null)
has C2.pack "- bin/a.sh :: - \`bin/a.sh\` — adds the A step" "$PR"
has C2.rule "THE PACK IS THE SURVEY." "$PR"
has C2.changed "CHANGED SINCE THE PACK (${SHA1:0:12}): none" "$PR"
hasnt C2.no-adopt-line "YOUR DRAFT PLAN IS THE CHILD SCOPE SECTION ABOVE." "$PR"
grep -qF "$(cat "$T/baseline.prompt")" "$T/cc.prompt" && ok || bad "C2: the baseline prompt does not follow intact"
c2run STUB_CP=0 CPK_FIXTURE="$P1" CPK_ADOPT=1 -- "$T/cp-block.sh" "$T/prompt-block.sh"
has C2.adopt-line "YOUR DRAFT PLAN IS THE CHILD SCOPE SECTION ABOVE." "$(cat "$T/cc.prompt" 2>/dev/null)"
# not a child: no row, an outage, an inherited CPK_FETCH_RC... all byte-identical
for s in 2 1; do
  c2run STUB_CP=$s -- "$T/cp-block.sh" "$T/prompt-block.sh"
  cmp -s "$T/cc.prompt" "$T/baseline.prompt" && ok || bad "C2: a non-child prompt (STUB_CP=$s) differs from the baseline"
done
# a pack that predates BH-9537 (no File map): the rule is not added
printf '## parent map\nbin/x.sh\n' > "$T/oldpack.md"
c2run STUB_CP=0 CPK_FIXTURE="$T/oldpack.md" -- "$T/cp-block.sh" "$T/prompt-block.sh"
hasnt C2.old-pack "THE PACK IS THE SURVEY." "$(cat "$T/cc.prompt" 2>/dev/null)"

# ============================================================================
# C3. the adopt arm: CHILD only on a MISS with a complete section
# ============================================================================
blk "$RB" "# >>> child section adopt (BH-9537)" "# <<< child section adopt" > "$T/c3-csa.sh"
blk "$RB" "# >>> preplan adopt" "# <<< preplan adopt" > "$T/c3-adopt.sh"
blk "$RB" "# >>> preplan outcome event (BH-2543)" "# <<< preplan outcome event" > "$T/c3-event.sh"
[ -s "$T/c3-csa.sh" ] && ok || bad "C3: could not extract the child section adopt block"
L_CSA=$(grep -n -x '# >>> child section adopt (BH-9537)' "$RB" | head -1 | cut -d: -f1)
L_PA=$(grep -n -x '# >>> preplan adopt' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_CSA" ] && [ -n "$L_PA" ] && [ "$((L_CSA))" -lt "$L_PA" ] && ok || bad "C3: child section adopt must sit before preplan adopt ($L_CSA, $L_PA)"
H3="$T/h3"; mkdir -p "$H3/bin/lib" "$H3/plans" "$H3/env"
: > "$H3/env/global.env"
cp "$LIB" "$H3/bin/lib/child-pack.sh"; cp "$H2/bin/lib/context-pack.sh" "$H3/bin/lib/"
cp "$DIR/bin/size-scope.sh" "$H3/bin/" 2>/dev/null
# The real pre-plan lib; the coordination DB answers through a stub (STUB_PC 1 =
# no client, STUB_PF = preplan_fetch's rc).
{ cat "$DIR/bin/lib/preplan-lib.sh"; cat <<'EOF'
_preplan_client() { [ "${STUB_PC:-0}" = 0 ]; }
preplan_fetch() { return "${STUB_PF:-1}"; }
EOF
} > "$H3/bin/lib/preplan-lib.sh"
R3="$T/repo3"; mkdir -p "$R3/src"
gitc "$R3" init -q -b main; echo a > "$R3/src/pay.ts"; gitc "$R3" add -A; gitc "$R3" commit -qm one
BASE3=$(git -C "$R3" rev-parse main)
FP_NOW='2026-11-24T12:00:00Z|x||4'
mkplan() { # mkplan <ticket-fp> — a hub pre-plan for AB-1
  scratch_rm "$H3/plans/proj-AB-1"; mkdir -p "$H3/plans/proj-AB-1"
  printf '## Scope\nTouch src/pay.ts.\nSIZE: S\n' > "$H3/plans/proj-AB-1/plan.md"
  printf '%s\n' "$BASE3" > "$H3/plans/proj-AB-1/base-sha"
  printf 'src/pay.ts\n' > "$H3/plans/proj-AB-1/planned-files.txt"
  printf 'AB-1\n' > "$H3/plans/proj-AB-1/key"
  printf '%s\n' "$1" > "$H3/plans/proj-AB-1/ticket-fp"
}
cat > "$T/c3-drive.sh" <<'EOF'
HARNESS="$H3"; PROJECT=proj; KEY=AB-1; WT="$R3"; BASE=main; FP_BEFORE="$FP_NOW"; PLAN_MODEL=model-plan; JOB_ID=7
STAMP() { printf 'TS'; }
BB() { :; }
job_event() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$BUILD/events"; return 0; }
for f in "$@"; do . "$f"; done
echo after > "$BUILD/after"
EOF
N3=0
c3() { # c3 <pack: complete|incomplete|none> [VAR=val...]  -> $B3
  local pk="$1"; shift
  N3=$((N3 + 1)); B3="$T/b3-$N3"; mkdir -p "$B3"; : > "$B3/pipeline.log"; rm -f "$T/cp-calls"
  case "$pk" in complete) set -- STUB_CP=0 CPK_FIXTURE="$P1" "$@" ;; incomplete) set -- STUB_CP=0 CPK_FIXTURE="$P3" "$@" ;; none) set -- STUB_CP=2 "$@" ;; esac
  [ -n "${SEED_AMEND:-}" ] && echo "amended" > "$B3/replan-amendment.md"
  [ -n "${SEED_RESUME:-}" ] && { echo '# plan' > "$B3/plan.md"; printf '%s\n' "$SEED_RESUME" > "$B3/preplan-outcome"; cp "$P1" "$B3/context-pack.md"; echo BH-100 > "$B3/context-pack.md.parent"; }
  env -u CPK_ADOPT -u CPK_FETCH_RC -u CP_PARENT -u CP_PREAMBLE H3="$H3" R3="$R3" FP_NOW="$FP_NOW" T="$T" BUILD="$B3" \
    PREPLAN_RELAY_DIR="$T/relay-none" "$@" \
    bash "$T/c3-drive.sh" "$T/c3-csa.sh" "$T/c3-adopt.sh" "$T/c3-event.sh" "$T/cp-block.sh" > "$T/c3.out" 2>&1
}
oc() { head -n1 "$B3/preplan-outcome" 2>/dev/null; }
pplines() { grep -cE 'PREPLAN_(HIT|STALE|MISS|OFF|CHILD)' "$B3/pipeline.log"; }
fetches() { grep -c . "$T/cp-calls" 2>/dev/null || echo 0; }

scratch_rm "$H3/plans/proj-AB-1"
c3 complete
case "$(oc)" in "CHILD parent section of BH-100 adopted as the draft") ok ;; *) bad "C3 complete: outcome [$(oc)] ($(cat "$T/c3.out"))" ;; esac
eq C3.one-line "$(pplines)" 1
grep -q 'PREPLAN_CHILD adopted the parent section of BH-100 as the draft' "$B3/pipeline.log" && ok || bad "C3: no PREPLAN_CHILD line: $(cat "$B3/pipeline.log")"
eq C3.no-miss "$(grep -c PREPLAN_MISS "$B3/pipeline.log")" 0
[ ! -e "$B3/plan.md" ] && ok || bad "C3: an adopted section must not be written to plan.md"
eq C3.event "$(cat "$B3/events" 2>/dev/null)" "7 preplan CHILD"
eq C3.one-get "$(fetches)" 1
grep -q 'CHILD_PLAN parent=BH-100' "$B3/pipeline.log" && ok || bad "C3: context pack block did not take the child arm"
[ -s "$B3/after" ] && ok || bad "C3: code after the blocks did not run"
for v in "STUB_PF=2" "STUB_PC=1"; do
  c3 complete "$v"
  case "$(oc)" in CHILD*) ok ;; *) bad "C3 complete with $v: outcome [$(oc)]" ;; esac
done
# incomplete section -> MISS, and the child plans on the child route as today
c3 incomplete
case "$(oc)" in MISS*) ok ;; *) bad "C3 incomplete: outcome [$(oc)]" ;; esac
eq C3.inc.lines "$(pplines)" 1
grep -q PREPLAN_MISS "$B3/pipeline.log" && ok || bad "C3 incomplete: no PREPLAN_MISS"
grep -q 'CHILD_PLAN parent=BH-100' "$B3/pipeline.log" && ok || bad "C3 incomplete: no CHILD_PLAN parent= line"
eq C3.inc.event "$(cat "$B3/events" 2>/dev/null)" "7 preplan MISS"
# not a child: one GET, MISS, CHILD_PLAN none
c3 none
case "$(oc)" in MISS*) ok ;; *) bad "C3 none: outcome [$(oc)]" ;; esac
eq C3.none.one-get "$(fetches)" 1
grep -q 'CHILD_PLAN none (no context pack)' "$B3/pipeline.log" && ok || bad "C3 none: $(cat "$B3/pipeline.log")"
# a real pre-plan wins: HIT
mkplan "$FP_NOW"; c3 complete
case "$(oc)" in HIT*) ok ;; *) bad "C3 HIT: outcome [$(oc)]" ;; esac
[ -s "$B3/plan.md" ] && ok || bad "C3 HIT: plan.md not adopted"
eq C3.hit.lines "$(pplines)" 1
# a thread-stale pre-plan stays STALE
mkplan 'older|x||1'; c3 complete
case "$(oc)" in STALE*) ok ;; *) bad "C3 STALE: outcome [$(oc)]" ;; esac
scratch_rm "$H3/plans/proj-AB-1"
# OFF stays OFF
c3 complete PREPLAN_SPECULATIVE=0
case "$(oc)" in OFF*) ok ;; *) bad "C3 OFF: outcome [$(oc)]" ;; esac
# replan-amended stays MISS
SEED_AMEND=1 c3 complete
case "$(oc)" in "MISS replan amended"*) ok ;; *) bad "C3 amended: outcome [$(oc)]" ;; esac
# resumed: the outcome stands, no early fetch
SEED_RESUME="CHILD parent section of BH-100 adopted as the draft" c3 complete
eq C3.resume.outcome "$(oc)" "CHILD parent section of BH-100 adopted as the draft"
grep -q 'PREPLAN_CHILD resumed dir already carries a plan' "$B3/pipeline.log" && ok || bad "C3 resume: $(cat "$B3/pipeline.log")"
eq C3.resume.no-fetch "$(fetches)" 0
SEED_RESUME="MISS no pre-plan" c3 complete
case "$(oc)" in MISS*) ok ;; *) bad "C3 resume MISS: outcome [$(oc)]" ;; esac
# a pack whose parent is the key itself never adopts
c3 complete CPK_PARENT=AB-1
case "$(oc)" in MISS*) ok ;; *) bad "C3 self-parent: outcome [$(oc)]" ;; esac
# no child-pack lib on the box: today's path
mv "$H3/bin/lib/child-pack.sh" "$T/parked-cpk.sh"; c3 complete
case "$(oc)" in MISS*) ok ;; *) bad "C3 no lib: outcome [$(oc)]" ;; esac
mv "$T/parked-cpk.sh" "$H3/bin/lib/child-pack.sh"

# ============================================================================
# C4. changed since the pack
# ============================================================================
R4="$T/repo4"; mkdir -p "$R4/bin" "$R4/lib/dir"
gitc "$R4" init -q -b main
echo a > "$R4/bin/a.sh"; echo b > "$R4/bin/b.sh"; echo x > "$R4/lib/dir/x.sh"; echo o > "$R4/other.sh"
gitc "$R4" add -A; gitc "$R4" commit -qm A; SHA_A=$(git -C "$R4" rev-parse HEAD)
echo a2 > "$R4/bin/a.sh"; echo o2 > "$R4/other.sh"; gitc "$R4" commit -qam B
gitc "$R4" update-ref refs/remotes/origin/main HEAD
mk4() { printf '## Child scope\nbody\n\n## Parent file inventory\nx\n\n## File map\nRead at: %s\n- bin/a.sh :: row\n- bin/b.sh :: row\n- lib/dir/ :: row\n\n## Siblings\n\nSection: complete\n' "$1" > "$T/p4.md"; }
mk4 "$SHA_A"
eq C4.listed "$(cpk_changed "$T/p4.md" "$R4" origin/main | paste -sd, -)" "bin/a.sh"
OUT4=$(cpk_rule "$T/p4.md" "$R4" origin/main 0)
has C4.rule "CHANGED SINCE THE PACK (${SHA_A:0:12}): bin/a.sh" "$OUT4"
hasnt C4.unlisted other.sh "$OUT4"
echo x2 > "$R4/lib/dir/x.sh"; gitc "$R4" commit -qam C; gitc "$R4" update-ref refs/remotes/origin/main HEAD
eq C4.dir "$(cpk_changed "$T/p4.md" "$R4" origin/main | paste -sd, -)" "bin/a.sh,lib/dir/"
mk4 0123456789abcdef0123456789abcdef01234567
eq C4.unreachable "$(cpk_changed "$T/p4.md" "$R4" origin/main | paste -sd, -)" "bin/a.sh (unverifiable),bin/b.sh (unverifiable),lib/dir/ (unverifiable)"
hasnt C4.never-none "): none" "$(cpk_rule "$T/p4.md" "$R4" origin/main 0)"
# the prompt names the change (the C2 blocks, WT on the moved repo)
mk4 "$SHA_A"; c2run STUB_CP=0 CPK_FIXTURE="$T/p4.md" WT="$R4" -- "$T/cp-block.sh" "$T/prompt-block.sh"
has C4.prompt "CHANGED SINCE THE PACK (${SHA_A:0:12}): bin/a.sh, lib/dir/" "$(cat "$T/cc.prompt" 2>/dev/null)"

# ============================================================================
# C5. the pack comes home to the hub
# ============================================================================
(
  . "$DIR/bin/lib/pool-record.sh"
  grep -qx context-pack.md < <(printf '%s\n' "${POOL_RECORD_FILES[@]}")
) && ok || bad "C5: context-pack.md is not in POOL_RECORD_FILES"
grep -qw 'context-pack\.md' <<<"$(awk '/^      for A in plan\.md /{f=1} f{print} f&&/; do$/{exit}' "$DIR/bin/fly-pool.sh")" \
  && ok || bad "C5: the fly-pool.sh pull list does not name context-pack.md"
H5="$T/h5"; mkdir -p "$H5/bin" "$T/c5"
cp "$DIR/bin/result-prefix-ok.sh" "$H5/bin/" && chmod +x "$H5/bin/result-prefix-ok.sh"
BD5="$T/c5/proj-BH-101-202611241500"; mkdir -p "$BD5"
cp "$P1" "$BD5/context-pack.md"; printf '# plan\n' > "$BD5/plan.md"
printf 'PR_CREATED https://github.com/o/r/pull/9\nBUILD_DIR: /data/harness/builds/proj-BH-101-202611241500\n' > "$T/c5/RESULT"
(
  export HARNESS="$H5" TMPDIR="$T/c5"
  _jobs_req_file() { cp "$3" "$T/c5/posted.json"; return 0; }
  . "$DIR/bin/lib/pool-record.sh"
  pool_record_put proj BH-101 m1 "$T/c5/RESULT" "$BD5" "" || exit 1
  jq -c '{record:{build_dir, machine:"m1", files:[.files[] | {name, body:(.b64 // null), skipped:(if .skipped then 1 else 0 end)}]}}' \
    "$T/c5/posted.json" > "$T/c5/answer.json"
  _jobs_req() { cat "$T/c5/answer.json"; return 0; }
  INFO=$(pool_record_get proj BH-101 m1 "2026-11-24 15:00:00Z" "$T/c5/stage") || exit 2
  mkdir -p "$T/c5/hub"
  pool_record_install "$T/c5/stage" "$T/c5/hub" m1 stopped "$INFO" >/dev/null || exit 3
) > "$T/c5.out" 2>&1
eq C5.roundtrip.rc "$?" 0
cmp -s "$BD5/context-pack.md" "$T/c5/hub/context-pack.md" && ok || bad "C5: the hub copy of context-pack.md is not byte-equal ($(cat "$T/c5.out"))"

# ============================================================================
# C6. tokens on the tripwire line
# ============================================================================
blk "$RB" "# >>> child plan tripwire" "# <<< child plan tripwire" > "$T/tw-block.sh"
[ -s "$T/tw-block.sh" ] && ok || bad "C6: could not extract the tripwire block"
H6="$T/h6"; mkdir -p "$H6/bin/lib"
cp "$DIR/bin/lib/context-pack.sh" "$LIB" "$H6/bin/lib/"
printf 'cpt_check() { echo "OK 1.00 6.43 15.6 50"; }\n' > "$H6/bin/lib/child-plan-tripwire.sh"
cat > "$T/c6-drive.sh" <<'EOF'
set -uo pipefail
STAMP() { echo TS; }
_jobs_req() {
  echo "$1 $2" >> "$T/c6-calls"
  [ "${STUB_FAIL:-0}" = 1 ] && return 1
  case "$2" in
    *"ticket=BH-100&stage=preplan"*) printf '{"cost_rows":[{"stage":"preplan","cache_read":125088,"output_toks":1000}]}' ;;
    *"ticket=BH-100&stage=plan"*)    printf '{"cost_rows":[{"stage":"plan","cache_read":600000,"output_toks":2000},{"stage":"plan","cache_read":"400000","output_toks":500}]}' ;;
    *) printf '{"cost_rows":[]}' ;;
  esac
}
. "$1"
echo "$?" > "$T/c6-rc"
echo after > "$T/c6-after"
EOF
c6() {
  rm -rf "$T/b6" "$T/c6-"{calls,rc,after}; mkdir -p "$T/b6"; : > "$T/b6/pipeline.log"
  printf 'pack\n' > "$T/b6/context-pack.md"; echo BH-100 > "$T/b6/context-pack.md.parent"
  printf 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd\n' > "$T/b6/cost.csv"
  [ -n "${C6_NO_CHILD_ROWS:-}" ] || printf '1,h,proj,plan,claude,m,0,10,5,700,3000000,0,1.0\n1,h,proj,plan,claude,m,0,10,5,300,366348,0,1.0\n' >> "$T/b6/cost.csv"
  printf '1,h,proj,execute,claude,m,0,10,5,9,999999,0,1.0\n' >> "$T/b6/cost.csv"
  env -u CP_PARENT HARNESS="$H6" PROJECT=proj KEY=BH-101 BUILD="$T/b6" T="$T" "$@" bash "$T/c6-drive.sh" "$T/tw-block.sh" > "$T/c6.out" 2>&1
}
c6
eq C6.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b6/pipeline.log")" "TS [proj/BH-101] CHILD_PLAN_TRIPWIRE OK 1.00 6.43 15.6 50 tokens child=3366348 parent=1125088 ratio=2.99 out=1000/3500"
eq C6.rc "$(cat "$T/c6-rc" 2>/dev/null)" 0; [ -s "$T/c6-after" ] && ok || bad "C6: code after the block did not run"
c6 STUB_FAIL=1
eq C6.fail.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b6/pipeline.log")" "TS [proj/BH-101] CHILD_PLAN_TRIPWIRE OK 1.00 6.43 15.6 50 tokens UNMEASURED BH-100 preplan read failed"
eq C6.fail.rc "$(cat "$T/c6-rc" 2>/dev/null)" 0; [ -s "$T/c6-after" ] && ok || bad "C6 fail: code after the block did not run"
# no plan row for the child in cost.csv or on the worker: UNMEASURED, never child=0
C6_NO_CHILD_ROWS=1 c6
eq C6.nochild "$(grep CHILD_PLAN_TRIPWIRE "$T/b6/pipeline.log")" "TS [proj/BH-101] CHILD_PLAN_TRIPWIRE OK 1.00 6.43 15.6 50 tokens UNMEASURED no child plan rows"
grep -q 'ticket=BH-101&stage=plan' "$T/c6-calls" && ok || bad "C6: the worker was not asked for the child's plan rows"
# a parent with no plan spend is no baseline, never ratio=inf
printf 'cpt_check() { echo OK; }\n' > "$H6/bin/lib/child-plan-tripwire.sh"
sed -i 's/ticket=BH-100&stage=preplan/ticket=NOPE/; s/ticket=BH-100&stage=plan/ticket=NOPE2/' "$T/c6-drive.sh"
c6
eq C6.nobase "$(grep CHILD_PLAN_TRIPWIRE "$T/b6/pipeline.log")" "TS [proj/BH-101] CHILD_PLAN_TRIPWIRE OK tokens UNMEASURED no parent baseline"
# no child-pack lib: the line is today's
rm -f "$H6/bin/lib/child-pack.sh"; c6
eq C6.no-lib "$(grep CHILD_PLAN_TRIPWIRE "$T/b6/pipeline.log")" "TS [proj/BH-101] CHILD_PLAN_TRIPWIRE OK"

echo "child-plan-from-parent.bh-9537: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
