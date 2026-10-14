#!/bin/bash
# tests/test-impact-test.sh — BH-1203: CI RUNS THE SUITES A DIFF CAN REACH, AND
# EVERYTHING IT CANNOT SEE RUNS EVERYTHING.
#
# After BH-1192 a PR runs the whole corpus in four shards. This lane cuts that
# to the suites the diff could possibly touch — a docs change runs the always-run
# floor, a one-library change runs a fraction, a workflow change still runs all
# of it. No count is written down here: main moves it every week, and a comment
# that drifts is worse than one that says less.
#
# THE FAILURE TO FEAR IS THE SAME ONE BH-1192 NAMED, one level up: a selection
# that drops a suite looks exactly like a fast green. Nobody opens a green
# check. So every case below is about the direction the mistake can go:
#
#   A  the map is deterministic, covers every suite, and is sorted and unique
#   A2 THE CORPUS-WIDE COVERAGE AUDIT: on every line of every suite that names
#      the checkout, every token resolving to a real file is a row of that
#      suite. This is the case BH-1203's review asked for after finding eight
#      suites dropped by a too-narrow idea of what "the checkout" looks like;
#      case B guards one library by hand and missed all eight beside it
#   B  a diff touching one library selects every suite that names that library
#   C  a doc-only diff selects the always-run set and nothing else
#   D  a path no suite maps selects EVERYTHING, and says why
#   E  the infra paths (tests/lib, the runner, this script, workflows, catalog)
#      select everything
#   F  mutation — a map with a row removed really does miss the suite that row
#      was for, which is what makes the map load-bearing rather than decorative
#   G  the orphan ratchet: the scripts no suite names by name. Nothing about the
#      set is committed — the live set is diffed against the MERGE-BASE's, so a
#      new orphan is refused, a fixed one needs no commit, and the two shapes a
#      committed count cannot see (a swap, and a new hole after a fix) are both
#      refused (BH-1268)
#   H  the CI decision — push, train, `full` label and a missing base are all
#      the whole corpus
#   I  both runners take --only-file, refuse an empty or unreadable one, and
#      narrow BEFORE the shard split
#   J  the workflow actually carries the wiring
#
# C, D and F run against a scratch git repository built here, because the
# question is "what does select do with THIS diff" and a real tree gives no way
# to ask it. A, B, G, H, I and J run against the REAL scripts and the REAL
# workflow.
#
# Self-contained: no network, no secrets, no $HARNESS, no clock read, no dice.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
RUNNER="$DIR/bin/test-suite-run.sh"
TRACE="$DIR/bin/test-trace-safety.sh"
WF="${BH1203_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$TI" ] || { echo "FAIL: bin/test-impact.sh is missing or not executable"; echo "test-impact: 0 passed, 1 failed"; exit 1; }
# A missing git is rc 2, not a green: every case below builds a scratch
# repository, so "skipped" here would be a suite that proved nothing while
# reading as a pass (BH-1203 review N4).
command -v git >/dev/null || { echo "test-impact: git is required for this suite"; exit 2; }

# ── A. the map ──────────────────────────────────────────────────────────────
MAP="$T/map.tsv"
"$TI" map --out "$MAP" 2>"$T/map.err"
if [ -s "$MAP" ]; then ok; else bad "A: the map came back empty ($(head -2 "$T/map.err"))"; fi

# Deterministic: same tree, same bytes. A map that moves on its own would make
# every consumer's answer depend on which machine asked.
"$TI" map --out "$T/map2.tsv" 2>/dev/null
if cmp -s "$MAP" "$T/map2.tsv"; then ok
else bad "A: two builds of the map differ:
$(diff "$MAP" "$T/map2.tsv" | head -6)"; fi

# Sorted and unique — the property that makes a diff of two maps readable.
if LC_ALL=C sort -u "$MAP" | cmp -s - "$MAP"; then ok
else bad "A: the map is not sorted-unique"; fi

# Every suite has at least one row: its own file, at minimum. A suite with no
# row would be selected by nothing and would silently stop running.
SUITES=$( cd "$DIR" && ls tests/*.sh tests/mc/*.sh 2>/dev/null | LC_ALL=C sort )
MAPPED=$(cut -f1 "$MAP" | LC_ALL=C sort -u)
MISSING=$(comm -23 <(printf '%s\n' "$SUITES") <(printf '%s\n' "$MAPPED"))
if [ -z "$MISSING" ]; then ok
else bad "A: these suites have no map row at all: $(printf '%s' "$MISSING" | tr '\n' ' ')"; fi

# Every row's path is a real file, a real directory, or the whole tree. A row
# naming something that does not exist is a token the extractor mis-read.
BOGUS=$(cut -f2 "$MAP" | LC_ALL=C sort -u | while IFS= read -r p; do
  [ "$p" = "*" ] && continue
  # TEST-CHANGE (BH-6005.4): worker/<w>/schema.sql is the one generated-path
  # alias the map keeps on purpose (bin/test-impact.sh, BH-6005). It is not in
  # git, so it exists only after a compose; its schema.d/ is the real path.
  case "$p" in worker/*/schema.sql) [ -d "$DIR/${p%schema.sql}schema.d" ] && continue ;; esac
  # TEST-CHANGE (BH-6499): catalog/llm-sites.json is the second generated-path
  # alias (bin/test-impact.sh ti_files, BH-4987); its llm-sites.d/ is the real path.
  case "$p" in catalog/llm-sites.json) [ -d "$DIR/catalog/llm-sites.d" ] && continue ;; esac
  [ -e "$DIR/$p" ] || printf '%s\n' "$p"
done)
if [ -z "$BOGUS" ]; then ok
else bad "A: the map names paths that do not exist: $(head -5 <<<"$BOGUS" | tr '\n' ' ')"; fi

# The always-run set is never empty: it is the floor every selection stands on,
# and a floor of nothing turns a doc-only PR into a green run of no tests.
ALWAYS=$("$TI" always 2>/dev/null)
NALWAYS=$(printf '%s\n' "$ALWAYS" | grep -c .)
if [ "$NALWAYS" -gt 0 ]; then ok; else bad "A: the always-run set is empty"; fi

# ── A2. the corpus-wide coverage audit ─────────────────────────────────────
# THE CASE THAT CATCHES THE WHOLE CLASS. `bin/test-impact.sh audit` re-reads the
# corpus with a cruder, independent rule — on any line that names the checkout,
# every token resolving to a real file must be a row of that suite — and prints
# what the map is missing. It has to print nothing.
#
# It is not decoration. Run against the map BH-1203 shipped for review it prints
# 493 missing rows over 465 suites, including every one of the eight suites that
# review found by hand; run against this map it prints nothing. The mutation
# below proves the same thing without pinning a number that main will drift.
AUDIT=$("$TI" audit 2>"$T/audit.err")
if [ -z "$AUDIT" ]; then ok
else bad "A2: the map is missing rows the corpus audit can see (first 8 of $(printf '%s\n' "$AUDIT" | grep -c .)):
$(head -8 <<<"$AUDIT")"; fi
if [ ! -s "$T/audit.err" ]; then ok
else bad "A2: the audit wrote to stderr: $(head -2 "$T/audit.err")"; fi

# ── A3. the eight suites BH-1203's review found, pinned by name ────────────
# Each of these runs ONE script and reaches the checkout by a spelling the first
# version of this map did not recognise: the inline idiom, its short form, a
# per-suite $H, and python's {DIR}. Each was silently dropped when its script
# changed. They are pinned individually so a future narrowing of the root forms
# names the suite it broke instead of moving a count.
# Covered, not "has this exact row": a suite that reaches a whole directory (the
# python `os.path.join(root, "bin", "share")` case) maps the DIRECTORY, and
# demanding the file row would fail on a map that is doing the right thing.
pin() { # <suite> <path the map must cover for it>
  if awk -F'\t' -v s="$1" -v p="$2" '
       $1 != s { next }
       $2 == "*" || $2 == p { found = 1; exit }
       $2 ~ /\/$/ && index(p, $2) == 1 { found = 1; exit }
       END { exit(found ? 0 : 1) }' "$MAP"; then ok
  else bad "A3: $1 must cover $2 — it runs it (BH-1203 review B1/B2)"; fi
}
pin tests/orc-dedupe-test.sh               bin/lib/orc-dedupe.sh
pin tests/fly-pool-result-gate-test.sh     bin/result-prefix-ok.sh
pin tests/fly-pool-result-gate.bh-540-test.sh bin/result-prefix-ok.sh
pin tests/tg-attribution-test.sh           bin/poll-commands.sh
pin tests/codex-model-capture-test.sh      bin/agent-call.sh
pin tests/jobs-client-retry-test.sh        bin/jobs-client.sh
pin tests/overage-absolute-test.sh         console-ui/src/lib/spend.js
# Round two, B2: the checkout handed to python on the command line and the path
# built piecewise — `python3 - "$DIR"`, `root = sys.argv[1]`,
# `os.path.join(root, "bin", "share")`. Two shapes, both pinned: a join that
# ends in a DIRECTORY the suite then imports from, and one that names a FILE.
pin tests/share-known-fakes-test.sh        bin/share/mapping.py
pin tests/share-leakguard-classes.bh-795-test.sh bin/share/gitleaks-gate.py

# And the audit REPORTS when a row is missing — a check that cannot fail is not
# a check. The row removed is ticket #1203 §4(b) verbatim: tests/orc-dedupe-test.sh
# SOURCES bin/lib/orc-dedupe.sh on its line 6, through `$(dirname "$0")/../`.
HOLE=$(printf 'tests/orc-dedupe-test.sh\tbin/lib/orc-dedupe.sh')
# Second mutation, on a row that only exists because the normaliser folds a
# PIECEWISE python join: os.path.join(d, "bin", "share", "gitleaks-gate.py").
# It proves the audit can see that shape too, which is the half of review B2
# the first mutation says nothing about.
JOINHOLE=$(printf 'tests/share-leakguard-classes.bh-795-test.sh\tbin/share/gitleaks-gate.py')
if grep -qxF "$JOINHOLE" "$MAP"; then ok
else bad "A2: the folded python join row is missing from the map"; fi
grep -vxF "$JOINHOLE" "$MAP" > "$T/map-joinholed.tsv"
JOIN_AUDIT=$("$TI" audit --map "$T/map-joinholed.tsv" 2>/dev/null)
if grep -qxF "$JOINHOLE" <<<"$JOIN_AUDIT"; then ok
else bad "A2: the audit cannot see a piecewise os.path.join — a future one would be invisible"; fi
grep -vxF "$HOLE" "$MAP" > "$T/map-holed.tsv"
HOLED_AUDIT=$("$TI" audit --map "$T/map-holed.tsv" 2>/dev/null)
if grep -qxF "$HOLE" <<<"$HOLED_AUDIT"; then ok
else bad "A2: removing '$(printf '%s' "$HOLE" | tr '\t' ' ')' from the map did not make the audit report it — the audit checks nothing"; fi

# ── B. one library, every suite that names it ───────────────────────────────
# bin/lib/merge-conductor-lib.sh is the biggest shared library in the repo, so
# it is the honest stress case: the selection has to find the suites that name
# it directly AND the ones that only reach it through a script that sources it.
LIB=bin/lib/merge-conductor-lib.sh
printf '%s\n' "$LIB" > "$T/ch-lib"
SEL_LIB=$(awk -F'\t' -v p="$LIB" '$2=="*" || $2==p {print $1}' "$MAP" | LC_ALL=C sort -u)
# Plain grep, not `git grep`: this suite runs against a git-archive export in
# the container gate, where there is no .git and `git grep` would come back
# empty — and an empty expectation is a case that passes by having nothing to
# check, which is the exact shape of failure this file is about.
GREPPED=$( cd "$DIR" && grep -lF merge-conductor-lib tests/*.sh 2>/dev/null | LC_ALL=C sort -u )
# tests/test-sources-lint-test.sh is the one documented divergence and it is
# CORRECT: its only mention is `. "$T/h/bin/lib/merge-conductor-lib.sh"`, a file
# the suite writes into its own scratch fixture. It does not read the repo's
# copy, so a change to the real library cannot affect it. If this set ever grows
# a second member, that member needs the same sentence or the extractor is
# dropping a real dependency — which is the failure this case exists for.
EXPECTED_DIVERGENCE="tests/test-sources-lint-test.sh"
MISSED=$(comm -13 <(printf '%s\n' "$SEL_LIB") <(printf '%s\n' "$GREPPED"))
if [ "$MISSED" = "$EXPECTED_DIVERGENCE" ]; then ok
else bad "B: the suites that name $LIB but are not selected are '$(printf '%s' "$MISSED" | tr '\n' ' ')', expected exactly '$EXPECTED_DIVERGENCE'"; fi

# And the selection is BIGGER than the grep, because of the closure. If it were
# not, the transitive half of the map is doing nothing.
NSEL=$(printf '%s\n' "$SEL_LIB" | grep -c .)
NGREP=$(printf '%s\n' "$GREPPED" | grep -c .)
if [ "$NSEL" -gt "$NGREP" ]; then ok
else bad "B: the selection for $LIB is $NSEL suites and the plain grep finds $NGREP — the source closure found nothing"; fi

# ── the scratch tree that C, D and F ask their questions of ─────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests/lib" "$R/docs" "$R/catalog"
cat > "$R/bin/lib/alpha.sh" <<'SH'
alpha() { echo alpha; }
SH
cat > "$R/bin/beta.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/alpha.sh"
alpha
SH
cat > "$R/tests/beta-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/beta.sh" >/dev/null
echo "beta: 1 passed, 0 failed"
SH
# gamma names the library DIRECTLY. beta reaches it only through bin/beta.sh's
# `source` line. Two suites over one path is what makes case F able to tell
# "the map drives the selection" apart from "the unknown-reach net caught it".
cat > "$R/tests/gamma-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q alpha "$DIR/bin/lib/alpha.sh"
echo "gamma: 1 passed, 0 failed"
SH
cat > "$R/tests/wide-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
git -C "$DIR" ls-files | wc -l
echo "wide: 1 passed, 0 failed"
SH
echo "a note" > "$R/docs/note.md"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

sel() { # <label> -> prints the suites, reason on stderr into $T/reason
  "$TI" --root "$R" select "$BASE..HEAD" 2>"$T/reason"
}

# The scratch tree's own always-run set: wide-test.sh says `git ls-files`.
SALWAYS=$("$TI" --root "$R" always 2>/dev/null)
if [ "$SALWAYS" = "tests/wide-test.sh" ]; then ok
else bad "C: the scratch tree's always-run set should be tests/wide-test.sh, got '$SALWAYS'"; fi

# ── C. a doc-only diff runs the always-run set and nothing more ─────────────
echo "another line" >> "$R/docs/note.md"
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm docs
GOT=$(sel)
if [ "$GOT" = "tests/wide-test.sh" ]; then ok
else bad "C: a doc-only diff selected '$(printf '%s' "$GOT" | tr '\n' ' ')', expected only the always-run set"; fi
if grep -q 'impact: 1 of 3 suites' "$T/reason"; then ok
else bad "C: the reason line should count 1 of 3, got '$(cat "$T/reason")'"; fi

# ── the transitive case: a library nothing names directly ──────────────────
# tests/beta-test.sh names bin/beta.sh, which SOURCES bin/lib/alpha.sh. A diff
# touching alpha.sh has to reach beta-test.sh through that edge, and this is the
# whole reason the map is closed over `source` lines.
echo '# touched' >> "$R/bin/lib/alpha.sh"
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm alpha
GOT=$(sel)
if grep -qxF tests/beta-test.sh <<<"$GOT"; then ok
else bad "C2: a diff on the sourced library did not select tests/beta-test.sh, which reaches it only through bin/beta.sh: '$(printf '%s' "$GOT" | tr '\n' ' ')'"; fi

# ── D. a path no suite maps runs EVERYTHING, and says so ───────────────────
mkdir -p "$R/weird"
echo payload > "$R/weird/thing.dat"
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm weird
GOT=$(sel)
NGOT=$(printf '%s\n' "$GOT" | grep -c .)
if [ "$NGOT" -eq 3 ]; then ok
else bad "D: an unmapped path should select all 3 suites, got $NGOT"; fi
if grep -q 'full: unknown reach (weird/thing.dat)' "$T/reason"; then ok
else bad "D: the reason should name the unknown path, got '$(cat "$T/reason")'"; fi

# ── E. the infra paths run everything ──────────────────────────────────────
# Each case starts from BASE so the diff holds ONE infra path. Left cumulative,
# the loop would break on the first match every time and the later cases would
# be asserting nothing.
infra_full() { # <path>
  local p="$1" d
  git -C "$R" -c user.email=t@example.com -c user.name=t reset -q --hard "$BASE"
  d=$(dirname "$p"); [ "$d" = "." ] || mkdir -p "$R/$d"
  echo "# $p" >> "$R/$p"
  git -C "$R" add -A
  git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm "infra $p"
  local got n
  got=$(sel); n=$(printf '%s\n' "$got" | grep -c .)
  if [ "$n" -eq 3 ] && grep -q "full: infra change ($p)" "$T/reason"; then ok
  else bad "E: a change to $p should run the whole corpus with a named reason, got $n suites / '$(cat "$T/reason")'"; fi
}
infra_full tests/lib/helper.sh
infra_full bin/lib/suite-runner.sh
infra_full bin/lib/docker-host.sh
infra_full bin/test-impact.sh
infra_full .github/workflows/ci.yml
infra_full catalog/knob.conf

# ── F. mutation: the map is load-bearing, and the net is under it ──────────
# Two halves, because a hole in the map has two possible outcomes and both have
# to be the right one:
#
#   F1  hole the ONLY row for a path and the path becomes unmapped, which is
#       `unknown reach` — the whole corpus, loudly. A stale map costs time, not
#       coverage. This is the property that replaces BH-1203's "the drift test
#       catches the stale map": there is no stored map to drift, so the answer
#       had to be structural instead.
#   F2  hole ONE suite's row while another suite still maps the path, and that
#       suite really is dropped. This is what proves the rows do the work — a
#       map whose contents changed nothing would pass every case above.
git -C "$R" -c user.email=t@example.com -c user.name=t reset -q --hard "$BASE"
echo '# touched again' >> "$R/bin/lib/alpha.sh"
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm alpha2
"$TI" --root "$R" map --out "$T/smap.tsv" 2>/dev/null
ROW_BETA=$(printf 'tests/beta-test.sh\tbin/lib/alpha.sh')
ROW_GAMMA=$(printf 'tests/gamma-test.sh\tbin/lib/alpha.sh')
for ROW in "$ROW_BETA" "$ROW_GAMMA"; do
  if grep -qxF "$ROW" "$T/smap.tsv"; then ok
  else bad "F: the map has no row '$(printf '%s' "$ROW" | tr '\t' ' ')' to mutate:
$(cat "$T/smap.tsv")"; fi
done

# F1 — no row at all for the path
grep -vxF "$ROW_BETA" "$T/smap.tsv" | grep -vxF "$ROW_GAMMA" > "$T/smap-none.tsv"
HOLED=$("$TI" --root "$R" --map "$T/smap-none.tsv" select "$BASE..HEAD" 2>"$T/reason2")
if [ "$(grep -c . <<<"$HOLED")" -eq 3 ] &&
   grep -q 'full: unknown reach (bin/lib/alpha.sh)' "$T/reason2"; then ok
else bad "F1: a map with no row for the changed path must fall through to the whole corpus, got '$(printf '%s' "$HOLED" | tr '\n' ' ')' / '$(cat "$T/reason2")'"; fi

# F2 — one suite's row removed, the path still mapped by the other
grep -vxF "$ROW_BETA" "$T/smap.tsv" > "$T/smap-holed.tsv"
HOLED=$("$TI" --root "$R" --map "$T/smap-holed.tsv" select "$BASE..HEAD" 2>/dev/null)
if ! grep -qxF tests/beta-test.sh <<<"$(printf '%s\n' "$HOLED")"; then ok
else bad "F2: removing beta-test's row changed nothing — the map is not what drives the selection"; fi
if grep -qxF tests/gamma-test.sh <<<"$HOLED"; then ok
else bad "F2: gamma-test still maps the path and must still be selected"; fi
WHOLE=$("$TI" --root "$R" --map "$T/smap.tsv" select "$BASE..HEAD" 2>/dev/null)
if grep -qxF tests/beta-test.sh <<<"$WHOLE"; then ok
else bad "F2: the intact map does not select tests/beta-test.sh either — case F proves nothing"; fi

# ── G. the orphan ratchet: a SET DIFF against the merge-base (BH-1268) ─────
# A script no suite names is not a saving, it is a hole: the lane will correctly
# run nothing for a diff that touches it. THE INTENT IS UNCHANGED — this diff
# may fix holes and must not add one — but nothing about the set is committed
# any more. It was: every PR that added a suite naming a previously-orphan
# script had to regenerate catalog/test-impact-orphans.txt or this case went
# red, which hit #842, #1161, #1029, #1212 and #1191 on 2026-09-21 alone.
#
# WHY NOT A COMMITTED COUNT, which is what the ticket first proposed and what
# review B1 refused. A floor only refuses while live == floor; one fixed orphan
# with nobody lowering the number (and nothing requires it) leaves the ratchet
# blind by the width of the slack. G6 and G7 are the two shapes that slips
# through a count and must not slip through this.
#
# G1–G2 ask the real repo; G3–G9 ask a tree built here, because every question
# below is about a different diff and the real one is only ever one diff.

# G1. the derived list is not in git. BH-1175's gate: a PR that puts it back
# must not be able to switch its own ratchet off by doing so.
if [ -z "$(git -C "$DIR" ls-files -- catalog/test-impact-orphans.txt 2>/dev/null)" ]; then ok
else bad "G1: catalog/test-impact-orphans.txt is TRACKED again — the orphan set is derived at check time (BH-1268)"; fi

# G2. this branch adds no orphan, said by the production check against its own
# merge-base — WHERE THERE IS ONE. A checkout with no base is not a pass and not
# a skip: the suite resolves the base itself and asserts the OTHER verdict, the
# rc 2 "no base to compare against". That case is real, not hypothetical — the
# shared Fly test host snapshots the upload as a one-commit repo with no
# origin/main, and a suite that quietly passed there would be reporting on a
# question it never asked.
GBASE=""
if [ -n "${TI_BASE:-}" ] && git -C "$DIR" cat-file -e "$TI_BASE^{commit}" 2>/dev/null; then
  GBASE="$TI_BASE"
else
  for b in origin/main main; do
    git -C "$DIR" cat-file -e "$b^{commit}" 2>/dev/null || continue
    GBASE=$(git -C "$DIR" merge-base HEAD "$b" 2>/dev/null) && [ -n "$GBASE" ] && break
  done
fi
GOUT=$("$TI" orphans --check 2>&1); GRC=$?
if [ -n "$GBASE" ]; then
  if [ "$GRC" = 0 ]; then ok
  else bad "G2: bin/test-impact.sh orphans --check refuses this branch against $GBASE (rc=$GRC):
$GOUT"; fi
else
  if [ "$GRC" = 2 ] && grep -qF 'no base to compare against' <<<"$GOUT"; then
    echo "test-impact: G2 — this checkout has no base (no TI_BASE, no origin/main); asserted the rc 2 path instead"
    ok
  else bad "G2: this checkout has no base, so --check must exit 2 saying so rather than pass (rc=$GRC):
$GOUT"; fi
fi

# ── the tree G3–G9 ask their questions of ──────────────────────────────────
# Two scripts and one suite: bin/mapped.sh is named by a suite, bin/lonely.sh is
# named by nothing. Base orphans = {bin/lonely.sh}, and every case below is a
# different diff on top of that same base.
OR="$T/orepo"
mkdir -p "$OR/bin/lib" "$OR/tests" "$OR/catalog"
cat > "$OR/bin/mapped.sh" <<'SH'
#!/bin/bash
echo mapped
SH
cat > "$OR/bin/lonely.sh" <<'SH'
#!/bin/bash
echo lonely
SH
cat > "$OR/tests/mapped-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/mapped.sh" >/dev/null
echo "mapped: 1 passed, 0 failed"
SH
ogit() { git -C "$OR" -c user.email=t@example.com -c user.name=t "$@"; }
git -C "$OR" init -q -b main
ogit add -A
ogit commit -qm base
OBASE=$(git -C "$OR" rev-parse HEAD)
ogit checkout -q -b work
# ocheck <label> — the check over the fixture, judged against OBASE. Every case
# re-reads it, so no case inherits the previous one's answer.
ocheck() { TI_BASE="$OBASE" "$TI" --root "$OR" orphans --check 2>&1; }
# owork — back to a clean copy of the base, as a new diff on top of it.
owork() { ogit reset -q --hard "$OBASE" && ogit clean -qfd; }

# G3. the fixture is the fixture: exactly one orphan at the base, and it is the
# one nothing names. A ratchet that passes over a tree with no orphans at all
# proves nothing.
OLIST=$("$TI" --root "$OR" orphans 2>/dev/null)
if [ "$OLIST" = "bin/lonely.sh" ]; then ok
else bad "G3: the fixture should have exactly one orphan (bin/lonely.sh), got '$(printf '%s' "$OLIST" | tr '\n' ' ')'"; fi
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 0 ]; then ok
else bad "G3: an unchanged tree must add no orphans (rc=$GRC): $GOUT"; fi

# G4. A NEW ORPHAN IS REFUSED, with no committed list anywhere in the tree.
printf '#!/bin/bash\necho stray\n' > "$OR/bin/stray.sh"
ogit add -A; ogit commit -qm "a script with no suite"
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 1 ]; then ok
else bad "G4: a script no suite names must be refused with rc 1 (got $GRC): $GOUT"; fi
if grep -qF 'bin/stray.sh' <<<"$GOUT"; then ok
else bad "G4: the refusal must NAME the script it is about. Got: $GOUT"; fi
# ...and it must not drag the orphan that was ALREADY there into the refusal:
# bin/lonely.sh is the base's hole, not this diff's.
if ! grep -qF 'bin/lonely.sh' <<<"$(printf '%s' "$GOUT")"; then ok
else bad "G4: the refusal names bin/lonely.sh, which was an orphan at the base — only what this diff ADDS is a finding. Got: $GOUT"; fi

# G5. A FIXED ORPHAN NEEDS NO COMMIT OF ANYTHING ELSE. This is the PR shape
# that used to have to regenerate a list, and the whole reason for the change.
owork
cat > "$OR/tests/lonely-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/lonely.sh" >/dev/null
echo "lonely: 1 passed, 0 failed"
SH
ogit add -A; ogit commit -qm "a suite for the lonely script"
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 0 ]; then ok
else bad "G5: a diff that FIXES an orphan and commits nothing else must pass (rc=$GRC): $GOUT"; fi
if grep -qE '1 fixed' <<<"$GOUT"; then ok
else bad "G5: the pass should report the orphan this diff fixed. Got: $GOUT"; fi
if [ -z "$(git -C "$OR" status --porcelain 2>/dev/null)" ]; then ok
else bad "G5: the check left the tree dirty — it must write nothing into the checkout it is grading"; fi

# G6. THE SWAP, which a committed COUNT cannot see: one orphan fixed and one
# added in the SAME diff. The total is unchanged; the hole is new.
owork
cat > "$OR/tests/lonely-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/lonely.sh" >/dev/null
echo "lonely: 1 passed, 0 failed"
SH
printf '#!/bin/bash\necho stray\n' > "$OR/bin/stray.sh"
ogit add -A; ogit commit -qm "fix one, add one"
OLIST=$("$TI" --root "$OR" orphans 2>/dev/null)
if [ "$OLIST" = "bin/stray.sh" ]; then ok
else bad "G6: the swap fixture should hold exactly one orphan again, got '$(printf '%s' "$OLIST" | tr '\n' ' ')' — the count is unchanged, which is the point"; fi
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 1 ] && grep -qF 'bin/stray.sh' <<<"$GOUT"; then ok
else bad "G6: a swap (one fixed, one added, same total) must be refused by name (rc=$GRC): $GOUT"; fi

# G7. THE DRIFT, the other shape a count misses: the fix and the new hole in
# two separate commits, so the live total never rises above where it started.
owork
cat > "$OR/tests/lonely-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/lonely.sh" >/dev/null
echo "lonely: 1 passed, 0 failed"
SH
ogit add -A; ogit commit -qm "first: fix the hole"
printf '#!/bin/bash\necho stray\n' > "$OR/bin/stray.sh"
ogit add -A; ogit commit -qm "then: add a new one"
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 1 ] && grep -qF 'bin/stray.sh' <<<"$GOUT"; then ok
else bad "G7: a new orphan added AFTER a fix in the same branch must still be refused — this is the state a floor count reads as 'at the floor' (rc=$GRC): $GOUT"; fi
# ...and the same branch with no base given falls back to the merge-base with
# main and answers identically, which is how it runs on a Mac.
GOUT=$(env -u TI_BASE "$TI" --root "$OR" orphans --check 2>&1); GRC=$?
if [ "$GRC" = 1 ] && grep -qF 'bin/stray.sh' <<<"$GOUT"; then ok
else bad "G7: with no TI_BASE the check must fall back to the merge-base with main and reach the same verdict (rc=$GRC): $GOUT"; fi

# G8. a TRACKED list switches nothing off. The derived file is allowed to exist
# on disk — every consumer writes it — but committing it puts the contested cell
# back, so the check refuses it whatever the sets say.
owork
# `git clean -fd` in owork takes the empty catalog/ with it, so the directory is
# remade here rather than assumed.
mkdir -p "$OR/catalog"
"$TI" --root "$OR" orphans --out "$OR/catalog/test-impact-orphans.txt" >/dev/null 2>&1
ogit add -f catalog/test-impact-orphans.txt >/dev/null 2>&1
ogit commit -qm "commit the list" >/dev/null 2>&1
GOUT=$(ocheck); GRC=$?
if [ "$GRC" = 1 ] && grep -qF 'TRACKED' <<<"$GOUT"; then ok
else bad "G8: a TRACKED catalog/test-impact-orphans.txt must be refused with rc 1 (got $GRC): $GOUT"; fi

# G9. A BASE THAT CANNOT BE RESOLVED IS rc 2, NEVER A GREEN. "this diff adds no
# orphan" is a claim, and a run that never saw a base has not made it.
owork
GOUT=$(TI_BASE=0000000000000000000000000000000000000000 "$TI" --root "$OR" orphans --check 2>&1); GRC=$?
if [ "$GRC" = 2 ]; then ok
else bad "G9: an unresolvable TI_BASE must be rc 2, never a pass (got $GRC): $GOUT"; fi

# ── H. the CI decision ─────────────────────────────────────────────────────
# H asks what the CI decision is, not what a particular diff selects, so HEAD is
# put back on a docs-only change first: the selected case below then has one
# knowable answer instead of inheriting whatever case F left behind.
git -C "$R" -c user.email=t@example.com -c user.name=t reset -q --hard "$BASE"
echo "one more line" >> "$R/docs/note.md"
git -C "$R" add -A
git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm docs-again

ci() { # <expected-reason-fragment> <env assignments...>
  local want="$1"; shift
  local out
  out=$(env "$@" "$TI" --root "$R" ci-select --out /dev/null 2>&1)
  case "$out" in
    *"$want"*) ok ;;
    *) bad "H: expected a reason containing '$want', got '$out'" ;;
  esac
}
ci "full: push"                 TI_EVENT=push
ci "full: merge train"          TI_EVENT=pull_request TI_BASE="$BASE" TI_PR_TITLE="merge train: land four"
ci "full: merge train"          TI_EVENT=pull_request TI_BASE="$BASE" TI_PR_TITLE="batch(cromford): land 3 approved siblings as one train"
ci "full: the 'full' label"     TI_EVENT=pull_request TI_BASE="$BASE" TI_PR_TITLE="BH-1: a change" TI_PR_LABELS="ai-build,full"
ci "full: no base sha"          TI_EVENT=pull_request TI_PR_TITLE="BH-1: a change"
ci "full: event"                TI_EVENT=workflow_dispatch
ci "impact: 1 of 3"             TI_EVENT=pull_request TI_BASE="$BASE" TI_PR_TITLE="BH-1: a change" TI_PR_LABELS="ai-build"

# A base sha that is not in the tree must not read as "nothing changed".
ci "full: cannot diff"          TI_EVENT=pull_request TI_BASE=0000000000000000000000000000000000000000 TI_PR_TITLE="BH-1: a change"

# ── I. the runners ─────────────────────────────────────────────────────────
# Both take --only-file, both refuse a list they cannot use, and the narrowing
# happens BEFORE the shard split — otherwise four shards would each take a
# quarter of the corpus and then throw most of it away.
printf 'tests/wide-test.sh\n' > "$T/only-one"
: > "$T/only-empty"

OUT=$( cd "$R" && bash "$RUNNER" --only-file "$T/only-one" tests 2>&1 ); RC=$?
if [ "$RC" -eq 0 ] && grep -q 'impact: 1 of 3 suites' <<<"$OUT"; then ok
else bad "I: test-suite-run --only-file did not narrow to one suite (rc=$RC): $(head -3 <<<"$OUT" | tr '\n' ' ')"; fi
if ! grep -q 'beta-test' <<<"$OUT"; then ok
else bad "I: test-suite-run --only-file ran a suite the list did not name"; fi

OUT=$( cd "$R" && bash "$RUNNER" --only-file "$T/only-empty" tests 2>&1 ); RC=$?
if [ "$RC" -eq 2 ]; then ok
else bad "I: an EMPTY --only-file must be rc 2, not a green run of nothing (rc=$RC)"; fi
OUT=$( cd "$R" && bash "$RUNNER" --only-file "$T/nope" tests 2>&1 ); RC=$?
if [ "$RC" -eq 2 ]; then ok
else bad "I: an unreadable --only-file must be rc 2 (rc=$RC)"; fi

# The narrowing precedes the shard split: one selected suite over four shards is
# one shard with it and three that refuse, never four quarters of the corpus.
HITS=0
for i in 0 1 2 3; do
  OUT=$( cd "$R" && bash "$RUNNER" --shard "$i/4" --only-file "$T/only-one" tests 2>&1 )
  grep -q 'shard .*: 1 of 1 suites' <<<"$OUT" && HITS=$((HITS+1))
done
if [ "$HITS" -eq 1 ]; then ok
else bad "I: over four shards exactly one should carry the single selected suite, $HITS did"; fi

OUT=$("$TRACE" --list --only-file "$T/only-one" "$R" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "tests/wide-test.sh" ]; then ok
else bad "I: test-trace-safety --only-file should list one test, got rc=$RC '$OUT'"; fi
OUT=$("$TRACE" --list --only-file "$T/only-empty" "$R" 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then ok
else bad "I: test-trace-safety must refuse an empty --only-file"; fi

# ── J. the workflow carries the wiring ─────────────────────────────────────
if [ -r "$WF" ]; then ok; else bad "J: $WF is missing"; fi
wf_has() { # <label> <ERE>
  if grep -qE "$2" "$WF"; then ok; else bad "J: $1 — no line matching /$2/ in $WF"; fi
}
# Since 2026-09-24 the selection is asked for once per job through bin/ci-plan.sh
# (which runs ci-select with these inputs — tests/ci-plan-test.sh), and the
# corpus runs once, traced, through bin/test-trace-safety.sh --gate.
wf_has "the plan asks for the selection"          'bin/ci-plan\.sh --out "\$RUNNER_TEMP/impact\.txt"'
wf_has "the traced runner is given the shard"     'test-trace-safety\.sh --gate'
wf_has "the traced runner reads the list"         '\-\-shard "\$SHARD/\$PLAN_N" --only-file "\$RUNNER_TEMP/impact\.txt" \.'
wf_has "the PR title travels as environment"      'TI_PR_TITLE: \$\{\{ github\.event\.pull_request\.title \}\}'
wf_has "the full-corpus button exists"            '^  workflow_dispatch:'

# The checkouts that diff must be deep: the selection diffs against the base
# commit, and a depth-1 clone turns every PR into `full: cannot diff`.
NDEEP=$(grep -c 'fetch-depth: 0' "$WF")
if [ "$NDEEP" -ge 6 ]; then ok
else bad "J: only $NDEEP checkouts ask for full history; plan, the shards, both fan-ins, lint and prompt-evals need it"; fi

# The metered replay must stay off the dispatch button: its gate fails OPEN to
# RUN when it cannot resolve a base commit, and a dispatch has none.
if grep -q "^    if: github.event_name == 'pull_request'$" "$WF"; then ok
else bad "J: prompt-evals is not fenced off the workflow_dispatch trigger — a full-run button would replay 20 metered decisions"; fi

# Every plan step passes the inputs ci-select reads; a step that dropped one
# would decide from a title or head ref it never read.
NSEL=$(grep -c 'bin/ci-plan\.sh --out' "$WF")
NEV=$(grep -c 'CI_EVENT: \${{ github\.event_name }}' "$WF")
NHR=$(grep -c 'TI_PR_HEAD_REF: \${{ github\.event\.pull_request\.head\.ref }}' "$WF")
if [ "$NSEL" -eq "$NEV" ] && [ "$NSEL" -eq "$NHR" ] && [ "$NSEL" -ge 2 ]; then ok
else bad "J: $NSEL plan steps but $NEV CI_EVENT and $NHR TI_PR_HEAD_REF lines (expected the same number, at least 2)"; fi

echo "test-impact: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
