#!/bin/bash
# tests/orphan-reconcile-test.sh — bin/orphan-reconcile.sh: every open ai-build
# issue has exactly ONE owner, and the ones with none get launched.
#
# WHY THIS EXISTS (2026-09-15). Three project-5 tickets stalled for hours because
# every launch path in the harness is edge-triggered and the edge never fired:
# #670 closed and #671 was never keyed into a wake, #719 merged and #721 was
# never re-scoped, PR #1045 went red and nobody re-kicked TK-989 — while the box
# logged `gate no-change (103 tickets)` every ten minutes, correctly. The
# reconciler computes the owner set from scratch instead of being told.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a DECISION: which of the
# five owner classes claims a ticket, and whether the thing actually launches.
# `grep -q queue_put` would pass on a version that enqueues a ticket a pool
# machine is already building — which is the one failure that costs money.
# gh and curl are PATH shims (no network, no secrets); run-build.sh is a shim
# that records its argv, so "did it launch, with which key" is provable.
# Run from anywhere: tests/orphan-reconcile-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
cp "$DIR/bin/orphan-reconcile.sh" "$H/bin/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
# The shared hold vocabulary (BH-408). Section 12 drives the same three regexes
# bin/blocked-resolver.sh's gate reads, and asserts the unsynced-box fallback
# with this file removed.
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/closeout-overdue.sh" "$H/bin/lib/"
# The REST contract itself (BH-1163). Copied, never stubbed: the rc 0/44/75
# mapping under test IS this file's, and a stub would test the stub.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
# The key prefix is READ FROM THE PROMPT (bin/lib/preplan-lib.sh:
# preplan_key_prefix), which is the harness's only statement of it — a stubbed
# prefix would test the stub.
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# run-build.sh: the launch, recorded. setsid backgrounds it, so the argv lands
# in a file rather than in this shell.
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# gh shim — a REST endpoint, not the CLI (BH-1163). bin/lib/gh-rest.sh calls
# `gh api -i -X GET <path> …`, so this answers with a status LINE, a blank line
# and a body, which is what the library parses and what makes rc 0/44/75 real
# here rather than mocked.
#
# THE FIXTURES ARE AUTHORED IN THE OLD, READABLE SHAPE and translated to the
# wire shape by the jq below: `comments` is a list here and a COUNT on the
# wire, `updatedAt`/`closedAt`/`headRefName` are `updated_at`/`closed_at`/
# `head.ref` on the wire, and a thread is its own endpoint. The script under
# test only ever sees the wire shape, so the assertions are still about REST.
#
# INJECTING A STATUS: `SETST <route> <code>` writes $HARNESS/st-<route>, and the
# route names are open / all / pulls / issue / comments. GH_FAIL=1 is a 500 on
# everything — the dead-token case, which is rc 75 and not an empty board.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
ST()   { cat "$HARNESS/st-$1" 2>/dev/null || echo "$2"; }
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
# GitHub's OWN wording on the two statuses that can mean a limit — the library
# only sniffs the reason out of the body, so an error body that says nothing
# would test a 429 the library cannot classify.
ERRB() { case "$1" in 403|429) echo '{"message":"API rate limit exceeded for installation."}' ;;
                      404) echo '{"message":"Not Found"}' ;;
                      *) echo '{"message":"no"}' ;; esac; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "${GH_FAIL:-}" = 1 ] && SEND 500 '{"message":"bad credentials"}'
case "$ARGS" in
  *"api rate_limit"*)
    if [ -n "${GH_BUDGET_CORE_REMAINING:-}" ]; then
      jq -nc --argjson core "$GH_BUDGET_CORE_REMAINING" --argjson graph 5000 '{
        resources: {
          core: {remaining: $core, limit: 5000, reset: 9999999999},
          graphql: {remaining: $graph, limit: 5000, reset: 9999999999}
        }
      }'
    else
      exit 1
    fi ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    s=$(ST comments 200)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' \
                 "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*)
    s=$(ST pulls 200)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, head:{ref:.headRefName}} ]' \
                 "$HARNESS/fixture/prs.json")" ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    s=$(ST issue 200)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '{number, state:(.state|ascii_downcase), closed_at:.closedAt}' \
                 "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*"state=all"*)
    s=$(ST all 200)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:(.state|ascii_downcase), closed_at:.closedAt} ]' \
                 "$HARNESS/fixture/states.json")" ;;
  *"/issues"*)
    s=$(ST open 200)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length),
                               updated_at:.updatedAt} + (if .pull_request then {pull_request:.pull_request} else {} end) ]' \
                 "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
SETST() { printf '%s' "$2" > "$H/st-$1"; }     # SETST <open|all|pulls|issue|comments> <code>
CLRST() { rm -f "$H"/st-* 2>/dev/null; }

# curl shim for jobs-client: /api/jobs and /api/queue answer from fixtures.
# CURL_MODE=down is the ledger outage the script must fail CLOSED on.
# The orphan-thread-cursor `ledgers` row (BH-8497) is kept in
# $HARNESS/fixture/ledger-cursor/<key>.json: a PUT writes it, a GET reads it
# back ({"ledger":null} when absent). Every other ledger kind answers as before.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
[ "${CURL_MODE:-ok}" = down ] && exit 7
M=GET; D=""; prev=""
for a in "$@"; do case "$prev" in -X) M="$a" ;; --data-binary) D="$a" ;; esac; prev="$a"; done
LD="$HARNESS/fixture/ledger-cursor"
case "$URL" in
  */api/ledger\?kind=orphan-thread-cursor\&key=*)
    K=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1].split("&key=",1)[1]), end="")' "$URL" | tr -c 'A-Za-z0-9._-' '_')
    if [ -f "$LD/$K.json" ]; then printf '{"ledger":%s}\n200\n' "$(cat "$LD/$K.json")"
    else printf '{"ledger":null}\n200\n'; fi ;;
  */api/ledger)
    if [ "$M" = PUT ] && [ "$(jq -r '.kind' <<<"$D" 2>/dev/null)" = orphan-thread-cursor ]; then
      K=$(jq -j '.key' <<<"$D" | tr -c 'A-Za-z0-9._-' '_'); mkdir -p "$LD"
      jq -c '{status, detail}' <<<"$D" > "$LD/$K.json"
    fi
    printf '{"ok":true}\n200\n' ;;
  */api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  */api/queue*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/queuerows.json")" ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# --- the fixture board -------------------------------------------------------
# One issue per owner class plus a genuine orphan, so a single run proves the
# whole rule. #671 is the incident's own ticket: its blocker closed long ago,
# nothing is building it, no PR carries it, nobody held it.
open_board() {
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":671,"title":"TK-670.1 org chart After view","body":"## Scope\nBlocked-by: #670","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":721,"title":"TK-719.2 carry-forward","body":"## Scope\nBlocked-by: #719","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":989,"title":"TK-989 retention sweeper","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":900,"title":"TK-900 running on a pool machine","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":901,"title":"TK-901 queued in the DB","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":902,"title":"TK-902 has an open PR","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":903,"title":"TK-903 blocked by an open sibling","body":"## Scope\nBlocked-by: #904","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":904,"title":"TK-904 the open sibling","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":905,"title":"TK-905 the decompose parent","body":"## Scope\nXL, split below.","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":906,"title":"TK-905.1 first slice","body":"Part of #905\nOrder: 1 of 2","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":911,"title":"TK-2416.0: contract slice owned by its child-keyed PR","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":14,"title":"Compliance P7 (HOLD): EU residency — deal-triggered","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":887,"title":"TK-875.1 report_rebuilt email type","body":"## Scope","comments":[{"body":"HOLD — the operator (2026-09-14 ~23:10Z): no customer email about rebuilt reports for now. Do not build this until the operator lifts the hold."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":907,"title":"TK-907 blocker closed two minutes ago","body":"## Scope\nBlocked-by: #908","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":909,"title":"TK-909 its own thread just moved","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 120)"}
]
JSON
  cat > "$H/fixture/states.json" <<JSON
[
 {"number":671,"state":"OPEN","closedAt":null},
 {"number":670,"state":"CLOSED","closedAt":"$(NOWISO 10800)"},
 {"number":721,"state":"OPEN","closedAt":null},
 {"number":719,"state":"CLOSED","closedAt":"$(NOWISO 10800)"},
 {"number":989,"state":"OPEN","closedAt":null},
 {"number":900,"state":"OPEN","closedAt":null},
 {"number":901,"state":"OPEN","closedAt":null},
 {"number":902,"state":"OPEN","closedAt":null},
 {"number":903,"state":"OPEN","closedAt":null},
 {"number":904,"state":"OPEN","closedAt":null},
 {"number":905,"state":"OPEN","closedAt":null},
 {"number":906,"state":"OPEN","closedAt":null},
 {"number":911,"state":"OPEN","closedAt":null},
 {"number":14,"state":"OPEN","closedAt":null},
 {"number":887,"state":"OPEN","closedAt":null},
 {"number":907,"state":"OPEN","closedAt":null},
 {"number":908,"state":"CLOSED","closedAt":"$(NOWISO 120)"},
 {"number":909,"state":"OPEN","closedAt":null}
]
JSON
  echo '[{"number":1044,"title":"TK-902: the PR that owns it","headRefName":"ticket/TK-902","body":""},{"number":1045,"title":"TK-2416.0: spec(TK-2416.0): the plan this build was executed from","headRefName":"ticket/TK-2416.0","body":""}]' > "$H/fixture/prs.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-900-1","ticket_id":"TK-900","kind":"build","status":"running","updated_at":"$(NOWISO 600)","meta":"{\"ticket_id\":\"900\"}"},
 {"id":"build-project-5-TK-989-0","ticket_id":"TK-989","kind":"build","status":"failed","updated_at":"$(NOWISO 9000)","meta":"{\"ticket_id\":\"989\"}"}
]}
JSON
  printf '{"queue":[{"project":"project-5","ticket_key":"TK-901","ticket_id":"901","status":"queued","target":"fly","attempt":0,"claimed_by":null,"enqueued_at":"%s"}]}\n' "$(NOWISO 300)" > "$H/fixture/queuerows.json"
}

reset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/alerts-called.log" "$H/gh-calls.log" "$H/fixture"/issue-*.json
  scratch_rm "$H/fixture/ledger-cursor"
  CLRST
  open_board
}
run() { "$H/bin/orphan-reconcile.sh" "$P" "${1:---explain}" 2>/dev/null; }
summary() { grep -o 'reconcile: .*' "$H/logs/$P.log" | tail -1; }
launched() { sort -u "$H/launches.log" 2>/dev/null; }
nlaunch() { cat "$H/launches.log" 2>/dev/null | grep -c . || true; }

# ---------- 0. every GitHub read is REST, never GraphQL (BH-1163) -----------
# `gh issue list`, `gh issue view` and `gh pr list` speak GraphQL and draw on
# the 5000/h bucket the WHOLE hub shares — the bucket that emptied on
# 2026-09-18 (#768) and made the dependency gate read silence as fact. This
# reconciler runs on every tick of every GitHub-Issues project, which makes it
# one of the hottest readers in the fleet. The marker line opts the file into
# tests/gh-no-graphql-decision-guard-test.sh; these two assertions are what
# prove the marker is not a lie.
reset
run >/dev/null
grep -qx '# gh-rest: no-graphql' "$DIR/bin/orphan-reconcile.sh" && ok \
  || bad "bin/orphan-reconcile.sh must carry the exact '# gh-rest: no-graphql' marker line"
grep -qE '(^| )(pr|issue) (list|view)( |$)' "$H/gh-calls.log" \
  && bad "no GraphQL reader may survive: $(grep -E '(^| )(pr|issue) (list|view)( |$)' "$H/gh-calls.log" | head -3)" || ok
grep -q 'repos/example-org/project-5/issues' "$H/gh-calls.log" && ok \
  || bad "the board must be read as GET repos/<slug>/issues: $(head -5 "$H/gh-calls.log")"
grep -q 'labels=ai-build' "$H/gh-calls.log" && ok \
  || bad "the open list must be scoped with labels=ai-build: $(head -5 "$H/gh-calls.log")"
grep -q 'repos/example-org/project-5/pulls' "$H/gh-calls.log" && ok \
  || bad "the PR list must be read as GET repos/<slug>/pulls: $(head -5 "$H/gh-calls.log")"

# ---------- 1. the whole owner rule in one run ------------------------------
reset
OUT=$(run)
verdict() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT"; }
grep -q '^TK-900	900	OWNED	ledger:' <<<"$OUT" && ok || bad "(a) a RUNNING ledger job must own its ticket: $(verdict TK-900)"
grep -q '^TK-901	901	OWNED	ledger:queue row queued' <<<"$OUT" && ok || bad "(a) a QUEUED queue row must own its ticket: $(verdict TK-901)"
grep -q '^TK-902	902	OWNED	pr:#1044 is open' <<<"$OUT" && ok || bad "(b) an open PR carrying the key must own the ticket: $(verdict TK-902)"
grep -q '^TK-911	911	OWNED	pr:#1045 is open (title key TK-2416.0)' <<<"$OUT" && ok \
  || bad "(b) an open PR carrying the issue's OWN child key must own it even when its number differs (the 2026-09-19 #2566/#2579 loop): $(verdict TK-911)"
grep -q '^TK-903	903	OWNED	blocker:#904 still open' <<<"$OUT" && ok || bad "(c) an open Blocked-by parent must own the child: $(verdict TK-903)"
grep -q '^TK-905	905	OWNED	children:#906 open (decompose parent)' <<<"$OUT" && ok || bad "(c) a decompose parent with open children is owned BY them: $(verdict TK-905)"
grep -q '^TK-14	14	OWNED	hold:title' <<<"$OUT" && ok || bad "(d) HOLD in the title must own the ticket (project-5 #14): $(verdict TK-14)"
grep -q '^TK-887	887	OWNED	hold:comment' <<<"$OUT" && ok || bad "(d) a HOLD comment from the operator must own the ticket (#887): $(verdict TK-887)"
grep -q '^TK-907	907	OWNED	grace:blocker #908 closed 2m ago' <<<"$OUT" && ok || bad "(e) a blocker that closed inside the window is a grace hold: $(verdict TK-907)"
grep -q '^TK-909	909	OWNED	grace:the thread itself moved' <<<"$OUT" && ok || bad "(e) a thread that just moved is a grace hold — the event path gets first claim: $(verdict TK-909)"
# …and the three tickets the incident actually lost
for K in TK-671 TK-721 TK-989; do
  grep -q "^$K	.*	ORPHAN	no owner" <<<"$OUT" && ok || bad "$K must read ORPHAN (the 2026-09-15 incident): $(verdict $K)"
done
grep -q '^TK-904	904	ORPHAN' <<<"$OUT" && ok || bad "the open sibling itself is launchable: $(verdict TK-904)"
grep -q '^TK-906	906	ORPHAN' <<<"$OUT" && ok || bad "a decompose CHILD with no live blocker is launchable: $(verdict TK-906)"

# ---------- 2. an orphan is enqueued through the box's own launch ------------
# 5 orphans (671, 721, 904, 906, 989) and the cap is 5, so all five go.
[ "$(nlaunch)" = 5 ] && ok || bad "five orphans must be launched, got $(nlaunch): $(launched)"
grep -qx "project-5 671 TK-671" <<<"$(launched)" && ok || bad "the launch must be run-build.sh <project> <issue> <KEY>: $(launched)"
grep -q 'reconcile: open=15 owned=10 orphans=5 enqueued=' "$H/logs/$P.log" && ok || bad "the one-line summary must carry the counts: $(summary)"
grep -q 'enqueued=TK-671,TK-721,TK-904,TK-906,TK-989' "$H/logs/$P.log" && ok || bad "the summary must name the keys: $(summary)"
# the alert fires ONLY on an enqueue, and names the keys and the why
grep -q 'orphan-reconcile/project-5' "$H/alerts-called.log" && ok || bad "an enqueue must lane-alert: $(cat "$H/alerts-called.log" 2>/dev/null)"
grep -q 'TK-671 (no owner); TK-721 (no owner)' "$H/alerts-called.log" && ok || bad "the alert must name each key and why it was orphaned: $(cat "$H/alerts-called.log")"

# ---------- 3. idempotent: a second run one minute later enqueues nothing ----
# The marker this run wrote is itself an owner-end, so the grace class holds
# every key it just launched even before the ledger row lands.
: > "$H/launches.log"; : > "$H/alerts-called.log"
OUT2=$(run)
[ "$(nlaunch)" = 0 ] && ok || bad "a second run must enqueue nothing, got: $(launched)"
grep -q '^TK-671	671	OWNED	grace:' <<<"$OUT2" && ok || bad "the enqueue marker must read as a grace hold: $(awk -F'\t' '$1=="TK-671"' <<<"$OUT2")"
[ ! -s "$H/alerts-called.log" ] && ok || bad "a run that enqueues nothing must not alert: $(cat "$H/alerts-called.log")"
grep -q 'orphans=0 enqueued=- skipped=-' "$H/logs/$P.log" && ok || bad "a quiet run still logs its one line: $(summary)"

# ---------- 4. the cap -------------------------------------------------------
reset
ORPHAN_MAX_PER_RUN=2 run >/dev/null
[ "$(nlaunch)" = 2 ] && ok || bad "ORPHAN_MAX_PER_RUN=2 must launch two, got $(nlaunch): $(launched)"
grep -q 'orphans=5 enqueued=TK-671,TK-721 skipped=TK-904:cap,TK-906:cap,TK-989:cap' "$H/logs/$P.log" \
  && ok || bad "the capped keys must be logged with their reason: $(summary)"

# ---------- 4b. no cap by default (the operator, unlimited concurrency, 2026-10-11) --
# With ORPHAN_MAX_PER_RUN unset, every ownerless ticket launches in one run.
# The old default of 5 left the rest named `:cap` for the next tick: 34 such
# skips in 24 h on 2026-10-11, with up to 35 orphans in one run.
reset
python3 - "$H/fixture/open.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for n in (951, 952, 953, 954):
    d.append({"number": n, "title": "TK-%d plain orphan" % n, "body": "## Scope", "comments": [],
              "updatedAt": d[2]["updatedAt"]})
json.dump(d, open(p, "w"))
PY
( unset ORPHAN_MAX_PER_RUN; run >/dev/null )
[ "$(nlaunch)" = 9 ] && ok || bad "4b: with no ORPHAN_MAX_PER_RUN all 9 orphans must launch in one run, got $(nlaunch): $(launched)"
grep -q ':cap' <<<"$(summary)" && bad "4b: a run with no cap named a key :cap: $(summary)" || ok
# 4c: a value that is not a whole number is no cap AND one log line that says so.
reset
python3 - "$H/fixture/open.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for n in (951, 952, 953, 954):
    d.append({"number": n, "title": "TK-%d plain orphan" % n, "body": "## Scope", "comments": [],
              "updatedAt": d[2]["updatedAt"]})
json.dump(d, open(p, "w"))
PY
ORPHAN_MAX_PER_RUN=-3 run >/dev/null
[ "$(nlaunch)" = 9 ] && ok || bad "4c: ORPHAN_MAX_PER_RUN=-3 must launch all 9, got $(nlaunch)"
grep -q "ORPHAN_MAX_PER_RUN='-3' is not a whole number; no launch cap" "$H/logs/$P.log" && ok \
  || bad "4c: a bad ORPHAN_MAX_PER_RUN is not logged: $(grep -i 'max_per_run' "$H/logs/$P.log")"

# ---------- 5. the build-key flock is a hard refusal ------------------------
# locks/ is DEDUPE (CLAUDE.md): a held key is already building on this box,
# whatever the ledger says about it.
reset
python3 - "$H/locks/build-key-$P-TK-671.lock" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(30)
PY
LPID=$!
sleep 1
run >/dev/null
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
grep -qx "project-5 671 TK-671" <<<"$(launched)" && bad "a key whose build-key lock is HELD must never be enqueued: $(launched)" || ok
grep -q 'skipped=TK-671:build-key-lock-held' "$H/logs/$P.log" && ok || bad "the lock refusal must be logged: $(summary)"

# ---------- 6. a finished build awaiting its close-out owns the ticket ------
# RESULT with no COMMENTED = the results sweep owns it. Re-launching would
# rebuild a ticket whose PLAN_BLOCKED questions nobody has answered yet.
reset
mkdir -p "$H/builds/$P-TK-989-202609151200"
echo "PLAN_BLOCKED how does the rep set the fee?" > "$H/builds/$P-TK-989-202609151200/RESULT"
run >/dev/null
grep -qx "project-5 989 TK-989" <<<"$(launched)" && bad "an un-swept RESULT dir must hold the ticket: $(launched)" || ok
grep -q 'skipped=TK-989:awaiting-closeout' "$H/logs/$P.log" && ok || bad "the close-out refusal must be logged: $(summary)"
grep -q 'closeout-overdue' "$H/alerts-called.log" 2>/dev/null && bad "a fresh un-swept RESULT must not raise closeout-overdue: $(cat "$H/alerts-called.log")" || ok
# BH-3953: the same skip past CLOSEOUT_OVERDUE_S (45m) is one pipeline-health warn naming key and dir.
touch -d "@$(( $(date +%s) - 3000 ))" "$H/builds/$P-TK-989-202609151200/RESULT"
scratch_rm "$H/state/orphan-reconcile"; rm -f "$H/alerts-called.log"
run >/dev/null
[ "$(grep -c 'closeout-overdue:project-5:TK-989' "$H/alerts-called.log" 2>/dev/null)" = 1 ] && ok \
  || bad "a 50m awaiting-closeout skip must lane-alert once: $(cat "$H/alerts-called.log" 2>/dev/null)"
grep -q -- '--severity warn pipeline-health project-5 TK-989 has waited 50m .*project-5-TK-989-202609151200' "$H/alerts-called.log" 2>/dev/null && ok \
  || bad "the overdue warn must name the key and its dir: $(cat "$H/alerts-called.log" 2>/dev/null)"
# …and once the sweep has commented, the ticket is launchable again
touch "$H/builds/$P-TK-989-202609151200/COMMENTED"
scratch_rm "$H/state/orphan-reconcile"; : > "$H/launches.log"
run >/dev/null
grep -qx "project-5 989 TK-989" <<<"$(launched)" && ok || bad "a COMMENTED dir must stop holding the ticket: $(launched)"

# ---------- 7. a blocker the ai-build list does not carry reads OPEN --------
# The de-labelled decompose parent (project-5 #667/#668 are OPEN and
# unlabelled). Missing from the list used to read as CLOSED, which releases a
# child under a live parent; an unreadable one must read OPEN too.
reset
python3 - "$H/fixture/open.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.append({"number":669,"title":"TK-669 child of a de-labelled parent",
          "body":"## Scope\nBlocked-by: #667","comments":[],"updatedAt":"2026-01-01T00:00:00Z"})
json.dump(d, open(p,"w"))
PY
echo '{"number":667,"state":"OPEN","closedAt":null}' > "$H/fixture/issue-667.json"
OUT7=$(ORPHAN_MAX_PER_RUN=0 run)
grep -q '^TK-669	669	OWNED	blocker:#667 still open' <<<"$OUT7" && ok || bad "a de-labelled OPEN parent must read OPEN: $(awk -F'\t' '$1=="TK-669"' <<<"$OUT7")"
grep -q 'repos/example-org/project-5/issues/667' "$H/gh-calls.log" && ok || bad "the missing blocker must be fetched by number over REST: $(cat "$H/gh-calls.log")"
# unreadable (the shim exits 1 with no fixture) -> OPEN, the fail-closed way
reset
python3 - "$H/fixture/open.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.append({"number":669,"title":"TK-669 child","body":"## Scope\nBlocked-by: #4242","comments":[],"updatedAt":"2026-01-01T00:00:00Z"})
json.dump(d, open(p,"w"))
PY
OUT7B=$(ORPHAN_MAX_PER_RUN=0 run)
grep -q '^TK-669	669	OWNED	blocker:#4242 still open' <<<"$OUT7B" && ok || bad "a blocker whose state cannot be read must read OPEN: $(awk -F'\t' '$1=="TK-669"' <<<"$OUT7B")"

# ---------- 8. it fails CLOSED, never open ----------------------------------
# "We cannot name these tickets' owners" and "these tickets have no owner" are
# different sentences, and only one of them may launch a build.
reset
CURL_MODE=down run >/dev/null
[ "$(nlaunch)" = 0 ] && ok || bad "a ledger outage must enqueue nothing: $(launched)"
grep -q 'reconcile: jobs ledger unreachable' "$H/logs/$P.log" && ok || bad "…and must say so: $(tail -1 "$H/logs/$P.log")"
reset
GH_FAIL=1 run >/dev/null
[ "$(nlaunch)" = 0 ] && ok || bad "a dead gh token must enqueue nothing: $(launched)"
grep -q 'the open ai-build list unverifiable (HTTP 500' "$H/logs/$P.log" && ok \
  || bad "a dead token is rc 75, and the line must name the status: $(tail -2 "$H/logs/$P.log")"

# ---------- 8a. 44 and 75 are different sentences (BH-1163) -----------------
# The #768 incident was a rate-limited read whose EMPTY answer was acted on as
# "no such thing". These two runs prove the reconciler can still tell "GitHub
# says this board is not there" from "GitHub did not answer", and that neither
# one spends a launch.
reset
SETST open 429
run >/dev/null
[ "$(nlaunch)" = 0 ] && ok || bad "a rate-limited board read must enqueue nothing: $(launched)"
grep -q 'the open ai-build list unverifiable (HTTP 429 rate-limit)' "$H/logs/$P.log" && ok \
  || bad "rc 75 must be logged as unverifiable, with the status and the reason: $(tail -2 "$H/logs/$P.log")"
grep -q 'gh-rest: orphan-reconcile' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "rc 75 must leave one gh_rest_alert line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
reset
SETST open 404
run >/dev/null
[ "$(nlaunch)" = 0 ] && ok || bad "a 404 board read must enqueue nothing either: $(launched)"
grep -q 'the open ai-build list answered HTTP 404' "$H/logs/$P.log" && ok \
  || bad "rc 44 must be logged as ABSENT, not as unverifiable: $(tail -2 "$H/logs/$P.log")"
grep -q 'the open ai-build list unverifiable' "$H/logs/$P.log" \
  && bad "a 404 must NOT be reported as unverifiable — that is the #768 conflation: $(tail -2 "$H/logs/$P.log")" || ok
# …and the same distinction one level down, on a single issue's thread: the
# ticket whose thread could not be read is parked, and the board keeps moving.
reset
SETST comments 429
OUT8A=$(run)
grep -q '^TK-887	887	OWNED	unverifiable:thread' <<<"$OUT8A" && ok \
  || bad "an unreadable thread must park its own ticket, not launch it: $(awk -F'\t' '$1=="TK-887"' <<<"$OUT8A")"
grep -qx "project-5 887 TK-887" <<<"$(launched)" \
  && bad "a ticket whose thread is unreadable must never be launched: $(launched)" || ok
grep -qx "project-5 671 TK-671" <<<"$(launched)" && ok \
  || bad "…and one bad thread must not stop the rest of the board: $(launched)"
grep -q 'the thread read for #887 unverifiable (HTTP 429' "$H/logs/$P.log" && ok \
  || bad "the declined thread read must be logged with its status: $(grep 'thread read' "$H/logs/$P.log")"

# ---------- 8d. a PR returned by GET /issues is not a ticket ----------------
# `gh issue list` never returned pull requests; GET /repos/{slug}/issues does.
# An unfiltered reconciler would read its own PRs as tickets with no owner and
# launch a build for each one.
reset
python3 - "$H/fixture/open.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.append({"number":1044,"title":"TK-902: the PR that owns it","body":"","comments":[],
          "updatedAt":"2026-01-01T00:00:00Z",
          "pull_request":{"url":"https://api.github.com/repos/example-org/project-5/pulls/1044"}})
json.dump(d, open(p,"w"))
PY2
OUT8D=$(ORPHAN_MAX_PER_RUN=0 run)
grep -q '^TK-1044	' <<<"$OUT8D" && bad "a pull request must never be classified as a ticket: $(grep '^TK-1044' <<<"$OUT8D")" || ok

# ---------- 8b. low GitHub API budget skips non-essential reads -------------
# When core remaining is below the threshold, the reconciler exits cleanly
# before issuing any gh issue list or gh pr list calls, and logs one line.
reset
GH_BUDGET_CORE_REMAINING=100 run >/dev/null
[ $? -eq 0 ] && ok || bad "low budget must exit 0"
[ "$(nlaunch)" = 0 ] && ok || bad "low budget must enqueue nothing: $(launched)"
! grep -qE "/issues|/pulls" "$H/gh-calls.log" && ok   || bad "low budget must not read the issue or PR lists: $(cat "$H/gh-calls.log")"
[ "$(grep -c "budget low" "$H/logs/orphan-reconcile.log")" = 1 ] && ok   || bad "low budget must log exactly one budget-low line: $(cat "$H/logs/orphan-reconcile.log" 2>/dev/null)"

# ---------- 8c. healthy GitHub API budget reads normally -------------------
# When core remaining is healthy, the reconciler lists issues/PRs exactly as
# before and enqueues the same orphans.
reset
GH_BUDGET_CORE_REMAINING=4000 run >/dev/null
[ "$(nlaunch)" = 5 ] && ok || bad "healthy budget must still enqueue five orphans: $(launched)"
grep -q "/issues" "$H/gh-calls.log" && grep -q "/pulls" "$H/gh-calls.log" && ok   || bad "healthy budget must read the issue and PR lists: $(cat "$H/gh-calls.log")"

# ---------- 9. the switches ------------------------------------------------
reset
ORPHAN_RECONCILE=0 run >/dev/null
[ "$(nlaunch)" = 0 ] && [ ! -s "$H/logs/$P.log" ] && ok || bad "ORPHAN_RECONCILE=0 must be a silent no-op: $(launched) $(cat "$H/logs/$P.log" 2>/dev/null)"
reset
touch "$H/flags/orphan-reconcile-off"
run >/dev/null
[ "$(nlaunch)" = 0 ] && [ ! -s "$H/logs/$P.log" ] && ok || bad "flags/orphan-reconcile-off must be a silent no-op: $(launched)"
rm -f "$H/flags/orphan-reconcile-off"
# a wider grace window swallows the orphans whole
reset
ORPHAN_GRACE_MIN=1000 run >/dev/null
[ "$(nlaunch)" = 0 ] && ok || bad "ORPHAN_GRACE_MIN=1000 must hold every ticket: $(launched)"

# ---------- 10. an in-app board project is not this script's business -------
reset
"$H/bin/orphan-reconcile.sh" project-3 >/dev/null 2>&1
[ "$(nlaunch)" = 0 ] && [ ! -s "$H/logs/project-3.log" ] && ok \
  || bad "an in-app board project must be an immediate no-op: $(launched)"

# ---------- 10b. the PR side of the same rule is hooked in ------------------
# Owner class (b) above reads an OPEN PR as proof a ticket is owned, so an
# ABANDONED PR holds its ticket hostage for ever (example-org/project-7 #323-#327,
# open since June). bin/pr-owner-sweep.sh answers the PR half; this asserts the
# reconciler actually rings it, detached and scoped to its own repo.
reset
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/sweep-called.log"\n' > "$H/bin/pr-owner-sweep.sh"
chmod +x "$H/bin/pr-owner-sweep.sh"
rm -f "$H/sweep-called.log"
run >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$H/sweep-called.log" ] && break; sleep 0.2; done
grep -q -- '--repo example-org/project-5' "$H/sweep-called.log" 2>/dev/null && ok \
  || bad "the reconciler must sweep its own repo's PR owners: $(cat "$H/sweep-called.log" 2>/dev/null)"
# and both of the sweep's switches stop the hook at the source
reset
rm -f "$H/sweep-called.log"
PR_OWNER_SWEEP=0 run >/dev/null
sleep 0.5
[ ! -s "$H/sweep-called.log" ] && ok || bad "PR_OWNER_SWEEP=0 must stop the hook: $(cat "$H/sweep-called.log")"
reset
rm -f "$H/sweep-called.log"
touch "$H/flags/pr-owner-sweep-off"
run >/dev/null
sleep 0.5
[ ! -s "$H/sweep-called.log" ] && ok || bad "flags/pr-owner-sweep-off must stop the hook: $(cat "$H/sweep-called.log")"
rm -f "$H/flags/pr-owner-sweep-off" "$H/bin/pr-owner-sweep.sh"

# ---------- 11. the tick runs it BEFORE the gate can skip ------------------
# The gate SKIP is the exact path that hid the orphans, so the hook has to sit
# in front of it. Driven against the REAL bin/run-triage.sh.
mkdir -p "$T/rt/bin/lib" "$T/rt/logs" "$T/rt/state" "$T/rt/locks" "$T/rt/env" \
         "$T/rt/flags" "$T/rt/prompts" "$T/rt/builds" "$T/repos"
: > "$T/rt/env/global.env"
echo "SOP for $P." > "$T/rt/prompts/$P.md"
sed -e "s|/root/harness|$T/rt|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$T/rt/bin/run-triage.sh"
chmod +x "$T/rt/bin/run-triage.sh"
mkdir -p "$T/rt/bin/lib/rt"; for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$T/rt|g" -e "s|/root/repos|$T/repos|g" "$s" > "$T/rt/bin/lib/rt/$(basename "$s")"; done
ln -sf "$DIR/bin/fleet-conf.sh" "$T/rt/bin/fleet-conf.sh"
printf '#!/bin/sh\necho "SKIP no-change (103 tickets)"\n' > "$T/rt/bin/triage-gate.sh"
printf '#!/bin/bash\necho "$*" >> "%s/rt/recon-called.log"\n' "$T" > "$T/rt/bin/orphan-reconcile.sh"
chmod +x "$T/rt/bin/triage-gate.sh" "$T/rt/bin/orphan-reconcile.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/rt/bin/beat.sh"; chmod +x "$T/rt/bin/beat.sh"
printf '#!/bin/sh\ntouch "%s/rt/AGENT-RAN"\nexit 0\n' "$T" > "$T/rt/bin/agent-call.sh"
chmod +x "$T/rt/bin/agent-call.sh"
HARNESS="$T/rt" "$T/rt/bin/run-triage.sh" "$P" >/dev/null 2>&1
grep -qx "$P" "$T/rt/recon-called.log" 2>/dev/null && ok \
  || bad "a tick the gate SKIPs must still have run the reconciler: $(cat "$T/rt/recon-called.log" 2>/dev/null)"
grep -q 'rc=skip :: gate no-change' "$T/rt/logs/$P.log" && ok \
  || bad "…and the gate's SKIP must still be honoured afterwards: $(tail -1 "$T/rt/logs/$P.log")"
[ ! -f "$T/rt/AGENT-RAN" ] && ok || bad "the hook must not buy a session on a SKIP tick"
# and the env knob reaches the tick's own hook
rm -f "$T/rt/recon-called.log"
HARNESS="$T/rt" ORPHAN_RECONCILE=0 "$T/rt/bin/run-triage.sh" "$P" >/dev/null 2>&1
[ ! -f "$T/rt/recon-called.log" ] && ok || bad "ORPHAN_RECONCILE=0 must stop the tick calling it at all"

# ---------- 12. the HOLD is read by RECENCY, not for ever (BH-408) ----------
# Owner class (d) used to hold a ticket on any HOLD ever written, so a ticket
# the operator later said RESUME on stayed parked with nothing in the harness able to
# un-park it. The newest DECISIVE human comment wins in both directions, and the
# lift vocabulary is the one bin/lib/hold.sh exports to bin/blocked-resolver.sh —
# the same strings, so the two lanes cannot drift.
#
# Its own three-issue board, so section 1's counts (open=14 owned=9 orphans=5)
# stay exactly where they are.
reset
cat > "$H/fixture/open.json" <<JSON
[
 {"number":950,"title":"TK-950 held and then released","body":"## Scope","comments":[
   {"body":"HOLD — the operator: not yet, the client has not answered."},
   {"body":"RESUME — answered, go ahead."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":951,"title":"TK-951 held and told not to resume","body":"## Scope","comments":[
   {"body":"HOLD — the operator: not yet."},
   {"body":"Do NOT RESUME this yet, I want to see the numbers first."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":952,"title":"TK-952 released and then held again","body":"## Scope","comments":[
   {"body":"RESUME — go ahead."},
   {"body":"HOLD — stop, this conflicts with the pricing work."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":953,"title":"TK-953 held, and the harness commented after","body":"## Scope","comments":[
   {"body":"HOLD — the operator: do not build this until the operator lifts the hold."},
   {"body":"We rebuilt this ticket fresh against current main and opened a PR."}],"updatedAt":"$(NOWISO 7200)"}
]
JSON
cat > "$H/fixture/states.json" <<JSON
[
 {"number":950,"state":"OPEN","closedAt":null},
 {"number":951,"state":"OPEN","closedAt":null},
 {"number":952,"state":"OPEN","closedAt":null},
 {"number":953,"state":"OPEN","closedAt":null}
]
JSON
echo '[]' > "$H/fixture/prs.json"
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
echo '{"queue":[]}' > "$H/fixture/queuerows.json"
OUT12=$(run)
verdict12() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT12"; }
grep -q '^TK-950	950	ORPHAN' <<<"$OUT12" && ok \
  || bad "a RESUME newer than the HOLD must release the ticket: $(verdict12 TK-950)"
grep -qx "project-5 950 TK-950" <<<"$(launched)" && ok \
  || bad "…and the released ticket must actually be launched: $(launched)"
grep -q '^TK-951	951	OWNED	hold:comment' <<<"$OUT12" && ok \
  || bad "'Do NOT RESUME this yet' is not a lift: $(verdict12 TK-951)"
grep -q '^TK-952	952	OWNED	hold:comment' <<<"$OUT12" && ok \
  || bad "a HOLD newer than the RESUME still holds: $(verdict12 TK-952)"
grep -q '^TK-953	953	OWNED	hold:comment' <<<"$OUT12" && ok \
  || bad "a neutral harness comment after a HOLD must not lift it: $(verdict12 TK-953)"
grep -qx "project-5 951 TK-951" <<<"$(launched)" && bad "a held ticket must never be launched: $(launched)" || ok
grep -qx "project-5 952 TK-952" <<<"$(launched)" && bad "a re-held ticket must never be launched: $(launched)" || ok
grep -qx "project-5 953 TK-953" <<<"$(launched)" && bad "a ticket whose HOLD stands must never be launched: $(launched)" || ok
# A BOX MID-SYNC BEHAVES EXACTLY AS IT DID. Without bin/lib/hold.sh there is no
# lift vocabulary at all, so every HOLD holds — today's behaviour, and the safe
# direction for a half-rsynced box.
mv "$H/bin/lib/hold.sh" "$T/hold.sh.away"
: > "$H/launches.log"
OUT12B=$(run)
grep -q '^TK-950	950	OWNED	hold:comment' <<<"$OUT12B" && ok \
  || bad "with no bin/lib/hold.sh, a HOLD must still hold (today's behaviour): $(awk -F'\t' '$1=="TK-950"' <<<"$OUT12B")"
[ "$(nlaunch)" = 0 ] && ok || bad "an unsynced box must launch nothing here: $(launched)"
mv "$T/hold.sh.away" "$H/bin/lib/hold.sh"

# ---------- 13. (b2) only the LEADING title key is the issue's own -----------
# PR #954 review: a title that merely MENTIONS another ticket's key must not be
# parked by that ticket's open PR, and the full-key match must normalise leading
# zeros on both sides like keynum_re does. Its own board, so section 1's counts
# stay where they are.
reset
cat > "$H/fixture/open.json" <<JSON
[
 {"number":912,"title":"TK-912: rework after TK-902","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"},
 {"number":913,"title":"TK-2416.0: zero-padded head still owns it","body":"## Scope","comments":[],"updatedAt":"$(NOWISO 7200)"}
]
JSON
cat > "$H/fixture/states.json" <<JSON
[
 {"number":912,"state":"OPEN","closedAt":null},
 {"number":913,"state":"OPEN","closedAt":null}
]
JSON
echo '[{"number":1044,"title":"TK-902: the PR that owns it","headRefName":"ticket/TK-902","body":""},{"number":1046,"title":"the child build","headRefName":"ticket/TK-02416.0","body":""}]' > "$H/fixture/prs.json"
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
echo '{"queue":[]}' > "$H/fixture/queuerows.json"
OUT13=$(run)
verdict13() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT13"; }
grep -q '^TK-912	912	ORPHAN' <<<"$OUT13" && ok \
  || bad "(b2) a key mentioned later in the title is not the issue's own; #912 must stay ORPHAN while PR 1044 is open: $(verdict13 TK-912)"
grep -qx "project-5 912 TK-912" <<<"$(launched)" && ok \
  || bad "…and the orphan must actually be launched: $(launched)"
grep -q '^TK-913	913	OWNED	pr:#1046 is open (title key TK-2416.0)' <<<"$OUT13" && ok \
  || bad "(b2) a zero-padded head branch (ticket/TK-02416.0) must still meet the title key TK-2416.0: $(verdict13 TK-913)"

# ---------- 14. a thread read that stopped short is never read as the thread -
# (PR #1167 review.) There are two ways the thread pass 2 judges can be
# INCOMPLETE, and on a board that is simply quiet they look exactly the same:
#
#   14a  ORPHAN_THREAD_FETCH_MAX bound pass 1, so the thread was never asked
#        for. The ticket is parked `unverifiable:thread` — the fail-closed
#        direction — but until now nothing said the CAP was the reason, so a
#        board with more commented orphans than the cap parked its tail on
#        every tick and read, in the log, like a board with nothing to do.
#   14b  the thread is LONGER than the row cap, which trims OLDEST-first, so
#        the missing comments are the NEWEST ones — the decisive end of the
#        BH-408 walk, where a HOLD written today lives. Read as "nobody held
#        it", that spends a build on a ticket the operator stopped.
#
# Both must park the ticket AND say so in the log.
reset
cat > "$H/fixture/open.json" <<JSON
[
 {"number":960,"title":"TK-960 first commented orphan","body":"## Scope","comments":[{"body":"Noted, carrying on."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":961,"title":"TK-961 second commented orphan","body":"## Scope","comments":[{"body":"Noted, carrying on."}],"updatedAt":"$(NOWISO 7200)"},
 {"number":962,"title":"TK-962 past the thread cap","body":"## Scope","comments":[{"body":"Noted, carrying on."}],"updatedAt":"$(NOWISO 7200)"}
]
JSON
cat > "$H/fixture/states.json" <<JSON
[
 {"number":960,"state":"OPEN","closedAt":null},
 {"number":961,"state":"OPEN","closedAt":null},
 {"number":962,"state":"OPEN","closedAt":null}
]
JSON
echo '[]' > "$H/fixture/prs.json"
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
echo '{"queue":[]}' > "$H/fixture/queuerows.json"
OUT14=$(ORPHAN_THREAD_FETCH_MAX=2 run)
verdict14() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT14"; }
grep -q '^TK-960	960	ORPHAN' <<<"$OUT14" && ok \
  || bad "14a: a thread inside the cap is read and its orphan launched: $(verdict14 TK-960)"
grep -q '^TK-962	962	OWNED	unverifiable:thread' <<<"$OUT14" && ok \
  || bad "14a: a ticket past ORPHAN_THREAD_FETCH_MAX must be parked, never launched: $(verdict14 TK-962)"
grep -qx "project-5 962 TK-962" <<<"$(launched)" && bad "14a: a capped ticket must never be launched: $(launched)" || ok
grep -q 'reconcile: ORPHAN_THREAD_FETCH_MAX=2 bound — #962 parked unverifiable:thread' "$H/logs/$P.log" && ok \
  || bad "14a: the cap must name itself and the tickets it parked: $(grep -o 'reconcile: .*' "$H/logs/$P.log" | tr '\n' '|')"
grep -q 'reconcile: parked unread — TK-962(unverifiable:thread)' "$H/logs/$P.log" && ok \
  || bad "14a: a verdict reached on an answer nobody has must be named in the tick's log: $(grep -o 'reconcile: .*' "$H/logs/$P.log" | tr '\n' '|')"
# …and the cap line is silent on a board that is inside it.
reset
run >/dev/null
grep -q 'ORPHAN_THREAD_FETCH_MAX' "$H/logs/$P.log" && bad "14a: an uncapped run must not log the cap: $(summary)" || ok
grep -q 'parked unread' "$H/logs/$P.log" && bad "14a: a run with nothing unread must not log one: $(summary)" || ok

# 14b: 201 comments, the NEWEST of them a HOLD. gh_rest_issue_comments caps at
# 200 rows oldest-first, so the HOLD is exactly the comment that falls off.
reset
jq -nc --arg now "$(NOWISO 7200)" \
  '[{number:963, title:"TK-963 a thread longer than the row cap", body:"## Scope",
     comments: ([range(0;200) | {body:"progress note"}]
                + [{body:"HOLD — the operator: stop, this is the newest word in the thread."}]),
     updatedAt:$now}]' > "$H/fixture/open.json"
echo '[{"number":963,"state":"OPEN","closedAt":null}]' > "$H/fixture/states.json"
echo '[]' > "$H/fixture/prs.json"
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
echo '{"queue":[]}' > "$H/fixture/queuerows.json"
OUT14B=$(run)
grep -q '^TK-963	963	OWNED	unverifiable:thread-truncated' <<<"$OUT14B" && ok \
  || bad "14b: a thread read that returned fewer comments than the issue has is not the thread: $(awk -F'\t' '$1=="TK-963"' <<<"$OUT14B")"
grep -qx "project-5 963 TK-963" <<<"$(launched)" && bad \
  "14b: a HOLD past the row cap must never be launched over: $(launched)" || ok
grep -q 'reconcile: parked unread — TK-963(unverifiable:thread-truncated)' "$H/logs/$P.log" && ok \
  || bad "14b: the truncated read must be named in the log: $(grep -o 'reconcile: .*' "$H/logs/$P.log" | tr '\n' '|')"

# ---------- 15. a 131-issue board: every thread is read (BH-8497) -----------
# The project-6 shape (comment 6426367666): 131 open ai-build issues, created
# #1..#131, where the 20 OLDEST-created carry the NEWEST comments. The old
# literal bound (40) parked 91 of them `unverifiable:thread` on every run.
# Every thread here ends in a HOLD, so no run launches anything and every run
# needs every thread again: the worst case for the bound.
#   15a  the default bound (a settings row, fallback 200) fits the board: no
#        ticket parked unverifiable on either of two runs, no cap line, no ALERT
#   15b  a bound of 100 parks 31 on run 1 and writes ONE ALERT with the count;
#        run 2 starts past the cursor, so none of run 1's parked tickets is
#        parked again, and the ALERT is not repeated the same day
board131() {
  jq -nc --arg old "$(NOWISO 7200)" --arg new "$(NOWISO 60)" '[range(131; 0; -1) as $n
    | {number: $n, title: "TK-\($n) old project-6 ticket", body: "## Scope",
       comments: [{body: "HOLD — the operator: wait for the drain."}],
       updatedAt: (if $n <= 20 then $new else $old end)}]' > "$H/fixture/open.json"
  jq -nc '[range(1; 132) as $n | {number: $n, state: "OPEN", closedAt: null}]' > "$H/fixture/states.json"
  echo '[]' > "$H/fixture/prs.json"
  echo '{"jobs":[]}' > "$H/fixture/jobs.json"
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
}
nunv() { awk -F'\t' '$4 ~ /^unverifiable:/' <<<"$1" | grep -c . || true; }
nhold() { awk -F'\t' '$3=="OWNED" && $4 ~ /^hold:/' <<<"$1" | grep -c . || true; }
reset; board131; rm -f "$H/flags/alerted-orphan-thread-cap-"*
OUT15A1=$(run); OUT15A2=$(run)
[ "$(grep -c . <<<"$OUT15A1")" = 131 ] && [ "$(nunv "$OUT15A1")" = 0 ] && [ "$(nunv "$OUT15A2")" = 0 ] && ok \
  || bad "15a: the default bound reads all 131 threads on both runs: run1 $(nunv "$OUT15A1") unverifiable, run2 $(nunv "$OUT15A2")"
[ "$(nhold "$OUT15A2")" = 131 ] && ok || bad "15a: every thread was read, so every HOLD holds: $(nhold "$OUT15A2") of 131"
for n in 1 20; do
  grep -q "^TK-$n	$n	OWNED	hold:" <<<"$OUT15A2" && ok || bad "15a: an old ticket with the newest comment (#$n) is read: $(awk -F'\t' -v n="$n" '$2==n' <<<"$OUT15A2")"
done
grep -q 'ORPHAN_THREAD_FETCH_MAX' "$H/logs/$P.log" && bad "15a: a board inside the default bound logs no cap: $(summary)" || ok
grep -q 'orphan-thread-cap' "$H/alerts-called.log" 2>/dev/null && bad "15a: no ALERT inside the bound: $(cat "$H/alerts-called.log")" || ok
[ "$(nlaunch)" = 0 ] && ok || bad "15a: a held board launches nothing: $(launched)"

reset; board131; rm -f "$H/flags/alerted-orphan-thread-cap-"*
OUT15B1=$(ORPHAN_THREAD_FETCH_MAX=100 run)
P1=$(awk -F'\t' '$4 ~ /^unverifiable:thread/ {print $2}' <<<"$OUT15B1" | sort -n | tr '\n' ' ')
[ "$P1" = "$(seq 101 131 | tr '\n' ' ')" ] && ok || bad "15b: run 1 reads #1..#100 and parks #101..#131: [$P1]"
grep -q 'reconcile: ORPHAN_THREAD_FETCH_MAX=100 bound — .*; next run starts past #100' "$H/logs/$P.log" && ok \
  || bad "15b: the cap line names the cursor: $(grep -o 'reconcile: ORPHAN.*' "$H/logs/$P.log")"
[ "$(grep -c 'orphan-thread-cap' "$H/alerts-called.log" 2>/dev/null)" = 1 ] && grep 'orphan-thread-cap' "$H/alerts-called.log" | grep -q 'cut 31 comment-thread read' && ok \
  || bad "15b: one ALERT names the 31 cut: $(cat "$H/alerts-called.log" 2>/dev/null)"
OUT15B2=$(ORPHAN_THREAD_FETCH_MAX=100 run)
P2=$(awk -F'\t' '$4 ~ /^unverifiable:thread/ {print $2}' <<<"$OUT15B2" | sort -n | tr '\n' ' ')
[ "$P2" = "$(seq 70 100 | tr '\n' ' ')" ] && ok || bad "15b: run 2 reads #101..#131 then #1..#69, and parks #70..#100: [$P2]"
BOTH=$(comm -12 <(tr ' ' '\n' <<<"$P1" | grep . | sort) <(tr ' ' '\n' <<<"$P2" | grep . | sort) | tr '\n' ' ')
[ -z "$BOTH" ] && ok || bad "15b: no ticket is parked unverifiable on two runs in a row: [$BOTH]"
[ "$(grep -c 'orphan-thread-cap' "$H/alerts-called.log" 2>/dev/null)" = 1 ] && ok \
  || bad "15b: the ALERT is not repeated the same day: $(cat "$H/alerts-called.log" 2>/dev/null)"
# The cursor is a `ledgers` row, never a state/ file (BH-4159).
CURF=$(ls "$H"/fixture/ledger-cursor/*orphan.json 2>/dev/null | head -1)
[ -n "$CURF" ] && [ "$(jq -r '.status + " " + .detail' "$CURF")" = "at 69" ] && ok \
  || bad "15b: the cursor is the ledger row orphan-thread-cursor (at 69, run 2 read up to #69): $(cat "$H"/fixture/ledger-cursor/* 2>/dev/null)"
ls "$H"/state/orphan-reconcile/*/thread-cursor* >/dev/null 2>&1 && bad "15b: no thread-cursor state file: $(ls "$H"/state/orphan-reconcile/*/)" || ok
# A run inside the bound resets the cursor, so the next capped run starts at #1.
OUT15B3=$(run)
[ "$(nunv "$OUT15B3")" = 0 ] && [ "$(jq -r '.detail' "$CURF" 2>/dev/null)" = 0 ] && ok \
  || bad "15b: an uncut run resets the cursor row to 0: $(cat "$CURF" 2>/dev/null)"

echo "orphan-reconcile: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
