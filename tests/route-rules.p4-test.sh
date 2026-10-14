#!/bin/bash
# tests/route-rules.p4-test.sh — P4, PLAN-DRIVEN MODEL ROUTING IN SHADOW MODE.
#
# bin/lib/route-rules.sh reads a build's plan artifacts (plan.md, kind.txt,
# size-gate.txt, plan-gate.txt, planned-files.txt, ticket-meta.json), derives
# the plan's features, and evaluates the route_rules rows against them to say
# which execute model, review tier and test scope the build WOULD get. It only
# LOGS that: $BUILD/route-shadow.json, one pipeline.log line and a
# POST /api/route-shadow row. run-build never reads the answer.
#
# What is proved here, by driving the real library against a fake worker (a
# `curl` on PATH) — the worker's own SQL is proven by
# worker/jobs/test/route-rules.p4.test.js against node:sqlite:
#   A. the resolver, one case per rule (and the negatives around each), and
#      that the same input gives byte-identical output;
#   B. the would-be MODEL comes from model_routes (a model id nowhere in the
#      rules or this library), and the review model is always build.review's;
#   C. the shadow record is written (file + log line + worker row), fails open
#      when the worker is down, and is silent under the kill switches;
#   D. the run-build hook is LOG ONLY: the block is extracted verbatim from
#      bin/run-build.sh and run between two identical executions of the real
#      `# >>> execute prompt` block — the runner argv is byte-identical with
#      the hook, without it, and with a hostile route-rules.sh in its place;
#   E. review_tier_files is the same classifier review_tier runs on a diff;
#   F. bin/route-shadow-report.sh summarises the shadow rows (share that would
#      go to the lite role, by project, by rule) from the worker.
#
# Run from anywhere: tests/route-rules.p4-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/route-rules.sh"
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/flags" "$H/logs" "$H/state" "$T/fakebin" "$T/routes"
cp "$LIB" "$H/bin/lib/route-rules.sh" 2>/dev/null
cp "$DIR/bin/lib/review-tier.sh" "$DIR/bin/lib/model-route.sh" "$H/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
cp "$DIR/bin/route-shadow-report.sh" "$H/bin/route-shadow-report.sh" 2>/dev/null
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "${BEAT_SINK:-/dev/null}"\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The seeded rules (worker/jobs/schema.sql, the P4 block), as GET /api/route-rules
# answers them. Model ids appear NOWHERE here: a rule names a model_routes role.
cat > "$T/rules.json" <<'EOF'
{"rules":[
 {"name":"risk-surface","priority":10,"effect":"route","mode":"shadow","match":{"any":["u0","invariant_bearing","risk_surface"]},"execute_role":"build.execute","review_tier":"T2","test_scope":"full","tier_bump":0},
 {"name":"docs-tests-copy","priority":20,"effect":"route","mode":"shadow","match":{"all":["docs_only"],"none":["u0","invariant_bearing","risk_surface"]},"execute_role":"build.execute.lite","review_tier":"T0","test_scope":"minimal","tier_bump":0},
 {"name":"specified-small","priority":30,"effect":"route","mode":"shadow","match":{"all":["fully_specified"],"max_lines":150,"none":["u0","invariant_bearing","risk_surface"]},"execute_role":"build.execute.lite","review_tier":"T1","test_scope":"impact","tier_bump":0},
 {"name":"bounce-escalate","priority":100,"effect":"bump","mode":"shadow","match":{"bounce_rate_gt":0.3,"days":30,"min_reviews":5},"execute_role":"build.execute","review_tier":null,"test_scope":null,"tier_bump":1}
]}
EOF
# model_routes, as GET /api/model-routes/<role> answers: fake ids, so a would-be
# model can only have come from here.
route() { printf '{"role":"%s","project":null,"ladder":[{"position":0,"model":"%s","runner":"claude"}],"source":"hub"}' "$1" "$2" > "$T/routes/$1.json"; }
route build.execute model-frontier
route build.execute.lite model-lite
route build.review model-reviewer

# THE FAKE WORKER. FAKE=down -> every call a transport failure (curl rc 7).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data="" method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d|--data|--data-binary) data="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
[ "${FAKE:-up}" = down ] && exit 7
# FAKE=empty: a 200 with no body at all (jq 1.6 reads that as a valid answer)
[ "${FAKE:-up}" = empty ] && { printf '\n200'; exit 0; }
printf '%s %s\n' "$method" "${url#*/api}" >> "$REQS"
case "$url" in
  */api/model-routes/*)
    r="${url##*/api/model-routes/}"; r="${r%%\?*}"
    if [ -s "$ROUTES/$r.json" ]; then cat "$ROUTES/$r.json"; else printf '{"role":"%s","ladder":[],"source":"none"}' "$r"; fi
    printf '\n200' ;;
  */api/route-rules) cat "$RULES"; printf '\n200' ;;
  */api/route-shadow/bounce\?*)
    case "$url" in *rule=*) cat "$BOUNCE_CLASS" ;; *) cat "$BOUNCE_PROJECT" ;; esac; printf '\n200' ;;
  */api/route-shadow\?*|*/api/route-shadow)
    if [ "$method" = POST ]; then printf '%s\n' "$data" >> "$SHADOW_SINK"; printf '{"recorded":true}\n200'
    else cat "$SHADOW_ROWS"; printf '\n200'; fi ;;
  *) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
printf '{"reviewed":0,"blocked":0,"rate":null}' > "$T/bounce-none.json"

wenv() { # the environment every library call runs in
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HOME="$T" JOBS_URL="https://jobs.test" \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 JOBS_BOX=testbox REQS="$T/reqs" \
      ROUTES="$T/routes" RULES="${RULES:-$T/rules.json}" SHADOW_SINK="$T/shadow.sink" \
      SHADOW_ROWS="${SHADOW_ROWS:-$T/rows.json}" \
      BOUNCE_PROJECT="${BOUNCE_PROJECT:-$T/bounce-none.json}" BOUNCE_CLASS="${BOUNCE_CLASS:-$T/bounce-none.json}" \
      FAKE="${FAKE:-up}" BEAT_SINK="$T/beat.sink" "$@"
}

# mkbuild <dir> <planned-files...> — a build dir whose plan is fully specified
# and small unless a later edit says otherwise. Every artifact is the file the
# pipeline itself writes, in the shape it writes it.
mkbuild() {
  local b="$1"; shift
  scratch_rm "$b"; mkdir -p "$b"
  cat > "$b/plan.md" <<'EOF'
# Plan

## Tasks
### Task 1: do the thing
VALIDATE: npm test
SATISFIES: R1

## System invariants
None beyond the iron laws. This is a pure formatter: no stored state, no external side effect.

## Acceptance tests
- tests/unit/thing.test.ts asserts the thing

## Size
FILES: 2
LINES: 120

KIND: feature
SIZE: S
EOF
  printf 'KIND: feature\nKIND_SOURCE: plan\nKIND_REPRO: n/a\n' > "$b/kind.txt"
  printf 'SIZE_DECLARED: files=2 lines=120\nSIZE_VERDICT: within\n' > "$b/size-gate.txt"
  printf 'PLAN_TASKS\t1\nPLAN_TRACE: ok\n' > "$b/plan-gate.txt"
  printf '{"title":"TK-1: do the thing","labels":[],"body":""}\n' > "$b/ticket-meta.json"
  : > "$b/planned-files.txt"
  local f; for f in "$@"; do printf '%s\n' "$f" >> "$b/planned-files.txt"; done
}

# decide <build> -> the resolver's decision as `k=v` lines (rule, execute_role,
# review_tier, planned_tier, test_scope, bumped), against the fake worker.
decide() {
  wenv bash "$H/bin/lib/route-rules.sh" resolve "$1" proj-a 2>"$T/decide.err"
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
expect() { # expect <label> <decision> <rule> <execute_role> <review_tier> <test_scope> [bumped]
  local d="$2" got
  got="$(field "$d" rule)|$(field "$d" execute_role)|$(field "$d" review_tier)|$(field "$d" test_scope)|$(field "$d" bumped)"
  [ "$got" = "$3|$4|$5|$6|${7:-}" ] && ok || bad "$1: want $3|$4|$5|$6|${7:-}, got $got"
}

[ -s "$LIB" ] && ok || bad "bin/lib/route-rules.sh does not exist"

# ============================================================================
# A. the resolver, one case per rule
# ============================================================================
B="$T/b"
mkbuild "$B" src/lib/thing.ts tests/unit/thing.test.ts
expect "A1 specified-small: traced, sized, 120 lines, product code" "$(decide "$B")" specified-small build.execute.lite T1 impact

sed -i 's/^LINES: 120/LINES: 151/' "$B/plan.md"; sed -i 's/lines=120/lines=151/' "$B/size-gate.txt"
expect "A2 151 lines is over the cheap rule: the live role, the classifier's tier" "$(decide "$B")" "" build.execute T1 full
sed -i 's/^LINES: 151/LINES: 150/' "$B/plan.md"; sed -i 's/lines=151/lines=150/' "$B/size-gate.txt"
expect "A2b exactly 150 lines is inside" "$(decide "$B")" specified-small build.execute.lite T1 impact

mkbuild "$B" src/lib/thing.ts
printf 'PLAN_TASKS\t1\nPLAN_UNTRACED\t1\nPLAN_TRACE: untraced\n' > "$B/plan-gate.txt"
expect "A3 an untraced plan is not fully specified" "$(decide "$B")" "" build.execute T1 full

mkbuild "$B" src/lib/thing.ts
sed -i '/^## Size/,/^LINES/d' "$B/plan.md"; printf 'SIZE_VERDICT: undeclared\n' > "$B/size-gate.txt"
expect "A4 an unsized plan is not fully specified" "$(decide "$B")" "" build.execute T1 full

mkbuild "$B" src/lib/thing.ts
sed -i '/^## Acceptance tests/,/^$/d' "$B/plan.md"
expect "A5 a plan with no acceptance tests is not fully specified" "$(decide "$B")" "" build.execute T1 full

mkbuild "$B" src/lib/thing.ts
printf 'KIND: bug\nKIND_SOURCE: plan\nKIND_REPRO: missing\n' > "$B/kind.txt"
expect "A6 a bug with no complete reproduction is not fully specified" "$(decide "$B")" "" build.execute T1 full
printf 'KIND: bug\nKIND_SOURCE: plan\nKIND_REPRO: ok\n' > "$B/kind.txt"
expect "A6b a bug with its reproduction is" "$(decide "$B")" specified-small build.execute.lite T1 impact

# risk-surface, each of its three triggers
mkbuild "$B" prisma/schema.prisma src/lib/thing.ts
expect "A7 a schema file in the plan is risk surface" "$(decide "$B")" risk-surface build.execute T2 full
for f in src/app/api/webhooks/stripe/route.ts src/lib/auth/session.ts src/lib/billing/invoice.ts prisma/migrations/2026/migration.sql; do
  mkbuild "$B" "$f"
  expect "A7 $f is risk surface" "$(decide "$B")" risk-surface build.execute T2 full
done
mkbuild "$B" src/lib/thing.ts
printf 'KIND: migration\nKIND_SOURCE: plan\nKIND_REPRO: n/a\n' > "$B/kind.txt"
expect "A7b KIND: migration is risk surface whatever the files" "$(decide "$B")" risk-surface build.execute T2 full

mkbuild "$B" src/lib/thing.ts
printf '{"title":"TK-9.0: contract — the shared types","labels":[],"body":""}\n' > "$B/ticket-meta.json"
expect "A8 a split's unit 0 (<KEY>.0: title) stays frontier" "$(decide "$B")" risk-surface build.execute T2 full
mkbuild "$B" src/lib/thing.ts
printf '{"title":"TK-9.2: slice two","labels":[],"body":""}\n' > "$B/ticket-meta.json"
expect "A8b unit 2 of the same split is not unit 0" "$(decide "$B")" specified-small build.execute.lite T1 impact
mkbuild "$B" src/lib/thing.ts
printf '\nCONTRACT: exports ThingType from src/lib/thing.ts\n' >> "$B/plan.md"
expect "A8c a plan that declares a CONTRACT: line is unit 0" "$(decide "$B")" risk-surface build.execute T2 full

mkbuild "$B" src/lib/thing.ts
printf '\n## System invariants\n- the ledger row is written before the post (claim-before-post)\n' >> "$B/plan.md"
expect "A9 a plan that carries system invariants is invariant-bearing" "$(decide "$B")" risk-surface build.execute T2 full
mkbuild "$B" src/lib/thing.ts
printf '\n## System invariants\nNone.\n\n## Notes\nx\n' >> "$B/plan.md"
expect "A9b an invariants section that says None is not" "$(decide "$B")" specified-small build.execute.lite T1 impact
mkbuild "$B" src/lib/thing.ts
printf '\n```\n## System invariants\n- a sample inside a fence\n```\n' >> "$B/plan.md"
expect "A9c an invariants heading inside a code fence is not a section" "$(decide "$B")" specified-small build.execute.lite T1 impact

# B1 (review of #2288): the plan prompt (bin/lib/rb/plan.sh, '## System
# invariants') tells a SIZE S plan to write "None beyond the iron laws" plus one
# sentence of why. That is an EMPTY section, in every shape a model writes it.
inv_plan() { # inv_plan <section body...> — the fixture plan with its invariants section replaced
  mkbuild "$B" src/lib/thing.ts
  awk -v body="$1" '
    /^## System invariants/ { print; print body; skip = 1; next }
    skip && /^## / { skip = 0 }
    !skip' "$B/plan.md" > "$B/plan.md.new" && mv "$B/plan.md.new" "$B/plan.md"
}
inv_plan "None beyond the iron laws. The change is a copy tweak with no state and no side effect."
expect "A9d 'None beyond the iron laws.' + why (the prompt's exact wording) is not invariant-bearing" \
  "$(decide "$B")" specified-small build.execute.lite T1 impact
inv_plan "None beyond the iron laws
This helper reads one file and prints a line; nothing persists."
expect "A9e the why on its own line after 'None beyond the iron laws' is still an empty section" \
  "$(decide "$B")" specified-small build.execute.lite T1 impact
inv_plan "- **None beyond the iron laws** — no cross-run state, no external side effect."
expect "A9f a bulleted, bold 'None beyond the iron laws' is still empty" "$(decide "$B")" specified-small build.execute.lite T1 impact
inv_plan "NONE: pure function."
expect "A9g upper-case NONE with trailing text is empty" "$(decide "$B")" specified-small build.execute.lite T1 impact
inv_plan "- (a) the claim row is written before the send, keyed on (ticket, day)
- None of the other clauses apply."
expect "A9h a real invariant followed by a 'None of the others' line IS invariant-bearing" \
  "$(decide "$B")" risk-surface build.execute T2 full
inv_plan "Nonce reuse is refused: the nonce table has a unique key on (account, nonce)."
expect "A9i a first line that merely starts with the letters n-o-n-e (Nonce) is not 'none'" \
  "$(decide "$B")" risk-surface build.execute T2 full

# B1' (review of #2288, round 2): a DEEPER heading inside the section is
# content, not the end of it — an M/L plan writes the prompt's clauses as
# "### (a) Cross-run state" sub-headings. Only a heading of the same or a
# higher level closes the section.
inv_plan "### (a) Cross-run state
The watermark lives in a table with a unique key on (project, day).
### (b) Side effects
The post is claimed before it is sent."
expect "A9j ### (a)/(b) sub-headings with real content are invariant-bearing" "$(decide "$B")" risk-surface build.execute T2 full
inv_plan "### (a) Cross-run state"
expect "A9j2 a bare ### (a) sub-heading as the first content is invariant-bearing" "$(decide "$B")" risk-surface build.execute T2 full
inv_plan "### None required
This change adds no state."
expect "A9k a sub-heading whose text starts with None is an empty section" "$(decide "$B")" specified-small build.execute.lite T1 impact
mkbuild "$B" src/lib/thing.ts
printf '\n# Appendix\n- (a) the claim row is written before the send\n' >> "$B/plan.md"
expect "A9k2 a same-or-higher heading still CLOSES the section: content after '# Appendix' is not an invariant" \
  "$(decide "$B")" specified-small build.execute.lite T1 impact
# nit: the other ways a model writes an empty section
for body in "No new invariants: this is a pure refactor." "No additional invariants beyond the iron laws." \
            "No system invariants; nothing persists." "Nothing beyond the iron laws. Read-only helper." \
            "No invariants." "- nothing beyond the iron laws"; do
  inv_plan "$body"
  expect "A9l '$body' is an empty section" "$(decide "$B")" specified-small build.execute.lite T1 impact
done
# nit: a later (a)-(d) clause is real content even after a leading "None..."
inv_plan "None beyond the iron laws for (a)-(c).
- (d) the reminder is claimed on (ticket, day) before it is posted, so a retry cannot double-send"
expect "A9m a later (d) clause after a leading None line is invariant-bearing" "$(decide "$B")" risk-surface build.execute T2 full
inv_plan "None beyond the iron laws.
b) the ledger row is the watermark"
expect "A9m2 an unparenthesised b) clause counts too" "$(decide "$B")" risk-surface build.execute T2 full
inv_plan "None beyond the iron laws. Nothing here touches (a) state or (b) side effects."
expect "A9m3 clause letters mentioned INSIDE the None sentence are not a clause" "$(decide "$B")" specified-small build.execute.lite T1 impact

# I1 (review of #2288): planned-files.txt keeps only some prefixes/extensions
# (bin/, worker/, supabase/, server/, packages/, .py, .go are dropped), so the
# plan's own path tokens are a floor: the tier is the max of both.
mkbuild "$B" docs/MIGRATION.md
printf '\n## Files\n- supabase/migrations/20260925_add_ledger.sql (new)\n- docs/MIGRATION.md\n' >> "$B/plan.md"
expect "I1a a docs+migration plan whose migration planned-files.sh dropped goes to the frontier" \
  "$(decide "$B")" risk-surface build.execute T2 full
mkbuild "$B" tests/unit/thing.test.ts
printf '\n## Files\n- `worker/jobs/schema.sql`\n- tests/unit/thing.test.ts\n' >> "$B/plan.md"
expect "I1b a worker schema.sql named only in the plan is risk surface" "$(decide "$B")" risk-surface build.execute T2 full
mkbuild "$B" tests/unit/thing.test.ts
printf '\n## Files\n- bin/lib/thing.sh\n- tests/unit/thing.test.ts\n' >> "$B/plan.md"
expect "I1c a bin/ product file the scraper dropped makes a tests-only list T1, not docs-only" \
  "$(decide "$B")" specified-small build.execute.lite T1 impact
mkbuild "$B" tests/unit/thing.test.ts
printf '\n## Files\n- services/billing/charge.py\n' >> "$B/plan.md"
expect "I1d a .py money path the scraper dropped is risk surface" "$(decide "$B")" risk-surface build.execute T2 full
mkbuild "$B" tests/unit/thing.test.ts docs/THING.md
printf '\nSee https://example.com/docs/auth/token.html and the tests/docs split and/or the README.\n' >> "$B/plan.md"
sed -i 's/^LINES: 120/LINES: 400/' "$B/plan.md"; sed -i 's/lines=120/lines=400/' "$B/size-gate.txt"
expect "I1e a URL and prose slashes (tests/docs, and/or) are not paths" "$(decide "$B")" docs-tests-copy build.execute.lite T0 minimal

# docs-tests-copy
mkbuild "$B" tests/unit/thing.test.ts docs/THING.md
sed -i 's/^LINES: 120/LINES: 400/' "$B/plan.md"; sed -i 's/lines=120/lines=400/' "$B/size-gate.txt"
expect "A10 tests/docs only is docs-tests-copy, whatever the size" "$(decide "$B")" docs-tests-copy build.execute.lite T0 minimal
mkbuild "$B" src/components/Banner.tsx
printf 'KIND: copy\nKIND_SOURCE: board\nKIND_REPRO: n/a\n' > "$B/kind.txt"
# I2 (review of #2288): the plan's own KIND label never picks the cheap rule.
# A T1 plan labelled copy is judged on its files: here it is fully specified
# and small, so specified-small, never docs-tests-copy.
expect "A11 KIND: copy on a product file is NOT docs-only (the label does not pick the lite model)" \
  "$(decide "$B")" specified-small build.execute.lite T1 impact
sed -i 's/^LINES: 120/LINES: 400/' "$B/plan.md"; sed -i 's/lines=120/lines=400/' "$B/size-gate.txt"
expect "A11b a 400-line T1 plan labelled copy stays on the live role" "$(decide "$B")" "" build.execute T1 full

# fail toward the frontier
mkbuild "$B"
expect "A12 no planned files at all is T2 (unknown), so risk surface" "$(decide "$B")" risk-surface build.execute T2 full
scratch_rm "$B"; mkdir -p "$B"
expect "A12b no plan at all: no artifacts, the frontier" "$(decide "$B")" risk-surface build.execute T2 full

# escalation on measured failure
mkbuild "$B" src/lib/thing.ts
printf '{"reviewed":6,"blocked":3,"rate":0.5}' > "$T/bounce-hot.json"
printf '{"reviewed":3,"blocked":3,"rate":1}' > "$T/bounce-few.json"
d=$(BOUNCE_PROJECT="$T/bounce-hot.json" decide "$B")
expect "A13 a project bouncing 50% on 6 reviews goes back to the frontier, one review tier up" "$d" \
  specified-small build.execute T2 impact bounce-escalate
d=$(BOUNCE_PROJECT="$T/bounce-few.json" decide "$B")
expect "A13b 3 reviews is under min_reviews: measured, not enough" "$d" specified-small build.execute.lite T1 impact
d=$(BOUNCE_CLASS="$T/bounce-hot.json" decide "$B")
expect "A13c the unit CLASS (this rule) bouncing escalates too" "$d" specified-small build.execute T2 impact bounce-escalate
grep -q "GET /route-shadow/bounce?project=" "$T/reqs" && ok || bad "A13d the project bounce rate was never asked for"
grep -q "rule=specified-small" "$T/reqs" && ok || bad "A13d the class bounce rate was not asked for the matched rule"

# a rule an operator turned off is skipped; an unknown mode is skipped too
jq '.rules |= map(if .name=="specified-small" then .mode="off" else . end)' "$T/rules.json" > "$T/rules-off.json"
d=$(RULES="$T/rules-off.json" wenv bash "$H/bin/lib/route-rules.sh" resolve "$B" proj-a 2>/dev/null)
expect "A14 mode off is skipped" "$d" "" build.execute T1 full
jq '.rules |= map(if .name=="specified-small" then .mode="live" else . end)' "$T/rules.json" > "$T/rules-live.json"
d=$(RULES="$T/rules-live.json" wenv bash "$H/bin/lib/route-rules.sh" resolve "$B" proj-a 2>/dev/null)
expect "A14b a 'live' row (the worker refuses one) is never evaluated here either" "$d" "" build.execute T1 full

# determinism: the same artifacts, twice, byte for byte
mkbuild "$B" src/lib/thing.ts
[ "$(decide "$B")" = "$(decide "$B")" ] && ok || bad "A15 the resolver is not deterministic"

# ============================================================================
# B + C. the shadow record
# ============================================================================
shadow() { # shadow <build> [actual-exec] [actual-review]
  wenv bash "$H/bin/lib/route-rules.sh" shadow proj-a TK-1 "$1" "${2:-model-frontier}" "${3:-model-reviewer}" job-1
}
: > "$T/shadow.sink"; : > "$T/reqs"
B="$T/project-3-TK-1-202609250101"
mkbuild "$B" src/lib/thing.ts
shadow "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "C1 shadow rc=$rc"
J="$B/route-shadow.json"
[ -s "$J" ] && ok || bad "C1 no \$BUILD/route-shadow.json"
[ "$(jq -r .would_execute_model "$J" 2>/dev/null)" = model-lite ] && ok \
  || bad "B1 the would-be model must be build.execute.lite's model_routes model, got $(jq -r .would_execute_model "$J" 2>/dev/null)"
[ "$(jq -r .actual_execute_model "$J" 2>/dev/null)" = model-frontier ] && ok || bad "B2 the actual model is what the build handed in"
[ "$(jq -r .review_model "$J" 2>/dev/null)" = model-reviewer ] && ok || bad "B3 the review model is build.review's, never a lite one"
[ "$(jq -r .rule "$J" 2>/dev/null)" = specified-small ] && ok || bad "C1 rule missing from the record"
[ "$(jq -r .features.fully_specified "$J" 2>/dev/null)" = true ] && ok || bad "C1 the features ride on the record"
[ "$(wc -l < "$T/shadow.sink")" -eq 1 ] && ok || bad "C2 exactly one POST /api/route-shadow, got $(wc -l < "$T/shadow.sink")"
[ "$(jq -r .build "$T/shadow.sink" 2>/dev/null)" = "$(basename "$B")" ] && ok || bad "C2 the row is keyed on the build dir's basename"
[ "$(jq -r .job_id "$T/shadow.sink" 2>/dev/null)" = job-1 ] && ok || bad "C2 the row carries the job id"
grep -q 'ROUTE_SHADOW (log only) rule=specified-small would=model-lite' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "C3 no ROUTE_SHADOW line in pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -qE 'claude-|gpt-|grok-' "$LIB" && bad "B4 a model id literal in bin/lib/route-rules.sh" || ok

# the worker is down: the record is still written locally, rc 0, rules from cache
: > "$T/shadow.sink"
B2="$T/project-3-TK-2-202609250102"; mkbuild "$B2" src/lib/thing.ts
FAKE=down shadow "$B2"; rc=$?
[ "$rc" = 0 ] && ok || bad "C4 a down worker must not fail the hook (rc=$rc)"
[ -s "$B2/route-shadow.json" ] && ok || bad "C4 no local record when the worker is down"
[ "$(jq -r .rules_source "$B2/route-shadow.json" 2>/dev/null)" = cache ] && ok \
  || bad "C4 with the worker down the rules come from the box cache the first call wrote, got $(jq -r .rules_source "$B2/route-shadow.json" 2>/dev/null)"
[ -s "$T/shadow.sink" ] && bad "C4 nothing can be posted to a down worker" || ok

# the kill switches: nothing written, nothing asked
: > "$T/reqs"; B3="$T/project-3-TK-3-202609250103"; mkbuild "$B3" src/lib/thing.ts
ROUTE_SHADOW=0 shadow "$B3"
[ -e "$B3/route-shadow.json" ] && bad "C5 ROUTE_SHADOW=0 still wrote a record" || ok
[ -s "$T/reqs" ] && bad "C5 ROUTE_SHADOW=0 still called the worker: $(head -2 "$T/reqs")" || ok
touch "$H/flags/route-shadow-off"
shadow "$B3"
[ -e "$B3/route-shadow.json" ] && bad "C6 flags/route-shadow-off still wrote a record" || ok
rm -f "$H/flags/route-shadow-off"

# nit (review of #2288): the shadow closes every inherited fd above 2 on entry,
# so it never holds a build lock — including a slot lock past fd 9 on a box with
# more than two BUILD_SLOTS. Fd 12 and 6 stand in for those locks here.
B4="$T/project-3-TK-4-202609250104"; mkbuild "$B4" src/lib/thing.ts
( exec 6>"$T/lock6" 12>"$T/lock12"
  ROUTE_RULES_FD_PROBE="$T/fds" wenv bash "$H/bin/lib/route-rules.sh" shadow proj-a TK-4 "$B4" model-frontier model-reviewer job-4 )
[ -s "$T/fds" ] && ok || bad "C7 the fd probe wrote nothing"
# 0-2, plus 255 (bash's own handle on the script it is running, never a lock).
[ "$(grep -vx 255 "$T/fds" | sort -n | tr '\n' ' ')" = "0 1 2 " ] && ok || bad "C7 inherited fds survived into the shadow: $(tr '\n' ' ' < "$T/fds")"

# ============================================================================
# D. the run-build hook is LOG ONLY — byte-identical runner argv
# ============================================================================
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
xb() { awk -v n="$1" 'index($0, "# >>> " n)==1 {f=1;next} index($0, "# <<< " n)==1 {exit} f' "$RB" > "$2"; }
xb 'route shadow' "$T/hook.sh"
xb 'execute prompt' "$T/exec.sh"
[ -s "$T/hook.sh" ] && ok || bad "D0 no '# >>> route shadow' block in bin/run-build.sh"
[ -s "$T/exec.sh" ] && ok || bad "D0 no '# >>> execute prompt' block"
# The hook must sit between the overlap gate and EXECUTE, read off the flattened
# pipeline: after rb_gate_overlap's last block (`plan overlap`), before
# rb_execute's first (`live emit execute`).
awk '/^# >>> plan overlap/{g=NR} /^# >>> route shadow/{h=NR} /^# >>> live emit execute/{e=NR} END{exit !(g && h && e && g<h && h<e)}' \
  "$RB" && ok || bad "D0 the hook is not between rb_gate_overlap and rb_execute"

# drive <with-hook: 0|1> <tag>: the real hook block, then the real execute CC
# call, in one shell; CC records its argv byte for byte, and every variable the
# shell holds is dumped immediately BEFORE and AFTER the hook, so a hook that
# changed ANY of them shows as a difference between the two dumps.
vars() { ( set -o posix; set ) | grep -vE '^(BASH[A-Z_]*|_|PIPESTATUS|SECONDS|RANDOM|LINENO|SRANDOM|EPOCH[A-Z]*|FUNCNAME)='; }
drive() {
  local with="$1" tag="$2"
  ( cd "$T" || exit 9
    export PATH="$T/fakebin:$PATH" JOBS_URL="https://jobs.test" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
           REQS="$T/reqs" ROUTES="$T/routes" RULES="${RULES:-$T/rules.json}" SHADOW_SINK="$T/shadow.sink" \
           SHADOW_ROWS="$T/rows.json" BOUNCE_PROJECT="$T/bounce-none.json" BOUNCE_CLASS="$T/bounce-none.json" FAKE=up
    HARNESS="$H" PROJECT=proj-a KEY=TK-7 BUILD="$T/proj-a-TK-7-202609250107" JOB_ID=job-7 \
    EXECUTE_MODEL=model-frontier REVIEW_MODEL=model-reviewer EXECUTE_TIMEOUT_SECS=7200 BRANCH=ticket/TK-7 \
    CKPT_RESUME_NOTE= KIND_EXEC_NOTE= REROUTE_EXEC_NOTE=
    CC() { printf '%s\0' "$@" > "$T/argv.$tag"; }
    vars > "$T/vars.pre.$tag"
    if [ "$with" = 1 ]; then . "$T/hook.sh"; fi
    vars > "$T/vars.post.$tag"
    . "$T/exec.sh"
  )
}
BD="$T/proj-a-TK-7-202609250107"; mkbuild "$BD" src/lib/thing.ts
: > "$T/shadow.sink"
drive 0 off
mkbuild "$BD" src/lib/thing.ts
drive 1 on
[ -s "$T/argv.off" ] && ok || bad "D1 the execute block never reached CC"
cmp -s "$T/argv.off" "$T/argv.on" && ok || bad "D1 the runner argv differs with the shadow hook in place"
cmp -s "$T/vars.pre.on" "$T/vars.post.on" && ok || bad "D2 the hook changed a variable of the build shell: $(diff "$T/vars.pre.on" "$T/vars.post.on" | head -4)"
# ...and the dump is not blind: a block that DOES assign is seen by it.
printf 'EXECUTE_MODEL=evil\n' > "$T/assigning-hook.sh"
( EXECUTE_MODEL=model-frontier; vars > "$T/vars.pre.x"; . "$T/assigning-hook.sh"; vars > "$T/vars.post.x" )
cmp -s "$T/vars.pre.x" "$T/vars.post.x" && bad "D2b the variable dump cannot see an assignment, so D2 proves nothing" || ok
[ -s "$BD/route-shadow.json" ] && ok || bad "D3 the hook ran but wrote no shadow record (so D1 proved nothing)"
[ "$(jq -r .would_execute_model "$BD/route-shadow.json" 2>/dev/null)" = model-lite ] && ok \
  || bad "D3 the hook's record disagrees with the build it saw"
[ "$(jq -r .would_execute_model "$BD/route-shadow.json" 2>/dev/null)" != "$(tr '\0' '\n' < "$T/argv.on" | sed -n 2p)" ] && ok \
  || bad "D4 would != actual here, and the argv must still carry the ACTUAL model"
[ "$(tr '\0' '\n' < "$T/argv.on" | sed -n 2p)" = model-frontier ] && ok || bad "D4 the argv's model is not the build's EXECUTE_MODEL"

# a hostile route-rules.sh: prints, fails, sleeps past nothing, tries to set
# EXECUTE_MODEL — none of it reaches the build shell
cp "$H/bin/lib/route-rules.sh" "$T/route-rules.real"
printf '#!/bin/bash\necho EXECUTE_MODEL=evil\nEXECUTE_MODEL=evil; export EXECUTE_MODEL\necho boom >&2\nexit 1\n' > "$H/bin/lib/route-rules.sh"
drive 1 hostile
cmp -s "$T/argv.off" "$T/argv.hostile" && ok || bad "D5 a failing route-rules.sh changed the runner argv"
cmp -s "$T/vars.pre.hostile" "$T/vars.post.hostile" && ok || bad "D5 a failing route-rules.sh changed the build shell: $(diff "$T/vars.pre.hostile" "$T/vars.post.hostile" | head -6)"
rm -f "$H/bin/lib/route-rules.sh"
drive 1 missing
cmp -s "$T/argv.off" "$T/argv.missing" && ok || bad "D6 a box without route-rules.sh changed the runner argv"
cp "$T/route-rules.real" "$H/bin/lib/route-rules.sh"

# ============================================================================
# E. review_tier_files is review_tier's classifier
# ============================================================================
( . "$DIR/bin/lib/review-tier.sh"
  G="$T/g"; scratch_rm "$G"; mkdir -p "$G"; cd "$G" || exit 9
  git init -q . && git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m base
  n=0
  for set in "docs/a.md tests/b.sh" "src/x.ts docs/a.md" "src/auth/x.ts" "tests/fixtures/seed.sql" "src/app/page.tsx prisma/schema.prisma"; do
    n=$((n+1))
    git checkout -q -B "c$n" 2>/dev/null
    git reset -q --hard "$(git rev-list --max-parents=0 HEAD)"
    for f in $set; do mkdir -p "$(dirname "$f")"; echo x > "$f"; done
    git add -A && git commit -q -m c
    a=$(review_tier HEAD~1 HEAD); b=$(printf '%s\n' $set | review_tier_files)
    [ "$a" = "$b" ] || { echo "MISMATCH [$set]: diff='$a' list='$b'"; exit 1; }
  done
  [ "$(printf '' | review_tier_files)" = "T2 reason=planned-files-unavailable" ] || { echo "empty list is not T2"; exit 1; }
) > "$T/e.out" 2>&1 && ok || bad "E1 review_tier_files disagrees with review_tier: $(tail -2 "$T/e.out")"

# ============================================================================
# F. the nightly report
# ============================================================================
cat > "$T/rows.json" <<'EOF'
{"rows":[
 {"build":"b1","project":"project-3","rule":"specified-small","bumped":"","would_execute_role":"build.execute.lite","would_execute_model":"model-lite","actual_execute_model":"model-frontier","would_review_tier":"T1","differs":1},
 {"build":"b2","project":"project-3","rule":"risk-surface","bumped":"","would_execute_role":"build.execute","would_execute_model":"model-frontier","actual_execute_model":"model-frontier","would_review_tier":"T2","differs":0},
 {"build":"b3","project":"project-5","rule":"docs-tests-copy","bumped":"","would_execute_role":"build.execute.lite","would_execute_model":"model-lite","actual_execute_model":"model-frontier","would_review_tier":"T0","differs":1},
 {"build":"b4","project":"project-5","rule":"","bumped":"","would_execute_role":"build.execute","would_execute_model":"model-frontier","actual_execute_model":"model-frontier","would_review_tier":"T1","differs":0}
],"truncated":false}
EOF
if [ -x "$H/bin/route-shadow-report.sh" ] || [ -s "$H/bin/route-shadow-report.sh" ]; then ok; else bad "F0 bin/route-shadow-report.sh does not exist"; fi
: > "$T/reqs"
REP=$(wenv bash "$H/bin/route-shadow-report.sh" --no-send --print 2>"$T/rep.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "F1 report rc=$rc: $(head -3 "$T/rep.err")"
grep -q 'builds: 4' <<<"$REP" && ok || bad "F1 total builds missing: $REP"
grep -q 'would move off the live execute model: 2 (50%)' <<<"$REP" && ok || bad "F2 the would-move share is wrong: $REP"
grep -q 'build.execute.lite: 2 (50%)' <<<"$REP" && ok || bad "F2 the lite-role share is wrong: $REP"
grep -qE 'project-3 +2 +1 \(50%\)' <<<"$REP" && ok || bad "F3 the per-project row for project-3 is wrong: $REP"
grep -qE 'project-5 +2 +1 \(50%\)' <<<"$REP" && ok || bad "F3 the per-project row for project-5 is wrong: $REP"
grep -qE '\(no rule\) +1' <<<"$REP" && ok || bad "F4 unmatched builds are named, not dropped: $REP"
grep -q 'GET /route-shadow?since=' "$T/reqs" && ok || bad "F5 the report did not read the worker's shadow rows"
[ -s "$H/state/route-shadow/latest.txt" ] && ok || bad "F6 no state/route-shadow/latest.txt"
FAKE=down wenv bash "$H/bin/route-shadow-report.sh" --no-send --print > "$T/rep.down" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "F7 a down worker must not crash the report (rc=$rc)"
grep -q 'n/a' "$T/rep.down" && ok || bad "F7 a down worker reads n/a, never 0 builds: $(head -3 "$T/rep.down")"

# I3 (review of #2288): a 200 with an EMPTY body is unreadable, not "0 builds",
# on every jq (1.6 exits 0 on `jq -e` over empty input; the guard does not rely
# on jq to notice). The resolver likewise never reads it as the worker's rules.
FAKE=empty wenv bash "$H/bin/route-shadow-report.sh" --no-send --print > "$T/rep.empty" 2>&1
grep -q 'builds: n/a' "$T/rep.empty" && ok || bad "F8 an empty 200 must read n/a: $(head -3 "$T/rep.empty")"
rm -f "$H/state/route-rules.json"
mkbuild "$T/b-empty" src/lib/thing.ts
d=$(FAKE=empty wenv bash "$H/bin/lib/route-rules.sh" resolve "$T/b-empty" proj-a 2>/dev/null)
[ "$(field "$d" rules_source)" = none ] && ok || bad "F9 an empty 200 is not the worker's rules (got $(field "$d" rules_source))"

# nit (review of #2288): the daily message is skipped when there were no builds;
# the files are still written.
: > "$T/beat.sink"
printf '{"rows":[],"truncated":false}' > "$T/rows-none.json"
SHADOW_ROWS="$T/rows-none.json" wenv bash "$H/bin/route-shadow-report.sh" > /dev/null 2>&1
[ -s "$T/beat.sink" ] && bad "F10 zero builds must post no message" || ok
grep -q 'builds: 0' "$H/state/route-shadow/latest.txt" && ok || bad "F10 zero builds still writes latest.txt"
wenv bash "$H/bin/route-shadow-report.sh" > /dev/null 2>&1
[ "$(wc -l < "$T/beat.sink")" -eq 1 ] && ok || bad "F11 a day with builds posts exactly one message"

echo "route-rules.p4-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
