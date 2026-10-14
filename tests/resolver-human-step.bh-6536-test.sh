#!/bin/bash
# tests/resolver-human-step.bh-6536-test.sh — bin/blocked-resolver.sh does not
# rebuild a released needs-human park whose build bin/review-rescue.sh will
# re-review (BH-6536). Before, rc 4 from br_needs_human_park (the human step is
# done) was always rebuild-fresh, so the built branch of a review that blocked
# only on a human step was thrown away (TK-232).
#   R1  HELD + nh_placed, the thread released, the record pending shape D
#       (nh_sd_pending) -> rc 3: no enqueue, one "human step done" line, and a
#       second tick neither enqueues nor says it again
#   R2  the record already has .review-rescued -> rebuild-fresh, as before
#   R3  RESCUE_HUMAN_STEP=0 -> rebuild-fresh
#   R4  the review has a code BLOCK too -> rebuild-fresh
#   R5  a settings row lane.review-rescue.rescue_human_step=0 (the kill switch
#       set from settings, with no env value in the resolver) -> rebuild-fresh
#   R6  the review-rescue lane is off (flags/lane-off-review-rescue) ->
#       rebuild-fresh: nobody would re-review, so the resolver must not wait
# The fixture is tests/resolver-needs-human.bh-3443-test.sh's.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# created_at below is derived from it, so the fixture thread is internally
# ordered whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# The lane and every lib it sources, bin/lib/needs-human/step-done.sh among them.
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
chmod +x "$H/bin/"*.sh
# Two projects: tproj is a GitHub-Issues lane (board prefix "-"), iproj is an
# in-app product board, which has no GitHub issue to read (section 9).
{ printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n'
  printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj 100.0.0.8\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj iproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# run-build.sh is the RESUME launch (section 8). Recorded, never run: "did the
# resume fire" is the whole question there.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
# agent-call.sh is the adjudicator. Its answer goes in the OUT file (arg 5), the
# way bin/agent-call.sh writes it.
printf '#!/bin/bash\nprintf "ACCEPT\\n" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
# lane-alert is RECORDED, never stubbed silent: a respected hold must not page,
# and "it went quiet" is only provable against a recorder.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/run-build.sh" "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

# Every gh call is recorded, so "did anything close a PR / reopen one / comment
# on the issue / read the issue at all" is a fact about the run.
# GH_ISSUE_FAIL=1 makes both ISSUE reads fail the way the real outage did.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). This fixture names its
  # PR fields off the NUMBER in the path, so they are written where the shared
  # REST stub reads them and the envelope is answered there.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  # The resolver reads PR state over REST since BH-597 (one gh api
  # repos/O/R/pulls/N for the whole object). Same facts this stub has always
  # answered: the state from $T/prstate, the head sha and branch below it.
  "api repos/"*"/pulls/\$N")
    PST=\$(cat "$T/prstate" 2>/dev/null || echo OPEN)
    if [ "\$PST" = MERGED ]; then
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}\n' "\$N" "\$N" "\$N"
    else
      CL=null; [ "\$PST" = CLOSED ] && CL='"2026-09-12T01:00:00Z"'
      LOWST=\$(printf '%s' "\$PST" | tr 'A-Z' 'a-z')
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"%s","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":%s}\n' "\$N" "\$N" "\$LOWST" "\$N" "\$CL"
    fi ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"; : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
: > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row

# The closure brings bin/lib/br/opt/unchanged.sh, whose quiet-row skip sees a
# person's answer on a needs-human hold up to BR_UNCHANGED_RECHECK_S late. Each
# tick here stands for a tick after that window.
export BR_UNCHANGED_RECHECK_S=0
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# The conductor hand-off row this lane drains: key, state, since, head, rev,
# alerted, why, url.
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"
          : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"; }

ISSUE() {
  jq -nc --arg c "$(ISO 604800)" \
    '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9: the report rebuilt email",body:"## Scope",created_at:$c}'
}
CMT() { jq -nc --arg b "$1" --arg c "$(ISO "$2")" --arg u "${3:-User}" '{body:$b,created_at:$c,user:{type:$u}}'; }
printf '%s\n' "$(ISSUE)" > "$T/issue-9.json"

ACT='run vs_publish probe from the hub'
FP=abc123def456
RESLINE="REVIEW_BLOCKED review.md NEEDS_HUMAN:$FP:$ACT"
# The placer stub: its argv to calls.placer; the tagged Bot marker appended to
# the thread (unless PLACER_RC is not 0, or PLACER_NOPOST=1 — the switch-on
# answer); exits ${PLACER_RC:-0}.
cat > "$H/bin/needs-human-hold.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.placer"
rc=\$(cat "$T/placer-rc" 2>/dev/null || echo 0)
if [ "\$rc" = 0 ] && [ ! -e "$T/placer-nopost" ]; then
  jq -c --arg b "NEEDS-HUMAN: \$4

Builds of this ticket are paused until a person does the step above.
<!-- nh-fp:\$3 -->" --arg c "$(ISO 1800)" '. + [{body:\$b, created_at:\$c, user:{type:"Bot"}}]' \
    "$T/comments-9.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments-9.json"
fi
exit "\$rc"
SH
chmod +x "$H/bin/needs-human-hold.sh"
DONE_CMT() { jq -c --argjson d "$(CMT 'HUMAN-STEP-DONE: ran it on the hub, it printed PASS' 60)" '. + [$d]' \
               "$T/comments-9.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments-9.json"; }
placer_calls() { cat "$T/calls.placer" 2>/dev/null | grep -c .; }
enqueues() { grep -v '^done ' "$T/queue.txt" 2>/dev/null | grep -c .; }
HUMAN_REVIEW='B1 migration 0020 not applied in prod.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'
CODE_REVIEW='B1 migration 0020 not applied in prod.
B2 the guard returns early on empty input.
NEEDS_HUMAN: apply migration 0020 in prod
TIER: 2
VERDICT: BLOCK'
# RECORD <stamp> <review text> [rescued] — a REVIEW_BLOCKED record of TK-9 with
# the NEEDS_HUMAN suffix, its RESULT 7 h old (past br_from_builds' 6-hour floor
# for a record bin/review-rescue.sh has not marked).
RECORD() {
  local r="$H/builds/tproj-TK-9-$1"
  scratch_rm "$r"; mkdir -p "$r"
  printf '%s\nTICKET_ID: 9\n' "$RESLINE" > "$r/RESULT"
  printf '%s\n' "$2" > "$r/review.md"
  [ "${3:-}" = rescued ] && : > "$r/.review-rescued"
  touch -d "@$((NOW - 25200))" "$r/RESULT"
  printf '%s' "$r"
}
said() { grep -c 'human step done — bin/review-rescue.sh re-reviews the built branch' "$H/logs/blocked-resolver.log" 2>/dev/null || true; }
# park_then_release <record args...> — tick 1 parks the needs-human hold, the
# person's HUMAN-STEP-DONE lands, tick 2 is the released tick under test.
park_then_release() {
  FRESH; REC=$(RECORD "$@")
  RUN
  [ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] || bad "setup: tick 1 must park HELD, got '$(STATEJSON tproj-TK-9 | jq -r .outcome)': $(tail -3 "$H/logs/blocked-resolver.log")"
  DONE_CMT
  RUN
}
FRESH() { CLEAN; : > "$H/state/merge-conductor/pr-state.tsv"; rm -f "$T/calls.placer" "$T/placer-rc" "$T/placer-nopost"
          scratch_rm "$H/builds"; mkdir -p "$H/builds"; echo '[]' > "$T/comments-9.json"; }

# ── R1: pending shape D — no rebuild ───────────────────────────────────────
park_then_release 202610130001 "$HUMAN_REVIEW"
[ "$(enqueues)" = 0 ] && ok || bad "R1: a released park pending the rescue re-review must not be rebuilt: $(cat "$T/queue.txt")"
[ "$(said)" = 1 ] && ok || bad "R1: one 'human step done' line, got $(said): $(tail -4 "$H/logs/blocked-resolver.log")"
grep -q -- '-> rebuild-fresh' "$H/logs/blocked-resolver.log" && bad "R1: no rebuild-fresh rung may be logged" || ok
RUN
[ "$(enqueues)" = 0 ] && ok || bad "R1: the next tick must not rebuild either: $(cat "$T/queue.txt")"
[ "$(said)" = 1 ] && ok || bad "R1: the line is said once per record, got $(said)"

# ── R2: the rescue lane is done with the record — today's rebuild ─────────
park_then_release 202610130002 "$HUMAN_REVIEW" rescued
[ "$(enqueues)" = 1 ] && grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "R2: .review-rescued -> one rebuild enqueued: $(cat "$T/queue.txt")"
[ "$(said)" = 0 ] && ok || bad "R2: no 'human step done' line"

# ── R3: the kill switch ────────────────────────────────────────────────────
BRENV=(RESCUE_HUMAN_STEP=0)
park_then_release 202610130003 "$HUMAN_REVIEW"
BRENV=()
[ "$(enqueues)" = 1 ] && ok || bad "R3: RESCUE_HUMAN_STEP=0 -> rebuild-fresh: $(cat "$T/queue.txt")"
[ "$(said)" = 0 ] && ok || bad "R3: no 'human step done' line"

# ── R4: a code BLOCK is not shape D ────────────────────────────────────────
park_then_release 202610130004 "$CODE_REVIEW"
[ "$(enqueues)" = 1 ] && ok || bad "R4: a code BLOCK -> rebuild-fresh: $(cat "$T/queue.txt")"
[ "$(said)" = 0 ] && ok || bad "R4: no 'human step done' line"

# ── R5: the kill switch as a settings row (lead review lr-6621-e59f79a9aa94) ─
# lane-gate.sh exports a knob only into the lane that owns it, so the resolver
# must read review-rescue's RESCUE_HUMAN_STEP through lane_knob. The row is in
# the lane-gate settings cache, fresh at the suite's one clock read.
REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || bad "R5 setup: no lanes.json"
jq -n --argjson t "$NOW" '{fetched_at:$t, values:{"lane.review-rescue.rescue_human_step":"0"}}' \
  > "$H/state/settings-cache.json"
BRENV=(LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW")
park_then_release 202610130005 "$HUMAN_REVIEW"
BRENV=()
rm -f "$H/state/settings-cache.json"
[ "$(enqueues)" = 1 ] && ok || bad "R5: settings row RESCUE_HUMAN_STEP=0 -> rebuild-fresh: $(cat "$T/queue.txt")"
[ "$(said)" = 0 ] && ok || bad "R5: no 'human step done' line with the settings row at 0"

# ── R6: the review-rescue lane is off ──────────────────────────────────────
: > "$H/flags/lane-off-review-rescue"
BRENV=(LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW")
park_then_release 202610130006 "$HUMAN_REVIEW"
BRENV=()
rm -f "$H/flags/lane-off-review-rescue"
[ "$(enqueues)" = 1 ] && ok || bad "R6: lane-off-review-rescue -> rebuild-fresh: $(cat "$T/queue.txt")"
[ "$(said)" = 0 ] && ok || bad "R6: no 'human step done' line with the rescue lane off"

echo "resolver-human-step.bh-6536: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
