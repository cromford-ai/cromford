#!/bin/bash
# tests/ticket-status-comment-state.bh-10216-test.sh — BH-10216: the hub lane
# bin/ticket-status-comment.sh keeps the comment id and the body hash in the
# worker's ticket_status_comments row, and makes no GitHub read before an edit.
# The fake worker here keeps the real row semantics (the due answer is computed
# from a fixture state and the row; DELETE is compare-and-delete on the id); the
# fake GitHub (gh_rest) logs "METHOD path" for each call. 0 network calls.
#
#   S1  no row, no marked comment: tick 1 = 1 GET (list) + 1 POST, row stored;
#       ticks 2 and 3 with the same state: 0 GitHub calls
#   S2  a state change: 1 PATCH, 0 GET; the row holds the new fingerprint
#   S3  the comment was deleted (PATCH 404): 1 DELETE of the row, 1 POST, 0 GET;
#       the row names the new id; posted=1
#   S4  a failed PATCH (500): the row keeps the old hash; the next tick PATCHes
#       again, 0 GET
#   S5  no row, our marked comment exists, its PATCH fails: 1 GET, 1 PATCH, the
#       row holds that id with fingerprint ''; the next tick: 0 GET, 1 PATCH,
#       the row holds the new fingerprint
#   S6  the DELETE after a 404 fails (503): 0 POST, posted=0 failed=1, row unchanged
#   S7  the due read fails (503): 0 GitHub calls, no row written
# Files under test: "$SRC/bin/ticket-status-comment.sh".
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ticket-status-comment-state.bh-10216-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MARK='<!-- harness-status: ticket-status -->'
APP='cromford-board[bot]'
export HOME="$T/home" TMPDIR="$T/tmp"
mkdir -p "$T/home" "$T/tmp" "$T/fakebin"
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/flags" "$H/state" "$H/locks" "$H/catalog"
: > "$H/env/global.env"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) printf 'cromford\n' ;;
  --*) ;;
  cromford) case "${2:-}" in repo) echo acme/cromford ;; board_prefix) echo - ;; esac ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
for s in bin/ticket-status-comment.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "the closure of $s did not install"
done
# Nothing reaches the network: gh and curl log and fail.
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$NETLOG"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$NETLOG"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The fake worker and the fake GitHub, sourced by the lane (sandbox seam
# TICKET_STATUS_COMMENT_FIXTURE) after its libs.
#   $FXT/state/<key>   <issue>\t<fingerprint>\t<state>: what the worker renders now
#   $FXT/rows/<key>    <comment_id>\t<fingerprint>: the worker's row
#   $FXT/due.down      GET due answers 503;  $FXT/delete.down: DELETE answers 503
#   $FXT/c/<id>        a comment on GitHub: <issue>\t<login>\t<type> on line 1, the body after it
#   $FXT/patch.rc      the rc of every PATCH (a 500 is rc 1)
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out k f issue fp st rid rfp q pk pc
  JOBS_HTTP=""; JOBS_BODY=""
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/jobs.log"
  case "$m ${p%%\?*}" in
    "GET /api/ticket-status-comments/due")
      [ -f "$FXT/due.down" ] && { JOBS_HTTP=503; return 1; }
      out='[]'
      for f in "$FXT"/state/*; do
        [ -f "$f" ] || continue
        k=${f##*/}; IFS=$'\t' read -r issue fp st < "$f"
        rid=""; rfp=""
        [ -f "$FXT/rows/$k" ] && IFS=$'\t' read -r rid rfp < "$FXT/rows/$k"
        [ -n "$rid" ] && [ "$rfp" = "$fp" ] && continue
        out=$(jq -c --arg k "$k" --argjson i "$issue" --arg fp "$fp" --arg s "$st" --arg id "$rid" --arg m "<!-- harness-status: ticket-status -->" \
          '. + [{key:$k, issue:$i, comment_id:(if $id == "" then null else ($id|tonumber) end), fingerprint:$fp, state:$s, final:false,
                 body:($m + "\n**Build status: " + $s + "**\n")}]' <<<"$out")
      done
      out=$(jq -c '{format:"ticket-status-comment v1", project:"cromford", repo:"acme/cromford", due:., scanned:(length), truncated:false}' <<<"$out") ;;
    "POST /api/ticket-status-comments")
      printf '%s\n' "$b" >> "$FXT/records.log"
      [ -f "$FXT/record.down" ] && { JOBS_HTTP=503; return 1; }
      printf '%s\t%s\n' "$(jq -r '.comment_id' <<<"$b")" "$(jq -r '.fingerprint // ""' <<<"$b")" > "$FXT/rows/$(jq -r '.ticket_key' <<<"$b")"
      out='{"ok":true}' ;;
    "DELETE /api/ticket-status-comments")
      [ -f "$FXT/delete.down" ] && { JOBS_HTTP=503; return 1; }
      q=${p#*\?}
      pk=$(sed -nE 's/(^|.*&)key=([^&]*).*/\2/p' <<<"$q"); pc=$(sed -nE 's/(^|.*&)comment_id=([^&]*).*/\2/p' <<<"$q")
      rid=""; [ -f "$FXT/rows/$pk" ] && IFS=$'\t' read -r rid rfp < "$FXT/rows/$pk"
      if [ -n "$rid" ] && [ "$rid" = "$pc" ]; then rm -f "$FXT/rows/$pk"; out='{"ok":true,"deleted":1}'; else out='{"ok":true,"deleted":0}'; fi ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=200; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" f="" id n page a
  printf '%s %s\n' "$m" "${p%%\?*}" >> "$FXT/ghrest.log"
  for a in "${@:3}"; do case "$a" in body=@*) f=${a#body=@} ;; esac; done
  case "$m $p" in
    PATCH\ repos/acme/cromford/issues/comments/*)
      id=${p##*/}
      [ -f "$FXT/patch.rc" ] && { GH_REST_STATUS=500; return "$(cat "$FXT/patch.rc")"; }
      [ -f "$FXT/c/$id" ] || { GH_REST_STATUS=404; return 44; }
      { head -n 1 "$FXT/c/$id"; cat "$f"; } > "$FXT/c/$id.new" && mv "$FXT/c/$id.new" "$FXT/c/$id"
      GH_REST_STATUS=200; printf '{"id":%s}' "$id"; return 0 ;;
    POST\ repos/acme/cromford/issues/*/comments)
      n=${p#repos/acme/cromford/issues/}; n=${n%/comments}
      id=$(( $(cat "$FXT/next.id") + 1 )); echo "$id" > "$FXT/next.id"
      { printf '%s\t%s\tBot\n' "$n" "cromford-board[bot]"; cat "$f"; } > "$FXT/c/$id"
      GH_REST_STATUS=201; printf '{"id":%s,"body":"x"}' "$id"; return 0 ;;
    GET\ repos/acme/cromford/issues/*/comments*)
      n=${p#repos/acme/cromford/issues/}; n=${n%%/*}
      page=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"$p")
      [ "$page" = 1 ] || { printf '[]'; GH_REST_STATUS=200; return 0; }
      for f in "$FXT"/c/*; do
        [ -f "$f" ] || continue
        IFS=$'\t' read -r ci cl ct < "$f"
        [ "$ci" = "$n" ] || continue
        jq -nc --argjson id "${f##*/}" --arg l "$cl" --arg t "$ct" --arg b "$(tail -n +2 "$f")" \
          '{id:$id, user:{login:$l, type:$t}, body:$b, created_at:"2026-11-26T10:00:00Z"}'
      done | jq -sc '.'
      GH_REST_STATUS=200; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
pl_token() { return 0; }
:
SH

export NETLOG="$T/net.log" HARNESS="$H" FXT="$T/fx" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret \
       LANE_GATE_DISABLE=1 HARNESS_TEST_SANDBOX=1 TICKET_STATUS_COMMENT_FIXTURE="$T/fx.sh" \
       HARNESS_SELF_APPS="cromford cromford-board cromford-builders" GH_TOKEN=ghs_fixture_token_1
LOG="$H/logs/ticket-status-comment.log"

# reset — a clean fake world for one case
reset() {
  rm -rf "$T/fx"; mkdir -p "$T/fx/c" "$T/fx/rows" "$T/fx/state"
  echo 8800000 > "$T/fx/next.id"
  rm -f "$LOG"
  clear_logs
}
# clear_logs — empty the call logs before one tick
clear_logs() { : > "$T/fx/ghrest.log"; : > "$T/fx/jobs.log"; : > "$T/fx/records.log"; }
# state <key> <issue> <fp> <state> — what the worker renders for the ticket now
state() { printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$T/fx/state/$1"; }
# rowfile <key> <id> <fp> — a row the worker already holds
rowfile() { printf '%s\t%s\n' "$2" "$3" > "$T/fx/rows/$1"; }
# comment <id> <issue> <body> — our App's comment on GitHub
comment() { printf '%s\t%s\tBot\n%s\n' "$2" "$APP" "$3" > "$T/fx/c/$1"; }
row() { cat "$T/fx/rows/$1" 2>/dev/null; }
run() { RC=0; clear_logs; bash "$H/bin/ticket-status-comment.sh" cromford > "$T/out" 2>&1 || RC=$?; }
calls() { grep -c "^$1 " "$T/fx/ghrest.log" 2>/dev/null || true; }
ghlog() { tr '\n' ';' < "$T/fx/ghrest.log"; }
last() { tail -n 1 "$LOG" 2>/dev/null; }

# ── S1: three ticks, same state: 0 GitHub calls after the first ───────────────
reset
state BH-10301 10301 aaaaaaaaaaaaaaaa queued
run
[ "$RC" = 0 ] && ok || bad "S1 tick 1 exits 0 (rc $RC: $(cat "$T/out"))"
[ "$(calls GET)" = 1 ] && [ "$(calls POST)" = 1 ] && [ "$(calls PATCH)" = 0 ] && ok \
  || bad "S1 tick 1: 1 GET (list) + 1 POST ($(ghlog))"
[ "$(row BH-10301)" = $'8800001\taaaaaaaaaaaaaaaa' ] && ok || bad "S1 tick 1 stores the id and the hash ('$(row BH-10301)')"
for tick in 2 3; do
  run
  [ ! -s "$T/fx/ghrest.log" ] && ok || bad "S1 tick $tick: 0 GitHub calls ($(ghlog))"
  [[ "$(last)" == *" due=0 patched=0 adopted=0 posted=0 failed=0 "* ]] && ok || bad "S1 tick $tick: nothing due ('$(last)')"
done

# ── S2: a state change: 1 PATCH, 0 GET ───────────────────────────────────────
state BH-10301 10301 bbbbbbbbbbbbbbbb running
run
[ "$(calls PATCH)" = 1 ] && [ "$(calls GET)" = 0 ] && [ "$(calls POST)" = 0 ] && ok \
  || bad "S2 a change: 1 PATCH, 0 GET, 0 POST ($(ghlog))"
grep -q '^PATCH repos/acme/cromford/issues/comments/8800001$' "$T/fx/ghrest.log" && ok || bad "S2 the PATCH edits 8800001"
[ "$(row BH-10301)" = $'8800001\tbbbbbbbbbbbbbbbb' ] && ok || bad "S2 the row holds the new hash ('$(row BH-10301)')"
grep -q 'Build status: running' "$T/fx/c/8800001" && ok || bad "S2 the comment reads running"
[[ "$(last)" == *" due=1 patched=1 adopted=0 posted=0 failed=0 "* ]] && ok || bad "S2 summary ('$(last)')"

# ── S3: the comment was deleted: DELETE the row, 1 POST, 0 GET ───────────────
reset
state BH-10302 10302 cccccccccccccccc running
rowfile BH-10302 8700001 1111111111111111      # c/8700001 does not exist: PATCH answers 404
run
[ "$RC" = 0 ] && ok || bad "S3 exits 0 (rc $RC)"
[ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 1 ] && [ "$(calls GET)" = 0 ] && ok \
  || bad "S3 a 404: 1 PATCH, 1 POST, 0 GET ($(ghlog))"
[ "$(grep -c '^DELETE /api/ticket-status-comments?project=cromford&key=BH-10302&comment_id=8700001 ' "$T/fx/jobs.log")" = 1 ] && ok \
  || bad "S3 one compare-and-delete of the row ($(tr '\n' ';' < "$T/fx/jobs.log"))"
d=$(grep -n '^DELETE ' "$T/fx/jobs.log" | cut -d: -f1); r=$(grep -n '^POST /api/ticket-status-comments ' "$T/fx/jobs.log" | cut -d: -f1)
[ -n "$d" ] && [ -n "$r" ] && [ "$d" -lt "$r" ] && ok || bad "S3 the DELETE comes before the record"
[ "$(row BH-10302)" = $'8800001\tcccccccccccccccc' ] && ok || bad "S3 the row names the new comment ('$(row BH-10302)')"
[[ "$(last)" == *" due=1 patched=0 adopted=0 posted=1 failed=0 truncated=0" ]] && ok || bad "S3 summary posted=1 ('$(last)')"
run
[ ! -s "$T/fx/ghrest.log" ] && ok || bad "S3 the next tick: 0 GitHub calls ($(ghlog))"

# ── S4: a failed PATCH keeps the old hash; the next tick PATCHes again ───────
reset
state BH-10303 10303 dddddddddddddddd running
rowfile BH-10303 8700002 2222222222222222
comment 8700002 10303 "$MARK"
echo 1 > "$T/fx/patch.rc"
run
[ "$(calls PATCH)" = 1 ] && [ "$(calls GET)" = 0 ] && [ "$(calls POST)" = 0 ] && ok || bad "S4 one PATCH, no read, no POST ($(ghlog))"
[ ! -s "$T/fx/records.log" ] && ok || bad "S4 nothing is recorded ($(cat "$T/fx/records.log"))"
[ "$(row BH-10303)" = $'8700002\t2222222222222222' ] && ok || bad "S4 the row keeps the old hash ('$(row BH-10303)')"
[[ "$(last)" == *" patched=0 adopted=0 posted=0 failed=1 "* ]] && ok || bad "S4 failed=1 ('$(last)')"
rm -f "$T/fx/patch.rc"
run
[ "$(calls PATCH)" = 1 ] && [ "$(calls GET)" = 0 ] && [ "$(calls POST)" = 0 ] && ok || bad "S4 the next tick PATCHes again, 0 GET ($(ghlog))"
[ "$(row BH-10303)" = $'8700002\tdddddddddddddddd' ] && ok || bad "S4 the retry stores the new hash ('$(row BH-10303)')"

# ── S5: no row, our comment exists, its PATCH fails: the id is still stored ──
reset
state BH-10304 10304 eeeeeeeeeeeeeeee running
comment 8700003 10304 "$MARK"
echo 1 > "$T/fx/patch.rc"
run
[ "$(calls GET)" = 1 ] && [ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 0 ] && ok || bad "S5 tick 1: 1 GET, 1 PATCH, 0 POST ($(ghlog))"
[ "$(row BH-10304)" = $'8700003\t' ] && ok || bad "S5 tick 1 stores the found id with an empty hash ('$(row BH-10304)')"
[ "$(head -n 1 "$T/fx/records.log" | jq -r '.fingerprint, .final' 2>/dev/null | tr '\n' ' ')" = "null false " ] && ok \
  || bad "S5 the pre-record sends fingerprint null, final false ($(cat "$T/fx/records.log"))"
[[ "$(last)" == *" patched=0 adopted=0 posted=0 failed=1 "* ]] && ok || bad "S5 failed=1 ('$(last)')"
rm -f "$T/fx/patch.rc"
run
[ "$(calls GET)" = 0 ] && [ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 0 ] && ok || bad "S5 tick 2: 0 GET, 1 PATCH ($(ghlog))"
grep -q '^PATCH repos/acme/cromford/issues/comments/8700003$' "$T/fx/ghrest.log" && ok || bad "S5 tick 2 edits the stored id"
[ "$(row BH-10304)" = $'8700003\teeeeeeeeeeeeeeee' ] && ok || bad "S5 tick 2 stores the hash ('$(row BH-10304)')"
# The adopt path that succeeds still makes 1 GET + 1 PATCH and ends with the real hash.
reset
state BH-10305 10305 ffffffffffffffff queued
comment 8700004 10305 "$MARK"
run
[ "$(calls GET)" = 1 ] && [ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 0 ] && ok || bad "S5 adopt: 1 GET, 1 PATCH ($(ghlog))"
[ "$(row BH-10305)" = $'8700004\tffffffffffffffff' ] && ok || bad "S5 adopt ends with the real hash ('$(row BH-10305)')"
[[ "$(last)" == *" patched=0 adopted=1 posted=0 failed=0 "* ]] && ok || bad "S5 adopted=1 ('$(last)')"
# A pre-record that fails: no PATCH, nothing written to GitHub.
reset
state BH-10306 10306 1212121212121212 queued
comment 8700005 10306 "$MARK"
: > "$T/fx/record.down"
run
[ "$(calls GET)" = 1 ] && [ "$(calls PATCH)" = 0 ] && [ "$(calls POST)" = 0 ] && ok || bad "S5 a failed pre-record: no PATCH, no POST ($(ghlog))"
[[ "$(last)" == *" patched=0 adopted=0 posted=0 failed=1 "* ]] && ok || bad "S5 a failed pre-record counts failed ('$(last)')"

# ── S6: the DELETE after a 404 fails: no POST ────────────────────────────────
reset
state BH-10307 10307 3434343434343434 running
rowfile BH-10307 8700006 5656565656565656
: > "$T/fx/delete.down"
run
[ "$RC" = 0 ] && ok || bad "S6 exits 0 (rc $RC)"
[ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 0 ] && [ "$(calls GET)" = 0 ] && ok || bad "S6 no POST, no read ($(ghlog))"
[ "$(row BH-10307)" = $'8700006\t5656565656565656' ] && ok || bad "S6 the row is unchanged ('$(row BH-10307)')"
[[ "$(last)" == *" patched=0 adopted=0 posted=0 failed=1 truncated=0" ]] && ok || bad "S6 posted=0 failed=1 ('$(last)')"

# ── S7: the due read fails: unknown, not "no change" ─────────────────────────
reset
state BH-10308 10308 7878787878787878 queued
: > "$T/fx/due.down"
run
[ "$RC" = 0 ] && [ ! -s "$T/fx/ghrest.log" ] && ok || bad "S7 0 GitHub calls (rc $RC, $(ghlog))"
[ -z "$(ls "$T/fx/rows")" ] && ok || bad "S7 no row written"
grep -q 'did not answer the due list' "$LOG" && ok || bad "S7 the log names the worker ('$(last)')"

[ ! -s "$NETLOG" ] && ok || bad "no network call in any case ($(cat "$NETLOG"))"

# ── W: the worker half (DELETE route, null fingerprint), its own node suite ──
WORKER_T="$SRC/worker/jobs/test/ticket-status-comment.bh-10216.test.js"
[ -f "$WORKER_T" ] && ok || bad "missing ${WORKER_T#"$SRC"/}"
if [ -f "$SRC/catalog/lanes.json" ] && [ -f "$SRC/catalog/llm-sites.json" ] && command -v node >/dev/null; then
  (cd "$SRC/worker/jobs" && node --test "$WORKER_T" > "$T/node.out" 2>&1) && ok || bad "the worker suite ($(grep -E '^not ok|^# fail' "$T/node.out"))"
else
  echo "skip: the worker suite needs the composed catalogs (bin/lanes-build.sh --write, bin/llm-sites-build.sh --compose)"
fi
echo "ticket-status-comment-state (BH-10216): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
