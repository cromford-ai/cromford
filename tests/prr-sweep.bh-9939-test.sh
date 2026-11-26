#!/bin/bash
# tests/prr-sweep.bh-9939-test.sh — BH-9939 (BH-9926 wave 7): the slow safety
# sweep bin/prr-sweep.sh, which compares the PR record with GitHub for the
# open PRs of each fleet repo and repairs each difference.
#
# The production entry point runs in a scratch harness. GitHub is a stub `gh`
# that logs each call (gh_rest's transport). The jobs worker is a stub
# _jobs_req over one JSON file per repo that keeps the worker's rule: a field
# is replaced only when its stored time is not newer than the write's `at`.
#
#   A1   a record that differs in 1 field gets 1 fix and 1 PRR_SWEEP_FIX line;
#        a second sweep makes 0 fixes
#   A2   50 open PRs and no change: 5 GitHub calls or less, 0 fixes
#   A3   a record with no check for a run GitHub has gets 1 checks fix; a
#        record check that differs from the run gets 1 checks fix
#   A4   a record status that differs from GitHub gets 1 statuses fix, and a
#        pending record status is read before the rotation
#   A5   a lost `labeled` webhook (a hold label) gets 1 labels fix
#   A6   a record field newer than the sweep start is kept: 0 fixes, 1 STALE line
#   A7   a PR that left GitHub's open list gets 1 state fix and 1 pulls/<n> read
#   A8   each sweep writes the sync stamp and the default-branch and cross-repo
#        memos; a repo that is not due makes 0 calls
#   A9   the trust window and the interval: registry defaults, the code
#        fallback, and a smaller window shortens the interval
#   A10  tickets-snapshot-push in step record between two sweeps: 0
#        pulls?state=open calls and 0 PRR_MISS why=stale lines
#   A11  fixes above the 24-hour limit fire one alert id; a lower count resolves it
#   A12  the raise rule on fixture clocks, and no raise when a sweep did not
#        complete in each of the 7 days
#   A13  the lane, its knobs, its cron line and its state path are registered
#   A14  tick starts one `project <p>` run per fleet project through pl_dispatch
#   A15  a sweep whose workflow-runs read fails is partial: it holds the
#        interval but writes no sweeps.tsv row, so 8 days of such sweeps raise
#        nothing; the same 8 days with the runs read working do raise
# Run: HARNESS_TEST_SANDBOX=1 bash tests/prr-sweep.bh-9939-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/prr-sweep.sh" ] || { echo "FAIL: bin/prr-sweep.sh is missing"; echo "prr-sweep.bh-9939: 0 passed, 1 failed"; exit 1; }

"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "prr-sweep.bh-9939: 0 passed, 1 failed"; exit 1; }

S="$T/h"; mkdir -p "$S/bin" "$S/env" "$S/logs" "$S/state" "$S/flags" "$T/fakebin" "$T/tmp" "$T/db" "$T/gh" "$T/settings"
scratch_install_closure bin/prr-sweep.sh "$S" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The raise step lists the seam files by name, so no closure scan sees them.
for f in "$DIR"/bin/lib/prr-shadow.d/*.sh; do scratch_install_closure "bin/lib/prr-shadow.d/$(basename "$f")" "$S" >/dev/null 2>&1 || true; done
# The suite sets its knobs in the environment, the way lane_env_apply exports them.
rm -f "$S/bin/lib/lane-gate.sh" "$S/bin/lib/wake-lanes.sh"
: > "$S/env/global.env"
echo local > "$S/state/box-name"
printf '#!/bin/bash\necho local\n' > "$S/bin/box-name.sh"
cat > "$S/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\$1" in --projects) cat "$T/projects" 2>/dev/null; exit 0 ;; esac
case "\$2" in repo) echo "o/\$1" ;; *) echo - ;; esac
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$T" > "$S/bin/lane-alert.sh"
chmod +x "$S/bin/"*.sh

# The stub jobs worker. Store: $T/db/<owner>_<repo>.json = {rows: {"<n>": row}, sync}.
cat > "$S/bin/jobs-client.sh" <<EOF
_jw_now() { date -u -d "@\$(cat "$T/now")" '+%Y-%m-%dT%H:%M:%SZ'; }
_jw_file() { local r=\${1#*repo=}; r=\${r%%&*}; printf '%s/db/%s.json' "$T" "\${r//\//_}"; }
_jw_save() { jq -c 'del(.out)' "\$1.new" > "\$1" && jq -c '.out' "\$1.new" && rm -f "\$1.new"; }
_jobs_req() {
  local m="\$1" p="\$2" body="\${3:-}" f n
  printf '%s %s\n' "\$m" "\$p" >> "$T/jobs-calls.txt"
  case "\$m \$p" in
    "GET /api/pr-records?"*number=*)
      f=\$(_jw_file "\$p"); n=\${p##*number=}; n=\${n%%&*}
      [ -r "\$f" ] || { echo '{"row":null,"age_s":null}'; return 0; }
      jq -c --arg n "\$n" '{row: (.rows[\$n] // null), age_s: 10}' "\$f" ;;
    "GET /api/pr-records?"*state=open*)
      f=\$(_jw_file "\$p")
      [ -r "\$f" ] || { echo '{"rows":[],"truncated":false,"missing":null,"unknown":0,"sync":null}'; return 0; }
      jq -c --argjson now "\$(cat "$T/now")" '{rows: [.rows[] | select(.state == "open")], truncated: false, missing: null, unknown: 0,
        sync: (if .sync then {synced_at: .sync, age_s: (\$now - (.sync | fromdateiso8601)), rows: 0} else null end)}' "\$f" ;;
    "PUT /api/pr-records")
      f="$T/db/\$(jq -r '.repo | gsub("/"; "_")' <<<"\$body").json"
      [ -r "\$f" ] || echo '{"rows":{},"sync":null}' > "\$f"
      jq -c --argjson b "\$body" --arg now "\$(_jw_now)" '
        (\$b.number | tostring) as \$n | (\$b.at // \$now) as \$at
        | (.rows[\$n] // {number: \$b.number, fields_at: {}}) as \$row
        | [\$b.fields | to_entries[] | select(((\$row.fields_at[.key]) // "") <= \$at)] as \$ap
        | .rows[\$n] = (\$row + (\$ap | from_entries) + {fields_at: (\$row.fields_at + (\$ap | map({key: .key, value: \$at}) | from_entries))})
        | .out = {row: .rows[\$n], applied: [\$ap[].key], stale: ([\$b.fields | keys[]] - [\$ap[].key])}' "\$f" > "\$f.new" || return 1
      _jw_save "\$f" ;;
    "POST /api/pr-record-lists")
      f="$T/db/\$(jq -r '.repo | gsub("/"; "_")' <<<"\$body").json"
      [ -r "\$f" ] || echo '{"rows":{},"sync":null}' > "\$f"
      jq -c --argjson b "\$body" --arg now "\$(_jw_now)" '
        (\$b.at // \$now) as \$at | [\$b.rows[].number | tostring] as \$in
        | reduce \$b.rows[] as \$r (.;
            (\$r.number | tostring) as \$n
            | (.rows[\$n] // {number: \$r.number, fields_at: {}}) as \$row
            | [\$r.fields | to_entries[] | select(((\$row.fields_at[.key]) // "") <= \$at)] as \$ap
            | .rows[\$n] = (\$row + (\$ap | from_entries) + {fields_at: (\$row.fields_at + (\$ap | map({key: .key, value: \$at}) | from_entries))}))
        | .rows |= with_entries(if (.value.state == "open") and ((.key | IN(\$in[])) | not) then .value.state = null else . end)
        | .sync = \$at | .out = {synced_at: \$at}' "\$f" > "\$f.new" || return 1
      _jw_save "\$f" ;;
    *) return 1 ;;
  esac
}
_setting_key_ok() { [[ "\${1:-}" =~ ^[a-z0-9._-]+\$ ]]; }
setting_get() { [ -r "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
setting_set() { printf '%s' "\$2" > "$T/settings/\$1"; printf '%s=%s\n' "\$1" "\$2" >> "$T/settings-writes.txt"; }
EOF

# The stub gh: `gh api -i -X GET <path> ...` from gh_rest. Answers from $T/gh/<owner>_<repo>/.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
A="\$*"
case "\$A" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api -i -X GET "*) ;;
  *) exit 1 ;;
esac
p="\$5"; r=\${p#repos/}; r=\$(printf '%s' "\$r" | cut -d/ -f1,2); d="$T/gh/\${r//\//_}"; sub=\${p#repos/\$r/}; sub=\${sub%%\?*}
# out runs at the end of a pipe (a subshell), so its exit ends only the pipe: each pipe into out is followed by exit 0.
out() { printf 'HTTP/1.1 200 OK\r\n\r\n'; cat; exit 0; }
case "\$sub" in
  pulls)
    case "\$A" in *"page=1"*) [ -r "\$d/open.json" ] && out < "\$d/open.json" ;; *) echo '[]' | out; exit 0 ;; esac ;;
  pulls/*)
    [ -r "\$d/pr-\${sub#pulls/}.json" ] && out < "\$d/pr-\${sub#pulls/}.json" ;;
  actions/runs)
    # runs.fail: GitHub refuses the runs read (an App token without actions:read).
    if [ -e "\$d/runs.fail" ]; then printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"Resource not accessible by integration"}'; exit 0; fi
    case "\$A" in *"page=1"*) if [ -r "\$d/runs.json" ]; then out < "\$d/runs.json"; else echo '{"total_count":0,"workflow_runs":[]}' | out; exit 0; fi ;;
      *) echo '{"total_count":0,"workflow_runs":[]}' | out; exit 0 ;; esac ;;
  commits/*/status)
    s=\${sub#commits/}; s=\${s%/status}
    if [ -r "\$d/status-\$s.json" ]; then out < "\$d/status-\$s.json"
    else echo '{"state":"success","statuses":[{"context":"lead-verdict","state":"success","description":"MERGE","updated_at":"2026-11-20T00:00:00Z"}]}' | out; exit 0; fi ;;
esac
printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'
EOF
chmod +x "$T/fakebin/gh"

NOW0=$(date -u -d '2026-11-26T12:00:00Z' +%s)
NOW=$NOW0
sha() { printf '%040x' "$1"; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# seed <repo-name> <count> — <count> open PRs, the same on GitHub and in the record.
seed() {
  local name="$1" c="$2" d="$T/gh/o_$1" i
  scratch_rm "$d"; mkdir -p "$d"; echo "$name" > "$T/projects"; PROJ=$name
  jq -nc --argjson c "$c" --arg r "o/$name" '
    def sha: tostring | ("0" * (40 - length)) + .;
    [range(1; $c + 1) | {number: ., title: "PR \(.)", draft: false, state: "open", body: "",
      html_url: "https://github.com/\($r)/pull/\(.)", created_at: "2026-11-19T00:00:00Z", updated_at: "2026-11-20T00:00:00Z",
      user: {login: "cromford[bot]"}, labels: [{name: "ai-build"}],
      head: {ref: "ticket/t-\(.)", sha: sha, repo: {full_name: $r}}, base: {ref: "main", sha: ("b" * 40), repo: {default_branch: "main", full_name: $r}}}]' > "$d/open.json"
  jq -c '{sync: null, rows: (map({key: (.number | tostring), value: {number, state: "open", title, draft: 0,
      head_ref: .head.ref, head_sha: .head.sha, base_ref: .base.ref, labels: [.labels[].name], checks: {},
      statuses: {"lead-verdict": {state: "success", description: "MERGE", sha: .head.sha, at: "2026-11-20T00:00:00Z"}},
      fields_at: {}}}) | from_entries)}' "$d/open.json" > "$T/db/o_$name.json"
}
# rec <repo-name> <jq filter> — edit the record store; ghl <repo-name> <jq filter> — edit GitHub's open list.
rec() { jq -c "$2" "$T/db/o_$1.json" > "$T/db/o_$1.json.t" && mv "$T/db/o_$1.json.t" "$T/db/o_$1.json"; }
ghl() { jq -c "$2" "$T/gh/o_$1/open.json" > "$T/gh/o_$1/open.json.t" && mv "$T/gh/o_$1/open.json.t" "$T/gh/o_$1/open.json"; }
recq() { jq -c "$2" "$T/db/o_$1.json"; }
fresh() { scratch_rm "$S/state"; mkdir -p "$S/state"; echo local > "$S/state/box-name"; : > "$S/logs/prr-shadow.log"; : > "$S/logs/prr-sweep.log"
          : > "$T/alerts.txt"; : > "$T/settings-writes.txt"; scratch_rm "$T/settings"; mkdir -p "$T/settings"; NOW=$NOW0; }
# sweep [VAR=val...] -- <args> — one run of the lane at clock $NOW; resets the call logs.
sweep() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/gh-calls.txt"; : > "$T/jobs-calls.txt"; echo "$NOW" > "$T/now"
  OUT=$( cd "$T" && env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$S" TMPDIR="$T/tmp" HARNESS_TEST_SANDBOX=1 \
      LANE_REGISTRY="$T/lanes.json" PRR_SWEEP_NOW="$NOW" "${envs[@]}" bash "$S/bin/prr-sweep.sh" "$@" 2>"$T/err" ); RC=$?
}
# cnt <regex> <file> — the count of matching lines; 0 for no file.
cnt() { if [ -r "$2" ]; then grep -c -- "$1" "$2" || true; else echo 0; fi; }
ghn()   { cnt '^api -i -X GET ' "$T/gh-calls.txt"; }
# Every gh invocation that goes to the network. `gh auth token` reads the local credential store.
ghnet() { cnt '^api ' "$T/gh-calls.txt"; }
ghall() { cnt . "$T/gh-calls.txt"; }
fixes() { cnt 'PRR_SWEEP_FIX ' "$S/logs/prr-shadow.log"; }
ledger() { cnt . "$S/state/prr-sweep/fixes.tsv"; }

# ---- A1: 1 field differs -> 1 fix, 1 line; the second sweep makes 0 ------------------
fresh; seed a1 3
ghl a1 '(.[] | select(.number == 2) | .draft) = true'
sweep -- project "$PROJ"
[ "$RC" = 0 ] && ok || bad "A1 tick rc $RC: $(head -5 "$T/err")"
[ "$(fixes)" = 1 ] && ok || bad "A1 exactly 1 PRR_SWEEP_FIX line, got $(fixes): $(cat "$S/logs/prr-shadow.log") / $(head -5 "$T/err")"
grep -q 'PRR_SWEEP_FIX repo=o/a1 n=2 field=draft' "$S/logs/prr-shadow.log" && ok || bad "A1 the line names repo, n and field: $(cat "$S/logs/prr-shadow.log")"
[ "$(recq a1 '.rows["2"].draft')" = true ] && ok || bad "A1 the record's draft is GitHub's value: $(recq a1 '.rows["2"].draft')"
[ "$(ledger)" = 1 ] && ok || bad "A1 the ledger holds 1 row, got $(ledger)"
NOW=$((NOW0 + 3600)); sweep -- project "$PROJ"
[ "$(ghn)" -ge 1 ] && ok || bad "A1 the second sweep, one interval later, must read GitHub"
[ "$(fixes)" = 1 ] && [ "$(ledger)" = 1 ] && ok || bad "A1 the second sweep makes 0 fixes (lines $(fixes), ledger $(ledger))"

# ---- A2 + A8: 50 open PRs, no change: <= 5 GitHub calls ------------------------------
fresh; seed a2 50
sweep -- project "$PROJ"
# The count is every network call, the rate_limit read of a cold budget memo included.
A2_CALLS=$(ghnet)
[ "$A2_CALLS" -ge 1 ] && [ "$A2_CALLS" -le 5 ] && ok || bad "A2 50 PRs with no change: 1..5 GitHub calls, got $A2_CALLS: $(cat "$T/gh-calls.txt")"
echo "A2 measured: $A2_CALLS GitHub calls for 50 open PRs with no change ($(ghn) REST reads + $(cnt '^api rate_limit' "$T/gh-calls.txt") rate_limit); not network: $(grep -v '^api ' "$T/gh-calls.txt" | sort | uniq -c | tr -s ' \n' ' ')"
[ "$(fixes)" = 0 ] && [ "$(ledger)" = 0 ] && ok || bad "A2 no change makes 0 fixes: $(cat "$S/logs/prr-shadow.log")"
[ "$(grep -c 'commits/.*/status' "$T/gh-calls.txt")" = 2 ] && ok || bad "A2 the status rotation reads 2 PRs: $(grep -c 'commits/.*/status' "$T/gh-calls.txt")"
[ "$(recq a2 '.sync')" = "\"$(iso "$NOW0")\"" ] && ok || bad "A8 the sweep writes the sync stamp at its start time: $(recq a2 '.sync')"
grep -q 'POST /api/pr-record-lists' "$T/jobs-calls.txt" && ok || bad "A8 the list goes through pr_record_list_sync: $(cat "$T/jobs-calls.txt" | sort | uniq -c)"
[ "$(head -1 "$S/state/prr-default-branch/o_a2" 2>/dev/null)" = main ] && [ "$(cnt 'false$' "$S/state/prr-default-branch/o_a2.cross")" = 50 ] && ok \
  || bad "A8 the list read writes the default-branch memo (main) and the cross-repo memo (50 same-repo rows): '$(head -1 "$S/state/prr-default-branch/o_a2" 2>/dev/null)' / $(cnt . "$S/state/prr-default-branch/o_a2.cross")"
FIRST=$(grep 'commits/.*/status' "$T/gh-calls.txt" | sort)
[ "$(cnt "^$NOW0	o_a2\$" "$S/state/prr-sweep/sweeps.tsv")" = 1 ] && [ -e "$S/state/prr-sweep/attempt/o_a2" ] && ok \
  || bad "A8 a completed sweep is 1 row in sweeps.tsv and 1 attempt stamp: $(cat "$S/state/prr-sweep/sweeps.tsv" 2>/dev/null) / $(grep -v '^$' "$S/logs/prr-sweep.log" | tail -4)"
NOW=$((NOW0 + 600)); sweep -- project "$PROJ"
[ "$(ghall)" = 0 ] && ok || bad "A8 a repo that is not due makes 0 GitHub calls, got $(ghall)"
[ "$(cnt . "$S/state/prr-sweep/sweeps.tsv")" = 1 ] && ok || bad "A8 a run that is not due adds no sweep row"
NOW=$((NOW0 + 3600)); sweep -- project "$PROJ"
[ "$(ghnet)" -le 5 ] && [ "$(ghnet)" -ge 1 ] && ok || bad "A8 the next due sweep: 1..5 calls, got $(ghnet)"
[ "$(grep 'commits/.*/status' "$T/gh-calls.txt" | sort)" != "$FIRST" ] && ok || bad "A2 the rotation must move to other PRs in the next sweep"
[ "$(recq a2 '.sync')" = "\"$(iso "$NOW")\"" ] && ok || bad "A8 the second sweep renews the stamp: $(recq a2 '.sync')"

# A sweep whose GitHub list read fails is tried, not completed: the raise rule must see the gap.
fresh; seed a8 2; rm -f "$T/gh/o_a8/open.json"
sweep -- project "$PROJ"
[ -e "$S/state/prr-sweep/attempt/o_a8" ] && [ "$(cnt . "$S/state/prr-sweep/sweeps.tsv")" = 0 ] && [ ! -e "$S/state/prr-sweep/last/o_a8" ] && [ "$(fixes)" = 0 ] && ok \
  || bad "A8 an unreadable GitHub list: 1 attempt stamp, 0 sweep rows, no last stamp, 0 fixes"
[ "$(recq a8 '.sync')" = null ] && ok || bad "A8 an unreadable GitHub list writes no sync stamp: $(recq a8 '.sync')"

# ---- A3: checks ------------------------------------------------------------------------
fresh; seed a3 3
jq -nc --arg h1 "$(sha 1)" --arg h3 "$(sha 3)" '{total_count: 3, workflow_runs: [
  {id: 11, name: "CI", head_sha: $h1, status: "completed", conclusion: "success", run_attempt: 1, run_started_at: "2026-11-26T11:20:00Z", updated_at: "2026-11-26T11:30:00Z"},
  {id: 12, name: "CI", head_sha: $h3, status: "completed", conclusion: "failure", run_attempt: 2, run_started_at: "2026-11-26T11:25:00Z", updated_at: "2026-11-26T11:35:00Z"},
  {id: 10, name: "CI", head_sha: $h3, status: "completed", conclusion: "success", run_attempt: 1, run_started_at: "2026-11-26T11:00:00Z", updated_at: "2026-11-26T11:10:00Z"},
  {id: 13, name: "CI", head_sha: ("f" * 40), status: "completed", conclusion: "failure", run_attempt: 1, run_started_at: "2026-11-26T11:25:00Z", updated_at: "2026-11-26T11:35:00Z"}]}' > "$T/gh/o_a3/runs.json"
rec a3 '.rows["3"].checks = {"workflow:CI": {status: "in_progress", conclusion: null, sha: .rows["3"].head_sha, at: "2026-11-26T11:25:00Z"}, "old": {status: "completed", conclusion: "success", sha: ("e" * 40), at: "2026-11-20T00:00:00Z"}}'
sweep -- project "$PROJ"
grep -q 'PRR_SWEEP_FIX repo=o/a3 n=1 field=checks' "$S/logs/prr-shadow.log" && ok || bad "A3 a record with no check for a run GitHub has gets 1 checks fix: $(cat "$S/logs/prr-shadow.log") / $(head -5 "$T/err")"
grep -q 'PRR_SWEEP_FIX repo=o/a3 n=3 field=checks' "$S/logs/prr-shadow.log" && ok || bad "A3 a record check that differs from the newest run gets 1 checks fix"
[ "$(fixes)" = 2 ] && ok || bad "A3 2 fixes (PR 1 and PR 3), got $(fixes): $(cat "$S/logs/prr-shadow.log")"
[ "$(recq a3 '.rows["1"].checks["workflow:CI"] | [.status, .conclusion, .sha]')" = "[\"completed\",\"success\",\"$(sha 1)\"]" ] && ok \
  || bad "A3 the record holds the run of PR 1: $(recq a3 '.rows["1"].checks')"
[ "$(recq a3 '.rows["3"].checks["workflow:CI"].conclusion')" = '"failure"' ] && ok || bad "A3 PR 3 holds the newest attempt (failure): $(recq a3 '.rows["3"].checks')"
[ "$(recq a3 '.rows["3"].checks | has("old")')" = true ] && ok || bad "A3 the write keeps the other entries of the checks object"
grep -q 'actions/runs' "$T/gh-calls.txt" && grep 'actions/runs' "$T/gh-calls.txt" | grep -q 'created=>=' && ok || bad "A3 the runs read is bounded by created>=: $(grep actions/runs "$T/gh-calls.txt")"
NOW=$((NOW0 + 3600)); sweep -- project "$PROJ"
[ "$(fixes)" = 2 ] && ok || bad "A3 the second sweep makes 0 fixes, lines now $(fixes)"

# ---- A4: statuses ----------------------------------------------------------------------
fresh; seed a4 10
rec a4 '.rows["7"].statuses["lead-verdict"].state = "pending" | .rows["7"].statuses["lead-verdict"].description = "review running"'
sweep -- project "$PROJ"
grep -q "commits/$(sha 7)/status" "$T/gh-calls.txt" && ok || bad "A4 a PR with a pending record status is read in this sweep: $(grep status "$T/gh-calls.txt")"
[ "$(fixes)" = 1 ] && grep -q 'PRR_SWEEP_FIX repo=o/a4 n=7 field=statuses' "$S/logs/prr-shadow.log" && ok || bad "A4 1 statuses fix for PR 7: $(cat "$S/logs/prr-shadow.log") / $(head -5 "$T/err")"
[ "$(recq a4 '.rows["7"].statuses["lead-verdict"] | [.state, .description, .sha]')" = "[\"success\",\"MERGE\",\"$(sha 7)\"]" ] && ok \
  || bad "A4 the record holds GitHub's status on the head: $(recq a4 '.rows["7"].statuses')"
[ "$(ghn)" -le 5 ] && ok || bad "A4 1 list + 1 runs + 1 pending + 2 rotation = 5 REST reads at most, got $(ghn)"

# ---- A5: a lost labeled webhook ---------------------------------------------------------
fresh; seed a5 3
ghl a5 '(.[] | select(.number == 2) | .labels) = [{name: "ai-build"}, {name: "hold"}]'
sweep -- project "$PROJ"
[ "$(fixes)" = 1 ] && grep -q 'PRR_SWEEP_FIX repo=o/a5 n=2 field=labels' "$S/logs/prr-shadow.log" && ok || bad "A5 1 labels fix: $(cat "$S/logs/prr-shadow.log")"
[ "$(recq a5 '.rows["2"].labels | sort')" = '["ai-build","hold"]' ] && ok || bad "A5 the record holds the hold label: $(recq a5 '.rows["2"].labels')"
# The same labels in another order are not a difference.
fresh; seed a5 3
ghl a5 '(.[] | select(.number == 2) | .labels) = [{name: "z"}, {name: "a"}]'; rec a5 '.rows["2"].labels = ["a", "z"]'
sweep -- project "$PROJ"
[ "$(fixes)" = 0 ] && ok || bad "A5 label order is not a difference: $(cat "$S/logs/prr-shadow.log")"

# ---- A6: newer only ------------------------------------------------------------------------
fresh; seed a6 3
jq -c --arg at "$(iso $((NOW0 + 100)))" '.rows["2"].title = "newer title" | .rows["2"].fields_at.title = $at' "$T/db/o_a6.json" > "$T/db/o_a6.json.t" && mv "$T/db/o_a6.json.t" "$T/db/o_a6.json"
sweep -- project "$PROJ"
[ "$(fixes)" = 0 ] && [ "$(ledger)" = 0 ] && ok || bad "A6 a refused write is not a fix: $(cat "$S/logs/prr-shadow.log")"
grep -q 'PRR_SWEEP_STALE repo=o/a6 n=2 field=title' "$S/logs/prr-shadow.log" && ok || bad "A6 1 PRR_SWEEP_STALE line: $(cat "$S/logs/prr-shadow.log")"
[ "$(recq a6 '.rows["2"].title')" = '"newer title"' ] && ok || bad "A6 the newer record value stays: $(recq a6 '.rows["2"].title')"

# ---- A7: a PR that left the open list ------------------------------------------------------
fresh; seed a7 4
ghl a7 'map(select(.number != 4))'
jq -nc --arg h "$(sha 4)" '{number: 4, state: "closed", merged_at: "2026-11-26T11:00:00Z", draft: false, head: {ref: "ticket/t-4", sha: $h}, base: {ref: "main", sha: ("b" * 40)}, labels: []}' > "$T/gh/o_a7/pr-4.json"
sweep -- project "$PROJ"
[ "$(grep -c 'repos/o/a7/pulls/4' "$T/gh-calls.txt")" = 1 ] && ok || bad "A7 exactly 1 pulls/4 read: $(cat "$T/gh-calls.txt")"
[ "$(fixes)" = 1 ] && grep -q 'PRR_SWEEP_FIX repo=o/a7 n=4 field=state' "$S/logs/prr-shadow.log" && ok || bad "A7 1 state fix: $(cat "$S/logs/prr-shadow.log") / $(head -5 "$T/err")"
[ "$(recq a7 '.rows["4"].state')" = '"merged"' ] && ok || bad "A7 the record says merged: $(recq a7 '.rows["4"].state')"
# A PR GitHub has and the record does not.
fresh; seed a7 4
rec a7 'del(.rows["3"])'
sweep -- project "$PROJ"
# The new row has no statuses, so the status compare of PR 3 can add one statuses fix.
[ "$(cnt 'PRR_SWEEP_FIX repo=o/a7 n=3 field=state' "$S/logs/prr-shadow.log")" = 1 ] && [ "$(cnt 'PRR_SWEEP_FIX .* field=\(draft\|title\|labels\|head_sha\|head_ref\|base_ref\)' "$S/logs/prr-shadow.log")" = 0 ] && ok \
  || bad "A7 a PR the record lacks is 1 state fix, not 1 for each field: $(cat "$S/logs/prr-shadow.log")"
[ "$(recq a7 '.rows["3"] | [.state, .head_sha]')" = "[\"open\",\"$(sha 3)\"]" ] && ok || bad "A7 the record now holds PR 3: $(recq a7 '.rows["3"]')"

# ---- A9: the trust window and the interval ---------------------------------------------------
INT=$(jq -r '.lanes[] | select(.id == "prr-sweep") | .knobs[] | select(.env == "PRR_SWEEP_INTERVAL_MIN") | .default' "$T/lanes.json")
SLACK=$(jq -r '.lanes[] | select(.id == "prr-sweep") | .knobs[] | select(.env == "PRR_SWEEP_LIST_SLACK_S") | .default' "$T/lanes.json")
WIN=$(jq -r '.libs[] | select(.id == "pr-record") | .knobs[] | select(.env == "PR_RECORD_LIST_MAX_AGE_S") | .default' "$T/lanes.json")
[ "$INT" = 60 ] && ok || bad "A9 the sweep interval starts at 60 minutes, got '$INT'"
[[ "$WIN" =~ ^[0-9]+$ ]] && [[ "$INT" =~ ^[0-9]+$ ]] && [[ "$SLACK" =~ ^[0-9]+$ ]] && [ "$WIN" -ge $((INT * 60 + SLACK)) ] && ok \
  || bad "A9 the list trust window default ($WIN s) is below the sweep interval default ($INT min) plus the slack ($SLACK s)"
CODE=$(env -i PATH="$PATH" HOME="$T" bash -c '. "$1"; pr_record_list_max_age' _ "$DIR/bin/lib/pr-record.sh" 2>/dev/null)
[ "$CODE" = "$WIN" ] && ok || bad "A9 the code fallback of PR_RECORD_LIST_MAX_AGE_S ($CODE) must equal the registry default ($WIN)"
fresh; seed a9 2
sweep PR_RECORD_LIST_MAX_AGE_S=2400 -- project "$PROJ"
grep -q 'PRR_SWEEP_WINDOW window_s=2400 interval_s=3600 used_s=2100' "$S/logs/prr-shadow.log" && ok || bad "A9 a 2400 s window shortens a 60 min interval to 2100 s: $(cat "$S/logs/prr-shadow.log")"
NOW=$((NOW0 + 2000)); sweep PR_RECORD_LIST_MAX_AGE_S=2400 -- project "$PROJ"
[ "$(ghall)" = 0 ] && ok || bad "A9 2000 s after a sweep the repo is not due (used 2100 s)"
NOW=$((NOW0 + 2101)); sweep PR_RECORD_LIST_MAX_AGE_S=2400 -- project "$PROJ"
[ "$(ghn)" -ge 1 ] && ok || bad "A9 2101 s after a sweep the repo is due, before the 2400 s window ends"
fresh; seed a9 2
sweep PRR_SWEEP_INTERVAL_MIN=0 -- project "$PROJ"
[ "$(ghall)" = 0 ] && ok || bad "A9 interval 0 is off: 0 calls, got $(ghall)"

# ---- A10: tickets-snapshot-push between two sweeps -----------------------------------------
S2="$T/h2"; mkdir -p "$S2/bin" "$S2/env" "$S2/logs" "$S2/state" "$S2/flags" "$T/fb2"
if scratch_install_closure bin/tickets-snapshot-push.sh "$S2" >/dev/null; then
  scratch_install_closure bin/lib/prr-shadow.d/tickets-snapshot-push.sh "$S2" >/dev/null 2>&1 || true
  rm -f "$S2/bin/lib/lane-gate.sh" "$S2/bin/lib/wake-lanes.sh"
  PA="pz$$"
  echo secret-fixture > "$S2/env/.watchdog-secret"; : > "$S2/env/global.env"; : > "$S2/env/$PA.env"
  printf '#!/bin/bash\necho "%s"\n' "$PA" > "$S2/bin/fleet-projects-or-alert.sh"
  cat > "$S2/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo https://board.example ;; board_prefix) echo /api ;; repo) echo "example-org/snap-$1" ;; *) echo - ;; esac
EOF
  printf '#!/bin/bash\necho tok-fixture-1\n' > "$S2/bin/internal-token-for.sh"
  printf '#!/bin/bash\nexit 0\n' > "$S2/bin/alert-line.sh"
  chmod +x "$S2/bin/"*.sh
  # The sync stamp is one minute younger than the sweep interval: the oldest
  # stamp a record lane sees between two sweeps.
  AGE=$((INT * 60 - 60))
  cat > "$S2/bin/jobs-client.sh" <<EOF
_jobs_req() {
  case "\$2" in
    /api/pr-records\?*state=open*)
      echo '{"rows":[{"number":7,"title":"AB-7 open work","head_ref":"ticket/ab-7","author":"partner-dev","updated_at":"2026-11-20T07:00:00Z","url":"https://github.com/example-org/snap-$PA/pull/7","created_at":"2026-11-19T07:00:00Z"}],"truncated":false,"sync":{"synced_at":"2026-11-24T00:00:00Z","age_s":$AGE},"missing":null,"unknown":0}'
      return 0 ;;
  esac
  return 1
}
EOF
  cat > "$T/fb2/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh2-calls.txt"
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"matching-refs"*|*"pulls?state=open"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]'; exit 0 ;;
esac
printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'
EOF
  cat > "$T/fb2/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    */boards) echo '[{"id":"b1"}]'; exit 0 ;;
    */boards/b1/tickets) echo '[{"key":"AB-7","status":"in_progress","title":"open work"}]'; exit 0 ;;
    @*) cp "\${a#@}" "$T/pushed2.json" ;;
  esac
done
exit 0
EOF
  chmod +x "$T/fb2/gh" "$T/fb2/curl"; : > "$T/gh2-calls.txt"
  # PR_RECORD_LIST_MAX_AGE_S is not set: the lane uses the default of this tree.
  ( cd "$T" && env HARNESS="$S2" PATH="$T/fb2:$PATH" TMPDIR="$T/tmp" GH_SOURCE=record \
      TICKETS_SNAPSHOT_MERGED_KEEP_DAYS=30 WATCHDOG_URL=http://watchdog.invalid \
      bash "$S2/bin/tickets-snapshot-push.sh" ) >/dev/null 2>&1
  [ -s "$T/pushed2.json" ] && ok || bad "A10 the snapshot was not pushed"
  [ "$(cnt 'pulls?state=open' "$T/gh2-calls.txt")" = 0 ] && ok \
    || bad "A10 a record tick with a stamp $AGE s old must make 0 pulls?state=open calls: $(grep pulls "$T/gh2-calls.txt")"
  [ "$(cnt 'PRR_MISS.*why=stale' "$S2/logs/prr-shadow.log")" = 0 ] && ok \
    || bad "A10 0 PRR_MISS why=stale lines: $(cat "$S2/logs/prr-shadow.log")"
else
  bad "A10 closure install of bin/tickets-snapshot-push.sh"
fi

# ---- A11: the 24-hour limit --------------------------------------------------------------
fresh; seed a11 4
ghl a11 'map(.draft = true)'
sweep PRR_SWEEP_FIX_ALERT_24H=2 -- project "$PROJ"
[ "$(fixes)" = 4 ] && ok || bad "A11 4 fixes expected, got $(fixes)"
[ "$(grep -c -- '--id prr-sweep-fixes:o/a11' "$T/alerts.txt")" = 1 ] && ! grep -q -- '--resolve' "$T/alerts.txt" && ok \
  || bad "A11 4 fixes above the limit 2 fire the alert id one time: $(cat "$T/alerts.txt")"
grep -q 'webhook' "$T/alerts.txt" && ok || bad "A11 the alert text says a webhook is missing: $(cat "$T/alerts.txt")"
: > "$T/alerts.txt"; NOW=$((NOW0 + 90000)); sweep PRR_SWEEP_FIX_ALERT_24H=2 -- project "$PROJ"
grep -q -- '--resolve' "$T/alerts.txt" && grep -q -- '--id prr-sweep-fixes:o/a11' "$T/alerts.txt" && ok \
  || bad "A11 25 hours later with 0 new fixes the alert is resolved: $(cat "$T/alerts.txt")"
fresh; seed a11 4
ghl a11 'map(.draft = true)'
sweep PRR_SWEEP_FIX_ALERT_24H=0 -- project "$PROJ"
[ ! -s "$T/alerts.txt" ] && ok || bad "A11 limit 0 is no alert: $(cat "$T/alerts.txt")"

# ---- A12: the raise rule on fixture clocks ---------------------------------------------------
KEY=lib.cadence-backstop.cadence_backstop_min_merge_conductor
raise_setup() { # raise_setup <first-sweep age in seconds>
  fresh; echo a12 > "$T/projects"; mkdir -p "$S/state/prr-sweep"
  echo $((NOW0 - $1)) > "$S/state/prr-sweep/first-sweep"
  # The repo was tried, and a sweep completed in each of the last 7 24-hour windows.
  mkdir -p "$S/state/prr-sweep/attempt"; : > "$S/state/prr-sweep/attempt/o_a12"
  for k in 0 1 2 3 4 5 6; do printf '%s\to_a12\n' $((NOW0 - k * 86400 - 3600)); done > "$S/state/prr-sweep/sweeps.tsv"
  echo record > "$T/settings/lane.merge-conductor.gh_source"
  echo shadow > "$T/settings/lane.blocked-resolver.gh_source"
}
raise_setup $((6 * 86400))
sweep -- raise
[ ! -s "$T/settings-writes.txt" ] && ok || bad "A12 day 6: no raise: $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1))
sweep -- raise --dry-run
[ ! -s "$T/settings-writes.txt" ] && grep -q 'merge-conductor' <<<"$OUT" && ok || bad "A12 --dry-run writes nothing and names the lane: '$OUT' / $(cat "$T/settings-writes.txt")"
sweep -- raise
[ "$(cat "$T/settings-writes.txt")" = "$KEY=120" ] && ok || bad "A12 day 7, 0 fixes: the record lane's row goes 60 -> 120, and the shadow lane gets none: $(cat "$T/settings-writes.txt") / $OUT / $(head -5 "$T/err")"
grep -q "PRR_SWEEP_RAISE lane=merge-conductor key=$KEY from=60 to=120" "$S/logs/prr-shadow.log" && ok || bad "A12 1 PRR_SWEEP_RAISE line: $(cat "$S/logs/prr-shadow.log")"
sweep -- raise
[ "$(grep -c . "$T/settings-writes.txt")" = 1 ] && ok || bad "A12 a second run makes no second raise: $(cat "$T/settings-writes.txt")"
NOW=$((NOW0 + 7 * 86400 + 1)); sweep -- raise
[ "$(grep -c . "$T/settings-writes.txt")" = 1 ] && ok || bad "A12 a row at the knob's max (120) is not raised again: $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1)); echo 100 > "$T/settings/$KEY"
sweep -- raise
[ "$(cat "$T/settings-writes.txt")" = "$KEY=120" ] && ok || bad "A12 100 x 2 stops at the knob's max 120: $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1)); printf '%s\to/a12\t5\tlabels\n' $((NOW0 - 3 * 86400)) > "$S/state/prr-sweep/fixes.tsv"
sweep -- raise
[ ! -s "$T/settings-writes.txt" ] && ok || bad "A12 a fix 3 days ago stops the raise: $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1)); printf '%s\to/a12\t5\tlabels\n' $((NOW0 - 8 * 86400)) > "$S/state/prr-sweep/fixes.tsv"
sweep -- raise
[ "$(cat "$T/settings-writes.txt")" = "$KEY=120" ] && ok || bad "A12 a fix 8 days ago is outside the window: $(cat "$T/settings-writes.txt")"
# 0 fixes from a sweep that did not run is not evidence.
raise_setup $((7 * 86400 + 1)); grep -v "^$((NOW0 - 4 * 86400 - 3600))	" "$S/state/prr-sweep/sweeps.tsv" > "$T/sw.t"; cp "$T/sw.t" "$S/state/prr-sweep/sweeps.tsv"
sweep -- raise
[ ! -s "$T/settings-writes.txt" ] && grep -q 'o_a12: a sweep completed in 6 of the last 7 days' <<<"$OUT" && ok || bad "A12 one day with no completed sweep stops the raise: '$OUT' / $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1)); : > "$S/state/prr-sweep/attempt/o_other"
sweep -- raise
[ ! -s "$T/settings-writes.txt" ] && grep -q 'o_other: a sweep completed in 0 of the last 7 days' <<<"$OUT" && ok || bad "A12 a tried repo with no completed sweep stops the raise: '$OUT' / $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1))
sweep PRR_SWEEP_RAISE_FACTOR=1 -- raise
[ ! -s "$T/settings-writes.txt" ] && ok || bad "A12 factor 1 is no raise: $(cat "$T/settings-writes.txt")"
raise_setup $((7 * 86400 + 1)); printf '%s\to/a12\t5\tlabels\n' $((NOW0 - 3600)) > "$S/state/prr-sweep/fixes.tsv"
sweep -- report
grep -q 'repo=o/a12 fixes_24h=1 fixes_7d=1' <<<"$OUT" && grep -q 'lane=merge-conductor step=record' <<<"$OUT" && grep -q 'swept=o_a12 days=7/7' <<<"$OUT" && ok || bad "A12 report prints the counts for each repo and lane: $OUT / $(head -5 "$T/err")"

# ---- A14: tick starts one project run per fleet project through the runner -------------
fresh; printf 'pa\npb\n' > "$T/projects"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/dispatch.txt"\n' "$T" > "$S/bin/project-lane-run.sh"; chmod +x "$S/bin/project-lane-run.sh"
: > "$T/dispatch.txt"
sweep -- tick
for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(cnt . "$T/dispatch.txt")" -ge 2 ] && break; sleep 0.5; done
[ "$(cnt "^prr-sweep pa [0-9][0-9]* $S/bin/prr-sweep.sh project\$" "$T/dispatch.txt")" = 1 ] && [ "$(cnt "^prr-sweep pb [0-9][0-9]* $S/bin/prr-sweep.sh project\$" "$T/dispatch.txt")" = 1 ] && ok \
  || bad "A14 tick starts 'prr-sweep.sh project' for each project through project-lane-run.sh: $(cat "$T/dispatch.txt") / $(head -5 "$T/err") / $(tail -2 "$S/logs/prr-sweep.log")"
[ "$(ghall)" = 0 ] && ok || bad "A14 the tick itself makes 0 GitHub calls"

# ---- A13: registered ---------------------------------------------------------------------------
L=$(jq -c '.lanes[] | select(.id == "prr-sweep") | [.scope, .script, .switch.name, .wired]' "$T/lanes.json")
[ "$L" = '["hub","bin/prr-sweep.sh","lane-off-prr-sweep",true]' ] && ok || bad "A13 the lane is registered: $L"
for k in PRR_SWEEP_INTERVAL_MIN PRR_SWEEP_FIX_ALERT_24H PRR_SWEEP_PR_READS_MAX PRR_SWEEP_STATUS_ROTATE PRR_SWEEP_RUNS_PAGES PRR_SWEEP_LIST_SLACK_S PRR_SWEEP_QUIET_DAYS PRR_SWEEP_RAISE_FACTOR; do
  jq -e --arg k "$k" '.lanes[] | select(.id == "prr-sweep") | .knobs[] | select(.env == $k and .type == "int")' "$T/lanes.json" >/dev/null && ok || bad "A13 knob $k is not registered as an int"
done
grep -q 'hub-lease.sh check && /root/harness/bin/prr-sweep.sh tick' "$DIR"/cron/lanes/*-prr-sweep.cron 2>/dev/null && ok || bad "A13 the cron line is lease-gated"
[ "$(jq -c '[.[] | select(.path == "prr-sweep") | .class]' "$DIR/catalog/state-paths.d/9939-prr-sweep.json" 2>/dev/null)" = '["cache"]' ] && ok || bad "A13 state path prr-sweep must be class cache"
grep -q 'prr-sweep' "$DIR/docs/EVENTS.md" && ok || bad "A13 docs/EVENTS.md section 8 names the sweep"

# ---- A15: a partial sweep is not a completed sweep -----------------------------------------
# a15_days <fail|ok> — 8 daily sweeps of repo a15, the first one 7 days + 1 hour ago.
a15_days() {
  fresh; seed a15 3; [ "$1" = fail ] && : > "$T/gh/o_a15/runs.fail"
  echo record > "$T/settings/lane.merge-conductor.gh_source"
  A15_RC=""
  for k in 7 6 5 4 3 2 1 0; do NOW=$((NOW0 - k * 86400 - 3600)); sweep -- project a15; A15_RC="$A15_RC$RC"; done
  NOW=$NOW0
}
a15_days fail
[ "$A15_RC" = 00000000 ] && ok || bad "A15 each partial sweep run ends rc 0, got $A15_RC: $(head -5 "$T/err")"
[ "$(cnt . "$S/state/prr-sweep/sweeps.tsv")" = 0 ] && ok || bad "A15 a failed runs read writes no sweeps.tsv row: $(cat "$S/state/prr-sweep/sweeps.tsv")"
[ "$(head -c 20 "$S/state/prr-sweep/last/o_a15" 2>/dev/null)" = "$((NOW0 - 3600))" ] && ok || bad "A15 a partial sweep still renews the interval stamp: $(cat "$S/state/prr-sweep/last/o_a15" 2>/dev/null)"
grep -q 'o/a15 .*partial=1' "$S/logs/prr-sweep.log" && ok || bad "A15 the sweep line says partial=1: $(grep o/a15 "$S/logs/prr-sweep.log" | tail -1)"
NOW=$((NOW0 - 3600 + 600)); sweep -- project a15
[ "$(ghall)" = 0 ] && ok || bad "A15 a partial sweep holds the next try for the interval: $(ghall) calls"
NOW=$NOW0; sweep -- raise
[ ! -s "$T/settings-writes.txt" ] && grep -q 'o_a15: a sweep completed in 0 of the last 7 days' <<<"$OUT" && ok \
  || bad "A15 8 days of partial sweeps raise nothing: '$OUT' / $(cat "$T/settings-writes.txt")"
a15_days ok
[ "$(cnt . "$S/state/prr-sweep/sweeps.tsv")" = 8 ] && ok || bad "A15 control: 8 completed sweeps are 8 rows: $(cnt . "$S/state/prr-sweep/sweeps.tsv")"
sweep -- raise
[ "$(cat "$T/settings-writes.txt")" = "$KEY=120" ] && ok || bad "A15 control: 8 completed days with 0 fixes do raise: '$OUT' / $(cat "$T/settings-writes.txt")"

echo "prr-sweep.bh-9939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
