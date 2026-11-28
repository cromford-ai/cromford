#!/bin/bash
# tests/contract-change-authority.bh-9929-test.sh — BH-9929 T10: a contract step
# that drops a table, drops a column or merges two tables (the PR carries the
# label `contract-change:human`) needs a --source human verdict on its head, in
# lane mode, in client mode and in an ungoverned repo. Driven on the real
# bin/lib/lead-authority.sh and bin/lib/contract-change-authority.sh with
# in-shell stubs for GitHub REST (gh_rest), the jobs worker (_jobs_req), the
# settings rows (setting_get) and the verdict reader (vd_standing). 0 network:
# a fake gh and curl on PATH record any call and the suite asserts none.
#   H1  label, no human row, mode lane, governed repo, conductor -> rc 1
#   H2  same, mode client                                         -> rc 1
#   H3  same, ungoverned repo                                     -> rc 1
#   H4  a human MERGE / MERGE-WITH-NOTES on this head, conductor  -> rc 0
#   H5  a human MERGE on an OLDER head                            -> rc 1
#   H6  a lead MERGE on this head, conductor                      -> rc 1
#   H7  the label read fails (REST error, not a PR object)        -> rc 2
#   H8  source lead + label -> rc 1 (also with a human MERGE); source human -> rc 0
#   H9  constraint step (no label): the same answer as la_decide without the hook
#   H11 no label, body line `CONTRACT-HUMAN-VERDICT: required`, conductor -> rc 1
#   H10 la_decide writes no ALERTS line and no beat; cc_needs_human rc 0/1/2
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/contract-change-authority.bh-9929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required by this test"; exit 1; }

ID="cca-$$"
GOV="example-org/gov-$ID"
UNGOV="example-org/free-$ID"
HEAD=aaaaaaaa11111111111111111111111111111111
OLD=bbbbbbbb22222222222222222222222222222222
mkdir -p "$T/set" "$T/tmp" "$T/catalog" "$T/fakebin" "$T/bin" "$T/logs" "$T/plain"
: > "$T/catalog/lead-protected-paths.seed.tsv"
export TMPDIR="$T/tmp"

# 0 network: any real gh or curl call is recorded and fails.
for b in gh curl; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/net"\nexit 1\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
export PATH="$T/fakebin:$PATH"
# A lane-alert or beat would land here.
for b in lane-alert.sh beat.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T" > "$T/bin/$b"
  chmod +x "$T/bin/$b"
done

# ---- the seams ----------------------------------------------------------------
# The jobs worker: the governed repo has one live glob (src/app/**), the other none.
_jobs_req() {
  case "$2" in
    *"repo=$(printf '%s' "$GOV" | tr 'A-Z' 'a-z')"*)
      jq -nc --arg r "$(printf '%s' "$GOV" | tr 'A-Z' 'a-z')" '{rows:[{repo:$r,glob:"src/app/**",removed_at:null}]}' ;;
    *) printf '{"rows":[]}' ;;
  esac
}
setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
# GitHub REST: pulls/<n> answers the PR with the labels in $T/labels (one per
# line) and the body in $T/body; $T/pr-fail makes that read fail; $T/pr-raw is answered verbatim.
gh_rest() {
  printf '%s\n' "$2" >> "$T/rest"
  case "$2" in
    *"/files?"*"page=1") printf '[{"filename":"src/app/x.tsx"}]' ;;
    *"/files?"*) echo '[]' ;;
    *"/pulls/"[0-9]*)
      [ -e "$T/pr-fail" ] && return 75
      [ -f "$T/pr-raw" ] && { cat "$T/pr-raw"; return 0; }
      jq -nc --arg h "$HEAD" --rawfile l "$T/labels" --rawfile b "$T/body" \
        '{number:7, head:{sha:$h}, body:$b, labels:($l | split("\n") | map(select(length > 0)) | map({name:.}))}' ;;
    *) return 75 ;;
  esac
}
# The verdict reader, head-bound like vd_standing: $T/standing holds
# `<verdict> <source> <head>`; a row on another head is not standing.
vd_standing() {
  local v s h
  [ -f "$T/standing" ] || return 1
  read -r v s h < "$T/standing"
  [ "$h" = "$3" ] || return 1
  printf '%s\t%s\t1\t2026-11-24T00:00:00Z\t-\t-\n' "$v" "$s"
}

HARNESS="$T"; export HARNESS
# shellcheck source=bin/lib/lead-authority.sh
. "$DIR/bin/lib/lead-authority.sh" || { echo "FAIL: the lib did not load"; exit 1; }

reset() {
  rm -f "$T/labels" "$T/pr-fail" "$T/pr-raw" "$T/standing" "$T/rest" "$T/set/"*
  : > "$T/labels"; printf 'CONTRACT STEP: contract of #41\n' > "$T/body"
}
label() { printf '%s\n' "$@" > "$T/labels"; }
mode() { printf '%s' "$2" > "$T/set/lead_authority_mode.$(printf '%s' "$1" | tr 'A-Z/' 'a-z.')"; }
stand() { printf '%s %s %s\n' "$1" "$2" "$3" > "$T/standing"; }
# decide <repo> <source> — rc and reason of the real la_decide.
decide() { local rc=0; la_memo_reset; la_decide "$1" 7 "$HEAD" "$2" || rc=$?; printf 'rc=%s reason=%s' "$rc" "$LA_REASON"; }
NEED="contract step drops a table/column or merges tables: needs a --source human verdict"

# ---- H1 lane, governed --------------------------------------------------------
reset; label contract-step:contract contract-change:human; mode "$GOV" lane
R=$(decide "$GOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H1 label + lane + no human row = rc 1 ($R)"
# ---- H2 client ----------------------------------------------------------------
mode "$GOV" client
R=$(decide "$GOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H2 label + client + no human row = rc 1 ($R)"
# ---- H3 ungoverned ------------------------------------------------------------
R=$(decide "$UNGOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H3 label + ungoverned repo = rc 1 ($R)"
# ---- H4 human MERGE on this head ----------------------------------------------
for v in MERGE MERGE-WITH-NOTES; do
  for repo in "$GOV" "$UNGOV"; do
    stand "$v" human "$HEAD"
    R=$(decide "$repo" conductor)
    case "$R" in rc=0\ *) ok ;; *) bad "H4 human $v on this head clears $repo ($R)" ;; esac
  done
done
stand BLOCK human "$HEAD"
R=$(decide "$GOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H4 a human BLOCK does not clear ($R)"
# ---- H5 human MERGE on an older head ------------------------------------------
stand MERGE human "$OLD"
R=$(decide "$GOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H5 a human MERGE on an older head = rc 1 ($R)"
# ---- H6 a lead MERGE on this head ---------------------------------------------
stand MERGE lead "$HEAD"
R=$(decide "$UNGOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H6 a lead MERGE never clears a human-class step ($R)"
# ---- H7 the label read fails --------------------------------------------------
reset; label contract-change:human; touch "$T/pr-fail"
R=$(decide "$UNGOV" conductor)
case "$R" in rc=2\ *labels*) ok ;; *) bad "H7 a failed label read = rc 2 ($R)" ;; esac
rm -f "$T/pr-fail"; printf '{"message":"Not Found"}' > "$T/pr-raw"
R=$(decide "$GOV" lead)
case "$R" in rc=2\ *) ok ;; *) bad "H7 a body that is not a PR object = rc 2 ($R)" ;; esac
printf '{"head":{"sha":"%s"},"labels":"x"}' "$HEAD" > "$T/pr-raw"
R=$(decide "$GOV" lead)
case "$R" in rc=2\ *) ok ;; *) bad "H7 labels that are not an array = rc 2 ($R)" ;; esac
# ---- H8 sources ---------------------------------------------------------------
reset; label contract-change:human
R=$(decide "$UNGOV" lead)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H8 source lead + label = rc 1 ($R)"
stand MERGE human "$HEAD"
R=$(decide "$GOV" lead)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H8 source lead + label = rc 1 even with a human MERGE ($R)"
R=$(decide "$GOV" human)
[ "$R" = "rc=0 reason=a human verdict" ] && ok || bad "H8 source human = rc 0 ($R)"
# ---- H9 constraint step: the normal path's answer -----------------------------
# The reference: the same la_decide from a tree without the authority lib (the
# hook finds no cc_la_gate and does nothing).
# scratch-closure-allow: a lone copy of lead-authority.sh with no contract-change-authority.sh beside it, to prove the hook does nothing when the lib is absent
cp "$DIR/bin/lib/lead-authority.sh" "$T/plain/lead-authority.sh"
plain() { ( unset -f cc_la_gate cc_needs_human; . "$T/plain/lead-authority.sh"
            command -v cc_la_gate >/dev/null 2>&1 && { echo "hook-loaded"; exit 0; }
            decide "$1" "$2" ) ; }
for m in lane client; do
  for repo in "$GOV" "$UNGOV"; do
    for src in lead conductor; do
      reset; label contract-step:contract bug; mode "$GOV" "$m"
      A=$(decide "$repo" "$src"); B=$(plain "$repo" "$src")
      [ "$A" = "$B" ] && [ "$B" != hook-loaded ] && ok || bad "H9 no label ($m, $repo, $src): hook '$A' vs plain '$B'"
    done
  done
done
reset; label contract-step:contract; mode "$GOV" client
R=$(decide "$GOV" conductor)
case "$R" in "rc=1 reason=touches member-facing paths"*) ok ;; *) bad "H9 a constraint step still gets the client-mode answer ($R)" ;; esac
mode "$GOV" lane
R=$(decide "$UNGOV" conductor)
[ "$R" = "rc=0 reason=not governed" ] && ok || bad "H9 a constraint step in an ungoverned repo = rc 0 not governed ($R)"
# ---- H11 the body line alone holds (a failed label write) ------------------
reset; label contract-step:contract
printf 'CONTRACT STEP: contract of #41\r\nCONTRACT-HUMAN-VERDICT: required\r\n' > "$T/body"
R=$(decide "$UNGOV" conductor)
[ "$R" = "rc=1 reason=$NEED" ] && ok || bad "H11 body line, no label, no human verdict = rc 1 ($R)"
stand MERGE human "$HEAD"
R=$(decide "$UNGOV" conductor)
case "$R" in rc=0\ *) ok ;; *) bad "H11 body line + human MERGE on this head = rc 0 ($R)" ;; esac
printf 'see `CONTRACT-HUMAN-VERDICT: required` in the docs\nCONTRACT-HUMAN-VERDICT: requiredish\n' > "$T/body"; rm -f "$T/standing"
R=$(decide "$UNGOV" conductor)
[ "$R" = "rc=0 reason=not governed" ] && ok || bad "H11 the line only in prose, or another word, does not hold ($R)"
# ---- H10 no ALERTS / beat; cc_needs_human answers ------------------------------
reset; label contract-change:human; mode "$GOV" lane
decide "$GOV" conductor >/dev/null; decide "$UNGOV" lead >/dev/null
[ ! -s "$T/alerts" ] && [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "H10 la_decide wrote an alert: $(cat "$T/alerts" "$T/logs/ALERTS.log" 2>/dev/null)"
cc_needs_human "$GOV" 7; RC=$?
[ "$RC" = 0 ] && ok || bad "H10 cc_needs_human with the label = rc 0 (rc $RC)"
label contract-step:contract; cc_needs_human "$GOV" 7; RC=$?
[ "$RC" = 1 ] && ok || bad "H10 cc_needs_human without the label = rc 1 (rc $RC)"
touch "$T/pr-fail"; cc_needs_human "$GOV" 7; RC=$?
[ "$RC" = 2 ] && ok || bad "H10 cc_needs_human on a failed read = rc 2 (rc $RC)"
rm -f "$T/pr-fail"; : > "$T/rest"; cc_needs_human "$GOV" 7 >/dev/null
[ "$(grep -c "/pulls/7\$" "$T/rest")" = 1 ] && ok || bad "H10 cc_needs_human makes one pulls/<n> read: $(cat "$T/rest")"
[ ! -s "$T/net" ] && ok || bad "0 network: a real gh/curl was called: $(cat "$T/net")"

echo "contract-change-authority: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
