#!/bin/bash
# tests/mc-rebase-credentials-test.sh — mc_rebase must reach a PRIVATE repo, and
# must not claim an approval was rebound when it was not.
#
# THE DEFECT THIS PINS. bin/lib/merge-conductor-lib.sh cloned with
# `git clone https://github.com/<slug>.git`. That URL is unauthenticated and git
# does not read GH_TOKEN, so the conductor's own token routing
# (bin/lib/gh-repo-token.sh, which picks the ADMIN PAT for the repos the default
# one cannot see) was invisible to it. Every repo in the fleet is private, so
# every mc_rebase off the hub returned rc 4 — forever, silently, because the
# clone's stderr went to /dev/null. The push had the same hole one line later.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q x-access-token bin/lib/...` passes on a
# string that is built and never handed to git. The fake `git` here records
# every argv AND runs $GIT_ASKPASS the way git itself would, so the assertions
# are about the credential that actually reached the process — and about the
# token value NEVER appearing in an argv, a log line or the reused scratch
# clone, which is the reason the token is not embedded in the URL.
#
# Run from anywhere: tests/mc-rebase-credentials-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

OLDSHA=1111111111111111111111111111111111111111
NEWSHA=2222222222222222222222222222222222222222
DEFTOK=tok_DEFAULT_VALUE_0001
ADMTOK=tok_ADMIN_VALUE_0002
SLUG=Example/private-repo

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/fakebin" "$T/repos"

# --- the fake git: records argv, and asks askpass exactly like git does -------
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-argv.txt"
if [ -n "\${GIT_ASKPASS:-}" ] && [ -x "\${GIT_ASKPASS:-}" ]; then
  "\$GIT_ASKPASS" "Password for 'https://x-access-token@github.com': " >> "$T/git-askpass.txt"
fi
SUB=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -C) shift 2 ;;
    -c) shift 2 ;;
    *) SUB="\$1"; shift; break ;;
  esac
done
case "\$SUB" in
  ls-remote) # real git: \`-h HEAD\` lists nothing (HEAD is not under refs/heads) and --exit-code makes that rc 2
             case " \$* " in *" -h "*|*" --heads "*) exit 2 ;; esac
             if [ -n "\${GIT_CAPABLE_TOK:-}" ] && [ "\$(tail -1 "$T/git-askpass.txt" 2>/dev/null)" != "\$GIT_CAPABLE_TOK" ]; then
               echo "remote: Write access to repository not granted." >&2; exit 128; fi; exit 0 ;;
  clone)    D="\${!#}"; mkdir -p "\$D/.git"; exit 0 ;;
  worktree) if [ "\${1:-}" = add ]; then for a in "\$@"; do case "\$a" in /*) mkdir -p "\$a" ;; esac; done; fi; exit 0 ;;
  rev-parse) N=\$(cat "$T/revn" 2>/dev/null || echo 0); N=\$((N+1)); echo "\$N" > "$T/revn"
             if [ "\$N" = 1 ]; then echo "$OLDSHA"; else echo "$NEWSHA"; fi; exit 0 ;;
  push)     [ -n "\${MC_PUSH_FAILS:-}" ] && exit 1; exit 0 ;;
  *)        exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/git"
# gh: the 2026-09-12 shape — the DEFAULT token 404s on this repo, the admin sees it.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") [ "\${GH_TOKEN:-}" = "$ADMTOK" ] && { echo 42; exit 0; }; exit 1 ;;
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
export PATH="$T/fakebin:$PATH"

printf 'GH_ADMIN_TOKEN=%s\n' "$ADMTOK" > "$T/h/env/github-admin.env"; chmod 600 "$T/h/env/github-admin.env"
export GH_TOKEN="$DEFTOK"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-2504: the conductor pushes only through bin/lib/hold-push.sh (+ hold.sh).
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/gh-repo-token.sh"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export MC_REPOS="$T/repos"

reset_run() { : > "$T/git-argv.txt"; : > "$T/git-askpass.txt"; rm -f "$T/revn"; : > "$MC_LOG"; }

# ============================================================================
# 1. No hub clone: the repo is cloned over an AUTHENTICATED url, with the token
#    gh_repo_use_token picked — and the token value is nowhere it could leak.
# ============================================================================
reset_run
OUT=$(mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); RC=$?
[ "$RC" = 0 ] && ok || bad "a private repo must rebase, not return rc $RC (this is the project-5 rc-4-forever bug)"
[ "$OUT" = "$NEWSHA" ] && ok || bad "mc_rebase must print the new head (got '$OUT')"
grep -q "clone .*https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" \
  && ok || bad "clone must use the authenticated remote form, got: $(grep clone "$T/git-argv.txt")"
grep -q "clone .*https://github\.com/$SLUG\.git" "$T/git-argv.txt" \
  && bad "the bare unauthenticated https url must not be used to clone a private repo" || ok
grep -q "push .*https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" \
  && ok || bad "push must carry the same authenticated remote, got: $(grep push "$T/git-argv.txt")"

# The credential git actually received — and that it is the ADMIN one, the whole
# point of routing through gh_repo_use_token rather than whatever GH_TOKEN held.
grep -qF "$ADMTOK" "$T/git-askpass.txt" && ok || bad "git's credential helper must yield the token gh_repo_use_token selected (the admin PAT)"
grep -qF "$DEFTOK" "$T/git-askpass.txt" && bad "the default token was handed to git for a repo it cannot see" || ok

# NEVER in an argv, a log line, or the reused scratch clone.
grep -qF "$ADMTOK" "$T/git-argv.txt" && bad "the token value appeared in a git argv (visible in ps)" || ok
grep -qF "$DEFTOK" "$T/git-argv.txt" && bad "the default token value appeared in a git argv" || ok
grep -rqF "$ADMTOK" "$T/h/logs/" && bad "the token value reached a log file" || ok
grep -rqF "$ADMTOK" "$T/h/tmp" 2>/dev/null && bad "the token value was written into the reused scratch clone (a secret at rest)" || ok

# ============================================================================
# 1b. The DEFAULT token is not in GH_TOKEN on a box (gh keeps it in its keyring
#     and gh_repo_use_token RESETS the variable for a default-visible repo). The
#     credential must then come from `gh auth token`, or every default-token
#     rebase fetches unauthenticated and returns rc 4 — the 2026-09-13 shape.
# ============================================================================
reset_run
cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") exit 0 ;;   # the DEFAULT token sees this repo
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/fakebin/gh"
( unset GH_TOKEN; . "$T/h/bin/lib/gh-repo-token.sh"; . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
  OUT=$(mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); echo "$? $OUT" > "$T/rc-default.txt" )
read -r RC OUT < "$T/rc-default.txt"
[ "$RC" = 0 ] && ok || bad "a default-token repo with GH_TOKEN unset must still rebase (got rc $RC — the keyring token was not resolved)"
grep -qF "$DEFTOK" "$T/git-askpass.txt" && ok || bad "with GH_TOKEN unset the credential must come from 'gh auth token'"
grep -q "push .*https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" && ok || bad "the default-token path must still push over the authenticated remote (the scratch clone from section 1 is reused, so no clone is expected)"
# restore the two-token stub for the sections below
cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") [ "\${GH_TOKEN:-}" = "$ADMTOK" ] && { echo 42; exit 0; }; exit 1 ;;
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/fakebin/gh"

# ============================================================================
# 1c. A token that can SEE the repo is not a token that can FETCH it. The hub's
#     default fine-grained PAT passes gh_repo_use_token's metadata probe on
#     project-5 and git answers 403 "Write access to repository not granted".
#     The credential must be chosen by ls-remote, falling through to the admin
#     token — or every rebase on that repo is rc 4 forever (2026-09-13).
# ============================================================================
reset_run
export GH_TOKEN="$DEFTOK"
cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") exit 0 ;;   # metadata: the DEFAULT token "sees" it
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/fakebin/gh"
OUT=$(GIT_CAPABLE_TOK="$ADMTOK" mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); RC=$?
[ "$RC" = 0 ] && ok || bad "when only the admin token can read the remote, mc_rebase must still succeed (got rc $RC — the metadata probe was trusted over ls-remote)"
grep -q "ls-remote" "$T/git-argv.txt" && ok || bad "the credential must be chosen by an ls-remote probe, not by the metadata probe alone"
[ "$(grep -c "push " "$T/git-argv.txt")" = 1 ] && ok || bad "exactly one push"
grep -qi "using the admin token" "$MC_LOG" && ok || bad "falling through to the admin token must be logged (nothing says why was the whole defect)"
# and when NO candidate can read it, the setup fails loudly with rc 4, not a silent fetch
reset_run
OUT=$(GIT_CAPABLE_TOK="nope" mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); RC=$?
[ "$RC" = 4 ] && ok || bad "no readable credential must be rc 4 (got $RC)"
grep -qi "no configured token can read" "$MC_LOG" && ok || bad "no-credential must be logged by name"
# restore the two-token stub for the sections below
cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") [ "\${GH_TOKEN:-}" = "$ADMTOK" ] && { echo 42; exit 0; }; exit 1 ;;
  "auth token") echo "$DEFTOK"; exit 0 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$T/fakebin/gh"

# ============================================================================
# 2. The hub clone is preferred when it exists (it also enables the local gate)
# ============================================================================
reset_run
mkdir -p "$T/repos/private-repo/.git"
OUT=$(mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); RC=$?
[ "$RC" = 0 ] && ok || bad "the hub-clone path must rebase (rc $RC)"
grep -q "clone " "$T/git-argv.txt" && bad "a hub clone at \$MC_REPOS/<project> exists — mc_rebase must not clone again" || ok
grep -q "worktree add" "$T/git-argv.txt" && ok || bad "the hub path must add a worktree on the hub clone"
grep -q "remote set-url origin https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" && ok || bad "the hub-clone path must point origin at the x-access-token remote before fetching (a bare url makes git ask for a username and GitHub refuses token/token)"
grep -q "push .*https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" \
  && ok || bad "the hub path's push must use the authenticated remote too (the hub clone's origin may be unauthenticated)"
rm -rf "$T/repos/private-repo"

# ============================================================================
# 3. A failed approval rebind is NOT a successful rebase
# ============================================================================
# job_verdict_rebind returns 1 (no ledger row / outage) or 2 (the row makes no
# head claim). Either way the approval is still bound to the OLD sha, so
# reporting rc 0 makes the conductor transition to WAIT_CI as if rebound and the
# sweep then parks the PR on a sha nobody approved.
reset_run
job_verdict_rebind() { return 1; }
OUT=$(mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1"); RC=$?
[ "$RC" = 5 ] && ok || bad "a failed job_verdict_rebind must not read as rc 0 (got rc $RC)"
[ "$OUT" = "$NEWSHA" ] && ok || bad "the new head is still printed on rc 5 — the push DID happen"
grep -qi "rebind" "$MC_LOG" && ok || bad "a failed rebind must say so in the conductor log ('nothing says why' was the whole defect)"
reset_run
job_verdict_rebind() { return 2; }
mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1" >/dev/null; RC=$?
[ "$RC" = 5 ] && ok || bad "rc 2 from job_verdict_rebind (no claim to move) must also refuse to read as rebound (got rc $RC)"
reset_run
job_verdict_rebind() { return 0; }
mc_rebase "$SLUG" private-repo ticket/x-1 "$OLDSHA" "https://github.com/$SLUG/pull/1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "a rebind that worked must still be rc 0 (got $RC)"
unset -f job_verdict_rebind

# ============================================================================
# 4. End to end through bin/merge-conductor.sh: rebind-failed lands the PR in
#    NEEDS_REBASE, never WAIT_CI.
#
#    THE REBASE IS A DETACHED LANE JOB (2026-09-14): the tick spawns it and a
#    LATER tick reads its result file, so the row this section is about is
#    written one tick after the push. Both ticks run below, with the job waited
#    for in between — the credential assertions are about the same git argv
#    either way, because the job runs mc_rebase unchanged.
# ============================================================================
rm -rf "$T/h/state/merge-conductor"; mc_init
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# the only jobs-client function the rebase path touches, and it fails
printf 'job_verdict_rebind() { return 1; }\n' > "$T/h/bin/jobs-client.sh"
mkdir -p "$T/h/builds/demo-os-TK-21-202609120021"
echo "PR_CREATED https://github.com/$SLUG/pull/21" > "$T/h/builds/demo-os-TK-21-202609120021/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-21-202609120021/review.md"
echo "$OLDSHA" > "$T/h/builds/demo-os-TK-21-202609120021/reviewed-sha"
# BH-2504: demo-os is an issues lane here, so the rebase reads ticket #21's hold
# before it merges and again before it pushes — FIXTURE: an unheld ticket.
. "$DIR/tests/lib/hold-fixture.sh" && hold_fixture_answer_lib "$T/holdfx" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
. "$T/holdfx/hold-answer.sh"; hold_answer "\$@" && exit 0
case "\$*" in
  "api repos/$SLUG -q .id") [ "\${GH_TOKEN:-}" = "$ADMTOK" ] && { echo 42; exit 0; }; exit 1 ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":21,"url":"https://github.com/$SLUG/pull/21","headRefOid":"$OLDSHA","headRefName":"ticket/TK-21","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "" ;;
  *"actions/runs"*) printf 'completed|success\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
touch "$T/h/flags/merge-conductor-actions"
reset_run
tick21() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" GH_TOKEN="$DEFTOK" \
    MC_RR_PATH="$T/fakebin:$PATH" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
tick21                                   # spawns the detached rebase
JF21=$(mc_rb_file "$SLUG" 21 "$OLDSHA")
grep -q "$SLUG#21 REBASE_SPAWNED" "$MC_LOG" && ok || bad "the tick must SPAWN the rebase, not run it inline"
for _ in $(seq 1 100); do [ "$(jq -r .status "$JF21" 2>/dev/null)" = done ] && break; sleep 0.2; done
[ "$(jq -r .status "$JF21" 2>/dev/null)" = done ] && ok || bad "the detached rebase job never finished (status $(jq -r .status "$JF21" 2>/dev/null))"
[ "$(jq -r .rc "$JF21" 2>/dev/null)" = 5 ] && ok || bad "the job must record mc_rebase's rc 5 (got $(jq -r .rc "$JF21" 2>/dev/null))"
tick21                                   # reads the result
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
ST=$(awk -F'\t' -v k="$SLUG#21" '$1==k {print $2}' "$ROWS")
RS=$(awk -F'\t' -v k="$SLUG#21" '$1==k {print $7}' "$ROWS")
[ "$ST" = NEEDS_REBASE ] && ok || bad "a pushed rebase whose rebind failed must go back to NEEDS_REBASE, not '$ST'"
[ "$ST" != WAIT_CI ] && ok || bad "WAIT_CI here is the lie: the approval is still on the old sha"
grep -q "rebind-failed" <<<"$RS" && ok || bad "the row's reason must be rebind-failed (got '$RS')"
grep -q "push .*https://x-access-token@github\.com/$SLUG\.git" "$T/git-argv.txt" \
  && ok || bad "the conductor's own rebase must push over the authenticated remote"
grep -rqF "$ADMTOK" "$T/h/logs/" && bad "the token reached a conductor log" || ok

echo "mc-rebase-credentials-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
