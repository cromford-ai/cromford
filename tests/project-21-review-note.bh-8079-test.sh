#!/bin/bash
# tests/project-21-review-note.bh-8079-test.sh — the pre-review self-check rule
# `project-21-upgrade` (bin/lib/project-21.example project-21_psc_check, row
# catalog/pr-self-check.d/bh-8079-project-21-upgrade.tsv), through the CLI
# bin/pr-self-check.sh, and its two forwarders into the lead review notes.
#   R1 an affected row with a fixed_in: a NOTE that names the upgrade line, rc 0
#   R2 lib.project-21.project-21_review_block=1 (env PROJECT_21_REVIEW_BLOCK): the same line as a REFUSE, rc 1
#   R3 fixed in `none`: no line       R4 clean, failed, partial-only: no line
#   R5 the heading quoted in a code fence: not read
#   R6 two project-21 headings: only the first is read    R7 no section: no line
#   R8 self_check_hold's PSCNOTES carry the line      R9 lgsc_notes prints it
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-21-review-note.bh-8079-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY PROJECT_21_REVIEW_BLOCK PROJECT_21_ENABLED
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
scratch_install_closure bin/project-21-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/project-21-check.sh"; exit 1; }
[ -r "$SRC/catalog/pr-self-check.d/bh-8079-project-21-upgrade.tsv" ] || { echo "FAIL: the catalog row is missing"; exit 1; }
export PR_SELF_CHECK_CATALOG="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
# shellcheck source=bin/lib/project-21.example
. "$H/bin/lib/project-21.example" || { echo "FAIL: bin/lib/project-21.example does not source"; exit 1; }
. "$SRC/tests/lib/project-21-fake.bh-8079.sh" "$SRC" || exit 1
tf_start || exit 1

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main && printf 'x\n' > "$R/README.md" && git -C "$R" add -A && git -C "$R" commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
printf '{"lockfileVersion":3}\n' > "$R/package-lock.json" && git -C "$R" add -A && git -C "$R" commit -qm "BH-8079: lock"
HD=$(git -C "$R" rev-parse HEAD)

section() { # section <mode> -> the real renderer's section over the real CLI's result
  tf_mode "$1"; "$H/bin/project-21-check.sh" "$R" --out "$T/r-$1.json" --head "$HD" >/dev/null 2>&1
  project-21_pr_section "$T/r-$1.json"
}
body() { # body <file> <section text>
  printf 'Ticket BH-8079 — the subject\n\n## What\n- a thing\n\n## Why\nbecause\n\n%s\n\n---\nfooter\n' "$2" > "$1"
}
psc() { # psc <body-file> -> $out $rc
  out=$("$H/bin/pr-self-check.sh" check --repo "$R" --base "$BASE" --head "$HD" --body "$1" --only '^project-21-upgrade$' 2>&1); rc=$?
}
WANT='NOTE project-21-upgrade: lodash@4.17.15 has a fix in 4.17.21 that this PR does not apply: Upgrade lodash to 4.17.21 or later. (https://osv.dev/vulnerability/GHSA-p6mc-m468-83gw)'

# R1
AFF=$(section affected); body "$T/b-aff.md" "$AFF"
psc "$T/b-aff.md"
{ [ "$rc" = 0 ] && grep -qxF -- "$WANT" <<<"$out" && [ "$(grep -c '^NOTE project-21-upgrade: ' <<<"$out")" = 2 ] \
  && ! grep -q '^REFUSE' <<<"$out"; } && ok || bad "R1 note: rc=$rc out=$out"
R1_OUT="$out"

# R2 the knob on
out=$(PROJECT_21_REVIEW_BLOCK=1 "$H/bin/pr-self-check.sh" check --repo "$R" --base "$BASE" --head "$HD" --body "$T/b-aff.md" --only '^project-21-upgrade$' 2>&1); rc=$?
{ [ "$rc" = 1 ] && grep -qxF -- "REFUSE ${WANT#NOTE }" <<<"$out" && ! grep -q '^NOTE project-21' <<<"$out"; } \
  && ok || bad "R2 refuse: rc=$rc out=$out"

# R3 fixed in none
NONE=$(sed 's/| 4\.17\.21 |/| none |/' <<<"$AFF"); body "$T/b-none.md" "$NONE"
psc "$T/b-none.md"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok || bad "R3 fixed in none: rc=$rc out=$out"

# R4 clean, failed and partial-only sections
for m in clean 500 partial; do
  body "$T/b-$m.md" "$(section "$m")"; psc "$T/b-$m.md"
  { [ "$rc" = 0 ] && [ -z "$out" ]; } && ok || bad "R4 $m: rc=$rc out=$out"
done

# R5 the heading quoted inside a code fence in another section
body "$T/b-fence.md" "$(printf '## Notes\n\n```\n%s\n```\n' "$AFF")"
psc "$T/b-fence.md"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok || bad "R5 fenced heading: rc=$rc out=$out"

# R6 two project-21 headings: the first (clean) is read, the second is not
body "$T/b-two.md" "$(printf '%s\n\n%s\n' "$(section clean)" "$AFF")"
psc "$T/b-two.md"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok || bad "R6 two headings: rc=$rc out=$out"

# R7 no section; a table in another section with a fixed in column is not read
body "$T/b-other.md" "$(printf '## Other\n\n| dependency | version | severity | fixed in | upgrade | advisory |\n|---|---|---|---|---|---|\n| x (npm) | 1 | high | 2 | Upgrade x. | A https://example.invalid |\n')"
psc "$T/b-other.md"
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok || bad "R7 no section: rc=$rc out=$out"

# R8 self_check_hold's PSCNOTES lines, read from the function body
EXTRACT=$(awk '/^self_check_hold\(\) \{/{b=1} b && /^[[:space:]]*PSCNOTES=\$\(printf/{print} b && /^}/{exit}' "$SRC/bin/lead-review-enqueue.sh")
out=$(printf '%s\nREFUSE plan-files: nope\n' "$R1_OUT")
PSCNOTES=""
eval "$EXTRACT"
grep -qxF -- "${WANT#NOTE }" <<<"$PSCNOTES" && ok || bad "R8 self_check_hold PSCNOTES: got: $PSCNOTES"

# R9 lgsc_notes forwards it
printf '%s\n' "$R1_OUT" > "$T/lgsc.out"
GOT=$(bash -c '. "$1/bin/lib/lead-gates-selfcheck.sh" 2>/dev/null; LGSC_OUT="$2"; lgsc_notes' _ "$SRC" "$T/lgsc.out")
grep -qxF -- "${WANT#NOTE }" <<<"$GOT" && ok || bad "R9 lgsc_notes: got: $GOT"

echo "project-21-review-note.bh-8079: PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
