#!/bin/bash
# tests/issue-reads-rest.bh-1641-test.sh — BH-1651 (BH-1641.3): the single-site
# issue readers and writers read GitHub over REST (bin/lib/gh-rest*.sh), and a
# read that did not answer (403 here) is never acted on as a state.
#
# One section per converted site. Each drives the real script (or, where the
# script is an onboarding/ssh lane, its exact production function/block) against
# a PATH `gh` that logs argv to a sink and answers `gh api -i` in the REST wire
# shape. Every section also asserts the sink holds no `gh issue view|list|
# comment|close|edit` call at all. review-rescue's and hotfix-after-deploy's
# REST behavior is driven through their real entry points in
# tests/review-rescue-test.sh (8, 8b) and tests/hotfix-after-deploy-test.sh (5i-5k).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# gh-rest-etag.sh caches 2xx bodies under $HARNESS/state/gh-etag and defaults
# HARNESS to /root/harness; sections that do not name their own HARNESS must
# never write that live tree.
export HARNESS="$T/h"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "issue-reads-rest: jq is required"; exit 1; }

# The fake gh. Fixtures, all under $T/gh:
#   st        HTTP status for every `api -i` read (default 200)
#   state     the issue's state for GET repos/o/r/issues/<n> (default open)
#   body      the issue's body for that same read
#   list.json the raw REST array for GET repos/o/r/issues (the list route)
mkdir -p "$T/fb" "$T/gh"
SINK="$T/gh/sink"
cat > "$T/fb/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$SINK"
# BH-8962: a create is a REST POST now; the adapter routes it through the
# issue create arm below, so the "must not create" checks still see it.
. "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1
gh_cli_rest_create "\$0" "\$@" && exit 0
G="$T/gh"
case "\$*" in
  "api -i -X GET repos/"*"/issues/"[0-9]*)
    st=\$(cat "\$G/st" 2>/dev/null || echo 200)
    printf 'HTTP/2 %s\r\n\r\n' "\$st"
    jq -nc --arg s "\$(cat "\$G/state" 2>/dev/null || echo open)" --rawfile b <(cat "\$G/body" 2>/dev/null) '{state:\$s, body:\$b}' ;;
  "api -i -X GET repos/"*"/issues"*)
    st=\$(cat "\$G/st" 2>/dev/null || echo 200)
    printf 'HTTP/2 %s\r\n\r\n' "\$st"
    case "\$st" in 2*) cat "\$G/list.json" 2>/dev/null || echo '[]' ;; *) echo '{"message":"Forbidden"}' ;; esac ;;
  "issue create"*) echo "https://github.com/o/r/issues/77" ;;
esac
exit 0
SH
chmod +x "$T/fb/gh"
export PATH="$T/fb:$PATH"
reset() { : > "$SINK"; rm -f "$T/gh/st" "$T/gh/state" "$T/gh/body" "$T/gh/list.json"; }
no_cli() { # no_cli <section>
  grep -qE 'issue (view|list|comment|close|edit)' "$SINK" \
    && bad "$1: a GraphQL issue CLI call is still made: $(grep -E 'issue (view|list|comment|close|edit)' "$SINK" | head -1)" || ok
}
fn_of() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"; }
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ══ T3.1 revdep_issue_state ══════════════════════════════════════════════════
rd() { ( unset GH_REST_LIB GH_REST_VAR_LIB; HARNESS="$T/none"; . "$DIR/bin/lib/revdep-lib.sh"; revdep_issue_state o/r 12 ); }
reset; echo closed > "$T/gh/state"
OUT=$(rd); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = CLOSED ] && ok || bad "revdep: REST closed must read CLOSED rc 0 (got '$OUT' rc $RC)"
grep -q '^api -i -X GET repos/o/r/issues/12' "$SINK" && ok || bad "revdep: the state read must be REST: $(cat "$SINK")"
reset; OUT=$(rd); [ "$OUT" = OPEN ] && ok || bad "revdep: REST open must read OPEN (got '$OUT')"
reset; echo 403 > "$T/gh/st"
OUT=$(rd); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "revdep: a 403 must be rc 1 and print nothing (got '$OUT' rc $RC)"
reset; echo merged-ish > "$T/gh/state"
OUT=$(rd); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "revdep: an unknown state must be rc 1, never a wake (got '$OUT' rc $RC)"
no_cli revdep

# ══ T3.2 wake-loop closed_diff ═══════════════════════════════════════════════
CD=$(fn_of "$DIR/bin/wake-loop.sh" closed_diff)
[ -n "$CD" ] && ok || bad "wake-loop: closed_diff() not found in bin/wake-loop.sh"
cdiff() { ( unset GH_REST_LIB GH_REST_VAR_LIB GH_REST_LIST_LIB; . "$DIR/bin/lib/gh-rest-list.sh"; RD_ON=0 PUSH_WINDOW=600; eval "$CD"; closed_diff o/r ); }
reset
jq -nc --arg now "$NOW_ISO" '[{number:331,closed_at:$now},{number:5,closed_at:"2020-01-01T00:00:00Z"},{number:9,closed_at:$now,pull_request:{}}]' > "$T/gh/list.json"
OUT=$(cdiff)
[ "$OUT" = 'board issues: CHANGED 331 "" (state: open -> closed)' ] && ok \
  || bad "wake-loop: only the in-window closed issue must print CHANGED (got: $OUT)"
grep -q 'api -i -X GET repos/o/r/issues' "$SINK" && grep -q 'state=closed' "$SINK" && grep -q 'labels=ai-build' "$SINK" \
  && ok || bad "wake-loop: the list must be the REST closed ai-build list: $(cat "$SINK")"
no_cli wake-loop
reset; echo 403 > "$T/gh/st"
OUT=$(cdiff); [ -z "$OUT" ] && ok || bad "wake-loop: a 403 must print nothing (got: $OUT)"

# ══ T3.4 planned-files-cheap ═════════════════════════════════════════════════
P="$T/pf"; mkdir -p "$P/bin/lib" "$P/logs" "$P/plans" "$P/catalog" "$P/prompts" "$P/repos/proj/src/lib"
cp "$DIR/bin/planned-files-cheap.sh" "$DIR/bin/fleet-conf.sh" "$P/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$P/bin/lib/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$P/bin/lib/"
cp "$DIR/catalog/model-prices.json" "$P/catalog/"
printf 'proj  o/r   -                 -           0 local -\n' > "$P/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$P/prompts/proj.md"
: > "$P/repos/proj/src/lib/a.ts"
printf 'exit 1\n' > "$P/bin/agent-call.sh"; chmod +x "$P/bin/agent-call.sh"
pf() { HARNESS="$P" FLEET_CONF="$P/fleet.conf" REPOS_ROOT="$P/repos" "$P/bin/planned-files-cheap.sh" proj "$1" >/dev/null 2>&1; }
reset; : > "$P/logs/preplan.log"
printf '## Scope\nTouch `src/lib/a.ts`.\n' > "$T/gh/body"
pf AB-12
grep -qx 'src/lib/a.ts' "$P/plans/proj-AB-12/planned-files.txt" 2>/dev/null && ok \
  || bad "planned-files: the REST body must yield the list ($(cat "$P/logs/preplan.log"))"
grep -q '^api -i -X GET repos/o/r/issues/12' "$SINK" && ok || bad "planned-files: the body read must be REST: $(cat "$SINK")"
no_cli planned-files
reset; : > "$P/logs/preplan.log"; echo 403 > "$T/gh/st"
printf '## Scope\nTouch `src/lib/a.ts`.\n' > "$T/gh/body"
pf AB-13
[ -e "$P/plans/proj-AB-13/planned-files.txt" ] && bad "planned-files: a 403 must write nothing" || ok
grep -q 'could not read ticket #13 (HTTP 403)' "$P/logs/preplan.log" && ok \
  || bad "planned-files: a 403 must say 'could not read' with its status ($(cat "$P/logs/preplan.log"))"
grep -q 'empty ticket body' "$P/logs/preplan.log" && bad "planned-files: a 403 is not an empty body" || ok

# ══ T3.6 load-project dedupe blocks ══════════════════════════════════════════
blk() { awk -v m="$1" '$0 ~ "^[[:space:]]*# >>> " m "$" {f=1; next} $0 ~ "^[[:space:]]*# <<< " m "$" {f=0} f' "$DIR/bin/load-project.sh"; }
LPD="$T/lp"; mkdir -p "$LPD/docs"; cp "$DIR/docs/VMAP-BACKFILL-TICKET.md" "$DIR/docs/ARCH-AUDIT-TICKET.md" "$LPD/docs/"
VTITLE="verification map: explore the app and draft docs/verification-map/"
ATITLE="agent architecture: audit the repo and draft AGENT_ARCHITECTURE.md"
for M in "vmap-ticket dedup|$VTITLE" "arch-ticket dedup|$ATITLE"; do
  MK="${M%%|*}"; TI="${M#*|}"; B=$(blk "$MK")
  [ -n "$B" ] && ok || { bad "load-project: block '$MK' not found"; continue; }
  lp() { ( set -euo pipefail; unset GH_REST_LIB GH_REST_VAR_LIB GH_REST_LIST_LIB; . "$DIR/bin/lib/gh-rest-list.sh"; . "$DIR/bin/lib/tracker/gh-issue-create.sh"; cd "$LPD"
           PROJECT=probe SLUG=o/r VTITLE="$VTITLE" ATITLE="$ATITLE"; eval "$B" ) 2>&1; }
  reset; jq -nc --arg t "$TI" '[{title:"other"},{title:$t}]' > "$T/gh/list.json"
  OUT=$(lp)
  grep -q 'already exists' <<<"$OUT" && ok || bad "load-project/$MK: a present title must skip (got: $OUT)"
  grep -q 'issue create' "$SINK" && bad "load-project/$MK: a present title must not create" || ok
  grep -q 'api -i -X GET repos/o/r/issues' "$SINK" && grep -q 'state=all' "$SINK" && ok || bad "load-project/$MK: the list must be REST state=all"
  no_cli "load-project/$MK"
  reset; echo 403 > "$T/gh/st"
  OUT=$(lp)
  grep -q '^WARN: could not list issues on o/r' <<<"$OUT" && ok || bad "load-project/$MK: a 403 must WARN (got: $OUT)"
  grep -q 'issue create' "$SINK" && bad "load-project/$MK: a 403 must never create" || ok
done

# ══ T3.7 up10_here dedupe ════════════════════════════════════════════════════
UH=$(fn_of "$DIR/bin/up10-lane.sh" up10_here)
[ -n "$UH" ] && ok || bad "up10: up10_here() not found"
U="$T/up"; mkdir -p "$U/bin" "$U/logs"
printf '#!/bin/bash\necho o/r\n' > "$U/bin/fleet-conf.sh"; printf '#!/bin/bash\nexit 0\n' > "$U/bin/run-build.sh"; chmod +x "$U/bin/"*.sh
up() { ( unset GH_REST_LIB GH_REST_VAR_LIB GH_REST_LIST_LIB; . "$DIR/bin/lib/gh-rest-list.sh"; . "$DIR/bin/lib/tracker/gh-issue-create.sh"
         HARNESS="$U" PROJECT=cromford SLUG=demo BRIEF="$T/brief" LOG="$U/logs/up10.log" LOCAL=box
         die() { echo "DIE: $*"; exit 2; }; STAMP() { date -u +%FT%TZ; }; setsid() { :; }
         eval "$UH"; up10_here ) 2>&1; }
echo brief > "$T/brief"
reset; echo '[{"number":41,"title":"up10: demo"},{"number":40,"title":"up10: demo-other"}]' > "$T/gh/list.json"
OUT=$(up)
grep -q 'issue create' "$SINK" && bad "up10: an open present title must not create (got: $OUT)" || ok
grep -q 'launched BH-41' "$U/logs/up10.log" && ok || bad "up10: must reuse #41 (log: $(cat "$U/logs/up10.log"); out: $OUT)"
grep -q -- '--search' "$SINK" && bad "up10: the Search API must not be used" || ok
grep -q 'api -i -X GET repos/o/r/issues' "$SINK" && grep -q 'state=open' "$SINK" && grep -q 'labels=ai-build' "$SINK" \
  && ok || bad "up10: the dedupe must be the REST open ai-build list: $(cat "$SINK")"
no_cli up10
reset; echo 403 > "$T/gh/st"
OUT=$(up); RC=$?
[ "$RC" = 2 ] && grep -q 'DIE: gh issue list failed' <<<"$OUT" && ok || bad "up10: a 403 must die (rc $RC: $OUT)"
grep -q 'issue create' "$SINK" && bad "up10: a 403 must never create" || ok

# ══ T3.8 bootstrap probe ═════════════════════════════════════════════════════
BS=$(awk '/board: GitHub Issues \(no app API base\)/ {f=1; next} f && /^fi$/ {exit} f' "$DIR/bin/bootstrap-machine.sh")
[ -n "$BS" ] && ok || bad "bootstrap: the GitHub-Issues probe block not found"
reset
OUT=$( ( unset GH_REST_LIB GH_REST_VAR_LIB; HERE="$DIR/bin" REPO_SLUG=o/r; eval "$BS" ) 2>&1)
grep -q '^api -i -X GET repos/o/r/issues' "$SINK" && ok || bad "bootstrap: the probe must be REST: $(cat "$SINK")"
grep -q 'gh issue access OK' <<<"$OUT" && ok || bad "bootstrap: a 2xx probe must print OK (got: $OUT)"
no_cli bootstrap
reset; echo 403 > "$T/gh/st"
OUT=$( ( unset GH_REST_LIB GH_REST_VAR_LIB; HERE="$DIR/bin" REPO_SLUG=o/r; eval "$BS" ) 2>&1)
grep -q 'gh issue access OK' <<<"$OUT" && bad "bootstrap: a 403 must not print OK" || ok

echo "issue-reads-rest.bh-1641-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
