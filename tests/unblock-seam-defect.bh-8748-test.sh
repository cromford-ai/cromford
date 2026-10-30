#!/bin/bash
# tests/unblock-seam-defect.bh-8748-test.sh — BH-8748: the queue collector's
# batch_failure seam sets its own env, keeps a failure reason, and a lane-wide
# defect is one ALERT per window, not one Tackler card per red-batch draft.
#
# WHY. The hub had no mcp/tools/batch-failure.mjs (harness-sync never copied
# mcp/), ubq_batch_failure ran node with 2>/dev/null and no seam env, and every
# red-batch draft became its own queue-unreadable card with no cause: 99 cards
# since 2026-10-27 01:44Z for one missing file.
#
# Each case seeds its own scratch harness: queue.sh, rules.sh, gh-rest.sh,
# card.sh and seam-defect.sh by their closures, a real copy of
# mcp/lib/config.mjs, a fake mcp/tools/batch-failure.mjs run by the real node,
# a `gh` stub that answers GET from the case fixture and logs every call, and a
# stub bin/gh-token.sh that logs its args and prints `fixture-token`. Every
# collector run uses `env -i` with only the lane's normal env (CONSOLE_URL, no
# HARNESS_CONSOLE_URL, no HARNESS_MCP_GITHUB_TOKEN). 0 network calls.
#
#   S1  tool file removed: 1 queue-unreadable record, reason tool-missing,
#       lane_defect true, seam_file, drafts [9001,9002,9003].
#   S2  mcp/lib/config.mjs removed: 1 record, reason module-missing; node ran
#       once for 3 drafts.
#   S3  the tool answers isError github_http_404 for 9002: one per-draft record
#       with reason tool-error:github_http_404, no lane_defect; 3 tool calls.
#   S4  the tool answers a JSON array for 9001: per-draft reason bad-output.
#   S5  lane env only: the tool sees HARNESS_CONSOLE_URL == CONSOLE_URL and
#       HARNESS_MCP_GITHUB_TOKEN == fixture-token; the mint log shows --read
#       <slug>; 0 queue-unreadable records.
#   S6  the mint prints nothing: 1 record reason github-token-missing,
#       lane_defect true, 1 tool call for 3 drafts. A second slug: the mint log
#       shows that slug (per-repo mint).
#   S7  unblock_card_fallback on the S3 record: WHAT names the reason.
#   S8  a red batch with one culprit and a working seam: U1 for the culprit, no
#       queue-unreadable record.
#   S9  the REAL mcp/tools/batch-failure.mjs, the mint prints nothing: the tool
#       fails with fail('github_auth_not_configured'), which has no
#       structuredContent. 1 record, reason github-token-missing, lane defect.
#   S10 the REAL tool with a token and HARNESS_MCP_GITHUB_URL=not-a-url: it
#       fails with fail('github_url_invalid') before any fetch. 3 per-draft
#       records, reason tool-error:github_url_invalid.
#   The fake tool's error replies have the shape of the real fail(t):
#   {content: [{text}], isError: true}, no structuredContent.
#   F1  ubs_fold on the S1 + S3 records: removes the lane-defect record, prints
#       1, writes 1 ALERT naming tool-missing and mcp/tools/batch-failure.mjs.
#       F1b the S3 record stays and gives no ALERT.
#   F2  a second fold inside the window: 0 new ALERT lines.
#   F3  the marker 25 h old: 1 new ALERT line. F3b alert-line.sh fails: rc 0,
#       count still printed, the marker is not touched.
#   F4  bin/unblock.sh tick in shadow on the S1 fixture: the tick line carries
#       seam_defect=1, no claim for a batch_failure subject, 1 ALERT.
#   F5  the knob file default == 24 == the code fallback in seam-defect.sh.
#   B1  every gh call of the suite is a GET.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/unblock-seam-defect.bh-8748-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

FX="$SRC/tests/fixtures/unblock"
RULES="$SRC/catalog/unblock-rules.d"
R=example-org/cromford
R2=example-org/other-repo
NOW=2026-10-28T12:00:00Z

mkcase() { # mkcase <name> -> prints the case dir
  local C="$T/$1" lib
  mkdir -p "$C/h/mcp/tools" "$C/h/mcp/lib" "$C/bin" "$C/h/logs" "$C/h/state" "$C/h/bin"
  for lib in bin/lib/unblock/collectors/queue.sh bin/lib/unblock/rules.sh bin/lib/gh-rest.sh \
             bin/lib/unblock/card.sh bin/lib/unblock/seam-defect.sh; do
    [ -e "$SRC/$lib" ] || continue
    ( cd "$SRC" && scratch_install_closure "$lib" "$C/h" ) >/dev/null || return 1
  done
  cp "$SRC/mcp/lib/config.mjs" "$C/h/mcp/lib/config.mjs"
  cat > "$C/h/mcp/tools/batch-failure.mjs" <<'JS'
import { readFileSync, appendFileSync } from 'node:fs';
appendFileSync(process.env.BF_LOG, 'import\n');
const text = (t) => [{ type: 'text', text: t }];
export const tools = [{
  name: 'batch_failure', kind: 'read', inputSchema: { type: 'object' },
  handler: async (a, ctx) => {
    const e = process.env;
    const tok = e.HARNESS_MCP_GITHUB_TOKEN ? (e.HARNESS_MCP_GITHUB_TOKEN === 'fixture-token' ? 'fixture' : 'other') : 'none';
    appendFileSync(e.BF_LOG, `call ${a.repo} ${a.draft} console_eq=${e.HARNESS_CONSOLE_URL === e.CONSOLE_URL} url=${ctx.cfg.url} token=${tok}\n`);
    if (!e.HARNESS_MCP_GITHUB_TOKEN) {
      return { content: text('github_auth_not_configured'), isError: true };
    }
    const fx = JSON.parse(readFileSync(e.GH_FX, 'utf8'));
    const mode = (fx.bf_mode || {})[String(a.draft)] || '';
    if (mode.startsWith('error:')) {
      return { content: text(mode.slice(6)), isError: true };
    }
    const v = fx.batch_failure[String(a.draft)];
    if (!v) return { content: text('no such draft'), isError: true };
    if (mode === 'array') return { content: text('[]'), structuredContent: [v] };
    return { content: text(JSON.stringify(v)), structuredContent: v };
  },
}];
JS
  # The App token mint: logs its args beside itself, prints a fixture token
  # unless tok-empty exists. No network.
  cat > "$C/h/bin/gh-token.sh" <<'SH'
#!/bin/bash
d=$(cd "$(dirname "$0")/.." && pwd)
echo "$*" >> "$d/tok.log"
[ -e "$d/tok-empty" ] || echo fixture-token
SH
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
  # The one sanctioned alert writer, as a stub: appends its text, or fails
  # when alert-fail exists.
  cat > "$C/h/bin/alert-line.sh" <<'SH'
#!/bin/bash
d=$(cd "$(dirname "$0")/.." && pwd)
[ -e "$d/alert-fail" ] && exit 1
echo "$*" >> "$d/logs/ALERTS.log"
SH
  chmod +x "$C/bin/"* "$C/h/bin/gh-token.sh" "$C/h/bin/alert-line.sh"
  jq -n '[range(1;22)] | map({key: "G\(.)", value: {title: "fixture guardrail G\(.)"}}) | from_entries' > "$C/cites.json"
  : > "$C/gh.log"; : > "$C/bf.log"; : > "$C/h/tok.log"; : > "$C/h/logs/ALERTS.log"
  # The driver: what the lane runs, sourced in a clean shell.
  cat > "$C/drive.sh" <<'SH'
#!/bin/bash
. "$HARNESS/bin/lib/gh-rest.sh" || exit 9
. "$HARNESS/bin/lib/unblock/collectors/queue.sh" || exit 9
vd_standing() { local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX"); [ -n "$l" ] || return 1; printf '%s\n' "$l"; }
mc_attempt_has() { jq -e --arg l "$1" '(.attempts // []) | index($l) != null' "$GH_FX" >/dev/null; }
mc_requeued_mark() { jq -r --arg k "$1 $2" '(.requeued // {})[$k] // empty' "$GH_FX"; }
setting_get() { local v; v=$(jq -r --arg k "$1" '(.settings // {})[$k] // empty' "$GH_FX"); [ -n "$v" ] || return 2; printf '%s' "$v"; }
if [ "${3:-}" = rules ]; then
  . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
  ub_collect_queue "$1" "$2" | tee "$CASE/stalls.jsonl" | ub_rules_eval "$RULES" > "$CASE/decisions.jsonl"
else
  ub_collect_queue "$1" "$2" > "$CASE/stalls.jsonl"
fi
SH
  printf '%s' "$C"
}

# seed <case dir> [jq transform]: three closed mergify drafts 9001-9003 on both
# slugs, each a passed batch, and empty open lists.
seed() {
  jq -n --arg now "$NOW" --arg r "$R" --arg r2 "$R2" '
    def drafts: [range(9001; 9004) | {number: ., user: {login: "mergify[bot]"},
      head: {ref: "mergify/merge-queue/\(.)abc"}, merged_at: null, closed_at: "2026-10-28T10:00:00Z"}];
    def closed($s): "repos/\($s)/pulls?state=closed&sort=updated&direction=desc&per_page=100";
    def open($s): "repos/\($s)/pulls?state=open&per_page=100";
    {now: $now,
     gh: {(closed($r)): drafts, (closed($r2)): drafts, (open($r)): [], (open($r2)): []},
     batch_failure: ([range(9001; 9004) | {key: "\(.)", value: {batch_state: "passed", complete: true, prs: []}}] | from_entries),
     bf_mode: {}}' | jq "${2:-.}" > "$1/fx.json"
}

# collect <case dir> [slug] [rules]: the collector under `env -i` with only the
# lane's normal env.
collect() {
  local C="$1" slug="${2:-$R}" now
  now=$(date -u -d "$(jq -r .now "$C/fx.json")" +%s)
  # shellcheck disable=SC2086 # CASE_GH_URL is one word or empty, by design
  env -i PATH="$C/bin:$PATH" HOME="$C" HARNESS="$C/h" CONSOLE_URL=http://192.0.2.10 \
    ${CASE_GH_URL:+HARNESS_MCP_GITHUB_URL=$CASE_GH_URL} \
    GH_FX="$C/fx.json" GH_LOG="$C/gh.log" BF_LOG="$C/bf.log" TMPDIR="$C" GH_ETAG=0 \
    UNBLOCK_NOW="$now" CASE="$C" RULES="$RULES" UNBLOCK_CITES_FILE="$C/cites.json" \
    bash "$C/drive.sh" cromford "$slug" "${3:-}" 2> "$C/collect.err"
  echo $? > "$C/rc"
}
unread() { jq -c 'select(.kind == "queue-unreadable")' "$1/stalls.jsonl"; }
calls() { grep -c '^call ' "$1/bf.log"; }

# ---------------------------------------------------------------- S1
C=$(mkcase s1) || exit 1; seed "$C"; rm -f "$C/h/mcp/tools/batch-failure.mjs"; collect "$C"
check "S1 rc 0" "$(cat "$C/rc")" "0"
check "S1 one queue-unreadable record" "$(unread "$C" | wc -l | tr -d ' ')" "1"
check "S1 record: tool-missing lane defect, all 3 drafts" \
  "$(unread "$C" | jq -c '[.reason, .lane_defect, .seam_file, .drafts, .input, .subject_kind]')" \
  '["tool-missing",true,"mcp/tools/batch-failure.mjs",[9001,9002,9003],"batch_failure:9001","lane"]'
S1="$C"

# ---------------------------------------------------------------- S2
C=$(mkcase s2) || exit 1; seed "$C"; rm -f "$C/h/mcp/lib/config.mjs"; collect "$C"
check "S2 one record, reason module-missing, lane defect" \
  "$(unread "$C" | jq -sc 'map([.reason, .lane_defect, .drafts])')" '[["module-missing",true,[9001,9002,9003]]]'
check "S2 node ran once for 3 drafts" "$(grep -c '^import' "$C/bf.log")" "1"

# ---------------------------------------------------------------- S3
C=$(mkcase s3) || exit 1; seed "$C" '.bf_mode["9002"] = "error:github_http_404"'; collect "$C"
check "S3 one per-draft record for 9002, reason kept, no lane_defect" \
  "$(unread "$C" | jq -sc 'map([.input, .reason, (.lane_defect // "absent")])')" \
  '[["batch_failure:9002","tool-error:github_http_404","absent"]]'
check "S3 3 tool calls (9001 and 9003 read)" "$(calls "$C")" "3"
S3="$C"

# ---------------------------------------------------------------- S4
C=$(mkcase s4) || exit 1; seed "$C" '.bf_mode["9001"] = "array"'; collect "$C"
check "S4 bad-output per draft, no fold" \
  "$(unread "$C" | jq -sc 'map([.input, .reason, (.lane_defect // "absent")])')" \
  '[["batch_failure:9001","bad-output","absent"]]'

# ---------------------------------------------------------------- S5
C=$(mkcase s5) || exit 1; seed "$C"; collect "$C"
check "S5 0 queue-unreadable records with the lane env only" "$(unread "$C" | wc -l | tr -d ' ')" "0"
check "S5 the tool saw HARNESS_CONSOLE_URL == CONSOLE_URL and the minted token, 3 calls" \
  "$(grep '^call ' "$C/bf.log" | awk '{print $4, $5, $6}' | sort | uniq -c | tr -s ' ')" \
  " 3 console_eq=true url=http://192.0.2.10 token=fixture"
check "S5 the mint was asked --read for the slug" "$(sort -u "$C/h/tok.log")" "--read $R"

# ---------------------------------------------------------------- S6
C=$(mkcase s6) || exit 1; seed "$C"; touch "$C/h/tok-empty"; collect "$C"
check "S6 one record, github-token-missing lane defect" \
  "$(unread "$C" | jq -sc 'map([.reason, .lane_defect, .drafts])')" '[["github-token-missing",true,[9001,9002,9003]]]'
check "S6 1 tool call for 3 drafts (no node call after a lane defect)" "$(calls "$C")" "1"
: > "$C/h/tok.log"; collect "$C" "$R2"
check "S6 per-repo mint for a second slug" "$(sort -u "$C/h/tok.log")" "--read $R2"
check "S6 second slug: record names that repo" "$(unread "$C" | jq -r '"\(.repo) \(.reason)"')" "$R2 github-token-missing"

# ---------------------------------------------------------------- S7
unread "$S3" > "$S3/s3-record.json"
what=$( export HARNESS="$S3/h"; . "$S3/h/bin/lib/unblock/card.sh" 2>/dev/null || exit 9
  unblock_card_fallback "$S3/s3-record.json" | jq -r .what )
case "$what" in
  *"Reason: tool-error:github_http_404."*) ok "S7 card WHAT names the reason" ;;
  *) no "S7 card WHAT names the reason" "$what" ;;
esac

# ---------------------------------------------------------------- S8
C=$(mkcase s8) || exit 1; cp "$FX/batch-7699.json" "$C/fx.json"; collect "$C" "$R" rules
check "S8 working seam: no queue-unreadable record" "$(unread "$C" | wc -l | tr -d ' ')" "0"
check "S8 U1 for the culprit #7617" \
  "$(jq -rs --arg s "$R#7617" 'map(select(.subject == $s)) | map(.rule_id) | join(",")' "$C/decisions.jsonl")" "U1-batch-culprit"

# ---------------------------------------------------------------- S9, S10
# realtool <case dir>: replace the fake with the real tool and its mcp/lib
# imports. The real tool reads GitHub only after these two checks fail to
# stop it, so S9 and S10 make 0 network calls.
realtool() {
  mkdir -p "$1/h/mcp/tools/lib"
  cp "$SRC/mcp/tools/batch-failure.mjs" "$1/h/mcp/tools/batch-failure.mjs"
  cp "$SRC/mcp/tools/lib/schema.mjs" "$1/h/mcp/tools/lib/schema.mjs"
  cp "$SRC/mcp/lib/config.mjs" "$SRC/mcp/lib/console.mjs" "$SRC/mcp/lib/github.mjs" "$1/h/mcp/lib/"
}
C=$(mkcase s9) || exit 1; seed "$C"; realtool "$C"; touch "$C/h/tok-empty"; collect "$C"
check "S9 real tool, no token: one record, github-token-missing lane defect" \
  "$(unread "$C" | jq -sc 'map([.reason, .lane_defect, .drafts])')" '[["github-token-missing",true,[9001,9002,9003]]]'
C=$(mkcase s10) || exit 1; seed "$C"; realtool "$C"; CASE_GH_URL=not-a-url collect "$C"
check "S10 real tool, bad GitHub URL: the code is read from the fail() text" \
  "$(unread "$C" | jq -sc 'map([.input, .reason, (.lane_defect // "absent")])')" \
  '[["batch_failure:9001","tool-error:github_url_invalid","absent"],["batch_failure:9002","tool-error:github_url_invalid","absent"],["batch_failure:9003","tool-error:github_url_invalid","absent"]]'

# ---------------------------------------------------------------- F1-F3
fold() { # fold <case dir> <records file> -> prints the count, rc in $C/fold.rc
  ( export HARNESS="$1/h" H="$1/h"
    . "$1/h/bin/lib/unblock/seam-defect.sh" 2>/dev/null || exit 9
    ubs_fold cromford "$2" ); echo $? > "$1/fold.rc"
}
alerts() { wc -l < "$1/h/logs/ALERTS.log" | tr -d ' '; }
C=$(mkcase f1) || exit 1
cat "$S1/stalls.jsonl" "$S3/s3-record.json" > "$C/records.jsonl"
n=$(fold "$C" "$C/records.jsonl")
check "F1 fold prints 1 and rc 0" "$n $(cat "$C/fold.rc")" "1 0"
check "F1 the lane-defect record is gone, the S3 record stays" \
  "$(jq -sc 'map([.reason, (.lane_defect // false)])' "$C/records.jsonl")" '[["tool-error:github_http_404",false]]'
check "F1 one ALERT line" "$(alerts "$C")" "1"
check "F1 the ALERT names the reason, the seam file and the repo" \
  "$(grep -c "tool-missing.*mcp/tools/batch-failure.mjs" "$C/h/logs/ALERTS.log") $(grep -c "$R" "$C/h/logs/ALERTS.log")" "1 1"
cp "$S3/s3-record.json" "$C/f1b.jsonl"
mkdir -p "$T/f1b/h/logs"
C2=$(mkcase f1b) || exit 1
n=$(fold "$C2" "$C/f1b.jsonl")
check "F1b a per-draft record: 0 folded, kept, no ALERT" "$n $(wc -l < "$C/f1b.jsonl" | tr -d ' ') $(alerts "$C2")" "0 1 0"

cat "$S1/stalls.jsonl" > "$C/records.jsonl"; fold "$C" "$C/records.jsonl" >/dev/null
check "F2 a second fold inside the window: 0 new ALERT lines" "$(alerts "$C")" "1"
mk=$(ls "$C/h/state/unblock-seam-alert/" 2>/dev/null)
check "F2 one marker, keyed by project and reason" "$mk" "cromford-tool-missing"
touch -d '25 hours ago' "$C/h/state/unblock-seam-alert/$mk" 2>/dev/null
cat "$S1/stalls.jsonl" > "$C/records.jsonl"; fold "$C" "$C/records.jsonl" >/dev/null
check "F3 past the window: 1 new ALERT line" "$(alerts "$C")" "2"
C=$(mkcase f3b) || exit 1; touch "$C/h/alert-fail"
cat "$S1/stalls.jsonl" > "$C/records.jsonl"; n=$(fold "$C" "$C/records.jsonl")
check "F3b alert-line fails: count 1, rc 0, no marker" \
  "$n $(cat "$C/fold.rc") $(ls "$C/h/state/unblock-seam-alert/" 2>/dev/null | wc -l | tr -d ' ')" "1 0 0"

# ---------------------------------------------------------------- F4
C=$(mkcase f4) || exit 1; seed "$C"; rm -f "$C/h/mcp/tools/batch-failure.mjs"
for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || no "F4 setup: closure $S"
done
mkdir -p "$C/h/catalog/unblock-rules.d" "$C/col" "$C/h/env"
cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
# scratch-closure-allow: places the already-installed queue collector into the UNBLOCK_COLLECTORS_DIR seam the tick reads; the closure itself comes from scratch_install_closure above
cp "$C/h/bin/lib/unblock/collectors/queue.sh" "$C/col/queue.sh"
: > "$C/h/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
TNOW=$(date -u -d "$NOW" +%s)
jq -nc --argjson fa "$TNOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow", "unblock.enabled": "1"}, seeded: {}}' \
  > "$C/h/state/settings-cache.json"
cat > "$C/fx.sh" <<'SH'
setting_get() {
  case "$1" in unblock.enabled) printf 1; return 0 ;; esac
  return 2
}
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$JOBS_LOG"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim") printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
vd_standing() { return 1; }
mc_attempt_has() { return 1; }
mc_requeued_mark() { return 0; }
SH
: > "$C/jobs.log"; : > "$C/model.log"
printf '#!/bin/bash\necho "model $*" >> "%s"\n' "$C/model.log" > "$C/bin/claude"; chmod +x "$C/bin/claude"
( env -i PATH="$C/bin:$PATH" HOME="$C" HARNESS="$C/h" CONSOLE_URL=http://192.0.2.10 GH_FX="$C/fx.json" GH_LOG="$C/gh.log" \
    BF_LOG="$C/bf.log" JOBS_LOG="$C/jobs.log" GH_ETAG=0 TMPDIR="$C" UNBLOCK_NOW="$TNOW" UB_NOW="$TNOW" \
    UNBLOCK_FIXTURE="$C/fx.sh" UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    LANE_GATE_NOW="$TNOW" LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= \
    bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
TL=$(grep ' tick cromford mode=' "$C/h/logs/unblock.log" 2>/dev/null | tail -n1)
case "$TL" in *" seam_defect=1"*) ok "F4 tick line carries seam_defect=1" ;; *) no "F4 tick line carries seam_defect=1" "$TL $(head -c 600 "$C/tick.out")" ;; esac
case "$TL" in *" records=0 "*) ok "F4 the folded record is not counted" ;; *) no "F4 the folded record is not counted" "$TL" ;; esac
check "F4 no claim for a batch_failure subject (no card)" "$(grep -c 'batch_failure' "$C/jobs.log")" "0"
check "F4 one ALERT line naming tool-missing" "$(grep -c 'tool-missing' "$C/h/logs/ALERTS.log")" "1"
check "F4 0 model calls" "$(wc -l < "$C/model.log" | tr -d ' ')" "0"

# ---------------------------------------------------------------- F5
KF="$SRC/catalog/lanes.d/unblock.knobs.d/UNBLOCK_SEAM_ALERT_WINDOW_H.json"
kd=$(jq -r '.default' "$KF" 2>/dev/null)
cf=$(grep -o 'UNBLOCK_SEAM_ALERT_WINDOW_H:-}" [0-9]*' "$SRC/bin/lib/unblock/seam-defect.sh" 2>/dev/null | awk '{print $2}')
check "F5 knob default == code fallback == 24" "$kd $cf" "24 24"

# ---------------------------------------------------------------- B1
check "B1 every gh call of the suite is a GET" "$(cat "$T"/*/gh.log | grep -cv '^GET ')" "0"

echo "unblock-seam-defect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
