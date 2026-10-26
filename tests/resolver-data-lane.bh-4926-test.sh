#!/bin/bash
# tests/resolver-data-lane.bh-4926-test.sh — bin/blocked-resolver.sh parks a
# review block whose ONLY finding is an unapplied migration (a DATA_LANE: line,
# bin/lib/data-lane.sh) as outcome DATA_LANE instead of walking the
# rebuild-review-blocked -> abandon-rebuild ladder (BH-4926, BH-4920 slice 4).
# TK-32 was ABANDONED that way and TK-40..42 sat three days.
#   §1  park: DATA_LANE over two ticks, nothing abandoned, closed or enqueued
#   §2  a flagged / failed ledger: exactly one escalation over two ticks
#   §3  no apply path (DATA_LANE_APP_BASE empty): exactly one escalation
#   §4  a second BLOCK: today's rung, logged (rebuild-fresh / abandon-rebuild)
#   §5  NEEDS_HUMAN with no DATA_LANE line: the needs-human path, unchanged
#   §6  negatives: `..` path, a path not in the diff, the placeholder
#   §7  ledger unknown: held, no alert, no re-review
#   §8  applied + probe at this fp: ONE same-head re-review, probe in the prompt
#   §9  applied, no probe: nothing released
#   §10 a probe with another fp: nothing released
#   §11 br_abandon on a DATA_LANE row refuses and closes nothing
#   §12 a rebuild-review-blocked row (rebuild source) parks, not abandon-rebuild
#   §13 review-changes-requested (record `-`) parks through the newest build dir
#   §13b a lead/human CHANGES_REQUESTED on the same head: not parked, fix round
#   §13c a lane CHANGES_REQUESTED with no DATA_LANE line: not parked
#   §13d the PR head moved past the record's review-head: handed to the ladder
#   §14 the PR head moved past the reviewed sha: nothing released, the park is
#       handed back to the ladder once (data_lane_unbound) and never re-taken
#   §15 a BLOCK already bought on this head is not reused by the release
#   §16 a release that read nothing, or got no verdict, is asked again
#   §18 (lead BLOCK dbed6c45, loop 2) a BUILD_DEAD row the route never parked,
#       at the rebuild cap, whose record's review has a DATA_LANE line: the
#       ladder ran out, so it is ABANDONED (the guard refuses only a park)
#   §19 (loop 1) §13b's lead CHANGES_REQUESTED on another bug, at the fix cap:
#       the review terminal records ABANDONED, never "ABANDON refused"
#   §20 (the rc 2 arm) a DATA_LANE row whose reviewed sha cannot be read, at
#       the rebuild cap: refused, and escalated ONCE over two ticks
#   §11 also: the refused park is escalated once, never silent
#   §21 (the route's rc 2 arm) a park whose review stays unreadable: held,
#       and escalated once at BR_DL_UNREADABLE_MAX (3) ticks, never again; its
#       missing sha is fetched once in 4 ticks (the miss stamp, lead NOTE)
#   §23 (lead BLOCK on 0d5f96563) the fetch-miss window runs from the last REAL
#       fetch: a tick inside the window neither fetches nor moves the stamp, so
#       once BR_DL_FETCH_MISS_S has passed since that fetch, the sha is fetched
#       again (the clock is moved by aging the stamp, as time would)
#   §22 (lead NOTE) a release tick runs none of the carry, conflict, CI-cap or
#       stale seams; a fix-round tick does (the probe's control)
#   §17 a final MERGED RE-REVIEW round carries the SHORT head sha review.sh
#       writes, over a stale review-head: it parks (17a) and releases once
#       (17b), never "the PR head moved" (lead review of 1082bfb4)
# The real bin/blocked-resolver.sh is driven end to end in a scratch tree; gh,
# lane-alert, run-build, agent-call and the jobs client are RECORDED.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The re-review's APPROVE is read by bin/lib/verdict-parse.sh, whose window a
# scratch harness has no catalog to resolve (tests/lib/verdict-fixture.sh).
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
# Stubs FIRST: scratch_install_closure never clobbers a file already there.
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
# The reviewer: argv to agent-call.txt, the prompt file (arg 6, "@<file>") kept,
# and a Claude APPROVE written to the OUT file (arg 5) the way agent-call.sh does.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent-call.txt"
cp "\${6#@}" "$T/prompt.txt" 2>/dev/null
case "\$(cat "$T/reviewer-mode" 2>/dev/null)" in
  silent)    : > "\$5" ;;
  noverdict) printf 'I read the diff and have no opinion.\n' > "\$5" ;;
  *)         printf 'The migration was applied ahead of merge and probed.\nTIER: 2\nVERDICT: APPROVE\n' > "\$5" ;;
esac
printf 'claude\n' > "\$5.runner"
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/placer.txt"\nexit 0\n' "$T" > "$H/bin/needs-human-hold.sh"
# The jobs client: queue writes recorded, the migration ledger answered from
# $T/ledger.tsv (<key>\t<status>; absent row rc 2, $T/ledger-unknown rc 1).
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
# A reachable jobs worker with no artifact rows: bor_union answers from the local records.
job_artifact_feed() { return 0; }
# §15: the review lane already bought a BLOCK on this head (review_bought's D1
# rrverdict row). Defined only when $T/rr-block exists, so no other case sees it.
if [ -f "$T/rr-block" ]; then
  _jobs_req() { return 2; }
  job_verdict_history() { return 2; }
  pr_attempt_list() { printf '%s BLOCK %s claude\n' "\$(cat "$T/rr-block")" "\$(date -u +%s)"; }
fi
job_ledger_put() { printf '%s\n' "\$*" >> "$T/ledger-put.txt"; return 0; }
job_ledger_get() {
  [ -f "$T/ledger-unknown" ] && return 1
  local row; row=\$(awk -F'\t' -v k="\$2" '\$1 == k {print \$2; exit}' "$T/ledger.tsv" 2>/dev/null)
  [ -n "\$row" ] || return 2
  printf '%s' "\$row"
}
EOF
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || { echo "FAIL: closure install (resolver)"; exit 1; }
# bin/lib/data-lane.sh loads needs-human.sh from beside itself, a path the
# closure walk cannot resolve statically; the sibling lane's closure carries it.
scratch_install_closure bin/data-lane-apply.sh "$H" >/dev/null || { echo "FAIL: closure install (data-lane)"; exit 1; }
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# THE REPO: main, plus the ticket branch that adds the migration script.
TS=scripts/migrate-client-redtail-status.ts
REPO="$T/repos/tproj"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo base > "$REPO/README"; git -C "$REPO" add README; git -C "$REPO" commit -qm base
git -C "$REPO" checkout -qb ticket/TK-9
mkdir -p "$REPO/scripts"
printf 'await db.execute("ALTER TABLE clients ADD COLUMN redtail_status text");\n' > "$REPO/$TS"
echo page > "$REPO/page.tsx"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "TK-9: redtail status"
HEADSHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" fetch -q origin
git -C "$REPO" remote set-head origin main
FPV=$(git -C "$REPO" show "$HEADSHA:$TS" | sha1sum | cut -c1-40)
OTHERSHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

RLOG="$H/logs/blocked-resolver.log"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" HARNESS_SECRET=test-secret JOBS_URL= HARNESS_WORKERS_SUBDOMAIN= \
           MC_RR_LIVE_CI=0 \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/${1:-tproj-TK-9}.json" 2>/dev/null; }
OUTCOME() { STATEJSON | jq -r '.outcome // ""'; }
NACT() { STATEJSON | jq --arg a "$1" '[.attempts[]? | select(.action == $a)] | length'; }
NLINES() { grep -c -- "$1" "$2" 2>/dev/null || true; }
NOABANDON() { # NOABANDON <section>
  local n
  n=$(cat "$H/state/blocked-resolver/tproj/"*.json "$RLOG" "$H/logs/ALERTS.log" 2>/dev/null | grep -c ABANDONED)
  [ "$n" = 0 ] && ok || bad "$1: ABANDONED appears $n time(s): $(grep -h ABANDONED "$RLOG" "$H/logs/ALERTS.log" 2>/dev/null | head -3)"
  [ -s "$T/closed.txt" ] && bad "$1: a PR was closed: $(cat "$T/closed.txt")" || ok
  grep -qE 'pr merge|merge-queue|-X PUT.*/merge' "$T/gh.txt" && bad "$1: a merge was asked for" || ok
  grep -q . <<<"$(grep -v '^done ' "$T/queue.txt" 2>/dev/null)" && bad "$1: something was enqueued: $(cat "$T/queue.txt")" || ok
  [ -s "$T/run-build.txt" ] && bad "$1: a build was started: $(cat "$T/run-build.txt")" || ok
}

# A review whose final round has exactly one blocking finding and a DATA_LANE line.
REVIEW_DL="# Review of TK-9

The diff adds the redtail status column and its backfill.

- **B1.** src/app/clients/page.tsx reads the new column, but $TS is not applied to prod yet, so the page throws on load.
DATA_LANE: $TS
TIER: 2
VERDICT: BLOCK"
# RECORD <result-line> <age-secs> <review-body> — the build record of TK-9.
RECORD() {
  local r="$H/builds/tproj-TK-9-202610060001"
  scratch_rm "$r"; mkdir -p "$r"
  printf '%s\nTICKET_ID: 9\n' "$1" > "$r/RESULT"
  printf '%s\n' "$3" > "$r/review.md"
  printf '%s\n' "$HEADSHA" > "$r/review-head"
  printf 'ticket/TK-9\n' > "$r/branch"
  : > "$r/.review-rescued"
  touch -d "@$((NOW - $2))" "$r/RESULT"
  printf '%s' "$r"
}
# The open PR on the ticket branch, at head $1 (the live head the release reads).
OPENPR() {
  printf '%s' "$1" > "$T/prhead"; printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: redtail' > "$T/prtitle"
  jq -nc --arg h "$1" --arg u "$(ISO 600)" \
    '[{number:9, html_url:"https://github.com/o/tproj/pull/9", title:"TK-9: redtail", body:"b",
       head:{sha:$h, ref:"ticket/TK-9"}, base:{ref:"main"}, draft:false,
       user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
       merged_at:null, closed_at:null, labels:[], state:"open"}]' > "$T/openprs"
}
LEDGER() { printf 'tproj %s\t%s\n' "$TS" "$1" > "$T/ledger.tsv"; }
PROBE() { printf '# data-lane probe\nSELECT redtail_status FROM clients LIMIT 1 -> ok\nfp=%s\n' "$1" > "$REC/data-lane-probe.md"; }
FRESH() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
  : > "$H/state/merge-conductor/pr-state.tsv"
  : > "$RLOG"; rm -f "$H/logs/ALERTS.log"
  for f in gh.txt closed.txt queue.txt lane-alert.txt run-build.txt agent-call.txt placer.txt \
           comments.txt comment-bodies.txt ledger-put.txt mergedprs; do : > "$T/$f"; done
  rm -f "$T/ledger.tsv" "$T/ledger-unknown" "$T/reviewer-mode" "$T/prompt.txt" "$T/openprs" "$T/prhead" "$T/reviews-9.json"
  printf 'DATA_LANE_APP_BASE=https://iproj.test\n' > "$H/env/tproj.env"
}
AGENT_RUNS() { grep -c . "$T/agent-call.txt" 2>/dev/null || true; }
ALERTS_DL() { grep -c 'data-lane-escalate:' "$T/lane-alert.txt" 2>/dev/null || true; }

# ── §1: the park ───────────────────────────────────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "1: tick 1 must park DATA_LANE, got '$(OUTCOME)': $(tail -5 "$RLOG")"
: > "$RLOG"
RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "1: tick 2 must stay DATA_LANE, got '$(OUTCOME)'"
grep -q 'DATA_LANE' "$RLOG" && ok || bad "1: tick 2 still offers the row and logs its data-lane line: $(cat "$RLOG")"
[ "$(NACT data-lane-parked)" = 1 ] && ok || bad "1: exactly one data-lane-parked attempt, got $(NACT data-lane-parked)"
[ "$(STATEJSON | jq -r '.data_lane_fp // ""')" = "$FPV" ] && ok || bad "1: data_lane_fp must be the file's fp"
[ "$(STATEJSON | jq -r '.rebuilds // 0')" = 0 ] && ok || bad "1: no rung spent"
grep -q -- '-> ' "$RLOG" && bad "1: no rung line on a parked tick: $(grep -- '-> ' "$RLOG")" || ok
NOABANDON 1
[ "$(ALERTS_DL)" = 0 ] && ok || bad "1: a configured lane with no ledger row waits, no alert: $(cat "$T/lane-alert.txt")"

# ── §2: flagged / failed ledger: one escalation ────────────────────────────
for st in "flagged PR#9 head=${HEADSHA:0:12} fp=$FPV" "failed apply PR#9 head=${HEADSHA:0:12} fp=$FPV"; do
  FRESH
  REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
  LEDGER "$st"
  RUN; RUN
  [ "$(ALERTS_DL)" = 1 ] && ok || bad "2 ($st): exactly one escalation alert over two ticks, got $(ALERTS_DL): $(cat "$T/lane-alert.txt")"
  grep -q "data-lane-escalate:tproj:TK-9:$FPV" "$T/lane-alert.txt" && ok || bad "2 ($st): the alert id: $(cat "$T/lane-alert.txt")"
  [ "$(NACT escalate-data-lane)" = 1 ] && ok || bad "2 ($st): exactly one escalate-data-lane row, got $(NACT escalate-data-lane)"
  [ "$(STATEJSON | jq -r '.data_lane_escalated // ""')" = "$FPV" ] && ok || bad "2 ($st): data_lane_escalated must be the fp"
  [ "$(OUTCOME)" = DATA_LANE ] && ok || bad "2 ($st): stays DATA_LANE, got '$(OUTCOME)'"
  NOABANDON "2 ($st)"
done

# ── §3: no apply path ──────────────────────────────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
printf 'DATA_LANE_APP_BASE=\n' > "$H/env/tproj.env"
RUN; RUN
[ "$(ALERTS_DL)" = 1 ] && ok || bad "3: exactly one escalation over two ticks, got $(ALERTS_DL)"
grep -q 'no apply path' "$T/lane-alert.txt" && ok || bad "3: the alert says no apply path: $(cat "$T/lane-alert.txt")"
[ "$(NACT escalate-data-lane)" = 1 ] && ok || bad "3: one escalate-data-lane row, got $(NACT escalate-data-lane)"
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "3: stays DATA_LANE"
NOABANDON 3

# ── §4: a second BLOCK: today's ladder ─────────────────────────────────────
REVIEW_2B="$REVIEW_DL
- **B2.** The parser reads an empty status as active (D11)."
REVIEW_2B=$(printf '%s\n' "$REVIEW_2B" | grep -v '^TIER:\|^VERDICT:'; printf 'TIER: 2\nVERDICT: BLOCK\n')
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_2B")
RUN
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "4: a second BLOCK must not park"
grep -q 'build/rescue-giving-up\] -> rebuild-fresh' "$RLOG" && ok || bad "4: today's rung logged: $(grep -- '-> ' "$RLOG")"
# …and the rebuild source's row walks to abandon-rebuild exactly as before.
FRESH
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 7200)" '{attempts:[{at:$at,action:"rebuild-fresh",reason:"rescue-giving-up",detail:"x"}],
       rebuilds:1, mechanicals:0, fixrounds:0, outcome:"", parked_url:"-"}' > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
REC=$(RECORD "REVIEW_BLOCKED see review.md" 600 "$REVIEW_2B")
RUN
grep -q 'rebuild-review-blocked\] -> abandon-rebuild' "$RLOG" && ok || bad "4: rebuild-review-blocked keeps abandon-rebuild: $(grep -- '-> ' "$RLOG")"

# ── §5: NEEDS_HUMAN, no DATA_LANE: the needs-human path ────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md NEEDS_HUMAN:abc123def456:run scripts/migrate-x.ts against prod" 10800 \
      "- **B1.** NEEDS_HUMAN: run scripts/migrate-x.ts against prod
TIER: 2
VERDICT: BLOCK")
RUN
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "5: no DATA_LANE line, no park"
[ "$(grep -c . "$T/placer.txt")" = 1 ] && ok || bad "5: the needs-human placer still runs once, got $(grep -c . "$T/placer.txt")"

# ── §6: negatives ──────────────────────────────────────────────────────────
for line in "DATA_LANE: ../../etc/x.sql" "DATA_LANE: scripts/migrate-other-thing.ts" "DATA_LANE: <path>"; do
  FRESH
  REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$(printf '%s\n' "$REVIEW_DL" | sed "s#^DATA_LANE: .*#$line#")")
  RUN
  [ "$(OUTCOME)" != DATA_LANE ] && ok || bad "6 ($line): must not park"
  grep -q 'build/rescue-giving-up\] -> rebuild-fresh' "$RLOG" && ok || bad "6 ($line): today's rung: $(grep -- '-> ' "$RLOG")"
done

# ── §7: ledger unknown ─────────────────────────────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
: > "$T/ledger-unknown"; PROBE "$FPV"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "7: unknown holds DATA_LANE, got '$(OUTCOME)'"
[ "$(ALERTS_DL)" = 0 ] && ok || bad "7: unknown never alerts here: $(cat "$T/lane-alert.txt")"
[ "$(AGENT_RUNS)" = 0 ] && ok || bad "7: unknown never releases, got $(AGENT_RUNS) re-review(s)"
NOABANDON 7

# ── §8: applied + probe: one same-head re-review ───────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 1 ] && ok || bad "8: exactly one re-review over two ticks, got $(AGENT_RUNS): $(grep 'data-lane' "$RLOG" | tail -5)"
[ "$(NLINES '\[data-lane-rereview\]: extra re-review APPROVED' "$RLOG")" = 1 ] && ok \
  || bad "8: one [data-lane-rereview] APPROVE line: $(grep 'data-lane-rereview' "$RLOG")"
grep -q "data-lane-rereview\]: extra re-review APPROVED ${HEADSHA:0:8}" "$RLOG" && ok || bad "8: the re-review names the reviewed head"
grep -qF "fp=$FPV" "$T/prompt.txt" 2>/dev/null && ok || bad "8: the prompt carries the probe as evidence"
grep -q 'EVIDENCE GATHERED BY THE HARNESS' "$T/prompt.txt" 2>/dev/null && ok || bad "8: the evidence block is labelled"
# Lead NOTE on dbed6c45: the header claims only what the release checked.
grep -q "the migration ledger says $TS is applied at fp ${FPV:0:12}, and this probe file names that fp" "$T/prompt.txt" 2>/dev/null && ok \
  || bad "8: the evidence header names what the release checked: $(grep 'EVIDENCE GATHERED' "$T/prompt.txt")"
grep -q 'applied to prod ahead of merge and probed' "$T/prompt.txt" 2>/dev/null && bad "8: the unchecked claim is gone from the header" || ok
[ "$(STATEJSON | jq -r '.data_lane_released // ""')" = "$FPV $HEADSHA" ] && ok || bad "8: data_lane_released = '<fp> <head>', got '$(STATEJSON | jq -r '.data_lane_released // ""')'"
[ "$(NACT data-lane-released)" = 1 ] && ok || bad "8: one data-lane-released row, got $(NACT data-lane-released)"
[ "$(cat "$REC/reviewed-sha" 2>/dev/null)" = "$HEADSHA" ] && ok || bad "8: the APPROVE is bound to the reviewed head"
NOABANDON 8

# ── §9: applied, no probe ──────────────────────────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 0 ] && ok || bad "9: no probe, no re-review, got $(AGENT_RUNS)"
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "9: stays DATA_LANE"
grep -q 'no probe yet' "$RLOG" && ok || bad "9: the log says the release waits on the probe"

# ── §10: a probe with another fp ───────────────────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "0000000000000000000000000000000000000000"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 0 ] && ok || bad "10: a probe of another fp releases nothing, got $(AGENT_RUNS)"
# …and an applied ledger at another fp releases nothing either.
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=0000000000000000000000000000000000000000"; PROBE "$FPV"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 0 ] && ok || bad "10: a ledger at another fp releases nothing, got $(AGENT_RUNS)"

# ── §11: br_abandon refuses a data-lane park ───────────────────────────────
# A DATA_LANE row that reaches the abandon terminal by another road: a
# BUILD_DEAD record (a reason the route does not take) at the rebuild cap, so
# br_rebuild_fresh calls br_abandon. The guard refuses it, once, and closes nothing.
FRESH
REC=$(RECORD "BUILD_DEAD the machine went away" 10800 "$REVIEW_DL")
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 20000)" --arg fp "$FPV" --arg f "$TS" \
  '{attempts:[{at:$at,action:"data-lane-parked",reason:"rescue-giving-up",detail:"x"}],
    rebuilds:3, mechanicals:0, fixrounds:0, outcome:"DATA_LANE", data_lane_fp:$fp, data_lane_file:$f, parked_url:"-"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q 'build/build-dead\] -> rebuild-fresh' "$RLOG" && ok || bad "11: precondition: the rebuild rung ran: $(grep -- '-> ' "$RLOG")"
[ "$(NLINES 'ABANDON refused' "$RLOG")" = 1 ] && ok || bad "11: one 'ABANDON refused' line: $(tail -5 "$RLOG")"
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "11: still DATA_LANE, got '$(OUTCOME)'"
[ "$(NACT abandoned)" = 0 ] && ok || bad "11: no abandoned attempt"
NOABANDON 11
grep -q 'abandoned' "$T/ledger-put.txt" && bad "11: no abandoned ledger row: $(cat "$T/ledger-put.txt")" || ok
# Lead BLOCK dbed6c45: a refused park is never silent. One escalation, and a
# second tick adds none.
[ "$(ALERTS_DL)" = 1 ] && ok || bad "11: the refused park is escalated once, got $(ALERTS_DL): $(cat "$T/lane-alert.txt")"
RUN
[ "$(ALERTS_DL)" = 1 ] && ok || bad "11: a second tick adds no escalation, got $(ALERTS_DL)"

# ── §12: a rebuild-review-blocked row parks ────────────────────────────────
FRESH
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 7200)" '{attempts:[{at:$at,action:"rebuild-fresh",reason:"rescue-giving-up",detail:"x"}],
       rebuilds:1, mechanicals:0, fixrounds:0, outcome:"", parked_url:"-"}' > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
# Ten minutes old: inside br_from_builds' 90-minute floor, so only the rebuild source offers it.
REC=$(RECORD "REVIEW_BLOCKED see review.md" 600 "$REVIEW_DL")
RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "12: rebuild-review-blocked parks DATA_LANE, got '$(OUTCOME)': $(tail -5 "$RLOG")"
grep -q 'rebuild-review-blocked' "$RLOG" && ok || bad "12: arrived as rebuild-review-blocked"
grep -q -- '-> abandon-rebuild' "$RLOG" && bad "12: never abandon-rebuild" || ok
: > "$RLOG"
RUN
grep -q 'rebuild-review-blocked.*DATA_LANE' "$RLOG" && ok || bad "12: tick 2 still offers the parked rebuild row: $(cat "$RLOG")"
NOABANDON 12

# ── §13: review-changes-requested through the newest build dir ─────────────
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$HEADSHA"
# LANEREVIEW <data-lane-line|-> — the lane's own CHANGES_REQUESTED on $HEADSHA.
# BH-8419: the lane's review is the App's (cromford[bot], type Bot).
LANEREVIEW() {
  local dl=""; [ "$1" = - ] || dl="$1"$'\n'
  jq -nc --arg c "$HEADSHA" --arg b "$(printf 'Findings.\n\n%sTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of %s. Static review._\n' "$dl" "$HEADSHA")" \
    '{id:11, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"cromford[bot]", type:"Bot"}, body:$b}'
}
jq -s . <(LANEREVIEW "DATA_LANE: $TS") > "$T/reviews-9.json"
RUN
grep -q 'review-changes-requested' "$RLOG" && ok || bad "13: the review source offered it: $(head -5 "$RLOG")"
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "13: review-changes-requested parks DATA_LANE, got '$(OUTCOME)': $(tail -5 "$RLOG")"
grep -q -- '-> fix-round' "$RLOG" && bad "13: no fix round on a data-lane park" || ok

# ── §13b: a lead/human CHANGES_REQUESTED on an unrelated bug, same head ─────
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$HEADSHA"
jq -s . <(LANEREVIEW "DATA_LANE: $TS") \
  <(jq -nc --arg c "$HEADSHA" '{id:12, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"lead-person", type:"User"}, author_association:"MEMBER",
       body:"- [BLOCK] src/app/clients/page.tsx: the filter drops archived clients."}') > "$T/reviews-9.json"
RUN
grep -q 'review-changes-requested' "$RLOG" && ok || bad "13b: the review source offered it: $(head -5 "$RLOG")"
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "13b: a lead CHANGES_REQUESTED must not park DATA_LANE: $(tail -5 "$RLOG")"
grep -q 'not the record.s data-lane BLOCK' "$RLOG" && ok || bad "13b: the log names why it was not parked: $(tail -5 "$RLOG")"
grep -q -- '-> fix-round' "$RLOG" && ok || bad "13b: the fix round runs on the lead's findings: $(grep -- '-> ' "$RLOG")"
grep -qsF '"data-lane-parked"' "$H/state/blocked-resolver/tproj/"*.json \
  && bad "13b: no data-lane-parked row on any record" || ok

# ── §13c: the lane's CHANGES_REQUESTED carries no DATA_LANE line ────────────
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$HEADSHA"
jq -s . <(LANEREVIEW -) > "$T/reviews-9.json"
RUN
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "13c: a PR review with no DATA_LANE line must not park: $(tail -5 "$RLOG")"
grep -q -- '-> fix-round' "$RLOG" && ok || bad "13c: the fix round runs: $(grep -- '-> ' "$RLOG")"

# ── §13d: the PR head moved past the record's review-head ──────────────────
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$OTHERSHA"
jq -nc --arg c "$OTHERSHA" --arg b "$(printf 'Findings.\n\nDATA_LANE: %s\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of %s. Static review._\n' "$TS" "$OTHERSHA")" \
  '[{id:13, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"cromford[bot]", type:"Bot"}, body:$b}]' > "$T/reviews-9.json"
RUN
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "13d: a moved head must not park on the old review: $(tail -5 "$RLOG")"
[ "$(STATEJSON | jq -r '.data_lane_unbound // ""')" = "$FPV $HEADSHA" ] && ok || bad "13d: data_lane_unbound = '<fp> <reviewed head>'"
grep -q -- '-> fix-round' "$RLOG" && ok || bad "13d: the ladder runs: $(grep -- '-> ' "$RLOG")"

# ── §14: the head moved past the reviewed sha ──────────────────────────────
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$OTHERSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 0 ] && ok || bad "14: a moved head releases nothing, got $(AGENT_RUNS)"
grep -q 'head moved' "$RLOG" && ok || bad "14: the log says the head moved: $(grep data-lane "$RLOG" | tail -3)"
[ "$(STATEJSON | jq -r '.data_lane_released // ""')" = "" ] && ok || bad "14: nothing stamped released"
# Not stuck: the park is handed back once, on the record, and the next tick's
# route does not re-take the same fp+head.
[ "$(OUTCOME)" != DATA_LANE ] && ok || bad "14: a moved head must not stay parked, got '$(OUTCOME)'"
[ "$(STATEJSON | jq -r '.data_lane_unbound // ""')" = "$FPV $HEADSHA" ] && ok || bad "14: data_lane_unbound = '<fp> <reviewed head>'"
[ "$(NACT data-lane-unbound)" = 1 ] && ok || bad "14: exactly one data-lane-unbound row over two ticks, got $(NACT data-lane-unbound)"
[ "$(NACT data-lane-parked)" = 1 ] && ok || bad "14: parked once, never re-parked on the same fp+head, got $(NACT data-lane-parked)"

# ── §15: a BLOCK already bought on this head is not reused by the release ──
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$HEADSHA"
printf '%s' "$HEADSHA" > "$T/rr-block"
RUN
rm -f "$T/rr-block"
[ "$(AGENT_RUNS)" = 1 ] && ok || bad "15: the release buys its own read, never the BLOCK bought before the apply, got $(AGENT_RUNS) run(s)"
grep -q 'review_skip_unchanged' "$RLOG" && bad "15: the stored BLOCK was reused: $(grep review_skip_unchanged "$RLOG")" || ok
[ "$(NACT data-lane-released)" = 1 ] && ok || bad "15: the APPROVE releases it, got $(NACT data-lane-released)"

# ── §16: a release that read nothing gives its claim back; no verdict asks again ──
for mode in silent noverdict; do
  FRESH
  REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
  LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$HEADSHA"
  printf '%s' "$mode" > "$T/reviewer-mode"
  RUN
  [ "$(STATEJSON | jq -r '.data_lane_released // ""')" = "-" ] && ok || bad "16 ($mode): the claim is given back, got '$(STATEJSON | jq -r '.data_lane_released // ""')'"
  [ "$(OUTCOME)" = DATA_LANE ] && ok || bad "16 ($mode): stays DATA_LANE, got '$(OUTCOME)'"
  RUN
  rm -f "$T/reviewer-mode"
  [ "$(AGENT_RUNS)" = 2 ] && ok || bad "16 ($mode): the next tick asks again, got $(AGENT_RUNS) run(s)"
  NOABANDON "16 ($mode)"
done

# ── §17: the merged re-review header's SHORT sha is the reviewed head ───────
# bin/lib/rb/review.sh writes `(head $(git rev-parse --short HEAD))` into the
# final merged round, and dl_reviewed_sha reads it (7 to 40 hex). review-head
# still holds the pre-fix head. The resolver must take the short sha as the
# PR head it names, not as "the head moved".
MERGED_DL="$REVIEW_DL

=== MERGED RE-REVIEW after the single fix round (head ${HEADSHA:0:9}) ===
- **B1.** Only the unapplied migration is left.
DATA_LANE: $TS
TIER: 2
VERDICT: BLOCK"
STALE=$(printf 'stale-review-head' | sha1sum | cut -c1-40)
# 17a: review-changes-requested through the newest build dir parks DATA_LANE.
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$MERGED_DL")
printf '%s\n' "$STALE" > "$REC/review-head"
OPENPR "$HEADSHA"
jq -s . <(LANEREVIEW "DATA_LANE: $TS") > "$T/reviews-9.json"
RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "17a: a short-sha merged round on the PR head parks DATA_LANE, got '$(OUTCOME)': $(tail -5 "$RLOG")"
grep -q 'head moved' "$RLOG" && bad "17a: the short sha read as 'the PR head moved': $(grep 'head moved' "$RLOG")" || ok
[ "$(NACT data-lane-unbound)" = 0 ] && ok || bad "17a: no unbind, got $(NACT data-lane-unbound)"
NOABANDON 17a
# 17b: applied + probe on that record: ONE re-review, bound to the FULL head.
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$MERGED_DL")
printf '%s\n' "$STALE" > "$REC/review-head"
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$HEADSHA"
RUN; RUN
[ "$(AGENT_RUNS)" = 1 ] && ok || bad "17b: exactly one re-review, got $(AGENT_RUNS): $(grep 'data-lane' "$RLOG" | tail -5)"
grep -q 'head moved' "$RLOG" && bad "17b: release refused as 'the PR head moved': $(grep 'head moved' "$RLOG")" || ok
[ "$(STATEJSON | jq -r '.data_lane_released // ""')" = "$FPV $HEADSHA" ] && ok \
  || bad "17b: data_lane_released keys the FULL head, got '$(STATEJSON | jq -r '.data_lane_released // ""')'"
[ "$(cat "$REC/reviewed-sha" 2>/dev/null)" = "$HEADSHA" ] && ok || bad "17b: the APPROVE is bound to the full head, got '$(cat "$REC/reviewed-sha" 2>/dev/null)'"
NOABANDON 17b

# ── §18: a row the route never parked, at the rebuild cap: ABANDONED ───────
# Lead BLOCK dbed6c45, loop 2. The record's older review has a DATA_LANE line,
# but the row is BUILD_DEAD (a reason the route does not take) and was never
# parked. The guard used to refuse it on every tick, with no alert.
FRESH
REC=$(RECORD "BUILD_DEAD the machine went away" 10800 "$REVIEW_DL")
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 20000)" '{attempts:[{at:$at,action:"rebuild-fresh",reason:"build-dead",detail:"x"}],
    rebuilds:3, mechanicals:0, fixrounds:0, outcome:"", parked_url:"-"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q 'ABANDON refused' "$RLOG" && bad "18: a row the route never parked must not be refused: $(grep 'ABANDON refused' "$RLOG")" || ok
[ "$(OUTCOME)" = ABANDONED ] && ok || bad "18: the exhausted ladder records ABANDONED, got '$(OUTCOME)': $(tail -5 "$RLOG")"

# ── §19: §13b's lead CHANGES_REQUESTED at the fix cap: ABANDONED ───────────
# Loop 1. The route says "not parked, the ladder runs"; once the fix rounds are
# spent, the review terminal (br_fix_terminal) abandons. It must not be refused.
FRESH
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$HEADSHA"
jq -s . <(LANEREVIEW "DATA_LANE: $TS") \
  <(jq -nc --arg c "$HEADSHA" '{id:12, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"lead-person", type:"User"}, author_association:"MEMBER",
       body:"- [BLOCK] src/app/clients/page.tsx: the filter drops archived clients."}') > "$T/reviews-9.json"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 20000)" '{attempts:[{at:$at,action:"fix-round",reason:"review-changes-requested",detail:"x"}],
    rebuilds:0, mechanicals:9, fixrounds:9, outcome:"", parked_url:"https://github.com/o/tproj/pull/9"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q 'ABANDON refused' "$RLOG" && bad "19: the lead's CHANGES_REQUESTED at the cap must not be refused: $(grep 'ABANDON refused' "$RLOG")" || ok
[ "$(OUTCOME)" = ABANDONED ] && ok || bad "19: the fix-cap terminal records ABANDONED, got '$(OUTCOME)': $(grep -- '-> \|ABANDON' "$RLOG" | tail -5)"

# ── §20: a DATA_LANE park whose reviewed sha cannot be read ────────────────
# The rc 2 arm: refused (it is a park), and escalated once, not held silently.
FRESH
REC=$(RECORD "BUILD_DEAD the machine went away" 10800 "$REVIEW_DL")
printf 'cccccccccccccccccccccccccccccccccccccccc\n' > "$REC/review-head"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 20000)" --arg fp "$FPV" --arg f "$TS" \
  '{attempts:[{at:$at,action:"data-lane-parked",reason:"rescue-giving-up",detail:"x"}],
    rebuilds:3, mechanicals:0, fixrounds:0, outcome:"DATA_LANE", data_lane_fp:$fp, data_lane_file:$f, parked_url:"-"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN; RUN
[ "$(OUTCOME)" = DATA_LANE ] && ok || bad "20: an unreadable park stays DATA_LANE, got '$(OUTCOME)'"
[ "$(ALERTS_DL)" = 1 ] && ok || bad "20: one escalation over two ticks, got $(ALERTS_DL): $(cat "$T/lane-alert.txt")"
NOABANDON 20

# ── §21: the route's rc 2 arm: escalated once at 3 unreadable ticks ───────
# A git wrapper counts the fetches of the missing sha across the 4 ticks.
REALGIT=$(command -v git)
mkdir -p "$T/gitwrap"
printf '#!/bin/bash
case " $* " in *" fetch "*cccccccc*) echo fetch >> "%s/fetches.txt" ;; esac
exec "%s" "$@"
' "$T" "$REALGIT" > "$T/gitwrap/git"
chmod +x "$T/gitwrap/git"; : > "$T/fetches.txt"
OLDPATH=$PATH; export PATH="$T/gitwrap:$PATH"
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
printf 'cccccccccccccccccccccccccccccccccccccccc\n' > "$REC/review-head"
RUN; RUN
[ "$(ALERTS_DL)" = 0 ] && ok || bad "21: no escalation before 3 unreadable ticks, got $(ALERTS_DL)"
RUN
[ "$(ALERTS_DL)" = 1 ] && ok || bad "21: one escalation at the 3rd unreadable tick, got $(ALERTS_DL): $(grep 'could not be read' "$RLOG" | tail -3)"
RUN
[ "$(ALERTS_DL)" = 1 ] && ok || bad "21: still one escalation on the 4th tick, got $(ALERTS_DL)"
export PATH="$OLDPATH"
[ "$(grep -c . "$T/fetches.txt")" = 1 ] && ok || bad "21: the missing sha is fetched once in 4 ticks, got $(grep -c . "$T/fetches.txt")"
NOABANDON 21

# ── §23: the fetch-miss window runs from the last real fetch ─────────────
export PATH="$T/gitwrap:$PATH"; : > "$T/fetches.txt"
FRESH
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
printf 'cccccccccccccccccccccccccccccccccccccccc\n' > "$REC/review-head"
MISSF="$H/state/blocked-resolver/.dl-fetch-miss/cccccccccccccccccccccccccccccccccccccccc"
age() { local t; t=$(tr -dc '0-9' < "$MISSF"); printf '%s\n' "$((t - $1))" > "$MISSF"; }   # age <secs>: the stamp as if <secs> passed
RUN
eq "23 tick 1: the missing sha is fetched once" "$(grep -c . "$T/fetches.txt")" "1"
[ -s "$MISSF" ] && ok || bad "23 the failed fetch wrote the miss stamp"
age 300; RUN
eq "23 tick 2, 300 s later: inside the window, no fetch" "$(grep -c . "$T/fetches.txt")" "1"
age 400; RUN
eq "23 tick 3, 700 s after the fetch: fetched again" "$(grep -c . "$T/fetches.txt")" "2"
RUN; RUN
eq "23 ticks 4-5 right after: no fetch" "$(grep -c . "$T/fetches.txt")" "2"
export PATH="$OLDPATH"

# ── §22: a release tick skips the carry, conflict, CI-cap and stale seams ──
# A probe, appended to the last optional module the resolver sources, logs
# each seam it is asked for and hands the row on (rc 1).
OPTF="$H/bin/lib/br/opt/parentprio.sh"
cp "$OPTF" "$T/parentprio.good" 2>/dev/null || : > "$T/parentprio.good"
cat >> "$OPTF" <<EOF
br_opt_carry_rung()    { echo carry >> "$T/seams.txt"; return 1; }
br_opt_conflict_rung() { echo conflict >> "$T/seams.txt"; return 1; }
br_opt_ci_cap_rung()   { echo cicap >> "$T/seams.txt"; return 1; }
br_opt_stale_rung()    { echo stale >> "$T/seams.txt"; return 1; }
EOF
FRESH; : > "$T/seams.txt"
REC=$(RECORD "REVIEW_BLOCKED see review.md" 10800 "$REVIEW_DL")
LEDGER "applied PR#9 head=${HEADSHA:0:12} fp=$FPV"; PROBE "$FPV"; OPENPR "$HEADSHA"
RUN
[ "$(AGENT_RUNS)" = 1 ] && ok || bad "22: precondition: the release ran, got $(AGENT_RUNS)"
[ ! -s "$T/seams.txt" ] && ok || bad "22: a release tick asked a seam: $(sort -u "$T/seams.txt" | tr '\n' ' ')"
FRESH; : > "$T/seams.txt"
REC=$(RECORD "PR_CREATED https://github.com/o/tproj/pull/9" 10800 "$REVIEW_DL")
OPENPR "$HEADSHA"
jq -s . <(LANEREVIEW -) > "$T/reviews-9.json"
RUN
grep -qx carry "$T/seams.txt" && ok || bad "22: control: a fix-round tick asks the carry seam: $(cat "$T/seams.txt")"
cp "$T/parentprio.good" "$OPTF"

echo "resolver-data-lane.bh-4926: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
