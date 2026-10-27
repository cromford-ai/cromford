#!/bin/bash
# tests/triage-state-no-decision.bh-8497-test.sh — BH-8497 part 2: two ways an
# open ticket sat off the model forever.
#
#   3  a ticket whose verdict names a blocker OFF the board fingerprint (no
#      ai-build label) gets a new input hash when the blocker closes: the
#      blocker is looked up over REST (refs.json), OPEN keeps the ticket
#      `skip unchanged`, CLOSED sends it to the model once
#   4  a verdict with reason "no DECISION line" is a counted retry, not a final
#      verdict: due again after the backoff, up to TRIAGE_STATE_NO_DECISION_RETRIES
#      (fallback 3) times; then final, with ONE ALERT line naming the keys
#   K  the retry cap and the board page cap are registry knobs
#
# Everything real except the network edges: bin/lib/triage-state.sh,
# bin/triage-state.py, bin/triage-gate.sh --thread and the REAL worker route on
# node:sqlite (the tests/triage-state-fetch-cap.bh-3920-test.sh scaffold). `gh`
# is a PATH stub serving fixture issues. The clock is pinned (_ts_now).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-no-decision.bh-8497-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
NOW=1793000000
NOW_T=$NOW
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
PY="$DIR/bin/triage-state.py"
ND="in the model set and in scope, no DECISION line, session rc 0"

# ═══ K — the knobs (no node needed) ═════════════════════════════════════════════
KD="$DIR/catalog/lanes.d/_lib.triage-state.knobs.d"
[ "$(jq -c '[.type, .default, .min, .max, (.settable // true)]' "$KD/TRIAGE_STATE_NO_DECISION_RETRIES.json" 2>/dev/null)" = '["int",3,0,20,true]' ] \
  && ok || bad "(K1) the registry declares TRIAGE_STATE_NO_DECISION_RETRIES int 3, 0..20, settable"
[ "$(jq -c '[.type, .default, .min, .max, .read_in]' "$KD/TRIAGE_STATE_BOARD_MAX_PAGES.json" 2>/dev/null)" = '["int",20,1,100,"bin/lib/triage-board-pages.sh"]' ] \
  && ok || bad "(K1) the registry declares TRIAGE_STATE_BOARD_MAX_PAGES int 20, 1..100, read in bin/lib/triage-board-pages.sh"

# ═══ U — the decide rule on its own (python only) ══════════════════════════════
# One hashes.tsv line per key against one rows file: what is due back at the model.
H64=$(printf 'b%.0s' $(seq 64))
urow() { # urow <key> <reason> [next_recheck_at] [verdict]
  jq -nc --arg k "$1" --arg r "$2" --arg n "${3:-}" --arg v "${4:-triaged}" --arg h "$H64" --arg t "$(iso $((NOW-90000)))" \
    '{ticket_key:$k, verdict:$v, waiting_on:"none", verdict_hash:$h, input_hash:$h, triaged_at:$t, reason:$r}
     + (if $n == "" then {} else {next_recheck_at:$n} end)'
}
{ urow 1 "$ND"
  urow 2 "$ND (no-decision 2/3)" "$(iso $((NOW-60)))"
  urow 3 "$ND (no-decision 1/3)" "$(iso $((NOW+600)))"
  urow 4 "$ND (no-decision retries spent 3/3)"
  urow 5 "DECISION skip: the last run printed no DECISION line, and that is fine"
  urow 6 "$ND" "" needs_clarification
  urow 7 "handed-no-decision $H64: the session was handed this ticket; was: $ND" "$(iso $((NOW+600)))"
} | jq -sc . > "$T/urows.json"
for k in 1 2 3 4 5 6 7; do printf '%s\tTS-%s\t%s\t-\t1\t-\t-\t-\n' "$k" "$k" "$H64"; done > "$T/uhashes.tsv"
udecide() { python3 "$PY" decide --hashes "$T/uhashes.tsv" --rows "$T/urows.json" --now "$NOW" --ttl 0 --defer-ttl 7200 --gh 1 "$@" 2>/dev/null \
            | awk -F'\t' '{print $1"="$3" "$4}' | tr '\n' '|'; }
U=$(udecide --no-decision-retries 3)
case "$U" in *"1=llm recheck-due|"*) ok ;; *) bad "(4a) a legacy no-DECISION row (no counter, no stamp) is due: [$U]" ;; esac
case "$U" in *"2=llm recheck-due|"*) ok ;; *) bad "(4b) (no-decision 2/3) with a past stamp is due: [$U]" ;; esac
case "$U" in *"3=skip unchanged:triaged|"*) ok ;; *) bad "(4b) (no-decision 1/3) with a future stamp is not due: [$U]" ;; esac
case "$U" in *"4=skip unchanged:triaged|"*) ok ;; *) bad "(4e) a spent row is final: [$U]" ;; esac
case "$U" in *"5=skip unchanged:triaged|"*) ok ;; *) bad "(4d) 'no DECISION line' not at the start is not due: [$U]" ;; esac
case "$U" in *"6=skip unchanged:needs_clarification|"*) ok ;; *) bad "(4d) a needs_clarification row is not retried: [$U]" ;; esac
case "$U" in *"7=skip unchanged:triaged|"*) ok ;; *) bad "(4c) a handed-no-decision reason is not a no-DECISION retry: [$U]" ;; esac
U0=$(udecide --no-decision-retries 0)
case "$U0" in *"1=skip unchanged:triaged|2=skip unchanged:triaged|"*) ok ;; *) bad "(4f) at 0 retries no no-DECISION row is due: [$U0]" ;; esac
U_=$(udecide)
[ "$U_" = "$U0" ] && ok || bad "(4f) no --no-decision-retries reads as 0 (the old rule): [$U_] vs [$U0]"
# due (the per-row timer list) asks the same rule
UD=$(python3 "$PY" due --rows "$T/urows.json" --now "$NOW" --ttl 0 --defer-ttl 7200 --gh 1 --no-decision-retries 3 2>/dev/null | tr '\n' ' ')
[ "$UD" = "1 2 " ] && ok || bad "(4a) due lists the two due no-DECISION rows: [$UD]"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-no-decision: SKIPPED the worker cases, this node has no node:sqlite"
  echo "triage-state-no-decision: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
# --write: the worker route imports catalog/lanes.json from the checkout
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
cp "$DIR/catalog/lanes.json" "$T/lanes.json"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"; P=project-5; SLUG=example-org/project-5
mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/catalog" "$T/gbin" "$T/fx/issues" "$T/fx/refs" "$T/calls"
for s in bin/lib/triage-state.sh bin/lib/jobs/queue.sh bin/triage-gate.sh bin/fleet-conf.sh bin/triage-state.py bin/triage-signal.py bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "FAIL: setup: cannot install $s"; exit 1; }
done
cp "$T/lanes.json" "$H/catalog/lanes.json"
: > "$H/env/global.env"
echo "SOP. Keys are TK-<issue-number>." > "$H/prompts/$P.md"

# gh, as gh_rest calls it: an issue on the board from fx/issues, a ref that is
# NOT on the board (no ai-build label) from fx/refs.
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/gh"
case "\$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
  *repos/$SLUG/pulls*) printf 'HTTP/2 200\r\n\r\n[]\n'; exit 0 ;;
esac
N=\$(printf '%s\n' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p' | head -1)
F="$T/fx/issues/\$N.json"; [ -s "\$F" ] || F="$T/fx/refs/\$N.json"
[ -n "\$N" ] && [ -s "\$F" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
case "\$*" in
  *issues/\$N/comments*) printf 'HTTP/2 200\r\n\r\n'; jq -c '.comments' "\$F"; exit 0 ;;
  *) printf 'HTTP/2 200\r\n\r\n'; jq -c '.issue' "\$F"; exit 0 ;;
esac
STUB
chmod +x "$T/gbin/gh"

# the worker, through the real router
export NODE_OPTIONS=--no-warnings
DB="$T/d1.sqlite"
cat >"$T/drv.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
const [method, path, body] = process.argv.slice(2);
const res = await worker.fetch(new Request('https://jobs.test' + path, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
_jobs_req() {
  local out code
  out=$(node "$T/drv.mjs" "$1" "$2" "${3:-}") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in 2*) printf '%s' "$out"; return 0 ;; 409) printf '%s' "$out"; return 9 ;; 404) return 2 ;; *) return 1 ;; esac
}
job_ledger_get() { return 2; }
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1]);
  for (const row of db.prepare(process.argv[2]).all()) console.log(Object.values(row).join("\t"));' "$DB" "$1"; }

# ── fixtures ─────────────────────────────────────────────────────────────────
iss() { # iss <n> <title> [body] — an ai-build issue on the board
  jq -n --argjson n "$1" --arg t "$2" --arg b "${3:-body}" \
    '{issue:{number:$n,title:$t,body:$b,state:"open",labels:[{name:"ai-build"}],assignees:[],milestone:null,comments:0,
      updated_at:"2026-10-20T09:00:00Z"},comments:[]}' > "$T/fx/issues/$1.json"
}
ref() { # ref <n> <open|closed> — an issue OFF the board (no ai-build label)
  jq -n --argjson n "$1" --arg s "$2" \
    '{issue:{number:$n,title:"blocker",body:"b",state:$s,labels:[],assignees:[],milestone:null,comments:0,
      updated_at:"2026-10-20T09:00:00Z"},comments:[]}' > "$T/fx/refs/$1.json"
}
world() { # the gate's fingerprint, from fx/issues only (a ref is never on it)
  local rows
  rows=$(for f in "$T/fx/issues/"*.json; do jq -c '.issue | {number, state:(.state|ascii_upcase), title, comments, updatedAt: .updated_at}' "$f"; done | jq -sc 'sort_by(.number)')
  jq -cS -n --argjson i "$rows" '{issues:$i, prs:[], meta:{}}' > "$H/state/$P.gate.pending"
}
tick_env() { # tick_env <mode>
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$DIR/fleet.conf" TRIAGE_GH_SLUG="$SLUG" \
         HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE="$1" GH_TOKEN=tok-fixture-1 \
         LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/lanes.json"
  PROJECT=$P; STAMP="2026-10-26 10:00:00Z"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
  GATE_DECISION="RUN board-changed"; GATE_REASON="board-changed"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; EW_KEYS=""; JOB_ID=""
}
# shellcheck source=/dev/null
. "$H/bin/lib/jobs/queue.sh"
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
_ts_now() { echo "$NOW_T"; }
SD="$H/state/triage-state/$P"
dec() { awk -F'\t' -v k="$1" '$1==k{print $3" "$4}' "$SD/decisions.tsv" 2>/dev/null; }
col5() { awk -F'\t' -v k="$1" '$1==k{print $5}' "$SD/decisions.tsv" 2>/dev/null; }
row() { sql "SELECT $2 FROM triage_state WHERE project='$P' AND ticket_key='$1'"; }
tick() { : > "$T/calls/gh"; ( ts_precheck >/dev/null 2>&1 ); }
session() { printf '%b' "$1" > "$T/out.txt"; ts_after_session "$H" "$P" 0 "$T/out.txt" >/dev/null 2>&1; }
put_row() { # put_row <key> <reason> <verdict_hash> [next_recheck_at] — one stored verdict
  jq -nc --arg p "$P" --arg k "$1" --arg r "$2" --arg h "$3" --arg n "${4:-}" --arg t "$(iso $((NOW-90000)))" \
    '{project:$p, rows:[{ticket_key:$k, ticket_label:("TK-" + $k), verdict:"triaged", waiting_on:"none", verdict_hash:$h,
      input_hash:$h, triaged_at:$t, reason:$r} + (if $n == "" then {} else {next_recheck_at:$n} end)]}' > "$T/put.json"
  triage_state_put "$T/put.json" >/dev/null 2>&1
}
ndalerts() { grep -c 'no DECISION line' "$H/logs/ALERTS.log" 2>/dev/null || true; }
reset() { rm -f "$T/fx/issues/"*.json "$T/fx/refs/"*.json "$DB"; scratch_rm "$SD"; : > "$H/logs/$P.log"; : > "$H/logs/ALERTS.log"; NOW_T=$NOW; }

# ═══ 3 — a blocker closes OFF the fingerprint ══════════════════════════════════
reset
iss 1767 "child"; ref 1766 open; world
tick_env enforce
tick 3pre
[ "$(dec 1767)" = "llm new" ] && ok || bad "(3) precondition: the child is new: [$(dec 1767)]"
session 'tickets=1\nDECISION: TK-1767 :: skip :: blocked by open #1766\n'
case "$(row 1767 reason)" in *"#1766"*) ok ;; *) bad "(3) precondition: the verdict names the blocker: [$(row 1767 reason)]" ;; esac
# 3a — blocker OPEN: unchanged
tick 3a
case "$(dec 1767)" in "skip unchanged:"*) ok ;; *) bad "(3a) blocker open: the child is skip unchanged: [$(dec 1767)]" ;; esac
# 3b — the off-board blocker was looked up and is cached
[ "$(jq -r '."1766" // ""' "$SD/refs.json" 2>/dev/null)" = OPEN ] && ok || bad "(3b) refs.json holds 1766 OPEN: $(cat "$SD/refs.json" 2>/dev/null)"
# 3c — the blocker closes: the child's hash moves and it goes to the model
ref 1766 closed
tick 3c
[ "$(dec 1767)" = "llm changed" ] && ok || bad "(3c) blocker closed: the child is llm changed: [$(dec 1767)]"
[ "$(jq -r '."1766" // ""' "$SD/refs.json" 2>/dev/null)" = CLOSED ] && ok || bad "(3c) refs.json now holds 1766 CLOSED"
# 3d — a new verdict on the child: it entered the model set once
session 'tickets=1\nDECISION: TK-1767 :: comment :: the blocker landed, asked the client to confirm\n'
tick 3d
case "$(dec 1767)" in "skip unchanged:"*) ok ;; *) bad "(3d) after its new verdict the child is unchanged again: [$(dec 1767)]" ;; esac

# ═══ 4 — the no-DECISION retry, end to end through the worker ══════════════════
reset
iss 801 "stuck"; iss 802 "spent"; world
tick_env enforce
tick 4pre
H801=$(col5 801); H802=$(col5 802)
# 4a — the legacy row (the project-6 shape: bare reason, no stamp) is due
put_row 801 "$ND" "$H801"
put_row 802 "$ND (no-decision 3/3)" "$H802" "$(iso $((NOW-60)))"
tick 4a
[ "$(dec 801)" = "llm recheck-due" ] && ok || bad "(4a) a legacy no-DECISION row goes back to the model: [$(dec 801)]"
[ "$(dec 802)" = "llm recheck-due" ] && ok || bad "(4e) precondition: a 3/3 row past its stamp is due: [$(dec 802)]"
# 4b/4e — the model again returns no DECISION line for both
session 'tickets=2 triaged=0\n'
[ "$(row 801 reason)" = "$ND (no-decision 2/3)" ] && ok || bad "(4b) the legacy row counts as 1: the retry is 2/3: [$(row 801 reason)]"
[ "$(row 801 verdict)" = triaged ] && [ "$(row 801 verdict_hash)" = "$H801" ] && ok || bad "(4b) the row stays triaged on its hash: [$(row 801 verdict)/$(row 801 verdict_hash)]"
[ "$(row 801 next_recheck_at)" = "$(iso $((NOW+7200)))" ] && ok || bad "(4b) next_recheck_at = now + the backoff: [$(row 801 next_recheck_at)]"
[ "$(row 802 reason)" = "$ND (no-decision retries spent 3/3)" ] && ok || bad "(4e) at 3/3 the next one is spent: [$(row 802 reason)]"
[ "$(ndalerts)" = 1 ] && ok || bad "(4e) ONE ALERT line: $(cat "$H/logs/ALERTS.log")"
AL=$(grep 'no DECISION line' "$H/logs/ALERTS.log")
case "$AL" in *"$P:"*"4 times"*"TK-802"*) ok ;; *) bad "(4e) the ALERT names the project, the count and the key: [$AL]" ;; esac
case "$AL" in *TK-801*) bad "(4e) a key with retries left is not named: [$AL]" ;; *) ok ;; esac
# 4b — before the stamp: held; after it: back at the model
tick 4b1
[ "$(dec 801)" = "skip unchanged:triaged" ] && ok || bad "(4b) before the backoff ends the retry waits: [$(dec 801)]"
[ "$(dec 802)" = "skip unchanged:triaged" ] && ok || bad "(4e) a spent row is final: [$(dec 802)]"
NOW_T=$((NOW+7201)); tick 4b2
[ "$(dec 801)" = "llm recheck-due" ] && ok || bad "(4b) after the backoff the retry is due: [$(dec 801)]"
[ "$(dec 802)" = "skip unchanged:triaged" ] && ok || bad "(4e) a spent row stays final: [$(dec 802)]"
# 4e — a later record that sees the spent row again adds no ALERT line
session 'tickets=2 triaged=0\n'
[ "$(row 801 reason)" = "$ND (no-decision 3/3)" ] && ok || bad "(4b) the count moves to 3/3: [$(row 801 reason)]"
[ "$(ndalerts)" = 1 ] && ok || bad "(4e) no second ALERT line: $(cat "$H/logs/ALERTS.log")"
# 4e — a spent ticket whose thread moves goes to the model (the hash), and a
# third empty answer keeps it spent: no restart of the count, no second ALERT
iss 802 "spent, edited"; world; tick 4e2
[ "$(dec 802)" = "llm changed" ] && ok || bad "(4e) precondition: a moved spent ticket is changed: [$(dec 802)]"
session 'tickets=1 triaged=0\n'
[ "$(row 802 reason)" = "$ND (no-decision retries spent 3/3)" ] && ok || bad "(4e) a spent row stays spent: [$(row 802 reason)]"
[ "$(ndalerts)" = 1 ] && ok || bad "(4e) a spent key is named once: $(cat "$H/logs/ALERTS.log")"
# 4b — a real DECISION ends the retries
NOW_T=$((NOW+14402)); tick 4b3
session 'tickets=1\nDECISION: TK-801 :: comment :: asked for the repro steps\n'
[ "$(row 801 reason)" = "DECISION comment: asked for the repro steps" ] && ok || bad "(4b) a DECISION replaces the counter: [$(row 801 reason)]"
NOW_T=$NOW

# 4f — the knob off: the legacy row is final and record writes the old row
reset
iss 901 "off"; world
tick_env enforce
tick 4fpre
H901=$(col5 901)
put_row 901 "$ND" "$H901"
export TRIAGE_STATE_NO_DECISION_RETRIES=0
tick 4f
[ "$(dec 901)" = "skip unchanged:triaged" ] && ok || bad "(4f) retries 0: the legacy row is not due: [$(dec 901)]"
# force it into the model set (a moved thread) and return no DECISION line
iss 901 "off, edited"; world; tick 4f2
[ "$(dec 901)" = "llm changed" ] && ok || bad "(4f) precondition: a moved thread is changed: [$(dec 901)]"
session 'tickets=1 triaged=0\n'
[ "$(row 901 reason)" = "$ND" ] && ok || bad "(4f) retries 0 writes the old bare reason: [$(row 901 reason)]"
[ "$(ndalerts)" = 0 ] && ok || bad "(4f) retries 0 writes no ALERT: $(cat "$H/logs/ALERTS.log")"
unset TRIAGE_STATE_NO_DECISION_RETRIES
# K2 — the settings row reaches the shell (lib_env_apply through _ts_knobs)
KOUT=$( unset LANE_GATE_DISABLE HARNESS_SECRET JOBS_URL TRIAGE_STATE_NO_DECISION_RETRIES
        export LANE_GATE_NOW=$NOW
        printf '{"fetched_at":%s,"values":{"lib.triage-state.triage_state_no_decision_retries":"5"},"seeded":{}}' "$NOW" > "$H/state/settings-cache.json"
        _ts_knobs "$P"; printf 'n=%s' "$(ts_nd_retries)" ) 2>/dev/null
rm -f "$H/state/settings-cache.json"
[ "$KOUT" = "n=5" ] && ok || bad "(K2) ts_nd_retries reads the settings row: [$KOUT]"
[ "$(unset TRIAGE_STATE_NO_DECISION_RETRIES; ts_nd_retries)" = 3 ] && ok || bad "(K2) unset reads the fallback 3"
[ "$(TRIAGE_STATE_NO_DECISION_RETRIES=junk ts_nd_retries)" = 3 ] && ok || bad "(K2) junk reads the fallback 3"

echo "triage-state-no-decision: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
