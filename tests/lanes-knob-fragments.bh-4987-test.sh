#!/bin/bash
# tests/lanes-knob-fragments.bh-4987-test.sh — a NEW lane knob is its own file.
#
# WHY. Every new knob was appended to the one `knobs` array of a lane file in
# catalog/lanes.d/, so two builds that each added a knob to the same lane both
# edited its last element and git called it a conflict. A new knob now lands as
# catalog/lanes.d/<owner>.knobs.d/<ENV>.json (owner = a lane id, or _lib.<id>),
# and bin/lanes-build.sh appends it to the owner's `knobs`.
#
# What is proved here, over scratch trees with the real scripts:
#   K1 a fragment lands at the end of its lane's knobs, and lane_knob (through
#      lanes_json_path) answers its default;
#   K2 moving the LAST inline knob of 3 lanes (ones with no knobs.d yet) and 1
#      lib into fragments composes byte-identically, and the real tree
#      composes as main's composer does;
#   K3 a lane with no `knobs` key gets one;
#   K4 every refusal is rc 1 naming the file, and --write keeps the old render;
#   K5 a lib fragment lands in that lib's knobs in .libs;
#   K6 fragments compose in LC_ALL=C name order, deterministically;
#   K7 lanes_json_path re-renders after a SECOND fragment in an existing dir,
#      and after an edit of a fragment's contents;
#   K8 bin/config-inventory.sh reads a fragment env as ALREADY_REGISTERED;
#   K9 --check is rc 1 on a tracked catalog/lanes.json and on a bad fragment;
#   M1 two branches that each add a fragment merge with no conflict;
#   L1..L6 bin/lanes-knob-lint.sh: an inline append on an existing lane or lib
#      is a finding; a new lane, a changed default, a move to a fragment and a
#      fork that predates the lint are not; a bad --base or a lane file that
#      does not parse is rc 2.
# Run from anywhere: tests/lanes-knob-fragments.bh-4987-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

KNOB() { # KNOB <ENV> <default> — one knob object, the shape the lane files use
  printf '{"env":"%s","type":"int","default":%s,"min":0,"max":100,"unit":null,"zero_means":null,"note":"fixture"}\n' "$1" "$2"
}

# A scratch repo with the real composer and loader and a copy of the REAL lanes.d.
R="$T/repo"
mkdir -p "$R/catalog"
scratch_install_closure bin/lanes-build.sh "$R" >/dev/null || exit 1
scratch_install_closure bin/lib/lanes-registry.sh "$R" >/dev/null || exit 1
scratch_install_closure bin/lib/lane-gate.sh "$R" >/dev/null || exit 1
cp -R "$DIR/catalog/lanes.d" "$R/catalog/" || exit 1
L="$R/catalog/lanes.d"

RC=0
build() { # build [args] -> stdout in $T/out, stderr in $T/err, rc in $RC
  bash "$R/bin/lanes-build.sh" --root "$R" "$@" > "$T/out" 2> "$T/err"; RC=$?
}
lane_envs() { jq -c --arg id "$1" '.lanes[]|select(.id==$id)|.knobs|map(.env)' "$T/out" 2>/dev/null; }
lib_envs()  { jq -c --arg id "$1" '.libs[]|select(.id==$id)|.knobs|map(.env)' "$T/out" 2>/dev/null; }

# ── K2 first, on the untouched copy: no fragments = today's bytes ────────────
build
[ "$RC" = 0 ] && ok || bad "K2 the real tree must compose: rc=$RC $(cat "$T/err")"
cp "$T/out" "$T/A.json"
if git -C "$DIR" cat-file -e origin/main:bin/lanes-build.sh 2>/dev/null; then
  git -C "$DIR" show origin/main:bin/lanes-build.sh > "$T/lb-main.sh"
  bash "$T/lb-main.sh" --root "$R" > "$T/main.json" 2>/dev/null
  cmp -s "$T/main.json" "$T/A.json" && ok || bad "K2 the real tree must compose as main's composer does: $(diff "$T/main.json" "$T/A.json" | head -5)"
else
  echo "K2: origin/main not resolvable here — main-composer comparison skipped"
fi
# Move the LAST inline knob of three lanes and one lib into fragments.
# The lanes must have no <id>.knobs.d yet: fragments compose in C name order
# after the inline knobs, so a moved knob that sorts after a lane's existing
# fragment would land after it and change the bytes (BH-6433 gave
# merge-conductor its first fragment). Prefer the named lanes, then any other.
B="$T/b"; mkdir -p "$B/catalog"; cp -R "$L" "$B/catalog/"; cp -R "$R/bin" "$B/"
K2_IDS=$(for id in review-prs merge-conductor alert-triage \
           $(cd "$L" && ls *.json | sed -n '/^_lib/!s/\.json$//p' | LC_ALL=C sort); do
           [ -d "$L/$id.knobs.d" ] && continue
           jq -e '(.knobs // []) | length > 0' "$L/$id.json" >/dev/null 2>&1 && echo "$id"
         done | awk '!seen[$0]++' | head -3)
[ "$(printf '%s\n' "$K2_IDS" | grep -c .)" = 3 ] && ok || bad "K2 needs 3 lanes with inline knobs and no knobs.d: '$K2_IDS'"
for id in $K2_IDS; do
  f="$B/catalog/lanes.d/$id.json"
  env=$(jq -r '.knobs[-1].env' "$f")
  mkdir -p "$B/catalog/lanes.d/$id.knobs.d"
  jq '.knobs[-1]' "$f" > "$B/catalog/lanes.d/$id.knobs.d/$env.json"
  jq 'del(.knobs[-1])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
lf="$B/catalog/lanes.d/_lib.call-guard.json"
lid=$(jq -r '.libs[0].id' "$lf"); env=$(jq -r '.libs[0].knobs[-1].env' "$lf")
mkdir -p "$B/catalog/lanes.d/_lib.$lid.knobs.d"
jq '.libs[0].knobs[-1]' "$lf" > "$B/catalog/lanes.d/_lib.$lid.knobs.d/$env.json"
jq 'del(.libs[0].knobs[-1])' "$lf" > "$lf.tmp" && mv "$lf.tmp" "$lf"
bash "$B/bin/lanes-build.sh" --root "$B" > "$T/B.json" 2> "$T/Berr"; rc=$?
[ "$rc" = 0 ] && ok || bad "K2 moved-knob tree must compose: rc=$rc $(cat "$T/Berr")"
cmp -s "$T/A.json" "$T/B.json" && ok || bad "K2 moving last knobs to fragments must be byte-identical: $(diff "$T/A.json" "$T/B.json" | head -8)"

# ── K1: a fragment lands last, and lane_knob reads it ────────────────────────
mkdir -p "$L/review-prs.knobs.d"
KNOB BH4987_A 7 > "$L/review-prs.knobs.d/BH4987_A.json"
build
[ "$RC" = 0 ] && ok || bad "K1 rc=$RC $(cat "$T/err")"
[ "$(jq -r '.lanes[]|select(.id=="review-prs")|.knobs[-1].env' "$T/out" 2>/dev/null)" = BH4987_A ] \
  && ok || bad "K1 BH4987_A must be the last review-prs knob: $(lane_envs review-prs)"
n_main=$(jq '.lanes[]|select(.id=="review-prs")|.knobs|length' "$T/A.json")
n_now=$(jq '.lanes[]|select(.id=="review-prs")|.knobs|length' "$T/out")
[ "$n_now" = $((n_main + 1)) ] && ok || bad "K1 review-prs knobs: want $((n_main + 1)), got $n_now"
cat > "$T/stub.sh" <<'SH'
_jobs_req() { printf '{"settings":[]}'; }
SH
mkdir -p "$R/state" "$R/logs" "$R/flags"
got=$(env -u LANE_REGISTRY BH4987_A= HARNESS="$R" bash -c '
  set -uo pipefail
  . "$1"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_knob review-prs BH4987_A' _ "$T/stub.sh" 2>/dev/null)
[ "$got" = 7 ] && ok || bad "K1 lane_knob review-prs BH4987_A must read the fragment default 7, got '$got'"

# ── K3: a lane with no knobs key ─────────────────────────────────────────────
# Every real lane carries a knobs key, so this is a fixture lane without one.
printf '{"id":"bh4987-noknobs","script":"bin/none.sh"}\n' > "$L/bh4987-noknobs.json"; nok=bh4987-noknobs
mkdir -p "$L/$nok.knobs.d"; KNOB BH4987_NK 1 > "$L/$nok.knobs.d/BH4987_NK.json"
build
[ "$RC" = 0 ] && ok || bad "K3 rc=$RC $(cat "$T/err")"
[ "$(lane_envs "$nok")" = '["BH4987_NK"]' ] && ok || bad "K3 $nok knobs: $(lane_envs "$nok")"
scratch_rm "$L/$nok.knobs.d"; scratch_rm "$L/bh4987-noknobs.json"

# ── K5: a lib fragment ───────────────────────────────────────────────────────
mkdir -p "$L/_lib.caller-check.knobs.d"
KNOB BH4987_LIB 2 > "$L/_lib.caller-check.knobs.d/BH4987_LIB.json"
build
[ "$RC" = 0 ] && ok || bad "K5 rc=$RC $(cat "$T/err")"
[ "$(jq -r '.libs[]|select(.id=="caller-check")|.knobs[-1].env' "$T/out" 2>/dev/null)" = BH4987_LIB ] \
  && ok || bad "K5 caller-check lib knobs: $(lib_envs caller-check)"
[ "$(jq '[.lanes[]|select(.id=="_lib.caller-check")]|length' "$T/out")" = 0 ] && ok || bad "K5 a lib fragment must not make a lane"
lid_main=$(jq -r '.libs[0].id' "$L/_lib.json")
mkdir -p "$L/_lib.$lid_main.knobs.d"; KNOB BH4987_LIB0 3 > "$L/_lib.$lid_main.knobs.d/BH4987_LIB0.json"
build
[ "$(jq -r --arg id "$lid_main" '.libs[]|select(.id==$id)|.knobs[-1].env' "$T/out" 2>/dev/null)" = BH4987_LIB0 ] \
  && ok || bad "K5 a fragment for a lib in _lib.json: $(lib_envs "$lid_main")"
scratch_rm "$L/_lib.$lid_main.knobs.d"

# ── K6: LC_ALL=C order, deterministic ────────────────────────────────────────
KNOB B_A 1 > "$L/review-prs.knobs.d/B_A.json"
KNOB BA 1  > "$L/review-prs.knobs.d/BA.json"
KNOB A_Z 1 > "$L/review-prs.knobs.d/A_Z.json"
build; cp "$T/out" "$T/k6a.json"
[ "$(jq -c '.lanes[]|select(.id=="review-prs")|.knobs[-4:]|map(.env)' "$T/out")" = '["A_Z","BA","BH4987_A","B_A"]' ] \
  && ok || bad "K6 C order: $(jq -c '.lanes[]|select(.id=="review-prs")|.knobs[-4:]|map(.env)' "$T/out")"
build
cmp -s "$T/k6a.json" "$T/out" && ok || bad "K6 two runs must give the same bytes"
rm -f "$L/review-prs.knobs.d/B_A.json" "$L/review-prs.knobs.d/BA.json" "$L/review-prs.knobs.d/A_Z.json"

# ── K4: refusals ─────────────────────────────────────────────────────────────
bash "$R/bin/lanes-build.sh" --root "$R" --write > /dev/null 2>&1
cp "$R/catalog/lanes.json" "$T/good.json"
refuse() { # refuse <label> <path-to-name> — compose and --write must be rc 1 naming it
  build
  [ "$RC" = 1 ] && ok || bad "K4 $1: want rc 1, got $RC"
  grep -qF "$2" "$T/err" && ok || bad "K4 $1: stderr must name $2: $(cat "$T/err")"
  [ "$(grep -c . "$T/err")" = 1 ] && ok || bad "K4 $1: one stderr line, got: $(cat "$T/err")"
  bash "$R/bin/lanes-build.sh" --root "$R" --write > /dev/null 2>&1
  cmp -s "$T/good.json" "$R/catalog/lanes.json" && ok || bad "K4 $1: --write must leave the old render alone"
}
mkdir -p "$L/nosuchlane.knobs.d"; KNOB X_ONE 1 > "$L/nosuchlane.knobs.d/X_ONE.json"
refuse "no owner lane" "nosuchlane.knobs.d"; scratch_rm "$L/nosuchlane.knobs.d"
mkdir -p "$L/_lib.nosuchlib.knobs.d"; KNOB X_ONE 1 > "$L/_lib.nosuchlib.knobs.d/X_ONE.json"
refuse "no owner lib" "_lib.nosuchlib.knobs.d"; scratch_rm "$L/_lib.nosuchlib.knobs.d"
KNOB a_knob 1 > "$L/review-prs.knobs.d/a_knob.json"
refuse "lower-case name" "review-prs.knobs.d/a_knob.json"; rm -f "$L/review-prs.knobs.d/a_knob.json"
KNOB Y_ENV 1 > "$L/review-prs.knobs.d/X_ENV.json"
refuse ".env differs from the name" "review-prs.knobs.d/X_ENV.json"; rm -f "$L/review-prs.knobs.d/X_ENV.json"
last=$(jq -r '.knobs[-1].env' "$L/review-prs.json")
KNOB "$last" 1 > "$L/review-prs.knobs.d/$last.json"
refuse "env already inline (the last one)" "review-prs.knobs.d/$last.json"; rm -f "$L/review-prs.knobs.d/$last.json"
echo "a readme" > "$L/review-prs.knobs.d/README"
refuse "a README in the dir" "review-prs.knobs.d/README"; rm -f "$L/review-prs.knobs.d/README"
printf '[%s]\n' "$(KNOB X_ARR 1)" > "$L/review-prs.knobs.d/X_ARR.json"
refuse "an array, not an object" "review-prs.knobs.d/X_ARR.json"; rm -f "$L/review-prs.knobs.d/X_ARR.json"
printf '{"env":"X_BAD",\n' > "$L/review-prs.knobs.d/X_BAD.json"
refuse "invalid JSON" "review-prs.knobs.d/X_BAD.json"; rm -f "$L/review-prs.knobs.d/X_BAD.json"
# A lane with no fragment dir yet: merge-conductor has one since BH-6335 (TEST-CHANGE).
NOKD=$(for f in "$L"/*.json; do b=$(basename "$f" .json); case "$b" in _*) continue ;; esac; [ -e "$L/$b.knobs.d" ] || { echo "$b"; break; }; done)
KNOB X_ONE 1 > "$L/$NOKD.knobs.d"
refuse "a file, not a dir" "$NOKD.knobs.d"; rm -f "$L/$NOKD.knobs.d"
build
[ "$RC" = 0 ] && ok || bad "K4 the tree must compose again after the refusals: $(cat "$T/err")"

# ── K7: the loader notices a SECOND fragment in an existing dir ──────────────
lr() { env -u LANE_REGISTRY bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$R" 2>/dev/null; }
p=$(lr); [ -n "$p" ] && [ -s "$p" ] && ok || bad "K7 lanes_json_path must serve a render"
p=$(lr)  # stamped now
KNOB BH4987_B 9 > "$L/review-prs.knobs.d/BH4987_B.json"
p=$(lr)
jq -e '.lanes[]|select(.id=="review-prs")|.knobs|map(.env)|index("BH4987_B")' "$p" >/dev/null 2>&1 \
  && ok || bad "K7 the second fragment must be in the served registry"
# An EDIT of a fragment changes no file name, only its contents.
KNOB BH4987_B 11 > "$L/review-prs.knobs.d/BH4987_B.json"
p=$(lr)
[ "$(jq -r '.lanes[]|select(.id=="review-prs")|.knobs[]|select(.env=="BH4987_B")|.default' "$p" 2>/dev/null)" = 11 ] \
  && ok || bad "K7 an edited fragment default must be in the served registry"
rm -f "$L/review-prs.knobs.d/BH4987_B.json"

# ── K8: config-inventory sees a fragment env as registered ───────────────────
if command -v python3 >/dev/null 2>&1; then
  FX="$T/fx"; mkdir -p "$FX/bin" "$FX/catalog/lanes.d/fx-lane.knobs.d"
  printf '{"id":"fx-lane","script":"bin/fx-lane.sh","knobs":[]}\n' > "$FX/catalog/lanes.d/fx-lane.json"
  KNOB FX_FRAG_KNOB 5 > "$FX/catalog/lanes.d/fx-lane.knobs.d/FX_FRAG_KNOB.json"
  printf '#!/bin/bash\nV="${FX_FRAG_KNOB:-5}"\nW="${FX_UNREG_KNOB:-5}"\necho "$V $W"\n' > "$FX/bin/fx-lane.sh"
  bash "$DIR/bin/config-inventory.sh" --root "$FX" --out "$T/inv" > "$T/inv.log" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok || bad "K8 config-inventory rc=$rc $(tail -3 "$T/inv.log")"
  cls() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|.class' "$T/inv/inventory.json" 2>/dev/null; }
  [ "$(cls FX_FRAG_KNOB)" = ALREADY_REGISTERED ] && ok || bad "K8 FX_FRAG_KNOB must be ALREADY_REGISTERED, got '$(cls FX_FRAG_KNOB)'"
  [ "$(cls FX_UNREG_KNOB)" != ALREADY_REGISTERED ] && ok || bad "K8 the control FX_UNREG_KNOB must not be ALREADY_REGISTERED"
else
  echo "K8: python3 missing — skipped"
fi

# ── K9: --check ──────────────────────────────────────────────────────────────
G="$T/g"; mkdir -p "$G"; cp -R "$R/bin" "$R/catalog" "$G/"
rm -f "$G/catalog/lanes.json"
printf 'catalog/lanes.json\n' > "$G/.gitignore"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@example.com -c user.name=t commit -qm base
bash "$G/bin/lanes-build.sh" --root "$G" --check > /dev/null 2> "$T/err"; rc=$?
[ "$rc" = 0 ] && ok || bad "K9 a clean tree with fragments must pass --check: $(cat "$T/err")"
KNOB X_ENV 1 > "$G/catalog/lanes.d/review-prs.knobs.d/Y_ENV.json"
bash "$G/bin/lanes-build.sh" --root "$G" --check > /dev/null 2> "$T/err"; rc=$?
[ "$rc" = 1 ] && grep -qF "Y_ENV.json" "$T/err" && ok || bad "K9 --check on a bad fragment: rc=$rc $(cat "$T/err")"
rm -f "$G/catalog/lanes.d/review-prs.knobs.d/Y_ENV.json"
bash "$G/bin/lanes-build.sh" --root "$G" --write > /dev/null 2>&1
git -C "$G" add -f catalog/lanes.json
bash "$G/bin/lanes-build.sh" --root "$G" --check > /dev/null 2> "$T/err"; rc=$?
[ "$rc" = 1 ] && grep -q "TRACKED" "$T/err" && ok || bad "K9 --check on a tracked catalog/lanes.json: rc=$rc $(cat "$T/err")"

# ── M1: two branches, two fragments, no conflict ─────────────────────────────
M="$T/m"; mkdir -p "$M"; cp -R "$R/bin" "$M/"; mkdir -p "$M/catalog"; cp -R "$DIR/catalog/lanes.d" "$M/catalog/"
gm() { git -C "$M" -c user.email=t@example.com -c user.name=t "$@"; }
gm init -q -b main && gm add -A && gm commit -qm base
gm checkout -q -b one && mkdir -p "$M/catalog/lanes.d/review-prs.knobs.d"
KNOB BH4987_ONE 1 > "$M/catalog/lanes.d/review-prs.knobs.d/BH4987_ONE.json"; gm add -A && gm commit -qm one
gm checkout -q main && gm checkout -q -b two && mkdir -p "$M/catalog/lanes.d/review-prs.knobs.d"
KNOB BH4987_TWO 2 > "$M/catalog/lanes.d/review-prs.knobs.d/BH4987_TWO.json"; gm add -A && gm commit -qm two
gm merge -q --no-edit one > "$T/merge.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "M1 git merge must exit 0: $(cat "$T/merge.log")"
[ -z "$(gm diff --name-only --diff-filter=U)" ] && ok || bad "M1 unmerged paths: $(gm diff --name-only --diff-filter=U)"
bash "$M/bin/lanes-build.sh" --root "$M" > "$T/out" 2>"$T/err"
[ "$(jq -c '.lanes[]|select(.id=="review-prs")|.knobs[-2:]|map(.env)' "$T/out" 2>/dev/null)" = '["BH4987_ONE","BH4987_TWO"]' ] \
  && ok || bad "M1 the merged composition must hold both: $(lane_envs review-prs) $(cat "$T/err")"

# ── L1..L6: bin/lanes-knob-lint.sh ───────────────────────────────────────────
LR="$T/lint"; mkdir -p "$LR/bin" "$LR/catalog/lanes.d"
cp "$DIR/bin/lanes-knob-lint.sh" "$LR/bin/" 2>/dev/null
cp "$DIR/catalog/lanes.d/review-prs.json" "$DIR/catalog/lanes.d/_lib.caller-check.json" "$DIR/catalog/lanes.d/_registry.json" "$LR/catalog/lanes.d/"
gl() { git -C "$LR" -c user.email=t@example.com -c user.name=t "$@"; }
gl init -q -b main && gl add -A && gl commit -qm base
BASE=$(gl rev-parse HEAD)
lint() { # lint [base] -> stdout $T/lo, stderr $T/le, rc $RC
  (cd "$LR" && bash "$DIR/bin/lanes-knob-lint.sh" --base "${1:-$BASE}" .) > "$T/lo" 2> "$T/le"; RC=$?
}
reset_lint() { gl checkout -q main && gl branch -qD work 2>/dev/null; gl checkout -q -b work; }
addk() { # addk <file> <jq path> <ENV>
  jq --argjson k "$(KNOB "$3" 1)" "$2 += [\$k]" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
# L1 inline append to a lane, and to a lib
reset_lint
addk "$LR/catalog/lanes.d/review-prs.json" '.knobs' BH4987_INL
addk "$LR/catalog/lanes.d/_lib.caller-check.json" '.libs[0].knobs' BH4987_LIBINL
gl commit -qam inline
lint
[ "$RC" = 1 ] && ok || bad "L1 an inline append must be rc 1, got $RC: $(cat "$T/lo" "$T/le")"
[ "$(grep -c . "$T/lo")" = 2 ] && ok || bad "L1 want exactly 2 finding lines: $(cat "$T/lo")"
grep -qF "catalog/lanes.d/review-prs.json: adds knob BH4987_INL" "$T/lo" && grep -qF "catalog/lanes.d/review-prs.knobs.d/BH4987_INL.json" "$T/lo" \
  && ok || bad "L1 the lane finding must name the file and the fragment path: $(cat "$T/lo")"
grep -qF "catalog/lanes.d/_lib.caller-check.knobs.d/BH4987_LIBINL.json" "$T/lo" \
  && ok || bad "L1 the lib finding must name the lib fragment path: $(cat "$T/lo")"
# L2 a new lane file with inline knobs, and a new lib in an existing lib file
reset_lint
printf '{"id":"bh4987-new","script":"bin/x.sh","knobs":[%s]}\n' "$(KNOB NEW_LANE_K 1)" > "$LR/catalog/lanes.d/bh4987-new.json"
jq --argjson k "$(KNOB NEW_LIB_K 1)" '.libs += [{"id":"bh4987-newlib","file":"bin/lib/x.sh","knobs":[$k]}]' \
  "$LR/catalog/lanes.d/_lib.caller-check.json" > "$T/x" && mv "$T/x" "$LR/catalog/lanes.d/_lib.caller-check.json"
gl add -A && gl commit -qm newlane
lint
[ "$RC" = 0 ] && [ ! -s "$T/lo" ] && ok || bad "L2 a new lane / new lib is not a finding: rc=$RC $(cat "$T/lo")"
# L3 a changed default, plus a whitespace-only reformat
reset_lint
jq '.knobs[0].default = 424242' "$LR/catalog/lanes.d/review-prs.json" > "$T/x" && mv "$T/x" "$LR/catalog/lanes.d/review-prs.json"
jq -c . "$LR/catalog/lanes.d/_lib.caller-check.json" > "$T/x" && mv "$T/x" "$LR/catalog/lanes.d/_lib.caller-check.json"
gl commit -qam default
lint
[ "$RC" = 0 ] && [ ! -s "$T/lo" ] && ok || bad "L3 a changed default / reformat is not a finding: rc=$RC $(cat "$T/lo")"
# L4 a knob moved inline -> fragment, and a fragment added the right way
reset_lint
mv_env=$(jq -r '.knobs[-1].env' "$LR/catalog/lanes.d/review-prs.json")
mkdir -p "$LR/catalog/lanes.d/review-prs.knobs.d"
jq '.knobs[-1]' "$LR/catalog/lanes.d/review-prs.json" > "$LR/catalog/lanes.d/review-prs.knobs.d/$mv_env.json"
jq 'del(.knobs[-1])' "$LR/catalog/lanes.d/review-prs.json" > "$T/x" && mv "$T/x" "$LR/catalog/lanes.d/review-prs.json"
KNOB BH4987_FRAG 1 > "$LR/catalog/lanes.d/review-prs.knobs.d/BH4987_FRAG.json"
gl add -A && gl commit -qm move
lint
[ "$RC" = 0 ] && [ ! -s "$T/lo" ] && ok || bad "L4 a move to a fragment is not a finding: rc=$RC $(cat "$T/lo")"
# L5 a fork that predates the lint: skipped, rc 0
reset_lint
gl rm -q bin/lanes-knob-lint.sh && gl commit -qm "drop lint"
OLD=$(gl rev-parse HEAD)
gl checkout -q -b later
gl checkout -q "$BASE" -- bin/lanes-knob-lint.sh
addk "$LR/catalog/lanes.d/review-prs.json" '.knobs' BH4987_OLDFORK
gl add -A && gl commit -qm later
lint "$OLD"
[ "$RC" = 0 ] && ok || bad "L5 a fork without the lint must be rc 0, got $RC: $(cat "$T/lo")"
grep -q "lanes-knob-lint: skipped: .* predates knob fragments" "$T/le" && ok || bad "L5 the skipped line: $(cat "$T/le")"
gl checkout -q main
# L6 a bad --base, and a lane file that does not parse at HEAD
lint no-such-ref-bh4987
[ "$RC" = 2 ] && ok || bad "L6 a bad --base must be rc 2, got $RC"
reset_lint
printf '{"id":"review-prs",\n' > "$LR/catalog/lanes.d/review-prs.json"
gl commit -qam broken
lint
[ "$RC" = 2 ] && grep -qF "review-prs.json" "$T/le" && ok || bad "L6 an unparseable lane file must be rc 2 naming it, got $RC: $(cat "$T/le")"
gl checkout -q main

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
