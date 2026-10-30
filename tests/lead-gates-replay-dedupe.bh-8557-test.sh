#!/bin/bash
# tests/lead-gates-replay-dedupe.bh-8557-test.sh — gate 50's rebound replay
# (bin/lib/lead-gates.d/50-replay-delta.sh) on the worklist: when the post
# counts as a replay, when the verdict history is unreadable, and when a head
# counts as already replayed. bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh, with the lead token on the box.
# The builder APPROVE is on $SHA (G, SG = its first 12) and head-bound
# reapproved@H1; H1 = $SHA + a clean main merge (lwf_main_merge). Each case has
# its own PR number on H1 and one lead row on $SHA.
#   DD1   bin/lead-verdict.sh (a stub) exits 5 (advice): replayed. The stub ran
#         once with the replay argv; 0 jobs; the `post rc 5); no review` line;
#         one modes.tsv `replay` row.
#   DD1b  the real bin/lead-verdict.sh, POST statuses answers 500 (exit 4):
#         one POST /api/verdicts, 0 jobs, the `post rc 4); no review` line, one
#         modes.tsv row.
#   DD1c  the stub exits 3: held. 0 jobs, the `not recorded (post rc 3` line,
#         held=1 in the summary, no modes.tsv row.
#   DD2   the history read (GET /api/verdicts?repo=&pr=, not standing_only)
#         answers 500: `verdicts read failed; full review`, 0 posts, 1 job. A
#         curl wrapper on PATH fails only that read and passes every other
#         request to the fixture's curl: the standing read must still answer,
#         or an earlier gate holds the head before gate 50 runs.
#   DD3   the history read answers 200 with a non-JSON body: the same.
#   DD4   the verdicts read is truncated: the same.
#   DD5   the only row on $SHA is a box row: no G, 0 posts, 1 job, no replay line.
#   DD6   the lead row on $SHA has an empty word: the same.
#   DD7   a lead `lead-replay:` row on ANOTHER head does not count for H1: one
#         MERGE post on H1, no `already replayed` line.
#   DD7b  the same note on H1 from source box: one post, no `already replayed`.
#   DD7c  the same note on H1 from the lead, retracted: one post, no
#         `already replayed`.
#   DD9   #312 on H3 = $SHA + one own line, its builder APPROVE on $SHA rebound
#         to H3: the patch changed, so 0 posts, 1 job, no replay line.
#   M1    the head clause cut from the already-replayed rule (scratch copy of
#         gate 50): DD7 makes 0 posts and logs `already replayed`.
#   M2    ` and .truncated != true` cut from the unreadable-read check: DD4
#         replays (1 post).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-replay-dedupe.bh-8557-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
for f in bin/lead-review.sh bin/lead-verdict.sh bin/lib/lead-gates.d/50-replay-delta.sh bin/lib/patch-same.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
# BH-8705: gate 07 (bin/lib/lead-gates.d/07-merge-carry.sh) carries a lead
# word onto a main-merge head before gates 10 and 50. This suite pins the path
# with that gate off; tests/lead-merge-carry.bh-8705-test.sh pins the gate.
export LEAD_REVIEW_MERGE_CARRY=0
lwf_main_merge
SG=${SHA:0:12}; H112=${H1:0:12}
refs=(); for n in $(seq 301 311); do refs+=("$H1:refs/pull/$n/head"); done
gc=(git -C "$W" -c user.email=t@t -c user.name=t)
"${gc[@]}" checkout -q -b own8557 "$SHA"; echo three >> "$W/a.txt"; "${gc[@]}" commit -qam "own line"; H3=$("${gc[@]}" rev-parse HEAD)
git -C "$W" push -q "$O" "${refs[@]}" "$H3:refs/pull/312/head"
GATE50="$H/bin/lib/lead-gates.d/50-replay-delta.sh"
[ -r "$GATE50" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/50-replay-delta.sh"; exit 1; }
LV="$H/bin/lead-verdict.sh"
# The history-read wrapper: $FX/history.fail = 500, $FX/history.junk = a non-JSON 200.
mkdir -p "$T/vwrap"
cat > "$T/vwrap/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    https://jobs.test/api/verdicts\?*standing_only=1*) ;;
    https://jobs.test/api/verdicts\?*)
      [ -e "$FX/history.fail" ] && { printf '%s\n%s' '{"error":"fixture outage"}' 500; exit 0; }
      [ -e "$FX/history.junk" ] && { printf '%s\n%s' '<html>not json</html>' 200; exit 0; } ;;
  esac
done
exec "$T/fakebin/curl" "\$@"
EOF
chmod +x "$T/vwrap/curl"
MODES="$H/state/lead-review-enqueue/modes.tsv"

djobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
vposts() { grep '^POST /api/verdicts ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/verdicts //'; }
nvposts() { lwf_cnt '^POST /api/verdicts ' "$T/log/worker"; }
nmodes() { awk -F'\t' -v n="$1" '$3 == "replay" && $5 == n' "$MODES" 2>/dev/null | wc -l | tr -d ' '; }
# dset <pr> <lead word on $SHA> [<jq on the history>] — <pr> on H1, rebound, token on the box
dset() {
  lwf_reset; scratch_rm "$H/state/lead-review-enqueue"
  lwf_needs_at example-org/demo-os "$H1" "$1"; echo "$H1" > "$FX/head.$1"
  lwf_bv "$1" APPROVE "$SHA" "reapproved@$H1"
  printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
  jq -nc --arg g "$SHA" --arg w "$2" --argjson n "$1" \
    '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:$n, head_sha:$g, verdict:$w, note:""}], truncated:false}' \
    | jq -c --arg h "$H1" --arg n "lead-replay:$SG how:main-merge" --argjson p "$1" "${3:-.}" > "$FX/verdicts.json"
}
# lvstub <rc> — bin/lead-verdict.sh logs its argv to $T/log/lv and exits <rc>
lvstub() {
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/lv"\nexit %s\n' "$T" "$1" > "$LV"; chmod +x "$LV"
}
lvrestore() {
  cp "$SRC/bin/lead-verdict.sh" "$LV"
  cmp -s "$LV" "$SRC/bin/lead-verdict.sh" && ok || bad "$1 bin/lead-verdict.sh was not restored"
}
# unreadable <case> <pr> — the outcome of an unreadable history
unreadable() {
  [ "$(nvposts)" = 0 ] && ok || bad "$1 posts=$(nvposts) (want 0): $(vposts)"
  [ "$(djobs "$2")" = 1 ] && ok || bad "$1 jobs=$(djobs "$2") (want 1): $(cat "$L")"
  grep -q "example-org/demo-os#$2 @$H112: verdicts read failed; full review" "$L" && ok || bad "$1 no read-failed line: $(cat "$L")"
}
# replays <case> <pr> — one MERGE post on H1 and no already-replayed line
replays() {
  [ "$(nvposts)" = 1 ] && [ "$(vposts | jq -r '.verdict + " " + .head_sha')" = "MERGE $H1" ] && ok \
    || bad "$1 posts: $(vposts) / $(cat "$L")"
  grep -q "example-org/demo-os#$2 @$H112: lead word already replayed" "$L" && bad "$1 counted as already replayed: $(cat "$L")" || ok
}

# ── DD1: post rc 5 (advice) is still a replay ──
lvstub 5; dset 301 MERGE; lwf_tick
[ "$(lwf_cnt . "$T/log/lv")" = 1 ] && ok || bad "DD1 lead-verdict.sh ran $(lwf_cnt . "$T/log/lv") time(s) (want 1)"
case "$(cat "$T/log/lv" 2>/dev/null)" in
  "post example-org/demo-os 301 $H1 MERGE --source lead "*"--note lead-replay:$SG how:main-merge"*) ok ;;
  *) bad "DD1 argv: '$(cat "$T/log/lv" 2>/dev/null)'" ;;
esac
[ "$(djobs 301)" = 0 ] && ok || bad "DD1 jobs=$(djobs 301) (want 0)"
grep -q "example-org/demo-os#301 @$H112: lead MERGE replayed from $SG (how:main-merge, post rc 5); no review" "$L" && ok \
  || bad "DD1 no replay line: $(cat "$L")"
[ "$(nmodes 301)" = 1 ] && ok || bad "DD1 modes rows=$(nmodes 301) (want 1): $(cat "$MODES" 2>/dev/null)"
lvrestore DD1

# ── DD1b: the real writer, its status publish fails (rc 4): still a replay ──
dset 302 MERGE; : > "$FX/statusfail"; lwf_tick
[ "$(nvposts)" = 1 ] && ok || bad "DD1b posts=$(nvposts) (want 1)"
[ "$(djobs 302)" = 0 ] && ok || bad "DD1b jobs=$(djobs 302) (want 0)"
grep -q "example-org/demo-os#302 @$H112: lead MERGE replayed from $SG (how:main-merge, post rc 4); no review" "$L" && ok \
  || bad "DD1b no rc 4 replay line: $(cat "$L")"
[ "$(nmodes 302)" = 1 ] && ok || bad "DD1b modes rows=$(nmodes 302) (want 1)"

# ── DD1c: an unknown post rc (3) is held, never recorded as a replay ──
lvstub 3; dset 303 MERGE; lwf_tick
[ "$(djobs 303)" = 0 ] && ok || bad "DD1c jobs=$(djobs 303) (want 0)"
grep -q "example-org/demo-os#303 @$H112: lead MERGE replay from $SG not recorded (post rc 3" "$L" && ok \
  || bad "DD1c no not-recorded line: $(cat "$L")"
lwf_summary | grep -qw 'held=1' && ok || bad "DD1c summary: $(lwf_summary)"
[ "$(nmodes 303)" = 0 ] && ok || bad "DD1c modes rows=$(nmodes 303) (want 0)"
lvrestore DD1c

# ── DD2, DD3, DD4: an unreadable history is a full review, never a replay ──
dset 304 MERGE; : > "$FX/history.fail"; PATH="$T/vwrap:$PATH" lwf_tick; unreadable DD2 304
dset 305 MERGE; : > "$FX/history.junk"; PATH="$T/vwrap:$PATH" lwf_tick; unreadable DD3 305
dset 306 MERGE '.truncated = true'; lwf_tick; unreadable DD4 306

# ── DD5, DD6: no G (a box-only history, an empty lead word): a full review ──
dset 307 MERGE '.rows |= map(.source = "box")'; lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 307)" = 1 ] && ok || bad "DD5 posts=$(nvposts) jobs=$(djobs 307) (want 0 1): $(cat "$L")"
grep -q "#307 .*replayed from" "$L" && bad "DD5 a replay line: $(cat "$L")" || ok
dset 308 ""; lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 308)" = 1 ] && ok || bad "DD6 posts=$(nvposts) jobs=$(djobs 308) (want 0 1): $(cat "$L")"
grep -q "#308 .*replayed from" "$L" && bad "DD6 a replay line: $(cat "$L")" || ok

# ── DD7, DD7b, DD7c: a lead-replay: note counts only from the lead, on this head, standing ──
DD7ROW='.rows += [{id:8, source:"lead", repo:"example-org/demo-os", pr:$p, head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", verdict:"MERGE", note:$n}]'
dset 309 MERGE "$DD7ROW"; lwf_tick; replays DD7 309
dset 310 MERGE '.rows += [{id:8, source:"box", repo:"example-org/demo-os", pr:$p, head_sha:$h, verdict:"APPROVE", note:$n}]'; lwf_tick
replays DD7b 310
dset 311 MERGE '.rows += [{id:8, source:"lead", repo:"example-org/demo-os", pr:$p, head_sha:$h, verdict:"MERGE", note:$n,
  retracted_at:"2026-10-26T01:00:00Z", retract_reason:"empty-report"}]'; lwf_tick
replays DD7c 311

# ── DD9: a rebound head with its own change is a review, never a replay ──
dset 312 MERGE
lwf_needs_at example-org/demo-os "$H3" 312; echo "$H3" > "$FX/head.312"; lwf_bv 312 APPROVE "$SHA" "reapproved@$H3"
lwf_tick
[ "$(nvposts)" = 0 ] && [ "$(djobs 312)" = 1 ] && ok || bad "DD9 posts=$(nvposts) jobs=$(djobs 312) (want 0 1): $(cat "$L")"
grep -q "#312 .*replayed from" "$L" && bad "DD9 a replay line: $(cat "$L")" || ok

# ── M1: without the head clause, DD7's other-head row would stop the replay ──
cp "$GATE50" "$T/gate50.orig"
sed -i 's/\.source == "lead" and ((\.head_sha \/\/ "") | ascii_downcase) == \$h$/.source == "lead"/' "$GATE50"
cmp -s "$GATE50" "$T/gate50.orig" && bad "M1 the mutation did not apply"
dset 309 MERGE "$DD7ROW"; lwf_tick
[ "$(nvposts)" = 0 ] && ok || bad "M1 posts=$(nvposts) (want 0): DD7 cannot fail"
grep -q "example-org/demo-os#309 @$H112: lead word already replayed onto this head" "$L" && ok || bad "M1 no already-replayed line: $(cat "$L")"
cp "$T/gate50.orig" "$GATE50"
cmp -s "$GATE50" "$SRC/bin/lib/lead-gates.d/50-replay-delta.sh" && ok || bad "M1 gate 50 was not restored"

# ── M2: without the truncated check, DD4 replays off a truncated history ──
sed -i 's/ and \.truncated != true//' "$GATE50"
cmp -s "$GATE50" "$T/gate50.orig" && bad "M2 the mutation did not apply"
dset 306 MERGE '.truncated = true'; lwf_tick
[ "$(nvposts)" = 1 ] && ok || bad "M2 posts=$(nvposts) (want 1): DD4 cannot fail"
cp "$T/gate50.orig" "$GATE50"
cmp -s "$GATE50" "$SRC/bin/lib/lead-gates.d/50-replay-delta.sh" && ok || bad "M2 gate 50 was not restored"

echo "lead-gates-replay-dedupe.bh-8557: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
