#!/bin/bash
# tests/lane-cpu-rank-load5.bh-7526-test.sh — BH-7526: the hub CPU table that
# bin/lane-cpu-rank.sh posts states the hub load5 target, the before number
# and the after numbers (load5 at the start and the end of the window), with a
# verdict; and the schema fragment seeds those rows plus three one-line
# lane_placement.<lane>.hub_only reasons. Runs the script as shipped in a
# scratch harness, with the seams of tests/lane-cpu-rank-token.bh-7406-test.sh.
#
#   L1  load 20.00/23.99, rows 24 + 52.42 + ts: the exact target line, yes
#   L2  start 24.00 (equal is not under): no
#   L3  end 24.01: no.  L4 start 52.42 end 57.69: no
#   L5  loadavg unreadable (NA): unknown
#   L6  no rows: under 24 (code default), Before: not set; posted once
#   L7  target row abc / 0 / -1 / empty: code default 24; row 30: under 30,
#       25.00/25.00 yes; row 24.5 used; before abc not set; _at malformed
#       omitted; a settings outage (setting_get rc 1) uses the defaults
#   L8  the line sits right after the Load line; the marker is last;
#       report.md equals the posted body
#   L9  round trip: the fragment applied to sqlite, exported to the settings
#       stub: the target line shows 24 / 52.42 / the ts and the lane-cpu-rank
#       row's reason cell is the seeded text
#   L10 the fragment: every statement is INSERT OR IGNORE INTO settings; a
#       second apply changes 0 rows; an operator row set first survives
#   L11 lp_placement lane-move stays hub with the fragment's rows present
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/lane-cpu-rank.sh
FRAG="$REPO/worker/jobs/schema.d/202610191634-bh-7526-hub-load5-and-hub-only.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$SCRIPT_REL" bin/lib/lane-placement.sh bin/lib/lane-gate.sh; do
  [ -f "$REPO/$L" ] || continue
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

STATE_DIR="$H/state/lane-cpu-rank"
LOG="$H/logs/lane-cpu-rank.log"
REPORT="$STATE_DIR/report.md"

# ── stubs ────────────────────────────────────────────────────────────────────
GHLIB="$T/ghlib.sh"
cat > "$GHLIB" <<EOF
gh_auth_for() { return 0; }
gh_auth_reset() { :; }
gh_rest_issue_comments() { GH_REST_STATUS=200; GH_REST_REASON=; echo '[]'; }
gh_rest_comment() {
  echo "post \$1 \$2" >> "$T/calls"
  cp "\$3" "$T/body.md"
  GH_REST_STATUS=201; GH_REST_REASON=
  return 0
}
EOF
SAMPLER="$T/sampler.sh"
cat > "$SAMPLER" <<EOF
#!/bin/bash
cat "$T/sample.out"
[ -e "$T/load.after" ] && cp "$T/load.after" "$T/loadavg"
exit 0
EOF
chmod +x "$SAMPLER"
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "alert \$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/lane-alert.sh"
# setting_get over settings.tsv: rc 2 = no row (the client's 404), rc 1 = the
# whole read failed (settings.outage exists).
cat > "$H/bin/jobs-client.sh" <<EOF
_setting_key_ok() { [[ "\$1" =~ ^[A-Za-z0-9._-]+\$ ]]; }
_jobs_req() { return 1; }
setting_get() {
  local v
  [ -e "$T/settings.outage" ] && return 1
  v=\$(awk -F '\t' -v k="\$1" '\$1 == k { print \$2; f = 1 } END { exit f ? 0 : 1 }' "$T/settings.tsv") || return 2
  printf '%s' "\$v"
}
EOF

ROWS_SEEDED=$'lane_cpu_rank.load5_target\t24\nlane_cpu_rank.load5_before\t52.42\nlane_cpu_rank.load5_before_at\t2026-10-17T09:30:45Z'

# reset <load5 start> <load5 end> — fresh state; the sampler stub swaps the
# loadavg file to the end value, so the start and end reads differ.
reset() {
  scratch_rm "$STATE_DIR" 2>/dev/null; mkdir -p "$STATE_DIR"
  : > "$LOG"; : > "$T/settings.tsv"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/settings.outage" "$T/load.after"
  printf '10.00 %s 9.00 3/900 12345\n' "$1" > "$T/loadavg"
  printf '11.00 %s 9.00 3/900 12345\n' "$2" > "$T/load.after"
  printf '50.0\tmerge-conductor\t7200.0\n25.0\tlane-cpu-rank\t3600.0\n25.0\tother\t3600.0\nLCS verdict\n' > "$T/sample.out"
  return 0
}
rows() { printf '%s\n' "$@" >> "$T/settings.tsv"; }
run() {
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo HARNESS_TEST_SANDBOX=1 \
    LANE_CPU_RANK_GH_LIB="$GHLIB" LANE_CPU_RANK_SAMPLER="$SAMPLER" \
    LANE_CPU_RANK_LOADAVG="$T/loadavg" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
tline() { grep '^Hub load5 target:' "$T/body.md" 2>/dev/null; }
verdict() { tline | sed -n 's/.*Target met: \([a-z]*\)\.$/\1/p'; }

# ── L1 the exact line, verdict yes ───────────────────────────────────────────
reset 20.00 23.99; rows "$ROWS_SEEDED"; run
want='Hub load5 target: under 24 (row lane_cpu_rank.load5_target). Before: 52.42 at 2026-10-17T09:30:45Z. After: start 20.00, end 23.99. Target met: yes.'
[ "$RC" = 0 ] && ok "L1 exit 0" || bad "L1 exit $RC: $(head -5 "$T/run.out")"
[ "$(tline)" = "$want" ] && ok "L1 the exact target line" || bad "L1 line: [$(tline)]"
[ "$(grep -c '^Hub load5 target:' "$T/body.md" 2>/dev/null)" = 1 ] && ok "L1 one target line" || bad "L1 target lines: $(grep -c '^Hub load5 target:' "$T/body.md" 2>/dev/null)"
grep -q '|' <<<"$(tline)" && bad "L1 the line holds a pipe" || ok "L1 no pipe in the line"
reset 23.99 20.00; rows "$ROWS_SEEDED"; run
[ "$(verdict)" = yes ] && ok "L1 23.99/20.00: yes" || bad "L1 23.99/20.00: [$(tline)]"

# ── L2-L4 not under the target ───────────────────────────────────────────────
reset 24.00 20.00; rows "$ROWS_SEEDED"; run
[ "$(verdict)" = no ] && ok "L2 start 24.00 (equal): no" || bad "L2: [$(tline)]"
reset 20.00 24.01; rows "$ROWS_SEEDED"; run
[ "$(verdict)" = no ] && ok "L3 end 24.01: no" || bad "L3: [$(tline)]"
reset 52.42 57.69; rows "$ROWS_SEEDED"; run
[ "$(verdict)" = no ] && tline | grep -q 'After: start 52.42, end 57.69\.' && ok "L4 52.42/57.69: no" || bad "L4: [$(tline)]"

# ── L5 a load read is NA ─────────────────────────────────────────────────────
reset 20.00 20.00; rows "$ROWS_SEEDED"; printf 'garbage\n' > "$T/load.after"; run
[ "$(verdict)" = unknown ] && tline | grep -q 'end NA\.' && ok "L5 end NA: unknown" || bad "L5 end NA: [$(tline)]"
reset 20.00 20.00; rows "$ROWS_SEEDED"; printf 'garbage\n' > "$T/loadavg"; run
[ "$(verdict)" = unknown ] && ok "L5 start NA: unknown" || bad "L5 start NA: [$(tline)]"

# ── L6 no rows at all ────────────────────────────────────────────────────────
reset 20.00 20.00; run
[ "$(tline)" = 'Hub load5 target: under 24 (code default). Before: not set. After: start 20.00, end 20.00. Target met: yes.' ] \
  && ok "L6 code default 24, Before: not set" || bad "L6 line: [$(tline)]"
[ "$(grep -c '^post' "$T/calls" 2>/dev/null)" = 1 ] && grep -q '^posted ' "$STATE_DIR/state-7252" 2>/dev/null \
  && ok "L6 posted once, state posted" || bad "L6 calls $(cat "$T/calls" 2>/dev/null) state $(cat "$STATE_DIR/state-7252" 2>/dev/null)"

# ── L7 row parsing ───────────────────────────────────────────────────────────
for v in abc 0 -1 '' 0.00 12345; do
  reset 20.00 20.00; rows "lane_cpu_rank.load5_target	$v"; run
  tline | grep -q '^Hub load5 target: under 24 (code default)\. ' && ok "L7 target row [$v]: code default" || bad "L7 target [$v]: [$(tline)]"
done
reset 25.00 25.00; rows "lane_cpu_rank.load5_target	30"; run
tline | grep -q '^Hub load5 target: under 30 (row lane_cpu_rank.load5_target)\. ' && [ "$(verdict)" = yes ] \
  && ok "L7 row 30: under 30, 25/25 yes" || bad "L7 row 30: [$(tline)]"
reset 24.40 24.49; rows "lane_cpu_rank.load5_target	24.5"; run
tline | grep -q '^Hub load5 target: under 24.5 (row ' && [ "$(verdict)" = yes ] && ok "L7 row 24.5 used" || bad "L7 row 24.5: [$(tline)]"
reset 20.00 20.00; rows "lane_cpu_rank.load5_before	abc" "lane_cpu_rank.load5_before_at	2026-10-17T09:30:45Z"; run
tline | grep -q ' Before: not set\. ' && ok "L7 before abc: not set" || bad "L7 before abc: [$(tline)]"
reset 20.00 20.00; rows "lane_cpu_rank.load5_before	52.42" "lane_cpu_rank.load5_before_at	yesterday"; run
tline | grep -q ' Before: 52.42\. After:' && ok "L7 _at malformed: omitted" || bad "L7 _at malformed: [$(tline)]"
reset 20.00 20.00; rows "$ROWS_SEEDED"; touch "$T/settings.outage"; run
tline | grep -q '^Hub load5 target: under 24 (code default)\. Before: not set\. ' && grep -q '^posted ' "$STATE_DIR/state-7252" 2>/dev/null \
  && ok "L7 settings outage: defaults, still posted" || bad "L7 outage: [$(tline)]"

# ── L8 placement in the body ─────────────────────────────────────────────────
reset 20.00 23.99; rows "$ROWS_SEEDED"; run
n=$(grep -n '^Load (load1/load5): ' "$T/body.md" 2>/dev/null | cut -d: -f1)
m=$(grep -n '^Hub load5 target: ' "$T/body.md" 2>/dev/null | cut -d: -f1)
[ -n "$n" ] && [ -n "$m" ] && [ "$m" = $((n + 1)) ] && ok "L8 the line follows the Load line" || bad "L8 Load line $n, target line $m"
grep -q '^Load (load1/load5): start 10.00/20.00, end 11.00/23.99\.$' "$T/body.md" && ok "L8 the Load line is unchanged" \
  || bad "L8 Load line: $(grep '^Load' "$T/body.md")"
tail -1 "$T/body.md" | grep -qxF '<!-- lane-cpu-rank:7252 -->' && ok "L8 the marker is the last line" || bad "L8 last: $(tail -1 "$T/body.md")"
cmp -s "$REPORT" "$T/body.md" && ok "L8 report.md equals the posted body" || bad "L8 report differs"
tail -1 "$LOG" | grep -q 'rank=posted issue=7252(default) rows=2 load5=20.00->23.99$' && ok "L8 the log line is unchanged" \
  || bad "L8 log: $(tail -1 "$LOG")"

# ── L9-L11 the fragment ──────────────────────────────────────────────────────
# sql <db> <statements...> — the sqlite3 CLI, or python3's sqlite3 module.
# Prints the rows of the last statement.
sql() {
  local db="$1"; shift
  if command -v sqlite3 >/dev/null 2>&1; then printf '%s\n' "$@" | sqlite3 "$db"
  else printf '%s\n' "$@" | python3 -I -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); s = sys.stdin.read()
parts = [p for p in s.split(";\n") if p.strip()]
for p in parts[:-1]: c.executescript(p + ";")
for r in c.execute(parts[-1]): print("|".join(map(str, r)))
c.commit()' "$db"; fi
}
REASON_CPU='samples the hub'"'"'s own /proc; on another machine it measures that machine'
if [ ! -f "$FRAG" ]; then
  bad "L9 fragment missing: ${FRAG#"$REPO"/}"
elif ! command -v sqlite3 >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP L9-L11 sqlite apply: sqlite3 and python3 missing"
else
  DDL='CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT);'
  EXPORT="SELECT key || char(9) || value FROM settings ORDER BY key;"
  rm -f "$T/l9.db" "$T/l10.db"
  sql "$T/l9.db" "$DDL" "$(cat "$FRAG")" "SELECT 1;" >/dev/null
  # L9 round trip
  reset 20.00 23.99; sql "$T/l9.db" "$EXPORT" > "$T/settings.tsv"; run
  tline | grep -q '^Hub load5 target: under 24 (row lane_cpu_rank.load5_target)\. Before: 52.42 at 2026-10-17T09:30:45Z\. ' \
    && ok "L9 seeded rows: 24 / 52.42 / the ts" || bad "L9 line: [$(tline)]"
  grep -qF "| 2 | lane-cpu-rank | 3600.0 | 25.0 | hub | $REASON_CPU |" "$T/body.md" \
    && ok "L9 the lane-cpu-rank reason cell is the seeded text" || bad "L9 row: $(grep 'lane-cpu-rank |' "$T/body.md")"
  for l in lane-cpu-rank lane-move lane-snapshot-publish; do
    v=$(awk -F '\t' -v k="lane_placement.$l.hub_only" '$1 == k { print $2 }' "$T/settings.tsv")
    [ -n "$v" ] && [ "${#v}" -le 120 ] && ok "L9 $l hub_only reason, ${#v} chars" || bad "L9 $l reason [$v]"
  done
  # L10 additive, idempotent, keeps an operator value
  stm=$(grep -v '^--' "$FRAG" | grep -ciE '^[[:space:]]*(insert|update|delete|create|drop|alter|replace)')
  ins=$(grep -c '^INSERT OR IGNORE INTO settings ' "$FRAG")
  [ "$stm" -ge 1 ] && [ "$stm" = "$ins" ] && ok "L10 every statement is INSERT OR IGNORE INTO settings ($ins)" || bad "L10 statements $stm, insert-or-ignore $ins"
  before=$(sql "$T/l9.db" "SELECT count(*) || ':' || total_changes() FROM settings;")
  after=$(sql "$T/l9.db" "$(cat "$FRAG")" "SELECT count(*) || ':' || total_changes() FROM settings;")
  [ "${before%%:*}" = 6 ] && [ "$after" = "6:0" ] && ok "L10 6 rows; a second apply changes 0 rows" || bad "L10 before $before after $after"
  [ "$(sql "$T/l10.db" "$DDL" "INSERT INTO settings VALUES ('lane_cpu_rank.load5_target','30','op','operator','x');" "$(cat "$FRAG")" \
        "SELECT value || ':' || actor FROM settings WHERE key='lane_cpu_rank.load5_target';")" = "30:operator" ] \
    && ok "L10 an operator value 30 (actor operator) stays" || bad "L10 operator value overwritten"
  # L11 no placement change
  got=$( cd "$T" && HARNESS="$H" bash -c '. "$1/bin/jobs-client.sh"; . "$1/bin/lib/lane-placement.sh"; for l in lane-move lane-cpu-rank lane-snapshot-publish; do lp_decide "$l"; printf "%s=%s;" "$l" "$LP_PLACE"; done' _ "$H" )
  [ "$got" = "lane-move=hub;lane-cpu-rank=hub;lane-snapshot-publish=hub;" ] && ok "L11 the 3 lanes stay hub" || bad "L11 placement: $got"
fi

echo "lane-cpu-rank-load5: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
