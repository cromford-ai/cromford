#!/bin/bash
# tests/blocked-resolver-provenance.bh-3630-test.sh — BH-3630: a `provenance`
# park the conductor saw APPROVE + CI red on is the resolver's (ci-red ladder),
# and every other BLOCKED_HUMAN reason the resolver has no rung for says so
# instead of being dropped without a word.
#
# WHAT HAPPENED (2026-09-30). example-org/project-7#530 sat BLOCKED_HUMAN
# `provenance (verdict=APPROVE ci=red …)` for 5370 minutes. br_reason_of
# answered "" for `provenance`, br_from_conductor's `[ -n "$reason" ] ||
# continue` dropped the row, and logs/blocked-resolver.log never named #530.
#
# THE ACCEPTANCE ROWS (plan R1-R8):
#   R1  provenance-ci-red maps to the ci-red ladder; a bare `provenance` does not.
#   R2  every reason that mapped before still maps to the same class and action,
#       in BOTH reads (the resolver corpus and bin/lib/br/ladder.sh; BH-5241
#       cut the inline copy, so the corpus finds the module's).
#   R3  a whole tick: provenance row + the conductor's APPROVE/red detail on the
#       row's head -> candidate `provenance-ci-red`, the ladder's first ci-red
#       rung, and a resolver claim for that head.
#   R4  the other provenance shapes: no candidate, no claim, ONE
#       `provenance-skip` line per PR per window.
#   R5  unmapped reasons: one `unmapped-reason` line per PR, ONE warn alert per
#       family, both deduped inside BR_UNMAPPED_WINDOW_S and repeated after it.
#   R6  a contested loser stays silent; a reason with parens does not crash.
#   R7  the CI repair cap counts provenance-ci-red rounds.
#   R8  br_record refreshes a claim's active_at and creates none.
#
# Run from anywhere: tests/blocked-resolver-provenance.bh-3630-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

# ============================================================================
# R1 / R2 — the classifier, pure, in both copies.
# ============================================================================
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
extract() { # extract <file> <fn>...
  local f="$1"; shift
  for fn in "$@"; do awk -v F="^$fn\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$f"; done
}
for src in "$T/br-corpus.sh" "$DIR/bin/lib/br/ladder.sh"; do
  extract "$src" br_ladder_class br_action br_reason_of > "$T/cls.sh"
  [ "$(grep -c '^br_.*() {' "$T/cls.sh")" = 3 ] && ok || bad "could not extract the classifier from $src"
  C() { bash -c '. "$0"; "$@"' "$T/cls.sh" "$@"; }
  n=$(basename "$src")
  # R1
  [ "$(C br_reason_of 'provenance-ci-red: verdict=APPROVE ci=red head=abc')" = provenance-ci-red ] && ok \
    || bad "R1 $n: br_reason_of must map the provenance-ci-red word (got '$(C br_reason_of 'provenance-ci-red: x')')"
  [ "$(C br_ladder_class provenance-ci-red)" = ci-red ] && ok \
    || bad "R1 $n: provenance-ci-red must be the ci-red ladder class (got '$(C br_ladder_class provenance-ci-red)')"
  [ "$(C br_action provenance-ci-red)" = ladder ] && ok \
    || bad "R1 $n: provenance-ci-red must go to the ladder (got '$(C br_action provenance-ci-red)')"
  [ "$(BR_LADDER=0 C br_action provenance-ci-red)" = rebuild-fresh ] && ok \
    || bad "R1 $n: with BR_LADDER=0 it must answer what red-ci-twice answers there (got '$(BR_LADDER=0 C br_action provenance-ci-red)')"
  [ -z "$(C br_reason_of provenance)" ] && ok \
    || bad "R1 $n: a BARE provenance must stay unmapped — only the conductor's detail may promote it"
  [ -z "$(C br_reason_of 'provenance (verdict=APPROVE ci=red)')" ] && ok \
    || bad "R1 $n: the page text alone must not promote a provenance park"
  # R2 — the BEFORE table, captured from main b8506fa2 before this change.
  while IFS='|' read -r raw word cls act act0; do
    [ -n "$raw" ] || continue
    got="$(C br_reason_of "$raw: detail")|$(C br_ladder_class "$word")|$(C br_action "$word")|$(BR_LADDER=0 C br_action "$word")"
    [ "$got" = "$word|$cls|$act|$act0" ] && ok || bad "R2 $n: '$raw' changed: want '$word|$cls|$act|$act0', got '$got'"
  done <<'TABLE'
conflict-unresolvable|conflict-unresolvable|rebase-conflict|ladder|rebuild-fresh
rebase-gate-red|rebase-gate-red|rebase-conflict|ladder|rebuild-fresh
red-ci-twice|red-ci-twice|ci-red|ladder|rebuild-fresh
red-twice|red-twice|ci-red|ladder|rebuild-fresh
queue-ejected-twice|queue-ejected-twice|ci-red|ladder|rebuild-fresh
head-not-reapproved|head-not-reapproved|review-blocked|ladder|fix-round
orphaned-child|orphaned-child|orphaned-parent|ladder|fix-round
review-changes-requested|review-changes-requested||fix-round|fix-round
iron-law|iron-law||adjudicate|adjudicate
no-verdict|no-verdict||re-review|re-review
pr-create-failed|pr-create-failed||rebuild-fresh|rebuild-fresh
abandoned-timeout|abandoned-timeout||rebuild-fresh|rebuild-fresh
rebuild-build-dead|rebuild-build-dead||rebuild-fresh|rebuild-fresh
rebuild-decompose-failed|rebuild-decompose-failed||abandon-rebuild|abandon-rebuild
rebuild-plan-blocked|rebuild-plan-blocked||abandon-rebuild|abandon-rebuild
rebuild-review-blocked|rebuild-review-blocked||abandon-rebuild|abandon-rebuild
rebuild-enqueue-failed|rebuild-enqueue-failed||rebuild-retry|rebuild-retry
merge-failed-twice|merge-failed-twice||rebuild-fresh|rebuild-fresh
queue-enqueue-failed-twice|queue-enqueue-failed-twice||rebuild-fresh|rebuild-fresh
TABLE
  for r in tightened contested static-guards-red; do
    [ -z "$(C br_reason_of "$r: x")" ] && ok || bad "R2 $n: '$r' must stay unmapped in br_reason_of"
  done
done

# ============================================================================
# R7 — the CI repair cap counts these rounds (bin/lib/br/opt/cirepair.sh).
# ============================================================================
extract "$DIR/bin/lib/br/opt/cirepair.sh" br_ci_lineage_rounds > "$T/cir.sh"
REC='{"attempts":[{"action":"fix-round","reason":"provenance-ci-red","detail":"pushed deadbeef to ticket/TK-9"},{"action":"fix-round","reason":"tightened","detail":"pushed cafebabe to x"}]}'
got=$(bash -c '. "$0"; br_ci_lineage_rounds "$1" 0' "$T/cir.sh" "$REC")
[ "$(grep -c . <<<"$got")" = 1 ] && grep -q provenance-ci-red <<<"$got" && ok \
  || bad "R7: exactly the provenance-ci-red fix round must count toward BR_CI_REPAIR_ROUNDS (got: $got)"

# ============================================================================
# The whole-lane fixture for R3-R6 and R8.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1              # impact: this suite runs when bin/lib/br/ changes
[ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1  # impact: the prov-detail and claim helpers live there
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
LOGF="$H/logs/blocked-resolver.log"
MCS="$H/state/merge-conductor"
HEADX=abc123abc123abc123abc123abc123abc123abc1
URL530="https://github.com/o/tproj/pull/530"

# ROWS <key|reason> ... — pr-state.tsv with one BLOCKED_HUMAN row per argument.
ROWS() {
  local a key why
  : > "$MCS/pr-state.tsv"
  for a in "$@"; do
    key="${a%%|*}"; why="${a#*|}"
    printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$key" "$NOW" "$HEADX" "$HEADX" "$why" \
      "https://github.com/o/tproj/pull/${key##*#}" >> "$MCS/pr-state.tsv"
  done
}
DETAIL() { # DETAIL <key-id> <head> <verdict> <ci>
  mkdir -p "$MCS/prov-detail"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$NOW" > "$MCS/prov-detail/$1"
}
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$MCS/prov-detail"
  scratch_rm "$MCS/resolver-claim"
  : > "$LOGF"; : > "$T/lane-alert.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"
}
UNMAPPED_ALERTS() { grep -c -- 'br-unmapped' "$T/lane-alert.txt" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# R3 — APPROVE + red on the row's head: the ci-red ladder, and a claim.
# ---------------------------------------------------------------------------
FRESH
ROWS "o/tproj#530|provenance"
DETAIL o_tproj_530 "$HEADX" APPROVE red
RUN
grep -q 'provenance-ci-red/ci-red.: ladder rung: mechanical' "$LOGF" && ok \
  || bad "R3: an APPROVE + ci=red provenance park must enter the ci-red ladder at rung 1 (log: $(tail -5 "$LOGF"))"
grep -q 'provenance-ci-red.* -> mechanical' "$LOGF" && ok \
  || bad "R3: the dispatch line must name provenance-ci-red and the mechanical rung (log: $(tail -5 "$LOGF"))"
CLAIM="$MCS/resolver-claim/o_tproj_530"
STATEJSON tproj-TK-9 | jq -e '[.attempts[]? | select(.reason | startswith("provenance-ci-red"))] | length > 0' >/dev/null && ok \
  || bad "R3: the resolver record must carry an attempt whose reason is provenance-ci-red (record: $(STATEJSON tproj-TK-9))"
[ -s "$CLAIM" ] && [ "$(cut -f1 "$CLAIM")" = "$HEADX" ] && [ "$(cut -f2 "$CLAIM")" = provenance-ci-red ] && ok \
  || bad "R3: the resolver must claim the park on its head (claim: $(cat "$CLAIM" 2>/dev/null || echo none))"
grep -q 'provenance-skip\|unmapped-reason' "$LOGF" && bad "R3: a promoted park must not also log a skip (log: $(grep 'skip\|unmapped' "$LOGF"))" || ok
[ "$(UNMAPPED_ALERTS)" = 0 ] && ok || bad "R3: a promoted park raises no unmapped alert"

# --- the same row in OBSERVE mode: it acts on nothing, so it claims nothing ---
FRESH
ROWS "o/tproj#530|provenance"
DETAIL o_tproj_530 "$HEADX" APPROVE red
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ -e "$CLAIM" ] && bad "R3 observe: an observe-mode resolver must not claim a park (claim: $(cat "$CLAIM"))" || ok

# ---------------------------------------------------------------------------
# R4 — every other provenance shape: skipped, said once per window, no claim.
# ---------------------------------------------------------------------------
for c in "- red" "APPROVE pending" "nodetail" "otherhead"; do
  FRESH
  ROWS "o/tproj#530|provenance"
  case "$c" in
    nodetail)  : ;;
    otherhead) DETAIL o_tproj_530 ffffffffffffffffffffffffffffffffffffffff APPROVE red ;;
    *)         DETAIL o_tproj_530 "$HEADX" ${c% *} ${c#* } ;;
  esac
  RUN
  n=$(grep -c 'provenance-skip o/tproj#530:' "$LOGF")
  [ "$n" = 1 ] && ok || bad "R4 '$c': exactly ONE provenance-skip line (got $n; log: $(tail -3 "$LOGF"))"
  case "$c" in
    "- red")         grep -q 'provenance-skip o/tproj#530: .*verdict=- ci=red' "$LOGF" && ok || bad "R4 '$c': the skip line must name the verdict/ci words (log: $(grep provenance-skip "$LOGF"))" ;;
    "APPROVE pending") grep -q 'provenance-skip o/tproj#530: .*verdict=APPROVE ci=pending' "$LOGF" && ok || bad "R4 '$c': the skip line must name the verdict/ci words (log: $(grep provenance-skip "$LOGF"))" ;;
    nodetail|otherhead) grep -q 'provenance-skip o/tproj#530: no conductor detail for head abc123ab' "$LOGF" && ok || bad "R4 '$c': the skip line must say there is no detail for this head (log: $(grep provenance-skip "$LOGF"))" ;;
  esac
  grep -q 'ladder rung' "$LOGF" && bad "R4 '$c': no rung may be offered (log: $(grep 'ladder rung' "$LOGF"))" || ok
  [ -e "$CLAIM" ] && bad "R4 '$c': no claim may be written" || ok
  [ "$(UNMAPPED_ALERTS)" = 0 ] && ok || bad "R4 '$c': a provenance skip is a log line, not an alert (alerts: $(cat "$T/lane-alert.txt"))"
  RUN
  n=$(grep -c 'provenance-skip o/tproj#530:' "$LOGF")
  [ "$n" = 1 ] && ok || bad "R4 '$c': a second tick inside the window adds no line (got $n)"
done

# ---------------------------------------------------------------------------
# R5 — unmapped reasons: a line per PR, one warn alert per family, deduped.
# ---------------------------------------------------------------------------
FRESH
ROWS "o/tproj#601|tightened: revert rate 0.4 over 0.3" "o/tproj#602|static-guards-red" "o/tproj#603|tightened"
RC5=0
( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
    bash "$H/bin/blocked-resolver.sh" >>"$T/run.log" 2>&1 ) || RC5=$?
[ "$RC5" = 0 ] && ok || bad "R5: the tick must exit 0 with unmapped rows (rc $RC5; $(tail -3 "$T/run.log"))"
for k in 601 603; do
  [ "$(grep -c "unmapped-reason tightened o/tproj#$k:" "$LOGF")" = 1 ] && ok \
    || bad "R5: one unmapped-reason line for tightened #$k (log: $(grep unmapped "$LOGF"))"
done
[ "$(grep -c 'unmapped-reason static-guards-red o/tproj#602:' "$LOGF")" = 1 ] && ok \
  || bad "R5: one unmapped-reason line for static-guards-red #602 (log: $(grep unmapped "$LOGF"))"
[ "$(UNMAPPED_ALERTS)" = 2 ] && ok || bad "R5: exactly two alerts, one per family (got: $(cat "$T/lane-alert.txt"))"
grep -q -- '--severity warn --id br-unmapped-tightened ' "$T/lane-alert.txt" && ok || bad "R5: the tightened family's alert is warn, id br-unmapped-tightened (got: $(cat "$T/lane-alert.txt"))"
grep -q -- '--severity warn --id br-unmapped-static-guards-red ' "$T/lane-alert.txt" && ok || bad "R5: the static-guards-red family's alert is warn (got: $(cat "$T/lane-alert.txt"))"
grep -q -- '--critical' "$T/lane-alert.txt" && bad "R5: an unmapped reason is never critical (got: $(cat "$T/lane-alert.txt"))" || ok
RUN
[ "$(grep -c 'unmapped-reason' "$LOGF")" = 3 ] && ok || bad "R5: a second tick inside the window adds no line (got $(grep -c unmapped-reason "$LOGF"))"
[ "$(UNMAPPED_ALERTS)" = 2 ] && ok || bad "R5: and no alert (got $(UNMAPPED_ALERTS))"
# Back-date every stamp past the window: one more line per PR, one alert per family.
OLD=$((NOW - 21601))
for f in "$H/state/blocked-resolver/unmapped/"* "$H/state/blocked-resolver/unmapped-family/"*; do
  [ -f "$f" ] && printf '%s\n' "$OLD" > "$f"
done
RUN
[ "$(grep -c 'unmapped-reason' "$LOGF")" = 6 ] && ok || bad "R5: past the window each PR says so once more (got $(grep -c unmapped-reason "$LOGF"))"
[ "$(UNMAPPED_ALERTS)" = 4 ] && ok || bad "R5: past the window each family alerts once more (got $(UNMAPPED_ALERTS))"
# The window is the knob: 600s makes a 700s-old stamp stale.
for f in "$H/state/blocked-resolver/unmapped/"* "$H/state/blocked-resolver/unmapped-family/"*; do
  [ -f "$f" ] && printf '%s\n' "$((NOW - 700))" > "$f"
done
BRENV=(BR_UNMAPPED_WINDOW_S=600)
RUN
BRENV=()
[ "$(grep -c 'unmapped-reason' "$LOGF")" = 9 ] && ok || bad "R5: BR_UNMAPPED_WINDOW_S must set the window (got $(grep -c unmapped-reason "$LOGF"))"

# ---------------------------------------------------------------------------
# R6 — the contested loser stays silent; a reason with parens is safe.
# ---------------------------------------------------------------------------
FRESH
ROWS "o/tproj#610|contested: lost path x.ts to TK-1" "o/tproj#611|weird (x) thing"
RC6=0
( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
    bash "$H/bin/blocked-resolver.sh" >>"$T/run.log" 2>&1 ) || RC6=$?
[ "$RC6" = 0 ] && ok || bad "R6: rc 0 (got $RC6)"
grep -E 'unmapped-reason|provenance-skip' "$LOGF" | grep -c 'o/tproj#610' >/dev/null \
  && bad "R6: a contested loser must write no unmapped line (log: $(grep 610 "$LOGF"))" || ok
grep -q 'br-unmapped-contested' "$T/lane-alert.txt" && bad "R6: and raise no alert" || ok
grep -q 'unmapped-reason weird o/tproj#611: weird (x) thing' "$LOGF" && ok \
  || bad "R6: a reason with parens has family 'weird' (log: $(grep unmapped "$LOGF"))"
grep -q -- '--id br-unmapped-weird ' "$T/lane-alert.txt" && ok || bad "R6: its alert id is the sanitised family (got: $(cat "$T/lane-alert.txt"))"

# ---------------------------------------------------------------------------
# R8 — br_record touches a claim (both copies) and creates none.
# ---------------------------------------------------------------------------
{ printf 'HARNESS="%s"; H="%s"; ST="%s/state/blocked-resolver"\n' "$H" "$H" "$H"
  printf '. "%s/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1\n' "$H"
  printf "STAMP() { date -u '+%%Y-%%m-%%d %%H:%%M:%%SZ'; }\n"
  printf '. "%s/bin/lib/br/record.sh"\n' "$H"
  extract "$H/bin/blocked-resolver.sh" br_slug_of_url
} > "$T/rec-lib.sh"
{ cat "$T/rec-lib.sh"; extract "$H/bin/blocked-resolver.sh" br_record; } > "$T/rec-inline.sh"
for v in rec-lib rec-inline; do
  FRESH
  mkdir -p "$MCS/resolver-claim"
  C0=$((NOW - 5000)); A0=$((NOW - 4000))
  printf '%s\tprovenance-ci-red\t%s\t%s\t-\t-\n' "$HEADX" "$C0" "$A0" > "$CLAIM"
  bash -c '. "$0"; br_record tproj tproj-TK-9 fix-round provenance-ci-red "pushed deadbeef" fixrounds "$1"' \
    "$T/$v.sh" "$URL530" 2>>"$T/run.log"
  a=$(cut -f4 "$CLAIM"); c=$(cut -f3 "$CLAIM")
  [ "${a:-0}" -ge "$NOW" ] 2>/dev/null && ok || bad "R8 $v: br_record must refresh active_at to now (claim: $(cat "$CLAIM"))"
  [ "$c" = "$C0" ] && ok || bad "R8 $v: claimed_at must not move (claim: $(cat "$CLAIM"))"
  [ "$(STATEJSON tproj-TK-9 | jq -r .fixrounds)" = 1 ] && ok || bad "R8 $v: the record itself is still written"
  rm -f "$CLAIM"
  bash -c '. "$0"; br_record tproj tproj-TK-9 fix-round provenance-ci-red "pushed deadbeef" fixrounds "$1"' \
    "$T/$v.sh" "$URL530" 2>>"$T/run.log"
  [ -e "$CLAIM" ] && bad "R8 $v: with no claim, br_record must create none" || ok
done

echo "blocked-resolver-provenance.bh-3630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
