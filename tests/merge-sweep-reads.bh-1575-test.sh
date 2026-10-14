#!/bin/bash
# tests/merge-sweep-reads.bh-1575-test.sh — BH-1575: bin/merge-sweep.sh's per-PR
# GitHub reads.
#
# THE INCIDENT. merge-sweep.log carried 70 lines of
#   <pr> read UNVERIFIABLE (HTTP 304) — skipped this pass, nothing recorded
# in one tick (2026-09-22 12:20-12:22Z, 69 PRs) while the App installation's
# bucket was drained. A 304 is an ETag cache HIT, and gh_rest answers it rc 0.
# The read that failed ran inside `STATE=$(mc_pr_view …)`, so its status died
# with the subshell and the log line printed whatever the PARENT shell's last
# read had said. The sweep also made ~965 GitHub calls an hour: `pulls/N` plus
# `pulls/N/commits` per PR per tick, for PRs the merge conductor had read five
# minutes earlier.
#
# WHAT IS PINNED HERE, each against the real bin/merge-sweep.sh in a scratch tree:
#   A. a failed PR read logs ITS OWN status (a 403, not a stale 304 or a 000);
#   B. a 304 whose cache entry is gone is re-read without If-None-Match — the
#      PR is judged this tick, not skipped;
#   C. a fresh conductor row in a state stricter than the sweep's own gates
#      (NEEDS_REBASE, REBASING, QUEUED, STACKED_WAIT, ABANDONED) costs 0 per-PR
#      GitHub reads — the acceptance line of the scope extension;
#   D. freshness is per project: tick-<P>.json finished inside the knob with
#      prs_seen > 0. A stale tick, a failing PR list (prs_seen=0), no tick
#      record, or the knob at 0 fall back to GitHub;
#   E. an unchanged head sha skips `pulls/N/commits`; a moved head reads it;
#   F. a fresh MERGED row is recorded merged without a read; READY still reads;
#   G. the token probe goes through gh_rest and classifies 404/401/403/429/5xx;
#   H. WAIT_CI, RED_TWICE, WAIT_REVIEW, HEAD_MOVED, BLOCKED_HUMAN rows are read
#      live: the sweep can merge through every one of them.
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

S="$T/s"; PR=https://github.com/o/r/pull/7; REC="$S/builds/pool-p-XX-7-202609150001"
HEAD1=1111111111111111111111111111111111111111
HEAD2=2222222222222222222222222222222222222222
mkdir -p "$S/bin/lib" "$S/logs" "$S/state/merge-conductor" "$S/flags" "$S/locks" "$S/env" "$S/builds" "$T/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$S/bin/sweep.sh"
mkdir -p "$S/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$S/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$S/bin/"
mkdir -p "$S/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$S/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$S/bin/lib/"
mkdir -p "$S/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$S/bin/lib/mc/"
# The lib under test. Copied only when it exists so that a run against a tree
# WITHOUT it (the red run) fails on the behaviour below rather than on the cp;
# section 0 then fails loudly, so a half-installed fixture is never green.
[ -f "$DIR/bin/lib/sweep-reads.sh" ] && cp "$DIR/bin/lib/sweep-reads.sh" "$S/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'p o/r - - 3 box-p\n' > "$S/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/$s"; chmod +x "$S/bin/$s"; done
# No jobs ledger: every ledger read 404s, so the verdict comes from the record.
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# The stub gh. Every call is appended to calls.txt — that file IS the counter the
# acceptance line asks for. $T/mode picks the answer for pulls/7:
#   dirty   200 open, mergeable_state dirty, head = $T/head, with an ETag
#   403     a rate-limit refusal
#   miss    a conditional request (If-None-Match) answers 304 AND deletes the
#           cache entry first (the sweep race); a plain request answers dirty
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.txt"
pull() { printf 'HTTP/1.1 200 OK\r\nETag: "e-%s"\r\n\r\n' "\$(cat "$T/head")"
  jq -nc --arg h "\$(cat "$T/head")" '{state:"open",merged_at:null,closed_at:null,head:{sha:\$h,ref:"ticket/x"},base:{ref:"main"},labels:[],mergeable:false,mergeable_state:"dirty",user:{login:"operator",type:"User"},merge_commit_sha:null,draft:false}'; }
case "\$*" in
  "api repos/o/r -q .id") echo 1 ;;
  "api -i -X GET repos/o/r") restpr --raw 200 '{"id":1}' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"repos/o/r/pulls/7/commits"*)
    restpr --raw 200 "[{\"sha\":\"\$(cat "$T/head")\",\"commit\":{\"committer\":{\"date\":\"2026-09-22T10:00:00Z\"}}}]" ;;
  *"repos/o/r/pulls/7"*)
    case "\$(cat "$T/mode")" in
      403) restpr --raw 403 '{"message":"API rate limit exceeded for installation ID 1."}' ;;
      miss) case "\$*" in
              *If-None-Match*) find "$S/state/gh-etag" -maxdepth 1 -type f ! -name '.*' -delete 2>/dev/null
                               printf 'HTTP/1.1 304 Not Modified\r\n\r\n' ;;
              *) pull ;;
            esac ;;
      *) pull ;;
    esac ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# setup <result-extra> — one APPROVEd pool record for o/r#7, a clean slate of
# logs and ledgers, mode dirty on HEAD1, no pr-state.tsv, no ETag cache.
setup() {
  scratch_rm "$S/builds"; mkdir -p "$REC"
  printf 'PR_CREATED %s\n%s\n' "$PR" "${1:-}" > "$REC/RESULT"
  # A record older than the head's commit date, so a REBASE note reads as
  # stale evidence and the sweep proceeds to the state read.
  touch -t 202609200000 "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  : > "$REC/pipeline.log"
  : > "$S/state/merge-sweep-done.txt"; : > "$S/logs/merge-sweep.log"; : > "$S/logs/ALERTS.log"
  rm -f "$S/state/merge-sweep-terminal.txt" "$S/state/merge-sweep-heads.tsv" "$S/state/merge-conductor/pr-state.tsv" "$S/state/merge-conductor/tick-p.json"
  scratch_rm "$S/state/gh-etag"
  echo dirty > "$T/mode"; echo "$HEAD1" > "$T/head"; : > "$T/calls.txt"
}
# prstate <state> <head> [tick-age-seconds] [prs_seen] — one conductor row for
# o/r#7, plus the conductor's per-project tick record (tick-p.json) that says
# whether project p's rows are fresh. The ROW FILE is always written now: its
# mtime is exactly what the #1599 review showed cannot vouch for one project.
prstate() {
  printf 'o/r#7\t%s\t%s\t%s\t%s\t-\treason\t%s\n' "$1" "$(date +%s)" "$2" "$2" "$PR" \
    > "$S/state/merge-conductor/pr-state.tsv"
  local fin=$(( $(date +%s) - ${3:-0} ))
  printf '{"tick":"t","project":"p","started_at":%s,"finished_at":%s,"prs_seen":%s}\n' \
    "$fin" "$fin" "${4:-3}" > "$S/state/merge-conductor/tick-p.json"
}
FRESH=600
tick() { : > "$T/calls.txt"
  ( cd "$S" && PATH="$T/fakebin:$PATH" HARNESS="$S" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
      SWEEP_PRS_FRESH_S="$FRESH" bash "$S/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) || true; }
pulls()   { grep -cE 'repos/o/r/pulls/7([^/0-9]|$)' "$T/calls.txt"; }
commits() { grep -c 'repos/o/r/pulls/7/commits' "$T/calls.txt"; }
log()     { cat "$S/logs/merge-sweep.log"; }

# ---------------------------------------------------------------------------
# 0. the lib is on the tree the lane sources it from
# ---------------------------------------------------------------------------
[ -f "$S/bin/lib/sweep-reads.sh" ] && ok || bad "0: bin/lib/sweep-reads.sh is missing — the sweep has no BH-1575 read path"

# ---------------------------------------------------------------------------
# A. a failed read names its own status
# ---------------------------------------------------------------------------
setup; echo 403 > "$T/mode"; tick
grep -qF "$PR read UNVERIFIABLE (HTTP 403)" "$S/logs/merge-sweep.log" \
  && ok || bad "A: a rate-limited PR read must log HTTP 403 — the status of THAT read, not the parent shell's last one (log: $(log))"
grep -qF "(HTTP 304)" "$S/logs/merge-sweep.log" && bad "A: a 403 was logged as a 304: $(log)" || ok
grep -qxF "$PR" "$S/state/merge-sweep-done.txt" && bad "A: an unread PR was recorded" || ok

# ---------------------------------------------------------------------------
# B. a 304 with no cache entry is re-read, never a skipped tick
# ---------------------------------------------------------------------------
setup
# Seed the ETag cache the way a previous tick would have: one plain gh_rest read
# of the same path, under the same (empty) identity label the sweep reads with.
( export HARNESS="$S"; PATH="$T/fakebin:$PATH"
  . "$S/bin/lib/gh-rest.sh"; gh_rest GET repos/o/r/pulls/7 >/dev/null ) || true
[ -n "$(find "$S/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)" ] \
  && ok || bad "B: fixture — the seed read left no ETag entry, so this section tests nothing"
echo miss > "$T/mode"; tick
grep -qF "UNVERIFIABLE" "$S/logs/merge-sweep.log" \
  && bad "B: a 304 whose cache entry was swept must be re-read without If-None-Match, not skipped (log: $(log))" || ok
grep -qF "$PR skipped: mergeState=DIRTY" "$S/logs/merge-sweep.log" \
  && ok || bad "B: the PR must be judged this tick on the re-read (log: $(log))"
[ "$(grep -F 'repos/o/r/pulls/7' "$T/calls.txt" | grep -vc If-None-Match)" -ge 1 ] \
  && ok || bad "B: no unconditional re-read was made (calls: $(cat "$T/calls.txt"))"

# ---------------------------------------------------------------------------
# C. the acceptance line: unchanged head + fresh pr-state.tsv = 0 per-PR reads
# ---------------------------------------------------------------------------
setup REBASE_CONFLICT
tick   # tick 1: no pr-state yet — reads GitHub and learns the head
[ "$(commits)" -ge 1 ] && ok || bad "C: fixture — tick 1 should read the commits once (calls: $(cat "$T/calls.txt"))"
prstate NEEDS_REBASE "$HEAD1"; tick   # tick 2: the conductor's row is fresh, the head has not moved
[ "$(pulls)" = 0 ] && ok || bad "C: a fresh NEEDS_REBASE row must cost 0 pulls/7 reads, made $(pulls) (calls: $(cat "$T/calls.txt"))"
[ "$(commits)" = 0 ] && ok || bad "C: a fresh NEEDS_REBASE row must cost 0 commits reads, made $(commits)"
grep -qE "$PR .*NEEDS_REBASE.*pr-state" "$S/logs/merge-sweep.log" \
  && ok || bad "C: the skip must say the conductor's state and where it came from (log: $(log))"
grep -qxF "$PR" "$S/state/merge-sweep-done.txt" && bad "C: a custody skip was recorded — it must be re-offered next tick" || ok
# The same without a REBASE note: the state read itself is the one avoided.
for st in REBASING QUEUED STACKED_WAIT ABANDONED; do
  setup; prstate "$st" "$HEAD1"; tick
  [ "$(pulls)" = 0 ] && ok || bad "C2: a fresh $st row must cost 0 pulls/7 reads, made $(pulls)"
done

# ---------------------------------------------------------------------------
# D. freshness is PER PROJECT (tick-<P>.json); the knob at 0 is off
# ---------------------------------------------------------------------------
# pr-state.tsv itself is fresh in every case here; only project p's tick varies.
setup; prstate NEEDS_REBASE "$HEAD1" 1200; tick
[ "$(pulls)" -ge 1 ] && ok || bad "D: project p's last conductor tick finished 20 min ago (knob $FRESH s) — its rows must not answer, made $(pulls) reads"
grep -qF "$PR skipped: mergeState=DIRTY" "$S/logs/merge-sweep.log" && ok || bad "D: the stale-project tick must judge the PR on GitHub's answer (log: $(log))"
# The #1599 review's case: this project's conductor PR LIST keeps failing (the
# tick is recorded with prs_seen=0) while other projects keep the file fresh.
setup; prstate NEEDS_REBASE "$HEAD1" 0 0; tick
[ "$(pulls)" -ge 1 ] && ok || bad "D: a project whose conductor PR list is failing (prs_seen=0) must fall back to GitHub, made $(pulls) reads"
setup; prstate NEEDS_REBASE "$HEAD1"; rm -f "$S/state/merge-conductor/tick-p.json"; tick
[ "$(pulls)" -ge 1 ] && ok || bad "D: no tick record for the project — its rows vouch for nothing, made $(pulls) reads"
setup; prstate NEEDS_REBASE "$HEAD1"; FRESH=0; tick; FRESH=600
[ "$(pulls)" -ge 1 ] && ok || bad "D: SWEEP_PRS_FRESH_S=0 must switch the pr-state read off, made $(pulls) reads"
setup; prstate NEEDS_REBASE "$HEAD1"; FRESH=""; tick; FRESH=600
[ "$(pulls)" -ge 1 ] && ok || bad "D: an unset knob must fail toward GitHub, not toward trusting a file, made $(pulls) reads"

# ---------------------------------------------------------------------------
# H. states the sweep can still merge through are read live (review of #1599)
# ---------------------------------------------------------------------------
# WAIT_CI / RED_TWICE: the conductor has no project-4 E2E discount and rewrites these
# rows every tick (tests/merge-sweep-project-4-custody.bh-1575-test.sh drives that
# end to end); WAIT_REVIEW / HEAD_MOVED: the sweep's head-bound gate fails open
# with no reviewed sha; BLOCKED_HUMAN: reasons the sweep does not share.
for st in WAIT_CI RED_TWICE WAIT_REVIEW HEAD_MOVED BLOCKED_HUMAN; do
  setup; prstate "$st" "$HEAD1"; tick
  [ "$(pulls)" -ge 1 ] && ok || bad "H: a fresh $st row must be read live, made $(pulls) reads"
done

# ---------------------------------------------------------------------------
# E. the commits read rides on the head sha
# ---------------------------------------------------------------------------
setup REBASE_CONFLICT
tick; [ "$(commits)" = 1 ] && ok || bad "E: first sight of a head must read its commits once, made $(commits)"
tick; [ "$(commits)" = 0 ] && ok || bad "E: an unchanged head must not re-read pulls/7/commits, made $(commits) (calls: $(cat "$T/calls.txt"))"
[ "$(pulls)" = 1 ] && ok || bad "E: one tick must read pulls/7 once, not once per question, made $(pulls)"
grep -qF "$PR REBASE note is stale" "$S/logs/merge-sweep.log" && ok || bad "E: the cached head date must still decide the REBASE note (log: $(log))"
echo "$HEAD2" > "$T/head"
tick; [ "$(commits)" = 1 ] && ok || bad "E: a moved head must read its commits again, made $(commits)"

# ---------------------------------------------------------------------------
# F. MERGED from the conductor is recorded; READY is still read live
# ---------------------------------------------------------------------------
setup; prstate MERGED "$HEAD1"; tick
[ "$(pulls)" = 0 ] && ok || bad "F: a fresh MERGED row must cost 0 reads, made $(pulls)"
grep -qxF "$PR" "$S/state/merge-sweep-done.txt" && ok || bad "F: a fresh MERGED row must be recorded merged (done: $(cat "$S/state/merge-sweep-done.txt"))"
setup; prstate READY "$HEAD1"; tick
[ "$(pulls)" -ge 1 ] && ok || bad "F: READY is a merge decision — it must be made on a live read, made $(pulls)"

# ---------------------------------------------------------------------------
# G. the token probe goes through gh_rest and keeps its classification
# ---------------------------------------------------------------------------
probe() { # probe <status> [body] -> the class sweep_probe_class_rest prints
  printf '%s' "$1" > "$T/pst"; printf '%s' "${2:-"{}"}" > "$T/pbody"
  ( export HARNESS="$S"; PATH="$T/pbin:$T/fakebin:$PATH"; GH_ETAG=0
    . "$S/bin/lib/merge-conductor-lib.sh"; . "$S/bin/lib/sweep-reads.sh" 2>/dev/null
    sweep_probe_class_rest o/r tok ) 2>/dev/null; }
mkdir -p "$T/pbin"; : > "$T/pcalls.txt"
cat > "$T/pbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/pcalls.txt"
restpr --raw "\$(cat "$T/pst")" "\$(cat "$T/pbody")"
EOF
chmod +x "$T/pbin/gh"
[ "$(probe 200 '{"id":1}')" = ok ]        && ok || bad "G: 200 must be ok, got '$(probe 200 '{"id":1}')'"
[ "$(probe 404)" = invisible ]            && ok || bad "G: 404 must be invisible, got '$(probe 404)'"
[ "$(probe 401)" = invisible ]            && ok || bad "G: 401 must be invisible, got '$(probe 401)'"
[ "$(probe 403 '{"message":"You have exceeded a secondary rate limit"}')" = transient ] \
                                          && ok || bad "G: a secondary-rate-limit 403 must be transient"
[ "$(probe 403 '{"message":"Resource not accessible by integration"}')" = invisible ] \
                                          && ok || bad "G: a permission 403 must be invisible"
[ "$(probe 429)" = transient ]            && ok || bad "G: 429 must be transient"
[ "$(probe 502)" = transient ]            && ok || bad "G: 5xx must be transient"
grep -qE '^api -i -X GET repos/o/r$' "$T/pcalls.txt" && ok || bad "G: the probe must be a gh_rest GET (calls: $(cat "$T/pcalls.txt"))"

echo "merge-sweep-reads: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
