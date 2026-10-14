#!/bin/bash
# tests/br-prequeue-red.bh-4545-test.sh — BH-4549 (BH-4545 child 3 of 4): a PR
# the pre-queue gate parks `prequeue-red: <suites> on main <m12> — …` gets a
# resolver fix round that names the suites and the main sha.
#
# THE CONTRACT. bin/merge-conductor.sh's pre-queue gate parks a head whose
# selected suites fail when it is merged onto current main. That head is GREEN
# on its own PR CI, so the park must NOT be classed ci-red (br_supersede_guard
# declines a ci-red park whose head is green: `green-at-head`). It is its own
# ladder class `prequeue-red`, with no mechanical rung (the gate already ran
# exactly that merge), and br_fix_round's brief re-reads the raw park reason,
# which the hub copies onto the record as `.prequeue_reason` before the round
# hops to the owning box.
#
# Cases:
#   R1  br_reason_of maps the tracer form and the batch-solo form (inline + module)
#   R2  class / skips-mechanical / action / rung order, inline + module, and the
#       four functions byte-identical between the two
#   R3a br_prequeue_brief parses suites + sha, and falls back honestly
#   R3b the REAL script through --fix-here: the agent prompt names the suites + sha
#   R3c br_prequeue_note copies only a prequeue-red row's reason onto the record
#   R3d the REAL script: br_fix_round's own note call puts the row's reason on the record
#   R4  through the lane: a prequeue-red park with a GREEN head is not declined
#       green-at-head and is not left unmapped
#   N1  the ci-red family still classes ci-red; no `ci-red:` arm is invented
#   MR  the brief arm deleted from a copy -> R3b's assertion goes red
# Run from anywhere: tests/br-prequeue-red.bh-4545-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

TRACER="prequeue-red: tests/x.sh on main abc123def456 — the head merged onto current main fails them"
SOLO="prequeue-red: tests/x.sh (reproduced alone on abc123def456, batch #9)"

# ============================================================================
# R1 / R2 / N1 — the classifier, inline (extracted by name) and module (sourced)
# ============================================================================
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
INLINE="$T/inline.sh"; : > "$INLINE"
for fn in br_ladder_class br_skips_mechanical br_ladder_rung br_action br_reason_of; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$INLINE"
done
MODULE="$DIR/bin/lib/br/ladder.sh"
for fn in br_ladder_class br_skips_mechanical br_ladder_rung br_action br_reason_of; do
  grep -q "^$fn()" "$INLINE" || bad "setup: $fn not extracted from bin/blocked-resolver.sh"
done
call() { bash -c '. "$0"; shift; "$@"' "$1" x "${@:2}" 2>/dev/null; }

for side in inline module; do
  src="$INLINE"; [ "$side" = module ] && src="$MODULE"
  got=$(call "$src" br_reason_of "$TRACER")
  [ "$got" = prequeue-red ] && ok "R1a[$side]: tracer reason -> prequeue-red" || bad "R1a[$side]: tracer reason -> '${got:-empty}'"
  got=$(call "$src" br_reason_of "$SOLO")
  [ "$got" = prequeue-red ] && ok "R1b[$side]: batch-solo reason -> prequeue-red" || bad "R1b[$side]: batch-solo reason -> '${got:-empty}'"
  got=$(call "$src" br_reason_of "prequeue-pending: gate running")
  [ -z "$got" ] && ok "R1c[$side]: prequeue-pending (the hold word) is not mapped" || bad "R1c[$side]: prequeue-pending -> '$got', want empty"

  got=$(call "$src" br_ladder_class prequeue-red)
  [ "$got" = prequeue-red ] && ok "R2[$side]: class prequeue-red (not ci-red)" || bad "R2[$side]: class '${got:-empty}', want prequeue-red"
  call "$src" br_skips_mechanical prequeue-red && ok "R2[$side]: skips-mechanical rc 0" || bad "R2[$side]: br_skips_mechanical prequeue-red rc != 0"
  got=$(call "$src" br_action prequeue-red)
  [ "$got" = ladder ] && ok "R2[$side]: br_action -> ladder" || bad "R2[$side]: br_action -> '${got:-empty}'"
  got=$(call "$src" br_ladder_rung prequeue-red 0 0 1)
  [ "$got" = fix-round ] && ok "R2[$side]: rung 0/0 -> fix-round (no mechanical)" || bad "R2[$side]: rung 0/0 -> '${got:-empty}', want fix-round"
  got=$(call "$src" br_ladder_rung prequeue-red 0 1 1)
  [ "$got" = rebuild-fresh ] && ok "R2[$side]: rung 0/cap -> rebuild-fresh" || bad "R2[$side]: rung 0/cap -> '${got:-empty}'"

  for r in "red-twice: x" "queue-ejected-twice — x" "red-ci-twice: x"; do
    got=$(call "$src" br_ladder_class "$(call "$src" br_reason_of "$r")")
    [ "$got" = ci-red ] && ok "N1[$side]: '$r' still classes ci-red" || bad "N1[$side]: '$r' classes '${got:-empty}', want ci-red"
  done
  got=$(call "$src" br_reason_of "ci-red: x")
  [ -z "$got" ] && ok "N1[$side]: no 'ci-red:' arm invented" || bad "N1[$side]: 'ci-red: x' -> '$got', want empty"
done
for fn in br_ladder_class br_skips_mechanical br_ladder_rung br_reason_of; do
  a=$(bash -c '. "$0"; declare -f "$1"' "$INLINE" "$fn" 2>/dev/null)
  b=$(bash -c '. "$0"; declare -f "$1"' "$MODULE" "$fn" 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "R2: $fn byte-identical inline vs module" || bad "R2: $fn differs between inline and module"
done

# ============================================================================
# R3a — br_prequeue_brief, extracted by name
# ============================================================================
awk '/^br_prequeue_brief\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brief.sh"
if grep -q '^br_prequeue_brief()' "$T/brief.sh"; then
  ok "R3a: br_prequeue_brief extracted"
  b=$(call "$T/brief.sh" br_prequeue_brief "$TRACER")
  grep -qF 'tests/x.sh' <<<"$b" && grep -qF abc123def456 <<<"$b" \
    && grep -qF 'bin/test-impact-gate.sh --base origin/main' <<<"$b" \
    && grep -qF 'These suites fail when this head is merged onto current main abc123def456: tests/x.sh.' <<<"$b" \
    && ok "R3a: tracer reason -> suites, sha and the gate command" || bad "R3a: tracer brief wrong: $b"
  b=$(call "$T/brief.sh" br_prequeue_brief "$SOLO")
  grep -qF 'current main abc123def456: tests/x.sh.' <<<"$b" \
    && ok "R3a: batch-solo reason -> suites and sha" || bad "R3a: batch-solo brief wrong: $b"
  b=$(call "$T/brief.sh" br_prequeue_brief "prequeue-red: tests/a.sh,tests/b.sh on main 0123456789ab — the head merged onto current main fails them")
  grep -qF 'current main 0123456789ab: tests/a.sh,tests/b.sh.' <<<"$b" \
    && ok "R3a: multiple suites pass through verbatim" || bad "R3a: multi-suite brief wrong: $b"
  for raw in "" "prequeue-red: garbage" "prequeue-red:  on main abc123def456 — x"; do
    b=$(call "$T/brief.sh" br_prequeue_brief "$raw")
    if [ -n "$b" ] && grep -qF 'could not be re-read here' <<<"$b" && ! grep -qF garbage <<<"$b" \
       && ! grep -qE '[0-9a-f]{7,}' <<<"$b"; then
      ok "R3a: unparseable '$raw' -> the honest fallback, no suite or sha invented"
    else
      bad "R3a: unparseable '$raw' -> '$b'"
    fi
  done
else
  bad "R3a: br_prequeue_brief is not defined in bin/blocked-resolver.sh"
fi

# ============================================================================
# R3c — br_prequeue_note, extracted with its reads and write stubbed
# ============================================================================
awk '/^br_prequeue_note\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/note.sh"
cat >> "$T/note.sh" <<EOF
br_slug_of_url() { printf 'o/tproj'; }
mc_num_of_url() { printf '91'; }
mc_row_field() { [ "\$1" = 'o/tproj#91' ] && [ "\$2" = 7 ] && cat "$T/why" 2>/dev/null; }
br_set_field() { printf '%s|%s|%s|%s\n' "\$@" >> "$T/set.txt"; }
EOF
if grep -q '^br_prequeue_note()' "$T/note.sh"; then
  printf '%s' "$TRACER" > "$T/why"; : > "$T/set.txt"
  call "$T/note.sh" br_prequeue_note tproj pq-1 https://github.com/o/tproj/pull/91
  [ "$(cat "$T/set.txt")" = "tproj|pq-1|prequeue_reason|$TRACER" ] \
    && ok "R3c: a prequeue-red row's reason is copied onto the record" || bad "R3c: set calls: $(cat "$T/set.txt")"
  printf 'red-twice: still red on abc' > "$T/why"; : > "$T/set.txt"
  call "$T/note.sh" br_prequeue_note tproj pq-1 https://github.com/o/tproj/pull/91
  [ ! -s "$T/set.txt" ] && ok "R3c: a red-twice row writes nothing" || bad "R3c: red-twice row wrote: $(cat "$T/set.txt")"
  rm -f "$T/why"; : > "$T/set.txt"
  call "$T/note.sh" br_prequeue_note tproj pq-1 https://github.com/o/tproj/pull/91
  [ ! -s "$T/set.txt" ] && ok "R3c: an unreadable row writes nothing" || bad "R3c: empty read wrote: $(cat "$T/set.txt")"
else
  bad "R3c: br_prequeue_note is not defined in bin/blocked-resolver.sh"
fi

# ============================================================================
# R3b / MR — the real script through --fix-here (bin/fix-round-claim.sh's entry)
# ============================================================================
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
cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# The agent records the prompt it was handed (argv 6 of agent-call.sh execute).
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

PR91="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$1" --fix-here tproj pq-1 prequeue-red "$PR91" - - < "$T/rec-in.json" ) 2>>"$T/run.log"; }
RESET() { # RESET [prequeue_reason]
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/lane-gate"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/all-off" "$H/flags/lane-off-"* "$H/flags/blocked-resolver-"* "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$H/logs/ALERTS.log"; rm -f "$T/prompt.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 | tr -d '\n' > "$T/prhead"
  : > "$T/findings"
  if [ $# -gt 0 ]; then
    jq -nc --arg r "$1" '{project:"tproj",rkey:"pq-1",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[],prequeue_reason:$r}' > "$T/rec-in.json"
  else
    jq -nc '{project:"tproj",rkey:"pq-1",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
  fi
}

RESET "$TRACER"
FIXHERE "$H/bin/blocked-resolver.sh" >/dev/null
if [ -s "$T/prompt.txt" ]; then
  ok "R3b: the prequeue-red round reached the agent"
  grep -qF 'tests/x.sh' "$T/prompt.txt" && grep -qF abc123def456 "$T/prompt.txt" \
    && ok "R3b: the prompt names tests/x.sh and abc123def456" || bad "R3b: the prompt lacks the suites/sha"
  grep -qF 'bin/test-impact-gate.sh --base origin/main' "$T/prompt.txt" \
    && ok "R3b: the prompt tells the agent to run the impact gate" || bad "R3b: no impact-gate instruction in the prompt"
else
  bad "R3b: the prequeue-red round never reached the agent (log: $(tail -3 "$LOGF"))"
fi
grep -q 'EVENT resolver_rung .*rung 2 fix-round on .*prequeue' "$LOGF" 2>/dev/null \
  && ok "R3b: the rung event says the prequeue brief fired" || bad "R3b: no 'prequeue' in the rung event"

# The record carries no prequeue_reason (the row moved on): the round still
# runs, on the honest fallback, never on a drop to REBUILD FRESH.
RESET
FIXHERE "$H/bin/blocked-resolver.sh" >/dev/null
if [ -s "$T/prompt.txt" ] && grep -qF 'could not be re-read here' "$T/prompt.txt" && ! grep -qF abc123def456 "$T/prompt.txt"; then
  ok "R3b: no prequeue_reason -> the round runs on the fallback brief"
else
  bad "R3b: no prequeue_reason -> no fallback round (log: $(tail -3 "$LOGF"))"
fi

# R3d: the record carries no copy but the conductor row still reads
# prequeue-red: br_fix_round's own br_prequeue_note call (the one that runs
# before the hub hop) copies the raw reason onto the record.
RESET
printf 'o/tproj#91\tBLOCKED_HUMAN\t%s\tabc\tabc\t-\t%s\t%s\n' "$(date -u +%s)" "$TRACER" "$PR91" \
  > "$H/state/merge-conductor/pr-state.tsv"
FIXHERE "$H/bin/blocked-resolver.sh" >/dev/null
got=$(jq -r '.prequeue_reason // empty' "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null | head -1)
[ "$got" = "$TRACER" ] && ok "R3d: br_fix_round copies the row's raw reason onto the record" \
  || bad "R3d: record .prequeue_reason = '${got:-empty}' (log: $(tail -3 "$LOGF"))"
: > "$H/state/merge-conductor/pr-state.tsv"

# MR: the brief arm deleted from a copy -> R3b's assertion goes red.
sed '/if \[ "\$(br_ladder_class "\$reason")" = prequeue-red \]; then/,/^  fi$/d' "$H/bin/blocked-resolver.sh" > "$H/bin/blocked-resolver.mut.sh"
if cmp -s "$H/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.mut.sh"; then
  bad "MR: the mutation changed nothing — the prequeue-red brief arm is not in bin/blocked-resolver.sh"
else
  RESET "$TRACER"
  FIXHERE "$H/bin/blocked-resolver.mut.sh" >/dev/null
  if grep -qF abc123def456 "$T/prompt.txt" 2>/dev/null; then
    bad "MR: R3b still passes with the brief arm deleted"
  else
    ok "MR: deleting the brief arm turns R3b red"
  fi
fi

# ============================================================================
# R4 — through the lane: a prequeue-red park whose head is GREEN
# ============================================================================
# The BH-1671 fixture: rungs spent for TK-9, so the park reaches rung 3 where
# br_supersede_guard runs, and a green head would be declined if this park were
# classed ci-red. It must instead be read, mapped and rebuilt like any red park.
cp "$DIR/bin/lib/ticket-ownership.sh" "$H/bin/lib/" || exit 1
cat > "$H/bin/lib/verdicts.sh" <<'EOF'
vd_standing() { [[ "$3" =~ ^[0-9a-f]{40}$ ]] || return 2; return 1; }
vd_clear_word() { return 1; }
EOF
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"
mv "$T/fakebin/gh" "$T/fakebin/gh.real"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET"*"actions/runs?head_sha="*)
    a="\$*"; sha=\${a##*head_sha=}; sha=\${sha%%&*}; sha=\${sha%% *}
    if [ -f "$T/ciruns-\$sha" ]; then restpr --runs - < "$T/ciruns-\$sha"; exit 0; fi ;;
esac
exec "$T/fakebin/gh.real" "\$@"
EOF
chmod +x "$T/fakebin/gh"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
scratch_rm "$H/state/blocked-resolver"
SPENT tproj-TK-9
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
scratch_rm "$H/state/merge-conductor/handoff"
scratch_rm "$H/state/merge-conductor/handoff-released"
printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
echo OPEN > "$T/prstate"; printf '%s' "$B" > "$T/prhead"
printf 'completed|success\n' > "$T/ciruns-$B"
printf 'o/tproj#9\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$(date -u +%s)" "$B" "$B" \
  "prequeue-red: tests/x.sh on main abc123def456 — the head merged onto current main fails them" \
  "https://github.com/o/tproj/pull/9" > "$H/state/merge-conductor/pr-state.tsv"
RUN
grep -q 'SKIP green-at-head' "$LOGF" && bad "R4: a prequeue-red park must not be declined green-at-head ($(grep 'green-at-head' "$LOGF" | head -1))" \
  || ok "R4: no green-at-head decline on a green prequeue-red head"
grep -q 'unmapped-reason.*o/tproj#9' "$LOGF" && bad "R4: the park was left unmapped" || ok "R4: the park is mapped, not left to the conductor"
grep -q -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null && grep -q '^tproj TK-9 ' "$T/queue.txt" \
  && ok "R4: the spent ladder takes rung 3 (superseded, fresh build enqueued)" \
  || bad "R4: rung 3 did not run (log: $(tail -3 "$LOGF"))"

echo "br-prequeue-red.bh-4545: $PASS passed, $FAIL failed"
exit $((FAIL>0))
