#!/bin/bash
# tests/lead-gates-tier-ports.bh-8630-test.sh — gate 60's review tier and mode
# tokens (bin/lib/lead-gates.d/60-risk.sh) on the cases the enqueue suite
# tests/review-tier-medium.bh-6967-test.sh pinned and no worklist suite did.
# Every case drives bin/lead-review.sh tick WHOLE over the worklist fixture
# (tests/lib/lead-worklist-fixture.bh-4956.sh + the 5875, 5876 and 5878 layers).
#   TP1  medium + risk_tier.medium_mode full: the /start notes end
#        `; review-tier:medium review-mode:full`, stored, and a job starts.
#   TP1b medium + no medium_mode row (404): full, and no log line about the row.
#   TP2  high (.mergify.yml) + intent: `; review-tier:high review-mode:full`.
#   TP3  low under shadow + intent: no sign-off, a job starts, and the notes end
#        `; review-tier:low review-mode:full`.
#   TP4  enforce + medium + intent, no build job for the head: gate 70 skips the
#        grace, a job starts, and the notes end `review-mode:intent`.
#   TP5  one tick: PR 141 medium + intent, then PR 142 with an unreadable author
#        (risk tier skipped): PR 142's notes carry no tokens.
#   TP6  the row ` Intent ` reads intent; the row `yes` over two medium heads in
#        one tick reads full for both, with one log line and one GET of the row.
#   PM1-PM4 mutations of the scratch gate 60: each turns its case red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-tier-ports.bh-8630-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5878.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
lg8_setup

G60="$H/bin/lib/lead-gates.d/60-risk.sh"
G70="$H/bin/lib/lead-gates.d/70-inbuild-grace.sh"
[ -f "$G60" ] && [ -f "$G70" ] && ok || bad "setup: the scratch harness has no gate 60 or gate 70"

HA=$(printf '%040d' 141); A12=${HA:0:12}
HB=$(printf '%040d' 142); B12=${HB:0:12}
ST="$H/state/lead-review-enqueue"
MEDF='[["bin/lib/thing.sh","modified",40,10,"@@ -1 +1 @@\n+x=1"]]'
HIGHF='[[".mergify.yml","modified",2,1,"@@ -1 +1 @@\n+x: 1"]]'
LOWF='[["tests/x.bh-1-test.sh","added",3,0,"@@ -0,0 +1,3 @@\n+#!/bin/bash\n+echo ok\n+exit 0"]]'
# one <mode> <files> [medium_mode row] — PR 141 on HA, the builder's APPROVE on it
one() {
  lg6_reset "$1"
  lgf_needs "141:$HA"; lgf_cmp "$HA" "$2"
  lg8_bv 141 APPROVE "$HA" 2026-10-15T10:00:00Z
  [ -n "${3+x}" ] && printf '%s' "$3" > "$FX/settings/risk_tier.medium_mode"
  return 0
}
# two <files 142> [medium_mode row] — PRs 141 (MEDF) and 142 in one worklist, shadow
two() {
  lg6_reset shadow
  lgf_needs "141:$HA" "142:$HB"; lgf_cmp "$HA" "$MEDF"; lgf_cmp "$HB" "$1"
  lg8_bv 141 APPROVE "$HA" 2026-10-15T10:00:00Z; lg8_bv 142 APPROVE "$HB" 2026-10-15T10:00:00Z
  [ -n "${2+x}" ] && printf '%s' "$2" > "$FX/settings/risk_tier.medium_mode"
  return 0
}
mm_reads() { lwf_cnt '^GET /api/settings/risk_tier.medium_mode ' "$T/log/worker"; }
yes_lines() { lwf_cnt "risk_tier.medium_mode reads 'yes'" "$L"; }

# Each case is a function so a mutation re-runs it word for word.
tp2() { one shadow "$HIGHF" intent; lwf_tick; }
tp5() { two "$MEDF" intent; : > "$FX/author.142"; lwf_tick; }
tp6a() { one shadow "$MEDF" ' Intent '; lwf_tick; }
tp6b() { two "$MEDF" yes; lwf_tick; }

# ── TP1: medium + full ──
one shadow "$MEDF" full
lwf_tick
[[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:full" ]] && ok || bad "TP1 notes: $(lg8_notes 141) / $(cat "$L")"
[ "$(cat "$ST/review-tier-example-org_cromford-141-$A12" 2>/dev/null)" = "review-tier:medium review-mode:full" ] && ok \
  || bad "TP1 stored tokens: $(cat "$ST/review-tier-example-org_cromford-141-$A12" 2>/dev/null)"
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "TP1 jobs=$(lgf_jobs 141)"

# ── TP1b: medium, no medium_mode row: full, no line ──
one shadow "$MEDF"
lwf_tick
[[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:full" ]] && ok || bad "TP1b notes: $(lg8_notes 141)"
[ "$(mm_reads)" = 1 ] && ok || bad "TP1b the row was not read: $(mm_reads) reads"
[ "$(lwf_cnt 'risk_tier.medium_mode' "$L")" = 0 ] && ok || bad "TP1b log lines: $(grep medium_mode "$L")"

# ── TP2: high + intent: full ──
tp2
[[ "$(lg8_notes 141)" == *"; review-tier:high review-mode:full" ]] && ok || bad "TP2 notes: $(lg8_notes 141) / $(cat "$L")"
[[ "$(lg8_notes 141)" != *"review-mode:intent"* ]] && ok || bad "TP2 intent on a high head: $(lg8_notes 141)"

# ── TP3: low under shadow + intent: a job, full ──
one shadow "$LOWF" intent
lwf_tick
[ "$(lgf_signed 141)" = 0 ] && ok || bad "TP3 a sign-off under shadow: $(cat "$T/log/lv")"
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "TP3 jobs=$(lgf_jobs 141): $(cat "$L")"
[[ "$(lg8_notes 141)" == *"; review-tier:low review-mode:full" ]] && ok || bad "TP3 notes: $(lg8_notes 141)"

# ── TP4: enforce + medium + intent, no build job: no grace, intent ──
one enforce "$MEDF" intent
lwf_tick
[ "$(lgf_jobs 141)" = 1 ] && ok || bad "TP4 jobs=$(lgf_jobs 141): $(cat "$L")"
[[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:intent" ]] && ok || bad "TP4 notes: $(lg8_notes 141)"
grep -q "inbuild-grace skipped #141 head=$A12: no build job for this head" "$L" && ok || bad "TP4 no grace-skip line: $(cat "$L")"

# ── TP5: PR 142's risk block skipped after PR 141's intent: no tokens ──
tp5
[ "$(lgf_jobs 141)" = 1 ] && [ "$(lgf_jobs 142)" = 1 ] && ok || bad "TP5 jobs=$(lgf_jobs 141)/$(lgf_jobs 142): $(cat "$L")"
[[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:intent" ]] && ok || bad "TP5 141 notes: $(lg8_notes 141)"
N142=$(lg8_notes 142)
[[ "$N142" != *"review-tier:"* && "$N142" != *"review-mode:"* ]] && ok || bad "TP5 142 notes carry tokens: $N142"
grep -qF "example-org/cromford#142 @$B12: risk tier skipped (PR author unreadable); reviewed as before" "$L" \
  && ok || bad "TP5 no skip line: $(cat "$L")"
[ "$(head -n 1 "$T/log/start" 2>/dev/null | jq -r '.pr' 2>/dev/null)" = 141 ] && ok || bad "TP5 the first start is not PR 141: $(cat "$T/log/start" 2>/dev/null)"

# ── TP6: the row read: trimmed, any case; a bad value once a tick ──
tp6a
[[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:intent" ]] && ok || bad "TP6a notes: $(lg8_notes 141)"
tp6b
[[ "$(lg8_notes 141)" != *"review-mode:intent"* && "$(lg8_notes 142)" != *"review-mode:intent"* ]] && ok \
  || bad "TP6b intent from 'yes': $(lg8_notes 141) / $(lg8_notes 142)"
[[ "$(lg8_notes 142)" == *"; review-tier:medium review-mode:full" ]] && ok || bad "TP6b 142 notes: $(lg8_notes 142)"
[ "$(yes_lines)" = 1 ] && ok || bad "TP6b 'yes' log lines=$(yes_lines)"
[ "$(mm_reads)" = 1 ] && ok || bad "TP6b row reads=$(mm_reads)"

# ── PM1-PM4: mutations of the scratch gate 60; each must turn its case red ──
# mutate <name> <sed program> — sed -i.orig on gate 60; rc 1 if it changed nothing.
mutate() {
  sed -i.orig "$2" "$G60"
  if cmp -s "$G60" "$G60.orig"; then bad "$1 the mutation did not apply"; mv "$G60.orig" "$G60"; return 1; fi
}
restore() { mv "$G60.orig" "$G60"; cmp -s "$G60" "$LWF_SRC/bin/lib/lead-gates.d/60-risk.sh" && ok || bad "$1 gate 60 not restored"; }

# PM1: no trim or case fold: ' Intent ' is not intent.
if mutate PM1 "s/tr -d '\[:space:\]' | tr '\[:upper:\]' '\[:lower:\]'/cat/"; then
  tp6a
  [[ "$(lg8_notes 141)" == *"; review-tier:medium review-mode:full" ]] && ok || bad "PM1 the mutant still read intent: $(lg8_notes 141)"
  restore PM1
fi
# PM2: no memo: the row is read and the bad value logged once per head.
if mutate PM2 '/\[ -n "\$_LGRT_MM" \] && { printf/d'; then
  tp6b
  [ "$(mm_reads)" = 2 ] && ok || bad "PM2 row reads=$(mm_reads), want 2"
  [ "$(yes_lines)" = 2 ] && ok || bad "PM2 'yes' log lines=$(yes_lines), want 2"
  restore PM2
fi
# PM3: the field ignores the key and the reset keeps the last head's tokens.
if mutate PM3 's/^  \[ "\${LG_RISK_KEY:-}" = "\$1#\$2@\$3" \] && printf .%s. "\$_LGRT_TOK"$/  printf "%s" "$_LGRT_TOK"/; s/; _LGRT_TOK=""$//'; then
  tp5
  [[ "$(lg8_notes 142)" == *"review-mode:intent" ]] && ok || bad "PM3 the mutant did not leak 141's tokens: $(lg8_notes 142)"
  restore PM3
fi
# PM4: high reads as medium intent.
if mutate PM4 's/high) t="review-tier:high review-mode:full" ;;/high) t="review-tier:medium review-mode:intent" ;;/'; then
  tp2
  [[ "$(lg8_notes 141)" == *"review-mode:intent" ]] && ok || bad "PM4 the mutant still sent full: $(lg8_notes 141)"
  restore PM4
fi

echo "lead-gates-tier-ports.bh-8630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
