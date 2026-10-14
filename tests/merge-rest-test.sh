#!/bin/bash
# tests/merge-rest-test.sh — MERGING IS A REST CALL, NOT A GRAPHQL MUTATION.
#
# THE DEFECT (BH-892, 2026-09-18). Every merge write in this harness was
# `gh pr merge`, which is GraphQL under the hood. On 2026-09-18 the PAT's
# GraphQL bucket was empty:
#   GraphQL: API rate limit already exceeded for user ID 2220366
# Console commands 15934 (project-4 #1598) and 15937 (#1599) dead-lettered with
# `merge failed: GraphQL: API rate limit …` while
# `PUT /repos/example-org/project-4/pulls/1598/merge` with merge_method=squash landed
# the same PRs at once. The sweep parked "merge FAILED despite CLEAN", the
# conductor spent a strike, and the merge queue re-offered the entry — all on a
# budget that had nothing to do with whether the PR could merge.
#
# WHAT THIS SUITE PINS. bin/lib/gh-pr-merge.sh sends one PUT per identity rung —
# current identity, then the default PAT, then the admin PAT — carrying the
# REVIEWED SHA so a head that moved is refused by GitHub (409) rather than
# merged blind; a rate limit CLIMBS, a 405/409/422 STOPS the ladder dead (a
# second identity must never re-try a merge GitHub already refused), and the
# kill flag puts the machine back on today's `gh pr merge` byte for byte.
#
# Blocks 7, 8 and 9 drive the PRODUCTION call sites — bin/merge-sweep.sh and
# bin/merge-queue.sh copied standalone into a scratch tree, the train landing
# block extracted verbatim, and mc_merge sourced from the real
# bin/lib/merge-conductor-lib.sh — so deleting a call site fails this suite (D2).
# Block 10 is the lib-absent fallback: on a box whose harness sync has not landed
# the lib, every lane issues today's `gh pr merge` line, unchanged.
#
# Assertions are on artifacts: the rc, stdout, the lane's own log, and the stub
# gh's call log. No network, no real token, no clock, no real sleep.
# Run from anywhere: bash tests/merge-rest-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the REST ladder"; exit 1; }
# A real credential in the runner's environment must never reach a fixture, a
# rung or an assertion message. HARNESS_ENV_DIR goes too: bin/lib/env-path.sh
# honours it FIRST, so a pool box's value would point the admin rung at the live
# env bundle and pull a real token into this suite — and ETC_HARNESS_ENV is
# pointed at a directory that does not exist for the same reason (the resolver's
# third rule is /etc/harness/env, which on a real box holds the real tokens).
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/project-4"
PR1598="https://github.com/example-org/project-4/pull/1598"
PR1599="https://github.com/example-org/project-4/pull/1599"
RSHA="1111bbbb1111"                                 # the sha the review approved
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"     # the merge commit GitHub answers with
RL='API rate limit already exceeded for user ID 2220366'
M405='Base branch was modified. Review and try the merge again.'
M409='Head branch was modified. Review and try the merge again.'

# ── the stub gh ──────────────────────────────────────────────────────────────
# Answers REST calls from per-case fixture files and records every call with the
# WORD for the identity it went out on, never the value. Numbered fixtures
# (put.1, put.2 …) are consumed in sequence, so a ladder that climbs gets a
# different answer without anything here racing a clock.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
W=none
case "${GH_TOKEN:-}" in
  ghp_pat_FIXTURE)     W=pat ;;
  ghp_default_FIXTURE) W=default ;;
  ghp_admin_FIXTURE)   W=admin ;;
  "")                  W=none ;;
  *)                   W=other ;;
esac
printf 'token=%s %s\n' "$W" "$*" >> "$CASE/gh-calls.log"
# The repo-visibility probe bin/merge-sweep.sh runs before anything else.
if [ "${1:-}" = api ] && [ "${4:-}" = .id ]; then echo 12345; exit 0; fi
case "$*" in
  # THE DECISION READS ARE REST (BH-784). The sweep, the queue and the conductor
  # lib read the pull object over `gh api -i -X GET repos/…/pulls/<n>`, and
  # bin/lib/gh-rest.sh judges the HTTP status line, so these arms print a whole
  # response. The pull object is derived from the same per-case files the old
  # --json arms read: state from the `merged` marker, mergeable_state / login /
  # head from prstate, the head from prhead, the merge sha from restsha. The
  # ladder's own ownership read (`api -i repos/…`, no -X) is a different call
  # and still goes to the numbered `get` fixtures below.
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  *"api -i -X GET repos/"*"/pulls/"*"v3.diff"*) printf 'HTTP/1.1 200 OK\r\n\r\n+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  *"api -i -X GET repos/"*"/issues/"*)         printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/project-4/pulls/1598"*)
    read -r _ MS LOGIN HEAD _ < "$CASE/prstate" 2>/dev/null || true
    [ -n "${HEAD:-}" ] || HEAD=$(cat "$CASE/prhead" 2>/dev/null)
    [ -n "${HEAD:-}" ] || HEAD=1111bbbb1111
    if [ -f "$CASE/merged" ]; then ST=closed; MA='"2026-09-18T00:00:00Z"'; else ST=open; MA=null; fi
    RS=$(cat "$CASE/restsha" 2>/dev/null); if [ -n "$RS" ]; then RS="\"$RS\""; else RS=null; fi
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    printf '{"state":"%s","merged_at":%s,"head":{"sha":"%s","ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"%s","user":{"login":"%s","type":"User"},"merge_commit_sha":%s,"body":"harness PR body","draft":false}\n' \
      "$ST" "$MA" "$HEAD" "$(printf '%s' "${MS:-clean}" | tr '[:upper:]' '[:lower:]')" "${LOGIN:-operator}" "$RS"
    exit 0 ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) cat "$CASE/prstate" 2>/dev/null; exit 0 ;;
  *"--json state,mergeable,headRefName"*)              cat "$CASE/prqstate" 2>/dev/null; exit 0 ;;
  *"--json headRefOid"*)                               cat "$CASE/prhead" 2>/dev/null; exit 0 ;;
  *"--json state -q .state"*) [ -f "$CASE/merged" ] && echo MERGED || echo OPEN; exit 0 ;;
  *"--json mergeCommit"*)     cat "$CASE/graphqlsha" 2>/dev/null; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$CASE/pr-merge.log"; touch "$CASE/merged"; exit 0 ;;
  *"issue comment"*|*"issue close"*) exit 0 ;;
esac
case "$1 $2" in
  "api -i") ;;
  *) exit 1 ;;
esac
KIND=get
# The stacked-child list (BH-1483) is its own fixture, never the numbered `get`
# ladder: it is a GET like any other, so without this arm it would be served the
# pull-object fixture and every delete case would fail closed on "not an array".
case "$*" in *"/pulls?state=open&base="*) KIND=children ;; esac
for a in "$@"; do case "$a" in PUT) KIND=put ;; DELETE) KIND=del ;; PATCH) KIND=patch ;; esac; done
N=$(cat "$CASE/$KIND.n" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$CASE/$KIND.n"
for F in "$CASE/$KIND.$W.$N" "$CASE/$KIND.$N" "$CASE/$KIND.$W" "$CASE/$KIND"; do
  [ -f "$F" ] && { cat "$F"; exit 0; }
done
echo "stub gh: no fixture for $KIND (token=$W attempt=$N)" >&2
exit 1
STUB
chmod +x "$T/bin/gh"
# No real sleep anywhere in this suite: the lanes settle for 3-10s after a merge
# and none of that wall time buys an assertion (bin/test-determinism-lint.sh).
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
PATH="$T/bin:$PATH"

# A scratch $HARNESS so the lib's flag and env lookups never touch a live tree.
HARNESS="$T/h"; export HARNESS
mkdir -p "$HARNESS/bin/lib" "$HARNESS/flags" "$HARNESS/logs" "$HARNESS/env" "$T/envdir"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do
  cp "$DIR/bin/lib/$L" "$HARNESS/bin/lib/" 2>/dev/null || {
    echo "FAIL: bin/lib/$L does not exist — the REST merge ladder has not been built"; exit 1; }
done

new_case() { # new_case <name> -> a fresh CASE dir with an empty call log
  CASE="$T/case-$1"; export CASE
  scratch_rm "$CASE"; mkdir -p "$CASE"
  : > "$CASE/gh-calls.log"
}
resp() { # resp <fixture name> <status> <body>
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"
}
# grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would print TWO
# zeroes; a missing file prints nothing at all. Both read as 0 here, and nothing
# else does.
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
ncalls() { countof "$1" "$CASE/gh-calls.log"; }
nputs()  { countof '-X PUT' "$CASE/gh-calls.log"; }
nmerge() { countof . "$CASE/pr-merge.log"; }
merges() { cat "$CASE/pr-merge.log" 2>/dev/null; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
admin_env() { printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"; }
no_admin()  { rm -f "$T/envdir/github-admin.env"; }
# The ladder under test, in a subshell so nothing it sources leaks between
# blocks. stdout line 1 is the lib's own output; the last line is RC=<true rc>.
merge() { # merge <pr-number> <sha> [delete]
  ( . "$HARNESS/bin/lib/gh-pr-merge.sh"
    [ -n "${DEFAULT_TOK:-}" ] && _GHAA_DEFAULT_TOK="$DEFAULT_TOK"
    gh_pr_merge_rest "$SLUG" "$1" "${2:-}" "$CASE/gh-stderr.log" "$CASE/pipeline.log" \
      "merge-rest #$1" "${3:-0}"
    printf '\nRC=%s\n' "$?" )
}
outof() { sed -n '1p' <<<"$1"; }
rcof()  { sed -n 's/^RC=//p' <<<"$1"; }
plog()  { cat "$CASE/pipeline.log" 2>/dev/null; }
# No token VALUE may reach any log or any stdout. The env bundle under $T/envdir
# is the one file that legitimately holds one, and it is not read here.
no_token_leak() { # no_token_leak <label>
  local hit
  hit=$(grep -rlE 'ghp_pat_FIXTURE|ghp_admin_FIXTURE|ghp_default_FIXTURE' "$CASE" 2>/dev/null | tr '\n' ' ')
  [ -z "$hit" ] && ok || bad "$1: a token VALUE reached a log: $hit"
}

# ══ 1. the happy path: ONE PUT, squash, the reviewed sha, rc 0 ═══════════════
new_case happy
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true,\"message\":\"Pull Request successfully merged\"}"
OUT=$(merge 1598 "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 1: a 200 merge must rc 0, got $(rcof "$OUT") — log: $(plog)"
[ "$(outof "$OUT")" = "$MSHA" ] && ok || bad "block 1: stdout must be the merge sha, got '$(outof "$OUT")'"
[ "$(nputs)" = 1 ] && ok || bad "block 1: exactly ONE PUT, got $(nputs): $(calls)"
grep -q -- 'api -i -X PUT repos/example-org/project-4/pulls/1598/merge' "$CASE/gh-calls.log" \
  && ok || bad "block 1: the PUT must go to repos/example-org/project-4/pulls/1598/merge, got: $(calls)"
grep -q -- '-f merge_method=squash' "$CASE/gh-calls.log" \
  && ok || bad "block 1: the PUT must carry merge_method=squash, got: $(calls)"
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "block 1: the PUT must carry the reviewed sha, got: $(calls)"
[ "$(nmerge)" = 0 ] && ok || bad "block 1: a REST merge must issue NO gh pr merge, got: $(merges)"
grep -q 'rung rest: merged example-org/project-4#1598' "$CASE/pipeline.log" \
  && ok || bad "block 1: the log must name the rung and the merge, got: $(plog)"
no_token_leak "block 1"

# ══ 2. HTTP 405 is a NAMED PARK: no retry, no second identity, no GraphQL ════
new_case park-405
admin_env
resp put '405 Method Not Allowed' "{\"message\":\"$M405\",\"documentation_url\":\"https://docs.github.com/rest\"}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; DEFAULT_TOK=ghp_default_FIXTURE; HARNESS_ENV_DIR="$T/envdir"
       export GH_TOKEN HARNESS_ENV_DIR; merge 1598 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 3 ] && ok || bad "block 2: a 405 must rc 3, got $(rcof "$OUT") — log: $(plog)"
grep -qF "$M405" <<<"$(outof "$OUT")" \
  && ok || bad "block 2: GitHub's own message must be on stdout, got '$(outof "$OUT")'"
[ "$(nputs)" = 1 ] \
  && ok || bad "block 2: a refusal must NOT climb to another identity — expected 1 PUT, got $(nputs): $(calls)"
[ "$(nmerge)" = 0 ] && ok || bad "block 2: a refused merge must never fall back to gh pr merge"
grep -q 'HTTP 405' "$CASE/pipeline.log" \
  && ok || bad "block 2: the park must be logged with its real status, got: $(plog)"
no_token_leak "block 2"

# ══ 3. HTTP 409 — the head moved since the sha we bound to ═══════════════════
new_case head-moved
admin_env
resp put '409 Conflict' "{\"message\":\"$M409\"}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1599 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 4 ] && ok || bad "block 3: a 409 must rc 4, got $(rcof "$OUT") — log: $(plog)"
grep -qF "$M409" <<<"$(outof "$OUT")" \
  && ok || bad "block 3: the 409 message must be on stdout, got '$(outof "$OUT")'"
[ "$(nputs)" = 1 ] \
  && ok || bad "block 3: a 409 must stop the ladder dead, got $(nputs) PUTs: $(calls)"
[ "$(nmerge)" = 0 ] && ok || bad "block 3: a 409 must never fall back to gh pr merge"

# ══ 4. a rate-limited identity CLIMBS to the next token rung ═════════════════
new_case climb
admin_env
resp put '403 Forbidden' "{\"message\":\"$RL\"}"
resp put.admin '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1598 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 4: the admin rung must merge, got rc $(rcof "$OUT") — log: $(plog)"
[ "$(outof "$OUT")" = "$MSHA" ] && ok || bad "block 4: the admin rung's sha must be printed, got '$(outof "$OUT")'"
[ "$(nputs)" = 2 ] && ok || bad "block 4: exactly two PUTs (one per rung), got $(nputs): $(calls)"
[ "$(grep -c '^token=admin .*-X PUT' "$CASE/gh-calls.log")" = 1 ] \
  && ok || bad "block 4: the merging PUT must be on the admin identity, got: $(calls)"
{ grep -q 'rung rest:' "$CASE/pipeline.log" && grep -q 'rung rest:admin-pat' "$CASE/pipeline.log"; } \
  && ok || bad "block 4: both rungs must be named by WORD in the log, got: $(plog)"
grep -q 'rate-limited' "$CASE/pipeline.log" \
  && ok || bad "block 4: the climb must WORD the cap it fell through, got: $(plog)"
no_token_leak "block 4"

# ══ 5. every rung rate-limited — NO verdict, the caller owns the fallback ════
new_case all-capped
admin_env
resp put '403 Forbidden' "{\"message\":\"$RL\"}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1598 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 2 ] && ok || bad "block 5: no REST verdict must rc 2, got $(rcof "$OUT") — log: $(plog)"
[ "$(nmerge)" = 0 ] \
  && ok || bad "block 5: the LIB never issues gh pr merge — that is the caller's line"
[ "$(nputs)" = 2 ] && ok || bad "block 5: both rungs must be tried, got $(nputs) PUTs: $(calls)"

# ══ 6. the kill flag: zero REST calls, rc 2, today's behaviour at the caller ══
new_case killflag-env
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$( PR_MERGE_REST=0; export PR_MERGE_REST; merge 1598 "$RSHA" )
[ "$(rcof "$OUT")" = 2 ] && ok || bad "block 6: PR_MERGE_REST=0 must rc 2, got $(rcof "$OUT")"
[ "$(ncalls 'api')" = 0 ] && ok || bad "block 6: the kill flag must make ZERO REST calls, got $(ncalls 'api')"
new_case killflag-file
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
touch "$HARNESS/flags/pr-merge-rest-off"
OUT=$(merge 1598 "$RSHA")
rm -f "$HARNESS/flags/pr-merge-rest-off"
{ [ "$(rcof "$OUT")" = 2 ] && [ "$(ncalls 'api')" = 0 ]; } \
  && ok || bad "block 6: flags/pr-merge-rest-off must stop the ladder before any REST call"

# ══ 6b. a 200 that carries no sha is still a merge, and says so ══════════════
new_case no-sha-200
resp put '200 OK' '{"merged":true,"message":"Pull Request successfully merged"}'
OUT=$(merge 1598 "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 6b: a 200 merged:true with no sha must still rc 0, got $(rcof "$OUT")"
[ -z "$(outof "$OUT")" ] && ok || bad "block 6b: no sha means EMPTY stdout, never a fabricated one, got '$(outof "$OUT")'"
grep -q 'carried no sha' "$CASE/pipeline.log" \
  && ok || bad "block 6b: the log must say the 200 carried no sha, got: $(plog)"
# …and a 200 that does NOT say merged is not a merge.
new_case not-merged-200
resp put '200 OK' '{"merged":false,"message":"Pull Request is not mergeable"}'
OUT=$(merge 1598 "$RSHA")
[ "$(rcof "$OUT")" = 2 ] \
  && ok || bad "block 6b: a 200 without \"merged\":true must never be read as a merge, got rc $(rcof "$OUT")"

# ══ 6c. delete=1 — the branch delete `--delete-branch` used to do ════════════
new_case delete-branch
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '204 No Content' ''
OUT=$(merge 1598 "$RSHA" 1)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 6c: the merge must rc 0, got $(rcof "$OUT")"
[ "$(ncalls 'api -i repos/example-org/project-4/pulls/1598')" = 1 ] \
  && ok || bad "block 6c: exactly one GET for the head ref, got: $(calls)"
grep -q -- '-X DELETE repos/example-org/project-4/git/refs/heads/ticket/project-4-1598' "$CASE/gh-calls.log" \
  && ok || bad "block 6c: the branch DELETE must name the head ref, got: $(calls)"
new_case delete-fails
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '422 Unprocessable Entity' '{"message":"Reference does not exist"}'
OUT=$(merge 1598 "$RSHA" 1)
[ "$(rcof "$OUT")" = 0 ] \
  && ok || bad "block 6c: a failed branch delete must NOT change the merge verdict, got rc $(rcof "$OUT")"
grep -q 'NOT deleted' "$CASE/pipeline.log" \
  && ok || bad "block 6c: a failed delete is one honest log line, got: $(plog)"
# …and a FORK's head is never deleted from the base repo. `refs/heads/main` in
# example-org/project-4 is not the fork branch that merged, and the DELETE here is
# against the base repo — `gh pr merge --delete-branch` skips a cross-repository
# head for exactly this reason.
new_case delete-fork-head
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"main","repo":{"full_name":"someone/project-4-fork"}}}'
resp del '204 No Content' ''
OUT=$(merge 1598 "$RSHA" 1)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 6c: a fork PR still merges, got rc $(rcof "$OUT")"
[ "$(ncalls '-X DELETE')" = 0 ] \
  && ok || bad "block 6c: a fork head must NEVER delete a base-repo branch, got: $(calls)"
grep -q 'its head lives in someone/project-4-fork' "$CASE/pipeline.log" \
  && ok || bad "block 6c: the skipped delete must say whose branch it was, got: $(plog)"
# A head whose repo the answer does not name is not proof of ownership either.
new_case delete-unnamed-head
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598"}}'
resp del '204 No Content' ''
OUT=$(merge 1598 "$RSHA" 1)
{ [ "$(rcof "$OUT")" = 0 ] && [ "$(ncalls '-X DELETE')" = 0 ]; } \
  && ok || bad "block 6c: an unproven head repo must not be deleted, got rc $(rcof "$OUT"): $(calls)"

new_case delete-case-only
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp children '200 OK' '[]'   # BH-1483: nothing is stacked on this head
resp del '204 No Content' ''
OUT=$(merge 1598 "$RSHA" 1)
grep -q -- '-X DELETE repos/example-org/project-4/git/refs/heads/ticket/project-4-1598' "$CASE/gh-calls.log" \
  && ok || bad "block 6c: a head repo that differs from the slug only in case is OURS and must be deleted, got: $(calls)"

# ══ 6d. HTTP 422 is a refusal, not a climb ═══════════════════════════════════
new_case refuse-422
admin_env
resp put '422 Unprocessable Entity' '{"message":"Pull Request is not mergeable"}'
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1598 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 5 ] && ok || bad "block 6d: a 422 must rc 5, got $(rcof "$OUT") — log: $(plog)"
[ "$(nputs)" = 1 ] && ok || bad "block 6d: a 422 must not climb, got $(nputs) PUTs"
grep -q 'not mergeable' <<<"$(outof "$OUT")" \
  && ok || bad "block 6d: GitHub's message must be on stdout, got '$(outof "$OUT")'"

# ══ 6e. an UNBOUND merge (no reviewed sha) sends no sha field and says so ════
new_case unbound
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1598 "")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 6e: an unbound merge must still work, got rc $(rcof "$OUT")"
grep -q -- '-f sha=' "$CASE/gh-calls.log" \
  && bad "block 6e: with no reviewed sha the PUT must carry NO sha field, got: $(calls)" || ok
grep -q 'UNBOUND' "$CASE/pipeline.log" \
  && ok || bad "block 6e: an unbound merge must say so in the log, got: $(plog)"

# ══ 7. THE PRODUCTION SWEEP: bin/merge-sweep.sh merges over REST ═════════════
# The real script, copied standalone into a scratch harness and driven with the
# stub gh — the convention tests/merge-sweep-token-ladder-test.sh uses. This is
# the 2026-09-18 replay: a CLEAN, APPROVEd, head-bound tier-2 PR on project-4.
SW="$T/sw"
sweep_tree() { # sweep_tree <with-lib|no-lib>
  scratch_rm "$SW"
  mkdir -p "$SW/bin/lib" "$SW/logs" "$SW/state" "$SW/flags" "$SW/locks" "$SW/env" "$SW/builds"
  cp "$DIR/bin/merge-sweep.sh" "$SW/bin/sweep.sh"
  mkdir -p "$SW/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$SW/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
  # The decision reads go through the conductor lib and bin/lib/gh-rest.sh since
  # BH-784; without both the sweep's fail-closed shims answer "unverifiable" and
  # it never reaches the merge line these blocks are about. with-lib/no-lib is
  # about the MERGE ladder only.
  cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$SW/bin/lib/"
  mkdir -p "$SW/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$SW/bin/lib/mc/"
  [ "$1" = with-lib ] && cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" \
                            "$DIR/bin/lib/env-path.sh" "$SW/bin/lib/"
  local s
  for s in deploy-request.sh codegraph-ensure.sh fleet-conf.sh beat.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$SW/bin/$s"; chmod +x "$SW/bin/$s"; done
  printf '#!/bin/bash\nexit 2\n' > "$SW/bin/pre-arm-guards.sh"; chmod +x "$SW/bin/pre-arm-guards.sh"
  local d="$SW/builds/pool-project-4-CT-1598-202609180001"; mkdir -p "$d"
  echo "PR_CREATED $PR1598" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$RSHA" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  printf 'OPEN CLEAN operator %s \n' "$RSHA" > "$CASE/prstate"
}
run_sweep() {
  ( export PATH="$T/bin:$SW/bin:$PATH" HARNESS="$SW" CASE="$CASE" SWEEP_MERGE_SETTLE=0
    bash "$SW/bin/sweep.sh" >/dev/null 2>>"$CASE/sweep-err.log" )
}
new_case sweep-rest
sweep_tree with-lib
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp del '204 No Content' ''
run_sweep
grep -q -- 'api -i -X PUT repos/example-org/project-4/pulls/1598/merge' "$CASE/gh-calls.log" \
  && ok || bad "block 7: the sweep must merge with a REST PUT, got: $(calls) err=$(cat "$CASE/sweep-err.log" 2>/dev/null)"
[ "$(nputs)" = 1 ] && ok || bad "block 7: exactly one PUT, got $(nputs)"
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "block 7: the sweep must pass the REVIEWED sha, got: $(calls)"
[ "$(nmerge)" = 0 ] \
  && ok || bad "block 7: a REST merge must issue ZERO gh pr merge, got: $(merges)"
grep -q "MERGED $PR1598" "$SW/logs/merge-sweep.log" \
  && ok || bad "block 7: the sweep must record the merge, got: $(cat "$SW/logs/merge-sweep.log" 2>/dev/null)"
grep -qF "$PR1598" "$SW/state/merge-sweep-done.txt" \
  && ok || bad "block 7: the merge must be ledgered"
grep -q 'merge FAILED despite CLEAN' "$SW/logs/merge-sweep.log" \
  && bad "block 7: a merged PR must never be parked as FAILED — $(cat "$SW/logs/merge-sweep.log")" || ok

# 7b. a NATIVE-QUEUE repo keeps the GraphQL enqueue: REST cannot enqueue.
new_case sweep-queue
sweep_tree with-lib
cat > "$SW/bin/lib/merge-conductor-lib.sh" <<'MCL'
mc_queue_enabled() { return 0; }
mc_queue_conductor_only() { return 1; }
mc_pr_queued() { return 0; }
mc_closed_settled() { return 0; }
MCL
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
run_sweep
[ "$(nputs)" = 0 ] \
  && ok || bad "block 7b: a native-queue repo must make ZERO REST merge calls, got: $(calls)"

# 7c. a terminal REST refusal never falls back to the GraphQL mutation.
new_case sweep-405
sweep_tree with-lib
resp put '405 Method Not Allowed' "{\"message\":\"$M405\"}"
run_sweep
[ "$(nmerge)" = 0 ] \
  && ok || bad "block 7c: a 405 must NOT be retried over GraphQL, got: $(merges)"
grep -q 'REST merge refused (rc 3)' "$SW/logs/merge-sweep.log" \
  && ok || bad "block 7c: the sweep must name the refusal, got: $(cat "$SW/logs/merge-sweep.log" 2>/dev/null)"

# 7d. HEADBOUND_ENFORCE=0 with a moved head: the warn-only branch continues to
# the merge line, and the PUT must NOT be bound to the stale reviewed sha — that
# is a terminal 409, which is the switch doing nothing. BH-1606 (every merge is
# pinned): it is bound to the head this pass READ instead, which the switch
# waved through, so it still merges and a push inside the pass is still refused.
new_case sweep-enforce-off
sweep_tree with-lib
printf 'OPEN CLEAN operator 2222cccc2222 \n' > "$CASE/prstate"
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp get '200 OK' '{"merged":true,"head":{"ref":"ticket/project-4-1598","repo":{"full_name":"example-org/project-4"}},"base":{"ref":"main"}}'
resp del '204 No Content' ''
( export HEADBOUND_ENFORCE=0; run_sweep )
[ "$(nputs)" = 1 ] && ok || bad "block 7d: with the switch off the sweep must still PUT once, got $(nputs): $(calls)"
grep -q -- '-f sha=1111bbbb1111' "$CASE/gh-calls.log" \
  && bad "block 7d: HEADBOUND_ENFORCE=0 must not bind the PUT to the stale reviewed sha, got: $(calls)" || ok
grep -q -- '-f sha=2222cccc2222' "$CASE/gh-calls.log" \
  && ok || bad "block 7d (BH-1606): the switch-off PUT is pinned to the head this pass read, got: $(calls)"
grep -q 'HEADBOUND_ENFORCE=0 — the merge is not bound to the reviewed sha' "$SW/logs/merge-sweep.log" \
  && ok || bad "block 7d: the unbound merge must be said in the log, got: $(cat "$SW/logs/merge-sweep.log" 2>/dev/null)"
grep -q "MERGED $PR1598" "$SW/logs/merge-sweep.log" \
  && ok || bad "block 7d: the switch-off merge must be recorded, got: $(cat "$SW/logs/merge-sweep.log" 2>/dev/null)"
# …and with the switch ON (default) the same moved head is parked: zero PUTs.
new_case sweep-enforce-on
sweep_tree with-lib
printf 'OPEN CLEAN operator 2222cccc2222 \n' > "$CASE/prstate"
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
run_sweep
[ "$(nputs)" = 0 ] && ok || bad "block 7d: with the switch on a moved head must be parked, not PUT, got: $(calls)"

# ══ 8. THE PRODUCTION MERGE QUEUE: both landing paths over REST ══════════════
MQ="$T/mq"
MQPROJ=project-4-fixture              # never a real /root/repos checkout
mq_tree() { # mq_tree <with-lib|no-lib>
  scratch_rm "$MQ"
  mkdir -p "$MQ/bin/lib" "$MQ/logs" "$MQ/state/merge-queue/$MQPROJ" "$MQ/flags" "$MQ/locks" "$MQ/env"
  cp "$DIR/bin/merge-queue.sh" "$MQ/bin/mq.sh"
  # Same as sweep_tree: the queue's reads (mq_pr) come off the conductor lib and
  # bin/lib/gh-rest.sh since BH-784, in both modes.
  cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$MQ/bin/lib/"
  mkdir -p "$MQ/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$MQ/bin/lib/mc/"
  [ "$1" = with-lib ] && cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" \
                            "$DIR/bin/lib/env-path.sh" "$MQ/bin/lib/"
  printf '#!/bin/bash\n[ "$2" = repo ] && printf "%%s" "%s"\nexit 0\n' "$SLUG" > "$MQ/bin/fleet-conf.sh"
  chmod +x "$MQ/bin/fleet-conf.sh"
  local s
  for s in beat.sh deploy-request.sh lander.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$MQ/bin/$s"; chmod +x "$MQ/bin/$s"; done
  # The ledger: one head-bound APPROVE for #1598, bound to the reviewed sha.
  printf "job_verdict() { printf 'APPROVE\\t2\\tclaude\\t-\\tjob-1\\t%s\\n'; }\n" "$RSHA" > "$MQ/bin/jobs-client.sh"
  touch "$MQ/state/merge-queue/$MQPROJ/1598"
  printf 'OPEN MERGEABLE ticket/project-4-1598\n' > "$CASE/prqstate"
  printf '%s\n' "$RSHA" > "$CASE/prhead"
}
run_mq() {
  ( export PATH="$T/bin:$MQ/bin:$PATH" HARNESS="$MQ" CASE="$CASE"
    bash "$MQ/bin/mq.sh" "$MQPROJ" >/dev/null 2>>"$CASE/mq-err.log" )
}
new_case mq-rest
mq_tree with-lib
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
run_mq
grep -q -- 'api -i -X PUT repos/example-org/project-4/pulls/1598/merge' "$CASE/gh-calls.log" \
  && ok || bad "block 8: the merge queue must land over REST, got: $(calls) err=$(cat "$CASE/mq-err.log" 2>/dev/null)"
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "block 8: the queue must pass the LEDGER's reviewed sha, got: $(calls)"
[ "$(nmerge)" = 0 ] && ok || bad "block 8: zero gh pr merge, got: $(merges)"
[ ! -e "$MQ/state/merge-queue/$MQPROJ/1598" ] \
  && ok || bad "block 8: a landed entry must be removed from the queue"
grep -q "#1598 LANDED" "$MQ/logs/merge-queue.log" \
  && ok || bad "block 8: the landing must be logged, got: $(cat "$MQ/logs/merge-queue.log" 2>/dev/null)"

# 8b. a 405 park leaves the entry in place and issues NO gh pr merge.
new_case mq-405
mq_tree with-lib
resp put '405 Method Not Allowed' "{\"message\":\"$M405\"}"
run_mq
[ -e "$MQ/state/merge-queue/$MQPROJ/1598" ] \
  && ok || bad "block 8b: a refused merge must leave the entry queued"
[ "$(nmerge)" = 0 ] && ok || bad "block 8b: a 405 must not fall back to gh pr merge"
grep -q 'REST merge refused (rc 3)' "$MQ/logs/merge-queue.log" \
  && ok || bad "block 8b: the park must be named in the log, got: $(cat "$MQ/logs/merge-queue.log" 2>/dev/null)"

# 8d. HEADBOUND_ENFORCE=0: hb_blocked says "land it" on a moved head, so mq_land
# must send the PUT unbound rather than 409 on the ledger's stale sha.
new_case mq-enforce-off
mq_tree with-lib
printf '2222cccc2222\n' > "$CASE/prhead"
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
( export HEADBOUND_ENFORCE=0; run_mq )
[ "$(nputs)" = 1 ] && ok || bad "block 8d: with the switch off the queue must still PUT once, got $(nputs): $(calls) err=$(cat "$CASE/mq-err.log" 2>/dev/null)"
grep -q -- '-f sha=' "$CASE/gh-calls.log" \
  && bad "block 8d: HEADBOUND_ENFORCE=0 must send the PUT unbound, got: $(calls)" || ok
grep -q 'HEADBOUND_ENFORCE=0 — the merge is not bound to the reviewed sha' "$MQ/logs/merge-queue.log" \
  && ok || bad "block 8d: the unbound merge must be said in the log, got: $(cat "$MQ/logs/merge-queue.log" 2>/dev/null)"
[ ! -e "$MQ/state/merge-queue/$MQPROJ/1598" ] \
  && ok || bad "block 8d: the landed entry must leave the queue"

# 8c. THE TRAIN LANDING, extracted verbatim from bin/merge-queue.sh and RUN.
# The union train is the busy tier-2 path and it cannot be driven end to end in
# a scratch tree (it needs a real /root/repos checkout), so its landing block and
# the mq_land helper are lifted out by their own markers and executed — deleting
# a marker, or the mq_land call inside the block, fails here rather than passing.
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1; next} f && index($0,e){exit} f{print}' "$3"; }
new_case mq-train
mq_tree with-lib
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
marked '# >>> mq_land' '# <<< mq_land' "$DIR/bin/merge-queue.sh" > "$CASE/mqland.sh"
marked '# >>> train landing' '# <<< train landing' "$DIR/bin/merge-queue.sh" > "$CASE/train.sh"
{ [ -s "$CASE/mqland.sh" ] && [ -s "$CASE/train.sh" ]; } \
  && ok || bad "block 8c: the mq_land / train landing markers are missing from bin/merge-queue.sh"
cat > "$CASE/train-driver.sh" <<DRV
set -uo pipefail
SLUG="$SLUG"; PROJECT="$MQPROJ"; HARNESS="$MQ"
Q="$MQ/state/merge-queue/$MQPROJ"; LOG="$MQ/logs/train.log"
BATCH=1598; LANDED=0; LAST_SHA=""
STAMP() { echo 2026-09-18T00:00:00Z; }
MQROW() { :; }
bg_queue_hold() { return 1; }
hb_sha() { printf %s "$RSHA"; }
. "$MQ/bin/lib/gh-pr-merge.sh"
. "$CASE/mqland.sh"
. "$CASE/train.sh"
printf 'LANDED=%s LAST_SHA=%s\n' "\$LANDED" "\$LAST_SHA" > "$CASE/train.out"
DRV
( export PATH="$T/bin:$MQ/bin:$PATH" HARNESS="$MQ" CASE="$CASE"
  bash "$CASE/train-driver.sh" ) >/dev/null 2>>"$CASE/train-err.log"
grep -q "LANDED=1 LAST_SHA=$MSHA" "$CASE/train.out" 2>/dev/null \
  && ok || bad "block 8c: the train landing must land over REST and carry the merge sha, got '$(cat "$CASE/train.out" 2>/dev/null)' err=$(cat "$CASE/train-err.log" 2>/dev/null)"
[ "$(nmerge)" = 0 ] && ok || bad "block 8c: the train landing must issue no gh pr merge, got: $(merges)"

# ══ 9. THE CONDUCTOR: mc_merge from the real lib ═════════════════════════════
MC="$T/mc"
mc_tree() { # mc_tree <with-lib|no-lib>
  scratch_rm "$MC"; mkdir -p "$MC/bin/lib" "$MC/logs" "$MC/state/merge-conductor" "$MC/env"
  cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$MC/bin/lib/"
  mkdir -p "$MC/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$MC/bin/lib/mc/"
  [ "$1" = with-lib ] && cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" \
                            "$DIR/bin/lib/env-path.sh" "$MC/bin/lib/"
}
mc_call() { # mc_call <url> <head>
  ( export PATH="$T/bin:$PATH" HARNESS="$MC" CASE="$CASE" MC_MERGE_SETTLE=0
    bash -c '
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      OUT=$(mc_merge "$1" "$2"); RC=$?
      printf "%s\nRC=%s\n" "$OUT" "$RC"' _ "$1" "$2" )
}
# mc_locked_call <url> <head> — the PRODUCTION shape: through mc_merge_locked,
# inside a command substitution, exactly as bin/merge-conductor.sh calls it.
mc_locked_call() {
  ( export PATH="$T/bin:$PATH" HARNESS="$MC" CASE="$CASE" MC_MERGE_SETTLE=0
    mkdir -p "$MC/locks"
    bash -c '
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      ERR=$(mc_merge_locked project-4-fixture mc_merge "$1" "$2"); RC=$?
      printf "%s\nRC=%s\n" "$ERR" "$RC"' _ "$1" "$2" )
}
# mc_settle_call <merge-sha-or-empty> — mc_settle_merged with the sha threaded
# in as its trailing argument (what conductor_settle passes), or without it.
mc_settle_call() {
  ( export PATH="$T/bin:$PATH" HARNESS="$MC" CASE="$CASE" MC_DETACHED_DEPLOY_VERIFY=0
    bash -c '
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      mc_settle_merged "example-org/project-4#1598" "$1" project-4-fixture example-org/project-4 ticket/project-4-1598 - - "$2" "$3"' \
      _ "$PR1598" "$RSHA" "${1:-}" )
}
new_case mc-rest
mc_tree with-lib
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(mc_call "$PR1598" "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 9: mc_merge must rc 0 on a REST merge, got $(rcof "$OUT") — $OUT"
[ "$(outof "$OUT")" = "$MSHA" ] \
  && ok || bad "block 9: mc_merge must print the merge sha on stdout so the deploy hand-off needs no GraphQL read, got '$OUT'"
grep -q -- 'api -i -X PUT repos/example-org/project-4/pulls/1598/merge' "$CASE/gh-calls.log" \
  && ok || bad "block 9: mc_merge must PUT, got: $(calls)"
grep -q -- "-f sha=$RSHA" "$CASE/gh-calls.log" \
  && ok || bad "block 9: mc_merge must bind the merge to the reviewed head"
[ "$(nmerge)" = 0 ] && ok || bad "block 9: zero gh pr merge, got: $(merges)"
new_case mc-409
mc_tree with-lib
resp put '409 Conflict' "{\"message\":\"$M409\"}"
OUT=$(mc_call "$PR1599" "$RSHA")
[ "$(rcof "$OUT")" = 1 ] && ok || bad "block 9: a 409 must rc 1 into the conductor's two-strike path, got $(rcof "$OUT")"
grep -qF "$M409" <<<"$OUT" && ok || bad "block 9: the 409 reason must reach the conductor, got '$OUT'"
[ "$(nmerge)" = 0 ] && ok || bad "block 9: a 409 must not be retried over GraphQL"

# 9b. THE PRODUCTION SHAPE: `ERR=$(mc_merge_locked … mc_merge …)`. A variable set
# inside mc_merge dies in that subshell; the sha has to come out on stdout.
new_case mc-locked
mc_tree with-lib
resp put '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(mc_locked_call "$PR1598" "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 9b: mc_merge_locked must rc 0 on a REST merge, got $(rcof "$OUT") — $OUT"
[ "$(outof "$OUT")" = "$MSHA" ] \
  && ok || bad "block 9b: the merge sha must survive mc_merge_locked's command substitution, got '$OUT'"
[ "$(nmerge)" = 0 ] && ok || bad "block 9b: zero gh pr merge through the lock, got: $(merges)"

# 9c. THE SETTLE: handed the sha, mc_settle_merged makes NO read for it and
# hands exactly that sha to the deploy train; without it, it reads — and since
# BH-784 that read is the REST pull object (merge_commit_sha), never GraphQL.
new_case mc-settle-with-sha
mc_tree with-lib
printf 'deadbeef00\n' > "$CASE/restsha"
mc_settle_call "$MSHA" >/dev/null 2>>"$CASE/settle-err.log"
[ "$(ncalls -- '--json mergeCommit')" = 0 ] && [ "$(ncalls 'api -i -X GET repos/example-org/project-4/pulls/1598')" = 0 ] \
  && ok || bad "block 9c: with the sha in hand the settle must not read the merge sha at all (GraphQL or REST), got: $(calls)"
grep -q "^deployreq example-org/project-4#1598 $MSHA\$" "$MC/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "block 9c: the deploy train must get the REST merge sha, got: $(cat "$MC/state/merge-conductor/attempts.txt" 2>/dev/null) err=$(cat "$CASE/settle-err.log" 2>/dev/null)"
new_case mc-settle-no-sha
mc_tree with-lib
printf 'deadbeef00\n' > "$CASE/restsha"
mc_settle_call "" >/dev/null 2>>"$CASE/settle-err.log"
[ "$(ncalls -- '--json mergeCommit')" = 0 ] && [ "$(ncalls 'api -i -X GET repos/example-org/project-4/pulls/1598')" = 1 ] \
  && ok || bad "block 9c: without a sha the settle must fall back to exactly one REST pull read, never GraphQL, got: $(calls)"
grep -q "^deployreq example-org/project-4#1598 deadbeef00\$" "$MC/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "block 9c: the fallback read's sha must reach the deploy train, got: $(cat "$MC/state/merge-conductor/attempts.txt" 2>/dev/null)"
new_case mc-settle-prose
mc_tree with-lib
printf 'deadbeef00\n' > "$CASE/restsha"
mc_settle_call "HTTP refusal (rc 4): $M409" >/dev/null 2>>"$CASE/settle-err.log"
grep -q "^deployreq example-org/project-4#1598 deadbeef00\$" "$MC/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "block 9c: a non-hex trailing argument must be ignored in favour of the read, got: $(cat "$MC/state/merge-conductor/attempts.txt" 2>/dev/null)"

# 9d. A 405 keeps the state read: a PR someone else landed between the list read
# and the merge call is rc 0, not a mergefail row. Unmerged, it is rc 1 as before.
new_case mc-405-landed
mc_tree with-lib
resp put '405 Method Not Allowed' '{"message":"Pull Request is not mergeable"}'
touch "$CASE/merged"
OUT=$(mc_call "$PR1598" "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 9d: a 405 on a PR that already merged must rc 0, got $(rcof "$OUT") — $OUT"
[ "$(nmerge)" = 0 ] && ok || bad "block 9d: a 405 must not be retried over GraphQL, got: $(merges)"
# …and the state read itself is REST (BH-597). This branch exists for the PR
# the sweep landed under a rate limit; a `gh pr view --json state` here is the
# read that fails in exactly that case, and the PR is charged a mergefail row
# for a merge that already happened. The read itself is main's mc_pr_view
# (BH-784), the same REST shape block 9c's fallback read asserts.
[ "$(ncalls 'api -i -X GET repos/example-org/project-4/pulls/1598')" = 1 ] && [ "$(ncalls -- '--json state')" = 0 ] \
  && ok || bad "block 9d: the 405 branch's state read must be ONE REST read and no GraphQL, got: $(calls)"
new_case mc-405-open
mc_tree with-lib
resp put '405 Method Not Allowed' "{\"message\":\"$M405\"}"
OUT=$(mc_call "$PR1598" "$RSHA")
[ "$(rcof "$OUT")" = 1 ] && ok || bad "block 9d: a 405 on an OPEN PR stays rc 1, got $(rcof "$OUT")"
grep -qF "$M405" <<<"$OUT" && ok || bad "block 9d: the 405 reason must reach the conductor, got '$OUT'"

# ══ 10. THE LIB IS ABSENT: every lane issues today's gh pr merge, unchanged ══
new_case fallback-sweep
sweep_tree no-lib
run_sweep
[ "$(nmerge)" = 1 ] \
  && ok || bad "block 10: without the lib the sweep must issue exactly today's gh pr merge, got: $(merges)"
# TEST-CHANGE (BH-1715): this pinned --delete-branch on the fallback line. Real
# gh deletes the head ref without retargeting stacked PRs and GitHub closes
# them, so the flag is gone; without the lib the branch is kept.
grep -q -- '--delete-branch' "$CASE/pr-merge.log" \
  && bad "block 10: the sweep's fallback line must not pass --delete-branch, got: $(merges)" || ok
[ "$(nputs)" = 0 ] && ok || bad "block 10: no lib means no REST call"

new_case fallback-mq
mq_tree no-lib
printf '%s\n' "$MSHA" > "$CASE/restsha"
run_mq
[ "$(nmerge)" = 1 ] \
  && ok || bad "block 10: without the lib the queue must issue today's gh pr merge, got: $(merges)"
grep -q -- "pr merge 1598 -R $SLUG --squash" "$CASE/pr-merge.log" \
  && ok || bad "block 10: the queue's fallback line is unchanged, got: $(merges)"

new_case fallback-mc
mc_tree no-lib
OUT=$(mc_call "$PR1598" "$RSHA")
grep -q -- "--match-head-commit $RSHA" "$CASE/pr-merge.log" \
  && ok || bad "block 10: without the lib mc_merge keeps --match-head-commit, got: $(merges)"
[ "$(rcof "$OUT")" = 0 ] \
  && ok || bad "block 10: the fallback merge must still verify MERGED and rc 0, got $(rcof "$OUT")"

echo "merge-rest-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
