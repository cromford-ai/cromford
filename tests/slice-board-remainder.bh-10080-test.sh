#!/bin/bash
# tests/slice-board-remainder.bh-10080-test.sh — the rest of a sliced in-app
# board ticket is never lost, and a comment never claims a filing that did not
# happen (BH-10080).
#
# Three project-2 remainders were lost on 2026-11-24/25: TK-618 (the plan had
# no SLICE list, so nothing knew a rest existed), TK-604 (a hand-opened slice PR
# with no build record, so the settle never ran), and TK-594 / TK-638 (a SLICE
# line with a prose rest: `unknown:none`, and the last word on the thread was
# "When it merges, we file the remaining slices"). This suite drives the fix
# against a curl stub that plays the board, a gh stub that plays GitHub, and a
# lane-alert stub that counts pages. 0 network; each case has its own case dir,
# ids and ledger.
#
#   K0-K16  slice_board_marker: the weak slice marker decision table
#   A1      the TK-618 shape: no SLICE line, a coverage row -> a Rest child
#   C3a-C3c a SLICE line with no C<j> list (TK-638): matrix, description, covered
#   A4      nothing readable: unknown:none, one page, one note, twice
#   H1-H4   hand-opened slice PRs: PR body as the plan, the conductor KEY from
#           the PR title, the merged-advance spawn
#   N1-N5   the note on the conductor path, the owner knob, never "We filed"
#           without a recorded child
#   D1-D2   dedupe on the parent's own children
#   B1-B5   bin/board-closeout.sh words
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-board-remainder.bh-10080-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/slice-board.sh" ] || { echo "FAIL: bin/lib/slice-board.sh does not exist"; exit 1; }

CUID=cmvmtfpj2000k07kzd588kq7r
TOKEN=tok-FIXTURE-10080
PRURL=https://github.com/example-org/ledger-os/pull/752

# ---- the scratch harness: one in-app board project -------------------------
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/h/logs" "$T/h/state" "$T/h/builds" "$T/stub"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ledger-os  example-org/ledger-os  https://ledger.example  /api/board  3
CONF
cat > "$T/h/env/ledger-os.env" <<CONF
LEDGER_API_BASE=https://ledger.example
LEDGER_INTERNAL_API_TOKEN=$TOKEN
CONF
printf '#!/bin/bash\necho %s\n' "$TOKEN" > "$T/h/bin/internal-token-for.sh"
printf '#!/bin/bash\necho OK\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERT_LOG"\nexit 0\n' > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/"*.sh
for s in bin/board-closeout.sh bin/slice-board-settle.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || exit 1
done
LIB="$T/h/bin/lib"

# The board. One line per request in $CURL_LOG: METHOD URL KEY; each body in
# $CURL_BODIES/<seq>.json. The parent GET carries CURL_PARENT_DESC and
# CURL_PARENT_CHILDREN (a JSON array); with CURL_FLIP_FILE set, every create
# also becomes one of the parent's children. CURL_CREATE_NO_ID=1 answers a
# create with a key and no id.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
method=GET; url=""; data=""; inline=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -d) inline="$2"; shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2#Idempotency-Key: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in https://ledger.example/*) ;; *) echo "NETWORK $method $url" >> "$CURL_LOG.net"; exit 7 ;; esac
printf '%s %s %s\n' "$method" "$url" "$k" >> "$CURL_LOG"
seq=$(wc -l < "$CURL_LOG" | tr -d ' ')
body=""
[ -n "$data" ] && body=$(cat "${data#@}")
[ -n "$inline" ] && body="$inline"
[ -n "$body" ] && printf '%s' "$body" > "$CURL_BODIES/$seq.json"
pos="${k##*-}"
case "$method $url" in
  "GET "*/boards) cat "$CURL_BOARDS" ;;
  "GET "*/tickets/*)
    [ -n "${CURL_PARENT_RC:-}" ] && exit "$CURL_PARENT_RC"
    ch="${CURL_PARENT_CHILDREN:-[]}"
    [ -n "${CURL_FLIP_FILE:-}" ] && [ -s "$CURL_FLIP_FILE" ] && ch=$(jq -sc . "$CURL_FLIP_FILE")
    jq -nc --arg id "${url##*/}" --arg k "${CURL_PARENT_KEY:-LG-9}" --arg d "${CURL_PARENT_DESC:-}" --argjson c "$ch" \
      '{ticket:{id:$id,key:$k,priority:"high",status:"in_progress",description:$d,children:$c}}' ;;
  "POST "*/boards/*/tickets)
    [ "$pos" = "${CURL_FAIL_CREATE:-x}" ] && exit 22
    if [ "${CURL_CREATE_NO_ID:-}" = 1 ]; then printf '{"ticket":{"key":"LG-10%s"}}\n' "$pos"; exit 0; fi
    [ -n "${CURL_FLIP_FILE:-}" ] && printf '{"id":"cmChild0%s","key":"LG-10%s","status":"todo"}\n' "$pos" "$pos" >> "$CURL_FLIP_FILE"
    printf '{"ticket":{"id":"cmChild0%s","key":"LG-10%s"}}\n' "$pos" "$pos" ;;
  "POST "*/comments) printf '{"comment":{"id":"c%s"}}\n' "$seq" ;;
  "POST "*/move) printf '{"ticket":{"status":"%s"}}\n' "$(printf '%s' "$body" | jq -r .toStatus)" ;;
  *) exit 22 ;;
esac
exit 0
SH
# GitHub. `gh api -i -X GET <path>` answers $GH_DIR/<path, '/', '?', '=' as _>.json
# with 200, else 404. Every call lands in $GH_DIR/GH.log.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
echo "$*" >> "${GH_DIR:-/dev/null}/GH.log"
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  f="${GH_DIR:-/nonexistent}/$(printf '%s' "${5:-}" | tr '/?=' '___').json"
  if [ -r "$f" ]; then printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n%s\n' "$(cat "$f")"; exit 0; fi
  printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"message":"Not Found"}\n'; exit 1
fi
exit 1
SH
chmod +x "$T/stub/curl" "$T/stub/gh"
printf '[{"id":"rb-1","capabilities":["dependencies"]}]\n' > "$T/boards-cap.json"

unset GH_TOKEN GITHUB_TOKEN SLICE_BOARD_FILE_OWNER 2>/dev/null || true
export PATH="$T/stub:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" CURL_BOARDS="$T/boards-cap.json" GH_ETAG=0

# case_dir <name> — a fresh, private request log, body dir, alert log and gh dir.
case_dir() {
  C="$T/case/$1"; mkdir -p "$C/bodies" "$C/gh"
  export CURL_LOG="$C/curl.log" CURL_BODIES="$C/bodies" ALERT_LOG="$C/alerts.log" GH_DIR="$C/gh"
  : > "$CURL_LOG"; : > "$ALERT_LOG"
}
creates()  { grep -c '^POST .*/boards/rb-1/tickets ' "$CURL_LOG"; }
comments() { grep -c '^POST .*/comments ' "$CURL_LOG"; }
moves()    { grep -c '^POST .*/move ' "$CURL_LOG"; }
alerts()   { grep -c . "$ALERT_LOG"; }
body_n()   { # body_n <grep pattern> <nth> -> the body of that request
  local s; s=$(grep -n "$1" "$CURL_LOG" | sed -n "${2:-1}p" | cut -d: -f1)
  [ -n "$s" ] && cat "$C/bodies/$s.json" 2>/dev/null
}
cbody() { body_n '/comments ' "${1:-1}" | jq -r .body; }
# keep <ledger> — the case's recorded children, for N5.
keep() { cat "$1/children.txt" > "$C/children.txt" 2>/dev/null || : > "$C/children.txt"; }

# ---- plan shapes ------------------------------------------------------------
# TK-618: no SLICE line, a SLICE-REASON, slice C0 in a heading, a coverage row
# that leaves the project-2 Prep tab to C1.
plan_pb618() {
  cat > "$1" <<'EOF'
# LG-9 plan

SLICE-REASON: ordering: the project-2 prep enum lands before the tab reads it

## Slice C0: the project-2 prep enum

Build the enum and its migration.

## Requirements coverage

| # | Requirement | Task | Test |
|---|---|---|---|
| 1 | project-2 prep enum on the return | T1 | A1 |
| 2 | project-2 Prep tab grouped by return | C1 | - |
EOF
}
# TK-638: a strong SLICE line, a prose rest, no C<j> list. $2: matrix|none|covered
plan_prose() {
  {
    printf '# LG-9 plan\n\nSLICE: C0 of #%s\n\n## Why one slice\n\n' "$CUID"
    printf 'This PR builds the schema. The Documents tab comes after it.\n'
    case "${2:-none}" in
      matrix)  printf '\n## Requirements coverage\n\n| # | Requirement | Task |\n|---|---|---|\n| 1 | Schema | T1 |\n| 2 | Documents tab per return | C1 |\n' ;;
      covered) printf '\n## Requirements coverage\n\n| # | Requirement | Task |\n|---|---|---|\n| 1 | Schema | T1 |\n| 2 | Documents tab per return | T2 |\n' ;;
    esac
  } > "$1"
}

# settle <rec|-> [ticket] [park] [VAR=value ...] -> the word; rc in $SRC
settle() {
  local rec="$1" tid="${2-$CUID}" park="${3:-1}"; shift 3 2>/dev/null || shift $#
  SW=$(env "$@" bash -c '. "$1/slice-board.sh"; slice_board_settle ledger-os LG-9 "$2" "$3" "$4" "$5" "$6"' \
    _ "$LIB" "$PRURL" "$rec" "$tid" "$park" "$T/h" 2>>"$T/settle.err"); SRC=$?
}
mkrec() { REC="$T/h/builds/ledger-os-LG-9-$1"; mkdir -p "$REC"; }

# ════════════════════════════════════════════════════════════════════════════
# K0-K16  slice_board_marker
# ════════════════════════════════════════════════════════════════════════════
# mk <plan text> [title] [key] -> "<rc>|<k>" for ticket CUID
mk() {
  printf '%s\n' "$1" > "$T/mk.md"
  bash -c '. "$1/slice-board.sh"; k=$(slice_board_marker "$2" "$3" "$4" "$5"); echo "$?|$k"' \
    _ "$LIB" "$T/mk.md" "${2:-}" "$CUID" "${3:-LG-9}" 2>/dev/null
}
mk_is() { local want="$1" name="$2"; shift 2; local got; got=$(mk "$@"); [ "$got" = "$want" ] && ok || bad "$name: want $want, got '$got'"; }
mk_no() { local name="$1"; shift; local got; got=$(mk "$@"); [ "${got%%|*}" = 1 ] && ok || bad "$name: not a slice of this ticket, rc 1 (got '$got')"; }
mk_no K0 "# p

## Scope
- a plain plan"
mk_is "0|0" K1 "# p

SLICE: C0"
mk_is "0|1" K2 "# p

**Slice:** C1 (schema)"
mk_is "0|0" K3 "# p

SLICE-REASON: ordering: C1 reads C0's table

## Why slice C0 first"
mk_is "0|2" K3b "# p

SLICE-REASON: context-ceiling

## Slice C2: the export"
mk_is "0|0" K4 "# p

SLICE-REASON: file-overlap"
mk_is "0|0" K5 "# p

This plan builds slice C0."
mk_is "0|1" K5b "# p

This PR delivers C1 of #$CUID, and nothing else."
mk_is "0|0" K6 "# p" "TK-618: C0 project-2 prep enum" TK-618
mk_is "0|0" K7 "# p" "TK-604 (C0) SQL" TK-604
mk_is "0|1" K8 "# p" "[TK-604] slice C1: code" TK-604
mk_no K9 "# p

SLICE: none"
mk_no K10 "# p

Commit C0FFEE is the base." "TK-700: C0FFEE base" TK-700
mk_no K11 "# p

We take a slice of the list."
mk_no K12 "# p

This waits until after slice C1 of TK-604 merges." "" TK-700
mk_no K13 "# p

This plan builds slice C1 of #cmzzzzzz9999k07kzd588kq7r"
mk_no K14 "# p

\`\`\`
SLICE: C0
\`\`\`"
mk_no K15 "# p

| T3 | route-suite C4–C7 |"
mk_no K16 "# p" "TK-700: CSV export" TK-700
mk_no K16b "# p" "TK-700: fix C0 enum" TK-700

# ════════════════════════════════════════════════════════════════════════════
# A1  the TK-618 shape: no SLICE line, a coverage row -> one Rest child
# ════════════════════════════════════════════════════════════════════════════
case_dir A1; mkrec a1; plan_pb618 "$REC/plan.md"
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "filed:LG-101|0" ] && ok || bad "A1: a plan with no SLICE line files the rest (got $SW|$SRC; $(tail -3 "$T/settle.err"))"
[ "$(creates)" = 1 ] && ok || bad "A1: one create (got $(creates))"
B=$(body_n '/boards/rb-1/tickets ' 1)
[ "$(jq -r .parentId <<<"$B")" = "$CUID" ] && ok || bad "A1: the child carries parentId = the master id (got $B)"
jq -r .title <<<"$B" | grep -qF 'Rest of LG-9: project-2 Prep tab grouped by return' && ok || bad "A1: the child title is Rest of LG-9: <row> (got $(jq -r .title <<<"$B"))"
jq -r .description <<<"$B" | grep -qF 'project-2 Prep tab grouped by return' && ok || bad "A1: the row is in the child description"
jq -r .description <<<"$B" | grep -qF 'Slice C0 of LG-9 merged' && ok || bad "A1: the child says which slice merged"
[ "$(comments)" = 1 ] && cbody | grep -q 'LG-101' && ok || bad "A1: one master comment that names LG-101 ($(comments): $(cbody))"
keep "$REC/slice-board"

# ════════════════════════════════════════════════════════════════════════════
# C3a-C3c  a SLICE line with no C<j> list (TK-638)
# ════════════════════════════════════════════════════════════════════════════
case_dir C3a; mkrec c3a; plan_prose "$REC/plan.md" matrix
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "filed:LG-101|0" ] && ok || bad "C3a: a prose rest with an uncovered row is filed (got $SW|$SRC)"
body_n '/boards/rb-1/tickets ' 1 | jq -r .description | grep -qF 'Documents tab per return' && ok || bad "C3a: the uncovered row is the child's item"
keep "$REC/slice-board"

case_dir C3b; mkrec c3b; plan_prose "$REC/plan.md" none
settle "$REC" "$CUID" 1 CURL_PARENT_DESC='<p>Intro line.</p><h2>Scope</h2><ul><li>Documents tab</li><li>Upload &amp; review</li></ul><h2>Out of scope</h2><ul><li>Billing</li></ul>'
[ "$SW|$SRC" = "filed:LG-101|0" ] && ok || bad "C3b: no matrix, the parent scope is the rest (got $SW|$SRC)"
D=$(body_n '/boards/rb-1/tickets ' 1 | jq -r .description)
grep -qF 'Documents tab' <<<"$D" && ok || bad "C3b: the scope item is in the child ($D)"
grep -qF 'Upload &amp; review' <<<"$D" && ! grep -qF '&amp;amp;' <<<"$D" && ok || bad "C3b: the entities are undone once, then escaped once ($D)"
grep -qF 'Billing' <<<"$D" && bad "C3b: an Out of scope item is never the rest" || ok
keep "$REC/slice-board"

case_dir C3c; mkrec c3c; plan_prose "$REC/plan.md" covered
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "unknown:covered|2" ] && ok || bad "C3c: every row covered is unknown:covered (got $SW|$SRC)"
[ "$(alerts)" = 1 ] && [ "$(creates)" = 0 ] && [ "$(comments)" = 1 ] && ok || bad "C3c: 1 page, 0 creates, 1 note (got $(alerts)/$(creates)/$(comments))"
keep "$REC/slice-board"

# ════════════════════════════════════════════════════════════════════════════
# A4 + N1  nothing readable: unknown:none, one page, one honest note, twice
# ════════════════════════════════════════════════════════════════════════════
case_dir A4; mkrec a4; plan_prose "$REC/plan.md" none
settle "$REC" "$CUID" 1; W1="$SW|$SRC"
settle "$REC" "$CUID" 1
[ "$W1" = "unknown:none|2" ] && [ "$SW|$SRC" = "unknown:none|2" ] && ok || bad "A4: nothing readable is unknown:none, twice (got $W1 then $SW|$SRC)"
[ "$(alerts)" = 1 ] && ok || bad "A4: one page over two settles (got $(alerts))"
grep -q 'slice-board-unknown:ledger-os:LG-9:752' "$ALERT_LOG" && ok || bad "A4: the page names the ticket"
[ "$(comments)" = 1 ] && ok || bad "N1: exactly one note over two settles (got $(comments))"
cbody | grep -q 'NOT filed' && ok || bad "N1: the note says the rest is NOT filed ($(cbody))"
cbody | grep -q 'the operator files them by hand' && ok || bad "N1: the note names the default owner ($(cbody))"
cbody | grep -q 'pull/752' && ok || bad "N1: the note links the merged PR"
[ -e "$REC/slice-board/noted" ] && ok || bad "N1: the ledger records the note"
keep "$REC/slice-board"

case_dir N2; mkrec n2; plan_prose "$REC/plan.md" none
settle "$REC" "$CUID" 1 SLICE_BOARD_FILE_OWNER=Dana
cbody | grep -q 'Dana files them by hand' && ok || bad "N2: the owner knob names who files ($(cbody))"
keep "$REC/slice-board"

# park 0 (the builder close-out owns its comment): no note.
case_dir N1b; mkrec n1b; plan_prose "$REC/plan.md" none
settle "$REC" "$CUID" 0
[ "$SW" = "unknown:none" ] && [ "$(comments)" = 0 ] && ok || bad "N1b: park 0 posts no note (got $SW, $(comments) comments)"
keep "$REC/slice-board"

# a parent that is not KEY: the page, never a note on the wrong ticket.
case_dir N1c; mkrec n1c; plan_prose "$REC/plan.md" matrix
settle "$REC" "$CUID" 1 CURL_PARENT_KEY=LG-77
[ "$SW" = "unknown:parent" ] && [ "$(comments)" = 0 ] && [ "$(alerts)" = 1 ] && ok || bad "N1c: a wrong parent is paged and gets no note (got $SW, $(comments) comments, $(alerts) pages)"
keep "$REC/slice-board"

# ════════════════════════════════════════════════════════════════════════════
# D1-D2, N3  dedupe on the parent's own children
# ════════════════════════════════════════════════════════════════════════════
KID='[{"id":"cmKid","key":"LG-50","status":"todo"}]'
case_dir D1; mkrec d1; plan_pb618 "$REC/plan.md"
settle "$REC" "$CUID" 1 CURL_PARENT_CHILDREN="$KID"
[ "$SW|$SRC" = "exists:LG-50|0" ] && ok || bad "D1: a parent with a child gives exists:LG-50 rc 0 (got $SW|$SRC)"
[ "$(creates)" = 0 ] && ok || bad "D1: no second child (got $(creates) creates)"
[ "$(comments)" = 1 ] && cbody | grep -q 'already has its own tickets: LG-50' && ok || bad "D1: one note naming LG-50 ($(cbody))"
grep -q 'We filed' <<<"$(cbody)" && bad "D1: the note never says We filed" || ok
[ "$(cat "$REC/slice-board/exists" 2>/dev/null)" = LG-50 ] && ok || bad "D1: the ledger records exists"
: > "$CURL_LOG"
settle "$REC" "$CUID" 1 CURL_PARENT_CHILDREN="$KID"
[ "$SW|$SRC" = "exists:LG-50|0" ] && ok || bad "N3: the second settle answers exists from the ledger (got $SW|$SRC)"
[ "$(comments)" = 0 ] && ok || bad "N3: one note in total over two settles"
keep "$REC/slice-board"

case_dir D2; mkrec d2; plan_pb618 "$REC/plan.md"
export CURL_FLIP_FILE="$C/children.jsonl"; : > "$CURL_FLIP_FILE"
settle "$REC" "$CUID" 1; W1="$SW"
# The same merge, settled again with no record (a state ledger): the merged spec.
printf '{"title":"LG-9: project-2 prep enum","merged_at":"2026-11-24T23:00:00Z","merge_commit_sha":"abc123","body":"Refs LG-9"}' > "$GH_DIR/repos_example-org_ledger-os_pulls_752.json"
jq -nc --arg c "$(base64 -w0 < "$REC/plan.md")" '{encoding:"base64",content:$c}' > "$GH_DIR/repos_example-org_ledger-os_contents_.harness_specs_LG-9_plan.md_ref_abc123.json"
settle - "$CUID" 1
[ "$W1" = "filed:LG-101" ] && [ "$SW|$SRC" = "exists:LG-101|0" ] && ok || bad "D2: the record ledger files, the state ledger sees the child (got $W1 then $SW|$SRC; $(tail -3 "$T/settle.err"))"
[ "$(creates)" = 1 ] && ok || bad "D2: one create in total over two ledgers (got $(creates))"
cat "$REC/slice-board/children.txt" > "$C/children.txt" 2>/dev/null
unset CURL_FLIP_FILE
rm -rf "$T/h/state/slice-board"

# D3 the merge's own lock: a held state-level lock defers a record ledger too.
case_dir D3; mkrec d3; plan_pb618 "$REC/plan.md"; mkdir -p "$T/h/state/slice-board"
( flock -x 7; : > "$C/held"; sleep 4 ) 7>"$T/h/state/slice-board/.lock-ledger-os-LG-9-pr752" &
LP=$!
for _ in $(seq 1 50); do [ -e "$C/held" ] && break; sleep 0.1; done
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "deferred:locked|1" ] && [ "$(creates)" = 0 ] && ok || bad "D3: a held merge lock defers the other ledger (got $SW|$SRC, $(creates) creates)"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
: > "$C/children.txt"

# ════════════════════════════════════════════════════════════════════════════
# N4  a create with a key and no id: never "We filed"
# ════════════════════════════════════════════════════════════════════════════
case_dir N4; mkrec n4; plan_pb618 "$REC/plan.md"
settle "$REC" "$CUID" 1 CURL_CREATE_NO_ID=1
[ "$SW|$SRC" = "deferred:file-failed|1" ] && ok || bad "N4: a create with no id is deferred:file-failed (got $SW|$SRC)"
[ ! -s "$REC/slice-board/children.txt" ] && ok || bad "N4: nothing is recorded as filed"
grep -l 'We filed' "$C"/bodies/*.json >/dev/null 2>&1 && bad "N4: no body says We filed" || ok
[ "$(comments)" = 1 ] && cbody | grep -q 'NOT filed yet' && ok || bad "N4: one note says NOT filed yet ($(comments): $(cbody))"
keep "$REC/slice-board"

# ════════════════════════════════════════════════════════════════════════════
# H1, H4  a hand-opened slice PR: no record, no spec, the PR body is the plan
# ════════════════════════════════════════════════════════════════════════════
hand_pr() { # hand_pr <title> <body>
  jq -nc --arg t "$1" --arg b "$2" '{title:$t,merged_at:"2026-11-24T23:00:00Z",merge_commit_sha:"abc123",body:$b}' \
    > "$GH_DIR/repos_example-org_ledger-os_pulls_752.json"
}
HBODY='Refs LG-9

SLICE: C0

## Requirements coverage

| # | Requirement | Task |
|---|---|---|
| 1 | Schema | T1 |
| 2 | Documents tab code | C1 |'
cli() { OUT=$("$T/h/bin/slice-board-settle.sh" ledger-os LG-9 "$PRURL" - --ticket "$CUID" "$@" 2>>"$T/settle.err"); RC=$?; }
case_dir H1; rm -rf "$T/h/state/slice-board"
hand_pr "LG-9: schema" "$HBODY"
cli
[ "$OUT|$RC" = "filed:LG-101|0" ] && ok || bad "H1: a hand PR with no record and no spec settles from its body (got $OUT|$RC; $(tail -3 "$T/settle.err"))"
grep -q 'contents/.harness/specs/LG-9/plan.md' "$GH_DIR/GH.log" && ok || bad "H1: the merged spec was asked for first"
body_n '/boards/rb-1/tickets ' 1 | jq -r .description | grep -qF 'Documents tab code' && ok || bad "H1: the body's uncovered row is the child's item"
keep "$T/h/state/slice-board/ledger-os-LG-9-pr752"
rm -rf "$T/h/state/slice-board"

case_dir H4
hand_pr "Schema fix" "SLICE: C0"
cli
[ "$OUT|$RC" = "skip:no-plan|3" ] && ok || bad "H4: no KEY in the title and no Refs in the body is skip:no-plan (got $OUT|$RC)"
[ "$(grep -c . "$CURL_LOG")" = 0 ] && ok || bad "H4: no board call"
[ ! -e "$T/h/state/slice-board/ledger-os-LG-9-pr752" ] && ok || bad "H4: a skip leaves no ledger"
case_dir H4b
hand_pr "Schema fix" "$HBODY"
cli
[ "$OUT|$RC" = "filed:LG-101|0" ] && ok || bad "H4b: no KEY in the title, but the body names LG-9 and a slice (got $OUT|$RC)"
keep "$T/h/state/slice-board/ledger-os-LG-9-pr752"
rm -rf "$T/h/state/slice-board"

# ════════════════════════════════════════════════════════════════════════════
# H2  mc_settle_merged: no record, no ticket/ branch -> the KEY from the title
# ════════════════════════════════════════════════════════════════════════════
M="$T/m"; mkdir -p "$M/bin/lib/mc" "$M/logs" "$M/state" "$M/env" "$M/flags" "$M/builds" "$T/mtmp"
for s in beat.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$M/bin/$s"; chmod +x "$M/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/spawned.txt"\n' "$M" > "$M/bin/slice-board-settle.sh"; chmod +x "$M/bin/slice-board-settle.sh"
: > "$M/env/global.env"
for s in bin/lib/merge-conductor-lib.sh bin/fleet-conf.sh; do scratch_install_closure "$s" "$M" >/dev/null || exit 1; done
printf 'ledger-os example-org/ledger-os https://ledger.example /api/board 3\n' > "$M/fleet.conf"
(
  export HARNESS="$M" TMPDIR="$T/mtmp" FLEET_CONF="$M/fleet.conf" MC_DETACHED_DEPLOY_VERIFY=0
  # shellcheck source=/dev/null
  . "$M/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_init
  # The PR read is GitHub's: a function stub, as the M-cases stub the conductor.
  mc_pr_view() { case "$1" in */pull/913) [ "$2" = .title ] && echo "LG-9: code" ;; */pull/914) [ "$2" = .title ] && echo "Fix the thing" ;; esac; return 0; }
  mc_settle_merged "example-org/ledger-os#913" https://github.com/example-org/ledger-os/pull/913 ledger-os example-org/ledger-os feature/x "" - aaaa1111 cccc3333 >/dev/null 2>&1
  mc_settle_merged "example-org/ledger-os#914" https://github.com/example-org/ledger-os/pull/914 ledger-os example-org/ledger-os fix/thing "" - aaaa1111 dddd4444 >/dev/null 2>&1
) || bad "H2: mc_settle_merged could not run"
for _ in $(seq 1 20); do [ -s "$M/spawned.txt" ] && break; sleep 0.3; done
sleep 0.3
grep -qxF "ledger-os LG-9 https://github.com/example-org/ledger-os/pull/913 - --park 1" "$M/spawned.txt" 2>/dev/null && ok \
  || bad "H2: a hand PR on a feature branch spawns the settle with the KEY from its title (got '$(cat "$M/spawned.txt" 2>/dev/null)')"
[ "$(grep -c . "$M/spawned.txt" 2>/dev/null)" = 1 ] && ok || bad "H2: a title with no KEY spawns nothing"
grep -q 'example-org/ledger-os#914 board slice settle NOT spawned' "$M/logs/merge-conductor.log" 2>/dev/null && ok || bad "H2: no KEY is one log line"

# ════════════════════════════════════════════════════════════════════════════
# H3  bin/merged-ticket-advance.sh: a held slice spawns the settle once
# ════════════════════════════════════════════════════════════════════════════
MH="$T/ma"; MB="$T/maboard"
mkdir -p "$MH/bin/lib" "$MH/env" "$MH/logs" "$MH/state" "$MH/flags" "$MH/builds" "$T/mafake" "$MB/gh"
for s in bin/merged-ticket-advance.sh bin/internal-token-for.sh bin/alert-line.sh bin/prod-url.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$MH" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/spawned.txt"\n' "$MH" > "$MH/bin/slice-board-settle.sh"
chmod +x "$MH/bin/"*.sh
printf 'x-os example-org/x-os https://x.test /api/board 3 local\n' > "$MH/fleet.conf"
: > "$MH/env/global.env"
printf 'X_API_BASE=https://x.test\nX_INTERNAL_API_TOKEN=tok-fixture-never-logged\n' > "$MH/env/x-os.env"
# The board: GET /boards, GET /boards/<id>/tickets and GET /tickets/<id> from
# db.json; every POST is recorded and answered 200. Status code last on stdout
# (the lane reads curl -w).
cat > "$T/mafake/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; URL=""
while [ $# -gt 0 ]; do
  case "$1" in -o) OUT="$2"; shift ;; -X) METHOD="$2"; shift ;; --data-binary|-H|-w|--max-time|-d) shift ;; http*) URL="$1" ;; esac
  shift
done
w() { if [ -n "$OUT" ]; then printf '%s' "$1" > "$OUT"; else printf '%s' "$1"; fi; }
echo "$METHOD $URL" >> "$MB/REQS.log"
if [ "$METHOD" = POST ]; then w '{"id":1}'; printf 200; exit 0; fi
case "$URL" in
  */boards) w '{"boards":[{"id":"b1","name":"Main"}]}' ;;
  */boards/*/tickets) w "$(jq -c '{tickets: map(del(.comments))}' "$MB/db.json")" ;;
  */tickets/*) w "$(jq -c --arg id "${URL##*/}" '[.[] | select((.id|tostring) == $id)][0] // {}' "$MB/db.json")" ;;
  *) w '{}'; printf 404; exit 0 ;;
esac
printf 200
SH
cat > "$T/mafake/gh" <<'SH'
#!/bin/bash
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  f="$MB/gh/$(printf '%s' "${5:-}" | tr '/' '_').json"
  if [ -r "$f" ]; then printf 'HTTP/2.0 200 X\r\nContent-Type: application/json\r\n\r\n%s\n' "$(cat "$f")"; exit 0; fi
  printf 'HTTP/2.0 404 X\r\n\r\n{}\n'; exit 1
fi
[ "${1:-}" = api ] && [ "${3:-}" = -q ] && { echo 1; exit 0; }
exit 1
SH
chmod +x "$T/mafake/curl" "$T/mafake/gh"
ma_run() {
  : > "$MB/REQS.log"; rm -f "$MH/spawned.txt"
  ( export HARNESS="$MH" FLEET_CONF="$MH/fleet.conf" MB JOBS_ALERT=0 PATH="$T/mafake:$PATH"
    unset MERGED_ADVANCE_MAX MERGED_ADVANCE_COOLDOWN_S
    "$MH/bin/merged-ticket-advance.sh" x-os >/dev/null 2>"$T/ma.err" )
  for _ in $(seq 1 20); do [ -s "$MH/spawned.txt" ] && break; sleep 0.2; done
  sleep 0.3
}
ma_line() { grep 'MERGED_ADVANCE moved=' "$MH/logs/x-os.log" 2>/dev/null | tail -1; }
# A peer-built ticket: no build dir here, a thread comment with PR 77, PR 77
# merged with a weak slice marker in its body (no `of #`).
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg t "$NOW" '[{id:501,key:"TK-501",title:"Ticket TK-501",status:"in_progress",waitingOn:"team",reporter:{userId:"u_7",name:"R"},
  comments:[{author:{userId:"cyg",name:"partner"},createdAt:$t,body:"Ready in https://github.com/example-org/x-os/pull/77"}]}]' > "$MB/db.json"
jq -nc --arg m "$NOW" '{number:77,state:"closed",merged_at:$m,merge_commit_sha:"abcdef1234567890abcdef1234567890abcdef12",title:"TK-501: schema",body:"Refs TK-501\n\nSLICE: C0\n"}' \
  > "$MB/gh/repos_example-org_x-os_pulls_77.json"
ma_run
[ "$(cat "$MH/spawned.txt" 2>/dev/null)" = "x-os TK-501 https://github.com/example-org/x-os/pull/77 - --ticket 501 --park 1" ] && ok \
  || bad "H3: a held peer slice spawns the settle once with --ticket (got '$(cat "$MH/spawned.txt" 2>/dev/null)'; $(ma_line); $(head -3 "$T/ma.err"))"
grep -q 'MERGED_ADVANCE_SLICE_SETTLE TK-501 https://github.com/example-org/x-os/pull/77' "$MH/logs/x-os.log" && ok || bad "H3: one MERGED_ADVANCE_SLICE_SETTLE line"
ma_line | grep -q 'slice-plan=1 slice-settle=1$' && ok || bad "H3: the summary counts the hold and the spawn ($(ma_line))"
grep -q '^POST' "$MB/REQS.log" && bad "H3: a held slice posts nothing itself" || ok
# A terminal ledger: held, no spawn.
mkdir -p "$MH/state/slice-board/x-os-TK-501-pr77"; echo LG-50 > "$MH/state/slice-board/x-os-TK-501-pr77/exists"
ma_run
[ ! -s "$MH/spawned.txt" ] && ok || bad "H3: a terminal ledger spawns nothing (got '$(cat "$MH/spawned.txt" 2>/dev/null)')"
ma_line | grep -q 'slice-plan=1 slice-settle=0$' && ok || bad "H3: held, not spawned ($(ma_line))"

# ════════════════════════════════════════════════════════════════════════════
# B1-B5  bin/board-closeout.sh
# ════════════════════════════════════════════════════════════════════════════
closeout() { # closeout <rec> [VAR=value ...] -> stdout in $OUT, rc in $BRC
  local rec="$1"; shift
  OUT=$(env "$@" "$T/h/bin/board-closeout.sh" ledger-os "$CUID" LG-9 "$rec" 2>>"$T/closeout.err"); BRC=$?
}
brec() { # brec <name> <result-line> <plan fn> [arg]
  mkrec "$1"; "$3" "$REC/plan.md" "${4:-}"
  echo "$2" > "$REC/RESULT"
  printf -- '- the inbound ledger\n' > "$REC/what.txt"
}
moved_to() { body_n '/move ' 1 | jq -r .toStatus; }

case_dir B1; brec b1 "PR_MERGED $PRURL" plan_pb618
closeout "$REC"
[ "$BRC" = 0 ] && [ "$(moved_to)" = in_progress ] && ok || bad "B1: a weak-marker plan merged moves to in_progress (rc $BRC, $(moved_to); $(tail -3 "$T/closeout.err"))"
grep -q '"toStatus":"done"' "$C"/bodies/*.json && bad "B1: never done" || ok
cbody | grep -q '<li>LG-101: ' && ok || bad "B1: the comment names the filed child ($(cbody))"
keep "$REC/slice-board"

case_dir B2; brec b2 "PR_MERGED $PRURL" plan_prose none
closeout "$REC"
[ "$BRC" = 0 ] && ok || bad "B2: unknown still posts (rc $BRC)"
cbody | grep -q 'not filed' && cbody | grep -q 'the operator files them by hand' && ok || bad "B2: the comment says not filed and who files ($(cbody))"
[ "$(comments)" = 1 ] && ok || bad "B2: one comment (got $(comments))"
# B4: the conductor's park-1 settle on the same record posts nothing more.
settle "$REC" "$CUID" 1
[ "$(comments)" = 1 ] && ok || bad "B4: close-out then a park-1 settle is one comment in total (got $(comments))"
keep "$REC/slice-board"

case_dir B3; brec b3 "PR_MERGED $PRURL" plan_pb618
closeout "$REC" CURL_PARENT_CHILDREN="$KID"
[ "$BRC" = 0 ] && [ "$(moved_to)" = in_progress ] && ok || bad "B3: exists posts and moves to in_progress (rc $BRC, $(moved_to))"
cbody | grep -q 'already has its own tickets: LG-50' && ok || bad "B3: the comment names LG-50 ($(cbody))"
grep -q 'We filed' <<<"$(cbody)" && bad "B3: no We filed when nothing was filed" || ok
[ "$(creates)" = 0 ] && ok || bad "B3: no create"
keep "$REC/slice-board"

case_dir B5; brec b5 "PR_CREATED $PRURL" plan_prose none
closeout "$REC"
cbody | grep -q 'This PR is slice C0 of the plan. When it merges, we file the remaining slices' && ok || bad "B5: the BH-8333 sentence stays ($(cbody))"
cbody | grep -q 'If we cannot file them, we say so here.' && ok || bad "B5: the honest condition is appended ($(cbody))"
[ "$(creates)" = 0 ] && ok || bad "B5: nothing filed before the merge"
: > "$C/children.txt"

# ════════════════════════════════════════════════════════════════════════════
# N5  over every case: "filed each remaining slice" only names recorded keys
# ════════════════════════════════════════════════════════════════════════════
N5BAD=""; N5SEEN=0
for cd in "$T"/case/*/; do
  for f in "$cd"bodies/*.json; do
    [ -r "$f" ] || continue
    b=$(jq -r '.body // empty' "$f" 2>/dev/null)
    grep -q 'filed each remaining slice' <<<"$b" || continue
    N5SEEN=$((N5SEEN + 1))
    for k in $(grep -oE '<li>(<a [^>]*>)?[A-Z]+-[0-9]+' <<<"$b" | grep -oE '[A-Z]+-[0-9]+$'); do
      grep -qxF "$k" "$cd/children.txt" 2>/dev/null || N5BAD="$N5BAD $(basename "$cd"):$k"
    done
  done
done
[ "$N5SEEN" -ge 3 ] && [ -z "$N5BAD" ] && ok || bad "N5: every 'filed' comment names only recorded children (seen $N5SEEN, unrecorded:$N5BAD)"

# Z: 0 network — every curl went to the board stub, every gh to the gh stub.
grep -q . <<<"$(cat "$T"/case/*/curl.log.net 2>/dev/null)" && bad "Z: a request left the stubs ($(cat "$T"/case/*/curl.log.net | head -3))" || ok

echo "slice-board-remainder.bh-10080: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
