#!/bin/bash
# tests/launch-fastpath-test.sh — bin/launch-fastpath.sh: the fast path launches
# a ticket ONLY when every one of the 19 conditions holds, and names exactly one
# reason when it does not.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a DECISION that costs
# money in one direction and an hour in the other: a build spawned on a ticket
# somebody is holding, or a ticket that sits because a read failed and the script
# guessed. `grep -q hold_re` would pass on a version that declines nothing.
# So the real script runs against a scratch $HARNESS with PATH shims for gh and
# curl (no network, no secrets), run-build.sh and dep-verify.sh as recorders, and
# every assertion reads an ARTIFACT — launches.log, logs/<project>.log, the
# marker file, state/wake-keys-<project> — never the script's source text. The
# one exception is T1.32, and it is named as one: the blocker/HOLD/PR regex block
# is a verbatim COPY of bin/orphan-reconcile.sh's, docs/verification-map pins the
# diff of the two ranges as "must be empty", and a drift check that lives only in
# a doc is a check nobody runs.
#
# The model recorders are the fast path's whole point: it decides without an LLM,
# so a non-empty model-called.log fails the section that produced it.
# Run from anywhere: bash tests/launch-fastpath-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; scratch_rm() { case "${1:-}" in "$T"/*) rm -rf "$T/${1#"$T"/}" ;; esac; }; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }

NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
cp "$DIR/bin/launch-fastpath.sh" "$H/bin/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# BH-1194: bin/jobs-client.sh is a SHIM over bin/lib/jobs/ — a scratch harness
# that copies the client without the modules gets a refusal, not a client, and
# every launcher hop that shells out to it would decline for the wrong reason.
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/dep-verify-lib.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
# bin/lib/hold.sh is the fleet's ONE definition of what a hold is (BH-408);
# bin/lib/lock-hygiene.sh is how every spawn site drops the lane's lock fds.
# Both are copied in so the sections below drive the real libs, and T1.4/nolib
# moves hold.sh aside to pin the no-lib fallback.
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/lock-hygiene.sh" "$H/bin/lib/"
# The REST contract itself (BH-1163). Copied, never stubbed: the rc 0/44/75
# mapping every read below is decided on IS this file's, and a stub would test
# the stub. bin/lib/gh-rest-etag.sh is deliberately NOT copied — there is no
# cache state in this suite, the same choice tests/orphan-reconcile-test.sh
# makes — so every read here is a fresh one.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"

# The registry fixture: one GitHub-Issues project (board_prefix "-") and one
# in-app board project, which is the never-fast-path negative.
cat > "$H/fleet.conf" <<'CONF'
project-5 example-org/project-5 https://project-5.example - 9 box-ts 10.0.0.13
project-3 example-org/project-3 https://project-3.example /api/feature-board 3 box-project-3 100.0.0.8
CONF
export FLEET_CONF="$H/fleet.conf"

# The key prefix is READ FROM THE PROMPT (bin/lib/preplan-lib.sh:
# preplan_key_prefix) and the launch argv is compared against the same line
# (T1.14), so this is the real SOP line, not a stub.
SOP='  `setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > /root/harness/logs/project-5.ts-<issue-number>-build.out 2>&1 &`'
printf '%s\n' "$SOP" > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# run-build.sh: the launch, recorded — with the marker's state AT SPAWN TIME,
# because "the marker is written BEFORE the spawn" is a claim only the child can
# prove (the reconciler's grace class depends on that order).
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s marker=%s\n' "$*" "$([ -f "$HARNESS/state/orphan-reconcile/project-5/${3:-}.enqueued" ] && echo 1 || echo 0)" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"

# dep-verify.sh: answers $DEP_VERDICT and records whether the child body file it
# was handed is actually readable.
cat > "$H/bin/dep-verify.sh" <<'SH'
#!/bin/bash
printf '%s body=%s\n' "$*" "$([ -r "${DEP_CHILD_BODY_FILE:-/nonexistent}" ] && echo 1 || echo 0)" >> "$HARNESS/dep-calls.log"
echo "${DEP_VERDICT:-UNKNOWN} shim says so"
SH
chmod +x "$H/bin/dep-verify.sh"

# The two ways an LLM could be bought. Either one firing is a bug in the fast path.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'agent-call %s\n' "$*" >> "$HARNESS/model-called.log"
SH
chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/claude" <<'SH'
#!/bin/bash
printf 'claude %s\n' "$*" >> "$HARNESS/model-called.log"
SH
chmod +x "$T/fakebin/claude"

# gh shim — a REST endpoint, not the CLI (BH-1163). Every read this script makes
# now goes through bin/lib/gh-rest.sh, which calls `gh api -i -X GET <path> …`,
# so this answers with a status LINE, a blank line and a body: that is what the
# library parses, and what makes the rc 0/44/75 the assertions below turn on real
# here rather than mocked. Every call is recorded twice — a per-section log the
# sections reset, and a cumulative one for the never-writes and no-GraphQL
# assertions at the end.
#
# THE FIXTURES STAY IN THE READABLE SHAPE `mkissue` writes and are translated to
# the wire shape here: `comments` is a list in the fixture and a COUNT on the
# wire with its own endpoint, `headRefName`/`isDraft` are `head.ref`/`draft`,
# and states are lowercase. The script under test only ever sees the wire shape,
# so the assertions are about REST and not about the fixture's convenience.
#
# INJECTING A STATUS: `SETST <route> <code>` writes $HARNESS/st-<route>, and the
# route names are pulls / all / issue / issue-<n> / comments / comments-<n> —
# the per-number ones so a BLOCKER read can fail while the key's own issue read
# succeeds. `$HARNESS/trim-comments` serves fewer bodies than the issue's own
# comment count, which is the row cap trimming the NEWEST comments away.
# GH_FAIL=1 is the dead token: the repo PROBE (a bare `gh api repos/<slug>`,
# no -i) fails, which is condition 4, and every REST read behind it would 500.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
printf '%s\n' "$*" >> "$HARNESS/gh-all.log"
ST()   { local f; for f in "$@"; do [ -f "$HARNESS/st-$f" ] && { cat "$HARNESS/st-$f"; return; }; done; echo 200; }
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
# GitHub's OWN wording on the two statuses that can mean a limit — the library
# only sniffs the reason out of the body, so an error body that says nothing
# would test a 429 the library cannot classify.
ERRB() { case "$1" in 403|429) echo '{"message":"API rate limit exceeded for installation."}' ;;
                      404) echo '{"message":"Not Found"}' ;;
                      *) echo '{"message":"no"}' ;; esac; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
if [ "${GH_FAIL:-}" = 1 ]; then
  case "$ARGS" in
    *"api -i"*) SEND 500 '{"message":"bad credentials"}' ;;
    *)          echo "gh: HTTP 401" >&2; exit 1 ;;
  esac
fi
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
    s=$(ST "comments-$n" comments)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    t=$(cat "$HARNESS/trim-comments" 2>/dev/null || echo 200)
    SEND 200 "$(jq -c --argjson t "$t" '[ (.comments // [])[] ] | .[:$t]' \
                 "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    s=$(ST "issue-$n" issue)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    # A fixture that is not JSON is served AS THE BODY under a 200: that is the
    # 2xx-nobody-can-act-on case (T1.15), and it is a different answer from an
    # absent issue, which is the 404 above.
    b=$(jq -c '{number, state:(.state|ascii_downcase), title, body, labels,
                comments:((.comments // [])|length), created_at:.createdAt}' \
          "$HARNESS/fixture/issue-$n.json" 2>/dev/null) \
      || b=$(cat "$HARNESS/fixture/issue-$n.json")
    SEND 200 "$b" ;;
  *"/issues"*)
    s=$(ST all)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    [ -f "$HARNESS/fixture/states.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '[ .[] | {number, state:(.state|ascii_downcase)} ]' \
                 "$HARNESS/fixture/states.json")" ;;
  *"/pulls"*)
    s=$(ST pulls)
    case "$s" in 2*) ;; *) SEND "$s" "$(ERRB "$s")" ;; esac
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    [ -f "$HARNESS/fixture/prs.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, head:{ref:.headRefName}, draft:.isDraft} ]' \
                 "$HARNESS/fixture/prs.json")" ;;
  *"api repos/"*)  echo 12345 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
SETST() { printf '%s' "$2" > "$H/st-$1"; }   # SETST <pulls|all|issue[-n]|comments[-n]> <code>

# curl shim for jobs-client: the two ledger reads answer from fixtures.
# CURL_MODE=down is the outage the script must fail CLOSED on.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in
  */api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  */api/queue*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/queuerows.json")" ;;
  # TEST-CHANGE BH-4153: paused-* is now a harness_flags row read DB-first; the
  # catch-all 200 {"ok":true} is an unreadable flag answer, which fails closed as
  # "project paused". No row exists in this fixture, so answer 404 (= off).
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"

# setsid: a passthrough, so the SOP launch line runs the recorder above.
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"
chmod +x "$T/fakebin/setsid"
# grep: a passthrough, EXCEPT under FP_TEST_CONSUME=1, where the one call the
# script makes with `-vixE` (the wake-keys read) also deletes the file the moment
# it has been read. That is bin/lib/rt/scope.sh's one-shot consume landing in the
# window between the read and the rewrite — the race T1.29 pins, made
# deterministic instead of hoped for.
GREP_REAL=$(command -v grep)
cat > "$T/fakebin/grep" <<SH
#!/bin/bash
if [ "\${FP_TEST_CONSUME:-}" = 1 ] && [ "\${1:-}" = "-vixE" ]; then
  out=\$($GREP_REAL "\$@"); rc=\$?
  rm -f "\$3"
  [ -n "\$out" ] && printf '%s\\n' "\$out"
  exit "\$rc"
fi
exec $GREP_REAL "\$@"
SH
chmod +x "$T/fakebin/grep"

export PATH="$T/fakebin:$PATH"

# --- fixtures ----------------------------------------------------------------
BODY_OK=$'## Scope\nBuild the thing.\n\n## Acceptance tests\n- it works\n'
LAB_AI='[{"name":"ai-build"}]'

mkissue() { # mkissue <n> <state> <labels-json> <title> <body> <comments-json>
  jq -n --argjson n "$1" --arg st "$2" --argjson lb "$3" --arg t "$4" --arg b "$5" \
        --argjson c "$6" --arg ca "$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')" \
    '{number:$n,state:$st,title:$t,body:$b,labels:$lb,comments:$c,createdAt:$ca}' \
    > "$H/fixture/issue-$1.json"
}
qrow() { # qrow <key> <id> <status>
  jq -nc --arg k "$1" --arg i "$2" --arg s "$3" \
     --arg at "$(date -u -d "@$((NOW - 300))" '+%Y-%m-%dT%H:%M:%SZ')" \
     '{queue:[{project:"project-5",ticket_key:$k,ticket_id:$i,status:$s,target:"fly",
               attempt:0,claimed_by:null,enqueued_at:$at,reason:null,meta:null}]}' \
     > "$H/fixture/queuerows.json"
}
jrow() { # jrow <ticket_id> <status>
  jq -nc --arg t "$1" --arg s "$2" \
     --arg at "$(date -u -d "@$((NOW - 300))" '+%Y-%m-%dT%H:%M:%SZ')" \
     '{jobs:[{id:"build-project-5-1",ticket_id:$t,kind:"build",status:$s,updated_at:$at,meta:null}]}' \
     > "$H/fixture/jobs.json"
}

seed() {
  echo '{"jobs":[]}'  > "$H/fixture/jobs.json"
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
  echo '[]'           > "$H/fixture/prs.json"
  echo '[]'           > "$H/fixture/states.json"
  mkissue 900 OPEN "$LAB_AI" "TK-900 the clean one" "$BODY_OK" '[]'
}

reset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/gh-calls.log" "$H/dep-calls.log" "$H/flags"/* "$H/fixture"/issue-*.json
  rm -f "$H"/st-* "$H/trim-comments"
  seed
}

run() { OUT=$("$H/bin/launch-fastpath.sh" "$@" 2>/dev/null); RC=$?; }
reason() { # reason <key-as-given> [project]
  grep -F "FASTPATH-DECLINED $1 ::" "$H/logs/${2:-$P}.log" 2>/dev/null | tail -1 | sed 's/.*:: //'
}
nlaunch() { [ -f "$H/launches.log" ] && grep -c . "$H/launches.log" || echo 0; }
marker() { echo "$H/state/orphan-reconcile/$P/$1.enqueued"; }
nomodel() { [ ! -s "$H/model-called.log" ] || bad "$1: the fast path bought an LLM call: $(cat "$H/model-called.log")"; }
starts() { case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac; }
# An rc 75 read owes ONE ALERTS line and an rc 44 owes none — "GitHub says no
# such thing" is a fact this lane acts on, and "GitHub did not answer" is an
# outage somebody has to see.
alerts() { local n; n=$(grep -c 'gh-rest: launch-fastpath' "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
ghcalls() { local n; n=$(grep -cE "$1" "$H/gh-calls.log" 2>/dev/null); echo "${n:-0}"; }

# ---------- T1.2 the ai-build label ------------------------------------------
reset
mkissue 901 OPEN '[]' "TK-901 unlabelled" "$BODY_OK" '[]'
run "$P" 901
[ "$RC" = 1 ] && ok || bad "T1.2: a declined key must exit 1, got rc=$RC"
[ "$OUT" = 901 ] && ok || bad "T1.2: the declined key must be on stdout, got '$OUT'"
[ "$(reason 901)" = "no ai-build label" ] && ok || bad "T1.2: reason was '$(reason 901)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.2: nothing may launch: $(cat "$H/launches.log" 2>/dev/null)"
nomodel T1.2

# ---------- T1.3 the body headings -------------------------------------------
reset
mkissue 902 OPEN "$LAB_AI" "TK-902 half a body" $'## Scope\nonly the scope\n' '[]'
mkissue 903 OPEN "$LAB_AI" "TK-903 prose" $'The Scope is broad and the Acceptance tests are obvious.\n' '[]'
mkissue 900 OPEN "$LAB_AI" "TK-900 h3 headings" $'### Scope\nx\n\n### Acceptance tests\n- y\n' '[]'
run "$P" 902 903 900
[ "$(reason 902)" = "body lacks ## Scope / ## Acceptance tests" ] && ok || bad "T1.3: missing Acceptance tests must decline, got '$(reason 902)'"
[ "$(reason 903)" = "body lacks ## Scope / ## Acceptance tests" ] && ok || bad "T1.3: prose is not a heading, got '$(reason 903)'"
grep -q 'project-5 900 TK-900' "$H/launches.log" 2>/dev/null && ok || bad "T1.3: h3 headings must pass condition 11: $(cat "$H/launches.log" 2>/dev/null)"
nomodel T1.3

# ---------- T1.4 HOLD ---------------------------------------------------------
reset
mkissue 904 OPEN "$LAB_AI" "TK-904 held in a comment" "$BODY_OK" '[{"body":"HOLD: not yet"}]'
mkissue 905 OPEN "$LAB_AI" "TK-905 the thing (HOLD)" "$BODY_OK" '[]'
mkissue 906 OPEN "$LAB_AI" "TK-906 prose about a hold" "$BODY_OK" '[{"body":"until the operator lifts the hold we keep the copy"}]'
mkissue 917 OPEN "$LAB_AI" "TK-917 held in the body" \
  $'## Scope\nHOLD — the client has not answered the fee question.\n\n## Acceptance tests\n- x\n' '[]'
run "$P" 904 905 906 917
[ "$(reason 904)" = "HOLD in comment" ] && ok || bad "T1.4: HOLD in a comment, got '$(reason 904)'"
[ "$(reason 905)" = "HOLD in title" ] && ok || bad "T1.4: HOLD in the title, got '$(reason 905)'"
[ "$(reason 917)" = "HOLD in body" ] && ok || bad "T1.4: HOLD in the body, got '$(reason 917)'"
grep -q 'project-5 906 TK-906' "$H/launches.log" 2>/dev/null && ok || bad "T1.4: lowercase 'hold' in prose must NOT decline: $(reason 906)"
# and the thread it read that from is its OWN endpoint (BH-1163): the issue
# payload carries a comment COUNT, never the bodies.
grep -q 'repos/example-org/project-5/issues/904/comments' "$H/gh-calls.log" 2>/dev/null && ok \
  || bad "T1.4: the thread must be read as GET /issues/904/comments: $(cat "$H/gh-calls.log" 2>/dev/null)"
nomodel T1.4

# ---------- T1.4c a BODY holds only on an explicit HOLD line (BH-1461) --------
# The incident this lane shares with the pool and the reconciler: a ticket BODY
# is where this harness documents itself, so the capital word appears in it as a
# NOUN constantly — BH-1419's "a per-project HOLD row for hub lanes" — and the
# word regex declined every such ticket on every tick. The body arm reads
# HOLD_BODY_RE now: a line that BEGINS with `HOLD`, `HOLD:` or `HOLD —` is the
# instruction, and a mid-line mention is prose. The TITLE still takes the whole
# word (T1.4's 905), because a title never documents a mechanism.
reset
mkissue 923 OPEN "$LAB_AI" "TK-923 prose about a hold row" \
  $'## Scope\n1. A per-project HOLD row for hub lanes.\n\n## Acceptance tests\n- x\n' '[]'
mkissue 924 OPEN "$LAB_AI" "TK-924 an explicit hold line" \
  $'## Scope\nHOLD: waiting on the client\n\n## Acceptance tests\n- x\n' '[]'
run "$P" 923 924
grep -q 'project-5 923 TK-923' "$H/launches.log" 2>/dev/null && ok \
  || bad "T1.4c: a prose HOLD mid-line must NOT decline: $(reason 923)"
[ "$(reason 924)" = "HOLD in body" ] && ok \
  || bad "T1.4c: a HOLD: line must decline, got '$(reason 924)'"
nomodel T1.4c

# ---------- T1.4b the newest human comment wins (BH-408) ----------------------
# The hold vocabulary is bin/lib/hold.sh's three exported regexes, the same
# reading bin/orphan-reconcile.sh and bin/blocked-resolver.sh use. A ticket the operator
# later said RESUME on must get this lane back; anything short of the explicit
# lift vocabulary must not give it back. Driven on the real script with the real
# lib, and asserted on launches.log and the decline reason.
reset
mkissue 918 OPEN "$LAB_AI" "TK-918 held then lifted" "$BODY_OK" \
  '[{"body":"HOLD: waiting on the client"},{"body":"RESUME — client answered"}]'
mkissue 919 OPEN "$LAB_AI" "TK-919 lift behind a negation" "$BODY_OK" \
  '[{"body":"HOLD: waiting on the client"},{"body":"Do NOT RESUME this yet"}]'
mkissue 920 OPEN "$LAB_AI" "TK-920 lifted then held again" "$BODY_OK" \
  '[{"body":"RESUME — go ahead"},{"body":"HOLD: new information"}]'
mkissue 921 OPEN "$LAB_AI" "TK-921 neutral after a hold" "$BODY_OK" \
  '[{"body":"HOLD: waiting on the client"},{"body":"we rebuilt this ticket fresh"}]'
mkissue 922 OPEN "$LAB_AI" "TK-922 lowercase resume is prose" "$BODY_OK" \
  '[{"body":"HOLD: waiting on the client"},{"body":"the resume lane will pick it up"}]'
run "$P" 918 919 920 921 922
grep -q 'project-5 918 TK-918' "$H/launches.log" 2>/dev/null && ok || bad "T1.4b: a newer RESUME must lift the hold: $(reason 918)"
[ "$(reason 919)" = "HOLD in comment" ] && ok || bad "T1.4b: 'Do NOT RESUME this yet' is not a lift, got '$(reason 919)'"
[ "$(reason 920)" = "HOLD in comment" ] && ok || bad "T1.4b: a newer HOLD overrides an older RESUME, got '$(reason 920)'"
[ "$(reason 921)" = "HOLD in comment" ] && ok || bad "T1.4b: a neutral comment must not lift a hold, got '$(reason 921)'"
[ "$(reason 922)" = "HOLD in comment" ] && ok || bad "T1.4b: lowercase 'resume' is harness prose, not a lift, got '$(reason 922)'"
nomodel T1.4b
# BH-3435: a comment OPENING with a lift word lifts, even when it carries the
# capital HOLD (project-5 #3354's exact words); our own ambiguity note, which
# names RESUME, never lifts.
reset
mkissue 925 OPEN "$LAB_AI" "TK-925 released with HOLD in the sentence" "$BODY_OK" \
  '[{"body":"HOLD: waiting on #3348"},{"body":"RELEASED (the operator, 2026-09-28). Proceed on the decision in #3348 … This supersedes the HOLD."}]'
mkissue 926 OPEN "$LAB_AI" "TK-926 our own note after a hold" "$BODY_OK" \
  '[{"body":"HOLD: waiting"},{"body":"start a comment with RESUME, RELEASE, RELEASED, UNHOLD or PROCEED\n<!-- harness:hold-ambiguous 1 -->"}]'
run "$P" 925 926
grep -q 'project-5 925 TK-925' "$H/launches.log" 2>/dev/null && ok || bad "T1.4d: the #3354 comment must lift the hold: $(reason 925)"
[ "$(reason 926)" = "HOLD in comment" ] && ok || bad "T1.4d: our ambiguity note must not lift, got '$(reason 926)'"
nomodel T1.4d
# BH-6091: a comment OPENING with `HOLD:` holds even when it names RESUME
# (#5962's two exact shapes); a lead RESUME that names the HOLD still lifts.
reset
mkissue 927 OPEN "$LAB_AI" "TK-927 HOLD that names the RESUME above" "$BODY_OK" \
  '[{"body":"RESUME — go ahead"},{"body":"HOLD: the lead reversed the RESUME above (the two messages crossed)."}]'
mkissue 928 OPEN "$LAB_AI" "TK-928 HOLD until RESUME" "$BODY_OK" \
  '[{"body":"RESUME — go ahead"},{"body":"HOLD: a Mac agent owns the branch. Please make no pool push until the PR is open and RESUME is posted."}]'
mkissue 929 OPEN "$LAB_AI" "TK-929 RESUME that names the HOLD" "$BODY_OK" \
  '[{"body":"HOLD: waiting"},{"body":"RESUME: the pool is building; the HOLD above is withdrawn"}]'
# a bare HOLD line, then text naming RESUME (#6091's real HOLD comments, review of 82abecc2)
mkissue 930 OPEN "$LAB_AI" "TK-930 bare HOLD line" "$BODY_OK" \
  '[{"body":"RESUME — go ahead"},{"body":"HOLD\n\nA Mac agent is fixing the lead BLOCK. A RESUME follows when the fix is pushed.\n"}]'
run "$P" 927 928 929 930
[ "$(reason 927)" = "HOLD in comment" ] && ok || bad "T1.4f: an opening HOLD naming RESUME must hold, got '$(reason 927)'"
[ "$(reason 928)" = "HOLD in comment" ] && ok || bad "T1.4f: 'HOLD: … until … RESUME' must hold, got '$(reason 928)'"
grep -q 'project-5 929 TK-929' "$H/launches.log" 2>/dev/null && ok || bad "T1.4f: an opening RESUME naming the HOLD must lift: $(reason 929)"
[ "$(reason 930)" = "HOLD in comment" ] && ok || bad "T1.4f: a bare HOLD line over text naming RESUME must hold, got '$(reason 930)'"
nomodel T1.4f
# and the box mid-sync without the lib: NO lift vocabulary, so it behaves exactly
# as this script did before it read bin/lib/hold.sh — every hold is permanent.
reset
mv "$H/bin/lib/hold.sh" "$T/hold-away.sh"
mkissue 918 OPEN "$LAB_AI" "TK-918 held then lifted" "$BODY_OK" \
  '[{"body":"HOLD: waiting on the client"},{"body":"RESUME — client answered"}]'
run "$P" 918
[ "$(reason 918)" = "HOLD in comment" ] && ok || bad "T1.4b/nolib: without bin/lib/hold.sh nothing lifts, got '$(reason 918)'"
mv "$T/hold-away.sh" "$H/bin/lib/hold.sh"
nomodel T1.4b/nolib

# ---------- T1.5 blockers -----------------------------------------------------
BLOCKED=$'## Scope\nBlocked-by: #331\n\n## Acceptance tests\n- it works\n'
for V in HARD UNKNOWN SOFT; do
  reset
  mkissue 907 OPEN "$LAB_AI" "TK-907 blocked" "$BLOCKED" '[]'
  echo '[{"number":331,"state":"OPEN"}]' > "$H/fixture/states.json"
  DEP_VERDICT=$V run "$P" 907
  case "$V" in
    HARD)
      starts "$(reason 907)" "blocker #331 open (HARD" && ok || bad "T1.5: a HARD blocker must decline, got '$(reason 907)'"
      [ "$(nlaunch)" = 0 ] && ok || bad "T1.5: a HARD blocker must not launch" ;;
    UNKNOWN)
      starts "$(reason 907)" "blocker #331 open (UNKNOWN" && ok || bad "T1.5: UNKNOWN is not SOFT, got '$(reason 907)'" ;;
    SOFT)
      grep -q 'project-5 907 TK-907' "$H/launches.log" 2>/dev/null && ok || bad "T1.5: a SOFT blocker must launch: $(reason 907)"
      grep -q "^$P 907 331 body=1" "$H/dep-calls.log" 2>/dev/null && ok || bad "T1.5: dep-verify.sh gets <p> <child> <blocker> and a readable body file: $(cat "$H/dep-calls.log" 2>/dev/null)" ;;
  esac
  nomodel "T1.5/$V"
done
# a blocker the ai-build list does not carry, whose own view fails, reads OPEN
reset
mkissue 908 OPEN "$LAB_AI" "TK-908 blocked by a de-labelled parent" \
  $'## Scope\nBlocked-by: #667\n\n## Acceptance tests\n- it works\n' '[]'
run "$P" 908
starts "$(reason 908)" "blocker #667 open (" && ok || bad "T1.5: an unreadable blocker must read OPEN, got '$(reason 908)'"
grep -q 'repos/example-org/project-5/issues/667' "$H/gh-calls.log" 2>/dev/null && ok || bad "T1.5: a blocker missing from the list must be fetched by number over REST: $(cat "$H/gh-calls.log" 2>/dev/null)"
grep -q 'fastpath: the blocker read for #667 answered HTTP 404 — read OPEN' "$H/logs/$P.log" 2>/dev/null && ok \
  || bad "T1.5: a blocker that 404s says so and reads OPEN: $(grep fastpath "$H/logs/$P.log" 2>/dev/null)"
[ "$(alerts)" = 0 ] && ok || bad "T1.5: a 404 is a fact, not an outage — no ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
nomodel T1.5/667
# a CLOSED blocker is not a blocker, and costs no dep-verify call
reset
mkissue 907 OPEN "$LAB_AI" "TK-907 blocker closed" "$BLOCKED" '[]'
echo '[{"number":331,"state":"CLOSED"}]' > "$H/fixture/states.json"
run "$P" 907
grep -q 'project-5 907 TK-907' "$H/launches.log" 2>/dev/null && ok || bad "T1.5: a CLOSED blocker must not hold the child: $(reason 907)"
[ ! -s "$H/dep-calls.log" ] && ok || bad "T1.5: a CLOSED blocker must cost no dep-verify call: $(cat "$H/dep-calls.log")"
# and the list it read that state off is the ai-build board, both states
grep -q 'labels=ai-build' "$H/gh-calls.log" 2>/dev/null && ok \
  || bad "T1.5: the state list must be scoped with labels=ai-build: $(cat "$H/gh-calls.log" 2>/dev/null)"
grep -q 'state=all' "$H/gh-calls.log" 2>/dev/null && ok \
  || bad "T1.5: the state list must ask for state=all: $(cat "$H/gh-calls.log" 2>/dev/null)"
nomodel T1.5/closed

# ---------- T1.6 PR ownership -------------------------------------------------
reset
mkissue 909 OPEN "$LAB_AI" "TK-909 has a PR" "$BODY_OK" '[]'
echo '[{"number":77,"headRefName":"ticket/TK-909","title":"x","body":"","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 909
[ "$(reason 909)" = "open PR #77" ] && ok || bad "T1.6: an open PR on the key owns the ticket, got '$(reason 909)'"
nomodel T1.6/head
reset
mkissue 909 OPEN "$LAB_AI" "TK-909 merely listed" "$BODY_OK" '[]'
echo '[{"number":78,"headRefName":"ticket/TK-901","title":"other work","body":"reading list: #909, #910","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 909
grep -q 'project-5 909 TK-909' "$H/launches.log" 2>/dev/null && ok || bad "T1.6: a body that merely LISTS #909 is not an owner: $(reason 909)"
nomodel T1.6/list
reset
mkissue 909 OPEN "$LAB_AI" "TK-909 closed by a PR" "$BODY_OK" '[]'
echo '[{"number":79,"headRefName":"ticket/TK-901","title":"other work","body":"Closes #909","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 909
[ "$(reason 909)" = "open PR #79" ] && ok || bad "T1.6: a closing keyword in the body owns the ticket, got '$(reason 909)'"
nomodel T1.6/closes
reset
mkissue 909 OPEN "$LAB_AI" "TK-909 draft PR" "$BODY_OK" '[]'
echo '[{"number":80,"headRefName":"ticket/TK-909","title":"x","body":"","isDraft":true}]' > "$H/fixture/prs.json"
run "$P" 909
grep -q 'project-5 909 TK-909' "$H/launches.log" 2>/dev/null && ok || bad "T1.6: a DRAFT PR is not an owner: $(reason 909)"
nomodel T1.6/draft

# ---------- T1.6b a decompose child, owned by its CHILD-KEYED PR --------------
# The 2026-09-19 #2566/#2579 re-launch loop. A decompose child's ISSUE is titled
# with its child key (`TK-2416.0`) and its build's PR head is `ticket/TK-2416.0`
# — the PR never carries the issue NUMBER, and `keynum_re` truncates at the dot,
# so the number map above reads that PR as a claim on the PARENT. Without the
# full-key owner class the fast path launches a second build of a ticket whose
# PR is already open, through the lane with no triage session in it.
reset
mkissue 2566 OPEN "$LAB_AI" "TK-2416.0: child slice of #2416" "$BODY_OK" '[]'
echo '[{"number":90,"headRefName":"ticket/TK-2416.0","title":"TK-2416.0: child slice","body":"Part of #2416","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 2566
[ "$(reason 2566)" = "open PR #90 (title key TK-2416.0)" ] && ok || bad "T1.6b: a child-keyed open PR owns its decompose child, got '$(reason 2566)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.6b: a decompose child with an open PR must not launch: $(cat "$H/launches.log" 2>/dev/null)"
nomodel T1.6b/child
# leading zeros meet on both sides, exactly as keynum_re's do
reset
mkissue 2566 OPEN "$LAB_AI" "TK-2416.0: child slice of #2416" "$BODY_OK" '[]'
echo '[{"number":90,"headRefName":"ticket/TK-02416.0","title":"x","body":"","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 2566
[ "$(reason 2566)" = "open PR #90 (title key TK-2416.0)" ] && ok || bad "T1.6b: ticket/TK-02416.0 and TK-2416.0 must meet, got '$(reason 2566)'"
nomodel T1.6b/zeros
# only the LEADING key is the issue's own name: a key mentioned later in the
# title is somebody else's work and must not park this ticket.
reset
mkissue 910 OPEN "$LAB_AI" "TK-910: follow-up to TK-902.0" "$BODY_OK" '[]'
echo '[{"number":91,"headRefName":"ticket/TK-902.0","title":"TK-902.0: the other work","body":"","isDraft":false}]' > "$H/fixture/prs.json"
run "$P" 910
grep -q 'project-5 910 TK-910' "$H/launches.log" 2>/dev/null && ok || bad "T1.6b: a key named LATER in the title is not this ticket's owner: $(reason 910)"
nomodel T1.6b/leading
# a DRAFT child-keyed PR is somebody's work in progress, exactly as T1.6/draft
reset
mkissue 2566 OPEN "$LAB_AI" "TK-2416.0: child slice of #2416" "$BODY_OK" '[]'
echo '[{"number":92,"headRefName":"ticket/TK-2416.0","title":"x","body":"","isDraft":true}]' > "$H/fixture/prs.json"
run "$P" 2566
grep -q 'project-5 2566 TK-2566' "$H/launches.log" 2>/dev/null && ok || bad "T1.6b: a DRAFT child-keyed PR is not an owner: $(reason 2566)"
nomodel T1.6b/draft

# ---------- T1.7 the ledger ---------------------------------------------------
reset
mkissue 910 OPEN "$LAB_AI" "TK-910 running" "$BODY_OK" '[]'
jrow TK-910 running
run "$P" 910
starts "$(reason 910)" "ledger:" && ok || bad "T1.7: a running jobs row owns the ticket, got '$(reason 910)'"
nomodel T1.7/job
reset
mkissue 911 OPEN "$LAB_AI" "TK-911 claimed" "$BODY_OK" '[]'
qrow TK-911 911 claimed
run "$P" 911
starts "$(reason 911)" "ledger:" && ok || bad "T1.7: a claimed queue row owns the ticket, got '$(reason 911)'"
nomodel T1.7/queue
reset
mkissue 912 OPEN "$LAB_AI" "TK-912 done" "$BODY_OK" '[]'
jrow TK-912 done
run "$P" 912
grep -q 'project-5 912 TK-912' "$H/launches.log" 2>/dev/null && ok || bad "T1.7: a DONE row is not live: $(reason 912)"
nomodel T1.7/done
reset
mkissue 901 OPEN "$LAB_AI" "TK-901 fine" "$BODY_OK" '[]'
# TEST-CHANGE BH-4153: paused-<project> is now a row read DB-first, so with curl
# down and nothing cached the pause is unknown and (by design) declines first as
# "project paused". This case is about the LEDGER outage, so the box carries a
# prior good "not paused" answer, as a box that has read its pause once does.
mkdir -p "$H/state/flags-cache/fleet"
printf '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":1700000000}\n' \
  > "$H/state/flags-cache/fleet/paused-$P"
CURL_MODE=down run "$P" 900 901
[ "$(reason 900)" = "ledger unreachable" ] && [ "$(reason 901)" = "ledger unreachable" ] && ok || bad "T1.7: a ledger outage declines every key, got '$(reason 900)' / '$(reason 901)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.7: a ledger outage must launch nothing"
[ "$RC" = 1 ] && ok || bad "T1.7: a ledger outage exits 1, got rc=$RC"
nomodel T1.7/down

# ---------- T1.8 the build-key lock is TESTED, never taken --------------------
reset
mkissue 913 OPEN "$LAB_AI" "TK-913 already building" "$BODY_OK" '[]'
LK="$H/locks/build-key-$P-TK-913.lock"
: > "$LK"
flock "$LK" "$H/bin/launch-fastpath.sh" "$P" 913 >/dev/null 2>&1
[ "$(reason 913)" = "already building (build-key lock held)" ] && ok || bad "T1.8: a held build-key lock must decline, got '$(reason 913)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.8: a held build-key lock must not launch"
( exec 9>"$LK"; flock -n 9 ) && ok || bad "T1.8: the build-key lock must be left FREE — this script only tests it"
nomodel T1.8

# ---------- T1.9 a prior build record -----------------------------------------
reset
mkissue 914 OPEN "$LAB_AI" "TK-914 built before" "$BODY_OK" '[]'
mkdir -p "$H/builds/$P-TK-914-202609170000"
touch "$H/builds/$P-TK-914-202609170000/RESULT" "$H/builds/$P-TK-914-202609170000/COMMENTED"
run "$P" 914
[ "$(reason 914)" = "prior build record exists — relaunches are triage's call" ] && ok || bad "T1.9: any prior build dir declines, got '$(reason 914)'"
nomodel T1.9/box
reset
mkissue 914 OPEN "$LAB_AI" "TK-914 built on the pool" "$BODY_OK" '[]'
mkdir -p "$H/builds/pool-$P-TK-914-202609170000"
run "$P" 914
[ "$(reason 914)" = "prior build record exists — relaunches are triage's call" ] && ok || bad "T1.9: a pool build dir declines too, got '$(reason 914)'"
nomodel T1.9/pool

# ---------- T1.10 paused ------------------------------------------------------
reset
touch "$H/flags/paused-$P"
run "$P" 900
[ "$(reason 900)" = "project paused" ] && ok || bad "T1.10: a paused project declines, got '$(reason 900)'"
[ ! -s "$H/gh-calls.log" ] && ok || bad "T1.10: a paused project must cost no gh call: $(cat "$H/gh-calls.log" 2>/dev/null)"
[ "$RC" = 1 ] && ok || bad "T1.10: paused exits 1, got rc=$RC"
nomodel T1.10

# ---------- T1.11 the launch, and its idempotence -----------------------------
reset
printf '900\n901\n' > "$H/state/wake-keys-$P"
run "$P" 900
[ "$RC" = 0 ] && ok || bad "T1.11: a launched key exits 0, got rc=$RC (declined: $OUT)"
[ -z "$OUT" ] && ok || bad "T1.11: nothing on stdout when every key launched, got '$OUT'"
[ "$(cat "$H/launches.log" 2>/dev/null)" = "project-5 900 TK-900 marker=1" ] && ok || bad "T1.11: the launch argv (and the marker BEFORE the spawn) was '$(cat "$H/launches.log" 2>/dev/null)'"
[ "$(grep -c 'FASTPATH TK-900 (issue #900) — launched' "$H/logs/$P.log")" = 1 ] && ok || bad "T1.11: exactly one FASTPATH line: $(grep FASTPATH "$H/logs/$P.log")"
[ -f "$(marker TK-900)" ] && ok || bad "T1.11: the reconciler's grace marker must exist after a launch"
[ ! -f "$H/logs/READY-QUEUE.log" ] && ok || bad "T1.11: the fast path writes no READY-QUEUE line"
[ "$(cat "$H/state/wake-keys-$P")" = "901" ] && ok || bad "T1.11: the launched key must leave wake-keys, got '$(cat "$H/state/wake-keys-$P" 2>/dev/null)'"
run "$P" 900
[ "$(reason 900)" = "reconciler enqueued it 0m ago" ] && ok || bad "T1.11: a second run inside the grace window declines, got '$(reason 900)'"
[ "$(nlaunch)" = 1 ] && ok || bad "T1.11: the second run must not launch again: $(cat "$H/launches.log")"
nomodel T1.11

# ---------- T1.12 the kill switch ---------------------------------------------
reset
touch "$H/flags/fastpath-off"
run "$P" 900
[ "$(reason 900)" = "fastpath off" ] && ok || bad "T1.12: flags/fastpath-off declines everything, got '$(reason 900)'"
[ ! -s "$H/gh-calls.log" ] && ok || bad "T1.12: the kill switch must cost no gh call"
[ "$RC" = 1 ] && ok || bad "T1.12: the kill switch exits 1, got rc=$RC"
nomodel T1.12

# ---------- T1.13 an in-app board is never fast-pathed ------------------------
reset
run project-3 12
[ "$(reason 12 project-3)" = "not a GitHub-Issues board" ] && ok || bad "T1.13: an in-app board declines, got '$(reason 12 project-3)'"
[ ! -s "$H/gh-calls.log" ] && ok || bad "T1.13: an in-app board must cost no gh call"
nomodel T1.13

# ---------- T1.14 the argv IS the SOP line ------------------------------------
reset
run "$P" 900
SOP_ARGV=$(sed -nE 's/.*run-build\.sh (.*) >.*/\1/p' "$H/prompts/$P.md" | sed 's/<issue-number>/900/g')
GOT_ARGV=$(sed 's/ marker=.*//' "$H/launches.log" 2>/dev/null)
[ "$SOP_ARGV" = "$GOT_ARGV" ] && ok || bad "T1.14: the launch argv must equal the SOP line token for token: '$GOT_ARGV' vs '$SOP_ARGV'"
nomodel T1.14

# ---------- T1.15 unparseable, unreadable, and no args ------------------------
reset
run "$P" ../x
[ "$OUT" = "../x" ] && ok || bad "T1.15: the key is echoed back AS GIVEN, got '$OUT'"
[ "$(reason ../x)" = "unparseable key" ] && ok || bad "T1.15: '../x' is unparseable, got '$(reason ../x)'"
echo 'not json' > "$H/fixture/issue-916.json"
run "$P" 916
[ "$(reason 916)" = "issue unreadable" ] && ok || bad "T1.15: a non-JSON answer is unreadable, got '$(reason 916)'"
reset
"$H/bin/launch-fastpath.sh" >/dev/null 2>&1; NARG=$?
[ "$NARG" = 1 ] && ok || bad "T1.15: no args exits 1, got $NARG"
[ ! -f "$H/logs/$P.log" ] && ok || bad "T1.15: no args logs nothing"
"$H/bin/launch-fastpath.sh" "$P" >/dev/null 2>&1; NARG=$?
[ "$NARG" = 1 ] && ok || bad "T1.15: a project with no keys exits 1, got $NARG"
nomodel T1.15

# ---------- T1.16 no key prefix -----------------------------------------------
reset
mv "$H/prompts/$P.md" "$T/prompt-away.md"
run "$P" 900
[ "$(reason 900)" = "no key prefix" ] && ok || bad "T1.16: no prefix declines, got '$(reason 900)'"
[ ! -s "$H/gh-calls.log" ] && ok || bad "T1.16: no prefix must cost no gh call"
mv "$T/prompt-away.md" "$H/prompts/$P.md"
nomodel T1.16

# ---------- T1.17 a repo no token can see -------------------------------------
reset
GH_FAIL=1 run "$P" 900
[ "$(reason 900)" = "repo invisible to every token" ] && ok || bad "T1.17: an invisible repo declines, got '$(reason 900)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.17: an invisible repo must launch nothing"
nomodel T1.17

# ---------- T1.18 the GitHub budget -------------------------------------------
reset
GH_BUDGET_CORE_REMAINING=100 run "$P" 900
[ "$(reason 900)" = "gh budget low" ] && ok || bad "T1.18: a low budget declines, got '$(reason 900)'"
grep -q '/issues/' "$H/gh-calls.log" 2>/dev/null && bad "T1.18: a low budget must buy no issue read: $(cat "$H/gh-calls.log")" || ok
reset
GH_BUDGET_CORE_REMAINING=4000 run "$P" 900
grep -q 'project-5 900 TK-900' "$H/launches.log" 2>/dev/null && ok || bad "T1.18: a healthy budget must not decline: $(reason 900)"
nomodel T1.18

# ---------- T1.19 no jobs client ----------------------------------------------
reset
mv "$H/bin/jobs-client.sh" "$T/jobs-client-away.sh"
run "$P" 900
[ "$(reason 900)" = "ledger unreachable" ] && ok || bad "T1.19: a missing jobs client fails CLOSED, got '$(reason 900)'"
mv "$T/jobs-client-away.sh" "$H/bin/jobs-client.sh"
nomodel T1.19

# ---------- T1.20 the PR list ---------------------------------------------------
# The run-level read: one failure declines every key on the argv, and the reason
# names WHICH failure it was (BH-1163). A 500 is GitHub not answering — the #768
# silence — and it must never read as a board with no open PRs on it.
reset
SETST pulls 500
run "$P" 900
[ "$(reason 900)" = "pr list unverifiable (HTTP 500)" ] && ok || bad "T1.20: an unverifiable PR list declines and says so, got '$(reason 900)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.20: an unverifiable PR list must launch nothing"
nomodel T1.20
reset
SETST pulls 404
run "$P" 900 901
[ "$(reason 900)" = "pr list absent (HTTP 404)" ] && ok || bad "T1.20: a 404 PR list is a different sentence from a 500, got '$(reason 900)'"
[ "$(reason 901)" = "pr list absent (HTTP 404)" ] && ok || bad "T1.20: the run-level read declines EVERY key, got '$(reason 901)'"
[ "$(alerts)" = 0 ] && ok || bad "T1.20: a 404 owes no ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
nomodel T1.20/404
# and the clean run reads the PR list as REST
reset
run "$P" 900
grep -q 'repos/example-org/project-5/pulls' "$H/gh-calls.log" 2>/dev/null && ok \
  || bad "T1.20: the PR list must be read as GET repos/<slug>/pulls: $(cat "$H/gh-calls.log" 2>/dev/null)"
nomodel T1.20/rest

# ---------- T1.33 the REST reads: 44 and 75 are different answers (BH-1163) ---
# Every read this script makes is a `gh api` through bin/lib/gh-rest.sh now, and
# the whole point of that library is that "GitHub says there is no such thing"
# (rc 44) can never again be read off the same silence as "GitHub did not
# answer" (rc 75) — #768, where a rate-limited read answered an empty string and
# five real PRs were rewritten on the strength of it. Both decline here, because
# this lane declines on anything it is not certain about; what the cases below
# pin is that they decline with DIFFERENT sentences, and that only the unknown
# one wakes somebody up.
reset
SETST issue 429
run "$P" 900
[ "$(reason 900)" = "issue #900 unverifiable (HTTP 429 rate-limit)" ] && ok || bad "T1.33: a rate-limited issue read is unverifiable, got '$(reason 900)'"
[ "$(alerts)" = 1 ] && ok || bad "T1.33: an unverifiable read owes exactly one ALERTS line, got $(alerts)"
grep -q 'gh-rest: launch-fastpath issue #900 HTTP 429' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "T1.33: the alert must name the lane, the read and the status: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: an unverifiable issue read must launch nothing"
nomodel T1.33/429
reset
SETST issue 404
run "$P" 900
[ "$(reason 900)" = "issue #900 absent (HTTP 404)" ] && ok || bad "T1.33: a 404 issue is absent, not unverifiable, got '$(reason 900)'"
[ "$(alerts)" = 0 ] && ok || bad "T1.33: an absent issue owes no ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: an absent issue must launch nothing"
nomodel T1.33/404
# a 2xx body that is not an issue OBJECT is neither: it is an answer nobody can
# act on, and it keeps the reason this script has always named.
reset
echo '[1,2]' > "$H/fixture/issue-900.json"
run "$P" 900
[ "$(reason 900)" = "issue unreadable" ] && ok || bad "T1.33: a 2xx that is not an issue object is unreadable, got '$(reason 900)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: an unreadable issue must launch nothing"
nomodel T1.33/notobject

# the thread: its own read, and its own two failures
reset
mkissue 904 OPEN "$LAB_AI" "TK-904 held in a comment" "$BODY_OK" '[{"body":"HOLD: not yet"}]'
SETST comments 429
run "$P" 904
[ "$(reason 904)" = "thread #904 unverifiable (HTTP 429 rate-limit)" ] && ok || bad "T1.33: a rate-limited thread read declines, got '$(reason 904)'"
[ "$(alerts)" = 1 ] && ok || bad "T1.33: the thread read owes one ALERTS line, got $(alerts)"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: an unread thread must launch nothing — a HOLD could be in it"
nomodel T1.33/thread429
# A READ THAT STOPPED SHORT IS NOT THE THREAD. The row cap trims OLDEST-first,
# so the comments a truncated read is missing are the NEWEST — which is exactly
# where a HOLD written today lives, and where this lane's newest-comment-wins
# walk starts (BH-408).
reset
mkissue 904 OPEN "$LAB_AI" "TK-904 three comments" "$BODY_OK" \
  '[{"body":"one"},{"body":"two"},{"body":"three"}]'
echo 2 > "$H/trim-comments"
run "$P" 904
[ "$(reason 904)" = "thread truncated (2 of 3)" ] && ok || bad "T1.33: fewer bodies than the issue's own count is a decline, got '$(reason 904)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: a truncated thread must launch nothing"
nomodel T1.33/truncated

# the blockers: the per-number read is bash's now, and its failures are LOGGED
# and read OPEN rather than declining the key on their own — the same
# fail-closed direction this script has always taken there.
reset
mkissue 908 OPEN "$LAB_AI" "TK-908 blocked by a de-labelled parent" \
  $'## Scope\nBlocked-by: #667\n\n## Acceptance tests\n- it works\n' '[]'
SETST issue-667 429
run "$P" 908
starts "$(reason 908)" "blocker #667 open (" && ok || bad "T1.33: an unverifiable blocker reads OPEN, got '$(reason 908)'"
grep -q 'fastpath: the blocker read for #667 unverifiable (HTTP 429 rate-limit) — read OPEN' "$H/logs/$P.log" 2>/dev/null && ok \
  || bad "T1.33: the blocker read's own failure must be logged: $(grep fastpath "$H/logs/$P.log" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "T1.33: an unverifiable blocker read owes one ALERTS line, got $(alerts)"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: nothing launches on a blocker nobody could read"
nomodel T1.33/blocker429
# the state list is bought once and its failure makes every blocker "missing",
# which is the same fail-closed direction: missing reads OPEN.
reset
mkissue 907 OPEN "$LAB_AI" "TK-907 blocked" "$BLOCKED" '[]'
echo '[{"number":331,"state":"OPEN"}]' > "$H/fixture/states.json"
SETST all 429
run "$P" 907
starts "$(reason 907)" "blocker #331 open (" && ok || bad "T1.33: an unreadable state list must not close a blocker, got '$(reason 907)'"
grep -q 'fastpath: the ai-build state list unverifiable (HTTP 429 rate-limit) — blockers read OPEN' "$H/logs/$P.log" 2>/dev/null && ok \
  || bad "T1.33: the state list's failure must be logged: $(grep fastpath "$H/logs/$P.log" 2>/dev/null)"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: nothing launches on a state list nobody could read"
nomodel T1.33/states429
# and the per-key blocker read stays capped at BLOCKER_FETCH_MAX
reset
mkissue 923 OPEN "$LAB_AI" "TK-923 three blockers nobody has listed" \
  $'## Scope\nBlocked-by: #661, #662, #663\n\n## Acceptance tests\n- it works\n' '[]'
run "$P" 923
[ "$(ghcalls '/issues/66[123]$')" = 2 ] && ok || bad "T1.33: at most 2 per-number blocker reads per key, got $(ghcalls '/issues/66[123]$')"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: the third blocker reads OPEN, so nothing launches"
nomodel T1.33/fetchmax

# the libs are a HARD requirement: an undefined reader answers 127, which is
# neither 44 nor 75, and a box mid-sync must say so rather than read that as a
# board with nothing on it.
reset
mv "$H/bin/lib/gh-rest-list.sh" "$T/gh-rest-list-away.sh"
run "$P" 900
[ "$(reason 900)" = "gh-rest lib missing" ] && ok || bad "T1.33: a missing gh-rest lib declines every key, got '$(reason 900)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.33: a missing gh-rest lib must launch nothing"
[ "$(ghcalls '/issues/')" = 0 ] && ok || bad "T1.33: a missing gh-rest lib buys no read: $(cat "$H/gh-calls.log" 2>/dev/null)"
mv "$T/gh-rest-list-away.sh" "$H/bin/lib/gh-rest-list.sh"
nomodel T1.33/nolib

# ---------- T1.21 a closed issue ----------------------------------------------
reset
mkissue 915 CLOSED "$LAB_AI" "TK-915 shipped last week" "$BODY_OK" '[]'
run "$P" 915
[ "$(reason 915)" = "issue not open" ] && ok || bad "T1.21: a CLOSED issue declines on state first, got '$(reason 915)'"
nomodel T1.21

# ---------- T1.22 a marker older than the grace window ------------------------
reset
mkdir -p "$H/state/orphan-reconcile/$P"
: > "$(marker TK-900)"
touch -d "@$((NOW - 3600))" "$(marker TK-900)"
run "$P" 900
grep -q 'project-5 900 TK-900' "$H/launches.log" 2>/dev/null && ok || bad "T1.22: a marker past the grace window must not hold the ticket: $(reason 900)"
nomodel T1.22

# ---------- T1.23 the launch lock is DEDUPE -----------------------------------
reset
LLK="$H/locks/launch-fastpath-$P-TK-900.lock"
: > "$LLK"
flock "$LLK" "$H/bin/launch-fastpath.sh" "$P" 900 >/dev/null 2>&1
[ "$(reason 900)" = "racing launch, declined" ] && ok || bad "T1.23: a held launch lock declines instead of waiting, got '$(reason 900)'"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.23: a held launch lock must not launch"
[ ! -f "$(marker TK-900)" ] && ok || bad "T1.23: a declined launch writes no marker"
nomodel T1.23

# ---------- T1.24 the spawn itself fails --------------------------------------
reset
chmod -x "$H/bin/run-build.sh"
run "$P" 900
starts "$(reason 900)" "launch failed (" && ok || bad "T1.24: a failed spawn is never a launch, got '$(reason 900)'"
[ ! -f "$(marker TK-900)" ] && ok || bad "T1.24: a failed spawn leaves no marker behind"
[ "$RC" = 1 ] && ok || bad "T1.24: a failed spawn exits 1, got rc=$RC"
chmod +x "$H/bin/run-build.sh"
nomodel T1.24

# ---------- T1.25 wake-keys, both spellings -----------------------------------
reset
printf 'TK-900\n900\n' > "$H/state/wake-keys-$P"
run "$P" 900
[ ! -f "$H/state/wake-keys-$P" ] && ok || bad "T1.25: an emptied wake-keys file is deleted, got '$(cat "$H/state/wake-keys-$P" 2>/dev/null)'"
nomodel T1.25

# ---------- T1.26 the run cap and the per-key gh bound ------------------------
reset
KEYS=(900)
for N in $(seq 901 950); do KEYS+=("$N"); done
run "$P" "${KEYS[@]}"
[ "$(reason 950)" = "over the 50-key run cap" ] && ok || bad "T1.26: the 51st key is declined with a reason, never dropped, got '$(reason 950)'"
GH900=$(grep -c '\b900\b' "$H/gh-calls.log" 2>/dev/null || true)
[ -n "$GH900" ] && [ "$GH900" -ge 1 ] && [ "$GH900" -le 4 ] && ok || bad "T1.26: between 1 and 4 REST reads for the one key with a fixture, got '$GH900'"
# and the comment-less issue costs exactly ONE of them: the count is in the
# issue payload, so there is nothing to ask the thread endpoint (BH-1163).
[ "$(ghcalls '/issues/900$')" = 1 ] && ok || bad "T1.26: the issue itself is one REST read, got $(ghcalls '/issues/900$')"
[ "$(ghcalls '/issues/900/comments')" = 0 ] && ok || bad "T1.26: an issue with no comments must cost no thread read, got $(ghcalls '/issues/900/comments')"
nomodel T1.26

# ---------- T1.27 the key forms condition 8 accepts ---------------------------
# Every case above passes a bare number. The contract also takes `<PFX>-<n>`,
# case-insensitively and with leading zeros, and all of those have to come out as
# the ONE canonical key the log line and the marker use (T1.11 and T1.14 pin the
# launch argv itself). Asserted on the LAUNCHER's own records, which are written
# before it exits — `launches.log` belongs to the spawned child, which is
# detached by then and may still be on its way.
for K in TK-900 TK-900 TK-0900 0900; do
  reset
  run "$P" "$K"
  [ "$RC" = 0 ] && ok || bad "T1.27: '$K' must launch, got rc=$RC (declined: '$(reason "$K")')"
  [ -z "$OUT" ] && ok || bad "T1.27: '$K' launched, so nothing may be on stdout, got '$OUT'"
  [ "$(grep -c 'FASTPATH TK-900 (issue #900) — launched' "$H/logs/$P.log" 2>/dev/null)" = 1 ] && ok \
    || bad "T1.27: '$K' must log the canonical KEY once: $(grep FASTPATH "$H/logs/$P.log" 2>/dev/null)"
  [ -f "$(marker TK-900)" ] && ok || bad "T1.27: '$K' must write the canonical marker"
  nomodel "T1.27/$K"
done

# ---------- T1.28 two runs deciding the same key at the same moment -----------
# T1.11 proves the SEQUENTIAL second run declines. This is the case the launch
# lock exists for, and the one a check made BEFORE the lock cannot answer: both
# runs read "no marker", the first takes the lock, writes the marker, spawns and
# releases in a few ms, and the second then finds the lock free. Conditions
# 16-18 are read a second time INSIDE the lock, so the loser declines whichever
# side of the lock it arrives on — `racing launch, declined` when it meets the
# lock held, `reconciler enqueued it 0m ago` when it gets the lock after the
# winner released it. Both are true in exactly the state that produced them.
#
# Ten trials, because a race that loses 40% of the time passes once. The
# assertions are the LAUNCHER's: it writes `FASTPATH … launched` only after its
# own spawn returned 0, so two launched lines ARE two spawns — and unlike
# `launches.log` (written by the detached grandchild) that record is complete the
# moment the process we waited for exited.
C_LOG=0; C_DECL=0; C_REASON=0; C_RC=0
for i in $(seq 1 10); do
  reset
  "$H/bin/launch-fastpath.sh" "$P" 900 >/dev/null 2>&1 &
  A=$!
  "$H/bin/launch-fastpath.sh" "$P" 900 >/dev/null 2>&1 &
  B=$!
  wait "$A"; RA=$?
  wait "$B"; RB=$?
  NL=$(grep -c 'FASTPATH TK-900 (issue #900) — launched' "$H/logs/$P.log" 2>/dev/null)
  [ "$NL" = 1 ] || { C_LOG=1; echo "  T1.28 trial $i launched $NL times: $(grep FASTPATH "$H/logs/$P.log" | tr '\n' '|')"; }
  [ "$(grep -c 'FASTPATH-DECLINED 900 ::' "$H/logs/$P.log" 2>/dev/null)" = 1 ] || C_DECL=1
  case "$(reason 900)" in
    "racing launch, declined"|"reconciler enqueued it 0m ago") ;;
    *) C_REASON=1; echo "  T1.28 trial $i loser said: '$(reason 900)'" ;;
  esac
  [ "$RA$RB" = "01" ] || [ "$RA$RB" = "10" ] || { C_RC=1; echo "  T1.28 trial $i rc: $RA/$RB"; }
done
[ "$C_LOG" = 0 ] && ok || bad "T1.28: two concurrent runs must launch the key exactly ONCE"
[ "$C_DECL" = 0 ] && ok || bad "T1.28: the loser must be DECLINED with a reason, never silently dropped"
[ "$C_REASON" = 0 ] && ok || bad "T1.28: the loser's reason must name the race or the marker"
[ "$C_RC" = 0 ] && ok || bad "T1.28: the winner exits 0 and the loser exits 1"
nomodel T1.28

# ---------- T1.29 a wake-keys file consumed under us is not resurrected -------
# bin/lib/rt/scope.sh reads state/wake-keys-<project> and `rm -f`s it, and it
# takes no lock — this script's flock only excludes other copies of itself. So
# the one-shot consume can land between this run's READ of the file and its
# REWRITE, and a rewrite that does not check would recreate a file scope.sh had
# already handed to a tick: "a key that outlived its wake would scope some later
# tick to a ticket nobody rang about" (scope.sh). The grep shim deletes the file
# the moment the rewrite has read it, which is that window exactly.
reset
printf '900\n901\n' > "$H/state/wake-keys-$P"
FP_TEST_CONSUME=1 run "$P" 900
[ ! -e "$H/state/wake-keys-$P" ] && ok || bad "T1.29: a consumed wake-keys file must not be recreated, got '$(cat "$H/state/wake-keys-$P" 2>/dev/null)'"
[ "$(nlaunch)" = 1 ] && ok || bad "T1.29: the launch itself still happens: $(cat "$H/launches.log" 2>/dev/null)"
nomodel T1.29

# ---------- T1.30 ORPHAN_GRACE_MIN=0 must not disable the dedupe --------------
# The knob is the reconciler's grace window, shared on purpose. Tuned eager
# there it used to switch OFF the in-lock marker re-read that IS this lock's
# reason to exist, leaving a lock that only serialises two identical builds.
# The second read is floored, so the marker this run just wrote still holds.
reset
ORPHAN_GRACE_MIN=0 run "$P" 900
[ "$(nlaunch)" = 1 ] && ok || bad "T1.30: the first run must launch: $(cat "$H/launches.log" 2>/dev/null)"
ORPHAN_GRACE_MIN=0 run "$P" 900
[ "$(reason 900)" = "reconciler enqueued it 0m ago" ] && ok || bad "T1.30: ORPHAN_GRACE_MIN=0 must not relaunch a key this box just launched, got '$(reason 900)'"
[ "$(nlaunch)" = 1 ] && ok || bad "T1.30: exactly one launch under ORPHAN_GRACE_MIN=0: $(cat "$H/launches.log" 2>/dev/null)"
nomodel T1.30
# and the concurrent shape of the same thing, ten trials
C_G0=0
for i in $(seq 1 10); do
  reset
  ORPHAN_GRACE_MIN=0 "$H/bin/launch-fastpath.sh" "$P" 900 >/dev/null 2>&1 &
  A=$!
  ORPHAN_GRACE_MIN=0 "$H/bin/launch-fastpath.sh" "$P" 900 >/dev/null 2>&1 &
  B=$!
  wait "$A"; wait "$B"
  NL=$(grep -c 'FASTPATH TK-900 (issue #900) — launched' "$H/logs/$P.log" 2>/dev/null)
  [ "$NL" = 1 ] || { C_G0=1; echo "  T1.30 trial $i launched $NL times under ORPHAN_GRACE_MIN=0"; }
done
[ "$C_G0" = 0 ] && ok || bad "T1.30: ORPHAN_GRACE_MIN=0 must still launch a key exactly once"
nomodel T1.30/race

# ---------- T1.31 the project name is validated before the first log write ----
# $project reaches $HARNESS/logs/$project.log, so a name with a path separator
# in it writes outside logs/. The caller is internal today; the guard is what
# makes that a fact about the script rather than about its callers.
reset
OUT=$("$H/bin/launch-fastpath.sh" ../../evil 900 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "T1.31: a project name that is not a name exits 1, got rc=$RC"
[ "$OUT" = 900 ] && ok || bad "T1.31: the key is still echoed back as declined, got '$OUT'"
[ ! -e "$T/evil.log" ] && ok || bad "T1.31: nothing may be written outside logs/: $T/evil.log exists"
[ "$(nlaunch)" = 0 ] && ok || bad "T1.31: an unvalidated project must launch nothing"
nomodel T1.31

# ---------- T1.32 the regex block has not drifted from the reconciler's -------
# The ONE assertion in this suite that reads source text, and it is here because
# the copy itself is the contract: docs/verification-map/launch-fastpath.md pins
# this exact diff as "must be empty", and a check nobody runs is a check that is
# already red. Everything else in this file drives the script and reads an
# artifact.
DRIFT=$(diff <(sed -n '/^line_re/,/^close_re/p' "$DIR/bin/orphan-reconcile.sh") \
             <(sed -n '/^line_re/,/^close_re/p' "$DIR/bin/launch-fastpath.sh") 2>&1)
[ -z "$DRIFT" ] && ok || bad "T1.32: the blocker/HOLD/PR regex block has drifted from bin/orphan-reconcile.sh's:
$DRIFT"

# ---------- never writes to GitHub -------------------------------------------
grep -qE '(^| )(issue|pr) (comment|close|edit|merge|create)' "$H/gh-all.log" 2>/dev/null \
  && bad "the fast path must never write to GitHub: $(grep -E '(comment|close|edit|merge|create)' "$H/gh-all.log")" || ok
# ---------- and never reads GitHub over GraphQL (BH-1163) --------------------
# `gh pr` / `gh issue` / `gh run` are the GraphQL-backed verbs, and this file
# carries `# gh-rest: no-graphql` to promise it uses none of them. Every case
# above appended its argv to gh-all.log, so this is that promise checked across
# a whole run rather than a marker taking the script's word for it.
grep -qE '(^| )(pr|issue|run) (list|view)( |$)' "$H/gh-all.log" 2>/dev/null \
  && bad "no GraphQL reader may survive: $(grep -E '(^| )(pr|issue|run) (list|view)( |$)' "$H/gh-all.log" | head -3)" || ok
[ ! -s "$H/model-called.log" ] && ok || bad "the fast path must never call a model: $(cat "$H/model-called.log")"

echo "launch-fastpath: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
