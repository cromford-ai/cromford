#!/bin/bash
# tests/review-replay-restamp.bh-9066-test.sh — BH-9066 C0: the review callers
# replay a verdict onto a head that is the reviewed head REBASED onto a newer
# main with its PR-added schema.d fragment restamped (renamed to a later stamp,
# every reference rewritten, nothing else changed). bin/lib/patch-same.sh
# patch_same_restamp names that `restamp-rebase`; patch_same_review asks it
# after patch_same and restamp_same. Before, each caller bought a new review.
#
# The git fixture is one real repo. main has worker/jobs/schema.d/
# 202610010000-bh-0-base.sql and f.txt (30 lines). The PR (R) adds
# 202611041200-bh-1-a.sql and refs.txt that names it, and changes f.txt line 10.
# main then moves (o.txt). The PR is rebased onto that main, the fragment is
# renamed to 202611051300-bh-1-a.sql and refs.txt is rewritten: that is H.
#   case 1  H = the rebase + the restamp                      -> replay
#   case 5  H = the same + one changed code line in f.txt     -> a review
#
# Gate 50 (bin/lib/lead-gates.d/50-replay-delta.sh) on the lead worklist
# (tests/lib/lead-worklist-fixture.bh-4956.sh; bin/lead-review.sh tick, the
# real bin/lead-verdict.sh, the builder APPROVE on R rebound to H):
#   G1  ld_classify (bin/lib/lead-delta.sh) on case 1: `replay restamp-rebase`;
#       on case 5: not a replay
#   G2  the tick on case 1 (#21, the delta branch, ld=1): one POST
#       /api/verdicts of MERGE on H with note `lead-replay:<R12>
#       how:restamp-rebase`, the replay line, 0 jobs, 0 model calls, the
#       delta.tsv row `replay restamp-rebase`
#   G3  the tick on case 5 (#22): no post, one review job
#   G4  gate 50 called with bin/lib/lead-delta.sh NOT loaded (the non-delta
#       branch, patch_same_review): case 1 (#23) rc 12, one post with
#       `how:restamp-rebase`; case 5 (#24) rc 0, no post
# bin/review-prs.sh (its real bin/lib closure, the jobs functions stubbed):
#   P1  case 1 (#61): R buys 1 agent call; H buys 0, state replayed_from=R,
#       replay_how=restamp-rebase, the `own patch unchanged (restamp-rebase)` line
#   P5  case 5 (#62): R buys 1; H buys exactly 1 more, no replay recorded
# bin/review-autopilot.sh (its real bin/lib closure, file mode):
#   A1  case 1 (#71): R buys 1 call; H buys 0 and posts nothing, its key says
#       `replayed_from=<R12> how=restamp-rebase`, the replay line
#   A5  case 5 (#72): H buys exactly 1 more review
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-replay-restamp.bh-9066-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
TD=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lib/patch-same.sh bin/lib/lead-delta.sh bin/lib/lead-gates.d/50-replay-delta.sh \
         bin/lead-review.sh bin/review-prs.sh bin/review-autopilot.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
# No box credential, env dir or worker decides a path in this suite.
unset HARNESS_ENV_DIR HARNESS_SECRET JOBS_URL HARNESS_WORKERS_SUBDOMAIN GH_TOKEN GH_EXTRA_READ_TOKEN \
  GH_EXTRA_READ_REPOS GH_TOKEN_INSTALLATION_ID GH_LIMIT_IDENTITY HARNESS_LANE HARNESS_LANE_WT \
  HARNESS_LANE_PROJECT HARNESS_TICKET HARNESS_CHECKOUT JOBS_BOX AGENT_CALL_FP AGENT_CALL_GUARD_STAGE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE='2026-11-05T12:00:00Z' GIT_COMMITTER_DATE='2026-11-05T12:00:00Z'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
BASE_PATH="$PATH"

# Each section runs in its own subshell (the lead fixture exports a PATH and a
# worker URL); the results go to one file.
RES="$T/results"; : > "$RES"
ok()  { echo ok >> "$RES"; }
bad() { echo bad >> "$RES"; echo "FAIL: $1"; }

# ───────────────────────────── the git fixture ─────────────────────────────
SD=worker/jobs/schema.d
GW="$T/gw"
gw() { git -C "$GW" "$@"; }
git init -q -b main "$GW"
mkdir -p "$GW/$SD"
printf 'CREATE TABLE base_fixture (id INTEGER);\n' > "$GW/$SD/202610010000-bh-0-base.sql"
seq 1 30 | sed 's/^/line /' > "$GW/f.txt"
printf '# fixture repo\n\nNo contract here.\n' > "$GW/CLAUDE.md"
gw add -A; gw commit -qm base; B0=$(gw rev-parse HEAD)
printf 'main moved fixture\n' > "$GW/o.txt"
gw add -A; gw commit -qm "main moves"; M1=$(gw rev-parse HEAD)
# mkpair <case> — R on B0; H = R rebased onto M1, restamped (case 5: + a code line)
mkpair() {
  gw checkout -q --detach "$B0"
  printf 'CREATE TABLE a_fixture (id INTEGER);\n' > "$GW/$SD/202611041200-bh-1-a.sql"
  printf 'applies %s/202611041200-bh-1-a.sql\n' "$SD" > "$GW/refs.txt"
  sed -i '10s/.*/line 10 CHANGED BY PR/' "$GW/f.txt"
  gw add -A; gw commit -qm "pr change case $1"; R=$(gw rev-parse HEAD)
  gw rebase -q "$M1" >/dev/null 2>&1 || { echo "FIXTURE: rebase failed"; return 1; }
  gw mv "$SD/202611041200-bh-1-a.sql" "$SD/202611051300-bh-1-a.sql"
  sed -i 's/202611041200-bh-1-a/202611051300-bh-1-a/' "$GW/refs.txt"
  [ "$1" = 5 ] && sed -i '20s/.*/line 20 REAL CODE CHANGE/' "$GW/f.txt"
  gw add -A; gw commit -qm "restamp case $1"; H=$(gw rev-parse HEAD)
}
mkpair 1 || exit 1; R1=$R; H1=$H
mkpair 5 || exit 1; R5=$R; H5=$H
gw checkout -q main
if gw merge-base --is-ancestor "$R1" "$H1" || [ "$(gw rev-parse "$H1~2")" != "$M1" ]; then
  echo "FAIL: fixture: H1 is not R1 rebased onto main plus one commit"; exit 1
fi
[ "$(gw show "$H1:refs.txt")" = "applies $SD/202611051300-bh-1-a.sql" ] || { echo "FAIL: fixture: refs.txt not rewritten"; exit 1; }
# pubremote <bare> <ref=sha>... — a bare remote with main at M1, R1/R5 kept reachable
pubremote() {
  local o="$1" r a=(); shift
  [ -d "$o" ] || git init -q --bare -b main "$o"
  for r in "$@"; do a+=("$r"); done
  git -C "$GW" push -q -f "$o" "$M1:refs/heads/main" "$R1:refs/heads/keep-r1" "$R5:refs/heads/keep-r5" "${a[@]}" >/dev/null 2>&1
}

# ═══════════════════ gate 50 through the lead worklist fixture ═══════════════════
(
  . "$TD/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
  lwf_setup
  export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
  # Gate 07 (merge carry) is off: this suite pins gate 50.
  export LEAD_REVIEW_MERGE_CARRY=0
  GATE50="$H/bin/lib/lead-gates.d/50-replay-delta.sh"
  [ -r "$GATE50" ] || { bad "setup: the closure of bin/lead-review.sh has no gate 50"; exit 0; }
  pubremote "$O" "$H1:refs/pull/21/head" "$H5:refs/pull/22/head" "$H1:refs/pull/23/head" "$H5:refs/pull/24/head" \
    || { bad "setup: push to the demo-os remote"; exit 0; }
  CL="$T/repos/demo-os"; scratch_rm "$CL"
  git clone -q "$O" "$CL" && git -C "$CL" fetch -q origin "+refs/pull/*:refs/remotes/origin/pull/*" \
    || { bad "setup: clone of the demo-os remote"; exit 0; }
  MODES="$H/state/lead-review-enqueue/modes.tsv"
  DELTA="$H/state/lead-review-enqueue/delta.tsv"

  # G1: ld_classify
  cls() {
    ( HARNESS="$H"; . "$H/bin/lib/lead-authority.sh"; . "$H/bin/lib/patch-same.sh"; . "$H/bin/lib/lead-delta.sh"
      setting_get() { return 2; }
      _jobs_req() { lpp_jobs_req "$LPPF" "$LPPDOWN" "$@"; }
      ld_classify "$CL" origin/main "$1" "$2" example-org/demo-os MERGE ) 2>/dev/null
  }
  V=$(cls "$R1" "$H1")
  [ "$V" = "replay restamp-rebase" ] && ok || bad "G1 ld_classify case 1: want 'replay restamp-rebase', got '$V'"
  V=$(cls "$R5" "$H5")
  case "$V" in "replay "*|"") bad "G1 ld_classify case 5: want a class that is not replay, got '$V'" ;; *) ok ;; esac

  djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
  vposts() { grep '^POST /api/verdicts ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/verdicts //'; }
  nvposts() { lwf_cnt '^POST /api/verdicts ' "$T/log/worker"; }
  # dset <pr> <R> <H> — <pr> on H, the builder APPROVE on R rebound to H, the lead MERGE on R
  dset() {
    lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
    lwf_needs_at example-org/demo-os "$3" "$1"; echo "$3" > "$FX/head.$1"
    lwf_bv "$1" APPROVE "$2" "reapproved@$3"
    printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
    jq -nc --arg g "$2" --argjson n "$1" \
      '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:$n, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' \
      > "$FX/verdicts.json"
  }

  # G2: case 1 on the tick (the delta branch)
  dset 21 "$R1" "$H1"; lwf_tick
  [ "$(nvposts)" = 1 ] && ok || bad "G2 #21 posts=$(nvposts) (want 1): $(vposts) / $(tail -5 "$L" 2>/dev/null)"
  [ "$(vposts | jq -r '.verdict + " " + .head_sha + " " + .note' 2>/dev/null)" = "MERGE $H1 lead-replay:${R1:0:12} how:restamp-rebase" ] \
    && ok || bad "G2 #21 the post is not the restamp-rebase replay of MERGE on H: $(vposts)"
  grep -q "example-org/demo-os#21 @${H1:0:12}: lead MERGE replayed from ${R1:0:12} (how:restamp-rebase, post rc 0); no review" "$L" \
    && ok || bad "G2 #21 no replay line: $(tail -5 "$L" 2>/dev/null)"
  [ "$(djobs 21)" = 0 ] && ok || bad "G2 #21 jobs=$(djobs 21) (want 0)"
  [ "$(lwf_agents)" = 0 ] && ok || bad "G2 #21 model calls=$(lwf_agents) (want 0)"
  awk -F'\t' -v n=21 -v h="$H1" '$3 == n && $5 == h && $7 == "replay restamp-rebase"' "$DELTA" 2>/dev/null | grep -q . \
    && ok || bad "G2 #21 no delta.tsv row 'replay restamp-rebase' (the delta branch did not classify): $(cat "$DELTA" 2>/dev/null)"
  awk -F'\t' -v n=21 '$3 == "replay" && $5 == n && $7 == "from='"${R1:0:12}"' how=restamp-rebase"' "$MODES" 2>/dev/null | grep -q . \
    && ok || bad "G2 #21 no modes.tsv replay row: $(cat "$MODES" 2>/dev/null)"

  # G3: case 5 on the tick
  dset 22 "$R5" "$H5"; lwf_tick
  [ "$(nvposts)" = 0 ] && ok || bad "G3 #22 posts=$(nvposts) (want 0): $(vposts)"
  [ "$(djobs 22)" = 1 ] && ok || bad "G3 #22 jobs=$(djobs 22) (want 1): $(tail -5 "$L" 2>/dev/null)"

  # G4: gate 50 with bin/lib/lead-delta.sh not loaded (the non-delta branch)
  gate_nd() {
    ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$FX/lead-token" JOBS_BOX=box-fixture
      . "$H/bin/lib/lead-authority.sh"; . "$H/bin/lib/patch-same.sh"
      . "$GATE50" || exit 3
      command -v ld_classify >/dev/null 2>&1 && exit 4
      setting_get() { return 2; }
      _jobs_req() {
        case "$2" in /api/verdicts*) [ "$1" = GET ] && cat "$FX/verdicts.json" ;; *) lpp_jobs_req "$LPPF" "$LPPDOWN" "$@" ;; esac
      }
      lgs_dir() { mkdir -p "$T/lgs" && printf '%s\n' "$T/lgs"; }
      _lgt_log() { echo "$*" >> "$T/log/gate-nd"; }
      LGB_KEY="example-org/demo-os#$1@$2"; LGB_APPROVED=0; LGB_REBOUND=0
      lg_gate_replay_delta example-org/demo-os "$1" "$2" ) 2>>"$T/gate-nd.err"
  }
  dset 23 "$R1" "$H1"; gate_nd 23 "$H1"; rc=$?
  [ "$rc" = 12 ] && ok || bad "G4 #23 non-delta gate 50 on case 1: want rc 12, got $rc ($(cat "$T/log/gate-nd" 2>/dev/null))"
  [ "$(nvposts)" = 1 ] && [ "$(vposts | jq -r '.note' 2>/dev/null)" = "lead-replay:${R1:0:12} how:restamp-rebase" ] \
    && ok || bad "G4 #23 want one post with note 'lead-replay:${R1:0:12} how:restamp-rebase': $(vposts)"
  dset 24 "$R5" "$H5"; gate_nd 24 "$H5"; rc=$?
  [ "$rc" = 0 ] && [ "$(nvposts)" = 0 ] && ok || bad "G4 #24 non-delta gate 50 on case 5: want rc 0 and no post, got rc $rc, posts $(nvposts)"
  grep -q "example-org/demo-os#24 @${H5:0:12}: patch changed since ${R5:0:12}; full review" "$T/log/gate-nd" 2>/dev/null \
    && ok || bad "G4 #24 no full-review line: $(cat "$T/log/gate-nd" 2>/dev/null)"
  exit 0
) || bad "the gate 50 section stopped (rc $?)"

# ═════════════════════════════ bin/review-prs.sh ═════════════════════════════
(
  . "$TD/lib/gh-list-bridge.sh" || exit 1
  . "$TD/lib/verdict-fixture.sh" || exit 1
  vpf_export || exit 1
  . "$TD/lib/model-route-stub.sh" || exit 1
  RD="$T/rp"; Hr="$RD/h"; PROJECT=project-1
  STATE="$Hr/state/$PROJECT.pr-reviews.json"; LOG="$Hr/logs/pr-reviews.log"
  mkdir -p "$RD/bin" "$RD/log"
  cp "$SRC/tests/lib/rest-emit.sh" "$RD/bin/restpr"; chmod +x "$RD/bin/restpr"
  cat > "$RD/bin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"/pulls -f state=open"*) case "$*" in *"page=1"|*"page=1 "*) restpr --raw 200 "$(cat "$TEST_ROOT/prs.json")" ;;
      *) restpr --raw 200 '[]' ;; esac ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*) printf '{"body":"test body","comments":[],"reviews":[]}\n' ;;
  *"pr review"*|*"pr comment"*) printf 'WRITE %s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *) : ;;
esac
exit 0
STUB
  # No request leaves the box: any curl answers 404.
  printf '#!/bin/bash\nprintf "%%s\\n%%s" "{\\"error\\":\\"not found\\"}" 404\n' > "$RD/bin/curl"
  chmod +x "$RD/bin/gh" "$RD/bin/curl"
  printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$RD/meminfo"
  cat > "$RD/stub.sh" <<'EOF'
job_lane_open() { JOB_ID="job-$2"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
_jobs_req() { case "$2" in /api/verdicts*) printf '{"rows":[]}' ;; *) printf '{"rounds":[]}' ;; esac; return 0; }
job_verdict_history() { return 2; }
pr_attempt_list() { return 0; }
EOF
  pubremote "$RD/remote.git" "$H1:refs/heads/pr-61" "$H5:refs/heads/pr-62" || { bad "setup: push to the review-prs remote"; exit 0; }
  mkdir -p "$RD/repos"; git clone -q "$RD/remote.git" "$RD/repos/$PROJECT" || { bad "setup: review-prs clone"; exit 0; }
  fresh() {
    scratch_rm "$Hr" 2>/dev/null
    rm -f "$RD/log"/* "$RD/gh-writes.log"
    mkdir -p "$Hr/bin" "$Hr/state" "$Hr/logs" "$Hr/locks" "$Hr/env" "$Hr/builds" "$Hr/tmp" "$Hr/catalog/lanes.d"
    cp "$SRC/catalog/lanes.d/_lib.json" "$Hr/catalog/lanes.d/"
    cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$Hr/bin/"
    scratch_install_closure bin/review-prs.sh "$Hr" >/dev/null || { echo "closure install failed"; exit 1; }
    mrs_fixture "$Hr" "$PROJECT"
    cp "$RD/stub.sh" "$Hr/bin/stub.sh"
    for b in beat.sh deploy-request.sh merge-queue.sh alert-line.sh; do printf '#!/bin/bash\nexit 0\n' > "$Hr/bin/$b"; chmod +x "$Hr/bin/$b"; done
    cat > "$Hr/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${AGENT_CALL_FP:-call}" >> "$RD/log/sink"
printf 'claude\n' > "\$5.runner"
printf 'Static review.\nTIER: 2\nVERDICT: APPROVE\n' > "\$5"
exit 0
EOF
    chmod +x "$Hr/bin/agent-call.sh"
    printf '{}\n' > "$STATE"; : > "$RD/log/sink"
  }
  # head <pr> <sha> — the one open PR
  head_is() {
    jq -nc --argjson n "$1" --arg h "$2" '[{number:$n, head:{sha:$h,ref:"ticket/x-fixture"}, base:{ref:"main"},
       user:{login:"externaldev-fixture",type:"User"}, title:"Test PR fixture", draft:false, state:"open", labels:[]}]' > "$RD/prs.json"
  }
  run_rp() {
    ( export PATH="$RD/bin:$BASE_PATH" HARNESS="$Hr" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$RD" \
        REPOS_ROOT="$RD/repos" BASH_ENV="$Hr/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_CONCURRENCY=1 \
        REVIEW_POOL_MEMINFO="$RD/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$RD/tmp-$1"
      mkdir -p "$TMPDIR"
      unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_POOL_TMP_PATH \
        REVIEW_DEDUPE REVIEW_CI_STALE_SECS
      bash "$Hr/bin/review-prs.sh" "$PROJECT" > "$RD/out.$1" 2>&1 )
  }
  calls() { local n; n=$(grep -c . "$RD/log/sink" 2>/dev/null); echo "${n:-0}"; }
  st() { jq -r --arg n "$1" ".[\$n].$2 // \"\"" "$STATE" 2>/dev/null; }

  # P1: case 1
  fresh; head_is 61 "$R1"; run_rp p1a
  [ "$(calls)" = 1 ] && [ "$(st 61 sha)" = "$R1" ] && [ "$(st 61 verdict)" = APPROVE ] && ok \
    || bad "P1 setup: R must buy 1 review with APPROVE on R: calls=$(calls) $(cat "$STATE") $(tail -3 "$LOG" 2>/dev/null)"
  head_is 61 "$H1"; run_rp p1b
  [ "$(calls)" = 1 ] && ok || bad "P1 a restamp-rebase head must buy NO review, got $(( $(calls) - 1 )) new call(s): $(tail -3 "$LOG" 2>/dev/null)"
  [ "$(st 61 sha)" = "$H1" ] && [ "$(st 61 verdict)" = APPROVE ] && ok || bad "P1 the verdict must sit on H: $(cat "$STATE")"
  [ "$(st 61 replayed_from)" = "$R1" ] && [ "$(st 61 replay_how)" = restamp-rebase ] && ok \
    || bad "P1 want replayed_from=R and replay_how=restamp-rebase: $(cat "$STATE")"
  grep -q "#61 @${H1:0:7} verdict REPLAYED from ${R1:0:7} (APPROVE): own patch unchanged (restamp-rebase)" "$LOG" 2>/dev/null \
    && ok || bad "P1 no replay line: $(tail -3 "$LOG" 2>/dev/null)"

  # P5: case 5
  fresh; head_is 62 "$R5"; run_rp p5a
  [ "$(calls)" = 1 ] && ok || bad "P5 setup: R must buy 1 review, calls=$(calls)"
  head_is 62 "$H5"; run_rp p5b
  [ "$(calls)" = 2 ] && ok || bad "P5 a code change must buy exactly 1 new review, got $(( $(calls) - 1 )) new"
  [ "$(st 62 sha)" = "$H5" ] && [ -z "$(st 62 replayed_from)" ] && ok || bad "P5 H must be reviewed, not replayed: $(cat "$STATE")"
  exit 0
) || bad "the review-prs section stopped (rc $?)"

# ═══════════════════════════ bin/review-autopilot.sh ═══════════════════════════
(
  . "$TD/lib/verdict-fixture.sh" || exit 1
  vpf_export || exit 1
  . "$TD/lib/model-route-stub.sh" || exit 1
  AD="$T/ap"; Ha="$AD/h"
  NOW=1793966400   # 2026-11-06 12:00Z: the lane's REVIEW_AUTOPILOT_NOW seam
  CREATED="2026-11-01T00:00:00Z"
  STATE="$Ha/state/review-autopilot"; RLOG="$Ha/logs/review-autopilot.log"
  mkdir -p "$AD/bin" "$Ha/logs" "$Ha/locks" "$Ha/env" "$Ha/state" "$Ha/flags"
  scratch_install_closure bin/review-autopilot.sh "$Ha" >/dev/null || { bad "setup: closure of bin/review-autopilot.sh"; exit 0; }
  scratch_install_closure bin/jobs-client.sh "$Ha" >/dev/null || { bad "setup: closure of bin/jobs-client.sh"; exit 0; }
  scratch_install_closure bin/fleet-conf.sh "$Ha" >/dev/null || { bad "setup: closure of bin/fleet-conf.sh"; exit 0; }
  chmod +x "$Ha/bin/"*.sh
  printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$Ha/fleet.conf"
  printf 'HARNESS_SECRET=secret-fixture-1\nJOBS_URL=https://jobs.fixture.test\n' > "$Ha/env/global.env"
  mrs_fixture "$Ha" p1
  # The fake worker: every GET is a 404 (flags fall to files, routes to the box
  # cache), every write a 200 (the replay's box row records).
  cat > "$AD/bin/curl" <<'EOF'
#!/bin/bash
M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
if [ "$M" = GET ]; then printf '{"error":"not found"}\n404'; else printf '{"ok":true}\n200'; fi
EOF
  { printf '#!/bin/bash\nT=%q\n' "$AD"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  echo post >> "$T/post-count.txt"; exit 0
fi
case "$*" in
  api\ repos/o/p1/issues/*/comments*) printf '[]\n' ;;
  *repos/o/p1/pulls/[0-9]*) printf 'HTTP/2.0 200 OK\r\n\r\n{"state":"open","merged_at":null}\n' ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'f.txt\n' ;;
  *"pr diff"*)              printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
esac
exit 0
EOF
  } > "$AD/bin/gh"
  { printf '#!/bin/bash\nT=%q\n' "$AD"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
printf 'Nothing load-bearing was deferred.\n\nVERDICT: MERGE — reads fine\n' > "$5"
exit 0
EOF
  } > "$Ha/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$Ha/bin/beat.sh"
  chmod +x "$AD/bin/curl" "$AD/bin/gh" "$Ha/bin/agent-call.sh" "$Ha/bin/beat.sh"
  pubremote "$AD/remote.git" "$H1:refs/heads/pr-71" "$H5:refs/heads/pr-72" || { bad "setup: push to the autopilot remote"; exit 0; }
  mkdir -p "$AD/repos"; git clone -q "$AD/remote.git" "$AD/repos/p1" || { bad "setup: autopilot clone"; exit 0; }

  pulls_for() { # pulls_for <pr> <sha>
    jq -n --argjson n "$1" --arg sha "$2" --arg c "$CREATED" \
      '[{number:$n,html_url:"https://github.com/o/p1/pull/\($n)",title:"BH-x: a fixture thing",
         body:"Closes #\($n)",head:{sha:$sha,ref:"ticket/x-fixture"},base:{ref:"main"},
         draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
         merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$AD/pulls.json"
  }
  RUN() { ( PATH="$AD/bin:$BASE_PATH" HARNESS="$Ha" FLEET_CONF="$Ha/fleet.conf" GH_TOKEN="" \
            HARNESS_TEST_SANDBOX=1 REVIEW_AUTOPILOT_NOW="$NOW" JOBS_BOX=box-fixture JOBS_RETRIES=0 \
            REPOS_ROOT="$AD/repos" bash "$Ha/bin/review-autopilot.sh" >>"$AD/run.log" 2>&1 ) || true; }
  CALLS() { local n; n=$(grep -c . "$AD/agent-calls.txt" 2>/dev/null); echo "${n:-0}"; }
  POSTS() { local n; n=$(grep -c . "$AD/post-count.txt" 2>/dev/null); echo "${n:-0}"; }
  KEYOF() { printf '%s/o-p1-%s-%s' "$STATE" "$1" "${2:0:12}"; }
  RESET() { scratch_rm "$STATE"; : > "$AD/agent-calls.txt"; : > "$AD/post-count.txt"; : > "$AD/gh-calls.txt"; : > "$RLOG"; : > "$AD/run.log"; }

  # A1: case 1
  RESET; pulls_for 71 "$R1"; RUN
  [ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "A1 setup: R must buy 1 review and 1 post: calls=$(CALLS) posts=$(POSTS) $(tail -3 "$RLOG")"
  [ "$(sed -n 2p "$(KEYOF 71 "$R1")" 2>/dev/null)" = "sha=$R1" ] && ok || bad "A1 setup: R's key: $(cat "$(KEYOF 71 "$R1")" 2>/dev/null)"
  pulls_for 71 "$H1"; RUN
  [ "$(CALLS)" = 1 ] && ok || bad "A1 a restamp-rebase head must buy NO review, calls=$(CALLS): $(tail -3 "$RLOG")"
  [ "$(POSTS)" = 1 ] && ok || bad "A1 a replay posts nothing, posts=$(POSTS)"
  K=$(KEYOF 71 "$H1")
  [[ "$(head -1 "$K" 2>/dev/null)" =~ ^reviewed\ .*\ verdict=MERGE$ ]] && ok || bad "A1 H's key must carry MERGE: '$(head -1 "$K" 2>/dev/null)'"
  [ "$(sed -n 2p "$K" 2>/dev/null)" = "replayed_from=${R1:0:12} how=restamp-rebase" ] && ok \
    || bad "A1 want 'replayed_from=${R1:0:12} how=restamp-rebase': '$(sed -n 2p "$K" 2>/dev/null)'"
  grep -q "#71 @${H1:0:12} verdict REPLAYED from ${R1:0:12} (MERGE): own patch unchanged (restamp-rebase)" "$RLOG" \
    && ok || bad "A1 no replay line: $(tail -3 "$RLOG")"

  # A5: case 5
  RESET; pulls_for 72 "$R5"; RUN
  [ "$(CALLS)" = 1 ] && ok || bad "A5 setup: R must buy 1 review, calls=$(CALLS)"
  pulls_for 72 "$H5"; RUN
  [ "$(CALLS)" = 2 ] && ok || bad "A5 a code change must buy exactly 1 new review, calls=$(CALLS): $(tail -3 "$RLOG")"
  grep -q "#72 .*REPLAYED" "$RLOG" && bad "A5 case 5 was replayed: $(grep REPLAYED "$RLOG")" || ok
  exit 0
) || bad "the autopilot section stopped (rc $?)"

PASS=$(grep -c '^ok$' "$RES"); FAIL=$(grep -c '^bad$' "$RES")
[ "$PASS" -gt 0 ] || { echo "FAIL: no assertion ran"; FAIL=$((FAIL + 1)); }
echo "review-replay-restamp.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
