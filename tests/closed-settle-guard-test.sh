#!/bin/bash
# tests/closed-settle-guard-test.sh — a PR that has JUST been closed is not yet
# an outcome (2026-09-15).
#
# WHY THIS EXISTS. The merge conductor's CI kick (mc_kick_ci) closes a PR and
# reopens it one REST call later, to fire the `pull_request` workflow a base
# change does not fire. The conductor holds its own per-project lock across
# that pair, so no other conductor tick can see the gap — but two OTHER lanes
# run on the same box on the same */10 cron and read the same PRs:
#
#   bin/reconcile-prs.sh   reads `state == CLOSED` and clears the build's
#                          console row permanently (cron-lines.sh:103).
#   bin/merge-sweep.sh     reads `state == CLOSED` and writes
#                          `sweep_record <pr> closed`, which sweep_seen then
#                          treats as terminal for ever (cron/hub.cron:47).
#
# Either one landing inside the kick's window retires a PR that is about to be
# open again, and nothing walks that back. The guard is a settle window: a PR
# whose closed_at is younger than MC_CLOSED_SETTLE (default 180s) is SKIPPED
# this pass and re-read on the next one, by which time it is either genuinely
# closed or open again. It costs one extra pass on a real closure and it is the
# difference between a transient close and a lost PR.
#
# Driven, not grepped: both scripts are run end to end against a gh stub whose
# closedAt is the only thing that changes between cases.
# Run from anywhere: tests/closed-settle-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# An ISO-8601 stamp <n> seconds in the past, without GNU date.
ago() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }

# ============================================================================
# 1. mc_closed_settled, the shared helper both lanes ask
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/fakebin"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/"
# The decision reads are REST now (BH-784), so every fixture tree here carries
# bin/lib/gh-rest.sh beside the lib — without it the lib's fail-closed shim
# answers "unverifiable" to every read and a lane would skip instead of deciding.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
export HARNESS="$T/h"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

mc_closed_settled "$(ago 600)" \
  && ok || bad "a PR closed ten minutes ago is settled — the guard must not park real closures for ever"
mc_closed_settled "$(ago 30)" \
  && bad "a PR closed 30 seconds ago is inside the kick's window and must NOT be treated as an outcome yet" || ok
mc_closed_settled "" \
  && ok || bad "an ABSENT closed_at must fail OPEN to settled — an API that stopped returning the field cannot stop the lane"
mc_closed_settled "not-a-date" \
  && ok || bad "an unparseable closed_at must fail OPEN too, never silently park every closed PR"
( MC_CLOSED_SETTLE=0; mc_closed_settled "$(ago 1)" ) \
  && ok || bad "MC_CLOSED_SETTLE=0 must switch the guard off entirely"
( MC_CLOSED_SETTLE=3600; mc_closed_settled "$(ago 600)" ) \
  && bad "MC_CLOSED_SETTLE must be the knob that decides how long" || ok

# ============================================================================
# 2. bin/reconcile-prs.sh — a freshly closed PR keeps its console row
# ============================================================================
H="$T/r"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/builds"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/"
# The guard is ONE function in one place; this lane sources it exactly as
# bin/merge-sweep.sh does, and falls open when the lib is not there.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# BH-1583: the lane runs only on the reconcile owner and reads its knobs with no
# literal; this fixture box is armed as the owner (tests/lib/reconcile-fixture.sh).
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
printf 'demo-os Example/demo-os https://demo.example /api/board 2 box-a\n' > "$H/fleet.conf"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/deploy-request.sh"; chmod +x "$H/bin/deploy-request.sh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
BODY=""
while [ \$# -gt 0 ]; do case "\$1" in --data-binary|--data|-d) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$URL" in
  *"/api/builds/unmerged") printf '{"builds":[{"bkey":"demo-os-TK-9-202609150001","pr_url":"https://github.com/Example/demo-os/pull/9"}]}\n' ;;
  *"/api/builds/reconcile") printf '%s\n' "\$BODY" >> "$T/reconciled.txt"; printf '{"ok":true}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
mk_gh_closed() { # mk_gh_closed <closed-at>
  # reconcile-prs.sh's read is REST now too (BH-994/BH-1295): `gh api -i -X GET
  # repos/Example/demo-os/pulls/9`, judged on its HTTP status line, the exact
  # same shape section 3's mk_sweep_gh below already uses. closed_at is the
  # field the settle guard reads and restpr does not emit it, so the pull
  # object is hand-built and printed through `restpr --raw 200`.
  #
  # The SECOND arm answers the "no merge-conductor-lib.sh" fallback: without
  # the lib, mc_pr_view's own fallback (bin/reconcile-prs.sh) is REST too now
  # (drain-review F1b follow-up: a no-lib fallback must never reach for
  # GraphQL, since it is exactly the path that fires when things are already
  # degraded) — `gh api repos/…/pulls/9 -q '{STATE:…}'`, no `-i`/`-X GET`
  # (gh_rest's own shape, matched by the FIRST arm) since this call never goes
  # through gh_rest at all. A real `gh api -q FILTER` runs the filter itself
  # and prints the RESULT; this stub IS the whole of `gh`, so it prints that
  # same result directly rather than a raw object for a jq this process never
  # runs. Order matters: the more specific `-i -X GET` arm is tried first, so
  # the with-lib call (which also contains "repos/…/pulls/9") never falls
  # through to this one.
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api -i -X GET repos/Example/demo-os/pulls/9"*)
    restpr --raw 200 '{"state":"closed","merged_at":null,"closed_at":"$1","head":{"sha":"headsha","ref":"ticket/x"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"operator","type":"User"},"merge_commit_sha":null,"draft":false}' ;;
  *"api repos/Example/demo-os/pulls/9"*)
    jq -nc --arg c "$1" '{STATE:"CLOSED", closed_at:\$c, merged_at:null, merge_commit_sha:null}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
run_reconcile() { : > "$T/reconciled.txt"; : > "$H/logs/reconcile.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/rec.err" ) || true; }

mk_gh_closed "$(ago 30)"; run_reconcile
grep -q 'demo-os-TK-9' "$T/reconciled.txt" \
  && bad "a PR closed 30s ago must NOT have its build row cleared — the conductor's CI kick closes and reopens inside that window (sent: $(cat "$T/reconciled.txt"))" || ok
grep -qi 'settl' "$H/logs/reconcile.log" \
  && ok || bad "the skip must say why, or the row silently does nothing twice (log: $(cat "$H/logs/reconcile.log"))"
mk_gh_closed "$(ago 600)"; run_reconcile
grep -q 'demo-os-TK-9' "$T/reconciled.txt" \
  && ok || bad "a PR closed ten minutes ago is a real outcome and must still clear its row (sent: $(cat "$T/reconciled.txt"))"
grep -q 'cleared CLOSED' "$H/logs/reconcile.log" \
  && ok || bad "a settled closure must still log exactly as it did (log: $(cat "$H/logs/reconcile.log"))"
# WITHOUT THE LIB the lane must behave exactly as it did before the guard
# existed — a cron script that stopped reconciling because a lib went missing
# would be a worse failure than the race.
mv "$H/bin/lib/merge-conductor-lib.sh" "$T/lib-parked.sh"
mv "$H/bin/lib/mc" "$T/mc-parked"
mk_gh_closed "$(ago 30)"; run_reconcile
grep -q 'demo-os-TK-9' "$T/reconciled.txt" \
  && ok || bad "with no merge-conductor-lib.sh the guard must fail OPEN and clear the row as it always did (sent: $(cat "$T/reconciled.txt"))"
mv "$T/lib-parked.sh" "$H/bin/lib/merge-conductor-lib.sh"
mv "$T/mc-parked" "$H/bin/lib/mc"

# ============================================================================
# 3. bin/merge-sweep.sh — a freshly closed PR is not ledgered as terminal
# ============================================================================
S="$T/s"
mkdir -p "$S/bin/lib" "$S/logs" "$S/state" "$S/flags" "$S/locks" "$S/env" "$S/tmp" "$S/builds"
cp "$DIR/bin/merge-sweep.sh" "$S/bin/sweep.sh"
mkdir -p "$S/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$S/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$S/bin/"
mkdir -p "$S/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$S/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$S/bin/lib/"
mkdir -p "$S/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$S/bin/lib/mc/"
printf 'p o/plain - - 3 box-p\n' > "$S/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/$s"; chmod +x "$S/bin/$s"; done
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl2"; chmod +x "$T/fakebin/curl2"
sweep_setup() {
  scratch_rm "$S/builds"; mkdir -p "$S/builds/pool-p-XX-8-202609150001"
  echo "PR_CREATED https://github.com/o/plain/pull/8" > "$S/builds/pool-p-XX-8-202609150001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$S/builds/pool-p-XX-8-202609150001/review.md"
  : > "$S/builds/pool-p-XX-8-202609150001/pipeline.log"
  : > "$S/state/merge-sweep-done.txt"; : > "$S/logs/merge-sweep.log"; : > "$S/logs/ALERTS.log"
}
mk_sweep_gh() { # mk_sweep_gh <closed-at>
  # The sweep's PR read is REST now (BH-784): `gh api -i -X GET repos/o/plain/
  # pulls/8`, judged on its HTTP status line. closed_at is the field the settle
  # guard reads and restpr does not emit it, so the pull object is hand-built and
  # printed through `restpr --raw 200` — CLOSED is state "closed" with merged_at
  # null, which is exactly what must not be read as a merge.
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/o/plain/rulesets"*) : ;;
  "api repos/o/plain -q .id") echo 1 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/o/plain/pulls/8"*)
    restpr --raw 200 '{"state":"closed","merged_at":null,"closed_at":"$1","head":{"sha":"headsha","ref":"ticket/x"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"operator","type":"User"},"merge_commit_sha":null,"draft":false}' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/sweep-merge-calls.txt"; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
run_sweep() { ( cd "$S" && PATH="$T/fakebin:$PATH" HARNESS="$S" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
    bash "$S/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) || true; }
# The sweep's own curl must 404 (no ledger rows), like the other sweep suites.
cp "$T/fakebin/curl2" "$T/fakebin/curl"

sweep_setup; mk_sweep_gh "$(ago 30)"; run_sweep
grep -qxF 'https://github.com/o/plain/pull/8' "$S/state/merge-sweep-done.txt" \
  && bad "a PR closed 30s ago must NOT be ledgered closed — sweep_seen makes that permanent and the conductor is about to reopen it" || ok
grep -qi 'settl' "$S/logs/merge-sweep.log" \
  && ok || bad "the sweep must say why it skipped the PR (log: $(cat "$S/logs/merge-sweep.log"))"
sweep_setup; mk_sweep_gh "$(ago 600)"; run_sweep
# BH-1601: a settled CLOSED PR is no longer recorded at all (only MERGED is
# permanent) — it is logged and re-read live, so a later reopen is swept.
grep -qxF 'https://github.com/o/plain/pull/8' "$S/state/merge-sweep-done.txt" \
  && bad "a PR closed ten minutes ago must NOT be recorded — only MERGED is permanent (BH-1601) (done: $(cat "$S/state/merge-sweep-done.txt"))" || ok
grep -q 'pull/8 reads CLOSED — not recorded, re-read live next pass' "$S/logs/merge-sweep.log" \
  && ok || bad "a settled closure must say it is re-read live (log: $(cat "$S/logs/merge-sweep.log"))"

echo "closed-settle-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
