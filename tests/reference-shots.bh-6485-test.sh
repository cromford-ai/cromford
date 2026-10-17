#!/bin/bash
# tests/reference-shots.bh-6485-test.sh — BH-6485: a ticket with `Reference:`
# lines on a UI diff gets light/dark x 1440/390 preview shots next to the
# reference images in the PR body, hosted on a side branch, and the PR
# self-check refuses a body without them.
#
# Driven: bin/reference-shots.sh against a local bare remote (the clock pinned
# by REFERENCE_SHOTS_NOW), bin/evidence-summary.sh, bin/pr-self-check.sh check,
# and the shipped QA_PROMPT_MODE, `# >>> reference shots` and
# _pr_self_check_prepush regions of bin/lib/rb/pr.sh (flattened by rb_all).
#   R1 a complete set: the ref exists on the remote, 4 rows with both images
#   R2 the PR branch head does not move     R3 the image URLs use the pushed sha
#   R4 one shot missing -> Missing:, no image markup
#   R5 the push is rejected -> Could not publish, no images, rc 0; R5b origin
#      holds another sha after the push -> Could not publish
#   R6 prune: dry deletes none, on deletes at most MAX, never a ref outside
#      harness-shots/, one audit line per run
#   R7 the two under= terms AND on one heading
#   R8 publish -> evidence-summary prints it -> pr-self-check passes the body
#   R9 no Reference lines -> publish writes nothing
#   S1-S6 the body-reference-shots row through bin/pr-self-check.sh check
#   A1-A4 the pr.sh regions: the QA note, the publish call, PSC_PHASE
# No network (the remote is a local bare repo), no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/reference-shots.bh-6485-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }

mkdir -p "$T/h/logs" "$T/h/catalog"
for s in bin/reference-shots.sh bin/pr-self-check.sh bin/evidence-summary.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
cp "$DIR/catalog/pr-self-check.tsv" "$T/h/catalog/" && mkdir -p "$T/h/catalog/pr-self-check.d" \
  && cp "$DIR/catalog/pr-self-check.d/bh-6485-reference-shots.tsv" "$T/h/catalog/pr-self-check.d/" \
  || { echo "FAIL: cannot stage the self-check catalog"; exit 1; }
RS="$T/h/bin/reference-shots.sh"
PSC="$T/h/bin/pr-self-check.sh"
NOW=$(date -u -d '2026-10-15T12:00:00Z' +%s)
export REFERENCE_SHOTS_NOW="$NOW" HARNESS="$T/h"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

# The remote and the checkout: main holds the reference image, the PR branch a
# UI file.
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/repo" 2>/dev/null
R="$T/repo"
mkdir -p "$R/design" "$R/src/app"
printf 'fixture-reference-png' > "$R/design/home.png"
git -C "$R" add -A && git -C "$R" commit -qm base && git -C "$R" push -q origin HEAD:main 2>/dev/null
BASE_SHA=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb ticket/bh-1
printf 'export default function Page() { return null }\n' > "$R/src/app/page.tsx"
git -C "$R" add -A && git -C "$R" commit -qm 'BH-1: page'
HEAD_SHA=$(git -C "$R" rev-parse HEAD)

B="$T/b"
build() { # build <ticket-body> <shots...> — a fresh build dir
  scratch_rm "$B"; mkdir -p "$B/qa-shots/ref"
  jq -n --arg b "$1" '{body: $b}' > "$B/ticket-meta.json"; shift
  local s; for s in "$@"; do printf 'fixture-png-%s' "$s" > "$B/qa-shots/ref/$s"; done
}
ALL4=(home-light-1440.png home-light-390.png home-dark-1440.png home-dark-390.png)
pub() { (cd "$T" && "$RS" publish "$B" "$R" acme/widget BH-1 "$BASE_SHA"); }

# R1-R3
build 'Reference: design/home.png' "${ALL4[@]}"
pub; RC=$?
[ "$RC" = 0 ] && ok || bad "R1 publish exits 0, got $RC"
REF_SHA=$(git -C "$R" ls-remote origin refs/heads/harness-shots/bh-1-20261015 | awk '{print $1}')
[ -n "$REF_SHA" ] && ok || bad "R1 the ref harness-shots/bh-1-20261015 must exist on the remote: $(git -C "$R" ls-remote origin)"
[ "$(grep -c '^| `design/home.png` |' "$B/reference-shots.md")" = 4 ] && ok || bad "R1 four rows: $(cat "$B/reference-shots.md")"
[ "$(grep -c '!\[preview\](.*!\[reference\](' "$B/reference-shots.md")" = 4 ] && ok || bad "R1 each row has both images"
[ "$(git -C "$R" ls-tree --name-only "$REF_SHA" | sort | paste -sd' ' -)" = "home-dark-1440.png home-dark-390.png home-light-1440.png home-light-390.png" ] \
  && ok || bad "R1 the shots commit holds the four shots: $(git -C "$R" ls-tree --name-only "$REF_SHA")"
[ -z "$(git -C "$R" log --format=%P -1 "$REF_SHA")" ] && ok || bad "R1 the shots commit is an orphan"
[ "$(git -C "$R" rev-parse HEAD)" = "$HEAD_SHA" ] && [ "$(git -C "$R" symbolic-ref --short HEAD)" = ticket/bh-1 ] && [ -z "$(git -C "$R" status --porcelain)" ] \
  && ok || bad "R2 the PR branch, its head and the tree are untouched"
grep -q "https://github.com/acme/widget/blob/$REF_SHA/home-light-1440.png?raw=true" "$B/reference-shots.md" \
  && grep -q "https://github.com/acme/widget/blob/$BASE_SHA/design/home.png?raw=true" "$B/reference-shots.md" && ok \
  || bad "R3 the preview URL uses the pushed sha and the reference URL the base sha: $(cat "$B/reference-shots.md")"
grep -q 'REFERENCE SHOTS: status=published ref=harness-shots/bh-1-20261015' "$B/pipeline.log" && ok || bad "R1 one pipeline.log line: $(cat "$B/pipeline.log")"
grep -q 'publish BH-1 status=published' "$T/h/logs/reference-shots.log" && ok || bad "R1 one reference-shots.log line"
cp "$B/reference-shots.md" "$T/complete.md"

# R4
build 'Reference: design/home.png' home-light-1440.png home-light-390.png home-dark-1440.png
pub
grep -q '^Missing: qa-shots/ref/home-dark-390.png$' "$B/reference-shots.md" && ok || bad "R4 Missing names the shot: $(cat "$B/reference-shots.md")"
grep -q '!\[' "$B/reference-shots.md" && bad "R4 an incomplete set has no image markup" || ok
build 'Reference: design/away.png' away-light-1440.png away-light-390.png away-dark-1440.png away-dark-390.png
pub
grep -q "design/away.png: reference not found at ${BASE_SHA:0:8}" "$B/reference-shots.md" && ! grep -q '!\[' "$B/reference-shots.md" && ok \
  || bad "R4 a reference absent at the base sha is missing: $(cat "$B/reference-shots.md")"

# R5
build 'Reference: design/home.png' "${ALL4[@]}"
cat > "$T/remote.git/hooks/pre-receive" <<'EOS'
#!/bin/sh
echo "fixture: rejected" >&2; exit 1
EOS
chmod +x "$T/remote.git/hooks/pre-receive"
REFERENCE_SHOTS_NOW=$((NOW + 86400)) bash -c "cd '$T' && '$RS' publish '$B' '$R' acme/widget BH-1 '$BASE_SHA'"; RC=$?
[ "$RC" = 0 ] && grep -q '^Could not publish: the push of harness-shots/bh-1-20261016 was rejected$' "$B/reference-shots.md" && ! grep -q '!\[' "$B/reference-shots.md" && ok \
  || bad "R5 a rejected push: rc 0, Could not publish, no images (rc $RC): $(cat "$B/reference-shots.md")"
rm -f "$T/remote.git/hooks/pre-receive"
# R5b: the push answers ok but origin holds another sha (a hook moved the ref):
# only the ls-remote check can tell, and no image is shown.
cat > "$T/remote.git/hooks/post-receive" <<EOS
#!/bin/sh
while read old new ref; do git update-ref "\$ref" $BASE_SHA; done
EOS
chmod +x "$T/remote.git/hooks/post-receive"
REFERENCE_SHOTS_NOW=$((NOW + 3 * 86400)) bash -c "cd '$T' && '$RS' publish '$B' '$R' acme/widget BH-1 '$BASE_SHA'"; RC=$?
[ "$RC" = 0 ] && grep -q '^Could not publish: origin does not show harness-shots/bh-1-20261018 at ' "$B/reference-shots.md" && ! grep -q '!\[' "$B/reference-shots.md" && ok \
  || bad "R5b a ref origin does not hold at the pushed sha: no images (rc $RC): $(cat "$B/reference-shots.md")"
rm -f "$T/remote.git/hooks/post-receive"
git -C "$R" push -q origin --delete refs/heads/harness-shots/bh-1-20261018 2>/dev/null

# R6
for n in harness-shots/bh-7-20260801 harness-shots/bh-8-20260802 harness-shots/bh-9-20261010 other/keep-20200101; do
  git -C "$R" push -q origin "$BASE_SHA:refs/heads/$n" 2>/dev/null
done
refs() { git -C "$R" ls-remote origin 'refs/heads/*' | awk '{print $2}' | sed 's#^refs/heads/##' | sort | paste -sd' ' -; }
: > "$T/h/logs/reference-shots.log"
REFERENCE_SHOTS_PRUNE=dry "$RS" prune "$R"
grep -q 'harness-shots/bh-7-20260801' <<<"$(refs)" && grep -q 'harness-shots/bh-8-20260802' <<<"$(refs)" && ok || bad "R6 dry deletes nothing: $(refs)"
[ "$(grep -c 'prune mode=dry' "$T/h/logs/reference-shots.log")" = 1 ] && grep -q 'candidates=2 deleted=0' "$T/h/logs/reference-shots.log" && ok \
  || bad "R6 one dry audit line naming 2 candidates: $(cat "$T/h/logs/reference-shots.log")"
: > "$T/h/logs/reference-shots.log"
REFERENCE_SHOTS_PRUNE=on REFERENCE_SHOTS_PRUNE_MAX=1 "$RS" prune "$R"
L=$(refs)
grep -q 'harness-shots/bh-7-20260801' <<<"$L" && bad "R6 on deletes the oldest candidate: $L" || ok
grep -q 'harness-shots/bh-8-20260802' <<<"$L" && ok || bad "R6 on deletes at most REFERENCE_SHOTS_PRUNE_MAX=1: $L"
grep -q 'harness-shots/bh-9-20261010' <<<"$L" && grep -q 'harness-shots/bh-1-20261015' <<<"$L" && ok || bad "R6 a ref inside the window stays: $L"
grep -q 'other/keep-20200101' <<<"$L" && grep -q '\bmain\b' <<<"$L" && ok || bad "R6 a ref outside harness-shots/ is never touched: $L"
[ "$(grep -c 'prune mode=on' "$T/h/logs/reference-shots.log")" = 1 ] && grep -q 'deleted=1 failed=0' "$T/h/logs/reference-shots.log" && ok \
  || bad "R6 one audit line for the run: $(cat "$T/h/logs/reference-shots.log")"
: > "$T/h/logs/reference-shots.log"
REFERENCE_SHOTS_PRUNE=off "$RS" prune "$R"
[ "$(refs)" = "$L" ] && grep -q 'prune mode=off' "$T/h/logs/reference-shots.log" && ok || bad "R6 off does nothing but its audit line"

# R9
build 'A plain ticket with no reference lines.'
pub
[ ! -e "$B/reference-shots.md" ] && [ ! -e "$B/pipeline.log" ] && ok || bad "R9 no Reference lines: nothing written"

# ── S, R7, R8: the self-check row ───────────────────────────────────────────
printf 'Reference: design/home.png\n' > "$T/tk-ref.md"
printf 'A plain ticket.\n' > "$T/tk-plain.md"
printf '## Why\n\nThe page.\n' > "$T/body-none.md"
cp "$T/complete.md" "$T/body-full.md"
{ printf '## Why\n\nThe page.\n\n## Reference screenshots\n\n'; grep -o '!\[preview\]([^)]*)' "$T/complete.md" | head -1; } > "$T/body-preview-only.md"
chk() { # chk <body> <ticket|-> [env...] -> $T/c.out, rc CRC
  local body="$1" tk="$2"; shift 2
  local ta=(); [ "$tk" = - ] || ta=(--ticket "$T/$tk")
  env "$@" "$PSC" check --repo "$R" --base "$BASE_SHA" --head "$HEAD_SHA" --body "$T/$body" "${ta[@]}" --only '^body-reference-shots$' > "$T/c.out" 2>&1; CRC=$?
}
chk body-none.md tk-ref.md
[ "$CRC" = 1 ] && grep -q '^REFUSE body-reference-shots:' "$T/c.out" && ok || bad "S1 Reference + UI diff + no section refuses (rc $CRC): $(cat "$T/c.out")"
chk body-full.md tk-ref.md
[ "$CRC" = 0 ] && ! grep -q 'body-reference-shots' "$T/c.out" && ok || bad "S2 the section passes (rc $CRC): $(cat "$T/c.out")"
chk body-none.md tk-ref.md PSC_PHASE=open
[ "$CRC" = 0 ] && grep -q '^NOTE body-reference-shots: reference shots are taken after preview QA' "$T/c.out" && ok || bad "S3 the open phase is a note (rc $CRC): $(cat "$T/c.out")"
chk body-none.md tk-plain.md
[ "$CRC" = 0 ] && ! grep -q 'body-reference-shots' "$T/c.out" && ok || bad "S4 no Reference lines: the rule does not apply (rc $CRC): $(cat "$T/c.out")"
git -C "$R" checkout -qb ticket/bh-2 "$BASE_SHA"; mkdir -p "$R/bin" "$R/docs"; printf 'x\n' > "$R/bin/x.sh"; printf 'a\n' > "$R/docs/a.md"
git -C "$R" add -A && git -C "$R" commit -qm 'BH-2: non-ui'
NONUI=$(git -C "$R" rev-parse HEAD); git -C "$R" checkout -q ticket/bh-1
"$PSC" check --repo "$R" --base "$BASE_SHA" --head "$NONUI" --body "$T/body-none.md" --ticket "$T/tk-ref.md" --only '^body-reference-shots$' > "$T/c.out" 2>&1; CRC=$?
[ "$CRC" = 0 ] && ! grep -q 'body-reference-shots' "$T/c.out" && ok || bad "S5 Reference + a non-UI diff: the rule does not apply (rc $CRC): $(cat "$T/c.out")"
chk body-none.md -
[ "$CRC" = 0 ] && grep -q '^NOTE body-reference-shots: no ticket text' "$T/c.out" && ok || bad "S6 no ticket text is a note (rc $CRC): $(cat "$T/c.out")"
chk body-preview-only.md tk-ref.md
[ "$CRC" = 1 ] && ok || bad "R7 a preview image with no reference image still refuses (rc $CRC): $(cat "$T/body-preview-only.md")"
{ cat "$T/body-preview-only.md"; printf '\n## Other\n\n![reference](x)\n'; } > "$T/body-split.md"
chk body-split.md tk-ref.md
[ "$CRC" = 1 ] && ok || bad "R7 the reference image under another heading does not count (rc $CRC)"
build 'Reference: design/home.png' home-light-1440.png
pub
cp "$B/reference-shots.md" "$T/body-missing.md"
chk body-missing.md tk-ref.md
[ "$CRC" = 1 ] && ok || bad "R7 a Missing: section is refused (rc $CRC)"

# R8: publish -> evidence-summary -> the self-check
build 'Reference: design/home.png' "${ALL4[@]}"
REFERENCE_SHOTS_NOW=$((NOW + 2 * 86400)) bash -c "cd '$T' && '$RS' publish '$B' '$R' acme/widget BH-1 '$BASE_SHA'"
"$T/h/bin/evidence-summary.sh" "$B" 2 > "$T/body-es.md" 2>/dev/null
grep -q '^## Evidence' "$T/body-es.md" && grep -q '^## Reference screenshots$' "$T/body-es.md" && [ "$(grep -c '!\[preview\]' "$T/body-es.md")" = 4 ] && ok \
  || bad "R8 evidence-summary prints the section after its block: $(tail -8 "$T/body-es.md")"
chk body-es.md tk-ref.md
[ "$CRC" = 0 ] && ok || bad "R8 the self-check passes the evidence-summary body (rc $CRC): $(cat "$T/c.out")"
rm -f "$B/reference-shots.md"
"$T/h/bin/evidence-summary.sh" "$B" 2 > "$T/body-es0.md" 2>/dev/null
grep -q 'Reference screenshots' "$T/body-es0.md" && bad "R8 no file: evidence-summary prints no section" || ok

# ── A: the pr.sh regions ────────────────────────────────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> preview-qa mode/{f=1;next} /^# <<< preview-qa mode/{exit} f' "$RB_ALL" > "$T/qamode.sh"
awk '/^    # >>> reference shots \(BH-6485\)/{f=1;next} /^    # <<< reference shots \(BH-6485\)/{exit} f' "$RB_ALL" > "$T/pubblock.sh"
awk '/^_pr_self_check_prepush\(\) \{/{f=1} f{print} f && /^}/{exit}' "$RB_ALL" > "$T/prepush.sh"
[ -s "$T/qamode.sh" ] && [ -s "$T/pubblock.sh" ] && [ -s "$T/prepush.sh" ] && ok || bad "A0 could not extract the pr.sh regions"
mkdir -p "$T/a/h/bin"
cp -R "$T/h/bin/lib" "$T/a/h/bin/" 2>/dev/null
cat > "$T/a/h/bin/reference-shots.sh" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGLOG"
EOS
cat > "$T/a/h/bin/pr-self-check.sh" <<'EOS'
#!/bin/bash
printf 'phase=%s\n' "${PSC_PHASE:-unset}" >> "$ARGLOG"
exit 0
EOS
chmod +x "$T/a/h/bin/reference-shots.sh" "$T/a/h/bin/pr-self-check.sh"
cat > "$T/a/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
QA_PROMPT_FOR() { printf 'QA-BASE'; }
. "$QAMODE"
preview_qa_mode() { echo auth; }
QA_PROMPT_MODE https://preview.example.invalid > "$QAOUT"
. "$PUBBLOCK"
. "$PREPUSH"
printf '## Why\n\nfixture\n' > "$BUILD/pr-body.md"
_pr_self_check_prepush "$BUILD/pr-body.md" open
_pr_self_check_prepush "$BUILD/pr-body.md" edit
EOS
adrive() { # adrive <ticket-body>
  rm -rf "$T/a/b"; mkdir -p "$T/a/b"; jq -n --arg b "$1" '{body: $b}' > "$T/a/b/ticket-meta.json"; : > "$T/a/arg.log"
  ( cd "$R" && env HARNESS="$T/a/h" BUILD="$T/a/b" PROJECT=widget-os KEY=BH-1 BASE=origin/main SLUG=acme/widget PCF_SLUG=acme/widget \
      PR_SELF_CHECK=1 ARGLOG="$T/a/arg.log" QAMODE="$T/qamode.sh" PUBBLOCK="$T/pubblock.sh" PREPUSH="$T/prepush.sh" \
      QAOUT="$T/a/qa.out" bash "$T/a/drive.sh" >/dev/null 2>&1 )
}
adrive 'Reference: design/home.png'
grep -q '^QA-BASE REFERENCE SCREENS (BH-6485)' "$T/a/qa.out" && grep -q 'home-dark-390.png' "$T/a/qa.out" && grep -q "$T/a/b/qa-shots/ref/" "$T/a/qa.out" && ok \
  || bad "A1 the QA prompt asks for the named shots: $(cat "$T/a/qa.out")"
grep -q "^publish $T/a/b \. acme/widget BH-1 $BASE_SHA\$" "$T/a/arg.log" && ok || bad "A2 the publish call: $(cat "$T/a/arg.log")"
grep -qx 'phase=open' "$T/a/arg.log" && grep -qx 'phase=edit' "$T/a/arg.log" && ok || bad "A3 the prepush passes PSC_PHASE: $(cat "$T/a/arg.log")"
adrive 'A plain ticket.'
[ "$(cat "$T/a/qa.out")" = QA-BASE ] && ok || bad "A4 a plain ticket adds nothing to the QA prompt: $(cat "$T/a/qa.out")"
grep -q '^publish' "$T/a/arg.log" && bad "A4 a plain ticket calls no publish" || ok

echo "reference-shots.bh-6485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
