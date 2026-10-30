#!/bin/bash
# tests/unblock-infra-parks-db.bh-8735-test.sh — BH-8735: the Tackler infra
# collector's parks come from the D1 pr_state ledger, not from
# state/merge-conductor/pr-state.tsv (a file on one box).
#
# WHAT RUNS. The shipped bin/lib/unblock/collectors/infra.sh in a subshell. Its
# input seam unblock_infra_src runs for real; only _jobs_req under it is a stub
# that answers from a fixture map and logs every call. The ledger rows are
# built in the shape mc_ledger_put (bin/lib/mc/settle.sh) PUTs: status = the
# conductor state, detail = the JSON of since, head_sha, reviewed_sha, verdict,
# merge_state, reason, record, url, alerted.
#
#   P1  two pr_state rows give two branch-park records with the ledger's fields
#   P2  a pr-state.tsv with another park (mode 000) does not change the output
#   P3  the ledger answers rc 1, a 404 or a body that is not JSON: one
#       source-unreadable record naming parks; no jobs transport is rc 1
#   P4  a page of exactly `limit` rows marks every park truncated; limit - 1 not
#   P5  the request path, and UNBLOCK_PARKS_READ_LIMIT (set, bad, out of range)
#   P6  0 non-GET requests, 0 gh/curl calls
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-infra-parks-db.bh-8735-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-infra-parks-db: jq is required"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LIB="$DIR/bin/lib/unblock/collectors/infra.sh"
H="$T/h"
mkdir -p "$H/state/merge-conductor" "$T/fakebin"
for w in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/writes.log"\nexit 1\n' "$w" "$T" > "$T/fakebin/$w"
  chmod +x "$T/fakebin/$w"
done
NOW=1792508400   # 2026-10-20T15:00:00Z
PATH_DEF='/api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=1000'

# row <key> <status> <since-iso> <head> <reason> — one ledgers row as
# mc_ledger_put writes it (job_ledger_put pr_state <key> <status> <detail>).
row() {
  jq -nc --arg k "$1" --arg s "$2" --arg since "$3" --arg h "$4" --arg w "$5" '
    {kind: "pr_state", key: $k, status: $s, actor: null, job_id: null,
     created_at: $since, updated_at: $since,
     detail: ({since: $since, head_sha: $h, reviewed_sha: $h, verdict: "APPROVE", merge_state: "DIRTY",
               reason: $w, record: "-", url: ("https://github.com/" + ($k | sub("#"; "/pull/"))), alerted: "-"} | tojson)}'
}
# page <file> <row-json>... — a GET /api/ledger list body.
page() { local f="$1"; shift; printf '%s\n' "$@" | jq -sc '{ledgers: ., as_of: "2026-10-20T15:00:00Z"}' > "$f"; }

# collect <answer-file|rc1|404> [env...] — one park collect; prints the JSONL.
collect() {
  local ans="$1"; shift
  ( export HARNESS="$H" HARNESS_TEST_SANDBOX=1 UNBLOCK_NOW="$NOW" ANS="$ans" FXT="$T" PATH="$T/fakebin:$PATH"
    for kv in "$@"; do export "${kv?}"; done
    . "$LIB" || exit 9
    _jobs_req() {
      printf '%s %s\n' "$1" "$2" >> "$FXT/jobs.log"
      [ "$1" = GET ] || return 1
      case "$ANS" in rc1) JOBS_HTTP=503; return 1 ;; 404) JOBS_HTTP=404; return 2 ;; esac
      case "$2" in /api/ledger\?kind=pr_state\&status=BLOCKED_HUMAN\&limit=*) ;; *) JOBS_HTTP=404; return 2 ;; esac
      JOBS_HTTP=200; cat "$ANS"
    }
    unblock_collect_infra --family park )
}

# ============================================================================
# P1 — two ledger rows, two records.
# ============================================================================
HA=aaaa1111bbbb2222cccc3333dddd4444eeee5555
HB=ffff6666aaaa7777bbbb8888cccc9999dddd0000
page "$T/p1.json" \
  "$(row 'example-org/alpha#101' BLOCKED_HUMAN 2026-10-20T12:00:00Z "$HA" 'conflict-unresolvable: both sides edit bin/x.sh')" \
  "$(row 'example-org/alpha#106' BLOCKED_HUMAN 2026-10-20T13:00:00Z "$HB" 'rebase-gate-red: lint')" \
  "$(row 'example-org/alpha#107' BLOCKED_HUMAN 2026-10-20T13:00:00Z "$HB" 'iron-law: model id')"
rm -f "$T/jobs.log" "$T/writes.log"
OUT=$(collect "$T/p1.json")
eq "P1 two branch-park records (the iron-law park is not one)" "$(jq -s -c 'map(select(.kind == "branch-park") | .pr)' <<<"$OUT")" "[101,106]"
R101=$(jq -c 'select(.pr == 101)' <<<"$OUT")
eq "P1 #101 fields" "$(jq -c '[.subject, .repo, .pr, .head, .mechanical_rung, .url]' <<<"$R101")" \
  "[\"example-org/alpha#101\",\"example-org/alpha\",101,\"$HA\",\"failed\",\"https://github.com/example-org/alpha/pull/101\"]"
eq "P1 #101 park_reason" "$(jq -r .park_reason <<<"$R101")" "conflict-unresolvable: both sides edit bin/x.sh"
eq "P1 #101 stall_at is the ledger's since" "$(jq -r .stall_at <<<"$R101")" "2026-10-20T12:00:00Z"
eq "P1 #106 rung n/a" "$(jq -r 'select(.pr == 106) | .mechanical_rung' <<<"$OUT")" "n/a"
eq "P1 not truncated" "$(jq -s -c 'map(.truncated) | unique' <<<"$OUT")" "[false]"
# A row whose detail does not parse is skipped, the others still pass.
jq -c '.ledgers += [{kind: "pr_state", key: "example-org/alpha#108", status: "BLOCKED_HUMAN", detail: "not json"}]' "$T/p1.json" > "$T/p1b.json"
OUT=$(collect "$T/p1b.json")
eq "P1 a row whose detail is not JSON is skipped" "$(jq -s -c 'map(.pr)' <<<"$OUT")" "[101,106]"

# ============================================================================
# P2 — pr-state.tsv is no longer an input.
# ============================================================================
printf 'example-org/alpha#199\tBLOCKED_HUMAN\t1792497600\th9\th9\t0\tconflict-unresolvable: file only\thttps://github.com/example-org/alpha/pull/199\n' \
  > "$H/state/merge-conductor/pr-state.tsv"
OUT_FILE_READABLE=$(collect "$T/p1.json")
eq "P2 a park only in pr-state.tsv gives no record" "$(jq -s -c 'map(.pr)' <<<"$OUT_FILE_READABLE")" "[101,106]"
chmod 000 "$H/state/merge-conductor/pr-state.tsv"
OUT=$(collect "$T/p1.json")
eq "P2 pr-state.tsv mode 000: the same output" "$OUT" "$OUT_FILE_READABLE"
eq "P2 pr-state.tsv mode 000: no source-unreadable record" "$(jq -s 'map(select(.kind == "source-unreadable")) | length' <<<"$OUT")" 0
chmod 600 "$H/state/merge-conductor/pr-state.tsv"
rm -f "$H/state/merge-conductor/pr-state.tsv"
OUT=$(collect "$T/p1.json")
eq "P2 no pr-state.tsv at all: the same output" "$OUT" "$OUT_FILE_READABLE"

# ============================================================================
# P3 — an unreadable ledger.
# ============================================================================
for a in rc1 404; do
  OUT=$(collect "$a")
  eq "P3 ledger $a: one source-unreadable record naming parks" \
    "$(jq -s -c 'map(select(.kind == "source-unreadable") | .unknown)' <<<"$OUT")" '[["parks"]]'
  eq "P3 ledger $a: no park record" "$(jq -s 'map(select(.kind == "branch-park")) | length' <<<"$OUT")" 0
done
printf 'not json' > "$T/p3.json"
OUT=$(collect "$T/p3.json")
eq "P3 a body that is not JSON: unreadable parks" "$(jq -s -c 'map(select(.kind == "source-unreadable") | .unknown)' <<<"$OUT")" '[["parks"]]'
printf '[]' > "$T/p3b.json"
OUT=$(collect "$T/p3b.json")
eq "P3 a body that is not an object: unreadable parks" "$(jq -s -c 'map(select(.kind == "source-unreadable") | .unknown)' <<<"$OUT")" '[["parks"]]'
printf '{"ledgers":"x"}' > "$T/p3c.json"
OUT=$(collect "$T/p3c.json")
eq "P3 ledgers not an array: unreadable parks" "$(jq -s -c 'map(select(.kind == "source-unreadable") | .unknown)' <<<"$OUT")" '[["parks"]]'
SEAM=$( (export HARNESS="$H" HARNESS_TEST_SANDBOX=1; . "$LIB"; unset -f _jobs_req 2>/dev/null; unblock_infra_src parks; echo "rc=$?") )
eq "P3 the seam with no jobs transport: rc 1, no output" "$SEAM" "rc=1"

# ============================================================================
# P4 — truncation at the page limit.
# ============================================================================
mkpage() { # mkpage <file> <n> — n BLOCKED_HUMAN rows: 3 conflict parks, the rest iron-law parks
  local i w
  for i in $(seq 1 "$2"); do
    w='iron-law: model id'; [ "$i" -le 3 ] && w=conflict-unresolvable
    row "example-org/alpha#$((2000+i))" BLOCKED_HUMAN 2026-10-20T12:00:00Z "$HA" "$w"
  done | jq -sc '{ledgers: ., as_of: "2026-10-20T15:00:00Z"}' > "$1"
}
# The page cap is separate from the 100-record cap: 3 records from a full page
# are still a partial view, because the rows past the page were never read.
mkpage "$T/p4a.json" 101
OUT=$(collect "$T/p4a.json" UNBLOCK_PARKS_READ_LIMIT=101)
eq "P4 a page of exactly limit rows: every record truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" "[3,[true]]"
mkpage "$T/p4b.json" 100
OUT=$(collect "$T/p4b.json" UNBLOCK_PARKS_READ_LIMIT=101)
eq "P4 limit - 1 rows: not truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" "[3,[false]]"
mkpage "$T/p4c.json" 200
OUT=$(collect "$T/p4c.json" UNBLOCK_PARKS_READ_LIMIT=200)
eq "P4 limit 200, 200 rows: truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" "[3,[true]]"
OUT=$(collect "$T/p4c.json")
eq "P4 the default limit 1000, 200 rows: not truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" "[3,[false]]"

# ============================================================================
# P5 — the request path and the knob.
# ============================================================================
for c in "|1000" "200|200" "abc|1000" "5000|1000" "100|1000" "101|101" "1000|1000"; do
  IFS='|' read -r v want <<<"$c"
  rm -f "$T/jobs.log"
  if [ -n "$v" ]; then collect "$T/p1.json" "UNBLOCK_PARKS_READ_LIMIT=$v" >/dev/null; else collect "$T/p1.json" >/dev/null; fi
  eq "P5 UNBLOCK_PARKS_READ_LIMIT='$v': the request" "$(cat "$T/jobs.log")" "GET /api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=$want"
done
rm -f "$T/jobs.log"; collect "$T/p1.json" >/dev/null
eq "P5 the default path" "$(cut -d' ' -f2 "$T/jobs.log")" "$PATH_DEF"

# ============================================================================
# P6 — reads only.
# ============================================================================
rm -f "$T/jobs.log" "$T/writes.log"
collect "$T/p1.json" >/dev/null; collect rc1 >/dev/null
eq "P6 0 non-GET requests" "$(grep -vc '^GET ' "$T/jobs.log" | tr -d ' ')" 0
eq "P6 0 gh/curl calls" "$(cat "$T/writes.log" 2>/dev/null | grep -c . | tr -d ' ')" 0

echo "unblock-infra-parks-db (BH-8735): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
