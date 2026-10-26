#!/bin/bash
# tests/security-lens-classes.bh-7911-test.sh — which attack-class notes the
# security lens gets for a diff (BH-7911).
#
# bin/lib/security-lens-classes.sh reads catalog/security-classes.tsv and the
# vendored class files in prompts/security-classes/. The diffs here are real
# `git diff main...HEAD` output of a scratch repo, the same command the review
# stage runs, so the parser sees what production hands it.
#
#   C1-C9  slc_for_diff / slc_check on the committed table and on bad tables
#   P1-P3  PROVENANCE.md names the sha, the licence and every vendored file
#   L1-L3  the SECURITY AUDIT fragment, its topic and the render
# Run from anywhere: tests/security-lens-classes.bh-7911-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/security-lens-classes.sh"
TSV="$DIR/catalog/security-classes.tsv"
CLS="$DIR/prompts/security-classes"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SHA=c1c8a8c1471069fb0e188eeaff69b8e8db6564a8
ORDER="data-isolation web-auth ai-llm cloud-deploy supply-chain client-side resource-exhaustion"

# mkdiff <name> <op>... — build a scratch repo, apply the ops on a branch, and
# write `git diff main...HEAD` to $T/<name>.diff. Ops: "add <path> <line>",
# "del <path>" (the path is created on main first).
mkdiff() {
  local name="$1" r="$T/repo-$1" op p l; shift
  mkdir -p "$r"
  ( cd "$r" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo base > README.md
    for op in "$@"; do
      case "$op" in del\ *) p=${op#del }; mkdir -p "$(dirname "$p")"; echo old > "$p" ;; esac
    done
    git add -A; git -c commit.gpgsign=false commit -qm base
    git checkout -q -b feat
    for op in "$@"; do
      case "$op" in
        add\ *) p=${op#add }; l=${p#* }; p=${p%% *}; mkdir -p "$(dirname "$p")"; printf '%s\n' "$l" >> "$p" ;;
        del\ *) git rm -q "${op#del }" ;;
      esac
    done
    git add -A; git -c commit.gpgsign=false commit -qm work
    git diff main...HEAD ) > "$T/$name.diff" 2>/dev/null
}

# slc <diff> [planned] — run slc_for_diff in a fresh shell; stdout to $T/out,
# stderr to $T/err, rc echoed. SLC_ROOT and the cap come from the caller's env.
slc() {
  local planned="${2:-$T/no-such-planned.txt}"
  bash -c '. "$1" || exit 9; slc_for_diff "$2" "$3"' _ "$LIB" "$1" "$planned" > "$T/out" 2> "$T/err"
  echo $?
}
line1() { head -n1 "$T/out"; }

[ -r "$LIB" ] && ok || bad "bin/lib/security-lens-classes.sh is missing"
[ -r "$TSV" ] && ok || bad "catalog/security-classes.tsv is missing"

# ── C1 two surfaces, in table order ─────────────────────────────────────────
mkdiff c1 "add prisma/migrations/x.sql create table t (id int);" "add src/app/api/route.ts export const GET = 1"
RC=$(SLC_ROOT="$DIR" slc "$T/c1.diff")
[ "$RC" = 0 ] && ok || bad "C1 rc $RC (err: $(head -c 300 "$T/err"))"
[ "$(line1)" = "SLC_CLASSES: data-isolation web-auth" ] && ok || bad "C1 line 1 is '$(line1)'"
[ "$(grep -c '^=== attack class: ' "$T/out")" = 2 ] && ok || bad "C1 expected two class headers, got $(grep -c '^=== attack class: ' "$T/out")"
H1=$(grep -n '^=== attack class: data-isolation (prompts/security-classes/data-isolation.md) ===$' "$T/out" | cut -d: -f1)
H2=$(grep -n '^=== attack class: web-auth (prompts/security-classes/web-auth.md) ===$' "$T/out" | cut -d: -f1)
{ [ -n "$H1" ] && [ -n "$H2" ] && [ "$H1" -lt "$H2" ]; } && ok || bad "C1 headers missing or out of order (data-isolation at '${H1:-}', web-auth at '${H2:-}')"
# The class text is the vendored file, not a paraphrase.
grep -qF -- "$(sed -n 1p "$CLS/data-isolation.md")" "$T/out" && grep -qF -- "$(sed -n 1p "$CLS/web-auth.md")" "$T/out" \
  && ok || bad "C1 the output does not carry the class files' text"
C1_OUT=$(cat "$T/out")
grep -q 'security-lens-classes: truncated' "$T/out" && bad "C1 the default cap truncated two class files" || ok

# ── C2 README only ──────────────────────────────────────────────────────────
mkdiff c2 "add README.md hello"
RC=$(SLC_ROOT="$DIR" slc "$T/c2.diff")
[ "$RC" = 0 ] && ok || bad "C2 rc $RC"
[ ! -s "$T/out" ] && ok || bad "C2 a README-only diff printed: $(head -c 200 "$T/out")"

# ── C3 five surfaces → the first two ────────────────────────────────────────
mkdiff c3 "add prisma/schema.prisma model A {}" "add src/middleware.ts x" "add agents/a.ts x" "add wrangler.toml x" "add package.json {}"
RC=$(SLC_ROOT="$DIR" slc "$T/c3.diff")
[ "$RC" = 0 ] && ok || bad "C3 rc $RC"
[ "$(line1)" = "SLC_CLASSES: data-isolation web-auth" ] && ok || bad "C3 line 1 is '$(line1)'"
[ "$(grep -c '^=== attack class: ' "$T/out")" = 2 ] && ok || bad "C3 more than two classes were printed"

# ── C4 the byte cap ─────────────────────────────────────────────────────────
RC=$(SLC_ROOT="$DIR" SECURITY_LENS_CLASS_MAX_BYTES=500 slc "$T/c1.diff")
[ "$RC" = 0 ] && ok || bad "C4 rc $RC"
[ "$(line1)" = "SLC_CLASSES: data-isolation web-auth" ] && ok || bad "C4 line 1 is '$(line1)'"
MARK='[security-lens-classes: truncated at 500 bytes, SECURITY_LENS_CLASS_MAX_BYTES]'
[ "$(grep -cxF -- "$MARK" "$T/out")" = 1 ] && ok || bad "C4 expected exactly one marker line, got $(grep -cxF -- "$MARK" "$T/out")"
[ "$(tail -n1 "$T/out")" = "$MARK" ] && ok || bad "C4 the marker is not the last line"
BODY=$(tail -n +2 "$T/out" | grep -vxF -- "$MARK" | wc -c)
# head -c 500 may end mid-line; the marker then starts on a new line, so allow that one newline.
[ "$BODY" -le 501 ] && ok || bad "C4 the text after line 1 is $BODY bytes, over the 500-byte cap"
[ "$BODY" -ge 400 ] && ok || bad "C4 the cap cut far too much ($BODY bytes kept of 500)"
for V in abc 0; do
  RC=$(SLC_ROOT="$DIR" SECURITY_LENS_CLASS_MAX_BYTES=$V slc "$T/c1.diff")
  [ "$(cat "$T/out")" = "$C1_OUT" ] && ok || bad "C4 SECURITY_LENS_CLASS_MAX_BYTES=$V did not fall back to the default cap"
done

# ── C5 malformed tables → rc 2 naming the line ──────────────────────────────
mkroot() { # mkroot <name> — a scratch SLC_ROOT with the real class files and the real tsv
  local r="$T/root-$1"
  mkdir -p "$r/catalog" "$r/prompts"
  cp "$TSV" "$r/catalog/security-classes.tsv"
  cp -R "$CLS" "$r/prompts/security-classes"
  printf '%s\n' "$r"
}
R=$(mkroot c5a)
printf '# h\n# h\n# h\nweb-auth\tauth\tnote-only\n' > "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a 3-field row must be rc 2, got $RC"
grep -q 'security-classes.tsv:4:' "$T/err" && ok || bad "C5 stderr does not name line 4: $(cat "$T/err")"
[ ! -s "$T/out" ] && ok || bad "C5 a bad table still printed class text"
RC=$(bash -c '. "$1"; slc_check "$2"' _ "$LIB" "$R/catalog/security-classes.tsv" 2>/dev/null; echo $?)
[ "$RC" = 2 ] && ok || bad "C5 slc_check on a 3-field row must be rc 2, got $RC"
R=$(mkroot c5b)
printf 'web-auth\tauth\t-\tn\nclient-side\t-\t(\tbad ERE\n' > "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a bad ERE must be rc 2, got $RC"
grep -q 'security-classes.tsv:2:' "$T/err" && ok || bad "C5 stderr does not name the bad-ERE line 2: $(cat "$T/err")"
R=$(mkroot c5c)
printf 'web-auth\tauth\t-\tn\nghost-class\tghost\t-\tno file\n' > "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a row with no class file must be rc 2, got $RC"
grep -q 'security-classes.tsv:2:' "$T/err" && ok || bad "C5 stderr does not name the missing-file line 2: $(cat "$T/err")"
R=$(mkroot c5d)
printf 'web-auth\tauth\t-\tn\nweb-auth\tsession\t-\tagain\n' > "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a repeated class must be rc 2, got $RC"
R=$(mkroot c5e)
printf 'web-auth\t-\t-\tmatches nothing\n' > "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a row with both EREs '-' must be rc 2, got $RC"
R=$(mkroot c5f); rm -f "$R/catalog/security-classes.tsv"
RC=$(SLC_ROOT="$R" slc "$T/c1.diff")
[ "$RC" = 2 ] && ok || bad "C5 a missing table must be rc 2, got $RC"
RC=$(SLC_ROOT="$DIR" slc "$T/no-such.diff")
[ "$RC" = 2 ] && ok || bad "C5 a missing diff file must be rc 2, got $RC"

# ── C6 the diff-line axis ───────────────────────────────────────────────────
mkdiff c6a "add src/x.tsx el.innerHTML = v"
RC=$(SLC_ROOT="$DIR" slc "$T/c6a.diff")
[ "$(line1)" = "SLC_CLASSES: client-side" ] && ok || bad "C6 an added innerHTML line gave '$(line1)' (rc $RC)"
mkdiff c6b "add src/x.tsx el.innerText = v"
RC=$(SLC_ROOT="$DIR" slc "$T/c6b.diff")
[ ! -s "$T/out" ] && ok || bad "C6 innerText must not match: $(line1)"

# ── C7 the planned-files axis ───────────────────────────────────────────────
printf 'cron/x.cron\n\n' > "$T/planned.txt"
RC=$(SLC_ROOT="$DIR" slc "$T/c2.diff" "$T/planned.txt")
[ "$(line1)" = "SLC_CLASSES: resource-exhaustion" ] && ok || bad "C7 a planned cron file gave '$(line1)' (rc $RC)"
RC=$(SLC_ROOT="$DIR" slc "$T/c2.diff" "$T/missing-planned.txt")
{ [ "$RC" = 0 ] && [ ! -s "$T/out" ]; } && ok || bad "C7 a missing planned-files file must act like C2 (rc $RC)"

# ── C8 near misses, and a deleted file ──────────────────────────────────────
mkdiff c8 "add src/lib/urls.ts x" "add bin/blocked-resolver.sh x" "add docs/clock.md x"
RC=$(SLC_ROOT="$DIR" slc "$T/c8.diff")
{ [ "$RC" = 0 ] && [ ! -s "$T/out" ]; } && ok || bad "C8 near misses matched: '$(line1)' (rc $RC)"
mkdiff c8d "del prisma/x.sql"
grep -q '^+++ /dev/null' "$T/c8d.diff" && ok || bad "C8 the deleted-file fixture has no '+++ /dev/null' line"
RC=$(SLC_ROOT="$DIR" slc "$T/c8d.diff")
[ "$(line1)" = "SLC_CLASSES: data-isolation" ] && ok || bad "C8 a deleted prisma file gave '$(line1)' (rc $RC)"
mkdiff c8q "add src/sp\"ace/tenant.ts x"
grep -q '^+++ "b/' "$T/c8q.diff" && ok || bad "C8 the quoted-path fixture has no quoted +++ line"
RC=$(SLC_ROOT="$DIR" slc "$T/c8q.diff")
[ "$(line1)" = "SLC_CLASSES: data-isolation" ] && ok || bad "C8 a quoted path gave '$(line1)' (rc $RC)"

# ── C10 case-insensitive paths, and the exact paths the parser reads ────────
mkdiff c10 "add src/Middleware.ts x"
RC=$(SLC_ROOT="$DIR" slc "$T/c10.diff")
[ "$(line1)" = "SLC_CLASSES: web-auth" ] && ok || bad "C10 src/Middleware.ts gave '$(line1)' (rc $RC): matching must be case-insensitive"
P=$(bash -c '. "$1"; _slc_paths "$2"' _ "$LIB" "$T/c8d.diff" | sort -u)
[ "$P" = "prisma/x.sql" ] && ok || bad "C10 the deleted-file paths are '$P', not 'prisma/x.sql' (/dev/null must be skipped)"
P=$(bash -c '. "$1"; _slc_paths "$2"' _ "$LIB" "$T/c8q.diff" | sort -u)
[ "$P" = 'src/sp"ace/tenant.ts' ] && ok || bad "C10 the quoted path parsed as '$P', not 'src/sp\"ace/tenant.ts'"

# ── C9 the committed table ──────────────────────────────────────────────────
RC=$(bash -c '. "$1"; slc_check "$2"' _ "$LIB" "$TSV" 2>"$T/err"; echo $?)
[ "$RC" = 0 ] && ok || bad "C9 slc_check on the committed table rc $RC: $(cat "$T/err")"
ROWS=$(grep -v '^#' "$TSV" | grep -v '^[[:space:]]*$' | cut -f1 | paste -sd' ' -)
[ "$ROWS" = "$ORDER" ] && ok || bad "C9 the rows are '$ROWS', not '$ORDER'"
for C in $ORDER; do [ -s "$CLS/$C.md" ] && ok || bad "C9 no class file for $C"; done

# ── P1-P4 provenance ────────────────────────────────────────────────────────
PROV="$CLS/PROVENANCE.md"
grep -qF "$SHA" "$PROV" && ok || bad "P1 PROVENANCE.md does not name the sha $SHA"
grep -q 'MIT' "$PROV" && ok || bad "P1 PROVENANCE.md does not name the MIT licence"
grep -qF 'Copyright (c) 2025-2026 Cloudflare, Inc.' "$PROV" && ok || bad "P1 PROVENANCE.md lacks the upstream copyright line"
for F in "$CLS"/*; do
  B=$(basename "$F"); [ "$B" = PROVENANCE.md ] && continue
  grep -qF "\`$B\`" "$PROV" && ok || bad "P2 $B is not listed in PROVENANCE.md"
  ROW=$(grep -F "| \`$B\` |" "$PROV")
  grep -qF "$(git hash-object "$F")" <<<"$ROW" && ok || bad "P4 the git blob sha of $B does not match its PROVENANCE.md row"
  grep -qF "| $(wc -c < "$F" | tr -d ' ') |" <<<"$ROW" && ok || bad "P4 the byte count of $B does not match its PROVENANCE.md row"
done
for F in "$CLS"/*.md; do
  B=$(basename "$F" .md); [ "$B" = PROVENANCE ] && continue
  cut -f1 "$TSV" | grep -qxF "$B" && ok || bad "P3 $B.md has no row in catalog/security-classes.tsv"
done

# ── L1-L3 the SECURITY AUDIT law text ───────────────────────────────────────
FRAG="$DIR/prompts/iron-laws.d/20261021-security-audit.md"
TOPIC="$DIR/rules/topics/16-security-audit.md"
W="The lens receives the attack-class notes for the diff's surface; it does not widen its scope beyond the diff."
. "$DIR/bin/lib/stage-iron-laws.sh" || exit 1
for S in review lead-review; do
  X=$(sil_text "$S" "$DIR/prompts/iron-laws.d")
  grep -qF 'SECURITY AUDIT (2026-10-21)' <<<"$X" && ok || bad "L1 sil_text $S lacks SECURITY AUDIT (2026-10-21)"
  grep -qF -- "$W" <<<"$X" && ok || bad "L1 sil_text $S lacks the no-widen sentence"
done
for S in triage execute; do
  X=$(sil_text "$S" "$DIR/prompts/iron-laws.d")
  grep -qF 'SECURITY AUDIT (2026-10-21)' <<<"$X" && bad "L1 sil_text $S must not carry SECURITY AUDIT" || ok
  grep -qF -- "$W" <<<"$X" && bad "L1 sil_text $S must not carry the no-widen sentence" || ok
done
[ "$(sed -n 1p "$FRAG" 2>/dev/null)" = "stages: review lead-review" ] && ok || bad "L1 the fragment's stages line is '$(sed -n 1p "$FRAG" 2>/dev/null)'"
{ [ -s "$FRAG" ] && [ -s "$TOPIC" ] && [ "$(tail -n +3 "$TOPIC")" = "$(tail -n +3 "$FRAG")" ]; } \
  && ok || bad "L2 the topic body is not the fragment body"
[ "$(sed -n 1p "$TOPIC" 2>/dev/null)" = "## Security audit (2026-10-21)" ] && ok || bad "L2 the topic heading is wrong"
"$DIR/bin/render-rules.sh" --root "$DIR" --check >/dev/null 2>&1 && ok || bad "L3 bin/render-rules.sh --check is not green"
grep -qF 'SECURITY AUDIT (2026-10-21)' "$DIR/rules/CLAUDE.md" && ok || bad "L3 rules/CLAUDE.md lacks SECURITY AUDIT"

echo "security-lens-classes.bh-7911-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
