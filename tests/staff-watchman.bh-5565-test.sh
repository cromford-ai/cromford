#!/bin/bash
# tests/staff-watchman.bh-5565-test.sh — BH-5565 (BH-5556.8): the Watchman
# collector, bin/staff/watchman-collect.sh, its rotation register
# (catalog/staff-rotations.d/) and its lanes.
#
#   W1   project-3 shape (a key in git history) -> one history-secret line, title
#        `Critical:`, one critical beat, and the secret value in no output
#   W2   the next tick inside the interval: same line, no gitleaks run, no
#        beat; the next interval with a clean commit: `--not <old tip>`, no beat
#   W3   the production entry point: bin/staff.sh tick watchman four times at
#        augmentation -> one ticket; nothing new; the rotated key closes the
#        issue (completed) and posts outcome merged; then nothing
#   W4   a rotation due 10 days ago -> one rotation-due line, latch written
#   W5   due today, due tomorrow -> no line
#   W6   the decision-rule edges, table-driven (rotation-due, scan due, NEW,
#        rotated)
#   W7   45 cached locations, STAFF_MAX_ITEMS=20 -> three ticks print three
#        different first-20 windows that cover all 45
#   W8   knobs: WM_PAGE_SEVERITY off/warn/bogus, a settings row for
#        WM_SCAN_INTERVAL_H, WM_SCAN_TIMEOUT_S default and out of range
#   W9   register validation: each bad file skipped with one log line
#   W10  two credentials, one due date -> two distinct fingerprints
#   W11  failures: jq missing, gitleaks rc 2, a timeout, findings unreadable,
#        PATCH rc 75, POST failing after the PATCH
#   W12  every lane the seed gives watchman has a lane registry file
#   W13  the composed schema gives watchman exactly the 4 security lanes; the
#        findings read uses idx_staff_findings_agent on a seeded table
#   W14  every committed catalog/staff-rotations.d/*.json validates
#   W15  two projects due, WM_SCAN_REPOS_PER_TICK=1 -> one scan per tick
#   W16  the collector names no model string and calls GitHub only via gh_rest
#   W17  a first scan in chunks (WM_SCAN_CHUNK_COMMITS) reads every commit
#        exactly once and is held until its last chunk; the tick budget
#        (STAFF_COLLECT_TIMEOUT_S) stops a tick and the next tick resumes
#   W18  a chunk that times out halves; one commit that times out is a failed
#        scan; a fast chunk doubles back to the knob
#   W19  a first scan over WM_FIRST_SCAN_MAX locations = one baseline finding
#        and one beat; later scans file only locations not in the baseline
#   W20  gitleaks reads the repo's own .gitleaksignore (--gitleaks-ignore-path)
#   W11 also pins the WM_SCAN_FAIL_ALERT-th failed scan in a row = one warn beat
#
# MUTATIONS (D1), each tried by hand once against the collector: read .Secret
# into the file field -> W1 red; drop the cache check -> W2 red; `>= due` instead
# of `>= due + 1 day` -> W5 red; post the outcome before the PATCH -> W11 red;
# name the item field `key` -> W10 red; print in one fixed order -> W7 red.
#
# gitleaks is a WM_GITLEAKS stub that copies $FXT/report/<repo>.json (the
# shape gitleaks 8.30.1 writes) to --report-path. The fixture repos are real
# `git init` repos with fixed dates. The secret value is built at run time, so
# no committed line matches a gitleaks rule.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-watchman.bh-5565-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-watchman: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "staff-watchman: git is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

COL_REL=bin/staff/watchman-collect.sh
COL_SRC="$DIR/bin/staff/watchman-collect.sh"
LIBF="$DIR/catalog/lanes.d/_lib.staff-watchman.json"
[ -r "$COL_SRC" ] || bad "missing $COL_SRC"
[ -r "$LIBF" ] || bad "missing $LIBF"

# 2026-10-15T12:00:00Z and its midnight, pinned (D60).
NOW=1792065600
MID=1792022400
DAY=86400; HR=3600
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
day() { date -u -d "@$1" +%Y-%m-%d; }
# The fixture secret: built here, never a committed literal (D47: it says fixture).
LEAKV="AKIA$(printf '%s' FIXTURE)WMQZXJKLB"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; REPOS="$T/repos"
mkdir -p "$H" "$FXT" "$REPOS" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$H" >/dev/null || bad "scratch_install_closure $COL_REL failed"
fi
COL="$H/$COL_REL"
# The rotated close fingerprints with agent-core, which a box keeps at $HARNESS/agent-core.
cp -r "$DIR/agent-core" "$H/agent-core"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.log"\nexit 0\n' "$FXT" > "$T/lane-alert.stub"
# fleet-conf stub: $FXT/fleet.tsv rows "<project> <owner/repo>".
cat > "$T/fleet-conf.stub" <<SH
#!/bin/bash
F="$FXT/fleet.tsv"
[ -f "\$F" ] || exit 0
case "\${1:-}" in
  --projects) awk '{print \$1}' "\$F" ;;
  *) [ "\${2:-}" = repo ] && awk -v p="\$1" '\$1 == p {print \$2; f=1} END {exit !f}' "\$F" ;;
esac
SH
chmod +x "$T/lane-alert.stub" "$T/fleet-conf.stub"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
# timeout: log the limit, then the real one; $FXT/timeout.force answers 124.
REAL_TIMEOUT=$(command -v timeout)
cat > "$T/fakebin/timeout" <<SH
#!/bin/bash
printf '%s\n' "\$1" >> "$FXT/timeout.log"
[ -f "$FXT/timeout.force" ] && exit 124
exec "$REAL_TIMEOUT" "\$@"
SH
chmod +x "$T/fakebin/timeout"

# The gitleaks stub: argv to gl.log; report/<basename of the repo>.json to the
# --report-path; rc from gl.rc.
cat > "$T/gitleaks" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gl.log"
repo=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    git) repo=$2; shift ;;
    --report-path) out=$2; shift ;;
  esac
  shift
done
rc=$(cat "$FXT/gl.rc" 2>/dev/null || echo 0)
r="$FXT/report/$(basename "$repo").json"
if [ -n "$out" ]; then if [ -f "$r" ]; then cp "$r" "$out"; else echo '[]' > "$out"; fi; fi
exit "$rc"
SH
chmod +x "$T/gitleaks"

# WM_FIXTURE: the findings list, the outcome POST and gh_rest (PATCH).
cat > "$T/wmfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"
  case "$1 $2" in
    "GET /api/staff/findings?agent=watchman")
      [ -f "$FXT/findings.fail" ] && return 1
      if [ -f "$FXT/records.jsonl" ]; then
        jq -cs '{agent: "watchman", truncated: false,
                 findings: [.[] | select(.outcome == "filed") | {fingerprint, status: "filed", ticket_url}]}' "$FXT/records.jsonl"
      else
        cat "$FXT/findings.json" 2>/dev/null || echo '{"agent":"watchman","findings":[],"truncated":false}'
      fi
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/wm-req.log"
  case "$1 $2" in
    "POST /api/staff/outcomes")
      [ -f "$FXT/outcome.fail" ] && return 1
      printf '{"ok":true,"outcome":"merged","verdict":"agree"}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  printf 'gh_rest %s %s %s\n' "$1" "$2" "$( [ "${3:-}" = --input ] && jq -c . "$4")" >> "$FXT/wm-gh.log"
  if [ -f "$FXT/patch.rc" ]; then GH_REST_STATUS=000; return "$(cat "$FXT/patch.rc")"; fi
  GH_REST_STATUS=200; printf '{"number":7,"state":"closed"}\n'; return 0
}
# A slow gitleaks without a real sleep: each run moves the collector's clock
# ($SECONDS, the tick budget) on by the seconds in $FXT/advance.
timeout() {
  local rc=0
  command timeout "$@" || rc=$?
  [ -f "$FXT/advance" ] && SECONDS=$((SECONDS + $(cat "$FXT/advance")))
  return "$rc"
}
# A head start on the tick budget: $FXT/slack seconds of real time the
# collector may use before its first scan (start-up, git, jq) without moving
# the budget's arithmetic. A loaded CI runner spends a whole second there, and
# a 10 s budget with no slack then starts no scan at all (batch #7242).
[ -f "$FXT/slack" ] && SECONDS=$((-$(cat "$FXT/slack")))
SH

REG="$H/catalog/staff-rotations.d"
# reg <id> due <YYYY-MM-DD> | reg <id> rot <YYYY-MM-DD> <every_days>
reg() {
  mkdir -p "$REG"
  if [ "$2" = due ]; then
    jq -n --arg id "$1" --arg d "$3" '{id: $id, where: "env file global.env, variable FX_CRED", owner: "ops@example.com", due: $d}' > "$REG/$1.json"
  else
    jq -n --arg id "$1" --arg d "$3" --argjson e "$4" \
      '{id: $id, where: "env file global.env, variable FX_CRED", owner: "ops@example.com", rotated_at: $d, every_days: $e}' > "$REG/$1.json"
  fi
}
# mkrepo <project> [secret]: a real repo, fixed dates. Prints nothing.
gitc() { GIT_AUTHOR_DATE="2026-09-01T00:00:00Z" GIT_COMMITTER_DATE="2026-09-01T00:00:00Z" git -C "$1" "${@:2}" >/dev/null 2>&1; }
mkrepo() {
  local r="$REPOS/$1"
  git init -q "$r" && git -C "$r" config user.email fx@example.com && git -C "$r" config user.name fx
  if [ -n "${2:-}" ]; then printf 'AWS_ACCESS_KEY_ID=%s\n' "$2" > "$r/.env"; else echo clean > "$r/README"; fi
  gitc "$r" add -A && gitc "$r" commit -qm "first"
}
tip() { git -C "$REPOS/$1" rev-parse HEAD; }
# report <project> <rows json array>: what gitleaks writes for that repo.
report() { mkdir -p "$FXT/report"; printf '%s\n' "$2" > "$FXT/report/$1.json"; }
# leakrow <commit> <file> <line> [rule]: one row as gitleaks 8.30.1 writes it, unredacted.
leakrow() {
  jq -cn --arg c "$1" --arg f "$2" --argjson l "$3" --arg r "${4:-aws-access-token}" --arg s "$LEAKV" '
    {Description: "AWS", StartLine: $l, EndLine: $l, StartColumn: 19, EndColumn: 38, Match: ("AWS_ACCESS_KEY_ID=" + $s),
     Secret: $s, File: $f, SymlinkFile: "", Commit: $c, Entropy: 3.5, Author: "fx", Email: "fx@example.com",
     Date: "2026-09-01T00:00:00Z", Message: ("first " + $s), Tags: [], RuleID: $r,
     Fingerprint: ($c + ":" + $f + ":" + $r + ":" + ($l | tostring))}'
}
fleet() { : > "$FXT/fleet.tsv"; local p; for p in "$@"; do printf '%s fx-org/%s\n' "$p" "$p" >> "$FXT/fleet.tsv"; done; }
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/catalog" "$FXT" "$REPOS"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT" "$REPOS" "$H/bin"
  : > "$FXT/beats.log"; : > "$FXT/gl.log"; : > "$FXT/wm-req.log"; : > "$FXT/wm-gh.log"; : > "$FXT/timeout.log"
  cp "$T/lane-alert.stub" "$H/bin/lane-alert.sh"
  cp "$T/fleet-conf.stub" "$H/bin/fleet-conf.sh"
}
# wm [VAR=value ...] — run the collector as shipped, sandboxed. Out: $T/out, RC.
wm() {
  env HARNESS="$H" FXT="$FXT" WM_FIXTURE="$T/wmfx.sh" HARNESS_TEST_SANDBOX=1 WM_NOW="${WNOW:-$NOW}" \
    WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$REPOS" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" "$@" bash "$COL" > "$T/out" 2> "$T/err"
  RC=$?
}
beats() { lines "$FXT/beats.log"; }
glruns() { lines "$FXT/gl.log"; }
WMS="$H/state/staff/watchman"
shape() {
  jq -e '.item and .title and .source.kind == "staff-security" and (.source.url | type == "string" and length > 0)
         and (.source.labels | type == "array") and .observedAt == "2026-10-15T12:00:00Z" and .class' "$1" >/dev/null 2>&1
}
no_secret() { # no_secret <case>: the value is in no output, log, state or beat
  local hits
  hits=$(grep -rlF "$LEAKV" "$T/out" "$T/err" "$H/logs" "$H/state" "$FXT/beats.log" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "$1: the secret value is in: $hits"
}

# ═════ W1: project-3 -> one critical finding, one beat, no secret value ═══════════
reset; fleet project-3; mkrepo project-3 "$LEAKV"; C1=$(tip project-3)
report project-3 "[$(leakrow "$C1" .env 1)]"
wm
eq "W1 rc" "$RC" 0
eq "W1 lines" "$(lines "$T/out")" 1
eq "W1 class" "$(jq -r .class "$T/out" 2>/dev/null)" history-secret
eq "W1 item" "$(jq -c .item "$T/out" 2>/dev/null)" \
  "{\"check\":\"history-secret\",\"project\":\"project-3\",\"commit\":\"$C1\",\"file\":\".env\",\"line\":1,\"rule\":\"aws-access-token\"}"
W1T="Critical: secret in git history: aws-access-token in project-3 .env:1 (commit ${C1:0:12})"
eq "W1 title" "$(jq -r .title "$T/out" 2>/dev/null)" "$W1T"
eq "W1 url" "$(jq -r .source.url "$T/out" 2>/dev/null)" "https://github.com/fx-org/project-3/commit/$C1"
shape "$T/out" && ok || bad "W1 line shape: $(cat "$T/out")"
eq "W1 gitleaks runs" "$(glruns)" 1
grep -q -- "--redact=100" "$FXT/gl.log" && ok || bad "W1: gitleaks ran without --redact=100: $(cat "$FXT/gl.log")"
grep -q -- "--not" "$FXT/gl.log" && bad "W1: the first scan has a --not range" || ok
eq "W1 beats" "$(beats)" 1
eq "W1 beat argv" "$(cat "$FXT/beats.log")" "--id staff-watchman-leak-project-3-$NOW --severity critical staff $W1T"
no_secret W1
eq "W1 scanned log" "$(grep -c 'scanned project-3 new=1' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W1 beat log" "$(grep -c 'beat project-3' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W1 tips saved" "$(cat "$WMS/scan/project-3.tips" 2>/dev/null)" "$C1"
eq "W1 leak cache rows" "$(lines "$WMS/leaks/project-3.jsonl")" 1

# ═════ W2: the next tick inside the interval, then the next interval ═════════
cp "$T/out" "$T/out.w1"
WNOW=$((NOW + HR)) wm
eq "W2 rc" "$RC" 0
eq "W2 same item" "$(jq -c .item "$T/out" 2>/dev/null)" "$(jq -c .item "$T/out.w1")"
eq "W2 gitleaks runs (inside the interval)" "$(glruns)" 1
eq "W2 beats" "$(beats)" 1
# The next interval, one new clean commit: the scan covers the new range only.
echo more > "$REPOS/project-3/notes"; gitc "$REPOS/project-3" add -A; gitc "$REPOS/project-3" commit -qm second
C2=$(tip project-3)
report project-3 '[]'
WNOW=$((NOW + 25 * HR)) wm
eq "W2 rc next interval" "$RC" 0
eq "W2 gitleaks runs next interval" "$(glruns)" 2
grep -q -- "--log-opts --all --not $C1" <(sed -n 2p "$FXT/gl.log") && ok || bad "W2: no --not <old tip>: $(sed -n 2p "$FXT/gl.log")"
eq "W2 beats next interval" "$(beats)" 1
eq "W2 cached line still printed" "$(jq -c .item "$T/out" 2>/dev/null)" "$(jq -c .item "$T/out.w1")"
eq "W2 tips moved" "$(cat "$WMS/scan/project-3.tips" 2>/dev/null)" "$C2"
# The same location returned again by a re-scan is not NEW: no beat.
echo more2 >> "$REPOS/project-3/notes"; gitc "$REPOS/project-3" commit -qam third
report project-3 "[$(leakrow "$C1" .env 1)]"
WNOW=$((NOW + 50 * HR)) wm
eq "W2 re-found location beats" "$(beats)" 1
eq "W2 re-found location lines" "$(lines "$T/out")" 1
eq "W2 cache rows" "$(lines "$WMS/leaks/project-3.jsonl")" 1
no_secret W2

# ═════ W4/W5: rotation-due ═══════════════════════════════════════════════════
reset; D10=$(day $((NOW - 10 * DAY))); reg fx-cred due "$D10"; wm
eq "W4 rc" "$RC" 0
eq "W4 lines" "$(lines "$T/out")" 1
eq "W4 class" "$(jq -r .class "$T/out" 2>/dev/null)" rotation-due
eq "W4 item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$D10\"}"
eq "W4 title" "$(jq -r .title "$T/out" 2>/dev/null)" \
  "Rotation past due: fx-cred was due $D10 (10 days ago); it lives in env file global.env, variable FX_CRED; owner ops@example.com"
shape "$T/out" && ok || bad "W4 line shape: $(cat "$T/out")"
eq "W4 latch" "$(cat "$WMS/due/fx-cred" 2>/dev/null)" "$D10"
eq "W4 beats" "$(beats)" 0
eq "W4 no findings read" "$(lines "$FXT/wm-req.log")" 0
# The computed form gives the same item as the explicit one.
reset; reg fx-cred rot "$(day $((NOW - 100 * DAY)))" 90; wm
eq "W4 rotated_at + every_days item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$D10\"}"
for d in "$(day "$NOW")" "$(day $((NOW + DAY)))"; do
  reset; reg fx-cred due "$d"; wm
  eq "W5 due $d rc" "$RC" 0
  eq "W5 due $d lines" "$(lines "$T/out")" 0
  [ -e "$WMS/due/fx-cred" ] && bad "W5 due $d wrote a latch" || ok
done

# ═════ W6: the decision-rule edges, table-driven ═════════════════════════════
# rotation-due: name | now | register (due:<date> | rot:<date>:<days> | bad) | want lines
while IFS='|' read -r name at spec want; do
  [ -n "$name" ] || continue
  reset
  case "$spec" in
    due:*) reg fx-cred due "${spec#due:}" ;;
    rot:*) IFS=: read -r _ rd re <<<"$spec"; reg fx-cred rot "$rd" "$re" ;;
    bad) mkdir -p "$REG"; echo '{"id":"fx-cred","where":"x","owner":"o","due":"2026-02-30"}' > "$REG/fx-cred.json" ;;
  esac
  WNOW=$at wm
  eq "W6 rotation $name rc" "$RC" 0
  eq "W6 rotation $name lines" "$(lines "$T/out")" "$want"
done <<EOF
due 10 days ago|$NOW|due:$(day $((NOW - 10 * DAY)))|1
due yesterday, now is midnight after it|$MID|due:$(day $((MID - DAY)))|1
due yesterday, one second before midnight|$((MID - 1))|due:$(day $((MID - DAY)))|0
due today|$NOW|due:$(day "$NOW")|0
due tomorrow|$NOW|due:$(day $((NOW + DAY)))|0
future rotated_at (a typo)|$NOW|rot:$(day $((NOW + 30 * DAY))):1|0
rotated 91 days ago, every 90|$NOW|rot:$(day $((NOW - 91 * DAY))):90|1
rotated 90 days ago, every 90|$NOW|rot:$(day $((NOW - 90 * DAY))):90|0
an invalid file|$NOW|bad|0
EOF
# scan due: name | .at age (s, or none) | tips (same | changed) | want gitleaks runs
while IFS='|' read -r name age tips want; do
  [ -n "$name" ] || continue
  reset; fleet p1; mkrepo p1; mkdir -p "$WMS/scan"
  [ "$age" = none ] || echo $((NOW - age)) > "$WMS/scan/p1.at"
  if [ "$tips" = same ]; then tip p1 > "$WMS/scan/p1.tips"; else echo 0000000000000000000000000000000000000000 > "$WMS/scan/p1.tips"; fi
  wm
  eq "W6 scan $name rc" "$RC" 0
  eq "W6 scan $name gitleaks runs" "$(glruns)" "$want"
done <<EOF
never scanned|none|changed|1
attempt 24 h + 1 s ago|$((24 * HR + 1))|changed|1
attempt exactly 24 h ago|$((24 * HR))|changed|0
attempt 24 h - 1 s ago|$((24 * HR - 1))|changed|0
due but tips unchanged|$((24 * HR + 1))|same|0
EOF
# A due project with unchanged tips is still stamped (one attempt per interval).
reset; fleet p1; mkrepo p1; mkdir -p "$WMS/scan"; echo $((NOW - 30 * HR)) > "$WMS/scan/p1.at"; tip p1 > "$WMS/scan/p1.tips"; wm
eq "W6 unchanged tips stamped" "$(cat "$WMS/scan/p1.at" 2>/dev/null)" "$NOW"
# A project with no repo on the box: no scan, stamped, one log line.
reset; fleet ghost-os; wm
eq "W6 no repo rc" "$RC" 0
eq "W6 no repo gitleaks runs" "$(glruns)" 0
eq "W6 no repo stamped" "$(cat "$WMS/scan/ghost-os.at" 2>/dev/null)" "$NOW"
eq "W6 no repo log line" "$(grep -c 'ghost-os has no repo' "$H/logs/staff.log" 2>/dev/null)" 1
WNOW=$((NOW + HR)) wm
eq "W6 no repo log once per interval" "$(grep -c 'ghost-os has no repo' "$H/logs/staff.log" 2>/dev/null)" 1
# A saved tip that no longer exists is dropped from --not; the same location
# found again after it is not NEW.
reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1); report p1 "[$(leakrow "$C1" .env 1)]"
gitc "$REPOS/p1" checkout -qb side; echo s > "$REPOS/p1/s"; gitc "$REPOS/p1" add -A; gitc "$REPOS/p1" commit -qm side
CS=$(tip p1); gitc "$REPOS/p1" checkout -q -; wm
eq "W6 vanished tip first beats" "$(beats)" 1
gitc "$REPOS/p1" branch -D side; gitc "$REPOS/p1" reflog expire --expire=now --all; gitc "$REPOS/p1" gc -q --prune=now
echo n > "$REPOS/p1/n"; gitc "$REPOS/p1" add -A; gitc "$REPOS/p1" commit -qm next
WNOW=$((NOW + 25 * HR)) wm
grep -q -- "$CS" <(sed -n 2p "$FXT/gl.log") && bad "W6: a vanished tip stayed in --not" || ok
grep -q -- "--not $C1" <(sed -n 2p "$FXT/gl.log") && ok || bad "W6: the live old tip left --not: $(sed -n 2p "$FXT/gl.log")"
eq "W6 vanished tip re-found location beats" "$(beats)" 1
# rotated -> merged: name | latch | register | findings status | want PATCH | want POST | latch kept
URL7=https://github.com/fx-org/fx-repo/issues/7
fpof() { # fpof <item json>: agent-core's fingerprint
  node --input-type=module -e "import { fingerprint } from '$DIR/agent-core/src/index.js'; console.log(fingerprint(JSON.parse(process.argv[1])));" "$1"
}
while IFS='|' read -r name latch spec status wpatch wpost wkept; do
  [ -n "$name" ] || continue
  reset
  case "$spec" in
    due:*) reg fx-cred due "${spec#due:}" ;;
    rot:*) IFS=: read -r _ rd re <<<"$spec"; reg fx-cred rot "$rd" "$re" ;;
  esac
  if [ "$latch" != none ]; then
    mkdir -p "$WMS/due"; echo "$latch" > "$WMS/due/fx-cred"
    fp=$(fpof "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$latch\"}")
    jq -n --arg f "$fp" --arg s "$status" --arg u "$URL7" '{agent: "watchman", truncated: false, findings: [{fingerprint: $f, status: $s, ticket_url: $u}]}' > "$FXT/findings.json"
  fi
  wm
  eq "W6 rotated $name rc" "$RC" 0
  eq "W6 rotated $name PATCH" "$(grep -c '^gh_rest PATCH' "$FXT/wm-gh.log")" "$wpatch"
  eq "W6 rotated $name POST" "$(grep -c '^POST /api/staff/outcomes' "$FXT/wm-req.log")" "$wpost"
  if [ -e "$WMS/due/fx-cred" ]; then k=1; else k=0; fi
  eq "W6 rotated $name latch kept" "$k" "$wkept"
done <<EOF
rotated_at moved to today|$(day $((NOW - 10 * DAY)))|rot:$(day "$NOW"):90|filed|1|1|0
the due did not move|$(day $((NOW - 10 * DAY)))|due:$(day $((NOW - 10 * DAY)))|filed|0|0|1
new due already past|$(day $((NOW - 10 * DAY)))|due:$(day $((NOW - 2 * DAY)))|filed|0|0|1
no latch|none|rot:$(day "$NOW"):90|filed|0|0|0
rotated, the finding was digested|$(day $((NOW - 10 * DAY)))|rot:$(day "$NOW"):90|digested|0|0|0
EOF
# A new due already past fires a NEW item, and the latch takes the new due.
reset; mkdir -p "$WMS/due"; day $((NOW - 10 * DAY)) > "$WMS/due/fx-cred"; reg fx-cred due "$(day $((NOW - 2 * DAY)))"; wm
eq "W6 new past due item" "$(jq -r .item.due "$T/out" 2>/dev/null)" "$(day $((NOW - 2 * DAY)))"
eq "W6 new past due latch" "$(cat "$WMS/due/fx-cred" 2>/dev/null)" "$(day $((NOW - 2 * DAY)))"
# The register entry deleted: the latch goes, nothing is closed.
reset; mkdir -p "$WMS/due" "$REG"; day $((NOW - 10 * DAY)) > "$WMS/due/fx-cred"; wm
eq "W6 entry deleted rc" "$RC" 0
[ -e "$WMS/due/fx-cred" ] && bad "W6: the latch of a deleted entry stayed" || ok
eq "W6 entry deleted PATCH" "$(lines "$FXT/wm-gh.log")" 0
eq "W6 entry deleted log" "$(grep -c 'fx-cred is no longer in the register' "$H/logs/staff.log" 2>/dev/null)" 1

# ═════ W7: the print order rotates through STAFF_MAX_ITEMS ═══════════════════
reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1)
rows=$(for i in $(seq 1 45); do leakrow "$C1" .env "$i"; done | jq -cs .); report p1 "$rows"
: > "$T/w7.all"
for k in 1 2 3; do
  WNOW=$((NOW + k * 60)) wm STAFF_MAX_ITEMS=20
  eq "W7 tick $k lines" "$(lines "$T/out")" 45
  head -20 "$T/out" | jq -r .item.line | sort -n > "$T/w7.$k"
  cat "$T/w7.$k" >> "$T/w7.all"
done
cmp -s "$T/w7.1" "$T/w7.2" && bad "W7: ticks 1 and 2 printed the same first 20" || ok
cmp -s "$T/w7.2" "$T/w7.3" && bad "W7: ticks 2 and 3 printed the same first 20" || ok
eq "W7 three windows cover all 45" "$(sort -nu "$T/w7.all" | grep -c .)" 45
eq "W7 one beat for the scan" "$(beats)" 1
case "$(cat "$FXT/beats.log")" in *"(+44 more)") ok ;; *) bad "W7 beat text: $(cat "$FXT/beats.log")" ;; esac
eq "W7 printed.tsv rows" "$(lines "$WMS/printed.tsv")" 45
# Rotation lines come first and take a slot.
reg fx-cred due "$(day $((NOW - 10 * DAY)))"; WNOW=$((NOW + 600)) wm STAFF_MAX_ITEMS=20
eq "W7 rotation line first" "$(head -1 "$T/out" | jq -r .class)" rotation-due
no_secret W7

# ═════ W8: knobs ═════════════════════════════════════════════════════════════
w1() { reset; fleet project-3; mkrepo project-3 "$LEAKV"; report project-3 "[$(leakrow "$(tip project-3)" .env 1)]"; }
w1; wm WM_PAGE_SEVERITY=off
eq "W8 off lines" "$(lines "$T/out")" 1
eq "W8 off beats" "$(beats)" 0
w1; wm WM_PAGE_SEVERITY=warn
grep -q -- '--severity warn staff' "$FXT/beats.log" && ok || bad "W8 warn: $(cat "$FXT/beats.log")"
w1; wm WM_PAGE_SEVERITY=bogus
grep -q -- '--severity critical staff' "$FXT/beats.log" && ok || bad "W8 bogus beat: $(cat "$FXT/beats.log")"
eq "W8 bogus warn line" "$(grep -c 'agent=watchman warn: WM_PAGE_SEVERITY=bogus' "$H/logs/staff.log" 2>/dev/null)" 1
# WM_SCAN_TIMEOUT_S: the default 90, and out of range -> warn + 90.
w1; wm
eq "W8 default scan timeout" "$(cat "$FXT/timeout.log")" 90
w1; wm WM_SCAN_TIMEOUT_S=45
eq "W8 scan timeout 45" "$(cat "$FXT/timeout.log")" 45
w1; wm WM_SCAN_TIMEOUT_S=5
eq "W8 scan timeout 5 -> 90" "$(cat "$FXT/timeout.log")" 90
grep -q 'warn: WM_SCAN_TIMEOUT_S=5 is outside' "$H/logs/staff.log" 2>/dev/null && ok || bad "W8: no timeout warn"
# The defaults are the registry's: 24 h, 1 repo per tick, 90 s, critical, /root/repos.
eq "W8 registry defaults" "$(jq -c '[.libs[0].knobs[] | select(.env | test("^WM_(REPOS_ROOT|SCAN_INTERVAL_H|SCAN_REPOS_PER_TICK|SCAN_TIMEOUT_S|PAGE_SEVERITY)$")) | {(.env): .default}] | add' "$LIBF" 2>/dev/null)" \
  '{"WM_REPOS_ROOT":"/root/repos","WM_SCAN_INTERVAL_H":24,"WM_SCAN_REPOS_PER_TICK":1,"WM_SCAN_TIMEOUT_S":90,"WM_PAGE_SEVERITY":"critical"}'
# WM_SCAN_INTERVAL_H from a settings row, through lib_env_apply and the real registry.
REGJ="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --to "$REGJ" >/dev/null 2>&1 || bad "W8: cannot render the lane registry"
jq -e '.libs[] | select(.id == "staff-watchman")' "$REGJ" >/dev/null 2>&1 && ok || bad "W8: catalog/lanes.json has no lib staff-watchman"
w2h() { reset; fleet p1; mkrepo p1; mkdir -p "$WMS/scan"; echo $((NOW - 2 * HR)) > "$WMS/scan/p1.at"; }
w2h; printf '{"fetched_at":%s,"values":{"lib.staff-watchman.wm_scan_interval_h":"1"},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
wm LANE_REGISTRY="$REGJ" LANE_GATE_NOW="$NOW"
eq "W8 settings row interval 1 h scans" "$(glruns)" 1
w2h; printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
wm LANE_REGISTRY="$REGJ" LANE_GATE_NOW="$NOW"
eq "W8 no row: 24 h, no scan" "$(glruns)" 0

# ═════ W9: register validation ═══════════════════════════════════════════════
reset; reg good due "$(day $((NOW - 5 * DAY)))"
jq -n '{id: "valueshaped", where: ("env " + "QWERTYUIOPASDFGHJKLZXCVBNM12"), owner: "o", due: "2026-01-01"}' > "$REG/valueshaped.json"
jq -n '{id: "baddate", where: "env file", owner: "o", due: "2026-13-01"}' > "$REG/baddate.json"
jq -n '{id: "both", where: "env file", owner: "o", due: "2026-01-01", rotated_at: "2025-01-01", every_days: 90}' > "$REG/both.json"
jq -n '{id: "other-name", where: "env file", owner: "o", due: "2026-01-01"}' > "$REG/misnamed.json"
jq -n '{id: "neither", where: "env file", owner: "o"}' > "$REG/neither.json"
jq -n '{id: "baddays", where: "env file", owner: "o", rotated_at: "2025-01-01", every_days: 0}' > "$REG/baddays.json"
jq -n '{id: "noowner", where: "env file", due: "2026-01-01"}' > "$REG/noowner.json"
printf '{not json' > "$REG/notjson.json"
wm
eq "W9 rc" "$RC" 0
eq "W9 lines" "$(lines "$T/out")" 1
eq "W9 the good file fires" "$(jq -r .item.credential "$T/out" 2>/dev/null)" good
eq "W9 one log line per bad file" "$(grep -c 'watchman: register .* invalid' "$H/logs/staff.log" 2>/dev/null)" 8
grep -q 'register valueshaped.json invalid (where' "$H/logs/staff.log" 2>/dev/null && ok || bad "W9: the value-shaped where was not named"
grep -q 'QWERTYUIOP' "$H/logs/staff.log" "$T/out" 2>/dev/null && bad "W9: the value-shaped where reached a log or a line" || ok

# ═════ W10: two credentials, one due date -> two fingerprints ════════════════
reset; DD=$(day $((NOW - 3 * DAY))); reg cred-a due "$DD"; reg cred-b due "$DD"; wm
eq "W10 lines" "$(lines "$T/out")" 2
FA=$(fpof "$(sed -n 1p "$T/out" | jq -c .item)"); FB=$(fpof "$(sed -n 2p "$T/out" | jq -c .item)")
[ -n "$FA" ] && [ "$FA" != "$FB" ] && ok || bad "W10: two credentials share one fingerprint ($FA)"
# Two locations in one file differ only by line: two fingerprints.
reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1); report p1 "[$(leakrow "$C1" .env 1),$(leakrow "$C1" .env 2)]"; wm
FA=$(fpof "$(sed -n 1p "$T/out" | jq -c .item)"); FB=$(fpof "$(sed -n 2p "$T/out" | jq -c .item)")
[ -n "$FA" ] && [ "$FA" != "$FB" ] && ok || bad "W10: two locations share one fingerprint ($FA)"

# ═════ W11: failures ═════════════════════════════════════════════════════════
# jq missing: rc 1, nothing printed.
mkdir -p "$T/nojq"
for b in bash git date env cat mkdir sort dirname basename sed grep tr head mktemp rm; do ln -sf "$(command -v $b)" "$T/nojq/$b"; done
w1; env -i HARNESS="$H" HARNESS_TEST_SANDBOX=1 WM_NOW="$NOW" WM_REPOS_ROOT="$REPOS" PATH="$T/nojq" \
  "$T/nojq/bash" "$COL" > "$T/out" 2>/dev/null; RC=$?
eq "W11 jq missing rc" "$RC" 1
eq "W11 jq missing stdout" "$(lines "$T/out")" 0
eq "W11 jq missing beats" "$(beats)" 0
# gitleaks rc 2: rc 0, the cached line still prints, tips unchanged, no beat.
w1; wm; cp "$WMS/scan/project-3.tips" "$T/tips.before"
echo s > "$REPOS/project-3/x"; gitc "$REPOS/project-3" add -A; gitc "$REPOS/project-3" commit -qm x
report project-3 "[$(leakrow "$(tip project-3)" x 1)]"; echo 2 > "$FXT/gl.rc"
WNOW=$((NOW + 25 * HR)) wm
eq "W11 gitleaks rc 2 rc" "$RC" 0
eq "W11 gitleaks rc 2 lines (cached)" "$(lines "$T/out")" 1
cmp -s "$WMS/scan/project-3.tips" "$T/tips.before" && ok || bad "W11: the tips moved after a failed scan"
eq "W11 gitleaks rc 2 beats" "$(beats)" 1
eq "W11 failed log" "$(grep -c 'scan project-3 failed' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W11 no scanned after a fail" "$(grep -c 'scanned project-3' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W11 failed scan stamped" "$(cat "$WMS/scan/project-3.at")" $((NOW + 25 * HR))
# A report that is not a gitleaks report: a failed scan too.
rm -f "$FXT/gl.rc"; report project-3 '{"oops":1}'; WNOW=$((NOW + 50 * HR)) wm
eq "W11 junk report rc" "$RC" 0
eq "W11 junk report failed log" "$(grep -c 'scan project-3 failed' "$H/logs/staff.log" 2>/dev/null)" 2
cmp -s "$WMS/scan/project-3.tips" "$T/tips.before" && ok || bad "W11: the tips moved after a junk report"
# A timeout: a failed scan.
touch "$FXT/timeout.force"; WNOW=$((NOW + 75 * HR)) wm; rm -f "$FXT/timeout.force"
eq "W11 timeout failed log" "$(grep -c 'scan project-3 failed (timeout' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W11 timeout leak beats" "$(grep -c -- '--id staff-watchman-leak-' "$FXT/beats.log")" 1
# The third failed scan in a row (rc 2, junk, timeout) is one warn beat: the
# repo is not covered, and that is an alert, not a log line.
eq "W11 scanfail beats" "$(grep -c -- "--id staff-watchman-scanfail-project-3-$((NOW + 75 * HR)) --severity warn staff Watchman: the history scan of project-3 failed 3 times in a row (last: timeout after 90 s on 1 commit" "$FXT/beats.log")" 1
eq "W11 timeout beats" "$(beats)" 2
eq "W11 fail count" "$(cat "$WMS/scan/project-3.fail" 2>/dev/null)" 3
# A good scan resets the count, and the next failure run pages again only at 3.
report project-3 '[]'; WNOW=$((NOW + 100 * HR)) wm
[ -e "$WMS/scan/project-3.fail" ] && bad "W11: a good scan kept the fail count" || ok
eq "W11 good scan beats" "$(beats)" 2
# A report row that fails validation is skipped with one log line; the good one stays.
w1; report project-3 "[$(leakrow "$(tip project-3)" .env 1 'bad rule"x'),$(leakrow "$(tip project-3)" .env 2),$(leakrow nothex .env 3)]"; wm
eq "W11 bad rows lines" "$(lines "$T/out")" 1
eq "W11 bad rows log lines" "$(grep -c 'report row skipped' "$H/logs/staff.log" 2>/dev/null)" 2
# gitleaks cannot be installed: one warn line, no scan, rotation items still print, rc 0.
reset; fleet p1; mkrepo p1; reg fx-cred due "$(day $((NOW - 10 * DAY)))"; wm WM_GITLEAKS="$T/no-such-gitleaks"
eq "W11 no gitleaks rc" "$RC" 0
eq "W11 no gitleaks lines" "$(lines "$T/out")" 1
grep -q 'agent=watchman warn: gitleaks unavailable' "$H/logs/staff.log" 2>/dev/null && ok || bad "W11: no gitleaks warn"
[ -e "$WMS/scan/p1.tips" ] && bad "W11: tips saved with no gitleaks" || ok
# The rotated close: findings unreadable -> no PATCH, latch kept.
rot_fx() {
  reset; mkdir -p "$WMS/due"; day $((NOW - 10 * DAY)) > "$WMS/due/fx-cred"; reg fx-cred rot "$(day "$NOW")" 90
  fp=$(fpof "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$(day $((NOW - 10 * DAY)))\"}")
  jq -n --arg f "$fp" --arg u "$URL7" '{agent: "watchman", truncated: false, findings: [{fingerprint: $f, status: "filed", ticket_url: $u}]}' > "$FXT/findings.json"
}
rot_fx; touch "$FXT/findings.fail"; wm
eq "W11 findings unreadable rc" "$RC" 0
eq "W11 findings unreadable PATCH" "$(lines "$FXT/wm-gh.log")" 0
[ -e "$WMS/due/fx-cred" ] && ok || bad "W11: the latch went with the findings unreadable"
# A truncated list that does not hold the finding: not "not found"; latch kept.
rot_fx; jq '.findings = [] | .truncated = true' "$FXT/findings.json" > "$FXT/f.tmp" && mv "$FXT/f.tmp" "$FXT/findings.json"; wm
[ -e "$WMS/due/fx-cred" ] && ok || bad "W11: a truncated list dropped the latch"
eq "W11 truncated PATCH" "$(lines "$FXT/wm-gh.log")" 0
# PATCH rc 75: latch kept, no POST.
rot_fx; echo 75 > "$FXT/patch.rc"; wm
eq "W11 PATCH 75 PATCHes" "$(grep -c '^gh_rest PATCH' "$FXT/wm-gh.log")" 1
eq "W11 PATCH 75 POST" "$(grep -c '^POST /api/staff/outcomes' "$FXT/wm-req.log")" 0
[ -e "$WMS/due/fx-cred" ] && ok || bad "W11: the latch went after a failed PATCH"
# POST fails after a good PATCH: latch kept; the next tick PATCHes again and posts.
rot_fx; touch "$FXT/outcome.fail"; wm
eq "W11 POST fail PATCH" "$(grep -c '^gh_rest PATCH' "$FXT/wm-gh.log")" 1
eq "W11 POST fail POST" "$(grep -c '^POST /api/staff/outcomes' "$FXT/wm-req.log")" 1
[ -e "$WMS/due/fx-cred" ] && ok || bad "W11: the latch went after a failed POST"
grep -q 'closed fx-cred as merged' "$H/logs/staff.log" 2>/dev/null && bad "W11: logged closed after a failed POST" || ok
rm -f "$FXT/outcome.fail"; wm
eq "W11 retry PATCH" "$(grep -c '^gh_rest PATCH' "$FXT/wm-gh.log")" 2
eq "W11 retry POST" "$(grep -c '^POST /api/staff/outcomes' "$FXT/wm-req.log")" 2
[ -e "$WMS/due/fx-cred" ] && bad "W11: the latch stayed after a 200 outcome" || ok
eq "W11 closed log" "$(grep -c 'closed fx-cred as merged' "$H/logs/staff.log" 2>/dev/null)" 1
# The PATCH comes before the POST.
eq "W11 order" "$(cat "$FXT/wm-gh.log" "$FXT/wm-req.log" | grep -o '^gh_rest PATCH\|^POST' | head -1)" "gh_rest PATCH"
grep '^gh_rest PATCH' "$FXT/wm-gh.log" | head -1 | grep -qF 'repos/fx-org/fx-repo/issues/7 {"state":"closed","state_reason":"completed"}' \
  && ok || bad "W11 PATCH body: $(head -1 "$FXT/wm-gh.log")"

# ═════ W15: two projects due, one scan per tick ══════════════════════════════
reset; fleet pa pb; mkrepo pa; mkrepo pb; wm
eq "W15 tick 1 gitleaks runs" "$(glruns)" 1
WNOW=$((NOW + 900)) wm
eq "W15 tick 2 gitleaks runs" "$(glruns)" 2
eq "W15 both scanned" "$(sed 's/^git \([^ ]*\) .*/\1/' "$FXT/gl.log" | xargs -n1 basename | sort | paste -sd' ')" "pa pb"
WNOW=$((NOW + 1800)) wm
eq "W15 tick 3 nothing due" "$(glruns)" 2
reset; fleet pa pb; mkrepo pa; mkrepo pb; wm WM_SCAN_REPOS_PER_TICK=2
eq "W15 bound 2 scans both" "$(glruns)" 2

# ═════ W17: a first scan in chunks covers every commit exactly once ══════════
# commits <project> <n>: n more clean commits.
commits() { local i; for i in $(seq 1 "$2"); do echo "$i" >> "$REPOS/$1/c"; gitc "$REPOS/$1" add -A; gitc "$REPOS/$1" commit -qm "c$i"; done; }
# logopts <n>: the --log-opts value of gitleaks run n.
logopts() { sed -n "${1}p" "$FXT/gl.log" | sed 's/.*--log-opts \(.*\) --redact=100 .*/\1/'; }
# covered <project> <from run> <to run>: the commits those runs read, in rev-list
# terms; prints "<commits read, duplicates counted> <distinct>".
covered() {
  local i all=""
  for i in $(seq "$2" "$3"); do
    # shellcheck disable=SC2046
    all="$all$(git -C "$REPOS/$1" rev-list $(logopts "$i"))"$'\n'
  done
  printf '%s %s' "$(grep -c . <<<"$all")" "$(grep . <<<"$all" | sort -u | grep -c .)"
}
reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1); commits p1 4
report p1 "[$(leakrow "$C1" .env 1)]"
wm WM_SCAN_CHUNK_COMMITS=2
eq "W17 rc" "$RC" 0
eq "W17 gitleaks runs (2 + 2 + 1 commits)" "$(glruns)" 3
case "$(logopts 1)" in *--all*) bad "W17: chunk 1 read --all: $(logopts 1)" ;; *) ok ;; esac
case "$(logopts 3)" in "--all --not "*) ok ;; *) bad "W17: the last chunk is not --all --not <cursor>: $(logopts 3)" ;; esac
eq "W17 every commit read once" "$(covered p1 1 3)" "5 5"
eq "W17 lines" "$(lines "$T/out")" 1
eq "W17 class" "$(jq -r .class "$T/out" 2>/dev/null)" history-secret
eq "W17 beats" "$(beats)" 1
eq "W17 tips are the ref tips" "$(cat "$WMS/scan/p1.tips" 2>/dev/null)" "$(tip p1)"
[ -f "$WMS/scan/p1.based" ] && ok || bad "W17: the first scan is not marked done"
[ -e "$WMS/first/p1.jsonl" ] && bad "W17: the held first scan stayed" || ok
eq "W17 chunk log" "$(grep -c 'scanned p1 chunk of 2 of 5 commits' "$H/logs/staff.log" 2>/dev/null)" 1
no_secret W17
# The tick budget: STAFF_COLLECT_TIMEOUT_S=30 leaves 10 s for scans. The 5 s
# slack covers the real start-up time; the scan still gets exactly 10 s (FULL).
# A 6 s chunk then leaves at most 4 s, so the tick stops; the first scan is held (no line, no beat) and
# the project is due again at once. The next tick finishes it.
reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1); commits p1 4
report p1 "[$(leakrow "$C1" .env 1)]"
echo 6 > "$FXT/advance"; echo 5 > "$FXT/slack"
wm WM_SCAN_CHUNK_COMMITS=2 STAFF_COLLECT_TIMEOUT_S=30
rm -f "$FXT/advance" "$FXT/slack"
eq "W17 budget rc" "$RC" 0
eq "W17 budget gitleaks runs" "$(glruns)" 1
eq "W17 budget scan timeout" "$(cat "$FXT/timeout.log")" 10
grep -q 'warn: WM_SCAN_TIMEOUT_S=90 does not fit STAFF_COLLECT_TIMEOUT_S=30; one scan gets at most 10 s' "$H/logs/staff.log" 2>/dev/null \
  && ok || bad "W17: no budget warn line"
eq "W17 budget lines (held)" "$(lines "$T/out")" 0
eq "W17 budget beats (held)" "$(beats)" 0
eq "W17 budget held rows" "$(lines "$WMS/first/p1.jsonl")" 1
eq "W17 budget stamp: due again at once" "$(cat "$WMS/scan/p1.at" 2>/dev/null)" $((NOW - 24 * HR - 1))
WNOW=$((NOW + 900)) wm WM_SCAN_CHUNK_COMMITS=2
eq "W17 next tick runs" "$(glruns)" 3
eq "W17 next tick every commit read once" "$(covered p1 1 3)" "5 5"
eq "W17 next tick lines" "$(lines "$T/out")" 1
eq "W17 next tick beats" "$(beats)" 1
eq "W17 next tick stamp" "$(cat "$WMS/scan/p1.at" 2>/dev/null)" $((NOW + 900))

# ═════ W18: a chunk that times out halves; a fast chunk doubles back ═════════
reset; fleet p1; mkrepo p1; commits p1 4; report p1 '[]'
touch "$FXT/timeout.force"; wm WM_SCAN_CHUNK_COMMITS=4; rm -f "$FXT/timeout.force"
eq "W18 rc" "$RC" 0
eq "W18 timeouts (4, 2, 1 commits)" "$(lines "$FXT/timeout.log")" 3
eq "W18 halved to 2" "$(grep -c 'scan p1 failed (timeout after 90 s on 4 commits); the next run reads 2 commits' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W18 halved to 1" "$(grep -c 'scan p1 failed (timeout after 90 s on 2 commits); the next run reads 1 commits' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W18 one commit is a failed scan" "$(grep -c 'scan p1 failed (timeout after 90 s on 1 commit, ' "$H/logs/staff.log" 2>/dev/null)" 1
eq "W18 chunk" "$(cat "$WMS/scan/p1.chunk" 2>/dev/null)" 1
eq "W18 fail count" "$(cat "$WMS/scan/p1.fail" 2>/dev/null)" 1
eq "W18 failed scan stamped" "$(cat "$WMS/scan/p1.at" 2>/dev/null)" "$NOW"
[ -e "$WMS/scan/p1.tips" ] && bad "W18: tips saved after a timeout" || ok
WNOW=$((NOW + 25 * HR)) wm WM_SCAN_CHUNK_COMMITS=4
eq "W18 next interval runs (1, 2, 2 commits)" "$(glruns)" 3
eq "W18 every commit read once" "$(covered p1 1 3)" "5 5"
eq "W18 chunk back to 4" "$(cat "$WMS/scan/p1.chunk" 2>/dev/null)" 4
[ -f "$WMS/scan/p1.based" ] && ok || bad "W18: the first scan is not marked done"
[ -e "$WMS/scan/p1.fail" ] && bad "W18: a good scan kept the fail count" || ok

# ═════ W19: a first scan over WM_FIRST_SCAN_MAX is one baseline finding ══════
w19() {
  reset; fleet p1; mkrepo p1 "$LEAKV"; C1=$(tip p1)
  report p1 "[$(leakrow "$C1" fx/test.js 1 generic-api-key),$(leakrow "$C1" fx/test.js 2 generic-api-key),$(leakrow "$C1" fx/test.js 3 generic-api-key),$(leakrow "$C1" .env 1),$(leakrow "$C1" .env 2)]"
}
w19; wm WM_FIRST_SCAN_MAX=3
eq "W19 rc" "$RC" 0
eq "W19 lines" "$(lines "$T/out")" 1
eq "W19 class" "$(jq -r .class "$T/out" 2>/dev/null)" history-baseline
eq "W19 item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"history-baseline\",\"project\":\"p1\",\"locations\":5,\"at\":$NOW}"
W19T="Critical: 5 secret-shaped locations in the git history of p1 at its first scan (2 files; generic-api-key 3, aws-access-token 2). Too many to file one by one: review state/staff/watchman/base/p1.jsonl on $(hostname), and allowlist test fixtures in the repo .gitleaksignore"
eq "W19 title" "$(jq -r .title "$T/out" 2>/dev/null)" "$W19T"
eq "W19 url" "$(jq -r .source.url "$T/out" 2>/dev/null)" "https://github.com/fx-org/p1"
shape "$T/out" && ok || bad "W19 line shape: $(cat "$T/out")"
eq "W19 beats" "$(beats)" 1
eq "W19 beat argv" "$(cat "$FXT/beats.log")" "--id staff-watchman-baseline-p1-$NOW --severity critical staff $W19T"
eq "W19 baseline rows" "$(lines "$WMS/base/p1.jsonl")" 5
eq "W19 leak cache rows" "$(lines "$WMS/leaks/p1.jsonl")" 0
no_secret W19
# The next tick: the same one line, no beat.
WNOW=$((NOW + HR)) wm WM_FIRST_SCAN_MAX=3
eq "W19 next tick lines" "$(lines "$T/out")" 1
eq "W19 next tick beats" "$(beats)" 1
# The next interval: a baseline location found again is not NEW; a new one is.
echo n > "$REPOS/p1/n"; gitc "$REPOS/p1" add -A; gitc "$REPOS/p1" commit -qm next; C2=$(tip p1)
report p1 "[$(leakrow "$C1" fx/test.js 1 generic-api-key),$(leakrow "$C1" .env 2),$(leakrow "$C2" n 1)]"
WNOW=$((NOW + 25 * HR)) wm WM_FIRST_SCAN_MAX=3
eq "W19 after the baseline lines" "$(lines "$T/out")" 2
eq "W19 after the baseline order" "$(jq -r .class "$T/out" 2>/dev/null | paste -sd' ')" "history-baseline history-secret"
eq "W19 after the baseline new item" "$(sed -n 2p "$T/out" | jq -r '"\(.item.commit) \(.item.file)"')" "$C2 n"
eq "W19 after the baseline beats" "$(beats)" 2
eq "W19 after the baseline leak beat" "$(grep -c -- "--id staff-watchman-leak-p1-$((NOW + 25 * HR))" "$FXT/beats.log")" 1
no_secret W19b
# Exactly WM_FIRST_SCAN_MAX locations: filed one by one, as W1.
w19; wm WM_FIRST_SCAN_MAX=5
eq "W19 at the max lines" "$(lines "$T/out")" 5
eq "W19 at the max classes" "$(jq -r .class "$T/out" | sort -u)" history-secret
eq "W19 at the max beats" "$(grep -c -- '--id staff-watchman-leak-p1-' "$FXT/beats.log")" 1
[ -e "$WMS/base/p1.item" ] && bad "W19: a baseline at the max" || ok
# WM_FIRST_SCAN_MAX out of range: one warn line and the default 100.
w19; wm WM_FIRST_SCAN_MAX=0
eq "W19 max 0 -> 100 lines" "$(lines "$T/out")" 5
grep -q 'warn: WM_FIRST_SCAN_MAX=0 is outside 1..100000; using the default 100' "$H/logs/staff.log" 2>/dev/null && ok || bad "W19: no WM_FIRST_SCAN_MAX warn"

# ═════ W20: the repo's own .gitleaksignore reaches the scan ══════════════════
w1; wm
grep -qF -- "--gitleaks-ignore-path $REPOS/project-3 " "$FXT/gl.log" && ok || bad "W20: no --gitleaks-ignore-path <repo>: $(cat "$FXT/gl.log")"

# ═════ W3: the production entry point ════════════════════════════════════════
S="$T/s"
mkdir -p "$S/prompts/staff" "$S/catalog/prompts" "$S/catalog/staff-rotations.d"
scratch_install_closure bin/staff.sh "$S" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
scratch_install_closure bin/jobs-client.sh "$S" >/dev/null || bad "W3 closure of bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$S" >/dev/null || bad "W3 closure of the collector failed"
fi
cp "$DIR/bin/staff-core.mjs" "$S/bin/"
cp -r "$DIR/agent-core" "$S/agent-core"
cp "$DIR/prompts/staff/watchman-soul.md" "$S/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$S/catalog/prompts/"
cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit 0
SH
cp "$T/lane-alert.stub" "$S/bin/lane-alert.sh"
cp "$T/fleet-conf.stub" "$S/bin/fleet-conf.sh"
chmod +x "$S/bin/agent-call.sh" "$S/bin/lane-alert.sh" "$S/bin/fleet-conf.sh"
# The claim stub keys on agent-core's fingerprint of the item, as the route does.
cat > "$T/stafffx.sh" <<SH
AGENT_CORE="$DIR/agent-core/src/index.js"
SH
cat >> "$T/stafffx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/staff-req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=watchman")
      printf '{"agent":{"name":"watchman","autonomy":"augmentation","cap":"augmentation","status":"active","soul":"prompts/staff/watchman-soul.md"}}'
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/staff-req.log"
  local fp
  case "$2" in
    /api/staff/findings/claim)
      fp=$(node --input-type=module -e "import { fingerprint } from '$AGENT_CORE'; console.log(fingerprint(JSON.parse(process.argv[1]).item));" "$(cat "$3")")
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
  [ "${3:-}" = --input ] && cp "$4" "$FXT/gh-payload.json"
  GH_REST_STATUS=201
  printf '{"number":7,"html_url":"https://github.com/fx-org/fx-repo/issues/7"}\n'
  return 0
}
gh_rest_issue_list() { printf 'LIST %s\n' "$*" >> "$FXT/gh.log"; GH_REST_STATUS=200; echo '[]'; return 0; }
lane_role_model() { printf 'stub-model\n'; }
SH
w3() { # w3 <now> — one tick, the shipped entry point
  : > "$FXT/staff-req.log"; : > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/wm-req.log"; : > "$FXT/wm-gh.log"; : > "$FXT/beats.log"
  env HARNESS="$S" FXT="$FXT" STAFF_FIXTURE="$T/stafffx.sh" WM_FIXTURE="$T/wmfx.sh" \
    HARNESS_TEST_SANDBOX=1 WM_NOW="$1" WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$REPOS" \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" bash "$S/bin/staff.sh" tick watchman > "$T/w3.out" 2>&1
  RC=$?
}
reset; scratch_rm "$S/state" || exit 1; scratch_rm "$S/logs" || exit 1; rm -f "$FXT/claimed" "$FXT/records.jsonl"
SREG="$S/catalog/staff-rotations.d"
DUE_OLD=$(day $((NOW - 10 * DAY)))
jq -n --arg d "$(day $((NOW - 100 * DAY)))" '{id: "fx-cred", where: "env file global.env, variable FX_CRED", owner: "ops@example.com", rotated_at: $d, every_days: 90}' > "$SREG/fx-cred.json"
w3 "$NOW"
eq "W3 tick1 rc" "$RC" 0
eq "W3 tick1 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 1
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '"agent":"watchman"' && ok || bad "W3: the claim is not watchman's"
grep 'findings/claim' "$FXT/staff-req.log" | grep -q "Rotation past due: fx-cred was due $DUE_OLD" && ok || bad "W3: the claim title: $(cat "$FXT/staff-req.log")"
eq "W3 tick1 agent-calls" "$(cat "$FXT/ac.log" 2>/dev/null)" "staff-tick|watchman"
eq "W3 tick1 issue creates" "$(grep -c '^gh_rest POST repos/.*/issues$' "$FXT/gh.log")" 1
eq "W3 tick1 labels" "$(jq -c .labels "$FXT/gh-payload.json" 2>/dev/null)" '["staff:watchman"]'
eq "W3 tick1 latch" "$(cat "$S/state/staff/watchman/due/fx-cred" 2>/dev/null)" "$DUE_OLD"
eq "W3 tick1 beats" "$(lines "$FXT/beats.log")" 0
w3 $((NOW + HR))
eq "W3 tick2 rc" "$RC" 0
eq "W3 tick2 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 1
eq "W3 tick2 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "W3 tick2 issue creates" "$(grep -c '^gh_rest POST' "$FXT/gh.log")" 0
eq "W3 tick2 PATCH" "$(lines "$FXT/wm-gh.log")" 0
# Tick 3: the key was rotated today.
jq --arg d "$(day $((NOW + 2 * HR)))" '.rotated_at = $d' "$SREG/fx-cred.json" > "$T/r.tmp" && mv "$T/r.tmp" "$SREG/fx-cred.json"
w3 $((NOW + 2 * HR))
eq "W3 tick3 rc" "$RC" 0
eq "W3 tick3 PATCH" "$(grep -c '^gh_rest PATCH repos/fx-org/fx-repo/issues/7 {"state":"closed","state_reason":"completed"}$' "$FXT/wm-gh.log")" 1
FPOLD=$(fpof "{\"check\":\"rotation-due\",\"credential\":\"fx-cred\",\"due\":\"$DUE_OLD\"}")
eq "W3 tick3 outcome POST" "$(grep '^POST /api/staff/outcomes' "$FXT/wm-req.log" | cut -d' ' -f3- | jq -c '{agent, fingerprint, outcome, ticket_url}')" \
  "{\"agent\":\"watchman\",\"fingerprint\":\"$FPOLD\",\"outcome\":\"merged\",\"ticket_url\":\"https://github.com/fx-org/fx-repo/issues/7\"}"
eq "W3 tick3 the filed fingerprint is the collector's" "$(jq -r 'select(.outcome == "filed") | .fingerprint' "$FXT/records.jsonl")" "$FPOLD"
[ -e "$S/state/staff/watchman/due/fx-cred" ] && bad "W3 tick3: the latch stayed" || ok
eq "W3 tick3 issue creates" "$(grep -c '^gh_rest POST' "$FXT/gh.log")" 0
eq "W3 tick3 agent-calls" "$(lines "$FXT/ac.log")" 0
w3 $((NOW + 3 * HR))
eq "W3 tick4 PATCH" "$(lines "$FXT/wm-gh.log")" 0
eq "W3 tick4 POST" "$(grep -c '^POST' "$FXT/wm-req.log")" 0
eq "W3 tick4 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 0
# With the collector gone, the tick claims nothing.
jq --arg d "$(day $((NOW - 100 * DAY)))" '.rotated_at = $d' "$SREG/fx-cred.json" > "$T/r.tmp" && mv "$T/r.tmp" "$SREG/fx-cred.json"
rm -f "$S/$COL_REL" "$FXT/claimed"; w3 "$NOW"
eq "W3 no collector claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 0

# ═════ W12/W13: the lane seed ════════════════════════════════════════════════
LANES4="audit-tail claude-auth-check gh-pat-charge-alert security-scan"
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-5565-watchman-lanes.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && ok || bad "W12: no worker/jobs/schema.d/*-bh-5565-watchman-lanes.sql fragment"
SEEDED=$( [ -n "$SEED" ] && sed -n "s/^[[:space:]]*('watchman','\([a-z0-9-]*\)',.*/\1/p" "$SEED" | LC_ALL=C sort | paste -sd' ')
eq "W12 seeded lanes" "$SEEDED" "$LANES4"
for L in $SEEDED; do
  [ -r "$DIR/catalog/lanes.d/$L.json" ] && ok || bad "W12: seeded lane $L has no catalog/lanes.d/$L.json"
done
if [ -n "$SEED" ] && grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED"; then
  bad "W12: the seed fragment holds DDL or a destructive statement"
else ok; fi
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "W13: bin/schema-build.sh --to failed"
  GOT=$(node --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(":memory:");
    db.exec(require("node:fs").readFileSync(process.argv[1], "utf8"));
    db.exec(require("node:fs").readFileSync(process.argv[2], "utf8"));
    const r = db.prepare("SELECT lane FROM staff_lanes WHERE agent = ? ORDER BY lane").all("watchman");
    console.log(r.map((x) => x.lane).join(" "));
    // 5000 findings over 4 agents; the GET /api/staff/findings?agent= read.
    const ins = db.prepare(`INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels,
      observed_at, status, claimed_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const agents = ["watchman", "dispatcher", "quartermaster", "clerk"];
    const st = ["claimed", "filed", "merged", "digested"];
    for (let i = 0; i < 5000; i++) {
      ins.run(i.toString(16).padStart(64, "0"), agents[i % 4], "t", "k", "u", "[]", "2026-10-01T00:00:00Z", st[i % 4], "x", "x");
    }
    db.exec("ANALYZE");
    const plan = db.prepare(`EXPLAIN QUERY PLAN SELECT id, fingerprint, agent, title, source_kind, source_url, status, ticket_url,
      observed_at, claimed_at, updated_at FROM staff_findings WHERE agent=?1 AND status NOT IN ('"'merged','rejected','noise','closed'"')
      ORDER BY id DESC LIMIT 501`).all().map((x) => x.detail).join(" | ");
    console.log("PLAN " + plan);
  ' "$T/schema.sql" "${SEED:-/dev/null}" 2>&1)
  eq "W13 watchman lanes after the seed applies twice" "$(head -1 <<<"$GOT")" "$LANES4"
  P=$(sed -n 's/^PLAN //p' <<<"$GOT")
  grep -q 'idx_staff_findings_agent' <<<"$P" && ! grep -qE 'SCAN staff_findings($| )' <<<"$P" && ! grep -q 'TEMP B-TREE' <<<"$P" \
    && ok || bad "W13 the findings read must use idx_staff_findings_agent with no scan or temp sort: $P"
else
  echo "W13 skipped: node:sqlite is not available in this node"
fi

# ═════ W14: the committed register ═══════════════════════════════════════════
reset; mkdir -p "$REG"; N=0
for f in "$DIR"/catalog/staff-rotations.d/*.json; do
  [ -e "$f" ] || continue
  N=$((N+1)); cp "$f" "$REG/"
done
wm
eq "W14 rc" "$RC" 0
eq "W14 invalid committed register files ($N read)" "$(cat "$H/logs/staff.log" 2>/dev/null | grep -c 'invalid')" 0

# ═════ W16: no model string; GitHub only through gh_rest ═════════════════════
if [ -r "$COL_SRC" ]; then
  eq "W16 claude- strings" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -c 'claude-')" 0
  eq "W16 gh CLI or curl calls" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -cE '(^|[^a-z_])(gh|curl) ')" 0
  [ -x "$COL_SRC" ] && ok || bad "W16: the collector is not executable (staff.sh runs it only when -x)"
else
  bad "W16: no collector to scan"
fi

[ -e "$T/net.log" ] && bad "a stub let a real curl/gh run: $(cat "$T/net.log")" || ok

echo "staff-watchman.bh-5565: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
