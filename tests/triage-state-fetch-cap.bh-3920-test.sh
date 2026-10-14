#!/bin/bash
# tests/triage-state-fetch-cap.bh-3920-test.sh — BH-3920: the triage-state
# fetch cap starved the tail into `unhashable`, the model set never shrank, and
# the call-guard deadlocked triage (project-4, 2026-10-03: 84 open keys, cap 30).
#
#   F  the thread reads ROTATE (never-read first, then least recently tried;
#      a webhook-named key before all of them), a key past the cap keeps its
#      cached thread and entry stamp, and is `skip deferred:cap` (BH-3921;
#      it was `fetch-deferred` / `*:stale-raw`), never `unhashable`
#   H  an rc-0 session that returns no DECISION line and no summary for a key it
#      was handed writes a `handed-no-decision <marker>` reason and a backoff on
#      the row (never a verdict), and the next tick holds that key off the
#      model until its inputs move or the backoff ends
#   A  the call-guard's third refusal writes ONE triage-stuck:<p> alert naming
#      the model-set keys and why they are stuck
#   K  the backoff and the read cap are settings rows, env the fallback
#
# Everything real except the network edges: bin/lib/triage-state.sh,
# bin/triage-state.py, bin/triage-gate.sh --thread, bin/lib/rt/gate.sh, and
# the REAL worker route on node:sqlite (the tests/triage-state-precheck-test.sh
# scaffold). `gh` is a PATH stub serving fixture issues.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/triage-state-fetch-cap.bh-3920-test.sh
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

# ═══ P1 — a PR shard never gets a handed-no-decision row (no node needed) ═════
: > "$T/empty.txt"
P1OUT=$(python3 "$PY" record --project p --key pr-5 --hash 0123456789abcdef --out "$T/empty.txt" --rc 0 \
          --now "$NOW" --ttl 86400 --hnd-backoff 7200 2>&1)
case "$P1OUT" in *'"rows":[]'*) ok ;; *) bad "(P1) a pr-* shard with no DECISION must write no row: [$P1OUT]" ;; esac

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-fetch-cap: SKIPPED the worker cases, this node has no node:sqlite"
  echo "triage-state-fetch-cap: $PASS passed, $FAIL failed"
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
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/rt/gate.sh" "$H/bin/lib/rt/gate.sh"
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
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
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
seed_rows() { # seed_rows <first> <last> — triaged, a stale verdict_hash, recheck due an hour ago
  local n
  { printf '{"project":"%s","rows":[' "$P"
    for n in $(seq "$1" "$2"); do
      [ "$n" = "$1" ] || printf ','
      printf '{"ticket_key":"%s","ticket_label":"TK-%s","verdict":"triaged","waiting_on":"none","verdict_hash":"%s","input_hash":"%s","triaged_at":"%s","next_recheck_at":"%s","reason":"seeded"}' \
        "$n" "$n" "$(printf 'a%.0s' $(seq 64))" "$(printf 'a%.0s' $(seq 64))" "$(iso $((NOW-90000)))" "$(iso $((NOW-3600)))"
    done
    printf ']}'; } > "$T/seed.json"
  triage_state_put "$T/seed.json" >/dev/null 2>&1
}

# ═══ F — rotation and deferral: 84 keys, every one due, cap 30 ═════════════════
reset
for n in $(seq 101 184); do iss "$n" "ticket $n"; done
world
tick_env enforce
seed_rows 101 184
[ "$(row 150 verdict)" = triaged ] && ok || bad "(F) precondition: the rows are seeded: [$(row 150 verdict)]"
export TRIAGE_STATE_MAX_FETCH=30
tick 1
# F3 — nothing past the cap is unhashable, its entry is not dropped, it is deferred
! grep -qP '\tunhashable\t' "$SD/decisions.tsv" && ok || bad "(F3) a key past the cap must never be 'unhashable': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
# TEST-CHANGE (BH-3921): past the cap a key is carried to the next tick as
# `skip deferred:cap`, never sent to the model as `llm fetch-deferred`.
[ "$(awk -F'\t' '$3=="skip" && $4=="deferred:cap"' "$SD/decisions.tsv" | wc -l | tr -d ' ')" = 54 ] && ok \
  || bad "(F3) the 54 unread keys with no cached thread are 'skip deferred:cap': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
[ "$(wc -l < "$SD/deferred.keys" 2>/dev/null | tr -d ' ')" = 54 ] && ok || bad "(F3) deferred.keys names the 54: [$(wc -l < "$SD/deferred.keys" 2>/dev/null)]"
# TEST-CHANGE (BH-3921): the bracket's deferred=N is split into cap=N budget=N.
grep -q 'reads=30 cap=54 budget=0' "$T/sum.1" 2>/dev/null && ok || bad "(F3) the summary carries reads=30 cap=54 budget=0: [$(cat "$T/sum.1")]"
tick 2
tick 3
# TEST-CHANGE (BH-3921): a due row no longer forces a read, so a key read on
# tick 1 or 2 is not read again on tick 3: only the 24 never-read keys remain.
[ "$(wc -l < "$T/reads.1" | tr -d ' ') $(wc -l < "$T/reads.2" | tr -d ' ') $(wc -l < "$T/reads.3" | tr -d ' ')" = "30 30 24" ] && ok \
  || bad "(F1) ticks 1-2 read the cap, tick 3 the 24 still owed: [$(wc -l < "$T/reads.1") $(wc -l < "$T/reads.2") $(wc -l < "$T/reads.3")]"
[ "$(sort -un "$T/reads.1" "$T/reads.2" "$T/reads.3" | wc -l | tr -d ' ')" = 84 ] && ok \
  || bad "(F1) three ticks at cap 30 read all 84 threads, read $(sort -un "$T/reads.1" "$T/reads.2" "$T/reads.3" | wc -l)"
[ "$(comm -12 "$T/reads.1" "$T/reads.2" | wc -l | tr -d ' ')" = 0 ] && ok || bad "(F2) tick 2 must read no key tick 1 read: $(comm -12 "$T/reads.1" "$T/reads.2" | tr '\n' ' ')"
[ "$(comm -12 <(seq 161 184) "$T/reads.3" | wc -l | tr -d ' ')" = 24 ] && ok || bad "(F1) tick 3 reads the last 24 never-read keys: $(tr '\n' ' ' < "$T/reads.3")"
[ "$(ls "$SD"/*.tried 2>/dev/null | wc -l | tr -d ' ')" = 84 ] && ok || bad "(F1) every key has a .tried stamp after 3 ticks: [$(ls "$SD"/*.tried 2>/dev/null | wc -l)]"

# F4 — the stale-raw tick: read all 84, stamp them, move every board entry
TRIAGE_STATE_MAX_FETCH=100 tick 4
printf 'tickets=84 triaged=84\n' > "$T/out84.txt"
ts_after_session "$H" "$P" 0 "$T/out84.txt" >/dev/null 2>&1
[ "$(sql "SELECT COUNT(*) FROM triage_state WHERE project='$P' AND verdict_hash <> '$(printf 'a%.0s' $(seq 64))'")" = 84 ] && ok \
  || bad "(F4) precondition: the tickets= session stamps all 84"
META=$(seq 101 184 | jq -Rsc 'split("\n") | map(select(length>0)) | map({(.): 1}) | add')
world
tick 5
[ "$(wc -l < "$T/reads.5" | tr -d ' ')" = 30 ] && ok || bad "(F4) 30 threads are re-read: [$(wc -l < "$T/reads.5")]"
NSKIP=0; NSTALE=0; NHASH=0
while read -r n; do [ "$(dec "$n")" = "skip unchanged:triaged" ] && NSKIP=$((NSKIP+1)); done < "$T/reads.5"
for n in $(seq 101 184); do
  grep -qx "$n" "$T/reads.5" && continue
  # TEST-CHANGE (BH-3921): `llm fetch-deferred:stale-raw` became `skip deferred:cap`.
  [ "$(dec "$n")" = "skip deferred:cap" ] && NSTALE=$((NSTALE+1))
  [[ "$(col5 "$n")" =~ ^[0-9a-f]{64}$ ]] && NHASH=$((NHASH+1))
done
[ "$NSKIP" = 30 ] && ok || bad "(F4) the 30 re-read keys with an unchanged thread are 'skip unchanged:triaged': [$NSKIP]"
[ "$NSTALE" = 54 ] && ok || bad "(F4) the 54 unread keys are 'skip deferred:cap', never unchanged or the model's: [$NSTALE] $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"
[ "$NHASH" = 54 ] && ok || bad "(F4) a deferred key carries its stale 64-hex hash: [$NHASH]"
[ "$(ls "$SD"/*.entry 2>/dev/null | wc -l | tr -d ' ')" = 84 ] && ok || bad "(F4) all 84 .entry files survive: [$(ls "$SD"/*.entry 2>/dev/null | wc -l)]"
! grep -qP '\tunhashable\t' "$SD/decisions.tsv" && ok || bad "(F4) no unhashable"

# F5 — a low GitHub budget: no reads, everything needing one is deferred
META=$(seq 101 184 | jq -Rsc 'split("\n") | map(select(length>0)) | map({(.): 2}) | add')
world
: > "$T/calls/gh"
( _ts_gh_budget_low() { return 0; }; ts_precheck ) >/dev/null 2>&1
[ "$(reads | wc -l | tr -d ' ')" = 0 ] && ok || bad "(F5) a low budget reads no thread: [$(reads | tr '\n' ' ')]"
# TEST-CHANGE (BH-3921): a low budget defers every needing key as `skip deferred:budget`.
[ "$(awk -F'\t' '$3=="skip" && $4=="deferred:budget"' "$SD/decisions.tsv" | wc -l | tr -d ' ')" = 84 ] && ok \
  || bad "(F5) every needing key is 'skip deferred:budget': $(cut -f3,4 "$SD/decisions.tsv" | sort | uniq -c | tr '\n' ' ')"

# F6 — a webhook-named key is read first even at cap 1
TRIAGE_STATE_MAX_FETCH=1; : > "$T/calls/gh"
( EW_KEYS="#184"; ts_precheck ) >/dev/null 2>&1
[ "$(reads | tr '\n' ' ')" = "184 " ] && ok || bad "(F6) the webhook-named key is the one read at cap 1: [$(reads | tr '\n' ' ')]"

# F7 — a failed read is unhashable that tick and rotates to the back
for f in "$SD"/*.tried; do touch -d "@$((NOW-1000))" "$f"; done
touch "$T/fx/fail/101"; : > "$T/calls/gh"
( ts_precheck ) >/dev/null 2>&1
[ "$(reads | tr '\n' ' ')" = "101 " ] && [ "$(dec 101)" = "llm unhashable" ] && ok \
  || bad "(F7) precondition: the LRU key 101 is read, fails, and is unhashable: [$(reads | tr '\n' ' ')] [$(dec 101)]"
[ -e "$SD/101.tried" ] && [ ! -e "$SD/101.raw" ] && ok || bad "(F7) a failed read keeps a .tried stamp and drops its raw"
: > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
[ -n "$(reads)" ] && [ "$(reads | tr '\n' ' ')" != "101 " ] && ok || bad "(F7) the next tick reads a different key: [$(reads | tr '\n' ' ')]"
rm -f "$T/fx/fail/101"
unset TRIAGE_STATE_MAX_FETCH

# ═══ H — handed-no-decision, with a backoff ════════════════════════════════════
reset
iss 201 "first"; iss 202 "second"; iss 203 "third"; world
tick_env enforce
tick h1
[ "$(llm_set)" = "201 202 203 " ] && ok || bad "(H1) precondition: three new keys in the model set: [$(llm_set)]"
H201=$(col5 201)
printf 'the session printed nothing useful\n' > "$T/out-empty.txt"
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
for k in 201 202 203; do
  case "$(row "$k" reason)" in "handed-no-decision "*) ;; *) bad "(H1) $k's reason starts handed-no-decision: [$(row "$k" reason)]"; continue ;; esac
  [[ "$(row "$k" reason)" =~ ^handed-no-decision\ [0-9a-f]{64}: ]] && ok || bad "(H1) the marker is a 64-hex input hash: [$(row "$k" reason)]"
done
[ "$(row 201 next_recheck_at)" = "$(iso $((NOW+7200)))" ] && ok || bad "(H1) next_recheck_at is now + 7200: [$(row 201 next_recheck_at)]"
[ -z "$(row 201 verdict)" ] && [ -z "$(row 201 verdict_hash)" ] && ok || bad "(H1) no verdict is claimed: [$(row 201 verdict)/$(row 201 verdict_hash)]"
case "$(row 201 reason)" in "handed-no-decision $H201:"*) ok ;; *) bad "(H1) the marker is the hash the next tick computes: [$(row 201 reason)] vs $H201" ;; esac
grep -q 'triage-state: handed-no-decision 3:' "$H/logs/$P.log" && ok || bad "(H1) the lane log names the hand-off: $(grep triage-state "$H/logs/$P.log" | tail -2)"
[ "$(cut -f2 "$SD/hnd.last" 2>/dev/null)" = 3 ] && ok || bad "(H1) hnd.last records 3 keys: [$(cat "$SD/hnd.last" 2>/dev/null)]"

# H2 — the next tick holds all three, and an enforce tick ends at $0
tick h2
[ "$(dec 201)|$(dec 202)|$(dec 203)" = "skip handed-no-decision|skip handed-no-decision|skip handed-no-decision" ] && ok \
  || bad "(H2) the handed keys are held: [$(dec 201)|$(dec 202)|$(dec 203)]"
[ -z "$(llm_set)" ] && ok || bad "(H2) the model set is empty: [$(llm_set)]"
: > "$H/logs/$P.log"
H2OUT=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$H2OUT" in *CONTINUED*) bad "(H2) an enforce tick with only held keys must end at \$0" ;; *) ok ;; esac
grep -q 'rc=skip :: triage-state: 0 changed' "$H/logs/$P.log" && ok || bad "(H2) the log says 0 changed: $(tail -2 "$H/logs/$P.log")"

# H3 — a new client comment re-offers that key only
comment 202 2201 "here is the answer" 2026-10-01T08:00:00Z; world
tick h3
case "$(dec 202)" in "llm changed"|"llm new") ok ;; *) bad "(H3) a moved key goes straight back to the model: [$(dec 202)]" ;; esac
[ "$(dec 201)|$(dec 203)" = "skip handed-no-decision|skip handed-no-decision" ] && ok || bad "(H3) the others stay held: [$(dec 201)|$(dec 203)]"

# H4 — after the backoff the held keys are back
NOW_T=$((NOW+7201)); tick h4
case "$(llm_set)" in *"201 "*"203 "*) ok ;; *) bad "(H4) past the backoff the held keys are in the model set: [$(llm_set)]" ;; esac
NOW_T=$NOW

# H7 — a tickets= summary still blanket-stamps triaged, and writes no hnd row
reset
iss 301 "a"; iss 302 "b"; iss 303 "c"; world
tick_env enforce; tick h7
printf 'tickets=3 triaged=0\n' > "$T/out-t3.txt"
ts_after_session "$H" "$P" 0 "$T/out-t3.txt" >/dev/null 2>&1
[ "$(row 301 verdict)" = triaged ] && ok || bad "(H7) tickets= blanket-stamps triaged: [$(row 301 verdict)]"
case "$(row 301 reason)" in handed-no-decision*) bad "(H7) a tickets= session writes no hnd row: [$(row 301 reason)]" ;; *) ok ;; esac

# H5 — a stale `queued` defer: the verdict stands, the defer clamp is skipped
reset
iss 401 "deferred"; world
tick_env enforce; tick h5a
H401=$(col5 401)
printf '{"project":"%s","rows":[{"ticket_key":"401","ticket_label":"TK-401","verdict":"queued","waiting_on":"team","verdict_hash":"%s","input_hash":"%s","triaged_at":"%s","next_recheck_at":"%s","reason":"DECISION defer: waits on the harness fix"}]}' \
  "$P" "$H401" "$H401" "$(iso $((NOW-9000)))" "$(iso $((NOW+70000)))" > "$T/q.json"
triage_state_put "$T/q.json" >/dev/null 2>&1
tick h5b
[ "$(dec 401)" = "llm recheck-due" ] && ok || bad "(H5) precondition: a queued row past the defer TTL is due: [$(dec 401)]"
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
[ "$(row 401 verdict)" = queued ] && [ "$(row 401 verdict_hash)" = "$H401" ] && ok \
  || bad "(H5) the hand-off keeps the verdict and its hash: [$(row 401 verdict)/$(row 401 verdict_hash)]"
[ "$(row 401 next_recheck_at)" = "$(iso $((NOW+7200)))" ] && ok || bad "(H5) next_recheck_at = now + backoff: [$(row 401 next_recheck_at)]"
triage_state_list "$P" > "$T/rows5.json" 2>/dev/null
DUE=$(python3 "$PY" due --rows "$T/rows5.json" --now "$((NOW+60))" --ttl 86400 --defer-ttl 7200 --gh 1 2>/dev/null)
[ -z "$DUE" ] && ok || bad "(H5) a marker row is not due before its backoff (the defer clamp is skipped): [$DUE]"

# H6 — a second hand-off never nests, a real DECISION clears the marker
NOW_T=$((NOW+7300)); tick h6
[ "$(dec 401)" = "llm recheck-due" ] && ok || bad "(H6) precondition: due again after the backoff: [$(dec 401)]"
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
R401=$(row 401 reason)
[ "$(printf '%s' "$R401" | grep -o 'handed-no-decision' | wc -l | tr -d ' ')" = 1 ] \
  && [ "$(printf '%s' "$R401" | grep -o '; was: ' | wc -l | tr -d ' ')" = 1 ] \
  && case "$R401" in *"; was: DECISION defer: waits on the harness fix") true ;; *) false ;; esac && ok \
  || bad "(H6) a second hand-off keeps ONE '; was: <original>': [$R401]"
printf 'tickets=1\nDECISION: TK-401 :: comment :: asked the client\n' > "$T/out-d.txt"
ts_after_session "$H" "$P" 0 "$T/out-d.txt" >/dev/null 2>&1
case "$(row 401 reason)" in *handed-no-decision*) bad "(H6) a DECISION replaces the marker: [$(row 401 reason)]" ;; "DECISION comment: asked the client") ok ;; *) bad "(H6) reason: [$(row 401 reason)]" ;; esac
NOW_T=$NOW

# ═══ K — the backoff and the cap are settings rows, env the fallback ══════════
KJ="$DIR/catalog/lanes.d/_lib.triage-state.json"
[ "$(jq -c '.libs[0].knobs[] | select(.env=="TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S") | [.type, .default, .min, (.settable // true)]' "$KJ" 2>/dev/null)" = '["int",7200,600,true]' ] \
  && ok || bad "(K1) the registry declares TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S int 7200 min 600, settable"
[ -n "$(jq -r '.libs[0].knobs[] | select(.env=="TRIAGE_STATE_MAX_FETCH") | .env' "$KJ" 2>/dev/null)" ] && ok || bad "(K1) TRIAGE_STATE_MAX_FETCH is declared"
reset
for n in 501 502 503 504 505 506 507 508; do iss "$n" "k $n"; done; world
tick_env enforce
printf '{"fetched_at":%s,"values":{"lib.triage-state.triage_state_handed_no_decision_backoff_s":"900","lib.triage-state.triage_state_max_fetch":"5"},"seeded":{}}' \
  "$NOW" > "$H/state/settings-cache.json"
KOUT=$( unset LANE_GATE_DISABLE HARNESS_SECRET JOBS_URL TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S TRIAGE_STATE_MAX_FETCH
        export LANE_GATE_NOW=$NOW
        _ts_knobs "$P"; echo "backoff=${TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S:-} max=${TRIAGE_STATE_MAX_FETCH:-}"
        : > "$T/calls/gh"; ts_precheck >/dev/null 2>&1; echo "reads=$(reads | wc -l | tr -d ' ')"
        ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1 ) 2>/dev/null
case "$KOUT" in *"backoff=900 max=5"*) ok ;; *) bad "(K1) _ts_knobs exports the settings rows: [$KOUT]" ;; esac
case "$KOUT" in *"reads=5"*) ok ;; *) bad "(K1) one tick reads at most 5 threads: [$KOUT]" ;; esac
[ "$(row 501 next_recheck_at)" = "$(iso $((NOW+900)))" ] && ok || bad "(K1) the hand-off backoff comes from the row: [$(row 501 next_recheck_at)]"
rm -f "$H/state/settings-cache.json"
[ "$(TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S=1200 ts_hnd_backoff 2>/dev/null)" = 1200 ] && ok || bad "(K2) env 1200 is read"
[ "$(TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S=junk ts_hnd_backoff 2>/dev/null)" = 7200 ] && ok || bad "(K2) junk reads as the default 7200"
[ "$(TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S=60 ts_hnd_backoff 2>/dev/null)" = 600 ] && ok || bad "(K2) 60 is floored at 600"
reset
iss 601 "env"; world; tick_env enforce; tick k2
TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S=1200 ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
[ "$(row 601 next_recheck_at)" = "$(iso $((NOW+1200)))" ] && ok || bad "(K2) env 1200 sets the hand-off backoff: [$(row 601 next_recheck_at)]"

# ═══ A — the call-guard's third refusal names the stuck keys ═══════════════════
GA="$T/ga"; GP=gp
mkdir -p "$GA/bin" "$GA/state/triage-state/$GP" "$GA/logs" "$T/calls"
cat > "$GA/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/alert"
echo "alert \$*" >> "$GA/logs/ALERTS.log"
STUB
chmod +x "$GA/bin/lane-alert.sh"
cp "$DIR/bin/alert-line.sh" "$GA/bin/alert-line.sh"
printf 'pending' > "$GA/state/$GP.gate.pending"
printf '1\tBH-1\tllm\trecheck-due\t-\t-\t1\t-\t0\n2\tBH-2\tllm\tchanged\t-\t-\t1\t-\t0\n3\tBH-3\tllm\trecheck-due\t-\t-\t1\t-\t0\n4\tBH-4\tskip\tunchanged:triaged\t-\t-\t1\t-\t0\n' \
  > "$GA/state/triage-state/$GP/decisions.tsv"
printf '%s\t3\tBH-1 BH-2 BH-3\n' "$((NOW-60))" > "$GA/state/triage-state/$GP/hnd.last"
gcall() { # gcall <rc> <out-text> — one failed attempt through the real rt_gate_fail_consume
  printf '%s\n' "$2" > "$T/gout.txt"
  ( HARNESS="$GA"; PROJECT=$GP; RC=$1; OUT="$T/gout.txt"; STAMP=s; LOG="$GA/logs/$GP.log"; ALERTS="$GA/logs/ALERTS.log"
    unset TRIAGE_FAIL_CONSUME_AFTER
    . "$DIR/bin/lib/rt/gate.sh"; rt_gate_consume() { :; }; _rt_tgl() { return 1; }
    rt_gate_fail_consume ) >/dev/null 2>&1
}
stuck_n() { grep -c -- '--id triage-stuck:' "$T/calls/alert" 2>/dev/null || true; }
: > "$T/calls/alert"; : > "$GA/logs/ALERTS.log"
REF='AGENT_CALL_REFUSED call-guard repeat triage paid=2/2 fp=x'
gcall 74 "$REF"; gcall 74 "$REF"
[ "$(stuck_n)" = 0 ] && ok || bad "(A1) no stuck alert before the cap: [$(stuck_n)]"
gcall 74 "$REF"
[ "$(stuck_n)" = 1 ] && ok || bad "(A1) one triage-stuck:<p> alert at the third refusal: [$(cat "$T/calls/alert")]"
SL=$(grep -- '--id triage-stuck:gp' "$T/calls/alert")
case "$SL" in *BH-1*BH-2*BH-3*"model returned no DECISION for 3 handed keys"*) ok ;; *) bad "(A1) the alert names the keys and the reason: [$SL]" ;; esac
case "$SL" in *BH-4*) bad "(A1) a skipped key is not named: [$SL]" ;; *) ok ;; esac
[ "$(wc -l < "$GA/logs/ALERTS.log" | tr -d ' ')" = 2 ] && grep -q 'triage-fail-consume:gp' "$GA/logs/ALERTS.log" && ok \
  || bad "(A1) ALERTS.log grew by the fail-consume line plus this one: $(cat "$GA/logs/ALERTS.log")"
# A2 — a failure that is not a call-guard refusal never writes it
: > "$T/calls/alert"
gcall 1 boom; gcall 1 boom; gcall 1 boom
[ "$(stuck_n)" = 0 ] && grep -q 'triage-fail-consume:gp' "$T/calls/alert" && ok || bad "(A2) rc 1 'boom': only triage-fail-consume: [$(cat "$T/calls/alert")]"
# A3 — no hnd.last: the reason is the model-set breakdown
rm -f "$GA/state/triage-state/$GP/hnd.last"; : > "$T/calls/alert"
gcall 74 "$REF"; gcall 74 "$REF"; gcall 74 "$REF"
case "$(grep -- '--id triage-stuck:gp' "$T/calls/alert")" in *"recheck-due=2 changed=1"*) ok ;; *) bad "(A3) the breakdown reason: [$(cat "$T/calls/alert")]" ;; esac
# A4 — lane-alert does not run: one ALERTS line through bin/alert-line.sh
chmod -x "$GA/bin/lane-alert.sh"; : > "$GA/logs/ALERTS.log"
gcall 74 "$REF"; gcall 74 "$REF"; gcall 74 "$REF"
[ "$(grep -c 'triage is stuck' "$GA/logs/ALERTS.log")" = 1 ] && ok || bad "(A4) one alert-line 'triage is stuck' line: $(cat "$GA/logs/ALERTS.log")"
# A5 — the launch order (bin/lib/rt/launch.sh): ts_after_session runs on every
# refusal BEFORE the gate, and must not overwrite the hand-off count it reads
chmod +x "$GA/bin/lane-alert.sh"; cp "$GA/bin/lane-alert.sh" "$GA/bin/alert-line.sh" "$H/bin/"
reset
iss 701 "a"; iss 702 "b"; iss 703 "c"; world
tick_env enforce; tick a5
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
[ "$(cut -f2 "$SD/hnd.last" 2>/dev/null)" = 3 ] && ok || bad "(A5) precondition: hnd.last records 3 keys: [$(cat "$SD/hnd.last" 2>/dev/null)]"
: > "$T/calls/alert"
for _ in 1 2 3; do
  printf '%s\n' "$REF" > "$T/a5out.txt"
  ts_after_session "$H" "$P" 74 "$T/a5out.txt" >/dev/null 2>&1
  GA="$H" GP="$P" gcall 74 "$REF"
done
[ "$(cut -f2 "$SD/hnd.last" 2>/dev/null)" = 3 ] && ok || bad "(A5) an rc 74 session leaves hnd.last alone: [$(cat "$SD/hnd.last" 2>/dev/null)]"
case "$(grep -- "--id triage-stuck:$P" "$T/calls/alert")" in *"model returned no DECISION for 3 handed keys"*) ok ;; *) bad "(A5) the alert keeps the hand-off reason through three refusals: [$(cat "$T/calls/alert")]" ;; esac

echo "triage-state-fetch-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
