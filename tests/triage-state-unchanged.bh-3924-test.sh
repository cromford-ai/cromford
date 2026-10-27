#!/bin/bash
# tests/triage-state-unchanged.bh-3924-test.sh — BH-3924 (BH-3921.1): read only
# moved rows, carry the over-cap reads to the next tick, no timer recheck.
#
#   U  a thread is read only when its board row moved (or nothing is cached):
#      a webhook or a due recheck no longer forces a read. Past the cap a key is
#      `skip deferred:cap` (a low budget: `skip deferred:budget`), never sent to
#      the model, listed in deferred.keys only under enforce, and drained by
#      ts-deferred ticks. The tick bracket carries `cap=N budget=N`.
#   G  bin/triage-gate.sh step 1d: `RUN ts-deferred` for a fresh, non-empty
#      deferred.keys under enforce with a read cap above 0, never otherwise
#   T  the one timer rule (bin/triage-state.py due_at / recheck_ttl / record):
#      at TTL 0 only a defer-like verdict naming no ref and the client-turn
#      nudge come back on a timer; TRIAGE_STATE_TTL_S > 0 is the old sweep
#   K  TRIAGE_STATE_TTL_S / TRIAGE_STATE_CLIENT_NUDGE_S: settings rows, env the
#      fallback (ts_ttl, ts_nudge)
#
# Everything real except the network edges: bin/lib/triage-state.sh,
# bin/triage-state.py, bin/triage-gate.sh (--thread and as the gate), and the
# REAL worker route on node:sqlite (the tests/triage-state-fetch-cap.bh-3920-test.sh
# scaffold). `gh` is a PATH stub serving fixture issues and logging every call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-unchanged.bh-3924-test.sh
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
NOW=$(date +%s)
NOW_T=$NOW
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
LIB="$DIR/bin/lib/triage-state.sh"
PY="$DIR/bin/triage-state.py"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-unchanged: SKIPPED the worker cases, this node has no node:sqlite"
  echo "triage-state-unchanged: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
# --write: the worker route imports catalog/lanes.json from the checkout
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
cp "$DIR/catalog/lanes.json" "$T/lanes.json"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"; P=project-5; SLUG=example-org/project-5
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/rt" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/builds" \
         "$H/catalog" "$T/gbin" "$T/fx/issues" "$T/fx/fail" "$T/calls"
for s in triage-gate.sh fleet-conf.sh triage-signal.py triage-state.py; do cp "$DIR/bin/$s" "$H/bin/$s"; done
for s in bin/triage-gate.sh bin/lib/triage-state.sh bin/lib/jobs/queue.sh bin/lib/rt/gate.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "$s could not be installed into the scratch harness"
done
cp "$T/lanes.json" "$H/catalog/lanes.json"
chmod +x "$H/bin/"*.sh
: > "$H/env/global.env"
echo "SOP. Keys are TK-<issue-number>." > "$H/prompts/$P.md"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls/run-build"\n' "$T" > "$H/bin/run-build.sh"
printf '#!/bin/bash\necho "LAUNCH $2"\n' > "$H/bin/overlap-guard.sh"
chmod +x "$H/bin/run-build.sh" "$H/bin/overlap-guard.sh"

# gh, as gh_rest calls it. $T/fx/fail/<n> makes that one issue answer 404.
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/gh"
case "\$*" in
  *rate_limit*) R=\$(cat "$T/fx/rl" 2>/dev/null || echo 4000)
    echo "{\"resources\":{\"core\":{\"remaining\":\$R,\"limit\":5000,\"reset\":0},\"graphql\":{\"remaining\":\$R,\"limit\":5000,\"reset\":0}}}"; exit 0 ;;
  *repos/$SLUG/pulls*) printf 'HTTP/2 200\r\n\r\n[]\n'; exit 0 ;;
esac
N=\$(printf '%s\n' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p' | head -1)
F="$T/fx/issues/\$N.json"
[ -n "\$N" ] && [ -s "\$F" ] && [ ! -e "$T/fx/fail/\$N" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
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
iss() { # iss <n> <title>
  jq -n --argjson n "$1" --arg t "$2" \
    '{issue:{number:$n,title:$t,body:"body",state:"open",labels:[{name:"ai-build"}],assignees:[],milestone:null,comments:0,
      updated_at:"2026-09-28T09:00:00Z"},comments:[]}' > "$T/fx/issues/$1.json"
}
comment() { # comment <n> <id> <body> <created_at>
  local f="$T/fx/issues/$1.json"
  jq --argjson id "$2" --arg b "$3" --arg at "$4" \
    '.comments += [{id:$id,user:{login:"client-carl",type:"User"},body:$b,created_at:$at,updated_at:$at}]
     | .issue.comments = (.comments|length) | .issue.updated_at = $at' "$f" > "$f.t" && mv "$f.t" "$f"
}
META='{}'
world() { # the gate's fingerprint, rebuilt from the fixtures; META is its meta map
  local rows
  rows=$(for f in "$T/fx/issues/"*.json; do jq -c '.issue | {number, state:(.state|ascii_upcase), title, comments, updatedAt: .updated_at}' "$f"; done | jq -sc 'sort_by(.number)')
  jq -cS -n --argjson i "$rows" --argjson m "$META" '{issues:$i, prs:[], meta:$m}' > "$H/state/$P.gate.pending"
}
tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$DIR/fleet.conf" \
         HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE="$1" GH_TOKEN=x \
         LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/lanes.json"
  PROJECT=$P; STAMP="2026-10-03 10:00:00Z"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
  GATE_DECISION="RUN ${2:-board-changed}"; GATE_REASON="${2:-board-changed}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; EW_KEYS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
LANE_TICK() { echo "LANE_TICK $*" >> "$T/calls/lane-tick"; }
rt_gate_consume() { echo consumed >> "$T/calls/consume"; }
# shellcheck source=/dev/null
. "$H/bin/lib/jobs/queue.sh"
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
_ts_now() { echo "$NOW_T"; }
SD="$H/state/triage-state/$P"
dec() { awk -F'\t' -v k="$1" '$1==k{print $3" "$4}' "$SD/decisions.tsv" 2>/dev/null; }
col5() { awk -F'\t' -v k="$1" '$1==k{print $5}' "$SD/decisions.tsv" 2>/dev/null; }
row() { sql "SELECT $2 FROM triage_state WHERE project='$P' AND ticket_key='$1'"; }
llm_set() { awk -F'\t' '$3=="llm"{print $1}' "$SD/decisions.tsv" 2>/dev/null | sort -n | tr '\n' ' '; }
reads() { grep -oE "repos/$SLUG/issues/[0-9]+\$" "$T/calls/gh" 2>/dev/null | sed 's#.*/##'; }
tick() { : > "$T/calls/gh"; ( ts_precheck >/dev/null 2>&1; printf '%s' "${TS_SUMMARY:-}" > "$T/sum.$1" ); reads | sort -n > "$T/reads.$1"; }
# reset: a fresh board, DB, state dir and lane log
reset() { rm -f "$T/fx/issues/"*.json "$T/fx/fail/"* "$DB"; scratch_rm "$SD"; : > "$H/logs/$P.log"; META='{}'; NOW_T=$NOW; }
move() { # move <meta-value> <n>... — those board rows move (their meta hash), nothing else
  local v="$1"; shift
  META=$(printf '%s\n' "$@" | jq -Rsc --argjson m "$META" --arg v "$v" 'split("\n") | map(select(length>0)) | reduce .[] as $k ($m; .[$k] = $v)')
  world
}
dkeys() { wc -l < "$SD/deferred.keys" 2>/dev/null | tr -d ' '; }
ndec() { awk -F'\t' -v d="$1" -v r="$2" '$3==d && $4==r' "$SD/decisions.tsv" 2>/dev/null | wc -l | tr -d ' '; }
setrow() { sql "UPDATE triage_state SET $2 WHERE project='$P' AND ticket_key='$1'" >/dev/null; }

# ═══ the fixture: 40 tickets, all read once and stamped `triaged` ══════════════
reset
for n in $(seq 401 440); do iss "$n" "ticket $n"; done
world
tick_env enforce
TRIAGE_STATE_MAX_FETCH=100 tick f0
[ "$(wc -l < "$T/reads.f0" | tr -d ' ')" = 40 ] && ok || bad "(U) precondition: the first tick reads all 40: [$(wc -l < "$T/reads.f0")]"
printf 'tickets=40 triaged=40\n' > "$T/out40.txt"
ts_after_session "$H" "$P" 0 "$T/out40.txt" >/dev/null 2>&1
[ "$(sql "SELECT COUNT(*) FROM triage_state WHERE project='$P' AND verdict='triaged' AND verdict_hash IS NOT NULL")" = 40 ] && ok \
  || bad "(U) precondition: the tickets= session stamps all 40 triaged"
export TRIAGE_STATE_MAX_FETCH=4

# U1 — a webhook names an unmoved key: hashed from the cache, no read
: > "$T/calls/gh"; ( EW_KEYS="#405"; ts_precheck ) >/dev/null 2>&1
[ "$(reads | wc -l | tr -d ' ')" = 0 ] && ok || bad "(U1) a webhook-named key whose row did not move makes no thread read: [$(reads | tr '\n' ' ')]"
[ "$(dec 405)" = "skip unchanged:triaged" ] && ok || bad "(U1) and it is decided from the cache: [$(dec 405)]"

# U2 — a due defer whose row did not move: recheck-due, still no read
setrow 406 "verdict='queued', reason='DECISION defer: waits on the harness fix', triaged_at='$(iso $((NOW-10800)))', next_recheck_at='$(iso $((NOW-3600)))'"
tick u2
[ "$(wc -l < "$T/reads.u2" | tr -d ' ')" = 0 ] && ok || bad "(U2) a due recheck with an unmoved row makes no thread read: [$(tr '\n' ' ' < "$T/reads.u2")]"
[ "$(dec 406)" = "llm recheck-due" ] && ok || bad "(U2) the due defer still goes to the model: [$(dec 406)]"
setrow 406 "verdict='triaged', reason='seeded', next_recheck_at=NULL"

# U3 — ten rows move at cap 4: four reads, six carried to the next tick
for n in $(seq 411 420); do cp -f "$SD/$n.entry" "$T/pre.$n.entry"; done
move 1 $(seq 411 420)
tick u3
[ "$(wc -l < "$T/reads.u3" | tr -d ' ')" = 4 ] && [ -z "$(awk '$1<411 || $1>420' "$T/reads.u3")" ] && ok \
  || bad "(U3) exactly 4 reads, all of moved rows: [$(tr '\n' ' ' < "$T/reads.u3")]"
[ "$(ndec skip deferred:cap)" = 6 ] && ok || bad "(U3) the 6 unread moved keys are 'skip deferred:cap': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
DEF6=$(awk -F'\t' '$3=="skip" && $4=="deferred:cap" {print $1}' "$SD/decisions.tsv" | sort -n | tr '\n' ' ')
NIN=0; NENT=0; NHEX=0
for n in $DEF6; do
  case " $(llm_set)" in *" $n "*) NIN=$((NIN+1)) ;; esac
  cmp -s "$SD/$n.entry" "$T/pre.$n.entry" && NENT=$((NENT+1))
  [[ "$(col5 "$n")" =~ ^[0-9a-f]{64}$ ]] && NHEX=$((NHEX+1))
done
[ "$NIN" = 0 ] && ok || bad "(U3) no deferred key is in the model set: [$(llm_set)]"
[ "$(dkeys)" = 6 ] && [ "$(sort -n "$SD/deferred.keys" | tr '\n' ' ')" = "$DEF6" ] && ok \
  || bad "(U3) deferred.keys names the 6: [$(tr '\n' ' ' < "$SD/deferred.keys" 2>/dev/null)] vs [$DEF6]"
! grep -qP '\tunhashable\t' "$SD/decisions.tsv" && ok || bad "(U3) nothing is unhashable"
[ "$NENT" = 6 ] && ok || bad "(U3) each deferred key keeps its pre-move .entry (still owed a read): [$NENT]"
[ "$NHEX" = 6 ] && ok || bad "(U3b) each deferred key carries its stale-raw 64-hex hash in column 5: [$NHEX]"
grep -q 'reads=4 cap=6 budget=0' "$T/sum.u3" 2>/dev/null && ok || bad "(U3) the summary carries reads=4 cap=6 budget=0: [$(cat "$T/sum.u3")]"
case "$(cat "$T/sum.u3")" in *"deferred="*) bad "(U3) the old deferred= bracket is gone: [$(cat "$T/sum.u3")]" ;; *) ok ;; esac
grep -q ' 34 unchanged' "$T/sum.u3" 2>/dev/null && ok || bad "(U3) the deferred keys are not counted unchanged (30 + 4 read): [$(cat "$T/sum.u3")]"

# U4 — the 30 unmoved keys: no read among them, each unchanged
NU=0
for n in $(seq 401 410) $(seq 421 440); do
  grep -qx "$n" "$T/reads.u3" && bad "(U4) unmoved key $n was read"
  [ "$(dec "$n")" = "skip unchanged:triaged" ] && NU=$((NU+1))
done
[ "$NU" = 30 ] && ok || bad "(U4) the 30 unmoved keys are 'skip unchanged:triaged': [$NU]"

# U5 — two ts-deferred ticks drain the six, and end at \$0
tick_env enforce ts-deferred
: > "$T/calls/gh"; : > "$H/logs/$P.log"; ( ts_tick ) >/dev/null 2>&1; reads | sort -n > "$T/reads.u5a"
[ "$(wc -l < "$T/reads.u5a" | tr -d ' ')" = 4 ] && [ -z "$(comm -23 "$T/reads.u5a" <(tr ' ' '\n' <<<"$DEF6" | grep . | sort -n))" ] && ok \
  || bad "(U5) the first ts-deferred tick reads 4 of the deferred keys: [$(tr '\n' ' ' < "$T/reads.u5a")]"
[ "$(dkeys)" = 2 ] && ok || bad "(U5) two are still owed: [$(dkeys)]"
: > "$T/calls/gh"; : > "$H/logs/$P.log"; ( ts_tick ) >/dev/null 2>&1; reads | sort -n > "$T/reads.u5b"
[ "$(wc -l < "$T/reads.u5b" | tr -d ' ')" = 2 ] && ok || bad "(U5) the second reads the last 2: [$(tr '\n' ' ' < "$T/reads.u5b")]"
[ -e "$SD/deferred.keys" ] && [ "$(dkeys)" = 0 ] && ok || bad "(U5) deferred.keys is empty after the drain: [$(cat "$SD/deferred.keys" 2>/dev/null)]"
grep 'rc=skip' "$H/logs/$P.log" | tail -1 | grep -q 'triage-state: 0 changed' && ok \
  || bad "(U5) unchanged threads end the ts-deferred tick at \$0: [$(tail -2 "$H/logs/$P.log")]"
# U5b — that \$0 end, through the real rt_gate_consume, absorbs the fingerprint
# and never stamps the daily sweep's clock (a full-scope consume would)
move 5 421 422
echo 1000 > "$H/state/$P.gate-meta"
: > "$H/logs/$P.log"
( unset -f rt_gate_consume; . "$H/bin/lib/rt/gate.sh"; _rt_tgl() { return 1; }
  TRIAGE_STATE_MAX_FETCH=100; ts_tick ) >/dev/null 2>&1
grep 'rc=skip' "$H/logs/$P.log" | tail -1 | grep -q 'gate=ts-deferred' && ok \
  || bad "(U5b) precondition: the ts-deferred tick ended at \$0: [$(tail -2 "$H/logs/$P.log")]"
[ "$(cat "$H/state/$P.gate-meta")" = 1000 ] && ok || bad "(U5b) a \$0 ts-deferred end leaves gate-meta untouched: [$(cat "$H/state/$P.gate-meta")]"
[ ! -e "$H/state/$P.gate.pending" ] && [ -s "$H/state/$P.gate.json" ] && ok || bad "(U5b) and it still absorbs the pending fingerprint"
( unset -f rt_gate_consume; . "$H/bin/lib/rt/gate.sh"; _rt_tgl() { return 1; }; SCOPE_N=full; rt_gate_consume )
[ "$(cat "$H/state/$P.gate-meta")" != 1000 ] && ok || bad "(U5b) control: a full-scope consume does stamp gate-meta"
rm -f "$H/state/$P.gate-meta"; world
tick_env enforce

# U6 — a low GitHub budget: nothing read, every owed key is deferred:budget
move 2 431 432 433
: > "$T/calls/gh"; ( _ts_gh_budget_low() { return 0; }; ts_precheck; printf '%s' "${TS_SUMMARY:-}" > "$T/sum.u6" ) >/dev/null 2>&1
[ "$(reads | wc -l | tr -d ' ')" = 0 ] && ok || bad "(U6) a low budget reads no thread: [$(reads | tr '\n' ' ')]"
[ "$(ndec skip deferred:budget)" = 3 ] && ok || bad "(U6) the 3 moved keys are 'skip deferred:budget': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
grep -q 'cap=0 budget=3' "$T/sum.u6" 2>/dev/null && ok || bad "(U6) the summary carries budget=3: [$(cat "$T/sum.u6")]"

# U7 — shadow: the decisions are the same, but no owed-read list is left behind
tick_env shadow
: > "$T/calls/gh"; : > "$H/logs/$P.log"; ( TRIAGE_STATE_MAX_FETCH=1; ts_precheck ) >/dev/null 2>&1
[ "$(ndec skip deferred:cap)" = 2 ] && ok || bad "(U7) shadow still decides 'skip deferred:cap': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
[ -e "$SD/deferred.keys" ] && [ ! -s "$SD/deferred.keys" ] && ok || bad "(U7) shadow leaves deferred.keys empty: [$(cat "$SD/deferred.keys" 2>/dev/null)]"
[ ! -e "$SD/deferred.tick" ] && ok || bad "(U7) and no deferred.tick"
grep -q 'cap=2 budget=0' "$H/logs/$P.log" && ok || bad "(U7) the shadow line carries cap=2: [$(grep triage-state "$H/logs/$P.log" | tail -1)]"
tick_env enforce
TRIAGE_STATE_MAX_FETCH=100 tick drain
[ "$(dkeys)" = 0 ] && ok || bad "(U7) precondition: the owed reads drained: [$(dkeys)]"

# U3c — a webhook-named key is read first INSIDE the read set (tier 0)
move 3 $(seq 411 420)
for n in $(seq 411 420); do touch -d "@$((NOW-5000))" "$SD/$n.tried"; done
touch -d "@$NOW" "$SD/420.tried"
: > "$T/calls/gh"; ( EW_KEYS="#420"; ts_precheck ) >/dev/null 2>&1
reads | grep -qx 420 && [ "$(reads | wc -l | tr -d ' ')" = 4 ] && ok \
  || bad "(U3c) the webhook-named moved key is among the 4 read: [$(reads | tr '\n' ' ')]"
TRIAGE_STATE_MAX_FETCH=100 tick drain2

# ═══ T — the one timer rule ═══════════════════════════════════════════════════
# T1 — a 3-day-old triaged row with a stale next_recheck_at is never due at TTL 0
# TEST-CHANGE (BH-8497): the U-section's tickets= stamp is a no-DECISION retry
# now (due at its stamp), so T1 gives 401 a real DECISION reason: the premise is
# a final triaged verdict with a stale stamp. The reason names no ref, so the
# hash does not move.
setrow 401 "triaged_at='$(iso $((NOW-259200)))', next_recheck_at='$(iso $((NOW-172800)))', reason='DECISION skip: nothing to do'"
tick t1
[ "$(dec 401)" = "skip unchanged:triaged" ] && ok || bad "(T1) a stale stamp is not a recheck at the default TTL: [$(dec 401)]"
triage_state_list "$P" > "$T/rows.t1" 2>/dev/null
DUE=$(python3 "$PY" due --rows "$T/rows.t1" --now "$NOW" --ttl 0 --defer-ttl 7200 --gh 1 2>&1)
case " $(tr '\n' ' ' <<<"$DUE")" in *" 401 "*) bad "(T1) due --ttl 0 names the 3-day-old triaged row: [$DUE]" ;; *) ok ;; esac
[ -z "$DUE" ] && ok || bad "(T1) due --ttl 0 prints nothing for this board: [$DUE]"
# T4 — TRIAGE_STATE_TTL_S=86400 restores the per-ticket sweep
TRIAGE_STATE_TTL_S=86400 tick t4
[ "$(dec 401)" = "llm recheck-due" ] && ok || bad "(T4) at TTL 86400 the same row is recheck-due: [$(dec 401)]"
setrow 401 "triaged_at='$(iso "$NOW")', next_recheck_at=NULL"

# T2 / T2b — a defer naming no ref is due; one naming a ref is the hash's
TR="$T/rows.t2"
jq -n --arg ta "$(iso $((NOW-10800)))" --arg nx "$(iso $((NOW-3600)))" '[
  {ticket_key:"901", ticket_label:"TK-901", verdict:"queued", triaged_at:$ta, reason:"DECISION defer: waits on the harness fix"},
  {ticket_key:"902", ticket_label:"TK-902", verdict:"queued", triaged_at:$ta, next_recheck_at:$nx, reason:"DECISION defer: waits on #999"}]' > "$TR"
DUE=$(python3 "$PY" due --rows "$TR" --now "$NOW" --ttl 0 --defer-ttl 7200 --prefix TS --gh 1 2>&1 | tr '\n' ' ')
[ "$DUE" = "901 " ] && ok || bad "(T2/T2b) at TTL 0 the no-ref defer is due and the #999 defer is not: [$DUE]"

# T3 — the client nudge
jq -n --arg old "$(iso $((NOW-1296000)))" --arg new "$(iso $((NOW-86400)))" '[
  {ticket_key:"911", verdict:"needs_clarification", waiting_on:"client", triaged_at:$old, reason:"DECISION comment: asked the client"},
  {ticket_key:"912", verdict:"needs_clarification", waiting_on:"client", triaged_at:$new, reason:"DECISION comment: asked the client"},
  {ticket_key:"913", verdict:"triaged", waiting_on:"client", triaged_at:$old, reason:"seeded"},
  {ticket_key:"914", verdict:"waiting_client", waiting_on:"client", triaged_at:$old, reason:"seeded"}]' > "$T/rows.t3"
DUE=$(python3 "$PY" due --rows "$T/rows.t3" --now "$NOW" --ttl 0 --defer-ttl 7200 --nudge 1209600 --gh 1 2>&1 | tr '\n' ' ')
[ "$DUE" = "911 913 914 " ] && ok || bad "(T3) --nudge 1209600: 15-day-old client turns are due, a 1-day-old is not: [$DUE]"
DUE=$(python3 "$PY" due --rows "$T/rows.t3" --now "$NOW" --ttl 0 --defer-ttl 7200 --nudge 0 --gh 1 2>&1)
[ -z "$DUE" ] && ok || bad "(T3) --nudge 0 is off: [$DUE]"
setrow 402 "verdict='needs_clarification', waiting_on='client', reason='DECISION comment: asked the client', triaged_at='$(iso $((NOW-1296000)))', next_recheck_at=NULL"
tick t3a
[ "$(dec 402)" = "llm recheck-due" ] && ok || bad "(T3) through ts_precheck, a 15-day-old client turn is nudged: [$(dec 402)]"
setrow 402 "triaged_at='$(iso $((NOW-86400)))'"
tick t3b
[ "$(dec 402)" = "skip unchanged:needs_clarification" ] && ok || bad "(T3) a 1-day-old client turn is not: [$(dec 402)]"

# T5 — record at TTL 0 never stamps now + 0
HX=$(printf 'b%.0s' $(seq 64))
printf '501\tTS-501\tllm\tnew\t%s\t-\t1\t-\t0\n502\tTS-502\tllm\tnew\t%s\t-\t1\t-\t0\n503\tTS-503\tllm\tnew\t%s\t-\t1\t-\t0\n' "$HX" "$HX" "$HX" > "$T/dec.t5"
printf 'tickets=3\nDECISION: TK-501 :: skip :: nothing to do\nDECISION: TK-502 :: defer :: waits on the harness fix\nDECISION: TK-503 :: comment :: asked the client for the export columns\n' > "$T/out.t5"
python3 "$PY" record --project "$P" --out "$T/out.t5" --rc 0 --now "$NOW" --ttl 0 --defer-ttl 7200 --nudge 1209600 \
  --decisions "$T/dec.t5" --prefix TS --gh 1 > "$T/rec.t5" 2>&1
rk() { jq -r --arg k "$1" ".rows[] | select(.ticket_key==\$k) | $2" "$T/rec.t5" 2>/dev/null; }
[ "$(rk 501 .verdict)" = triaged ] && [ "$(rk 501 'has("next_recheck_at")')" = false ] && ok \
  || bad "(T5) a skip DECISION at TTL 0 is triaged with NO next_recheck_at: [$(rk 501 -c .)] $(head -c 300 "$T/rec.t5")"
[ "$(rk 502 .verdict)" = queued ] && [ "$(rk 502 .next_recheck_at)" = "$(iso $((NOW+7200)))" ] && ok \
  || bad "(T5) a defer at TTL 0 rechecks at now + defer TTL: [$(rk 502 -c .)]"
[ "$(rk 503 .verdict)" = needs_clarification ] && [ "$(rk 503 .next_recheck_at)" = "$(iso $((NOW+1209600)))" ] && ok \
  || bad "(T5b) a client turn at TTL 0 rechecks at now + nudge: [$(rk 503 -c .)]"
printf '601\tTS-601\t-\t-\t0\t-\t-\t-\n' > "$T/hash.t5"
printf '[{"ticket_key":"601","verdict":"triaged","verdict_hash":"%s","input_hash":"%s"}]' "$HX" "$HX" > "$T/rows.t5"
CL=$(python3 "$PY" decide --hashes "$T/hash.t5" --rows "$T/rows.t5" --now "$NOW" --ttl 0 --defer-ttl 7200 --gh 1 2>&1)
[ "$(cut -f3,4 <<<"$CL")" = "stamp	closed-on-board" ] && [ "$(cut -f6 <<<"$CL" | jq -r 'has("next_recheck_at")' 2>/dev/null)" = false ] && ok \
  || bad "(T5) the closed seed at TTL 0 carries no next_recheck_at: [$CL]"

# ═══ G — bin/triage-gate.sh step 1d ═══════════════════════════════════════════
jq -cn '{issues:[], prs:[], meta:{}}' > "$H/state/$P.gate.json"
rm -f "$H/state/wake-$P" "$H/flags/force-triage-$P"; scratch_rm "$H/state/remote-results"
gate() { # gate <mode> <max-fetch> — the gate's answer line
  ( unset FORCE_TRIAGE EW_KEYS
    HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH="$2" \
      LANE_GATE_DISABLE=1 timeout 60 bash "$H/bin/triage-gate.sh" "$P" 2>/dev/null </dev/null | head -1 )
}
# G1 — a fresh, non-empty deferred.keys under enforce at cap > 0 fires step 1d
printf '411\n412\n' > "$SD/deferred.keys"
G1=$(gate enforce 4)
[ "$G1" = "RUN ts-deferred" ] && ok || bad "(G1) a fresh, non-empty deferred.keys under enforce: [$G1]"
# G2 — a file older than a day, or an empty file, never fires
touch -d "@$((NOW-90000))" "$SD/deferred.keys"
G2=$(gate enforce 4)
[ "$G2" != "RUN ts-deferred" ] && ok || bad "(G2) a deferred.keys older than a day never fires: [$G2]"
: > "$SD/deferred.keys"
G2=$(gate enforce 4)
[ "$G2" != "RUN ts-deferred" ] && ok || bad "(G2) an empty deferred.keys never fires: [$G2]"
# G3 — a read cap of 0 never fires (and G4: nor does a non-enforce mode)
printf '411\n' > "$SD/deferred.keys"
G3=$(gate enforce 0)
[ "$G3" != "RUN ts-deferred" ] && ok || bad "(G3) a read cap of 0 never fires: [$G3]"
G4=$(gate shadow 4)
[ "$G4" != "RUN ts-deferred" ] && ok || bad "(G4) a non-enforce mode never fires: [$G4]"
G1=$(gate enforce 4)
[ "$G1" = "RUN ts-deferred" ] && ok || bad "(G1) the same file under enforce fires again: [$G1]"
# G5 — a low GitHub budget never fires (no tick could drain the list), and the
# same file fires again once the budget recovers
echo 10 > "$T/fx/rl"; scratch_rm "$H/state/gh-budget"
G5=$(gate enforce 4)
[ "$G5" != "RUN ts-deferred" ] && ok || bad "(G5) a low GitHub budget never fires: [$G5]"
[ -s "$SD/deferred.keys" ] && ok || bad "(G5) and the owed-read list is kept"
rm -f "$T/fx/rl"; scratch_rm "$H/state/gh-budget"
G5=$(gate enforce 4)
[ "$G5" = "RUN ts-deferred" ] && ok || bad "(G5) the recovered budget fires it again: [$G5]"
rm -f "$SD/deferred.keys"

# ═══ K — the TTL and the nudge are settings rows, env the fallback ════════════
# K1 — the settings-cache rows resolve ts_ttl / ts_nudge
printf '{"fetched_at":%s,"values":{"lib.triage-state.triage_state_ttl_s":"900","lib.triage-state.triage_state_client_nudge_s":"0"},"seeded":{}}' \
  "$NOW" > "$H/state/settings-cache.json"
KOUT=$( unset LANE_GATE_DISABLE HARNESS_SECRET JOBS_URL TRIAGE_STATE_TTL_S TRIAGE_STATE_CLIENT_NUDGE_S
        export LANE_GATE_NOW=$NOW
        _ts_knobs "$P"; echo "ttl=$(ts_ttl) nudge=$(ts_nudge)" ) 2>/dev/null
[ "$KOUT" = "ttl=900 nudge=0" ] && ok || bad "(K1) the settings rows resolve ts_ttl / ts_nudge: [$KOUT]"
rm -f "$H/state/settings-cache.json"
# K2 — the env fallback: ttl junk/unset/0 -> 0, 300 -> 600; nudge 0 -> off
k2() { ( unset TRIAGE_STATE_TTL_S TRIAGE_STATE_CLIENT_NUDGE_S; [ "$2" = unset ] || export "$1=$2"; "$3" 2>/dev/null ); }
KT="$(k2 TRIAGE_STATE_TTL_S junk ts_ttl) $(k2 TRIAGE_STATE_TTL_S unset ts_ttl) $(k2 TRIAGE_STATE_TTL_S 0 ts_ttl) $(k2 TRIAGE_STATE_TTL_S 300 ts_ttl) $(k2 TRIAGE_STATE_TTL_S 86400 ts_ttl)"
[ "$KT" = "0 0 0 600 86400" ] && ok || bad "(K2) ts_ttl junk/unset/0/300/86400 -> 0 0 0 600 86400: [$KT]"
KN="$(k2 TRIAGE_STATE_CLIENT_NUDGE_S 0 ts_nudge) $(k2 TRIAGE_STATE_CLIENT_NUDGE_S 00 ts_nudge) $(k2 TRIAGE_STATE_CLIENT_NUDGE_S unset ts_nudge) $(k2 TRIAGE_STATE_CLIENT_NUDGE_S 60 ts_nudge) $(k2 TRIAGE_STATE_CLIENT_NUDGE_S junk ts_nudge)"
[ "$KN" = "0 0 1209600 3600 1209600" ] && ok || bad "(K2) ts_nudge 0/00/unset/60/junk -> 0 0 1209600 3600 1209600: [$KN]"

echo "triage-state-unchanged: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
