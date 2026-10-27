#!/bin/bash
# tests/blocked-resolver-zero-rung.bh-8328-test.sh — BH-8328: the resolver must
# not close a PR when no rung was counted since the last head reset.
#
# WHAT HAPPENED. project-6#2606: a person pushed a new head, br_head_gate reset
# the ladder to it, and a fix round on the owning box found nothing to brief.
# That round recorded no attempt and answered FIX_RESULT terminal. The hub took
# the terminal under the park's new reason (review-changes-requested), and
# br_abandon closed the PR with "mechanical 0, regenerate 0, fix round 0 ...
# could not start: 0" in its close comment.
#
# THE CASES (plan ## Acceptance tests):
#   Z6  --fix-here, nothing to brief: FIX_RESULT terminal, and FIX_RECORD
#       carries one nothing-to-brief fix-round-blocked attempt
#   Z1  the project-6 replay on the hub (an old box's record, no nobrief row):
#       nothing closed, ZERO-RUNG GATE line, the next tick queues a fix round
#   Z1n the same with the record Z6 produced: nothing closed
#   Z7  two real fix rounds at cap 2 on the current head: closes, ABANDONED
#   Z8  a queued fix-round row never claimed: nothing closed, nothing counted
#   Z1a-Z1h, Z2, Z2b, Z3, Z4a-Z4k, Z5, Z9: the fragment's rules, driven
#       directly on the real bin/lib/br modules (the head-gate suite's U pattern)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-zero-rung.bh-8328-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

FRAG="$DIR/bin/blocked-resolver.d/bh-8328-zero-rung.sh"
[ -r "$FRAG" ] && ok || bad "0: bin/blocked-resolver.d/bh-8328-zero-rung.sh is missing"
[ -r "$DIR/bin/lib/br/headgate.sh" ] || { echo "FAIL: bin/lib/br/headgate.sh is missing"; exit 1; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# The hub identity and heartbeat libs (the hub queues and adopts the round),
# each with its own closure: the lane's whole closure would also install the
# review-level and verdict libs, which change what br_cap_notes answers here.
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || exit 1
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# The fragment rides with the driver copy, as bin/harness-sync.sh puts it on a box.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
[ -r "$FRAG" ] && { cp "$FRAG" "$H/bin/blocked-resolver.d/" || exit 1; }
# The hub's fix round is a fix_round_jobs row (BH-2674): the fake worker behind a
# `curl` shim, the real transport and the real bin/lib/fix-round-queue.sh.
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
for lib in bin/lib/jobs/req.sh bin/lib/fix-round-queue.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || exit 1
done
printf '#!/bin/bash\nFRW_STATE=%q exec python3 %q "$@"\n' "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret-fixture; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
} >> "$H/bin/jobs-client.sh" || exit 1
ROWS() { cat "$FRW/rows.json" 2>/dev/null || echo "[]"; }
# The "agent": records its argv. Nothing below may reach it.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 1\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-91 "$1" "$PR91" - TK-91 < "$T/rec-in.json" ) 2>>"$T/run.log"; }
LOGF="$H/logs/blocked-resolver.log"
PR91="https://github.com/o/tproj/pull/91"
CK91=tproj-TK-91
RECF91="$H/state/blocked-resolver/tproj/$CK91.json"
H91=$(osha ticket/TK-91)
OLDH=1111111111111111111111111111111111111111
HUBENV=(HUB_BOX_NAME=hubx BOX_NAME=hubx)
# One clock read: the unclaimed-row page in Z8 is measured by the lane against
# its own clock, so "three hours ago" has to be relative to now.
NOW=$(date -u +%s)  # determinism: ok — br_fix_unclaimed reads the same clock; the row only has to be older than BR_FIX_LANE_TIMEOUT

RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/tmp/brfix"
  mkdir -p "$H/state/blocked-resolver/tproj"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"
  : > "$T/agent.txt"; : > "$T/comment-bodies.txt"
  rm -f "$T/prcomments" "$T/prcomments.json" "$T/prreviews.json"
  : > "$T/findings"   # the ladder-git stub serves this file as the posted findings
  scratch_rm "$FRW"; mkdir -p "$FRW"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" branch -D "brfix/$CK91" >/dev/null 2>&1
  printf 'ticket/TK-91' > "$T/prbranch"; printf '%s' "$H91" > "$T/prhead"; echo OPEN > "$T/prstate"
  BRENV=()
}
REC() { jq -r "$1" "$RECF91" 2>/dev/null; }
CLOSES() { grep -c -- '-X PATCH.*pulls/91' "$T/closed.txt" 2>/dev/null; }
PARK() { ROW "o/tproj#91" "$1" "$PR91"; }
# The project-6 record: one real fix round ran on the OLD head, a person
# pushed H91, and br_head_gate reset the ladder to H91 (counters 0, baseline 1).
RESET_REC() {
  jq -nc --arg u "$PR91" --arg o "$OLDH" --arg h "$H91" '
    {project:"tproj",rkey:"tproj-TK-91",first_seen:"2026-10-25 15:00:00Z",
     rebuilds:0,mechanicals:0,regens:0,fixrounds:0,adjudications:0,rereviews:0,outcome:"",
     attempts:[{at:"2026-10-25 16:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$o},
               {at:"2026-10-25 17:20:00Z",action:"head-reset",reason:"review-changes-requested",detail:"the ladder starts again on the new head",url:$u,head:$h}],
     rung_head:$o,rung_pr:$u,head_resets:1,
     ladder_reset:{url:$u,from:$o,to:$h,at:"2026-10-25 17:20:00Z",base:{fixround:1}}}'
}
# DONE_ROW <result> <record_out-json> — the box's answer, as the worker holds it.
DONE_ROW() {
  jq -nc --arg u "$PR91" --arg r "$1" --arg ro "$2" '[{id:1,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",
    args:["tproj","o-tproj-91","head-not-reapproved",$u,"-","TK-91"],record_in:null,hotfix:0,status:"done",attempt:1,
    claimed_by:"box-tproj",result:$r,record_out:$ro,enqueued_at:"2026-10-25T17:33:04Z",updated_at:"2026-10-25T17:34:18Z"}]' > "$FRW/rows.json"
}

# ============================================================================
# Z6. The owning box: a head-not-reapproved round with no posted findings, no
#     conflict and no failing job. FIX_RESULT stays terminal; the record that
#     goes back carries ONE nothing-to-brief attempt on the head, no counter.
# ============================================================================
RESET
RESET_REC > "$T/rec-in.json"
FH6=$(FIXHERE head-not-reapproved)
grep -qx 'FIX_RESULT terminal' <<<"$FH6" && ok || bad "Z6: nothing to brief must still answer FIX_RESULT terminal (stdout: $FH6; log: $(tail -3 "$LOGF"))"
grep -q 'nothing to brief a fix round with' "$LOGF" && ok || bad "Z6: the round must reach the nothing-to-brief branch (log: $(tail -4 "$LOGF"))"
REC6=$(grep '^FIX_RECORD ' <<<"$FH6" | head -1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
[ "$(jq -r '.attempts[-1].action' <<<"$REC6" 2>/dev/null)" = fix-round-blocked ] && ok \
  || bad "Z6: the carried record's last attempt must be fix-round-blocked (got $(jq -c '.attempts[-1]' <<<"$REC6" 2>/dev/null))"
jq -r '.attempts[-1].detail' <<<"$REC6" 2>/dev/null | grep -q '^nothing to brief' && ok \
  || bad "Z6: the attempt's detail must start 'nothing to brief' (got $(jq -r '.attempts[-1].detail' <<<"$REC6" 2>/dev/null))"
[ "$(jq -r '.attempts[-1].head + " " + .attempts[-1].url' <<<"$REC6" 2>/dev/null)" = "$H91 $PR91" ] && ok \
  || bad "Z6: the attempt must carry the head and the url (got $(jq -c '.attempts[-1]' <<<"$REC6" 2>/dev/null))"
[ "$(jq -r '.fixrounds' <<<"$REC6" 2>/dev/null)" = 0 ] && ok || bad "Z6: no fix round may be counted (got $(jq -r .fixrounds <<<"$REC6" 2>/dev/null))"
[ -s "$T/agent.txt" ] && bad "Z6: no agent may run ($(cat "$T/agent.txt"))" || ok

# ============================================================================
# Z1 (acceptance 1, the project-6 replay). The hub adopts the box's terminal
# under the park's CURRENT reason, review-changes-requested. The box is an old
# one: its record carries no nothing-to-brief row (exactly the incident).
# ============================================================================
RESET
RESET_REC > "$RECF91"
DONE_ROW terminal "$(RESET_REC)"
PARK review-changes-requested; BRENV=("${HUBENV[@]}")
RUN
[ "$(CLOSES)" = 0 ] && ok || bad "Z1: a PR with 0 rungs counted since the head reset must NOT be closed (closed: $(cat "$T/closed.txt"); log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" != ABANDONED ] && ok || bad "Z1: no ABANDONED outcome may be recorded"
grep -q "ZERO-RUNG GATE — 0 fix rounds counted on ${H91:0:12} since the last head reset" "$LOGF" && ok \
  || bad "Z1: the refusal line must name the count and the head (log: $(tail -4 "$LOGF"))"
[ "$(REC '[.mechanicals,.regens,.fixrounds]|map(tostring)|join(" ")')" = "0 0 0" ] && ok \
  || bad "Z1: a refusal spends no counter (got $(REC '[.mechanicals,.regens,.fixrounds]'))"
[ "$(REC '.zero_rung.head + " " + (.zero_rung.n|tostring)')" = "$H91 1" ] && ok \
  || bad "Z1: the refusal is counted on the record for this head (got $(REC -c .zero_rung))"
[ "$(grep -c 'br-zero-rung:' "$T/lane-alert.txt")" = 0 ] && ok || bad "Z1: no alert on the first refusal (alerts: $(cat "$T/lane-alert.txt"))"
# The next tick: the row is adopted, so the ladder offers the park again and
# the hub queues a fresh fix round for the same head (the re-brief).
: > "$LOGF"
RUN
grep -q 'fix round queued' "$LOGF" && ok || bad "Z1: the next tick must queue a fix round for the same head (log: $(tail -4 "$LOGF"))"
[ "$(CLOSES)" = 0 ] && ok || bad "Z1: the next tick closes nothing"

# Z1n. The same replay with the record a fixed box sends back (Z6's FIX_RECORD).
RESET
RESET_REC > "$RECF91"
DONE_ROW terminal "$REC6"
PARK review-changes-requested; BRENV=("${HUBENV[@]}")
RUN
[ "$(CLOSES)" = 0 ] && ok || bad "Z1n: the fixed box's record must not close the PR either (log: $(tail -4 "$LOGF"))"
grep -q 'ZERO-RUNG GATE' "$LOGF" && ok || bad "Z1n: the zero-rung gate must be what refused (log: $(tail -4 "$LOGF"))"
[ "$(REC '[.attempts[]|select(.action=="fix-round-blocked")]|length')" = 1 ] && ok \
  || bad "Z1n: the hub adopts the nothing-to-brief attempt (got $(REC '[.attempts[].action]|join(",")'))"
[ "$(REC .fixrounds)" = 0 ] && ok || bad "Z1n: the adopted attempt counts no fix round (got $(REC .fixrounds))"

# ============================================================================
# Z7 (acceptance 2). Two REAL fix rounds on the current head, cap 2, no
# verified push: the review terminal closes once and records ABANDONED.
# ============================================================================
RESET
jq -nc --arg u "$PR91" --arg h "$H91" '
  {project:"tproj",rkey:"tproj-TK-91",rebuilds:0,mechanicals:0,regens:0,fixrounds:2,adjudications:0,outcome:"",
   attempts:[{at:"2026-10-25 16:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h},
             {at:"2026-10-25 16:30:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h}],
   rung_head:$h,rung_pr:$u}' > "$RECF91"
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 1 ] && ok || bad "Z7: two real rounds at the cap must close exactly once (closes: $(CLOSES); log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" = ABANDONED ] && ok || bad "Z7: outcome must be ABANDONED (got $(REC .outcome))"
grep -q 'fix round 2' "$T/comment-bodies.txt" && ok || bad "Z7: the close body counts the 2 fix rounds (body: $(tail -2 "$T/comment-bodies.txt"))"
grep -q 'ZERO-RUNG GATE' "$LOGF" && bad "Z7: the gate must not refuse two real rounds" || ok

# ============================================================================
# Z8. A fix-round row queued three hours ago and never claimed: the park is
#     held, one unclaimed page, nothing counted, nothing closed.
# ============================================================================
RESET
RESET_REC > "$RECF91"
jq -nc --arg u "$PR91" --arg at "$(date -u -d "@$((NOW - 10800))" '+%Y-%m-%dT%H:%M:%SZ')" '[{id:2,project:"tproj",cap_key:"tproj-TK-91",box:"box-tproj",
  args:["tproj","o-tproj-91","review-changes-requested",$u,"-","TK-91"],record_in:null,hotfix:0,status:"queued",attempt:0,
  enqueued_at:$at,updated_at:$at}]' > "$FRW/rows.json"
PARK review-changes-requested; BRENV=("${HUBENV[@]}" BR_FIX_LANE_TIMEOUT=5400)
RUN
[ "$(CLOSES)" = 0 ] && ok || bad "Z8: an unclaimed round closes nothing (log: $(tail -3 "$LOGF"))"
[ "$(REC .fixrounds)" = 0 ] && ok || bad "Z8: an unclaimed round counts nothing (got $(REC .fixrounds))"
[ "$(grep -c 'fix-round-unclaimed-tproj' "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "Z8: one unclaimed page (alerts: $(cat "$T/lane-alert.txt"))"

# ============================================================================
# U. The fragment, driven directly: the real record.sh, ladder.sh and
#    headgate.sh modules, GitHub's PR object and head commit served from files.
# ============================================================================
U="$T/u"; mkdir -p "$U/state/tproj" "$U/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$U" > "$U/bin/lane-alert.sh"
chmod +x "$U/bin/lane-alert.sh"
UNOW=1793000000
cat > "$T/u-pre.sh" <<EOF
set -u
unset BR_ZERO_RUNG_REBRIEFS BR_HUMAN_PUSH_SETTLE_SECS
H="$U"; ST="$U/state"; LOG="$U/log"; OBSERVE="\${OBSERVE:-0}"
STAMP() { printf '2026-10-25 18:02:50Z'; }
say() { printf '%s\n' "\$*" >> "\$LOG"; }
br_now() { printf '%s' "$UNOW"; }
br_is_sha() { [[ "\${1:-}" =~ ^[0-9a-f]{40}\$ ]]; }
br_slug_of_url() { case "\${1:-}" in https://github.com/*/*/pull/*) local s="\${1#https://github.com/}"; printf '%s' "\${s%/pull/*}" ;; *) return 1 ;; esac; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
br_pr_field() {
  local rc; rc=\$(cat "$U/pr-rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || return "\$rc"
  jq -r "\$2 // empty" "$U/pr.json"
}
# gh_rest's contract (0 / 44 / 75), the commit object from a file.
gh_rest() {
  printf '%s\n' "\$*" >> "$U/ghreads"
  local rc; rc=\$(cat "$U/commit-rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || { GH_REST_STATUS=403; return "\$rc"; }
  GH_REST_STATUS=200; cat "$U/commit.json"
}
pr_rows_on() { [ -s "$U/rows" ]; }
pr_attempt_count() { cat "$U/rows"; return 0; }
. "$DIR/bin/lib/br/record.sh" || exit 9
. "$DIR/bin/lib/br/ladder.sh" || exit 9
. "$DIR/bin/lib/br/headgate.sh" || exit 9
. "$FRAG" || exit 9
eval "\$(declare -f br_save | sed '1s/^br_save/br_save_real/')"
br_save() { [ -e "$U/save-fail" ] && return 1; br_save_real "\$@"; }
EOF
URF="$U/state/tproj/$CK91.json"
UNIT() { ( . "$T/u-pre.sh"; eval "$1" ) 2>>"$U/err"; }
UGATE() { UNIT "zr_close_gate tproj $CK91 ${1:-review-changes-requested} $PR91; echo rc=\$?"; }
UPR() { jq -nc --arg s "$1" --arg h "$2" '{state:$s, head:{sha:$h}}' > "$U/pr.json"; rm -f "$U/pr-rc"; }
# UCOMMIT <login|null> <seconds-ago|bad> — the head commit as GitHub's REST answers it.
UCOMMIT() {
  local d="not-a-date"; [ "$2" = bad ] || d=$(date -u -d "@$((UNOW - $2))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -nc --arg l "$1" --arg d "$d" '{sha:"x", author:(if $l == "null" then null else {login:$l} end), commit:{committer:{date:$d}}}' > "$U/commit.json"
  rm -f "$U/commit-rc"
}
# USEED <jq-filter> — the project-6 record on H91, edited by the filter.
USEED() {
  RESET_REC | jq -c --arg u "$PR91" --arg o "$OLDH" --arg h "$H91" "$1" > "$URF"
  : > "$U/log"; : > "$U/alerts"; : > "$U/ghreads"; rm -f "$U/save-fail" "$U/rows"
  UPR open "$H91"; UCOMMIT person-fixture 7200
}
ALERTS() { grep -c 'br-zero-rung:' "$U/alerts"; }
NOBRIEF='{at:"2026-10-25 17:34:18Z",action:"fix-round-blocked",reason:"head-not-reapproved",detail:"nothing to brief a fix round with",url:$u,head:$h}'

# Z1a. zr_nobrief twice on one head: ONE attempt, no counter, head and url.
USEED '.'
UNIT "zr_nobrief tproj $CK91 head-not-reapproved $PR91 ${H91^^}"
UNIT "zr_nobrief tproj $CK91 head-not-reapproved $PR91 $H91"
[ "$(jq '[.attempts[]|select(.action=="fix-round-blocked")]|length' "$URF")" = 1 ] && ok \
  || bad "Z1a: two nothing-to-brief rounds on one head add ONE attempt (got $(jq -c '[.attempts[].action]' "$URF"))"
[ "$(jq -r '.attempts[-1].head + " " + .attempts[-1].url' "$URF")" = "$H91 $PR91" ] && ok \
  || bad "Z1a: the attempt carries the head (lower case) and url (got $(jq -c '.attempts[-1]' "$URF"))"
[ "$(jq -r .fixrounds "$URF")" = 0 ] && ok || bad "Z1a: no counter moves (fixrounds $(jq -r .fixrounds "$URF"))"
# ...and a new head is a new attempt.
UNIT "zr_nobrief tproj $CK91 head-not-reapproved $PR91 $OLDH"
[ "$(jq '[.attempts[]|select(.action=="fix-round-blocked")]|length' "$URF")" = 2 ] && ok \
  || bad "Z1a: a nothing-to-brief round on another head is a new attempt"

# Z1 (unit). The project-6 record plus the nobrief attempt: rc 5, nothing else moves.
USEED ".attempts += [$NOBRIEF]"
OUT=$(UGATE)
[ "$OUT" = rc=5 ] && ok || bad "Z1u: zero counted fix rounds refuse the close (got '$OUT'; log: $(cat "$U/log"))"
[ "$(jq -r '[.mechanicals,.regens,.fixrounds,.rebuilds]|map(tostring)|join(" ")' "$URF")" = "0 0 0 0" ] && ok \
  || bad "Z1u: no counter moves on a refusal"
# Z1b. An old box's record (no nobrief row): the count alone refuses.
USEED '.'
[ "$(UGATE)" = rc=5 ] && ok || bad "Z1b: a count of 0 with only a head-reset after it refuses (got '$(UGATE)')"
# Z1c. One real round of cap 2, then a nobrief round: still refused, fixrounds 1.
USEED ".fixrounds = 1 | .rung_head = \$h | .attempts += [{action:\"fix-round\",reason:\"review-changes-requested\",detail:\"agent rc=1\",url:\$u,head:\$h}, $NOBRIEF]"
[ "$(UGATE)" = rc=5 ] && ok || bad "Z1c: a round that found nothing to brief is not a rung (got '$(UGATE)'; log: $(cat "$U/log"))"
[ "$(jq -r .fixrounds "$URF")" = 1 ] && ok || bad "Z1c: fixrounds stays 1"
# Z1d. Near miss: a setup-blocked round, then a real round newer: passes.
USEED '.fixrounds = 1 | .rung_head = $h | .attempts += [{action:"fix-round-blocked",reason:"review-changes-requested",detail:"there is no local clone",url:$u},{action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1",url:$u,head:$h}]'
[ "$(UGATE)" = rc=0 ] && ok || bad "Z1d: a real round after a setup block closes as today (got '$(UGATE)'; log: $(cat "$U/log"))"
# Z1e. Near miss: a ladder reason after a reset, rebuilds spent: not this gate's.
USEED '.rebuilds = 3'
[ "$(UGATE red-twice)" = rc=0 ] && ok || bad "Z1e: a ladder reason is not refused here (got '$(UGATE red-twice)')"
# Z1f. Near miss: a rebuild-only reason.
USEED '.'
[ "$(UGATE build-dead)" = rc=0 ] && ok || bad "Z1f: a rebuild-only reason is not refused here (got '$(UGATE build-dead)')"
# Z1g. The record's rungs are for another PR: the count is the record's, 0.
USEED '.rung_pr = "https://github.com/o/tproj/pull/8" | del(.ladder_reset)'
[ "$(UGATE)" = rc=5 ] && ok || bad "Z1g: a record with 0 fix rounds refuses whatever PR its rungs named (got '$(UGATE)')"
# Z1h. A rebuilt hub: the record says 0, the rows say 2 above the baseline.
USEED '.ladder_reset.base.fixround = 0 | .attempts += [{action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1",url:$u,head:$h}]'
echo 2 > "$U/rows"
[ "$(UGATE)" = rc=0 ] && ok || bad "Z1h: the rows' count (br_cap_rows) is the count (got '$(UGATE)'; log: $(cat "$U/log"))"
# Orphaned-child is a fix-round park only with the ladder off.
USEED '.'
[ "$(UNIT "BR_LADDER=0 zr_close_gate tproj $CK91 orphaned-child $PR91; echo rc=\$?")" = rc=5 ] && ok \
  || bad "Z1i: orphaned-child with BR_LADDER=0 is a fix-round park and is refused at 0"
# Z1j. Near miss: a review fix cap of 0 means no round is ever due: not refused.
USEED '.'
[ "$(UNIT "BR_REVIEW_FIX_ROUNDS=0 zr_close_gate tproj $CK91 review-changes-requested $PR91; echo rc=\$?")" = rc=0 ] && ok \
  || bad "Z1j: BR_REVIEW_FIX_ROUNDS=0 closes at a count of 0, as configured (log: $(cat "$U/log"))"

# Z2. The refusal counter: knob unset (fallback 1). 1st no alert, 2nd one
#     alert, 3rd none more; a new head starts again.
USEED '.'
UGATE >/dev/null
[ "$(ALERTS)" = 0 ] && ok || bad "Z2: no alert on the 1st refusal"
UGATE >/dev/null
[ "$(ALERTS)" = 1 ] && ok || bad "Z2: ONE alert on the 2nd refusal on a head (alerts: $(cat "$U/alerts"))"
grep -q "br-zero-rung:tproj:$CK91:${H91:0:12}" "$U/alerts" && grep -q 'NEEDS_HUMAN' "$U/alerts" && ok \
  || bad "Z2: the alert carries the park+head id and says NEEDS_HUMAN (alerts: $(cat "$U/alerts"))"
[ "$(jq -r .zero_rung.alerted "$URF")" = true ] && ok || bad "Z2: zero_rung.alerted is written"
UGATE >/dev/null
[ "$(ALERTS)" = 1 ] && ok || bad "Z2: the 3rd refusal sends no new alert (got $(ALERTS))"
UPR open "$OLDH"
UGATE >/dev/null
[ "$(ALERTS)" = 1 ] && [ "$(jq -r '.zero_rung.head + " " + (.zero_rung.n|tostring)' "$URF")" = "$OLDH 1" ] && ok \
  || bad "Z2: a new head starts the count at 1 with no alert (got $(jq -c .zero_rung "$URF"), alerts $(ALERTS))"
grep -q "ZERO-RUNG GATE — 0 fix rounds counted on ${H91:0:12}" "$U/log" && ok || bad "Z2: the refusal line names the head (log: $(cat "$U/log"))"
# Z2b. Knob 0: the 1st refusal alerts. A non-number: the fallback 1, one line.
USEED '.'
UNIT "BR_ZERO_RUNG_REBRIEFS=0 zr_close_gate tproj $CK91 review-changes-requested $PR91" >/dev/null
[ "$(ALERTS)" = 1 ] && ok || bad "Z2b: BR_ZERO_RUNG_REBRIEFS=0 alerts on the 1st refusal (alerts: $(cat "$U/alerts"))"
USEED '.'
UNIT "BR_ZERO_RUNG_REBRIEFS=x zr_close_gate tproj $CK91 review-changes-requested $PR91" >/dev/null
[ "$(ALERTS)" = 0 ] && grep -q "BR_ZERO_RUNG_REBRIEFS is 'x'" "$U/log" && ok \
  || bad "Z2b: a non-number knob is the fallback 1, said once (alerts $(ALERTS); log: $(cat "$U/log"))"

# Z3 (acceptance 3). The close body prints the counts the gate decided with.
USEED '.ladder_reset.base.fixround = 0 | .attempts += [{action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1",url:$u,head:$h}]'
echo 2 > "$U/rows"
OUT=$(UNIT "zr_close_gate tproj $CK91 review-changes-requested $PR91; echo rc=\$?; zr_counts tproj $CK91 $PR91 x; echo; br_close_facts tproj $CK91 $PR91")
[ "$(sed -n 1p <<<"$OUT")" = rc=0 ] && ok || bad "Z3: rows 2 / record 0 passes the gate (got $(sed -n 1p <<<"$OUT"))"
[ "$(sed -n 2p <<<"$OUT")" = "0 0 2" ] && ok || bad "Z3: zr_counts prints mech regen fix = 0 0 2 (got '$(sed -n 2p <<<"$OUT")')"
grep -q 'mechanical 0, regenerate 0, fix round 2\.' <<<"$OUT" && ok || bad "Z3: the close body says fix round 2, the gate's count (got: $OUT)"
USEED '.fixrounds = 2 | .rung_head = $h | .attempts += [{action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1",url:$u,head:$h}]'
OUT=$(UNIT "br_close_facts tproj $CK91 $PR91")
grep -q 'fix round 2\.' <<<"$OUT" && ok || bad "Z3: record 2 and no rows says fix round 2 (got: $OUT)"
grep -q 'could not start (not counted): 0' <<<"$OUT" && ok || bad "Z3: the could-not-start count stays (got: $OUT)"

# Z4. THE HUMAN-PUSH DEFER, on a head the ladder was reset to. A red-twice
#     ladder reason, so the zero-rung rule does not apply.
Z4() { # Z4 <case> <want-rc> <login> <ago> [filter] [env]
  USEED "${5:-.}"; UCOMMIT "$3" "$4"
  local got; got=$(UNIT "${6:-} zr_close_gate tproj $CK91 red-twice $PR91; echo rc=\$?")
  [ "$got" = "rc=$2" ] && ok || bad "$1: want rc=$2, got '$got' (log: $(cat "$U/log"))"
}
Z4 Z4a 5 person-fixture 300
[ ! -s "$U/alerts" ] && cmp -s "$URF" <(RESET_REC | jq -c --arg h "$H91" .) && ok || bad "Z4a: a defer writes nothing"
grep -q "deferred: person-fixture committed ${H91:0:12} 300s ago" "$U/log" && ok || bad "Z4a: the defer line names the author, head and age (log: $(cat "$U/log"))"
Z4 Z4b 0 person-fixture 3601
Z4 Z4c 0 person-fixture 60 '.fix_pr = $u | .fix_head = $h'
Z4 Z4d 0 'cromford[bot]' 60
Z4 Z4e 5 null 60
Z4 Z4f 5 person-fixture bad
grep -q 'committer date' "$U/log" && ok || bad "Z4f: an unreadable date is said (log: $(cat "$U/log"))"
USEED '.'; echo 75 > "$U/commit-rc"
[ "$(UGATE red-twice)" = rc=75 ] && ok || bad "Z4g: a failed commit read is rc 75 (got '$(UGATE red-twice)')"
Z4 Z4h 0 person-fixture 60 '.' BR_HUMAN_PUSH_SETTLE_SECS=0
[ ! -s "$U/ghreads" ] && ok || bad "Z4h: knob 0 reads no commit ($(cat "$U/ghreads"))"
USEED '.'; UPR closed "$H91"; UCOMMIT person-fixture 60
[ "$(UGATE red-twice)" = rc=0 ] && [ ! -s "$U/ghreads" ] && ok || bad "Z4i: a closed PR is not gated and reads no commit"
# Z4j. A head a counted rung already ran on: no read, rc 0 (head-gate A1c).
Z4 Z4j 0 person-fixture 60 '.rung_head = $h'
[ ! -s "$U/ghreads" ] && ok || bad "Z4j: a head a counted rung ran on reads no commit"
# Z4k. No reset on record (the head gate still owns a moved head): no read.
Z4 Z4k 0 person-fixture 60 'del(.ladder_reset)'
[ ! -s "$U/ghreads" ] && ok || bad "Z4k: a record with no reset reads no commit"
# The PR's own head read failing: rc 75, nothing written.
USEED '.'; echo 75 > "$U/pr-rc"
[ "$(UGATE)" = rc=75 ] && [ "$(jq -r '.zero_rung // "none"' "$URF")" = none ] && ok || bad "Z4l: an unreadable PR is rc 75, nothing written"

# Z5. The refusal cannot be written: rc 75, no alert, no outcome.
USEED '.zero_rung = {head:$h, n:1, alerted:false}'; touch "$U/save-fail"
[ "$(UGATE)" = rc=75 ] && ok || bad "Z5: a failed write is rc 75 (got '$(UGATE)')"
[ "$(ALERTS)" = 0 ] && [ "$(jq -r .outcome "$URF")" = "" ] && ok || bad "Z5: no alert, no outcome"

# Z9. The code fallbacks with no knob in the environment: 1 and 3600 (BH-8474: 60 minutes).
USEED '.'
UNIT "zr_close_gate tproj $CK91 review-changes-requested $PR91; zr_close_gate tproj $CK91 review-changes-requested $PR91" >/dev/null
[ "$(ALERTS)" = 1 ] && ok || bad "Z9: the fallback BR_ZERO_RUNG_REBRIEFS is 1 (alerts $(ALERTS))"
Z4 Z9b 5 person-fixture 3599
Z4 Z9c 0 person-fixture 3600

# Observe mode: WOULD, rc 5, nothing written.
USEED '.'; cp "$URF" "$T/before.json"
OUT=$(OBSERVE=1 UGATE)
[ "$OUT" = rc=5 ] && cmp -s "$URF" "$T/before.json" && grep -q 'WOULD refuse' "$U/log" && ok \
  || bad "observe: WOULD refuse, nothing written (got '$OUT'; log: $(cat "$U/log"))"

echo "blocked-resolver-zero-rung.bh-8328: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
