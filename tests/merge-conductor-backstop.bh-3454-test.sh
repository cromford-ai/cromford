#!/bin/bash
# tests/merge-conductor-backstop.bh-3454-test.sh — BH-3436.2 (BH-3454): the */5
# keyed backstop reads state/merge-conductor/pr-state.tsv only, picks WAIT_CI /
# READY rows approved on their head, oldest first up to MC_BACKSTOP_MAX_KEYS,
# and hands them to ONE keyed conductor run. B1 drives the REAL backstop into
# the REAL bin/merge-conductor.sh (gh/REST stubbed as in
# tests/tier2-autoenqueue-test.sh AT-13); B2-B5 put a recorder in the
# conductor's place. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
SLUG=example-org/mgfy-os
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"

# ============================================================================
# B2-B5: the backstop against a RECORDER conductor.
# ============================================================================
R="$T/r"; mkdir -p "$R/bin/lib" "$R/logs" "$R/state/merge-conductor" "$R/flags" "$R/env" "$T/rbin"
cp "$DIR/bin/merge-conductor-backstop.sh" "$R/bin/"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$R/bin/lib/" 2>/dev/null
: > "$R/env/global.env"
cat > "$R/bin/merge-conductor.sh" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\${MC_ONLY_PR:-<unset>}" "\${WAKE_LAUNCH:-<unset>}" >> "$T/rec.txt"
EOF
chmod +x "$R/bin/merge-conductor.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/r-gh.txt"; exit 1\n' "$T" > "$T/rbin/gh"; chmod +x "$T/rbin/gh"
row() { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$1" "$2" "$3" "$4" "$5" "$U" "${1##*#}"; }
# TEST-CHANGE (BH-6000): the backstop now starts one DETACHED run per
# candidate and returns at once, so bs waits (bounded) for the recorder runs to
# land before the assertions read rec.txt. Nothing asserted below is weaker.
# TEST-CHANGE (BH-7376): the backstop now starts at most MC_BACKSTOP_MAX_RUNNING
# (default 6) runs at once. This suite pins BH-6000's one run per candidate in
# one fire, so it sets the cap to 0 (none); tests/merge-conductor-keyed-timeout-test.sh
# K13 pins the cap itself.
bs() { : > "$T/rec.txt"; : > "$T/r-gh.txt"; ( cd "$T" && env PATH="$T/rbin:$PATH" HARNESS="$R" MC_BACKSTOP_MAX_RUNNING=0 "$@" \
  bash "$R/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 ); echo $? > "$T/bs.rc"
  local want n=0; want=$(sed -n 's/.*: \([0-9]*\) detached keyed conductor run(s) started.*/\1/p' "$T/bs.out" | tail -1)
  while [ "$(grep -c . "$T/rec.txt" 2>/dev/null || echo 0)" -lt "${want:-0}" ] && [ "$n" -lt 40 ]; do sleep 0.25; n=$((n + 1)); done; }
nrec() { grep -c . "$T/rec.txt" 2>/dev/null || true; }
keys() { cut -f1 "$T/rec.txt" | head -1; }

# B2: no candidates — no conductor, no gh.
: > "$R/state/merge-conductor/pr-state.tsv"; bs
[ "$(cat "$T/bs.rc")" = 0 ] && ok || bad "B2 exit 0 with no candidates (rc $(cat "$T/bs.rc"))"
[ "$(nrec)" = 0 ] && ok || bad "B2 the conductor ran with no candidates ($(cat "$T/rec.txt"))"
[ ! -s "$T/r-gh.txt" ] && ok || bad "B2 a gh call with no candidates ($(cat "$T/r-gh.txt"))"
grep -q '0 candidates' "$T/bs.out" && ok || bad "B2 one '0 candidates' line (got: $(cat "$T/bs.out"))"
rm -f "$R/state/merge-conductor/pr-state.tsv"; bs
[ "$(nrec)" = 0 ] && ok || bad "B2 an absent pr-state.tsv runs nothing"

# B3: only WAIT_CI/READY with reviewed == head are keys.
{ row "$SLUG#1" WAIT_CI $((NOW-50)) "$H1" "$H2"
  row "$SLUG#2" READY   $((NOW-40)) "$H1" -
  row "$SLUG#3" BLOCKED_HUMAN $((NOW-30)) "$H1" "$H1"
  row "$SLUG#4" QUEUED  $((NOW-20)) "$H1" "$H1"
  row "$SLUG#5" STACKED_WAIT $((NOW-10)) "$H1" "$H1"
  row "$SLUG#6" MERGED  $((NOW-5)) "$H1" "$H1"
  row "$SLUG#7" WAIT_CI $((NOW-5)) - - ; } > "$R/state/merge-conductor/pr-state.tsv"
bs
[ "$(nrec)" = 0 ] && ok || bad "B3 no row qualifies, so no conductor run (got: $(cat "$T/rec.txt"))"
# Control: the same file plus one qualifying row runs exactly that key.
row "$SLUG#8" READY $((NOW-60)) "$H2" "$H2" >> "$R/state/merge-conductor/pr-state.tsv"; bs
[ "$(keys)" = "$SLUG#8" ] && ok || bad "B3 control: only $SLUG#8 is keyed (got: $(keys))"
[ "$(cut -f2 "$T/rec.txt")" = 1 ] && ok || bad "B3 the keyed run carries WAKE_LAUNCH=1"

# B4: 25 candidates. TEST-CHANGE (BH-6000): this case pinned ONE run taking the
# 20 oldest keys (cap MC_BACKSTOP_MAX_KEYS) and deferring 5, and a default cap
# of 6. The batching is what starved PRs: now every candidate gets its own run
# in the same fire, the cap is a deprecated no-op, and nothing is deferred.
: > "$R/state/merge-conductor/pr-state.tsv"
for i in $(seq 1 25); do row "$SLUG#$((100+i))" WAIT_CI $((NOW-i*60)) "$H1" "$H1" >> "$R/state/merge-conductor/pr-state.tsv"; done
bs MC_BACKSTOP_MAX_KEYS=20
WANT=$(for i in $(seq 1 25); do printf '%s#%s\n' "$SLUG" $((100+i)); done | sort | paste -sd, -)
[ "$(cut -f1 "$T/rec.txt" | sort | paste -sd, -)" = "$WANT" ] && ok || bad "B4 every one of the 25 candidates gets its own run (got: $(cut -f1 "$T/rec.txt" | sort | paste -sd, -))"
grep -q ',' <<<"$(cut -f1 "$T/rec.txt")" && bad "B4 a run keyed to more than one PR" || ok
grep -qi 'deferred' "$T/bs.out" && bad "B4 nothing is deferred (got: $(cat "$T/bs.out"))" || ok
bs; [ "$(nrec)" = 25 ] && ok || bad "B4 the default (deprecated) cap caps nothing (runs: $(nrec))"
bs MC_BACKSTOP_MAX_KEYS=0; [ "$(nrec)" = 25 ] && ok || bad "B4 cap 0: every candidate runs (runs: $(nrec))"

# B5: the lane's own switch, and the conductor's two, stand it down.
for f in lane-off-merge-conductor-backstop automerge-disabled lane-off-merge-conductor; do
  touch "$R/flags/$f"; bs
  [ "$(cat "$T/bs.rc")" = 0 ] && ok || bad "B5 $f: exit 0"
  [ "$(nrec)" = 0 ] && ok || bad "B5 $f: nothing run ($(cat "$T/rec.txt"))"
  rm -f "$R/flags/$f"
done

# ============================================================================
# B1: the REAL backstop into the REAL conductor — a WAIT_CI row approved on its
# head, green and clean on a Mergify repo, no wake: one run enqueues it.
# ============================================================================
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/pr-dep-gate.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR/bin/merge-conductor-backstop.sh" "$T/h/bin/"
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$T/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/c-calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*)
    printf '%s\n' "\$*" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api repos/$SLUG/issues/31") printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '%s\n' "\$D" >> "$T/c-ledger.jsonl"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"; : > "$T/c-ledger.jsonl"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge" "$T/h/flags/conductor-owns-merges"
printf '%s\tWAIT_CI\t%s\t%s\t%s\t-\t-\t%s\n' "$SLUG#31" $((NOW-600)) "$H1" "$H1" "$U/31" > "$T/h/state/merge-conductor/pr-state.tsv"
: > "$T/c-posts.txt"; : > "$T/c-calls.txt"
( cd "$T" && env -u MC_ONLY_PR PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor-backstop.sh" > "$T/b1.out" 2>&1 )
# TEST-CHANGE (BH-6000): the run is detached now; wait (bounded) for it to end.
n=0; while pgrep -f "$T/h/bin/merge-conductor.sh" >/dev/null 2>&1 && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n + 1)); done
[ "$(grep -c . "$T/c-posts.txt")" = 1 ] && ok || bad "B1 one backstop run posts @mergifyio queue for #31 (posts: $(grep -c . "$T/c-posts.txt"); out: $(tail -3 "$T/b1.out"); log: $(grep -i '31\|keyed\|autoenqueue' "$T/h/logs/merge-conductor.log" | tail -8))"
grep -q "keyed tick: 1 key(s) — $SLUG#31" "$T/h/logs/merge-conductor.log" && ok || bad "B1 the conductor ran KEYED on $SLUG#31"
[ -s "$T/c-merges.txt" ] && bad "B1 no merge call ($(cat "$T/c-merges.txt"))" || ok
[ ! -e "$T/h/state/merge-conductor/tick-mgfy.json" ] && ok || bad "B1 the keyed run leaves the cadence clock alone"

echo "merge-conductor-backstop.bh-3454: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
