#!/bin/bash
# tests/pm-signals-adapters.bh-7259-test.sh — BH-7259 (BH-7244.1, slice 2):
# the read-only product data adapters in bin/pm-signals.d/ and their helper
# library bin/lib/pm-signals-adapter.sh.
#
#   A1        the 8 per-project files exist, parse, one pms_ function each
#   W1-W3/X1  no write verb, no ALERTS writer, the contract files untouched
#   H1-H3     the row helpers
#   C1-C5     common-cost.sh: cost.csv sums and the jobs llm-spend read
#   Q1-Q5     common-qa.sh: open findings by severity from *qa* ledgers
#   P1-P3     common-prd-rescore.sh: the latest rescore file
#   B1-B6     common-board.sh: GitHub Issues and in-app boards
#   U1-U3     the per-project files and state/pm-data/<project>.json
#   E1-E2     the empty state through the real runner
#   S1        no token or secret in an output file, a stderr or a curl argv
#   D1, R1-R2 the hash is stable; the real runner over the real registry
#
# Every case runs bin/pm-signals.sh (the production entry point) or sources
# one adapter in a child. The clock is pinned (NOW, passed as PM_SIGNALS_NOW)
# and every fixture time is computed from it. gh and curl are stubs on PATH
# that read fixture files and log their argv: no case reaches the network.
#
# Run from anywhere: tests/pm-signals-adapters.bh-7259-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset HARNESS_SECRET JOBS_URL PM_SIGNALS_DIR PM_SIGNALS_ADAPTER_TIMEOUT_S HARNESS_SELF_APPS GH_REST_LIB

RUNNER="$DIR/bin/pm-signals.sh"
REGD="$DIR/bin/pm-signals.d"
LIB="$DIR/bin/lib/pm-signals-adapter.sh"
PROJECTS="project-6-os project-5 project-2 project-4 project-3 project-9 project-8 project-1"

NOW=1791979200   # 2026-10-14 12:00:00Z
iso() { date -u -d "@$((NOW - $1))" '+%Y-%m-%dT%H:%M:%SZ'; }

# ── stubs ────────────────────────────────────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
# gh: `auth token` fails when $STUBW/gh.authfail exists. `api ... <path>` logs
# the path and answers $STUBW/gh/<path-without-query>_p<page>.json (200, or the
# status in .status); a missing page answers [] (a real empty list).
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
W="$STUBW"
if [ "${1:-} ${2:-}" = "auth token" ]; then
  echo "auth token" >> "$W/gh.log"
  [ -e "$W/gh.authfail" ] && exit 1
  echo tok-fixture-gh; exit 0
fi
[ "${1:-}" = api ] || exit 2
path=""; for a in "$@"; do case "$a" in repos/*) path=$a ;; esac; done
echo "api $path" >> "$W/gh.log"
base=${path%%\?*}; page=1
[[ $path =~ [?\&]page=([0-9]+) ]] && page=${BASH_REMATCH[1]}
key=$(printf '%s' "$base" | tr -c 'A-Za-z0-9' '_')_p$page
st=200; [ -f "$W/gh/$key.status" ] && st=$(cat "$W/gh/$key.status")
body='[]'; [ -f "$W/gh/$key.json" ] && body=$(cat "$W/gh/$key.json")
printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n%s\n' "$st" "$body"
case $st in 2*) exit 0 ;; *) exit 1 ;; esac
EOF
# curl: logs its argv to $STUBW/curl.log and the content of every -H @file to
# $STUBW/curl-hdr.log; answers $STUBW/web/<url-path>.json, exits with the rc in
# .rc, sleeps the seconds in .sleep first; no fixture = rc 22 (an HTTP error).
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
W="$STUBW"; url=""; prev=""
for a in "$@"; do
  case "$a" in http://*|https://*) url=$a ;; esac
  [ "$prev" = -H ] && case "$a" in @*) cat "${a#@}" >> "$W/curl-hdr.log" 2>/dev/null ;; esac
  printf '%s ' "$a" >> "$W/curl.log"; prev=$a
done
echo >> "$W/curl.log"
key=$(printf '%s' "${url#*://*/}" | sed 's/[?].*//' | tr -c 'A-Za-z0-9' '_')
[ -f "$W/web/$key.sleep" ] && sleep "$(cat "$W/web/$key.sleep")"
[ -f "$W/web/$key.rc" ] && exit "$(cat "$W/web/$key.rc")"
[ -f "$W/web/$key.json" ] || exit 22
cat "$W/web/$key.json"
EOF
chmod +x "$STUB/gh" "$STUB/curl"
export PATH="$STUB:$PATH"

cat > "$T/fleet.conf" <<'EOF'
# fixture registry
project-6-os  Fixture-org/mk-fixture  -                         -          3 box-fixture 192.0.2.10
project-1   Fixture-org/mo-fixture  https://app.example.test  /api/board 2 box-fixture 192.0.2.11
project-9    Fixture-org/so-fixture  https://so.example.test   /api/board 5 box-fixture 192.0.2.12
EOF
export FLEET_CONF="$T/fleet.conf" REGISTRY_SOURCE=file

# newh <name> — a scratch harness with an env/ dir; newh also makes the stub dir.
newh() { mkdir -p "$T/$1/h/env" "$T/$1/h/logs" "$T/$1/h/state" "$T/$1/w/gh" "$T/$1/w/web"; }
# pms <name> <project> <out> [env...] — the real runner on a pinned clock.
pms() {
  local n=$1 p=$2 o=$3; shift 3
  env HARNESS="$T/$n/h" STUBW="$T/$n/w" PM_SIGNALS_NOW="$NOW" "$@" bash "$RUNNER" "$p" "$o" 2>>"$T/$n/err"
}
row() { jq -c --arg i "$2" '.evidence[] | select(.id == $i)' "$1" 2>/dev/null; }
val() { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .value' "$1" 2>/dev/null; }
st()  { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .status' "$1" 2>/dev/null; }
met() { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .metric' "$1" 2>/dev/null; }
lnk() { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .link' "$1" 2>/dev/null; }
numeq() { jq -en --argjson a "${1:-null}" --argjson b "$2" '$a != null and (($a - $b) | fabs) < 0.00001' >/dev/null 2>&1; }

# ════════════════════════════════════════════════════════════════════════════
# A1 — the registry files
# ════════════════════════════════════════════════════════════════════════════
for p in $PROJECTS; do
  [ -f "$REGD/$p.sh" ] && ok || bad "A1: bin/pm-signals.d/$p.sh is missing"
done
for f in "$REGD"/*.sh "$LIB"; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null && ok || bad "A1: bash -n fails on $f"
done
for f in "$REGD"/*.sh; do
  n=$(bash -c '. "$1" >/dev/null 2>&1 || exit 97; compgen -A function pms_ | wc -l' _ "$f")
  [ "$n" = 1 ] && ok || bad "A1: $(basename "$f") defines $n pms_ functions (want 1)"
done
for f in common-board.sh common-qa.sh common-prd-rescore.sh common-cost.sh; do
  [ -f "$REGD/$f" ] && ok || bad "A1: bin/pm-signals.d/$f is missing"
done

# ════════════════════════════════════════════════════════════════════════════
# W1-W3 / X1 — read only
# ════════════════════════════════════════════════════════════════════════════
if grep -En 'INSERT|UPDATE|DELETE|DROP|-X POST|-X PUT|-X PATCH|gh issue (comment|create|edit|close)|gh pr (comment|create|edit|merge)' "$REGD"/* "$LIB" >/dev/null 2>&1; then
  bad "W1: a write verb in an adapter: $(grep -En 'INSERT|UPDATE|DELETE|DROP|-X POST|-X PUT|-X PATCH|gh issue (comment|create|edit|close)|gh pr (comment|create|edit|merge)' "$REGD"/* "$LIB")"
else ok; fi
if grep -En 'board-creds\.sh|jobs-client\.sh|ALERTS\.log >>|>>' "$REGD"/* "$LIB" >/dev/null 2>&1; then
  bad "W2: an adapter names an ALERTS writer or appends: $(grep -En 'board-creds\.sh|jobs-client\.sh|ALERTS\.log >>|>>' "$REGD"/* "$LIB")"
else ok; fi
# Scoped to this ticket's own commits (D57): on main after the merge, or with
# no origin/main, the range holds none of them and the case is a skip note.
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  OWN=$(git -C "$DIR" log --format=%H --grep='BH-7259' origin/main..HEAD 2>/dev/null)
  if [ -n "$OWN" ]; then
    CH=$(for c in $OWN; do git -C "$DIR" show --format= --name-only --diff-filter=AMDR "$c"; done | sort -u)
    if grep -qxE 'bin/pm-signals\.sh|bin/run-product\.sh|bin/pm-signals\.d/common-alerts\.sh' <<<"$CH"; then
      bad "X1: a BH-7259 commit edits a contract file: $(grep -xE 'bin/pm-signals\.sh|bin/run-product\.sh|bin/pm-signals\.d/common-alerts\.sh' <<<"$CH")"
    else ok; fi
    grep -q '^env-templates/' <<<"$CH" && bad "W3: a BH-7259 commit touches env-templates/" || ok
  else
    echo "note: X1/W3 skip, this branch holds no BH-7259 commit"
  fi
else
  echo "note: X1/W3 skip, no origin/main"
fi

# ════════════════════════════════════════════════════════════════════════════
# H1-H3 — the helpers
# ════════════════════════════════════════════════════════════════════════════
H1=$(bash -c '. "$1" && _pmsa_row a.b a b 3 7d lnk ok' _ "$LIB" 2>/dev/null)
jq -e '(keys | sort) == ["id","link","metric","source","status","value","window"] and .value == 3 and .status == "ok" and .window == "7d"' <<<"$H1" >/dev/null 2>&1 && ok \
  || bad "H1: _pmsa_row prints the 7 keys: '$H1'"
H2=$(bash -c '. "$1" && _pmsa_nc a.b a b 7d lnk' _ "$LIB" 2>/dev/null)
jq -e '.value == null and .status == "not-configured"' <<<"$H2" >/dev/null 2>&1 && ok || bad "H2: _pmsa_nc: '$H2'"
newh h3
H3=$(HARNESS="$T/h3/h" bash -c '. "$1" && _pmsa_project_rows p usage.signups:30d churn.cancels:30d' _ "$LIB" 2>/dev/null)
[ "$(jq -sc '[.[] | [.id, .source, .metric, .status, .value]]' <<<"$H3" 2>/dev/null)" = '[["usage.signups","usage","signups","not-configured",null],["churn.cancels","churn","cancels","not-configured",null]]' ] && ok \
  || bad "H3: _pmsa_project_rows with no file: '$H3'"

# ════════════════════════════════════════════════════════════════════════════
# C1-C5 — common-cost.sh
# ════════════════════════════════════════════════════════════════════════════
CHDR='ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp'
crow() { printf '%s,host-fixture,%s,build,stub,stub-model,0,1,1,1,0,0,%s,subscription,,,,,,,,,,,,\n' "$1" "$2" "$3"; }
write_cost() {
  { echo "$CHDR"
    crow "$(iso 3600)" project-6-os 0.10
    crow "$(iso $((7*86400 - 60)))" project-6-os 0.25
    crow "$(iso 7200)" project-6-os 1.05
    crow "$(iso $((20*86400)))" project-6-os 0.50
    crow "$(iso 600)" project-6-os-x 9
    crow "$(iso 600)" project-6-os 9
    crow "$(date -u -d "@$((NOW + 3600))" '+%Y-%m-%dT%H:%M:%SZ')" project-6-os 9
    crow "$(iso $((31*86400)))" project-6-os 9
    crow "$(iso 600)" project-6-os ""
    crow "$(date -u -d "@$((NOW - 600))" '+%Y-%m-%d %H:%M:%S')" project-6-os 9
  } > "$1/logs/cost.csv"
}
newh c; write_cost "$T/c/h"
pms c project-6-os "$T/c1.json"; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: the runner exits 0 (rc=$RC)"
numeq "$(val "$T/c1.json" cost.7d)" 1.4 && [ "$(st "$T/c1.json" cost.7d)" = ok ] && [ "$(lnk "$T/c1.json" cost.7d)" = logs/cost.csv ] && [ "$(met "$T/c1.json" cost.7d)" = usd ] && ok \
  || bad "C1: 3 rows inside 7d sum to cost.7d 1.4, ok, link logs/cost.csv: $(row "$T/c1.json" cost.7d)"
[ "$(val "$T/c1.json" cost.7d)" = 1.4 ] && ok || bad "C1: the value is printed in its plain form (got '$(val "$T/c1.json" cost.7d)')"
numeq "$(val "$T/c1.json" cost.30d)" 1.9 && ok \
  || bad "C2: the near misses are skipped and the 20-day row counts in cost.30d only (1.9): $(row "$T/c1.json" cost.30d)"
newh c3
pms c3 project-6-os "$T/c3.json"
[ "$(jq -c '[.evidence[] | select(.id == "cost.7d" or .id == "cost.30d") | [.status, .value]]' "$T/c3.json" 2>/dev/null)" = '[["not-configured",null],["not-configured",null]]' ] && ok \
  || bad "C3: no cost.csv gives two not-configured rows: $(jq -c '[.evidence[] | select(.source == "cost")]' "$T/c3.json" 2>/dev/null)"
[ "$(jq -c '[.evidence[] | select(.id == "cost.d1_7d" or .id == "cost.d1_30d") | .status]' "$T/c3.json" 2>/dev/null)" = '["not-configured","not-configured"]' ] && ok \
  || bad "C4: JOBS_URL empty gives cost.d1_* not-configured: $(jq -c '[.evidence[] | select(.source == "cost")]' "$T/c3.json" 2>/dev/null)"
grep -q 'llm-spend' "$T/c3/w/curl.log" 2>/dev/null && bad "C4: no llm-spend call when JOBS_URL is empty" || ok
JOBS_SECRET='secret-fixture-jobs-sentinel'
printf '{"usd":2.5,"calls":3}' > "$T/c/w/web/api_metrics_llm_spend.json"
pms c project-6-os "$T/c5.json" JOBS_URL=http://jobs.example.test HARNESS_SECRET="$JOBS_SECRET"
numeq "$(val "$T/c5.json" cost.d1_7d)" 2.5 && [ "$(st "$T/c5.json" cost.d1_7d)" = ok ] && [ "$(met "$T/c5.json" cost.d1_30d)" = usd_d1 ] && ok \
  || bad "C5: the llm-spend answer gives cost.d1_7d 2.5 ok: $(jq -c '[.evidence[] | select(.source == "cost")]' "$T/c5.json" 2>/dev/null)"
grep -q 'llm-spend?project=project-6-os&since=2026-10-07T12:00:00Z' "$T/c/w/curl.log" 2>/dev/null && ok \
  || bad "C5: the 7d call names the project and since: $(cat "$T/c/w/curl.log" 2>/dev/null)"
grep -qF "authorization: Bearer $JOBS_SECRET" "$T/c/w/curl-hdr.log" 2>/dev/null && ok || bad "C5: the bearer header reaches curl as a header file"
grep -qF "$JOBS_SECRET" "$T/c/w/curl.log" 2>/dev/null && bad "C5: the secret is in the curl argv" || ok
echo 22 > "$T/c/w/web/api_metrics_llm_spend.rc"
pms c project-6-os "$T/c5e.json" JOBS_URL=http://jobs.example.test HARNESS_SECRET="$JOBS_SECRET"
[ "$(jq -c '[.evidence[] | select(.id == "cost.d1_7d" or .id == "cost.d1_30d") | [.status, .value]]' "$T/c5e.json" 2>/dev/null)" = '[["error",null],["error",null]]' ] && ok \
  || bad "C5: a failed llm-spend call gives error rows with value null: $(jq -c '[.evidence[] | select(.source == "cost")]' "$T/c5e.json" 2>/dev/null)"
rm -f "$T/c/w/web/api_metrics_llm_spend.rc"; printf '{"usd":"x"}' > "$T/c/w/web/api_metrics_llm_spend.json"
pms c project-6-os "$T/c5n.json" JOBS_URL=http://jobs.example.test HARNESS_SECRET="$JOBS_SECRET"
[ "$(st "$T/c5n.json" cost.d1_7d)" = error ] && ok || bad "C5: a non-number usd is an error row: $(row "$T/c5n.json" cost.d1_7d)"

# ════════════════════════════════════════════════════════════════════════════
# Q1-Q5 — common-qa.sh
# ════════════════════════════════════════════════════════════════════════════
newh q1; mkdir -p "$T/q1/h/state/qa-run1"
{ echo '{"run_id":"r1","ts":"x","board":"project-6-os","group_key":"g","fp":"f1","severity":"high","title":"a","action":"filed"}'
  echo '{"board":"project-6-os","fp":"f2","severity":"high","title":"b","status":"open"}'
} > "$T/q1/h/state/qa-run1/findings-ledger.jsonl"
touch -d "@$((NOW - 3600))" "$T/q1/h/state/qa-run1/findings-ledger.jsonl"
pms q1 project-6-os "$T/q1.json"
[ "$(val "$T/q1.json" qa.open_high)" = 2 ] && [ "$(st "$T/q1.json" qa.open_high)" = ok ] && [ "$(lnk "$T/q1.json" qa.open_high)" = state/qa-run1/findings-ledger.jsonl ] && ok \
  || bad "Q1: 2 open high findings give qa.open_high 2 ok: $(jq -c '[.evidence[] | select(.source == "qa")]' "$T/q1.json" 2>/dev/null)"
[ "$(val "$T/q1.json" qa.open_critical)" = 0 ] && [ "$(met "$T/q1.json" qa.open_low)" = open_findings ] && ok \
  || bad "Q1: the other severities are counted zeros: $(jq -c '[.evidence[] | select(.source == "qa")]' "$T/q1.json" 2>/dev/null)"
newh q2; mkdir -p "$T/q2/h/state/console-postmerge-qa/abc" "$T/q2/h/state/qa-old"
{ echo '{"board":"project-6-os","fp":"f3","severity":"high","status":"open"}'
  echo '{"board":"project-6-os","fp":"f4","severity":"low","status":"fixed"}'
  echo '{"board":"project-6-os","fp":"f3","severity":"high","status":"fixed"}'
  echo '{"board":"project-6-os","fp":"f4","severity":"low","status":"OPEN"}'
  echo '{"board":"project-6-os-x","fp":"f5","severity":"high"}'
  echo '{"project":"project-6-os","fp":"f6","severity":"High"}'
  echo '{"board":"project-6-os","fp":"f7","severity":"urgent"}'
  echo '{"board":"project-6-os","fp":"f8","severity":"critical","status":"pending"}'
  echo '{"board":"project-6-os","fp":"f9","severity":"low","status":"RESOLVED"}'
} > "$T/q2/h/state/console-postmerge-qa/abc/qa-findings.jsonl"
touch -d "@$((NOW - 7200))" "$T/q2/h/state/console-postmerge-qa/abc/qa-findings.jsonl"
echo '{"board":"project-6-os","fp":"f10","severity":"critical"}' > "$T/q2/h/state/qa-old/findings-ledger.jsonl"
touch -d "@$((NOW - 31*86400))" "$T/q2/h/state/qa-old/findings-ledger.jsonl"
pms q2 project-6-os "$T/q2.json"
Q2=$(jq -c '[.evidence[] | select(.source == "qa") | [.id, .value]]' "$T/q2.json" 2>/dev/null)
[ "$(val "$T/q2.json" qa.open_low)" = 1 ] && [ "$(val "$T/q2.json" qa.open_high)" = 1 ] && ok \
  || bad "Q2/Q3: the last row of a key wins; .board of another project skipped; .project counts; High is high (want high 1, low 1): $Q2"
[ "$(val "$T/q2.json" qa.open_medium)" = 1 ] && ok || bad "Q3: severity urgent counts as medium: $Q2"
[ "$(val "$T/q2.json" qa.open_critical)" = 1 ] && ok || bad "Q3/Q4: pending is open; a ledger 31 days old is skipped (want critical 1): $Q2"
[ "$(lnk "$T/q2.json" qa.open_high)" = state/console-postmerge-qa/abc/qa-findings.jsonl ] && ok || bad "Q2: the link is the matched ledger: $(lnk "$T/q2.json" qa.open_high)"
newh q5
pms q5 project-6-os "$T/q5.json"
[ "$(jq -c '[.evidence[] | select(.source == "qa") | [.id, .status, .value]]' "$T/q5.json" 2>/dev/null)" = '[["qa.open","not-configured",null]]' ] && ok \
  || bad "Q5: no ledger gives one qa.open not-configured row: $(jq -c '[.evidence[] | select(.source == "qa")]' "$T/q5.json" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# P1-P3 — common-prd-rescore.sh
# ════════════════════════════════════════════════════════════════════════════
write_prd() {
  mkdir -p "$1/state/prd-rescore/project-6-os"
  echo '{"criteria":[{"id":"a","status":"pass"},{"id":"b","status":"fail"}]}' > "$1/state/prd-rescore/project-6-os/o.json"
  touch -d "@$((NOW - 86400))" "$1/state/prd-rescore/project-6-os/o.json"
  echo '{"criteria":[{"id":"a","status":"pass"},{"id":"b","status":"partial"},{"id":"c","status":"Partial"},{"id":"d","status":"fail"}]}' > "$1/state/prd-rescore/project-6-os/r.json"
  touch -d "@$((NOW - 3600))" "$1/state/prd-rescore/project-6-os/r.json"
}
newh p1; write_prd "$T/p1/h"
pms p1 project-6-os "$T/p1.json"
[ "$(val "$T/p1.json" prd-rescore.partial)/$(val "$T/p1.json" prd-rescore.failed)/$(val "$T/p1.json" prd-rescore.criteria)" = 2/1/4 ] && ok \
  || bad "P1/P2: the newer file gives partial 2, failed 1, criteria 4: $(jq -c '[.evidence[] | select(.source == "prd-rescore")]' "$T/p1.json" 2>/dev/null)"
[ "$(lnk "$T/p1.json" prd-rescore.partial)" = state/prd-rescore/project-6-os/r.json ] && [ "$(st "$T/p1.json" prd-rescore.failed)" = ok ] && ok \
  || bad "P2: the link names the newer file: $(row "$T/p1.json" prd-rescore.partial)"
newh p3
pms p3 project-6-os "$T/p3.json"
[ "$(jq -c '[.evidence[] | select(.source == "prd-rescore") | [.id, .status, .value]]' "$T/p3.json" 2>/dev/null)" = '[["prd-rescore.partial","not-configured",null]]' ] && ok \
  || bad "P3: no dir gives one not-configured row: $(jq -c '[.evidence[] | select(.source == "prd-rescore")]' "$T/p3.json" 2>/dev/null)"
mkdir -p "$T/p3/h/state/prd-rescore/project-6-os"; echo 'not json' > "$T/p3/h/state/prd-rescore/project-6-os/x.json"
pms p3 project-6-os "$T/p3b.json"
[ "$(jq -c '[.evidence[] | select(.source == "prd-rescore") | [.id, .status, .value]]' "$T/p3b.json" 2>/dev/null)" = '[["prd-rescore.partial","error",null]]' ] && ok \
  || bad "P3: a file that does not parse gives one error row: $(jq -c '[.evidence[] | select(.source == "prd-rescore")]' "$T/p3b.json" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# B1-B6 — common-board.sh
# ════════════════════════════════════════════════════════════════════════════
GHK=repos_Fixture_org_mk_fixture
write_gh() {
  local w=$1 i
  jq -n '[{number:1,state:"open"},{number:2,state:"open"},{number:3,state:"closed"},{number:4,state:"open",pull_request:{url:"x"}}]' > "$w/gh/${GHK}_issues_p1.json"
  # Page 1 holds 100 comments, so page 2 is read too.
  { jq -n --arg c1 "$(iso 3600)" --arg c2 "$(iso 7200)" '
      [{user:{login:"dana-fixture",type:"User"}, created_at:$c1, html_url:"https://github.com/x/y/issues/1#c1"},
       {user:{login:"intercom[bot]",type:"Bot"}, created_at:$c1, html_url:"https://github.com/x/y/issues/1#c2"},
       {user:{login:"operator-fixture",type:"User"}, performed_via_github_app:{slug:"cromford"}, created_at:$c1, html_url:"https://github.com/x/y/issues/1#c3"},
       {user:{login:"pat-fixture",type:"User"}, created_at:$c2, html_url:"https://github.com/x/y/pull/4#c4"}]'
    jq -n --arg c "$(iso 600)" '[range(96) | {user:{login:"cromford-builders[bot]",type:"Bot"}, created_at:$c, html_url:"https://github.com/x/y/issues/2#f"}]'
  } | jq -sc 'add' > "$w/gh/${GHK}_issues_comments_p1.json"
  jq -n --arg c "$(iso 7200)" --arg o "$(iso $((31*86400)))" '
    [{user:{login:"sam-fixture",type:"User"}, created_at:$c, html_url:"https://github.com/x/y/issues/2#p2"},
     {user:{login:"old-fixture",type:"User"}, created_at:$o, html_url:"https://github.com/x/y/issues/2#old"}]' > "$w/gh/${GHK}_issues_comments_p2.json"
}
newh b1; write_gh "$T/b1/w"
pms b1 project-6-os "$T/b1.json"
[ "$(val "$T/b1.json" board.status.open)/$(val "$T/b1.json" board.status.closed)/$(val "$T/b1.json" board.tickets)" = 2/1/3 ] && ok \
  || bad "B1: GH issues by status, the PR item dropped (want 2/1/3): $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b1.json" 2>/dev/null)"
[ "$(lnk "$T/b1.json" board.tickets)" = https://github.com/Fixture-org/mk-fixture/issues ] && [ "$(st "$T/b1.json" board.tickets)" = ok ] && ok \
  || bad "B1: the link is the issues page: $(row "$T/b1.json" board.tickets)"
[ "$(val "$T/b1.json" board.client_comments_30d)" = 2 ] && [ "$(met "$T/b1.json" board.client_comments_30d)" = client_comments ] && ok \
  || bad "B2: a User comment on page 1 and one on page 2 count; Bot, self-app, PR and 31-day-old do not (want 2): $(row "$T/b1.json" board.client_comments_30d)"
grep -q "api repos/Fixture-org/mk-fixture/issues?state=all&since=2026-09-14T12:00:00Z&per_page=100&page=1" "$T/b1/w/gh.log" && ok \
  || bad "B1: the issues read names state=all and the 30d since: $(cat "$T/b1/w/gh.log")"
[ -z "$(find "$T/b1/h/state" -path '*gh-etag*' -type f 2>/dev/null)" ] && ok || bad "B1: gh_rest wrote an etag cache file"

# B3/B4 — an in-app board.
BOARD_TOKEN='tok-fixture-board-sentinel'
write_app() {
  local w=$1
  printf 'PROJECT_1_API_BASE=https://app.example.test\nproject-1_INTERNAL_API_TOKEN=%s\n' "$BOARD_TOKEN" > "$2/env/project-1.env"
  echo '{"boards":[{"id":"b1"}]}' > "$w/web/api_board_boards.json"
  jq -n --arg a "$(iso 3600)" --arg b "$(iso $((40*86400)))" --arg c "$(iso 86400)" \
    '{tickets:[{id:"t1",status:"todo",lastActivityAt:$a},{id:"t2",status:"todo",lastActivityAt:$b},{id:"t3",status:"Done",lastActivityAt:$c}]}' \
    > "$w/web/api_board_boards_b1_tickets.json"
  jq -n --arg h1 "$(iso 3600)" --arg h2 "$(iso 7200)" --arg o "$(iso $((31*86400)))" \
    '{id:"t1",comments:[{author:{name:"Dana Ruiz"},createdAt:$h1},{author:{name:"Harness Team Lead"},createdAt:$h2},
      {author:{name:"project-1 Team Harness"},createdAt:$h1},{author:"harness",createdAt:$h1},{author:{name:"Dana Ruiz"},createdAt:$o}]}' \
    > "$w/web/api_board_tickets_t1.json"
  jq -n --arg d "$(iso 86400 | sed 's/Z$/.000Z/')" '{ticket:{id:"t3",comments:[{author:"Client",createdAt:$d}]}}' > "$w/web/api_board_tickets_t3.json"
}
newh b3; write_app "$T/b3/w" "$T/b3/h"
pms b3 project-1 "$T/b3.json"
[ "$(val "$T/b3.json" board.status.todo)/$(val "$T/b3.json" board.status.done)/$(val "$T/b3.json" board.tickets)/$(val "$T/b3.json" board.active_30d)" = 2/1/3/2 ] && ok \
  || bad "B3: in-app status counts, total and active_30d (want 2/1/3/2): $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b3.json" 2>/dev/null)"
[ "$(val "$T/b3.json" board.client_comments_30d)" = 3 ] && [ "$(met "$T/b3.json" board.client_comments_30d)" = client_comments ] && ok \
  || bad "B4: Dana Ruiz, Harness Team Lead and Client count; *Harness and 31-day-old do not (want 3): $(row "$T/b3.json" board.client_comments_30d)"
[ "$(lnk "$T/b3.json" board.tickets)" = https://app.example.test/api/board ] && ok || bad "B3: the link is <prod><prefix>: $(lnk "$T/b3.json" board.tickets)"
grep -qF "authorization: Bearer $BOARD_TOKEN" "$T/b3/w/curl-hdr.log" 2>/dev/null && ok || bad "B3: the board token reaches curl as a header file"
grep -c 'api/board/tickets/' "$T/b3/w/curl.log" 2>/dev/null | grep -qx 2 && ok || bad "B3: only the 2 tickets active in 30d have their thread read: $(cat "$T/b3/w/curl.log")"

# B5 — not-configured and error.
newh b5a; touch "$T/b5a/w/gh.authfail"
pms b5a project-6-os "$T/b5a.json"
[ "$(jq -c '[.evidence[] | select(.source == "board") | [.id, .status, .value]]' "$T/b5a.json" 2>/dev/null)" = '[["board.tickets","not-configured",null]]' ] && ok \
  || bad "B5: gh auth fails gives one board.tickets not-configured row: $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b5a.json" 2>/dev/null)"
grep -q '^api ' "$T/b5a/w/gh.log" 2>/dev/null && bad "B5: no gh api call without gh auth" || ok
newh b5b
pms b5b project-9 "$T/b5b.json"
[ "$(st "$T/b5b.json" board.tickets)" = not-configured ] && [ ! -s "$T/b5b/w/curl.log" ] && ok \
  || bad "B5: no env file for an in-app board gives not-configured and no curl call: $(row "$T/b5b.json" board.tickets) $(cat "$T/b5b/w/curl.log" 2>/dev/null)"
newh b5c
pms b5c proj "$T/b5c.json"
[ "$(jq -c '[.evidence[] | select(.source == "board") | [.id, .status]]' "$T/b5c.json" 2>/dev/null)" = '[["board.tickets","not-configured"]]' ] && ok \
  || bad "B5: no registry row gives one not-configured row: $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b5c.json" 2>/dev/null)"
newh b5d; write_gh "$T/b5d/w"; echo 500 > "$T/b5d/w/gh/${GHK}_issues_p1.status"
pms b5d project-6-os "$T/b5d.json"
[ "$(st "$T/b5d.json" board.tickets)" = error ] && [ "$(val "$T/b5d.json" board.tickets)" = null ] \
  && [ "$(jq '[.evidence[] | select(.id | startswith("board.status."))] | length' "$T/b5d.json")" = 0 ] && ok \
  || bad "B5: a 500 on the issues read gives an error row, no status rows: $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b5d.json" 2>/dev/null)"
newh b5e; write_app "$T/b5e/w" "$T/b5e/h"; echo 7 > "$T/b5e/w/web/api_board_boards_b1_tickets.rc"
pms b5e project-1 "$T/b5e.json"
[ "$(st "$T/b5e.json" board.tickets)" = error ] && [ "$(st "$T/b5e.json" board.client_comments_30d)" = error ] && ok \
  || bad "B5: a failed in-app list read gives error rows: $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b5e.json" 2>/dev/null)"

# B6 — a slow thread read is cut at half the adapter timeout.
newh b6; write_app "$T/b6/w" "$T/b6/h"
echo 1 > "$T/b6/w/web/api_board_tickets_t1.sleep"; echo 1 > "$T/b6/w/web/api_board_tickets_t3.sleep"
pms b6 project-1 "$T/b6.json" PM_SIGNALS_ADAPTER_TIMEOUT_S=2; RC=$?
[ "$RC" = 0 ] && [ "$(jq '[.evidence[] | select(.id | startswith("adapter."))] | length' "$T/b6.json" 2>/dev/null)" = 0 ] && ok \
  || bad "B6: the board adapter ends inside the timeout (rc=$RC): $(jq -c '[.evidence[] | select(.status == "error")]' "$T/b6.json" 2>/dev/null)"
[ "$(val "$T/b6.json" board.status.todo)" = 2 ] && [ "$(met "$T/b6.json" board.client_comments_30d)" = client_comments_min ] && ok \
  || bad "B6: the status rows are kept and the comment row is a floor: $(jq -c '[.evidence[] | select(.source == "board")]' "$T/b6.json" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# U1-U3 — the per-project files
# ════════════════════════════════════════════════════════════════════════════
newh u
for p in $PROJECTS; do
  f="$REGD/$p.sh"; [ -f "$f" ] || continue
  out=$(HARNESS="$T/u/h" bash -c '. "$1" || exit 97; "$(compgen -A function pms_)" "$2"' _ "$f" "$p" 2>/dev/null)
  [ "$(jq -sc '[.[].source] | unique' <<<"$out" 2>/dev/null)" = '["churn","support","usage"]' ] \
    && jq -se 'length >= 7 and all(.status == "not-configured" and .value == null)' <<<"$out" >/dev/null 2>&1 && ok \
    || bad "U1: $p.sh alone gives usage, support and churn rows, all not-configured: $out"
done
mkdir -p "$T/u/h/state/pm-data"
echo '{"metrics":{"usage.signups":{"value":12,"link":"https://example.test/a"},"usage.first_run":{"value":"7"}}}' > "$T/u/h/state/pm-data/project-5.json"
pms u project-5 "$T/u2.json"
[ "$(val "$T/u2.json" usage.signups)/$(st "$T/u2.json" usage.signups)/$(lnk "$T/u2.json" usage.signups)" = "12/ok/https://example.test/a" ] && ok \
  || bad "U2: state/pm-data/project-5.json gives usage.signups 12 ok: $(row "$T/u2.json" usage.signups)"
[ "$(st "$T/u2.json" usage.first_run)/$(val "$T/u2.json" usage.first_run)" = not-configured/null ] && ok \
  || bad "U2: a non-number stays not-configured: $(row "$T/u2.json" usage.first_run)"

# ════════════════════════════════════════════════════════════════════════════
# E1-E2 — the empty state, no credentials
# ════════════════════════════════════════════════════════════════════════════
newh e; touch "$T/e/w/gh.authfail"
pms e project-6-os "$T/e1.json"; RC=$?
[ "$RC" = 0 ] && jq -e '.evidence | length > 0 and all(.status | type == "string")' "$T/e1.json" >/dev/null 2>&1 && ok \
  || bad "E1: rc 0 and every row has a string status (rc=$RC)"
[ "$(jq -c '[.evidence[].source] | unique' "$T/e1.json" 2>/dev/null)" = '["alerts","board","churn","cost","prd-rescore","qa","support","usage"]' ] && ok \
  || bad "E1: the 8 source kinds are present: $(jq -c '[.evidence[].source] | unique' "$T/e1.json" 2>/dev/null)"
[ "$(jq '[.evidence[] | select(.id | startswith("adapter."))] | length' "$T/e1.json" 2>/dev/null)" = 0 ] && ok \
  || bad "E1: no adapter error row: $(jq -c '[.evidence[] | select(.id | startswith("adapter."))]' "$T/e1.json" 2>/dev/null)"
for o in "$T"/*.json; do
  jq -e '[.evidence[] | select(.status == "not-configured" and .value != null)] | length == 0' "$o" >/dev/null 2>&1 \
    || bad "E2: a not-configured row with a value in $o: $(jq -c '[.evidence[] | select(.status == "not-configured" and .value != null)]' "$o")"
done
ok

# ════════════════════════════════════════════════════════════════════════════
# D1 / R1 / R2 / U3 — every adapter on full fixtures
# ════════════════════════════════════════════════════════════════════════════
newh f; write_cost "$T/f/h"; write_prd "$T/f/h"; write_gh "$T/f/w"
mkdir -p "$T/f/h/state/qa-run1"; cp "$T/q1/h/state/qa-run1/findings-ledger.jsonl" "$T/f/h/state/qa-run1/"
touch -d "@$((NOW - 3600))" "$T/f/h/state/qa-run1/findings-ledger.jsonl"
echo "$(date -u -d "@$((NOW - 3600))" '+%Y-%m-%d %H:%M:%SZ') [project-6-os] a fixture alert" > "$T/f/h/logs/ALERTS.log"
pms f project-6-os "$T/r1.json"; RC=$?
pms f project-6-os "$T/r1b.json"
H_A=$(jq -r .snapshot_hash "$T/r1.json" 2>/dev/null); H_B=$(jq -r .snapshot_hash "$T/r1b.json" 2>/dev/null)
[ -n "$H_A" ] && [ "$H_A" != null ] && [ "$H_A" = "$H_B" ] && ok || bad "D1: two runs on the same fixtures give one hash ($H_A / $H_B)"
[ "$RC" = 0 ] && [ "$(jq '[.evidence[] | select(.id | startswith("adapter."))] | length' "$T/r1.json" 2>/dev/null)" = 0 ] \
  && [ "$(jq -c '[.evidence[].source] | unique' "$T/r1.json" 2>/dev/null)" = '["alerts","board","churn","cost","prd-rescore","qa","support","usage"]' ] && ok \
  || bad "R1: the real registry on full fixtures: no adapter row, 8 kinds (rc=$RC): $(jq -c '[.evidence[] | select(.status == "error")]' "$T/r1.json" 2>/dev/null)"
jq -e '[.evidence[] | select(.status == "ok")] | length >= 10 and all(.value | type == "number") and all(.link | type == "string" and length > 0)' "$T/r1.json" >/dev/null 2>&1 && ok \
  || bad "R2: every ok row has a number and a link: $(jq -c '[.evidence[] | select(.status == "ok")]' "$T/r1.json" 2>/dev/null)"
for p in $PROJECTS; do
  pms f "$p" "$T/u3-$p.json"
  jq -e '[.evidence[] | [.id, .source]] | length == (unique | length)' "$T/u3-$p.json" >/dev/null 2>&1 && ok \
    || bad "U3: a duplicate (id, source) for $p: $(jq -c '[.evidence[] | [.id, .source]] | group_by(.) | map(select(length > 1))' "$T/u3-$p.json" 2>/dev/null)"
done

# ════════════════════════════════════════════════════════════════════════════
# S1 — no credential in an output file, a stderr or a curl argv
# ════════════════════════════════════════════════════════════════════════════
LEAK=$(grep -rlF -e "$BOARD_TOKEN" -e "$JOBS_SECRET" -e tok-fixture-gh "$T"/*.json "$T"/*/err "$T"/*/w/curl.log "$T"/*/w/gh.log 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "S1: a credential is in: $LEAK"

echo "pm-signals-adapters: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
