#!/bin/bash
# tests/lookback-reopen-detail.bh-9908-test.sh — BH-9908: the reopen items of
# the lookback bundle carry the PR that shipped the ticket, its changed files
# and the client's latest comment around the reopen.
#
# DRIVEN, NOT GREPPED: the C and U cases run the real bin/lookback-collect.sh
# in a scratch $HARNESS ($T/h) built with scratch_install_closure, with the
# real bin/jobs-client.sh + bin/lib/jobs/*, bin/lib/reopen-reason.sh and
# bin/lib/lookback-reopen.sh. A `curl` shim plays the jobs worker
# (/api/ticket-status answered from the requested keys only, /api/ledger for
# reopen_reason GET and PUT, abandoned, /api/alerts, /api/settings/<key>); a
# `gh` shim answers pulls/<n>/files. The R cases call the lib functions directly
# behind the same shims. Fixture dates come from the ONE `NOW` read below.
#
#   C1  3 reopens: TK-447 (PR + files + saved comment), TK-521 (PR, no comment
#       row), TK-743 (pr null) -> pr/files/comment/comment_status, the detail
#       counts, the reason unchanged, one ticket-status request per project
#   C2  a lower-case CSV key gets the PR of its upper-case key; TK-4470 in the
#       answer never maps to TK-447
#   C3  a GitHub-issues key #123 is sent as issue=123 and matched by .issue
#   C4  ticket-status 503, then a 200 HTML body: rc 0, incomplete false, pr ""
#       everywhere, pr_lookup names the http code, the comment still set
#   C5  bin/lib/lookback-reopen.sh absent: today's fields + comment null, none
#   C6  the K2 id rule holds with a filled pr
#   R1  lrd_pr_map never sends `PB 447` or `PB/447`; a non-GitHub pr url is dropped
#   R2  a detail written by the real rr_encode + rr_save for day D reads as saved
#   R3  the same detail read for day D+1 is other-day, comment null
#   R4  ticket_status.batch_max = 2 and 5 keys: 3 requests, every key mapped
#   R5  read unreadable -> unreadable; 0 comments -> no-comment; no row -> none
#   R6  ledger 503 and a mirror with the same day -> saved from the mirror
#   U1  the real _lookback_evidence on the real bundle prints the comment and PR
#   U2  lookback_cluster_run's prompt items carry pr and comment
#   U3  bin/lib/lookback-board.sh is unchanged (no client text on a board)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-reopen-detail.bh-9908-test: SKIPPED — jq missing"; exit 0; }

NOW=$(date -u +%s)
IN=$((NOW - 86400))
DAY_IN=$(date -u -d "@$IN" +%Y%m%d)
DAY_NEXT=$(date -u -d "@$((IN + 86400))" +%Y%m%d)
ISO_IN=$(date -u -d "@$IN" +%Y-%m-%dT%H:%M:%SZ)
ISO_IN2=$(date -u -d "@$((IN + 600))" +%Y-%m-%dT%H:%M:%SZ)
H="$T/h"
OUT="$T/bundle.json"
S="$T/stub"
PR501="https://github.com/example-org/project-2/pull/501"
PR530="https://github.com/example-org/project-2/pull/530"
PR77="https://github.com/example-org/ghp-app/pull/77"

# fresh — a new scratch harness with the real collector, its libs and the shims.
fresh() {
  scratch_rm "$H"; scratch_rm "$S"; rm -f "$OUT" "$T/out" "$T"/calls.*
  mkdir -p "$H/logs" "$H/env" "$H/state" "$S/rr" "$T/shim"
  : > "$H/env/global.env"
  scratch_install_closure bin/lookback-collect.sh "$H" >/dev/null || bad "closure lookback-collect"
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure jobs-client"
  scratch_install_closure bin/lib/reopen-reason.sh "$H" >/dev/null || bad "closure reopen-reason"
  scratch_install_closure bin/lib/lookback-reopen.sh "$H" >/dev/null 2>&1 || true
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in --projects) exit 0 ;; ghp) [ "$2" = board_prefix ] && echo - ;; *) exit 1 ;; esac
SH
  chmod +x "$H/bin/fleet-conf.sh"
  printf 'date,project,key,from,to\n%s,project-2,TK-447,review,in_progress\n%s,project-2,TK-521,review,in_progress\n%s,project-3,TK-743,review,in_progress\n' \
    "$DAY_IN" "$DAY_IN" "$DAY_IN" > "$H/logs/reopens.csv"
  # The worker's ticket-status rows per project: the shim answers only the
  # requested keys (key=K by .key, issue=n by .issue), the way the route does.
  jq -nc --arg u "$PR501" --arg u2 "$PR530" '[
    {key:"TK-447", issue:null, pr:{number:501, state:"merged", merged_at:"2026-11-15T10:00:00Z", url:$u}},
    {key:"TK-4470", issue:null, pr:{number:999, state:"merged", merged_at:"2026-11-15T10:00:00Z", url:"https://github.com/example-org/project-2/pull/999"}},
    {key:"TK-521", issue:null, pr:{number:530, state:"open", merged_at:null, url:$u2}},
    {key:"TK-1", issue:null, pr:{number:1, state:"merged", merged_at:null, url:"https://github.com/example-org/project-2/pull/1"}},
    {key:"TK-2", issue:null, pr:{number:2, state:"merged", merged_at:null, url:"https://github.com/example-org/project-2/pull/2"}},
    {key:"TK-3", issue:null, pr:{number:3, state:"merged", merged_at:null, url:"https://github.com/example-org/project-2/pull/3"}},
    {key:"TK-4", issue:null, pr:{number:4, state:"merged", merged_at:null, url:"https://github.com/example-org/project-2/pull/4"}},
    {key:"TK-5", issue:null, pr:{number:5, state:"merged", merged_at:null, url:"https://github.com/example-org/project-2/pull/5"}},
    {key:"TK-9", issue:null, pr:{number:9, state:"merged", merged_at:null, url:"https://example.com/x"}}]' > "$S/ts-project-2.json"
  jq -nc '[{key:"TK-743", issue:null, pr:null}]' > "$S/ts-project-3.json"
  jq -nc --arg u "$PR77" '[{key:"BH-123", issue:123, pr:{number:77, state:"merged", merged_at:null, url:$u}},
    {key:"BH-12", issue:12, pr:{number:12, state:"merged", merged_at:null, url:"https://github.com/example-org/ghp-app/pull/12"}}]' > "$S/ts-ghp.json"
  printf '[{"filename":"app/clients/page.tsx"},{"filename":"lib/fees.ts"}]' > "$S/pr-501-files.json"
  printf '[{"filename":"app/invoices/page.tsx"}]' > "$S/pr-530-files.json"
  printf '[{"filename":"src/issue.ts"}]' > "$S/pr-77-files.json"
  printf '<html><body>Cloudflare: origin error</body></html>' > "$S/html"
  cat > "$T/shim/curl" <<SH
#!/bin/bash
url="\${!#}"; method=GET; body=""
while [ \$# -gt 1 ]; do case "\$1" in -X) method="\$2"; shift ;; --data-binary) body="\$2"; shift ;; esac; shift; done
answer() { printf '%s\n%s' "\$2" "\$1"; }
path="\${url#http://jobs.stub}"
case "\$method \$path" in
  "GET /api/ticket-status?"*)
    printf '%s\n' "\$path" >> "$T/calls.ts"
    case "\${STUB_TS:-ok}" in
      503) answer 503 '{"error":"overloaded fixture"}'; exit 0 ;;
      html) answer 200 "\$(cat "$S/html")"; exit 0 ;;
      all) answer 200 "\$(jq -c '{format:"ticket-status v1", tickets:., unknown:[]}' "$S/ts-project-2.json")"; exit 0 ;;
    esac
    q="\${path#*\?}"; proj=""; keys=(); iss=()
    IFS='&' read -r -a parts <<<"\$q"
    for kv in "\${parts[@]}"; do
      case "\$kv" in project=*) proj="\${kv#project=}" ;; key=*) keys+=("\${kv#key=}") ;; issue=*) iss+=("\${kv#issue=}") ;; esac
    done
    f="$S/ts-\$proj.json"; [ -f "\$f" ] || f=/dev/null
    t=\$(jq -c --args '(\$ARGS.positional) as \$a | [.[]? | select((.key as \$k | \$a | index("k:"+\$k)) or (.issue != null and (.issue|tostring) as \$i | \$a | index("i:"+\$i)))]' \
        "\${keys[@]/#/k:}" "\${iss[@]/#/i:}" < "\$f")
    answer 200 "\$(jq -nc --arg p "\$proj" --argjson t "\${t:-[]}" '{format:"ticket-status v1", project:\$p, tickets:\$t, unknown:[]}')" ;;
  "GET /api/ledger?kind=reopen_reason&key="*)
    [ "\${STUB_RR:-ok}" = 503 ] && { answer 503 '{"error":"overloaded fixture"}'; exit 0; }
    enc="\${path#*&key=}"; k=\$(printf '%b' "\$(printf '%s' "\$enc" | sed 's/+/ /g; s/%/\\\\x/g')")
    f="$S/rr/\$(printf '%s' "\$k" | tr -c 'A-Za-z0-9._-' '_').json"
    if [ -f "\$f" ]; then answer 200 "\$(cat "\$f")"; else answer 404 '{"error":"not found"}'; fi ;;
  "PUT /api/ledger")
    k=\$(jq -r '.key' <<<"\$body")
    jq -c '{ledger:{status, detail, kind, key}}' <<<"\$body" > "$S/rr/\$(printf '%s' "\$k" | tr -c 'A-Za-z0-9._-' '_').json"
    answer 200 '{"ok":true}' ;;
  "GET /api/ledger?kind=abandoned"*) answer 200 '{"ledgers":[]}' ;;
  "GET /api/alerts"*) answer 200 '{"alerts":[],"truncated":false}' ;;
  "GET /api/settings/ticket_status.batch_max")
    if [ -n "\${STUB_BATCH:-}" ]; then answer 200 "{\"setting\":{\"key\":\"ticket_status.batch_max\",\"value\":\"\$STUB_BATCH\"}}"
    else answer 404 '{"error":"not found"}'; fi ;;
  *) answer 404 '{"error":"not found"}' ;;
esac
SH
  cat > "$T/shim/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.gh"
[ "\$1" = api ] || exit 1
path="\$2"; shift 2; q=""
[ "\${1:-}" = --jq ] && q="\$2"
case "\$path" in
  repos/example-org/project-2/pulls/501/files*) f="$S/pr-501-files.json" ;;
  repos/example-org/project-2/pulls/530/files*) f="$S/pr-530-files.json" ;;
  repos/example-org/ghp-app/pulls/77/files*) f="$S/pr-77-files.json" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
if [ -n "\$q" ]; then jq -r "\$q" "\$f"; else cat "\$f"; fi
SH
  chmod +x "$T/shim/curl" "$T/shim/gh"
}

# put_rr <project> <key> <day> <comments-json> [read] — a ledger row written
# the way bin/reopen-metrics.sh writes it: the real rr_encode + rr_save, through
# the real jobs client into the curl shim's ledger store (and the hub mirror).
put_rr() {
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture-secret \
    JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 RR_NOW="$NOW" bash -c '
    . "$HARNESS/bin/jobs-client.sh" || exit 91
    . "$HARNESS/bin/lib/reopen-reason.sh" || exit 92
    d=$(rr_encode "$1" "$2" "$3" review in_progress - "$5" "$5" app "${6:-ok}" "$4" 1) || exit 93
    rr_save "$1" "$2" "$(rr__status_of "$d")" "$d"' _ "$1" "$2" "$3" "$4" "$ISO_IN" "${5:-ok}" >/dev/null 2>&1
}
COMMENTS2=$(jq -nc --arg a "$ISO_IN" --arg b "$ISO_IN2" '[{at:$a, author:"Dana Client", text:"The fee field is still not editable."},
  {at:$b, author:"Dana Client", text:"Still broken on the client page after the deploy."}]')

collect() { # collect [VAR=value ...]; rc in $RC, bundle in $OUT
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture-secret \
    JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_GATE_NOW="$NOW" "$@" bash "$H/bin/lookback-collect.sh" --days 7 --out "$OUT" > "$T/out" 2>&1
  RC=$?
}
q() { jq -r "$1" "$OUT" 2>/dev/null; }
item() { jq -c --arg t "$1" '[.items[]|select(.source=="reopen" and .ticket==$t)][0]' "$OUT" 2>/dev/null; }
f_of() { jq -r "$2" <<<"$1" 2>/dev/null; }

# lib [VAR=value ...] -- <bash snippet> [args] — the real libs in a clean shell.
lib() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture-secret \
    JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_GATE_NOW="$NOW" "${envs[@]}" bash -c '
    . "$HARNESS/bin/jobs-client.sh" || exit 91
    . "$HARNESS/bin/lib/reopen-reason.sh" || exit 92
    . "$HARNESS/bin/lib/lookback-reopen.sh" || exit 93
    '"$1" _ "${@:2}" 2>>"$T/lib.err"
}

# --- C1 ------------------------------------------------------------------------
fresh
put_rr project-2 TK-447 "$DAY_IN" "$COMMENTS2"
collect
eq "C1 rc" "$RC" 0
I447=$(item TK-447); I521=$(item TK-521); I743=$(item TK-743)
eq "C1 TK-447 pr" "$(f_of "$I447" .pr)" "$PR501"
eq "C1 TK-447 files from the PR" "$(f_of "$I447" '.files|join(",")')" "app/clients/page.tsx,lib/fees.ts"
eq "C1 TK-447 comment is the newest" "$(f_of "$I447" '.comment.text')" "Still broken on the client page after the deploy."
eq "C1 TK-447 comment author/at" "$(f_of "$I447" '[.comment.author,.comment.at]|join("|")')" "Dana Client|$ISO_IN2"
eq "C1 TK-447 comment_status" "$(f_of "$I447" .comment_status)" saved
eq "C1 TK-521 pr (open PR)" "$(f_of "$I521" .pr)" "$PR530"
eq "C1 TK-521 comment_status none" "$(f_of "$I521" .comment_status)" none
eq "C1 TK-521 comment null" "$(f_of "$I521" .comment)" null
eq "C1 TK-743 pr empty" "$(f_of "$I743" .pr)" ""
eq "C1 TK-743 files []" "$(f_of "$I743" '.files|length')" 0
eq "C1 reason unchanged" "$(q '[.items[]|select(.source=="reopen")|.reason]|unique|join(",")')" "reopened: review -> in_progress"
eq "C1 detail" "$(q '.sources.reopen.detail|[.pr_lookup,.with_pr,.with_comment]|map(tostring)|join("|")')" "ok|2|1"
eq "C1 reopen source n" "$(q '.sources.reopen.n')" 3
eq "C1 incomplete" "$(q .incomplete)" false
eq "C1 one ticket-status request per project" "$(grep -c . "$T/calls.ts" 2>/dev/null || echo 0)" 2
cp "$OUT" "$T/bundle-c1.json"

# --- C2 lower-case key, and TK-4470 never maps to TK-447 -----------------------
fresh
printf 'date,project,key,from,to\n%s,project-2,TK-447,review,in_progress\n' "$DAY_IN" > "$H/logs/reopens.csv"
collect
eq "C2 rc" "$RC" 0
eq "C2 lower-case key gets TK-447's PR" "$(q '.items[]|select(.source=="reopen")|.pr')" "$PR501"
has "C2 the key is sent upper-case" "$(cat "$T/calls.ts" 2>/dev/null)" "key=TK-447"
fresh
printf 'date,project,key,from,to\n%s,project-2,TK-447,review,in_progress\n' "$DAY_IN" > "$H/logs/reopens.csv"
jq -c 'map(select(.key != "TK-447"))' "$S/ts-project-2.json" > "$S/x" && mv "$S/x" "$S/ts-project-2.json"
# STUB_TS=all: a worker that answers every row it holds, TK-4470 included
collect STUB_TS=all
eq "C2 TK-4470 in the answer -> TK-447 gets no PR" "$(q '.items[]|select(.source=="reopen")|.pr')" ""

# --- C3 GitHub-issues key ------------------------------------------------------
fresh
printf 'date,project,key,from,to\n%s,ghp,#123,done,todo\n' "$DAY_IN" > "$H/logs/reopens.csv"
collect
eq "C3 rc" "$RC" 0
has "C3 sent as issue=123" "$(cat "$T/calls.ts" 2>/dev/null)" "issue=123"
hasnt "C3 never sent as key=" "$(cat "$T/calls.ts" 2>/dev/null)" "key="
eq "C3 #123 gets the PR of issue 123" "$(q '.items[]|select(.source=="reopen")|.pr')" "$PR77"
eq "C3 files from that PR" "$(q '.items[]|select(.source=="reopen")|.files|join(",")')" "src/issue.ts"
eq "C3 ticket stays #123" "$(q '.items[]|select(.source=="reopen")|.ticket')" "#123"

# --- C4 ticket-status outage ---------------------------------------------------
for mode in 503 html; do
  fresh
  put_rr project-2 TK-447 "$DAY_IN" "$COMMENTS2"
  collect STUB_TS=$mode
  eq "C4/$mode rc" "$RC" 0
  eq "C4/$mode incomplete false" "$(q .incomplete)" false
  eq "C4/$mode reopen ok" "$(q .sources.reopen.ok)" true
  eq "C4/$mode no pr anywhere" "$(q '[.items[]|select(.source=="reopen")|.pr]|unique|join(",")')" ""
  eq "C4/$mode with_pr 0" "$(q .sources.reopen.detail.with_pr)" 0
  [ "$mode" = 503 ] && has "C4/503 pr_lookup names the code" "$(q .sources.reopen.detail.pr_lookup)" "http=503"
  [ "$mode" = html ] && has "C4/html pr_lookup names the code" "$(q .sources.reopen.detail.pr_lookup)" "http=200"
  hasnt "C4/$mode pr_lookup is not ok" "$(q .sources.reopen.detail.pr_lookup)" "ok;"
  [ "$(q .sources.reopen.detail.pr_lookup)" = ok ] && bad "C4/$mode pr_lookup must not be ok"
  eq "C4/$mode comment still set" "$(f_of "$(item TK-447)" .comment_status)" saved
done

# --- C5 lib absent -------------------------------------------------------------
fresh
put_rr project-2 TK-447 "$DAY_IN" "$COMMENTS2"
rm -f "$H/bin/lib/lookback-reopen.sh"
collect
eq "C5 rc" "$RC" 0
eq "C5 pr empty" "$(f_of "$(item TK-447)" .pr)" ""
eq "C5 comment null" "$(f_of "$(item TK-447)" .comment)" null
eq "C5 comment_status none" "$(f_of "$(item TK-447)" .comment_status)" none
eq "C5 today's fields" "$(f_of "$(item TK-447)" '[.source,.project,.ticket,.lane,.reason]|join("|")')" "reopen|project-2|TK-447|reopen|reopened: review -> in_progress"
has "C5 pr_lookup names why" "$(q .sources.reopen.detail.pr_lookup)" "lookback-reopen"
eq "C5 no ticket-status request" "$([ -s "$T/calls.ts" ] && echo sent || echo none)" none

# --- C6 id rule with a filled pr -----------------------------------------------
ids_ok=true; nfilled=0
while IFS= read -r id && IFS= read -r joined && IFS= read -r pr; do
  [ -n "$pr" ] && nfilled=$((nfilled + 1))
  [ "$id" = "$(printf '%s' "$joined" | sha1sum | cut -c1-12)" ] || ids_ok=false
done < <(jq -r '.items[]|select(.source=="reopen")|.id, ([.source,.project,.ticket,.pr,.reason]|join("|")), .pr' "$T/bundle-c1.json")
eq "C6 id = sha1(source|project|ticket|pr|reason)[:12]" "$ids_ok" true
eq "C6 the rule was checked on filled prs" "$nfilled" 2

# --- R1 malformed keys never sent; non-GitHub url dropped ----------------------
fresh
printf 'PB 447\nPB/447\nPB-9\nPB-447\n' > "$T/keys"
out=$(lib -- 'lrd_pr_map project-2 "$1" "$2"; echo "rc=$?"' "$T/keys" "$T/map")
eq "R1 rc" "$out" "rc=0"
hasnt "R1 PB 447 never sent" "$(cat "$T/calls.ts" 2>/dev/null)" "PB 447"
hasnt "R1 PB%20447 never sent" "$(cat "$T/calls.ts" 2>/dev/null)" "PB%20447"
hasnt "R1 PB/447 never sent" "$(cat "$T/calls.ts" 2>/dev/null)" "PB/447"
eq "R1 only valid keys mapped" "$(cut -f1 "$T/map" 2>/dev/null | sort | paste -sd, -)" "TK-447"
eq "R1 example.com url dropped" "$(grep -c 'example.com' "$T/map" 2>/dev/null)" 0
out=$(lib -- 'lrd_pr_map "Bad/Project" "$1" "$2"; echo "rc=$?"' "$T/keys" "$T/map2")
eq "R1 bad project refused" "$out" "rc=1"

# --- R2/R3 rr_encode + rr_save round trip, day check ---------------------------
fresh
put_rr project-2 TK-447 "$DAY_IN" "$COMMENTS2"
out=$(lib -- 'lrd_comment project-2 TK-447 "$1"' "$DAY_IN")
eq "R2 saved" "$(jq -r .comment_status <<<"$out" 2>/dev/null)" saved
eq "R2 last comment" "$(jq -r .comment.text <<<"$out" 2>/dev/null)" "Still broken on the client page after the deploy."
out=$(lib -- 'lrd_comment project-2 TK-447 "$1"' "$DAY_NEXT")
eq "R3 other-day" "$(jq -r .comment_status <<<"$out" 2>/dev/null)" other-day
eq "R3 comment null" "$(jq -r .comment <<<"$out" 2>/dev/null)" null

# --- R4 batch_max knob ---------------------------------------------------------
fresh
printf 'TK-1\nPB-2\nPB-3\nPB-4\nPB-5\n' > "$T/keys"
out=$(lib STUB_BATCH=2 -- 'lrd_pr_map project-2 "$1" "$2"; echo "rc=$?"' "$T/keys" "$T/map")
eq "R4 rc" "$out" "rc=0"
eq "R4 3 requests for 5 keys at batch 2" "$(grep -c . "$T/calls.ts" 2>/dev/null)" 3
eq "R4 every key mapped (chunk 3 too)" "$(cut -f1 "$T/map" | sort | paste -sd, -)" "TK-1,TK-2,TK-3,TK-4,TK-5"
eq "R4 TK-5 url" "$(awk -F'\t' '$1=="TK-5"{print $2}' "$T/map")" "https://github.com/example-org/project-2/pull/5"
rm -f "$T/calls.ts"
out=$(lib -- 'lrd_pr_map project-2 "$1" "$2"; echo "rc=$?"' "$T/keys" "$T/map")
eq "R4 no row -> fallback 20: one request" "$(grep -c . "$T/calls.ts" 2>/dev/null)" 1

# --- R5 unreadable, no-comment, no row -----------------------------------------
fresh
put_rr project-2 TK-447 "$DAY_IN" '[]' unreadable
put_rr project-2 TK-521 "$DAY_IN" '[]'
eq "R5 unreadable" "$(lib -- 'lrd_comment project-2 TK-447 "$1"' "$DAY_IN" | jq -r .comment_status)" unreadable
eq "R5 no-comment" "$(lib -- 'lrd_comment project-2 TK-521 "$1"' "$DAY_IN" | jq -r .comment_status)" no-comment
eq "R5 no row -> none" "$(lib -- 'lrd_comment project-2 TK-999 "$1"' "$DAY_IN" | jq -r .comment_status)" none
eq "R5 no-comment has null comment" "$(lib -- 'lrd_comment project-2 TK-521 "$1"' "$DAY_IN" | jq -r .comment)" null

# --- R6 ledger 503, mirror read ------------------------------------------------
fresh
put_rr project-2 TK-447 "$DAY_IN" "$COMMENTS2"
out=$(lib STUB_RR=503 -- 'lrd_comment project-2 TK-447 "$1"' "$DAY_IN")
eq "R6 saved from the mirror" "$(jq -r .comment_status <<<"$out" 2>/dev/null)" saved
eq "R6 mirror comment" "$(jq -r .comment.author <<<"$out" 2>/dev/null)" "Dana Client"
scratch_rm "$H/state/reopen-reasons"
out=$(lib STUB_RR=503 -- 'lrd_comment project-2 TK-447 "$1"' "$DAY_IN")
eq "R6 ledger 503 and no mirror -> unreadable" "$(jq -r .comment_status <<<"$out" 2>/dev/null)" unreadable

# --- U1 the issue evidence -----------------------------------------------------
fresh
scratch_install_closure bin/lib/lookback-file.sh "$H" >/dev/null || bad "closure lookback-file"
mkdir -p "$T/run"; cp "$T/bundle-c1.json" "$T/run/bundle.json"
ids=$(jq -c '[.items[]|select(.source=="reopen")|.id]' "$T/run/bundle.json")
ev=$(env -i PATH="$PATH" HOME="$T" HARNESS="$H" bash -c '. "$HARNESS/bin/lib/lookback-file.sh" >/dev/null 2>&1; _lookback_evidence "$1" "$2"' _ "$T/run" "$ids" 2>&1)
l447=$(grep -F "ticket: TK-447" <<<"$ev"); l743=$(grep -F "ticket: TK-743" <<<"$ev")
has "U1 TK-447 client comment" "$l447" "client comment: Dana Client ($ISO_IN2): Still broken on the client page after the deploy."
has "U1 TK-447 PR" "$l447" "PR: $PR501"
has "U1 TK-447 files" "$l447" "files: app/clients/page.tsx, lib/fees.ts"
hasnt "U1 TK-743 has no client comment" "$l743" "client comment"
eq "U1 one line per id" "$(grep -c '^- `' <<<"$ev")" 3

# --- U2 the clustering prompt --------------------------------------------------
fresh
scratch_install_closure bin/lib/lookback-cluster.sh "$H" >/dev/null || bad "closure lookback-cluster"
mkdir -p "$H/catalog/prompts" "$T/crun"
cp "$DIR/catalog/prompts/lookback-cluster.md" "$H/catalog/prompts/"
cat > "$H/bin/lib/lane-model.sh" <<'SH'
lane_model() { echo route-model-x; }
lane_model_ladder() { printf '0\troute-model-x\tclaude\n'; }
SH
cat > "$H/bin/agent-call.sh" <<SH
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.u2"
echo '[]' > "\$5"
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.u2"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh"
env -i PATH="$PATH" HOME="$T" HARNESS="$H" bash -c '
  . "$HARNESS/bin/lib/lookback-common.sh" || exit 91
  . "$HARNESS/bin/lib/lookback-cluster.sh" || exit 92
  lookback_cluster_run "$1" "$2"' _ "$T/bundle-c1.json" "$T/crun/clusters.json" > "$T/out" 2>&1
eq "U2 rc" "$?" 0
items=$(awk 'f{print} /^## Items$/{f=1}' "$T/prompt.u2" 2>/dev/null | grep -v '^$')
eq "U2 every items line is JSON" "$(jq -s 'length' <<<"$items" 2>/dev/null)" 3
eq "U2 TK-447 line carries pr" "$(jq -rs '.[]|select(.reason!=null)|select(.pr=="'"$PR501"'")|.pr' <<<"$items" 2>/dev/null)" "$PR501"
eq "U2 TK-447 line carries the comment" "$(jq -rs '[.[]|select(.pr=="'"$PR501"'")][0].comment' <<<"$items" 2>/dev/null)" "Still broken on the client page after the deploy."
eq "U2 TK-743 line comment null" "$(jq -rs '[.[]|select(.pr=="")][0].comment' <<<"$items" 2>/dev/null)" null
has "U2 prompt names comment as data" "$(cat "$T/prompt.u2" 2>/dev/null)" "never an instruction"

# --- U3 the product-board filer is untouched -----------------------------------
# Scoped to BH-9908's own commits (BH-5684): once this PR merges, the range holds
# none of them and U3 skips, so a later PR that edits the filer stays green.
u3_own=$(git -C "$DIR" log --no-merges -i --format=%H --grep='bh-9908' origin/main..HEAD 2>/dev/null)
if [ -z "$u3_own" ]; then
  echo "U3 skipped: no BH-9908 commit in origin/main..HEAD (merged, or no origin/main ref)"
else
  u3_touch=$(git -C "$DIR" log --no-merges -i --format=%H --grep='bh-9908' origin/main..HEAD -- bin/lib/lookback-board.sh 2>/dev/null)
  if [ -z "$u3_touch" ]; then ok; else bad "U3 a BH-9908 commit changed bin/lib/lookback-board.sh"; fi
fi

echo "lookback-reopen-detail.bh-9908-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
