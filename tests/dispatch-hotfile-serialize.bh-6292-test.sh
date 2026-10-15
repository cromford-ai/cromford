#!/bin/bash
# tests/dispatch-hotfile-serialize.bh-6292-test.sh — BH-6292: a ticket whose
# plan shares a CONFLICT HOTSPOT file with an open PR of ANY other ticket (not
# only a sibling) is held behind that PR (`plan-sibling.sh inflight`, then the
# existing After: hold), a file not on the hot list never holds it, the hold is
# bounded by PLAN_AFTER_MAX_MIN (`EXPIRED` -> $BUILD/after-expired), a hotfix
# is never held, and the hold is said once on the issue with `Blocked-by #<n>`.
#
# The REAL bin/plan-sibling.sh and bin/plan-after.sh run in a scratch harness
# $H against stub REST libs that serve fixtures from $H/fx, trace every read and
# record comment posts. A `gh` on PATH fails the suite if anything calls it.
# G-path cases run the real `# >>> overlap not-before` and `# >>> plan overlap`
# blocks of bin/lib/rb/gates.sh with the real scripts behind them.
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

# The REST stubs, written BEFORE the closure install (which never clobbers).
# Every read is traced to fx/trace; fx/rc.<what> makes it fail with that rc.
cat > "$H/bin/lib/gh-rest-list.sh" <<'SH'
_fx() { printf '%s\n' "$*" >> "$HARNESS/fx/trace"; }
_fxrc() { cat "$HARNESS/fx/rc.$1" 2>/dev/null || echo 0; }
gh_rest_issue_list() { _fx "issues $*"; printf '[]\n'; }
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
# open_pr_for_key (bin/lib/open-pr-precheck.sh) runs for real on this stub.
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest_pr_list_var() { # <var> <slug> <state> <owner:branch> <limit>
  printf '%s\n' "prvar $*" >> "$HARNESS/fx/trace"
  local br="${4#*:}"
  printf -v "$1" '%s' "$(jq -c --arg br "$br" '[.[] | select(.head.ref == $br)]' "$HARNESS/fx/pulls.json")"
}
SH
cat > "$T/stub/gh" <<SH
#!/bin/bash
echo "\$*" >> "$T/gh-called"
exit 99
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

scratch_install_closure bin/plan-sibling.sh "$H" >/dev/null || bad "closure install: bin/plan-sibling.sh"
scratch_install_closure bin/plan-after.sh "$H" >/dev/null || bad "closure install: bin/plan-after.sh"
[ -e "$H/bin/fleet-conf.sh" ] || cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
# The pool runs these as executables, behind `[ -x ]`.
for f in "$DIR/bin/plan-sibling.sh" "$DIR/bin/plan-after.sh"; do [ -x "$f" ] && ok || bad "$f must be executable"; done

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture || bad "fixture repo"

B="$T/b"
SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
mkb() { # mkb <touch file>... — candidate BH-6001's build dir (declared touch list)
  scratch_rm "$B"; mkdir -p "$B"
  printf '# plan\n\n## Files to touch\n\n- x\n' > "$B/plan.md"
  printf '%s\n' "$@" > "$B/touch-files.txt"
  printf '%s\n' "$@" > "$B/planned-files.txt"
  echo declared > "$B/touch-source"
  jq -n '{key:"BH-6001",body:"A plain ticket, no footer."}' > "$B/ticket-meta.json"
  printf '2026-10-14T00:00:00Z [cromford/BH-6001] HOTSPOT_CLAIM n=1 source=rows\n' > "$B/pipeline.log"
}
hot() { printf '%s\n' "$@" > "$B/.hotspots.txt"; }  # hot <path>... — rows in conflicts DESC order
shared() { printf '\n## Shared files\n\n' >> "$B/plan.md"; printf '%s\n' "$@" >> "$B/plan.md"; printf '\n## Changed symbols\n\n- none\n' >> "$B/plan.md"; }
pull() { # pull <pr> <head ref> <sha> <file>... — one open PR and its changed files
  local n="$1" ref="$2" sha="$3"; shift 3
  jq -c --argjson n "$n" --arg r "$ref" --arg s "$sha" '. + [{number:$n,state:"open",head:{ref:$r,sha:$s}}]' "$H/fx/pulls.json" > "$H/fx/p.tmp" \
    && mv "$H/fx/p.tmp" "$H/fx/pulls.json"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename:.,status:"modified"})' > "$H/fx/files.$n.json"
}
reset() {
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"
  mkdir -p "$H/fx" "$H/logs"; printf '[]\n' > "$H/fx/pulls.json"
  rm -f "$H/flags/plan-overlap-off"
}
inf() { # inf [VAR=val...] — plan-sibling inflight for $B; sets RC OUT ERR
  OUT=$(env HARNESS="$H" PLAN_OVERLAP_REPO="$R" "$@" bash "$H/bin/plan-sibling.sh" inflight cromford "$B" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
hlog() { cat "$H/logs/plan-hotspot.log" 2>/dev/null; }
reads() { grep -c "pulls/$1/files" "$H/fx/trace" 2>/dev/null || true; }
LR=bin/lead-review.sh

# ---------- the real gates.sh blocks -----------------------------------------
blk() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$DIR/bin/lib/rb/gates.sh"; }
for b in "overlap not-before" "plan overlap"; do
  [ "$(blk "$b" | wc -l)" -gt 5 ] && ok || bad "gates.sh block '$b' not found"
done
mkrun() { # mkrun <file> <block>... — a runner for those blocks, in order
  local f="$1"; shift
  { echo 'set -uo pipefail'
    echo 'STAMP() { date -u +%FT%TZ; }'
    echo 'RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT.gate"; }'
    for b in "$@"; do blk "$b"; done
    echo 'echo FELL_THROUGH'; } > "$f"
}
mkrun "$T/nb-run.sh" "overlap not-before"
mkrun "$T/po-run.sh" "plan overlap"
mkrun "$T/both-run.sh" "overlap not-before" "plan overlap"
# plan-overlap.sh (the in-flight build check) is not this ticket's: a stub
# that defers when $H/po.msg is set, else says build.
cat > "$H/bin/plan-overlap.sh" <<'SH'
#!/bin/bash
echo "overlap $*" >> "$HARNESS/fx/po.trace"
[ -s "$HARNESS/po.msg" ] && { cat "$HARNESS/po.msg"; exit 1; }
exit 0
SH
chmod +x "$H/bin/plan-overlap.sh"
gate() { # gate <runner> [VAR=val...] — sets RC OUT RES
  local r="$1"; shift
  rm -f "$B/RESULT.gate"
  OUT=$(env HARNESS="$H" PROJECT=cromford KEY=BH-6001 BUILD="$B" REPO="$R" STACK_ON= "$@" bash "$r" 2>/dev/null); RC=$?
  RES=$(cat "$B/RESULT.gate" 2>/dev/null)
}
marker() { mkdir -p "$H/state/overlap-after/cromford"; printf '%s\t%s\n' "$1" "$2" > "$H/state/overlap-after/cromford/BH-6001"; }

# ---------- S1. a hot file shared with an unrelated open PR -> defer -----------
reset; mkb "$LR" bin/mine.sh; hot worker/jobs/schema.sql "$LR"
pull 7000 ticket/bh-6000 "$SHA1" "$LR" bin/theirs.sh
inf
[ "$RC" = 1 ] && ok || bad "S1: a hot file in an open PR must defer, rc=$RC out=$OUT err=$ERR"
[ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6000 files=[$LR,$LR]" ] && ok || bad "S1: stdout: '$OUT'"
case "$ERR" in *"PLAN_INFLIGHT BH-6001 choice=after after=BH-6000 pr=#7000"*) ok ;; *) bad "S1: stderr lacks the after line: $ERR" ;; esac
hlog | grep -q "PLAN_INFLIGHT BH-6001 choice=after after=BH-6000 pr=#7000 files=\[$LR,$LR\]" && ok || bad "S1: plan-hotspot.log: $(hlog)"
# S1 through the production entry: the real plan overlap block
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
gate "$T/po-run.sh"
[ "$RC" = 3 ] && ok || bad "S1g: the gates block must defer (exit 3), rc=$RC out=$OUT"
case "$RES" in "BUILD_DEFERRED OVERLAP_DEFER BH-6001 vs BH-6000"*"After: BH-6000"*) ok ;; *) bad "S1g: RESULT: $RES" ;; esac
[ "$(cut -f1 "$H/state/overlap-after/cromford/BH-6001" 2>/dev/null)" = BH-6000 ] && ok || bad "S1g: no After: marker naming BH-6000"
grep -q 'PLAN_INFLIGHT BH-6001 choice=after after=BH-6000 pr=#7000' "$B/pipeline.log" && ok || bad "S1g: pipeline.log lacks the PLAN_INFLIGHT line"
# N1: the note posted by that same gates run
[ "$(cat "$H/fx/posted" 2>/dev/null)" = "example-org/cromford 6001" ] && ok || bad "N1: one post on #6001 expected: $(cat "$H/fx/posted" 2>/dev/null)"
NB=$(cat "$H/fx/body.1" 2>/dev/null)
[ "${NB%%$'\n'*}" = "Blocked-by #6000" ] && ok || bad "N1: first line must be 'Blocked-by #6000': $NB"
case "$NB" in *"#7000"*) ok ;; *) bad "N1: body must name PR #7000: $NB" ;; esac
case "$NB" in *"\`$LR\`"*) ok ;; *) bad "N1: body must name $LR: $NB" ;; esac
case "$NB" in *"Blocked-by:"*) bad "N1: body has a 'Blocked-by:' with a colon" ;; *) ok ;; esac
case "$NB" in *—*) bad "N1: body has an em dash" ;; *) ok ;; esac
[ "$(printf '%s\n' "$NB" | tail -1)" = "<!-- plan-sibling:BH-6001:BH-6000 -->" ] && ok || bad "N1: last line must be the marker: $NB"
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" note cromford BH-6001 "OVERLAP_DEFER BH-6001 vs BH-6000 files=[$LR,$LR]" "$B" 2>&1)
[ "$(wc -l < "$H/fx/posted" | tr -d ' ')" = 1 ] && grep -q 'comment=already' <<<"$OUT" && ok || bad "N1: a second note must not post: $OUT"

# ---------- S3. the other PR merged -> released, then inflight builds ----------
printf '[]\n' > "$H/fx/pulls.json"
PA=$(HARNESS="$H" bash "$H/bin/plan-after.sh" check cromford BH-6001 2>"$T/err"); RC=$?
[ "$RC" = 0 ] && [ -z "$PA" ] && grep -q 'choice=released after=BH-6000' "$T/err" && ok || bad "S3: a merged PR must release the hold, rc=$RC out=$PA err=$(cat "$T/err")"
inf
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S3: with the PR gone inflight must build, rc=$RC out=$OUT"

# ---------- S2. shared file NOT on the hot list -> build, no GitHub read --------
reset; mkb bin/x.sh; hot worker/jobs/schema.sql "$LR"
pull 7000 ticket/bh-6000 "$SHA1" bin/x.sh
inf
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S2: a non-hot shared file must build, rc=$RC out=$OUT"
hlog | grep -q 'PLAN_INFLIGHT BH-6001 choice=build hot=0' && ok || bad "S2: log lacks hot=0: $(hlog)"
[ ! -e "$H/fx/trace" ] && ok || bad "S2: no GitHub read expected: $(cat "$H/fx/trace")"

# ---------- S4. a hotfix is never deferred ----------------------------------------
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
printf 'OVERLAP_DEFER BH-6001 vs BH-5999 files=[x,x]\n' > "$H/po.msg"
gate "$T/po-run.sh" HOTFIX=1
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && [ -z "$RES" ] && ok || bad "S4: a hotfix must fall through, rc=$RC out=$OUT res=$RES"
grep -q 'PLAN_OVERLAP skipped hotfix' "$B/pipeline.log" && ok || bad "S4: pipeline.log lacks 'PLAN_OVERLAP skipped hotfix'"
[ ! -e "$H/fx/po.trace" ] && [ ! -e "$H/fx/trace" ] && ok || bad "S4: no overlap check may run for a hotfix: $(cat "$H/fx/po.trace" "$H/fx/trace" 2>/dev/null)"
gate "$T/po-run.sh"
[ "$RC" = 3 ] && ok || bad "S4: the same run without HOTFIX must defer (control), rc=$RC"
rm -f "$H/po.msg"
# S4b. a live After: marker does not hold a hotfix
reset; mkb "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
marker BH-6000 1
gate "$T/nb-run.sh" HOTFIX=1 PLAN_AFTER_MAX_MIN=0
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && ok || bad "S4b: a hotfix must not be held by After:, rc=$RC res=$RES"
gate "$T/nb-run.sh" PLAN_AFTER_MAX_MIN=0
[ "$RC" = 3 ] && case "$RES" in "BUILD_DEFERRED After: BH-6000 PR #7000 open"*) true ;; *) false ;; esac && ok \
  || bad "S4b: without HOTFIX the same marker must hold (control), rc=$RC res=$RES"

# ---------- S5 / C1. the wait cap: expired -> after-expired -> inflight builds --
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
marker BH-6000 1
PA=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=1 bash "$H/bin/plan-after.sh" check cromford BH-6001 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$PA" = "EXPIRED BH-6000" ] && ok || bad "S5: an expired hold must print 'EXPIRED BH-6000' rc 0, rc=$RC out=$PA"
marker BH-6000 1
gate "$T/both-run.sh" PLAN_AFTER_MAX_MIN=1
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && [ -z "$RES" ] && ok || bad "C1: past the cap the build must dispatch, rc=$RC out=$OUT res=$RES"
[ "$(cat "$B/after-expired" 2>/dev/null)" = BH-6000 ] && ok || bad "C1: \$BUILD/after-expired must be BH-6000: $(cat "$B/after-expired" 2>/dev/null)"
grep -q 'AFTER_CAP BH-6001 after=BH-6000 cap=PLAN_AFTER_MAX_MIN' "$B/pipeline.log" && ok || bad "C1: pipeline.log lacks AFTER_CAP"
grep -q 'PLAN_INFLIGHT BH-6001 choice=build vs BH-6000 cap=PLAN_AFTER_MAX_MIN expired' "$B/pipeline.log" && ok || bad "C1: pipeline.log lacks the expired skip line"
[ ! -e "$H/state/overlap-after/cromford/BH-6001" ] && ok || bad "C1: no new After: marker may be written past the cap"
# the exemption is for that key only: a second hot PR still defers
pull 7001 ticket/bh-6002 "$SHA2" "$LR"
inf
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6002 files=[$LR,$LR]" ] && ok || bad "S5: another hot PR must still defer, rc=$RC out=$OUT"
# C2. a live (not expired) marker prints no EXPIRED line
reset; mkb "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"; marker BH-6000 1
PA=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=0 bash "$H/bin/plan-after.sh" check cromford BH-6001 2>/dev/null); RC=$?
[ "$RC" = 3 ] && [ "$PA" = "AFTER BH-6000 PR #7000 open" ] && ok || bad "C2: a live hold must print only AFTER, rc=$RC out=$PA"

# ---------- S6. the files read is cached by head sha ---------------------------
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
inf; inf
[ "$RC" = 1 ] && [ "$(reads 7000)" = 1 ] && ok || bad "S6: two runs on one head sha must read files once, rc=$RC reads=$(reads 7000)"
[ "$(cat "$H/state/plan-inflight/cromford/7000.$SHA1" 2>/dev/null)" = "$LR" ] && ok || bad "S6: cache file missing or wrong"
printf '[]\n' > "$H/fx/pulls.json"; pull 7000 ticket/bh-6000 "$SHA2" "$LR"
inf
[ "$(reads 7000)" = 2 ] && ok || bad "S6: a new head sha must read again, reads=$(reads 7000)"
# S6b. a failed read is not cached, and is never a defer
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"; echo 75 > "$H/fx/rc.files.7000"
inf
[ "$RC" = 0 ] && hlog | grep -q 'unjudged=files:#7000' && ok || bad "S6b: a failed read must build and log unjudged, rc=$RC $(hlog)"
[ ! -e "$H/state/plan-inflight/cromford/7000.$SHA1" ] && ok || bad "S6b: a failed read must not be cached"
grep -q ' disjoint' <<<"$(hlog)" && bad "S6b: an unread PR was logged disjoint" || ok

# ---------- S7. a -rN branch names the -rN key ----------------------------------
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000-r2 "$SHA1" "$LR"
inf
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6000-r2 files=[$LR,$LR]" ] && ok || bad "S7: rc=$RC out=$OUT"
# and that key is one open_pr_for_key finds, so the After: hold really holds
marker BH-6000-r2 1
PA=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=0 bash "$H/bin/plan-after.sh" check cromford BH-6001 2>/dev/null); RC=$?
[ "$RC" = 3 ] && [ "$PA" = "AFTER BH-6000-r2 PR #7000 open" ] && ok || bad "S7: the -r2 hold must hold, rc=$RC out=$PA"
# S7b. agent/ branch
reset; mkb "$LR"; hot "$LR"; pull 7000 agent/BH-6000 "$SHA1" "$LR"
inf
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6000 files=[$LR,$LR]" ] && ok || bad "S7b: rc=$RC out=$OUT"
# S7c. a human branch is not a ticket's
reset; mkb "$LR"; hot "$LR"; pull 7000 feature/bh-6000 "$SHA1" "$LR"
inf
[ "$RC" = 0 ] && ok || bad "S7c: a non-ticket branch must not defer, rc=$RC out=$OUT"

# ---------- S8 / S9. own PR and stack base ----------------------------------------
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6001-r2 "$SHA1" "$LR"
inf
[ "$RC" = 0 ] && ok || bad "S8: the candidate's own -r2 PR must not defer it, rc=$RC out=$OUT"
reset; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
inf PLAN_SIBLING_STACK_ON=ticket/bh-6000
[ "$RC" = 0 ] && ok || bad "S9: the stack base must not defer, rc=$RC out=$OUT"

# ---------- oldest PR wins, PR cap -------------------------------------------------
reset; mkb "$LR"; hot "$LR"
pull 7005 ticket/bh-6005 "$SHA2" "$LR"; pull 7003 ticket/bh-6003 "$SHA1" "$LR"
inf
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6003 files=[$LR,$LR]" ] && ok || bad "order: the oldest PR must win, out=$OUT"
reset; mkb "$LR"; hot "$LR"
pull 7003 ticket/bh-6003 "$SHA1" bin/a.sh; pull 7005 ticket/bh-6005 "$SHA2" "$LR"
inf PLAN_INFLIGHT_MAX_PRS=1
[ "$RC" = 0 ] && hlog | grep -q 'incomplete=1' && [ "$(reads 7005)" = 0 ] && ok || bad "cap: past PLAN_INFLIGHT_MAX_PRS must not read and must log incomplete=1, rc=$RC $(hlog)"

# ---------- SF. the plan's ## Shared files section --------------------------------
reset; mkb bin/mine.sh; hot "$LR"; shared "- $LR — adds the hold arm"
pull 7000 ticket/bh-6000 "$SHA1" "$LR"
inf
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-6001 vs BH-6000 files=[$LR,$LR]" ] && ok || bad "SF1: a hot path only in Shared files must defer, rc=$RC out=$OUT"
reset; mkb bin/mine.sh; hot "$LR"; shared "- $LR — named only, not edited"
pull 7000 ticket/bh-6000 "$SHA1" "$LR"
inf
[ "$RC" = 0 ] && [ ! -e "$H/fx/trace" ] && ok || bad "SF2: a 'named only' line must not count, rc=$RC out=$OUT"
# SF3: psib_shared_files directly
P="$T/sf3.md"
cat > "$P" <<'MD'
# plan

## Files to touch

- bin/not-shared.sh — not this section

## Shared files

- `bin/a.sh` — edited
- bin/b.sh: edited too
- None
- `my file.sh` — a path with a space
- bin/c.sh — Named Only here
```
- bin/fenced.sh — inside a fence
```
Prose line bin/prose.sh is not a bullet.

## Next

- bin/after.sh — another section
MD
SF=$(HARNESS="$H" bash -c '. "$1"; psib_shared_files "$2"' _ "$H/bin/plan-sibling.sh" "$P" 2>/dev/null)
[ "$SF" = "bin/a.sh
bin/b.sh" ] && ok || bad "SF3: psib_shared_files printed: '$SF'"

# ---------- N2 / N3. the note's own rules --------------------------------------------
LINE="OVERLAP_DEFER BH-6001 vs BH-6000 files=[$LR,$LR]"
reset; mkb "$LR"
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" note cromford BH-6001 "$LINE" "$B" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$H/fx/posted" ] && ok || bad "N2: a non-child with no PLAN_INFLIGHT line must not get a note"
printf '2026-10-14 PLAN_INFLIGHT BH-6001 choice=after after=BH-6000 pr=#7000 files=[x,x]\n' >> "$B/pipeline.log"
OUT=$(HARNESS="$H" PLAN_SIBLING_COMMENT=0 bash "$H/bin/plan-sibling.sh" note cromford BH-6001 "$LINE" "$B" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$H/fx/posted" ] && grep -q 'comment=off' <<<"$OUT" && ok || bad "N3: PLAN_SIBLING_COMMENT=0 must not post, out=$OUT"
# N1b: the -r2 other still says the bare issue number
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" note cromford BH-6001 "OVERLAP_DEFER BH-6001 vs BH-6000-r2 files=[$LR,$LR]" "$B" 2>&1)
printf '2026-10-14 PLAN_INFLIGHT BH-6001 choice=after after=BH-6000-r2 pr=#7000 files=[x,x]\n' >> "$B/pipeline.log"
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" note cromford BH-6001 "OVERLAP_DEFER BH-6001 vs BH-6000-r2 files=[$LR,$LR]" "$B" 2>&1)
[ "$(head -1 "$H/fx/body.1" 2>/dev/null)" = "Blocked-by #6000" ] && ok || bad "N1b: a -r2 other must say 'Blocked-by #6000': $(cat "$H/fx/body.1" 2>/dev/null) $OUT"

# ---------- G. the hot-list cut ------------------------------------------------------
ROWS=(r1.sh r2.sh r3.sh r4.sh r5.sh r6.sh r7.sh r8.sh r9.sh r10.sh r11.sh)
reset; mkb r2.sh; hot "${ROWS[@]}"; pull 7000 ticket/bh-6000 "$SHA1" r2.sh
inf PLAN_INFLIGHT_HOT_TOP=1
[ "$RC" = 0 ] && ok || bad "G1: with HOT_TOP=1 row 2 is not hot, rc=$RC out=$OUT"
reset; mkb r11.sh; hot "${ROWS[@]}"; pull 7000 ticket/bh-6000 "$SHA1" r11.sh
inf
[ "$RC" = 0 ] && ok || bad "G2: by default row 11 is not hot, rc=$RC out=$OUT"
reset; mkb r10.sh; hot "${ROWS[@]}"; pull 7000 ticket/bh-6000 "$SHA1" r10.sh
inf
[ "$RC" = 1 ] && ok || bad "G2: by default row 10 is hot, rc=$RC out=$OUT"
# G3. off, and an unread hot list
inf PLAN_INFLIGHT_HOT_TOP=0
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G3: HOT_TOP=0 must build, rc=$RC"
reset; mkb r10.sh; hot "${ROWS[@]}"; pull 7000 ticket/bh-6000 "$SHA1" r10.sh
inf PLAN_INFLIGHT_HOT_TOP=0
[ ! -e "$H/fx/trace" ] && ok || bad "G3: HOT_TOP=0 must read nothing"
printf '2026-10-14T00:00:01Z [cromford/BH-6001] HOTSPOT_CLAIM n=0 source=none\n' >> "$B/pipeline.log"
inf
[ "$RC" = 0 ] && hlog | grep -q 'PLAN_INFLIGHT BH-6001 choice=build unjudged=hotlist' && [ ! -e "$H/fx/trace" ] && ok \
  || bad "G3: an unread hot list must build with unjudged=hotlist, rc=$RC $(hlog)"
reset; mkb r10.sh; pull 7000 ticket/bh-6000 "$SHA1" r10.sh
inf
[ "$RC" = 0 ] && hlog | grep -q 'unjudged=hotlist' && ok || bad "G3: a missing .hotspots.txt must build with unjudged=hotlist"
# kill switch
reset; mkb r10.sh; hot "${ROWS[@]}"; pull 7000 ticket/bh-6000 "$SHA1" r10.sh
inf OVERLAP_SCHED=0
[ "$RC" = 0 ] && [ ! -e "$H/fx/trace" ] && ok || bad "kill: OVERLAP_SCHED=0 must build with no read"
# an in-app board
OUT=$(HARNESS="$H" bash "$H/bin/plan-sibling.sh" inflight inapp "$B" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && hlog | grep -q 'choice=build unjudged=in-app-board' && ok || bad "inapp: an in-app board must not be judged, rc=$RC"

# ---------- C1f. the wait cap on a pool machine: the hold read from the fleet --
# A pool re-offer runs on a fresh machine: no marker file, so plan-after reads
# the hold back from the `overlap_defer` fleet row. The stub answers
# /api/artifacts the way the worker does (worker/jobs/src/routes/artifacts.js:
# `a.updated_at > since`), so a reader that asks only for the cap window never
# sees a row older than the cap. Cap 60 min, row 2 h old: the cap must fire.
ARTS="$T/arts.json"
cat > "$H/bin/jobs-client.sh" <<SH
. "$DIR/bin/lib/jobs/jobs.sh"
JOBS_BOX=box
_jobs_req() {
  case "\$1 \$2" in
    "GET /api/file-claims?"*) printf '{"claims":[]}\n' ;;
    "GET /api/artifacts?"*)
      local since; since=\$(printf '%s' "\$2" | sed -n 's/.*[?&]since=\([^&]*\).*/\1/p')
      printf '%s\n' "\$2" >> "$T/feed-asks"
      jq -c --arg s "\$since" '{artifacts: [.artifacts[] | select(\$s == "" or .updated_at > \$s)]}' "$ARTS" ;;
    *) return 1 ;;
  esac
}
SH
fleet_row() { # fleet_row <age_s> — BH-6001's deferred After: BH-6000 row, that old
  local u; u=$(date -u -d "@$(( $(date -u +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -nc --arg u "$u" '{artifacts:[{job_id:"j-6001",artifact_kind:"overlap_defer",artifact_ref:"deferred",box:"pool-m1",ticket_id:"BH-6001",updated_at:$u,detail:"{\"scope\":\"fleet\",\"choice\":\"after\",\"after\":\"BH-6000\"}"}]}' > "$ARTS"
}
reset; rm -f "$T/feed-asks"; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
fleet_row 7200
[ ! -e "$H/state/overlap-after/cromford/BH-6001" ] && ok || bad "C1f: the fresh machine must have no marker file"
PA=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=60 bash "$H/bin/plan-after.sh" check cromford BH-6001 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$PA" = "EXPIRED BH-6000" ] && ok || bad "C1f: a 2 h fleet hold past a 60 min cap must print 'EXPIRED BH-6000' rc 0, rc=$RC out=$PA"
hlog | grep -q 'PLAN_HOTSPOT BH-6001 choice=expired after=BH-6000 .* src=fleet' && ok || bad "C1f: no expired src=fleet line: $(hlog)"
rm -f "$B/after-expired"
gate "$T/both-run.sh" PLAN_AFTER_MAX_MIN=60
[ "$RC" = 0 ] && [ "$OUT" = FELL_THROUGH ] && [ -z "$RES" ] && ok || bad "C1f: past the cap the pool build must dispatch, rc=$RC out=$OUT res=$RES"
[ "$(cat "$B/after-expired" 2>/dev/null)" = BH-6000 ] && ok || bad "C1f: \$BUILD/after-expired must be BH-6000: $(cat "$B/after-expired" 2>/dev/null)"
# C1g (control). a 30 min fleet hold under the 60 min cap still holds.
reset; rm -f "$T/feed-asks"; mkb "$LR"; hot "$LR"; pull 7000 ticket/bh-6000 "$SHA1" "$LR"
fleet_row 1800
PA=$(HARNESS="$H" PLAN_AFTER_MAX_MIN=60 bash "$H/bin/plan-after.sh" check cromford BH-6001 2>/dev/null); RC=$?
[ "$RC" = 3 ] && [ "$PA" = "AFTER BH-6000 PR #7000 open" ] && ok || bad "C1g: a 30 min fleet hold under the cap must hold, rc=$RC out=$PA"
rm -f "$H/bin/jobs-client.sh"

[ ! -e "$T/gh-called" ] && ok || bad "gh was called: $(cat "$T/gh-called")"

echo "dispatch-hotfile-serialize.bh-6292: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
