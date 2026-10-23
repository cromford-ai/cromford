#!/bin/bash
# tests/rebase-on-pool-test.sh — the HUB half of REBASE_ON_POOL (BH-541/BH-486.2).
#
# WHAT THIS PINS. Under the flag the hub stops rebasing and starts DELEGATING:
# it writes one job file and one queue row, and later reads a RESULT a pool
# machine wrote. Four things have to be true for that to be safe:
#   - rc 6 means a queue row EXISTS. The row goes REBASING on nothing else.
#   - rc 7 means NOTHING was spent — no job file, no attempts line, the budget
#     handed back — so the next tick asks again instead of parking a PR on an
#     outage.
#   - a RESULT this parser cannot read as one of the five documented words is
#     rc 4, never 0. "Succeeded but said nothing usable" must never move a head
#     or an approval.
#   - THE KEY WINS OVER THE FILE. A RESULT is a text file a machine we do not
#     hold wrote: its `PR:` line is trusted only when it names the number in the
#     key, and its `HEAD:` line only when it is 40 hex starting with the key's
#     head8. Anything else is dropped, so no RESULT can rebind another PR's
#     approval or steer a job-file path.
#
# WHY DRIVEN AND NOT GREPPED (D2/D3). `grep -q mc_pool_rebase_enqueue bin/...`
# passes on a branch nothing reaches. Here the REAL bin/merge-conductor.sh runs
# against a scratch $HARNESS with a fake gh and a fake curl, the REAL
# bin/jobs-client.sh makes the queue call, and every assertion is on an
# artifact: pr-state.tsv, attempts.txt, the job files under
# state/merge-conductor/rebase/, their .out files, the recorded HTTP bodies in
# $T/req.txt and merge-conductor.log.
#
# MUTATION NOTES (D1 — each applied once during the build, the red observed, the
# product line restored):
#   - delete the mc_pool_rebase_enabled branch in the NEEDS_REBASE arm   -> §3 red
#     (a detached pid job file appears and nothing is queued)
#   - drop the job-file-first write in mc_pool_rebase_enqueue            -> §1 red
#   - return 6 instead of 7 when queue_put fails                         -> §1b red
#   - make mc_rb_state ignore `pool` (call mc_lane_state always)         -> §2 red
#     (a pool file aged 1000s reads `stale` on the pid-0 rule)
#   - swap rc 0/1 in mc_pool_rebase_apply's REBASED arm                  -> §4/§5 red
#   - reset started_at on a re-enqueue of the same head                  -> §1e red
#   - drop the key-vs-PR cross-check in mc_pool_rebase_apply             -> §4 red
#     (a RESULT naming pull/99 rebinds PR 21's approval)
#   - drop the mc_attempt_clear rebasedone/rebasefailed pair after a
#     successful queue_put                                              -> §6 red
#
# Run from anywhere: bash tests/rebase-on-pool-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# Every temp file the production code makes (an askpass helper, a scratch
# worktree) lands inside the tree this suite deletes, and the "the hub cloned
# nothing" assertions below read the same TMPDIR the code does.
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"

# ONE clock read. Every fixture age below is NOW-<n>; the tick's own mc_now is
# production code and is left alone.
NOW=$(date +%s)

SLUG=example-org/demo-os
PROJ=demo-os
H1=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
NEW2=4444444444444444444444444444444444444444
URL21="https://github.com/$SLUG/pull/21"
URL99="https://github.com/$SLUG/pull/99"
KEY21="$SLUG#21"
RBKEY=RB-21-11111111

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos" "$T/results"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-repo-token.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/rebase-job.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/lane-alerts.txt" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "" > "$4"\nexit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"

# --- the fake git: under the flag it must never be called at all --------------
# It records its argv and FAILS, so a hub path that sneaks back in cannot
# quietly succeed against somebody's real repo; §1c uses the same failure to
# prove the hub path really was taken when the pool app flag is absent.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-argv.txt"
exit 1
EOF
chmod +x "$T/fakebin/git"
: > "$T/git-argv.txt"

# --- the fake curl: the jobs client's transport, recorded ---------------------
# METHOD URL BODY into $REQ_SINK, answering per $T/queue-mode:
#   up   -> {"ok":true} 200        dup  -> {"duplicate":true} 200
#   down -> exit 7 (curl's "could not connect": the transport rc the client reads)
# GET /api/verdict answers a rebindable row only when $T/verdict-ok exists, so
# §4 can drive job_verdict_rebind's refusal through the REAL client.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
U="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\${REQ_SINK:-}" ] && printf '%s %s %s\n' "\$M" "\$U" "\$BODY" >> "\$REQ_SINK"
MODE=\$(cat "$T/queue-mode" 2>/dev/null || echo up)
case "\$M \$U" in
  "PUT "*/api/ledger)  printf '{"ok":true}\n200\n' ;;
  "POST "*/api/queue)
    case "\$MODE" in
      down) exit 7 ;;
      dup)  printf '{"duplicate":true}\n200\n' ;;
      *)    printf '{"ok":true}\n200\n' ;;
    esac ;;
  "GET "*/api/verdict*)
    if [ -f "$T/verdict-ok" ]; then
      printf '{"job_id":"j1","verdict":"APPROVE","reviewed_sha":"%s","artifacts":[{"artifact_kind":"verdict","detail":"{}"}]}\n200\n' "$H1"
    else
      printf '{"error":"not found"}\n404\n'
    fi ;;
  "PUT "*/artifacts) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
echo up > "$T/queue-mode"

# --- the fake gh: PR 21 is open and DIRTY, which classifies as NEEDS_REBASE ---
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"pr review"*|*"issue close"*|*"pr close"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"auth token"*) echo faketoken ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":21,"url":"$URL21","headRefOid":"$H1","headRefName":"ticket/TK-21","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs"*) printf 'completed|success\n' ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"

# PR 21's build record. It carries NO verdict by default: an approved head that
# equals the PR's head buys a patch-id remember, which clones — and §3's claim
# is that the flag leaves the hub's disk untouched. The one case that needs a
# real approval (rc 5, "pushed but the approval did not move") arms it itself.
REC21="$T/h/builds/demo-os-TK-21-202609120021"
mkdir -p "$REC21"
echo "PR_CREATED $URL21" > "$REC21/RESULT"
approve21() { printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC21/review.md"; echo "$H1" > "$REC21/reviewed-sha"; }
touch "$T/h/flags/merge-conductor-actions"
# The app flag NAMES the pool app, as in production: bin/fly-pool.sh treats an
# EMPTY fly-pool-app-<P> as "no dedicated pool app" (reap-only, never spawns),
# and since BH-1372 mc_pool_rebase_enabled asks routing_pool_app, which agrees.
printf 'harness-pool-%s\n' "$PROJ" > "$T/h/flags/fly-pool-app-$PROJ"

export PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=x JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_URL="https://jobs.example"
export REQ_SINK="$T/req.txt"; : > "$T/req.txt"
export MC_REPOS="$T/repos"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh"

RBDIR="$T/h/state/merge-conductor/rebase"
qposts()   { grep -cE '^POST [^ ]*/api/queue ' "$T/req.txt" 2>/dev/null || true; }
qbody()    { grep -E '^POST [^ ]*/api/queue ' "$T/req.txt" | head -1 | cut -d' ' -f3-; }
verdicts() { grep -cE '^GET [^ ]*/api/verdict' "$T/req.txt" 2>/dev/null || true; }
ledgers()  { grep -E '^PUT [^ ]*/api/ledger ' "$T/req.txt" | cut -d' ' -f3-; }
# ledger_status <key> -> the status of the LAST kind=rebase row written for it
ledger_status() {
  ledgers | jq -r --arg k "$1" 'select(.kind=="rebase" and .key==$k) | .status' 2>/dev/null | tail -1
}
clear_jobs() { rm -f "$RBDIR"/*.json "$RBDIR"/*.out 2>/dev/null; return 0; }
JF21=$(mc_rb_file "$SLUG" 21 "$H1")

# ============================================================================
# §1. THE ENQUEUE, HAPPY PATH: one queue row, one pool job file, nothing else.
#     Driven through mc_rebase, which is the function all four callers enter.
# ============================================================================
export REBASE_ON_POOL=1
: > "$T/req.txt"; : > "$T/git-argv.txt"; : > "$MC_LOG"; touch "$T/mark"
clear_jobs
OUT1=$(mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21"); RC1=$?
[ "$RC1" = 6 ] && ok || bad "a queued pool rebase must answer rc 6 (got $RC1)"
[ -z "$OUT1" ] && ok || bad "rc 6 carries no head on stdout — callers read stdout as a sha (got '$OUT1')"
[ "$(qposts)" = 1 ] && ok || bad "exactly one POST /api/queue per enqueue (got $(qposts))"
B=$(qbody)
[ "$(jq -r .key <<<"$B")" = "$RBKEY" ] && ok || bad "the queue key must be RB-<num>-<head8> (got $(jq -r .key <<<"$B"))"
[ "$(jq -r .target <<<"$B")" = fly ] && ok || bad "a pool rebase is a fly row (got $(jq -r .target <<<"$B"))"
[ "$(jq -r .ticket_id <<<"$B")" = 21 ] && ok || bad "ticket_id must be the PR number, or bin/fly-pool.sh quarantines the row (got $(jq -r .ticket_id <<<"$B"))"
[ "$(jq -r .project <<<"$B")" = "$PROJ" ] && ok || bad "the row must name the project (got $(jq -r .project <<<"$B"))"
M=$(jq -r '.meta' <<<"$B" | jq -c . 2>/dev/null)
[ "$(jq -r .kind <<<"$M")" = rebase ] && ok || bad "meta.kind must be rebase (got $(jq -r .kind <<<"$M"))"
[ "$(jq -r .head <<<"$M")" = "$H1" ] && ok || bad "meta.head must be the sha this tick read (got $(jq -r .head <<<"$M"))"
[ "$(jq -r .base <<<"$M")" = main ] && ok || bad "meta.base must be main (got $(jq -r .base <<<"$M"))"
[ "$(jq -r .pr <<<"$M")" = 21 ] && ok || bad "meta.pr must be the number (got $(jq -r .pr <<<"$M"))"
[ "$(jq -r .slug <<<"$M")" = "$SLUG" ] && ok || bad "meta.slug must be owner/repo (got $(jq -r .slug <<<"$M"))"
[ "$(jq -r .url <<<"$M")" = "$URL21" ] && ok || bad "meta.url must be the PR url (got $(jq -r .url <<<"$M"))"
[ "$(jq -r .branch <<<"$M")" = ticket/TK-21 ] && ok || bad "meta.branch must be the branch (got $(jq -r .branch <<<"$M"))"
[ "$(jq -r 'keys|join(",")' <<<"$M")" = "base,branch,head,kind,pr,slug,url" ] && ok \
  || bad "meta carries the documented fields and nothing else (got $(jq -r 'keys|join(",")' <<<"$M"))"
case "$B" in *tok_*|*faketoken*) bad "the queue body carries a credential-shaped string: $B" ;; *) ok ;; esac
# the job file, and the fields a later tick reads off it
[ -f "$JF21" ] && ok || bad "the enqueue must write the job file ($JF21)"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = pool ] && ok || bad "the job file's status must be pool (got $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(jq -r .rc "$JF21" 2>/dev/null)" = "-" ] && ok || bad "a job that has not answered must not carry a numeric rc (got $(jq -r .rc "$JF21" 2>/dev/null))"
[ "$(jq -r .pid "$JF21" 2>/dev/null)" = 0 ] && ok || bad "a pool job has no pid on this box (got $(jq -r .pid "$JF21" 2>/dev/null))"
[ "$(jq -r .head_sha "$JF21" 2>/dev/null)" = "$H1" ] && ok || bad "the job file must record the head it was queued for"
[ "$(jq -r .new_head "$JF21" 2>/dev/null)" = "-" ] && ok || bad "nothing has moved yet, so new_head is -"
# nothing was spent on the hub
[ "$(wc -c < "$T/git-argv.txt")" = 0 ] && ok || bad "the hub ran git under the flag: $(tr '\n' '|' < "$T/git-argv.txt")"
[ -z "$(find "$T/h/tmp" -mindepth 1 2>/dev/null)" ] && ok || bad "the hub left a working tree under \$H/tmp: $(find "$T/h/tmp" -mindepth 1)"
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'mc-rebase-*' -newer "$T/mark" 2>/dev/null)" ] \
  && ok || bad "the hub left a mc-rebase-* worktree in TMPDIR"
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'mc-askpass-*' 2>/dev/null)" ] \
  && ok || bad "the hub wrote an askpass helper under the flag — no credential may be resolved"
# the ledger row, fail-open but written when the client is there
[ "$(ledger_status "$URL21@$H1")" = queued ] && ok \
  || bad "the enqueue must write a kind=rebase ledger row with status queued (got '$(ledger_status "$URL21@$H1")')"
grep -q "pool rebase queued as $RBKEY" "$MC_LOG" && ok || bad "the enqueue must say what it queued (log: $(cat "$MC_LOG"))"

# ============================================================================
# §1b. THE QUEUE REFUSES. rc 7 must leave NOTHING behind — that is what lets the
#      caller hand its budget back and retry on the next tick. And `duplicate`
#      is rc 6: one (project, key) is one row, however many ticks ask.
# ============================================================================
clear_jobs
: > "$T/req.txt"; echo down > "$T/queue-mode"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1; RC2=$?
[ "$RC2" = 7 ] && ok || bad "an unreachable queue must be rc 7, never 6 (got $RC2)"
[ ! -f "$JF21" ] && ok || bad "rc 7 must leave no job file — the next tick would read it as a rebase in flight"
[ ! -f "${JF21%.json}.out" ] && ok || bad "rc 7 must leave no .out file either"
[ "$(qposts)" = 1 ] && ok || bad "the enqueue must have tried exactly once (got $(qposts))"

: > "$T/req.txt"; echo dup > "$T/queue-mode"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1; RC3=$?
[ "$RC3" = 6 ] && ok || bad "a duplicate row is still a queued row: rc 6 (got $RC3)"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = pool ] && ok || bad "a duplicate must still leave the job file in pool"

# ============================================================================
# §1c. THE FLAG IS ON BUT THERE IS NO POOL APP. Fallback, not a page: one log
#      line and the HUB does the rebase — which here means the fake git is
#      reached and refuses, so the rc is the hub's, never 6 or 7.
# ============================================================================
clear_jobs
rm -f "$T/h/flags/fly-pool-app-$PROJ"
: > "$T/req.txt"; : > "$T/git-argv.txt"; : > "$MC_LOG"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1; RC4=$?
case "$RC4" in 6|7) bad "with no pool app the rebase must NOT be queued (got rc $RC4)" ;; *) ok ;; esac
[ -s "$T/git-argv.txt" ] && ok || bad "with no pool app the hub path must be taken — git was never called"
[ "$(qposts)" = 0 ] && ok || bad "with no pool app nothing may be queued (got $(qposts) POSTs)"
[ "$(grep -c 'no pool app' "$MC_LOG")" = 1 ] && ok \
  || bad "the fallback says so exactly once per call, and never alerts (got $(grep -c 'no pool app' "$MC_LOG"))"
printf 'harness-pool-%s\n' "$PROJ" > "$T/h/flags/fly-pool-app-$PROJ"
echo up > "$T/queue-mode"

# ============================================================================
# §1d. NO QUEUE CLIENT SOURCED (a box whose harness-sync has not landed
#      bin/jobs-client.sh): rc 7 and nothing written, never a silent success.
# ============================================================================
clear_jobs
: > "$T/req.txt"
RC5=$(env HARNESS="$T/h" REBASE_ON_POOL=1 MC_REPOS="$T/repos" TMPDIR="$TMPDIR" PATH="$T/fakebin:$PATH" \
      bash -c '. "$1/bin/lib/merge-conductor-lib.sh"; mc_init
               unset -f queue_put
               mc_rebase "$2" "$3" ticket/TK-21 "$4" "$5" >/dev/null 2>&1; echo $?' \
      _ "$T/h" "$SLUG" "$PROJ" "$H1" "$URL21")
[ "$RC5" = 7 ] && ok || bad "no queue client must be rc 7 (got $RC5)"
[ ! -f "$JF21" ] && ok || bad "no queue client must leave no job file"
[ "$(qposts)" = 0 ] && ok || bad "no queue client must make no HTTP call (got $(qposts))"

# ============================================================================
# §1e. A RE-ENQUEUE OF A HEAD ALREADY IN POOL keeps its started_at. The resolver
#      and the rebase train reach mc_rebase without reading the job file, so the
#      same head can be offered again while a machine has it; restarting the
#      clock there means the pool timeout never fires and the PR waits for ever
#      on a machine that died.
# ============================================================================
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-3000)) 0 - "$H1" - "${JF21%.json}.out"
: > "$T/req.txt"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1; RC3b=$?
[ "$RC3b" = 6 ] && ok || bad "a re-enqueue of the same head is still rc 6 (got $RC3b)"
[ "$(jq -r .started_at "$JF21" 2>/dev/null)" = "$((NOW-3000))" ] && ok \
  || bad "a re-enqueue must keep the original started_at or the pool timeout never fires (got $(jq -r .started_at "$JF21" 2>/dev/null))"
# ... but a head whose previous job FAILED starts a fresh clock: that file is
# not a rebase in flight, it is a dead one.
mc_rb_write "$JF21" failed 0 $((NOW-9000)) $((NOW-8000)) 4 "$H1" - "${JF21%.json}.out"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1
[ "$(jq -r .started_at "$JF21" 2>/dev/null)" != "$((NOW-9000))" ] && ok \
  || bad "a re-enqueue over a FAILED file must start its own clock (got $(jq -r .started_at "$JF21" 2>/dev/null))"

# ============================================================================
# §1f. NO PR NUMBER IN THE URL. There is no key to queue under and no ledger key
#      to write, so it is rc 7 with nothing spent — never a row keyed on an
#      empty number (bin/fly-pool.sh quarantines those).
# ============================================================================
clear_jobs
: > "$T/req.txt"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "https://github.com/$SLUG/pull/-" >/dev/null 2>&1; RC1f=$?
[ "$RC1f" = 7 ] && ok || bad "a url with no PR number must be rc 7 (got $RC1f)"
[ "$(qposts)" = 0 ] && ok || bad "a url with no PR number must queue nothing (got $(qposts))"
[ -z "$(find "$RBDIR" -name '*.json' 2>/dev/null)" ] && ok \
  || bad "a url with no PR number must write no job file: $(find "$RBDIR" -name '*.json')"

# ============================================================================
# §2. mc_rb_state LEARNS `pool`. A pool job has no pid here, so the pid rule
#     mc_lane_state applies would call every one of them stale after 120s. The
#     pool timeout is the only clock that judges it — and mc_lane_state itself
#     must be untouched for the pid lanes.
# ============================================================================
PJ="$RBDIR/probe.json"
mc_rb_write "$PJ" pool 0 $((NOW-60)) 0 - "$H1" - /dev/null
[ "$(mc_rb_state "$PJ")" = running ] && ok || bad "a fresh pool job is running (got $(mc_rb_state "$PJ"))"
mc_rb_write "$PJ" pool 0 $((NOW-1000)) 0 - "$H1" - /dev/null
[ "$(mc_rb_state "$PJ")" = running ] && ok \
  || bad "a pool job 1000s old is STILL running — the pid-0 grace rule must not leak in (got $(mc_rb_state "$PJ"))"
mc_rb_write "$PJ" pool 0 $((NOW-6000)) 0 - "$H1" - /dev/null
[ "$(mc_rb_state "$PJ")" = stale ] && ok || bad "a pool job past 5400s is stale (got $(mc_rb_state "$PJ"))"
mc_rb_write "$PJ" pool 0 $((NOW-200)) 0 - "$H1" - /dev/null
[ "$( MC_REBASE_POOL_TIMEOUT_SECS=100 mc_rb_state "$PJ" )" = stale ] && ok \
  || bad "an operator's MC_REBASE_POOL_TIMEOUT_SECS must decide the timeout"
# the pid lanes are untouched
mc_rb_write "$PJ" running "$$" $((NOW-60)) 0 - "$H1" - /dev/null
[ "$(mc_rb_state "$PJ")" = running ] && ok || bad "a running pid job with a live pid is running (got $(mc_rb_state "$PJ"))"
mc_rb_write "$PJ" running 0 $((NOW-1000)) 0 - "$H1" - /dev/null
[ "$(mc_rb_state "$PJ")" = stale ] && ok \
  || bad "a pid job with no pid past the grace window is stale, exactly as before (got $(mc_rb_state "$PJ"))"
mc_rb_write "$PJ" done 0 $((NOW-6000)) $((NOW-5000)) 0 "$H1" "$NEW" /dev/null
[ "$(mc_rb_state "$PJ")" = done ] && ok || bad "a done job stays done at any age (got $(mc_rb_state "$PJ"))"
[ "$(mc_rb_state "$RBDIR/nothing-here.json")" = none ] && ok \
  || bad "a missing job file is none (got $(mc_rb_state "$RBDIR/nothing-here.json"))"
rm -f "$PJ"

# ============================================================================
# §3. THE DRIVEN TICK. The real bin/merge-conductor.sh, flag on, one DIRTY PR:
#     it must queue and move on — no lane job, no pid, no hub worktree — and the
#     NEXT tick must not queue it a second time.
# ============================================================================
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
                JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_URL="https://jobs.example" \
                REQ_SINK="$T/req.txt" MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" \
                TMPDIR="$TMPDIR" REBASE_ON_POOL=1 MC_MERGE_TREE=0 MC_MERGE_SETTLE=0 \
                env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
head_of()   { awk -F'\t' -v k="$1" '$1==k {print $4}' "$T/h/state/merge-conductor/pr-state.tsv"; }
revd_of()   { awk -F'\t' -v k="$1" '$1==k {print $5}' "$T/h/state/merge-conductor/pr-state.tsv"; }
# the LAST tick's own budget counter file for this project (one file per tick)
budget_rebase() { awk '$1=="budget-rebase" {print $2}' \
  "$(ls -t "$T/h/state/merge-conductor/tick"/*."$PROJ" 2>/dev/null | head -1)" 2>/dev/null; }
reset21() {
  rm -f "$REC21/review.md" "$REC21/reviewed-sha"
  clear_jobs
  rm -rf "$T/h/state/merge-conductor/handoff" "$T/h/state/merge-conductor/handoff-released"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  : > "$T/h/state/merge-conductor/pr-state.tsv"
  : > "$T/h/state/merge-conductor/attempts.txt"
  : > "$T/req.txt"; : > "$MC_LOG"; : > "$T/git-argv.txt"
}
touch "$T/h/state/merge-conductor/attempts.txt"

reset21; touch "$T/mark"
run_tick
[ "$(state_of "$KEY21")" = REBASING ] && ok || bad "a DIRTY PR whose rebase was queued must be REBASING (got $(state_of "$KEY21"))"
case "$(reason_of "$KEY21")" in *"pool rebase queued"*) ok ;; *) bad "the row must say the rebase went to the pool (got '$(reason_of "$KEY21")')" ;; esac
case "$(reason_of "$KEY21")" in *"$RBKEY"*) ok ;; *) bad "the row's reason must name the queue key (got '$(reason_of "$KEY21")')" ;; esac
grep -qxF "rebase $KEY21 $H1" "$T/h/state/merge-conductor/attempts.txt" && ok \
  || bad "a queued rebase is this head's one rebase and must be recorded in attempts.txt"
[ "$(qposts)" = 1 ] && ok || bad "the tick must queue exactly one row (got $(qposts))"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = pool ] && ok || bad "the tick's job file must be pool (got $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(jq -r .pid "$JF21" 2>/dev/null)" = 0 ] && ok || bad "the tick must spawn nothing: pid must stay 0 (got $(jq -r .pid "$JF21" 2>/dev/null))"
[ -z "$(grep -l '"status":"running"' "$RBDIR"/*.json 2>/dev/null)" ] && ok \
  || bad "no detached lane job may exist under the flag"
# THE ONE READ-ONLY VERB THIS ALLOWS (BH-870). The land trigger asks
# `ls-remote` for this project's base sha once per tick, before any PR is
# classified, and that read happens whatever the pool flag says — it is what
# decides whether a landing fans out at all, on the hub or on a pool. It clones
# nothing, fetches nothing, checks out nothing and pushes nothing, which is what
# this assertion is about: no hub REBASE WORK under the flag. Every other git
# verb is still the failure it always was, and the two probes below (no scratch
# clone, no mc-rebase-* worktree) are unchanged.
HUBGIT=$(grep -v -- 'ls-remote' "$T/git-argv.txt" 2>/dev/null)
[ -z "$HUBGIT" ] && ok || bad "the tick ran git under the flag: $(tr '\n' '|' <<<"$HUBGIT")"
# $H/tmp/conductor is where a hub-side rebase clones and worktrees; $H/tmp
# itself also holds the merge-queue provider cache, which every tick writes and
# which has nothing to do with rebasing.
[ ! -d "$T/h/tmp/conductor" ] && ok || bad "the tick left a scratch clone at \$H/tmp/conductor: $(find "$T/h/tmp/conductor" -maxdepth 1)"
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'mc-rebase-*' -newer "$T/mark" 2>/dev/null)" ] \
  && ok || bad "the tick left a mc-rebase-* worktree in TMPDIR"
grep -q "pool rebase queued" "$MC_LOG" && ok || bad "the tick must log the queued rebase"
# the second tick reads the SAME job file and must neither queue nor mislabel it
run_tick
[ "$(qposts)" = 1 ] && ok || bad "a second tick over a queued rebase must not queue it again (got $(qposts))"
grep -q "pool rebase running on a pool machine" "$MC_LOG" && ok \
  || bad "a running pool rebase must say where it is running (log: $(grep "$KEY21" "$MC_LOG" | tail -3))"
grep -q "pid 0" "$MC_LOG" && bad "a pool job has no pid and must never be described as one (log: $(grep 'pid 0' "$MC_LOG"))" || ok
[ "$(state_of "$KEY21")" = REBASING ] && ok || bad "the row stays REBASING while the pool works (got $(state_of "$KEY21"))"
[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# §3b. THE QUEUE IS DOWN DURING A TICK. Nothing spent: no attempts line, no job
#      file, the tick budget handed back, and the tick AFTER it (queue back)
#      queues the rebase — which is the proof that the first tick spent nothing.
# ============================================================================
reset21; echo down > "$T/queue-mode"
run_tick
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "an unreachable queue leaves the PR NEEDS_REBASE (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "pool queue unreachable, retry" ] && ok \
  || bad "the row must say the queue was unreachable (got '$(reason_of "$KEY21")')"
grep -qxF "rebase $KEY21 $H1" "$T/h/state/merge-conductor/attempts.txt" \
  && bad "rc 7 must NOT burn this head's one rebase — the next tick would never retry it" || ok
[ ! -f "$JF21" ] && ok || bad "rc 7 must leave no job file behind"
[ "$(budget_rebase)" = 0 ] && ok || bad "rc 7 must hand the tick's rebase budget back (got '$(budget_rebase)')"
echo up > "$T/queue-mode"; : > "$T/req.txt"
run_tick
[ "$(qposts)" = 1 ] && ok || bad "the tick after the outage must queue the rebase (got $(qposts))"
[ "$(state_of "$KEY21")" = REBASING ] && ok || bad "and the row must then be REBASING (got $(state_of "$KEY21"))"

# ============================================================================
# §4. mc_pool_rebase_apply: THE RESULT PARSER. Every adversarial shape in the
#     plan's invariant (c) list is here, and the claim is the same for all of
#     them: a RESULT that is not one of the five words is rc 4, never 0 — and a
#     RESULT that disagrees with the KEY loses.
# ============================================================================
RES="$T/results/RESULT"
# The rebind runs through the REAL bin/jobs-client.sh against the fake curl:
# $T/verdict-ok present = the worker has a rebindable row (rc 0), absent = 404
# (rc 1, "the approval did not move").
touch "$T/verdict-ok"
mkres() { # mkres <first line> [pr-line-or-'-'] [head-line-or-'-']
  { printf '%s\n' "$1"
    [ "${2:-}" = "-" ] || printf 'PR: %s\n' "${2:-$URL21}"
    [ "${3:-}" = "-" ] || printf 'HEAD: %s\n' "${3:-$H1}"
    printf 'BRANCH: ticket/TK-21\nBASE: main\nGATE: typecheck=0 unit=skipped\n'; } > "$RES"
}
apply21() { : > "$T/req.txt"; mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES"; }
jfrc()  { jq -r .rc "$JF21" 2>/dev/null; }
jfout() { cat "$(jq -r .out_file "$JF21" 2>/dev/null)" 2>/dev/null; }

# --- REBASED <sha>, rebind OK -------------------------------------------------
reset21
echo "$H1" > "$REC21/reviewed-sha"
mkres "REBASED $NEW"; apply21; APRC=$?
[ "$APRC" = 0 ] && ok || bad "apply must return 0 when it wrote the job file (got $APRC)"
[ -f "$JF21" ] && ok || bad "apply must create the job file even when the hub lost it ($JF21)"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = done ] && ok || bad "an applied job is done (got $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(jfrc)" = 0 ] && ok || bad "REBASED with a good sha and a good rebind is rc 0 (got $(jfrc))"
[ "$(jq -r .new_head "$JF21" 2>/dev/null)" = "$NEW" ] && ok || bad "the job file must record the pushed head (got $(jq -r .new_head "$JF21" 2>/dev/null))"
[ "$(jfout)" = "$NEW" ] && ok || bad "the .out file must be the new sha — it is what rebase_result reads as a head (got '$(jfout)')"
[ "$(cat "$REC21/reviewed-sha")" = "$NEW" ] && ok || bad "an EXISTING reviewed-sha must move with the rebound approval (got $(cat "$REC21/reviewed-sha"))"
[ "$(ledger_status "$URL21@$H1")" = REBASED ] && ok || bad "the ledger row must be REBASED (got '$(ledger_status "$URL21@$H1")')"
[ "$(verdicts)" -ge 1 ] && ok || bad "the approval rebind must be attempted (no GET /api/verdict was made)"

# a record with NO reviewed-sha must not have one invented for it
rm -f "$REC21/reviewed-sha"; clear_jobs
mkres "REBASED $NEW2"; apply21 >/dev/null
[ ! -e "$REC21/reviewed-sha" ] && ok || bad "a record that never claimed a reviewed sha must not gain one"
[ "$(jfrc)" = 0 ] && ok || bad "a missing reviewed-sha file is not a rebind failure (got $(jfrc))"

# --- REBASED <sha>, rebind REFUSED -> rc 5, never 0 --------------------------
# And the record's reviewed-sha stays where it was: the approval did NOT move,
# so a file that says it did would hand the sweep an unreviewed head.
echo "$H1" > "$REC21/reviewed-sha"; rm -f "$T/verdict-ok"; clear_jobs
mkres "REBASED $NEW"; apply21 >/dev/null
[ "$(jfrc)" = 5 ] && ok || bad "a refused rebind is rc 5 — reporting 0 would merge a sha nobody approved (got $(jfrc))"
[ "$(jq -r .new_head "$JF21" 2>/dev/null)" = "$NEW" ] && ok || bad "rc 5 still records the head that was pushed"
[ "$(jfout)" = "$NEW" ] && ok || bad "rc 5's .out is still the new sha (rebase_result reads it as a head)"
[ "$(cat "$REC21/reviewed-sha")" = "$H1" ] && ok \
  || bad "a refused rebind must leave reviewed-sha where it was (got $(cat "$REC21/reviewed-sha"))"
touch "$T/verdict-ok"; rm -f "$REC21/reviewed-sha"

# --- the rest of the vocabulary ----------------------------------------------
# row <first line> <expected job rc> <expected .out> <expected ledger status>
row() {
  local first="$1" want="$2" wantout="$3" wantled="$4"
  clear_jobs
  mkres "$first"
  apply21 >/dev/null; local arc=$?
  [ "$arc" = 0 ] && ok || bad "apply('$first') must return 0 once it wrote the file (got $arc)"
  [ "$(jfrc)" = "$want" ] && ok || bad "apply('$first') must record rc $want (got $(jfrc))"
  [ "$(jfout)" = "$wantout" ] && ok || bad "apply('$first') .out must be '$wantout' (got '$(jfout)')"
  if [ -n "$wantled" ]; then
    [ "$(ledger_status "$URL21@$H1")" = "$wantled" ] && ok \
      || bad "apply('$first') ledger status must be $wantled (got '$(ledger_status "$URL21@$H1")')"
  fi
}
row "CONFLICT a.txt b.txt"          1 "a.txt b.txt" CONFLICT
row "CONFLICT"                      1 "-"           CONFLICT
row "GATE_RED unit"                 2 "GATE_RED unit" GATE_RED
row "GATE_RED"                      2 "GATE_RED"      GATE_RED
row "REBASE_LEASE_REJECTED moved"   3 "REBASE_LEASE_REJECTED moved" LEASE_REJECTED
row "REBASE_SETUP_FAILED no token"  4 "REBASE_SETUP_FAILED no token" SETUP_FAILED
# NEGATIVES (plan invariant (c)): none of these may ever be rc 0.
row ""                              4 "empty RESULT" SETUP_FAILED
row "REBASED"                       4 "REBASED with no usable sha: REBASED" SETUP_FAILED
row "REBASED notasha"               4 "REBASED with no usable sha: REBASED notasha" SETUP_FAILED
row "REBASED 111111111111111111111111111111111111111" 4 \
    "REBASED with no usable sha: REBASED 111111111111111111111111111111111111111" SETUP_FAILED
row "REBASE_OK $NEW"                4 "REBASE_OK $NEW" SETUP_FAILED
row "rebased $NEW"                  4 "rebased $NEW" SETUP_FAILED
row "  REBASED $NEW"                4 "  REBASED $NEW" SETUP_FAILED
row "Error: panic: runtime error REBASED $NEW" 4 "Error: panic: runtime error REBASED $NEW" SETUP_FAILED
row "PR: $URL21"                    4 "PR: $URL21" SETUP_FAILED

# GATE_RED with no HEAD: line is still rc 2 — the head falls back to the job file
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-120)) 0 - "$H1" - "${JF21%.json}.out"
mkres "GATE_RED typecheck" "" "-"; apply21 >/dev/null
[ "$(jfrc)" = 2 ] && ok || bad "a RESULT with no HEAD: line must still map its word (got $(jfrc))"
[ "$(jq -r .head_sha "$JF21" 2>/dev/null)" = "$H1" ] && ok || bad "the head must fall back to the job file this key already has (got $(jq -r .head_sha "$JF21" 2>/dev/null))"

# a RESULT with no PR: line can rebind nothing, so it is rc 4 and NO ledger row
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-120)) 0 - "$H1" - "${JF21%.json}.out"
mkres "REBASED $NEW" "-"; apply21 >/dev/null
[ "$(jfrc)" = 4 ] && ok || bad "REBASED with no PR: line must be rc 4 — an approval is never presumed moved (got $(jfrc))"
[ "$(verdicts)" = 0 ] && ok || bad "no url means no rebind was even attempted (got $(verdicts) verdict reads)"
[ -z "$(ledgers)" ] && ok || bad "no url means no ledger key, so no row: $(ledgers)"

# --- THE KEY WINS OVER THE FILE (the #757 review must-fix) -------------------
# A RESULT naming ANOTHER PR must never rebind this one's approval. The key says
# 21; the file says 99; the file loses, and the recorded rc is 4.
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-120)) 0 - "$H1" - "${JF21%.json}.out"
: > "$MC_LOG"
mkres "REBASED $NEW" "$URL99"; apply21 >/dev/null
[ "$(jfrc)" = 4 ] && ok || bad "a RESULT naming another PR must not be read as a rebase of this one (got $(jfrc))"
[ "$(verdicts)" = 0 ] && ok || bad "and no approval anywhere may be rebound from it (got $(verdicts) verdict reads)"
[ -z "$(ledgers)" ] && ok || bad "a dropped url leaves no honest ledger key, so no row: $(ledgers)"
grep -q "names PR 99, not 21" "$MC_LOG" && ok || bad "the mismatch must be logged (log: $(cat "$MC_LOG"))"

# A HEAD: line that is not this key's head8 is dropped, and the job file is the
# one the KEY names — a RESULT can never steer the path a job file is written to.
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-120)) 0 - "$H1" - "${JF21%.json}.out"
touch "$T/pathmark"
mkres "CONFLICT z.txt" "" "../../etc/x"; apply21 >/dev/null
[ "$(jfrc)" = 1 ] && ok || bad "a RESULT with a junk HEAD: line still maps its word off the key's job file (got $(jfrc))"
OUTSIDE=$(find "$T/h" "$T/results" -newer "$T/pathmark" -name '*.json' 2>/dev/null | grep -v "^$RBDIR/" || true)
[ -z "$OUTSIDE" ] && ok || bad "a RESULT wrote a job file outside \$MC_RB_DIR: $OUTSIDE"
[ "$(jq -r .head_sha "$JF21" 2>/dev/null)" = "$H1" ] && ok \
  || bad "the head must come from the key's own job file, never from the RESULT's junk (got $(jq -r .head_sha "$JF21" 2>/dev/null))"

# A HEAD: line carrying the NEW sha (a machine that reported where it ended up)
# is not this key's head either: the job file is still the one keyed on the OLD
# head, and new_head is where the branch went.
clear_jobs
mc_rb_write "$JF21" pool 0 $((NOW-120)) 0 - "$H1" - "${JF21%.json}.out"
mkres "REBASED $NEW" "" "$NEW"; apply21 >/dev/null
[ -f "$JF21" ] && ok || bad "the job file must stay the one the KEY names ($JF21)"
[ "$(jq -r .head_sha "$JF21" 2>/dev/null)" = "$H1" ] && ok \
  || bad "head_sha is the head the job was queued for (got $(jq -r .head_sha "$JF21" 2>/dev/null))"
[ "$(jq -r .new_head "$JF21" 2>/dev/null)" = "$NEW" ] && ok \
  || bad "new_head is where the branch ended up (got $(jq -r .new_head "$JF21" 2>/dev/null))"
[ "$(jfrc)" = 0 ] && ok || bad "and the rebase itself still counts (got $(jfrc))"

# a LATE result over a failed file still applies — a pushed head is a fact
clear_jobs
mc_rb_write "$JF21" failed 0 $((NOW-6000)) $((NOW-100)) 4 "$H1" - "${JF21%.json}.out"
mkres "REBASED $NEW"; apply21 >/dev/null
[ "$(jq -r .status "$JF21" 2>/dev/null)" = done ] && ok || bad "a late RESULT must rewrite a failed job file to done (got $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(jfrc)" = 0 ] && ok || bad "and the late result's rc is the one the machine reported (got $(jfrc))"
[ "$(jq -r .started_at "$JF21" 2>/dev/null)" = "$((NOW-6000))" ] && ok \
  || bad "an applied result keeps the job's original started_at (got $(jq -r .started_at "$JF21" 2>/dev/null))"

# nothing to read at all
clear_jobs
mc_pool_rebase_apply "$PROJ" RB-77-99999999 "$T/results/does-not-exist"; APRC=$?
[ "$APRC" = 1 ] && ok || bad "a missing RESULT file must be rc 1 so the caller alerts (got $APRC)"
[ -z "$(find "$RBDIR" -name '*.json' 2>/dev/null)" ] && ok \
  || bad "a RESULT that cannot be located must write no job file"
mkres "REBASED $NEW"
mc_pool_rebase_apply "$PROJ" "" "$RES"; APRC=$?
[ "$APRC" = 1 ] && ok || bad "an empty key must be rc 1 (got $APRC)"
# a key whose (num, head8) names no job file on disk, and whose RESULT lines are
# all unusable, has nothing honest to write: rc 1, and the caller alerts.
mkres "REBASED $NEW" "-" "-"
mc_pool_rebase_apply "$PROJ" RB-21-aaaaaaaa "$RES"; APRC=$?
[ "$APRC" = 1 ] && ok || bad "a key that matches no job file and no RESULT line must be rc 1 (got $APRC)"

# ============================================================================
# §5. THE CONSUME. The tick reads each applied job file once and turns it into
#     the row the inline rebase always produced — plus the pool timeout.
# ============================================================================
consume_case() { # consume_case <first line> [verdict-row: ok|no]
  reset21
  if [ "${2:-ok}" = no ]; then rm -f "$T/verdict-ok"; else touch "$T/verdict-ok"; fi
  { printf '%s\n' "$1"; printf 'PR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$URL21" "$H1"; } > "$RES"
  mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
  : > "$T/req.txt"
  run_tick
}
consume_case "REBASED $NEW"
[ "$(state_of "$KEY21")" = WAIT_CI ] && ok || bad "a consumed rc-0 pool rebase must be WAIT_CI (got $(state_of "$KEY21"))"
[ "$(head_of "$KEY21")" = "$NEW" ] && ok || bad "the row's head must be the pushed sha (got $(head_of "$KEY21"))"
[ "$(revd_of "$KEY21")" = "$NEW" ] && ok || bad "the approval must have moved with it (got $(revd_of "$KEY21"))"
grep -q "rebased: pushed ${NEW:0:8} over ${H1:0:8}" "$MC_LOG" && ok || bad "the consumed result logs exactly as the inline path did"

consume_case "CONFLICT a.txt b.txt"
[ "$(state_of "$KEY21")" = BLOCKED_HUMAN ] && ok || bad "a conflict parks the PR (got $(state_of "$KEY21"))"
case "$(reason_of "$KEY21")" in "conflict-unresolvable: a.txt b.txt"*) ok ;; *) bad "the park reason must carry the conflicting paths (got '$(reason_of "$KEY21")')" ;; esac
grep -q "BLOCKED_AGENT conflict-unresolvable" "$MC_LOG" && ok || bad "the conflict must be handed to the resolver in the log"

consume_case "GATE_RED unit"
[ "$(state_of "$KEY21")" = BLOCKED_HUMAN ] && ok || bad "a red gate parks the PR (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "rebase-gate-red" ] && ok || bad "a red gate parks as rebase-gate-red (got '$(reason_of "$KEY21")')"

consume_case "REBASE_LEASE_REJECTED the head moved"
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "a rejected lease is retried, not parked (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "lease rejected, retry" ] && ok || bad "and it says so (got '$(reason_of "$KEY21")')"

consume_case "REBASE_SETUP_FAILED no token"
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "a setup failure is retried (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "rebase setup failed rc=4" ] && ok || bad "and it names the rc (got '$(reason_of "$KEY21")')"

# A REBASED result whose rebind was refused on a PR with NO approval is not a
# failure at all: there was no claim to move, so the row goes WAIT_CI with no
# reviewed sha and the head-bound review is bought on the new head.
consume_case "REBASED $NEW" no
[ "$(state_of "$KEY21")" = WAIT_CI ] && ok || bad "a PR that never had an approval must not be parked by a rebind refusal (got $(state_of "$KEY21"))"
[ "$(revd_of "$KEY21")" = "-" ] && ok || bad "and it must claim no reviewed sha (got '$(revd_of "$KEY21")')"

# The one case that needs a real approval on the row: rc 5 is "the push landed,
# the approval did NOT move", and that row must never read as reviewed.
reset21; approve21
rm -f "$T/verdict-ok"
{ printf 'REBASED %s\nPR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$NEW" "$URL21" "$H1"; } > "$RES"
mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
: > "$T/req.txt"
run_tick
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "a rebase whose approval could not be moved must NOT go WAIT_CI (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "rebind-failed" ] && ok || bad "and the row says the rebind failed (got '$(reason_of "$KEY21")')"
touch "$T/verdict-ok"

# --- the hub timeout ---------------------------------------------------------
reset21
mc_rb_write "$JF21" pool 0 $((NOW-6000)) 0 - "$H1" - "${JF21%.json}.out"
: > "$T/req.txt"
run_tick
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "a pool rebase nobody answered puts the PR back in NEEDS_REBASE (got $(state_of "$KEY21"))"
[ "$(reason_of "$KEY21")" = "detached rebase produced no result" ] && ok \
  || bad "the timeout reason is unchanged (got '$(reason_of "$KEY21")')"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = failed ] && ok || bad "the timed-out job file must be failed (got $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(ledger_status "$URL21@$H1")" = TIMED_OUT ] && ok \
  || bad "a pool timeout must be a TIMED_OUT ledger row (got '$(ledger_status "$URL21@$H1")')"
grep -q "produced no RESULT within" "$MC_LOG" && ok || bad "the log must name the pool timeout, not a dead pid"
# AND A LATE RESULT STILL APPLIES over that failed file.
{ printf 'REBASED %s\nPR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$NEW" "$URL21" "$H1"; } > "$RES"
mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
: > "$T/req.txt"; : > "$MC_LOG"
run_tick
[ "$(state_of "$KEY21")" = WAIT_CI ] && ok \
  || bad "a RESULT that arrived after the hub gave up must still be read (got $(state_of "$KEY21"))"

# NEGATIVE: a pid job that timed out is NOT a pool timeout and writes no row
reset21
mc_rb_write "$JF21" running 0 $((NOW-4000)) 0 - "$H1" - "${JF21%.json}.out"
: > "$T/req.txt"
run_tick
[ "$(state_of "$KEY21")" = NEEDS_REBASE ] && ok || bad "a dead detached job still parks the PR in NEEDS_REBASE (got $(state_of "$KEY21"))"
[ -z "$(ledger_status "$URL21@$H1")" ] && ok \
  || bad "a pid job's timeout is not a pool timeout and must write no TIMED_OUT row (got '$(ledger_status "$URL21@$H1")')"
grep -q "pid dead or past" "$MC_LOG" && ok || bad "a dead pid job keeps its own wording (log: $(grep "$KEY21" "$MC_LOG" | tail -2))"

# THE KILL SWITCH AND THE FLAG TOGETHER. MC_DETACHED_REBASE=0 turns the detached
# lane off; with the pool flag on, the result a machine already wrote must still
# be read, or the row sits REBASING for ever under a `done` job file.
reset21
{ printf 'REBASED %s\nPR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$NEW" "$URL21" "$H1"; } > "$RES"
mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
: > "$T/req.txt"
run_tick MC_DETACHED_REBASE=0
[ "$(state_of "$KEY21")" = WAIT_CI ] && ok \
  || bad "a pool result must be consumed even with the detached-lane kill switch off (got $(state_of "$KEY21"))"

# ============================================================================
# §6. THE SECOND ANSWER FOR THE SAME HEAD. The tick enqueues a head once, but
#     the resolver's rung 1 (and the rebase train, and the stuck re-kick) reach
#     mc_rebase for a head the conductor has ALREADY turned into a row. The
#     claim: a re-queued head owes a fresh read, so the pool's second answer
#     reaches pr-state.tsv exactly like the first.
#
#     What this catches if the enqueue does not forget the read: rebase_consume
#     bails on `mc_attempted rebasedone`, the `done` file is never read, the row
#     falls back to NEEDS_REBASE on mergeState, the park that the resolver's
#     rung 2 (the fix round) waits for is never made — and the stuck re-kick
#     then buys one more billable pool machine for the same head every TTL.
# ============================================================================
ATT="$T/h/state/merge-conductor/attempts.txt"
reset21
run_tick                                     # tick 1: the head is queued
[ "$(state_of "$KEY21")" = REBASING ] && ok || bad "§6 setup: the first tick must queue the rebase (got $(state_of "$KEY21"))"
{ printf 'CONFLICT a.txt\nPR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$URL21" "$H1"; } > "$RES"
mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
run_tick                                     # tick 2: the first answer is read
[ "$(state_of "$KEY21")" = BLOCKED_HUMAN ] && ok || bad "§6 setup: the first CONFLICT must park the PR (got $(state_of "$KEY21"))"
grep -qxF "rebasedone $KEY21 $H1" "$ATT" && ok || bad "§6 setup: the first answer must be recorded as read"
# THE RESOLVER'S RUNG 1, exactly as br_mechanical takes it: mc_rebase on the
# same head (it never reads the job file), then its own row move off the park.
: > "$T/req.txt"
mc_rebase "$SLUG" "$PROJ" ticket/TK-21 "$H1" "$URL21" >/dev/null 2>&1; RC6=$?
[ "$RC6" = 6 ] && ok || bad "the resolver's re-offer of a parked head must queue a pool rebase (got rc $RC6)"
[ "$(qposts)" = 1 ] && ok || bad "the re-offer queues exactly one row (got $(qposts))"
[ "$(jq -r .status "$JF21" 2>/dev/null)" = pool ] && ok || bad "the re-offer puts the job file back in pool (got $(jq -r .status "$JF21" 2>/dev/null))"
grep -qxF "rebasedone $KEY21 $H1" "$ATT" \
  && bad "a re-queued head owes a FRESH read — the previous result's rebasedone line must be forgotten, or the pool's next answer is unreadable" || ok
mc_transition "$KEY21" REBASING "pool rebase queued by the resolver" "$H1" "-" "$URL21" "-" "-" "-" >/dev/null
# The machine answers a second time. Main did not move enough, so it is another
# conflict — the shape that has to reach rung 2.
{ printf 'CONFLICT c.txt\nPR: %s\nHEAD: %s\nBRANCH: ticket/TK-21\nBASE: main\n' "$URL21" "$H1"; } > "$RES"
mc_pool_rebase_apply "$PROJ" "$RBKEY" "$RES" >/dev/null
: > "$T/req.txt"; : > "$MC_LOG"
run_tick
[ "$(state_of "$KEY21")" = BLOCKED_HUMAN ] && ok \
  || bad "the pool's SECOND answer for this head must reach the row (got $(state_of "$KEY21"))"
case "$(reason_of "$KEY21")" in "conflict-unresolvable: c.txt"*) ok ;; *) bad "and it must be the second answer's own conflict, not the first's (got '$(reason_of "$KEY21")')" ;; esac
grep -q "BLOCKED_AGENT conflict-unresolvable" "$MC_LOG" && ok \
  || bad "the park must be handed to the resolver, which is how the fix round is reached (log: $(grep "$KEY21" "$MC_LOG" | tail -3))"
[ "$(qposts)" = 0 ] && ok || bad "the tick that reads an answer must not buy another pool machine (got $(qposts) POSTs)"

[ -s "$T/gh-writes.txt" ] && bad "a write verb ran somewhere in this file: $(cat "$T/gh-writes.txt")" || ok

echo "rebase-on-pool-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
