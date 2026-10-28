#!/bin/bash
# tests/ci-batch-escalate-retired.bh-8649-test.sh — catalog/ci-batch-escalate.tsv
# is retired (BH-8649, the rest of BH-8608 item 3). Its rows live in the seed
# fragments catalog/ci-batch-escalate.d/seed-*.tsv, cbe_rules reads only the
# fragments, and cbe_check refuses the old file if it comes back.
#
#   S1  every row of the old file (tests/fixtures/bh-8649/old-rules.tsv) is in
#       the composed rules, and every seed row is an old row
#   S2  a planted old file changes no reader's answer
#   S3  the lint: a planted old file (file, directory, symlink) is retired
#   S4  no fragment fails closed
#   S5  per row: the readers answer the same with the old file and the tree
#   S6  the real planner and the fingerprint's @infra set answer the same
#   S7  this PR's diff shape is infra, not the corpus; a lost row is full;
#       no bin/ line outside the lib names the old path
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
OLD="$DIR/tests/fixtures/bh-8649/old-rules.tsv"
unset CI_BATCH_ESCALATE_TSV CI_FULL_TRIGGERS
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
GC() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }
RET='catalog/ci-batch-escalate.tsv:0: retired (BH-8649)'
[ -r "$OLD" ] || { echo "FAIL: no fixture $OLD"; exit 1; }

# rows <file>... — the non-comment, non-blank lines, sorted.
rows() { cat "$@" | grep -v '^#' | grep -v '^[[:space:]]*$' | LC_ALL=C sort; }
# compare <root> — rc 0 when every old row is in cbe_rules <root> (count
# included) and every row of <root>'s seed-*.tsv is an old row.
compare() {
  local r="$1" comp missing extra
  comp=$( . "$LIB" && cbe_rules "$r" ) || return 1
  missing=$(LC_ALL=C comm -23 <(rows "$OLD") <(rows <(printf '%s\n' "$comp")))
  extra=$(LC_ALL=C comm -13 <(rows "$OLD" | LC_ALL=C sort -u) <(rows "$r"/catalog/ci-batch-escalate.d/seed-*.tsv | LC_ALL=C sort -u))
  [ -z "$missing" ] && [ -z "$extra" ] && return 0
  echo "missing: [$missing] extra: [$extra]"; return 1
}

# ── S1. the seed compare.
[ "$(rows "$OLD" | grep -c .)" = 93 ] && ok || bad "S1: the fixture holds $(rows "$OLD" | grep -c .) rows, want 93"
[ "$(rows "$OLD" | grep -cxP 'catalog/prompt-markers\.json\tspa\t.*')" = 2 ] && ok || bad "S1: the fixture has the duplicate prompt-markers spa pair"
o=$(compare "$DIR") && ok || bad "S1: the tree's composed rules against the old rows: $o"
ls "$DIR"/catalog/ci-batch-escalate.d/seed-*.tsv > /dev/null 2>&1 && ok || bad "S1: the tree has no seed-*.tsv fragment"
sroot() { # sroot <name> — a copy of the real fragment folder. Prints the root.
  local r="$T/$1"; mkdir -p "$r/catalog"; cp -r "$DIR/catalog/ci-batch-escalate.d" "$r/catalog/"; printf '%s\n' "$r"
}
R=$(sroot s1a); compare "$R" > /dev/null && ok || bad "S1 control: an exact copy compares clean"
sed -i '/^fleet\.conf\tworker\t/d' "$R/catalog/ci-batch-escalate.d/seed-worker.tsv"
compare "$R" > /dev/null && bad "S1: a deleted seed row must fail the compare" || ok
R=$(sroot s1b); sed -i 's/^\(\.mergify\.yml\tescalate\t\).*/\1an edited why/' "$R/catalog/ci-batch-escalate.d/seed-escalate.tsv"
compare "$R" > /dev/null && bad "S1: a changed why must fail the compare" || ok
R=$(sroot s1c); sed -i '0,/^catalog\/prompt-markers\.json\tspa\t/{/^catalog\/prompt-markers\.json\tspa\t/d}' "$R/catalog/ci-batch-escalate.d/seed-spa.tsv"
compare "$R" > /dev/null && bad "S1: one of the 2 duplicate rows dropped must fail the compare" || ok
R=$(sroot s1d); printf 'zz-new/\tspa\ta later row\n' > "$R/catalog/ci-batch-escalate.d/bh-9999.tsv"
compare "$R" > /dev/null && ok || bad "S1: a new row in its own fragment must still compare clean"

# mkroot <name> — a scratch root with the real lib, the fragment `zz-frag/
# escalate` and the directory it names. Prints the root.
mkroot() {
  local r="$T/$1"
  mkdir -p "$r/catalog/ci-batch-escalate.d" "$r/zz-frag"
  scratch_install_closure bin/lib/ci-batch-escalate.sh "$r" > /dev/null || return 1
  printf 'zz-frag/\tescalate\tthe fragment row\n' > "$r/catalog/ci-batch-escalate.d/bh-1.tsv"
  printf '%s\n' "$r"
}
inr() { local r="$1"; shift; ( . "$r/bin/lib/ci-batch-escalate.sh" || exit 9; "$@" ); }
plant() { printf 'zz-old/\tescalate\told\nzz-old-spa/\tspa\told\nzz-old-inf/\tinfra\told\n' > "$1/catalog/ci-batch-escalate.tsv"; }

# ── S2. a planted old file is not read.
R=$(mkroot s2); plant "$R"
inr "$R" cbe_reason zz-old/x > /dev/null && bad "S2: an old-file escalate row must not escalate" || ok
inr "$R" cbe_affects spa zz-old-spa/x && bad "S2: an old-file spa row must not turn spa on" || ok
inr "$R" cbe_infra zz-old-inf/x && bad "S2: an old-file infra row must not be infra" || ok
[ "$(inr "$R" cbe_reason zz-frag/x)" = "selection input: zz-frag/x" ] && ok || bad "S2: the fragment row must escalate"
got=$(inr "$R" cbe_rules); rc=$?
{ [ "$rc" = 0 ] && [[ $got != *zz-old* ]] && [[ $got == *zz-frag/* ]]; } && ok || bad "S2: cbe_rules must print the fragment only (rc=$rc): [$got]"

# ── S3. the lint.
lint() { # lint <tag> <root> <want rc> [want substring]
  local o rc; o=$( . "$LIB" && cbe_check "$2" ); rc=$?
  [ "$rc" = "$3" ] || { bad "$1: cbe_check want rc $3, got $rc [$o]"; return; }
  if [ "$3" = 0 ]; then [ -z "$o" ] && ok || bad "$1: a pass prints nothing [$o]"; return; fi
  [[ $o == *"$4"* ]] && ok || bad "$1: output lacks [$4]: [$o]"
}
lint "S3 a planted old file" "$R" 1 "ci-batch-escalate: $RET; put its rows in catalog/ci-batch-escalate.d/<name>.tsv"
rm "$R/catalog/ci-batch-escalate.tsv"
lint "S3 the old file removed" "$R" 0
: > "$R/catalog/ci-batch-escalate.tsv"; lint "S3 an empty old file" "$R" 1 "$RET"; rm "$R/catalog/ci-batch-escalate.tsv"
mkdir "$R/catalog/ci-batch-escalate.tsv"; lint "S3 a directory of that name" "$R" 1 "$RET"; rmdir "$R/catalog/ci-batch-escalate.tsv"
ln -s "$T/no-such" "$R/catalog/ci-batch-escalate.tsv"; lint "S3 a dangling symlink of that name" "$R" 1 "$RET"; rm "$R/catalog/ci-batch-escalate.tsv"
printf 'x\n' > "$R/catalog/ci-batch-escalate.tsvx"; lint "S3 a near-miss sibling is not this lint's" "$R" 0; rm "$R/catalog/ci-batch-escalate.tsvx"
printf 'zz-frag/a\tspa\tnested name\n' > "$R/catalog/ci-batch-escalate.d/ci-batch-escalate.tsv"
lint "S3 a fragment named ci-batch-escalate.tsv is a fragment" "$R" 0
lint "S3 the real tree" "$DIR" 0
[ -z "$(git -C "$DIR" ls-files catalog/ci-batch-escalate.tsv)" ] && ok || bad "S3: catalog/ci-batch-escalate.tsv is still in git"
[ ! -e "$DIR/catalog/ci-batch-escalate.tsv" ] && ok || bad "S3: catalog/ci-batch-escalate.tsv still exists in the tree"

# ── S4. no fragment fails closed: no folder, and an empty folder.
closed() { # closed <tag> <root>
  local r; r=$(inr "$2" cbe_reason docs/x.md)
  [ "$r" = "selection input: catalog/ci-batch-escalate.tsv unreadable" ] && ok || bad "$1: cbe_reason must fail closed, got [$r]"
  inr "$2" cbe_affects spa docs/x.md && ok || bad "$1: cbe_affects must answer rc 0"
  inr "$2" cbe_infra bin/x.sh && bad "$1: cbe_infra must answer rc 1" || ok
  r=$(inr "$2" cbe_check); [ $? = 1 ] && [[ $r == *"catalog/ci-batch-escalate.d:0: no rules fragment"* ]] && ok \
    || bad "$1: cbe_check must be rc 1 with the no-fragment line: [$r]"
}
R=$(mkroot s4a); scratch_rm "$R/catalog/ci-batch-escalate.d"; closed "S4 no folder" "$R"
R=$(mkroot s4b); rm "$R/catalog/ci-batch-escalate.d/bh-1.tsv"; closed "S4 an empty folder" "$R"
printf 'readme\n' > "$R/catalog/ci-batch-escalate.d/README.md"; closed "S4 a folder with a README only" "$R"

# ── S5. per row: the same answers with the old file and with the tree.
# answers [VAR=val] < paths — `<path> <reason> <infra> <spa> <worker>` per path.
answers() {
  env "$@" bash -c '. "$1" || exit 9
    while IFS= read -r p; do
      r=$(cbe_reason "$p"); i=0; s=0; w=0
      cbe_infra "$p" && i=1; cbe_affects spa "$p" && s=1; cbe_affects worker "$p" && w=1
      printf "%s|%s|%s%s%s\n" "$p" "$r" "$i" "$s" "$w"
    done' _ "$LIB"
}
rows "$OLD" | awk -F'\t' '{ p = $1; if (p ~ /\/$/) p = p "zz.txt"; else gsub(/[*?\[\]]/, "", p); print p }' | LC_ALL=C sort -u > "$T/s5.paths"
printf '%s\n' docs/x.md bin/lib/x.md catalog/x.md console-ui/src/x.js >> "$T/s5.paths"
answers CI_BATCH_ESCALATE_TSV="$OLD" < "$T/s5.paths" > "$T/s5.old"
answers X=1 < "$T/s5.paths" > "$T/s5.new"
n=$(grep -c . "$T/s5.old")
{ [ "$n" -ge 86 ] && cmp -s "$T/s5.old" "$T/s5.new"; } && ok || bad "S5: $n paths; old file vs tree differ: $(diff "$T/s5.old" "$T/s5.new" | head -10)"
grep -qxF '.mergify.yml|selection input: .mergify.yml|000' "$T/s5.new" && grep -qxF 'docs/x.md||000' "$T/s5.new" \
  && grep -qxF 'fleet.conf||001' "$T/s5.new" && grep -qxF 'bin/ci-plan.sh||100' "$T/s5.new" \
  && ok || bad "S5: the tree's answers are not the known ones: $(grep -E '^(\.mergify|docs/x|fleet|bin/ci-plan)' "$T/s5.new")"

# ── S6. the real planner on a fixed 12-path batch, and the fingerprint.
QHEAD=$(git -C "$DIR" rev-parse HEAD)
cat > "$T/qimpact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; esac; shift; done
if [ "$cmd" = select ]; then printf 'tests/a-test.sh\n' > "$out"; echo "impact: 1 of 200 suites (selected)" >&2
else for i in $(seq 0 199); do echo "tests/s$i-test.sh"; done > "$out"; echo "impact: 200 of 200 suites (full: corpus)" >&2; fi
EOF
chmod +x "$T/qimpact.sh"; : > "$T/notiers.tsv"
qplan() { # qplan <paths-file> [VAR=val] — prints rc mode spa worker count escalation
  rm -f "$T/qgo"
  env -u GITHUB_ACTIONS -u CI_PR_BODY -u TI_PR_TITLE -u CI_REPO -u GITHUB_STEP_SUMMARY CI_PLAN_IMPACT="$T/qimpact.sh" \
      CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_QUARANTINE= TI_PR_LABELS= GITHUB_OUTPUT="$T/qgo" CI_EVENT=pull_request \
      TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$QHEAD" CI_PLAN_ESCALATION=- CI_PLAN_CHANGED_FILE="$1" \
      CI_INFRA_CANARY_FILE="$DIR/catalog/ci-infra-canary.txt" "${@:2}" "$DIR/bin/ci-plan.sh" --out "$T/qlist" > /dev/null 2>&1
  printf 'rc=%s ' "$?"; grep -E '^(mode|spa|worker|count|escalation)=' "$T/qgo" 2>/dev/null | paste -sd' ' -
}
qn=0; modes=""
for set in "docs/x.md console-ui/src/screens/Jobs.js bin/lib/jobs/cost.sh catalog/lanes.d/x.json fleet.conf" \
           "bin/lib/suite-runner.sh catalog/test-tiers.tsv" "worker/jobs/src/index.js tests/fixtures/daily-digest/empty-day.json" \
           ".mergify.yml" ".github/actions/x/action.yml" "bin/ci-plan.sh"; do
  printf '%s\n' $set > "$T/q.paths"; qn=$((qn + $(grep -c . "$T/q.paths")))
  a=$(qplan "$T/q.paths" CI_BATCH_ESCALATE_TSV="$OLD")
  b=$(qplan "$T/q.paths" X=1)
  { [ "$a" = "$b" ] && [[ $a == "rc=0 mode="* ]]; } && ok || bad "S6: [$set] old file [$a] vs tree [$b]"
  modes="$modes $(sed -n 's/.*mode=\([^ ]*\).*/\1/p' <<<"$b")"
done
[ "$qn" = 12 ] && ok || bad "S6: the fixed batch has $qn paths, want 12"
[[ $modes == *full* && $modes == *infra* ]] && ok || bad "S6: the fixed batch must reach both full and infra, got [$modes]"
# The fingerprint: the fixture as the only fragment, then the seed fragments.
fprint() { # fprint <name> <fragment source>... — the tree's @infra set, minus the rules folder itself
  local name="$1" r="$T/$1"; shift
  mkdir -p "$r/catalog/ci-batch-escalate.d" "$r/tests/lib"
  for s in bin/test-impact.sh bin/lib/ci-batch-escalate.sh; do scratch_install_closure "$s" "$r" > /dev/null || return 1; done
  cp "$@" "$r/catalog/ci-batch-escalate.d/"
  printf '{"v":1}\n' > "$r/catalog/c1.json"; printf 'x\n' > "$r/catalog/test-tiers.tsv"; printf '{}\n' > "$r/catalog/lanes.json"
  printf '# scratch\n' > "$r/tests/lib/scratch.sh"
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\ncat "$DIR/catalog/c1.json"\ncat "$DIR/catalog/test-tiers.tsv"\ncat "$DIR/catalog/lanes.json"\n' > "$r/tests/u1.sh"
  printf '#!/bin/bash\necho always\n' > "$r/tests/sa.sh"; printf 'tests/sa.sh\n' > "$r/catalog/test-impact-always.txt"
  GC "$r" init -q && GC "$r" add -A && GC "$r" commit -qm init || return 1
  "$r/bin/test-impact.sh" --root "$r" inputs 2> "$T/$name.err" | grep '^@infra' | grep -v 'catalog/ci-batch-escalate\.d/'
}
fa=$(fprint fa "$OLD"); fb=$(fprint fb "$DIR"/catalog/ci-batch-escalate.d/seed-*.tsv)
{ [ -n "$fa" ] && [ "$fa" = "$fb" ]; } && ok || bad "S6: fingerprint @infra old [$fa] vs seeds [$fb] $(cat "$T/fa.err" "$T/fb.err")"
{ grep -qxP '@infra\tcatalog/test-tiers.tsv' <<<"$fb" && ! grep -qxP '@infra\tcatalog/c1.json' <<<"$fb" \
  && ! grep -qxP '@infra\tcatalog/lanes.json' <<<"$fb"; } && ok || bad "S6: the seed @infra set is not the known one: [$fb]"

# ── S7. this PR's diff shape, on the real planner in a scratch repo.
G="$T/repo"; F=catalog/ci-batch-escalate.d
mkdir -p "$G/$F" "$G/tests"
scratch_install_closure bin/ci-plan.sh "$G" > /dev/null || { echo "FAIL: cannot install bin/ci-plan.sh's closure"; exit 1; }
cp "$OLD" "$G/catalog/ci-batch-escalate.tsv"; cp "$DIR/$F/bh-8608.tsv" "$DIR/$F/README.md" "$G/$F/"
printf '#!/bin/bash\n' > "$G/tests/canary-test.sh"; printf 'tests/canary-test.sh\n' > "$G/canary.txt"
cat > "$G/impact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; esac; shift; done
if [ "$cmd" = select ]; then printf 'tests/a-test.sh\n' > "$out"; echo "impact: 1 of 200 suites (selected)" >&2
else for i in $(seq 0 199); do echo "tests/s$i-test.sh"; done > "$out"; echo "impact: 200 of 200 suites (full: corpus)" >&2; fi
EOF
printf '#!/bin/bash\ncat\n' > "$G/tiers.sh"; chmod +x "$G/impact.sh" "$G/tiers.sh"
GC "$G" init -q && GC "$G" add -A && GC "$G" commit -qm base || { echo "FAIL: cannot commit the S7 base"; exit 1; }
BASE=$(GC "$G" rev-parse HEAD)
s7() { # s7 <tag> <shell edit> <want deletes_row rc> <want mode>
  local rc mode
  GC "$G" reset -q --hard "$BASE" && GC "$G" clean -fdq
  git -C "$G" rm -q catalog/ci-batch-escalate.tsv && cp "$DIR"/$F/seed-*.tsv "$G/$F/" && ( cd "$G" && eval "$2" ) || { bad "$1: the edit failed"; return; }
  GC "$G" add -A && GC "$G" commit -qm "$1"
  ( . "$LIB" && cbe_rules_diff "$G" "$BASE" ) > "$T/s7.diff" || { bad "$1: cbe_rules_diff failed"; return; }
  grep -q '^deleted file mode' "$T/s7.diff" && ok || bad "$1: the diff must delete the old file"
  ( . "$LIB" && cbe_deletes_row "$T/s7.diff" ); rc=$?
  [ "$rc" = "$3" ] && ok || bad "$1: cbe_deletes_row want rc $3, got $rc"
  ( . "$LIB" && cbe_add_only "$T/s7.diff" > /dev/null ) && bad "$1: a delete-and-seed diff is not add-only" || ok
  rm -f "$G/go"
  ( cd "$G" && env -u GITHUB_ACTIONS -u CI_PLAN_CHANGED_FILE -u CI_PR_BODY -u TI_PR_TITLE -u CI_REPO -u GITHUB_STEP_SUMMARY \
      CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= \
      CI_PLAN_IMPACT="$G/impact.sh" CI_PLAN_TIERS="$G/tiers.sh" CI_INFRA_CANARY_FILE="$G/canary.txt" GITHUB_OUTPUT="$G/go" \
      bin/ci-plan.sh --out "$G/list" > "$T/s7.out" 2>&1 ); rc=$?
  mode=$(sed -n 's/^mode=//p' "$G/go" 2>/dev/null | tail -1)
  { [ "$rc" = 0 ] && [ "$mode" = "$4" ]; } && ok || bad "$1: ci-plan want mode $4, got rc=$rc mode=$mode $(grep '^escalation=' "$G/go") $(tail -3 "$T/s7.out")"
}
s7 "S7 the old file deleted, every row seeded" ":" 1 infra
s7 "S7 the same, a seed row missing" "sed -i '/^fleet\.conf\tworker\t/d' $F/seed-worker.tsv" 0 full
s7 "S7 the same, a seed row with its kind changed" "sed -i 's/^\(fleet\.conf\t\)worker\t/\1spa\t/' $F/seed-worker.tsv" 0 full
# No bin/ line names the old path, comments included, but the fail-closed
# text and the lib's diff keys, retired-file lint and self row.
hits=$(cd "$DIR" && grep -rnF 'catalog/ci-batch-escalate.tsv' bin/ | grep -vF 'selection input: catalog/ci-batch-escalate.tsv' \
       | grep -v '^bin/lib/ci-batch-escalate.sh:')
[ -z "$hits" ] && ok || bad "S7: these bin/ lines still name catalog/ci-batch-escalate.tsv: $hits"
code=$(grep -nF 'catalog/ci-batch-escalate.tsv' "$LIB" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF 'selection input: catalog/ci-batch-escalate.tsv' \
       | grep -vE 'catalog/ci-batch-escalate\.tsv\) return 0 ;;|git -C "\$1" diff --no-renames|^[0-9]+:_CBE_SELF=|retired \(BH-8649\)|ret="\$root/catalog/ci-batch-escalate\.tsv"')
[ -z "$code" ] && ok || bad "S7: lib code lines that name the old path outside the allowed list: $code"
grep -qF 'ret="$root/catalog/ci-batch-escalate.tsv"' "$LIB" && ok || bad "S7: the lib must keep the retired-file lint path"

echo "ci-batch-escalate-retired.bh-8649-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
