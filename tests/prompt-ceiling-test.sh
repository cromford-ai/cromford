#!/bin/bash
# tests/prompt-ceiling-test.sh — no call ships an oversized prompt, and the
# per-runner input distribution is measured rather than assumed.
#
# WHAT THIS IS AND IS NOT. The guard bounds the text WE assemble. It does NOT
# shrink the measured grok triage calls (620K mean / 3.7M max input tokens),
# and this file says so out loud because the easiest mistake available here is
# to ship the guard, see the bill unchanged, and not know why.
#
# The arithmetic that settles it: the entire triage assembly is the project SOP
# (largest 17,219 bytes), a bounded gate-diff, `head -40` of the ready queue and
# `head -20` of build-queue dirs — under ~25K tokens all in. alert-triage caps
# its log slice at 20,000 bytes and runs CLAUDE, not grok. So the assembled
# prompt is 25-150x too small to be the 620K mean. The tokens accumulate inside
# the agentic session, and the row's input_toks is that session's final
# cumulative figure (agent-call reads the LAST usage object from grok's ledger).
#
# The guard is still worth having: past 200K prompt tokens xAI bills the WHOLE
# request at double rate, so an assembly that ever drifted over the cliff would
# cost 2x with nothing in any log to say why. Its silence is then evidence.
# Run from anywhere: tests/prompt-ceiling-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
AC="$DIR/bin/agent-call.sh"
ROLL="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/flags" "$T/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

# ---------- the guard, extracted and run for real ----------
python3 - "$AC" "$T/guard.sh" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
start = src.index("prompt_guard() {")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
EXTRACT
[ -s "$T/guard.sh" ] && ok || bad "could not extract prompt_guard from agent-call.sh"

guard() {  # guard <text> -> prints the possibly-truncated result
  HARNESS="$T" STAGE=triage PROJECT=alpha-os bash -c '
    set -uo pipefail
    HARNESS="'"$T"'"; STAGE=triage; PROJECT=alpha-os
    . "'"$T"'/guard.sh"
    prompt_guard "$1"' _ "$1"
}

# --- 1. a normal prompt passes through UNCHANGED -----------------------------
# The guard must be invisible in the case that is always true today. A guard
# that trims healthy prompts would silently degrade every triage run.
SMALL=$(printf 'x%.0s' $(seq 1 5000))
[ "$(guard "$SMALL" | wc -c | tr -d ' ')" = "5000" ] \
  && ok || bad "a 5KB prompt must pass through untouched"
[ ! -f "$T/logs/ALERTS.log" ] \
  && ok || bad "a normal prompt must not raise an alert"

# --- 2. an oversized prompt is TRUNCATED, not shipped ------------------------
BIG=$(PROMPT_MAX_BYTES=1000 true; printf 'y%.0s' $(seq 1 3000))
OUT=$(HARNESS="$T" STAGE=triage PROJECT=alpha-os PROMPT_MAX_BYTES=1000 bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; STAGE=triage; PROJECT=alpha-os
  . "'"$T"'/guard.sh"
  prompt_guard "$1"' _ "$BIG")
[ "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" = "1000" ] \
  && ok || bad "an oversized prompt must be cut to the cap (got $(printf '%s' "$OUT" | wc -c) bytes)"

# --- 3. it keeps the TAIL, and that choice is deliberate ---------------------
# The tail of a triage prompt is the current scope and the SOP — what the turn
# actually needs. Keeping the head would drop exactly the part that matters.
TAILED=$(HARNESS="$T" PROMPT_MAX_BYTES=10 bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; STAGE=triage; PROJECT=alpha-os
  . "'"$T"'/guard.sh"
  prompt_guard "AAAAAAAAAAAAAAAAAAAAHEADTAILZZZZ"' 2>/dev/null)
[ "$TAILED" = "TAILZZZZ" ] || [ "${TAILED: -4}" = "ZZZZ" ] \
  && ok || bad "truncation must keep the TAIL (scope + SOP), got '$TAILED'"

# --- 4. THE TRUNCATION IS ANNOUNCED ------------------------------------------
# A silent trim is a lost signal nobody can diagnose. This is the difference
# between a bounded prompt and a mystery.
grep -q 'PROMPT OVERSIZE' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "an oversized prompt was truncated with no ALERTS line — a silent trim is undiagnosable"
grep -q 'bills the whole request double' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the alert does not say WHY it matters (the 200K cliff doubles the whole request)"

# Once per day, not once per call: an alert that fires on every triage tick
# becomes noise and gets filtered, which is how the next one goes unread.
BEFORE=$(wc -l < "$T/logs/ALERTS.log")
HARNESS="$T" PROMPT_MAX_BYTES=10 bash -c '
  set -uo pipefail
  HARNESS="'"$T"'"; STAGE=triage; PROJECT=alpha-os
  . "'"$T"'/guard.sh"
  prompt_guard "AAAAAAAAAAAAAAAAAAAAHEADTAILZZZZ"' >/dev/null 2>&1
AFTER=$(wc -l < "$T/logs/ALERTS.log")
[ "$BEFORE" = "$AFTER" ] \
  && ok || bad "the oversize alert repeats per call ($BEFORE -> $AFTER) — that is noise, not a signal"

# --- 5. the DISTRIBUTION is measured, not assumed ----------------------------
# This is what settles where the tokens come from, and what makes a regression
# visible instead of arriving as a bill.
python3 - "$ROLL" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
i = body.index("def runner_input_stats(")
out = ["import csv, json, datetime, sys\nH = CD = sys.argv[1]\nnow = datetime.datetime.utcnow()\n"]
out.append(body[i:body.index("def overage_accounts(", i)])
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && ok || bad "could not extract runner_input_stats from cost-rollup.sh"

NOW=$(python3 -c "
import datetime
print((datetime.datetime.utcnow()-datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
{ echo 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode'
  # 3 grok calls: two over the 200K cliff, one under.
  echo "$NOW,hub,alpha-os,triage,grok,grok-4.6,0,60,300000,100,0,0,1.00,metered"
  echo "$NOW,hub,alpha-os,triage,grok,grok-4.6,0,60,900000,100,0,0,3.00,metered"
  echo "$NOW,hub,alpha-os,triage,grok,grok-4.6,0,60,60000,100,0,0,0.20,metered"
  # a claude row that must not be mixed into grok's distribution
  echo "$NOW,hub,alpha-os,execute,claude,claude-opus-5,0,60,5000,100,0,0,2.00,subscription"
  # an UNCAPTURED row (0 tokens) that would drag the mean down if counted
  echo "$NOW,hub,alpha-os,triage,grok,grok-4.6,0,60,0,0,0,0,0,metered"
} > "$T/fleet-cost.csv"

python3 - "$T" <<'PY' && ok || bad "runner_input_stats must report per-runner mean/p95 and the over-cliff share"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
st = core.runner_input_stats(7)
# Keyed on (runner, stage, project) now — runner alone collided medic with
# alert-triage, and judged every claude lane against the strictest claude
# ceiling.
g = st["grok/triage/alpha-os"]
assert g["calls"] == 3, f"uncaptured 0-token rows must not count as calls: {g}"
assert g["mean_input"] == 420000, g          # (300k+900k+60k)/3
assert g["max_input"] == 900000, g
# THE PRICE MULTIPLIER: 2 of 3 over the cliff, computed on PROMPT tokens.
assert g["over_200k_share"] == 0.667, g
# Lanes must not be blended — claude's small prompts would hide grok's size.
assert st["claude/execute/alpha-os"]["mean_input"] == 5000, st["claude/execute/alpha-os"]
# The cliff is a grok fact and must not be attached to a claude lane.
assert "over_200k_share" not in st["claude/execute/alpha-os"]
PY

# --- 6. ALERT-TRIAGE: the assembly was never the problem --------------------
# Measured before spec'ing, per the F5 lesson: this lane's prompt slice is
# ALREADY capped at 20KB (head -c 20000), and it still ran 400K-1.4M per call.
# So the volume is the agent's own investigation reads, and a bigger prompt cap
# would have saved nothing — the same correction F5 needed.
AT="$DIR/bin/alert-triage.sh"
# A DESIGN ceiling, one named constant (2026-09-28 ratchet review): the byte cap
# alert-triage puts on its log slice and on each investigation read. It is not
# a count of the live tree, so nothing main does elsewhere moves it.
ALERT_TRIAGE_SLICE_BYTES=20000
grep -q "head -c $ALERT_TRIAGE_SLICE_BYTES" "$AT" \
  && ok || bad "alert-triage's assembly slice is no longer capped at ALERT_TRIAGE_SLICE_BYTES=$ALERT_TRIAGE_SLICE_BYTES (head -c) — the one part that was already fine"
grep -q 'READ CAPPED' "$AT" \
  && ok || bad "the investigation instructions do not mandate capped reads — that is where the 1.4M comes from"
grep -q "tail -c $ALERT_TRIAGE_SLICE_BYTES" "$AT" \
  && ok || bad "the contract names no concrete cap (tail -c ALERT_TRIAGE_SLICE_BYTES=$ALERT_TRIAGE_SLICE_BYTES); 'read less' is not an instruction"
grep -qi 'do not re-read the quarantine' "$AT" \
  && ok || bad "the prompt does not tell the agent the alerts are already in front of it"

# --- 7. THE CLAUDE LANES HAVE A DOLLAR BOUND -------------------------------
# The orchestrator got --max-budget-usd in #75; every claude lane through
# agent-call had none — including alert-triage, which runs claude PRIMARY on the
# hub and bills an account in overage. A bound on one caller and not on the
# shared path is a bound most of the fleet does not have.
grep -q -- '--max-budget-usd "\$(_budget_for "\$STAGE" "\$PROJECT" "\$runner")"' "$AC" \
  && ok || bad "agent-call's claude lane does not size its bound from the lane's own ceiling"
# ...and it checks its own inertness, because the flag is UNVERIFIED under
# subscription OAuth exactly as in #75.
grep -q 'BUDGET FLAG INERT' "$AC" \
  && ok || bad "the bound does not report its own inertness — an unenforced cap stops people looking"
# The grok failover path must carry its bound too, or the cheaper-looking lane
# is the unbounded one.
grep -q -- '--max-turns "\${GROK_MAX_TURNS:-25}"' "$AC" \
  && ok || bad "the grok failover path has no tool-loop bound"

# --- 8. THE DETECTOR MUST READ THE STREAM THE ANSWER IS IN ------------------
# The first version grepped "$OUT" — which on the SUCCESS path is
# `jq -r '.result'`, only the model's answer text. The stop signal lives in the
# envelope ($OUT.json) or stderr ($OUT.err), merged into $OUT only on FAILURE.
# So a graceful stop that still returned a result could not match by
# construction, and the detector announced "treat the bound as absent" about a
# bound that had just worked.
#
# That is #83's bug two files over. A bound has THREE questions: is it present,
# is it enforced, and is the thing that would tell you looking at the right
# stream.
T2=$(mktemp -d "$T/t2-XXXXXX")
# EXTRACTED FROM THE SCRIPT, not retyped. The first version of this helper
# inlined its own copy of the classifier, so deleting the envelope read from
# agent-call.sh left every assertion green — a test of a copy proves the copy.
# Same coupling lesson as the marker lifts, arriving as a hand-written twin
# instead of a stale anchor.
CLASSIFY_SRC=$(sed -n '/_STOP=\$(jq -r/,/_STOP=hit$/p' "$AC")
[ -n "$CLASSIFY_SRC" ] && ok || bad "could not extract the budget-stop classifier from agent-call.sh"
classify() { # classify <envelope-json> <err-text> -> hit|""
  printf '%s' "$1" > "$T2/o.json"; printf '%s' "$2" > "$T2/o.err"
  OUT="$T2/o" bash -c "OUT=\"$T2/o\"; $CLASSIFY_SRC
    printf '%s' \"\${_STOP:-}\""
}
# THE CASE THAT WAS BROKEN: the CLI stopped on budget AND returned a result, so
# the envelope says so while the answer text says nothing.
[ "$(classify '{"subtype":"budget_exceeded","result":"partial answer"}' '')" = hit ] \
  && ok || bad "a graceful budget stop WITH a result must classify as stopped, not inert"
[ "$(classify '{"stop_reason":"max_budget_usd"}' '')" = hit ] \
  && ok || bad "stop_reason must be read as well as subtype"
# stderr still counts, for the failure branch.
[ "$(classify '{}' 'Error: max budget exceeded')" = hit ] \
  && ok || bad "a budget stop reported only on stderr must still classify"
# A NORMAL call must NOT classify as stopped, or every call reads as bounded
# and the detector never fires when it should.
[ -z "$(classify '{"subtype":"success","result":"the budget for Q3 is approved"}' '')" ] \
  && ok || bad "an ordinary answer mentioning budgets must not read as a stop"
[ -z "$(classify '{}' '')" ] \
  && ok || bad "an empty envelope must not invent a stop"

# --- 9. THE BUDGET IS PROPORTIONAL TO THE JOB -------------------------------
# A flat $3 truncated exactly the lanes the manifest protects most: build
# plan/review/fix are declared at 400K because reading a codebase IS the job,
# and 400K in plus output prices well past $3. "The diff is sacred; a
# budget-truncated review carries a verdict on code nobody read."
# DRIVEN THROUGH THE SHIPPED FUNCTION, against a fixture manifest. The first
# version asserted on a RETYPED copy of the formula in its own awk, so changing
# 15/75 to 1/1 inside _budget_for — pricing a 400K review at $0.46 — kept the
# suite green. That is the sixth disguise of one lesson, in the commit that
# named the fifth.
#
# The general form, worth more than this test: IF A TEST COMPUTES THE EXPECTED
# VALUE IT TESTS ITS OWN ARITHMETIC; IF IT READS THE EXPECTED VALUE FROM THE
# CODE IT TESTS THE CODE. The seam that makes this possible (CONTEXT_BUDGETS)
# is the same one #78 added to ceiling_breaches — an untestable path is where
# this class lives.
BUDGET_FOR=$(sed -n '/^_budget_for()/,/^}/p' "$AC")
[ -n "$BUDGET_FOR" ] && ok || bad "no per-lane budget resolver in agent-call"
grep -q 'CONTEXT_BUDGETS:-' "$AC" \
  && ok || bad "_budget_for hardcodes the manifest path — no test can drive the real function"

cat > "$T2/budgets.json" <<'EOF'
{"lanes":[
 {"lane":"alerts-medic","runner":"claude","stage":"triage","project":"medic","ceiling_tokens":1200000},
 {"lane":"alert-triage","runner":"claude","stage":"triage","project":"alert-triage","ceiling_tokens":2000000},
 {"lane":"project-triage","stage":"triage","ceiling_tokens":1600000},
 {"lane":"build-plan","runner":"claude","stage":"plan","ceiling_tokens":8000000}
]}
EOF
budget() { CONTEXT_BUDGETS="$T2/budgets.json" bash -c "$BUDGET_FOR; _budget_for \"$1\" \"$2\" \"$3\""; }

# THE FINDING: stage-only min() gave alert-triage medic's ceiling, not its own.
# THE FIXTURE IS PRICED ABOVE THE FAILSAFE FLOOR ON PURPOSE. The dollar bound is
# now a loose runaway tripwire (the operator 2026-08-27: "that cap is too specific for a
# PR"), so lanes priced under it all read as the same floored number and the
# resolver becomes unobservable through this seam — the assertions would go
# green against a resolver that had regressed to strictest-governs. Ceilings
# here are therefore large enough that each lane's own price is distinguishable:
# 2.0M -> 52.50, 1.2M -> 31.50, 1.6M -> 42.00, 8M -> 210.00.
[ "$(budget triage alert-triage claude)" = "52.50" ] \
  && ok || bad "alert-triage is budgeted against medic's ceiling — a strict lane governing a workload it does not describe (got $(budget triage alert-triage claude))"
[ "$(budget triage medic claude)" = "31.50" ] \
  && ok || bad "medic must still get its own ceiling"
[ "$(budget plan alpha-os claude)" = "210.00" ] \
  && ok || bad "a build lane must price off its own ceiling, not the failsafe floor"
# An unpinned project falls to the catch-all lane, not to the strictest.
[ "$(budget triage project-2 grok)" = "42.00" ] \
  && ok || bad "an unpinned project must resolve to project-triage's ceiling, not medic's"

# A MISSING MANIFEST MUST NOT FLOOR AT THE SMALL TIER. Fly builders never receive catalog/
# (fly-sync-harness tars bin/prompts/rules/fleet.conf/fly), and they are the
# machines that run build lanes — flooring there silently reinstates exactly
# the truncation this derivation removes.
nobudget() { CONTEXT_BUDGETS="$T/no-such-budgets.json" bash -c "$BUDGET_FOR; _budget_for \"$1\" x claude"; }
[ "$(nobudget plan)" = "150.00" ] \
  && ok || bad "a build lane with no manifest floors at the smallest number — the truncation returns invisibly"
[ "$(nobudget triage)" = "25.00" ] \
  && ok || bad "a triage lane's fallback should stay at the small tier"
# ...and the manifest should REACH the builders in the first place.
# Asserted PER MEMBER rather than as one literal argument string (2026-08-29):
# the old grep pinned the exact word order of the tar line, so ADDING a member
# broke a check whose claim is only that these ones are present. Same claim,
# and now it says which member is missing instead of just that the line moved.
TARLINE=$(grep -m1 '^harness_tarball "\$TB" "\$REPO" ' "$DIR/bin/fly-sync-harness.sh")
MISSING=""
for MEMBER in bin prompts rules catalog fleet.conf fly; do
  grep -qE "[ \"]$MEMBER( |\$)" <<<"$TARLINE" || MISSING="$MISSING $MEMBER"
done
[ -z "$MISSING" ] \
  && ok || bad "fly-sync-harness does not ship:$MISSING — builders cannot read their own budgets"

# --- 9b. THE TWO NOTHINGS ARE TOLD APART, and something drives the branch ----
# "No manifest on this machine" and "the manifest is here and this lane is not
# in it" are different facts and get different answers: the first is the
# environment the tier fallback exists for, the second is an UNBUDGETED LANE
# that should be visible instead of quietly funded. That separation shipped
# CORRECT and DEFENDED BY NOTHING — a rarely-hit branch whose only output is a
# log line no test ever read, which is the shape that rots first. Two mutations
# proved the gap: re-merging the nothings (dropping the readable-manifest gate)
# and re-merging the stages (dropping $st from the flag key) both stayed green.
UD=$(date -u +%Y%m%d)
HB="$T2/hb"; HN="$T2/hn"; mkdir -p "$HB/logs" "$HB/flags" "$HB/bin" "$HN/logs" "$HN/flags" "$HN/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$HB/bin/"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$HN/bin/"
ubudget() { HARNESS="$1" CONTEXT_BUDGETS="$2" bash -c "$BUDGET_FOR; _budget_for \"$3\" \"$4\" \"$5\""; }
uc() { local f="$1/logs/ALERTS.log"; [ -f "$f" ] || { echo 0; return; }
       awk '/UNBUDGETED LANE/{n++} END{print n+0}' "$f"; }

# (1) MANIFEST PRESENT, LANE ABSENT -> say so, once, and still fund the call.
# execute/anyproj/claude is the real case: build-execute pins codex, so a claude
# execute lane matches nothing. The call must not die for want of a budget.
B1=$(ubudget "$HB" "$T2/budgets.json" execute anyproj claude)
ubudget "$HB" "$T2/budgets.json" execute anyproj claude >/dev/null   # same day, again
[ "$B1" = "150.00" ] && [ "$(uc "$HB")" = "1" ] \
  && [ -f "$HB/flags/alerted-unbudgeted-lane-execute-$UD" ] \
  && ok || bad "an unbudgeted lane is funded silently (or alerts on every call): budget=$B1 lines=$(uc "$HB")"

# (2) MANIFEST ABSENT -> a DIFFERENT nothing, and not this finding. Builders run
# without catalog/ by construction; an UNBUDGETED LANE line there would accuse
# the manifest author of an omission that is really a sync fact, on every call,
# on the machines that make the most of them.
B2=$(ubudget "$HN" "$T/no-such-budgets.json" execute anyproj claude)
[ "$B2" = "150.00" ] && [ "$(uc "$HN")" = "0" ] \
  && ok || bad "a missing manifest is reported as an unbudgeted lane — the two nothings are merged again (lines=$(uc "$HN"))"

# (3) ONE FLAG PER STAGE. ~29 callers share this path; a day-scoped flag without
# the stage lets the first lane to trip it mute every other lane until midnight
# — the same nit #88 fixed on the inert-budget alert, in a branch written after.
B3=$(ubudget "$HB" "$T2/budgets.json" chat anyproj claude)
[ "$B3" = "25.00" ] && [ "$(uc "$HB")" = "2" ] \
  && [ -f "$HB/flags/alerted-unbudgeted-lane-chat-$UD" ] \
  && ok || bad "the unbudgeted-lane flag is not per-stage — one lane mutes the rest for the day (lines=$(uc "$HB"))"

# (4) A LANE THAT IS BUDGETED MUST STAY SILENT. The finding only means anything
# if it fires ONLY on lanes with no declared ceiling: ~29 callers and one flag
# per stage per day turns a false positive into a daily accusation that the
# manifest is missing lanes it already has.
B4=$(ubudget "$HB" "$T2/budgets.json" triage medic claude)
[ "$B4" = "31.50" ] && [ "$(uc "$HB")" = "2" ] \
  && ok || bad "a lane that IS budgeted was reported unbudgeted (lines=$(uc "$HB"))"

# --- 10. the inert alert is PER-STAGE ---------------------------------------
# ~29 callers share this path; one daily flag let the first lane to trip it
# silence every other lane for the day.
grep -q 'alerted-agentcall-budget-inert-\$STAGE-' "$AC" \
  && ok || bad "the inert-alert flag is not per-stage — one lane would mute all the others"

# --- 11. THE TWO RESOLVERS MUST AGREE, and now something checks -------------
# "SAME RESOLVER AS THE CEILING JOIN" was a COMMENT over two implementations of
# one rule in two languages: Python ceiling_for in cost-rollup.sh, and its jq
# port inside _budget_for. They had already diverged — Python filters
# non-numeric ceilings, the port dropped that filter — so ONE null ceiling made
# the budget behave as if the whole manifest were absent while the ceiling join
# read the good lane at 400K. Budgeted against one ceiling, measured against
# another: the exact thing the port existed to prevent, reachable through a
# manifest typo.
#
# The day's lesson in its final form: THE SAME RULE WRITTEN TWICE IS ONE RULE
# UNTIL THE DAY IT ISN'T, AND NOTHING TELLS YOU WHICH DAY THAT IS — so this
# drives BOTH implementations over one fixture and asserts they select the same
# lane. It would have caught the dropped filter on its first run.
cat > "$T2/cross.json" <<'EOF'
{"lanes":[
 {"lane":"medic","runner":"claude","stage":"triage","project":"medic","ceiling_tokens":80000},
 {"lane":"alert","runner":"claude","stage":"triage","project":"alert-triage","ceiling_tokens":200000},
 {"lane":"anytriage","stage":"triage","ceiling_tokens":180000},
 {"lane":"plan","runner":"claude","stage":"plan","project":"p1","ceiling_tokens":400000},
 {"lane":"plan-malformed","runner":"claude","stage":"plan","project":"p1","ceiling_tokens":null},
 {"lane":"runner-only","stage":"review","runner":"claude","ceiling_tokens":80000},
 {"lane":"project-only","stage":"review","project":"bigproj","ceiling_tokens":400000},
 {"lane":"cliff","stage":"fix","project":"big","ceiling_tokens":400000,"runner_ceilings":{"grok":200000}}
]}
EOF
python3 - "$DIR" "$T2" <<'PYX' && ok || bad "the jq and Python resolvers select different lanes for the same input"
import sys, json, subprocess
DIR, T2 = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
ns = {"lanes": json.load(open(f"{T2}/cross.json"))["lanes"]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)

bf = subprocess.run(["sed", "-n", "/^_budget_for()/,/^}/p", f"{DIR}/bin/agent-call.sh"],
                    capture_output=True, text=True).stdout

def jq_cap(stage, project, runner):
    """The jq side, asked for the CEILING it selected rather than the dollars —
    comparing lane selection directly instead of through the pricing."""
    # Both bounds anchored to the jq program's OWN start: searching for the
    # terminator from byte 0 found the first `2>/dev/null)` anywhere in the
    # function, so any earlier line carrying one (the DB-first lane cap, phase 1
    # of docs/DB-COORDINATION-SPEC.md) sliced the program to nothing and this
    # cross-check silently compared Python against an empty string.
    start = bf.index("cap=$(CB=")
    prog = bf[start:bf.index("2>/dev/null)", start) + len("2>/dev/null)")]
    prog = prog.replace("cap=$(", "").rstrip(")")
    out = subprocess.run(["bash", "-c",
        f'st={stage}; pj={project}; rn={runner}; CONTEXT_BUDGETS={T2}/cross.json; {prog}'],
        capture_output=True, text=True).stdout.strip()
    return None if out in ("", "null") else int(float(out))

CASES = [("claude","triage","medic"), ("claude","triage","alert-triage"),
         ("grok","triage","project-2"), ("claude","plan","p1"),
         ("claude","review","bigproj"), ("claude","review","otherproj"),
         ("codex","execute","p1"),
         # PER-RUNNER CEILING, both sides. The xAI cliff is a fact about the
         # executor, so it cannot live in the job's ceiling — and a per-runner
         # cap that only one resolver honours is worse than none: the lane
         # would be JUDGED at 200K and FUNDED at 400K, which is "budgeted
         # against one ceiling, measured against another" arriving through a
         # feature added to prevent it.
         ("grok","fix","big"), ("claude","fix","big"), ("codex","fix","big")]
bad = []
for runner, stage, project in CASES:
    py = ns["ceiling_for"](runner, stage, project)
    jq = jq_cap(stage, project, runner)
    if py != jq:
        bad.append(f"{runner}/{stage}/{project}: python={py} jq={jq}")
assert not bad, "resolvers disagree:\n  " + "\n  ".join(bad)
PYX

echo "prompt-ceiling-test: $PASS pass, $FAIL fail"
echo "NOTE: this guard bounds ASSEMBLED prompts. It does not shrink agentic"
echo "      session growth, which is what the 620K grok mean actually is."
[ "$FAIL" -eq 0 ]
