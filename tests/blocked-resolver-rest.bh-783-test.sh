#!/bin/bash
# tests/blocked-resolver-rest.bh-783-test.sh — bin/blocked-resolver.sh reads,
# searches, comments and closes over REST, and a GitHub that will not answer
# stops it.
#
# THE INCIDENT (#768 -> #783). `gh pr view` speaks GraphQL. On 2026-09-18 the
# shared GraphQL bucket ran out, the read answered EMPTY, and every decision in
# this lane read that silence as a fact: "not OPEN" became "nothing to close",
# "no merged PR" became "rebuild it", "no findings" became "there is nothing to
# brief, REBUILD FRESH". Open PRs were closed and rebuilt because GitHub was
# rate-limiting us.
#
# So this suite is about THREE answers, never two: 2xx act on it, 404 the thing
# is ABSENT, anything else (403/429/5xx/000/empty-2xx) is UNVERIFIABLE and the
# tick ends with the park exactly as it was. Every row asserts on ARTIFACTS —
# the queue, the PATCH/comment records, state/blocked-resolver/*.json, the log,
# ALERTS.log and the stub's own argv log — never on the resolver's source text.
#
# HOW IT DRIVES THE REAL THING: bin/blocked-resolver.sh is copied into a scratch
# harness and RUN, with one stub `gh` that answers `api -i` from per-route
# fixture files in the `HTTP/2 <st>\r\n\r\n<body>` shape tests/gh-rest-lib-test.sh
# uses. Section 1 extracts the helpers from the same file to pin their rc
# contract directly; every other section runs the whole script.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-rest.bh-783-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock anchor for the whole file; every fixture timestamp is derived from
# it, so nothing here can go red on a date nobody chose (the #360 lesson).
NOW=$(date -u +%s)
MERGEDAT=$(date -u -d "@$((NOW-86400))" +%Y-%m-%dT%H:%M:%SZ)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh internal-token-for.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The "agent": records that it was called and the prompt it was given. A rung
# that must NOT be bought is asserted by this file staying empty.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# ── the gh stub ──────────────────────────────────────────────────────────────
# Every call is recorded to gh-argv.log. `api -i` answers are built from
# per-route status files ($T/st-<route>, default 2xx) and per-route body files,
# so a scenario is one write rather than one stub. $T/down makes gh itself fail
# with no output at all, which is the 000/network row. Calls WITHOUT `-i` are
# the raw-REST readers this ticket deliberately leaves alone (br_pr_ref,
# br_failed_runs) plus the one allow-listed `gh run view --log-failed`.
# BH-2504: the lane's hold gates read the ticket (bin/lib/hold.sh travels with the
# modules now); FIXTURE: an unheld ticket.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "\$*" >> "$T/gh-argv.log"
[ -f "$T/down" ] && exit 1
ST()   { cat "$T/st-\$1" 2>/dev/null || echo "\$2"; }
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; exit 0; }
PRN()  { local p="\$*"; p="\${p##*/pulls/}"; printf '%s' "\${p%% *}"; }
case "\$*" in
  *"run view"*"--log-failed"*)             # the one allow-listed raw gh call
      cat "$T/joblog" 2>/dev/null; exit 0 ;;
  *"--jq"*"/pulls/"*|*"/pulls/"*"--jq"*)   # br_pr_ref: raw REST, not this ticket's
      cat "$T/prref" 2>/dev/null; exit 0 ;;
  *"actions/runs?head_sha="*)              # br_failed_runs: raw REST, not this ticket's
      cat "$T/failedruns" 2>/dev/null; exit 0 ;;
  *"repos/"*"/pulls?state="*)              # harness_pr_list's REST page (BH-872's
      echo '[]'; exit 0 ;;                 # review source runs on every tick; an
                                           # empty page is this fixture's truth,
                                           # and it keeps the lane off the
                                           # GraphQL fallback block 9 forbids
  *"vnd.github.v3.diff"*)
      SEND "\$(ST diff 200)" "\$(cat "$T/prdiff" 2>/dev/null)" ;;
  *"-X PATCH"*"/pulls/"*)
      printf '%s\n' "\$*" >> "$T/patched.txt"
      s=\$(ST patch 200)
      case "\$s" in 2*) [ -f "$T/patch-noflip" ] || printf '{"state":"closed","merged_at":null,"head":{"sha":"","ref":""},"base":{"ref":"main"},"title":""}' > "$T/pr-\$(PRN "\$@").json" ;; esac
      SEND "\$s" '{"state":"closed"}' ;;
  *"-X POST"*"/issues/"*"/comments"*)
      printf '%s\n' "\$*" >> "$T/comments.txt"
      for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" >> "$T/comment-bodies.txt" ;; esac; done
      SEND "\$(ST comment 201)" '{"id":1}' ;;
  *"-X GET"*"/issues/"*"/comments"*)
      SEND "\$(ST comments 200)" "\$(cat "$T/pr-comments.json" 2>/dev/null)" ;;
  *"-X GET"*"search/issues"*)
      SEND "\$(ST search 200)" "\$(cat "$T/search.json" 2>/dev/null)" ;;
  *"-X POST"*"rerun-failed-jobs"*)
      printf '%s\n' "\$*" >> "$T/reruns.txt"
      SEND "\$(ST rerun 201)" '{}' ;;
  *"-X GET"*"/pulls/"*"/reviews"*)          # BH-2200: the lead-review read br_findings makes
      SEND "\$(ST reviews 200)" "\$(cat "$T/reviews.json" 2>/dev/null || echo '[]')" ;;
  *"-X GET"*"/pulls/"*)
      f="$T/pr-\$(PRN "\$@").json"; [ -f "\$f" ] || f="$T/pr.json"
      SEND "\$(ST pr 200)" "\$(cat "\$f" 2>/dev/null)" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# PR <number> <open|closed|merged> [branch] [title] [sha] — the REST PR object.
PR() {
  local n="$1" s="$2" br="${3:-ticket/TK-9}" ti="${4:-TK-9: a thing}" sh="${5:-$SHA}" st ma
  case "$s" in
    merged) st=closed; ma="\"$MERGEDAT\"" ;;
    closed) st=closed; ma=null ;;
    *)      st=open;   ma=null ;;
  esac
  jq -nc --arg st "$st" --argjson ma "$ma" --arg sh "$sh" --arg br "$br" --arg ti "$ti" \
    '{state:$st,merged_at:$ma,head:{sha:$sh,ref:$br},base:{ref:"main"},title:$ti}' \
    > "$T/pr-$n.json"
  cp "$T/pr-$n.json" "$T/pr.json"
}
SETST() { printf '%s' "$2" > "$T/st-$1"; }              # SETST <route> <status>
CLRST() { rm -f "$T"/st-* "$T/down" "$T/patch-noflip" 2>/dev/null; }
RESET() {
  scratch_rm "$H/state/blocked-resolver" 2>/dev/null
  rm -f "$H/state/merge-conductor/handoff"/* 2>/dev/null
  : > "$T/gh-argv.log"; : > "$T/queue.txt"; : > "$T/patched.txt"; : > "$T/comments.txt"
  : > "$T/comment-bodies.txt"; : > "$T/agent.txt"; : > "$T/prompt.txt"
  : > "$T/lane-alert.txt"; : > "$T/reruns.txt"
  : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
  : > "$H/state/merge-conductor/pr-state.tsv"
}
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH=/bin/true bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# ROW <key> <reason> <url> — one BLOCKED_HUMAN conductor row.
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" "$SHA" "$SHA" "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
# NUM <cap-key> <field> — a counter no tick ever wrote is 0, not "".
NUM() { local v; v=$(STATEJSON "$1" | jq -r "(.$2 // 0)" 2>/dev/null); case "$v" in ''|null) echo 0 ;; *) echo "$v" ;; esac; }
LOG="$H/logs/blocked-resolver.log"
# SPENT <cap-key> [rebuilds] — the cheaper rungs already ran, so the next tick
# takes the rung under test rather than rung 1.
SPENT() {
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg k "$1" --argjson n "${2:-0}" \
    '{project:"tproj",rkey:$k,mechanicals:1,fixrounds:1,rebuilds:$n,adjudications:0,rereviews:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/$1.json"
}
: > "$T/search.json"; printf '{"items":[]}' > "$T/search.json"
: > "$T/pr-comments.json"; printf '[]' > "$T/pr-comments.json"
: > "$T/run.log"

# ============================================================================
# 1. The helpers' rc contract: 0 act, 44 absent, 75 unverifiable.
#    Extracted from the script under test the way section 1 of
#    tests/blocked-resolver-test.sh extracts the classifier — sourcing the whole
#    file would run the drain.
# ============================================================================
: > "$T/helpers.sh"
for fn in br_slug_of_url br_pr_field br_pr_state br_pr_comment br_issue_comment br_close_pr br_findings; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$H/bin/blocked-resolver.sh" >> "$T/helpers.sh"
done
[ "$(grep -c '^}$' "$T/helpers.sh")" = 7 ] && ok \
  || bad "all seven REST helpers must exist in bin/blocked-resolver.sh (extracted $(grep -c '^}$' "$T/helpers.sh") of 7)"
# HELP <fn> [args...] -> stdout in $T/hout, rc in $HRC. The real lib and the real
# conductor lib are sourced; only the drain is left out.
HRC=0
HELP() {
  ( export HARNESS="$H"; LOG="$H/logs/blocked-resolver.log"
    say() { echo "$*" >> "$LOG"; }
    # shellcheck source=/dev/null
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$H/bin/lib/gh-rest.sh"
    # The verdict-trust set br_findings reads (BH-1992), sourced as the lane does.
    # shellcheck source=/dev/null
    . "$H/bin/lib/gh-pr-list.sh"
    # shellcheck source=/dev/null
    . "$T/helpers.sh"
    "$@" ) > "$T/hout" 2>/dev/null; HRC=$?
}
U=https://github.com/o/tproj/pull/9
RESET; CLRST
PR 9 open
HELP br_pr_state "$U"
[ "$HRC" = 0 ] && [ "$(cat "$T/hout")" = open ] && ok || bad "br_pr_state on an open PR: rc=$HRC out=$(cat "$T/hout")"
PR 9 merged
HELP br_pr_state "$U"
[ "$HRC" = 0 ] && [ "$(cat "$T/hout")" = merged ] && ok || bad "br_pr_state on a merged PR: rc=$HRC out=$(cat "$T/hout")"
PR 9 closed
HELP br_pr_state "$U"
[ "$HRC" = 0 ] && [ "$(cat "$T/hout")" = closed ] && ok || bad "br_pr_state on a closed PR: rc=$HRC out=$(cat "$T/hout")"
PR 9 open
SETST pr 404
HELP br_pr_state "$U"
[ "$HRC" = 44 ] && ok || bad "a 404 PR read must be rc 44 (ABSENT), got $HRC"
SETST pr 403
: > "$LOG"
HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "a 403 PR read must be rc 75 (UNVERIFIABLE), got $HRC"
grep -q 'HTTP 403' "$LOG" && ok || bad "a 75 must log the HTTP status it got (log: $(cat "$LOG"))"
grep -q 'UNVERIFIABLE' "$LOG" && ok || bad "a 75 must say UNVERIFIABLE in the log (log: $(cat "$LOG"))"
SETST pr 429; HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "429 must be 75, got $HRC"
SETST pr 500; HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "500 must be 75, got $HRC"
SETST pr 401; HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "401 must be 75, got $HRC"
CLRST; : > "$T/pr-9.json"; cp "$T/pr-9.json" "$T/pr.json"
HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "an EMPTY body on a 2xx single-object GET must be 75, got $HRC"
touch "$T/down"; PR 9 open; HELP br_pr_state "$U"
[ "$HRC" = 75 ] && ok || bad "gh exiting non-zero with no output (000/network) must be 75, got $HRC"
rm -f "$T/down"
# null head.ref (the head repo was deleted) is EMPTY at rc 0 — a read that WORKED.
jq -nc --arg sh "$SHA" '{state:"open",merged_at:null,head:{sha:$sh,ref:null},base:{ref:"main"},title:"t"}' > "$T/pr-9.json"
cp "$T/pr-9.json" "$T/pr.json"
HELP br_pr_field "$U" .head.ref 'head branch'
[ "$HRC" = 0 ] && [ -z "$(cat "$T/hout")" ] && ok \
  || bad "a null head.ref must read as EMPTY at rc 0, not as an error (rc=$HRC out=$(cat "$T/hout"))"
PR 9 open
HELP br_pr_field "$U" .head.ref 'head branch'
[ "$HRC" = 0 ] && [ "$(cat "$T/hout")" = ticket/TK-9 ] && ok || bad "br_pr_field .head.ref: rc=$HRC out=$(cat "$T/hout")"
HELP br_pr_field "$U" .base.ref 'base branch'
[ "$(cat "$T/hout")" = main ] && ok || bad "br_pr_field .base.ref must read the base branch (got $(cat "$T/hout"))"
HELP br_pr_field "$U" .title 'pr title'
[ "$(cat "$T/hout")" = "TK-9: a thing" ] && ok || bad "br_pr_field .title must read the title (got $(cat "$T/hout"))"
# the comment body NEVER on argv
: > "$T/gh-argv.log"; : > "$T/comment-bodies.txt"
HELP br_pr_comment "$U" 'a body with "quotes" and a SECRETWORD in it'
[ "$HRC" = 0 ] && ok || bad "br_pr_comment on a 201 must be rc 0, got $HRC"
grep -q 'body=@' "$T/gh-argv.log" && ok || bad "the comment body must go by FILE (-F body=@): $(cat "$T/gh-argv.log")"
grep -q SECRETWORD "$T/gh-argv.log" && bad "the comment body must never reach argv: $(cat "$T/gh-argv.log")" || ok
grep -q SECRETWORD "$T/comment-bodies.txt" && ok || bad "the body file must carry the body (got: $(cat "$T/comment-bodies.txt"))"
SETST comment 403
HELP br_pr_comment "$U" 'nope'
[ "$HRC" = 75 ] && ok || bad "a refused comment must be rc 75, got $HRC"
CLRST

# ── br_close_pr: THE REPRODUCTION, in the suite so it cannot come back ───────
# With GitHub answering nothing at all, br_close_pr used to read the empty
# answer as "not OPEN, nothing to close" and return SUCCESS — and its callers
# then enqueued a fresh build / recorded ABANDONED over a PR that is still open.
PR 9 open
touch "$T/down"
HELP br_close_pr "$U" why
[ "$HRC" = 75 ] && ok || bad "THE #783 BUG: a PR this lane could not READ must be rc 75, never a silent success (got $HRC)"
rm -f "$T/down"
SETST pr 403
HELP br_close_pr "$U" why
[ "$HRC" = 75 ] && ok || bad "a 403 on the state read must leave the PR alone at rc 75, got $HRC"
SETST pr 404
HELP br_close_pr "$U" why
[ "$HRC" = 0 ] && ok || bad "a 404 is ABSENT — there is nothing to close and that is rc 0, got $HRC"
CLRST
PR 9 closed
: > "$T/patched.txt"
HELP br_close_pr "$U" why
[ "$HRC" = 0 ] && ok || bad "an already-closed PR is nothing to close: rc 0, got $HRC"
[ -s "$T/patched.txt" ] && bad "an already-closed PR must not be PATCHed" || ok
PR 9 open
: > "$T/gh-argv.log"; : > "$T/patched.txt"; : > "$LOG"
HELP br_close_pr "$U" 'because reasons'
[ "$HRC" = 0 ] && ok || bad "a close that verifies must be rc 0, got $HRC"
grep -q "closed $U" "$LOG" && ok || bad "a verified close must be logged (log: $(cat "$LOG"))"
# ORDER: the comment lands BEFORE the PATCH, and a verifying GET follows it.
CO=$(grep -n 'X POST.*comments' "$T/gh-argv.log" | head -1 | cut -d: -f1)
PA=$(grep -n 'X PATCH' "$T/gh-argv.log" | head -1 | cut -d: -f1)
VE=$(grep -n 'X GET' "$T/gh-argv.log" | tail -1 | cut -d: -f1)
[ -n "$CO" ] && [ -n "$PA" ] && [ "$CO" -lt "$PA" ] && ok \
  || bad "the close comment must be POSTed BEFORE the PATCH (argv: $(cat "$T/gh-argv.log"))"
[ -n "$VE" ] && [ "$VE" -gt "$PA" ] && ok \
  || bad "a close must be VERIFIED by a fresh read after the PATCH (argv: $(cat "$T/gh-argv.log"))"
# A PATCH that fails is never a close, and never a "closed" log line.
PR 9 open; SETST patch 403
: > "$LOG"; : > "$T/patched.txt"
HELP br_close_pr "$U" why
[ "$HRC" = 75 ] && ok || bad "a refused PATCH must be rc 75, got $HRC"
grep -q "closed $U" "$LOG" && bad "a refused PATCH must NEVER log 'closed' (log: $(cat "$LOG"))" || ok
CLRST
# A PATCH that answers 2xx but whose re-read still says OPEN is not a close
# either: "closed" is earned by the verifying read, never by the 2xx.
PR 9 open; touch "$T/patch-noflip"
: > "$LOG"
HELP br_close_pr "$U" why
[ "$HRC" = 75 ] && ok || bad "a PATCH whose re-read still says open must be rc 75, got $HRC"
grep -q "closed $U" "$LOG" && bad "an unverified close must never log 'closed' (log: $(cat "$LOG"))" || ok
CLRST

# ── br_findings: an unreadable list is NOT an empty one ──────────────────────
PR 9 open
printf '[{"user":{"login":"cromford[bot]"},"body":"Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated."}]' > "$T/pr-comments.json"
HELP br_findings "$U"
[ "$HRC" = 0 ] && ok || bad "a readable comments list must be rc 0, got $HRC"
grep -q 'route is unauthenticated' "$T/hout" && ok || bad "br_findings must print the newest head-bound body (got $(cat "$T/hout"))"
printf '[]' > "$T/pr-comments.json"
HELP br_findings "$U"
[ "$HRC" = 0 ] && [ -z "$(cat "$T/hout")" ] && ok \
  || bad "an EMPTY comments list is a real 'no findings' at rc 0 (rc=$HRC out=$(cat "$T/hout"))"
SETST comments 403
HELP br_findings "$U"
[ "$HRC" = 75 ] && ok || bad "comments GitHub would not hand over must be rc 75, got $HRC"
CLRST
printf '[{"user":{"login":"cromford[bot]"},"body":"Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated."}]' > "$T/pr-comments.json"

# ============================================================================
# 2. THE MERGED GUARD. br_already_merged runs first for every park; an
#    unverifiable state must take NO rung at all — and must not be read as
#    "not merged, carry on rebuilding".
# ============================================================================
PARKQ="$H/state/build-queue/tproj/TK-9.json"
: > "$PARKQ"; touch -d "@$((NOW-259200))" "$PARKQ"
for row in "403:403 rate-limited" "429:429 secondary limit" "500:500 server error"; do
  st="${row%%:*}"; label="${row##*:}"
  RESET; CLRST; PR 9 open; SETST pr "$st"
  SPENT tproj-TK-9 2
  ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
  RUN
  [ -s "$T/queue.txt" ] && bad "$label: an unverifiable merged-state must enqueue NOTHING (queue: $(cat "$T/queue.txt"))" || ok
  [ -s "$T/patched.txt" ] && bad "$label: an unverifiable merged-state must close NOTHING" || ok
  grep -q 'UNVERIFIABLE' "$LOG" && ok || bad "$label: the tick must say the state was unverifiable (log: $(tail -3 "$LOG"))"
  grep -q 'EVENT resolver_rung' "$LOG" \
    && bad "$label: no rung may RUN on a state nobody read (log: $(tail -3 "$LOG"))" || ok
  [ "$(NUM tproj-TK-9 rebuilds)" = 2 ] && ok \
    || bad "$label: no counter may be spent (rebuilds=$(NUM tproj-TK-9 rebuilds), want 2)"
  [ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = "" ] && ok || bad "$label: no outcome may be recorded"
done
# gh down entirely (000/network), and a 2xx with an EMPTY body: same answer.
for mode in down empty; do
  RESET; CLRST; PR 9 open; SPENT tproj-TK-9 2
  case "$mode" in
    down)  touch "$T/down" ;;
    empty) : > "$T/pr-9.json"; : > "$T/pr.json" ;;
  esac
  ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
  RUN
  [ -s "$T/queue.txt" ] && bad "$mode: must enqueue nothing (queue: $(cat "$T/queue.txt"))" || ok
  [ -s "$T/patched.txt" ] && bad "$mode: must close nothing" || ok
  rm -f "$T/down"
done
# POSITIVE CONTROL: a PR the read says is MERGED resolves the park.
RESET; CLRST; PR 9 merged; SPENT tproj-TK-9 2
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = RESOLVED_MERGED ] && ok \
  || bad "a merged PR must RESOLVE the park (outcome=$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""'))"
[ -s "$T/queue.txt" ] && bad "a resolved-merged park must not enqueue" || ok
[ -s "$T/patched.txt" ] && bad "a merged PR must never be closed" || ok
# POSITIVE CONTROL: a 404 is ABSENT, not unknown — the ladder proceeds.
RESET; CLRST; PR 9 open; SETST pr 404; SPENT tproj-TK-9 2
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
grep -q 'HTTP 404' "$LOG" && ok || bad "a 404 must be logged as absent, never as unverifiable (log: $(tail -3 "$LOG"))"
grep -q 'UNVERIFIABLE' "$LOG" && bad "a 404 is ABSENT and must never be called UNVERIFIABLE" || ok
# The ladder RUNS on a 404 — it does not defer. (It then refuses the enqueue for
# want of a ticket key, because a PR GitHub says is absent carries no branch and
# no title to derive one from; that refusal is BH-530's, not this ticket's.)
grep -q 'EVENT resolver_rung' "$LOG" && ok \
  || bad "a 404 PR read is ABSENT and the rebuild rung must still RUN (log: $(tail -4 "$LOG"))"
CLRST

# ============================================================================
# 3. THE MERGED SEARCH over REST search/issues. A search that did not answer is
#    not "this ticket never merged".
# ============================================================================
RESET; CLRST; PR 9 open; SETST search 403; SPENT tproj-TK-9 2
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ -s "$T/queue.txt" ] && bad "an unreadable merged-search must enqueue nothing (queue: $(cat "$T/queue.txt"))" || ok
[ -s "$T/patched.txt" ] && bad "an unreadable merged-search must close nothing" || ok
[ "$(NUM tproj-TK-9 rebuilds)" = 2 ] && ok \
  || bad "an unreadable merged-search must spend no counter (rebuilds=$(NUM tproj-TK-9 rebuilds))"
grep -q 'search/issues' "$T/gh-argv.log" && ok \
  || bad "the merged-PR lookup must go through REST search/issues (argv: $(cat "$T/gh-argv.log"))"
# 200 with a real hit on ticket/TK-9, merged AFTER the park -> resolved.
RESET; CLRST; PR 9 open; SPENT tproj-TK-9 2
printf '{"items":[{"html_url":"https://github.com/o/tproj/pull/50"}]}' > "$T/search.json"
jq -nc --arg at "$MERGEDAT" --arg sh "$SHA" \
  '{state:"closed",merged_at:$at,head:{sha:$sh,ref:"ticket/TK-9"},base:{ref:"main"},title:"TK-9: the real one"}' \
  > "$T/pr-50.json"
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = RESOLVED_MERGED ] && ok \
  || bad "a merged PR for this TICKET must resolve the park (outcome=$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""'))"
grep -q '^tproj TK-9 ' "$T/queue.txt" \
  && bad "a ticket that already merged must not be rebuilt (queue: $(cat "$T/queue.txt"))" || ok
# THE TOKENISER NEGATIVE: TK-91 is not TK-9.
RESET; CLRST; PR 9 open; SPENT tproj-TK-9 2
printf '{"items":[{"html_url":"https://github.com/o/tproj/pull/51"}]}' > "$T/search.json"
jq -nc --arg at "$MERGEDAT" --arg sh "$SHA" \
  '{state:"closed",merged_at:$at,head:{sha:$sh,ref:"ticket/TK-91"},base:{ref:"main"},title:"TK-91: another ticket"}' \
  > "$T/pr-51.json"
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = RESOLVED_MERGED ] \
  && bad "GitHub search tokenises on the hyphen: a TK-91 PR must never resolve TK-9" || ok
printf '{"items":[]}' > "$T/search.json"

# ============================================================================
# 4. THE CLOSE. Comment, then close, then VERIFY — and a close that did not
#    happen defers the whole rebuild to the next tick.
# ============================================================================
RESET; CLRST; PR 9 open; SPENT tproj-TK-9 0
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ -s "$T/patched.txt" ] && ok || bad "the rebuild rung must close the stale PR (argv: $(cat "$T/gh-argv.log"))"
grep -q 'Superseded by a fresh build' "$T/comment-bodies.txt" && ok \
  || bad "the close must carry its reason as a comment (bodies: $(cat "$T/comment-bodies.txt"))"
grep -q "closed $U" "$LOG" && ok || bad "a verified close must be logged (log: $(tail -3 "$LOG"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok || bad "the rebuild must enqueue the ticket (queue: $(cat "$T/queue.txt"))"
[ "$(NUM tproj-TK-9 rebuilds)" = 1 ] && ok \
  || bad "a landed rebuild spends its counter (rebuilds=$(NUM tproj-TK-9 rebuilds))"
# THE 403 ROW: the PATCH is refused, so nothing at all is spent or enqueued.
RESET; CLRST; PR 9 open; SETST patch 403; SPENT tproj-TK-9 0
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
grep -q "closed $U" "$LOG" && bad "a refused PATCH must never log a close (log: $(tail -3 "$LOG"))" || ok
[ -s "$T/queue.txt" ] && bad "a PR that could not be closed must not be rebuilt (queue: $(cat "$T/queue.txt"))" || ok
[ "$(NUM tproj-TK-9 rebuilds)" = 0 ] && ok \
  || bad "a deferred rebuild spends no counter (rebuilds=$(NUM tproj-TK-9 rebuilds))"
grep -q 'rebuild deferred' "$LOG" && ok || bad "the deferral must be said out loud (log: $(tail -3 "$LOG"))"
grep -q 'EVENT resolver_rung' "$LOG" && bad "a rung that did not run must not be recorded as an event" || ok
# ... and the SAME park, next tick, with GitHub answering: it closes and enqueues.
CLRST; : > "$LOG"; : > "$T/queue.txt"; : > "$T/patched.txt"
PR 9 open
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ -s "$T/patched.txt" ] && ok || bad "retry-next-tick must be real: the second tick closes the PR"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok \
  || bad "the second tick must enqueue the rebuild it deferred (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 5. ABANDON. The outcome is stamped only AFTER the PR is really closed: a
#    ticket recorded ABANDONED over a PR still open is the worst of both.
# ============================================================================
RESET; CLRST; PR 9 open; SETST patch 403; SPENT tproj-TK-9 3
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] \
  && bad "a PR that could not be closed must NOT be stamped ABANDONED" || ok
grep -q 'ABANDONED' "$H/logs/ALERTS.log" && bad "no ABANDONED alert for an abandon that did not happen" || ok
grep -q "closed $U" "$LOG" && bad "no close may be claimed for an abandon that did not happen (log: $(tail -3 "$LOG"))" || ok
grep -q 'ABANDON deferred' "$LOG" && ok || bad "the deferred abandon must say so (log: $(tail -3 "$LOG"))"
# positive control: GitHub answers, the abandon completes.
CLRST; : > "$LOG"; : > "$H/logs/ALERTS.log"; : > "$T/comment-bodies.txt"; : > "$T/patched.txt"
PR 9 open
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] && ok \
  || bad "with GitHub answering, the cap must ABANDON (outcome=$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""'))"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" && ok || bad "the abandon must write its ALERTS line"
grep -q 'Abandoned by' "$T/comment-bodies.txt" && ok \
  || bad "the abandon must comment on the PR before closing it (bodies: $(cat "$T/comment-bodies.txt"))"
[ -s "$T/patched.txt" ] && ok || bad "the abandon must close the PR"

# ============================================================================
# 6. THE FIX ROUND. Findings that could not be READ are not "no findings" —
#    that reading is exactly how an unreadable PR became a REBUILD FRESH.
# ============================================================================
# A real local clone, because the fix round refuses to start without one and a
# refusal would make the row below pass for the wrong reason.
ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
git -C "$SEED" checkout -q -b ticket/TK-9
printf 'the branch changed this line\n' >> "$SEED/a.txt"
git -C "$SEED" commit -qam "work"; git -C "$SEED" push -q origin ticket/TK-9
git -C "$SEED" checkout -q main
printf 'main changed this line\n' >> "$SEED/a.txt"
git -C "$SEED" commit -qam "main work"; git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
BRHEAD=$(git -C "$ORIGIN" rev-parse ticket/TK-9)
printf '%s ticket/TK-9\n' "$BRHEAD" > "$T/prref"

RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
SETST comments 403
ROW "o/tproj#9" "head-not-reapproved: the head was never re-approved" "$U"
RUN
grep -q 'fix round not started' "$LOG" && ok || bad "unreadable findings must spend no rung (log: $(tail -3 "$LOG"))"
grep -q 'REBUILD FRESH' "$LOG" && bad "THE #783 BUG: unreadable findings must NEVER become a rebuild (log: $(tail -3 "$LOG"))" || ok
[ -s "$T/agent.txt" ] && bad "no agent call may be bought on findings we could not read" || ok
[ -s "$T/queue.txt" ] && bad "nothing may be enqueued (queue: $(cat "$T/queue.txt"))" || ok
[ -s "$T/patched.txt" ] && bad "nothing may be closed" || ok
[ "$(NUM tproj-TK-9 fixrounds)" = 0 ] && ok \
  || bad "no fix-round counter may be spent (fixrounds=$(NUM tproj-TK-9 fixrounds))"
# POSITIVE CONTROL: the findings are read and reach the agent's prompt.
RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
ROW "o/tproj#9" "head-not-reapproved: the head was never re-approved" "$U"
RUN
grep -q 'the route is unauthenticated' "$T/prompt.txt" && ok \
  || bad "the posted findings must reach the fix round's prompt (prompt: $(head -c 300 "$T/prompt.txt"))"

# ============================================================================
# 7. ADJUDICATE. The diff is the whole evidence; a diff we could not read must
#    not buy a review-stage agent call.
# ============================================================================
printf -- '+++ b/src/x.tsx\n+  window.confirm("really?")\n' > "$T/prdiff"
RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
SETST diff 403
ROW "o/tproj#9" "iron-law: 1 hit(s)" "$U"
RUN
[ -s "$T/agent.txt" ] && bad "a diff we could not read must not buy an adjudication (agent: $(cat "$T/agent.txt"))" || ok
grep -q 'not bought' "$LOG" && ok || bad "the skipped adjudication must say so (log: $(tail -3 "$LOG"))"
[ "$(NUM tproj-TK-9 adjudications)" = 0 ] && ok \
  || bad "no adjudication counter may be spent (adjudications=$(NUM tproj-TK-9 adjudications))"
# POSITIVE CONTROL: the diff is read over REST, with the diff Accept header.
RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
ROW "o/tproj#9" "iron-law: 1 hit(s)" "$U"
RUN
grep -q 'window.confirm' "$T/prompt.txt" && ok \
  || bad "the PR diff must reach the adjudication prompt (prompt: $(head -c 300 "$T/prompt.txt"))"
grep -q 'vnd.github.v3.diff' "$T/gh-argv.log" && ok \
  || bad "the diff must be read with the REST diff Accept header (argv: $(cat "$T/gh-argv.log"))"

# ============================================================================
# 8. MECHANICAL. A CI re-run that GitHub refused is not a rung that ran.
# ============================================================================
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
# --- fixture override: mc_rebase says "nothing to merge" (stdout = the head) ---
mc_rebase() { printf '%s' "$BRHEAD"; return 0; }
EOF
printf '77\n' > "$T/failedruns"
printf 'the job log\n' > "$T/joblog"
RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
ROW "o/tproj#9" "red-twice: still red after a re-run" "$U"
RUN
[ "$(NUM tproj-TK-9 mechanicals)" = 1 ] && ok \
  || bad "a dispatched CI re-run spends the mechanical rung (mechanicals=$(NUM tproj-TK-9 mechanicals))"
[ -s "$T/reruns.txt" ] && ok || bad "the re-run must POST rerun-failed-jobs (argv: $(cat "$T/gh-argv.log"))"
grep -q 'rerun-failed-jobs' "$T/gh-argv.log" && ok || bad "the re-run must use the REST rerun-failed-jobs endpoint"
# ... and the same rung when GitHub refuses the re-run: nothing spent at all.
RESET; CLRST; PR 9 open ticket/TK-9 'TK-9: a thing' "$BRHEAD"
SETST rerun 403
ROW "o/tproj#9" "red-twice: still red after a re-run" "$U"
RUN
[ "$(NUM tproj-TK-9 mechanicals)" = 0 ] && ok \
  || bad "a re-run GitHub refused must spend nothing (mechanicals=$(NUM tproj-TK-9 mechanicals))"
grep -q 'UNVERIFIABLE' "$LOG" && ok || bad "the refused re-run must say UNVERIFIABLE (log: $(tail -3 "$LOG"))"
grep -q 'mechanical-failed' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" 2>/dev/null \
  && bad "a re-run that was never dispatched must not be recorded as a failed rung" || ok
CLRST

# ============================================================================
# 9. NEGATIVES over every call this suite made: no GraphQL verb ever reached gh,
#    and no comment body ever reached argv.
# ============================================================================
ALL="$T/all-argv.log"
cat "$T/gh-argv.log" > "$ALL" 2>/dev/null
grep -Eq '(^| )(pr|issue) (view|list|close|comment|diff|merge)' "$ALL" \
  && bad "a GraphQL gh verb reached the stub: $(grep -E '(^| )(pr|issue) ' "$ALL" | head -3)" || ok

# ============================================================================
# 10. MUTATION (D1). Break each behavior once; the row above must go red.
# ============================================================================
MUT="$T/mut"; mkdir -p "$MUT"
MUT_RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH=/bin/true \
                bash "$1" >>"$T/run.log" 2>&1 ) || true; }
# 10a. br_close_pr answers 0 where it answers 75 — the #783 bug put back. Every
#      75 in the function is a "GitHub did not answer"; mapping any of them to
#      success is what closed and rebuilt PRs that were open.
sed '/^br_close_pr() {/,/^}$/ s/return 75/return 0/g' \
  "$H/bin/blocked-resolver.sh" > "$MUT/br-close.sh"
cmp -s "$H/bin/blocked-resolver.sh" "$MUT/br-close.sh" \
  && bad "mutation 10a: br_close_pr's rc-75 exits were not found to mutate" || ok
RESET; CLRST; PR 9 open; SETST patch 403; SPENT tproj-TK-9 0
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
MUT_RUN "$MUT/br-close.sh"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok \
  || bad "mutation 10a: with br_close_pr's 75s removed, the PATCH-403 row must go RED (it did not enqueue)"
CLRST
# 10b. br_pr_field answers 0-with-nothing where it answers 75 — #768 itself, the
#      read that could not be made returned as a state. Every guard downstream
#      then reads "not merged / not open" off silence, and the 403 rows in
#      sections 2 and 4 must both go red.
sed '/^br_pr_field() {/,/^}$/ s/^    \*)  say /    *)  rc=0; say /' \
  "$H/bin/blocked-resolver.sh" > "$MUT/br-field.sh"
cmp -s "$H/bin/blocked-resolver.sh" "$MUT/br-field.sh" \
  && bad "mutation 10b: br_pr_field's unverifiable arm was not found to mutate" || ok
RESET; CLRST; PR 9 open; SETST pr 403; SPENT tproj-TK-9 2
ROW "o/tproj#9" "merge-failed-twice: could not merge" "$U"
MUT_RUN "$MUT/br-field.sh"
# The real thing takes NO rung on this input (section 2 asserts that directly);
# the mutant walks straight down the ladder on the silence.
if grep -q 'EVENT resolver_rung' "$LOG"; then ok
else bad "mutation 10b: with an unverifiable read answering 0, the 403 row must go RED (it took no rung; log: $(tail -3 "$LOG"))"; fi
CLRST
# 10c. the allow tag on the one raw `gh run view` line: strip it and the
#      no-GraphQL guard scanner must flag the file.
cat > "$T/scan.sh" <<'SCAN'
#!/bin/bash
set -uo pipefail
f="${1:?usage: scan.sh <file>}"
grep -qx '# gh-rest: no-graphql' "$f" || { echo "unmarked"; exit 2; }
hits=0; n=0
while IFS= read -r line; do
  n=$((n+1))
  case "$line" in *"# gh-guard-allow: "*)
    reason=${line#*"# gh-guard-allow: "}
    case "$reason" in *[![:space:]]*) continue ;; esac
    ;;
  esac
  code=$(printf '%s\n' "$line" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//')
  grep -Eq '(^|[[:space:];|&(]|\$\()[[:space:]]*gh[[:space:]]+(pr|issue|run)[[:space:]]' <<<"$code" \
    && { echo "$f:$n"; hits=$((hits+1)); }
done < "$f"
[ "$hits" = 0 ] || exit 1
exit 0
SCAN
bash "$T/scan.sh" "$H/bin/blocked-resolver.sh" >/dev/null 2>&1 && ok \
  || bad "bin/blocked-resolver.sh must be marked and clean under the no-GraphQL scanner"
sed 's/  # gh-guard-allow: .*$//' "$H/bin/blocked-resolver.sh" > "$MUT/no-allow.sh"
cmp -s "$H/bin/blocked-resolver.sh" "$MUT/no-allow.sh" \
  && bad "mutation 10c: no '# gh-guard-allow:' tag was found to strip" || ok
bash "$T/scan.sh" "$MUT/no-allow.sh" >/dev/null 2>&1 \
  && bad "mutation 10c: with the allow tag stripped the scanner must flag the raw gh run call" || ok
grep -qx '# gh-rest: no-graphql' "$H/bin/blocked-resolver.sh" && ok \
  || bad "bin/blocked-resolver.sh must carry the '# gh-rest: no-graphql' marker"

echo "blocked-resolver-rest.bh-783: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
