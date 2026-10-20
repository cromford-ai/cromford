#!/bin/bash
# tests/unblock-metrics.bh-7728-test.sh — BH-7728 (UNB-6): Tackler's override
# detection, the daily metrics line and the weekly precision report, driven
# through the SHIPPED entry points bin/unblock-metrics.sh and
# bin/staff/tackler-report.sh over the REAL bin/jobs-client.sh and
# bin/lib/gh-rest.sh.
#
#   O1..O12  bin/lib/unblock/override.sh: a person's reversal of a Tackler act
#            inside 24 h (a verdict, a dequeue, a setting) demotes the rule's
#            class to ask_first, then stamps override_* on the ledger row;
#            Tackler's own rows, bots, the seed, the lead, other heads,
#            out-of-window rows and truncated pages never count
#   M1..M6   bin/unblock-metrics.sh: kill switches, the lock, the daily line,
#            once a day, the ledger not live yet, a stamped row is done
#   W1..W5   bin/staff/tackler-report.sh: per-class precision, expired cards,
#            uncovered stalls, promotions; once per ISO week through
#            archie_beat_gate; pending on a failed send; --dry-run
#   B        budget (BH-7563): every curl call went to the fixture jobs URL and
#            every gh call to the stub; 0 calls to a real vendor
#
# STUBS. curl and gh are PATH stubs. curl answers the jobs API from files under
# $FXT (a small router below) and records every call; gh answers `gh api -i`
# from files under $FXT/gh. bin/archie-tg-send.sh records the send. The rule
# files are tests/fixtures/unblock/bh-7728/rules/, and the metrics answer is
# tests/fixtures/unblock/bh-7728/metrics-week.json, which
# worker/jobs/test/unblock-metrics.bh-7728.test.js R1 compares with the real
# route output key for key.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-metrics.bh-7728-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIX="$REPO/tests/fixtures/unblock/bh-7728"
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { grep -qF -- "$3" "$2" 2>/dev/null && ok || bad "$1: [$3] not in $2: $(head -c 600 "$2" 2>/dev/null)"; }
hasnt() { grep -qF -- "$3" "$2" 2>/dev/null && bad "$1: [$3] in $2" || ok; }

for SRC in bin/unblock-metrics.sh bin/lib/unblock/override.sh bin/staff/tackler-report.sh \
           catalog/lanes.d/unblock-metrics.json cron/lanes/418-unblock-metrics.cron; do
  [ -r "$REPO/$SRC" ] || bad "missing $SRC"
done
if [ ! -r "$REPO/bin/unblock-metrics.sh" ] || [ ! -r "$REPO/bin/staff/tackler-report.sh" ]; then
  echo "unblock-metrics.bh-7728: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; FB="$T/fakebin"
mkdir -p "$H/bin" "$H/env" "$H/catalog/unblock-rules.d" "$FB" || exit 1
: > "$H/env/global.env"
cp "$FIX"/rules/*.json "$H/catalog/unblock-rules.d/" || exit 1
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/tg.log"
exit "$(cat "$FXT/tg.rc" 2>/dev/null || echo 0)"
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/beats.log"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/archie-tg-send.sh" "$H/bin/lane-alert.sh"
for S in bin/unblock-metrics.sh bin/staff/tackler-report.sh bin/jobs-client.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$H" ) >/dev/null || { echo "setup: closure $S"; exit 1; }
done
[ -f "$H/bin/lib/unblock/override.sh" ] || bad "setup: the closure lacks bin/lib/unblock/override.sh"

JURL="http://jobs.fixture.test"
# curl: parse the call the jobs client makes, record it, answer from $FXT.
cat > "$FB/curl" <<'SH'
#!/bin/bash
m=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift 2 ;;
    --data-binary|-d) data=$2; shift 2 ;;
    -m|--connect-timeout|-w|-H|-o) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
jq -nc --arg m "$m" --arg u "$url" --arg d "$data" '{m: $m, u: $u, d: $d}' >> "$FXT/curl.log"
p=${url#"$JURL"}
# shellcheck disable=SC1091
. "$FXT/../router.sh"
route "$m" "$p" "$data"
SH
chmod +x "$FB/curl"
cat > "$T/router.sh" <<'SH'
ans() { printf '%s\n%s' "$2" "$1"; exit 0; }
qp() { local v; v=$(sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p" <<<"$2"); printf '%b' "${v//%/\\x}"; }
route() {
  local m=$1 p=$2 d=$3 f k
  case "$m ${p%%\?*}" in
    "GET /api/unblock/overrides/candidates")
      [ -f "$FXT/cand.code" ] && ans "$(cat "$FXT/cand.code")" "$(cat "$FXT/cand.body")"
      jq -c --slurpfile s "$FXT/stamped.json" '.candidates |= map(select(.id as $i | ($s[0] | index($i)) == null))' "$FXT/cand.json" \
        > "$FXT/cand.out" && ans 200 "$(cat "$FXT/cand.out")" ;;
    "POST /api/staff/classes/delegation")
      [ -f "$FXT/deleg.transport" ] && exit 7
      ans "$(cat "$FXT/deleg.code" 2>/dev/null || echo 200)" "$(cat "$FXT/deleg.body" 2>/dev/null || echo '{"ok":true,"change_id":41}')" ;;
    "POST /api/unblock/overrides")
      [ -f "$FXT/stamp.code" ] && ans "$(cat "$FXT/stamp.code")" '{"error":"x"}'
      jq -c --argjson i "$(jq .id <<<"$d")" '. + [$i]' "$FXT/stamped.json" > "$FXT/stamped.tmp" && mv "$FXT/stamped.tmp" "$FXT/stamped.json"
      ans 200 '{"ok":true}' ;;
    "GET /api/verdicts")
      k=$(qp pr "$p")
      [ -f "$FXT/verdicts.code" ] && ans "$(cat "$FXT/verdicts.code")" '{"error":"verdicts unavailable"}'
      [ -f "$FXT/verdicts-$k.json" ] && ans 200 "$(cat "$FXT/verdicts-$k.json")"
      ans 200 '{"rows":[],"truncated":false}' ;;
    "GET /api/config-changes")
      k=$(qp name "$p")
      [ -f "$FXT/cc-$k.json" ] && ans 200 "$(cat "$FXT/cc-$k.json")"
      ans 200 '{"changes":[],"truncated":false}' ;;
    "GET /api/settings") ans 200 "$(cat "$FXT/settings.json")" ;;
    "GET /api/unblock/metrics")
      k=$(qp project "$p")
      [ -f "$FXT/metrics-$k.code" ] && ans "$(cat "$FXT/metrics-$k.code")" '{"error":"x"}'
      f="$FXT/metrics-$k.json"; [ -f "$f" ] || f="$FXT/metrics.json"
      ans 200 "$(cat "$f")" ;;
    "GET /api/staff/autonomy")
      [ -f "$FXT/autonomy.json" ] && ans 200 "$(cat "$FXT/autonomy.json")"
      ans 404 '{"error":"agent not found"}' ;;
    "GET /api/ledger")
      [ -f "$FXT/ledger.fail" ] && ans 503 '{"error":"ledgers unavailable"}'
      f="$FXT/ledger/$(qp kind "$p")__$(qp key "$p")"
      [ -f "$f" ] && ans 200 "$(jq -nc --arg s "$(cat "$f")" '{ledger: {status: $s}}')"
      ans 404 '{"error":"not found"}' ;;
    "PUT /api/ledger")
      mkdir -p "$FXT/ledger"
      jq -r .status <<<"$d" > "$FXT/ledger/$(jq -r .kind <<<"$d")__$(jq -r .key <<<"$d")"
      ans 200 '{"ok":true}' ;;
  esac
  ans 404 '{"error":"no route"}'
}
SH
# gh: `gh api -i -X <m> <path>` from $FXT/gh/<path with / ? & = as _>.
cat > "$FB/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh.log"
[ "$1" = api ] || exit 1
shift; p=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-H) shift 2 ;; *) p=$1; shift ;; esac; done
f="$FXT/gh/$(printf '%s' "$p" | tr '/?&=' '____')"
if [ -f "$f" ]; then printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n'; cat "$f"; exit 0; fi
printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 1
SH
chmod +x "$FB/gh"
ghfx() { mkdir -p "$FXT/gh"; printf '%s' "$2" > "$FXT/gh/$(printf '%s' "$1" | tr '/?&=' '____')"; }

export HARNESS_SECRET=fixture-harness-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 \
  JOBS_SETTINGS_CACHE_S=0 GH_ETAG=0
HEAD_A=$(printf 'a%.0s' $(seq 1 40)); HEAD_B=$(printf 'b%.0s' $(seq 1 40))
ACT="2026-10-19T04:00:00Z"
ep() { date -u -d "$1" +%s; }
at() { date -u -d "@$(( $(ep "$ACT") + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }   # at <seconds after ACT>
NOW_O=$(( $(ep "$ACT") + 30 * 3600 ))                               # every override case runs 30 h after the act

reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/ledger" "$H/flags" "$H/logs" "$H/locks"
  : > "$FXT/curl.log"; : > "$FXT/gh.log"; : > "$FXT/tg.log"; echo '[]' > "$FXT/stamped.json"
  jq -nc '{settings: [{key: "unblock.project.cromford.mode", value: "shadow"},
    {key: "unblock.project.project-3.mode", value: "act"}, {key: "unblock.project.project-4.mode", value: "off"},
    {key: "lane.other.knob", value: "1"}]}' > "$FXT/settings.json"
  cp "$FIX/metrics-week.json" "$FXT/metrics.json"
  cands '[]'
}
cands() { jq -nc --argjson c "$1" '{since: "x", candidates: $c, truncated: false}' > "$FXT/cand.json"; }
# row <id> <action> <action_args-json> <rule> [subject] [head]: a candidate in the route's shape.
row() {
  jq -nc --argjson id "$1" --arg a "$2" --arg aa "$3" --arg r "$4" --arg s "${5:-example-org/cromford#7617}" \
    --arg h "${6:-$HEAD_A}" --arg at "$ACT" \
    '{id: $id, project: "cromford", repo: "example-org/cromford", subject_kind: "pr", subject: $s,
      head: $h, rule_id: $r, action: $a, action_args: $aa, created_at: "2026-10-19T03:55:00Z", acted_at: $at}'
}
# vrow <id> <verdict> <source> <reviewer> <created_at> [head]: a verdicts row.
vrow() {
  jq -nc --argjson id "$1" --arg v "$2" --arg s "$3" --arg r "$4" --arg c "$5" --arg h "${6:-$HEAD_A}" \
    '{id: $id, repo: "example-org/cromford", pr: 7617, head_sha: $h, verdict: $v, source: $s, reviewer: $r, created_at: $c}'
}
verdicts() { jq -sc '{rows: (. | reverse), truncated: false}' > "$FXT/verdicts-7617.json"; }
run_um() { # run_um <verb> [now]
  env HARNESS="$H" FXT="$FXT" JURL="$JURL" JOBS_URL="$JURL" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE="${GATE_OFF-1}" \
    UNBLOCK_NOW="${2:-$NOW_O}" PATH="$FB:$PATH" bash "$H/bin/unblock-metrics.sh" "$1" >"$T/out.txt" 2>&1
}
run_tr() { # run_tr <now> [args]
  local n=$1; shift
  env HARNESS="$H" FXT="$FXT" JURL="$JURL" JOBS_URL="$JURL" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    TACKLER_NOW="$n" PATH="$FB:$PATH" bash "$H/bin/staff/tackler-report.sh" run "$@" >"$T/out.txt" 2>&1
}
calls() { grep -c -- "\"u\":\"$JURL$1" "$FXT/curl.log"; }        # calls <path prefix>
posts() { jq -r --arg u "$JURL$1" 'select(.m == "POST" and .u == $u) | .d' "$FXT/curl.log"; }
npost() { posts "$1" | grep -c .; }
olog() { grep 'overrides:' "$H/logs/unblock-metrics.log" | tail -1; }

# ═════ O1: a human MERGE 3 h after a Tackler BLOCK on the same head ══════════
reset
cands "[$(row 101 post_block '{"verdict":"BLOCK"}' U-test)]"
{ vrow 9000 BLOCK human tackler:k1 "$(at 1)"; vrow 9001 MERGE human operator "$(at 10800)"; } | verdicts
run_um overrides; rc=$?
eq "O1 rc" "$rc" 0
eq "O1 delegation POSTs" "$(npost /api/staff/classes/delegation)" 1
eq "O1 delegation body" "$(posts /api/staff/classes/delegation | jq -c '{agent, class, decision, actor}')" \
  '{"agent":"tackler","class":"review-block","decision":"ask_first","actor":"unblock-override"}'
posts /api/staff/classes/delegation | jq -r .reason | grep -q 'override of decision #101 by operator' && ok \
  || bad "O1 reason: $(posts /api/staff/classes/delegation)"
eq "O1 stamp POSTs" "$(npost /api/unblock/overrides)" 1
eq "O1 stamp fields" "$(posts /api/unblock/overrides | jq -c '{id, override_by, override_at}')" \
  "{\"id\":101,\"override_by\":\"operator\",\"override_at\":\"$(at 10800)\"}"
eq "O1 stamp detail" "$(posts /api/unblock/overrides | jq -r .override_detail)" \
  "verdict: #9001 MERGE by operator on ${HEAD_A:0:12}; demote: changed"
eq "O1 order: demote before stamp" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | sed "s#$JURL##" | tr '\n' ' ')" \
  "/api/staff/classes/delegation /api/unblock/overrides "
eq "O1 log line" "$(olog | sed 's/^[^ ]* //')" "overrides: candidates=1 checked=1 overrides=1 demoted=1 unknown=0"

# ═════ O2/O3: the other directions ═══════════════════════════════════════════
reset
cands "[$(row 102 post_verdict '{"verdict":"MERGE"}' U-test)]"
vrow 9002 BLOCK human operator "$(at $((86400 - 60)))" | verdicts
run_um overrides
eq "O2 BLOCK 23h59m after a MERGE: stamped" "$(npost /api/unblock/overrides)" 1
reset
cands "[$(row 103 post_block '{"verdict":"BLOCK"}' U-test)]"
vrow 9003 MERGE-WITH-NOTES human operator "$(at 600)" | verdicts
run_um overrides
eq "O3 MERGE-WITH-NOTES after a BLOCK: stamped" "$(npost /api/unblock/overrides)" 1

# ═════ O4..O6: never an override ═════════════════════════════════════════════
not_override() { # not_override <label> <verdict-row>
  reset
  cands "[$(row 104 post_block '{"verdict":"BLOCK"}' U-test)]"
  printf '%s\n' "$2" | verdicts
  run_um overrides
  eq "$1: POSTs" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | grep -c .)" 0
}
not_override "O4 Tackler's own row" "$(vrow 9004 MERGE human tackler:abc123 "$(at 600)")"
not_override "O6a 24h1m after" "$(vrow 9005 MERGE human operator "$(at $((86400 + 60)))")"
not_override "O6b another head" "$(vrow 9006 MERGE human operator "$(at 600)" "$HEAD_B")"
not_override "O6c same direction" "$(vrow 9007 BLOCK human operator "$(at 600)")"
not_override "O6d the lead's row" "$(vrow 9008 MERGE lead mac-lead "$(at 600)")"
not_override "O6e before the act" "$(vrow 9009 MERGE human operator "$(at -600)")"
eq "O6e log line" "$(olog | sed 's/^[^ ]* //')" "overrides: candidates=1 checked=1 overrides=0 demoted=0 unknown=0"

reset
cands "[$(row 105 post_block '{"verdict":"BLOCK"}' U-test)]"
echo 503 > "$FXT/verdicts.code"
run_um overrides; rc=$?
eq "O5 verdicts unreadable: rc" "$rc" 0
eq "O5 verdicts unreadable: POSTs" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | grep -c .)" 0
eq "O5 log line" "$(olog | sed 's/^[^ ]* //')" "overrides: candidates=1 checked=1 overrides=0 demoted=0 unknown=1"

# ═════ O7..O9: a dequeue by a person ═════════════════════════════════════════
EV="repos/example-org/cromford/issues/7617/events?per_page=100"
CM="repos/example-org/cromford/issues/7617/comments?since=$ACT&per_page=100"
ev() { jq -nc --arg e "$1" --arg l "$2" --arg who "$3" --arg ty "$4" --arg c "$5" \
  '{event: $e, label: {name: $l}, actor: {login: $who, type: $ty}, created_at: $c}'; }
cm() { jq -nc --arg b "$1" --arg who "$2" --arg ty "$3" --arg c "$4" '{body: $b, user: {login: $who, type: $ty}, created_at: $c}'; }
reset
cands "[$(row 106 requeue '{"pr":7617}' U-q)]"
ghfx "$EV" "$(ev labeled merge-queue tackler-app Bot "$(at 1)" | jq -sc .)"
ghfx "$EV" "$( { ev labeled merge-queue tackler-app Bot "$(at 1)"; ev unlabeled merge-queue operator User "$(at 7200)"; } | jq -sc .)"
ghfx "$CM" '[]'
run_um overrides
eq "O7a unlabeled by a User: delegation class" "$(posts /api/staff/classes/delegation | jq -r .class)" queue-requeue
eq "O7a stamp by" "$(posts /api/unblock/overrides | jq -r .override_by)" operator
posts /api/unblock/overrides | jq -r .override_detail | grep -q '^dequeue: unlabeled merge-queue by operator' && ok \
  || bad "O7a detail: $(posts /api/unblock/overrides)"
reset
cands "[$(row 107 requeue '{"pr":7617}' U-q)]"
ghfx "$EV" '[]'
ghfx "$CM" "$(cm '@Mergifyio dequeue' operator User "$(at 3600)" | jq -sc .)"
run_um overrides
eq "O7b @mergifyio dequeue by a User: stamped" "$(npost /api/unblock/overrides)" 1
reset
cands "[$(row 108 requeue '{"pr":7617}' U-q)]"
ghfx "$EV" "$( { ev unlabeled merge-queue 'mergify[bot]' Bot "$(at 600)"; ev unlabeled merge-queue fixture-app Bot "$(at 650)";
  ev labeled merge-queue operator User "$(at 700)";
  ev unlabeled needs-human operator User "$(at 800)"; ev unlabeled merge-queue operator User "$(at $((25 * 3600)))"; } | jq -sc .)"
ghfx "$CM" "$(cm '@mergifyio dequeue' 'mergify[bot]' Bot "$(at 900)" | jq -sc .)"
run_um overrides
eq "O8 bot login, Bot type, labeled, other label, 25 h: POSTs" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | grep -c .)" 0
reset
cands "[$(row 109 requeue '{"pr":7617}' U-q)]"
ghfx "$EV" "$(for i in $(seq 1 100); do ev labeled "l$i" operator User "$(at 60)"; done | jq -sc .)"
ghfx "$CM" '[]'
run_um overrides
eq "O9 a full page with no match: POSTs" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | grep -c .)" 0
eq "O9 counted unknown" "$(olog | sed 's/^[^ ]* //')" "overrides: candidates=1 checked=1 overrides=0 demoted=0 unknown=1"
eq "O9 gh calls (events, then no comments read)" "$(grep -c . "$FXT/gh.log")" 1

# ═════ O10/O11: a setting set back by a person ═══════════════════════════════
ccrow() { jq -nc --argjson id "$1" --arg n "$2" --arg v "$3" --arg a "$4" --arg c "$5" \
  '{id: $id, kind: "setting", name: $n, before_json: null, after_json: ({value: $v} | tojson), actor: $a, at: $c}'; }
cc() { jq -sc '{changes: (. | reverse), truncated: false}' > "$FXT/cc-lane.pool.max.json"; }
for V in 4 9; do
  reset
  cands "[$(row 110 setting_set '{"key":"lane.pool.max","value":"6"}' U-s)]"
  { ccrow 1 lane.pool.max 6 tackler:k1 "$(at 0)"; ccrow 2 lane.pool.max "$V" operator "$(at 3600)"; } | cc
  run_um overrides
  eq "O10 set to $V by operator: delegation class" "$(posts /api/staff/classes/delegation | jq -r .class)" infra-knob
  eq "O10 set to $V: stamped" "$(npost /api/unblock/overrides)" 1
  posts /api/unblock/overrides | jq -r .override_detail | grep -q "^setting: config_changes #2 lane.pool.max=$V by operator" && ok \
    || bad "O10 detail: $(posts /api/unblock/overrides)"
done
reset
cands "[$(row 111 setting_set '{"key":"lane.pool.max","value":"6"}' U-s)]"
{ ccrow 1 lane.pool.max 6 tackler:k1 "$(at 0)"; ccrow 2 lane.pool.max 3 tackler:abc123 "$(at 600)"
  ccrow 3 lane.pool.max 3 registry-seed "$(at 700)"; ccrow 4 lane.pool.max 6 operator "$(at 800)"
  ccrow 5 lane.other.max 3 operator "$(at 900)"; ccrow 6 lane.pool.max 3 operator "$(at -60)"; } | cc
run_um overrides
eq "O11 Tackler, seed, same value, other key, before: POSTs" "$(jq -r 'select(.m == "POST") | .u' "$FXT/curl.log" | grep -c .)" 0

# ═════ O12: the demote answers ═══════════════════════════════════════════════
o12() { # o12 <rule>; the verdict override of O1
  reset
  cands "[$(row 112 post_block '{"verdict":"BLOCK"}' "$1")]"
  vrow 9012 MERGE human operator "$(at 600)" | verdicts
}
o12 U-never
echo 409 > "$FXT/deleg.code"; echo '{"error":"never_delegable","agent_cap":"autonomy"}' > "$FXT/deleg.body"
run_um overrides
eq "O12a never-delegable: stamped" "$(npost /api/unblock/overrides)" 1
posts /api/unblock/overrides | jq -r .override_detail | grep -q '; demote: never-delegable$' && ok || bad "O12a detail: $(posts /api/unblock/overrides)"
eq "O12a demoted count" "$(olog | sed 's/^[^ ]* //')" "overrides: candidates=1 checked=1 overrides=1 demoted=0 unknown=0"
o12 U-test
: > "$FXT/deleg.transport"
run_um overrides
eq "O12b transport failure: delegation tried" "$(calls /api/staff/classes/delegation)" 1
eq "O12b transport failure: no stamp" "$(npost /api/unblock/overrides)" 0
o12 U-noclass
run_um overrides
eq "O12c no class: no demote" "$(npost /api/staff/classes/delegation)" 0
posts /api/unblock/overrides | jq -r .override_detail | grep -q '; demote: no-class$' && ok || bad "O12c detail: $(posts /api/unblock/overrides)"
o12 U-test
echo 404 > "$FXT/deleg.code"; echo '{"error":"class review-block not found"}' > "$FXT/deleg.body"
run_um overrides
posts /api/unblock/overrides | jq -r .override_detail | grep -q '; demote: not-found$' && ok || bad "O12d detail: $(posts /api/unblock/overrides)"
o12 U-test
echo 200 > "$FXT/deleg.code"; echo '{"ok":true,"existing":true}' > "$FXT/deleg.body"
run_um overrides
posts /api/unblock/overrides | jq -r .override_detail | grep -q '; demote: existing$' && ok || bad "O12e detail: $(posts /api/unblock/overrides)"
o12 U-test
echo 500 > "$FXT/deleg.code"; echo '{"error":"x"}' > "$FXT/deleg.body"
run_um overrides
eq "O12f a 5xx: no stamp" "$(npost /api/unblock/overrides)" 0

# ═════ M1..M6: the lane ══════════════════════════════════════════════════════
reset
cands "[$(row 101 post_block '{"verdict":"BLOCK"}' U-test)]"
# staff-off-tackler: lane_switch, before the gate; with the gate off it is a
# file read and nothing else.
: > "$FXT/curl.log"; : > "$H/flags/staff-off-tackler"
run_um tick; rc=$?
eq "M1 flags/staff-off-tackler rc" "$rc" 0
eq "M1 flags/staff-off-tackler curl calls" "$(grep -c . "$FXT/curl.log")" 0
rm -f "$H/flags/staff-off-tackler"
# lane-off-unblock-metrics: the REAL lane gate (it may read its own settings
# rows); the lane itself reads nothing.
: > "$FXT/curl.log"; : > "$H/flags/lane-off-unblock-metrics"
GATE_OFF=0 run_um tick; rc=$?
eq "M1 flags/lane-off-unblock-metrics rc" "$rc" 0
eq "M1 flags/lane-off-unblock-metrics lane reads" \
  "$(jq -r .u "$FXT/curl.log" | grep -c -e /api/unblock/ -e /api/verdicts -e /api/ledger)" 0
rm -f "$H/flags/lane-off-unblock-metrics"
: > "$FXT/curl.log"
env HARNESS="$H" FXT="$FXT" JURL="$JURL" JOBS_URL="$JURL" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
  UNBLOCK_METRICS_ENABLED=0 UNBLOCK_NOW="$NOW_O" PATH="$FB:$PATH" bash "$H/bin/unblock-metrics.sh" tick >/dev/null 2>&1; rc=$?
eq "M1 ENABLED=0 rc" "$rc" 0
eq "M1 ENABLED=0 curl calls" "$(grep -c . "$FXT/curl.log")" 0
eq "M1 gh calls" "$(grep -c . "$FXT/gh.log")" 0

reset
cands "[$(row 101 post_block '{"verdict":"BLOCK"}' U-test)]"
exec 8>"$H/locks/unblock-metrics.lock"; flock -n 8
run_um overrides; rc=$?
exec 8>&-
eq "M2 lock held rc" "$rc" 0
eq "M2 lock held calls" "$(grep -c . "$FXT/curl.log")" 0
eq "M2 lock held log" "$(grep -c 'lock held' "$H/logs/unblock-metrics.log")" 1

TUE=$(ep 2026-10-20T00:17:00Z)
reset
run_um daily "$TUE"; rc=$?
eq "M3 rc" "$rc" 0
eq "M3 metrics reads (cromford, project-3; project-4 is off)" "$(calls /api/unblock/metrics)" 2
grep -q 'project=cromford&days=7&to=2026-10-20' "$FXT/curl.log" && ok || bad "M3: the read is not days=7&to=today: $(cat "$FXT/curl.log")"
L="tackler cromford 2026-10-19: decisions 3, would 1, escalations 0, overrides 0, stall median 200m p95 210m; 7d decisions/day 3, escalations/day 0.57, override rate 9.5%, stall median 120m p95 300m"
eq "M3 cromford line" "$(grep -c -F -- "$L" "$H/logs/unblock-metrics.log")" 1
eq "M3 project-3 line" "$(grep -c -F -- "tackler project-3 2026-10-19: decisions 3," "$H/logs/unblock-metrics.log")" 1
eq "M3 project-4 (off) line" "$(grep -c 'tackler project-4' "$H/logs/unblock-metrics.log")" 0
reset
echo 503 > "$FXT/metrics-project-3.code"
run_um daily "$TUE"
eq "M3b an unreadable project is one line, the other still written" \
  "$(grep -c -e 'tackler project-3: metrics unreadable' -e 'tackler cromford 2026-10-19' "$H/logs/unblock-metrics.log")" 2

reset
run_um tick "$TUE"; run_um tick "$((TUE + 3600))"
eq "M4 daily lines over two ticks" "$(grep -c 'tackler cromford 2026-10-19' "$H/logs/unblock-metrics.log")" 1
eq "M4 the day ledger" "$(cat "$FXT/ledger/unblock_metrics__daily-2026-10-20" 2>/dev/null)" sent
reset
: > "$FXT/ledger.fail"
run_um tick "$TUE"
eq "M4b ledger unreadable: no daily line" "$(grep -c 'tackler cromford 2026-10-19' "$H/logs/unblock-metrics.log")" 0

reset
echo 503 > "$FXT/cand.code"; echo '{"error":"unblock_decisions schema not applied","detail":"no such table"}' > "$FXT/cand.body"
run_um overrides; rc=$?
eq "M5 rc" "$rc" 0
eq "M5 ledger not live line" "$(grep -c 'overrides: ledger not live' "$H/logs/unblock-metrics.log")" 1
eq "M5 nothing else read" "$(grep -c . "$FXT/curl.log")" 1
reset
echo 503 > "$FXT/cand.code"; echo '{"error":"unblock_decisions unavailable"}' > "$FXT/cand.body"
run_um overrides
eq "M5b another 503 is not 'not live'" "$(grep -c 'overrides: ledger not live' "$H/logs/unblock-metrics.log")" 0
eq "M5b it is unreadable" "$(grep -c 'overrides: candidates unreadable' "$H/logs/unblock-metrics.log")" 1

reset
cands "[$(row 101 post_block '{"verdict":"BLOCK"}' U-test)]"
vrow 9001 MERGE human operator "$(at 10800)" | verdicts
run_um overrides; run_um overrides
eq "M6 two runs, one stamp" "$(npost /api/unblock/overrides)" 1
eq "M6 two runs, one demote" "$(npost /api/staff/classes/delegation)" 1

# ═════ W1..W5: the weekly report ═════════════════════════════════════════════
MON=$(ep 2026-10-19T06:17:00Z)   # Monday, ISO week 2026-W43
autonomy() { jq -nc --argjson c "$1" '{agent: {name: "tackler"}, changes: $c}' > "$FXT/autonomy.json"; }
reset; autonomy '[]'
run_tr "$MON"; rc=$?
eq "W1 rc" "$rc" 0
eq "W1 one send" "$(grep -c . "$FXT/tg.log")" 1
jq -r .line "$FXT/tg.log" > "$T/report.txt"
eq "W1 akey" "$(jq -r .akey "$FXT/tg.log")" tackler-weekly-2026-W43
has "W1 header" "$T/report.txt" "Tackler weekly report 2026-W43 (2026-10-13 to 2026-10-19)."
has "W1 project line" "$T/report.txt" "cromford: decisions/day 3, escalations/day 0.57, stall median 120m p95 300m, override rate 9.5%"
has "W1 class U1" "$T/report.txt" "- queue-requeue: acts 11, overrides 2, precision 82%"
has "W1 class U6" "$T/report.txt" "- review-block: acts 10, overrides 0, precision 100%"
has "W1 expired" "$T/report.txt" "cards expired: 2"
has "W1 uncovered" "$T/report.txt" "uncovered stalls: 2"
has "W1 promotions" "$T/report.txt" "promotions: none"
hasnt "W1 off project" "$T/report.txt" "project-4"
hasnt "W1 em dash" "$T/report.txt" "—"
[ "$(wc -c < "$T/report.txt")" -le 3501 ] && ok || bad "W1 longer than 3500"
eq "W1 ledger" "$(cat "$FXT/ledger/tackler_report__weekly-2026-W43" 2>/dev/null)" sent
[ -f "$H/state/tackler-report/weekly-2026-W43.md" ] && ok || bad "W1 no report file"

reset
autonomy "$(jq -nc '[{kind: "delegation", class: "queue-requeue", from_value: "ask_first", to_value: "delegated", created_at: "2026-10-16T00:00:00Z"},
  {kind: "delegation", class: "fix-round", from_value: "ask_first", to_value: "delegated", created_at: "2026-10-01T00:00:00Z"},
  {kind: "delegation", class: "review-block", from_value: "delegated", to_value: "ask_first", created_at: "2026-10-17T00:00:00Z"}]')"
run_tr "$MON"
jq -r .line "$FXT/tg.log" > "$T/report.txt"
has "W2 promotion in the week" "$T/report.txt" "promotions: queue-requeue"

reset; autonomy '[]'
run_tr "$((MON + 86400))"
eq "W3 not Monday: curl calls" "$(grep -c . "$FXT/curl.log")" 0
reset; autonomy '[]'
echo sent > "$FXT/ledger/tackler_report__weekly-2026-W43"
run_tr "$MON"
eq "W3 already sent: sends" "$(grep -c . "$FXT/tg.log")" 0
eq "W3 already sent: metrics reads" "$(calls /api/unblock/metrics)" 0

reset; autonomy '[]'
echo 1 > "$FXT/tg.rc"
run_tr "$MON"
eq "W4 send failed: ledger" "$(cat "$FXT/ledger/tackler_report__weekly-2026-W43" 2>/dev/null)" pending
rm -f "$FXT/tg.rc"
run_tr "$((MON + 3600))"
eq "W4 the next tick sends" "$(cat "$FXT/ledger/tackler_report__weekly-2026-W43" 2>/dev/null)" sent

reset; autonomy '[]'
run_tr "$((MON + 86400))" --dry-run; rc=$?
eq "W5 rc" "$rc" 0
has "W5 printed" "$T/out.txt" "Tackler weekly report 2026-W43"
eq "W5 sends" "$(grep -c . "$FXT/tg.log")" 0
eq "W5 ledger writes" "$(jq -r 'select(.m == "PUT") | .u' "$FXT/curl.log" | grep -c .)" 0

# ═════ B: budget (BH-7563) ═══════════════════════════════════════════════════
# Every case above wrote to the same two logs between resets; the last case's
# logs plus a sweep of every curl.log line written in this run.
eq "B every curl call went to the fixture jobs URL" \
  "$(jq -r .u "$FXT/curl.log" | grep -vc "^$JURL/")" 0

echo "unblock-metrics.bh-7728: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
