#!/bin/bash
# tests/plan-sibling-sequence.bh-4988-test.sh — BH-4988 r2 (BH-4975.3, the operator
# 2026-10-07): a rollout/decompose child whose plan shares an ordinary file with
# a SIBLING that already finished building but whose PR is still open is held
# (`OVERLAP_DEFER ... vs <SIB>`, then the existing After: hold) instead of
# building into a merge conflict; disjoint siblings still build in parallel;
# each sequencing decision is posted ONCE on the child issue; and both
# decomposer prompts tell the .0 contract to pre-create the shared seams.
#
# The REAL bin/plan-sibling.sh runs in a scratch harness $H against a stub
# bin/lib/gh-rest-list.sh that serves REST-shaped fixtures from $H/fx (issues,
# pulls, per-PR files) and records comment posts. A `gh` on PATH fails the
# suite if anything calls it. G-cases run the real `# >>> plan overlap` block of
# bin/lib/rb/gates.sh with stub helpers; C-cases run the real
# bin/run-decompose.sh with a stub agent-call.sh that saves the prompt it is
# handed.
#
# No network, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/fx" "$T/stub"
cat > "$H/fleet.conf" <<'CONF'
cromford  example-org/cromford  -  -     0 local -
inapp          example-org/inapp          -  /api  0 local -
CONF
export FLEET_CONF="$H/fleet.conf"

# The REST stub, written BEFORE the closure install (which never clobbers).
# Every read is traced to fx/trace; fx/rc.<what> makes it fail with that rc.
cat > "$H/bin/lib/gh-rest-list.sh" <<'SH'
_fx() { printf '%s\n' "$*" >> "$HARNESS/fx/trace"; }
_fxrc() { cat "$HARNESS/fx/rc.$1" 2>/dev/null || echo 0; }
gh_rest_issue_list() {
  local rc; _fx "issues $*"; rc=$(_fxrc issues); [ "$rc" = 0 ] || return "$rc"
  [ "$1" = example-org/cromford ] || return 75
  cat "$HARNESS/fx/issues.json"
}
gh_rest_pr_list_all() {
  local rc; _fx "pulls $*"; rc=$(_fxrc pulls); [ "$rc" = 0 ] || return "$rc"
  cat "$HARNESS/fx/pulls.json"
}
gh_rest() {
  local n rc; _fx "rest $*"
  case "$2" in repos/example-org/cromford/pulls/*/files) ;; *) return 75 ;; esac
  n=${2#repos/example-org/cromford/pulls/}; n=${n%/files}
  rc=$(_fxrc "files.$n"); [ "$rc" = 0 ] || return "$rc"
  cat "$HARNESS/fx/files.$n.json"
}
gh_rest_comment() {
  local rc; rc=$(_fxrc comment); [ "$rc" = 0 ] || return "$rc"
  printf '%s %s\n' "$1" "$2" >> "$HARNESS/fx/posted"
  cp "$3" "$HARNESS/fx/body.$(wc -l < "$HARNESS/fx/posted" | tr -d ' ')"
}
SH
cat > "$T/stub/gh" <<SH
#!/bin/bash
echo "\$*" >> "$T/gh-called"
exit 99
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

[ -x "$DIR/bin/plan-sibling.sh" ] && ok || bad "bin/plan-sibling.sh must exist and be executable (gates.sh runs it behind -x)"
scratch_install_closure bin/plan-sibling.sh "$H" >/dev/null || bad "closure install: bin/plan-sibling.sh"
[ -e "$H/bin/fleet-conf.sh" ] || cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"

# The fixture target repo: the Generated-files table gen_table_paths reads.
R="$T/repo"
mkdir -p "$R/docs/verification-map/index"
cat > "$R/docs/verification-map/index/tail.md" <<'MD'
## Generated files

| Path | Regenerate with |
|---|---|
| `catalog/lanes.json` | `bin/lanes-build.sh` |
MD
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.email=t@t -c user.name=t commit -qm fixture || bad "fixture repo commit"

# Bodies the way bin/lib/file-children.sh's fc_child_footer writes them (D4).
body() { printf 'Scope for this slice.\n\n---\nPart of #%s\nOrder: %s of 3\n' "$1" "$2"; }
B="$T/b"
mkb() { # mkb <body> <planned file>...
  local bd="$1"; shift
  scratch_rm "$B"; mkdir -p "$B"
  printf '# plan\n' > "$B/plan.md"
  printf '%s\n' "$@" > "$B/planned-files.txt"
  jq -n --arg b "$bd" '{key:"BH-5001",body:$b}' > "$B/ticket-meta.json"
}
issues() { # issues <num>:<parent>... — open issues (REST shape, one is a PR to be filtered upstream)
  local a out='[]' n p
  for a in "$@"; do
    n=${a%%:*}; p=${a#*:}
    out=$(jq -c --argjson n "$n" --arg b "$(body "$p" 2)" '. + [{number:$n,title:"slice",body:$b,state:"open"}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$H/fx/issues.json"
}
pull() { # pull <pr> <head ref> <file>... — one open PR and its changed files
  local n="$1" ref="$2"; shift 2
  jq -c --argjson n "$n" --arg r "$ref" '. + [{number:$n,state:"open",head:{ref:$r}}]' "$H/fx/pulls.json" > "$H/fx/p.tmp" \
    && mv "$H/fx/p.tmp" "$H/fx/pulls.json"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename:.,status:"modified"})' > "$H/fx/files.$n.json"
}
reset() {
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"
  mkdir -p "$H/fx" "$H/logs"; printf '[]\n' > "$H/fx/pulls.json"; printf '[]\n' > "$H/fx/issues.json"
  rm -f "$H/flags/plan-overlap-off"
}
chk() { # chk [VAR=val...] — plan-sibling check for $B; sets RC OUT ERR
  OUT=$(env HARNESS="$H" PLAN_OVERLAP_REPO="$R" "$@" bash "$H/bin/plan-sibling.sh" check cromford "$B" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
hlog() { cat "$H/logs/plan-hotspot.log" 2>/dev/null; }
LINE='OVERLAP_DEFER BH-5001 vs BH-5000 files=[bin/lib/triage-state.sh,bin/lib/triage-state.sh]'

# ---------- S1. finished sibling with an open PR on an ordinary file -> defer
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh bin/mine.sh
issues 5000:4975 5001:4975 5002:4975
pull 900 ticket/bh-5000 bin/lib/triage-state.sh bin/theirs.sh
chk
[ "$RC" = 1 ] && ok || bad "S1: a shared ordinary file with an open sibling PR must defer, rc=$RC out=$OUT err=$ERR"
[ "$OUT" = "$LINE" ] && ok || bad "S1: stdout must be exactly the OVERLAP_DEFER line: '$OUT'"
hlog | grep -q 'PLAN_SIBLING BH-5001 choice=after after=BH-5000 pr=#900 files=\[bin/lib/triage-state.sh,bin/lib/triage-state.sh\]' && ok \
  || bad "S1: logs/plan-hotspot.log lacks the after line: $(hlog)"
case "$ERR" in *"PLAN_SIBLING BH-5001 choice=after after=BH-5000 pr=#900"*) ok ;; *) bad "S1: stderr (pipeline.log) lacks the after line: $ERR" ;; esac

# S1b. a rebuild branch of the sibling
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 901 ticket/bh-5000-r2 bin/lib/triage-state.sh
chk
[ "$RC" = 1 ] && [ "$OUT" = "$LINE" ] && ok || bad "S1b: a -r2 sibling branch must defer too, rc=$RC out=$OUT"
# S1c. an agent/ branch
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 902 agent/BH-5000 bin/lib/triage-state.sh
chk
[ "$RC" = 1 ] && [ "$OUT" = "$LINE" ] && ok || bad "S1c: an agent/BH-5000 branch must defer too, rc=$RC out=$OUT"
# S1d. a dir in our plan containing their file
reset; mkb "$(body 4975 3)" bin/lib/rb
issues 5000:4975; pull 903 ticket/bh-5000 bin/lib/rb/gates.sh
chk
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-5000 files=[bin/lib/rb,bin/lib/rb/gates.sh]" ] && ok \
  || bad "S1d: dir-prefix collision must defer, rc=$RC out=$OUT"

# ---------- S2b. disjoint sibling -> build in parallel ------------------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 900 ticket/bh-5000 bin/other.sh
chk
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S2b: disjoint sibling must build, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_SIBLING BH-5001 choice=build siblings=1 prs=1 disjoint' && ok || bad "S2b: log lacks the disjoint line: $(hlog)"

# ---------- S3. fragment-only collisions are not held ------------------------
reset; mkb "$(body 4975 3)" catalog/lanes.json catalog/lanes.d
issues 5000:4975; pull 900 ticket/bh-5000 catalog/lanes.json catalog/lanes.d/x.json
chk
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S3: generated file + bare fragment dir must not defer, rc=$RC out=$OUT"
# S3a. two different files in the same fragment dir
reset; mkb "$(body 4975 3)" catalog/lanes.d/_lib.mine.json
issues 5000:4975; pull 900 ticket/bh-5000 catalog/lanes.d/_lib.theirs.json
chk
[ "$RC" = 0 ] && ok || bad "S3a: different fragment files must not defer, rc=$RC out=$OUT"
# S3b. the SAME fragment file on both sides is a real conflict
reset; mkb "$(body 4975 3)" catalog/lanes.d/x.json
issues 5000:4975; pull 900 ticket/bh-5000 catalog/lanes.d/x.json
chk
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-5000 files=[catalog/lanes.d/x.json,catalog/lanes.d/x.json]" ] && ok \
  || bad "S3b: the same fragment file on both sides must defer, rc=$RC out=$OUT"

# ---------- S4. a NON-sibling's PR on the same file is not this check's ------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4000 5002:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
chk
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S4: a PR on a non-sibling issue must not defer, rc=$RC out=$OUT"
# S4b. a PR whose branch names no sibling (a human branch)
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 900 feature/bh-5000 bin/lib/triage-state.sh
chk
[ "$RC" = 0 ] && ok || bad "S4b: a branch not ticket/bh-5000 must not count as the sibling's, rc=$RC out=$OUT"

# ---------- S5. a sibling with no open PR -------------------------------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975
chk
[ "$RC" = 0 ] && ok || bad "S5: a sibling with no PR must not defer, rc=$RC"
hlog | grep -q 'choice=build siblings=1 prs=0' && ok || bad "S5: log lacks siblings=1 prs=0: $(hlog)"

# ---------- S6. the stack base's PR is our base, not a sibling ----------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
chk PLAN_SIBLING_STACK_ON=ticket/bh-5000
[ "$RC" = 0 ] && ok || bad "S6: the stacked-on PR must be skipped, rc=$RC out=$OUT"

# ---------- S7. not a child: no read at all -----------------------------------
reset; mkb "Just a ticket, no footer." bin/lib/triage-state.sh
issues 5000:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
chk
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$H/fx/trace" ] && ok || bad "S7: a non-child must exit 0 with no read, rc=$RC trace=$(cat "$H/fx/trace" 2>/dev/null)"
# S7b. Part of #49750 is not Part of #4975
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:49750; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
chk
[ "$RC" = 0 ] && ok || bad "S7b: #49750 must not match #4975, rc=$RC out=$OUT"
# S7c. our own issue's earlier PR is not a sibling
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5001:4975; pull 900 ticket/bh-5001 bin/lib/triage-state.sh
chk
[ "$RC" = 0 ] && ok || bad "S7c: this ticket's own PR must not defer it, rc=$RC out=$OUT"

# ---------- S8. kill switches: no read ----------------------------------------
for kv in OVERLAP_SCHED=0 OVERLAP_SCHED=off PLAN_SIBLING_SEQ=0; do
  reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
  issues 5000:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
  chk "$kv"
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$H/fx/trace" ] && ok || bad "S8: $kv must exit 0 with no read, rc=$RC"
done
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
touch "$H/flags/plan-overlap-off"
chk
[ "$RC" = 0 ] && [ ! -e "$H/fx/trace" ] && ok || bad "S8: flags/plan-overlap-off must exit 0 with no read, rc=$RC"

# ---------- S9. unreadable reads fail open and say so ---------------------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975; pull 900 ticket/bh-5000 bin/lib/triage-state.sh
echo 75 > "$H/fx/rc.issues"
chk
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S9: an unreadable issue list must fail open, rc=$RC"
hlog | grep -q 'PLAN_SIBLING BH-5001 choice=build unjudged=issues rc=75' && ok || bad "S9: log lacks unjudged=issues rc=75: $(hlog)"
grep -q 'siblings=0' <<<"$(hlog)" && bad "S9: an unreadable list was logged as no siblings" || ok
# S9b. unreadable pulls
rm -f "$H/fx/rc.issues"; echo 44 > "$H/fx/rc.pulls"; scratch_rm "$H/logs"; mkdir -p "$H/logs"
chk
[ "$RC" = 0 ] && hlog | grep -q 'unjudged=pulls rc=44' && ok || bad "S9b: unreadable pulls must fail open and log, rc=$RC $(hlog)"
# S9c. one PR's files unreadable: never counted as disjoint
rm -f "$H/fx/rc.pulls"; echo 75 > "$H/fx/rc.files.900"; scratch_rm "$H/logs"; mkdir -p "$H/logs"
chk
[ "$RC" = 0 ] && ok || bad "S9c: an unreadable files read must fail open, rc=$RC"
hlog | grep -q 'unjudged=files:#900' && ok || bad "S9c: log must name the unjudged PR: $(hlog)"
grep -q ' disjoint' <<<"$(hlog)" && bad "S9c: an unread PR was logged disjoint: $(hlog)" || ok
# S9d. a pulls answer that is not an array (rc 0): never counted as disjoint
rm -f "$H/fx/rc.files.900"; echo '{"message":"Bad credentials"}' > "$H/fx/pulls.json"; scratch_rm "$H/logs"; mkdir -p "$H/logs"
chk
[ "$RC" = 0 ] && hlog | grep -q 'unjudged=pulls rc=shape' && ok || bad "S9d: a non-array pulls answer must log unjudged=pulls rc=shape, rc=$RC $(hlog)"
grep -q ' disjoint' <<<"$(hlog)" && bad "S9d: a non-array pulls answer was logged disjoint: $(hlog)" || ok

# ---------- S10. an in-app board is not judged ----------------------------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" check inapp "$B" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ ! -e "$H/fx/trace" ] && hlog | grep -q 'choice=build unjudged=in-app-board' && ok \
  || bad "S10: an in-app board must log unjudged=in-app-board and read nothing, rc=$RC $(hlog)"

# ---------- S11. the PR cap is logged as incomplete -------------------------------
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
issues 5000:4975 5002:4975 5003:4975
pull 900 ticket/bh-5000 a.sh; pull 902 ticket/bh-5002 b.sh; pull 903 ticket/bh-5003 bin/lib/triage-state.sh
chk PLAN_SIBLING_MAX_PRS=2
[ "$RC" = 0 ] && hlog | grep -q 'incomplete=1' && ok || bad "S11: past the PR cap must log incomplete=1, rc=$RC $(hlog)"
chk
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-5003 files=[bin/lib/triage-state.sh,bin/lib/triage-state.sh]" ] && ok \
  || bad "S11: the third sibling's overlap must defer under the default cap, rc=$RC out=$OUT"

# ---------- N. the sequencing note on the child issue -----------------------------
note() { # note <line> [VAR=val...] — sets RC OUT
  local l="$1"; shift
  OUT=$(env HARNESS="$H" "$@" bash "$H/bin/plan-sibling.sh" note cromford BH-5001 "$l" "$B" 2>&1); RC=$?
}
posts() { [ -s "$H/fx/posted" ] && wc -l < "$H/fx/posted" | tr -d ' ' || echo 0; }
# N1: one post, the exact copy
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
printf '2026-10-08 PLAN_SIBLING BH-5001 choice=after after=BH-5000 pr=#900 files=[x,x]\n' > "$B/pipeline.log"
note "$LINE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "N1: one post expected, rc=$RC posts=$(posts) out=$OUT"
[ "$(cat "$H/fx/posted" 2>/dev/null)" = "example-org/cromford 5001" ] && ok || bad "N1: posted to the wrong issue: $(cat "$H/fx/posted" 2>/dev/null)"
NB=$(cat "$H/fx/body.1" 2>/dev/null)
case "$NB" in "Holding this one until BH-5000 (#900) merges. Both plan to edit \`bin/lib/triage-state.sh\`, and building them side by side would conflict at merge. It re-checks before every planning pass and starts on its own once BH-5000's PR is merged or closed. Nothing for you to do."*) ok ;;
  *) bad "N1: body copy: $NB" ;; esac
case "$NB" in *Blocked-by*) bad "N1: body says Blocked-by" ;; *) ok ;; esac
case "$NB" in *—*) bad "N1: body has an em dash" ;; *) ok ;; esac
[ "$(printf '%s\n' "$NB" | tail -1)" = "<!-- plan-sibling:BH-5001:BH-5000 -->" ] && ok || bad "N1: last line must be the marker: $NB"
grep -q 'PLAN_SIBLING BH-5001 comment=posted after=BH-5000' <<<"$OUT" && ok || bad "N1: no comment=posted log: $OUT"
# BH-5799: the posted note is in the build's own-post ledger, so the plan
# thread gate never refuses this build's plan on it
[ "$(wc -l < "$B/own-comments.sha256" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "N1: the posted note must be in $B/own-comments.sha256"
# N2: the same pair again -> no second post
note "$LINE"
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "N2: a second note for the same pair must not post, posts=$(posts)"
grep -q 'comment=already' <<<"$OUT" && ok || bad "N2: no comment=already log: $OUT"
# N3: a failed post leaves no mark; the next call posts
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
echo 75 > "$H/fx/rc.comment"
note "$LINE"
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ -z "$(find "$H/state/comment-marks" -type f 2>/dev/null)" ] && ok || bad "N3: a failed post must leave no mark, rc=$RC $(find "$H/state/comment-marks" -type f 2>/dev/null)"
grep -q 'comment=failed rc=75' <<<"$OUT" && ok || bad "N3: no comment=failed log: $OUT"
rm -f "$H/fx/rc.comment"
note "$LINE"
[ "$(posts)" = 1 ] && ok || bad "N3: the retry must post, posts=$(posts)"
# a running-sibling defer (no PR in pipeline.log): no (#n), copy true for a build in flight
NB=$(cat "$H/fx/body.1" 2>/dev/null)
case "$NB" in "Holding this one until BH-5000 merges. "*"once BH-5000 is done building and has no open PR."*) ok ;;
  *) bad "N3: the no-PR copy: $NB" ;; esac
# N4: a hostile OTHER is refused, nothing posted
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
note "OVERLAP_DEFER BH-5001 vs ../x files=[a,a]"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [ ! -e "$H/state/comment-marks" ] && ok || bad "N4: ../x must be refused, rc=$RC posts=$(posts)"
note "OVERLAP_DEFER BH-5001 vs .. files=[a,a]"
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "N4: .. must be refused, rc=$RC"
# N5: comment switch and kill switch
note "$LINE" PLAN_SIBLING_COMMENT=0
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && grep -q 'comment=off' <<<"$OUT" && ok || bad "N5: PLAN_SIBLING_COMMENT=0 must not post, posts=$(posts) out=$OUT"
note "$LINE" OVERLAP_SCHED=0
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "N5: OVERLAP_SCHED=0 must not post"
# N6: not a child
reset; mkb "Just a ticket." bin/lib/triage-state.sh
note "$LINE"
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "N6: a non-child must not get a note, posts=$(posts)"
# N7: an in-app board
reset; mkb "$(body 4975 3)" bin/lib/triage-state.sh
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" note inapp BH-5001 "$LINE" "$B" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "N7: an in-app board must not get a GitHub note, posts=$(posts)"

# ---------- G. production entry: the gates.sh block --------------------------------
G="$T/g"; mkdir -p "$G/bin" "$G/b"
blk() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$DIR/bin/lib/rb/gates.sh"; }
[ "$(blk "plan overlap" | wc -l)" -gt 5 ] && ok || bad "G: gates.sh block 'plan overlap' not found"
{ echo 'set -uo pipefail'
  echo 'STAMP() { date -u +%FT%TZ; }'
  echo 'RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT.gate"; }'
  blk "plan overlap"
  echo 'echo FELL_THROUGH'; } > "$T/gate-run.sh"
cat > "$G/bin/plan-overlap.sh" <<'SH'
#!/bin/bash
echo "overlap $*" >> "$HARNESS/trace"
[ -s "$HARNESS/po.msg" ] && { cat "$HARNESS/po.msg"; exit 1; }
exit 0
SH
cat > "$G/bin/plan-sibling.sh" <<'SH'
#!/bin/bash
echo "sibling $1 $2 stack=${PLAN_SIBLING_STACK_ON:-}" >> "$HARNESS/trace"
case "$1" in
  check) [ -s "$HARNESS/ps.msg" ] && { cat "$HARNESS/ps.msg"; exit 1; }; exit 0 ;;
  note)  printf '%s\n' "$*" >> "$HARNESS/note.trace"; exit 0 ;;
esac
exit 2
SH
cat > "$G/bin/plan-after.sh" <<'SH'
#!/bin/bash
echo "after $*" >> "$HARNESS/trace"; exit 0
SH
chmod +x "$G/bin/"*.sh
gate() {
  rm -f "$G/b/RESULT.gate" "$G/trace" "$G/note.trace"
  OUT=$(HARNESS="$G" PROJECT=cromford KEY=BH-5001 BUILD="$G/b" REPO="$R" STACK_ON="${1:-}" bash "$T/gate-run.sh" 2>/dev/null); RC=$?
  RES=$(cat "$G/b/RESULT.gate" 2>/dev/null)
}
# G1: plan-overlap says build, plan-sibling finds the finished sibling -> After:
rm -f "$G/po.msg"; printf '%s\n' "$LINE" > "$G/ps.msg"
gate
[ "$RC" = 3 ] && ok || bad "G1: a sibling overlap must defer the build (exit 3), rc=$RC out=$OUT"
case "$RES" in "BUILD_DEFERRED OVERLAP_DEFER BH-5001 vs BH-5000"*"After: BH-5000"*) ok ;; *) bad "G1: RESULT: $RES" ;; esac
grep -q '^after record cromford BH-5001 OVERLAP_DEFER BH-5001 vs BH-5000' "$G/trace" 2>/dev/null && ok || bad "G1: plan-after record not called: $(cat "$G/trace" 2>/dev/null)"
[ "$(wc -l 2>/dev/null < "$G/note.trace" | tr -d ' ')" = 1 ] && grep -qxF "note cromford BH-5001 $LINE $G/b" "$G/note.trace" && ok \
  || bad "G1: the note must be posted once: $(cat "$G/note.trace" 2>/dev/null)"
# G1b: the stack base is handed through
gate ticket/bh-4999
grep -q 'sibling check cromford stack=ticket/bh-4999' "$G/trace" && ok || bad "G1b: STACK_ON not handed to plan-sibling: $(cat "$G/trace")"
# G2: plan-sibling says build -> fall through, no RESULT
rm -f "$G/ps.msg"
gate
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && [ -z "$RES" ] && ok || bad "G2: a clean sibling check must fall through, rc=$RC out=$OUT res=$RES"
grep -q '^sibling check' "$G/trace" && ok || bad "G2: plan-sibling check must run when plan-overlap says build"
[ ! -e "$G/note.trace" ] && ok || bad "G2: no note without a defer"
# G3: plan-overlap defers on a running sibling -> no sibling read, note still posted
printf 'OVERLAP_DEFER BH-5001 vs BH-4000 files=[x,x]\n' > "$G/po.msg"
gate
[ "$RC" = 3 ] && ok || bad "G3: plan-overlap's defer must still defer, rc=$RC"
grep -q '^sibling check' "$G/trace" && bad "G3: plan-sibling check must not run after plan-overlap deferred" || ok
grep -q '^note cromford BH-5001 OVERLAP_DEFER BH-5001 vs BH-4000' "$G/note.trace" 2>/dev/null && ok || bad "G3: the running-sibling decision must be noted too"
rm -f "$G/po.msg"

# plan-sibling reads and posts only through the REST lib, never the gh CLI.
[ ! -e "$T/gh-called" ] && ok || bad "gh was called: $(cat "$T/gh-called")"

# ---------- C. the .0 contract pre-creates the shared seams -----------------------
DEC="$DIR/bin/run-decompose.sh"
D="$T/d"; mkdir -p "$D/bin/lib" "$D/logs" "$D/env" "$D/prompts" "$D/flags"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$D" scoutish || exit 1
model_routes_fixture "$D" widget || exit 1
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/planned-files.sh" "$D/bin/"
cat > "$D/fleet.conf" <<'CONF'
scoutish  example-org/scoutish  https://scoutish.example  -           9 box-1 10.0.0.9
widget    example-org/widget    https://widget.example    /api/board  9 box-1 10.0.0.9
CONF
cat > "$D/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s' "${6:-}" > "$PROMPT_OUT"
exit 0
SH
chmod +x "$D/bin/agent-call.sh"
dec() { # dec <project> <num> <key> — run the real decomposer with no spec; the prompt lands in $T/prompt
  rm -rf "$T/db" "$T/prompt"; mkdir -p "$T/db"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_VERDICT: over\n' > "$T/db/size-gate.txt"
  ( cd "$T" && env HARNESS="$D" FLEET_CONF="$D/fleet.conf" PROMPT_OUT="$T/prompt" DECOMPOSE_DRY_RUN=1 \
      "$DEC" "$1" "$2" "$3" "$T/db" 300 12 ) >/dev/null 2>&1 </dev/null
}
dec scoutish 552 TK-552
[ -s "$T/prompt" ] && ok || bad "C1: the issues lane never reached agent-call"
for p in 'SHARED SEAMS GO IN THE CONTRACT' 'registry slot' 'section stub' 'empty module file' 'every shared seam it pre-creates'; do
  grep -qF -- "$p" "$T/prompt" 2>/dev/null && ok || bad "C1: the issues-lane prompt must say '$p'"
done
: > "$D/flags/decompose-board-filer-off"
dec widget 77 WO-77
[ -s "$T/prompt" ] && ok || bad "C2: the board lane never reached agent-call"
grep -qF "'DECOMPOSED: <comma-separated child keys>'" "$T/prompt" 2>/dev/null && ok || bad "C2: that was not the board-lane prompt"
for p in 'registry slot' 'section stub' 'empty module file' 'every shared seam path to that CONTRACT: line'; do
  grep -qF -- "$p" "$T/prompt" 2>/dev/null && ok || bad "C2: the board-lane prompt must say '$p'"
done


echo "plan-sibling-sequence.bh-4988: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
