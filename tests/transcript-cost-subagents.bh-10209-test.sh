#!/bin/bash
# tests/transcript-cost-subagents.bh-10209-test.sh — bin/transcript-cost.sh
# sums the CLI 2.1.331 subagent files and reports their dollars (BH-10209).
#
# WHY. On CLI 2.1.331 an Agent call writes its turns to
# <project>/<session>/subagents/agent-<id>.jsonl (plus a .meta.json). The
# entries carry isSidechain:true and the PARENT's sessionId, and no
# parentSessionId. The main file holds none of them. Before BH-10209 the
# pricer looked only in <project>/ itself, so every claude cost row left the
# subagent spend out, and the subagent share of execute spend could not be
# measured at all.
#
# Cases (the plan's S1-S9, plus S10 for the dedup and no-key rows of the
# decision table):
#   S1  main + <sid>/subagents/agent-a.jsonl: both summed, the subagent
#       response once (it is written as 2 content-block lines).
#   S2  --no-subagents: main only.
#   S3  --subagent-usd: last field = the subagent dollars; field order with
#       --price-version and --peak.
#   S4  an in-file isSidechain entry is subagent spend, and --no-subagents
#       keeps it (the premise tests/transcript-cost-test.sh pins).
#   S5  --peak ignores a subagent's bigger context.
#   S6  field 6 stays the main session's model when a subagent writes more.
#   S7  COST_TRANSCRIPT_SUBAGENT_DIR=0: main only.
#   S8  --since drops a subagent entry before the cut.
#   S9  another session's subagents dir and a .meta.json are not read; an
#       unreadable entry in the dir is skipped and the line still prints.
#   S10 a subagents-dir entry with no isSidechain key is subagent spend; one
#       that repeats a main-file response id is counted once, as main.
# No network, no model call. Prices come from a fixture table.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

TC="$DIR/bin/transcript-cost.sh"
#   test-model: prompt 1e-5 completion 2e-5 (version 3)
#   test-haiku: prompt 1e-6 completion 5e-6
cat > "$T/prices.json" <<'JSON'
{"per_token":{
  "test-model": {"prompt":0.00001,"completion":0.00002,"cache_read":0.000001,"cache_write":0.0000125,"version":3},
  "test-haiku": {"prompt":0.000001,"completion":0.000005,"cache_read":0.0000001,"cache_write":0.00000125}
}}
JSON
mkdir -p "$T/cfg/projects"
PROJ="$T/cfg/projects/-work"
mkdir -p "$PROJ"

# msg <file> <msg-id> <model> <in> <out> <cache_read> [ts] [extra-json]
msg() {
  mkdir -p "$(dirname "$1")"
  python3 - "$@" <<'PY'
import json, sys
a = sys.argv[1:] + [""] * 9
f, mid, model, i, o, cr, ts, extra = a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]
e = {"type": "assistant", "uuid": "u-%s-%d" % (mid, len(open(f).read()) if __import__("os").path.exists(f) else 0),
     "timestamp": ts or "2026-11-26T10:00:00.000Z",
     "message": {"id": mid, "type": "message", "role": "assistant", "model": model,
                 "content": [{"type": "text", "text": "x"}],
                 "usage": {"input_tokens": int(i), "output_tokens": int(o),
                           "cache_read_input_tokens": int(cr),
                           "cache_creation_input_tokens": 0}}}
if extra:
    e.update(json.loads(extra))
open(f, "a").write(json.dumps(e) + "\n")
PY
}
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
nf()    { printf '%s' "$1" | awk -F'|' '{print NF}'; }
run_tc() { "$TC" "$@" --config-dir "$T/cfg" --prices "$T/prices.json" 2>"$T/err"; }

# fixture_s1 <sid> — main: 2 test-model responses (100 in, 100 out each =
# $0.003 each). Subagent: 1 test-haiku response (1000 in, 1000 out = $0.006),
# written as 2 content-block lines with one message.id, the CLI 2.1.331 way.
fixture_s1() {
  local s="$1"
  msg "$PROJ/$s.jsonl" "m1-$s" test-model 100 100 0
  msg "$PROJ/$s.jsonl" "m2-$s" test-model 100 100 0
  for _ in 1 2; do
    msg "$PROJ/$s/subagents/agent-a.jsonl" "sub1-$s" test-haiku 1000 1000 0 "" "{\"isSidechain\":true,\"sessionId\":\"$s\"}"
  done
  printf '{"agentType":"general-purpose","model":"haiku"}\n' > "$PROJ/$s/subagents/agent-a.meta.json"
}

echo "--- S1. the subagents dir is summed, each response once"
S1=sess-bh10209-s01; fixture_s1 "$S1"
L=$(run_tc "$S1" --cwd /work); RC=$?
eq "S1 rc" "$RC" 0
eq "S1 files (main + subagent)" "$(field "$L" 8)" 2
eq "S1 input (100+100+1000, the sub response once)" "$(field "$L" 1)" 1200
eq "S1 output" "$(field "$L" 2)" 1200
eq "S1 usd (0.006 main + 0.006 sub)" "$(field "$L" 5)" 0.012000
eq "S1 messages" "$(field "$L" 7)" 3
J=$(run_tc "$S1" --cwd /work --format json)
python3 - "$J" <<'PY' && ok || bad "S1 json: models must hold both, subagent_usd 0.006, subagent_files 1: $J"
import json, sys
d = json.loads(sys.argv[1])
assert set(d["models"]) == {"test-model", "test-haiku"}, d["models"]
assert d["subagent_usd"] == 0.006, d.get("subagent_usd")
assert len(d["subagent_files"]) == 1 and d["subagent_files"][0].endswith("/subagents/agent-a.jsonl"), d.get("subagent_files")
assert not any(f.endswith(".meta.json") for f in d["files"]), d["files"]
PY

echo "--- S2. --no-subagents"
L=$(run_tc "$S1" --cwd /work --no-subagents)
eq "S2 files" "$(field "$L" 8)" 1
eq "S2 usd = main only" "$(field "$L" 5)" 0.006000

echo "--- S3. --subagent-usd and the field order"
L=$(run_tc "$S1" --cwd /work --subagent-usd)
eq "S3 field count" "$(nf "$L")" 10
eq "S3 last field = subagent dollars" "$(field "$L" 10)" 0.006000
L=$(run_tc "$S1" --cwd /work --price-version --subagent-usd)
eq "S3 field count with --price-version" "$(nf "$L")" 11
eq "S3 field 10 is the price version" "$(field "$L" 10)" 3
eq "S3 field 11 is sub_usd" "$(field "$L" 11)" 0.006000
L=$(run_tc "$S1" --cwd /work --price-version --peak --subagent-usd)
eq "S3 field count with all three" "$(nf "$L")" 12
eq "S3 field 11 is peak (main max = 100)" "$(field "$L" 11)" 100
eq "S3 field 12 is sub_usd" "$(field "$L" 12)" 0.006000
L=$(run_tc "$S1" --cwd /work --price-version --peak)
eq "S3 no flag: the line keeps its 11 fields" "$(nf "$L")" 11
L=$(run_tc "$S1" --cwd /work --no-subagents --subagent-usd)
eq "S3 --no-subagents: a measured zero" "$(field "$L" 10)" 0.000000

echo "--- S4. an in-file sidechain is subagent spend, kept by --no-subagents"
S4=sess-bh10209-s04
msg "$PROJ/$S4.jsonl" "m1-$S4" test-model 100 100 0
msg "$PROJ/$S4.jsonl" "side-$S4" test-haiku 1000 1000 0 "" '{"isSidechain":true}'
msg "$PROJ/$S4.jsonl" "m2-$S4" test-model 100 100 0 "" '{"isSidechain":false}'
L=$(run_tc "$S4" --cwd /work --subagent-usd)
eq "S4 usd" "$(field "$L" 5)" 0.012000
eq "S4 sub_usd = the in-file sidechain" "$(field "$L" 10)" 0.006000
L=$(run_tc "$S4" --cwd /work --subagent-usd --no-subagents)
eq "S4 --no-subagents keeps the in-file sidechain" "$(field "$L" 10)" 0.006000

echo "--- S5. --peak counts the main session only"
S5=sess-bh10209-s05
msg "$PROJ/$S5.jsonl" "m1-$S5" test-model 100 10 400
msg "$PROJ/$S5/subagents/agent-b.jsonl" "sub-$S5" test-haiku 10 10 90000 "" "{\"isSidechain\":true,\"sessionId\":\"$S5\"}"
L=$(run_tc "$S5" --cwd /work --peak)
eq "S5 peak = the main max (100+400)" "$(field "$L" 10)" 500

echo "--- S6. the model column stays the main session's"
L=$(run_tc "$S1" --cwd /work)
eq "S6 field 6 (haiku wrote 1000 out, main 200)" "$(field "$L" 6)" test-model

echo "--- S7. COST_TRANSCRIPT_SUBAGENT_DIR=0"
L=$(COST_TRANSCRIPT_SUBAGENT_DIR=0 run_tc "$S1" --cwd /work --subagent-usd)
eq "S7 files" "$(field "$L" 8)" 1
eq "S7 usd" "$(field "$L" 5)" 0.006000
eq "S7 sub_usd" "$(field "$L" 10)" 0.000000

echo "--- S8. --since drops an older subagent entry"
S8=sess-bh10209-s08
msg "$PROJ/$S8.jsonl" "m1-$S8" test-model 100 100 0 2026-11-26T21:00:00.000Z
msg "$PROJ/$S8/subagents/agent-c.jsonl" "sub-$S8" test-haiku 1000 1000 0 2026-11-26T19:00:00.000Z "{\"isSidechain\":true,\"sessionId\":\"$S8\"}"
CUT=$(date -u -d '2026-11-26T20:00:00Z' +%s)
L=$(run_tc "$S8" --cwd /work --since "$CUT" --subagent-usd)
eq "S8 input (main only)" "$(field "$L" 1)" 100
eq "S8 sub_usd" "$(field "$L" 10)" 0.000000
L=$(run_tc "$S8" --cwd /work --subagent-usd)
eq "S8 without --since the subagent counts" "$(field "$L" 10)" 0.006000

echo "--- S9. near misses are not read"
S9=sess-bh10209-s09
OTHER=sess-bh10209-other
msg "$PROJ/$S9.jsonl" "m1-$S9" test-model 100 100 0
msg "$PROJ/$OTHER.jsonl" "m1-$OTHER" test-model 5 5 0
msg "$PROJ/$OTHER/subagents/agent-z.jsonl" "sub-$OTHER" test-haiku 7777 0 0 "" "{\"isSidechain\":true,\"sessionId\":\"$OTHER\"}"
# A .meta.json that holds a usage-shaped line: read, it would add 5555 input.
msg "$PROJ/$S9/subagents/agent-m.meta.json" "meta-$S9" test-haiku 5555 0 0
L=$(run_tc "$S9" --cwd /work --subagent-usd)
eq "S9 input (no other session, no meta.json)" "$(field "$L" 1)" 100
eq "S9 files" "$(field "$L" 8)" 1
# An entry the reader cannot open (a directory named *.jsonl) is skipped.
mkdir -p "$PROJ/$S9/subagents/agent-broken.jsonl"
msg "$PROJ/$S9/subagents/agent-ok.jsonl" "sub-$S9" test-haiku 1000 1000 0 "" "{\"isSidechain\":true,\"sessionId\":\"$S9\"}"
L=$(run_tc "$S9" --cwd /work --subagent-usd); RC=$?
eq "S9 rc with an unreadable entry" "$RC" 0
eq "S9 the readable subagent still counts" "$(field "$L" 10)" 0.006000
eq "S9 usd (main 0.003 + sub 0.006)" "$(field "$L" 5)" 0.009000

echo "--- S10. location decides; dedup keeps the main read"
S10=sess-bh10209-s10
msg "$PROJ/$S10.jsonl" "m1-$S10" test-model 100 100 0
msg "$PROJ/$S10/subagents/agent-d.jsonl" "sub-$S10" test-haiku 1000 1000 0
msg "$PROJ/$S10/subagents/agent-d.jsonl" "m1-$S10" test-model 100 100 0 "" '{"isSidechain":true}'
L=$(run_tc "$S10" --cwd /work --subagent-usd)
eq "S10 usd (repeated id counted once)" "$(field "$L" 5)" 0.009000
eq "S10 sub_usd (the no-key entry only)" "$(field "$L" 10)" 0.006000
eq "S10 messages" "$(field "$L" 7)" 2

echo "transcript-cost-subagents.bh-10209: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
