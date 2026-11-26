#!/bin/bash
# tests/staff-watchman-chat.bh-10122-test.sh — BH-10122 (C1 of BH-9423): the
# watchman check chat-secret. bin/staff/watchman-collect.sh scans the Archie
# chat log (WM_CHAT_LOG, the orc-context.sh record format) with gitleaks `dir`
# and prints one chat-secret finding per location: the record time, the part,
# the line and the rule, never the value. bin/staff/watchman-metric.sh counts
# the live chat locations in live_unrotated_secrets.
#
#   C1  a key on line 2 of a message -> exactly 1 line, the item exact, 1 beat,
#       the value in no output, log, beat or state file; gitleaks runs `dir`
#       with --redact=100. Two keys in one tick -> 2 lines, 1 beat (+1 more)
#   C2  no row from gitleaks -> 0 lines, 0 beats, every record in `scanned`
#   C3  a key on the REPLY line -> part reply line 1; no REPLY line -> message;
#       `REPLY:` inside a message line does not move the split
#   C4  a second tick with no new record runs no gitleaks and prints the cached
#       line with no beat; one appended record -> one run over 1 file
#   C5  gitleaks rc 1 -> nothing scanned, 0 lines; the 3rd failure in a row is
#       one warn beat; a good run resets the count
#   C6  25 history + 2 chat cached, STAFF_MAX_ITEMS 20 -> 20 lines; the next
#       tick prints the 7 not printed first
#   C7  sandbox with no WM_CHAT_LOG -> no gitleaks run, no chat/ dir; a missing
#       file, an empty value and a symlink -> one log line each, nothing else
#   C8  the record header decision table
#   C9  the report row decision table; a report that is `{}` is a failure
#   C10 the metric counts the live chat locations; no cache = no `chat=`
#   C11 the REAL collector writes the chat cache, the REAL metric counts it
#   C12 the soul: REPORT line, the new section, the checklist lines once
#
# gitleaks is a WM_GITLEAKS stub that writes a report as gitleaks 8.30.1 does,
# UNREDACTED (Secret, Match), so a collector that read them would leak the
# value into an output. curl and gh are stubs that log and fail: 0 network calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-watchman-chat.bh-10122-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
for c in jq git node; do command -v "$c" >/dev/null 2>&1 || { echo "staff-watchman-chat: $c is required"; exit 1; }; done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

COL_REL=bin/staff/watchman-collect.sh
MET_REL=bin/staff/watchman-metric.sh
NOW=1795608000   # 2026-11-25T12:00:00Z, pinned
HR=3600
# Fake values, built here from the test name; never a committed literal.
RUN=$(printf '%s' staff-watchman-chat.bh-10122 | sha256sum | cut -c1-20)
KEY1="ghp_$(printf FIXTURE)${RUN}ABCDEFGHIJKLMN"
KEY2="ghp_$(printf FIXTURE)${RUN}ZYXWVUTSRQPONM"

H="$T/h"; FXT="$T/fx"
mkdir -p "$H" "$FXT" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
scratch_install_closure "$COL_REL" "$H" >/dev/null || bad "scratch_install_closure $COL_REL failed"
scratch_install_closure "$MET_REL" "$H" >/dev/null || bad "scratch_install_closure $MET_REL failed"
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
# The gitleaks stub. `dir <src>`: one row per line of each file that holds a
# value of $FXT/keys.tsv (<value> TAB <rule>), as gitleaks writes it, with the
# value in Secret and Match. $FXT/chat-report.json overrides the rows (__D__ =
# the scanned dir). $FXT/gl.rc is the exit code.
cat > "$T/gitleaks" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gl.log"
mode=$1; src=${2:-}; out=""
while [ $# -gt 0 ]; do [ "$1" = --report-path ] && { out=$2; shift; }; shift; done
if [ "$mode" = dir ] && [ -n "$out" ]; then
  find "$src" -type f | grep -c . >> "$FXT/gl.files"
  if [ -f "$FXT/chat-report.json" ]; then
    sed "s#__D__#$src#g" "$FXT/chat-report.json" > "$out"
  else
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      while IFS=$'\t' read -r v r; do
        [ -n "$v" ] || continue
        grep -nF -- "$v" "$f" | cut -d: -f1 | while read -r n; do
          jq -cn --arg f "$f" --argjson l "$n" --arg r "$r" --arg s "$v" \
            '{Description: "x", StartLine: $l, EndLine: $l, StartColumn: 1, EndColumn: 40, Match: ("token " + $s), Secret: $s,
              File: $f, SymlinkFile: "", Commit: "", Entropy: 4.1, Author: "", Email: "", Date: "", Message: "",
              Tags: [], RuleID: $r, Fingerprint: ($f + ":" + $r + ":" + ($l | tostring))}'
        done
      done < "$FXT/keys.tsv"
    done | jq -cs . > "$out"
  fi
fi
exit "$(cat "$FXT/gl.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/gitleaks"
cat > "$T/wmfx.sh" <<'SH'
_jobs_req() { printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"; return 1; }
_jobs_req_file() { printf '%s %s\n' "$1" "$2" >> "$FXT/wm-req.log"; return 1; }
gh_rest() { printf 'gh_rest %s %s\n' "$1" "$2" >> "$FXT/wm-gh.log"; return 1; }
SH
cat > "$T/metfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=watchman") echo '{"agent":{"name":"watchman","status":"active"}}'; return 0 ;;
    "GET /api/staff/findings?agent=watchman")
      cat "$FXT/findings.json" 2>/dev/null || echo '{"agent":"watchman","findings":[],"truncated":false}'; return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "POST /api/staff/levers/metric") jq -c . "$3" >> "$FXT/samples.jsonl"; printf '{"ok":true,"settled":0}'; return 0 ;;
  esac
  return 1
}
flag_active() { [ -f "$FXT/flags/$1" ]; }
setting_get() { return 1; }
SH

WMS="$H/state/staff/watchman"
CHAT="$T/conversation-log.md"
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/catalog" "$H/locks" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/flags" "$H/bin"
  : > "$FXT/beats.log"; : > "$FXT/gl.log"; : > "$FXT/keys.tsv"; : > "$FXT/wm-req.log"; : > "$FXT/req.log"
  rm -f "$T/net.log" "$CHAT"
  cp "$T/lane-alert.stub" "$H/bin/lane-alert.sh"
  cp "$T/fleet-conf.stub" "$H/bin/fleet-conf.sh"
}
# wm [VAR=value ...]: one collector tick, with WM_CHAT_LOG=$CHAT unless NOCHAT=1.
wm() {
  local -a ch=(WM_CHAT_LOG="$CHAT")
  [ "${NOCHAT:-}" = 1 ] && ch=()
  env -u WM_CHAT_LOG HARNESS="$H" FXT="$FXT" WM_FIXTURE="$T/wmfx.sh" HARNESS_TEST_SANDBOX=1 WM_NOW="${WNOW:-$NOW}" \
    WM_GITLEAKS="$T/gitleaks" WM_REPOS_ROOT="$T/repos" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" "${ch[@]}" "$@" bash "$COL" > "$T/out" 2> "$T/err"
  RC=$?
}
met() {
  env HARNESS="$H" FXT="$FXT" WM_METRIC_FIXTURE="$T/metfx.sh" HARNESS_TEST_SANDBOX=1 WM_METRIC_NOW="$NOW" \
    WM_REPOS_ROOT="$T/repos" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= JOBS_ALERT=0 \
    PATH="$T/fakebin:$PATH" "$@" bash "$MET" > "$T/mout" 2> "$T/merr"
  RC=$?
}
beats() { lines "$FXT/beats.log"; }
glruns() { local n; n=$(grep -c '^dir ' "$FXT/gl.log" 2>/dev/null); echo "${n:-0}"; }
slog() { cat "$H/logs/staff.log" 2>/dev/null; }
# rec <iso> <lane> <message %b> <reply %b>: one record as bin/orc-context.sh append writes it.
rec() { printf '\n### %s · %s\nOPERATOR: %b\nREPLY: %b\n' "$1" "$2" "$3" "$4" >> "$CHAT"; }
# recsha <iso> <lane> <message> <reply>: the sha12 of the record text (header to
# its last non-blank line).
recsha() { printf '### %s · %s\nOPERATOR: %b\nREPLY: %b\n' "$1" "$2" "$3" "$4" | sha256sum | cut -c1-12; }
key() { printf '%s\t%s\n' "$1" "$2" >> "$FXT/keys.tsv"; }
no_value() {
  local hits
  hits=$(grep -rlF -e "$KEY1" -e "$KEY2" "$T/out" "$T/err" "$T/mout" "$T/merr" "$H/logs" "$H/state" "$FXT/beats.log" "$FXT/samples.jsonl" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "$1: the key value is in: $hits"
}
fpof() {
  node --input-type=module -e "import { fingerprint } from '$DIR/agent-core/src/index.js'; console.log(fingerprint(JSON.parse(process.argv[1])));" "$1"
}
I1=2026-11-25T10:00:00Z; I2=2026-11-25T10:05:00Z; I3=2026-11-25T10:09:00Z; I4=2026-11-25T11:00:00Z
M2="deploy is red, here is the token\n$KEY1\nuse it"

# ═════ C1: one key -> one finding, the location only ═════════════════════════
c1() {
  reset
  rec "$I1" claude-1 "status?" "all green"
  rec "$I2" claude-1 "$M2" "ok, set it"
  rec "$I3" "bash floor" "thanks" "done"
  key "$KEY1" github-pat
}
c1; wm
eq "C1 rc" "$RC" 0
eq "C1 one line" "$(lines "$T/out")" 1
eq "C1 class" "$(jq -r .class "$T/out" 2>/dev/null)" chat-secret
S2=$(recsha "$I2" claude-1 "$M2" "ok, set it")
eq "C1 item" "$(jq -c .item "$T/out" 2>/dev/null)" \
  "{\"check\":\"chat-secret\",\"at\":\"$I2\",\"record\":\"$S2\",\"part\":\"message\",\"line\":2,\"rule\":\"github-pat\"}"
eq "C1 title" "$(jq -r .title "$T/out" 2>/dev/null)" \
  "Critical: key-shaped value pasted in the Archie chat: github-pat in the message of $I2 line 2 (record $S2). Rotate the credential."
eq "C1 source kind" "$(jq -r .source.kind "$T/out" 2>/dev/null)" staff-security
eq "C1 beats" "$(beats)" 1
eq "C1 beat argv" "$(cat "$FXT/beats.log")" \
  "--id staff-watchman-chat-$NOW --severity critical staff Critical: key-shaped value in the Archie chat: github-pat in the message of $I2 line 2. Rotate it."
eq "C1 one gitleaks dir run" "$(glruns)" 1
grep -q -- '--redact=100' "$FXT/gl.log" && ok || bad "C1: gitleaks ran without --redact=100: $(cat "$FXT/gl.log")"
eq "C1 three files scanned" "$(cat "$FXT/gl.files")" 3
eq "C1 cache rows" "$(lines "$WMS/chat/leaks.jsonl")" 1
eq "C1 scanned rows" "$(lines "$WMS/chat/scanned")" 3
grep -q "chat: scanned 3 records new=1 rows=1" <<<"$(slog)" && ok || bad "C1 log: $(slog)"
eq "C1 no request" "$(lines "$FXT/wm-req.log")" 0
[ -e "$T/net.log" ] && bad "C1: a network call: $(cat "$T/net.log")" || ok
no_value C1
# Two keys in one tick: two lines, one beat.
c1; rec "$I4" claude-2 "and the other" "REPLY with $KEY2"; key "$KEY2" github-pat; wm
eq "C1b two lines" "$(lines "$T/out")" 2
eq "C1b beats" "$(beats)" 1
grep -q -- ' (+1 more)\. Rotate it\.$' "$FXT/beats.log" && ok || bad "C1b beat: $(cat "$FXT/beats.log")"
no_value C1b

# ═════ C2: no row -> nothing printed, every record scanned ═══════════════════
c1; : > "$FXT/keys.tsv"; wm
eq "C2 rc" "$RC" 0
eq "C2 lines" "$(lines "$T/out")" 0
eq "C2 beats" "$(beats)" 0
eq "C2 scanned" "$(lines "$WMS/chat/scanned")" 3
eq "C2 cache rows" "$(lines "$WMS/chat/leaks.jsonl")" 0

# ═════ C3: the part split ════════════════════════════════════════════════════
reset
rec "$I1" claude-1 "here" "REPLY_KEY_LINE $KEY1"
key "$KEY1" github-pat
printf '\n### %s · %s\nOPERATOR: no reply here\nsee REPLY: below\n%s\n' "$I2" claude-1 "$KEY2" >> "$CHAT"
rec "$I3" claude-1 "x REPLY: y\n$KEY2" "fine"
key "$KEY2" github-pat
wm
eq "C3 lines" "$(lines "$T/out")" 3
eq "C3 reply line" "$(jq -r 'select(.item.at == "'"$I1"'") | "\(.item.part) \(.item.line)"' "$T/out")" "reply 1"
eq "C3 no REPLY line" "$(jq -r 'select(.item.at == "'"$I2"'") | "\(.item.part) \(.item.line)"' "$T/out")" "message 3"
eq "C3 REPLY: inside a message" "$(jq -r 'select(.item.at == "'"$I3"'") | "\(.item.part) \(.item.line)"' "$T/out")" "message 2"
no_value C3

# ═════ C4: the scanned set over two ticks ════════════════════════════════════
c1; wm
WNOW=$((NOW + 900)) wm
eq "C4 no new record: no gitleaks run" "$(glruns)" 1
eq "C4 the cached line still prints" "$(lines "$T/out")" 1
eq "C4 no second beat" "$(beats)" 1
grep -q "chat: scanned 0 new records" <<<"$(slog)" && ok || bad "C4 log: $(slog)"
rec "$I4" claude-1 "next" "ok"
WNOW=$((NOW + 1800)) wm
eq "C4 one new record: one run" "$(glruns)" 2
eq "C4 one new record: one file" "$(tail -1 "$FXT/gl.files")" 1
eq "C4 scanned rows" "$(lines "$WMS/chat/scanned")" 4
eq "C4 still one line" "$(lines "$T/out")" 1
eq "C4 still one beat" "$(beats)" 1
# A trim drops record 1: the scanned set drops it too, and nothing is rescanned.
awk 'f || /^### 2026-11-25T10:05:00Z/ {f=1; print}' "$CHAT" > "$CHAT.t" && mv "$CHAT.t" "$CHAT"
WNOW=$((NOW + 2700)) wm
eq "C4 trimmed: no run" "$(glruns)" 2
eq "C4 trimmed: scanned pruned" "$(lines "$WMS/chat/scanned")" 3

# ═════ C5: a failed scan marks nothing ═══════════════════════════════════════
c1; echo 1 > "$FXT/gl.rc"
for i in 1 2 3; do WNOW=$((NOW + i * 900)) wm; done
eq "C5 rc" "$RC" 0
eq "C5 three runs" "$(glruns)" 3
eq "C5 nothing scanned" "$(lines "$WMS/chat/scanned")" 0
eq "C5 no line" "$(lines "$T/out")" 0
eq "C5 one warn beat" "$(grep -c -- "--id staff-watchman-scanfail-_chat-$((NOW + 2700)) --severity warn staff Watchman: the chat scan failed 3 times in a row (last: gitleaks rc=1)" "$FXT/beats.log")" 1
eq "C5 beats" "$(beats)" 1
rm -f "$FXT/gl.rc"; WNOW=$((NOW + 3600)) wm
eq "C5 good run: one line" "$(lines "$T/out")" 1
[ -e "$WMS/scan/_chat.fail" ] && bad "C5: the fail count was not reset" || ok
eq "C5 good run: scanned" "$(lines "$WMS/chat/scanned")" 3

# ═════ C6: chat lines share the claim window with history ════════════════════
reset; mkdir -p "$WMS/leaks" "$WMS/chat"
for i in $(seq 1 25); do
  jq -cn --argjson l "$i" '{check: "history-secret", project: "p6", commit: "0123456789abcdef0123456789abcdef01234567", file: ".env", line: $l, rule: "aws-access-token"}'
done | LC_ALL=C sort -u > "$WMS/leaks/p6.jsonl"
for i in 1 2; do
  jq -cn --argjson l "$i" --arg at "$I1" '{check: "chat-secret", at: $at, record: "aaaaaaaaaaaa", part: "message", line: $l, rule: "github-pat"}'
done | LC_ALL=C sort -u > "$WMS/chat/leaks.jsonl"
NOCHAT=1 wm STAFF_MAX_ITEMS=20
eq "C6 tick 1 lines" "$(lines "$T/out")" 27
head -20 "$T/out" | jq -c .item | LC_ALL=C sort > "$T/c6.first"
tail -7 "$T/out" | jq -c .item | LC_ALL=C sort > "$T/c6.left"
eq "C6 chat lines printed" "$(jq -r .class "$T/out" | grep -c chat-secret)" 2
NOCHAT=1 WNOW=$((NOW + 900)) wm STAFF_MAX_ITEMS=20
eq "C6 tick 2: the 7 not printed come first" "$(head -7 "$T/out" | jq -c .item | LC_ALL=C sort)" "$(cat "$T/c6.left")"
eq "C6 no gitleaks run" "$(glruns)" 0

# ═════ C7: the chat scan off, a missing file, a symlink ══════════════════════
c1; NOCHAT=1 wm
eq "C7 sandbox, no WM_CHAT_LOG: no run" "$(glruns)" 0
[ -e "$WMS/chat" ] && bad "C7: a chat/ dir with no WM_CHAT_LOG" || ok
eq "C7 sandbox, no WM_CHAT_LOG: no line" "$(lines "$T/out")" 0
eq "C7 sandbox, no WM_CHAT_LOG: no chat log line" "$(slog | grep -c 'chat:')" 0
reset; wm WM_CHAT_LOG="$T/no-such.md"
eq "C7 missing: no run" "$(glruns)" 0
eq "C7 missing: one log line" "$(slog | grep -c "chat: no chat log at $T/no-such.md; no chat scan")" 1
[ -e "$WMS/chat" ] && bad "C7: a chat/ dir for a missing log" || ok
reset; wm WM_CHAT_LOG=
eq "C7 empty: one log line" "$(slog | grep -c 'chat: WM_CHAT_LOG is empty; no chat scan')" 1
eq "C7 empty: no run" "$(glruns)" 0
c1; ln -s "$CHAT" "$T/link.md"; wm WM_CHAT_LOG="$T/link.md"; rm -f "$T/link.md"
eq "C7 symlink: no run" "$(glruns)" 0
eq "C7 symlink: one log line" "$(slog | grep -c "chat: $T/link.md is not a regular file; no chat scan")" 1
c1; mkdir -p "$T/dirlog"; wm WM_CHAT_LOG="$T/dirlog"
eq "C7 a dir: one log line" "$(slog | grep -c "chat: $T/dirlog is not a regular file; no chat scan")" 1

# ═════ C8: the record header decision table ══════════════════════════════════
reset
{
  printf 'preamble %s\n' "$KEY2"
  printf '### 2026-11-25T10:00:00Z · claude-1\nOPERATOR: a\n## 2026-11-25T10:01:00Z · x\n### 2026-11-25 10:00 · x\n%s\n' "$KEY1"
  printf '###2026-11-25T10:02:00Z · x\nREPLY: b\n\n'
  printf '### 2026-11-25T10:03:00Z · bash floor\nOPERATOR: c\nREPLY: d %s\n' "$KEY2"
} > "$CHAT"
key "$KEY1" github-pat; key "$KEY2" generic-api-key
wm
eq "C8 two records scanned" "$(cat "$FXT/gl.files")" 2
eq "C8 lines" "$(lines "$T/out")" 2
eq "C8 a bad header stays in its record" "$(jq -r 'select(.item.rule == "github-pat") | "\(.item.at) \(.item.part) \(.item.line)"' "$T/out")" \
  "2026-11-25T10:00:00Z message 4"
eq "C8 a lane with a space" "$(jq -r 'select(.item.rule == "generic-api-key") | "\(.item.at) \(.item.part) \(.item.line)"' "$T/out")" \
  "2026-11-25T10:03:00Z reply 1"
grep -q "chat: skipped 1 lines before the first record" <<<"$(slog)" && ok || bad "C8 preamble log: $(slog)"
no_value C8

# ═════ C9: the report row decision table ═════════════════════════════════════
c9() { reset; rec "$I1" a "m1" "r1"; rec "$I2" a "m2" "r2"; rec "$I3" a "m3\nm3b\nm3c" "r3"; printf '%s\n' "$1" > "$FXT/chat-report.json"; }
c9 '[{"RuleID":"github-pat","File":"__D__/r1.txt","StartLine":2,"Secret":"S"},
     {"RuleID":"generic-api-key","File":"__D__/r3.txt","StartLine":3},
     {"RuleID":"github-pat","File":"../x.txt","StartLine":1},
     {"RuleID":"github-pat","File":"__D__/r9.txt","StartLine":1},
     {"RuleID":"github-pat","File":"__D__/r1.txt","StartLine":0},
     {"RuleID":"github-pat","File":"__D__/r1.txt","StartLine":"2"},
     {"RuleID":"a b","File":"__D__/r1.txt","StartLine":1},
     {"Secret":"only"}]'
wm
eq "C9 kept" "$(jq -r '"\(.item.rule) \(.item.at) \(.item.part) \(.item.line)"' "$T/out" | LC_ALL=C sort | paste -sd'|')" \
  "generic-api-key $I3 message 3|github-pat $I1 reply 1"
eq "C9 skipped rows logged" "$(slog | grep -c 'chat: report row skipped')" 6
eq "C9 scanned" "$(lines "$WMS/chat/scanned")" 3
c9 '{}'; wm
eq "C9 {} lines" "$(lines "$T/out")" 0
eq "C9 {} nothing scanned" "$(lines "$WMS/chat/scanned")" 0
eq "C9 {} fail count" "$(cat "$WMS/scan/_chat.fail" 2>/dev/null)" 1
grep -q "chat scan failed (the report is not a gitleaks report)" <<<"$(slog)" && ok || bad "C9 {} log: $(slog)"

# ═════ C10: the metric counts the live chat locations ════════════════════════
pkey() { printf '%s' "$1" | sha256sum | cut -c1-64; }
reset; mkdir -p "$WMS/leaks" "$WMS/chat"
LH=$(jq -cn '{check: "history-secret", project: "m", commit: "0123456789abcdef0123456789abcdef01234567", file: ".env", line: 1, rule: "aws-access-token"}')
LO=$(jq -cn --arg at "$I1" '{check: "chat-secret", at: $at, record: "aaaaaaaaaaaa", part: "message", line: 1, rule: "github-pat"}')
LC=$(jq -cn --arg at "$I2" '{check: "chat-secret", at: $at, record: "bbbbbbbbbbbb", part: "reply", line: 1, rule: "github-pat"}')
printf '%s\n' "$LH" > "$WMS/leaks/m.jsonl"
printf '%s\n' "$LO" "$LC" | LC_ALL=C sort > "$WMS/chat/leaks.jsonl"
printf '%s\t%s\n' "$(pkey "$LH")" "$NOW" "$(pkey "$LO")" "$NOW" "$(pkey "$LC")" "$NOW" > "$WMS/printed.tsv"
jq -n --arg h "$(fpof "$LH")" --arg o "$(fpof "$LO")" '{agent: "watchman", truncated: false, findings: [{fingerprint: $h, status: "filed"}, {fingerprint: $o, status: "filed"}]}' > "$FXT/findings.json"
met
eq "C10 rc" "$RC" 0
eq "C10 value" "$(jq -r .value "$FXT/samples.jsonl" 2>/dev/null)" 2
eq "C10 detail" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=1 rotation=0 allowlisted=0 chat=1"
grep -q ' live_unrotated_secrets=2 history=1 rotation=0 allowlisted=0 chat=1 sample=ok$' "$H/logs/staff-watchman-metric.log" && ok \
  || bad "C10 log: $(tail -1 "$H/logs/staff-watchman-metric.log" 2>/dev/null)"
rm -f "$WMS/chat/leaks.jsonl"; : > "$FXT/samples.jsonl"; met
eq "C10 no cache: no chat=" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=1 rotation=0 allowlisted=0"
# Only chat locations, never printed: live.
reset; mkdir -p "$WMS/chat"; printf '%s\n' "$LO" > "$WMS/chat/leaks.jsonl"; met
eq "C10 chat only, never printed" "$(jq -r '"\(.value) \(.detail)"' "$FXT/samples.jsonl" 2>/dev/null)" "1 history=0 rotation=0 allowlisted=0 chat=1"

# ═════ C11: the real collector, then the real metric ═════════════════════════
c1; wm
jq -n --arg f "$(fpof "$(jq -c .item "$T/out")")" '{agent: "watchman", truncated: false, findings: [{fingerprint: $f, status: "filed"}]}' > "$FXT/findings.json"
met
eq "C11 value" "$(jq -r .value "$FXT/samples.jsonl" 2>/dev/null)" 1
eq "C11 detail" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=0 allowlisted=0 chat=1"
rm -f "$FXT/findings.json"; : > "$FXT/samples.jsonl"; met
eq "C11 printed and not open: closed" "$(jq -r .detail "$FXT/samples.jsonl" 2>/dev/null)" "history=0 rotation=0 allowlisted=0 chat=0"
no_value C11

# ═════ C12: the soul ═════════════════════════════════════════════════════════
SOUL="$DIR/prompts/staff/watchman-soul.md"
node "$DIR/bin/staff-core.mjs" soul "$SOUL" > "$T/soul.json"
eq "C12 parses" "$(jq -r .ok "$T/soul.json")" true
eq "C12 NEVER count" "$(jq -r '.never | length' "$T/soul.json")" 9
eq "C12 REPORT holds the chat line" "$(jq -r '.report | map(select(. == "a key pasted into the chat with Archie")) | length' "$T/soul.json")" 1
eq "C12 the section" "$(grep -cx '## When I file a ticket for a key pasted into the chat' "$SOUL")" 1
eq "C12 no label line in the section" "$(sed -n '/^## When I file a ticket for a key pasted/,$p' "$SOUL" | grep -cE '^(MAY|NEVER|REPORT)')" 0
eq "C12 the delete line" "$(grep -cxF -- '- [ ] Delete or edit the chat message that holds the key, where the chat allows it.' "$SOUL")" 1
for l in '- [ ] Rotate the credential at its vendor.' '- [ ] Revoke the old value.' '- [ ] Close this issue as completed. That closes the finding.'; do
  eq "C12 checklist line once: ${l:6:24}" "$(grep -cxF -- "$l" "$SOUL")" 1
done

echo "staff-watchman-chat: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
