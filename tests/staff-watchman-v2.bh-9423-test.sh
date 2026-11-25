#!/bin/bash
# tests/staff-watchman-v2.bh-9423-test.sh — BH-9423 (watchman v2): the path
# allowlist (bin/lib/watchman-allow.sh), the collector that uses it
# (bin/staff/watchman-collect.sh), the rotation checklist in the soul
# (prompts/staff/watchman-soul.md) and the metric lane
# (bin/staff/watchman-metric.sh, live_unrotated_secrets).
#
#   A1  each allowlisted path -> rc 0 and `path`
#   A2  each near miss -> rc 1
#   A3  WM_PATH_ALLOWLIST: e2e/ only; empty = the default list; a bad pattern
#       is dropped with one warn line
#   A4  the DUMMY VALUES header: line 3 lowercase; line 6 with 5 and with 6;
#       a gone commit; a missing repo; WM_DUMMY_LINES out of range
#   V1  3 fixture hits + 1 .env.vercel hit: cache 4, the beat names only
#       .env.vercel, 1 history-secret line
#   V2  only allowlisted hits: 0 beats, 0 lines, cache 3
#   V3  a near miss (contests/key.js) prints and beats
#   V4  a first scan of 150 locations, 140 allowlisted, max 100: no baseline,
#       10 lines; an existing baseline whose filtered count is 10 prints 10
#       lines and not its item; one over the max keeps its item
#   V5  a secret value in a fixture file (path and DUMMY) reaches no output
#   V6  a tick with no new commit runs no gitleaks; one new commit is read
#       with --not <old tip>
#   R1  the soul parses, the six checklist lines are present, and the
#       MAY/NEVER/REPORT lists equal those of the soul without the section
#   M1  seeded state -> one sample, value 3, history=2 rotation=1 allowlisted=3
#   M2  the REAL collector writes the cache, the lane reads it
#   M3  findings read fails / not a list / truncated -> no sample, unreadable
#   M4  register edges (the collector's rotation-due rule), and parity with
#       the collector's own rotation-due lines
#   M5  the sample POST fails -> sample=failed, rc 0
#   M6  no lever action and no GitHub call, whatever staff.watchman.level says
#   M7  kill flags, STAFF_ENABLED=0, the lane-off flag, an inactive roster
#       and a held lock
#
# gitleaks is a WM_GITLEAKS stub (as in tests/staff-watchman.bh-5565-test.sh).
# The jobs client is stubbed through WM_FIXTURE and WM_METRIC_FIXTURE: 0
# network calls (curl and gh are stubs that log and fail).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-watchman-v2.bh-9423-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-watchman-v2: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "staff-watchman-v2: git is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-watchman-v2: node is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

LIB_SRC="$DIR/bin/lib/watchman-allow.sh"
COL_REL=bin/staff/watchman-collect.sh
MET_REL=bin/staff/watchman-metric.sh
for f in "$LIB_SRC" "$DIR/$COL_REL" "$DIR/$MET_REL" "$DIR/catalog/lanes.d/staff-watchman-metric.json" \
         "$DIR/cron/lanes/782-staff-watchman-metric.cron" "$DIR/prompts/staff/watchman-soul.md"; do
  [ -s "$f" ] && ok || bad "missing source ${f#"$DIR"/}"
done

# 2026-10-15T12:00:00Z and its midnight, pinned (D60).
NOW=1792065600
MID=1792022400
DAY=86400; HR=3600
day() { date -u -d "@$1" +%Y-%m-%d; }
# The fixture secret: built here, never a committed literal (D47: it says fixture).
LEAKV="AKIA$(printf '%s' FIXTURE)WMQZXJKLB"

# ═════ A1-A4: the allowlist lib ══════════════════════════════════════════════
LR="$T/librepo"
git init -q "$LR" && git -C "$LR" config user.email fx@example.com && git -C "$LR" config user.name fx
mkdir -p "$LR/cfg"
printf 'A=1\nB=2\n# dummy values only\nC=3\n' > "$LR/.env.example"
printf '1\n2\n3\n4\n5\n# DUMMY VALUES\n' > "$LR/cfg/six.env"
printf 'AWS_ACCESS_KEY_ID=%s\n' "$LEAKV" > "$LR/.env.vercel"
GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z git -C "$LR" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE=2026-09-01T00:00:00Z GIT_COMMITTER_DATE=2026-09-01T00:00:00Z git -C "$LR" commit -qm first >/dev/null 2>&1
LC=$(git -C "$LR" rev-parse HEAD)
GONE=0123456789abcdef0123456789abcdef01234567

# allow [VAR=value ...] -- <repo> <commit> <file>: wm_allowed in a fresh shell.
# Out: $T/a.out (stdout), $T/a.err (stderr), ARC.
allow() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u WM_PATH_ALLOWLIST -u WM_DUMMY_LINES "${envs[@]}" bash -c '. "$1" || exit 9; wm_allow_load || exit 8; wm_allowed "$2" "$3" "$4"' _ \
    "$LIB_SRC" "$@" > "$T/a.out" 2> "$T/a.err"
  ARC=$?
}
for f in tests/a.env pkg/tests/x.js src/__tests__/k.ts e2e/login.spec.ts test/fixtures/keys.json \
         .harness/specs/BH-1/plan.md README.md docs/setup.md; do
  allow -- "$LR" "$LC" "$f"
  eq "A1 $f rc" "$ARC" 0
  eq "A1 $f why" "$(cat "$T/a.out")" path
done
for f in contests/key.js tests.js test/key.js README.md.bak fixtures.json .harness/specs .env.vercel mytests/x.js; do
  allow -- "$LR" "$LC" "$f"
  eq "A2 $f rc" "$ARC" 1
  eq "A2 $f stdout" "$(cat "$T/a.out")" ""
done
allow WM_PATH_ALLOWLIST=e2e/ -- "$LR" "$LC" tests/a.env; eq "A3 e2e/ only: tests/a.env" "$ARC" 1
allow WM_PATH_ALLOWLIST=e2e/ -- "$LR" "$LC" e2e/a.env;   eq "A3 e2e/ only: e2e/a.env" "$ARC" 0
allow WM_PATH_ALLOWLIST=e2e/ -- "$LR" "$LC" README.md;   eq "A3 e2e/ only: README.md" "$ARC" 1
allow WM_PATH_ALLOWLIST=.env.vercel -- "$LR" "$LC" .env.vercel; eq "A3 an exact path" "$ARC" 0
allow WM_PATH_ALLOWLIST=.env.vercel -- "$LR" "$LC" x/.env.vercel; eq "A3 an exact path is not a suffix" "$ARC" 1
allow WM_PATH_ALLOWLIST= -- "$LR" "$LC" tests/a.env;     eq "A3 empty = the default list" "$ARC" 0
allow 'WM_PATH_ALLOWLIST= , ' -- "$LR" "$LC" __tests__/a; eq "A3 blank patterns = the default list" "$ARC" 0
allow 'WM_PATH_ALLOWLIST=tests/,$(rm)' -- "$LR" "$LC" tests/a.env
eq "A3 bad pattern dropped, tests/ kept" "$ARC" 0
eq "A3 one warn line" "$(grep -c 'warn: WM_PATH_ALLOWLIST pattern' "$T/a.err")" 1
allow 'WM_PATH_ALLOWLIST=tests/,$(rm)' -- "$LR" "$LC" e2e/a.env
eq "A3 bad pattern: the default list is not added back" "$ARC" 1
allow 'WM_PATH_ALLOWLIST=$(rm)' -- "$LR" "$LC" fixtures/a
eq "A3 no valid pattern = the default list" "$ARC" 0
eq "A3 no valid pattern: two warn lines" "$(grep -c 'warn:' "$T/a.err")" 2
allow -- "$LR" "$LC" .env.example
eq "A4 line 3 lowercase rc" "$ARC" 0
eq "A4 line 3 lowercase why" "$(cat "$T/a.out")" dummy
allow -- "$LR" "$LC" cfg/six.env;                 eq "A4 line 6 with the default 5" "$ARC" 1
allow WM_DUMMY_LINES=6 -- "$LR" "$LC" cfg/six.env; eq "A4 line 6 with 6" "$ARC" 0
allow -- "$LR" "$GONE" .env.example;              eq "A4 a gone commit" "$ARC" 1
allow -- "$T/no-such-repo" "$LC" .env.example;    eq "A4 a missing repo" "$ARC" 1
allow -- "$LR" "$LC" no/such/file.env;            eq "A4 a file not in the commit" "$ARC" 1
allow -- "$LR" "$LC" .env.vercel;                 eq "A4 a real hit" "$ARC" 1
for v in 0 51 abc; do
  allow "WM_DUMMY_LINES=$v" -- "$LR" "$LC" cfg/six.env
  eq "A4 WM_DUMMY_LINES=$v rc (5 lines)" "$ARC" 1
  eq "A4 WM_DUMMY_LINES=$v warn" "$(grep -c "WM_DUMMY_LINES=$v is outside 1..50" "$T/a.err")" 1
done
grep -qF "$LEAKV" "$T/a.out" "$T/a.err" && bad "A4: the file content reached the output" || ok

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; REPOS="$T/repos"
mkdir -p "$H" "$FXT" "$REPOS" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
scratch_install_closure "$COL_REL" "$H" >/dev/null || bad "scratch_install_closure $COL_REL failed"
scratch_install_closure "$MET_REL" "$H" >/dev/null || bad "scratch_install_closure $MET_REL failed"
[ -f "$H/bin/lib/watchman-allow.sh" ] && ok || bad "the closure of the collector does not hold bin/lib/watchman-allow.sh"
COL="$H/$COL_REL"; MET="$H/$MET_REL"
cp -r "$DIR/agent-core" "$H/agent-core"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.log"\nexit 0\n' "$FXT" > "$T/lane-alert.stub"
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
r="$FXT/report/$(basename "$repo").json"
if [ -n "$out" ]; then if [ -f "$r" ]; then cp "$r" "$out"; else echo '[]' > "$out"; fi; fi
exit 0
SH
chmod +x "$T/gitleaks"
# The collector's fixture: no request is expected (BH-5565 W4); log any.
cat > "$T/wmfx.sh" <<'SH'
_jobs_req() { printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"; return 1; }
_jobs_req_file() { printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"; return 1; }
gh_rest() { printf 'gh_rest %s %s\n' "$1" "$2" >> "$FXT/wm-gh.log"; return 1; }
SH
# The lane's fixture: the roster, the findings list, the sample POST, flags.
cat > "$T/metfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=watchman")
      cat "$FXT/agent.json" 2>/dev/null || echo '{"agent":{"name":"watchman","status":"active"}}'; return 0 ;;
    "GET /api/staff/findings?agent=watchman")
      [ -f "$FXT/findings.fail" ] && return 1
      cat "$FXT/findings.json" 2>/dev/null || echo '{"agent":"watchman","findings":[],"truncated":false}'
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "POST /api/staff/levers/metric")
      jq -c . "$3" >> "$FXT/samples.jsonl"
      [ -f "$FXT/sample.fail" ] && return 1
      printf '{"ok":true,"settled":0}'; return 0 ;;
  esac
  return 1
}
flag_active() { printf '%s\n' "$1" >> "$FXT/flags.log"; [ -f "$FXT/flags/$1" ]; }
setting_get() { printf 'setting %s\n' "$1" >> "$FXT/req.log"; [ "$1" = staff.watchman.level ] && [ -f "$FXT/level" ] && { cat "$FXT/level"; return 0; }; return 1; }
SH

gitc() { GIT_AUTHOR_DATE="2026-09-01T00:00:00Z" GIT_COMMITTER_DATE="2026-09-01T00:00:00Z" git -C "$1" "${@:2}" >/dev/null 2>&1; }
# mkrepo <project> <file>=<content> ...: one commit with those files.
mkrepo() {
  local r="$REPOS/$1" kv; shift
  git init -q "$r" && git -C "$r" config user.email fx@example.com && git -C "$r" config user.name fx
  echo clean > "$r/README"
  for kv in "$@"; do mkdir -p "$r/$(dirname "${kv%%=*}")"; printf '%b\n' "${kv#*=}" > "$r/${kv%%=*}"; done
  gitc "$r" add -A && gitc "$r" commit -qm "first"
}
tip() { git -C "$REPOS/$1" rev-parse HEAD; }
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
  for d in "$H/state" "$H/logs" "$H/catalog" "$H/locks" "$FXT" "$REPOS"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/flags" "$REPOS" "$H/bin"
  : > "$FXT/beats.log"; : > "$FXT/gl.log"; : > "$FXT/wm-req.log"; : > "$FXT/wm-gh.log"; : > "$FXT/req.log"; : > "$FXT/flags.log"
  rm -f "$T/net.log"
  cp "$T/lane-alert.stub" "$H/bin/lane-alert.sh"
  cp "$T/fleet-conf.stub" "$H/bin/fleet-conf.sh"
}
wm() {
  env HARNESS="$H" FXT="$FXT" WM_FIXTURE="$T/wmfx.sh" HARNESS_TEST_SANDBOX=1 WM_NOW="${WNOW:-$NOW}" \
    WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$REPOS" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" "$@" bash "$COL" > "$T/out" 2> "$T/err"
  RC=$?
}
met() {
  env HARNESS="$H" FXT="$FXT" WM_METRIC_FIXTURE="$T/metfx.sh" HARNESS_TEST_SANDBOX=1 WM_METRIC_NOW="${WNOW:-$NOW}" \
    WM_REPOS_ROOT="$REPOS" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= JOBS_ALERT=0 \
    PATH="$T/fakebin:$PATH" "$@" bash "$MET" > "$T/mout" 2> "$T/merr"
  RC=$?
}
beats() { lines "$FXT/beats.log"; }
glruns() { lines "$FXT/gl.log"; }
mlog() { tail -1 "$H/logs/staff-watchman-metric.log" 2>/dev/null; }
samples() { lines "$FXT/samples.jsonl"; }
WMS="$H/state/staff/watchman"
no_secret() {
  local hits
  hits=$(grep -rlF "$LEAKV" "$T/out" "$T/err" "$T/mout" "$T/merr" "$H/logs" "$H/state" "$FXT/beats.log" "$FXT/samples.jsonl" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "$1: the secret value is in: $hits"
}
fpof() {
  node --input-type=module -e "import { fingerprint } from '$DIR/agent-core/src/index.js'; console.log(fingerprint(JSON.parse(process.argv[1])));" "$1"
}

# ═════ V1: 3 fixture hits and one real hit ═══════════════════════════════════
v1() {
  reset; fleet project-3
  mkrepo project-3 "tests/a.env=K=$LEAKV" "fixtures/k.json=$LEAKV" "docs/setup.md=K=$LEAKV" ".env.vercel=K=$LEAKV"
  C1=$(tip project-3)
  report project-3 "[$(leakrow "$C1" tests/a.env 1),$(leakrow "$C1" fixtures/k.json 1),$(leakrow "$C1" docs/setup.md 1),$(leakrow "$C1" .env.vercel 1)]"
}
v1; wm
eq "V1 rc" "$RC" 0
eq "V1 cache rows" "$(lines "$WMS/leaks/project-3.jsonl")" 4
eq "V1 lines" "$(lines "$T/out")" 1
eq "V1 the line" "$(jq -r '"\(.class) \(.item.file)"' "$T/out" 2>/dev/null)" "history-secret .env.vercel"
eq "V1 beats" "$(beats)" 1
eq "V1 beat argv" "$(cat "$FXT/beats.log")" \
  "--id staff-watchman-leak-project-3-$NOW --severity critical staff Critical: secret in git history: aws-access-token in project-3 .env.vercel:1 (commit ${C1:0:12})"
eq "V1 allowlist log" "$(grep -c 'allowlist skipped=3 path=3 dummy=0' "$H/logs/staff.log" 2>/dev/null)" 1
eq "V1 beat log" "$(grep -c 'beat project-3 severity critical new=1' "$H/logs/staff.log" 2>/dev/null)" 1
eq "V1 no request" "$(lines "$FXT/wm-req.log")" 0
no_secret V1
# The next tick: still one line, no beat; a changed allowlist takes effect with no rescan.
WNOW=$((NOW + HR)) wm
eq "V1 next tick lines" "$(lines "$T/out")" 1
eq "V1 next tick beats" "$(beats)" 1
WNOW=$((NOW + HR)) wm WM_PATH_ALLOWLIST=e2e/
eq "V1 allowlist e2e/ only: lines with no rescan" "$(lines "$T/out")" 4
eq "V1 allowlist e2e/ only: gitleaks runs" "$(glruns)" 1

# ═════ V2: only allowlisted hits ═════════════════════════════════════════════
reset; fleet p2
mkrepo p2 "tests/a.env=K=$LEAKV" "e2e/b.ts=$LEAKV" ".env.example=A=1\n# DUMMY VALUES ONLY\nK=$LEAKV"
C2=$(tip p2)
report p2 "[$(leakrow "$C2" tests/a.env 1),$(leakrow "$C2" e2e/b.ts 1),$(leakrow "$C2" .env.example 3)]"
wm
eq "V2 rc" "$RC" 0
eq "V2 lines" "$(lines "$T/out")" 0
eq "V2 beats" "$(beats)" 0
eq "V2 cache rows" "$(lines "$WMS/leaks/p2.jsonl")" 3
eq "V2 allowlist log" "$(grep -c 'allowlist skipped=3 path=2 dummy=1' "$H/logs/staff.log" 2>/dev/null)" 1
eq "V2 all allowlisted log" "$(grep -c 'scan p2: 3 new locations, all allowlisted; no beat' "$H/logs/staff.log" 2>/dev/null)" 1
no_secret V2

# ═════ V3: a near miss prints and beats ══════════════════════════════════════
reset; fleet p3; mkrepo p3 "contests/key.js=K=$LEAKV"; C3=$(tip p3)
report p3 "[$(leakrow "$C3" contests/key.js 1)]"
wm
eq "V3 lines" "$(lines "$T/out")" 1
eq "V3 file" "$(jq -r .item.file "$T/out" 2>/dev/null)" contests/key.js
eq "V3 beats" "$(beats)" 1

# ═════ V4: the first-scan baseline counts only non-allowlisted locations ═════
v4() {
  reset; fleet p4; mkrepo p4 "tests/x.js=$LEAKV" ".env=K=$LEAKV"; C4=$(tip p4)
  { for i in $(seq 1 "$1"); do leakrow "$C4" tests/x.js "$i"; done
    for i in $(seq 1 "$2"); do leakrow "$C4" .env "$i"; done; } | jq -cs . > "$T/v4.json"
  report p4 "$(cat "$T/v4.json")"
}
v4 140 10; wm WM_FIRST_SCAN_MAX=100
eq "V4 rc" "$RC" 0
[ -e "$WMS/base/p4.item" ] && bad "V4: a baseline item for 10 non-allowlisted locations" || ok
eq "V4 lines" "$(lines "$T/out")" 10
eq "V4 classes" "$(jq -r .class "$T/out" | sort -u)" history-secret
eq "V4 files" "$(jq -r .item.file "$T/out" | sort -u)" .env
eq "V4 cache rows" "$(lines "$WMS/leaks/p4.jsonl")" 150
eq "V4 one beat, +9" "$(grep -c -- '(+9 more)$' "$FXT/beats.log")" 1
# Over the max after the filter: a baseline, its item names the filtered count.
v4 140 101; wm WM_FIRST_SCAN_MAX=100
eq "V4 101 hits: one line" "$(lines "$T/out")" 1
eq "V4 101 hits: the baseline" "$(jq -r '"\(.class) \(.item.locations)"' "$T/out" 2>/dev/null)" "history-baseline 101"
eq "V4 101 hits: base rows (all)" "$(lines "$WMS/base/p4.jsonl")" 241
eq "V4 101 hits: one beat" "$(beats)" 1
# A baseline written before v2 (150 locations, 140 allowlisted): 10 lines, no item.
v4 140 10
jq -c '.[] | {check: "history-secret", project: "p4", commit: .Commit, file: .File, line: .StartLine, rule: .RuleID}' "$T/v4.json" \
  | LC_ALL=C sort -u > "$T/v4.base"
mkdir -p "$WMS/base" "$WMS/scan"
cp "$T/v4.base" "$WMS/base/p4.jsonl"
jq -cn --argjson at "$NOW" '{item: {check: "history-baseline", project: "p4", locations: 150, at: $at}, title: "Critical: 150", source: {kind: "staff-security", url: "u", labels: []}, observedAt: "x", class: "history-baseline"}' > "$WMS/base/p4.item"
echo "$NOW" > "$WMS/scan/p4.based"; echo "$NOW" > "$WMS/scan/p4.at"; tip p4 > "$WMS/scan/p4.tips"
wm WM_FIRST_SCAN_MAX=100
eq "V4 old baseline: gitleaks runs" "$(glruns)" 0
eq "V4 old baseline: lines" "$(lines "$T/out")" 10
eq "V4 old baseline: no item" "$(grep -c history-baseline "$T/out")" 0
eq "V4 old baseline: files" "$(jq -r .item.file "$T/out" | sort -u)" .env
eq "V4 old baseline: allowlist log" "$(grep -c 'allowlist skipped=140 path=140 dummy=0' "$H/logs/staff.log" 2>/dev/null)" 1
wm WM_FIRST_SCAN_MAX=9
eq "V4 old baseline over the max: the item only" "$(jq -r .class "$T/out" | paste -sd' ')" history-baseline

# ═════ V5: a secret value in a fixture file reaches nothing ══════════════════
reset; fleet p5
mkrepo p5 "tests/a.env=K=$LEAKV" "cfg/demo.env=# DUMMY VALUES\nK=$LEAKV" "src/real.js=K=$LEAKV"; C5=$(tip p5)
report p5 "[$(leakrow "$C5" tests/a.env 1),$(leakrow "$C5" cfg/demo.env 2),$(leakrow "$C5" src/real.js 1)]"
wm
eq "V5 lines" "$(lines "$T/out")" 1
eq "V5 allowlist log" "$(grep -c 'allowlist skipped=2 path=1 dummy=1' "$H/logs/staff.log" 2>/dev/null)" 1
met
no_secret V5

# ═════ V6: scan only new commits (the BH-5565 cursor) ════════════════════════
reset; fleet p6; mkrepo p6 ".env=K=$LEAKV"; C6=$(tip p6)
report p6 "[$(leakrow "$C6" .env 1)]"
wm
eq "V6 first scan runs" "$(glruns)" 1
WNOW=$((NOW + 25 * HR)) wm
eq "V6 no new commit: no gitleaks run" "$(glruns)" 1
eq "V6 no new commit: no new beat" "$(beats)" 1
echo n > "$REPOS/p6/n"; gitc "$REPOS/p6" add -A; gitc "$REPOS/p6" commit -qm next
report p6 '[]'
WNOW=$((NOW + 50 * HR)) wm
eq "V6 one new commit: one run" "$(glruns)" 2
grep -q -- "--log-opts --all --not $C6" <(sed -n 2p "$FXT/gl.log") && ok || bad "V6: the run is not --not <old tip>: $(sed -n 2p "$FXT/gl.log")"

# ═════ R1: the rotation checklist in the soul ════════════════════════════════
SOUL="$DIR/prompts/staff/watchman-soul.md"
node "$DIR/bin/staff-core.mjs" soul "$SOUL" > "$T/soul.json"
eq "R1 parses" "$(jq -r '.ok' "$T/soul.json")" true
eq "R1 NEVER count" "$(jq -r '.never | length' "$T/soul.json")" 9
for l in '- [ ] Rotate the credential at its vendor.' \
         '- [ ] Put the new value in every place that uses it (Vercel prod and preview, /etc/harness/env, CI secrets).' \
         '- [ ] Revoke the old value.' \
         '- [ ] Prove that the old value fails (name the probe).' \
         '- [ ] Add or update `catalog/staff-rotations.d/<id>.json` with `rotated_at`.' \
         '- [ ] Close this issue as completed. That closes the finding.'; do
  eq "R1 checklist line: ${l:6:30}" "$(grep -cxF -- "$l" "$SOUL")" 1
done
grep -q '^## When I file a ticket for a secret in git history or a credential past its rotation date$' "$SOUL" && ok || bad "R1: no checklist section"
sed '/^## When I file a ticket for a secret/,$d' "$SOUL" > "$T/soul-base.md"
node "$DIR/bin/staff-core.mjs" soul "$T/soul-base.md" > "$T/soul-base.json"
eq "R1 the lists are unchanged by the section" "$(jq -c '[.may, .never, .report]' "$T/soul.json")" "$(jq -c '[.may, .never, .report]' "$T/soul-base.json")"
eq "R1 no label line in the section" "$(sed -n '/^## When I file a ticket for a secret/,$p' "$SOUL" | grep -cE '^(MAY|NEVER|REPORT)')" 0

# ═════ M1: seeded state -> one sample ════════════════════════════════════════
loc() { jq -cn --arg p "$1" --arg c "$2" --arg f "$3" --argjson l "$4" '{check: "history-secret", project: $p, commit: $c, file: $f, line: $l, rule: "aws-access-token"}'; }
key() { printf '%s' "$1" | sha256sum | cut -c1-64; }
reg() {
  mkdir -p "$H/catalog/staff-rotations.d"
  jq -n --arg id "$1" --arg d "$2" '{id: $id, where: "env file global.env, variable FX_CRED", owner: "ops@example.com", due: $d}' > "$H/catalog/staff-rotations.d/$1.json"
}
reset; fleet m1; mkrepo m1 ".env.vercel=K=$LEAKV"; CM=$(tip m1)
L_OPEN=$(loc m1 "$CM" .env.vercel 1); L_NEW=$(loc m1 "$CM" src/k.js 1); L_CLOSED=$(loc m1 "$CM" config/x.js 1)
L_OFF=$(loc m1 "$CM" config/y.js 1)
A_1=$(loc m1 "$CM" tests/a.env 1); A_2=$(loc m1 "$CM" fixtures/b.json 1); A_3=$(loc m1 "$CM" README.md 1)
mkdir -p "$WMS/leaks" "$WMS/base"
printf '%s\n' "$L_OPEN" "$L_CLOSED" "$A_1" "$A_2" | LC_ALL=C sort -u > "$WMS/leaks/m1.jsonl"
printf '%s\n' "$L_NEW" "$A_3" "$L_OFF" | LC_ALL=C sort -u > "$WMS/base/m1.jsonl"
printf '%s\t%s\n' "$(key "$L_OPEN")" "$NOW" "$(key "$L_CLOSED")" "$NOW" "$(key "$L_OFF")" "$NOW" "$(key "$A_1")" "$NOW" "$(key "$L_NEW")" 0 > "$WMS/printed.tsv"
jq -n --arg o "$(fpof "$L_OPEN")" --arg a "$(fpof "$A_1")" --arg f "$(fpof "$L_OFF")" \
  '{agent: "watchman", truncated: false, findings: [{fingerprint: $o, status: "filed"}, {fingerprint: $a, status: "claimed"}, {fingerprint: $f, status: "filed", state: "off"}]}' > "$FXT/findings.json"
reg m1-past "$(day $((NOW - 10 * DAY)))"; reg m1-later "$(day $((NOW + 10 * DAY)))"
met
eq "M1 rc" "$RC" 0
eq "M1 one sample" "$(samples)" 1
eq "M1 sample agent+metric" "$(jq -r '"\(.agent) \(.metric)"' "$FXT/samples.jsonl" 2>/dev/null)" "watchman live_unrotated_secrets"
eq "M1 sample value" "$(jq -r '.value | tostring + " " + type' "$FXT/samples.jsonl" 2>/dev/null)" "3 number"
eq "M1 sample detail" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=2 rotation=1 allowlisted=3"
grep -q ' live_unrotated_secrets=3 history=2 rotation=1 allowlisted=3 sample=ok$' <<<"$(mlog)" && ok || bad "M1 log: $(mlog)"
eq "M1 findings read once" "$(grep -c '^GET /api/staff/findings?agent=watchman$' "$FXT/req.log")" 1
eq "M1 no state written" "$(find "$H/state" -newer "$WMS/printed.tsv" -type f | grep -c .)" 0
[ -e "$T/net.log" ] && bad "M1: a network call: $(cat "$T/net.log")" || ok
# The open finding closes (rotated): history 1.
jq '.findings |= map(select(.status != "filed" or .state == "off"))' "$FXT/findings.json" > "$FXT/f2" && mv "$FXT/f2" "$FXT/findings.json"
met
eq "M1 closed -> value 2" "$(jq -r .value "$FXT/samples.jsonl" | tail -1)" 2

# ═════ M2: the real collector writes the cache, the lane reads it ════════════
v1; wm
met
eq "M2 printed by the tick, no open finding: closed" "$(jq -r .value "$FXT/samples.jsonl" 2>/dev/null)" 0
eq "M2 detail" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=0 allowlisted=3"
jq -n --arg f "$(fpof "$(jq -c .item "$T/out")")" '{agent: "watchman", truncated: false, findings: [{fingerprint: $f, status: "filed"}]}' > "$FXT/findings.json"
met
eq "M2 the filed line is live" "$(jq -r .value "$FXT/samples.jsonl" | tail -1)" 1
# A first scan held over the claim window: the 10 not yet printed are live.
reset; fleet p4; mkrepo p4 ".env=K=$LEAKV"; C4=$(tip p4)
report p4 "$(for i in $(seq 1 25); do leakrow "$C4" .env "$i"; done | jq -cs .)"
wm STAFF_MAX_ITEMS=15
met
eq "M2 25 lines, 15 printed, 10 never printed" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=10 rotation=0 allowlisted=0"

# ═════ M3: an unreadable findings list is never 0 ════════════════════════════
for k in fail notlist truncated; do
  reset
  case "$k" in
    fail) : > "$FXT/findings.fail" ;;
    notlist) echo '{"agent":"watchman","findings":{}}' > "$FXT/findings.json" ;;
    truncated) echo '{"agent":"watchman","findings":[],"truncated":true}' > "$FXT/findings.json" ;;
  esac
  met
  eq "M3 $k rc" "$RC" 0
  eq "M3 $k no sample" "$(samples)" 0
  grep -q 'live_unrotated_secrets=unreadable (findings list ' <<<"$(mlog)" && ok || bad "M3 $k log: $(mlog)"
  grep -qE 'live_unrotated_secrets=[0-9]' "$H/logs/staff-watchman-metric.log" && bad "M3 $k: a number was logged" || ok
done

# ═════ M4: the register edges and parity with the collector ══════════════════
while IFS='|' read -r name at due want; do
  [ -n "$name" ] || continue
  reset; reg fx-cred "$due"
  WNOW=$at met
  eq "M4 $name rotation" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=$want allowlisted=0"
  WNOW=$at wm
  eq "M4 $name parity with the collector" "$(grep -c '"class":"rotation-due"' "$T/out")" "$want"
done <<EOF
due 10 days ago|$NOW|$(day $((NOW - 10 * DAY)))|1
due 2 days ago|$NOW|$(day $((NOW - 2 * DAY)))|1
due yesterday, now is noon|$NOW|$(day $((NOW - DAY)))|1
due yesterday, one second before midnight|$((MID - 1))|$(day $((MID - DAY)))|0
due today|$NOW|$(day "$NOW")|0
due tomorrow|$NOW|$(day $((NOW + DAY)))|0
EOF
reset; mkdir -p "$H/catalog/staff-rotations.d"
jq -n --arg d "$(day $((NOW + 30 * DAY)))" '{id: "fx-cred", where: "env file global.env, variable FX_CRED", owner: "o", rotated_at: $d, every_days: 1}' > "$H/catalog/staff-rotations.d/fx-cred.json"
met
eq "M4 future rotated_at" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=0 allowlisted=0"
reset; mkdir -p "$H/catalog/staff-rotations.d"
echo '{"id":"fx-cred","where":"x","owner":"o","due":"2026-02-30"}' > "$H/catalog/staff-rotations.d/fx-cred.json"
reg fx-ok "$(day $((NOW - 10 * DAY)))"
met
eq "M4 invalid file not counted" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=1 allowlisted=0"
eq "M4 invalid file one log line" "$(grep -c 'register fx-cred.json invalid (due); not counted' "$H/logs/staff-watchman-metric.log")" 1
wm
eq "M4 the collector still logs the invalid file" "$(grep -c 'watchman: register fx-cred.json invalid (due); skipped' "$H/logs/staff.log")" 1
eq "M4 the collector still fires the valid one" "$(grep -c '"credential":"fx-ok"' "$T/out")" 1

# ═════ M5: the sample POST fails ═════════════════════════════════════════════
reset; : > "$FXT/sample.fail"; met
eq "M5 rc" "$RC" 0
eq "M5 one POST" "$(samples)" 1
grep -q ' sample=failed$' <<<"$(mlog)" && ok || bad "M5 log: $(mlog)"

# ═════ M6: no action at any level ════════════════════════════════════════════
for lv in observe file act; do
  reset; echo "$lv" > "$FXT/level"; reg fx-cred "$(day $((NOW - 10 * DAY)))"
  met
  eq "M6 $lv rc" "$RC" 0
  eq "M6 $lv requests" "$(paste -sd'|' "$FXT/req.log")" \
    "GET /api/staff/agent?name=watchman|GET /api/staff/findings?agent=watchman|POST /api/staff/levers/metric"
  [ -e "$T/net.log" ] && bad "M6 $lv: a network call" || ok
done

# ═════ M7: the stops ═════════════════════════════════════════════════════════
for k in staff-off-all staff-kill-all staff-off-watchman staff-kill-watchman env; do
  reset
  if [ "$k" = env ]; then met STAFF_ENABLED=0; want="killed by STAFF_ENABLED=0"; else : > "$FXT/flags/$k"; met; want="killed by $k"; fi
  eq "M7 $k rc" "$RC" 0
  eq "M7 $k 0 requests" "$(lines "$FXT/req.log")" 0
  eq "M7 $k 0 samples" "$(samples)" 0
  grep -q " $want\$" <<<"$(mlog)" && ok || bad "M7 $k log: $(mlog)"
done
# The lane-off flag, through the real lane gate (no worker: the file flag).
reset; mkdir -p "$H/flags"; : > "$H/flags/lane-off-staff-watchman-metric"
met LANE_GATE_DISABLE=0
eq "M7 lane-off rc" "$RC" 0
eq "M7 lane-off 0 requests" "$(lines "$FXT/req.log")" 0
eq "M7 lane-off 0 samples" "$(samples)" 0
rm -f "$H/flags/lane-off-staff-watchman-metric"
reset; echo '{"agent":{"name":"watchman","status":"paused"}}' > "$FXT/agent.json"; met
eq "M7 inactive: no findings read" "$(grep -c findings "$FXT/req.log")" 0
eq "M7 inactive: 0 samples" "$(samples)" 0
grep -q 'watchman is not active on the roster' <<<"$(mlog)" && ok || bad "M7 inactive log: $(mlog)"
reset; mkdir -p "$H/locks"
exec 8>"$H/locks/staff-watchman-metric.lock"; flock -n 8 || bad "M7: cannot take the lock"
met
exec 8>&-
eq "M7 lock held: 0 requests" "$(lines "$FXT/req.log")" 0
grep -q 'another watchman-metric run is running' <<<"$(mlog)" && ok || bad "M7 lock log: $(mlog)"
# Bad arguments: rc 2.
env HARNESS="$H" HARNESS_TEST_SANDBOX=1 bash "$MET" --bogus > "$T/mout" 2> "$T/merr"; eq "M7 bad argument rc" "$?" 2

echo "staff-watchman-v2: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
