#!/bin/bash
# tests/fixround-nochange.bh-8592-test.sh — BH-8592: a fix round that changed
# no file pushes nothing, and an innocent twice-ejected PR goes back in the
# Mergify queue on the SAME head. A round never pushes while Mergify holds the PR.
#
# THE INCIDENT (2026-10-27). The fix round on #8550 found its queue ejection
# was a batch sibling's fault and committed `--allow-empty` (73aadc64, "no
# change"). br_fix_round saw HEAD != lease and pushed it; Mergify dequeued
# #8550 from batch #8588 (PULL_REQUEST_UPDATED) and the batch merged nothing.
#
#   D1-D9  brnc_nochange over real git trees (the plan's decision table)
#   N*     the REAL bin/blocked-resolver.sh --fix-here (the owning box's half,
#          as bin/fix-round-claim.sh runs it) over a real bare origin:
#          N1 empty commit on queue-ejected-twice: origin unchanged, recorded
#             fix-round-nochange, one PR comment with the round's message
#          N3 no commit at all: same; N10 a clean main merge + empty commit
#          N6 red-ci-twice + empty commit: not pushed, the ladder's terminal
#          N7 a real edit, PR not queued: pushed
#          N5/Q1 a real edit, Mergify holds the PR: NOT pushed, fix-round-queued,
#             brfix/<ck> kept; Q3 merged and Q4 unknown: pushed
#          N8 the same head twice: one comment
#   S*/R*  brnc_settle on the hub (the requeue gates), K* the knobs
#   N9     the box record round trip through the REAL br_fix_adopt: 1 requeue,
#          a second adopt 0
#   NH     brnc_round on the hub: 0 pushes, 1 requeue
#   E*     the br_one block (extracted verbatim): a pending head is settled
#          before the ladder rung
#   A1     three parked records, one pending: 1 requeue, 0 alerts
#   B1     the hub half makes 0 gh calls (every vendor verb is a stub)
# Run from anywhere: tests/fixround-nochange.bh-8592-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
FRAG="$DIR/bin/blocked-resolver.d/bh-8592-fixround-nochange.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
[ -f "$FRAG" ] || bad "F0 bin/blocked-resolver.d/bh-8592-fixround-nochange.sh does not exist"
export GIT_CONFIG_NOSYSTEM=1

# ============================================================================
# D — brnc_nochange on real trees
# ============================================================================
G="$T/dgit"; mkdir -p "$G"
git -C "$G" init -q; git -C "$G" config user.email t@t; git -C "$G" config user.name t
printf 'base\n' > "$G/a.txt"; git -C "$G" add -A; git -C "$G" commit -qm base; git -C "$G" branch -M main
M1=$(git -C "$G" rev-parse HEAD)
git -C "$G" checkout -q -b pr; printf 'pr\n' > "$G/p.txt"; git -C "$G" add -A; git -C "$G" commit -qm "pr work"
L=$(git -C "$G" rev-parse HEAD)
git -C "$G" checkout -q main; printf 'main moved\n' > "$G/m.txt"; git -C "$G" add -A; git -C "$G" commit -qm "main moves"
M2=$(git -C "$G" rev-parse HEAD)
# the stacked shape: parent off main, child off parent, parent moves
git -C "$G" checkout -q -b parent "$M1"; printf 'parent\n' > "$G/q.txt"; git -C "$G" add -A; git -C "$G" commit -qm parent
git -C "$G" checkout -q -b child; printf 'child\n' > "$G/c.txt"; git -C "$G" add -A; git -C "$G" commit -qm child
C=$(git -C "$G" rev-parse HEAD)
git -C "$G" checkout -q parent; printf 'parent moved\n' > "$G/q2.txt"; git -C "$G" add -A; git -C "$G" commit -qm "parent moves"
P2=$(git -C "$G" rev-parse HEAD)
DSET() { # DSET <origin-main> [<origin-parent>] — the remote-tracking refs a round sees
  git -C "$G" update-ref refs/remotes/origin/main "$1"
  if [ -n "${2:-}" ]; then git -C "$G" update-ref refs/remotes/origin/parent "$2"; else git -C "$G" update-ref -d refs/remotes/origin/parent 2>/dev/null; fi
}
EMPTY() { git -C "$G" commit -q --allow-empty -m "fix round: a batch sibling's fault, no change"; }
NC() { # NC <lease> <mref> <conflicts> <reason> -> "rc:<rc> n:<count>"
  local out rc=0
  out=$(bash -c '. "$1"; shift; brnc_nochange "$@"' _ "$FRAG" "$G" "$@" 2>/dev/null) || rc=$?
  printf 'rc:%s n:%s' "$rc" "$out"
}
DSET "$M1"
git -C "$G" checkout -q -B round "$L"; EMPTY
[ "$(NC "$L" main "" queue-ejected-twice)" = "rc:0 n:1" ] && ok || bad "D1 one empty commit is no change: $(NC "$L" main "" queue-ejected-twice)"
git -C "$G" checkout -q -B round "$L"
[ "$(NC "$L" main "" queue-ejected-twice)" = "rc:0 n:0" ] && ok || bad "D2 no commit at all is no change: $(NC "$L" main "" queue-ejected-twice)"
git -C "$G" checkout -q -B round "$L"; EMPTY; EMPTY
[ "$(NC "$L" main "" red-ci-twice)" = "rc:0 n:2" ] && ok || bad "D3 two empty commits on red-ci-twice are no change: $(NC "$L" main "" red-ci-twice)"
DSET "$M2"
git -C "$G" checkout -q -B round "$L"; git -C "$G" merge -q --no-edit origin/main >/dev/null; EMPTY
[ "$(NC "$L" main "" queue-ejected-twice)" = "rc:0 n:1" ] && ok || bad "D4 a clean main merge + empty commit on queue-ejected-twice is no change: $(NC "$L" main "" queue-ejected-twice)"
case "$(NC "$L" main "" red-ci-twice)" in rc:1*) ok ;; *) bad "D5 the same tree on red-ci-twice is a change (the merge is pushed as today): $(NC "$L" main "" red-ci-twice)" ;; esac
DSET "$M1"
git -C "$G" checkout -q -B round "$L"; printf 'real fix\n' >> "$G/p.txt"; git -C "$G" commit -qam "real fix"
case "$(NC "$L" main "" queue-ejected-twice)" in rc:1*) ok ;; *) bad "D6 a real file edit is a change: $(NC "$L" main "" queue-ejected-twice)" ;; esac
git -C "$G" checkout -q -B round "$L"
case "$(NC "$L" main "a.txt" rebase-conflict)" in rc:1*) ok ;; *) bad "D7 a resolved conflict is a change, even with the tree equal to the lease" ;; esac
git -C "$G" checkout -q -B round "$L"; printf 'tmp\n' >> "$G/p.txt"; git -C "$G" commit -qam edit; git -C "$G" revert --no-edit HEAD >/dev/null
case "$(NC "$L" main "" queue-ejected-twice)" in rc:1*) ok ;; *) bad "D8 an edit and its revert touched a file: a change: $(NC "$L" main "" queue-ejected-twice)" ;; esac
DSET "$M1" "$P2"
git -C "$G" checkout -q -B round "$C"; git -C "$G" merge -q --no-edit origin/parent >/dev/null; EMPTY
[ "$(NC "$C" parent "" queue-ejected-twice)" = "rc:0 n:1" ] && ok || bad "D9 a stacked child's base merge + empty commit is no change: $(NC "$C" parent "" queue-ejected-twice)"
case "$(NC "$C" main "" queue-ejected-twice)" in rc:1*) ok ;; *) bad "D9 read against main, the parent's new commit counts as the round's own: a change" ;; esac
DSET "$M1"

# ============================================================================
# N — the REAL driver, --fix-here (the owning box's half of a hopped round)
# ============================================================================
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
[ -f "$FRAG" ] && { scratch_install_closure bin/blocked-resolver.d/bh-8592-fixround-nochange.sh "$H" >/dev/null || { echo "FAIL: closure of the fragment"; exit 1; }; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# The queue state is the suite's: $T/qstate (absent = unknown).
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
mc_queue_state() { printf '%s\n' "\$*" >> "$T/qstate.log"; cat "$T/qstate" 2>/dev/null || printf unknown; }
EOF
# Two branches cut from main's tip (the round's merge of main is a no-op), and
# TK-90 (main moved under it: the merge is clean and real).
S="$T/seed"
for b in ticket/TK-120 ticket/TK-121; do
  git -C "$S" checkout -q main; git -C "$S" checkout -q -B "$b"
  printf '%s\n' "$b" > "$S/g.txt"; git -C "$S" add -A; git -C "$S" commit -qm "work on $b"; git -C "$S" push -q -f origin "$b"
done
git -C "$T/repos/tproj" fetch -q origin
MSG="BH-9999 fix round: queue-ejected-twice is a batch sibling's fault, no change"
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
case "\$(cat "$T/agent-mode" 2>/dev/null)" in
  empty) git commit -q --allow-empty -m "$MSG" -m "The batch failed in tests/other-test.sh, which this PR does not touch." ;;
  edit)  printf 'fixed\n' >> g.txt; git add -A; git commit -q -m "fix round: the real fix" ;;
  *) : ;;
esac
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"
PR="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
CK=nc-1
FIXHERE() { # FIXHERE <reason> — one hopped round; stdout in $T/fh.out
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
      bash "$H/bin/blocked-resolver.sh" --fix-here tproj "$CK" "$1" "$PR" - - < "$T/rec-in.json" ) > "$T/fh.out" 2>>"$T/run.log"
  sed -n 's/^FIX_RECORD //p' "$T/fh.out" | base64 -d > "$T/rec-out.json" 2>/dev/null
}
RESULT() { sed -n 's/^FIX_RESULT //p' "$T/fh.out" | head -1; }
OUTJ() { jq -r "$1" "$T/rec-out.json" 2>/dev/null; }
NRESET() { # NRESET <branch> <agent-mode> [qstate]
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"; : > "$T/qstate.log"
  rm -f "$T/qstate" "$T/fh.out" "$T/rec-out.json"
  [ -n "${3:-}" ] && printf '%s' "$3" > "$T/qstate"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf 'main\n' > "$T/prbase"
  printf '%s' "$2" > "$T/agent-mode"
  printf 'Head-bound harness re-review: the merge queue ejected this PR twice.\n' > "$T/prcomments"
  jq -nc --arg k "$CK" '{project:"tproj",rkey:$k,fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
BRFIX() { git -C "$T/repos/tproj" rev-parse --verify -q "brfix/$CK" >/dev/null 2>&1; }

# N1 — the incident: an empty "sibling's fault" commit on queue-ejected-twice
NRESET ticket/TK-120 empty ejected
B0=$(osha ticket/TK-120)
FIXHERE queue-ejected-twice
[ -s "$T/agent.txt" ] && ok || bad "N1 the round never reached the agent (log: $(tail -4 "$LOGF"))"
[ "$(osha ticket/TK-120)" = "$B0" ] && ok || bad "N1 the empty commit must NOT be pushed: origin moved ${B0:0:8} -> $(osha ticket/TK-120 | cut -c1-8)"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-nochange ] && ok || bad "N1 the round is recorded fix-round-nochange: $(OUTJ '.attempts[-1]')"
[ "$(OUTJ '.fixrounds')" = 1 ] && ok || bad "N1 the round was spent: fixrounds 1 (got $(OUTJ '.fixrounds'))"
[ "$(OUTJ '.nochange_heads[-1]')" = "$B0" ] && ok || bad "N1 the head is in nochange_heads: $(OUTJ '.nochange_heads')"
[ "$(RESULT)" = done ] && ok || bad "N1 FIX_RESULT is done, not a terminal (got '$(RESULT)')"
[ "$(grep -c . "$T/comments.txt")" = 1 ] && ok || bad "N1 one PR comment: $(cat "$T/comments.txt")"
grep -qF "$MSG" "$T/comment-bodies.txt" && grep -qF 'tests/other-test.sh, which this PR does not touch' "$T/comment-bodies.txt" \
  && ok || bad "N1 the comment carries the round's commit message: $(cat "$T/comment-bodies.txt")"
grep -qF 'changed no file, so nothing was pushed' "$T/comment-bodies.txt" && ok || bad "N1 the comment says nothing was pushed"
BRFIX && bad "N1 brfix/$CK must be dropped (an empty commit never seeds a later round)" || ok
grep -q 'EVENT resolver_fix_nochange' "$LOGF" && ok || bad "N1 one resolver_fix_nochange event: $(grep EVENT "$LOGF")"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "N1 nothing pages: $(cat "$T/lane-alert.txt")"

# N8 — the same head again (a second round, cap 2): still one comment
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/comments.txt"
( export BR_MAX_FIXROUNDS=2; FIXHERE queue-ejected-twice )
[ "$(osha ticket/TK-120)" = "$B0" ] && ok || bad "N8 the second round pushes nothing either"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-nochange ] && ok || bad "N8 the second round is fix-round-nochange too (log: $(tail -3 "$LOGF"))"
[ ! -s "$T/comments.txt" ] && ok || bad "N8 the head was already noted: no second comment: $(cat "$T/comments.txt")"

# N3 — the agent commits nothing at all
NRESET ticket/TK-120 none ejected
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-120)" = "$B0" ] && ok || bad "N3 nothing pushed"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-nochange ] && ok || bad "N3 a round with no commit is fix-round-nochange: $(OUTJ '.attempts[-1]')"
[ "$(RESULT)" = done ] && ok || bad "N3 no terminal (got '$(RESULT)')"
grep -qF 'The round committed no message.' "$T/comment-bodies.txt" && ok || bad "N3 the comment says the round committed no message: $(cat "$T/comment-bodies.txt")"

# N10 — main moved under the PR: the round's clean main merge + an empty commit
NRESET ticket/TK-90 empty ejected
B90=$(osha ticket/TK-90)
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-90)" = "$B90" ] && ok || bad "N10 a clean main merge + empty commit is not pushed on queue-ejected-twice (73aadc64's shape)"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-nochange ] && ok || bad "N10 recorded fix-round-nochange: $(OUTJ '.attempts[-1]')"

# N6 — another park, a pure empty commit: not pushed, the no-verified-commit exit
NRESET ticket/TK-121 empty ejected
B121=$(osha ticket/TK-121)
FIXHERE red-ci-twice
[ "$(osha ticket/TK-121)" = "$B121" ] && ok || bad "N6 an empty commit on red-ci-twice is not pushed"
[ "$(OUTJ '.attempts[-1].action')" = fix-round ] && OUTJ '.attempts[-1].detail' | grep -qF 'tree unchanged (1 empty commit(s)), not pushed' \
  && ok || bad "N6 the no-verified-commit attempt names the empty commit: $(OUTJ '.attempts[-1]')"
[ "$(RESULT)" = terminal ] && ok || bad "N6 the round ends in the ladder's terminal, as a round that committed nothing does (got '$(RESULT)')"
[ "$(OUTJ '(.nochange_heads // []) | length')" = 0 ] && ok || bad "N6 no requeue is pending for a non-queue park"
grep -qF "$MSG" "$T/comment-bodies.txt" && ok || bad "N6 the finding is still posted on the PR"

# N7 / Q2 — a real fix, the PR not in the queue: pushed
NRESET ticket/TK-121 edit ejected
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-121)" != "$B121" ] && ok || bad "N7 a real fix is pushed (log: $(tail -4 "$LOGF"))"
[ "$(OUTJ '.attempts[-1].action')" = fix-round ] && OUTJ '.attempts[-1].detail' | grep -q '^pushed ' && ok || bad "N7 recorded as pushed: $(OUTJ '.attempts[-1]')"
grep -qF "$PR" "$T/qstate.log" && ok || bad "Q2 the queue state is read before the push"

# N5 / Q1 — a real fix while Mergify holds the PR: NOT pushed
NRESET ticket/TK-120 edit queued
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-120)" = "$B0" ] && ok || bad "Q1 nothing is pushed while Mergify holds the PR"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-queued ] && ok || bad "Q1 recorded fix-round-queued: $(OUTJ '.attempts[-1]')"
[ "$(OUTJ '.fixrounds')" = 1 ] && ok || bad "Q1 the refused round still counts (fixrounds 1, got $(OUTJ '.fixrounds'))"
BRFIX && ok || bad "Q1 brfix/$CK is kept for a later round"
[ "$(RESULT)" = done ] && ok || bad "Q1 no terminal (got '$(RESULT)')"
grep -q 'EVENT resolver_fix_queued' "$LOGF" && ok || bad "Q1 one resolver_fix_queued event"

# Q3 — merged: pushed (the conductor settles it); Q4 — unknown: pushed, one line
NRESET ticket/TK-120 edit merged
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-120)" != "$B0" ] && ok || bad "Q3 a merged queue state does not block the push"
git -C "$S" push -q -f origin "$B0:refs/heads/ticket/TK-120"; git -C "$T/repos/tproj" fetch -q origin
NRESET ticket/TK-120 edit
FIXHERE queue-ejected-twice
[ "$(osha ticket/TK-120)" != "$B0" ] && ok || bad "Q4 an unknown queue state pushes as before"
grep -q 'queue state of the PR is unknown' "$LOGF" && ok || bad "Q4 one line says the queue state was unknown"
git -C "$S" push -q -f origin "$B0:refs/heads/ticket/TK-120"; git -C "$T/repos/tproj" fetch -q origin

# ============================================================================
# S / R / K / N9 / NH / E / A — the hub half, every vendor verb a stub
# ============================================================================
HB="$T/hub"; mkdir -p "$HB/fakebin" "$HB/rec" "$HB/repos/tproj"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls"\nexit 1\n' "$HB" > "$HB/fakebin/gh"; chmod +x "$HB/fakebin/gh"
: > "$HB/gh-calls"
KEY="o/tproj#91"
HEADH=1234567890abcdef1234567890abcdef12345678
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$2"; }
lift br_has_field_value "$DIR/bin/lib/br/record.sh" > "$HB/real.sh"
cat > "$HB/stubs.sh" <<EOF
H="$HB"; ST="$HB/st"; REPOS="$HB/repos"; LOG="$HB/br.log"; OBSERVE=\${OBSERVE:-0}
STAMP() { printf '2026-10-27T00:00:00Z'; }
say() { printf '%s\n' "\$*" >> "$HB/say.log"; }
br_load() { cat "$HB/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_save() { printf '%s\n' "\$3" > "$HB/rec/\$2.json"; }
br_push_field() { [ -f "$HB/rec-ro" ] && return 1; local c; c=\$(br_load "\$1" "\$2" | jq -c --arg k "\$3" --arg v "\$4" '.[\$k] = (((.[\$k] // []) + [\$v]) | unique)') && printf '%s\n' "\$c" > "$HB/rec/\$2.json"; }
br_record() { printf '%s\n' "\$*" >> "$HB/record.log"; local c; c=\$(br_load "\$1" "\$2" | jq -c --arg a "\$3" '.attempts = ((.attempts // []) + [{action:\$a}]) | .fixrounds = ((.fixrounds // 0) + 1)') && printf '%s\n' "\$c" > "$HB/rec/\$2.json"; }
br_event() { printf '%s\n' "\$*" >> "$HB/events.log"; }
br_pr_comment() { printf '%s\n' "\$2" >> "$HB/comment.log"; }
br_wt_drop() { :; }; mc_git_auth_clear() { :; }
br_rung_hold_gate() { [ ! -f "$HB/held" ]; }
br_reset_token() { :; }
mc_slug_of_url() { printf 'o/tproj'; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
mc_queue_provider() { cat "$HB/provider" 2>/dev/null || printf mergify; }
mc_pr_live_head() { [ -f "$HB/live-fail" ] && return 1; cat "$HB/live"; }
mc_attempt_has() { grep -qxF "\$1" "$HB/attempts.txt" 2>/dev/null; }
mc_requeued_record() { printf 'requeued %s %s\n' "\$1" "\$2" >> "$HB/attempts.txt"; }
mc_attempt_clear() { grep -vxF "\$1 \$2 \$3" "$HB/attempts.txt" > "$HB/attempts.tmp"; mv "$HB/attempts.tmp" "$HB/attempts.txt"; }
mc_row_field() { [ "\$2" = 5 ] && cat "$HB/reviewed"; }
mc_queue_state() { cat "$HB/qstate" 2>/dev/null || printf unknown; }
mc_requeue_mergify() {
  # The marks must be written BEFORE the post (BH-636).
  local m=nomarks
  grep -qxF "requeued \$(mc_slug_of_url)#91 \$3" "$HB/attempts.txt" && ! grep -qxF "reejected \$(mc_slug_of_url)#91 \$3" "$HB/attempts.txt" && m=marks-first
  printf '%s %s\n' "\$*" "\$m" >> "$HB/requeue.log"
  local rc; rc=\$(cat "$HB/requeue-rc" 2>/dev/null || echo 0); [ "\$rc" = 1 ] && printf 'the dequeued label could not be removed (stub)'
  return "\$rc"
}
mc_transition() { printf '%s\n' "\$*" >> "$HB/transition.log"; }
EOF
SRESET() { # SRESET [ck] — one pending no-change head, every gate open
  local ck="${1:-$CK}"
  rm -f "$HB"/rec/*.json "$HB/rec-ro" "$HB/held" "$HB/live-fail" "$HB/provider" "$HB/requeue-rc" "$HB/qstate"
  : > "$HB/say.log"; : > "$HB/requeue.log"; : > "$HB/transition.log"; : > "$HB/events.log"; : > "$HB/comment.log"; : > "$HB/record.log"
  jq -nc --arg h "$HEADH" '{project:"tproj",fixrounds:1,attempts:[{action:"fix-round-nochange"}],nochange_heads:[$h]}' > "$HB/rec/$ck.json"
  printf '%s' "$HEADH" > "$HB/live"; printf '%s' "$HEADH" > "$HB/reviewed"; printf ejected > "$HB/qstate"
  printf 'ejected %s %s\nreejected %s %s\n' "$KEY" "$HEADH" "$KEY" "$HEADH" > "$HB/attempts.txt"
}
HUB() { # HUB <fn> <args...> — the fragment over the stubs, in a clean shell
  ( unset BR_NOCHANGE_REQUEUE BR_NOCHANGE_NOTE_BYTES BR_FIX_HERE LANE_RUN_ID
    [ -n "${HUBENV:-}" ] && export "${HUBENV?}"
    PATH="$HB/fakebin:$PATH" bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$HB/stubs.sh" "$HB/real.sh" "$FRAG" "$@" )
}
REC() { jq -r "$1" "$HB/rec/${2:-$CK}.json" 2>/dev/null; }
SETTLE() { HUB brnc_settle tproj "$CK" "$CK" queue-ejected-twice "$PR" o/tproj; }

# S1 — every gate open: ONE requeue, marks first, row QUEUED, head unchanged
SRESET; A=$(SETTLE)
[ "$A" = requeued ] && ok || bad "S1 answer 'requeued' (got '$A'; say: $(cat "$HB/say.log"))"
[ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "S1 exactly one requeue: $(cat "$HB/requeue.log")"
grep -q "o/tproj $PR $HEADH marks-first" "$HB/requeue.log" && ok || bad "S1 requeued on the SAME head, after the marks: $(cat "$HB/requeue.log")"
grep -q "^$KEY QUEUED requeued on ${HEADH:0:8} by the blocked-resolver" "$HB/transition.log" && ok || bad "S1 the row goes QUEUED: $(cat "$HB/transition.log")"
grep -qxF "requeued $KEY $HEADH" "$HB/attempts.txt" && ok || bad "S1 MC_ATTEMPTS has the requeued mark"
grep -qxF "reejected $KEY $HEADH" "$HB/attempts.txt" && bad "S1 this head's reejected mark is cleared once" || ok
[ "$(REC '.nochange_requeued_heads[0]')" = "$HEADH" ] && ok || bad "S1 nochange_requeued_heads has the head"
grep -q "requeued $KEY on ${HEADH:0:8} — Mergify acknowledged it" "$HB/say.log" && ok || bad "S1 the status line says requeued after rc 0: $(cat "$HB/say.log")"
# S9 — the same head again: no second requeue
A=$(SETTLE)
[ "$A" = queued ] && [ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "S9 a second settle on the head posts nothing (got '$A', $(grep -c . "$HB/requeue.log") requeues)"

# S2 — Mergify already holds it: 0 requeues, row QUEUED
SRESET; printf queued > "$HB/qstate"; A=$(SETTLE)
[ "$A" = queued ] && [ ! -s "$HB/requeue.log" ] && ok || bad "S2 already queued: 0 requeues (got '$A': $(cat "$HB/requeue.log"))"
grep -q "^$KEY QUEUED already in the Mergify queue on ${HEADH:0:8}" "$HB/transition.log" && ok || bad "S2 the row says already queued: $(cat "$HB/transition.log")"

# S3-S7 and the merged arm — declined, the head in nochange_declined_heads, 0 requeues
DECL() { # DECL <id> <want-why>
  [ "$A" = "declined $2" ] && [ ! -s "$HB/requeue.log" ] && [ ! -s "$HB/transition.log" ] \
    && [ "$(REC '.nochange_declined_heads[0]')" = "$HEADH" ] && ok \
    || bad "$1 declined $2 with 0 requeues (got '$A'; requeue: $(cat "$HB/requeue.log"); declined: $(REC '.nochange_declined_heads'))"
}
SRESET; printf 'fedcba9876543210fedcba9876543210fedcba98' > "$HB/live"; A=$(SETTLE); DECL S3 head-moved
SRESET; printf 'dqwculprit %s %s\n' "$KEY" "$HEADH" >> "$HB/attempts.txt"; A=$(SETTLE); DECL S4 culprit
SRESET; printf 'fedcba9876543210fedcba9876543210fedcba98' > "$HB/reviewed"; A=$(SETTLE); DECL S5 not-approved-at-head
SRESET; printf none > "$HB/provider"; A=$(SETTLE); DECL S6 not-mergify
SRESET; A=$(HUBENV=BR_NOCHANGE_REQUEUE=0 SETTLE); DECL S7 knob-off
SRESET; printf merged > "$HB/qstate"; A=$(SETTLE); DECL S10 merged
# S8 — unreadable reads write nothing and are asked again
SRESET; touch "$HB/live-fail"; A=$(SETTLE)
[ "$A" = "unread live-head" ] && [ ! -s "$HB/requeue.log" ] && [ "$(REC '.nochange_declined_heads // [] | length')" = 0 ] \
  && [ "$(REC '.nochange_requeued_heads // [] | length')" = 0 ] && ok || bad "S8 an unreadable live head writes nothing (got '$A')"
HUB brnc_pending "$(cat "$HB/rec/$CK.json")" && ok || bad "S8 the head stays pending for the next tick"
SRESET; rm -f "$HB/qstate"; A=$(SETTLE)
[ "$A" = "unread queue-state" ] && [ ! -s "$HB/requeue.log" ] && ok || bad "S8 an unknown queue state is retried, not requeued (got '$A')"
SRESET; touch "$HB/rec-ro"; A=$(SETTLE)
[ "$A" = "unread record-write" ] && [ ! -s "$HB/requeue.log" ] && ok || bad "S8 a mark that will not write posts no requeue (got '$A')"
# S11 — observe mode: one WOULD line, nothing written
SRESET; A=$(OBSERVE=1 SETTLE)
[ "$A" = observe ] && [ ! -s "$HB/requeue.log" ] && grep -q 'WOULD requeue' "$HB/say.log" && grep -qxF "reejected $KEY $HEADH" "$HB/attempts.txt" \
  && ok || bad "S11 observe mode writes nothing (got '$A')"
# R1 — Mergify refuses: no "requeued" claim, the mark kept, declined
SRESET; echo 1 > "$HB/requeue-rc"; A=$(SETTLE)
[ "$A" = "declined requeue-refused" ] && ok || bad "R1 a refused requeue is declined (got '$A')"
grep -q "requeued $KEY" "$HB/say.log" && bad "R1 the log must not say requeued after a refusal: $(cat "$HB/say.log")" || ok
[ ! -s "$HB/transition.log" ] && ok || bad "R1 no row write on a refusal"
[ "$(REC '.nochange_requeued_heads[0]')" = "$HEADH" ] && ok || bad "R1 the mark stays: no second post on this head"
# R3 — posted, no witness yet: WAIT_CI and the line says so
SRESET; echo 3 > "$HB/requeue-rc"; A=$(SETTLE)
[ "$A" = "requeued awaiting" ] && ok || bad "R3 answer 'requeued awaiting' (got '$A')"
grep -q "^$KEY WAIT_CI requeued on ${HEADH:0:8}, awaiting Mergify's witness" "$HB/transition.log" && ok || bad "R3 the row is WAIT_CI: $(cat "$HB/transition.log")"
grep -q "awaiting Mergify's witness" "$HB/say.log" && ok || bad "R3 the line says awaiting Mergify's witness"

# P — brnc_settle_pending: hub only, held tickets wait, nothing pending is a no-op
SRESET; A=$(HUBENV=BR_FIX_HERE=1 HUB brnc_settle_pending tproj "$CK" "$CK" queue-ejected-twice "$PR" - -); RC=$?
[ "$RC" = 1 ] && [ ! -s "$HB/requeue.log" ] && ok || bad "P1 a box (--fix-here) never requeues (rc $RC)"
SRESET; A=$(HUBENV=LANE_RUN_ID=fixture-run-1 HUB brnc_settle_pending tproj "$CK" "$CK" queue-ejected-twice "$PR" - -); RC=$?
[ "$RC" = 1 ] && [ ! -s "$HB/requeue.log" ] && ok || bad "P1 a lane machine never requeues (rc $RC)"
SRESET; touch "$HB/held"; A=$(HUB brnc_settle_pending tproj "$CK" "$CK" queue-ejected-twice "$PR" - -); RC=$?
[ "$RC" = 0 ] && [ ! -s "$HB/requeue.log" ] && ok || bad "P2 a held ticket is not requeued, and takes no rung (rc $RC)"
SRESET; jq -c '.nochange_requeued_heads = [.nochange_heads[0]]' "$HB/rec/$CK.json" > "$HB/x" && mv "$HB/x" "$HB/rec/$CK.json"
A=$(HUB brnc_settle_pending tproj "$CK" "$CK" queue-ejected-twice "$PR" - -); RC=$?
[ "$RC" = 1 ] && [ ! -s "$HB/requeue.log" ] && ok || bad "P3 nothing pending: rc 1, no requeue (rc $RC)"

# K1 — the prod defaults with no env: requeue on (S1 ran with none), 3000 bytes
[ "$(HUB brnc_note_bytes)" = 3000 ] && ok || bad "K1 BR_NOCHANGE_NOTE_BYTES defaults to 3000"
[ "$(HUBENV=BR_NOCHANGE_NOTE_BYTES=500 HUB brnc_note_bytes)" = 500 ] && ok || bad "K1 a valid knob value is read"
[ "$(HUBENV=BR_NOCHANGE_NOTE_BYTES=abc HUB brnc_note_bytes)" = 3000 ] && [ "$(HUBENV=BR_NOCHANGE_NOTE_BYTES=100 HUB brnc_note_bytes)" = 3000 ] \
  && ok || bad "K1 a value that is not a number in 200..20000 reads as 3000"
git -C "$G" checkout -q -B round "$L"
git -C "$G" commit -q --allow-empty -m "$(head -c 5000 /dev/zero | tr '\0' x)"
NB=$(HUB brnc_note_body "$G" "$L" main | wc -c)
[ "$NB" -eq 3000 ] && ok || bad "K1 a 5000-byte commit body is cut to 3000 bytes (got $NB)"
# K2 — the settings rows
for kv in BR_NOCHANGE_REQUEUE:1 BR_NOCHANGE_NOTE_BYTES:3000; do
  k=${kv%%:*}; v=${kv##*:}; f="$DIR/catalog/lanes.d/blocked-resolver.knobs.d/$k.json"
  [ "$(jq -r '.default' "$f" 2>/dev/null)" = "$v" ] && [ "$(jq -r '.env' "$f" 2>/dev/null)" = "$k" ] && ok || bad "K2 $f parses with env $k, default $v"
done

# NH — brnc_round on the hub (no hop): the round is recorded, 0 pushes, 1 requeue
SRESET; rm -f "$HB/rec/$CK.json"
git -C "$G" checkout -q -B round "$L"; EMPTY
HUB brnc_round tproj "$CK" "$CK" queue-ejected-twice "$PR" o/tproj "$G" "$L" main "$HEADH" 1 - - >/dev/null
grep -q "fix-round-nochange queue-ejected-twice" "$HB/record.log" && ok || bad "NH the round is recorded fix-round-nochange: $(cat "$HB/record.log")"
[ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "NH one requeue on the hub: $(cat "$HB/requeue.log")"
[ "$(grep -c . "$HB/comment.log")" -ge 1 ] && ok || bad "NH the finding is posted"
grep -q resolver_fix_nochange "$HB/events.log" && ok || bad "NH one resolver_fix_nochange event"

# N9 — the box record round trip through the REAL br_fix_adopt
NRESET ticket/TK-120 empty ejected
FIXHERE queue-ejected-twice
lift br_fix_adopt "$DRIVER" > "$HB/adopt.sh"
[ -s "$HB/adopt.sh" ] && ok || bad "N9 br_fix_adopt could not be lifted"
cat >> "$HB/adopt.sh" <<'EOF'
fix_round_adopt() { return 0; }
br_fix_terminal() { printf 'terminal\n' >> "$HB/terminal.log"; }
br_fix_terminal_word() { printf terminal; }
EOF
SRESET; rm -f "$HB/rec/$CK.json"; : > "$HB/terminal.log"
printf '%s' "$B0" > "$HB/live"; printf '%s' "$B0" > "$HB/reviewed"
printf 'ejected %s %s\nreejected %s %s\n' "$KEY" "$B0" "$KEY" "$B0" > "$HB/attempts.txt"
ROW=$(jq -nc --arg ro "$(cat "$T/rec-out.json")" '{id:7, claimed_by:"box-tproj", result:"done", record_out:$ro}')
ADOPT() { HB="$HB" HUB bash -c '. "$1"; . "$2"; . "$3"; . "$4"; br_fix_adopt tproj "$5" queue-ejected-twice "$6" - - "$5" "$7"' _ \
            "$HB/stubs.sh" "$HB/real.sh" "$FRAG" "$HB/adopt.sh" "$CK" "$PR" "$ROW"; }
export HB
ADOPT >/dev/null 2>&1
[ "$(REC '.attempts[-1].action')" = fix-round-nochange ] && ok || bad "N9 the hub adopted the box's record: $(REC '.attempts[-1]')"
[ "$(grep -c . "$HB/requeue.log")" = 1 ] && grep -q " $B0 marks-first" "$HB/requeue.log" && ok || bad "N9 the adopt requeues the same head once: $(cat "$HB/requeue.log"); say: $(tail -3 "$HB/say.log")"
[ ! -s "$HB/terminal.log" ] && ok || bad "N9 no terminal on a no-change round"
ADOPT >/dev/null 2>&1
[ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "N9 a second adopt requeues nothing: $(cat "$HB/requeue.log")"

# E — the br_one call site, verbatim: a pending head is settled before the ladder rung.
# The driver is at its line ceiling (tests/br/driver-ceiling.tsv), so the site is
# ONE line that shares the needs-human `esac`; the `esac;` prefix is cut and the
# rest of that line runs as the driver has it.
{ printf 'br_one_part() {\n  local p=tproj rkey="%s" ck="%s" reason="$1" url="%s" rec=- tkey=-\n' "$CK" "$CK" "$PR"
  lift br_one "$DRIVER" | grep -F 'brnc_one_gate "' | sed 's/^[[:space:]]*esac;//'
  printf '  return 99\n}\n'; } > "$HB/brone.sh"
[ "$(lift br_one "$DRIVER" | grep -cF 'brnc_one_gate "')" = 1 ] && grep -q 'brnc_one_gate .*br_reset_token; return 3' "$HB/brone.sh" && bash -n "$HB/brone.sh" \
  && ok || bad "E0 br_one has exactly one brnc_one_gate call site that resets the token and returns 3"
ONE() { HUB bash -c '. "$1"; . "$2"; . "$3"; . "$4"; br_one_part "$5"' _ "$HB/stubs.sh" "$HB/real.sh" "$FRAG" "$HB/brone.sh" "$1" >/dev/null 2>&1; }
SRESET; ONE queue-ejected-twice; RC=$?
[ "$RC" = 3 ] && [ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "E1 a pending head is requeued and the rung is skipped (rc $RC, $(grep -c . "$HB/requeue.log") requeues)"
SRESET; printf none > "$HB/provider"; ONE queue-ejected-twice; RC=$?
[ "$RC" = 99 ] && ok || bad "E2 a declined head falls through to the ladder rung (rc $RC)"
SRESET; ONE red-ci-twice; RC=$?
[ "$RC" = 99 ] && [ ! -s "$HB/requeue.log" ] && ok || bad "E3 another reason is not touched (rc $RC)"

# A1 — first tick: three parked records, one pending — 1 requeue, 0 alerts
SRESET a1
jq -nc '{project:"tproj",fixrounds:1,attempts:[{action:"fix-round"}]}' > "$HB/rec/a2.json"
jq -nc '{project:"tproj",fixrounds:0,attempts:[]}' > "$HB/rec/a3.json"
for ck in a1 a2 a3; do HUB brnc_settle_pending tproj "$ck" "$ck" queue-ejected-twice "$PR" - - >/dev/null 2>&1; done
[ "$(grep -c . "$HB/requeue.log")" = 1 ] && ok || bad "A1 one requeue over three parked records: $(cat "$HB/requeue.log")"
grep -q 'lane-alert\|ALERT' "$HB/say.log" && bad "A1 nothing alerts" || ok

# B1 — the hub half never reached a gh binary
[ ! -s "$HB/gh-calls" ] && ok || bad "B1 the hub half made gh calls: $(cat "$HB/gh-calls")"

echo "fixround-nochange.bh-8592: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
