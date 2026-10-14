#!/bin/bash
# tests/mc-diff-local.bh-5914-test.sh — BH-5914: a diff the GitHub API will
# not serve (HTTP 406, "too large") is read from a local git clone, so the
# iron-law scan still runs over EVERY file; and the conductor publishes its
# verdict per head.
#
# THE INCIDENT (example-org/project-6 PR #27, 2026-10-10): 837 files, +175,936
# lines. GET /pulls/27 with the diff media type answered 406, the conductor
# logged "diff read UNVERIFIABLE (HTTP 406) — iron-law scan NOT run" every
# tick, and the PR could never pass the scan through the API.
#
# THE REVIEW (5da26c71): the first cut left files over a line limit out of the
# scanned diff and then published `clear`. A 406 PR with one 20,001-line file
# holding a claude-* literal would have MERGED, where before it was held. So:
# every text file is scanned, whatever its size (the scan reads line by line),
# and a file with no text to scan (binary) HOLDS, never clears.
#
# The functions are extracted VERBATIM from bin/lib/mc/classify.sh, and the
# conductor's two blocks (# >>> iron-law diff read, # >>> merge verdict
# publish) VERBATIM from bin/merge-conductor.sh, and run against a real local
# git origin. Stubs replace only the network edges (mc_pr_diff,
# mc_rest_status, mc_funnel_repo's auth), the ledger client and the memo.
#   L1 406: every file is read, so the literal inside a 20,001-line file
#      counts: 2 hits, both named
#   L2 406 with a binary file: rc 3, MC_DIFF_UNSCANNED=1, the file named
#   L3 a 502 and a 403 fall back to the local diff too (BH-6000: any failure of
#      the API read, not only a 406), and the log names the status
#   L4 the fetched PR head is not the head the conductor read: rc 75
#   L5 the API answers: its diff is used, no clone touched
#   H1 THE REVIEW'S CASE, through the conductor's blocks: a 406 PR whose
#      20,001-line file holds a claude-* literal is HELD with the hit named,
#      and never cleared
#   H2 a 406 PR with a binary file and no hits is HELD ("not scanned"), and
#      the scan count is NOT stored in the memo
#   H3 a clean 406 PR (text only, no hits) is cleared and its scan memoised
#   P1-P4 mc_merge_verdict_put: one PUT per (head, status), a failed PUT is
#      retried next tick, detail is "<head> <reason>"
#   W1-W3 the wiring: the conductor's scan reads through mc_pr_diff_or_local
#      and publishes hold/clear; merge-queue's mq_land asks the gate
# Run from anywhere: tests/mc-diff-local.bh-5914-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v jq >/dev/null || { echo "FAIL: git/jq missing"; exit 1; }

CL="$DIR/bin/lib/mc/classify.sh"
MC="$DIR/bin/merge-conductor.sh"
# One function by name: from `name() {` to its closing `}` at column 0, or the
# one line when the body closes on the same line.
fn() { awk -v n="$1" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "$CL"; }
for f in mc_iron_law_scan mc_iron_law_names mc_handoff_id mc_pr_diff_local mc_pr_diff_or_local mc_merge_verdict_put; do
  fn "$f" >> "$T/fns.sh"
  grep -qE "^$f\(\)[[:space:]]*\{" "$T/fns.sh" && ok || bad "could not extract $f from bin/lib/mc/classify.sh"
done
awk '/# >>> iron-law diff read/{f=1;next} /# <<< iron-law diff read/{exit} f' "$MC" > "$T/read.sh"
awk '/# >>> merge verdict publish/{f=1;next} /# <<< merge verdict publish/{exit} f' "$MC" > "$T/publish.sh"
[ -s "$T/read.sh" ] && ok || bad "could not extract the conductor's iron-law diff read block"
[ -s "$T/publish.sh" ] && ok || bad "could not extract the conductor's merge verdict publish block"

# --- the fixture origin ------------------------------------------------------
#   refs/pull/7/head: a 20,001-line gen/big.js with a claude-opus literal at
#     line 15000, src/app.js with a claude-sonnet literal, 120 clean files
#   refs/pull/8/head: one binary file, no literal anywhere
#   refs/pull/9/head: clean text only
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@fixture.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@fixture.test
export GIT_AUTHOR_DATE=2026-10-10T08:00:00Z GIT_COMMITTER_DATE=2026-10-10T08:00:00Z
SRC="$T/src"; ORIGIN="$T/origin.git"
git init -q -b main "$SRC" && echo base > "$SRC/README" && git -C "$SRC" add -A && git -C "$SRC" commit -qm base
git -C "$SRC" checkout -qb pr7
mkdir -p "$SRC/src" "$SRC/gen" "$SRC/lots"
printf 'export const model = "claude-sonnet-5-5";\n' > "$SRC/src/app.js"
awk 'BEGIN { for (i = 1; i <= 20001; i++) print (i == 15000 ? "const m = \"claude-opus-5-5\";" : "export const v" i " = " i ";") }' > "$SRC/gen/big.js"
for i in $(seq 1 120); do awk -v i="$i" 'BEGIN { for (j = 1; j <= 100; j++) print "export const f" i "_" j " = " j ";" }' > "$SRC/lots/f$i.js"; done
git -C "$SRC" add -A && git -C "$SRC" commit -qm "big pr"
H7=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q main && git -C "$SRC" checkout -qb pr8
printf '\000\001\002binary\000' > "$SRC/logo.bin"; printf 'export const ok = 1;\n' > "$SRC/ok.js"
git -C "$SRC" add -A && git -C "$SRC" commit -qm "binary pr"
H8=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q main && git -C "$SRC" checkout -qb pr9
printf 'export const clean = 1;\n' > "$SRC/clean.js"
git -C "$SRC" add -A && git -C "$SRC" commit -qm "clean pr"
H9=$(git -C "$SRC" rev-parse HEAD)
git clone -q --bare "$SRC" "$ORIGIN"
git -C "$ORIGIN" update-ref refs/pull/7/head "$H7"; git -C "$ORIGIN" update-ref refs/pull/8/head "$H8"; git -C "$ORIGIN" update-ref refs/pull/9/head "$H9"

# The network edges, shared by the drivers below.
cat > "$T/edges.sh" <<'EDGES'
MC_H="$T"; MC_STATE_DIR="$T/state"
mc_log() { printf "%s\n" "$*" >> "$T/mc.log"; }
mc_rest_status() { printf "%s" "$API"; }
mc_pr_diff() { if [ "$API" = 200 ]; then printf "diff --git a/x b/x\n+++ b/x\n+api diff\n" > "$2"; return 0; fi; : > "$2"; return 75; }
mc_git_bounded() { shift; "$@"; }
mc_git_auth_clear() { :; }
mc_funnel_repo() { echo "$1 $2" >> "$T/funnel-calls"
  [ -d "$T/wt/.git" ] || git clone -q "$ORIGIN" "$T/wt" >/dev/null 2>&1 || return 1
  MC_FUNNEL_WT="$T/wt"; MC_REMOTE="$ORIGIN"; return 0; }
EDGES

drive() { # drive <api-status> <num> <expected-head> — mc_pr_diff_or_local, then the scan
  : > "$T/mc.log"; : > "$T/funnel-calls"; rm -f "$T/out.diff"
  ( cd "$T" && T="$T" ORIGIN="$ORIGIN" API="$1" bash -c '
      set -uo pipefail
      . "$T/edges.sh"; . "$T/fns.sh"
      mc_pr_diff_or_local "https://github.com/o/r/pull/$1" "$T/out.diff" o/r demo-os "$1" main "$2"
      echo "rc=$?"; echo "unscanned=$MC_DIFF_UNSCANNED"
      [ -s "$T/out.diff" ] && echo "scan=$(mc_iron_law_scan "$T/out.diff")"
      [ -s "$T/out.diff" ] && mc_iron_law_names "$T/out.diff" | sed "s/^/name=/"' _ "$2" "$3" > "$T/drive.out" 2>"$T/drive.err" )
}

# L1. 406: every file is read; the literal inside the 20,001-line file counts
drive 406 7 "$H7"
grep -qx "rc=0" "$T/drive.out" && ok || bad "L1 a 406 must fall back to the local diff (rc 0): $(cat "$T/drive.out") $(tail -3 "$T/drive.err") $(cat "$T/mc.log")"
grep -qx "scan=2" "$T/drive.out" && ok || bad "L1 the scan must count both literals, the one in the 20,001-line file too: $(cat "$T/drive.out")"
grep -qx "name=gen/big.js (claude-opus-5-5)" "$T/drive.out" && grep -qx "name=src/app.js (claude-sonnet-5-5)" "$T/drive.out" \
  && ok || bad "L1 both hits must be named with their file: $(grep name= "$T/drive.out")"
grep -q "^diff --git a/gen/big.js" "$T/out.diff" && ok || bad "L1 the big file must be in the scanned diff"
grep -q "every file scanned" "$T/mc.log" && grep -q "406" "$T/mc.log" && ok || bad "L1 the log must say every file was scanned on a local diff after a 406: $(cat "$T/mc.log")"

# L2. 406 with a binary file: rc 3, counted, named
drive 406 8 "$H8"
grep -qx "rc=3" "$T/drive.out" && grep -qx "unscanned=1" "$T/drive.out" && ok || bad "L2 a binary file must give rc 3 and MC_DIFF_UNSCANNED=1: $(cat "$T/drive.out")"
grep -q "1 file(s) not scanned.*logo.bin" "$T/mc.log" && ok || bad "L2 the unscanned file must be named: $(cat "$T/mc.log")"

# L3. TEST-CHANGE (BH-6000): any failure of the API read falls back, not only a
# 406. Before, a 403 was asserted to stay UNVERIFIABLE; #6000 asks that a
# failed read (#5993: UNVERIFIABLE on every tick) runs the local scan. The
# local read spends no API budget, so a rate limit is no reason to skip it.
for st in 502 403; do
  drive "$st" 7 "$H7"
  grep -qx "rc=0" "$T/drive.out" && grep -qx "scan=2" "$T/drive.out" && ok || bad "L3 a $st must fall back to the local diff and scan it (rc 0, 2 hits): $(cat "$T/drive.out")"
  [ -s "$T/funnel-calls" ] && ok || bad "L3 a $st must read the local clone"
  grep -q "diff read from the API failed (HTTP $st) — iron-law scan reads a local git diff" "$T/mc.log" && ok || bad "L3 the log must name HTTP $st: $(cat "$T/mc.log")"
done

# L4. the head the PR ref carries is not the head the conductor read
drive 406 7 "0000000000000000000000000000000000000000"
grep -qx "rc=75" "$T/drive.out" && ok || bad "L4 a head mismatch must be UNVERIFIABLE (rc 75): $(cat "$T/drive.out")"
grep -q "head" "$T/mc.log" && ok || bad "L4 the mismatch must be logged: $(cat "$T/mc.log")"

# L5. the API answers: its diff is used
drive 200 7 "$H7"
grep -qx "rc=0" "$T/drive.out" && grep -q "api diff" "$T/out.diff" && ok || bad "L5 an API diff must be used as is: $(cat "$T/drive.out")"
[ ! -s "$T/funnel-calls" ] && ok || bad "L5 an API diff must not touch a clone"

# --- H. the conductor's own blocks: read, then publish ------------------------
conduct() { # conduct <num> <head> — the read block then the publish block; PUTs -> $T/puts, memo -> $T/memo
  : > "$T/mc.log"; : > "$T/puts"; : > "$T/memo"; rm -rf "$T/state"
  ( cd "$T" && T="$T" ORIGIN="$ORIGIN" API=406 bash -c '
      set -uo pipefail
      . "$T/edges.sh"; . "$T/fns.sh"
      job_ledger_put() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$T/puts"; return 0; }
      read_memo_put() { printf "%s\n" "$*" >> "$T/memo"; }
      SLUG=o/r; P=demo-os; NUM="$1"; HEAD="$2"; KEY="o/r#$1"; URL="https://github.com/o/r/pull/$1"
      BASEREF=main; PBASE=main; UPDATED=2026-10-10T08:00:00Z; MC_SCAN_FP=fp
      SCAN=0; DIFF_UNREAD=0; DIFF_WHY=""; MC_HIT_NAMES=""; DF=$(mktemp)
      . "$T/read.sh"
      rm -f "$DF"
      . "$T/publish.sh"
      echo "SCAN=$SCAN DIFF_UNREAD=$DIFF_UNREAD"' _ "$1" "$2" > "$T/conduct.out" 2>"$T/conduct.err" )
}

# H1. THE REVIEW'S CASE: held with the hit named, never cleared
conduct 7 "$H7"
grep -q "^mc-merge-verdict|o/r#7|hold|$H7 iron-law: 2 hit(s) on this head: .*gen/big.js (claude-opus-5-5)" "$T/puts" \
  && ok || bad "H1 a 406 PR with a literal in a 20,001-line file must be HELD with the hit named: $(cat "$T/puts") $(cat "$T/conduct.err")"
grep -q "|clear|" "$T/puts" && bad "H1 it must never be cleared: $(cat "$T/puts")" || ok

# H2. binary and no hits: held, and the count is not memoised
conduct 8 "$H8"
grep -q "^mc-merge-verdict|o/r#8|hold|$H8 iron-law: 1 file(s) not scanned" "$T/puts" && ok || bad "H2 an unscanned file must hold: $(cat "$T/puts") $(cat "$T/conduct.err")"
grep -q "|clear|" "$T/puts" && bad "H2 it must never be cleared: $(cat "$T/puts")" || ok
[ ! -s "$T/memo" ] && ok || bad "H2 a partial scan must not be stored in the scan memo: $(cat "$T/memo")"
grep -q "DIFF_UNREAD=1" "$T/conduct.out" && ok || bad "H2 the READY arm must see the head as unread: $(cat "$T/conduct.out")"

# H3. clean text: cleared, memoised
conduct 9 "$H9"
grep -q "^mc-merge-verdict|o/r#9|clear|$H9 iron-law scan clean" "$T/puts" && ok || bad "H3 a clean 406 PR must clear: $(cat "$T/puts") $(cat "$T/conduct.err")"
grep -q "^scan o/r#9 $H9 .* 0$" "$T/memo" && ok || bad "H3 a whole clean scan is memoised: $(cat "$T/memo")"

# --- P. mc_merge_verdict_put -------------------------------------------------
put() { # put <head> <status> <reason>
  ( cd "$T" && T="$T" bash -c '
      set -uo pipefail
      MC_STATE_DIR="$T/pstate"
      job_ledger_put() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$T/puts"; return "$(cat "$T/put.rc" 2>/dev/null || echo 0)"; }
      . "$T/fns.sh"
      mc_merge_verdict_put "example-org/project-6#27" "$1" "$2" "$3"' _ "$1" "$2" "$3" )
}
: > "$T/puts"; rm -rf "$T/pstate"; echo 0 > "$T/put.rc"
put "$H7" hold "diff-unread: HTTP 406"
grep -qx "mc-merge-verdict|example-org/project-6#27|hold|$H7 diff-unread: HTTP 406" "$T/puts" && ok || bad "P1 the hold row: $(cat "$T/puts")"
put "$H7" hold "diff-unread: HTTP 406"
[ "$(grep -c . "$T/puts")" = 1 ] && ok || bad "P2 the same (head, status) must not be PUT twice: $(cat "$T/puts")"
echo 1 > "$T/put.rc"
put "$H7" clear "iron-law scan clean"
echo 0 > "$T/put.rc"
put "$H7" clear "iron-law scan clean"
[ "$(grep -c "|clear|" "$T/puts")" = 2 ] && ok || bad "P3 a failed PUT must be retried on the next call: $(cat "$T/puts")"
put "$H7" clear "iron-law scan clean"
[ "$(grep -c "|clear|" "$T/puts")" = 2 ] && ok || bad "P4 after a landed PUT the same verdict is not re-sent: $(cat "$T/puts")"

# --- W. wiring ---------------------------------------------------------------
MC="$DIR/bin/merge-conductor.sh"
grep -qF 'mc_pr_diff_or_local "$URL" "$DF" "$SLUG" "$P" "$NUM"' "$MC" && ok || bad "W1 the conductor's iron-law scan must read through mc_pr_diff_or_local"
grep -q 'mc_merge_verdict_put "$KEY" "$HEAD" hold' "$MC" && grep -q 'mc_merge_verdict_put "$KEY" "$HEAD" clear' "$MC" \
  && ok || bad "W2 the conductor must publish hold and clear verdicts for the scanned head"
MQLAND=$(awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' "$DIR/bin/merge-queue.sh")
grep -q 'mq_conductor_hold "$num" "$pin"' <<<"$MQLAND" && ok || bad "W3 mq_land must ask mq_conductor_hold before it merges"

echo "mc-diff-local.bh-5914: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
