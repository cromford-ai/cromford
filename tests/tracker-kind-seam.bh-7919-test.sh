#!/bin/bash
# tests/tracker-kind-seam.bh-7919-test.sh — BH-7919: the tracker kind seam.
# bin/lib/tracker.sh tracker_kind / tracker_context and
# bin/lib/tracker/linear.sh trk_linear_context, driven through the real libs in
# a scratch tree. The settings worker is a stub bin/jobs-client.sh whose
# setting_get reads $ROWS/<key> and logs every key it is asked for, so a case
# can count reads. No network: no curl, no gh.
#
#   K1-K4  tracker_kind answers github-issues, board, jira, linear
#   K5     a second call in the same shell reads no row (the cache)
#   K6     TRK_DRY=1 reads no row, and the jira project answers column 4
#   K7     a caller under set -u with no cache variable does not die
#   K8     a typo row is rc 1 and is not cached
#   L1-L7  trk_linear_context: env only; rows win; team mismatch; no key;
#          outage; no fixture token in any output; a dry run reads no row
#   C1-C10 tracker_context for the four kinds, the refusals with
#          TRK_CTX_MISSING, no stdout, no token in any output, and the dry-run
#          board with no token variable writes no ALERTS line
#   C7     a caller that sets only H (HARNESS unset) over a WRITABLE copy of
#          bin/: the token script gets HARNESS=$H and writes its ALERTS flag
#          there, and nothing lands in the copy (the suite-reach refusal of the
#          first build: lib-root-records a6-seed-H)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; ROWS="$T/rows"
export FLEET_CONF="$H/fleet.conf"  # fleet-conf.sh reads /root/harness/fleet.conf before its own dir
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$ROWS"
cat > "$H/bin/jobs-client.sh" <<'SH'
# stub jobs client: setting_get <key> -> $ROWS/<key>; rc 2 no row, rc 1 worker down
setting_get() {
  printf '%s\n' "$1" >> "$ROWS/calls"
  [ -e "$ROWS/down" ] && return 1
  [ -r "$ROWS/$1" ] || return 2
  cat "$ROWS/$1"
}
SH
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/internal-token-for.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
[ -r "$H/bin/lib/tracker/linear.sh" ] || { echo "FAIL: closure did not install bin/lib/tracker/linear.sh"; exit 1; }
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
gh  o/gh  https://gh.example  -           1 box-1 192.0.2.1
bd  o/bd  https://bd.example  /api/board  2 box-1 192.0.2.1
bn  o/bn  https://bn.example  /api/board  3 box-1 192.0.2.1
bt  o/bt  https://bt.example  /api/board  4 box-1 192.0.2.1
jr  o/jr  https://jr.example  -           5 box-1 192.0.2.1
ln  o/ln  https://ln.example  -           6 box-1 192.0.2.1
lx  o/lx  https://lx.example  -           7 box-1 192.0.2.1
ty  o/ty  https://ty.example  -           8 box-1 192.0.2.1
CONF
printf 'BD_API_BASE=https://board.example/\nBD_INTERNAL_API_TOKEN=tok-fixture-bd\n' > "$H/env/bd.env"
printf 'BN_INTERNAL_API_TOKEN=tok-fixture-bn\n' > "$H/env/bn.env"
printf 'BT_API_BASE=https://bt-board.example\n' > "$H/env/bt.env"
printf 'JIRA_BASE=https://api.atlassian.com/ex/jira/33333333-3333-3333-3333-333333333333\nJIRA_EMAIL=bot@example.com\nJIRA_API_TOKEN=tok-fixture-jr\n' > "$H/env/jr.env"
printf 'LINEAR_API_KEY=tok-fixture-ln\nLINEAR_TEAM=CRO\nLINEAR_LABEL=env-label\n' > "$H/env/ln.env"
printf 'LINEAR_TEAM=CRO\n' > "$H/env/lx.env"
printf 'jira' > "$ROWS/tracker_adapter.jr"
printf 'SCRUM' > "$ROWS/tracker_jira.jr.write_projects"
printf 'linear' > "$ROWS/tracker_adapter.ln"
printf 'linear' > "$ROWS/tracker_adapter.lx"
printf 'linaer' > "$ROWS/tracker_adapter.ty"
printf 'github-issues' > "$ROWS/tracker_adapter.gz"

# sh <snippet> — the snippet in a fresh bash that sourced the real lib.
sh() { HARNESS="$H" ROWS="$ROWS" bash -c '. "$HARNESS/bin/lib/tracker.sh" || exit 9; '"$1"; }
calls() { if [ -r "$ROWS/calls" ]; then grep -c "${1:-.}" "$ROWS/calls"; else echo 0; fi; }
reset_calls() { rm -f "$ROWS/calls"; }
ALL="$T/all-output"; : > "$ALL"

# ---- K: tracker_kind -----------------------------------------------------------
eq K1 "$(sh 'tracker_kind gh')" github-issues
eq K2 "$(sh 'tracker_kind bd')" board
eq K3 "$(sh 'tracker_kind jr')" jira
eq K4 "$(sh 'tracker_kind ln')" linear

reset_calls
out=$(sh 'tracker_kind ln >/dev/null; tracker_kind ln; tracker_kind ln')
eq "K5 answer" "$(printf '%s' "$out" | paste -sd' ' -)" "linear linear"
eq "K5 one read for three calls" "$(calls tracker_adapter.ln)" 1

reset_calls
eq "K6 dry jira project answers column 4" "$(sh 'TRK_DRY=1; tracker_kind jr')" github-issues
eq "K6 dry linear project answers column 4" "$(sh 'TRK_DRY=1; tracker_kind ln')" github-issues
eq "K6 dry reads no row" "$(calls)" 0
# The mode is part of the cache key: a dry answer never serves a live call.
eq "K6 dry answer does not serve live" "$(sh 'TRK_DRY=1; tracker_kind ln >/dev/null; TRK_DRY=0; tracker_kind ln')" linear

out=$(HARNESS="$H" ROWS="$ROWS" bash -c 'set -u; unset _TRK_KIND_CACHE; . "$HARNESS/bin/lib/tracker.sh"; tracker_kind gh; echo "alive rc=$?"' 2>&1)
eq K7 "$out" "github-issues
alive rc=0"

reset_calls
out=$(sh 'tracker_kind ty; echo "rc=$?"; tracker_kind ty; echo "rc=$?"' 2>/dev/null)
eq "K8 typo row rc 1, no answer" "$(printf '%s' "$out" | paste -sd' ' -)" "rc=1 rc=1"
eq "K8 a refusal is not cached" "$(calls tracker_adapter.ty)" 2

# ---- L: trk_linear_context -------------------------------------------------------
# lctx <project> [<pre-snippet>] — the context, then its variables, one per line.
lctx() {
  sh "${2:-}"'
    tracker_load linear || exit 8
    TRK_LINEAR_TOKEN=stale; TRK_LINEAR_TEAM=STALE
    trk_linear_context '"$1"' >"$OUTF"; echo "rc=$?"
    echo "team=$TRK_LINEAR_TEAM"; echo "var=$TRK_LINEAR_TOKEN_VAR"; echo "label=$TRK_LINEAR_LABEL"
    echo "states=$TRK_LINEAR_STATES"; [ "$TRK_LINEAR_TOKEN" = tok-fixture-ln ] && echo tok=fixture || echo "tok-len=${#TRK_LINEAR_TOKEN}"'
}
export OUTF="$T/ctx.stdout"
r=$(lctx ln 2>"$T/err"); cat "$T/err" >> "$ALL"; printf '%s\n' "$r" >> "$ALL"
eq "L1 rc" "$(sed -n 1p <<<"$r")" rc=0
eq "L1 team from env" "$(sed -n 2p <<<"$r")" team=CRO
eq "L1 token var" "$(sed -n 3p <<<"$r")" var=LINEAR_API_KEY
eq "L1 label from env" "$(sed -n 4p <<<"$r")" label=env-label
eq "L1 token set" "$(sed -n 6p <<<"$r")" tok=fixture
eq "L1 no stdout" "$(cat "$OUTF")" ""

printf 'row-label' > "$ROWS/tracker_linear.ln.label"
printf '{"review":"QA"}' > "$ROWS/tracker_linear.ln.states"
printf 'CRO' > "$ROWS/tracker_linear.ln.team"
r=$(lctx ln 2>"$T/err"); cat "$T/err" >> "$ALL"; printf '%s\n' "$r" >> "$ALL"
eq "L2 rc" "$(sed -n 1p <<<"$r")" rc=0
eq "L2 row label wins" "$(sed -n 4p <<<"$r")" label=row-label
eq "L2 row states" "$(sed -n 5p <<<"$r")" 'states={"review":"QA"}'
printf 'not json' > "$ROWS/tracker_linear.ln.states"
r=$(lctx ln 2>"$T/err"); cat "$T/err" >> "$ALL"
eq "L2b states not an object rc 1" "$(sed -n 1p <<<"$r")" rc=1
grep -q 'not a JSON object' "$T/err" && ok || bad "L2b stderr says the states are not a JSON object: $(cat "$T/err")"
rm -f "$ROWS/tracker_linear.ln.states"

printf 'ENG' > "$ROWS/tracker_linear.ln.team"
r=$(lctx ln 2>"$T/err"); cat "$T/err" >> "$ALL"
eq "L3 row/env team mismatch rc 1" "$(sed -n 1p <<<"$r")" rc=1
eq "L3 blank team" "$(sed -n 2p <<<"$r")" team=
grep -q 'name different teams' "$T/err" && ok || bad "L3 stderr names the mismatch: $(cat "$T/err")"
rm -f "$ROWS/tracker_linear.ln.team" "$ROWS/tracker_linear.ln.label"

r=$(lctx lx 2>"$T/err"); cat "$T/err" >> "$ALL"
eq "L4 no key rc 1" "$(sed -n 1p <<<"$r")" rc=1
eq "L4 every variable blank" "$(sed -n '2,5p' <<<"$r" | paste -sd' ' -) $(sed -n 6p <<<"$r")" "team= var= label= states= tok-len=0"
eq "L4 one stderr line" "$(grep -c . "$T/err")" 1
grep -q 'LINEAR_API_KEY' "$T/err" && ok || bad "L4 stderr names LINEAR_API_KEY: $(cat "$T/err")"

: > "$ROWS/down"
r=$(lctx ln 2>"$T/err"); cat "$T/err" >> "$ALL"
eq "L5 outage rc 1" "$(sed -n 1p <<<"$r")" rc=1
eq "L5 outage blank token" "$(sed -n 6p <<<"$r")" tok-len=0
grep -q 'tracker_linear.ln' "$T/err" && ok || bad "L5 stderr names the rows: $(cat "$T/err")"
# L7: a dry run reads no row, so an outage does not matter and the env decides.
reset_calls
r=$(lctx ln 'TRK_DRY=1;' 2>"$T/err"); cat "$T/err" >> "$ALL"
eq "L7 dry rc 0 with the worker down" "$(sed -n 1p <<<"$r")" rc=0
eq "L7 dry reads no row" "$(calls tracker_linear)" 0
rm -f "$ROWS/down"

grep -q 'tok-fixture' "$ALL" && bad "L6 a fixture token reached stdout/stderr: $(grep -m1 tok-fixture "$ALL")" || ok

# ---- C: tracker_context ------------------------------------------------------------
# cctx <project> [<pre-snippet>] — rc, TRK_CTX_MISSING, then the named variables.
cctx() {
  sh "${3:-}"'
    tracker_context '"$1"' >"$OUTF"; echo "rc=$? missing=$TRK_CTX_MISSING adapter=${TRK_ADAPTER:-}"
    for v in '"$2"'; do printf "%s=%s\n" "$v" "${!v:-}"; done'
}
: > "$T/c-stdout"
r=$(cctx gh TRK_SLUG 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C1 rc" "$(sed -n 1p <<<"$r")" "rc=0 missing= adapter=github-issues"
eq "C1 slug" "$(sed -n 2p <<<"$r")" TRK_SLUG=o/gh

r=$(cctx bd "TRK_BOARD_BASE TRK_BOARD_TOKEN_VAR" 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C2 rc" "$(sed -n 1p <<<"$r")" "rc=0 missing= adapter=board"
eq "C2 base, trailing slash stripped" "$(sed -n 2p <<<"$r")" TRK_BOARD_BASE=https://board.example/api/board
eq "C2 token var" "$(sed -n 3p <<<"$r")" TRK_BOARD_TOKEN_VAR=BD_INTERNAL_API_TOKEN
eq "C2 token set" "$(sh 'tracker_context bd; [ "$TRK_BOARD_TOKEN" = tok-fixture-bd ] && echo yes')" yes

r=$(cctx jr "TRK_JIRA_BASE TRK_JIRA_WRITE_PROJECTS" 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C3 rc" "$(sed -n 1p <<<"$r")" "rc=0 missing= adapter=jira"
eq "C3 gateway base" "$(sed -n 2p <<<"$r")" TRK_JIRA_BASE=https://api.atlassian.com/ex/jira/33333333-3333-3333-3333-333333333333
eq "C3 allowlist" "$(sed -n 3p <<<"$r")" TRK_JIRA_WRITE_PROJECTS=SCRUM

r=$(cctx ln "TRK_LINEAR_TEAM TRK_LINEAR_TOKEN_VAR" 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C4 rc" "$(sed -n 1p <<<"$r")" "rc=0 missing= adapter=linear"
eq "C4 team" "$(sed -n 2p <<<"$r")" TRK_LINEAR_TEAM=CRO
eq "C4 token var" "$(sed -n 3p <<<"$r")" TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY

r=$(cctx bn TRK_BOARD_BASE 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C6 board with no base" "$(sed -n 1p <<<"$r")" "rc=1 missing=base adapter=board"
eq "C6 base stays empty" "$(sed -n 2p <<<"$r")" TRK_BOARD_BASE=

scratch_rm "$T/h/logs/ALERTS.log" || exit 1; scratch_rm "$T/h/flags" || exit 1
r=$(cctx bt "TRK_BOARD_BASE TRK_BOARD_TOKEN" 'TRK_DRY=1;' 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C6 dry board with no token var" "$(sed -n 1p <<<"$r")" "rc=1 missing=token adapter=board"
eq "C6 dry keeps the base" "$(sed -n 2p <<<"$r")" TRK_BOARD_BASE=https://bt-board.example/api/board
[ -s "$H/logs/ALERTS.log" ] && bad "C6 a dry run with no token variable wrote an ALERTS line: $(cat "$H/logs/ALERTS.log")" || ok
# The same project live asks internal-token-for.sh, which says so once.
r=$(cctx bt TRK_BOARD_BASE 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C6 live board with no token" "$(sed -n 1p <<<"$r")" "rc=1 missing=token adapter=board"
grep -q 'bt: env/bt.env defines no \*_INTERNAL_API_TOKEN' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "C6 live: internal-token-for.sh wrote its ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# C7: the root the token script takes. A writable copy of bin/ (the shape a
# nobody-owned snapshot has; a root-owned checkout hid it, because the child's
# mkdir there failed silently). Only H is set. $R/bin has no
# internal-token-for.sh, so the copy's runs: a stub that records HARNESS, then
# execs the real script. Without the handoff the real script takes the copy as
# its root and writes flags/ and logs/ there.
R="$T/c7root"; LC="$T/lib-copy"
mkdir -p "$R/env" "$LC"
cp -R "$H/bin" "$LC/bin"
mv "$LC/bin/internal-token-for.sh" "$LC/bin/internal-token-for.real.sh"
cat > "$LC/bin/internal-token-for.sh" <<SH
#!/bin/bash
printf 'HARNESS=%s\n' "\${HARNESS-<unset>}" >> "$T/c7-itf-env"
exec "\$(dirname "\$0")/internal-token-for.real.sh" "\$@"
SH
chmod +x "$LC/bin/internal-token-for.sh"
printf 'BT_API_BASE=https://bt-board.example\n' > "$R/env/bt.env"
# Fixed old mtimes on the copy and the marker: any write after this is newer.
find "$LC" -exec touch -d @1000000000 {} +; touch -d @1000000001 "$T/c7-marker"
r=$(env -u HARNESS H="$R" ROWS="$ROWS" bash -c '. "'"$LC"'/bin/lib/tracker.sh" || exit 9
  tracker_context bt c7 >/dev/null; echo "rc=$? missing=$TRK_CTX_MISSING base=$TRK_BOARD_BASE"' 2>>"$ALL")
eq "C7 H-only board with no token" "$r" "rc=1 missing=token base=https://bt-board.example/api/board"
eq "C7 token script got the caller's root" "$(cat "$T/c7-itf-env" 2>/dev/null)" "HARNESS=$R"
ls "$R"/flags/alerted-token-bt-* >/dev/null 2>&1 && ok || bad "C7 the ALERTS flag landed under H: $(ls -R "$R" 2>&1 | head -5)"
eq "C7 nothing written in the copy of bin/" "$(find "$LC" -newer "$T/c7-marker" 2>&1)" ""
eq "C7 no flags/ or logs/ beside the copy" "$(ls -d "$LC/flags" "$LC/logs" 2>/dev/null)" ""

r=$(cctx gz TRK_SLUG 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C9 github project with no repo" "$(sed -n 1p <<<"$r")" "rc=1 missing=slug adapter=github-issues"
r=$(cctx nope TRK_SLUG 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C9 unknown project" "$(sed -n 1p <<<"$r")" "rc=1 missing=kind adapter="
r=$(cctx lx TRK_LINEAR_TEAM 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C9 linear with no key" "$(sed -n 1p <<<"$r")" "rc=1 missing=context adapter=linear"
mv "$H/bin/lib/tracker/linear.sh" "$T/linear.sh.away"
r=$(cctx ln TRK_LINEAR_TEAM 2>>"$ALL"); cat "$OUTF" >> "$T/c-stdout"
eq "C10 adapter file missing" "$(sed -n 1p <<<"$r")" "rc=1 missing=adapter adapter="
mv "$T/linear.sh.away" "$H/bin/lib/tracker/linear.sh"

eq "C5 tracker_context printed nothing on stdout" "$(cat "$T/c-stdout")" ""
grep -q 'tok-fixture' "$ALL" "$T/c-stdout" && bad "C5 a fixture token reached stdout/stderr" || ok

echo "tracker-kind-seam.bh-7919: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
