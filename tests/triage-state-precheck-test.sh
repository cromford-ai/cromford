#!/bin/bash
# tests/triage-state-precheck-test.sh — TRIAGE-STATE slice 2: the per-ticket
# pre-check that runs before a triage tick spends a token.
#
# Everything real except the network edges: bin/lib/triage-state.sh,
# bin/triage-state.py, bin/triage-signal.py, bin/triage-gate.sh --thread,
# bin/lib/gh-rest.sh, bin/lib/hold.sh and the jobs-client queue module, against
# the REAL worker route (one file-backed node:sqlite DB, the driver
# tests/file-claims-lib.bh-2524-test.sh uses). `gh` is a PATH stub serving
# fixture issues; bin/run-build.sh and bin/overlap-guard.sh are stubs that
# record their calls. The board fingerprint (state/<p>.gate.pending) is written
# by hand, in the shape bin/triage-gate.sh writes it.
#
#   (a) a rerun with unchanged inputs puts 0 tickets in the model set, reads no
#       thread, and an enforce tick ends at $0 before any agent call
#   (b) one new client comment puts exactly that ticket in the model set
#   (c) a buildable, unchanged, unbuilt ticket is handed to run-build with no
#       model call, once per verdict
#   (d) a held ticket (a HOLD comment / the hold label) is never enqueued
#   (e) shadow changes nothing a tick does (prompt, exit, launches, shard
#       filter) and records the decision in the lane log and the rows
#   (f) a dependency changing state (an issue closing, a PR merging) moves the hash
#   (g) our own App's comment and a harness label do not move the hash; a
#       person's (the PAT login's) comment does
#   plus: ts_after_session stamps the PRE-session hash from DECISION lines,
#   rc!=0 stamps nothing, the TTL makes a row due, backfill from decisions.log,
#   the kill switch, a dead worker fails open, the rt_shards hook is wired.
#
# Run from anywhere: tests/triage-state-precheck-test.sh   (exit 0 = all pass)
# BH-6578: triaged_at is one hour before the run, never a fixed date. A
# client-turn verdict comes back after triaged_at + the nudge (14 days), so a
# fixed date made this fixture go red on the day the nudge ran out.
TRIAGED_AT=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
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

LIB="$DIR/bin/lib/triage-state.sh"
PY="$DIR/bin/triage-state.py"
[ -r "$LIB" ] && ok || bad "bin/lib/triage-state.sh must exist"
[ -r "$PY" ] && ok || bad "bin/triage-state.py must exist"

# (NR) BH-2613 no-root contract (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md):
# the lib's root is ${HARNESS:-${H:-}}, never a /root/harness literal. With
# neither set, the pre-check decides nothing (TS_MODE=off, the tick runs as
# today), the recorder writes nothing, and no path is built from an empty root.
# Runs before the node:sqlite skip so every box checks it.
NR="$T/noroot"; mkdir -p "$NR"
NROUT=$( cd "$NR" && unset HARNESS H LOG && PROJECT=p && . "$LIB" && ts_precheck; echo "rc=$? mode=$TS_MODE ready=$TS_READY"
         echo x > "$NR/out.txt"; ts_after_session "" p 0 "$NR/out.txt"; echo "arc=$?"
         ts_mode "" p; echo; ts_hash_of 11; echo "hrc=$?"; _ts_prefix p; echo "prc=$?" ) 2>&1
case "$NROUT" in *"rc=0 mode=off ready=0"*"arc=0"*"hrc=0"*"prc=0"*) ok ;; *) bad "(NR) no root: pre-check off, recorder rc 0 [$NROUT]" ;; esac
[ "$(cd "$NR" && find . -mindepth 1 ! -name out.txt | head -1)" = "" ] && ok || bad "(NR) no root writes nothing: $(cd "$NR" && find . -mindepth 1)"
[ ! -e /state/triage-state ] && [ ! -e /logs/p.log ] && ok || bad "(NR) no root must never build /state or /logs from an empty root"
! grep -nE '\$\{HARNESS:-/root/harness' "$LIB" >/dev/null && ok || bad "(NR) the lib must not fall back to the /root/harness literal"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "triage-state-precheck: SKIPPED, this node has no node:sqlite"
  echo "triage-state-precheck: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"; P=project-5; SLUG=example-org/project-5
mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/builds" \
         "$H/catalog" "$T/gbin" "$T/fx/issues" "$T/fx/extra" "$T/calls"
for s in triage-gate.sh fleet-conf.sh triage-signal.py triage-state.py; do cp "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
chmod +x "$H/bin/"*.sh
: > "$H/env/global.env"
echo "SOP. Keys are TK-<issue-number>." > "$H/prompts/$P.md"
cat > "$H/bin/run-build.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/run-build"
STUB
cat > "$H/bin/overlap-guard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/overlap"
echo "LAUNCH \$2"
STUB
chmod +x "$H/bin/run-build.sh" "$H/bin/overlap-guard.sh"

# gh, as gh_rest calls it: `gh api -i -X GET <path> [-f/-F k=v]...`
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/gh"
case "\$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
  *repos/$SLUG/pulls*) printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/pulls.json"; exit 0 ;;
esac
N=\$(printf '%s\n' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p' | head -1)
# GH_STUB_SLEEP_<n>: a slow REST answer for issue n (the concurrent-fetcher case)
[ -n "\$N" ] && eval "SL=\\\${GH_STUB_SLEEP_\$N:-}" && [ -n "\$SL" ] && sleep "\$SL"
F="$T/fx/issues/\$N.json"
[ -s "\$F" ] || F="$T/fx/extra/\$N.json"   # issues NOT on the ai-build list (so not in the fingerprint)
[ -n "\$N" ] && [ -s "\$F" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
case "\$*" in
  *issues/\$N/comments*) printf 'HTTP/2 200\r\n\r\n'; jq -c '.comments' "\$F"; exit 0 ;;
  *) printf 'HTTP/2 200\r\n\r\n'; jq -c '.issue' "\$F"; exit 0 ;;
esac
STUB
chmod +x "$T/gbin/gh"
echo '[]' > "$T/fx/pulls.json"

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
WORKER_UP=1
_jobs_req() {
  local out code
  [ "$WORKER_UP" = 1 ] || return 1
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
iss() { # iss <n> <title> <body> [labels-json]
  jq -n --argjson n "$1" --arg t "$2" --arg b "$3" --argjson l "${4:-[\"ai-build\"]}" \
    '{issue:{number:$n,title:$t,body:$b,state:"open",labels:($l|map({name:.})),assignees:[],milestone:null,comments:0,
      updated_at:"2026-09-28T09:00:00Z"},comments:[]}' > "$T/fx/issues/$1.json"
}
comment() { # comment <n> <id> <login> <type> <body> <created_at>
  local f="$T/fx/issues/$1.json"
  jq --argjson id "$2" --arg u "$3" --arg ty "$4" --arg b "$5" --arg at "$6" \
    '.comments += [{id:$id,user:{login:$u,type:$ty},body:$b,created_at:$at,updated_at:$at}]
     | .issue.comments = (.comments|length) | .issue.updated_at = $at' "$f" > "$f.t" && mv "$f.t" "$f"
}
label() { local f="$T/fx/issues/$1.json"; jq --arg l "$2" '.issue.labels += [{name:$l}]' "$f" > "$f.t" && mv "$f.t" "$f"; }
# world — the gate's fingerprint, rebuilt from the fixtures: issue rows exactly
# as fetch_fingerprint projects them, the open PRs, and the content-hash meta.
world() {
  local rows
  rows=$(for f in "$T/fx/issues/"*.json; do jq -c '.issue | {number, state:(.state|ascii_upcase), title, comments, updatedAt: .updated_at} + (if .closed_at then {closedAt: .closed_at} else {} end)' "$f"; done | jq -sc 'sort_by(.number)')
  jq -cS -n --argjson i "$rows" --slurpfile p "$T/fx/pulls.json" \
    '{issues:$i, prs:($p[0] | map({number, headRefOid: .head.sha, state:"OPEN"})), meta:{}}' > "$H/state/$P.gate.pending"
}

iss 11 "Fee toggle" "Remove the discount toggle"
comment 11 1101 client-carl User "please remove it" 2026-09-28T08:00:00Z
iss 12 "Export CSV" "Add a CSV export button"
iss 13 "Nightly report" "Blocked-by: #20. Needs PR #30 first."
iss 20 "Report schema" "The dependency of #13"
echo '[{"number":30,"head":{"sha":"abc","ref":"ticket/TK-99-other"},"title":"TK-99: other","state":"open"}]' > "$T/fx/pulls.json"
world

# One tick's environment, the way bin/run-triage.sh has it when rt_shards runs.
tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$DIR/fleet.conf" \
         HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE="$1" GH_TOKEN=x \
         LANE_GATE_DISABLE=1
  PROJECT=$P; STAMP="2026-09-28 10:00:00Z"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
  GATE_DECISION="RUN ${2:-board-changed}"; GATE_REASON="${2:-board-changed}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; EW_KEYS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
LANE_TICK() { echo "LANE_TICK $*" >> "$T/calls/lane-tick"; }
rt_gate_consume() { echo consumed >> "$T/calls/consume"; }
# shellcheck source=/dev/null
. "$H/bin/lib/jobs/queue.sh"
# shellcheck source=/dev/null
[ -r "$LIB" ] && . "$H/bin/lib/triage-state.sh"
decisions() { cut -f1,3,4 "$H/state/triage-state/$P/decisions.tsv" 2>/dev/null | sort; }
row() { sql "SELECT $2 FROM triage_state WHERE project='$P' AND ticket_key='$1'"; }
llm_set() { awk -F'\t' '$3=="llm"{print $1}' "$H/state/triage-state/$P/decisions.tsv" 2>/dev/null | sort | tr '\n' ' '; }
thread_reads() { grep -cE "repos/$SLUG/issues/[0-9]+\$" "$T/calls/gh" 2>/dev/null || true; }
# run-build.sh is spawned DETACHED (setsid, like every launch here): wait for it.
settle() { local i=0; while [ "$i" -lt 30 ]; do [ "$(wc -l < "$T/calls/run-build" 2>/dev/null | tr -d ' ')" -ge "${1:-1}" ] && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
hashof() { awk -F'\t' -v k="$1" '$1==k{print $5}' "$H/state/triage-state/$P/decisions.tsv"; }

# ═══ 1 — first tick, shadow: every ticket is new, rows observed ═════════════
tick_env shadow
( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "11 12 13 20 " ] && ok || bad "(1) a first tick must send every open ticket to the model: [$(llm_set)]"
[ "$(awk -F'\t' '$1=="11"{print $4}' "$H/state/triage-state/$P/decisions.tsv" 2>/dev/null)" = new ] && ok || bad "(1) a ticket with no row is 'llm new': $(decisions)"
[ "$(row 11 last_decision)" = "llm new" ] && [ "$(row 11 last_mode)" = shadow ] && ok \
  || bad "(1) the observe write must record last_decision/last_mode: [$(row 11 last_decision)/$(row 11 last_mode)]"
H11=$(hashof 11)
[[ "$H11" =~ ^[0-9a-f]{64}$ ]] && [ "$(row 11 input_hash)" = "$H11" ] && ok || bad "(1) input_hash must be a sha256 and land on the row: [$H11]"
[ -z "$(row 11 verdict)" ] && ok || bad "(1) the pre-check must never write a verdict itself"

# the session: a DECISION for 11 and 12, nothing for 13, rc 0
cat > "$T/out1.txt" <<'OUT'
tickets=3 triaged=3
DECISION: TK-11 :: comment :: asked the client how the rep sets the discount
DECISION: TK-12 :: launch :: client confirmed the export columns
DECISION: TK-20 :: status :: moved to in-progress
OUT
ts_after_session "$H" "$P" 0 "$T/out1.txt" >/dev/null 2>&1
[ "$(row 11 verdict)" = needs_clarification ] && [ "$(row 11 waiting_on)" = client ] && ok \
  || bad "(S) a client question maps to needs_clarification/client: [$(row 11 verdict)/$(row 11 waiting_on)]"
[ "$(row 12 verdict)" = buildable ] && ok || bad "(S) DECISION launch maps to buildable: [$(row 12 verdict)]"
[ "$(row 13 verdict)" = triaged ] && ok || bad "(S) a model-set ticket with no DECISION line on an rc=0 session is stamped triaged: [$(row 13 verdict)]"
[ "$(row 11 verdict_hash)" = "$H11" ] && ok || bad "(S) verdict_hash must be the PRE-session input hash"
# TEST-CHANGE (BH-3921): at the default TTL 0 a `buildable` verdict has no timer,
# so record leaves next_recheck_at out (it never stamps now + 0).
[ -z "$(row 12 next_recheck_at)" ] && ok || bad "(S) at TTL 0 a buildable verdict carries no next_recheck_at: [$(row 12 next_recheck_at)]"

# ═══ (a) — the same inputs again: 0 to the model, 0 thread reads ═══════════
tick_env shadow
: > "$T/calls/gh"
( ts_precheck ) >/dev/null 2>&1
[ -z "$(llm_set)" ] && ok || bad "(a) unchanged inputs must put 0 tickets in the model set: [$(llm_set)] $(decisions | tr '\n' ' ')"
[ "$(thread_reads)" = 0 ] && ok || bad "(a) an unchanged board entry must re-hash the cached thread, not re-read it ($(thread_reads) reads)"
[ "$(awk -F'\t' '$1=="11"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "skip unchanged:needs_clarification" ] && ok \
  || bad "(a) the waiting-on-client ticket is skipped: $(decisions | tr '\n' ' ')"

# ═══ (e) — shadow changes nothing a tick does ══════════════════════════════
tick_env shadow
: > "$T/calls/run-build"; : > "$T/calls/overlap"
OUTE=$( ts_tick; echo "CONTINUED prompt=[$PROMPT_TEXT] skip=[$(ts_unit_skip /dev/null 11 && echo yes || echo no)]" ) 2>/dev/null
case "$OUTE" in *"CONTINUED prompt=[SOP PROMPT] skip=[no]"*) ok ;; *) bad "(e) shadow must not exit, not touch the prompt and not filter a shard: [$OUTE]" ;; esac
[ ! -s "$T/calls/run-build" ] && ok || bad "(e) shadow must never launch a build: $(cat "$T/calls/run-build")"
[ ! -s "$T/calls/overlap" ] && ok || bad "(e) shadow must not run the overlap guard (it writes its own log lines): $(cat "$T/calls/overlap")"
grep -q "triage-state shadow: 4 open, 0 to the model" "$H/logs/$P.log" && grep -q "would enqueue: TK-12" "$H/logs/$P.log" && ok \
  || bad "(e) shadow must log what it would do: $(grep triage-state "$H/logs/$P.log" | tail -2)"
[ "$(row 12 last_decision)" = enqueue ] && ok || bad "(e) the row must record the would-be decision: [$(row 12 last_decision)]"
# and off is the same tick with no record at all
tick_env off; : > "$H/logs/$P.log"
OUTO=$( ts_tick; echo "CONTINUED prompt=[$PROMPT_TEXT]" ) 2>/dev/null
case "$OUTO" in *"CONTINUED prompt=[SOP PROMPT]"*) ok ;; *) bad "(e) off must be a no-op: [$OUTO]" ;; esac
! grep -q triage-state "$H/logs/$P.log" && ok || bad "(e) off must log nothing"

# ═══ (a)+(c) — enforce: the tick ends at $0 and the buildable ticket launches ══
tick_env enforce; : > "$T/calls/run-build"; : > "$T/calls/consume"
OUTA=$( ts_tick; echo CONTINUED ) 2>/dev/null; RCA=$?
[ "$RCA" = 0 ] && case "$OUTA" in *CONTINUED*) false ;; *) true ;; esac && ok \
  || bad "(a) enforce with 0 changed must end the tick (exit 0) before any agent call: rc=$RCA [$OUTA]"
grep -q "rc=skip :: triage-state: 0 changed" "$H/logs/$P.log" && ok || bad "(a) the \$0 tick must log '0 changed': $(tail -2 "$H/logs/$P.log")"
grep -q consumed "$T/calls/consume" && ok || bad "(a) the \$0 tick must consume the gate fingerprint"
settle 1
grep -qx "$P TK-12" "$T/calls/overlap" && ok || bad "(c) enforce asks the overlap guard before a launch: $(cat "$T/calls/overlap")"
[ "$(cat "$T/calls/run-build" 2>/dev/null)" = "$P 12 TK-12" ] && ok \
  || bad "(c) the unchanged buildable ticket must be launched once via run-build.sh: [$(cat "$T/calls/run-build" 2>/dev/null)]"
tick_env enforce
( ts_tick ) >/dev/null 2>&1; sleep 1
[ "$(wc -l < "$T/calls/run-build" | tr -d ' ')" = 1 ] && ok || bad "(c) a second tick must not launch the same verdict again: $(cat "$T/calls/run-build")"
[ "$(awk -F'\t' '$1=="12"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "skip buildable-owned:enqueued" ] && ok \
  || bad "(c) the second tick reads the launch as its owner: $(decisions | tr '\n' ' ')"

# ═══ (d) — a held ticket is never enqueued ═════════════════════════════════
iss 14 "Dark mode" "Add dark mode"
comment 14 1401 client-carl User "HOLD: wait for the brand refresh" 2026-09-28T08:30:00Z
iss 15 "Audit log" "Add an audit log" '["ai-build","hold"]'
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
for k in 14 15; do
  jq -n --arg ta "$TRIAGED_AT" --arg k "$k" --arg h "$(hashof $k)" '{project:"project-5",ticket_key:$k,verdict:"buildable",verdict_hash:$h,input_hash:$h,
    triaged_at:$ta,next_recheck_at:"2099-01-01T00:00:00Z",reason:"test"}' > "$T/r.json"
  triage_state_put "$T/r.json" >/dev/null || bad "(d) could not seed the buildable row for $k"
done
tick_env enforce; : > "$T/calls/run-build"
( ts_tick ) >/dev/null 2>&1; sleep 1
! grep -qE ' (14|15) ' "$T/calls/run-build" 2>/dev/null && ok || bad "(d) a HOLD comment or the hold label must never be enqueued: $(cat "$T/calls/run-build")"
[ "$(awk -F'\t' '$1=="14"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv" | cut -c1-17)" = "skip buildable-he" ] \
  && [ "$(awk -F'\t' '$1=="15"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv" | cut -c1-17)" = "skip buildable-he" ] && ok \
  || bad "(d) both held tickets decide skip buildable-held: $(decisions | tr '\n' ' ')"

# ═══ (b) — one new client comment: exactly that ticket ═════════════════════
comment 11 1102 client-carl User "the rep sets it by hand" 2026-09-28T10:05:00Z
world
tick_env shadow; : > "$T/calls/gh"
( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "11 " ] && ok || bad "(b) one client comment must put exactly that ticket in the model set: [$(llm_set)]"
[ "$(awk -F'\t' '$1=="11"{print $4}' "$H/state/triage-state/$P/decisions.tsv")" = changed ] && ok || bad "(b) the reason is 'changed'"
H11B=$(hashof 11)
# enforce, same inputs: the session is bought for 11 only, and the prompt says so
tick_env enforce
OUTB=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUTB" in *CONTINUED*"Re-triage ONLY: TK-11"*) ok ;; *) bad "(b) enforce with one changed ticket runs the session, told to re-triage only that one: [$OUTB]" ;; esac
( ts_tick; ts_unit_skip /dev/null 11 && echo SKIP11; ts_unit_skip /dev/null 13 && echo SKIP13 ) > "$T/o" 2>/dev/null
! grep -q SKIP11 "$T/o" && grep -q SKIP13 "$T/o" && ok || bad "(b) the shard filter drops unchanged keys and keeps the changed one: $(cat "$T/o")"
printf '13\tqueue\tTS-13 waiting on PR #30\n' > "$T/units"
( ts_tick; ts_unit_skip "$T/units" 13 && echo SKIP13 ) > "$T/o" 2>/dev/null
! grep -q SKIP13 "$T/o" && ok || bad "(b) a key with a queue unit is never filtered (launch work is not triage)"
# a queue line in scope: never a $0 exit
tick_env enforce; ts_after_session "$H" "$P" 0 "$T/out1.txt" >/dev/null 2>&1   # 11 answered again
tick_env enforce queue-pending; QLINES="TK-13 waiting on PR #30"
OUTQ=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$OUTQ" in *CONTINUED*) ok ;; *) bad "(b) a tick with queue lines is never ended at \$0: [$OUTQ]" ;; esac
tick_env enforce forced
OUTF=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUTF" in *"CONTINUED [SOP PROMPT]"*) ok ;; *) bad "(b) a forced tick is observed only: [$OUTF]" ;; esac

# ═══ ts_after_session: the PRE-session hash, and rc!=0 stamps nothing ══════
comment 13 1301 client-carl User "any update?" 2026-09-28T10:10:00Z
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
H13=$(hashof 13); OLD13=$(row 13 verdict_hash)
ts_after_session "$H" "$P" 1 "$T/out1.txt" >/dev/null 2>&1
[ "$(row 13 verdict_hash)" = "$OLD13" ] && ok || bad "(S) an rc!=0 session stamps nothing"
comment 13 1302 client-carl User "hello?" 2026-09-28T10:11:00Z   # lands mid-session
world
printf 'DECISION: TK-13 :: comment :: told the client PR #30 is in review\n' > "$T/out2.txt"
ts_after_session "$H" "$P" 0 "$T/out2.txt" >/dev/null 2>&1
# TEST-CHANGE (reason refs): this asserted verdict_hash = H13 byte for byte. The
# new reason names PR #30, and a reason's refs are now part of the hash, so the
# stamp is the PRE-session thread hash composed with the NEW reason's refs at
# their pre-session state — no longer H13 (whose row reason named nothing). The
# property is proved by behaviour instead, and more strongly: the mid-session
# comment re-offers the ticket, and with that comment taken away the very same
# stamp reads as unchanged.
[ "$(row 13 verdict_hash)" != "$OLD13" ] && [[ "$(row 13 verdict_hash)" =~ ^[0-9a-f]{64}$ ]] && ok || bad "(S) an rc 0 session stamps a new verdict hash"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "13 " ] && ok || bad "(S) a comment that landed mid-session re-offers the ticket next tick: [$(llm_set)]"
cp "$T/fx/issues/13.json" "$T/13.keep"
jq '.comments |= map(select(.id != 1302)) | .issue.comments = (.comments|length) | .issue.updated_at = "2026-09-28T10:10:00Z"' "$T/13.keep" > "$T/fx/issues/13.json"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(llm_set)" ] && ok || bad "(S) the verdict is stamped with the inputs the session was HANDED (without the mid-session comment it is unchanged): [$(llm_set)]"
mv "$T/13.keep" "$T/fx/issues/13.json"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
ts_after_session "$H" "$P" 0 "$T/out2.txt" "13" "$(hashof 13)" >/dev/null 2>&1   # the shard form
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(llm_set)" ] && ok || bad "(S) the shard form stamps its own key: [$(llm_set)]"

# ═══ (g) — our own writes do not move the hash; a person's do ══════════════
BASE13=$(hashof 13)
comment 13 1303 cromford[bot] Bot "triage: still waiting on #30" 2026-09-28T10:20:00Z
label 13 dequeued
world
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
[ "$(thread_reads)" -ge 1 ] && ok || bad "(g) a moved board entry must re-read the thread"
[ "$(hashof 13)" = "$BASE13" ] && [ -z "$(llm_set)" ] && ok \
  || bad "(g) our App's comment and a harness label must not move the hash: [$(llm_set)]"
comment 13 1304 operator User "ship it once #30 lands" 2026-09-28T10:25:00Z
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "13 " ] && ok || bad "(g) a comment by the PAT login is a person's: [$(llm_set)]"
printf 'DECISION: TK-13 :: skip :: nothing to do until #30 merges\n' > "$T/out3.txt"
ts_after_session "$H" "$P" 0 "$T/out3.txt" >/dev/null 2>&1

# ═══ (f) — a dependency changing state moves the hash, with no thread read ═
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1; BASE13=$(hashof 13)
[ -z "$(llm_set)" ] && ok || bad "(f) precondition: nothing in the model set: [$(llm_set)]"
echo '[]' > "$T/fx/pulls.json"; world    # PR #30 merged: gone from the open list
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "13 " ] && [ "$(hashof 13)" != "$BASE13" ] && ok || bad "(f) a PR the ticket names merging must move its hash: [$(llm_set)]"
# TEST-CHANGE (review of #3172, item 7): this asserted thread_reads = 0. #30 has
# left the open-PR list, so it is no longer on the board fingerprint and is now
# looked up by REST (refs.json) — one issues/ call, for #30, and no thread of any
# ticket re-read. Pinned exactly rather than loosened.
[ "$(grep -oE "repos/$SLUG/issues/[0-9]+(/comments)?\$" "$T/calls/gh" | sort -u | tr '\n' ' ')" = "repos/$SLUG/issues/30 " ] && ok \
  || bad "(f) the only issues/ call is the REST lookup of #30, no thread re-read: $(grep issues "$T/calls/gh" | tr '\n' ' ')"
ts_after_session "$H" "$P" 0 "$T/out3.txt" >/dev/null 2>&1
jq '.issue.state="closed"' "$T/fx/issues/20.json" > "$T/c.json" && mv "$T/c.json" "$T/fx/issues/20.json"; world   # issue #20 closes
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
# TEST-CHANGE (review of #3172, item 6): #20 itself closed while holding a
# verdict, so it now goes to the model once too (`llm closed`); 13 is still here.
# TEST-CHANGE (closed stamp in the pre-check): a closed ticket is no longer sent to
# the model (`llm closed`, which looped: no session ever ran for it); the
# pre-check stamps it `closed` itself, so the expectation here moves with it.
[ "$(llm_set)" = "13 " ] && [ "$(awk -F'\t' '$1=="20"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "stamp closed-on-board" ] && ok \
  || bad "(f) a Blocked-by issue closing must move the hash (and the closed #20 is stamped closed, not offered): [$(llm_set)]"
ts_after_session "$H" "$P" 0 "$T/out3.txt" >/dev/null 2>&1

# ═══ webhook: a ticket a delivery named is NOT re-read when its entry did not move
# TEST-CHANGE (BH-3921): a webhook no longer forces a read; only a moved board
# row (or no cache) does. A real change moves the row the same tick.
tick_env shadow; : > "$T/calls/gh"; EW_KEYS="TK-12"
( ts_precheck ) >/dev/null 2>&1
[ "$(thread_reads)" = 0 ] && ok \
  || bad "(w) a webhook-named ticket whose entry did not move makes no thread read: $(grep issues "$T/calls/gh" | tr '\n' ' ')"

# ═══ TTL: a row past its recheck goes back to the model ════════════════════
sql "UPDATE triage_state SET next_recheck_at='2020-01-01T00:00:00Z' WHERE project='$P' AND ticket_key='13'" >/dev/null
# TEST-CHANGE (BH-3921): the default TTL is 0 (a stale stamp is ignored), so this
# pins the TTL > 0 sweep with TRIAGE_STATE_TTL_S=86400 on this tick.
tick_env shadow; ( TRIAGE_STATE_TTL_S=86400; ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="13"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "llm recheck-due" ] && ok \
  || bad "(t) a due row is 'llm recheck-due': $(decisions | tr '\n' ' ')"

# ═══ backfill from decisions.log ═══════════════════════════════════════════
iss 16 "Old ticket" "triaged before this existed"
comment 16 1601 client-carl User "is this on the list?" 2026-09-27T08:00:00Z
iss 17 "Another" "client wrote after the decision"
comment 17 1701 client-carl User "one more thing" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"   # determinism: ok — must be newer than the decision below
world
DSTAMP=$(date -u -d '-1 hour' '+%Y-%m-%d %H:%M:%S')   # determinism: ok — a decision inside the TTL
printf '%sZ [%s] gate=board-changed scope=full TK-16 :: comment :: asked the client for the priority\n' "$DSTAMP" "$P" >> "$H/logs/decisions.log"
printf '%sZ [%s] gate=board-changed scope=full TK-17 :: comment :: asked the client for the priority\n' "$DSTAMP" "$P" >> "$H/logs/decisions.log"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="16"{print $3}' "$H/state/triage-state/$P/decisions.tsv")" = skip ] && [ "$(row 16 verdict)" = needs_clarification ] && ok \
  || bad "(k) a decision newer than the last human word seeds the row: $(decisions | grep '^16') [$(row 16 verdict)]"
[ "$(awk -F'\t' '$1=="17"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "llm new" ] && [ -z "$(row 17 verdict)" ] && ok \
  || bad "(k) a decision OLDER than the last human word seeds nothing: $(decisions | grep '^17')"

# ═══ a SCOPED tick counts only the model-set tickets in its own scope ═══════
# 17 is still `llm new` (never triaged) but lives outside this tick's diff.
tick_env enforce board-changed; SCOPE_N=1; TICK_SCOPE='board 1: CHANGED 11 "Fee toggle"'
OUTS=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$OUTS" in *CONTINUED*) bad "(s) a board scope whose tickets are all unchanged ends at \$0 even with a new ticket elsewhere: [$OUTS]" ;; *) ok ;; esac
tick_env enforce board-changed; SCOPE_N=1; TICK_SCOPE='board 1: NEW 17 "Another"'
OUTS=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUTS" in *CONTINUED*) ok ;; *) bad "(s) a scope holding a model-set ticket runs the session" ;; esac
case "$OUTS" in *"Re-triage ONLY"*) bad "(s) a scoped tick is never widened with a positive list: [$OUTS]" ;; *) ok ;; esac
tick_env enforce event-wake; SCOPE_N=1; TICK_SCOPE='something this cannot place'
OUTS=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$OUTS" in *CONTINUED*) ok ;; *) bad "(s) a scope line nobody can place reads as work" ;; esac


# ═══ REVIEW (#3172) — BLOCKER: a scoped tick never blanket-stamps a key it did not read
comment 11 1103 client-carl User "and a note for the invoice" 2026-09-28T11:00:00Z
world
tick_env shadow board-changed; SCOPE_N=1; TICK_SCOPE='board 1: CHANGED 11 "Fee toggle"'
( ts_tick ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="11"{print $7}' "$H/state/triage-state/$P/decisions.tsv")" = 1 ] \
  && [ "$(awk -F'\t' '$1=="17"{print $3" "$7}' "$H/state/triage-state/$P/decisions.tsv")" = "llm 0" ] && ok \
  || bad "(R0) decisions.tsv records in_scope: 11 in the board diff, 17 (new) outside it: $(cut -f1,3,7 "$H/state/triage-state/$P/decisions.tsv" | tr '\n' ' ')"
printf 'tickets=1 triaged=1\n' > "$T/out-scoped.txt"
ts_after_session "$H" "$P" 0 "$T/out-scoped.txt" >/dev/null 2>&1
[ -z "$(row 17 verdict)" ] && [ -z "$(row 17 verdict_hash)" ] && ok \
  || bad "(R0) an out-of-scope model-set key the session never read must get NO verdict: [$(row 17 verdict)]"
[ "$(row 11 verdict_hash)" = "$(hashof 11)" ] && [ "$(row 11 verdict)" = triaged ] && ok \
  || bad "(R0) the in-scope key with no DECISION line is stamped triaged: [$(row 11 verdict)]"
printf 'tickets=2\nDECISION: TK-17 :: comment :: asked the client for the priority\n' > "$T/out-scoped2.txt"
ts_after_session "$H" "$P" 0 "$T/out-scoped2.txt" >/dev/null 2>&1
[ "$(row 17 verdict)" = needs_clarification ] && ok || bad "(R0) an explicit DECISION still stamps any key: [$(row 17 verdict)]"

# ═══ REVIEW 1 — rc 0 with no summary and no DECISION line stamps nothing ══════
comment 11 1104 client-carl User "one more" 2026-09-28T11:05:00Z
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
OLD11=$(row 11 verdict_hash)
printf 'the session printed nothing useful\n' > "$T/out-empty.txt"
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" >/dev/null 2>&1
[ "$(row 11 verdict_hash)" = "$OLD11" ] && ok || bad "(R1) an rc 0 session with no tickets= summary and no DECISION must not blanket-stamp"
ts_after_session "$H" "$P" 0 "$T/out-empty.txt" 11 "$(hashof 11)" >/dev/null 2>&1
[ "$(row 11 verdict_hash)" = "$OLD11" ] && ok || bad "(R1) nor may a shard with no summary and no DECISION"

# ═══ REVIEW 2 — every DECISION line is read, not the first 40 ═══════════════
{ for i in $(seq 1 45); do printf 'DECISION: TK-%s :: skip :: filler\n' "$((900+i))"; done
  printf 'DECISION: TK-11 :: comment :: asked the client about the invoice note\n'; } > "$T/out-many.txt"
ts_after_session "$H" "$P" 0 "$T/out-many.txt" >/dev/null 2>&1
[ "$(row 11 verdict_hash)" = "$(hashof 11)" ] && [ "$(row 11 verdict)" = needs_clarification ] && ok \
  || bad "(R2) the 46th DECISION line must be read: [$(row 11 verdict)]"

# ═══ REVIEW 3 — backfill only when the decision is newer than ANY update ═════
iss 19 "Label edited" "no human comment after the decision"
comment 19 1901 client-carl User "please" 2026-09-20T08:00:00Z
f="$T/fx/issues/19.json"; jq --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '.issue.updated_at=$at | .issue.labels += [{name:"p1"}]' "$f" > "$f.t" && mv "$f.t" "$f"   # determinism: ok — an edit after the decision
world
printf '%sZ [%s] gate=board-changed scope=full TK-19 :: comment :: asked the client\n' "$(date -u -d '-1 hour' '+%Y-%m-%d %H:%M:%S')" "$P" >> "$H/logs/decisions.log"   # determinism: ok — a decision inside the TTL, one hour before the edit
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="19"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "llm new" ] && [ -z "$(row 19 verdict)" ] && ok \
  || bad "(R3) a label/body edit newer than the decision leaves the row unseeded: $(grep '^19' "$H/state/triage-state/$P/decisions.tsv")"
printf 'tickets=1\nDECISION: TK-19 :: skip :: fine\n' > "$T/o19.txt"; ts_after_session "$H" "$P" 0 "$T/o19.txt" >/dev/null 2>&1

# ═══ REVIEW 4 — the in-app held check fails CLOSED for a launch ══════════════
H2="$T/h2"; mkdir -p "$H2/bin" "$H2/state/triage-state/$P"
printf '#!/bin/bash\nexit 1\n' > "$H2/bin/triage-gate.sh"; chmod +x "$H2/bin/triage-gate.sh"
OWN=$( HARNESS="$H2"; TS_MODE=shadow; queue_status() { return 2; }; echo '[]' > "$H2/state/triage-state/$P/prs.json"; _ts_owned 101 TK-101 "$(printf 'a%.0s' $(seq 64))" "" 0 ); RCO=$?
[ "$RCO" = 0 ] && case "$OWN" in held:*) true ;; *) false ;; esac && ok \
  || bad "(R4) an in-app buildable gate that cannot answer must hold the launch (rc=$RCO out=[$OWN])"
G="$T/g"; mkdir -p "$G/bin/lib" "$G/env" "$G/state" "$G/logs"
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/fleet-conf.sh" "$G/bin/"; cp "$DIR"/bin/lib/*.sh "$G/bin/lib/"
printf 'sg   org/sg   https://x.invalid /api/board 1 box-1\n' > "$G/fleet.conf"; : > "$G/env/global.env"
printf 'SG_APP_BASE=https://x.invalid\nSG_INTERNAL_API_TOKEN=tok-sg\n' > "$G/env/sg.env"
printf '#!/bin/bash\necho "BOARD-FETCH FAILED: HTTP 503 for x"\n' > "$G/bin/board-fetch.sh"; chmod +x "$G/bin/"*.sh
GB=$(env HARNESS="$G" HARNESS_ENV_DIR="$G/env" FLEET_CONF="$G/fleet.conf" bash "$G/bin/triage-gate.sh" sg --buildable-strict 101 2>/dev/null)
case "$GB" in "BLOCKED unreadable"*) ok ;; *) bad "(R4) --buildable-strict answers BLOCKED on a failed fetch: [$GB]" ;; esac
GB=$(env HARNESS="$G" HARNESS_ENV_DIR="$G/env" FLEET_CONF="$G/fleet.conf" bash "$G/bin/triage-gate.sh" sg --buildable 101 2>/dev/null)
[ "$GB" = OK ] && ok || bad "(R4) plain --buildable keeps its fail-open answer for the client-court guard: [$GB]"

# ═══ REVIEW 5 — the directive never names a key the tick has queue/close-out work for
comment 13 1305 client-carl User "status?" 2026-09-28T11:10:00Z
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-13 :: skip :: waiting on #30\n' > "$T/o13.txt"; ts_after_session "$H" "$P" 0 "$T/o13.txt" >/dev/null 2>&1
tick_env enforce queue-pending; SCOPE_N=queue; QLINES="TK-13 waiting on PR #30"; RDIRS="$H/builds/$P-TK-12-20260928 :: RESULT: BUILT"
OUT5=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUT5" in *"must NOT be re-triaged"*) ok ;; *) bad "(R5) precondition: the directive is appended: [$OUT5]" ;; esac
UNCH=$(printf '%s' "$OUT5" | sed -n 's/.*status: \(.*\)\. Queue lines.*/\1/p')
case " $UNCH " in *" TK-13 "*|*" TK-12 "*) bad "(R5) a key with a queue line or a result dir must not be listed as do-not-touch: [$UNCH]" ;; *) ok ;; esac
case " $UNCH " in *" TK-11 "*) ok ;; *) bad "(R5) other unchanged keys are still listed: [$UNCH]" ;; esac

# ═══ REVIEW 6 — a ticket that closed is stamped closed, then rests ═══════════
# TEST-CHANGE (closed stamp in the pre-check): a closed ticket is no longer sent to
# the model (`llm closed`, which looped: no session ever ran for it); the
# pre-check stamps it `closed` itself, so the expectation here moves with it.
f="$T/fx/issues/16.json"; jq '.issue.state="closed"' "$f" > "$f.t" && mv "$f.t" "$f"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="16"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "stamp closed-on-board" ] && ok \
  || bad "(R6) an open->closed ticket whose verdict is not closed is stamped closed, no model call: $(grep '^16' "$H/state/triage-state/$P/decisions.tsv")"
[ "$(row 16 verdict)" = closed ] && ok || bad "(R6) the row says closed: [$(row 16 verdict)]"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
! grep -q '^16	' "$H/state/triage-state/$P/decisions.tsv" && ok || bad "(R6) a closed ticket with a closed verdict is never offered again"

# ═══ REVIEW 7 — a blocker NOT on the ai-build list still moves the hash ═══════
iss 18 "Needs the platform fix" "Blocked-by: #40"
jq -n '{issue:{number:40,title:"platform",body:"x",state:"open",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/40.json"
world
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
grep -qE "repos/$SLUG/issues/40\$" "$T/calls/gh" && ok || bad "(R7) an absent #N ref is looked up by REST"
printf 'tickets=1\nDECISION: TK-18 :: skip :: blocked on #40\n' > "$T/o18.txt"; ts_after_session "$H" "$P" 0 "$T/o18.txt" >/dev/null 2>&1
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(llm_set)" ] && ok || bad "(R7) precondition: nothing to the model: [$(llm_set)]"
f="$T/fx/extra/40.json"; jq '.issue.state="closed"' "$f" > "$f.t" && mv "$f.t" "$f"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(llm_set)" = "18 " ] && ok || bad "(R7) the off-list blocker closing moves the hash: [$(llm_set)]"
printf 'tickets=1\nDECISION: TK-18 :: comment :: unblocked, asked the client to confirm\n' > "$T/o18.txt"; ts_after_session "$H" "$P" 0 "$T/o18.txt" >/dev/null 2>&1
# refs.json forgets what no open ticket names: never re-asked, pruned
jq '. + {"77":"OPEN"}' "$H/state/triage-state/$P/refs.json" > "$T/r.t" && mv "$T/r.t" "$H/state/triage-state/$P/refs.json"
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
! grep -qE "repos/$SLUG/issues/77\$" "$T/calls/gh" && ok || bad "(R7b) an OPEN ref no open ticket names is not fetched"
[ "$(jq -r 'has("77")' "$H/state/triage-state/$P/refs.json")" = false ] && ok || bad "(R7b) and it is pruned from refs.json: $(cat "$H/state/triage-state/$P/refs.json")"
[ "$(jq -r '."40" // ""' "$H/state/triage-state/$P/refs.json")" = CLOSED ] && ok || bad "(R7b) a ref an open ticket still names is kept: $(cat "$H/state/triage-state/$P/refs.json")"
sql "UPDATE triage_state SET next_recheck_at='2020-01-01T00:00:00Z' WHERE project='$P' AND ticket_key='12'" >/dev/null
# TEST-CHANGE (BH-3921): a due recheck no longer forces a read (the session reads
# the thread itself), so 12's unmoved thread is hashed from the cache.
tick_env shadow; : > "$T/calls/gh"; ( TRIAGE_STATE_TTL_S=86400; ts_precheck ) >/dev/null 2>&1
! grep -qE "repos/$SLUG/issues/12\$" "$T/calls/gh" && ok || bad "(R7) a due recheck with an unmoved row makes no thread read"

# ═══ REVIEW 8 — shadow reports what it would have missed ═════════════════════
# A miss is a DECISION on a ticket the pre-check marked `skip unchanged` that
# would have CHANGED something: its verdict (verdict_of) differs from the stored
# one. A `skip` DECISION (the model looked and left it: BH-3223 "skip ::
# QUEUED_FLY on pool, still running", BH-3159) and a DECISION landing on the
# stored verdict are no-ops, counted apart as model-noop-on-skip.
# TEST-CHANGE (shadow no-op fix): this asserted TK-11's `comment :: re-asked the
# client` is a miss. Its verdict is needs_clarification, the verdict TK-11
# already holds, so the gate skipping it lost nothing: it is now asserted as a
# no-op, and a verdict-changing launch and defer are asserted as misses.
for k in 13 18 19; do sql "UPDATE triage_state SET verdict='triaged', waiting_on='none', next_recheck_at='2099-01-01T00:00:00Z' WHERE project='$P' AND ticket_key='$k'" >/dev/null; done
sql "UPDATE triage_state SET verdict='needs_clarification', waiting_on='client', next_recheck_at='2099-01-01T00:00:00Z' WHERE project='$P' AND ticket_key='11'" >/dev/null
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(for k in 11 13 18 19; do awk -F'\t' -v k="$k" '$1==k{printf "%s %s|", $3, $4}' "$H/state/triage-state/$P/decisions.tsv"; done)" \
  = "skip unchanged:needs_clarification|skip unchanged:triaged|skip unchanged:triaged|skip unchanged:triaged|" ] && ok \
  || bad "(R8) precondition: 11/13/18/19 are skip unchanged: $(decisions | grep -E '^(11|13|18|19)\s' | tr '\n' ' ')"
cat > "$T/o-miss.txt" <<'OUT'
tickets=4
DECISION: TK-11 :: comment :: re-asked the client
DECISION: TK-13 :: skip :: QUEUED_FLY on pool, still running
DECISION: TK-18 :: launch :: blocker gone, building
DECISION: TK-19 :: defer :: waits on the harness fix
OUT
: > "$H/logs/$P.log"; ts_after_session "$H" "$P" 0 "$T/o-miss.txt" >/dev/null 2>&1
grep -q "triage-state shadow: would-have-missed 2: TK-18 (launch), TK-19 (defer)\$" "$H/logs/$P.log" && ok \
  || bad "(R8) a verdict-changing launch and defer are misses; the skip and the same-verdict comment are not: $(grep would-have "$H/logs/$P.log")"
grep -q "triage-state shadow: model-noop-on-skip 2: TK-11 (comment), TK-13 (skip)\$" "$H/logs/$P.log" && ok \
  || bad "(R8) the skip DECISION and the same-verdict DECISION are logged as model-noop-on-skip: $(grep triage-state "$H/logs/$P.log")"

# a LAUNCH always has effect, even on a ticket already stored `buildable`: the
# earlier launch was lost (a context-drift deferral, a stranded queue row, a
# failed build — BH-1174) and the gate, seeing it owned, would skip the relaunch.
sql "UPDATE triage_state SET verdict='buildable', waiting_on='team', triaged_at='2026-09-01T00:00:00Z', next_recheck_at='2099-01-01T00:00:00Z' WHERE project='$P' AND ticket_key='12'" >/dev/null
rm -f "$H/state/triage-state/$P/12.enqueued"; mkdir -p "$H/builds/$P-TK-12-20260928-failed"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$1=="12"{print $3" "$4}' "$H/state/triage-state/$P/decisions.tsv")" = "skip buildable-owned:build-dir" ] && ok \
  || bad "(R8b) precondition: the buildable ticket with a failed build dir is skipped as owned: $(decisions | grep '^12')"
printf 'tickets=1\nDECISION: TK-12 :: launch :: the last build failed, relaunching\n' > "$T/o-miss2.txt"
: > "$H/logs/$P.log"; ts_after_session "$H" "$P" 0 "$T/o-miss2.txt" >/dev/null 2>&1
grep -q "triage-state shadow: would-have-missed 1: TK-12 (launch)\$" "$H/logs/$P.log" && ok \
  || bad "(R8b) a launch on a ticket stored buildable (skipped as owned) is a miss: $(grep triage-state "$H/logs/$P.log")"
rmdir "$H/builds/$P-TK-12-20260928-failed"

# ═══ REVIEW 9 — daily-sweep and remote-results-pending never end at $0 ═══════
for r in daily-sweep remote-results-pending; do
  tick_env enforce "$r"
  OUT9=$( ts_tick; echo CONTINUED ) 2>/dev/null
  case "$OUT9" in *CONTINUED*) ok ;; *) bad "(R9) a $r tick is never ended at \$0: [$OUT9]" ;; esac
done

# ═══ REASON REFS — the BH-3149 / BH-3154 incident (first shadow tick, 2026-09-28)
# A ticket was deferred "until #3165"; its thread never names #3165. #3165
# merged and the hash did not move, so enforce would have held the ticket to the
# 24h TTL. Every #N / KEY-N in the stored verdict's REASON is a dependency now.
dcol() { awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}' "$H/state/triage-state/$P/decisions.tsv"; }
iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # determinism: ok — rows are judged against the real clock
epoch_of() { date -u -d "$1" +%s; }
echo '[{"number":50,"head":{"sha":"a50","ref":"fix/title-hold"},"title":"fix the title hold classifier","state":"open"},
       {"number":51,"head":{"sha":"a51","ref":"fix/other"},"title":"another fix","state":"open"}]' > "$T/fx/pulls.json"
iss 21 "Title-hold false positive" "The classifier holds this on its title."
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 21 3)" = llm ] && ok || bad "(RR) precondition: the new ticket goes to the model: $(dcol 21 3)"
printf 'tickets=1\nDECISION: TK-21 :: defer :: classifier still returns hold:title; #50 remains open\n' > "$T/o21.txt"
ts_after_session "$H" "$P" 0 "$T/o21.txt" >/dev/null 2>&1
[ "$(row 21 verdict)" = queued ] && ok || bad "(RR) a defer maps to queued: [$(row 21 verdict)]"
# #50 still open: unchanged, skip
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 21 3) $(dcol 21 4)" = "skip unchanged:queued" ] && ok \
  || bad "(RR) the defer's ref still open: unchanged: [$(dcol 21 3) $(dcol 21 4)]"
# #50 merges: it leaves the open-PR list and REST says merged
echo '[{"number":51,"head":{"sha":"a51","ref":"fix/other"},"title":"another fix","state":"open"}]' > "$T/fx/pulls.json"
jq -n '{issue:{number:50,title:"fix the title hold classifier",body:"x",state:"closed",labels:[],comments:0,
  pull_request:{merged_at:"2026-09-28T18:40:00Z"},updated_at:"2026-09-28T18:40:00Z"},comments:[]}' > "$T/fx/extra/50.json"
world
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 21 3) $(dcol 21 4)" = "llm changed" ] && ok \
  || bad "(RR) the ref the defer waits on merging moves the hash: [$(dcol 21 3) $(dcol 21 4)]"
grep -qE "repos/$SLUG/issues/50\$" "$T/calls/gh" && ok || bad "(RR) a reason ref off the fingerprint is looked up by REST like a thread ref"
[ "$(jq -r '."50" // ""' "$H/state/triage-state/$P/refs.json")" = MERGED ] && ok \
  || bad "(RR) and cached in refs.json: $(cat "$H/state/triage-state/$P/refs.json")"
# the model launches it; the new reason names no ref, so the stamp is stable
printf 'tickets=1\nDECISION: TK-21 :: launch :: title-hold false positive cleared by the fix\n' > "$T/o21.txt"
ts_after_session "$H" "$P" 0 "$T/o21.txt" >/dev/null 2>&1
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 21 3)" != llm ] && ok || bad "(RR) a verdict is stable the tick after it is stamped: [$(dcol 21 3) $(dcol 21 4)]"
# the stamp covers the NEW reason's refs at their pre-session state: a verdict
# that names a still-open ref is not re-offered the next tick (no circularity)
iss 22 "Waits on another fix" "nothing named here"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-22 :: defer :: wait for #51 to land\n' > "$T/o22.txt"
ts_after_session "$H" "$P" 0 "$T/o22.txt" >/dev/null 2>&1
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 22 3) $(dcol 22 4)" = "skip unchanged:queued" ] && ok \
  || bad "(RR) a fresh verdict naming a new ref is not re-offered next tick: [$(dcol 22 3) $(dcol 22 4)]"
# a reason ref off the fingerprint that the pre-check never looked up is resolved
# after the session (bounded REST), so it does not re-offer the ticket either
jq -n '{issue:{number:60,title:"infra",body:"x",state:"open",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/60.json"
iss 23 "Waits on infra" "nothing named here either"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-23 :: defer :: blocked until #60 is done\n' > "$T/o23.txt"
ts_after_session "$H" "$P" 0 "$T/o23.txt" >/dev/null 2>&1
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 23 3) $(dcol 23 4)" = "skip unchanged:queued" ] && ok \
  || bad "(RR) an off-board reason ref is resolved at record time: [$(dcol 23 3) $(dcol 23 4)] refs=$(cat "$H/state/triage-state/$P/refs.json")"

# ═══ REASON REFS — the transition: rows stamped before reason refs existed ════
# A legacy row's verdict_hash is the thread-only hash (decisions.tsv column 8,
# base). It is NOT a blanket "changed": a legacy row whose reason refs are all
# still open is re-stamped in place with no model call; one whose reason ref has
# since settled (merged/closed) goes to the model — the incident's exact case.
B22=$(dcol 22 8)
[[ "$B22" =~ ^[0-9a-f]{64}$ ]] && [ "$B22" != "$(dcol 22 5)" ] && ok \
  || bad "(RT) decisions.tsv column 8 carries the thread-only base hash: [$B22] vs [$(dcol 22 5)]"
sql "UPDATE triage_state SET verdict_hash='$B22' WHERE project='$P' AND ticket_key='22'" >/dev/null
: > "$H/logs/$P.log"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 22 3) $(dcol 22 4)" = "skip unchanged:queued" ] && ok \
  || bad "(RT) a legacy row whose reason refs are all open is not sent to the model: [$(dcol 22 3) $(dcol 22 4)]"
[ "$(row 22 verdict_hash)" = "$(dcol 22 5)" ] && ok || bad "(RT) and is re-stamped in place with the new hash: [$(row 22 verdict_hash)]"
grep -q "triage-state shadow: re-stamped 1 legacy verdict" "$H/logs/$P.log" && ok \
  || bad "(RT) the one-time re-stamp is logged: $(grep triage-state "$H/logs/$P.log" | tail -2)"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 22 3)" = skip ] && ok || bad "(RT) the re-stamp holds on the next tick: [$(dcol 22 3) $(dcol 22 4)]"
# the incident: a legacy defer naming a PR that has merged since
iss 24 "Deferred before the fix" "classifier false positive"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
B24=$(dcol 24 8)
jq -n --arg h "$B24" --arg at "$(iso_ago 3600)" --arg nx "$(iso_ago -80000)" '{project:"project-5",rows:[{ticket_key:"24",verdict:"queued",waiting_on:"team",
  verdict_hash:$h,triaged_at:$at,next_recheck_at:$nx,reason:"DECISION defer: classifier still returns hold:title; #50 remains open"}]}' > "$T/r24.json"
triage_state_put "$T/r24.json" >/dev/null || bad "(RT) could not write the legacy row"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 24 3)" = llm ] && ok || bad "(RT) a legacy defer whose reason ref has merged goes to the model: [$(dcol 24 3) $(dcol 24 4)]"

# ═══ DEFER TTL — a defer-like verdict naming NO ref is re-checked sooner ══════
# A defer whose reason names a ref is re-offered by the hash when that ref moves,
# so it keeps the 24h TTL; the short recheck is for defers that wait on
# something no ref names (a harness code change).
iss 28 "Waits on a harness change" "the classifier needs a deploy"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-28 :: defer :: waiting on the harness classifier deploy, attempt #2\n' > "$T/o28.txt"
ts_after_session "$H" "$P" 0 "$T/o28.txt" >/dev/null 2>&1
TA=$(row 28 triaged_at); NX=$(row 28 next_recheck_at)
[ "$(( $(epoch_of "$NX") - $(epoch_of "$TA") ))" = 7200 ] && ok \
  || bad "(DT) a queued verdict naming no ref (\"attempt #2\" is a count, not a ref) rechecks at +TRIAGE_STATE_DEFER_TTL_S (7200): [$TA -> $NX]"
# TEST-CHANGE (BH-3921): rows 22 and 21 were recorded by earlier sessions in
# this suite at the default TTL, which is now 0: a ref-naming defer and a
# non-defer verdict get NO timer (no next_recheck_at), where they used to keep
# the 24h TTL. The TTL > 0 sweep is pinned by (t) and the new suite's T4.
TA=$(row 22 triaged_at); NX=$(row 22 next_recheck_at)
[ -n "$TA" ] && [ -z "$NX" ] && ok \
  || bad "(DT) a queued verdict whose reason names a ref (#51) has no timer at TTL 0: [$TA -> $NX]"
TA=$(row 21 triaged_at); NX=$(row 21 next_recheck_at)
[ -n "$TA" ] && [ -z "$NX" ] && ok \
  || bad "(DT) a non-defer verdict has no timer at TTL 0: [$TA -> $NX]"
# rows stamped under the old 24h recheck: the no-ref defer is due after defer_ttl,
# the ref-naming defer and a non-defer of the same age are not
for k in 28 22 11; do
  sql "UPDATE triage_state SET triaged_at='$(iso_ago 10800)', next_recheck_at='$(iso_ago -75600)' WHERE project='$P' AND ticket_key='$k'" >/dev/null
done
tick_env shadow; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 28 3) $(dcol 28 4)" = "llm recheck-due" ] && ok \
  || bad "(DT) a no-ref defer older than defer_ttl goes back to the model: [$(dcol 28 3) $(dcol 28 4)]"
# TEST-CHANGE (BH-3921): a due recheck no longer forces a read: 28's row did not
# move, so its thread is NOT re-read, and it is still `llm recheck-due` above.
! grep -qE "repos/$SLUG/issues/28\$" "$T/calls/gh" && ok || bad "(DT) and its unmoved thread is NOT re-read (the session reads it)"
[ "$(dcol 22 3)" = skip ] && ok || bad "(DT) a defer naming a ref, same age, is not due: [$(dcol 22 3) $(dcol 22 4)]"
[ "$(dcol 11 3)" = skip ] && ok || bad "(DT) a non-defer verdict of the same age is not due: [$(dcol 11 3) $(dcol 11 4)]"
# the knob resolves from the DB settings row (lib.triage-state.triage_state_defer_ttl_s),
# through the settings cache lib_env_apply reads, not only from the environment
sql "UPDATE triage_state SET triaged_at='$(iso_ago 10800)', next_recheck_at='$(iso_ago -75600)' WHERE project='$P' AND ticket_key='28'" >/dev/null
cp -f "$H/state/settings-cache.json" "$T/settings.keep" 2>/dev/null || rm -f "$T/settings.keep"
printf '{"fetched_at":%s,"values":{"lib.triage-state.triage_state_defer_ttl_s":"14400"},"seeded":{}}' "$(date -u +%s)" > "$H/state/settings-cache.json"   # determinism: ok — a fresh cache
tick_env shadow; unset TRIAGE_STATE_DEFER_TTL_S; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 28 3)" = skip ] && ok || bad "(DT) the settings row triage_state_defer_ttl_s=14400 keeps a 3h-old defer: [$(dcol 28 3) $(dcol 28 4)]"
if [ -e "$T/settings.keep" ]; then mv -f "$T/settings.keep" "$H/state/settings-cache.json"; else rm -f "$H/state/settings-cache.json"; fi

# ═══ REASON REFS — a legacy row whose ref is not looked up yet ═══════════════
# (the fetch cap / a low budget): decided unchanged, NOT re-stamped; re-stamped
# on a later tick once the ref is looked up and still open.
jq -n '{issue:{number:62,title:"infra 2",body:"x",state:"open",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/62.json"
iss 27 "Legacy, ref off the board" "nothing named"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
B27=$(dcol 27 8)
jq -n --arg h "$B27" --arg at "$(iso_ago 3600)" --arg nx "$(iso_ago -80000)" '{project:"project-5",rows:[{ticket_key:"27",verdict:"queued",waiting_on:"team",
  verdict_hash:$h,triaged_at:$at,next_recheck_at:$nx,reason:"DECISION defer: blocked until #62 is deployed"}]}' > "$T/r27.json"
triage_state_put "$T/r27.json" >/dev/null || bad "(RC) could not write the legacy row"
tick_env shadow; export TRIAGE_STATE_MAX_FETCH=0; : > "$T/calls/gh"; ( ts_precheck ) >/dev/null 2>&1; unset TRIAGE_STATE_MAX_FETCH
[ "$(dcol 27 3) $(dcol 27 4)" = "skip unchanged:queued" ] && ok \
  || bad "(RC) a legacy row whose ref the cap left unread is decided unchanged: [$(dcol 27 3) $(dcol 27 4)]"
[ "$(row 27 verdict_hash)" = "$B27" ] && ok || bad "(RC) and is NOT re-stamped while its ref is absent: [$(row 27 verdict_hash)]"
! grep -qE "repos/$SLUG/issues/62\$" "$T/calls/gh" && ok || bad "(RC) the cap reads nothing"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 27 3)" = skip ] && [ "$(row 27 verdict_hash)" = "$(dcol 27 5)" ] && [ "$(dcol 27 5)" != "$B27" ] && ok \
  || bad "(RC) a later tick looks the ref up (OPEN) and re-stamps: [$(dcol 27 3) $(dcol 27 4)] [$(row 27 verdict_hash)]"

# ═══ SHOULD 3 — the post-session lookup never stamps a SETTLED state ════════
# The new reason names #63, off the board and never looked up; by the time the
# session ends it is CLOSED. It may have closed after the model read it, so the
# stamp keeps it `absent` and the next tick re-offers the ticket once.
jq -n '{issue:{number:63,title:"old infra",body:"x",state:"closed",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/63.json"
iss 26 "Waits on old infra" "nothing named"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-26 :: defer :: wait for #63\n' > "$T/o26.txt"
: > "$T/calls/gh"; ts_after_session "$H" "$P" 0 "$T/o26.txt" >/dev/null 2>&1
grep -qE "repos/$SLUG/issues/63\$" "$T/calls/gh" && ok || bad "(PS) the new reason's off-board ref is looked up after the session"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 26 3) $(dcol 26 4)" = "llm changed" ] && ok \
  || bad "(PS) a ref found settled after the session is not stamped settled: the ticket is re-offered once: [$(dcol 26 3) $(dcol 26 4)]"

# ═══ MUST 2 — a shard stamps against ITS dispatch snapshot, not a later tick ══
# The shard re-triages "defer until #70" while #70 is open; before it records,
# the next tick's pre-check sees #70 merged (world.json, refs.json and
# decisions.tsv rewritten). The following pre-check must re-offer the ticket.
echo '[{"number":51,"head":{"sha":"a51","ref":"fix/other"},"title":"another fix","state":"open"},
       {"number":70,"head":{"sha":"a70","ref":"fix/seventy"},"title":"the fix 25 waits on","state":"open"}]' > "$T/fx/pulls.json"
iss 25 "Waits on a fix, named only in the reason" "nothing named"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
H25=$(ts_shard_hash 25 2>/dev/null || ts_hash_of 25)   # the dispatch (bin/lib/rt/shards.sh)
echo '[{"number":51,"head":{"sha":"a51","ref":"fix/other"},"title":"another fix","state":"open"}]' > "$T/fx/pulls.json"
jq -n '{issue:{number:70,title:"the fix",body:"x",state:"closed",labels:[],comments:0,pull_request:{merged_at:"2026-09-28T19:00:00Z"},updated_at:"2026-09-28T19:00:00Z"},comments:[]}' > "$T/fx/extra/70.json"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1                 # the next tick, while the shard runs
printf 'tickets=1\nDECISION: TK-25 :: defer :: until #70 lands\n' > "$T/o25.txt"
ts_after_session "$H" "$P" 0 "$T/o25.txt" 25 "$H25" >/dev/null 2>&1   # the shard records late
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 25 3)" = llm ] && ok \
  || bad "(SS) a shard that recorded after #70 merged must not stamp the merged state: the ticket goes to the model: [$(dcol 25 3) $(dcol 25 4)]"
[ ! -d "$H/state/triage-state/$P/snap/25.$H25" ] && ok || bad "(SS) the shard's snapshot is removed once it recorded"
grep -q 'ts_shard_hash "\$K"' "$DIR/bin/lib/rt/shards.sh" && ok || bad "(SS) the dispatcher snapshots per shard (ts_shard_hash)"

# ═══ NOTE 1 — NOT_A_REF only drops a WHOLE word before #N ════════════════════
NAR=$(python3 - "$PY" <<'PYX'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ts", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for t in ["bypass #3165", "PR number #3165", "workaround #3165", "checkpoint #12", "entry #40", "attempt #2", "round #3"]:
    print(f"{t}={int(m.reason_names_refs(True, t, 'TS', '999'))}")
PYX
)
case "$(printf '%s\n' "$NAR" | tr '\n' ' ')" in
  "bypass #3165=1 PR number #3165=1 workaround #3165=1 checkpoint #12=1 entry #40=1 attempt #2=0 round #3=0 ") ok ;;
  *) bad "(N1) only a whole count word drops a #N (bypass/number/workaround/checkpoint/entry are refs; attempt/round are not): $(printf '%s' "$NAR" | tr '\n' ' ')" ;;
esac

# ═══ NOTE 2 — two dispatches of one key+hash never share a snapshot ══════════
iss 29 "Dispatched twice" "nothing named"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
D29A=$(ts_shard_hash 29 2>/dev/null)
iss 31 "Unrelated new ticket" "moves only the fingerprint"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1                 # the next tick; 29's hash is unchanged
D29B=$(ts_shard_hash 29 2>/dev/null)
SD="$H/state/triage-state/$P/snap"
N29=$(find "$SD" -mindepth 1 -maxdepth 1 -name '29.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$D29A" != "$D29B" ] && [ "$N29" = 2 ] && ok || bad "(N2) a second dispatch of the same key+hash gets its own snapshot: [$D29A] [$D29B] n=$N29"
A_WORLD=$(find "$SD" -mindepth 1 -maxdepth 1 -name "29.*" 2>/dev/null | while read -r x; do grep -c '"number":31' "$x/world.json"; done | sort | tr '\n' ' ')
[ "$A_WORLD" = "0 1 " ] && ok || bad "(N2) the first dispatch's snapshot is not overwritten by the second: [$A_WORLD]"
printf 'tickets=1\nDECISION: TK-29 :: skip :: fine\n' > "$T/o29.txt"
ts_after_session "$H" "$P" 0 "$T/o29.txt" 29 "$D29A" >/dev/null 2>&1
[ "$(find "$SD" -mindepth 1 -maxdepth 1 -name '29.*' | wc -l | tr -d ' ')" = 1 ] && ok || bad "(N2) a shard removes only its own snapshot"
ts_after_session "$H" "$P" 0 "$T/o29.txt" 29 "$D29B" >/dev/null 2>&1
[ -z "$(find "$SD" -mindepth 1 -maxdepth 1 -name '29.*')" ] && ok || bad "(N2) and the second removes its own"

# ═══ NOTE 3 — the single session stamps the refs as the PRE-CHECK left them ══
# A concurrent writer (a shard's recorder) puts #90 MERGED into refs.json after
# the pre-check; the single session's stamp must not bake that in.
jq -n '{issue:{number:90,title:"x",body:"x",state:"open",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/90.json"
iss 32 "Single session" "nothing named"
world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
jq '. + {"90":"MERGED"}' "$H/state/triage-state/$P/refs.json" > "$T/r.t" && mv "$T/r.t" "$H/state/triage-state/$P/refs.json"
printf 'tickets=1\nDECISION: TK-32 :: defer :: until #90\n' > "$T/o32.txt"
ts_after_session "$H" "$P" 0 "$T/o32.txt" >/dev/null 2>&1
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 32 3)" = llm ] && ok || bad "(N3) a ref state written after the pre-check is not stamped by the single session: [$(dcol 32 3) $(dcol 32 4)]"

# ═══ NOTE 4 — leaked temps are swept after 24h ══════════════════════════════
TD="$H/state/triage-state/$P"
for f in refs.priv.AbC123 refs.json.XyZ789 refs.fetched.QwE456 ref.RtY012; do : > "$TD/$f"; touch -d '2 days ago' "$TD/$f"; done   # determinism: ok — an aged leak
: > "$TD/refs.priv.fresh1"
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(cd "$TD" && ls refs.priv.AbC123 refs.json.XyZ789 refs.fetched.QwE456 ref.RtY012 2>/dev/null)" ] && [ -e "$TD/refs.priv.fresh1" ] && [ -s "$TD/refs.json" ] && ok \
  || bad "(N4) the pre-check sweeps temps older than 24h, keeps fresh ones and refs.json: $(cd "$TD" && ls refs* ref.* 2>/dev/null | tr '\n' ' ')"
rm -f "$TD/refs.priv.fresh1"

# ═══ MUST 1 — concurrent ref fetchers never cache each other's state ═════════
# Two fetchers (a shard's recorder and a pre-check) look up different refs at
# the same time, the slow one's REST body landing after the fast one's. Each
# must cache its own ref's state, and neither may lose the other's entry.
jq -n '{issue:{number:81,title:"open one",body:"x",state:"open",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/81.json"
jq -n '{issue:{number:82,title:"closed one",body:"x",state:"closed",labels:[],comments:0,updated_at:"2026-09-01T00:00:00Z"},comments:[]}' > "$T/fx/extra/82.json"
RF="$T/cc/refs.json"; mkdir -p "$T/cc"
fetch_one() { # fetch_one <n> — one fetcher, in its own process, as a recorder would run it
  ( d="$T/cc"; refs="$RF"; max=30; nf=0; slug=$SLUG; fetched=0; _ts_libs
    printf '%s\n' "$1" > "$T/cc/n.$1"; _ts_fetch_refs "$T/cc/n.$1" )
}
CCBAD=""
for i in 1 2 3 4 5 6; do
  echo '{}' > "$RF"
  GH_STUB_SLEEP_81=0.6 GH_STUB_SLEEP_82=0.1 fetch_one 81 & A=$!
  sleep 0.2
  GH_STUB_SLEEP_81=0.6 GH_STUB_SLEEP_82=0.1 fetch_one 82 & B=$!
  wait "$A" "$B"
  [ "$(jq -c -S . "$RF" 2>/dev/null)" = '{"81":"OPEN","82":"CLOSED"}' ] || CCBAD="$CCBAD [$i: $(cat "$RF" 2>/dev/null | tr -d ' \n')]"
done
[ -z "$CCBAD" ] && ok || bad "(CC) two concurrent fetchers each cache their own ref, and both entries survive:$CCBAD"

# ═══ CLOSED-TICKET LOOP (enforce, 2026-09-28 22:34Z+) ═══════════════════════
# A closed ticket goes to the model once (`llm closed`); the model answers
# `skip` / `comment` ("already closed by mergify"), verdict_of maps that to
# `triaged`, and the next tick sends it again, forever (BH-3316, BH-3320). The
# recorder stamps `closed` for a ticket closed in this tick's world, whatever
# the action; the shard path included.
closeiss() { local f="$T/fx/issues/$1.json"; jq --arg at "${2:-}" '.issue.state="closed" | (if $at != "" then .issue.closed_at=$at else . end)' "$f" > "$f.t" && mv "$f.t" "$f"; }
for n in 34 35; do iss "$n" "Closes by PR $n" "fixed by a PR"; done
world; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=2\nDECISION: TK-34 :: skip :: fine\nDECISION: TK-35 :: skip :: fine\n' > "$T/o3435.txt"
ts_after_session "$H" "$P" 0 "$T/o3435.txt" >/dev/null 2>&1
closeiss 34; closeiss 35; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
# TEST-CHANGE (closed stamp in the pre-check): a closed ticket is no longer sent to
# the model (`llm closed`, which looped: no session ever ran for it); the
# pre-check stamps it `closed` itself, so the expectation here moves with it.
[ "$(dcol 34 3) $(dcol 34 4)|$(dcol 35 3) $(dcol 35 4)" = "stamp closed-on-board|stamp closed-on-board" ] && ok \
  || bad "(CL) precondition: both closed tickets are stamped by the pre-check: [$(dcol 34 3) $(dcol 34 4)|$(dcol 35 3) $(dcol 35 4)]"
# the shard form (enforce dispatches each llm key as a shard)
S34=$(ts_shard_hash 34 2>/dev/null || ts_hash_of 34); S35=$(ts_shard_hash 35 2>/dev/null || ts_hash_of 35)
printf 'tickets=1\nDECISION: TK-34 :: skip :: PR #3345 merged and issue closed\n' > "$T/o34.txt"
printf 'tickets=1\nDECISION: TK-35 :: comment :: PR #3343 merged 22:31Z and issue auto-closed\n' > "$T/o35.txt"
ts_after_session "$H" "$P" 0 "$T/o34.txt" 34 "$S34" >/dev/null 2>&1
ts_after_session "$H" "$P" 0 "$T/o35.txt" 35 "$S35" >/dev/null 2>&1
[ "$(row 34 verdict)|$(row 35 verdict)" = "closed|closed" ] && ok \
  || bad "(CL) a closed ticket is stamped closed whatever the action (skip, comment): [$(row 34 verdict)|$(row 35 verdict)]"
case "$(row 35 reason)" in *"PR #3343 merged"*) ok ;; *) bad "(CL) the model's reason text is kept: [$(row 35 reason)]" ;; esac
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(dcol 34 3)$(dcol 35 3)" ] && ok || bad "(CL) the next tick does not send them again: [$(dcol 34 3) $(dcol 34 4)|$(dcol 35 3) $(dcol 35 4)]"
# the single-session form, a skip on a closed ticket
iss 36 "Closes too" "x"; world; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-36 :: skip :: fine\n' > "$T/o36.txt"; ts_after_session "$H" "$P" 0 "$T/o36.txt" >/dev/null 2>&1
closeiss 36; world; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-36 :: skip :: already closed by mergify\n' > "$T/o36.txt"; ts_after_session "$H" "$P" 0 "$T/o36.txt" >/dev/null 2>&1
[ "$(row 36 verdict)" = closed ] && ok || bad "(CL) the single session stamps a closed ticket closed on a skip: [$(row 36 verdict)]"
# reopening moves the hash: back to the model
f="$T/fx/issues/34.json"; jq '.issue.state="open"' "$f" > "$f.t" && mv "$f.t" "$f"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 34 3) $(dcol 34 4)" = "llm changed" ] && ok || bad "(CL) a reopened ticket goes to the model: [$(dcol 34 3) $(dcol 34 4)]"
# BACKSTOP: the world carries closedAt, and the row holds a model verdict stamped
# after it (a recorder that predates the stamp-closed rule): skip unchanged
iss 37 "Closed, triaged after" "x"; iss 38 "Closed, triaged before" "x"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
for n in 37 38; do
  jq -n --arg k "$n" --arg h "$(dcol $n 5)" --arg at "$([ $n = 37 ] && echo 2026-09-28T12:00:00Z || echo 2026-09-28T08:00:00Z)" \
    '{project:"project-5",rows:[{ticket_key:$k,verdict:"triaged",waiting_on:"none",verdict_hash:$h,input_hash:$h,triaged_at:$at,next_recheck_at:"2099-01-01T00:00:00Z",reason:"DECISION skip: closed"}]}' > "$T/r$n.json"
  triage_state_put "$T/r$n.json" >/dev/null || bad "(CL) could not write row $n"
done
closeiss 37 2026-09-28T11:00:00Z; closeiss 38 2026-09-28T11:00:00Z; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
# TEST-CHANGE (closed stamp in the pre-check): a closed ticket is no longer sent to
# the model (`llm closed`, which looped: no session ever ran for it); the
# pre-check stamps it `closed` itself, so the expectation here moves with it.
[ "$(dcol 37 3) $(dcol 37 4)|$(dcol 38 3) $(dcol 38 4)" = "stamp closed-on-board|stamp closed-on-board" ] && ok \
  || bad "(CL) closed tickets are stamped whether their verdict predates closedAt or not: [$(dcol 37 3) $(dcol 37 4)|$(dcol 38 3) $(dcol 38 4)]"

# ═══ CLOSED STAMP IN THE PRE-CHECK (no model call) ═════════════════════════
# #3388 stamped `closed` only when a model session ran for the closed ticket,
# and none does (every shard is a pr-NNNN or an open ticket): BH-3316, 3320,
# 2649, 2652, 3321 stayed `triaged` and "to the model" every enforce tick. The
# pre-check now stamps a ticket CLOSED in this tick's world `closed` itself.
iss 39 "Closed by its merge" "x"; world; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
printf 'tickets=1\nDECISION: TK-39 :: skip :: fine\n' > "$T/o39.txt"; ts_after_session "$H" "$P" 0 "$T/o39.txt" >/dev/null 2>&1
[ "$(row 39 verdict)" = triaged ] && ok || bad "(CS) precondition: a stored triaged row: [$(row 39 verdict)]"
closeiss 39; iss 41 "Closed before any triage" "x"; closeiss 41; world
: > "$H/logs/$P.log"; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 39 3) $(dcol 39 4)|$(dcol 41 3) $(dcol 41 4)" = "stamp closed-on-board|stamp closed-on-board" ] && ok \
  || bad "(CS) a closed ticket (triaged row, or no row at all) is stamped by the pre-check: [$(dcol 39 3) $(dcol 39 4)|$(dcol 41 3) $(dcol 41 4)]"
case " $(llm_set)" in *" 39 "*|*" 41 "*) bad "(CS) a stamped closed ticket is never in the model set: [$(llm_set)]" ;; *) ok ;; esac
[ "$(row 39 verdict)|$(row 41 verdict)" = "closed|closed" ] && [ "$(row 39 reason)" = "closed on the board; stamped without a model call" ] && ok \
  || bad "(CS) the rows say closed, with the no-model reason: [$(row 39 verdict)|$(row 41 verdict)] [$(row 39 reason)]"
grep -qE "triage-state shadow: stamped [0-9]+ closed ticket\(s\) without a model call:.* TK-39" "$H/logs/$P.log" && ok \
  || bad "(CS) the stamp is logged: $(grep triage-state "$H/logs/$P.log")"
grep -q "to the model:.*TK-39" "$H/logs/$P.log" && bad "(CS) and never listed under to the model" || ok
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ -z "$(dcol 39 3)$(dcol 41 3)" ] && ok || bad "(CS) the next tick does not list them: [$(dcol 39 3)|$(dcol 41 3)]"
f="$T/fx/issues/39.json"; jq '.issue.state="open" | del(.issue.closed_at)' "$f" > "$f.t" && mv "$f.t" "$f"; world
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(dcol 39 3) $(dcol 39 4)" = "llm changed" ] && ok || bad "(CS) a reopened stamped ticket goes to the model: [$(dcol 39 3) $(dcol 39 4)]"

# ═══ the kill switch, and a dead worker ════════════════════════════════════
touch "$H/flags/triage-state-off"; : > "$H/logs/$P.log"
tick_env enforce
OUTK=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$OUTK" in *CONTINUED*) ok ;; *) bad "(x) the kill switch makes the pre-check a no-op" ;; esac
! grep -q triage-state "$H/logs/$P.log" && ok || bad "(x) the kill switch logs nothing"
rm -f "$H/flags/triage-state-off"
# TEST-CHANGE (BH-3921): an unreachable worker no longer fails open under enforce; the tick is skipped (BH-3925)
WORKER_UP=0; tick_env enforce
OUTD=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUTD" in *CONTINUED*) bad "(x) an unreachable worker under enforce skips the tick, no model call [$OUTD]" ;; *) ok ;; esac
case "$OUTD" in *"TRIAGE STATE"*) bad "(x) a skipped tick appends nothing to the prompt [$OUTD]" ;; *) ok ;; esac
grep -q 'rows unreadable — tick skipped' "$H/logs/$P.log" && ok || bad "(x) the skip is logged: $(cat "$H/logs/$P.log")"
[ "$(awk -F'\t' '$3=="llm"' "$H/state/triage-state/$P/decisions.tsv" | grep -c rows-unreadable)" -ge 5 ] && ok \
  || bad "(x) with no rows every ticket goes to the model: $(decisions | tr '\n' ' ')"
WORKER_UP=1

# ═══ the wiring ════════════════════════════════════════════════════════════
awk '/^rt_shards\(\) \{/{f=1} f&&/# >>> triage shards/{exit} f' "$DIR/bin/lib/rt/shards.sh" | grep -q 'ts_tick' && ok \
  || bad "(w) rt_shards must call ts_tick BEFORE the shard units are formed"
grep -q 'ts_unit_skip "\$SHARD_UNITS" "\$K"' "$DIR/bin/lib/rt/shards.sh" && ok || bad "(w) the shard loop must ask ts_unit_skip per key"
grep -q 'TSH_TS_HASH=' "$DIR/bin/lib/rt/shards.sh" && ok || bad "(w) a shard must be handed the hash it is triaging against"
grep -q 'ts_after_session' "$DIR/bin/lib/rt/launch.sh" && ok || bad "(w) the single session must record its verdicts"
grep -q 'ts_after_session' "$DIR/bin/triage-shard.sh" && ok || bad "(w) a shard must record its verdict"
grep -q -- '--thread' "$DIR/bin/triage-gate.sh" && ok || bad "(w) bin/triage-gate.sh must serve --thread"

echo "triage-state-precheck: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
