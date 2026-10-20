#!/bin/bash
# tests/blocked-resolver-head-gate.bh-7660-test.sh — BH-7660: the resolver must
# not close a PR whose head changed after its last counted rung.
#
# WHAT HAPPENED. A person pushed a new head B to a parked PR about 30 minutes
# before the lane closed it as ABANDONED. Every counted rung had run on the old
# head A. The supersede guard only delays a close for a new head (the settle
# window, 1800 s); it never resets the counts, and the record kept no head per
# rung, so nothing could tell "rungs on A" from "rungs on B".
#
# THE CASES (plan ## Acceptance tests):
#   T1  a counted rung records the head it ran on (rung_head / rung_pr)
#   T2  after a reset the pr_attempts rows do not undo it (the baseline)
#   A1  rungs on A, PR on B, rebuild cap spent: the tick resets, nothing closed;
#       the next tick runs rung 1 on B; a ladder spent on B then closes
#   A2  the same record on A: closed, and the close body names the judged head
#       and the counted rungs
#   A3  the lane's own fix-round push is not a foreign head: closed
#   A4  the second terminal on an already-reset head closes (R5b), no 2nd reset
#   A5  an unreadable head: nothing closed, record unchanged byte for byte
#   A6  a record write that fails: rc 75, no event, nothing claimed
#   A7  rebuild-fresh below the cap: a moved head is not superseded; the same
#       head is, with the facts paragraph on the close comment
#   B1  three ticks whose rung 1 could not START: nothing counted, nothing closed
#   B2  a terminal over a setup-blocked-only history: nothing closed
#   B3  near miss: a real rung after a setup block still closes
#   U*  the gate's other rows (closed PR, 404, legacy record, another PR,
#       uppercase head, short head, observe mode, rebuild-only reason)
#
# Run from anywhere: bash tests/blocked-resolver-head-gate.bh-7660-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# The gate module, named by path so bin/test-impact.sh selects this suite.
[ -r "$DIR/bin/lib/br/headgate.sh" ] && ok || bad "0: bin/lib/br/headgate.sh is missing"

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
# br_pr_ref reads head+branch with a plain `gh api` (not the -i REST envelope),
# and the shared stub answers that arm with a fixed head A. This suite moves the
# PR between heads, so its scratch stub answers from $T/prhead like the REST arm.
sed -i "s#^  \*\"/pulls/\"\*) echo \"$(printf 'a%.0s' {1..40}) ticket/TK-9\" ;;#  *\"/pulls/\"*) printf '%s %s\\\\n' \"\$(cat $T/prhead)\" \"\$(cat $T/prbranch)\" ;;#" "$T/fakebin/gh"
grep -q 'cat .*/prhead' "$T/fakebin/gh" || { echo "FAIL: could not point the gh stub's PR read at \$T/prhead"; exit 1; }
# The queue, and the pr_attempts rows the fix cap reads (BH-1388): files, so a
# scenario is one write. rows-on raises the flag; rows-fixround is the count.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
pr_rows_on() { [ -e "$T/rows-on" ]; }
pr_attempt_count() {
  if [ "\$3" = fixround ] && [ -s "$T/rows-fixround" ]; then cat "$T/rows-fixround"; return 0; fi
  printf 0; return 2
}
pr_attempt_put() { return 0; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: a rebuild is a queue row
# mc_rebase to its documented rc contract (the same override fx_br_ladder_git
# installs): 0 pushed (stdout: the new head) | 2 gate red | 4 setup failed.
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  local out; out=\$(cat "$T/rebase-out" 2>/dev/null)
  [ -n "\$out" ] && printf '%s' "\$out"
  return "\$(cat "$T/rebase-rc" 2>/dev/null || echo 4)"
}
EOF
# Rung 1b would buy a second mc_rebase on a ci-red park; this suite is about the
# terminal, so the ladder is 1 -> 2 -> 3. The settle window is the registry's.
BASEENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
BRENV=("${BASEENV[@]}")

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
URL=https://github.com/o/tproj/pull/9
CK=tproj-TK-9
LOGF="$H/logs/blocked-resolver.log"
RECF="$H/state/blocked-resolver/tproj/$CK.json"
# The settle window is measured by the lane against its own clock, so "two hours
# ago" has to be relative to now; only "older than 1800 s" is asserted.
OLD=$(( $(date -u +%s) - 7200 ))  # determinism: ok — the lane's settle window reads the same clock; the value only has to be 2 h old

# PARK <head> — the conductor's red-twice row for PR 9, judged on <head>.
PARK() {
  printf 'o/tproj#9\tRED_TWICE\t%s\t%s\t%s\t-\t%s\t%s\n' "$(date -u +%s)" "$1" "$1" \
    "red-twice: still red on ${1:0:8} after its failed jobs were re-run once" "$URL" \
    > "$H/state/merge-conductor/pr-state.tsv"
}
# FRESH — one scenario's clean slate. No record, an open PR on head A.
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  mkdir -p "$H/state/blocked-resolver/tproj"
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
  : > "$T/lane-alert.txt"; : > "$T/rebase.txt"
  rm -f "$T/rows-on" "$T/rows-fixround" "$T/rebase-out" "$T/rebase-rc" "$T/st-pr" \
        "$H/flags/blocked-resolver-observe"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf '%s' "$A" > "$T/prhead"
  echo OPEN > "$T/prstate"
  BRENV=("${BASEENV[@]}")
}
# SEED <jq-filter> — the record, as the lane writes it, edited by <filter>.
# The base is the incident: rung 1 and two fix rounds ran on head A, the ticket
# has already bought its three rebuilds, and this lane last saw the PR on A.
SEED() {
  jq -nc --arg u "$URL" --arg a "$A" --arg b "$B" --argjson old "$OLD" '
    {project:"tproj",rkey:"tproj-TK-9",first_seen:"2026-10-20 01:00:00Z",
     rebuilds:3,mechanicals:1,regens:0,fixrounds:2,adjudications:0,rereviews:0,outcome:"",
     rebuild_jobs:[{id:"TK-9~r1",enqueued_at:"2026-10-19 01:00:00Z"},
                   {id:"TK-9~r2",enqueued_at:"2026-10-19 05:00:00Z"},
                   {id:"TK-9~r3",enqueued_at:"2026-10-19 09:00:00Z"}],
     attempts:[{at:"2026-10-20 02:00:00Z",action:"mechanical",reason:"red-twice",detail:"merged origin/main",head:$a},
               {at:"2026-10-20 02:10:00Z",action:"fix-round",reason:"red-twice",detail:"agent rc=1",url:$u,head:$a},
               {at:"2026-10-20 02:20:00Z",action:"fix-round",reason:"red-twice",detail:"agent rc=1",url:$u,head:$a}],
     rung_head:$a,rung_pr:$u,sup_pr:$u,sup_head:$a,sup_at:$old,sup_settle:true}
    | '"$1" > "$RECF"
}
REC() { jq -r "$1" "$RECF" 2>/dev/null; }
CLOSED() { grep -q -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null; }
RUN_N() { local i; for i in $(seq 1 "$1"); do RUN; done; }

# ============================================================================
# A1 (acceptance 1). Rungs on A, the PR is on B now, the conductor re-parked it
#    on B, and the settle window has run out: the tick resets, closes nothing.
# ============================================================================
FRESH
SEED '.sup_head = $b'
PARK "$B"; printf '%s' "$B" > "$T/prhead"
RUN
CLOSED && bad "A1: a PR whose head moved after its last counted rung must NOT be closed (closed: $(cat "$T/closed.txt"); log: $(tail -3 "$LOGF"))" || ok
[ "$(REC .outcome)" = "" ] && ok || bad "A1: no outcome may be recorded (got $(REC .outcome))"
[ ! -s "$T/queue.txt" ] && ok || bad "A1: nothing may be enqueued (queue: $(cat "$T/queue.txt"))"
[ "$(REC '[.mechanicals,.regens,.fixrounds]|map(tostring)|join(" ")')" = "0 0 0" ] && ok \
  || bad "A1: the per-head counters must reset to 0 (got $(REC '[.mechanicals,.regens,.fixrounds]'))"
[ "$(REC .rebuilds)" = 3 ] && ok || bad "A1: the ticket-wide rebuild count must stay 3 (got $(REC .rebuilds))"
[ "$(REC '.head_resets // 0')" = 1 ] && ok || bad "A1: head_resets must be 1 (got $(REC .head_resets))"
[ "$(REC '.ladder_reset.from') $(REC '.ladder_reset.to') $(REC '.ladder_reset.base.fixround')" = "$A $B 2" ] && ok \
  || bad "A1: ladder_reset must name A -> B with a fix-round baseline of 2 (got $(REC -c .ladder_reset))"
[ "$(REC '[.attempts[]|select(.action=="head-reset")]|length')" = 1 ] && ok \
  || bad "A1: exactly one head-reset attempt (got $(REC '[.attempts[].action]|join(",")'))"
REC '[.attempts[]|select(.action=="head-reset")][0].detail' | grep -q "${A:0:12}.*${B:0:12}" && ok \
  || bad "A1: the head-reset attempt must name both heads (got $(REC '[.attempts[]|select(.action=="head-reset")][0].detail'))"
[ "$(grep -c 'EVENT resolver_head_reset' "$LOGF")" = 1 ] && ok \
  || bad "A1: one EVENT resolver_head_reset line (got $(grep -c 'EVENT resolver_head_reset' "$LOGF"))"
grep -q 'EVENT resolver_abandoned' "$LOGF" && bad "A1: no abandoned event may be written" || ok

# A1b. Next tick, same head B, no rung has run on it: the ladder climbs from
#      rung 1 again, it does not close. Rung 1 cannot START here (mc_rebase rc 4).
: > "$LOGF"; echo 4 > "$T/rebase-rc"
RUN
grep -q 'rung 1 mechanical' "$LOGF" && ok || bad "A1b: the next tick must run rung 1 on the new head (log: $(tail -3 "$LOGF"))"
CLOSED && bad "A1b: the tick after a reset must not close the PR" || ok
[ "$(REC .outcome)" = "" ] && ok || bad "A1b: no outcome (got $(REC .outcome))"

# A1c. Rung 1 runs on B and fails (gate red), the fix cap is 0, the rebuild cap
#      is spent: the ladder is exhausted ON B now, so the terminal closes.
: > "$LOGF"; echo 2 > "$T/rebase-rc"
BRENV=("${BASEENV[@]}" BR_MAX_FIXROUNDS=0)
RUN
BRENV=("${BASEENV[@]}")
[ "$(REC .rung_head)" = "$B" ] && ok || bad "A1c: rung 1 on B must record rung_head B (got $(REC .rung_head))"
CLOSED && ok || bad "A1c: a ladder exhausted on the PR's current head must close it (log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" = ABANDONED ] && ok || bad "A1c: outcome must be ABANDONED (got $(REC .outcome))"
[ "$(REC '[.attempts[]|select(.action=="head-reset")]|length')" = 1 ] && ok \
  || bad "A1c: still one head-reset attempt (got $(REC '[.attempts[]|select(.action=="head-reset")]|length'))"

# ============================================================================
# A2. The same record, and the PR is still on A: closed as today, and the close
#     comment names the head it judged and the rungs it counted.
# ============================================================================
FRESH
SEED '.'
PARK "$A"
RUN
CLOSED && ok || bad "A2: a ladder exhausted on the PR's current head must close it (log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" = ABANDONED ] && ok || bad "A2: outcome must be ABANDONED (got $(REC .outcome))"
head -1 "$T/comment-bodies.txt" | grep -q '^Abandoned by `bin/blocked-resolver.sh`' && ok \
  || bad "A2: the close body must still start with the ABANDONED sentence (got: $(head -1 "$T/comment-bodies.txt"))"
grep -q "Judged head: $A" "$T/comment-bodies.txt" && ok \
  || bad "A2: the close body must name the judged head (body: $(tail -3 "$T/comment-bodies.txt"))"
grep -q 'fix round 2' "$T/comment-bodies.txt" && ok \
  || bad "A2: the close body must name the counted fix rounds (body: $(tail -3 "$T/comment-bodies.txt"))"
grep -q 'could not start (not counted): 0' "$T/comment-bodies.txt" && ok \
  || bad "A2: the close body must name the attempts that could not start (body: $(tail -3 "$T/comment-bodies.txt"))"
[ "$(REC '.head_resets // 0')" = 0 ] && ok || bad "A2: no reset on an unchanged head"

# ============================================================================
# A3. The PR is on B because THIS lane's fix round pushed B: not a foreign head.
# ============================================================================
FRESH
SEED '.fix_pr = $u | .fix_head = $b | .fix_base = $a | .fix_at = $old | .sup_head = $b'
PARK "$B"; printf '%s' "$B" > "$T/prhead"
RUN
CLOSED && ok || bad "A3: the lane's own fix-round push is not a new head — the exhausted ladder closes (log: $(tail -4 "$LOGF"))"
[ "$(REC '.head_resets // 0')" = 0 ] && ok || bad "A3: no reset for the lane's own push (got $(REC .head_resets))"

# ============================================================================
# A7. Rebuild-fresh BELOW the cap. A moved head is not superseded and nothing is
#     enqueued; on the same head the supersede close carries the facts.
# ============================================================================
FRESH
SEED '.rebuilds = 0 | .rebuild_jobs = [] | .fixrounds = 1 | .sup_head = $b'
PARK "$B"; printf '%s' "$B" > "$T/prhead"
RUN
CLOSED && bad "A7a: a moved head must not be superseded (log: $(tail -3 "$LOGF"))" || ok
[ ! -s "$T/queue.txt" ] && ok || bad "A7a: nothing may be enqueued on a reset (queue: $(cat "$T/queue.txt"))"
[ "$(REC .rebuilds)" = 0 ] && ok || bad "A7a: no rebuild may be spent (got $(REC .rebuilds))"
[ "$(REC '.head_resets // 0')" = 1 ] && ok || bad "A7a: the ladder must reset for B (got $(REC .head_resets))"

FRESH
SEED '.rebuilds = 0 | .rebuild_jobs = [] | .fixrounds = 1'
PARK "$A"
RUN
CLOSED && ok || bad "A7b: the same head is superseded as today (log: $(tail -3 "$LOGF"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok || bad "A7b: the fresh build must be enqueued (queue: $(cat "$T/queue.txt"))"
head -1 "$T/comment-bodies.txt" | grep -q '^Superseded by a fresh build' && ok \
  || bad "A7b: the supersede body must still start 'Superseded by a fresh build' (got: $(head -1 "$T/comment-bodies.txt"))"
grep -q "Judged head: $A" "$T/comment-bodies.txt" && ok \
  || bad "A7b: the supersede body must name the judged head (body: $(cat "$T/comment-bodies.txt"))"

# ============================================================================
# B1 (acceptance 2, end to end). Rung 1 cannot START (mc_rebase rc 4) on three
#    ticks, on a ticket whose rebuild cap is spent: nothing counts, nothing closes.
# ============================================================================
FRESH
SEED '.mechanicals = 0 | .fixrounds = 0 | .attempts = [] | del(.rung_head, .rung_pr)'
PARK "$A"; echo 4 > "$T/rebase-rc"
RUN_N 3
[ "$(REC '[.mechanicals,.regens,.fixrounds]|map(tostring)|join(" ")')" = "0 0 0" ] && ok \
  || bad "B1: rungs that could not START must not count (got $(REC '[.mechanicals,.regens,.fixrounds]'))"
[ "$(grep -c 'could not START' "$LOGF")" = 3 ] && ok \
  || bad "B1: one 'could not START' line per tick (got $(grep -c 'could not START' "$LOGF"))"
CLOSED && bad "B1: a setup-blocked ladder must never close the PR" || ok
[ "$(REC .outcome)" = "" ] && ok || bad "B1: no ABANDONED outcome (got $(REC .outcome))"

# ============================================================================
# B2 (acceptance 2, at the terminal). Three setup-blocked attempts and no real
#    rung, and the ladder reaches its terminal anyway (rung 1 and the fix round
#    switched off): nothing closed, nothing recorded.
# ============================================================================
FRESH
SEED '.mechanicals = 0 | .fixrounds = 0 | del(.rung_head, .rung_pr)
      | .attempts = [range(3) as $i | {at:"2026-10-20 0\($i):00:00Z",action:"mechanical-blocked",reason:"red-twice",detail:"the mechanical rung could not START: mc_rebase rc=4"}]'
PARK "$A"
BRENV=("${BASEENV[@]}" BR_MAX_MECHANICAL=0 BR_MAX_FIXROUNDS=0)
RUN
CLOSED && bad "B2: a history of rungs that could not START must not close the PR (log: $(tail -3 "$LOGF"))" || ok
[ "$(REC .outcome)" = "" ] && ok || bad "B2: no outcome (got $(REC .outcome))"
grep -q 'no real rung ran (3 attempts could not START)' "$LOGF" && ok \
  || bad "B2: the stop must say no real rung ran (log: $(tail -3 "$LOGF"))"

# B3. Near miss: a setup block, then a real fix round on A, PR still on A: closes.
FRESH
SEED '.mechanicals = 0 | .fixrounds = 1
      | .attempts = [{at:"2026-10-20 01:00:00Z",action:"mechanical-blocked",reason:"red-twice",detail:"could not START"},
                     {at:"2026-10-20 02:00:00Z",action:"fix-round",reason:"red-twice",detail:"agent rc=1",url:$u,head:$a}]'
PARK "$A"
BRENV=("${BASEENV[@]}" BR_MAX_MECHANICAL=0)
RUN
CLOSED && ok || bad "B3: a real rung after a setup block counts — the exhausted ladder closes (log: $(tail -3 "$LOGF"))"
grep -q 'could not start (not counted): 1' "$T/comment-bodies.txt" && ok \
  || bad "B3: the close body must count the one attempt that could not start (body: $(tail -2 "$T/comment-bodies.txt"))"

# ============================================================================
# T1 (lane). Rung 1 reads the PR on A and pushes C: the counted rung is recorded
#    against the head it ran on, A, for this PR.
# ============================================================================
FRESH
PARK "$A"; echo 0 > "$T/rebase-rc"; printf '%s' "$C" > "$T/rebase-out"
RUN
[ "$(REC .mechanicals)" = 1 ] && ok || bad "T1: rung 1 must have run (log: $(tail -3 "$LOGF"))"
[ "$(REC .rung_head) $(REC .rung_pr)" = "$A $URL" ] && ok \
  || bad "T1: a mechanical rung must record rung_head A for this PR (got $(REC .rung_head) $(REC .rung_pr))"
[ "$(REC '.attempts[-1].head')" = "$A" ] && ok || bad "T1: the attempt must carry its head (got $(REC -c '.attempts[-1]'))"

# ============================================================================
# T2 (lane). After a reset with a fix-round baseline of 2, the rows still say 2.
#    The fix round must be offered on B, not read as spent. Observe mode, so
#    the round itself is not bought.
# ============================================================================
FRESH
SEED '.mechanicals = 1 | .fixrounds = 0 | .rebuilds = 0 | .rebuild_jobs = [] | .rung_head = $b | .sup_head = $b
      | .ladder_reset = {url:$u, from:$a, to:$b, at:"2026-10-20 03:00:00Z", base:{fixround:2}}'
PARK "$B"; printf '%s' "$B" > "$T/prhead"
touch "$T/rows-on"; echo 2 > "$T/rows-fixround"; touch "$H/flags/blocked-resolver-observe"
RUN
grep -q 'WOULD run a fix round' "$LOGF" && ok \
  || bad "T2: the rows must not undo the reset — a fix round is due on B (log: $(tail -3 "$LOGF"))"
grep -q 'the fix round already ran' "$LOGF" && bad "T2: the baseline was not subtracted" || ok
# ...and rows ABOVE the baseline still count: a round on B is a spent round.
: > "$LOGF"; echo 3 > "$T/rows-fixround"
RUN
grep -q 'the fix round already ran 1 time' "$LOGF" && ok \
  || bad "T2: rows above the baseline must still count (log: $(tail -3 "$LOGF"))"

# ============================================================================
# U. The gate and the record layer, driven directly on a scratch record: the
#    real bin/lib/br modules, GitHub's PR object served from a file through the
#    gate's own jq filter.
# ============================================================================
U="$T/u"; mkdir -p "$U/state/tproj"
cat > "$T/u-pre.sh" <<EOF
set -u
H="$U"; ST="$U/state"; LOG="$U/log"; OBSERVE="\${OBSERVE:-0}"
STAMP() { printf '2026-10-20 06:00:00Z'; }
say() { printf '%s\n' "\$*" >> "\$LOG"; }
br_is_sha() { [[ "\${1:-}" =~ ^[0-9a-f]{40}\$ ]]; }
br_slug_of_url() { case "\${1:-}" in https://github.com/*/*/pull/*) local s="\${1#https://github.com/}"; printf '%s' "\${s%/pull/*}" ;; *) return 1 ;; esac; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
# br_pr_field: the real contract's rc (0 / 44 absent / 75 unread), the real
# filter applied to a PR object on disk.
br_pr_field() {
  printf '%s\n' "\$1" >> "$U/reads"
  local rc; rc=\$(cat "$U/pr-rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || return "\$rc"
  jq -r "\$2 // empty" "$U/pr.json"
}
. "$DIR/bin/lib/br/record.sh" || exit 9
. "$DIR/bin/lib/br/ladder.sh" || exit 9
. "$DIR/bin/lib/br/headgate.sh" || exit 9
eval "\$(declare -f br_save | sed '1s/^br_save/br_save_real/')"
br_save() { [ -e "$U/save-fail" ] && return 1; br_save_real "\$@"; }
EOF
URF="$U/state/tproj/$CK.json"
UNIT() { ( . "$T/u-pre.sh"; eval "$1" ) 2>>"$U/err"; }
GATE() { UNIT "br_head_gate tproj $CK ${1:-red-twice} $URL; echo \"rc=\$? head=\${BR_GATE_HEAD:-}\""; }
UPR() { jq -nc --arg s "$1" --arg h "$2" '{state:$s, head:{sha:$h}}' > "$U/pr.json"; rm -f "$U/pr-rc"; }
USEED() { SEED "$1"; cp "$RECF" "$URF"; : > "$U/log"; rm -f "$U/save-fail"; }

# T1 (record). A fix round passes its head (any case) and its url; a rung with
# no head takes the head the lane last read; an unbumped attempt moves nothing.
USEED '.sup_head = $b'
UNIT "br_record tproj $CK fix-round red-twice 'agent rc=1' fixrounds $URL ${A^^}"
[ "$(jq -r '.rung_head+" "+.rung_pr' "$URF")" = "$A $URL" ] && ok \
  || bad "T1u: a fix round on A must record rung_head A (got $(jq -c '{rung_head,rung_pr}' "$URF"))"
UNIT "br_record tproj $CK mechanical red-twice 'merged' mechanicals"
[ "$(jq -r .rung_head "$URF")" = "$B" ] && ok || bad "T1u: a rung with no head takes sup_head (got $(jq -r .rung_head "$URF"))"
UNIT "br_record tproj $CK mechanical-blocked red-twice 'could not START'"
[ "$(jq -r .rung_head "$URF")" = "$B" ] && ok || bad "T1u: an unbumped attempt must not move rung_head"

# T2 (record). br_cap_rows subtracts the baseline only for this PR's fixround.
cat >> "$T/u-pre.sh" <<EOF
pr_rows_on() { return 0; }
pr_attempt_count() { printf '%s' "\$(cat "$U/rows")"; return 0; }
EOF
echo 2 > "$U/rows"
R1=$(UNIT "br_cap_rows tproj $CK red-twice 0 $URL fixround fixrounds '{\"ladder_reset\":{\"url\":\"$URL\",\"base\":{\"fixround\":2}}}'")
R2=$(UNIT "br_cap_rows tproj $CK red-twice 0 $URL fixround fixrounds '{\"ladder_reset\":{\"url\":\"https://github.com/o/tproj/pull/8\",\"base\":{\"fixround\":2}}}'")
R3=$(UNIT "br_cap_rows tproj $CK red-twice 0 $URL fixround fixrounds")
[ "$R1 $R2 $R3" = "0 2 2" ] && ok || bad "T2u: baseline only for this PR (got '$R1 $R2 $R3', want '0 2 2')"

# A4 (R5b). After A1's reset to B, a second terminal on B with no rung since:
# rc 0 (the close proceeds), and no second reset.
USEED '.sup_head = $b'; UPR open "$B"
OUT=$(GATE)
[ "$OUT" = "rc=5 head=$B" ] && ok || bad "A4: the first terminal on B resets (got '$OUT')"
OUT=$(GATE)
[ "$OUT" = "rc=0 head=$B" ] && ok || bad "A4: the second terminal on the reset head proceeds (got '$OUT')"
[ "$(jq -r .head_resets "$URF")" = 1 ] && ok || bad "A4: one reset per foreign head (got $(jq -r .head_resets "$URF"))"
# A third head after the reset resets again, and the baseline accumulates.
UPR open "$C"
OUT=$(GATE)
[ "$OUT" = "rc=5 head=$C" ] && [ "$(jq -r '.ladder_reset.to+" "+(.ladder_reset.base.fixround|tostring)' "$URF")" = "$C 2" ] && ok \
  || bad "A4: a later foreign head resets again (got '$OUT', $(jq -c .ladder_reset "$URF"))"

# A5. The head cannot be read (rate limit): rc 75, record byte-identical.
USEED '.'; echo 75 > "$U/pr-rc"
cp "$URF" "$T/before.json"
OUT=$(GATE)
[ "$OUT" = "rc=75 head=" ] && ok || bad "A5: an unreadable head is rc 75 (got '$OUT')"
cmp -s "$URF" "$T/before.json" && ok || bad "A5: the record must be unchanged byte for byte"
grep -q 'nothing closed' "$U/log" && ok || bad "A5: one line must say nothing was closed (log: $(cat "$U/log"))"

# A6. The reset cannot be written: rc 75, no event, the counters stand.
USEED '.'; UPR open "$B"; touch "$U/save-fail"
OUT=$(GATE)
[ "$OUT" = "rc=75 head=$B" ] && ok || bad "A6: a failed reset write is rc 75 (got '$OUT')"
grep -q 'EVENT resolver_head_reset' "$U/log" && bad "A6: no event may claim a reset that was not written" || ok
[ "$(jq -r .fixrounds "$URF")" = 2 ] && ok || bad "A6: the counters stand"

# U1. A closed or merged PR is not gated, and a 404 is absence.
USEED '.'; UPR closed "$B"
[ "$(GATE)" = "rc=0 head=" ] && ok || bad "U1: a closed PR is not gated (got '$(GATE)')"
echo 44 > "$U/pr-rc"
[ "$(GATE)" = "rc=0 head=" ] && ok || bad "U1: a 404 PR is not gated"
# U2. A legacy record (no rung head) and a rung head for ANOTHER PR: today's path.
USEED 'del(.rung_head, .rung_pr)'; UPR open "$B"
[ "$(GATE)" = "rc=0 head=$B" ] && ok || bad "U2: a legacy record keeps today's path (got '$(GATE)')"
USEED '.rung_pr = "https://github.com/o/tproj/pull/8"'; UPR open "$B"
[ "$(GATE)" = "rc=0 head=$B" ] && ok || bad "U2: a rung head for another PR protects nothing here (got '$(GATE)')"
# U3. GitHub's head in upper case is the same head; a short one is unreadable.
USEED '.'; UPR open "${A^^}"
[ "$(GATE)" = "rc=0 head=$A" ] && ok || bad "U3: an upper-case head is the same head (got '$(GATE)')"
UPR open "${A:0:7}"
[ "$(GATE | cut -d' ' -f1)" = "rc=75" ] && ok || bad "U3: a short head with a rung head recorded is rc 75 (got '$(GATE)')"
# U4. Observe mode: WOULD, rc 5, no write.
USEED '.'; UPR open "$B"; cp "$URF" "$T/before.json"
OUT=$(OBSERVE=1 GATE)
[ "$OUT" = "rc=5 head=$B" ] && cmp -s "$URF" "$T/before.json" && grep -q 'WOULD reset' "$U/log" && ok \
  || bad "U4: observe mode logs WOULD reset and writes nothing (got '$OUT', log: $(cat "$U/log"))"
# U5. R6 reads past bookkeeping attempts; a rebuild-only reason is not a ladder.
USEED '.mechanicals = 0 | .fixrounds = 0 | del(.rung_head, .rung_pr)
       | .attempts = [{action:"mechanical-blocked"},{action:"held"},{action:"head-reset"}]'; UPR open "$A"
[ "$(GATE)" = "rc=5 head=$A" ] && ok || bad "U5: setup-blocked under bookkeeping still stops (got '$(GATE)')"
[ "$(GATE build-dead)" = "rc=0 head=$A" ] && ok || bad "U5: a rebuild-only reason is not stopped by R6 (got '$(GATE build-dead)')"

echo "blocked-resolver-head-gate.bh-7660: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
