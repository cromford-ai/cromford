#!/bin/bash
# tests/ledger-stages.bh-3498-test.sh — BH-3498 (BH-3481.1): two build-ledger
# rows that used to stop at `planning` now end at an honest stage.
#
# 1. A size-gate split. The parent's run ends with RESULT DECOMPOSED and no
#    build beat after the plan, so its console row sat at `planning` forever
#    (BH-3417). The DECOMPOSED arm now beats `decomposed` first. Fail-open: a
#    missing beat.sh never costs the RESULT line.
# 2. br_resolve_ticket_merged. It marks every build dir of a merged ticket
#    `.blocked-resolver-superseded`, and those dirs' rows sat at whatever stage
#    they died at. Each one now beats `superseded`, except the dir that merged
#    (PR_MERGED, or a RESULT naming the merged url) and a hub MIRROR of a pool
#    build (BUILD_DIR:/BUILT_AS: names another dir), whose basename is no row's
#    bkey — a beat there would invent a phantom row.
#
# Driven through the shipped text: the size-gate block extracted verbatim by
# its markers from the flattened pipeline, the REAL BB() from gates.sh (only its
# beat.sh path rewritten into scratch), and the two resolver functions extracted
# verbatim. The beat.sh stub records every payload. No network, no model, no gh.
#   HARNESS_TEST_SANDBOX=1 bash tests/ledger-stages.bh-3498-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog" "$T/h/builds"
for S in size-scope.sh size-threshold.sh size-gate.sh planned-files.sh; do
  [ -f "$DIR/bin/$S" ] && cp "$DIR/bin/$S" "$T/h/bin/"
done

# The recording beat.sh: every payload to beats.jsonl, and the stage in order
# next to the RESULT lines in seq.txt.
cat > "$T/beat.sh" <<EOS
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats.jsonl"
echo "BEAT \$(printf '%s' "\$1" | jq -r '.stage')" >> "$T/seq.txt"
exit 0
EOS
chmod +x "$T/beat.sh"
arm_beat()    { cp "$T/beat.sh" "$T/h/bin/beat.sh"; }
disarm_beat() { rm -f "$T/h/bin/beat.sh"; }
arm_beat

cat > "$T/h/bin/run-decompose.sh" <<'EOS'
#!/bin/bash
case "${DRC:-0}" in
  0) printf 'BH-9.1\nBH-9.2\n' > "$4/children.txt"; exit 0 ;;
  3) echo 'DECOMPOSE_HELD x' > "$4/decompose-run.txt"; exit 3 ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$T/h/bin/run-decompose.sh"

# ============================================================================
# The size-gate DECOMPOSED arm
# ============================================================================
awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' "$RB_ALL" > "$T/sizeblock.sh"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' "$RB_ALL" > "$T/switch.sh"
awk '/^BB\(\) \{/,/^\}/' "$DIR/bin/lib/rb/gates.sh" | sed "s#/root/harness/bin/beat.sh#$T/h/bin/beat.sh#" > "$T/bb.sh"
[ -s "$T/sizeblock.sh" ] && ok || bad "could not extract the size-gate block"
[ -s "$T/switch.sh" ] && ok || bad "could not extract the size enforce switch"
grep -q "$T/h/bin/beat.sh" "$T/bb.sh" && ok || bad "could not extract the real BB() from gates.sh: $(cat "$T/bb.sh")"

BN=widget-os-WD-9-202609290000
BKEY="build:widget-os:WD-9:$BN"
drive() { # drive <block-file> [env...] — prints nothing; rc in $RC, seq/beats in $T
  local block="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b/$BN"
  printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 6\nLINES: 900\n\nKIND: feature\nSIZE: M\n' \
    > "$T/b/$BN/plan.md"
  : > "$T/seq.txt"
  # The row's last beat before the gate was `planning`, as on a real parent.
  jq -nc --arg b "$BKEY" '{kind:"build",bkey:$b,project:"widget-os",ticket_key:"WD-9",stage:"planning"}' > "$T/beats.jsonl"
  ( env HARNESS="$T/h" BUILD="$T/b/$BN" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 BKEY="$BKEY" \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SIZE_GATE_ENFORCE=1 \
        SWITCHBLOCK="$T/switch.sh" BBBLOCK="$T/bb.sh" SEQ="$T/seq.txt" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT $*" >> "$SEQ"; }
             job_artifact_put() { :; }
             . "$BBBLOCK"
             . "$SWITCHBLOCK"
             . "$0"; echo CONTINUED >> "$SEQ"' "$block" >/dev/null 2>&1 )
  RC=$?
}
dec_beats() { jq -c 'select(.stage=="decomposed")' "$T/beats.jsonl" 2>/dev/null; }

# D1 — DRC=0: one decomposed beat on the parent's row, before RESULT.
drive "$T/sizeblock.sh" DRC=0
[ "$RC" = 0 ] && ok || bad "D1: the DECOMPOSED arm must exit 0 (rc=$RC)"
grep -q CONTINUED "$T/seq.txt" && bad "D1: a split must not reach EXECUTE: $(cat "$T/seq.txt")" || ok
[ "$(dec_beats | grep -c .)" = 1 ] && ok || bad "D1: want exactly one decomposed beat: $(cat "$T/beats.jsonl")"
B=$(dec_beats | head -1)
[ "$(jq -r '[.kind,.bkey,(.merged|tostring),.project,.ticket_key,.detail]|join("|")' <<<"${B:-null}" 2>/dev/null)" \
  = "build|$BKEY|false|widget-os|WD-9|split into BH-9.1,BH-9.2" ] \
  && ok || bad "D1: wrong decomposed beat payload: $B"
BL=$(grep -n '^BEAT decomposed$' "$T/seq.txt" | cut -d: -f1 | head -1)
RL=$(grep -n '^RESULT DECOMPOSED BH-9.1,BH-9.2$' "$T/seq.txt" | cut -d: -f1 | head -1)
[ -n "$BL" ] && [ -n "$RL" ] && [ "$BL" -lt "$RL" ] \
  && ok || bad "D1: the decomposed beat must come before the RESULT: $(cat "$T/seq.txt")"
LAST=$(jq -r --arg b "$BKEY" 'select(.bkey==$b) | .stage' "$T/beats.jsonl" | tail -1)
[ -n "$LAST" ] && [ "$LAST" != planning ] && ok || bad "D1: the row's last stage is still '$LAST'"

# D1b — fail-open: no beat.sh at all, the RESULT and the rc are unchanged.
disarm_beat
drive "$T/sizeblock.sh" DRC=0
[ "$RC" = 0 ] && ok || bad "D1b: a missing beat.sh must not change the rc (rc=$RC)"
grep -qx 'RESULT DECOMPOSED BH-9.1,BH-9.2' "$T/seq.txt" \
  && ok || bad "D1b: a missing beat.sh must not cost the RESULT: $(cat "$T/seq.txt")"
arm_beat

# D2 — the other two arms beat nothing new.
drive "$T/sizeblock.sh" DRC=1
[ -z "$(dec_beats)" ] && ok || bad "D2: a failed split must not beat decomposed"
grep -q '^RESULT DECOMPOSE_FAILED ' "$T/seq.txt" && ok || bad "D2: DRC=1 RESULT: $(cat "$T/seq.txt")"
drive "$T/sizeblock.sh" DRC=3
[ "$RC" = 3 ] && ok || bad "D2: a held split must exit 3 (rc=$RC)"
[ -z "$(dec_beats)" ] && ok || bad "D2: a held split must not beat decomposed"
grep -q '^RESULT BUILD_DEFERRED held at split ' "$T/seq.txt" && ok || bad "D2: DRC=3 RESULT: $(cat "$T/seq.txt")"

# M1 — the mutant (the BB decomposed line deleted) must FAIL D1.
grep -q 'BB decomposed' "$T/sizeblock.sh" && ok || bad "M1: no 'BB decomposed' line in the shipped block"
sed '/BB decomposed/d' "$T/sizeblock.sh" > "$T/sizeblock.mut.sh"
drive "$T/sizeblock.mut.sh" DRC=0
[ -z "$(dec_beats)" ] && ok || bad "M1: the mutant still beats decomposed — D1 is vacuous"
[ "$(jq -r --arg b "$BKEY" 'select(.bkey==$b) | .stage' "$T/beats.jsonl" | tail -1)" = planning ] \
  && ok || bad "M1: the mutant's row should still read planning"

# ============================================================================
# br_resolve_ticket_merged — superseded beats
# ============================================================================
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
{ awk '/^br_row_closed\(\) \{/,/^\}/' "$T/br-corpus.sh"
  awk '/^br_resolve_ticket_merged\(\) \{/,/^\}/' "$DIR/bin/blocked-resolver.sh"; } > "$T/resolver.sh"
grep -q '^br_resolve_ticket_merged() {' "$T/resolver.sh" && grep -q '^br_row_closed() {' "$T/resolver.sh" \
  && ok || bad "could not extract the resolver functions"

MURL=https://github.com/o/widget-os/pull/77
H="$T/h"
seed() { # seed — the three S1 dirs, fresh
  scratch_rm "$H/builds"; mkdir -p "$H/builds/widget-os-WD-9-1" "$H/builds/widget-os-WD-9-2" "$H/builds/widget-os-WD-9-3"
  echo 'PLAN_BLOCKED x' > "$H/builds/widget-os-WD-9-1/RESULT"
  echo "PR_MERGED $MURL" > "$H/builds/widget-os-WD-9-3/RESULT"
  : > "$T/beats.jsonl"
}
resolve() { # resolve <observe> <murl>
  ( H="$H" OBSERVE="$1" RES="$T/resolver.sh" MU="$2" bash -c '
      STAMP() { echo TS; }; say() { :; }; br_record() { :; }; br_set_outcome() { :; }
      queue_done() { :; }
      . "$RES"
      br_resolve_ticket_merged widget-os widget-os-WD-9 merge-failed-twice WD-9 "$MU" -' >/dev/null 2>&1 )
}
bkeys() { jq -r '.bkey // "NONE"' "$T/beats.jsonl" 2>/dev/null | sort | paste -sd' '; }

# S1 — PLAN_BLOCKED and no-RESULT dirs beat superseded; the merged dir does not.
seed; resolve 0 "$MURL"
[ "$(grep -c . "$T/beats.jsonl")" = 2 ] && ok || bad "S1: want 2 beats: $(cat "$T/beats.jsonl")"
[ "$(bkeys)" = "build:widget-os:WD-9:widget-os-WD-9-1 build:widget-os:WD-9:widget-os-WD-9-2" ] \
  && ok || bad "S1: wrong bkeys: $(bkeys)"
[ "$(jq -r 'select(.stage!="superseded" or .merged!=false or .kind!="build") | 1' "$T/beats.jsonl" | grep -c .)" = 0 ] \
  && ok || bad "S1: every beat must be build/superseded/merged:false: $(cat "$T/beats.jsonl")"
[ "$(jq -r --arg d "superseded: WD-9 already merged via $MURL" 'select(.detail!=$d) | 1' "$T/beats.jsonl" | grep -c .)" = 0 ] \
  && ok || bad "S1: wrong detail: $(cat "$T/beats.jsonl")"
for n in 1 2 3; do
  [ -f "$H/builds/widget-os-WD-9-$n/.blocked-resolver-superseded" ] && ok || bad "S1: dir -$n lost its marker"
done

# S1b — a RESULT that names the merged url (not PR_MERGED) is the merged dir too.
seed; echo "PR_CREATED $MURL" > "$H/builds/widget-os-WD-9-3/RESULT"; resolve 0 "$MURL"
grep -q 'widget-os-WD-9-3' "$T/beats.jsonl" && bad "S1b: the dir naming $MURL must not be beaten" || ok
[ "$(grep -c . "$T/beats.jsonl")" = 2 ] && ok || bad "S1b: want 2 beats: $(cat "$T/beats.jsonl")"

# S2 — observe mode: nothing sent, nothing marked.
seed; resolve 1 "$MURL"
[ ! -s "$T/beats.jsonl" ] && ok || bad "S2: observe mode sent beats: $(cat "$T/beats.jsonl")"
grep -q blocked-resolver-superseded <<<"$(ls -a "$H"/builds/*/)" && bad "S2: observe mode wrote markers" || ok

# S3 — hub mirrors of pool builds keep the marker and get no beat.
seed
mkdir -p "$H/builds/pool-widget-os-WD-9-4" "$H/builds/widget-os-WD-9-remote6"
printf 'PLAN_BLOCKED x\nBUILD_DIR: widget-os-WD-9-5\n' > "$H/builds/pool-widget-os-WD-9-4/RESULT"
printf 'PLAN_BLOCKED x\nBUILT_AS: widget-os-WD-9-7\n' > "$H/builds/widget-os-WD-9-remote6/RESULT"
resolve 0 "$MURL"
for d in pool-widget-os-WD-9-4 widget-os-WD-9-remote6; do
  [ -f "$H/builds/$d/.blocked-resolver-superseded" ] && ok || bad "S3: mirror $d lost its marker"
done
grep -qE 'pool-|remote' <<<"$(jq -r '.bkey // ""' "$T/beats.jsonl")" \
  && bad "S3: a mirror dir was beaten: $(bkeys)" || ok
[ "$(grep -c . "$T/beats.jsonl")" = 2 ] && ok || bad "S3: want only the 2 real rows: $(bkeys)"

# S4 — an empty merged url must not skip every dir (grep -F "" matches all).
seed; resolve 0 ""
grep -q '"build:widget-os:WD-9:widget-os-WD-9-1"' "$T/beats.jsonl" \
  && ok || bad "S4: an empty murl skipped dir -1: $(cat "$T/beats.jsonl")"
grep -q 'widget-os-WD-9-3' "$T/beats.jsonl" && bad "S4: the PR_MERGED dir was beaten" || ok

echo "ledger-stages.bh-3498: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
