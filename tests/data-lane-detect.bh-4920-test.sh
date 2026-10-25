#!/bin/bash
# tests/data-lane-detect.bh-4920-test.sh — the data lane's detection half
# (BH-4923, order 1 of BH-4920): the DATA_LANE: review field, dl_candidate and
# the helpers the siblings import, all from bin/lib/data-lane.sh.
#   D1-D13  dl_candidate on review.md fixtures shaped like review.sh's output
#   D11     REVIEW_PROMPT, cut from the flattened pipeline, carries the field
#   D14-D17 dl_fp, dl_ledger_status, dl_reviewed_sha, dl_probe_file
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/data-lane.sh"
[ -r "$LIB" ] && [ -r "$DIR/bin/data-lane-apply.sh" ] && ok || bad "D41: $LIB or $DIR/bin/data-lane-apply.sh is missing"
scratch_install_closure bin/data-lane-apply.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# shellcheck source=/dev/null
. "$T/h/bin/lib/data-lane.sh" 2>/dev/null
type dl_candidate >/dev/null 2>&1 && ok || bad "D0: dl_candidate is not defined by bin/lib/data-lane.sh"

TS=scripts/migrate-client-redtail-status.ts
SQL=scripts/migrations/0001_add_col.sql
printf '%s\n' "$TS" "$SQL" src/app/clients/page.tsx > "$T/diff"

# review <file> <extra lines…> — the general review shape: prose, findings,
# the extra lines, then TIER/VERDICT (VERDICT overridable via $V).
review() {
  local f=$1; shift
  {
    echo "# Review of TK-32"
    echo
    echo "The diff adds the redtail status column and a backfill script. Tests cover the parser."
    echo
    echo "- **B1.** The new column is read by src/app/clients/page.tsx, but the migration is not applied to prod yet, so the page throws on load."
    printf '%s\n' "$@"
    echo "TIER: 2"
    echo "VERDICT: ${V:-BLOCK}"
  } > "$f"
}
cand() { # cand <label> <want-rc> <want-out> <file> [diff]
  local out rc
  out=$(dl_candidate "$4" ${5+"$5"}); rc=$?
  [ "$rc" = "$2" ] && [ "$out" = "$3" ] && ok || bad "$1: want rc $2 '$3', got rc $rc '$out'"
}

# D1: one finding, DATA_LANE, BLOCK, path in the diff → candidate (.ts and .sql).
review "$T/r1.md" "" "DATA_LANE: $TS"
cand D1 0 "candidate	$TS" "$T/r1.md" "$T/diff"
review "$T/r1s.md" "" "DATA_LANE: $SQL"
cand D1-sql 0 "candidate	$SQL" "$T/r1s.md" "$T/diff"
# D2: a second, unrelated blocking finding → none.
review "$T/r2.md" "- **B2.** The parser swallows an empty status as \"active\" (D11)." "DATA_LANE: $TS"
cand D2 1 none "$T/r2.md" "$T/diff"
review "$T/r2b.md" "BLOCKING: the RLS policy is missing on the new table." "DATA_LANE: $SQL"
cand D2-BLOCKING 1 none "$T/r2b.md" "$T/diff"
# …while non-blocking prose and a lowercase heading never count.
review "$T/r2c.md" "- Non-blocking: rename the helper." "Blocking findings: one, above." "DATA_LANE: $TS"
cand D2-nonblocking 0 "candidate	$TS" "$T/r2c.md" "$T/diff"
# D3: NEEDS_HUMAN only, no DATA_LANE line → none (NEEDS_HUMAN text is never read).
review "$T/r3.md" "NEEDS_HUMAN: run $TS against prod"
cand D3 1 none "$T/r3.md" "$T/diff"
# D4-D6: traversal, absolute, placeholder → none, even if the diff "lists" them.
printf '%s\n' "scripts/migrations/../../etc/x.sql" "/scripts/migrations/x.sql" "<repo-relative script path>" >> "$T/diff"
review "$T/r4.md" "DATA_LANE: scripts/migrations/../../etc/x.sql"; cand D4 1 none "$T/r4.md" "$T/diff"
review "$T/r5.md" "DATA_LANE: /scripts/migrations/x.sql"; cand D5 1 none "$T/r5.md" "$T/diff"
review "$T/r6.md" "DATA_LANE: <repo-relative script path>"; cand D6 1 none "$T/r6.md" "$T/diff"
# D7: a path the diff does not touch → none; no diff list at all → none.
review "$T/r7.md" "DATA_LANE: scripts/migrations/0099_other.sql"; cand D7 1 none "$T/r7.md" "$T/diff"
cand D7-nodiff 1 none "$T/r1.md"
cand D7-missing-diff 1 none "$T/r1.md" "$T/no-such-diff"
# D8: two DATA_LANE lines → none.
review "$T/r8.md" "DATA_LANE: $TS" "DATA_LANE: $SQL"; cand D8 1 none "$T/r8.md" "$T/diff"
# D9: VERDICT APPROVE → none.
V=APPROVE review "$T/r9.md" "DATA_LANE: $TS"; cand D9 1 none "$T/r9.md" "$T/diff"
# D10: DATA_LANE in round 1 only; the final merged round (review.sh's exact
# header) has none → none. The reverse → candidate.
# The header carries the SHORT sha review.sh writes (LENS_SHA=$(git rev-parse
# --short HEAD), lead review of b80275f9): HEADS is that form, never 40 hex.
HEAD40=$(printf 'h' | sha1sum | cut -c1-40); HEADS=${HEAD40:0:9}
cp "$T/r1.md" "$T/r10.md"
{ printf '\n=== MERGED RE-REVIEW after the single fix round (head %s) ===\n' "$HEADS"
  echo "- **B1.** Still blocking: the migration is not applied to prod."
  echo "TIER: 2"; echo "VERDICT: BLOCK"; } >> "$T/r10.md"
cand D10 1 none "$T/r10.md" "$T/diff"
review "$T/r10b.md" "- **B2.** a second finding, answered by the fix round"
{ printf '\n=== MERGED RE-REVIEW after the single fix round (head %s) ===\n' "$HEADS"
  echo "- **B1.** Only the unapplied migration is left."
  echo "DATA_LANE: $SQL"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } >> "$T/r10b.md"
cand D10-final 0 "candidate	$SQL" "$T/r10b.md" "$T/diff"
# D12: DATA_LANE inside a fenced block → none.
review "$T/r12.md" '```' "DATA_LANE: $TS" '```'; cand D12 1 none "$T/r12.md" "$T/diff"
# D13: a missing file → rc 2, nothing printed.
cand D13 2 "" "$T/nope.md" "$T/diff"

# ── D11: the prompts, from the flattened pipeline ─────────────────────────
NOTE=$(dl_prompt_field_note)
[[ "$NOTE" == " If the diff adds or changes schema (scripts/migrations/*.sql or scripts/migrate-*.ts) and a BLOCK finding exists only because that migration is not yet applied to prod, write 'DATA_LANE: <repo-relative script path>' on its own line above the 'TIER:' line, and do NOT write a NEEDS_HUMAN line for that step. Write no DATA_LANE line otherwise." ]] \
  && ok || bad "D11: dl_prompt_field_note is not the ticket's sentence: $NOTE"
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_block "needs-human seam" "$T/seam.sh"
# TEST-CHANGE (BH-7970): REVIEW_PROMPT is now built by the `review prompt` block (SP_REVIEW_* precompute + sp_render of
# prompts/stages/review.md); PROMPT() drives that real block with the repo lib bin/lib/stage-prompt.sh sourced first.
cut_block "review prompt" "$T/prompt.sh"
[ -s "$T/seam.sh" ] && grep -q 'nh_prompt_release_note' "$T/prompt.sh" && ok || bad "D11: could not cut the seam / REVIEW_PROMPT"
mkdir -p "$T/h/repo"
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/fleet-conf.sh"; chmod +x "$T/h/bin/fleet-conf.sh"
PROMPT() {
  (cd "$T/h/repo" && HARNESS="$T/h" PROJECT=p KEY=BH-7 bash -c '. "$3"; . "$1"; . "$2"; printf "%s" "$REVIEW_PROMPT"' _ "$T/seam.sh" "$T/prompt.sh" "$DIR/bin/lib/stage-prompt.sh" 2>"$T/prompt.err")
}
OUT=$(PROMPT); RC=$?
[ "$RC" = 0 ] && grep -qF "DATA_LANE: <repo-relative script path>" <<<"$OUT" && grep -qF "${NOTE# }" <<<"$OUT" \
  && ok || bad "D11: REVIEW_PROMPT lacks the DATA_LANE note (rc $RC): $(tail -c 300 <<<"$OUT") $(cat "$T/prompt.err")"
# It follows the needs-human note directly.
grep -qF "$(nh_prompt_field_note)$NOTE" <<<"$OUT" && ok || bad "D11: the DATA_LANE note does not follow nh_prompt_field_note"
# The merged re-review prompt (the CC review call that writes merged-review2.md) carries it too.
MR_CALL=$(grep -E 'CC review .*RE-REVIEW AFTER ONE MERGED FIX ROUND' "$RB_ALL")
grep -qF '$(dl_prompt_field_note 2>/dev/null) Write everything to $BUILD/merged-review2.md.' <<<"$MR_CALL" \
  && ok || bad "D11: the merged re-review prompt does not interpolate dl_prompt_field_note"
# D11b: a box without the lib renders the prompt, with no DATA_LANE text.
rm -f "$T/h/bin/lib/data-lane.sh"
OUT=$(PROMPT); RC=$?
[ "$RC" = 0 ] && ! grep -q 'DATA_LANE' <<<"$OUT" && grep -q 'VERDICT: APPROVE or VERDICT: BLOCK' <<<"$OUT" \
  && ok || bad "D11b: lib absent: rc $RC, DATA_LANE present or prompt broken: $(cat "$T/prompt.err")"

# ── D14-D17: the helpers ───────────────────────────────────────────────────
printf 'ALTER TABLE "Client" ADD COLUMN "redtailStatus" TEXT;\n' > "$T/s.sql"
FP=$(dl_fp "$T/s.sql"); WANT=$(sha1sum < "$T/s.sql" | cut -c1-40)
[ "$FP" = "$WANT" ] && [[ "$FP" =~ ^[0-9a-f]{40}$ ]] && ok || bad "D14: dl_fp '$FP' != sha1 '$WANT'"
printf ' ' >> "$T/s.sql"
[ "$(dl_fp "$T/s.sql")" != "$FP" ] && ok || bad "D14: dl_fp did not change after a one-byte edit"
dl_fp "$T/none.sql" >/dev/null; [ $? = 2 ] && ok || bad "D14: dl_fp of a missing file is not rc 2"

# D15-D16: job_ledger_get stubbed with each of its three answers.
job_ledger_get() { echo "$*" >> "$T/lg"; case "$LG_RC" in 0) printf 'applied PR#7 head=abc fp=1';; esac; return "$LG_RC"; }
ls_case() { # ls_case <label> <job_ledger_get rc> <secret> <want rc> <want out>
  local out rc
  out=$(LG_RC=$2 HARNESS_SECRET=$3 dl_ledger_status p "$SQL"); rc=$?
  [ "$rc" = "$4" ] && [ "$out" = "$5" ] && ok || bad "$1: want rc $4 '$5', got rc $rc '$out'"
}
ls_case D15-present 0 s 0 "applied PR#7 head=abc fp=1"
ls_case D15-absent 2 s 1 ""
ls_case D16-unknown 1 s 2 ""
ls_case D16-other-rc 7 s 2 ""
ls_case D16-no-secret 2 "" 2 ""
grep -qx "migration p $SQL" "$T/lg" && ok || bad "D15: ledger key is not 'migration <project> <file>': $(cat "$T/lg")"
unset -f job_ledger_get
out=$(HARNESS_SECRET=s dl_ledger_status p "$SQL"); [ $? = 2 ] && ok || bad "D16: no job_ledger_get must be unknown (2)"

# D17: dl_reviewed_sha — the final merged round's header over review-head.
mkdir -p "$T/b"; OLD=$(printf 'o' | sha1sum | cut -c1-40)
echo "$OLD" > "$T/b/review-head"; cp "$T/r10b.md" "$T/b/review.md"
[ "$(dl_reviewed_sha "$T/b")" = "$HEADS" ] && ok || bad "D17: the header's short sha (as review.sh writes it) not preferred: '$(dl_reviewed_sha "$T/b")'"
# D17b: a 40-hex header is read too; a 6-hex one is not a sha (falls back).
sed "s/(head $HEADS)/(head $HEAD40)/" "$T/r10b.md" > "$T/b/review.md"
[ "$(dl_reviewed_sha "$T/b")" = "$HEAD40" ] && ok || bad "D17b: a 40-hex header must be read"
sed "s/(head $HEADS)/(head ${HEAD40:0:6})/" "$T/r10b.md" > "$T/b/review.md"
[ "$(dl_reviewed_sha "$T/b")" = "$OLD" ] && ok || bad "D17b: a 6-hex header is too short to trust; review-head expected"
cp "$T/r10b.md" "$T/b/review.md"
cp "$T/r1.md" "$T/b/review.md"
[ "$(dl_reviewed_sha "$T/b")" = "$OLD" ] && ok || bad "D17: no header → review-head expected"
rm -f "$T/b/review-head"; dl_reviewed_sha "$T/b" >/dev/null; [ $? = 1 ] && ok || bad "D17: neither → rc 1"
[ "$(dl_probe_file "$T/b/")" = "$T/b/data-lane-probe.md" ] && ok || bad "D17: dl_probe_file"

echo "data-lane-detect: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
