#!/bin/bash
# tests/br-fix-cap-row.bh-7123-test.sh — the review fix-round cap reads the
# settings row (BH-7123 wave B, C1). `review.fix_rounds_max` (seeded 2 by wave A,
# per project `review.fix_rounds_max.<p>`) is what bin/lib/br/record.sh's
# br_fix_cap answers for a review-changes-requested park, and what
# bin/lib/review-tier.sh's review_tier_cap answers for an in-build T2 lens. In
# review.mode cowboy or off the cap is 0: no fix round at all.
#   §R  br_fix_cap reads the row: per project, then fleet, then the registry
#       knob BR_REVIEW_FIX_ROUNDS, then 2; cowboy / off -> 0; the shape caps of
#       every other reason are byte-for-byte what they were
#   §T  review_tier_cap: T2 reads the same row; T0/T1 unchanged; no lib -> 0
#   §E  bin/blocked-resolver.sh applies the lane env PER PROJECT inside the
#       candidate loop (br_env_for_project): a project row wins for its rows,
#       the next project without one reads the fleet value again, and the
#       tick-budget knobs stay fleet-wide whatever a project row says
#   §M  the prepass mirror and the fix round pass the project to the cap
# Run from anywhere: bash tests/br-fix-cap-row.bh-7123-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
: > "$T/cap.sh"
for fn in br_shape br_num br_fix_cap br_review_fix_cap; do
  # index(), not a regex: BSD awk reads `\(` in -v as `(`, so `^br_fix_cap()`
  # would match a longer name first. The exact `name() ` prefix cannot.
  awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/cap.sh"
done
grep -q '^br_review_fix_cap()' "$T/cap.sh" && ok || bad "R0: bin/lib/br/record.sh has no br_review_fix_cap"
grep -q '^br_fix_cap()' "$T/cap.sh" && ok || bad "R0: could not extract br_fix_cap"

# The settings rows a scratch box would read: <key>\t<value>, no worker.
ROWS="$T/rows.tsv"
cat > "$ROWS" <<'EOF'
review.fix_rounds_max.p1	4
review.fix_rounds_max	3
review.mode.p2	cowboy
review.mode.p3	off
EOF
cat > "$T/stub.sh" <<EOF
setting_get() { local v; v=\$(awk -F'\t' -v k="\$1" '\$1==k {print \$2; exit}' "$ROWS"); [ -n "\$v" ] || return 2; printf '%s' "\$v"; }
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a log stamp the stub's say lines carry; no assertion reads it
export HARNESS="$DIR"
. "$DIR/bin/lib/review-level.sh"
. "$T/cap.sh"
EOF
# cap <env...> <json> <reason> [project]
cap() { ( unset BR_REVIEW_FIX_ROUNDS REVIEW_LEVEL_MODE MAX_FIXROUNDS MAX_FIXROUNDS_SMALL BR_MAX_FIXROUNDS BR_CONFLICT_FIX_ROUNDS BR_MAX_FIXROUNDS_SMALL
         while [ $# -gt 0 ]; do case "$1" in *=*) export "$1"; shift ;; *) break ;; esac; done
         . "$T/stub.sh"; br_fix_cap "$@" ); }

# ── §R: br_fix_cap reads the row ───────────────────────────────────────────
[ "$(cap '{}' review-changes-requested p1)" = 4 ] && ok || bad "R1: project row review.fix_rounds_max.p1=4 must win (got $(cap '{}' review-changes-requested p1))"
[ "$(cap '{}' review-changes-requested p0)" = 3 ] && ok || bad "R2: a project with no row reads the fleet row (3), got $(cap '{}' review-changes-requested p0)"
[ "$(cap '{}' review-changes-requested)" = 3 ] && ok || bad "R3: no project at all reads the fleet row (3), got $(cap '{}' review-changes-requested)"
sed -i.bak '/fix_rounds_max/d' "$ROWS" 2>/dev/null || sed -i '' '/fix_rounds_max/d' "$ROWS"; rm -f "$ROWS.bak"
[ "$(cap '{}' review-changes-requested p1)" = 2 ] && ok || bad "R4: no row anywhere -> the code default 2, got $(cap '{}' review-changes-requested p1)"
[ "$(cap BR_REVIEW_FIX_ROUNDS=5 '{}' review-changes-requested p1)" = 5 ] && ok || bad "R5: with no row the registry knob BR_REVIEW_FIX_ROUNDS is the fallback (5), got $(cap BR_REVIEW_FIX_ROUNDS=5 '{}' review-changes-requested p1)"
printf 'review.fix_rounds_max.p1\t4\n' >> "$ROWS"
[ "$(cap BR_REVIEW_FIX_ROUNDS=5 '{}' review-changes-requested p1)" = 4 ] && ok || bad "R6: the row outranks the env knob, got $(cap BR_REVIEW_FIX_ROUNDS=5 '{}' review-changes-requested p1)"
[ "$(cap '{}' review-changes-requested p2)" = 0 ] && ok || bad "R7: review.mode.p2=cowboy -> cap 0, got $(cap '{}' review-changes-requested p2)"
[ "$(cap '{}' review-changes-requested p3)" = 0 ] && ok || bad "R8: review.mode.p3=off -> cap 0, got $(cap '{}' review-changes-requested p3)"
[ "$(cap REVIEW_LEVEL_MODE=cowboy '{}' review-changes-requested p1)" = 0 ] && ok || bad "R9: the REVIEW_LEVEL_MODE env (rl_knob's override) -> 0, got $(cap REVIEW_LEVEL_MODE=cowboy '{}' review-changes-requested p1)"
[ "$(cap REVIEW_LEVEL_MODE=strict '{}' review-changes-requested p1)" = 4 ] && ok || bad "R10: strict keeps the row cap, got $(cap REVIEW_LEVEL_MODE=strict '{}' review-changes-requested p1)"
printf 'review.fix_rounds_max.p4\t12x\n' >> "$ROWS"
[ "$(cap '{}' review-changes-requested p4)" = 2 ] && ok || bad "R11: a row that is not 1-2 digits falls to the default, got $(cap '{}' review-changes-requested p4)"
# Every other reason keeps its shape-driven cap, project or not.
[ "$(cap '{"conflict_lines":0}' conflict-unresolvable p1)" = 1 ] && ok || bad "R12: large shape stays 1"
[ "$(cap '{"conflict_lines":300}' conflict-unresolvable p1)" = 2 ] && ok || bad "R13: small shape stays 2"
[ "$(cap '{"conflict_lines":5,"fixround_bonus":1}' '' p2)" = 3 ] && ok || bad "R14: the contested bonus still rides, even on a cowboy project (not a review park)"
[ "$(cap '{}' queue-dequeued p1)" = 1 ] && ok || bad "R15: queue-dequeued stays 1"
# Without the review-level lib at all (a scratch tree, br-contested's `pure`), the knob/default path stands.
[ "$(bash -c 'unset BR_REVIEW_FIX_ROUNDS; . "$0"; br_fix_cap "{}" review-changes-requested p1' "$T/cap.sh")" = 2 ] && ok \
  || bad "R16: no rl_knob on the box -> 2"
[ "$(bash -c 'BR_REVIEW_FIX_ROUNDS=7; . "$0"; br_fix_cap "{}" review-changes-requested' "$T/cap.sh")" = 7 ] && ok \
  || bad "R17: no rl_knob on the box -> the env knob"

# ── §T: review_tier_cap ────────────────────────────────────────────────────
tcap() { ( . "$T/stub.sh"; . "$DIR/bin/lib/review-tier.sh"; review_tier_cap "$@" ); }
printf 'review.fix_rounds_max\t3\n' >> "$ROWS"
[ "$(tcap T2 p1)" = 4 ] && ok || bad "T1: T2 reads the project row (4), got $(tcap T2 p1)"
[ "$(tcap T2 p0)" = 3 ] && ok || bad "T2: T2 reads the fleet row (3), got $(tcap T2 p0)"
[ "$(tcap T0 p1)" = 1 ] && ok || bad "T3: T0 stays 1"
[ "$(tcap T1 p1)" = 2 ] && ok || bad "T4: T1 stays 2"
[ "$(bash -c '. "$1"; review_tier_cap T2 p1' _ "$DIR/bin/lib/review-tier.sh")" = 0 ] && ok \
  || bad "T5: without the review-level lib T2 is 0 (uncapped), as before"
[ "$(tcap T9 p1)" = 4 ] && ok || bad "T6: an unknown tier reads the row like T2 (p1's row, 4), got $(tcap T9 p1)"

# ── §E: the lane env is applied per project ────────────────────────────────
: > "$T/env.sh"
awk '/^br_env_for_project\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/env.sh"
grep -q '^br_env_for_project()' "$T/env.sh" && ok || bad "E0: bin/blocked-resolver.sh has no br_env_for_project"
# The registry is read for the knob names; lane_env_apply is a stub that plays
# the settings rows: lane.blocked-resolver.<p>.<knob> and the fleet row.
cat > "$T/lanerows.tsv" <<'EOF'
p1	BR_REVIEW_FIX_ROUNDS	5
p1	BR_PER_TICK	40
p1	BR_MAX_FIXROUNDS	3
EOF
cat > "$T/envdrv.sh" <<EOF
H="$DIR"
lane_env_apply() {
  printf '%s %s\n' "\$1" "\${2:-}" >> "$T/apply.txt"
  local rp re rv
  while IFS=\$'\t' read -r rp re rv; do
    [ "\$rp" = "\${2:-}" ] && export "\$re=\$rv"
  done < "$T/lanerows.tsv"
}
say() { printf '%s\n' "\$*" >> "$T/say.txt"; }
. "$T/env.sh"
export BR_PER_TICK=4 BR_REVIEW_FIX_ROUNDS=2 BR_MAX_FIXROUNDS=1
MAX_FIXROUNDS="\${BR_MAX_FIXROUNDS:-1}"
br_env_for_project p1; echo "p1 rfr=\$BR_REVIEW_FIX_ROUNDS tick=\$BR_PER_TICK mf=\$MAX_FIXROUNDS"
br_env_for_project p2; echo "p2 rfr=\$BR_REVIEW_FIX_ROUNDS tick=\$BR_PER_TICK mf=\$MAX_FIXROUNDS"
br_env_for_project p2; echo "p2b rfr=\$BR_REVIEW_FIX_ROUNDS tick=\$BR_PER_TICK mf=\$MAX_FIXROUNDS"
br_env_for_project p1; echo "p1b rfr=\$BR_REVIEW_FIX_ROUNDS tick=\$BR_PER_TICK mf=\$MAX_FIXROUNDS"
br_env_for_project -;  echo "none rfr=\$BR_REVIEW_FIX_ROUNDS tick=\$BR_PER_TICK mf=\$MAX_FIXROUNDS"
EOF
rm -f "$T/apply.txt"
OUT=$(bash "$T/envdrv.sh" 2>"$T/envdrv.err")
grep -qx 'p1 rfr=5 tick=4 mf=3' <<<"$OUT" && ok || bad "E1: p1's rows must set BR_REVIEW_FIX_ROUNDS=5 and MAX_FIXROUNDS=3, BR_PER_TICK stays fleet-wide (4): $OUT $(cat "$T/envdrv.err")"
grep -qx 'p2 rfr=2 tick=4 mf=1' <<<"$OUT" && ok || bad "E2: p2 (no rows) must read the fleet values again, not p1's: $OUT"
grep -qx 'p2b rfr=2 tick=4 mf=1' <<<"$OUT" && ok || bad "E3: a repeat of the same project is unchanged: $OUT"
grep -qx 'p1b rfr=5 tick=4 mf=3' <<<"$OUT" && ok || bad "E4: back to p1 reads its rows again: $OUT"
grep -qx 'none rfr=2 tick=4 mf=1' <<<"$OUT" && ok || bad "E5: the empty project bucket reads the fleet values: $OUT"
[ "$(grep -c '^blocked-resolver p1$' "$T/apply.txt")" = 2 ] && ok || bad "E6: lane_env_apply blocked-resolver p1 called once per visit (2): $(cat "$T/apply.txt")"
[ "$(grep -c '^blocked-resolver p2$' "$T/apply.txt")" = 1 ] && ok || bad "E7: the repeat visit of p2 is memoised (1 apply): $(cat "$T/apply.txt")"
# The driver calls it inside the candidate loop with the row's project, and the
# --fix-here entry with its project; the startup line still applies the fleet rows.
grep -qE '^command -v lane_env_apply +>/dev/null 2>&1 && lane_env_apply +blocked-resolver$' "$DIR/bin/blocked-resolver.sh" && ok \
  || bad "E8: the startup fleet-wide lane_env_apply line is gone"
grep -q 'br_env_for_project "\$P"' "$DIR/bin/blocked-resolver.sh" && ok || bad "E9: the candidate loop does not call br_env_for_project \"\$P\""
grep -q 'br_env_for_project "\$_fh_p"' "$DIR/bin/blocked-resolver.sh" && ok || bad "E10: the --fix-here entry does not call br_env_for_project for its project"

# ── §M: the project reaches the cap at every read ─────────────────────────
[ "$(grep -c 'br_fix_cap "\$st" "\$reason" "\$p"' "$DIR/bin/blocked-resolver.sh")" -ge 3 ] && ok \
  || bad "M1: br_fix_round's three cap reads must pass the project ($(grep -c 'br_fix_cap "\$st" "\$reason" "\$p"' "$DIR/bin/blocked-resolver.sh"))"
grep -q 'review-changes-requested) br_review_fix_cap "\${p:-}" >/dev/null; cap="\$_BR_REVIEW_CAP_OUT"' "$DIR/bin/blocked-resolver.sh" && ok \
  || bad "M2: the prepass mirror must read the row through br_review_fix_cap with the row's project"
grep -q 'review-changes-requested) cap="\${BR_REVIEW_FIX_ROUNDS:-2}"' "$DIR/bin/blocked-resolver.sh" \
  && bad "M3: the prepass still hardcodes BR_REVIEW_FIX_ROUNDS" || ok
grep -q 'review_tier_cap "\$REVIEW_TIER" "\$PROJECT"' "$DIR/bin/lib/rb/review.sh" && ok \
  || bad "M4: bin/lib/rb/review.sh must pass the project to review_tier_cap"

echo "br-fix-cap-row.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
