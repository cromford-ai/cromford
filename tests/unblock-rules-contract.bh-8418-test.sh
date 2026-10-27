#!/bin/bash
# tests/unblock-rules-contract.bh-8418-test.sh — BH-8418 (UNB-8): the Tackler
# contract between the rule files, the rules engine, act.sh, the class lookup
# and the tick loader, run over every SHIPPED file in catalog/unblock-rules.d.
#
#   S1  every rule file validates against _schema.json (a stdlib validator,
#       below). 6 mutants fail: name AND verb; an unknown top key; key item
#       Bad-Key; kind ""; kind []; cites []. The validator refuses a schema
#       keyword it does not implement, so a new keyword cannot pass silently.
#   S2  ub_rules_load on the shipped dir: rc 0, one rule per [!_]*.json file.
#   S3  bin/unblock.sh tick, sandboxed, over one record per rule id
#       (tests/fixtures/unblock/bh-8418/records.json; a rule with no record is
#       a FAIL): each record decides to its own rule; an acting rule goes
#       through the REAL act.sh in shadow and records `would` (never failed
#       bad-input, never unknown-action); the card rule escalates and reaches
#       ubt_stage_card (never deferred); a rule whose judge runs on its record
#       (U6, BH-7724) reaches ubt_stage_judge and records `would` with the
#       judge's proceed detail (never deferred).
#   S4  uo_class_of looks a rule up by its id: U8 U9 U10 U12 by id (id is not
#       the stem), U1-batch-culprit; a stem, a case change, a space, ../U8, an
#       ambiguous id (two files) give rc 1; a file that is not JSON next to a
#       good U8 hides nothing.
#   S5  after the tick's loader: ub_rules_eval, ubt_stage_card, the six mc_*
#       functions act.sh and the queue collector call and fix_round_enqueue are
#       defined, and so is every ubt_stage_* bin/unblock.sh dispatches to
#       (ubt_stage_judge is a SKIP while bin/lib/unblock/judge.sh, #7753, is
#       absent). Without merge-conductor-lib.sh on the tree the tick still loads.
#   S6  U2/U3 through the tick with the REAL queue collector and the REAL
#       merge-conductor libs over a seeded attempts.txt (no mc_* stub):
#       requeued_on_head reads false, U2 claims #7592 #7666 #7588 #7363, U3
#       claims the 3 green dead-shard members, WOULD_REQUEUE lines, 0 failed
#       records. A `requeued` line for #7592's head: true, and no U2 for #7592.
#   S7  the card seam: (a) shadow: claim, then 1 agent-call, then a `would`
#       record with card u-<6 hex> and model_calls 1, 0 alerts; (b) a second
#       tick: 409, 0 agent-calls; (c) act + UNBLOCK_ACT=1: 1 critical alert,
#       `escalated`; (d) an empty answer: the fallback card, model_calls 1;
#       (e) no claim: refused, 0 agent-calls; (f) deferred=0. Plus the outcome
#       table: SEND_FAILED, a compose failure, another key's claim, act mode
#       with UNBLOCK_ACT unset.
#   B   budget (BH-7563): curl, gh, flyctl and claude on PATH log and exit 7;
#       0 lines in net.log after every section. The S6 gh is a fixture answer.
#
# MUTATIONS (D1), each tried once by hand: revert U8's args to {box} -> S3 red
# (failed bad-input); revert uo_class_of to <id>.json -> S4 red; drop the
# merge-conductor-lib line from bin/unblock.sh -> S5 and S6 red
# (requeued_on_head null, no U2/U3 claim); drop `card` from the seam loop ->
# S3, S5 and S7 red (deferred); drop the UBT_CLAIMED_KEY check -> S7e red;
# map SEND_FAILED to escalated -> the S7 table red; drop `verb` from the
# schema's action -> S1 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-rules-contract.bh-8418-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: jq, python3 or flock missing"; exit 0; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

RULES="$SRC/catalog/unblock-rules.d"
FX="$SRC/tests/fixtures/unblock"
RECS="$FX/bh-8418/records.json"
R=example-org/cromford
NOW=1792497600   # 2026-10-20T12:00:00Z

# The vendor fakes: every one logs and fails.
FB="$T/fakebin"; mkdir -p "$FB"; : > "$T/net.log"
for b in curl gh flyctl claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"; chmod +x "$FB/$b"
done
budget() { check "B $1: 0 curl/gh/flyctl/claude calls" "$(grep -c . "$T/net.log")" 0; }

# ═════ S1: the schema ════════════════════════════════════════════════════════
# A JSON Schema subset validator, stdlib only (no jsonschema module on a box).
# rc 0 valid; rc 1 invalid (one line per error); rc 3 the schema uses a
# keyword it does not implement.
cat > "$T/validate.py" <<'PY'
import json, re, sys
ANNOT = {"$schema", "$id", "title", "description"}
KNOWN = {"type", "required", "properties", "additionalProperties", "pattern", "items", "minItems",
         "uniqueItems", "minimum", "maximum", "minLength", "oneOf", "const", "enum"} | ANNOT
def walk(s):
    if isinstance(s, dict):
        for k in s:
            if k not in KNOWN:
                print("unsupported schema keyword %s" % k); sys.exit(3)
        for k in ("properties",):
            for v in s.get(k, {}).values(): walk(v)
        for k in ("items", "additionalProperties"):
            if isinstance(s.get(k), dict): walk(s[k])
        for v in s.get("oneOf", []): walk(v)
def tname(v):
    if v is None: return "null"
    if isinstance(v, bool): return "boolean"
    if isinstance(v, int): return "integer"
    if isinstance(v, float): return "number"
    if isinstance(v, str): return "string"
    if isinstance(v, list): return "array"
    return "object"
def tok(v, t):
    n = tname(v)
    return n == t or (t == "number" and n == "integer")
def val(v, s, p, e):
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        if not any(tok(v, t) for t in ts): e.append("%s: type %s is not %s" % (p, tname(v), ts)); return
    if "const" in s and v != s["const"]: e.append("%s: not const %r" % (p, s["const"]))
    if "enum" in s and v not in s["enum"]: e.append("%s: not in enum" % p)
    if isinstance(v, str):
        if "pattern" in s and not re.search(s["pattern"], v): e.append("%s: %r does not match %s" % (p, v, s["pattern"]))
        if "minLength" in s and len(v) < s["minLength"]: e.append("%s: shorter than %d" % (p, s["minLength"]))
    if tname(v) in ("integer", "number"):
        if "minimum" in s and v < s["minimum"]: e.append("%s: under minimum" % p)
        if "maximum" in s and v > s["maximum"]: e.append("%s: over maximum" % p)
    if isinstance(v, list):
        if "minItems" in s and len(v) < s["minItems"]: e.append("%s: fewer than %d items" % (p, s["minItems"]))
        if s.get("uniqueItems") and len({json.dumps(x, sort_keys=True) for x in v}) != len(v): e.append("%s: items not unique" % p)
        if isinstance(s.get("items"), dict):
            for i, x in enumerate(v): val(x, s["items"], "%s[%d]" % (p, i), e)
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v: e.append("%s: missing %s" % (p, k))
        props = s.get("properties", {})
        for k, x in v.items():
            if k in props: val(x, props[k], p + "." + k, e)
            elif s.get("additionalProperties") is False: e.append("%s: unknown key %s" % (p, k))
            elif isinstance(s.get("additionalProperties"), dict): val(x, s["additionalProperties"], p + "." + k, e)
    if "oneOf" in s:
        n = 0
        for sub in s["oneOf"]:
            se = []; val(v, sub, p, se)
            if not se: n += 1
        if n != 1: e.append("%s: matches %d of oneOf, not exactly 1" % (p, n))
schema = json.load(open(sys.argv[1]))
walk(schema)
errs = []
val(json.load(open(sys.argv[2])), schema, "$", errs)
for x in errs: print(x)
sys.exit(1 if errs else 0)
PY
SCHEMA="$RULES/_schema.json"
validate() { python3 -I "$T/validate.py" "$1" "$2"; }
NFILES=0
for f in "$RULES"/[!_]*.json; do
  NFILES=$((NFILES + 1))
  out=$(validate "$SCHEMA" "$f" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then ok "S1 $(basename "$f") validates against _schema.json"
  else no "S1 $(basename "$f") validates against _schema.json" "rc $rc: $out"; fi
done
[ "$NFILES" -ge 8 ] && ok "S1 at least the 8 shipped rule files" || no "S1 at least the 8 shipped rule files" "found $NFILES"
mutant() { # mutant <label> <file> <jq transform>
  jq "$3" "$RULES/$2" > "$T/mutant.json" || { no "S1 mutant $1: setup"; return; }
  validate "$SCHEMA" "$T/mutant.json" > "$T/mutant.out" 2>&1; local rc=$?
  check "S1 mutant $1 fails validation (rc 1)" "$rc" 1
}
mutant "action name AND verb" U8-box-restart.json '.action.name = "box_restart"'
mutant "unknown top key foo" U1-batch-culprit.json '.foo = 1'
mutant "key item Bad-Key" U2-bystander-requeue.json '.key += ["Bad-Key"]'
mutant 'kind ""' U3-dead-shard-requeue.json '.match.kind = ""'
mutant "kind []" U9-throughput-knob.json '.match.kind = []'
mutant "cites []" U10-branch-fix-round.json '.cites = []'
jq '.properties.note.if = {}' "$SCHEMA" > "$T/schema-if.json"
validate "$T/schema-if.json" "$RULES/U8-box-restart.json" > /dev/null 2>&1
check "S1 the validator refuses an unsupported keyword (rc 3)" "$?" 3
budget S1

# ═════ S2: the loader ════════════════════════════════════════════════════════
LOADED=$( HARNESS="$SRC" bash -c '. "$HARNESS/bin/lib/unblock/rules.sh" && ub_rules_load "$1"' _ "$RULES" 2>"$T/s2.err" ); rc=$?
check "S2 ub_rules_load rc 0" "$rc" 0
check "S2 one rule per file" "$(jq 'length' <<<"$LOADED" 2>/dev/null)" "$NFILES"
budget S2

# ═════ the tick harness (S3, S5, S6, S7) ═════════════════════════════════════
# mktick <name> [queue] -> prints the case dir. The shipped bin/unblock.sh by
# its closure, with the rules engine, the judge seam (BH-7724) and the card
# seam it loads by a loop, the shipped rules, a settings cache, a logging
# lane-alert and an agent-call stub that answers per $FXT/ac.mode (the
# unblock-judge stage answers $FXT/judge.answer, default CAP_ONLY). `queue`
# adds the real queue collector, the fake batch_failure tool and a gh that
# answers from the case fixture.
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col" "$C/bin"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$SRC/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  : > "$C/h/env/global.env"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  cat > "$C/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
echo "ALERT $*" | tr '\n' ' ' >> "$FXT/alerts.log"; echo >> "$FXT/alerts.log"
echo "ALERT" >> "$FXT/seq.log"
[ -f "$FXT/alert.fail" ] && exit 1
exit 0
SH
  cat > "$C/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENTCALL $1 $2 $3" >> "$FXT/seq.log"
if [ "$1" = unblock-judge ]; then cat "$FXT/judge.answer" 2>/dev/null > "$5" || echo CAP_ONLY > "$5"; exit 0; fi
case "$(cat "$FXT/ac.mode" 2>/dev/null)" in
  empty) : > "$5" ;;
  *) printf '{"what":"#7604 waits: its own CI is red on a dead-shard batch.","options":["hold: keep it parked","re-run its CI by hand"],"recommendation":1,"reason":"own CI is red"}\n' > "$5" ;;
esac
exit 0
SH
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  if [ "${2:-}" = queue ]; then
    for S in bin/lib/unblock/collectors/queue.sh bin/lib/gh-rest.sh; do
      ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
    done
    # scratch-closure-allow: places the already-installed queue collector into the UNBLOCK_COLLECTORS_DIR seam the tick reads; the closure itself comes from scratch_install_closure above
    cp "$C/h/bin/lib/unblock/collectors/queue.sh" "$C/col/queue.sh"
    mkdir -p "$C/h/mcp/tools" "$C/h/mcp/lib"
    cp "$SRC/mcp/lib/config.mjs" "$C/h/mcp/lib/config.mjs"
    cat > "$C/h/mcp/tools/batch-failure.mjs" <<'JS'
import { readFileSync } from 'node:fs';
const text = (t) => [{ type: 'text', text: t }];
export const tools = [{
  name: 'batch_failure', kind: 'read', inputSchema: { type: 'object' },
  handler: async (a) => {
    const fx = JSON.parse(readFileSync(process.env.GH_FX, 'utf8'));
    const v = fx.batch_failure[String(a.draft)];
    if (!v) return { content: text('no such draft'), isError: true };
    return { content: text(JSON.stringify(v)), structuredContent: v };
  },
}];
JS
    cat > "$C/bin/gh" <<'SH'
#!/bin/bash
m=GET; p=
while [ $# -gt 0 ]; do
  case "$1" in api|-i) ;; -X) m="$2"; shift ;; -H) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ]; then printf 'HTTP/2 405\r\n\r\n{"message":"fixture: writes refused"}\n'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n{"message":"Not Found"}\n'; exit 1
SH
    chmod +x "$C/bin/gh"
  fi
  # The fixture the sandboxed tick sources AFTER its libs: the jobs API (claims
  # are UNIQUE on decision_key: a seen key is a 409), the settings reads, the
  # model route and the verdict reader. No mc_* function: S6 runs the real ones.
  cat > "$C/fx.sh" <<'SH'
seq_log() { printf '%s\n' "$*" >> "$FXT/seq.log"; }
if [ -f "$FXT/declare-probe" ]; then
  for n in $(cat "$FXT/declare-probe"); do declare -F "$n" >/dev/null && echo "$n" >> "$FXT/declared"; done
  exit 0
fi
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
_jobs_req() {
  local k n
  seq_log "JOBS $1 $2 ${3:-}"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"would"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
lane_role_model() { seq_log "ROUTE $*"; printf 'model-fixture\n'; }
vd_standing() { local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX"); [ -n "$l" ] || return 1; printf '%s\n' "$l"; }
SH
  printf '%s' "$C"
}
# mode <case dir> <shadow|act> — the settings cache the scope lib and
# bin/jobs-client.sh setting-get (act.sh's mode read) answer from.
mode() {
  jq -nc --argjson fa "$NOW" --arg m "$2" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": $m, "unblock.enabled": "1"}, seeded: {}}' \
    > "$1/h/state/settings-cache.json"
}
# tick <case dir> [env...] — the shipped entry point, sandboxed.
tick() {
  local C="$1"; shift
  ( env HARNESS="$C/h" FXT="$C/fx" GH_FX="$C/gh-fx.json" GH_LOG="$C/gh.log" UNBLOCK_FIXTURE="$C/fx.sh" \
      UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$C/bin:$FB:$PATH" GH_ETAG=0 TMPDIR="$C" \
      HARNESS_CONSOLE_URL=http://192.0.2.10 UNBLOCK_NOW="$NOW" UB_NOW="$NOW" "$@" \
      bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
}
# records_collector <case dir> <file of JSONL> — a wired collector that prints it.
records_collector() {
  cp "$2" "$1/fx/lines.jsonl"
  printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$1/col/fixture.sh"
}
claims_of() { grep '^JOBS POST /api/unblock/decisions/claim ' "$1/fx/seq.log" 2>/dev/null | sed 's/^JOBS POST [^ ]* //'; }
records_of() { grep '^JOBS POST /api/unblock/decisions/record ' "$1/fx/seq.log" 2>/dev/null | sed 's/^JOBS POST [^ ]* //'; }
tickline() { grep ' tick cromford mode=' "$1/h/logs/unblock.log" 2>/dev/null | tail -n1; }

# ═════ S3: every rule's action through act.sh, by the tick ═══════════════════
C=$(mktick s3) || exit 1; mode "$C" shadow
: > "$C/s3.jsonl"; MISSING=""
for f in "$RULES"/[!_]*.json; do
  id=$(jq -r .id "$f")
  if jq -e --arg id "$id" '.records | has($id)' "$RECS" >/dev/null; then
    jq -c --arg id "$id" '.records[$id]' "$RECS" >> "$C/s3.jsonl"
  else
    MISSING="$MISSING $id"
  fi
done
check "S3 every shipped rule id has a sample record in $(basename "$(dirname "$RECS")")/records.json" "${MISSING:-none}" none
records_collector "$C" "$C/s3.jsonl"
tick "$C"
TL=$(tickline "$C")
claims_of "$C" > "$C/claims.jsonl"; records_of "$C" > "$C/records.jsonl"
for f in "$RULES"/[!_]*.json; do
  id=$(jq -r .id "$f"); verb=$(jq -r '.action.name // .action.verb' "$f")
  subj=$(jq -r --arg id "$id" '.records[$id].subject // ""' "$RECS")
  got=$(jq -rs --arg s "$subj" 'map(select(.subject == $s)) | map(.rule_id // "null") | join(",")' "$C/claims.jsonl")
  check "S3 $id: its record decides to $id" "$got" "$id"
  key=$(jq -rs --arg s "$subj" 'map(select(.subject == $s))[0].decision_key // ""' "$C/claims.jsonl")
  rec=$(jq -rs --arg k "$key" 'map(select(.decision_key == $k)) | map("\(.outcome) \(.outcome_detail)") | join(",")' "$C/records.jsonl")
  # A rule whose judge runs on its record (no `when`, or `when` true) goes
  # through ubt_stage_judge (BH-7724): the stub answers the proceed word, so
  # the record is would with the judge's detail; act.sh is UNB-4's, later.
  jw=$(jq -r 'if .judge == null then "" else (.judge.when // "true") end' "$f")
  jr=$(jq -c --arg id "$id" '.records[$id]' "$RECS")
  if [ -n "$jw" ] && [ "$(jq -c "$jw" <<<"$jr" 2>/dev/null)" = true ]; then
    jq_=$(jq -r .judge.question "$f")
    check "S3 $id: judge $jq_, through ubt_stage_judge, recorded would" "$rec" "would judge $jq_=CAP_ONLY (ok): proceed $verb"
  elif [ "$verb" = card ]; then
    check "S3 $id: escalate, through ubt_stage_card, recorded would" "$(jq -rs --arg k "$key" 'map(select(.decision_key == $k))[0] | "\(.decision) \(.action)"' "$C/claims.jsonl") ${rec%% *}" "escalate card would"
  else
    WANT="WOULD_$(printf '%s' "$verb" | tr '[:lower:]' '[:upper:]')"
    check "S3 $id: act.sh accepts $verb's args (would $WANT)" "$rec" "would $WANT"
  fi
done
check "S3 0 failed records" "$(grep -c '"outcome":"failed"' "$C/records.jsonl")" 0
case "$TL" in *"decisions=$NFILES claimed=$NFILES rows=$NFILES deferred=0"*) ok "S3 tick line: every decision claimed and recorded, 0 deferred" ;;
  *) no "S3 tick line: every decision claimed and recorded, 0 deferred" "$TL $(head -c 600 "$C/tick.out")" ;; esac
check "S3 0 alerts in shadow" "$(cnt . "$C/fx/alerts.log")" 0
budget S3

# ═════ S4: the class of a rule, by its id ════════════════════════════════════
s4() { HARNESS="$1" bash -c '. "$HARNESS/bin/lib/unblock/override.sh" && uo_class_of "$1"; echo " rc=$?"' _ "$2" 2>/dev/null | tr -d '\n'; }
check "S4 U8 (file U8-box-restart.json)" "$(s4 "$SRC" U8)" "infra-restart rc=0"
check "S4 U9" "$(s4 "$SRC" U9)" "infra-knob rc=0"
check "S4 U10" "$(s4 "$SRC" U10)" "fix-round rc=0"
check "S4 U12" "$(s4 "$SRC" U12)" "escalate rc=0"
check "S4 U1-batch-culprit (id == stem)" "$(s4 "$SRC" U1-batch-culprit)" "review-block rc=0"
check "S4 a stem is not an id: U8-box-restart" "$(s4 "$SRC" U8-box-restart)" " rc=1"
check "S4 case differs: u8" "$(s4 "$SRC" u8)" " rc=1"
check "S4 a trailing space: 'U8 '" "$(s4 "$SRC" 'U8 ')" " rc=1"
check "S4 ../U8" "$(s4 "$SRC" ../U8)" " rc=1"
check "S4 an unknown id: U99" "$(s4 "$SRC" U99)" " rc=1"
S4H="$T/s4/h"; mkdir -p "$S4H/catalog/unblock-rules.d"
( cd "$SRC" && scratch_install_closure bin/lib/unblock/override.sh "$S4H" ) >/dev/null || no "S4 setup: closure override.sh"
cp "$RULES"/*.json "$S4H/catalog/unblock-rules.d/"
printf '{not json' > "$S4H/catalog/unblock-rules.d/U7-broken.json"
check "S4 a file that is not JSON hides nothing" "$(s4 "$S4H" U8)" "infra-restart rc=0"
jq '.class = "other-class"' "$RULES/U8-box-restart.json" > "$S4H/catalog/unblock-rules.d/U8-copy.json"
check "S4 two files carry id U8: ambiguous, rc 1" "$(s4 "$S4H" U8)" " rc=1"
check "S4 the other ids still resolve" "$(s4 "$S4H" U9)" "infra-knob rc=0"
budget S4

# ═════ S5: the tick loads every seam it dispatches to ════════════════════════
NAMES="ub_rules_eval ub_act ubt_stage_card mc_requeued_mark mc_attempt_has mc_requeue_mergify mc_requeued_record mc_dequeue_label mc_enqueue_mergify fix_round_enqueue"
SEAMS=$(grep -o 'seam=ubt_stage_[a-z_]*' "$SRC/bin/unblock.sh" | sed 's/^seam=//' | sort -u | tr '\n' ' ')
check "S5 bin/unblock.sh dispatches to ubt_stage_judge and ubt_stage_card" "$SEAMS" "ubt_stage_card ubt_stage_judge "
C=$(mktick s5) || exit 1; mode "$C" shadow
[ -f "$C/h/bin/lib/merge-conductor-lib.sh" ] && ok "S5 the closure of bin/unblock.sh installs merge-conductor-lib.sh" \
  || no "S5 the closure of bin/unblock.sh installs merge-conductor-lib.sh"
[ -f "$C/h/bin/lib/fix-round-queue.sh" ] && ok "S5 the closure of bin/unblock.sh installs fix-round-queue.sh" \
  || no "S5 the closure of bin/unblock.sh installs fix-round-queue.sh"
printf '%s\n' $NAMES $SEAMS | sort -u > "$C/fx/declare-probe"
tick "$C"
for n in $NAMES; do
  grep -qx "$n" "$C/fx/declared" 2>/dev/null && ok "S5 $n is defined after the loader" \
    || no "S5 $n is defined after the loader" "$(head -c 600 "$C/tick.out")"
done
for n in $SEAMS; do
  if [ "$n" = ubt_stage_judge ] && [ ! -f "$SRC/bin/lib/unblock/judge.sh" ]; then
    echo "SKIP S5 ubt_stage_judge: bin/lib/unblock/judge.sh is not on this tree (#7753, BH-7724)"; continue
  fi
  grep -qx "$n" "$C/fx/declared" 2>/dev/null && ok "S5 dispatch target $n is defined" || no "S5 dispatch target $n is defined"
done
# The conductor libs are optional: without them the tick still loads (the
# queue collector reads null, act.sh's arms answer conductor-libs-not-loaded).
rm -f "$C/h/bin/lib/merge-conductor-lib.sh" "$C/fx/declared"
tick "$C"; rc=$?
check "S5 no merge-conductor-lib.sh: the loader still runs (rc 0)" "$rc" 0
check "S5 no merge-conductor-lib.sh: ubt_stage_card still defined, mc_requeued_mark not" \
  "$(grep -cx 'ubt_stage_card' "$C/fx/declared" 2>/dev/null) $(grep -cx 'mc_requeued_mark' "$C/fx/declared" 2>/dev/null)" "1 0"
budget S5

# ═════ S6: U2/U3 with the real conductor libs ════════════════════════════════
# s6 <name> <fixture> [attempts transform] -> the case dir
s6() {
  local C NOW; C=$(mktick "s6-$1" queue) || return 1
  jq . "$FX/$2" > "$C/gh-fx.json"
  NOW=$(date -u -d "$(jq -r .now "$C/gh-fx.json")" +%s); mode "$C" shadow   # the fixture's own clock
  mkdir -p "$C/h/state/merge-conductor"
  jq -r --arg extra "${3:-}" '.attempts[], (if $extra == "" then empty else $extra end)' "$C/gh-fx.json" \
    > "$C/h/state/merge-conductor/attempts.txt"
  : > "$C/gh.log"
  tick "$C"
  claims_of "$C" > "$C/claims.jsonl"; records_of "$C" > "$C/records.jsonl"
  printf '%s' "$C"
}
rule_prs() { jq -rs --arg r "$2" 'map(select(.rule_id == $r) | .subject | sub(".*#"; "")) | sort | join(" ")' "$1/claims.jsonl"; }
C=$(s6 u2 batch-7699.json) || exit 1
check "S6 U2: requeued_on_head read false for every member" \
  "$(jq -rs 'map(.evidence.requeued_on_head | tostring) | unique | join(",")' "$C/claims.jsonl")" "false"
check "S6 U2: ejected_on_head read true for #7617" \
  "$(jq -rs --arg s "$R#7617" 'map(select(.subject == $s))[0].evidence.ejected_on_head' "$C/claims.jsonl")" "true"
check "S6 U2: U2-bystander-requeue claims" "$(rule_prs "$C" U2-bystander-requeue)" "7363 7588 7592 7666"
check "S6 U2: U1-batch-culprit claims #7617" "$(rule_prs "$C" U1-batch-culprit)" "7617"
check "S6 U2: 4 WOULD_REQUEUE lines from act.sh" "$(grep -c ' U2-bystander-requeue WOULD_REQUEUE would ' "$C/h/logs/unblock.log")" 4
check "S6 U2: 0 failed records" "$(grep -c '"outcome":"failed"' "$C/records.jsonl")" 0
check "S6 U2: 0 non-GET gh calls" "$(grep -cv '^GET ' "$C/gh.log")" 0
H7592=$(jq -r '.heads["7592"]' "$FX/batch-7699.json")
C=$(s6 u2-requeued batch-7699.json "requeued $R#7592 $H7592 1792490000") || exit 1
check "S6 negative: #7592 requeued on its head reads true" \
  "$(jq -rs --arg s "$R#7592" 'map(select(.subject == $s))[0].evidence.requeued_on_head' "$C/claims.jsonl")" "true"
check "S6 negative: no U2 for #7592, the other three still U2" "$(rule_prs "$C" U2-bystander-requeue)" "7363 7588 7666"
C=$(s6 u2-other-head batch-7699.json "requeued $R#7592 7592000000000000000000000000000000000000 1792490000") || exit 1
check "S6 a requeue of ANOTHER head of #7592 reads false" \
  "$(jq -rs --arg s "$R#7592" 'map(select(.subject == $s))[0].evidence.requeued_on_head' "$C/claims.jsonl")" "false"
C=$(s6 u3 ejects-20261019.json) || exit 1
check "S6 U3: requeued_on_head read false" "$(jq -rs 'map(.evidence.requeued_on_head | tostring) | unique | join(",")' "$C/claims.jsonl")" "false"
check "S6 U3: U3-dead-shard-requeue claims the 3 green members" "$(rule_prs "$C" U3-dead-shard-requeue)" "7590 7595 7600"
check "S6 U3: 3 WOULD_REQUEUE lines" "$(grep -c ' U3-dead-shard-requeue WOULD_REQUEUE would ' "$C/h/logs/unblock.log")" 3
check "S6 U3: 0 failed records" "$(grep -c '"outcome":"failed"' "$C/records.jsonl")" 0
budget S6

# ═════ S7: the card seam ═════════════════════════════════════════════════════
jq -c '.records.U12' "$RECS" > "$T/u12.jsonl"
C=$(mktick s7) || exit 1; mode "$C" shadow; records_collector "$C" "$T/u12.jsonl"
tick "$C"
records_of "$C" > "$C/records.jsonl"
check "S7a shadow: 1 claim, 1 agent-call, 1 record" \
  "$(cnt '^JOBS POST /api/unblock/decisions/claim' "$C/fx/seq.log") $(cnt '^AGENTCALL' "$C/fx/seq.log") $(cnt '^JOBS POST /api/unblock/decisions/record' "$C/fx/seq.log")" "1 1 1"
check "S7a the claim comes before the agent-call, the record after" \
  "$(grep -o '^JOBS POST /api/unblock/decisions/[a-z]*\|^AGENTCALL' "$C/fx/seq.log" | sed 's#.*/##' | tr '\n' ' ')" "claim AGENTCALL record "
check "S7a the agent-call is stage unblock on the tick's route" "$(grep '^AGENTCALL' "$C/fx/seq.log")" "AGENTCALL unblock cromford model-fixture"
check "S7a outcome would, model_calls 1" "$(jq -r '"\(.outcome) \(.model_calls)"' "$C/records.jsonl")" "would 1"
check "S7a the card id is u- + 6 hex" "$(jq -r '.card.id | test("^u-[0-9a-f]{6}$")' "$C/records.jsonl")" "true"
check "S7a the card carries the model's options" "$(jq -r '.card.options | join("|")' "$C/records.jsonl")" "hold: keep it parked|re-run its CI by hand"
check "S7a the detail names the decide outcome and the send" "$(jq -r '.outcome_detail | test("^ok; WOULD_SEND_CARD u-[0-9a-f]{6}$")' "$C/records.jsonl")" "true"
check "S7a 0 alerts in shadow" "$(cnt . "$C/fx/alerts.log")" 0
case "$(tickline "$C")" in *"claimed=1 rows=1 deferred=0"*) ok "S7f tick line deferred=0" ;; *) no "S7f tick line deferred=0" "$(tickline "$C")" ;; esac
check "S7 the card temp dir is removed" "$(find "$C" -maxdepth 1 -name 'ubt-card.*' | wc -l | tr -d ' ')" 0
: > "$C/fx/seq.log"
tick "$C"
check "S7b a second tick: 409, 0 agent-calls, 0 records" \
  "$(cnt '^AGENTCALL' "$C/fx/seq.log") $(cnt '^JOBS POST /api/unblock/decisions/record' "$C/fx/seq.log")" "0 0"
grep -q 'held by row' "$C/h/logs/unblock.log" && ok "S7b the 409 is logged" || no "S7b the 409 is logged"

C=$(mktick s7c) || exit 1; mode "$C" act; records_collector "$C" "$T/u12.jsonl"
tick "$C" UNBLOCK_ACT=1
records_of "$C" > "$C/records.jsonl"
check "S7c act + UNBLOCK_ACT=1: escalated" "$(jq -r .outcome "$C/records.jsonl")" "escalated"
check "S7c one critical alert DM" "$(grep -c -- '--critical --id unblock-' "$C/fx/alerts.log")" 1

C=$(mktick s7d) || exit 1; mode "$C" shadow; records_collector "$C" "$T/u12.jsonl"; echo empty > "$C/fx/ac.mode"
tick "$C"
records_of "$C" > "$C/records.jsonl"
check "S7d an empty answer: billed (model_calls 1), would" "$(jq -r '"\(.outcome) \(.model_calls)"' "$C/records.jsonl")" "would 1"
check "S7d the fallback card: option 1 is hold" "$(jq -r '.card.options[0]' "$C/records.jsonl")" "hold: keep it parked"
check "S7d the detail names the empty answer" "$(jq -r '.outcome_detail | startswith("empty; ")' "$C/records.jsonl")" "true"

# The seam alone, in a subshell, over the decision the S7 tick saw.
C="$T/s7"
DEC=$( HARNESS="$C/h" bash -c '. "$HARNESS/bin/lib/unblock/rules.sh" && ub_rules_eval < "$1"' _ "$T/u12.jsonl" )
DKEY=$(jq -r .decision_key <<<"$DEC")
seam() { # seam <claimed key> <mode> [env...] -- [pre-commands]: the seam's answer
  local ck="$1" m="$2"; shift 2
  : > "$C/fx/seq.log"
  ( export HARNESS="$C/h" FXT="$C/fx" TMPDIR="$C" PATH="$FB:$PATH" UB_NOW="$NOW"
    . "$C/h/bin/lib/token-redact.sh" 2>/dev/null
    . "$C/h/bin/lib/unblock/card.sh" || exit 9
    while [ $# -gt 0 ] && [ "$1" != -- ]; do export "${1?}"; shift; done
    [ "${1:-}" = -- ] && { shift; eval "${1:-:}"; }
    UBT_CLAIMED_KEY="$ck"
    ubt_stage_card "$DEC" model-fixture "$m" )
}
rm -f "$C/fx/alert.fail" "$C/fx/ac.mode"
OUT=$(seam "" shadow)
check "S7e no claim: refused, 0 calls" "$(jq -r '"\(.outcome) \(.model_calls)"' <<<"$OUT" 2>/dev/null) $(cnt '^AGENTCALL' "$C/fx/seq.log")" "refused 0 0"
OUT=$(seam "${DKEY%?}0" shadow)
check "S7 another key's claim: refused, 0 calls" "$(jq -r '"\(.outcome) \(.model_calls)"' <<<"$OUT" 2>/dev/null) $(cnt '^AGENTCALL' "$C/fx/seq.log")" "refused 0 0"
OUT=$(seam "$DKEY" act)
check "S7 act mode, UNBLOCK_ACT unset: would, 0 alerts" "$(jq -r .outcome <<<"$OUT") $(cnt '^ALERT' "$C/fx/seq.log")" "would 0"
touch "$C/fx/alert.fail"
OUT=$(seam "$DKEY" act UNBLOCK_ACT=1)
check "S7 SEND_FAILED: failed, the spend kept" "$(jq -r '"\(.outcome) \(.model_calls) \(.detail | test("SEND_FAILED"))"' <<<"$OUT")" "failed 1 true"
rm -f "$C/fx/alert.fail"
OUT=$(seam "$DKEY" act UNBLOCK_ACT=1)
check "S7 SENT_CARD: escalated" "$(jq -r .outcome <<<"$OUT")" "escalated"
OUT=$(seam "$DKEY" shadow -- 'unblock_card_compose() { return 1; }')
check "S7 a compose failure: failed card-compose-failed, the spend kept" "$(jq -r '"\(.outcome) \(.model_calls) \(.detail)"' <<<"$OUT")" "failed 1 card-compose-failed"
check "S7 the seam's temp dirs are removed" "$(find "$C" -maxdepth 1 -name 'ubt-card.*' | wc -l | tr -d ' ')" 0
budget S7

echo "unblock-rules-contract.bh-8418: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
