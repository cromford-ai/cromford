#!/bin/bash
# tests/pool-push-rejected-landed.bh-6821-test.sh — a pool build whose push was
# reported rejected is not always a terminal (BH-6821).
#
# BH-5566 was built, its head was already on GitHub, and only the PR step did
# not run. The reap wrote a terminal, opened no PR and closed the row failed.
# Now the reap compares the head the machine built with the remote branch:
#
#   T1     bin/lib/rb/pr.sh names the built head in the rejected RESULT line
#   L1     identical (the BH-5566 replay) -> one pulls POST, RESULT line 1 is
#          PR_CREATED <url>, the row closes done, no terminal file
#   L2     ahead (remote contains the built head) -> PR opened, no terminal
#   L3     the POSTed body has Closes #<ticket> on line 2 (issues lane), ## Why,
#          ## Evidence, ## Opened by the hub with both shas, the footer and
#          the Harness- trailers
#   L4     identical but every create rung fails -> terminal, row failed, no
#          PR_CREATED line
#   L5     no sha in the line, reviewed-sha relayed (an older image) -> PR opened
#   D1     diverged, no strike file -> one requeue with continue_branch, strike
#          written, no terminal, no ALERTS line
#   D2     diverged with a fresh strike file -> terminal with ticket_id, row
#          failed, exactly one ALERTS line naming both shas
#   D3     diverged with an 8-day-old strike file -> requeue (as D1)
#   D4     behind and a 404 compare both read as diverged
#   U1     no sha in the line and no reviewed-sha -> terminal, no compare call
#   U2     compare answers 403 -> terminal, no PR POST
#   U3     ticket held -> terminal, no PR POST; POOL_PUSH_LANDED_OPEN=0 ->
#          terminal, no compare call
#   N1     a HOLD_YIELD deferral is not a push-rejected line: no compare
#   C1     queue_row_job_file keeps continue_branch, refuses ticket/x;rm (rc 3)
#   C2     builder-runner passes continue_branch as TARGET_BRANCH; an adopt
#          head still wins
#
# HOW IT DRIVES: the real bin/fly-pool.sh with fly/gh stubs (the bh-5912
# harness), bin/lib/pool-push-rejected.sh installed by its closure. The file
# anchors wall-clock time in $NOW; fixture timestamps are derived from it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
NOW=$(date +%s)

# The three shas of the story: the head the machine built, a remote head that
# diverged from it, and a remote head one commit ahead of it.
S=f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f
RDIV=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2
RAHEAD=a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3
BR=ticket/bh-t1
PRURL=https://github.com/example-org/project-5/pull/901

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/relay"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The queue client, recorded: every row write lands in $T/sink.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/sink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/sink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
# ppr_lib loads the trailers lib by name at open time, as a hub's full tree has it.
scratch_install_closure bin/lib/pr-trailers.sh "$H" >/dev/null || { echo "closure install of bin/lib/pr-trailers.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

# The new lib must be in the pool's closure, or no hub ever runs it.
[ -f "$H/bin/lib/pool-push-rejected.sh" ] && ok \
  || bad "closure: bin/lib/pool-push-rejected.sh is not sourced by bin/fly-pool.sh"

# Fly stub: the RESULT head, and a base64 relay of any file in $T/relay whose
# name is the artifact the reap asks for.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) cat "$T/result-line" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*)
    for f in "$T/relay"/*; do
      [ -f "\$f" ] || continue
      n=\$(basename "\$f")
      case "\$*" in *"/\$n\\\\ "*|*"/\$n "*) /usr/bin/base64 -w0 "\$f" 2>/dev/null || base64 -w0 "\$f"; exit 0 ;; esac
    done
    exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

# gh stub: every call to $T/gh-calls.log. Fixture files in $T:
#   remote-sha   the branch head the ref read answers
#   cmp-code     the compare's HTTP code (default 200); cmp-status its .status
#   post-code    the pulls POST's code (default 201)
#   held         present = the ticket thread's newest comment is a HOLD
# The POSTed PR body is copied to $T/pr-body-posted.md.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.log"
emit() { printf 'HTTP/1.1 %s X\\r\\n\\r\\n%s\\n' "\$1" "\$2"; }
case "\$1 \$2" in
  "pr create") echo "GraphQL: API rate limit already exceeded for installation ID 1" >&2; exit 1 ;;
  "pr list") exit 0 ;;
esac
PATHARG=""; METHOD=GET; I=0
for a in "\$@"; do
  case "\$a" in repos/*|user) [ -z "\$PATHARG" ] && PATHARG="\$a" ;; -i) I=1 ;; POST) METHOD=POST ;; esac
done
if [ "\$I" = 0 ]; then
  case "\$PATHARG" in
    *"/issues/61/comments"*)
      if [ -f "$T/held" ]; then
        echo '[{"created_at":"$(date -u -d @$((NOW-60)) '+%Y-%m-%dT%H:%M:%SZ')","body":"HOLD — do not build","user":{"type":"User","login":"fixture-lead"}}]'
      else echo '[]'; fi
      exit 0 ;;
    *"/issues/61") echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"Dispatcher fixture","body":""}'; exit 0 ;;
  esac
  exit 1
fi
case "\$METHOD \$PATHARG" in
  "GET repos/example-org/project-5") emit 200 '{"full_name":"example-org/project-5"}' ;;
  "GET repos/example-org/project-5/git/ref/heads/$BR")
    emit 200 "{\"object\":{\"sha\":\"\$(cat "$T/remote-sha" 2>/dev/null)\"}}" ;;
  "GET repos/example-org/project-5/compare/"*)
    emit "\$(cat "$T/cmp-code" 2>/dev/null || echo 200)" "{\"status\":\"\$(cat "$T/cmp-status" 2>/dev/null)\"}" ;;
  "GET repos/example-org/project-5/pulls?head="*) emit 200 '[]' ;;
  "GET repos/example-org/project-5/pulls?state=open"*) emit 200 '[]' ;;
  "POST repos/example-org/project-5/pulls")
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/pr-body-posted.md" ;; esac; done
    C=\$(cat "$T/post-code" 2>/dev/null || echo 201)
    if [ "\$C" = 201 ]; then emit 201 '{"number":901,"html_url":"$PRURL"}'
    else emit "\$C" '{"message":"fixture refusal"}'; fi ;;
  "GET repos/example-org/project-5/pulls/901")
    emit 200 '{"number":901,"state":"open","merged_at":null,"html_url":"$PRURL","head":{"ref":"$BR","sha":"$S"}}' ;;
  *) emit 404 '{"message":"Not Found"}' ;;
esac
exit 0
GH
chmod +x "$T/fakebin/gh"

run_pool() {
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" POOL_SPAWN=0 GH_TOKEN="" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reset_case() { # reset_case <result-line> <remote-sha> <cmp-status>
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/build-queue/project-5"/.[!.]* \
           "$H/state/fly-pool/project-5"/*.json "$H/state/pool/project-5"/* \
           "$H/builds"/* "$T/relay"/* "$T/sink" "$T/gh-calls.log" "$T/pr-body-posted.md" \
           "$T/cmp-code" "$T/post-code" "$T/held" "$H/logs/ALERTS.log"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  printf '%s\n' "$1" > "$T/result-line"
  printf '%s\n' "$2" > "$T/remote-sha"
  printf '%s\n' "$3" > "$T/cmp-status"
  : > "$T/sink"; : > "$T/gh-calls.log"; : > "$H/logs/ALERTS.log"
  jq -nc '{machine:"m-t1",key:"BH-T1",ticket_id:"61",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-14T23:00:00Z"}' \
    > "$H/state/fly-pool/project-5/m-t1.json"
  printf '{"title":"Dispatcher fixture","labels":[]}\n' > "$T/relay/ticket-meta.json"
  printf '# BH-T1 — fixture plan\n\n## Why\n\nThe dispatcher fixture needs a PR.\n\n## Scope\n\nnone\n' > "$T/relay/plan.md"
  printf 'evidence fixture line\n' > "$T/relay/evidence.md"
  return 0
}
rec() { ls -d "$H/builds/pool-project-5-BH-T1-"* 2>/dev/null | head -1; }
terminal() { [ -f "$H/state/pool/project-5/BH-T1.terminal" ]; }
posts() { grep -c '^api -i -X POST repos/example-org/project-5/pulls ' "$T/gh-calls.log" 2>/dev/null || true; }
compares() { grep -c 'repos/example-org/project-5/compare/' "$T/gh-calls.log" 2>/dev/null || true; }
line1() { head -1 "$(rec)/RESULT" 2>/dev/null; }
RJ="BUILD_DEFERRED push of $BR rejected at $S"

# ── T1: pr.sh names the head it built ──────────────────────────────────────
{
  blk=$(awk 'index($0, "# >>> pr push") {on=1} on {print} index($0, "# <<< pr push") {exit}' "$DIR/bin/lib/rb/pr.sh")
  if [ -z "$blk" ]; then
    bad "T1: bin/lib/rb/pr.sh has no '# >>> pr push' block"
  else
    G="$T/t1"; mkdir -p "$G/wt" "$G/build"
    git -C "$G/wt" init -q
    ( cd "$G/wt" && echo x > f && git add f && git -c user.name=FIXTURE -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm base )
    WANT=$(git -C "$G/wt" rev-parse HEAD)
    printf '%s\n' "$blk" > "$G/blk.sh"
    ( cd "$G/wt" && BUILD="$G/build" BRANCH=ticket/bh-t1 PROJECT=tproj KEY=BH-T1 bash -c '
        STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }
        GH_LIVE() { :; }; RB_PUSH() { return 1; }; track_pushed() { :; }; sleep() { :; }
        . "$0"' "$G/blk.sh" ) >/dev/null 2>&1
    RC=$?
    [ "$RC" = 3 ] && ok || bad "T1: a rejected push must exit 3, got $RC"
    [[ "$(head -1 "$G/build/RESULT" 2>/dev/null)" =~ ^BUILD_DEFERRED\ push\ of\ ticket/bh-t1\ rejected\ at\ [0-9a-f]{40}$ ]] \
      && ok || bad "T1: RESULT must end 'rejected at <40-hex>', got '$(cat "$G/build/RESULT" 2>/dev/null)'"
    [ "$(head -1 "$G/build/RESULT" 2>/dev/null)" = "BUILD_DEFERRED push of ticket/bh-t1 rejected at $WANT" ] \
      && ok || bad "T1: the sha must be the worktree HEAD $WANT"
  fi
}

# ── L1: identical — the BH-5566 replay ─────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  printf '%s\n' "$S" > "$T/relay/reviewed-sha"
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "L1: expected one pulls POST, got $(posts): $(cat "$T/gh-calls.log")"
  grep -q "head=$BR" "$T/gh-calls.log" && ok || bad "L1: the POST must name head=$BR"
  [ "$(line1 | awk '{print $1, $2}')" = "PR_CREATED $PRURL" ] && ok || bad "L1: RESULT line 1 must be PR_CREATED $PRURL, got '$(line1)'"
  sed -n 2p "$(rec)/RESULT" 2>/dev/null | grep -qF "$RJ" && ok || bad "L1: the rejected line must stay as line 2 for audit"
  grep -q "^done project-5 BH-T1 done" "$T/sink" && ok || bad "L1: the row must close done: $(cat "$T/sink")"
  grep -q "^done project-5 BH-T1 failed" "$T/sink" && bad "L1: the row was closed failed: $(cat "$T/sink")" || ok
  terminal && bad "L1: a terminal file was written for a push that landed" || ok
  grep -q "push-rejected BH-T1: landed at $S -> PR $PRURL" "$H/logs/fly-pool.log" && ok \
    || bad "L1: the landed line is missing: $(cat "$H/logs/fly-pool.log")"
  # L3 on the same POST
  PB="$T/pr-body-posted.md"
  for want in '## Why' 'The dispatcher fixture needs a PR.' '## Evidence' 'evidence fixture line' \
              '## Opened by the hub' "$S" '🤖 Generated with [Claude Code](https://claude.com/claude-code)'; do
    grep -qF "$want" "$PB" 2>/dev/null && ok || bad "L3: the PR body lacks '$want'"
  done
  grep -q "title=BH-T1: Dispatcher fixture" "$T/gh-calls.log" && ok || bad "L3: the PR title must be 'BH-T1: Dispatcher fixture'"
  # An issues-lane project (board prefix "-"): line 2 is `Closes #<ticket>`, as
  # pr.sh writes it, so the merge closes the issue and lead review finds the
  # thread. The trailers name the ticket at the foot.
  [ "$(sed -n 2p "$PB" 2>/dev/null)" = "Closes #61" ] && ok \
    || bad "L3: line 2 of the PR body must be 'Closes #61', got '$(sed -n 2p "$PB" 2>/dev/null)'"
  grep -qx 'Harness-Ticket: BH-T1' "$PB" 2>/dev/null && ok || bad "L3: the PR body lacks the 'Harness-Ticket: BH-T1' trailer"
  grep -q '^Harness-Job: ' "$PB" 2>/dev/null && ok || bad "L3: the PR body lacks the 'Harness-Job:' trailer"
}

# ── L2: ahead — the remote contains the built head ─────────────────────────
{
  reset_case "$RJ" "$RAHEAD" ahead
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "L2: expected one pulls POST, got $(posts)"
  terminal && bad "L2: terminal written for an ahead remote" || ok
  grep -qF "$RAHEAD" "$T/pr-body-posted.md" 2>/dev/null && grep -qF "$S" "$T/pr-body-posted.md" \
    && ok || bad "L3: the hub section must name the remote and the built sha"
}

# ── L4: identical, every create rung fails ────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 403 > "$T/post-code"
  run_pool
  terminal && ok || bad "L4: a failed open must fall back to the terminal"
  grep -q '^PR_CREATED' <<<"$(line1)" && bad "L4: a PR_CREATED line was written with no PR" || ok
  grep -q "^done project-5 BH-T1 failed" "$T/sink" && ok || bad "L4: the row must close failed"
}

# ── L5: an older image — no sha in the line, reviewed-sha relayed ─────────
{
  reset_case "BUILD_DEFERRED push of $BR rejected" "$S" identical
  printf '%s\n' "$S" > "$T/relay/reviewed-sha"
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "L5: the relayed reviewed-sha must stand in for the built head"
  terminal && bad "L5: terminal written" || ok
}

# ── D1: diverged, first strike ────────────────────────────────────────────
{
  reset_case "$RJ" "$RDIV" diverged
  run_pool
  Q="$H/state/build-queue/project-5/BH-T1.json"
  [ "$(jq -r '.continue_branch // ""' "$Q" 2>/dev/null)" = "$BR" ] && ok \
    || bad "D1: the queue file must carry continue_branch=$BR: $(cat "$Q" 2>/dev/null)"
  [ "$(jq -r '.ticket_id' "$Q" 2>/dev/null)" = 61 ] && ok || bad "D1: the queue file must keep ticket 61"
  grep -q "^put project-5 BH-T1 61 fly 1 .*\"continue_branch\":\"$BR\"" "$T/sink" && ok \
    || bad "D1: the row must be requeued with continue_branch in meta: $(cat "$T/sink")"
  grep -q "^done project-5 BH-T1 failed push to $BR rejected: remote $RDIV diverged from built $S" "$T/sink" && ok \
    || bad "D1: the reason must name both shas: $(cat "$T/sink")"
  [ -f "$H/state/pool/project-5/BH-T1.push-diverged" ] && ok || bad "D1: no strike file"
  terminal && bad "D1: a terminal was written on the first divergence" || ok
  [ "$(posts)" = 0 ] && ok || bad "D1: a PR was opened for a diverged branch"
  [ -s "$H/logs/ALERTS.log" ] && bad "D1: an ALERTS line on the first divergence: $(cat "$H/logs/ALERTS.log")" || ok
  grep -q "push-rejected BH-T1: diverged -> requeue 1 from $RDIV" "$H/logs/fly-pool.log" && ok \
    || bad "D1: the requeue line is missing: $(cat "$H/logs/fly-pool.log")"
}

# ── D2: diverged again — terminal and one ALERTS line ─────────────────────
{
  reset_case "$RJ" "$RDIV" diverged
  jq -nc --arg b "$S" --arg r "$RDIV" '{built:$b,remote:$r,at:"2026-10-15T00:00:00Z",ticket_id:"61"}' \
    > "$H/state/pool/project-5/BH-T1.push-diverged"
  run_pool
  terminal && ok || bad "D2: the second divergence must be terminal"
  [ "$(jq -r '.ticket_id // ""' "$H/state/pool/project-5/BH-T1.terminal" 2>/dev/null)" = 61 ] && ok \
    || bad "D2: the terminal file must carry ticket_id 61"
  grep -q "^done project-5 BH-T1 failed" "$T/sink" && ok || bad "D2: the row must close failed"
  [ "$(grep -F "$S" "$H/logs/ALERTS.log" | grep -cF "$RDIV")" = 1 ] && ok \
    || bad "D2: exactly one ALERTS line must name both shas: $(cat "$H/logs/ALERTS.log")"
  [ -f "$H/state/build-queue/project-5/BH-T1.json" ] && bad "D2: the second divergence was requeued" || ok
  [ -f "$H/state/pool/project-5/BH-T1.push-diverged" ] && bad "D2: the strike file must be removed" || ok
}

# ── D3: an 8-day-old strike is stale ──────────────────────────────────────
{
  reset_case "$RJ" "$RDIV" diverged
  jq -nc --arg b "$S" --arg r "$RDIV" '{built:$b,remote:$r,at:"old",ticket_id:"61"}' \
    > "$H/state/pool/project-5/BH-T1.push-diverged"
  touch -d "@$((NOW - 8*86400))" "$H/state/pool/project-5/BH-T1.push-diverged"
  run_pool
  [ "$(jq -r '.continue_branch // ""' "$H/state/build-queue/project-5/BH-T1.json" 2>/dev/null)" = "$BR" ] && ok \
    || bad "D3: a stale strike must requeue like a first one"
  terminal && bad "D3: terminal on a stale strike" || ok
}

# ── D4: behind and a 404 compare read as diverged ─────────────────────────
for d4 in behind 404; do
  if [ "$d4" = 404 ]; then reset_case "$RJ" "$RDIV" ""; echo 404 > "$T/cmp-code"
  else reset_case "$RJ" "$RDIV" behind; fi
  run_pool
  [ -f "$H/state/build-queue/project-5/BH-T1.json" ] && ok || bad "D4 ($d4): must requeue as diverged"
  [ "$(posts)" = 0 ] && ok || bad "D4 ($d4): no PR may open"
done

# ── U1: no built head anywhere ────────────────────────────────────────────
{
  reset_case "BUILD_DEFERRED push of $BR rejected" "$S" identical
  run_pool
  terminal && ok || bad "U1: an unknown built head must stay terminal"
  [ "$(compares)" = 0 ] && ok || bad "U1: no compare may be made without a built head"
}

# ── U2: the compare answers 403 ───────────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 403 > "$T/cmp-code"
  run_pool
  terminal && ok || bad "U2: an unreadable compare must stay terminal"
  [ "$(posts)" = 0 ] && ok || bad "U2: no PR on an unreadable compare"
}

# ── U3: a held ticket, and the knob at 0 ──────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  : > "$T/held"
  run_pool
  terminal && ok || bad "U3: a held ticket must stay terminal"
  [ "$(posts)" = 0 ] && ok || bad "U3: no PR on a held ticket"
  grep -q "push-rejected BH-T1: landed at $S but the ticket hold reads held — no PR opened" "$H/logs/fly-pool.log" && ok \
    || bad "U3: the held line is missing: $(grep push-rejected "$H/logs/fly-pool.log")"
  reset_case "$RJ" "$S" identical
  run_pool POOL_PUSH_LANDED_OPEN=0
  terminal && ok || bad "U3: POOL_PUSH_LANDED_OPEN=0 must keep the terminal"
  [ "$(compares)" = 0 ] && ok || bad "U3: POOL_PUSH_LANDED_OPEN=0 must make no compare"
}

# ── N1: other deferrals are not push-rejected lines ───────────────────────
{
  reset_case "BUILD_DEFERRED HOLD_YIELD BH-T1 at pr-push" "$S" identical
  run_pool
  [ "$(compares)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "N1: a HOLD_YIELD deferral must not compare or open"
}

# ── C1: queue_row_job_file carries continue_branch ────────────────────────
{
  Q="$T/c1"; mkdir -p "$Q/bin/lib" "$Q/logs"
  scratch_install_closure bin/lib/queue-row-job.sh "$Q" >/dev/null || bad "C1: closure install failed"
  OUT=$(HARNESS="$Q" bash -c '. "$0"; queue_row_job_file p "$1/job.json" BH-T1 61 1 "{\"continue_branch\":\"ticket/bh-t1\"}"; echo "rc=$?"' \
        "$Q/bin/lib/queue-row-job.sh" "$Q")
  [ "$OUT" = rc=0 ] && ok || bad "C1: a clean continue_branch must write (got $OUT)"
  [ "$(jq -r '.continue_branch // ""' "$Q/job.json" 2>/dev/null)" = ticket/bh-t1 ] && ok \
    || bad "C1: job.json must carry continue_branch: $(cat "$Q/job.json" 2>/dev/null)"
  OUT=$(HARNESS="$Q" bash -c '. "$0"; queue_row_job_file p "$1/bad.json" BH-T1 61 1 "{\"continue_branch\":\"ticket/x;rm\"}" >/dev/null; echo "rc=$?"' \
        "$Q/bin/lib/queue-row-job.sh" "$Q")
  [ "$OUT" = rc=3 ] && ok || bad "C1: ticket/x;rm must be refused rc 3 (got $OUT)"
  [ -f "$Q/bad.json" ] && bad "C1: a refused row wrote a job file" || ok
  HARNESS="$Q" bash -c '. "$0"; queue_row_job_file p "$1/plain.json" BH-T1 61 1 "{}"' "$Q/bin/lib/queue-row-job.sh" "$Q"
  [ "$(jq -r 'has("continue_branch")' "$Q/plain.json" 2>/dev/null)" = false ] && ok \
    || bad "C1: a row with no continue_branch must write no field"
}

# ── C2: builder-runner hands continue_branch to run-build.sh ───────────────
{
  R="$T/c2"; mkdir -p "$R/h/bin" "$R/path" "$R/job"
  awk '/^_run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$R/runner.sh"
  grep -q 'run-build.sh' "$R/runner.sh" && ok || bad "C2: could not extract _run_job from fly/builder-runner.sh"
  printf '#!/bin/bash\necho "TARGET_BRANCH=${TARGET_BRANCH:-}" >> "%s/called"\nexit 0\n' "$R" > "$R/h/bin/run-build.sh"
  chmod +x "$R/h/bin/run-build.sh"
  c2() { # c2 <job-json> <adopt-head-or-empty>
    rm -f "$R/called"; printf '%s\n' "$1" > "$R/job/job.json"
    printf '#!/bin/bash\ncase "$*" in *headRefName*) [ -n "%s" ] && echo %s ;; esac\nexit 0\n' "$2" "'[{\"headRefName\":\"$2\",\"title\":\"BH-T1: fixture\"}]'" > "$R/path/gh"
    chmod +x "$R/path/gh"
    timeout 60 env PATH="$R/path:$PATH" HARNESS="$R/h" JOB="$R/job/job.json" JOBDIR="$R/job" RESULT_FILE="$R/job/RESULT" \
        PROJECT=proj REPO="$R" bash -c '
      log() { :; }; load_env() { :; }; model_routes_warm() { :; }; slot_preflight() { return 0; }
      start_heartbeat() { :; }; stop_heartbeat() { :; }; beat() { :; }; fly_result_put() { :; }
      warm_up() { return 0; }
      . "$0"; _run_job' "$R/runner.sh" >/dev/null 2>&1
    head -1 "$R/called" 2>/dev/null
  }
  OUT=$(c2 '{"key":"BH-T1","ticket_id":"61","continue_branch":"ticket/bh-t1"}' "")
  [ "$OUT" = "TARGET_BRANCH=ticket/bh-t1" ] && ok || bad "C2: continue_branch must reach run-build.sh as TARGET_BRANCH, got '$OUT'"
  OUT=$(c2 '{"key":"BH-T1","ticket_id":"61","continue_branch":"ticket/bh-t1"}' "ticket/bh-t1-r2")
  [ "$OUT" = "TARGET_BRANCH=ticket/bh-t1-r2" ] && ok || bad "C2: an adopt head must win over continue_branch, got '$OUT'"
  OUT=$(c2 '{"key":"BH-T1","ticket_id":"61"}' "")
  [ "$OUT" = "TARGET_BRANCH=" ] && ok || bad "C2: no continue_branch and no adopt head must pass an empty TARGET_BRANCH, got '$OUT'"
}

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
