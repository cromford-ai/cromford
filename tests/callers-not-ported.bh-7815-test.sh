#!/bin/bash
# tests/callers-not-ported.bh-7815-test.sh — BH-7815: a NOTE when the merge of
# main and the PR head still names a path the PR deletes or renames. The parts:
# bin/lib/callers-not-ported.sh (cnp_scan, psc_cnp_check), the CLI
# bin/callers-not-ported-lint.sh, the self-check rule callers-not-ported
# (catalog/pr-self-check.d/bh-7815-callers-not-ported.tsv, the arm in
# bin/lib/pr-self-check.sh) and the two forwarders into the lead review notes
# (self_check_hold in bin/lead-review-enqueue.sh, lgsc_notes in
# bin/lib/lead-gates-selfcheck.sh).
#
#   A1-A4  the ticket's acceptance cases, through the CLI
#   M1     mutation: grep the head's tree instead of the merge, A1 goes empty
#   B1-B11 the decision rule (which paths, which hits)
#   X1-X4  every failure path prints a line and exits 0
#   S1-S5  the self-check rule and the two forwarders
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/callers-not-ported.bh-7815-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY

H="$T/h"; mkdir -p "$H" "$T/tmp" "$T/b"
[ -r "$SRC/bin/lib/callers-not-ported.sh" ] && [ -r "$SRC/bin/callers-not-ported-lint.sh" ] \
  && [ -r "$SRC/catalog/pr-self-check.d/bh-7815-callers-not-ported.tsv" ] \
  || { echo "FAIL: bin/lib/callers-not-ported.sh, bin/callers-not-ported-lint.sh or the catalog row is missing"; exit 1; }
scratch_install_closure bin/callers-not-ported-lint.sh "$H" >/dev/null || { echo "FAIL: closure of bin/callers-not-ported-lint.sh"; exit 1; }
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
CAT="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
export TMPDIR="$T/tmp"
RULE='callers-not-ported'
TAIL='which this PR deletes or renames; port it after you merge main.'
REALGIT=$(command -v git)

has() { grep -qF -- "$2" <<<"$1"; }
nl()  { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
# mk <case> — a fresh repo $R on main with one commit holding README.
mk() {
  R="$T/r/$1"; mkdir -p "$R"
  git -C "$R" init -q -b main
  printf 'readme\n' > "$R/README"
  git -C "$R" add -A; git -C "$R" commit -qm base
}
put() { mkdir -p "$(dirname "$R/$1")"; printf '%s' "$2" > "$R/$1"; }
cm()  { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }
co()  { git -C "$R" checkout -q "$1"; }
pr()  { git -C "$R" checkout -qb pr main; }   # the PR branch, from main as it is now
cli() { OUT=$(bash "${CLI:-$H/bin/callers-not-ported-lint.sh}" "$@" 2>"$T/cli.err"); RC=$?; }

# ── A1: PR deletes catalog/x.tsv; main then adds a suite that reads it ────────
mk a1; put catalog/x.tsv $'a\tb\n'; cm add-x
pr; git -C "$R" rm -q catalog/x.tsv; cm pr-delete
co main; put tests/a-test.sh $'#!/bin/bash\nDIR=.\ncp "$DIR/catalog/x.tsv" .\n'; cm main-adds-suite
A1SHA=$(git -C "$R" rev-parse main | cut -c1-12)
A1R="$R"
cli --repo "$R" --base main --head pr
WANT_A1="[NOTE] $RULE: tests/a-test.sh:3 still references catalog/x.tsv, $TAIL (tests/a-test.sh was added by $A1SHA, not in this PR's diff)"
{ [ "$RC" = 0 ] && [ "$OUT" = "$WANT_A1" ]; } && ok || bad "A1 main-only suite: want one line rc 0"$'\n'"want: $WANT_A1"$'\n'"got (rc $RC): $OUT"

# ── A2: rename with every caller ported; only the plan names the old path ─────
mk a2; put bin/old.sh $'#!/bin/bash\necho one\necho two\necho three\n'; put tests/t.sh $'bash bin/old.sh\n'; cm add
pr; git -C "$R" mv bin/old.sh bin/new.sh; put tests/t.sh $'bash bin/new.sh\n'
put .harness/specs/BH-1/plan.md $'rename bin/old.sh to bin/new.sh\n'; cm pr-rename
co main; put docs/other.md $'unrelated\n'; cm main-moves
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "A2 rename, callers ported: want no line rc 0, got rc $RC: $OUT"

# ── A3: delete; the only references are a plan and a dated note ───────────────
mk a3; put catalog/y.tsv $'y\n'; cm add
pr; git -C "$R" rm -q catalog/y.tsv
put .harness/specs/BH-1/plan.md $'delete catalog/y.tsv\n'; put docs/notes/2026-10-21-BH-1-x.md $'catalog/y.tsv is gone\n'; cm pr
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "A3 refs only in .harness/specs and docs/notes: want no line, got rc $RC: $OUT"

# ── A4: no delete, no rename: no output and no grep or merge-tree call ───────
mk a4; put bin/a.sh $'echo a\n'; cm add
pr; put bin/a.sh $'echo a2\n'; put bin/b.sh $'cat bin/a.sh\n'; cm pr
co main; put docs/m.md $'m\n'; cm main
mkdir -p "$T/shim4"; LOG4="$T/shim4.log"; : > "$LOG4"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$LOG4" "$REALGIT" > "$T/shim4/git"; chmod +x "$T/shim4/git"
OUT=$(PATH="$T/shim4:$PATH" bash "$H/bin/callers-not-ported-lint.sh" --repo "$R" --base main --head pr 2>&1); RC=$?
{ [ "$RC" = 0 ] && [ -z "$OUT" ] && grep -qE '(^| )diff( |$)' "$LOG4" && ! grep -qE '(^| )(grep|merge-tree)( |$)' "$LOG4"; } \
  && ok || bad "A4 no D/R row: want no line, rc 0, a diff call and no grep/merge-tree call; got rc $RC: $OUT; log: $(tr '\n' ';' < "$LOG4")"

# ── M1: mutation — grep the head's tree, not the merge; A1 must go empty ──────
HM="$T/hm"; mkdir -p "$HM"
scratch_install_closure bin/callers-not-ported-lint.sh "$HM" >/dev/null || bad "M1 setup: closure"
sed -i 's|^\([[:space:]]*\)mt=\$(git -C "\$repo" merge-tree --write-tree .*$|\1mt=$(git -C "$repo" rev-parse "$head^{tree}" 2>/dev/null); mrc=$?|' "$HM/bin/lib/callers-not-ported.sh"
if cmp -s "$HM/bin/lib/callers-not-ported.sh" "$H/bin/lib/callers-not-ported.sh"; then
  bad "M1 setup: the merge-tree line did not change (the mutation is vacuous)"
else
  CLI="$HM/bin/callers-not-ported-lint.sh" cli --repo "$A1R" --base main --head pr
  { [ "$RC" = 0 ] && [ "$OUT" != "$WANT_A1" ] && [ -z "$OUT" ]; } && ok || bad "M1 mutated lib (head tree only) still found the main-only suite: $OUT"
fi

# ── B1: rename, caller on base not ported → NOTE with the add sha ─────────────
mk b1; put bin/old.sh $'echo old\n'; put tests/t.sh $'set -e\nbash bin/old.sh\n'; cm add
B1SHA=$(git -C "$R" rev-parse HEAD | cut -c1-12)
pr; git -C "$R" mv bin/old.sh bin/new.sh; cm pr
cli --repo "$R" --base main --head pr
[ "$OUT" = "[NOTE] $RULE: tests/t.sh:2 still references bin/old.sh, $TAIL (tests/t.sh was added by $B1SHA, not in this PR's diff)" ] \
  && ok || bad "B1 rename, caller left: got: $OUT"

# ── B2: rename with edits (a similarity under 100) ────────────────────────────
mk b2; put lib/x.sh "$(printf 'line %s\n' 1 2 3 4 5 6 7 8 9 10)"$'\n'; put run.sh $'. lib/x.sh\n'; cm add
pr; git -C "$R" mv lib/x.sh lib/y.sh; put lib/y.sh "$(printf 'line %s\n' 1 2 3 4 5 6 7 X Y Z)"$'\n'; cm pr
st=$(git -C "$R" diff --name-status -M main...pr | cut -f1)
cli --repo "$R" --base main --head pr
{ [[ "$st" == R0* || "$st" == R[1-9]* ]] && [ "$st" != R100 ] && has "$OUT" "run.sh:1 still references lib/x.sh"; } \
  && ok || bad "B2 rename with edits ($st): got: $OUT"

# ── B3: a copy is not a delete ────────────────────────────────────────────────
mk b3; put bin/a.sh $'echo a\n'; put run.sh $'bash bin/a.sh\n'; cm add
pr; cp "$R/bin/a.sh" "$R/bin/c.sh"; cm pr
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B3 a copy: want no line, got: $OUT"

# ── B4: main keeps the path (it edits it) → skipped ───────────────────────────
mk b4; put catalog/z.tsv $'z\n'; put tests/r.sh $'cat catalog/z.tsv\n'; cm add
pr; git -C "$R" rm -q catalog/z.tsv; cm pr
co main; put catalog/z.tsv $'z2\n'; cm main-edits
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B4 path still in the merged tree: want no line, got: $OUT"

# ── B5: a reference in a file the PR changed → NOTE without the suffix ────────
mk b5; put catalog/x.tsv $'x\n'; put tests/b.sh $'cat catalog/x.tsv\n'; cm add
pr; git -C "$R" rm -q catalog/x.tsv; put tests/b.sh $'cat catalog/x.tsv\necho more\n'; cm pr
cli --repo "$R" --base main --head pr
[ "$OUT" = "[NOTE] $RULE: tests/b.sh:1 still references catalog/x.tsv, $TAIL" ] && ok || bad "B5 file in the PR diff: want no suffix, got: $OUT"

# B6-B8 share one delete and add one file each on main.
bsetup() { mk "$1"; put catalog/x.tsv $'x\n'; put catalog/w.tsv $'w\n'; cm add
  pr; git -C "$R" rm -q catalog/x.tsv catalog/w.tsv; cm pr; co main; }
# ── B6: boundary negatives ────────────────────────────────────────────────────
bsetup b6; put s.sh $'xcatalog/x.tsv\ncatalog/x.tsv.bak\ncatalog/x.tsvx\ncatalog/x.tsv-old\ncatalog/x.tsv_2\ncatalog/x.tsv/sub\n.catalog/x.tsv\n'; cm m
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B6 boundary negatives: want no line, got: $OUT"
# ── B7: boundary positives ────────────────────────────────────────────────────
bsetup b7; put s.sh $'see catalog/x.tsv.\nf="catalog/x.tsv"\ncatalog/x.tsv\nX=$D/catalog/x.tsv:1\n'; cm m
cli --repo "$R" --base main --head pr
{ [ "$(nl "$OUT")" = 4 ] && has "$OUT" "s.sh:1 still" && has "$OUT" "s.sh:2 still" && has "$OUT" "s.sh:3 still" && has "$OUT" "s.sh:4 still"; } \
  && ok || bad "B7 boundary positives: want 4 lines, got: $OUT"
# ── B8: one line per (file, line, path) ───────────────────────────────────────
bsetup b8; put s.sh $'cp catalog/x.tsv catalog/x.tsv.new; cat catalog/x.tsv\ndiff catalog/x.tsv catalog/w.tsv\n'; cm m
cli --repo "$R" --base main --head pr
{ [ "$(nl "$OUT")" = 3 ] && [ "$(grep -c 's.sh:1 still references catalog/x.tsv,' <<<"$OUT")" = 1 ] \
  && has "$OUT" "s.sh:2 still references catalog/w.tsv," && has "$OUT" "s.sh:2 still references catalog/x.tsv,"; } \
  && ok || bad "B8 multi-hit lines: want 3 lines, got: $OUT"
# B7 order: sorted by file then line, paths sorted inside a line.
first=$(head -1 <<<"$OUT")
has "$first" "s.sh:1 " && ok || bad "B8 order: first line is not s.sh:1: $first"

# ── B9: a binary file is not read ─────────────────────────────────────────────
bsetup b9; printf 'bin\0ary catalog/x.tsv\0\n' > "$R/blob.bin"; cm m
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B9 binary file: want no line, got: $OUT"

# ── B10: 25 hits → 20 lines and `and 5 more` ──────────────────────────────────
bsetup b10; for i in $(seq -w 1 25); do put "t/f$i.sh" $'cat catalog/x.tsv\n'; done; cm m
cli --repo "$R" --base main --head pr
{ [ "$RC" = 0 ] && [ "$(nl "$OUT")" = 21 ] && [ "$(tail -1 <<<"$OUT")" = "[NOTE] $RULE: and 5 more" ] \
  && has "$(head -1 <<<"$OUT")" "t/f01.sh:1 " && has "$(sed -n 20p <<<"$OUT")" "t/f20.sh:1 "; } \
  && ok || bad "B10 cap: want 20 lines + 'and 5 more', got $(nl "$OUT") lines: $(tail -2 <<<"$OUT")"

# ── B11: cron lines, catalog rows and workflow files are read ─────────────────
bsetup b11; put cron/x.cron $'*/5 * * * * root bash bin/a.sh catalog/x.tsv\n'
put catalog/y.tsv $'k\tcatalog/x.tsv\n'; put .github/workflows/z.yml $'on: push\n  run: cat catalog/x.tsv\n'; cm m
cli --repo "$R" --base main --head pr
{ [ "$(nl "$OUT")" = 3 ] && has "$OUT" "cron/x.cron:1 " && has "$OUT" "catalog/y.tsv:1 " && has "$OUT" ".github/workflows/z.yml:2 "; } \
  && ok || bad "B11 cron/catalog/workflow: want 3 lines, got: $OUT"

# ── X1-X4: failure paths, all exit 0 ──────────────────────────────────────────
cli --bogus
{ [ "$RC" = 0 ] && [ -z "$OUT" ] && grep -q '^usage: ' "$T/cli.err"; } && ok || bad "X1 bad args: want usage on stderr, rc 0; got rc $RC: $OUT / $(cat "$T/cli.err")"
cli --head pr
{ [ "$RC" = 0 ] && grep -q '^usage: ' "$T/cli.err"; } && ok || bad "X1b no --base: want usage, rc 0; got rc $RC"
mkdir -p "$T/notgit"
cli --repo "$T/notgit" --base main --head pr
{ [ "$RC" = 0 ] && [[ "$OUT" == "[NOTE] $RULE: could not run: "* ]]; } && ok || bad "X2 not a repo: got rc $RC: $OUT"
mk x3; git -C "$R" checkout -q --orphan lone; printf 'o\n' > "$R/o"; git -C "$R" add -A; git -C "$R" commit -qm lone
cli --repo "$R" --base main --head lone
{ [ "$RC" = 0 ] && [[ "$OUT" == "[NOTE] $RULE: could not run: no merge base of main and "* ]]; } && ok || bad "X3 unrelated histories: got rc $RC: $OUT"
mkdir -p "$T/shim128"
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = merge-tree ] && { echo "fatal: shim" >&2; exit 128; }; done\nexec "%s" "$@"\n' "$REALGIT" > "$T/shim128/git"; chmod +x "$T/shim128/git"
OUT=$(PATH="$T/shim128:$PATH" bash "$H/bin/callers-not-ported-lint.sh" --repo "$A1R" --base main --head pr 2>/dev/null); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "[NOTE] $RULE: could not run: git merge-tree --write-tree failed (rc 128)" ]; } && ok || bad "X4 merge-tree fails: got rc $RC: $OUT"

# ── S1-S3: the self-check rule through bin/pr-self-check.sh ───────────────────
BODY="$T/b/body.md"; printf '## Why\nbecause\n' > "$BODY"
run() { # run <repo> <head> <catalog> [only]
  OUT=$(PR_SELF_CHECK_CATALOG="$3" bash "$H/bin/pr-self-check.sh" check \
        --repo "$1" --base main --head "$2" --body "$BODY" ${4:+--only "$4"} 2>/dev/null); RC=$?
}
WANT_S="NOTE $RULE: tests/a-test.sh:3 still references catalog/x.tsv, $TAIL (tests/a-test.sh was added by $A1SHA, not in this PR's diff)"
mkdir -p "$T/ca/pr-self-check.d" "$T/cb/pr-self-check.d"
cp "$CAT" "$T/ca/pr-self-check.tsv"; cp "$CAT" "$T/cb/pr-self-check.tsv"
cp "$SRC"/catalog/pr-self-check.d/*.tsv "$T/ca/pr-self-check.d/"
cp "$SRC"/catalog/pr-self-check.d/*.tsv "$T/cb/pr-self-check.d/"; rm -f "$T/cb/pr-self-check.d/bh-7815-callers-not-ported.tsv"
run "$A1R" pr "$CAT"; RCA=$RC; OA="$OUT"
run "$A1R" pr "$T/cb/pr-self-check.tsv"; RCB=$RC; OB="$OUT"
{ grep -qxF -- "$WANT_S" <<<"$OA" && [ "$RCA" = "$RCB" ] && ! has "$OB" "$RULE" \
  && [ "$(grep -v "^NOTE $RULE: " <<<"$OA")" = "$OB" ]; } \
  && ok || bad "S1 shipped catalog: want the NOTE line and rc unchanged; rc $RCA vs $RCB"$'\n'"with: $OA"$'\n'"without: $OB"
S1_OUT="$OA"
sed -i "s/^$RULE\tnote\t/$RULE\trefuse\t/" "$T/ca/pr-self-check.d/bh-7815-callers-not-ported.tsv"
grep -q "^$RULE"$'\t'"refuse"$'\t' "$T/ca/pr-self-check.d/bh-7815-callers-not-ported.tsv" || bad "S2 setup: the row did not turn to refuse"
run "$A1R" pr "$T/ca/pr-self-check.tsv" "^$RULE\$"
{ [ "$RC" = 0 ] && [ "$OUT" = "$WANT_S" ]; } && ok || bad "S2 refuse mode: want still one NOTE, rc 0; got rc $RC: $OUT"
sed -i "s/^$RULE\trefuse\t/$RULE\toff\t/" "$T/ca/pr-self-check.d/bh-7815-callers-not-ported.tsv"
run "$A1R" pr "$T/ca/pr-self-check.tsv" "^$RULE\$"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "S3 off mode: want no line, got rc $RC: $OUT"

# ── S4: lgsc_notes forwards the line, `NOTE ` cut ─────────────────────────────
printf '%s\nNOTE body-plan-requires: the body is missing ## X (required by T1)\nREFUSE plan-files: nope\n' "$S1_OUT" > "$T/lgsc.out"
GOT=$(bash -c '. "$1/bin/lib/lead-gates-selfcheck.sh" 2>/dev/null; LGSC_OUT="$2"; lgsc_notes' _ "$SRC" "$T/lgsc.out")
{ has "$GOT" "body-plan-requires: the body is missing ## X (required by T1)" && grep -qxF -- "${WANT_S#NOTE }" <<<"$GOT" \
  && ! has "$GOT" "NOTE " && ! has "$GOT" "plan-files"; } \
  && ok || bad "S4 lgsc_notes: got: $GOT"

# ── S5: self_check_hold's PSCNOTES lines, read from the function body ─────────
EXTRACT=$(awk '/^self_check_hold\(\) \{/{b=1} b && /^[[:space:]]*PSCNOTES=\$\(printf/{print} b && /^}/{exit}' "$SRC/bin/lead-review-enqueue.sh")
[ "$(nl "$EXTRACT")" -ge 2 ] && ok || bad "S5 setup: want 2+ PSCNOTES lines in self_check_hold, got: $EXTRACT"
out=$(cat "$T/lgsc.out")
# shellcheck disable=SC2034 # read by the eval'd PSCNOTES lines
PSCNOTES=""
eval "$EXTRACT"
{ has "$PSCNOTES" "body-plan-requires: the body is missing ## X" && grep -qxF -- "${WANT_S#NOTE }" <<<"$PSCNOTES" \
  && [ "$(nl "$PSCNOTES")" = 2 ]; } \
  && ok || bad "S5 self_check_hold PSCNOTES: got: $PSCNOTES"

echo "callers-not-ported.bh-7815: PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
