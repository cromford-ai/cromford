#!/bin/bash
# tests/ticket-identity-guard-test.sh — one identity per ticket (BH-866).
#
# THE DEFECT THIS PINS. A build's identity, everywhere the fleet dedupes, is the
# KEY: bin/run-build.sh claims its jobs row with `job_open "$PROJECT" "$KEY"
# build …`, and the worker's double-build guard dedupes on
# (project, ticket_id=KEY, kind). The BOARD ticket id rides only in `meta`. So
# on an in-app board, where a decomposed child can carry the title label
# `TK-1766.5` while the board's own key for that ticket is `TK-1789`, the same
# board ticket has TWO identities and both of them build: two plans, two
# executes, two PRs, one ticket.
#
# The guard is a lib every launch path asks BEFORE it spends anything — before
# the Fly enqueue, before the slot lock, before the queue claim — and its answer
# is the existing `BUILD_DEFERRED` (exit 3), which the queue re-offers next tick.
# Refusal needs EVIDENCE: an unreachable ledger with nothing local to go on
# proceeds and says so, because a worker outage must not stop the fleet.
#
# Driven, not grepped: §1 calls the lib, §2 runs the marker block extracted
# VERBATIM from bin/run-build.sh, §3 runs bin/free-slots.sh as the prompts do.
# Run from anywhere: tests/ticket-identity-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The driver is being split into bin/lib/rb/ stage modules (BH-568), and only
# the two suites that EXECUTE it may read it raw. §2 only lifts a marker block
# out of the pipeline text, so it reads the flattened driver like every other
# block-extracting suite.
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/builds" "$H/logs" "$H/flags" "$H/env" "$H/prompts" "$T/fakebin"
cp "$DIR/bin/lib/ticket-identity.sh" "$H/bin/lib/" 2>/dev/null
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/free-slots.sh" "$DIR/bin/count-builds.sh" "$H/bin/"
# jobs-client.sh is a SHIM over bin/lib/jobs/ (BH-1194): it resolves its modules
# off BASH_SOURCE and `exit 1`s the CALLER when one is missing, so the copy
# carries the modules too.
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/build-caps.sh" "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh 2>/dev/null
# BH-7919: source (a2) decides the issues lane through bin/lib/tracker.sh tracker_kind.
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1

# THE PROJECT REGISTRY (§1e). board-api-prefix "-" is the GitHub-Issues lane,
# the same test bin/run-decompose.sh, bin/orphan-reconcile.sh and
# bin/triage-gate.sh apply. FLEET_CONF is set EXPLICITLY: bin/fleet-conf.sh
# falls back to /root/harness/fleet.conf, and a run on the hub would otherwise
# answer these cases from the live fleet instead of this fixture.
#
# widget-os is deliberately ABSENT. Every §1a-d case above and below launches
# that project, and a registry row for it would put the issues-board source in
# front of assertions that are about the other four sources.
cat > "$H/fleet.conf" <<'CONF'
# project     repo             prod                     board-prefix  offset box
issues-os     org/issues-os    https://issues.example   -             5      local
board-os      org/board-os     https://board.example    /api/board    7      local
nopfx-os      org/nopfx-os     https://nopfx.example    -             9      local
CONF
# preplan_key_prefix reads the rendered launch line out of prompts/<project>.md
# — the only place an issues project's KEY prefix is written down.
printf 'setsid /root/harness/bin/run-build.sh issues-os <issue-number> TK-<issue-number> &\n' > "$H/prompts/issues-os.md"
# board-os carries a launch line of the same SHAPE on purpose: the source must
# be gated on the board lane, not on whether a prompt happens to parse.
printf 'setsid /root/harness/bin/run-build.sh board-os <issue-number> AB-<issue-number> &\n' > "$H/prompts/board-os.md"
printf 'this project has never had its launch line rendered\n' > "$H/prompts/nopfx-os.md"

# The two fixtures every stub reads. Rewritten between cases; never a clock.
printf '{"jobs":[]}\n' > "$T/jobs.json"
printf '{"queue":[]}\n' > "$T/queue.json"
printf '200\n' > "$T/queue-http"   # 404 = a worker with no /api/queue at all
# ...and ONE page can be down while the other answers: the queue is asked once
# per status, so `claimed` and `queued` are two separate round trips and either
# of them can be the one that fails. Empty = no per-status override.
: > "$T/queue-http-claimed"; : > "$T/queue-http-queued"
: > "$T/ledger-status.txt"     # empty = the worker has no such row (404)
printf '0\n' > "$T/curl-rc"    # 7 = transport failure, the outage case

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
RC=\$(cat "$T/curl-rc"); [ "\$RC" = 0 ] || exit "\$RC"
URL="\${!#}"; WANT_CODE=0
while [ \$# -gt 0 ]; do case "\$1" in -w) WANT_CODE=1; shift 2 ;; *) shift ;; esac; done
emit() { printf '%s' "\$1"; [ "\$WANT_CODE" = 1 ] && printf '\n%s' "\$2"; printf '\n'; }
case "\$URL" in
  *"/api/jobs"*)
    printf '%s\n' "\$URL" >> "$T/jobs-calls.txt"
    emit "\$(cat "$T/jobs.json")" 200 ;;
  *"/api/queue"*)
    printf '%s\n' "\$URL" >> "$T/queue-calls.txt"
    # The queue is asked once per STATUS. A per-status fixture lets a case put a
    # claimed row and a queued row on the same ticket under different keys; with
    # none, every status sees the one queue.json every other case writes.
    QF="$T/queue.json"
    case "\$URL" in
      *status=claimed*) [ -s "$T/queue-claimed.json" ] && QF="$T/queue-claimed.json" ;;
      *status=queued*)  [ -s "$T/queue-queued.json" ]  && QF="$T/queue-queued.json" ;;
    esac
    # ...and the QUEUE alone can be the thing that is down: an older worker with
    # no /api/queue answers 404 while /api/jobs is perfectly healthy.
    QHTTP=\$(cat "$T/queue-http" 2>/dev/null); [ -n "\$QHTTP" ] || QHTTP=200
    # ...and a PARTIAL outage is a real shape: the claimed page 404s or times
    # out while the queued page answers perfectly, which is the case where this
    # launch's own row is the invisible one.
    case "\$URL" in
      *status=claimed*) [ -s "$T/queue-http-claimed" ] && QHTTP=\$(cat "$T/queue-http-claimed") ;;
      *status=queued*)  [ -s "$T/queue-http-queued" ]  && QHTTP=\$(cat "$T/queue-http-queued") ;;
    esac
    if [ "\$QHTTP" = 200 ]; then emit "\$(cat "\$QF")" 200
    else emit '{"error":"no such route"}' "\$QHTTP"; fi ;;
  *"/api/ledger"*)
    S=\$(cat "$T/ledger-status.txt")
    if [ -n "\$S" ]; then emit "{\"ledger\":{\"status\":\"\$S\"}}" 200
    else emit '{"error":"not found"}' 404; fi ;;
  *) emit '{}' 200 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
# ps stub for count-builds.sh (§3): an idle box unless a fixture says otherwise.
printf '#!/bin/bash\ncat "${PS_FIXTURE:-/dev/null}"\n' > "$T/fakebin/ps"; chmod +x "$T/fakebin/ps"
: > "$T/ps.txt"

export PATH="$T/fakebin:$PATH"
export HARNESS="$H" HARNESS_SECRET=shh JOBS_URL=https://jobs.example JOBS_RETRIES=0
export FLEET_CONF="$H/fleet.conf"
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=/dev/null
if [ -r "$H/bin/lib/ticket-identity.sh" ]; then . "$H/bin/lib/ticket-identity.sh" 2>/dev/null; fi

conflict() { # conflict <project> <tid> <key> -> prints the line, returns the rc
  ticket_identity_conflict "$H" "$1" "$2" "$3" 2>/dev/null
}
rc_of() { conflict "$@" >/dev/null 2>&1; echo $?; }

if ! command -v ticket_identity_conflict >/dev/null 2>&1; then
  bad "bin/lib/ticket-identity.sh must define ticket_identity_conflict — the guard has nothing to ask"
  echo "ticket-identity-guard: $PASS pass, $FAIL fail"; exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# §1a THE KEYMAP — bin/triage-gate.sh already writes id<->key both ways
# ════════════════════════════════════════════════════════════════════════════
printf '{"4711":"AB-12","AB-12":"4711"}\n' > "$H/state/widget-os.keymap.json"
[ "$(rc_of widget-os 4711 AB-7.2)" = 0 ] \
  && ok || bad "the board says ticket 4711 is AB-12 — a launch under the label AB-7.2 is a second identity and must be refused"
L=$(conflict widget-os 4711 AB-7.2)
[ "$(cut -f1 <<<"$L")" = "AB-12" ] && ok || bad "the conflict must name the OWNING key so the operator knows what to launch instead, got: $L"
[ "$(cut -f2 <<<"$L")" = "keymap" ] && ok || bad "the conflict must name its source, got: $L"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "launching under the board's OWN key is the whole point — it must never be refused"
# D17: one normalization, everywhere.
[ "$(rc_of widget-os 4711 ab-12)" = 1 ] \
  && ok || bad "keys compare case-insensitively; 'ab-12' is 'AB-12' and must not read as a second identity"
# A GitHub-issues project hands the issue NUMBER as the id and BH-<n> as the key.
# Those are the same thing and there is nothing to compare.
[ "$(rc_of widget-os '' AB-12)" = 1 ] && ok || bad "an empty ticket id has nothing to conflict with"
[ "$(rc_of widget-os AB-12 AB-12)" = 1 ] && ok || bad "id == key (an issues lane) must skip the guard entirely"
# ...and the SHAPE a GitHub-issues lane actually hands over is `866` + `BH-866`,
# never the same string twice (bin/run-build.sh is called with <ticket-id>
# <KEY>). Those are one identity, so the guard has nothing to look for: it must
# skip before it scans a build tree and before it spends a ledger round trip —
# proved here by the outage, where "I could not look" (rc 2) would be wrong.
printf '7\n' > "$T/curl-rc"
[ "$(rc_of widget-os 866 BH-866)" = 1 ] \
  && ok || bad "an issues-lane launch (866 / BH-866) is one identity — it must return 'nothing conflicts', not 'I could not consult the ledger'"
[ "$(rc_of widget-os 66 BH-866)" = 2 ] \
  && ok || bad "...but 66 is not 866: the skip is the WHOLE key after the prefix, never a partial number — an unrelated id still asks every source"
printf '0\n' > "$T/curl-rc"
rm -f "$H/state/widget-os.keymap.json"
[ "$(rc_of widget-os 4711 AB-7.2)" = 1 ] \
  && ok || bad "no keymap on this box is not evidence of anything — it must not refuse"

# ════════════════════════════════════════════════════════════════════════════
# §1b LOCAL BUILD RECORDS — builds/<project>-<KEY>-<stamp>/job.json
# ════════════════════════════════════════════════════════════════════════════
D="$H/builds/widget-os-AB-7.2-202609180900"
mk_record() { # mk_record <ticket-id> <key> <RESULT line or "">
  for d in "$H/builds/widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done
  mkdir -p "$D"
  jq -nc --arg t "$1" --arg k "$2" '{project:"widget-os",ticket_id:$t,key:$k}' > "$D/job.json"
  [ -n "$3" ] && printf '%s\n' "$3" > "$D/RESULT" || rm -f "$D/RESULT"
  return 0
}

mk_record 4711 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5"
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a sibling key already has an OPEN PR for this ticket — that is the TK-1766.5/TK-1789 double build"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "build-record" ] && [ "$(cut -f3 <<<"$L")" = "pr_created" ] \
  && ok || bad "the build-record conflict must name key, source and state, got: $L"

# THE OTHER HALF OF THIS TICKET: once that PR is closed unmerged, nothing
# shipped and the ticket is launchable again.
printf 'closed\n' > "$T/ledger-status.txt"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a sibling PR ledgered 'closed' is over — pr_closed returns the ticket to the launchable pool"
printf 'abandoned\n' > "$T/ledger-status.txt"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "an abandoned sibling PR is over too"
printf 'merged\n' > "$T/ledger-status.txt"
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] && ok || bad "a sibling PR ledgered merged is still a conflict"
# ...and it is MERGED, not "an open PR". The merge sweep never rewrites a
# build's RESULT, so a merged sibling's record still says PR_CREATED while the
# ledger knows it shipped. Reporting `pr_created` there tells the operator to
# wait for a PR that no longer exists, and hides the TK-1789 case (already
# shipped under another key) behind the weaker sentence.
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f3 <<<"$L")" = "merged" ] \
  && ok || bad "a sibling the sweep already merged must be reported merged, not as an open PR, got: $L"
: > "$T/ledger-status.txt"

touch "$D/SUPERSEDED"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a SUPERSEDED build dir is not a live identity"
rm -f "$D/SUPERSEDED"

mk_record 4711 AB-7.2 "PR_MERGED https://github.com/o/w/pull/5"
L=$(conflict widget-os 4711 AB-12)
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] && [ "$(cut -f3 <<<"$L")" = "merged" ] \
  && ok || bad "the work already SHIPPED under the sibling key — building it again is the TK-1789 case, got: $L"

mk_record 4711 AB-7.2 "PLAN_BLOCKED needs the client"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a blocked sibling build is not an identity holding the ticket"
mk_record 4711 AB-7.2 ""
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a dir with no RESULT is resume-dead-builds.sh's business; liveness comes from the ledger, not from a directory"
mk_record 47110 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "ticket 47110 is not ticket 4711 — the id compare must be exact, never a prefix"
# A rebuild (-r2) or a RESUME re-enters the SAME key. Never a conflict.
mk_record 4711 AB-12 "PR_CREATED https://github.com/o/w/pull/5"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "a -r2 rebuild under the same key must not refuse itself"
[ "$(rc_of widget-os 4711 ab-12)" = 1 ] && ok || bad "...and the same key in another case is still the same key"
for d in "$H/builds/widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done

# ── THE FLY HOP: the stub keeps QUEUED_FLY, the TWIN carries the outcome ─────
# On a Fly-routed project — most of the fleet — the dir this source globs is a
# QUEUED_FLY STUB, and nothing ever rewrites its RESULT
# (bin/queued-fly-relayed.sh:21 depends on it staying that way). The build's
# real outcome lands in the pool TWIN, `builds/pool-<project>-<KEY>-<stamp>/`,
# which carries the PR_CREATED/PR_MERGED line and NO job.json of its own (this
# hub: 524 pool-project-4-* dirs, 0 with a job.json). A source that reads only the
# stub therefore reports `pr_created`/`merged` for NO pool build at all — and
# project-4, where TK-1789 was built after #1592 already existed, is pool-routed.
# The stub↔twin pairing is the one bin/fleet-status-push.sh:218 and
# bin/pipeline-health.sh:259 already walk.
mk_fly() { # mk_fly <ticket-id> <key> <twin RESULT or ""> [SUPERSEDED]
  for d in "$H/builds/widget-os-"* "$H/builds/pool-widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done
  local stub="$H/builds/widget-os-$2-202609180900" twin="$H/builds/pool-widget-os-$2-202609181000"
  mkdir -p "$stub"
  jq -nc --arg t "$1" --arg k "$2" '{project:"widget-os",ticket_id:$t,key:$k}' > "$stub/job.json"
  printf 'QUEUED_FLY %s\n' "$2" > "$stub/RESULT"
  if [ -n "$3" ]; then mkdir -p "$twin"; printf '%s\n' "$3" > "$twin/RESULT"; fi
  [ -n "${4:-}" ] && touch "$twin/SUPERSEDED"
  return 0
}

mk_fly 4711 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5"
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a Fly-routed sibling with an open PR is the same duplicate: the stub says QUEUED_FLY forever and the twin holds the PR line"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "build-record" ] && [ "$(cut -f3 <<<"$L")" = "pr_created" ] \
  && ok || bad "the identity still comes from the stub's job.json, only the RESULT from the twin, got: $L"

mk_fly 4711 AB-7.2 "PR_MERGED https://github.com/o/w/pull/5"
L=$(conflict widget-os 4711 AB-12)
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] && [ "$(cut -f3 <<<"$L")" = "merged" ] \
  && ok || bad "a pool build that SHIPPED under the sibling key is the TK-1789-after-#1592 sequence itself, got: $L"

mk_fly 4711 AB-7.2 ""
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a stub with no twin yet has produced nothing — liveness for that is the ledger's answer, not this source's"

mk_fly 4711 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5" SUPERSEDED
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a SUPERSEDED pool twin is not a live identity, exactly as a SUPERSEDED local build is not"

mk_fly 4711 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5"
printf 'closed\n' > "$T/ledger-status.txt"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "the closed-unmerged terminal must reach the pool twin too — nothing shipped, the ticket is launchable again"
: > "$T/ledger-status.txt"
for d in "$H/builds/widget-os-"* "$H/builds/pool-widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done

# ════════════════════════════════════════════════════════════════════════════
# §1c THE JOBS LEDGER — the only place a LIVE build on another box is visible
# ════════════════════════════════════════════════════════════════════════════
mk_jobs() { # mk_jobs <ticket_key> <meta ticket_id> <kind>
  jq -nc --arg k "$1" --arg t "$2" --arg kind "$3" \
    '{jobs:[{id:"job-1",project:"widget-os",kind:$kind,stage:"plan",box:"box-b",
             status:"running",ticket_id:$k,meta:({ticket_id:$t}|tojson)}]}' > "$T/jobs.json"
}
mk_jobs AB-7.2 4711 build
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a RUNNING build for this board ticket under another key is exactly the duplicate this ticket is about"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "ledger" ] && [ "$(cut -f3 <<<"$L")" = "running" ] \
  && ok || bad "the ledger conflict must name key, source and state, got: $L"
grep -q 'project=widget-os' "$T/jobs-calls.txt" \
  && ok || bad "the running rows must be asked for BY PROJECT — a fleet-wide list is a different question: $(cat "$T/jobs-calls.txt")"
mk_jobs AB-12 4711 build
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "the row under our OWN key is our own claim, not a conflict"
mk_jobs AB-7.2 4711 review
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a running REVIEW row is not a second build — only kind=build holds an identity"
mk_jobs AB-7.2 9999 build
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "another ticket's running build is not this ticket's conflict"
printf '{"jobs":[]}\n' > "$T/jobs.json"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "an empty running list is a real answer: nothing conflicts"

# ── the outage: refusal needs evidence ──────────────────────────────────────
printf '7\n' > "$T/curl-rc"
[ "$(rc_of widget-os 4711 AB-12)" = 2 ] \
  && ok || bad "an unreachable worker with nothing local is 'I could not tell' (rc 2), never a refusal — a D1 outage must not stop every launch on the fleet"
[ -z "$(conflict widget-os 4711 AB-12)" ] \
  && ok || bad "rc 2 prints nothing: there is no conflict to name"
# ...but local evidence still refuses while the worker is down.
mk_record 4711 AB-7.2 "PR_CREATED https://github.com/o/w/pull/5"
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "local evidence must still refuse during an outage — the build record is not the worker's to lose"
for d in "$H/builds/widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done
printf '{"jobs":[]}\n' > "$T/jobs.json"
printf '0\n' > "$T/curl-rc"

# job_builds_running itself: rc 1 and NOTHING printed on a transport failure —
# a partial list read as complete is how a guard says "all clear" during an
# outage (D12).
printf '7\n' > "$T/curl-rc"
OUT=$(job_builds_running widget-os 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] \
  && ok || bad "job_builds_running must answer rc 1 and print nothing when it cannot reach the worker (rc=$RC out='$OUT')"
printf '0\n' > "$T/curl-rc"
mk_jobs AB-7.2 4711 build
OUT=$(job_builds_running widget-os); RC=$?
[ "$RC" = 0 ] && [ "$(cut -f2 <<<"$OUT")" = "AB-7.2" ] && [ "$(cut -f3 <<<"$OUT")" = "4711" ] \
  && ok || bad "job_builds_running must print the row's KEY and its meta ticket id (rc=$RC): $OUT"
printf '{"jobs":[]}\n' > "$T/jobs.json"

# ════════════════════════════════════════════════════════════════════════════
# §1d THE QUEUE — queued-but-not-running, the blind window (BH-1140)
# ════════════════════════════════════════════════════════════════════════════
# On a Fly-routed project — most of the fleet — bin/run-build.sh enqueues at the
# QUEUED_FLY path and `job_open` (the running row §1c reads) only happens on the
# pool machine, much later. In between there is no running row, no pool TWIN
# (§1b answers rc 1 for a stub without one, and must keep doing so), and on a
# board whose list omits `key` no keymap either — so on project-4 a queued ticket had
# ZERO coverage and a second launch built it again. `queue_put "$PROJECT" "$KEY"
# "$TICKET"` already writes the board id on the row, so `queue_list <project>
# queued` can answer it: one call, one more source, same fail-open contract.
#
# AND build_queue IS SHARED. The merge conductor enqueues pool REBASE rows on
# the same table (`mc_pool_rebase_enqueue`, bin/lib/mc/rebase.sh) whose
# `ticket_id` is the PR NUMBER and whose key is `RB-<num>-<head8>`. Board ticket
# ids are integer strings, so an unscoped reader refuses board ticket 1592 the
# moment PR #1592 has a rebase queued — a build refused IN ERROR, which is the
# one failure this lane promises never to produce. §1c is already scoped
# (`job_builds_running` selects `kind == "build"`); this source must be too.
mk_queue() { # mk_queue <ticket_key> <board ticket_id> [status] [meta-json] [fixture] [enqueued_at]
  jq -nc --arg k "$1" --arg t "$2" --arg s "${3:-queued}" --arg m "${4:-}" \
    --arg a "${6:-2026-09-20T00:00:00Z}" \
    '{queue:[ {project:"widget-os",ticket_key:$k,ticket_id:$t,status:$s,
               target:"fly",attempt:1,claimed_by:null,enqueued_at:$a}
              + (if $m == "" then {} else {meta:$m} end) ]}' \
    > "${5:-$T/queue.json}"
}
# TWO rows for one ticket in ONE list — the shape the whole tie-break section is
# about, and the one a single-row fixture cannot express.
mk_queue2() { # mk_queue2 <fixture> <k1> <at1> <k2> <at2> [status] [ticket_id]
  jq -nc --arg k1 "$2" --arg a1 "$3" --arg k2 "$4" --arg a2 "$5" \
    --arg st "${6:-queued}" --arg t "${7:-4711}" \
    '{queue:[ {project:"widget-os",ticket_key:$k1,ticket_id:$t,status:$st,
               target:"fly",attempt:1,claimed_by:null,enqueued_at:$a1},
              {project:"widget-os",ticket_key:$k2,ticket_id:$t,status:$st,
               target:"fly",attempt:1,claimed_by:null,enqueued_at:$a2} ]}' \
    > "$1"
}
: > "$T/queue-calls.txt"

mk_queue AB-7.2 4711
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a sibling key is ALREADY QUEUED for this board ticket — launching a second identity is the duplicate this guard exists to refuse, and between queue_put and pool pickup the queue is the only source that can say so"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "queue" ] && [ "$(cut -f3 <<<"$L")" = "queued" ] \
  && ok || bad "the queue conflict must name key, source and state, got: $L"
grep -q 'project=widget-os' "$T/queue-calls.txt" \
  && ok || bad "the queue must be asked BY PROJECT — a fleet-wide list is a different question: $(cat "$T/queue-calls.txt")"
grep -q 'status=queued' "$T/queue-calls.txt" \
  && ok || bad "...and for the QUEUED rows: $(cat "$T/queue-calls.txt")"
# ...AND for the CLAIMED rows. `queue_claim` runs on the HUB when a pool machine
# is spawned or reused (bin/fly-pool.sh), while `job_open` — the running row §1c
# reads — runs on the MACHINE after boot, clone and the context gate. Between
# those two the row is `claimed`, there is no running row, no twin and no
# keymap: the same blind window one state further along, and asking only for
# `queued` leaves it wide open.
grep -q 'status=claimed' "$T/queue-calls.txt" \
  && ok || bad "the CLAIMED rows must be asked for too — between queue_claim on the hub and job_open on the machine a claimed row is the ONLY evidence the build exists: $(cat "$T/queue-calls.txt")"
# A finished row must never be asked for as an identity, in either direction.
! grep -qE 'status=(done|failed)' "$T/queue-calls.txt" \
  && ok || bad "a done/failed row is a finished attempt, never an identity — the queue must not be asked for them: $(cat "$T/queue-calls.txt")"
# The sentence an operator reads. The generic arm ("already has a queued build")
# is FALSE here — nothing is building yet, that is the entire point of this
# window — so `queued` must carry its own wording, exactly as `board-key` does.
S=$(ticket_identity_say 4711 AB-7.2 queue queued)
grep -q 'AB-7.2' <<<"$S" && grep -q '4711' <<<"$S" && grep -q 'queue' <<<"$S" \
  && ok || bad "the refusal sentence must name the ticket, the owning key and the source, got: $S"
! grep -q 'already has a queued build' <<<"$S" \
  && ok || bad "a queued ticket does not yet HAVE a build — the generic arm renders a claim that is false in this window, got: $S"
# `claimed` is a THIRD claim, and neither of the other two is true of it: a
# machine has taken the row but has not opened its running row yet, so "is
# already queued" is stale and the generic "already has a claimed build" is the
# unworded arm D13 exists to keep out of an operator's face.
S=$(ticket_identity_say 4711 AB-7.2 queue claimed)
grep -q 'AB-7.2' <<<"$S" && grep -q '4711' <<<"$S" && grep -q 'queue' <<<"$S" \
  && ok || bad "the claimed refusal must name the ticket, the owning key and the source, got: $S"
! grep -q 'already has a claimed build' <<<"$S" && ! grep -q 'queued' <<<"$S" \
  && ok || bad "a CLAIMED row is neither the generic arm nor the queued wording — a box has taken it and is booting, got: $S"

# ── everything the queue must NOT refuse ────────────────────────────────────
mk_queue AB-12 4711
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "the queue row under our OWN key is this launch's own enqueue (or a -r2), never a conflict"
mk_queue ab-12 4711
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "...and the same key in another case is still the same key (D17)"
mk_queue AB-7.2 9999
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "another ticket's queued row is not this ticket's conflict"
mk_queue AB-7.2 47110
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "ticket 47110 is not ticket 4711 — the queue id compare must be exact, never a prefix"
# A worker that IGNORES the status parameter degrades to a wider list, never a
# wrong one — the same discipline queue_list's `deferred` filter documents. A
# done or failed row is a FINISHED attempt and holds nothing, whichever list it
# arrives in.
for st in done failed; do
  mk_queue AB-7.2 4711 "$st"
  [ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
    && ok || bad "a queue row in status '$st' is a finished attempt, not an identity — the reader must re-check the column, not trust the filter"
done
# ...and a POOL REBASE row is not a board ticket at all. `mc_pool_rebase_enqueue`
# puts `ticket_id=<PR number>` and `key=RB-<num>-<head8>` on this very table with
# `{"kind":"rebase",…}` in its meta. Board ids are integer strings in the same
# range as PR numbers, so an unscoped reader answers "ticket 1592 is already
# queued for a build under key RB-1592-deadbeef" for a launch that has no
# duplicate anywhere — a refusal in error, every tick, with an instruction an
# operator cannot follow.
for st in queued claimed; do
  mk_queue RB-1592-deadbeef 1592 "$st" '{"kind":"rebase","slug":"widget","pr":1592,"head":"deadbeef01"}'
  [ "$(rc_of widget-os 1592 AB-12)" = 1 ] \
    && ok || bad "a pool REBASE row in status '$st' (ticket_id = the PR NUMBER, key RB-1592-…) must NOT refuse board ticket 1592 — this source has to be scoped to BUILD rows exactly as job_builds_running is, got: $(conflict widget-os 1592 AB-12)"
done
# ...while a row that says it IS a build still refuses. The scoping must be a
# filter on kind, not a filter on "has any meta at all": bin/run-build.sh's
# QMETA carries stack_base/hotfix, bin/blocked-resolver.sh's carries deferrals
# and a note, and neither may be read as "not a build".
mk_queue AB-7.2 4711 queued '{"kind":"build","stack_base":"ticket/bh-866"}'
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a queued row whose meta says kind=build is exactly the duplicate this source exists to catch"
mk_queue AB-7.2 4711 queued '{"stack_base":"ticket/bh-866","hotfix":true}'
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a build row carries NO kind at all (run-build.sh's QMETA is stack_base/hotfix) — a meta-bearing row must not be read as a non-build"
# A row whose ticket_key never made it onto the table holds nothing. With
# IFS=$'\t' an empty field collapses and every later column shifts left, so the
# row cannot be trusted at all — the status re-check is what drops it, and it
# must keep dropping it.
mk_queue "" 4711 queued
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a queue row with no ticket_key names no owning key — it must hold nothing rather than refuse under an empty name"
printf '{"queue":[]}\n' > "$T/queue.json"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] && ok || bad "an empty queue is a real answer: nothing conflicts"

# ── the CLAIMED sub-window: a box took the row and has not opened its own yet ─
# queue_claim runs on the HUB at pool spawn/reuse (bin/fly-pool.sh); job_open
# runs on the MACHINE after boot, clone and the context gate (bin/run-build.sh).
# In between the row is `claimed`, §1c sees no running row, §1b sees a stub with
# no twin and project-4 has no keymap — so a second launch had nothing to stop it.
mk_queue AB-7.2 4711 claimed
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "THE CLAIMED SUB-WINDOW: a row a pool machine has claimed but not yet opened a running row for is a build in flight — a second identity launched into it is the duplicate this guard exists to refuse"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "queue" ] && [ "$(cut -f3 <<<"$L")" = "claimed" ] \
  && ok || bad "a claimed row reports its OWN state — 'queued' is stale the moment a box takes it, got: $L"
[ "$(rc_of widget-os 4711 AB-7.2)" = 1 ] \
  && ok || bad "...and a launch under the claimed row's own key is this build, never a conflict"
# Both at once, under different keys: `claimed` is the later, stronger fact, the
# same ordering rule that makes §1c's `running` win over the queue.
mk_queue AB-9 4711 claimed '' "$T/queue-claimed.json"
mk_queue AB-7.2 4711 queued '' "$T/queue-queued.json"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-9" ] && [ "$(cut -f3 <<<"$L")" = "claimed" ] \
  && ok || bad "a ticket with a CLAIMED row and a QUEUED row under different keys is reported claimed — a box already has that one, got: $L"
scratch_rm "$T/queue-claimed.json"; scratch_rm "$T/queue-queued.json"
printf '{"queue":[]}\n' > "$T/queue.json"

# ── TWO ROWS, ONE TICKET: exactly one of them may ever be refused ───────────
# THE LIVELOCK THIS PINS. The guard block runs TWICE per build: once on the hub
# before the Fly enqueue, and again on the pool MACHINE (fly/builder-runner.sh
# -> bin/run-build.sh), where it sits above `job_open` and above the machine's
# own `queue_claim` — while the HUB already claimed the row when it spawned the
# machine (bin/fly-pool.sh). So on the machine this launch's OWN row reads
# `claimed`, and a reader that refuses on any sibling row refuses the launch
# that is already holding the claim. A machine-side BUILD_DEFERRED is REQUEUED
# by the reap, not closed ("a deferral is REQUEUED, not closed", bin/fly-pool.sh)
# — so a ticket with two rows never builds: claim one, defer on the other,
# requeue, claim the other, defer, until jobs-watchdog's QDEFER_MAX parks both
# `failed` and bin/blocked-resolver.sh abandons both. ~18 machines, zero builds,
# two abandoned records, for a ticket that had ONE legitimate build in it —
# where before this source existed the first claimant built and the second saw
# its running row. Two rows for one ticket is the project-4 TK-1784 / TK-1766.0 pair
# this ticket is named for; a death-requeue beside a deferral-parked duplicate,
# jobs-watchdog's deferral requeue and blocked-resolver's fresh enqueue all
# produce it too.
#
# So a sibling refuses only a launch that is BEHIND it, and a pair in the SAME
# state is settled by a total order both sides compute identically.
printf '{"queue":[]}\n' > "$T/queue.json"
mk_queue AB-7.2 4711 claimed '' "$T/queue-claimed.json"
mk_queue AB-12  4711 queued  '' "$T/queue-queued.json"
[ "$(rc_of widget-os 4711 AB-7.2)" = 1 ] \
  && ok || bad "WE HOLD THE CLAIM: a merely QUEUED sibling is behind this launch and must not refuse it — this is the machine-side guard, where the hub's claim is already on our row, and refusing here livelocks the ticket through requeue -> claim -> defer until both rows are abandoned, got: $(conflict widget-os 4711 AB-7.2)"
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "...while the QUEUED row's own launch still sees the claimed sibling ahead of it and stands down — exactly one of the two, never neither"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f3 <<<"$L")" = "claimed" ] \
  && ok || bad "...and it is reported against the key that holds the claim, got: $L"
scratch_rm "$T/queue-claimed.json"; scratch_rm "$T/queue-queued.json"

# TWO QUEUED ROWS. Neither is further along, so the tie-break decides — and it
# must decide the SAME way from both ends, or both stand down and nothing builds.
printf '{"queue":[]}\n' > "$T/queue.json"
mk_queue2 "$T/queue-queued.json" AB-7.2 2026-09-20T00:00:00Z AB-12 2026-09-20T00:05:00Z
A=$(rc_of widget-os 4711 AB-7.2); B=$(rc_of widget-os 4711 AB-12)
[ "$A$B" = "10" ] \
  && ok || bad "two QUEUED rows for one ticket: the OLDER row (AB-7.2, 00:00) builds and the newer (AB-12, 00:05) stands down — got AB-7.2 rc=$A, AB-12 rc=$B (0=refused); '00' is the livelock where neither ever builds"
mk_queue2 "$T/queue-queued.json" AB-7.2 2026-09-20T00:05:00Z AB-12 2026-09-20T00:00:00Z
A=$(rc_of widget-os 4711 AB-7.2); B=$(rc_of widget-os 4711 AB-12)
[ "$A$B" = "01" ] \
  && ok || bad "...and the order is the TIMESTAMP, not the key: with AB-12 enqueued first it is AB-12 that builds — got AB-7.2 rc=$A, AB-12 rc=$B"
# Equal timestamps (the worker stamps to the second, and two rows filed by one
# tick land on the same one) and absent timestamps must still pick a winner.
for AT in 2026-09-20T00:00:00Z -; do
  mk_queue2 "$T/queue-queued.json" AB-7.2 "$AT" AB-12 "$AT"
  A=$(rc_of widget-os 4711 AB-7.2); B=$(rc_of widget-os 4711 AB-12)
  if [ "$A$B" = "01" ] || [ "$A$B" = "10" ]; then ok; else
    bad "two queued rows stamped '$AT' must still settle on ONE winner — a tie that refuses both is the livelock, and a tie that refuses neither is the duplicate: AB-7.2 rc=$A, AB-12 rc=$B"
  fi
done
# ...and a launch with NO row of its own is behind every row: the hand launch or
# label launch in the blind window is the case this source was written for, and
# the tie-break must not hand it a way through.
mk_queue2 "$T/queue-queued.json" AB-7.2 2026-09-20T00:00:00Z AB-12 2026-09-20T00:05:00Z
[ "$(rc_of widget-os 4711 AB-99)" = 0 ] \
  && ok || bad "a third key has no row of its own — every queued row is ahead of it and must still refuse it, got: $(conflict widget-os 4711 AB-99)"

# TWO CLAIMED ROWS. Two machines already spawned for one ticket: the same
# tie-break, or each defers to the other and both are abandoned.
scratch_rm "$T/queue-queued.json"
mk_queue2 "$T/queue-claimed.json" AB-7.2 2026-09-20T00:00:00Z AB-12 2026-09-20T00:05:00Z claimed
A=$(rc_of widget-os 4711 AB-7.2); B=$(rc_of widget-os 4711 AB-12)
[ "$A$B" = "10" ] \
  && ok || bad "two CLAIMED rows for one ticket: the older claim proceeds and the newer defers, and job_open settles what is left — got AB-7.2 rc=$A, AB-12 rc=$B"
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f1 <<<"$L")" = "AB-7.2" ] && [ "$(cut -f2 <<<"$L")" = "queue" ] && [ "$(cut -f3 <<<"$L")" = "claimed" ] \
  && ok || bad "...and the loser names the claim that won, got: $L"
scratch_rm "$T/queue-claimed.json"; scratch_rm "$T/queue-queued.json"
printf '{"queue":[]}\n' > "$T/queue.json"

# ── the `kind` filter is asked of the JSON, not of the bytes ────────────────
# `{"kind": "build"}` — one space after the colon, what any non-compact writer
# emits — matched the '"kind"' skip arm and the row was read as a non-build, so
# a REAL duplicate was let through silently. No producer writes it that way
# today, which is precisely why it would have sat here unseen.
mk_queue AB-7.2 4711 queued '{"kind": "build", "stack_base": "ticket/bh-866"}'
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "a build row whose meta has a space after the colon is still a build row — the kind test must read the JSON, not glob the bytes, got: $(conflict widget-os 4711 AB-12)"
mk_queue RB-1592-deadbeef 1592 queued '{"kind": "rebase", "pr": 1592}'
[ "$(rc_of widget-os 1592 AB-12)" = 1 ] \
  && ok || bad "...and the same spacing on a REBASE row must still be skipped — this is the refusal-in-error the scoping exists to prevent, got: $(conflict widget-os 1592 AB-12)"
# A meta that MENTIONS kind but cannot be read as one is not evidence of a
# build: an unparseable row must never be the thing that refuses a launch.
mk_queue AB-7.2 4711 queued '{"kind":'
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a half-written meta that mentions kind is not readable evidence — it must not refuse, got: $(conflict widget-os 4711 AB-12)"
printf '{"queue":[]}\n' > "$T/queue.json"

# ── ordering: the ledger's RUNNING is the stronger, later fact ───────────────
mk_queue AB-7.2 4711
mk_jobs AB-9 4711 build
L=$(conflict widget-os 4711 AB-12)
[ "$(cut -f2 <<<"$L")" = "ledger" ] && [ "$(cut -f3 <<<"$L")" = "running" ] \
  && ok || bad "a ticket that is BOTH queued and running must be reported running — 'is already being built' is the stronger claim and the one an operator can act on, got: $L"
printf '{"jobs":[]}\n' > "$T/jobs.json"

# ── the blind window itself: a Fly stub, no twin, no running row ─────────────
mk_fly 4711 AB-7.2 ""
printf '{"queue":[]}\n' > "$T/queue.json"
[ "$(rc_of widget-os 4711 AB-12)" = 1 ] \
  && ok || bad "a stub with no twin and an EMPTY queue is still rc 1 — §1b's contract must not change because a fourth source was added"
mk_queue AB-7.2 4711
L=$(conflict widget-os 4711 AB-12)
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] && [ "$(cut -f2 <<<"$L")" = "queue" ] \
  && ok || bad "THE WINDOW: a Fly stub whose build is still sitting in the queue — no twin, no running row, no keymap — must now refuse the second launch, got: $L"
for d in "$H/builds/widget-os-"* "$H/builds/pool-widget-os-"*; do [ -e "$d" ] && scratch_rm "$d"; done

# ── the outage: a queue it could not read is 'I could not tell', not a refusal ─
printf '{"queue":[]}\n' > "$T/queue.json"
printf '7\n' > "$T/curl-rc"
[ "$(rc_of widget-os 4711 AB-12)" = 2 ] \
  && ok || bad "an unreachable worker with nothing local stays rc 2 with a fourth source in the chain — refusal needs evidence"
[ -z "$(conflict widget-os 4711 AB-12)" ] && ok || bad "rc 2 still prints nothing"
printf '0\n' > "$T/curl-rc"
# ...and THIS source's own fail-open, isolated. A transport failure takes
# /api/jobs down first, so §1c sets `unknown` before the queue is ever asked and
# the case above proves nothing about §1d. A worker that simply has no
# /api/queue route — an older box mid-propagation — answers 404 with the ledger
# perfectly healthy, and that must still be "I could not tell", never a refusal
# and never a silent "nothing conflicts".
printf '404\n' > "$T/queue-http"
[ "$(rc_of widget-os 4711 AB-12)" = 2 ] \
  && ok || bad "a queue that 404s while the ledger is healthy is a source that could not be consulted — rc 2, proceed and say so, got rc=$(rc_of widget-os 4711 AB-12)"
[ -z "$(conflict widget-os 4711 AB-12)" ] \
  && ok || bad "a queue-only outage still prints nothing — refusal needs evidence"
printf '200\n' > "$T/queue-http"
# ...and a PARTIAL outage is the one that can still livelock a ticket. The two
# statuses are two round trips: if `claimed` fails and `queued` answers, the
# claim the HUB took for this very machine is invisible, so our own rank reads
# 0 — "no row of our own", the rank every sibling is ahead of — and a merely
# QUEUED sibling refuses the launch that is holding the claim. The reap requeues
# that deferral rather than closing it, so one transient error per round walks
# the ticket straight back into claim -> defer -> requeue. A page we could not
# read may be holding our own row, so a candidate no further along than that
# page cannot be proven ahead of us and must not refuse.
printf '{"queue":[]}\n' > "$T/queue.json"
mk_queue AB-7.2 4711 queued '' "$T/queue-queued.json"
printf '404\n' > "$T/queue-http-claimed"
[ "$(rc_of widget-os 4711 AB-12)" = 2 ] \
  && ok || bad "the CLAIMED page could not be read, so this launch's own claim is invisible — a merely queued sibling must NOT refuse it (that is the livelock, reopened by one transient error): rc 2, proceed and say so, got rc=$(rc_of widget-os 4711 AB-12) $(conflict widget-os 4711 AB-12)"
[ -z "$(conflict widget-os 4711 AB-12)" ] \
  && ok || bad "...and it prints nothing: a page it could not read is not evidence, got: $(conflict widget-os 4711 AB-12)"
# The fix must stay NARROW. A page that failed only blinds the ranks at or below
# its own: with `queued` down and a CLAIMED sibling on the healthy page, that box
# is ahead of us whatever our own unread row says, and the refusal stands.
: > "$T/queue-http-claimed"; printf '404\n' > "$T/queue-http-queued"
scratch_rm "$T/queue-queued.json"
mk_queue AB-7.2 4711 claimed '' "$T/queue-claimed.json"
L=$(conflict widget-os 4711 AB-12)
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] && [ "$(cut -f3 <<<"$L")" = "claimed" ] \
  && ok || bad "the QUEUED page failing must not blind the guard to a CLAIMED sibling — a box already has that one and is ahead of any row of ours, read or unread, got: $L"
# ...and a row of our own that WAS read still ranks us: the tie-break between two
# queued rows is unchanged by an unread claimed page.
scratch_rm "$T/queue-claimed.json"; : > "$T/queue-http-queued"; printf '404\n' > "$T/queue-http-claimed"
mk_queue2 "$T/queue-queued.json" AB-7.2 2026-09-20T00:00:00Z AB-12 2026-09-20T00:05:00Z
[ "$(rc_of widget-os 4711 AB-12)" = 0 ] \
  && ok || bad "our own QUEUED row was read, so we are ranked and the older sibling is still ahead of us — an unread claimed page must not switch the tie-break off, got: $(conflict widget-os 4711 AB-12)"
[ "$(rc_of widget-os 4711 AB-7.2)" = 2 ] \
  && ok || bad "...and the older row still builds; it answers rc 2 rather than rc 1 only because a page went unread, which is proceed-and-say-so, got rc=$(rc_of widget-os 4711 AB-7.2)"
: > "$T/queue-http-claimed"; scratch_rm "$T/queue-queued.json"
printf '{"queue":[]}\n' > "$T/queue.json"
# ...and the one-identity skip still costs NO round trip: an issues lane hands
# `866` + `BH-866`, which has no second identity in it.
: > "$T/queue-calls.txt"
[ "$(rc_of widget-os 866 BH-866)" = 1 ] && [ ! -s "$T/queue-calls.txt" ] \
  && ok || bad "an issues-lane launch must return before the queue is asked: $(cat "$T/queue-calls.txt")"

# ════════════════════════════════════════════════════════════════════════════
# §1e THE ISSUES-BOARD KEY — derived, because there is no keymap (BH-1139)
# ════════════════════════════════════════════════════════════════════════════
# THE GAP. §1a's keymap is written by bin/triage-gate.sh for BOARD projects; a
# GitHub-Issues project has no board API and never gets one, so that source is
# permanently empty there. §1b/§1c/§1d only see a duplicate once one EXISTS. So
# the FIRST launch under a decomposed child's dotted TITLE LABEL — `TK-2411.2`,
# which bin/run-decompose.sh's issues lane writes into the child's title while
# filing it as issue #2487 — had nothing to refuse it: two plans, two executes,
# two PRs, one issue, on every split.
#
# An issues board needs no keymap: its key for issue N is `<PREFIX>-N` BY
# CONSTRUCTION. run-decompose writes children.txt that way, and
# bin/orphan-reconcile.sh, bin/preplan-candidates.sh, bin/hotfix-seen.sh and
# bin/dep-verify.sh all derive it the same way through `preplan_key_prefix`,
# which reads the rendered launch line in prompts/<project>.md — the one place
# that prefix is written down. So the board's own key is a LOCAL question, and
# this source is asked second, right after the keymap.
: > "$T/jobs-calls.txt"; : > "$T/queue-calls.txt"
[ "$(rc_of issues-os 2487 TK-2411.2)" = 0 ] \
  && ok || bad "issue #2487 filed by a split carries the title label TK-2411.2 — launching it under that label is a second identity for one issue, and on an issues board no keymap will ever say so"
L=$(conflict issues-os 2487 TK-2411.2)
[ "$(cut -f1 <<<"$L")" = "TK-2487" ] \
  && ok || bad "the refusal must name the BOARD's own key — <PREFIX>-<issue number> is what every other lane files this ticket under, got: $L"
[ "$(cut -f2 <<<"$L")" = "issues-key" ] && [ "$(cut -f3 <<<"$L")" = "board-key" ] \
  && ok || bad "the issues-board conflict must name its source and report board-key, got: $L"
# It is a LOCAL question and it is asked before the expensive ones: a mis-keyed
# launch must not pay a build-tree scan and two round trips to be told the key.
[ ! -s "$T/jobs-calls.txt" ] && [ ! -s "$T/queue-calls.txt" ] \
  && ok || bad "the issues-board key is derived locally — it must answer before the ledger and the queue are asked: $(cat "$T/jobs-calls.txt" "$T/queue-calls.txt")"
# The CONTRACT child (.0) is the same label shape and the same duplicate.
[ "$(rc_of issues-os 2486 TK-2411.0)" = 0 ] \
  && ok || bad "the contract child's label TK-2411.0 is a label too — the .0 is not special"
# A NEIGHBOURING issue's key is a second identity exactly as a label is: ticket
# 2487 does not belong to TK-2486, whoever typed it.
L=$(conflict issues-os 2487 TK-2486)
[ "$(rc_of issues-os 2487 TK-2486)" = 0 ] && [ "$(cut -f1 <<<"$L")" = "TK-2487" ] \
  && ok || bad "issue #2487's key is TK-2487 — a launch under TK-2486 is the wrong identity for it, got: $L"

# ── everything it must NOT refuse ───────────────────────────────────────────
[ "$(rc_of issues-os 2487 TK-2487)" = 1 ] \
  && ok || bad "the issue's OWN key is the identity every other lane uses — refusing it would stop the whole project"
[ "$(rc_of issues-os 2487 TK-2487)" = 1 ] \
  && ok || bad "...and the same key in another case is still the same key (D17)"
# AN IN-APP BOARD IS NOT DERIVABLE. Its key for ticket 4711 is whatever the
# board assigned (AB-12, §1a) — deriving AB-4711 there would refuse launches
# naming a key that does not exist anywhere, which is the one failure this lane
# promises never to produce. The gate is the board lane, not the prompt: board-os
# carries a launch line of exactly the same shape.
[ "$(rc_of board-os 4711 AB-7.2)" = 1 ] \
  && ok || bad "an in-app board's key is the board's to assign — this source must be gated on board_prefix '-', not on whether a prompt parses"
# Every other leg fails OPEN and SILENT — never rc 2. A derived key is only
# evidence when every part of the derivation is there.
[ "$(rc_of nopfx-os 2487 TK-2411.2)" = 1 ] \
  && ok || bad "a project whose launch line was never rendered has no prefix to derive from — nothing to say, and nothing to refuse"
[ "$(rc_of widget-os 2487 TK-2411.2)" = 1 ] \
  && ok || bad "a project the registry does not list is not known to be an issues board — the guard proceeds"
[ "$(rc_of issues-os abc TK-2411.2)" = 1 ] \
  && ok || bad "an issues board's ticket id IS the issue number — a non-numeric id derives nothing"
mv "$H/bin/fleet-conf.sh" "$T/fleet-conf-parked.sh"
[ "$(rc_of issues-os 2487 TK-2411.2)" = 1 ] \
  && ok || bad "a box with no fleet-conf.sh cannot tell an issues board from a product board — it proceeds, exactly as a box with no lib does"
mv "$T/fleet-conf-parked.sh" "$H/bin/fleet-conf.sh"
mv "$H/bin/lib/preplan-lib.sh" "$T/preplan-parked.sh"
[ "$(rc_of issues-os 2487 TK-2411.2)" = 1 ] \
  && ok || bad "a box mid-propagation without preplan-lib.sh has no way to read the prefix — it must proceed, not invent one"
mv "$T/preplan-parked.sh" "$H/bin/lib/preplan-lib.sh"
# The sentence an operator reads. `board-key` already has its own wording
# because there may be no second build anywhere yet — this arm must keep it and
# must not claim one exists (D13).
S=$(ticket_identity_say 2487 TK-2487 issues-key board-key)
grep -q 'TK-2487' <<<"$S" && grep -q '2487' <<<"$S" && grep -q 'issues-key' <<<"$S" \
  && ok || bad "the refusal must name the ticket, the board's key and the source, got: $S"
! grep -q 'already has' <<<"$S" \
  && ok || bad "nothing may be building yet — the sentence must not claim a second build exists, got: $S"

# ════════════════════════════════════════════════════════════════════════════
# §2 THE LAUNCH PATH — the marker block, extracted VERBATIM from run-build.sh
# ════════════════════════════════════════════════════════════════════════════
BLOCK="$T/block.sh"
awk '/# >>> ticket identity guard/{f=1;next} /# <<< ticket identity guard/{exit} f' \
  "$RB_ALL" > "$T/block-body.sh"
[ -s "$T/block-body.sh" ] \
  && ok || bad "bin/run-build.sh carries no '# >>> ticket identity guard' block — every launch route enters that script, and it is the only choke point a Fly enqueue also passes"
{
  printf '#!/bin/bash\nset -uo pipefail\n'
  printf 'STAMP() { date -u "+%%Y-%%m-%%d %%H:%%M:%%SZ"; }\n'
  printf 'RESULT() { echo "$*" > "$BUILD/RESULT"; echo "$*"; }\n'
  printf 'ALERTS="$HARNESS/logs/ALERTS.log"\n'
  # run-build.sh resolves HENV at its top (bin/lib/env-path.sh, :26), far above
  # this block, so the extracted body inherits it there and must here too. The
  # real resolver, not a literal: $H/env is what it answers for this fixture.
  printf '. "$HARNESS/bin/lib/env-path.sh" || exit 1\n'
  printf 'HENV=$(harness_env_dir "$HARNESS")\n'
  cat "$T/block-body.sh"
  printf '\necho GUARD_PROCEEDED\n'
} > "$BLOCK"

B="$T/bdir"
drive() { # drive <ticket> <key> [env assignments...]   (DRIVE_PROJECT: widget-os)
  scratch_rm "$B"; mkdir -p "$B"
  local tick="$1" key="$2"; shift 2
  ( env HARNESS="$H" PROJECT="${DRIVE_PROJECT:-widget-os}" TICKET="$tick" KEY="$key" BUILD="$B" \
        HARNESS_SECRET=shh JOBS_URL=https://jobs.example JOBS_RETRIES=0 \
        PATH="$T/fakebin:$PATH" "$@" bash "$BLOCK" ) >"$T/block.out" 2>"$T/block.err"
  echo $?
}

mk_jobs AB-7.2 4711 build
: > "$H/logs/ALERTS.log"; rm -f "$H"/flags/alerted-identity-*
RC=$(drive 4711 AB-12)
[ "$RC" = 3 ] \
  && ok || bad "a refused duplicate exits 3 (BUILD_DEFERRED), which _job_finish parks and the queue re-offers next tick — got rc=$RC, out: $(cat "$T/block.out") $(cat "$T/block.err")"
R=$(cat "$B/RESULT" 2>/dev/null)
case "$R" in
  "BUILD_DEFERRED duplicate identity:"*) ok ;;
  *) bad "the RESULT must open with 'BUILD_DEFERRED duplicate identity:', got: $R" ;;
esac
grep -q 'AB-7.2' <<<"$R" && ok || bad "the refusal must name the key that owns the ticket, got: $R"
grep -q '4711' <<<"$R" && ok || bad "the refusal must name the ticket, got: $R"
grep -qi 'identity' "$B/pipeline.log" \
  && ok || bad "the build record must say why it stopped: $(cat "$B/pipeline.log" 2>/dev/null)"
[ "$(grep -c 'duplicate identity' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "stopping is an alert, not a whisper — exactly one ALERTS line: $(cat "$H/logs/ALERTS.log")"
# D21: bounded. The queue re-offers this ticket every tick; an alert per tick is
# a pager that gets muted.
drive 4711 AB-12 >/dev/null
[ "$(grep -c 'duplicate identity' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the ALERTS line is once per (project, ticket, other key, day) — the ticket is re-offered every tick: $(cat "$H/logs/ALERTS.log")"

# THE SAME REFUSAL FROM THE QUEUE ALONE (BH-1140). The window this closes has
# no running row and no twin, so §2 must prove the block acts on the fourth
# source exactly as it acts on the other three — the block asks the lib, and a
# source that only the lib knows about is worth nothing if the launch path
# renders it differently.
printf '{"jobs":[]}\n' > "$T/jobs.json"
mk_queue AB-7.2 4711
: > "$H/logs/ALERTS.log"; rm -f "$H"/flags/alerted-identity-*
RC=$(drive 4711 AB-12)
[ "$RC" = 3 ] \
  && ok || bad "a duplicate the QUEUE found must defer exactly as one the ledger found does — got rc=$RC, out: $(cat "$T/block.out") $(cat "$T/block.err")"
R=$(cat "$B/RESULT" 2>/dev/null)
case "$R" in
  "BUILD_DEFERRED duplicate identity:"*) grep -q 'AB-7.2' <<<"$R" && ok || bad "the queued refusal must name the owning key, got: $R" ;;
  *) bad "the queue refusal must render the same RESULT head, got: $R" ;;
esac
# ...and the CLAIMED sub-window end to end: a pool machine has the row, its
# running row does not exist yet, and the launch path must defer on that too.
mk_queue AB-7.2 4711 claimed
: > "$H/logs/ALERTS.log"; rm -f "$H"/flags/alerted-identity-*
RC=$(drive 4711 AB-12)
[ "$RC" = 3 ] \
  && ok || bad "a row a pool machine has CLAIMED must defer on the launch path too — that is the window between queue_claim on the hub and job_open on the machine, got rc=$RC, out: $(cat "$T/block.out") $(cat "$T/block.err")"
R=$(cat "$B/RESULT" 2>/dev/null)
case "$R" in
  "BUILD_DEFERRED duplicate identity:"*) grep -q 'AB-7.2' <<<"$R" && ok || bad "the claimed refusal must name the owning key, got: $R" ;;
  *) bad "the claimed refusal must render the same RESULT head, got: $R" ;;
esac
# ...and THE CLAIMANT'S OWN LAUNCH, end to end. This block is what the pool
# MACHINE runs (fly/builder-runner.sh -> bin/run-build.sh), above `job_open` and
# above its own `queue_claim`, while the hub's claim is already on this row. A
# guard that stops here stops the build that holds the claim, the reap requeues
# it, and the ticket livelocks — so the launch path must fall through, not just
# the lib.
mk_queue AB-7.2 4711 claimed '' "$T/queue-claimed.json"
mk_queue AB-12  4711 queued  '' "$T/queue-queued.json"
: > "$H/logs/ALERTS.log"; rm -f "$H"/flags/alerted-identity-*
RC=$(drive 4711 AB-7.2)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "the box that HOLDS the claim must build: a queued sibling is behind it, and deferring here is the livelock the reap turns into ~18 machines and zero builds (rc=$RC, RESULT='$(cat "$B/RESULT" 2>/dev/null)')"
grep -q GUARD_PROCEEDED "$T/block.out" \
  && ok || bad "...and fall through to the rest of the pipeline: $(cat "$T/block.out") $(cat "$T/block.err")"
scratch_rm "$T/queue-claimed.json"; scratch_rm "$T/queue-queued.json"
printf '{"queue":[]}\n' > "$T/queue.json"

# THE ISSUES-BOARD LABEL, END TO END (BH-1139). No keymap, no build record, no
# running row, no queue row — the first launch of a freshly filed child, which
# is the launch that has always got through. The block must defer on the derived
# key exactly as it defers on the other sources, or the lib's answer is worth
# nothing on the lane it was written for.
printf '{"jobs":[]}\n' > "$T/jobs.json"
: > "$H/logs/ALERTS.log"; rm -f "$H"/flags/alerted-identity-*
RC=$(DRIVE_PROJECT=issues-os drive 2487 TK-2411.2)
[ "$RC" = 3 ] \
  && ok || bad "a child launched under its dotted title label on an issues board must defer — got rc=$RC, out: $(cat "$T/block.out") $(cat "$T/block.err")"
R=$(cat "$B/RESULT" 2>/dev/null)
case "$R" in
  "BUILD_DEFERRED duplicate identity:"*) grep -q 'TK-2487' <<<"$R" && ok || bad "the refusal must name the issue's own key so the operator can relaunch under it, got: $R" ;;
  *) bad "the issues-board refusal must render the same RESULT head, got: $R" ;;
esac
RC=$(DRIVE_PROJECT=issues-os drive 2487 TK-2487)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "...and the issue's own key must launch on that same project (rc=$RC, RESULT='$(cat "$B/RESULT" 2>/dev/null)')"

mk_jobs AB-7.2 4711 build

# ── everything that must NOT refuse ────────────────────────────────────────
RC=$(drive 4711 AB-7.2)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "the owning key must launch (rc=$RC, RESULT='$(cat "$B/RESULT" 2>/dev/null)')"
grep -q GUARD_PROCEEDED "$T/block.out" && ok || bad "...and fall through to the rest of the pipeline"
RC=$(drive 4711 AB-12 TICKET_IDENTITY_GUARD=0)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "TICKET_IDENTITY_GUARD=0 must switch the guard off (rc=$RC)"
grep -qi 'identity guard' "$B/pipeline.log" \
  && ok || bad "...and say so once, so an operator can tell 'off' from 'found nothing': $(cat "$B/pipeline.log" 2>/dev/null)"
# THE KNOB'S DOCUMENTED HOME IS env/global.env (env-templates/global.env.example,
# docs/verification-map/ticket-identity.md) — and bin/run-build.sh does not
# source that file until ~300 lines BELOW this block. A guard that reads only
# the environment has a kill switch that does nothing where it is documented to
# be set, which is the worst shape a kill switch can have: an operator turns it
# off, the fleet keeps refusing, and nothing says why.
printf 'TICKET_IDENTITY_GUARD=0\n' > "$H/env/global.env"
RC=$(drive 4711 AB-12)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "TICKET_IDENTITY_GUARD=0 in env/global.env must switch the guard off — that file is the only place the docs tell an operator to set it (rc=$RC)"
rm -f "$H/env/global.env"
RC=$(drive 4711 AB-12)
[ "$RC" = 3 ] \
  && ok || bad "...and with the knob absent the guard is on, exactly as its default says (rc=$RC)"
mv "$H/bin/lib/ticket-identity.sh" "$T/lib-parked.sh"
RC=$(drive 4711 AB-12)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "a box whose lib has not propagated yet must behave exactly as it does today (rc=$RC)"
mv "$T/lib-parked.sh" "$H/bin/lib/ticket-identity.sh"
# rc 2 (could not consult) proceeds, and says what it could not read.
printf '7\n' > "$T/curl-rc"
RC=$(drive 4711 AB-12)
[ "$RC" = 0 ] && [ ! -e "$B/RESULT" ] \
  && ok || bad "an unreachable ledger must not stop a launch (rc=$RC)"
grep -qi 'could not consult' "$B/pipeline.log" \
  && ok || bad "...and the record must say the guard ran blind: $(cat "$B/pipeline.log" 2>/dev/null)"
printf '0\n' > "$T/curl-rc"

# ════════════════════════════════════════════════════════════════════════════
# §3 bin/free-slots.sh — the command the in-app prompts run before a launch
# ════════════════════════════════════════════════════════════════════════════
free() { ( export PATH="$T/fakebin:$PATH" HARNESS="$H" PS_FIXTURE="$T/ps.txt" \
             HARNESS_SECRET=shh JOBS_URL=https://jobs.example JOBS_RETRIES=0
           bash "$H/bin/free-slots.sh" "$@" 2>/dev/null ); }
printf 'BUILD_SLOTS=2\n' > "$H/env/global.env"
mk_jobs AB-7.2 4711 build

OUT=$(free widget-os 4711 AB-12)
[ "$(awk '{print $1}' <<<"$OUT")" = 0 ] \
  && ok || bad "a duplicate identity leaves ZERO slots for this launch, whatever the box has free: '$OUT'"
grep -q 'identity:' <<<"$OUT" \
  && ok || bad "...and the parenthetical must say 'identity:', or the prompt cannot tell it from a busy box: '$OUT'"
grep -q 'AB-7.2' <<<"$OUT" && ok || bad "...and must name the owning key: '$OUT'"

# A FLY-ROUTED PROJECT MUST BE REFUSED TOO. The fly early return sits above the
# slot arithmetic, so a guard placed after it would let every pool-routed
# duplicate through — which is most of the fleet.
touch "$H/flags/builder-fly-widget-os"
OUT=$(free widget-os 4711 AB-12)
[ "$(awk '{print $1}' <<<"$OUT")" = 0 ] \
  && ok || bad "the identity refusal must come BEFORE the fly early return — a pool launch duplicates just as well: '$OUT'"
OUT=$(free widget-os 4711 AB-7.2)
grep -qi 'fly' <<<"$OUT" \
  && ok || bad "the OWNING key on a fly-routed project must still get today's answer: '$OUT'"
rm -f "$H/flags/builder-fly-widget-os"

# NO TICKET ARGS = byte-for-byte today's answer, for the callers that pass one.
BASE_ANSWER=$(free widget-os)
mv "$H/bin/lib/ticket-identity.sh" "$T/lib-parked.sh"
[ "$(free widget-os)" = "$BASE_ANSWER" ] \
  && ok || bad "the one-arg form must be untouched: '$BASE_ANSWER' vs '$(free widget-os)'"
[ "$(free widget-os 4711 AB-12)" = "$BASE_ANSWER" ] \
  && ok || bad "with no lib on the box, free-slots must answer exactly as it does today: '$(free widget-os 4711 AB-12)'"
mv "$T/lib-parked.sh" "$H/bin/lib/ticket-identity.sh"
[ "$(free | awk '{print $1}')" = 2 ] \
  && ok || bad "the box-wide question still answers: '$(free)'"

echo "ticket-identity-guard: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
