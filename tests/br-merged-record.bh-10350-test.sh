#!/bin/bash
# tests/br-merged-record.bh-10350-test.sh — BH-10350: the resolver's merged-PR
# lookup (br_merged_prs_for) answers from the PR record, through prr_read
# blocked-resolver and the lane's step GH_SOURCE (settings row
# lane.blocked-resolver.gh_source). A record miss runs today's two searches.
#
#   L1-L3   pr_record_list's optional 7th arg [since-iso]
#   R1-R12  brs_merged_record: the decision rule table of the plan, and the
#           miss words (plus a row of another repo: malformed)
#   D1      record, a fresh record holds merged #41 on ticket/bh-23: 0 GitHub
#           calls, the same TSV as step off, and the real br_already_merged
#           resolves on it
#   D2      shadow: the record lacks #41. GitHub calls as step off, the lane
#           output is GitHub's, exactly 1 PRR_SHADOW ...@merged line
#   D3      off: 0 /api/pr-records GETs, 2 searches + 1 pulls read
#   D4      record, a stale stamp: 1 PRR_MISS why=stale fallback=github, the
#           GitHub calls of D3
#   D5      record, each of no-sync unreadable truncated field:merged_at
#           no-since: the GitHub calls of D3
#   D6      no GH_SOURCE: step shadow
#   D7      record miss and the search answers 403: rc 75, br_already_merged
#           rc 2, no new file under state/
#   D8      BR_OPT_OFF=bh-10350-merged-record: today's calls, 0 record GETs
#   W1-W3   the reason line per step (step-off, step-shadow, record-miss:stale)
#   K1-K7   the retention window: a park older than the record's window
#           (settings rows retention.pr_records.closed_days / .days, fallback
#           14 / 90, minus 1 day) misses too-old and searches; a park inside it
#           is answered by the record; the window comes from the rows
#   P1-P2   the `# >>> stall alerts` block of bin/pipeline-health.sh writes one
#           reason line per tick for its HOLD searches, and none with no search
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, its modules and fragments,
# lifted up to DONE_KEYS= (the tests/blocked-resolver.bh-1900-test.sh rig), in
# a scratch $HARNESS. No vendor is called (BH-7563): gh_rest is a local stub
# that logs each path and answers from fixture files, the jobs worker is a stub
# _jobs_req, and a fake `gh` on PATH logs any call that slips past them.
#
# determinism: ok-file the stamps below are fixed fixture DATA; this suite
# reads no clock and rolls no dice.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/br-merged-record.bh-10350-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The files under test, named by rooted path so the orphan check sees them.
FRAG="$DIR/bin/blocked-resolver.d/bh-10350-merged-record.sh"
SEAMF="$DIR/bin/lib/prr-shadow.d/blocked-resolver.sh"
PH="$DIR/bin/pipeline-health.sh"

H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/tmp" "$T/fakebin"
cp -r "$DIR/bin" "$H/" || exit 1
: > "$H/env/global.env"
printf 'p1 o/r - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"

# PARK = 2026-11-25T00:00:00Z. Every "after the park" stamp is 2026-11-26.
PARK=1795564800
PARK_ISO=2026-11-25T00:00:00Z
# NOW = PARK + 1.5 days, the fixture clock (PR_RECORD_NOW) of every case.
NOW=1795694400
DAY=86400
mkdir -p "$T/settings"
GHROW=$'https://github.com/o/r/pull/41\t2026-11-26T10:00:00Z\tticket/bh-23'

# THE JOBS STUB. GET /api/pr-records?...state=merged answers $T/rec.json
# (absent = a failed read). Every request is one line in $T/jobs.txt.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
# setting_get: $T/settings/<key> is the row (rc 0), $T/settings-down is an
# outage (rc 1), else no row (rc 2).
setting_get() {
  [ -e "$T/settings-down" ] && return 1
  [ -f "$T/settings/\$1" ] || return 2
  cat "$T/settings/\$1"
}
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  case "\$1 \$2" in
    "GET /api/pr-records?"*"state=merged"*) [ -f "$T/rec.json" ] && cat "$T/rec.json" && return 0; return 1 ;;
  esac
  return 1
}
EOF
# A real gh must never run: log it and answer nothing.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/realgh.txt"
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# THE gh_rest STUB, defined after the lift (it replaces gh-rest.sh's and the
# readmemo wrapper). search/issues answers $T/gh-search.json; pulls/<n>
# answers $T/gh-pull-<n>.json. $T/gh-403 makes every call a 403.
cat > "$T/stubs.sh" <<EOF
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/gh.txt"
  GH_REST_STATUS=200; GH_REST_REASON=
  [ -e "$T/gh-403" ] && { GH_REST_STATUS=403; return 1; }
  case "\$2" in
    search/issues) cat "$T/gh-search.json" ;;
    repos/*/pulls/*) [ -f "$T/gh-pull-\${2##*/}.json" ] || { GH_REST_STATUS=404; return 44; }
                     cat "$T/gh-pull-\${2##*/}.json" ;;
    *) GH_REST_STATUS=500; return 1 ;;
  esac
}
say() { printf '%s\n' "\$*" >> "$T/say.log"; }
br_cap_key() { echo p1-K-1; }
br_load() { echo '{}'; }
br_park_time() { echo $PARK; }
br_resolve_ticket_merged() { echo "RESOLVED \$5"; }
EOF
printf '{"items":[{"html_url":"https://github.com/o/r/pull/41"}]}\n' > "$T/gh-search.json"
printf '{"merged_at":"2026-11-26T10:00:00Z","head":{"ref":"ticket/bh-23"},"title":"BH-23: thing"}\n' > "$T/gh-pull-41.json"

awk '/^DONE_KEYS=/{exit} {print}' "$H/bin/blocked-resolver.sh" > "$T/br-lib.sh"
[ -s "$T/br-lib.sh" ] || { echo "FAIL: could not lift the resolver's functions"; exit 1; }

# row <n> <head_ref> <title> <merged_at|null> — one record row (JSON).
row() {
  jq -nc --argjson n "$1" --arg h "$2" --arg t "$3" --arg m "$4" \
    '{number:$n, head_ref:$h, title:$t, merged_at:(if $m == "null" then null else $m end),
      url:("https://github.com/o/r/pull/" + ($n|tostring))}'
}
# rec [jq-edit] <row-json>... — the record's merged list since the park, fresh.
rec() {
  local ed="."; case "${1:-}" in jq:*) ed="${1#jq:}"; shift ;; esac
  printf '%s\n' "$@" | jq -s --argjson x 0 '{rows: ., truncated: false, sync: {age_s: 60, synced_at: "2026-11-26T12:00:00Z"}, missing: null, unknown: 0}' \
    | jq -c "$ed" > "$T/rec.json"
}
REC41() { rec "$(row 41 ticket/bh-23 'BH-23: thing' 2026-11-26T10:00:00Z)"; }

# SEAM <snippet> — the seam and pr-record.sh, loaded the way prr_seam_load
# loads them, with the jobs stub. stdout in $OUT, rc in $RC.
SEAM() {
  : > "$T/jobs.txt"
  OUT=$(cd "$T" && env -u GH_SOURCE -u GH_SOURCE_LANE HARNESS="$H" TMPDIR="$T/tmp" T="$T" PR_RECORD_LIST_MAX_AGE_S=3900 PR_RECORD_NOW="${SEAM_NOW:-$NOW}" bash -c '
      . "$HARNESS/bin/jobs-client.sh"
      . "$HARNESS/bin/lib/prr-shadow.sh" || exit 3
      prr_seam_load blocked-resolver || { echo noseam; exit 4; }
      '"$1" 2>"$T/seam.err"); RC=$?
}
# BR <snippet> [VAR=val...] — the lifted resolver, then the stubs. stdout in
# $OUT, rc in $RC; calls in $T/gh.txt and $T/jobs.txt; lane lines in $T/say.log.
BR() {
  local code="$1"; shift
  : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/say.log"; rm -f "$H/logs/prr-shadow.log"
  OUT=$(cd "$T" && env -u GH_SOURCE -u GH_SOURCE_LANE -u BR_OPT_OFF HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      TMPDIR="$T/tmp" T="$T" BRLIB="$T/br-lib.sh" GH_TOKEN="" PR_RECORD_LIST_MAX_AGE_S=3900 PR_RECORD_NOW="$NOW" "$@" bash -c '
      set --; . "$BRLIB" >/dev/null 2>&1; . "$T/stubs.sh"
      '"$code" 2>"$T/br.err"); RC=$?
}
NSEARCH() { grep -c ' search/issues$' "$T/gh.txt"; }
NPULLS()  { grep -c ' repos/o/r/pulls/' "$T/gh.txt"; }
NREC()    { grep -c '/api/pr-records' "$T/jobs.txt"; }
NREASON() { grep -c 'reason=' "$T/say.log"; }

[ -f "$FRAG" ] && ok || bad "0: $FRAG must exist"

# ============================================================================
# L1-L3 pr_record_list [since-iso]
# ============================================================================
REC41
SEAM 'pr_record_list o/r merged "$T/l.json" head_ref,merged_at,url,title "" "" 2026-11-20T00:00:00Z; echo "rc=$?"'
{ grep -qx 'rc=0' <<<"$OUT" && grep -q '^GET /api/pr-records?repo=o/r&state=merged&need=head_ref,merged_at,url,title&since=2026-11-20T00:00:00Z$' "$T/jobs.txt"; } \
  && ok || bad "L1: the GET must carry &since=2026-11-20T00:00:00Z (out=$OUT jobs=$(cat "$T/jobs.txt"))"
SEAM 'pr_record_list o/r merged "$T/l.json" head_ref "" "" 2026-11-20; echo "rc=$?"'
{ grep -qx 'rc=2' <<<"$OUT" && [ "$(NREC)" = 0 ]; } && ok || bad "L2: a bad since must be rc 2 with no GET (out=$OUT jobs=$(cat "$T/jobs.txt"))"
SEAM 'pr_record_list o/r merged "$T/l.json" head_ref; echo "rc=$?"'
{ grep -qx 'rc=0' <<<"$OUT" && grep -q '^GET /api/pr-records?repo=o/r&state=merged&need=head_ref$' "$T/jobs.txt"; } \
  && ok || bad "L3: no since must send today's query (jobs=$(cat "$T/jobs.txt"))"

# ============================================================================
# R1-R12 brs_merged_record <file> <slug> <tkey> <since>: the decision rule.
# ============================================================================
# match <n> <head_ref> <title> <merged_at> — R-case: is PR <n> in the answer?
MREC() { SEAM 'brs_merged_record "$T/m.tsv" o/r BH-23 '"$PARK"'; echo "rc=$?"; cat "$T/m.tsv"'; }
match_case() { # match_case <id> <yes|no> <head_ref> <title> <merged_at>
  rec "$(row 77 "$3" "$4" "$5")"; MREC
  if [ "$2" = yes ]; then
    { grep -qx 'rc=0' <<<"$OUT" && grep -q "^https://github.com/o/r/pull/77	$5	$3\$" <<<"$OUT"; } \
      && ok || bad "$1: $3 / '$4' / $5 must match BH-23 (out=$OUT err=$(cat "$T/seam.err"))"
  else
    { grep -qx 'rc=0' <<<"$OUT" && ! grep -q 'pull/77' <<<"$OUT"; } \
      && ok || bad "$1: $3 / '$4' / $5 must NOT match BH-23 (out=$OUT)"
  fi
}
match_case R1  yes ticket/bh-23     anything            2026-11-26T10:00:00Z
match_case R2  yes ticket/bh-23-r2  anything            2026-11-26T10:00:00Z
match_case R3  yes ticket/bh-23-r61 anything            2026-11-26T10:00:00Z
match_case R4  yes mac/bh-23        anything            2026-11-26T10:00:00Z
match_case R5  yes fix/other        'BH-23: fix x'      2026-11-26T10:00:00Z
match_case R6  no  ticket/bh-234    'BH-234: y'         2026-11-26T10:00:00Z
match_case R7  no  ticket/bh-2      'BH-2: z'           2026-11-26T10:00:00Z
match_case R8  no  fix/other        'XBH-23 and BH-230' 2026-11-26T10:00:00Z
match_case R9  no  ticket/bh-23     anything            2026-11-24T10:00:00Z
match_case R10 no  mac/bh-23x       notes               2026-11-26T10:00:00Z
match_case R4b yes mac/bh-23-r3     anything            2026-11-26T10:00:00Z
# R11 a null merged_at (the worker names it in .missing): miss field:merged_at.
rec jq:'.missing = "merged_at"' "$(row 77 ticket/bh-23 anything null)"; MREC
{ grep -qx 'rc=1' <<<"$OUT" && grep -qx 'field:merged_at' <<<"$OUT"; } && ok || bad "R11: a null merged_at must miss field:merged_at (out=$OUT)"
rec "$(row 77 ticket/bh-23 anything null)"; MREC
{ grep -qx 'rc=1' <<<"$OUT" && grep -qx 'field:merged_at' <<<"$OUT"; } && ok || bad "R11b: a null merged_at the worker did not name must still miss (out=$OUT)"
# R12 more rows than the page since the park: miss truncated.
rec jq:'.truncated = true' "$(row 77 ticket/bh-23 anything 2026-11-26T10:00:00Z)"; MREC
{ grep -qx 'rc=1' <<<"$OUT" && grep -qx 'truncated' <<<"$OUT"; } && ok || bad "R12: a cut page must miss truncated (out=$OUT)"
# The other miss words.
rec jq:'.sync.age_s = 99999' "$(row 77 ticket/bh-23 anything 2026-11-26T10:00:00Z)"; MREC
grep -qx 'stale' <<<"$OUT" && ok || bad "R13: an old stamp must miss stale (out=$OUT)"
rec jq:'.sync = null' "$(row 77 ticket/bh-23 anything 2026-11-26T10:00:00Z)"; MREC
grep -qx 'no-sync' <<<"$OUT" && ok || bad "R14: no stamp must miss no-sync (out=$OUT)"
rm -f "$T/rec.json"; MREC
grep -qx 'unreadable' <<<"$OUT" && ok || bad "R15: a failed jobs read must miss unreadable (out=$OUT)"
REC41
SEAM 'brs_merged_record "$T/m.tsv" o/r BH-23 ""; echo "rc=$?"'
{ grep -qx 'no-since' <<<"$OUT" && [ "$(NREC)" = 0 ]; } && ok || bad "R16: no park time must miss no-since with no GET (out=$OUT)"
SEAM 'brs_merged_record "$T/m.tsv" o/r "BH 23" '"$PARK"'; echo "rc=$?"'
grep -qx 'unknown' <<<"$OUT" && ok || bad "R17: a bad key must miss unknown (out=$OUT)"
# A row whose url is another repo's: malformed, never a match.
rec "$(row 77 ticket/bh-23 anything 2026-11-26T10:00:00Z | jq -c '.url = "https://github.com/evil/r/pull/77"')"; MREC
{ grep -qx 'rc=1' <<<"$OUT" && grep -qx 'malformed' <<<"$OUT"; } && ok || bad "R18: a row of another repo must miss malformed (out=$OUT)"
# The GET is the since-bounded merged list.
REC41; MREC
grep -q "^GET /api/pr-records?repo=o/r&state=merged&need=head_ref,merged_at,url,title&since=$PARK_ISO\$" "$T/jobs.txt" \
  && ok || bad "R19: the record read must be the merged list since the park (jobs=$(cat "$T/jobs.txt"))"
# brs_merged_norm: the same {n} for the record file and the GitHub file, and
# GitHub's pre-park rows are out of the window.
printf '%s\n' "$GHROW" > "$T/g.tsv"
printf '%s\n%s\n' 'https://github.com/o/r/pull/9	2026-11-01T00:00:00Z	ticket/bh-23' "$GHROW" > "$T/g2.tsv"
SEAM '_BRMR_SINCE='"$PARK"' brs_merged_norm "$T/g.tsv"; _BRMR_SINCE='"$PARK"' brs_merged_norm "$T/g2.tsv"'
[ "$OUT" = $'[{"n":41}]\n[{"n":41}]' ] && ok || bad "R20: brs_merged_norm must give [{n:41}] for both files (out=$OUT)"

# ============================================================================
# D1-D8 the lane: br_merged_prs_for through the fragment, by step.
# ============================================================================
CALL="br_merged_prs_for o/r BH-23 $PARK; echo \"rc=\$?\""
AM='br_already_merged p1 rk reason - - BH-23 o/r; echo "am=$?"'

# D3 first: step off is today's behavior, the reference for the others.
REC41; BR "$CALL" GH_SOURCE=off
OFF_OUT="$OUT"; cp "$T/gh.txt" "$T/gh-off.txt"
{ [ "$OUT" = "$GHROW"$'\nrc=0' ] && [ "$(NSEARCH)" = 2 ] && [ "$(NPULLS)" = 1 ] && [ "$(NREC)" = 0 ]; } \
  && ok || bad "D3: off must make 2 searches + 1 pulls and 0 record GETs (out=$OUT gh=$(cat "$T/gh.txt") jobs=$(cat "$T/jobs.txt") err=$(head -5 "$T/br.err"))"
# W1
{ [ "$(NREASON)" = 1 ] && grep -q 'o/r: the merged-PR search for BH-23 ran, reason=step-off' "$T/say.log"; } \
  && ok || bad "W1: off must write one reason=step-off line (say=$(cat "$T/say.log"))"

# D1 / the REPRO: record, a fresh record holds #41 -> 0 GitHub calls.
REC41; BR "$CALL" GH_SOURCE=record
{ [ "$(NSEARCH)" = 0 ] && [ "$(NPULLS)" = 0 ]; } && ok \
  || bad "D1: record with a hit must make 0 GitHub calls, made $(NSEARCH) search/issues and $(NPULLS) pulls/N: $(tr '\n' ';' < "$T/gh.txt")"
[ "$OUT" = "$OFF_OUT" ] && ok || bad "D1: the record answer must equal the step-off answer (record='$OUT' off='$OFF_OUT')"
[ "$(NREC)" = 1 ] && ok || bad "D1: record must make exactly 1 record GET (jobs=$(cat "$T/jobs.txt"))"
[ "$(NREASON)" = 0 ] && ok || bad "D1: a record hit must write no reason line (say=$(cat "$T/say.log"))"
REC41; BR "$AM" GH_SOURCE=record
{ grep -qx 'RESOLVED https://github.com/o/r/pull/41' <<<"$OUT" && grep -qx 'am=0' <<<"$OUT" && [ "$(NSEARCH)" = 0 ]; } \
  && ok || bad "D1: the real br_already_merged must resolve on the record answer with 0 searches (out=$OUT gh=$(cat "$T/gh.txt"))"

# D2 shadow: the record lacks #41.
rec; BR "$CALL" GH_SOURCE=shadow
{ [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt" && [ "$(NREC)" = 1 ]; } \
  && ok || bad "D2: shadow must act on GitHub with the calls of off plus 1 record GET (out=$OUT gh=$(cat "$T/gh.txt") jobs=$(cat "$T/jobs.txt"))"
N=$(grep -c 'PRR_SHADOW lane=blocked-resolver key=o/r#BH-23@merged ' "$H/logs/prr-shadow.log" 2>/dev/null)
[ "$N" = 1 ] && ok || bad "D2: exactly 1 PRR_SHADOW ...@merged line expected, got $N: $(cat "$H/logs/prr-shadow.log" 2>/dev/null)"
# W2
{ [ "$(NREASON)" = 1 ] && grep -q 'reason=step-shadow' "$T/say.log"; } && ok || bad "W2: shadow must write one reason=step-shadow line (say=$(cat "$T/say.log"))"
# A shadow that agrees writes no PRR_SHADOW line.
REC41; BR "$CALL" GH_SOURCE=shadow
[ ! -s "$H/logs/prr-shadow.log" ] && ok || bad "D2b: an agreeing shadow must write no line: $(cat "$H/logs/prr-shadow.log")"

# D4 record, stale.
rec jq:'.sync.age_s = 99999' "$(row 41 ticket/bh-23 'BH-23: thing' 2026-11-26T10:00:00Z)"
BR "$CALL" GH_SOURCE=record
{ [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt"; } && ok || bad "D4: a stale record must make the calls of off (gh=$(cat "$T/gh.txt"))"
N=$(grep -c 'PRR_MISS lane=blocked-resolver key=o/r#BH-23@merged why=stale fallback=github' "$H/logs/prr-shadow.log" 2>/dev/null)
[ "$N" = 1 ] && ok || bad "D4: exactly 1 PRR_MISS why=stale line expected, got $N"
# W3
{ [ "$(NREASON)" = 1 ] && grep -q 'o/r: the merged-PR search for BH-23 ran, reason=record-miss:stale, rc 0' "$T/say.log"; } \
  && ok || bad "W3: a stale miss must write one reason=record-miss:stale line (say=$(cat "$T/say.log"))"

# D5 the other miss words.
d5() { # d5 <word> <call>
  BR "$2" GH_SOURCE=record
  { [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt" && grep -q "reason=record-miss:$1," "$T/say.log"; } \
    && ok || bad "D5: miss $1 must make the calls of off and name its reason (out=$OUT gh=$(cat "$T/gh.txt") say=$(cat "$T/say.log"))"
}
rec jq:'.sync = null' "$(row 41 ticket/bh-23 'BH-23: thing' 2026-11-26T10:00:00Z)"; d5 no-sync "$CALL"
rm -f "$T/rec.json"; d5 unreadable "$CALL"
rec jq:'.truncated = true' "$(row 41 ticket/bh-23 'BH-23: thing' 2026-11-26T10:00:00Z)"; d5 truncated "$CALL"
rec jq:'.missing = "merged_at"' "$(row 41 ticket/bh-23 'BH-23: thing' null)"; d5 field:merged_at "$CALL"
REC41; d5 no-since 'br_merged_prs_for o/r BH-23; echo "rc=$?"'

# D6 no GH_SOURCE: the step is shadow.
REC41; BR "$CALL"
{ [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt" && grep -q 'reason=step-shadow' "$T/say.log"; } \
  && ok || bad "D6: no GH_SOURCE must run step shadow (gh=$(cat "$T/gh.txt") say=$(cat "$T/say.log"))"

# D7 record miss, and the search answers 403: unknown, no state written.
rec jq:'.sync.age_s = 99999' "$(row 41 ticket/bh-23 'BH-23: thing' 2026-11-26T10:00:00Z)"
touch "$T/gh-403"
# The lift writes its own heartbeat file per run; that is not the read's state.
stl() { (cd "$H/state" && find . -path ./heartbeat -prune -o -print | LC_ALL=C sort); }
before=$(stl)
BR "$CALL" GH_SOURCE=record
grep -qx 'rc=75' <<<"$OUT" && ok || bad "D7: a refused search after a miss must be rc 75 (out=$OUT)"
BR "$AM" GH_SOURCE=record
grep -qx 'am=2' <<<"$OUT" && ok || bad "D7: br_already_merged must answer 2 (unknown) (out=$OUT)"
after=$(stl)
[ "$before" = "$after" ] && ok || bad "D7: a refused read must write no state: $(diff <(echo "$before") <(echo "$after"))"
rm -f "$T/gh-403"

# D8 the fragment switched off: today's function.
REC41; BR "$CALL" GH_SOURCE=record BR_OPT_OFF=bh-10350-merged-record
{ [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt" && [ "$(NREC)" = 0 ] && [ "$(NREASON)" = 0 ]; } \
  && ok || bad "D8: BR_OPT_OFF=bh-10350-merged-record must run today's search only (gh=$(cat "$T/gh.txt") jobs=$(cat "$T/jobs.txt"))"
[ ! -s "$T/realgh.txt" ] && ok || bad "0: a real gh ran: $(cat "$T/realgh.txt")"

# ============================================================================
# K1-K7 the retention window (lead review of #10389).
# ============================================================================
# kcase <id> <now-epoch> <hit|miss> [word] — step record, the record holds #41.
kcase() {
  REC41; BR "$CALL" GH_SOURCE=record PR_RECORD_NOW="$2"
  if [ "$3" = hit ]; then
    { [ "$OUT" = "$OFF_OUT" ] && [ "$(NSEARCH)" = 0 ] && [ "$(NPULLS)" = 0 ] && [ "$(NREC)" = 1 ]; } \
      && ok || bad "$1: the record must answer with 0 GitHub calls (out=$OUT gh=$(cat "$T/gh.txt") jobs=$(cat "$T/jobs.txt") say=$(cat "$T/say.log"))"
  else
    { [ "$OUT" = "$OFF_OUT" ] && cmp -s "$T/gh.txt" "$T/gh-off.txt" && [ "$(NREC)" = 0 ] \
      && grep -q "reason=record-miss:$4," "$T/say.log" \
      && grep -q "PRR_MISS lane=blocked-resolver key=o/r#BH-23@merged why=$4 fallback=github" "$H/logs/prr-shadow.log"; } \
      && ok || bad "$1: miss $4 must read no record and make the calls of off (out=$OUT gh=$(cat "$T/gh.txt") jobs=$(cat "$T/jobs.txt") say=$(cat "$T/say.log"))"
  fi
}
rm -f "$T/settings/"* "$T/settings-down"
# K1 no rows: the fallback 14 days, minus 1 day = 13 days.
kcase K1  "$((PARK + 13 * DAY))"     miss too-old
kcase K1b "$((PARK + 13 * DAY - 1))" hit
# K2 inside the window: the record answers (D1 is K2 at 1.5 days too).
kcase K2  "$((PARK + 12 * DAY))"     hit
# K3 the window comes from retention.pr_records.closed_days.
echo 30 > "$T/settings/retention.pr_records.closed_days"
kcase K3  "$((PARK + 20 * DAY))"     hit
kcase K3b "$((PARK + 29 * DAY))"     miss too-old
echo 5 > "$T/settings/retention.pr_records.closed_days"
kcase K4  "$((PARK + 4 * DAY + DAY / 2))" miss too-old
# K5 retention.pr_records.days is the smaller window: it binds.
echo 14 > "$T/settings/retention.pr_records.closed_days"; echo 10 > "$T/settings/retention.pr_records.days"
kcase K5  "$((PARK + 9 * DAY + DAY / 2))" miss too-old
# K6 both rules off (0): no window, an old park is answered.
echo 0 > "$T/settings/retention.pr_records.closed_days"; echo 0 > "$T/settings/retention.pr_records.days"
kcase K6  "$((PARK + 400 * DAY))"    hit
# K6b a bad value is the fallback, as the worker parses it.
echo abc > "$T/settings/retention.pr_records.closed_days"; rm -f "$T/settings/retention.pr_records.days"
kcase K6b "$((PARK + 13 * DAY))"     miss too-old
# K7 the row cannot be read: the window is unknown, a miss.
rm -f "$T/settings/"*; touch "$T/settings-down"
kcase K7  "$NOW"                     miss window-unread
rm -f "$T/settings-down"

# ============================================================================
# P1-P2 pipeline-health: the HOLD search carries its reason.
# ============================================================================
awk '/^# >>> stall alerts \(BH-6308\)/{f=1;next} /^# <<< stall alerts/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "P0: could not extract the stall alerts block"
PHH="$T/ph"; mkdir -p "$PHH/bin/lib" "$PHH/logs" "$PHH/state"
printf 'a o/a - - 2 box\nb o/b - - 2 box\n' > "$PHH/fleet.conf"
cat > "$PHH/bin/lib/stall-alerts.sh" <<EOF
stall_knob() { case "\$1" in STALL_HOLD_CHECK) echo "\${P_HOLD:-1}" ;; STALL_PARENT_CHECK) echo 0 ;; STALL_MAX_THREADS) echo 30 ;; *) echo 12 ;; esac; }
stall_parent_judge() { return 1; }
stall_hold_candidates() { echo "\$1" >> "$T/holdsearch.txt"; echo '[]'; }
EOF
phrun() {
  : > "$PHH/logs/pipeline-health.log"; : > "$T/holdsearch.txt"
  ( H="$PHH"; PROJECTS="a b"; NOW=1795564800; TMPDIR="$T/tmp"
    ACTIVE="$PHH/state/active.txt"; FIRED="$PHH/state/fired.txt"; : > "$ACTIVE"; : > "$FIRED"
    STAMP() { echo "2026-11-27 06:00:00Z"; }
    gh_budget_low() { return 1; }
    preplan_key_prefix() { echo BH; }
    alert() { :; }
    export P_HOLD="$1"
    # shellcheck source=/dev/null
    . "$T/block.sh" ) > "$T/ph.out" 2>&1
}
phrun 1
N=$(grep -c 'stall hold: 2 HOLD search read(s), reason=issue-comment-text' "$PHH/logs/pipeline-health.log")
{ [ "$N" = 1 ] && [ "$(wc -l < "$T/holdsearch.txt")" = 2 ]; } \
  && ok || bad "P1: 2 HOLD searches must write exactly 1 reason line, got $N: $(cat "$PHH/logs/pipeline-health.log") $(cat "$T/ph.out")"
phrun 0
grep -q 'stall hold' "$PHH/logs/pipeline-health.log" && bad "P2: no HOLD search must write no reason line: $(cat "$PHH/logs/pipeline-health.log")" || ok

echo "br-merged-record.bh-10350: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
