#!/bin/bash
# tests/pool-push-rejected-behind.bh-9483-test.sh — a PR the hub opens after a
# "push rejected" deferral, on a branch behind main, gets a pool rebase queued
# at once, before the lead-review request (BH-9483, item 3 of #9406).
#
# project-6 TK-3738: ppr_reap_landed opened the PR straight from the remote
# branch and never read main, so the PR sat on outdated code until the
# conductor's land_rebase_arm saw the next merge on main.
#
#   B1  behind_by 3: one compare GET of main...ticket/bh-t1, one PR POST, one
#       `put RB-901-<head8>` row (kind rebase, pr 901, branch, remote head),
#       queued BEFORE the lead-review request; prepr-rebase.txt `queued RB-901-`
#   B2  behind_by 0: PR opened, no RB row, `current`
#   B3  behind_by 1 (edge): one RB row
#   B4  compare of main answers 500, then no behind_by: PR opens, no RB row, `unknown`
#   B5  POOL_PUSH_LANDED_REBASE=0: no compare GET of main, no RB row
#   B6  a stacked build (stack_base ticket/bh-parent): no compare of main, no RB row
#   B7  REBASE_ON_POOL unset: no RB row, `skipped`
#   B8  queue_put fails: `not-queued`, no `queued` say line
#   B9  every PR create rung fails: terminal as before, no RB row
#
# HOW IT DRIVES: the real bin/fly-pool.sh with fly/gh stubs (the bh-7383
# harness), the real bin/lib/merge-conductor-lib.sh. queue_put and the
# lead-verdict.sh stub append to one ordered log.
# HOW IT DRIVES: the real bin/fly-pool.sh with fly/gh stubs (the bh-6821
# harness). beat.sh and lead-verdict.sh are stubs that log their arguments;
# bin/alert-line.sh is the real one.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

S=f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f
S2=b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7
RAHEAD=a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3
RDIV=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2
BR=ticket/bh-t1
PRURL=https://github.com/example-org/project-5/pull/901
MBD=project-5-BH-T1-202610180000

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/relay" "$T/relay2"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/sink"; return 0; }
queue_put() {
  printf 'put %s\n' "\$*" >> "$T/sink"
  [ -f "$T/qput-fail" ] && case "\$2" in RB-*) return 1 ;; esac
  printf 'put %s\n' "\$2" >> "$T/order.log"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
# TEST-CHANGE (BH-7383): the scratch harness gets catalog/lanes.d/_lib.json, as a
# hub tree has it. bin/lib/verdict-parse.sh resolves VERDICT_WINDOW_LINES from
# that file (BH-1644); without it every verdict reads `unknown`. The suite went
# green on the builder only because the builder process had exported _VP_WINDOW
# (verdict_prime), and it went red in clean CI (run 39133671107). No assertion changes.
# A window the caller exported must not decide the run: CI has none.
unset _VP_WINDOW VERDICT_WINDOW_LINES
mkdir -p "$H/catalog/lanes.d" && cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/" || exit 1
scratch_install_closure bin/lib/pr-trailers.sh "$H" >/dev/null || { echo "closure install of bin/lib/pr-trailers.sh failed"; exit 1; }
# ppr_lib loads these by name at hand-off time, as a hub's full tree has them.
# On the merge base ppr-review.sh does not exist yet: the install fails and the
# hand-off cases below go red, which is this suite's reproduction.
scratch_install_closure bin/lib/ppr-review.sh "$H" >/dev/null 2>&1 || echo "note: bin/lib/ppr-review.sh is not installable"
scratch_install_closure bin/lib/migration-renumber.sh "$H" >/dev/null || { echo "closure install of bin/lib/migration-renumber.sh failed"; exit 1; }
# The conductor lib the RB-* reap arm already loads lazily (BH-7428): the new
# enqueue goes through its mc_pool_rebase_enqueue.
scratch_install_closure bin/lib/merge-conductor-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/merge-conductor-lib.sh failed"; exit 1; }
scratch_install_closure bin/lib/queue-row-job.sh "$H" >/dev/null || { echo "closure install of bin/lib/queue-row-job.sh failed"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.log"\nexit 0\n' "$T" > "$H/bin/beat.sh"
cat > "$H/bin/lead-verdict.sh" <<LV
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lv.log"
printf '%s\n' "\$*" >> "$T/order.log"
[ -f "$T/lv-err" ] && cat "$T/lv-err" >&2
exit "\$(cat "$T/lv-rc" 2>/dev/null || echo 0)"
LV
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$H/bin/beat.sh" "$H/bin/lead-verdict.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

# Fly stub: machine m-t2 answers from result-line-2 and relay2, every other
# machine from result-line and relay.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
RL="$T/result-line"; RD="$T/relay"
case "\$*" in *"--machine m-t2 "*) RL="$T/result-line-2"; RD="$T/relay2" ;; esac
case "\$*" in
  *"machine status"*) echo "State: started"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) cat "\$RL" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*)
    for f in "\$RD"/*; do
      [ -f "\$f" ] || continue
      n=\$(basename "\$f")
      case "\$*" in *"/\$n\\\\ "*|*"/\$n "*) base64 -w0 "\$f"; exit 0 ;; esac
    done
    exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

# gh stub. Every call goes to gh-calls.log. Fixture files in $T:
#   remote-sha, cmp-status, post-code   as in the bh-6821 suite (key BH-T1)
#   pr-head        the PR head GET pulls/901 answers (default $S)
#   plan-code      the branch plan.md contents GET code (default 404)
#   branch-plan.md its file
#   files-<k>.json pulls/901/files page k (default [])
#   dir-code       the contents GET of prisma/sql (default 200); main-dir.json its body
#   comment-code   the issues/901/comments POST code (default 201)
# Key BH-T2 (ticket 62) is ticket/bh-t2 -> PR 902, always identical at $S2.
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
    *"/issues/61/comments"*|*"/issues/62/comments"*) echo '[]'; exit 0 ;;
    *"/issues/61"|*"/issues/62") echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"Dispatcher fixture","body":""}'; exit 0 ;;
  esac
  exit 1
fi
case "\$METHOD \$PATHARG" in
  "GET repos/example-org/project-5") emit 200 '{"full_name":"example-org/project-5"}' ;;
  "GET repos/example-org/project-5/git/ref/heads/$BR")
    emit 200 "{\"object\":{\"sha\":\"\$(cat "$T/remote-sha" 2>/dev/null)\"}}" ;;
  "GET repos/example-org/project-5/git/ref/heads/ticket/bh-t2") emit 200 '{"object":{"sha":"$S2"}}' ;;
  "GET repos/example-org/project-5/compare/$S2..."*) emit 200 '{"status":"identical"}' ;;
  "GET repos/example-org/project-5/compare/main...$BR")
    emit "\$(cat "$T/main-cmp-code" 2>/dev/null || echo 200)" "\$(cat "$T/main-cmp-body" 2>/dev/null || echo '{"status":"identical"}')" ;;
  "GET repos/example-org/project-5/compare/"*)
    emit "\$(cat "$T/cmp-code" 2>/dev/null || echo 200)" "{\"status\":\"\$(cat "$T/cmp-status" 2>/dev/null)\"}" ;;
  "GET repos/example-org/project-5/pulls?head="*) emit 200 '[]' ;;
  "GET repos/example-org/project-5/pulls?state=open"*) emit 200 '[]' ;;
  "POST repos/example-org/project-5/pulls")
    N=901; U="$PRURL"
    case "\$*" in *"head=ticket/bh-t2"*) N=902; U="https://github.com/example-org/project-5/pull/902" ;; esac
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/pr-body-posted-\$N.md" ;; esac; done
    C=\$(cat "$T/post-code" 2>/dev/null || echo 201)
    if [ "\$C" = 201 ]; then emit 201 "{\"number\":\$N,\"html_url\":\"\$U\"}"
    else emit "\$C" '{"message":"fixture refusal"}'; fi ;;
  "GET repos/example-org/project-5/pulls/901/files?"*)
    K=\$(sed -E 's/.*[?&]page=([0-9]+).*/\1/' <<<"\$PATHARG")
    emit 200 "\$(cat "$T/files-\$K.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/example-org/project-5/pulls/902/files?"*) emit 200 '[]' ;;
  "GET repos/example-org/project-5/pulls/901")
    emit 200 "{\"number\":901,\"state\":\"open\",\"merged_at\":null,\"html_url\":\"$PRURL\",\"head\":{\"ref\":\"$BR\",\"sha\":\"\$(cat "$T/pr-head" 2>/dev/null || echo $S)\"}}" ;;
  "GET repos/example-org/project-5/pulls/902")
    emit 200 '{"number":902,"state":"open","merged_at":null,"html_url":"https://github.com/example-org/project-5/pull/902","head":{"ref":"ticket/bh-t2","sha":"$S2"}}' ;;
  "GET repos/example-org/project-5/contents/.harness/specs/BH-T1/plan.md?ref=$BR")
    C=\$(cat "$T/plan-code" 2>/dev/null || echo 404)
    if [ "\$C" = 200 ]; then emit 200 "{\"encoding\":\"base64\",\"content\":\"\$(base64 -w 60 "$T/branch-plan.md" | sed ':a;N;\$!ba;s/\n/\\\\n/g')\"}"
    else emit "\$C" '{"message":"Not Found"}'; fi ;;
  "GET repos/example-org/project-5/contents/prisma/sql?ref=main")
    emit "\$(cat "$T/dir-code" 2>/dev/null || echo 200)" "\$(cat "$T/main-dir.json" 2>/dev/null || echo '[]')" ;;
  "POST repos/example-org/project-5/issues/901/comments")
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment-posted.md" ;; esac; done
    C=\$(cat "$T/comment-code" 2>/dev/null || echo 201)
    emit "\$C" '{"id":1}' ;;
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

reset_case() { # reset_case <result-line> <remote-sha> <cmp-status> [stack-base]
  local p sb="${4:-}"
  for p in "$H/state/build-queue/project-5"/* "$H/state/build-queue/project-5"/.[!.]* \
           "$H/state/fly-pool/project-5"/*.json "$H/state/pool/project-5"/* \
           "$H/builds"/* "$T/relay"/* "$T/relay2"/* "$T/sink" "$T/gh-calls.log" "$T"/pr-body-posted-*.md \
           "$T/cmp-code" "$T/post-code" "$H/logs/ALERTS.log" "$T/beats.log" "$T/lv.log" "$T/lv-rc" "$T/lv-err" \
           "$T/pr-head" "$T/plan-code" "$T/branch-plan.md" "$T"/files-*.json "$T/dir-code" "$T/main-dir.json" \
           "$T/comment-code" "$T/comment-posted.md" "$T/result-line-2" \
           "$T/order.log" "$T/main-cmp-code" "$T/main-cmp-body" "$T/qput-fail" "$H/state/merge-conductor"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  printf '%s\nBUILD_DIR: /data/harness/builds/%s\n' "$1" "$MBD" > "$T/result-line"
  printf '%s\n' "$2" > "$T/remote-sha"
  printf '%s\n' "$3" > "$T/cmp-status"
  : > "$T/sink"; : > "$T/gh-calls.log"; : > "$H/logs/ALERTS.log"; : > "$T/beats.log"; : > "$T/lv.log"
  : > "$T/order.log"
  # Every case rebases on the pool unless it removes this line (B7).
  printf 'REBASE_ON_POOL=1\n' > "$H/env/project-5.env"
  jq -nc --arg sb "$sb" '{machine:"m-t1",key:"BH-T1",ticket_id:"61",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-14T23:00:00Z"} + (if $sb == "" then {} else {stack_base:$sb} end)' \
    > "$H/state/fly-pool/project-5/m-t1.json"
  printf '{"title":"Dispatcher fixture","labels":[]}\n' > "$T/relay/ticket-meta.json"
  printf '# BH-T1 — fixture plan\n\n## Why\n\nThe dispatcher fixture needs a PR.\n\n## Scope\n\nnone\n' > "$T/relay/plan.md"
  printf 'evidence fixture line\n' > "$T/relay/evidence.md"
  return 0
}
rec() { ls -d "$H/builds/pool-project-5-BH-T1-"* 2>/dev/null | head -1; }
terminal() { [ -f "$H/state/pool/project-5/BH-T1.terminal" ]; }
posts() { grep -c '^api -i -X POST repos/example-org/project-5/pulls ' "$T/gh-calls.log" 2>/dev/null || true; }
comments() { grep -c '^api -i -X POST repos/example-org/project-5/issues/901/comments ' "$T/gh-calls.log" 2>/dev/null || true; }
gets() { grep -c "$1" "$T/gh-calls.log" 2>/dev/null || true; }
# The build beats for a key, one JSON per line, in the order sent.
bbeats() { jq -c --arg k "${1:-BH-T1}" 'select(.kind == "build" and .ticket_key == $k)' "$T/beats.log" 2>/dev/null; }
hbeats() { bbeats "${1:-BH-T1}" | jq -c 'select(.stage == "pr_created")'; }
lastbeat() { bbeats "${1:-BH-T1}" | tail -n 1; }
lvreqs() { grep -c "^request example-org/project-5 ${1:-901} " "$T/lv.log" 2>/dev/null || true; }
recf() { cat "$(rec)/$1" 2>/dev/null; }
# The hand-off's own ALERTS lines. The harness writes others (the PR verify
# gate cannot probe the repo here), and those are not this suite's subject.
halerts() { grep -E 'lead review request|migration-number comment|bin/lib/ppr-review.sh' "$H/logs/ALERTS.log" 2>/dev/null; }
alerts() { halerts | grep -c . || true; }
RJ="BUILD_DEFERRED push of $BR rejected at $S"

K8="RB-901-${S:0:8}"
rbputs() { grep -c '^put project-5 RB-' "$T/sink" 2>/dev/null || true; }
rbmeta() { grep -m1 '^put project-5 RB-' "$T/sink" | sed 's/^[^{]*//'; }
maincmps() { grep -c "repos/example-org/project-5/compare/main\.\.\.$BR" "$T/gh-calls.log" 2>/dev/null || true; }
word() { recf prepr-rebase.txt | head -n 1 | awk '{print $1}'; }
behind() { reset_case "$RJ" "$S" identical "${2:-}"; printf '{"status":"diverged","behind_by":%s,"ahead_by":2}\n' "$1" > "$T/main-cmp-body"; }

# ── B1: behind_by 3 -> one RB row, before the review request ───────────────
{
  behind 3
  run_pool
  [ "$(maincmps)" = 1 ] && ok || bad "B1: expected one compare GET of main...$BR, got $(maincmps)"
  [ "$(posts)" = 1 ] && ok || bad "B1: expected one pulls POST, got $(posts)"
  [ "$(rbputs)" = 1 ] && ok || bad "B1: expected one put RB- line, sink: $(cat "$T/sink")"
  grep -q "^put project-5 $K8 901 fly " "$T/sink" && ok || bad "B1: the row key must be $K8 with ticket 901: $(grep RB- "$T/sink")"
  M=$(rbmeta)
  [ "$(jq -r '.kind' <<<"$M" 2>/dev/null)" = rebase ] && ok || bad "B1: meta kind must be rebase: $M"
  [ "$(jq -r '.pr' <<<"$M" 2>/dev/null)" = 901 ] && ok || bad "B1: meta pr must be 901: $M"
  [ "$(jq -r '.branch' <<<"$M" 2>/dev/null)" = "$BR" ] && ok || bad "B1: meta branch must be $BR: $M"
  [ "$(jq -r '.head' <<<"$M" 2>/dev/null)" = "$S" ] && ok || bad "B1: meta head must be the remote head $S: $M"
  # The writer/reader round trip: the pool's own row -> job file mapping takes it.
  JF="$T/b1-job.json"
  ( . "$DIR/bin/lib/queue-row-job.sh" && HARNESS="$H" queue_row_job_file project-5 "$JF" "$K8" 901 0 "$M" >/dev/null 2>&1 )
  [ "$(jq -r '.rebase.pr' "$JF" 2>/dev/null)" = 901 ] && [ "$(jq -r '.rebase.head' "$JF" 2>/dev/null)" = "$S" ] && ok \
    || bad "B1: queue_row_job_file must map the row to rebase.pr 901 / head $S: $(cat "$JF" 2>/dev/null)"
  PL=$(grep -n "^put $K8\$" "$T/order.log" | head -1 | cut -d: -f1)
  RL=$(grep -n '^request example-org/project-5 901 ' "$T/order.log" | head -1 | cut -d: -f1)
  [ -n "$PL" ] && [ -n "$RL" ] && [ "$PL" -lt "$RL" ] && ok || bad "B1: the RB row must come before the review request: $(cat "$T/order.log")"
  recf prepr-rebase.txt | head -n 1 | grep -q "^queued $K8 behind_by=3" && ok || bad "B1: prepr-rebase.txt must say queued $K8 behind_by=3, got '$(recf prepr-rebase.txt)'"
  grep -q "push-rejected BH-T1: .*pool rebase queued as $K8" "$H/logs/fly-pool.log" && ok || bad "B1: no 'pool rebase queued as' say line"
  terminal && bad "B1: no terminal expected" || ok
}

# ── B2: behind_by 0 -> no row ──────────────────────────────────────────────
{
  behind 0
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "B2: the PR must open, posts=$(posts)"
  [ "$(rbputs)" = 0 ] && ok || bad "B2: no RB row for a branch that is current"
  [ "$(word)" = current ] && ok || bad "B2: prepr-rebase.txt must say current, got '$(recf prepr-rebase.txt)'"
  [ "$(lvreqs)" = 1 ] && ok || bad "B2: the review request still goes out"
}

# ── B3: behind_by 1 (edge) -> one row ──────────────────────────────────────
{
  behind 1
  run_pool
  [ "$(rbputs)" = 1 ] && ok || bad "B3: behind_by 1 must queue one RB row, got $(rbputs)"
  [ "$(word)" = queued ] && ok || bad "B3: prepr-rebase.txt must say queued"
}

# ── B4: the compare of main does not read -> today's behavior ──────────────
{
  reset_case "$RJ" "$S" identical
  echo 500 > "$T/main-cmp-code"
  run_pool
  [ "$(maincmps)" = 1 ] && ok || bad "B4: one compare GET of main expected, got $(maincmps)"
  [ "$(posts)" = 1 ] && ok || bad "B4: a 500 compare still opens the PR"
  [ "$(rbputs)" = 0 ] && ok || bad "B4: a 500 compare queues no RB row"
  [ "$(word)" = unknown ] && ok || bad "B4: prepr-rebase.txt must say unknown, got '$(recf prepr-rebase.txt)'"
  reset_case "$RJ" "$S" identical
  printf '{"status":"identical"}\n' > "$T/main-cmp-body"
  run_pool
  [ "$(posts)" = 1 ] && [ "$(rbputs)" = 0 ] && [ "$(word)" = unknown ] && ok || bad "B4: no behind_by must open the PR, queue nothing, say unknown"
  for v in '"3a"' '-1'; do
    reset_case "$RJ" "$S" identical
    printf '{"status":"diverged","behind_by":%s}\n' "$v" > "$T/main-cmp-body"
    run_pool
    [ "$(posts)" = 1 ] && [ "$(rbputs)" = 0 ] && [ "$(word)" = unknown ] && ok || bad "B4: behind_by $v must read unknown and queue nothing"
  done
}

# ── B5: the knob at 0 ──────────────────────────────────────────────────────
{
  behind 3
  run_pool POOL_PUSH_LANDED_REBASE=0
  [ "$(posts)" = 1 ] && ok || bad "B5: the PR must open with the knob at 0"
  [ "$(maincmps)" = 0 ] && ok || bad "B5: no compare of main with the knob at 0, got $(maincmps)"
  [ "$(rbputs)" = 0 ] && ok || bad "B5: no RB row with the knob at 0"
}

# ── B6: a stacked build ────────────────────────────────────────────────────
{
  behind 3 ticket/bh-parent
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "B6: the stacked PR must open, posts=$(posts)"
  grep -q 'base=ticket/bh-parent' "$T/gh-calls.log" && ok || bad "B6: the PR base must be the stack base"
  [ "$(maincmps)" = 0 ] && ok || bad "B6: no compare of main for a stacked PR, got $(maincmps)"
  [ "$(rbputs)" = 0 ] && ok || bad "B6: no RB row for a stacked PR"
}

# ── B7: REBASE_ON_POOL off ─────────────────────────────────────────────────
{
  behind 3
  : > "$H/env/project-5.env"
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "B7: the PR must open"
  [ "$(rbputs)" = 0 ] && ok || bad "B7: no RB row with REBASE_ON_POOL off"
  [ "$(word)" = skipped ] && ok || bad "B7: prepr-rebase.txt must say skipped, got '$(recf prepr-rebase.txt)'"
}

# ── B8: the queue refuses ──────────────────────────────────────────────────
{
  behind 3
  : > "$T/qput-fail"
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "B8: the PR must open"
  [ "$(word)" = not-queued ] && ok || bad "B8: prepr-rebase.txt must say not-queued, got '$(recf prepr-rebase.txt)'"
  grep -q 'pool rebase queued as' "$H/logs/fly-pool.log" && bad "B8: a refused queue must not say queued" || ok
  [ "$(lvreqs)" = 1 ] && ok || bad "B8: the review request still goes out"
}

# ── B9: every PR create rung fails ─────────────────────────────────────────
{
  behind 3
  echo 403 > "$T/post-code"
  run_pool
  terminal && ok || bad "B9: a failed open is terminal, as before"
  [ "$(rbputs)" = 0 ] && ok || bad "B9: no RB row without a PR"
}

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
