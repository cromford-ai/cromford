#!/bin/bash
# tests/triage-board-pages.bh-8497-test.sh — BH-8497: the GitHub-Issues board
# fingerprint (bin/triage-gate.sh fetch_fingerprint) holds EVERY open ai-build
# issue, not the first page of `state=all`.
#
# THE DEFECT. The gate read ONE page: `issues?labels=ai-build&state=all&per_page=100`.
# On project-6-os (131 open, ~250 ai-build issues in all) that page held the
# 100 newest issues, 13 of them open, so triage saw 13 of 131 open tickets.
#
#   1  every open issue is in the fingerprint (state=open, paged to a short
#      page), and no closed issue (the operator, comment 6426367666: closed tickets do
#      not belong in the open-ticket snapshot); a second unchanged run answers
#      every page 304 from the ETag cache and writes the same bytes
#   2  the page cap is a knob; a full cap page writes ONE ALERT line a day
#   3  a closed blocker is not placed by the fingerprint: it is an absent ref,
#      and resolves CLOSED from refs.json (the REST ref lookup)
#   4  ts_precheck counts the open set: "131 open"
#   5  the page loop stop rule, and a bad page body fails the fetch
#   6  no closed read is made (a dead closed endpoint changes nothing); a
#      failed open page 2 fails the whole read
#   7  the comment's fixture: 131 open where the 20 OLDEST-created have the
#      NEWEST comments, GitHub's default sort (created desc): all 131 are in
#      the snapshot on each of two ticks
#
# Drives the REAL bin/triage-gate.sh (its libs come from this checkout, beside
# it) against a scratch $HARNESS. `gh` is a PATH stub serving fixture issues
# with ETag/304. No network, no model.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-board-pages.bh-8497-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/bin" "$T/state" "$T/flags" "$T/logs" "$T/env" "$T/fakebin" "$T/fx"
P=p

cat > "$T/bin/fleet-conf.sh" <<'SH'
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
chmod +x "$T/bin/fleet-conf.sh"
# The cap ALERT goes through $HARNESS/bin/alert-line.sh.
( cd "$DIR" && scratch_install_closure bin/alert-line.sh "$T" ) >/dev/null || { echo "FAIL: setup: cannot install bin/alert-line.sh"; exit 1; }

# The fake gh: `gh api -i -X GET repos/o/r/issues -f state=.. -F page=..`.
# Rows come from $T/fx/all.json (newest-CREATED first, GitHub's default sort;
# `sort=updated` sorts by updated_at desc), filtered by state and sliced by page. Each answer carries an ETag (the sha1 of its body);
# an If-None-Match that equals it answers 304 with no body. One line per call
# goes to $GH_SINK: "<path> state=<s> page=<n> inm=<0|1> -> <status> <rows>".
# $T/fx/fail-<state> makes that state's read answer 500; $T/fx/junk-<state>
# makes it answer 200 with an object body.
cat > "$T/fakebin/gh" <<'SH'
[ "${1:-}" = api ] || exit 1
shift
P=""; STATE=""; PAGE=1; INM=""; SORT=created
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X) shift 2 ;;
    -f|-F)
      case "$2" in state=*) STATE="${2#state=}" ;; page=*) PAGE="${2#page=}" ;; sort=*) SORT="${2#sort=}" ;; esac
      shift 2 ;;
    -H) case "$2" in [Ii]f-[Nn]one-[Mm]atch:*) INM="${2#*: }" ;; esac; shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift ;;
  esac
done
case "$P" in
  repos/o/r/pulls*) printf 'HTTP/2.0 200\r\n\r\n[]\n'; exit 0 ;;
  repos/o/r/issues) ;;
  *) printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
if [ -e "$T/fx/fail-$STATE" ]; then
  printf '%s state=%s page=%s inm=%s -> 500 0\n' "$P" "$STATE" "$PAGE" "$([ -n "$INM" ] && echo 1 || echo 0)" >> "$GH_SINK"
  printf 'HTTP/2.0 500\r\n\r\n{"message":"boom"}\n'; exit 1
fi
if [ -e "$T/fx/junk-$STATE" ]; then
  BODY='{"message":"not a list"}'
else
  BODY=$(jq -c --arg s "$STATE" --argjson pg "$PAGE" --arg sort "$SORT" \
    '[.[] | select($s == "all" or .state == $s)]
     | (if $sort == "updated" then sort_by(.updated_at) | reverse else sort_by(.number) | reverse end)
     | .[(($pg-1)*100):($pg*100)]' "$T/fx/all.json")
fi
ET="\"$(printf '%s' "$BODY" | sha1sum | cut -c1-20)\""
N=$(printf '%s' "$BODY" | jq 'if type=="array" then length else -1 end')
if [ -n "$INM" ] && [ "$INM" = "$ET" ]; then
  printf '%s state=%s page=%s inm=1 -> 304 %s\n' "$P" "$STATE" "$PAGE" "$N" >> "$GH_SINK"
  printf 'HTTP/2.0 304\r\nETag: %s\r\n\r\n' "$ET"; exit 1
fi
printf '%s state=%s page=%s inm=%s -> 200 %s\n' "$P" "$STATE" "$PAGE" "$([ -n "$INM" ] && echo 1 || echo 0)" "$N" >> "$GH_SINK"
printf 'HTTP/2.0 200\r\nETag: %s\r\n\r\n%s\n' "$ET" "$BODY"
exit 0
SH
chmod +x "$T/fakebin/gh"

# board <open-list> — 250 ai-build issues #1..#250, newest (highest number)
# first. The numbers in <open-list> (a jq array) are open, every other one is
# closed. Issue #5's body names #200 (a closed blocker on the closed page).
board() {
  jq -nc --argjson open "$1" '[range(250; 0; -1) as $n
    | {number: $n, state: (if ($open | index($n)) then "open" else "closed" end),
       title: "ticket \($n)", comments: 0, updated_at: "2026-10-20T10:00:00Z",
       body: (if $n == 5 then "Blocked-by: #200" else "body \($n)" end),
       labels: [{name: "ai-build"}], assignees: [], milestone: null}]' > "$T/fx/all.json"
}
# THE project-6 SHAPE: 131 open. 13 of them are among the 100 newest (#238-250),
# 118 are old (#1-118). #119-#237 are closed.
OPEN131='[range(1;119)] + [range(238;251)]'
OPEN131=$(jq -nc "$OPEN131")

gate() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt"; : > "$T/gh.txt"; \
           "$DIR/bin/triage-gate.sh" "$P" "$@" 2>"$T/err.txt" ); }
FP="$T/state/$P.gate.json"
nopen()   { jq '[.issues[] | select(.state=="OPEN")] | length' "${1:-$FP}" 2>/dev/null; }
nclosed() { jq '[.issues[] | select(.state=="CLOSED")] | length' "${1:-$FP}" 2>/dev/null; }
reset() { scratch_rm "$T/state"; mkdir -p "$T/state"; rm -f "$T/fx/fail-"* "$T/fx/junk-"* "$T/flags/"*; : > "$T/logs/ALERTS.log"; unset TRIAGE_STATE_BOARD_MAX_PAGES; }

# ═══ 1 — the open set, paged; no closed read; the ETag replay ═══════════════
reset; board "$OPEN131"
OUT=$(gate --seed)
grep -q '^SEEDED' <<<"$OUT" && ok || bad "(1) seed: '$OUT' err=$(head -3 "$T/err.txt")"
# 1a — every open issue, two open pages, no third
[ "$(nopen)" = 131 ] && ok || bad "(1a) expected 131 open, got $(nopen)"
grep -q 'state=open page=1 .*-> 200 100$' "$T/gh.txt" && grep -q 'state=open page=2 .*-> 200 31$' "$T/gh.txt" && ok \
  || bad "(1a) the open read pages: page 1 = 100 rows, page 2 = 31 rows: $(tr '\n' '|' < "$T/gh.txt")"
! grep -q 'state=open page=3' "$T/gh.txt" && ok || bad "(1a) a short page 2 ends the read (no page 3): $(tr '\n' '|' < "$T/gh.txt")"
! grep -q 'state=all' "$T/gh.txt" && ok || bad "(1a) the state=all read is gone: $(tr '\n' '|' < "$T/gh.txt")"
# 1b — no closed read, no closed row: the snapshot is the open set
[ "$(grep -c 'state=closed' "$T/gh.txt")" = 0 ] && ok || bad "(1b) no closed read: $(tr '\n' '|' < "$T/gh.txt")"
[ "$(nclosed)" = 0 ] && ok || bad "(1b) no closed issue is in the fingerprint: $(nclosed)"
[ "$(jq '[.issues[] | select(.number==200)] | length' "$FP" 2>/dev/null)" = 0 ] && ok || bad "(1b) closed #200 is not in the fingerprint"
[ "$(jq '.issues | length' "$FP" 2>/dev/null)" = 131 ] && ok || bad "(1b) 131 open rows and nothing else: $(jq '.issues | length' "$FP" 2>/dev/null)"
[ "$(jq -r '.meta | has("5") and has("1") and (has("200") | not)' "$FP" 2>/dev/null)" = true ] && ok || bad "(1b) the meta map covers the open rows only"
# 1c — a second run on the unchanged board: every page 304, same bytes
cp "$FP" "$T/fp.1"
OUT=$(gate --seed)
grep -q '^SEEDED' <<<"$OUT" && ok || bad "(1c) second seed: '$OUT'"
N304=$(grep -c -- '-> 304' "$T/gh.txt"); NISS=$(grep -c 'repos/o/r/issues ' "$T/gh.txt")
[ "$NISS" = 2 ] && [ "$N304" = 2 ] && ok || bad "(1c) both open pages answer 304 on an unchanged board: $(tr '\n' '|' < "$T/gh.txt")"
[ "$(grep 'repos/o/r/issues ' "$T/gh.txt" | grep -c 'inm=1')" = 2 ] && ok || bad "(1c) each page sent If-None-Match"
cmp -s "$FP" "$T/fp.1" && ok || bad "(1c) the fingerprint is byte-identical after a 304 run"

# ═══ 2 — the page cap: a knob, one ALERT a day ═════════════════════════════════
reset; board "$OPEN131"
export TRIAGE_STATE_BOARD_MAX_PAGES=1
OUT=$(gate --pending); rc=$?
[ "$rc" = 0 ] && ok || bad "(2a) a capped read still writes the fingerprint: rc=$rc"
[ "$(nopen "$T/state/$P.gate.pending")" = 100 ] && ok || bad "(2a) cap 1 page = 100 open rows: $(nopen "$T/state/$P.gate.pending")"
! grep -q 'state=open page=2' "$T/gh.txt" && ok || bad "(2a) no read past the cap"
[ "$(grep -c 'page cap' "$T/logs/ALERTS.log")" = 1 ] && grep 'page cap' "$T/logs/ALERTS.log" | grep -q "$P: .*100 open ai-build issues read" && ok \
  || bad "(2a) one ALERT line names the project and the 100 read: $(cat "$T/logs/ALERTS.log")"
grep 'page cap' "$T/logs/ALERTS.log" | grep -q "lib.triage-state.$P.triage_state_board_max_pages" && ok || bad "(2a) the ALERT names the settings row"
# 2b — the same day again: still one line
OUT=$(gate --pending)
[ "$(grep -c 'page cap' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "(2b) a second capped run the same day adds no line: $(cat "$T/logs/ALERTS.log")"
# 2c — the seed takes the board as it is and writes no ALERT
rm -f "$T/flags/"*; : > "$T/logs/ALERTS.log"
OUT=$(gate --seed)
[ "$(grep -c 'page cap' "$T/logs/ALERTS.log")" = 0 ] && ok || bad "(2c) --seed writes no cap ALERT: $(cat "$T/logs/ALERTS.log")"
# 2d — a cap the board fits under writes no ALERT (2 pages, 131 open)
rm -f "$T/flags/"*; : > "$T/logs/ALERTS.log"; export TRIAGE_STATE_BOARD_MAX_PAGES=2
OUT=$(gate --pending)
[ "$(nopen "$T/state/$P.gate.pending")" = 131 ] && [ "$(grep -c 'page cap' "$T/logs/ALERTS.log")" = 0 ] && ok \
  || bad "(2d) a short last page under the cap is no cap hit: $(nopen "$T/state/$P.gate.pending") $(cat "$T/logs/ALERTS.log")"
unset TRIAGE_STATE_BOARD_MAX_PAGES

# ═══ 3 — a closed blocker resolves CLOSED from refs.json, not the snapshot ═══════
reset; board "$OPEN131"; gate --seed >/dev/null
printf '[{"ticket_key":"5","verdict":"blocked","verdict_hash":"0123456789abcdef","reason":"DECISION skip: blocked by open #200"}]' > "$T/rows3.json"
jq -nc '{kind:"gh", doc:{issue:{number:5,title:"ticket 5",body:"Blocked-by: #200",state:"open",labels:[{name:"ai-build"}],
         assignees:[],milestone:null,comments:0,updated_at:"2026-10-20T10:00:00Z"},comments:[]}}' > "$T/wrap5.json"
H3=$(python3 "$DIR/bin/triage-state.py" hash --world "$FP" --key 5 --rows "$T/rows3.json" < "$T/wrap5.json" 2>/dev/null)
[ "$(jq -c '.absent_refs' <<<"$H3" 2>/dev/null)" = '["200"]' ] && ok \
  || bad "(3) #200 is not in the snapshot, so a REST ref lookup is owed: $H3"
printf '{"200":"CLOSED"}' > "$T/refs3.json"
H3R=$(python3 "$DIR/bin/triage-state.py" hash --world "$FP" --key 5 --rows "$T/rows3.json" --refs "$T/refs3.json" < "$T/wrap5.json" 2>/dev/null)
[ "$(jq -c '.reason_deps' <<<"$H3R" 2>/dev/null)" = '[["200","CLOSED"]]' ] && ok \
  || bad "(3) with refs.json #200 resolves CLOSED: $H3R"
[ "$(jq -r '.input_hash' <<<"$H3R")" != "$(jq -r '.input_hash' <<<"$H3")" ] && ok \
  || bad "(3) the blocker closing moves the input hash"
[ -z "$(python3 "$DIR/bin/triage-state.py" entries --world "$FP" 2>/dev/null | awk -F'\t' '$1==200')" ] && ok \
  || bad "(3) entries has no row for closed #200"

# ═══ 4 — ts_precheck counts the whole open set ══════════════════════════════════
# The pre-check runs from $HARNESS/bin: install its closure (and the python
# module bin/triage-state.py imports, which the shell scan does not follow).
for s in bin/lib/triage-state.sh bin/triage-state.py bin/triage-signal.py; do
  ( cd "$DIR" && scratch_install_closure "$s" "$T" ) >/dev/null || bad "(4) setup: cannot install $s"
done
( export HARNESS="$T" PATH="$T/fakebin:$PATH" TRIAGE_STATE_MODE=shadow TRIAGE_STATE_MAX_FETCH=0 LANE_GATE_DISABLE=1
  PROJECT=$P; LOG="$T/logs/$P.log"; : > "$LOG"; GATE_REASON=board-changed; SCOPE_N=full
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/triage-state.sh"
  ts_precheck >/dev/null 2>&1
  printf '%s' "${TS_SUMMARY:-}" > "$T/sum4" ) 2>/dev/null
case "$(cat "$T/sum4" 2>/dev/null) $(cat "$T/logs/$P.log" 2>/dev/null)" in *"131 open"*) ok ;; *) bad "(4) ts_precheck counts 131 open: [$(cat "$T/sum4" 2>/dev/null)] $(tail -2 "$T/logs/$P.log" 2>/dev/null)" ;; esac

# ═══ 5 — the stop rule ═══════════════════════════════════════════════════════════
# 5a — 0 open: one open read ([]), an empty open set is a real board
reset; board '[]'
OUT=$(gate --seed)
grep -q '^SEEDED' <<<"$OUT" && [ "$(nopen)" = 0 ] && [ "$(grep -c 'state=open' "$T/gh.txt")" = 1 ] && ok \
  || bad "(5a) 0 open: seeded, 0 open, one open read: '$OUT' $(tr '\n' '|' < "$T/gh.txt")"
# 5b — 31 open: one page
reset; board "$(jq -nc '[range(1;32)]')"
OUT=$(gate --seed)
[ "$(nopen)" = 31 ] && [ "$(grep -c 'state=open' "$T/gh.txt")" = 1 ] && ok || bad "(5b) 31 open on one page: $(nopen) $(tr '\n' '|' < "$T/gh.txt")"
# 5c — exactly 100 open: page 2 is read and answers []
reset; board "$(jq -nc '[range(1;101)]')"
OUT=$(gate --seed)
[ "$(nopen)" = 100 ] && grep -q 'state=open page=2 .*-> 200 0$' "$T/gh.txt" && ! grep -q 'state=open page=3' "$T/gh.txt" && ok \
  || bad "(5c) 100 open: page 2 read, empty, stop: $(nopen) $(tr '\n' '|' < "$T/gh.txt")"
# 5c — the knob unset reads up to 20 pages (a 2100-row open read stops at 20)
reset
jq -nc '[range(2100; 0; -1) as $n | {number: $n, state: "open", title: "t", comments: 0, updated_at: "2026-10-20T10:00:00Z",
        body: "b", labels: [], assignees: [], milestone: null}]' > "$T/fx/all.json"
OUT=$(gate --pending)
[ "$(grep -c 'state=open' "$T/gh.txt")" = 20 ] && [ "$(nopen "$T/state/$P.gate.pending")" = 2000 ] && ok \
  || bad "(5c) knob unset: 20 pages, 2000 open: $(grep -c 'state=open' "$T/gh.txt") pages, $(nopen "$T/state/$P.gate.pending") open"
[ "$(grep -c 'page cap (20 pages, 2000 open' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "(5c) the default cap hit ALERTs: $(cat "$T/logs/ALERTS.log")"
# 5d — a 2xx page that is not an array: no fingerprint, RUN gate-fetch-failed
reset; board "$OPEN131"; gate --seed >/dev/null; cp "$FP" "$T/fp.5d"
touch "$T/fx/junk-open"
date +%s > "$T/state/$P.gate-meta"
OUT=$(gate)
grep -q '^RUN gate-fetch-failed' <<<"$OUT" && ok || bad "(5d) a non-array open page is a failed fetch: '$OUT'"
cmp -s "$FP" "$T/fp.5d" && [ ! -e "$T/state/$P.gate.pending" ] && ok || bad "(5d) nothing is written from a bad page"
OUT=$(gate --pending); rc=$?
[ "$rc" != 0 ] && ok || bad "(5d) --pending exits non-zero on a bad page: rc=$rc"

# ═══ 6 — no closed read; a failed open page fails the fetch ═════════════════════
reset; board "$OPEN131"; gate --seed >/dev/null
touch "$T/fx/fail-closed"; date +%s > "$T/state/$P.gate-meta"
OUT=$(gate)
! grep -q '^RUN gate-fetch-failed' <<<"$OUT" && ! grep -q 'state=closed' "$T/gh.txt" && ok \
  || bad "(6) a dead closed endpoint is never read and fails nothing: '$OUT' $(tr '\n' '|' < "$T/gh.txt")"
# 6b — a failed open page 2 too (never half a board)
rm -f "$T/fx/fail-closed"
# page 1 answers, page 2 fails: the lib itself, with a gh() that fails page 2
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" GH_ETAG=0
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/triage-board-pages.sh" || exit 3
  gh() { if [ "$*" != "${*/page=2/}" ]; then printf 'HTTP/2.0 500\r\n\r\n{"message":"boom"}\n'; return 1; fi; command gh "$@"; }
  tbp_issue_pages o/r 20 "$T/out6b.json"; echo "rc=$?" > "$T/rc6b" ) 2>/dev/null
case "$(cat "$T/rc6b" 2>/dev/null)" in rc=0|'') bad "(6b) a failed page 2 fails the whole read: [$(cat "$T/rc6b" 2>/dev/null)]" ;; *) ok ;; esac
[ ! -s "$T/out6b.json" ] && ok || bad "(6b) no partial list is written: $(head -c 80 "$T/out6b.json" 2>/dev/null)"

# ═══ 7 — the comment's fixture: old tickets with the newest comments ═════════════
# 131 open, created #1..#131; the 20 OLDEST-created (#1..#20) have the NEWEST
# comments and updated_at. GitHub's default sort is created desc, so on the
# old one-page read #1..#31 were never on page 1, whatever their comments.
reset
jq -nc '[range(131; 0; -1) as $n
  | {number: $n, state: "open", title: "ticket \($n)",
     comments: (if $n <= 20 then 3 else 1 end),
     updated_at: (if $n <= 20 then "2026-10-26T20:00:\($n + 10)Z" else "2026-10-01T10:00:00Z" end),
     body: "body \($n)", labels: [{name: "ai-build"}], assignees: [], milestone: null}]' > "$T/fx/all.json"
for tick in 1 2; do
  OUT=$(gate --pending); rc=$?
  PEND="$T/state/$P.gate.pending"
  [ "$rc" = 0 ] && [ "$(nopen "$PEND")" = 131 ] && ok || bad "(7) tick $tick: all 131 open are in the snapshot: rc=$rc $(nopen "$PEND")"
  [ "$(jq '[.issues[] | select(.number <= 20 and .comments == 3)] | length' "$PEND" 2>/dev/null)" = 20 ] && ok \
    || bad "(7) tick $tick: the 20 oldest-created, newest-commented tickets are in the snapshot"
done

echo "triage-board-pages: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
