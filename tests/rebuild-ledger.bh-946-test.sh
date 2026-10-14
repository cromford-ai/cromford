#!/bin/bash
# tests/rebuild-ledger.bh-946-test.sh — BH-487.0, the CONTRACT slice: the rebuild
# ledger on the blocked-resolver state row, the wait fields, `queue_row`, and the
# two ticket-key-cache hooks the resolver now calls.
#
# WHY THIS IS THE TEST THAT MATTERS. Nothing on this branch WRITES a ledger yet —
# the rung (BH-487.1) and the key cache (BH-487.2) land in the siblings. So the
# only things that can go wrong here are the two that are silent:
#
#   1. the ledger functions answer the wrong thing about ABSENCE. A legacy row
#      has no `rebuild_jobs` at all and must read `null` ("use the counter cap"),
#      while a row with an EMPTY ledger must read `0`. Collapse those two into
#      zero and the sibling's cap lets an already-capped ticket rebuild again.
#   2. the resolver sources the lib SOFTLY, or the hooks are not actually wired.
#      A soft source means a box mid-sync runs the ladder with the ledger
#      functions undefined, silently back on the bare counter; an unwired hook
#      means #948's cache never fills. Both are invisible until a rebuild loops.
#
# So sections 1-6 drive the REAL functions (the row shape comes from the
# resolver's own `br_file`/`br_load`, extracted, never paraphrased), and sections
# 7-8 drive the REAL bin/blocked-resolver.sh end to end from a scratch $HARNESS:
# the hard source is proven by DELETING the lib and reading the exit code, and
# the hooks are proven by replacing the lib with a recorder and asserting the
# lines the run appended.
# Run from anywhere: tests/rebuild-ledger.bh-946-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "rebuild-ledger.bh-946-test: SKIPPED — jq is required"; exit 0; }

# ════════════════════════════════════════════════════════════════════════════
# Fixture for 1-4 and 6: the lib IN PROCESS, over the resolver's own row shape.
# br_file and br_load are extracted from bin/blocked-resolver.sh rather than
# re-written here — a fresh row's fields (outcome:"", the counters) are the
# lane's contract, and a paraphrase of them would pass while the lane changed.
# ════════════════════════════════════════════════════════════════════════════
ST="$T/st"; mkdir -p "$ST"
# The clock is PINNED: every `at`/`updated` this suite asserts is this literal.
STAMP() { printf '2026-09-19 00:00:00Z'; }
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
{
  grep -m1 '^br_file()' "$T/br-corpus.sh"
  awk '$0 ~ /^br_load\(\)/ {f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh"
} > "$T/rowlib.sh"
grep -q 'br_file()' "$T/rowlib.sh" && grep -q 'br_load()' "$T/rowlib.sh" && ok \
  || bad "could not extract br_file/br_load from bin/blocked-resolver.sh — sections 1-4 would test a paraphrase"
# shellcheck source=/dev/null
. "$T/rowlib.sh"
[ -r "$DIR/bin/lib/rebuild-ledger.sh" ] && ok || bad "bin/lib/rebuild-ledger.sh is missing"
# shellcheck source=/dev/null
. "$DIR/bin/lib/rebuild-ledger.sh" || bad "bin/lib/rebuild-ledger.sh does not source"
ROWJSON() { cat "$ST/tproj/$1.json" 2>/dev/null; }

J1='TK-9@2026-09-18 22:00:00Z'
J2='TK-9@2026-09-18 23:00:00Z'

# ══ 1. br_jobs_count: ABSENT IS NOT ZERO ════════════════════════════════════
# This is the whole reason the ledger is a list and not a counter. `null` means
# "this row predates the ledger, keep counting on `rebuilds`"; `0` means "the
# ledger is here and empty", which is a different instruction to the sibling.
OUT=$(br_jobs_count '{}')
[ "$OUT" = null ] && ok || bad "br_jobs_count on a row with no ledger must print null, got '$OUT'"
OUT=$(br_jobs_count '{"rebuild_jobs":[]}')
[ "$OUT" = 0 ] && ok || bad "br_jobs_count on an EMPTY ledger must print 0, got '$OUT'"
OUT=$(br_jobs_count '{"rebuild_jobs":[{"id":"a"},{"id":"b"}]}')
[ "$OUT" = 2 ] && ok || bad "br_jobs_count on a two-job ledger must print 2, got '$OUT'"
OUT=$(br_jobs_count "$(br_load tproj tproj-TK-9)")
[ "$OUT" = null ] && ok || bad "a FRESH resolver row carries no ledger, so br_jobs_count must print null, got '$OUT'"
OUT=$(br_jobs_count 'not json')
[ -z "$OUT" ] && ok || bad "br_jobs_count on malformed json must print nothing, got '$OUT'"

# ══ 2. br_job_add: one entry per job id, for ever ═══════════════════════════
# The resolver re-reads the same live row every ten minutes. Without the dedupe
# a ticket waiting on ONE queued rebuild would count a new job on every tick and
# burn its cap in an hour.
br_job_add tproj tproj-TK-9 "$J1" '2026-09-18 22:00:00Z' \
  || bad "br_job_add exited nonzero on a fresh row"
br_job_add tproj tproj-TK-9 "$J1" '2026-09-18 22:00:00Z' \
  || bad "br_job_add exited nonzero on the repeat"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs|length')
[ "$OUT" = 1 ] && ok || bad "the same job id added twice must leave ONE entry, got '$OUT'"
br_job_add tproj tproj-TK-9 "$J2" '2026-09-18 23:00:00Z'
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs|length')
[ "$OUT" = 2 ] && ok || bad "a SECOND job id must append, got length '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs[0].id')
[ "$OUT" = "$J1" ] && ok || bad "the first entry must keep its id, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs[0].enqueued_at')
[ "$OUT" = '2026-09-18 22:00:00Z' ] && ok \
  || bad "the dedupe must keep the FIRST write's enqueued_at, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs[0].at')
[ "$OUT" = '2026-09-19 00:00:00Z' ] && ok || bad ".at must be the resolver's STAMP, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.updated')
[ "$OUT" = '2026-09-19 00:00:00Z' ] && ok || bad ".updated must be the resolver's STAMP, got '$OUT'"
OUT=$(wc -l < "$ST/tproj/tproj-TK-9.json")
[ "$OUT" = 1 ] && ok || bad "the row must stay ONE line of json (br_load cats it), got $OUT lines"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.project + "/" + .rkey')
[ "$OUT" = "tproj/tproj-TK-9" ] && ok || bad "br_job_add must write through br_load's row shape, got '$OUT'"
br_job_add tproj tproj-TK-9 'TK-9@local~1' ''
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs[2].enqueued_at')
[ "$OUT" = '-' ] && ok || bad "an absent enqueued_at must store '-', got '$OUT'"
# and back to two, so section 3's expected suffix is exact
TMPJ=$(ROWJSON tproj-TK-9 | jq -c '.rebuild_jobs = [.rebuild_jobs[0], .rebuild_jobs[1]]')
printf '%s\n' "$TMPJ" > "$ST/tproj/tproj-TK-9.json"

# ══ 3. br_jobs_why: the suffix the ABANDONED alert prints ═══════════════════
WHY=$(br_jobs_why '{}'); RC=$?
[ "$RC" = 0 ] && ok || bad "br_jobs_why on a row with no ledger must be rc 0, got $RC"
[ -z "$WHY" ] && ok || bad "br_jobs_why on a row with no ledger must print nothing, got '$WHY'"
ROW=$(ROWJSON tproj-TK-9)
WHY=$(br_jobs_why "$ROW"); RC=$?
[ "$RC" = 0 ] && ok || bad "br_jobs_why on a two-job row must be rc 0, got $RC"
[ "$WHY" = " (jobs: $J1, $J2)" ] && ok \
  || bad "br_jobs_why must print ' (jobs: <id>, <id>)' with its leading space, got '$WHY'"
WHY=$(br_jobs_why 'not json'); RC=$?
[ "$RC" = 0 ] && ok || bad "br_jobs_why on malformed json must still be rc 0, got $RC"
[ -z "$WHY" ] && ok || bad "br_jobs_why on malformed json must print nothing, got '$WHY'"
OUT=$(br_jobs_count "$ROW")
[ "$OUT" = 2 ] && ok || bad "the row section 3 read must still count 2, got '$OUT'"

# ══ 4. br_set_wait: a wait is a FIELD, never an outcome ═════════════════════
# br_from_rebuilds skips a row whose outcome is set. If a wait wrote one, the
# waiting ticket would drop out of the lane and never be re-read.
br_set_wait tproj tproj-TK-9 "$J1" || bad "br_set_wait exited nonzero"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.wait')
[ "$OUT" = REBUILD_WAIT ] && ok || bad "br_set_wait must set wait=REBUILD_WAIT, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.wait_job')
[ "$OUT" = "$J1" ] && ok || bad "br_set_wait must set wait_job to the job id, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.outcome')
[ "$OUT" = "" ] && ok || bad "br_set_wait must NOT touch outcome, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.rebuild_jobs|length')
[ "$OUT" = 2 ] && ok || bad "br_set_wait must leave the ledger alone, got length '$OUT'"
br_set_wait tproj tproj-TK-9 -
OUT=$(ROWJSON tproj-TK-9 | jq -r '.wait + "/" + .wait_job')
[ "$OUT" = "-/-" ] && ok || bad "br_set_wait <key> - must clear BOTH fields, got '$OUT'"
br_set_wait tproj tproj-TK-9 "$J2"
br_set_wait tproj tproj-TK-9
OUT=$(ROWJSON tproj-TK-9 | jq -r '.wait + "/" + .wait_job')
[ "$OUT" = "-/-" ] && ok || bad "br_set_wait with NO third arg must clear both fields, got '$OUT'"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.outcome')
[ "$OUT" = "" ] && ok || bad "clearing a wait must not touch outcome, got '$OUT'"
# A row the ladder has already terminated: set and clear must both leave it.
printf '%s\n' "$(ROWJSON tproj-TK-9 | jq -c '.outcome="ABANDONED"')" > "$ST/tproj/tproj-TK-9.json"
br_set_wait tproj tproj-TK-9 "$J1"
OUT=$(ROWJSON tproj-TK-9 | jq -r '.outcome')
[ "$OUT" = ABANDONED ] && ok || bad "br_set_wait must not overwrite an ABANDONED outcome, got '$OUT'"
br_set_wait tproj tproj-TK-9 -
OUT=$(ROWJSON tproj-TK-9 | jq -r '.outcome')
[ "$OUT" = ABANDONED ] && ok || bad "clearing a wait must not overwrite an ABANDONED outcome, got '$OUT'"

# ══ 5. queue_row, through the REAL bin/jobs-client.sh ══════════════════════
# The three answers have to stay apart: a row, "the worker answered and there is
# no row", and "the worker is down". A caller that read an outage as "no row"
# would decide the rebuild never happened and enqueue a second one.
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
  empty)  printf '{"queue":[]}\n200\n'; exit 0 ;;
  notfound) printf '{"error":"no such row"}\n404\n'; exit 0 ;;
esac
printf '%s\n200\n' '{"queue":[{"status":"claimed","enqueued_at":"2026-09-18 22:00:00Z","claimed_by":"pool-3","reason":"RESULT_MALFORMED\nline two"}]}'
EOF
chmod +x "$T/fakebin/curl"
QENV() { # QENV <curl-mode> — the shared environment of every section-5 call
  export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
         HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
         REQ_SINK="$T/req.log" CURL_MODE="$1"
}
SOURCED() { # SOURCED <curl-mode> <args...> — queue_row as the resolver calls it
  local mode="$1"; shift
  : > "$T/req.log"
  ( QENV "$mode"; . "$T/h/bin/jobs-client.sh" 2>/dev/null; queue_row "$@" )
}
CLI() { # CLI <curl-mode> <args...> — queue-row as an operator runs it
  local mode="$1"; shift
  : > "$T/req.log"
  ( QENV "$mode"; bash "$T/h/bin/jobs-client.sh" "$@" 2>/dev/null )
}
reqs() { cat "$T/req.log" 2>/dev/null; }

WANT=$(printf 'claimed\t2026-09-18 22:00:00Z\tpool-3\t-\tRESULT_MALFORMED line two')
OUT=$(SOURCED ok tproj TK-9); RC=$?
[ "$RC" = 0 ] && ok || bad "queue_row on a live row must be rc 0, got $RC"
[ "$OUT" = "$WANT" ] && ok || bad "queue_row printed '$OUT', want '$WANT'"
reqs | grep -q '/api/queue?project=tproj&key=TK-9&limit=1$' \
  && ok || bad "queue_row must ask the queue for exactly that key: $(reqs)"

OUT=$(SOURCED empty tproj TK-9); RC=$?
[ "$RC" = 2 ] && ok || bad "an empty queue must be rc 2 (a real answer), got $RC"
[ -z "$OUT" ] && ok || bad "an empty queue must print nothing, got '$OUT'"
OUT=$(SOURCED notfound tproj TK-9); RC=$?
[ "$RC" = 2 ] && ok || bad "a 404 must be rc 2, got $RC"
[ -z "$OUT" ] && ok || bad "a 404 must print nothing, got '$OUT'"

OUT=$(SOURCED down tproj TK-9); RC=$?
[ "$RC" = 1 ] && ok || bad "an unreachable worker must be rc 1, NEVER rc 2, got $RC"
[ -z "$OUT" ] && ok || bad "an outage must print nothing a caller could parse as a row, got '$OUT'"
OUT=$(SOURCED err500 tproj TK-9); RC=$?
[ "$RC" = 1 ] && ok || bad "a 500 must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "a 500 must print nothing, got '$OUT'"

OUT=$(SOURCED ok tproj); RC=$?
[ "$RC" = 1 ] && ok || bad "queue_row with no key must be rc 1, got $RC"
[ -z "$(reqs)" ] && ok || bad "queue_row with no key must make NO request: $(reqs)"

# The production entry point: the CLI verb an operator actually types.
OUT=$(CLI ok queue-row tproj TK-9); RC=$?
[ "$RC" = 0 ] && ok || bad "the queue-row verb must exit 0 on a live row, got $RC"
[ "$OUT" = "$WANT" ] && ok || bad "the queue-row verb printed '$OUT', want '$WANT'"
CLI empty queue-row tproj TK-9 >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "the queue-row verb must exit 2 on an empty queue, got $RC"
CLI down queue-row tproj TK-9 >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "the queue-row verb must exit 1 on an outage, got $RC"
USAGE=$( ( QENV ok; bash "$T/h/bin/jobs-client.sh" no-such-verb ) 2>&1 )
grep -q 'queue-row <project> <key>' <<<"$USAGE" \
  && ok || bad "queue-row is missing from the usage string"
grep -q 'queue-status <project> <key>' <<<"$USAGE" \
  && ok || bad "queue-status fell out of the usage string"

# ══ 6. The two hooks are REAL (BH-487.2) ════════════════════════════════════
# The signatures are still this slice's contract, and the bodies behind them are
# the ticket-key cache. The put writes ONE file, beside the row and never a
# *.json; the sync answers the derived key and, with none, whatever the cache
# holds — `p/r` has no cache here, so it answers "-".
BEFORE=$(find "$ST" -type f | sort)
br_tkey_put tproj tproj-TK-9 TK-9; RC=$?
[ "$RC" = 0 ] && ok || bad "br_tkey_put must be rc 0, got $RC"
[ "$(cat "$ST/tproj/tproj-TK-9.tkey" 2>/dev/null)" = TK-9 ] && ok \
  || bad "br_tkey_put must cache the key beside the row, got '$(cat "$ST/tproj/tproj-TK-9.tkey" 2>/dev/null)'"
AFTER=$(find "$ST" -type f | sort)
[ "$AFTER" = "$(printf '%s\n%s\n' "$BEFORE" "$ST/tproj/tproj-TK-9.tkey" | sort)" ] && ok \
  || bad "br_tkey_put must add exactly one file: $AFTER"
OUT=$(br_tkey_sync p r TK-9)
[ "$OUT" = TK-9 ] && ok || bad "br_tkey_sync must echo the derived key back, got '$OUT'"
OUT=$(br_tkey_sync p r '')
[ "$OUT" = - ] && ok || bad "br_tkey_sync with an empty key and no cache must print -, got '$OUT'"
OUT=$(br_tkey_sync p r)
[ "$OUT" = - ] && ok || bad "br_tkey_sync with no key at all must print -, got '$OUT'"

# ════════════════════════════════════════════════════════════════════════════
# Fixture for 7-8: the REAL bin/blocked-resolver.sh, run from a scratch $HARNESS.
# ════════════════════════════════════════════════════════════════════════════
H="$T/rh"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/rbin" "$T/rrepos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# gh answers an EMPTY head branch (the BH-614 shape: discovery carries no key)
# and a title that does, so br_one has to derive — which is where br_tkey_put is.
cat > "$T/rbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # The PR reads are REST (#783). The branch is blank and the title carries the
  # key, which is the case this file is about: the fixture files below say so.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)            printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json headRefName"*)  echo "" ;;
  *"--json title"*)        echo "TK-9: nav anchors" ;;
  *"--json state"*)        echo OPEN ;;
  *"pr list"*)             echo "" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/rbin/gh"
: > "$T/prbranch"; : > "$T/prhead"; echo OPEN > "$T/prstate"
printf 'TK-9: nav anchors' > "$T/prtitle"
: > "$T/closed.txt"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"; chmod +x "$T/rbin/flock"
: > "$T/gh.txt"; : > "$T/closed.txt"
export PATH="$T/rbin:$PATH"
export GH_TOKEN=""
RRUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/rrepos" \
             bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>>"$T/run.err" ) ; }

# One parked PR, in the conductor's own row shape, so every run below has real
# work to do — a tick with nothing to say logs nothing, and section 7's "no tick
# ran" assertion would then hold whether the lane refused or not.
# 1758240000 is a literal epoch: the `since` column is read but never compared.
printf 'o/tproj#9\tBLOCKED_HUMAN\t1758240000\tabc123\tabc123\t-\thead-not-reapproved\thttps://github.com/o/tproj/pull/9\n' \
  > "$H/state/merge-conductor/pr-state.tsv"
# Observe mode: the ladder classifies and logs, and acts on nothing.
touch "$H/flags/blocked-resolver-observe"

# ══ 7. THE SOURCE IS HARD, proven by artifact ══════════════════════════════
# A soft `[ -r ] &&` guard would leave a mid-sync box running the ladder with
# br_jobs_count undefined — silently back on the bare counter once #947 reads
# it. The only way to prove hardness is to take the lib away.
scratch_rm "$H/bin/lib/rebuild-ledger.sh"
: > "$T/run.err"; : > "$T/run.log"
RRUN tproj; RC=$?
[ "$RC" = 1 ] && ok || bad "the resolver must EXIT 1 without bin/lib/rebuild-ledger.sh, got $RC"
grep -q 'bin/lib/rebuild-ledger.sh' "$T/run.err" \
  && ok || bad "the refusal must name the missing lib on stderr: $(cat "$T/run.err")"
[ ! -s "$H/logs/blocked-resolver.log" ] \
  && ok || bad "the resolver ran a tick without the ledger: $(cat "$H/logs/blocked-resolver.log")"
cp "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
: > "$T/run.err"
RRUN tproj; RC=$?
[ "$RC" = 0 ] && ok || bad "with the lib present the resolver must exit 0, got $RC: $(tail -3 "$T/run.err")"
# ...and it DID tick on the same fixture, which is what gives the assertion
# above its teeth: an empty log is the refusal, not a quiet lane.
[ -s "$H/logs/blocked-resolver.log" ] && ok \
  || bad "the run with the lib logged nothing, so 'no tick line' proved nothing"

# ══ 8. BOTH HOOKS ARE WIRED, proven by artifact ════════════════════════════
# The lib on the scratch box is replaced by a RECORDER over the real one: the
# real bodies still load, and every call the resolver makes lands in a file.
cat > "$H/bin/lib/rebuild-ledger.sh" <<EOF
. "$DIR/bin/lib/rebuild-ledger.sh"
br_tkey_put()  { printf '%s\n' "\$*" >> "$T/tkey-put.txt"; }
br_tkey_sync() { printf '%s\n' "\$*" >> "$T/tkey-sync.txt"; printf '%s' "\${3:--}"; }
EOF
: > "$T/tkey-put.txt"; : > "$T/tkey-sync.txt"
: > "$T/run.err"
RRUN tproj; RC=$?
[ "$RC" = 0 ] && ok || bad "the observe tick exited $RC: $(tail -3 "$T/run.err")"
grep -qx 'tproj o-tproj-9 -' "$T/tkey-sync.txt" && ok \
  || bad "br_conductor_emit never called br_tkey_sync on the sanitized rkey: $(cat "$T/tkey-sync.txt")"
grep -qx 'tproj o-tproj-9 TK-9' "$T/tkey-put.txt" && ok \
  || bad "br_one never called br_tkey_put with the derived key: $(cat "$T/tkey-put.txt")"
[ ! -s "$T/closed.txt" ] && ok || bad "observe mode acted on the PR: $(cat "$T/closed.txt")"

echo "rebuild-ledger.bh-946-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
