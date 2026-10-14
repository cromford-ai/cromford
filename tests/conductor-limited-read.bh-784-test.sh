#!/bin/bash
# tests/conductor-limited-read.bh-784-test.sh — BH-784: the merge family reads REST,
# and a LIMITED read never dequeues, relabels or closes.
#
# THE INCIDENT (#768, 2026-09-18). `gh pr view` speaks GraphQL, was rate
# limited, and answered EMPTY. Every decision path in the merge family read that
# empty answer as a fact about the PR — "no such PR", "not open", "no label" —
# and acted on it. bin/lib/gh-rest.sh makes the three answers distinguishable
# (rc 0 acted on, 44 ABSENT, 75 UNVERIFIABLE); this suite is what proves the
# merge conductor, the box merge queue and the two sweeps actually obey it.
#
# WHY DRIVEN AND NOT GREPPED. "Nothing was dequeued" is a claim about a FILE
# that must still exist after a tick, and "nothing was relabelled" is a claim
# about an argv log. A grep for `gh_rest` in the source passes just as happily
# on a script that calls it and then ignores the rc. Sections 5-7 run the real
# bin/merge-conductor.sh, bin/merge-queue.sh and bin/merge-sweep.sh against a
# scratch $HARNESS with a stub `gh` that answers HTTP STATUS LINES; sections
# 1-4 source the real lib.
#
# Section 9 is the mutation check: a copy of the lib whose rc-75 branch prints
# nothing and returns 0 — the exact #768 shape — must turn sections 5 and 6 RED.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/conductor-limited-read.bh-784-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1939: the scratch tree below carries no lane registry, and mc/queue.sh no
# longer has a literal default; this is the value a box resolves from
# catalog/lanes.d/_lib.mc-queue.json.
export MC_QUEUE_TTL=300
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111; H2=bbbbbbbb2222; MSHA=cccccccc3333
MUT="${LIMITED_READ_MUTATE:-0}"   # section 9 re-runs this file with it set

# ── scratch harness ──────────────────────────────────────────────────────────
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/fakebin" "$T/tmp"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
   mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/" 2>/dev/null || true
if [ "$MUT" = 1 ]; then
  # THE #768 SHAPE, injected: an unverifiable read answers "nothing" with rc 0,
  # so every call site reads silence as a fact. Sections 5/6 must go red.
  # BH-477.3: mc_pr_view is defined by bin/lib/mc/classify.sh — the lib is a
  # 20-line shim that sources it. Mutating the shim would inject nothing, and a
  # mutation that changes no behaviour makes sections 5/6 pass and case 9 lie.
  perl -0pi -e 's/^(mc_pr_view\(\) \{.*?\n)/$1  printf ""; return 0\n/ms' "$T/h/bin/lib/mc/classify.sh"
fi
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" FLEET_CONF="$T/h/fleet.conf"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
# BH-1194 split bin/jobs-client.sh into bin/lib/jobs/*.sh; the client refuses to
# run without its modules, so a fixture that copies the client copies them too.
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - - box-issuer\n' > "$T/h/fleet.conf"
# curl: the jobs client. Every read 404s (no ledger row), which is the fallback
# path the whole merge family is specified against — and, because the client
# refuses to call at all without HARNESS_SECRET, that is what every section but
# 6b gets whatever is routed here.
# /api/verdict is the exception section 6b needs: the head-bound gate's input is
# a REVIEWED SHA off the verdict row, so $T/verdict-sha puts one there and the
# real bin/jobs-client.sh parses it. Absent the file it 404s like everything else.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/verdict*) if [ -s "$GHFX/verdict-sha" ]; then
                    jq -nc --arg s "$(cat "$GHFX/verdict-sha")" \
                      '{verdict:"APPROVE",tier:2,provenance:"claude",job_id:"j1",reviewed_sha:$s}'
                    printf '200\n'
                  else printf '{"error":"not found"}\n404\n'; fi ;;
  */api/ledger*) printf '{"ok":true}\n200\n' ;;
  *)             printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "cannot source the lib"; exit 1; }
mc_init

RC=0
call() { local of="$1"; shift; "$@" > "$of" 2>/dev/null; RC=$?; }
argv() { cat "$T/gh-argv.log"; }

# ============================================================================
# 1. The REST helpers: the vocabulary, and the three answers kept apart
# ============================================================================
[ "$MUT" = 1 ] || {
ghfx_routes_reset
ghfx_route GET 'repos/o/r/pulls/1' 200 "$(ghfx_pr open - "$H1" ticket/x main 'queued,mergify' true clean operator '')"
call "$T/o" mc_rest_pr_json o/r 1
[ "$RC" = 0 ] && ok || bad "1: a 200 pull read must be rc 0 (got $RC)"
[ "$(jq -r .STATE     < "$T/o")" = OPEN ]      && ok || bad "1: state open must normalise to OPEN (got $(jq -r .STATE < "$T/o"))"
[ "$(jq -r .MERGEABLE < "$T/o")" = MERGEABLE ] && ok || bad "1: mergeable true must be MERGEABLE"
[ "$(jq -r .MSTATE    < "$T/o")" = CLEAN ]     && ok || bad "1: mergeable_state clean must be CLEAN"
[ "$(jq -r .LABELS    < "$T/o")" = 'queued,mergify' ] && ok || bad "1: labels must join to a csv (got $(jq -r .LABELS < "$T/o"))"

ghfx_routes_reset
ghfx_route GET 'repos/o/r/pulls/1' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/x main '' null dirty operator "$MSHA")"
call "$T/o" mc_rest_pr_json o/r 1
[ "$(jq -r .STATE     < "$T/o")" = MERGED ]  && ok || bad "1: merged_at set must be MERGED, never CLOSED"
[ "$(jq -r .MERGEABLE < "$T/o")" = UNKNOWN ] && ok || bad "1: mergeable null must be UNKNOWN, never CONFLICTING"
[ "$(jq -r .MSTATE    < "$T/o")" = DIRTY ]   && ok || bad "1: mergeable_state must upper-case"

ghfx_routes_reset
ghfx_route GET 'repos/o/r/pulls/1' 200 "$(ghfx_pr closed - "$H1" ticket/x main '' false dirty operator '')"
[ "$(mc_pr_view https://github.com/o/r/pull/1 .STATE)" = CLOSED ] && ok || bad "1: closed with no merged_at must be CLOSED, never MERGED"
[ "$(mc_pr_view https://github.com/o/r/pull/1 .MERGEABLE)" = CONFLICTING ] && ok || bad "1: mergeable false must be CONFLICTING"

# the three answers, kept apart
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 403 '{"message":"API rate limit exceeded"}'
call "$T/o" mc_pr_view https://github.com/o/r/pull/1 .STATE
[ "$RC" = 75 ] && ok || bad "1: a 403 read must be rc 75 UNVERIFIABLE (got $RC)"
[ ! -s "$T/o" ] && ok || bad "1: a 403 read must print NOTHING (got '$(cat "$T/o")')"
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 404 '{"message":"Not Found"}'
call "$T/o" mc_pr_view https://github.com/o/r/pull/1 .STATE
[ "$RC" = 44 ] && ok || bad "1: a 404 read must be rc 44 ABSENT, not 75 (got $RC)"
ghfx_routes_reset; ghfx_route GET 'repos/o/r/pulls/1' 200 ''
call "$T/o" mc_pr_view https://github.com/o/r/pull/1 .STATE
[ "$RC" = 75 ] && ok || bad "1: the #768 shape (2xx, empty body) must be 75, never 0 (got $RC)"

# mc_pr_diff carries the diff Accept header and passes the rc through
ghfx_routes_reset
ghfx_route DIFF 'repos/o/r/pulls/1' 200 '+++ b/src/x.ts
+const a = 1;'
ghfx_log_reset
mc_pr_diff https://github.com/o/r/pull/1 "$T/d"; RC=$?
[ "$RC" = 0 ] && grep -q 'const a = 1' "$T/d" && ok || bad "1: mc_pr_diff must fetch the diff (rc=$RC)"
case "$(argv)" in *'application/vnd.github.v3.diff'*) ok ;; *) bad "1: mc_pr_diff must ask for the diff media type: $(argv)" ;; esac
ghfx_routes_reset; ghfx_route DIFF 'repos/o/r/pulls/1' 403 '{"message":"nope"}'
mc_pr_diff https://github.com/o/r/pull/1 "$T/d"; RC=$?
[ "$RC" = 75 ] && ok || bad "1: a diff read that 403s must be 75, not a silent empty diff (got $RC)"

# the comment body goes by FILE: never on argv, never in a process list
ghfx_routes_reset; ghfx_route POST 'repos/o/r/issues/1/comments' 200 '{"id":1}'
ghfx_log_reset
mc_pr_comment https://github.com/o/r/pull/1 'SECRETWORD in the body'; RC=$?
[ "$RC" = 0 ] && ok || bad "1: mc_pr_comment must succeed on a 200 (got $RC)"
case "$(argv)" in *SECRETWORD*) bad "1: the comment body reached argv: $(argv)" ;; *) ok ;; esac
case "$(argv)" in *'body=@'*) ok ;; *) bad "1: the comment body must go by file (-F body=@): $(argv)" ;; esac
[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && ok || bad "1: mc_pr_comment left a temp file behind ($(ls -A "$T/tmp"))"
ghfx_routes_reset; ghfx_route POST 'repos/o/r/issues/1/comments' 403 '{"message":"nope"}'
mc_pr_comment https://github.com/o/r/pull/1 hello; RC=$?
[ "$RC" != 0 ] && ok || bad "1: a comment POST that 403s must not answer success"

# mc_rest_pages: two pages concatenated, and a failed page is not a short list
ghfx_routes_reset
P1=$(jq -nc '[range(100)] | map({filename:("f\(.).ts")})')
P2=$(jq -nc '[{filename:"a.ts"},{filename:"b.ts"},{filename:"c.ts"}]')
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=1' 200 "$P1"
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=2' 200 "$P2"
call "$T/o" mc_rest_pages repos/o/r/pulls/1/files
[ "$RC" = 0 ] && [ "$(jq length < "$T/o")" = 103 ] && ok || bad "1: two pages must concatenate to 103 (rc=$RC got $(jq length < "$T/o" 2>/dev/null))"
ghfx_routes_reset
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=1' 200 "$P1"
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=2' 403 '{"message":"nope"}'
call "$T/o" mc_rest_pages repos/o/r/pulls/1/files
[ "$RC" = 75 ] && ok || bad "1: a page that 403s must fail the whole list, never truncate it (got rc=$RC)"
[ ! -s "$T/o" ] && ok || bad "1: a failed paginated read must print nothing"
# The cap BOUNDS the loop, and hitting it on a FULL page is a failed read, not
# a short list: page 2 is never asked for, so "103 files" would be a claim about
# a list nobody finished reading — the truncation half of D12.
ghfx_routes_reset
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=1' 200 "$P1"
ghfx_route GET 'repos/o/r/pulls/1/files?per_page=100&page=2' 200 "$P2"
ghfx_log_reset
call "$T/o" mc_rest_pages repos/o/r/pulls/1/files 1
[ "$RC" = 75 ] && ok || bad "1: a full page at the cap must fail the read, never pass as complete (rc=$RC)"
[ ! -s "$T/o" ] && ok || bad "1: a read stopped by the page cap must print nothing (got $(jq length < "$T/o" 2>/dev/null))"
case "$(argv)" in *'page=2'*) bad "1: the cap did not bound the loop — page 2 was fetched" ;; *) ok ;; esac
# …and a cap the list fits inside is a normal, complete read.
call "$T/o" mc_rest_pages repos/o/r/pulls/1/files 2
[ "$RC" = 0 ] && [ "$(jq length < "$T/o")" = 103 ] && ok \
  || bad "1: a list that ENDS inside the cap must read normally (rc=$RC got $(jq length < "$T/o" 2>/dev/null))"

# pr_body_read: mc_is_harness_pr runs the body read DOWN A PIPE, so an rc kept
# in a variable dies with the subshell and the tick reports "no marker" for a
# body GitHub refused to hand over. The flag file is how the refusal gets back.
# shellcheck source=/dev/null
eval "$(sed -n '/^pr_body_read() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
BPR=https://github.com/example-org/demo-os/pull/31
BF="$T/body-unread.flag"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/31' 403 '{"message":"nope"}'
rm -f "$BF"
mc_is_harness_pr feature/x "" pr_body_read "$BPR" "$BF" \
  && bad "1: a body nobody could read must not answer 'harness PR'" || ok
[ -f "$BF" ] && ok || bad "1: a refused body read must leave its flag, or the tick claims 'no marker' about a body it never saw"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 '{"body":"opened by a harness build"}'
rm -f "$BF"
mc_is_harness_pr feature/x "" pr_body_read "$BPR" "$BF" && ok || bad "1: a body carrying the marker IS a harness PR"
[ ! -f "$BF" ] && ok || bad "1: a body that READ must not be flagged unread"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 '{"body":"written by hand"}'
rm -f "$BF"
mc_is_harness_pr feature/x "" pr_body_read "$BPR" "$BF" && bad "1: a body without the marker is not a harness PR" || ok
[ ! -f "$BF" ] && ok || bad "1: a real 'no marker' must not be reported as an unread body"

# ============================================================================
# 2. mc_stack_parent — a read that failed is NONE ("keep waiting"), never a
#    reason to merge. And a real empty list is the same NONE.
# ============================================================================
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls*' 403 '{"message":"nope"}'
: > "$MC_LOG"
[ "$(mc_stack_parent example-org/demo-os ticket/x)" = "$(printf 'NONE\t-')" ] && ok || bad "2: a 403 list read must answer NONE (got '$(mc_stack_parent example-org/demo-os ticket/x)')"
# …and SAYS it was a refused read. Both answers are the word NONE, so the log
# line is the only thing that tells "no parent PR" from "GitHub would not say".
grep -q 'stack-parent read for example-org/demo-os head ticket/x UNVERIFIABLE' "$MC_LOG" && ok \
  || bad "2: a refused parent read must name the status it got (log: $(cat "$MC_LOG"))"
# BH-1485 — THE LINE SHAPE CHANGED, and this is the assertion that pins it.
# The read was `list=$(gh_rest_pr_list …)`, a subshell, so GH_REST_STATUS died
# in it and this line said `(HTTP 000)` for every refusal. It reads
# `HTTP <status> <reason>` now: a 403 whose body does not say "rate limit" is
# `HTTP 403` with no reason word, and the one below is `HTTP 403 rate-limit`.
grep -q '(HTTP 403)' "$MC_LOG" && ok \
  || bad "2: a 403 must be logged as its own status, never as 000 (log: $(cat "$MC_LOG"))"
grep -q 'HTTP 000' "$MC_LOG" && bad "2: the BH-781/BH-1485 bug: a classified 403 logged as HTTP 000" || ok
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls*' 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
: > "$MC_LOG"
[ "$(mc_stack_parent example-org/demo-os ticket/x)" = "$(printf 'NONE\t-')" ] && ok || bad "2: a rate-limited list read must still answer NONE"
grep -q 'HTTP 403 rate-limit' "$MC_LOG" && ok \
  || bad "2: an exhausted quota must read 'HTTP 403 rate-limit' — the whole subject of BH-1485 (log: $(cat "$MC_LOG"))"
# A read that never got a status line at all is the one case that IS 000, and it
# names why: `HTTP 000 network`, which no longer collides with a refusal.
ghfx_routes_reset
GHFX_SAVED=$(cat "$T/fakebin/gh"); printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
: > "$MC_LOG"
[ "$(mc_stack_parent example-org/demo-os ticket/x)" = "$(printf 'NONE\t-')" ] && ok || bad "2: a dead gh must still answer NONE"
grep -q 'HTTP 000 network' "$MC_LOG" && ok \
  || bad "2: a dead client must read 'HTTP 000 network', which is what 000 is FOR (log: $(cat "$MC_LOG"))"
printf '%s' "$GHFX_SAVED" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls*' 200 '[]'
: > "$MC_LOG"
[ "$(mc_stack_parent example-org/demo-os ticket/x)" = "$(printf 'NONE\t-')" ] && ok || bad "2: a real empty list must answer NONE"
grep -q 'UNVERIFIABLE' "$MC_LOG" && bad "2: a REAL empty list is a fact, not an unverifiable read" || ok
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls*' 200 '[{"state":"open","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/9"}]'
ghfx_log_reset
[ "$(mc_stack_parent example-org/demo-os ticket/x)" = "$(printf 'OPEN\thttps://github.com/example-org/demo-os/pull/9')" ] \
  && ok || bad "2: an open parent must answer OPEN + its url (got '$(mc_stack_parent example-org/demo-os ticket/x)')"
case "$(argv)" in *'head=example-org:ticket/x'*) ok ;; *) bad "2: REST head= must be owner:branch (got $(argv))" ;; esac
case "$(argv)" in *'state=all'*) ok ;; *) bad "2: the parent probe must ask state=all: $(argv)" ;; esac
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls*' 200 '[{"state":"closed","merged_at":"2026-09-18T00:00:00Z","html_url":"https://github.com/example-org/demo-os/pull/9"}]'
[ "$(mc_stack_parent example-org/demo-os ticket/x | cut -f1)" = MERGED ] && ok || bad "2: a merged parent must read MERGED"

# ============================================================================
# 3. mc_queue_state / mc_inqueue — an outage is `unknown`, never an ejection
# ============================================================================
QURL=https://github.com/example-org/demo-os/pull/31
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/31' 403 '{"message":"nope"}'
[ "$(mc_queue_state "$QURL")" = unknown ] && ok || bad "3: a 403 must answer unknown, never ejected (got $(mc_queue_state "$QURL"))"
mc_inqueue "$QURL" && bad "3: mc_inqueue must be false under a 403" || ok
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 ''
[ "$(mc_queue_state "$QURL")" = unknown ] && ok || bad "3: an empty 2xx body must answer unknown"
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/x main 'queued')"
[ "$(mc_queue_state "$QURL")" = merged ] && ok || bad "3: MERGED wins over every label (got $(mc_queue_state "$QURL"))"
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/x main 'queued')"
[ "$(mc_queue_state "$QURL")" = queued ] && ok || bad "3: an open PR carrying the queue label is queued (got $(mc_queue_state "$QURL"))"
mc_inqueue "$QURL" && ok || bad "3: mc_inqueue must be true for a queued PR"
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr closed - "$H1" ticket/x main '')"
[ "$(mc_queue_state "$QURL")" = unknown ] && ok || bad "3: a CLOSED PR is the conductor's own branch — unknown"
# The read never speaks GraphQL again.
case "$(argv)" in *'pr view'*) bad "3: mc_queue_state still called gh pr view" ;; *) ok ;; esac

# --- 3b. the Mergify witness: a check-runs read that did not answer ----------
# The check-runs read is the SECOND read in this decision and it was the one
# left off the contract: `gh api … || out=""` gave back the empty string, which
# reads as "Mergify has no check on this head" — and with the label already
# gone that is the sentence mc_queue_state turns into `ejected`, i.e. a strike,
# a label strip and a dequeue off a 403. The provider cache is the fixture; the
# capability probe is not what is under test (the same hook other suites use).
mkdir -p "$T/h/tmp"; echo mergify > "$T/h/tmp/merge-queue-example-org_demo-os.provider"
ghfx_routes_reset; ghfx_log_reset
ghfx_route GET "repos/example-org/demo-os/commits/$H1/check-runs*" 403 '{"message":"nope"}'
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/x main '')"
[ "$(mc_queue_state "$QURL")" = unknown ] && ok \
  || bad "3b: a 403 on check-runs must answer unknown — calling it an ejection dequeues a PR the queue still holds (got $(mc_queue_state "$QURL"))"
case "$(argv)" in *check-runs*) ok ;; *) bad "3b: the mergify arm must actually ask for the check runs, or this case proves nothing" ;; esac
# …and the same fixture with the read ANSWERING still ejects: this is a fix to
# what an unread answer means, not to what a real empty check list means.
ghfx_routes_reset
ghfx_route GET "repos/example-org/demo-os/commits/$H1/check-runs*" 200 '{"check_runs":[]}'
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/x main '')"
[ "$(mc_queue_state "$QURL")" = ejected ] && ok \
  || bad "3b: an ANSWERED check-runs read with no queue check is still an ejection under mergify (got $(mc_queue_state "$QURL"))"
# A live queue check under a 403… cannot happen; a live LABEL under one can, and
# it keeps the row where it is.
ghfx_routes_reset
ghfx_route GET "repos/example-org/demo-os/commits/$H1/check-runs*" 403 '{"message":"nope"}'
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/x main 'queued')"
[ "$(mc_queue_state "$QURL")" = queued ] && ok \
  || bad "3b: a queue label read from a 200 is still a fact when the check-runs read 403s (got $(mc_queue_state "$QURL"))"
# --- 3c. a native-queue repo never runs the Mergify witness at all -----------
# isInMergeQueue is GraphQL-only, so there is nothing for this read to find on a
# `github` or `none` provider: asking spends a call to learn nothing and then
# invites the no-witness arm to call it an ejection (the operator's finding 2 on #941).
echo github > "$T/h/tmp/merge-queue-example-org_demo-os.provider"
ghfx_routes_reset; ghfx_log_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/x main '')"
[ "$(mc_queue_state "$QURL")" = unknown ] && ok \
  || bad "3c: an OPEN PR on the native queue is unknown, never ejected (got $(mc_queue_state "$QURL"))"
case "$(argv)" in *check-runs*) bad "3c: a github-provider PR must not spend a Mergify check-runs read: $(argv)" ;; *) ok ;; esac
rm -f "$T/h/tmp/merge-queue-example-org_demo-os.provider"

# ============================================================================
# 4. mc_pr_files, mc_merge, mc_settle_merged
# ============================================================================
FURL=https://github.com/example-org/demo-os/pull/41
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/41/files*' 200 '[{"filename":"src/b.ts"},{"filename":"src/a.ts"},{"filename":"src/a.ts"}]'
[ "$(mc_pr_files example-org/demo-os 41 "$FURL" "$H1" | paste -sd, -)" = "src/a.ts,src/b.ts" ] \
  && ok || bad "4: mc_pr_files must answer sorted unique filenames (got $(mc_pr_files example-org/demo-os 41 "$FURL" "$H1" | paste -sd, -))"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/42/files*' 403 '{"message":"nope"}'
mc_pr_files example-org/demo-os 42 https://github.com/example-org/demo-os/pull/42 "$H1" >/dev/null 2>&1 \
  && bad "4: a files read that 403s must be rc 1 (cannot judge), never an empty file list" || ok
[ -z "$(ls -A "$MC_FILES_DIR" 2>/dev/null | grep _42_ || true)" ] && ok || bad "4: a failed files read must not be cached"

# mc_merge: the merge verb is untouched; the POST-merge READ decides
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; exit 0 ;;
esac
SH
: > "$T/merge-calls.txt"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/x main '' true clean operator "$MSHA")"
MC_MERGE_SETTLE=0 mc_merge "$FURL" "$H1" >/dev/null && ok || bad "4: a post-merge read of MERGED must be rc 0"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 403 '{"message":"nope"}'
MC_MERGE_SETTLE=0 mc_merge "$FURL" "$H1" >/dev/null && bad "4: an UNVERIFIABLE post-merge read must never be read as merged" || ok
[ "$(wc -l < "$T/merge-calls.txt")" = 2 ] && ok || bad "4: mc_merge must still call the gated merge verb ($(cat "$T/merge-calls.txt"))"

# mc_enqueue_github: the verb was ACCEPTED and the verifying read was refused.
# rc 1 here is a strike against the PR, and two strikes park it BLOCKED_AGENT —
# so reading a rate limit as "the enqueue failed" costs a PR its build for an
# enqueue GitHub took. 404 is a real contradiction and keeps the failure path.
: > "$T/merge-calls.txt"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 "$(ghfx_pr open - "$H1" ticket/x main '')"
MC_ENQUEUE_SETTLE=0 mc_enqueue_github "$FURL" "$H1" >/dev/null \
  && ok || bad "4: verb rc 0 + a 2xx OPEN read IS the enqueue (expected rc 0)"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 403 '{"message":"nope"}'
MC_ENQUEUE_SETTLE=0 mc_enqueue_github "$FURL" "$H1" >/dev/null \
  && ok || bad "4: an UNVERIFIABLE post-enqueue read must not be reported as a failed enqueue — that is a strike for a rate limit"
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 404 '{"message":"no"}'
MC_ENQUEUE_SETTLE=0 mc_enqueue_github "$FURL" "$H1" >/dev/null \
  && bad "4: a 404 after an accepted merge verb is a contradiction, not an enqueue" || ok
ghfx_routes_reset
ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/x main '' true clean operator "$MSHA")"
MC_ENQUEUE_SETTLE=0 mc_enqueue_github "$FURL" "$H1" >/dev/null; ERC=$?
[ "$ERC" = 2 ] && ok || bad "4: a PR the verb merged outright must answer rc 2, not an enqueue (got $ERC)"
# and the verb's own refusal is still a failure, read or no read
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; exit 1 ;;
esac
SH
ghfx_routes_reset; ghfx_route GET 'repos/example-org/demo-os/pulls/41' 403 '{"message":"nope"}'
MC_ENQUEUE_SETTLE=0 mc_enqueue_github "$FURL" "$H1" >/dev/null \
  && bad "4: a merge verb that FAILED is never an enqueue, whatever the verifying read says" || ok

# mc_settle_merged: comment then close; a close that 403s takes the existing
# "could not be closed" branch and NEVER claims the issue was closed.
SURL=https://github.com/example-org/issuer/pull/7
mkdir -p "$T/h/builds/issuer-IS-7-202609180001"
ghfx_routes_reset; ghfx_log_reset
ghfx_route GET   'repos/example-org/issuer/pulls/7' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-7 main '' true clean operator "$MSHA")"
ghfx_route POST  'repos/example-org/issuer/issues/7/comments' 200 '{"id":1}'
ghfx_route PATCH 'repos/example-org/issuer/issues/7' 403 '{"message":"nope"}'
mc_settle_merged example-org/issuer#7 "$SURL" issuer example-org/issuer ticket/is-7 \
  "$T/h/builds/issuer-IS-7-202609180001" - "$H1" >/dev/null 2>&1
grep -q 'could not be closed' "$T/h/logs/merge-conductor.log" && ok || bad "4: a close that 403s must take the could-not-be-closed branch"
grep -q 'closed issue #7' "$T/h/logs/merge-conductor.log" && bad "4: a failed close must never log 'closed issue'" || ok
[ "$(grep -c 'issues/7/comments' "$T/gh-argv.log")" = 1 ] && ok || bad "4: exactly one comment POST ($(grep -c 'issues/7/comments' "$T/gh-argv.log"))"
case "$(argv)" in *'issue close'*) bad "4: mc_settle_merged still shells out to gh issue close" ;; *) ok ;; esac
# …and the RETRY does not say it twice. gh_rest_close answers 75 for a PATCH
# that landed with an unreadable confirmation too, so the second settle may be
# talking to an issue that is already closed and already commented.
ghfx_routes_reset
ghfx_route GET   'repos/example-org/issuer/pulls/7' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-7 main '' true clean operator "$MSHA")"
ghfx_route POST  'repos/example-org/issuer/issues/7/comments' 200 '{"id":1}'
ghfx_route PATCH 'repos/example-org/issuer/issues/7' 200 '{"state":"closed"}'
ghfx_route GET   'repos/example-org/issuer/issues/7' 200 '{"state":"closed"}'
mc_settle_merged example-org/issuer#7 "$SURL" issuer example-org/issuer ticket/is-7 \
  "$T/h/builds/issuer-IS-7-202609180001" - "$H1" >/dev/null 2>&1
grep -q 'closed issue #7' "$T/h/logs/merge-conductor.log" && ok || bad "4: the retry must close the issue once the PATCH lands"
[ "$(grep -c 'issues/7/comments' "$T/gh-argv.log")" = 1 ] && ok \
  || bad "4: still exactly ONE comment POST across both settles ($(grep -c 'issues/7/comments' "$T/gh-argv.log"))"
}

# ============================================================================
# 5. bin/merge-conductor.sh, driven: a 403 on /pulls/{n} leaves the row alone
# ============================================================================
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/"
mkdir -p "$T/h/builds/demo-os-TK-31-202609180001"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/31" > "$T/h/builds/demo-os-TK-31-202609180001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-31-202609180001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-31-202609180001/reviewed-sha"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

ghfx_extra <<SH
case "\$A" in
  *"pr merge"*) printf '%s\n' "\$A" >> "\$GHFX/merge-calls.txt"; exit 0 ;;
  *"pr list -R example-org/demo-os --state open"*)
    echo '[{"number":31,"url":"https://github.com/example-org/demo-os/pull/31","headRefOid":"$H1","headRefName":"ticket/TK-31","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","baseRefName":"main"}]'; exit 0 ;;
  *"pr list"*) echo "[]"; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
tick() { ( cd "$T" && HARNESS="$T/h" HARNESS_SECRET=x MC_MERGE_SETTLE=0 MC_DETACHED_REBASE=0 \
           bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || true; }
row_state() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }

# 5a. the UNVERIFIABLE tick
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$T/h/logs/merge-conductor.log"
ghfx_route GET  'repos/example-org/demo-os/pulls/31' 403 '{"message":"API rate limit exceeded"}'
ghfx_route DIFF 'repos/example-org/demo-os/pulls/31' 403 '{"message":"API rate limit exceeded"}'
tick
cp "$T/h/state/merge-conductor/pr-state.tsv" "$T/rows.a"
tick
[ "$(row_state 'example-org/demo-os#31')" = READY ] && ok || bad "5a: the row must stay READY under a 403 (got '$(row_state 'example-org/demo-os#31')')"
cmp -s "$T/rows.a" "$T/h/state/merge-conductor/pr-state.tsv" && ok || bad "5a: a second UNVERIFIABLE tick must leave the row file byte-identical"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "5a: a 403 tick must never reach the merge verb ($(cat "$T/merge-calls.txt"))"
grep -q 'UNVERIFIABLE' "$T/h/logs/merge-conductor.log" && ok || bad "5a: the tick must SAY the read was unverifiable"
grep -qE '(DELETE|PATCH|PUT|POST).*labels' "$T/gh-argv.log" \
  && bad "5a: a 403 tick wrote labels: $(grep -E '(DELETE|PATCH|PUT|POST).*labels' "$T/gh-argv.log")" || ok
case "$(argv)" in *'pr view'*|*'pr diff'*) bad "5a: the conductor still speaks GraphQL: $(argv)" ;; *) ok ;; esac

# 5a2. …and a 404 is a DIFFERENT sentence from a 403. Both leave the row alone,
# but an operator reading "UNVERIFIABLE" for a PR that GitHub says does not
# exist goes looking for a rate limit that was never there.
ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$T/h/logs/merge-conductor.log"
ghfx_route GET  'repos/example-org/demo-os/pulls/31' 404 '{"message":"Not Found"}'
ghfx_route DIFF 'repos/example-org/demo-os/pulls/31' 404 '{"message":"Not Found"}'
cp "$T/h/state/merge-conductor/pr-state.tsv" "$T/rows.a2"
tick
cmp -s "$T/rows.a2" "$T/h/state/merge-conductor/pr-state.tsv" && ok \
  || bad "5a2: a 404 tick rewrote the row file"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "5a2: a 404 tick reached the merge verb"

# 5d. the JSON read answers, the DIFF read does not: the iron-law scan is the
# thing that did not run, so the row must not merge on the zero hits an empty
# diff file always has. This is the one 403 that 5a cannot cover — both reads
# fail there, and the pre-merge re-read would hold the row anyway.
ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$T/h/logs/merge-conductor.log"
ghfx_route GET  'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/TK-31 main '' true clean operator '')"
ghfx_route DIFF 'repos/example-org/demo-os/pulls/31' 403 '{"message":"API rate limit exceeded"}'
cp "$T/h/state/merge-conductor/pr-state.tsv" "$T/rows.d"
tick
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "5d: a PR whose DIFF could not be read reached the merge verb — the iron-law scan never ran ($(cat "$T/merge-calls.txt"))"
grep -q 'iron-law scan NOT run' "$T/h/logs/merge-conductor.log" && ok \
  || bad "5d: the tick must say the scan did not run (log: $(cat "$T/h/logs/merge-conductor.log"))"
cmp -s "$T/rows.d" "$T/h/state/merge-conductor/pr-state.tsv" && ok \
  || bad "5d: an unread diff rewrote the row file"

# 5b. the happy path still moves — otherwise 5a proves only that nothing works
ghfx_routes_reset; : > "$T/merge-calls.txt"
ghfx_route GET  'repos/example-org/demo-os/pulls/31' 200 "$(ghfx_pr open - "$H1" ticket/TK-31 main '' true clean operator '')"
ghfx_route DIFF 'repos/example-org/demo-os/pulls/31' 200 '+++ b/src/x.ts
+const a = 1;'
tick
[ -s "$T/merge-calls.txt" ] && ok || bad "5b: a 200 OPEN read at the reviewed head must still merge"
grep -q -- "--match-head-commit $H1" "$T/merge-calls.txt" && ok || bad "5b: the merge verb must keep --match-head-commit (got $(cat "$T/merge-calls.txt"))"

# 5c. ticket_open under a limited read: rc 1 (skip the close-out) and a loud line
TO_LOG="$T/h/logs/merge-conductor.log"
ticket_open_probe() { # <status> [body]
  ghfx_routes_reset; ghfx_route GET 'repos/example-org/issuer/issues/7' "$1" "${2:-}"
  ( set +u
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    H="$T/h"; eval "$(sed -n '/^ticket_open() {/,/^}/p' "$T/h/bin/lib/mc/classify.sh")"
    ticket_open issuer example-org/issuer "$T/h/builds/issuer-IS-7-202609180001" ticket/is-7 )
}
[ "$MUT" = 1 ] || {
: > "$TO_LOG"
ticket_open_probe 200 '{"state":"open"}'   && ok || bad "5c: an OPEN issue must be rc 0"
ticket_open_probe 200 '{"state":"closed"}' && bad "5c: a CLOSED issue must be rc 1" || ok
: > "$TO_LOG"
ticket_open_probe 404 '{"message":"Not Found"}' && bad "5c: a 404 issue must be rc 1" || ok
grep -q 'ticket_open UNKNOWN' "$TO_LOG" && bad "5c: a 404 is ABSENT, not UNKNOWN — it must not log UNKNOWN" || ok
# …and it is not silent either. A close-out skipped without a word every tick
# looks exactly like one that was never owed (the same reason the 403 talks).
grep -q 'ticket_open ABSENT (HTTP 404)' "$TO_LOG" && ok \
  || bad "5c: a 404 must say ABSENT rather than skip the close-out in silence (log: $(cat "$TO_LOG"))"
: > "$TO_LOG"
ticket_open_probe 403 '{"message":"nope"}' && bad "5c: a 403 issue read must be rc 1 (skip the close-out)" || ok
grep -q 'ticket_open UNKNOWN' "$TO_LOG" && ok || bad "5c: a 403 must log ticket_open UNKNOWN (log: $(cat "$TO_LOG"))"
}

# ============================================================================
# 6. bin/merge-queue.sh, driven: a limited read NEVER dequeues
# ============================================================================
cp "$DIR/bin/merge-queue.sh" "$T/h/bin/"
mkdir -p "$T/h/state/merge-queue/demo-os"
QLOG="$T/h/logs/merge-queue.log"
queue_tick() { ( cd "$T" && HARNESS="$T/h" bash "$T/h/bin/merge-queue.sh" demo-os >/dev/null 2>&1 ) || true; }

ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$QLOG"
touch "$T/h/state/merge-queue/demo-os/41"
ghfx_route GET 'repos/example-org/demo-os/pulls/41' 403 '{"message":"API rate limit exceeded"}'
queue_tick
[ -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6: a 403 read DEQUEUED the row — the #768 shape, in the queue"
grep -q 'left queued this tick' "$QLOG" && ok || bad "6: the queue must say the row was left queued (log: $(cat "$QLOG"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "6: a 403 read must never reach the merge verb"
grep -q 'state=)' "$QLOG" && bad "6: the dequeue line rendered with an EMPTY state" || ok

# …and a real 2xx that says CLOSED still dequeues, or the guard is just a stall
ghfx_routes_reset; : > "$QLOG"
ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 "$(ghfx_pr closed - "$H1" ticket/TK-41 main '')"
queue_tick
[ ! -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6: a 200 CLOSED read must still dequeue the row"
grep -q 'state=CLOSED' "$QLOG" && ok || bad "6: the dequeue must name the state it read (log: $(cat "$QLOG"))"

# --- 6c. 404 IS NOT 403, AND NEITHER IS A DEQUEUE ----------------------------
# the operator's finding 1 on #941, which collapsed 44 into 75 and so answered a PR that
# GitHub says does not exist with the same silent "left queued" for ever. A 404
# on a row this queue holds means the PR was deleted, the repo went invisible to
# this box's token, or the row carries a number that never existed — none of
# which is knowable from one tick, and all of which need a human eventually. So
# the row still stays, the consecutive count goes in a side file, and at
# MQ_ABSENT_ALERT_AFTER exactly ONE ALERTS line names it. Never two, never none.
ALOG="$T/h/logs/ALERTS.log"
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$QLOG"; : > "$ALOG"
rm -f "$T/h/state/merge-queue/demo-os/41.absent"
touch "$T/h/state/merge-queue/demo-os/41"
ghfx_route GET 'repos/example-org/demo-os/pulls/41' 404 '{"message":"Not Found"}'
queue_tick; queue_tick
[ -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6c: a 404 read DEQUEUED the row"
[ "$(cat "$T/h/state/merge-queue/demo-os/41.absent" 2>/dev/null)" = 2 ] && ok \
  || bad "6c: two consecutive 404s must count 2 (got '$(cat "$T/h/state/merge-queue/demo-os/41.absent" 2>/dev/null)')"
[ ! -s "$ALOG" ] && ok || bad "6c: two 404s must not alert yet (ALERTS: $(cat "$ALOG"))"
grep -q 'ABSENT (HTTP 404)' "$QLOG" && ok || bad "6c: a 404 must be logged as ABSENT, not as UNVERIFIABLE (log: $(cat "$QLOG"))"
queue_tick; queue_tick   # the 3rd trips the alert; the 4th must NOT repeat it
[ -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6c: the alert must not dequeue the row"
[ "$(grep -c '#41' "$ALOG")" = 1 ] && ok \
  || bad "6c: exactly ONE ALERTS line for a row that keeps 404ing (got $(grep -c '#41' "$ALOG"): $(cat "$ALOG"))"
grep -q 'demo-os' "$ALOG" && ok || bad "6c: the ALERTS line must name the project (ALERTS: $(cat "$ALOG"))"
# …and an answer clears the counter. Without this the side file is a leak that
# alerts again the moment a later outage pushes it back past the threshold.
ghfx_routes_reset; : > "$QLOG"
ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 "$(ghfx_pr closed - "$H1" ticket/TK-41 main '')"
queue_tick
[ ! -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6c: a 200 CLOSED must still dequeue after a 404 run"
[ ! -f "$T/h/state/merge-queue/demo-os/41.absent" ] && ok \
  || bad "6c: the absent counter must go with the row it counted for"
# the counter file must never be walked as a queue row of its own
ghfx_routes_reset; : > "$QLOG"; : > "$ALOG"
touch "$T/h/state/merge-queue/demo-os/42"; echo 9 > "$T/h/state/merge-queue/demo-os/42.absent"
ghfx_route GET 'repos/example-org/demo-os/pulls/42' 200 "$(ghfx_pr closed - "$H1" ticket/TK-42 main '')"
queue_tick
grep -q '42.absent' "$QLOG" && bad "6c: the counter side file was walked as a queue row" || ok
rm -f "$T/h/state/merge-queue/demo-os/42" "$T/h/state/merge-queue/demo-os/42.absent"

# --- 6b. …AND THE HEAD-BOUND GATE'S OWN READ, which is the one that MERGES ----
# The state read above is not the queue's only decision read: hb_blocked reads
# the head to compare it against the sha the review approved, and NEITHER merge
# verb in this queue carries --match-head-commit — so that one comparison is the
# whole thing standing in front of code no reviewer saw. A refused head read used
# to leave $head empty, which the gate read as "no drift" and landed.
#
# The claim comes off the REAL bin/jobs-client.sh: HARNESS_SECRET arms it and the
# curl stub answers /api/verdict, so hb_sha reads a reviewed sha the way the
# shipped queue does rather than through a stub of the gate's own input.
# $T/head403 makes every /pulls/41 read AFTER the first answer 403 — the only way
# to say "the row read OPEN and THEN the head could not be read" when both reads
# are the same REST path. git and sleep are stubbed so the landing path below
# neither touches the network nor waits on GitHub to settle.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/git";   chmod +x "$T/fakebin/git"
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; exit 0 ;;
esac
if [ -e "$GHFX/head403" ]; then
  case "$A" in
    *"GET repos/example-org/demo-os/pulls/41"*)
      if [ -e "$GHFX/pulls41-seen" ]; then
        printf 'HTTP/1.1 403 Forbidden\r\nServer: x\r\n\r\n{"message":"API rate limit exceeded"}'; exit 0
      fi
      : > "$GHFX/pulls41-seen" ;;
  esac
fi
SH
queue_tick_hb() { ( cd "$T" && HARNESS="$T/h" HARNESS_SECRET=fx-secret \
                    JOBS_URL=http://jobs.invalid \
                    bash "$T/h/bin/merge-queue.sh" demo-os >/dev/null 2>&1 ) || true; }
hb_case() { # hb_case <reviewed-sha> <head-read-403 0|1>
  ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$QLOG"
  rm -f "$T/pulls41-seen" "$T/head403" "$T/h/state/merge-queue/demo-os/41.blocked"
  [ "$2" = 1 ] && : > "$T/head403"
  echo "$1" > "$T/verdict-sha"
  touch "$T/h/state/merge-queue/demo-os/41"
  ghfx_route GET 'repos/example-org/demo-os/pulls/41' 200 \
    "$(ghfx_pr open - "$H1" ticket/TK-41 main '' true clean operator '')"
  queue_tick_hb
}

# the gate is WIRED: a READABLE head that is not the reviewed sha still blocks.
# Without this the two cases after it would pass on a gate that never ran.
hb_case "$H2" 0
[ -f "$T/h/state/merge-queue/demo-os/41.blocked" ] && ok \
  || bad "6b: the ledger claim never reached hb_blocked — the head-read cases prove nothing (log: $(cat "$QLOG"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "6b: a drifted head reached the merge verb"

# the head read is REFUSED: left queued, not parked, and above all not merged
hb_case "$H2" 1
[ -f "$T/h/state/merge-queue/demo-os/41" ] && ok || bad "6b: an unreadable HEAD dequeued the row"
[ ! -f "$T/h/state/merge-queue/demo-os/41.blocked" ] && ok \
  || bad "6b: an unreadable head parked the entry .blocked — a rate limit is not code a reviewer missed, and a park needs a hand to undo"
grep -q 'head read UNVERIFIABLE' "$QLOG" && ok \
  || bad "6b: the head-bound gate said nothing about the read it could not make (log: $(cat "$QLOG"))"
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "6b: the queue MERGED a PR whose head it could not read — the head-bound approval was never compared"

# positive control: a head that MATCHES the claim lands, so the negatives above
# are about the gate and not about a fixture that can never reach a merge.
hb_case "$H1" 0
[ -s "$T/merge-calls.txt" ] && ok \
  || bad "6b: a PR on its reviewed head never reached the merge verb — the negatives above prove nothing (log: $(cat "$QLOG"))"
rm -f "$T/fakebin/sleep" "$T/fakebin/git" "$T/head403" "$T/pulls41-seen" \
      "$T/verdict-sha" "$T/h/state/merge-queue/demo-os/41"

# ============================================================================
# 7. bin/merge-sweep.sh, driven: comment -> close -> marker, marker LAST
# ============================================================================
[ "$MUT" = 1 ] || {
cp "$DIR/bin/merge-sweep.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/h/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
SLOG="$T/h/logs/merge-sweep.log"
SREC="$T/h/builds/pool-issuer-IS-9-202609180003"
mkdir -p "$SREC"
echo "PR_CREATED https://github.com/example-org/issuer/pull/9" > "$SREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SREC/review.md"
echo "$H1" > "$SREC/reviewed-sha"
SPR=https://github.com/example-org/issuer/pull/9
sweep_tick() { ( cd "$T" && HARNESS="$T/h" SWEEP_MERGE_SETTLE=0 \
                 bash "$T/h/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; exit 0 ;;
  "api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH

# pass 1 — the comment lands, the close 403s: no done-marker, and it says so
# The merge verb flips $T/merged9 on, which is what makes the PR read MERGED
# afterwards — gh's exit code is never the landing (#272).
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; touch "$GHFX/merged9"; exit 0 ;;
  "api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
: > "$T/h/state/merge-sweep-done.txt"; rm -f "$T/merged9"
ghfx_route GET   'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-9 main '' true clean 'app/cromford' "$MSHA")" "$T/merged9"
ghfx_route GET   'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr open - "$H1" ticket/is-9 main '' true clean 'app/cromford' '')"
ghfx_route DIFF  'repos/example-org/issuer/pulls/9' 200 '+++ b/src/x.ts
+const a = 1;'
ghfx_route POST  'repos/example-org/issuer/issues/9/comments' 200 '{"id":1}'
ghfx_route PATCH 'repos/example-org/issuer/issues/9' 403 '{"message":"nope"}'
sweep_tick
grep -qxF "$SPR" "$T/h/state/merge-sweep-done.txt" \
  && bad "7: the done-marker was written for a PR whose issue close FAILED" || ok
grep -q 'close deferred to next sweep' "$SLOG" && ok || bad "7: a deferred close must say so (log: $(cat "$SLOG"))"
[ -f "$SREC/issue-commented" ] && ok || bad "7: the comment-once marker must exist after a successful comment"
C1=$(grep -c 'issues/9/comments' "$T/gh-argv.log")

# pass 2 — the close succeeds: the marker lands, and the comment is NOT repeated
ghfx_routes_reset; : > "$T/merge-calls.txt"
ghfx_route GET   'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-9 main '' true clean 'app/cromford' "$MSHA")"
ghfx_route POST  'repos/example-org/issuer/issues/9/comments' 200 '{"id":1}'
ghfx_route PATCH 'repos/example-org/issuer/issues/9' 200 '{"state":"closed"}'
ghfx_route GET   'repos/example-org/issuer/issues/9' 200 '{"state":"closed"}'
sweep_tick
grep -qxF "$SPR" "$T/h/state/merge-sweep-done.txt" && ok || bad "7: pass 2 must write the done-marker once the close is verified"
grep -q 'closed issue #9' "$SLOG" && ok || bad "7: a verified close must be logged"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7: the retry pass must close the issue, never merge the PR again"
C2=$(grep -c 'issues/9/comments' "$T/gh-argv.log")
[ "$C1" = 1 ] && [ "$C2" = 1 ] && ok || bad "7: exactly ONE comment POST across both passes (pass1=$C1 total=$C2)"
# order: comment, then close, then the marker
AO=$(grep -n 'issues/9' "$T/gh-argv.log" | grep -nE 'comments|PATCH' | head -2 | tr '\n' ' ')
case "$AO" in *comments*PATCH*) ok ;; *) bad "7: the comment must precede the close (got $AO)" ;; esac

# pass 0 shape — /pulls/{n} 403: nothing recorded, nothing merged
ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$SLOG"; rm -f "$T/merged9"
: > "$T/h/state/merge-sweep-done.txt"; rm -f "$SREC/issue-commented" "$SREC/issue-close-owed"
ghfx_route GET 'repos/example-org/issuer/pulls/9' 403 '{"message":"nope"}'
sweep_tick
[ ! -s "$T/h/state/merge-sweep-done.txt" ] && ok || bad "7: a 403 PR read must record NOTHING (got $(cat "$T/h/state/merge-sweep-done.txt"))"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7: a 403 PR read must never merge"
grep -q 'UNVERIFIABLE' "$SLOG" && ok || bad "7: the sweep must say the read was unverifiable (log: $(cat "$SLOG"))"

# …and a 404 is the other sentence: the PR is not there. Same non-action, and
# the log has to be able to tell an operator which of the two happened.
ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
: > "$T/h/state/merge-sweep-done.txt"
ghfx_route GET 'repos/example-org/issuer/pulls/9' 404 '{"message":"Not Found"}'
sweep_tick
[ ! -s "$T/h/state/merge-sweep-done.txt" ] && ok || bad "7: a 404 PR read must record NOTHING"
grep -q 'ABSENT (HTTP 404)' "$SLOG" && ok \
  || bad "7: a 404 must be named ABSENT, not folded into UNVERIFIABLE (log: $(cat "$SLOG"))"

# the iron-law scan never runs on a diff it could not read
ghfx_routes_reset; : > "$SLOG"; : > "$T/merge-calls.txt"
ghfx_route GET  'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr open - "$H1" ticket/is-9 main '' true clean 'app/cromford' '')"
ghfx_route DIFF 'repos/example-org/issuer/pulls/9' 403 '{"message":"nope"}'
sweep_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7: a diff the sweep could not read must never be scanned as clean and merged"

# --- 7b. on a NATIVE-queue repo the enqueue witness is the verb SUCCEEDING ----
# isInMergeQueue is GraphQL-only, so mc_pr_queued answers `unknown` here and the
# sweep falls back to "the verb ran and the PR is still OPEN". THE VERB HAVING
# SUCCEEDED IS PART OF THAT: a merge GitHub refused (not mergeable, protection,
# auth) logged as "enqueued … the merge conductor settles it" records nothing,
# pages nobody, and re-runs the same failing merge every ten minutes forever.
# The provider cache is the fixture — the repo capability probe is not what is
# under test here (tests/merge-conductor-test.sh uses the same hook).
mkdir -p "$T/h/tmp"; echo github > "$T/h/tmp/merge-queue-example-org_issuer.provider"
sweep_native() { # sweep_native <merge-verb-rc>
  ghfx_extra <<SH
case "\$A" in
  *"pr merge"*) printf '%s\n' "\$A" >> "\$GHFX/merge-calls.txt"; exit $1 ;;
  "api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
  ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$SLOG"; rm -f "$T/merged9"
  : > "$T/h/state/merge-sweep-done.txt"; rm -f "$SREC/issue-commented" "$SREC/issue-close-owed"
  ghfx_route GET  'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr open - "$H1" ticket/is-9 main '' true clean 'app/cromford' '')"
  ghfx_route DIFF 'repos/example-org/issuer/pulls/9' 200 '+++ b/src/x.ts
+const a = 1;'
  sweep_tick
}

# verb rc 0, PR still OPEN: that IS the enqueue, and nothing is recorded
sweep_native 0
[ -s "$T/merge-calls.txt" ] && ok || bad "7b: the sweep never reached the merge verb on a native-queue repo"
grep -q 'enqueued in' "$SLOG" && ok || bad "7b: an accepted verb leaving the PR OPEN must read as an enqueue (log: $(cat "$SLOG"))"
[ ! -s "$T/h/state/merge-sweep-done.txt" ] && ok || bad "7b: an enqueue must record NOTHING — the conductor owns the settle"

# verb rc 1: NOT an enqueue. It takes the failure branch, which is the thing
# that actually gets looked at.
sweep_native 1
grep -q 'enqueued in' "$SLOG" && bad "7b: a merge verb that FAILED was logged as an enqueue — nothing recorded, nobody paged, and the same failing merge re-runs every ten minutes (log: $(cat "$SLOG"))" || ok
grep -q 'merge FAILED despite CLEAN' "$SLOG" && ok || bad "7b: a refused merge must take the failure branch (log: $(cat "$SLOG"))"
[ ! -s "$T/h/state/merge-sweep-done.txt" ] && ok || bad "7b: a refused merge must not be recorded as merged"
rm -f "$T/h/tmp/merge-queue-example-org_issuer.provider"

# --- 7c. the verb returned 0 and the verifying read did not answer -----------
# The PR is almost certainly merged: the merge verb GitHub ran returned 0. The
# old shape wrote "merge FAILED despite CLEAN" into the ledger off a read that
# said nothing — the ticket's own defect class, at the sweep's loudest line —
# and the next pass, finding the PR MERGED, stamped the record done without the
# issue close. So: nothing recorded either way, the record marked as owing its
# close, and the next pass pays it. The deploy request is NOT re-run on that
# pass and the log line says so; deploy-train's self-source floor covers it.
# $T/merged9 makes every /pulls/9 read AFTER the merge verb answer 403.
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; touch "$GHFX/merged9"; exit 0 ;;
  "api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$SLOG"; rm -f "$T/merged9"
: > "$T/h/state/merge-sweep-done.txt"
rm -f "$SREC/issue-commented" "$SREC/issue-close-owed"
ghfx_route GET  'repos/example-org/issuer/pulls/9' 403 '{"message":"API rate limit exceeded"}' "$T/merged9"
ghfx_route GET  'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr open - "$H1" ticket/is-9 main '' true clean 'app/cromford' '')"
ghfx_route DIFF 'repos/example-org/issuer/pulls/9' 200 '+++ b/src/x.ts
+const a = 1;'
sweep_tick
[ -s "$T/merge-calls.txt" ] && ok || bad "7c: the sweep never reached the merge verb — the case below proves nothing"
grep -q 'merge FAILED despite CLEAN' "$SLOG" \
  && bad "7c: a merge verb that SUCCEEDED was written down as FAILED because the verifying read 403'd (log: $(cat "$SLOG"))" || ok
[ ! -s "$T/h/state/merge-sweep-done.txt" ] && ok || bad "7c: an unverified merge must record nothing"
[ -f "$SREC/issue-close-owed" ] && ok || bad "7c: the record must be marked as owing its issue close"
grep -q 'UNVERIFIABLE' "$SLOG" && ok || bad "7c: the sweep must say the verifying read could not answer (log: $(cat "$SLOG"))"
grep -q 'deploy-train' "$SLOG" && ok \
  || bad "7c: the log must name the deploy request this path does NOT issue (log: $(cat "$SLOG"))"

# --- 7d. …and the NEXT pass finishes it, close-out and all -------------------
# Without the owed marker this pass takes the plain "already MERGED" branch and
# writes the done-marker with no issue close, which is the half of the defect
# that costs the work rather than the honesty.
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
ghfx_route GET   'repos/example-org/issuer/pulls/9' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-9 main '' true clean 'app/cromford' "$MSHA")"
ghfx_route POST  'repos/example-org/issuer/issues/9/comments' 200 '{"id":1}'
ghfx_route PATCH 'repos/example-org/issuer/issues/9' 200 '{"state":"closed"}'
ghfx_route GET   'repos/example-org/issuer/issues/9' 200 '{"state":"closed"}'
sweep_tick
grep -qxF "$SPR" "$T/h/state/merge-sweep-done.txt" && ok || bad "7d: the retry pass must record the merge once it reads MERGED"
grep -q 'closed issue #9' "$SLOG" && ok \
  || bad "7d: the owed work includes the issue close-out (log: $(cat "$SLOG"))"
[ "$(grep -c 'issues/9/comments' "$T/gh-argv.log")" = 1 ] && ok \
  || bad "7d: the retry must post exactly one close-out comment (got $(grep -c 'issues/9/comments' "$T/gh-argv.log"))"
[ ! -f "$SREC/issue-close-owed" ] && ok || bad "7d: the owed marker must be cleared once the close is verified"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7d: a PR that already merged must never be merged again"
rm -f "$T/merged9"

# --- 7e. an owed close whose ISSUE cannot be named is still owed --------------
# the operator's finding 3 on #941. If sweep_issue_for cannot resolve the project or the
# issue number, the `&&` chain used to fall straight through to sweep_record —
# retiring the debt by forgetting it, with the marker left in a record nothing
# would ever read again. The record below belongs to a repo that IS in
# fleet.conf but whose directory name carries no issue number, so the
# derivation fails on the second half and the branch has to refuse.
SREC2="$T/h/builds/relayed-issuer-record-no-number"; mkdir -p "$SREC2"
echo "PR_CREATED https://github.com/example-org/issuer/pull/11" > "$SREC2/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SREC2/review.md"
touch "$SREC2/issue-close-owed"
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
: > "$T/h/state/merge-sweep-done.txt"
ghfx_route GET 'repos/example-org/issuer/pulls/11' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-11 main '' true clean 'app/cromford' "$MSHA")"
ghfx_route GET 'repos/example-org/issuer/pulls/9'  200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/is-9  main '' true clean 'app/cromford' "$MSHA")"
sweep_tick
grep -qxF 'https://github.com/example-org/issuer/pull/11' "$T/h/state/merge-sweep-done.txt" \
  && bad "7e: an owed close whose issue could not be named was recorded done — the debt is now invisible" || ok
grep -q 'owed close cannot be retried' "$SLOG" && ok \
  || bad "7e: the sweep must name the record whose owed close it cannot retry (log: $(cat "$SLOG"))"
# …and it is said ONCE, where someone reads it. A line repeated into this
# sweep's own log every ten minutes is a question nobody is being asked.
grep -q 'neither the project nor the issue number can be derived' "$T/h/logs/ALERTS.log" && ok \
  || bad "7e: an owed close nothing can repay must page once (ALERTS: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null))"
A1=$(grep -c 'neither the project nor the issue number' "$T/h/logs/ALERTS.log")
sweep_tick
[ "$(grep -c 'neither the project nor the issue number' "$T/h/logs/ALERTS.log")" = "$A1" ] && ok \
  || bad "7e: the alert must be written once per record, not once per pass"
scratch_rm "$SREC2"

# --- 7f. a BOARD project owes no issue close, and must never wait for one ----
# Most of the fleet is board-driven (project-1, project-2, project-3, project-4): the
# ticket lives on the product board and is closed through the app's API, never
# from here. sweep_issue_for answers "nothing owed" for those, and that is the
# OPPOSITE of "owed and unnameable" even though both used to be rc 1. Marking
# one of them owed strands a merge that really happened: never recorded, no
# beat, no ledger row, no deploy request, and 7e's line every ten minutes
# sending someone after an issue that does not exist.
BREC="$T/h/builds/pool-demo-os-TK-77-202609180007"; mkdir -p "$BREC"
BPR=https://github.com/example-org/demo-os/pull/77
echo "PR_CREATED $BPR" > "$BREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$BREC/review.md"
echo "$H1" > "$BREC/reviewed-sha"
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; touch "$GHFX/merged77"; exit 0 ;;
  "api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  "api repos/example-org/demo-os -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
ghfx_routes_reset; ghfx_log_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
: > "$T/h/state/merge-sweep-done.txt"; rm -f "$T/merged77" "$BREC/issue-close-owed"
# the verb lands, every read after it 403s — 7c's shape, on a board project
ghfx_route GET  'repos/example-org/demo-os/pulls/77' 403 '{"message":"API rate limit exceeded"}' "$T/merged77"
ghfx_route GET  'repos/example-org/demo-os/pulls/77' 200 "$(ghfx_pr open - "$H1" ticket/TK-77 main '' true clean 'cromford[bot]' '')"
ghfx_route DIFF 'repos/example-org/demo-os/pulls/77' 200 '+++ b/src/x.ts
+const a = 1;'
sweep_tick
[ -s "$T/merge-calls.txt" ] && ok || bad "7f: the sweep never reached the merge verb — the case below proves nothing (log: $(cat "$SLOG"))"
[ ! -f "$BREC/issue-close-owed" ] && ok \
  || bad "7f: a board project owes no issue close, so the owed marker must never go on its record"
grep -qxF "$BPR" "$T/h/state/merge-sweep-done.txt" && bad "7f: an unverified merge must still record nothing" || ok
grep -q 'board-driven project, no issue close is owed' "$SLOG" && ok \
  || bad "7f: the log must say why nothing is owed (log: $(cat "$SLOG"))"
# the next pass reads MERGED and records it — no close to wait for, ever
ghfx_routes_reset; : > "$T/merge-calls.txt"; : > "$SLOG"
ghfx_route GET 'repos/example-org/demo-os/pulls/77' 200 "$(ghfx_pr closed 2026-09-18T00:00:00Z "$H1" ticket/TK-77 main '' true clean 'cromford[bot]' "$MSHA")"
sweep_tick
grep -qxF "$BPR" "$T/h/state/merge-sweep-done.txt" && ok \
  || bad "7f: the merge must be recorded on the pass that reads MERGED (log: $(cat "$SLOG"))"
case "$(argv)" in *'issues/77'*) bad "7f: a board project's merge must never touch a GitHub issue" ;; *) ok ;; esac
# and a marker left by an older pass is CLEARED, not waited on for ever
touch "$BREC/issue-close-owed"
: > "$T/h/state/merge-sweep-done.txt"; : > "$SLOG"
sweep_tick
grep -qxF "$BPR" "$T/h/state/merge-sweep-done.txt" && ok \
  || bad "7f: a stale owed marker on a board record must be cleared and the merge recorded (log: $(cat "$SLOG"))"
[ ! -f "$BREC/issue-close-owed" ] && ok || bad "7f: the stale marker must be removed, not left to re-strand the record"
scratch_rm "$BREC"

# BH-1366: section 8 drove bin/tier2-merge-sweep.sh and pinned that a 403 read
# enqueues nothing and says why. That lane is retired — the enqueue happens at
# the APPROVE verdict now, off a variable this process holds, so there is no
# PR-state read in front of it to refuse. The read-refusal rule it pinned still
# lives on the CONSUMER, in section 5 above and in bin/merge-queue.sh.

}

# ============================================================================
# 9. Mutation: break mc_pr_view's failure branch and sections 5/6 must go red
# ============================================================================
if [ "$MUT" != 1 ]; then
  MUTOUT=$(LIMITED_READ_MUTATE=1 HARNESS_TEST_SANDBOX="${HARNESS_TEST_SANDBOX:-}" \
           bash "$DIR/tests/conductor-limited-read.bh-784-test.sh" 2>&1); MRC=$?
  [ "$MRC" != 0 ] && ok || bad "9: MUTATION SURVIVED — mc_pr_view answering '' with rc 0 (the #768 shape) left this suite green"
  case "$MUTOUT" in *"FAIL: 5a"*|*"FAIL: 6"*) ok ;;
    *) bad "9: the mutation must be caught by the DRIVEN sections 5/6, not only by the unit ones (got: $(printf '%s' "$MUTOUT" | grep '^FAIL' | head -3 | tr '\n' ' '))" ;;
  esac
fi

# ============================================================================
# 10. The no-GraphQL guard, pinned HERE
# ============================================================================
# tests/gh-no-graphql-decision-guard-test.sh is BH-780's file and ships in ITS
# PR, not this one. The acceptance criterion "the six converted files carry the
# marker and hold no unallowed GraphQL call" is this PR's, though, so the
# scanner is copied verbatim from that guard and run over the six files here.
# Whichever of the two PRs lands first, the rule is enforced from that moment.
#
# This is the one section that reads SOURCE rather than behaviour (D3), because
# the criterion IS about the source — so the scanner is mutation-checked twice
# below: a bare call must be red, and a reason-less allow must not allow.
if [ "$MUT" != 1 ]; then
cat > "$T/scan10.sh" <<'SCAN'
#!/bin/bash
set -uo pipefail
root="${1:?usage: scan.sh <dir>}"
marked=0; hits=0
while IFS= read -r f; do
  grep -qx '# gh-rest: no-graphql' "$f" || continue
  marked=$((marked+1))
  n=0
  while IFS= read -r line; do
    n=$((n+1))
    # An allow line is decided on the ORIGINAL line, and only with a reason.
    case "$line" in *"# gh-guard-allow: "*)
      reason=${line#*"# gh-guard-allow: "}
      case "$reason" in *[![:space:]]*) continue ;; esac
      ;;
    esac
    code=$(printf '%s\n' "$line" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//')
    grep -Eq '(^|[[:space:];|&(]|\$\()[[:space:]]*gh[[:space:]]+(pr|issue|run)[[:space:]]' <<<"$code" \
      && { echo "$f:$n"; hits=$((hits+1)); }
  done < "$f"
done < <(find "$root" -type f -name '*.sh' | sort)
[ "$marked" -gt 0 ] || { echo "no file carries the '# gh-rest: no-graphql' marker"; exit 2; }
[ "$hits" = 0 ] || exit 1
echo "marked files: $marked, offending lines: 0"
exit 0
SCAN
chmod +x "$T/scan10.sh"

# BH-477.3 split bin/lib/merge-conductor-lib.sh into bin/lib/mc/: every call this
# section polices moved with its function, so the five modules that carry a gh
# call join the list and carry the marker. The shim stays and keeps its own —
# ten files since BH-1366 retired bin/tier2-merge-sweep.sh, never fewer.
SIX="bin/lib/gh-rest.sh bin/lib/merge-conductor-lib.sh bin/merge-conductor.sh
     bin/merge-queue.sh bin/merge-sweep.sh
     bin/lib/mc/log.sh bin/lib/mc/classify.sh bin/lib/mc/queue.sh
     bin/lib/mc/rebase.sh bin/lib/mc/settle.sh"
rm -rf "$T/six"; mkdir -p "$T/six/lib/mc"
for f in $SIX; do cp "$DIR/$f" "$T/six/${f#bin/}"; done
G10=$(bash "$T/scan10.sh" "$T/six" 2>&1); G10RC=$?
[ "$G10RC" = 0 ] && ok || bad "10: the six converted files must scan clean (rc=$G10RC): $G10"
# TEST-CHANGE (Lane E, 2026-09-24): the expected count is the length of $SIX
# rather than a literal it had to be re-pinned beside (6 -> 11 -> 10); the scan
# still has to mark EVERY listed file, and the per-file marker check follows.
NSIX=$(printf '%s\n' $SIX | grep -c .)
[ "$NSIX" -ge 10 ] && ok || bad "10: the list of converted files shrank to $NSIX — never fewer than ten"
[ "$G10" = "marked files: $NSIX, offending lines: 0" ] && ok \
  || bad "10: all $NSIX files must carry '# gh-rest: no-graphql' — got: $G10"
for f in $SIX; do
  grep -qx '# gh-rest: no-graphql' "$DIR/$f" && ok || bad "10: $f is missing the marker line"
done

# The scanner itself is not taken on trust: a bare call in a marked file is red,
# and an allow with no reason does not allow. Without these two the section
# above would pass just as happily on a regex that matches nothing.
rm -rf "$T/mut10"; mkdir -p "$T/mut10"
cp "$DIR/bin/lib/gh-rest.sh" "$T/mut10/x.sh"; echo 'gh pr view a/b/1' >> "$T/mut10/x.sh"
bash "$T/scan10.sh" "$T/mut10" >/dev/null 2>&1; [ $? = 1 ] && ok \
  || bad "10: the scanner must flag a bare 'gh pr view' in a marked file"
rm -rf "$T/mut10"; mkdir -p "$T/mut10"
cp "$DIR/bin/lib/gh-rest.sh" "$T/mut10/x.sh"; echo 'gh pr view a/b/1  # gh-guard-allow:' >> "$T/mut10/x.sh"
bash "$T/scan10.sh" "$T/mut10" >/dev/null 2>&1; [ $? = 1 ] && ok \
  || bad "10: a reason-less '# gh-guard-allow:' must not allow"

# ── and the allowlist is a CLOSED set, not a sink ──────────────────────────
# Every allow line in the six files is one of four things: the gated merge verb,
# a `gh run rerun` write, the hotfix proof comment read (#854 converts it), or
# prose inside a log string. Anything else is a read that slipped back in
# wearing a reason, which is exactly what the guard cannot catch by itself.
ALLOWS=$(for f in $SIX; do grep -n '# gh-guard-allow: ' "$DIR/$f" | sed "s|^|$f:|"; done)
UNEXPECTED=$(printf '%s\n' "$ALLOWS" | grep -v 'gh-guard-allow: gated merge verb' \
  | grep -v 'gh-guard-allow: CI rerun write verb' \
  | grep -v 'gh-guard-allow: hotfix proof comment read' \
  | grep -v 'gh-guard-allow: prose in a log line' | sed '/^$/d')
[ -z "$UNEXPECTED" ] && ok || bad "10: unexpected allow reasons: $UNEXPECTED"
# The merge verbs are all four of them, and they are still merge verbs. The
# queue's two landing paths share one verb since BH-892 (mq_land), so the count
# is mc/queue.sh x2 (the lib's pair, moved by BH-477.3), merge-queue x1, sweep x1.
MERGEVERBS=$(printf '%s\n' "$ALLOWS" | grep -c 'gh pr merge .*gh-guard-allow: gated merge verb')
[ "$MERGEVERBS" = 4 ] && ok \
  || bad "10: expected 4 allowlisted 'gh pr merge' verbs (mc/queue.sh x2, merge-queue x1 via mq_land, sweep x1), got $MERGEVERBS: $ALLOWS"
RERUNS=$(printf '%s\n' "$ALLOWS" | grep -c 'gh run rerun .*gh-guard-allow: CI rerun write verb')
[ "$RERUNS" = 3 ] && ok || bad "10: expected 3 allowlisted 'gh run rerun' writes, got $RERUNS"
# A3 — ASSERTION CHANGED (BH-1585, behaviour changed on purpose): this pinned
# the hotfix proof read as "STILL the GraphQL one, tagged for #854". BH-1585 is
# that conversion: the read is REST (issues/<n>/comments, paged), and no
# GraphQL comments read and no allow tag for it may remain.
grep -q 'gh pr view .*--json comments' "$DIR/bin/lib/mc/classify.sh" \
  && bad "10: mc_hotfix_proof must not read the proof comment over GraphQL any more (BH-1585)" || ok
grep -q 'mc_rest_var comments _gh_rest_list "$slug" "issues/$num/comments"' "$DIR/bin/lib/mc/classify.sh" \
  && ok || bad "10: mc_hotfix_proof must read the proof comment through the paged gh_rest reader (issues/<n>/comments)"
fi

echo "conductor-limited-read: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
