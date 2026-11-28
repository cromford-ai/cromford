#!/bin/bash
# tests/staff-inspector-lever.bh-9419-test.sh — BH-9419 (C1 of #9187): the
# inspector staff agent owns hours_behind_main and files ONE fix-main-red
# issue, with the failing Vercel build step quoted, as its one lever.
# bin/staff/inspector-lever.sh is driven over real curl against one local
# server (tests/lib/inspector-world.bh-9419.mjs) that hosts the REAL jobs
# worker (the C0 lever routes, the settings rows of this PR's seed, the
# ledger), a fake Vercel API and a fake Cloudflare Pages project. GitHub is a
# `gh` stub on PATH (the gh api -i envelope of tests/lib/gh-rest-stub.sh) with
# an argv log. No call leaves the box (I12).
#
#   I0  sources, the cron line, the lane row, the 4 seed rows in the world's D1
#   U1  insp_vercel_hours over seeded state dirs
#   U2  insp_console_hours on a scratch git repo
#   U3  insp_action_verdict and insp_deliver_verdict tables
#   U4  insp_quote: filter, last N, 300-char cut, redaction, the step
#   I1  level observe, behind 5 h with ERROR: one sample, 0 actions, 0 gh calls
#   I2  console behind 3 h, Vercel in sync: sample 3.00, 0 actions
#   I3  level file, the seeded dry row: one dry action, 0 gh calls; act;rm -> 0
#   I4  (Acc 2) live: one action, then a sample 25 h later settles it
#   I5  the I4 issue body: title, label, step, fenced quote, markers, no em
#       dash; a dry run then a live run in one episode files once
#   I6  an unreadable part: no sample, no action, the log names the part
#   I7  two projects 3 h and 6 h: sample 6.00; lever_max_run 1 -> 1 action
#   I8  1.99 h, READY / BUILDING / list 500, events 500 -> no action row
#   I9  delivery dedupe: closed episode marker -> already; open project ->
#       open-reused; a refused action row -> no GitHub call
#   I10 day cap: 3 live actions -> day-cap; 3 dry -> no cap; cap abc -> 3
#   I11 kill flags, STAFF_ENABLED=0, lane-off flag, roster inactive -> no request
#   I12 every request went to 127.0.0.1; the gh argv log names no host
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-inspector-lever.bh-9419-test.sh  (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/inspector-world.bh-9419.mjs"
INSP_REL=bin/staff/inspector-lever.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2' want '$3'"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' found in: $2" ;; *) ok "$1" ;; esac; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or git missing"; exit 0; }

# Pinned clocks: the lane's clock is INSPECTOR_NOW. The shas are fixed.
NOW0=$(date -u -d 2026-11-12T12:00:00Z +%s)   # determinism: ok parses a fixed date, reads no clock
A=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432    # prod serves
B=2b2272a4e1f0c3d5b6a7980112233445566778aa    # main head
stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }  # determinism: ok formats a pinned epoch

# --- I0 sources -----------------------------------------------------------------
for f in "$DIR/$INSP_REL" "$DIR/catalog/lanes.d/staff-inspector-lever.json" \
         "$DIR/cron/lanes/781-staff-inspector-lever.cron" "$DIR/tests/lib/inspector-world.bh-9419.mjs" \
         "$DIR/worker/jobs/schema.d/202611121831-bh-9419-inspector-lever.sql" \
         "$DIR/docs/notes/2026-11-12-BH-9419-inspector-lever.md"; do
  [ -s "$f" ] && ok "I0 source exists: ${f#"$DIR"/}" || bad "I0 missing source ${f#"$DIR"/}"
done
grep -q '^23 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/staff/inspector-lever.sh ' \
  "$DIR/cron/lanes/781-staff-inspector-lever.cron" 2>/dev/null && ok "I0 cron: hourly :23 behind the hub lease" || bad "I0 cron line"
eq "I0 lane row" "$(jq -r '.script + " " + .switch.name + " " + .scope + " " + .cadence' "$DIR/catalog/lanes.d/staff-inspector-lever.json" 2>/dev/null)" \
  "bin/staff/inspector-lever.sh lane-off-staff-inspector-lever hub 23 * * * *"

# --- the unit half (INSPECTOR_LIB_ONLY=1) ---------------------------------------
lib() { INSPECTOR_LIB_ONLY=1 . "$DIR/$INSP_REL"; }

# state <dir> <p> <verdict> <since|-> <checked_at> [first_seen] — the shape
# bin/served-sha-watch.sh + 30-prodbehind.sh write (ssw_state_write).
state() {
  local d=$1 p=$2 v=$3 s=$4 c=$5 fs=${6:-$((NOW0 - 600))}
  mkdir -p "$d"
  if [ "$s" = - ]; then
    jq -nc --arg h "$B" --arg sv "$A" --arg v "$v" --argjson fs "$fs" --argjson c "$c" \
      '{head:$h, first_seen:$fs, served:$sv, dep_state:"failed", last_verdict:$v, checked_at:$c}' > "$d/$p.json"
  else
    jq -nc --arg h "$B" --arg sv "$A" --arg v "$v" --argjson fs "$fs" --argjson c "$c" --argjson s "$s" \
      '{head:$h, first_seen:$fs, served:$sv, dep_state:"failed", last_verdict:$v, checked_at:$c, prodbehind:{since:$s, open:true}}' > "$d/$p.json"
  fi
}
summary_line() { printf '%s checked=%s in_sync=0 wait=0 alert=%s unreadable=%s\n' "$(stamp "$1")" "$2" "$2" "${3:-0}"; }

# --- U1 insp_vercel_hours ---------------------------------------------------------
(
  lib || { echo "  FAIL U1 source"; exit 1; }
  f=0
  chk() { [ "$2" = "$3" ] && echo "  ok   U1 $1" || { echo "  FAIL U1 $1: got '$2' want '$3'"; f=1; }; }
  U="$T/u1"; mkdir -p "$U"
  printf 'project-3 team_fixture prj_fixture_project-3 project-3.example\nbeta team_fixture prj_fixture_beta beta.example\n' > "$U/vercel.conf"
  summary_line "$((NOW0 - 300))" 2 > "$U/ssw.log"
  out=$(insp_vercel_hours "$U/vercel.conf" "$U/none" "$U/ssw.log" "$NOW0" 20); rc=$?
  chk "no state files: rc 0" "$rc" 0
  chk "no state files: project-3 0" "$(awk '$1=="project-3"{print $2}' <<<"$out")" 0.00
  chk "no state files: beta 0" "$(awk '$1=="beta"{print $2}' <<<"$out")" 0.00
  chk "watch_unreadable=0" "$(head -1 <<<"$out")" watch_unreadable=0
  state "$U/s1" project-3 alert "$((NOW0 - 3 * 3600))" "$((NOW0 - 300))"
  out=$(insp_vercel_hours "$U/vercel.conf" "$U/s1" "$U/ssw.log" "$NOW0" 20)
  chk "alert since now-3h: 3.00" "$(awk '$1=="project-3"{print $2}' <<<"$out")" 3.00
  chk "alert since now-3h: since and fresh" "$(awk '$1=="project-3"{print $3, $4}' <<<"$out")" "$((NOW0 - 3 * 3600)) fresh"
  chk "alert: served and head carried" "$(awk '$1=="project-3"{print $5, $6}' <<<"$out")" "$A $B"
  chk "beta without a file stays 0" "$(awk '$1=="beta"{print $2}' <<<"$out")" 0.00
  state "$U/s2" project-3 wait "$((NOW0 - 9000))" "$((NOW0 - 300))"
  chk "wait counts: 2.50" "$(insp_vercel_hours "$U/vercel.conf" "$U/s2" "$U/ssw.log" "$NOW0" 20 | awk '$1=="project-3"{print $2}')" 2.50
  state "$U/s3" project-3 alert "$((NOW0 - 7200))" "$((NOW0 - 3600))"
  chk "stale file counts with its clock" "$(insp_vercel_hours "$U/vercel.conf" "$U/s3" "$U/ssw.log" "$NOW0" 20 | awk '$1=="project-3"{print $2, $4}')" "2.00 stale"
  state "$U/s4" project-3 alert - "$((NOW0 - 300))" "$((NOW0 - 4 * 3600))"
  chk "no .prodbehind uses first_seen" "$(insp_vercel_hours "$U/vercel.conf" "$U/s4" "$U/ssw.log" "$NOW0" 20 | awk '$1=="project-3"{print $2}')" 4.00
  summary_line "$((NOW0 - 21 * 60))" 2 > "$U/old.log"
  out=$(insp_vercel_hours "$U/vercel.conf" "$U/s1" "$U/old.log" "$NOW0" 20); rc=$?
  chk "summary 21 min old, fresh 20: rc 1" "$rc" 1
  chk "summary 21 min old: unreadable" "${out%% *}" unreadable
  out=$(insp_vercel_hours "$U/vercel.conf" "$U/s1" "$U/nolog" "$NOW0" 20); rc=$?
  chk "no watch log: rc 1" "$rc" 1
  mkdir -p "$U/s5"; printf '{"head":' > "$U/s5/project-3.json"
  out=$(insp_vercel_hours "$U/vercel.conf" "$U/s5" "$U/ssw.log" "$NOW0" 20); rc=$?
  chk "unparsable file: rc 1" "$rc" 1
  chk "unparsable file: unreadable" "${out%% *}" unreadable
  summary_line "$((NOW0 - 300))" 2 1 > "$U/unr.log"
  chk "watch unreadable=1 is carried" "$(insp_vercel_hours "$U/vercel.conf" "$U/s1" "$U/unr.log" "$NOW0" 20 | head -1)" watch_unreadable=1
  out=$(insp_vercel_hours "$U/no.conf" "$U/s1" "$U/ssw.log" "$NOW0" 20); rc=$?
  chk "no vercel.conf: rc 1" "$rc" 1
  exit "$f"
) && ok "U1 insp_vercel_hours" || bad "U1 insp_vercel_hours"

# --- a scratch harness checkout for the console part -----------------------------
HCO="$T/hco"
mkdir -p "$HCO" && git -C "$HCO" init -q -b main 2>/dev/null || git -C "$HCO" init -q
gcommit() { # gcommit <path> <epoch> -> sha
  mkdir -p "$HCO/$(dirname "$1")"; printf '%s\n' "$2" >> "$HCO/$1"
  git -C "$HCO" add -A >/dev/null
  GIT_AUTHOR_DATE="@$2 +0000" GIT_COMMITTER_DATE="@$2 +0000" git -C "$HCO" -c user.name=fixture -c user.email=fixture@example.com \
    commit -q -m "c $1 $2" >/dev/null
  git -C "$HCO" rev-parse HEAD
}
C1=$(gcommit console-ui/a.txt "$((NOW0 - 10 * 3600))")
C2=$(gcommit console-ui/b.txt "$((NOW0 - 3 * 3600))")
C3=$(gcommit console-ui/c.txt "$((NOW0 - 3600))")
C4=$(gcommit docs/x.txt "$((NOW0 - 1800))")
git -C "$HCO" update-ref refs/remotes/origin/main "$C4"
cf() { jq -nc --arg h "$1" '{success:true, result:{canonical_deployment:{deployment_trigger:{metadata:{commit_hash:$h}}}}}'; }

# --- U2 insp_console_hours ---------------------------------------------------------
(
  lib || { echo "  FAIL U2 source"; exit 1; }
  f=0
  chk() { [ "$2" = "$3" ] && echo "  ok   U2 $1" || { echo "  FAIL U2 $1: got '$2' want '$3'"; f=1; }; }
  cf "$C3" > "$T/u2.json"; chk "deploy == want: 0" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 0.00
  cf "$C1" > "$T/u2.json"; chk "2 console-ui commits behind: the oldest pending (C2, 3 h)" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 3.00
  cf "$C2" > "$T/u2.json"; chk "1 behind: C3, 1 h" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 1.00
  cf "$C4" > "$T/u2.json"; chk "deploy ahead of want (docs-only after): 0" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 0.00
  cf 0123456789abcdef0123456789abcdef01234567 > "$T/u2.json"
  chk "deploy unknown to the checkout: age of main's console-ui commit" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 1.00
  jq -nc --arg h "$C1" '{success:true, result:{latest_deployment:{environment:"production", deployment_trigger:{metadata:{commit_hash:$h}}}}}' > "$T/u2.json"
  chk "latest production deployment is the fallback field" "$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0")" 3.00
  for body in '{"success":false,"errors":[{"code":10000,"message":"auth"}]}' '{"success":true,"result":{}}' \
              '{"success":true,"result":{"latest_deployment":{"environment":"preview","deployment_trigger":{"metadata":{"commit_hash":"'"$C1"'"}}}}}' \
              'not json' ''; do
    printf '%s' "$body" > "$T/u2.json"
    out=$(insp_console_hours "$HCO" "$T/u2.json" "$NOW0"); rc=$?
    chk "unreadable answer '${body:0:30}': rc 1" "$rc" 1
    chk "unreadable answer '${body:0:30}': says unreadable" "${out%% *}" unreadable
  done
  cf "$C1" > "$T/u2.json"
  out=$(insp_console_hours "$T/no-checkout" "$T/u2.json" "$NOW0"); rc=$?
  chk "no checkout: rc 1" "$rc" 1
  exit "$f"
) && ok "U2 insp_console_hours" || bad "U2 insp_console_hours"

# --- U3 insp_action_verdict, insp_deliver_verdict ----------------------------------
(
  lib || { echo "  FAIL U3 source"; exit 1; }
  f=0
  chk() { local b="$T/u3.json"; printf '%s' "$2" > "$b"
          local got; got=$(insp_action_verdict "$1" "$b" "$3")
          [ "$got" = "$4" ] && echo "  ok   U3 $5" || { echo "  FAIL U3 $5: got '$got' want '$4'"; f=1; }; }
  chk 200 '{"ok":true,"action":{"action_key":"ab"}}' 0 new "a new row delivers"
  chk 200 '{"ok":true,"existing":true,"action":{"action_key":"ab"}}' 0 recorded-earlier "existing is recorded-earlier"
  chk 409 '{"error":"key_mismatch","action":{}}' 9 recorded-earlier "409 key_mismatch is recorded-earlier"
  chk 409 '{"error":"other"}' 9 failed "409 with another error is failed"
  chk 500 '{"error":"x"}' 1 failed "500 is failed"
  chk 404 '' 2 failed "404 (not on roster) is failed"
  chk "" '' 1 failed "rc 1, empty body is failed"
  chk 200 '{"ok":false}' 0 failed "ok:false is failed"
  chk 200 'not json' 0 failed "a non-JSON 200 is failed"
  dv() { local got; got=$(insp_deliver_verdict "$T/u3l.json" "$1" "$2" "$3" ${6:+"$6"})
         [ "$got" = "$4" ] && echo "  ok   U3 $5" || { echo "  FAIL U3 $5: got '$got' want '$4'"; f=1; }; }
  iss() { jq -nc --argjson n "$1" --arg s "$2" --arg b "$3" '{number:$n, state:$s, html_url:("https://github.com/example/fixture/issues/" + ($n|tostring)), body:$b}'; }
  ep() { printf '<!-- inspector-fmr:%s@%s -->\n<!-- inspector-fmr-project:%s -->' "$1" "$2" "$1"; }
  printf '[%s]' "$(iss 4 closed "$(ep project-3 100)")" > "$T/u3l.json"
  dv 0 project-3 100 "already https://github.com/example/fixture/issues/4" "the episode marker on a CLOSED issue is already"
  dv 0 project-3 200 file "a project marker only on a closed issue files a new one"
  printf '[%s,%s]' "$(iss 4 closed "$(ep project-3 100)")" "$(iss 6 open "$(ep project-3 150)")" > "$T/u3l.json"
  dv 0 project-3 200 "open-reused https://github.com/example/fixture/issues/6" "an open issue for an older episode is open-reused"
  printf '[%s]' "$(iss 7 open "$(ep project-3 100)")" > "$T/u3l.json"
  dv 0 project-3 100 file "a marker for project-3 does not count for project-3"
  printf '[]' > "$T/u3l.json"; dv 0 project-3 100 file "an empty list files"
  dv 75 project-3 100 list-unreadable "list rc 75 is list-unreadable"
  printf '{"message":"x"}' > "$T/u3l.json"; dv 0 project-3 100 list-unreadable "a list that is not an array is list-unreadable"
  jq -nc '[range(1000) | {number:., state:"open", body:""}]' > "$T/u3l.json"; dv 0 project-3 100 list-unreadable "a list of 1000 rows is list-unreadable"
  dv 0 project-3 100 list-unreadable "a list of 1000 rows with max 5000 is list-unreadable (the list reads 1000 at most)" 5000
  jq -nc '[range(50) | {number:., state:"open", body:""}]' > "$T/u3l.json"; dv 0 project-3 100 list-unreadable "a list of 50 rows with max 50 is list-unreadable" 50
  jq -nc '[range(49) | {number:., state:"open", body:""}]' > "$T/u3l.json"; dv 0 project-3 100 file "a list of 49 rows with max 50 files" 50
  exit "$f"
) && ok "U3 action and delivery verdicts" || bad "U3 action and delivery verdicts"

# --- U4 insp_quote ---------------------------------------------------------------------
ev_json() { # ev_json <n matching lines> — a Vercel /v3 events array
  jq -nc --argjson n "${1:-3}" '[
    {type:"command", created:1, payload:{text:"Running \"install\" command: `npm ci`"}},
    {type:"stdout", created:2, payload:{text:"added 500 packages"}},
    {type:"command", created:3, payload:{text:"Running \"build\" command: `npm run build`"}},
    {type:"stdout", created:4, payload:{text:"Creating an optimized production build"}},
    (range($n) | {type:"stdout", created:(10 + .), payload:{text:("Type error: line " + (. | tostring) + " failed")}}),
    {type:"stderr", created:900, payload:{text:"npm ERR! code ELIFECYCLE"}},
    {type:"stdout", created:901, payload:{text:"Error: Command \"npm run build\" exited with 1"}}
  ]'
}
(
  lib || { echo "  FAIL U4 source"; exit 1; }
  f=0
  chk() { [ "$2" = "$3" ] && echo "  ok   U4 $1" || { echo "  FAIL U4 $1: got '$2' want '$3'"; f=1; }; }
  ev_json 3 > "$T/u4.json"
  out=$(insp_quote "$T/u4.json" 30); rc=$?
  chk "rc 0" "$rc" 0
  chk "the step is the last command event" "$(head -1 <<<"$out")" 'Running "build" command: `npm run build`'
  chk "5 lines quoted (3 failed, ERR!, Error:)" "$(tail -n +2 <<<"$out" | grep -c .)" 5
  chk "plain stdout dropped" "$(grep -c 'optimized production' <<<"$out")" 0
  chk "the stderr line kept" "$(grep -c '^npm ERR! code ELIFECYCLE$' <<<"$out")" 1
  chk "the last line is the exit line" "$(tail -1 <<<"$out")" 'Error: Command "npm run build" exited with 1'
  ev_json 45 > "$T/u4.json"
  out=$(insp_quote "$T/u4.json" 30)
  chk "47 matching lines give the last 30" "$(tail -n +2 <<<"$out" | grep -c .)" 30
  chk "the first kept line is #17 of the failed ones" "$(sed -n 2p <<<"$out")" "Type error: line 17 failed"
  jq -nc --arg x "Error: $(printf 'x%.0s' $(seq 1 900))" '[{type:"command",payload:{text:"build"}},{type:"stderr",payload:{text:$x}}]' > "$T/u4.json"
  chk "a 900-char line is cut to 300" "$(insp_quote "$T/u4.json" 30 | sed -n 2p | awk '{print length($0)}')" 300
  chk "chars 120: a 900-char line is cut to 120" "$(insp_quote "$T/u4.json" 30 120 | sed -n 2p | awk '{print length($0)}')" 120
  chk "chars 120: the short step is kept" "$(insp_quote "$T/u4.json" 30 120 | sed -n 1p)" build
  # determinism: ok a fixed fixture string shaped like a token, never a real one
  TOKSHAPE="ghp_$(printf 'a%.0s' $(seq 1 36))"
  jq -nc --arg a "Error: auth $TOKSHAPE refused" '[{type:"stderr",payload:{text:$a}},{type:"stderr",payload:{text:"failed with API_KEY=abc123fixture and NPM_TOKEN=xyzfixture"}}]' > "$T/u4.json"
  out=$(insp_quote "$T/u4.json" 30)
  chk "no command event: the step is -" "$(head -1 <<<"$out")" -
  chk "the ghp_ token is redacted" "$(grep -c 'ghp_a' <<<"$out")" 0
  chk "the github redaction marker is there" "$(grep -c '<redacted:github-token>' <<<"$out")" 1
  chk "the API_KEY and NPM_TOKEN values are gone" "$(grep -c 'abc123fixture\|xyzfixture' <<<"$out")" 0
  chk "both values are marked redacted" "$(sed -n 3p <<<"$out" | grep -o '_\(KEY\|TOKEN\)=<redacted>' | grep -c .)" 2
  # Redaction runs before the cut: a token that crosses the cut leaves no fragment.
  jq -nc --arg a "Error: $(printf 'x%.0s' $(seq 1 280)) $TOKSHAPE" '[{type:"stderr",payload:{text:$a}}]' > "$T/u4.json"
  chk "a token across the 300-char cut leaves no ghp_ fragment" "$(insp_quote "$T/u4.json" 30 | grep -c 'ghp_')" 0
  # The name filter is case-insensitive, and a Bearer credential is redacted.
  jq -nc '[{type:"stderr",payload:{text:"failed password=pwfixture1 apiKey=akfixture2 client_secret=csfixture3"}},
           {type:"stderr",payload:{text:"Error: Authorization: Bearer brfixture4 refused"}}]' > "$T/u4.json"
  out=$(insp_quote "$T/u4.json" 30)
  chk "lower- and mixed-case secret values are gone" "$(grep -c 'pwfixture1\|akfixture2\|csfixture3' <<<"$out")" 0
  chk "the Bearer value is gone" "$(grep -c 'brfixture4' <<<"$out")" 0
  chk "the names stay, marked redacted" "$(grep -o 'password=<redacted>\|apiKey=<redacted>\|client_secret=<redacted>\|Bearer <redacted>' <<<"$out" | grep -c .)" 4
  jq -nc '[{type:"command",payload:{text:"build"}},{type:"stdout",payload:{text:"all good"}}]' > "$T/u4.json"
  insp_quote "$T/u4.json" 30 >/dev/null; chk "no error line: rc 1" "$?" 1
  printf '{"error":"x"}' > "$T/u4.json"; insp_quote "$T/u4.json" 30 >/dev/null; chk "not an array: rc 1" "$?" 1
  printf 'not json' > "$T/u4.json"; insp_quote "$T/u4.json" 30 >/dev/null; chk "not JSON: rc 1" "$?" 1
  jq -nc '[{type:"stderr",payload:{text:"Error: ``` fence"}}]' > "$T/u4.json"
  chk "a triple backtick cannot close the fence" "$(insp_quote "$T/u4.json" 30 | grep -c '```')" 0
  exit "$f"
) && ok "U4 insp_quote" || bad "U4 insp_quote"

# --- the scratch harness ------------------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/staff" "$H/logs" "$H/locks" "$H/state/served-sha-watch" "$H/env" "$H/flags" "$T/bin" "$T/gh-posts"
# The lane sources each lib as "$H/..." || "$LIBD/...", so each one's closure is installed too.
for L in "$INSP_REL" bin/jobs-client.sh bin/lib/staff-contract.sh bin/lib/console-pages.sh bin/lib/lane-gate.sh \
         bin/lib/served-sha-watch.sh bin/lib/served-sha-watch.d/30-prodbehind.sh bin/lib/endpoints.sh \
         bin/lib/gh-app-auth.sh bin/lib/gh-rest-list.sh bin/lib/tracker/github-issues.sh bin/lib/token-redact.sh bin/lib/deployment.sh bin/lib/env-path.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
for L in bin/jobs-client.sh bin/lib/staff-contract.sh bin/lib/console-pages.sh bin/lib/lane-gate.sh bin/lib/served-sha-watch.sh \
         bin/lib/served-sha-watch.d/30-prodbehind.sh bin/lib/endpoints.sh bin/lib/gh-app-auth.sh bin/lib/gh-rest-list.sh \
         bin/lib/tracker/github-issues.sh bin/lib/token-redact.sh bin/lib/deployment.sh; do
  [ -s "$H/$L" ] || bad "setup: the closure lacks $L"
done
chmod +x "$H/bin/"*.sh "$H/bin/staff/"*.sh 2>/dev/null
printf 'project-3 team_fixture prj_fixture_project-3 project-3.example\n' > "$H/vercel.conf"
printf '{"token":"tok-fixture-vercel"}\n' > "$T/vauth.json"
printf 'CLOUDFLARE_API_TOKEN=tok-fixture-cloudflare\nCLOUDFLARE_ACCOUNT_ID=acct_fixture\n' > "$H/env/cloudflare.env"

# The gh stub: one argv line per call; the gh api -i envelope from
# tests/lib/gh-rest-stub.sh. GET repos/<r>/issues answers $T/gh-issues.json
# on page 1 ([] on later pages; 100 rows a page with $T/gh-issues-many);
# POST repos/<r>/issues answers 201 (or $T/gh-st-post) and, on a 201 only,
# stores the --input body as $T/gh-posts/<n>.json. $T/gh-st-list overrides the list status.
cat > "$T/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.log"
GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"
m=""; p=""; inp=""; page=1; a=("\$@")
for ((i = 0; i < \${#a[@]}; i++)); do
  case "\${a[i]}" in
    -X) m=\${a[i+1]}; p=\${a[i+2]} ;;
    --input) inp=\${a[i+1]} ;;
    page=*) page=\${a[i]#page=} ;;
  esac
done
case "\$m \$p" in
  "GET repos/"*/issues)
    if [ -f "$T/gh-issues-many" ]; then _ghs_send 200 "\$(jq -nc --argjson p "\$page" '[range(100) | {number:(\$p * 1000 + .), state:"open", body:"", html_url:"https://github.com/example/fixture/issues/1"}]')"
    elif [ "\$page" = 1 ]; then _ghs_send "\$(_ghs_st list 200)" "\$(cat "$T/gh-issues.json" 2>/dev/null || echo '[]')"
    else _ghs_send 200 '[]'; fi ;;
  "POST repos/"*/issues)
    n=\$((\$(ls "$T/gh-posts" | wc -l) + 1)); st=\$(_ghs_st post 201)
    [ "\$st" = 201 ] && cp "\$inp" "$T/gh-posts/\$n.json"
    _ghs_send "\$st" "{\"number\":\$n,\"html_url\":\"https://github.com/example/fixture/issues/\$n\"}" ;;
  *) _ghs_send 404 '{"message":"Not Found"}' ;;
esac
EOF
chmod +x "$T/bin/gh"
# The stub reads $GHT/st-<route>; map the suite's names onto it.
ln -sf "$T/gh-st-list" "$T/st-list"; ln -sf "$T/gh-st-post" "$T/st-post"

export PATH="$T/bin:$PATH"
export HARNESS="$H" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=fixture-harness-secret HARNESS_CHECKOUT="$HCO"
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 BOX_NAME=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0 SERVED_SHA_VERCEL_AUTH="$T/vauth.json"
export STAFF_FILE_REPO=example/fixture GH_APP_TOKENS=0
unset STAFF_ENABLED INSPECTOR_LIB_ONLY GH_TOKEN SERVED_SHA_CONF CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
: > "$T/w.log"; : > "$T/w.port"; printf '{}' > "$T/fx.json"
node "$SRV" "$T/w.log" "$T/fx.json" > "$T/w.port" 2> "$T/w.err" &
SPID=$!; PIDS+=("$SPID")
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: server did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT" ENDPOINT_VERCEL="http://127.0.0.1:$PORT" INSPECTOR_CF_BASE="http://127.0.0.1:$PORT/cf"
: > "$T/all-w.log"; : > "$T/gh-argv.log"

jsql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
setk() { jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('$1','$2','t','test','2026-11-12T00:00:00Z')"; }
delk() { jsql "DELETE FROM settings WHERE key='$1'"; }
seedv() { jget "SELECT value FROM settings WHERE key='$1'" | jq -r '.[0].value'; }

# --- I0 the seed rows, read back from the composed schema ---------------------------
eq "I0 seed staff.inspector.lever_dry_run" "$(seedv staff.inspector.lever_dry_run)" 1
eq "I0 seed staff.inspector.quote_lines" "$(seedv staff.inspector.quote_lines)" 30
eq "I0 seed staff.inspector.fresh_min" "$(seedv staff.inspector.fresh_min)" 20
eq "I0 seed staff.inspector.lever_max_run" "$(seedv staff.inspector.lever_max_run)" 1
eq "I0 seed staff.inspector.issue_list_max" "$(seedv staff.inspector.issue_list_max)" 1000
eq "I0 seed staff.inspector.quote_line_chars" "$(seedv staff.inspector.quote_line_chars)" 300
eq "I0 seed staff.inspector.level (C0) is observe" "$(seedv staff.inspector.level)" observe

SD="$H/state/served-sha-watch"
# fx_set <jq expr> — edit the vendor fixture file
fx_set() { jq -c "$1" "$T/fx.json" > "$T/fx.tmp" && mv "$T/fx.tmp" "$T/fx.json"; }
# deploy <projectId> <uid> <STATE> [status] — the newest production deployment
deploy() {
  jq -c --arg p "$1" --arg u "$2" --arg s "$3" --argjson st "${4:-200}" --arg sha "$B" \
    '.deployments[$p] = {status:$st, body:{deployments:[{uid:$u, created:1790000000000, target:"production", state:$s, meta:{githubCommitSha:$sha}}]}}' \
    "$T/fx.json" > "$T/fx.tmp" && mv "$T/fx.tmp" "$T/fx.json"
}
events() { # events <uid> [n matching] [status]
  ev_json "${2:-3}" > "$T/ev.json"
  jq -c --arg u "$1" --argjson st "${3:-200}" --slurpfile e "$T/ev.json" '.events[$u] = {status:$st, body:$e[0]}' \
    "$T/fx.json" > "$T/fx.tmp" && mv "$T/fx.tmp" "$T/fx.json"
}
console() { jq -c --argjson b "$(cf "$1")" '.cf = {status:200, body:$b}' "$T/fx.json" > "$T/fx.tmp" && mv "$T/fx.tmp" "$T/fx.json"; }
watchlog() { summary_line "$((NOW0 - ${1:-300}))" "$(grep -c . "$H/vercel.conf")" > "$H/logs/served-sha-watch.log"; }
# behind <p> <hours> [verdict] — a state file the watch wrote 5 min ago
behind() { state "$SD" "$1" "${3:-alert}" "$(awk -v n="$NOW0" -v h="$2" 'BEGIN{printf "%d", n - h * 3600}')" "$((NOW0 - 300))"; }
# RESET: no inspector rows, the seed's inspector settings, the roster active, a
# clean log and request logs, Vercel in sync, the console in sync.
RESET() {
  cat "$T/w.log" >> "$T/all-w.log" 2>/dev/null
  jsql "DELETE FROM staff_lever_actions WHERE agent='inspector'; DELETE FROM staff_metric_samples WHERE agent='inspector';
        UPDATE staff_agents SET status='active' WHERE name='inspector'"
  setk staff.inspector.level observe; setk staff.inspector.target 2; setk staff.inspector.file_max_day 3
  setk staff.inspector.lever_dry_run 1; setk staff.inspector.quote_lines 30; setk staff.inspector.fresh_min 20
  setk staff.inspector.lever_max_run 1; setk staff.inspector.issue_list_max 1000; setk staff.inspector.quote_line_chars 300
  rm -f "$H"/flags/* "$SD"/*.json "$T"/gh-posts/* "$T/gh-issues.json" "$T/gh-issues-many" "$T/gh-st-list" "$T/gh-st-post" 2>/dev/null
  printf 'project-3 team_fixture prj_fixture_project-3 project-3.example\n' > "$H/vercel.conf"
  printf '{}' > "$T/fx.json"; console "$C3"; watchlog
  : > "$H/logs/staff-inspector-lever.log"; : > "$H/logs/ALERTS.log"; : > "$T/w.log"
}
run() { INSPECTOR_NOW="${1:-$NOW0}" "$H/$INSP_REL" > "$T/run.out" 2>&1; RC=$?; }
last() { tail -1 "$H/logs/staff-inspector-lever.log"; }
field() { tr ' ' '\n' <<<"$(last)" | sed -n "s/^$1=//p" | head -1; }
nactions() { grep -c '^POST /api/staff/levers/actions ' "$T/w.log"; }
nsamples() { grep -c '^POST /api/staff/levers/metric ' "$T/w.log"; }
nevents() { grep -c '^GET /v3/deployments/' "$T/w.log"; }
ghmark() { cat "$T/gh-argv.log" >> "$T/gh-argv.all" 2>/dev/null; : > "$T/gh-argv.log"; }
nposts() { ls "$T/gh-posts" | grep -c .; }
rows() { jget "SELECT dry_run, metric_before, lever, target, detail, metric_after, moved, settled_at, action_key FROM staff_lever_actions WHERE agent='inspector' ORDER BY id"; }
samples() { jget "SELECT value, detail, metric FROM staff_metric_samples WHERE agent='inspector' ORDER BY id"; }
ngcalls() { grep -c . "$T/gh-argv.log"; }

# --- I1 level observe ------------------------------------------------------------------
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
run
eq "I1 rc" "$RC" 0
S=$(samples)
eq "I1 one sample" "$(jq length <<<"$S")" 1
eq "I1 sample metric and value" "$(jq -r '.[0] | "\(.metric) \(.value)"' <<<"$S")" "hours_behind_main 5"
has "I1 sample detail names the project" "$(jq -r '.[0].detail' <<<"$S")" "vercel=project-3:5.00"
has "I1 sample detail names the console" "$(jq -r '.[0].detail' <<<"$S")" "console=0.00"
eq "I1 0 action rows" "$(rows | jq length)" 0
eq "I1 0 action POSTs" "$(nactions)" 0
eq "I1 0 gh calls" "$(ngcalls)" 0
eq "I1 0 build-log reads" "$(nevents)" 0
eq "I1 summary level/hours/sample/action" "$(field level) $(field hours) $(field sample) $(field action)" "observe 5.00 ok none"

# --- I2 console behind 3 h, Vercel in sync ---------------------------------------------
RESET; ghmark; console "$C1"; setk staff.inspector.level file
run
S=$(samples)
eq "I2 sample value" "$(jq -r '.[0].value' <<<"$S")" 3
has "I2 detail console=3.00" "$(jq -r '.[0].detail' <<<"$S")" "console=3.00"
eq "I2 0 actions (the console has no lever)" "$(rows | jq length)" 0
eq "I2 0 gh calls" "$(ngcalls)" 0
eq "I2 summary vercel/console" "$(field vercel) $(field console)" "0.00 3.00"

# --- I3 level file with the seeded dry row; level act;rm -------------------------------
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file
run
R=$(rows)
eq "I3 one action row" "$(jq length <<<"$R")" 1
eq "I3 row dry_run/metric_before/lever/target" "$(jq -r '.[0] | "\(.dry_run) \(.metric_before) \(.lever) \(.target)"' <<<"$R")" "1 5 fix-main-red project-3"
eq "I3 0 gh calls" "$(ngcalls)" 0
eq "I3 one build-log read" "$(nevents)" 1
eq "I3 summary action/dry/project/filed" "$(field action) $(field dry) $(field project) $(field filed)" "recorded 1 project-3 dry"
grep -q 'dry fix-main-red: project-3 .*step: Running "build" command' "$H/logs/staff-inspector-lever.log" \
  && ok "I3 the dry line names the title and the step" || bad "I3 dry line: $(cat "$H/logs/staff-inspector-lever.log")"
for lv in 'act;rm' files NOROW; do
  RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
  if [ "$lv" = NOROW ]; then delk staff.inspector.level; else setk staff.inspector.level "$lv"; fi
  run
  eq "I3 [$lv] 0 action rows" "$(rows | jq length)" 0
  eq "I3 [$lv] level observe in the summary" "$(field level)" observe
  eq "I3 [$lv] 1 sample" "$(samples | jq length)" 1
done
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level ' FILE '; run
eq "I3 [' FILE '] one action (trimmed, lowercased)" "$(rows | jq length)" 1
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level act; setk staff.inspector.lever_dry_run abc; run
eq "I3 [act, dry row abc] one dry action" "$(rows | jq -r '.[0].dry_run')" 1
eq "I3 [act, dry row abc] 0 gh calls" "$(ngcalls)" 0

# --- I4 (Acc 2) live: one action -> the outcome row --------------------------------------
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0
run
R=$(rows)
eq "I4 one action row" "$(jq length <<<"$R")" 1
eq "I4 row dry_run 0, metric_before 5" "$(jq -r '.[0] | "\(.dry_run) \(.metric_before)"' <<<"$R")" "0 5"
eq "I4 one issue POST" "$(nposts)" 1
eq "I4 summary action/dry/filed" "$(field action) $(field dry) $(field filed)" "recorded 0 new"
has "I4 summary carries the issue url" "$(last)" "filed=new https://github.com/example/fixture/issues/1"
eq "I4 one list read before the POST" "$(grep -c 'GET repos/example/fixture/issues' "$T/gh-argv.log")" 1
has "I4 the list asks for all states and the label" "$(grep 'GET repos/example/fixture/issues' "$T/gh-argv.log")" "state=all"
has "I4 the list asks for the label" "$(grep 'GET repos/example/fixture/issues' "$T/gh-argv.log")" "labels=staff:inspector"
cp "$T/gh-posts/1.json" "$T/i4-post.json"
EP_SINCE=$((NOW0 - 5 * 3600))
# Prod catches up; 25 h later the next sample (0) settles the action.
rm -f "$SD/project-3.json"
jsql "UPDATE staff_lever_actions SET acted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-25 hours') WHERE agent='inspector'"
watchlog -$((25 * 3600 - 300)); run "$((NOW0 + 25 * 3600))"
R=$(rows)
eq "I4 the action settled: metric_after 0, moved 1" "$(jq -r '.[0] | "\(.metric_after) \(.moved)"' <<<"$R")" "0 1"
SC=$(curl -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/staff/levers/scorecard?agent=inspector&days=7")
eq "I4 scorecard actions/settled/moved/precision" "$(jq -r '"\(.actions) \(.settled) \(.moved) \(.precision)"' <<<"$SC")" "1 1 1 1"
eq "I4 scorecard metric" "$(jq -r '.metric' <<<"$SC")" hours_behind_main

# --- I5 the issue body -------------------------------------------------------------------
P="$T/i4-post.json"
TITLE=$(jq -r '.title' "$P"); BODY=$(jq -r '.body' "$P")
eq "I5 title" "$TITLE" "fix-main-red: project-3 prod ${A:0:8} behind main ${B:0:8} for 5.00h"
[ "${#TITLE}" -le 80 ] && ok "I5 title at most 80 chars" || bad "I5 title is ${#TITLE} chars"
eq "I5 label" "$(jq -r '.labels | join(",")' "$P")" staff:inspector
has "I5 body names the served sha" "$BODY" "$A"
has "I5 body names the head sha" "$BODY" "$B"
has "I5 body names the deployment" "$BODY" "dpl_fixture_project-3"
has "I5 body quotes the step" "$BODY" 'Running "build" command: `npm run build`'
has "I5 body has the vercel inspect line" "$BODY" "vercel inspect dpl_fixture_project-3 --logs --scope team_fixture"
has "I5 body has the episode marker" "$BODY" "<!-- inspector-fmr:project-3@$EP_SINCE -->"
has "I5 body has the project marker" "$BODY" "<!-- inspector-fmr-project:project-3 -->"
Q=$(awk '/^```text$/{f=1; next} /^```$/{f=0} f' <<<"$BODY")
eq "I5 the fence holds the 5 quoted lines" "$(grep -c . <<<"$Q")" 5
eq "I5 the fence ends with the exit line" "$(tail -1 <<<"$Q")" 'Error: Command "npm run build" exited with 1'
hasnt "I5 no em dash" "$TITLE $BODY" "—"

# I5 the quote_line_chars row cuts each quoted line.
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0; setk staff.inspector.quote_line_chars 20
run
Q=$(jq -r '.body' "$T/gh-posts/1.json" 2>/dev/null | awk '/^```text$/{f=1; next} /^```$/{f=0} f')
eq "I5 [quote_line_chars 20] the exit line is cut to 20" "$(tail -1 <<<"$Q")" 'Error: Command "npm '
eq "I5 [quote_line_chars 20] no quoted line over 20" "$(awk 'length($0) > 20' <<<"$Q" | grep -c .)" 0

# I5 dry first, then live, in ONE episode: the live key never collides with
# the dry one, so the move to live records a new row and files.
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; run
setk staff.inspector.lever_dry_run 0; run
eq "I5 [dry then live] two rows, dry then live" "$(rows | jq -r '[.[].dry_run] | join(",")')" "1,0"
eq "I5 [dry then live] the live run recorded and filed" "$(field action) $(field dry) $(field filed)" "recorded 0 new"
eq "I5 [dry then live] one issue" "$(nposts)" 1

# --- I6 an unreadable part ------------------------------------------------------------------
for k in no-summary old-summary bad-state cf-false TK-500 no-cf-token; do
  RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
  setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0
  case "$k" in
    no-summary) : > "$H/logs/served-sha-watch.log" ;;
    old-summary) watchlog $((21 * 60)) ;;
    bad-state) printf '{"head":' > "$SD/project-3.json" ;;
    cf-false) fx_set '.cf = {status:200, body:{success:false, errors:[{code:10000, message:"Authentication error"}]}}' ;;
    TK-500) fx_set '.cf = {status:500, body:{success:false}}' ;;
    no-cf-token) mv "$H/env/cloudflare.env" "$T/cf.env.off" ;;
  esac
  run
  [ "$k" = no-cf-token ] && mv "$T/cf.env.off" "$H/env/cloudflare.env"
  eq "I6 [$k] rc" "$RC" 0
  eq "I6 [$k] 0 samples" "$(samples | jq length)" 0
  eq "I6 [$k] 0 actions" "$(rows | jq length)" 0
  eq "I6 [$k] 0 gh calls" "$(ngcalls)" 0
  eq "I6 [$k] hours=unreadable" "$(field hours)" unreadable
  case "$k" in cf*|no-cf*) part=console ;; *) part=vercel ;; esac
  grep -q "$part part unreadable" "$H/logs/staff-inspector-lever.log" && ok "I6 [$k] the log names the $part part" \
    || bad "I6 [$k] log: $(cat "$H/logs/staff-inspector-lever.log")"
done

# --- I7 two projects -------------------------------------------------------------------------
RESET; ghmark
printf 'project-3 team_fixture prj_fixture_project-3 project-3.example\nbeta team_fixture prj_fixture_beta beta.example\n' > "$H/vercel.conf"; watchlog
behind project-3 3; behind beta 6
deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
deploy prj_fixture_beta dpl_fixture_beta ERROR; events dpl_fixture_beta
setk staff.inspector.level file
run
eq "I7 sample is the max" "$(samples | jq -r '.[0].value')" 6
has "I7 detail names both" "$(samples | jq -r '.[0].detail')" "project-3:3.00"
eq "I7 lever_max_run 1: one action" "$(rows | jq length)" 1
eq "I7 the oldest (6 h) project first" "$(rows | jq -r '.[0].target')" beta
run
eq "I7 lever_max_run 1: a recorded-earlier beta does not use the slot; the second run adds project-3" "$(rows | jq -r '[.[].target] | sort | join(",")')" "beta,project-3"
setk staff.inspector.lever_max_run 2; run
eq "I7 lever_max_run 2: the second run adds project-3 (beta already recorded)" "$(rows | jq -r '[.[].target] | sort | join(",")')" "beta,project-3"

# --- I8 the negatives ---------------------------------------------------------------------
for k in 1.99h READY BUILDING CANCELED list500 events500 noerrlines; do
  RESET; ghmark; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
  setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0
  behind project-3 5
  case "$k" in
    1.99h) behind project-3 1.99 ;;
    READY|BUILDING|CANCELED) deploy prj_fixture_project-3 dpl_fixture_project-3 "$k" ;;
    list500) deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR 500 ;;
    events500) events dpl_fixture_project-3 3 500 ;;
    noerrlines) fx_set '.events.dpl_fixture_project-3 = {status:200, body:[{type:"command",payload:{text:"build"}},{type:"stdout",payload:{text:"ok"}}]}' ;;
  esac
  run
  eq "I8 [$k] rc" "$RC" 0
  eq "I8 [$k] one sample" "$(samples | jq length)" 1
  eq "I8 [$k] 0 action rows" "$(rows | jq length)" 0
  eq "I8 [$k] 0 gh calls" "$(ngcalls)" 0
  case "$k" in
    events500|noerrlines) eq "I8 [$k] action=log-unreadable" "$(field action)" log-unreadable ;;
    1.99h) eq "I8 [$k] no deploy read" "$(grep -c '^GET /v6/deployments' "$T/w.log")" 0 ;;
    *) eq "I8 [$k] action=none" "$(field action)" none ;;
  esac
done
RESET; ghmark; behind project-3 2.00; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; run
eq "I8 [2.00h] is a candidate" "$(rows | jq length)" 1

# --- I9 the delivery dedupe ------------------------------------------------------------------
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0
setk staff.inspector.file_max_day 10   # this case files 4 episodes; I10 owns the cap
run
eq "I9 first live run files" "$(nposts)" 1
# The issue is closed, then the same episode is seen again one hour later.
jq -c '[{number:1, state:"closed", html_url:"https://github.com/example/fixture/issues/1", body:.body}]' "$T/gh-posts/1.json" > "$T/gh-issues.json"
: > "$T/w.log"; watchlog -3300; run "$((NOW0 + 3600))"
grep -q '^POST /api/staff/levers/actions 409' "$T/w.log" && ok "I9 the real route answered 409 (metricBefore 6 vs 5)" || bad "I9 actions: $(grep actions "$T/w.log")"
eq "I9 recorded-earlier, already" "$(field action) $(field filed)" "recorded-earlier already"
eq "I9 0 new POST" "$(nposts)" 1
eq "I9 still one action row" "$(rows | jq length)" 1
# The same episode, same value: existing:true, the same answer.
watchlog; run "$NOW0"
eq "I9 [same value] recorded-earlier, already" "$(field action) $(field filed)" "recorded-earlier already"
# A new episode with an open issue for the project.
jq -c '[{number:1, state:"open", html_url:"https://github.com/example/fixture/issues/1", body:.body}]' "$T/gh-posts/1.json" > "$T/gh-issues.json"
behind project-3 3
run
eq "I9 [new episode, open issue] recorded, open-reused" "$(field action) $(field filed)" "recorded open-reused"
eq "I9 [new episode, open issue] 0 new POST" "$(nposts)" 1
# The list cannot be read: no POST; the next run retries the delivery.
touch "$T/gh-issues-many"; behind project-3 4; run
eq "I9 [1000-row list] list-unreadable" "$(field filed)" list-unreadable
eq "I9 [1000-row list] 0 new POST" "$(nposts)" 1
# The issue_list_max row bounds the list read: 200 rows = 2 pages, then list-unreadable.
ghmark; setk staff.inspector.issue_list_max 200; behind project-3 4.5; run
eq "I9 [issue_list_max 200] list-unreadable" "$(field filed)" list-unreadable
eq "I9 [issue_list_max 200] 2 list pages read" "$(grep -c 'GET repos/example/fixture/issues' "$T/gh-argv.log")" 2
eq "I9 [issue_list_max 200] 0 new POST" "$(nposts)" 1
setk staff.inspector.issue_list_max 1000
rm -f "$T/gh-issues-many"; printf '[]' > "$T/gh-issues.json"; printf '500' > "$T/gh-st-post"; run
eq "I9 [POST 500] recorded-earlier, failed" "$(field action) $(field filed)" "recorded-earlier failed"
rm -f "$T/gh-st-post"; run
eq "I9 [retry] recorded-earlier, new" "$(field action) $(field filed)" "recorded-earlier new"
eq "I9 [retry] the episode is filed once" "$(nposts)" 2

# Record before act: the action route fails (an insert the DB refuses), so the
# lane makes no GitHub call at all.
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0
jsql "CREATE TRIGGER fixture_refuse_action BEFORE INSERT ON staff_lever_actions BEGIN SELECT RAISE(ABORT, 'fixture refuse'); END"
run
jsql "DROP TRIGGER fixture_refuse_action"
grep -qE '^POST /api/staff/levers/actions 5[0-9][0-9]' "$T/w.log" && ok "I9 [action refused] the route answered 5xx" || bad "I9 [action refused] log: $(grep actions "$T/w.log")"
eq "I9 [action refused] action=failed" "$(field action)" failed
eq "I9 [action refused] 0 gh calls" "$(ngcalls)" 0
eq "I9 [action refused] 0 POSTs" "$(nposts)" 0

# --- I10 the day cap ---------------------------------------------------------------------------
seed_actions() { # seed_actions <n> <dry 0|1>
  local i
  for i in $(seq 1 "$1"); do
    jsql "INSERT INTO staff_lever_actions (action_key, agent, lever, target, dry_run, metric, metric_before, acted_at)
      VALUES ('fixture-cap-$2-$i','inspector','fix-main-red','seed$i',$2,'hours_behind_main',5,strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hours'))"
  done
}
for k in live3:day-cap live2:recorded dry3:recorded abc:day-cap zero:day-cap neg:day-cap; do
  RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
  setk staff.inspector.level file
  case "${k%%:*}" in
    live3) seed_actions 3 0 ;; live2) seed_actions 2 0 ;; dry3) seed_actions 3 1 ;;
    abc) seed_actions 3 0; setk staff.inspector.file_max_day abc ;;
    zero) seed_actions 3 0; setk staff.inspector.file_max_day 0 ;;
    neg) seed_actions 3 0; setk staff.inspector.file_max_day -1 ;;
  esac
  run
  eq "I10 [$k]" "$(field action)" "${k#*:}"
  eq "I10 [$k] action POSTs" "$(nactions)" "$([ "${k#*:}" = day-cap ] && echo 0 || echo 1)"
done
RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
setk staff.inspector.level file; jsql "ALTER TABLE staff_lever_actions RENAME TO sla_fixture_off"; run
jsql "ALTER TABLE sla_fixture_off RENAME TO staff_lever_actions"
eq "I10 [scorecard unreadable] action" "$(field action)" scorecard-unreadable
eq "I10 [scorecard unreadable] 0 action POSTs" "$(nactions)" 0

# --- I11 the kill switches ---------------------------------------------------------------------
for k in flag:staff-off-inspector flag:staff-kill-inspector flag:staff-off-all flag:staff-kill-all env:STAFF_ENABLED=0 \
         lane:lane-off-staff-inspector-lever roster:paused; do
  RESET; ghmark; behind project-3 5; deploy prj_fixture_project-3 dpl_fixture_project-3 ERROR; events dpl_fixture_project-3
  setk staff.inspector.level file; setk staff.inspector.lever_dry_run 0; : > "$T/w.log"
  case "$k" in
    flag:*) : > "$H/flags/${k#flag:}"; run ;;
    env:*) STAFF_ENABLED=0 run ;;
    lane:*) : > "$H/flags/${k#lane:}"; LANE_GATE_DISABLE=0 run ;;
    roster:*) jsql "UPDATE staff_agents SET status='paused' WHERE name='inspector'"; : > "$T/w.log"; run ;;
  esac
  eq "I11 [$k] rc" "$RC" 0
  # The kill check reads the flag rows (flag_active), the lane gate reports
  # flag-seen and liveness, and the roster check reads the roster row.
  OWN=$(grep -vE '^(GET /api/flags/|POST /api/lanes/(flag-seen|liveness) |GET /api/staff/agent\?name=inspector )' "$T/w.log")
  eq "I11 [$k] 0 inspector requests" "$(grep -c . <<<"$OWN")" 0
  eq "I11 [$k] 0 gh calls" "$(ngcalls)" 0
done
RESET; : > "$H/flags/staff-off-inspector"; run
grep -q 'killed by staff-off-inspector' "$H/logs/staff-inspector-lever.log" && ok "I11 one 'killed by' line" || bad "I11 log: $(cat "$H/logs/staff-inspector-lever.log")"

# --- I12 no call left the box -------------------------------------------------------------------
RESET; ghmark
ALLW=$(cat "$T/all-w.log")
eq "I12 the world saw requests" "$([ "$(grep -c . <<<"$ALLW")" -gt 50 ] && echo yes || echo no)" yes
eq "I12 every request went to 127.0.0.1" "$(grep -vc " host=127.0.0.1:$PORT\$" <<<"$ALLW")" 0
eq "I12 the world saw Vercel reads" "$([ "$(grep -c '^GET /v6/deployments' <<<"$ALLW")" -gt 0 ] && echo yes || echo no)" yes
eq "I12 the world saw Cloudflare reads" "$([ "$(grep -c '^GET /cf/accounts/acct_fixture/pages/projects/mission-control ' <<<"$ALLW")" -gt 0 ] && echo yes || echo no)" yes
GHA=$(cat "$T/gh-argv.all" 2>/dev/null)
eq "I12 the gh stub saw calls" "$([ "$(grep -c . <<<"$GHA")" -gt 0 ] && echo yes || echo no)" yes
eq "I12 the gh argv names no host" "$(grep -cE 'https?://|--hostname|api\.github\.com' <<<"$GHA")" 0
eq "I12 the gh argv only names the fixture repo" "$(grep -vc 'repos/example/fixture/issues' <<<"$GHA")" 0

echo "staff-inspector-lever.bh-9419: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
