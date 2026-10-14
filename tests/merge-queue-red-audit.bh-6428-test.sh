#!/bin/bash
# tests/merge-queue-red-audit.bh-6428-test.sh — BH-6428: the fleet audit lists
# every PR the box merge queue landed in the last N days whose head CI was not
# success at merge time.
#
# Driven: bin/merge-queue-red-audit.sh runs WHOLE in a scratch tree whose
# bin/jobs-client.sh and bin/lib/gh-rest.sh are fixture stubs (_jobs_req and
# gh_rest answer from files and log every call). The clock is pinned with
# MQ_AUDIT_NOW.
#   U1 runs all success before merged_at            -> not listed
#   U2 a run completed failure before merged_at     -> listed failure
#   U3 a run still in progress at merged_at         -> listed pending
#   U4 a row outside --days                         -> ignored; count line right
#   U5 ledger unreadable -> rc 75, no count line; a PR read failure -> unreadable=
#   U6 no write call (no PUT/PATCH/POST)
#   U7 a run created after merged_at is not counted (the rerun that went green later)
#   U8 a project read at the 500-row cap is named incomplete
#   U9 the project-6#216 shape: ci failure at 07:2x, merged 07:26:24Z -> failure
# Run from anywhere: bash tests/merge-queue-red-audit.bh-6428-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

A="$T/h"; mkdir -p "$A/bin/lib" "$A/env" "$A/fx/gh"
cp "$DIR/bin/merge-queue-red-audit.sh" "$A/bin/merge-queue-red-audit.sh"
cat > "$A/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --projects) printf 'project-6-os\nproject-3\n' ;;
  project-6-os) echo example-org/project-6 ;;
  project-3) echo example-org/project-3 ;;
esac
EOF
chmod +x "$A/bin/fleet-conf.sh"
# _jobs_req <method> <path> — answers fx/mq.<project>.json, rc fx/mq.rc (default 0).
cat > "$A/bin/jobs-client.sh" <<'EOF'
_jobs_req() {
  echo "jobs $1 $2" >> "$HARNESS/calls"
  local p; p=$(sed -n 's/.*project=\([^&]*\).*/\1/p' <<<"$2")
  local rc; rc=$(cat "$HARNESS/fx/mq.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  cat "$HARNESS/fx/mq.$p.json" 2>/dev/null || echo '{"merge_queue":[]}'
}
EOF
# gh_rest <method> <path> — answers fx/gh/<path with / ? & = as _>, rc .rc beside it.
cat > "$A/bin/lib/gh-rest.sh" <<'EOF'
gh_rest() {
  echo "gh $1 $2" >> "$HARNESS/calls"
  local k; k=$(tr '/?&=' '____' <<<"$2")
  [ -e "$HARNESS/fx/gh/$k" ] || return 44
  local rc; rc=$(cat "$HARNESS/fx/gh/$k.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  cat "$HARNESS/fx/gh/$k"
}
# The real library sources its variable-assigning face at its end; so does the stub.
. "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh"
EOF
# The real gh_rest_var (bin/lib/gh-rest-var.sh) over the stub gh_rest above.
scratch_install_closure bin/lib/gh-rest-var.sh "$A" >/dev/null || { echo "FAIL: cannot install bin/lib/gh-rest-var.sh"; exit 1; }
NOW=$(date -u -d 2026-10-13T08:00:00Z +%s)

row() { jq -nc --arg p "$1" --argjson n "$2" --arg r "$3" --arg u "$4" '{project:$p,pr:$n,status:"landed",repo:$r,enqueued_at:$u,updated_at:$u}'; }
pull() { # pull <slug> <n> <head> <merged_at|null>
  local k; k=$(tr '/?&=' '____' <<<"repos/$1/pulls/$2")
  jq -nc --arg h "$3" --arg m "$4" '{number:1, head:{sha:$h}, merged_at:(if $m == "null" then null else $m end)}' > "$A/fx/gh/$k"
}
runs() { # runs <slug> <head> <json-array-of-runs>
  local k; k=$(tr '/?&=' '____' <<<"repos/$1/actions/runs?head_sha=$2&per_page=50")
  jq -nc --argjson r "$3" '{total_count:($r|length), workflow_runs:$r}' > "$A/fx/gh/$k"
}
run() { # run <name> <status> <conclusion> <created> <updated> [attempt]
  jq -nc --arg n "$1" --arg s "$2" --arg c "$3" --arg cr "$4" --arg u "$5" --argjson a "${6:-1}" \
    '{name:$n,status:$s,conclusion:(if $c == "null" then null else $c end),created_at:$cr,run_started_at:$cr,updated_at:$u,run_attempt:$a}'
}
audit() { : > "$A/calls"; ( HARNESS="$A" HARNESS_ENV_DIR="$A/env" MQ_AUDIT_NOW="$NOW" bash "$A/bin/merge-queue-red-audit.sh" "$@" ) > "$T/out" 2>"$T/err"; RC=$?; }

MK=example-org/project-6; OM=example-org/project-3
H1=1111111111111111111111111111111111111111   # U1 all green
H2=1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912   # U2/U9 the #216 shape
H3=3333333333333333333333333333333333333333   # U3 pending at merge
H4=4444444444444444444444444444444444444444   # U4 outside the window
H7=7777777777777777777777777777777777777777   # U7 later green rerun is a new run after merge

{ echo '{"merge_queue":['
  row project-6-os 201 "$MK" 2026-10-12T10:00:00Z; echo ,
  row project-6-os 216 "$MK" 2026-10-13T07:26:24Z; echo ,
  row project-6-os 230 - 2026-10-11T09:00:00Z; echo ,
  row project-6-os 150 "$MK" 2026-09-30T09:00:00Z; echo ,
  row project-6-os 240 "$MK" 2026-10-10T09:00:00Z
  echo ']}'; } > "$A/fx/mq.project-6-os.json"
{ echo '{"merge_queue":['; row project-3 77 "$OM" 2026-10-12T12:00:00Z; echo ']}'; } > "$A/fx/mq.project-3.json"

pull "$MK" 201 "$H1" 2026-10-12T10:00:00Z
runs "$MK" "$H1" "[$(run ci completed success 2026-10-12T09:00:00Z 2026-10-12T09:20:00Z),$(run lint completed success 2026-10-12T09:00:00Z 2026-10-12T09:05:00Z),$(run docs completed skipped 2026-10-12T09:00:00Z 2026-10-12T09:00:10Z)]"
pull "$MK" 216 "$H2" 2026-10-13T07:26:24Z
runs "$MK" "$H2" "[$(run ci completed failure 2026-10-13T06:50:00Z 2026-10-13T07:20:00Z 2)]"
pull "$MK" 230 "$H3" 2026-10-11T09:00:00Z
runs "$MK" "$H3" "[$(run ci completed success 2026-10-11T08:50:00Z 2026-10-11T09:10:00Z)]"
pull "$MK" 150 "$H4" 2026-09-30T09:00:00Z
runs "$MK" "$H4" "[$(run ci completed failure 2026-09-30T08:00:00Z 2026-09-30T08:30:00Z)]"
pull "$MK" 240 "$H7" 2026-10-10T09:00:00Z
runs "$MK" "$H7" "[$(run ci completed failure 2026-10-10T08:00:00Z 2026-10-10T08:30:00Z 1),$(run ci completed success 2026-10-10T10:00:00Z 2026-10-10T10:20:00Z 1)]"
# project-3 #77: the PR read fails (rate limit) -> unreadable
k=$(tr '/?&=' '____' <<<"repos/$OM/pulls/77"); echo '{}' > "$A/fx/gh/$k"; echo 75 > "$A/fx/gh/$k.rc"

audit --days 7
[ "$RC" = 0 ] && ok || bad "the audit must exit 0 (rc $RC): $(cat "$T/err")"
# U1
grep -q $'^project-6-os\t201\t' "$T/out" && bad "U1 an all-green PR must not be listed: $(cat "$T/out")" || ok
# U2 / U9
grep -qx $'project-6-os\t216\texample-org/project-6\t1ad9442c\t2026-10-13T07:26:24Z\tfailure' "$T/out" && ok || bad "U2/U9 #216 must be listed failure: $(cat "$T/out")"
# U3: the slug comes from fleet.conf when the row has none; the run completed after merged_at
grep -qx $'project-6-os\t230\texample-org/project-6\t33333333\t2026-10-11T09:00:00Z\tpending' "$T/out" && ok || bad "U3 a run not completed at merged_at must be pending: $(cat "$T/out")"
# U4
grep -q $'\t150\t' "$T/out" && bad "U4 a row outside --days must be ignored: $(cat "$T/out")" || ok
grep -q "repos/$MK/pulls/150" "$A/calls" && bad "U4 a row outside the window must not be read from GitHub" || ok
# U7: the success run started after the merge; at merge time CI was failure
grep -qx $'project-6-os\t240\texample-org/project-6\t77777777\t2026-10-10T09:00:00Z\tfailure' "$T/out" && ok || bad "U7 a run created after merged_at must not count: $(cat "$T/out")"
# U5b: the PR read failure
grep -qx $'project-3\t77\texample-org/project-3\t\t-\tunreadable' "$T/out" && ok || bad "U5b a failed PR read must be listed unreadable: $(cat "$T/out")"
grep -qx 'merge-queue-red-audit: 3 of 5 merge-queue landings in 7d had head CI not success at merge time (unreadable=1, not_merged=0, incomplete=none)' "$T/out" \
  && ok || bad "U4 the count line must read 3 of 5 (unreadable=1): $(tail -1 "$T/out")"
# U6
grep -qE '^(jobs|gh) (PUT|PATCH|POST|DELETE) ' "$A/calls" && bad "U6 the audit must not write: $(grep -E 'PUT|PATCH|POST|DELETE' "$A/calls")" || ok
grep -q "^jobs GET /api/merge-queue?project=project-6-os&status=landed&limit=500" "$A/calls" && ok || bad "U6 the ledger read must ask for landed rows per project: $(cat "$A/calls")"

# --days 1 narrows the window to 2026-10-12T08:00Z..: #216, #201 and project-3 #77
audit --days 1
tail -1 "$T/out" | grep -q '^merge-queue-red-audit: 1 of 3 merge-queue landings in 1d .*(unreadable=1,' && ok || bad "U4b --days 1 must keep three rows: $(tail -1 "$T/out")"
grep -q $'\t230\t' "$T/out" && bad "U4b #230 (2026-10-11) is outside one day" || ok

# U8: a project read at the 500-row cap is named incomplete
python3 - "$A/fx/mq.project-3.json" <<'PY'
import json, sys
rows = [{"project": "project-3", "pr": i, "status": "landed", "repo": "example-org/project-3",
         "enqueued_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"} for i in range(1, 501)]
json.dump({"merge_queue": rows}, open(sys.argv[1], "w"))
PY
audit --days 7
tail -1 "$T/out" | grep -q 'incomplete=project-3)$' && ok || bad "U8 a capped read must be named incomplete: $(tail -1 "$T/out")"

# U5: the ledger is unreadable -> rc 75, no count line
echo 1 > "$A/fx/mq.rc"
audit --days 7
[ "$RC" = 75 ] && ok || bad "U5 an unreadable ledger must exit 75 (rc $RC)"
grep -q '^merge-queue-red-audit: [0-9]' "$T/out" && bad "U5 no count line on an unreadable ledger: $(cat "$T/out")" || ok
grep -q 'could not be read (rc 1)' "$T/err" && ok || bad "U5 the reason must be on stderr: $(cat "$T/err")"
rm -f "$A/fx/mq.rc"

# Bad --days is refused before any read
audit --days x
[ "$RC" = 2 ] && [ ! -s "$A/calls" ] && ok || bad "a bad --days must exit 2 before any read (rc $RC)"

echo "merge-queue-red-audit.bh-6428: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
