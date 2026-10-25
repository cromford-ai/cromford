#!/bin/bash
# tests/prequeue-gate-row.bh-8062-test.sh — BH-8062 T1: shape B. The merge
# conductor no longer dispatches .github/workflows/prequeue-gate.yml for a READY
# PR once an operator sets the existing knob MC_PREQUEUE_GATE to 0. No seed
# row ships for `lane.merge-conductor.mc_prequeue_gate` (review 5641193259,
# option 1): the code fallback 1 keeps the CI pre-queue gate on until the pool
# gate runs green, and one row (value 0) turns the dispatch off.
#
# Every case runs the REAL pq_gate (bin/lib/mc-prequeue.sh) with the real hooks
# (mc-prequeue.d/dispatch.sh, status.sh), the real lane_knob
# (bin/lib/lane-gate.sh) over a settings cache, and a stub gh / gh_rest.
#
#   R   the composed schema, served as the worker serves it: it has no
#       mc_prequeue_gate row, so a READY PR gets exactly 1 dispatch, answer hold
#   G0  global row 0: 0 dispatch, no prequeue file, no could-not-run, no alert,
#       prequeue-verdict published success "gate off", answer proceed
#   H   row 0 still runs pq_restamp and pq_mignum: H0 both called, H1-H4 a
#       pushed/held answer from either hook holds the PR, H5 an unreadable
#       main tip holds (the hooks never run on a guessed main), H6 neither
#       hook can act: proceed with no main tip read, H7 only pq_mignum can act
#   G1  global row 1: exactly 1 `gh workflow run prequeue-gate.yml`, a pending
#       entry, answer hold
#   F   no row, no env: the registry default 1, one dispatch (the fallback)
#   N   row "off" (not a number): pq_knob's default 1, one dispatch
#   P   per-project row 1 over a global 0: dispatch for that project only
#   S   the composed schema holds no lane.merge-conductor.mc_prequeue_gate row
#       and no lane.merge-conductor.<project>.mc_prequeue_gate row
#   S2  the composed schema seeds NO lane.lead-review.lead_review_gate_record
#       row: the code fallback block applies (r3 F3: a fix round refreshes the
#       selection-gate record, so no note seed hides the refusal)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-gate-row.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
python3 -I -c 'import sqlite3' 2>/dev/null || { echo "python3 sqlite3 missing — skipping"; exit 0; }

NOW=1792814400   # 2026-10-24T00:00:00Z, the settings cache's fetched_at
KEY=lane.merge-conductor.mc_prequeue_gate
PKEY=lane.merge-conductor.cromford.mc_prequeue_gate
SLUG=example-org/demo-os
HEAD1=$(printf 'e%.0s' $(seq 40))
MAIN=$(printf 'c%.0s' $(seq 40))

# The registry, rendered once from catalog/lanes.d (git-ignored render).
REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || REG=""
[ -r "$REG" ] || { echo "FAIL: setup: catalog/lanes.json could not be rendered"; exit 1; }

# The composed schema, applied to a scratch sqlite db.
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
  || bad "setup: bin/schema-build.sh --to failed"
python3 -I - "$T/schema.sql" "$T/db.sqlite" <<'PY' || bad "setup: the composed schema does not apply to sqlite"
import sqlite3, sys
db = sqlite3.connect(sys.argv[2]); db.executescript(open(sys.argv[1]).read()); db.commit()
PY

# cache <case> <values-json> — the box settings cache lane_knob reads.
cache() {
  mkdir -p "$T/$1/state"
  jq -nc --argjson fa "$NOW" --argjson v "$2" '{fetched_at:$fa, values:$v, seeded:{}}' > "$T/$1/state/settings-cache.json"
}

# gate <case> [project] — one READY head through the real pq_gate.
#   Sinks: $C/gh (every gh argv), $C/status (published statuses), $C/out
#   (the answer and PQ_WHY), $C/state/prequeue/ (the store), $C/logs/ALERTS.log.
gate() {
  local c="$1" p="${2:-}"
  local C="$T/$c"
  mkdir -p "$C/state" "$C/tick" "$C/tmp" "$C/logs" "$C/bin"
  : > "$C/gh"; : > "$C/status"; : > "$C/log"; : > "$C/hooks"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
  ( export HARNESS="$C" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL='' TMPDIR="$C/tmp"
    P="$p"; MC_H="$C"; MC_STATE_DIR="$C/state"; MC_TICK_ID=t8062; MC_TICK_DIR="$C/tick"; MC_LOG="$C/mclog"
    . "$DIR/bin/lib/lane-gate.sh" || exit 1
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"
    . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
    mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$C/log"; }
    mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_use_token() { :; }
    vs_publish() { printf '%s %s %s\n' "$LEAD_VERDICT_CONTEXT" "$3" "$4" >> "$C/status"; }
    # The two pre-queue migration hooks record each call; RS_WORD / MN_WORD set
    # their answer (default none); RS_WANT / MN_WANT=0 says the hook cannot act.
    pq_restamp_wanted() { [ "${RS_WANT:-1}" = 1 ]; }
    pq_restamp() { echo restamp >> "$C/hooks"; echo "${RS_WORD:-none}"; }
    pq_mignum_wanted() { [ "${MN_WANT:-1}" = 1 ]; }
    pq_mignum() { echo mignum >> "$C/hooks"; echo "${MN_WORD:-none}"; }
    pq_adopt_run() { return 1; }
    pq_impact_reuse() { _pq_ir=none; }; pq_dispatch_veto() { return 1; }
    gh() { printf '%s\n' "$*" >> "$C/gh"; return 0; }
    gh_rest() {
      case "$2" in
        */commits/*) echo tip >> "$C/tipreads"; [ -n "${TIP_DOWN:-}" ] && return 75; printf '{"sha":"%s"}' "$MAIN" ;;
        */actions/workflows/prequeue-gate.yml) printf '{}' ;;
        */runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    pq_gate "$SLUG" 71 "https://github.com/$SLUG/pull/71" "$HEAD1" main > "$C/word"
    printf 'word=%s why=%s\n' "$(cat "$C/word")" "$PQ_WHY" > "$C/out"
  ) > "$C/err" 2>&1
}
dispatches() { grep -c '^workflow run prequeue-gate.yml ' "$T/$1/gh" 2>/dev/null; }
store() { find "$T/$1/state/prequeue" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ── R: the composed schema, served as the worker serves it ───────────────────
# GET /api/settings returns every row with its actor; lane-gate keeps rows whose
# actor is not `registry-seed` as values. A schema.d seed row has actor `seed`.
ROWS=$(python3 -I - "$T/db.sqlite" <<'PY'
import sqlite3, sys, json
db = sqlite3.connect(sys.argv[1])
try:
    rows = db.execute("SELECT key, value FROM settings WHERE actor != 'registry-seed' AND key LIKE 'lane.merge-conductor.%'").fetchall()
except Exception:
    rows = []
print(json.dumps({k: v for k, v in rows}))
PY
)
cache r "${ROWS:-{\}}"; gate r ""
[ "$(dispatches r)" = 1 ] && ok || bad "R the composed schema has no mc_prequeue_gate row: a READY PR gets exactly 1 prequeue-gate.yml dispatch (got $(dispatches r); $(cat "$T/r/out" "$T/r/err" 2>/dev/null))"
grep -q '^word=hold ' "$T/r/out" 2>/dev/null && ok || bad "R the composed schema: the answer is hold ($(cat "$T/r/out" 2>/dev/null))"

# ── G0: global row 0 ─────────────────────────────────────────────────────────
cache g0 "{\"$KEY\":\"0\"}"; gate g0 ""
[ "$(dispatches g0)" = 0 ] && ok || bad "G0 row 0: no dispatch (got $(dispatches g0))"
[ ! -s "$T/g0/gh" ] && ok || bad "G0 row 0: no gh call at all ($(cat "$T/g0/gh"))"
[ "$(store g0)" = 0 ] && ok || bad "G0 row 0: nothing written under prequeue/ (got $(store g0))"
! grep -rqs could-not-run "$T/g0/state" "$T/g0/log" "$T/g0/logs" && ok || bad "G0 row 0: no could-not-run record or line"
[ ! -s "$T/g0/logs/ALERTS.log" ] && ok || bad "G0 row 0: no alert ($(cat "$T/g0/logs/ALERTS.log" 2>/dev/null))"
grep -qx 'prequeue-verdict success gate off' "$T/g0/status" && ok || bad "G0 row 0: prequeue-verdict success \"gate off\" ($(cat "$T/g0/status"))"
grep -q '^word=proceed ' "$T/g0/out" 2>/dev/null && ok || bad "G0 row 0: proceed ($(cat "$T/g0/out" "$T/g0/err" 2>/dev/null))"

# ── H: row 0 keeps the pre-queue migration hooks (refute r3) ──────────────────
# The row turns off only the verdict and the dispatch. pq_restamp (BH-6842) and
# pq_mignum (BH-7671) still run, and their push or refusal still holds the PR.
hooks() { tr '\n' ' ' < "$T/$1/hooks" 2>/dev/null | sed 's/ $//'; }
[ "$(hooks g0)" = "restamp mignum" ] && ok || bad "H0 row 0: pq_restamp and pq_mignum both run (got '$(hooks g0)')"
cache h1 "{\"$KEY\":\"0\"}"; RS_WORD="pushed $MAIN 1" gate h1 ""
grep -q '^word=hold why=restamped 1 schema fragment' "$T/h1/out" && ok || bad "H1 row 0: a restamp push holds ($(cat "$T/h1/out" "$T/h1/err" 2>/dev/null))"
[ "$(dispatches h1)" = 0 ] && [ "$(hooks h1)" = restamp ] && ok || bad "H1 row 0: no dispatch, mignum not reached (gh: $(cat "$T/h1/gh"); hooks: $(hooks h1))"
cache h2 "{\"$KEY\":\"0\"}"; RS_WORD="held lock busy" gate h2 ""
grep -q '^word=hold why=schema restamp held: lock busy' "$T/h2/out" && ok || bad "H2 row 0: a restamp refusal holds ($(cat "$T/h2/out" 2>/dev/null))"
cache h3 "{\"$KEY\":\"0\"}"; MN_WORD="pushed $MAIN 2" gate h3 ""
grep -q '^word=hold why=renumbered 2 migration' "$T/h3/out" && ok || bad "H3 row 0: a migration renumber push holds ($(cat "$T/h3/out" "$T/h3/err" 2>/dev/null))"
[ "$(hooks h3)" = "restamp mignum" ] && [ "$(dispatches h3)" = 0 ] && ok || bad "H3 row 0: both hooks ran, no dispatch (hooks: $(hooks h3))"
cache h4 "{\"$KEY\":\"0\"}"; MN_WORD="held a renumber rebase is queued on the pool" gate h4 ""
grep -q '^word=hold why=migration number check held: ' "$T/h4/out" && ok || bad "H4 row 0: a migration number refusal holds ($(cat "$T/h4/out" 2>/dev/null))"
! grep -q 'gate off' "$T/h4/status" && ok || bad "H4 a hold publishes no 'gate off' status ($(cat "$T/h4/status"))"
cache h5 "{\"$KEY\":\"0\"}"; TIP_DOWN=1 gate h5 ""
grep -q '^word=hold why=main tip unreadable' "$T/h5/out" && ok || bad "H5 row 0: an unreadable main tip holds, the hooks cannot run blind ($(cat "$T/h5/out" 2>/dev/null))"
[ -z "$(hooks h5)" ] && ok || bad "H5 no hook runs without a main tip (got '$(hooks h5)')"
cache h6 "{\"$KEY\":\"0\"}"; RS_WANT=0 MN_WANT=0 gate h6 ""
grep -q '^word=proceed ' "$T/h6/out" && [ -z "$(hooks h6)" ] && [ ! -s "$T/h6/tipreads" ] && ok \
  || bad "H6 row 0, neither hook can act: proceed, no hook, no main tip read ($(cat "$T/h6/out"); hooks '$(hooks h6)'; tip reads $(wc -l < "$T/h6/tipreads" 2>/dev/null))"
grep -qx 'prequeue-verdict success gate off' "$T/h6/status" && ok || bad "H6 publishes \"gate off\" ($(cat "$T/h6/status"))"
cache h7 "{\"$KEY\":\"0\"}"; RS_WANT=0 MN_WORD="pushed $MAIN 1" gate h7 ""
grep -q '^word=hold why=renumbered 1 migration' "$T/h7/out" && [ "$(hooks h7)" = "restamp mignum" ] && ok \
  || bad "H7 row 0, only pq_mignum can act: the tip is read and its push holds ($(cat "$T/h7/out"); hooks '$(hooks h7)')"

# ── G1: global row 1 (the rollback) ──────────────────────────────────────────
cache g1 "{\"$KEY\":\"1\"}"; gate g1 ""
[ "$(dispatches g1)" = 1 ] && ok || bad "G1 row 1: exactly one dispatch (got $(dispatches g1); $(cat "$T/g1/gh" "$T/g1/err" 2>/dev/null))"
grep -q "^workflow run prequeue-gate.yml -R $SLUG --ref main -f pr=71 -f head=$HEAD1 -f main=$MAIN" "$T/g1/gh" && ok || bad "G1 the dispatch names this PR, head and main ($(cat "$T/g1/gh"))"
F1=$(find "$T/g1/state/prequeue" -type f -name "*_71_${HEAD1}_${MAIN}" 2>/dev/null | head -1)
[ -n "$F1" ] && grep -q '^pending ' "$F1" && ok || bad "G1 a pending entry for (71, head, main) ($(find "$T/g1/state" -type f 2>/dev/null))"
grep -q '^word=hold ' "$T/g1/out" 2>/dev/null && ok || bad "G1 the answer is hold ($(cat "$T/g1/out" 2>/dev/null))"

# ── F: no row, no env — the documented code fallback 1 ───────────────────────
cache f '{}'; gate f ""
[ "$(dispatches f)" = 1 ] && ok || bad "F no row: the fallback 1 dispatches once (got $(dispatches f))"

# ── N: a non-numeric row is not the ticket's word ────────────────────────────
cache n "{\"$KEY\":\"off\"}"; gate n ""
[ "$(dispatches n)" = 1 ] && ok || bad "N row 'off': pq_knob falls back to 1 and dispatches (got $(dispatches n))"

# ── P: a per-project row over the global one ─────────────────────────────────
cache p "{\"$KEY\":\"0\",\"$PKEY\":\"1\"}"; gate p cromford
[ "$(dispatches p)" = 1 ] && ok || bad "P project row 1 over global 0: cromford dispatches (got $(dispatches p))"
cache p2 "{\"$KEY\":\"0\",\"$PKEY\":\"1\"}"; gate p2 demo-os
[ "$(dispatches p2)" = 0 ] && ok || bad "P another project keeps the global 0 (got $(dispatches p2))"

# ── S: no mc_prequeue_gate seed row in the composed schema (option 1) ────────
GOT=$(python3 -I - "$T/db.sqlite" <<'PY' 2>&1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
r = db.execute("SELECT key FROM settings WHERE key LIKE 'lane.merge-conductor.%mc_prequeue_gate' ORDER BY key").fetchall()
print(",".join(k for (k,) in r) or "none")
PY
)
[ "$GOT" = "none" ] && ok || bad "S the composed schema holds no global or per-project mc_prequeue_gate row (got '$GOT')"

# ── S2: no seed row for the lead review's record check (r3, F3) ──────────────
GOT=$(python3 -I - "$T/db.sqlite" <<'PY' 2>&1
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
r = db.execute("SELECT value, actor FROM settings WHERE key='lane.lead-review.lead_review_gate_record'").fetchone()
print("%s/%s" % r if r else "none")
PY
)
[ "$GOT" = "none" ] && ok || bad "S2 lane.lead-review.lead_review_gate_record has no seed row (got '$GOT')"

echo "prequeue-gate-row.bh-8062: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
