#!/bin/bash
# tests/rebase-train-handoff.bh-9167-test.sh — the rebase train's park becomes a
# conductor hand-off that bin/blocked-resolver.sh takes onto its rebase-conflict
# ladder, up to rebuild-fresh (BH-9167).
#
# THE BUG THIS PINS. After 2 STRIKE lines bin/rebase-train.sh appended the PR to
# state/rebase-train-skip.txt and wrote an ALERTS line that promised a conductor
# conflict-unresolvable park and a fresh rebuild. Nothing wrote the park, so the
# row stayed NEEDS_REBASE and the resolver never listed the PR (project-4 #2325
# and #2326, 23h).
#
#   A  rth_park_why: the train's detail line -> the conductor reason
#   B  rth_handoff / rth_handed: every state of the hand-off decision
#   C  the REAL bin/rebase-train.sh, run over 6 records: the 2-strike path, the
#      skip-list recovery, and the PRs it must not hand off; a second run costs
#      no read for a hand-off that stands
#   D  the REAL bin/blocked-resolver.sh over the park C wrote:
#      [conductor/conflict-unresolvable] and `ladder rung: rebuild-fresh` with
#      the cheaper rungs spent, `ladder rung: mechanical` with fresh counters
#   E  the same run with the pre-BH-9167 train block put back: no park, no
#      candidate. A revert of the fix is red here.
# No network, no real token: gh is a stub, GH_TOKEN is empty.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/rebase-train-handoff.bh-9167-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/rebase-train-handoff.sh"
TRAIN_SRC="$DIR/bin/rebase-train.sh"
[ -r "$LIB" ] || bad "setup: $LIB is missing"
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
STAMPAT() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%d %H:%M:%SZ'; }
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

# ── the scratch harness (built once per section by mkh) ─────────────────────
# mkh <dir> — the resolver, its modules, the conductor lib, the train and its
#   libs, a recording alert-line.sh and inert stubs for every lane they start.
mkh() {
  local h="$1" f
  mkdir -p "$h/bin/lib/mc" "$h/logs" "$h/state/merge-conductor" "$h/state/build-queue/tproj" \
           "$h/flags" "$h/locks" "$h/env" "$h/builds"
  cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
     "$DIR/bin/box-for.sh" "$TRAIN_SRC" "$h/bin/"
  # shellcheck source=tests/lib/br-modules.sh
  . "$DIR/tests/lib/br-modules.sh" || return 1
  br_modules_install "$DIR" "$h" || return 1
  for f in bin/lib/merge-conductor-lib.sh bin/lib/gh-pr-list.sh bin/lib/rebuild-ledger.sh \
           bin/lib/env-path.sh bin/lib/verdict-parse.sh bin/lib/pr-terminal.sh; do
    scratch_install_closure "$f" "$h" >/dev/null || return 1
  done
  if [ -r "$LIB" ]; then scratch_install_closure bin/lib/rebase-train-handoff.sh "$h" >/dev/null || return 1; fi
  cp "$DIR/bin/lib/mc/MODULES" "$h/bin/lib/mc/" || return 1
  printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$h/fleet.conf"
  : > "$h/env/global.env"
  for f in agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh beat.sh lane-alert.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$h/bin/$f"
  done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$h" > "$h/bin/alert-line.sh"
  cat > "$h/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$h/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
  chmod +x "$h/bin/"*.sh
  touch "$h/flags/fly-pool-tproj"
  mkdir -p "$T/repos/tproj"
}

mkdir -p "$T/fakebin"
# The gh stub. A train PR read (`-X GET .../pulls/<n>`) is answered from
# $GHT/pr-<n>.json, the REST shape prt_fields reads; every other -i route goes
# to the shared stub. Every call is logged to $GHT/gh.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$GHT/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
. "$DIR/tests/lib/gh-rest-stub.sh"
case "\$*" in
  *"-i -X GET"*"/pulls/"*) if [ -f "\$GHT/pr-\$N.json" ]; then _ghs_send 200 "\$(cat "\$GHT/pr-\$N.json")"; else gh_rest_stub "\$@"; fi ;;
  *"-i -X "*) gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "\$GHT/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)   cat "\$GHT/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN.
export GH_TOKEN="" GH_ENTERPRISE_TOKEN="" HARNESS_SECRET=""

# MC <harness> <commands> — run <commands> with the conductor lib, the new lib
#   and mc_init loaded, as the train loads them.
MC() {
  local h="$1"; shift
  ( export HARNESS="$h"
    # shellcheck source=/dev/null
    . "$h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 97
    # shellcheck source=/dev/null
    . "$h/bin/lib/rebase-train-handoff.sh" 2>/dev/null || exit 98
    mc_init >/dev/null 2>&1
    eval "$*" )
}
# row <harness> <n> <state> <head> <reason> — one conductor row for o/tproj#<n>.
row() {
  printf 'o/tproj#%s\t%s\t%s\t%s\t%s\t-\t%s\thttps://github.com/o/tproj/pull/%s\n' \
    "$2" "$3" "$NOW" "$4" "$4" "$5" "$2" >> "$1/state/merge-conductor/pr-state.tsv"
}
U() { printf 'https://github.com/o/tproj/pull/%s' "$1"; }

# ============================================================================
# A. rth_park_why — the train's own detail lines (bin/rebase-train.sh: the
#    four `STRIKE` sites) map to a reason mc_handoff_owns and br_reason_of know.
# ============================================================================
A="$T/a"; mkh "$A" || bad "A: setup failed"
TL="$T/a-train.log"
why() { MC "$A" "rth_park_why '$TL' '$1'"; }
U23=$(U 23); U232=$(U 232)
TAIL='rebase-train parked it after 2 failed rounds'
casea() { # casea <name> <expected> <log lines...>
  local name="$1" want="$2" got; shift 2
  printf '%s\n' "$@" > "$TL"
  got=$(why "$U23")
  [ "$got" = "$want" ] && ok || bad "A/$name: rth_park_why gave '$got', want '$want'"
}
S1="$(STAMPAT 600) [tproj]"; S2="$(STAMPAT 300) [tproj]"
casea conflict "conflict-unresolvable: a.ts src/b.ts — $TAIL" \
  "$S1 $U23 rebasing (ticket/x)" "$S1 STRIKE $U23" "$S1 $U23 conflict outside the auto classes (a.ts src/b.ts ) — left for judgment"
casea resolver-failed "conflict-unresolvable: $TAIL" \
  "$S1 STRIKE $U23" "$S1 $U23 conflict outside the auto classes (resolver failed) — left for judgment"
casea stopped "conflict-unresolvable: $TAIL (rebase stopped more than 6 times)" \
  "$S1 STRIKE $U23" "$S1 $U23 rebase stopped >6 times — left for judgment"
casea typecheck "rebase-gate-red: $TAIL (typecheck: 3 new errors)" \
  "$S1 STRIKE $U23" "$S1 $U23 typecheck: 3 NEW error(s) vs baseline — not pushed"
casea unit "rebase-gate-red: $TAIL (unit tests red)" \
  "$S1 STRIKE $U23" "$S1 $U23 unit tests RED post-rebase — not pushed"
casea near-232 "conflict-unresolvable: $TAIL" \
  "$S1 STRIKE $U23" "$S1 $U232 conflict outside the auto classes (x.ts ) — left for judgment"
casea strike-232-only "conflict-unresolvable: $TAIL" \
  "$S1 STRIKE $U232" "$S1 $U23 conflict outside the auto classes (x.ts ) — left for judgment"
casea newest-wins "conflict-unresolvable: c.ts — $TAIL" \
  "$S1 STRIKE $U23" "$S1 $U23 typecheck: 2 NEW error(s) vs baseline — not pushed" \
  "$S2 STRIKE $U23" "$S2 $U23 conflict outside the auto classes (c.ts ) — left for judgment"
casea interleaved "conflict-unresolvable: d.ts — $TAIL" \
  "$S1 STRIKE $U23" "$S1 STRIKE $U232" "$S1 $U232 unit tests RED post-rebase — not pushed" \
  "$S1 $U23 conflict outside the auto classes (d.ts ) — left for judgment"
casea success-line-skipped "rebase-gate-red: $TAIL (unit tests red)" \
  "$S1 STRIKE $U23" "$S1 $U23 conflicts auto-unioned across 2 stop(s)" "$S1 $U23 unit tests RED post-rebase — not pushed"
casea no-strike "conflict-unresolvable: $TAIL" "$S1 $U23 rebasing (ticket/x)"
casea no-log "conflict-unresolvable: $TAIL"
rm -f "$TL"; G=$(why "$U23"); [ "$G" = "conflict-unresolvable: $TAIL" ] && ok || bad "A/missing-log: got '$G'"
# Every reason is on the resolver's rebase-conflict ladder and adds no false path.
for R in "conflict-unresolvable: a.ts src/b.ts — $TAIL" "rebase-gate-red: $TAIL (typecheck: 3 new errors)" \
         "conflict-unresolvable: $TAIL (rebase stopped more than 6 times)"; do
  P=$(H="$A" bash -c '. "$1/bin/lib/br/ladder.sh" 2>/dev/null; br_reason_of "$2"' _ "$A" "$R")
  case "$P" in conflict-unresolvable|rebase-gate-red) ok ;; *) bad "A: br_reason_of '$R' gave '$P'" ;; esac
done
PATHS=$(sed -n '/^br_paths_of_reason() {/,/^}/p' "$DIR/bin/blocked-resolver.sh" > "$T/bpr.sh"; \
        bash -c '. "$1"; br_paths_of_reason "$2"' _ "$T/bpr.sh" "conflict-unresolvable: a.ts src/b.ts — $TAIL" | tr '\n' ' ')
[ "$PATHS" = "a.ts src/b.ts " ] && ok || bad "A: br_paths_of_reason must read only the two paths (got '$PATHS')"

# ============================================================================
# B. rth_handoff / rth_handed — every row of the decision table.
# ============================================================================
B="$T/b"; mkh "$B" || bad "B: setup failed"
ROWS="$B/state/merge-conductor/pr-state.tsv"; ATT="$B/state/merge-conductor/attempts.txt"
MCLOG="$B/logs/merge-conductor.log"
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
WHY="conflict-unresolvable: src/a.ts — $TAIL"
HO() { MC "$B" "w=\$(rth_handoff '$(U "$1")' '$2' '' '${3:-$WHY}'); echo \"\$w rc=\$?\""; }
st() { awk -F'\t' -v k="o/tproj#$1" '$1==k {print $2 "|" $4 "|" $7}' "$ROWS"; }
# no-row
G=$(HO 101 "$H1"); [ "$G" = "no-row rc=1" ] && ok || bad "B/no-row: got '$G'"
[ ! -s "$ATT" ] || ! grep -q '#101' "$ATT" && ok || bad "B/no-row: must write no marker"
# bad-head
row "$B" 102 NEEDS_REBASE "$H1" "head-lag"
for HD in "" - abc12; do
  G=$(HO 102 "$HD"); [ "$G" = "bad-head rc=1" ] && ok || bad "B/bad-head '$HD': got '$G'"
done
[ "$(st 102)" = "NEEDS_REBASE|$H1|head-lag" ] && ok || bad "B/bad-head: the row must not change ($(st 102))"
# conductor-park: byte-identical
row "$B" 103 BLOCKED_HUMAN "$H1" "conflict-unresolvable: CONFLICT (content): src/z.ts"
BEFORE=$(grep 'o/tproj#103' "$ROWS")
G=$(HO 103 "$H1"); [ "$G" = "conductor-park rc=3" ] && ok || bad "B/conductor-park: got '$G'"
[ "$(grep 'o/tproj#103' "$ROWS")" = "$BEFORE" ] && ok || bad "B/conductor-park: the conductor's row must stay byte-identical"
grep -q 'trainhandoff o/tproj#103' "$ATT" 2>/dev/null && bad "B/conductor-park: no marker may be written" || ok
# handed
G=$(HO 102 "$H1"); [ "$G" = "handed rc=0" ] && ok || bad "B/handed: got '$G'"
[ "$(st 102)" = "BLOCKED_HUMAN|$H1|$WHY" ] && ok || bad "B/handed: the row must be BLOCKED_HUMAN on the head with the reason ($(st 102))"
[ -s "$B/state/merge-conductor/handoff/o_tproj_102" ] && ok || bad "B/handed: mc_transition must record the hand-off file"
grep -qxF "trainhandoff o/tproj#102 $H1" "$ATT" && ok || bad "B/handed: the trainhandoff marker is missing ($(cat "$ATT" 2>/dev/null))"
grep -q "o/tproj#102 BLOCKED_AGENT $WHY — handed to bin/blocked-resolver.sh (rebase-train: 2 failed rounds" "$MCLOG" && ok \
  || bad "B/handed: the hand-off log line is missing ($(tail -3 "$MCLOG"))"
sed -n '/^br_handoff_lines() {/,/^}/p' "$DIR/bin/blocked-resolver.sh" > "$T/bhl.sh"
HL=$(H="$B" bash -c '. "$1"; br_handoff_lines' _ "$T/bhl.sh")
grep -qxF "o/tproj#102	conflict-unresolvable	$(U 102)" <<<"$HL" && ok \
  || bad "B/handed: the real br_handoff_lines must parse the line (got '$HL')"
MC "$B" "mc_handoff_sticky 'o/tproj#102' '$H1'" && ok || bad "B/handed: mc_handoff_sticky must hold the park"
# already (park stands)
G=$(HO 102 "$H1"); [ "$G" = "already rc=3" ] && ok || bad "B/already: got '$G'"
[ "$(grep -c 'o/tproj#102 BLOCKED_AGENT' "$MCLOG")" = 1 ] && ok || bad "B/already: a second call must log nothing"
# already (the resolver released it, the conductor moved the row on)
MC "$B" "mc_handoff_release 'o/tproj#102' blocked-resolver/mechanical"
sed -i "/^o\/tproj#102	/d" "$ROWS"; row "$B" 102 NEEDS_REBASE "$H1" "head-lag"
G=$(HO 102 "$H1"); [ "$G" = "already rc=3" ] && ok || bad "B/released: got '$G'"
[ "$(st 102)" = "NEEDS_REBASE|$H1|head-lag" ] && ok || bad "B/released: the row must not be re-parked ($(st 102))"
# a new head is a new hand-off
sed -i "/^o\/tproj#102	/d" "$ROWS"; row "$B" 102 NEEDS_REBASE "$H2" "head-lag"
G=$(HO 102 "$H2"); [ "$G" = "handed rc=0" ] && ok || bad "B/new-head: got '$G'"
[ "$(st 102)" = "BLOCKED_HUMAN|$H2|$WHY" ] && ok || bad "B/new-head: ($(st 102))"
# race: a conductor tick overwrote the park, no release -> written again
row "$B" 104 NEEDS_REBASE "$H1" "head-lag"
G=$(HO 104 "$H1"); [ "$G" = "handed rc=0" ] && ok || bad "B/race-1: got '$G'"
sed -i "/^o\/tproj#104	/d" "$ROWS"; row "$B" 104 NEEDS_REBASE "$H1" "head-lag"
MC "$B" "rth_handed 'o/tproj#104' '$H1'" && bad "B/race: rth_handed must say no for an overwritten park" || ok
G=$(HO 104 "$H1"); [ "$G" = "handed rc=0" ] && ok || bad "B/race-2: got '$G'"
[ "$(st 104)" = "BLOCKED_HUMAN|$H1|$WHY" ] && ok || bad "B/race: ($(st 104))"
# provenance (a reason no lane owns) moves to a hand-off reason
row "$B" 105 BLOCKED_HUMAN "$H1" "provenance"
G=$(HO 105 "$H1"); [ "$G" = "handed rc=0" ] && ok || bad "B/provenance: got '$G'"
[ "$(st 105)" = "BLOCKED_HUMAN|$H1|$WHY" ] && ok || bad "B/provenance: ($(st 105))"
[ -s "$B/state/merge-conductor/handoff/o_tproj_105" ] && ok || bad "B/provenance: the re-reason must record the hand-off"
# no conductor lib: one word, rc 1
G=$( (. "$LIB"; w=$(rth_handoff "$(U 106)" "$H1" "" "$WHY"); echo "$w rc=$?") )
[ "$G" = "no-conductor-lib rc=1" ] && ok || bad "B/no-lib: got '$G'"

# ============================================================================
# C. THE REAL TRAIN. Six records:
#    #9  2 STRIKEs, DIRTY, row NEEDS_REBASE  -> handed by the strike path
#    #21 skip-listed, DIRTY, row NEEDS_REBASE -> handed by the recovery
#    #22 skip-listed, CLEAN                   -> one read, nothing written
#    #23 skip-listed, known merged            -> no read, nothing written
#    #24 2 STRIKEs, DIRTY, NO conductor row    -> ALERTS says NOT written
#    #25 skip-listed, DIRTY, not our author   -> one read, nothing written
# ============================================================================
HEAD9=9999999999999999999999999999999999999999
# setup_train <harness> — the records, the PR answers, the rows, the train log.
setup_train() {
  local h="$1" n rec
  for n in 9 21 22 23 24 25; do
    rec="$h/builds/tproj-TK-$n-202611070000"; mkdir -p "$rec"
    printf 'PR_CREATED %s\n' "$(U "$n")" > "$rec/RESULT"
    printf 'VERDICT: APPROVE\n' > "$rec/review.md"
    jq -nc --arg s "$(printf '%040d' "$n" | tr 0 9)" --arg n "$n" \
      --arg m "$( [ "$n" = 22 ] && echo clean || echo dirty)" \
      --arg u "$( [ "$n" = 25 ] && echo someone-else || echo app/cromford)" \
      '{state:"open",merged_at:null,mergeable_state:$m,user:{login:$u},head:{sha:$s,ref:("ticket/ts-" + $n)}}' \
      > "$h/gh/pr-$n.json"
    row "$h" "$n" NEEDS_REBASE "$(printf '%040d' "$n" | tr 0 9)" "head-lag"
  done
  printf 'merged %s %s\n' "$NOW" "$(U 23)" > "$h/builds/tproj-TK-23-202611070000/pr-terminal"
  sed -i '/^o\/tproj#24	/d' "$h/state/merge-conductor/pr-state.tsv"
  printf '%s\n' "$(U 21)" "$(U 22)" "$(U 23)" "$(U 25)" > "$h/state/rebase-train-skip.txt"
  { for n in 9 24; do
      printf '%s STRIKE %s\n' "$S1" "$(U "$n")"
      printf '%s %s conflict outside the auto classes (src/a.ts ) — left for judgment\n' "$S1" "$(U "$n")"
      printf '%s STRIKE %s\n' "$S2" "$(U "$n")"
      printf '%s %s conflict outside the auto classes (src/a.ts src/b.ts ) — left for judgment\n' "$S2" "$(U "$n")"
    done; } > "$h/logs/rebase-train.log"
}
# train <harness> — one run of bin/rebase-train.sh tproj.
train() {
  ( cd "$T" && env -i PATH="$PATH" HOME="$T" TMPDIR="$T" HARNESS="$1" HARNESS_ENV_DIR="$1/env" \
      REPOS_ROOT="$T/repos" GHT="$1/gh" GH_TOKEN="" HARNESS_SECRET="" HARNESS_TEST_SANDBOX=1 \
      HARNESS_PR_AUTHORS="app/cromford" _VP_WINDOW=3 \
      bash "$1/bin/rebase-train.sh" tproj >>"$1/train-run.txt" 2>&1 ) || echo "rc=$?" >> "$1/train-run.txt"
}
reads() { grep -c -- "-X GET .*/pulls/$2\$\|-X GET .*/pulls/$2 " "$1/gh/gh.txt" 2>/dev/null; }

C="$T/c"; mkh "$C" || bad "C: setup failed"; mkdir -p "$C/gh"; : > "$C/gh/gh.txt"
setup_train "$C"
train "$C"
CROWS="$C/state/merge-conductor/pr-state.tsv"; TLOG="$C/logs/rebase-train.log"; CAL="$C/logs/ALERTS.log"
cst() { awk -F'\t' -v k="o/tproj#$1" '$1==k {print $2 "|" $7}' "$CROWS"; }
WHY9="conflict-unresolvable: src/a.ts src/b.ts — $TAIL"
# #9: the strike path
[ "$(cst 9)" = "BLOCKED_HUMAN|$WHY9" ] && ok \
  || bad "C/#9: THE BUG — a 2-strike park must become a BLOCKED_HUMAN conflict-unresolvable row (row: $(cst 9); run: $(tail -5 "$C/train-run.txt"))"
grep -qxF "$(U 9)" "$C/state/rebase-train-skip.txt" && ok || bad "C/#9: the PR must be on the skip list"
grep -qF "[rebase-train] $(U 9) parked after 2 failed rounds — handed to bin/blocked-resolver.sh as conflict-unresolvable" "$CAL" && ok \
  || bad "C/#9: the ALERTS line must name the hand-off (alerts: $(cat "$CAL" 2>/dev/null))"
grep -q "o/tproj#9 BLOCKED_AGENT conflict-unresolvable: .*handed to bin/blocked-resolver.sh" "$C/logs/merge-conductor.log" && ok \
  || bad "C/#9: the conductor log must carry the hand-off line"
# #21: the recovery of a PR parked before the fix
[ "$(cst 21)" = "BLOCKED_HUMAN|conflict-unresolvable: $TAIL" ] && ok \
  || bad "C/#21: a skip-listed DIRTY PR must be handed off (row: $(cst 21))"
grep -qF "$(U 21) parked earlier — handed" "$TLOG" && ok || bad "C/#21: the train log must say 'parked earlier — handed'"
grep -qF "$(U 21)" "$CAL" && bad "C/#21: the recovery must write no ALERTS line" || ok
# #22, #23, #25: nothing written
[ "$(cst 22)" = "NEEDS_REBASE|head-lag" ] && ok || bad "C/#22: a CLEAN PR must not be handed off ($(cst 22))"
[ "$(cst 23)" = "NEEDS_REBASE|head-lag" ] && ok || bad "C/#23: a merged PR must not be handed off ($(cst 23))"
[ "$(cst 25)" = "NEEDS_REBASE|head-lag" ] && ok || bad "C/#25: a PR not by a harness author must not be handed off ($(cst 25))"
[ "$(reads "$C" 22)" = 1 ] && ok || bad "C/#22: one read (got $(reads "$C" 22))"
[ "$(reads "$C" 23)" = 0 ] && ok || bad "C/#23: a known-merged PR costs no read (got $(reads "$C" 23))"
# #24: no conductor row on this box -> the ALERTS line says so
grep -qF "[rebase-train] $(U 24) parked after 2 failed rounds — hand-off NOT written (no-row)" "$CAL" && ok \
  || bad "C/#24: the ALERTS line must say the hand-off was NOT written (alerts: $(cat "$CAL" 2>/dev/null))"
[ -z "$(cst 24)" ] && ok || bad "C/#24: no row may be invented ($(cst 24))"
# nothing was rebased (BUDGET is spent only by a rebase)
grep -q ' rebasing (' "$TLOG" && bad "C: no PR may be rebased: $(grep ' rebasing (' "$TLOG")" || ok
[ "$(grep -c 'STRIKE' "$TLOG")" = 4 ] && ok || bad "C: no STRIKE line may be added"
grep -q 'rc=' "$C/train-run.txt" && bad "C: the train must exit 0 ($(tail -3 "$C/train-run.txt"))" || ok
# second run: a hand-off that stands costs no read and writes nothing
R9=$(reads "$C" 9); R21=$(reads "$C" 21); NA=$(wc -l < "$CAL"); NL=$(grep -c 'BLOCKED_AGENT' "$C/logs/merge-conductor.log")
train "$C"
[ "$(reads "$C" 9)" = "$R9" ] && [ "$(reads "$C" 21)" = "$R21" ] && ok \
  || bad "C/rerun: a standing hand-off must cost no read (#9 $R9 -> $(reads "$C" 9), #21 $R21 -> $(reads "$C" 21))"
[ "$(wc -l < "$CAL")" = "$NA" ] && ok || bad "C/rerun: no new ALERTS line ($(tail -2 "$CAL"))"
[ "$(grep -c 'BLOCKED_AGENT' "$C/logs/merge-conductor.log")" = "$NL" ] && ok || bad "C/rerun: no second hand-off line"

# ============================================================================
# D. THE ACCEPTANCE CRITERION. The real resolver over the park the real train
#    wrote: a [conductor/conflict-unresolvable] candidate, rebuild-fresh with the
#    two cheaper rungs spent, and mechanical (the first rung) with fresh state.
# ============================================================================
resolver_fixture() { # resolver_fixture <harness>
  local h="$1"
  jq -nc --arg c "$(ISO 604800)" \
    '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9: the report nav",body:"## Scope",created_at:$c}' \
    > "$h/gh/issue-9.json"
  printf '[]\n' > "$h/gh/comments-9.json"
  echo OPEN > "$h/gh/prstate"; printf 'ticket/TK-9' > "$h/gh/prbranch"; printf '%s' "$HEAD9" > "$h/gh/prhead"
  : > "$h/gh/closed.txt"
  # The train's PR answer goes: the shared stub answers the resolver's reads,
  # so a close it makes reads back closed.
  rm -f "$h/gh/pr-9.json"
  # Only #9 is on the resolver's table: the other rows are C's, not D's subject.
  awk -F'\t' '$1=="o/tproj#9"' "$h/state/merge-conductor/pr-state.tsv" > "$h/rows.tmp" \
    && mv "$h/rows.tmp" "$h/state/merge-conductor/pr-state.tsv"
}
spent() { # spent <harness> <mechanicals> <fixrounds>
  mkdir -p "$1/state/blocked-resolver/tproj"
  jq -nc --argjson m "$2" --argjson f "$3" \
    '{project:"tproj",rkey:"tproj-TK-9",mechanicals:$m,fixrounds:$f,rebuilds:0,outcome:"",attempts:[]}' \
    > "$1/state/blocked-resolver/tproj/tproj-TK-9.json"
}
resolve() { # resolve <harness> — one bin/blocked-resolver.sh tproj tick
  ( cd "$T" && env -i PATH="$PATH" HOME="$T" TMPDIR="$T" HARNESS="$1" HARNESS_ENV_DIR="$1/env" \
      FLEET_CONF="$1/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" GHT="$1/gh" \
      GH_TOKEN="" HARNESS_SECRET="" HARNESS_TEST_SANDBOX=1 \
      bash "$1/bin/blocked-resolver.sh" tproj >>"$1/resolver-run.txt" 2>&1 ) || true
}
BRLOG() { cat "$1/logs/blocked-resolver.log" 2>/dev/null; }
# clone <from> <to> — a copy of a harness whose stubs write into the copy.
clone() {
  cp -a "$1" "$2"
  sed -i "s#$1#$2#g" "$2/bin/jobs-client.sh" "$2/bin/alert-line.sh"
}
# The resolver names the PR's row tproj/<rkey>; the rkey ends in the PR number.
CAND='tproj/[^ ]*-9 \[conductor/conflict-unresolvable\]'
RUNG='tproj/[^ ]*-9 \[conflict-unresolvable/rebase-conflict\]: ladder rung:'

D1="$T/d1"; clone "$C" "$D1"
resolver_fixture "$D1"; spent "$D1" 1 1
resolve "$D1"
grep -q "$CAND" <<<"$(BRLOG "$D1")" && ok \
  || bad "D: THE BUG — the train park must be a [conductor/conflict-unresolvable] candidate (log: $(BRLOG "$D1" | tail -5))"
grep -q "$RUNG rebuild-fresh" <<<"$(BRLOG "$D1")" && ok \
  || bad "D: with mechanical and fix round spent the rung must be rebuild-fresh (log: $(BRLOG "$D1" | grep 'TK-9' | tail -3))"
grep -q "$CAND -> rebuild-fresh" <<<"$(BRLOG "$D1")" && ok \
  || bad "D: the rung taken must be rebuild-fresh (log: $(BRLOG "$D1" | grep 'TK-9' | tail -3))"
grep -q '^tproj TK-9 9 ' "$D1/queue.txt" 2>/dev/null && ok \
  || bad "D: the fresh rebuild must be enqueued (queue: $(cat "$D1/queue.txt" 2>/dev/null))"

D2="$T/d2"; clone "$C" "$D2"
resolver_fixture "$D2"; spent "$D2" 0 0
resolve "$D2"
grep -q "$RUNG mechanical" <<<"$(BRLOG "$D2")" && ok \
  || bad "D: with fresh counters the park must start the ladder at mechanical (log: $(BRLOG "$D2" | grep 'TK-9' | tail -3))"

# ============================================================================
# E. RED WITHOUT THE FIX. The same train with the pre-BH-9167 block put back
#    (verbatim below): the park writes no row, so the resolver lists no
#    candidate. A revert of the fix fails here.
# ============================================================================
cat > "$T/old-block.sh" <<'OLD'
  grep -qxF "$PR" "$SKIP" && continue
  verdict_is APPROVE -L "$D/review.md" 2>/dev/null || continue
  command -v prt_read >/dev/null 2>&1 || continue
  prt_known_terminal "$D" "$PR" && continue
  PRJ=$(mktemp "${TMPDIR:-/tmp}/rebase-train-pr.XXXXXX") || continue
  PRC=0; prt_read "$D" "$PR" "$PRJ" || PRC=$?
  STATE=""; [ "$PRC" = 0 ] && STATE=$(prt_fields "$PRJ")
  rm -f "$PRJ"
  read -r PSTATE PMERGE PAUTHOR BR _ <<<"$STATE"
  [ "${PSTATE:-}" = "OPEN" ] && [ "${PMERGE:-}" = "DIRTY" ] && harness_pr_author_match "${PAUTHOR:-}" || continue

  STRIKES=$(grep -c "STRIKE $PR$" "$LOG" 2>/dev/null); STRIKES=${STRIKES:-0}
  if [ "$STRIKES" -ge 2 ]; then
    echo "$PR" >> "$SKIP"
    HARNESS="$H" "$H/bin/alert-line.sh" "[rebase-train] $PR parked after 2 failed rounds — the merge conductor classifies it conflict-unresolvable and bin/blocked-resolver.sh rebuilds the ticket fresh against current main"
    continue
  fi
OLD
E="$T/e"; mkh "$E" || bad "E: setup failed"; mkdir -p "$E/gh"; : > "$E/gh/gh.txt"
awk -v f="$T/old-block.sh" '
  index($0, "# >>> train park hand-off (BH-9167)") { skip = 1; while ((getline l < f) > 0) print l; next }
  skip && index($0, "# <<< train park hand-off") { skip = 0; next }
  !skip { print }' "$TRAIN_SRC" > "$E/bin/rebase-train.sh"
grep -qF 'grep -qxF "$PR" "$SKIP" && continue' "$E/bin/rebase-train.sh" && ! grep -q 'rth_handoff "\$PR"' "$E/bin/rebase-train.sh" && ok \
  || bad "E: the pre-fix train must have no rth_handoff call"
setup_train "$E"; train "$E"
EROWS="$E/state/merge-conductor/pr-state.tsv"
grep -qx NEEDS_REBASE <<<"$(awk -F'\t' '$1=="o/tproj#9" {print $2}' "$EROWS")" && ok \
  || bad "E: without the fix the row must stay NEEDS_REBASE"
grep -qF "$(U 9) parked after 2 failed rounds" "$E/logs/ALERTS.log" && ok || bad "E: the pre-fix train must still park #9"
resolver_fixture "$E"; spent "$E" 1 1
resolve "$E"
grep -q "$CAND" <<<"$(BRLOG "$E")" && bad "E: without the fix there must be no candidate (log: $(BRLOG "$E" | tail -3))" || ok

# ============================================================================
# F. FAIL-OPEN. A conductor module that does not load makes the lib `exit 1`.
#    The train must still run: the park is written to the skip list, the
#    ALERTS line says no hand-off was written, and the train exits 0.
# ============================================================================
F="$T/f"; mkh "$F" || bad "F: setup failed"; mkdir -p "$F/gh"; : > "$F/gh/gh.txt"
rm -f "$F/bin/lib/deployment.sh"
# (scratch.sh exports HARNESS_DEPLOYMENT_FILE; the train runs under env -i.)
( env -u HARNESS_DEPLOYMENT_FILE HARNESS="$F" bash -c '. "$1/bin/lib/merge-conductor-lib.sh"' _ "$F" ) >/dev/null 2>&1 \
  && bad "F: setup — the conductor lib must fail to load without bin/lib/deployment.sh" || ok
setup_train "$F"; train "$F"
grep -q 'rc=' "$F/train-run.txt" && bad "F: the train must exit 0 when the conductor lib does not load ($(tail -3 "$F/train-run.txt"))" || ok
grep -qxF "$(U 9)" "$F/state/rebase-train-skip.txt" && ok || bad "F: the park must still reach the skip list"
grep -qF "[rebase-train] $(U 9) parked after 2 failed rounds — hand-off NOT written (no-conductor-lib)" "$F/logs/ALERTS.log" && ok \
  || bad "F: the ALERTS line must say no hand-off was written (alerts: $(cat "$F/logs/ALERTS.log" 2>/dev/null))"
[ "$(reads "$F" 21)" = 0 ] && ok || bad "F: without the lib a skip-listed PR is dropped with no read, as before (got $(reads "$F" 21))"

echo "rebase-train-handoff.bh-9167-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
