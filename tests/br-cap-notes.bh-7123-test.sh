#!/bin/bash
# tests/br-cap-notes.bh-7123-test.sh — at the review fix-round cap the resolver
# merges with notes, it does not abandon (BH-7123 wave B, C2). br_fix_terminal's
# review-changes-requested arm reads the standing REQUEST_CHANGES review(s) on
# the PR's head (bin/blocked-resolver.sh br_cap_notes): when none of their
# finding lines stands under rl_line_blocks (no ALWAYS-BLOCK class, no catalog
# ERE) the lane records outcome CAP_NOTES, dismisses the stale harness
# REQUEST_CHANGES, asks for ONE notes-only lead re-review of the same head
# (scope token review-level:cap-reached, ledger row review_cap = cap-reached)
# and raises exactly one warn alert. A standing ALWAYS-BLOCK line keeps today's
# br_abandon. Extracted and driven, bin/lib/br/*.sh real on a scratch record
# tree, GitHub / the jobs worker / the lead CLI / the alert line stubbed.
#   §C  the cap with notes only: CAP_NOTES, one request, one dismissal, one
#       alert, nothing abandoned; a second tick on the same head is quiet
#   §F  a floor line (tenant leak class, money ERE, red build) -> br_abandon
#   §P  a person's CHANGES_REQUESTED is never dismissed -> today's path
#   §U  an unreadable reviews list or head: nothing abandoned, retried
#   §O  observe mode: WOULD, no write, no request
#   §W  br_fix_terminal_word no longer promises ABANDONED for a review park
# Run from anywhere: bash tests/br-cap-notes.bh-7123-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The cap layer lives in its own module; it is named here BY PATH so
# bin/test-impact.sh maps a change to it onto this suite (an unnamed script is an
# orphan the impact lane never selects).
[ -r "$DIR/bin/lib/br/cap.sh" ] && ok || bad "C0 bin/lib/br/cap.sh is missing"
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
: > "$T/fns.sh"
for fn in br_fix_terminal br_cap_notes br_floor_stands br_fix_terminal_word br_cap_key br_rkey br_file br_load br_save \
          br_record br_set_outcome br_set_field br_num br_shape br_fix_cap br_review_fix_cap br_slug_of_url br_is_external; do
  # index(), not a regex: BSD awk reads `\(` in -v as `(`, and `^br_record()`
  # then matches br_record_index() first. The exact `name() ` prefix cannot.
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/fns.sh"
done
grep -q '^br_cap_notes()' "$T/fns.sh" && ok || bad "C0: bin/blocked-resolver.sh has no br_cap_notes"
grep -q '^br_fix_terminal()' "$T/fns.sh" && ok || bad "C0: could not extract br_fix_terminal"

H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver" "$H/logs"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
# The lead CLI: `request` answers the worker's 409 (a done row with other notes
# already holds this head) unless $T/fresh-row exists; `reset` is recorded.
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lead-verdict.txt"
case "\$1" in
  request) [ -e "$T/fresh-row" ] && { echo "requested lead review #new"; exit 0; }
           echo "lead-verdict: request refused: a lead review request for this repo, pr and head_sha already exists with different scope_notes" >&2; exit 1 ;;
  reset)   echo "lead review \$2: requested (reset_count 1)"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$H/bin/"*.sh
HEAD=$(printf 'c%.0s' {1..40})
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
H="$H"; ST="$H/state/blocked-resolver"; LOG="$T/say.txt"; OBSERVE="\${OBSERVE:-0}"
export HARNESS="$DIR"
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a log stamp for the say lines; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { [ -e "$T/head-unreadable" ] && return 75; printf '%s' "$HEAD"; }
br_review_rows() { [ -e "$T/rows-unreadable" ] && return 2; cat "$T/rows.json"; }
br_review_cleared() { return 1; }
br_rebuild_fresh() { printf 'rebuild %s\n' "\$*" >> "$T/rebuild.txt"; }
br_abandon() { printf '%s\n' "\$*" >> "$T/abandon.txt"; return 0; }
# BH-8419: bot-only, like the real helper. The quotes keep [bot] literal (a bare
# cromford[bot] glob is "cromford" plus one of b, o, t).
harness_verdict_author_match() { case "\$1" in 'cromford[bot]'|app/cromford) return 0 ;; *) return 1 ;; esac; }
gh_rest() { printf '%s\n' "\$*" >> "$T/gh.txt"; return 0; }
_jobs_req() { printf '%s\n' "\$*" >> "$T/jobs.txt"
  case "\$2" in /api/lead-reviews*) printf '{"requests":[{"id":"req-1","repo":"o/r","pr":9,"head_sha":"$HEAD","status":"done","verdict":"BLOCK"}]}' ;; esac; return 0; }
job_ledger_put() { printf '%s\n' "\$*" >> "$T/ledger.txt"; return 0; }
setting_get() { return 2; }
. "$DIR/bin/lib/review-level.sh"
. "$T/fns.sh"
EOF
# rows <state> <login> <type> <body>... — the PR's reviews, one per argument triple
mkrows() { local out='[]'; while [ $# -ge 4 ]; do out=$(jq -c --arg s "$1" --arg l "$2" --arg t "$3" --arg b "$4" --argjson id "$(( $(jq length <<<"$out") + 101 ))" \
  '. + [{id:$id, l:$l, t:$t, a:"MEMBER", c:"'"$HEAD"'", s:$s, b:$b}]' <<<"$out"); shift 4; done; printf '%s' "$out" > "$T/rows.json"; }
LEAD_NOTES='<!-- lead-review:abc -->
Lead review (automated lead-review lane) of cccccccccccc

- [BLOCK] card.tsx:12: card padding is 14 px, the prototype has 16 px
- [BLOCK] src/app/x.tsx:40: the table headers do not sort
- [NOTE] bin/x.sh:4: the log line could name the pr

VERDICT: BLOCK'
LEAD_FLOOR='<!-- lead-review:abd -->
Lead review of cccccccccccc

- [BLOCK tenant-leak] src/lib/clients.ts:88: listClients() has no companyId filter
- [NOTE] card.tsx:12: padding

VERDICT: BLOCK'
RESET() { local _p; for _p in "$H/state/blocked-resolver"/* "$T"/{say,alerts,lead-verdict,abandon,rebuild,gh,jobs,ledger}.txt "$T/fresh-row" "$T/rows-unreadable" "$T/head-unreadable"; do scratch_rm "$_p" 2>/dev/null; done
          mkdir -p "$H/state/blocked-resolver/tproj"
          jq -nc '{project:"tproj",rkey:"tproj-TP-9",fixrounds:2,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$H/state/blocked-resolver/tproj/tproj-TP-9.json"; }
TERM() { ( . "$T/drv.sh"; br_fix_terminal tproj 9 review-changes-requested "$URL" - TP-9 ); }
OUTCOME() { jq -r '.outcome // ""' "$H/state/blocked-resolver/tproj/tproj-TP-9.json"; }
n() { grep -c . "$T/$1.txt" 2>/dev/null || echo 0; }

# ── §C: the cap with notes only ────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
TERM; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: br_fix_terminal rc $RC, want 0 ($(cat "$T/say.txt" 2>/dev/null))"
[ "$(n abandon)" = 0 ] && ok || bad "C1: br_abandon must not run on notes-only findings: $(cat "$T/abandon.txt")"
[ "$(OUTCOME)" = CAP_NOTES ] && ok || bad "C1: outcome must be CAP_NOTES, got '$(OUTCOME)'"
jq -e '.attempts[] | select(.action == "cap-notes")' "$H/state/blocked-resolver/tproj/tproj-TP-9.json" >/dev/null && ok || bad "C1: no cap-notes attempt on the record"
[ "$(jq -r '.cap_notes_head' "$H/state/blocked-resolver/tproj/tproj-TP-9.json")" = "$HEAD" ] && ok || bad "C1: the record must remember the head the notes review was asked on"
grep -q "^review_cap o/r#9@$HEAD cap-reached" "$T/ledger.txt" 2>/dev/null && ok || bad "C1: the ledger row review_cap <slug>#<pr>@<head> cap-reached is the carrier the lead reads: $(cat "$T/ledger.txt" 2>/dev/null)"
grep -q '^PUT repos/o/r/pulls/9/reviews/101/dismissals' "$T/gh.txt" 2>/dev/null && ok || bad "C1: the stale harness REQUEST_CHANGES (id 101) must be dismissed: $(cat "$T/gh.txt" 2>/dev/null)"
grep -q 'event=DISMISS' "$T/gh.txt" 2>/dev/null && ok || bad "C1: the dismissal must say event=DISMISS"
grep -qE "^request o/r 9 $HEAD --notes review-level:cap-reached" "$T/lead-verdict.txt" 2>/dev/null && ok || bad "C1: the lead re-review request must carry the scope token review-level:cap-reached: $(cat "$T/lead-verdict.txt" 2>/dev/null)"
grep -q '^reset req-1$' "$T/lead-verdict.txt" 2>/dev/null && ok || bad "C1: with the head's done row already there, the request is reset (req-1): $(cat "$T/lead-verdict.txt" 2>/dev/null)"
[ "$(n alerts)" = 1 ] && ok || bad "C1: exactly one warn alert (got $(n alerts)): $(cat "$T/alerts.txt" 2>/dev/null)"
grep -q -- '--severity warn' "$T/alerts.txt" 2>/dev/null && ok || bad "C1: the escalation is a warn, never a page"
grep -q 'TP-9' "$T/alerts.txt" 2>/dev/null && ok || bad "C1: the alert names the ticket"
grep -qi 'nothing was abandoned' "$T/alerts.txt" 2>/dev/null && ok || bad "C1: the alert says nothing was abandoned or closed"
grep -q 'CAP_NOTES' "$T/say.txt" 2>/dev/null && ok || bad "C1: the log line names the outcome word"
# A second tick on the same head: quiet, nothing repeated.
TERM; RC=$?
[ "$RC" = 0 ] && ok || bad "C2: second tick rc $RC"
[ "$(n alerts)" = 1 ] && ok || bad "C2: the alert fires once, got $(n alerts)"
[ "$(grep -c '^request' "$T/lead-verdict.txt")" = 1 ] && ok || bad "C2: one request, got $(grep -c '^request' "$T/lead-verdict.txt")"
[ "$(n abandon)" = 0 ] && ok || bad "C2: still nothing abandoned"
# A fresh row (no done request on this head): the request lands, no reset needed.
RESET; touch "$T/fresh-row"; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
TERM
grep -q '^request' "$T/lead-verdict.txt" 2>/dev/null && ! grep -q '^reset' "$T/lead-verdict.txt" 2>/dev/null && ok || bad "C3: a 201 request needs no reset: $(cat "$T/lead-verdict.txt" 2>/dev/null)"
# The lane's own footer review (review-prs.sh, a verdict author) is ours too.
# BH-8419: the lane posts it as the App, a Bot row; a plain User login is a person.
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$(printf '1. **[HIGH] Card padding is 14 px.** card.tsx:12.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\nharness review footer')"
TERM
[ "$(OUTCOME)" = CAP_NOTES ] && ok || bad "C4: a lane review tagged HIGH with no class is notes-only -> CAP_NOTES, got '$(OUTCOME)'"
[ "$(n abandon)" = 0 ] && ok || bad "C4: nothing abandoned"

# ── §F: a floor line stands -> abandon as before ──────────────────────────
for body in "$LEAD_FLOOR" \
  "$(printf -- '- [HIGH] 4xx refusals become fake spend and trip the spend limit\n\nVERDICT: BLOCK')" \
  "$(printf -- '- [BLOCK] CI is red on this head: the typecheck fails in src/x.ts\n\nVERDICT: BLOCK')" \
  "$(printf -- '- [BLOCK red-build] main is red\n- [BLOCK] padding\n\nVERDICT: BLOCK')"; do
  RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$body"
  TERM
  [ "$(n abandon)" = 1 ] && ok || bad "F: a standing ALWAYS-BLOCK line must still abandon: '$(head -1 <<<"$body" | cut -c1-60)' ($(n abandon))"
  [ "$(OUTCOME)" = "" ] && ok || bad "F: no CAP_NOTES on a floor line, got '$(OUTCOME)'"
  [ "$(n alerts)" = 0 ] && ok || bad "F: no cap alert on the abandon path (br_abandon alerts itself)"
done
grep -q 'the review findings outlasted' "$T/abandon.txt" && ok || bad "F: br_abandon's why line is unchanged"

# ── §P: a person's CHANGES_REQUESTED is not ours ───────────────────────────
RESET; mkrows CHANGES_REQUESTED operator User "$(printf 'Please rename this.\n\n- [BLOCK] naming')"
TERM
[ "$(n abandon)" = 1 ] && ok || bad "P1: a person's REQUEST_CHANGES takes today's path (abandon), got $(n abandon)"
[ "$(n gh)" = 0 ] && ok || bad "P1: a person's review is never dismissed: $(cat "$T/gh.txt" 2>/dev/null)"
# A person's APPROVED newest, with an older lead BLOCK standing: the lead's is still ours.
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES" APPROVED operator User "lgtm"
TERM
[ "$(OUTCOME)" = CAP_NOTES ] && ok || bad "P2: a person's APPROVE beside the lead's notes-only BLOCK -> CAP_NOTES, got '$(OUTCOME)'"
# A DISMISSED harness review no longer stands: nothing to cap-note, today's path.
RESET; mkrows DISMISSED 'cromford[bot]' Bot "$LEAD_NOTES"
TERM
[ "$(OUTCOME)" = "" ] && ok || bad "P3: a dismissed review stands for nothing, got '$(OUTCOME)'"

# ── §U: unreadable ─────────────────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"; touch "$T/rows-unreadable"
TERM; RC=$?
[ "$RC" = 0 ] && [ "$(n abandon)" = 0 ] && [ "$(OUTCOME)" = "" ] && ok || bad "U1: an unreadable reviews list closes nothing and records nothing (rc $RC, abandon $(n abandon), outcome '$(OUTCOME)')"
grep -qi 'retried next tick' "$T/say.txt" && ok || bad "U1: the log says it is retried: $(cat "$T/say.txt")"
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"; touch "$T/head-unreadable"
TERM; RC=$?
[ "$RC" = 0 ] && [ "$(n abandon)" = 0 ] && ok || bad "U2: an unreadable head closes nothing (rc $RC, abandon $(n abandon))"

# ── §O: observe mode ───────────────────────────────────────────────────────
RESET; mkrows CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES"
( . "$T/drv.sh"; OBSERVE=1 br_fix_terminal tproj 9 review-changes-requested "$URL" - TP-9 )
grep -q 'WOULD' "$T/say.txt" && ok || bad "O1: observe mode says WOULD: $(cat "$T/say.txt")"
[ "$(OUTCOME)" = "" ] && [ "$(n lead-verdict)" = 0 ] && [ "$(n alerts)" = 0 ] && [ "$(n gh)" = 0 ] && ok \
  || bad "O1: observe mode writes, requests, dismisses and alerts nothing"

# ── §W: the terminal word ──────────────────────────────────────────────────
W=$( . "$T/drv.sh"; br_fix_terminal_word review-changes-requested )
case "$W" in *ABANDONED*notes*|*notes*ABANDONED*) ok ;; *) bad "W1: the review terminal word must name both outcomes (merge with notes / ABANDONED), got '$W'" ;; esac
[ "$( . "$T/drv.sh"; br_fix_terminal_word conflict-unresolvable )" = 'REBUILD FRESH instead' ] && ok || bad "W2: other reasons unchanged"

echo "br-cap-notes.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
