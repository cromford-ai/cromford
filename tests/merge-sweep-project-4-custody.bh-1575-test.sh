#!/bin/bash
# tests/merge-sweep-project-4-custody.bh-1575-test.sh — BH-1575, the #1599 review's
# BLOCKING 1, reproduced end to end against the real bin/merge-sweep.sh.
#
# THE SHAPE. merge-sweep merges a project-4 PR that is UNSTABLE only because its
# E2E is red (Typecheck, Unit tests and Guard green: the "project-4 discount"). The
# merge conductor has no such discount — mc_discount exempts project-4 on purpose —
# so it holds the same PR in WAIT_CI, then RED_TWICE, and rewrites that row on
# every */5 tick. project-4 has no merge queue, so the sweep is its only merger.
# If a fresh WAIT_CI / RED_TWICE row made the sweep skip the PR, neither lane
# would ever merge it. Those rows must be read live and the discount must apply.
# (Reviewer's repro, folded in; the row helper also writes the conductor's
# per-project tick record, which is what vouches for the row's freshness.)
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

S="$T/s"; PR=https://github.com/example-org/project-4/pull/7; REC="$S/builds/pool-p-XX-7-202609150001"
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
printf 'p example-org/project-4 - - 3 box-p\n' > "$S/fleet.conf"
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
  jq -nc --arg h "\$(cat "$T/head")" '{state:"open",merged_at:null,closed_at:null,head:{sha:\$h,ref:"ticket/x"},base:{ref:"main"},labels:[],mergeable:true,mergeable_state:"unstable",user:{login:"operator",type:"User"},merge_commit_sha:null,draft:false}'; }
case "\$*" in
  "api repos/example-org/project-4 -q .id") echo 1 ;;
  "api -i -X GET repos/example-org/project-4") restpr --raw 200 '{"id":1}' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"actions/runs"*)
    case "\$*" in
      *"-i -X GET"*) restpr --raw 200 '{"workflow_runs":[{"name":"Typecheck","conclusion":"success"},{"name":"Unit tests","conclusion":"success"},{"name":"Guard","conclusion":"success"},{"name":"E2E","conclusion":"failure"}]}' ;;
      *) printf '%s\n' "Typecheck|success" "Unit tests|success" "Guard|success" "E2E|failure" ;;
    esac ;;
  *"repos/example-org/project-4/pulls/7/commits"*)
    restpr --raw 200 "[{\"sha\":\"\$(cat "$T/head")\",\"commit\":{\"committer\":{\"date\":\"2026-09-22T10:00:00Z\"}}}]" ;;
  *"repos/example-org/project-4/pulls/7"*)
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

# setup <result-extra> — one APPROVEd pool record for example-org/project-4#7, a clean slate of
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
  rm -f "$S/state/merge-sweep-terminal.txt" "$S/state/merge-sweep-heads.tsv" "$S/state/merge-conductor/pr-state.tsv"
  scratch_rm "$S/state/gh-etag"
  echo dirty > "$T/mode"; echo "$HEAD1" > "$T/head"; : > "$T/calls.txt"
}
# prstate <state> <head> [age-seconds] — one conductor row for example-org/project-4#7.
prstate() {
  printf 'example-org/project-4#7\t%s\t%s\t%s\t%s\t-\treason\t%s\n' "$1" "$(date +%s)" "$2" "$2" "$PR" \
    > "$S/state/merge-conductor/pr-state.tsv"
  # The conductor's tick record for project p: fresh, and it saw PRs.
  printf '{"tick":"t","project":"p","started_at":%s,"finished_at":%s,"prs_seen":3}\n' \
    "$(date +%s)" "$(date +%s)" > "$S/state/merge-conductor/tick-p.json"
}
FRESH=600
tick() { : > "$T/calls.txt"
  ( cd "$S" && PATH="$T/fakebin:$PATH" HARNESS="$S" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
      SWEEP_PRS_FRESH_S="$FRESH" bash "$S/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) || true; }
pulls()   { grep -cE 'repos/example-org/project-4/pulls/7([^/0-9]|$)' "$T/calls.txt"; }
commits() { grep -c 'repos/example-org/project-4/pulls/7/commits' "$T/calls.txt"; }
log()     { cat "$S/logs/merge-sweep.log"; }


# R2. project-4 PR, UNSTABLE with only E2E red: the sweep's project-4 discount merges it.
setup; tick
grep -qF "project-4 discount applies" "$S/logs/merge-sweep.log" && ok || bad "R2 control: no row — the project-4 discount must apply (log: $(log))"
setup; prstate WAIT_CI "$HEAD1"; tick
grep -qF "project-4 discount applies" "$S/logs/merge-sweep.log" && ok || bad "R2: a fresh conductor WAIT_CI row (the conductor has no project-4 E2E discount: UNSTABLE -> WAIT_CI) suppresses the sweep's project-4 discount (log: $(log))"
setup; prstate RED_TWICE "$HEAD1"; tick
grep -qF "project-4 discount applies" "$S/logs/merge-sweep.log" && ok || bad "R2: a fresh RED_TWICE row (E2E red twice) suppresses the project-4 discount (log: $(log))"
echo "repro-ms-project-4: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
