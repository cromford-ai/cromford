#!/bin/bash
# tests/tickets-snapshot-record.bh-9933-test.sh — BH-9933 (BH-9926.1):
# bin/tickets-snapshot-push.sh reads each board repo's open PR list from the
# PR record (pr_record_list) through bin/lib/prr-shadow.sh.
#
# The production entry point runs in a scratch harness: 3 board projects on 3
# repos, a fake `curl` for the boards and the watchdog POST, a stub `gh` that
# logs each REST read (gh_rest's transport), and a stub jobs client whose
# _jobs_req answers /api/pr-records?...state=open... from a fixture.
#   1. GH_SOURCE=record: 0 `pulls?state=open` reads; the in-progress tickets
#      get their claims from the record rows.
#   2. GH_SOURCE=off: 3 `pulls?state=open` reads, 0 record reads, and the
#      pushed projects equal the record run's (what the snapshot sends does
#      not change).
#   3. GH_SOURCE=shadow, one repo's record misses a PR: 3 pulls reads, 3
#      record reads and exactly 1 PRR_SHADOW lane=tickets-snapshot-push line.
#   4. GH_SOURCE=record, one repo's record is stale: that repo falls back to
#      GitHub (1 pulls read) and logs PRR_MISS ... why=stale fallback=github.
# Run from anywhere: bash tests/tickets-snapshot-record.bh-9933-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

S="$T/h"; mkdir -p "$S/bin" "$S/env" "$S/logs" "$S/state" "$S/flags" "$T/fakebin" "$T/tmp"
scratch_install_closure bin/tickets-snapshot-push.sh "$S" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The lane's seam is loaded by name (prr_seam_load), so no closure scan sees it.
scratch_install_closure bin/lib/prr-shadow.d/tickets-snapshot-push.sh "$S" >/dev/null 2>&1 || true
# lane-gate would read settings rows and wake-lanes the wake backstop: this
# suite sets its knobs in the environment, the way lane_env_apply exports them.
rm -f "$S/bin/lib/lane-gate.sh" "$S/bin/lib/wake-lanes.sh"

# The lane writes /tmp/snap-<project>.json, so the names carry this run's pid:
# two runs of this suite on one box must not share a file.
PA="pa$$"; PB="pb$$"; PC="pc$$"; PROJS="$PA $PB $PC"
echo secret-fixture > "$S/env/.watchdog-secret"
: > "$S/env/global.env"; for p in $PROJS; do : > "$S/env/$p.env"; done
printf '#!/bin/bash\necho "%s"\n' "$PROJS" > "$S/bin/fleet-projects-or-alert.sh"
cat > "$S/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo https://board.example ;; board_prefix) echo /api ;; repo) echo "example-org/snap-$1" ;; *) echo - ;; esac
EOF
printf '#!/bin/bash\necho tok-fixture-1\n' > "$S/bin/internal-token-for.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alerts.txt"\n' "$T" > "$S/bin/alert-line.sh"
chmod +x "$S/bin/"*.sh

# The stub jobs client: _jobs_req answers the record list from
# $T/rec/<repo-safe>.json and logs each path. Nothing else is answered.
mkdir -p "$T/rec"
cat > "$S/bin/jobs-client.sh" <<EOF
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs-calls.txt"
  case "\$2" in
    /api/pr-records\?*state=open*)
      local r=\${2#*repo=}; r=\${r%%&*}; r=\${r//\//_}
      [ -r "$T/rec/\$r.json" ] || return 1
      cat "$T/rec/\$r.json"; return 0 ;;
  esac
  return 1
}
EOF

# The stub gh: REST reads arrive as `gh api -i -X GET <path>` from gh_rest.
mkdir -p "$T/ans"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
A="\$*"
case "\$A" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api -i -X GET "*) ;;
  *) exit 1 ;;
esac
f=""
case "\$A" in
  *"pulls?state=open"*) r=\${A#*repos/}; r=\${r%%/pulls*}; f="$T/ans/open-\${r//\//_}" ;;
  *"matching-refs"*)    f="$T/ans/refs" ;;
esac
[ -n "\$f" ] && [ -r "\$f" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "\$f"
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    */boards) echo '[{"id":"b1"}]'; exit 0 ;;
    */boards/b1/tickets) echo '[{"key":"AB-7","status":"in_progress","title":"open work"},{"key":"AB-9","status":"review","title":"more work"},{"key":"AB-5","status":"todo","title":"later"}]'; exit 0 ;;
    @*) cp "\${a#@}" "$T/pushed.json" ;;
  esac
done
exit 0
EOF
chmod +x "$T/fakebin/curl"
echo '[]' > "$T/ans/refs"

# Fixtures: per repo, PR 7 (AB-7) and PR 9 (AB-9), in GitHub's REST shape and
# in the record's list shape (bin/lib/pr-record.sh pr_record_list rows).
fixture() { # fixture <project> [record-drop-number] [sync age]
  local r="example-org/snap-$1" safe="example-org_snap-$1" lr="example-org_snap-$1"
  jq -nc --arg r "$r" '[
    {number:9, title:"AB-9 more work", head:{ref:"ticket/ab-9"}, user:{login:"cromford[bot]"}, updated_at:"2026-11-20T09:00:00Z", html_url:("https://github.com/"+$r+"/pull/9")},
    {number:7, title:"AB-7 open work", head:{ref:"ticket/ab-7"}, user:{login:"partner-dev"}, updated_at:"2026-11-20T07:00:00Z", html_url:("https://github.com/"+$r+"/pull/7")}]' \
    > "$T/ans/open-$safe"
  jq -nc --arg r "$r" --argjson drop "${2:-0}" --argjson age "${3:-30}" '{
    rows: ([
      {number:9, title:"AB-9 more work", head_ref:"ticket/ab-9", author:"cromford[bot]", updated_at:"2026-11-20T09:00:00Z", url:("https://github.com/"+$r+"/pull/9"), created_at:"2026-11-19T09:00:00Z"},
      {number:7, title:"AB-7 open work", head_ref:"ticket/ab-7", author:"partner-dev", updated_at:"2026-11-20T07:00:00Z", url:("https://github.com/"+$r+"/pull/7"), created_at:"2026-11-19T07:00:00Z"}
    ] | map(select(.number != $drop))),
    truncated:false, sync:{synced_at:"2026-11-24T00:00:00Z", age_s:$age}, missing:null, unknown:0}' \
    > "$T/rec/$lr.json"
}
for p in $PROJS; do fixture "$p"; done

snap() { # snap <GH_SOURCE>
  : > "$T/gh-calls.txt"; : > "$T/jobs-calls.txt"; : > "$S/logs/prr-shadow.log"; rm -f "$T/pushed.json"
  ( cd "$T" && env HARNESS="$S" PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" GH_SOURCE="$1" \
      TICKETS_SNAPSHOT_MERGED_KEEP_DAYS=30 WATCHDOG_URL=http://watchdog.invalid \
      bash "$S/bin/tickets-snapshot-push.sh" ) >/dev/null 2>&1
}
pulls() { grep -c 'pulls?state=open' "$T/gh-calls.txt" 2>/dev/null || true; }
recs()  { grep -c '/api/pr-records?' "$T/jobs-calls.txt" 2>/dev/null || true; }
# The fields the open list feeds: each ticket's claim and the external lanes.
owned() { jq -c '[.projects | to_entries[] | {p: .key, claims: [.value.tickets[] | {key, claim}], ext: .value.external_lanes}] | sort_by(.p)' "$T/pushed.json" 2>/dev/null; }
claim() { jq -r --arg p "$1" --arg k "$2" '.projects[$p].tickets[] | select(.key==$k) | .claim | "\(.kind) \(.pr) \(.actor) \(.ref)"' "$T/pushed.json" 2>/dev/null; }

# ---- 1. record: 0 pulls reads ----------------------------------------------------
snap record
[ -s "$T/pushed.json" ] && ok || bad "1: the snapshot was not pushed"
[ "$(pulls)" = 0 ] && ok || bad "1: step record must make 0 pulls?state=open reads, got $(pulls): $(cat "$T/gh-calls.txt")"
[ "$(recs)" = 3 ] && ok || bad "1: one record read per repo (3), got $(recs): $(cat "$T/jobs-calls.txt")"
grep -qF "/api/pr-records?repo=example-org/snap-$PA&state=open&order=created&limit=100" "$T/jobs-calls.txt" && ok \
  || bad "1: the record read is the open window of TICKETS_SNAPSHOT_OPEN_PR_LIMIT (100): $(cat "$T/jobs-calls.txt")"
[ "$(claim "$PB" AB-7)" = "pr 7 partner-dev ticket/ab-7" ] && ok || bad "1: AB-7's claim comes from the record rows, got '$(claim "$PB" AB-7)'"
[ "$(claim "$PC" AB-9)" = "pr 9 cromford[bot] ticket/ab-9" ] && ok || bad "1: AB-9's claim comes from the record rows, got '$(claim "$PC" AB-9)'"
[ ! -s "$S/logs/prr-shadow.log" ] && ok || bad "1: a record hit logs nothing: $(cat "$S/logs/prr-shadow.log")"
REC_PROJ=$(owned)

# ---- 2. off: today's reads, same snapshot ------------------------------------------
snap off
[ "$(pulls)" = 3 ] && ok || bad "2: step off reads pulls?state=open once per repo (3), got $(pulls)"
[ "$(recs)" = 0 ] && ok || bad "2: step off makes 0 record reads, got $(recs)"
OFF_PROJ=$(owned)
[ -n "$OFF_PROJ" ] && [ "$OFF_PROJ" = "$REC_PROJ" ] && ok || bad "2: the pushed claims must be the same in off and record: off=[$OFF_PROJ] record=[$REC_PROJ]"
grep -q 'per_page=100' "$T/gh-calls.txt" && ok || bad "2: the GitHub read keeps per_page=100: $(grep pulls "$T/gh-calls.txt")"

# ---- 3. shadow: one mismatch, one line ----------------------------------------------
fixture "$PB" 9
snap shadow
[ "$(pulls)" = 3 ] && [ "$(recs)" = 3 ] && ok || bad "3: shadow reads both sides for each repo (pulls $(pulls), record $(recs))"
[ "$(grep -c 'PRR_SHADOW lane=tickets-snapshot-push' "$S/logs/prr-shadow.log")" = 1 ] && ok \
  || bad "3: exactly 1 PRR_SHADOW line for the one mismatched repo: $(cat "$S/logs/prr-shadow.log")"
grep -qF "PRR_SHADOW lane=tickets-snapshot-push key=example-org/snap-$PB#open record=1 github=2 only_record=0 only_github=1 changed=0" "$S/logs/prr-shadow.log" && ok \
  || bad "3: the line names the repo key and counts: $(cat "$S/logs/prr-shadow.log")"
[ "$(owned)" = "$OFF_PROJ" ] && ok || bad "3: shadow pushes the GitHub answer"
fixture "$PB"

# ---- 4. record, stale: fall back for that repo ------------------------------------------
fixture "$PC" 0 99999
snap record
[ "$(pulls)" = 1 ] && grep -qF "repos/example-org/snap-$PC/pulls?state=open" "$T/gh-calls.txt" && ok \
  || bad "4: only the stale repo reads GitHub (got $(pulls)): $(grep pulls "$T/gh-calls.txt")"
grep -qF "PRR_MISS lane=tickets-snapshot-push key=example-org/snap-$PC#open why=stale fallback=github" "$S/logs/prr-shadow.log" && ok \
  || bad "4: PRR_MISS why=stale fallback=github: $(cat "$S/logs/prr-shadow.log")"
[ "$(owned)" = "$OFF_PROJ" ] && ok || bad "4: the fallback keeps the snapshot the same"
fixture "$PC"

echo "tickets-snapshot-record.bh-9933: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
