#!/bin/bash
# tests/fixround-preflight.bh-1794-test.sh — BH-1794: a fix round starts from the
# PR as it is NOW, not from the review record it was queued from.
#
# THE INCIDENT (project-3 #378, TK-202, 2026-09-23). Round 1 fixed the code and CI
# went green on b8e228d3. The re-review still blocked, on paperwork: the PR
# body's Evidence block said HARNESS_EXIT 1 / head-red, and the reviewer's token
# 403'd on check-runs. A second paid round and a second re-review were spent
# only to refresh that block.
#
# THE ACCEPTANCE ROWS (the ticket's five, red first, plus the wiring):
#   T1  findings on an old sha, head moved, CI green  -> no fix round, re-review
#   T2  the only blocker is stale Evidence            -> live-CI block written,
#                                                        re-review asked, no round
#   T3  a real finding at head                        -> the round runs and its
#                                                        prompt carries the live
#                                                        head sha + check states
#   T4  check-runs 403                                -> "unreadable", never "red"
#   T5  after a fix round pushes                      -> the body names the NEW
#                                                        head's CI
#   T6  the review lanes' prompts carry the live CI (bin/review-prs.sh and the
#       conductor's mc_rereview), and bin/review-prs.sh honours the re-review
#       request exactly once per head.
#   T7  the knob: BR_FIXROUND_PREFLIGHT=0 is today's behaviour, no GitHub read.
#
# Every assertion is about what ran: the gh call log, the PR body the fake
# GitHub holds after the call, the agent-call prompt, the resolver's record.
# Run from anywhere: tests/fixround-preflight.bh-1794-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/fixround-preflight.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/fixround-preflight.sh does not exist"; echo "fixround-preflight.bh-1794: 0 passed, 1 failed"; exit 1; }

OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the findings were posted on
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # the PR's head now
PUSHED=cccccccccccccccccccccccccccccccccccccccc
SLUG=o/tproj
URL="https://github.com/$SLUG/pull/7"

H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$T/fakebin" "$T/gh"

# ---------------------------------------------------------------------------
# THE FAKE GITHUB. REST shapes as GitHub answers them; the PR body is a file the
# PATCH really rewrites, so "the block is in the body" is a fact about the body.
#   $T/gh/runs-<sha>.json     actions/runs?head_sha=<sha>
#   $T/gh/checks-<sha>.json   commits/<sha>/check-runs
#   $T/gh/runs-403, checks-403   that endpoint refuses (HTTP 403)
#   $T/gh/pr-7.json           the PR object (body, head)
# ---------------------------------------------------------------------------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
case "\$*" in
  *"-X PATCH"*"/pulls/"*)
    N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    F=""; for A in "\$@"; do case "\$A" in body=@*) F="\${A#body=@}" ;; esac; done
    [ -f "$T/gh/patch-fail" ] && { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    jq --rawfile b "\$F" '.body = \$b' "$T/gh/pr-\$N.json" > "$T/gh/pr.tmp" && mv "$T/gh/pr.tmp" "$T/gh/pr-\$N.json"
    printf 'PATCH %s\n' "\$N" >> "$T/patches.log"
    echo '{}' ;;
  *"/actions/runs?head_sha="*)
    S=\$(printf '%s' "\$*" | sed -nE 's#.*head_sha=([0-9a-f]+).*#\1#p')
    [ -f "$T/gh/runs-403" ] && { echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1; }
    if [ -f "$T/gh/runs-\$S.json" ]; then cat "$T/gh/runs-\$S.json"; else echo '{"total_count":0,"workflow_runs":[]}'; fi ;;
  *"/check-runs"*)
    S=\$(printf '%s' "\$*" | sed -nE 's#.*/commits/([0-9a-f]+)/check-runs.*#\1#p')
    [ -f "$T/gh/checks-403" ] && { echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1; }
    if [ -f "$T/gh/checks-\$S.json" ]; then cat "$T/gh/checks-\$S.json"; else echo '{"total_count":0,"check_runs":[]}'; fi ;;
  *"/pulls/"*)
    N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    if [ -n "\$JQX" ]; then jq -r "\$JQX" "$T/gh/pr-\$N.json"; else cat "$T/gh/pr-\$N.json"; fi ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

RUNS() { # RUNS <sha> <conclusion|in_progress> — one workflow run named CI
  if [ "$2" = in_progress ]; then
    jq -nc --arg s "$1" '{total_count:1, workflow_runs:[{id:11, name:"CI", head_sha:$s, status:"in_progress", conclusion:null, run_attempt:1, run_started_at:"2026-09-23T21:10:00Z", html_url:"https://github.com/o/tproj/actions/runs/11"}]}' > "$T/gh/runs-$1.json"
  else
    jq -nc --arg s "$1" --arg c "$2" '{total_count:1, workflow_runs:[{id:11, name:"CI", head_sha:$s, status:"completed", conclusion:$c, run_attempt:1, run_started_at:"2026-09-23T21:10:00Z", html_url:"https://github.com/o/tproj/actions/runs/11"}]}' > "$T/gh/runs-$1.json"
  fi
}
CHECKS() { # CHECKS <sha> <conclusion>
  jq -nc --arg c "$2" '{total_count:1, check_runs:[{id:21, name:"unit (4848)", status:"completed", conclusion:$c, started_at:"2026-09-23T21:11:00Z", html_url:"https://github.com/o/tproj/runs/21"}]}' > "$T/gh/checks-$1.json"
}
PRBODY() { # PRBODY <head> <body>
  jq -nc --arg h "$1" --arg b "$2" '{number:7, head:{sha:$h, ref:"ticket/TK-202"}, body:$b}' > "$T/gh/pr-7.json"
}
body() { jq -r '.body' "$T/gh/pr-7.json"; }
reset_gh() { rm -f "$T/gh/"* "$T/gh.log" "$T/patches.log"; : > "$T/gh.log"; }
patches() { if [ -f "$T/patches.log" ]; then wc -l < "$T/patches.log" | tr -d ' '; else echo 0; fi; }

STALE_BODY='## What

TK-202.

## Evidence

| check | result |
|---|---|
| repo suite, run by the harness | `HARNESS_EXIT: 1` |
| reproduction gate | head-red |'

# The findings exactly as the review lanes post them: numbered, severity-tagged,
# and the footer naming the head they judged.
STALE_FINDINGS="The code change is right; the paperwork is not.

1. BLOCKER — the PR body Evidence block still reads HARNESS_EXIT: 1 and head-red; I cannot verify CI (check-runs returns 403), so this head is unverified.
2. Nit: the commit message says 'fixes' twice.

TIER: 2
VERDICT: REQUEST_CHANGES

---
_Automated harness review (Fable) of $NEW. Static review — no build run._"
REAL_FINDINGS="1. HIGH src/rate.ts:12 the route is unauthenticated — add the session guard.
2. BLOCKER — the Evidence block says head-red.

TIER: 2
VERDICT: REQUEST_CHANGES

---
_Automated harness review (Fable) of $NEW. Static review — no build run._"
OLD_FINDINGS="1. HIGH src/rate.ts:12 the route is unauthenticated.

VERDICT: BLOCK

---
_Head-bound harness re-review (claude) of $OLD: BLOCK. Static review, no build run. Push fixes; the conductor reviews the next head._"

# shellcheck source=bin/lib/fixround-preflight.sh
. "$LIB"

# ============================================================================
# T4 — check-runs 403: "unreadable", never "red"
# ============================================================================
reset_gh
RUNS "$NEW" success; touch "$T/gh/checks-403"
CI=$(frp_ci "$SLUG" "$NEW")
[ "$(jq -r .state <<<"$CI")" = green ] && ok || bad "T4a actions green + check-runs 403 must read green on the readable half (got $CI)"
[ "$(jq -r .checks <<<"$CI")" = unreadable ] && ok || bad "T4a the refused endpoint must be named unreadable (got $CI)"
TXT=$(frp_ci_text "$CI")
grep -q 'check-runs: UNREADABLE' <<<"$TXT" && ok || bad "T4a the text must say check-runs is UNREADABLE: $TXT"
grep -q ': GREEN' <<<"$TXT" && ok || bad "T4a the text must carry the green state: $TXT"
grep -q 'https://github.com/o/tproj/actions/runs/11' <<<"$TXT" && ok || bad "T4a the run URL must be in the text: $TXT"
touch "$T/gh/runs-403"
CI=$(frp_ci "$SLUG" "$NEW")
[ "$(jq -r .state <<<"$CI")" = unreadable ] && ok || bad "T4b both endpoints refused must be unreadable (got $CI)"
TXT=$(frp_ci_text "$CI")
grep -q ': UNREADABLE' <<<"$TXT" && ok || bad "T4b the state line must say UNREADABLE: $TXT"
grep -q ': RED' <<<"$TXT" && bad "T4b a refused read was reported RED: $TXT" || ok
grep -q 'not red' <<<"$TXT" && ok || bad "T4b the text must say out loud that unreadable is not red: $TXT"
# ...and the decision on an unreadable head is never a route that assumes red.
D=$(frp_decide red-ci-twice "$NEW" "" unreadable "")
[ "${D%%$'\t'*}" = fix ] && ok || bad "T4c unreadable CI on a red park must neither skip nor claim green (got $D)"
# A red check really is red; an empty head is none (not green).
rm -f "$T/gh/runs-403" "$T/gh/checks-403"; RUNS "$NEW" success; CHECKS "$NEW" failure
[ "$(jq -r .state <<<"$(frp_ci "$SLUG" "$NEW")")" = red ] && ok || bad "T4d a failed check-run must read red"
[ "$(jq -r .state <<<"$(frp_ci "$SLUG" "$PUSHED")")" = none ] && ok || bad "T4e a head with no runs must read none"

# ============================================================================
# The decision table (frp_decide), the ticket's rows one by one
# ============================================================================
[ "$(frp_findings_head "$OLD_FINDINGS")" = "$OLD" ] && ok || bad "D0 the head-bound footer's sha must be read as the findings head"
[ "$(frp_findings_head "$STALE_FINDINGS")" = "$NEW" ] && ok || bad "D0 the review-lane footer's sha must be read as the findings head"
D=$(frp_decide head-not-reapproved "$NEW" "$OLD" green "$OLD_FINDINGS")
[ "${D%%$'\t'*}" = rereview ] && ok || bad "T1 findings on an old sha with green CI at the moved head must route to re-review (got $D)"
D=$(frp_decide head-not-reapproved "$NEW" "$OLD" pending "$OLD_FINDINGS")
[ "${D%%$'\t'*}" = wait ] && ok || bad "T1b a moved head whose CI is pending must wait (got $D)"
D=$(frp_decide review-changes-requested "$NEW" "$NEW" green "$STALE_FINDINGS")
[ "${D%%$'\t'*}" = evidence ] && ok || bad "T2 a stale-Evidence-only blocker on a green head must take the evidence route (got $D)"
D=$(frp_decide review-changes-requested "$NEW" "$NEW" red "$STALE_FINDINGS")
[ "${D%%$'\t'*}" = fix ] && ok || bad "T2b the same findings on a RED head are not paperwork (got $D)"
D=$(frp_decide review-changes-requested "$NEW" "$NEW" green "$REAL_FINDINGS")
[ "${D%%$'\t'*}" = fix ] && ok || bad "T3 a real finding at head must run the round (got $D)"
D=$(frp_decide red-ci-twice "$NEW" "" green "")
[ "${D%%$'\t'*}" = skip ] && ok || bad "D1 a red-CI park green at head must be skipped (got $D)"
D=$(frp_decide queue-ejected-twice "$NEW" "" green "")
[ "${D%%$'\t'*}" = fix ] && ok || bad "D2 queue-ejected-twice is a rebase case — green does not skip it (got $D)"
frp_stale_evidence_only "no numbered findings here, only prose about the Evidence block" \
  && bad "D3 prose with no numbered findings must never read as stale-evidence-only" || ok
frp_stale_evidence_only "1. HIGH there is no evidence the retry path is tested; add a case." \
  && bad "D5 'no evidence X is tested' is a real finding, not PR-body paperwork" || ok
frp_stale_evidence_only "1. Nit: the Evidence table is ugly." \
  && bad "D4 a nit alone is not a blocker, so there is no stale-evidence blocker to route" || ok

# ============================================================================
# The PR body block: placed above ## Evidence, idempotent, replaced per head
# ============================================================================
reset_gh
RUNS "$NEW" success; CHECKS "$NEW" success; PRBODY "$NEW" "$STALE_BODY"
frp_body_refresh "$SLUG" 7 "$(frp_ci "$SLUG" "$NEW")" "$NEW"; RC=$?
[ "$RC" = 0 ] && ok || bad "B1 the first refresh must write (rc $RC)"
B=$(body)
grep -q 'harness:live-ci:begin' <<<"$B" && ok || bad "B1 the live-CI block is not in the body: $B"
[ "$(grep -n 'harness:live-ci:begin' <<<"$B" | cut -d: -f1)" -lt "$(grep -n '^## Evidence' <<<"$B" | cut -d: -f1)" ] \
  && ok || bad "B1 the block must sit above the build's ## Evidence block"
grep -q 'HARNESS_EXIT: 1' <<<"$B" && ok || bad "B1 the build's own Evidence rows are history and must be kept"
grep -q "CI on ${NEW:0:12}: GREEN" <<<"$B" && ok || bad "B1 the block must name the head and its green CI"
frp_rereview_requested "$B" "$NEW" && ok || bad "B1 the re-review request marker for this head is missing"
frp_rereview_requested "$B" "$OLD" && bad "B1 the marker must not answer for another head" || ok
frp_body_refresh "$SLUG" 7 "$(frp_ci "$SLUG" "$NEW")" "$NEW"; RC=$?
[ "$RC" = 3 ] && [ "$(patches)" = 1 ] && ok || bad "B2 a second refresh of the same head and state must send no PATCH (rc $RC, patches $(patches))"
[ "$(grep -c 'harness:live-ci:begin' <<<"$(body)")" = 1 ] && ok || bad "B2 exactly one block in the body"

# ============================================================================
# THE RESOLVER WIRING — br_preflight and br_fix_round, the real functions,
# extracted from bin/blocked-resolver.sh with the lane's own helpers stubbed.
# ============================================================================
BR="$DIR/bin/blocked-resolver.sh"
awk '/^# >>> br fixround preflight/{f=1} f{print} /^# <<< br fixround preflight/{f=0}' "$BR" > "$T/pre.sh"
awk '/^br_fix_round\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$BR" > "$T/fixround.sh"
[ -s "$T/pre.sh" ] && ok || bad "W0 the '# >>> br fixround preflight' block is missing from bin/blocked-resolver.sh"
[ -s "$T/fixround.sh" ] && ok || bad "W0 br_fix_round could not be extracted"
ST="$T/st"; mkdir -p "$ST"
cat > "$T/stubs.sh" <<EOF
say()  { printf '%s\n' "\$*" >> "$T/say.log"; }
STAMP() { printf '2026-09-24 00:00:00Z'; }
br_event() { printf '%s\n' "\$*" >> "$T/events.log"; }
br_rereview() { printf '%s\n' "\$*" >> "$T/rereview.log"; }
mc_num_of_url() { printf '%s' "\$1" | sed -nE 's#.*/pull/([0-9]+).*#\1#p'; }
br_file() { printf '%s' "$T/rec.json"; }
br_load() { cat "$T/rec.json" 2>/dev/null || echo '{}'; }
br_push_field() { local c; c=\$(br_load | jq -c --arg k "\$3" --arg v "\$4" '.[\$k] = (((.[\$k] // []) + [\$v]) | unique)') && printf '%s\n' "\$c" > "$T/rec.json"; }
br_has_field_value() { printf '%s' "\${1:-}" | jq -e --arg k "\$2" --arg v "\$3" '((.[\$k] // []) | index(\$v)) != null' >/dev/null 2>&1; }
br_num() { local v; v=\$(printf '%s' "\$1" | jq -r "(.\$2 // 0)" 2>/dev/null); case "\$v" in ''|*[!0-9]*) echo 0 ;; *) echo "\$v" ;; esac; }
br_set_field() { local c; c=\$(br_load | jq -c --arg k "\$3" --arg v "\${4:--}" '.[\$k] = \$v') && printf '%s\n' "\$c" > "$T/rec.json"; }
br_set_num() { local c; c=\$(br_load | jq -c --arg k "\$3" --argjson v "\${4:-0}" '.[\$k] = \$v') && printf '%s\n' "\$c" > "$T/rec.json"; }
# BH-1992: the review-lane route posts its re-review request as a PR comment.
br_pr_comment() { printf '%s\n' "\$2" >> "$T/comments.log"; }
EOF
reset_rec() { rm -f "$T/rec.json" "$T/say.log" "$T/events.log" "$T/rereview.log" "$T/comments.log"; }
PRE() { # PRE <reason> <findings> — runs br_preflight in a fresh shell; prints rc then the brief
  env BR_FIXROUND_PREFLIGHT="${BR_FIXROUND_PREFLIGHT:-1}" bash -c '. "$1"; . "$2"; . "$3"
    br_preflight tproj ck rk "$4" "$5" /rec TK-7 "$6" "$7" "$8"; rc=$?
    printf "%s\n" "$rc"; printf "%s" "$BR_PREFLIGHT_BRIEF"' _ \
    "$LIB" "$T/stubs.sh" "$T/pre.sh" "$1" "$URL" "$SLUG" "$NEW" "$2"
}

# T1 at the wiring: a conductor park whose findings are on the OLD head, head
# moved, CI green -> rc 1 (no round), br_rereview bought, one event row.
reset_gh; reset_rec
RUNS "$NEW" success; CHECKS "$NEW" success; PRBODY "$NEW" "$STALE_BODY"
OUT=$(PRE head-not-reapproved "$OLD_FINDINGS")
[ "$(head -1 <<<"$OUT")" = 1 ] && ok || bad "T1w the moved-head park must NOT run a fix round (rc $(head -1 <<<"$OUT"))"
[ -s "$T/rereview.log" ] && ok || bad "T1w the conductor park must buy the head-bound re-review"
grep -q "resolver_preflight tproj ck head-not-reapproved rereview on ${NEW:0:8}" "$T/events.log" 2>/dev/null \
  && ok || bad "T1w one resolver_preflight reason row must be written: $(cat "$T/events.log" 2>/dev/null)"
[ "$(jq -r '.preflight_heads[0] // ""' "$T/rec.json" 2>/dev/null)" = "$NEW" ] && ok || bad "T1w the route must be recorded once per head"
# ...and a second pass on the SAME head runs the round from the live state.
OUT=$(PRE head-not-reapproved "$OLD_FINDINGS")
[ "$(head -1 <<<"$OUT")" = 0 ] && ok || bad "T1w a re-review route already taken on this head must not repeat (rc $(head -1 <<<"$OUT"))"
[ "$(wc -l < "$T/rereview.log" | tr -d ' ')" = 1 ] && ok || bad "T1w the re-review must be bought once per head"

# T2 at the wiring: a review-lane verdict whose only blocker is stale Evidence.
reset_gh; reset_rec
RUNS "$NEW" success; touch "$T/gh/checks-403"; PRBODY "$NEW" "$STALE_BODY"
OUT=$(PRE review-changes-requested "$STALE_FINDINGS")
[ "$(head -1 <<<"$OUT")" = 1 ] && ok || bad "T2w a stale-Evidence-only verdict must NOT run a fix round (rc $(head -1 <<<"$OUT"))"
B=$(body)
grep -q "CI on ${NEW:0:12}: GREEN" <<<"$B" && ok || bad "T2w the Evidence block must be rewritten from live CI: $B"
frp_rereview_requested "$(cat "$T/comments.log" 2>/dev/null)" "$NEW" && ok || bad "T2w a PR comment must ask the review lane to re-review this head (BH-1992)"
[ -s "$T/rereview.log" ] && bad "T2w a review-lane park must not buy the conductor's re-review" || ok
grep -q "evidence on ${NEW:0:8}" "$T/events.log" 2>/dev/null && ok || bad "T2w one reason row for the evidence route: $(cat "$T/events.log" 2>/dev/null)"
# A body that refuses the write leaves nobody asked: the round runs instead.
reset_rec; PRBODY "$NEW" "$STALE_BODY"; touch "$T/gh/patch-fail"
OUT=$(PRE review-changes-requested "$STALE_FINDINGS")
[ "$(head -1 <<<"$OUT")" = 0 ] && ok || bad "T2w a refused body PATCH must fall back to the fix round (rc $(head -1 <<<"$OUT"))"
rm -f "$T/gh/patch-fail"

# T3 at the wiring: a real finding at head -> rc 0 and a live brief.
reset_gh; reset_rec
RUNS "$NEW" success; CHECKS "$NEW" failure; PRBODY "$NEW" "$STALE_BODY"
OUT=$(PRE review-changes-requested "$REAL_FINDINGS")
[ "$(head -1 <<<"$OUT")" = 0 ] && ok || bad "T3w a real finding must run the round (rc $(head -1 <<<"$OUT"))"
grep -q "current head: $NEW" <<<"$OUT" && ok || bad "T3w the brief must carry the live head sha: $OUT"
grep -q 'unit (4848) \[check\]: failure https://github.com/o/tproj/runs/21' <<<"$OUT" && ok \
  || bad "T3w the brief must carry each live check state with its run URL: $OUT"
grep -q 'CI \[workflow\]: success https://github.com/o/tproj/actions/runs/11' <<<"$OUT" && ok \
  || bad "T3w the brief must carry the workflow run too: $OUT"
# BH-8339: the body is written only after a push that landed (br_preflight_after_push, T5),
# so a round that then pushes nothing leaves it as it was. The brief above still carries the live state.
[ "$(body)" = "$STALE_BODY" ] && [ "$(patches)" = 0 ] && ok || bad "T3w the preflight must not rewrite the body before the round (patches $(patches))"

# T7 — the knob. 0 is today's behaviour: rc 0, no brief, not one GitHub read.
reset_gh; reset_rec; PRBODY "$NEW" "$STALE_BODY"
OUT=$(BR_FIXROUND_PREFLIGHT=0 PRE review-changes-requested "$STALE_FINDINGS")
[ "$OUT" = 0 ] && ok || bad "T7 BR_FIXROUND_PREFLIGHT=0 must proceed with no brief (got: $OUT)"
[ ! -s "$T/gh.log" ] && ok || bad "T7 BR_FIXROUND_PREFLIGHT=0 must make no GitHub read: $(cat "$T/gh.log")"

# ---------------------------------------------------------------------------
# br_fix_round itself, end to end up to the agent call (git, the agent and the
# lane's bookkeeping stubbed): the no-round routes spend nothing, and the round
# that runs puts the live brief into the prompt the agent receives.
# ---------------------------------------------------------------------------
REPOS="$T/repos"; mkdir -p "$REPOS/tproj/.git" "$H/bin"
printf '#!/bin/bash\n[ "$2" = repo ] && echo %s\nexit 0\n' "$SLUG" > "$H/bin/fleet-conf.sh"
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
printf 'agent %s\n' "\$1" >> "$T/agent.log"
exit 0
EOF
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/agent-call.sh"
cat > "$T/fr-stubs.sh" <<EOF
OBSERVE=0; H="$H"; ST="$ST"; LOG="$T/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
LEASE=$NEW
br_cap_key() { printf ck; }
br_num() { printf 0; }
br_cap_rows() { printf '%s' "\$4"; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal %s\n' "\$3" >> "$T/terminal.log"; }
br_slug_of_url() { printf '%s' "$SLUG"; }
br_pr_ref() { printf '%s ticket/TK-202 %s\n' "$SLUG" "$NEW"; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$T/terminal.log"; }
br_findings() { cat "$T/findings.txt"; }
br_ladder_class() { case "\$1" in head-not-reapproved) echo review-blocked ;; red-ci-twice|red-twice|queue-ejected-twice) echo ci-red ;; *) echo "" ;; esac; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$T/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  printf 'git %s\n' "\${a[*]}" >> "$T/git.log"
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/"*) echo "\$LEASE" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD") echo "\$LEASE" ;;
    *) return 0 ;;
  esac
}
EOF
FR() { # FR <reason> — runs the real br_fix_round in a fresh shell
  rm -f "$T/prompt.txt" "$T/agent.log" "$T/git.log" "$T/terminal.log" "$T/record.log"
  bash -c '. "$1"; . "$2"; . "$3"; . "$4"; . "$5"
    br_fix_round tproj rk "$6" "$7" /rec TK-7' _ \
    "$LIB" "$T/stubs.sh" "$T/pre.sh" "$T/fr-stubs.sh" "$T/fixround.sh" "$1" "$URL" >/dev/null 2>&1
}

# T1 end to end: findings on the old head, green CI at the new one — the round
# never reaches git or the agent.
reset_gh; reset_rec
RUNS "$NEW" success; CHECKS "$NEW" success; PRBODY "$NEW" "$STALE_BODY"
printf '%s\n' "$OLD_FINDINGS" > "$T/findings.txt"
FR head-not-reapproved
[ ! -s "$T/agent.log" ] && ok || bad "T1e br_fix_round bought an agent call on a moved, green head"
[ ! -s "$T/git.log" ] && ok || bad "T1e br_fix_round set up a worktree it did not need: $(head -3 "$T/git.log")"
[ -s "$T/rereview.log" ] && ok || bad "T1e br_fix_round must hand the park to the re-review"

# T2 end to end: stale Evidence only — no agent, no git, body rewritten.
reset_gh; reset_rec
RUNS "$NEW" success; touch "$T/gh/checks-403"; PRBODY "$NEW" "$STALE_BODY"
printf '%s\n' "$STALE_FINDINGS" > "$T/findings.txt"
FR review-changes-requested
[ ! -s "$T/agent.log" ] && ok || bad "T2e br_fix_round bought a fix round to refresh an Evidence block"
grep -q "CI on ${NEW:0:12}: GREEN" <<<"$(body)" && ok || bad "T2e the body was not refreshed"

# T3 end to end: a real finding — the agent runs and its prompt leads with the
# live head and check states, then the findings.
reset_gh; reset_rec
RUNS "$NEW" success; CHECKS "$NEW" failure; PRBODY "$NEW" "$STALE_BODY"
printf '%s\n' "$REAL_FINDINGS" > "$T/findings.txt"
FR review-changes-requested
[ -s "$T/agent.log" ] && ok || bad "T3e the fix round must run on a real finding (terminal: $(cat "$T/terminal.log" 2>/dev/null))"
P=$(cat "$T/prompt.txt" 2>/dev/null)
grep -q "current head: $NEW" <<<"$P" && ok || bad "T3e the agent's prompt must carry the live head sha"
grep -q 'unit (4848) \[check\]: failure https://github.com/o/tproj/runs/21' <<<"$P" && ok || bad "T3e the agent's prompt must carry the live check states with URLs"
grep -q 'REVIEW FINDINGS AS POSTED ON THE PR' <<<"$P" && ok || bad "T3e the findings must still be in the brief"
[ "$(grep -n 'current head:' <<<"$P" | head -1 | cut -d: -f1)" -lt "$(grep -n 'REVIEW FINDINGS AS POSTED' <<<"$P" | head -1 | cut -d: -f1)" ] \
  && ok || bad "T3e the live state must lead the brief"

# T5 — after a fix round pushes: the body names the NEW head's CI.
reset_gh; reset_rec
RUNS "$NEW" failure; PRBODY "$NEW" "$STALE_BODY"
frp_body_refresh "$SLUG" 7 "$(frp_ci "$SLUG" "$NEW")" "" >/dev/null
bash -c '. "$1"; . "$2"; . "$3"; br_preflight_after_push "$4" "$5" "$6"' _ \
  "$LIB" "$T/stubs.sh" "$T/pre.sh" "$SLUG" "$URL" "$PUSHED"
B=$(body)
grep -q "CI on ${PUSHED:0:12}: NONE" <<<"$B" && ok || bad "T5 the body must name the pushed head and its (not yet started) CI: $B"
grep -q "CI on ${NEW:0:12}" <<<"$B" && bad "T5 the old head's CI result must be gone from the live block" || ok
[ "$(grep -c 'harness:live-ci:begin' <<<"$B")" = 1 ] && ok || bad "T5 the block must be replaced, not stacked"
# ...and the push path in br_fix_round calls it with the pushed head.
grep -qF 'br_preflight_after_push "$slug" "$url" "$(git -C "$wt" rev-parse HEAD)"' "$T/fixround.sh" \
  && ok || bad "T5 br_fix_round's successful push must refresh the body for the pushed head"

# ============================================================================
# T6 — the review lanes see live CI, and the re-review request is honoured once
# ============================================================================
RP="$DIR/bin/review-prs.sh"
# (a) bin/review-prs.sh: the live-CI block, extracted and run as the lane runs it.
awk '/# >>> review-prs live ci/{f=1} f{print} /# <<< review-prs live ci/{f=0}' "$RP" > "$T/rp-live.sh"
[ -s "$T/rp-live.sh" ] && ok || bad "T6a the '# >>> review-prs live ci' block is missing"
reset_gh; RUNS "$NEW" success; touch "$T/gh/checks-403"
LIVE=$(bash -c '. "$1"; SLUG="$2"; SHA="$3"; . "$4"; printf "%s" "$RP_LIVE_CI"' _ "$LIB" "$SLUG" "$NEW" "$T/rp-live.sh")
grep -q "CI on ${NEW:0:12}: GREEN" <<<"$LIVE" && ok || bad "T6a the review lane must read the live CI of the head it reviews: $LIVE"
grep -q 'check-runs: UNREADABLE' <<<"$LIVE" && ok || bad "T6a a 403 on check-runs must be said as unreadable: $LIVE"
LIVE0=$(bash -c '. "$1"; SLUG="$2"; SHA="$3"; REVIEW_LIVE_CI=0; . "$4"; printf "%s" "$RP_LIVE_CI"' _ "$LIB" "$SLUG" "$NEW" "$T/rp-live.sh")
[ -z "$LIVE0" ] && ok || bad "T6a REVIEW_LIVE_CI=0 must leave the prompt as it was"
grep -q 'LIVE CI ON THIS HEAD' "$RP" && grep -q '\$RP_LIVE_CI' "$RP" && ok || bad "T6a the reviewer PROMPT must carry \$RP_LIVE_CI"

# (b) bin/review-prs.sh: the re-review request, extracted with the lane's own
# state writer. Once per head, only on a blocked head.
awk '/# >>> review-prs rereview request/{f=1} f{print} /# <<< review-prs rereview request/{f=0}' "$RP" > "$T/rp-rereq.sh"
awk '/# >>> review-prs rereview consume/{f=1} f{print} /# <<< review-prs rereview consume/{f=0}' "$RP" > "$T/rp-consume.sh"
awk '/^rp_state_write\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RP" > "$T/rp-write.sh"
[ -s "$T/rp-rereq.sh" ] && [ -s "$T/rp-consume.sh" ] && [ -s "$T/rp-write.sh" ] && ok || bad "T6b the rereview-request/consume blocks or rp_state_write are missing"
RPSTATE="$T/rp-state.json"
REREQ() { # REREQ [consume] -> prints RP_REREQ after one pass of the request block for PR 7
  # at $NEW; with `consume`, the tick also reaches the consume block (its CI was green).
  # Since BH-1992 the request is a verdict author's PR comment ($T/gh/comments-7.json),
  # read through the real trust set; the body marker alone triggers nothing
  # (tests/fixround-preflight-trust.bh-1992-test.sh pins the negatives).
  bash -c 'HARNESS="$7"; . "$1"; . "$2"; . "${11}"; STATE="$3"; LOG="$4"; PROJECT=tproj; SLUG="$5"; NUM=7; SHA="$6"; DONE="$6"
    STAMP() { printf x; }; RP_WRITE_ALERTED=0; CF="${12}"
    gh_rest_issue_comments() { cat "$CF" 2>/dev/null || echo "[]"; }
    . "$8"; [ "${10}" = consume ] && . "$9"; printf "%s" "$RP_REREQ"' _ \
    "$LIB" "$T/rp-write.sh" "$RPSTATE" "$T/rp.log" "$SLUG" "$NEW" "$H" "$T/rp-rereq.sh" "$T/rp-consume.sh" "${1:-}" \
    "$DIR/bin/lib/gh-pr-list.sh" "$T/gh/comments-7.json"
}
reset_gh
PRBODY "$NEW" "$STALE_BODY"
frp_body_refresh "$SLUG" 7 "$(frp_ci "$SLUG" "$NEW")" "$NEW" >/dev/null
jq -nc --arg b "$(printf 'one more review, please\n\n<!-- harness:rereview-requested %s -->' "$NEW")" \
  '[{user:{login:"cromford[bot]"}, body:$b}]' > "$T/gh/comments-7.json"
jq -n --arg s "$NEW" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$RPSTATE"
[ "$(REREQ)" = 1 ] && ok || bad "T6b a blocked head whose body asks for a re-review must be reviewed once more"
[ "$(jq -r '."7".rereq_sha // ""' "$RPSTATE")" = "" ] && ok || bad "T6b a tick that never reached the review (CI pending) must not spend the request"
[ "$(REREQ)" = 1 ] && ok || bad "T6b an unspent request must still stand on the next tick"
[ "$(REREQ consume)" = 1 ] && ok || bad "T6b the tick that reaches the review honours the request"
[ "$(jq -r '."7".rereq_sha' "$RPSTATE")" = "$NEW" ] && ok || bad "T6b the request must be recorded against this head once the review runs"
[ "$(REREQ)" = 0 ] && ok || bad "T6b the request must be honoured ONCE per head"
# The verdict write keeps rereq_sha, so a re-review that blocks again does not loop.
grep -qF 'ci_alerted_sha, rereq_sha}' "$RP" && ok || bad "T6b the verdict write must keep rereq_sha, or the request loops"
jq -n --arg s "$NEW" '{"7":{sha:$s, verdict:"APPROVE", tier:"1", served:"claude"}}' > "$RPSTATE"
[ "$(REREQ)" = 0 ] && ok || bad "T6b an approved head is never re-reviewed on request"
jq -n --arg s "$NEW" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$RPSTATE"
PRBODY "$NEW" "$STALE_BODY"; echo '[]' > "$T/gh/comments-7.json"
[ "$(REREQ)" = 0 ] && ok || bad "T6b no marker, no re-review"
# TEST-CHANGE (BH-2315): the call site became an if/case (rc 3 = held), same
# meaning: only a head WITHOUT a re-review request goes through rp_rehydrate.
grep -qF 'if [ "${RP_REREQ:-0}" != 1 ]; then' "$RP" && grep -qF 'rp_rehydrate "$NUM" "$SHA" || RP_RH=$?' "$RP" \
  && ok || bad "T6b a requested head must skip the GitHub rehydrate that would otherwise dedupe it"
# T6c (K3): a review call agent-call.sh REFUSES before billing (rc 74: the
# call-guard, the lane's own gate) bought no review, so the request the consume
# block spent is handed back — and the next tick honours it.
awk '/# >>> review-prs before-billing/{f=1} f{print} /# <<< review-prs before-billing/{f=0}' "$RP" > "$T/rp-bb.sh"
[ -s "$T/rp-bb.sh" ] && ok || bad "T6c the '# >>> review-prs before-billing' block is missing"
REREQ_REFUSED() { # one tick: request -> consume -> agent-call answers rc 74
  bash -c 'HARNESS="$7"; . "$1"; . "$2"; . "${11}"; STATE="$3"; LOG="$4"; PROJECT=tproj; SLUG="$5"; NUM=7; SHA="$6"; DONE="$6"
    STAMP() { printf x; }; RP_WRITE_ALERTED=0; CF="${12}"
    gh_rest_issue_comments() { cat "$CF" 2>/dev/null || echo "[]"; }
    . "$8"; . "$9"; IF_N=1; RP_AC_RC=74; OUT_FILE=$(mktemp); PROMPT_FILE=$(mktemp)
    printf "AGENT_CALL_REFUSED call-guard repeat review paid=2/2 fp=x\n" > "$OUT_FILE"
    for _once in 1; do . "${13}"; done; printf "%s" "$RP_REREQ"' _ \
    "$LIB" "$T/rp-write.sh" "$RPSTATE" "$T/rp.log" "$SLUG" "$NEW" "$H" "$T/rp-rereq.sh" "$T/rp-consume.sh" "" \
    "$DIR/bin/lib/gh-pr-list.sh" "$T/gh/comments-7.json" "$T/rp-bb.sh"
}
jq -nc --arg b "$(printf 'one more review, please\n\n<!-- harness:rereview-requested %s -->' "$NEW")" \
  '[{user:{login:"cromford[bot]"}, body:$b}]' > "$T/gh/comments-7.json"
jq -n --arg s "$NEW" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude"}}' > "$RPSTATE"
[ "$(REREQ_REFUSED)" = 1 ] && ok || bad "T6c precondition: the request is honoured on the refused tick"
[ "$(jq -r '."7".rereq_sha // ""' "$RPSTATE")" = "" ] && ok \
  || bad "T6c a refused (unbilled) review spent the re-review request: rereq_sha=$(jq -r '."7".rereq_sha' "$RPSTATE")"
[ "$(REREQ)" = 1 ] && ok || bad "T6c the handed-back request must stand on the next tick"
jq -n --arg s "$NEW" '{"7":{sha:$s, verdict:"REQUEST_CHANGES", tier:"2", served:"claude", rereq_sha:"oldhead"}}' > "$RPSTATE"
REREQ_REFUSED >/dev/null
[ "$(jq -r '."7".rereq_sha // ""' "$RPSTATE")" = oldhead ] && ok || bad "T6c the rollback must restore the PRIOR rereq_sha, got $(jq -r '."7".rereq_sha' "$RPSTATE")"


# (c) the conductor's head-bound re-review (mc_rereview) — the REAL function,
# through the lib the conductor sources, with agent-call.sh recording the prompt.
mkdir -p "$H/bin/lib/mc"
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/review-provenance.sh" \
   "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-ci-read.sh" "$LIB" "$H/bin/lib/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
P="\$6"; [ "\${P#@}" != "\$P" ] && cat "\${P#@}" > "$T/mc-prompt.txt"
printf 'VERDICT: APPROVE\n' > "\$5"; printf 'claude\n' > "\$5.runner"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
# The conductor's REST reads arrive under -i; everything else falls to the fake above.
mv "$T/fakebin/gh" "$T/fakebin/gh-plain"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/$SLUG/pulls/7"*) restpr OPEN $NEW ticket/TK-202 main "" MERGEABLE CLEAN operator "" 'Evidence: HARNESS_EXIT: 1, head-red' ;;
  *) exec "$T/fakebin/gh-plain" "\$@" ;;
esac
EOF
chmod +x "$T/fakebin/gh"
reset_gh; RUNS "$NEW" success; touch "$T/gh/checks-403"
MCRR() { rm -f "$T/mc-prompt.txt"
  env MC_RR_LIVE_CI="${MC_RR_LIVE_CI:-1}" bash -c 'set -uo pipefail; . "$HARNESS/bin/lib/merge-conductor-lib.sh"
    mc_rereview "$1" 7 tproj "$2" "$3" "$4" "" "$5"' _ "$SLUG" "$URL" "$OLD" "$NEW" "$T/mcrr.out" >/dev/null 2>&1; }
MCRR
grep -q 'LIVE CI ON THIS HEAD' "$T/mc-prompt.txt" 2>/dev/null && ok || bad "T6c the head-bound re-review prompt must carry the live CI header"
grep -q "CI on ${NEW:0:12}: GREEN" "$T/mc-prompt.txt" 2>/dev/null && ok || bad "T6c the head-bound re-review prompt must say the head is green: $(head -c 600 "$T/mc-prompt.txt" 2>/dev/null)"
grep -q 'check-runs: UNREADABLE' "$T/mc-prompt.txt" 2>/dev/null && ok || bad "T6c the refused check-runs read must be named unreadable in the prompt"
MC_RR_LIVE_CI=0 MCRR
[ -s "$T/mc-prompt.txt" ] && ! grep -q 'LIVE CI ON THIS HEAD' "$T/mc-prompt.txt" && ok || bad "T6c MC_RR_LIVE_CI=0 must leave the prompt as it was"

echo "fixround-preflight.bh-1794: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
