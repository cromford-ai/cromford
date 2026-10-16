#!/bin/bash
# tests/golive-hold.bh-7123-test.sh — a NEEDS-HUMAN step never gates a merge
# (BH-7123 wave B, C3). A go-live step a user depends on (catalog/review-golive.tsv)
# rides to the TICKET as a visible hold the pool and the resolver read as clear,
# and the PR lands on the lead's MERGE / MERGE-WITH-NOTES or the builder's APPROVE.
#   §A  rl_cap --golive note: a go-live NEEDS_HUMAN: / [BLOCK needs-human] line
#       becomes [HUMAN go-live] (lead, prs) or HUMAN_GOLIVE: (in-build), counts as
#       no standing BLOCK, and the summary says golive=N; the default still stands
#       (wave A's A4); rl_golive_opt reads review.golive_gates_merge
#   §H  bin/lib/hold.sh: a `NEEDS-HUMAN: go-live: <step>` marker classifies
#       `clear<TAB>hold:go-live <at> <step>` (rc 0): the pool and the resolver
#       proceed, HUMAN-STEP-DONE / RESUME lift it, a person's HOLD / ABANDON and
#       an unanswered ordinary NEEDS-HUMAN still hold; both engines agree
#   §R  bin/blocked-resolver.sh br_hold_gate reads it as clear (no HELD park)
#   §N  bin/needs-human-hold.sh with source go-live: the marker shape, one POST,
#       one ask, the fp dedupe, and the thread then reads hold:go-live
#   §L  bin/lead-review-land.sh lrl_golive_route: a MERGE whose detail says
#       golive:N posts the go-live hold from the report's [HUMAN go-live] lines,
#       once; no detail, no artifact read, no hold
#   §B  in-build: nh_on_golive's RESULT suffix, and LENS_REFUSE's human-only
#       guard approves instead of exit 6 when nothing else stands
#   §K  the ticket_stage row human-step-waiting is written for the kanban
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/golive-hold.bh-7123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

STEP='add the live Stripe key on Vercel before go-live'
T1=2026-10-16T09:00:00Z; T2=2026-10-16T10:00:00Z; T3=2026-10-16T11:00:00Z

# ── §A: rl_cap --golive note ───────────────────────────────────────────────
unset REVIEW_LEVEL_MODE REVIEW_LEVEL_GOLIVE_GATES_MERGE
(
  export HARNESS="$DIR"
  . "$DIR/bin/lib/review-level.sh" || { echo "FAIL: cannot source review-level.sh"; exit 1; }
  cat > "$T/a1.md" <<EOF
Findings

- [BLOCK] worker/x.js:12: the comment says 60 s but the cache window is 90 s
- [BLOCK needs-human] src/billing.ts:9: $STEP
- [NOTE] bin/x.sh:4: the log line could name the pr

VERDICT: BLOCK
EOF
  cp "$T/a1.md" "$T/a1.keep"
  out=$(rl_cap "$T/a1.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive note 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && ok || bad "A1 rl_cap rc $rc"
  grep -q 'standing=0 verdict=MERGE-WITH-NOTES' <<<"$out" && ok || bad "A1 summary: $out"
  grep -q 'golive=1' <<<"$out" && ok || bad "A1 the summary must say golive=1: $out"
  grep -q "^- \[HUMAN go-live\] src/billing.ts:9: $STEP" "$T/a1.md" && ok || bad "A1 the go-live line was not rewritten to [HUMAN go-live]: $(grep -n 'needs-human\|go-live' "$T/a1.md")"
  grep -q '^- \[NOTE demoted from BLOCK\] worker/x.js' "$T/a1.md" && ok || bad "A1 the nit was not demoted"
  [ "$(sed -n '$p' "$T/a1.md")" = "VERDICT: MERGE-WITH-NOTES" ] && ok || bad "A1 verdict: $(sed -n '$p' "$T/a1.md")"
  out2=$(rl_cap "$T/a1.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive note 2>/dev/null)
  grep -q 'golive=1' <<<"$out2" && ok || bad "A1b a second read of the capped file keeps golive=1: $out2"
  # The default (no --golive) is wave A's behaviour: the go-live step stands.
  out=$(rl_cap "$T/a1.keep" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead 2>/dev/null)
  grep -q 'standing=1 verdict=BLOCK' <<<"$out" && ok || bad "A2 default: the go-live step must still stand: $out"
  grep -q "^- \[BLOCK needs-human\] src/billing.ts:9: $STEP" "$T/a1.keep" && ok || bad "A2 default: the line must not be rewritten"
  # An explicit --golive stand is the default spelled out.
  cat > "$T/a2.md" <<EOF
- [BLOCK needs-human] src/billing.ts:9: $STEP

VERDICT: BLOCK
EOF
  out=$(rl_cap "$T/a2.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive stand 2>/dev/null)
  grep -q 'standing=1' <<<"$out" && ok || bad "A3 --golive stand: $out"
  # In-build: the structured NEEDS_HUMAN: line becomes HUMAN_GOLIVE: on its own line.
  cat > "$T/a4.md" <<EOF
Findings:
- [BLOCK] src/app/page.tsx:40: the sort indicator is missing
NEEDS_HUMAN: $STEP
NEEDS_HUMAN: On a host with Chromium run npm run e2e
TIER: 2
VERDICT: BLOCK
EOF
  out=$(rl_cap "$T/a4.md" project-6-os --approve APPROVE --block BLOCK --lens inbuild --golive note 2>/dev/null)
  grep -q 'standing=0 verdict=APPROVE' <<<"$out" && grep -q 'golive=1' <<<"$out" && ok || bad "A4 in-build summary: $out"
  grep -q "^HUMAN_GOLIVE: $STEP\$" "$T/a4.md" && ok || bad "A4 in-build: the go-live line must become HUMAN_GOLIVE: <text>: $(grep -n 'HUMAN\|NEEDS' "$T/a4.md")"
  grep -q '^NOTE not verified here (demoted, BH-7123): On a host with Chromium' "$T/a4.md" && ok || bad "A4 the Chromium verification is still a demoted note"
  grep -q '^VERDICT: APPROVE$' "$T/a4.md" && ok || bad "A4 verdict flipped"
  [ "$(grep -c '^NEEDS_HUMAN:' "$T/a4.md")" = 0 ] && ok || bad "A4 no NEEDS_HUMAN: line may remain (the hold is placed from HUMAN_GOLIVE:)"
  # A floor line beside a go-live step: the floor stands, the step is still noted.
  cat > "$T/a5.md" <<EOF
- [BLOCK tenant-leak] src/lib/clients.ts:88: listClients() has no companyId filter
- [BLOCK needs-human] $STEP

VERDICT: BLOCK
EOF
  out=$(rl_cap "$T/a5.md" cromford --approve MERGE-WITH-NOTES --block BLOCK --lens lead --golive note 2>/dev/null)
  grep -q 'standing=1 verdict=BLOCK untagged=0 golive=1' <<<"$out" && ok || bad "A5 floor + go-live: $out"
  # rl_golive_opt: the row review.golive_gates_merge (0 = note, 1 = stand; no row = note).
  [ "$(rl_golive_opt cromford)" = note ] && ok || bad "A6 no row -> note, got $(rl_golive_opt cromford)"
  [ "$(REVIEW_LEVEL_GOLIVE_GATES_MERGE=1 rl_golive_opt cromford)" = stand ] && ok || bad "A6 row 1 -> stand"
  [ "$(REVIEW_LEVEL_GOLIVE_GATES_MERGE=0 rl_golive_opt cromford)" = note ] && ok || bad "A6 row 0 -> note"
  [ "$(REVIEW_LEVEL_GOLIVE_GATES_MERGE=x rl_golive_opt cromford)" = note ] && ok || bad "A6 a bad row -> note"
  echo "A: $PASS passed, $FAIL failed" > "$T/a.count"
)
read -r _ AP _ AF _ < "$T/a.count"; PASS=$((PASS+AP)); FAIL=$((FAIL+AF))

# ── §H: hold.sh ────────────────────────────────────────────────────────────
LIB="$DIR/bin/lib/hold.sh"
(
  . "$LIB" || { echo "FAIL: hold.sh does not source"; exit 1; }
  ISSUE() { jq -nc --arg s "${1:-open}" --arg l "${2-ai-build}" '{state:$s, labels:($l | split(",") | map(select(. != "")) | map({name:.})), title:"BH-1: a thing", body:"## Scope"}'; }
  CMT() { jq -nc --arg b "$1" --arg c "$2" --arg u "${3:-User}" '{body:$b, created_at:$c, user:{type:$u}}'; }
  CMTS() { local IFS=","; printf '[%s]' "$*"; }
  OPEN=$(ISSUE)
  GL="NEEDS-HUMAN: go-live: $STEP"
  NH="NEEDS-HUMAN: run vs_publish probe from the hub"
  TAG='<!-- nh-fp:abc123def456 -->'
  row() { local out rc; out=$(hold_classify "$3" "$4" 2>/dev/null); rc=$?; out=$(printf '%s' "$out" | tr '\t' '|')
    case "$2" in *'*') [ "$rc" = "$1" ] && [[ "$out" == "${2%\*}"* ]] && ok || bad "$5 — wanted rc $1 '$2', got rc $rc '$out'" ;;
      *) [ "$rc" = "$1" ] && [ "$out" = "$2" ] && ok || bad "$5 — wanted rc $1 '$2', got rc $rc '$out'" ;; esac; }
  row 0 "clear|hold:go-live $T2 $STEP" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")")" "H1: a go-live marker is clear, and names the step"
  row 0 "clear|hold:go-live $T2 $STEP" "$OPEN" "$(CMTS "$(CMT "$GL
$TAG" "$T2" Bot)")" "H2: the placer's tagged Bot go-live marker reads the same"
  row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2" Bot)")" "H3: an untagged Bot marker is nothing, as today"
  row 0 "clear|lifted-by-human-step $T3" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")" "$(CMT 'HUMAN-STEP-DONE: key added' "$T3")")" "H4: HUMAN-STEP-DONE lifts it"
  row 0 "clear|lifted-by-comment $T3" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")" "$(CMT 'RESUME' "$T3")")" "H5: RESUME lifts it"
  row 1 "held|hold:comment $T1 HOLD: wait for the operator" "$OPEN" "$(CMTS "$(CMT 'HOLD: wait for the operator' "$T1")" "$(CMT "$GL" "$T2")")" "H6: a person's older HOLD still holds under a go-live marker"
  row 1 "held|hold:comment $T3 HOLD: wait" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")" "$(CMT 'HOLD: wait' "$T3")")" "H7: a newer HOLD holds"
  row 1 "held|abandon:comment $T1 ABANDON this one" "$OPEN" "$(CMTS "$(CMT 'ABANDON this one' "$T1")" "$(CMT "$GL" "$T2")")" "H8: an ABANDON still holds"
  row 1 "held|hold:waiting-on-human $T1 run vs_publish probe from the hub" "$OPEN" "$(CMTS "$(CMT "$NH" "$T1")" "$(CMT "$GL" "$T2")")" "H9: an unanswered ordinary NEEDS-HUMAN under a go-live marker still holds"
  row 0 "clear|hold:go-live $T3 $STEP" "$OPEN" "$(CMTS "$(CMT "$NH" "$T1")" "$(CMT 'HUMAN-STEP-DONE: ran it' "$T2")" "$(CMT "$GL" "$T3")")" "H10: an answered NEEDS-HUMAN under a go-live marker: the go-live step is what shows"
  row 1 "held|hold:waiting-on-human $T3 run vs_publish probe from the hub" "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")" "$(CMT "$NH" "$T3")")" "H11: a newer ordinary NEEDS-HUMAN holds over an open go-live step"
  row 1 "held|hold:label hold" "$(ISSUE open 'ai-build,hold')" "$(CMTS "$(CMT "$GL" "$T2")")" "H12: the hold label wins"
  row 1 "held|closed" "$(ISSUE closed)" "$(CMTS "$(CMT "$GL" "$T2")")" "H13: closed wins"
  V=$(hold_classify "$OPEN" "$(CMTS "$(CMT "$GL" "$T2")")")
  hold_is_pause "$V" && ok || bad "H14: hold_is_pause reads an open go-live step as a pause (bin/lib/ticket-ownership.sh keeps the ticket owned, so no re-launch): '$V'"
  hold_is_abandon "$V" && bad "H14: go-live is not an abandon" || ok
  # The regex is exported for the python engine like every other HOLD_*_RE.
  [ -n "${HOLD_GOLIVE_RE:-}" ] && ok || bad "H15: HOLD_GOLIVE_RE is not defined"
  bash -c '[ -n "${HOLD_GOLIVE_RE:-}" ]' && ok || bad "H15: HOLD_GOLIVE_RE is not exported"
  echo "H: $PASS passed, $FAIL failed" > "$T/h.count"
)
read -r _ HP _ HF _ < "$T/h.count"; PASS=$((PASS+HP)); FAIL=$((FAIL+HF))
# The python engine in bin/orphan-reconcile.sh has no NEEDS-HUMAN reading of its
# own: it takes hold_classify's answer (rc 0 = clear), so both engines agree by
# construction. Pin that it stays that way.
[ "$(grep -c 'NEEDS-HUMAN' <(awk '/^cat > "\$TD\/classify.py"/,/^PYEOF$/' "$DIR/bin/orphan-reconcile.sh"; sed -n '/^import /,/^print("\\n".join(rows))/p' "$DIR/bin/orphan-reconcile.sh") 2>/dev/null)" = 0 ] && ok \
  || bad "H16: the python engine grew its own NEEDS-HUMAN regex; the lib (hold_classify) is the one reading"
grep -q 'go-live' "$DIR/bin/lib/hold.sh" && ok || bad "H17: hold.sh does not know the go-live tail"

# ── §R: the resolver's hold gate reads it as clear ────────────────────────
: > "$T/gate.sh"
awk '/^br_hold_gate\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" >> "$T/gate.sh"
RG=$( ST="$T/st"; mkdir -p "$ST/tproj"; H="$T"
  say() { printf '%s\n' "$*" >> "$T/gate-say.txt"; }
  br_hold_issue() { printf 'o/r 7'; }
  br_cap_key() { printf 'ck'; }
  hold_check() { printf 'clear\thold:go-live %s %s\n' "$T2" "$STEP"; return 0; }
  br_record() { printf 'record %s\n' "$*" >> "$T/gate-rec.txt"; }
  br_set_outcome() { printf 'outcome %s\n' "$*" >> "$T/gate-rec.txt"; }
  br_set_field() { :; }; br_event() { :; }
  BR_HOLD_PARKED=0
  . "$T/gate.sh"; br_hold_gate tproj 7 review-changes-requested https://github.com/o/r/pull/9 - TP-7; echo "rc=$? parked=$BR_HOLD_PARKED" )
[ "$RG" = 'rc=0 parked=0' ] && ok || bad "R1: br_hold_gate must proceed on a go-live hold (got '$RG')"
[ ! -e "$T/gate-rec.txt" ] && ok || bad "R1: no HELD record on a go-live hold: $(cat "$T/gate-rec.txt")"
# bin/fly-pool.sh's pool_hold_check switches on the first word: clear proceeds.
grep -q 'case "\$v" in held\*) return 1 ;; clear\*) return 0 ;;' "$DIR/bin/fly-pool.sh" && ok || bad "R2: pool_hold_check no longer switches on the clear/held word"

# ── §N: the placer with source go-live ────────────────────────────────────
# scratch-closure-allow: bin/needs-human-hold.sh sources its needs-human/ slices by a computed path (bin/lib/needs-human.sh), which scratch_install_closure cannot follow; the hand copies below are that placer's own libs, run against a stateful gh stub
NOW=$(date -u +%s)
PH="$T/ph"; mkdir -p "$PH/bin/lib/needs-human" "$PH/logs" "$PH/flags" "$PH/state" "$T/fakebin"
cp "$DIR/bin/needs-human-hold.sh" "$PH/bin/"
cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/needs-human.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/data-lane.sh" "$PH/bin/lib/"
cp "$DIR"/bin/lib/needs-human/*.sh "$PH/bin/lib/needs-human/"
# The key prefix the kanban row is keyed on comes from the rendered prompt's
# launch line (bin/lib/preplan-lib.sh preplan_key_prefix).
cp "$DIR/bin/lib/preplan-lib.sh" "$PH/bin/lib/"
mkdir -p "$PH/prompts"; printf 'run-build.sh bp <issue-number> BP-<issue-number>\n' > "$PH/prompts/bp.md"
ln -s "$DIR/bin/fleet-conf.sh" "$PH/bin/fleet-conf.sh"
printf 'bp o/r - - 2 box-bp 100.0.0.9\n' > "$T/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.alert"\nexit 0\n' "$T" > "$PH/bin/alert-line.sh"
chmod +x "$PH/bin/"*.sh
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.gh"
case "\$*" in
  *"-X POST repos/o/r/issues/7/comments"*)
    body=\$(jq -r '.body'); printf '%s\n' "\$body" >> "$T/posts.txt"; printf -- '---\n' >> "$T/posts.txt"
    n=\$(jq length "$T/comments.json")
    jq -c --arg b "\$body" --arg c "\$(date -u -d "@\$(( $NOW + n ))" '+%Y-%m-%dT%H:%M:%SZ')" \
      '. + [{body:\$b, created_at:\$c, user:{type:"Bot"}}]' "$T/comments.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments.json"
    echo '{"id":2}' ;;
  *"repos/o/r/issues/7/comments"*) cat "$T/comments.json" ;;
  *"repos/o/r/issues/7"*) cat "$T/issue.json" ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
jq -nc '{number:7, state:"open", title:"BP-7: a thing", body:"## Scope", labels:[{name:"ai-build"}]}' > "$T/issue.json"
echo '[]' > "$T/comments.json"
FP=abc123def456
PRC=0; PATH="$T/fakebin:$PATH" GH_TOKEN="" FLEET_CONF="$T/fleet.conf" LANE_GATE_DISABLE=1 HARNESS="$PH" \
  bash "$PH/bin/needs-human-hold.sh" bp 7 "$FP" "go-live: $STEP" go-live 2>"$T/ph.err" || PRC=$?
[ "$PRC" = 0 ] && ok || bad "N1: placer rc $PRC, want 0 ($(cat "$T/ph.err"))"
[ "$(grep -c '^---$' "$T/posts.txt" 2>/dev/null)" = 1 ] && ok || bad "N1: exactly one POST"
BODY=$(sed '/^---$/,$d' "$T/posts.txt" 2>/dev/null)
[ "$(head -1 <<<"$BODY")" = "NEEDS-HUMAN: go-live: $STEP" ] && ok || bad "N1: line 1 must be the go-live marker: '$(head -1 <<<"$BODY")'"
grep -qF "<!-- nh-fp:$FP -->" <<<"$BODY" && ok || bad "N1: the nh-fp tag rides"
grep -qi 'paused' <<<"$BODY" && bad "N1: a go-live marker must not say builds are paused" || ok
grep -qi 'merge' <<<"$BODY" && ok || bad "N1: the body says the PR merges without waiting on the step"
grep -q 'HUMAN-STEP-DONE:' <<<"$BODY" && ok || bad "N1: the body says how to mark it done"
[ "$(grep -c . "$T/calls.alert" 2>/dev/null)" = 1 ] && ok || bad "N1: one ask (got $(grep -c . "$T/calls.alert" 2>/dev/null))"
grep -q 'go-live' "$T/calls.alert" && ok || bad "N1: the ask names it a go-live step: $(cat "$T/calls.alert")"
V=$( . "$LIB"; hold_classify "$(cat "$T/issue.json")" "$(cat "$T/comments.json")" | tr '\t' '|' )
[[ "$V" == "clear|hold:go-live "*"$STEP" ]] && ok || bad "N2: the placed thread must read clear|hold:go-live, got '$V'"
PRC=0; PATH="$T/fakebin:$PATH" GH_TOKEN="" FLEET_CONF="$T/fleet.conf" LANE_GATE_DISABLE=1 HARNESS="$PH" \
  bash "$PH/bin/needs-human-hold.sh" bp 7 "$FP" "go-live: $STEP" go-live 2>/dev/null || PRC=$?
[ "$PRC" = 0 ] && [ "$(grep -c '^---$' "$T/posts.txt")" = 1 ] && ok || bad "N3: the same fp again is one comment (rc $PRC, posts $(grep -c '^---$' "$T/posts.txt"))"
[ "$(grep -c . "$T/calls.alert")" = 1 ] && ok || bad "N3: and one ask"
# §K: the kanban row.
grep -q 'human-step-waiting' "$PH/state/ticket-stage/bp.tsv" 2>/dev/null && ok || bad "K1: ticket_stage human-step-waiting was not written for the kanban: $(cat "$PH/state/ticket-stage/bp.tsv" 2>/dev/null)"
grep -q "^BP-7	review	human-step-waiting	.*go-live" "$PH/state/ticket-stage/bp.tsv" 2>/dev/null && ok || bad "K1: the row is keyed BP-7 in the review column and names the go-live step"
# An ordinary review hold still says paused and reads waiting-on-human (unchanged).
echo '[]' > "$T/comments.json"; rm -f "$T/posts.txt" "$T/calls.alert"
PATH="$T/fakebin:$PATH" GH_TOKEN="" FLEET_CONF="$T/fleet.conf" LANE_GATE_DISABLE=1 HARNESS="$PH" \
  bash "$PH/bin/needs-human-hold.sh" bp 7 "$FP" "run vs_publish probe from the hub" review 2>/dev/null
grep -q 'paused' "$T/posts.txt" && ok || bad "N4: a review hold still says builds are paused"
V=$( . "$LIB"; hold_classify "$(cat "$T/issue.json")" "$(cat "$T/comments.json")" | tr '\t' '|' )
[[ "$V" == "held|hold:waiting-on-human "* ]] && ok || bad "N4: a review hold still holds: '$V'"

# ── §L: the land lane's go-live route ─────────────────────────────────────
: > "$T/land.sh"
for fn in lrl_ticket_of lrl_golive_route lrl_flag_done lrl_flag_set; do
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/lead-review-land.sh" >> "$T/land.sh"
done
grep -q '^lrl_golive_route()' "$T/land.sh" && ok || bad "L0: bin/lead-review-land.sh has no lrl_golive_route"
grep -q '^lrl_ticket_of()' "$T/land.sh" && ok || bad "L0: bin/lead-review-land.sh has no lrl_ticket_of"
LH="$T/lh"; mkdir -p "$LH/bin" "$LH/state/lead-review-land"
printf '#!/bin/bash\ncase "$1" in --projects) echo demo ;; demo) case "$2" in repo) echo o/r ;; board_prefix) echo - ;; esac ;; esac\n' > "$LH/bin/fleet-conf.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/placer.txt"\nexit 0\n' "$T" > "$LH/bin/needs-human-hold.sh"
chmod +x "$LH/bin/"*.sh
SHA=$(printf 'a%.0s' {1..40})
REPORT="# Lead review lr-5-aaaaaaaaaaaa (o/r#5 at $SHA)

- verdict: MERGE-WITH-NOTES
- review level (BH-7123): mode=levels demoted=1 standing=0 verdict=MERGE-WITH-NOTES golive=1

- [NOTE demoted from BLOCK] worker/x.js:12: the cache window
- [HUMAN go-live] src/billing.ts:9: $STEP

VERDICT: MERGE-WITH-NOTES"
cat > "$T/landdrv.sh" <<EOF
H="$LH"; STATE="$LH/state/lead-review-land"; SJOB="job-1"; LRL_BRANCH="ticket/BH-77"
log() { printf '%s\n' "\$*" >> "$T/land-log.txt"; }
lrl_pr_head() { LRL_HEAD="$SHA"; LRL_BRANCH="ticket/BH-77"; return 0; }
job_artifact_detail() { printf '%s\n' "\$*" >> "$T/artifact.txt"; jq -nc --arg b "\$(cat "$T/report.md")" '{body:\$b, path:"/x", verdict:"MERGE-WITH-NOTES"}'; }
. "$DIR/bin/lib/needs-human.sh"
. "$T/land.sh"
EOF
printf '%s\n' "$REPORT" > "$T/report.md"
ROW='{"id":"r1","job_id":"job-1","box":"b1","scope_notes":""}'
( . "$T/landdrv.sh"; lrl_golive_route r1 r1 o/r 5 "$SHA" "$ROW" "golive:1" ); RC=$?
[ "$RC" = 0 ] && ok || bad "L1: lrl_golive_route rc $RC ($(cat "$T/land-log.txt" 2>/dev/null))"
[ "$(grep -c . "$T/placer.txt" 2>/dev/null)" = 1 ] && ok || bad "L1: one hold placed (got $(grep -c . "$T/placer.txt" 2>/dev/null)): $(cat "$T/placer.txt" 2>/dev/null)"
grep -qE "^demo 77 [0-9a-f]{12} go-live: .*$STEP go-live$" "$T/placer.txt" 2>/dev/null && ok || bad "L1: placer args must be <project> <issue> <fp> 'go-live: ...<step>' go-live: $(cat "$T/placer.txt" 2>/dev/null)"
[ -e "$LH/state/lead-review-land/golive-r1" ] && ok || bad "L1: the golive-<id> flag was not written"
( . "$T/landdrv.sh"; lrl_golive_route r1 r1 o/r 5 "$SHA" "$ROW" "golive:1" )
[ "$(grep -c . "$T/placer.txt")" = 1 ] && ok || bad "L2: a second landing of the same request posts nothing (flag): $(cat "$T/placer.txt")"
rm -f "$T/placer.txt" "$T/artifact.txt" "$LH/state/lead-review-land/golive-r1"
( . "$T/landdrv.sh"; lrl_golive_route r1 r1 o/r 5 "$SHA" "$ROW" "-" )
[ ! -e "$T/placer.txt" ] && [ ! -e "$T/artifact.txt" ] && ok || bad "L3: a detail without golive: reads no artifact and places nothing"
( . "$T/landdrv.sh"; lrl_golive_route r1 r1 o/r 5 "$SHA" "$ROW" "golive:0" )
[ ! -e "$T/artifact.txt" ] && ok || bad "L4: golive:0 reads no artifact"
rm -f "$LH/state/lead-review-land/golive-r1"
( . "$T/landdrv.sh"; lrl_pr_head() { LRL_HEAD="$SHA"; LRL_BRANCH="feature/no-ticket"; return 0; }; LRL_BRANCH="feature/no-ticket"; lrl_golive_route r1 r1 o/r 5 "$SHA" "$ROW" "golive:1" ); RC=$?
[ "$RC" = 0 ] && [ ! -e "$T/placer.txt" ] && ok || bad "L5: a PR whose branch names no ticket places nothing and still lets the stamp happen (rc $RC)"
grep -q 'names no ticket' "$T/land-log.txt" && ok || bad "L5: the log says why"
# The MERGE path calls it before the stamp, and a BLOCK never does.
grep -q 'lrl_golive_route "\$ID" "\$SAFE_ID" "\$REPO" "\$PR" "\$HEAD" "\$ROW" "\$DETAIL"' "$DIR/bin/lead-review-land.sh" && ok || bad "L6: the land loop does not call lrl_golive_route on the MERGE path"

# ── §B: in-build ───────────────────────────────────────────────────────────
BH="$T/bh"; mkdir -p "$BH/bin/lib/needs-human" "$BH/catalog" "$T/build"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/bplacer.txt"\nexit 0\n' "$T" > "$BH/bin/needs-human-hold.sh"; chmod +x "$BH/bin/needs-human-hold.sh"
cp "$DIR"/catalog/review-*.tsv "$BH/catalog/"
cat > "$T/build/review.md" <<EOF
Findings:
- [BLOCK] src/app/page.tsx:40: the sort indicator is missing
NEEDS_HUMAN: $STEP
TIER: 2
VERDICT: BLOCK
EOF
SFX=$( export HARNESS="$BH"; . "$DIR/bin/lib/review-level.sh"; . "$DIR/bin/lib/needs-human.sh"
  rl_cap "$T/build/review.md" demo --approve APPROVE --block BLOCK --lens inbuild --golive note >/dev/null 2>&1
  nh_on_golive demo 77 "$T/build/review.md" "$T/build" )
[[ "$SFX" == " NEEDS_HUMAN:"*":go-live: $STEP" ]] && ok || bad "B1: nh_on_golive's suffix must be ' NEEDS_HUMAN:<fp>:go-live: <step>', got '$SFX'"
grep -qE "^demo 77 [0-9a-f]{12} go-live: $STEP go-live$" "$T/bplacer.txt" 2>/dev/null && ok || bad "B1: the placer is called with source go-live: $(cat "$T/bplacer.txt" 2>/dev/null)"
grep -q 'go-live' "$T/build/pipeline.log" 2>/dev/null && ok || bad "B1: pipeline.log records the placement"
[ -z "$( export HARNESS="$BH"; . "$DIR/bin/lib/needs-human.sh"; printf 'VERDICT: APPROVE\n' > "$T/build/plain.md"; nh_on_golive demo 77 "$T/build/plain.md" "$T/build" )" ] && ok || bad "B2: no HUMAN_GOLIVE: line -> no suffix"
# The three PR_CREATED RESULT lines carry the suffix.
[ "$(grep -c 'RESULT "PR_CREATED \$PR_URL.*\${NH_GOLIVE_SUFFIX:-}"' "$DIR/bin/lib/rb/result.sh")" = 3 ] && ok \
  || bad "B3: every PR_CREATED RESULT in bin/lib/rb/result.sh must carry \${NH_GOLIVE_SUFFIX:-} ($(grep -c 'RESULT "PR_CREATED \$PR_URL.*\${NH_GOLIVE_SUFFIX:-}"' "$DIR/bin/lib/rb/result.sh"))"
# LENS_REFUSE's guard: human-only + standing 0 -> approved, no exit 6, no REVIEW_BLOCKED.
: > "$T/lens.sh"
for fn in LENS_GOLIVE_PASS LENS_REFUSE LENS_ART; do
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/lib/rb/review.sh" >> "$T/lens.sh"
done
grep -q '^LENS_GOLIVE_PASS()' "$T/lens.sh" && ok || bad "B4: bin/lib/rb/review.sh has no LENS_GOLIVE_PASS"
cat > "$T/lensdrv.sh" <<EOF
export HARNESS="$BH"; BUILD="$T/build"; PROJECT=demo; KEY=BH-77; NH_ISSUE=77
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }
LENS_VARS() { L_RUN=review-run.txt; L_RUN2=review2-run.txt; L_FIXRUN=fix-run.txt; }; STAGE_LANE_DEFER() { :; }
nh_trip_on_block() { :; }
nh_on_block() { printf ' NEEDS_HUMAN:deadbeefcafe:%s' "x"; }
RESULT() { printf '%s\n' "\$*" >> "$T/result.txt"; }
. "$DIR/bin/lib/review-level.sh"; . "$DIR/bin/lib/needs-human.sh"; . "$DIR/bin/lib/data-lane.sh" 2>/dev/null
. "$T/lens.sh"
EOF
# Case 1: strict mode (rl_cap rewrote nothing), a human-only BLOCK: today's terminal.
cat > "$T/build/review.md" <<EOF
Findings:
NEEDS_HUMAN: $STEP
TIER: 2
VERDICT: BLOCK
EOF
rm -f "$T/result.txt"
( . "$T/lensdrv.sh"; REVIEW_LEVEL_MODE=strict; export REVIEW_LEVEL_MODE; LENS_REFUSE review ); RC=$?
[ "$RC" = 6 ] && grep -q '^REVIEW_BLOCKED' "$T/result.txt" 2>/dev/null && ok || bad "B5: in strict mode a human-only BLOCK is still REVIEW_BLOCKED / exit 6 (rc $RC: $(cat "$T/result.txt" 2>/dev/null))"
# Case 2: levels, --golive note: the only blocking line is the go-live step and nothing stands -> approved.
cat > "$T/build/review.md" <<EOF
Findings:
NEEDS_HUMAN: $STEP
TIER: 2
VERDICT: BLOCK
EOF
rm -f "$T/result.txt" "$T/bplacer.txt"
OUT=$( . "$T/lensdrv.sh"; LENS_REFUSE review; echo "rc=$? sfx=[$NH_GOLIVE_SUFFIX]" ); RC=$?
grep -q '^rc=0 sfx=\[ NEEDS_HUMAN:[0-9a-f]*:go-live: ' <<<"$OUT" && ok || bad "B6: a human-only, standing=0 lens must return 0 with the go-live suffix, got '$OUT' rc $RC"
[ ! -e "$T/result.txt" ] && ok || bad "B6: no REVIEW_BLOCKED RESULT may be written: $(cat "$T/result.txt")"
grep -q '^VERDICT: APPROVE$' "$T/build/review.md" && ok || bad "B6: review.md's verdict must read APPROVE afterwards: $(tail -3 "$T/build/review.md")"
grep -q "^HUMAN_GOLIVE: $STEP" "$T/build/review.md" && ok || bad "B6: the step rides in review.md as HUMAN_GOLIVE:"
# Case 3: a floor line beside the step: refused as today.
cat > "$T/build/review.md" <<EOF
Findings:
- [BLOCK tenant-leak] src/lib/clients.ts:88: listClients() has no companyId filter
NEEDS_HUMAN: $STEP
TIER: 2
VERDICT: BLOCK
EOF
rm -f "$T/result.txt"
( . "$T/lensdrv.sh"; LENS_REFUSE review ); RC=$?
[ "$RC" = 6 ] && grep -q '^REVIEW_BLOCKED' "$T/result.txt" 2>/dev/null && ok || bad "B7: a standing floor line is still REVIEW_BLOCKED (rc $RC)"
# Case 4: an ordinary human step that is NOT a go-live step under --golive note is a demoted note (standing 0) -> approved, no hold.
cat > "$T/build/review.md" <<EOF
Findings:
NEEDS_HUMAN: On a host with Chromium run npm run e2e
TIER: 2
VERDICT: BLOCK
EOF
rm -f "$T/result.txt" "$T/bplacer.txt"
OUT=$( . "$T/lensdrv.sh"; LENS_REFUSE review; echo "rc=$? sfx=[$NH_GOLIVE_SUFFIX]" )
grep -q '^rc=0 sfx=\[\]$' <<<"$OUT" && ok || bad "B8: a verification this box cannot run approves with no hold, got '$OUT'"
[ ! -e "$T/bplacer.txt" ] && ok || bad "B8: no placer call for a demoted verification"

echo "golive-hold.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
