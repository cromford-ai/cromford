#!/bin/bash
# tests/gh-budget-rest-test.sh — BH-597. Two defects, one lane's day.
#
# 1. THE ONE BUCKET (history). `gh pr view --json` and `gh pr list --json` are
#    GraphQL calls. Every PAT in this fleet belongs to the same GitHub user
#    (operator, id 2220366), so they all draw on ONE 5000/hour GraphQL budget. On
#    2026-09-16 (17:05-18:05Z, and again at 22:03Z) it ran out: every PR-state
#    read in bin/merge-conductor.sh, bin/merge-sweep.sh, bin/blocked-resolver.sh
#    and bin/lib/merge-conductor-lib.sh answered an empty string, the lanes went
#    blind, and clean PRs were sent to REBUILD FRESH because "this PR has no
#    branch". BH-597's own planned reader (never shipped) moved every PR-state read in
#    those four files onto REST — and by the time this PR rebased onto main,
#    BH-783/BH-784 (#966, #1157) had independently converted the same four
#    lanes onto REST through a different, more complete reader (`mc_pr_view` /
#    `gh_rest_*` in bin/lib/gh-rest.sh, with a three-way 0/44/75 ok/absent/
#    unverifiable contract the planned reader's rc 0/1/2 did not carry). The rebase
#    keeps main's reader — two live per-PR REST readers with different failure
#    contracts in the same lanes is exactly the regression BH-597's operator
#    HOLD existed to prevent — so that planned reader, and every call site this
#    PR moved onto it, is gone. What survives from the ticket is item 2: EVERY
#    LANE NAMES ITS CREDENTIAL, once per tick per repo, in the words `App
#    installation token` / `default PAT` / `admin PAT` and never a token value
#    — blocks B, C and D below drive that, against the real scripts, over
#    whichever reader each one now uses.
#
# 2. THE INHERITED LOCK. bin/run-triage.sh holds locks/<project>.lock on fd 9
#    for its tick. The agent session it launches — and every build that session
#    detaches — inherits that descriptor, so the lock stayed held for the build's
#    whole life and later ticks logged "previous run still active, skipping"
#    (2026-09-16 21:53Z and 22:03Z, while BH-416/420/449 built; it is what
#    blocked BH-594's re-offer). bin/triage-shard.sh had the same trap on its
#    per-key lock on fd 8. BH-651 closed both by launching the session through
#    lock_run_unheld / lock_spawn_unheld (bin/lib/lock-hygiene.sh), which close
#    fds 8 and 9 in a subshell and exec. THIS FILE SHIPS NO PART OF THAT FIX —
#    block E is its regression guard, so a future edit that puts agent-call.sh
#    back on the bare line is red here rather than a week of skipped ticks.
#
# WHAT THIS FILE DRIVES. The real bin/merge-sweep.sh (block B), bin/run-triage.sh
# and bin/triage-shard.sh (block E), plus bin/merge-conductor.sh's and
# bin/blocked-resolver.sh's own credential functions extracted BY NAME (blocks C
# and D). Assertions are on artifacts: the recorded gh argv, the lane logs, the
# done-file, and whether a lock is actually held.
#
# Run from anywhere: tests/gh-budget-rest-test.sh   (exit 0 = all pass)
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
# NEVER a skip-exit-0 on a missing tool. Every claim below needs all three, and a
# suite that exits green without them is a suite that vouched for nothing.
for _t in jq flock setsid; do
  command -v "$_t" >/dev/null 2>&1 || { echo "FAIL: $_t missing — this suite cannot vouch for anything without it"; exit 1; }
done
# NO REAL CREDENTIAL REACHES THIS RUN (tests/blocked-resolver-test.sh's rule).
# The stubs below RECORD the token each call ran on, and the failure messages
# print those lines: a run that inherited this box's live GH_TOKEN would put an
# installation token into CI output and into a build's red.txt.
export GH_TOKEN=pat_fixture_default
unset GH_ADMIN_TOKEN GITHUB_TOKEN

# ===========================================================================
# BLOCK B — the REAL bin/merge-sweep.sh: reads over REST, App token per repo,
#           and a log line naming the credential
# ===========================================================================
B="$T/b"
mkdir -p "$B/bin/lib" "$B/logs" "$B/state" "$B/flags" "$B/locks" "$B/env" "$B/tmp" "$B/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$B/bin/sweep.sh"
mkdir -p "$B/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$B/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$B/bin/"
mkdir -p "$B/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$B/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-app-auth.sh" "$B/bin/lib/"
# Every decision read in the sweep goes through the conductor lib's mc_pr_view
# and bin/lib/gh-rest.sh (BH-784). Without gh-rest.sh the lib's guard leaves
# gh_rest undefined and mc_pr_view dies on it.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$B/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# and exits on a missing module — every fixture that sources it carries the
# modules too.
mkdir -p "$B/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$B/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$B/fakebin/restpr"; chmod +x "$B/fakebin/restpr"
printf 'p o/plain - - 3 box-p\nx o/other - - 3 box-x\n' > "$B/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$B/bin/$s"; chmod +x "$B/bin/$s"
done
# The App is configured on this box, and gh-token.sh mints for o/plain only —
# the fallback case the ticket asks for ("fall back to the current PAT when the
# App has no installation for that repo") is o/other.
printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$B/env/github-app.env"
cat > "$B/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in
  o/plain) echo "ghs_fixture_o_plain" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$B/bin/gh-token.sh"
BPAT=pat_fixture_default
cat > "$B/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\tGH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-}" >> "$B/gh-calls.txt"
case "\$*" in
  "api repos/o/plain -q .id"|"api repos/o/other -q .id") echo 1 ;;
  "api repos/o/plain/rulesets"*|"api repos/o/other/rulesets"*) : ;;
  # The sweep's iron-law scan reads the diff over REST too (mc_pr_diff), before
  # the pulls/N object read below — matched first since both share the same
  # path and differ only by Accept header.
  *"v3.diff"*) restpr --diff ;;
  # After the merge attempt the sweep asks GitHub what actually happened over
  # REST (mc_pr_view, BH-784) — a full HTTP response through restpr, not a
  # bare JSON echo. The marker file is what the \`pr merge\` arm below leaves.
  *"-i -X GET repos/o/plain/pulls/8")
    if [ -f "$B/merged8" ]; then
      restpr MERGED headsha8 ticket/p-8 main "" MERGEABLE CLEAN operator mergesha8
    else
      restpr OPEN headsha8 ticket/p-8 main "" MERGEABLE CLEAN operator
    fi ;;
  *"-i -X GET repos/o/other/pulls/9")
    restpr OPEN headsha9 ticket/x-9 main "" MERGEABLE BLOCKED operator ;;
  "pr merge"*) printf '%s\n' "\$*" >> "$B/merge-calls.txt"; touch "$B/merged8"; echo "" ;;
  "pr diff"*) echo "+ const x = 1;" ;;
  "issue comment"*|"issue close"*) printf '%s\n' "\$*" >> "$B/issue-calls.txt" ;;
  # The post-merge issue close-out is REST too (mc_close_shipped, via
  # gh_rest_comment / gh_rest_close): a POST comment, a PATCH to closed, then a
  # fresh GET the close verifies against before it is ever logged as closed.
  *"-i -X POST repos/o/plain/issues/8/comments"*)
    printf '%s\n' "\$*" >> "$B/issue-calls.txt"; restpr --raw 200 '{}' ;;
  *"-i -X PATCH repos/o/plain/issues/8"*)
    printf '%s\n' "\$*" >> "$B/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"-i -X GET repos/o/plain/issues/8")
    restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$B/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$B/fakebin/curl"; chmod +x "$B/fakebin/curl"

b_setup() {
  scratch_rm "$B/builds"
  mkdir -p "$B/builds/pool-p-XX-8-202609120001" "$B/builds/pool-x-XX-9-202609120002"
  echo "PR_CREATED https://github.com/o/plain/pull/8" > "$B/builds/pool-p-XX-8-202609120001/RESULT"
  echo "PR_CREATED https://github.com/o/other/pull/9" > "$B/builds/pool-x-XX-9-202609120002/RESULT"
  for d in "$B/builds/pool-p-XX-8-202609120001" "$B/builds/pool-x-XX-9-202609120002"; do
    printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"; : > "$d/pipeline.log"
  done
  : > "$B/state/merge-sweep-done.txt"; : > "$B/logs/merge-sweep.log"; : > "$B/logs/ALERTS.log"
  : > "$B/merge-calls.txt"; : > "$B/issue-calls.txt"; : > "$B/gh-calls.txt"
  rm -f "$B/merged8"; rm -f "$B/tmp"/*.probe 2>/dev/null
}
b_run() { # b_run [extra env assignments]
  ( cd "$B" && PATH="$B/fakebin:$PATH" HARNESS="$B" GH_TOKEN="$BPAT" FLEET_CONF="$B/fleet.conf" \
      SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 env "$@" bash "$B/bin/sweep.sh" >/dev/null 2>"$B/sweep.err" ) || true
}
b_setup; b_run
grep -q -- '-i -X GET repos/o/plain/pulls/8' "$B/gh-calls.txt" \
  && ok || bad "B: the sweep never read PR 8 over REST (calls: $(cut -f1 "$B/gh-calls.txt" | paste -sd'|' -))"
grep -qE '^pr (view|list) ' "$B/gh-calls.txt" \
  && bad "B: bin/merge-sweep.sh still spends the shared GraphQL bucket: $(grep -m1 -E '^pr (view|list) ' "$B/gh-calls.txt" | cut -f1)" || ok
grep -qxF 'https://github.com/o/plain/pull/8' "$B/state/merge-sweep-done.txt" \
  && ok || bad "B: the merged PR must still be recorded — the transport changed, the decision did not (log: $(cat "$B/logs/merge-sweep.log"))"
# Token per repo, from bin/gh-token.sh, and NOTHING of repo A's token leaks into
# repo B's probe (the r3 bug this rebuild exists to not repeat).
BAD_TOK=$(grep -E '^api (-i -X GET )?repos/o/plain/' "$B/gh-calls.txt" | grep -vc 'GH_TOKEN=ghs_fixture_o_plain' || true)
[ "${BAD_TOK:-1}" = 0 ] \
  && ok || bad "B: every o/plain REST call must run on the App installation token ($BAD_TOK did not: $(grep -E '^api (-i -X GET )?repos/o/plain/' "$B/gh-calls.txt" | grep -v 'GH_TOKEN=ghs_fixture_o_plain' | head -2))"
grep -qF "api repos/o/other -q .id	GH_TOKEN=$BPAT" "$B/gh-calls.txt" \
  && ok || bad "B: the default-visibility probe for a repo the App cannot see must run on the PAT (got: $(grep -F 'api repos/o/other -q .id' "$B/gh-calls.txt" | cut -f1 | head -1))"
# NOT ONE o/other CALL MAY CARRY o/plain's TOKEN. This is the bug the r3 attempt
# shipped: without the reset at the top of sweep_use_token_for, the App token
# armed for the previous repo is still exported when THIS repo's visibility probe
# runs, so the probe answers "visible" on a credential that has nothing to do
# with it. Asserting only that SOME o/other call ran on the PAT would pass with
# the leak still there, because the calls after the probe are on the PAT anyway.
LEAKED=$(grep -c -E '^api (-i -X GET )?repos/o/other.*GH_TOKEN=ghs_fixture_o_plain' "$B/gh-calls.txt" || true)
[ "${LEAKED:-1}" = 0 ] \
  && ok || bad "B: $LEAKED call(s) against o/other ran on o/plain's App installation token — sweep_use_token_for must reset before it probes the next repo"
[ "$(grep -c 'github auth: App installation token for o/plain' "$B/logs/merge-sweep.log")" = 1 ] \
  && ok || bad "B: exactly one 'github auth: App installation token for o/plain' line per tick (got $(grep -c 'github auth:' "$B/logs/merge-sweep.log") auth line(s): $(grep 'github auth:' "$B/logs/merge-sweep.log" | head -3))"
[ "$(grep -c 'github auth: default PAT for o/other' "$B/logs/merge-sweep.log")" = 1 ] \
  && ok || bad "B: a repo with no App installation must log the PAT fallback once (auth lines: $(grep 'github auth:' "$B/logs/merge-sweep.log" | head -3))"
grep -rqE 'ghs_fixture_o_plain|pat_fixture_default' "$B/logs" \
  && bad "B: a TOKEN VALUE reached a log: $(grep -rlE 'ghs_fixture_o_plain|pat_fixture_default' "$B/logs" | head -1)" || ok

# --- the unarmed box does exactly what it did on 2026-09-13 ------------------
b_setup; b_run GH_APP_TOKENS=0
grep -q 'github auth: default PAT for o/plain' "$B/logs/merge-sweep.log" \
  && ok || bad "B: with GH_APP_TOKENS=0 the sweep must say it ran on the PAT (auth lines: $(grep 'github auth:' "$B/logs/merge-sweep.log" | head -3))"
grep -qF 'GH_TOKEN=ghs_fixture_o_plain' "$B/gh-calls.txt" \
  && bad "B: GH_APP_TOKENS=0 must mint nothing — the kill switch is the safety argument" || ok
grep -qxF 'https://github.com/o/plain/pull/8' "$B/state/merge-sweep-done.txt" \
  && ok || bad "B: an unarmed box must still sweep its PRs"

# ===========================================================================
# THE SECOND WAY AN APP TOKEN ARRIVES, built once and used by blocks C and D
# ===========================================================================
# gh_auth_for is not the only rung that can hand a lane an installation token.
# It refuses when bin/gh-token.sh prints nothing for the bare call; the ladder
# below it (bin/lib/gh-repo-token.sh) then mints AGAIN with --min-life and
# verifies the repo is visible, and that rung can succeed where the first one
# declined. `gh_repo_token_for` then answers the word `app`, and a lane that
# spells its log line "$(gh_repo_token_for) PAT" writes `app PAT` — the name of
# a credential that does not exist, in the one line an operator reads to learn
# what a tick spent.
#
# The fixture reproduces exactly that split: the gh-token.sh stub refuses the
# bare call gh_auth_for makes and answers the --min-life call the ladder makes.
app_ladder_fixture() { # app_ladder_fixture <dir> <slug> <token>
  local d="$1" slug="$2" tok="$3"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/env" "$d/flags" "$d/fakebin"
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" \
     "$DIR/bin/lib/gh-budget.sh" "$d/bin/lib/"
  cat > "$d/bin/gh-token.sh" <<STUB
#!/bin/bash
# The bare call is gh_auth_for's; --min-life is gh-repo-token.sh's App rung.
case "\${1:-}" in
  --min-life) [ "\${3:-}" = "$slug" ] && { echo "$tok"; exit 0; }; exit 1 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$d/bin/gh-token.sh"
  printf 'GH_APP_ID=1\n' > "$d/env/github-app.env"
  cat > "$d/fakebin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$d/gh-calls.txt"
case "\$*" in
  "api repos/$slug -q .id") echo 1 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$d/fakebin/gh"
}

# ===========================================================================
# BLOCK C — bin/merge-conductor.sh's own use_token / reset_token, by name
# ===========================================================================
C="$T/c"
mkdir -p "$C/bin/lib" "$C/logs" "$C/env" "$C/flags"
cp "$DIR/bin/lib/gh-app-auth.sh" "$C/bin/lib/"
cat > "$C/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in o/plain) echo "ghs_fixture_o_plain" ;; *) exit 1 ;; esac
STUB
chmod +x "$C/bin/gh-token.sh"
printf 'GH_APP_ID=1\n' > "$C/env/github-app.env"
: > "$C/fns.sh"
for fn in use_token reset_token; do
  awk -v f="^$fn\\\\(\\\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/merge-conductor.sh" >> "$C/fns.sh"
done
[ -s "$C/fns.sh" ] && ok || bad "C: could not extract use_token/reset_token from bin/merge-conductor.sh"
c_drive() { # c_drive <env-assignments...> -- prints "<GH_TOKEN after>"
  ( export HARNESS="$C" GH_TOKEN=pat_fixture_default
    : > "$C/logs/mc.log"
    env "$@" bash -c '
      . "$HARNESS/bin/lib/gh-app-auth.sh"
      MC_LOG="$HARNESS/logs/mc.log"
      mc_log() { echo "$*" >> "$MC_LOG"; }
      . "$HARNESS/fns.sh"
      use_token o/plain
      printf "ARMED=%s\n" "${GH_TOKEN:-}"
      reset_token
      printf "RESET=%s\n" "${GH_TOKEN:-}"
    ' )
}
COUT=$(c_drive HARNESS="$C")
grep -qx 'ARMED=ghs_fixture_o_plain' <<<"$COUT" \
  && ok || bad "C: use_token must arm the repo's App installation token (got: $COUT)"
grep -qx 'RESET=pat_fixture_default' <<<"$COUT" \
  && ok || bad "C: reset_token must put the lane's own identity back (got: $COUT)"
[ "$(grep -c 'github auth: App installation token' "$C/logs/mc.log")" = 1 ] \
  && ok || bad "C: one 'github auth:' line per tick per slug (log: $(cat "$C/logs/mc.log"))"
grep -q 'ghs_fixture_o_plain' "$C/logs/mc.log" \
  && bad "C: the conductor printed a TOKEN VALUE into its log" || ok

COUT=$(c_drive HARNESS="$C" GH_APP_TOKENS=0)
grep -qx 'ARMED=pat_fixture_default' <<<"$COUT" \
  && ok || bad "C: with GH_APP_TOKENS=0 the environment must be untouched (got: $COUT)"
grep -q 'github auth: default PAT' "$C/logs/mc.log" \
  && ok || bad "C: an unarmed conductor must still name its credential (log: $(cat "$C/logs/mc.log"))"

# The PAT-ladder App rung: gh_auth_for declines, gh_repo_use_token arms the
# installation token anyway, and the log line must say what that token IS.
CA="$T/ca"
app_ladder_fixture "$CA" o/plain ghs_fixture_ladder
cp "$C/fns.sh" "$CA/fns.sh"
CAOUT=$( export HARNESS="$CA" PATH="$CA/fakebin:$PATH" GH_TOKEN=pat_fixture_default
  : > "$CA/logs/mc.log"
  bash -c '
    . "$HARNESS/bin/lib/gh-app-auth.sh"
    . "$HARNESS/bin/lib/gh-repo-token.sh"
    MC_LOG="$HARNESS/logs/mc.log"
    mc_log() { echo "$*" >> "$MC_LOG"; }
    gh_repo_invisible_alert() { echo "ALERTED" >> "$MC_LOG"; }
    . "$HARNESS/fns.sh"
    use_token o/plain
    printf "ARMED=%s\n" "${GH_TOKEN:-}"
  ' 2>&1 )
# Without this the two assertions below would pass on a lane that never took the
# App rung at all.
grep -qx 'ARMED=ghs_fixture_ladder' <<<"$CAOUT" \
  && ok || bad "C: the PAT ladder's App rung did not arm — the log assertions below would be vacuous (got: $CAOUT; log: $(cat "$CA/logs/mc.log"))"
grep -q 'github auth: app PAT' "$CA/logs/mc.log" \
  && bad "C: the conductor logged 'app PAT' — an installation token named as a PAT (log: $(cat "$CA/logs/mc.log"))" || ok
grep -q 'github auth: App installation token' "$CA/logs/mc.log" \
  && ok || bad "C: an App token armed by the PAT ladder must still be named as one (log: $(cat "$CA/logs/mc.log"))"
grep -q 'ghs_fixture_ladder' "$CA/logs/mc.log" \
  && bad "C: the conductor printed a TOKEN VALUE into its log" || ok

# ===========================================================================
# BLOCK D — bin/blocked-resolver.sh's own br-token block, by name (BH-597
#           ticket item 2). The resolver's PR-state reads themselves are main's
#           br_pr_field/br_pr_state (BH-783/#1157, bin/lib/gh-rest.sh) — see the
#           header note — and are covered by tests/blocked-resolver-test.sh and
#           friends, not here.
# ===========================================================================
D="$T/d"
mkdir -p "$D/bin/lib" "$D/logs" "$D/env" "$D/flags" "$D/fakebin"
cp "$DIR/bin/lib/gh-app-auth.sh" "$D/bin/lib/"
cat > "$D/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in o/r) echo "ghs_fixture_o_r" ;; *) exit 1 ;; esac
STUB
chmod +x "$D/bin/gh-token.sh"
printf 'GH_APP_ID=1\n' > "$D/env/github-app.env"
cat > "$D/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$D/gh-calls.txt"
case "\$*" in
  # o/invisible is the repo no credential of ours can see: the PAT probe 404s on
  # it and bin/gh-token.sh above refuses to mint for it.
  "api repos/o/invisible -q .id") exit 1 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$D/fakebin/gh"
: > "$D/fns.sh"
awk '/^# >>> br-token$/{p=1;next} /^# <<< br-token$/{exit} p{print}' "$DIR/bin/blocked-resolver.sh" >> "$D/fns.sh"
[ -s "$D/fns.sh" ] && grep -q 'br_use_token' "$D/fns.sh" \
  && ok || bad "D: could not extract the br-token block from bin/blocked-resolver.sh"
d_drive() {
  ( export HARNESS="$D" PATH="$D/fakebin:$PATH" GH_TOKEN=pat_fixture_default LOG="$D/logs/br.log"
    : > "$D/logs/br.log"; : > "$D/gh-calls.txt"
    env "$@" bash -c '
      . "$HARNESS/bin/lib/gh-app-auth.sh"
      LOG="$HARNESS/logs/br.log"
      STAMP() { echo "T"; }
      say() { echo "$(STAMP) $*" >> "$LOG"; }
      . "$HARNESS/fns.sh"
      br_use_token o/r; printf "ARMED=%s\n" "${GH_TOKEN:-}"
      br_use_token o/r
      br_reset_token; printf "RESET=%s\n" "${GH_TOKEN:-}"
    ' )
}
DOUT=$(d_drive HARNESS="$D")
grep -qx 'ARMED=ghs_fixture_o_r' <<<"$DOUT" \
  && ok || bad "D: br_use_token must arm the App installation token (got: $DOUT)"
grep -qx 'RESET=pat_fixture_default' <<<"$DOUT" \
  && ok || bad "D: br_reset_token must restore the run's own identity (got: $DOUT)"
[ "$(grep -c 'github auth:' "$D/logs/br.log")" = 1 ] \
  && ok || bad "D: two calls on one slug in one run must log the credential ONCE (log: $(cat "$D/logs/br.log"))"
grep -q 'ghs_fixture_o_r' "$D/logs/br.log" \
  && bad "D: the resolver printed a TOKEN VALUE into its log" || ok
# A repo NO credential can see. The App has no installation and the PAT probe
# answers `none`, which is the ABSENCE of a credential, not the name of one —
# the line has to say so. br_use_token still returns 0 here (the reads that
# follow fail and take their own "could not read" branch), so the honesty has to
# live in the log copy.
cp "$DIR/bin/lib/gh-repo-token.sh" "$D/bin/lib/"
DNONE=$( export HARNESS="$D" PATH="$D/fakebin:$PATH" GH_TOKEN=pat_fixture_default
  : > "$D/logs/br.log"
  bash -c '
    . "$HARNESS/bin/lib/gh-app-auth.sh"
    . "$HARNESS/bin/lib/gh-repo-token.sh"
    LOG="$HARNESS/logs/br.log"
    STAMP() { echo "T"; }
    say() { echo "$(STAMP) $*" >> "$LOG"; }
    . "$HARNESS/fns.sh"
    br_use_token o/invisible' 2>&1; cat "$D/logs/br.log" )
grep -q 'github auth: none PAT' <<<"$DNONE" \
  && bad "D: a repo no credential can see logs the word none as if it were a token: $DNONE" || ok
grep -q 'github auth: no credential' <<<"$DNONE" \
  && ok || bad "D: a repo no credential can see must say so in the auth line (got: $DNONE)"

# The same split rung as block C, on the resolver's own br_use_token.
DA="$T/da"
app_ladder_fixture "$DA" o/r ghs_fixture_ladder
cp "$D/fns.sh" "$DA/fns.sh"
DAOUT=$( export HARNESS="$DA" PATH="$DA/fakebin:$PATH" GH_TOKEN=pat_fixture_default
  : > "$DA/logs/br.log"
  bash -c '
    . "$HARNESS/bin/lib/gh-app-auth.sh"
    . "$HARNESS/bin/lib/gh-repo-token.sh"
    LOG="$HARNESS/logs/br.log"
    STAMP() { echo "T"; }
    say() { echo "$(STAMP) $*" >> "$LOG"; }
    . "$HARNESS/fns.sh"
    br_use_token o/r
    printf "ARMED=%s\n" "${GH_TOKEN:-}"
  ' 2>&1 )
grep -qx 'ARMED=ghs_fixture_ladder' <<<"$DAOUT" \
  && ok || bad "D: the PAT ladder's App rung did not arm — the log assertions below would be vacuous (got: $DAOUT; log: $(cat "$DA/logs/br.log"))"
grep -q 'github auth: app PAT' "$DA/logs/br.log" \
  && bad "D: the resolver logged 'app PAT' — an installation token named as a PAT (log: $(cat "$DA/logs/br.log"))" || ok
grep -q 'github auth: App installation token' "$DA/logs/br.log" \
  && ok || bad "D: an App token armed by the PAT ladder must still be named as one (log: $(cat "$DA/logs/br.log"))"
grep -q 'ghs_fixture_ladder' "$DA/logs/br.log" \
  && bad "D: the resolver printed a TOKEN VALUE into its log" || ok

# ===========================================================================
# BLOCK E — the tick's lock dies with the tick
# ===========================================================================
E="$T/e"; mkdir -p "$E"
SLEEPERS=""
kill_sleepers() { for p in $SLEEPERS; do kill "$p" 2>/dev/null; done; }
trap 'kill_sleepers' EXIT

held() { # held <lockfile> -> rc 0 when SOMETHING ELSE holds it
  [ -e "$1" ] || return 1
  if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi
  return 0
}

# NEGATIVE CONTROL FIRST. If a launch that does NOT close the descriptor fails to
# hold the lock here, then this machine cannot show the trap at all and every
# assertion below would pass vacuously.
( exec 9>"$E/control.lock"; flock -n 9 || exit 1
  setsid sleep 40 >/dev/null 2>&1 & echo $! > "$E/control.pid" ) 2>/dev/null
CTLPID=$(cat "$E/control.pid" 2>/dev/null); SLEEPERS="$SLEEPERS $CTLPID"
kill -0 "$CTLPID" 2>/dev/null && held "$E/control.lock" \
  && ok || bad "E: the leaky control did NOT hold the lock — this box cannot demonstrate the fd-inheritance trap, so nothing below is evidence"
kill "$CTLPID" 2>/dev/null

# --- the real bin/run-triage.sh ---------------------------------------------
EH="$E/h"
mkdir -p "$EH/bin/lib/rt" "$EH/bin/lib/jobs" "$EH/logs" "$EH/state" "$EH/flags" "$EH/env" "$EH/locks" \
         "$EH/prompts" "$EH/builds" "$EH/catalog/agent-contracts" "$EH/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$EH" alpha-os || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
   "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/triage-contract.sh" "$EH/bin/"
cp "$DIR"/bin/lib/rt/*.sh "$EH/bin/lib/rt/"
# BH-1033 (#1161) split bin/jobs-client.sh's modules into bin/lib/jobs/*.sh — a
# fixture that copies the client must copy the modules too, or the client dies
# on the missing-module guard before run-triage.sh ever reaches agent-call.sh.
cp "$DIR"/bin/lib/jobs/*.sh "$EH/bin/lib/jobs/"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$EH/catalog/agent-contracts/"
printf 'HARNESS_SECRET=test-secret\n' > "$EH/env/global.env"
printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$EH/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$EH/bin/beat.sh"; chmod +x "$EH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$EH/bin/decision-log.sh"; chmod +x "$EH/bin/decision-log.sh"
printf 'the SOP\n' > "$EH/prompts/alpha-os.md"
printf '#!/bin/bash\necho "RUN board-changed"\n' > "$EH/bin/triage-gate.sh"; chmod +x "$EH/bin/triage-gate.sh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$EH/fakebin/curl"; chmod +x "$EH/fakebin/curl"
# The agent session, as the incident produced it: a DETACHED child that outlives
# the call. If it inherits fd 9 the tick's lock is held for the build's life.
cat > "$EH/bin/agent-call.sh" <<EOF
#!/bin/bash
touch "$E/AGENT_CALLED"
setsid sleep 40 >/dev/null 2>&1 &
echo \$! > "$E/tick-child.pid"
exit 0
EOF
chmod +x "$EH/bin/agent-call.sh"
( export PATH="$EH/fakebin:$PATH" HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" \
         JOBS_URL=https://jobs.invalid JOBS_BOX=box-alpha
  bash "$DIR/bin/run-triage.sh" alpha-os >/dev/null 2>&1 )
ERC=$?
TICKPID=$(cat "$E/tick-child.pid" 2>/dev/null); SLEEPERS="$SLEEPERS $TICKPID"
[ "$ERC" = 0 ] && [ -f "$E/AGENT_CALLED" ] \
  && ok || bad "E: the tick did not reach agent-call.sh (rc=$ERC) — the fixture, not the lock, is what this would be measuring"
kill -0 "$TICKPID" 2>/dev/null \
  && ok || bad "E: the launched child is already gone, so 'the lock is free' proves nothing"
held "$EH/locks/alpha-os.lock" \
  && bad "E: locks/alpha-os.lock is STILL HELD after the tick exited — the agent session inherited fd 9, and the next tick will log 'previous run still active, skipping' for as long as the build runs" || ok
kill "$TICKPID" 2>/dev/null

# --- the real bin/triage-shard.sh, same trap on fd 8 ------------------------
printf '#!/bin/bash\necho "CONTRACT: end with DECISION lines."\n' > "$EH/bin/triage-contract.sh"
chmod +x "$EH/bin/triage-contract.sh"
cat > "$EH/bin/agent-call.sh" <<EOF
#!/bin/bash
touch "$E/SHARD_CALLED"
setsid sleep 40 >/dev/null 2>&1 &
echo \$! > "$E/shard-child.pid"
exit 0
EOF
chmod +x "$EH/bin/agent-call.sh"
printf 'triage this one ticket\n' > "$E/shard-prompt.txt"
( export PATH="$EH/fakebin:$PATH" HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" TSH_MODEL=fixture-model
  bash "$DIR/bin/triage-shard.sh" alpha-os AL-1 "$E/shard-prompt.txt" >/dev/null 2>&1 )
SRC=$?
SHPID=$(cat "$E/shard-child.pid" 2>/dev/null); SLEEPERS="$SLEEPERS $SHPID"
[ "$SRC" = 0 ] && [ -f "$E/SHARD_CALLED" ] \
  && ok || bad "E: the shard did not reach agent-call.sh (rc=$SRC)"
kill -0 "$SHPID" 2>/dev/null \
  && ok || bad "E: the shard's launched child is already gone, so 'the key lock is free' proves nothing"
held "$EH/locks/triage-key-alpha-os-AL-1.lock" \
  && bad "E: locks/triage-key-alpha-os-AL-1.lock is STILL HELD after the shard exited — the key's re-offer will be skipped as 'already being triaged' for the build's whole life" || ok
kill "$SHPID" 2>/dev/null

kill_sleepers
echo "gh-budget-rest-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
