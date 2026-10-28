#!/bin/bash
# tests/ci-batch-escalate-fragments.bh-8608-test.sh — the batch-escalation
# rules are composed from every catalog/ci-batch-escalate.d/*.tsv fragment
# (BH-8608, slice C0; the old file catalog/ci-batch-escalate.tsv is retired
# since BH-8649 and still keys the rules diff).
#
# WHY. Every PR that added a cross-tree row appended it to the end of one
# file, and parallel PRs conflicted on the same last lines (#7653, #8550,
# #8511 twice on 2026-10-27). A new row now goes in its own fragment file, so
# two PRs add two files. This suite proves every reader sees a fragment row,
# the planner judges a fragment diff as it judges the old file's diff, and the
# lint (cbe_check) refuses a broken fragment. It is also the lint's CI step:
# it names catalog/ci-batch-escalate.d/, so a batch that changes a fragment
# runs it.
#
#   R1-R8   cbe_rules and the readers (cbe_reason, cbe_affects, cbe_infra)
#   D1-D16  cbe_add_only / cbe_deletes_row on real `git diff -U0` output
#   P1-P10  cbe_rules_path, and the real bin/ci-plan.sh in a scratch repo
#   L1-L13  cbe_check, and cbe_check on the real tree
#   M1      two branches that each add a fragment merge with no conflict
#   Q1      the real planner gives the same answers with the old file's rows
#           (tests/fixtures/bh-8649/old-rules.tsv) and the composed rules
#   F1      the fingerprint's @infra set reads a fragment row
#   S1      a batch select of a changed fragment selects this suite
#   X1      the row tests/cross-tree-rows.bh-8573-test.sh prints, in a fragment
#   G1      no bin/ reader outside the lib reads the old file by path
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
unset CI_BATCH_ESCALATE_TSV CI_FULL_TRIGGERS
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TAB=$'\t'
GC() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }

# mkroot <name> — a scratch root with the real lib and a fragment folder that
# holds one base fragment, 0-base.tsv, with one row. Prints the root.
mkroot() {
  local r="$T/$1"
  mkdir -p "$r/catalog/ci-batch-escalate.d"
  scratch_install_closure bin/lib/ci-batch-escalate.sh "$r" > /dev/null || return 1
  printf '# base fragment\nzz-base/\tescalate\tbase row\n' > "$r/catalog/ci-batch-escalate.d/0-base.tsv"
  printf '%s\n' "$r"
}
# inr <root> <fn> [args] — call a lib function sourced from <root>/bin/lib.
inr() { local r="$1"; shift; ( . "$r/bin/lib/ci-batch-escalate.sh" || exit 9; "$@" ); }
frag() { printf '%b' "$3" > "$1/catalog/ci-batch-escalate.d/$2"; }

# ── R1. composition order: the fragments in LC_ALL=C order. A
# fragment with no final newline does not glue its last row to the next one.
R=$(mkroot r1)
frag "$R" b.tsv 'zz-b/\tspa\tb\n'
frag "$R" a.tsv 'zz-a/\tworker\ta'
frag "$R" B.tsv 'zz-B/\tinfra\tB\n'
frag "$R" README.md 'zz-readme/\tescalate\tnot a source\n'
frag "$R" x.txt 'zz-txt/\tescalate\tnot a source\n'
want=$(printf '# base fragment\nzz-base/\tescalate\tbase row\nzz-B/\tinfra\tB\nzz-a/\tworker\ta\nzz-b/\tspa\tb')
got=$(LC_ALL=en_US.UTF-8 inr "$R" cbe_rules 2>/dev/null); rc=$?
{ [ "$rc" = 0 ] && [ "$got" = "$want" ]; } && ok || bad "R1: cbe_rules order (rc=$rc): [$got]"
got=$( . "$LIB" && cbe_rules "$R" ); [ "$got" = "$want" ] && ok || bad "R1: cbe_rules <root> reads that root: [$got]"
scratch_rm "$R/catalog/ci-batch-escalate.d"
got=$(inr "$R" cbe_rules); rc=$?
{ [ "$rc" = 0 ] && [ -z "$got" ]; } && ok || bad "R1: no folder is zero fragments (rc=$rc): [$got]"

# ── R2. a row that exists only in a fragment changes every reader's answer.
R=$(mkroot r2)
reads() { # reads <tag> <want: 1 = the fragment rows count, 0 = they do not>
  local e a i
  inr "$R" cbe_reason frag-esc/x > /dev/null && e=1 || e=0
  inr "$R" cbe_affects spa frag-spa/x && a=1 || a=0
  inr "$R" cbe_infra frag-inf/x && i=1 || i=0
  [ "$e$a$i" = "$2$2$2" ] && ok || bad "$1: reason/affects/infra of the fragment rows = $e$a$i, want $2$2$2"
}
reads "R2 no fragment" 0
frag "$R" bh-1.tsv 'frag-esc/\tescalate\te\nfrag-spa/\tspa\ts\nfrag-inf/\tinfra\ti\nzz-base/*.md\tallow\tdocs\n'
reads "R2 fragment" 1
[ "$(inr "$R" cbe_reason frag-esc/x)" = "selection input: frag-esc/x" ] && ok || bad "R2: cbe_reason names the path"
inr "$R" cbe_reason zz-base/doc.md > /dev/null && bad "R2: a fragment allow row exempts another fragment's escalate row" || ok
inr "$R" cbe_reason zz-base/x.sh > /dev/null && ok || bad "R2: the base fragment's escalate row still counts"
inr "$R" cbe_affects worker frag-spa/x && bad "R2: a spa row is not a worker row" || ok

# ── R3. CI_BATCH_ESCALATE_TSV replaces both sources.
printf 'env-only/\tescalate\tenv\n' > "$T/env.tsv"
[ "$(CI_BATCH_ESCALATE_TSV="$T/env.tsv" inr "$R" cbe_rules)" = "$(cat "$T/env.tsv")" ] && ok || bad "R3: cbe_rules prints only the env file"
CI_BATCH_ESCALATE_TSV="$T/env.tsv" inr "$R" cbe_reason frag-esc/x > /dev/null && bad "R3: a fragment row is ignored under the env file" || ok
CI_BATCH_ESCALATE_TSV="$T/env.tsv" inr "$R" cbe_reason env-only/x > /dev/null && ok || bad "R3: the env file's row counts"
CI_BATCH_ESCALATE_TSV="$T/env.tsv" inr "$R" cbe_affects spa frag-spa/x && bad "R3: cbe_affects ignores fragments under the env file" || ok

# ── R4-R6. fail closed on a source that cannot be read.
closed() { # closed <tag> [VAR=val] — every reader fails closed on root $R
  local r tag="$1" rrc=1; shift
  [ "${1:-}" = RULES_RC0 ] && { rrc=0; shift; }
  r=$(env "$@" bash -c '. "$1" && cbe_reason docs/x.md' _ "$R/bin/lib/ci-batch-escalate.sh")
  [ "$r" = "selection input: catalog/ci-batch-escalate.tsv unreadable" ] && ok || bad "$tag: cbe_reason must fail closed, got [$r]"
  env "$@" bash -c '. "$1" && cbe_affects spa docs/x.md' _ "$R/bin/lib/ci-batch-escalate.sh" && ok || bad "$tag: cbe_affects must answer rc 0"
  env "$@" bash -c '. "$1" && cbe_infra frag-inf/x' _ "$R/bin/lib/ci-batch-escalate.sh" && bad "$tag: cbe_infra must answer rc 1" || ok
  if [ "$rrc" = 1 ]; then
    env "$@" bash -c '. "$1" && cbe_rules > /dev/null' _ "$R/bin/lib/ci-batch-escalate.sh" && bad "$tag: cbe_rules must be rc 1" || ok
  else # zero fragments: nothing to read, so cbe_rules prints nothing, rc 0, and the readers above fail closed on that
    r=$(env "$@" bash -c '. "$1" && cbe_rules' _ "$R/bin/lib/ci-batch-escalate.sh"); [ $? = 0 ] && [ -z "$r" ] && ok || bad "$tag: cbe_rules must print nothing, rc 0 [$r]"
  fi
}
# The bad source sorts first, so a good fragment is read after it.
ln -s "$T/no-such-target" "$R/catalog/ci-batch-escalate.d/aa-dangling.tsv"
closed "R4 dangling fragment" X=1
rm "$R/catalog/ci-batch-escalate.d/aa-dangling.tsv"
mkdir "$R/catalog/ci-batch-escalate.d/aa-dir.tsv"
closed "R4 a fragment that is a directory" X=1
rmdir "$R/catalog/ci-batch-escalate.d/aa-dir.tsv"
mv "$R/catalog/ci-batch-escalate.d" "$T/r2-frags"
closed "R5 no fragment folder" RULES_RC0 X=1
mkdir "$R/catalog/ci-batch-escalate.d"
closed "R5 an empty fragment folder" RULES_RC0 X=1
rmdir "$R/catalog/ci-batch-escalate.d"; mv "$T/r2-frags" "$R/catalog/ci-batch-escalate.d"
closed "R6 env file unreadable" CI_BATCH_ESCALATE_TSV="$T/no-such.tsv"
reads "R6 control: the root reads again" 1

# ── R7. the real tree: a fragment path escalates through the folder's row,
# the folder's README does not.
[ "$( . "$LIB" && cbe_reason catalog/ci-batch-escalate.d/bh-9999.tsv)" = "selection input: catalog/ci-batch-escalate.d/bh-9999.tsv" ] \
  && ok || bad "R7: a fragment path must escalate through the folder's own row"
( . "$LIB" && cbe_reason catalog/ci-batch-escalate.d/README.md > /dev/null ) && bad "R7: the folder's README must not escalate" || ok
grep -qP '^catalog/ci-batch-escalate\.d/\tescalate\t' "$DIR/catalog/ci-batch-escalate.d/bh-8608.tsv" 2>/dev/null \
  && ok || bad "R7: catalog/ci-batch-escalate.d/bh-8608.tsv must carry the folder's escalate row"

# ── R8. a delta can never remove the folder's row.
r=$( . "$LIB" && cbe_delta_norm '-catalog/ci-batch-escalate.d/' 2> "$T/r8.err")
{ [ "$r" = - ] && grep -q 'refused (a self row)' "$T/r8.err"; } && ok || bad "R8: -catalog/ci-batch-escalate.d/ must be refused: [$r] $(cat "$T/r8.err")"

# ── D. the diff judges, on real `git diff -U0` output over both sources.
DG="$T/dg"; mkdir -p "$DG/catalog/ci-batch-escalate.d"
printf '# old\nzz-old-esc/\tescalate\told e\nzz-old-spa/\tspa\told s\n' > "$DG/catalog/ci-batch-escalate.tsv"
printf 'zz-f1/\tworker\tf1\nzz-f1b/\tinfra\tf1b\n' > "$DG/catalog/ci-batch-escalate.d/bh-1.tsv"
printf 'readme\n' > "$DG/catalog/ci-batch-escalate.d/README.md"
GC "$DG" init -q && GC "$DG" config core.fileMode true && GC "$DG" add -A && GC "$DG" commit -qm base || { echo "FAIL: cannot commit the D base"; exit 1; }
DBASE=$(GC "$DG" rev-parse HEAD)
F="catalog/ci-batch-escalate.d"
# dcase <tag> <shell edit> <add-only rc> <add-only kinds> <deletes-row rc>
dcase() {
  local r rc
  GC "$DG" reset -q --hard "$DBASE" && GC "$DG" clean -fdq
  ( cd "$DG" && eval "$2" ) || { bad "$1: the edit failed"; return; }
  GC "$DG" add -A && GC "$DG" commit -qm "$1" --allow-empty
  ( . "$LIB" && cbe_rules_diff "$DG" "$DBASE" ) > "$T/d.diff" || { bad "$1: cbe_rules_diff failed"; return; }
  r=$( . "$LIB" && cbe_add_only "$T/d.diff"); rc=$?
  { [ "$rc" = "$3" ] && [ "$r" = "$4" ]; } || { bad "$1: cbe_add_only want rc $3 [$4], got rc $rc [$r] $(cat "$T/d.diff")"; return; }
  ( . "$LIB" && cbe_deletes_row "$T/d.diff" ); rc=$?
  [ "$rc" = "$5" ] && ok || bad "$1: cbe_deletes_row want rc $5, got $rc $(cat "$T/d.diff")"
}
dcase "D1 new fragment, one spa row"     "printf 'n1/\tspa\tx\n' > $F/bh-2.tsv" 0 spa 1
dcase "D2 new fragment, escalate+worker" "printf 'n1/\tworker\tx\nn2/\tescalate\ty\n' > $F/bh-2.tsv" 0 $'escalate\nworker' 1
dcase "D3 two new fragments"             "printf 'n1/\tspa\tx\n' > $F/bh-2.tsv; printf 'n2/\tworker\ty\n' > $F/bh-3.tsv" 0 $'spa\nworker' 1
dcase "D4 old file row + new fragment"   "printf 'n1/\tspa\tx\n' >> catalog/ci-batch-escalate.tsv; printf 'n2/\tescalate\ty\n' > $F/bh-2.tsv" 0 $'escalate\nspa' 1
dcase "D5 new fragment, comment+blank"   "printf '# why\n\nn1/\tspa\tx\n' > $F/bh-2.tsv" 0 spa 1
dcase "D6 why edit in a fragment"        "sed -i 's/\tf1\$/\tf1 edited/' $F/bh-1.tsv" 1 "" 1
dcase "D7 new fragment, infra row"       "printf 'n1/\tinfra\tx\n' > $F/bh-2.tsv" 1 "" 1
dcase "D8 row moved old -> fragment"     "sed -i '/^zz-old-spa/d' catalog/ci-batch-escalate.tsv; printf 'zz-old-spa/\tspa\tmoved\n' > $F/bh-2.tsv" 1 "" 1
dcase "D9 row moved between fragments"   "sed -i '/^zz-f1b/d' $F/bh-1.tsv; printf 'zz-f1b/\tinfra\tmoved\n' > $F/bh-2.tsv" 1 "" 1
dcase "D10 comment edit in a fragment"   "printf '# note\n' >> $F/bh-1.tsv" 1 "" 1
dcase "D11 a removed fragment row"       "sed -i '/^zz-f1b/d' $F/bh-1.tsv" 1 "" 0
dcase "D12 a deleted fragment file"      "rm $F/bh-1.tsv" 1 "" 0
dcase "D13 a kind change in a fragment"  "sed -i 's/\tworker\t/\tspa\t/' $F/bh-1.tsv" 1 "" 0
dcase "D14 an added allow row"           "printf 'n1/*.md\tallow\tx\n' > $F/bh-2.tsv" 1 "" 0
dcase "D15 a malformed added row"        "printf 'n1/\tspa\n' > $F/bh-2.tsv" 1 "" 0
dcase "D16 a mode-only change"           "chmod +x $F/bh-1.tsv" 1 "" 0
dcase "D16b README edit is not in the diff" "printf 'more\n' >> $F/README.md" 1 "" 0
( . "$LIB" && cbe_rules_diff "$DG" 0000000000000000000000000000000000000bad ) > /dev/null 2>&1 && bad "D16c: a bad base must fail the diff" || ok

# ── P1. which changed paths are rules paths.
for p in catalog/ci-batch-escalate.tsv catalog/ci-batch-escalate.d/bh-1.tsv catalog/ci-batch-escalate.d/zz-theme.tsv; do
  ( . "$LIB" && cbe_rules_path "$p" ) && ok || bad "P1: $p is a rules path"
done
for p in catalog/ci-batch-escalate.d/README.md catalog/ci-batch-escalate.d/x.txt catalog/ci-batch-escalate.d/sub/x.tsv \
         catalog/ci-batch-escalate.tsvx catalog/ci-batch-regression.d/bh-1.txt xcatalog/ci-batch-escalate.d/a.tsv catalog/ci-batch-escalate.d/; do
  ( . "$LIB" && cbe_rules_path "$p" ) && bad "P1: $p is not a rules path" || ok
done

# ── P2-P10. the real planner in a scratch repo with the real rules.
G="$T/repo"; mkdir -p "$G/catalog/ci-batch-escalate.d" "$G/tests"
scratch_install_closure bin/ci-plan.sh "$G" > /dev/null || { echo "FAIL: cannot install bin/ci-plan.sh's closure"; exit 1; }
[ -f "$G/bin/lib/ci-batch-escalate.sh" ] || { echo "FAIL: the closure has no bin/lib/ci-batch-escalate.sh"; exit 1; }
cp "$DIR"/catalog/ci-batch-escalate.d/* "$G/catalog/ci-batch-escalate.d/" 2>/dev/null
printf 'zz-p/\tworker\texisting fragment\n' > "$G/catalog/ci-batch-escalate.d/bh-7.tsv"
printf '#!/bin/bash\n' > "$G/tests/canary-test.sh"; printf 'tests/canary-test.sh\n' > "$G/canary.txt"
cat > "$G/impact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; esac; shift; done
if [ "$cmd" = select ]; then
  printf 'tests/a-test.sh\ntests/b-test.sh\n' > "$out"; echo "impact: 2 of 10 suites (selected)" >&2
else
  for i in 0 1 2 3 4 5 6 7 8 9; do echo "tests/s$i-test.sh"; done > "$out"; echo "impact: 10 of 10 suites (full: corpus)" >&2
fi
EOF
printf '#!/bin/bash\ncat\n' > "$G/tiers.sh"
chmod +x "$G/impact.sh" "$G/tiers.sh"
GC "$G" init -q && GC "$G" config core.fileMode true && GC "$G" add -A && GC "$G" commit -qm base || { echo "FAIL: cannot commit the scratch base"; exit 1; }
BASE=$(GC "$G" rev-parse HEAD)
# pcase <tag> <shell edit> — reset to the base, edit, commit, plan TI_BASE=$BASE
pcase() {
  GC "$G" reset -q --hard "$BASE" && GC "$G" clean -fdq
  ( cd "$G" && eval "$2" ) || { bad "$1: the edit failed"; return 1; }
  GC "$G" add -A && GC "$G" commit -qm "$1" --allow-empty
  rm -f "$G/go"
  OUT=$(cd "$G" && env -u GITHUB_ACTIONS -u CI_PLAN_CHANGED_FILE CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t \
          TI_BASE="${PBASE:-$BASE}" CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$G/impact.sh" \
          CI_PLAN_TIERS="$G/tiers.sh" CI_INFRA_CANARY_FILE="$G/canary.txt" GITHUB_OUTPUT="$G/go" bin/ci-plan.sh --out "$G/list" 2>&1); RC=$?
  GO=$(cat "$G/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
pwant() { # pwant <tag> <mode> <spa> <worker> <escalation> [summary substring]
  { [ "$RC" = 0 ] && [ "$(out mode)" = "$2" ] && [ "$(out spa)" = "$3" ] && [ "$(out worker)" = "$4" ] && [ "$(out escalation)" = "$5" ] \
    && { [ -z "${6:-}" ] || [[ $(out summary) == *"$6"* ]]; }; } && ok \
    || bad "$1: want mode=$2 spa=$3 worker=$4 escalation='$5' summary~'${6:-}', got rc=$RC mode=$(out mode) spa=$(out spa) worker=$(out worker) escalation='$(out escalation)' summary='$(out summary)' [$OUT]"
}
pcase P2 "printf 'zz-p2/\tspa\tx\n' > $F/bh-2.tsv"
pwant "P2 a new spa fragment" batch-selected 1 0 - "escalation rows added only (spa)"
pcase P3 "printf 'zz-p3/\tworker\tx\n' > $F/bh-2.tsv; printf 'zz-p3e/\tescalate\ty\n' >> $F/seed-escalate.tsv"
pwant "P3 a worker fragment + a row appended to a seed fragment" batch-selected 0 1 - "escalation rows added only (escalate,worker)"
pcase P4 "sed -i 's/existing fragment/edited why/' $F/bh-7.tsv"
pwant "P4 a why edit is infra (both jobs run whole)" infra 1 1 -
pcase P4b "sed -i '/^bin\/test-tiers.sh\t/{w $F/bh-2.tsv
d}' $F/seed-infra.tsv"
pwant "P4b a row moved into another fragment is infra" infra 1 1 -
pcase P5 "rm $F/bh-7.tsv"
pwant "P5 a deleted fragment escalates" full 1 1 "selection input: $F/bh-7.tsv"
pcase P6 "printf 'zz-p6/*.md\tallow\tx\n' > $F/bh-2.tsv"
pwant "P6 an added allow row escalates" full 1 1 "selection input: $F/bh-2.tsv"
pcase P7 "printf 'more\n' >> $F/README.md"
pwant "P7 a README edit selects" batch-selected 0 0 -
[[ $(out summary) != *"rows added only"* ]] && ok || bad "P7: a README edit is not a rows-added diff: $(out summary)"
pcase P8 "chmod +x $F/bh-7.tsv"
pwant "P8 a mode-only change escalates" full 1 1 "selection input: $F/bh-7.tsv"
PBASE=0000000000000000000000000000000000000bad pcase P9 "printf 'zz-p9/\tspa\tx\n' > $F/bh-2.tsv"
[ "$(out mode)" = full ] && ok || bad "P9: a base the diff cannot read must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"
pcase P10 "printf 'zz-p10/\tspa\tx\n' > $F/sub.tsv; mkdir $F/sub; printf 'zz-p10b/\tspa\tx\n' > $F/sub/x.tsv"
pwant "P10 a file in a sub-folder escalates" full 1 1 "selection input: $F/sub/x.tsv"

# ── L. the lint.
lint() { # lint <tag> <root> <want rc> [want output substring]...
  local tag="$1" r="$2" want="$3" o rc s; shift 3
  o=$( . "$LIB" && cbe_check "$r" ); rc=$?
  [ "$rc" = "$want" ] || { bad "$tag: cbe_check want rc $want, got $rc [$o]"; return; }
  [ "$want" = 1 ] || [ -z "$o" ] || { bad "$tag: a pass prints nothing [$o]"; return; }
  [ "$want" = 0 ] || [ "$(grep -c '^ci-batch-escalate: ' <<<"$o")" = "$(grep -c . <<<"$o")" ] || { bad "$tag: every line starts 'ci-batch-escalate: ' [$o]"; return; }
  for s in "$@"; do [[ $o == *"$s"* ]] || { bad "$tag: output lacks [$s]: [$o]"; return; }; done
  ok
}
lroot() { # lroot <name> — a lint root with bin/ and worker/jobs/ dirs
  local r; r=$(mkroot "$1"); mkdir -p "$r/worker/jobs" "$r/zz-base"; printf 'readme\n' > "$r/catalog/ci-batch-escalate.d/README.md"; printf '%s\n' "$r"
}
L=$(lroot l1)
lint "L1 a clean root" "$L" 0
frag "$L" bh-1.tsv '# a comment\twith\ttabs\nbin/test-impact*.sh\tinfra\tglob\nworker/jobs/schema.sql\tworker\tgit-ignored render\nzz-base/\tspa\tsame pattern, other kind\nbin/x\tspa\tdup in one file\nbin/x\tspa\tdup in one file\n\n'
lint "L2 globs, ignored renders, an in-file duplicate" "$L" 0
L=$(lroot l3); frag "$L" bh-1.tsv 'zz-base/x\tspa\n'
lint "L3 two columns" "$L" 1 "catalog/ci-batch-escalate.d/bh-1.tsv:1:"
L=$(lroot l4); frag "$L" bh-1.tsv 'zz-base/x\tescalte\twhy\n'
lint "L4 an unknown kind" "$L" 1 "bh-1.tsv:1:" escalte
L=$(lroot l5); frag "$L" bh-1.tsv '\n# c\nzz-base/x\tspa\t \n'
lint "L5 an empty why" "$L" 1 "bh-1.tsv:3:"
L=$(lroot l6); frag "$L" bh-1.tsv 'zz-base/x\tspa\ta\n'; frag "$L" bh-2.tsv 'zz-base/x\tspa\tb\n'
lint "L6 a duplicate across fragments" "$L" 1 "bh-2.tsv:1:" "catalog/ci-batch-escalate.d/bh-1.tsv:1"
L=$(lroot l7); printf 'zz-base/\tescalate\ta planted old file\n' > "$L/catalog/ci-batch-escalate.tsv"
lint "L7 a planted old file is retired" "$L" 1 "catalog/ci-batch-escalate.tsv:0: retired (BH-8649)"
L=$(lroot l8); frag "$L" bh-1.tsv 'nosuchdir/x.sh\tescalate\twhy\n'
lint "L8 a missing directory" "$L" 1 "bh-1.tsv:1:" nosuchdir
L=$(lroot l9); mkdir "$L/catalog/ci-batch-escalate.d/sub"
lint "L9 a sub-folder" "$L" 1 "catalog/ci-batch-escalate.d/sub"
L=$(lroot l10); frag "$L" x.txt 'zz-base/\tspa\tx\n'
lint "L10 a non-tsv file" "$L" 1 "catalog/ci-batch-escalate.d/x.txt"
L=$(lroot l11); frag "$L" bh-1.tsv '\tspa\tno pattern\n'
lint "L11 an empty pattern" "$L" 1 "bh-1.tsv:1:"
L=$(lroot l12); ln -s "$T/no-such" "$L/catalog/ci-batch-escalate.d/bh-1.tsv"
lint "L12 a dangling fragment" "$L" 1 "bh-1.tsv"
L=$(lroot l12b); frag "$L" bh-1.tsv 'nosuch*/x\tescalate\tglob in the first segment\n'
lint "L12b a glob in the first segment checks the root" "$L" 0
lint "L13 the real tree" "$DIR" 0

# ── M1. two PRs that each add a fragment merge with no conflict.
M="$T/m"; mkdir -p "$M/catalog/ci-batch-escalate.d"
scratch_install_closure bin/lib/ci-batch-escalate.sh "$M" > /dev/null || { echo "FAIL: cannot install the lib for M1"; exit 1; }
printf 'zz-base/\tescalate\tbase\n' > "$M/catalog/ci-batch-escalate.d/0-base.tsv"
printf 'readme\n' > "$M/catalog/ci-batch-escalate.d/README.md"
GC "$M" init -q -b main && GC "$M" add -A && GC "$M" commit -qm base || { echo "FAIL: cannot commit the M base"; exit 1; }
GC "$M" checkout -qb a && printf 'zz-a/\tspa\tPR a\n' > "$M/catalog/ci-batch-escalate.d/bh-1.tsv" && GC "$M" add -A && GC "$M" commit -qm a
GC "$M" checkout -q main && GC "$M" checkout -qb b && printf 'zz-b/\tworker\tPR b\n' > "$M/catalog/ci-batch-escalate.d/bh-2.tsv" && GC "$M" add -A && GC "$M" commit -qm b
GC "$M" checkout -q a && GC "$M" merge -q --no-edit b > "$T/m.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "M1: two fragment PRs must merge clean (rc=$rc) $(cat "$T/m.out")"
got=$(inr "$M" cbe_rules)
{ grep -qx "zz-a/${TAB}spa${TAB}PR a" <<<"$got" && grep -qx "zz-b/${TAB}worker${TAB}PR b" <<<"$got"; } && ok || bad "M1: the composed rules carry both rows: [$got]"
# Control: the same two rows appended to one shared file conflict.
GC "$M" checkout -q main && GC "$M" checkout -qb oa && printf 'zz-a/\tspa\tPR a\n' >> "$M/catalog/ci-batch-escalate.d/0-base.tsv" && GC "$M" commit -qam oa
GC "$M" checkout -q main && GC "$M" checkout -qb ob && printf 'zz-b/\tworker\tPR b\n' >> "$M/catalog/ci-batch-escalate.d/0-base.tsv" && GC "$M" commit -qam ob
GC "$M" checkout -q oa && GC "$M" merge -q --no-edit ob > /dev/null 2>&1 && bad "M1 control: two appends to one file must conflict" || ok
GC "$M" merge --abort > /dev/null 2>&1

# ── Q1. the real planner: the old file's rows (the BH-8649 fixture) and the
# composed rules give the same answers on a fixed diff (no path here touches
# the fragment folder).
QHEAD=$(git -C "$DIR" rev-parse HEAD)
cat > "$T/qimpact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; esac; shift; done
if [ "$cmd" = select ]; then printf 'tests/a-test.sh\n' > "$out"; echo "impact: 1 of 10 suites (selected)" >&2
else for i in 0 1 2 3 4 5 6 7 8 9; do echo "tests/s$i-test.sh"; done > "$out"; echo "impact: 10 of 10 suites (full: corpus)" >&2; fi
EOF
chmod +x "$T/qimpact.sh"; : > "$T/notiers.tsv"
qplan() { # qplan <paths-file> [VAR=val] — prints mode spa worker count escalation
  rm -f "$T/qgo"
  env -u GITHUB_ACTIONS -u CI_PR_BODY -u TI_PR_TITLE -u CI_REPO -u GITHUB_STEP_SUMMARY CI_PLAN_IMPACT="$T/qimpact.sh" \
      CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_QUARANTINE= TI_PR_LABELS= GITHUB_OUTPUT="$T/qgo" CI_EVENT=pull_request \
      TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$QHEAD" CI_PLAN_ESCALATION=- CI_PLAN_CHANGED_FILE="$1" \
      "${@:2}" "$DIR/bin/ci-plan.sh" --out "$T/qlist" > /dev/null 2>&1
  printf 'rc=%s ' "$?"; grep -E '^(mode|spa|worker|count|escalation)=' "$T/qgo" 2>/dev/null | paste -sd' ' -
}
qn=0
for set in "docs/x.md console-ui/src/screens/Jobs.js bin/lib/jobs/cost.sh catalog/lanes.d/x.json fleet.conf" \
           "bin/lib/suite-runner.sh catalog/test-tiers.tsv" "worker/jobs/src/index.js tests/fixtures/daily-digest/empty-day.json" \
           ".mergify.yml" ".github/actions/x/action.yml" "bin/ci-plan.sh"; do
  printf '%s\n' $set > "$T/q.paths"; qn=$((qn + $(grep -c . "$T/q.paths")))
  a=$(qplan "$T/q.paths" CI_BATCH_ESCALATE_TSV="$DIR/tests/fixtures/bh-8649/old-rules.tsv" CI_INFRA_CANARY_FILE="$DIR/catalog/ci-infra-canary.txt")
  b=$(qplan "$T/q.paths" CI_INFRA_CANARY_FILE="$DIR/catalog/ci-infra-canary.txt")
  { [ "$a" = "$b" ] && [[ $a == "rc=0 mode="* ]]; } && ok || bad "Q1: [$set] old file [$a] vs composed [$b]"
done
[ "$qn" -ge 12 ] && ok || bad "Q1: the fixed diff has $qn paths, want 12 or more"

# ── F1. the fingerprint's @infra set reads the composed rules.
FR="$T/frepo"; mkdir -p "$FR"
for s in bin/test-impact.sh bin/lib/ci-batch-escalate.sh; do
  scratch_install_closure "$s" "$FR" > /dev/null || { echo "FAIL: cannot install $s"; exit 1; }
done
mkdir -p "$FR/tests/lib" "$FR/catalog/ci-batch-escalate.d"
printf '{"v":1}\n' > "$FR/catalog/c1.json"
printf 'tests/lib/scratch.sh\tescalate\tglobal\n' > "$FR/catalog/ci-batch-escalate.d/0-base.tsv"
printf '# scratch\n' > "$FR/tests/lib/scratch.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\ncat "$DIR/catalog/c1.json"\n' > "$FR/tests/u1.sh"
printf '#!/bin/bash\necho always\n' > "$FR/tests/sa.sh"; printf 'tests/sa.sh\n' > "$FR/catalog/test-impact-always.txt"
GC "$FR" init -q && GC "$FR" add -A && GC "$FR" commit -qm init || { echo "FAIL: cannot commit the F base"; exit 1; }
"$FR/bin/test-impact.sh" --root "$FR" inputs > "$T/f0.tsv" 2> "$T/f0.err" || bad "F1: inputs failed: $(cat "$T/f0.err")"
grep -qxF "@infra${TAB}catalog/c1.json" "$T/f0.tsv" && bad "F1 control: a named catalog file with no row is not @infra" || ok
printf 'catalog/c1.json\tescalate\tfragment only\n' > "$FR/catalog/ci-batch-escalate.d/bh-1.tsv"
GC "$FR" add -A && GC "$FR" commit -qm frag
"$FR/bin/test-impact.sh" --root "$FR" inputs > "$T/f1.tsv" 2> "$T/f1.err" || bad "F1: inputs failed: $(cat "$T/f1.err")"
grep -qxF "@infra${TAB}catalog/c1.json" "$T/f1.tsv" && ok || bad "F1: a fragment escalate row must put catalog/c1.json in @infra: $(grep '^@infra' "$T/f1.tsv")"
CI_BATCH_ESCALATE_TSV=/dev/null "$FR/bin/test-impact.sh" --root "$FR" inputs > "$T/f2.tsv" 2>/dev/null
cmp -s "$T/f1.tsv" "$T/f2.tsv" && ok || bad "F1: the environment's rules file must not leak into the fingerprint"

# ── S1. a batch select of a changed fragment picks this suite, not the corpus.
printf 'catalog/ci-batch-escalate.d/bh-9999.tsv\n' > "$T/s1.changed"
( cd "$DIR" && TI_BATCH_SELECT=1 bin/test-impact.sh select --changed "$T/s1.changed" --why ) > "$T/s1.out" 2> "$T/s1.err"; rc=$?
{ [ "$rc" = 0 ] && grep -q '^tests/ci-batch-escalate-fragments.bh-8608-test.sh' "$T/s1.out" && ! grep -q $'\tfull\t' "$T/s1.out"; } && ok \
  || bad "S1: rc=$rc; want this suite selected and no full row: $(head -5 "$T/s1.out") $(tail -3 "$T/s1.err")"

# ── X1. the row tests/cross-tree-rows.bh-8573-test.sh prints, pasted into a
# fragment, clears the miss under the composed rules.
X=$(mkroot x1)
inr "$X" cbe_affects spa tests/fixtures/x.bh-0001.json && bad "X1 control: no row, no spa" || ok
printf 'tests/fixtures/x.bh-0001.json\tspa\tconsole-ui/tests/b.test.js reads tests/fixtures/x.bh-0001.json (BH-9999)\n' > "$X/catalog/ci-batch-escalate.d/bh-9999.tsv"
inr "$X" cbe_affects spa tests/fixtures/x.bh-0001.json && ok || bad "X1: a pasted spa row in a fragment must clear the miss"
grep -q 'add to catalog/ci-batch-escalate.d/<TICKET>.tsv' "$DIR/tests/cross-tree-rows.bh-8573-test.sh" && ok \
  || bad "X1: tests/cross-tree-rows.bh-8573-test.sh must tell a miss to add catalog/ci-batch-escalate.d/<TICKET>.tsv"

# ── G1. no bin/ reader outside the lib reads the old file by path. The
# fail-closed text `selection input: catalog/ci-batch-escalate.tsv` is a
# message, not a read.
hits=$(cd "$DIR" && grep -rnF 'catalog/ci-batch-escalate.tsv' bin/ | grep -v '^bin/lib/ci-batch-escalate.sh:' \
       | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vF 'selection input: catalog/ci-batch-escalate.tsv')
[ -z "$hits" ] && ok || bad "G1: these bin/ lines read catalog/ci-batch-escalate.tsv outside the lib: $hits"

echo "ci-batch-escalate-fragments.bh-8608-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
