#!/bin/bash
# tests/telegram-topics-sync-test.sh — BH-437: state/telegram-topics.json is
# D1-backed for its two READERS.
#
# THE INCIDENT SHAPE THIS PINS. The topic map lived only as a file on the hub.
# A rebuilt box, or a hub whose state/ was wiped, had no file — so every beat
# answered in General, and the per-project topics the group was organised
# around silently stopped being used. `telegram_topics_sync` (bin/jobs-client.sh)
# made D1 the ledger of record; this suite proves the two readers actually CALL
# it, and that poll-commands resolves BOTH file shapes.
#
# Driven against the REAL blocks, lifted verbatim out of bin/orchestrate.sh and
# bin/poll-commands.sh, with the REAL bin/jobs-client.sh behind a stubbed curl.
# Every claim below is about a resolved value, bytes on disk, a request that was
# made, or an ALERTS line — never about source text.
#
# The fixtures are the worker's own envelope ({"topics":{...},"as_of":...}),
# the same shape worker/jobs/src/index.js serves and
# tests/jobs-client-ledger-verbs-test.sh already pins.
#
# Run from anywhere: tests/telegram-topics-sync-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read for the whole file; every age is derived from it, so this suite
# cannot pick its own red day (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
STALE="@$((NOW - 1200))"   # 20 minutes old: stale under the 600s default

# curl shim: records METHOD URL BODY, answers $CURL_RESP, exits 7 when down.
# Byte-identical to tests/jobs-client-ledger-verbs-test.sh's shim.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
[ "$METHOD" = PUT ] && [ -n "${CURL_PUT_RESP:-}" ] && [ -r "$CURL_PUT_RESP" ] && { cat "$CURL_PUT_RESP"; exit 0; }
[ -n "${CURL_RESP:-}" ] && [ -r "$CURL_RESP" ] && { cat "$CURL_RESP"; exit 0; }
printf '{"ok":true}\n200\n'
SH
chmod +x "$T/fakebin/curl"

TOPICS="$T/state/telegram-topics.json"
printf '{"topics":{"project-3":6},"as_of":"2026-09-16T12:00:00Z"}\n200\n' > "$T/resp-project-3.json"
printf '{"topics":{}}\n200\n' > "$T/resp-empty.json"
printf '%s' '{"topics":{"project-3":6}}' > "$T/expected-project-3.json"
clearlog() { : > "$T/req.log"; }
# grep -c prints 0 and exits 1 on no match, and prints NOTHING on a missing
# file; both have to read as the number 0 or the comparisons below blow up.
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
gets()  { count 'GET https://jobs.test/api/telegram-topics' "$T/req.log"; }
puts()  { count 'PUT https://jobs.test/api/telegram-topics' "$T/req.log"; }

# ── the two readers, lifted verbatim ─────────────────────────────────────────
# orchestrate.sh's outbound topic-routing block, lifted the same way
# tests/tg-outbound-topic-test.sh lifts it.
ORC_BLK=$(awk '/^# Outbound per-project topic routing/,/^fi$/' "$DIR/bin/orchestrate.sh")
[ -n "$ORC_BLK" ] && ok || bad "could not lift the topic-routing block from bin/orchestrate.sh"

# poll-commands.sh's chat-handler attribution block, lifted the same way
# tests/tg-attribution-test.sh lifts it (its `if` closes past the awk range).
POLL_BLK=$(awk '/# Telegram group attribution \(2026-08-31\)/,/^        ATTRIB=/' "$DIR/bin/poll-commands.sh" \
  | sed "s#/root/harness/state/telegram-topics.json#$TOPICS#g")
POLL_BLK="$POLL_BLK
fi"
grep -q 'TG_THREAD=\$(jq' <<<"$POLL_BLK" && ok || bad "could not lift the chat-handler block from bin/poll-commands.sh"

ENVV=(HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test JOBS_BOX=testbox
      JOBS_RETRIES=0 REQ_LOG="$T/req.log")

run_orc() { # run_orc <inbound message text> -> resolved TG_THREAD
  printf '%s' "$1" > "$T/m"; printf '%s' '{}' > "$T/m.meta"
  env "${ENVV[@]}" PATH="$T/fakebin:$PATH" \
      CURL_RESP="${CURL_RESP:-}" CURL_MODE="${CURL_MODE:-ok}" \
      MSGF="$T/m" TG_TOPICS_FILE="$TOPICS" TG_THREAD="" \
      bash -c "$ORC_BLK; printf '%s' \"\$TG_THREAD\""
}

run_poll() { # run_poll <thread_id> -> resolved ATTRIB (client SOURCED, as in prod)
  local payload
  payload=$(jq -nc --arg t "$1" '{text:"fix it",chat_id:"-1000000000000",thread_id:$t,from_name:"collaborator-1"}')
  env "${ENVV[@]}" PATH="$T/fakebin:$PATH" \
      CURL_RESP="${CURL_RESP:-}" CURL_MODE="${CURL_MODE:-ok}" PAYLOAD="$payload" \
      bash -c ". \"$T/bin/jobs-client.sh\"; $POLL_BLK; printf '%s' \"\$ATTRIB\""
}

run_poll_bare() { # run_poll_bare <thread_id> -> ATTRIB with the client NOT sourced
  local payload
  payload=$(jq -nc --arg t "$1" '{text:"fix it",chat_id:"-1000000000000",thread_id:$t,from_name:"collaborator-1"}')
  PAYLOAD="$payload" bash -c "$POLL_BLK; printf '%s' \"\$ATTRIB\""
}

# ── C1. no file at all: the reader's own sync rehydrates it from D1 ──────────
rm -f "$TOPICS"; clearlog
GOT=$(CURL_RESP="$T/resp-project-3.json" run_orc 'project-3 triage wave done')
[ "$GOT" = 6 ] && ok || bad "C1 orchestrate: an project-3 beat with no topics file must resolve 6 (got '$GOT')"
cmp -s "$T/expected-project-3.json" "$TOPICS" && ok || bad "C1 orchestrate: file bytes are $(cat "$TOPICS" 2>/dev/null)"
[ "$(gets)" -eq 1 ] && ok || bad "C1 orchestrate: want exactly 1 GET, log: $(cat "$T/req.log")"

rm -f "$TOPICS"; clearlog
GOT=$(CURL_RESP="$T/resp-project-3.json" run_poll 6)
case "$GOT" in *"topic project-3"*) ok ;; *) bad "C1 poll-commands: thread 6 with no topics file must attribute topic project-3 (got '$GOT')" ;; esac
cmp -s "$T/expected-project-3.json" "$TOPICS" && ok || bad "C1 poll-commands: file bytes are $(cat "$TOPICS" 2>/dev/null)"
[ "$(gets)" -eq 1 ] && ok || bad "C1 poll-commands: want exactly 1 GET, log: $(cat "$T/req.log")"

# ── C2. a fresh file costs no request ────────────────────────────────────────
printf '%s' '{"topics":{"project-3":6}}' > "$TOPICS"; clearlog
GOT=$(CURL_RESP="$T/resp-project-3.json" run_orc 'project-3 triage wave done')
[ "$GOT" = 6 ] && ok || bad "C2 orchestrate resolved '$GOT'"
[ ! -s "$T/req.log" ] && ok || bad "C2 orchestrate: a fresh file must cost no request, log: $(cat "$T/req.log")"
clearlog
GOT=$(CURL_RESP="$T/resp-project-3.json" run_poll 6)
case "$GOT" in *"topic project-3"*) ok ;; *) bad "C2 poll-commands resolved '$GOT'" ;; esac
[ ! -s "$T/req.log" ] && ok || bad "C2 poll-commands: a fresh file must cost no request, log: $(cat "$T/req.log")"

# ── C3. stale file, D1 empty: seed D1, leave the file alone, still resolve ───
printf '%s' '{"topics":{"project-3":6,"project-2":7}}' > "$TOPICS"
touch -d "$STALE" "$TOPICS"; cp "$TOPICS" "$T/before-c3.json"; clearlog
GOT=$(CURL_RESP="$T/resp-empty.json" run_orc 'project-3 triage wave done')
[ "$GOT" = 6 ] && ok || bad "C3 orchestrate resolved '$GOT' (want 6 from the untouched file)"
[ "$(gets)" -eq 1 ] && ok || bad "C3: want 1 GET, log: $(cat "$T/req.log")"
[ "$(puts)" -eq 2 ] && ok || bad "C3: an empty D1 must be seeded with one PUT per entry, log: $(cat "$T/req.log")"
grep 'PUT https://jobs.test/api/telegram-topics ' "$T/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.project=="project-3")) | length==1 and (.[0].thread_id==6) and ((.[0].thread_id|type)=="number")' >/dev/null 2>&1 \
  && ok || bad "C3: project-3 was not seeded as the integer 6: $(cat "$T/req.log")"
grep 'PUT https://jobs.test/api/telegram-topics ' "$T/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.project=="project-2")) | length==1 and (.[0].thread_id==7) and ((.[0].thread_id|type)=="number")' >/dev/null 2>&1 \
  && ok || bad "C3: project-2 was not seeded as the integer 7: $(cat "$T/req.log")"
cmp -s "$T/before-c3.json" "$TOPICS" && ok || bad "C3: the seed path overwrote the file"

# ── C4. worker down: fail-open. File untouched, readers still resolve, ONE ───
#        ALERTS line for the two calls (the client's daily flag).
printf '%s' '{"topics":{"project-3":6,"project-2":7}}' > "$TOPICS"
touch -d "$STALE" "$TOPICS"; cp "$TOPICS" "$T/before-c4.json"
rm -rf "$T/flags"; mkdir -p "$T/flags"; rm -f "$T/logs/ALERTS.log"; clearlog
GOT=$(CURL_MODE=down CURL_RESP="$T/resp-project-3.json" run_orc 'project-3 triage wave done')
[ "$GOT" = 6 ] && ok || bad "C4 orchestrate: an outage must not change the resolved topic (got '$GOT')"
touch -d "$STALE" "$TOPICS"
GOT=$(CURL_MODE=down CURL_RESP="$T/resp-project-3.json" run_poll 7)
case "$GOT" in *"topic project-2"*) ok ;; *) bad "C4 poll-commands: an outage must not change attribution (got '$GOT')" ;; esac
cmp -s "$T/before-c4.json" "$TOPICS" && ok || bad "C4: an outage rewrote the file"
[ "$(count 'harness-jobs unreachable' "$T/logs/ALERTS.log")" -eq 1 ] \
  && ok || bad "C4: want exactly one ALERTS line for two reader calls, got $(cat "$T/logs/ALERTS.log" 2>/dev/null)"

# ── C5. poll-commands resolves BOTH file shapes, with no client at all ───────
#        (exactly tests/tg-attribution-test.sh's shape: root map on disk).
printf '%s' '{"project-3":6}' > "$TOPICS"
GOT=$(run_poll_bare 6)
case "$GOT" in *"topic project-3"*) ok ;; *) bad "C5 root-map shape {\"project-3\":6} must resolve topic project-3 (got '$GOT')" ;; esac
printf '%s' '{"topics":{"project-3":6}}' > "$TOPICS"
GOT=$(run_poll_bare 6)
case "$GOT" in *"topic project-3"*) ok ;; *) bad "C5 nested shape {\"topics\":{\"project-3\":6}} must resolve topic project-3 (got '$GOT')" ;; esac
GOT=$(run_poll_bare 99)
case "$GOT" in *topic*) bad "C5 nested: an unknown thread must name no topic (got '$GOT')" ;; *) ok ;; esac
printf '%s' '{"project-3":6}' > "$TOPICS"
GOT=$(run_poll_bare 99)
case "$GOT" in *topic*) bad "C5 root-map: an unknown thread must name no topic (got '$GOT')" ;; *) ok ;; esac

# ── C6. no readable client on HARNESS: the guard holds, by construction ─────
#        The block is lifted and RUN by sibling suites with whatever HARNESS the
#        caller exported. Pointed at a dir that holds no client, even a STALE
#        file must cost zero requests and still resolve from what is on disk.
mkdir -p "$T/emptyharness"
printf '%s' '{"topics":{"project-3":6}}' > "$TOPICS"; touch -d "$STALE" "$TOPICS"; clearlog
printf '%s' 'project-3 triage wave done' > "$T/m"; printf '%s' '{}' > "$T/m.meta"
GOT=$(env HARNESS="$T/emptyharness" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
          JOBS_BOX=testbox JOBS_RETRIES=0 REQ_LOG="$T/req.log" PATH="$T/fakebin:$PATH" \
          MSGF="$T/m" TG_TOPICS_FILE="$TOPICS" TG_THREAD="" \
          bash -c "$ORC_BLK; printf '%s' \"\$TG_THREAD\"")
[ "$GOT" = 6 ] && ok || bad "C6: with no client on HARNESS the block must still resolve 6 (got '$GOT')"
[ ! -s "$T/req.log" ] && ok || bad "C6: an unreadable client must cost no request, log: $(cat "$T/req.log")"

# ── C7. the sibling suites that lift this block stay off the network ─────────
#        tests/tg-reply-origin-test.sh and tests/tg-outbound-topic-test.sh run
#        these same lines through `bash -c`, which inherits the caller's whole
#        environment. On every box the harness itself drives (validate stages,
#        cron, a session) HARNESS=/root/harness is exported — so an unpinned
#        lift sources the REAL bin/jobs-client.sh, reads the box's real secret,
#        and hits the production coordination worker from a unit test, able to
#        rewrite the box's real state/telegram-topics.json and PUT seed rows
#        into the live D1. Run both suites with HARNESS exported at a
#        harness-shaped dir whose "client" RECORDS every call instead of making
#        it: the record must stay empty, and both suites must still pass.
mkdir -p "$T/spyharness/bin"
cat > "$T/spyharness/bin/jobs-client.sh" <<'SH'
#!/bin/bash
# Not the real client. Sourcing this records the call rather than making it, so
# a suite that reaches for the box's client is caught instead of being obeyed.
telegram_topics_sync() { printf 'telegram_topics_sync %s\n' "$*" >> "$SPY_LOG"; }
SH
: > "$T/spy.log"
for SIB in tg-reply-origin tg-outbound-topic orc-reply-via-console orchestrate-reply-ledger.bh-4995 orchestrate-reply-spool.bh-4995 orchestrate-no-reply.bh-5028; do
  SCRATCH= HARNESS="$T/spyharness" SPY_LOG="$T/spy.log" bash "$DIR/tests/$SIB-test.sh" >/dev/null 2>&1 \
    && ok || bad "C7: tests/$SIB-test.sh must still pass with HARNESS exported"
done
[ ! -s "$T/spy.log" ] && ok \
  || bad "C7: a lifted block reached the box's own client $(wc -l < "$T/spy.log") time(s): $(tr '\n' ' ' < "$T/spy.log")"

# ── C8. C7's list is the WHOLE list ─────────────────────────────────────────
#        The one assertion here about source text, and deliberately so: it is
#        not about the feature (C1-C6 cover that from resolved values, file
#        bytes and request logs) but about WHO ELSE runs these lines. A suite
#        added later that lifts the block by either of its anchors inherits the
#        same escape, so it has to be pinned and named in C7 — this catches that
#        at the moment it is written instead of on a box.
LIFTERS=$(grep -lE "/\^# Outbound per-project topic routing/|/\^TG_TO=/" "$DIR"/tests/*.sh \
  | xargs -n1 basename | sort | tr '\n' ' ')
[ "$LIFTERS" = "orc-reply-via-console-test.sh orchestrate-no-reply.bh-5028-test.sh orchestrate-reply-ledger.bh-4995-test.sh orchestrate-reply-spool.bh-4995-test.sh telegram-topics-sync-test.sh tg-outbound-topic-test.sh tg-reply-origin-test.sh " ] \
  && ok || bad "C8: these suites lift the topic-routing block; pin HARNESS in any C7 does not cover: $LIFTERS"

echo "telegram-topics-sync-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
