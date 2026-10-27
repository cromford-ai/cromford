#!/bin/bash
# tests/verdict-author-person.bh-8419-test.sh — the operator login is a person,
# never a verdict author (BH-8419). At 02:05:32Z on 2026-10-26 the resolver's
# cap-notes path (bin/lib/br/cap.sh br_cap_notes) dismissed review 5645681626
# by `operator` on PR #8351: harness_verdict_author_match (bin/lib/gh-pr-list.sh)
# answered 0 for the operator login, so a person's CHANGES_REQUESTED counted as
# the harness's own.
#   §M  harness_verdict_author_match: an App spelling in the set is rc 0; the
#       operator login, a plain login, the builders App and an empty login are 1
#   §J  harness_verdict_authors_json never carries the operator login
#   §C  br_cap_notes, driven with the REAL helper: a person's review stands
#       (0 dismissals, rc 1, the stand line names the login); a bot-only PR
#       still dismisses exactly its bot review
#   §D  every GitHub /dismissals call site in bin/ is listed, and each one's
#       person guard is bot-only (rp_dismiss_own and lsr_bots_json driven)
# Run from anywhere: bash tests/verdict-author-person.bh-8419-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# Named by path so bin/test-impact.sh maps a change to them onto this suite.
[ -r "$DIR/bin/lib/gh-pr-list.sh" ] && ok || bad "M0 bin/lib/gh-pr-list.sh is missing"
[ -r "$DIR/bin/lib/br/cap.sh" ] && ok || bad "C0 bin/lib/br/cap.sh is missing"

# A hub with no env/github-app.env: no App slug is unioned in, so the set is
# exactly the default or the override under test.
NOHUB="$T/nohub"; mkdir -p "$NOHUB"
# vam <login> [HARNESS_VERDICT_AUTHORS] -> rc of harness_verdict_author_match
vam() { env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator ${2:+HARNESS_VERDICT_AUTHORS="$2"} \
          bash -c '. "$1/bin/lib/gh-pr-list.sh"; harness_verdict_author_match "$2"' _ "$DIR" "$1"; }
vaj() { env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator ${1:+HARNESS_VERDICT_AUTHORS="$1"} \
          bash -c '. "$1/bin/lib/gh-pr-list.sh"; harness_verdict_authors_json' _ "$DIR"; }
pam() { env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator \
          bash -c '. "$1/bin/lib/gh-pr-list.sh"; harness_pr_author_match "$2"' _ "$DIR" "$1"; }

# ── §M: the decision rule ──────────────────────────────────────────────────
vam operator && bad "M1: the operator login operator must not be a verdict author" || ok
vam operator "operator app/cromford" && bad "M2: an env override that lists operator must not make it a verdict author" || ok
vam operator operator && bad "M2: HARNESS_VERDICT_AUTHORS=operator alone must not make it a verdict author" || ok
for l in cromford operator-mac '' 'cromford-builders[bot]' app/cromford-builders some-person; do
  vam "$l" && bad "M3: '$l' must not be a verdict author" || ok
done
vam app/cromford && ok || bad "M4: app/cromford must be a verdict author"
vam 'cromford[bot]' && ok || bad "M5: cromford[bot] must be a verdict author"
vam 'cromford[bot]' "operator app/cromford" && ok || bad "M5: cromford[bot] with the override must be a verdict author"
pam operator && ok || bad "M6: harness_pr_author_match operator must stay rc 0 (a PR the operator opened is one of ours)"

# ── §J: the json helper ────────────────────────────────────────────────────
for ov in "" "operator app/cromford"; do
  j=$(vaj "$ov")
  jq -e 'type == "array"' <<<"$j" >/dev/null 2>&1 && ok || bad "J0: not a JSON array (override '$ov'): $j"
  jq -e 'index("operator") == null' <<<"$j" >/dev/null 2>&1 && ok || bad "J1: the json carries operator (override '$ov'): $j"
  jq -e 'index("cromford[bot]") != null' <<<"$j" >/dev/null 2>&1 && ok || bad "J2: the json lacks cromford[bot] (override '$ov'): $j"
done

# ── §C: br_cap_notes with the real helper ──────────────────────────────────
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
: > "$T/fns.sh"
for fn in br_cap_notes br_floor_stands br_cap_key br_rkey br_file br_load br_save \
          br_record br_set_outcome br_set_field br_num br_shape br_fix_cap br_review_fix_cap br_slug_of_url br_is_external; do
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/fns.sh"
done
grep -q '^br_cap_notes()' "$T/fns.sh" && ok || bad "C0: could not extract br_cap_notes"
H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver" "$H/logs"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lead-verdict.txt"\necho "requested lead review #new"\nexit 0\n' "$T" > "$H/bin/lead-verdict.sh"
chmod +x "$H/bin/"*.sh
HEAD=$(printf 'c%.0s' {1..40})
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
H="$H"; ST="$H/state/blocked-resolver"; LOG="$T/say.txt"; OBSERVE=0
export HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator
unset HARNESS_VERDICT_AUTHORS
STAMP() { echo T; }  # determinism: ok a log stamp no assertion reads
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { printf '%s' "$HEAD"; }
br_review_rows() { cat "$T/rows.json"; }
_jobs_req() { return 0; }
job_ledger_put() { return 0; }
setting_get() { return 2; }
. "$DIR/bin/lib/gh-pr-list.sh"
gh_rest() { printf '%s\n' "\$*" >> "$T/gh.txt"; return 0; }
. "$DIR/bin/lib/review-level.sh"
. "$T/fns.sh"
EOF
mkrows() { local out='[]' id; while [ $# -ge 5 ]; do out=$(jq -c --argjson id "$1" --arg s "$2" --arg l "$3" --arg t "$4" --arg b "$5" \
  '. + [{id:$id, l:$l, t:$t, a:"MEMBER", c:"'"$HEAD"'", s:$s, b:$b}]' <<<"$out"); shift 5; done; printf '%s' "$out" > "$T/rows.json"; }
LEAD_NOTES='<!-- lead-review:abc -->
Lead review (automated lead-review lane) of cccccccccccc

- [BLOCK] card.tsx:12: card padding is 14 px, the prototype has 16 px
- [NOTE] bin/x.sh:4: the log line could name the pr

VERDICT: BLOCK'
PERSON='Three things block this:

- [BLOCK] no gate proof in the PR body
- [BLOCK] no operator steps
- [BLOCK] the bake.flyctl.version row is not seeded'
RESET() { local _p; for _p in "$H/state/blocked-resolver"/* "$T"/{say,alerts,lead-verdict,gh}.txt; do scratch_rm "$_p" 2>/dev/null; done
          mkdir -p "$H/state/blocked-resolver/tproj"
          jq -nc '{project:"tproj",rkey:"tproj-TP-9",fixrounds:2,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$H/state/blocked-resolver/tproj/tproj-TP-9.json"; }
CAP() { ( . "$T/drv.sh"; br_cap_notes tproj tproj-TP-9 review-changes-requested "$URL" - TP-9 ); }
OUTCOME() { jq -r '.outcome // ""' "$H/state/blocked-resolver/tproj/tproj-TP-9.json"; }
puts() { grep -c '/dismissals' "$T/gh.txt" 2>/dev/null || echo 0; }

# C1: the incident — the harness's notes-only lead review AND the operator's block.
RESET; mkrows 5645681001 CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES" 5645681626 CHANGES_REQUESTED operator User "$PERSON"
CAP; RC=$?
[ "$RC" = 1 ] && ok || bad "C1: br_cap_notes rc $RC, want 1 ($(cat "$T/say.txt" 2>/dev/null))"
[ "$(puts)" = 0 ] && ok || bad "C1: a person's review stands, so nothing is dismissed: $(cat "$T/gh.txt" 2>/dev/null)"
grep -q "a person's CHANGES_REQUESTED by operator stands" "$T/say.txt" 2>/dev/null && ok || bad "C1: the stand line must name operator: $(cat "$T/say.txt" 2>/dev/null)"
[ "$(OUTCOME)" != CAP_NOTES ] && ok || bad "C1: no CAP_NOTES outcome while a person's block stands"
[ ! -s "$T/lead-verdict.txt" ] && ok || bad "C1: no notes-only re-review is requested: $(cat "$T/lead-verdict.txt" 2>/dev/null)"
# The same with the person's row FIRST in the list: order does not matter.
RESET; mkrows 5645681626 CHANGES_REQUESTED operator User "$PERSON" 5645681001 CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C1b: person row first: rc $RC, $(puts) dismissals"

# C2: only the harness's bot review: exactly one dismissal, for its id.
RESET; mkrows 5645681001 CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
CAP; RC=$?
[ "$RC" = 0 ] && ok || bad "C2: bot-only rc $RC, want 0 ($(cat "$T/say.txt" 2>/dev/null))"
[ "$(puts)" = 1 ] && ok || bad "C2: exactly one dismissal, got $(puts): $(cat "$T/gh.txt" 2>/dev/null)"
grep -q '^PUT repos/o/r/pulls/9/reviews/5645681001/dismissals' "$T/gh.txt" 2>/dev/null && ok || bad "C2: the dismissal is for the bot review's id: $(cat "$T/gh.txt" 2>/dev/null)"
[ "$(OUTCOME)" = CAP_NOTES ] && ok || bad "C2: outcome CAP_NOTES, got '$(OUTCOME)'"
# C2b: the lane's footer review as the App (Bot, no lead marker): a verdict author, dismissed.
RESET; mkrows 777 CHANGES_REQUESTED 'cromford[bot]' Bot "$(printf -- '- [BLOCK] padding\n\nVERDICT: REQUEST_CHANGES\n\n---\nharness review footer')"
CAP; RC=$?
[ "$RC" = 0 ] && [ "$(puts)" = 1 ] && ok || bad "C2b: the App's footer review is ours: rc $RC, $(puts) dismissals"

# C3: a person who pastes the lead marker is still a person.
# TEST-CHANGE (BH-8466): the login was operator. An operator-login row with the
# lead marker is now the lane's own (a PAT post); that dismissal is pinned in
# tests/own-review-pat.bh-8466-test.sh §C. A non-operator person keeps the intent.
RESET; mkrows 5645681626 CHANGES_REQUESTED some-person User "$LEAD_NOTES"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C3: some-person with a pasted lead marker: rc $RC, $(puts) dismissals"
grep -q "a person's CHANGES_REQUESTED by some-person stands" "$T/say.txt" 2>/dev/null && ok || bad "C3: the stand line must name some-person"
# C3b: the operator's footer review (the PAT-posted shape) stands too.
RESET; mkrows 42 CHANGES_REQUESTED operator User "$(printf -- '- [BLOCK] padding\n\nVERDICT: REQUEST_CHANGES\n\n---\nharness review footer')"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C3b: operator footer review: rc $RC, $(puts) dismissals"
# C3c: a User-typed row that claims an App spelling is not trusted on the name alone.
RESET; mkrows 43 CHANGES_REQUESTED operator-mac User "$LEAD_NOTES"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C3c: operator-mac: rc $RC, $(puts) dismissals"
# C3d: a bot that is neither a verdict author nor the lead marker stands (today's rc 1).
RESET; mkrows 44 CHANGES_REQUESTED 'some-ci[bot]' Bot "$PERSON"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C3d: some-ci[bot]: rc $RC, $(puts) dismissals"

# ── §D: the dismissal-path audit ───────────────────────────────────────────
# D1 every file in bin/ that calls .../reviews/<id>/dismissals, comment lines out.
got=$(cd "$DIR" && grep -rn 'reviews/.*/dismissals' bin/ --include=*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | cut -d: -f1 | LC_ALL=C sort -u)
want=$(printf '%s\n' bin/lib/br/cap.sh bin/lib/lead-stale-review.sh bin/lib/unblock/act.sh bin/review-prs.sh | LC_ALL=C sort -u)
[ "$got" = "$want" ] && ok || bad "D1: the dismissal call sites changed — add the new one here with its bot-only guard. got: $(tr '\n' ' ' <<<"$got")"
# D2 cap.sh: the bot column gates both skips (driven in §C; pinned here too).
grep -q '"Bot") or ((.l // "") | endswith("\[bot\]"))' "$DIR/bin/lib/br/cap.sh" && ok || bad "D2: br_cap_notes lost its bot column"
# D3 rp_dismiss_own: driven. A operator review with no footer is never dismissed; the App's is.
# TEST-CHANGE (BH-8466): the operator row was foot=yes. A operator row WITH the
# footer is now the lane's own PAT post and is dismissed (pinned in
# tests/own-review-pat.bh-8466-test.sh §R2); a person's row has no footer.
awk 'index($0, "rp_dismiss_own() ") == 1 {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/review-prs.sh" > "$T/rp.sh"
grep -q '^rp_dismiss_own()' "$T/rp.sh" && ok || bad "D3: could not extract rp_dismiss_own"
cat > "$T/rpdrv.sh" <<EOF
export HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator
unset HARNESS_VERDICT_AUTHORS
. "$DIR/bin/lib/gh-pr-list.sh"
STAMP() { echo T; }  # determinism: ok a log stamp no assertion reads
LOG="$T/rp-log.txt"; PROJECT=p; SLUG=o/r; RP_DISMISS_FAILS="$T/rpfails"
gh_auth_for() { :; }; gh_auth_reset() { :; }
gh() { printf '%s\n' "\$*" >> "$T/rp-gh.txt"; return 0; }
. "$T/rp.sh"
EOF
scratch_rm "$T/rp-gh.txt" 2>/dev/null
( . "$T/rpdrv.sh"; rp_dismiss_own 9 "$(printf '501\tCHANGES_REQUESTED\tdead\toperator\tno\n502\tCHANGES_REQUESTED\tdead\tcromford[bot]\tyes')" )
n=$(grep -c '/dismissals' "$T/rp-gh.txt" 2>/dev/null || echo 0)
[ "$n" = 1 ] && ok || bad "D3: rp_dismiss_own must dismiss exactly the App's review, got $n: $(cat "$T/rp-gh.txt" 2>/dev/null)"
grep -q 'reviews/502/dismissals' "$T/rp-gh.txt" 2>/dev/null && ok || bad "D3: the dismissed id must be 502 (cromford[bot])"
grep -q 'reviews/501/' "$T/rp-gh.txt" 2>/dev/null && bad "D3: rp_dismiss_own dismissed operator's review 501" || ok
# D4 lsr_bots_json: [bot] logins only, never the operator, even when the set lists it.
lsr=$(env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator HARNESS_VERDICT_AUTHORS="operator app/cromford" \
        bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$1/bin/lib/lead-stale-review.sh"; lsr_bots_json' _ "$DIR" 2>/dev/null)
jq -e 'index("operator") == null and index("cromford[bot]") != null and all(.[]; endswith("[bot]"))' <<<"$lsr" >/dev/null 2>&1 \
  && ok || bad "D4: lsr_bots_json must be [bot]-only and never the operator: $lsr"
# D5 _ub_dismiss acts on a decision's review id and never asks the author helper.
awk 'index($0, "_ub_dismiss() ") == 1 || index($0, "_ub_dismiss()") == 1 {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/lib/unblock/act.sh" > "$T/ub.sh"
grep -q '/dismissals' "$T/ub.sh" && ok || bad "D5: could not extract _ub_dismiss"
grep -qE 'harness_(verdict|pr)_author' "$T/ub.sh" && bad "D5: _ub_dismiss uses an author-match helper — make it bot-only and pin it here" || ok
# D6 cap.sh posts no review of its own (re-post nothing by code).
grep -qE 'POST[^#]*pulls/[^ ]*/reviews' "$DIR/bin/lib/br/cap.sh" && bad "D6: bin/lib/br/cap.sh posts a review" || ok

echo "verdict-author-person.bh-8419: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
