#!/bin/bash
# tests/pool-reuse-clean-tree.bh-8896-test.sh — a reused pool machine hands the
# next job a clean build root, and a fix round's record never borrows another
# job's build dir (BH-8896).
#
# project-6-os, 2026-11-01: machine d8d99e47a11198 built TK-3496 (PR #3512,
# head 708294bb), was reused for FXR-1465 (the fix round for TK-3508 / #3511),
# and the FXR record carried TK-3496's reviewed-sha and pipeline.log: the reuse
# left builds/project-6-os-TK-3496-* on the machine, and pool_record_write took
# the newest build dir for a RESULT that names none.
#   R1  next_job_or_destroy (lifted verbatim) moves the previous key's build
#       dir into builds.prev/ before the handoff, and says it reused
#   R2  a dir of the NEXT key stays in builds/ (a same-key retry resumes)
#   R3  `BUILDSASIDE failed` destroys the machine and hands the row back once
#   R4  an empty cleanup answer (an older stub) reuses as before
#   R5  a second reuse replaces builds.prev/ (one generation)
#   R6  pool_record_write (lifted from fly/builder-runner.sh): an FXR key posts
#       no build dir; a build key with no BUILD_DIR line keeps the newest dir
#   R7  NKEY TK-1 does not keep TK-10's dir; a key that is not
#       [A-Za-z0-9._-]+ is never handed the machine
# The mexec stub runs the hub's command string locally, with /data/harness and
# /run/harness mapped into $T and pkill disabled. 0 network calls.
# Run from anywhere: bash tests/pool-reuse-clean-tree.bh-8896-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "pool-reuse-clean-tree.bh-8896: jq absent — skipping"; exit 0; }

# ── R1-R5, R7: the hub handoff, next_job_or_destroy lifted verbatim ──────────
NR="$T/nr"; M="$T/m"
mkdir -p "$NR/q" "$NR/pool" "$NR/bin" "$NR/local"
awk '/^next_job_or_destroy\(\) \{/,/^\}$/' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
grep -q 'REUSED=0' "$NR/fn.sh" && ok || bad "could not extract next_job_or_destroy from bin/fly-pool.sh"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"; chmod +x "$NR/bin/beat.sh"
# machine <dir names...> — a fresh machine tree whose builds/ holds those dirs
machine() {
  scratch_rm "$M" 2>/dev/null; mkdir -p "$M/data/harness/builds" "$M/run/harness"
  local d i=0
  for d in "$@"; do
    i=$((i+1)); mkdir -p "$M/data/harness/builds/$d"
    printf '708294bb%032d\n' "$i" > "$M/data/harness/builds/$d/reviewed-sha"
    printf 'pipeline of %s\n' "$d" > "$M/data/harness/builds/$d/pipeline.log"
    touch -d "2026-11-01 11:0$i:00" "$M/data/harness/builds/$d"
  done
  printf 'PR_CREATED x\n' > "$M/run/harness/RESULT"
}
# handoff <next key> [forced mexec answer for the cleanup] -> REUSED; logs in $NR
handoff() {
  local nkey="$1"
  rm -f "$NR/q"/*.json "$NR/pool"/*.json; : > "$NR/log"; : > "$NR/calls"
  jq -nc --arg k "$nkey" '{key:$k,ticket_id:"9",attempt:0}' > "$NR/q/next.json"
  jq -nc --arg k "${HKEY:-TK-1}" '{machine:"m1",key:$k}' > "$NR/pool/m1.json"
  REUSED=$(
    set +u
    HARNESS="$NR"; P=tproj; APP=app; FLY=/bin/false; ROWS_ONLY=1
    QDIR="$NR/q"; POOL="$NR/pool"; LOCAL="$NR/local"
    MID=m1; MSTATE=started; KEY="${HKEY:-TK-1}"; MF="$NR/pool/m1.json"; MACCT=max1
    FORCED="${2:-}"
    STAMP() { echo now; }; say() { echo "$*" >> "$NR/log"; }
    mexec() {
      local cmd="$2"
      echo "mexec $cmd" >> "$NR/calls"
      if [ -n "$FORCED" ] && [[ "$cmd" == *pool-slot-clean* ]]; then
        [ "$FORCED" = - ] || printf '%s\n' "$FORCED"; return 0
      fi
      cmd="${cmd//\/data\/harness/$M/data/harness}"; cmd="${cmd//\/run\/harness/$M/run/harness}"
      cmd="${cmd//pkill /: }"
      /bin/sh -c "$cmd"
    }
    mput() { echo "mput $3" >> "$NR/calls"; local r="${3//\/run\/harness/$M/run/harness}"; mkdir -p "${r%/*}"; cp "$2" "$r"; }
    queue_claim() { echo "claim $3" >> "$NR/calls"; return 0; }
    queue_release() { echo "release $2 $3" >> "$NR/calls"; return 0; }
    destroy_machine() { echo "destroy $1" >> "$NR/calls"; return 0; }
    push_preplan() { :; }; push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    . "$NR/fn.sh"
    next_job_or_destroy
    echo "$REUSED"
  )
}
c() { grep -c "$1" "$NR/calls" 2>/dev/null || true; }
B="$M/data/harness/builds"; PV="$M/data/harness/builds.prev"
newest() { ls -dt "$B"/* 2>/dev/null | head -1; }

# R1 THE POINT: the previous key's dir is moved aside, not handed on.
machine tproj-TK-1-202611011100
handoff FXR-9-abcdef12
[ "$REUSED" = 1 ] && ok || bad "R1: the machine must still be reused (REUSED=$REUSED; log: $(cat "$NR/log"))"
[ -e "$B/tproj-TK-1-202611011100" ] && bad "R1 THE POINT: the previous job's build dir is still in builds/ (newest: $(newest))" || ok
[ -z "$(newest)" ] && ok || bad "R1: builds/ must hold no other key's dir, newest is $(newest)"
[ -s "$PV/tproj-TK-1-202611011100/reviewed-sha" ] && ok || bad "R1: the dir must be in builds.prev/, not deleted: $(ls -R "$M/data/harness" 2>/dev/null | head -20)"
grep -q '^reused m1 for FXR-9-abcdef12 (was TK-1)' "$NR/log" && ok || bad "R1: no reuse line: $(cat "$NR/log")"
grep -q 'moved=1\|moved 1\|1 build dir' "$NR/log" && ok || bad "R1: the move is not logged: $(cat "$NR/log")"
[ -e "$M/run/harness/RESULT" ] && bad "R1: the previous RESULT is still on the machine" || ok
[ -s "$M/run/harness/job.json" ] && ok || bad "R1: the next job was not pushed"

# R2 the next key's own dir stays.
machine tproj-TK-1-202611011100 tproj-FXR-9-abcdef12-202611011150
handoff FXR-9-abcdef12
[ "$REUSED" = 1 ] && ok || bad "R2: REUSED=$REUSED"
[ -d "$B/tproj-FXR-9-abcdef12-202611011150" ] && ok || bad "R2: the next key's own dir must stay in builds/"
[ -e "$B/tproj-TK-1-202611011100" ] && bad "R2: TK-1's dir stayed in builds/" || ok
[ -e "$PV/tproj-FXR-9-abcdef12-202611011150" ] && bad "R2: the next key's dir was moved aside" || ok

# R3 a move that fails: the machine is destroyed, not reused.
machine tproj-TK-1-202611011100
handoff FXR-9-abcdef12 "BUILDSASIDE failed"
[ "$REUSED" = 0 ] && ok || bad "R3 THE POINT: a machine whose build dirs could not be moved was reused"
[ "$(c '^destroy m1')" = 1 ] && ok || bad "R3: the machine was not destroyed: $(cat "$NR/calls")"
[ "$(c '^release FXR-9-abcdef12')" = 1 ] && ok || bad "R3: the claimed row must go back exactly once: $(cat "$NR/calls")"
[ "$(c '^mput')" = 0 ] && ok || bad "R3: a job was pushed onto the machine"
grep -q 'could not be moved aside' "$NR/log" && ok || bad "R3: no say line: $(cat "$NR/log")"

# R4 an empty answer (a stub or a machine with an older tree): reuse as before.
machine tproj-TK-1-202611011100
handoff FXR-9-abcdef12 -
[ "$REUSED" = 1 ] && ok || bad "R4: an empty cleanup answer must reuse (REUSED=$REUSED)"
[ "$(c '^destroy')" = 0 ] && ok || bad "R4: destroyed on an empty answer"

# R5 one generation: a second reuse replaces builds.prev/.
machine tproj-TK-1-202611011100
handoff FXR-9-abcdef12
mkdir -p "$B/tproj-FXR-9-abcdef12-202611011200"; : > "$B/tproj-FXR-9-abcdef12-202611011200/pipeline.log"
handoff TK-2
[ "$REUSED" = 1 ] && ok || bad "R5: REUSED=$REUSED"
[ -d "$PV/tproj-FXR-9-abcdef12-202611011200" ] && ok || bad "R5: the last job's dir must be in builds.prev/: $(ls "$PV" 2>/dev/null)"
[ -e "$PV/tproj-TK-1-202611011100" ] && bad "R5: builds.prev/ must hold one generation only: $(ls "$PV")" || ok

# R7 prefix near miss, and a key that cannot be quoted safely.
machine tproj-TK-10-202611011100
HKEY=TK-10 handoff TK-1
[ "$REUSED" = 1 ] && ok || bad "R7: REUSED=$REUSED"
[ -e "$B/tproj-TK-10-202611011100" ] && bad "R7: NKEY TK-1 kept TK-10's dir (prefix near miss)" || ok
machine tproj-TK-1-202611011100
handoff 'bad key'
[ "$REUSED" = 0 ] && ok || bad "R7: a key with a space was handed the machine"
[ "$(c '^release bad key')" = 1 ] && ok || bad "R7: the row of a refused key must go back once: $(cat "$NR/calls")"
grep -q "^mexec .*bad key" "$NR/calls" && bad "R7: the refused key reached a machine command" || ok
machine tproj-TK-1-202611011100
handoff '../x'
[ "$REUSED" = 0 ] && ok || bad "R7: a key with a slash was handed the machine"

# ── R6: pool_record_write, lifted from fly/builder-runner.sh ─────────────────
RW="$T/rw"; mkdir -p "$RW/h/builds" "$RW/h/bin/lib" "$RW/h/logs"
awk '/^pool_record_write\(\) \{/,/^\}$/' "$DIR/fly/builder-runner.sh" > "$RW/fn.sh"
grep -q 'pool_record_put' "$RW/fn.sh" && ok || bad "could not extract pool_record_write from fly/builder-runner.sh"
cat > "$RW/h/bin/lib/pool-record.sh" <<EOF
pool_record_enabled() { echo 1; }
pool_record_put() { printf '%s\n' "\$5" > "$RW/put.bd"; printf '%s\n' "\$2" > "$RW/put.key"; return 0; }
EOF
mkdir -p "$RW/h/builds/tproj-TK-1-202611011100"; : > "$RW/h/builds/tproj-TK-1-202611011100/reviewed-sha"
# rw <key> <result line> — runs the lifted function; the 5th put arg in $RW/put.bd
rw() {
  rm -f "$RW/put.bd" "$RW/put.key"
  jq -nc --arg k "$1" '{key:$k}' > "$RW/job.json"; printf '%s\n' "$2" > "$RW/RESULT"
  ( POOL_MODE=1 JOB="$RW/job.json" RESULT_FILE="$RW/RESULT" HARNESS="$RW/h" PROJECT=tproj FLY_MACHINE_ID=m1
    log() { :; }
    . "$RW/fn.sh"; pool_record_write )
}
rw FXR-9-abcdef12 "FIX_ROUND_FINISHED terminal finish=ok"
[ "$(cat "$RW/put.key" 2>/dev/null)" = FXR-9-abcdef12 ] && ok || bad "R6: the FXR record must still be posted"
[ -e "$RW/put.bd" ] && [ -z "$(cat "$RW/put.bd")" ] && ok || bad "R6 THE POINT: an FXR record borrowed build dir '$(cat "$RW/put.bd" 2>/dev/null)'"
rw TK-2 "PR_CREATED https://github.com/o/r/pull/2"
[ "$(cat "$RW/put.bd" 2>/dev/null)" = "$RW/h/builds/tproj-TK-1-202611011100" ] && ok || bad "R6: a build key with no BUILD_DIR line keeps the newest-dir fallback, got '$(cat "$RW/put.bd" 2>/dev/null)'"
rw TK-2 "$(printf 'PR_CREATED x\nBUILD_DIR: /root/harness/builds/tproj-TK-2-1')"
[ "$(cat "$RW/put.bd" 2>/dev/null)" = "$RW/h/builds/tproj-TK-2-1" ] && ok || bad "R6: BUILD_DIR: is read for a build key, got '$(cat "$RW/put.bd" 2>/dev/null)'"

echo "pool-reuse-clean-tree.bh-8896: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
