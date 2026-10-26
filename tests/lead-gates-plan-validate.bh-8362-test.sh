#!/bin/bash
# tests/lead-gates-plan-validate.bh-8362-test.sh — the plan-validate rule of the
# pre-review self-check (bin/lib/pr-self-check-validate.sh, bin/lib/plan-validate.py,
# catalog/pr-self-check.d/bh-7072-plan-validate.tsv) as the worklist's gate 75
# holds it (bin/lib/lead-gates.d/75-self-check.sh, bin/lib/lead-gates-selfcheck.sh).
# Every case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh, lead-gates-fixture.bh-5875.sh,
# lead-gates-fixture.bh-5876.sh) on a real head in the clone. The head carries
# .harness/specs/BH-41/plan.md with task T7: VALIDATE `test -f catalog/knob.json`.
#   PV1  the head lacks catalog/knob.json: no job, ONE PR comment that names
#        `plan-validate: T7:` and `missing at head`, one `[skip selfcheck]` line.
#   PV2  a head that commits catalog/knob.json: one job, no comment.
#   PV3  PV1's head, a body line `owed: T7 ...` and a thread comment
#        `approve owed: T7` by a login in trigger.actors.cromford: one job,
#        and the thread was read at least once.
#   M1   75-self-check.sh removed: PV1's head gets a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-plan-validate.bh-8362-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset PR_SELF_CHECK PR_SELF_CHECK_MAX_WAIT_MIN PR_SELF_CHECK_CATALOG PLAN_VALIDATE_MAX_LINES
lwf_setup
lgf_setup
lg6_setup
GD="$H/bin/lib/lead-gates.d"
# The evaluator is python, which the source closure does not follow.
cp "$LWF_SRC/bin/lib/plan-validate.py" "$H/bin/lib/plan-validate.py" || bad "setup: no bin/lib/plan-validate.py"
for f in bin/lib/lead-gates.d/75-self-check.sh bin/lib/lead-gates-selfcheck.sh bin/lib/pr-self-check-validate.sh; do
  [ -r "$LWF_SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
# A gh layer for the PR thread: GET issues/<n>/comments answers $FX/thread.<n>
# (else no comments) and logs one line to $T/log/comment-reads.
mv "$T/fakebin/gh" "$T/fakebin/gh.5876"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  echo "\${BASH_REMATCH[1]}" >> "$T/log/comment-reads"
  printf 'HTTP/2 200\r\n\r\n'
  cat "$FX/thread.\${BASH_REMATCH[1]}" 2>/dev/null || echo '[]'
  exit 0
fi
exec "$T/fakebin/gh.5876" "\$@"
EOF
chmod +x "$T/fakebin/gh"

plan() { # plan <files-to-touch line>... — the plan text with task T7
  printf '# plan\n\n## Files to touch\n'
  printf -- '- `%s`\n' "$@"
  printf '\n### T7 — the knob file\n- VALIDATE: `test -f catalog/knob.json`\n- SATISFIES: x\n'
}
# head <pr> — the plan, then bin/a.sh, on main: the PV1 head (no knob file)
head_noknob() {
  local p
  p=$(lg6_head "$1" .harness/specs/BH-41/plan.md "$(plan bin/a.sh)") || return 1
  lg6_head "$1" bin/a.sh a "$p"
}
head_knob() {
  local p a
  p=$(lg6_head "$1" .harness/specs/BH-41/plan.md "$(plan bin/a.sh catalog/knob.json)") || return 1
  a=$(lg6_head "$1" bin/a.sh a "$p") || return 1
  lg6_head "$1" catalog/knob.json '{}' "$a"
}
# one <pr> <head> [body] — PR <pr> on <head>, titled BH-41, with both catalogs
one() {
  lg6_reset none; lgf_needs "$1:$2"
  printf '%s' "${3:-$LG6_BODY}" > "$FX/body.$1"; echo "BH-41: the knob" > "$FX/title.$1"
  lg6_catalog; cp -r "$LWF_SRC/catalog/pr-self-check.d" "$H/catalog/"
}
reads() { lwf_cnt . "$T/log/comment-reads"; }

H1=$(head_noknob 141) || bad "setup: the PV1 head"
H2=$(head_knob 142) || bad "setup: the PV2 head"
H3=$(head_noknob 143) || bad "setup: the PV3 head"

# ── PV1: the VALIDATE file is missing at head: held, one comment, no job ──
one 141 "$H1"
lwf_tick
[ "$(lgf_jobs 141)" = 0 ] && ok || bad "PV1 a job on a failing plan VALIDATE: $(cat "$L")"
[ "$(lg6_comments 141)" = 1 ] && ok || bad "PV1 comments=$(lg6_comments 141)"
grep -qF 'plan-validate: T7:' "$T/log/comments.141" && grep -qF 'missing at head' "$T/log/comments.141" && ok \
  || bad "PV1 the comment: $(cat "$T/log/comments.141" 2>/dev/null)"
[ "$(lg6_skips selfcheck)" = 1 ] && ok || bad "PV1 selfcheck lines=$(lg6_skips selfcheck): $(cat "$L")"

# ── PV2: the head commits the file: a job, no comment ──
one 142 "$H2"
lwf_tick
[ "$(lgf_jobs 142)" = 1 ] && ok || bad "PV2 no job with the knob committed: $(cat "$L")"
[ "$(lg6_comments 142)" = 0 ] && ok || bad "PV2 a comment: $(cat "$T/log/comments.142" 2>/dev/null)"

# ── PV3: an operator-approved owed line lets PV1's failure go ──
one 143 "$H3" "$LG6_BODY
owed: T7 the knob lands with BH-42
"
printf 'operator' > "$FX/settings/trigger.actors.cromford"
jq -nc '[{user:{login:"operator"}, body:"approve owed: T7"}]' > "$FX/thread.143"
lwf_tick
[ "$(lgf_jobs 143)" = 1 ] && ok || bad "PV3 no job on an approved owed line: $(cat "$L") comments=$(cat "$T/log/comments.143" 2>/dev/null)"
[ "$(reads)" -ge 1 ] && ok || bad "PV3 the thread was never read"

# ── M1: no self-check gate: PV1's head gets a job ──
mv "$GD/75-self-check.sh" "$T/75.off"
one 141 "$H1"
lwf_tick
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "M1 no job with 75-self-check.sh gone: $(cat "$L")"
mv "$T/75.off" "$GD/75-self-check.sh"

echo "lead-gates-plan-validate.bh-8362: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
