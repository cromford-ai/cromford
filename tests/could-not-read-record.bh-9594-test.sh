#!/bin/bash
# tests/could-not-read-record.bh-9594-test.sh — BH-9594 (BH-9555, order 1 of
# 2): a failed GitHub read is a "could not read", never a fact, and a lane that
# gets one records it against the box.
#
# bin/lib/could-not-read.sh classifies an HTTP answer (cnr_classify_status) and
# a free-text skip reason (cnr_classify_text), and cnr_record POSTs one row to
# the REAL jobs worker route /api/box-read-failures. Here that worker runs on a
# node:sqlite file through tests/lib/ledger-worker-fake.bh-9064.mjs, behind a
# fake curl. gh is a PATH shim that logs every call. 0 network calls.
#
#   C1  every status row of the plan's Failure-modes table prints its class
#   C2  every text row prints its class (near misses: #401, 403 days, #500)
#   C3  cnr_record refuses cred class gh, box 192.0.2.5 / box.local and reason
#       quota-reserve: 0 POSTs, rc 0
#   S1  cnr_retry runs in the CURRENT shell (rc verbatim, GH_REST_STATUS kept);
#       both triage-state hooks are placeholders (rc 1)
#   S2  triage-state with the placeholders: _ts_fetch_refs makes 1 gh call per
#       ref; _ts_record_run on a shard runs the recorder. With the hooks forced
#       to 0, the fetch makes 0 calls and the record run records nothing
#   O1  orphan-reconcile, open ai-build list answers 401: exit 0, today's
#       `unverifiable (HTTP 401 auth)` line, nothing enqueued, 1 row for the box
#       (cred gh-app), GET answers consecutive=1
#   O2  the next run reads 200: consecutive=0, still 1 failure row
#   O3  the jobs worker is down: exit 0, `box_read_failures row not written`
#   O4  CNR_ENFORCE=0: 0 POSTs, no `cnr:` line in the log
#   N1  no IPv4 address in any new file of this ticket
#   N2  every curl call went to the fake jobs host; gh was only the shim
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/could-not-read-record.bh-9594-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
jobs_schema_render "$DIR" || exit 1
# The jobs worker imports the git-ignored catalog/lanes.json and llm-sites.json.
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v node    >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e "require('node:sqlite')" 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }
LWF_MJS="$DIR/tests/lib/ledger-worker-fake.bh-9064.mjs"
export LWF_SECRET=fixture-secret

CNR="$DIR/bin/lib/could-not-read.sh"
RETRY="$DIR/bin/lib/cnr-retry.sh"

# ── C1 cnr_classify_status ─────────────────────────────────────────────────
c1() { ( . "$CNR" 2>/dev/null && cnr_classify_status "$1" "$2" ) 2>/dev/null; }
while IFS='|' read -r st rs want; do
  check "C1 status '$st' reason '$rs'" "$(c1 "$st" "$rs")" "$want"
done <<'EOF'
401|auth|could-not-read
401|auth-skipped|could-not-read
403||could-not-read
429|rate-limit|could-not-read
500||could-not-read
502||could-not-read
503||could-not-read
504||could-not-read
000|network|could-not-read
000|timeout|could-not-read
200|rate-limit|could-not-read
200||decision
304||decision
404||decision
422||decision
409||decision
501||decision
||decision
EOF

# ── C2 cnr_classify_text ───────────────────────────────────────────────────
c2() { ( . "$CNR" 2>/dev/null && cnr_classify_text "$1" ) 2>/dev/null; }
while IFS='|' read -r txt want; do
  check "C2 text '$txt'" "$(c2 "$txt")" "$want"
done <<'EOF'
gh returns 401 on this box|could-not-read
gh: HTTP 403|could-not-read
API rate limit exceeded|could-not-read
GitHub API returned 502|could-not-read
timed out reading the board|could-not-read
Bad credentials|could-not-read
waiting on PR #401 to merge|decision
client has not answered (asked 403 days ago)|decision
blocked by #500|decision
see issue #429 first|decision
rebased after 401 commits|decision
gh issue #401 is still open|decision
github says see #503 first|decision
api answered after 403 days|decision
http 1401 bytes|decision
|decision
EOF

# ── the fake world: curl to the real worker, gh logging every call ─────────
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'SH'
#!/bin/bash
url="" data="" method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary|-d|--data) data="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "${CURL_LOG:-/dev/null}"
case "$url" in
  */api/box-read-failures*)
    [ "${CNR_JOBS_DOWN:-0}" = 1 ] && exit 7
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "${TMPDIR:-/tmp}/cnr-body.XXXXXX")
      case "$data" in @*) cat "${data#@}" > "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    node "$LWF_MJS" "$CNR_DB" "$method" "$url" ${bf:+"$bf"}; rc=$?
    [ -n "$bf" ] && rm -f "$bf"
    exit "$rc" ;;
  */api/queue*) printf '{"queue":[]}\n200' ;;
  */api/jobs*)  printf '{"jobs":[]}\n200' ;;
  *)            printf '{"ok":true}\n200' ;;
esac
SH
cat > "$FB/gh" <<'SH'
#!/bin/bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*[ ?&]page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/pulls"*) [ "$PAGE" = 1 ] || SEND 200 '[]'; SEND 200 '[]' ;;
  *"/comments"*)
    [ -f "$HARNESS/thread-status" ] && SEND "$(cat "$HARNESS/thread-status")" '{"message":"Server Error"}'
    SEND 200 '[]' ;;
  *"/issues/"*) SEND 404 '{"message":"Not Found"}' ;;
  *"/issues"*)
    [ -f "$HARNESS/issues-status" ] && SEND "$(cat "$HARNESS/issues-status")" '{"message":"Bad credentials"}'
    [ "$PAGE" = 1 ] && [ -f "$HARNESS/open.json" ] && SEND 200 "$(cat "$HARNESS/open.json")"
    SEND 200 '[]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FB/curl" "$FB/gh"
export PATH="$FB:$PATH" LWF_MJS

# ── C3 cnr_record refusals: 0 POSTs, rc 0 ─────────────────────────────────
export CURL_LOG="$T/c3-curl.log" CNR_DB="$T/c3.db" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret JOBS_RETRIES=0
: > "$CURL_LOG"
for args in "c3box p gh 401 auth" "192.0.2.5 p gh-app 401 auth" "box.local p gh-app 401 auth" "c3box p gh-app 000 quota-reserve" \
            "c3box p gh-app 000 bad-args" "c3box p gh-app 000 cache-miss"; do
  # shellcheck disable=SC2086
  out=$( . "$CNR" 2>/dev/null && cnr_record $args ); rc=$?
  check "C3 rc for [$args]" "$rc" 0
  [ -n "$out" ] && ok || bad "C3 [$args] printed no refusal line"
done
check "C3 POSTs" "$(grep -c box-read-failures "$CURL_LOG")" 0
# A valid record from the same shell IS a POST (the refusals are not vacuous).
out=$( . "$CNR" 2>/dev/null && BOX_NAME=c3box cnr_record c3box p gh-app 401 auth )
check "C3 a valid record POSTs once" "$(grep -c 'POST .*box-read-failures' "$CURL_LOG")" 1
case "$out" in "cnr: recorded gh-app 401 for c3box (consecutive=1)") ok ;; *) bad "C3 status line: [$out]" ;; esac
# The kill row inside cnr_record itself: no POST and no line.
out=$( . "$CNR" 2>/dev/null && CNR_ENFORCE=0 cnr_record c3box p gh-app 401 auth )
check "C3 CNR_ENFORCE=0 prints nothing" "$out" ""
check "C3 CNR_ENFORCE=0 adds no POST" "$(grep -c 'POST .*box-read-failures' "$CURL_LOG")" 1
unset CURL_LOG CNR_DB JOBS_URL HARNESS_SECRET JOBS_RETRIES

# ── S1 cnr_retry and the placeholder hooks ─────────────────────────────────
s1() {
  . "$RETRY" 2>/dev/null || return 99
  f() { GH_REST_STATUS=401; return 75; }
  GH_REST_STATUS=""
  cnr_retry "" f; local rc=$?
  printf '%s %s' "$rc" "$GH_REST_STATUS"
}
check "S1 cnr_retry rc and status" "$(s1)" "75 401"
check "S1 _ts_cnr_skip placeholder" "$( . "$DIR/bin/lib/triage-state.d/bh-9555-3-cnr.sh" 2>/dev/null || exit 99; _ts_cnr_skip x y; echo $?)" 1
check "S1 _ts_pr_record_ref placeholder" "$( . "$DIR/bin/lib/triage-state.d/bh-9555-5-pr-record.sh" 2>/dev/null || exit 99; _ts_pr_record_ref o/r 1; echo $?)" 1

# ── S2 triage-state with the hooks: today's behaviour ──────────────────────
s2_fetch() { # s2_fetch <force-hook> -> "<gh calls> <refs states>"
  local d="$T/s2-$1" refs max=30 slug=o/r nf=0 fetched=0
  mkdir -p "$d"; refs="$d/refs.json"; echo '{}' > "$refs"; printf '5\n6\n' > "$d/n"
  (
    . "$DIR/bin/lib/triage-state.sh" 2>/dev/null
    declare -F _ts_pr_record_ref >/dev/null || { echo "no-hook"; exit 0; }
    [ "$1" = 1 ] && _ts_pr_record_ref() { _TS_PR_REF_ST=MERGED; return 0; }
    gh_rest() { echo x >> "$d/gh.calls"; echo '{"state":"open"}'; return 0; }
    _ts_fetch_refs "$d/n"
    printf '%s %s' "$(cat "$d/gh.calls" 2>/dev/null | grep -c .)" "$(jq -c -S . "$refs")"
  )
}
check "S2 placeholder: one gh call per ref" "$(s2_fetch 0)" '2 {"5":"OPEN","6":"OPEN"}'
check "S2 a served ref spends no gh call" "$(s2_fetch 1)" '0 {"5":"MERGED","6":"MERGED"}'
s2_record() { # s2_record <force-skip> -> rc of _ts_record_run and whether the recorder ran
  local h="$T/s2h-$1" d="$T/s2r-$1" p=x out="$T/s2-out" rc=0 key=TK-1 hash=h DEC="" W="" ROWS="" priv="" gh=0
  mkdir -p "$h/bin" "$d"
  printf 'import sys\nopen(%s, "a").write("ran\\n")\nprint("{}")\n' "'$d/ran'" > "$h/bin/triage-state.py"
  (
    . "$DIR/bin/lib/triage-state.sh" 2>/dev/null
    declare -F _ts_cnr_skip >/dev/null || { echo "no-hook"; exit 0; }
    [ "$1" = 1 ] && _ts_cnr_skip() { return 0; }
    _ts_record_run; printf '%s %s' "$?" "$(cat "$d/ran" 2>/dev/null || echo none)"
  )
}
check "S2 placeholder: the shard's decision is recorded" "$(s2_record 0)" "0 ran"
check "S2 a could-not-read skip records nothing" "$(s2_record 1)" "1 none"

# ── O1-O4 the real bin/orphan-reconcile.sh ─────────────────────────────────
TPL="$T/tpl"
mkdir -p "$TPL/bin/lib" "$TPL/logs" "$TPL/state" "$TPL/locks" "$TPL/flags" "$TPL/env" "$TPL/prompts" "$TPL/builds"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh \
         bin/lib/wake-backstop.sh bin/lib/pr-record.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in bin/lib/could-not-read.sh bin/lib/cnr-retry.sh; do
  [ -e "$DIR/$L" ] && cp -p "$DIR/$L" "$TPL/$L"
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$TPL/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\nJOBS_RETRIES=0\n' > "$TPL/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$TPL/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/pr-owner-sweep.sh"
# The App path is armed: gh_auth_for rc 0 is the gh-app credential class.
printf '%s\n' 'gh_auth_for() { return 0; }' 'gh_auth_reset() { return 0; }' > "$TPL/bin/lib/gh-app-auth.sh"
chmod +x "$TPL/bin/"*.sh

fresh() { # fresh <case>
  H="$T/$1"; cp -a "$TPL" "$H" || { echo "setup: cannot copy the template"; exit 1; }
  export HARNESS="$H" CNR_DB="$T/$1.db" CURL_LOG="$T/$1-curl.log" BOX_NAME="cnr-box-$$-$1"
  rm -f "$CNR_DB"
}
run() {
  : > "$H/logs/$P.log"
  env HARNESS_TEST_SANDBOX=1 "$@" bash ${CNR_DEBUG:+-x} "$H/bin/orphan-reconcile.sh" "$P" >/dev/null 2>"$H/run.err"; RC=$?
  LOGS=$(cat "$H/logs/$P.log" 2>/dev/null)
}
getj() { # getj <jq> — the GET answer for this case's box
  node "$LWF_MJS" "$CNR_DB" GET "https://jobs.test/api/box-read-failures?box=$BOX_NAME" 2>/dev/null | head -1 | jq -r "$1" 2>/dev/null
}
rows() { node "$LWF_MJS" "$CNR_DB" --sql "SELECT count(*) AS n FROM box_read_failures WHERE box=?" "$BOX_NAME" 2>/dev/null | jq -r .n 2>/dev/null; }
posts() { grep -c 'POST .*box-read-failures' "$CURL_LOG" 2>/dev/null; }
enq() { { cat "$H/launches.log" 2>/dev/null; grep 'POST .*/api/queue' "$CURL_LOG" 2>/dev/null; } | grep -c .; }

# O1
fresh o1; echo 401 > "$H/issues-status"
run
check "O1 exit" "$RC" 0
grep -q 'reconcile: the open ai-build list unverifiable (HTTP 401 auth) — enqueued nothing' <<<"$LOGS" && ok || bad "O1 today's unverifiable line missing: [$LOGS] stderr: $(tail -${CNR_DEBUG:-5} "$H/run.err")"
check "O1 enqueued" "$(enq)" 0
check "O1 failure rows for the box" "$(rows)" 1
check "O1 cred class" "$(node "$LWF_MJS" "$CNR_DB" --sql "SELECT cred_class FROM box_read_failures WHERE box=?" "$BOX_NAME" 2>/dev/null | jq -r .cred_class)" gh-app
check "O1 GET consecutive" "$(getj '.health[] | select(.cred_class=="gh-app") | .consecutive')" 1
grep -q "cnr: recorded gh-app 401 for $BOX_NAME (consecutive=1)" <<<"$LOGS" && ok || bad "O1 status line missing: $LOGS"
# O2 — the next run reads 200
rm -f "$H/issues-status"
run
check "O2 exit" "$RC" 0
check "O2 GET consecutive" "$(getj '.health[] | select(.cred_class=="gh-app") | .consecutive')" 0
check "O2 failure rows still" "$(rows)" 1
check "O2 last_status" "$(getj '.health[] | select(.cred_class=="gh-app") | .last_status')" ok
# O3 — the jobs worker is down
fresh o3; echo 503 > "$H/issues-status"
run CNR_JOBS_DOWN=1
check "O3 exit" "$RC" 0
grep -q 'unverifiable (HTTP 503)' <<<"$LOGS" && ok || bad "O3 today's line missing: $LOGS"
grep -q 'cnr: box_read_failures row not written (rc ' <<<"$LOGS" && ok || bad "O3 not-written line missing: $LOGS"
check "O3 enqueued" "$(enq)" 0
# O4 — the kill row
fresh o4; echo 401 > "$H/issues-status"
run CNR_ENFORCE=0
check "O4 exit" "$RC" 0
check "O4 POSTs" "$(posts)" 0
grep -q 'cnr:' <<<"$LOGS" && bad "O4 a cnr line with the kill row 0: $LOGS" || ok
grep -q 'unverifiable (HTTP 401 auth) — enqueued nothing' <<<"$LOGS" && ok || bad "O4 today's line missing"

# O5 — one record a run: three thread reads fail in one run, after an ok
fresh o5; echo 502 > "$H/thread-status"
jq -n '[11,12,13] | map({number: ., title: "TK-\(.) ticket \(.)", body: "## Scope", comments: 1, state: "open",
                         updated_at: "2026-01-01T00:00:00Z"})' > "$H/open.json"
run
check "O5 exit" "$RC" 0
check "O5 thread reads that failed" "$(grep -c 'thread read for #1[123] unverifiable (HTTP 502)' <<<"$LOGS")" 3
check "O5 failure rows (one a run)" "$(rows)" 1
check "O5 GET consecutive" "$(getj '.health[] | select(.cred_class=="gh-app") | .consecutive')" 1
check "O5 POSTs (ok + one failure)" "$(posts)" 2

# ── N1 no host address in a new file ───────────────────────────────────────
NEW="bin/lib/could-not-read.sh bin/lib/cnr-retry.sh bin/lib/triage-state.d/bh-9555-3-cnr.sh bin/lib/triage-state.d/bh-9555-5-pr-record.sh
     worker/jobs/src/routes/box-read-failures.js worker/jobs/src/routes/retention.d/bh-9594-box-read-failures.js
     worker/jobs/test/route-table.d/bh-9594-box-read-failures.txt catalog/lanes.d/_lib.could-not-read.json
     docs/verification-map/entries/box-read-failures.md"
for f in $NEW; do
  [ -e "$DIR/$f" ] || { bad "N1 $f missing"; continue; }
  grep -nE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' "$DIR/$f" && bad "N1 $f holds an IPv4 address" || ok
done
# ── N2 every curl went to the fake jobs host; gh was only the shim ────────
ALLC=$(cat "$T"/*-curl.log 2>/dev/null)
[ -n "$ALLC" ] && ok || bad "N2 no curl call logged at all"
check "N2 curl calls off the fake host" "$(grep -vc ' https://jobs.test/' <<<"$ALLC")" 0
[ -s "$T/o1/gh-calls.log" ] && ok || bad "N2 the gh shim was not called"

echo "could-not-read-record: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
