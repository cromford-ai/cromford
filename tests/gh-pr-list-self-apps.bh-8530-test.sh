#!/bin/bash
# tests/gh-pr-list-self-apps.bh-8530-test.sh — the PR author set derives from
# HARNESS_SELF_APPS, and an UNKNOWN-AUTHOR streak becomes one warn beat.
#
# THE INCIDENT (BH-8530, 2026-10-27). The board App, cromford-board, opens
# PRs on some projects (project-6-desktop #6, author `cromford-board[bot]`).
# The default author set in bin/lib/gh-pr-list.sh was a second copy of the trust
# list and did not name that App, so the REST filter dropped the PR and
# merge-conductor logged `prs=0` for project-6-desktop. HARNESS_SELF_APPS
# (catalog/lanes.d/_lib.harness-self.json) already listed the App.
#
# What this pins:
#   A1  the default set carries app/cromford-board in every spelling
#   A2  a REST open list keeps a cromford-board[bot] ticket/* PR, logs no
#       UNKNOWN-AUTHOR for it, and drops the near miss
#   A3  the code fallback slug set == the registry default of HARNESS_SELF_APPS
#   A4  an exported HARNESS_SELF_APPS is normalized and unioned, no duplicates
#   A5  an explicit HARNESS_PR_AUTHORS still wins exactly
#   A6  near misses and the empty login do not match
#   A7  the verdict set is not widened
#   S1-S6  the UNKNOWN-AUTHOR streak ledger row (kind pr_author_unknown), its
#          one warn beat, the no-op read, isolation, the knob, fail-open
#   S7  the knob GH_PR_LIST_UNKNOWN_STREAK_DAYS is registered, default 2
# Run from anywhere: tests/gh-pr-list-self-apps.bh-8530-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamps below are read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/h/flags" "$T/h/bin" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
date -u -d yesterday +%Y%m%d >/dev/null 2>&1 || { echo "GNU date missing — skipping"; exit 0; }
TODAY=$(date -u +%Y%m%d)
DAGO() { date -u -d "$TODAY -$1 day" +%Y%m%d; }

# beat stub: records every beat the lib sends.
cat > "$T/h/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEATS"
SH
chmod +x "$T/h/bin/beat.sh"
# alert-line stub: the one sanctioned ALERTS.log writer, recorded verbatim.
cat > "$T/h/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$T/h/bin/alert-line.sh"

# jobs-client stub: the two ledger helpers the lib calls, backed by one file per
# key under $LEDGER (the row's detail). $LEDGER/.down = an outage (rc 1), and
# every put is counted in $LEDGER/.puts.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
#!/bin/bash
_lk() { printf '%s/%s__%s' "$LEDGER" "$1" "$(printf '%s' "$2" | tr '/' '_')"; }
job_ledger_row() {
  [ -e "$LEDGER/.down" ] && return 1
  local f; f=$(_lk "$1" "$2"); [ -f "$f" ] || return 2
  jq -nc --arg d "$(cat "$f")" '{status:"streak",detail:$d}'
}
job_ledger_put() {
  [ -e "$LEDGER/.down" ] && return 1
  [ "$3" = streak ] || return 1
  printf '%s %s\n' "$1" "$2" >> "$LEDGER/.puts"
  printf '%s' "$4" > "$(_lk "$1" "$2")"
}
SH
chmod +x "$T/h/bin/jobs-client.sh"
mkdir -p "$T/ledger"

# gh shim (REST only). FIXTURE rows:
#   o/mkd     #6 cromford-board[bot] ticket/TK-1.1, #7 cromford-boardx[bot]
#             ticket/x (near miss), #8 operator ticket/y
#   o/strange #21 operator ticket/a, #22 other-app[bot] ticket/b
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
[ "$1" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
repo="${P%%/pulls*}"; repo="${repo#repos/}"
row() { # row <num> <login> <ref>
  jq -nc --argjson n "$1" --arg l "$2" --arg r "$3" --arg repo "$repo" '{
    number: $n, html_url: "https://github.com/\($repo)/pull/\($n)", title: "FIXTURE \($n)",
    head: {sha: "s\($n)", ref: $r, repo: {full_name: $repo}}, base: {ref: "main", repo: {full_name: $repo}},
    draft: false, user: {login: $l, type: "Bot"},
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
    merged_at: null, closed_at: null, state: "open", labels: []}'
}
case "$repo" in
  o/mkd)     R=$(row 6 'cromford-board[bot]' ticket/TK-1.1; row 7 'cromford-boardx[bot]' ticket/x; row 8 operator ticket/y) ;;
  o/strange) R=$(row 21 operator ticket/a; row 22 'other-app[bot]' ticket/b) ;;
  *) printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n'
printf '%s\n' "$R" | jq -sc .
GH
chmod +x "$T/fakebin/gh"

drive() { # drive <bash snippet>; the lib sourced fresh with HARNESS=$T/h
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BEATS="$T/beats.txt" LEDGER="$T/ledger"
    unset HARNESS_PR_AUTHORS HARNESS_SELF_APPS HARNESS_VERDICT_AUTHORS GH_PR_LIST_REST_PAGES
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-pr-list.sh"; eval "$1" )
}
F=number,url,headRefName,author

# A1 — the board App is in the default set, in every spelling
case " $(drive 'harness_pr_authors') " in *" app/cromford-board "*) ok ;; *) bad "A1 default set lacks app/cromford-board: $(drive 'harness_pr_authors')" ;; esac
drive 'harness_pr_author_match "cromford-board[bot]"' && ok || bad "A1 REST spelling cromford-board[bot] must match"
drive 'harness_pr_author_match "app/cromford-board"' && ok || bad "A1 GraphQL spelling app/cromford-board must match"
# the env -i shape of the reproduction: no HARNESS_SELF_APPS, an empty harness
( env -i PATH="$PATH" HARNESS="$T/empty" bash -c ". '$DIR/bin/lib/gh-pr-list.sh'; harness_pr_author_match 'cromford-board[bot]'" ) \
  && ok || bad "A1 env -i: cromford-board[bot] must match with no environment"

# A2 — the REST open list keeps #6 (the incident: it did not) and drops #7
: > "$T/beats.txt"
OUT=$(drive "harness_pr_list o/mkd open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[6,8]" ] \
  && ok || bad "A2 open list should be [6,8] (board App #6 in, near miss #7 out): rc=$RC $OUT"
grep -q "#6 " <<<"$(grep "UNKNOWN-AUTHOR" "$T/h/logs/gh-pr-list.log" 2>/dev/null)" \
  && bad "A2 UNKNOWN-AUTHOR logged for #6: $(grep UNKNOWN-AUTHOR "$T/h/logs/gh-pr-list.log")" || ok
grep -q "#6 " "$T/beats.txt" 2>/dev/null && bad "A2 a beat names #6: $(cat "$T/beats.txt")" || ok
grep -q "#7 cromford-boardx" <<<"$(grep "UNKNOWN-AUTHOR" "$T/h/logs/gh-pr-list.log" 2>/dev/null)" \
  && ok || bad "A2 the near miss #7 must still be reported as UNKNOWN-AUTHOR"

# A3 — the code fallback is the registry default, as a set (sourced value, not source text)
REG=$(jq -r '.libs[]|select(.id=="harness-self")|.knobs[]|select(.env=="HARNESS_SELF_APPS")|.default' "$DIR/catalog/lanes.d/_lib.harness-self.json")
FB=$(drive 'printf %s "${_HPL_SELF_APPS_FALLBACK:-}"')
[ -n "$REG" ] && [ -n "$FB" ] && [ "$(tr ' ' '\n' <<<"$REG" | sort -u)" = "$(tr ' ' '\n' <<<"$FB" | sort -u)" ] \
  && ok || bad "A3 fallback slugs '$FB' != registry HARNESS_SELF_APPS default '$REG'"
for s in $REG; do
  case " $(drive 'printf %s "$HARNESS_PR_AUTHORS_DEFAULT"') " in *" app/$s "*) ok ;; *) bad "A3 default lacks app/$s" ;; esac
done

# A4 — an exported HARNESS_SELF_APPS is normalized, unioned, deduped, login first
GOT=$(drive 'HARNESS_OPERATOR_LOGIN=operator HARNESS_SELF_APPS="cromford Extra-App[bot] app/third cromford" bash -c ". \"$DIR/bin/lib/gh-pr-list.sh\"; harness_pr_authors"')
[ "$GOT" = "operator app/cromford app/extra-app app/third" ] \
  && ok || bad "A4 HARNESS_SELF_APPS derivation: '$GOT'"

# A5 — an explicit HARNESS_PR_AUTHORS wins exactly
drive 'HARNESS_PR_AUTHORS="operator app/cromford" harness_pr_author_match "cromford-board[bot]"' \
  && bad "A5 an explicit HARNESS_PR_AUTHORS that omits the board App must not match it" || ok

# A6 — near misses and the empty login
for l in 'cromford-boardx[bot]' 'cromford-boar[bot]' 'other-app[bot]' 'mergify[bot]' ''; do
  drive "harness_pr_author_match '$l'" && bad "A6 '$l' must not match" || ok
done

# A7 — listing is not verdict trust
drive 'harness_verdict_author_match "cromford-board[bot]"' && bad "A7 the board App must NOT be a verdict author" || ok

# ---- S: the UNKNOWN-AUTHOR streak (one ledger row per PR) ------------------
SF="$T/ledger/pr_author_unknown__o_strange#22"
row() { cat "$SF" 2>/dev/null; }
puts() { grep -c . "$T/ledger/.puts" 2>/dev/null || echo 0; }
streak_beats() { jq -c 'select(.akey=="prauthorunknown-streak:o/strange#22")' "$T/beats.txt" 2>/dev/null | grep -c .; }
reset_s() { scratch_rm "$T/ledger"; mkdir -p "$T/ledger"; scratch_rm "$T/h/flags"; mkdir -p "$T/h/flags"; : > "$T/beats.txt"; : > "$T/h/logs/ALERTS.log"; }

# S1 — day 1: no row -> today today 0, no warn, no streak dir under state/
reset_s
OUT=$(drive "harness_pr_list o/strange open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21]" ] && ok || bad "S1 list: rc=$RC $OUT"
[ "$(row)" = "$TODAY $TODAY 0" ] && ok || bad "S1 row: '$(row)'"
[ "$(streak_beats)" = 0 ] && ok || bad "S1 a day-1 streak warned"
[ ! -e "$T/h/state/pr-author-unknown" ] && ok || bad "S1 the streak wrote under state/: $(find "$T/h/state/pr-author-unknown" 2>/dev/null)"

# S2 — day 2: yesterday yesterday 0 -> yesterday today 0, no warn
reset_s; printf '%s %s 0' "$(DAGO 1)" "$(DAGO 1)" > "$SF"
drive "harness_pr_list o/strange open $F 100" >/dev/null
[ "$(row)" = "$(DAGO 1) $TODAY 0" ] && ok || bad "S2 row: '$(row)'"
[ "$(streak_beats)" = 0 ] && ok || bad "S2 a day-2 streak warned"

# S3 — day 3: today-2 yesterday 0 -> one warn beat, one ALERTS line, warned=1
reset_s; printf '%s %s 0' "$(DAGO 2)" "$(DAGO 1)" > "$SF"
OUT=$(drive "harness_pr_list o/strange open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21]" ] && ok || bad "S3 list: rc=$RC $OUT"
[ "$(streak_beats)" = 1 ] && ok || bad "S3 expected one streak beat: $(cat "$T/beats.txt")"
jq -e 'select(.akey=="prauthorunknown-streak:o/strange#22") | .kind=="fleet_alert" and .severity=="warn" and .project=="fleet"
       and (.line|test("#22")) and (.line|test("other-app\\[bot\\]")) and (.line|test("\\b3 consecutive days"))' "$T/beats.txt" >/dev/null 2>&1 \
  && ok || bad "S3 beat shape: $(cat "$T/beats.txt")"
[ "$(grep -c 'consecutive days' "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "S3 ALERTS streak lines: $(cat "$T/h/logs/ALERTS.log")"
[ "$(row)" = "$(DAGO 2) $TODAY 1" ] && ok || bad "S3 row: '$(row)'"

# S4 — a second read the same day: still exactly one streak beat, and no write
P0=$(puts)
drive "harness_pr_list o/strange open $F 100" >/dev/null
[ "$(streak_beats)" = 1 ] && ok || bad "S4 a second read warned again: $(streak_beats)"
[ "$(grep -c 'consecutive days' "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "S4 a second ALERTS streak line"
[ "$(puts)" = "$P0" ] && ok || bad "S4 a same-day read that changes nothing wrote the row ($P0 -> $(puts))"

# S5 — a gap resets; another PR's row is not touched
reset_s; printf '%s %s 1' "$(DAGO 5)" "$(DAGO 3)" > "$SF"
printf '%s %s 0' "$(DAGO 4)" "$(DAGO 3)" > "$T/ledger/pr_author_unknown__o_other#99"
drive "harness_pr_list o/strange open $F 100" >/dev/null
[ "$(row)" = "$TODAY $TODAY 0" ] && ok || bad "S5 gap must reset: '$(row)'"
[ "$(streak_beats)" = 0 ] && ok || bad "S5 a reset streak warned"
[ "$(cat "$T/ledger/pr_author_unknown__o_other#99")" = "$(DAGO 4) $(DAGO 3) 0" ] && ok || bad "S5 another PR's row was changed"
[ "$(grep -c 'o_other\|o/other' "$T/ledger/.puts")" = 0 ] && ok || bad "S5 a put named another PR: $(cat "$T/ledger/.puts")"

# S6 — knob 0 never warns; knob 5 at day 3 does not; unparseable resets; an outage is harmless
reset_s; printf '%s %s 0' "$(DAGO 2)" "$(DAGO 1)" > "$SF"
drive "GH_PR_LIST_UNKNOWN_STREAK_DAYS=0 harness_pr_list o/strange open $F 100" >/dev/null
[ "$(streak_beats)" = 0 ] && ok || bad "S6 knob 0 warned"
reset_s; printf '%s %s 0' "$(DAGO 2)" "$(DAGO 1)" > "$SF"
drive "GH_PR_LIST_UNKNOWN_STREAK_DAYS=5 harness_pr_list o/strange open $F 100" >/dev/null
[ "$(streak_beats)" = 0 ] && ok || bad "S6 knob 5 warned at day 3"
reset_s; printf 'garbage' > "$SF"
drive "harness_pr_list o/strange open $F 100" >/dev/null
[ "$(row)" = "$TODAY $TODAY 0" ] && ok || bad "S6 unparseable must reset: '$(row)'"
[ "$(streak_beats)" = 0 ] && ok || bad "S6 unparseable warned"
reset_s; printf '%s %s 0' "$(DAGO 2)" "$(DAGO 1)" > "$SF"; : > "$T/ledger/.down"   # the jobs worker is down
OUT=$(drive "harness_pr_list o/strange open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21]" ] && ok || bad "S6 an outage changed the list: rc=$RC $OUT"
[ "$(streak_beats)" = 0 ] && ok || bad "S6 an outage warned"
grep -q "unknown-author streak: ledger read failed for o/strange#22" "$T/h/logs/gh-pr-list.log" && ok || bad "S6 an outage must log the skipped streak"
rm -f "$T/ledger/.down"
# no jobs client at all: the streak is skipped and logged, the list is the same
mv "$T/h/bin/jobs-client.sh" "$T/jc.off"; reset_s
OUT=$(drive "harness_pr_list o/strange open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21]" ] && ok || bad "S6 no jobs client changed the list: rc=$RC $OUT"
[ ! -e "$SF" ] && [ "$(streak_beats)" = 0 ] && ok || bad "S6 no jobs client still wrote or warned"
mv "$T/jc.off" "$T/h/bin/jobs-client.sh"

# S7 — the knob is registered on lib gh-pr-list, default 2 (a knob fragment, BH-4987)
jq -e '.env=="GH_PR_LIST_UNKNOWN_STREAK_DAYS" and .default==2 and .type=="int" and .min==0' \
  "$DIR/catalog/lanes.d/_lib.gh-pr-list.knobs.d/GH_PR_LIST_UNKNOWN_STREAK_DAYS.json" >/dev/null \
  && ok || bad "S7 GH_PR_LIST_UNKNOWN_STREAK_DAYS must be registered in catalog/lanes.d/_lib.gh-pr-list.knobs.d/, default 2"

[ "$(date -u +%Y%m%d)" = "$TODAY" ] || { echo "SKIP: the UTC date changed during the run ($TODAY -> $(date -u +%Y%m%d)); the S cases are not valid"; exit 0; }
echo "gh-pr-list-self-apps: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
