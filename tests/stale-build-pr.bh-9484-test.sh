#!/bin/bash
# tests/stale-build-pr.bh-9484-test.sh — BH-9484 (item 5 of #9406, slice C1):
# the stale-build reaper opens the PR from a dead build's branch when the
# branch holds finished commits, no PR in any state, and a tip newer than the
# build start, through the item 3 path (ppr_after_reap: pool rebase when behind
# main, lead review, pr_created beat). Every other branch opens nothing, and
# observe mode only logs `pr=<outcome>`.
#
# Section L calls sbp_decide / sbp_open (bin/lib/stale-build-pr.sh) directly.
# Section R runs the real bin/stale-build-reaper.sh --now <epoch>.
#
# The scratch harness holds the real libs (the reaper's closure, hold-push.sh,
# hold.sh, gh-pr-create.sh, pr-trailers.sh, ppr-review.sh, fleet-conf.sh,
# alert-line.sh). Stubs: a scratch bin/lib/merge-conductor-lib.sh (the
# conductor's pool-rebase functions, recorded), bin/beat.sh and
# bin/lead-verdict.sh (recorded), and on PATH `gh` (REST from fixture files
# keyed by the API path; every call goes to fx/GH.log; `pr create` and
# POST .../pulls go to fx/CREATES.log) and `curl` (the console feed, the close
# POST and the jobs worker). bin/lib/gh-repo-token.sh is not installed, so the
# reads run on ambient auth, except case L-TOKEN, which installs a stub of it.
# 0 network calls. Every case has its own keys (SB-<n>).
# Run from anywhere: tests/stale-build-pr.bh-9484-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin" "$T/fx"
X="$T/fx"

# The conductor stub, written before the closure copy (no-clobber keeps it).
cat > "$T/bin/lib/merge-conductor-lib.sh" <<'EOF'
# scratch stub of the conductor lib: its pool-rebase functions, recorded.
[ -f "$T_FX/MC_EXIT" ] && exit 1
mc_pool_rebase_enabled() { return 0; }
mc_pool_rebase_enqueue() { printf '%s\n' "$*" >> "$T_FX/REBASE.log"; return 6; }
mc_num_of_url() { printf '%s' "${1##*/}"; }
mc_pool_rebase_key() { printf 'RB-%s-%s' "$1" "${2:0:8}"; }
EOF
for S in bin/stale-build-reaper.sh bin/jobs-client.sh bin/alert-line.sh bin/fleet-conf.sh \
         bin/lib/hold-push.sh bin/lib/hold.sh bin/lib/gh-pr-create.sh bin/lib/pr-trailers.sh bin/lib/ppr-review.sh; do
  scratch_install_closure "$S" "$T" >/dev/null || { echo "FAIL: scratch_install_closure $S"; exit 1; }
done
[ -f "$T/bin/lib/stale-build-pr.sh" ] && [ -f "$T/bin/lib/pool-push-rejected.sh" ] \
  || { echo "FAIL: the reaper's closure did not bring bin/lib/stale-build-pr.sh and bin/lib/pool-push-rejected.sh"; exit 1; }
rm -f "$T/bin/lib/gh-repo-token.sh"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
bh-os Org/bhrepo - - 2 hub
noslug-os - https://n.example /api/board 2 local
EOF
export FLEET_CONF="$T/fleet.conf"
unset FLY_MACHINES_ROWS STALE_REAPER_ACT STALE_REAPER_MINUTES STALE_REAPER_MAX STALE_REAPER_PAGE STALE_REAPER_HTTP_TIMEOUT_S STALE_REAPER_OPEN_PR
unset GH_REPO GH_TOKEN POOL_PUSH_LANDED_REBASE
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=fixture-secret-example\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/BEAT.log"\n' "$X" > "$T/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/LV.log"\n' "$X" > "$T/bin/lead-verdict.sh"
chmod +x "$T/bin/beat.sh" "$T/bin/lead-verdict.sh"
printf '#!/bin/bash\n[ -f "%s/LOCK_HELD" ] && exit 1\nexit 0\n' "$X" > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# gh. `gh api [-i] [--paginate] [-X M] <path> ...`: fixture fx/<path, with
# / ? & = : as _>.code and .body; no fixture is a 404. A code of TIMEOUT exits
# 124, as a cut read does. Without -i a non-200 is rc 1 (gh's own shape).
# `gh pr create` answers https://github.com/$GH_REPO/pull/77 (fx/CREATE_FAIL:
# rc 1); `gh pr list` names no PR; POST .../pulls answers 201 (CREATE_FAIL: 422).
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
X="$T_FX"
printf '%s\t%s\n' "${GH_TOKEN:-}" "$*" >> "$X/GH.log"
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    create)
      printf '%s\n' "$*" >> "$X/CREATES.log"
      P=""; for a; do [ "$P" = 1 ] && { cp "$a" "$X/BODY.md"; P=""; }; [ "$a" = --body-file ] && P=1; done
      [ -f "$X/CREATE_FAIL" ] && { echo "fixture: create refused" >&2; exit 1; }
      printf 'https://github.com/%s/pull/77\n' "${GH_REPO:-Org/none}"; exit 0 ;;
  esac
  exit 1
fi
[ "${1:-}" = api ] || exit 1
shift
INC=0; M=GET; P=""; SK=""
for a; do
  if [ -n "$SK" ]; then [ "$SK" = -X ] && M="$a"; SK=""; continue; fi
  case "$a" in
    -i) INC=1 ;;
    -X|-f|-F|-q|-H|--jq) SK="$a" ;;
    -*) ;;
    *) [ -n "$P" ] || P="$a" ;;
  esac
done
if [ "$M" = POST ]; then
  case "$P" in */pulls)
    printf 'POST %s\n' "$P" >> "$X/CREATES.log"
    if [ -f "$X/CREATE_FAIL" ]; then printf 'HTTP/2.0 422 X\r\n\r\n{"message":"fixture: refused"}\n'; exit 1; fi
    printf 'HTTP/2.0 201 X\r\n\r\n{"html_url":"https://github.com/%s/pull/77"}\n' "${P%/pulls}"; exit 0 ;;
  esac
  exit 1
fi
K=$(printf '%s' "$P" | tr '/?&=:' '_____')
C=$(cat "$X/$K.code" 2>/dev/null || echo 404)
[ "$C" = TIMEOUT ] && exit 124
if [ "$INC" = 1 ]; then
  printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n' "$C"
  cat "$X/$K.body" 2>/dev/null || echo '{"message":"Not Found"}'
  [ "$C" = 200 ]; exit $?
fi
[ "$C" = 200 ] || { echo "gh: HTTP $C" >&2; exit 1; }
cat "$X/$K.body" 2>/dev/null
EOF
chmod +x "$T/fakebin/gh"

# curl: the console (stale feed, close POST) and the jobs worker (empty
# queue, machines and jobs). A tracker_adapter.<p> settings read answers the
# value in fx ADAPTER_<p> when that file exists. Everything else is rc 7.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
X="$T_FX"; MODE=""; METHOD=GET; BODY=""; P=0
for a; do
  [ "$P" = 1 ] && { BODY="$a"; P=0; }
  [ "$P" = 2 ] && { METHOD="$a"; P=0; }
  case "$a" in -d|--data-binary) P=1;; -X) P=2;; esac
  case "$a" in
    *api/builds/stale*) MODE=feed;;
    *api/builds/close*) MODE=close;;
    *api/queue*) MODE=queue;;
    *api/machines*) MODE=machines;;
    *api/jobs*) MODE=jobs;;
    *api/settings/tracker_adapter.*) MODE=adapter; AP="${a##*tracker_adapter.}";;
  esac
done
case "$MODE" in
  feed) cat "$X/FEED.json"; exit 0 ;;
  close)
    printf '%s\n' "$BODY" >> "$X/POSTS.jsonl"
    N=$(printf '%s' "$BODY" | jq '.closed | length')
    printf '{"ok":true,"requested":%s,"updated":%s}\n' "$N" "$N"; exit 0 ;;
  queue) printf '{"queue":[]}\n200\n'; exit 0 ;;
  machines) printf '{"machines":[]}\n200\n'; exit 0 ;;
  jobs)
    if [ "$METHOD" = PATCH ]; then printf '%s\n' "$BODY" >> "$X/PATCHES.log"; printf '{"ok":true}\n200\n'; exit 0; fi
    printf '{"jobs":[]}\n200\n'; exit 0 ;;
  adapter)
    [ -f "$X/ADAPTER_$AP" ] || exit 7
    printf '{"setting":{"key":"tracker_adapter.%s","value":"%s"}}\n200\n' "$AP" "$(cat "$X/ADAPTER_$AP")"; exit 0 ;;
esac
exit 7
EOF
chmod +x "$T/fakebin/curl"

# ---------- fixtures ----------
fxk() { printf '%s' "$1" | tr '/?&=:' '_____'; }
fx() { # fx <api-path> <code> [body]
  local k; k=$(fxk "$1"); printf '%s' "$2" > "$X/$k.code"; printf '%s' "${3:-}" > "$X/$k.body"; }
SHA=1111111111111111111111111111111111111111
HEAD77=2222222222222222222222222222222222222222
TS=202611141000                       # every build dir's start: 2026-11-14T10:00Z
TIP_OK=2026-11-14T10:05:00Z
refs() { # refs <slug> <stem> <branch...>
  local slug="$1" stem="$2"; shift 2
  local j; j=$(printf '%s\n' "$@" | jq -R --arg s "$SHA" 'select(. != "") | {ref: ("refs/heads/" + .), object: {sha: $s}}' | jq -sc .)
  fx "repos/$slug/git/matching-refs/heads/$stem" 200 "$j"; }
pulls() { fx "repos/$1/pulls?state=all&head=${1%%/*}:$2" "$3" "${4:-[]}"; }
compare() { # compare <slug> <branch> <behind> <files> <tip-date> <subject...>
  local slug="$1" br="$2" behind="$3" files="$4" tipd="$5"; shift 5
  local c; c=$(printf '%s\n' "$@" | jq -R --arg d "$tipd" '{commit: {message: (. + "\n\nbody line"), committer: {date: $d}}}' | jq -sc .)
  local f; f=$(tr ' ' '\n' <<<"$files" | jq -R 'select(. != "") | {filename: .}' | jq -sc .)
  fx "repos/$slug/compare/main...$br" 200 "$(jq -nc --argjson c "$c" --argjson f "$f" --argjson b "$behind" '{ahead_by: ($c|length), behind_by: $b, commits: $c, files: $f}')"; }
pr77() { fx "repos/$1/pulls/77" 200 "{\"head\":{\"sha\":\"$HEAD77\"}}"; }
plan() { # plan <slug> <key> <branch> — the branch's .harness/specs/<KEY>/plan.md
  fx "repos/$1/contents/.harness/specs/$2/plan.md?ref=$3" 200 "{\"content\":\"$(printf '# %s plan\n\n## Why\n\nThe dead build of %s left work.\n' "$2" "$2" | base64 -w0)\"}"; }
# good <n> [branch-suffix] [behind] — a branch that opens, for key SB-<n>
good() {
  local n="$1" suf="${2:-}" behind="${3:-0}"
  refs Org/alpha "ticket/sb-$n" "ticket/sb-$n$suf"
  pulls Org/alpha "ticket/sb-$n$suf" 200
  compare Org/alpha "ticket/sb-$n$suf" "$behind" "bin/x.sh" "$TIP_OK" "feat(SB-$n): the work"
  pr77 Org/alpha
}
bk() { printf 'build:alpha-os:SB-%s:alpha-os-SB-%s-%s' "$1" "$1" "${2:-$TS}"; }
reset() {
  scratch_rm "$X"; mkdir -p "$X"
  : > "$X/GH.log"; : > "$X/CREATES.log"; : > "$X/POSTS.jsonl"; : > "$X/PATCHES.log"
  : > "$T/logs/stale-build-reaper.log"; : > "$T/logs/ALERTS.log"
}
ncreate() { grep -c . "$X/CREATES.log" 2>/dev/null || true; }
napi()    { grep -c "	api " "$X/GH.log" 2>/dev/null || true; }
nposts()  { grep -c . "$X/POSTS.jsonl" 2>/dev/null || true; }
nalerts() { grep -c "\[stale-build-reaper\]" "$T/logs/ALERTS.log" 2>/dev/null || true; }
logged()  { cat "$T/logs/stale-build-reaper.log" 2>/dev/null; }

# lib <fn> <args...> — the lib in a subshell, as the reaper runs it. Prints
# "rc=<n> <outcome>" and "alive" on a second line when the shell survived.
lib() {
  ( export HARNESS="$T" T_FX="$X" PATH="$T/fakebin:$PATH" TMPDIR="$X/tmp"
    mkdir -p "$TMPDIR"
    say() { printf '%s\n' "$*" >> "$X/SAY.log"; }
    # shellcheck source=bin/lib/stale-build-pr.sh
    . "$T/bin/lib/stale-build-pr.sh" || { echo "rc=9 the lib did not load"; exit 0; }
    if [ "$1" = decide ]; then shift; sbp_decide "$@"; rc=$?; echo "rc=$rc $SBP_OUT"
    else shift; : > "$X/OUT"; sbp_open "$@" "$X/OUT"; rc=$?; echo "rc=$rc $(head -n 1 "$X/OUT")"; fi
    echo alive )
}
out1() { head -n 1 <<<"$1"; }
# expect_open <label> <want-prefix> <open args...>
expect_open() {
  local label="$1" want="$2" o; shift 2
  o=$(lib open "$@")
  case "$(out1 "$o")" in "rc=0 $want"*) ok ;; *) bad "$label: want 'rc=0 $want...', got '$(out1 "$o")' (say: $(tr '\n' '|' < "$X/SAY.log" 2>/dev/null))" ;; esac
  [ "$(ncreate)" = 1 ] && ok || bad "$label: want 1 PR create, got $(ncreate): $(cat "$X/CREATES.log")"
}
# expect_none <label> <word-and-prefix> <open args...> — no PR create
expect_none() {
  local label="$1" want="$2" o; shift 2
  o=$(lib open "$@")
  case "$(out1 "$o")" in "rc=1 $want"*) ok ;; *) bad "$label: want 'rc=1 $want...', got '$(out1 "$o")'" ;; esac
  [ "$(ncreate)" = 0 ] && ok || bad "$label: no PR create may run (creates: $(ncreate))"
}

# ===================== L: the lib =====================

# ---------- L1 newest -r3, a feat and a spec commit, behind 0: opened ----------
reset
refs Org/alpha ticket/sb-1 ticket/sb-1 ticket/sb-1-r2 ticket/sb-1-r3
pulls Org/alpha ticket/sb-1-r3 200
compare Org/alpha ticket/sb-1-r3 0 ".harness/specs/SB-1/plan.md bin/x.sh" "$TIP_OK" "spec(SB-1): the plan" "feat(SB-1): the work"
pr77 Org/alpha; plan Org/alpha SB-1 ticket/sb-1-r3
expect_open "L1" "opened https://github.com/Org/alpha/pull/77 rebase=current review=requested" alpha-os SB-1 executing "$(bk 1)"
grep -q -- '--head ticket/sb-1-r3 --base main ' "$X/CREATES.log" && ok || bad "L1 the create is from the newest branch -r3 to main: $(cat "$X/CREATES.log")"
# L-BEAT: the pr_created beat carries the dead build's own bkey
B=$(head -n 1 "$X/BEAT.log" 2>/dev/null)
[ "$(jq -r .bkey <<<"$B" 2>/dev/null)" = "$(bk 1)" ] && [ "$(jq -r .stage <<<"$B" 2>/dev/null)" = pr_created ] \
  && [ "$(jq -r .pr_url <<<"$B" 2>/dev/null)" = https://github.com/Org/alpha/pull/77 ] && ok || bad "L-BEAT the pr_created beat: '$B'"
# L-REVIEW: one lead review request for the PR head
grep -q "^request Org/alpha 77 $HEAD77" "$X/LV.log" && [ "$(grep -c . "$X/LV.log")" = 1 ] && ok || bad "L-REVIEW one review request for the PR head: $(cat "$X/LV.log" 2>/dev/null)"
# L-BODY (board project): the heading, the plan's Why, the footer, no Closes
grep -q '^## Opened by the stale-build reaper' "$X/BODY.md" && grep -q 'died in executing' "$X/BODY.md" && grep -q "$SHA" "$X/BODY.md" \
  && grep -q 'The dead build of SB-1 left work.' "$X/BODY.md" && grep -q 'Generated with \[Claude Code\]' "$X/BODY.md" \
  && ok || bad "L-BODY the body: $(cat "$X/BODY.md" 2>/dev/null)"
grep -q '^Closes #' "$X/BODY.md" && bad "L-BODY a board project gets no Closes line" || ok
grep -q '^Harness-Ticket: SB-1$' "$X/BODY.md" && ok || bad "L-BODY the trailers are applied: $(tail -3 "$X/BODY.md")"
[ ! -s "$X/REBASE.log" ] && ok || bad "L1 behind 0 queues no pool rebase: $(cat "$X/REBASE.log")"
[ -d "$X/tmp" ] && [ -z "$(ls -A "$X/tmp")" ] && ok || bad "L1 the LOCAL dir is removed: $(ls -A "$X/tmp" 2>&1)"

# ---------- L2 the bare branch, two code commits, behind 3: rebase queued ----------
reset; good 2 "" 3
compare Org/alpha ticket/sb-2 3 "bin/x.sh tests/x-test.sh" "$TIP_OK" "feat(SB-2): one" "fix(SB-2): two"
expect_open "L2" "opened https://github.com/Org/alpha/pull/77 rebase=queued review=requested" alpha-os SB-2 planning "$(bk 2)"
# L-REBASE: the conductor's enqueue got the branch, its head and the PR URL
[ "$(grep -c . "$X/REBASE.log" 2>/dev/null)" = 1 ] && grep -q "^Org/alpha alpha-os ticket/sb-2 $SHA https://github.com/Org/alpha/pull/77$" "$X/REBASE.log" \
  && ok || bad "L-REBASE one pool rebase with the branch and the PR URL: $(cat "$X/REBASE.log" 2>/dev/null)"

# ---------- L3 -r2 newest with -r1 present: picks -r2 ----------
reset; good 3 -r2
refs Org/alpha ticket/sb-3 ticket/sb-3-r1 ticket/sb-3-r2
expect_open "L3" "opened " alpha-os SB-3 executing "$(bk 3)"
grep -q -- '--head ticket/sb-3-r2 ' "$X/CREATES.log" && ok || bad "L3 picks -r2: $(cat "$X/CREATES.log")"

# ---------- L4 the tip exactly at the build start minute: opens ----------
reset; good 4
compare Org/alpha ticket/sb-4 0 "bin/x.sh" "2026-11-14T10:00:00Z" "feat(SB-4): work"
expect_open "L4" "opened " alpha-os SB-4 executing "$(bk 4)"

# ---------- L21 near miss: a spec() commit of ANOTHER key with code files: opens ----------
reset; good 21
compare Org/alpha ticket/sb-21 0 "bin/x.sh" "$TIP_OK" "spec(SB-OTHER): not this key's plan"
expect_open "L21" "opened " alpha-os SB-21 executing "$(bk 21)"

# ---------- L-ISSUES an issues board: Closes #<n>, the issue title, the hold read ----------
reset
refs Org/bhrepo ticket/bh-12 ticket/bh-12
pulls Org/bhrepo ticket/bh-12 200
compare Org/bhrepo ticket/bh-12 0 "bin/y.sh" "$TIP_OK" "feat(BH-12): work"
fx "repos/Org/bhrepo/issues/12" 200 '{"state":"open","title":"Fix the thing","labels":[{"name":"ai-build"}]}'
fx "repos/Org/bhrepo/issues/12/comments?per_page=100" 200 '[]'
pr77 Org/bhrepo
expect_open "L-ISSUES" "opened https://github.com/Org/bhrepo/pull/77" bh-os BH-12 executing "build:bh-os:BH-12:bh-os-BH-12-$TS"
grep -q '^Closes #12$' "$X/BODY.md" && ok || bad "L-BODY an issues board gets Closes #12: $(cat "$X/BODY.md" 2>/dev/null)"
grep -q -- '--title BH-12: Fix the thing ' "$X/CREATES.log" && ok || bad "L-ISSUES the title is the issue's: $(cat "$X/CREATES.log")"
grep -q 'api repos/Org/bhrepo/issues/12$' "$X/GH.log" && ok || bad "L-ISSUES the hold read the issue: $(cat "$X/GH.log")"

# ---------- L-ADAPTER the tracker seam decides the issues mode, not fleet.conf ----------
# alpha-os has a board prefix in fleet.conf column 4, but its tracker_adapter
# settings row says github-issues. The row wins (bin/lib/tracker.sh
# tracker_kind): the PR body says Closes #32. (bin/lib/hold-push.sh still
# reads fleet.conf column 4 for its own issue read; it is not this lib's.)
reset; good 32
printf 'github-issues' > "$X/ADAPTER_alpha-os"
fx "repos/Org/alpha/issues/32" 200 '{"state":"open","title":"Adapter row","labels":[{"name":"ai-build"}]}'
JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
  expect_open "L-ADAPTER" "opened https://github.com/Org/alpha/pull/77" alpha-os SB-32 executing "$(bk 32)"
grep -q '^Closes #32$' "$X/BODY.md" && ok || bad "L-ADAPTER the settings row github-issues gives Closes #32: $(cat "$X/BODY.md" 2>/dev/null)"

# ---------- L-TOKEN the repo token is armed for every read ----------
reset; good 40
cat > "$T/bin/lib/gh-repo-token.sh" <<'EOF'
gh_repo_use_token() { export GH_TOKEN=fixture-repo-tok; return 0; }
gh_repo_token_reset() { unset GH_TOKEN; }
EOF
expect_open "L-TOKEN" "opened " alpha-os SB-40 executing "$(bk 40)"
rm -f "$T/bin/lib/gh-repo-token.sh"
[ "$(grep -c '^fixture-repo-tok	api ' "$X/GH.log")" -ge 3 ] && [ "$(grep -c '^	' "$X/GH.log")" = 0 ] && ok || bad "L-TOKEN every gh call carries the repo token: $(cat "$X/GH.log")"

# ---------- L-CONDUCTOR the conductor lib exits at source time ----------
reset; good 41 "" 2
: > "$X/MC_EXIT"
O=$(lib open alpha-os SB-41 executing "$(bk 41)")
case "$(out1 "$O")" in "rc=0 opened https://github.com/Org/alpha/pull/77 rebase=not-queued review=requested") ok ;; *) bad "L-CONDUCTOR want rebase=not-queued, got '$(out1 "$O")'" ;; esac
[ "$(tail -n 1 <<<"$O")" = alive ] && ok || bad "L-CONDUCTOR the calling shell is still alive: '$O'"
[ ! -s "$X/REBASE.log" ] && ok || bad "L-CONDUCTOR no rebase queued: $(cat "$X/REBASE.log")"

# ---------- L-FAIL every create rung fails: failed, no hand-off ----------
reset; good 42
: > "$X/CREATE_FAIL"
O=$(lib open alpha-os SB-42 executing "$(bk 42)")
case "$(out1 "$O")" in "rc=1 failed every PR create rung"*) ok ;; *) bad "L-FAIL want 'failed every PR create rung', got '$(out1 "$O")'" ;; esac
[ ! -s "$X/BEAT.log" ] && [ ! -s "$X/LV.log" ] && ok || bad "L-FAIL a failed open sends no beat and asks no review"

# ---------- L5..L28 every branch that must open nothing ----------
reset; fx "repos/Org/alpha/git/matching-refs/heads/ticket/sb-5" 200 '[]'
expect_none "L5 no branch" "none no branch" alpha-os SB-5 executing "$(bk 5)"
reset; refs Org/alpha ticket/sb-6 ticket/sb-60
expect_none "L6 only the prefix near miss ticket/sb-60" "none no branch" alpha-os SB-6 executing "$(bk 6)"
reset; refs Org/alpha ticket/sb-7 ticket/sb-7-r1x
expect_none "L7 a non-digit -r suffix" "none no branch" alpha-os SB-7 executing "$(bk 7)"
reset; fx "repos/Org/alpha/git/matching-refs/heads/ticket/sb-8" 500 '{}'
expect_none "L8 refs 500" "unknown refs 500" alpha-os SB-8 executing "$(bk 8)"
reset; fx "repos/Org/alpha/git/matching-refs/heads/ticket/sb-9" TIMEOUT
expect_none "L9 refs TIMEOUT" "unknown refs TIMEOUT" alpha-os SB-9 executing "$(bk 9)"
reset; good 10; pulls Org/alpha ticket/sb-10 200 '[{"number":5,"state":"open","html_url":"https://github.com/Org/alpha/pull/5"}]'
expect_none "L10 an open PR" "none PR exists https://github.com/Org/alpha/pull/5" alpha-os SB-10 executing "$(bk 10)"
reset; good 11; pulls Org/alpha ticket/sb-11 200 '[{"number":6,"state":"closed","merged_at":null,"html_url":"https://github.com/Org/alpha/pull/6"}]'
expect_none "L11 a closed unmerged PR" "none PR exists https://github.com/Org/alpha/pull/6" alpha-os SB-11 executing "$(bk 11)"
reset; good 12; pulls Org/alpha ticket/sb-12 200 '[{"number":4,"state":"closed","merged_at":"2026-11-01T00:00:00Z","html_url":"https://github.com/Org/alpha/pull/4"}]'
expect_none "L12 a merged PR" "none PR exists https://github.com/Org/alpha/pull/4" alpha-os SB-12 executing "$(bk 12)"
reset; good 13; pulls Org/alpha ticket/sb-13 403 '{}'
expect_none "L13 pulls 403" "unknown pulls 403" alpha-os SB-13 executing "$(bk 13)"
reset; good 14; fx "repos/Org/alpha/compare/main...ticket/sb-14" 404 '{}'
expect_none "L14 compare 404" "unknown compare http=404" alpha-os SB-14 executing "$(bk 14)"
reset; good 15
fx "repos/Org/alpha/compare/main...ticket/sb-15" 200 "$(jq -nc --arg d "$TIP_OK" '{ahead_by:300,behind_by:0,commits:[range(250)|{commit:{message:"feat(SB-15): one",committer:{date:$d}}}],files:[{filename:"a.sh"}]}')"
expect_none "L15 a cut compare (ahead_by 300, 250 listed)" "unknown compare cut" alpha-os SB-15 executing "$(bk 15)"
reset; good 16; fx "repos/Org/alpha/compare/main...ticket/sb-16" 200 '{"ahead_by":0,"behind_by":4,"commits":[],"files":[]}'
expect_none "L16 ahead 0" "none no commits ahead of main" alpha-os SB-16 executing "$(bk 16)"
reset; good 17; compare Org/alpha ticket/sb-17 0 "bin/x.sh" "$TIP_OK" "wip: checkpoint execute 2026-11-14 10:01:00Z" "wip: checkpoint execute-exit 2026-11-14 10:04:00Z"
expect_none "L17 only wip commits" "none wip on branch" alpha-os SB-17 executing "$(bk 17)"
reset; good 18; compare Org/alpha ticket/sb-18 0 "bin/x.sh" "$TIP_OK" "feat(SB-18): real" "wip: checkpoint execute-exit 2026-11-14 10:04:00Z"
expect_none "L-WIP-TIP code commits plus one wip commit at the tip" "none wip on branch" alpha-os SB-18 executing "$(bk 18)"
reset; good 19; compare Org/alpha ticket/sb-19 0 ".harness/specs/SB-19/plan.md bin/x.sh" "$TIP_OK" "spec(SB-19): the plan" "spec(SB-19): the plan again"
expect_none "L19 only spec(SB-19) commits" "none spec only" alpha-os SB-19 executing "$(bk 19)"
reset; good 20; compare Org/alpha ticket/sb-20 0 ".harness/specs/SB-20/plan.md" "$TIP_OK" "docs: touch the plan"
expect_none "L20 a docs: commit that touches only .harness/specs/" "none spec only" alpha-os SB-20 executing "$(bk 20)"
reset; good 22; compare Org/alpha ticket/sb-22 0 "bin/x.sh" "2026-11-14T09:59:00Z" "feat(SB-22): an earlier build's work"
expect_none "L-TIP-OLD a tip 1 min older than the build start" "none branch tip 2026-11-14T09:59:00Z is older than build alpha-os-SB-22-$TS" alpha-os SB-22 executing "$(bk 22)"
reset; good 23; compare Org/alpha ticket/sb-23 0 "bin/x.sh" "not-a-date" "feat(SB-23): work"
expect_none "L23 an unparsable committer date" "unknown tip date" alpha-os SB-23 executing "$(bk 23)"
reset; good 24
expect_none "L24 a bkey with no build start" "unknown no build start in bkey bA1" alpha-os SB-24 executing bA1
[ "$(grep -c . "$X/GH.log")" = 0 ] && ok || bad "L24 no build start: 0 gh calls: $(cat "$X/GH.log")"
reset; good 25
expect_none "L25 a dir that ends in 10 digits" "unknown no build start" alpha-os SB-25 executing "$(bk 25 2026111900)"
[ "$(grep -c . "$X/GH.log")" = 0 ] && ok || bad "L25 no build start: 0 gh calls: $(cat "$X/GH.log")"
reset
refs Org/bhrepo ticket/bh-26 ticket/bh-26; pulls Org/bhrepo ticket/bh-26 200
compare Org/bhrepo ticket/bh-26 0 "bin/y.sh" "$TIP_OK" "feat(BH-26): work"
fx "repos/Org/bhrepo/issues/26" 200 '{"state":"open","title":"t","labels":[{"name":"ai-build"},{"name":"hold"}]}'
fx "repos/Org/bhrepo/issues/26/comments?per_page=100" 200 '[]'
expect_none "L26 a HOLD on the ticket" "held a HOLD on the ticket" bh-os BH-26 executing "build:bh-os:BH-26:bh-os-BH-26-$TS"
reset
refs Org/bhrepo ticket/bh-27 ticket/bh-27; pulls Org/bhrepo ticket/bh-27 200
compare Org/bhrepo ticket/bh-27 0 "bin/y.sh" "$TIP_OK" "feat(BH-27): work"
fx "repos/Org/bhrepo/issues/27" 502 '{}'
expect_none "L27 the hold does not read" "held the hold did not read" bh-os BH-27 executing "build:bh-os:BH-27:bh-os-BH-27-$TS"
reset
expect_none "L28 a project with no owner/repo slug" "none no repo slug for noslug-os" noslug-os SB-28 executing "build:noslug-os:SB-28:noslug-os-SB-28-$TS"

# ---------- L-NOROOT no harness root: unknown, no read ----------
reset; good 43
O=$( ( unset H; HARNESS="" PATH="$T/fakebin:$PATH" T_FX="$X"; export T_FX PATH; HARNESS=""; . "$T/bin/lib/stale-build-pr.sh"; sbp_decide alpha-os SB-43 "$(bk 43)"; echo "rc=$? $SBP_OUT" ) )
[ "$O" = "rc=1 unknown no harness root" ] && [ ! -s "$X/GH.log" ] && ok || bad "L-NOROOT want 'rc=1 unknown no harness root' and 0 gh calls, got '$O'"

# ---------- L-DECIDE sbp_decide is read only: would-open, 3 reads, 0 creates ----------
reset; good 29 -r2 5
O=$(lib decide alpha-os SB-29 "$(bk 29)")
[ "$(out1 "$O")" = "rc=0 would-open ticket/sb-29-r2 head=${SHA:0:12} ahead=1 behind=5" ] && ok || bad "L-DECIDE want would-open, got '$(out1 "$O")'"
[ "$(napi)" = 3 ] && [ "$(ncreate)" = 0 ] && [ ! -s "$X/BEAT.log" ] && [ ! -s "$X/LV.log" ] && ok || bad "L-DECIDE 3 reads, 0 creates (api=$(napi) creates=$(ncreate))"

# ===================== R: the real reaper =====================
NOW=$(date -u -d '2026-11-14 12:00' +%s)
ago() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%dT%H:%M:%SZ'; }
row() { # row <n> — a dead executing build of SB-<n>, 61 min quiet
  jq -nc --arg b "$(bk "$1")" --arg k "SB-$1" --arg u "$(ago 61)" \
    '{bkey:$b,project:"alpha-os",ticket_key:$k,stage:"executing",updated_at:$u,pr_url:""}'; }
feed() { printf '%s\n' "$@" | jq -sc '{ok:true,count:length,builds:.}' > "$X/FEED.json"; }
run() { # run [args] — env passes through; prints the true rc
  HARNESS="$T" T_FX="$X" PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-secret-example FLY_MACHINES_ROWS=off \
    JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
    bash "$DIR/bin/stale-build-reaper.sh" --now "$NOW" "$@" >/dev/null 2>&1; echo $?; }
summary() { logged | grep 'mode=' | tail -n 1; }

# ---------- R-OBS observe, no knobs: pr=would-open, 3 reads per build, no change ----------
reset; good 30; refs Org/alpha ticket/sb-31 ticket/sb-31
pulls Org/alpha ticket/sb-31 200; compare Org/alpha ticket/sb-31 0 "bin/x.sh" "$TIP_OK" "feat(SB-31): work"
feed "$(row 30)" "$(row 31)"
RC=$(run)
[ "$RC" = 0 ] && [ "$(grep -c 'OBSERVE would reap' <<<"$(logged)")" = 2 ] && ok || bad "R-OBS rc 0 and 1 OBSERVE line per dead build (rc=$RC): $(logged)"
logged | grep "OBSERVE would reap $(bk 30) " | grep -q " pr=would-open ticket/sb-30 head=${SHA:0:12} ahead=1 behind=0$" && ok || bad "R-OBS the OBSERVE line ends pr=would-open: $(logged)"
[ "$(ncreate)" = 0 ] && [ "$(nposts)" = 0 ] && [ ! -s "$X/PATCHES.log" ] && [ "$(nalerts)" = 0 ] && ok || bad "R-OBS 0 creates, 0 POSTs, 0 PATCHes, 0 alerts (creates=$(ncreate) posts=$(nposts) alerts=$(nalerts))"
[ "$(napi)" = 6 ] && ok || bad "R-OBS 2 candidates make 6 GitHub reads (got $(napi)): $(cat "$X/GH.log")"
summary | grep -q 'mode=observe candidates=2 .* opened=0$' && ok || bad "R-OBS the summary ends opened=0: $(summary)"

# ---------- R-OPEN act: the PR opens, no close POST ----------
reset; good 32; feed "$(row 32)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(ncreate)" = 1 ] && grep -q -- '--head ticket/sb-32 --base main ' "$X/CREATES.log" && ok || bad "R-OPEN 1 create from the branch (rc=$RC): $(cat "$X/CREATES.log")"
[ "$(nposts)" = 0 ] && ok || bad "R-OPEN an opened PR makes 0 close POSTs: $(cat "$X/POSTS.jsonl")"
[ "$(nalerts)" = 1 ] && grep -q "SB-32: build $(bk 32) died in executing (61 min quiet); opened https://github.com/Org/alpha/pull/77 from its branch (rebase=current, review=requested); claim none" "$T/logs/ALERTS.log" \
  && ok || bad "R-OPEN 1 alert naming the PR: $(cat "$T/logs/ALERTS.log")"
logged | grep "REAPED $(bk 32) " | grep -q ' pr=opened https://github.com/Org/alpha/pull/77 rebase=current review=requested$' && ok || bad "R-OPEN the REAPED line carries pr=opened <url>: $(logged)"
summary | grep -q 'mode=act candidates=1 held=0 skipped=0 reaped=1 deferred=0 refused=0 opened=1$' && ok || bad "R-OPEN summary: $(summary)"
B=$(head -n 1 "$X/BEAT.log" 2>/dev/null)
[ "$(jq -r .bkey <<<"$B" 2>/dev/null)" = "$(bk 32)" ] && [ "$(jq -r .stage <<<"$B" 2>/dev/null)" = pr_created ] && ok || bad "R-OPEN the pr_created beat keys the dead build: '$B'"

# ---------- R-NONE act, a wip branch: the C0 close runs ----------
reset; good 33; compare Org/alpha ticket/sb-33 0 "bin/x.sh" "$TIP_OK" "wip: checkpoint execute 2026-11-14 10:01:00Z"
feed "$(row 33)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && [ "$(jq -r '.closed[0]' "$X/POSTS.jsonl")" = "$(bk 33)" ] && [ "$(ncreate)" = 0 ] && ok || bad "R-NONE 1 close POST, 0 creates (rc=$RC posts=$(nposts))"
[ "$(nalerts)" = 1 ] && grep -q '; PR: none wip on branch (ticket/sb-33)' "$T/logs/ALERTS.log" && ok || bad "R-NONE 1 alert with PR: none wip: $(cat "$T/logs/ALERTS.log")"
logged | grep "REAPED $(bk 33) " | grep -q ' pr=none wip on branch' && summary | grep -q 'reaped=1 .* opened=0$' && ok || bad "R-NONE REAPED pr=none, opened=0: $(logged)"

# ---------- R-FAIL act, every create rung fails: pr=failed, the close runs ----------
reset; good 34; : > "$X/CREATE_FAIL"; feed "$(row 34)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && logged | grep "REAPED $(bk 34) " | grep -q ' pr=failed every PR create rung' && ok || bad "R-FAIL pr=failed and 1 close POST (rc=$RC posts=$(nposts)): $(logged)"
grep -q 'opened https' "$T/logs/ALERTS.log" "$T/logs/stale-build-reaper.log" && bad "R-FAIL no 'opened https' text anywhere" || ok
[ "$(nalerts)" = 1 ] && summary | grep -q 'opened=0$' && ok || bad "R-FAIL 1 alert, opened=0: $(summary)"

# ---------- R-OFF STALE_REAPER_OPEN_PR=0 (and =yes): 0 GitHub calls, the C0 close ----------
for V in 0 yes; do
  reset; good 35; feed "$(row 35)"
  RC=$(STALE_REAPER_ACT=1 STALE_REAPER_OPEN_PR="$V" run)
  [ "$RC" = 0 ] && [ ! -s "$X/GH.log" ] && [ "$(nposts)" = 1 ] && ok || bad "R-OFF OPEN_PR=$V: 0 gh calls, 1 close POST (rc=$RC gh=$(grep -c . "$X/GH.log") posts=$(nposts))"
  logged | grep "REAPED $(bk 35) " | grep -q ' pr=off$' && ok || bad "R-OFF OPEN_PR=$V: REAPED pr=off: $(logged)"
done
reset; good 35; feed "$(row 35)"
RC=$(STALE_REAPER_OPEN_PR=0 run)
logged | grep -q "OBSERVE would reap $(bk 35) .* pr=off$" && [ ! -s "$X/GH.log" ] && ok || bad "R-OFF observe with OPEN_PR=0: pr=off, 0 gh calls: $(logged)"

# ---------- R-CAP observe, STALE_REAPER_MAX=1, 2 candidates ----------
reset; good 36; feed "$(row 36)" "$(row 37)"
RC=$(STALE_REAPER_MAX=1 run)
[ "$(grep -c 'pr=would-open' <<<"$(logged)")" = 1 ] && [ "$(grep -c 'pr=not-read (over STALE_REAPER_MAX)' <<<"$(logged)")" = 1 ] && [ "$(napi)" = 3 ] \
  && ok || bad "R-CAP 1 would-open, 1 not-read, 3 reads (api=$(napi)): $(logged)"

# ---------- R-EXIT a sourced lib exits mid hand-off, after the create ----------
reset; good 38; feed "$(row 38)"
mv "$T/bin/lib/ppr-review.sh" "$X/ppr-review.sh.real"
printf 'ppr_review_handoff() { exit 7; }\n' > "$T/bin/lib/ppr-review.sh"
RC=$(STALE_REAPER_ACT=1 run)
mv -f "$X/ppr-review.sh.real" "$T/bin/lib/ppr-review.sh"
[ "$RC" = 0 ] && summary | grep -q 'mode=act .* reaped=1 .* opened=1$' && ok || bad "R-EXIT the summary is still written (rc=$RC): $(logged)"
logged | grep "REAPED $(bk 38) " | grep -q ' pr=opened https://github.com/Org/alpha/pull/77 rebase=pending review=pending$' && [ "$(nposts)" = 0 ] \
  && ok || bad "R-EXIT the REAPED line says opened, 0 close POSTs: $(logged)"

# ---------- R-NOLIB the lib is missing: one PR-step-off line, the C0 close ----------
reset; good 39; feed "$(row 39)"
mv "$T/bin/lib/stale-build-pr.sh" "$X/sbp.off"
RC=$(STALE_REAPER_ACT=1 run)
mv "$X/sbp.off" "$T/bin/lib/stale-build-pr.sh"
[ "$RC" = 0 ] && [ "$(grep -c 'PR step off: bin/lib/stale-build-pr.sh is missing' <<<"$(logged)")" = 1 ] && [ "$(nposts)" = 1 ] && [ ! -s "$X/GH.log" ] \
  && ok || bad "R-NOLIB one PR step off line, 1 close POST, 0 gh calls (rc=$RC): $(logged)"

# ---------- G1 the state-paths guard passes the lib and the reaper ----------
printf 'bin/lib/stale-build-pr.sh\nbin/stale-build-reaper.sh\n' > "$T/spg.txt"
GOUT=$(cd "$DIR" && SPG_FILES="$T/spg.txt" SPG_ROOT="$DIR" bin/state-paths-guard.sh 2>&1); GRC=$?
[ "$GRC" = 0 ] && ! grep -q 'STATE-PATHS-GUARD: bin/' <<<"$GOUT" && ok || bad "G1 state-paths-guard: rc=$GRC $GOUT"

echo "stale-build-pr.bh-9484-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
