#!/bin/bash
# tests/br-record-retire.bh-10157-test.sh — BH-10157 (BH-9937 C1): the bh-9369
# closed-PR retire on the PR record. In step record, bcr_load_one reads no
# closed-list page, and a candidate row whose PR the record says is merged or
# closed leaves the list in the pre-pass (brd_row_word in
# bin/blocked-resolver.d/bh-10157-record-discovery.sh), and is skipped in
# discovery from the next tick on.
#
# The decision table (plan, Failure modes), one block each:
#   W1  record, PR absent from the open list, record merged: retired merged,
#       0 closed pages, 0 GitHub per-PR state reads, store row added ret=1
#   W2  record, record closed: retired closed
#   W3  record, PR in the open list, record merged (stale): not retired, 0 peeks
#   W4  record, a rebuild-* reason: not retired, 0 peeks (function)
#   W5  record, open list unreadable, record closed: not retired
#   W6  record, open list unreadable, record merged: retired merged
#   W7  record, record open: not retired
#   W8  record, peek miss: 1 pulls/<n> read for that PR, 1 PRR_MISS line, act
#       on GitHub's answer
#   W9  shadow, closed pages empty, record merged: not retired, 1 PRR_SHADOW
#   W10 shadow, closed pages merged, record merged: retired, 0 PRR_SHADOW
#   W11 off, record merged: not retired, 0 /api/pr-records GETs
#   W12 record: another repo's url, #2890 (open) near #289, url `-`: not
#       retired, 0 peeks (function)
# The round trips:
#   R1  tick 2 after W1/W2: retired_skipped=2, no new event line, 0 peeks
#   R2  an old url-only $BCR_RETIRED_OUT line still marks an existing row
#   R3  a row added 100 days ago is pruned by a record-step tick at
#       BR_CLOSED_PR_KEEP_DAYS=90; the watermark stays
#   R4  observe mode in record: says WOULD, no event, no store row
#
# WHAT IS DRIVEN. The driver cases run the real bin/blocked-resolver.sh end to
# end against a scratch $HARNESS (the rig of tests/br-retire-closed.bh-9369-test.sh).
# No vendor is called (BH-7563): gh is a local stub that answers from fixture
# JSON and records every call, GH_TOKEN is empty, and the jobs worker is a stub
# _jobs_req that answers the PR record from fixture JSON.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/br-record-retire.bh-10157-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The files under test, named by rooted path so the orphan check sees them.
FRAG="$DIR/bin/blocked-resolver.d/bh-10157-record-discovery.sh"
FRAG9369="$DIR/bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh"
SEAMF="$DIR/bin/lib/prr-shadow.d/blocked-resolver.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh bin/lib/prr-shadow.sh bin/lib/pr-record.sh \
         $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# The seam is sourced by prr_seam_load from a computed path, which the closure
# walk cannot follow: install it the same way, by its own closure.
if [ -f "$SEAMF" ]; then
  ( cd "$DIR" && scratch_install_closure bin/lib/prr-shadow.d/blocked-resolver.sh "$H" ) >/dev/null \
    || { echo "setup: could not install the seam"; exit 1; }
fi
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# THE gh STUB. The closed pull list is answered here, first arm: page k is
# $T/closed-<k>.json (default []), $T/st-closed sets the status, and every
# read is one line in $T/closedreads.txt. $T/st-closed-<k> sets one page's status. Everything else is the shared stub.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    printf '%s\n' "\$*" >> "$T/closedreads.txt"
    K=\$(printf '%s' "\$*" | sed -nE 's#.*[?&]page=([0-9]+).*#\1#p')
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"
    S=\$(cat "$T/st-closed-\$K" 2>/dev/null || _ghs_st closed 200)
    _ghs_send "\$S" "\$(cat "$T/closed-\$K.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
# THE JOBS STUB (BH-10157). GET /api/pr-records?...state=open answers
# $T/rec-list.json (absent = a failed read); ?...number=<n> answers
# $T/rec-<n>.json (absent = no record). Every request is a line in $T/jobs.txt.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  case "\$1 \$2" in
    "GET /api/pr-records?"*"state=open"*) [ -f "$T/rec-list.json" ] && cat "$T/rec-list.json" && return 0; return 1 ;;
    "GET /api/pr-records?"*"number="*) local n="\${2##*number=}"; n="\${n%%&*}"
      [ -f "$T/rec-\$n.json" ] && cat "$T/rec-\$n.json" && return 0; echo '{"row":null}'; return 0 ;;
  esac
  return 1
}
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
STORE="$ST/.closed-prs-p1.tsv"
LOGF="$H/logs/blocked-resolver.log"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ROWS"; }
LOG() { cat "$LOGF" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NLINES() { grep -c -- "$1" "$LOGF" 2>/dev/null; }
# A row was DISPATCHED when the rung loop logged a line for its key.
# The candidate key of conductor row o/p1#<n> is o-p1-<n>; a dispatch is its `-> <rung>` line.
DISPATCHED() { grep -qE "p1/o-p1-$1 \[[^]]*\] -> " "$LOGF"; }
OVERDUE_OF() { grep 'OVERDUE' "$LOGF" | grep -c -- "p1/o-p1-$1 "; }
NCLOSEDREADS() { grep -c . "$T/closedreads.txt" 2>/dev/null; }
# CPR <num> <merged|closed> <closed-age-secs> [updated-age-secs] — one closed-list item.
CPR() {
  local m=null; [ "$2" = merged ] && m="\"$(ISO $((NOW - $3)))\""
  jq -nc --argjson n "$1" --arg c "$(ISO $((NOW - $3)))" --arg u "$(ISO $((NOW - ${4:-$3})))" --argjson m "$m" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), state:"closed",
      merged_at:$m, closed_at:$c, updated_at:$u}'
}
OPR() { # OPR <num> — one open-list item (an author harness_pr_list keeps)
  jq -nc --argjson n "$1" --arg u "$(ISO $((NOW - 600)))" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), title:"t", body:"",
      head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ref:("ticket/ts-"+($n|tostring))}, base:{ref:"main"},
      draft:false, user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}'
}
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          rm -f "$T"/closed-*.json "$T/st-closed" "$T"/st-closed-* "$H/flags/blocked-resolver-observe" "$T/openprs" "$T/st-prlist" "$H/logs/ALERTS.log" \
                "$T/rec-list.json" "$T"/rec-*.json "$T/prstate" "$H/logs/prr-shadow.log"
          : > "$T/jobs.txt"
          : > "$T/gh.txt"; : > "$T/closedreads.txt"; : > "$T/alerts.txt"; : > "$T/agent.txt"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"; BRENV=(); }

IRONLAW="iron-law (8 hit(s))"
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
U="https://github.com/o/p1/pull"
[ -f "$FRAG" ] && ok || bad "0: bin/blocked-resolver.d/bh-10157-record-discovery.sh must exist"

SHADOW="$H/logs/prr-shadow.log"
# REC_OPEN <n>... — the record's open list, fresh and whole.
REC_OPEN() {
  local n
  for n in "$@"; do
    jq -nc --argjson n "$n" --arg u "$(ISO $((NOW - 600)))" \
      '{number:$n, head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", head_ref:("ticket/ts-"+($n|tostring)), base_ref:"main",
        author:"operator", url:("https://github.com/o/p1/pull/"+($n|tostring)), updated_at:$u, created_at:$u, draft:false}'
  done | jq -s '{rows:., truncated:false, sync:{age_s:5, synced_at:"2026-11-26T00:00:00Z"}, missing:null, unknown:0}' > "$T/rec-list.json"
}
# REC <n> <state> [merged-age-secs] — the record row of one PR (the peek).
REC() {
  local m=null; [ "$2" = merged ] && m="\"$(ISO $((NOW - ${3:-3600})))\""
  jq -nc --arg s "$2" --argjson m "$m" --arg u "$(ISO $((NOW - 60)))" \
    '{row:{state:$s, merged_at:$m, updated_at:$u}, age_s:3}' > "$T/rec-$1.json"
}
NPEEKS() { grep -c 'number=' "$T/jobs.txt" 2>/dev/null; }
# EV <n> <word> — event lines that retire PR #<n> with <word>. The candidate key
# carries the PR number (o-p1-<n>) or the ticket the stub names (TK-<n>).
EV() { grep 'EVENT resolver_retired' "$LOGF" 2>/dev/null | grep -cE -- "-$1 .*PR is $2"; }
NEV() { grep -c 'EVENT resolver_retired' "$LOGF" 2>/dev/null; }
PEEKS_OF() { grep -c "number=$1\$" "$T/jobs.txt" 2>/dev/null; }
NSTATE() { grep -cE 'repos/o/p1/pulls/[0-9]+$' "$T/gh.txt" 2>/dev/null; }
RECBASE=(BR_PER_TICK=20 BR_PER_TICK_P1=20)

# ============================================================================
# W1 W2 W3 W7 + the driver half of W12 (record, the open list readable).
#   #301 merged, #302 closed, #303 open-listed with a stale merged record,
#   #307 open, #2890 open-listed while #289 is merged, #293 another repo.
# ============================================================================
CLEAN
ROWADD "o/p1#301"  "$((NOW - 38960 * 60))" "$IRONLAW"  "$U/301"
ROWADD "o/p1#302"  "$((NOW - 7200))"       "$CONFLICT" "$U/302"
ROWADD "o/p1#303"  "$((NOW - 7200))"       "$CONFLICT" "$U/303"
ROWADD "o/p1#307"  "$((NOW - 7200))"       "$CONFLICT" "$U/307"
ROWADD "o/p1#2890" "$((NOW - 7200))"       "$CONFLICT" "$U/2890"
ROWADD "o/p1#293"  "$((NOW - 7200))"       "$CONFLICT" "https://github.com/other/repo/pull/289"
REC 301 merged 3600; REC 302 closed; REC 303 merged; REC 307 open; REC 289 merged
{ OPR 303; OPR 2890; } | jq -s . > "$T/openprs"
REC_OPEN 303 2890
BRENV=("${RECBASE[@]}" GH_SOURCE=record)
RUN p1
[ "$(NCLOSEDREADS)" = 0 ] && ok || bad "W1: record reads 0 closed-list pages (reads: $(cat "$T/closedreads.txt"))"
[ "$(NLINES 'closed-PR read for o/p1: record step')" = 1 ] && ok || bad "W1: one line says the record step read no page ($(LOG | grep -i 'closed-PR'))"
[ "$(grep -c 'repos/o/p1/pulls?state=open' "$T/gh.txt")" = 0 ] && ok || bad "W1: the open list comes from the record ($(grep 'state=open' "$T/gh.txt" | head -2))"
[ "$(EV 301 merged)" = 1 ] && ! DISPATCHED 301 && ok || bad "W1: #301 retires merged (log: $(LOG | grep -E 'EVENT|301' | head -4))"
grep -qE "^301	merged	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	1$" "$STORE" && ok || bad "W1: the store has 301 merged <ISO> 1 ($(cat "$STORE" 2>/dev/null))"
[ "$(EV 302 closed)" = 1 ] && ! DISPATCHED 302 && ok || bad "W2: #302 retires closed (log: $(LOG | grep -E 'EVENT|302' | head -4))"
grep -qE "^302	closed	[^	]+	1$" "$STORE" && ok || bad "W2: the store has 302 closed <ISO> 1 ($(cat "$STORE" 2>/dev/null))"
[ "$(EV 303 '')" = 0 ] && DISPATCHED 303 && [ "$(PEEKS_OF 303)" = 0 ] && ok \
  || bad "W3: #303 is in the open list: not retired, never peeked (peeks: $(PEEKS_OF 303); log: $(LOG | grep -- '-303' | head -3))"
[ "$(EV 307 '')" = 0 ] && DISPATCHED 307 && [ "$(PEEKS_OF 307)" = 1 ] && ok \
  || bad "W7: record open: #307 is peeked once and not retired (peeks: $(PEEKS_OF 307))"
[ "$(EV 2890 '')" = 0 ] && DISPATCHED 2890 && [ "$(PEEKS_OF 2890)" = 0 ] && [ "$(PEEKS_OF 289)" = 0 ] && ok \
  || bad "W12: #2890 (open) is not retired, and neither it nor #289 is peeked"
[ "$(grep -c 'repo=other' "$T/jobs.txt")" = 0 ] && DISPATCHED 293 && ok || bad "W12: another repo's url is never peeked and not retired"
[ "$(NEV)" = 2 ] && ok || bad "W1/W2: exactly 2 retire events (log: $(LOG | grep 'EVENT resolver_retired'))"

# ============================================================================
# R1 tick 2: no new event, the two rows are skipped in discovery, 0 peeks.
# ============================================================================
: > "$LOGF"; : > "$T/closedreads.txt"; : > "$T/jobs.txt"; : > "$T/gh.txt"
RUN p1
[ "$(PFIELD retired_skipped)" = 2 ] && ok || bad "R1: tick 2 retired_skipped=2 (prof: $(LASTPROF))"
[ "$(NEV)" = 0 ] && ok || bad "R1: tick 2 says no new event line (log: $(LOG | grep EVENT))"
[ "$(PEEKS_OF 301)" = 0 ] && [ "$(PEEKS_OF 302)" = 0 ] && ok || bad "R1: tick 2 does not peek #301 or #302 again"

# ============================================================================
# W5 W6: record, the open list unreadable (record miss + GitHub 500).
# ============================================================================
CLEAN
ROWADD "o/p1#305" "$((NOW - 7200))" "$CONFLICT" "$U/305"
ROWADD "o/p1#306" "$((NOW - 7200))" "$CONFLICT" "$U/306"
REC 305 closed; REC 306 merged
echo 500 > "$T/st-prlist"
BRENV=("${RECBASE[@]}" GH_SOURCE=record)
RUN p1
[ "$(EV 305 '')" = 0 ] && DISPATCHED 305 && ok || bad "W5: closed-unmerged is not retired while the open list is unreadable (log: $(LOG | grep -E 'EVENT|305' | head -3))"
[ "$(EV 306 merged)" = 1 ] && ok || bad "W6: a merged PR retires while the open list is unreadable (log: $(LOG | grep -E 'EVENT|306' | head -3))"

# ============================================================================
# W8: record, the peek misses: 1 pulls/<n> read decides.
# ============================================================================
CLEAN
ROWADD "o/p1#308" "$((NOW - 7200))" "$CONFLICT" "$U/308"
REC_OPEN
echo MERGED > "$T/prstate"
BRENV=("${RECBASE[@]}" GH_SOURCE=record)
RUN p1
W8BASE=$(grep -c 'repos/o/p1/pulls/308$' "$T/gh.txt")
[ "$(grep -c 'PRR_MISS lane=blocked-resolver key=o/p1#308@state why=unknown fallback=github' "$SHADOW" 2>/dev/null)" = 1 ] && ok \
  || bad "W8: one PRR_MISS ... fallback=github line ($(cat "$SHADOW" 2>/dev/null))"
[ "$(EV 308 merged)" = 1 ] && ok || bad "W8: GitHub says merged, so #308 retires (log: $(LOG | grep -E 'EVENT|308' | head -4))"
[ "$(NCLOSEDREADS)" = 0 ] && ok || bad "W8: record reads no closed page"
[ "$(grep -cE 'repos/o/p1/pulls/[0-9]+$' "$T/gh.txt")" = "$W8BASE" ] && ok || bad "W8: every per-PR read names #308 only ($(grep -E 'pulls/[0-9]+$' "$T/gh.txt"))"
# The same tick with the record hit: exactly one pulls/308 read fewer.
CLEAN
ROWADD "o/p1#308" "$((NOW - 7200))" "$CONFLICT" "$U/308"
REC_OPEN; REC 308 merged
echo MERGED > "$T/prstate"
BRENV=("${RECBASE[@]}" GH_SOURCE=record)
RUN p1
[ "$(EV 308 merged)" = 1 ] && ok || bad "W8: the record hit retires #308 too"
[ "$(grep -c 'repos/o/p1/pulls/308$' "$T/gh.txt")" = $((W8BASE - 1)) ] && ok \
  || bad "W8: the miss adds exactly 1 pulls/308 read (miss: $W8BASE, hit: $(grep -c 'repos/o/p1/pulls/308$' "$T/gh.txt"))"

# ============================================================================
# W9 W10: shadow. #309 the record says merged, no closed page has it;
#   #310 both say merged.
# ============================================================================
CLEAN
ROWADD "o/p1#309" "$((NOW - 7200))" "$CONFLICT" "$U/309"
ROWADD "o/p1#310" "$((NOW - 7200))" "$CONFLICT" "$U/310"
REC 309 merged; REC 310 merged
CPR 310 merged 3600 | jq -s . > "$T/closed-1.json"
REC_OPEN
BRENV=("${RECBASE[@]}" GH_SOURCE=shadow)
RUN p1
[ "$(grep -c 'PRR_SHADOW lane=blocked-resolver key=o/p1#309@state ' "$SHADOW" 2>/dev/null)" = 1 ] && ok \
  || bad "W9: one PRR_SHADOW key=o/p1#309@state line ($(cat "$SHADOW" 2>/dev/null))"
[ "$(EV 309 '')" = 0 ] && DISPATCHED 309 && ok || bad "W9: shadow acts on GitHub: #309 is not retired"
[ "$(NCLOSEDREADS)" = 1 ] && ok || bad "W9: shadow reads the closed pages as today (reads: $(NCLOSEDREADS))"
[ "$(grep -c 'PRR_SHADOW lane=blocked-resolver key=o/p1#310@state' "$SHADOW" 2>/dev/null)" = 0 ] && [ "$(EV 310 merged)" = 1 ] && ok \
  || bad "W10: both say merged: #310 retires with no PRR_SHADOW line ($(cat "$SHADOW" 2>/dev/null))"

# ============================================================================
# W11: off. The record says merged; nothing reads it.
# ============================================================================
CLEAN
ROWADD "o/p1#311" "$((NOW - 7200))" "$CONFLICT" "$U/311"
REC 311 merged
BRENV=("${RECBASE[@]}" GH_SOURCE=off)
RUN p1
[ "$(grep -c '/api/pr-records' "$T/jobs.txt")" = 0 ] && ok || bad "W11: off makes 0 /api/pr-records GETs ($(cat "$T/jobs.txt"))"
[ "$(EV 311 '')" = 0 ] && DISPATCHED 311 && ok || bad "W11: off: #311 is not retired"
[ "$(NCLOSEDREADS)" = 1 ] && ok || bad "W11: off reads the closed pages as today"

# ============================================================================
# R3: a record-step tick prunes a row added 100 days ago; the watermark stays.
# ============================================================================
CLEAN
mkdir -p "$ST"
printf '#wm\t%s\n41\tmerged\t%s\t1\n42\tclosed\t%s\t1\n' "$(ISO $((NOW - 3600)))" "$(ISO $((NOW - 100 * 86400)))" "$(ISO $((NOW - 10 * 86400)))" > "$STORE"
REC_OPEN
BRENV=("${RECBASE[@]}" GH_SOURCE=record BR_CLOSED_PR_KEEP_DAYS=90)
RUN p1
grep -q '^41	' "$STORE" && bad "R3: the 100-day row is pruned ($(cat "$STORE"))" || ok
grep -q '^42	closed	' "$STORE" && ok || bad "R3: the 10-day row stays ($(cat "$STORE"))"
[ "$(head -1 "$STORE")" = "$(printf '#wm\t%s' "$(ISO $((NOW - 3600)))")" ] && ok || bad "R3: the watermark stays ($(head -1 "$STORE"))"

# ============================================================================
# R4: observe mode in record.
# ============================================================================
CLEAN
ROWADD "o/p1#314" "$((NOW - 7200))" "$CONFLICT" "$U/314"
REC 314 merged; REC_OPEN
touch "$H/flags/blocked-resolver-observe"
BRENV=("${RECBASE[@]}" GH_SOURCE=record)
RUN p1
[ "$(NLINES 'p1/o-p1-314 \[conflict-unresolvable\]: WOULD retire — PR is merged — observe mode')" = 1 ] && ok \
  || bad "R4: observe mode says WOULD (log: $(LOG | grep -E 'WOULD|314' | head -3))"
[ "$(NEV)" = 0 ] && ok || bad "R4: observe mode writes no event line"
grep -q '^314	' "$STORE" 2>/dev/null && bad "R4: observe mode adds no store row ($(cat "$STORE"))" || ok

# ============================================================================
# W4 W12 (function) + R2 (function). bcr_is_closed with brd_row_word in step
#   record, and bcr_commit's two line shapes.
# ============================================================================
: > "$T/jobs.txt"
REC 289 merged; REC 400 merged
FN=$( cd "$T" && env HARNESS="$H" H="$H" ST="$T/fn" TMPDIR="$T" GH_SOURCE=record U="$U" T="$T" bash -c '
  say() { :; }
  . "$H/bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh" || exit 1
  . "$H/bin/blocked-resolver.d/bh-10157-record-discovery.sh" 2>/dev/null
  mkdir -p "$ST"; r=""
  declare -A _BCR_CLOSED=() _BCR_OPEN=(["$U/2890"]=1) _BCR_OPENBAD=() _BCR_RET=() _BCR_SLUG=([p1]=o/p1)
  bcr_is_closed "$U/400" rebuild-conflict || r="${r}a"
  bcr_is_closed "-" conflict-unresolvable || r="${r}b"
  bcr_is_closed "https://github.com/other/repo/pull/289" conflict-unresolvable || r="${r}c"
  bcr_is_closed "$U/2890" conflict-unresolvable || r="${r}d"
  bcr_is_closed "$U/400" conflict-unresolvable && [ "$_BCR_WORD" = merged ] && r="${r}e"
  printf "#wm\t2026-11-20T00:00:00Z\n289\tmerged\t2026-11-20T00:00:00Z\t0\n" > "$ST/.closed-prs-p1.tsv"
  BCR_RETIRED_OUT="$T/fn.out"
  printf "%s\n" "$U/289" > "$BCR_RETIRED_OUT"
  printf "%s\tclosed\t2026-11-25T00:00:00Z\n" "$U/300" >> "$BCR_RETIRED_OUT"
  printf "%s\tmerged\t-\n" "$U/299" >> "$BCR_RETIRED_OUT"
  printf "%s\tmerged\t2026-11-25T00:00:00Z\n" "https://github.com/other/repo/pull/301" >> "$BCR_RETIRED_OUT"
  bcr_commit
  grep -qP "^289\tmerged\t2026-11-20T00:00:00Z\t1$" "$ST/.closed-prs-p1.tsv" && r="${r}f"
  grep -qP "^300\tclosed\t2026-11-25T00:00:00Z\t1$" "$ST/.closed-prs-p1.tsv" && r="${r}g"
  grep -q "^299" "$ST/.closed-prs-p1.tsv" || r="${r}h"
  grep -q "^301" "$ST/.closed-prs-p1.tsv" || r="${r}i"
  head -1 "$ST/.closed-prs-p1.tsv" | grep -qP "^#wm\t2026-11-20T00:00:00Z$" && r="${r}j"
  _BCR_RET=(); bcr_note_retired "$U/77" merged 2026-11-24T00:00:00Z
  tail -1 "$BCR_RETIRED_OUT" | grep -qP "^https://github.com/o/p1/pull/77\tmerged\t2026-11-24T00:00:00Z$" && r="${r}k"
  echo "$r"' 2>"$T/fn.err")
[ "$FN" = abcdefghijk ] && ok || bad "W4/W12/R2: rebuild-*, url -, other repo, open #2890, record hit, url-only line, 3-field line, no-time line, other repo line, watermark, note format (got '$FN', want abcdefghijk; err: $(head -3 "$T/fn.err"))"
[ "$(grep -c 'number=' "$T/jobs.txt")" = 1 ] && grep -q 'number=400$' "$T/jobs.txt" && ok \
  || bad "W4/W12: only the record-hit case peeks, once ($(cat "$T/jobs.txt"))"

echo "br-record-retire.bh-10157: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
