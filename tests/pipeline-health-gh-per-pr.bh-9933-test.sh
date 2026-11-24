#!/bin/bash
# tests/pipeline-health-gh-per-pr.bh-9933-test.sh — BH-9933 (BH-9926.1): the
# daily "GitHub calls per merged PR" line per repo (bin/lib/gh-per-pr-daily.sh
# gpd_run, called from bin/pipeline-health.sh) and its fleet-status field
# (bin/fleet-status-push.sh section 13, gh_per_merged_pr).
#
#   1. due: no state file, an old stamp, an unparseable stamp and a stamp in the
#      future by more than EVERY_S run; a stamp 1 s or EVERY_S-1 old does not;
#      EVERY_S=0 is off. Unset knobs give 86400 / 168 h / 120 s.
#   2. the real bin/gh-ledger-report.sh (fleet + merged seam files): the state
#      file has one entry per repo with the fixture values and window_h 168;
#      logs/pipeline-health.log has one `gh per merged PR (168h):` line per repo.
#   3. a report that fails or times out: state has `error` and repos []; no
#      ALERTS.log line; a fleet `unknown` line is an error too.
#   4. section 13 of bin/fleet-status-push.sh adds gh_per_merged_pr to SNAP; an
#      unparseable or missing file leaves SNAP as it was.
#   5. the pipeline-health block sits in the `PH_MODE != project` group and
#      calls gpd_run.
# Run from anywhere: bash tests/pipeline-health-gh-per-pr.bh-9933-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-per-pr-daily.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }
unset PH_GH_PER_PR_EVERY_S PH_GH_PER_PR_WINDOW_H PH_GH_PER_PR_TIMEOUT_S GH_LEDGER_REPORT_FLEET_FILE GH_LEDGER_REPORT_MERGED_FILE H

NOW=1795500000
H1="$T/h1"; mkdir -p "$H1/bin" "$H1/logs" "$H1/state" "$T/fakebin"
# A `timeout` on PATH that records its first argument, then runs the rest.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/timeout-args.txt"\nshift\nexec "$@"\n' "$T" > "$T/fakebin/timeout"
chmod +x "$T/fakebin/timeout"
export PATH="$T/fakebin:$PATH"
# A stub report: logs its argv, prints two repo lines.
cat > "$H1/bin/gh-ledger-report.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/report-calls.txt"
echo 'gh-ledger-report: fleet gh_ledger (D1) window x'
echo 'per_merged_pr=5 counted=10 merged=2'
echo 'per_merged_pr_repo=A/x counted=10 merged=2 per_merged_pr=5'
echo 'per_merged_pr_repo=B/y counted=0 merged=0 per_merged_pr=n/a'
exit \${STUB_RC:-0}
EOF
chmod +x "$H1/bin/gh-ledger-report.sh"
STATE1="$H1/state/gh-per-merged-pr.json"
gpd() { # gpd <harness> <now> [VAR=value ...] — gpd_run in a fresh shell
  local h="$1" now="$2"; shift 2
  env "$@" HARNESS="$h" bash -c '. "$1" && gpd_run "$2"' _ "$LIB" "$now" >/dev/null 2>&1
}
reports() { grep -c . "$T/report-calls.txt" 2>/dev/null || true; }

# ---- 1. due -------------------------------------------------------------------------
due_case() { # due_case <name> <state content|NONE> <want runs 0|1> [VAR=value ...]
  local name="$1" st="$2" want="$3"; shift 3
  : > "$T/report-calls.txt"
  if [ "$st" = NONE ]; then rm -f "$STATE1"; else printf '%s' "$st" > "$STATE1"; fi
  gpd "$H1" "$NOW" "$@"
  [ "$(reports)" = "$want" ] && ok || bad "due $name: want $want report run(s), got $(reports)"
}
due_case no-state NONE 1
due_case old "{\"generated_at\":$((NOW - 86400))}" 1
due_case unparseable '{"generated_at":"soon"}' 1
due_case garbage 'not json' 1
due_case future "{\"generated_at\":$((NOW + 86401))}" 1
due_case one-second "{\"generated_at\":$((NOW - 1))}" 0
due_case every-minus-1 "{\"generated_at\":$((NOW - 86399))}" 0
due_case off NONE 0 PH_GH_PER_PR_EVERY_S=0
due_case knob-short "{\"generated_at\":$((NOW - 600))}" 1 PH_GH_PER_PR_EVERY_S=300
: > "$T/report-calls.txt"; : > "$T/timeout-args.txt"; rm -f "$STATE1"
gpd "$H1" "$NOW"
grep -qx -- '--fleet --last 168h --per-merged-pr --by-repo' "$T/report-calls.txt" && ok || bad "1: default window 168h: $(cat "$T/report-calls.txt")"
[ "$(cat "$T/timeout-args.txt")" = 120 ] && ok || bad "1: default timeout 120, got '$(cat "$T/timeout-args.txt")'"
[ "$(jq -r .generated_at "$STATE1" 2>/dev/null)" = "$NOW" ] && ok || bad "1: generated_at = now: $(cat "$STATE1")"
: > "$T/report-calls.txt"; rm -f "$STATE1"
gpd "$H1" "$NOW" PH_GH_PER_PR_WINDOW_H=abc
grep -q -- '--last 168h' "$T/report-calls.txt" && ok || bad "1: a non-number window falls back to 168h: $(cat "$T/report-calls.txt")"
grep -q "PH_GH_PER_PR_WINDOW_H='abc'" "$H1/logs/pipeline-health.log" && ok || bad "1: a bad knob writes one log line: $(cat "$H1/logs/pipeline-health.log")"
: > "$T/report-calls.txt"; rm -f "$STATE1"
gpd "$H1" "$NOW" PH_GH_PER_PR_WINDOW_H=24
grep -q -- '--last 24h' "$T/report-calls.txt" && ok || bad "1: the window knob reaches the report: $(cat "$T/report-calls.txt")"

# ---- 2. the real report ---------------------------------------------------------------
H2="$T/h2"; mkdir -p "$H2/logs" "$H2/state"
scratch_install_closure bin/gh-ledger-report.sh "$H2" >/dev/null || bad "2: closure install"
printf '%s' '{"group":"repo","rows":[{"repo":"A/x","calls":12,"counted":10},{"repo":"B/y","calls":5,"counted":5}],"truncated":false,"totals":{"rest_calls":17,"rest_counted":15}}' > "$T/fleet.json"
printf 'A/x\t2\nB/y\t0\n' > "$T/merged.tsv"
gpd "$H2" "$NOW" GH_LEDGER_REPORT_FLEET_FILE="$T/fleet.json" GH_LEDGER_REPORT_MERGED_FILE="$T/merged.tsv" GH_LEDGER_REPORT_NOW="$NOW"
S2="$H2/state/gh-per-merged-pr.json"
[ "$(jq -c '[.window_h, .source, .error]' "$S2" 2>/dev/null)" = '[168,"fleet",null]' ] && ok || bad "2: state header: $(cat "$S2" 2>/dev/null)"
[ "$(jq -c '[.repos[] | .repo, .counted, .merged, .per_merged_pr]' "$S2" 2>/dev/null)" = '["A/x",10,2,5,"B/y",5,0,"n/a"]' ] && ok \
  || bad "2: state repos: $(jq -c .repos "$S2" 2>/dev/null)"
[ "$(grep -c 'gh per merged PR (168h): ' "$H2/logs/pipeline-health.log")" = 2 ] && ok || bad "2: one log line per repo: $(cat "$H2/logs/pipeline-health.log")"
grep -q 'gh per merged PR (168h): A/x counted=10 merged=2 per_merged_pr=5$' "$H2/logs/pipeline-health.log" && ok || bad "2: the A/x line: $(cat "$H2/logs/pipeline-health.log")"

# ---- 3. failures: error, no alert ----------------------------------------------------
: > "$H1/logs/ALERTS.log"
rm -f "$STATE1"; gpd "$H1" "$NOW" STUB_RC=124
[ "$(jq -c '{repos, e: (.error | test("timeout"))}' "$STATE1" 2>/dev/null)" = '{"repos":[],"e":true}' ] && ok || bad "3: a timeout writes error + repos []: $(cat "$STATE1" 2>/dev/null)"
rm -f "$STATE1"; gpd "$H1" "$NOW" STUB_RC=1
[ "$(jq -c '{repos, error}' "$STATE1" 2>/dev/null)" = '{"repos":[],"error":"report rc=1"}' ] && ok || bad "3: rc 1 writes error report rc=1: $(cat "$STATE1" 2>/dev/null)"
[ "$(jq -r .generated_at "$STATE1" 2>/dev/null)" = "$NOW" ] && ok || bad "3: a failed run still stamps generated_at"
: > "$T/report-calls.txt"; gpd "$H1" "$((NOW + 60))" STUB_RC=1
[ "$(reports)" = 0 ] && ok || bad "3: a failed run does not retry on the next tick"
cat > "$T/unk.sh" <<'EOF'
#!/bin/bash
echo 'per_merged_pr=unknown (fleet ledger: http=503)'
echo 'per_merged_pr_repo=unknown (fleet ledger: http=503)'
EOF
H3="$T/h3"; mkdir -p "$H3/bin" "$H3/logs" "$H3/state"; cp "$T/unk.sh" "$H3/bin/gh-ledger-report.sh"; chmod +x "$H3/bin/gh-ledger-report.sh"
gpd "$H3" "$NOW"
[ "$(jq -c '{repos, error}' "$H3/state/gh-per-merged-pr.json" 2>/dev/null)" = '{"repos":[],"error":"unknown (fleet ledger: http=503)"}' ] && ok \
  || bad "3: a fleet unknown line is an error: $(cat "$H3/state/gh-per-merged-pr.json" 2>/dev/null)"
grep -q 'gh per merged PR (168h): unknown (fleet ledger: http=503)' "$H3/logs/pipeline-health.log" && ok || bad "3: one log line for the error: $(cat "$H3/logs/pipeline-health.log")"
[ ! -s "$H1/logs/ALERTS.log" ] && [ ! -e "$H3/logs/ALERTS.log" ] && ok || bad "3: no alert in this wave"

# ---- 4. fleet-status-push section 13 -------------------------------------------------
FSP="$DIR/bin/fleet-status-push.sh"
A=$(grep -c '^# >>> 13. GH PER MERGED PR (BH-9933)' "$FSP"); B=$(grep -c '^# <<< 13. GH PER MERGED PR' "$FSP")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok || bad "4: fleet-status-push.sh must carry one section 13 block (open=$A close=$B)"
awk '/^# >>> 13. GH PER MERGED PR \(BH-9933\)/{f=1;next} /^# <<< 13. GH PER MERGED PR/{exit} f' "$FSP" > "$T/sec13.sh"
H4="$T/h4"; mkdir -p "$H4/state"
scratch_install_closure bin/lib/gh-per-pr-daily.sh "$H4" >/dev/null || bad "4: closure install"
sec13() { ( H="$H4"; NOW="$NOW"; SNAP='{"pushed_at":"x","projects":[]}'; . "$T/sec13.sh"; printf '%s' "$SNAP" ) 2>/dev/null; }
cp "$S2" "$H4/state/gh-per-merged-pr.json"
OUT=$(sec13)
[ "$(jq -c '.gh_per_merged_pr.repos | map(.repo)' <<<"$OUT" 2>/dev/null)" = '["A/x","B/y"]' ] && ok || bad "4: SNAP gains gh_per_merged_pr: $OUT"
[ "$(jq -r '.pushed_at' <<<"$OUT" 2>/dev/null)" = x ] && ok || bad "4: the other SNAP keys stay: $OUT"
printf 'not json' > "$H4/state/gh-per-merged-pr.json"
[ "$(sec13)" = '{"pushed_at":"x","projects":[]}' ] && ok || bad "4: an unparseable file leaves SNAP as it was: $(sec13)"
rm -f "$H4/state/gh-per-merged-pr.json"
[ "$(sec13)" = '{"pushed_at":"x","projects":[]}' ] && ok || bad "4: a missing file leaves SNAP as it was: $(sec13)"

# ---- 5. the pipeline-health block ------------------------------------------------------
PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> gh per merged PR daily (BH-9933)' "$PH"); B=$(grep -c '^# <<< gh per merged PR daily' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok || bad "5: pipeline-health.sh must carry one block (open=$A close=$B)"
GRP=$(awk '/^if \[ "\$PH_MODE" != project \]; then$/{g=$0} /^fi # /{g=""} /^# >>> gh per merged PR daily \(BH-9933\)/{print g; exit}' "$PH")
[ "$GRP" = 'if [ "$PH_MODE" != project ]; then' ] && ok || bad "5: the block must sit in the PH_MODE != project group (group: [$GRP])"
awk '/^# >>> gh per merged PR daily \(BH-9933\)/{f=1;next} /^# <<< gh per merged PR daily/{exit} f' "$PH" > "$T/phblock.sh"
H5="$T/h5"; mkdir -p "$H5/bin" "$H5/logs" "$H5/state"
scratch_install_closure bin/lib/gh-per-pr-daily.sh "$H5" >/dev/null || bad "5: closure install"
cp "$H1/bin/gh-ledger-report.sh" "$H5/bin/"
( unset -f gpd_run; H="$H5"; NOW="$NOW"; STAMP() { echo x; }; . "$T/phblock.sh" ) >/dev/null 2>&1
[ "$(jq -c '.repos | length' "$H5/state/gh-per-merged-pr.json" 2>/dev/null)" = 2 ] && ok || bad "5: the block runs gpd_run (state: $(cat "$H5/state/gh-per-merged-pr.json" 2>/dev/null))"

echo "pipeline-health-gh-per-pr.bh-9933: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
