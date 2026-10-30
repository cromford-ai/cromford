#!/bin/bash
# tests/merge-queue-red-guard.bh-6428-test.sh — BH-6428: the box merge queue
# re-checks CI, the reviewed sha and the conductor's park state right before
# every merge, on every rung.
#
# THE INCIDENT (example-org/project-6 #216, 2026-10-13). The conductor parked
# #216 RED_TWICE on head 1ad9442c at 07:23:55Z (CI red after a rerun). At
# 07:26:02Z project-6-os materialised the coordination-DB row, and at 07:26:24Z
# bin/merge-queue.sh merged that head over REST. Nothing in the box queue read
# CI, and cv_hold reads only the mc-merge-verdict kind, which a RED_TWICE park
# never writes.
#
# Driven, not grepped: the `# >>> pre-merge guard`, `# >>> conductor verdict
# gate` and `# >>> mq_land` blocks are extracted VERBATIM by their markers and
# run against stubs; the lib is installed with scratch_install_closure. The
# assertions are on the merge sinks (gh_pr_merge_rest and a `gh` on PATH), the
# mq_land output and the lane log. G8 drives the WHOLE script.
#   A1-A4  the ticket's acceptance cases
#   R1     the project-6#216 replay (and each leg alone)
#   G1-G7  the decision table of pmg_check
#   G8     both landing paths of the real script: hand-back, hold, land
#   G9     real-tree pins (source line, closure, call order, mutation)
#   G10    round trip through the real mc_ledger_put writer
# Run from anywhere: tests/merge-queue-red-guard.bh-6428-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

MQ="$DIR/bin/merge-queue.sh"
extract() { # extract <src> <dest>
  awk '/^# >>> pre-merge guard/{f=1;next} /^# <<< pre-merge guard/{exit} f' "$1" > "$2/guard.sh"
  awk '/^# >>> conductor verdict gate/{f=1;next} /^# <<< conductor verdict gate/{exit} f' "$1" > "$2/gate.sh"
  awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' "$1" > "$2/mqland.sh"
}
extract "$MQ" "$T"
[ -s "$T/guard.sh" ] && ok || bad "could not extract the pre-merge guard (# >>> pre-merge guard) from bin/merge-queue.sh"
[ -s "$T/mqland.sh" ] && ok || bad "could not extract mq_land from bin/merge-queue.sh"
( cd "$DIR" && scratch_install_closure bin/lib/mq-premerge.sh "$T" ) >/dev/null 2>&1 \
  && ok || bad "cannot install the closure of bin/lib/mq-premerge.sh"

SLUG=example-org/project-6
H216=1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912
HOLD=0bd0c0de5e0b7a91d3c4f2e8b6a0d1c3e5f70912
ENQ=2026-10-13T07:26:02Z
PARKED=2026-10-13T07:23:55Z
LATER=2026-10-13T07:30:00Z

# Fixture knobs, one file each under $T/f:
#   head       mq_pr .head.sha            (absent = unreadable)
#   hb         hb_sha answer              (empty = no job_verdict row)
#   ci         mc_ci_state answer         (noci present = mc_ci_state undefined)
#   ps.rc/ps   job_ledger_row pr_state    (rc 0 + row, 2 no row, 1 outage)
#   enq        the queued row's enqueued_at
#   norest     present = gh_pr_merge_rest undefined (the gh pr merge rung)
mkdir -p "$T/f" "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHCALLS"
exit 0
EOF
chmod +x "$T/bin/gh"
reset_fixture() {
  rm -f "$T/f"/*
  printf '%s' "$H216" > "$T/f/head"; printf '%s' "$H216" > "$T/f/hb"
  echo green > "$T/f/ci"; echo 2 > "$T/f/ps.rc"; printf '%s' "$ENQ" > "$T/f/enq"
}
# ps <state> <since> <head> <reviewed> — a pr_state row in the shape the worker
# returns it: {status, detail} with detail the JSON string mc_ledger_put sent.
ps() {
  echo 0 > "$T/f/ps.rc"
  jq -nc --arg st "$1" --arg s "$2" --arg h "$3" --arg r "$4" \
    '{status:$st, detail:({since:$s,head_sha:$h,reviewed_sha:$r,verdict:"-",merge_state:"-",reason:"r",record:"-",url:"u",alerted:"-"}|tojson)}' > "$T/f/ps"
}

# run_land <pin> [lib-dir] — drive mq_land 216 <pin> with the extracted blocks.
run_land() {
  : > "$T/merges"; : > "$T/mq.log"; : > "$T/ghcalls"
  ( cd "$T" && SLUG="$SLUG" PROJECT=project-6-os LOG="$T/mq.log" HARNESS="${2:-$T}" T="$T" \
      GHCALLS="$T/ghcalls" PATH="$T/bin:$PATH" Q="$T/q" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      F="$T/f"
      hb_sha() { cat "$F/hb" 2>/dev/null; }
      mq_pr() { [ -s "$F/head" ] || return 75; cat "$F/head"; }
      mc_rest_status() { printf 403; }
      job_ledger_row() {
        case "$1" in
          pr_state) local rc; rc=$(cat "$F/ps.rc"); [ "$rc" = 0 ] && cat "$F/ps"; return "$rc" ;;
          *) return 2 ;;
        esac
      }
      merge_queue_list() { printf "%s\t216\tqueued\t%s\t-\t%s\t-\n" "$1" "$SLUG" "$(cat "$F/enq")"; }
      [ -e "$F/noci" ] || mc_ci_state() { printf "%s %s\n" "$1" "$2" >> "$T/ci-calls"; cat "$F/ci"; }
      [ -e "$F/norest" ] || gh_pr_merge_rest() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$T/merges"; printf mergesha; return 0; }
      . "$T/guard.sh"
      . "$T/gate.sh"
      . "$T/mqland.sh"
      mq_land 216 "$1"' _ "${1:-}" > "$T/land.out" 2>"$T/land.err" )
}
merged()   { [ -s "$T/merges" ] || grep -q '^pr merge' "$T/ghcalls"; }
refused()  { # refused <id> <leg> <word> <reason-prefix>
  merged && bad "$1 must not merge: $(cat "$T/merges" "$T/ghcalls")" || ok
  grep -q "MERGE_REFUSED premerge-$2" "$T/mq.log" && ok || bad "$1 must log MERGE_REFUSED premerge-$2: $(cat "$T/mq.log") $(cat "$T/land.err")"
  grep -q "^REFUSED $3 $4" "$T/land.out" && ok || bad "$1 mq_land must print 'REFUSED $3 $4…': $(cat "$T/land.out")"
}
lands()    { # lands <id>
  grep -q "^$SLUG 216 $H216" "$T/merges" && ok || bad "$1 must merge pinned to $H216: $(cat "$T/merges") $(cat "$T/mq.log") $(cat "$T/land.err")"
  grep -q '^MERGED mergesha' "$T/land.out" && ok || bad "$1 mq_land must print MERGED: $(cat "$T/land.out")"
  grep -q 'MERGE_REFUSED' "$T/mq.log" && bad "$1 must log no refusal: $(cat "$T/mq.log")" || ok
}

# A1. head CI failure -> refused on the REST rung and on the gh pr merge rung
reset_fixture; echo red > "$T/f/ci"
run_land "$H216"; refused A1 ci handback ci-red
: > "$T/f/norest"; run_land "$H216"; refused A1b ci handback ci-red
grep -q "^$SLUG $H216" "$T/ci-calls" 2>/dev/null && ok || bad "A1 the CI leg must read mc_ci_state <slug> <head>"

# A2. conductor parked RED_TWICE after the enqueue — on this head, and on an older head
reset_fixture; ps RED_TWICE "$LATER" "$H216" "$H216"
run_land "$H216"; refused A2 park handback conductor-park
reset_fixture; ps RED_TWICE "$LATER" "$HOLD" "$HOLD"
run_land "$H216"; refused A2b park handback stale-enqueue

# A3. head is not the reviewed sha
reset_fixture; printf '%s' "$HOLD" > "$T/f/hb"
run_land "$H216"; refused A3 reviewed-sha handback head-not-reviewed
# A3b. no reviewed sha anywhere
reset_fixture; : > "$T/f/hb"
run_land "$H216"; refused A3b reviewed-sha handback no-reviewed-sha
# A3b2. no job_verdict row, but pr_state carries reviewed_sha = head -> lands
reset_fixture; : > "$T/f/hb"; ps WAIT_CI "$LATER" "$H216" "$H216"
run_land "$H216"; lands A3b2
# A3c. HEADBOUND_ENFORCE=0 -> the leg is skipped with a log line, the merge runs
reset_fixture; printf '%s' "$HOLD" > "$T/f/hb"
HEADBOUND_ENFORCE=0 run_land "$H216"
grep -q "^$SLUG 216 " "$T/merges" && ok || bad "A3c HEADBOUND_ENFORCE=0 must still merge: $(cat "$T/mq.log")"
grep -q "premerge reviewed-sha leg skipped (HEADBOUND_ENFORCE=0)" "$T/mq.log" && ok || bad "A3c the skipped leg must be logged: $(cat "$T/mq.log")"

# A4. green, matching sha, no park row -> merges as today; a READY row too
reset_fixture
run_land "$H216"; lands A4
[ "$(wc -l < "$T/merges")" -eq 1 ] && ok || bad "A4 exactly one REST merge call"
reset_fixture; ps READY "$LATER" "$H216" "$H216"
run_land "$H216"; lands A4b
# A4c. no pin: the guard reads the head itself
reset_fixture; run_land ""; lands A4c

# R1. project-6#216 replay: CI red AND RED_TWICE on 1ad9442c, parked before the enqueue
reset_fixture; echo red > "$T/f/ci"; ps RED_TWICE "$PARKED" "${H216:0:8}" "${H216:0:8}"
run_land "$H216"
merged && bad "R1 the project-6#216 row must not merge" || ok
grep -q "MERGE_REFUSED premerge-park" "$T/mq.log" && ok || bad "R1 the park leg must refuse first: $(cat "$T/mq.log")"
grep -q "^REFUSED handback conductor-park RED_TWICE on ${H216:0:8}" "$T/land.out" && ok || bad "R1 output: $(cat "$T/land.out")"
# R1b. CI forced green: the park leg alone refuses
echo green > "$T/f/ci"; run_land "$H216"
merged && bad "R1b park leg alone must refuse" || ok
# R1c. ledger unreadable: the CI leg alone refuses
echo red > "$T/f/ci"; echo 1 > "$T/f/ps.rc"; run_land "$H216"
merged && bad "R1c CI leg alone must refuse" || ok
grep -q "premerge park state could not be read (ledger rc 1)" "$T/mq.log" && ok || bad "R1c the outage must be logged: $(cat "$T/mq.log")"
grep -q "MERGE_REFUSED premerge-ci" "$T/mq.log" && ok || bad "R1c the CI leg must refuse: $(cat "$T/mq.log")"

# G1. CI leg
for c in pending:hold:ci-pending none:hold:ci-none unavailable:hold:ci-unavailable; do
  reset_fixture; echo "${c%%:*}" > "$T/f/ci"; run_land "$H216"
  w=${c#*:}; refused "G1-${c%%:*}" ci "${w%%:*}" "${w#*:}"
done
reset_fixture; : > "$T/f/noci"; run_land "$H216"; refused G1-absent ci hold ci-unavailable
# G2. reviewed-sha leg: an 8-char reviewed sha matches the full head. The guard
# passes it; mq_land's own exact pin compare (BH-1606, unchanged) then decides.
reset_fixture; printf '%s' "${H216:0:8}" > "$T/f/hb"; run_land "$H216"
grep -q 'MERGE_REFUSED premerge' "$T/mq.log" && bad "G2 an 8-char reviewed sha must pass the guard: $(cat "$T/mq.log")" || ok
grep -q '^REFUSED' "$T/land.out" && bad "G2 no REFUSED line: $(cat "$T/land.out")" || ok
# G2b. a 4-char stray reviewed sha does not match
reset_fixture; printf '%s' "${H216:0:4}" > "$T/f/hb"; run_land "$H216"; refused G2b reviewed-sha handback head-not-reviewed
# G3. head leg: not hex
reset_fixture; printf 'nothex!!' > "$T/f/head"; run_land ""; refused G3 head hold head-unread
# G4. park leg: BLOCKED_HUMAN and NEEDS_REBASE on this head
for s in BLOCKED_HUMAN BLOCKED_AGENT NEEDS_REBASE; do
  reset_fixture; ps "$s" "$PARKED" "$H216" "$H216"; run_land "$H216"; refused "G4-$s" park handback "conductor-park $s"
done
# G5. park leg: WAIT_CI -> pass; outage -> pass with a line
reset_fixture; ps WAIT_CI "$LATER" "$H216" "$H216"; run_land "$H216"; lands G5
reset_fixture; echo 1 > "$T/f/ps.rc"; run_land "$H216"
grep -q "^$SLUG 216 " "$T/merges" && ok || bad "G5b a ledger outage must not stop a green head"
grep -q "premerge park state could not be read (ledger rc 1)" "$T/mq.log" && ok || bad "G5b outage line: $(cat "$T/mq.log")"
# G6. park on another head, older than the enqueue -> pass
reset_fixture; ps RED_TWICE "$PARKED" "$HOLD" "$HOLD"; run_land "$H216"; lands G6
# G7. park on another head, since unparseable -> handback
reset_fixture; ps RED_TWICE "garbage" "$HOLD" "$HOLD"; run_land "$H216"; refused G7 park handback stale-enqueue
reset_fixture; printf -- '-' > "$T/f/enq"; ps RED_TWICE "$PARKED" "$HOLD" "$HOLD"; run_land "$H216"; refused G7b park handback stale-enqueue

# G9. real-tree pins. The script sources the lib; the closure lists it; the
# call sits before the first merge rung inside mq_land.
grep -qE '^\[ -r "\$HARNESS/bin/lib/mq-premerge.sh" \] && \. "\$HARNESS/bin/lib/mq-premerge.sh"' "$MQ" && ok \
  || bad "G9 bin/merge-queue.sh must source bin/lib/mq-premerge.sh"
( cd "$DIR" && scratch_closure_list bin/merge-queue.sh ) 2>/dev/null | grep -qx 'bin/lib/mq-premerge.sh' && ok \
  || bad "G9 scratch_closure_list bin/merge-queue.sh must list bin/lib/mq-premerge.sh"
gl=$(grep -n 'mq_premerge_guard' "$T/mqland.sh" | head -1 | cut -d: -f1)
rl=$(grep -n 'gh_pr_merge_rest' "$T/mqland.sh" | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
[ -n "$gl" ] && [ -n "$rl" ] && [ "$gl" -lt "$rl" ] && ok || bad "G9 mq_land must call mq_premerge_guard (line ${gl:-none}) before gh_pr_merge_rest (line ${rl:-none})"
# Mutation: take the guard's answer out of a COPY of mq_land, and A1 must go red.
mkdir -p "$T/mut"
sed 's/verdict=$(mq_premerge_guard "$num" "$ghead")/verdict=ok/' "$MQ" > "$T/mut/merge-queue.sh"
cmp -s "$MQ" "$T/mut/merge-queue.sh" && bad "G9 mutation did not apply: the guard call line changed shape"
extract "$T/mut/merge-queue.sh" "$T"
reset_fixture; echo red > "$T/f/ci"; run_land "$H216"
merged && ok || bad "G9 mutation: with the guard call removed, A1's red head must merge (the guard is what stops it)"
extract "$MQ" "$T"

# G10. round trip through the real writer: mc_ledger_put -> job_ledger_put
# captures the row; the captured row, read back, drives pmg_check.
# mc_ledger_put writes its row through mc_ledger_row_put (BH-8735), so both
# real functions are extracted: the writer is the pair, not a copy of it.
grep -q '^mc_ledger_put()' "$DIR/bin/lib/mc/settle.sh" && ok || bad "G10 mc_ledger_put not found in bin/lib/mc/settle.sh"
grep -q '^mc_ledger_row_put()' "$DIR/bin/lib/mc/settle.sh" && ok || bad "G10 mc_ledger_row_put not found in bin/lib/mc/settle.sh"
( T="$T" bash -c '
    awk "/^mc_ledger_(row_)?put\\(\\)/{f=1} f{print} f&&/^}/{f=0}" "$0/bin/lib/mc/settle.sh" > "$T/mlp.sh"
    . "$T/mlp.sh"
    mc_state_event_put() { :; }
    job_ledger_put() { jq -nc --arg s "$3" --arg d "$4" "{status:\$s, detail:\$d}" > "$T/captured"; }
    mc_ledger_put "example-org/project-6#216" RED_TWICE 2026-10-13T07:23:55Z 1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912 \
      1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912 BLOCK - "ci-red-twice" - u -' "$DIR" )
[ -s "$T/captured" ] && ok || bad "G10 the real mc_ledger_put wrote no row"
G10=$(T="$T" HARNESS="$T" bash -c '
  . "$T/bin/lib/mq-premerge.sh"
  job_ledger_row() { cat "$T/captured"; }
  mc_ci_state() { echo green; }
  pmg_check example-org/project-6 216 1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912 1ad9442c5e0b7a91d3c4f2e8b6a0d1c3e5f70912 \
    "$(date -u -d 2026-10-13T07:26:02Z +%s)" "$T/g10.log" "TS"' 2>&1)
[ "$G10" = "handback conductor-park RED_TWICE on 1ad9442c" ] && ok || bad "G10 the real writer's row must drive the park leg: '$G10'"

# G8. both landing paths of the REAL script, three queued entries:
#   301 red CI, 302 parked RED_TWICE on its head, 303 green -> lands,
#   and (serial only) 304 pending -> held, file kept.
G8=$T/g8; mkdir -p "$G8"
( cd "$DIR" && scratch_install_closure bin/merge-queue.sh "$G8" ) >/dev/null 2>&1 || bad "G8 cannot install the closure of bin/merge-queue.sh"
mkdir -p "$G8/logs" "$G8/locks" "$G8/env" "$G8/state/merge-queue/proj" "$G8/sbin" "$G8/repo"
cat > "$G8/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "$2" = repo ] && echo example-org/proj
EOF
cat > "$G8/bin/beat.sh" <<'EOF'
#!/bin/bash
echo beat >> "$HARNESS/beats"
EOF
cat > "$G8/bin/deploy-request.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$G8/bin/fleet-conf.sh" "$G8/bin/beat.sh" "$G8/bin/deploy-request.sh"
# Every lib the script would source on a box, replaced by one stub file that
# answers from fixtures. The pre-merge lib stays REAL.
cat > "$G8/bin/jobs-client.sh" <<'EOF'
job_verdict() { local n="${1##*/}"; printf 'u\tproj\tAPPROVE\t-\t-\t%s\n' "$(cat "$HARNESS/fx/head.$n")"; }
job_ledger_row() { local n="${2##*#}"; [ "$1" = pr_state ] && [ -s "$HARNESS/fx/ps.$n" ] && { cat "$HARNESS/fx/ps.$n"; return 0; }; return 2; }
merge_queue_list() { :; }
merge_queue_set() { printf '%s\n' "$*" >> "$HARNESS/mqset"; }
EOF
cat > "$G8/bin/lib/merge-conductor-lib.sh" <<'EOF'
mc_queue_enabled() { return 1; }
mc_rest_status() { printf 200; }
mc_pr_view() { local n="${1##*/}"
  case "$2" in
    .head.sha) cat "$HARNESS/fx/head.$n" ;;
    *user.login*) echo "fixture-bot $(cat "$HARNESS/fx/head.$n")" ;;
    .STATE) cat "$HARNESS/fx/state.$n" 2>/dev/null || echo OPEN ;;
    .merge_commit_sha*) echo "msha$n" ;;
    *STATE*MERGEABLE*) echo "OPEN MERGEABLE br$n main" ;;
    *STATE*) echo "OPEN br$n main" ;;
  esac; }
mc_ci_state() { local s; s=${2:0:3}; cat "$HARNESS/fx/ci.$s"; }
gh_pr_merge_rest() { printf '%s\n' "$2" >> "$HARNESS/merged"; echo MERGED > "$HARNESS/fx/state.$2"; printf "msha%s" "$2"; return 0; }
EOF
: > "$G8/bin/lib/gh-pr-merge.sh"
# No ownership lib: the lead fence and the ticket hold land as before (their
# own suites pin them).
: > "$G8/bin/lib/ticket-ownership.sh"
g8_fixture() {
  scratch_rm "$G8/fx"; mkdir -p "$G8/fx"; : > "$G8/merged"; : > "$G8/mqset"; : > "$G8/beats"; : > "$G8/logs/merge-queue.log"
  local n
  for n in "$@"; do
    printf '%s0000000000000000000000000000000000000' "$n" | cut -c1-40 > "$G8/fx/head.$n"
    : > "$G8/state/merge-queue/proj/$n"; touch -d "2026-10-13 07:0${n: -1}:00" "$G8/state/merge-queue/proj/$n"
  done
  echo red > "$G8/fx/ci.301"; echo green > "$G8/fx/ci.302"; echo green > "$G8/fx/ci.303"; echo pending > "$G8/fx/ci.304"
  jq -nc --arg h "$(cat "$G8/fx/head.302")" '{status:"RED_TWICE", detail:({since:"2026-10-13T07:23:55Z",head_sha:$h,reviewed_sha:$h}|tojson)}' > "$G8/fx/ps.302"
}
g8_run() { # g8_run <label> — run the real script; mq-train repo dir is a real git repo
  ( HARNESS="$G8" HARNESS_ENV_DIR="$G8/env" PATH="$G8/sbin:$PATH" bash "$G8/bin/merge-queue.sh" proj ) > "$G8/run.out" 2>&1
}
g8_assert() { # g8_assert <label> <held-entry-or-empty>
  grep -qx 303 "$G8/merged" && ok || bad "$1 the green entry 303 must land: $(cat "$G8/merged") $(tail -20 "$G8/logs/merge-queue.log")"
  grep -qxE '30[124]' "$G8/merged" && bad "$1 a red, parked or pending entry merged: $(cat "$G8/merged")" || ok
  [ "$(grep -c 'MERGE_REFUSED premerge-' "$G8/logs/merge-queue.log")" -eq "$(( ${2:+1} + 2 ))" ] && ok \
    || bad "$1 expected $(( ${2:+1} + 2 )) MERGE_REFUSED lines: $(grep MERGE_REFUSED "$G8/logs/merge-queue.log")"
  for n in 301 302; do
    [ ! -e "$G8/state/merge-queue/proj/$n" ] && ok || bad "$1 handed-back $n must lose its queue file"
    grep -q "^proj $n dropped MERGE_REFUSED" "$G8/mqset" && ok || bad "$1 $n must be dropped with the MERGE_REFUSED reason: $(cat "$G8/mqset")"
    grep -q "#$n LANDED" "$G8/logs/merge-queue.log" && bad "$1 $n must have no LANDED line" || ok
    grep -q "#$n merge attempt failed" "$G8/logs/merge-queue.log" && bad "$1 $n must not read as a failed attempt" || ok
  done
  grep -q "^proj 303 landed" "$G8/mqset" && ok || bad "$1 303 must be recorded landed: $(cat "$G8/mqset")"
  [ ! -s "$G8/beats" ] && ok || bad "$1 a refusal must not page (beat.sh called)"
  if [ -n "${2:-}" ]; then
    [ -e "$G8/state/merge-queue/proj/$2" ] && ok || bad "$1 held entry $2 must keep its queue file"
    grep -q "^proj $2 " "$G8/mqset" && bad "$1 held entry $2 must get no merge_queue_set call: $(cat "$G8/mqset")" || ok
  fi
}
# sleep is a no-op in this run: the script sleeps between landings.
printf '#!/bin/bash\nexit 0\n' > "$G8/sbin/sleep"; chmod +x "$G8/sbin/sleep"
# Serial path: REPO_DIR does not exist, so the train cannot build a worktree
# and every entry takes the serial loop.
g8_fixture 301 302 303 304
g8_run serial
g8_assert G8-serial 304
# Train path: a real repo with branches br301..br303 that merge cleanly.
R="$G8/origin.git"; W="$G8/work"
git init -q --bare "$R" && git init -q "$W" && (
  cd "$W" && git config user.email t@example.invalid && git config user.name t && git checkout -q -b main
  echo base > a && git add a && git commit -qm base && git remote add origin "$R" && git push -q origin main
  for n in 301 302 303; do git checkout -q -b "br$n" main; echo "$n" > "f$n"; git add "f$n"; git commit -qm "$n"; git push -q origin "br$n"; done
) >/dev/null 2>&1
mkdir -p "$G8/root-repos"; git clone -q "$R" "$G8/root-repos/proj" >/dev/null 2>&1
# The union build commits merges: an identity of its own, so the case does not
# depend on the box's global git config (a bare CI or test container has none).
git -C "$G8/root-repos/proj" config user.email t@example.invalid
git -C "$G8/root-repos/proj" config user.name t
sed -i "s#^REPO_DIR=\"/root/repos/\$PROJECT\"#REPO_DIR=\"$G8/root-repos/\$PROJECT\"#" "$G8/bin/merge-queue.sh"
grep -q "REPO_DIR=\"$G8/root-repos" "$G8/bin/merge-queue.sh" && ok || bad "G8 could not point REPO_DIR at the fixture repo"
g8_fixture 301 302 303
g8_run train
grep -q "merge train: 1/3 landed" "$G8/logs/merge-queue.log" && ok || bad "G8-train the train must count one real landing: $(tail -20 "$G8/logs/merge-queue.log")"
g8_assert G8-train ""

echo "merge-queue-red-guard.bh-6428: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
