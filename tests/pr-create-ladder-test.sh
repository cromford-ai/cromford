#!/bin/bash
# tests/pr-create-ladder-test.sh — PR CREATE IS A LADDER, NOT ONE RUNG.
#
# THE DEFECT (BH-848, 2026-09-18). `gh pr create` is GraphQL under the hood. On a
# pool machine it runs on a GitHub App installation token whose GraphQL budget is
# chronically exhausted:
#   GraphQL: API rate limit already exceeded for installation ID 161623167.
# `PR_URL` came back empty, the adopt fallback was `gh pr list` — GraphQL again,
# same bucket, same failure — and the build wrote `PR_CREATE_FAILED`. Ten open
# cromford PRs had url-less records at the time of writing; bin/merge-sweep.sh
# only walks records whose line 1 is `PR_CREATED https://`, so ten CI-green APPROVE
# PRs were invisible to the sweep. REST and GraphQL are separate budgets — this repo
# already learned that for READS (BH-709, BH-374) and not for the create.
#
# WHAT THIS SUITE PINS: bin/lib/gh-pr-create.sh climbs GraphQL create -> GraphQL
# adopt -> REST adopt -> REST create -> REST on every OTHER identity this box holds,
# prints the URL and nothing else, and stops after the GraphQL adopt when the kill
# flag is set — the pre-#848 behaviour, which the flag must RESTORE and not remove
# (blocks 2c, 4, 10). Blocks 9 and 10 drive the PRODUCTION entry point: the
# `# >>> result pr url ratchet` and `# >>> pr create call` blocks are EXTRACTED
# VERBATIM from bin/run-build.sh and run against a scratch $HARNESS, so deleting
# the ladder's call site — or the adopt it replaced — fails this suite (D2). It is
# the ticket's reproduction, in the suite, so the defect cannot come back unnoticed.
#
# Assertions are on artifacts: stdout, the rc, $BUILD/RESULT, pipeline.log and the
# stub's call log. No network, no real token, no clock.
#
# Run from anywhere: bash tests/pr-create-ladder-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# One clock read for the whole file (bin/test-determinism-lint.sh); nothing below
# depends on its value — it only keeps the fixture directory names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# jq is a hard dependency of the lib itself (it parses the REST body), so a box
# without it cannot run the ladder either. Fail loudly rather than skip.
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the ladder"; exit 1; }
# A real credential in the runner's environment must never reach a fixture, a
# rung or an assertion message. Every identity below is a named fixture.
# HARNESS_ENV_DIR goes too: bin/lib/env-path.sh honours it FIRST, so leaving a
# pool box's value set would point the admin rung at the real env bundle and pull
# a live token into this suite.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR

SLUG="example-org/cromford"
URL834="https://github.com/example-org/cromford/pull/834"
URL707="https://github.com/example-org/cromford/pull/707"

# ── the stub gh ──────────────────────────────────────────────────────────────
# Answers from the per-case fixture files in $CASE and records every call. It
# records the WORD for the token in use (app/pat/admin/none), never the value —
# the same discipline bin/lib/gh-repo-token.sh keeps. Fixtures are consumed in
# sequence when numbered (list.1, list.2 …), so a rung that re-reads gets a
# different answer without anything in this file racing a clock.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
W=none
case "${GH_TOKEN:-}" in
  ghs_app_FIXTURE)   W=app ;;
  ghp_pat_FIXTURE)   W=pat ;;
  ghp_admin_FIXTURE) W=admin ;;
  "")                W=none ;;
  *)                 W=other ;;
esac
printf 'token=%s %s\n' "$W" "$*" >> "$CASE/gh-calls.log"
case "$1 $2" in
  "pr create")
    printf 'GraphQL: API rate limit already exceeded for installation ID 161623167.\n' >&2
    exit 1 ;;
  "pr list")
    # GraphQL is the exhausted budget unless a case says otherwise; $CASE/prlist
    # holds the url `gh pr list --json url -q .[0].url` would have printed.
    [ -f "$CASE/prlist" ] && { cat "$CASE/prlist"; exit 0; }
    printf 'GraphQL: API rate limit already exceeded for installation ID 161623167.\n' >&2
    exit 1 ;;
  "api user")
    # The login behind the token in use — a fixture per identity WORD, operator by
    # default. `gh api user -q .login` prints the bare login, so the stub does too.
    # `login.<word>.fail` makes the READ fail the way a blip, a 5xx or a secondary
    # rate limit does: nothing on stdout, a reason on stderr, non-zero.
    [ -f "$CASE/login.$W.fail" ] && {
      printf 'gh: HTTP 503 Service Unavailable (https://api.github.com/user)\n' >&2; exit 1; }
    [ -f "$CASE/login.$W" ] && { cat "$CASE/login.$W"; exit 0; }
    echo operator; exit 0 ;;
  "api -i") ;;
  *) exit 1 ;;
esac
KIND=list
for a in "$@"; do case "$a" in POST) KIND=post ;; esac; done
N=$(cat "$CASE/$KIND.n" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$CASE/$KIND.n"
for F in "$CASE/$KIND.$W.$N" "$CASE/$KIND.$N" "$CASE/$KIND.$W" "$CASE/$KIND"; do
  [ -f "$F" ] && { cat "$F"; exit 0; }
done
echo "stub gh: no fixture for $KIND (token=$W attempt=$N)" >&2
exit 1
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

# A scratch $HARNESS so the lib's flag and env lookups never touch a live tree.
HARNESS="$T/h"; export HARNESS
mkdir -p "$HARNESS/bin/lib" "$HARNESS/flags" "$HARNESS/env" "$HARNESS/logs"
cp "$DIR/bin/lib/gh-pr-create.sh" "$HARNESS/bin/lib/" 2>/dev/null || {
  echo "FAIL: bin/lib/gh-pr-create.sh does not exist — the ladder has not been built"; exit 1; }
# The real resolver, so block 2b exercises the env path the admin rung takes on a
# box rather than a spelled-out fallback (tests/env-path-test.sh).
cp "$DIR/bin/lib/env-path.sh" "$HARNESS/bin/lib/" 2>/dev/null || {
  echo "FAIL: bin/lib/env-path.sh is missing"; exit 1; }
# The sweep's own author matcher, so block 2d exercises the SAME set the sweep
# filters on (bin/lib/gh-pr-list.sh) and not a copy that could drift from it.
cp "$DIR/bin/lib/gh-pr-list.sh" "$HARNESS/bin/lib/" 2>/dev/null || {
  echo "FAIL: bin/lib/gh-pr-list.sh is missing"; exit 1; }

new_case() { # new_case <name> -> exports CASE with a body file and an empty call log
  CASE="$T/case-$1-$NOW"; export CASE
  scratch_rm "$CASE"; mkdir -p "$CASE"
  printf 'body of the PR\n' > "$CASE/body.md"
  : > "$CASE/gh-calls.log"
}
resp() { # resp <fixture name> <status> <body>
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"
}
ncalls() { grep -c -- "$1" "$CASE/gh-calls.log" 2>/dev/null || true; }
# The ladder under test, run in a subshell so nothing it sources leaks between
# blocks. Prints the ladder's stdout, then RC=<its true exit code>.
ladder() { # ladder <head-branch> [env assignments via the caller's environment]
  ( . "$HARNESS/bin/lib/gh-pr-create.sh"
    [ -n "${DEFAULT_TOK:-}" ] && _GHAA_DEFAULT_TOK="$DEFAULT_TOK"
    gh_pr_create_ladder "$SLUG" "$1" main "BH: subject" "$CASE/body.md" \
      "$CASE/gh-stderr.log" "$CASE/pipeline.log" "$1"
    printf 'RC=%s\n' "$?"
    # The WORD for whatever identity the shell is left holding — never the value,
    # even when the runner's own environment carries a real one.
    case "${GH_TOKEN:-}" in
      ghs_app_FIXTURE) printf 'AFTER=app\n' ;;
      ghp_pat_FIXTURE) printf 'AFTER=pat\n' ;;
      "")              printf 'AFTER=unset\n' ;;
      *)               printf 'AFTER=other\n' ;;
    esac )
}
urlof()  { grep -m1 -E '^https://' <<<"$1"; }
rcof()   { sed -n 's/^RC=//p' <<<"$1"; }

# ══ 1. rate-limited GraphQL create, nothing to adopt, REST 201 ═══════════════
new_case rest-create
resp list '200 OK' '[]'
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
OUT=$(ladder ticket/bh-1)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 1: the ladder must rc 0 when REST creates the PR, got $(rcof "$OUT")"
[ "$(urlof "$OUT")" = "$URL834" ] && ok || bad "block 1: stdout must be exactly $URL834, got '$OUT'"
grep -q 'rung rest:' "$CASE/pipeline.log" \
  && ok || bad "block 1: pipeline.log must name the rung that worked, got: $(cat "$CASE/pipeline.log" 2>/dev/null)"
[ "$(ncalls 'pr create')" = 1 ] \
  && ok || bad "block 1: exactly ONE 'gh pr create' (no GraphQL retry — the reads lesson), got $(ncalls 'pr create')"
[ "$(ncalls 'POST')" = 1 ] \
  && ok || bad "block 1: exactly ONE REST POST, got $(ncalls 'POST')"
grep -q 'API rate limit' "$CASE/gh-stderr.log" \
  && ok || bad "block 1: rung 1's stderr must land in the stderr log the caller passed"
grep -q 'rate-limited' "$CASE/pipeline.log" \
  && ok || bad "block 1: the log must WORD the cap it fell through ('rate-limited')"
grep -qE 'ghs_|ghp_' "$CASE/pipeline.log" \
  && bad "block 1: a token value reached pipeline.log" || ok

# ══ 2. REST 403 on the App identity, 201 on the default PAT ══════════════════
new_case identity
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
resp post.pat '201 Created' "{\"html_url\":\"$URL834\"}"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; export GH_TOKEN; DEFAULT_TOK=ghp_pat_FIXTURE; ladder ticket/bh-2 )
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 2: the ladder must rc 0 when a second identity creates the PR, got $(rcof "$OUT")"
[ "$(urlof "$OUT")" = "$URL834" ] && ok || bad "block 2: the PAT rung's url must be printed, got '$OUT'"
grep -qx 'AFTER=app' <<<"$OUT" \
  && ok || bad "block 2: GH_TOKEN must be UNCHANGED after the ladder (a rung token is per-call), got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=pat ')" = 1 ] \
  && ok || bad "block 2: the successful POST must be recorded on the PAT, got: $(grep POST "$CASE/gh-calls.log")"
grep -q 'rung rest:default-pat' "$CASE/pipeline.log" \
  && ok || bad "block 2: the log must name the identity rung by WORD, got: $(cat "$CASE/pipeline.log")"
grep -qE 'ghs_|ghp_' "$CASE/pipeline.log" \
  && bad "block 2: a token value reached pipeline.log" || ok

# ══ 2b. the admin PAT rung reads the env dir the RESOLVER names ══════════════
# bin/lib/env-path.sh is the only thing allowed to say where env/ is: $HARNESS/env
# is a compat symlink for one release, and a rung that SPELLS the path silently
# stops existing the day it goes. Nothing but this block writes github-admin.env.
new_case admin-identity
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
resp post.admin '201 Created' "{\"html_url\":\"$URL834\"}"
# The bundle lives where the RESOLVER says, NOT at $HARNESS/env: that is the
# arrangement a pool box (tmpfs) and a watcher box (/etc/harness/env) both have,
# and a rung that spells $HARNESS/env finds nothing here — which is precisely the
# silent loss this asserts against.
mkdir -p "$T/envdir"
printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR; ladder ticket/bh-2b )
rm -f "$T/envdir/github-admin.env"
[ "$(urlof "$OUT")" = "$URL834" ] \
  && ok || bad "block 2b: rung rest:admin-pat must create the PR, got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=admin ')" = 1 ] \
  && ok || bad "block 2b: the successful POST must be on the admin identity, got: $(grep POST "$CASE/gh-calls.log")"
grep -q 'rung rest:admin-pat' "$CASE/pipeline.log" \
  && ok || bad "block 2b: the log must name the admin rung by WORD, got: $(cat "$CASE/pipeline.log")"
grep -qE 'ghs_|ghp_' "$CASE/pipeline.log" \
  && bad "block 2b: a token value reached pipeline.log" || ok

# ══ 2d. an identity the sweep cannot see is NOT a rung ═══════════════════════
# bin/merge-sweep.sh drops every PR whose author is outside HARNESS_PR_AUTHORS
# (default `operator app/cromford`). A PR the admin PAT opens is authored by
# the admin login; if that login is outside the set, the ladder would "succeed"
# into a PR the sweep and conductor never touch — the same invisibility one layer
# over. The login is read once and the rung is skipped with the reason logged.
new_case admin-outsider
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
resp post.admin '201 Created' "{\"html_url\":\"$URL834\"}"
printf 'contractor-x\n' > "$CASE/login.admin"
mkdir -p "$T/envdir"
printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR; unset HARNESS_PR_AUTHORS; ladder ticket/bh-2d )
[ "$(rcof "$OUT")" = 1 ] && [ -z "$(urlof "$OUT")" ] \
  && ok || bad "block 2d: an identity outside HARNESS_PR_AUTHORS must not open the PR, got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=admin ')" = 0 ] \
  && ok || bad "block 2d: no POST may run on the outsider identity, got: $(grep POST "$CASE/gh-calls.log")"
[ "$(grep -c '^token=admin api user' "$CASE/gh-calls.log")" = 1 ] \
  && ok || bad "block 2d: the login must be read exactly once, got: $(grep 'api user' "$CASE/gh-calls.log")"
grep -q "rung rest:admin-pat skipped — its login 'contractor-x' is not in HARNESS_PR_AUTHORS" "$CASE/pipeline.log" \
  && ok || bad "block 2d: the skip must be logged with the login and the reason, got: $(cat "$CASE/pipeline.log")"
grep -q 'operator app/cromford' "$CASE/pipeline.log" \
  && ok || bad "block 2d: the log must name the set the login was checked against"
grep -qE 'ghs_|ghp_' "$CASE/pipeline.log" \
  && bad "block 2d: a token value reached pipeline.log" || ok
# The same identity, once an operator adds its login to the set, IS a rung.
new_case admin-in-set
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
resp post.admin '201 Created' "{\"html_url\":\"$URL834\"}"
printf 'contractor-x\n' > "$CASE/login.admin"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; HARNESS_PR_AUTHORS="operator app/cromford contractor-x"
       export GH_TOKEN HARNESS_ENV_DIR HARNESS_PR_AUTHORS; ladder ticket/bh-2d2 )
rm -f "$T/envdir/github-admin.env"
[ "$(urlof "$OUT")" = "$URL834" ] \
  && ok || bad "block 2d: with the login in HARNESS_PR_AUTHORS the admin rung must create the PR, got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=admin ')" = 1 ] \
  && ok || bad "block 2d: the successful POST must be on the admin identity once it is in the set"

# ══ 2g. an outsider identity still ADOPTS — only its create is gated ═════════
# Adopt is a read. The open PR it finds on the head was authored by whoever
# opened it (here the ambient App identity, which created it and then 403'd
# before it could report the url), not by the token reading it, so the sweep
# sees that PR whatever this login is. Gating the adopt behind the login turned
# this recoverable tick into `every rung failed` (review round 2, finding 2).
new_case admin-outsider-adopts
resp list '200 OK' '[]'
resp list.admin '200 OK' "[{\"html_url\":\"$URL707\"}]"
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
printf 'contractor-x\n' > "$CASE/login.admin"
mkdir -p "$T/envdir"
printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR; unset HARNESS_PR_AUTHORS; ladder ticket/bh-2g )
rm -f "$T/envdir/github-admin.env"
[ "$(urlof "$OUT")" = "$URL707" ] && [ "$(rcof "$OUT")" = 0 ] \
  && ok || bad "block 2g: an outsider identity must still adopt the open PR on the head, got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=admin ')" = 0 ] \
  && ok || bad "block 2g: no POST may run on the outsider identity, got: $(grep POST "$CASE/gh-calls.log")"
grep -q "rung rest:admin-pat: adopted the open PR already on ticket/bh-2g" "$CASE/pipeline.log" \
  && ok || bad "block 2g: the adopt must be logged on the admin rung, got: $(cat "$CASE/pipeline.log")"
grep -q 'rung rest:admin-pat skipped' "$CASE/pipeline.log" \
  && bad "block 2g: the login gate must not run ahead of the adopt read" || ok
grep -qE 'ghs_|ghp_' "$CASE/pipeline.log" \
  && bad "block 2g: a token value reached pipeline.log" || ok

# ══ 2e. a login that WOULD NOT READ is UNKNOWN, not an outsider ══════════════
# D11 / BH-709 in this file's own words: a failed read is never a fact. `gh api
# user` fails on a network blip, a 5xx or a secondary rate limit, and reading
# that as "not one of ours" deletes the last rung of the ladder on exactly the
# path where the ambient identity has already 403'd — the only reason these
# rungs exist. The rung RUNS, and the log says unknown rather than outsider.
new_case admin-login-unreadable
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded for installation ID 161623167."}'
resp post.admin '201 Created' "{\"html_url\":\"$URL834\"}"
: > "$CASE/login.admin.fail"
mkdir -p "$T/envdir"
printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"
OUT=$( GH_TOKEN=ghs_app_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR; unset HARNESS_PR_AUTHORS; ladder ticket/bh-2e )
rm -f "$T/envdir/github-admin.env" "$CASE/login.admin.fail"
[ "$(urlof "$OUT")" = "$URL834" ] \
  && ok || bad "block 2e: an unreadable login must not delete the rung, got '$OUT'"
[ "$(grep 'POST' "$CASE/gh-calls.log" | grep -c '^token=admin ')" = 1 ] \
  && ok || bad "block 2e: the admin rung must still POST, got: $(grep POST "$CASE/gh-calls.log")"
grep -q "rung rest:admin-pat: its login would not read" "$CASE/pipeline.log" \
  && ok || bad "block 2e: the log must say the login would not read, got: $(cat "$CASE/pipeline.log")"
grep -q 'rung rest:admin-pat skipped' "$CASE/pipeline.log" \
  && bad "block 2e: an unreadable login must never be logged as a skipped outsider" || ok

# ══ 2f. the author set is never a second literal ═════════════════════════════
# bin/lib/gh-pr-list.sh owns the set ("THE SET IS ONE STRING … Nothing else may
# hardcode a login"). The fallback matcher in gh-pr-create.sh must read that
# lib's HARNESS_PR_AUTHORS_DEFAULT, never its own copy of the names, and it must
# bare both sides the way harness_pr_author_match does so the two cannot drift
# on a spelling.
( . "$DIR/bin/lib/gh-pr-create.sh" 2>/dev/null
  unset -f harness_pr_author_match harness_pr_authors 2>/dev/null
  unset HARNESS_PR_AUTHORS
  HARNESS_PR_AUTHORS_DEFAULT="operator app/cromford"
  _gpc_author_ok 'cromford[bot]' || exit 1
  _gpc_author_ok app/cromford || exit 2
  _gpc_author_ok operator || exit 3
  _gpc_author_ok contractor-x && exit 4
  unset HARNESS_PR_AUTHORS_DEFAULT
  _gpc_author_ok contractor-x || exit 5   # no set at all is UNKNOWN, not an outsider
  exit 0 )
[ $? = 0 ] \
  && ok || bad "block 2f: the fallback matcher must read HARNESS_PR_AUTHORS_DEFAULT, bare both spellings, and treat an unknowable set as UNKNOWN"
# CODE only: the comments name the set to explain the rule, the code must not.
grep -q 'operator' <<<"$(grep -vE '^[[:space:]]*#' "$DIR/bin/lib/gh-pr-create.sh")" \
  && bad "block 2f: bin/lib/gh-pr-create.sh must not hardcode a login — the set belongs to bin/lib/gh-pr-list.sh" || ok

# ══ 2c. rung graphql-adopt: the adopt run-build.sh has always done ═══════════
# THE REGRESSION THIS BLOCK EXISTS FOR. Before #848 the whole of bin/run-build.sh's
# PR open was `gh pr create` then `gh pr list --head … --state open`. If the ladder
# replaces the create but drops that adopt, a box whose REST budget is the
# exhausted one (GraphQL fine) stops adopting the PR it already has and writes
# PR_CREATE_FAILED where main wrote PR_CREATED — the ticket's own failure class,
# re-created by its fix.
new_case graphql-adopt
printf '%s\n' "$URL707" > "$CASE/prlist"
resp post '403 Forbidden' '{"message":"API rate limit exceeded."}'
OUT=$(ladder ticket/bh-2c)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 2c: an open PR found by gh pr list must rc 0, got $(rcof "$OUT")"
[ "$(urlof "$OUT")" = "$URL707" ] \
  && ok || bad "block 2c: rung graphql-adopt must print the adopted url, got '$OUT'"
grep -q 'rung graphql-adopt' "$CASE/pipeline.log" \
  && ok || bad "block 2c: the log must name rung graphql-adopt, got: $(cat "$CASE/pipeline.log")"
[ "$(ncalls 'api')" = 0 ] \
  && ok || bad "block 2c: adopting over GraphQL must spend no REST call, got $(ncalls 'api')"

# ══ 3. every rung fails ══════════════════════════════════════════════════════
new_case all-fail
resp list '200 OK' '[]'
resp post '403 Forbidden' '{"message":"API rate limit exceeded."}'
OUT=$(ladder ticket/bh-3)
[ "$(rcof "$OUT")" = 1 ] && ok || bad "block 3: every rung failing must rc 1, got $(rcof "$OUT")"
[ -z "$(urlof "$OUT")" ] && ok || bad "block 3: a failed ladder prints NO url on stdout, got '$OUT'"
grep -q 'PR_CREATED' "$CASE/pipeline.log" \
  && bad "block 3: a failed ladder must never write a PR_CREATED claim anywhere" || ok
grep -q 'no second identity on this machine' "$CASE/pipeline.log" \
  && ok || bad "block 3: a pool machine (one identity) must say so in the log"

# ══ 4. the kill flag: the pre-#848 behaviour, and nothing past it ════════════
# The flag switches off the REST rungs #848 ADDED. It must NOT switch off what
# bin/run-build.sh did before #848 — `gh pr create` then `gh pr list` — or the
# rollback lever for this change re-creates the bug it rolled back from.
new_case killflag
resp list '200 OK' '[]'
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
OUT=$( PR_CREATE_REST_FALLBACK=0; export PR_CREATE_REST_FALLBACK; ladder ticket/bh-4 )
[ "$(rcof "$OUT")" = 1 ] && ok || bad "block 4: with the fallback off a failed create and a failed adopt must rc 1, got $(rcof "$OUT")"
[ -z "$(urlof "$OUT")" ] && ok || bad "block 4: with the fallback off no url is printed, got '$OUT'"
[ "$(ncalls 'pr create')" = 1 ] \
  && ok || bad "block 4: exactly one 'gh pr create', got $(ncalls 'pr create')"
[ "$(ncalls 'pr list')" = 1 ] \
  && ok || bad "block 4: the GraphQL adopt is pre-#848 behaviour and must still run under the kill flag, got $(ncalls 'pr list')"
[ "$(ncalls 'api')" = 0 ] \
  && ok || bad "block 4: the kill flag must make ZERO REST calls, got $(ncalls 'api')"
# …and when that adopt FINDS the PR, the flag path still ends in a url — this is
# the shape main answers today, and the rollback lever has to answer it too.
new_case killflag-adopts
printf '%s\n' "$URL707" > "$CASE/prlist"
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
OUT=$( PR_CREATE_REST_FALLBACK=0; export PR_CREATE_REST_FALLBACK; ladder ticket/bh-4a )
{ [ "$(rcof "$OUT")" = 0 ] && [ "$(urlof "$OUT")" = "$URL707" ] && [ "$(ncalls 'api')" = 0 ]; } \
  && ok || bad "block 4: with the fallback off an open PR must still be adopted over GraphQL, got '$OUT' / $(ncalls 'api') REST calls"
new_case killflag-file
resp list '200 OK' '[]'
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
touch "$HARNESS/flags/pr-create-rest-fallback-off"
OUT=$(ladder ticket/bh-4b)
{ [ -z "$(urlof "$OUT")" ] && [ "$(ncalls 'api')" = 0 ] && [ "$(ncalls 'pr list')" = 1 ]; } \
  && ok || bad "block 4: flags/pr-create-rest-fallback-off must stop the ladder after rung graphql-adopt too"
rm -f "$HARNESS/flags/pr-create-rest-fallback-off"

# ══ 5. REST adopt finds the PR the GraphQL create could not report ═══════════
new_case rest-adopt
resp list '200 OK' "[{\"html_url\":\"$URL707\"}]"
OUT=$(ladder ticket/bh-5)
[ "$(urlof "$OUT")" = "$URL707" ] && ok || bad "block 5: an open PR on the head must be ADOPTED over REST, got '$OUT'"
[ "$(ncalls 'POST')" = 0 ] \
  && ok || bad "block 5: adopting must not also POST a create, got $(ncalls 'POST')"

# ══ 6. a failed READ is UNKNOWN, never "no PR" ═══════════════════════════════
# A 403 on the adopt must not read as "nothing to adopt": it falls through to the
# create rung, and the log says UNKNOWN rather than absent (D11, the BH-709 lesson).
new_case adopt-403
resp list '403 Forbidden' '{"message":"API rate limit exceeded."}'
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
OUT=$(ladder ticket/bh-6)
[ "$(urlof "$OUT")" = "$URL834" ] && ok || bad "block 6: a 403 adopt must fall through to the create rung, got '$OUT'"
grep -q 'HTTP 403' "$CASE/pipeline.log" \
  && ok || bad "block 6: the log must carry the real status of the failed read"
grep -q 'nor as absent' "$CASE/pipeline.log" \
  && ok || bad "block 6: a failed read must be logged as UNKNOWN, not as absent"

# ══ 7. HTTP 201 with no html_url is a FAILED rung, never an empty url ════════
new_case no-url-201
resp list '200 OK' '[]'
resp post '201 Created' '{"number":834}'
OUT=$(ladder ticket/bh-7)
{ [ "$(rcof "$OUT")" = 1 ] && [ -z "$(urlof "$OUT")" ]; } \
  && ok || bad "block 7: a 201 with no html_url must fail the rung (rc 1, no url), got '$OUT'"

# ══ 8. 422 "a pull request already exists" re-reads instead of failing ═══════
new_case create-422
resp list.1 '200 OK' '[]'
resp list.2 '200 OK' "[{\"html_url\":\"$URL707\"}]"
resp post '422 Unprocessable Entity' \
  '{"message":"Validation Failed","errors":[{"message":"A pull request already exists for example-org:ticket/bh-8."}]}'
OUT=$(ladder ticket/bh-8)
[ "$(urlof "$OUT")" = "$URL707" ] && ok || bad "block 8: a 422 'already exists' must re-read the PR over REST, got '$OUT'"

# ══ 9. THE PRODUCTION ENTRY POINT: run-build.sh's own blocks, verbatim ═══════
# This is the ticket's reproduction. The two marked blocks are lifted out of
# bin/run-build.sh and run against the stub: a rate-limited GraphQL create with
# nothing to adopt must still end as `PR_CREATED https://…` in $BUILD/RESULT,
# with no ALERTS line. Delete the ladder's call site and this block goes red.
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }
entry_point() { # entry_point <branch> -> runs run-build.sh's own blocks; BUILDDIR is the record
  BLK="$CASE/blk.sh"
  marked '# >>> result pr url ratchet' '# <<< result pr url ratchet' "$RB_ALL" >  "$BLK"
  marked '# >>> pr create call'        '# <<< pr create call'        "$RB_ALL" >> "$BLK"
  [ -s "$BLK" ] || return 1
  hold_gate_prepend "$RB_ALL" "$BLK"   # BH-6091: the real gate, a no-HOLD ticket read
  BUILDDIR="$CASE/b"; mkdir -p "$BUILDDIR"
  ( cd "$BUILDDIR" \
    && git init -q . \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "the subject line" \
    && git remote add origin "https://github.com/$SLUG.git" ) >/dev/null 2>&1
  ( cd "$BUILDDIR" && CASE="$CASE" HARNESS="$HARNESS" BUILD="$BUILDDIR" PROJECT=cromford KEY=BH-1 \
     BRANCH="$1" BASE=main BASE_MAIN=main ALERTS="$CASE/ALERTS.log" \
     bash -c 'STAMP(){ echo 2026-09-18T00:00:00Z; }; PR_BODY_FOR(){ echo body; }; EVIDENCE_SECTION=; GH_LIVE(){ :; };
              . '"$BLK"'; RESULT "PR_CREATED $PR_URL"' ) >/dev/null 2>&1
  return 0
}
new_case entry-point
resp list '200 OK' '[]'
resp post '201 Created' "{\"html_url\":\"$URL834\"}"
entry_point ticket/bh-1 && ok || bad "block 9: the marked blocks are missing from bin/run-build.sh"
grep -q "^PR_CREATED $URL834" "$BUILDDIR/RESULT" \
  && ok || bad "block 9 (production entry point): \$BUILD/RESULT must read 'PR_CREATED $URL834', got '$(cat "$BUILDDIR/RESULT" 2>/dev/null)'"
[ -f "$CASE/ALERTS.log" ] \
  && bad "block 9: a build whose PR was created on the REST rung must write NO ALERTS line, got: $(cat "$CASE/ALERTS.log")" || ok
grep -q 'rung rest:' "$BUILDDIR/pipeline.log" \
  && ok || bad "block 9: the build's pipeline.log must name the rung that opened the PR"

# ══ 10. THE ENTRY POINT KEEPS MAIN'S ADOPT — default flags AND kill flag ═════
# On main the create failing with "a pull request already exists" and `gh pr list`
# naming the PR ends as PR_CREATED. The ladder must answer the same, and so must
# the rollback lever: this is the case where the box's REST budget is the spent
# one (403) and GraphQL is fine. Either answering PR_CREATE_FAILED is a
# regression against the branch this diff replaces.
new_case entry-adopt
printf '%s\n' "$URL707" > "$CASE/prlist"
resp list '403 Forbidden' '{"message":"API rate limit exceeded."}'
resp post '403 Forbidden' '{"message":"API rate limit exceeded."}'
entry_point ticket/bh-10 && ok || bad "block 10: the marked blocks are missing from bin/run-build.sh"
grep -q "^PR_CREATED $URL707" "$BUILDDIR/RESULT" \
  && ok || bad "block 10: an open PR named by gh pr list must still be adopted — \$BUILD/RESULT must read 'PR_CREATED $URL707', got '$(cat "$BUILDDIR/RESULT" 2>/dev/null)'"
[ -f "$CASE/ALERTS.log" ] \
  && bad "block 10: an adopted PR must write NO ALERTS line, got: $(cat "$CASE/ALERTS.log")" || ok

new_case entry-adopt-killflag
printf '%s\n' "$URL707" > "$CASE/prlist"
resp list '403 Forbidden' '{"message":"API rate limit exceeded."}'
resp post '403 Forbidden' '{"message":"API rate limit exceeded."}'
export PR_CREATE_REST_FALLBACK=0
entry_point ticket/bh-10b && ok || bad "block 10: the marked blocks are missing from bin/run-build.sh"
unset PR_CREATE_REST_FALLBACK
grep -q "^PR_CREATED $URL707" "$BUILDDIR/RESULT" \
  && ok || bad "block 10 (kill flag): PR_CREATE_REST_FALLBACK=0 must leave the entry point adopting exactly as it did before #848, got '$(cat "$BUILDDIR/RESULT" 2>/dev/null)'"
[ "$(ncalls 'api')" = 0 ] \
  && ok || bad "block 10 (kill flag): zero REST calls, got $(ncalls 'api')"
[ -f "$CASE/ALERTS.log" ] \
  && bad "block 10 (kill flag): an adopted PR must write NO ALERTS line, got: $(cat "$CASE/ALERTS.log")" || ok

echo "pr-create-ladder-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
