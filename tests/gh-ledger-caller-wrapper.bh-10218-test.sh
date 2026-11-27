#!/bin/bash
# tests/gh-ledger-caller-wrapper.bh-10218-test.sh — BH-10218 W1: the ledger
# names the SCRIPT behind a wrapper program, not the wrapper.
#
# WHY. The hub ledger (2026-11-26 10:00Z-10:33Z) named `timeout` as the caller
# of 21 `pulls` and 16 `repos/<owner>/<repo>` reads. bin/gh-ledger/gh
# (_ghl_caller) and bin/gh-rest-shim (gshim_caller) take the program name of
# $PPID, and `timeout 30 gh …` makes `timeout` that parent. Both now step past a
# wrapper program (timeout gtimeout nice ionice setsid flock env stdbuf nohup
# chrt) to its parent, at most 3 hops, and never print an argument.
#
# Cases (the plan's decision rule):
#   W1 `timeout 30 gh`                      -> lane.sh
#   W2 `timeout 9 timeout 8 gh` (2 hops)    -> lane.sh
#   W3 `flock <f> timeout 9 gh` (2 hops)    -> lane.sh
#   W4 `env A=1 gh` (env execs: no hop)     -> lane.sh
#   N1 bash bin/timeout-report.sh calls gh  -> timeout-report.sh (a script, not a wrapper)
#   N2 a program named timeoutd             -> timeoutd (not in the list)
#   N3 `bash -c 'gh …; true'`               -> bash (today's rule)
#   N4 four nested `timeout`s               -> timeout (stops after 3 hops)
#   N5 no argument text reaches the row
#   S  bin/gh-rest-shim under `timeout 5`   -> the fixture script name
# Nothing touches the network: the real `gh` is a stub that prints the trace
# shape gh 2.101 prints under GH_DEBUG=api.
#
# Run from anywhere: bash tests/gh-ledger-caller-wrapper.bh-10218-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SHIM="$DIR/bin/gh-ledger/gh"
RSHIM="$DIR/bin/gh-rest-shim"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

NOW=1790143200   # determinism: ok pinned
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/flags" "$T/tmp" "$T/real" "$T/lane/bin"
export TMPDIR="$T/tmp"
unset GH_TOKEN GITHUB_TOKEN GH_DEBUG HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_LEDGER_OFF GH_LEDGER_DEPTH GH_LEDGER_BY_CALLER GH_REST_SHIM_DEPTH
LED="$T/h/state/gh-rest-ledger"

cat > "$T/real/gh" <<STUB
#!/bin/bash
if [ "\${GH_DEBUG:-}" = api ]; then
  cat >&2 <<'EOF'
* Request at 2026-09-23 03:00:01.000000 +0000 UTC m=+0.042467085
* Request to https://api.github.com/repos/o/r/pulls
> GET /repos/o/r/pulls HTTP/1.1
> Host: api.github.com

< HTTP/2.0 200 OK
< X-Ratelimit-Limit: 6600
< X-Ratelimit-Remaining: 6000
< X-Ratelimit-Reset: $((NOW + 900))
< X-Ratelimit-Resource: core
< X-Ratelimit-Used: 600

* Request took 1.000000ms
EOF
fi
printf '[]'
exit 0
STUB
chmod +x "$T/real/gh"

# The lane: argv[1] is a mode, argv[2] a would-be secret that must never reach
# a row. It calls gh by name, the way a lane does.
cat > "$T/lane/lane.sh" <<'SH'
#!/bin/bash
mode="$1"
case "$mode" in
  W1) timeout 30 gh api repos/o/r/pulls ;;
  W2) timeout 9 timeout 8 gh api repos/o/r/pulls ;;
  W3) flock "$TMPDIR/w3.lock" timeout 9 gh api repos/o/r/pulls ;;
  W4) env A=1 gh api repos/o/r/pulls ;;
  N3) bash -c 'gh api repos/o/r/pulls; true' ;;
  N4) timeout 9 timeout 9 timeout 9 timeout 9 gh api repos/o/r/pulls ;;
esac
exit 0
SH
cat > "$T/lane/bin/timeout-report.sh" <<'SH'
#!/bin/bash
gh api repos/o/r/pulls
exit 0
SH
cp "$T/lane/bin/timeout-report.sh" "$T/lane/bin/timeoutd"
chmod +x "$T/lane/lane.sh" "$T/lane/bin/timeout-report.sh" "$T/lane/bin/timeoutd"

SHIMDIR="$(dirname "$SHIM")"
P0="$SHIMDIR:$T/real:/usr/bin:/bin"
rows() { cat "$LED"/*.tsv 2>/dev/null; }
col() { rows | awk -F'\t' -v c="$1" 'NR==1{print $c}'; }
reset() { [ -e "$LED" ] && scratch_rm "$LED"; return 0; }
case_is() { # case_is <name> <want> <cmd…>
  local name="$1" want="$2"; shift 2
  reset
  env PATH="$P0" "$@" > "$T/out" 2> "$T/err"
  [ "$(rows | grep -c .)" = 1 ] || { bad "$name: want 1 ledger row, got: $(rows) err: $(head -c 300 "$T/err")"; return; }
  [ "$(col 2)" = "$want" ] && ok || bad "$name: the caller must be '$want', got '$(col 2)'"
  case "$(rows)" in *SECRETX*) bad "$name: argument text reached the row: $(rows)" ;; *) ok ;; esac
}

[ -x "$SHIM" ] && ok || bad "0: bin/gh-ledger/gh must exist and be executable"

case_is "W1 timeout 30 gh" lane.sh "$T/lane/lane.sh" W1 SECRETX
case_is "W2 timeout timeout gh (2 hops)" lane.sh "$T/lane/lane.sh" W2 SECRETX
case_is "W3 flock timeout gh (2 hops)" lane.sh "$T/lane/lane.sh" W3 SECRETX
case_is "W4 env A=1 gh" lane.sh "$T/lane/lane.sh" W4 SECRETX
case_is "N1 a script named timeout-report.sh" timeout-report.sh bash "$T/lane/bin/timeout-report.sh" SECRETX
case_is "N2 a program named timeoutd" timeoutd "$T/lane/bin/timeoutd" SECRETX
case_is "N3 bash -c stays bash" bash "$T/lane/lane.sh" N3 SECRETX
case_is "N4 four nested timeouts stop at 3 hops" timeout "$T/lane/lane.sh" N4 SECRETX
# Today's rule is unchanged for a direct call: the parent script.
case_is "D direct call" timeout-report.sh "$T/lane/bin/timeout-report.sh" SECRETX

# ══ S: bin/gh-rest-shim's passthrough line names the script behind `timeout` ══
mkdir -p "$T/rs"
ln -sf "$RSHIM" "$T/rs/gh"
cat > "$T/lane/fixture-lane.sh" <<'SH'
#!/bin/bash
timeout 5 gh frobnicate-untranslated
exit 0
SH
chmod +x "$T/lane/fixture-lane.sh"
PLOG="$T/h/logs/gh-passthrough.log"
rm -f "$PLOG"
env PATH="$T/rs:$T/real:/usr/bin:/bin" GH_REAL="$T/real/gh" "$T/lane/fixture-lane.sh" SECRETX > "$T/out" 2> "$T/err"
if [ -s "$PLOG" ]; then
  grep -q ' caller=fixture-lane.sh ' "$PLOG" && ok || bad "S: gh-rest-shim must name fixture-lane.sh behind timeout, got: $(cat "$PLOG")"
  grep -q 'SECRETX' "$PLOG" && bad "S: argument text reached the passthrough log: $(cat "$PLOG")" || ok
else
  bad "S: gh-rest-shim wrote no passthrough line (err: $(head -c 300 "$T/err"))"
fi
# S2: a direct call (no wrapper) keeps today's answer.
rm -f "$PLOG"
cat > "$T/lane/direct-lane.sh" <<'SH'
#!/bin/bash
gh frobnicate-untranslated
exit 0
SH
chmod +x "$T/lane/direct-lane.sh"
env PATH="$T/rs:$T/real:/usr/bin:/bin" GH_REAL="$T/real/gh" "$T/lane/direct-lane.sh" > "$T/out" 2> "$T/err"
grep -q ' caller=direct-lane.sh ' "$PLOG" 2>/dev/null && ok || bad "S2: a direct call names direct-lane.sh, got: $(cat "$PLOG" 2>/dev/null)"

# ══ T: one shared word list, written once in each file ══
w1=$(sed -n 's/^_GHL_WRAPPERS="\(.*\)".*/\1/p' "$SHIM")
w2=$(sed -n 's/^GSHIM_WRAPPERS="\(.*\)".*/\1/p' "$RSHIM")
[ -n "$w1" ] && [ "$w1" = "$w2" ] && ok || bad "T: the wrapper lists must be equal and non-empty: ledger='$w1' shim='$w2'"

echo "gh-ledger-caller-wrapper: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
