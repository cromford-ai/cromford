#!/bin/bash
# tests/builds-merged-sweep.bh-3971-test.sh — the one-time sweep that re-checks
# console merged=1 rows against GitHub's merge fact (BH-3971).
#
# THE DEFECT. Before BH-866 reconcile put CLOSED PRs in the `merged` list, so a
# closed-unmerged PR (project-3 #331, TK-166) became a merged=1/pr_merged console
# row, and no lane ever re-read a merged=1 row. bin/builds-merged-sweep.sh is
# the re-read: it corrects a keyed closed-unmerged row to pr_closed/merged=0 and
# leaves every real merge alone.
#
# Driven, not grepped: the real script runs against a scratch $HARNESS with
# stubbed gh (REST shape), curl (jobs ledger + Cloudflare D1 query API) and
# beat.sh. Assertions are on the recorded beats, ledger PUTs, gh calls, D1
# request bodies, the log, the run TSV and ALERTS.log.
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/env" "$T/fakebin"
cp "$DIR/bin/builds-merged-sweep.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/console-pages.sh" "$H/bin/lib/"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"
CF_TOKEN="cfTOKENzz9-not-a-real-one-41f"
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CF_TOKEN" > "$H/env/cloudflare.env"

# beat.sh stub: every payload recorded; a build beat fails while $T/beat-fail exists.
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats.txt"
if [ -f "$T/beat-fail" ] && grep -q '"kind":"build"' <<<"\$1"; then exit 1; fi
exit 0
EOF
chmod +x "$H/bin/beat.sh"

A=https://github.com/Ex/demo/pull/1   # closed, never merged, keyed     -> corrected
B=https://github.com/Ex/other/pull/2  # merged                          -> kept
C=https://github.com/Ex/demo/pull/3   # open                            -> reported
D=https://github.com/Ex/demo/pull/4   # GitHub 404                      -> skipped (unknown)
E=https://github.com/Ex/demo/pull/5   # closed, never merged, NO bkey   -> reported (keyless)
jq -n --arg a "$A" --arg b "$B" --arg c "$C" --arg d "$D" --arg e "$E" '[
  {id:1,bkey:"build:demo:TK-1:demo-TK-1-202609170001",project:"demo",ticket_key:"TK-1",stage:"pr_merged",tier:2,verdict:"APPROVE",pr_url:$a,merged:1},
  {id:2,bkey:"build:other:OT-2:other-OT-2-202609170002",project:"other",ticket_key:"OT-2",stage:"pr_merged",tier:1,verdict:"APPROVE",pr_url:$b,merged:1},
  {id:3,bkey:"build:demo:TK-3:demo-TK-3-202609170003",project:"demo",ticket_key:"TK-3",stage:"pr_merged",tier:2,verdict:"APPROVE",pr_url:$c,merged:1},
  {id:4,bkey:"build:demo:TK-4:demo-TK-4-202609170004",project:"demo",ticket_key:"TK-4",stage:"pr_merged",tier:2,verdict:"APPROVE",pr_url:$d,merged:1},
  {id:5,bkey:"",project:"fleet",ticket_key:"",stage:"pr_merged",tier:null,verdict:null,pr_url:$e,merged:1}
]' > "$T/rows.json"

# gh stub, the shape gh_rest reads (`gh api -i -X GET <path> …`): a status
# line, a blank line, then the body. Closed lists answer A+E (Ex/demo) and B
# (Ex/other); C and D are only reachable by single reads.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHLOG"
P=""
for a in "$@"; do case "$a" in repos/*) P="$a" ;; esac; done
emit() { printf 'HTTP/2.0 %s X\r\n\r\n%s' "$1" "$2"; }
case "$P" in
  repos/Ex/demo/pulls) emit 200 '[{"html_url":"https://github.com/Ex/demo/pull/1","number":1,"state":"closed","closed_at":"2026-09-20T02:09:09Z","merged_at":null},
                                   {"html_url":"https://github.com/Ex/demo/pull/5","number":5,"state":"closed","closed_at":"2026-09-19T00:00:00Z","merged_at":null}]' ;;
  repos/Ex/other/pulls) emit 200 '[{"html_url":"https://github.com/Ex/other/pull/2","number":2,"state":"closed","closed_at":"2026-09-18T00:00:00Z","merged_at":"2026-09-18T00:00:00Z"}]' ;;
  repos/Ex/demo/pulls/3) emit 200 '{"html_url":"https://github.com/Ex/demo/pull/3","state":"open","closed_at":null,"merged_at":null}' ;;
  repos/Ex/demo/pulls/4) emit 404 '{"message":"Not Found"}' ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# curl stub: the jobs ledger (GET answers from $T/ledger-state "<kind> <url> <status>",
# PUT recorded) and the Cloudflare D1 query API ($T/d1-mode: pages | 403).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TT/curl-argv.txt"
URL="${!#}"; BODY=""; METHOD=GET; OUT=""; WCODE=""; DFILE=""; HSTDIN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|--data|-d) case "$2" in @*) DFILE="${2#@}" ;; *) BODY="$2" ;; esac; shift 2 ;;
    -X) METHOD="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -w) WCODE="$2"; shift 2 ;;
    -H) [ "$2" = "@-" ] && HSTDIN=1; shift 2 ;;
    *) shift ;;
  esac
done
case "$URL" in
  *api.cloudflare.com*/d1/database/*/query)
    [ "$HSTDIN" = 1 ] && cat >> "$TT/curl-stdin.txt"
    cat "$DFILE" >> "$TT/d1-reqs.txt"; printf '\n' >> "$TT/d1-reqs.txt"
    if [ "$(cat "$TT/d1-mode")" = 403 ]; then
      printf '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}' > "$OUT"; printf '403'; exit 0
    fi
    CUR=$(jq -r '.params[0]' "$DFILE")
    # A cursor asked for twice is a loop that never advances: answer 500 so it ends now.
    if grep -qxF "$CUR" "$TT/d1-cursors" 2>/dev/null; then printf '{"success":false}' > "$OUT"; printf '500'; exit 0; fi
    printf '%s\n' "$CUR" >> "$TT/d1-cursors"
    if [ "$CUR" = 0 ]; then FROM=1; TO=500; elif [ "$CUR" = 500 ]; then FROM=501; TO=503; else FROM=1; TO=0; fi
    jq -nc --argjson f "$FROM" --argjson t "$TO" '{success:true,errors:[],result:[{success:true,results:
      [range($f; $t + 1) | {id:., bkey:("build:demo:TK-\(.):x"), project:"demo", ticket_key:"TK-\(.)", stage:"pr_merged",
        tier:2, verdict:"APPROVE", pr_url:"https://github.com/Ex/other/pull/2", merged:1}]}]}' > "$OUT"
    printf '200'; exit 0 ;;
  *"/api/ledger"*)
    code=200; payload='{"ok":true}'
    if [ "$METHOD" = PUT ]; then printf '%s\n' "$BODY" >> "$TT/ledger-puts.txt"
    else
      k=$(printf '%s' "$URL" | sed -n 's/.*kind=\([^&]*\).*/\1/p')
      v=$(printf '%s' "$URL" | sed -n 's/.*key=\([^&]*\).*/\1/p' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')
      st=$(awk -v k="$k" -v v="$v" '$1==k && $2==v {s=$3} END{print s}' "$TT/ledger-state" 2>/dev/null)
      if [ -n "$st" ]; then payload="{\"ledger\":{\"status\":\"$st\"}}"; else code=404; payload='{"error":"not found"}'; fi
    fi
    printf '%s\n%s' "$payload" "$code"; exit 0 ;;
esac
printf '{}\n200'; exit 0
EOF
chmod +x "$T/fakebin/curl"

reset_rec() { : > "$T/d1-cursors"; : > "$T/beats.txt"; : > "$T/ledger-puts.txt"; : > "$T/gh-calls.txt"; : > "$T/d1-reqs.txt"
              : > "$T/curl-argv.txt"; : > "$T/curl-stdin.txt"; : > "$H/logs/builds-merged-sweep.log"; : > "$H/logs/ALERTS.log"; }
sweep() { # sweep <args...> ; RC and $T/out hold the result
  RC=0
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" GHLOG="$T/gh-calls.txt" TT="$T" JOBS_RETRIES=0 \
      JOBS_URL=https://jobs.example HARNESS_SECRET=shh GH_ETAG=0 \
      bash "$H/bin/builds-merged-sweep.sh" "$@" > "$T/out" 2> "$T/err" ) || RC=$?
}
build_beats() { jq -c 'select(.kind == "build")' "$T/beats.txt" 2>/dev/null; }
summary() { grep ' summary ' "$H/logs/builds-merged-sweep.log" | tail -1; }

# ═══ S1: the dry run classifies and writes nothing ═══════════════════════════
reset_rec; : > "$T/ledger-state"
printf 'merge %s merged\n' "$A" > "$T/ledger-state"
sweep --rows-file "$T/rows.json"
[ "$RC" = 0 ] && ok || bad "S1 dry run exit 0, got $RC: $(cat "$T/err")"
[ -z "$(build_beats)" ] && ok || bad "S1 dry run must send no build beat: $(cat "$T/beats.txt")"
[ ! -s "$T/ledger-puts.txt" ] && ok || bad "S1 dry run must PUT nothing to the ledger: $(cat "$T/ledger-puts.txt")"
summary | grep -q 'closed_unmerged=2 corrected=0 would_correct=1 ' && ok || bad "S1 summary closed_unmerged=2 corrected=0 would_correct=1: $(summary)"
grep -qF "build:demo:TK-1:demo-TK-1-202609170001 $A closed_unmerged -> corrected(dry)" "$H/logs/builds-merged-sweep.log" \
  && ok || bad "S1 A must log closed_unmerged -> corrected(dry): $(cat "$H/logs/builds-merged-sweep.log")"

# ═══ S2 + S5 + S6: --apply corrects A only, flips its ledger row, logs every row ═
rm -f "$H"/state/builds-merged-sweep/run-*.tsv
reset_rec
sweep --rows-file "$T/rows.json" --apply
[ "$RC" = 0 ] && ok || bad "S2 apply exit 0, got $RC: $(cat "$T/err")"
[ "$(build_beats | wc -l)" = 1 ] && ok || bad "S2 exactly one build beat: $(build_beats)"
BB=$(build_beats | head -1)
[ "$(jq -r '.bkey' <<<"$BB")" = "build:demo:TK-1:demo-TK-1-202609170001" ] && ok || bad "S2 the beat is for A: $BB"
[ "$(jq -r '.stage' <<<"$BB")" = pr_closed ] && ok || bad "S2 stage pr_closed: $BB"
[ "$(jq -r '.merged' <<<"$BB")" = false ] && ok || bad "S2 merged:false: $BB"
[ "$(jq -r '.tier' <<<"$BB")" = 2 ] && [ "$(jq -r '.verdict' <<<"$BB")" = APPROVE ] && ok || bad "S2 tier/verdict passed back as read: $BB"
[ "$(jq -r '.pr_url' <<<"$BB")" = "$A" ] && [ "$(jq -r '.project' <<<"$BB")" = demo ] && [ "$(jq -r '.ticket_key' <<<"$BB")" = TK-1 ] \
  && ok || bad "S2 pr_url/project/ticket_key passed back: $BB"
jq -r '.detail' <<<"$BB" | grep -q 'closed without merging' && ok || bad "S2 detail names 'closed without merging': $BB"
for u in "$B" "$C" "$D" "$E"; do
  grep -qF "\"pr_url\":\"$u\"" <<<"$(build_beats)" && bad "S2 no beat for $u: $(build_beats)" || ok
done
# S5: the ledger said merge <A> = merged -> one PUT, status closed, for A; nothing for B.
[ "$(grep -c . "$T/ledger-puts.txt")" = 1 ] && ok || bad "S5 one ledger PUT: $(cat "$T/ledger-puts.txt")"
LP=$(head -1 "$T/ledger-puts.txt")
[ "$(jq -r '.kind' <<<"$LP")" = merge ] && [ "$(jq -r '.key' <<<"$LP")" = "$A" ] && [ "$(jq -r '.status' <<<"$LP")" = closed ] \
  && ok || bad "S5 PUT merge <A> closed: $LP"
grep -qF "$B" "$T/ledger-puts.txt" && bad "S5 no PUT for B" || ok
# S6: one log line per row, the run TSV, the summary, one ALERTS line.
LG="$H/logs/builds-merged-sweep.log"
[ "$(grep -c ' -> ' "$LG")" = 5 ] && ok || bad "S6 five row lines: $(cat "$LG")"
grep -qF "build:other:OT-2:other-OT-2-202609170002 $B merged -> kept" "$LG" && ok || bad "S6 B kept: $(cat "$LG")"
grep -qF "build:demo:TK-3:demo-TK-3-202609170003 $C open -> reported" "$LG" && ok || bad "S6 C reported: $(cat "$LG")"
grep -qF "build:demo:TK-4:demo-TK-4-202609170004 $D unknown -> skipped:404" "$LG" && ok || bad "S6 D unknown/skipped: $(cat "$LG")"
grep -qF "<no-bkey> $E closed_unmerged -> reported:keyless" "$LG" && ok || bad "S6 E keyless: $(cat "$LG")"
grep -qF "build:demo:TK-1:demo-TK-1-202609170001 $A closed_unmerged -> corrected" "$LG" && ok || bad "S6 A corrected: $(cat "$LG")"
TSV=$(ls "$H"/state/builds-merged-sweep/run-*.tsv 2>/dev/null | head -1)
[ -n "$TSV" ] && [ "$(tail -n +2 "$TSV" | grep -c .)" = 5 ] && ok || bad "S6 run TSV with 5 data rows: ${TSV:-none}"
awk -F'\t' -v a="$A" '$4==a && $5=="closed_unmerged" && $6=="corrected" && $3=="TK-1"' "$TSV" 2>/dev/null | grep -q . \
  && ok || bad "S6 TSV row for A carries ticket, class, outcome"
summary | grep -qE 'mode=apply rows=5 prs=5 merged=1 closed_unmerged=2 corrected=1 would_correct=0 failed=0 open=1 unknown=1 keyless=1 no_url=0 reads=2 capped=0 tsv=' \
  && ok || bad "S6 summary line: $(summary)"
[ "$(grep -c 'builds-merged-sweep' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "S6 one ALERTS line: $(cat "$H/logs/ALERTS.log")"
grep 'builds-merged-sweep' "$H/logs/ALERTS.log" | grep -q "open=1 keyless=1 failed=0" && grep -qF "$TSV" "$H/logs/ALERTS.log" \
  && ok || bad "S6 ALERTS line counts open+keyless and names the TSV: $(cat "$H/logs/ALERTS.log")"

# ═══ S3: B is remembered as merged; a re-run reads nothing for it ════════════
grep -qxF "$B" "$H/state/builds-merged-sweep/verified-merged.tsv" && ok || bad "S3 B in verified-merged.tsv"
grep -qxF "$A" "$H/state/builds-merged-sweep/verified-merged.tsv" && bad "S3 A (closed unmerged) must never be remembered as merged" || ok
reset_rec; printf 'merge %s closed\n' "$A" > "$T/ledger-state"
sweep --rows-file "$T/rows.json" --apply
[ "$RC" = 0 ] && ok || bad "S3 re-run exit 0, got $RC"
grep -q 'Ex/other' "$T/gh-calls.txt" && bad "S3 a re-run must make no GitHub read for B: $(cat "$T/gh-calls.txt")" || ok
grep -qF "\"pr_url\":\"$B\"" <<<"$(build_beats)" && bad "S3 no beat for B" || ok
# S5 negative: the ledger already says closed -> no PUT.
[ ! -s "$T/ledger-puts.txt" ] && ok || bad "S5 ledger already closed: no PUT: $(cat "$T/ledger-puts.txt")"

# ═══ S7: a refused beat is `failed`, writes no ledger row, and the next run retries ═
reset_rec; printf 'merge %s merged\n' "$A" > "$T/ledger-state"; : > "$T/beat-fail"
sweep --rows-file "$T/rows.json" --apply
[ "$RC" = 0 ] && ok || bad "S7 a failed beat still exits 0, got $RC"
grep -qF "$A closed_unmerged -> failed" "$LG" && ok || bad "S7 A failed: $(cat "$LG")"
[ ! -s "$T/ledger-puts.txt" ] && ok || bad "S7 no ledger PUT after a failed beat: $(cat "$T/ledger-puts.txt")"
summary | grep -q 'corrected=0 would_correct=0 failed=1 ' && ok || bad "S7 summary failed=1: $(summary)"
rm -f "$T/beat-fail"; reset_rec
sweep --rows-file "$T/rows.json" --apply
grep -qF "$A closed_unmerged -> corrected" "$LG" && ok || bad "S7 the re-run corrects A: $(cat "$LG")"
[ "$(grep -c . "$T/ledger-puts.txt")" = 1 ] && ok || bad "S7 the re-run flips the ledger: $(cat "$T/ledger-puts.txt")"

# ═══ S4: bms_classify, sourced functions-only ════════════════════════════════
# shellcheck source=/dev/null
BMS_LIB_ONLY=1 . "$DIR/bin/builds-merged-sweep.sh" || { bad "S4 BMS_LIB_ONLY source failed"; }
cls_is() { local got; got=$(bms_classify "$1"); [ "$got" = "$2" ] && ok || bad "S4 bms_classify $1 -> $2, got $got"; }
cls_is '{"state":"closed","merged_at":"2026-09-18T00:00:00Z"}' merged
cls_is '{"state":"closed","merged":true,"merged_at":"2026-09-18T00:00:00Z"}' merged
cls_is '{"state":"closed","merged_at":"2026-09-18T00:00:00Z","merge_commit_sha":null}' merged
cls_is '{"state":"closed","merged_at":null}' closed_unmerged
cls_is '{"state":"closed","merged_at":""}' closed_unmerged
cls_is '{"state":"closed"}' closed_unmerged
cls_is '{"state":"open","merged_at":null}' open
cls_is '{"state":"open","merged_at":""}' open
cls_is '{}' unknown
cls_is '{"message":"Not Found"}' unknown
cls_is '{"merged_at":""}' unknown
cls_is 'not json at all' unknown
cls_is '' unknown
cls_is '{"STATE":"MERGED"}' unknown
cls_is '{"STATE":"MERGED","merged_at":null}' unknown
cls_is '{"state":"closed","merged":true,"merged_at":null}' unknown
cls_is '[{"state":"closed","merged_at":null}]' unknown

# ═══ bad arguments: no reads, exit 2 ═════════════════════════════════════════
reset_rec; printf '{"rows":[]}' > "$T/notarray.json"
sweep --rows-file "$T/notarray.json" --apply
[ "$RC" = 2 ] && ok || bad "a --rows-file that is not a JSON array exits 2, got $RC"
[ ! -s "$T/gh-calls.txt" ] && [ -z "$(build_beats)" ] && ok || bad "a bad --rows-file reads and writes nothing"
sweep --rows-file "$T/rows.json" --max-reads lots
[ "$RC" = 2 ] && ok || bad "--max-reads lots exits 2, got $RC"

# ═══ --max-reads caps single reads and says so ═══════════════════════════════
rm -f "$H/state/builds-merged-sweep/verified-merged.tsv"; reset_rec
sweep --rows-file "$T/rows.json" --max-reads 1
[ "$(grep -c 'pulls/[0-9]' "$T/gh-calls.txt")" = 1 ] && ok || bad "--max-reads 1 makes one single read: $(cat "$T/gh-calls.txt")"
summary | grep -q 'capped=1 INCOMPLETE' && ok || bad "a capped run says so: $(summary)"
grep -q -- '-> skipped:capped' "$LG" && ok || bad "the capped row is skipped:capped: $(cat "$LG")"

# ═══ S8: the D1 read — cursor paging on id, bound params, token kept off argv ═
export CLOUDFLARE_ACCOUNT_ID=acct0example
printf '%s\n' "$B" > "$H/state/builds-merged-sweep/verified-merged.tsv"
reset_rec; echo pages > "$T/d1-mode"
sweep
[ "$RC" = 0 ] && ok || bad "S8 D1 run exit 0, got $RC: $(cat "$T/err")"
[ "$(grep -c . "$T/d1-reqs.txt")" = 2 ] && ok || bad "S8 two D1 pages read: $(cat "$T/d1-reqs.txt")"
R2=$(grep . "$T/d1-reqs.txt" | sed -n 2p)
[ "$(jq -r '.params[0]' <<<"$R2")" = 500 ] && ok || bad "S8 page 2 binds id > 500 (last id of page 1): $R2"
jq -r '.sql' <<<"$R2" | grep -q 'id > ?' && ok || bad "S8 the cursor is 'id > ?': $R2"
grep -qi 'offset' "$T/d1-reqs.txt" && bad "S8 never OFFSET: $(cat "$T/d1-reqs.txt")" || ok
summary | grep -q 'rows=503 prs=1 merged=503 ' && ok || bad "S8 503 rows read across both pages: $(summary)"
[ ! -s "$T/gh-calls.txt" ] && ok || bad "S8 a remembered merge costs no GitHub read: $(cat "$T/gh-calls.txt")"
grep -qF "Authorization: Bearer $CF_TOKEN" "$T/curl-stdin.txt" && ok || bad "S8 the token reaches curl on stdin"
reset_rec
sweep --project "demo'; DROP TABLE builds;--"
R1=$(grep . "$T/d1-reqs.txt" | sed -n 1p)
[ "$(jq -r '.params[1]' <<<"$R1")" = "demo'; DROP TABLE builds;--" ] && ok || bad "S8 --project rides as a bound param: $R1"
grep -q 'DROP' <<<"$(jq -r '.sql' <<<"$R1")" && bad "S8 --project never spliced into the SQL: $R1" || ok
jq -r '.sql' <<<"$R1" | grep -q 'project = ?' && ok || bad "S8 the SQL filters 'project = ?': $R1"
# 403: exit 1, one ALERTS line naming the scope, no GitHub reads.
reset_rec; echo 403 > "$T/d1-mode"
sweep --apply
[ "$RC" = 1 ] && ok || bad "S8 a 403 read exits 1, got $RC"
[ "$(grep -c 'builds-merged-sweep' "$H/logs/ALERTS.log")" = 1 ] && grep -q 'HTTP 403' "$H/logs/ALERTS.log" \
  && grep -q 'D1 read on harness-console-db' "$H/logs/ALERTS.log" && ok || bad "S8 one ALERTS line naming D1 read on harness-console-db: $(cat "$H/logs/ALERTS.log")"
[ ! -s "$T/gh-calls.txt" ] && [ -z "$(build_beats)" ] && ok || bad "S8 a failed read makes no GitHub read and no beat"
for f in "$LG" "$H/logs/ALERTS.log" "$T/curl-argv.txt" "$T/out" "$T/err" "$T/beats.txt"; do
  grep -qF "$CF_TOKEN" "$f" && bad "S8 the token leaked into $f" || ok
done
unset CLOUDFLARE_ACCOUNT_ID

echo "builds-merged-sweep.bh-3971: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
