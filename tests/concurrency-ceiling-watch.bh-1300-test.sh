#!/bin/bash
# tests/concurrency-ceiling-watch.bh-1300-test.sh — a pool project's build
# ceiling must never drop in silence (BH-1300, the deferred half of BH-1279).
#
# On 2026-09-20 and again on 2026-09-21 the jobs worker's schema re-apply
# resurrected `repo/*/build = 1`, every pool-routed project went from unlimited
# to ONE build at a time, and nobody was told: project-5 sat at queue depth 5
# with 13 ai-build tickets waiting and the ceiling was rediscovered by a human
# reading `fleet_status.rules`. Nothing in the harness compared two consecutive
# observations of the number.
#
# There is no ledger row for a rule-set — `bin/jobs-client.sh rule-set` PUTs
# /api/rules and the worker stamps `concurrency_rules.updated_at`, nothing else.
# So "a rule-set since the previous snapshot" is read off the BINDING repo rule's
# `updated_at`, and the resurrection case is exactly the one that carries the
# SEED's old stamp (2026-08-29) while the number moved.
#
# Driven against the real bin/concurrency-plan.sh over a scratch harness whose
# flags, fleet.conf and rules TSV are shaped like a box's, with a fake
# bin/lane-alert.sh recording its full argv. What is asserted is what the watch
# INVOKED and what it STORED, never the source text.
#
#   1  first run, no store         → silent, baseline written, pool only
#   2  unlimited -> 1, seed stamp  → exactly one warn alert naming both numbers
#   3  the same tick again         → silent (once per change, not per tick)
#   4  drop with a fresh stamp     → silent (an operator's rule-set explains it)
#   5  drop with NO stamp at all   → alerts (absent evidence is not approval)
#   5b the same, with the previous observation before today's midnight
#   6  a RISE                      → silent, no --resolve, baseline follows
#   7  a local-route project       → never compared, never alerted
#   8  THE PRODUCTION ENTRY POINT  → the whole bin/fleet-status-push.sh run
#   9  lane-alert.sh absent        → the ALERTS.log line still lands
#  10  concurrency-plan.sh silent  → nothing sent, the store is not touched
#  11  a second, smaller drop 4->1 → its own id, so it gets its own line
#  12  a numeric rise 1->4         → silent
#
# Run from anywhere: tests/concurrency-ceiling-watch.bh-1300-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# One clock read for the whole file; every fixture stamp is derived from it, so
# the suite cannot pick its own red minute.
NOW=$(date -u +%s)
iso_at() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin"
cp "$DIR/bin/concurrency-plan.sh" "$DIR/bin/concurrency-ceiling-watch.sh" \
   "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/" 2>/dev/null
cp "$DIR/bin/lib/build-caps.sh" "$T/bin/lib/" 2>/dev/null
chmod +x "$T/bin/"*.sh 2>/dev/null
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"

# The rules client, as the worker would answer them: sourceable (the plan sources
# it and calls job_rules) AND runnable (`jobs-client.sh rules`, which is how
# bin/fleet-status-push.sh asks). A stub rather than the network, because the
# whole question is what the plan CONCLUDES from a specific rule set.
cat > "$T/bin/jobs-client.sh" <<'STUB'
#!/bin/bash
job_rules() { cat "${RULES_TSV:-/dev/null}" 2>/dev/null; }
case "${1:-}" in rules) job_rules ;; esac
STUB
printf '#!/bin/bash\nprintf "0\\n"\n' > "$T/bin/pool-cap.sh"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"
# The fake alert path records its FULL argv, one line per call.
cat > "$T/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/LANEALERT.log"
exit 0
SH
chmod +x "$T/bin/jobs-client.sh" "$T/bin/pool-cap.sh" "$T/bin/beat.sh" \
         "$T/bin/lane-alert.sh" "$T/fakebin/curl"

# alpha is pool-routed (both flags), beta is local. The pool filter is the whole
# point of case 7: from the hub, a local project's numbers are the HUB's flags.
cat > "$T/fleet.conf" <<'EOF'
# <project> <repo> <prod> <board-prefix> <offset> [box]
alpha Org/alpha https://a.example /api/board 2 box-alpha
beta  Org/beta  https://b.example /api/board 4 box-beta
EOF
touch "$T/flags/builder-fly-alpha" "$T/flags/fly-pool-alpha"

STORE="$T/state/concurrency-ceiling.json"
watch() { rm -f "$T/LANEALERT.log"
          RULES_TSV="$T/rules.tsv" HARNESS="$T" bash "$T/bin/concurrency-ceiling-watch.sh"; }
calls() { if [ -f "$T/LANEALERT.log" ]; then grep -c . "$T/LANEALERT.log"; else echo 0; fi; }
argv()  { cat "$T/LANEALERT.log" 2>/dev/null; }
q()     { jq -r "$1" "$STORE" 2>/dev/null; }
# A previous observation, planted the way the watch itself would have written it.
plant() { jq -nc --arg e "$2" --arg a "$(iso_at "$3")" --arg p "$1" \
            '{($p): {effective:$e, bound_by:"fixture", as_of:$a}}' > "$STORE"; }

: > "$T/rules.tsv"

# ─────────────────────────────────────────────────────────────────────────────
# 1. FIRST RUN — nothing to compare against, so nothing is said
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$STORE"
watch
[ "$(calls)" = 0 ] && ok || bad "1: a first run has no previous snapshot and must be silent, got $(calls): $(argv)"
[ "$(q '.alpha.effective')" = unlimited ] \
  && ok || bad "1: the baseline must record alpha's ceiling (got: $(q '.|tojson'))"
date -u -d "$(q '.alpha.as_of')" >/dev/null 2>&1 \
  && ok || bad "1: as_of must be a parseable timestamp (got: $(q '.alpha.as_of'))"
[ "$(q '.beta // "absent"')" = absent ] \
  && ok || bad "1: a local-route project must never enter the store (got: $(q '.|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 2. THE INCIDENT — repo/*/build resurrected at 1, carrying the SEED's stamp
# ─────────────────────────────────────────────────────────────────────────────
printf 'repo\t*\tbuild\t1\tseed\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
watch
[ "$(calls)" = 1 ] && ok || bad "2: a silent drop must alert exactly once, got $(calls): $(argv)"
for want in "--severity warn" "--id concurrency-ceiling-alpha-unlimited-to-1" \
            "alpha" "unlimited" "repo-rule 1"; do
  case "$(argv)" in
    *"$want"*) ok ;;
    *) bad "2: the alert must carry '$want' (got: $(argv))" ;;
  esac
done
case "$(argv)" in
  *"unlimited -> 1"*) ok ;;
  *) bad "2: the alert must name the old and the new ceiling (got: $(argv))" ;;
esac
# The cap that binds, not the plan's whole "(route: pool, on <box>'s view of the
# flags)" sentence repeated on every alert line.
case "$(argv)" in
  *"(bound by repo-rule 1)"*) ok ;;
  *) bad "2: the binding rule must read as just the rule (got: $(argv))" ;;
esac
case "$(argv)" in
  *--critical*) bad "2: never --critical, this is the batched digest (got: $(argv))" ;;
  *) ok ;;
esac
case "$(argv)" in
  *--resolve*) bad "2: a drop is a fire, never a resolve (got: $(argv))" ;;
  *) ok ;;
esac
[ "$(q '.alpha.effective')" = 1 ] \
  && ok || bad "2: the store must advance to the new ceiling (got: $(q '.|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 3. ONCE PER CHANGE, NOT PER TICK — the same rules on the next */10
# ─────────────────────────────────────────────────────────────────────────────
watch
[ "$(calls)" = 0 ] \
  && ok || bad "3: a re-observed ceiling is not a change and must be silent, got $(calls): $(argv)"

# ─────────────────────────────────────────────────────────────────────────────
# 4. AN OPERATOR'S RULE-SET EXPLAINS IT — updated_at inside the window
# ─────────────────────────────────────────────────────────────────────────────
plant alpha unlimited "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t1\tlowered on purpose\t%s\n' "$(iso_at "$(( NOW - 300 ))")" > "$T/rules.tsv"
watch
[ "$(calls)" = 0 ] \
  && ok || bad "4: a drop with a rule-set in the window must be silent, got $(calls): $(argv)"
[ "$(q '.alpha.effective')" = 1 ] \
  && ok || bad "4: the store still follows the ceiling (got: $(q '.|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 5. ABSENT EVIDENCE IS NOT APPROVAL — a five-column row (older client)
# ─────────────────────────────────────────────────────────────────────────────
plant alpha unlimited "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t1\tno stamp at all\n' > "$T/rules.tsv"
watch
[ "$(calls)" = 1 ] \
  && ok || bad "5: a drop with no updated_at must alert, got $(calls): $(argv)"
# 5b. ...AT EVERY HOUR OF THE DAY. GNU `date -d ""` is not an error: it is TODAY
# 00:00:00Z. So an empty stamp read as "midnight", and every drop whose previous
# observation was taken before midnight looked explained. That is a silent
# drop in the first ten minutes of each UTC day, and it is how case 5 went red
# on main at 00:00Z on 2026-09-24. The previous observation is planted one
# second before today's midnight, so this case reproduces the bug at any hour,
# not just in that window.
MIDNIGHT=$(date -u -d "$(date -u +%F)" +%s 2>/dev/null)  # determinism: ok the product's broken read IS "today's midnight"; anchoring to it is the reproduction
if [ -n "$MIDNIGHT" ]; then
  plant alpha unlimited "$(( MIDNIGHT - 1 ))"
  printf 'repo\t*\tbuild\t1\tno stamp at all\n' > "$T/rules.tsv"
  watch
  [ "$(calls)" = 1 ] \
    && ok || bad "5b: a drop with no updated_at must alert even when the last observation was before midnight, got $(calls): $(argv)"
else
  echo "note: this date has no GNU -d — 5b did not run"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. A RISE IS NOT AN ALERT — and it is not a --resolve either
# ─────────────────────────────────────────────────────────────────────────────
plant alpha 1 "$(( NOW - 600 ))"
: > "$T/rules.tsv"
watch
[ "$(calls)" = 0 ] && ok || bad "6: a rise must be silent, got $(calls): $(argv)"
[ "$(q '.alpha.effective')" = unlimited ] \
  && ok || bad "6: the store must follow the rise (got: $(q '.|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 7. POOL ONLY — a box rule drops beta's local ceiling; the hub says nothing
# ─────────────────────────────────────────────────────────────────────────────
jq -nc --arg a "$(iso_at "$(( NOW - 600 ))")" \
  '{beta: {effective:"unlimited", bound_by:"fixture", as_of:$a}}' > "$STORE"
printf 'box\t*\tbuild\t1\tone build per box\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
watch
[ "$(calls)" = 0 ] \
  && ok || bad "7: a local-route project is the hub's own flags, never an alert, got $(calls): $(argv)"
[ "$(q '.beta.effective')" = unlimited ] \
  && ok || bad "7: and its planted entry is left exactly as it was (got: $(q '.|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 8. THE PRODUCTION ENTRY POINT — the whole hub */10 lane, end to end
# ─────────────────────────────────────────────────────────────────────────────
push() { rm -f "$T/PUSH.json" "$T/BEAT.json" "$T/LANEALERT.log"
         PATH="$T/fakebin:$PATH" RULES_TSV="$T/rules.tsv" HARNESS="$T" \
           bash "$DIR/bin/fleet-status-push.sh"; }
# grep -c prints its own 0 and exits 1; a `|| echo 0` after it would print a
# SECOND zero and every count comparison would compare against "0\n0".
bh1300() { if [ -f "$T/LANEALERT.log" ]; then grep -c 'concurrency-ceiling-alpha' "$T/LANEALERT.log"; else echo 0; fi; }
plant alpha unlimited "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t1\tseed\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
push
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "8: the watchdog push must still be valid JSON"
[ "$(bh1300)" = 1 ] \
  && ok || bad "8: the lane itself must raise the ceiling alert, got $(bh1300): $(argv)"
[ "$(q '.alpha.effective')" = 1 ] \
  && ok || bad "8: and the lane advances the store (got: $(q '.|tojson'))"

# 8b. the watch script absent must cost the dead-man signal NOTHING
mv "$T/bin/concurrency-ceiling-watch.sh" "$T/watch.away"
plant alpha unlimited "$(( NOW - 600 ))"
push
RC=$?
[ "$RC" = 0 ] && ok || bad "8b: an absent watch must not fail the push (rc $RC)"
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "8b: the push is unchanged without the watch"
[ "$(bh1300)" = 0 ] \
  && ok || bad "8b: and nothing is sent, got $(bh1300): $(argv)"
mv "$T/watch.away" "$T/bin/concurrency-ceiling-watch.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 9. NO lane-alert.sh — the ALERTS.log line is the requirement, not the helper
# ─────────────────────────────────────────────────────────────────────────────
mv "$T/bin/lane-alert.sh" "$T/alert.away"
: > "$T/logs/ALERTS.log"
plant alpha unlimited "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t1\tseed\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
watch
N=$(grep -c '\[orchestrator/fleet-status\].*alpha.*unlimited.*1.*repo-rule' "$T/logs/ALERTS.log")
[ "$N" = 1 ] \
  && ok || bad "9: exactly one ALERTS.log line without lane-alert.sh, got $N: $(cat "$T/logs/ALERTS.log")"
[ "$(q '.alpha.effective')" = 1 ] \
  && ok || bad "9: the store advances on the direct path too (got: $(q '.|tojson'))"
mv "$T/alert.away" "$T/bin/lane-alert.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 10. NO ANSWER FROM THE PLAN — say nothing, and do not overwrite the baseline
# ─────────────────────────────────────────────────────────────────────────────
cp "$T/bin/concurrency-plan.sh" "$T/plan.away"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/concurrency-plan.sh"; chmod +x "$T/bin/concurrency-plan.sh"
plant alpha unlimited "$(( NOW - 600 ))"
BEFORE=$(cat "$STORE")
watch
[ "$(calls)" = 0 ] && ok || bad "10: an unreadable plan must send nothing, got $(calls): $(argv)"
[ "$(cat "$STORE")" = "$BEFORE" ] \
  && ok || bad "10: and must not overwrite the baseline it could not re-read (got: $(cat "$STORE"))"
cp "$T/plan.away" "$T/bin/concurrency-plan.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 11. A SECOND, SMALLER DROP — 4 -> 1 is a distinct condition with its own id
# ─────────────────────────────────────────────────────────────────────────────
plant alpha 4 "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t1\tseed\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
watch
[ "$(calls)" = 1 ] && ok || bad "11: a number lower than a number is a drop too, got $(calls): $(argv)"
case "$(argv)" in
  *"--id concurrency-ceiling-alpha-4-to-1"*) ok ;;
  *) bad "11: the id must carry THIS change, not the last one (got: $(argv))" ;;
esac
case "$(argv)" in
  *"dropped 4 -> 1"*) ok ;;
  *) bad "11: and the line names both numbers (got: $(argv))" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# 12. A NUMERIC RISE — 1 -> 4 is the same arithmetic the other way, and silent
# ─────────────────────────────────────────────────────────────────────────────
plant alpha 1 "$(( NOW - 600 ))"
printf 'repo\t*\tbuild\t4\tseed\t2026-08-29T00:00:00Z\n' > "$T/rules.tsv"
watch
[ "$(calls)" = 0 ] && ok || bad "12: raising a cap is not an incident, got $(calls): $(argv)"
[ "$(q '.alpha.effective')" = 4 ] \
  && ok || bad "12: the store follows it anyway (got: $(q '.|tojson'))"

echo "concurrency-ceiling-watch.bh-1300-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
