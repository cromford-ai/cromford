#!/bin/bash
# tests/spec-lens-replay.bh-7233-test.sh — BH-7233: the replay manifest can
# name its spec folder with one `# spec-root: <glob>` line, so a manifest row
# carries a short path (`prd-doc/a.md#J01`) and never the folder's real name.
#
# Driven: bin/spec-lens-replay.sh as installed by scratch_install_closure, with
# a stub bin/agent-call.sh beside it, against fixture clones.
#   R1 the directive resolves to one folder; the prompt holds that section
#   R2 near misses are not the directive: the old behaviour (no root), rc 0
#   R3 a glob with 0 matches and --run: rc 2, no call, a header-only ledger
#   R4 a glob with 2 matches and --run: rc 2, no call
#   R5 2 directive lines, a `..` value, a `/abs` value and --run: rc 2, no call
#   R6 R3's manifest with no --run: rc 0, one spec-root warning, no call
#   R7 the root is in the fingerprint: a re-run is a hit, another root a call
#   R8 a ledger row written with the no-root formula is still a hit
#   R9 a prompt over 128 KiB (MAX_ARG_STRLEN) reaches agent-call as @<file>
# The shipped manifest and note (the real project-6-os run of 2026-10-17):
#   M1 the manifest has >= 20 data rows, and its header states that count
#   M2 every data row has 5 columns and a 40-hex merge-sha
#   M3 one `# spec-root:` line; every spec value is `-` or prd-doc/<f>.md#<s>
#   (no person name in the manifest or note: tests/share-publish-clean.bh-795-test.sh
#   builds the public mirror and runs bin/share/leakcheck.py over it)
#   M5 with SPEC_LENS_CLONE=<project-6 clone>: every spec value resolves with
#      st_section at <sha>^1:<root>/<path> (else prints `M5 skip`)
#   N1 the note has the 4 metric bullets (replayed, blocked, cut-exempt, audit
#      items matched), each with a number after its colon, none "owed" or
#      "not measured"
#   N2 each of the 4 bullets names its target: `target (#6485)`
#   N3 the note says why cromford has no rows, and it has exactly one
#      outcome line (`No target missed`, `follow-up: #<n>` or
#      `follow-up not filed`)
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/spec-lens-replay.bh-7233-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export VERDICT_WINDOW_LINES=12 REVIEW_MODEL=stub-model-fixture
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

mkdir -p "$T/h"
scratch_install_closure bin/spec-lens-replay.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The stub: logs the call and its prompt, and answers one delivered row.
cat > "$T/h/bin/agent-call.sh" <<'EOS'
#!/bin/bash
pr=$(basename "$5" .md)
printf '%s\n' "$pr" >> "$CALLS"
case "$6" in @/*) cat "${6#@}" ;; *) printf '%s' "$6" ;; esac > "$PROMPTS/$pr.txt"
printf 'SPEC-TRACE: J01 | ACC-1 | delivered | src/p.ts:1\nVERDICT: APPROVE\n' > "$5"
EOS
chmod +x "$T/h/bin/agent-call.sh"
mkdir -p "$T/prompts"
export CALLS="$T/calls.log" PROMPTS="$T/prompts"
RP="$T/h/bin/spec-lens-replay.sh"
calls() { grep -c . "$CALLS" 2>/dev/null || true; }
GLOB='design/*-proto-2026-10-05/handoff'

# mkclone <dir> <folder>... -> a base commit with prd-doc/a.md under each
# folder, then one merge-like commit; prints that commit's sha.
mkclone() {
  local c="$1" d; shift
  git init -q "$c"; mkdir -p "$c/src"
  for d in "$@"; do
    mkdir -p "$c/$d/prd-doc"
    printf '# PRD fixture\n\n## J01. First\n\n- ACC-1 welcome card in %s\n\n## J02. Next\n\n- ACC-9 other\n' "$d" > "$c/$d/prd-doc/a.md"
  done
  git -C "$c" add -A && git -C "$c" commit -qm base
  echo 'export const p = 1' > "$c/src/p.ts"; git -C "$c" add -A; git -C "$c" commit -qm p
  git -C "$c" rev-parse HEAD
}
C1="$T/c1"; S1=$(mkclone "$C1" design/x-proto-2026-10-05/handoff)
C2="$T/c2"; S2=$(mkclone "$C2" design/x-proto-2026-10-05/handoff design/y-proto-2026-10-05/handoff)

# man <file> <sha> <head lines...> -> a manifest with one mapped row (pr 501).
man() {
  local f="$1" sha="$2"; shift 2
  { printf '%s\n' "$@"; printf 'pr\tmerge-sha\tspec-values\tcut-values\tnote\n'
    printf '501\t%s\tprd-doc/a.md#J01\t-\tfixture spec-root: in a note\n' "$sha"; } > "$f"
}
hdr_only() { [ "$(grep -vc '^#' "$1/ledger.tsv" 2>/dev/null)" = 0 ] && [ -s "$1/ledger.tsv" ]; }

# R1
man "$T/r1.tsv" "$S1" "# spec-root: $GLOB"
: > "$CALLS"
OUT=$("$RP" "$T/r1.tsv" "$C1" "$T/o1" --run 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "R1 one call, rc 0 (rc $RC, calls $(calls)): $OUT"
grep -q '^- ACC-1 welcome card in design/x-proto-2026-10-05/handoff$' "$T/prompts/501.txt" && ok \
  || bad "R1 the prompt holds the J01 section read from the root: $(head -c 900 "$T/prompts/501.txt")"
[ "$(awk -F'\t' '!/^#/ && $2 == 501 {print $3}' "$T/o1/ledger.tsv")" = done ] && ok || bad "R1 one done ledger row: $(cat "$T/o1/ledger.tsv")"
# The same with 2 trailing spaces on the directive line.
man "$T/r1s.tsv" "$S1" "# spec-root: $GLOB  "
OUT=$("$RP" "$T/r1s.tsv" "$C1" "$T/o1s" --run 2>&1)
grep -q '^- ACC-1 welcome card in design/x' "$T/prompts/501.txt" && ok || bad "R1 trailing spaces still name the root: $OUT"

# R2: near misses are no directive; the row's short path is then unreadable.
i=0
for line in "#spec-root: $GLOB" "# spec-root $GLOB" "# spec-roots: $GLOB" "# note"; do
  i=$((i + 1)); rm -f "$T/prompts/501.txt"
  man "$T/r2-$i.tsv" "$S1" "$line"
  OUT=$("$RP" "$T/r2-$i.tsv" "$C1" "$T/o2-$i" --run 2>&1); RC=$?
  [ "$RC" = 0 ] && grep -q 'no file prd-doc/a.md in the repo' "$T/prompts/501.txt" 2>/dev/null && ! grep -q 'spec-root' <<<"$OUT" && ok \
    || bad "R2 '$line' is not the directive (rc $RC): $OUT"
done

# R3
man "$T/r3.tsv" "$S1" "# spec-root: design/*-nothing/handoff"
: > "$CALLS"
OUT=$("$RP" "$T/r3.tsv" "$C1" "$T/o3" --run 2>&1); RC=$?
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && grep -q 'spec-root design/\*-nothing/handoff: 0 ' <<<"$OUT" && grep -q 'nothing was called' <<<"$OUT" && ok \
  || bad "R3 0 matches: rc 2, no call, glob and count named (rc $RC, calls $(calls)): $OUT"
hdr_only "$T/o3" && ok || bad "R3 the ledger has the header only: $(cat "$T/o3/ledger.tsv" 2>&1)"

# R4
man "$T/r4.tsv" "$S2" "# spec-root: $GLOB"
: > "$CALLS"
OUT=$("$RP" "$T/r4.tsv" "$C2" "$T/o4" --run 2>&1); RC=$?
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && grep -q ': 2 ' <<<"$OUT" && hdr_only "$T/o4" && ok \
  || bad "R4 2 matches: rc 2, no call (rc $RC, calls $(calls)): $OUT"

# R5
man "$T/r5a.tsv" "$S1" "# spec-root: $GLOB" "# spec-root: $GLOB"
man "$T/r5b.tsv" "$S1" "# spec-root: ../x"
man "$T/r5c.tsv" "$S1" "# spec-root: /abs"
for f in r5a r5b r5c; do
  : > "$CALLS"
  OUT=$("$RP" "$T/$f.tsv" "$C1" "$T/o-$f" --run 2>&1); RC=$?
  [ "$RC" = 2 ] && [ "$(calls)" = 0 ] && grep -q 'nothing was called' <<<"$OUT" && ok \
    || bad "R5 $f: rc 2, no call (rc $RC, calls $(calls)): $OUT"
done

# R6
: > "$CALLS"
OUT=$("$RP" "$T/r3.tsv" "$C1" "$T/o6" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && [ "$(grep -c 'spec-root' <<<"$OUT")" = 1 ] && grep -q 'dry run, continuing with no root' <<<"$OUT" && grep -q '^spec-lens-replay: rows=1 unmapped=0 ledger-hits=0 calls=0 ' <<<"$OUT" && ok \
  || bad "R6 a dry run warns once and goes on (rc $RC, calls $(calls)): $OUT"

# R7
: > "$CALLS"
OUT=$("$RP" "$T/r1.tsv" "$C1" "$T/o1" --run 2>&1)
[ "$(calls)" = 0 ] && grep -q 'ledger-hits=1 calls=0' <<<"$OUT" && ok || bad "R7 a re-run is a ledger hit: $OUT"
man "$T/r7x.tsv" "$S2" "# spec-root: design/x-proto-*/handoff"
man "$T/r7y.tsv" "$S2" "# spec-root: design/y-proto-*/handoff"
: > "$CALLS"
"$RP" "$T/r7x.tsv" "$C2" "$T/o7" --run >/dev/null 2>&1
OUT=$("$RP" "$T/r7y.tsv" "$C2" "$T/o7" --run 2>&1)
[ "$(calls)" = 2 ] && grep -q '^- ACC-1 welcome card in design/y-proto' "$T/prompts/501.txt" && ok \
  || bad "R7 another root for the same row is a new call (calls $(calls)): $OUT"

# R8: inherited state, a ledger row with the no-root formula.
printf 'pr\tmerge-sha\tspec-values\tcut-values\tnote\n501\t%s\tdocs/prd.md#J01\t-\told\n' "$S1" > "$T/r8.tsv"
mkdir -p "$T/o8"
FP=$(printf '%s\t%s\t%s\t%s' "$S1" docs/prd.md#J01 "" 1 | sha256sum | awk '{print $1}')
printf '# fp\tpr\n%s\t501\tdone\tAPPROVE\tok\t0\t1\t0\t0\t0\t0\t\n' "$FP" > "$T/o8/ledger.tsv"
: > "$CALLS"
OUT=$("$RP" "$T/r8.tsv" "$C1" "$T/o8" --run 2>&1)
[ "$(calls)" = 0 ] && grep -q 'ledger-hits=1 calls=0' <<<"$OUT" && ok || bad "R8 a no-root ledger row is still a hit: $OUT"

# R9: a 200 KB diff makes a prompt over MAX_ARG_STRLEN; inline argv fails E2BIG.
C9="$T/c9"; S9=$(mkclone "$C9" design/x-proto-2026-10-05/handoff)
head -c 150000 /dev/zero | tr '\0' 'a' | fold -w 100 > "$C9/src/big.txt"
git -C "$C9" add -A && git -C "$C9" commit -qm big && S9=$(git -C "$C9" rev-parse HEAD)
man "$T/r9.tsv" "$S9" "# spec-root: $GLOB"
: > "$CALLS"
OUT=$(SPEC_LENS_REPLAY_DIFF_MAX=200000 "$RP" "$T/r9.tsv" "$C9" "$T/o9" --run 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 1 ] && [ "$(wc -c < "$T/prompts/501.txt")" -gt 140000 ] && grep -q '^- ACC-1 welcome card in design/x' "$T/prompts/501.txt" \
  && [ "$(awk -F'\t' '!/^#/ && $2 == 501 {print $3}' "$T/o9/ledger.tsv")" = done ] && ok \
  || bad "R9 a prompt over 128 KiB is called (rc $RC, calls $(calls), prompt $(wc -c < "$T/prompts/501.txt" 2>/dev/null)): $OUT"

# M1-M5, N1-N3: the shipped manifest and note.
TOP="$(cd "$(dirname "$0")/.." && pwd)"
MAN="$TOP/catalog/fixtures/spec-lens-replay/project-6-os-2026-10-12.tsv"
NOTE="$TOP/docs/notes/2026-10-15-BH-6485-spec-trace.md"
data() { awk -F'\t' '!/^#/ && $1 != "pr" && NF > 0' "$MAN"; }
NROWS=$(data | grep -c .)
NMAP=$(data | awk -F'\t' '$3 != "-"' | grep -c .)
[ "$NROWS" -ge 20 ] && grep -qE "^# .*\b$NROWS rows\b" "$MAN" && grep -qE "^# .*\b$NMAP mapped\b" "$MAN" && grep -qE "^# .*\b$((NROWS - NMAP)) unmapped\b" "$MAN" && ok \
  || bad "M1 >= 20 data rows and the header states $NROWS rows, $NMAP mapped, $((NROWS - NMAP)) unmapped: $(grep '^#' "$MAN" | tail -5)"
[ "$(data | awk -F'\t' 'NF != 5 || $2 !~ /^[0-9a-f]{40}$/' | grep -c .)" = 0 ] && ok \
  || bad "M2 rows with not 5 columns or no 40-hex sha: $(data | awk -F'\t' 'NF != 5 || $2 !~ /^[0-9a-f]{40}$/' | head -3)"
BADV=$(data | awk -F'\t' '{print $3; print $4}' | tr ';' '\n' | grep -vxE -- '-|prd-doc/[0-9][0-9]-[a-z0-9-]+\.md#(J[0-5][0-9]|4\.[0-9]{1,2})' | head -3)
[ "$(grep -c '^# spec-root: ' "$MAN")" = 1 ] && [ -z "$BADV" ] && ok \
  || bad "M3 one spec-root line ($(grep -c '^# spec-root: ' "$MAN")), bad values: $BADV"
if [ -n "${SPEC_LENS_CLONE:-}" ]; then
  RG=$(sed -nE 's/^# spec-root:[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1/p' "$MAN")
  RT=""; while IFS= read -r d; do [[ $d == $RG ]] && RT="$d"; done < <(git -C "$SPEC_LENS_CLONE" ls-tree -d -r --name-only HEAD)
  # shellcheck source=bin/lib/spec-trace.sh
  . "$TOP/bin/lib/spec-trace.sh" || exit 1
  unres=0 nv=0
  while IFS=$'\t' read -r _ sha specs cuts _; do
    for v in $(printf '%s;%s' "$specs" "$cuts" | tr ';' ' '); do
      [ "$v" = - ] && continue
      nv=$((nv + 1))
      git -C "$SPEC_LENS_CLONE" show "${sha}^1:$RT/${v%%#*}" > "$T/m5.md" 2>/dev/null \
        && [ -n "$(st_section "$T/m5.md" "${v#*#}" 2>/dev/null)" ] || { unres=$((unres + 1)); echo "M5 unresolved: $sha $v"; }
    done
  done < <(data)
  echo "M5: $unres unresolved of $nv values (root $RT)"
  [ -n "$RT" ] && [ "$unres" = 0 ] && [ "$nv" -gt 0 ] && ok || bad "M5 every spec value resolves"
else
  echo "M5 skip (set SPEC_LENS_CLONE)"
fi
# A bullet is its `- ` line plus its indented continuation lines, joined.
bullets() { awk '/^- /{if(b!="")print b; b=$0; next} /^  [^ ]/ && b!=""{sub(/^ +/," "); b=b $0; next} {if(b!="")print b; b=""} END{if(b!="")print b}' "$NOTE"; }
BUL=$(bullets)
for m in replayed blocked cut-exempt 'audit items matched'; do
  hits=$(grep -F -- "- $m" <<<"$BUL")
  n=$(grep -c . <<<"$hits")
  line=${hits%%$'\n'*}
  { [ "$n" = 1 ] && grep -qE -- "^- $m[^:]*:[[:space:]]*[0-9]" <<<"$line" \
      && ! grep -qiE 'owed|not measured' <<<"$line"; } && ok \
    || bad "N1 one '- $m' bullet with a number, not owed ($n found): ${line:0:160}"
  grep -qF 'target (#6485)' <<<"$line" && ok || bad "N2 '- $m' names its target (#6485): ${line:0:160}"
done
grep -qiE 'cromford has no rows' "$NOTE" && ok || bad "N3 the note names why cromford has no rows"
OUT=$(grep -cE 'No target missed|follow-up: #[0-9]+|follow-up not filed' "$NOTE")
[ "$OUT" = 1 ] && ok || bad "N3 exactly one outcome line in the note ($OUT found)"

echo "spec-lens-replay.bh-7233: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
