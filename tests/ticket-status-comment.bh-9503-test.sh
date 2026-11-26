#!/bin/bash
# tests/ticket-status-comment.bh-9503-test.sh — BH-9503 (C1 of #8973): the hub
# lane bin/ticket-status-comment.sh keeps ONE status comment per ticket and
# edits it in place at each state change. The worker says which tickets are due
# (worker/jobs/src/routes/ticket-status-comment.js, its own node suite
# worker/jobs/test/ticket-status-comment.bh-9503.test.js); this suite pins the
# lane against a fake worker and a fake GitHub (gh_rest), 0 network calls.
#
#   L1  first run POSTs one comment and records its id; the next change PATCHes
#       that id; the POST count stays 1
#   L2  disabled, off flag, project not watched, in-app board, no App token:
#       exit 0, zero gh calls, zero worker calls, one log line each
#   L3  a PATCH that answers rc 75 stops the tick: no record POST, failed=1
#   L4  adopt: our App's marked comment on page 2 is PATCHed (the newest), no POST
#   L5  adopt negatives: a person, a third-party bot, another marker, the marker
#       on line 2, the marker with trailing text: none PATCHed, one POST
#   L6  the record POST fails after a GitHub POST; the next run adopts and
#       PATCHes the same comment; total POSTs 1
#   L7  the worker answers 503: exit 0, zero gh calls
#   L8  the worker's real renderBody output, as our App's edited comment, is a
#       status comment to ptg_classify (rc 0, 1 skipped); without the catalog
#       line it would refuse the plan
#   L9  the summary line carries due= patched= adopted= posted= failed= truncated=
#   L10 --dispatch starts the project runs through pl_dispatch
#   L11 a POST answer with no comment id: failed=1, nothing recorded
#   L12 a PATCH that fails with an rc other than 44 or 75: failed=1, no adopt, no POST
#   L13 a comment POST that answers rc 75 stops the tick: nothing recorded
# Files under test: "$SRC/bin/ticket-status-comment.sh",
# "$SRC/worker/jobs/src/routes/ticket-status-comment.js",
# "$SRC/worker/jobs/src/routes/retention.d/bh-9503-ticket-status-comments.js",
# "$SRC/worker/jobs/src/lib/core.d/bh-9503-ticket-status-comment.js",
# "$SRC/catalog/plan-thread-status-markers.txt".
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ticket-status-comment.bh-9503-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE_SRC="$SRC/bin/ticket-status-comment.sh"
ROUTE_SRC="$SRC/worker/jobs/src/routes/ticket-status-comment.js"
RET_SRC="$SRC/worker/jobs/src/routes/retention.d/bh-9503-ticket-status-comments.js"
for f in "$LANE_SRC" "$ROUTE_SRC" "$RET_SRC"; do
  [ -f "$f" ] && ok || bad "missing ${f#"$SRC"/}"
done
grep -q "retention.ticket_status_comments.days" "$RET_SRC" 2>/dev/null && ok || bad "the retention rule reads retention.ticket_status_comments.days"
CORE_SRC="$SRC/worker/jobs/src/lib/core.d/bh-9503-ticket-status-comment.js"
grep -q "idx_build_queue_project_updated ON build_queue(project, updated_at)" "$CORE_SRC" 2>/dev/null && ok \
  || bad "core.d/bh-9503-ticket-status-comment.js adds the (project, updated_at) index the recent read uses"

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
  --projects) printf 'cromford\nproject-3\n' ;;
  --*) ;;
  cromford) case "${2:-}" in repo) echo acme/cromford ;; board_prefix) echo - ;; esac ;;
  project-3) case "${2:-}" in repo) echo acme/project-3 ;; board_prefix) echo FR ;; esac ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
for s in bin/ticket-status-comment.sh bin/jobs-client.sh bin/lib/plan-thread.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "the closure of $s did not install"
done
cp "$SRC/catalog/plan-thread-status-markers.txt" "$H/catalog/" 2>/dev/null || bad "cannot copy the markers catalog"
# Nothing reaches the network: gh and curl log and fail.
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The fake worker and the fake GitHub. Sourced by the lane (sandbox seam
# TICKET_STATUS_COMMENT_FIXTURE) after its libs.
#   $FXT/due.json        the due entries the worker answers (comment_id is
#                        filled from $FXT/rows/<key> when a record exists)
#   $FXT/rows/<key>      the recorded comment id (the worker's table)
#   $FXT/jobs.down       GET due answers 503;  $FXT/record.down: POST answers 503
#   $FXT/c/<id>          a comment on GitHub: <issue>\t<login>\t<type> on line 1, the body after it
#   $FXT/patch.rc        the rc of every PATCH (75 = a 500 or a rate limit)
#   $FXT/post.rc         the rc of every comment POST
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out k
  JOBS_HTTP=""; JOBS_BODY=""
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/jobs.log"
  case "$m ${p%%\?*}" in
    "GET /api/ticket-status-comments/due")
      [ -f "$FXT/jobs.down" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c --arg rows "$FXT/rows" '.' "$FXT/due.json")
      for k in $(jq -r '.due[].key' <<<"$out"); do
        [ -f "$FXT/rows/$k" ] && out=$(jq -c --arg k "$k" --argjson id "$(cat "$FXT/rows/$k")" \
          '.due |= map(if .key == $k then .comment_id = $id else . end)' <<<"$out")
      done ;;
    "POST /api/ticket-status-comments")
      printf '%s\n' "$b" >> "$FXT/records.log"
      [ -f "$FXT/record.down" ] && { JOBS_HTTP=503; return 1; }
      mkdir -p "$FXT/rows"
      jq -r '.comment_id' <<<"$b" > "$FXT/rows/$(jq -r '.ticket_key' <<<"$b")"
      out='{"ok":true}' ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=200; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" f id n page body
  printf '%s %s %s\n' "$m" "$p" "${*:3}" >> "$FXT/ghrest.log"
  for a in "${@:3}"; do case "$a" in body=@*) f=${a#body=@} ;; esac; done
  mkdir -p "$FXT/c"
  case "$m $p" in
    PATCH\ repos/acme/cromford/issues/comments/*)
      id=${p##*/}
      [ -f "$FXT/patch.rc" ] && { GH_REST_STATUS=500; return "$(cat "$FXT/patch.rc")"; }
      [ -f "$FXT/c/$id" ] || { GH_REST_STATUS=404; return 44; }
      { head -n 1 "$FXT/c/$id"; cat "$f"; } > "$FXT/c/$id.new" && mv "$FXT/c/$id.new" "$FXT/c/$id"
      GH_REST_STATUS=200; printf '{"id":%s}' "$id"; return 0 ;;
    POST\ repos/acme/cromford/issues/*/comments)
      n=${p#repos/acme/cromford/issues/}; n=${n%/comments}
      [ -f "$FXT/post.rc" ] && { GH_REST_STATUS=500; return "$(cat "$FXT/post.rc")"; }
      id=$((8000000 + $(grep -c '^POST ' "$FXT/ghrest.log")))
      { printf '%s\t%s\tBot\n' "$n" "cromford-board[bot]"; cat "$f"; } > "$FXT/c/$id"
      GH_REST_STATUS=201
      if [ -f "$FXT/post.noid" ]; then printf '{"body":"x"}'; else printf '{"id":%s,"body":"x"}' "$id"; fi
      return 0 ;;
    GET\ repos/acme/cromford/issues/*/comments*)
      n=${p#repos/acme/cromford/issues/}; n=${n%%/*}
      page=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"$p")
      [ -f "$FXT/get.rc" ] && { GH_REST_STATUS=500; return "$(cat "$FXT/get.rc")"; }
      if [ -f "$FXT/pages/$n-$page.json" ]; then cat "$FXT/pages/$n-$page.json"; GH_REST_STATUS=200; return 0; fi
      [ "$page" = 1 ] || { printf '[]'; GH_REST_STATUS=200; return 0; }
      # page 1 with no fixture: the comments posted on this issue
      for f in "$FXT"/c/*; do
        [ -f "$f" ] || continue
        IFS=$'\t' read -r ci cl ct < "$f"
        [ "$ci" = "$n" ] || continue
        jq -nc --argjson id "${f##*/}" --arg l "$cl" --arg t "$ct" --arg b "$(tail -n +2 "$f")" \
          '{id:$id, user:{login:$l, type:$t}, body:$b, created_at:"2026-11-11T12:00:00Z"}'
      done | jq -sc '.'
      GH_REST_STATUS=200; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
pl_token() { return 0; }
pl_dispatch() { printf 'pl_dispatch %s\n' "$*" >> "$FXT/dispatch.log"; echo "$1 dispatch: started 2 project run(s)"; }
:
SH

export HARNESS="$H" FXT="$T/fx" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret \
       LANE_GATE_DISABLE=1 HARNESS_TEST_SANDBOX=1 TICKET_STATUS_COMMENT_FIXTURE="$T/fx.sh" \
       HARNESS_SELF_APPS="cromford cromford-board cromford-builders" GH_TOKEN=ghs_fixture_token_1
LOG="$H/logs/ticket-status-comment.log"

# reset — a clean fake world for one case
reset() {
  rm -rf "$T/fx"; mkdir -p "$T/fx/c" "$T/fx/rows" "$T/fx/pages"
  : > "$T/fx/ghrest.log"; : > "$T/fx/jobs.log"; : > "$T/fx/records.log"; : > "$T/fx/net.log"
  rm -f "$LOG" "$H/flags/lane-off-ticket-status-comment"
}
# due_entry <key> <issue> <fp> <state> [final] — one entry of the due answer
due_entry() {
  jq -nc --arg k "$1" --argjson i "$2" --arg fp "$3" --arg s "$4" --argjson f "${5:-false}" --arg m "$MARK" \
    '{key:$k, issue:$i, comment_id:null, fingerprint:$fp, state:$s, final:$f,
      body:($m + "\n**Build status: " + $s + "**\n\nUpdated 2026-11-11 12:00Z. The harness edits this comment at each state change.\n")}'
}
# due_file <truncated> <entry>... — the worker's answer
due_file() {
  local tr="$1"; shift
  printf '%s\n' "$@" | jq -sc --argjson tr "$tr" \
    '{format:"ticket-status-comment v1", project:"cromford", repo:"acme/cromford", fresh_at:"2026-11-11T12:00:00Z", due:., scanned:(length), truncated:$tr}' \
    > "$T/fx/due.json"
}
run() { RC=0; bash "$H/bin/ticket-status-comment.sh" "$@" > "$T/out" 2>&1 || RC=$?; }
calls() { grep -c "^$1 " "$T/fx/ghrest.log" 2>/dev/null || true; }
cm() { # cm <id> <login> <type> <body> — one REST comment
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg b "$4" '{id:$id, user:{login:$l, type:$t}, body:$b, created_at:"2026-11-10T10:00:00Z"}'
}
NL=$'\n'

# ── L1 + L9: POST once, then PATCH that id ───────────────────────────────────
reset
due_file false "$(due_entry BH-9001 9001 aaaaaaaaaaaaaaaa queued)"
run cromford
[ "$RC" = 0 ] && ok || bad "L1 first run exits 0 (rc $RC: $(cat "$T/out"))"
[ "$(calls POST)" = 1 ] && [ "$(calls PATCH)" = 0 ] && ok || bad "L1 first run POSTs one comment ($(cat "$T/fx/ghrest.log"))"
grep -q '^POST repos/acme/cromford/issues/9001/comments ' "$T/fx/ghrest.log" && ok || bad "L1 the POST goes to issue 9001"
grep -q -- "-F body=@" "$T/fx/ghrest.log" && ok || bad "L1 the body rides as a file (-F body=@<file>)"
[ "$(head -n 2 "$T/fx/c/8000001" 2>/dev/null | tail -n 1)" = "$MARK" ] && ok || bad "L1 the posted body starts with the marker"
rec=$(tail -n 1 "$T/fx/records.log")
[ "$(jq -r '[.project, .ticket_key, .issue, .comment_id, .fingerprint, .state, .final] | @tsv' <<<"$rec" 2>/dev/null)" \
  = $'cromford\tBH-9001\t9001\t8000001\taaaaaaaaaaaaaaaa\tqueued\tfalse' ] && ok || bad "L1 the record names the new comment id and fp ($rec)"
summary=$(tail -n 1 "$LOG" 2>/dev/null)
[[ "$summary" =~ project=cromford\ due=1\ patched=0\ adopted=0\ posted=1\ failed=0\ truncated=0$ ]] && ok \
  || bad "L9 the summary line ('$summary')"
[ "$(wc -l < "$LOG")" = 1 ] && ok || bad "L9 one summary line per run"
due_file true "$(due_entry BH-9001 9001 bbbbbbbbbbbbbbbb running)"
run cromford
[ "$(calls POST)" = 1 ] && [ "$(calls PATCH)" = 1 ] && ok || bad "L1 the next change PATCHes, POST count stays 1 ($(cat "$T/fx/ghrest.log"))"
grep -q '^PATCH repos/acme/cromford/issues/comments/8000001 ' "$T/fx/ghrest.log" && ok || bad "L1 the PATCH edits comment 8000001"
grep -q 'Build status: running' "$T/fx/c/8000001" && ok || bad "L1 the comment now reads running"
[ "$(tail -n 1 "$T/fx/records.log" | jq -r '.fingerprint + " " + (.comment_id|tostring)')" = "bbbbbbbbbbbbbbbb 8000001" ] && ok \
  || bad "L1 the edit is recorded with the new fp"
[[ "$(tail -n 1 "$LOG")" == *" due=1 patched=1 adopted=0 posted=0 failed=0 truncated=1" ]] && ok || bad "L9 truncated=1 carried ('$(tail -n 1 "$LOG")')"
[ ! -s "$T/fx/net.log" ] && ok || bad "L1 no network call ($(cat "$T/fx/net.log"))"

# ── L2: every quiet exit ─────────────────────────────────────────────────────
quiet() { # quiet <label> <expected log word> <args...>
  local label="$1" word="$2"; shift 2
  run "$@"
  [ "$RC" = 0 ] && ok || bad "L2 $label exits 0 (rc $RC: $(cat "$T/out"))"
  [ ! -s "$T/fx/ghrest.log" ] && [ ! -s "$T/fx/jobs.log" ] && ok || bad "L2 $label: zero gh and worker calls ($(cat "$T/fx/ghrest.log" "$T/fx/jobs.log"))"
  [ "$(wc -l < "$LOG" 2>/dev/null)" = 1 ] && grep -q "$word" "$LOG" && ok || bad "L2 $label: one log line with '$word' ($(cat "$LOG" 2>/dev/null))"
}
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
TICKET_STATUS_COMMENT_ENABLED=0 quiet disabled disabled cromford
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"; : > "$H/flags/lane-off-ticket-status-comment"
quiet "off flag" off cromford
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
quiet "not watched (default self)" "not watched" project-3
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
TICKET_STATUS_COMMENT_PROJECTS=all quiet "in-app board" "not a GitHub-issues board" project-3
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
GH_TOKEN=ghp_fixture_pat_1 quiet "a PAT, not an App token" "no App token" cromford
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
GH_TOKEN='' quiet "no token" "no App token" cromford
# The positive control for the watch list: a listed project runs.
reset; due_file false "$(due_entry BH-9002 9002 aaaaaaaaaaaaaaaa queued)"
TICKET_STATUS_COMMENT_PROJECTS=cromford,project-4 run cromford
[ "$(calls POST)" = 1 ] && ok || bad "L2 a comma list that names the project runs it"
reset
run 'bad name!'
[ "$RC" = 2 ] && [ ! -s "$T/fx/jobs.log" ] && ok || bad "L2 a bad project name exits 2 before any request (rc $RC)"

# ── L3: PATCH rc 75 stops the tick ───────────────────────────────────────────
reset
printf '%s\t%s\tBot\n%s\n' 9003 "$APP" "$MARK" > "$T/fx/c/8100001"; echo 8100001 > "$T/fx/rows/BH-9003"
echo 75 > "$T/fx/patch.rc"
due_file false "$(due_entry BH-9003 9003 cccccccccccccccc running)" "$(due_entry BH-9004 9004 dddddddddddddddd queued)"
run cromford
[ "$RC" = 0 ] && ok || bad "L3 exits 0 (rc $RC)"
[ "$(calls PATCH)" = 1 ] && [ "$(calls POST)" = 0 ] && [ "$(calls GET)" = 0 ] && ok || bad "L3 the tick stops after the failed PATCH ($(cat "$T/fx/ghrest.log"))"
[ ! -s "$T/fx/records.log" ] && ok || bad "L3 nothing is recorded ($(cat "$T/fx/records.log"))"
[[ "$(tail -n 1 "$LOG")" == *" due=2 patched=0 adopted=0 posted=0 failed=1 truncated=0 stopped=rc75-patch:BH-9003" ]] && ok || bad "L3 failed=1, stopped names the PATCH ('$(tail -n 1 "$LOG")')"
[ "$(wc -l < "$LOG")" = 1 ] && ok || bad "L3 one summary line"

# ── L12: a PATCH that fails with an rc other than 44 or 75 never POSTs ──────
reset
printf '%s\t%s\tBot\n%s\n' 9011 "$APP" "$MARK" > "$T/fx/c/8110001"; echo 8110001 > "$T/fx/rows/BH-9011"
echo 2 > "$T/fx/patch.rc"
due_file false "$(due_entry BH-9011 9011 6666666666666666 running)" "$(due_entry BH-9012 9012 7777777777777777 queued)"
run cromford
[ "$RC" = 0 ] && ok || bad "L12 exits 0 (rc $RC)"
[ "$(grep -c '^PATCH repos/acme/cromford/issues/comments/8110001 ' "$T/fx/ghrest.log")" = 1 ] && ok || bad "L12 the PATCH ran once"
! grep -q 'issues/9011/comments' "$T/fx/ghrest.log" && ok || bad "L12 no adopt read and no POST on issue 9011 ($(cat "$T/fx/ghrest.log"))"
grep -q '^POST repos/acme/cromford/issues/9012/comments ' "$T/fx/ghrest.log" && ok || bad "L12 the next ticket still runs"
[ "$(jq -r '.ticket_key' "$T/fx/records.log" | tr '\n' ' ')" = "BH-9012 " ] && ok || bad "L12 only the next ticket is recorded ($(cat "$T/fx/records.log"))"
[[ "$(tail -n 1 "$LOG")" == *" due=2 patched=0 adopted=0 posted=1 failed=1 truncated=0" ]] && ok || bad "L12 failed=1, no stop ('$(tail -n 1 "$LOG")')"

# ── L13: a POST that answers rc 75 stops the tick ──────────────────────────
reset
echo 75 > "$T/fx/post.rc"
due_file false "$(due_entry BH-9013 9013 8888888888888888 queued)" "$(due_entry BH-9014 9014 9999999999999999 queued)"
run cromford
[ "$RC" = 0 ] && ok || bad "L13 exits 0 (rc $RC)"
[ "$(calls POST)" = 1 ] && ! grep -q 'issues/9014/' "$T/fx/ghrest.log" && ok || bad "L13 the tick stops at the first POST ($(cat "$T/fx/ghrest.log"))"
[ ! -s "$T/fx/records.log" ] && ok || bad "L13 nothing is recorded ($(cat "$T/fx/records.log"))"
[[ "$(tail -n 1 "$LOG")" == *" due=2 patched=0 adopted=0 posted=0 failed=1 truncated=0 stopped=rc75-post:BH-9013" ]] && ok || bad "L13 stopped names the POST ('$(tail -n 1 "$LOG")')"

# ── L4: adopt our marked comment on page 2 ──────────────────────────────────
reset
{ for i in $(seq 1 99); do cm $((8200100 + i)) client-person User "comment $i"; done
  cm 8200001 "$APP" Bot "${MARK}${NL}**Build status: queued**"; } | jq -sc '.' > "$T/fx/pages/9005-1.json"
cm 8200002 "$APP" Bot "${NL}${MARK}${NL}**Build status: spawning**" | jq -sc '.' > "$T/fx/pages/9005-2.json"
for id in 8200001 8200002; do printf '9005\t%s\tBot\nold\n' "$APP" > "$T/fx/c/$id"; done
due_file false "$(due_entry BH-9005 9005 eeeeeeeeeeeeeeee running)"
run cromford
[ "$(calls POST)" = 0 ] && ok || bad "L4 no POST when a marked comment of ours exists ($(cat "$T/fx/ghrest.log"))"
grep -q '^PATCH repos/acme/cromford/issues/comments/8200002 ' "$T/fx/ghrest.log" && [ "$(calls PATCH)" = 1 ] && ok \
  || bad "L4 the newest marked comment (page 2) is PATCHed ($(cat "$T/fx/ghrest.log"))"
grep -q 'issues/9005/comments?per_page=100&page=2' "$T/fx/ghrest.log" && ok || bad "L4 page 2 is read"
[ "$(jq -r '.comment_id' <<<"$(tail -n 1 "$T/fx/records.log")")" = 8200002 ] && ok || bad "L4 the adopted id is recorded"
[[ "$(tail -n 1 "$LOG")" == *" patched=0 adopted=1 posted=0 failed=0 "* ]] && ok || bad "L4 adopted=1 ('$(tail -n 1 "$LOG")')"
# The page cap is the knob: with 1 page the page-2 comment is not read.
rm -f "$T/fx/rows/BH-9005"; : > "$T/fx/ghrest.log"
TICKET_STATUS_COMMENT_ADOPT_PAGES=1 run cromford
! grep -q 'page=2' "$T/fx/ghrest.log" && ok || bad "L4 TICKET_STATUS_COMMENT_ADOPT_PAGES=1 reads page 1 only ($(cat "$T/fx/ghrest.log"))"

# ── L5: adopt negatives ─────────────────────────────────────────────────────
reset
{ cm 8300001 client-person User "${MARK}${NL}quoted by a person"
  cm 8300002 'coderabbitai[bot]' Bot "${MARK}${NL}a third-party bot"
  cm 8300003 "$APP" Bot "<!-- harness-status: board-closeout -->${NL}Built and opened for review."
  cm 8300004 "$APP" Bot "Status:${NL}${MARK}"
  cm 8300005 "$APP" Bot "${MARK} HOLD${NL}trailing text"
  cm 8300006 cromford-builders Bot "${MARK}" | jq -c '.user.type = "User"'; } | jq -sc '.' > "$T/fx/pages/9006-1.json"
due_file false "$(due_entry BH-9006 9006 ffffffffffffffff queued)"
run cromford
[ "$(calls PATCH)" = 0 ] && ok || bad "L5 no negative is PATCHed ($(cat "$T/fx/ghrest.log"))"
[ "$(calls POST)" = 1 ] && ok || bad "L5 one POST"

# ── L6: the record fails after a POST; the next run adopts the same comment ──
reset
due_file false "$(due_entry BH-9007 9007 1111111111111111 queued)"
: > "$T/fx/record.down"
run cromford
[ "$RC" = 0 ] && [ "$(calls POST)" = 1 ] && ok || bad "L6 first run POSTs (rc $RC)"
[[ "$(tail -n 1 "$LOG")" == *" posted=1 failed=1 "* ]] && ok || bad "L6 posted=1 failed=1 ('$(tail -n 1 "$LOG")')"
rm -f "$T/fx/record.down"
due_file false "$(due_entry BH-9007 9007 2222222222222222 spawning)"
run cromford
[ "$(calls POST)" = 1 ] && ok || bad "L6 the second run makes no second POST ($(cat "$T/fx/ghrest.log"))"
grep -q '^PATCH repos/acme/cromford/issues/comments/8000001 ' "$T/fx/ghrest.log" && ok || bad "L6 the second run PATCHes the comment it posted"
[ "$(tail -n 1 "$T/fx/records.log" | jq -r '.comment_id')" = 8000001 ] && ok || bad "L6 the record now holds that comment"
# A thread that cannot be read is never a reason to POST a second comment.
reset
due_file false "$(due_entry BH-9008 9008 3333333333333333 queued)"
echo 75 > "$T/fx/get.rc"
run cromford
[ "$(calls POST)" = 0 ] && [ ! -s "$T/fx/records.log" ] && ok || bad "L6 an unreadable thread stops the tick, no blind POST ($(cat "$T/fx/ghrest.log"))"

# ── L11: a POST answer with no comment id is never recorded ────────────────
reset
due_file false "$(due_entry BH-9010 9010 5555555555555555 queued)"
: > "$T/fx/post.noid"
run cromford
[ "$RC" = 0 ] && [ "$(calls POST)" = 1 ] && ok || bad "L11 one POST (rc $RC)"
[ ! -s "$T/fx/records.log" ] && ok || bad "L11 no record without a comment id ($(cat "$T/fx/records.log"))"
[[ "$(tail -n 1 "$LOG")" == *" posted=1 failed=1 "* ]] && ok || bad "L11 counted failed ('$(tail -n 1 "$LOG")')"

# ── L7: the worker answers 503 ──────────────────────────────────────────────
reset
due_file false "$(due_entry BH-9009 9009 4444444444444444 queued)"
: > "$T/fx/jobs.down"
run cromford
[ "$RC" = 0 ] && [ ! -s "$T/fx/ghrest.log" ] && ok || bad "L7 a 503 makes no GitHub call (rc $RC, $(cat "$T/fx/ghrest.log"))"
grep -q "worker" "$LOG" && [ "$(wc -l < "$LOG")" = 1 ] && ok || bad "L7 one log line names the worker ($(cat "$LOG" 2>/dev/null))"

# ── L8: the real body is a status comment to the plan-thread gate ───────────
BODY=$(node --input-type=module -e '
  const { renderBody } = await import(process.argv[1]);
  process.stdout.write(renderBody({ key: "BH-8973", issue: 8973, state: "running", stage: "execute", rung: null,
    machine: "m-fixture-1", spawned_at: "2026-11-11T11:00:00Z", pr: null,
    attempts: [{ status: "running", started_at: "2026-11-11T11:00:00Z", ended_at: null, outcome: null }],
    waits_on: [], hold: null }, "2026-11-11T12:00:00Z"));' "$ROUTE_SRC" 2>/dev/null)
[ "$(head -n 1 <<<"$BODY")" = "$MARK" ] && ok || bad "L8 renderBody's line 1 is the marker ('$(head -n 1 <<<"$BODY")')"
printf '# Plan\n\nnone\n' > "$T/plan.md"
COMMENTS=$(jq -nc --arg b "$BODY" --arg l "$APP" \
  '[{id: 9503001, node_id: "IC_fixture9503001", user: {login: $l, type: "Bot"}, created_at: "2026-11-11T10:00:00Z", updated_at: "2026-11-11T12:00:00Z", body: $b}]')
classify() { OUT=$(HARNESS="$H" PTG_STATUS_MARKERS="$1" bash -c '. "$1"; ptg_classify "$2" "$3" "$4" "$5"' _ \
  "$H/bin/lib/plan-thread.sh" "$T/plan.md" 2026-11-11T11:30:00Z "$COMMENTS" '["cromford-board"]' 2>/dev/null); RC=$?; }
classify "$H/catalog/plan-thread-status-markers.txt"
[ "$RC" = 0 ] && [[ "$OUT" == *", 1 status comment(s) skipped" ]] && ok || bad "L8 the edited status comment is skipped (rc $RC, '$OUT')"
grep -v 'harness-status: ticket-status' "$H/catalog/plan-thread-status-markers.txt" > "$T/no-line.txt"
classify "$T/no-line.txt"
[ "$RC" = 1 ] && ok || bad "L8 without the catalog line the same edit refuses the plan (rc $RC, '$OUT')"

# ── L10: --dispatch ─────────────────────────────────────────────────────────
reset
run --dispatch
[ "$RC" = 0 ] && grep -q "^pl_dispatch ticket-status-comment 240 $H/bin/ticket-status-comment.sh\$" "$T/fx/dispatch.log" 2>/dev/null && ok \
  || bad "L10 --dispatch calls pl_dispatch with the lane, the spread and the script (rc $RC, $(cat "$T/fx/dispatch.log" 2>/dev/null))"
[ ! -s "$T/fx/jobs.log" ] && [ ! -s "$T/fx/ghrest.log" ] && ok || bad "L10 the dispatcher reads nothing"

echo "ticket-status-comment (BH-9503): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
