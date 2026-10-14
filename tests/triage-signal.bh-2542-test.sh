#!/bin/bash
# tests/triage-signal.bh-2542-test.sh — BH-2542: a ticket change that carries no
# human signal (our own comment, a label, a harness waitingOn/triageVerdict
# write) settles with no triage session.
#
# THE GAP. The per-ticket fingerprint (BH-1015) hashes the ticket's LIVE board
# entry, and that entry moves on everything: commentCount, lastActivityAt,
# waitingOn, triageVerdict, updatedAt. The tick-level absorbers
# (bin/gate-selfwrite.py, bin/lib/gate-self-comments.sh) only help when EVERY
# delta on the board is ours. Once one real change makes the tick RUN, every
# other key whose only change was bot or label churn is re-bought in the shard
# loop. This suite pins that such a key buys nothing, and that every change a
# human made still does.
#
#   A  the pure digest, bin/triage-signal.py, in-app and GitHub shapes
#   B  the REAL bin/triage-gate.sh --signal, board-fetch.sh / gh stubbed
#   C  the two knobs, TRIAGE_SIGNAL_SETTLE and TRIAGE_SIGNAL_MAX_READS
#   D  the signal fingerprint still moves on queue / PR / build changes
#   E  end to end through the REAL bin/run-triage.sh, cost on logs/cost.csv
#
# Run from anywhere: tests/triage-signal.bh-2542-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
NOW=$(date +%s)

SIGPY="$DIR/bin/triage-signal.py"
SIGLIB="$DIR/bin/lib/triage-signal.sh"
[ -r "$SIGPY" ] && ok || bad "bin/triage-signal.py must exist"
[ -r "$SIGLIB" ] && ok || bad "bin/lib/triage-signal.sh must exist"
HEX16='^[0-9a-f]{16}$'

# ═══ A — the digest ═════════════════════════════════════════════════════════
A="$T/a"; mkdir -p "$A"
dig() { # dig <kind> <file> -> digest on stdout, the script's own rc
  # BH-2604: agent:build-harness is no longer a literal in the digest; it
  # arrives as SELF_IDENTITIES, the way production now hands it over
  SELF_ACTORS="project-1 Team Harness" SELF_APPS_JSON='["cromford"]' SELF_IDENTITIES=agent:build-harness \
    python3 "$SIGPY" --kind "$1" < "$2"
}
cat > "$A/in.json" <<'JSON'
{"ticket":{"id":"101","title":"Fee toggle","description":"Remove the discount toggle","status":"open",
 "waitingOn":"us","triageVerdict":null,"turn":"us","labels":["billing"],"assignee":"dev-a",
 "commentCount":2,"lastActivityAt":"2026-09-25T01:00:00Z","createdAt":"2026-09-20T00:00:00Z",
 "comments":[
  {"id":"c1","author":{"userId":"u-carol","name":"Carol Client"},"body":"please remove it","createdAt":"2026-09-20T01:00:00Z","isInternal":false},
  {"id":"c2","author":{"userId":"u-h","name":"project-1 Team Harness"},"body":"on it","createdAt":"2026-09-20T02:00:00Z","isInternal":false}]}}
JSON
inv() { jq -c "$1" "$A/in.json" > "$A/v.json"; }
BASE_IN=$(dig inapp "$A/in.json"); RC=$?
[ "$RC" = 0 ] && grep -qE "$HEX16" <<<"$BASE_IN" && ok \
  || bad "(A) the in-app base thread must digest to 16 hex, rc 0 (rc=$RC out='$BASE_IN')"
same_in() { local d; d=$(dig inapp "$A/v.json"); [ -n "$BASE_IN" ] && [ "$d" = "$BASE_IN" ] && ok || bad "(A) in-app $1 must NOT move the digest ($d vs $BASE_IN)"; }
diff_in() { local d; d=$(dig inapp "$A/v.json"); grep -qE "$HEX16" <<<"$d" && [ "$d" != "$BASE_IN" ] && ok || bad "(A) in-app $1 MUST move the digest ($d vs $BASE_IN)"; }

inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-h","name":"project-1 team harness"},"body":"triage: holding","createdAt":"2026-09-25T02:00:00Z","isInternal":false}] | .ticket.commentCount=3 | .ticket.lastActivityAt="2026-09-25T02:00:00Z"'
same_in "a self-authored comment (+count, +lastActivityAt)"
# PR #2593 lead fix, B1. This assertion was WRONG and is flipped, not loosened:
# it pinned `same_in` for a human's isInternal note. On the project-9 contract
# (docs/board-api.md) isInternal also marks a HUMAN on the delivery team, so a
# note a person typed on the board must move the digest. Ours = author only.
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-dan","name":"Dev Dan"},"body":"internal note","isInternal":true}]'
diff_in "an isInternal comment by a human (Dev Dan)"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-h","name":"project-1 Team Harness"},"body":"triage: holding","isInternal":true}]'
same_in "our own comment that the board also marks isInternal"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-bh","name":"Build Harness"},"authorActor":"agent:build-harness","body":"built"}]'
same_in "a comment carrying our author_actor marker (agent:build-harness)"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-bh","name":"Build Harness","author_actor":"agent:build-harness"},"body":"built"}]'
same_in "a comment carrying our author_actor marker inside the author object"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-t","name":"Ticket Triage"},"authorActor":"agent:ticket-triage","body":"a question"}]'
diff_in "a comment by another agent (author_actor agent:ticket-triage is not ours)"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-carol","name":"Carol Client","recordedBy":"Build Harness"},"authorActor":"agent:build-harness","body":"from the call: yes"}]'
diff_in "a person's words a machine recorded for them (author.recordedBy)"
# spoofs: exclusion is by author identity, never by what the body quotes and
# never by a name that merely looks like ours
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-carol","name":"Carol Client"},"body":"> project-1 Team Harness wrote:\n> triage: holding\nno, do it now","isInternal":false}]'
diff_in "a human comment that quotes our bot"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-x","name":"project-1 Team Harness Bot"},"body":"hi"}]'
diff_in "a display name that looks like our bot (project-1 Team Harness Bot)"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-x","name":"project-1-team-harness[bot]","displayName":"[bot] project-1 Team Harness"},"body":"hi"}]'
diff_in "a display name dressed as a bot account ([bot] project-1 Team Harness)"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-dan","name":"Dev Dan"},"body":"> project-1 Team Harness: on it\nnot yet","isInternal":true}]'
diff_in "an isInternal human comment quoting the self actor"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-dan","name":"Dev Dan","displayName":"project-1 Team Harness"},"body":"ship it","isInternal":true}]'
diff_in "a human comment whose displayName is the self actor name"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-carol","name":"Carol Client"},"authorName":"project-1 Team Harness","body":"ship it"}]'
diff_in "a human comment with a self-actor authorName beside its author object"
# PR #2593 lead fix, 4: priority and attachments are a person's signal
inv '.ticket.priority="urgent"';                 diff_in "a priority change"
inv '.ticket.attachments=[{"id":"a1","name":"w9.pdf","size":123,"url":"https://s.invalid/w9.pdf?sig=1"}]'
diff_in "an attachment added with no comment"
jq -c '.ticket.attachments=[{"id":"a1","name":"w9.pdf","size":123,"url":"https://s.invalid/w9.pdf?sig=1"}]' "$A/in.json" > "$A/att1.json"
jq -c '.ticket.attachments=[{"id":"a1","name":"w9.pdf","size":123,"url":"https://s.invalid/w9.pdf?sig=2"}]' "$A/in.json" > "$A/att2.json"
[ "$(dig inapp "$A/att1.json")" = "$(dig inapp "$A/att2.json")" ] && ok \
  || bad "(A) a signed attachment URL re-minted on a later read must NOT move the digest"
inv '.ticket.labels=["billing","urgent"] | .ticket.assignee="dev-b" | .ticket.milestone="M2"'
same_in "a label / assignee / milestone change"
inv '.ticket.waitingOn="client" | .ticket.triageVerdict="needs_clarification" | .ticket.turn="client"'
same_in "a waitingOn / triageVerdict / turn flip"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-carol","name":"Carol Client"},"body":"the rep sets it by hand","createdAt":"2026-09-25T03:00:00Z"}]'
diff_in "a client comment"
inv '.ticket.comments[0].body="please remove it, and the note too"'
diff_in "an edited client comment"
inv '.ticket.comments += [{"id":"c3","author":{"userId":"u-x","name":"project-1 Team Harness Jr"},"body":"hi"}]'
diff_in "a comment whose author only CONTAINS the self actor name"
inv '.ticket.title="Fee toggle v2"';            diff_in "a title edit"
inv '.ticket.description="Remove it entirely"'; diff_in "a description edit"
inv '.ticket.status="in_progress"';             diff_in "a status change"
inv 'del(.ticket.comments[0])';                 diff_in "a deleted client comment"
inv '.ticket.comments[0] = {"id":"c9","author":{"userId":"u-carol","name":"Carol Client"},"body":"please remove it"}'
diff_in "a comment deleted and another added (same count)"
# the project-9 shape: metadata under .ticket, thread in the sibling .comments
jq -c '{ticket: (.ticket | del(.comments)), comments: .ticket.comments}' "$A/in.json" > "$A/v.json"
D=$(dig inapp "$A/v.json"); grep -qE "$HEX16" <<<"$D" && ok || bad "(A) the sibling-comments in-app shape must digest (got '$D')"

cat > "$A/gh.json" <<'JSON'
{"issue":{"number":563,"title":"c","body":"b","state":"open","labels":[{"name":"ai-build"}],"assignees":[],
  "milestone":null,"comments":2,"updated_at":"2026-09-25T01:00:00Z"},
 "comments":[{"id":11,"user":{"login":"client-carl","type":"User"},"body":"hi","created_at":"2026-09-20T01:00:00Z"},
             {"id":12,"user":{"login":"cromford[bot]","type":"Bot"},"body":"triage","created_at":"2026-09-20T02:00:00Z"}]}
JSON
ghv() { jq -c "$1" "$A/gh.json" > "$A/v.json"; }
BASE_GH=$(dig gh "$A/gh.json"); RC=$?
[ "$RC" = 0 ] && grep -qE "$HEX16" <<<"$BASE_GH" && ok || bad "(A) the GitHub base thread must digest (rc=$RC out='$BASE_GH')"
same_gh() { local d; d=$(dig gh "$A/v.json"); [ -n "$BASE_GH" ] && [ "$d" = "$BASE_GH" ] && ok || bad "(A) gh $1 must NOT move the digest ($d vs $BASE_GH)"; }
diff_gh() { local d; d=$(dig gh "$A/v.json"); grep -qE "$HEX16" <<<"$d" && [ "$d" != "$BASE_GH" ] && ok || bad "(A) gh $1 MUST move the digest ($d vs $BASE_GH)"; }
ghv '.comments += [{"id":13,"user":{"login":"cromford[bot]","type":"Bot"},"body":"note"}] | .issue.comments=3 | .issue.updated_at="2026-09-25T09:00:00Z"'
same_gh "a comment by our own App"
ghv '.issue.labels += [{"name":"needs-info"}] | .issue.updated_at="2026-09-25T09:00:00Z" | .issue.assignees=[{"login":"x"}]'
same_gh "a label / assignee change"
ghv '.comments += [{"id":13,"user":{"login":"intercom[bot]","type":"Bot"},"body":"client says: yes"}]'
diff_gh "a comment by a bot that is not ours (intercom[bot])"
ghv '.comments += [{"id":13,"user":{"login":"operator","type":"User"},"body":"do it"}]'
diff_gh "a comment by the PAT login operator"
ghv '.issue.state="closed"';            diff_gh "a close"
ghv '.issue.title="c2"';                diff_gh "a title edit"
ghv '.issue.body="b2"';                 diff_gh "a body edit"
ghv '.comments[0].body="hi, edited"';   diff_gh "an edited client comment"
ghv '.comments += [{"id":13,"user":{"login":"client-carl","type":"User"},"body":"> cromford[bot] wrote: triage\nplease go"}]'
diff_gh "a human comment that quotes our App"
ghv '.comments += [{"id":13,"user":{"login":"cromford","type":"User"},"body":"hi"}]'
diff_gh "a USER whose login is our App slug (not a bot account)"
ghv '.comments += [{"id":13,"user":{"login":"cromford-bot","type":"User"},"body":"hi"}]'
diff_gh "a login that looks like our bot (cromford-bot, type User)"
ghv '.issue.labels += [{"name":"P1"}]';  diff_gh "a priority label added"
python3 -c 'import json; print(json.dumps({"issue":{"title":"t","body":"b","state":"open"},"comments":[{"id":i,"user":{"login":"u"},"body":"x"} for i in range(301)]}))' > "$A/v.json"
D=$(dig gh "$A/v.json"); RC=$?
[ "$RC" = 1 ] && [ -z "$D" ] && ok || bad "(A) more than 300 GitHub comments must be rc 1, no output (rc=$RC out='$D')"
for g in 'not json' '[]' '{"ticket":{"title":"t","comments":"x"}}' '{"ticket":{"title":"t"}}' '"str"'; do
  printf '%s' "$g" > "$A/v.json"
  D=$(dig inapp "$A/v.json"); RC=$?
  [ "$RC" = 1 ] && [ -z "$D" ] && ok || bad "(A) garbage in-app input '$g' must be rc 1 with empty stdout (rc=$RC out='$D')"
done
printf '%s' '{"issue":{"title":"t"}}' > "$A/v.json"
D=$(dig gh "$A/v.json"); RC=$?
[ "$RC" = 1 ] && [ -z "$D" ] && ok || bad "(A) a GitHub thread with no comments list must be rc 1 (rc=$RC out='$D')"
printf 'BOARD-FETCH FAILED: HTTP 500 for x' > "$A/v.json"
D=$(dig inapp "$A/v.json"); RC=$?
[ "$RC" = 1 ] && [ -z "$D" ] && ok || bad "(A) a board-fetch failure line must be rc 1 (rc=$RC out='$D')"

# ═══ B — the REAL gate's --signal mode ══════════════════════════════════════
G="$T/g"
mkdir -p "$G/bin/lib" "$G/env" "$G/state" "$G/logs" "$G/fixture" "$T/gbin"
for s in triage-gate.sh fleet-conf.sh triage-signal.py; do cp "$DIR/bin/$s" "$G/bin/$s"; done
for s in board-creds.sh internal-token.sh gh-rest.sh gh-rest-var.sh gate-self-comments.sh harness-self.sh env-path.sh deployment.sh; do
  [ -r "$DIR/bin/lib/$s" ] && cp "$DIR/bin/lib/$s" "$G/bin/lib/$s"
done
chmod +x "$G/bin/"*.sh
cat > "$G/fleet.conf" <<'CONF'
sg   org/sg   https://x.invalid /api/board 1 box-1
sge  org/sge  https://x.invalid /api/board 1 box-1
project-5 org/project-5 https://x.invalid - 1 box-1
CONF
# BH-4080: project-5 is no longer a literal arm of triage-gate.sh; it reaches
# the GitHub path through its fleet.conf row (board prefix "-"), like any
# GitHub-Issues board.
: > "$G/env/global.env"
# the generic arm's self actor is "$BOARD_SELF_ACTORS Harness" — the same
# "project-1 Team Harness" the section A fixtures name as ours
printf 'SG_APP_BASE=https://x.invalid\nSG_INTERNAL_API_TOKEN=tok-sg\nBOARD_SELF_ACTORS="project-1 Team"\n' > "$G/env/sg.env"
printf 'SGE_APP_BASE=https://x.invalid\nSGE_INTERNAL_API_TOKEN=\n'     > "$G/env/sge.env"
cp "$A/in.json" "$G/fixture/thread.json"
cat > "$G/bin/board-fetch.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$G/fixture/bf-calls"
cat "$G/fixture/thread.json"
STUB
chmod +x "$G/bin/board-fetch.sh"
# gh, as gh_rest calls it: `gh api -i -X GET <path> [-F k=v]...`, headers first.
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$G/fixture/gh-calls"
case "\$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
  *issues/563/comments*)
    PG=\$(printf '%s\n' "\$@" | sed -n 's/^page=//p'); PG=\${PG:-1}
    printf 'HTTP/2 200\r\n\r\n'
    jq -c --argjson p "\$PG" '.comments[((\$p-1)*100):(\$p*100)]' "$G/fixture/gh-thread.json"; exit 0 ;;
  *issues/563*)
    printf 'HTTP/2 200\r\n\r\n'; jq -c '.issue' "$G/fixture/gh-thread.json"; exit 0 ;;
esac
printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1
STUB
chmod +x "$T/gbin/gh"
GE=(env HARNESS="$G" HARNESS_ENV_DIR="$G/env" FLEET_CONF="$G/fleet.conf" HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH")
gsig() { "${GE[@]}" bash "$G/bin/triage-gate.sh" "$1" --signal "$2" 2>/dev/null; }
statesum() { (cd "$G" && find state -type f -print0 | sort -z | xargs -0 -r sha256sum); }

BEFORE=$(statesum)
OUT=$(gsig sg 101); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$BASE_IN" ] && ok || bad "(B) the real gate --signal must print the thread's digest (rc=$RC out='$OUT' want '$BASE_IN')"
grep -q -- '--full' "$G/fixture/bf-calls" 2>/dev/null && ok || bad "(B) the gate must read the WHOLE thread (board-fetch.sh --full): $(cat "$G/fixture/bf-calls" 2>/dev/null)"
grep -q 'https://x.invalid/api/board/tickets/101' "$G/fixture/bf-calls" 2>/dev/null && ok || bad "(B) the gate must fetch this ticket's own URL: $(cat "$G/fixture/bf-calls" 2>/dev/null)"
[ "$(statesum)" = "$BEFORE" ] && [ ! -e "$G/state/sg.gate.pending" ] && [ ! -e "$G/state/sg.gate.json" ] && ok \
  || bad "(B) --signal must write no state at all"
: > "$G/fixture/bf-calls"
OUT=$(gsig sge 101); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(B) an empty token must exit 1 with no verdict text (rc=$RC out='$OUT')"
[ ! -s "$G/fixture/bf-calls" ] && ok || bad "(B) an empty token must fetch nothing"
mkdir -p "$G/state/remote-results/sg"; echo '{}' > "$G/state/remote-results/sg/x.json"
OUT=$(gsig sg 101); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$BASE_IN" ] && ok || bad "(B) remote results pending must not turn --signal into a RUN verdict (rc=$RC out='$OUT')"
scratch_rm "$G/state/remote-results"
printf 'BOARD-FETCH FAILED: HTTP 401 for x\n' > "$G/fixture/thread.json"
OUT=$(gsig sg 101); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(B) a failed board read must exit 1 (rc=$RC out='$OUT')"
OUT=$(gsig nosuchproject 101); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(B) an unknown project must exit 1 with no RUN text (rc=$RC out='$OUT')"

# GitHub: 150 comments over two pages
python3 - "$A/gh.json" > "$G/fixture/gh-thread.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
t["comments"] = [{"id": 1000 + i, "user": {"login": "client-carl" if i % 3 else "cromford[bot]", "type": "User" if i % 3 else "Bot"}, "body": "c%d" % i} for i in range(150)]
t["issue"]["comments"] = 150
print(json.dumps(t))
PY
WANT=$(dig gh "$G/fixture/gh-thread.json")
OUT=$(gsig project-5 TK-563); RC=$?
[ "$RC" = 0 ] && [ -n "$WANT" ] && [ "$OUT" = "$WANT" ] && ok || bad "(B) GitHub: the gate must assemble issue + both comment pages into the same digest (rc=$RC out='$OUT' want '$WANT')"
grep -q 'page=2' "$G/fixture/gh-calls" 2>/dev/null && ok || bad "(B) GitHub: the second comment page must be read"
python3 - "$A/gh.json" > "$G/fixture/gh-thread.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
t["comments"] = [{"id": 1000 + i, "user": {"login": "client-carl"}, "body": "c%d" % i} for i in range(301)]
t["issue"]["comments"] = 301
print(json.dumps(t))
PY
OUT=$(gsig project-5 563); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(B) GitHub: more than 300 comments must exit 1 (rc=$RC out='$OUT')"
# the issue's own count says 301 while the pages hand back fewer (a read racing
# new comments): the count alone must refuse, never digest a partial thread
jq -c '.comments = .comments[0:50]' "$G/fixture/gh-thread.json" > "$G/fixture/gh-thread.new" && mv "$G/fixture/gh-thread.new" "$G/fixture/gh-thread.json"
OUT=$(gsig project-5 563); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "(B) GitHub: an issue whose count is over 300 must exit 1 whatever the pages return (rc=$RC out='$OUT')"

# ═══ E harness — the REAL run-triage.sh, gate stubbed ══════════════════════
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" project-5 project-1 || exit 1
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
export FLEET_CONF="$DIR/fleet.conf"
for p in project-5 project-1; do echo "SOP for $p. Fetch the thread. Do the work." > "$H/prompts/$p.md"; done
for s in run-triage.sh triage-shard.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
cp "$SIGLIB" "$H/bin/lib/triage-signal.sh" 2>/dev/null
cp "$SIGPY" "$H/bin/triage-signal.py" 2>/dev/null
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh gh-budget.sh cost-row.sh harness-self.sh alert-state.sh env-path.sh; do
  sed -e "s|/root/harness|$H|g" "$DIR/bin/lib/$s" > "$H/bin/lib/$s"
done
# BH-2604: the empty-allowlist alert goes through the real bin/lane-alert.sh
sed -e "s|/root/harness|$H|g" -e "s|/root/orchestrator|$T/orc|g" "$DIR/bin/lane-alert.sh" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
cp "$DIR/bin/alert_family.py" "$H/bin/alert_family.py"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
# The gate stub: --signal pipes this ticket's thread fixture into the REAL
# bin/triage-signal.py; every other mode behaves like the BH-1015 suite's stub.
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
case "\$MODE" in
  --buildable) echo OK; exit 0 ;;
  --signal)
    printf '%s %s\n' "\$P" "\$3" >> "$H/fixture/signal-calls"
    [ -e "$H/fixture/signal-fail" ] && exit 1
    F="$H/fixture/\$P/thread-\$3.json"; [ -s "\$F" ] || exit 1
    K=inapp; [ "\$P" = project-5 ] && K=gh
    SELF_ACTORS="project-1 Team Harness" SELF_APPS_JSON='["cromford"]' SELF_IDENTITIES=agent:build-harness \
      python3 "$H/bin/triage-signal.py" --kind "\$K" < "\$F"
    exit \$? ;;
esac
cp "$H/fixture/\$P/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
cat > "$H/bin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/gh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '2026-09-25T00:00:00Z,box,%s,%s,claude,%s,,,,,,,0.9100\n' "$2" "$1" "$3" >> "$COSTCSV"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

held() { [ -e "$1" ] || return 1; if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi; return 0; }
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
ncost()  { grep -c ',triage,' "$H/logs/cost.csv" 2>/dev/null | tr -d ' ' || true; }
nsig()   { grep -c . "$H/fixture/signal-calls" 2>/dev/null | tr -d ' ' || true; }
fpf()    { printf '%s/state/triage-shards/%s/%s.fp\n' "$H" "$P" "$1"; }
calledfor() { grep -l "Work ONLY ticket $1 this tick" "$T/calls"/prompt-* >/dev/null 2>&1; }
settle() {
  local i=0 busy L
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "${1:-0}" ]; then
      busy=0
      for L in "$H"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  sleep 1; return 1
}
nextick() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$H/logs/cost.csv"; : > "$H/fixture/signal-calls"; }
run() { CALLDIR="$T/calls" COSTCSV="$H/logs/cost.csv" PATH="$H/bin:$PATH" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
tick() { nextick; run "$@"; settle "${WANT_CALLS:-0}" >/dev/null; }
reset_box() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 project-1 || exit 1
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds" "$H/fixture/$P"
  rm -f "$H/fixture/signal-fail"
  : > "$H/logs/READY-QUEUE.log"; : > "$H/logs/cost.csv"
  echo "RUN board-changed" > "$H/fixture/gate-decision"
}

# ---- in-app fixtures (project-1): tickets 101 (A) and 102 (B) --------------
tk() { # tk <id> <count> <activity> [waitingOn] [verdict]
  printf '{"id":"%s","status":"open","waitingOn":"%s","triageVerdict":%s,"commentCount":%s,"lastActivityAt":"%s","title":"T%s"}' \
    "$1" "${4:-us}" "${5:-null}" "$2" "$3" "$1"
}
pend_in() { printf '{"b1":[%s,%s]}' "$1" "$2" > "$H/fixture/$P/pending.json"; }
thr() { # thr <id> <jq-filter> — the ticket's thread fixture, derived from A's base
  jq -c --arg id "$1" '.ticket.id=$id | .ticket.title=("T"+$id) | '"$2" "$A/in.json" > "$H/fixture/$P/thread-$1.json"
}
diff_in2() { printf 'board b1: CHANGED 101 "T101" (comments: 1 -> 2)\nboard b1: CHANGED 102 "T102" (comments: 1 -> 2)\n' > "$H/fixture/diff"; }
SELFC='{"id":"s%s","author":{"userId":"u-h","name":"project-1 Team Harness"},"body":"triage: holding %s"}'
CLIC='{"id":"k%s","author":{"userId":"u-carol","name":"Carol Client"},"body":"answer %s"}'
addc() { # addc <id> <template> <n> — append one comment to the ticket's thread fixture
  local f="$H/fixture/$P/thread-$1.json" c
  c=$(printf "$2" "$3" "$3")
  jq -c --argjson c "$c" '.ticket.comments += [$c]' "$f" > "$f.new" && mv "$f.new" "$f"
}
base_inapp() { # a box whose first tick over A and B has been paid for
  P=project-1; reset_box
  thr 101 '.'; thr 102 '.'
  pend_in "$(tk 101 2 2026-09-25T01:00:00Z)" "$(tk 102 2 2026-09-25T01:00:00Z)"
  pend_in "$(tk 101 2 2026-09-25T01:00:00Z)" "$(tk 102 2 2026-09-25T01:00:00Z)"
  cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
  diff_in2
  WANT_CALLS=2 tick "$@"
}

# ═══ E1 — a mixed tick: A has only our comment, B a client comment ═════════
base_inapp
[ "$(ncost)" = 2 ] && ok || bad "(E1) precondition: the first tick must buy A and B (got $(ncost))"
[ "$(sed -n 3p "$(fpf 101)" 2>/dev/null | grep -cE "$HEX16")" = 1 ] && ok \
  || bad "(E1) a dispatch that computed a signal fingerprint must store it as stamp line 3: $(cat "$(fpf 101)" 2>/dev/null | tr '\n' ' ')"
EPOCH_A=$(sed -n 2p "$(fpf 101)" 2>/dev/null)
addc 101 "$SELFC" 1; addc 102 "$CLIC" 1
pend_in "$(tk 101 3 2026-09-25T02:00:00Z)" "$(tk 102 3 2026-09-25T02:00:00Z)"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && ok || bad "(E1) our own comment on A plus a client comment on B must buy exactly ONE session (got $(ncost)) — a bot comment buys no triage call"
calledfor 102 && ok || bad "(E1) the one session bought must be B's (102)"
calledfor 101 && bad "(E1) A (101) must not be bought for our own comment" || ok
grep -qE "triage shards: 101 .*no-signal|no-signal:.* 101" "$H/logs/$P.log" && ok || bad "(E1) A's settle must be logged as no-signal"
grep -q 'no-signal: 101' "$H/logs/$P.log" && ok || bad "(E1) the dispatch summary must list the settled key: $(grep dispatched "$H/logs/$P.log" | tail -1)"
[ "$(sed -n 2p "$(fpf 101)" 2>/dev/null)" = "$EPOCH_A" ] && ok \
  || bad "(E1) a settle must keep the OLD epoch so the TTL backstop still fires ($(sed -n 2p "$(fpf 101)") vs $EPOCH_A)"
# PR #2593 lead fix, 2: the saving is a ledger row, not only a log line
PRE=$(grep ',triage-precheck,' "$H/logs/cost.csv" 2>/dev/null)
[ "$(printf '%s\n' "$PRE" | grep -c ',triage-precheck,')" = 1 ] && ok \
  || bad "(E1) a settle must write exactly one triage-precheck row to logs/cost.csv (got: $PRE)"
printf '%s' "$PRE" | awk -F, '$3=="project-1" && $4=="triage-precheck" && $13=="0" && $18=="settled" && $20=="101" && $24=="settled:no-signal" && $25=="run-triage" {f=1} END{exit !f}' && ok \
  || bad "(E1) the settle row must be project project-1, stage triage-precheck, cost_usd 0, row_source settled (BH-2604), ticket 101, note settled:no-signal, lane run-triage: $PRE"
[ "$(awk -F, '$4=="triage-precheck" {print NF}' "$H/logs/cost.csv" | head -1)" = 25 ] && ok \
  || bad "(E1) the settle row must carry the canonical 25 columns"

# ═══ E2 — waitingOn us->client + needs_clarification, no new comment ════════
pend_in "$(tk 101 3 2026-09-25T02:30:00Z client '"needs_clarification"')" "$(tk 102 3 2026-09-25T02:00:00Z)"
thr_a=$(cat "$H/fixture/$P/thread-101.json")
printf '%s' "$thr_a" | jq -c '.ticket.waitingOn="client" | .ticket.triageVerdict="needs_clarification"' > "$H/fixture/$P/thread-101.json"
printf 'board b1: CHANGED 101 "T101" (waitingOn: us -> client)\n' > "$H/fixture/diff"
WANT_CALLS=0 tick
[ "$(ncost)" = 0 ] && ok || bad "(E2) a harness waitingOn/triageVerdict write with no client reply must buy nothing (got $(ncost))"

# ═══ E2b — a PERSON flips the turn back to the team, no comment ═════════════
# PR #2593 lead fix, 4: waitingOn is out of the digest, so the turn itself is
# compared (stamp line 4). Back to the team = our move now, not at the 4h TTL.
pend_in "$(tk 101 3 2026-09-25T02:40:00Z team '"needs_clarification"')" "$(tk 102 3 2026-09-25T02:00:00Z)"
printf 'board b1: CHANGED 101 "T101" (waitingOn: client -> team)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && calledfor 101 && ok || bad "(E2b) a human flipping waitingOn back to the team must buy the session now (got $(ncost))"
[ "$(sed -n 4p "$(fpf 101)" 2>/dev/null)" = team ] && ok || bad "(E2b) the dispatch stamp must record the turn as line 4: $(cat "$(fpf 101)" 2>/dev/null | tr '\n' ' ')"

# ═══ E3 — the client then answers ═══════════════════════════════════════════
addc 101 "$CLIC" 2
pend_in "$(tk 101 4 2026-09-25T03:00:00Z client '"needs_clarification"')" "$(tk 102 3 2026-09-25T02:00:00Z)"
printf 'board b1: CHANGED 101 "T101" (comments: 3 -> 4)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && calledfor 101 && ok || bad "(E3) a client reply on a waiting ticket must buy its session (got $(ncost))"

# ═══ E5 — the TTL backstop: an old stamp dispatches even with no signal ════
F=$(fpf 101); printf '%s\n%s\n%s\n' "$(sed -n 1p "$F")" "$(( NOW - 15000 ))" "$(sed -n 3p "$F")" > "$F"
addc 101 "$SELFC" 3
pend_in "$(tk 101 5 2026-09-25T04:00:00Z client '"needs_clarification"')" "$(tk 102 3 2026-09-25T02:00:00Z)"
printf 'board b1: CHANGED 101 "T101" (comments: 4 -> 5)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && ok || bad "(E5) a stamp older than TRIAGE_SHARD_FP_TTL_S must dispatch even with no signal (got $(ncost))"

# ═══ E7 — the thread read fails: dispatch, 2-line stamp ═════════════════════
touch "$H/fixture/signal-fail"
addc 101 "$SELFC" 4
pend_in "$(tk 101 6 2026-09-25T05:00:00Z client '"needs_clarification"')" "$(tk 102 3 2026-09-25T02:00:00Z)"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && ok || bad "(E7) an unreadable thread must dispatch (got $(ncost)) — a failed read is never 'unchanged'"
[ "$(grep -c . "$(fpf 101)" 2>/dev/null)" = 2 ] && ok || bad "(E7) with no signal fingerprint the stamp is the 2-line one: $(cat "$(fpf 101)" | tr '\n' ' ')"
rm -f "$H/fixture/signal-fail"

# ═══ C — knobs ═════════════════════════════════════════════════════════════
nosig_tick() { # both tickets gain only our own comment
  addc 101 "$SELFC" 9; addc 102 "$SELFC" 9
  pend_in "$(tk 101 3 2026-09-25T06:00:00Z)" "$(tk 102 3 2026-09-25T06:00:00Z)"
  WANT_CALLS="$1" tick "${@:2}"
}
base_inapp
nosig_tick 2 env TRIAGE_SIGNAL_SETTLE=0
[ "$(ncost)" = 2 ] && [ "$(nsig)" = 0 ] && ok || bad "(C) TRIAGE_SIGNAL_SETTLE=0 in env must restore today's behaviour: dispatch, no thread read (cost $(ncost), reads $(nsig))"
base_inapp
echo 'TRIAGE_SIGNAL_SETTLE=0' >> "$H/env/global.env"
nosig_tick 2
[ "$(ncost)" = 2 ] && ok || bad "(C) TRIAGE_SIGNAL_SETTLE=0 in env/global.env must dispatch too (got $(ncost))"
sed -i'' -e '/TRIAGE_SIGNAL_SETTLE/d' "$H/env/global.env"
base_inapp
nosig_tick 1 env TRIAGE_SIGNAL_MAX_READS=1
[ "$(ncost)" = 1 ] && [ "$(nsig)" = 1 ] && ok || bad "(C) MAX_READS=1 must settle one bot-only key and dispatch the other (cost $(ncost), reads $(nsig))"
# and the default: both settle
base_inapp
nosig_tick 0
[ "$(ncost)" = 0 ] && [ "$(nsig)" = 2 ] && ok || bad "(C) by default two bot-only keys must both settle (cost $(ncost), reads $(nsig))"
jq -e '.libs[] | select(.id=="triage-signal") | .knobs | map(.env) | index("TRIAGE_SIGNAL_SETTLE") and index("TRIAGE_SIGNAL_MAX_READS")' \
  "$DIR/catalog/lanes.d/_lib.triage-signal.json" >/dev/null 2>&1 && ok || bad "(C) both knobs must be registered in catalog/lanes.d/_lib.triage-signal.json"
LB=$(cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "(C) bin/lanes-build.sh --check must stay green (rc=$RC): $LB"

# ═══ E9 — mutation: the settle's `continue` is what saves the money ════════
cp "$H/bin/lib/rt/shards.sh" "$T/shards.orig"
if grep -q 'continue  # no-signal settle' "$H/bin/lib/rt/shards.sh"; then
  sed -i'' -e 's/continue  # no-signal settle/: # MUTANT/' "$H/bin/lib/rt/shards.sh"
  base_inapp
  nosig_tick 2
  [ "$(ncost)" = 2 ] && ok || bad "(E9) with the settle's continue removed, the bot-only keys must be bought again (got $(ncost)) — else this suite proves nothing"
else
  bad "(E9) the settle branch must carry the marker 'continue  # no-signal settle'"
fi
cp "$T/shards.orig" "$H/bin/lib/rt/shards.sh"

# ═══ GitHub (project-5): E4 label churn, E6 absence, E8 pr keys ═══════════
P=project-5
reset_box
cp "$A/gh.json" "$H/fixture/$P/thread-563.json"
ghpend() { printf '{"issues":[%s],"prs":[{"number":12,"headRefOid":"aaa","state":"OPEN"}]}' "$1" > "$H/fixture/$P/pending.json"; }
ghi() { printf '{"number":563,"state":"OPEN","title":"c","comments":%s,"updatedAt":"%s"}' "$1" "$2"; }
ghpend "$(ghi 2 2026-09-25T01:00:00Z)"
cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
printf 'board issues: CHANGED 563 "c" (comments: 1 -> 2)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick env HARNESS_SELF_APPS=cromford
[ "$(ncost)" = 1 ] && ok || bad "(E4) precondition: the first GitHub tick must dispatch (got $(ncost))"
jq -c '.issue.labels += [{"name":"needs-info"}] | .issue.updated_at="2026-09-25T09:00:00Z"' "$A/gh.json" > "$H/fixture/$P/thread-563.json"
ghpend "$(ghi 2 2026-09-25T09:00:00Z)"
WANT_CALLS=0 tick env HARNESS_SELF_APPS=cromford
[ "$(ncost)" = 0 ] && ok || bad "(E4) a label added on GitHub (updatedAt moved, no comment) must buy nothing (got $(ncost))"
grep -q 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" "$H/logs/$P.log" 2>/dev/null \
  && bad "(E4) a set HARNESS_SELF_APPS must raise no empty-allowlist line" || ok
# D — the signal fingerprint composition, same box
UN="$T/units"
printf '563\tboard\tboard issues: CHANGED 563 "c"\n563\tqueue\tTS-563 tid-563 — waiting on PR #12 project=project-5\n' > "$UN"
sfp() ( . "$H/bin/lib/triage-shards-lib.sh"; triage_shard_fp "$H" "$P" 563 1 "$UN" "sig 0123456789abcdef" )
printf '12\tOPEN\t%s\n' "$NOW" > "$H/state/$P.prstates"
S1=$(sfp)
ghpend "$(ghi 7 2026-09-25T11:00:00Z)"; cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.pending"
S1b=$(sfp)
[ -n "$S1" ] && [ "$S1" = "$S1b" ] && ok || bad "(D) with a pend override the live board entry must not reach the fingerprint ($S1 vs $S1b)"
printf '12\tMERGED\t%s\n' "$NOW" > "$H/state/$P.prstates"; S2=$(sfp)
[ -n "$S2" ] && [ "$S2" != "$S1" ] && ok || bad "(D) a PR it names merging must move the signal fingerprint"
mkdir -p "$H/builds/$P-TK-563-202609250101"; echo "PR_CREATED x" > "$H/builds/$P-TK-563-202609250101/RESULT"; S3=$(sfp)
[ -n "$S3" ] && [ "$S3" != "$S2" ] && ok || bad "(D) a new build dir must move the signal fingerprint"
printf '563\tboard\tboard issues: CHANGED 563 "c"\n563\tqueue\tTS-563 tid-563 — waiting on PR #13 project=project-5\n' > "$UN"; S4=$(sfp)
[ -n "$S4" ] && [ "$S4" != "$S3" ] && ok || bad "(D) a queue-line skeleton change must move the signal fingerprint"
scratch_rm "$H/builds"; mkdir -p "$H/builds"; rm -f "$H/state/$P.prstates"

# E8 — a pr-<n> key is never asked for a thread
ghpend "$(ghi 2 2026-09-25T09:00:00Z)"
printf '{"issues":[%s],"prs":[{"number":12,"headRefOid":"bbb","state":"OPEN"}]}' "$(ghi 2 2026-09-25T09:00:00Z)" > "$H/fixture/$P/pending.json"
printf 'board prs: CHANGED 12 "fix" (head: aaa -> bbb)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && ok || bad "(E8) a pr-12 key must dispatch as today (got $(ncost))"
grep -q 'pr-12' "$H/fixture/signal-calls" 2>/dev/null && bad "(E8) a pr-12 key must never call --signal" || ok

# E6 — the issue leaves the ai-build list: presence is signal
printf '{"issues":[],"prs":[]}' > "$H/fixture/$P/pending.json"
printf 'board issues: REMOVED 563 "c"\n' > "$H/fixture/diff"
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && ok || bad "(E6) an issue leaving the ai-build list must dispatch (got $(ncost))"
[ "$(nsig)" = 0 ] && ok || bad "(E6) an absent ticket must not be read for a digest (reads $(nsig))"

# ═══ E10 — GitHub board, HARNESS_SELF_APPS empty: never settle, and say so ══
# PR #2593 lead fix, 3. Safe direction (dispatch), but visible: one project-log
# line per tick, one ALERTS line per project per day (BH-2604: through
# bin/lane-alert.sh's alert state, which reset_box clears with state/).
P=project-5
reset_box
cp "$A/gh.json" "$H/fixture/$P/thread-563.json"
ghpend "$(ghi 2 2026-09-25T01:00:00Z)"
cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
printf 'board issues: CHANGED 563 "c" (comments: 1 -> 2)\n' > "$H/fixture/diff"
WANT_CALLS=1 tick env HARNESS_SELF_APPS=
for n in 1 2; do
  jq -c --arg u "2026-09-25T1${n}:00:00Z" '.issue.labels += [{"name":"needs-info"}] | .issue.updated_at=$u' "$A/gh.json" > "$H/fixture/$P/thread-563.json"
  ghpend "$(ghi 2 "2026-09-25T1${n}:00:00Z")"
  WANT_CALLS=1 tick env HARNESS_SELF_APPS=
  [ "$(ncost)" = 1 ] && ok || bad "(E10.$n) with HARNESS_SELF_APPS empty a moved GitHub key must dispatch, never settle (got $(ncost))"
  [ "$(nsig)" = 0 ] && ok || bad "(E10.$n) with no allowlist the thread must not be read (reads $(nsig))"
done
[ "$(grep -c 'no-signal settle is OFF for this GitHub board' "$H/logs/$P.log" 2>/dev/null)" = 3 ] && ok \
  || bad "(E10) one project-log line per tick with an empty allowlist (want 3, got $(grep -c 'no-signal settle is OFF' "$H/logs/$P.log" 2>/dev/null))"
[ "$(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "(E10) exactly one ALERTS line per project per day (got $(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q ',triage-precheck,' "$H/logs/cost.csv" 2>/dev/null && bad "(E10) a dispatch must write no settle row" || ok

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
