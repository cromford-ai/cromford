#!/bin/bash
# tests/merge-conductor-deadend-test.sh — BH-764: the merge conductor's three
# dead ends must each end in a named, logged action.
#
#   1. HEAD_MOVED on a PR that already carries a >12h review-autopilot verdict
#      for THIS head: the verdict is consumed (MERGE/MERGE-WITH-NOTES rebinds
#      the approval, BLOCK parks head-not-reapproved for bin/blocked-resolver.sh)
#      instead of a second paid re-review, or nothing at all. Only a comment by
#      a HARNESS login counts, and a MERGE only rebinds on a head CI has passed.
#   2. A head whose every run was cancelled/timed out, which BH-636's flake
#      ladder has already re-run once, and whose rerun died the same way: the
#      review is bought WITHOUT CI, said once, and the verdict comment says so.
#      BH-636 owns the rerun itself; nothing here dispatches a second one.
#   3. NEEDS_REBASE exits that rebase nothing: each logs one NO_REBASE line
#      naming itself, and the merge-tree line stops promising a rebase it is
#      not going to run.
#
# WHY DRIVEN. Every claim here is about control flow inside
# bin/merge-conductor.sh — which branch a tick takes, what it writes to
# attempts.txt, what it logs, and above all what it does NOT buy. A grep over
# the source passes just as happily on a branch no tick can reach. So the real
# script runs against a scratch $HARNESS with gh/git/curl stubbed, and every
# assertion reads an artifact: the row in pr-state.tsv, a line in attempts.txt,
# the log, the gh-call sink, or the presence of a detached job file.
#
# Run from anywhere: bash tests/merge-conductor-deadend-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 145 || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ---------------------------------------------------------------------------
# The scratch harness. Modelled on tests/merge-conductor-test.sh section 4: one
# project (demo-os), one PR (12), a build record whose review.md carries an
# APPROVE bound to $H_OLD, and stubs for gh / git / curl / agent-call.
# ---------------------------------------------------------------------------
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/fakebin" "$T/runs" "$T/comments" "$T/repos"
# bin/lib/gh-rest.sh rides with the conductor lib (BH-784): the pre-action
# re-read, the body read and the iron-law diff all go through it, and a tree
# without it keeps the lib's fail-closed shims — every read would then answer
# "unverifiable" and the ticks below would decide nothing.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1951): the autopilot verdict is a source=box ROW now, read by
# mc_autopilot_verdict through bin/lib/verdicts.sh, which merge-conductor-lib.sh
# loads through block-gate.sh exactly as it does on the hub.
cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$T/h/bin/lib/"
# The shared REST answer emitter: gh-rest.sh judges the HTTP STATUS LINE that
# `gh api -i` prints, so a stub arm that echoes a word says nothing at all.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-7086: MC_DEADEND_RR_DELAY_S=<n> delays every detached re-review job in the
# SCRATCH copy only, so the drain in reset12 can be proved under a slow runner.
if [ -n "${MC_DEADEND_RR_DELAY_S:-}" ]; then
  sed -i "/^mc_rereview_run() {\$/a sleep ${MC_DEADEND_RR_DELAY_S//[!0-9]/}" "$T/h/bin/lib/mc/rebase.sh"
  grep -q '^sleep [0-9]' <<<"$(grep -A1 '^mc_rereview_run() {$' "$T/h/bin/lib/mc/rebase.sh")" \
    || { echo "FAIL: MC_DEADEND_RR_DELAY_S set but mc_rereview_run was not found in the scratch copy"; exit 1; }
fi
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
# agent-call.sh review <project> <model> <timeout> <out-file> @<prompt-file>:
# the out file is $5, and a review lane that wrote nothing is a LANE FAILURE to
# mc_review_lane_failure, not a verdict — so this stub has to write a real one.
printf '#!/bin/bash\nprintf "static review\\nVERDICT: APPROVE\\n" > "$5"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"

H_OLD=aaaaaaaa1111          # the sha the build record's APPROVE is bound to
H_CUT=cccccccc2222          # every run on it was cancelled by its job timeout
H_NORUN=dddddddd3333        # no workflow run at all
H_PEND=eeeeeeee4444eeeeeeeeeeeeeeeeeeeeeeeeeeee  # a run still going (full: a verdict row binds to a full sha)
H_AP=ffffffff5555ffffffffffffffffffffffffffff  # autopilot said MERGE about this head
H_BLK=9999999966669999999999999999999999999999  # autopilot said BLOCK about this head
H_GRN=bbbbbbbb7777          # green, no autopilot verdict anywhere

REC="$T/h/builds/pool-demo-os-TK-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H_OLD" > "$REC/reviewed-sha"

# --- run fixtures: real actions/runs JSON, so the stub's jq is gh's jq --------
wr() { # wr <id> <workflow-name> <started-at> <attempt> <status> <conclusion|->
  local c='null'; [ "$6" = - ] || c="\"$6\""
  printf '{"id":%s,"name":"%s","run_started_at":"%s","run_attempt":%s,"status":"%s","conclusion":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$c"
}
mkruns() { local sha="$1"; shift; local IFS=,; printf '{"workflow_runs":[%s]}\n' "$*" > "$T/runs/$sha.json"; }
mkgreen() { mkruns "$1" "$(wr "$2" 'Harness CI' '2026-09-18T00:00:00Z' 1 completed success)"; }

mkgreen "$H_OLD" 900
mkruns "$H_CUT"   "$(wr 901 'Harness CI' '2026-09-18T00:00:00Z' 1 completed cancelled)" \
                  "$(wr 902 'E2E'        '2026-09-18T00:00:00Z' 1 completed timed_out)"
printf '{"workflow_runs":[]}\n' > "$T/runs/$H_NORUN.json"
mkruns "$H_PEND"  "$(wr 903 'Harness CI' '2026-09-18T00:00:00Z' 1 in_progress -)"
mkgreen "$H_AP"  904
mkgreen "$H_BLK" 905
mkgreen "$H_GRN" 906
echo '[]' > "$T/comments/12.json"

# --- the stubs ---------------------------------------------------------------
# gh: fixture-driven and FAITHFUL — the `-q` expression the caller passed is run
# by the real jq over the real JSON shape, so a change to either side's jq is
# caught here rather than papered over by a stub that pre-extracted the answer.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
Q=""; ARGS=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -q|--jq) Q="\$2"; shift 2 ;;
    *) ARGS+=("\$1"); shift ;;
  esac
done
A="\${ARGS[*]}"
HEAD=\$(cat "$T/prhead" 2>/dev/null)
MS=\$(cat "$T/mergestate" 2>/dev/null); MS="\${MS:-CLEAN}"
MG=MERGEABLE; [ "\$MS" = CLEAN ] || MG=CONFLICTING
answer() { # answer <fixture-file>
  # BH-1586: a gh_rest read (api -i -X GET) gets a whole HTTP response and the
  # RAW fixture JSON — the conductor runs its own jq over it, so the caller's
  # jq is still what is under test. A raw read keeps gh's shape.
  case "\$A" in
    *"api -i -X GET "*)
      [ -f "\$1" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
      restpr --raw 200 "\$(cat "\$1")"; exit 0 ;;
  esac
  [ -f "\$1" ] || exit 1
  if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi
}
case "\$A" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) echo "MERGE ATTEMPTED: \$A" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr comment"*)
    printf '%s\n' "\$A" >> "$T/comments.txt"
    # A COMMENT POSTED WITH --body-file CARRIES ITS TEXT IN THE FILE, not in
    # argv (BH-641 moved the verdict comments onto the review poster, whose
    # rendered findings can be longer than an argument list). Record the body
    # itself alongside the args, so an assertion about what the PR was told is
    # about the comment and not about which flag carried it.
    BF=""; P=""; for X in "\${ARGS[@]}"; do [ "\$P" = --body-file ] && BF="\$X"; P="\$X"; done
    [ -n "\$BF" ] && [ -r "\$BF" ] && cat "\$BF" >> "$T/comments.txt"
    exit 0 ;;
  *"run rerun"*) exit 0 ;;
  *"pr list -R example-org/demo-os --state open"*)
    printf '[{"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"%s","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN"}]\n' "\$HEAD" "\$MS" "\$MG" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*)
    SHA="\${A#*head_sha=}"; SHA="\${SHA%%&*}"; SHA="\${SHA%% *}"
    answer "$T/runs/\$SHA.json" ;;
  # THE CONDUCTOR'S DECISION READS AND ITS COMMENT ARE REST (BH-784).
  # The POST comes first because it shares the autopilot read's path. Its body
  # travels as a FILE, never on argv, so the sink gets the same two facts the
  # old \`gh pr comment --body "…"\` argv put there: one comment line per post,
  # and the text that was posted.
  *"api -i -X POST repos/example-org/demo-os/issues/12/comments"*)
    { printf 'pr comment %s\n' "\$A"
      for a in "\${ARGS[@]}"; do case "\$a" in body=@*) cat "\${a#body=@}"; echo ;; esac; done
    } >> "$T/comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  # The diff read shares the pull's path and is told apart by its Accept header,
  # so it is matched before the pull object itself.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  # The pull object carries what the --json arms below carried: OPEN on the
  # fixture head, the fixture's merge state, and the plain body.
  *"api -i -X GET repos/example-org/demo-os/pulls/12"*)
    restpr OPEN "\$HEAD" ticket/TK-12 main "" "\$MG" "\$MS" app/cromford "" "plain body" ;;
  *"issues/12/comments"*) answer "$T/comments/12.json" ;;
  *"pr view"*"--json state,headRefOid"*) echo "OPEN \$HEAD" ;;
  *"pr view"*"--json state"*) echo OPEN ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# git: patch-id is the md5 of a per-sha file, so "same patch" and "different
# patch" are one fixture each; merge-tree answers whatever $T/mtree-rc says.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *--version*) echo "git version 2.43.0"; exit 0 ;;
  *merge-tree*)
    RC=\$(cat "$T/mtree-rc" 2>/dev/null); RC="\${RC:-0}"
    [ "\$RC" = 1 ] && printf '\nsrc/x.ts\n'
    exit "\$RC" ;;
  *cat-file*) exit 0 ;;
  *ls-remote*|*"remote set-url"*|*clone*|*fetch*) exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*) md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*) SHA="\${A##* }"; cat "$T/patch.\$SHA" 2>/dev/null || printf 'diff-%s\n' "\$SHA"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

# TEST-CHANGE (BH-1951): GET /api/verdicts answers the rows in $T/vrows.json
# (id DESC; `standing` = the newest lead/human row on the head, the worker's
# rule), so an autopilot verdict is set up as the source=box row
# bin/review-autopilot.sh now POSTs, not as a state/review-autopilot file.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
qp() { printf '%s' "\${URL#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*)
    [ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
    jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
      [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
      | {repo:\$r, pr:\$pr, head:\$h,
         standing:([\$rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | first),
         rows:\$rows, truncated:false}' "$T/vrows.json"
    printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

: > "$T/gh-calls.txt"; : > "$T/comments.txt"; : > "$T/gh-writes.txt"
printf '0' > "$T/mtree-rc"
touch "$T/h/flags/merge-conductor-actions"   # actions on, merge flag deliberately OFF

# shellcheck source=/dev/null
. "$T/h/bin/lib/gh-pr-list.sh"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
ATT="$T/h/state/merge-conductor/attempts.txt"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
LOG="$T/h/logs/merge-conductor.log"; touch "$LOG"
RRDIR="$T/h/state/merge-conductor/rereview"
RBDIR="$T/h/state/merge-conductor/rebase"
KEY='example-org/demo-os#12'

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
               "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
tick() { run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" MC_MERGE_TREE=0 "$@"; }
state_of() { awk -F'\t' -v k="$KEY" '$1==k {print $2}' "$ROWS"; }
why_of()   { awk -F'\t' -v k="$KEY" '$1==k {print $7}' "$ROWS"; }
jobs_n()   { ls "$RRDIR"/*.json 2>/dev/null | wc -l; }
# rr_drain — stop every detached job this scratch harness spawned (BH-7086).
# A re-review job rewrites its job file when it ends (mc_rr_write recreates a
# missing file), so deleting the file under a live job brings it back after
# reset12. Wait up to RR_DRAIN_S, then TERM its session (setsid: pgid = pid).
# Only a process whose cmdline names a mc_*_run entry point AND this $T/h is
# ours: a reused pid or another tree's job is never waited on or killed.
rr_ours()  { local c; c=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null) || return 1
             grep -qE 'mc_(rereview|rebase|dv)_run' <<<"$c" && grep -qF "$T/h " <<<"$c"; }
rr_pids()  { { command -v pgrep >/dev/null && pgrep -f 'mc_(rereview|rebase|dv)_run'
               for f in "$RRDIR"/*.json "$RBDIR"/*.json; do [ -f "$f" ] && jq -r '.pid // 0' "$f" 2>/dev/null; done
             } | grep -E '^[1-9][0-9]*$' | sort -u | while read -r p; do rr_ours "$p" && echo "$p"; done; }
rr_drain() { local end=$(( $(date +%s) + ${RR_DRAIN_S:-30} )) p
  while [ -n "$(rr_pids)" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 0.2; done
  for p in $(rr_pids); do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
  sleep 0.2; }
LOGN=0
logmark()  { LOGN=$(wc -l < "$LOG" 2>/dev/null || echo 0); }
logsince() { tail -n +$((LOGN+1)) "$LOG" 2>/dev/null; }
set_pr()   { printf '%s' "$1" > "$T/prhead"; printf '%s' "${2:-CLEAN}" > "$T/mergestate"; }
# Wipe everything this PR carries between cases: the row, its attempt records,
# its job files and its reviewed sha. Nothing here touches another key.
reset12() {
  rr_drain   # BH-7086: a live job would recreate the file deleted below
  awk -F'\t' -v k="$KEY" '$1!=k' "$ROWS" > "$T/rows.tmp" 2>/dev/null; mv -f "$T/rows.tmp" "$ROWS"
  grep -vF "$KEY" "$ATT" > "$T/att.tmp" 2>/dev/null; mv -f "$T/att.tmp" "$ATT"
  find "$RRDIR" "$RBDIR" -maxdepth 1 -type f -delete 2>/dev/null
  rm -f "$T/h/state/merge-conductor/handoff"/* "$T/h/state/merge-conductor/stuck"/* 2>/dev/null
  rm -f "$T/h/state/review-autopilot"/* "$T/vrows.json" 2>/dev/null
  echo "$H_OLD" > "$REC/reviewed-sha"
  echo '[]' > "$T/comments/12.json"
  : > "$T/comments.txt"; : > "$T/gh-calls.txt"
}
# Every head gets its own patch so the patch-id rebind never fires and the PR
# really reaches the head-bound review path.
for S in "$H_OLD" "$H_CUT" "$H_NORUN" "$H_PEND" "$H_AP" "$H_BLK" "$H_GRN"; do
  printf 'patch for %s\n' "$S" > "$T/patch.$S"
done
APS="$T/h/state/review-autopilot"
mkdir -p "$APS"
# vrow <head> <verdict> [source] — one verdicts row on PR 12, as the worker holds
# it (TEST-CHANGE BH-1951: the autopilot's verdict reaches the conductor as a
# source=box row, never as a file under $APS).
vrow() { [ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
         jq -c --arg h "$1" --arg v "$2" --arg s "${3:-box}" \
           '. + [{id:(length + 1), repo:"example-org/demo-os", pr:12, head_sha:$h, verdict:$v, source:$s,
                  note:"review-autopilot", created_at:"2026-09-18T00:10:00Z"}]' "$T/vrows.json" > "$T/vrows.tmp" \
           && mv "$T/vrows.tmp" "$T/vrows.json"; }

# ============================================================================
# 1. mc_autopilot_verdict: bound to a head, and to a harness author
# ============================================================================
apv() { ( PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
           mc_autopilot_verdict example-org/demo-os 12 "$KEY" "$1" ); }
apcomment() { # apcomment <head12> <login> <body>
  jq -n --arg l "$2" --arg b "<!-- harness-review-autopilot $1 -->
$3" '[{"id":1,"user":{"login":$l},"body":$b}]' > "$T/comments/12.json"
}
: > "$ATT"; : > "$T/gh-calls.txt"
# TEST-CHANGE (BH-1951): the autopilot's box ROW answers, and costs no comments
# read; the hub-local file it used to be is not read at all.
vrow "$H_AP" MERGE
[ "$(apv "$H_AP")" = MERGE ] && ok || bad "a box MERGE row on this head must answer MERGE (got '$(apv "$H_AP")')"
grep -q 'issues/12/comments' "$T/gh-calls.txt" && bad "a row hit must cost NO comments read" || ok
rm -f "$T/vrows.json"
: > "$ATT"
printf 'reviewed 2026-09-18 00:10:00Z verdict=MERGE\n' > "$APS/example-org-demo-os-12-${H_AP:0:12}"
[ -z "$(apv "$H_AP")" ] && ok || bad "the state/review-autopilot file alone must not be read (got '$(apv "$H_AP")')"
rm -f "$APS/example-org-demo-os-12-${H_AP:0:12}"
: > "$ATT"; : > "$T/gh-calls.txt"
apcomment "${H_BLK:0:12}" 'cromford[bot]' 'findings about the diff

**VERDICT: BLOCK — a hardcoded model string**'
[ "$(apv "$H_BLK")" = BLOCK ] && ok || bad "a comment carrying this head's marker and a bold VERDICT line must parse to BLOCK (got '$(apv "$H_BLK")')"
: > "$ATT"
[ -z "$(apv "$H_AP")" ] && ok || bad "a comment marked with ANOTHER head12 must never be consumed (got '$(apv "$H_AP")')"
# THE AUTHOR IS HALF THE BINDING. Anyone with comment rights can paste the
# marker; only a harness login may rebind an approval with it.
: > "$ATT"
apcomment "${H_AP:0:12}" 'someone-else' 'looks fine to me

VERDICT: MERGE'
[ -z "$(apv "$H_AP")" ] && ok || bad "a marker comment by a NON-harness login must never be consumed (got '$(apv "$H_AP")')"
# BH-1668 (review of #1926, blocking 2): LISTING A PR AND ISSUING A VERDICT ARE
# DIFFERENT TRUST. The builders App (cromford-builders) is the identity the
# pool build boxes hold — where the LLM build agent runs — so it authors PRs
# but its marker comments must never rebind an approval: that is a build
# approving itself. HARNESS_VERDICT_AUTHORS, not HARNESS_PR_AUTHORS, decides.
: > "$ATT"
apcomment "${H_AP:0:12}" 'cromford-builders[bot]' 'VERDICT: MERGE'
[ -z "$(apv "$H_AP")" ] && ok || bad "a marker comment by the builders App must never be consumed — self-approval (got '$(apv "$H_AP")')"
: > "$ATT"
apcomment "${H_AP:0:12}" 'cromford[bot]' 'VERDICT: MERGE'
[ "$(apv "$H_AP")" = MERGE ] && ok || bad "the hub App's marker comment still counts (got '$(apv "$H_AP")')"
: > "$ATT"
apcomment "${H_AP:0:12}" 'operator' 'this diff would BLOCK on a lesser day

VERDICT: MERGE-WITH-NOTES — fine'
[ "$(apv "$H_AP")" = MERGE-WITH-NOTES ] && ok || bad "a marker comment by a harness login must be read, last VERDICT line wins, not the word BLOCK in prose (got '$(apv "$H_AP")')"
: > "$ATT"
apcomment "${H_AP:0:12}" 'app/cromford' 'findings with no verdict line at all'
[ -z "$(apv "$H_AP")" ] && ok || bad "a marked comment with no VERDICT line must print nothing (got '$(apv "$H_AP")')"
# FAIL CLOSED: without the author list there is no way to tell ours from theirs,
# so the comment path is skipped entirely and no call is made.
: > "$ATT"; : > "$T/gh-calls.txt"
apcomment "${H_AP:0:12}" 'cromford[bot]' 'VERDICT: MERGE'
OUT=$( PATH="$T/fakebin:$PATH" HARNESS="$T/h" bash -c '
  . "'"$T"'/h/bin/lib/merge-conductor-lib.sh"; mc_init
  unset -f harness_verdict_authors_json 2>/dev/null
  mc_autopilot_verdict example-org/demo-os 12 "'"$KEY"'" "'"$H_AP"'"' )
# TEST-CHANGE (BH-1668): the verdict path reads harness_verdict_authors_json now
# (the verdict-author set, split from the PR-author set), so that is the function
# whose absence must fail closed. Same assertion.
[ -z "$OUT" ] && ok || bad "with harness_verdict_authors_json uncallable the comment path must fail closed (got '$OUT')"
grep -q 'issues/12/comments' "$T/gh-calls.txt" && bad "failing closed must also cost no comments read" || ok
: > "$ATT"; echo '[]' > "$T/comments/12.json"
printf 'skipped 2026-09-18 00:10:00Z reason=cap\n' > "$APS/example-org-demo-os-12-${H_AP:0:12}"
[ -z "$(apv "$H_AP")" ] && ok || bad "a 'skipped' mirror line is not a verdict (got '$(apv "$H_AP")')"
printf 'reviewed 2026-09-18 00:10:00Z verdict=UNPARSED\n' > "$APS/example-org-demo-os-12-${H_AP:0:12}"
[ -z "$(apv "$H_AP")" ] && ok || bad "verdict=UNPARSED is never consumed (got '$(apv "$H_AP")')"
rm -f "$APS/example-org-demo-os-12-${H_AP:0:12}"
# The hourly bound: two reads inside MC_AUTOPILOT_RECHECK_SECS cost ONE call.
: > "$ATT"; : > "$T/gh-calls.txt"; echo '[]' > "$T/comments/12.json"
apv "$H_AP" >/dev/null; apv "$H_AP" >/dev/null
[ "$(grep -c 'issues/12/comments' "$T/gh-calls.txt")" = 1 ] && ok || bad "the comments read must be bounded to one per (PR, head) per MC_AUTOPILOT_RECHECK_SECS (got $(grep -c 'issues/12/comments' "$T/gh-calls.txt"))"
[ "$(grep -c "^apread $KEY $H_AP " "$ATT")" -ge 1 ] && ok || bad "the read must be recorded as an apread mark"
# ...and an expired mark asks again.
: > "$T/gh-calls.txt"
( PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_AUTOPILOT_RECHECK_SECS=0 mc_autopilot_verdict example-org/demo-os 12 "$KEY" "$H_AP" ) >/dev/null
[ "$(grep -c 'issues/12/comments' "$T/gh-calls.txt")" = 1 ] && ok || bad "an expired apread mark must buy a fresh read"
# The kill switch reads nothing at all.
: > "$ATT"; : > "$T/gh-calls.txt"
vrow "$H_AP" MERGE
OUT=$( PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test MC_AUTOPILOT_CONSUME=0 mc_autopilot_verdict example-org/demo-os 12 "$KEY" "$H_AP" )
[ -z "$OUT" ] && ok || bad "MC_AUTOPILOT_CONSUME=0 must print nothing (got '$OUT')"
[ -s "$T/gh-calls.txt" ] && bad "MC_AUTOPILOT_CONSUME=0 must make no call" || ok
rm -f "$T/vrows.json"

# ============================================================================
# 2. The autopilot MERGE verdict is consumed instead of a second review
# ============================================================================
reset12; set_pr "$H_AP" CLEAN
vrow "$H_AP" MERGE
logmark; tick
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "a consumed autopilot MERGE must leave the row WAIT_REVIEW for the reclassify (got $(state_of))"
[ "$(head -1 "$REC/reviewed-sha")" = "$H_AP" ] && ok || bad "the consume must rebind reviewed-sha onto the head the verdict is bound to (got $(head -1 "$REC/reviewed-sha"))"
[ "$(jobs_n)" = 0 ] && ok || bad "consuming a verdict we already paid for must buy NO re-review"
[ "$(grep -c 'pr comment' "$T/comments.txt")" = 1 ] && ok || bad "the consume must post exactly one PR comment (got $(grep -c 'pr comment' "$T/comments.txt"))"
grep -q 'autopilot' "$T/comments.txt" && ok || bad "the comment must say the autopilot review is what was consumed"
grep -q 'Judged WITHOUT CI' "$T/comments.txt" && bad "a green head was NOT judged without CI; the footer must not appear" || ok
logsince | grep -q "AUTOPILOT_VERDICT consumed: MERGE on ${H_AP:0:8}" && ok || bad "the consume must be logged by name (got: $(logsince | grep -i autopilot | tr '\n' '|'))"
[ "$(grep -c "^apverdict $KEY $H_AP\$" "$ATT")" = 1 ] && ok || bad "the consume must be recorded exactly once per (PR, head)"
# tick 2 over the same head: nothing new is bought or said.
CN=$(grep -c 'pr comment' "$T/comments.txt"); logmark; tick
[ "$(grep -c 'pr comment' "$T/comments.txt")" = "$CN" ] && ok || bad "a consumed verdict must never be consumed twice"
[ "$(jobs_n)" = 0 ] && ok || bad "tick 2 must still buy no re-review"
# ...and the reclassify does the rest: green CI + CLEAN + reviewed = head = READY
[ "$(state_of)" = READY ] && ok || bad "with CI green and the head CLEAN the rebound approval must reclassify to READY (got $(state_of))"
[ -s "$T/gh-writes.txt" ] && bad "nothing here may merge: $(cat "$T/gh-writes.txt")" || ok
# MC_AUTOPILOT_CONSUME=0 is the way back: today's path, a review is bought.
reset12; set_pr "$H_AP" CLEAN
vrow "$H_AP" MERGE
tick MC_AUTOPILOT_CONSUME=0
[ -f "$(mc_rr_file example-org/demo-os 12 "$H_AP")" ] && ok || bad "with the knob off the conductor must buy the re-review exactly as it does today"
# A NON-HARNESS marker comment on a green head rebinds nothing and pays as usual.
reset12; set_pr "$H_GRN" CLEAN
apcomment "${H_GRN:0:12}" 'someone-else' 'VERDICT: MERGE'
logmark; tick
[ "$(state_of)" = HEAD_MOVED ] && ok || bad "an outsider's marker comment must not move the row (got $(state_of))"
grep -q "^apverdict $KEY $H_GRN\$" "$ATT" && bad "an outsider's marker comment must never be recorded as a consumed verdict" || ok
[ -f "$(mc_rr_file example-org/demo-os 12 "$H_GRN")" ] && ok || bad "the head must buy its own review, exactly as if the comment were not there"
rr_drain   # BH-7086: both section-2 jobs end here, before section 3 counts job files
echo '[]' > "$T/comments/12.json"

# ============================================================================
# 3. A MERGE verdict on a head CI has not passed is NOT consumed
# ============================================================================
reset12; set_pr "$H_PEND" CLEAN
vrow "$H_PEND" MERGE
logmark; tick
[ "$(state_of)" = HEAD_MOVED ] && ok || bad "a MERGE verdict on a pending head must leave the row HEAD_MOVED (got $(state_of))"
grep -q "^apverdict $KEY $H_PEND\$" "$ATT" && bad "a MERGE on a non-green head must record NO consumed verdict" || ok
[ "$(jobs_n)" = 0 ] && ok || bad "and it must buy no review either — the CI debounce still owns this head"
[ -s "$T/comments.txt" ] && bad "nothing may be posted for an unconsumed verdict: $(cat "$T/comments.txt")" || ok
logsince | grep -q "demo-os#12 re-review deferred — CI pending on ${H_PEND:0:8}" && ok || bad "the tick must fall through to the ordinary CI-pending deferral (got: $(logsince | grep -i 'deferred' | tr '\n' '|'))"
# ...and once the same head goes green the verdict IS consumed, on the row
# alone, without a second review.
mkgreen "$H_PEND" 903
logmark; tick
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "once CI is green the held verdict must be consumed (got $(state_of))"
[ "$(grep -c "^apverdict $KEY $H_PEND\$" "$ATT")" = 1 ] && ok || bad "the consume must be recorded once, on the tick that acted"
[ "$(jobs_n)" = 0 ] && ok || bad "the consumed verdict must still buy no review"
mkruns "$H_PEND"  "$(wr 903 'Harness CI' '2026-09-18T00:00:00Z' 1 in_progress -)"

# ============================================================================
# 4. The autopilot BLOCK verdict parks for bin/blocked-resolver.sh
# ============================================================================
reset12; set_pr "$H_BLK" CLEAN
vrow "$H_BLK" BLOCK
logmark; tick
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "an autopilot BLOCK bound to this head must park the PR (got $(state_of))"
[ "$(why_of)" = head-not-reapproved ] && ok || bad "the park reason must be the one bin/blocked-resolver.sh owns (got $(why_of))"
grep -qxF "hbrefused $KEY $H_BLK" "$ATT" && ok || bad "the refusal must be recorded so mc_classify keeps parking this head"
[ "$(jobs_n)" = 0 ] && ok || bad "a BLOCK we already paid for must buy no second review"
[ "$(grep -c "^apverdict $KEY $H_BLK\$" "$ATT")" = 1 ] && ok || bad "the BLOCK consume must be recorded once"
[ -s "$T/h/state/merge-conductor/handoff/example-org_demo-os_12" ] && ok || bad "the park must write the resolver hand-off record"
tick   # second tick: the hand-off line must not be written twice
HO=$(grep -F 'handed to bin/blocked-resolver.sh' "$LOG" \
     | sed -nE 's#^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8})Z ([^ ]+) (BLOCKED_AGENT|RED_TWICE) ([^ :]+).*(https://github\.com/[^ ]+)$#\2 \4#p' \
     | grep -c "^$KEY head-not-reapproved$")
[ "$HO" = 1 ] && ok || bad "exactly ONE line in br_handoff_lines' shape must be written across two ticks (got $HO)"

# ============================================================================
# 5. A twice-cancelled head is reviewed WITHOUT CI, and the verdict says so
# ============================================================================
# BH-636 owns the rerun: rung 0 dispatches it on the SHARED `cirerun` mark, and
# rung 1 waits. Rung 2 — the rerun ended cancelled/timed_out too — is the dead
# end this ticket closes, and it is the ONLY rung that buys a read.
reset12; set_pr "$H_CUT" CLEAN; : > "$T/gh-calls.txt"; logmark; tick
[ "$(state_of)" = HEAD_MOVED ] && ok || bad "the cancelled head must still classify HEAD_MOVED (got $(state_of))"
[ "$(grep -c 'run rerun' "$T/gh-calls.txt")" = 2 ] && ok || bad "BH-636's flake ladder must re-run both dead runs once (got $(grep -c 'run rerun' "$T/gh-calls.txt"))"
[ "$(grep -c "^cirerun $KEY $H_CUT " "$ATT")" = 1 ] && ok || bad "exactly ONE rerun ledger line on this head — no second mark beside cirerun (got $(grep -c "^cirerun $KEY $H_CUT " "$ATT"))"
[ "$(jobs_n)" = 0 ] && ok || bad "rung 0 buys no review: the rerun has not reported yet"
logsince | grep -q 're-review deferred — ci=flake' && ok || bad "rung 0/1 must keep BH-636's deferral line (got: $(logsince | grep -i flake | tr '\n' '|'))"
# rung 1: the mark is fresh, the rerun is still settling — nothing is bought.
reset12; set_pr "$H_CUT" CLEAN
echo "cirerun $KEY $H_CUT $((NOW - 60))" >> "$ATT"
: > "$T/gh-calls.txt"; logmark; tick
[ "$(jobs_n)" = 0 ] && ok || bad "a rerun still inside the settle window must buy no review"
[ "$(grep -c 'run rerun' "$T/gh-calls.txt")" = 0 ] && ok || bad "a head that has spent its one rerun must not be re-run again"
logsince | grep -q 're-review deferred — ci=flake' && ok || bad "rung 1 must say it is waiting on the rerun"
grep -q "^rrnoci $KEY $H_CUT\$" "$ATT" && bad "rung 1 must NOT buy a read without CI" || ok
# rung 2: the rerun has settled and the runs are dead again. Buy it, once.
reset12; set_pr "$H_CUT" CLEAN
echo "cirerun $KEY $H_CUT $((NOW - 600))" >> "$ATT"
: > "$T/gh-calls.txt"; logmark; tick
JFC="$(mc_rr_file example-org/demo-os 12 "$H_CUT")"
[ -f "$JFC" ] && ok || bad "once the one rerun has settled and the runs are still dead, the review must be bought anyway"
[ "$(jobs_n)" = 1 ] && ok || bad "exactly one job file (got $(jobs_n))"
[ "$(grep -c "^rrnoci $KEY $H_CUT\$" "$ATT")" = 1 ] && ok || bad "the without-CI read must be recorded once so the verdict comment can say so"
[ "$(logsince | grep -c 'bought WITHOUT CI')" = 1 ] && ok || bad "buying a review without CI must say so once (got $(logsince | grep -c 'bought WITHOUT CI'))"
[ "$(grep -c 'run rerun' "$T/gh-calls.txt")" = 0 ] && ok || bad "rung 2 must dispatch no second rerun — the ladder is BH-636's and it is spent"
[ "$(grep -c "^cirerun $KEY $H_CUT " "$ATT")" = 1 ] && ok || bad "and it must add no second rerun ledger line"
# tick 2: the job file is the already-bought ledger, and the line is silent.
logmark; tick
[ "$(logsince | grep -c 'bought WITHOUT CI')" = 0 ] && ok || bad "the without-CI line must not repeat every tick (got $(logsince | grep -c 'bought WITHOUT CI'))"
[ "$(jobs_n)" = 1 ] && ok || bad "and no second review is bought"
# THE REFUSAL CASE, which is what the first-write gate is FOR. `rrnoci` is
# recorded before the spawn, so a spawn the daily cap refuses leaves the record
# and comes back to this same branch on the next tick — and must not re-log.
reset12; set_pr "$H_CUT" CLEAN
echo "cirerun $KEY $H_CUT $((NOW - 600))" >> "$ATT"
CAPF="$T/h/state/merge-conductor/rereviews-$(date -u +%Y%m%d).txt"
printf 'demo-os example-org/demo-os#99 someotherhead\n' > "$CAPF"
logmark; tick MC_REREVIEW_DAILY_CAP=1
[ "$(jobs_n)" = 0 ] && ok || bad "the daily cap must refuse the spawn (got $(jobs_n) job files)"
logsince | grep -q 'hit the operator-set daily cap' && ok || bad "the cap refusal must say it is the cap"
[ "$(logsince | grep -c 'bought WITHOUT CI')" = 1 ] && ok || bad "the first tick still says it once (got $(logsince | grep -c 'bought WITHOUT CI'))"
grep -qxF "rrnoci $KEY $H_CUT" "$ATT" && ok || bad "the record is written before the spawn, so a refused spawn keeps it"
logmark; tick MC_REREVIEW_DAILY_CAP=1
[ "$(logsince | grep -c 'bought WITHOUT CI')" = 0 ] && ok || bad "a refused spawn must NOT re-log the without-CI line every tick (got $(logsince | grep -c 'bought WITHOUT CI'))"
logsince | grep -q 'hit the operator-set daily cap' && ok || bad "...while the cap refusal itself still reports, so the row is not silent"
: > "$CAPF"
# ...and the APPROVE that comes back carries the without-CI sentence on the PR.
# Driven from a job file written here rather than from the spawned lane's own
# result, so the assertion is about the comment and not about when a detached
# process happened to finish.
reset12; set_pr "$H_CUT" CLEAN
echo "cirerun $KEY $H_CUT $((NOW - 600))" >> "$ATT"
echo "rrnoci $KEY $H_CUT" >> "$ATT"
JFC="$(mc_rr_file example-org/demo-os 12 "$H_CUT")"
printf 'findings\nVERDICT: APPROVE\n' > "$RRDIR/noci.out"
mc_rr_write "$JFC" done 0 "$NOW" "$NOW" APPROVE "$H_CUT" "$H_OLD" "$RRDIR/noci.out"
: > "$T/comments.txt"; : > "$T/gh-writes.txt"; tick
grep -q 'Judged WITHOUT CI' "$T/comments.txt" && ok || bad "the verdict comment must say the merge was judged without CI (got: $(cat "$T/comments.txt"))"
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "the without-CI APPROVE still only reaches WAIT_REVIEW (got $(state_of))"
# ...and the next tick reclassifies it to WAIT_CI, never READY: READY needs green.
tick
[ "$(state_of)" = WAIT_CI ] && ok || bad "a head with no CI may not reach READY on a without-CI approval (got $(state_of))"
[ -s "$T/gh-writes.txt" ] && bad "nothing judged without CI may merge: $(cat "$T/gh-writes.txt")" || ok
# a head with NO run at all is BH-636's absent-CI kick, not this path
reset12; set_pr "$H_NORUN" CLEAN; : > "$T/gh-calls.txt"; logmark; tick
logsince | grep -q 're-review deferred — ci=absent' && ok || bad "a head with no run at all stays on BH-636's absent-CI path (got: $(logsince | grep -i 'deferred' | tr '\n' '|'))"
[ "$(grep -c 'run rerun' "$T/gh-calls.txt")" = 0 ] && ok || bad "a head with no run has nothing to re-run"
grep -q "^rrnoci $KEY $H_NORUN\$" "$ATT" && bad "a head with no run was never re-run, so it may not be read without CI" || ok
[ "$(jobs_n)" = 0 ] && ok || bad "a norun head must still buy no review"

# ============================================================================
# 6. A verdict consumed on an earlier tick is never a silent return
# ============================================================================
reset12; set_pr "$H_GRN" CLEAN
JFG="$(mc_rr_file example-org/demo-os 12 "$H_GRN")"
printf 'findings\nVERDICT: APPROVE\n' > "$RRDIR/old.out"
mc_rr_write "$JFG" done 0 "$NOW" "$NOW" APPROVE "$H_GRN" "$H_OLD" "$RRDIR/old.out"
echo "rereviewdone $KEY $H_GRN" >> "$ATT"
: > "$T/comments.txt"; logmark; tick
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "a consumed APPROVE on a row still stuck in HEAD_MOVED must be re-applied (got $(state_of))"
[ "$(head -1 "$REC/reviewed-sha")" = "$H_GRN" ] && ok || bad "the re-apply must move reviewed-sha onto the head (got $(head -1 "$REC/reviewed-sha"))"
logsince | grep -q 're-applied once' && ok || bad "the re-apply must say so (got: $(logsince | grep -i 'demo-os#12' | tr '\n' '|'))"
[ -s "$T/comments.txt" ] && bad "the re-apply must not re-post the review comment: $(cat "$T/comments.txt")" || ok
# force the row back to HEAD_MOVED on the same head: one line, then silence
awk -F'\t' -v OFS='\t' -v k="$KEY" '$1==k{$2="HEAD_MOVED"}1' "$ROWS" > "$T/rows.tmp"; mv -f "$T/rows.tmp" "$ROWS"
echo "$H_OLD" > "$REC/reviewed-sha"
logmark; tick
[ "$(logsince | grep -c 'nothing left to apply')" = 1 ] && ok || bad "a verdict with nothing left to apply must say so exactly once (got $(logsince | grep -c 'nothing left to apply'))"
awk -F'\t' -v OFS='\t' -v k="$KEY" '$1==k{$2="HEAD_MOVED"}1' "$ROWS" > "$T/rows.tmp"; mv -f "$T/rows.tmp" "$ROWS"
echo "$H_OLD" > "$REC/reviewed-sha"
logmark; tick
[ "$(logsince | grep -c 'nothing left to apply')" = 0 ] && ok || bad "...and never again on the next tick"

# ============================================================================
# 7. Every NEEDS_REBASE exit that rebases nothing names itself
# ============================================================================
# (a) the attempts guard: this head has had its one rebase and the job file is gone
reset12; set_pr "$H_GRN" DIRTY; echo "$H_GRN" > "$REC/reviewed-sha"
echo "rebase $KEY $H_GRN" >> "$ATT"
: > "$T/gh-calls.txt"; logmark; tick
[ "$(state_of)" = NEEDS_REBASE ] && ok || bad "the DIRTY row must be NEEDS_REBASE (got $(state_of))"
[ "$(logsince | grep -c 'NO_REBASE')" = 1 ] && ok || bad "the attempts guard must log exactly one NO_REBASE line (got $(logsince | grep -c 'NO_REBASE'))"
logsince | grep -q 'already had its one rebase' && ok || bad "the NO_REBASE line must name which exit it is"
logsince | grep -qE 'TICK demo-os .* rebases=0' && ok || bad "nothing was rebased, so the counter must say 0 (got: $(logsince | grep -o 'TICK demo-os .*'))"
[ -z "$(ls "$RBDIR"/*.json 2>/dev/null)" ] && ok || bad "the guard must spawn no rebase"
logmark; tick
[ "$(logsince | grep -c 'NO_REBASE')" = 0 ] && ok || bad "the NO_REBASE line is once per (exit, PR, head), not once per tick"
# past its TTL the stuck re-kick forgets the guard AND its NO_REBASE dedupe, so
# the next cycle speaks again instead of being deduped into silence. The budget
# is pinned to 0 for this one tick so the re-kick's own clearing is what the
# assertions read, not a fresh spawn re-recording the attempt.
awk -F'\t' -v OFS='\t' -v k="$KEY" -v s="$((NOW - 7200))" '$1==k{$3=s}1' "$ROWS" > "$T/rows.tmp"; mv -f "$T/rows.tmp" "$ROWS"
logmark; tick MC_REBASE_BUDGET=0
logsince | grep -q 'forgot this head.s rebase attempt' && ok || bad "the stuck re-kick must fire past the NEEDS_REBASE TTL"
grep -qxF "rebase $KEY $H_GRN" "$ATT" && bad "the re-kick must forget the rebase attempt" || ok
grep -qxF "rebasenoop-attempted $KEY $H_GRN" "$ATT" && bad "the re-kick must also forget the NO_REBASE dedupe, or the next cycle is silent" || ok
echo "rebase $KEY $H_GRN" >> "$ATT"; logmark; tick
[ "$(logsince | grep -c 'NO_REBASE')" = 1 ] && ok || bad "after the re-kick the guard must speak again, not stay deduped (got $(logsince | grep -c 'NO_REBASE'))"

# (b) a detached rebase whose result was consumed on an earlier tick
reset12; set_pr "$H_GRN" DIRTY; echo "$H_GRN" > "$REC/reviewed-sha"
JRB="$(mc_rb_file example-org/demo-os 12 "$H_GRN")"
printf 'rebase output\n' > "$RBDIR/done.out"
mc_rb_write "$JRB" done 0 "$NOW" "$NOW" 0 "$H_GRN" newhead0000 "$RBDIR/done.out"
echo "rebasedone $KEY $H_GRN" >> "$ATT"
logmark; tick
[ "$(logsince | grep -c 'NO_REBASE')" = 1 ] && ok || bad "a consumed rebase result must log exactly one NO_REBASE line (got $(logsince | grep -c 'NO_REBASE'))"
logsince | grep -q 'already produced its result' && ok || bad "the consumed-result NO_REBASE line must name itself"
logsince | grep -qE 'TICK demo-os .* rebases=0' && ok || bad "a consumed result rebases nothing, so rebases=0"

# (c) the budget refusal still says it is the budget
reset12; set_pr "$H_GRN" DIRTY; echo "$H_GRN" > "$REC/reviewed-sha"; logmark
tick MC_REBASE_BUDGET=0
logsince | grep -q 'rebase deferred — demo-os has spent this tick.s rebase budget' && ok || bad "the budget refusal must keep naming the budget (got: $(logsince | grep -i rebase | tr '\n' '|'))"

# (d) a real conflict: the rebase IS spawned, the counter moves, and no line
#     anywhere promised a rebase that did not happen
reset12; set_pr "$H_GRN" DIRTY; echo "$H_GRN" > "$REC/reviewed-sha"; printf '1' > "$T/mtree-rc"; logmark
run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"
logsince | grep -q 'REBASE_SPAWNED' && ok || bad "a conflicted head must still spawn its rebase (got: $(logsince | grep -i rebase | tr '\n' '|'))"
logsince | grep -qE 'TICK demo-os .* rebases=1' && ok || bad "a spawned rebase must move the counter (got: $(logsince | grep -o 'TICK demo-os .*'))"
logsince | grep -q 'GitHub is right, this head needs a rebase' && ok || bad "the merge-tree conflict line must say what is true"
[ "$(grep -c 'GitHub is right, rebasing' "$LOG")" = 0 ] && ok || bad "no line may promise 'rebasing' — the tick spawns a job, it does not rebase"
printf '0' > "$T/mtree-rc"

# ============================================================================
# 8. Regression: a plain green HEAD_MOVED head still buys exactly one review
# ============================================================================
reset12; set_pr "$H_GRN" CLEAN; tick
JF8="$(mc_rr_file example-org/demo-os 12 "$H_GRN")"
[ -f "$JF8" ] && ok || bad "a green moved head with no verdict anywhere must buy its one re-review"
[ "$(jobs_n)" = 1 ] && ok || bad "exactly one job file after tick 1"
tick
[ "$(jobs_n)" = 1 ] && ok || bad "and still exactly one after tick 2 — the job file is the already-bought ledger"
# BH-636 retired this wording and pins its absence; nothing here may bring it back.
[ "$(grep -c 're-review deferred — CI none' "$LOG")" = 0 ] && ok || bad "the retired 'CI none' deferral must never be logged again (got $(grep -c 're-review deferred — CI none' "$LOG"))"

rr_drain   # BH-7086: leave no detached job behind the scratch tree
echo "merge-conductor-deadend-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
