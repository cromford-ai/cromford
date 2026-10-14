#!/bin/bash
# tests/alert-triage-hooks.bh-2544-test.sh — the CONTRACT slice of BH-2544
# (BH-2568): the four hook points bin/alert-triage.sh gained for deterministic
# alert settlement, the two stubs they call, the table and the knobs.
#
# This slice changes NO behaviour, so what is proved here is the WIRING the
# siblings build on:
#   * the family-registry runner is called with three args, and not at all
#     under flags/triage-registry-off; a non-zero rc logs one line and the tick
#     goes on;
#   * triage_close_ids is reached for step0 and for settle (after the
#     NOISE-STALE log lines), and neither is reached under flags/triage-close-off;
#   * a family the runner writes to <removed-fams-out> is put back at its
#     pre-tick stamp, including on the empty-FILTERED early exit;
#   * the REAL lib (BH-2570 filled it in) extracts only resolved:/superseded:/
#     verify: dbrow ids, and the REAL runner with no registry to read (this
#     scratch has no jobs client) fails open: a tick with nothing to close
#     leaves the same families file, spool and prompts as a tick with both
#     hooks switched off, and the same log but for the runner's one
#     `REGISTRY unavailable` line (BH-2572).
#
# Seed rows, verify scripts and the lane's knobs are DISCOVERED (BH-4608): a
# family or knob ticket adds its row, script or knob and edits nothing here.
# Its own assertions go in its own tests/<area>.bh-<N>-test.sh. Edit this suite
# only when the hook WIRING it pins changes.
#
# It runs the REAL bin/alert-triage.sh in a scratch harness, the way
# tests/alert-triage-spool-age.bh-979-test.sh does. agent-call, gh-pr-state,
# ssh, flock and timeout are stubbed; the close lib and the runner are
# recording fakes except in blocks 5, 6 and 11, which use the real ones.
#   bash tests/alert-triage-hooks.bh-2544-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REAL_LIB="$DIR/bin/lib/triage-close.sh"
REAL_RUNNER="$DIR/bin/triage-family-scripts.sh"

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub" "$T/calls" "$T/tmp"
: > "$H/env/global.env"
LOGF="$H/logs/alert-triage.log"
FAMF="$H/state/alert-families.json"
SPOOL="$H/state/alert-triage-deferred.tsv"
# BH-5942: project "fleet" is not in fleet.conf, so the cromford run owns
# the line. reset seeds the shared files above (the dispatch routes the legacy
# spool; the run seeds its brake file by copy); the run writes these.
HP="$H/state/alert-triage/cromford"
PFAMF="$HP/alert-families.json"
PSPOOL="$HP/deferred.tsv"

for s in alert-triage.sh triage-spool-retire.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
cp "$H/bin/triage-spool-retire.sh" "$T/retire-real.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1

# --- stubs --------------------------------------------------------------------
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=1 escalated=0 noise=0" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/sh\nexit 75\n' > "$H/bin/gh-pr-state.sh"; chmod +x "$H/bin/gh-pr-state.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

# Recording fakes. The close fake records whether the ids file it was handed
# exists, and how many NOISE-STALE lines the lane log held at that moment: the
# ordering "log first, then write" is read off that count.
cat > "$T/fake-lib.sh" <<STUB
triage_close_ids() { echo "close \$1 \$([ -f "\$2" ] && echo exists || echo missing) noise=\$(grep -c NOISE-STALE "$LOGF" 2>/dev/null)" >> "\$CALLDIR/close"; return 0; }
triage_settled_ids() { echo "settled \$# \$([ -f "\$2" ] && echo exists || echo missing)" >> "\$CALLDIR/close"; return 0; }
STUB
# The fake runner sources \$T/runner-mode (when present) with the three args.
cat > "$T/fake-runner.sh" <<STUB
#!/bin/bash
echo "runner \$#" >> "\$CALLDIR/runner"
[ -f "$T/runner-mode" ] && . "$T/runner-mode"
exit 0
STUB
chmod +x "$T/fake-runner.sh"

use_fakes() { cp "$T/fake-lib.sh" "$H/bin/lib/triage-close.sh"; cp "$T/fake-runner.sh" "$H/bin/triage-family-scripts.sh"; }
use_real()  { cp "$REAL_LIB" "$H/bin/lib/triage-close.sh"; cp "$REAL_RUNNER" "$H/bin/triage-family-scripts.sh"; chmod +x "$H/bin/triage-family-scripts.sh"; }

# --- fixture ------------------------------------------------------------------
NOW=1790467200   # 2026-09-26T22:40:00Z
RAW=$(printf 'hub\t%s\t{"kind":"fleet_alert","project":"fleet","akey":"orclane:bh2544","line":"the widget subsystem is unhappy"}' "$((NOW - 3600))")
# The family key the lane itself will compute, never a typed one (D4).
FKEY=$(cd "$DIR/bin" && python3 -c 'import sys; from alert_family import family; print(family(sys.argv[1]))' "$RAW")
[ -n "$FKEY" ] || { echo "FAIL: could not compute the fixture's family key"; exit 1; }

reset() {
  triage_tick_reset "$H"; : > "$LOGF"; : > "$H/logs/ALERTS.log"; : > "$H/logs/cost.csv"
  echo '{}' > "$FAMF"; printf '%s\n' "$RAW" > "$SPOOL"
  : > "$H/state/alert-quarantine.jsonl"
  rm -f "$H"/flags/triage-registry-off "$H"/flags/triage-close-off "$T/runner-mode"
  rm -f "$H"/state/alert-triage-expired-*.tsv "$H"/flags/alerted-spoolretire-* "$H/state/triage-prstate.json"
  scratch_rm "$T/calls"; mkdir -p "$T/calls"
  use_fakes
}
RC=0
run() {
  TMPDIR="$T/tmp" TRIAGE_NOW="$NOW" TRIAGE_MAX_FAMILIES=20 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
  RC=$?
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
# The lane writes stamps as floats (1000.0), so they are compared as integers.
stamp_of() { jq -r --arg k "$FKEY" 'if .[$k] == null then "absent" else (.[$k] | floor | tostring) end' "$PFAMF"; }

# ---------- 1. the runner is called with three args ---------------------------
reset; run
[ "$(cat "$T/calls/runner" 2>/dev/null)" = "runner 3" ] && ok \
  || bad "1: the runner must be called once with 3 args (got: $(cat "$T/calls/runner" 2>/dev/null))"
[ "$RC" = 0 ] && ok || bad "1: the tick exits 0 (got $RC)"

# ---------- 2. flags/triage-registry-off: no runner ---------------------------
reset; touch "$H/flags/triage-registry-off"; run
[ ! -e "$T/calls/runner" ] && ok || bad "2: triage-registry-off must skip the runner (got: $(cat "$T/calls/runner"))"
[ "$(ncalls)" = 1 ] && ok || bad "2: the family still gets its session (got $(ncalls))"

# ---------- 2b. runner rc!=0: one log line, the tick goes on ------------------
reset; echo 'exit 3' > "$T/runner-mode"; run
[ "$(grep -c 'family registry rc=3' "$LOGF")" = 1 ] && ok \
  || bad "2b: exactly one 'family registry rc=3' log line (got $(grep -c 'family registry rc=3' "$LOGF"))"
[ "$RC" = 0 ] && ok || bad "2b: the tick exits 0 (got $RC)"
[ "$(ncalls)" = 1 ] && ok || bad "2b: the session still runs after a failed runner (got $(ncalls))"

# ---------- 3a/3b. step0 and settle close calls, settle after the log ---------
reset
# The runner settles the one line (the protocol's append format) and removes
# nothing, so the settlement block logs one NOISE-STALE line before (c).
cat > "$T/runner-mode" <<'M'
printf 'verify:bh2544: proof\t%s\n' "$(cut -f3- "$1" | head -1)" >> "$2"
M
run
grep -q '^close step0 exists ' "$T/calls/close" 2>/dev/null && ok \
  || bad "3a: triage_close_ids step0 <existing idsfile> must be called (got: $(cat "$T/calls/close" 2>/dev/null))"
SL=$(grep -n '^settled 2 exists' "$T/calls/close" 2>/dev/null | head -1 | cut -d: -f1)
CL=$(grep -n '^close settle exists ' "$T/calls/close" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$SL" ] && [ -n "$CL" ] && [ "$SL" -lt "$CL" ] && ok \
  || bad "3b: triage_settled_ids (2 args) must come before triage_close_ids settle (got: $(cat "$T/calls/close" 2>/dev/null))"
grep -q '^close settle exists noise=1$' "$T/calls/close" 2>/dev/null && ok \
  || bad "3b: the NOISE-STALE line must be logged BEFORE the settle close (got: $(grep settle "$T/calls/close" 2>/dev/null))"
S0=$(grep -n '^close step0' "$T/calls/close" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$S0" ] && [ -n "$SL" ] && [ "$S0" -lt "$SL" ] && ok || bad "3b: step0 comes before settle"

# ---------- 3c. flags/triage-close-off: no close calls, runner still runs -----
reset; touch "$H/flags/triage-close-off"; run
! grep -q '^close ' "$T/calls/close" 2>/dev/null && ok \
  || bad "3c: triage-close-off must skip both close calls (got: $(cat "$T/calls/close"))"
! grep -q '^settled ' "$T/calls/close" 2>/dev/null && ok || bad "3c: triage-close-off also skips triage_settled_ids"
[ "$(cat "$T/calls/runner" 2>/dev/null)" = "runner 3" ] && ok || bad "3c: the runner still runs under triage-close-off"

# ---------- 4a. removed family restored on the empty-FILTERED exit ------------
reset
jq -n --arg k "$FKEY" '{($k): 1000}' > "$FAMF"
printf 'printf "%%s\\n" "%s" > "$3"; : > "$1"\n' "$FKEY" > "$T/runner-mode"
run
[ "$(stamp_of)" = 1000 ] && ok || bad "4a: the removed family must be back at its pre-tick stamp 1000 (got $(stamp_of))"
[ "$(ncalls)" = 0 ] && ok || bad "4a: an emptied FILTERED takes the early exit, no session (got $(ncalls))"

# ---------- 4b. a never-seen removed family is popped -------------------------
reset
printf 'printf "%%s\\n" "%s" > "$3"; : > "$1"\n' "$FKEY" > "$T/runner-mode"
run
[ "$(stamp_of)" = absent ] && ok || bad "4b: a never-seen removed family must be absent afterwards (got $(stamp_of))"

# ---------- 4c. control: nothing in <removed-fams-out>, the stamp is NOW ------
reset
jq -n --arg k "$FKEY" '{($k): 1000}' > "$FAMF"
echo ': > "$1"' > "$T/runner-mode"
run
[ "$(stamp_of)" = "$NOW" ] && ok || bad "4c: control — without a removed key the splitter's stamp $NOW stays (got $(stamp_of))"

# ---------- 5. the REAL lib: settled ids, and no request with the flag off ---
# SPEC CHANGE (BH-2570): this pinned "both real stubs return 0 and write
# nothing" while the lib was the contract's stubs. BH-2570 is the sibling that
# implements them, so the real lib now extracts the dbrow id of a `resolved:`
# line and still makes no request and writes no file with ALERTS_DB unset.
mkdir -p "$T/empty"; printf 'a1\na2\n' > "$T/ids"
{ printf 'resolved:x\t{"dbrow":true,"alertid":"a9"}\n'; printf 'stale-akey:y\t{"dbrow":true,"alertid":"a8"}\n'; } > "$T/settled"
( cd "$T/empty" && unset ALERTS_DB && . "$REAL_LIB" && triage_close_ids settle "$T/ids" 2>/dev/null && triage_settled_ids "$T/settled" "$T/ids" )
[ $? = 0 ] && ok || bad "5: both real functions must return 0"
[ "$(cat "$T/ids")" = a9 ] && ok || bad "5: <idsout> holds the resolved: dbrow id a9 and not the stale-akey a8 (got: $(tr '\n' ' ' < "$T/ids"))"
[ -z "$(ls -A "$T/empty")" ] && ok || bad "5: the real lib must create no file in the cwd"

# ---------- 6. the REAL runner: 3 args rc 0 nothing changed, 2 args rc 64 -----
# HARNESS points at an empty scratch dir: the runner has no registry to read
# there and fails open, and it can never reach a live worker from this suite.
printf 'f\tt\t%s\n' "$RAW" > "$T/rf"; printf 'x\n' > "$T/rs"; printf 'y\n' > "$T/rr"
cp "$T/rf" "$T/rf.b"; cp "$T/rs" "$T/rs.b"; cp "$T/rr" "$T/rr.b"
HARNESS="$T/no-harness" "$REAL_RUNNER" "$T/rf" "$T/rs" "$T/rr" 2>/dev/null; R6=$?
[ "$R6" = 0 ] && ok || bad "6: the real runner exits 0 on three args (got $R6)"
cmp -s "$T/rf" "$T/rf.b" && cmp -s "$T/rs" "$T/rs.b" && cmp -s "$T/rr" "$T/rr.b" && ok \
  || bad "6: the real runner must leave all three files byte-identical"
"$REAL_RUNNER" "$T/rf" "$T/rs" 2>/dev/null; R6=$?
[ "$R6" = 64 ] && ok || bad "6: the real runner refuses two args with rc 64 (got $R6)"

# ---------- 7. schema: table, index, seed rows, idempotent, the runner seed
# SPEC CHANGE (BH-2570): the contract left lane.alert-triage.triage_runners
# unseeded (the operator, 2026-09-28: the runner-allowlist sibling that reads it
# decides its value). BH-2570 is that sibling and seeds claude,fireworks.
# SPEC CHANGE (BH-4608): the seed rows are DISCOVERED, never counted by hand.
# A family ticket adds its row to worker/jobs/schema.sql and its script to
# bin/alert-verify/ and edits nothing here: the check is that both applies
# leave the same rows, every verify names an executable bin/alert-verify/<v>.sh
# and every script there is named by a row (no orphans either way).
python3 - "$DIR/worker/jobs/schema.sql" "$DIR/bin/alert-verify" "$T/schema.out" <<'PY2'
import os, sqlite3, sys
sql = open(sys.argv[1]).read()
db = sqlite3.connect(":memory:")
db.executescript(sql)
once = db.execute("SELECT id,verify FROM alert_family_scripts ORDER BY id").fetchall()
db.execute("UPDATE alert_family_scripts SET note='operator-edit'")
db.executescript(sql)
kept = db.execute("SELECT count(*) FROM alert_family_scripts WHERE note IS NOT 'operator-edit'").fetchone()[0]
rows = db.execute("SELECT id,verify FROM alert_family_scripts ORDER BY id").fetchall()
cols = [r[1] for r in db.execute("PRAGMA table_info(alert_family_scripts)")]
idx = [r[1] for r in db.execute("PRAGMA index_list(alert_family_scripts)")]
val = db.execute("SELECT value FROM settings WHERE key='lane.alert-triage.triage_runners'").fetchone()
bad = 0
try:
    db.execute("INSERT INTO alert_family_scripts (id,match_kind,match,updated_at) VALUES ('x','nope','m','t')")
except sqlite3.IntegrityError:
    bad = 1
d = sys.argv[2]
named = {v for _, v in rows if v}
on_disk = {f[:-3] for f in os.listdir(d) if f.endswith(".sh")} if os.path.isdir(d) else set()
errs = []
if not rows: errs.append("no seed rows")
if once != rows: errs.append(f"second apply changed the rows ({len(once)} -> {len(rows)})")
if kept: errs.append(f"second apply overwrote {kept} operator-edited rows")
errs += [f"{i}: verify {v!r} has no executable {d}/{v}.sh" for i, v in rows if v and not os.access(os.path.join(d, v + ".sh"), os.X_OK)]
errs += [f"orphan {d}/{s}.sh: no seed row names it" for s in sorted(on_disk - named)]
open(sys.argv[3], "w").write(f"{','.join(cols)}|{'idx_alert_family_scripts_enabled_priority' in idx}|{val[0] if val else None}|{bad}|{'; '.join(errs) or 'rows-ok'}\n")
PY2
[ "$(cat "$T/schema.out" 2>/dev/null)" = "id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at|True|claude,fireworks|1|rows-ok" ] \
  && ok || bad "7: schema applies twice with the 11 columns, the index, the claude,fireworks triage_runners seed (BH-2570), seed rows that match bin/alert-verify/ both ways (BH-4608) and the match_kind CHECK (got: $(cat "$T/schema.out" 2>/dev/null))"

# ---------- 9. the knobs, as bin/lanes-build.sh composes them ------------------
# SPEC CHANGE (BH-4608): the four contract knobs are pinned BY NAME, and every
# other knob is discovered from catalog/lanes.d/alert-triage.json: each one
# must reach the composed registry unchanged. A new knob edits nothing here.
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1; then
  KQ='[.lanes[]|select(.id=="alert-triage")|.knobs[]|select(.env==$e)|[.type,.default,.min,.max]]'
  for row in 'TRIAGE_VERIFY_TIMEOUT_S ["int",20,1,120]' 'TRIAGE_VERIFY_MAX ["int",20,0,200]' \
             'TRIAGE_VERIFY_DEADLINE_S ["int",120,10,600]' 'TRIAGE_RUNNERS ["string","",null,null]'; do
    e=${row%% *}; K=$(jq -c --arg e "$e" "$KQ" "$T/lanes.json")
    [ "$K" = "[${row#* }]" ] && ok || bad "9: $e must be composed once with the ticket's type/default/min/max ${row#* } (got $K)"
  done
  MISS=$(jq -rn --slurpfile src "$DIR/catalog/lanes.d/alert-triage.json" --slurpfile reg "$T/lanes.json" '
    ([$reg[0].lanes[]|select(.id=="alert-triage")|.knobs[]|[.env,.type,.default,.min,.max]]) as $have
    | $src[0].knobs[] | [.env,.type,.default,.min,.max] | select(. as $k | $have | index([$k]) | not) | .[0]')
  [ -z "$MISS" ] && ok || bad "9: knobs declared in catalog/lanes.d/alert-triage.json but not composed as declared: $(echo $MISS)"
  # Not `bin/harness-ctl.sh show`: that answers from the LIVE worker's
  # /api/status, so it sees a knob only once the catalog is deployed. The
  # composed registry above is what `harness-ctl set` validates a knob against.
else
  bad "9: bin/lanes-build.sh could not compose the registry"
fi

# ---------- 10. the retire call gets TRIAGE_RETIRE_IDS_OUT --------------------
reset
cat > "$H/bin/triage-spool-retire.sh" <<STUB
#!/bin/bash
echo "ids=\${TRIAGE_RETIRE_IDS_OUT:-unset} file=\$([ -f "\${TRIAGE_RETIRE_IDS_OUT:-/nonexistent}" ] && echo yes || echo no)" >> "$T/calls/retire"
STUB
chmod +x "$H/bin/triage-spool-retire.sh"
run
grep -q '^ids=/.* file=yes$' "$T/calls/retire" 2>/dev/null && ok \
  || bad "10: the retire call must get TRIAGE_RETIRE_IDS_OUT naming an existing file (got: $(cat "$T/calls/retire" 2>/dev/null))"
cp "$T/retire-real.sh" "$H/bin/triage-spool-retire.sh"

# ---------- 11. no-op proof: real stubs == both hooks switched off ------------
# The runner is real now (BH-2572). This scratch has no jobs client, so it logs
# exactly one `triage pass: REGISTRY unavailable` line and changes nothing else;
# that line is counted, then dropped from the compare.
snap() {  # snap <dir> — what a tick leaves behind, timestamps stripped
  mkdir -p "$1"
  grep -c 'triage pass: REGISTRY' "$LOGF" > "$1/registry-lines"
  grep -v 'triage pass: REGISTRY' "$LOGF" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z/<ts>/g' > "$1/log"
  cp "$PFAMF" "$1/fam"; cp "$PSPOOL" "$1/spool" 2>/dev/null || : > "$1/spool"
  cat "$T"/calls/prompt-*.txt 2>/dev/null | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z/<ts>/g' > "$1/prompts"
}
reset; use_real; run; R11a=$RC; snap "$T/s-real"; cp "$LOGF" "$LOGF.real"
reset; use_real; touch "$H/flags/triage-registry-off" "$H/flags/triage-close-off"; run; R11b=$RC; snap "$T/s-off"
[ "$R11a" = 0 ] && [ "$R11b" = 0 ] && ok || bad "11: both ticks exit 0 (got $R11a/$R11b)"
[ -s "$T/s-real/log" ] && ok || bad "11: the real-stub tick must have logged something (vacuous otherwise)"
[ "$(cat "$T/s-real/registry-lines")" = 1 ] && grep -q 'triage pass: REGISTRY unavailable rc=' "$LOGF.real" && ok \
  || bad "11: the real runner logs exactly one REGISTRY unavailable line and nothing else (got $(cat "$T/s-real/registry-lines"))"
[ "$(cat "$T/s-off/registry-lines")" = 0 ] && ok || bad "11: hooks-off logs no REGISTRY line"
for f in log fam spool prompts; do
  cmp -s "$T/s-real/$f" "$T/s-off/$f" && ok || bad "11: $f differs between the real stubs and hooks-off: $(diff "$T/s-real/$f" "$T/s-off/$f" | head -5)"
done

# ---------- 12. no temp file outlives a tick ---------------------------------
for mode in plain remove; do
  reset; scratch_rm "$T/tmp"; mkdir -p "$T/tmp"
  [ "$mode" = remove ] && printf 'printf "%%s\\n" "%s" > "$3"; : > "$1"\n' "$FKEY" > "$T/runner-mode"
  run
  [ -z "$(ls -A "$T/tmp")" ] && ok || bad "12 ($mode): the tick left temp files behind: $(ls "$T/tmp" | head -5 | tr '\n' ' ')"
done

echo "alert-triage-hooks.bh-2544: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
