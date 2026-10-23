#!/bin/bash
# tests/staff-watchman-guards.bh-8057-test.sh — BH-8057 (BH-5565.1): the three
# #5556 guard rules, proven for Watchman through the production entry point
# (bin/staff.sh tick watchman) with the REAL collector,
# bin/staff/watchman-collect.sh.
#
#   G0     baseline: an unkilled tick at augmentation runs the real collector
#          (1 gitleaks call, claims), so the zero counts below are not vacuous
#   K1-K4  staff-off-all, staff-kill-all, staff-off-watchman,
#          staff-kill-watchman: rc 0, one `killed by <flag>` line, no request
#          but the flag reads, 0 git/gitleaks/node/fleet-conf/agent-call/gh
#          calls, 0 beats, no state dir, no digest
#   K5     tick-all with staff-kill-all: no roster read
#   N1-N4  staff-kill-quartermaster, staff-off-dispatcher,
#          staff-kill-watchmanx, no flag: the tick runs
#   O1     every collector line: labels [], no filedBy, kind staff-security,
#          url not an issue URL
#   O2     collector stdout byte-identical with an empty and a 3-row staff
#          findings answer (the findings read never becomes an item)
#   O3     a Watchman tick drops two staff-labelled copies of a real line (one
#          log line, count 2) and claims the `security` copy
#   M1     the composed schema seeds watchman automation/augmentation/active;
#          every row automation with cap <= augmentation; a row with no
#          autonomy reads automation; a second apply changes nothing
#   M2     a tick at the seeded level (the row read from M1's database): 2
#          digest lines level=automation verdict=refuse, 0 issue creates, 0
#          list calls, 2 `digested` records, 1 beat (the history-secret beat)
#   M3     the credential rotated at automation: 0 PATCH, 0 outcomes POST, the
#          latch deleted, one `not filed with an issue` line
#   M4     the M2 tick at augmentation files 2 issues labelled staff:watchman
#   Every case: no curl or gh ran (net.log absent): 0 vendor calls.
#
# MUTATIONS (D1), each run once against a scratch copy of the repo, red output
# in the build's red.txt: drop the `staff-kill-$AGENT` check in bin/staff.sh ->
# K4 red; label the rotation-due item staff:watchman in the collector -> O1 red;
# drop the `staff` classification in bin/staff.sh -> O3 red; seed watchman at
# augmentation in 0010 -> M1 and M2 red.
#
# gitleaks is a WM_GITLEAKS stub that copies $FXT/report.json to
# --report-path. The fixture repo is a real `git init` repo with fixed dates;
# the secret value is built at run time and says fixture (D47).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-watchman-guards.bh-8057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-watchman-guards: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "staff-watchman-guards: git is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-watchman-guards: node is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

COL_REL=bin/staff/watchman-collect.sh
# 2026-10-15T12:00:00Z, pinned (D60).
NOW=1792065600
DAY=86400; HR=3600
day() { date -u -d "@$1" +%Y-%m-%d; }
LEAKV="AKIA$(printf '%s' FIXTURE)WMQZXJKLB"
REAL_GIT=$(command -v git); REAL_NODE=$(command -v node)

# ═════ the scratch harness ═══════════════════════════════════════════════════
S="$T/s"; FXT="$T/fx"; REPOS="$T/repos"
mkdir -p "$S/prompts/staff" "$S/catalog/prompts" "$FXT" "$REPOS" "$T/fakebin"
scratch_install_closure bin/staff.sh "$S" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
scratch_install_closure bin/jobs-client.sh "$S" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
scratch_install_closure "$COL_REL" "$S" >/dev/null || bad "scratch_install_closure $COL_REL failed"
cp "$DIR/bin/staff-core.mjs" "$S/bin/"
cp -r "$DIR/agent-core" "$S/agent-core"
cp "$DIR/prompts/staff/watchman-soul.md" "$S/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$S/catalog/prompts/"
COL="$S/$COL_REL"
cp "$COL" "$T/collect.real"

cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit 0
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/beats.log"\nexit 0\n' > "$S/bin/lane-alert.sh"
cat > "$S/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/fc.log"
case "${1:-}" in
  --projects) echo fx-proj ;;
  fx-proj) [ "${2:-}" = repo ] && echo fx-org/fx-proj ;;
  *) exit 1 ;;
esac
SH
chmod +x "$S/bin/agent-call.sh" "$S/bin/lane-alert.sh" "$S/bin/fleet-conf.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/git.log"\nexec "%s" "$@"\n' "$REAL_GIT" > "$T/fakebin/git"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/node.log"\nexec "%s" "$@"\n' "$REAL_NODE" > "$T/fakebin/node"
chmod +x "$T/fakebin/"*
cat > "$T/gitleaks" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gl.log"
out=""
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && { if [ -f "$FXT/report.json" ]; then cp "$FXT/report.json" "$out"; else echo '[]' > "$out"; fi; }
exit 0
SH
chmod +x "$T/gitleaks"

# STAFF_FIXTURE (staff.sh): the roster, the claim (keyed on agent-core's
# fingerprint, as the route does), the record, gh_rest. Every call is logged.
cat > "$T/stafffx.sh" <<SH
AGENT_CORE="$DIR/agent-core/src/index.js"
SH
cat >> "$T/stafffx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/flags/"*) return 2 ;;
    "GET /api/staff/agent?name=watchman") cat "$FXT/agent.json"; return 0 ;;
    "GET /api/staff/agents") printf '{"agents":[{"name":"watchman","status":"active"}]}'; return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/req.log"
  local fp
  case "$2" in
    /api/staff/findings/claim)
      fp=$(command node --input-type=module -e "import { fingerprint } from '$AGENT_CORE'; console.log(fingerprint(JSON.parse(process.argv[1]).item));" "$(cat "$3")")
      if grep -qx "$fp" "$FXT/claimed" 2>/dev/null; then
        printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"agent":"watchman","status":"filed"}}' "$fp"
        return 9
      fi
      printf '%s\n' "$fp" >> "$FXT/claimed"
      printf '{"claimed":true,"fingerprint":"%s","finding":{"agent":"watchman","status":"claimed"}}' "$fp"; return 0 ;;
    /api/staff/findings/record) jq -c . "$3" >> "$FXT/records.jsonl"; printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  printf 'gh_rest %s %s\n' "$1" "$2" >> "$FXT/gh.log"
  [ "${3:-}" = --input ] && jq -c . "$4" >> "$FXT/gh-payloads.jsonl"
  GH_REST_STATUS=201
  printf '{"number":7,"html_url":"https://github.com/fx-org/fx-repo/issues/7"}\n'
  return 0
}
gh_rest_issue_list() { printf 'LIST %s\n' "$*" >> "$FXT/gh.log"; GH_REST_STATUS=200; echo '[]'; return 0; }
lane_role_model() { printf 'stub-model\n'; }
SH
# WM_FIXTURE (the collector): the staff findings read answers $FXT/findings.json,
# else the records as findings; the outcomes POST and gh_rest PATCH are logged.
cat > "$T/wmfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"
  case "$1 $2" in
    "GET /api/staff/findings?agent=watchman")
      if [ -f "$FXT/findings.json" ]; then cat "$FXT/findings.json"
      elif [ -f "$FXT/records.jsonl" ]; then
        jq -cs '{agent: "watchman", truncated: false, findings: [.[] | {fingerprint, status: .outcome, ticket_url: (.ticket_url // null)}]}' "$FXT/records.jsonl"
      else echo '{"agent":"watchman","findings":[],"truncated":false}'; fi
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/wm-req.log"
  [ "$1 $2" = "POST /api/staff/outcomes" ] && { printf '{"ok":true}'; return 0; }
  return 1
}
gh_rest() { printf 'gh_rest %s %s\n' "$1" "$2" >> "$FXT/wm-gh.log"; GH_REST_STATUS=200; echo '{}'; return 0; }
SH

# The fixture repo: one commit with the fixture key, fixed dates.
R="$REPOS/fx-proj"
"$REAL_GIT" init -q "$R" && "$REAL_GIT" -C "$R" config user.email fx@example.com && "$REAL_GIT" -C "$R" config user.name fx
printf 'AWS_ACCESS_KEY_ID=%s\n' "$LEAKV" > "$R/.env"
GIT_AUTHOR_DATE="2026-09-01T00:00:00Z" GIT_COMMITTER_DATE="2026-09-01T00:00:00Z" "$REAL_GIT" -C "$R" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-09-01T00:00:00Z" GIT_COMMITTER_DATE="2026-09-01T00:00:00Z" "$REAL_GIT" -C "$R" commit -qm first >/dev/null 2>&1
C1=$("$REAL_GIT" -C "$R" rev-parse HEAD)
LEAKROW=$(jq -cn --arg c "$C1" --arg s "$LEAKV" '[{Description: "AWS", StartLine: 1, EndLine: 1, Match: ("AWS_ACCESS_KEY_ID=" + $s),
  Secret: $s, File: ".env", Commit: $c, RuleID: "aws-access-token", Tags: []}]')
DUE_OLD=$(day $((NOW - 10 * DAY)))
SREG="$S/catalog/staff-rotations.d"

# agent <autonomy> [cap]: the roster row the tick reads.
agent() {
  jq -cn --arg l "$1" --arg c "${2:-augmentation}" '{agent: {name: "watchman", role: "security", autonomy: $l, cap: $c,
    status: "active", soul: "prompts/staff/watchman-soul.md", lanes: []}}' > "$FXT/agent.json"
}
# reg <rotated_at>: the fx-cred register entry (every 90 days).
reg() {
  mkdir -p "$SREG"
  jq -n --arg d "$1" '{id: "fx-cred", where: "env file global.env, variable FX_CRED", owner: "ops@example.com",
    rotated_at: $d, every_days: 90}' > "$SREG/fx-cred.json"
}
reset() { # fresh state: one overdue credential, one leak in history, augmentation
  local d
  for d in "$S/state" "$S/logs" "$S/flags" "$S/locks" "$S/catalog/staff-rotations.d" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT" "$S/flags"
  for d in req.log gh.log ac.log beats.log gl.log git.log node.log fc.log wm-req.log wm-gh.log; do : > "$FXT/$d"; done
  printf '%s\n' "$LEAKROW" > "$FXT/report.json"
  reg "$(day $((NOW - 100 * DAY)))"
  agent augmentation
  cp "$T/collect.real" "$COL"
}
tick() { # tick [mode] [now] — the shipped entry point, sandboxed
  env HARNESS="$S" FXT="$FXT" STAFF_FIXTURE="$T/stafffx.sh" WM_FIXTURE="$T/wmfx.sh" \
    HARNESS_TEST_SANDBOX=1 WM_NOW="${2:-$NOW}" WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$REPOS" \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" bash "$S/bin/staff.sh" "${1:-tick}" watchman > "$T/tick.out" 2>&1
  RC=$?
}
collect() { # collect <out> [now] — the collector alone, same seams
  env HARNESS="$S" FXT="$FXT" WM_FIXTURE="$T/wmfx.sh" HARNESS_TEST_SANDBOX=1 WM_NOW="${2:-$NOW}" \
    WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$REPOS" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" bash "$COL" > "$1" 2> "$T/collect.err"
  RC=$?
}
claims() { grep -c '^POST /api/staff/findings/claim ' "$FXT/req.log"; }
nonet() { [ -e "$T/net.log" ] && bad "$1: a real curl/gh ran: $(cat "$T/net.log")" || ok; }
runs() { # runs <case>: the tick ran the real collector and claimed
  eq "$1 rc" "$RC" 0
  eq "$1 gitleaks calls" "$(lines "$FXT/gl.log")" 1
  [ "$(claims)" -ge 1 ] && ok || bad "$1: no claim: $(cat "$FXT/req.log")"
  grep -q 'killed by' "$S/logs/staff.log" 2>/dev/null && bad "$1: a kill line: $(grep 'killed by' "$S/logs/staff.log")" || ok
  nonet "$1"
}

# ═════ G0: the baseline ══════════════════════════════════════════════════════
reset; tick
runs G0
eq "G0 claims" "$(claims)" 2
eq "G0 agent-calls" "$(cat "$FXT/ac.log")" "staff-tick|watchman"
eq "G0 issue creates" "$(grep -c '^gh_rest POST repos/.*/issues$' "$FXT/gh.log")" 2
[ "$(lines "$FXT/git.log")" -gt 0 ] && ok || bad "G0: the git wrapper logged no call (the K zero is vacuous)"
[ "$(lines "$FXT/node.log")" -gt 0 ] && ok || bad "G0: the node wrapper logged no call (the K zero is vacuous)"
[ "$(lines "$FXT/fc.log")" -gt 0 ] && ok || bad "G0: fleet-conf logged no call (the K zero is vacuous)"
[ -d "$S/state/staff/watchman" ] && ok || bad "G0: no state dir (the K check is vacuous)"
grep -q '^POST /api/staff/ticks ' "$FXT/req.log" && ok || bad "G0: no tick record (the K check is vacuous)"

# ═════ K1-K4: a kill flag stops the tick before any read ═════════════════════
for F in staff-off-all staff-kill-all staff-off-watchman staff-kill-watchman; do
  reset; touch "$S/flags/$F"; tick
  eq "K $F rc" "$RC" 0
  eq "K $F killed lines" "$(grep -c "agent=watchman killed by $F$" "$S/logs/staff.log" 2>/dev/null)" 1
  eq "K $F requests other than the flag reads" "$(grep -vc '^GET /api/flags/staff-' "$FXT/req.log")" 0
  eq "K $F staff requests" "$(grep -c '/api/staff' "$FXT/req.log")" 0
  eq "K $F gitleaks calls" "$(lines "$FXT/gl.log")" 0
  eq "K $F git calls" "$(lines "$FXT/git.log")" 0
  eq "K $F fleet-conf calls" "$(lines "$FXT/fc.log")" 0
  eq "K $F node calls" "$(lines "$FXT/node.log")" 0
  eq "K $F agent-calls" "$(lines "$FXT/ac.log")" 0
  eq "K $F gh calls" "$(lines "$FXT/gh.log")" 0
  eq "K $F collector requests" "$(lines "$FXT/wm-req.log")" 0
  eq "K $F beats" "$(lines "$FXT/beats.log")" 0
  [ -e "$S/state/staff/watchman" ] && bad "K $F: the state dir exists" || ok
  [ -e "$S/logs/staff-digest.log" ] && bad "K $F: a digest was written" || ok
  nonet "K $F"
done

# ═════ K5: tick-all with staff-kill-all reads no roster ══════════════════════
reset; touch "$S/flags/staff-kill-all"; tick tick-all
eq "K5 rc" "$RC" 0
eq "K5 roster reads" "$(grep -c '^GET /api/staff/agents' "$FXT/req.log")" 0
eq "K5 staff requests" "$(grep -c '/api/staff' "$FXT/req.log")" 0
eq "K5 killed lines" "$(grep -c 'killed by staff-kill-all$' "$S/logs/staff.log" 2>/dev/null)" 1
eq "K5 gitleaks calls" "$(lines "$FXT/gl.log")" 0
eq "K5 git calls" "$(lines "$FXT/git.log")" 0
eq "K5 node calls" "$(lines "$FXT/node.log")" 0
eq "K5 agent-calls" "$(lines "$FXT/ac.log")" 0
nonet K5
# The near miss: tick-all with no flag reads the roster and ticks watchman.
reset; tick tick-all
eq "K5 unkilled roster reads" "$(grep -c '^GET /api/staff/agents' "$FXT/req.log")" 1
runs "K5 unkilled"

# ═════ N1-N4: near misses, the tick runs ═════════════════════════════════════
for F in staff-kill-quartermaster staff-off-dispatcher staff-kill-watchmanx ""; do
  reset; [ -n "$F" ] && touch "$S/flags/$F"; tick
  runs "N ${F:-no-flag}"
done

# ═════ O1: the collector prints no staff-filed item ══════════════════════════
reset; collect "$T/o1.out"
eq "O1 rc" "$RC" 0
eq "O1 lines" "$(lines "$T/o1.out")" 2
eq "O1 classes" "$(jq -r .class "$T/o1.out" | sort | paste -sd' ')" "history-secret rotation-due"
eq "O1 lines with labels other than []" "$(jq -c 'select(.source.labels != [])' "$T/o1.out" | grep -c .)" 0
eq "O1 lines with filedBy" "$(jq -c 'select(.source | has("filedBy"))' "$T/o1.out" | grep -c .)" 0
eq "O1 lines not staff-security" "$(jq -c 'select(.source.kind != "staff-security")' "$T/o1.out" | grep -c .)" 0
eq "O1 lines with an issue url" "$(jq -c 'select(.source.url | test("/issues/[0-9]+$"))' "$T/o1.out" | grep -c .)" 0
nonet O1

# ═════ O2: the findings read never becomes an item ═══════════════════════════
# A rotated latch that qualifies (latch at the old due, the register rotated
# today), plus a second credential still overdue and the cached leak, so the
# stdout is not empty.
reset; collect "$T/o2.pre"
mkdir -p "$S/state/staff/watchman/due"
printf '%s\n' "$DUE_OLD" > "$S/state/staff/watchman/due/fx-cred"
reg "$(day "$NOW")"
jq -n --arg d "$(day $((NOW - 100 * DAY)))" '{id: "fx-old", where: "env file global.env, variable FX_OLD", owner: "ops@example.com",
  rotated_at: $d, every_days: 90}' > "$SREG/fx-old.json"
FPOLD=$(node --input-type=module -e "import { fingerprint } from '$DIR/agent-core/src/index.js'; console.log(fingerprint(JSON.parse(process.argv[1])));" \
  "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$DUE_OLD\"}")
cp -r "$S/state" "$T/o2.state"
o2run() { # o2run <findings json> <out>
  scratch_rm "$S/state" || exit 1; cp -r "$T/o2.state" "$S/state"
  printf '%s\n' "$1" > "$FXT/findings.json"; : > "$FXT/wm-req.log"
  collect "$2"
  eq "O2 $2 rc" "$RC" 0
  eq "O2 $2 findings reads" "$(grep -c '^GET /api/staff/findings?agent=watchman$' "$FXT/wm-req.log")" 1
}
o2run '{"agent":"watchman","findings":[],"truncated":false}' "$T/o2.empty"
ROWS=$(jq -cn --arg f "$FPOLD" '{agent: "watchman", truncated: false, findings: [
  {fingerprint: $f, status: "digested", title: "Rotation past due: fx-cred", ticket_url: "https://github.com/fx-org/fx-repo/issues/7",
   source_labels: ["staff:watchman"]},
  {fingerprint: ("a" * 64), status: "filed", title: "Critical: staff-filed fx row", ticket_url: "https://github.com/fx-org/fx-repo/issues/8",
   source_labels: ["staff:watchman"]},
  {fingerprint: ("b" * 64), status: "claimed", title: "staff:watchman fx row", ticket_url: "https://github.com/fx-org/fx-repo/issues/9",
   source_labels: ["staff:watchman"]}]}')
o2run "$ROWS" "$T/o2.rows"
[ -s "$T/o2.empty" ] && ok || bad "O2: the collector printed nothing (the compare is vacuous)"
cmp -s "$T/o2.empty" "$T/o2.rows" && ok || bad "O2: stdout differs: $(diff "$T/o2.empty" "$T/o2.rows")"
grep -qE 'issues/[0-9]|staff:watchman|staff-filed' "$T/o2.rows" && bad "O2: a findings row reached stdout: $(cat "$T/o2.rows")" || ok
rm -f "$FXT/findings.json"
nonet O2

# ═════ O3: a staff-labelled line is dropped in a Watchman tick ═══════════════
reset
cp "$T/collect.real" "$S/bin/staff/watchman-collect.real.sh"
cat > "$COL" <<'SH'
#!/bin/bash
out=$("$(dirname "$0")/watchman-collect.real.sh") || exit $?
printf '%s\n' "$out"
first=$(head -n 1 <<<"$out")
jq -c '.item.copy = "a" | .source.labels = ["staff:watchman"]' <<<"$first"
jq -c '.item.copy = "b" | .source.labels = [" Staff:Watchman "]' <<<"$first"
jq -c '.item.copy = "c" | .source.labels = ["security"]' <<<"$first"
SH
chmod +x "$COL" "$S/bin/staff/watchman-collect.real.sh"
tick
eq "O3 rc" "$RC" 0
eq "O3 claims (2 real + the security copy)" "$(claims)" 3
eq "O3 drop lines" "$(grep -c 'dropped 2 staff-filed item(s) before the claim$' "$S/logs/staff.log")" 1
eq "O3 claims with a staff: label" "$(grep '^POST /api/staff/findings/claim ' "$FXT/req.log" | cut -d' ' -f3- \
  | jq -c 'select([.source.labels[]? | ascii_downcase | test("staff:")] | any)' | grep -c .)" 0
eq "O3 the security copy is claimed" "$(grep '^POST /api/staff/findings/claim ' "$FXT/req.log" | cut -d' ' -f3- \
  | jq -r 'select(.item.copy == "c") | .source.labels[0]')" security
nonet O3
cp "$T/collect.real" "$COL"; rm -f "$S/bin/staff/watchman-collect.real.sh"

# ═════ M1: the seed starts every agent in observe mode ═══════════════════════
M1OK=0
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "M1: bin/schema-build.sh --to failed"
  GOT=$(node --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const fs = require("node:fs");
    const db = new DatabaseSync(process.argv[2]);
    const sql = fs.readFileSync(process.argv[1], "utf8");
    db.exec(sql);
    const row = () => db.prepare("SELECT name, autonomy, cap, status, soul_path FROM staff_agents WHERE name = ?").get("watchman");
    const w = row();
    console.log("ROW " + JSON.stringify(w));
    const all = db.prepare("SELECT name, autonomy, cap FROM staff_agents ORDER BY name").all();
    console.log("ROWS " + all.length);
    console.log("ABOVE " + all.filter((r) => r.autonomy !== "automation" || !["automation", "augmentation"].includes(r.cap)).map((r) => r.name).join(","));
    db.prepare("INSERT INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES (?, ?, ?, ?, ?)")
      .run("fx-new", "fixture", "ops@example.com", "prompts/staff/fx-new-soul.md", "2026-10-15T00:00:00Z");
    const n = db.prepare("SELECT autonomy, cap FROM staff_agents WHERE name = ?").get("fx-new");
    console.log("NEW " + n.autonomy + " " + n.cap);
    db.exec(sql);
    console.log("SAME " + (JSON.stringify(row()) === JSON.stringify(w)));
  ' "$T/schema.sql" "$T/m1.db" 2>&1)
  ROW=$(sed -n 's/^ROW //p' <<<"$GOT")
  eq "M1 watchman row" "$(jq -c '{autonomy, cap, status}' <<<"$ROW" 2>/dev/null)" \
    '{"autonomy":"automation","cap":"augmentation","status":"active"}'
  [ "$(sed -n 's/^ROWS //p' <<<"$GOT")" -ge 7 ] 2>/dev/null && ok || bad "M1: fewer than 7 seeded rows: $GOT"
  eq "M1 rows above observe mode or cap" "$(sed -n 's/^ABOVE //p' <<<"$GOT")" ""
  eq "M1 a row with no autonomy" "$(sed -n 's/^NEW //p' <<<"$GOT")" "automation augmentation"
  eq "M1 second apply leaves watchman" "$(sed -n 's/^SAME //p' <<<"$GOT")" true
  M1OK=1
else
  echo "SKIP: M1 and M2, node:sqlite is not available in this node"
fi

# ═════ M2: a tick at the seeded level reports and files nothing ══════════════
if [ "$M1OK" = 1 ]; then
  reset
  jq -c '{agent: {name, autonomy, cap, status, soul: .soul_path, lanes: []}}' <<<"$ROW" > "$FXT/agent.json"
  tick
  eq "M2 rc" "$RC" 0
  eq "M2 level read from the seed" "$(jq -r .agent.autonomy "$FXT/agent.json")" automation
  eq "M2 claims" "$(claims)" 2
  eq "M2 agent-calls" "$(cat "$FXT/ac.log")" "staff-tick|watchman"
  eq "M2 refuse digest lines" "$(grep -c 'agent=watchman level=automation verdict=refuse ' "$S/logs/staff-digest.log" 2>/dev/null)" 2
  eq "M2 issue creates" "$(grep -c '^gh_rest POST' "$FXT/gh.log")" 0
  eq "M2 issue list calls" "$(grep -c '^LIST' "$FXT/gh.log")" 0
  eq "M2 digested records" "$(jq -r 'select(.outcome == "digested") | .fingerprint' "$FXT/records.jsonl" 2>/dev/null | grep -c .)" 2
  eq "M2 other records" "$(jq -r 'select(.outcome != "digested") | .outcome' "$FXT/records.jsonl" 2>/dev/null | grep -c .)" 0
  eq "M2 beats" "$(lines "$FXT/beats.log")" 1
  grep -q -- '--id staff-watchman-leak-fx-proj-' "$FXT/beats.log" && ok || bad "M2: the beat is not the history-secret beat: $(cat "$FXT/beats.log")"
  eq "M2 latch" "$(cat "$S/state/staff/watchman/due/fx-cred" 2>/dev/null)" "$DUE_OLD"
  nonet M2

  # ═════ M3: the credential rotated; nothing filed, so nothing closed ════════
  : > "$FXT/req.log"; : > "$FXT/wm-req.log"; : > "$FXT/wm-gh.log"; : > "$FXT/gh.log"; : > "$FXT/ac.log"
  reg "$(day $((NOW + 2 * HR)))"
  tick tick $((NOW + 2 * HR))
  eq "M3 rc" "$RC" 0
  eq "M3 findings reads" "$(grep -c '^GET /api/staff/findings?agent=watchman$' "$FXT/wm-req.log")" 1
  eq "M3 PATCH" "$(lines "$FXT/wm-gh.log")" 0
  eq "M3 outcomes POST" "$(grep -c '^POST /api/staff/outcomes' "$FXT/wm-req.log")" 0
  [ -e "$S/state/staff/watchman/due/fx-cred" ] && bad "M3: the latch stayed" || ok
  eq "M3 not-filed lines" "$(grep -c 'fx-cred rotated; finding [0-9a-f]* is digested, not filed with an issue' "$S/logs/staff.log")" 1
  eq "M3 issue creates" "$(grep -c '^gh_rest POST' "$FXT/gh.log")" 0
  nonet M3
fi

# ═════ M4: the near miss, the same tick at augmentation files ════════════════
reset; agent augmentation; tick
eq "M4 rc" "$RC" 0
eq "M4 issue creates" "$(grep -c '^gh_rest POST repos/.*/issues$' "$FXT/gh.log")" 2
eq "M4 labels" "$(jq -c .labels "$FXT/gh-payloads.jsonl" 2>/dev/null | sort -u)" '["staff:watchman"]'
eq "M4 digest lines" "$(lines "$S/logs/staff-digest.log")" 0
nonet M4

nonet "the suite"
echo "staff-watchman-guards.bh-8057: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
