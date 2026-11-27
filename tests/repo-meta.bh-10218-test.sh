#!/bin/bash
# tests/repo-meta.bh-10218-test.sh — BH-10218 W2: bin/lib/repo-meta.sh and the
# change-mark hook in bin/lib/gh-repo-token.sh.
#
#   L  repo_meta_get: the first call makes 1 `repos/<slug>` read, 10 more calls
#      in separate processes make 0. 11 gh_repo_use_token calls with
#      repo_meta_arm, in 11 processes, make 1 visibility probe.
#   W  a fixture `push` wake (and separately a `repo` wake) makes the next get
#      read once, then 0. A `pr` wake and another repo's push make 0.
#   A  age: REPO_META_BACKSTOP_S - 1 serves, REPO_META_BACKSTOP_S reads.
#   F  a failed read (75, 44, a body with no default_branch) writes nothing.
#   Z  REPO_META_BACKSTOP_S=0 reads every time; the code fallback is 86400.
#   D  the feed cannot tell (down, stale): every call reads.
#   O  old 2-column probe rows: served as before with the hook undefined (the
#      merge conductor), read once then 3 columns with the hook armed.
#   S  slugs map to files exactly (o/r vs o/r-c).
#   C  the production entry point: 11 runs of bin/ci-shard-watch.sh make 1
#      visibility probe, and each of the 5 callers arms the memo.
# Fixture clocks (REPO_META_NOW) and fixture GitHub answers only.
#
# Run from anywhere: bash tests/repo-meta.bh-10218-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wake-feed-fixture.bh-10218.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/repo-meta.sh"
TOK="$DIR/bin/lib/gh-repo-token.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "repo-meta: 0 passed, 1 failed"; exit 1; }

NOW=$(date +%s)   # the one clock read
export HARNESS="$T/h"; mkdir -p "$HARNESS/env" "$T/fakebin" "$T/rest"
export PR_SNAPSHOT_TTL_S=0 PR_SNAPSHOT_FEED_STALE_S=900 HARNESS_TEST_SANDBOX=1
unset GH_TOKEN GITHUB_TOKEN H REPO_META_BACKSTOP_S REPO_META_NOW
wf_init

# gh_rest: the fixture answer for a path, logged. $T/rest-rc forces a code.
cat > "$T/rest-stub.sh" <<'EOF'
gh_rest() {
  local m="$1" p="$2" f
  printf 'REST %s %s\n' "$m" "$p" >> "$T/rest.log"
  if [ -s "$T/rest-rc" ]; then GH_REST_STATUS=500; return "$(cat "$T/rest-rc")"; fi
  f="$T/rest/$(printf '%s' "$p" | tr '/' '_')"
  [ -r "$f" ] || { GH_REST_STATUS=000; return 75; }
  GH_REST_STATUS=200; cat "$f"
}
EOF
export T
: > "$T/rest.log"
rest_n() { grep -c "^REST GET repos/$1\$" "$T/rest.log" 2>/dev/null || true; }
rmd() { ( . "$WF_STUBS"; . "$T/rest-stub.sh"; . "$LIB"; "$@" ); }
get() { rmd repo_meta_get "$1" default_branch 2>/dev/null; }
printf '{"id":1,"full_name":"o/r","default_branch":"main"}' > "$T/rest/repos_o_r"
printf '{"id":2,"full_name":"o/r-c","default_branch":"trunk"}' > "$T/rest/repos_o_r-c"
wf_wake o/r pr 3 10
wf_wake o/r-c pr 4 11

# ══ L ══
eq "L first get answers main" "$(get o/r)" main
eq "L first get reads GitHub once" "$(rest_n o/r)" 1
for _ in 1 2 3 4 5 6 7 8 9 10; do get o/r > "$T/out"; done
eq "L the 10th get still answers main" "$(cat "$T/out")" main
eq "L 10 more gets make 0 reads" "$(rest_n o/r)" 1
MEMO="$HARNESS/state/prr-default-branch/o_r"
[ -s "$MEMO.meta" ] && ok || bad "L the stamp $MEMO.meta was not written"
IFS=$'\t' read -r _ MK < "$MEMO.meta" 2>/dev/null
eq "L the stamp carries the mark read BEFORE the read (wake id 10)" "${MK:-}" 10

# ══ S ══
eq "S o/r-c answers its own branch" "$(get o/r-c)" trunk
eq "S o/r-c read once" "$(rest_n o/r-c)" 1
eq "S o/r still served" "$(get o/r)" main
eq "S o/r still 1 read" "$(rest_n o/r)" 1

# ══ W ══
wf_wake o/r pr 3 12
get o/r >/dev/null; eq "W a pr wake reads nothing" "$(rest_n o/r)" 1
wf_wake o/r-c push "$(printf 'b%.0s' {1..40})" 13
get o/r >/dev/null; eq "W another repo's push reads nothing" "$(rest_n o/r)" 1
printf '{"id":1,"full_name":"o/r","default_branch":"trunk2"}' > "$T/rest/repos_o_r"
wf_wake o/r push "$(printf 'a%.0s' {1..40})" 14
eq "W after a push wake the get reads the new branch" "$(get o/r)" trunk2
eq "W a push wake makes 1 read" "$(rest_n o/r)" 2
get o/r >/dev/null; eq "W then 0" "$(rest_n o/r)" 2
wf_wake o/r repo 1 15
get o/r >/dev/null; eq "W a repo wake makes 1 read" "$(rest_n o/r)" 3
get o/r >/dev/null; eq "W then 0 again" "$(rest_n o/r)" 3

# ══ A ══
ST=$(cut -f1 "$MEMO.meta")
REPO_META_NOW=$((ST + 86399)) get o/r >/dev/null; eq "A age 86399 serves" "$(rest_n o/r)" 3
REPO_META_NOW=$((ST + 86400)) get o/r >/dev/null; eq "A age 86400 reads" "$(rest_n o/r)" 4

# ══ F ══
wf_wake o/r push "$(printf 'c%.0s' {1..40})" 16
cp "$MEMO" "$T/memo.before"; cp "$MEMO.meta" "$T/meta.before"
for code in 75 44; do
  echo "$code" > "$T/rest-rc"
  rc=0; get o/r > "$T/out" || rc=$?
  eq "F a $code read returns $code" "$rc" "$code"
  eq "F a $code read prints nothing" "$(cat "$T/out")" ""
  cmp -s "$MEMO" "$T/memo.before" && cmp -s "$MEMO.meta" "$T/meta.before" && ok || bad "F a $code read changed the memo or the stamp"
done
: > "$T/rest-rc"
printf '{"id":1,"full_name":"o/r"}' > "$T/rest/repos_o_r"
rc=0; get o/r > "$T/out" || rc=$?
eq "F a body with no default_branch returns 75" "$rc" 75
cmp -s "$MEMO.meta" "$T/meta.before" && ok || bad "F a bad body changed the stamp"
printf '{"id":1,"full_name":"o/r","default_branch":"trunk2"}' > "$T/rest/repos_o_r"
N=$(rest_n o/r); get o/r >/dev/null
eq "F the next call reads again" "$(rest_n o/r)" $((N + 1))
get o/r >/dev/null; eq "F then serves" "$(rest_n o/r)" $((N + 1))

# ══ Z ══
N=$(rest_n o/r)
REPO_META_BACKSTOP_S=0 rmd repo_meta_get o/r default_branch >/dev/null
REPO_META_BACKSTOP_S=0 rmd repo_meta_get o/r default_branch >/dev/null
eq "Z backstop 0 reads every call" "$(rest_n o/r)" $((N + 2))
eq "Z the code fallback is 86400" "$(REPO_META_BACKSTOP_S=garbage rmd repo_meta_backstop)" 86400
eq "Z the registry default is 86400" "$(rmd repo_meta_backstop)" 86400

# ══ D ══
get o/r >/dev/null; N=$(rest_n o/r)
wf_down; get o/r >/dev/null; get o/r >/dev/null
eq "D feed down: every call reads" "$(rest_n o/r)" $((N + 2))
[ -e "$MEMO.meta" ] && bad "D a read with no mark must remove the stamp" || ok
wf_up; get o/r >/dev/null; get o/r >/dev/null
eq "D feed back: one read, then served" "$(rest_n o/r)" $((N + 3))
wf_stale; get o/r >/dev/null
eq "D feed stale: reads" "$(rest_n o/r)" $((N + 4))
wf_fresh

# ══ L (ladder) and O ══
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/gh.log"
case "$*" in
  "auth token") echo ghp_fixture ;;
  "api repos/o/r -q .id"|"api repos/o/r-c -q .id") echo 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
: > "$T/gh.log"
probes() { grep -c "^api repos/$1 -q .id\$" "$T/gh.log" 2>/dev/null || true; }
lad() { ( export PATH="$T/fakebin:$PATH"; . "$WF_STUBS"; . "$TOK"; . "$LIB"; "$@" ); }
for _ in 1 2 3 4 5 6 7 8 9 10 11; do
  lad eval 'repo_meta_arm && gh_repo_use_token o/r; echo "rc=$? rung=${_GHRT_REPO_TOK[o/r]}"' > "$T/out" 2>/dev/null
done
eq "L 11 armed gh_repo_use_token calls make 1 probe" "$(probes o/r)" 1
eq "L the 11th call still answers the default rung" "$(cat "$T/out")" "rc=0 rung=default"
PF="$HARNESS/state/repo-meta/probe/o_r.pat"
eq "L the memo row has 3 columns, the 3rd the mark" "$(awk -F'\t' '{print NF ":" ($3 ~ /^[0-9]+$/)}' "$PF")" "3:1"
wf_wake o/r push "$(printf 'd%.0s' {1..40})" 17
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
eq "W a push wake voids the probe memo: 1 more probe, then 0" "$(probes o/r)" 2
# O: a 2-column row
printf '%s\tdefault\n' "$(date +%s)" > "$PF"
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
eq "O armed: a 2-column row is no memo (1 probe)" "$(probes o/r)" 3
eq "O and is rewritten with a mark" "$(awk -F'\t' '{print NF}' "$PF")" 3
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
eq "O then served" "$(probes o/r)" 3
mkdir -p "$T/mc"
printf '%s\tdefault\n' "$(date +%s)" > "$T/mc/o_r.pat"
lad eval '_GHRT_PROBE_MEMO_DIR=$T/mc; gh_repo_use_token o/r' >/dev/null 2>&1
eq "O unarmed (the conductor): a 2-column row is served" "$(probes o/r)" 3
printf '%s\tdefault\t5\n' "$(date +%s)" > "$T/mc/o_r.pat"
lad eval '_GHRT_PROBE_MEMO_DIR=$T/mc; gh_repo_use_token o/r' >/dev/null 2>&1
eq "O unarmed: a 3-column row is served, the mark ignored" "$(probes o/r)" 3
wf_down
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
lad eval 'repo_meta_arm && gh_repo_use_token o/r' >/dev/null 2>&1
eq "D feed down: the ladder probes every call" "$(probes o/r)" 5
wf_up

# ══ C: the production entry point ══
# The lane runs from a symlinked copy of bin/ whose jobs-client.sh is the wake
# fixture: gh-budget.sh sources the client from its own bin/, so a stub in the
# caller's shell would be replaced by the real client.
: > "$T/gh.log"
scratch_rm "$HARNESS/state/repo-meta"
mkdir -p "$T/lane"
cp -rs "$DIR/bin" "$T/lane/bin"
rm -f "$T/lane/bin/jobs-client.sh"
printf '. "%s"\n' "$WF_STUBS" > "$T/lane/bin/jobs-client.sh"
for _ in 1 2 3 4 5 6 7 8 9 10 11; do
  env PATH="$T/fakebin:$PATH" CI_SHARD_WATCH_REPO=o/r-c HARNESS_DEPLOYMENT_FILE=/dev/null \
    bash "$T/lane/bin/ci-shard-watch.sh" > /dev/null 2> "$T/csw.err"
done
eq "C 11 runs of bin/ci-shard-watch.sh make 1 visibility probe" "$(probes o/r-c)" 1
grep -q 'unreadable' "$HARNESS/logs/ci-shard-watch.log" 2>/dev/null && ok \
  || bad "C ci-shard-watch did not reach its run read (log: $(tail -2 "$HARNESS/logs/ci-shard-watch.log" 2>/dev/null))"
for f in bin/main-red-pr-pair.sh bin/pr-owner-sweep.sh bin/overlap-guard.sh bin/ci-shard-watch.sh bin/fly-pool.sh; do
  [ "$(grep -v '^[[:space:]]*#' "$DIR/$f" | grep -c 'repo-meta.sh.*repo_meta_arm')" -gt 0 ] && ok || bad "C $f does not arm the repo-meta memo"
done

# No network: every GitHub answer was a fixture's.
# ci-shard-watch's own reads (the budget probe, the run list) answer rc 1.
ALLOWED='^(auth token|api rate_limit|api repos/o/r(-c)? -q \.id|api repos/o/r-c/actions/.*)$'
[ "$(grep -cvE "$ALLOWED" "$T/gh.log")" = 0 ] && ok \
  || bad "a gh call the fixture does not serve: $(grep -vE "$ALLOWED" "$T/gh.log" | head -3)"

echo "repo-meta: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
