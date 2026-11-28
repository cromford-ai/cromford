#!/bin/bash
# tests/triage-could-not-read.bh-9555-test.sh — BH-10453 (BH-9555.3): a
# could-not-read in triage is not a decision.
#
# The two seams BH-9594 landed as placeholders get their bodies:
#   bin/lib/cnr-retry.sh                       cnr_retry: backoff 2, 4, 8 s
#       inside CNR_RETRY_BUDGET_S (row lib.could-not-read.cnr_retry_budget_s,
#       default 20), only on a could-not-read answer, in the current shell.
#   bin/lib/triage-state.d/bh-9555-3-cnr.sh    _ts_cnr_skip: a shard's `skip`
#       whose reason is a could-not-read records no decision, takes its fp stamp
#       back, re-arms the key and records one box_read_failures row.
#   bin/lib/triage-shards-lib.sh               the dispatcher's PR read goes
#       through cnr_retry; a could-not-read writes no fp stamp, one record a pass.
#
# cnr_record POSTs to the REAL jobs worker route, run on node:sqlite through
# tests/lib/ledger-worker-fake.bh-9064.mjs behind a fake curl. gh is a PATH
# stub that answers `gh api -i` with a status line. 0 network calls.
#
#   R1-R7  cnr_retry          K1-K7  _ts_cnr_skip through _ts_record_run
#   D1-D5  the dispatcher     N1-N2  no network, no host address
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/triage-could-not-read.bh-9555-test.sh
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
export LWF_SECRET=fixture-secret LWF_MJS
RETRY="$DIR/bin/lib/cnr-retry.sh"
P=project-5
NOW=$(date +%s)
export FLEET_CONF="$DIR/fleet.conf" GH_BUDGET_TTL_S=0
export JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret JOBS_RETRIES=0
unset CNR_ENFORCE CNR_RETRY_BUDGET_S

# ── the fake world ─────────────────────────────────────────────────────────
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
printf '%s %s\n' "$method" "$url" >> "${CURL_ALL:-/dev/null}"
case "$url" in
  */api/box-read-failures*)
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "${TMPDIR:-/tmp}/cnr-body.XXXXXX")
      case "$data" in @*) cat "${data#@}" > "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    node "$LWF_MJS" "$CNR_DB" "$method" "$url" ${bf:+"$bf"}; rc=$?
    [ -n "$bf" ] && rm -f "$bf"
    exit "$rc" ;;
  *) printf '{"ok":true}\n200' ;;
esac
SH
# gh: `pulls/<n>` answers from $HARNESS/fixture/pr<n>, one status a line, the
# first line consumed per call (the last one sticks). `none` = no status line.
cat > "$FB/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/fixture/gh-calls"
printf '%s\n' "$*" >> "${GH_ALL:-/dev/null}"
case "$*" in
  *pulls/[0-9]*)
    n=$(printf '%s' "$*" | sed -nE 's#.*pulls/([0-9]+).*#\1#p')
    f="$HARNESS/fixture/pr$n"
    st=$(head -1 "$f" 2>/dev/null); st="${st:-200}"
    [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 1 ] && sed -i 1d "$f"
    case "$st" in
      none) exit 1 ;;
      200) printf 'HTTP/2 200\r\n\r\n{"state":"open","merged_at":null}\n'; exit 0 ;;
      404) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
      401) printf 'HTTP/2 401\r\n\r\n{"message":"Bad credentials"}\n'; exit 1 ;;
      429) printf 'HTTP/2 429\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
      *)   printf 'HTTP/2 %s\r\n\r\n{"message":"Forbidden"}\n' "$st"; exit 1 ;;
    esac ;;
esac
exit 1
SH
chmod +x "$FB/curl" "$FB/gh"
export PATH="$FB:$PATH" CURL_ALL="$T/curl-all.log" GH_ALL="$T/gh-all.log"
: > "$CURL_ALL"; : > "$GH_ALL"

rows() { node "$LWF_MJS" "$1" --sql "SELECT count(*) AS n FROM box_read_failures WHERE box=?" "$BOX_NAME" 2>/dev/null | jq -r .n 2>/dev/null; }
rowf() { node "$LWF_MJS" "$1" --sql "SELECT $2 AS v FROM box_read_failures WHERE box=?" "$BOX_NAME" 2>/dev/null | jq -r .v 2>/dev/null | paste -sd, -; }
posts() { cat "$1" 2>/dev/null | grep -c 'POST .*box-read-failures'; }

# ══ R cnr_retry ════════════════════════════════════════════════════════════
mkdir -p "$T/rh"
# rrun <budget> <fake-sleep 1|0> <items> [VAR=val...] -> "rc=<rc> calls=<n> sleeps=<list> st=<status>"
#   item = <status>[/<reason>]; `ok` = status 200 and rc 0; 4xx/5xx/000 rc 75,
#   anything else rc 1.
rrun() {
  local budget="$1" fake="$2" items="$3"; shift 3
  (
    export HARNESS="$T/rh"
    [ $# -gt 0 ] && export "$@"
    . "$RETRY" 2>/dev/null || { echo "no-lib"; exit 0; }
    SLEEPS=""
    if [ "$fake" = 1 ]; then _cnr_sleep() { SLEEPS="$SLEEPS $1"; }; fi
    read -r -a SEQ <<<"$items"
    CALLS=0
    f() {
      local it="${SEQ[$CALLS]:-${SEQ[${#SEQ[@]}-1]}}"
      CALLS=$((CALLS+1))
      GH_REST_STATUS="${it%%/*}"; GH_REST_REASON=""
      case "$it" in */*) GH_REST_REASON="${it#*/}" ;; esac
      [ "$it" = ok ] && { GH_REST_STATUS=200; return 0; }
      [ "$it" = - ] && GH_REST_STATUS=""
      case "$GH_REST_STATUS" in 4??|5??|000) return 75 ;; esac
      return 1
    }
    GH_REST_STATUS=""
    cnr_retry "$budget" f; rc=$?
    echo "rc=$rc calls=$CALLS sleeps=${SLEEPS# } st=$GH_REST_STATUS"
  )
}
check "R1 401 always: 2 4 8, 4 calls, rc 75" "$(rrun 20 1 401)" "rc=75 calls=4 sleeps=2 4 8 st=401"
check "R1 403 always"                        "$(rrun 20 1 403)" "rc=75 calls=4 sleeps=2 4 8 st=403"
check "R1 429 always"                        "$(rrun 20 1 429/rate-limit)" "rc=75 calls=4 sleeps=2 4 8 st=429"
check "R1 000 timeout always"                "$(rrun 20 1 000/timeout)" "rc=75 calls=4 sleeps=2 4 8 st=000"
check "R1 200 with reason rate-limit retries" "$(rrun 20 1 200/rate-limit)" "rc=1 calls=4 sleeps=2 4 8 st=200"
for s in 200 404 422 -; do
  st="$s"; [ "$s" = - ] && st=""
  check "R2 status [$st] is a decision: 1 call" "$(rrun 20 1 "$s")" "rc=$( [ "$s" = 404 ] || [ "$s" = 422 ] && echo 75 || echo 1) calls=1 sleeps= st=$st"
done
check "R2 rc 0: 1 call"                       "$(rrun 20 1 ok)" "rc=0 calls=1 sleeps= st=200"
check "R3 401 then 200: rc 0, status seen by the caller" "$(rrun 20 1 '401 ok')" "rc=0 calls=2 sleeps=2 st=200"
s0=$SECONDS
check "R4 real sleep, budget 3: one 2 s step" "$(rrun 3 0 401)" "rc=75 calls=2 sleeps= st=401"
el=$((SECONDS - s0))
[ "$el" -le 4 ] && [ "$el" -ge 2 ] && ok || bad "R4 elapsed ${el}s, want 2..4"
check "R4b budget 5: 2 s taken, 4 s refused"  "$(rrun 5 1 401)" "rc=75 calls=2 sleeps=2 st=401"
check "R4c budget 0: one read"                "$(rrun 0 1 401)" "rc=75 calls=1 sleeps= st=401"
check "R4d budget 500 clamps to 120: 2 4 8"   "$(rrun 500 1 401)" "rc=75 calls=4 sleeps=2 4 8 st=401"
check "R5 empty budget, no env, no lane-gate: 20" "$(rrun '' 1 401)" "rc=75 calls=4 sleeps=2 4 8 st=401"
check "R5b empty budget, env 5"               "$(rrun '' 1 401 CNR_RETRY_BUDGET_S=5)" "rc=75 calls=2 sleeps=2 st=401"
check "R5c empty budget, env junk reads 20"   "$(rrun '' 1 401 CNR_RETRY_BUDGET_S=abc)" "rc=75 calls=4 sleeps=2 4 8 st=401"
check "R5d budget junk reads 20"              "$(rrun -3 1 401)" "rc=75 calls=4 sleeps=2 4 8 st=401"
check "R6 CNR_ENFORCE=0: one read"            "$(rrun 20 1 401 CNR_ENFORCE=0)" "rc=75 calls=1 sleeps= st=401"
check "R7 a local refusal is not retried"     "$(rrun 20 1 000/quota-reserve)" "rc=75 calls=1 sleeps= st=000"

# ══ K _ts_cnr_skip through the real _ts_record_run ══════════════════════════
KTPL="$T/ktpl"
mkdir -p "$KTPL/bin/lib" "$KTPL/logs" "$KTPL/state/triage-shards/$P" "$KTPL/fixture"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$KTPL" ) >/dev/null || { echo "setup: jobs-client"; exit 1; }
# The recorder stub: it only says it ran.
printf 'import sys\nimport os\nopen(os.environ["KRAN"], "a").write("ran\\n")\nprint("{}")\n' > "$KTPL/bin/triage-state.py"
# kcase <name> <out-text|@missing> [VAR=val...] -> sets KH (the case harness)
kcase() {
  local name="$1" text="$2"; shift 2
  KH="$T/k-$name"; cp -a "$KTPL" "$KH" || { echo "setup: cannot copy"; exit 1; }
  [ "$text" = @missing ] || printf '%s\n' "$text" > "$KH/out"
  printf 'abcdef0123456789\n%s\n' "$NOW" > "$KH/state/triage-shards/$P/9472.fp"
  printf '{"issues":[{"number":9472,"state":"OPEN"},{"number":9473,"state":"OPEN"}],"prs":[]}' > "$KH/state/$P.gate.json"
  mkdir -p "$KH/d"
  (
    export HARNESS="$KH" CURL_LOG="$KH/curl.log" CNR_DB="$KH/db" BOX_NAME="cnr-k-$$" KRAN="$KH/ran"
    [ $# -gt 0 ] && export "$@"
    . "$DIR/bin/lib/triage-state.sh" 2>/dev/null
    . "$DIR/bin/lib/triage-shards-lib.sh" 2>/dev/null
    h="$KH" p="$P" out="$KH/out" rc=0 key=9472 hash=h DEC="" W="" ROWS="" priv="" gh=1 d="$KH/d"
    _ts_record_run; echo $? > "$KH/rc"
  )
}
gate_has() { jq -r --argjson n "$1" '[.issues[] | select(.number == $n)] | length' "$KH/state/$P.gate.json" 2>/dev/null; }
export BOX_NAME="cnr-k-$$"

# K1
kcase k1 "tickets=1
DECISION: BH-9472 :: skip :: gh returns 401 on this box"
check "K1 _ts_record_run rc (record nothing)" "$(cat "$KH/rc")" 1
check "K1 the recorder did not run" "$(cat "$KH/ran" 2>/dev/null || echo none)" none
[ -e "$KH/state/triage-shards/$P/9472.fp" ] && bad "K1 the fp stamp is still there" || ok
check "K1 9472 re-armed out of gate.json" "$(gate_has 9472)" 0
check "K1 9473 kept in gate.json" "$(gate_has 9473)" 1
check "K1 box_read_failures rows" "$(rows "$KH/db")" 1
check "K1 row cred/status/project" "$(rowf "$KH/db" "cred_class||'/'||status||'/'||project")" "gh-app/401/$P"
grep -q "cnr: recorded gh-app 401 for $BOX_NAME (consecutive=1)" "$KH/logs/$P.log" 2>/dev/null && ok \
  || bad "K1 the cnr line is not in logs/$P.log: $(cat "$KH/logs/$P.log" 2>/dev/null)"
# K7 — the next tick offers the key again
K1H="$KH"
check "K7 fp_fresh after K1 dispatches" "$( . "$DIR/bin/lib/triage-shards-lib.sh" 2>/dev/null; triage_shard_fp_fresh "$K1H" "$P" 9472 abcdef0123456789; echo $?)" 1

# K2
kcase k2a "DECISION: #9472 :: skip :: API rate limit exceeded"
check "K2 #9472 rate limit: recorder" "$(cat "$KH/ran" 2>/dev/null || echo none)" none
check "K2 rate limit status" "$(rowf "$KH/db" status)" 429
kcase k2b "DECISION: 9472 :: skip :: timed out reading the board"
check "K2 9472 timeout: recorder" "$(cat "$KH/ran" 2>/dev/null || echo none)" none
check "K2 timeout status" "$(rowf "$KH/db" status)" 000
kcase k2c "DECISION: BH-9472 :: skip :: waiting on client
DECISION: BH-9472 :: SKIP :: gh: HTTP 403 on the thread read"
check "K2 last line wins (cnr): recorder" "$(cat "$KH/ran" 2>/dev/null || echo none)" none
check "K2 403 status" "$(rowf "$KH/db" status)" 403

# K3 — a build verdict that says 401 stays a decision
kcase k3 "DECISION: BH-9472 :: build :: gh returns 401 on this box"
check "K3 recorder ran" "$(cat "$KH/ran" 2>/dev/null)" ran
[ -e "$KH/state/triage-shards/$P/9472.fp" ] && ok || bad "K3 the fp stamp was taken back"
check "K3 9472 still in gate.json" "$(gate_has 9472)" 1
check "K3 POSTs" "$(posts "$KH/curl.log")" 0

# K4 — negatives
n=0
while IFS= read -r txt; do
  n=$((n+1))
  kcase "k4-$n" "$txt"
  check "K4.$n recorder ran for [$txt]" "$(cat "$KH/ran" 2>/dev/null)" ran
  check "K4.$n POSTs" "$(posts "$KH/curl.log")" 0
  [ -e "$KH/state/triage-shards/$P/9472.fp" ] && ok || bad "K4.$n the fp stamp was taken back"
done <<'EOF'
DECISION: BH-9472 :: skip :: waiting on PR #401 to merge
DECISION: BH-9472 :: skip :: client has not answered (asked 403 days ago)
DECISION: BH-9473 :: skip :: gh returns 401 on this box
DECISION: BH-9472 :: escalate :: API rate limit exceeded
DECISION: BH-94720 :: skip :: gh returns 401 on this box
EOF
kcase k4-last "DECISION: BH-9472 :: skip :: gh returns 401 on this box
DECISION: BH-9472 :: skip :: waiting on client"
check "K4 last line is a real skip: recorder ran" "$(cat "$KH/ran" 2>/dev/null)" ran
check "K4 last line is a real skip: POSTs" "$(posts "$KH/curl.log")" 0

# K5 — empty and missing out file
K5=$(
  . "$DIR/bin/lib/triage-state.sh" 2>/dev/null
  h="$T/k5" p="$P" gh=1
  : > "$T/k5-empty"
  _ts_cnr_skip "$T/k5-empty" 9472; a=$?
  _ts_cnr_skip "$T/k5-missing" 9472; b=$?
  echo "$a $b"
)
check "K5 empty / missing out" "$K5" "1 1"

# K6 — the kill row
kcase k6 "DECISION: BH-9472 :: skip :: gh returns 401 on this box" CNR_ENFORCE=0
check "K6 CNR_ENFORCE=0: recorder ran" "$(cat "$KH/ran" 2>/dev/null)" ran
[ -e "$KH/state/triage-shards/$P/9472.fp" ] && ok || bad "K6 the fp stamp was taken back"
check "K6 POSTs" "$(posts "$KH/curl.log")" 0

# ══ D the dispatcher: triage_prstates_refresh + triage_shard_fp_put ═════════
DTPL="$T/dtpl"
mkdir -p "$DTPL/bin/lib" "$DTPL/logs" "$DTPL/state" "$DTPL/fixture"
for L in bin/lib/triage-shards-lib.sh bin/lib/gh-rest.sh bin/lib/gh-budget.sh bin/jobs-client.sh bin/fleet-conf.sh \
         bin/lib/could-not-read.sh bin/lib/cnr-retry.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$DTPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
rm -f "$DTPL/bin/lib/gh-app-auth.sh"
# dcase <name> <pr12 seq> <pr13 seq> [VAR=val...] — key 9472 waits on PR #12,
#   key 9480 on PR #13; both PRs are OPEN in the ledger, read 4000 s ago.
dcase() {
  local name="$1" s12="$2" s13="$3"; shift 3
  DH="$T/d-$name"; cp -a "$DTPL" "$DH" || { echo "setup: cannot copy"; exit 1; }
  printf '%b' "$s12" > "$DH/fixture/pr12"; printf '%b' "$s13" > "$DH/fixture/pr13"
  printf '12\tOPEN\t%s\n13\tOPEN\t%s\n' "$((NOW-4000))" "$((NOW-4000))" > "$DH/state/$P.prstates"
  printf '9472\tqueue\tBH-9472 waiting on PR #12\n9480\tqueue\tBH-9480 waiting on PR #13\n' > "$DH/units"
  LED0=$(cat "$DH/state/$P.prstates")
  (
    export HARNESS="$DH" CURL_LOG="$DH/curl.log" CNR_DB="$DH/db"
    [ $# -gt 0 ] && export "$@"
    . "$DH/bin/lib/triage-shards-lib.sh"
    if [ -n "${DFAKE:-}" ]; then
      . "$DH/bin/lib/cnr-retry.sh"
      _cnr_sleep() { echo "$1" >> "$DH/sleeps"; }
    fi
    triage_prstates_refresh "$DH" "$P" "$DH/units"
    for k in 9472 9480; do triage_shard_fp_put "$DH" "$P" "$k" 0123456789abcdef; echo "$k $?" >> "$DH/put-rc"; done
  ) >/dev/null 2>"$DH/err"
}
stamped() { [ -e "$DH/state/triage-shards/$P/$1.fp" ] && echo yes || echo no; }
pulls() { cat "$DH/fixture/gh-calls" 2>/dev/null | grep -c "pulls/$1"; }
led() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$DH/state/$P.prstates"; }

# D1
for s in 401 403 429 none; do
  want="$s"; [ "$s" = none ] && want=000
  dcase "d1-$s" "$s\n" "200\n" CNR_RETRY_BUDGET_S=0
  check "D1 $s: 9472 not stamped" "$(stamped 9472)" no
  check "D1 $s: 9480 (PR read 200) stamped" "$(stamped 9480)" yes
  check "D1 $s: rows" "$(rows "$DH/db")" 1
  check "D1 $s: status" "$(rowf "$DH/db" status)" "$want"
  check "D1 $s: cred" "$(rowf "$DH/db" cred_class)" gh-app
  check "D1 $s: ledger line for PR 12 unchanged" "$(grep "^12	" "$DH/state/$P.prstates")" "$(grep "^12	" <<<"$LED0")"
  check "D1 $s: put rc 0 (no ALERTS line)" "$(grep -c ' 0$' "$DH/put-rc")" 2
  grep -q "9472 no fp stamp — PR read could not read (HTTP $want)" "$DH/logs/$P.log" 2>/dev/null && ok \
    || bad "D1 $s: refusal line missing: $(cat "$DH/logs/$P.log" 2>/dev/null) err: $(tail -3 "$DH/err")"
  grep -q "cnr: recorded gh-app $want" "$DH/logs/$P.log" 2>/dev/null && ok || bad "D1 $s: cnr line missing"
done
# D2 — two failing PRs: one POST
dcase d2 "401\n" "401\n" CNR_RETRY_BUDGET_S=0
check "D2 POSTs" "$(posts "$DH/curl.log")" 1
check "D2 9472 stamped" "$(stamped 9472)" no
check "D2 9480 stamped" "$(stamped 9480)" no
# D2b — the rest of a pass after a could-not-read takes one read each
dcase d2b "401\n" "401\n" DFAKE=1
check "D2b pulls/12 (budget, 2 4 8)" "$(pulls 12)" 4
check "D2b pulls/13 (one read after the first cnr)" "$(pulls 13)" 1
# D3 — 401 then 200 on the same PR in one pass
dcase d3 "401\n200\n" "200\n" DFAKE=1
check "D3 pulls/12" "$(pulls 12)" 2
check "D3 slept" "$(paste -sd' ' "$DH/sleeps" 2>/dev/null)" 2
check "D3 OPEN restamped" "$(led 12) $(awk -F'\t' '$1==12{print ($3 >= '"$NOW"')}' "$DH/state/$P.prstates")" "OPEN 1"
check "D3 9472 stamped" "$(stamped 9472)" yes
check "D3 POSTs" "$(posts "$DH/curl.log")" 0
# D4 — 200 and 404 are decisions
dcase d4 "200\n" "404\n"
check "D4 9472 stamped (200)" "$(stamped 9472)" yes
check "D4 9480 stamped (404)" "$(stamped 9480)" yes
check "D4 PR 13 ABSENT" "$(led 13)" ABSENT
check "D4 POSTs" "$(posts "$DH/curl.log")" 0
check "D4 pulls/13 (404 not retried)" "$(pulls 13)" 1
# D5 — the kill row
dcase d5 "401\n" "200\n" CNR_ENFORCE=0
check "D5 pulls/12" "$(pulls 12)" 1
check "D5 9472 stamped as today" "$(stamped 9472)" yes
check "D5 POSTs" "$(posts "$DH/curl.log")" 0
grep -q "PR #12 lookup failed (HTTP 401" "$DH/logs/$P.log" 2>/dev/null && ok || bad "D5 today's lookup-failed line missing"

# ══ N no network, no host address ═════════════════════════════════════════
[ -s "$CURL_ALL" ] && ok || bad "N1 no curl call logged at all"
check "N1 curl calls off the fake host" "$(grep -vc ' https://jobs.test/' "$CURL_ALL")" 0
[ -s "$GH_ALL" ] && ok || bad "N1 the gh stub was not called"
for f in bin/lib/cnr-retry.sh bin/lib/triage-state.d/bh-9555-3-cnr.sh catalog/lanes.d/_lib.could-not-read.knobs.d/CNR_RETRY_BUDGET_S.json; do
  [ -e "$DIR/$f" ] || { bad "N2 $f missing"; continue; }
  grep -nE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' "$DIR/$f" && bad "N2 $f holds an IPv4 address" || ok
done

echo "triage-could-not-read: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
