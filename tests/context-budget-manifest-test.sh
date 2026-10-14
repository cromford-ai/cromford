#!/bin/bash
# tests/context-budget-manifest-test.sh — every LLM lane has a declared context
# budget, and every declared lane still exists.
#
# WHY A TEST AND NOT A DOCUMENT. docs/CONTEXT-COMPOSITION.md says lanes must be
# budgeted. A document says that once; this fails the build when a lane ships
# without a row. The distinction is the wave's own lesson: the pipefail/SIGPIPE
# hazard was written down in one test's comment and six other tests kept
# flaking on it for weeks. A lesson recorded in one file's comment is not a
# lesson the codebase has.
#
# BOTH DIRECTIONS, same shape as watchdog-boxes and the per-box overage test:
#   observed but unbudgeted -> a lane nobody sized, which is exactly how
#                              $18,863 accumulated unwatched
#   budgeted but unobserved -> a stale row that will be trusted as current
# Run from anywhere: tests/context-budget-manifest-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
MAN="$DIR/catalog/context-budgets.json"
DOC="$DIR/docs/CONTEXT-COMPOSITION.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- 1. the manifest is well formed ------------------------------------------
[ -s "$MAN" ] && jq -e . "$MAN" >/dev/null 2>&1 \
  && ok || bad "catalog/context-budgets.json is missing or not valid JSON"
[ -s "$DOC" ] && ok || bad "docs/CONTEXT-COMPOSITION.md is missing — the manifest without the contract is a table of unexplained numbers"

# Every row carries the fields a reviewer needs to judge it. A row with a number
# and no job statement cannot be argued with, which is the point of Rule 1.
# `runner` and `project` are OPTIONAL — absent means "any", which is how one
# lane covers a project's triage across the primary runner and its failover.
# Everything else is required.
MISSING=$(jq -r '[.lanes[] | select(
    (.lane|type)!="string" or (.stage|type)!="string"
    or (.job|type)!="string" or (.target_tokens|type)!="number"
    or (.ceiling_tokens|type)!="number" or (.composition|type)!="array"
    or (.bounds|type)!="array") | .lane // "<unnamed>"] | join(", ")' "$MAN")
[ -z "$MISSING" ] && ok || bad "manifest rows missing required fields: $MISSING"

# --- 2. the numbers have to make sense ---------------------------------------
BAD=$(jq -r '[.lanes[] | select(.target_tokens > .ceiling_tokens) | .lane] | join(", ")' "$MAN")
[ -z "$BAD" ] && ok || bad "target above ceiling (a budget that can never be met): $BAD"
ZERO=$(jq -r '[.lanes[] | select(.target_tokens <= 0 or .ceiling_tokens <= 0) | .lane] | join(", ")' "$MAN")
[ -z "$ZERO" ] && ok || bad "non-positive budget: $ZERO"

# Board lanes must sit under xAI's 200K cliff, where the WHOLE request bills
# double. A ceiling above it is not a budget, it is a price multiplier.
#
# THIS NOW APPLIES TO EVERY LANE, and the previous form was two ways wrong.
# It asked `has("runner")`, so a lane written as "runner": null — the shape a
# runner-agnostic lane naturally takes — counted as PINNED and skipped the
# check entirely. And its premise, that a pinned lane cannot serve grok, is
# false in the code: the failover ladder in agent-call.sh is stage-agnostic
# (tier-3 openrouter, tier-3b fireworks, tier-4 grok fire on rc!=0 for ANY
# stage) and the orchestrator carries ORC_SURVIVAL="codex grok". Every lane in
# this manifest is grok-reachable, so every lane is checked.
#
# The escape hatch is not an exemption: a lane whose JOB needs more than 200K
# declares a per-runner grok ceiling, which BOTH resolvers honour (asserted in
# tests/prompt-ceiling-test.sh, section 11) — so it is a bound, not a note.
# What is checked is the EFFECTIVE ceiling a grok call would resolve to.
#
# ⚠️ This is a deliberate change of rule, not a fix: the old form forbade any
# ceiling over the cliff outright, and taken with the ladder that forbids build
# lanes from existing at all (they measure 1.2M-16M). Flagged rather than made
# quietly — see the PR body.
OVER=$(jq -r '[.lanes[] | select(((.runner_ceilings.grok // .ceiling_tokens) > 200000)) | .lane] | join(", ")' "$MAN")
[ -z "$OVER" ] \
  && ok || bad "a lane resolves ABOVE the 200K cliff on grok, where the whole request bills double: $OVER"

# ...AND THE BOUND MUST SAY WHAT UNIT IT IS IN. 200,000 is a PER-REQUEST prompt
# threshold; the resolver compares it against this manifest's cumulative
# per-call context. A 25-turn session averaging 60K per request reads 1.5M and
# breaches with zero requests over the cliff. The cap still binds in the safe
# direction — a session containing a real crossing always exceeds it — so this
# is a CONSERVATIVE bound, and the honest failure mode is a reader quoting a
# breach as a confirmed doubled bill.
#
# Rule 8's lesson arriving at a BOUND for the first time: a number in the wrong
# unit is not a measurement, and a bound in a different unit from the thing it
# protects against is a coincidence that happens to hold. The label is the
# deliverable — the fleet captures per-request prompt tokens from no runner, so
# there is nothing to recompute.
NOUNIT=$(jq -r '[.lanes[] | select(has("runner_ceilings"))
  | select(((.runner_ceilings_note // "") | test("(?i)cumulative")) and ((.runner_ceilings_note // "") | test("(?i)per.request")) | not)
  | .lane] | join(", ")' "$MAN")
[ -z "$NOUNIT" ] \
  && ok || bad "a per-runner ceiling does not say it is a CUMULATIVE cap against a PER-REQUEST cliff — the next reader will quote a breach as a doubled bill: $NOUNIT"
grep -q 'CUMULATIVE, NOT PER-REQUEST' "$DIR/bin/cost-rollup.sh" \
  && ok || bad "over_200k_share ships without the same caveat — the share is 'sessions over the bound', not 'requests that doubled'"

# --- 2b. BOUNDS CARRY A TRUTH VALUE, and an empty list is not a claim --------
# Bare mechanism names dropped the only thing that matters about a bound:
# whether it is known to work. `--max-budget-usd $2.00` reads as enforced when
# it is UNVERIFIED under subscription OAuth; `[]` reads as "unfilled" when the
# codex lanes have a positive negative to state — no cap exists and the CLI
# silently accepts unknown keys, so one could never be added blind.
#
# Same lesson as #78's [] meaning both healthy and unreadable: an empty
# collection standing in for a meaningful negative is a claim nobody made.
EMPTY=$(jq -r '[.lanes[] | select((.bounds|length) == 0) | .lane] | join(", ")' "$MAN")
[ -z "$EMPTY" ] \
  && ok || bad "lanes with an EMPTY bounds list — say 'none, because X' rather than leaving it blank: $EMPTY"
# INERT joins the vocabulary 2026-08-25, and it is a widening — flagged, not
# slipped in. The orchestrator's turn cap is now the first bound MEASURED TO NOT
# WORK: its self-check is VERIFIED (it ran, priced a live turn, and reported)
# while the cap itself did nothing (a $4.67 turn completed against $2.00). The
# old four words had no way to say that, so the state would have had to be
# recorded as VERIFIED — which a skimming reader takes as "the cap works", the
# most expensive possible misreading of a bound that does not.
NOSTATUS=$(jq -r '[.lanes[] | select([.bounds[] | test("VERIFIED|UNVERIFIED|PENDING|INERT|none")] | all | not) | .lane] | join(", ")' "$MAN")
[ -z "$NOSTATUS" ] \
  && ok || bad "bounds without a truth value (VERIFIED / UNVERIFIED / PENDING / INERT / none): $NOSTATUS"
# ...and INERT must carry its evidence, or it is just a shrug with a strong word
# in it. A bound measured not to work is a claim, and a claim needs a basis.
# --- 2c. EVIDENCE AND ITS FINDING, KEYED PER BOUND ---------------------------
# A lane can carry more than one convicted bound (alert-triage carries two), so
# bounds_evidence is keyed by the bound's [scope:id] tag. Both directions:
# an INERT bound needs its entry, and an entry needs its INERT bound — evidence
# outliving its finding reads exactly like evidence supporting it.
python3 - "$MAN" <<'@EV@' && ok || bad "bounds_evidence and INERT bounds are out of step"
import json, re, sys
man = json.load(open(sys.argv[1]))
bad = []
for l in man["lanes"]:
    ev = l.get("bounds_evidence") or {}
    inert = set()
    for b in l["bounds"]:
        m = re.match(r"^\[([a-z]+:[a-z0-9_]+)\]", b)
        if not m:
            bad.append(f"{l['lane']}: untagged bound {b[:40]!r}")
            continue
        if "INERT" in b:
            inert.add(m.group(1))
    for bid in inert - set(ev):
        bad.append(f"{l['lane']}: bound {bid} is INERT with no bounds_evidence entry")
    for bid in set(ev) - inert:
        bad.append(f"{l['lane']}: bounds_evidence[{bid}] has no INERT bound — the finding was retired and its evidence was not")
assert not bad, "; ".join(bad[:4])
@EV@

# --- 2d. A NON-LANE-SCOPED BOUND IS ONE FACT, WHEREVER IT IS DECLARED -------
# GENERIC over the scope tag, which is the point. The previous version of this
# guard was hardcoded to --max-budget-usd and cured that INSTANCE while the
# CLASS had two more live members: `grok --max-turns` (runner-scoped, 2 lanes)
# and `prompt_guard` (harness-scoped, ONE implementation declared on 8 lanes —
# a single finding there would need eight hand edits and would drift on the
# first one someone missed).
#
# scope says what the bound is a property of: an ACCOUNT's billing mode, a
# RUNNER's CLI, the HARNESS's own code, or this LANE alone. Only the last may
# legitimately differ between lanes.
python3 - "$MAN" <<'@SC@' && ok || bad "a non-lane-scoped bound reads differently on different lanes"
import json, re, sys
from collections import defaultdict
man = json.load(open(sys.argv[1]))
TRUTH = ("INERT", "VERIFIED", "UNVERIFIED", "PENDING", "none")
def truth_of(text):
    # INERT wins when present: it is the strongest claim about the bound, and a
    # bound can be "self-check VERIFIED" while the bound itself does nothing.
    if "INERT" in text:
        return "INERT"
    for t in TRUTH:
        if t in text:
            return t
    return "?"
seen = defaultdict(dict)
for l in man["lanes"]:
    for b in l["bounds"]:
        m = re.match(r"^\[([a-z]+):([a-z0-9_]+)\]", b)
        if not m:
            continue
        scope, bid = m.group(1), m.group(2)
        if scope == "lane":
            continue        # lane-scoped bounds legitimately differ
        seen[f"{scope}:{bid}"][l["lane"]] = truth_of(b)
bad = []
for bid, lanes in seen.items():
    vals = set(lanes.values())
    if len(vals) > 1:
        agree = max(lanes.values(), key=list(lanes.values()).count)
        n = sum(1 for v in lanes.values() if v == agree)
        bad.append(f"{bid}: only {n} of {len(lanes)} declaring lanes say {agree} ({lanes})")
assert not bad, "; ".join(bad[:3])
@SC@

# --- 3. EVERY LANE DECLARES ITS SCOPED DELTA ---------------------------------
# Rule 3's asymmetry is the design: trim what a lane consults, never what it is
# deciding about. A row with no delta component has not said what it must never
# trim, which is the part that produces a confident wrong answer.
NODELTA=$(jq -r '[.lanes[] | select([.composition[].purpose | ascii_downcase | test("delta|sacred")] | any | not) | .lane] | join(", ")' "$MAN")
[ -z "$NODELTA" ] && ok || bad "lanes that never name their scoped delta (the thing that must NOT be trimmed): $NODELTA"

# --- 3b. A NULL MEASUREMENT MUST SAY WHICH NULL -----------------------------
# 10 lanes carry measured_before: null and only one carried a note, so nine
# nulls meant "never measured" and "withdrawn as wrong-unit" indistinguishably.
# That is the []-lesson one field over: a value meaning "nothing here" has to
# say WHICH nothing.
NONOTE=$(jq -r '[.lanes[] | select(.measured_before == null and (has("measured_before_note") | not)) | .lane] | join(", ")' "$MAN")
[ -z "$NONOTE" ] \
  && ok || bad "measured_before is null with no note — say whether it was never measured or withdrawn: $NONOTE"

# --- 3c. EVERY LANE IS EITHER MEASURED OR DECLARED UNMEASURED ---------------
# Rule 8 in the doc: a declared ceiling nobody has compared against a real
# observation is a POLICY number, and until it has been compared it is a floor.
# The manifest shipped 11 such numbers and the only signal of that was a null
# field, which reads exactly like a lane whose number is fine. So a lane now
# carries `measured` (an observation, in the declared unit, with its window and
# source) or `_unmeasured` with a reason. Silence is not a permitted state.
UNSAID=$(jq -r '[.lanes[] | select((has("measured") | not) and ((._unmeasured // "") | length) == 0) | .lane] | join(", ")' "$MAN")
[ -z "$UNSAID" ] \
  && ok || bad "lanes with neither a measurement nor a declared reason for having none: $UNSAID"
THIN=$(jq -r '[.lanes[] | select(has("measured")) | select(
    (.measured.unit // "") == "" or (.measured.window // "") == "" or (.measured.source // "") == ""
    or (.measured.calls // 0) <= 0 or (.measured.per_call_mean // 0) <= 0) | .lane] | join(", ")' "$MAN")
[ -z "$THIN" ] \
  && ok || bad "a measurement without unit, window, source or a positive sample is not a measurement: $THIN"

# THE UNIT IS PART OF THE NUMBER. orchestrator-turn's original figure was a
# SESSION-PEAK cache_read compared against a per-call ceiling — two different
# quantities that look identical in JSON, and the join reads healthy forever.
# The unit string is checked against the manifest's own _units declaration, so
# a future re-measure in the wrong quantity fails here instead of silently
# becoming the new baseline.
WRONGU=$(jq -r --arg u "input_toks + cache_read" \
  '[.lanes[] | select(has("measured")) | select(.measured.unit != $u) | .lane] | join(", ")' "$MAN")
[ -z "$WRONGU" ] && jq -e '._units | test("input_toks \\+ cache_read")' "$MAN" >/dev/null \
  && ok || bad "a measurement is stated in a unit the manifest does not declare — the wrong-unit failure that made the original figure meaningless: $WRONGU"

# --- 4. COMPLETENESS, both directions ----------------------------------------
# Against real fleet data when it exists (on the hub), against a fixture
# otherwise — so the comparison logic itself is proven in CI, where there is no
# cost.csv. A completeness check that only runs where nobody looks is the same
# class of dead guard this whole wave has been removing.
# ONE RESOLVER. This asks the join's OWN ceiling_for(): a row is unbudgeted iff
# that returns None. The previous version keyed on runner/stage alone, so
# "claude/triage exists" read as budgeted while ceiling_for returned None and
# exempted the row — two keys for one question, and a row satisfied both by
# matching neither. Measured live: every project's claude/triage rows
# (project-2 1358, project-1 1235, project-4 880, project-3 201, project-5 133 in 7d)
# fell through both.
check_completeness() { # check_completeness <fleet-cost.csv>
  local csv="$1"
  python3 - "$DIR" "$MAN" "$csv" <<'@CP@'
import sys, csv as _csv, json
DIR, MAN, CSVF = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
ns = {"lanes": json.load(open(MAN))["lanes"]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
seen = set()
for r in _csv.DictReader(open(CSVF)):
    if not r.get("runner") or not r.get("stage"):
        continue
    key = (r["runner"], r["stage"], r.get("project", ""))
    if key in seen:
        continue
    seen.add(key)
    if ns["ceiling_for"](*key) is None:
        print("/".join(key))
@CP@
}

# THE LIVE SHAPE, from the hub's own 7d claude/triage counts: every project
# runs triage on BOTH the primary runner and the claude failover, and only
# medic and alert-triage were ever pinned. Keyed on runner/stage alone, all of
# project-2 (1358 rows), project-1 (1235), project-4 (880), project-3 (201) and project-5
# (133) read as budgeted while the ceiling join exempted them — most of triage,
# invisible to both guards.
cat > "$T/fixture.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
2026-08-24T10:00:00Z,hub,project-2,triage,grok,grok-4.6,0,60,300000,100,0,0,1.00,metered
2026-08-24T10:01:00Z,hub,project-2,triage,claude,claude-fable-5,0,60,50,100,250000,0,1.00,subscription
2026-08-24T10:02:00Z,hub,project-1,triage,claude,claude-fable-5,0,60,50,100,250000,0,1.00,subscription
2026-08-24T10:03:00Z,hub,medic,triage,claude,claude-sonnet-5,0,60,50,100,20000,0,1.00,subscription
2026-08-24T10:04:00Z,hub,alpha-os,plan,claude,claude-opus-5,0,60,50000,100,0,0,2.00,subscription
2026-08-24T10:05:00Z,hub,alpha-os,newstage,claude,claude-opus-5,0,60,50000,100,0,0,2.00,subscription
EOF
UNBUDGETED=$(check_completeness "$T/fixture.csv")
grep -q 'claude/newstage' <<<"$UNBUDGETED" \
  && ok || bad "the completeness check does not catch an unbudgeted lane — it would pass anything"
grep -q 'grok/triage' <<<"$UNBUDGETED" \
  && bad "a budgeted lane was reported as unbudgeted — the check would cry wolf on every run" || ok

# THE ESCAPE, closed: a project's CLAUDE triage must resolve to the same lane
# its grok triage does. Pinning medic must not exempt every other project.
grep -q 'claude/triage/project-2' <<<"$UNBUDGETED" \
  && bad "a project's claude triage is unbudgeted — the failover runner must inherit the project's triage ceiling" || ok
grep -q 'claude/triage/project-1' <<<"$UNBUDGETED" \
  && bad "project-1 claude triage is unbudgeted — most of triage volume would be exempt from the ceiling" || ok
grep -q 'claude/triage/medic' <<<"$UNBUDGETED" \
  && bad "medic is a pinned lane and must stay budgeted" || ok

# ONE RESOLVER: whatever answers "is this budgeted" must BE the code that
# answers "is this over budget". Asserted by construction — the same
# ceiling_for decides both, so a row cannot satisfy one by matching neither.
grep -q 'ceiling_for' "$DIR/tests/context-budget-manifest-test.sh" \
  && ok || bad "completeness no longer asks the join's own resolver"
# ...and specificity must rank, or a pinned lane and a catch-all tie.
# EXTRACTION COUPLING, stated: this and the block below lift ceiling_for by
# string-index on "    def ceiling_for(" and "    out = []", then re-indent with
# l[4:]. It fails LOUD (an index error, not a silent pass) but it reads the
# function's exact indentation, so reformatting ceiling_for breaks two tests.
# There is no entry point to drive here the way the capture test drives
# --shape-stdin; if one is ever added, prefer it.
python3 - "$DIR" "$MAN" <<'@SP@' && ok || bad "the most specific lane must win over a catch-all"
import sys, json
DIR, MAN = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
# DISCRIMINATING ON PURPOSE: the pinned lane's ceiling is HIGHER than the
# catch-all's. A first version had the pinned lane also being the strictest, so
# "most specific" and "strictest" agreed and dropping the specificity ranking
# left the test green — the fixture could not tell the two rules apart.
ns = {"lanes": [
  {"lane": "catchall", "stage": "triage", "ceiling_tokens": 180000},
  {"lane": "pinned", "stage": "triage", "project": "buildy", "runner": "claude", "ceiling_tokens": 400000},
]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
assert ns["ceiling_for"]("claude", "triage", "buildy") == 400000, "the most SPECIFIC lane must win, not the strictest"
assert ns["ceiling_for"]("grok", "triage", "alpha-os") == 180000, "the catch-all covers everything else"
@SP@

# AND AGAINST THE REAL FLEET SHAPE, IN CI. The block below runs this for real
# — but only on the hub, and nobody runs the suite on the hub, so the property
# has never once spoken. That is this wave's own failure shape wearing a test's
# clothes: a guard whose only execution path is a machine no one executes it on.
# tests/fixtures/live-lane-triples.txt is a committed snapshot of the fleet's
# distinct (runner,stage,project) keys, so the check now runs everywhere.
#
# A triple must resolve to a ceiling, OR its stage must be listed in the
# manifest's _unbudgeted_stages — declared debt, reviewable, with counts. A NEW
# undeclared stage still fails, which is the whole point of declaring rather
# than exempting.
python3 - "$DIR" "$MAN" <<'@LT@' && ok || bad "live lanes resolve to NO ceiling and their stage is not declared as debt"
import sys, json
DIR, MAN = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
man = json.load(open(MAN))
ns = {"lanes": man["lanes"]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
declared = set((man.get("_unbudgeted_stages") or {}).get("stages", {}))
bad = []
for line in open(f"{DIR}/tests/fixtures/live-lane-triples.txt"):
    if line.startswith("#") or not line.strip():
        continue
    key = line.rsplit(" ", 1)[0]
    runner, stage, project = key.split("/", 2)
    if ns["ceiling_for"](runner, stage, project) is None and stage not in declared:
        bad.append(key)
assert not bad, "undeclared unbudgeted live lanes: " + ", ".join(bad[:8])
@LT@

# THE PIN PROPERTY, stated directly: a runner must never be the reason a live
# lane is unbudgeted. If any runner resolves for a (stage, project), every
# runner seen on it must — that is what dropping the pins bought, and it is the
# thing that silently broke three times before anyone looked.
python3 - "$DIR" "$MAN" <<'@PP@' && ok || bad "a live lane is budgeted on one runner and unbudgeted on another — a pin is deciding a workload's budget again"
import sys, json
from collections import defaultdict
DIR, MAN = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
ns = {"lanes": json.load(open(MAN))["lanes"]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
by_job = defaultdict(dict)
for line in open(f"{DIR}/tests/fixtures/live-lane-triples.txt"):
    if line.startswith("#") or not line.strip():
        continue
    runner, stage, project = line.rsplit(" ", 1)[0].split("/", 2)
    by_job[(stage, project)][runner] = ns["ceiling_for"](runner, stage, project)
split = {j: v for j, v in by_job.items()
         if any(c is None for c in v.values()) and any(c is not None for c in v.values())}
assert not split, "runner decides budgeted-ness for: " + ", ".join(f"{s}/{p} {v}" for (s, p), v in list(split.items())[:5])
@PP@

# --- 4b. THE OTHER DIRECTION: CALL SITES, NOT BILLS --------------------------
# THE HOLE THIS CLOSES, found 2026-08-28 by walking the call sites by hand.
# Every completeness check above reads tests/fixtures/live-lane-triples.txt or
# a cost.csv — the fleet's OBSERVED (runner, stage, project) keys. So a stage
# becomes visible to them only AFTER it has run and billed at least once inside
# a captured window. `revise` had been a real call site in bin/product-cmd.sh
# for weeks and appeared in none of them: it fell through to the $10.50
# plan/execute/review/fix TIER with no declared ceiling and no UNBUDGETED LANE
# alert, because bin/agent-call.sh only alerts on a lane it can see run.
#
# A guard keyed on observation cannot see a lane before its first bill. This one
# reads the SOURCE: every LITERAL stage argument at an agent-call.sh call site
# in bin/ must resolve to a ceiling, or be named in _unbudgeted_stages. It fires
# on the day the call site is written, which is the day it can still be cheap.
#
# LITERAL only, and that limit is stated rather than hidden: run-build.sh
# dispatches through "$stage", so execute/qa/takeover/probe are invisible here
# and are covered by the observed-lane checks above. The two directions overlap
# deliberately — neither is complete alone.
python3 - "$DIR" "$MAN" <<'@CS@' && ok || bad "a stage is passed to agent-call.sh in bin/ but resolves to NO ceiling and is not declared debt"
import sys, json, re, glob, os
DIR, MAN = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
man = json.load(open(MAN))
ns = {"lanes": man["lanes"]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
declared = set((man.get("_unbudgeted_stages") or {}).get("stages", {}))

# The path prefix is what makes this a CALL and not prose: every real call site
# invokes the script through a variable ("$HARNESS/bin/agent-call.sh",
# "$SELF/agent-call.sh"). Without it the scan reads "the agent-call.sh header
# upgrade" as a stage called `header` — four such phantoms in bin/ today.
# The second argument is the cost-row PROJECT. When it is a literal too it is
# resolved as written: a lane pinned to one workload (the rule-miner lane is
# stage mine, project rule-miner) budgets exactly that call and no other, so a
# placeholder project would report it unbudgeted. A non-literal project
# ("$PROJECT") still resolves as `any-project`, i.e. only a stage-wide lane.
PAT = re.compile(r'(?:^|[\s(`])"?\$\{?\w+\}?/(?:bin/)?agent-call\.sh"?\s+"?([a-z][a-z_-]*)\b(?:"?\s+([a-z][a-z0-9_.-]*)(?=[\s"]))?')

def scan(files, calls=None):
    found = {}
    for f in files:
        for n, line in enumerate(open(f, errors="replace"), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in PAT.finditer(line):
                found.setdefault(m.group(1), f"{os.path.basename(f)}:{n}")
                if calls is not None:
                    calls.append((m.group(1), m.group(2) or "any-project", f"{os.path.basename(f)}:{n}"))
    return found

calls = []
sites = scan(sorted(glob.glob(f"{DIR}/bin/*.sh")), calls)

# A regex that matched nothing would pass this check on every possible manifest,
# which is the dead-guard shape this suite keeps finding. Both controls run.
assert len(sites) >= 10, f"the call-site scan found only {len(sites)} stages — it has stopped matching real call sites"
assert "triage" in sites and "review" in sites, f"the scan missed the busiest stages: {sorted(sites)}"
import tempfile
with tempfile.TemporaryDirectory() as td:
    open(f"{td}/prose.sh", "w").write(
        'echo "the agent-call.sh header upgrade"\n'
        '[ -x "$BIN/agent-call.sh" ] || exit 1\n')
    assert not scan([f"{td}/prose.sh"]), "the scan reads prose as a call site — it would cry wolf on every run"

bad = sorted({f"{st} ({where})" for st, proj, where in calls
              if ns["ceiling_for"]("claude", st, proj) is None and st not in declared})
assert not bad, "undeclared call-site stages: " + ", ".join(bad)
@CS@

# On the hub, run it for real.
FLEET="/root/harness/state/cost/fleet-cost.csv"
if [ -r "$FLEET" ]; then
  REAL=$(check_completeness "$FLEET")
  [ -z "$REAL" ] \
    && ok || bad "lanes running in production with NO declared budget: $(tr '\n' ' ' <<<"$REAL")"
else
  ok   # not the hub; the fixture above proved the logic
fi

# Stale rows: a manifest entry for a stage nothing references any more.
#
# SCOPE, and this cost a false positive to learn: run-build.sh dispatches its
# stages through a VARIABLE ("$stage"), so grepping for literal `agent-call.sh
# execute` finds nothing and would condemn every build lane as stale. A literal
# grep cannot prove absence when the call site is dynamic. So the check looks
# for the stage name anywhere in bin/ or prompts/ — weaker, but it only claims
# what it can actually show.
for S in $(jq -r '.lanes[].stage' "$MAN" | sort -u); do
  case "$S" in orchestrator|chat) continue ;; esac   # not agent-call stages
  grep -rqw "$S" "$DIR"/bin/*.sh "$DIR"/prompts/*.md 2>/dev/null \
    || bad "manifest declares stage '$S' but nothing in bin/ or prompts/ mentions it — stale row"
done
ok

# --- 5. THE WIRING CHECKS, pulled forward ------------------------------------
# Four times in one session a unit was fully covered while nothing asserted it
# was CALLED. These are the generic version, applied to the guards this wave
# shipped — the risk is not that any one is dead today, it is the pattern not
# landing while the lesson is fresh.
AC="$DIR/bin/agent-call.sh"
grep -q 'PROMPT=$(prompt_guard "$PROMPT")' "$AC" \
  && ok || bad "prompt_guard is defined but never invoked — the assembly cap would be dead code"
# ...and it must run BEFORE provenance, or the recorded sha describes a prompt
# that was never sent.
GUARD_LN=$(grep -n 'PROMPT=$(prompt_guard' "$AC" | head -1 | cut -d: -f1)
PROV_LN=$(grep -n 'PROMPT_SHA=' "$AC" | head -1 | cut -d: -f1)
[ -n "$GUARD_LN" ] && [ -n "$PROV_LN" ] && [ "$GUARD_LN" -lt "$PROV_LN" ] \
  && ok || bad "prompt_guard runs after provenance — the sha would describe an unsent prompt"

# Every bin/ function whose name ends _guard/_check/_hit must be called
# somewhere in its own file. Generic, so the next guard is covered without
# anyone remembering to add a case.
#
# TWO LIMITS, both ABSENT rather than handled — green today by luck, not by
# coverage, and named here so the next false fire arrives with a warning
# instead of a mystery:
#
#   1. DYNAMIC DISPATCH. A call site like "${stage}_check" is invisible to this
#      grep, so a dynamically-dispatched guard reports as uncalled. Nothing in
#      bin/ dispatches a guard that way today. The same blind spot bit the
#      staleness check above, where run-build dispatches stages through a
#      variable — a literal grep cannot prove absence when the call site is
#      built at runtime.
#   2. THE TRAILING CLASS. It matches a call followed by a space or a quote,
#      which misses `if fn_guard; then`, `fn_guard;`, `$(fn_guard)`,
#      `fn_guard&&` and a bare end-of-line. All three of today's guards happen
#      to be called with a trailing space, so this is honestly green — but
#      renaming orc_fresh() to the *_check convention would false-fire it
#      immediately. Widening the class is the fix; whoever does it must
#      re-verify that the DEFINITION line still does not self-match, since a
#      wider trailing class can reopen exactly that bug.
UNCALLED=""
for F in "$DIR"/bin/*.sh; do
  for FN in $(grep -oE '^[a-z_]+(_guard|_check|_hit)\(\)' "$F" 2>/dev/null | tr -d '()'); do
    # Count CALLS, not mentions: the definition line is `name() {`, which the
    # call pattern deliberately does not match. Counting all occurrences and
    # expecting >=2 read a correctly-called function as uncalled, because the
    # definition never matched in the first place.
    [ "$(grep -cE "(^|[^a-z_])$FN[ \"]" "$F")" -ge 1 ] || UNCALLED="$UNCALLED $(basename "$F"):$FN"
  done
done
[ -z "$UNCALLED" ] \
  && ok || bad "guard functions defined but never called:$UNCALLED"

# --- 6. THE LIVE JOIN: three states, and two of them used to look alike ------
# [] meant BOTH "checked, all lanes within budget" AND "could not read the
# manifest". To any consumer [] IS "all fine", so an unreadable catalog read as
# a clean bill of health — the None-vs-0 distinction this wave built three
# times elsewhere, violated inside the change that documents it.
#
# It survived because the manifest path was a hardcoded absolute with no env
# seam, so no test could drive the join at all. That is not incidental: an
# untestable path is where this class lives.
python3 - "$DIR" "$T" <<'@PY@' && ok || bad "the ceiling join must distinguish healthy / breach / unreadable"
import sys, json, importlib.util, os, datetime
DIR, T = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("def ceiling_breaches("):body.index("def overage_accounts(")]
mod = "import json, os" + chr(10) + fn
open(f"{T}/cb.py", "w").write(mod)
spec = importlib.util.spec_from_file_location("cb", f"{T}/cb.py")
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)

man = {"lanes": [{"lane": "l", "runner": "grok", "stage": "triage",
                  "job": "j", "target_tokens": 50000, "ceiling_tokens": 180000,
                  "composition": [], "bounds": []}]}
# Stats rows now carry their own key fields — the join matches a lane on
# (runner, stage) plus project, so a row must say which lane it is.
def row(mean): return {"runner": "grok", "stage": "triage", "project": "alpha-os",
                       "mean_input": mean, "calls": 1}
open(f"{T}/budgets.json", "w").write(json.dumps(man))
os.environ["CONTEXT_BUDGETS"] = f"{T}/budgets.json"

# healthy -> [] AND a status saying it was actually checked
b, st = cb.ceiling_breaches({"grok/triage/alpha-os": row(50000)})
assert b == [] and st == "checked", (b, st)

# breach -> named, with both numbers so it can be acted on
b, st = cb.ceiling_breaches({"grok/triage/alpha-os": row(900000)})
assert b and "900000" in b[0] and "180000" in b[0], b
assert st == "checked", st

# UNREADABLE -> NOT [], and the status says why. This is the assertion the
# whole fold exists for.
os.environ["CONTEXT_BUDGETS"] = f"{T}/does-not-exist.json"
b, st = cb.ceiling_breaches({"grok/triage/alpha-os": row(900000)})
assert b is None, f"an unreadable manifest returned {b!r} — indistinguishable from healthy"
assert "unreadable" in st, st
@PY@

# --- 7. THE UNIT, AND THE GUARD'S FIRST REAL FIRING -------------------------
# Two gaps this section exists to close, both found by deleting the fix and
# watching nothing go red:
#   * the + cache_read term could be removed and all 34 suites stayed green,
#     because the only fixture was grok-shaped, where input_toks already
#     carries the context. The unit fix was untested in the shape it was FOR.
#   * the ceiling join was corrected from never-fires to fires-wrong: keyed on
#     runner, medic's 80K governed every claude lane, so a build lane
#     legitimately at 400K read as a breach.
#
# "Correcting an inert guard is only half a fix — check what it does the first
# time it can actually fire."
python3 - "$DIR" "$T" <<'PYK' && ok || bad "the stats unit and the per-lane ceiling match must both hold"
import sys, json, importlib.util, os, datetime, csv
DIR, T = sys.argv[1], sys.argv[2]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
mod = ("import csv, json, os, datetime, sys\nnow = datetime.datetime.utcnow()\n"
       "CD = sys.argv[1]\n"
       + body[body.index("def runner_input_stats("):body.index("def overage_accounts(")]
       + body[body.index("def ceiling_breaches("):body.index("def overage_accounts(")])
open(f"{T}/cb2.py", "w").write(mod)
spec = importlib.util.spec_from_file_location("cb2", f"{T}/cb2.py")
cb2 = importlib.util.module_from_spec(spec); sys.argv = ["cb2", T]
spec.loader.exec_module(cb2)

ts = (datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
hdr = ("ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,"
       "cache_read,cache_write,cost_usd,billing_mode")
rows = [
  # CLAUDE-SHAPED: the context is in cache_read and input_toks is tiny. This is
  # the shape the unit fix exists for, and the one no fixture had.
  f"{ts},hub,medic,triage,claude,claude-sonnet-5,0,60,50,100,250000,0,1.00,subscription",
  # a build lane legitimately far above medic's 80K ceiling
  f"{ts},hub,alpha-os,plan,claude,claude-opus-5,0,60,50,100,300000,0,2.00,subscription",
  # grok, where input_toks already carries the context
  f"{ts},hub,alpha-os,triage,grok,grok-4.6,0,60,300000,100,0,0,1.00,metered",
]
open(f"{T}/fleet-cost.csv", "w").write(hdr + "\n" + "\n".join(rows) + "\n")

st = cb2.runner_input_stats(7)
medic = st["claude/triage/medic"]
assert medic["mean_input"] == 250050, f"claude context must be input+cache_read: {medic}"
# The cliff metric is grok-only and computed on PROMPT tokens. Under the
# combined unit a normal claude lane read 1.0 — 100% over a cliff it does not
# have.
assert "over_200k_share" not in medic, f"the xAI cliff is not a claude fact: {medic}"
grok = st["grok/triage/alpha-os"]
assert grok["over_200k_share"] == 1.0, grok

# THE GUARD'S FIRST REAL FIRING: every lane here is inside its OWN ceiling.
open(f"{T}/budgets.json", "w").write(json.dumps({"lanes": [
  {"lane": "alerts-medic", "runner": "claude", "stage": "triage", "project": "medic",
   "job": "j", "target_tokens": 30000, "ceiling_tokens": 400000, "composition": [], "bounds": []},
  {"lane": "build-plan", "runner": "claude", "stage": "plan",
   "job": "j", "target_tokens": 120000, "ceiling_tokens": 400000, "composition": [], "bounds": []},
  {"lane": "board-triage", "runner": "grok", "stage": "triage",
   "job": "j", "target_tokens": 50000, "ceiling_tokens": 400000, "composition": [], "bounds": []},
]}))
os.environ["CONTEXT_BUDGETS"] = f"{T}/budgets.json"
b, status = cb2.ceiling_breaches(st)
assert status == "checked", status
assert b == [], f"no lane is over ITS OWN ceiling, so nothing may be reported: {b}"

# ...and it still fires when a lane really is over.
open(f"{T}/budgets.json", "w").write(json.dumps({"lanes": [
  {"lane": "alerts-medic", "runner": "claude", "stage": "triage", "project": "medic",
   "job": "j", "target_tokens": 30000, "ceiling_tokens": 80000, "composition": [], "bounds": []},
]}))
b, _ = cb2.ceiling_breaches(st)
assert len(b) == 1 and "medic" in b[0], f"a lane genuinely over its ceiling must be named: {b}"
PYK

# --- 8. THE TIE-BREAK IS A DECISION, not a default --------------------------
# A runner-only lane and a project-only lane both matched at equal weight, so
# ties fell to min(ceiling) and the strictest lane silently governed a workload
# it did not describe — #86's false alarm one level up, arriving as a default
# nobody designed. No fixture covered a tie at all, which is the same habit one
# case over: the shape that was never exercised is the shape that was wrong.
#
# project outweighs runner because project identifies the WORKLOAD and runner
# only names the executor.
python3 - "$DIR" <<'PYT' && ok || bad "a project-pinned lane must beat a runner-pinned one"
import sys, json
DIR = sys.argv[1]
src = open(f"{DIR}/bin/cost-rollup.sh").read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
fn = body[body.index("    def ceiling_for("):body.index("    out = []", body.index("    def ceiling_for("))]
ns = {"lanes": [
  # The exact shape the reviewer built: a strict runner-only lane and a
  # generous project-only lane, both matching claude/triage/bigproj.
  {"lane": "runner-only",  "stage": "triage", "runner": "claude",     "ceiling_tokens": 80000},
  {"lane": "project-only", "stage": "triage", "project": "bigproj",   "ceiling_tokens": 400000},
]}
exec("\n".join(l[4:] for l in fn.split("\n")), ns)
got = ns["ceiling_for"]("claude", "triage", "bigproj")
assert got == 400000, (
    f"resolved to {got}: the strict runner-only lane governed a workload it does "
    "not describe. Under equal weights this ties and min() picks 80000.")
# ...and a runner-only lane still governs a project it is the only match for.
assert ns["ceiling_for"]("claude", "triage", "otherproj") == 80000
# Both pinned (spec 3) still beats either single pin.
ns["lanes"].append({"lane": "both", "stage": "triage", "runner": "claude",
                    "project": "bigproj", "ceiling_tokens": 123456})
assert ns["ceiling_for"]("claude", "triage", "bigproj") == 123456
PYT

# --- 9. THE STAFF LANE HAS ITS ONE BUDGET ROW (BH-5561) ----------------------
# TEST-CHANGE (lead review lr-5985 of 623ae9adc): this section required one
# `staff.<name>` row per agent, and section 4 let those rows pass on a soul
# file alone. Every staff agent calls the ONE stage staff-tick (the operator,
# 2026-10-12), so a per-agent row could never match a cost row. The guard now
# requires the row the code reads, and refuses a per-agent row coming back.
python3 - "$DIR" "$MAN" <<'@ST@' && ok || bad "the staff lane's budget row is wrong"
import sys, json, re, copy
DIR, MAN = sys.argv[1], sys.argv[2]
man = json.load(open(MAN))
src = open(f"{DIR}/bin/staff.sh").read()
m = re.search(r'agent-call\.sh" ([a-z][a-z0-9-]*) fleet', src)
assert m, "bin/staff.sh: no literal agent-call stage found"
stage = m.group(1)

def check(mm):
    rows = [l for l in mm["lanes"] if l.get("stage") == stage]
    per = sorted(l.get("stage") for l in mm["lanes"] if str(l.get("stage", "")).startswith("staff."))
    return rows, per

cut = copy.deepcopy(man)
cut["lanes"] = [l for l in cut["lanes"] if l.get("stage") != stage]
assert not check(cut)[0], "the guard does not see a removed staff-tick row"
rows, per = check(man)
assert len(rows) == 1, f"want one budget row for stage {stage}, got {len(rows)}"
assert not per, "per-agent staff rows match no cost row: " + ", ".join(per)
@ST@

echo "context-budget-manifest-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
