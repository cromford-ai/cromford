#!/bin/bash
# tests/epic-blocked-by.bh-9289-test.sh — BH-9289: a Blocked-by on a
# hand-written epic resolves with a question and a default.
#
# WHAT IS UNDER TEST. The REAL bin/decompose-parent-close.sh and the REAL
# bin/unblocked-children.sh, run as their callers run them, with the REAL
# bin/lib/epic-blocker.sh, against a file-backed `gh` that logs every call.
# Each case is its own harness tree ($CASE, bin/ linked to one installed
# closure) with its own fixtures, so cases share no data and run in any order.
# The clock is pinned through EPIC_BLOCKER_NOW (honoured only under
# HARNESS_TEST_SANDBOX=1). The suite passes that flag itself, to the scripts
# under test alone (the tests/wake-backstop.bh-6976-test.sh way): the traced CI
# shards do not set it, and without it the lib reads the real clock, so every
# fixture time is days in the past and each wait reads as MET. It is never
# exported, so tests/lib/scratch.sh's root guard above still sees the caller's
# value.
#
# The project-6 shape (ticket body): epic #1008 has no labels; its children are
# #1009 (`Part of #1008`), #1081 (`epic #1008`) and #1029 (a sub-issue only);
# #1055 and #1057 carry ai-build and `Blocked-by: #1008`.
#
# Run from anywhere: tests/epic-blocked-by.bh-9289-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }

REPO="example-org/project-6-fixture"
PRJ=mk
NOW=1793000000
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

mkdir -p "$T/inst" "$T/stub"
for s in bin/decompose-parent-close.sh bin/unblocked-children.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$T/inst" ) >/dev/null \
    || { echo "setup: could not install $s"; exit 1; }
done
chmod +x "$T/inst/bin/"*.sh
# The lib must reach the tree through the closure of the script that sources it.
LIB="$DIR/bin/lib/epic-blocker.sh"
[ -r "$LIB" ] && cmp -s "$LIB" "$T/inst/bin/lib/epic-blocker.sh" && ok \
  || bad "setup: bin/lib/epic-blocker.sh is not in the closure of bin/decompose-parent-close.sh"

# gh: every shape the two scripts ask for, answered from $CASE/gh. A POST of a
# comment WRITES it to the thread (created_at = the pinned now), so a second
# pass reads its own question.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/calls"
G="$CASE/gh"
M=GET; P=""; Q=""; prev=""; page=1; inc=0
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  [ "$a" = -i ] && inc=1
  case "$a" in repos/*|search/*) [ -z "$P" ] && P="${a%%\?*}" ;; page=*) page="${a#page=}" ;; q=*) Q="${a#q=}" ;; esac
  prev="$a"
done
say() { # say <status line> <body>
  if [ "$inc" = 1 ]; then printf 'HTTP/2.0 %s\nx-stub: 1\n\n%s\n' "$1" "$2"; else printf '%s\n' "$2"; fi
  case "$1" in 2*) exit 0 ;; *) exit 1 ;; esac
}
if [ "$1" = pr ]; then echo '[]'; exit 0; fi
if [ "$1" = auth ] && [ "$2" = token ]; then echo tok-fixture-1; exit 0; fi
if [ "$1" = api ] && [ "$2" = "repos/$GH_ISSUES_REPO" ]; then echo 1; exit 0; fi
if [ "$1" = issue ] && [ "$2" = view ]; then
  f="$G/issue-$3.json"; [ -f "$f" ] || exit 1
  jq -c '{number, title, state:(.state|ascii_upcase)}' "$f"; exit 0
fi
R="repos/$GH_ISSUES_REPO"
case "$M $P" in
  "GET $R/issues")
    say "200 OK" "$(jq -c --argjson p "$page" '.[($p-1)*100:$p*100]' "$G/issues.json")" ;;
  "GET $R/pulls")
    say "200 OK" "$(jq -c --argjson p "$page" '.[($p-1)*100:$p*100]' "$G/prs.json" 2>/dev/null || echo '[]')" ;;
  "GET search/issues")
    case "$Q" in *'"Part of #'*) k=part ;; *) k=epic ;; esac
    n=$(printf '%s' "$Q" | sed -nE 's/.*#([0-9]+)".*/\1/p')
    f="$G/search-$k-$n.json"
    [ -f "$f" ] || { say "200 OK" '{"total_count":0,"incomplete_results":false,"items":[]}'; }
    say "200 OK" "$(cat "$f")" ;;
  "GET $R/issues/"*/sub_issues)
    n="${P#"$R"/issues/}"; n="${n%/sub_issues}"
    [ -f "$G/sub-$n.fail" ] && say "502 Bad Gateway" '{"message":"stub"}'
    [ -f "$G/sub-$n.json" ] || say "404 Not Found" '{"message":"Not Found"}'
    say "200 OK" "$(cat "$G/sub-$n.json")" ;;
  "GET $R/issues/"*/comments)
    n="${P#"$R"/issues/}"; n="${n%/comments}"
    say "200 OK" "$(cat "$G/comments-$n.json" 2>/dev/null || echo '[]')" ;;
  "POST $R/issues/"*/comments)
    n="${P#"$R"/issues/}"; n="${n%/comments}"
    if [ -f "$G/post-fail" ]; then rm -f "$G/post-fail"; say "500 Internal Server Error" '{"message":"stub"}'; fi
    bf=""; for a in "$@"; do case "$a" in body=@*) bf="${a#body=@}" ;; esac; done
    [ -f "$G/comments-$n.json" ] || echo '[]' > "$G/comments-$n.json"
    jq -c --rawfile b "$bf" --arg t "$STUB_NOW_ISO" '. + [{id: (length + 1), body: $b, created_at: $t, user: {login: "operator", type: "User"}}]' \
      "$G/comments-$n.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/comments-$n.json"
    say "201 Created" '{"id":1}' ;;
  "PATCH $R/issues/"*)
    n="${P#"$R"/issues/}"
    jq -c '.state="closed"' "$G/issue-$n.json" > "$G/i.tmp" && mv "$G/i.tmp" "$G/issue-$n.json"
    say "200 OK" '{"state":"closed"}' ;;
  "GET $R/issues/"*)
    n="${P#"$R"/issues/}"
    [ -f "$G/issue-$n.json" ] || say "404 Not Found" '{"message":"Not Found"}'
    say "200 OK" "$(cat "$G/issue-$n.json")" ;;
esac
say "404 Not Found" '{"message":"stub: no route"}'
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH" PARENT_CLOSE_COOLDOWN_S=0 GH_ISSUES_REPO="$REPO" REVDEP_WAKE=1 \
  GH_ETAG=0 EPIC_BLOCKER_NOW="$NOW" STUB_NOW_ISO="$(iso "$NOW")" STACKED_BUILDS=0 DEP_VERIFY=0
unset EPIC_BLOCKER EPIC_BLOCKER_DEFAULT_H EPIC_BLOCKER_MAX EPIC_BLOCKER_COMMENTS_MAX

# iss <n> <open|closed> <labels-json> <body> -> one REST issue object
iss() { jq -nc --argjson n "$1" --arg s "$2" --argjson l "$3" --arg b "$4" \
          '{number:$n, title:("issue " + ($n|tostring)), state:$s, state_reason:(if $s == "closed" then "completed" else null end), labels:$l, body:$b}'; }
AI='[{"name":"ai-build"}]'
# search <file> <issue-json>... -> a one-page search answer
search() { local f="$1"; shift; printf '%s\n' "$@" | jq -sc '{total_count: length, incomplete_results: false, items: .}' > "$f"; }
# qcomment <created-epoch> -> the question comment as the pass posts it
qcomment() { jq -nc --arg t "$(iso "$1")" '{id: 1, body: "<!-- harness: epic-close-question -->\nEvery child of this epic is closed.", created_at: $t, user: {login: "operator", type: "User"}}'; }
# comment <created-epoch> <login> <type> <body>
comment() { jq -nc --arg t "$(iso "$1")" --arg l "$2" --arg y "$3" --arg b "$4" '{id: 9, body: $b, created_at: $t, user: {login: $l, type: $y}}'; }
thread() { local n="$1"; shift; printf '%s\n' "$@" | jq -sc '.' > "$CASE/gh/comments-$n.json"; }

newcase() { # newcase <name> -> a fresh harness tree with the project-6 shape
  CASE="$T/cases/$1"; mkdir -p "$CASE/logs" "$CASE/state" "$CASE/gh"
  ln -s "$T/inst/bin" "$CASE/bin"
  export CASE
  G="$CASE/gh"
  printf '%s\n' "$(iss 1055 open "$AI" 'Blocked-by: #1008')" "$(iss 1057 open "$AI" $'Some work.\n\nBlocked-by: #1008')" \
    "$(iss 1060 open "$AI" 'No blockers here.')" | jq -sc '.' > "$G/issues.json"
  echo '[]' > "$G/prs.json"
  iss 1008 open '[]' 'The project-6 epic.' > "$G/issue-1008.json"
  search "$G/search-part-1008.json" "$(iss 1009 closed '[]' 'Part of #1008')"
  search "$G/search-epic-1008.json" "$(iss 1081 closed '[]' 'Parent: epic #1008')"
  printf '%s\n' "$(iss 1029 closed '[]' 'A slice with no text link.')" | jq -sc '.' > "$G/sub-1008.json"
  echo '[]' > "$G/comments-1008.json"
  MET="$CASE/state/epic-blocker/$PRJ/1008.met"
  KEYS="$CASE/state/parent-close-$PRJ.keys"
}
dp() { OUT=$(HARNESS_TEST_SANDBOX=1 HARNESS="$CASE" "$CASE/bin/decompose-parent-close.sh" "$PRJ" "$@" 2>/dev/null); }
uc() { UOUT=$(printf '' | HARNESS_TEST_SANDBOX=1 HARNESS="$CASE" "$CASE/bin/unblocked-children.sh" "$PRJ" 2>/dev/null); }
cnt()     { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
posts()   { cnt "-X POST repos/$REPO/issues/${1:-1008}/comments" "$CASE/calls"; }
alerts()  { cnt 'epic-blocker:' "$CASE/logs/ALERTS.log"; }
plog()    { cat "$CASE/logs/$PRJ.log" 2>/dev/null; }
nlog()    { cnt "$1" "$CASE/logs/$PRJ.log"; }
qbody()   { jq -r '[.[] | select(.body | startswith("<!-- harness: epic-close-question -->"))][0].body // ""' "$CASE/gh/comments-${1:-1008}.json"; }

# ── E1: one question, one alert, no close, no release yet ───────────────────
newcase e1
dp
[ "$(posts)" = 1 ] && ok || bad "E1: exactly one POST to #1008 wanted, got $(posts): $(cat "$CASE/calls")"
B=$(qbody)
case "$B" in "<!-- harness: epic-close-question -->"*) ok ;; *) bad "E1: the question must start with the marker: '$B'" ;; esac
for w in '#1009' '#1029' '#1081' '#1055' '#1057' '24 h' 'Blocked-by #1008 as met' 'I recommend that we close it'; do
  grep -qF -- "$w" <<<"$B" && ok || bad "E1: the question must name '$w': $B"
done
[ "$(alerts)" = 1 ] && ok || bad "E1: exactly one epic-blocker alert wanted: $(cat "$CASE/logs/ALERTS.log" 2>/dev/null)"
AL=$(grep 'epic-blocker:' "$CASE/logs/ALERTS.log" 2>/dev/null)
for w in '#1008' '#1055' '#1057'; do grep -qF -- "$w" <<<"$AL" && ok || bad "E1: the alert must name $w: $AL"; done
grep -q -- "-X PATCH repos/$REPO/issues/1008" "$CASE/calls" && bad "E1: the epic must never be closed" || ok
[ "$(nlog 'EPIC_QUESTION_POSTED #1008')" = 1 ] && ok || bad "E1: EPIC_QUESTION_POSTED #1008 wanted once: $(plog)"
[ -e "$MET" ] && bad "E1: no .met before the window" || ok
[ -z "$OUT" ] && ok || bad "E1: the stdout contract (closed parents) must stay empty, got '$OUT'"
grep -qx 1008 "$KEYS" 2>/dev/null && ok || bad "E1: #1008 must be a wake key: $(cat "$KEYS" 2>/dev/null)"
uc
grep -q 'UNBLOCKED 1055' <<<"$UOUT" && bad "E1: #1055 must not be released before the window: $UOUT" || ok

# ── E2: a second pass posts nothing and alerts nothing ──────────────────────
dp
[ "$(posts)" = 1 ] && ok || bad "E2: a second pass must post no second question ($(posts) posts)"
[ "$(alerts)" = 1 ] && ok || bad "E2: a second pass must write no second alert ($(alerts))"

# ── E3: a decompose parent closes at once and gets no question ──────────────
newcase e3
kid() { iss "$1" closed "$AI" "$(printf 'Part of #900\nOrder: %s of 2' "$2")"; }
mpr() { jq -nc --argjson n "$2" --arg r "$REPO" --argjson k "$1" '{number:$n, html_url:("https://github.com/" + $r + "/pull/" + ($n|tostring)), title:("TK-" + ($k|tostring) + ": part"), head:{ref:("ticket/mk-" + ($k|tostring))}, state:"closed", merged_at:"2026-10-17T10:00:00Z"}'; }
printf '%s\n' "$(kid 901 1)" "$(kid 902 2)" "$(iss 950 open "$AI" 'Blocked-by: #900')" | jq -sc '.' > "$G/issues.json"
printf '%s\n' "$(mpr 901 1901)" "$(mpr 902 1902)" | jq -sc '.' > "$G/prs.json"
iss 900 open '[]' 'The master.' > "$G/issue-900.json"
thread 900 "$(comment $((NOW - 90000)) operator User 'Split into 2 parts. This issue stays open as the master.')"
search "$G/search-part-900.json" "$(kid 901 1)" "$(kid 902 2)"
dp
grep -qx 900 <<<"$OUT" && ok || bad "E3: the parent must close at once (stdout '$OUT')"
grep -q -- "-X PATCH repos/$REPO/issues/900" "$CASE/calls" && ok || bad "E3: the parent close was not made: $(cat "$CASE/calls")"
grep -q 'epic-close-question' "$G/comments-900.json" && bad "E3: a decompose parent must get no question" || ok
[ "$(alerts)" = 0 ] && ok || bad "E3: the epic pass must write no alert for a decompose parent"
grep -q 'search/issues' "$CASE/calls" && bad "E3: a decompose parent is not an epic candidate: $(grep search "$CASE/calls")" || ok
# A parent whose children lost ai-build still carries the filer sentence.
newcase e3b
iss 1008 open '[]' 'A parked master.' > "$G/issue-1008.json"
thread 1008 "$(comment $((NOW - 90000)) operator User 'This issue stays open until they ship. We took the `ai-build` label off it so no builder picks the whole thing up again.')"
dp
[ "$(posts)" = 0 ] && ok || bad "E3b: a filer sentence on the thread must stop the question"
[ "$(alerts)" = 0 ] && ok || bad "E3b: no alert for a decompose parent"

# ── E4: the child match ─────────────────────────────────────────────────────
newcase e4
search "$G/search-part-1008.json" "$(iss 2001 closed '[]' 'Part of #100')" "$(iss 2002 closed '[]' 'Part of #10080')" \
  "$(jq -c '. + {pull_request: {url: "x"}}' <<<"$(iss 2005 closed '[]' 'Part of #1008')")"
search "$G/search-epic-1008.json" "$(iss 2003 closed '[]' 'epic #10080')" \
  "$(iss 2004 closed '[]' $'Blocked-by: #1008\nSee epic #1008.')" "$(iss 2006 closed '[]' 'about #1008, an epic')" \
  "$(iss 1008 open '[]' 'epic #1008 itself')"
echo '[]' > "$G/sub-1008.json"
dp
[ "$(posts)" = 0 ] && ok || bad "E4: near-miss hits are not children (NO_CHILDREN), got a post: $(qbody)"
[ "$(alerts)" = 0 ] && ok || bad "E4: no alert"
newcase e4p
search "$G/search-part-1008.json" "$(iss 2011 closed '[]' '> **Part of #1008**')"
search "$G/search-epic-1008.json" "$(iss 2012 closed '[]' 'Epic #1008 slice 2')"
echo '[]' > "$G/sub-1008.json"
dp
B=$(qbody)
grep -qF '#2011, #2012' <<<"$B" && ok || bad "E4p: the markdown and capitalised shapes are children: '$B'"
# A child found only through the sub-issues API counts on its own.
newcase e4s
search "$G/search-part-1008.json"
search "$G/search-epic-1008.json"
dp
B=$(qbody)
grep -qF 'is closed: #1029.' <<<"$B" && ok || bad "E4s: a sub-issue alone is a child: '$B'"

# ── E5: no answer in the window: the dependents are UNBLOCKED ───────────────
newcase e5
thread 1008 "$(qcomment $((NOW - 25 * 3600)))"
dp
[ -e "$MET" ] && ok || bad "E5: the window is over: $MET wanted. $(plog)"
uc
for d in 1055 1057; do
  L=$(grep "board issues: UNBLOCKED $d " <<<"$UOUT")
  grep -q 'met by default' <<<"$L" && grep -qF '#1008 is a hand-written epic' <<<"$L" && ok \
    || bad "E5: UNBLOCKED $d with the met-by-default reason wanted: $UOUT"
done
grep -q 'UNBLOCKED 1060' <<<"$UOUT" && bad "E5: an unblocked-by-nothing ticket is not released" || ok
dp
[ "$(nlog 'EPIC_DEFAULT_MET #1008')" = 1 ] && ok || bad "E5: EPIC_DEFAULT_MET #1008 wanted once: $(plog)"
[ "$(posts)" = 0 ] && ok || bad "E5: an asked epic gets no second question"
# The marker goes when no open ticket waits on the epic any more (retention).
jq -c 'map(if .number == 1055 or .number == 1057 then .body = "done" else . end)' "$G/issues.json" > "$G/x" && mv "$G/x" "$G/issues.json"
dp
[ -e "$MET" ] && bad "E5: a .met with no dependent left must be deleted" || ok

# ── E6: a human reply stops the default ─────────────────────────────────────
newcase e6
mkdir -p "$(dirname "$MET")"; : > "$MET"
thread 1008 "$(qcomment $((NOW - 25 * 3600)))" \
  "$(comment $((NOW - 20 * 3600)) operator User 'keep this open, one more slice is coming')"
uc
[ -e "$MET" ] && bad "E6: a reply must remove the .met" || ok
grep -qE 'UNBLOCKED (1055|1057)' <<<"$UOUT" && bad "E6: a reply must hold the dependents: $UOUT" || ok
dp
[ "$(nlog 'EPIC_DEFAULT_STOPPED #1008')" = 1 ] && ok || bad "E6: EPIC_DEFAULT_STOPPED #1008 wanted once over two passes: $(plog)"
# What is not an answer: a harness comment, a bot, a comment older than the question.
newcase e6n
thread 1008 "$(comment $((NOW - 30 * 3600)) operator User 'an older human note')" "$(qcomment $((NOW - 25 * 3600)))" \
  "$(comment $((NOW - 20 * 3600)) operator User '<!-- harness-status: results-sweep --> sweep')" \
  "$(comment $((NOW - 19 * 3600)) 'mergify[bot]' Bot 'queued')"
dp
[ -e "$MET" ] && ok || bad "E6n: no human reply after the question: .met wanted. $(plog)"

# ── E7: one open child: nothing at all ──────────────────────────────────────
newcase e7
search "$G/search-epic-1008.json" "$(iss 1081 open '[]' 'Parent: epic #1008')"
dp
[ "$(posts)" = 0 ] && ok || bad "E7: an open child must stop the question"
[ "$(alerts)" = 0 ] && ok || bad "E7: an open child must stop the alert"
[ -e "$MET" ] && bad "E7: no .met with an open child" || ok

# ── E8: inside the window: no release ───────────────────────────────────────
newcase e8
thread 1008 "$(qcomment $((NOW - 23 * 3600)))"
uc
[ -e "$MET" ] && bad "E8: 23 h is inside the 24 h window" || ok
grep -q 'UNBLOCKED 1055' <<<"$UOUT" && bad "E8: no release inside the window: $UOUT" || ok

# ── E9: no verdict from what cannot be judged ───────────────────────────────
newcase e9a   # carries ai-build on its own record
iss 1008 open "$AI" 'labelled' > "$G/issue-1008.json"
mkdir -p "$(dirname "$MET")"; : > "$MET"
dp
[ "$(posts)" = 0 ] && ok || bad "E9a: a labelled epic gets no question"
[ -e "$MET" ] && bad "E9a: a labelled epic loses its .met" || ok
newcase e9b   # closed
iss 1008 closed '[]' 'done' > "$G/issue-1008.json"
dp
[ "$(posts)" = 0 ] && ok || bad "E9b: a closed epic gets no question"
newcase e9c   # search past one page
jq -c '.total_count = 101' "$G/search-part-1008.json" > "$G/x" && mv "$G/x" "$G/search-part-1008.json"
mkdir -p "$(dirname "$MET")"; : > "$MET"
dp
[ "$(posts)" = 0 ] && ok || bad "E9c: an incomplete search gets no question"
[ -e "$MET" ] && ok || bad "E9c: an unjudged epic keeps its .met"
newcase e9d   # sub-issues read fails
: > "$G/sub-1008.fail"
mkdir -p "$(dirname "$MET")"; : > "$MET"
dp
[ "$(posts)" = 0 ] && ok || bad "E9d: a failed sub-issues read gets no question"
[ -e "$MET" ] && ok || bad "E9d: an unjudged epic keeps its .met"

# ── E10: a failed POST: no alert, no event, a retry; then once ──────────────
newcase e10
: > "$G/post-fail"
dp
[ "$(alerts)" = 0 ] && ok || bad "E10: a failed POST must write no alert"
[ "$(nlog EPIC_QUESTION_POSTED)" = 0 ] && ok || bad "E10: a failed POST must log no EPIC_QUESTION_POSTED"
grep -qx retry "$KEYS" 2>/dev/null && ok || bad "E10: a failed POST must add retry to the keys: $(cat "$KEYS" 2>/dev/null)"
dp
[ "$(alerts)" = 1 ] && ok || bad "E10: the retry must alert once ($(alerts))"
[ "$(jq '[.[] | select(.body | startswith("<!-- harness: epic-close-question"))] | length' "$G/comments-1008.json")" = 1 ] && ok \
  || bad "E10: exactly one question on the thread after the retry"

# ── E11: a dry run writes nothing ───────────────────────────────────────────
newcase e11
dp --dry-run
[ "$(posts)" = 0 ] && ok || bad "E11: a dry run posts nothing"
[ "$(alerts)" = 0 ] && ok || bad "E11: a dry run alerts nothing"
[ -e "$CASE/state/epic-blocker/$PRJ/cursor" ] && bad "E11: a dry run moves no cursor" || ok
[ "$(nlog 'EPIC_DRY #1008 ASK')" = 1 ] && ok || bad "E11: EPIC_DRY #1008 ASK wanted: $(plog)"

# ── E12: the kill switch ────────────────────────────────────────────────────
newcase e12
thread 1008 "$(qcomment $((NOW - 25 * 3600)))"
mkdir -p "$(dirname "$MET")"; : > "$MET"
EPIC_BLOCKER=0 dp
grep -qE 'search/issues|sub_issues' "$CASE/calls" && bad "E12: EPIC_BLOCKER=0 must make no epic read" || ok
UOUT=$(printf '' | EPIC_BLOCKER=0 HARNESS_TEST_SANDBOX=1 HARNESS="$CASE" "$CASE/bin/unblocked-children.sh" "$PRJ" 2>/dev/null)
grep -q 'UNBLOCKED 1055' <<<"$UOUT" && bad "E12: EPIC_BLOCKER=0 must release nothing by default: $UOUT" || ok

# ── E13: the knobs and their fallbacks ──────────────────────────────────────
newcase e13a
thread 1008 "$(qcomment $((NOW - 25 * 3600)))"
EPIC_BLOCKER_DEFAULT_H=abc dp
[ -e "$MET" ] && ok || bad "E13a: an invalid window reads as 24 h (25 h old: met)"
newcase e13b
thread 1008 "$(qcomment $((NOW - 23 * 3600)))"
EPIC_BLOCKER_DEFAULT_H=0 dp
[ -e "$MET" ] && bad "E13b: a 0 window reads as 24 h (23 h old: not met)" || ok
newcase e13c
thread 1008 "$(qcomment $((NOW - 3 * 3600)))"
EPIC_BLOCKER_DEFAULT_H=2 dp
[ -e "$MET" ] && ok || bad "E13c: EPIC_BLOCKER_DEFAULT_H=2 is read (3 h old: met)"
grep -q 'in 2 h' <<<"$(plog)" && ok || bad "E13c: the met line names the window: $(plog)"
newcase e13d   # six candidates
L='[]'
for e in 3001 3002 3003 3004 3005 3006; do
  iss "$e" open '[]' 'another epic' > "$G/issue-$e.json"
  L=$(jq -c --argjson x "$(iss $((e + 100)) open "$AI" "Blocked-by: #$e")" '. + [$x]' <<<"$L")
done
jq -c --argjson x "$L" '. + $x' "$G/issues.json" > "$G/x" && mv "$G/x" "$G/issues.json"
looked() { grep -cE -- "-X GET repos/$REPO/issues/[0-9]+\$" "$CASE/calls"; }
EPIC_BLOCKER_MAX=0 dp
[ "$(looked)" = 5 ] && ok || bad "E13d: EPIC_BLOCKER_MAX=0 reads as 5 lookups, got $(looked)"
rm -f "$CASE/calls"
EPIC_BLOCKER_MAX=2 dp
[ "$(looked)" = 2 ] && ok || bad "E13d: EPIC_BLOCKER_MAX=2 is read, got $(looked)"
[ "$(grep -oE -- "-X GET repos/$REPO/issues/[0-9]+\$" "$CASE/calls" | grep -oE '[0-9]+$' | tr '\n' ' ')" = "3005 3006 " ] && ok \
  || bad "E13d: the cursor rotates past the last lookup (3004): $(grep -E 'issues/[0-9]+$' "$CASE/calls")"

# ── E14: a thread longer than EPIC_BLOCKER_COMMENTS_MAX is a short read ─────
# (lead review lr-9302). The question sits past the cap, so a read of the cap
# alone never sees it: the pass must give no verdict, never ask again, never
# write .met. With the cap raised, the same thread reads in full and waits.
newcase e14
thread 1008 "$(comment $((NOW - 7200)) dev-a User 'note one')" "$(comment $((NOW - 7100)) dev-b User 'note two')" "$(qcomment $((NOW - 3600)))"
jq -c '.comments = 3' "$G/issue-1008.json" > "$G/x" && mv "$G/x" "$G/issue-1008.json"
EPIC_BLOCKER_COMMENTS_MAX=2 dp
[ "$(posts)" = 0 ] && ok || bad "E14: a short read must post no question, got $(posts): $(cat "$CASE/calls")"
[ "$(alerts)" = 0 ] && ok || bad "E14: a short read must write no alert"
[ -e "$MET" ] && bad "E14: a short read must write no .met" || ok
# The knob reaches the read: a dry pass at cap 2 gives no verdict, at cap 3 it waits.
EPIC_BLOCKER_COMMENTS_MAX=2 dp --dry-run
[ "$(nlog 'EPIC_DRY #1008')" = 0 ] && ok || bad "E14: cap 2 must give no verdict: $(plog)"
EPIC_BLOCKER_COMMENTS_MAX=3 dp --dry-run
[ "$(nlog 'EPIC_DRY #1008 WAIT')" = 1 ] && ok || bad "E14: cap 3 reads the whole thread and waits: $(plog)"
EPIC_BLOCKER_COMMENTS_MAX=3 dp
[ "$(posts)" = 0 ] && ok || bad "E14: a full read sees the old question and posts none, got $(posts)"
[ -e "$MET" ] && bad "E14: inside the window, no .met" || ok
# A thread that answers fewer comments than the issue counts is short too.
newcase e14b
jq -c '.comments = 5' "$G/issue-1008.json" > "$G/x" && mv "$G/x" "$G/issue-1008.json"
dp
[ "$(posts)" = 0 ] && ok || bad "E14b: 0 of 5 comments read must post no question, got $(posts)"

echo "epic-blocked-by.bh-9289: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
