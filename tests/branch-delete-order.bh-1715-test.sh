#!/bin/bash
# tests/branch-delete-order.bh-1715-test.sh — BH-1715 item 3: NO CODE PATH
# DELETES A PARENT BRANCH BEFORE EVERY OPEN CHILD HAS BEEN PATCHED OFF IT.
#
# THE INCIDENT (2026-09-23). An API delete of #1659's branch made GitHub CLOSE
# #1664 and #1666 instead of retargeting them: `delete_branch_on_merge` is false
# on these repos, so GitHub never retargets on a delete, it closes. BH-1483 put
# list -> PATCH -> DELETE into bin/lib/gh-pr-merge.sh `_gpm_delete_branch`, but
# three other paths still deleted blind:
#   * bin/lib/gh-shim/pr-write.sh `gshim_prw_delete_branch` (`pr merge|close
#     --delete-branch` through the REST shim): a straight DELETE
#   * bin/merge-sweep.sh and bin/poll-commands.sh handed `--delete-branch` to
#     REAL `gh pr merge` on their no-REST-verdict fallback
#
# WHAT THIS PINS, behaviourally first (D3):
#   B  the shim's `pr merge --delete-branch`: list, PATCH every child to the
#      PR's own base, THEN delete; a refused PATCH, an unreadable list or a full
#      page keeps the branch
#   C  the shim's `pr close --delete-branch`: an unmerged parent with an open
#      child keeps its branch and retargets nothing; no children deletes
#   D  poll-commands' merge_pr fallback (the real handler, extracted by its
#      markers): no `--delete-branch` to gh; on merged the children list comes
#      before the DELETE; on queued nothing is deleted; on GitHub's native
#      queue (the REAL queue reader, which answers `unknown`) an enqueue that
#      gh reports as exit 0 retargets no child and deletes nothing
#   E  merge-sweep's fallback (the real lane): no `--delete-branch` to gh; the
#      DELETE that follows comes after the children list
#   F  the lib, from the invariant's side: every DELETE follows a 200 PATCH for
#      every child the list returned
# and then as an INVENTORY (A): every line under bin/ that can delete a branch
# is one of an allowlist with a reason, and an allowlist entry that matches
# nothing fails too, so a stale allowlist cannot hide a new site.
#
# D1 MUTATIONS, run once before the PR and confirmed red: put `--delete-branch`
# back on poll-commands' gh line (A, D red); swap the shim's PATCH loop and its
# DELETE (B red); let the shim's close path retarget (C red); call
# `_gpm_delete_branch` on a queued result in poll-commands (D red); drop the
# `.merged == true` check from `_gpm_delete_branch` (D3 red); drop
# merge-sweep's children-first delete after its fallback merge (E red).
#
# Run from anywhere: bash tests/branch-delete-order.bh-1715-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
[ -f "$DIR/bin/lib/gh-shim/pr-write.sh" ] || exit 1   # impact: bin/lib/gh-shim/pr-write.sh
[ -f "$DIR/bin/merge-sweep.sh" ] || exit 1            # impact: bin/merge-sweep.sh
[ -f "$DIR/bin/poll-commands.sh" ] || exit 1          # impact: bin/poll-commands.sh
[ -f "$DIR/bin/lib/gh-pr-merge.sh" ] || exit 1        # impact: bin/lib/gh-pr-merge.sh
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV
ORIGPATH="$PATH"

# ============================================================================
# A. The inventory. A branch-delete verb on a code line under bin/:
#      -X DELETE … git/refs/heads      (the REST ref delete)
#      --delete-branch                 (handed to gh, or held in a variable for it)
#      push … --delete                 (git's remote delete)
#      push … :<ref>                   (git's empty-source refspec delete)
# ============================================================================
VERBS='-X DELETE[^#]*git/refs/heads|--delete-branch|push[^#]*[[:space:]]--delete([[:space:]]|$)|push[^#]*[[:space:]]["'"'"']?:[^[:space:]]'
# file | enclosing function (- = top level) | ERE the line must match | why it may delete
ALLOW='bin/lib/gh-pr-merge.sh|_gpm_del_ref|-X DELETE|the ref DELETE itself; its only caller is _gpm_delete_branch, which lists and PATCHes first (asserted below)
bin/lib/gh-shim/pr-write.sh|gshim_prw_delete_branch|-X DELETE|the shim delete; lists and PATCHes first (sections B and C)
bin/lib/gh-shim/pr-write.sh|gshim_cmd_pr_close|--delete-branch:b:delbranch|the flag parser; the flag routes to gshim_prw_delete_branch
bin/lib/gh-shim/pr-write.sh|gshim_cmd_pr_merge|--delete-branch:b:delbranch|the flag parser; the flag routes to gshim_prw_delete_branch
bin/batch-resolve.sh|delete_train_branch|push .*--delete|a dead TRAIN branch: trains and their members target main, no PR is ever based on one
bin/batch-resolve.sh|reconcile_creating|push .*--delete|an orphan TRAIN branch no PR was ever opened for'
# sites <file> — "<file>|<function>|<line>" for every code line with a verb.
sites() {
  awk -v f="${1#"$DIR"/}" -v re="$VERBS" '
    /^[[:space:]]*#/ { next }
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
      fn = $0; sub(/^[[:space:]]*/, "", fn); sub(/[[:space:]]*\(.*/, "", fn) }
    /^}/ { fn = "-"; next }
    $0 ~ re { print f "|" (fn == "" ? "-" : fn) "|" $0 }
  ' "$1"
}
SITES=$(grep -rlIE -- "$VERBS" "$DIR/bin" 2>/dev/null | sort | while IFS= read -r f; do sites "$f"; done)
[ -n "$SITES" ] && ok || bad "A: the inventory found no delete site at all — the scan is broken"
UNLISTED=""; declare -A USED=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  sf="${s%%|*}"; rest="${s#*|}"; sfn="${rest%%|*}"; sline="${rest#*|}"; hit=""
  while IFS='|' read -r af afn are _; do
    [ "$sf" = "$af" ] && [ "$sfn" = "$afn" ] && grep -qE -- "$are" <<<"$sline" && { hit="$af|$afn|$are"; break; }
  done <<<"$ALLOW"
  if [ -n "$hit" ]; then USED["$hit"]=1
  else UNLISTED="$UNLISTED
  $sf ($sfn): $(sed 's/^[[:space:]]*//' <<<"$sline")"; fi
done <<<"$SITES"
[ -z "$UNLISTED" ] && ok || bad "A: branch-delete sites that do not list and PATCH children first:$UNLISTED"
while IFS='|' read -r af afn are _; do
  [ -n "${USED["$af|$afn|$are"]:-}" ] && ok || bad "A: the allowlist entry $af ($afn) matches nothing — a stale entry hides nothing and must go"
done <<<"$ALLOW"
# _gpm_del_ref is reached only through _gpm_delete_branch: every code line under
# bin/ that CALLS it, with the function it sits in.
CALLERS=$(grep -rlIw -- '_gpm_del_ref' "$DIR/bin" | sort | while IFS= read -r f; do
  awk -v f="${f#"$DIR"/}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*_gpm_del_ref\(\)/ { fn = "_gpm_del_ref"; next }
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
      fn = $0; sub(/^[[:space:]]*/, "", fn); sub(/[[:space:]]*\(.*/, "", fn) }
    /^}/ { fn = "-"; next }
    /_gpm_del_ref[[:space:]]/ { print f "|" fn }
  ' "$f"; done)
[ "$CALLERS" = "bin/lib/gh-pr-merge.sh|_gpm_delete_branch" ] \
  && ok || bad "A: _gpm_del_ref must have exactly one caller, inside _gpm_delete_branch (got: $CALLERS)"

# ============================================================================
# B / C. The REST shim, driven as `gh` through the real bin/gh-rest-shim.
# ============================================================================
gshim_stub_setup
printf 'https://github.com/o/r\n' >"$T/fixtures/git-origin.txt"
printf '{"number":7,"title":"Fix it","head":{"ref":"feat","repo":{"full_name":"o/r"}},"base":{"ref":"main"},"state":"open"}\n' | gshim_fixture repos_o_r_pulls_7
printf '{"sha":"deadbeef","merged":true,"message":"Pull Request successfully merged"}\n' | gshim_fixture repos_o_r_pulls_7_merge
printf '{}\n' | gshim_fixture repos_o_r_git_refs_heads_feat
printf '{"number":8}\n' | gshim_fixture repos_o_r_pulls_8
printf '{"number":9}\n' | gshim_fixture repos_o_r_pulls_9
# The children list is `repos/o/r/pulls?state=open&base=feat&per_page=100`. The
# stub keys a list by its path and serves `.p<N>.json` for a `page=N` in the
# query, and `per_page=100` reads to it as page 100 — so that is its fixture.
kids() { rm -f "$T/fixtures/repos_o_r_pulls".*; printf '%s\n' "$1" | gshim_fixture repos_o_r_pulls.p100; }
lineno() { gshim_calls | grep -nF -- "$1" | head -1 | cut -d: -f1; }
ndel() { local n; n=$(gshim_calls | grep -c -- '-X DELETE repos/o/r/git/refs/heads/feat'); echo "${n:-0}"; }

# B1. two children: list, PATCH 8, PATCH 9, then DELETE — in that order.
kids '[{"number":8},{"number":9}]'
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
[ "$RC" = 0 ] && ok || bad "B1: the merge must exit 0 (rc $RC, err: $ERR)"
L=$(lineno 'pulls?state=open&base=feat'); P8=$(lineno '-X PATCH repos/o/r/pulls/8'); P9=$(lineno '-X PATCH repos/o/r/pulls/9')
D=$(lineno '-X DELETE repos/o/r/git/refs/heads/feat'); M=$(lineno 'pulls/7/merge')
{ [ -n "$M" ] && [ -n "$L" ] && [ -n "$P8" ] && [ -n "$P9" ] && [ -n "$D" ] \
  && [ "$M" -lt "$L" ] && [ "$L" -lt "$P8" ] && [ "$P8" -lt "$D" ] && [ "$P9" -lt "$D" ]; } \
  && ok || bad "B1: the order must be merge, list, PATCH each child, DELETE (merge=$M list=$L p8=$P8 p9=$P9 del=$D): $(gshim_calls)"
gshim_calls | grep -qF 'query=state=open&base=feat&per_page=100' \
  && ok || bad "B1: the list must ask for the open PRs based on this head ref: $(gshim_calls | grep 'pulls?')"
gshim_calls | grep -F -- '-X PATCH repos/o/r/pulls/8' | grep -q 'base=main' \
  && ok || bad "B1: each child is retargeted to the PR's own base, main: $(gshim_calls | grep PATCH)"
# B2. the second PATCH is refused: nothing is deleted, the merge still exits 0.
printf 'HTTP 422: Validation Failed\n' | gshim_fixture repos_o_r_pulls_9 1
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
[ "$RC" = 0 ] && ok || bad "B2: a refused retarget must not fail a merge that landed (rc $RC)"
[ "$(ndel)" = 0 ] && ok || bad "B2: a refused PATCH must keep the branch: $(gshim_calls)"
rm -f "$T/fixtures/repos_o_r_pulls_9.rc" "$T/fixtures/repos_o_r_pulls_9.err"
# B3. the list does not read, or reads as a full page: nothing is deleted.
rm -f "$T/fixtures/repos_o_r_pulls".*; printf 'HTTP 502: Bad Gateway\n' | gshim_fixture repos_o_r_pulls 1
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
{ [ "$RC" = 0 ] && [ "$(ndel)" = 0 ]; } && ok || bad "B3: an unreadable list must keep the branch (rc $RC): $(gshim_calls)"
kids "$(jq -cn '[range(100)|{number:(100+.)}]')"
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
{ [ "$RC" = 0 ] && [ "$(ndel)" = 0 ]; } && ok || bad "B3: a full page of 100 must keep the branch (rc $RC)"
kids '{"message":"not a list"}'
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
{ [ "$RC" = 0 ] && [ "$(ndel)" = 0 ]; } && ok || bad "B3: a body that is not an array must keep the branch (rc $RC)"
# B4. no children: the DELETE runs as before.
kids '[]'
gshim_reset; gshim_run pr merge 7 -R o/r --squash --delete-branch
{ [ "$RC" = 0 ] && [ "$(ndel)" = 1 ]; } && ok || bad "B4: no children deletes the branch once (rc $RC): $(gshim_calls)"

# C1. close (NOT merged) with an open child: no retarget, no delete, exit 0.
kids '[{"number":8}]'
gshim_reset; gshim_run pr close 7 -R o/r --delete-branch
[ "$RC" = 0 ] && ok || bad "C1: the close must exit 0 (rc $RC, err: $ERR)"
grep -q -- '-X PATCH repos/o/r/pulls/8' <<<"$(gshim_calls)" && bad "C1: an unmerged parent's child must not be retargeted: $(gshim_calls)" || ok
[ "$(ndel)" = 0 ] && ok || bad "C1: a branch an open PR is based on must be kept: $(gshim_calls)"
[ -n "$(lineno 'pulls?state=open&base=feat')" ] && ok || bad "C1: the close must list the children before deciding"
# C1b. close with a list that does not read: kept, and the close says so (rc 1).
rm -f "$T/fixtures/repos_o_r_pulls".*; printf 'HTTP 502: Bad Gateway\n' | gshim_fixture repos_o_r_pulls 1
gshim_reset; gshim_run pr close 7 -R o/r --delete-branch
{ [ "$RC" = 1 ] && [ "$(ndel)" = 0 ]; } && ok || bad "C1b: an unproven list on a close keeps the branch and exits 1 (rc $RC): $(gshim_calls)"
# C2. close with no children deletes as before, after the close PATCH.
kids '[]'
gshim_reset; gshim_run pr close 7 -R o/r --delete-branch
{ [ "$RC" = 0 ] && [ "$(ndel)" = 1 ]; } && ok || bad "C2: a close with no children deletes the branch (rc $RC): $(gshim_calls)"
{ [ -n "$(lineno '-X PATCH repos/o/r/pulls/7')" ] && [ "$(lineno '-X PATCH repos/o/r/pulls/7')" -lt "$(lineno 'git/refs/heads/feat')" ]; } \
  && ok || bad "C2: the delete comes after the close"
export PATH="$ORIGPATH"; unset HARNESS

# ============================================================================
# D. poll-commands' merge_pr handler, extracted by its markers, on the
#    no-REST-verdict fallback.
# ============================================================================
SLUG="example-org/project-4"; PR1598="https://github.com/example-org/project-4/pull/1598"
PD="$T/pc"; mkdir -p "$PD/h/bin/lib" "$PD/h/logs" "$PD/h/flags" "$PD/h/env" "$PD/bin"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do cp "$DIR/bin/lib/$L" "$PD/h/bin/lib/" || exit 1; done
cat > "$PD/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo project-4; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$PD/h/bin/fleet-conf.sh"
cat > "$PD/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
case "$*" in *"pr merge"*) printf '%s\n' "$*" >> "$CASE/pr-merge.log"; exit 0 ;; esac
case "$1 $2" in "api -i") ;; *) exit 1 ;; esac
KIND=get
case "$*" in *"/pulls?state=open&base="*) KIND=children ;; esac
for a in "$@"; do case "$a" in PUT) KIND=put ;; DELETE) KIND=del ;; PATCH) KIND=patch ;; esac; done
[ -f "$CASE/$KIND" ] && { cat "$CASE/$KIND"; exit 0; }
exit 1
STUB
chmod +x "$PD/bin/gh"; printf '#!/bin/bash\nexit 0\n' > "$PD/bin/sleep"; chmod +x "$PD/bin/sleep"
awk '/^    # >>> merge_pr handler/{f=1; next} /^    # <<< merge_pr handler/{exit} f{print}' "$DIR/bin/poll-commands.sh" \
  | sed -e '1s/^    merge_pr)//' -e '$s/ ;;$//' > "$PD/merge_pr.body"
[ -s "$PD/merge_pr.body" ] && ok || { echo "FAIL: D: could not extract the merge_pr handler"; exit 1; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
pc_case() { # pc_case <name> <queue-provider> [merged: true|false] [queue reader: stub|real]
  CASE="$PD/case-$1"; export CASE; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"
  scratch_rm "$PD/h/state/stack-follow"
  resp put '403 Forbidden' '{"message":"API rate limit already exceeded for user ID 2220366"}'
  resp get '200 OK' "{\"merged\":${3:-true},\"head\":{\"ref\":\"ticket/project-4-1598\",\"sha\":\"abc\",\"repo\":{\"full_name\":\"example-org/project-4\"}},\"base\":{\"ref\":\"main\"}}"
  resp children '200 OK' '[{"number":1600}]'
  resp patch '200 OK' '{"number":1600}'
  resp del '204 No Content' ''
  PC_OUT=$(PATH="$PD/bin:$ORIGPATH" HARNESS="$PD/h" ID=1 PROJECT=project-4 QPROV="$2" QREAD="${4:-stub}" DIR="$DIR" \
    PAYLOAD="{\"pr_url\":\"$PR1598\",\"sha\":\"abc\"}" bash -c '
      set -uo pipefail; OK=false; RESULT=""
      if [ "$QREAD" = real ]; then
        # The REAL queue reader (bin/lib/mc/queue.sh mc_queue_state), fed the
        # one read it makes: the PR is OPEN, which is what an enqueue on
        # GitHub'"'"'s native queue looks like over REST.
        MC_H="$HARNESS"
        . "$DIR/bin/lib/mc/classify.sh" || exit 1; . "$DIR/bin/lib/mc/queue.sh" || exit 1
        mc_pr_view() { printf "OPEN abc \n"; }
      else
        mc_pr_queued() { [ "${QPROV:-none}" = mergify ]; }
        # BH-2199: a Mergify repo is ENQUEUED by the handler (label + @mergifyio
        # queue through the conductor lib), never merged over REST. On a real
        # box bin/poll-commands.sh sources that lib; this harness stands in for
        # its two edges: the live head, and a queue that acknowledges the ask.
        mc_pr_view() { printf abc; }
        mc_enqueue_mergify() { printf "%s\n" "$*" >> "$CASE/enqueue.log"; return 0; }
      fi
      mc_queue_provider() { printf %s "${QPROV:-none}"; }
      [ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
      . "$0"
      printf "OK=%s\nRESULT=%s\n" "$OK" "$RESULT"' "$PD/merge_pr.body")
}
pline() { grep -n -- "$1" "$CASE/gh-calls.log" | head -1 | cut -d: -f1; }
# D1. REST rate-limited -> gh pr merge fallback -> merged.
pc_case merged none
grep -q -- '--delete-branch' "$CASE/pr-merge.log" 2>/dev/null \
  && bad "D1: the fallback must not hand --delete-branch to gh: $(cat "$CASE/pr-merge.log")" || ok
[ -s "$CASE/pr-merge.log" ] && ok || bad "D1: the fallback must still run gh pr merge"
grep -q '^RESULT=merged ' <<<"$PC_OUT" && ok || bad "D1: the ack must still read merged (got: $PC_OUT)"
L=$(pline '/pulls?state=open&base='); P=$(pline '-X PATCH repos/example-org/project-4/pulls/1600'); D=$(pline '-X DELETE')
{ [ -n "$L" ] && [ -n "$P" ] && [ -n "$D" ] && [ "$L" -lt "$P" ] && [ "$P" -lt "$D" ]; } \
  && ok || bad "D1: on merged the branch goes list -> PATCH -> DELETE (list=$L patch=$P del=$D): $(cat "$CASE/gh-calls.log")"
# D2. a queue that answers "queued" (Mergify's labels): nothing is deleted.
pc_case queued mergify false
grep -q '^RESULT=queued ' <<<"$PC_OUT" && ok || bad "D2: a queued PR acks queued (got: $PC_OUT)"
grep -q -- '-X DELETE' "$CASE/gh-calls.log" && bad "D2: a queued PR's branch must not be deleted: $(cat "$CASE/gh-calls.log")" || ok
grep -q -- '--delete-branch' "$CASE/pr-merge.log" 2>/dev/null && bad "D2: no --delete-branch on an enqueue" || ok
[ "$(grep -c . "$CASE/enqueue.log" 2>/dev/null)" = 1 ] && ok || bad "D2: the queued PR was asked of the queue exactly once (got: $(cat "$CASE/enqueue.log" 2>/dev/null))"
grep -q -- '-X PUT' "$CASE/gh-calls.log" && bad "D2: a Mergify repo is never merged over REST: $(cat "$CASE/gh-calls.log")" || ok
# D3. GitHub's NATIVE queue, through the real queue reader: it cannot see the
#     queue and answers `unknown`, so poll-commands takes the not-queued arm.
#     gh exited 0 on an ENQUEUE and the PR is still open (merged:false): no
#     child may be retargeted, no restack owed, and the head ref not deleted
#     (deleting it drops the PR out of the queue).
pc_case native-queue github false real
grep -q -- '-X PATCH' "$CASE/gh-calls.log" && bad "D3: an enqueued PR's children must not be retargeted: $(cat "$CASE/gh-calls.log")" || ok
grep -q -- '-X DELETE' "$CASE/gh-calls.log" && bad "D3: an enqueued PR's branch must not be deleted: $(cat "$CASE/gh-calls.log")" || ok
[ -e "$PD/h/state/stack-follow" ] && [ -n "$(ls -A "$PD/h/state/stack-follow" 2>/dev/null)" ] \
  && bad "D3: an enqueue must not record an owed restack: $(ls "$PD/h/state/stack-follow")" || ok
grep -q -- '--delete-branch' "$CASE/pr-merge.log" 2>/dev/null && bad "D3: no --delete-branch on an enqueue" || ok

# ============================================================================
# E. merge-sweep, the whole lane, on its no-REST-verdict fallback
#    (PR_MERGE_REST=0: the ladder answers rc 2 and the gh line runs).
# ============================================================================
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
S="$T/sw"; mkdir -p "$S/bin/lib/jobs" "$S/bin/lib/mc" "$S/logs" "$S/state" "$S/flags" "$S/locks" "$S/env" "$S/tmp" "$S/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$S/bin/sweep.sh"
mkdir -p "$S/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$S/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$S/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$S/bin/lib/jobs/"; cp "$DIR"/bin/lib/mc/*.sh "$S/bin/lib/mc/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" "$S/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$S/fakebin/restpr"; chmod +x "$S/fakebin/restpr"
printf 'p o/plain - - 3 box-p\n' > "$S/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do printf '#!/bin/bash\nexit 0\n' > "$S/bin/$s"; chmod +x "$S/bin/$s"; done
cat > "$S/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$S/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/o/plain/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  "api repos/o/plain -q .id") echo 1 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$S/merge-calls.txt"; touch "$S/merged"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i repos/o/plain/pulls?state=open&base="*) restpr --raw 200 '[{"number":9}]' ;;
  *"-X PATCH repos/o/plain/pulls/9"*) restpr --raw 200 '{"number":9}' ;;
  *"-X DELETE repos/o/plain/git/refs/heads/"*) restpr --raw 204 '' ;;
  *"api -i repos/o/plain/pulls/8"*)
    restpr --raw 200 '{"number":8,"merged":true,"head":{"ref":"ticket/x","sha":"headsha","repo":{"full_name":"o/plain"}},"base":{"ref":"main"}}' ;;
  *"api -i repos/o/plain"*) restpr --raw 200 '{"full_name":"o/plain","allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false}' ;;
  *"api -i -X GET repos/o/plain/pulls/8"*)
    if [ -f "$S/merged" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$S/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$S/fakebin/curl"; chmod +x "$S/fakebin/curl"
B="$S/builds/pool-p-XX-8-202609120001"; mkdir -p "$B"
echo "PR_CREATED https://github.com/o/plain/pull/8" > "$B/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$B/review.md"; : > "$B/pipeline.log"
: > "$S/state/merge-sweep-done.txt"; : > "$S/merge-calls.txt"; : > "$S/gh-calls.txt"
( cd "$S" && PATH="$S/fakebin:$ORIGPATH" HARNESS="$S" FLEET_CONF="$S/fleet.conf" PR_MERGE_REST=0 \
  SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 bash "$S/bin/sweep.sh" >/dev/null 2>"$S/sweep.err" ) \
  || { echo "E: sweep rc=$? stderr:"; tail -5 "$S/sweep.err"; }
[ -s "$S/merge-calls.txt" ] && ok || bad "E: the sweep must reach its gh pr merge fallback (log: $(tail -3 "$S/logs/merge-sweep.log" 2>/dev/null))"
grep -q -- '--delete-branch' "$S/merge-calls.txt" \
  && bad "E: the fallback must not hand --delete-branch to gh: $(cat "$S/merge-calls.txt")" || ok
grep -q 'MERGED https://github.com/o/plain/pull/8' "$S/logs/merge-sweep.log" && ok || bad "E: the merge must still be recorded MERGED"
EL=$(grep -n 'pulls?state=open&base=' "$S/gh-calls.txt" | head -1 | cut -d: -f1)
EP=$(grep -n -- '-X PATCH repos/o/plain/pulls/9' "$S/gh-calls.txt" | head -1 | cut -d: -f1)
ED=$(grep -n -- '-X DELETE repos/o/plain/git/refs/heads/ticket/x' "$S/gh-calls.txt" | head -1 | cut -d: -f1)
{ [ -n "$EL" ] && [ -n "$EP" ] && [ -n "$ED" ] && [ "$EL" -lt "$EP" ] && [ "$EP" -lt "$ED" ]; } \
  && ok || bad "E: after the merge the branch goes list -> PATCH -> DELETE (list=$EL patch=$EP del=$ED): $(grep -E 'pulls\?|PATCH|DELETE' "$S/gh-calls.txt")"

# ============================================================================
# F. The lib, from the invariant's side: every DELETE in the log follows a 200
#    PATCH of every child the list returned.
# ============================================================================
FH="$T/lib"; mkdir -p "$FH/h/bin/lib" "$FH/h/flags" "$FH/h/logs" "$FH/bin"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do cp "$DIR/bin/lib/$L" "$FH/h/bin/lib/" || exit 1; done
cat > "$FH/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
KIND=""
case "$*" in
  *"-X PATCH repos/"*"/pulls/"*) a="$*"; n="${a##*pulls/}"; n="${n%% *}"; KIND="patch-$n" ;;
  *"api -i repos/"*"/pulls?"*) KIND=children ;;
  *"-X DELETE repos/"*"/git/refs/"*) KIND=del ;;
  *"api -i repos/"*"/pulls/"*) KIND=pull ;;
esac
[ -n "$KIND" ] && [ -f "$CASE/$KIND" ] && { cat "$CASE/$KIND"; exit 0; }
exit 1
STUB
chmod +x "$FH/bin/gh"
invariant() { # every DELETE line is preceded by a 200 PATCH of every listed child
  local d kid p
  d=$(grep -n -- '-X DELETE' "$CASE/gh-calls.log" | head -1 | cut -d: -f1)
  [ -n "$d" ] || return 0
  for kid in $1; do
    p=$(grep -n -- "-X PATCH repos/o/r/pulls/$kid " "$CASE/gh-calls.log" | head -1 | cut -d: -f1)
    [ -n "$p" ] && [ "$p" -lt "$d" ] && [ "$(head -n 1 "$CASE/patch-$kid" | cut -d' ' -f2)" = 200 ] || return 1
  done
}
lib_case() { # lib_case <name> <patch-code-for-12>
  CASE="$FH/case-$1"; export CASE; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"
  resp pull '200 OK' '{"number":10,"merged":true,"head":{"ref":"ticket/a","sha":"aaa","repo":{"full_name":"o/r"}},"base":{"ref":"main"}}'
  resp children '200 OK' '[{"number":11},{"number":12}]'
  resp patch-11 '200 OK' '{"number":11}'
  resp patch-12 "$2" '{"number":12}'
  resp del '204 No Content' ''
  ( PATH="$FH/bin:$ORIGPATH" HARNESS="$FH/h"; . "$FH/h/bin/lib/gh-pr-merge.sh"
    _gpm_delete_branch o/r 10 "" "$CASE/plog" "bh-1715" ) >/dev/null 2>&1
}
lib_case both '200 OK'
grep -q -- '-X DELETE' "$CASE/gh-calls.log" && ok || bad "F: two retargeted children delete the branch: $(cat "$CASE/gh-calls.log")"
invariant "11 12" && ok || bad "F: the DELETE must follow a 200 PATCH of #11 and #12: $(cat "$CASE/gh-calls.log")"
lib_case refused '422 Unprocessable Entity'
grep -q -- '-X DELETE' "$CASE/gh-calls.log" && bad "F: a refused PATCH of #12 must keep the branch: $(cat "$CASE/gh-calls.log")" || ok
invariant "11 12" && ok || bad "F: the invariant must hold with a refused child"

echo "branch-delete-order.bh-1715-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
