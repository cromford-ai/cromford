#!/bin/bash
# tests/hub-load-sample.bh-6882-test.sh — BH-6882 (part of #6881): the hub load
# sampler lane, bin/hub-load-sample.sh, run as shipped in a scratch harness.
# `ps`, `vmstat` and `sleep` are stubs on PATH; the clock is HUB_LOAD_NOW.
#
#   A1  attribution: jq under fly-pool.sh counts as fly-pool.sh; a non-harness
#       R process is (<comm>); S-state is not counted; a parent loop ends; the
#       sampler's own ps is not counted; runnable = the fixture R count
#   A2  vmstat: steal and cpu come from the LAST data line, header-indexed
#   A3  no vmstat on PATH, or garbage output: steal=NA cpu=NA, never 0
#   A3b forks_s from the processes delta; NA on a missing file or line
#   A4  retention by the date in the filename, keep_days 14
#   A5  p90 alert: one ALERTS line per UTC hour; insufficient, under, equal
#   A6  tsv field order and the 15-pair cap
#   A7  ledger push: args, detail JSON, push=ok|failed|not-configured|not-loaded
#   A8  knob rows: 3 fires a p90 of 5; abc falls back to 8 (default)
#   A9  flags/lane-off-hub-load-sample: exit 0, nothing written
#   A10 lock held: skipped (running), nothing written
#   A11 ps fails every sample: runnable=NA samples=0/3, line still written
#
# Run from anywhere: tests/hub-load-sample.bh-6882-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/hub-load-sample.sh
FIX="$REPO/tests/fixtures/hub-load"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
[ -s "$REPO/$SCRIPT_REL" ] && ok "source exists: $SCRIPT_REL" || bad "missing source $SCRIPT_REL"
for L in "$SCRIPT_REL" bin/jobs-client.sh bin/lane-alert.sh; do
  [ -f "$REPO/$L" ] || continue
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
# The real client needs its modules beside it (A7 swaps a stub in and back).
[ -r "$H/bin/lib/jobs/settings.sh" ] && [ -r "$H/bin/lib/jobs/jobs.sh" ] \
  && ok "closure installs bin/lib/jobs modules" || bad "closure lacks bin/lib/jobs modules"
cp -p "$H/bin/jobs-client.sh" "$T/jobs-client.real" 2>/dev/null

# ── stubs ────────────────────────────────────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<EOF
#!/bin/bash
[ -e "$T/ps.fail" ] && exit 1
cat "\$(cat "$T/ps.src")"
printf '%5d %5d R    ps              ps -eo pid=,ppid=,stat=,comm=,args=\n' "\$\$" "\$PPID"
EOF
cat > "$STUB/vmstat" <<EOF
#!/bin/bash
if [ -e "$T/vmstat.garbage" ]; then echo "vmstat: no data"; exit 0; fi
cat "$FIX/vmstat.txt"
EOF
# sleep: the fork window (10 s) bumps the processes counter by 1000.
cat > "$STUB/sleep" <<'EOF'
#!/bin/bash
f="${HUB_LOAD_PROC_STAT:-}"
if [ "${1:-}" = 10 ] && [ -n "$f" ] && [ -w "$f" ]; then
  awk '$1=="processes"{$2=$2+1000} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
fi
exit 0
EOF
chmod +x "$STUB/ps" "$STUB/vmstat" "$STUB/sleep"
# A PATH with every system command except vmstat (A3).
NOVM="$T/novm"; mkdir -p "$NOVM"
for d in /usr/local/bin /usr/bin /bin; do
  for c in "$d"/*; do
    b=${c##*/}; [ "$b" = vmstat ] && continue
    [ -e "$NOVM/$b" ] || ln -s "$c" "$NOVM/$b" 2>/dev/null
  done
done

printf '%s\n' "$FIX/ps-dump.txt" > "$T/ps.src"
NOW=1791000300          # 2026-10-03T04:05:00Z
DAY=2026-10-03
TSV="$H/state/hub-load/$DAY.tsv"
LOG="$H/logs/hub-load-sample.log"

reset() {
  scratch_rm "$H/state/hub-load"
  : > "$LOG"; : > "$H/logs/ALERTS.log"
  rm -f "$T/ps.fail" "$T/vmstat.garbage" "$H/flags/lane-off-hub-load-sample"
  printf '%s\n' "$FIX/ps-dump.txt" > "$T/ps.src"
  cp -p "$T/jobs-client.real" "$H/bin/jobs-client.sh"
  printf 'cpu  1 2 3 4\nprocesses 500000\nprocs_running 3\n' > "$T/stat"
}
# run <now> [PATH] — the lane as cron runs it, with the test seams pinned.
run() {
  local now="$1" p="${2:-$STUB:$PATH}"
  env PATH="$p" HARNESS="$H" HUB_LOAD_NOW="$now" HUB_LOAD_SAMPLES=3 HUB_LOAD_INTERVAL_S=0 \
    HUB_LOAD_FORK_WINDOW_S=10 HUB_LOAD_PROC_STAT="$T/stat" BOX_NAME=hub \
    "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
last() { tail -1 "$TSV" 2>/dev/null; }
# field <key> — the value of key=<value> in the last tsv line
field() { last | tr '\t' '\n' | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }
lastlog() { tail -1 "$LOG" 2>/dev/null; }
nalerts() { grep -c 'hub-load-sample' "$H/logs/ALERTS.log" 2>/dev/null; }
# seed <file> <n> <runnable> — n earlier lines in the writer's own format
seed() {
  local i; mkdir -p "$H/state/hub-load"
  for i in $(seq 1 "$2"); do
    printf '2026-10-03T03:%02d:00Z\trunnable=%s\tsteal=10\tforks_s=50.0\tcpu=us:1,sy:1,id:90,wa:0\tsamples=30/30\tx.sh=100.0\n' "$i" "$3" >> "$1"
  done
}
# stub_client <rc> — a jobs client that records the ledger call
stub_client() {
  cat > "$H/bin/jobs-client.sh" <<EOF
_jobs_box_name() { printf hub; }
setting_get() {
  case "\$1" in
    hub_load.max_runnable) [ -n "\${STUB_MAXR:-}" ] && { printf '%s' "\$STUB_MAXR"; return 0; } ;;
    hub_load.keep_days) [ -n "\${STUB_KEEP:-}" ] && { printf '%s' "\$STUB_KEEP"; return 0; } ;;
  esac
  return 2
}
job_ledger_put() { jq -nc '\$ARGS.positional' --args "\$@" > "$T/ledger.json"; return $1; }
EOF
}

# ── A1 attribution ───────────────────────────────────────────────────────────
reset; run "$NOW"
[ "$RC" = 0 ] && ok "A1 exit 0" || bad "A1 exit $RC: $(head -5 "$T/run.out")"
[ "$(field runnable)" = "4.00" ] && ok "A1 runnable=4.00 (4 R per sample)" || bad "A1 runnable=$(field runnable) line: $(last)"
[ "$(field fly-pool.sh)" = "25.0" ] && ok "A1 jq under fly-pool.sh counts as fly-pool.sh" || bad "A1 fly-pool.sh=$(field fly-pool.sh)"
[ "$(field merge-conductor.sh)" = "25.0" ] && ok "A1 own args match: merge-conductor.sh" || bad "A1 merge-conductor.sh=$(field merge-conductor.sh)"
[ "$(field '(kworker/0:1)')" = "25.0" ] && ok "A1 non-harness R is (kworker/0:1)" || bad "A1 kworker=$(field '(kworker/0:1)')"
[ "$(field '(loopy)')" = "25.0" ] && ok "A1 a parent loop ends at (loopy)" || bad "A1 loopy=$(field '(loopy)')"
[ -z "$(field '(jq)')" ] && [ -z "$(field '(sleep)')" ] && [ -z "$(field '(node)')" ] \
  && ok "A1 no (jq), and S-state sleep/node not counted" || bad "A1 extra names: $(last)"
[ -z "$(field '(ps)')" ] && [ -z "$(field hub-load-sample.sh)" ] && ok "A1 the sampler's own ps is not counted" || bad "A1 self counted: $(last)"
[ "$(field samples)" = "3/3" ] && ok "A1 samples=3/3" || bad "A1 samples=$(field samples)"
[ "$(wc -l < "$TSV" 2>/dev/null)" = 1 ] && ok "A1 one tsv line per run" || bad "A1 tsv lines: $(wc -l < "$TSV" 2>/dev/null)"

# ── A2 vmstat ────────────────────────────────────────────────────────────────
[ "$(field steal)" = 57 ] && ok "A2 steal=57 from the last data line" || bad "A2 steal=$(field steal)"
[ "$(field cpu)" = "us:15,sy:8,id:18,wa:2" ] && ok "A2 cpu from the last data line" || bad "A2 cpu=$(field cpu)"

# ── A3 vmstat missing / garbage ──────────────────────────────────────────────
# ps and sleep stubs on a PATH that has no vmstat
mkdir -p "$T/stub2"; cp -p "$STUB/ps" "$STUB/sleep" "$T/stub2/"
reset; run "$NOW" "$T/stub2:$NOVM"
[ "$RC" = 0 ] && ok "A3 exit 0 without vmstat" || bad "A3 exit $RC"
[ "$(field steal)" = NA ] && ok "A3 no vmstat: steal=NA" || bad "A3 steal=$(field steal) line: $(last)"
[ "$(field cpu)" = NA ] && ok "A3 no vmstat: cpu=NA" || bad "A3 cpu=$(field cpu)"
[ "$(field runnable)" = "4.00" ] && ok "A3 the sample still runs" || bad "A3 runnable=$(field runnable)"
reset; touch "$T/vmstat.garbage"; run "$NOW"
[ "$(field steal)" = NA ] && ok "A3 garbage vmstat: steal=NA, not 0" || bad "A3 garbage steal=$(field steal)"

# ── A3b forks per second ─────────────────────────────────────────────────────
reset; run "$NOW"
[ "$(field forks_s)" = "100.0" ] && ok "A3b forks_s=100.0 (1000 over 10 s)" || bad "A3b forks_s=$(field forks_s)"
reset; rm -f "$T/stat"; run "$NOW"
[ "$(field forks_s)" = NA ] && ok "A3b missing stat file: forks_s=NA" || bad "A3b missing forks_s=$(field forks_s)"
reset; printf 'cpu 1 2 3\n' > "$T/stat"; run "$NOW"
[ "$(field forks_s)" = NA ] && ok "A3b no processes line: forks_s=NA" || bad "A3b noline forks_s=$(field forks_s)"

# ── A4 retention ─────────────────────────────────────────────────────────────
reset; mkdir -p "$H/state/hub-load"
for d in 2026-09-18 2026-09-19 2026-09-20; do echo x > "$H/state/hub-load/$d.tsv"; done   # NOW-15, -14, -13
echo x > "$H/state/hub-load/notes.txt"; echo x > "$H/state/hub-load/bad-name.tsv"; echo x > "$H/state/hub-load/2026-13-45.tsv"
run "$NOW"
[ ! -e "$H/state/hub-load/2026-09-18.tsv" ] && ok "A4 NOW-15 d file deleted" || bad "A4 NOW-15 d file kept"
[ -e "$H/state/hub-load/2026-09-19.tsv" ] && [ -e "$H/state/hub-load/2026-09-20.tsv" ] && ok "A4 NOW-14 d and NOW-13 d kept" || bad "A4 a kept file was deleted"
[ -e "$H/state/hub-load/notes.txt" ] && [ -e "$H/state/hub-load/bad-name.tsv" ] && [ -e "$H/state/hub-load/2026-13-45.tsv" ] \
  && ok "A4 unparsable names left alone" || bad "A4 an unparsable name was deleted"
lastlog | grep -q ' pruned=1 ' && ok "A4 pruned=1" || bad "A4 summary: $(lastlog)"
lastlog | grep -q 'keep_days=14(default)' && ok "A4 keep_days=14(default)" || bad "A4 keep src: $(lastlog)"

# ── A5 p90 alert, once per UTC hour ──────────────────────────────────────────
reset; seed "$TSV" 5 20
run "$NOW";          a1=$(nalerts); s1=$(lastlog)
run $((NOW + 600));  a2=$(nalerts); s2=$(lastlog)
run $((NOW + 1200)); a3=$(nalerts); s3=$(lastlog)
[ "$a1" = 1 ] && [ "$a2" = 1 ] && [ "$a3" = 1 ] && ok "A5 3 runs in one UTC hour: exactly one ALERTS line" || bad "A5 alerts after runs: $a1 $a2 $a3"
[[ "$s1" == *"alert=written"* ]] && [[ "$s2" == *"alert=latched"* ]] && [[ "$s3" == *"alert=latched"* ]] \
  && ok "A5 written, then latched" || bad "A5 summaries: $s1 | $s2 | $s3"
grep 'hub-load-sample' "$H/logs/ALERTS.log" | grep -q 'p90 20' && ok "A5 the line names the p90" || bad "A5 line: $(cat "$H/logs/ALERTS.log")"
run $((NOW + 3600))
[ "$(nalerts)" = 2 ] && ok "A5 the next UTC hour writes one more line" || bad "A5 next hour alerts=$(nalerts) $(lastlog)"
reset; seed "$TSV" 4 20; run "$NOW"
[ "$(nalerts)" = 0 ] && lastlog | grep -q 'alert=insufficient(5)' && ok "A5 5 values: insufficient(5), no line" || bad "A5 five: $(nalerts) $(lastlog)"
reset; seed "$TSV" 5 1; run "$NOW"
[ "$(nalerts)" = 0 ] && lastlog | grep -q 'alert=under' && ok "A5 under the limit: no line" || bad "A5 under: $(nalerts) $(lastlog)"
reset; seed "$TSV" 5 8; run "$NOW"
[ "$(nalerts)" = 0 ] && lastlog | grep -q 'alert=under' && ok "A5 p90 equal to the limit: no line" || bad "A5 equal: $(nalerts) $(lastlog)"
reset; seed "$TSV" 5 NA; seed "$TSV" 1 20; run "$NOW"
[ "$(nalerts)" = 0 ] && lastlog | grep -q 'alert=insufficient(2)' && ok "A5 NA runs are skipped" || bad "A5 NA: $(nalerts) $(lastlog)"
reset; seed "$H/state/hub-load/2026-10-02.tsv" 5 20; run "$NOW"
[ "$(nalerts)" = 1 ] && ok "A5 yesterday's file fills the window" || bad "A5 yesterday: $(nalerts) $(lastlog)"

# ── A6 field order and the 15-pair cap ───────────────────────────────────────
reset
{ printf '%5d %5d S    bash            /bin/bash /root/harness/bin/s17.sh\n' 900 1
  for i in $(seq -w 1 17); do printf '%5d %5d R    bash            /bin/bash /root/harness/bin/s%s.sh\n' "$((100 + 10#$i))" 1 "$i"; done
  printf '%5d %5d R    jq              jq .\n' 950 900; } > "$T/ps17.txt"
printf '%s\n' "$T/ps17.txt" > "$T/ps.src"; run "$NOW"
keys=$(last | tr '\t' '\n' | sed -n '2,5p' | cut -d= -f1 | tr '\n' ' ')
[ "$keys" = "runnable steal forks_s cpu " ] && ok "A6 order: time, runnable, steal, forks_s, cpu" || bad "A6 order: $keys"
last | cut -f1 | grep -qx '2026-10-03T04:05:00Z' && ok "A6 first field is the ISO time" || bad "A6 time: $(last | cut -f1)"
pairs=$(last | cut -f7- | tr '\t' '\n' | grep -c '=')
[ "$pairs" = 15 ] && ok "A6 at most 15 pairs (17 names)" || bad "A6 pairs=$pairs"
[ "$(last | cut -f7)" = "s17.sh=11.1" ] && ok "A6 the biggest name is first" || bad "A6 first pair: $(last | cut -f7)"
[ "$(last | cut -f21)" = "s14.sh=5.6" ] && [ -z "$(field s15.sh)" ] && ok "A6 ties by name, s15 and s16 cut" || bad "A6 last pair: $(last | cut -f21)"

# ── A7 ledger push ───────────────────────────────────────────────────────────
reset; stub_client 0; rm -f "$T/ledger.json"; run "$NOW"
[ "$(jq -r '.[0]' "$T/ledger.json" 2>/dev/null)" = hub-load ] && ok "A7 kind hub-load" || bad "A7 ledger: $(cat "$T/ledger.json" 2>/dev/null)"
[ "$(jq -r '.[1]' "$T/ledger.json" 2>/dev/null)" = "hub:04:00" ] && ok "A7 key hub:04:00 (10-min slot)" || bad "A7 key: $(jq -r '.[1]' "$T/ledger.json" 2>/dev/null)"
[ "$(jq -r '.[2]' "$T/ledger.json" 2>/dev/null)" = ok ] && ok "A7 status ok" || bad "A7 status"
jq -e '(.[3] | fromjson | .steal) == 57' "$T/ledger.json" >/dev/null 2>&1 && ok "A7 detail .steal == 57" || bad "A7 detail: $(jq -r '.[3]' "$T/ledger.json" 2>/dev/null)"
jq -e '(.[3] | fromjson | .runnable) == 4' "$T/ledger.json" >/dev/null 2>&1 && ok "A7 detail .runnable == 4" || bad "A7 detail runnable"
[ "$(jq -r '.[3] | fromjson | .top[0].n' "$T/ledger.json" 2>/dev/null)" = "(kworker/0:1)" ] && ok "A7 detail .top in tsv order" || bad "A7 detail top"
lastlog | grep -q ' push=ok ' && ok "A7 push=ok" || bad "A7 summary: $(lastlog)"
reset; stub_client 1; run $((NOW + 600))
lastlog | grep -q ' push=failed ' && ok "A7 push=failed on rc 1" || bad "A7 failed: $(lastlog)"
[ "$(field runnable)" = "4.00" ] && ok "A7 the tsv line is written when the push fails" || bad "A7 tsv on fail: $(last)"
reset; rm -f "$T/stat"; stub_client 0; run "$NOW"
[ "$(jq -r '.[3] | fromjson | .forks_s' "$T/ledger.json" 2>/dev/null)" = null ] \
  && ok "A7 NA is null in the detail" || bad "A7 NA detail: $(jq -r '.[3]' "$T/ledger.json" 2>/dev/null)"
reset; run "$NOW"
lastlog | grep -q ' push=not-configured ' && ok "A7 no JOBS_URL: push=not-configured" || bad "A7 not-configured: $(lastlog)"
[ -s "$TSV" ] && ok "A7 tsv written when not configured" || bad "A7 no tsv"
reset; echo 'return 1' > "$H/bin/jobs-client.sh"; run "$NOW"
lastlog | grep -q ' push=not-loaded ' && ok "A7 client fails to load: push=not-loaded" || bad "A7 not-loaded: $(lastlog)"
[ "$(field runnable)" = "4.00" ] && ok "A7 tsv written when the client does not load" || bad "A7 tsv not-loaded"

# ── A8 knob rows ─────────────────────────────────────────────────────────────
reset; stub_client 0; seed "$TSV" 5 5; STUB_MAXR=3 run "$NOW"
[ "$(nalerts)" = 1 ] && lastlog | grep -q 'max_runnable=3(row)' && ok "A8 row 3: a p90 of 5 fires" || bad "A8 row: $(nalerts) $(lastlog)"
reset; stub_client 0; seed "$TSV" 5 5; STUB_MAXR=abc run "$NOW"
[ "$(nalerts)" = 0 ] && lastlog | grep -q 'max_runnable=8(default)' && ok "A8 abc: default 8, no line" || bad "A8 abc: $(nalerts) $(lastlog)"
reset; stub_client 0; mkdir -p "$H/state/hub-load"; echo x > "$H/state/hub-load/2026-09-30.tsv"; STUB_KEEP=2 run "$NOW"
[ ! -e "$H/state/hub-load/2026-09-30.tsv" ] && lastlog | grep -q 'keep_days=2(row)' && ok "A8 keep_days row 2 prunes NOW-3 d" || bad "A8 keep: $(lastlog)"

# ── A9 lane off ──────────────────────────────────────────────────────────────
reset; touch "$H/flags/lane-off-hub-load-sample"; run "$NOW"
[ "$RC" = 0 ] && [ ! -e "$TSV" ] && ok "A9 lane off: exit 0, no tsv line" || bad "A9 rc=$RC tsv=$(last)"

# ── A10 lock held ────────────────────────────────────────────────────────────
reset; exec 9> "$H/locks/hub-load-sample.lock"; flock -n 9
run "$NOW"
exec 9>&-
[ "$RC" = 0 ] && [ ! -e "$TSV" ] && lastlog | grep -q 'skipped (running)' && ok "A10 lock held: skipped (running)" || bad "A10 rc=$RC $(lastlog)"

# ── A11 ps fails ─────────────────────────────────────────────────────────────
reset; touch "$T/ps.fail"; run "$NOW"
[ "$RC" = 0 ] && [ "$(field runnable)" = NA ] && [ "$(field samples)" = "0/3" ] \
  && ok "A11 ps fails: runnable=NA samples=0/3, line written" || bad "A11 rc=$RC $(last)"

echo
echo "hub-load-sample: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
