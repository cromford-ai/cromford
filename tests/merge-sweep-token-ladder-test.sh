#!/bin/bash
# tests/merge-sweep-token-ladder-test.sh — BH-796: the sweep's per-repo token
# ladder in bin/merge-sweep.sh.
#
# THE DEFECT THIS PINS (hub, 2026-09-18 03:55-04:00Z). The probe classified by
# EXIT CODE alone, so `gh: You have exceeded a secondary rate limit … (HTTP 403)`
# and `gh: Not Found (HTTP 404)` were the same answer: "no token can see this
# repo". 238 of 400 merge-sweep.log lines blamed repo visibility during a rate
# limit, the invisible-repo page fired, and merged-to-main sat flat.
#
# What this suite asserts, all of it through the REAL script copied standalone
# into a scratch tree and driven with a gh shim (the convention
# tests/merge-sweep-invisible-repo-test.sh and tests/head-bound-approval-test.sh
# already use):
#   * 404 / 403-no-access / 401  -> invisible: the ALERT, the beat, the flag,
#     the logged skip (unchanged behaviour)
#   * 403-rate-limit / 429 / 5xx / no HTTP status at all -> TRANSIENT: no page,
#     no beat, no flag, a "deferred" line naming the real cause, not ledgered
#   * a third rung — a GitHub App token from bin/gh-token.sh — tried only after
#     the default and admin PATs fail, minted at most once per (repo, run)
#   * the rung-1 probe runs on the DEFAULT token even after an earlier
#     iteration exported the admin one
#   * token VALUES never reach a log; only the words default/admin/app
# Run from anywhere: tests/merge-sweep-token-ladder-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/bin" "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/alert-line.sh" "$T/bin/"
# The sweep sources the conductor lib for its PR-state reader (mc_pr_view,
# BH-783/784) and the merge-queue probe; without it every read answers rc 1 and the
# PR logs "mergeState=unknown (will retry)" — the same shape
# tests/merge-sweep-invisible-repo-test.sh already copies in.
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# and exits on a missing module — a fixture that copies it carries them too.
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# Since BH-784 every decision read in the sweep goes through the conductor lib
# and bin/lib/gh-rest.sh. Without both in the scratch box's bin/lib the sweep's
# fail-closed shims answer "unverifiable" to every read, nothing ever merges,
# and the rungs below would be tested against a sweep that cannot act on what
# they can see.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
for stub in deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$stub"; chmod +x "$T/bin/$stub"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"
# no project owns these repos -> the post-merge codegraph/issue-close block is inert
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"
# worker stub: no ledger rows at all -> the build record decides
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# gh shim. The RUNG is decided by the token the call is going out on, and it is
# the rung WORD that lands in gh.txt — the suite never writes a token value.
# The visibility probe (`api repos/<slug> -q .id`) answers from
# $T/probe-<owner>_<repo>-<rung>: file present -> print its contents on stderr
# and exit 1 (the real gh shape), absent -> rc 0. Every other call is gated by
# $T/only-<owner>_<repo>, which names the one rung allowed to talk about that
# repo (so "the App token is the only one that can merge" is testable).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "${GH_TOKEN:-}" in
  admintok)  RUNG=admin ;;
  ghs_stub)  RUNG=app ;;
  ""|pattok) RUNG=default ;;
  *)         RUNG=other ;;
esac
printf '%s %s\n' "$RUNG" "$*" >> "$GH_SINK"
if [ "${1:-}" = api ] && [ "${4:-}" = .id ]; then
  KEY=${2#repos/}; KEY=${KEY//\//_}
  if [ -f "$T/probe-$KEY-$RUNG" ]; then
    cat "$T/probe-$KEY-$RUNG" >&2
    [ -f "$T/probebody-$KEY-$RUNG" ] && cat "$T/probebody-$KEY-$RUNG"
    exit 1
  fi
  echo 12345; exit 0
fi
PRURL=$(grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' <<<"$*" | head -1)
PRKEY=$(grep -oE 'github\.com/[^/]+/[^/]+' <<<"$*" | head -1 | sed 's|github\.com/||; s|/|_|')
# THE DECISION READS ARE REST (BH-784): they name the PR as
# repos/<owner>/<repo>/pulls/<n> and carry no github.com url at all, so the repo
# key and the PR url the arms below need are rebuilt from that path. `gh pr
# merge` still speaks the url, which is why both derivations stay.
if [ -z "$PRKEY" ]; then
  RESTPR=$(grep -oE 'repos/[^ /]+/[^ /]+/pulls/[0-9]+' <<<"$*" | head -1)
  if [ -n "$RESTPR" ]; then
    RESTPR=${RESTPR#repos/}
    PRKEY=$(sed 's|/pulls/[0-9]*$||; s|/|_|' <<<"$RESTPR")
    PRURL="https://github.com/${RESTPR/\/pulls\//\/pull\/}"
  fi
fi
if [ -n "$PRKEY" ] && [ -s "$T/only-$PRKEY" ] && [ "$RUNG" != "$(cat "$T/only-$PRKEY")" ]; then exit 1; fi
case "$*" in
  # The diff shares the pulls path with the JSON read and is told apart by its
  # Accept header, so it matches FIRST.
  *"v3.diff"*)            restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    # The same facts the old --json arms carried, now off one pull object: OPEN
    # CLEAN operator headsha before the merge, and MERGED with merge commit
    # deadbeefcafe once this PR is in the merge sink. gh's exit code was never
    # the landing.
    if [ -n "$PRURL" ] && grep -qF "$PRURL" "$MERGE_SINK"; then
      restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else
      restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator
    fi ;;
  *"pr merge"*)           echo "merged $PRURL" >> "$MERGE_SINK"; exit 0 ;;
  # No project owns these repos, so the close-out never runs; the arms answer
  # success anyway, as the old issue comment/close arms did.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*)   restpr --raw 200 '{"state":"closed"}' ;;
  *)                      echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"

S404='gh: Not Found (HTTP 404)'
S403P='gh: API rate limit exceeded for user ID 2220366. If you reach out to GitHub Support for help, please include the request ID. (HTTP 403)'
S403S='gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)'
S403N='gh: Resource not accessible by personal access token (HTTP 403)'
S401='gh: Bad credentials (HTTP 401)'
S429='gh: Too Many Requests (HTTP 429)'
S502='gh: Server Error (HTTP 502)'
SNET='error connecting to api.github.com'

reset() {
  rm -rf "$T/builds"; mkdir -p "$T/builds"
  rm -f "$T"/probe-* "$T"/probebody-* "$T"/only-* "$T/bin/gh-token.sh"
  rm -f "$T"/flags/alerted-repo-invisible-*
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merges.txt"; : > "$T/gh.txt"; : > "$T/beats.txt"; : > "$T/mints.txt"; : > "$T/err.txt"
}
add_pr() { # add_pr <record-suffix> <owner/repo> <pr-number>
  local d="$T/builds/pool-ts-$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$2/pull/$3" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  : > "$d/pipeline.log"
}
probe()       { printf '%s\n' "$3" > "$T/probe-$1-$2"; }   # probe <owner_repo> <rung> <stderr shape>
probe_empty() { : > "$T/probe-$1-$2"; }                     # a bare rc 1 with no output at all
mint_stub() { # mint_stub <what bin/gh-token.sh prints>
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$MINT_SINK"\nprintf "%%s\\n" "%s"\n' "$1" > "$T/bin/gh-token.sh"
  chmod +x "$T/bin/gh-token.sh"
}
sweep() {
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" T="$T" GH_TOKEN=pattok \
           HARNESS_SECRET=s JOBS_URL=https://jobs.invalid JOBS_BOX=b SWEEP_MERGE_SETTLE=0 \
           MERGE_SINK="$T/merges.txt" GH_SINK="$T/gh.txt" BEAT_SINK="$T/beats.txt" MINT_SINK="$T/mints.txt"
    bash "$T/bin/sweep.sh" >/dev/null 2>>"$T/err.txt" )
}
probes_for() { grep -c " api repos/$1 -q .id\$" "$T/gh.txt"; }
probe_rungs() { grep " api repos/$1 -q .id\$" "$T/gh.txt" | awk '{print $1}' | tr '\n' ' '; }
no_flag()    { ! compgen -G "$T/flags/alerted-repo-invisible-*" >/dev/null; }

# ---------------------------------------------------------------- case 1: 404
# A real 404 on every PAT is still an invisible repo: page, beat, flag, skip.
reset; add_pr a1 o/r 7; probe o_r default "$S404"; probe o_r admin "$S404"
sweep
grep -q "repo o/r is INVISIBLE to the default gh token (the admin token cannot see it either)" "$T/logs/ALERTS.log" \
  && ok || bad "1: a real 404 must still page: $(cat "$T/logs/ALERTS.log") err=$(cat "$T/err.txt")"
grep -q "repoinvisible:merge-sweep:o/r" "$T/beats.txt" && ok || bad "1: no invisible-repo beat: $(cat "$T/beats.txt")"
no_flag && bad "1: the per-(repo,day) dedup flag was not written" || ok
grep -q "pull/7 skipped: its repo is invisible to every gh token" "$T/logs/merge-sweep.log" \
  && ok || bad "1: the skip was not logged: $(cat "$T/logs/merge-sweep.log")"
[ ! -s "$T/merges.txt" ] && ok || bad "1: merged through an invisible repo"
grep -q "pull/7" "$T/state/merge-sweep-done.txt" && bad "1: an invisible skip was ledgered" || ok

# ------------------------------------------- case 2: 403 secondary rate limit
# THE INCIDENT. Two PRs on one repo, every PAT rate-limited. No page, no beat,
# no flag, a deferred line per PR naming the real cause, nothing ledgered, and
# the repo is probed once per rung for the whole run (not once per PR).
reset; add_pr a1 o/r 7; add_pr b2 o/r 8
probe o_r default "$S403S"; probe o_r admin "$S403S"
sweep
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "2: a rate limit fired the invisible-repo page: $(cat "$T/logs/ALERTS.log")"
[ ! -s "$T/beats.txt" ] && ok || bad "2: a rate limit fired a fleet_alert beat: $(cat "$T/beats.txt")"
no_flag && ok || bad "2: a rate limit wrote the invisible-repo dedup flag"
grep -q "pull/7 deferred: GitHub answered a transient error for o/r" "$T/logs/merge-sweep.log" \
  && ok || bad "2: pull/7 was not deferred: $(cat "$T/logs/merge-sweep.log") ERR=$(cat "$T/err.txt")"
grep -q "pull/8 deferred: GitHub answered a transient error for o/r" "$T/logs/merge-sweep.log" \
  && ok || bad "2: pull/8 was not deferred: $(cat "$T/logs/merge-sweep.log")"
grep -q "default=transient admin=transient app=absent" "$T/logs/merge-sweep.log" \
  && ok || bad "2: the deferred line must name each rung's class: $(cat "$T/logs/merge-sweep.log")"
grep -q "skipped: its repo is invisible" "$T/logs/merge-sweep.log" && bad "2: a rate limit was logged as invisible" || ok
[ "$(probes_for o/r)" = 2 ] && ok || bad "2: the ladder must probe once per rung per run, saw $(probes_for o/r): $(probe_rungs o/r)"
[ ! -s "$T/merges.txt" ] && ok || bad "2: merged while every token was rate-limited"
grep -q "pull/" "$T/state/merge-sweep-done.txt" && bad "2: a deferred PR was ledgered — it can never land" || ok

# ------------------------- case 3: every other transient shape defers, no page
for shape in "$S403P" "$S429" "$S502" "$SNET" ""; do
  reset; add_pr a1 o/r 7
  if [ -z "$shape" ]; then probe_empty o_r default; probe_empty o_r admin
  else probe o_r default "$shape"; probe o_r admin "$shape"; fi
  sweep
  W="${shape:-<bare rc 1, no output>}"
  [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/beats.txt" ] && no_flag \
    && grep -q "pull/7 deferred: GitHub answered a transient error" "$T/logs/merge-sweep.log" \
    && ok || bad "3: [$W] must defer without paging: alerts=$(cat "$T/logs/ALERTS.log") log=$(cat "$T/logs/merge-sweep.log")"
done
# the JSON-body fallback: gh printed no `(HTTP nnn)` line, only the API body
reset; add_pr a1 o/r 7
probe_empty o_r default; probe_empty o_r admin
printf '{"message":"You have exceeded a secondary rate limit","status":"403"}\n' > "$T/probebody-o_r-default"
printf '{"message":"You have exceeded a secondary rate limit","status":"403"}\n' > "$T/probebody-o_r-admin"
sweep
[ ! -s "$T/logs/ALERTS.log" ] && grep -q "pull/7 deferred" "$T/logs/merge-sweep.log" \
  && ok || bad "3: the status in the JSON body must be read when gh prints no (HTTP nnn) line: $(cat "$T/logs/merge-sweep.log")"

# ------------------ case 4: a 403 that is NOT a rate limit, and a 401, do page
for shape in "$S403N" "$S401"; do
  reset; add_pr a1 o/r 7; probe o_r default "$shape"; probe o_r admin "$shape"
  sweep
  grep -q "repo o/r is INVISIBLE to the default gh token" "$T/logs/ALERTS.log" \
    && grep -q "pull/7 skipped: its repo is invisible" "$T/logs/merge-sweep.log" \
    && ok || bad "4: [$shape] is a dead/under-scoped credential and must page: $(cat "$T/logs/ALERTS.log")"
done

# ----------------------------- case 5: the App rung merges what the PATs can't
reset; add_pr a1 o/r 7; add_pr b2 o/r 8
probe o_r default "$S403S"; probe o_r admin "$S403S"
mint_stub ghs_stub
echo app > "$T/only-o_r"
sweep
[ "$(grep -c . "$T/merges.txt")" = 2 ] \
  && ok || bad "5: both PRs must merge on the App token, merges=$(cat "$T/merges.txt") log=$(cat "$T/logs/merge-sweep.log")"
[ "$(probe_rungs o/r)" = "default admin app " ] \
  && ok || bad "5: rung order must be default, admin, app — saw: $(probe_rungs o/r)"
[ "$(grep -c . "$T/mints.txt")" = 1 ] && ok || bad "5: exactly one mint per (repo, run), saw $(grep -c . "$T/mints.txt"): $(cat "$T/mints.txt")"
grep -qx "o/r" "$T/mints.txt" && ok || bad "5: the mint must be scoped to the PR's repo: $(cat "$T/mints.txt")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "5: nothing to page about once a rung sees the repo: $(cat "$T/logs/ALERTS.log")"
grep -rqE 'ghs_stub|admintok|pattok' "$T/logs" && bad "5: a token VALUE reached a log" || ok

# --------------------- case 6: the default token sees it -> no mint, no ladder
reset; add_pr a1 o/r 7; mint_stub ghs_stub
sweep
[ ! -s "$T/mints.txt" ] && ok || bad "6: minted an App token the sweep did not need: $(cat "$T/mints.txt")"
[ "$(probe_rungs o/r)" = "default " ] && ok || bad "6: only the default rung should be probed, saw: $(probe_rungs o/r)"
grep -q merged "$T/merges.txt" && ok || bad "6: did not merge a CLEAN APPROVE on the default token: $(cat "$T/logs/merge-sweep.log")"

# --------- case 7: an unarmed gh-token.sh echoes the PAT -> no third rung spent
reset; add_pr a1 o/r 7; probe o_r default "$S404"; probe o_r admin "$S404"; mint_stub pattok
sweep
[ "$(probes_for o/r)" = 2 ] && ok || bad "7: the PAT echo must not be probed as a third rung, saw: $(probe_rungs o/r)"
grep -q "repo o/r is INVISIBLE to the default gh token" "$T/logs/ALERTS.log" \
  && ok || bad "7: an unarmed box still pages on a real 404: $(cat "$T/logs/ALERTS.log")"
reset; add_pr a1 o/r 7; probe o_r default "$S403S"; probe o_r admin "$S403S"; mint_stub pattok
sweep
[ ! -s "$T/logs/ALERTS.log" ] && grep -q "app=unavailable" "$T/logs/merge-sweep.log" \
  && ok || bad "7: unarmed + rate-limited defers with app=unavailable: $(cat "$T/logs/merge-sweep.log")"

# ------------- case 8: rung 1 is the DEFAULT token, not whatever GH_TOKEN holds
# PR 1's repo is admin-only, so its iteration exports the admin token. PR 2's
# repo is visible ONLY to the default one: if the next probe inherits the export
# it reads as invisible and the PR is skipped (the 2026-09-13 review-rescue
# shape bin/lib/gh-repo-token.sh already fixed for its own consumers).
reset; add_pr a-adm o/adm 1; add_pr b-def o/def 2
probe o_adm default "$S404"; probe o_def admin "$S404"
echo admin   > "$T/only-o_adm"
echo default > "$T/only-o_def"
sweep
[ "$(grep -c . "$T/merges.txt")" = 2 ] \
  && ok || bad "8: both PRs must merge on the token that can see their repo: $(cat "$T/merges.txt") log=$(cat "$T/logs/merge-sweep.log")"
[ "$(probe_rungs o/def)" = "default " ] \
  && ok || bad "8: repo B's first rung must run on the default token, saw: $(probe_rungs o/def)"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "8: nothing is invisible here: $(cat "$T/logs/ALERTS.log")"

echo "merge-sweep-token-ladder: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
