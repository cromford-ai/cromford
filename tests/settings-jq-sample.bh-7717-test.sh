#!/bin/bash
# tests/settings-jq-sample.bh-7717-test.sh — BH-7717: bin/settings-jq-sample.sh
# counts the jq processes that read the settings cache and their CPU seconds
# per hour, over a fake --proc-root built per case.
#
#   S1  3 matching jq pids among 5 non-matching processes: pids=3.
#   S2  the non-matching processes alone: pids=0 per_min=0.0 cpu_s_per_h=0.0.
#   S3  CPU math: CLK_TCK 100, 2 s window, 60 ticks: cpu_s_per_h=1080.0,
#       per_min = pids * 60 / seconds.
#   S4  a pid whose ticks grow between polls counts its highest ticks once; a
#       pid whose ticks drop (a reused pid) keeps the highest it showed.
#   S5  bad arguments exit 64.
#   S6  a jq that exits between the grep and the stat read is skipped, with
#       no shell error on the output.
#   S7  a process that execs between the grep and the cmdline read (a bash
#       child whose cmdline named the cache, now a jq over another file) is
#       not counted: both rules are decided from one read of the cmdline.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/settings-jq-sample.bh-7717-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SJS="$DIR/bin/settings-jq-sample.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# mkproc <root> <pid> <ticks> <argv...> — a fake /proc/<pid> with a NUL-split
# cmdline and a stat line whose utime+stime is <ticks>.
mkproc() {
  local r="$1" p="$2" t="$3"; shift 3
  mkdir -p "$r/$p"
  printf '%s\0' "$@" > "$r/$p/cmdline"
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0 1 0 1 0 0\n' "$p" "${1##*/}" "$((t - t / 2))" "$((t / 2))" > "$r/$p/stat"
}
negatives() {
  mkproc "$1" 201 50 jq . /h/state/other.json
  mkproc "$1" 202 50 grep settings-cache.json x
  mkproc "$1" 203 50 /usr/bin/jqx /h/state/settings-cache.json
  mkproc "$1" 204 50 bash bin/x.sh /h/state/settings-cache.json
  mkproc "$1" 205 50 jq -r . /h/state/lane-gate/settings-cache.env
}
run() { OUT=$(SJS_CLK_TCK=100 bash "$SJS" "$@" 2>&1); RC=$?; }

# S1 / S3
P="$T/p1"; mkdir -p "$P"
mkproc "$P" 101 10 jq -r --arg src /h/state/settings-cache.json 'def enc: gsub("_";"__")'
mkproc "$P" 102 20 /usr/bin/jq --arg src /h/state/settings-cache.json .
mkproc "$P" 103 30 jq -e .values /h/state/settings-cache.json
negatives "$P"
run --seconds 2 --interval-ms 50 --proc-root "$P"
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC: $OUT"
case "$OUT" in "settings_jq pids=3 per_min=90.0 cpu_s_per_h=1080.0 window_s=2 interval_ms=50 (lower bound: a jq that starts and ends between two polls is not seen)") ok ;;
  *) bad "S1/S3 line: $OUT" ;; esac
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "S1 more than one output line"

# S2
P="$T/p2"; mkdir -p "$P"; negatives "$P"
run --seconds 1 --proc-root "$P"
[ "$RC" = 0 ] && case "$OUT" in "settings_jq pids=0 per_min=0.0 cpu_s_per_h=0.0 window_s=1 interval_ms=50 "*) true ;; *) false ;; esac \
  && ok || bad "S2 rc=$RC: $OUT"

# S4 a pid that grows, and one that appears late
P="$T/p4"; mkdir -p "$P"
mkproc "$P" 301 10 jq --arg src /h/state/settings-cache.json .
( sleep 0.5; mkproc "$P" 301 40 jq --arg src /h/state/settings-cache.json .
  mkproc "$P" 302 20 jq . /h/state/settings-cache.json ) &
run --seconds 2 --interval-ms 100 --proc-root "$P"
wait
# ticks 40 + 20 = 60 over 2 s at CLK_TCK 100 = 1080 s/h; 2 pids = 60/min
case "$OUT" in "settings_jq pids=2 per_min=60.0 cpu_s_per_h=1080.0 window_s=2 interval_ms=100 "*) ok ;; *) bad "S4: $OUT" ;; esac
P="$T/p4b"; mkdir -p "$P"
mkproc "$P" 311 60 jq . /h/state/settings-cache.json
( sleep 0.5; mkproc "$P" 311 5 jq . /h/state/settings-cache.json ) &
run --seconds 2 --interval-ms 100 --proc-root "$P"
wait
case "$OUT" in "settings_jq pids=1 per_min=30.0 cpu_s_per_h=1080.0 window_s=2 interval_ms=100 "*) ok ;; *) bad "S4 drop: $OUT" ;; esac

# S5
for a in "--seconds x" "--seconds 0" "--interval-ms 0" "--interval-ms y" "--bogus" "--proc-root"; do
  # shellcheck disable=SC2086 # split on purpose
  run $a --proc-root "$T/p2"
  [ "$a" = "--proc-root" ] && run --proc-root
  [ "$RC" = 64 ] && ok || bad "S5 '$a' exit $RC (want 64)"
done
run --seconds 1 --proc-root "$T/nonexistent"
[ "$RC" = 64 ] && ok || bad "S5 a missing --proc-root exit $RC (want 64)"

# S6
P="$T/p6"; mkdir -p "$P"; negatives "$P"
mkproc "$P" 401 70 jq . /h/state/settings-cache.json; rm -f "$P/401/stat"
run --seconds 1 --proc-root "$P"
case "$RC $OUT" in "0 settings_jq pids=0 per_min=0.0 cpu_s_per_h=0.0 window_s=1 "*) ok ;; *) bad "S6 rc=$RC: $OUT" ;; esac

# S7 a grep shim that lists, then turns pid 501 into `jq . other.json` (an exec)
# before it prints the list.
P="$T/p7"; mkdir -p "$P" "$T/gshim"
mkproc "$P" 501 50 bash -c 'jq . /h/state/settings-cache.env; : settings-cache.json'
mkproc "$P" 502 20 jq . /h/state/settings-cache.json
cat > "$T/gshim/grep" <<SH
#!/bin/bash
out=\$($(command -v grep) "\$@"); rc=\$?
printf '%s\\0' jq . /h/state/lane-gate/settings-cache.env > "$P/501/cmdline"
printf '%s\\n' "\$out"; exit \$rc
SH
chmod +x "$T/gshim/grep"
OUT=$(PATH="$T/gshim:$PATH" SJS_CLK_TCK=100 bash "$SJS" --seconds 1 --proc-root "$P" 2>&1); RC=$?
case "$RC $OUT" in "0 settings_jq pids=1 per_min=60.0 cpu_s_per_h=720.0 window_s=1 "*) ok ;; *) bad "S7 an exec between the grep and the read was counted: rc=$RC: $OUT" ;; esac

echo "settings-jq-sample bh-7717: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
