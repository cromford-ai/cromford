#!/bin/bash
# tests/review-disprove-report.bh-9238-test.sh — BH-9238 (C2 of BH-9047): the
# 7-day disprove report line and the stop rule. Runs the real
# bin/review-disprove-report.sh (installed with its source closure into a
# scratch harness) and the real bin/lib/review-disprove-report.sh, with only
# these stubbed:
#   * curl — the jobs worker: GET /api/review-disprove from $T/runs.json
#            ($T/rd500 = 500), GET /api/verdicts from $T/vrows.json ($T/v500 =
#            500), GET/PUT /api/settings over $T/set/<key> ($T/put500 = PUT
#            refused), GET/PUT /api/ledger over $T/ledger/<md5 of the query>;
#   * gh   — GitHub REST: repos/<o>/<r>/pulls/<n> ($T/gh/pull-<n>.json,
#            $T/gh/pull-<n>.500), the closed-PR list ($T/gh/closed-<o>-<r>.json),
#            pulls/<n>/files ($T/gh/files-<n>.json), compare/<a>...<b>
#            ($T/gh/compare-<a>-<b>.json); anything else is 404;
#   * date — `date -u +%s` answers the pinned NOW (Monday 2026-11-09T07:00Z);
#   * $H/bin/beat.sh and $H/bin/lane-alert.sh — record their argv.
# A second fakebin later on PATH holds a `gh` and a `curl` that write a
# sentinel: if any call passes the stubs, B1 fails (0 real vendor calls).
# Every case seeds its own rows with its own PR numbers (reset_case clears all
# state), so no case depends on another.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-disprove-report.bh-9238-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SCRIPT_REL=bin/review-disprove-report.sh; SCRIPT_ABS="$DIR/bin/review-disprove-report.sh"
LIB="$DIR/bin/lib/review-disprove-report.sh"
H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/logs" "$T/fakebin" "$T/realbin" "$T/log" "$T/tmp"
[ -f "$SCRIPT_ABS" ] || { echo "FAIL: $SCRIPT_REL missing"; FAIL=1; }
[ -f "$LIB" ] || { echo "FAIL: bin/lib/review-disprove-report.sh missing"; FAIL=1; }
if [ -f "$DIR/$SCRIPT_REL" ]; then
  scratch_install_closure "$SCRIPT_REL" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $SCRIPT_REL"; exit 1; }
fi
# The real lib the S5 round trip reads: dp_gate.
scratch_install_closure bin/lib/review-disprove.sh "$H" >/dev/null || { echo "FAIL: closure of bin/lib/review-disprove.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }

REALDATE=$(command -v date)
NOW=$("$REALDATE" -u -d 2026-11-09T07:00:00Z +%s)
DAYTAG=2026-11-09
iso() { "$REALDATE" -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf 'c%039d' "$1"; }
sha2() { printf 'd%039d' "$1"; }
REPO=example-org/cromford

cat > "$T/fakebin/date" <<EOF
#!/bin/bash
case "\$*" in "+%s"|"-u +%s") echo $NOW; exit 0 ;; esac
exec "$REALDATE" "\$@"
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker-all"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/review-disprove?"*)
    if [ -e "$T/rd500" ]; then code=500; out='{"error":"boom"}'
    else out=\$(jq -c --arg s "\$(qp since)" --argjson l "\$(qp limit)" \
      '[.[] | select(.created_at >= \$s)] | sort_by(.created_at) | reverse | {rows: .[0:\$l], limit: \$l}' "$T/runs.json"); fi ;;
  "GET /api/verdicts?"*)
    if [ -e "$T/v500" ]; then code=500; out='{"error":"boom"}'
    else out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" \
      '[.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) | {repo:\$r, pr:\$pr, rows:.[0:100]}' "$T/vrows.json"); fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "PUT /api/settings")
    if [ -e "$T/put500" ]; then code=500; out='{"error":"boom"}'
    elif [ -e "$T/putnoop" ]; then out='{"ok":true}'
    else jq -r .value <<<"\$body" > "$T/set/\$(jq -r .key <<<"\$body")"; out='{"ok":true}'; fi ;;
  "GET /api/ledger?"*)
    f="$T/ledger/\$(printf '%s' "\${p#*\?}" | md5sum | cut -c1-32)"
    if [ -f "\$f" ]; then out=\$(cat "\$f"); else code=404; out='{"error":"no row"}'; fi ;;
  "PUT /api/ledger")
    q=\$(jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)' <<<"\$body")
    jq -c '{ledger:{kind, key, status, detail:(.detail // "")}}' <<<"\$body" > "$T/ledger/\$(printf '%s' "\$q" | md5sum | cut -c1-32)"
    out='{"ok":true}' ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
p=""; prev=""; m=""
for a in "\$@"; do [ "\$prev" = -X ] && { m="\$a"; p=next; }; [ "\$p" = next ] && [ "\$a" != "\$m" ] && p="\$a"; prev="\$a"; done
okf() { printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$(cat "\$1")"; }
nf() { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
boom() { printf 'HTTP/1.1 500 Boom\r\n\r\n{"message":"boom"}\n'; exit 1; }
path="\${p%%\?*}"
case "\$m \$path" in
  "GET repos/"*"/pulls/"*"/files")
    n=\${path%/files}; n=\${n##*/}
    case "\$p" in *"page=1"*) [ -f "$T/gh/files-\$n.json" ] && okf "$T/gh/files-\$n.json" || nf ;; *) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;; esac ;;
  "GET repos/"*"/pulls/"*)
    n=\${path##*/}
    [ -e "$T/gh/pull-\$n.500" ] && boom
    [ -f "$T/gh/pull-\$n.json" ] && okf "$T/gh/pull-\$n.json" || nf ;;
  "GET repos/"*"/pulls")
    r=\${path#repos/}; r=\${r%/pulls}; r=\${r//\//-}
    case "\$p" in *"page=1") [ -f "$T/gh/closed-\$r.json" ] && okf "$T/gh/closed-\$r.json" || printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
                  *) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;; esac ;;
  "GET repos/"*"/compare/"*)
    c=\${path##*/compare/}; c=\${c/.../-}
    [ -f "$T/gh/compare-\$c.json" ] && okf "$T/gh/compare-\$c.json" || nf ;;
  *) nf ;;
esac
exit 0
EOF
# B1: the binaries a call reaches only when it passed the stubs.
for b in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/log/REAL-VENDOR-CALL"\nexit 1\n' "$b" "$T" > "$T/realbin/$b"
done
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/log/beats"
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
chmod +x "$T/fakebin/"* "$T/realbin/"* "$H/bin/beat.sh" "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$T/realbin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_APP_TOKENS=0 JOBS_BOX=test-box
unset GH_TOKEN HUB_BOX_NAME REVIEW_DISPROVE_REPORT_WINDOW_D REVIEW_DISPROVE_REPORT_DOW REVIEW_DISPROVE_REPORT_SEND \
  REVIEW_DISPROVE_REPORT_MAX_READS REVIEW_DISPROVE_REPORT_KEEP_D REVIEW_DISPROVE_STOP_WINDOW_D \
  REVIEW_DISPROVE_STOP_SLACK_LINES REVIEW_DISPROVE_STOP_MAX_PRS MC_MAIN_RED_LABEL

OUT="$H/state/review-disprove-report"
reset_case() {
  rm -rf "$T/set" "$T/ledger" "$T/gh" "$OUT" "$T/rd500" "$T/v500" "$T/put500" "$T/putnoop"
  mkdir -p "$T/set" "$T/ledger" "$T/gh"
  : > "$T/log/worker"; : > "$T/log/gh"; : > "$T/log/beats"; : > "$T/log/alerts"
  : > "$H/logs/review-disprove-report.log"
  echo '[]' > "$T/runs.json"; echo '[]' > "$T/vrows.json"
}
# row <jq object> — one review_disprove_runs row, defaults overridden by the object.
row() {
  local pr; pr=$(jq -nr "($1).pr")
  jq -nc --arg h "$(sha "$pr")" --arg c "$(iso $((NOW - 86400)))" --arg repo "$REPO" '
    {repo:$repo, head_sha:$h, review_id:"r", lane:"lead", project:"cromford", mode:"shadow",
     verdict_before:"BLOCK", verdict_after:"BLOCK", findings:1, checked:1, confirmed:0, disproved:1,
     kept_protected:0, unchecked:0, cost_usd:0.25,
     detail:[{cls:"wrong-data", loc:"bin/x.sh:40", outcome:"DISPROVED", reason:"r"}], created_at:$c} + ('"$1"')'
}
runs() { printf '%s\n' "$@" | jq -sc . > "$T/runs.json"; }
RC=0; STDOUT=""
run_lane() { RC=0; STDOUT=$(bash "$H/bin/review-disprove-report.sh" "$@" 2>"$T/log/stderr") || RC=$?; }
J() { jq -r "$1" "$OUT/$DAYTAG.json" 2>/dev/null; }
TXT() { cat "$OUT/latest.txt" 2>/dev/null; }
n_lines() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# ── R: the report line ─────────────────────────────────────────────────────
reset_case
runs "$(row '{pr:101, findings:2, checked:2, disproved:2}')" \
     "$(row '{pr:102}')" \
     "$(row '{pr:103, findings:2, checked:2, confirmed:1, disproved:1}')" \
     "$(row '{pr:104, disproved:0, kept_protected:1}')" \
     "$(row '{pr:105, lane:"conductor", confirmed:1, disproved:0, cost_usd:null}')"
run_lane --no-send
check "R1 rc 0" '[ "$RC" = 0 ]'
check "R1 lead.blocks=4" '[ "$(J .lead.blocks)" = 4 ]'
check "R1 lead.fully_disproved=2" '[ "$(J .lead.fully_disproved)" = 2 ]'
check "R1 lead.share=50" '[ "$(J .lead.share)" = 50 ]'
check "R1 conductor.blocks=1, fully 0" '[ "$(J .conductor.blocks)" = 1 ] && [ "$(J .conductor.fully_disproved)" = 0 ]'
check "R1 total.blocks=5" '[ "$(J .total.blocks)" = 5 ]'
check "R1 total findings: 2 confirmed, 4 disproved, 1 kept" '[ "$(J "[.total.confirmed,.total.disproved,.total.kept] | join(\",\")")" = "2,4,1" ]'
check "R1 total cost 1 (null cost left out)" '[ "$(J .total.cost_usd)" = 1 ]'
check "R1 latest.txt: fully disproved 2 of 5 (40%)" 'TXT | grep -qF "fully disproved 2 of 5 (40%)"'
check "R1 the text is made from the JSON: lead 2 of 4 (50%)" 'TXT | grep -qF "lead $(J .lead.fully_disproved) of $(J .lead.blocks) ($(J .lead.share)%)"'
check "R1 no verdict row yet: 2 pending" '[ "$(J .next_read.pending)" = 2 ] && TXT | grep -qF "2 pending"'
check "R1 --no-send: no beat" '[ ! -s "$T/log/beats" ]'
check "R1 one log line" '[ "$(wc -l < "$H/logs/review-disprove-report.log")" = 1 ]'

reset_case
runs "$(row '{pr:111, verdict_before:"MERGE", verdict_after:"MERGE"}')" "$(row '{pr:112}')"
run_lane --no-send
check "R2 verdict_before=MERGE is not a block" '[ "$(J .total.blocks)" = 1 ]'

reset_case
runs "$(row '{pr:121}')"; : > "$T/rd500"
run_lane
check "R3 rc 0 on an unreadable worker" '[ "$RC" = 0 ]'
check "R3 latest.txt holds n/a" 'TXT | grep -qF "n/a"'
check "R3 never 0 blocks" '! TXT | grep -qF "0 of 0"'
check "R3 no beat" '[ ! -s "$T/log/beats" ]'
check "R3 no gh call" '[ ! -s "$T/log/gh" ]'
check "R3 log line says n/a" 'grep -qF "blocks=n/a" "$H/logs/review-disprove-report.log"'

reset_case
runs "$(row '{pr:131}')"
run_lane
check "R4 Monday, send on, 1 block: exactly one beat" '[ "$(wc -l < "$T/log/beats")" = 1 ]'
check "R4 beat akey review-disprove-report:$DAYTAG" '[ "$(jq -r .akey "$T/log/beats")" = "review-disprove-report:$DAYTAG" ]'
check "R4 beat is a triaged fleet_alert carrying the line" '[ "$(jq -r "[.kind,.project,.triaged] | join(\",\")" "$T/log/beats")" = "fleet_alert,fleet,true" ] && jq -r .line "$T/log/beats" | grep -qF "fully disproved 1 of 1 (100%)"'

reset_case
runs "$(row '{pr:141}')"
REVIEW_DISPROVE_REPORT_DOW=3 run_lane
check "R5 not the report weekday: no beat" '[ ! -s "$T/log/beats" ]'
check "R5 the files are still written" 'TXT | grep -qF "fully disproved 1 of 1"'
REVIEW_DISPROVE_REPORT_DOW=3 run_lane --report-now
check "R5 --report-now: one beat" '[ "$(wc -l < "$T/log/beats")" = 1 ]'

reset_case
runs "$(row '{pr:151, verdict_before:"MERGE"}')"
run_lane
check "R6 0 blocks: no beat" '[ ! -s "$T/log/beats" ]'
check "R6 0 blocks: share n/a" 'TXT | grep -qF "fully disproved 0 of 0 (n/a)"'

reset_case
echo 3 > "$T/set/review.disprove.list_max"
runs "$(row '{pr:161}')" "$(row '{pr:162}')" "$(row '{pr:163}')"
run_lane --no-send
check "R6b answer holds limit rows: truncated in the JSON" '[ "$(J .truncated)" = true ]'
check "R6b truncated in the text" 'TXT | grep -qF "truncated"'
check "R6b the read asked for limit=3" 'grep -q "GET /api/review-disprove?since=.*&limit=3" "$T/log/worker"'
reset_case
runs "$(row '{pr:164}')" "$(row '{pr:165}')"
run_lane --no-send
check "R6b fewer rows than the limit: not truncated" '[ "$(J .truncated)" = false ] && ! TXT | grep -qF truncated'

# K1: no knob rows -> the fallbacks, named in the log line.
reset_case
runs "$(row '{pr:171}')"
run_lane --no-send
check "K1 log line names the fallbacks" 'grep -qF "window=7d dow=1 send=1 max_reads=40 stop_window=7d slack=10 max_prs=50 keep=84d" "$H/logs/review-disprove-report.log"'
check "K1 the read starts 14 days back (2 x stop window)" 'grep -qF "since=$(iso $((NOW - 14 * 86400)))" "$T/log/worker"'
check "K1 a row 8 days old is outside the 7-day report" '
  runs "$(row "{pr:172, created_at:\"$(iso $((NOW - 8 * 86400)))\"}")"; run_lane --no-send; [ "$(J .total.blocks)" = 0 ]'
REVIEW_DISPROVE_REPORT_WINDOW_D=abc run_lane --no-send
check "K1 a junk knob value falls back to 7 and says so" 'grep -qF "REVIEW_DISPROVE_REPORT_WINDOW_D=abc" "$H/logs/review-disprove-report.log" && [ "$(J .window_d)" = 7 ]'

# ── F: the fully-disproved rule table (drr_summary) ─────────────────────────
f_case() { # f_case <name> <row-object> <expected fully 0|1> <expected block 0|1>
  local s; s=$(row "$2" | jq -sc . | bash -c ". '$LIB'; drr_summary '$(iso $((NOW - 7 * 86400)))' false 7")
  check "F $1: fully=$3" "[ \"\$(jq -r .total.fully_disproved <<<'$s')\" = $3 ]"
  check "F $1: block=$4" "[ \"\$(jq -r .total.blocks <<<'$s')\" = $4 ]"
}
f_case "disproved=findings=2" '{pr:181, findings:2, checked:2, disproved:2}' 1 1
f_case "findings=1, disproved=1" '{pr:182}' 1 1
f_case "disproved=1 of findings=2" '{pr:183, findings:2, checked:2, disproved:1, confirmed:1}' 0 1
f_case "kept_protected=1 is not disproved" '{pr:184, disproved:0, kept_protected:1}' 0 1
f_case "findings=0" '{pr:185, findings:0, checked:0, disproved:0, detail:[]}' 0 0
f_case "verdict_before=MERGE" '{pr:186, verdict_before:"MERGE"}' 0 0

# ── N: the next read (drr_next_read) ────────────────────────────────────────
reset_case
C=$((NOW - 2 * 86400))
vrow() { # vrow <id> <pr> <head> <verdict> <source> <created epoch>
  jq -nc --argjson id "$1" --argjson pr "$2" --arg h "$3" --arg v "$4" --arg s "$5" --arg c "$(iso "$6")" --arg repo "$REPO" \
    '{id:$id, repo:$repo, pr:$pr, head_sha:$h, verdict:$v, source:$s, note:"", created_at:$c}'
}
nrow() { row "{pr:$1, created_at:\"$(iso "$C")\"}"; }
printf '%s\n' \
  "$(vrow 1 201 "$(sha 201)" APPROVE human $((C + 60)))" \
  "$(vrow 2 202 "$(sha2 202)" MERGE lead $((C + 60)))" \
  "$(vrow 3 203 "$(sha2 203)" MERGE-WITH-NOTES lead $((C + 60)))" \
  "$(vrow 4 204 "$(sha2 204)" BLOCK lead $((C + 60)))" \
  "$(vrow 5 205 "$(sha 205)" APPROVE human $((C - 60)))" \
  "$(vrow 6 205 "$(sha 205)" BLOCK lead $((C + 5)))" \
  "$(vrow 7 206 "$(sha 206)" MERGE lead $((C + 30)))" \
  "$(vrow 8 206 "$(sha 206)" MERGE human $((C + 90)))" \
  "$(vrow 9 208 "$(sha2 208)" MERGE lead $((C + 60)))" | jq -sc . > "$T/vrows.json"
echo '{"files":[{"filename":"docs/a.md"}]}' > "$T/gh/compare-$(sha 202)-$(sha2 202).json"
echo '{"files":[{"filename":"docs/a.md"},{"filename":"bin/y.sh","previous_filename":"bin/x.sh"}]}' > "$T/gh/compare-$(sha 203)-$(sha2 203).json"
nr() { bash -c ". '$H/bin/jobs-client.sh'; . '$H/bin/lib/gh-rest.sh'; . '$LIB'; GH_REST_OPTIONAL=1 drr_next_read '$REPO' \"\$1\"" _ "$(nrow "$1")" 2>/dev/null; }
check "N1 same head, human APPROVE: agreed-false" '[ "$(nr 201)" = agreed-false ]'
check "N2 moved head, disproved path untouched, MERGE: agreed-false" '[ "$(nr 202)" = agreed-false ]'
check "N3 moved head, disproved path renamed away: disagreed" '[ "$(nr 203)" = disagreed ]'
check "N4 next verdict BLOCK: disagreed" '[ "$(nr 204)" = disagreed ]'
check "N5 only the review's own lead BLOCK on the same head (and an older human row): pending" '[ "$(nr 205)" = pending ]'
check "N6 a same-head lead MERGE is skipped, the later same-head human MERGE counts: agreed-false" '[ "$(nr 206)" = agreed-false ]'
check "N8 compare 404: unreadable, not agreed" '[ "$(nr 208)" = unreadable ]'
runs "$(nrow 201)" "$(nrow 202)" "$(nrow 203)" "$(nrow 204)" "$(nrow 205)" "$(nrow 206)" "$(nrow 208)"
run_lane --no-send
check "N the lane counts 3 agreed, 2 disagreed, 1 pending, 1 unreadable" \
  '[ "$(J "[.next_read.agreed_false,.next_read.disagreed,.next_read.pending,.next_read.unreadable] | join(\",\")")" = "3,2,1,1" ]'
check "N the text line carries the four counts" 'TXT | grep -qF "3 agreed false, 2 disagreed, 1 pending, 1 unreadable"'
REVIEW_DISPROVE_REPORT_MAX_READS=2 run_lane --no-send
check "N cap: 2 read, 5 not read (cap)" '[ "$(J .next_read.not_read_cap)" = 5 ] && TXT | grep -qF "5 not read (cap 2)"'
: > "$T/v500"
check "N7 verdicts 500: unreadable" '[ "$(nr 201)" = unreadable ]'

# ── D: the hunk and touch table ────────────────────────────────────────────
hk() { bash -c ". '$LIB'; printf '%s\n' \"\$1\" | drr_hunks" _ "$1"; }
tc() { bash -c ". '$LIB'; printf '%s\n' \"\$1\" | drr_hunks | drr_touch $2 $3 $4" _ "$1"; }
check "D0 drr_hunks reads -a,b +c,d" '[ "$(hk "@@ -5,6 +7,2 @@ ctx")" = "5 10 7 8" ]'
check "D0 drr_hunks: a missing count is 1, a 0 count is its start" '[ "$(hk "@@ -7 +7,0 @@")" = "7 7 7 7" ]'
check "D1 hunk ends exactly at n-slack: touch" 'tc "@@ -5,6 +5,6 @@" 20 20 10'
check "D2 hunk starts at n+slack+1: no touch" '! tc "@@ -31,2 +31,2 @@" 20 20 10'
check "D3 range loc 10-20, slack 0, hunk at 20: touch" 'tc "@@ -20 +20 @@" 10 20 0'
check "D3 range loc 10-20, slack 0, hunk at 21: no touch" '! tc "@@ -21,3 +21,3 @@" 10 20 0'
check "D3 only the new side overlaps: touch" 'tc "@@ -100,1 +15,2 @@" 10 20 0'
FT="$T/files-test.json"
ft() { bash -c ". '$LIB'; drr_file_touch '$FT' $1 $2 $3 $4"; }
echo '[{"filename":"bin/new.sh","previous_filename":"bin/x.sh","patch":"@@ -10,1 +10,1 @@\n-a\n+b"}]' > "$FT"
check "D4 renamed file (previous_filename = path): touch" 'ft bin/x.sh 10 10 0'
echo '[{"filename":"tests/bin/x.sh","patch":"@@ -10,1 +10,1 @@\n-a\n+b"}]' > "$FT"
check "D5 same basename in another dir: no touch" '! ft bin/x.sh 10 10 10'
echo '[{"filename":"bin/x.sh","patch":"@@ -10,1 +10,1 @@\n-a\n+b"}]' > "$FT"
check "D5 reverse: tests/bin/x.sh finding, bin/x.sh changed: no touch" '! ft tests/bin/x.sh 10 10 10'
echo '[{"filename":"bin/x.sh"}]' > "$FT"
check "D7 a file entry with no patch counts as a touch" 'ft bin/x.sh 10 10 0'
CANDS=$(printf '%s\n' "$(row '{pr:191, mode:"enforce", verdict_after:"MERGE-WITH-NOTES", detail:[
  {cls:"wrong-data", loc:"-", outcome:"DISPROVED"}, {cls:"wrong-data", loc:"../x.sh:3", outcome:"DISPROVED"},
  {cls:"wrong-data", loc:"/etc/x:1", outcome:"DISPROVED"}, {cls:"wrong-data", loc:"bin/a.sh:4-6", outcome:"DISPROVED"},
  {cls:"wrong-data", loc:"bin/c.sh:9", outcome:"CONFIRMED"}]}')" | jq -sc . | bash -c ". '$LIB'; drr_candidates '$(iso $((NOW - 14 * 86400)))'")
check "D6 candidates: a bad loc (-, ../, /) is dropped, a range loc kept, a CONFIRMED loc dropped" \
  '[ "$(printf "%s\n" "$CANDS" | cut -f5)" = "bin/a.sh:4-6" ]'

# ── S: the stop rule ───────────────────────────────────────────────────────
# stop_setup <pr> [<project>] [<repo>] — enforce on for the project; one enforce
# row on <pr> created 5 days ago, cleared to MERGE-WITH-NOTES, finding bin/x.sh:40;
# the PR merged an hour after the row.
SC=$((NOW - 5 * 86400)); SM=$((SC + 3600))
stop_setup() {
  local pr="$1" project="${2:-cromford}" repo="${3:-$REPO}"
  echo enforce > "$T/set/review.disprove.mode"; echo 1 > "$T/set/review.disprove.$project.enabled"
  row "{pr:$pr, mode:\"enforce\", verdict_after:\"MERGE-WITH-NOTES\", project:\"$project\", repo:\"$repo\", created_at:\"$(iso "$SC")\"}"
  jq -nc --argjson n "$pr" --arg m "$(iso "$SM")" --arg h "$(sha "$pr")" '{number:$n, merged_at:$m, head:{sha:$h}}' > "$T/gh/pull-$pr.json"
}
# fixpr <repo> <n> <merged epoch> <label|-> <patch> — one merged PR on the closed list, with its files.
fixpr() {
  local f; f="$T/gh/closed-${1//\//-}.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --argjson n "$2" --arg m "$(iso "$3")" --arg l "$4" \
    '. + [{number:$n, merged_at:$m, updated_at:$m, labels:(if $l == "-" then [] else [{name:$l}] end)}]' "$f" > "$f.t" && mv "$f.t" "$f"
  jq -nc --arg p "$5" '[{filename:"bin/x.sh", patch:$p}]' > "$T/gh/files-$2.json"
}
HIT='@@ -38,4 +38,5 @@'
PUTS() { grep -c '^PUT /api/settings .*"key":"review.disprove.'"${1:-cromford}"'.enabled","value":"0"' "$T/log/worker" || true; }
LEDGER_PUTS() { grep -c '^PUT /api/ledger .*"kind":"review_disprove_stop"' "$T/log/worker" || true; }
CRIT() { grep -c -- "--severity critical --id review-disprove-stop-${1:-cromford}" "$T/log/alerts" || true; }

reset_case
runs "$(stop_setup 301)"; fixpr "$REPO" 401 $((SM + 2 * 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S1 rc 0" '[ "$RC" = 0 ]'
check "S1 PUT review.disprove.cromford.enabled = 0" '[ "$(PUTS)" = 1 ]'
check "S1 the setting note names the PR, the loc and the fix PR" 'grep "^PUT /api/settings" "$T/log/worker" | grep -qF "$REPO#301" && grep "^PUT /api/settings" "$T/log/worker" | grep -qF "bin/x.sh:40" && grep "^PUT /api/settings" "$T/log/worker" | grep -qF "#401"'
check "S1 ledger PUT review_disprove_stop with the pair key" 'grep "^PUT /api/ledger" "$T/log/worker" | grep -qF "\"key\":\"$REPO#301@$(sha 301 | cut -c1-12):401\""'
check "S1 exactly one critical lane-alert" '[ "$(CRIT)" = 1 ] && [ "$(wc -l < "$T/log/alerts")" = 1 ]'
check "S1 the alert says turned off" 'grep -qF "turned off" "$T/log/alerts"'
check "S1 order: setting, then ledger" '[ "$(grep -n "^PUT /api/settings" "$T/log/worker" | cut -d: -f1)" -lt "$(grep -n "^PUT /api/ledger" "$T/log/worker" | cut -d: -f1)" ]'
check "S1 the report line says 1 stopped" 'TXT | grep -qF "1 stopped"'
# S5: the switch round trip, through the real dp_gate.
check "S5 dp_gate cromford reads off after the stop" '[ "$(bash -c ". \"$H/bin/jobs-client.sh\"; . \"$H/bin/lib/review-disprove.sh\"; dp_gate cromford" 2>/dev/null)" = off ]'

reset_case
runs "$(stop_setup 302 | jq -c '.mode = "shadow"')"; fixpr "$REPO" 402 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S2 a shadow row: nothing written" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ] && [ "$(LEDGER_PUTS)" = 0 ]'
check "S2 a shadow row: 0 gh calls" '[ ! -s "$T/log/gh" ]'

reset_case
runs "$(stop_setup 303)"; jq -c '.merged_at = null' "$T/gh/pull-303.json" > "$T/gh/p.t" && mv "$T/gh/p.t" "$T/gh/pull-303.json"
fixpr "$REPO" 403 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S3 PR closed without merge: no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
runs "$(stop_setup 304)"; fixpr "$REPO" 404 $((SM + 86400)) fix-main-red "$HIT"; fixpr "$REPO" 405 $((SM + 2 * 86400)) fix-main-red "@@ -40,1 +40,1 @@"
run_lane --no-send
check "S4 two touching fix PRs: one setting write" '[ "$(PUTS)" = 1 ]'
check "S4 two touching fix PRs: one alert, naming the first fix PR" '[ "$(CRIT)" = 1 ] && grep -qF "#404" "$T/log/alerts"'

reset_case
runs "$(stop_setup 306)"; fixpr "$REPO" 406 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
echo 1 > "$T/set/review.disprove.cromford.enabled"   # an operator turns it back on
: > "$T/log/worker"; : > "$T/log/alerts"
run_lane --no-send
check "S6 second run: the pair is in the ledger, no setting PUT" '[ "$(PUTS)" = 0 ]'
check "S6 second run: no alert" '[ ! -s "$T/log/alerts" ]'
check "S6 the operator value stands" '[ "$(cat "$T/set/review.disprove.cromford.enabled")" = 1 ]'

reset_case
runs "$(stop_setup 307)"; : > "$T/gh/pull-307.500"; fixpr "$REPO" 407 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S7 pulls/<n> 500: no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'
check "S7 the report says stop-check: 1 unreadable" 'TXT | grep -q "stop-check: .*1 unreadable"'

reset_case
runs "$(stop_setup 308)"; fixpr "$REPO" 408 $((SM + 86400)) fix-main-red "$HIT"; : > "$T/put500"
run_lane --no-send
check "S8 settings PUT 500: one critical alert" '[ "$(CRIT)" = 1 ]'
check "S8 the alert names the failed switch-off and the row to set" 'grep -qF "could not turn" "$T/log/alerts" && grep -qF "review.disprove.cromford.enabled" "$T/log/alerts"'
check "S8 no ledger PUT" '[ "$(LEDGER_PUTS)" = 0 ]'
check "S8 the alert never says turned off" '! grep -qF "turned off" "$T/log/alerts"'

reset_case
runs "$(stop_setup 328)"; fixpr "$REPO" 428 $((SM + 86400)) fix-main-red "$HIT"; : > "$T/putnoop"
run_lane --no-send
check "S8b PUT answers 200 but the re-read is not 0: the could-not alert, no ledger PUT" \
  'grep -qF "could not turn" "$T/log/alerts" && ! grep -qF "turned off" "$T/log/alerts" && [ "$(LEDGER_PUTS)" = 0 ]'

reset_case
SC9=$((NOW - 12 * 86400)); SM9=$((SC9 + 3600))
runs "$(stop_setup 309 | jq -c --arg c "$(iso "$SC9")" '.created_at = $c')"
jq -c --arg m "$(iso "$SM9")" '.merged_at = $m' "$T/gh/pull-309.json" > "$T/gh/p.t" && mv "$T/gh/p.t" "$T/gh/pull-309.json"
fixpr "$REPO" 409 $((SM9 + 8 * 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S9 fix PR 8 days after the merge (window 7): no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'
REVIEW_DISPROVE_STOP_WINDOW_D=9 run_lane --no-send
check "S9 the same fix PR with window 9 (knob): stop" '[ "$(PUTS)" = 1 ]'

reset_case
runs "$(stop_setup 310 | jq -c '.verdict_after = "BLOCK"')"; fixpr "$REPO" 410 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S10 verdict_after=BLOCK (kept): no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
R2=example-org/project-1
runs "$(stop_setup 311)" "$(stop_setup 312 project-1 "$R2")"
fixpr "$REPO" 411 $((SM + 86400)) fix-main-red "$HIT"; fixpr "$R2" 412 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S11 two enforce projects, both touched: two PUTs" '[ "$(PUTS cromford)" = 1 ] && [ "$(PUTS project-1)" = 1 ]'
check "S11 two alerts, one per project" '[ "$(CRIT cromford)" = 1 ] && [ "$(CRIT project-1)" = 1 ]'

reset_case
runs "$(stop_setup 313)"; echo shadow > "$T/set/review.disprove.mode"; fixpr "$REPO" 413 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S12 gate shadow: 0 gh calls" '[ ! -s "$T/log/gh" ]'
check "S12 gate shadow: nothing written" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'
check "S12 gate shadow: the line says off (mode shadow)" 'TXT | grep -qF "stop-check: off (mode shadow)"'
reset_case
runs "$(stop_setup 314)"; echo 0 > "$T/set/review.disprove.cromford.enabled"; fixpr "$REPO" 414 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send
check "S12 project gate off (enabled 0): 0 gh calls, nothing written" '[ ! -s "$T/log/gh" ] && [ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
runs "$(stop_setup 315)"; fixpr "$REPO" 415 $((SM + 86400)) - "$HIT"; fixpr "$REPO" 416 $((SM + 86400)) docs "$HIT"
run_lane --no-send
check "S13 unlabelled or other-label merged PRs on the exact line: no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'
MC_MAIN_RED_LABEL=docs run_lane --no-send
check "S13 MC_MAIN_RED_LABEL names the label" '[ "$(PUTS)" = 1 ]'

reset_case
runs "$(stop_setup 317)"; fixpr "$REPO" 417 $((SM + 86400)) fix-main-red '@@ -90,2 +90,2 @@'
run_lane --no-send
check "S14 a fix PR 50 lines away: no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
runs "$(stop_setup 318)"; fixpr "$REPO" 418 $((SM + 86400)) fix-main-red "$HIT"
run_lane --no-send --dry-stop
check "S15 --dry-stop prints the decision" 'grep -qF "would stop cromford" <<<"$STDOUT"'
check "S15 --dry-stop: no setting PUT, no ledger PUT, no alert" '[ "$(PUTS)" = 0 ] && [ "$(LEDGER_PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
runs "$(stop_setup 319)"; fixpr "$REPO" 419 $((SM - 600)) fix-main-red "$HIT"
run_lane --no-send
check "S16 fix PR merged before the candidate: no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

reset_case
runs "$(stop_setup 320)" "$(stop_setup 321)"; fixpr "$REPO" 420 $((SM + 86400)) - "$HIT"
REVIEW_DISPROVE_STOP_MAX_PRS=1 run_lane --no-send
check "S17 the GitHub read cap stops the check and says truncated" 'TXT | grep -q "stop-check: .*truncated" && [ "$(grep -c "^api" "$T/log/gh")" -le 1 ]'

reset_case
runs "$(stop_setup 322)"; jq -c --arg m "$(iso $((SC - 3600)))" '.merged_at = $m' "$T/gh/pull-322.json" > "$T/gh/p.t" && mv "$T/gh/p.t" "$T/gh/pull-322.json"
fixpr "$REPO" 422 $((SC + 3600)) fix-main-red "$HIT"
run_lane --no-send
check "S18 the PR merged before the disprove row: not a candidate merge, no stop" '[ "$(PUTS)" = 0 ] && [ ! -s "$T/log/alerts" ]'

# R7: no case wrote the global mode (the lane never flips enforce).
check "R7 no PUT of review.disprove.mode in any case" '! grep -q "^PUT /api/settings .*\"key\":\"review.disprove.mode\"" "$T/log/worker-all"'

# L1: the hub cron renders one lease-gated line.
CRONOUT=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-crontab.sh" hub 2>/dev/null)
check "L1 exactly one hub cron line runs the lane" '[ "$(printf "%s\n" "$CRONOUT" | grep -v "^#" | grep -c "/root/harness/bin/review-disprove-report.sh")" = 1 ]'
check "L1 it is lease-gated at 06:25Z" 'grep -qxF "25 6 * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/review-disprove-report.sh >/dev/null 2>&1" <<<"$CRONOUT"'

# B1: 0 real vendor calls; the stubs saw the calls.
check "B1 no call passed the stubs" '[ ! -e "$T/log/REAL-VENDOR-CALL" ]'

echo "review-disprove-report.bh-9238: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
