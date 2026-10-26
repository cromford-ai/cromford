#!/bin/bash
# tests/unblock-infra-rules.bh-7725-test.sh — BH-7725 (UNB-3): the Tackler infra
# collector and the U8, U9, U10 and U12 rule files, in shadow.
#
# WHAT RUNS. The SHIPPED bin/lib/unblock/collectors/infra.sh, sourced in a
# subshell. Its one input seam, unblock_infra_src, runs for real; only the
# jobs transport under it (_jobs_req) is a stub that answers from a fixture's
# `routes` map and counts every call. pr-state.tsv is a scratch file. A fake
# curl, gh and lane-alert.sh count any write that would leave the box.
#
# THE RULE EVALUATOR. rules.sh is UNB-1 (#7723), not on main. evaluate() below
# implements the plan's documented contract on the committed rule files: kind
# match, every match.all predicate true, false or null or an error = no match
# (unknown is not false), priority order, U12 the fallback, U12's never_auto
# map sets the class.
#
# Cases: A1-A6 the collector, B1-B10 the rules.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-infra-rules.bh-7725-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-infra-rules: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LIB="$DIR/bin/lib/unblock/collectors/infra.sh"
CARD="$DIR/bin/lib/unblock/card.sh"
RULES_D="$DIR/catalog/unblock-rules.d"
FX="$DIR/tests/fixtures/unblock"
for f in "$LIB" "$CARD" "$RULES_D/U8-box-restart.json" "$RULES_D/U9-throughput-knob.json" \
         "$RULES_D/U10-branch-fix-round.json" "$RULES_D/U12-escalate.json" \
         "$FX/box-project-6-os.json" "$FX/pool-project-6.json" "$FX/respawn-loop.json" "$FX/conflict-park.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$LIB" ] || [ ! -f "$RULES_D/U12-escalate.json" ]; then echo "unblock-infra-rules: $PASS passed, $FAIL failed"; exit 1; fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/state/merge-conductor" "$T/fakebin"
ln -s "$DIR/catalog" "$H/catalog"
NOW=1792508400   # 2026-10-20T15:00:00Z
for w in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/writes.log"\nexit 1\n' "$w" "$T" > "$T/fakebin/$w"
  chmod +x "$T/fakebin/$w"
done
printf '#!/bin/bash\nprintf "lane-alert %%s\\n" "$*" >> "%s/writes.log"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# collect <fixture> [collector args] — one collector run. Prints its JSONL.
# _jobs_req answers GET <path> from .routes[path] (null = HTTP 404 = rc 2,
# the string "rc1" = an outage = rc 1). Every call lands in $T/jobs.log.
# br_rows_count answers from .fixrounds[url] when the fixture has the map.
collect() {
  local fx="$1"; shift
  : > "$T/pr-state.tsv.tmp"
  ( export HARNESS="$H" HARNESS_TEST_SANDBOX=1 UNBLOCK_NOW="$NOW" FXF="$fx" FXT="$T" PATH="$T/fakebin:$PATH"
    . "$LIB" || exit 9
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/jobs.log"
      [ "$1" = GET ] || return 1
      local b
      b=$(jq -c --arg p "$2" '.routes[$p]' "$FXF")
      case "$b" in
        null) JOBS_HTTP=404; return 2 ;;
        '"rc1"') JOBS_HTTP=503; return 1 ;;
      esac
      JOBS_HTTP=200; printf '%s' "$b"
    }
    if jq -e 'has("fixrounds")' "$FXF" >/dev/null; then
      br_rows_count() { jq -r --arg u "$1" '.fixrounds[$u] // empty' "$FXF"; }
    fi
    unblock_collect_infra "$@" )
}
# with <fixture> <jq filter> — a variant of a fixture, written to the scratch dir.
with() { local out; out="$T/fx.$(printf '%s' "$2" | md5sum | cut -c1-8).json"; jq "$2" "$1" > "$out"; printf '%s' "$out"; }
parks() { jq -r '.pr_state_tsv[]' "$1" > "$H/state/merge-conductor/pr-state.tsv"; }

# evaluate <record-json> — the plan's rule contract over catalog/unblock-rules.d.
# Prints {rule, class, action, key, near_miss}.
evaluate() {
  local rec="$1" f id pr nm='[]' p r kinds pass act cls key
  while IFS=$'\t' read -r pr f; do
    id=$(jq -r .id "$f")
    kinds=$(jq -c '.match.kind | if type == "array" then . else [.] end' "$f")
    jq -e --argjson k "$kinds" '. as $r | ($k | index("*")) != null or ($k | index($r.kind)) != null' <<<"$rec" >/dev/null || continue
    pass=1
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      r=$(jq -c "$p" <<<"$rec" 2>/dev/null) || r=error
      if [ "$r" != true ]; then
        nm=$(jq -c --arg id "$id" --arg p "$p" --arg r "${r:-error}" '. + [{rule: $id, predicate: $p, read: $r}]' <<<"$nm")
        pass=0; break
      fi
    done < <(jq -r '.match.all[]?' "$f")
    [ "$pass" = 1 ] || continue
    act=$(jq -c --argjson r "$rec" '.action | {verb, args: ((.args // {}) | with_entries(.value as $p | .value = ($r | getpath($p | ltrimstr(".") | split("."))))) }' "$f")
    cls=$(jq -r --argjson r "$rec" '. as $u | ($r.proposal.key // "" | ascii_upcase) as $k
      | ([($u.never_auto // {}) | to_entries[] | select(.key as $g | $k | test("^" + ($g | gsub("\\*"; ".*")) + "$")) | .value] | first) // $u.class' "$f")
    key=$(jq -r --argjson r "$rec" --arg id "$id" '[.key[] | if . == "id" then $id else (. as $k | $r | getpath($k | split(".")) | tostring) end] | join("|")' "$f")
    jq -nc --arg id "$id" --arg c "$cls" --argjson a "$act" --arg k "$key" --argjson n "$nm" '{rule: $id, class: $c, action: $a, key: $k, near_miss: $n}'
    return 0
  done < <(for f in "$RULES_D"/*.json; do printf '%s\t%s\n' "$(jq -r .priority "$f")" "$f"; done | sort -n)
  echo '{"rule":"none"}'
}

# ═════ A: the collector ══════════════════════════════════════════════════════
rm -f "$T/jobs.log" "$T/writes.log"
OUT=$(collect "$FX/box-project-6-os.json" --family box)
eq "A1 one box-hung record" "$(jq -s 'map(select(.kind == "box-hung")) | length' <<<"$OUT")" 1
REC_BOX=$(jq -c 'select(.kind == "box-hung")' <<<"$OUT")
eq "A1 subject" "$(jq -r .subject <<<"$REC_BOX")" "box:box-project-6-os-1"
eq "A1 unreachable minutes" "$(jq -r .ssh_unreachable_min <<<"$REC_BOX")" 540
eq "A1 env-bundle failures" "$(jq -r .envbundle_fail_1h <<<"$REC_BOX")" 14
eq "A1 the threshold rides the record" "$(jq -r .hung_min_threshold <<<"$REC_BOX")" 30
eq "A1 the stall hour is the first unreachable reading's hour" "$(jq -r .stall_at_hour <<<"$REC_BOX")" "2026-10-20T06"
eq "A1 family and unknown" "$(jq -c '[.family, .unknown]' <<<"$REC_BOX")" '["infra",[]]'
check "A1 the reachable box yields no record" '! grep -q box-alpha <<<"$OUT"'
eq "A1 one read, a GET of the box_health route" "$(cat "$T/jobs.log")" "GET /api/boxes/health "
OUT=$(UNBLOCK_BOX_HUNG_MIN=600 collect "$FX/box-project-6-os.json" --family box)
eq "A1 UNBLOCK_BOX_HUNG_MIN reaches the record" "$(jq -r .hung_min_threshold <<<"$OUT")" 600

rm -f "$T/jobs.log"
OUT=$(collect "$FX/pool-project-6.json" --family pool --project project-6-os --project alpha)
REC_POOL=$(jq -c 'select(.kind == "pool-starved" and .project == "project-6-os")' <<<"$OUT")
eq "A2 one pool-starved record for project-6-os" "$(jq -s 'map(select(.kind == "pool-starved" and .project == "project-6-os")) | length' <<<"$OUT")" 1
eq "A2 proposal key" "$(jq -r .proposal.key <<<"$REC_POOL")" "lane.fly-pool-tick.pool_tick_max_parallel"
eq "A2 old new min max" "$(jq -c '.proposal | [.old, .new, .min, .max]' <<<"$REC_POOL")" "[4,8,0,256]"
eq "A2 in range and allowlisted" "$(jq -c '.proposal | [.in_range, .key_allowlisted, .person_set_24h]' <<<"$REC_POOL")" "[true,true,false]"
check "A2 the rollback note names the old value" 'jq -e ".proposal.rollback_note | contains(\"=4\")" <<<"$REC_POOL" >/dev/null'
REC_SHARD=$(jq -c 'select(.kind == "pool-starved" and .project == "alpha")' <<<"$OUT")
eq "A2 CI_MAX_SHARDS: proposal not allowlisted, no range" "$(jq -c '.proposal | [.key, .key_allowlisted, .in_range]' <<<"$REC_SHARD")" '["CI_MAX_SHARDS",false,null]'
check "A2 reads are GETs only" '! grep -qv "^GET " "$T/jobs.log"'
OUT=$(collect "$(with "$FX/pool-project-6.json" '.routes["/api/settings/lane.fly-pool-tick.pool_tick_max_parallel"].setting.value = "0"')" --family pool --project project-6-os)
eq "A2 old 0 (unlimited) proposes nothing" "$(jq -c 'select(.project == "project-6-os") | .proposal' <<<"$OUT")" null
OUT=$(collect "$(with "$FX/pool-project-6.json" '.routes["/api/settings/lane.fly-pool-tick.pool_tick_max_parallel"].setting.value = "200"')" --family pool --project project-6-os)
eq "A2 new is capped at the registry max" "$(jq -c 'select(.project == "project-6-os") | .proposal | [.new, .in_range]' <<<"$OUT")" "[256,true]"
OUT=$(collect "$(with "$FX/pool-project-6.json" '.routes["/api/pool/status?project=project-6-os"].queued = 8')" --family pool --project project-6-os)
eq "A2 queued 8 vs running 2 is not starved" "$OUT" ""
OUT=$(collect "$(with "$FX/pool-project-6.json" '.routes["/api/settings/lane.fly-pool-tick.pool_tick_max_parallel"].setting.actor = "tackler:u8"')" --family pool --project project-6-os)
eq "A2 a record built from a Tackler-authored row is dropped (G6)" "$OUT" ""
OUT=$(collect "$(with "$FX/pool-project-6.json" '.routes["/api/settings/unblock.knob_allowlist"] = "rc1"')" --family pool --project project-6-os)
eq "A2 allowlist unreadable: key_allowlisted is null, named unknown" \
  "$(jq -c '[.proposal.key_allowlisted, (.unknown | index("unblock.knob_allowlist") != null)]' <<<"$OUT")" "[null,true]"

OUT=$(collect "$FX/respawn-loop.json" --family pool --project project-6-os --project alpha)
eq "A3 one respawn-loop record (9 > 6, PLAN_BLOCKED)" "$(jq -s 'map(select(.kind == "respawn-loop")) | length' <<<"$OUT")" 1
REC_RESP=$(jq -c 'select(.kind == "respawn-loop")' <<<"$OUT")
eq "A3 proposal" "$(jq -c '.proposal | [.key, .old, .new, .min, .max, .in_range]' <<<"$REC_RESP")" '["lane.fly-pool.project-6-os.pool_record_read",0,1,0,1,true]'
eq "A3 the looping key" "$(jq -r .respawn_key <<<"$REC_RESP")" TK-901
check "A3 no pool-starved record (3 queued, 3 running)" '! jq -e "select(.kind == \"pool-starved\")" <<<"$OUT" >/dev/null'
OUT=$(UNBLOCK_RESPAWN_MAX_DAY=9 collect "$FX/respawn-loop.json" --family pool --project project-6-os)
eq "A3 UNBLOCK_RESPAWN_MAX_DAY=9: 9 is not over 9" "$OUT" ""

parks "$FX/conflict-park.json"
OUT=$(collect "$FX/conflict-park.json" --family park)
eq "A4 two branch-park records" "$(jq -s 'length' <<<"$OUT")" 2
eq "A4 fix rounds 0 and 2" "$(jq -s -c 'map(.fixrounds)' <<<"$OUT")" "[0,2]"
REC_PARK0=$(jq -c 'select(.pr == 101)' <<<"$OUT"); REC_PARK2=$(jq -c 'select(.pr == 102)' <<<"$OUT")
eq "A4 park fields" "$(jq -c '[.subject, .repo, .pr, .head, .mechanical_rung]' <<<"$REC_PARK0")" \
  '["example-org/alpha#101","example-org/alpha",101,"aaaa1111bbbb2222cccc3333dddd4444eeee5555","failed"]'
check "A4 park reason" 'jq -e ".park_reason | startswith(\"conflict-unresolvable\")" <<<"$REC_PARK0" >/dev/null'
{ jq -r '.pr_state_tsv[]' "$FX/conflict-park.json"
  printf 'example-org/alpha#103\tREADY\t1792497600\th3\th3\t0\t-\thttps://github.com/example-org/alpha/pull/103\n'
  printf 'example-org/alpha#104\tBLOCKED_HUMAN\t1792497600\th4\th4\t0\tiron-law: model id\thttps://github.com/example-org/alpha/pull/104\n'
  printf 'example-org/alpha#105\tBLOCKED_HUMAN\t1792497600\th5\th5\t0\tcontested:x\thttps://github.com/example-org/alpha/pull/105\n'
  printf 'example-org/alpha#106\tBLOCKED_HUMAN\t1792497600\th6\th6\t0\trebase-gate-red: lint\thttps://github.com/example-org/alpha/pull/106\n'
} > "$H/state/merge-conductor/pr-state.tsv"
OUT=$(collect "$FX/conflict-park.json" --family park)
eq "A4 READY, iron-law and contested rows are not branch parks" "$(jq -s -c 'map(.pr)' <<<"$OUT")" "[101,102,106]"
REC_PARKN=$(jq -c 'select(.pr == 106)' <<<"$OUT")
eq "A4 rebase-gate-red: rung n/a, fix rounds unread = null, named unknown" "$(jq -c '[.mechanical_rung, .fixrounds, .unknown]' <<<"$REC_PARKN")" '["n/a",null,["fixrounds"]]'
OUT=$(collect "$FX/box-project-6-os.json" --family park)
eq "A4 no br lib loaded: fix rounds null" "$(jq -s -c 'map(.fixrounds) | unique' <<<"$OUT")" "[null]"
for i in $(seq 1 105); do printf 'example-org/alpha#%d\tBLOCKED_HUMAN\t1792497600\th%d\th%d\t0\tconflict-unresolvable\thttps://github.com/example-org/alpha/pull/%d\n' "$((1000+i))" "$i" "$i" "$((1000+i))"; done > "$H/state/merge-conductor/pr-state.tsv"
OUT=$(collect "$FX/conflict-park.json" --family park)
eq "A4 cap: at most 100 park records, each marked truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" "[100,[true]]"

rm -f "$T/jobs.log" "$T/writes.log"
rm -f "$H/state/merge-conductor/pr-state.tsv"
OUT=$(collect "$(with "$FX/box-project-6-os.json" '.routes["/api/boxes/health"] = "rc1"')")
check "A5 box_health down: one source-unreadable record naming it" \
  'jq -s -e "map(select(.kind == \"source-unreadable\" and .unknown == [\"box_health\"])) | length == 1" <<<"$OUT" >/dev/null'
check "A5 no pr-state.tsv: one source-unreadable record naming parks" \
  'jq -s -e "map(select(.kind == \"source-unreadable\" and .unknown == [\"parks\"])) | length == 1" <<<"$OUT" >/dev/null'
OUT=$(collect "$FX/box-project-6-os.json" --family pool --project project-6-os)
check "A5 pool_status 404 is unreadable too, never nothing stalled" \
  'jq -e "select(.kind == \"source-unreadable\") | .unknown == [\"pool_status\"] and .project == \"project-6-os\"" <<<"$OUT" >/dev/null'
check "A5 0 writes: no curl, gh or lane-alert call, no non-GET request" '[ ! -s "$T/writes.log" ] && ! grep -qv "^GET " "$T/jobs.log"'
OUT=$(collect "$(with "$FX/box-project-6-os.json" '.routes["/api/boxes/health"] = "not json"')" --family box)
check "A5 a body that is not an object is unreadable" 'jq -e ".kind == \"source-unreadable\"" <<<"$OUT" >/dev/null'
# The seam itself, with no fixture stub: no jobs transport loaded at all.
SEAM=$( (export HARNESS="$H" HARNESS_TEST_SANDBOX=1; . "$LIB"; unset -f _jobs_req 2>/dev/null; unblock_infra_src box_health; echo "rc=$?") )
eq "A5 the seam with no jobs transport: rc 1, no output" "$SEAM" "rc=1"
SEAM=$( (export HARNESS="" H=""; . "$LIB"; unblock_infra_src parks; echo "rc=$?") )
eq "A5 the seam with no harness root: rc 1" "$SEAM" "rc=1"
printf '# comment\nproject-6-os example-org/mk https://x.example.com /api 3 project-6-os\nalpha example-org/alpha https://a.example.com /api 3 a\n' > "$T/fleet.conf"
rm -f "$T/jobs.log"
OUT=$(FLEET_CONF="$T/fleet.conf" collect "$FX/pool-project-6.json" --family pool)
eq "A5 no --project: the projects come from fleet.conf" "$(grep -o 'project=[a-z-]*' "$T/jobs.log" | tr '\n' ' ')" "project=project-6-os project=alpha "

# A6: a collected U12 record composes into a card (the writer/reader round trip).
. "$CARD" 2>/dev/null || bad "A6 card.sh does not source"
if type unblock_card_compose >/dev/null 2>&1; then
  A6KEY="a1b2c3d4$(printf 'e5%.0s' $(seq 12))"   # 32 hex, built at run time (share-mirror leakcheck)
  printf '%s' "$REC_SHARD" | jq --arg k "$A6KEY" '. + {decision_key: $k}' > "$T/stall.json"
  unblock_card_fallback "$T/stall.json" > "$T/decide.json"
  CARDJ=$(unblock_card_compose "$T/stall.json" "$T/decide.json" "$A6KEY" "$NOW"); rc=$?
  eq "A6 compose rc" "$rc" 0
  eq "A6 the card names the subject" "$(jq -r .subject <<<"$CARDJ")" "pool:alpha"
else
  bad "A6 unblock_card_compose is not defined"
fi

# ═════ B: the rules ══════════════════════════════════════════════════════════
V=$(evaluate "$REC_BOX")
eq "B1 project-6-os -> U8" "$(jq -r .rule <<<"$V")" U8
eq "B1 would-action box_restart on the box" "$(jq -c '[.action.verb, .action.args.box]' <<<"$V")" '["box_restart","box-project-6-os-1"]'
eq "B1 one decision per box per hour" "$(jq -r .key <<<"$V")" "box:box-project-6-os-1|2026-10-20T06|U8"
eq "B1 U8 cites, delegation and the critical alert (the operator 6294290004 item 2)" \
  "$(jq -c '[(.cites | length > 0), .delegate_in_act, .after.alert]' "$RULES_D/U8-box-restart.json")" '[true,true,"critical"]'
for v in '.last_restart_min_ago = 3' '.ssh_reachable = true | .ssh_unreachable_min = 0' '.orgo_state = "stopped"' \
         '.orgo_hosted = false' '.envbundle_fail_1h = 3' '.ssh_unreachable_min = 30'; do
  eq "B2 $v -> not U8" "$(jq -r .rule <<<"$(evaluate "$(jq -c "$v" <<<"$REC_BOX")")")" U12
done
eq "B2 unreachable 31 min with 4 failures -> U8" \
  "$(jq -r .rule <<<"$(evaluate "$(jq -c '.ssh_unreachable_min = 31 | .envbundle_fail_1h = 4' <<<"$REC_BOX")")")" U8
V=$(evaluate "$(jq -c '.build_claim_10m = null' <<<"$REC_BOX")")
eq "B3 build claim unknown -> U12" "$(jq -r .rule <<<"$V")" U12
check "B3 the card names the predicate that read unknown" 'jq -e ".near_miss | map(.predicate) | any(test(\"build_claim_10m\"))" <<<"$V" >/dev/null'
eq "B3 hung threshold unknown -> U12" "$(jq -r .rule <<<"$(evaluate "$(jq -c '.hung_min_threshold = null' <<<"$REC_BOX")")")" U12

V=$(evaluate "$REC_POOL")
eq "B4 project-6 pool -> U9" "$(jq -r .rule <<<"$V")" U9
eq "B4 would-action setting_set to 8" "$(jq -c '.action | [.verb, .args.key, .args.new]' <<<"$V")" '["setting_set","lane.fly-pool-tick.pool_tick_max_parallel",8]'
check "B4 the note names the old value 4" 'jq -e ".action.args.note | test(\"=4\")" <<<"$V" >/dev/null'
eq "B4 one change per knob per day" "$(jq -r .key <<<"$V")" "lane.fly-pool-tick.pool_tick_max_parallel|2026-10-20|U9"
V=$(evaluate "$REC_SHARD")
eq "B5 CI_MAX_SHARDS -> U12, class spend" "$(jq -c '[.rule, .class]' <<<"$V")" '["U12","spend"]'
B5KEY="b1b2c3d4$(printf 'e5%.0s' $(seq 12))"   # 32 hex, built at run time (share-mirror leakcheck)
printf '%s' "$REC_SHARD" | jq --arg k "$B5KEY" '. + {decision_key: $k}' > "$T/stall5.json"
if type unblock_card_fallback >/dev/null 2>&1; then
  unblock_card_fallback "$T/stall5.json" > "$T/decide5.json"
  check "B5 a card composes for it" 'unblock_card_compose "$T/stall5.json" "$T/decide5.json" "$B5KEY" "$NOW" | jq -e ".text | test(\"TACKLER CARD\")" >/dev/null'
fi
eq "B5 a key with USD -> class spend" "$(jq -r .class <<<"$(evaluate "$(jq -c '.proposal.key = "lane.x.llm_usd_cap"' <<<"$REC_SHARD")")")" spend

V=$(evaluate "$REC_RESP")
eq "B6 respawn -> U9" "$(jq -r .rule <<<"$V")" U9
eq "B6 pool_record_read=1 for project-6-os only" "$(jq -c '.action.args | [.key, .new]' <<<"$V")" '["lane.fly-pool.project-6-os.pool_record_read",1]'

V=$(evaluate "$(jq -c '.proposal.key = "hub_load.shed" | .proposal.key_allowlisted = true | .proposal.min = null | .proposal.max = null | .proposal.in_range = null' <<<"$REC_POOL")")
eq "B7 hub_load.shed with no registry range -> U12" "$(jq -r .rule <<<"$V")" U12
OUT=$(collect "$(with "$FX/pool-project-6.json" ".routes[\"/api/settings/lane.fly-pool-tick.pool_tick_max_parallel\"].setting |= (.actor = \"operator@example.com\" | .updated_at = \"2026-10-20T13:00:00Z\")")" --family pool --project project-6-os)
eq "B7 a person set it 2 h ago: person_set_24h" "$(jq -r .proposal.person_set_24h <<<"$OUT")" true
eq "B7 ... -> U12" "$(jq -r .rule <<<"$(evaluate "$OUT")")" U12
OUT=$(collect "$(with "$FX/pool-project-6.json" ".routes[\"/api/settings/lane.fly-pool-tick.pool_tick_max_parallel\"].setting |= (.actor = \"operator@example.com\" | .updated_at = \"2026-10-19T13:00:00Z\")")" --family pool --project project-6-os)
eq "B7 a person set it 26 h ago -> U9" "$(jq -r .rule <<<"$(evaluate "$OUT")")" U9
eq "B7 old value unlimited, no proposal -> U12" "$(jq -r .rule <<<"$(evaluate "$(jq -c '.proposal = null' <<<"$REC_POOL")")")" U12
eq "B7 new over max -> U12" "$(jq -r .rule <<<"$(evaluate "$(jq -c '.proposal.new = 300 | .proposal.in_range = false' <<<"$REC_POOL")")")" U12

V=$(evaluate "$REC_PARK0")
eq "B8 fix rounds 0 -> U10" "$(jq -r .rule <<<"$V")" U10
eq "B8 would-action fix_round on that head" "$(jq -c '.action | [.verb, .args.pr, .args.head]' <<<"$V")" '["fix_round",101,"aaaa1111bbbb2222cccc3333dddd4444eeee5555"]'
eq "B8 fix rounds 1 -> U10" "$(jq -r .rule <<<"$(evaluate "$(jq -c '.fixrounds = 1' <<<"$REC_PARK0")")")" U10
eq "B9 fix rounds 2 -> U12" "$(jq -r .rule <<<"$(evaluate "$REC_PARK2")")" U12
V=$(evaluate "$REC_PARKN")
eq "B9 fix rounds null -> U12" "$(jq -r .rule <<<"$V")" U12
check "B9 the near miss names fixrounds" 'jq -e ".near_miss | map(.predicate) | any(test(\"fixrounds\"))" <<<"$V" >/dev/null'
eq "B9 rung null -> U12" "$(jq -r .rule <<<"$(evaluate "$(jq -c '.mechanical_rung = null' <<<"$REC_PARK0")")")" U12

# TEST-CHANGE (BH-7722): UNB-0 adds the rule-file contract files _schema.json
# and _cites.json to this directory. They are not rule files, so B10 reads
# only the files without the `_` prefix. Every rule file is still checked.
check "B10 every rule file is valid JSON" 'jq -e . "$RULES_D"/[!_]*.json >/dev/null'
eq "B10 rule ids are unique" "$(jq -r .id "$RULES_D"/[!_]*.json | sort | uniq -d)" ""
eq "B10 every rule cites a guideline" "$(jq -r 'select((.cites | length) == 0) | .id' "$RULES_D"/[!_]*.json)" ""
eq "B10 no acting rule carries a never-auto class" \
  "$(jq -r 'select(.action.verb != "card") | select(.class | IN("spend","production","live-probe","client-board","merge","deploy","governance")) | .id' "$RULES_D"/[!_]*.json)" ""
eq "B10 U12 is the lowest priority" "$(for f in "$RULES_D"/[!_]*.json; do printf '%s %s\n' "$(jq -r .priority "$f")" "$(jq -r .id "$f")"; done | sort -n | tail -1 | cut -d' ' -f2)" U12
eq "B10 the rule shape" "$(jq -r 'select((has("id") and has("priority") and has("family") and has("class") and has("cites") and has("match") and has("judge") and has("action") and has("key") and has("note")) | not) | .id' "$RULES_D"/[!_]*.json)" ""

# C0 (2026-10-26): every collector file defines the UNB-0 contract entry
# ub_collect_<family> that bin/lib/unblock/collect.sh calls. infra.sh defined
# only unblock_collect_infra, so the live tick logged "unwired infra" and read
# nothing.
DIR_REPO=$(cd "$(dirname "$0")/.." && pwd)
for cf in "$DIR_REPO"/bin/lib/unblock/collectors/*.sh; do
  cfam=$(basename "$cf" .sh); cfn="ub_collect_${cfam//-/_}"
  check "C0 collectors/$cfam.sh defines $cfn" "bash -c '. \"\$1\" >/dev/null 2>&1; declare -F \"\$2\" >/dev/null' _ \"$cf\" \"$cfn\""
done
echo "unblock-infra-rules: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
