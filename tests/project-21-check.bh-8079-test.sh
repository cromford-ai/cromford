#!/bin/bash
# tests/project-21-check.bh-8079-test.sh — bin/project-21-check.sh against a fake
# project-21 API (tests/lib/fake-project-21-api.bh-8079.py on 127.0.0.1).
#   C1  an affected lockfile: one row line per advisory, the summary, rc 0, one POST
#   C2  a clean answer: "none known"
#   C3  HTTP 500: "check failed (HTTP 500)", never "none known", rc 0
#   C4  no lockfile: "nothing to check", 0 requests
#   C5  HTTP 429; C6 an HTML answer; C7 a timeout
#   C8  a partial_coverage skip and a checked:0 answer are partial, never clean
#   C9  which files are sent (nested, near-miss names, untracked)
#   C10 PROJECT_21_ENABLED=0: off, 0 requests
#   C11 not a git worktree: check failed, rc 0
#   C12 the scratch default (PROJECT_21_BASE_URL empty): not configured, 0 curl calls
#   C13 a usage error exits 2; C14 --out writes the result JSON
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-21-check.bh-8079-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PROJECT_21_ENABLED PROJECT_21_TIMEOUT_S

H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/project-21-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/project-21-check.sh"; exit 1; }
CHECK="$H/bin/project-21-check.sh"
[ -x "$CHECK" ] || { echo "FAIL: $SRC/bin/project-21-check.sh is missing or not executable"; exit 1; }

# C12 runs FIRST, before the fake exports a base URL: scratch.sh's own default.
mkrepo() { # mkrepo <dir> <tracked file>...
  local d="$1"; shift
  mkdir -p "$d" && git -C "$d" init -q -b main
  local f
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf '{"lockfileVersion":3}\n' > "$d/$f"; done
  printf 'x\n' > "$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -qm init
}
mkrepo "$T/r-lock" package-lock.json
mkdir -p "$T/shim"
printf '#!/bin/bash\necho "$*" >> %q\nexit 7\n' "$T/curl-calls.log" > "$T/shim/curl"; chmod +x "$T/shim/curl"
: > "$T/curl-calls.log"
out=$(PATH="$T/shim:$PATH" "$CHECK" "$T/r-lock" 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (PROJECT_21_BASE_URL is empty: not configured)' <<<"$out" \
  && [ ! -s "$T/curl-calls.log" ]; } && ok || bad "C12 scratch default: rc=$rc out=$out curl=$(cat "$T/curl-calls.log")"

. "$SRC/tests/lib/project-21-fake.bh-8079.sh" "$SRC" || exit 1
tf_start || exit 1

summary() { sed -n 's/^PROJECT_21_SUMMARY //p' <<<"$1" | tail -1; }
run() { # run <repo> [args] -> $out $rc
  tf_reset
  out=$("$CHECK" "$@" 2>&1); rc=$?
}

# C1 affected
tf_mode affected; run "$T/r-lock"
s=$(summary "$out")
{ [ "$rc" = 0 ] \
  && grep -q '^project-21: affected npm/lodash@4.17.15 high fixed_in=4.17.21 GHSA-p6mc-m468-83gw https://osv.dev/vulnerability/GHSA-p6mc-m468-83gw$' <<<"$out" \
  && [ "$(grep -c '^project-21: affected ' <<<"$out")" = 2 ] \
  && [ "$(tail -1 <<<"$out" | cut -d' ' -f1)" = PROJECT_21_SUMMARY ] \
  && [ "$(jq -r .state <<<"$s")" = affected ] && [ "$(jq -r .affected <<<"$s")" = 2 ] && [ "$(jq -r .checked <<<"$s")" = 2 ] \
  && [ "$(tf_posts)" = 1 ] && grep -qx 'POST /v1/check package-lock.json' "$TF_DIR/req.log"; } \
  && ok || bad "C1 affected: rc=$rc out=$out req=$(cat "$TF_DIR/req.log")"

# C2 clean
tf_mode clean; run "$T/r-lock"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: none known (2 checked in 1 lockfile(s))' <<<"$out" \
  && [ "$(jq -r .state <<<"$(summary "$out")")" = clean ]; } && ok || bad "C2 clean: rc=$rc out=$out"

# C3 HTTP 500
tf_mode 500; run "$T/r-lock"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (HTTP 500)' <<<"$out" \
  && ! grep -q 'none known' <<<"$out" && [ "$(jq -r .state <<<"$(summary "$out")")" = failed ]; } \
  && ok || bad "C3 500: rc=$rc out=$out"

# C4 no lockfile
mkrepo "$T/r-none"
tf_mode affected; run "$T/r-none"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: nothing to check (no lockfile)' <<<"$out" \
  && [ "$(tf_posts)" = 0 ] && [ "$(jq -r .state <<<"$(summary "$out")")" = nothing ]; } \
  && ok || bad "C4 nothing: rc=$rc out=$out posts=$(tf_posts)"

# C5 429, C6 html, C7 timeout
tf_mode 429; run "$T/r-lock"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (HTTP 429, rate limited)' <<<"$out"; } && ok || bad "C5 429: rc=$rc out=$out"
tf_mode html; run "$T/r-lock"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (bad answer)' <<<"$out"; } && ok || bad "C6 html: rc=$rc out=$out"
tf_mode noarray; run "$T/r-lock"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (bad answer)' <<<"$out"; } && ok || bad "C6b no affected array: rc=$rc out=$out"
tf_mode slow; tf_reset
out=$(PROJECT_21_TIMEOUT_S=5 "$CHECK" "$T/r-lock" 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (curl rc=28)' <<<"$out" && ! grep -q 'none known' <<<"$out"; } \
  && ok || bad "C7 timeout: rc=$rc out=$out"

# C8 partial coverage and checked:0
tf_mode partial; run "$T/r-lock"
s=$(summary "$out")
{ [ "$rc" = 0 ] && [ "$(jq -r .state <<<"$s")" = partial ] && [ "$(jq -r .skipped <<<"$s")" = 1 ] \
  && grep -qF 'project-21: skipped {"file":"go.sum","reason":"partial_coverage"}' <<<"$out" \
  && ! grep -q 'none known' <<<"$out"; } && ok || bad "C8 partial: rc=$rc out=$out"
tf_mode zero; run "$T/r-lock"
s=$(summary "$out")
{ [ "$rc" = 0 ] && [ "$(jq -r .state <<<"$s")" = partial ] && [ "$(jq -r .reason <<<"$s")" = "0 dependencies checked" ] \
  && ! grep -q 'none known' <<<"$out"; } && ok || bad "C8 zero: rc=$rc out=$out"

# C9 discovery: nested and exact names are sent, near-misses and untracked files are not
mkrepo "$T/r-many" apps/web/yarn.lock requirements.txt requirements-dev.txt package-lock.json.bak npm-shrinkwrap.json
mkdir -p "$T/r-many/node_modules/x" && printf '{}\n' > "$T/r-many/node_modules/x/package-lock.json"
tf_mode clean; run "$T/r-many"
{ [ "$rc" = 0 ] && [ "$(tf_fields)" = "yarn.lock,requirements.txt" ] \
  && grep -qxF 'project-21: none known (2 checked in 2 lockfile(s))' <<<"$out"; } \
  && ok || bad "C9 discovery: fields=$(tf_fields) out=$out"

# C10 the knob off
tf_mode affected; tf_reset
out=$(PROJECT_21_ENABLED=0 "$CHECK" "$T/r-lock" 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qxF 'project-21: off (lib.project-21.project-21_enabled=0)' <<<"$out" && [ "$(tf_posts)" = 0 ] \
  && [ "$(jq -r .state <<<"$(summary "$out")")" = off ]; } && ok || bad "C10 off: rc=$rc out=$out posts=$(tf_posts)"

# C11 not a git worktree
mkdir -p "$T/plain" && printf '{}\n' > "$T/plain/package-lock.json"
tf_mode affected; run "$T/plain"
{ [ "$rc" = 0 ] && grep -qxF 'project-21: check failed (not a git worktree)' <<<"$out" && [ "$(tf_posts)" = 0 ]; } \
  && ok || bad "C11 not git: rc=$rc out=$out"

# C13 usage errors exit 2
"$CHECK" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "C13 no worktree argument: rc=$rc"
"$CHECK" "$T/r-lock" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "C13 unknown flag: rc=$rc"

# C14 --out writes the result JSON with the head and the raw answer fields
tf_mode affected; run "$T/r-lock" --out "$T/res.json" --head deadbeefcafe0000000000000000000000000000
{ [ "$rc" = 0 ] && [ "$(jq -r .state "$T/res.json")" = affected ] && [ "$(jq -r .head "$T/res.json")" = deadbeefcafe0000000000000000000000000000 ] \
  && [ "$(jq -r '.files|join(",")' "$T/res.json")" = package-lock.json ] && [ "$(jq -r '.affected|length' "$T/res.json")" = 2 ] \
  && [ "$(jq -r '.affected[0].fixed_in' "$T/res.json")" = 4.17.21 ]; } && ok || bad "C14 --out: $(cat "$T/res.json" 2>&1)"

echo "project-21-check.bh-8079: PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
