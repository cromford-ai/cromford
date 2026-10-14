#!/bin/bash
# tests/merge-sweep-db-first.bh-2312-test.sh — bin/merge-sweep.sh enumerates the
# builds of record from the jobs ledger first (BH-2348, slice 2 of BH-2312).
#
# WHAT THIS SUITE PINS (the ticket's acceptance list):
#   A1  a ledger row is walked in LEDGER-time order, even when its local RESULT
#       is older than a sibling's; projects still interleave round-robin (BH-710)
#   A2  a ledger-only record (no local dir) is NEVER merged: one held line per
#       tick, db-only=<n> on the tick TOTAL line, no gh call for its PR — even
#       when the ledger's own verdict is a settled APPROVE
#   A3  the ledger's result line wins over an OLDER `head -1 RESULT`; a local
#       RESULT rewritten AFTER the ledger row (pr-url-reconcile's RECONCILED
#       relink, fly-pool's RESULT_UNVERIFIED relabel) wins over the ledger (BH-848)
#   A4  provisional verdict, RESULT_UNVERIFIED PR_CREATED and PR_CREATE_FAILED
#       as the ledger line: no merge
#   A5  a feed outage (rc 1) walks in exactly the order a lib-less tree does
#   A6  a truncated feed (BOR_LIMIT) still walks every local record, and says so
#   A7  the tick deadline still bounds the walk; one bor_union (= the lib's two
#       feed calls) per project
#   A9  a ledger row with a blank field (tab collapse shifts its columns) is
#       dropped with a log line and walked from its local RESULT instead
#
# HOW IT DRIVES. The production script, copied into a scratch tree as
# $T/bin/sweep.sh (bin/iron-law-guard.sh denies a session that invokes
# merge-sweep.sh by name), next to the REAL bin/lib/builds-of-record.sh, with gh,
# the jobs client and fleet-conf.sh stubbed. The gh stub is the one
# tests/merge-sweep-order-cache-test.sh uses: the REST state read of a PR is
# what marks it VISITED, and `gh pr merge` is the merge verb's sink.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-sweep-db-first.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

mkdir -p "$T/bin" "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/builds" "$T/fakebin" "$T/feed"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/lib/builds-of-record.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

cat > "$T/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --projects) printf 'pa\npb\n' ;;
  *) case "${2:-}" in
       repo)         echo "o/${1}" ;;
       board_prefix) echo "-" ;;
     esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/fleet-conf.sh"

# The jobs client. job_artifact_feed answers from $T/feed/<kind>-<project>.tsv
# (TSV: job_id, ref, box, ticket_id, updated_at, detail — the real shape),
# honours its limit like the worker's route does, and is rc 1 while
# $T/feed-down exists. Every feed call is counted in feed-calls.txt.
cat > "$T/bin/jobs-client.sh" <<EOF
WORKER_SINK="$T/worker-calls.txt"
VERDICT_SINK="$T/verdict-calls.txt"
VERDICTS="$T/verdicts.txt"
job_artifact_feed() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/feed-calls.txt"
  [ -f "$T/feed-down" ] && return 1
  [ -f "$T/feed/\$1-\$2.tsv" ] && head -n "\${4:-100}" "$T/feed/\$1-\$2.tsv"
  return 0
}
job_ledger_get() { printf 'ledger_get %s\n' "\$*" >> "\$WORKER_SINK"; return 2; }
job_ledger_put() { printf 'ledger_put %s\n' "\$*" >> "\$WORKER_SINK"; return 0; }
job_verdict() {
  printf '%s\n' "\$1" >> "\$VERDICT_SINK"
  local row; row=\$(awk -v p="\$1" '\$1==p {print; exit}' "\$VERDICTS" 2>/dev/null)
  [ -n "\$row" ] || return 2
  # shellcheck disable=SC2086
  set -- \$row
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "\$2" "\$3" "\$4" "\$5" "\$6" "\$7"
}
job_lane_open() { JOB_ID=job-1; return 0; }
job_lane_close() { return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
EOF

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
PRURL=\$(printf '%s\n' "\$*" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1)
case "\$*" in
  "api repos/"*" -q .id") echo 1 ;;
  # The PR state read, over REST since BH-597. Same fixture table, same
  # visit-order recording: this call is what marks a record VISITED now.
  "api repos/"*"/pulls/"[0-9]*)
    RP=\$(printf '%s\n' "\$*" | grep -oE 'repos/[^/]+/[^/]+/pulls/[0-9]+' | head -1)
    RS=\${RP#repos/}; RS=\${RS%%/pulls/*}; RN=\${RP##*/}
    PRURL="https://github.com/\$RS/pull/\$RN"
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5, \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha OPEN"
    set -- \$ST
    RSTATE=\$1; RMERGE=\$2; RAUTH=\$3; RHEAD=\$4; RPOST=\${5:-OPEN}
    # column 6 is what the POST-MERGE re-read must answer; the PR itself is
    # still open at this point unless the fixture says it closed.
    if [ "\$RSTATE" = MERGED ] || { [ -f "$T/merge-calls.txt" ] && grep -qF "\$PRURL" "$T/merge-calls.txt" 2>/dev/null && [ "\$RPOST" = MERGED ]; }; then
      printf '{"number":%s,"html_url":"%s","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"%s","draft":false,"head":{"sha":"%s","ref":"ticket/x-1"},"base":{"ref":"main"},"user":{"login":"%s","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}\n' \
        "\$RN" "\$PRURL" "\$(printf '%s' "\$RMERGE" | tr 'A-Z' 'a-z')" "\$RHEAD" "\$RAUTH"
    else
      printf '{"number":%s,"html_url":"%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"%s","draft":false,"head":{"sha":"%s","ref":"ticket/x-1"},"base":{"ref":"main"},"user":{"login":"%s","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
        "\$RN" "\$PRURL" "\$(printf '%s' "\$RMERGE" | tr 'A-Z' 'a-z')" "\$RHEAD" "\$RAUTH"
    fi ;;
  *"--json state,mergeStateStatus,author,headRefOid,closedAt"*)
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha"
    printf '%s \n' "\$ST" ;;
  *"--json state -q .state"*)
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN"
    printf '%s\n' "\$ST" ;;
  *"--json headRefOid"*) echo "headsha" ;;
  *"--json mergeCommit"*) echo "deadbeefcafe" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt" ;;
  # THE DECISION READS ARE REST (BH-784): every \`gh pr view --json …\` became
  # \`gh api -i -X GET repos/<slug>/pulls/<n>\`, judged on the HTTP status line, so
  # restpr prints a whole HTTP response. The diff shares that path and is told
  # apart by its Accept header, so it is matched FIRST.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    # The fixture table is still keyed on the PR url, so rebuild the url from the
    # REST path. This GET is what marks a record VISITED, exactly as the old
    # state read did.
    SN=\$(printf '%s\n' "\$*" | grep -oE 'repos/[^ ]+/pulls/[0-9]+' | head -1)
    SN=\${SN#repos/}; NUM=\${SN##*/}; SLUG=\${SN%/pulls/*}
    PRURL="https://github.com/\$SLUG/pull/\$NUM"
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5, \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha OPEN"
    # shellcheck disable=SC2086
    set -- \$ST   # state mstate author headsha post-merge-state
    # After the merge verb the same GET is the post-merge state read the old
    # \`--json state -q .state\` arm answered, so column 6 speaks once this PR is
    # in merge-calls.txt — with the merge sha the old --json mergeCommit arm gave.
    if grep -qF "\$PRURL" "$T/merge-calls.txt" 2>/dev/null; then
      restpr "\$5" "\$4" ticket/x main "" MERGEABLE "\$2" "\$3" deadbeefcafe
    else
      restpr "\$1" "\$4" ticket/x main "" MERGEABLE "\$2" "\$3"
    fi ;;
  # The issue close-out is a comment POST, a close PATCH and the re-read
  # gh_rest_close does before it reports the close landed — the same sink the
  # old \`issue comment\`/\`issue close\` arms wrote to.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*|*"api -i -X PATCH repos/"*"/issues/"*|*"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# ── fixture helpers ─────────────────────────────────────────────────────────
reset_tree() {
  rm -rf "$T/builds" "$T/feed"; mkdir -p "$T/builds" "$T/feed"
  rm -f "$T/feed-down"
  for f in state/merge-sweep-done.txt state/merge-sweep-terminal.txt \
           state/headbound-alerted.txt logs/merge-sweep.log logs/ALERTS.log; do
    : > "$T/$f"
  done
  for f in gh-calls.txt visit-order.txt merge-calls.txt worker-calls.txt \
           verdict-calls.txt issue-calls.txt feed-calls.txt pr-state.txt verdicts.txt; do
    : > "$T/$f"
  done
}
mkrec() { # mkrec <dir> <pr-url> <verdict> <result-mtime> — a local build record
  local d="$T/builds/$1"
  mkdir -p "$d"
  echo "PR_CREATED $2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: %s\n' "$3" > "$d/review.md"
  : > "$d/pipeline.log"
  touch -d "@$4" "$d/RESULT"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ledger() { # ledger <project> <job> <build_dir> <key> <epoch> <result line> [pr url]
  printf '%s\t%s\thub\t-\t%s\t{"build_dir":"%s","key":"%s"}\n' "$2" "$6" "$(iso "$5")" "$3" "$4" >> "$T/feed/result-$1.tsv"
  [ -n "${7:-}" ] && printf '%s\t%s\thub\t-\t%s\t-\n' "$2" "$7" "$(iso "$5")" >> "$T/feed/pr_url-$1.tsv"
  return 0
}
run_sweep() { # run_sweep [VAR=VAL ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" env SWEEP_MERGE_SETTLE=0 "$@" \
      bash "$T/bin/sweep.sh" >/dev/null 2>>"$T/sweep.err" ) \
    || { echo "sweep rc=$? — stderr:"; tail -5 "$T/sweep.err"; }
}
order() { tr '\n' ' ' < "$T/visit-order.txt"; }
U=https://github.com/o

# Four local records. pa-X-1's RESULT is OLDER than pa-X-2's on disk, but the
# ledger recorded pa-X-1 LATER — the ledger's time is the one that counts.
four_records() {
  mkrec pa-X-1-r "$U/pa/pull/1" APPROVE "$((NOW - 500))"
  mkrec pa-X-2-r "$U/pa/pull/2" APPROVE "$((NOW - 100))"
  mkrec pb-X-3-r "$U/pb/pull/3" APPROVE "$((NOW - 300))"
  mkrec pb-X-4-r "$U/pb/pull/4" APPROVE "$((NOW - 200))"
}

# ============================================================================
echo "--- A1: ledger-time order, round-robin across projects"
reset_tree; four_records
ledger pa J1 pa-X-1-r X-1 "$((NOW - 10))"  "PR_CREATED $U/pa/pull/1" "$U/pa/pull/1"
ledger pa J2 pa-X-2-r X-2 "$((NOW - 400))" "PR_CREATED $U/pa/pull/2" "$U/pa/pull/2"
run_sweep
A1_WANT="$U/pa/pull/1 $U/pb/pull/4 $U/pa/pull/2 $U/pb/pull/3 "
[ "$(order)" = "$A1_WANT" ] && ok \
  || bad "A1: want ledger order '$A1_WANT', got '$(order)'"
[ "$(grep -c . "$T/feed-calls.txt")" = 4 ] && ok \
  || bad "A1: two feed calls (one bor_union) per project expected: $(tr '\n' ',' < "$T/feed-calls.txt")"

# ============================================================================
echo "--- A5: an outage walks exactly today's find order"
touch "$T/feed-down"; : > "$T/visit-order.txt"
run_sweep
A5_DOWN=$(order)
A5_WANT="$U/pa/pull/2 $U/pb/pull/4 $U/pa/pull/1 $U/pb/pull/3 "
[ "$A5_DOWN" = "$A5_WANT" ] && ok || bad "A5: outage order must be the mtime order '$A5_WANT', got '$A5_DOWN'"
mv "$T/bin/lib/builds-of-record.sh" "$T/bor.bak"; : > "$T/visit-order.txt"; : > "$T/feed-calls.txt"
run_sweep
mv "$T/bor.bak" "$T/bin/lib/builds-of-record.sh"
[ "$(order)" = "$A5_DOWN" ] && ok || bad "A5: lib-less order '$(order)' differs from outage order '$A5_DOWN'"
[ -s "$T/feed-calls.txt" ] && bad "A5: a lib-less tree must not call the feed" || ok

# ============================================================================
echo "--- A2: a ledger-only record is held, counted, never merged"
reset_tree
ledger pa J9 pa-X-9-r X-9 "$((NOW - 5))" "PR_CREATED https://github.com/o/r/pull/99" "https://github.com/o/r/pull/99"
run_sweep
HELD="[merge-sweep] db-only record X-9 https://github.com/o/r/pull/99 held: no local evidence (review.md/migration-gate)"
[ "$(grep -cF "$HELD" "$T/logs/merge-sweep.log")" = 1 ] && ok \
  || bad "A2: exactly one held line expected — log: $(cat "$T/logs/merge-sweep.log")"
grep -qE 'tick TOTAL: .* db-only=1' "$T/logs/merge-sweep.log" && ok \
  || bad "A2: the tick TOTAL line must carry db-only=1 — log: $(cat "$T/logs/merge-sweep.log")"
grep -qE 'tick TOTAL:.*https://' "$T/logs/merge-sweep.log" && bad "A2: the TOTAL line must carry no PR URL" || ok
grep -q 'pull/99' "$T/gh-calls.txt" && bad "A2: no gh call may be made for a ledger-only PR: $(cat "$T/gh-calls.txt")" || ok
[ -s "$T/merge-calls.txt" ] && bad "A2: no merge verb for a ledger-only record: $(cat "$T/merge-calls.txt")" || ok
a2_untouched() { # the hold comes BEFORE every read, cache write, tally and done-mark
  grep -qxF "https://github.com/o/r/pull/99" "$T/state/merge-sweep-done.txt" && bad "$1: a held record must not be marked done" || ok
  grep -q 'pull/99' "$T/verdict-calls.txt" && bad "$1: a held record must not reach the verdict read" || ok
  grep -q 'pull/99' "$T/state/merge-sweep-terminal.txt" && bad "$1: a held record must not be cached as terminal" || ok
  grep -q 'pull/99 parked' "$T/logs/merge-sweep.log" && bad "$1: a held record must not be parked" || ok
  grep -qE 'tick TOTAL: projects=0 seen=0 .* db-only=1' "$T/logs/merge-sweep.log" && ok \
    || bad "$1: a held record is neither a project tally nor seen — $(grep 'tick TOTAL' "$T/logs/merge-sweep.log")"
}
a2_untouched A2

echo "--- A2 (variant): the ledger's own settled APPROVE is not enough"
echo "https://github.com/o/r/pull/99 APPROVE 2 claude sha job-9 sha" > "$T/verdicts.txt"
echo "https://github.com/o/r/pull/99 OPEN CLEAN operator sha MERGED" > "$T/pr-state.txt"
run_sweep
[ "$(grep -cF "$HELD" "$T/logs/merge-sweep.log")" = 2 ] && ok \
  || bad "A2v: the held line must repeat once on the next tick — log: $(cat "$T/logs/merge-sweep.log")"
[ -s "$T/merge-calls.txt" ] && bad "A2v: a settled ledger APPROVE must not merge a ledger-only record" || ok
grep -q 'pull/99' "$T/gh-calls.txt" && bad "A2v: no gh call for the ledger-only PR" || ok
a2_untouched A2v

# ============================================================================
echo "--- A3: the ledger's result line wins over head -1 RESULT"
reset_tree
mkrec pa-X-5-r "$U/pa/pull/10" APPROVE "$((NOW - 100))"
ledger pa J5 pa-X-5-r X-5 "$((NOW - 50))" "PR_CREATED $U/pa/pull/11" "$U/pa/pull/11"
run_sweep
grep -qxF "$U/pa/pull/11" "$T/visit-order.txt" && ok || bad "A3: the ledger's pull/11 must be the PR evaluated: $(order)"
grep -q 'pa/pull/10' "$T/gh-calls.txt" && bad "A3: the RESULT file's pull/10 must not be evaluated" || ok

echo "--- A3b: a local RECONCILED relink newer than the ledger's PR_CREATE_FAILED is evaluated"
reset_tree
mkrec pa-X-14-r "$U/pa/pull/14" APPROVE "$((NOW - 100))"
ledger pa J14 pa-X-14-r X-14 "$((NOW - 200))" "PR_CREATE_FAILED: gh 502 on create"
printf 'PR_CREATED %s | RECONCILED 2026-09-25T00:00:00Z by pr-url-reconcile: the create had failed on the builder\nRECONCILED_FROM: PR_CREATE_FAILED: gh 502 on create\n' \
  "$U/pa/pull/14" > "$T/builds/pa-X-14-r/RESULT"
touch -d "@$((NOW - 100))" "$T/builds/pa-X-14-r/RESULT"
run_sweep
grep -qxF "$U/pa/pull/14" "$T/visit-order.txt" && ok \
  || bad "A3b: a reconciled record the ledger still calls PR_CREATE_FAILED must be evaluated (BH-848): $(order)"

echo "--- A3c: a local RESULT_UNVERIFIED relabel newer than the ledger's PR_CREATED does not reach gh"
reset_tree
mkrec pa-X-15-r "$U/pa/pull/15" APPROVE "$((NOW - 100))"
ledger pa J15 pa-X-15-r X-15 "$((NOW - 200))" "PR_CREATED $U/pa/pull/15" "$U/pa/pull/15"
echo "RESULT_UNVERIFIED PR_CREATED $U/pa/pull/15" > "$T/builds/pa-X-15-r/RESULT"
touch -d "@$((NOW - 100))" "$T/builds/pa-X-15-r/RESULT"
echo "$U/pa/pull/15 OPEN CLEAN operator sha MERGED" > "$T/pr-state.txt"
run_sweep
grep -q 'pa/pull/15' "$T/gh-calls.txt" && bad "A3c: a relabelled RESULT_UNVERIFIED must not reach gh: $(grep 'pa/pull/15' "$T/gh-calls.txt" | head -2)" || ok
[ -s "$T/merge-calls.txt" ] && bad "A3c: no merge verb expected: $(cat "$T/merge-calls.txt")" || ok

# ============================================================================
echo "--- A4a: provisional verdict + no APPROVE on the record: no merge"
reset_tree
mkrec pa-X-6-r "$U/pa/pull/6" BLOCK "$((NOW - 100))"
ledger pa J6 pa-X-6-r X-6 "$((NOW - 50))" "PR_CREATED $U/pa/pull/6" "$U/pa/pull/6"
echo "$U/pa/pull/6 OPEN CLEAN operator sha MERGED" > "$T/pr-state.txt"
run_sweep
grep -qxF "$U/pa/pull/6" "$T/verdict-calls.txt" && ok || bad "A4a: the record must reach the verdict read"
[ -s "$T/merge-calls.txt" ] && bad "A4a: provisional verdict must not merge: $(cat "$T/merge-calls.txt")" || ok

echo "--- A4b/A4c: RESULT_UNVERIFIED and PR_CREATE_FAILED as the ledger line"
reset_tree
mkrec pa-X-7-r "$U/pa/pull/12" APPROVE "$((NOW - 100))"
mkrec pb-X-8-r "$U/pb/pull/13" APPROVE "$((NOW - 100))"
ledger pa J7 pa-X-7-r X-7 "$((NOW - 50))" "RESULT_UNVERIFIED PR_CREATED $U/pa/pull/12"
ledger pb J8 pb-X-8-r X-8 "$((NOW - 50))" "PR_CREATE_FAILED: boom"
ledger pa J70 pa-X-70-r X-70 "$((NOW - 40))" "RESULT_UNVERIFIED PR_CREATED $U/pa/pull/70"
printf '%s OPEN CLEAN operator sha MERGED\n' "$U/pa/pull/12" "$U/pb/pull/13" "$U/pa/pull/70" > "$T/pr-state.txt"
run_sweep
for pr in pa/pull/12 pb/pull/13 pa/pull/70; do
  grep -q "$pr" "$T/gh-calls.txt" && bad "A4b/c: $pr must not reach gh: $(grep "$pr" "$T/gh-calls.txt" | head -2)" || ok
done
[ -s "$T/merge-calls.txt" ] && bad "A4b/c: no merge verb expected: $(cat "$T/merge-calls.txt")" || ok
grep -q 'db-only record' "$T/logs/merge-sweep.log" && bad "A4b: a non-PR_CREATED ledger-only line is not a PR record and is not counted as db-only" || ok

# ============================================================================
echo "--- A6: a truncated feed still walks every local record"
reset_tree; four_records
mkrec pa-X-20-r "$U/pa/pull/20" APPROVE "$((NOW - 700))"
ledger pa J1 pa-X-1-r X-1 "$((NOW - 10))"  "PR_CREATED $U/pa/pull/1" "$U/pa/pull/1"
ledger pa J2 pa-X-2-r X-2 "$((NOW - 400))" "PR_CREATED $U/pa/pull/2" "$U/pa/pull/2"
run_sweep BOR_LIMIT=1
for pr in pa/pull/1 pa/pull/2 pa/pull/20 pb/pull/3 pb/pull/4; do
  grep -qxF "$U/$pr" "$T/visit-order.txt" && ok || bad "A6: $pr must still be walked under BOR_LIMIT=1: $(order)"
done
[ "$(sort "$T/visit-order.txt" | uniq -d | grep -c .)" = 0 ] && ok || bad "A6: a record was walked twice: $(order)"
grep -q '\[merge-sweep\] pa: ledger feed hit BOR_LIMIT' "$T/logs/merge-sweep.log" && ok \
  || bad "A6: the truncation must be logged — log: $(cat "$T/logs/merge-sweep.log")"

# ============================================================================
echo "--- A8: pool-/fly- copies and non-project dirs are walked once each"
reset_tree
mkrec fly-pa-X-30-r "$U/pa/pull/30" APPROVE "$((NOW - 100))"
mkrec pool-pb-X-31-r "$U/pb/pull/31" APPROVE "$((NOW - 100))"
mkrec zz-X-32-r "$U/zz/pull/32" APPROVE "$((NOW - 100))"
ledger pa J30 pa-X-30-r X-30 "$((NOW - 50))" "PR_CREATED $U/pa/pull/30" "$U/pa/pull/30"
run_sweep
for pr in pa/pull/30 pb/pull/31 zz/pull/32; do
  [ "$(grep -cxF "$U/$pr" "$T/visit-order.txt")" = 1 ] && ok || bad "A8: $pr must be walked exactly once: $(order)"
done
grep -q 'db-only record' "$T/logs/merge-sweep.log" && bad "A8: a fly- copy is local evidence, not db-only" || ok

# ============================================================================
echo "--- A9: a ledger row with a blank box is dropped, not walked shifted"
reset_tree
mkrec pa-X-40-r "$U/pa/pull/40" APPROVE "$((NOW - 100))"
printf '%s\t%s\t\t-\t%s\t{"build_dir":"%s","key":"%s"}\n' J40 "PR_CREATED $U/pa/pull/40" "$(iso "$((NOW - 50))")" pa-X-40-r X-40 >> "$T/feed/result-pa.tsv"
run_sweep
[ "$(grep -cxF "$U/pa/pull/40" "$T/visit-order.txt")" = 1 ] && ok \
  || bad "A9: pull/40 must be walked exactly once, from its local RESULT: $(order)"
grep -q '\[merge-sweep\] pa: ledger row for pa-X-40-r has no updated_at' "$T/logs/merge-sweep.log" && ok \
  || bad "A9: the dropped row must be logged — log: $(cat "$T/logs/merge-sweep.log")"

# ============================================================================
echo "--- A7: the tick deadline still bounds the walk"
reset_tree; four_records
ledger pa J9 pa-X-9-r X-9 "$((NOW - 5))" "PR_CREATED https://github.com/o/r/pull/99" "https://github.com/o/r/pull/99"
run_sweep SWEEP_DEADLINE_SECS=0
grep -q 'tick deadline 0s reached' "$T/logs/merge-sweep.log" && ok || bad "A7: the deadline line is missing: $(cat "$T/logs/merge-sweep.log")"
[ -s "$T/gh-calls.txt" ] && bad "A7: no gh call after the deadline: $(head -3 "$T/gh-calls.txt")" || ok
UNSEEN=$(grep -o 'unseen=[0-9]*' "$T/logs/merge-sweep.log" | tail -1 | cut -d= -f2)
[ -n "$UNSEEN" ] && [ "$UNSEEN" -ge 1 ] && ok || bad "A7: unseen must be >= 1, got '$UNSEEN'"
[ "$(grep -c . "$T/feed-calls.txt")" = 4 ] && ok \
  || bad "A7: exactly 2 feed calls per project, got $(tr '\n' ',' < "$T/feed-calls.txt")"

echo "merge-sweep-db-first.bh-2312-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
