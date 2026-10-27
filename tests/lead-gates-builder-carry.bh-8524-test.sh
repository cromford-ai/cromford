#!/bin/bash
# tests/lead-gates-builder-carry.bh-8524-test.sh — gate 10's builder carry
# (bin/lib/lead-gates.d/10-builder.sh, bin/lib/builder-carry.sh) and gate 50's
# already-replayed rule (bin/lib/lead-gates.d/50-replay-delta.sh) on the
# worklist. bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh. The builder APPROVE is on $SHA;
# H1 = $SHA + a clean main merge (lwf_main_merge); H3 = $SHA + one own line.
# CI is not green on any head. Each case has its own PR number.
#   BC1   #221 on H1, lead MERGE on $SHA: one POST /api/verdicts with
#         `lead-replay:<SG> how:main-merge`. The row that post writes is added
#         to the history; the next tick makes 0 posts, 0 jobs, 0 agent calls,
#         and logs `lead word already replayed onto this head`.
#   BC2   #222 on H1, no lead row, LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 (env;
#         gate 10 reads it through lane_env_apply, which keeps the env value):
#         one job, its scope notes start `auto: builder APPROVE carried from
#         <SG> (how:main-merge)`, the carried log line, 0 posts.
#   BC2b  #223 on H3 under the same knob: 0 jobs, `[skip no-approve]`, no
#         carried line.
#   BC3   #224 on H1, lead MERGE on $SHA, the clone lacks $SHA and H1 and its
#         origin is an https URL with a fixture credential; a git wrapper fails
#         every fetch. The log has the redacted `not carried: fetch of ...
#         failed (...)` line, never the credential; builder-carry.tsv has no
#         row for H1; 0 posts.
#   M1    the LGB_REQFOR carry line deleted from the scratch copy of gate 10:
#         BC2's notes lose the carried prefix (so BC2 can fail).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-builder-carry.bh-8524-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lib/lead-gates.d/10-builder.sh bin/lib/lead-gates.d/50-replay-delta.sh bin/lib/builder-carry.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
lwf_main_merge
SG=${SHA:0:12}; H112=${H1:0:12}
gc=(git -C "$W" -c user.email=t@t -c user.name=t)
"${gc[@]}" checkout -q -b own8524 "$SHA"; echo three >> "$W/a.txt"; "${gc[@]}" commit -qam "own line"; H3=$("${gc[@]}" rev-parse HEAD)
git -C "$W" push -q "$O" "$H1:refs/pull/222/head" "$H3:refs/pull/223/head" "$H1:refs/pull/224/head"
GATE10="$H/bin/lib/lead-gates.d/10-builder.sh"
[ -r "$GATE10" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/10-builder.sh"; exit 1; }
CARRY="$H/state/lead-review-enqueue/builder-carry.tsv"

djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
nvposts() { lwf_cnt '^POST /api/verdicts ' "$T/log/worker"; }
# jnotes <pr> — the scope notes of the last lead review start for <pr>
jnotes() {
  grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null | sed 's#^POST /api/lead-reviews/start ##' \
    | jq -r --argjson n "$1" 'select(.pr == $n) | .scope_notes // ""' 2>/dev/null | tail -n 1
}
# wset <pr> <head> <lead word on $SHA, or ""> — one needs-review row, builder APPROVE on $SHA, CI not green
wset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$2" "$1"; echo "$2" > "$FX/head.$1"
  lwf_bv "$1" APPROVE "$SHA"
  printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "Tests"\n' > "$FX/mergify.yml"
  jq -nc --arg g "$SHA" --arg w "$3" --argjson n "$1" \
    '{rows:(if $w == "" then [] else [{id:7, source:"lead", repo:"example-org/demo-os", pr:$n, head_sha:$g, verdict:$w,
      note:"report:state/lead-reviews/x.md"}] end), truncated:false}' > "$FX/verdicts.json"
  printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
}

# ── BC1: a carried head that already has its replay row gets no second post ──
wset 221 "$H1" MERGE; lwf_tick
[ "$(nvposts)" = 1 ] && grep '^POST /api/verdicts ' "$T/log/worker" | grep -q "lead-replay:$SG how:main-merge" && ok \
  || bad "BC1 tick 1 POST /api/verdicts=$(nvposts): $(cat "$L")"
# The history now holds the row that post wrote (its own body, as the worker stores it).
PB=$(grep '^POST /api/verdicts ' "$T/log/worker" | head -1 | sed 's#^POST /api/verdicts ##')
jq -c '{source, head_sha, verdict, note}' <<<"$PB" >/dev/null 2>&1 || bad "BC1 the replay POST body is not JSON: $PB"
jq --argjson b "$PB" '.rows += [$b + {id:8, repo:"example-org/demo-os", pr:221}]' "$FX/verdicts.json" > "$FX/v.tmp" && mv "$FX/v.tmp" "$FX/verdicts.json"
[ "$(jq -r --arg h "$H1" '[.rows[] | select(.head_sha == $h and .source == "lead") | .note] | first // ""' "$FX/verdicts.json")" = "lead-replay:$SG how:main-merge" ] && ok \
  || bad "BC1 the replay row in the history: $(cat "$FX/verdicts.json")"
rm -f "$T/log/worker" "$T/log/agent-prs"; lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 221)" = 0 ] && [ "$(lwf_agents)" = 0 ] && ok \
  || bad "BC1 tick 2: posts=$(nvposts) jobs=$(djobs 221) agents=$(lwf_agents) (want 0 0 0): $(cat "$L")"
grep -q "example-org/demo-os#221 @$H112: lead word already replayed onto this head; no post, no review" "$L" && ok \
  || bad "BC1 tick 2: no already-replayed line: $(cat "$L")"

# ── BC2: the builder gate on, no lead row, CI not green: the carried APPROVE starts one review ──
bc2() { wset 222 "$H1" ""; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 lwf_tick; }
bc2
[ "$(djobs 222)" = 1 ] && ok || bad "BC2 jobs for 222=$(djobs 222) (want 1): $(cat "$L")"
case "$(jnotes 222)" in "auto: builder APPROVE carried from $SG (how:main-merge)"*) ok ;; *) bad "BC2 notes: '$(jnotes 222)'" ;; esac
grep -q "example-org/demo-os#222 @$H112: builder APPROVE carried from $SG (how:main-merge)" "$L" && ok || bad "BC2 no carried line: $(cat "$L")"
[ "$(nvposts)" = 0 ] && ok || bad "BC2 POST /api/verdicts=$(nvposts)"

# ── BC2b: one own line under the same knob: no carry, skipped ──
wset 223 "$H3" ""; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 lwf_tick
[ "$(djobs 223)" = 0 ] && ok || bad "BC2b jobs for 223=$(djobs 223) (want 0)"
[ "$(lwf_cnt "\[skip no-approve\] example-org/demo-os#223 @${H3:0:12} " "$L")" = 1 ] && ok || bad "BC2b no [skip no-approve]: $(cat "$L")"
grep -q 'builder APPROVE carried' "$L" && bad "BC2b a carried line: $(grep carried "$L")" || ok

# ── BC3: every fetch fails: the redacted error is logged, nothing is cached ──
REALGIT=$(command -v git)
ORIGIN_URL="https://u:secret-fixture@example.invalid/demo-os/"
mkdir -p "$T/gitwrap"
cat > "$T/gitwrap/git" <<GIT
#!/bin/bash
for a in "\$@"; do
  [ "\$a" = fetch ] && { echo "fatal: unable to access '$ORIGIN_URL': fixture outage" >&2; exit 128; }
done
exec "$REALGIT" "\$@"
GIT
chmod +x "$T/gitwrap/git"
wset 224 "$H1" MERGE
scratch_rm "$T/repos/demo-os"
# A main-only clone: main is the new main, which holds neither $SHA nor H1.
git clone -q --single-branch -b main "file://$O" "$T/repos/demo-os"
git -C "$T/repos/demo-os" remote set-url origin "$ORIGIN_URL"
git -C "$T/repos/demo-os" cat-file -e "$SHA^{commit}" 2>/dev/null && bad "BC3 setup: the clone holds \$SHA"
git -C "$T/repos/demo-os" cat-file -e "$H1^{commit}" 2>/dev/null && bad "BC3 setup: the clone holds H1"
PATH="$T/gitwrap:$PATH" lwf_tick
grep -qF "example-org/demo-os#224 @$H112: builder APPROVE on $SG not carried: fetch of $SG/$H112 failed (fatal: unable to access 'https://***@example.invalid/demo-os/': fixture outage)" "$L" && ok \
  || bad "BC3 no redacted not-carried line: $(cat "$L")"
grep -q secret-fixture "$L" && bad "BC3 the credential reached the log: $(grep secret-fixture "$L")" || ok
[ "$(awk -F'\t' -v h="$H1" '$5 == h' "$CARRY" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && ok || bad "BC3 a cache row for an undecided answer: $(cat "$CARRY")"
[ "$(nvposts)" = 0 ] && ok || bad "BC3 POST /api/verdicts=$(nvposts)"
scratch_rm "$T/repos/demo-os"; git clone -q "$O" "$T/repos/demo-os"

# ── M1: without the LGB_REQFOR carry line the notes lose the carried prefix ──
cp "$GATE10" "$T/gate10.orig"
sed -i '/LGB_REQFOR="builder APPROVE carried from/d' "$GATE10"
cmp -s "$GATE10" "$T/gate10.orig" && bad "M1 the mutation did not apply"
bc2
case "$(jnotes 222)" in "auto: builder APPROVE carried"*) bad "M1 the notes still name the carry: '$(jnotes 222)'" ;; "") bad "M1 no review started: $(cat "$L")" ;; *) ok ;; esac
cp "$T/gate10.orig" "$GATE10"
cmp -s "$GATE10" "$SRC/bin/lib/lead-gates.d/10-builder.sh" && ok || bad "M1 gate 10 was not restored"

echo "lead-gates-builder-carry.bh-8524: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
