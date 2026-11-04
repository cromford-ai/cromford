#!/bin/bash
# tests/execute-empty.bh-9021-test.sh — BH-9021: the pool's EXECUTE_EMPTY cap
# counts only attempts that did not move the branch; a resumed build stopped by
# rule=time with a full tree is a normal execute result; an out-of-memory stop
# says EXECUTE_OOM and names the machine memory.
#
# THE INCIDENTS (project-6-os, 2026-11-03). TK-3552 attempt 1 pushed 6 commits
# before the no-progress stop, attempt 2 resumed them and was stopped by
# rule=time: two EXECUTE_EMPTY records, the cap of 2 held the key NEEDS_HUMAN,
# and the finished tree on ticket/TK-3552 never reached a PR. TK-3552 and
# TK-3575 also ran `npm run typecheck` / `npm test` into an OOM kill, and the
# stop reason said only what the model said last.
#
# Driven, not grepped:
#   A  ee_stop_check (the REAL bin/lib/execute-empty.sh) over hub records whose
#      RESULT line 1 carries, or does not carry, the [branch-head ...] token.
#   B  the REAL `# >>> execute result` block of bin/lib/rb/execute.sh and its
#      EE_HEAD_START line, on a scratch git repo with a bare origin: the RESULT
#      token names the start head and the head origin holds after the attempt;
#      the record then goes through ee_stop_check (round trip).
#   C  the same block: a resumed build stopped by rule=time whose branch
#      carries the work is a normal execute result; the near misses are not.
#   D  ee_on_empty / ee_oom on sessions rendered by the REAL
#      bin/transcript-render.sh: an OOM after a typecheck or test command
#      writes stop-reason.txt `EXECUTE_OOM: ...` and one alert line that names
#      the memory and the lane.fly-pool.<project>.vm_memory_mb row.
#   Z  no network stub was called.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/execute-empty.bh-9021-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
LIB="$DIR/bin/lib/execute-empty.sh"

# Network stubs: any call is a vendor call in a PR-path suite (BH-7563 item 6).
mkdir -p "$T/stubbin"
for c in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$c" "$T/net.log" > "$T/stubbin/$c"
  chmod +x "$T/stubbin/$c"
done
export PATH="$T/stubbin:$PATH"

# The scratch hub: the real render and scrub, fake alert and hold writers.
H="$T/h"; mkdir -p "$H/bin/lib" "$H/builds" "$H/logs"
ln -s "$DIR/bin/transcript-render.sh" "$H/bin/transcript-render.sh"
ln -s "$DIR/bin/transcript-scrub.sh" "$H/bin/transcript-scrub.sh"
ln -s "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
cat > "$H/bin/needs-human-hold.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOLDLOG"
exit 0
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
chmod +x "$H/bin/needs-human-hold.sh" "$H/bin/alert-line.sh"
mkdir -p "$T/envdir"; : > "$T/envdir/global.env"
NOW=1793750000
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40)); SHA_C=$(printf 'c%.0s' $(seq 40))

# GATE <key> -> rc of ee_stop_check project-6-os <key> 3552 (a GitHub-Issues board)
GATE() {
  ( export HARNESS="$H" EE_NOW="$NOW" HOLDLOG="$T/hold.log" ALERTLOG="$T/alert.log"
    say() { :; }
    # shellcheck disable=SC1090
    . "$DIR/bin/lib/tracker.sh"
    tracker_adapter() { echo github-issues; }
    trk_gh_issue_number() { echo 3552; }
    hold_check() { return 2; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    ee_stop_check project-6-os "$1" 3552 )
}
holds() { local c; c=$(grep -c . "$T/hold.log" 2>/dev/null); echo "${c:-0}"; }
# rec <key> <dir-suffix> <age-s> <result line 1> [line 2]
rec() {
  local d="$H/builds/pool-project-6-os-$1-$2"
  mkdir -p "$d"
  printf '%s\n' "$4" > "$d/RESULT"
  [ -n "${5:-}" ] && printf '%s\n' "$5" >> "$d/RESULT"
  printf 'the model stopped\n' > "$d/stop-reason.txt"
  touch -d "@$((NOW - $3))" "$d/RESULT"
}
reset_h() {
  local d; for d in "$H"/builds/*/; do [ -d "$d" ] && scratch_rm "${d%/}"; done
  rm -f "$T/hold.log" "$T/alert.log"
}
NH() { ls "$H"/builds/pool-project-6-os-"$1"-*/needs-human.md 2>/dev/null | head -1; }

NP_MOVED="EXECUTE_EMPTY EXECUTE_NO_PROGRESS: ceiling after 2400s, 26800000 of 53600000 context tokens, 0 files changed — transcript in execute-transcript.md [branch-head start=$SHA_A end=$SHA_B]"
NP_SAME="EXECUTE_EMPTY EXECUTE_NO_PROGRESS: time after 1260s, 1200000 of 53600000 context tokens, 0 files changed — transcript in execute-transcript.md [branch-head start=$SHA_B end=$SHA_B]"
NP_NOPUSH="EXECUTE_EMPTY EXECUTE_NO_PROGRESS: time after 1260s, 1200000 of 53600000 context tokens, 0 files changed — transcript in execute-transcript.md [branch-head start=$SHA_B end=-]"
CK_MOVED="EXECUTE_EMPTY the execute session committed nothing of its own — 3 lane checkpoint(s) are pushed on ticket/TK-3552 [branch-head start=$SHA_A end=$SHA_C]"

# ═════ A: the cap counts only attempts that did not move the branch ═════════
reset_h; rec TK-3552 202611030400 7200 "$NP_MOVED"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; RC=$?
[ "$RC" = 0 ] && ok || bad "A1+A2 an attempt that moved the branch must not count: want rc 0 (count 1), got $RC"
[ -z "$(NH TK-3552)" ] && ok || bad "A1+A2 needs-human.md was written: the key was held"
[ "$(holds)" = 0 ] && ok || bad "A1+A2 a NEEDS_HUMAN hold was placed ($(holds))"

reset_h; rec TK-3552 202611030400 7200 "$NP_SAME"; rec TK-3552 202611030500 600 "$NP_NOPUSH"
GATE TK-3552; RC=$?
[ "$RC" = 1 ] && ok || bad "A2+A4 two attempts that did not move the branch must count 2: want rc 1, got $RC"
[ -n "$(NH TK-3552)" ] && ok || bad "A2+A4 no needs-human.md"
[ "$(holds)" = 1 ] && ok || bad "A2+A4 want one hold, got $(holds)"

reset_h; rec TK-3552 202611030400 7200 "EXECUTE_EMPTY no changes produced"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 1 ] && ok || bad "A5+A2 a record with no token (before this change) is counted"

reset_h; rec TK-3552 202611030400 7200 "$CK_MOVED"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 0 ] && ok || bad "A3+A2 a checkpoint-only attempt that moved the branch must not count"

reset_h; rec TK-3552 202611030400 7200 "EXECUTE_EMPTY no changes produced" "[branch-head start=$SHA_A end=$SHA_B]"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 1 ] && ok || bad "A7 a token on line 2 is not read: the record is counted"

reset_h; rec TK-3552 202611030400 7200 "EXECUTE_EMPTY x [branch-head start=AAAAAAAA end=BBBBBBBB]"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 1 ] && ok || bad "A8 an upper-case token is not a sha: the record is counted"
reset_h; rec TK-3552 202611030400 7200 "EXECUTE_EMPTY x [branch-head start=xyz end=$SHA_B]"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 1 ] && ok || bad "A8 a non-hex start is not a sha: the record is counted"

reset_h; rec TK-3552 202611030400 7200 "PR_CREATED https://example.invalid/pull/1 [branch-head start=$SHA_A end=$SHA_B]"; rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 0 ] && ok || bad "A6 a non-EXECUTE_EMPTY record is not counted (as before)"

# ═════ B / C: the execute result block on a scratch repo ═══════════════════
awk 'index($0,"# >>> execute result")==1{f=1;next} index($0,"# <<< execute result")==1{exit} f' \
  "$DIR/bin/lib/rb/execute.sh" > "$T/exec.sh"
[ -s "$T/exec.sh" ] && ok || bad "could not extract the execute result block"
grep -E '^EE_HEAD_START=' "$DIR/bin/lib/rb/execute.sh" > "$T/head-start.sh"
[ -s "$T/head-start.sh" ] && ok || bad "B no EE_HEAD_START= line in bin/lib/rb/execute.sh (the start head is never recorded)"
grep -E '^CKPT_(WIP|NONWIP)_COUNT\(\)' "$DIR/bin/lib/rb/plan.sh" > "$T/ckpt.sh"
[ "$(grep -c . "$T/ckpt.sh")" = 2 ] && ok || bad "could not extract CKPT_WIP_COUNT / CKPT_NONWIP_COUNT from bin/lib/rb/plan.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# new_repo <dir> -> a repo on ticket/TK-3552 at the base commit, with a bare origin
new_repo() {
  git init -q --bare "$1.origin.git"
  git init -q -b main "$1"
  ( cd "$1" && echo base > base.txt && git add . && git commit -qm base \
    && git remote add origin "$1.origin.git" && git push -q origin main 2>/dev/null \
    && git checkout -q -b ticket/TK-3552 )
}
wip() { ( cd "$1" && printf '%s\n' "$3" > "$2" && git add -A && git commit -qm "wip: checkpoint execute $2" ); }
own() { ( cd "$1" && printf '%s\n' "$3" > "$2" && git add -A && git commit -qm "TK-3552: own work" ); }
push() { ( cd "$1" && git push -q origin HEAD:ticket/TK-3552 2>/dev/null ); }
# RUNBLK <repo> <build> [VAR=value ...] -> rc of the real result block
RUNBLK() {
  local repo="$1" b="$2"; shift 2
  ( set -uo pipefail
    cd "$repo" || exit 9
    for kv in "$@"; do export "${kv?}"; done
    PROJECT=project-6-os; KEY=TK-3552; BASE=main; BRANCH=ticket/TK-3552; BUILD="$b"
    HARNESS="$H" CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_ENV_DIR="$T/envdir" ETC_HARNESS_ENV="$T/envdir"
    HOME="$T/home" ALERTLOG="$T/alert.log"
    export HARNESS CLAUDE_PROJECTS_DIR HARNESS_ENV_DIR ETC_HARNESS_ENV HOME ALERTLOG
    STAMP() { echo TS; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    STAGE_LANE_DEFER() { :; }
    CKPT_STOP() { :; }
    CKPT_SQUASH_WIP() { echo squashed > "$BUILD/squashed"; }
    CKPT_SQUASH_REFUSED() { echo refused > "$BUILD/squash-refused"; }
    # shellcheck disable=SC1090
    . "$T/ckpt.sh"
    # shellcheck disable=SC1090
    . "$LIB"
    # shellcheck disable=SC1090
    [ -n "${PRE_START:-}" ] && . "$T/head-start.sh"
    [ -n "${ATTEMPT:-}" ] && eval "$ATTEMPT"
    # shellcheck disable=SC1090
    . "$T/exec.sh" ) >/dev/null 2>&1
}
r1() { head -1 "$1/RESULT" 2>/dev/null; }

# B1: a fresh attempt whose watcher pushed a commit, then a ceiling stop.
R="$T/rb1"; new_repo "$R"; BASE_SHA=$(git -C "$R" rev-parse HEAD)
B="$T/bb1"; mkdir -p "$B"; printf 'still reading\n' > "$B/execute-run.txt"
printf 'rule=ceiling elapsed_s=2400 total=26800000 ceiling=53600000\n' > "$B/execute-run.txt.noprogress"
RUNBLK "$R" "$B" PRE_START=1 ATTEMPT="wip '$R' a.txt one; push '$R'"; RC=$?
PUSHED=$(git -C "$R" rev-parse refs/remotes/origin/ticket/TK-3552 2>/dev/null)
[ "$RC" = 5 ] && ok || bad "B1 a ceiling stop still ends exit 5, got $RC"
case "$(r1 "$B")" in "EXECUTE_EMPTY EXECUTE_NO_PROGRESS: ceiling after 2400s"*"[branch-head start=$BASE_SHA end=$PUSHED]") ok ;;
  *) bad "B1 RESULT line 1 must end [branch-head start=$BASE_SHA end=$PUSHED]: $(r1 "$B")" ;; esac
[ -n "$PUSHED" ] && [ "$PUSHED" != "$BASE_SHA" ] && ok || bad "B1 fixture: the push did not land"
# Round trip: that record on the hub, beside one that did not move.
reset_h; mkdir -p "$H/builds/pool-project-6-os-TK-3552-202611030400"
cp "$B/RESULT" "$H/builds/pool-project-6-os-TK-3552-202611030400/RESULT"
touch -d "@$((NOW - 7200))" "$H/builds/pool-project-6-os-TK-3552-202611030400/RESULT"
rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 0 ] && ok || bad "B1 round trip: the written record must not be counted by ee_stop_check"

# B2: no push -> end=-, counted.
R="$T/rb2"; new_repo "$R"; BASE_SHA=$(git -C "$R" rev-parse HEAD)
git -C "$R" update-ref -d refs/remotes/origin/ticket/TK-3552 2>/dev/null
B="$T/bb2"; mkdir -p "$B"; printf 'still reading\n' > "$B/execute-run.txt"
printf 'rule=ceiling elapsed_s=2400 total=26800000 ceiling=53600000\n' > "$B/execute-run.txt.noprogress"
RUNBLK "$R" "$B" PRE_START=1 ATTEMPT="wip '$R' a.txt one"
case "$(r1 "$B")" in *"[branch-head start=$BASE_SHA end=-]") ok ;; *) bad "B2 no push must record end=-: $(r1 "$B")" ;; esac
reset_h; mkdir -p "$H/builds/pool-project-6-os-TK-3552-202611030400"
cp "$B/RESULT" "$H/builds/pool-project-6-os-TK-3552-202611030400/RESULT"
touch -d "@$((NOW - 7200))" "$H/builds/pool-project-6-os-TK-3552-202611030400/RESULT"
rec TK-3552 202611030500 600 "$NP_SAME"
GATE TK-3552; [ $? = 1 ] && ok || bad "B2 round trip: an attempt with no push is counted"

# B3: checkpoint-only stop (no marker) whose push landed: the token is there too.
R="$T/rb3"; new_repo "$R"; BASE_SHA=$(git -C "$R" rev-parse HEAD)
B="$T/bb3"; mkdir -p "$B"; printf 'still reading\n' > "$B/execute-run.txt"
RUNBLK "$R" "$B" PRE_START=1 ATTEMPT="wip '$R' a.txt one; push '$R'"
PUSHED=$(git -C "$R" rev-parse refs/remotes/origin/ticket/TK-3552 2>/dev/null)
case "$(r1 "$B")" in "EXECUTE_EMPTY the execute session committed nothing of its own"*"[branch-head start=$BASE_SHA end=$PUSHED]") ok ;;
  *) bad "B3 the checkpoint-only RESULT must carry the token: $(r1 "$B")" ;; esac

# C: resumed + rule=time. Fixture: base + 2 wip commits holding a file, pushed.
# c_setup <name> [net-zero] -> R, B
c_setup() {
  R="$T/rc-$1"; new_repo "$R"
  wip "$R" work.txt "half done"
  if [ "${2:-}" = zero ]; then ( cd "$R" && git rm -q work.txt && git commit -qm "wip: checkpoint execute z" )
  else wip "$R" work.txt "all done"; fi
  push "$R"
  B="$T/bc-$1"; mkdir -p "$B"; printf 'still checking\n' > "$B/execute-run.txt"
  printf 'rule=time elapsed_s=1260 total=1200000 ceiling=53600000\n' > "$B/execute-run.txt.noprogress"
}
c_setup 1; RUNBLK "$R" "$B" CKPT_START_POINT=origin/ticket/TK-3552 CKPT_WIP_N=2; RC=$?
[ "$RC" = 0 ] && ok || bad "C1 a resumed rule=time stop with 2 wip and a full tree must continue (rc 0), got $RC: $(r1 "$B")"
case "$(r1 "$B")" in EXECUTE_EMPTY*) bad "C1 RESULT starts EXECUTE_EMPTY: $(r1 "$B")" ;; *) ok ;; esac
[ -e "$B/squashed" ] && ok || bad "C1 the wip commits were not squashed (the PR path did not run)"
grep -q 'rule=time.*normal execute result' "$B/pipeline.log" 2>/dev/null && ok || bad "C1 pipeline.log must name rule=time and a normal execute result: $(cat "$B/pipeline.log" 2>/dev/null)"

c_setup 2; own "$R" own.txt mine
RUNBLK "$R" "$B" CKPT_START_POINT=origin/ticket/TK-3552 CKPT_WIP_N=2; RC=$?
[ "$RC" = 0 ] && [ -e "$B/squashed" ] && ok || bad "C2 resumed + 2 wip + 1 own commit must continue, got rc $RC: $(r1 "$B")"

c_setup 3; printf 'rule=ceiling elapsed_s=2400 total=26800000 ceiling=53600000\n' > "$B/execute-run.txt.noprogress"
RUNBLK "$R" "$B" CKPT_START_POINT=origin/ticket/TK-3552 CKPT_WIP_N=2; RC=$?
[ "$RC" = 5 ] && ok || bad "C3 rule=ceiling stays EXECUTE_EMPTY (rc 5), got $RC"
case "$(r1 "$B")" in "EXECUTE_EMPTY EXECUTE_NO_PROGRESS: ceiling"*) ok ;; *) bad "C3 RESULT: $(r1 "$B")" ;; esac

c_setup 4; RUNBLK "$R" "$B" CKPT_WIP_N=0; RC=$?
[ "$RC" = 5 ] && ok || bad "C4 a build that did not resume stays EXECUTE_EMPTY (rc 5), got $RC"
case "$(r1 "$B")" in "EXECUTE_EMPTY EXECUTE_NO_PROGRESS: time"*) ok ;; *) bad "C4 RESULT: $(r1 "$B")" ;; esac

c_setup 5 zero; RUNBLK "$R" "$B" CKPT_START_POINT=origin/ticket/TK-3552 CKPT_WIP_N=2; RC=$?
[ "$RC" = 5 ] && ok || bad "C5 a resumed build with an empty diff stays EXECUTE_EMPTY (rc 5), got $RC"
case "$(r1 "$B")" in EXECUTE_EMPTY*) ok ;; *) bad "C5 RESULT: $(r1 "$B")" ;; esac
[ ! -e "$B/squashed" ] && ok || bad "C5 an empty tree went on to the squash"

c_setup 6; rm -f "$B/execute-run.txt.noprogress"
RUNBLK "$R" "$B" CKPT_START_POINT=origin/ticket/TK-3552 CKPT_WIP_N=2; RC=$?
[ "$RC" = 5 ] && ok || bad "C6 no marker: a checkpoint-only branch stays EXECUTE_EMPTY (rc 5), got $RC"
case "$(r1 "$B")" in "EXECUTE_EMPTY the execute session committed nothing of its own"*) ok ;; *) bad "C6 RESULT: $(r1 "$B")" ;; esac

# ═════ D: an out-of-memory stop says EXECUTE_OOM ════════════════════════════
mkdir -p "$T/projects/-data-repo"
# JSONL helpers, the CLI's record shape.
j_call() { jq -nc --arg id "$1" --arg n "$2" --arg c "$3" \
  '{type:"assistant",timestamp:"2026-11-03T04:33:00.000Z",message:{role:"assistant",content:[{type:"tool_use",id:$id,name:$n,input:(if $n=="Bash" then {command:$c} else {file_path:$c} end)}]}}'; }
j_res() { jq -nc --arg id "$1" --argjson e "$2" --arg t "$3" \
  '{type:"user",timestamp:"2026-11-03T04:44:00.000Z",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:$e,content:$t}]}}'; }
j_text() { jq -nc --arg t "$1" '{type:"assistant",timestamp:"2026-11-03T04:45:00.000Z",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
V8OOM=$'Exit code 134\n\n<--- Last few GCs --->\n\n[41:0x6b2e000]   612345 ms: Mark-Compact 4041.2 (4130.5) -> 4030.1 (4131.7) MB, 2210.31 / 0.00 ms  allocation failure\n\n<--- JS stacktrace --->\n\nFATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory\n 1: 0xb7b3e0 node::Abort()\n 2: 0xa8c89a v8::Utils::ReportOOMFailure\n 3: 0xd5f1c0 v8::internal::V8::FatalProcessOutOfMemory'
FINAL_MSG="No file changed. I ran the typecheck and it did not finish."
# d_build <name> <jsonl-body> -> a build dir with that session
d_build() {
  local b="$T/bd-$1" sid="sess-9021-$1"
  mkdir -p "$b"; printf '%s\n' "$FINAL_MSG" > "$b/execute-run.txt"
  jq -nc --arg r "$FINAL_MSG" --arg s "$sid" '{session_id:$s, result:$r}' > "$b/execute-run.txt.json"
  printf '%s\n' "$2" > "$T/projects/-data-repo/$sid.jsonl"
  printf '%s' "$b"
}
# ONEMPTY <build> [VAR=value ...]
ONEMPTY() {
  local b="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    export HARNESS="$H" CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_ENV_DIR="$T/envdir" ETC_HARNESS_ENV="$T/envdir" \
      HOME="$T/home" ALERTLOG="$T/alert.log" PROJECT=project-6-os KEY=TK-3552
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    ee_on_empty "$b" ) >/dev/null 2>&1
}
sr() { head -1 "$1/stop-reason.txt" 2>/dev/null; }
alerts() { local c; c=$(grep -c . "$T/alert.log" 2>/dev/null); echo "${c:-0}"; }

# D1: npm run typecheck -> V8 heap OOM (TK-3552 04:33-04:44).
rm -f "$T/alert.log"
D1=$(d_build 1 "$(j_call t1 Bash 'npm run typecheck'; j_res t1 true "$V8OOM"; j_text "$FINAL_MSG")")
ONEMPTY "$D1" VM_MEMORY_MB=16384
case "$(sr "$D1")" in "EXECUTE_OOM: npm run typecheck"*) ok ;; *) bad "D1 stop-reason.txt must start 'EXECUTE_OOM: npm run typecheck': $(sr "$D1")" ;; esac
grep -q '16384 MB' "$D1/stop-reason.txt" 2>/dev/null && ok || bad "D1 the stop reason must name 16384 MB: $(sr "$D1")"
[ "$(alerts)" = 1 ] && ok || bad "D1 want exactly one alert line, got $(alerts)"
AL=$(head -1 "$T/alert.log" 2>/dev/null)
grep -q 'VM_MEMORY_MB=16384' <<<"$AL" && ok || bad "D1 the alert must name VM_MEMORY_MB=16384: $AL"
grep -q 'lane.fly-pool.project-6-os.vm_memory_mb' <<<"$AL" && ok || bad "D1 the alert must name the row lane.fly-pool.project-6-os.vm_memory_mb: $AL"
grep -q 'EXECUTE_OOM' <<<"$AL" && grep -q 'TK-3552' <<<"$AL" && ok || bad "D1 the alert must name EXECUTE_OOM and the key: $AL"
grep -q -- '--id execute-oom:project-6-os:TK-3552' <<<"$AL" && ok || bad "D1 the alert must carry --id execute-oom:project-6-os:TK-3552: $AL"
ONEMPTY "$D1" VM_MEMORY_MB=16384
[ "$(alerts)" = 1 ] && ok || bad "D1 a second ee_on_empty on the same dir must add no alert (got $(alerts))"
# The memory source: meminfo, then unknown.
printf 'MemTotal:       16374784 kB\nMemFree: 1 kB\n' > "$T/meminfo"
D1M=$(d_build 1m "$(j_call t1 Bash 'npm run typecheck'; j_res t1 true "$V8OOM")")
ONEMPTY "$D1M" EE_MEMINFO="$T/meminfo"
grep -q '15991 MB' "$D1M/stop-reason.txt" 2>/dev/null && ok || bad "D1 with no VM_MEMORY_MB the memory comes from MemTotal (15991 MB): $(sr "$D1M")"
D1U=$(d_build 1u "$(j_call t1 Bash 'npm run typecheck'; j_res t1 true "$V8OOM")")
ONEMPTY "$D1U" EE_MEMINFO="$T/no-such-meminfo"
grep -q 'unknown MB' "$D1U/stop-reason.txt" 2>/dev/null && ok || bad "D1 with no memory source the text says unknown: $(sr "$D1U")"

# D2: npm test -> Exit code 137 (TK-3575 16:12).
D2=$(d_build 2 "$(j_call t1 Bash 'npm test'; j_res t1 true 'Exit code 137')")
ONEMPTY "$D2" VM_MEMORY_MB=16384
case "$(sr "$D2")" in "EXECUTE_OOM: npm test"*) ok ;; *) bad "D2 Exit code 137 after npm test: $(sr "$D2")" ;; esac
# D3: npx tsc with NODE_OPTIONS.
D3=$(d_build 3 "$(j_call t1 Bash 'NODE_OPTIONS=--max-old-space-size=11000 npx tsc --noEmit'; j_res t1 true 'Exit code 137')")
ONEMPTY "$D3" VM_MEMORY_MB=16384
case "$(sr "$D3")" in "EXECUTE_OOM: "*tsc*) ok ;; *) bad "D3 npx tsc OOM: $(sr "$D3")" ;; esac

# Negatives: stop-reason.txt stays the model's message.
neg() { # neg <case> <build>
  ONEMPTY "$2" VM_MEMORY_MB=16384
  case "$(sr "$2")" in EXECUTE_OOM*) bad "$1 is not an OOM: $(sr "$2")" ;; "$FINAL_MSG"*) ok ;; *) bad "$1 stop-reason.txt: $(sr "$2")" ;; esac
}
neg D4 "$(d_build 4 "$(j_call t1 Bash 'npm run typecheck'; j_res t1 true "$V8OOM"; j_call t2 Bash 'npm run typecheck'; j_res t2 false '')")"
neg D5 "$(d_build 5 "$(j_call t1 Bash 'grep -rn FatalProcessOutOfMemory logs/'; j_res t1 false 'logs/x: FatalProcessOutOfMemory')")"
neg D6 "$(d_build 6 "$(j_text 'the typecheck hit FatalProcessOutOfMemory earlier')")"
neg D7 "$(d_build 7 "$(j_call t1 Bash 'npm run lint'; j_res t1 true 'Exit code 137')")"
# D8: two parallel calls; the first result pairs with npm test.
D8J=$(jq -nc '{type:"assistant",timestamp:"2026-11-03T16:12:00.000Z",message:{role:"assistant",content:[
  {type:"tool_use",id:"p1",name:"Bash",input:{command:"npm test"}},{type:"tool_use",id:"p2",name:"Read",input:{file_path:"src/x.ts"}}]}}'
  jq -nc '{type:"user",timestamp:"2026-11-03T16:13:00.000Z",message:{role:"user",content:[
  {type:"tool_result",tool_use_id:"p1",is_error:true,content:"Exit code 137"},{type:"tool_result",tool_use_id:"p2",content:"export const x = 1"}]}}')
D8=$(d_build 8 "$D8J"); ONEMPTY "$D8" VM_MEMORY_MB=16384
case "$(sr "$D8")" in "EXECUTE_OOM: npm test"*) ok ;; *) bad "D8 parallel calls: the 137 belongs to npm test: $(sr "$D8")" ;; esac
# D9: no session file (stage output) that mentions the signature.
D9="$T/bd-9"; mkdir -p "$D9"; printf 'FatalProcessOutOfMemory was in a log I read\n' > "$D9/execute-run.txt"
ONEMPTY "$D9" VM_MEMORY_MB=16384
case "$(sr "$D9")" in EXECUTE_OOM*) bad "D9 stage output is not an OOM: $(sr "$D9")" ;; *) ok ;; esac
# ee_oom on its own: one line, signal TAB command.
OO=$( . "$LIB"; ee_oom "$D2/execute-transcript.md" )
[ "$(printf '%s' "$OO" | cut -f2)" = "npm test" ] && ok || bad "ee_oom must print <signal>TAB<command>: '$OO'"

# D10: two OOM records reach the hub ask.
reset_h
for s in 202611030400 202611030500; do
  d="$H/builds/pool-project-6-os-TK-3575-$s"; mkdir -p "$d"
  cp "$D2/execute-run.txt" "$D2/execute-run.txt.json" "$d/"
  ONEMPTY "$d" VM_MEMORY_MB=16384
  printf 'EXECUTE_EMPTY no changes produced\n' > "$d/RESULT"
done
touch -d "@$((NOW - 7200))" "$H/builds/pool-project-6-os-TK-3575-202611030400/RESULT"
touch -d "@$((NOW - 600))" "$H/builds/pool-project-6-os-TK-3575-202611030500/RESULT"
GATE TK-3575; [ $? = 1 ] && ok || bad "D10 two OOM stops still count"
grep -q 'EXECUTE_OOM' "$(NH TK-3575)" 2>/dev/null && ok || bad "D10 the hub ask must quote the EXECUTE_OOM stop reason: $(cat "$(NH TK-3575)" 2>/dev/null)"

# ═════ Z: vendor budget ═════════════════════════════════════════════════════
[ ! -s "$T/net.log" ] && ok || bad "Z a network stub was called: $(cat "$T/net.log")"

echo "execute-empty.bh-9021-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
