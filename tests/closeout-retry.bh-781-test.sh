#!/bin/bash
# tests/closeout-retry.bh-781-test.sh — every decision close-out and comment
# writer BH-781 moved onto bin/lib/gh-rest.sh, driven against a stub GitHub
# that can refuse.
#
# THE ONE RULE ALL SEVEN OBEY. A marker — a done-file, a ledger row, a line of
# stdout, a "closed" log line — is written ONLY after the library returned rc 0,
# and `gh_rest_close` returns 0 only after a FRESH READ says `closed`. So a 403
# leaves the work exactly where it was and the next tick retries it; nothing
# here is ever "stamped closed without being closed" (#768).
#
# ORDER IS PART OF THE CONTRACT: comment, then close, then the marker. A PR or
# an issue closed with no explanation tells the next reader nothing, so a failed
# comment never reaches the close.
#
# HOW IT DRIVES. Five of the seven are run as the REAL script
# (bin/board-closeout.sh, bin/unblocked-children.sh, bin/hotfix-seen.sh,
# bin/decompose-parent-close.sh) or the REAL library function
# (bin/lib/hotfix-lib.sh:hotfix_issue_is). The two that live inside a 5000-line
# pipeline (bin/run-build.sh, bin/batch-resolve.sh) have their function
# extracted verbatim and sourced beside the same `. bin/lib/gh-rest.sh` line
# their own script carries, so a script that stopped sourcing the library fails
# here. Assertions are on artifacts: marker files, log lines, stdout, and the
# stub's ordered invocation log.
#
# Run from anywhere: tests/closeout-retry.bh-781-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these lanes"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required by bin/decompose-parent-close.sh"; exit 1; }

SLUG="example-org/cromford"

# ── the stub gh ──────────────────────────────────────────────────────────────
# REST calls answer from $CASE/<kind>.resp (`<code>` on line 1, body after);
# the CLI reads this slice does not convert answer from their own fixtures.
# Every invocation is logged in order, which is what the ordering assertions
# read.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
[ -f "$CASE/issues.resp" ] || { . "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0; }
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
if [ "${1:-}" != api ]; then
  case "$*" in
    *"issue list"*) cat "$CASE/issues-list.json" 2>/dev/null || echo '[]' ;;
    *"pr list"*)    cat "$CASE/prs-list.json"    2>/dev/null || echo '[]' ;;
    *"issue view"*)
      n=$(printf '%s' "$*" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
      cat "$CASE/issue-$n.json" 2>/dev/null || exit 1 ;;
    *"pr view"*)    cat "$CASE/pr-head.txt"      2>/dev/null || exit 1 ;;
    *) exit 1 ;;
  esac
  exit 0
fi
M=GET; P=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  case "$a" in repos/*) P="$a" ;; esac
  prev="$a"
done
case "$M $P" in
  "POST "*/comments) K=comment ;;
  "PATCH "*)         K=close ;;
  "GET "*/labels)    K=labels ;;
  "GET "*/issues)    K=issues ;;
  "GET "*/files)     cat "$CASE/pr-files.json" 2>/dev/null || echo '[]'; exit 0 ;;
  # A PULL READ IS THE ONE THE STUB HAS TO MODEL, not answer from a constant.
  # settle_member now reads the PR's state BEFORE it writes, and gh_rest_close
  # re-reads the same path AFTER its PATCH — two GETs on one path that must give
  # different answers. A case that writes prread.resp gets the modelled object:
  # this read answers from it, and the PATCH below advances it to `closed` only
  # when the PATCH itself was accepted. Cases that do not write it are answered
  # from read.resp exactly as before.
  "GET "*/pulls/*)   K=read; [ -f "$CASE/prread.resp" ] && K=prread ;;
  "GET "*)           K=read ;;
  *)                 K=other ;;
esac
F="$CASE/$K.resp"
[ -f "$F" ] || exit 1
CODE=$(head -n 1 "$F"); BODY=$(tail -n +2 "$F")
[ "$CODE" = none ] && exit 1
case "$CODE" in
  200) TXT="OK" ;; 201) TXT="Created" ;; 403) TXT="Forbidden" ;;
  404) TXT="Not Found" ;; 429) TXT="Too Many Requests" ;; *) TXT="Status" ;;
esac
case " $* " in
  *" -i "*) printf 'HTTP/2.0 %s %s\nx-stub: 1\n\n%s' "$CODE" "$TXT" "${BODY:+$BODY
}" ;;
  *) [ -n "$BODY" ] && printf '%s\n' "$BODY" ;;
esac
# THE OBJECT MOVES ONLY WHEN THE WRITE WAS ACCEPTED. A refused PATCH leaves the
# PR open, which is what makes a second pass a real retry rather than a replay.
# AND A MERGED PR NEVER BECOMES PLAIN `closed`: GitHub accepts `state=closed` on
# a merged PR with a 200 and keeps merged_at, so gh_rest_pr_state keeps
# answering `merged` and gh_rest_close keeps answering 75. Flattening it here
# would hide exactly the "this member never settles" bug the BR5 case is for.
case "$M $P:$CODE" in
  "PATCH "*/pulls/*:2*)
    if [ -f "$CASE/prread.resp" ] && ! grep -q merged_at "$CASE/prread.resp"; then
      printf '200\n{"state":"closed"}\n' > "$CASE/prread.resp"
    fi ;;
esac
case "$CODE" in 2*) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin/gh"

resp() { printf '%s\n%s\n' "$2" "$3" > "$CASE/$1.resp"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
ncalls() { calls | grep -c . ; }
nth()    { calls | sed -n "${1}p"; }

newcase() { # newcase <name> — a fresh scratch harness with the stub on PATH
  CASE="$T/case-$1"; export CASE
  H="$CASE/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/builds"
  cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  # BH-7919: escalate_block's ticket comment now asks bin/lib/tracker.sh trk_gh_issue_number.
  scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
  : > "$CASE/gh-calls.log"
  # The defaults are the happy path; a case overrides exactly what it is about.
  resp comment 201 '{"id":1}'
  resp close   200 '{"state":"closed"}'
  resp read    200 '{"state":"closed"}'
  export PATH="$T/bin:$H/bin:$PATH"
}

# The `. bin/lib/gh-rest.sh` line each script carries, lifted from the script
# itself: an extracted function driven beside a hand-written source would stay
# green on a script that never wired the library up.
srcline() { # srcline <script>
  grep -m1 -E '^[^#]*lib/gh-rest\.sh' "$DIR/bin/$1"
}

# ════════════════════════════════════════════════════════════════════════════
# R — bin/run-build.sh: the tier-1 close-out pair and the blocked notice
# ════════════════════════════════════════════════════════════════════════════
# THE FLATTEN, NEVER THE RAW DRIVER (BH-568 seam). bin/run-build.sh is split
# into stage modules under bin/lib/rb/ (BH-478; cut in BH-572), so a suite that
# lifted a block — or the gh-rest source line — out of the driver itself would
# read a pipeline with holes in it. tests/rb-modules-source-test.sh pins that rule.
# shellcheck source=/dev/null
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
[ -s "$RB_ALL" ] && ok || bad "R: the flattened bin/run-build.sh is empty — the seam helper could not build it"
RB_SRC=$(grep -m1 -E '^[^#]*lib/gh-rest\.sh' "$RB_ALL")
[ -n "$RB_SRC" ] && ok || bad "R: bin/run-build.sh sources no bin/lib/gh-rest.sh — its close-out cannot reach the library"
awk '/^CLOSE_ISSUE_AFTER_MERGE\(\) \{/,/^\}/' "$RB_ALL" > "$T/close-fn.sh"
awk '/^escalate_block\(\) \{/,/^\}/'          "$RB_ALL" > "$T/escalate-fn.sh"
[ -s "$T/close-fn.sh" ]    && ok || bad "R: could not extract CLOSE_ISSUE_AFTER_MERGE from bin/run-build.sh"
[ -s "$T/escalate-fn.sh" ] && ok || bad "R: could not extract escalate_block from bin/run-build.sh"

cat > "$T/drive-rb.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# shellcheck source=/dev/null
eval "$RB_SRC"
# shellcheck source=/dev/null
. "$FN"
CLOSE_ISSUE_AFTER_MERGE "https://github.com/$SLUG/pull/9"
DRIVE
rb() { # rb — one CLOSE_ISSUE_AFTER_MERGE pass
  HARNESS="$H" SLUG="$SLUG" PROJECT=cromford KEY=BH-781 BUILD="$H/builds/b" \
    CLOSES_LINE="Closes #7" RB_SRC="$RB_SRC" FN="$T/close-fn.sh" \
    bash "$T/drive-rb.sh" >/dev/null 2>&1
}
plog() { cat "$H/builds/b/pipeline.log" 2>/dev/null; }

# R1 — the whole pair lands: comment, close, verified re-read, one log line.
newcase r1; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
rb
plog | grep -q "closed issue #7 after merge" && ok \
  || bad "R1: a verified close must log it: $(plog)"
nth 1 | grep -q -- '-X POST repos/example-org/cromford/issues/7/comments' && ok \
  || bad "R1: the comment must be the FIRST call: $(calls)"
nth 2 | grep -q -- '-X PATCH repos/example-org/cromford/issues/7' && ok \
  || bad "R1: the close must be the SECOND call: $(calls)"
nth 3 | grep -q -- '-X GET repos/example-org/cromford/issues/7' && ok \
  || bad "R1: the verifying re-read must be the THIRD call: $(calls)"
calls | grep -q -- '-F body=@' && ok \
  || bad "R1: the comment body must travel by FILE, never on argv: $(calls)"

# R2 — the close is refused: the issue is left open and the log says so.
newcase r2; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
resp close 403 '{"message":"API rate limit exceeded"}'
rb
plog | grep -q "could not be commented/closed" && ok \
  || bad "R2: a refused close must log the retry sentence: $(plog)"
grep -q "closed issue #7 after merge" <<<"$(plog)" \
  && bad "R2: a refused close must never log a close that did not happen: $(plog)" || ok
rb
# THE TICKET'S ACCEPTANCE, not the code's behaviour: "comment posted exactly
# once across the two passes". The first version of this suite asserted 2 and
# called it correct — that is the acceptance inverted in the acceptance test.
# A POST that landed under a PATCH that was refused is a client-visible comment,
# and restating it on every retry is the TK-88 shape (one bot comment 213 times
# in 5.5h on a client thread).
[ "$(calls | grep -c -- '-X POST')" = 1 ] && ok \
  || bad "R2: the close-out comment must be posted exactly once across the two passes: $(calls)"
[ "$(calls | grep -c -- '-X PATCH')" = 2 ] && ok \
  || bad "R2: the CLOSE is what a second pass retries — it must be attempted again: $(calls)"

# R2c — the close finally lands on the retry: one comment, and the marker is
# dropped so a reopened issue is never closed again in silence.
newcase r2c; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
resp close 403 '{"message":"API rate limit exceeded"}'
rb
resp close 200 '{"state":"closed"}'
rb
[ "$(calls | grep -c -- '-X POST')" = 1 ] && ok \
  || bad "R2c: the retry that closes must not re-post the comment: $(calls)"
plog | grep -q "closed issue #7 after merge" && ok \
  || bad "R2c: the retry must log the close it landed: $(plog)"
[ ! -e "$H/state/merge-close-commented-example-org_cromford-7" ] && ok \
  || bad "R2c: a verified close must drop the commented-marker"

# R2b — the close 200s but the re-read does not say closed: still not a close.
newcase r2b; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
resp read 200 '{"state":"open"}'
rb
grep -q "closed issue #7 after merge" <<<"$(plog)" \
  && bad "R2b: a PATCH that did not actually close must not be logged as a close: $(plog)" || ok

# R3 — the blocked notice: the stamp is written only on a post that landed.
cat > "$T/drive-eb.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# shellcheck source=/dev/null
eval "$RB_SRC"
# shellcheck source=/dev/null
. "$FN"
escalate_block "test-tamper" "the detail line"
DRIVE
eb() {
  HARNESS="$H" SLUG="$SLUG" PROJECT=cromford KEY=BH-781 BUILD="$H/builds/b" \
    RB_SRC="$RB_SRC" FN="$T/escalate-fn.sh" bash "$T/drive-eb.sh" >/dev/null 2>&1
}
stamps() { ls "$H"/state/blocked-commented-* 2>/dev/null | grep -c . ; }
eb_setup() {
  mkdir -p "$H/builds/b"
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo "-" ;; repo) echo "example-org/cromford" ;; *) exit 1 ;; esac
SH
  chmod +x "$H/bin/fleet-conf.sh"
}
newcase r3a; eb_setup
resp comment 403 '{"message":"API rate limit exceeded"}'
eb
[ "$(stamps)" = 0 ] && ok || bad "R3: a refused comment must leave NO stamp, or the block is never restated"
newcase r3b; eb_setup
eb
[ "$(stamps)" = 1 ] && ok || bad "R3: a posted comment must leave exactly one stamp (got $(stamps))"
BEFORE=$(ncalls); eb
[ "$(ncalls)" = "$BEFORE" ] && ok \
  || bad "R3: a second pass over a stamped build must make zero calls: $(calls)"

# ════════════════════════════════════════════════════════════════════════════
# BR — bin/batch-resolve.sh: settle_member
# ════════════════════════════════════════════════════════════════════════════
BR_SRC=$(srcline batch-resolve.sh)
[ -n "$BR_SRC" ] && ok || bad "BR: bin/batch-resolve.sh sources no bin/lib/gh-rest.sh"
awk '/^settle_member\(\) \{/,/^\}/' "$DIR/bin/batch-resolve.sh" > "$T/settle-fn.sh"
[ -s "$T/settle-fn.sh" ] && ok || bad "BR: could not extract settle_member from bin/batch-resolve.sh"

cat > "$T/drive-br.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
LOG="$H/logs/batch-resolve.log"
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] $*" >> "$LOG"; }
mc_batch_release() { :; }
mc_record_for()    { printf '%s\n' "$CASE/rec.json"; }
mc_issue_of()      { printf '\n'; }
job_ledger_put()   { printf '%s\n' "$*" >> "$CASE/ledger.txt"; }
# shellcheck source=/dev/null
eval "$BR_SRC"
# shellcheck source=/dev/null
. "$FN"
settle_member "$1" "$2" "$3" "$4"
printf 'rc=%s\n' "$?" > "$CASE/settle.rc"
DRIVE
br() { # br <head-now>
  printf '%s\n' "$1" > "$CASE/pr-head.txt"
  H="$H" HARNESS="$H" SLUG="$SLUG" PROJECT=cromford STATE="$H/state/batch-resolve/cromford" \
    PBASE=main CASE="$CASE" BR_SRC="$BR_SRC" FN="$T/settle-fn.sh" \
    bash "$T/drive-br.sh" 12 deadbeefcafe "https://github.com/$SLUG/pull/99" abc123 \
    >/dev/null 2>&1
  cat "$CASE/settle.rc" 2>/dev/null
}
br_setup() {
  mkdir -p "$H/state/batch-resolve/cromford" "$H/logs"
  printf '{}\n' > "$CASE/rec.json"
  # The member PR as an object, not a constant: OPEN until a PATCH is accepted.
  # settle_member reads it before it writes anything (an already-merged member
  # must not be commented on or PATCHed), and gh_rest_close re-reads it after
  # its PATCH.
  printf '200\n{"state":"open"}\n' > "$CASE/prread.resp"
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo "FR" ;; *) exit 1 ;; esac
SH
  chmod +x "$H/bin/fleet-conf.sh"
}
done_file() { cat "$H/state/merge-sweep-done.txt" 2>/dev/null; }

# BR1 — the comment lands, the close is refused: no ledger row, no done-file.
newcase br1; br_setup
resp close 403 '{"message":"API rate limit exceeded"}'
[ "$(br abc123)" = "rc=1" ] && ok || bad "BR1: a refused close must return 1 so the train stays open (got $(br abc123))"
[ ! -f "$CASE/ledger.txt" ] && ok || bad "BR1: a refused close must write NO ledger row: $(cat "$CASE/ledger.txt")"
[ -z "$(done_file)" ] && ok || bad "BR1: a refused close must write NO done-marker: $(done_file)"

# BR2 — the comment itself is refused: the close is never attempted.
newcase br2; br_setup
resp comment 403 '{"message":"API rate limit exceeded"}'
[ "$(br abc123)" = "rc=1" ] && ok || bad "BR2: a refused comment must return 1"
[ "$(calls | grep -c -- '-X PATCH')" = 0 ] && ok \
  || bad "BR2: a PR must never be closed on a comment that did not land: $(calls)"

# BR3 — both land: the done-file carries the url exactly once across two passes.
newcase br3; br_setup
br abc123 >/dev/null
[ "$(done_file | grep -c "pull/12")" = 1 ] && ok \
  || bad "BR3: a verified close must record the member exactly once: $(done_file)"
[ -f "$CASE/ledger.txt" ] && ok || bad "BR3: a verified close must write the ledger row"
br abc123 >/dev/null
[ "$(done_file | grep -c "pull/12")" = 1 ] && ok \
  || bad "BR3: a second pass must not duplicate the done-marker: $(done_file)"

# BR4 — the close is refused twice: the close-out comment is posted EXACTLY
# ONCE across both passes (the ticket's acceptance), and the close is retried.
# Without the marker the conductor says the same sentence on the same member PR
# every */5 pass until the PATCH lands.
newcase br4; br_setup
resp close 403 '{"message":"API rate limit exceeded"}'
br abc123 >/dev/null
br abc123 >/dev/null
[ "$(calls | grep -c -- '-X POST')" = 1 ] && ok \
  || bad "BR4: the close-out comment must be posted exactly once across the two passes: $(calls)"
[ "$(calls | grep -c -- '-X PATCH')" = 2 ] && ok \
  || bad "BR4: the CLOSE is what a second pass retries — it must be attempted again: $(calls)"
[ -z "$(done_file)" ] && ok || bad "BR4: a refused close still writes NO done-marker: $(done_file)"

# BR5 — the member was merged by someone else while the train was in flight
# (Mergify, a human), head unchanged. `gh_rest_close` answers 75 forever on a
# merged PR because `merged` is not the literal `closed` it demands, so without
# a pre-read this member re-comments every pass and never settles — it holds the
# train open until the age budget abandons it. A pre-read settles it in one pass
# with ZERO writes to GitHub and the ledger row written as usual.
newcase br5; br_setup
printf '200\n{"state":"closed","merged_at":"2026-09-19T00:00:00Z"}\n' > "$CASE/prread.resp"
[ "$(br abc123)" = "rc=0" ] && ok \
  || bad "BR5: an already-merged member must settle, not hold the train open (got $(br abc123))"
[ "$(calls | grep -c -- '-X POST')" = 0 ] && ok \
  || bad "BR5: a merged PR must not be commented on: $(calls)"
[ "$(calls | grep -c -- '-X PATCH')" = 0 ] && ok \
  || bad "BR5: a merged PR must not be PATCHed closed: $(calls)"
[ "$(done_file | grep -c "pull/12")" = 1 ] && ok \
  || bad "BR5: an already-merged member must still be recorded done: $(done_file)"
[ -f "$CASE/ledger.txt" ] && ok || bad "BR5: an already-merged member must still write the ledger row"

# BR6 — the state read is REFUSED (403): "unreadable" is not "already settled".
# It falls through to the normal comment-then-close path, which is the
# conservative reading — a train must never skip a close it could not rule out.
newcase br6; br_setup
printf '403\n{"message":"API rate limit exceeded"}\n' > "$CASE/prread.resp"
br abc123 >/dev/null
[ "$(calls | grep -c -- '-X POST')" = 1 ] && ok \
  || bad "BR6: an unreadable state must still take the normal close-out path: $(calls)"

# ════════════════════════════════════════════════════════════════════════════
# D — bin/decompose-parent-close.sh: the parent close, driven as the real script
# ════════════════════════════════════════════════════════════════════════════
dp_setup() {
  cp "$DIR/bin/decompose-parent-close.sh" "$H/bin/"
  cp "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
  cat > "$CASE/issues-list.json" <<'JSON'
[{"number":11,"state":"CLOSED","stateReason":"COMPLETED","title":"BH-9.1 first part","body":"Part of #9\nOrder: 1 of 1"}]
JSON
  cat > "$CASE/prs-list.json" <<'JSON'
[{"number":12,"url":"https://github.com/example-org/cromford/pull/12","title":"BH-11: first part","headRefName":"ticket/bh-11","state":"MERGED"}]
JSON
  printf '{"number":9,"state":"OPEN","title":"the parent","labels":[]}\n' > "$CASE/issue-9.json"
}
dp() { HARNESS="$H" GH_ISSUES_REPO="$SLUG" GH_CLI_REST_READS=1 "$H/bin/decompose-parent-close.sh" cromford 2>/dev/null; }
plogp() { cat "$H/logs/cromford.log" 2>/dev/null; }

# D1 — the close is refused: nothing on stdout, and the failure is logged.
newcase d1; dp_setup
resp close 403 '{"message":"API rate limit exceeded"}'
OUT=$(dp)
[ -z "$OUT" ] && ok || bad "D1: a parent that did not close must not be announced closed (stdout: '$OUT')"
plogp | grep -q 'PARENT_CLOSE_FAILED #9' && ok || bad "D1: the failure must be logged: $(plogp)"
grep -q 'PARENT_CLOSED #9' <<<"$(plogp)" && bad "D1: a refused close must not log PARENT_CLOSED" || ok

# D2 — the close lands: stdout is exactly the number, comment before close.
newcase d2; dp_setup
OUT=$(dp)
[ "$OUT" = "9" ] && ok || bad "D2: a verified close must print the parent number (stdout: '$OUT')"
plogp | grep -q 'PARENT_CLOSED #9' && ok || bad "D2: the close must be logged: $(plogp)"
CN=$(calls | grep -n -- '-X POST.*issues/9/comments' | head -1 | cut -d: -f1)
PN=$(calls | grep -n -- '-X PATCH.*issues/9' | head -1 | cut -d: -f1)
[ -n "$CN" ] && [ -n "$PN" ] && [ "$CN" -lt "$PN" ] && ok \
  || bad "D2: the comment must be posted BEFORE the close (comment=$CN close=$PN): $(calls)"
[ ! -e "$H/state/parent-close-commented-cromford-9" ] && ok \
  || bad "D2: a verified close must drop the commented-marker"

# D3 — the close is refused on both passes: the client-visible close comment is
# posted EXACTLY ONCE, and the CLOSE is what is retried. This is the regression
# the split into two calls created: the merge-base ran the atomic `gh issue
# close --comment`, which could not leave a comment behind without a close, so
# POST 201 + PATCH 403 used to be impossible. The conductor rebuilds this list
# every */5 tick, so without the marker the same paragraph lands on the parent's
# thread every five minutes until the PATCH goes through (TK-88).
newcase d3; dp_setup
resp close 403 '{"message":"API rate limit exceeded"}'
dp >/dev/null
dp >/dev/null
[ "$(calls | grep -c -- '-X POST.*issues/9/comments')" = 1 ] && ok \
  || bad "D3: the parent close comment must be posted exactly once across the two passes: $(calls)"
[ "$(calls | grep -c -- '-X PATCH.*issues/9')" = 2 ] && ok \
  || bad "D3: the CLOSE is what a second pass retries — it must be attempted again: $(calls)"

# D4 — the close lands on the retry: still one comment, and the parent is
# announced closed only on the pass that closed it.
newcase d4; dp_setup
resp close 403 '{"message":"API rate limit exceeded"}'
OUT1=$(dp)
resp close 200 '{"state":"closed"}'
OUT2=$(dp)
[ -z "$OUT1" ] && [ "$OUT2" = "9" ] && ok \
  || bad "D4: only the pass that closed the parent may announce it (pass1='$OUT1' pass2='$OUT2')"
[ "$(calls | grep -c -- '-X POST.*issues/9/comments')" = 1 ] && ok \
  || bad "D4: the retry that closes must not re-post the comment: $(calls)"

# ════════════════════════════════════════════════════════════════════════════
# BC — bin/board-closeout.sh: the issues-lane what-shipped comment
# ════════════════════════════════════════════════════════════════════════════
bc_setup() {
  cp "$DIR/bin/board-closeout.sh" "$H/bin/"
  cp "$DIR/bin/lib/builder-direct.sh" "$H/bin/lib/" 2>/dev/null
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in
  prod) echo "-" ;; board_prefix) echo "-" ;; repo) echo "example-org/cromford" ;;
  *) exit 1 ;;
esac
SH
  printf '#!/bin/bash\necho OK\n' > "$H/bin/triage-gate.sh"
  chmod +x "$H/bin/fleet-conf.sh" "$H/bin/triage-gate.sh"
  BB="$H/builds/bc"; mkdir -p "$BB"
  echo "PR_CREATED https://github.com/$SLUG/pull/9" > "$BB/RESULT"
  printf -- '- did the thing\n' > "$BB/what.txt"
}
bc() { HARNESS="$H" "$H/bin/board-closeout.sh" cromford T1 BH-7 "$BB" 2>/dev/null; }

# BC1 — a refused post is not a close-out: rc 1 and no POSTED word.
newcase bc1; bc_setup
resp comment 403 '{"message":"API rate limit exceeded"}'
OUT=$(bc); RC=$?
[ "$RC" = 1 ] && ok || bad "BC1: a refused comment must exit 1 (rc=$RC)"
case "$OUT" in *POSTED*) bad "BC1: nothing was posted, so POSTED must not be printed (got '$OUT')" ;; *) ok ;; esac

# BC2 — a post that landed: rc 0 and the word the caller reads.
newcase bc2; bc_setup
OUT=$(bc); RC=$?
[ "$RC" = 0 ] && ok || bad "BC2: a posted close-out must exit 0 (rc=$RC)"
[ "$OUT" = "POSTED $SLUG#7" ] && ok || bad "BC2: the caller reads this word (got '$OUT')"
calls | grep -q -- '-X POST repos/example-org/cromford/issues/7/comments' && ok \
  || bad "BC2: the comment must go over REST: $(calls)"

# ════════════════════════════════════════════════════════════════════════════
# U — bin/unblocked-children.sh: the dep-pass paper trail
# ════════════════════════════════════════════════════════════════════════════
# The dep pass's own shape, copied from tests/unblocked-children-test.sh: #51's
# planned files are disjoint from #50's open PR and its plan calls the link
# ordering-only, so it is released SOFT — which is the one path that comments.
uc_setup() {
  cp "$DIR/bin/dep-verify.sh" "$H/bin/"
  cp "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
  mkdir -p "$H/plans/cromford-BH-51" "$H/prompts"
  echo 'setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > x' \
    > "$H/prompts/cromford.md"
  cat > "$CASE/issues-list.json" <<'JSON'
[
 {"number":50,"state":"OPEN","title":"parent, PR open","body":""},
 {"number":51,"state":"OPEN","title":"BH-50.2 brain map","body":"## Scope\nBlocked-by: #50"}
]
JSON
  echo '[{"number":900,"title":"BH-50: parent","headRefName":"ticket/bh-50","headRefOid":"bbbb222","state":"OPEN","url":"https://gh/900","isDraft":false}]' \
    > "$CASE/prs-list.json"
  echo '[{"filename":"src/lib/rollup.ts"}]' > "$CASE/pr-files.json"
  printf '## Dependencies\nDEPENDS: #50 soft — shares no code with the parent\nSIZE: S\n' \
    > "$H/plans/cromford-BH-51/plan.md"
  printf 'src/lib/brain-map.ts\n' > "$H/plans/cromford-BH-51/planned-files.txt"
}
uc() { # uc [script]
  HARNESS="$H" GH_ISSUES_REPO="$SLUG" \
    bash "${1:-$DIR/bin/unblocked-children.sh}" cromford 2>/dev/null \
    <<<'board issues: CHANGED 50 "parent" (comments: 1 -> 2; activity)'
}
marks() { ls "$H"/state/dep-verify/cromford/*.commented 2>/dev/null | grep -c . ; }

# U1 — the comment is refused: no marker, and the next tick comments again.
newcase u1; uc_setup
resp comment 403 '{"message":"API rate limit exceeded"}'
uc >/dev/null
[ "$(marks)" = 0 ] && ok || bad "U1: a refused comment must leave no .commented marker"
B1=$(calls | grep -c -- '-X POST'); uc >/dev/null
[ "$(calls | grep -c -- '-X POST')" -gt "$B1" ] && ok \
  || bad "U1: an unmarked child must be re-commented next tick: $(calls)"

# U2 — the comment lands: exactly one marker and exactly one POST over two ticks.
newcase u2; uc_setup
uc >/dev/null
[ "$(marks)" = 1 ] && ok || bad "U2: a posted comment must leave exactly one marker (got $(marks))"
uc >/dev/null
[ "$(calls | grep -c -- '-X POST')" = 1 ] && ok \
  || bad "U2: a marked child must never be commented twice: $(calls)"

# ════════════════════════════════════════════════════════════════════════════
# H — bin/lib/hotfix-lib.sh and bin/hotfix-seen.sh
# ════════════════════════════════════════════════════════════════════════════
hf_setup() {
  cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/" 2>/dev/null
  cp "$DIR/bin/hotfix-seen.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/" 2>/dev/null
  cat > "$H/fleet.conf" <<'CONF'
cromford  example-org/cromford   -   -   0 local -
CONF
  mkdir -p "$H/prompts"
  echo 'setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > x' \
    > "$H/prompts/cromford.md"
  : > "$H/env/global.env"
  cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CASE/beats.txt"
exit 0
SH
  chmod +x "$H/bin/beat.sh"
}
issue_is() { # issue_is — hotfix_issue_is against the stub, printing its rc
  HARNESS="$H" FLEET_CONF="$H/fleet.conf" CASE="$CASE" bash -c '
    set -uo pipefail
    . "$H/bin/lib/hotfix-lib.sh"
    hotfix_issue_is "'"$SLUG"'" 7 "$H"
    printf "rc=%s\n" "$?"' 2>/dev/null
}

# H1 — a failed labels read is UNKNOWN (rc 2), never "not a hotfix" (rc 1).
newcase h1a; hf_setup; resp labels 403 '{"message":"API rate limit exceeded"}'
[ "$(H="$H" issue_is)" = "rc=2" ] && ok \
  || bad "H1: a 403 on the labels read must answer 2 (UNKNOWN), got $(H="$H" issue_is)"
newcase h1b; hf_setup; resp labels 404 '{"message":"Not Found"}'
[ "$(H="$H" issue_is)" = "rc=2" ] && ok \
  || bad "H1: a 404 on the labels read must answer 2 (UNKNOWN), got $(H="$H" issue_is)"
newcase h1c; hf_setup; resp labels 200 '[{"name":"hotfix"}]'
[ "$(H="$H" issue_is)" = "rc=0" ] && ok \
  || bad "H1: a labelled issue must answer 0, got $(H="$H" issue_is)"
newcase h1d; hf_setup; resp labels 200 '[{"name":"bug"}]'
[ "$(H="$H" issue_is)" = "rc=1" ] && ok \
  || bad "H1: an unlabelled issue must answer 1, got $(H="$H" issue_is)"
newcase h1e; hf_setup; resp labels 200 '[{"name":"hotfix"}]'
H="$H" issue_is >/dev/null
calls | grep -q -- '-X GET repos/example-org/cromford/issues/7/labels' && ok \
  || bad "H1: the labels read must go to the REST labels collection: $(calls)"

# H2 — the /issues collection returns PRs too; a labelled PR is not a ticket.
hs() { HARNESS="$H" FLEET_CONF="$H/fleet.conf" "$H/bin/hotfix-seen.sh" cromford; }
seen() { grep -c 'HOTFIX seen' "$H/logs/ALERTS.log" 2>/dev/null || echo 0; }
newcase h2; hf_setup
resp issues 200 '[{"number":60,"title":"payments are down"},{"number":61,"title":"a labelled PR","pull_request":{"url":"x"}}]'
hs >/dev/null 2>&1
[ "$(seen)" = 1 ] && ok || bad "H2: a labelled PR must not be announced as a hotfix ticket: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'BH-60' "$H/logs/ALERTS.log" && ok || bad "H2: the real issue must still be announced"
grep -q 'BH-61' "$H/logs/ALERTS.log" && bad "H2: the PR was announced" || ok
calls | grep -q 'labels=ai-build,hotfix' && ok \
  || bad "H2: the listing must AND both labels the way gh issue list did: $(calls)"
calls | grep -q 'state=open' && ok || bad "H2: the listing must ask for open issues only: $(calls)"

# H3 — the listing is refused: exit 0, announce nothing, claim nothing.
newcase h3; hf_setup
resp issues 403 '{"message":"API rate limit exceeded"}'
hs >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "H3: a refused listing must never kill the triage tick (rc=$RC)"
[ "$(seen)" = 0 ] && ok || bad "H3: a refused listing must announce nothing"
[ ! -s "$CASE/beats.txt" ] && ok || bad "H3: a refused listing must beat nothing"

# ════════════════════════════════════════════════════════════════════════════
# M — mutation check (D1): a marker written before its verified call
# ════════════════════════════════════════════════════════════════════════════
# unblocked-children's marker moved ABOVE the post. U1 must go red.
MUTU="$T/uc-mut.sh"
sed 's|^    if gh_rest_comment "\$repo" "\$C" "\$BF"; then$|    : > "$MARKDIR/$C.commented" 2>/dev/null; if gh_rest_comment "$repo" "$C" "$BF"; then|' \
  "$DIR/bin/unblocked-children.sh" > "$MUTU"
if cmp -s "$DIR/bin/unblocked-children.sh" "$MUTU"; then
  bad "M: the unblocked-children mutation matched nothing — the mutation check is vacuous"
else
  chmod +x "$MUTU"
  newcase m1; uc_setup
  resp comment 403 '{"message":"API rate limit exceeded"}'
  uc "$MUTU" >/dev/null
  [ "$(marks)" = 1 ] && ok \
    || bad "M: with the marker written before the post, U1's assertion did not go red — it proves nothing"
fi
# gh_rest_close's re-read removed from the library COPY run-build sources. R2b
# must go red: a PATCH that 200s but did not close would be logged as a close.
newcase m2; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
resp read 200 '{"state":"open"}'
perl -0pi -e 's/if \[ "\$rc" != 0 \] \|\| \[ "\$seen" != closed \]; then return 75; fi/return 0/' \
  "$H/bin/lib/gh-rest.sh"
if grep -q 'seen" != closed' "$H/bin/lib/gh-rest.sh"; then
  bad "M: the gh_rest_close mutation matched nothing — the mutation check is vacuous"
else
  rb
  plog | grep -q "closed issue #7 after merge" && ok \
    || bad "M: with the verifying re-read removed, R2b's assertion did not go red — it proves nothing"
fi

echo "closeout-retry.bh-781: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
