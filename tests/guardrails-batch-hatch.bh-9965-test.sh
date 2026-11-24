#!/bin/bash
# tests/guardrails-batch-hatch.bh-9965-test.sh — BH-9965: on a Mergify batch
# draft PR the escape hatch reads the `skip-guardrail` label and the
# `Guardrail-Justification:` line of each SOURCE PR, and a hatch exempts only
# the files that hatched source PR changed.
#
# WHY. Mergify tests a batch on its own draft PR (`mergify/merge-queue/*`). The
# draft carries neither the source PR's labels nor its body, so a hatched check
# passed on the PR's own head and then failed on every batch, and the queue
# ejected the PR until the requeue cap.
#
#   A1-A4  the ticket's acceptance cases, through the REAL rls-on-create-table check
#   P1-P8  the batch-draft decision table (head prefix AND author mergify[bot])
#   F1-F4  failure paths: no metadata, parser negatives, a truncated file list,
#          an API error. Every one fails closed (no file exempt) and says so.
#   C1-C4  the per-file filter in verification-map-freshness,
#          rendered-file-freshness and doc-monolith-edit
#   S1-S2  guardrail_semgrep_excludes (S2 runs semgrep when it is installed)
#   O1     an ordinary PR: the pre-change lib and checks (pinned e6f248aa) vs
#          this head, byte for byte
#   B1     0 real GitHub calls: the GitHub seam is GUARDRAIL_GH (a stub), and a
#          trap `gh` first on PATH fails the suite if anything runs it
# Run: HARNESS_TEST_SANDBOX=1 bash tests/guardrails-batch-hatch.bh-9965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
G="$DIR/guardrails"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

FX="$T/fx"
TRAPDIR="$T/trap"; mkdir -p "$TRAPDIR"
printf '#!/bin/bash\ntouch "%s/trap-hit"\nexit 99\n' "$T" > "$TRAPDIR/gh"
chmod +x "$TRAPDIR/gh"

# The GitHub fake: serves $FX/pr-<n>.json and $FX/files-<n>.json, logs every
# call, fails a PR when $FX/fail-<n> exists, and exits 1 on any other call.
STUB="$T/gh-stub"
cat > "$STUB" <<EOF
#!/bin/bash
FX="$FX"
EOF
cat >> "$STUB" <<'EOF'
echo "$*" >> "$FX/calls.log"
[ "${1:-}" = api ] || { echo "stub: not an api call: $*" >&2; exit 1; }
shift
pag=""; [ "${1:-}" = --paginate ] && { pag=1; shift; }
case "${1:-}" in
  repos/o/r/pulls/*/files) n=${1#repos/o/r/pulls/}; n=${n%/files}
                           [ -n "$pag" ] || { echo "stub: files without --paginate" >&2; exit 1; }
                           f="$FX/files-$n.json" ;;
  repos/o/r/pulls/*)       n=${1#repos/o/r/pulls/}; f="$FX/pr-$n.json" ;;
  *) echo "stub: unexpected call: $*" >&2; exit 1 ;;
esac
[ -e "$FX/fail-$n" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
[ -f "$f" ] || { echo "stub: no fixture $f" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$STUB"

JUST='Guardrail-Justification: legacy table, RLS lands in the follow-up migration'
reset_fx() { scratch_rm "$FX" || exit 1; mkdir -p "$FX"; : > "$FX/calls.log"; }
# pr <n> <labels-csv> <body> [changed_files]
pr() {
  jq -n --arg l "$2" --arg b "$3" --argjson c "${4:-0}" \
    '{number: 0, labels: ($l | split(",") | map(select(. != "")) | map({name: .})), body: $b, changed_files: $c}' \
    > "$FX/pr-$1.json"
}
# files <n> <path>... — written as TWO arrays when there are 2+, the way
# `gh api --paginate` concatenates pages. A path "old=>new" is a rename.
files() {
  local n=$1; shift
  local all; all=$(for p in "$@"; do
    case "$p" in
      *'=>'*) jq -nc --arg o "${p%%=>*}" --arg f "${p#*=>}" '{filename: $f, previous_filename: $o, status: "renamed"}' ;;
      *)      jq -nc --arg f "$p" '{filename: $f, status: "modified"}' ;;
    esac
  done | jq -s .)
  local len; len=$(jq length <<<"$all")
  if [ "$len" -ge 2 ]; then
    { jq -c '.[0:1]' <<<"$all"; jq -c '.[1:]' <<<"$all"; } > "$FX/files-$n.json"
  else
    printf '%s\n' "$all" > "$FX/files-$n.json"
  fi
  # changed_files of the PR record follows the list unless the case set it
  local cur; cur=$(jq .changed_files "$FX/pr-$n.json")
  [ "$cur" = 0 ] && jq --argjson c "$len" '.changed_files = $c' "$FX/pr-$n.json" > "$FX/t" && mv "$FX/t" "$FX/pr-$n.json"
  return 0
}
# draft_body <n>... — the live Mergify layout (guardrails/lib/fixtures/mergify-draft-body.md)
draft_body() {
  printf '# Merge Queue: batch\n\nThis pull request has been created by Mergify.\n\n---\n\n<details>\n<summary>Metadata for CI tooling</summary>\n\n```yaml\n---\nchecking_base_sha: e6f248aa\nprevious_failed_batches: []\npull_requests:\n'
  for n in "$@"; do printf '  - number: %s\n    scopes: []\n' "$n"; done
  printf '...\n\n```\n\n</details>\n'
}
W="$T/w"
fresh_w() { scratch_rm "$W" || exit 1; mkdir -p "$W/migrations"; }
violate() { printf 'CREATE TABLE "%s" (id int);\n' "${1%.sql}" > "$W/migrations/$1"; }

HEADREF='mergify/merge-queue/default/abc123'
AUTHOR='mergify[bot]'
# runb <draft body> <cmd...> -> OUT, RC. A batch-draft CI env with the stub as
# the GitHub seam and the trap first on PATH. The draft's OWN labels/body come
# from DRAFT_LABELS / DRAFT_JUST (default none).
runb() {
  local body=$1; shift
  OUT=$(cd "$W" && env GUARDRAIL_HEAD_REF="$HEADREF" GUARDRAIL_PR_AUTHOR="$AUTHOR" \
      GUARDRAIL_DRAFT_BODY="$body" GITHUB_REPOSITORY=o/r GUARDRAIL_GH="$STUB" \
      PR_LABELS="${DRAFT_LABELS:-}" GUARDRAIL_JUSTIFICATION="${DRAFT_JUST:-}" \
      PATH="$TRAPDIR:$PATH" "$@" 2>&1); RC=$?
}
has()   { grep -qF -- "$1" <<<"$OUT"; }
calls() { grep -c . "$FX/calls.log"; }
RLS="$G/rls-on-create-table/check.sh"

# ── A1: one hatched source PR -> the hatched guardrail passes for its files ──
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "Moves the table.
$JUST"
files 101 migrations/a.sql
runb "$(draft_body 101)" "$RLS"
[ "$RC" = 0 ] && ok || bad "A1: hatched source PR's own file still failed the batch (rc=$RC): $OUT"
has 'GUARDRAIL rls-on-create-table: batch draft: #101 hatched (Justification: legacy table, RLS lands in the follow-up migration); 1 file(s) exempt.' \
  && ok || bad "A1: no exact batch summary line: $OUT"
[ "$(calls)" = 2 ] && ok || bad "A1: want 2 GitHub calls (pr + files), got $(calls)"

# ── A2: + a non-hatched PR that breaks the same guardrail -> batch fails ─────
# The draft body is the committed live-format fixture, verbatim (PRs 101, 102).
reset_fx; fresh_w; violate a.sql; violate b.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
pr 102 "" "Adds b."; files 102 migrations/b.sql
runb "$(cat "$G/lib/fixtures/mergify-draft-body.md")" "$RLS"
[ "$RC" = 1 ] && ok || bad "A2: a non-hatched PR's violation passed the batch (rc=$RC)"
has 'migrations/b.sql creates a table but never enables RLS.' && ok || bad "A2: b.sql not named: $OUT"
has 'migrations/a.sql creates a table' && bad "A2: the hatched PR's a.sql was still checked: $OUT" || ok
has '#101 hatched' && ok || bad "A2: no '#101 hatched' line"
has '#102 hatched' && bad "A2: #102 reported hatched" || ok

# ── A3: label and no justification line -> fails with the existing message ──
reset_fx; fresh_w; violate c.sql
pr 103 skip-guardrail "No marker in this body at all, just prose that goes on a while."
files 103 migrations/c.sql
runb "$(draft_body 103)" "$RLS"
[ "$RC" = 1 ] && ok || bad "A3: label-only source PR passed (rc=$RC)"
grep -A1 -xF 'GUARDRAIL rls-on-create-table: batch source PR #103:' <<<"$OUT" | tail -1 \
  | grep -qxF "GUARDRAIL rls-on-create-table: 'skip-guardrail' label present, but no usable justification." \
  && ok || bad "A3: the existing message does not follow the source PR header: $OUT"
has 'migrations/c.sql creates a table but never enables RLS.' && ok || bad "A3: c.sql not reported"
[ "$(calls)" = 1 ] && ok || bad "A3: no source PR hatched, want 1 call (no file list), got $(calls)"

# ── A4: a file both a hatched and a non-hatched PR changed is checked ───────
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
pr 102 "" ""; files 102 migrations/a.sql
runb "$(draft_body 101 102)" "$RLS"
[ "$RC" = 1 ] && ok || bad "A4: shared file exempted by one PR's hatch (rc=$RC)"
has 'migrations/a.sql creates a table but never enables RLS.' && ok || bad "A4: a.sql not named"
has '0 file(s) exempt.' && ok || bad "A4: want '0 file(s) exempt.': $OUT"

# ── P1-P8: is this a batch draft? head prefix AND author mergify[bot] ───────
# The draft itself carries a valid label + marker: an ordinary PR skips on it
# (rc 0); a batch draft ignores it and reads the source PRs (rc 1 + batch line).
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 src/x.ts
p_row() { # p_row <id> <head|-unset-> <author> <yes|no>
  local hv=$2
  OUT=$(env -u GUARDRAIL_HEAD_REF GUARDRAIL_PR_AUTHOR="$3" GUARDRAIL_DRAFT_BODY="$(draft_body 101)" \
      GITHUB_REPOSITORY=o/r GUARDRAIL_GH="$STUB" PATH="$TRAPDIR:$PATH" \
      PR_LABELS=skip-guardrail GUARDRAIL_JUSTIFICATION="$JUST" \
      bash -c '[ "$1" = -unset- ] || export GUARDRAIL_HEAD_REF="$1"; . "$2"; guardrail_escape_hatch pcheck' _ "$hv" "$G/lib/escape-hatch.sh" 2>&1); RC=$?
  if [ "$4" = yes ]; then
    [ "$RC" = 1 ] && has 'GUARDRAIL pcheck: batch draft: #101 hatched' && ! has 'SKIPPED via skip-guardrail label.' && ok \
      || bad "$1: head '$2' author '$3' is a batch draft, but got rc=$RC: $OUT"
  else
    [ "$RC" = 0 ] && has 'GUARDRAIL pcheck: SKIPPED via skip-guardrail label.' && ! has 'batch' && ok \
      || bad "$1: head '$2' author '$3' is NOT a batch draft, but got rc=$RC: $OUT"
  fi
}
p_row P1 mergify/merge-queue/abc          'mergify[bot]' yes
p_row P2 mergify/merge-queue/x/y          'mergify[bot]' yes
p_row P3 mergify/merge-queue/abc          alice          no
p_row P4 feature/mergify/merge-queue/x    'mergify[bot]' no
p_row P5 mergify/merge-queue              'mergify[bot]' no
p_row P6 Mergify/merge-queue/x            'mergify[bot]' no
p_row P7 -unset-                          'mergify[bot]' no
p_row P8 mergify/merge-queue/abc          mergify        no

# ── F1: no metadata block -> could-not-read line, nothing exempt ────────────
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
runb "Merge Queue: checking #101 and #102 together." "$RLS"
[ "$RC" = 1 ] && ok || bad "F1: no metadata block, but the batch passed (rc=$RC)"
has 'GUARDRAIL rls-on-create-table: batch draft: could not read source PR(s) (no source PR number in the draft body); no file is exempt.' \
  && ok || bad "F1: no could-not-read line: $OUT"
has 'migrations/a.sql creates a table but never enables RLS.' && ok || bad "F1: violation not reported"
[ "$(calls)" = 0 ] && ok || bad "F1: want 0 calls, got $(calls)"

# ── F2: the body parser, live format and negatives ──────────────────────────
parse() { bash -c '. "$1"; . "$2"; guardrail_batch_prs "$3"' _ "$G/lib/escape-hatch.sh" "$G/lib/batch-hatch.sh" "$1" 2>&1; }
[ "$(parse "$(cat "$G/lib/fixtures/mergify-draft-body.md")")" = $'101\n102' ] && ok || bad "F2: live fixture did not give 101 102: $(parse "$(cat "$G/lib/fixtures/mergify-draft-body.md")")"
[ "$(parse "$(draft_body 9960)")" = 9960 ] && ok || bad "F2: one PR"
[ "$(parse "$(draft_body 101 102 | sed 's/$/\r/')")" = $'101\n102' ] && ok || bad "F2: CRLF body"
[ -z "$(parse 'Batch of #9960 and #9961. number: 9962')" ] && ok || bad "F2: markdown mention counted"
[ -z "$(parse "$(printf 'pull_requests:\nother:\n  - number: 101\n')")" ] && ok || bad "F2: number under another key counted"
[ -z "$(parse "$(printf 'pull_requests:\n  - number: abc\n')")" ] && ok || bad "F2: non-digit number counted"
[ -z "$(parse "$(printf 'pull_requests:\n  - number: 101x\n')")" ] && ok || bad "F2: '101x' counted"
[ -z "$(parse "$(printf '  pull_requests:\n  - number: 101\n')")" ] && ok || bad "F2: indented pull_requests: key counted"
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
runb 'Batch of #101 (checking).' "$RLS"
[ "$RC" = 1 ] && has 'could not read source PR(s)' && has 'migrations/a.sql creates' && ok \
  || bad "F2: '#101' in markdown only exempted something (rc=$RC): $OUT"

# ── F3: a truncated file list of a NON-hatched PR -> nothing exempt ─────────
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
pr 102 "" "" 5; files 102 src/x.ts src/y.ts src/z.ts
runb "$(draft_body 101 102)" "$RLS"
[ "$RC" = 1 ] && ok || bad "F3: truncated non-hatched list, but the batch passed (rc=$RC)"
has 'GUARDRAIL rls-on-create-table: batch draft: could not read source PR(s) (file list of #102 is incomplete: 3 of 5); no file is exempt.' \
  && ok || bad "F3: no truncation line: $OUT"
has 'migrations/a.sql creates a table but never enables RLS.' && ok || bad "F3: hatched file not reported"
# a truncated list of the HATCHED PR exempts only the fetched files
reset_fx; fresh_w; violate a.sql; violate b.sql
pr 101 skip-guardrail "$JUST" 4; files 101 migrations/a.sql
runb "$(draft_body 101)" "$RLS"
[ "$RC" = 1 ] && has 'migrations/b.sql creates' && ! has 'migrations/a.sql creates' && has '1 file(s) exempt.' && ok \
  || bad "F3: truncated hatched list: want only the fetched a.sql exempt (rc=$RC): $OUT"

# ── F4: the API fails for a source PR -> named, nothing exempt ──────────────
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql; touch "$FX/fail-101"
runb "$(draft_body 101)" "$RLS"
[ "$RC" = 1 ] && ok || bad "F4: API failure, but the batch passed (rc=$RC)"
has 'GUARDRAIL rls-on-create-table: batch draft: could not read source PR(s) (could not read source PR #101); no file is exempt.' \
  && ok || bad "F4: no could-not-read line naming #101: $OUT"
has 'migrations/a.sql creates a table but never enables RLS.' && ok || bad "F4: violation not reported"
# the files call fails -> also fail closed
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; rm -f "$FX/files-101.json"
runb "$(draft_body 101)" "$RLS"
[ "$RC" = 1 ] && has 'could not read source PR(s) (could not read the file list of #101)' && ok \
  || bad "F4: files-call failure did not fail closed (rc=$RC): $OUT"
# no GITHUB_REPOSITORY -> fail closed
reset_fx; fresh_w; violate a.sql
OUT=$(cd "$W" && env -u GITHUB_REPOSITORY GUARDRAIL_HEAD_REF="$HEADREF" GUARDRAIL_PR_AUTHOR="$AUTHOR" \
    GUARDRAIL_DRAFT_BODY="$(draft_body 101)" GUARDRAIL_GH="$STUB" PATH="$TRAPDIR:$PATH" "$RLS" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -qF 'could not read source PR(s) (GITHUB_REPOSITORY is not set)' <<<"$OUT" && ok \
  || bad "F4: no GITHUB_REPOSITORY did not fail closed (rc=$RC): $OUT"
# the batch lib missing -> one line, run the check on every file
cp -r "$G" "$T/g-nolib"; rm -f "$T/g-nolib/lib/batch-hatch.sh"
reset_fx; fresh_w; violate a.sql
pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
runb "$(draft_body 101)" "$T/g-nolib/rls-on-create-table/check.sh"
[ "$RC" = 1 ] && has 'GUARDRAIL rls-on-create-table: batch draft: could not read source PR(s) (guardrails/lib/batch-hatch.sh is missing); no file is exempt.' \
  && has 'migrations/a.sql creates' && ok || bad "F4: missing batch lib did not fail closed (rc=$RC): $OUT"

# ── C1-C4: the per-file filter in the other three shell checks ──────────────
VM="$G/verification-map-freshness/check.sh"
fresh_w; mkdir -p "$W/docs/verification-map"
printf 'src/app/x/page.tsx\n' > "$W/changed.txt"
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 src/app/x/page.tsx
runb "$(draft_body 101)" env VMAP_FILES="$W/changed.txt" "$VM"
[ "$RC" = 0 ] && ok || bad "C1: hatched route file still failed vmap (rc=$RC): $OUT"
reset_fx; pr 101 "" ""; files 101 src/app/x/page.tsx
runb "$(draft_body 101)" env VMAP_FILES="$W/changed.txt" "$VM"
[ "$RC" = 1 ] && grep -qF '    src/app/x/page.tsx' <<<"$OUT" && ok || bad "C1: non-hatched route file passed vmap (rc=$RC)"
# C4: hatched PR edits the map, non-hatched PR edits a route -> map side counts
printf 'docs/verification-map/entries/x.md\nsrc/app/y/page.tsx\n' > "$W/changed.txt"
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 docs/verification-map/entries/x.md
pr 102 "" ""; files 102 src/app/y/page.tsx
runb "$(draft_body 101 102)" env VMAP_FILES="$W/changed.txt" "$VM"
[ "$RC" = 0 ] && ok || bad "C4: the map edit of a hatched PR stopped counting (rc=$RC): $OUT"

RFF="$G/rendered-file-freshness/check.sh"
fresh_w; mkdir -p "$W/frag"; printf 'out/gen.txt\n' > "$W/changed.txt"
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 out/gen.txt
runb "$(draft_body 101)" env RFF_MAP='out/gen.txt|frag/|bin/render.sh --write' RFF_FILES="$W/changed.txt" RFF_ROOT="$W" "$RFF"
[ "$RC" = 0 ] && ok || bad "C2: hatched rendered file still failed rff (rc=$RC): $OUT"
reset_fx; pr 101 "" ""; files 101 out/gen.txt
runb "$(draft_body 101)" env RFF_MAP='out/gen.txt|frag/|bin/render.sh --write' RFF_FILES="$W/changed.txt" RFF_ROOT="$W" "$RFF"
[ "$RC" = 1 ] && grep -qF '    out/gen.txt' <<<"$OUT" && ok || bad "C2: non-hatched rendered file passed rff (rc=$RC): $OUT"

DM="$G/doc-monolith-edit/check.sh"
fresh_w; mkdir -p "$W/docs"; printf 'one\ntwo\nthree\n' > "$W/docs/A.md"
cat > "$W/pr.diff" <<'EOF'
diff --git a/docs/A.md b/docs/A.md
index 1111111..2222222 100644
--- a/docs/A.md
+++ b/docs/A.md
@@ -1,2 +1,3 @@
 one
+two
 three
EOF
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 docs/A.md
runb "$(draft_body 101)" env DOC_MONOLITHS=docs/A.md DOC_MONOLITH_DIFF="$W/pr.diff" "$DM"
[ "$RC" = 0 ] && ok || bad "C3: hatched doc edit still failed doc-monolith (rc=$RC): $OUT"
reset_fx; pr 101 "" ""; files 101 docs/A.md
runb "$(draft_body 101)" env DOC_MONOLITHS=docs/A.md DOC_MONOLITH_DIFF="$W/pr.diff" "$DM"
[ "$RC" = 1 ] && has '    docs/A.md' && ok || bad "C3: non-hatched doc edit passed doc-monolith (rc=$RC): $OUT"
# a rename's OLD name in a hatched PR is exempt too
reset_fx; pr 101 skip-guardrail "$JUST"; files 101 'docs/A.md=>docs/B.md'
runb "$(draft_body 101)" env DOC_MONOLITHS=docs/A.md DOC_MONOLITH_DIFF="$W/pr.diff" "$DM"
[ "$RC" = 0 ] && ok || bad "C3: a hatched rename's previous_filename was not exempt (rc=$RC): $OUT"

# ── S1-S2: the semgrep exclude helper ───────────────────────────────────────
S=$(bash -c '. "$1"; GUARDRAIL_EXEMPT=$'"'"'src/a.ts\nsrc/b c.ts\nsrc/*.ts'"'"'; guardrail_semgrep_excludes' _ "$G/lib/escape-hatch.sh")
[ "$S" = $'--exclude=src/a.ts\n--exclude=src/b c.ts' ] && ok || bad "S1: excludes wrong (a glob path must never widen): $S"
S=$(bash -c '. "$1"; guardrail_semgrep_excludes' _ "$G/lib/escape-hatch.sh")
[ -z "$S" ] && ok || bad "S1: excludes not empty with nothing exempt: $S"
# an exempt list in the ambient env never reaches a check: sourcing resets it
S=$(GUARDRAIL_EXEMPT=src/a.ts bash -c '. "$1"; printf "src/a.ts\n" | guardrail_drop_exempt' _ "$G/lib/escape-hatch.sh")
[ "$S" = src/a.ts ] && ok || bad "S1: an ambient GUARDRAIL_EXEMPT dropped a file"
if command -v semgrep >/dev/null 2>&1; then
  fresh_w; mkdir -p "$W/src"; cp "$G/hardcoded-model-ids/fixtures/violation.ts" "$W/src/a.ts"
  semgrep_batch() { # semgrep_batch <labels of PR 101>
    reset_fx; pr 101 "$1" "$JUST"; files 101 src/a.ts
    runb "$(draft_body 101)" bash -c '. "$1"; guardrail_escape_hatch hardcoded-model-ids && exit 0
      mapfile -t EX < <(guardrail_semgrep_excludes)
      semgrep --metrics=off --quiet --disable-version-check --config "$2" --error "${EX[@]}" .' _ "$G/lib/escape-hatch.sh" "$G/hardcoded-model-ids/rule.yml"
  }
  semgrep_batch skip-guardrail
  [ "$RC" = 0 ] && ok || bad "S2: semgrep still failed on the hatched PR's file (rc=$RC): $OUT"
  semgrep_batch ""
  [ "$RC" = 1 ] && ok || bad "S2: semgrep passed a non-hatched PR's violation (rc=$RC): $OUT"
else
  echo "S2: semgrep not installed — skipped"
fi

# ── O1: an ordinary PR is byte for byte as before (merge-base lib + checks) ─
# The "before" is pinned: e6f248aa is main just before BH-9965 (it never moves,
# D60). The merge base is only the fallback for a clone that lacks it.
BASE=e6f248aafdc0c95dd049a7143060267b9a9945fd
git -C "$DIR" cat-file -e "$BASE^{commit}" 2>/dev/null \
  || BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null || true)
mkdir -p "$T/old"
if [ -z "$BASE" ]; then
  echo "O1: skipped — neither the pinned pre-change commit nor origin/main is in this clone"
elif git -C "$DIR" archive "$BASE" guardrails | tar -x -C "$T/old"; then
  o_row() { # o_row <id> <labels> <justification> [head] [author]
    local o n
    o=$(env PR_LABELS="$2" GUARDRAIL_JUSTIFICATION="$3" GUARDRAIL_HEAD_REF="${4:-}" GUARDRAIL_PR_AUTHOR="${5:-}" \
        GUARDRAIL_DRAFT_BODY="$(draft_body 101)" GITHUB_REPOSITORY=o/r GUARDRAIL_GH="$STUB" PATH="$TRAPDIR:$PATH" \
        bash -c '. "$1"; guardrail_escape_hatch ocheck; echo "rc=$?"' _ "$T/old/guardrails/lib/escape-hatch.sh" 2>&1)
    n=$(env PR_LABELS="$2" GUARDRAIL_JUSTIFICATION="$3" GUARDRAIL_HEAD_REF="${4:-}" GUARDRAIL_PR_AUTHOR="${5:-}" \
        GUARDRAIL_DRAFT_BODY="$(draft_body 101)" GITHUB_REPOSITORY=o/r GUARDRAIL_GH="$STUB" PATH="$TRAPDIR:$PATH" \
        bash -c '. "$1"; guardrail_escape_hatch ocheck; echo "rc=$?"' _ "$G/lib/escape-hatch.sh" 2>&1)
    [ "$o" = "$n" ] && ok || bad "O1 $1: ordinary PR output changed. old: [$o] new: [$n]"
  }
  reset_fx; pr 101 skip-guardrail "$JUST"; files 101 migrations/a.sql
  o_row no-labels   ""                 ""
  o_row label-only  skip-guardrail     ""
  o_row valid       "bug,skip-guardrail" "Body.
$JUST"
  o_row whitespace  skip-guardrail     "Guardrail-Justification:                          "
  o_row short19     skip-guardrail     "Guardrail-Justification: 1234567890123456789"
  o_row marker-only ""                 "$JUST"
  o_row feature-x   skip-guardrail     "$JUST" feature/x 'mergify[bot]'
  o_row spoofed     skip-guardrail     "$JUST" mergify/merge-queue/x alice
  o_row spoofed-nl  ""                 ""      mergify/merge-queue/x alice
  # whole checks on an ordinary PR: merge-base vs head, stdout and rc
  o_check() { # o_check <id> <check> [env...]
    local id=$1 c=$2; shift 2
    local o n
    o=$(cd "$W" && env "$@" "$T/old/guardrails/$c/check.sh" 2>&1; echo "rc=$?")
    n=$(cd "$W" && env "$@" "$G/$c/check.sh" 2>&1; echo "rc=$?")
    [ "$o" = "$n" ] && ok || bad "O1 $id: $c output changed on an ordinary PR. old: [$o] new: [$n]"
  }
  fresh_w; violate a.sql; printf 'CREATE TABLE ok (id int);\nALTER TABLE ok ENABLE ROW LEVEL SECURITY;\n' > "$W/migrations/ok.sql"
  o_check rls-plain rls-on-create-table PR_LABELS=
  o_check rls-hatch rls-on-create-table PR_LABELS=skip-guardrail GUARDRAIL_JUSTIFICATION="$JUST"
  o_check rls-spoof rls-on-create-table GUARDRAIL_HEAD_REF=mergify/merge-queue/x GUARDRAIL_PR_AUTHOR=alice \
    GUARDRAIL_DRAFT_BODY="$(draft_body 101)" GITHUB_REPOSITORY=o/r GUARDRAIL_GH="$STUB" GUARDRAIL_EXEMPT=migrations/a.sql
  mkdir -p "$W/docs/verification-map"; printf 'src/app/x/page.tsx\n' > "$W/changed.txt"
  o_check vmap verification-map-freshness VMAP_FILES="$W/changed.txt"
  mkdir -p "$W/frag"; printf 'out/gen.txt\n' > "$W/changed-r.txt"
  o_check rff rendered-file-freshness RFF_MAP='out/gen.txt|frag/|bin/render.sh --write' RFF_FILES="$W/changed-r.txt" RFF_ROOT="$W"
  mkdir -p "$W/docs"; printf 'one\ntwo\nthree\n' > "$W/docs/A.md"
  printf 'diff --git a/docs/A.md b/docs/A.md\n--- a/docs/A.md\n+++ b/docs/A.md\n@@ -1,2 +1,3 @@\n one\n+two\n three\n' > "$W/pr.diff"
  o_check doc doc-monolith-edit DOC_MONOLITHS=docs/A.md DOC_MONOLITH_DIFF="$W/pr.diff"
else
  bad "O1: could not extract guardrails/ at the merge base ($BASE)"
fi

# ── B1: 0 real GitHub calls ─────────────────────────────────────────────────
[ ! -e "$T/trap-hit" ] && ok || bad "B1: the real 'gh' on PATH was run"

echo "guardrails-batch-hatch.bh-9965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
