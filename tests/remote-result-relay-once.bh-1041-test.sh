#!/bin/bash
# tests/remote-result-relay-once.bh-1041-test.sh — one finished remote build
# reaches the owning box's sweep EXACTLY ONCE, and "the ledger could not be
# asked" is never spent as "the ledger said no".
#
# WHAT IS ACTUALLY AT RISK, which is what this file drives:
#   * A SECOND COMMENT ON A CLIENT'S TICKET. A relay json and a ledger row
#     describe one build through two doors. They were deduped by comparing the
#     RESULT LINE, and the line diverges routinely — the pool truncates it to
#     200 bytes, the pr-verify gate rewrites word 1, the builder appends its
#     close-out marker after the row was written. Every divergence was a second
#     staged dir and a second close-out. The identity is now the MACHINE'S BUILD
#     DIR, carried by the row's detail.build_dir and the json's
#     machine_build_dir, and written into the staged RESULT as `BUILT_AS:`.
#   * A RELAY ON AN OUTAGE. bd_result_in_ledger answered rc 1 for both "not
#     there" and "could not ask", so a blink of the coordination DB pushed a
#     copy of a result whose row already existed. Unknown now answers rc 2 and
#     NEITHER hub site relays on it.
#   * A DEFERRAL THAT STRANDS. Not relaying is only safe if something re-asks:
#     the ingest leaves the result on its builder for the */2 sweep, the pool
#     parks it under RELAY_DEFERRED and retries every tick. Both are driven.
#   * AN ALERT CHANNEL THAT STOPS BEING READ. A ledger outage lasts hours and
#     these lanes tick every two minutes. One line per key, not one per tick.
#
# DRIVEN, NOT GREPPED. Every headline here is a NEGATIVE — no json, no ssh, no
# second dir, no second alert — and a negative cannot be read off the source.
# The ssh, rm and request stubs record what they were asked to do, and the
# assertions are on those files.
# Run from anywhere: tests/remote-result-relay-once.bh-1041-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "remote-result-relay-once.bh-1041-test: SKIPPED — jq is not installed"; exit 0; }

# ONE CLOCK READ FOR THE WHOLE FILE. Every fixture timestamp below is derived
# from it, so this suite cannot pick its own red hour (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
TS_OLD=$(date -u -d "@$((NOW - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || TS_OLD="2026-01-01T00:00:00Z"
TS_NEW=$(date -u -d "@$((NOW - 60))"   '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || TS_NEW="2026-01-01T01:00:00Z"

# The machine's own build dir — the ONE name the ledger row's detail and the
# relay json both carry, and the whole point of the ticket.
MBD=project-3-TK-9-m1

# ══════════════════════════════════════════════════════════════════════════════
# 1. bd_result_in_ledger ANSWERS THREE WAYS
# ══════════════════════════════════════════════════════════════════════════════
# rc 0 present / rc 1 answered-and-absent / rc 2 could-not-ask. Collapsing the
# last two is the defect: every caller's fallback is "relay", so an outage
# relays a result the ledger already has.
LIB="$DIR/bin/lib/builder-direct.sh"
ledger_rc() { # ledger_rc <feed-stub-source> <project> <key> [line] [machine-build-dir]
  ( . "$LIB"; eval "$1"; bd_result_in_ledger "$2" "$3" "${4:-}" "${5:-}" ) >/dev/null 2>&1
  echo $?
}
FEED_HAS='job_artifact_feed() { printf "J1\tPR_CREATED x\tbuilder-1\tT1\tt\t{\"key\":\"TK-9\"}\n"; }'
FEED_OTHER='job_artifact_feed() { printf "J2\tPR_CREATED y\tbuilder-1\tT2\tt\t{\"key\":\"TK-8\"}\n"; }'
FEED_NONE='job_artifact_feed() { :; }'
FEED_DOWN='job_artifact_feed() { return 1; }'

[ "$(ledger_rc "$FEED_HAS" project-3 TK-9)" = 0 ] \
  && ok || bad "§1 a feed carrying this key must answer rc 0"
[ "$(ledger_rc "$FEED_OTHER" project-3 TK-9)" = 1 ] \
  && ok || bad "§1 a feed that was READ and lacks this key must answer rc 1"
[ "$(ledger_rc "$FEED_NONE" project-3 TK-9)" = 1 ] \
  && ok || bad "§1 an EMPTY feed is still an answer — rc 1, not rc 2"
[ "$(ledger_rc "$FEED_DOWN" project-3 TK-9)" = 2 ] \
  && ok || bad "§1 THE TICKET: a feed that could not be read must answer rc 2, never rc 1"
[ "$(ledger_rc ':' project-3 TK-9)" = 2 ] \
  && ok || bad "§1 no jobs client in this shell must answer rc 2 (could not ask), not rc 1 (absent)"
[ "$(ledger_rc "$FEED_HAS" project-3 '')" = 2 ] \
  && ok || bad "§1 an empty key is unanswerable — rc 2"
[ "$(ledger_rc "$FEED_HAS" '' TK-9)" = 2 ] \
  && ok || bad "§1 an empty project is unanswerable — rc 2"
# The line match is the second door into rc 0 and must survive the rc split.
[ "$(ledger_rc "$FEED_OTHER" project-3 TK-9 'PR_CREATED y')" = 0 ] \
  && ok || bad "§1 a row whose ref IS this result line must still answer rc 0"

# (f) WHICH BUILD, NOT WHICH TICKET (review round 1). The key is not an identity
# for a build: a ticket gets rebuilt. A caller holding the machine's build dir
# gets THAT BUILD's row or rc 1 — never a sibling build's row.
FEED_B1='job_artifact_feed() { printf "J1\tPR_CREATED x\tbuilder-1\tT1\tt\t{\"key\":\"TK-9\",\"build_dir\":\"project-3-TK-9-m1\"}\n"; }'
[ "$(ledger_rc "$FEED_B1" project-3 TK-9 '' project-3-TK-9-m1)" = 0 ] \
  && ok || bad "§1f the row for THIS build dir must answer rc 0"
[ "$(ledger_rc "$FEED_B1" project-3 TK-9 '' project-3-TK-9-m2)" = 1 ] \
  && ok || bad "§1f THE FINDING: a SECOND build of the same key must not read its sibling's row as delivered"
[ "$(ledger_rc "$FEED_B1" project-3 TK-9 'PR_CREATED x' project-3-TK-9-m2)" = 0 ] \
  && ok || bad "§1f the exact-line door must stay open even when the build dirs differ"
# A row from before detail.build_dir existed (pre 2026-09-10) carries no build
# dir at all, and the key match is the only thing left. It stays the FALLBACK.
[ "$(ledger_rc "$FEED_HAS" project-3 TK-9 '' project-3-TK-9-m2)" = 0 ] \
  && ok || bad "§1f a row with NO build_dir must still match on the key (older rows)"
[ "$(ledger_rc "$FEED_B1" project-3 TK-9)" = 0 ] \
  && ok || bad "§1f a caller with no build dir in hand keeps today's key match"

# ══════════════════════════════════════════════════════════════════════════════
# THE HUB'S INGEST (§2, §3) — bin/fly-results-ingest.sh driven whole
# ══════════════════════════════════════════════════════════════════════════════
HI="$T/hi"
mkdir -p "$HI/bin/lib" "$HI/env" "$HI/flags" "$HI/logs" "$HI/state/fly" "$HI/builds" "$T/fakebin"
cp "$DIR/bin/lib/builder-direct.sh" "$HI/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$HI/bin/"
cp "$DIR/bin/alert-line.sh" "$HI/bin/"
# BH-1194: bin/jobs-client.sh is a shim over bin/lib/jobs/*.sh and exit-1s when
# a module is missing, so a fixture that copies the client copies the modules.
mkdir -p "$HI/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$HI/bin/lib/jobs/"
printf 'FLY_API_TOKEN_PROJECT_3_OS=tok\n' > "$HI/env/fly.env"
printf '#!/bin/bash\nexit 0\n' > "$HI/bin/beat.sh"; chmod +x "$HI/bin/beat.sh"
cat > "$HI/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-}" in --tailnet-ip) echo 10.0.0.9; exit 0 ;; esac
exit 1
SH
chmod +x "$HI/bin/fleet-conf.sh"
export PATH="$T/fakebin:$PATH"

# The builder, over `flyctl ssh console`. The probe rides through `printf %q`,
# so the stub matches the words that survive the escaping. THE rm ARM IS AN
# ASSERTION: "the builder's state was left in place" is a fact about a call that
# did not happen, and $RM_SINK is where that fact lives.
cat > "$T/fakebin/flyctl" <<'SH'
#!/bin/bash
case "$*" in
  *sftp*)       : ;;
  *echo*yes*)   echo yes ;;
  *cat*RESULT*) cat "$RESULT_SRC" ;;
  *rm*RESULT*)  printf 'rm %s\n' "$*" >> "$RM_SINK" ;;
  *)            : ;;
esac
exit 0
SH
chmod +x "$T/fakebin/flyctl"
# BOTH NAMES: the script resolves `fly` first and only falls back to `flyctl`.
cp "$T/fakebin/flyctl" "$T/fakebin/fly"
# ssh records its ARGUMENTS and, for the relay payload only, its STDIN. The
# payload always rides a here-string, so reading stdin here can never block.
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$SSH_SINK"
case "$*" in *remote-results*) cat >> "$SSH_BODY" ;; esac
exit 0
SH
chmod +x "$T/fakebin/ssh"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-feed_empty}" in
  down) exit 7 ;;
  feed_has)
    case "$URL" in
      */api/artifacts*) printf '%s\n200\n' "{\"artifacts\":[{\"job_id\":\"J1\",\"artifact_kind\":\"result\",\"artifact_ref\":\"PR_CREATED https://github.com/o/r/pull/9\",\"box\":\"builder-1\",\"ticket_id\":\"T1\",\"updated_at\":\"$FIX_TS\",\"detail\":\"{\\\"build_dir\\\":\\\"$FIX_MBD\\\",\\\"key\\\":\\\"TK-9\\\"}\"}]}" ;;
      *)                printf '{}\n200\n' ;;
    esac ;;
  *)
    case "$URL" in
      */api/artifacts*) printf '{"artifacts":[]}\n200\n' ;;
      *)                printf '{}\n200\n' ;;
    esac ;;
esac
STUB
chmod +x "$T/fakebin/curl"

seed_ingest() { # seed_ingest <result-line>   — a fresh, undelivered build
  rm -rf "$T/hi/state/remote-results" "$T/hi/builds/fly-"* 2>/dev/null
  mkdir -p "$HI/state/fly"
  { printf '%s\n' "$1"; printf 'BUILD_DIR: %s\n' "$MBD"; } > "$T/result.src"
  jq -nc '{key:"TK-9",ticket_id:"T1"}' > "$HI/state/fly/project-3-active.json"
  jq -nc '{app:"builder-project-3"}'        > "$HI/state/fly/project-3.json"
  rm -f "$HI/state/fly/project-3-TK-9.relay-deferred"
  : > "$T/rm.txt"; : > "$T/ssh.txt"; : > "$T/ssh-body.txt"; : > "$T/req.txt"
  : > "$HI/logs/ALERTS.log"; : > "$HI/logs/fly-dispatch.log"
}
ingest() { # ingest <curl-mode>   — one tick; seeds NOTHING, so ticks accumulate
  ( export HARNESS="$HI" JOBS_HARNESS="$HI" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           CURL_MODE="$1" REQ_SINK="$T/req.txt" RESULT_SRC="$T/result.src" \
           SSH_SINK="$T/ssh.txt" SSH_BODY="$T/ssh-body.txt" RM_SINK="$T/rm.txt" \
           FIX_TS="$TS_NEW" FIX_MBD="$MBD" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/fly-results-ingest.sh" project-3 >/dev/null 2>&1 )
}
i_relayed()  { ls "$HI/builds"/fly-project-3-TK-9-*/RELAYED 2>/dev/null | head -1; }
i_builddir() { ls -d "$HI/builds"/fly-project-3-TK-9-* 2>/dev/null | head -1; }
i_flag="$HI/state/fly/project-3-TK-9.relay-deferred"
n_unreadable() { grep -c 'LEDGER UNREADABLE' "$HI/logs/ALERTS.log" 2>/dev/null | head -1; }

# ── §2 the row is there: bookkeeping, never a relay ──────────────────────────
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest feed_has
[ ! -e "$HI/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§2a a result already terminal in the ledger must not be relayed again"
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "§2a nothing may go over ssh for a delivered result: $(cat "$T/ssh.txt")"
[ -n "$(i_relayed)" ] \
  && ok || bad "§2a custody must still be stamped RELAYED"
[ ! -e "$HI/state/fly/project-3-active.json" ] \
  && ok || bad "§2a the hub's active-job state must be cleared"
grep -q 'rm .*RESULT' "$T/rm.txt" \
  && ok || bad "§2a the builder's RESULT/job.json must be cleared on a delivered result"
[ ! -e "$i_flag" ] && ok || bad "§2a a delivered result must leave no deferral flag"

# (b) THE MARKER IS A CACHE: present, the ledger is never asked at all.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: the builder posted the board close-out on project-3/TK-9 -> review"
ingest down
[ ! -e "$HI/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§2b a marked RESULT must not be parked for a second close-out"
[ ! -s "$T/ssh.txt" ] && ok || bad "§2b a marked RESULT must not be pushed over ssh"
[ -n "$(i_relayed)" ] && ok || bad "§2b custody must still be stamped RELAYED"
# The LEDGER read is the `result` feed. The `fly_result` read (BH-2625) is the
# RESULT transport itself and happens before the marker can be seen.
[ "$(grep -c '/api/artifacts?kind=result&' "$T/req.txt" 2>/dev/null | head -1)" = 0 ] \
  && ok || bad "§2b the marker is a CACHE HIT — no ledger read may happen: $(cat "$T/req.txt")"
[ ! -e "$i_flag" ] \
  && ok || bad "§2b a cache hit is not an outage — no deferral flag"

# ── §3 the ledger could not be asked: hold, do not relay ─────────────────────
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
[ ! -e "$HI/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§3a THE TICKET: an unreadable ledger must NOT relay"
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "§3a an unreadable ledger must send no ssh: $(cat "$T/ssh.txt")"
[ ! -s "$T/rm.txt" ] \
  && ok || bad "§3a the builder's RESULT must be LEFT IN PLACE for the next sweep: $(cat "$T/rm.txt")"
[ -f "$HI/state/fly/project-3-active.json" ] \
  && ok || bad "§3a the active-job row must survive a deferral, or nothing re-asks"
[ -z "$(i_builddir)" ] \
  && ok || bad "§3a the half-made hub build dir must be removed: $(i_builddir)"
[ -f "$i_flag" ] && ok || bad "§3a the deferral must be recorded as a flag file"
[ "$(n_unreadable)" = 1 ] \
  && ok || bad "§3a one ALERTS line must name the outage, got $(n_unreadable): $(cat "$HI/logs/ALERTS.log")"
grep -q 'TK-9' "$HI/logs/ALERTS.log" && ok || bad "§3a the ALERTS line must name the key"

# (b) ONE LINE PER KEY, not one per tick. This lane runs every two minutes and
# a worker outage lasts hours.
ingest down
ingest down
[ "$(n_unreadable)" = 1 ] \
  && ok || bad "§3b three deferred ticks must still be ONE alert, got $(n_unreadable)"
[ "$(grep -c 'is held on the builder' "$HI/logs/fly-dispatch.log" 2>/dev/null | head -1)" = 1 ] \
  && ok || bad "§3b the dispatch log must say it once too, got $(grep -c 'is held on the builder' "$HI/logs/fly-dispatch.log")"
[ ! -s "$T/ssh.txt" ] && ok || bad "§3b still nothing over ssh after three ticks"
[ ! -s "$T/rm.txt" ]  && ok || bad "§3b still nothing cleared on the builder after three ticks"

# (c) THE DEFERRAL RESOLVES. The row turned up; this is bookkeeping now.
ingest feed_has
[ -n "$(i_relayed)" ] && ok || bad "§3c once the ledger answers, the result must be accounted for"
[ ! -e "$HI/state/fly/project-3-active.json" ] \
  && ok || bad "§3c a resolved deferral clears the active-job row"
[ ! -e "$i_flag" ] && ok || bad "§3c a resolved deferral removes its flag, or the next one is silent"
[ ! -e "$HI/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§3c the row carried it — still no relay"

# (d) THE OTHER RESOLUTION: the ledger answers and has NO row -> relay, as
# always, and the payload carries the cross-path identity.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
[ -f "$i_flag" ] && ok || bad "§3d precondition: the fresh deferral must be flagged"
ingest feed_empty
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "§3d an answered-and-absent ledger must relay exactly as today: $(cat "$T/ssh.txt")"
[ ! -e "$i_flag" ] && ok || bad "§3d a relayed result removes its deferral flag"
[ "$(jq -r '.machine_build_dir // ""' "$T/ssh-body.txt" 2>/dev/null)" = "$MBD" ] \
  && ok || bad "§3d the relay payload must carry machine_build_dir: $(cat "$T/ssh-body.txt")"
[ "$(jq -r '.key // ""' "$T/ssh-body.txt" 2>/dev/null)" = TK-9 ] \
  && ok || bad "§3d the relay payload must still be the shape the box reads"
grep -q 'rm .*RESULT' "$T/rm.txt" \
  && ok || bad "§3d a relayed result clears the builder, exactly as today"

# (e) THE HOLD IS BOUNDED BY THE BUILDER'S AUTOSTOP (review round 1).
# fly/builder-runner.sh exits 0 after IDLE_TIMEOUT=600s of no new job, which
# stops the machine and takes the tmpfs the held RESULT lives in — and
# bin/fly-dispatch.sh then reads `stopped` + an active-job row as "died
# mid-build", requeues, and `.failed`s the ticket on attempt 2. So a hold that
# outlives the autostop turns a CLEAN build into a paged failure during the very
# outage this ticket exists for. Past the cap the hub relays instead of holding.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
[ -f "$i_flag" ] && ok || bad "§3e precondition: the first deferred tick must flag"
# Age the flag past the cap the way the clock would. Line 1 IS the epoch the
# bound is measured from; line 2 is the human stamp.
head -1 "$i_flag" | grep -qE '^[0-9]+$' \
  && ok || bad "§3e the flag's first line must be the epoch the bound reads: $(head -1 "$i_flag")"
{ printf '%s\n' "$((NOW - 600))"; printf 'aged-by-test\n'; } > "$i_flag"
ingest down
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "§3e THE FINDING: past the cap the hub must RELAY, not keep holding: $(cat "$T/ssh.txt")"
grep -q 'rm .*RESULT' "$T/rm.txt" \
  && ok || bad "§3e an expired hold clears the builder, so its autostop takes nothing"
[ ! -e "$HI/state/fly/project-3-active.json" ] \
  && ok || bad "§3e an expired hold clears the hub active-job row, so dispatch cannot call it dead"
[ ! -e "$i_flag" ] && ok || bad "§3e an expired hold removes its flag"
[ "$(grep -c 'HOLD EXPIRED' "$HI/logs/ALERTS.log" 2>/dev/null | head -1)" = 1 ] \
  && ok || bad "§3e giving up on a hold must be said once in ALERTS, got $(grep -c 'HOLD EXPIRED' "$HI/logs/ALERTS.log")"
# ...and the cap is small enough to leave room under the builder's own 600s for
# the two */2 sweeps that bracket it (the flag is stamped up to one sweep after
# the RESULT appears, and the expiry is noticed up to one sweep after the cap).
# Driven, not read off the source: a hold aged 350s must already have given up.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
{ printf '%s\n' "$((NOW - 350))"; printf 'aged-by-test\n'; } > "$i_flag"
ingest down
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "§3e a 350s hold must already have expired — the cap has to leave two sweeps under the builder's 600s autostop"
# A FLAG FROM AN OLDER HUB carries only the human stamp. That is "no clock", not
# an epoch in the year 20260921 — it is re-stamped and bounded from now, never
# held for ever.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
printf '2026-09-21 06:53:06Z\n' > "$i_flag"
ingest down
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "§3e a flag with no epoch must be re-stamped and HELD, not relayed on the spot: $(cat "$T/ssh.txt")"
head -1 "$i_flag" | grep -qE '^[0-9]+$' \
  && ok || bad "§3e a flag with no epoch must be re-stamped with one: $(head -1 "$i_flag")"
{ printf '%s\n' "$((NOW - 600))"; printf 'aged-by-test\n'; } > "$i_flag"
ingest down
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "§3e a re-stamped flag must then expire like any other"

# A FRESH hold is still a hold — the bound must not have turned the hold off.
seed_ingest "PR_CREATED https://github.com/o/r/pull/9"
ingest down
ingest down
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "§3e a hold younger than the cap must still hold: $(cat "$T/ssh.txt")"
[ -f "$i_flag" ] && ok || bad "§3e a hold younger than the cap keeps its flag"

# ══════════════════════════════════════════════════════════════════════════════
# 4. THE POOL REAP — bin/fly-pool.sh driven whole
# ══════════════════════════════════════════════════════════════════════════════
HP="$T/hp"
mkdir -p "$HP/bin/lib" "$HP/logs" "$HP/flags" "$HP/locks" "$HP/env" \
         "$HP/state/fly" "$HP/state/fly-pool/project-3" "$HP/state/remote-results/project-3" \
         "$HP/builds" "$T/poolbin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
   "$DIR/bin/result-prefix-ok.sh" "$HP/bin/"
cp "$DIR/bin/alert-line.sh" "$HP/bin/"
cp "$DIR/bin/lib/builder-direct.sh" "$HP/bin/lib/"
# BH-1194: the jobs client is a shim; its modules travel with it.
mkdir -p "$HP/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$HP/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$HP/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$HP/env/global.env"
: > "$HP/env/fly.env"
printf '3\n' > "$HP/flags/fly-pool-project-3"
printf 'pool-project-3\n' > "$HP/flags/fly-pool-app-project-3"
printf '{"app":"pool-project-3"}\n' > "$HP/state/fly/project-3.json"
printf '#!/bin/bash\nexit 0\n' > "$HP/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/poolbin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/poolbin/timeout"
printf '#!/bin/bash\necho OPEN\n' > "$T/poolbin/gh"
# The RESULT the machine wrote, including the BUILD_DIR: line that IS the
# cross-path identity this ticket adds.
printf 'PR_CREATED https://github.com/o/r/pull/55\nTIER: 1\nBUILD_DIR: %s\n' "$MBD" > "$T/pool-result.src"
printf 'VERDICT: APPROVE\n' > "$T/pool-review.src"
# base64 DIALECTS: the same shim tests/pool-relay-rowfirst-test.sh carries, and
# for the same reason — GNU takes -d/-w0, BSD -D/-b 0, and a shim that picks a
# side silently decodes to empty files on the other one.
cat > "$T/poolbin/base64" <<'STUB'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
STUB
cat > "$T/poolbin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
case "$*" in *remote-results*) cat >> "$SSH_BODY" ;; esac
exit 0
STUB
# LOOSE PATTERNS ON PURPOSE: mexec wraps its command with `printf %q`, so a
# match on a whole quoted phrase never fires and the reap silently does nothing.
cat > "$T/poolbin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    base64 -w0 "$POOL_RESULT_SRC" ;;
  *base64*review*)    base64 -w0 "$POOL_REVIEW_SRC" ;;
  *base64*)           : ;;
  *head*RESULT*)      head -1 "$POOL_RESULT_SRC" ;;
  *ls*builds*)        echo "/data/harness/builds/$POOL_MBD" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
cat > "$T/poolbin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$M" "$URL" >> "$REQ_SINK"
[ "${CLIENT_DOWN:-0}" = 1 ] && exit 7
case "$URL" in
  */api/artifacts\?*)
    if [ "${FEED_HAS_KEY:-0}" = 1 ]; then
      printf '%s\n200\n' "{\"artifacts\":[{\"job_id\":\"j1\",\"artifact_kind\":\"result\",\"artifact_ref\":\"PR_CREATED https://github.com/o/r/pull/55\",\"box\":\"pool-machine-1\",\"ticket_id\":\"9\",\"updated_at\":\"$FIX_TS\",\"detail\":\"{\\\"build_dir\\\":\\\"$POOL_MBD\\\",\\\"key\\\":\\\"TK-9\\\",\\\"job_status\\\":\\\"done\\\"}\"}]}"
    else
      printf '{"artifacts":[]}\n200\n'
    fi ;;
  */api/merge-queue)
    printf '{"merge":{"project":"project-3","pr":55,"status":"queued"},"duplicate":false}\n201\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$HP/bin/beat.sh" "$HP/bin/result-prefix-ok.sh" "$T/poolbin"/*

pool_run() { # pool_run <FEED_HAS_KEY> [CLIENT_DOWN]
  ( export PATH="$T/poolbin:$PATH" HARNESS="$HP" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$HP/fleet.conf" REQ_SINK="$T/preq.txt" SSH_SINK="$T/pssh.txt" \
           SSH_BODY="$T/pssh-body.txt" FEED_HAS_KEY="$1" CLIENT_DOWN="${2:-0}" \
           FLY_API_TOKEN_PROJECT_3_OS=tok FLY_BIN_DIR="$T/poolbin" FIX_TS="$TS_NEW" \
           POOL_RESULT_SRC="$T/pool-result.src" POOL_REVIEW_SRC="$T/pool-review.src" \
           POOL_MBD="$MBD"
    bash "$DIR/bin/fly-pool.sh" project-3 >/dev/null 2>&1 )
}
pool_sinks() { : > "$T/preq.txt"; : > "$T/pssh.txt"; : > "$T/pssh-body.txt"; }
pool_reap() { # pool_reap <FEED_HAS_KEY> [CLIENT_DOWN]   — a machine with a RESULT
  pool_sinks
  printf '{"machine":"m1","key":"TK-9","ticket_id":"9","attempt":0}\n' \
    > "$HP/state/fly-pool/project-3/m1.json"
  pool_run "$1" "${2:-0}"
}
pool_tick() { pool_sinks; pool_run "$1" "${2:-0}"; }   # no machine: retry only
pool_reset() {
  rm -rf "$T/hp/builds"/pool-project-3-* "$T/hp/flags"/alerted-pool-relay-* 2>/dev/null
  rm -f "$HP/state/remote-results/project-3/TK-9.json"
  : > "$HP/logs/ALERTS.log"; : > "$HP/logs/fly-pool.log"
}
p_dir()      { ls -d "$HP/builds/pool-project-3-TK-9-"* 2>/dev/null | head -1; }
p_deferred() { ls "$HP/builds/pool-project-3-TK-9-"*/RELAY_DEFERRED 2>/dev/null | head -1; }
p_relayed()  { ls "$HP/builds/pool-project-3-TK-9-"*/RELAYED 2>/dev/null | head -1; }
p_unreadable() { grep -c 'LEDGER UNREADABLE' "$HP/logs/ALERTS.log" 2>/dev/null | head -1; }

# (a) THE FEED COULD NOT BE READ -> park, do not push.
pool_reset
pool_reap 1 1
[ -n "$(p_dir)" ] && ok || bad "§4a precondition: the reap must have produced a pool build dir"
grep -q 'remote-results' "$T/pssh.txt" \
  && bad "§4a THE TICKET: an unreadable ledger must NOT push the result: $(cat "$T/pssh.txt")" || ok
grep -q 'builds/' "$T/pssh.txt" \
  && bad "§4a an unreadable ledger must not push the artifacts either" || ok
[ -n "$(p_deferred)" ] && ok || bad "§4a the deferral must be marked RELAY_DEFERRED on the pool dir"
[ -z "$(p_relayed)" ] \
  && ok || bad "§4a nothing was delivered, so nothing may be stamped RELAYED"
[ -f "$HP/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§4a the hub json is the only other copy — it must be kept"
[ "$(jq -r '.machine_build_dir // ""' "$HP/state/remote-results/project-3/TK-9.json")" = "$MBD" ] \
  && ok || bad "§4a the hub json must carry machine_build_dir"
[ "$(p_unreadable)" = 1 ] \
  && ok || bad "§4a one LEDGER UNREADABLE line, got $(p_unreadable): $(cat "$HP/logs/ALERTS.log")"
grep -q 'held hub-side' "$HP/logs/ALERTS.log" \
  && ok || bad "§4a the alert must say the result is HELD, not that it was pushed"

# (b) A SECOND TICK WHILE THE OUTAGE HOLDS: silent, and still nothing pushed.
pool_tick 1 1
[ ! -s "$T/pssh.txt" ] && ok || bad "§4b the retry must push nothing while the ledger is still down"
[ -n "$(p_deferred)" ] && ok || bad "§4b the marker must survive an unresolved retry"
[ "$(p_unreadable)" = 1 ] && ok || bad "§4b a silent retry must not page again, got $(p_unreadable)"
pool_reap 1 1
[ "$(p_unreadable)" = 1 ] \
  && ok || bad "§4b a second REAP on the same day must not page again either, got $(p_unreadable)"

# (c) THE ROW TURNS UP -> bookkeeping, still no ssh.
pool_tick 1 0
[ ! -s "$T/pssh.txt" ] && ok || bad "§4c a resolved deferral must not push: $(cat "$T/pssh.txt")"
[ -n "$(p_relayed)" ] && ok || bad "§4c a resolved deferral stamps custody RELAYED"
[ -z "$(p_deferred)" ] && ok || bad "§4c a resolved deferral removes its marker"
[ -f "$HP/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§4c the row path keeps the hub json, exactly as the reap does"

# (d) THE LEDGER ANSWERS AND HAS NO ROW -> one full push, then done.
pool_reset
pool_reap 1 1
[ -n "$(p_deferred)" ] && ok || bad "§4d precondition: a fresh deferral"
pool_tick 0 0
[ "$(grep -c 'remote-results' "$T/pssh.txt")" = 1 ] \
  && ok || bad "§4d exactly one json push, got $(grep -c 'remote-results' "$T/pssh.txt"): $(cat "$T/pssh.txt")"
grep -q 'builds/' "$T/pssh.txt" && ok || bad "§4d the artifacts must ride with it"
[ "$(jq -r '.machine_build_dir // ""' "$T/pssh-body.txt" 2>/dev/null)" = "$MBD" ] \
  && ok || bad "§4d the pushed payload must carry machine_build_dir: $(cat "$T/pssh-body.txt")"
[ ! -f "$HP/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "§4d a successful push removes the hub json"
[ -n "$(p_relayed)" ] && ok || bad "§4d a successful push stamps RELAYED"
[ -z "$(p_deferred)" ] && ok || bad "§4d a resolved deferral removes its marker"
# (e) THE MERGE-QUEUE HAND-OFF IS THE REAP'S, NOT THE RETRY'S: the #224 row took
# it at reap time, so a retry that re-sent it would enqueue one PR twice.
grep -q 'merge-queue' "$T/pssh.txt" \
  && bad "§4e the retry must not touch the merge queue: $(cat "$T/pssh.txt")" || ok

# ══════════════════════════════════════════════════════════════════════════════
# 5. THE OWNING BOX STAGES A BUILD ONCE — bin/run-triage.sh driven whole
# ══════════════════════════════════════════════════════════════════════════════
HS="$T/hs"
mkdir -p "$HS/bin/lib/rt" "$HS/logs" "$HS/flags" "$HS/locks" "$HS/builds" \
         "$HS/env" "$HS/prompts" "$HS/catalog/agent-contracts" \
         "$HS/state/remote-results/project-3" "$T/stagebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$HS/bin/"
cp "$DIR"/bin/lib/rt/*.sh "$HS/bin/lib/rt/"
cp "$DIR/bin/lib/builder-direct.sh" "$HS/bin/lib/"
# BH-1194: the jobs client is a shim; its modules travel with it.
mkdir -p "$HS/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$HS/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$HS/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$HS/catalog/agent-contracts/"
: > "$HS/env/global.env"
printf 'SOP BODY\n' > "$HS/prompts/project-3.md"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$HS/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$HS/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$HS/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$HS/bin/decision-log.sh"
printf '#!/bin/bash\nprintf "tickets=0\\n" > "${5:-/dev/null}"\nexit 0\n' > "$HS/bin/agent-call.sh"
chmod +x "$HS/bin/"*.sh
printf '#!/bin/bash\nexit 0\n' > "$T/stagebin/ssh"
printf '#!/bin/bash\nexit 0\n' > "$T/stagebin/scp"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/stagebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/stagebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/stagebin/tailscale"
cat > "$T/stagebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/artifacts\?*)
    SINCE=""
    case "$URL" in *since=*) SINCE="${URL##*since=}"; SINCE="${SINCE%%&*}" ;; esac
    printf '%s\n200\n' "$(jq -c --arg s "$SINCE" \
      '{artifacts: [ .artifacts[] | select($s == "" or .updated_at > $s) ]}' \
      "${ARTS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"artifacts":[]}')" ;;
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
  */api/flags/*)  printf '{"error":"not found"}\n404\n' ;;
  *)              printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/stagebin"/*

# The ledger row for one build of TK-77, and the relay json for the SAME build.
# Their result LINES differ on purpose — the pool truncates, the verify gate
# rewrites, the builder appends its marker — because the text is exactly what
# stopped being the identity.
ROW_LINE='PR_CREATED https://github.com/o/r/pull/12 | CLOSED-OUT: the builder posted the board close-out on project-3/TK-77 -> review'
JSON_LINE='PR_CREATED https://github.com/o/r/pull/12'
arts() { # arts <build_dir> [more-rows-json]
  jq -nc --arg r "$ROW_LINE" --arg b "$1" --arg t "$TS_OLD" \
    '{artifacts:[{job_id:"build-project-3-TK-77-1",artifact_kind:"result",artifact_ref:$r,
                  box:"pool-machine-1",ticket_id:"77",updated_at:$t,
                  detail:({build_dir:$b,key:"TK-77",job_status:"done"}|tostring)}]}' \
    > "$T/arts.json"
}
relayjson() { # relayjson <key> <machine_build_dir|-> <result-line>
  local mbd="$2"
  if [ "$mbd" = - ]; then
    jq -nc --arg k "$1" --arg r "$3" \
      '{key:$k,ticket_id:"77",result:$r,build_dir:"pool-project-3-TK-77-1"}'
  else
    jq -nc --arg k "$1" --arg r "$3" --arg m "$mbd" \
      '{key:$k,ticket_id:"77",result:$r,build_dir:"pool-project-3-TK-77-1",machine_build_dir:$m}'
  fi > "$HS/state/remote-results/project-3/$1.json"
}
triage() {
  ( export PATH="$T/stagebin:$PATH" HARNESS="$HS" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           JOBS_BEAT_SECS=3600 ARTS_FIXTURE="$T/arts.json"
    bash "$DIR/bin/run-triage.sh" project-3 >/dev/null 2>&1 )
}
s_reset() {
  rm -rf "$T/hs/builds"/project-3-* "$T/hs/state/remote-results" 2>/dev/null
  mkdir -p "$HS/state/remote-results/project-3"
  : > "$HS/logs/ALERTS.log"; : > "$HS/logs/project-3.log"
  printf '{"artifacts":[]}\n' > "$T/arts.json"
}
s_dirs() { ls -d "$HS/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' '; }
# TWO TICKS, TWO NAMES. A staged dir is named `<project>-<key>-remote<YYYYmmdd
# HHMMSS>`, so two stagings inside one second land on ONE directory — which
# would make "only one dir exists" true for a reason that has nothing to do with
# the dedupe this file is about. In production the two paths are a tick apart.
# Renaming the first staging's dir to a stamp of its own restores that, and the
# guards below glob on `-remote*` so they still find it. The `-remote0` prefix
# is how an already-renamed dir is recognised: a real stamp starts with 2.
S_N=0
s_settle() {
  local d
  for d in "$HS/builds/project-3-TK-77-remote"*; do
    [ -d "$d" ] || continue
    case "$d" in *-remote0*) continue ;; esac
    S_N=$((S_N+1)); mv "$d" "$HS/builds/project-3-TK-77-remote0000000000000$S_N"
  done
}

# (a) ROW FIRST, then the json for the same build with a DIFFERENT line.
s_reset
arts project-3-TK-77-x
triage
[ "$(s_dirs)" = 1 ] && ok || bad "§5a precondition: the ledger row must stage one dir, got $(s_dirs)"
grep -qxF "BUILT_AS: project-3-TK-77-x" "$HS/builds/project-3-TK-77-remote"*/RESULT 2>/dev/null \
  && ok || bad "§5a the staged RESULT must carry the machine's build dir as BUILT_AS:"
s_settle
relayjson TK-77 project-3-TK-77-x "$JSON_LINE"
triage
[ "$(s_dirs)" = 1 ] \
  && ok || bad "§5a THE TICKET: the relay json for a staged build must not stage a second dir, got $(s_dirs)"
[ -f "$HS/state/remote-results/project-3/.handled/TK-77.json" ] \
  && ok || bad "§5a the superseded json must be consumed, not retried every tick"

# (b) JSON FIRST, row second — the same answer in the other direction.
s_reset
relayjson TK-77 project-3-TK-77-x "$JSON_LINE"
triage
[ "$(s_dirs)" = 1 ] && ok || bad "§5b precondition: the json must stage one dir, got $(s_dirs)"
grep -qxF "BUILT_AS: project-3-TK-77-x" "$HS/builds/project-3-TK-77-remote"*/RESULT 2>/dev/null \
  && ok || bad "§5b a json-staged dir must carry BUILT_AS: too, or the row stages a second one"
s_settle
arts project-3-TK-77-x
triage
[ "$(s_dirs)" = 1 ] \
  && ok || bad "§5b the ledger row for a json-staged build must not stage a second dir, got $(s_dirs)"
[ -f "$HS/state/remote-results/project-3/.handled/build-project-3-TK-77-1.job" ] \
  && ok || bad "§5b the row must be marked handled so the window does not re-offer it for ever"

# (c) TWO DIFFERENT BUILDS OF ONE TICKET THAT END IN THE SAME SENTENCE ARE TWO
# RESULTS. This is the negative the ticket asks for: the text is not the key.
s_reset
arts project-3-TK-77-x
triage
s_settle
relayjson TK-77 project-3-TK-77-y "$ROW_LINE"
triage
[ "$(s_dirs)" = 2 ] \
  && ok || bad "§5c a DIFFERENT build with an identical result line must stage its own dir, got $(s_dirs)"

# (d) AN OLDER SENDER: no machine_build_dir at all.
#
# TEST-CHANGE (BH-1284), and it inverts what this case asserted. BH-1041 decided
# that a json carrying no cross-path identity should be STAGED and the log should
# say so, on the reasoning that an unprovable duplicate is better staged twice
# than lost. Production disagreed: `machine_build_dir` is empty on every json
# whose builder or sender predates BH-1041 — which was ALL of them until it
# propagated — so this was not a rare shape, and the hub's builds/ carries about
# twenty pairs from one drain on 2026-09-17 where the same ticket, the same PR
# and two dirs four seconds apart became two close-out comments on a client's
# ticket. A duplicate close-out has no undo; a consumed json does, because the
# ledger row for the same build has already staged the close-out it carries.
#
# So: consumed, not staged, and said out loud in BOTH the project log and (once
# a day) ALERTS, because the one case this gets wrong — an old sender relaying a
# genuinely NEW build — must not be silent. It is narrow: it applies only where
# every dir for the ticket came from the LEDGER. Where the RELAY is the path that
# staged before, an identity-less json names a build nothing has staged and is
# still staged — that is project-3 TK-139, and tests/fly-lane-db-test.sh §4f asserts it.
s_reset
rm -f "$HS/flags"/alerted-relay-consume-*
arts project-3-TK-77-x
triage
s_settle
relayjson TK-77 - "$JSON_LINE"
triage
[ "$(s_dirs)" = 1 ] \
  && ok || bad "§5d a json with no cross-path identity, for a ticket the LEDGER already staged, must be consumed not staged, got $(s_dirs)"
grep -q 'no cross-path identity' "$HS/logs/project-3.log" \
  && ok || bad "§5d a json consumed without proof it is a duplicate must say so in the project log"
grep -q 'no cross-path identity' "$HS/logs/ALERTS.log" \
  && ok || bad "§5d ...and page once, or a genuinely stranded close-out is invisible"

# (e) NOTHING ELSE PAGES, and no secret rides a log. §5d's consume notice is the
# one staging decision in this section that is allowed to page, and it does so
# once a day.
s_reset
arts project-3-TK-77-x
triage
s_settle
relayjson TK-77 project-3-TK-77-x "$JSON_LINE"
triage
[ ! -s "$HS/logs/ALERTS.log" ] \
  && ok || bad "§5 staging decisions must not page: $(cat "$HS/logs/ALERTS.log")"
grep -rq test-secret "$HS/logs" "$HP/logs" "$HI/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log" || ok

# ══════════════════════════════════════════════════════════════════════════════
# 6. THE OTHER WAY A HELD KEY LEAVES — bin/fly-dispatch.sh driven whole
# ══════════════════════════════════════════════════════════════════════════════
# The hold flag is what keeps the "held on the builder" line to ONE per key, and
# the ingest clears it on any completion. The other exit from an active job is
# bin/fly-dispatch.sh's died-mid-build requeue, which removes the active row —
# and used to leave the flag. A stale flag silences the NEXT outage on the key
# that most recently survived one, which is exactly the key a human is watching.
mkdir -p "$HI/locks" "$HI/state/build-queue/project-3"
printf '3\n' > "$HI/flags/builder-fly-project-3"
printf '#!/bin/bash\nexit 0\n' > "$HI/bin/fly-lock-guard.sh"; chmod +x "$HI/bin/fly-lock-guard.sh"
# The machine is STOPPED — the state fly/builder-runner.sh leaves behind when it
# idles out 600s after a job, which is the shape §3e is bounded against.
printf '#!/bin/bash\ncase "${2:-}" in state) echo stopped ;; *) exit 0 ;; esac\n' > "$HI/bin/fly-api.sh"
chmod +x "$HI/bin/fly-api.sh"
d_flag="$HI/state/fly/project-3-TK-9.relay-deferred"
seed_dispatch() { # seed_dispatch <attempt>
  rm -f "$HI/state/build-queue/project-3/"*.json
  jq -nc --argjson a "$1" '{key:"TK-9",ticket_id:"T1",attempt:$a}' > "$HI/state/fly/project-3-active.json"
  { printf '%s\n' "$NOW"; printf 'held\n'; } > "$d_flag"
  : > "$HI/logs/ALERTS.log"
}
dispatch() {
  ( export HARNESS="$HI" JOBS_HARNESS="$HI" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           CURL_MODE=feed_empty REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" \
           SSH_BODY="$T/ssh-body.txt" RM_SINK="$T/rm.txt" RESULT_SRC="$T/result.src" \
           PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
seed_dispatch 0
dispatch
[ -f "$HI/state/build-queue/project-3/TK-9.json" ] \
  && ok || bad "§6 precondition: a stopped machine with an active job must requeue the key"
[ "$(jq -r '.attempt // ""' "$HI/state/build-queue/project-3/TK-9.json" 2>/dev/null)" = 1 ] \
  && ok || bad "§6 precondition: the requeue must carry attempt=1"
[ ! -e "$HI/state/fly/project-3-active.json" ] \
  && ok || bad "§6 precondition: the requeue must clear the active-job row"
[ ! -e "$d_flag" ] \
  && ok || bad "§6 THE FINDING: the requeue must clear the key's relay-deferred flag, or the rebuilt attempt's outage is silent"
# ...and on the give-up path too, which is the other door out of the active row.
seed_dispatch 1
dispatch
[ -f "$HI/state/build-queue/project-3/TK-9.failed.json" ] \
  && ok || bad "§6 precondition: attempt 2 must mark the key .failed"
[ ! -e "$d_flag" ] \
  && ok || bad "§6 the give-up path must clear the flag too"

echo "remote-result-relay-once.bh-1041-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
