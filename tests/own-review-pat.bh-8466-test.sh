#!/bin/bash
# tests/own-review-pat.bh-8466-test.sh — under PAT auth the review lane still
# recognises its OWN reviews (BH-8466). A lane on the default PAT posts its
# review as the operator login. BH-8419 made harness_verdict_author_match
# Apps-only, so every "is this our review" reader stopped seeing that row: the
# lane bought the same review on every tick and never dismissed its own
# standing CHANGES_REQUESTED. The own-review readers now ask
# harness_own_review_match (an App, or the bare operator login), and an
# operator-login row counts only with the harness footer or the lead marker.
#   §M  the matcher tables (bin/lib/gh-pr-list.sh)
#   §R  bin/review-prs.sh driven: R1 tick 2 buys 0, R2 own CR dismissed once,
#       R3 no footer = a person's (1 bought, 0 dismissed), R1b/R2b the App
#       unchanged, R4 the re-review request from the operator login
#   §B  blocked-resolver br_review_harness_pick, br_review_after, the bh-8307
#       br_rsn_pick, builder-review br_fetch
#   §C  br_cap_notes: operator login + footer or lead marker is ours
#   §P  the `github auth: default PAT` log line and one warn ALERTS line per
#       project per UTC day
# Every gh and agent call is a local stub: 0 network calls.
# Run from anywhere: bash tests/own-review-pat.bh-8466-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# Named by path so bin/test-impact.sh maps a change to them onto this suite.
for f in bin/lib/gh-pr-list.sh bin/review-prs.sh bin/blocked-resolver.sh bin/lib/builder-review.sh \
         bin/lib/br/cap.sh bin/blocked-resolver.d/bh-8307-review-skip-note.sh; do
  [ -r "$DIR/$f" ] && ok || bad "0: $f is missing"
done
export TEST_ROOT="$T"
FOOT='Automated harness review (Fable) of'   # a LITERAL: the suite must not import the marker it pins

# ── §M: the matcher tables ───────────────────────────────────────────────────
NOHUB="$T/nohub"; mkdir -p "$NOHUB"
# hpl <fn> <args...> -> rc of the named gh-pr-list.sh function, operator login operator
# (HPL_OP overrides it; HPL_OP=-unset leaves it unset after the lib loads)
hpl() {
  env -i PATH="$PATH" HARNESS="$NOHUB" HPL_OP="${HPL_OP-operator}" bash -c 'HARNESS_OPERATOR_LOGIN="$HPL_OP"; . "$1/bin/lib/gh-pr-list.sh"
    if [ "$HPL_OP" = -unset ]; then unset HARNESS_OPERATOR_LOGIN; else HARNESS_OPERATOR_LOGIN="$HPL_OP"; fi
    shift; "$@"' _ "$DIR" "$@"
}
for l in 'cromford[bot]' app/cromford operator; do
  hpl harness_own_review_match "$l" && ok || bad "M1: harness_own_review_match '$l' must be rc 0"
done
for l in 'operator[bot]' app/operator operator-mac operator 'cromford-builders[bot]' app/cromford-builders 'some-ci[bot]' some-person ''; do
  hpl harness_own_review_match "$l" && bad "M2: harness_own_review_match '$l' must be rc 1" || ok
done
HPL_OP='' hpl harness_own_review_match operator && bad "M3: an empty HARNESS_OPERATOR_LOGIN must match no plain login" || ok
HPL_OP=-unset hpl harness_own_review_match operator && bad "M3: an unset HARNESS_OPERATOR_LOGIN must match no plain login" || ok
hpl harness_verdict_author_match operator && bad "M4: harness_verdict_author_match operator must stay rc 1 (Apps only)" || ok
BODY_FOOT=$(printf 'Static review.\n\nVERDICT: REQUEST_CHANGES\n\n---\n_%s S1. Static review — no build run._' "$FOOT")
hpl harness_own_review_marked "$BODY_FOOT" && ok || bad "M5: a body with the harness footer must be marked"
hpl harness_own_review_marked '<!-- lead-review:abc -->
Lead review' && ok || bad "M5: a body that starts with the lead marker must be marked"
for b in 'harness review footer' 'Automated harness review, by hand' 'notes first
<!-- lead-review:abc -->' '<!-- harness:rereview-requested abcdef1 -->' '' "quoting $FOOT"; do
  hpl harness_own_review_marked "$b" && bad "M6: '$b' must not be marked" || ok
done
hpl harness_own_review_row operator "$BODY_FOOT" && ok || bad "M7: operator + footer is our own row"
hpl harness_own_review_row operator 'Three things block this.' && bad "M7: operator with no footer is a person's row" || ok
hpl harness_own_review_row 'cromford[bot]' 'no footer' && ok || bad "M7: an App row keeps today's rule (no footer needed)"
hpl harness_own_review_row 'cromford-builders[bot]' "$BODY_FOOT" && bad "M7: the builders App is never our review" || ok
# The footer is one string in three places.
FOOTER_LIB=$(env -i PATH="$PATH" HARNESS="$NOHUB" bash -c '. "$1/bin/lib/gh-pr-list.sh"; printf "%s|" "$HARNESS_OWN_REVIEW_FOOTER"' _ "$DIR")
RPM=$(sed -nE 's/^RP_MARKER="([^"]*)".*/\1/p' "$RP" | head -1)
BRM=$(sed -nE 's/^BR_MARKER="([^"]*)".*/\1/p' "$DIR/bin/lib/builder-review.sh" | head -1)
[ -n "$RPM" ] && [ "$FOOTER_LIB" = "$RPM |" ] && ok || bad "M8: HARNESS_OWN_REVIEW_FOOTER '$FOOTER_LIB' must be RP_MARKER '$RPM' + a space"
[ -n "$BRM" ] && [ "$FOOTER_LIB" = "$BRM |" ] && ok || bad "M8: HARNESS_OWN_REVIEW_FOOTER must be BR_MARKER '$BRM' + a space"
[ "$FOOTER_LIB" = "$FOOT |" ] && ok || bad "M8: the footer is not the posted text '$FOOT '"

# ── the lane fixture (shape of tests/review-prs-followups.bh-989-test.sh) ────
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; exit 0 ;;
    view)
      case "$*" in
        *--json\ state*) printf 'OPEN\n'; exit 0 ;;
        *--json\ mergeCommit*) printf '\n'; exit 0 ;;
      esac
      printf '## What\nSomething an outside author wrote.\n'; exit 0 ;;
    review) printf '%s\n' "${GH_TOKEN:-none}" >> "$TEST_ROOT/posts.log"; exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  shift
  Q=""; PATHARG=""; INC=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) Q="${2:-}"; shift 2 ;;
      -X|--method|-H|--header) shift 2 ;;
      -f|-F|--field|--raw-field) shift 2 ;;
      -i|--include) INC=1; shift ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  # A REST read through bin/lib/gh-rest.sh asks with -i: the status line comes first.
  emit() { [ "$INC" = 1 ] && printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n'
           if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s\n' "$1"; fi; }
  PATHARG="${PATHARG%%\?*}"
  case "$PATHARG" in
    */pulls)
      emit "$(jq -nc --arg h "${PR_HEAD:-S1}" --arg a "${PR_AUTHOR:-externaldev}" '[{number:7, head:{sha:$h, ref:"", repo:{full_name:"o/tproj"}},
        base:{ref:"main"}, user:{login:$a, type:(if ($a | endswith("[bot]")) then "Bot" else "User" end)}, title:"Change under review",
        draft:false, state:"open", body:"", labels:[], html_url:"https://github.com/o/tproj/pull/7"}]')"
      exit 0 ;;
    rate_limit)
      printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n'
      exit 0 ;;
    */reviews/*/dismissals) exit 0 ;;
    */pulls/*/reviews/*)
      emit "$(jq -c --argjson id "${PATHARG##*/}" '.[] | select(.id == $id)' "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/*/reviews) emit "$(cat "$TEST_ROOT/reviews.json")"; exit 0 ;;
    */pulls/[0-9]*) emit "$(jq -nc '{body:"## What\nSomething an outside author wrote.\n"}')"; exit 0 ;;
    *actions/runs*) exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB
cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: 2\nVERDICT: %s\n' "${AGENT_VERDICT:-REQUEST_CHANGES}" > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  scratch_rm "$T/h" 2>/dev/null
  rm -f "$T/agent-calls.log" "$T/gh-calls.log" "$T/posts.log" "$T/reviews.json"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  # the lane runs from its installed copy, beside its own lib closure
  scratch_install_closure bin/review-prs.sh "$T/h" >/dev/null || return 1
  cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
  mkdir -p "$T/h/catalog/lanes.d"; cp "$DIR/catalog/lanes.d/_lib.json" "$T/h/catalog/lanes.d/"
  mrs_fixture "$T/h" tproj
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 192.0.2.1\n' > "$T/h/fleet.conf"
  printf '[]\n' > "$T/reviews.json"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
}
arm_app() { # arm_app <token the minter prints>: an App-armed box
  printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$T/h/env/github-app.env"
  printf '#!/bin/bash\nprintf "%s\\n"\n' "$1" > "$T/h/bin/gh-token.sh"
  chmod +x "$T/h/bin/gh-token.sh"
}
footer_body() { # footer_body <sha>
  printf 'Static review.\n1. lib/x.ts:4 leaks a token into the log.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_%s %s. Static review — no build run._' "$FOOT" "$1"
}
PERSON_BODY='Three things block this:

- no gate proof in the PR body

VERDICT: REQUEST_CHANGES'
review_row() { # review_row <id> <state> <commit> <login> <body>
  jq -nc --argjson id "$1" --arg st "$2" --arg c "$3" --arg l "$4" --arg b "$5" \
    '{id:$id, state:$st, commit_id:$c, user:{login:$l, type:(if ($l | endswith("[bot]")) then "Bot" else "User" end)}, body:$b}'
}
reviews() { printf '%s\n' "$1" > "$T/reviews.json"; }
run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" HARNESS_OPERATOR_LOGIN=operator \
    GH_TOKEN="ghp_fixture_default" PR_HEAD="${PR_HEAD:-S1}" PR_AUTHOR="${PR_AUTHOR:-externaldev}" \
    GH_BUDGET_TTL_S=0 AGENT_VERDICT="${AGENT_VERDICT:-REQUEST_CHANGES}" \
    bash "$T/h/bin/review-prs.sh" tproj >/dev/null 2>&1
}
calls() { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" || echo 0; }
dismissals() { grep -c -F -- "/reviews/$1/dismissals" "$T/gh-calls.log" 2>/dev/null || true; }
rplog() { cat "$T/h/logs/pr-reviews.log" 2>/dev/null; }
patlines() { local n; n=$(grep -c 'github auth: default PAT' "$1" 2>/dev/null); echo "${n:-0}"; }

# ── §R: bin/review-prs.sh ────────────────────────────────────────────────────
# R1: the lane's own review at this head, posted on the PAT (operator, User, footer).
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 operator "$(footer_body S1)")]"
run_lane; run_lane
[ "$(calls)" -eq 0 ] && ok || bad "R1: the lane re-bought its own PAT-posted review: $(calls) agent call(s) over 2 ticks, expected 0"
grep -q 'not re-reviewed: o/tproj already carries' <<<"$(rplog)" && ok || bad "R1: no 'not re-reviewed' line: $(rplog)"
# R1b: the same row from the App: unchanged.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 'cromford[bot]' "$(footer_body S1)")]"
run_lane; run_lane
[ "$(calls)" -eq 0 ] && ok || bad "R1b: the App row stopped deduping: $(calls) call(s)"
# R2: the lane's own CHANGES_REQUESTED at an OLDER head on a harness PR: dismissed exactly once over 2 ticks.
fresh_harness
reviews "[$(review_row 21 CHANGES_REQUESTED S0 operator "$(footer_body S0)")]"
PR_AUTHOR=operator run_lane; PR_AUTHOR=operator run_lane
[ "$(dismissals 21)" = 1 ] && ok || bad "R2: the own PAT-posted CR must be dismissed exactly once, got $(dismissals 21): $(cat "$T/gh-calls.log" 2>/dev/null | grep dismiss)"
grep -q 'dismissed its own standing CHANGES_REQUESTED review 21' <<<"$(rplog)" && ok || bad "R2: no dismissal line: $(rplog)"
# R2b: the App's: unchanged (1 dismissal).
fresh_harness
reviews "[$(review_row 22 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0)")]"
PR_AUTHOR=operator run_lane; PR_AUTHOR=operator run_lane
[ "$(dismissals 22)" = 1 ] && ok || bad "R2b: the App's CR must be dismissed exactly once, got $(dismissals 22)"
# R3: operator with NO footer is a person's review: bought, and never dismissed.
fresh_harness
reviews "[$(review_row 31 CHANGES_REQUESTED S1 operator "$PERSON_BODY")]"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "R3: a person's review must not dedupe the paid review: $(calls) call(s), expected 1"
fresh_harness
reviews "[$(review_row 32 CHANGES_REQUESTED S0 operator "$PERSON_BODY")]"
PR_AUTHOR=operator run_lane
[ "$(dismissals 32)" = 0 ] && ok || bad "R3: a person's CR (no footer) was dismissed: $(grep dismiss "$T/gh-calls.log")"
# A row from someone else WITH the footer text is still not ours.
fresh_harness
reviews "[$(review_row 33 CHANGES_REQUESTED S1 some-person "$(footer_body S1)")]"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "R3: a non-operator person's pasted footer deduped the review: $(calls) call(s)"

# R4: the re-review request block (the real block, lifted as BH-1992's suite does).
awk '/# >>> review-prs rereview request/{f=1} f{print} /# <<< review-prs rereview request/{f=0}' "$RP" > "$T/rp-rereq.sh"
[ -s "$T/rp-rereq.sh" ] && ok || bad "R4: the rereview request block markers are missing"
RQSHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REREQ() { # REREQ <login> -> RP_REREQ after one pass for PR 7 at $RQSHA
  jq -nc --arg l "$1" --arg b "Stale evidence only.

<!-- harness:rereview-requested $RQSHA -->" '[{user:{login:$l}, body:$b}]' > "$T/rq-comments.json"
  jq -n --arg s "$RQSHA" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$T/rq-state.json"
  rm -f "$T/rq.log"
  env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$1/bin/lib/fixround-preflight.sh"
    STATE="$2"; LOG="$3"; PROJECT=tproj; SLUG=o/tproj; NUM=7; SHA="$4"; DONE="$4"; CF="$5"
    STAMP() { printf x; }
    gh_rest_issue_comments() { cat "$CF"; }
    . "$6"; printf "%s" "$RP_REREQ"' _ "$DIR" "$T/rq-state.json" "$T/rq.log" "$RQSHA" "$T/rq-comments.json" "$T/rp-rereq.sh" 2>/dev/null
}
[ "$(REREQ operator)" = 1 ] && ok || bad "R4: the operator login's tagged comment must request the re-review"
grep -q 're-review requested by operator' "$T/rq.log" 2>/dev/null && ok || bad "R4: the request by operator was not logged: $(cat "$T/rq.log" 2>/dev/null)"
[ "$(REREQ some-person)" = 0 ] && ok || bad "R4: a non-operator person's tagged comment must request nothing"
[ "$(REREQ 'cromford[bot]')" = 1 ] && ok || bad "R4: the App's tagged comment must still request the re-review"

# ── §B: the resolver and builder readers ─────────────────────────────────────
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
: > "$T/brfns.sh"
for fn in br_review_harness_pick br_review_after; do
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/brfns.sh"
done
grep -q '^br_review_harness_pick()' "$T/brfns.sh" && grep -q '^br_review_after()' "$T/brfns.sh" && ok || bad "B0: could not extract the resolver readers"
BRFOOT=$(sed -nE "s/^BR_REVIEW_FOOTER='([^']*)'.*/\\1/p" "$T/br-corpus.sh" | head -1)
H40=$(printf 'c%.0s' {1..40})
rows() { # rows <login> <body> [state] [type] -> br_review_rows-shaped JSON
  jq -nc --arg l "$1" --arg b "$2" --arg s "${3:-CHANGES_REQUESTED}" --arg t "${4:-User}" --arg c "$H40" \
    '[{id:501, l:$l, t:$t, a:"OWNER", c:$c, s:$s, b:$b}]'
}
BR() { # BR <cmd...> in a shell with the real gh-pr-list.sh and the lifted readers
  env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator BR_REVIEW_FOOTER="$BRFOOT" T="$T" \
    bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; shift 2; "$@"' _ "$DIR" "$T/brfns.sh" "$@"
}
FB=$(footer_body "$H40")
BR br_review_harness_pick "$H40" "$(rows operator "$FB")" >/dev/null && ok || bad "B1: operator + footer at the head must be picked"
BR br_review_harness_pick "$H40" "$(rows operator "$PERSON_BODY")" >/dev/null && bad "B1: operator with no footer was picked" || ok
BR br_review_harness_pick "$H40" "$(rows 'cromford-builders[bot]' "$FB" CHANGES_REQUESTED Bot)" >/dev/null && bad "B1: the builders App was picked" || ok
BR br_review_harness_pick "$H40" "$(rows 'cromford[bot]' "$FB" CHANGES_REQUESTED Bot)" >/dev/null && ok || bad "B1: the App row must still be picked"
# br_review_after reads `gh api .../reviews --jq <filter>`; the stub applies the real filter.
cat > "$T/fakebin/gh-after" <<'STUB'
#!/bin/bash
Q=""; prev=""; for a in "$@"; do [ "$prev" = --jq ] && Q="$a"; prev="$a"; done
jq -r "$Q" "$TEST_ROOT/after.json"
STUB
chmod +x "$T/fakebin/gh-after"
AFTER() { # AFTER <login> <body> -> rc of br_review_after
  jq -nc --arg l "$1" --arg b "$2" --arg c "$H40" '[{user:{login:$l}, commit_id:$c, submitted_at:"2026-10-26T12:00:00Z", body:$b}]' > "$T/after.json"
  env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator TEST_ROOT="$T" \
    bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; GHA="$3/fakebin/gh-after"; gh() { "$GHA" "$@"; }; br_review_after o/r 7 "$4" 1000' _ "$DIR" "$T/brfns.sh" "$T" "$H40"
}
AFTER operator "$FB"; rc=$?; [ "$rc" = 0 ] && ok || bad "B2: operator + footer after the epoch must be rc 0, got $rc"
AFTER operator "$PERSON_BODY"; rc=$?; [ "$rc" = 1 ] && ok || bad "B2: operator with no footer must be rc 1, got $rc"
AFTER operator '<!-- lead-review:abc -->
notes'; rc=$?; [ "$rc" = 0 ] && ok || bad "B2: operator + lead marker must be rc 0, got $rc"
AFTER 'cromford[bot]' "$PERSON_BODY"; rc=$?; [ "$rc" = 0 ] && ok || bad "B2: the App with no footer keeps today's rc 0, got $rc"
# br_fetch (bin/lib/builder-review.sh), the real lib.
FETCH() { # FETCH <login> <body> -> rc, then the out file
  jq -nc --arg l "$1" --arg b "$2" --arg c "$H40" '[{id:1, user:{login:$l}, commit_id:$c, state:"CHANGES_REQUESTED", submitted_at:"2026-10-26T12:00:00Z", body:$b}]' > "$T/fetch.json"
  rm -f "$T/fetch.out"
  env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator \
    bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$1/bin/lib/verdict-parse.sh"; . "$1/bin/lib/builder-review.sh"
      RF="$2"; gh_rest() { cat "$RF"; }; br_fetch o/r 7 "$3" "$4"' _ "$DIR" "$T/fetch.json" "$H40" "$T/fetch.out" >/dev/null 2>&1
}
FETCH operator "$FB"; rc=$?
[ "$rc" = 0 ] && grep -q '^reviewer: operator' "$T/fetch.out" 2>/dev/null && ok || bad "B3: operator + marker must be rc 0 with reviewer operator, got rc $rc: $(cat "$T/fetch.out" 2>/dev/null | head -3)"
FETCH operator "$PERSON_BODY"; rc=$?
[ "$rc" = 1 ] && ok || bad "B3: operator without the marker must be rc 1, got $rc"
FETCH 'cromford-builders[bot]' "$FB"; rc=$?
[ "$rc" = 1 ] && ok || bad "B3: the builders App must be rc 1, got $rc"
# br_rsn_pick (bin/blocked-resolver.d/bh-8307-review-skip-note.sh): no `author` reason for our own row.
RSN() { env -i PATH="$PATH" HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator BR_REVIEW_FOOTER="$BRFOOT" \
          bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$1/bin/blocked-resolver.d/bh-8307-review-skip-note.sh"; br_rsn_pick "$2" "$3"' _ "$DIR" "$H40" "$1"; }
out=$(RSN "$(rows operator "$FB")"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "B4: operator + footer CR must give no skip note, got rc $rc '$out'"
out=$(RSN "$(rows operator "$PERSON_BODY")"); rc=$?
[ "$rc" = 0 ] && [ "$(cut -f3 <<<"$out")" = author,footer ] && ok || bad "B4: operator without footer is a person, noted as author,footer, got rc $rc '$out'"
out=$(RSN "$(rows some-person "$FB")"); rc=$?
[ "$rc" = 0 ] && grep -q 'author' <<<"$out" && ok || bad "B4: a non-operator person keeps the 'author' reason, got rc $rc '$out'"

# ── §C: br_cap_notes (the 8419 suite's driver, the real helper) ──────────────
: > "$T/fns.sh"
for fn in br_cap_notes br_floor_stands br_cap_key br_rkey br_file br_load br_save \
          br_record br_set_outcome br_set_field br_num br_shape br_fix_cap br_review_fix_cap br_slug_of_url br_is_external; do
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/fns.sh"
done
grep -q '^br_cap_notes()' "$T/fns.sh" && ok || bad "C0: could not extract br_cap_notes"
HC="$T/hc"; mkdir -p "$HC/bin" "$HC/state/blocked-resolver" "$HC/logs"
printf '#!/bin/bash\nexit 0\n' > "$HC/bin/lane-alert.sh"
printf '#!/bin/bash\necho "requested lead review #new"\nexit 0\n' > "$HC/bin/lead-verdict.sh"
chmod +x "$HC/bin/"*.sh
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
H="$HC"; ST="$HC/state/blocked-resolver"; LOG="$T/say.txt"; OBSERVE=0
export HARNESS="$NOHUB" HARNESS_OPERATOR_LOGIN=operator
unset HARNESS_VERDICT_AUTHORS
STAMP() { echo T; }  # determinism: ok a log stamp no assertion reads
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { printf '%s' "$H40"; }
br_review_rows() { cat "$T/caprows.json"; }
_jobs_req() { return 0; }
job_ledger_put() { return 0; }
setting_get() { return 2; }
. "$DIR/bin/lib/gh-pr-list.sh"
gh_rest() { printf '%s\n' "\$*" >> "$T/capgh.txt"; return 0; }
. "$DIR/bin/lib/review-level.sh"
. "$T/fns.sh"
EOF
caprows() { local out='[]'; while [ $# -ge 5 ]; do out=$(jq -c --argjson id "$1" --arg s "$2" --arg l "$3" --arg t "$4" --arg b "$5" --arg c "$H40" \
  '. + [{id:$id, l:$l, t:$t, a:"MEMBER", c:$c, s:$s, b:$b}]' <<<"$out"); shift 5; done; printf '%s' "$out" > "$T/caprows.json"; }
LEAD_NOTES='<!-- lead-review:abc -->
Lead review (automated lead-review lane) of cccccccccccc

- [NOTE] bin/x.sh:4: the log line could name the pr

VERDICT: BLOCK'
# A notes-only footer review: no ALWAYS-BLOCK line, so the floor does not stand.
FOOT_NOTES=$(printf -- '- [NOTE] bin/x.sh:4: the log line could name the pr\n\nVERDICT: REQUEST_CHANGES\n\n---\n_%s %s. Static review — no build run._' "$FOOT" "$H40")
CRESET() { local _p; for _p in "$HC/state/blocked-resolver"/* "$T"/{say,capgh}.txt; do scratch_rm "$_p" 2>/dev/null; done
           mkdir -p "$HC/state/blocked-resolver/tproj"
           jq -nc '{project:"tproj",rkey:"tproj-TP-9",fixrounds:2,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$HC/state/blocked-resolver/tproj/tproj-TP-9.json"; }
CAP() { ( . "$T/drv.sh"; br_cap_notes tproj tproj-TP-9 review-changes-requested "$URL" - TP-9 ); }
OUTCOME() { jq -r '.outcome // ""' "$HC/state/blocked-resolver/tproj/tproj-TP-9.json"; }
puts() { grep -c '/dismissals' "$T/capgh.txt" 2>/dev/null || echo 0; }
CRESET; caprows 701 CHANGES_REQUESTED operator User "$FOOT_NOTES"
CAP; RC=$?
[ "$RC" = 0 ] && [ "$(puts)" = 1 ] && ok || bad "C1: operator + the real footer is ours: rc $RC, $(puts) dismissals ($(cat "$T/say.txt" 2>/dev/null))"
grep -q 'reviews/701/dismissals' "$T/capgh.txt" 2>/dev/null && ok || bad "C1: the dismissal is for 701"
[ "$(OUTCOME)" = CAP_NOTES ] && ok || bad "C1: outcome CAP_NOTES, got '$(OUTCOME)'"
CRESET; caprows 702 CHANGES_REQUESTED operator User "$LEAD_NOTES"
CAP; RC=$?
[ "$RC" = 0 ] && [ "$(puts)" = 1 ] && ok || bad "C2: operator + lead marker is ours: rc $RC, $(puts) dismissals"
CRESET; caprows 703 CHANGES_REQUESTED operator User "$PERSON_BODY"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C3: operator with no footer is a person: rc $RC, $(puts) dismissals"
CRESET; caprows 704 CHANGES_REQUESTED 'cromford[bot]' Bot "$LEAD_NOTES" 705 CHANGES_REQUESTED operator User "$PERSON_BODY"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C4: the App's lead row + a person's operator block: rc $RC, $(puts) dismissals"
CRESET; caprows 706 CHANGES_REQUESTED some-person User "$FOOT_NOTES"
CAP; RC=$?
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "C5: a non-operator person with the footer stands: rc $RC, $(puts) dismissals"

# ── §P: the PAT ledger line and the daily warn ───────────────────────────────
MARKF="$T/h/state/review-prs-pat-alert/tproj"
# P1: an armed box whose mint fell to the PAT: a log line per post, one ALERTS line a day.
fresh_harness; arm_app ghp_pat
PR_HEAD=S1 run_lane
[ "$(patlines "$T/h/logs/pr-reviews.log")" = 1 ] && ok || bad "P1: no 'github auth: default PAT' log line on a PAT post: $(rplog | tail -3)"
[ "$(patlines "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "P1: want 1 ALERTS line, got $(patlines "$T/h/logs/ALERTS.log"): $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep 'github auth: default PAT' "$T/h/logs/ALERTS.log" 2>/dev/null | grep -q 'tproj' && ok || bad "P1: the ALERTS line must name the project"
grep -q 'ghp_pat' "$T/h/logs/ALERTS.log" "$T/h/logs/pr-reviews.log" 2>/dev/null && bad "P1: a token value reached a log" || ok
# A new head with a verdict on record waits for green CI; an empty ledger reviews at once.
printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
PR_HEAD=S2 run_lane
[ "$(grep -c . "$T/posts.log" 2>/dev/null)" = 2 ] && ok || bad "P2 setup: want 2 posts, got $(cat "$T/posts.log" 2>/dev/null)"
[ "$(patlines "$T/h/logs/pr-reviews.log")" = 2 ] && ok || bad "P2: want 2 log lines after 2 PAT posts, got $(patlines "$T/h/logs/pr-reviews.log")"
[ "$(patlines "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "P2: a second post the same day must not alert again: $(patlines "$T/h/logs/ALERTS.log")"
printf '1970-01-01\n' > "$MARKF"
printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
PR_HEAD=S3 run_lane
[ "$(patlines "$T/h/logs/ALERTS.log")" = 2 ] && ok || bad "P3: an older marker day must alert again: $(patlines "$T/h/logs/ALERTS.log")"
# P4: the App minted an installation token: silent.
fresh_harness; arm_app ghs_install
run_lane
[ "$(grep -c . "$T/posts.log" 2>/dev/null)" = 1 ] && ok || bad "P4 setup: no post"
[ "$(patlines "$T/h/logs/pr-reviews.log")" = 0 ] && [ "$(patlines "$T/h/logs/ALERTS.log")" = 0 ] && ok || bad "P4: a ghs_ post must be silent"
# P5: an unarmed box runs on the PAT by design: silent.
fresh_harness
run_lane
[ "$(grep -c . "$T/posts.log" 2>/dev/null)" = 1 ] && ok || bad "P5 setup: no post"
[ "$(patlines "$T/h/logs/pr-reviews.log")" = 0 ] && [ "$(patlines "$T/h/logs/ALERTS.log")" = 0 ] && ok || bad "P5: an unarmed box must be silent"
# P6: an APPROVE on the reviewing App's own PR goes out on the PAT on purpose (RP_POST_APP=0): silent.
fresh_harness; arm_app ghp_pat
PR_AUTHOR='cromford[bot]' AGENT_VERDICT=APPROVE run_lane
[ "$(grep -c . "$T/posts.log" 2>/dev/null)" = 1 ] && ok || bad "P6 setup: want 1 post, got $(cat "$T/posts.log" 2>/dev/null)"
[ "$(patlines "$T/h/logs/ALERTS.log")" = 0 ] && [ "$(patlines "$T/h/logs/pr-reviews.log")" = 0 ] && ok || bad "P6: a deliberate PAT approve must be silent"

echo "own-review-pat.bh-8466: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
