#!/bin/bash
# tests/pool-push-rejected-review.bh-7383-test.sh — a PR the hub opens after a
# "push rejected" deferral gets a build row, a head-bound review request and a
# migration-number check (BH-7383).
#
# example-org/project-6#1460 and #1607 were opened by the hub (BH-6821) and then
# nothing else happened: no beat named the PR, so the console card read
# `build: null`; no review was asked for, so no verdict ever came; and #1607
# carried a migration number main already used. The hand-off now runs once
# after such an open:
#
#   R1  identical compare: one PR POST, one `request <slug> 901 <head>` to
#       lead-verdict.sh, the LAST build beat for the key is stage pr_created
#       with the PR url, verdict "" and the machine bkey; review-request.txt =
#       `requested <head>`; the summary line says review requested
#   R2  a relayed APPROVE bound to the head: the beat verdict is APPROVE and
#       carries the RESULT tier, no lead-verdict call, `bound <head>`
#   R3  lead-verdict.sh refuses with HTTP 409: `requested <head> (already)`,
#       no ALERTS line
#   R4  lead-verdict.sh refuses with HTTP 500: `failed …`, exactly one ALERTS
#       line naming #901 and the head; the row still closes done once, no
#       terminal. R4b: two keys fail in one tick -> exactly two ALERTS lines
#   H1  the PR head moved after the open: the review binds to the new head
#   B1-B7  the bound-verdict table (APPROVE on the exact head only)
#   P1  a relayed plan.md wins: no contents GET
#   P2  no relayed plan, the branch has .harness/specs/<KEY>/plan.md: the PR
#       body's ## Why comes from it, plan-source names it
#   P3  the branch plan answers 404: the old body text, the PR still opens
#   M1-M11  the migration-number table (dir prisma/sql, main holds 0245_a.sql
#       and 0246_connector_writes.sql); M1 posts one comment naming both files;
#       M3b a modified file whose number main uses twice is not a collision;
#       M9b mode off; M11 a failed comment POST pages once
#   N1  a machine-opened PR_CREATED reap: no hand-off
#   N2  a diverged reap, a failed open, and POOL_PUSH_LANDED_OPEN=0: no hand-off
#
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
queue_put() { printf 'put %s\n' "\$*" >> "$T/sink"; echo queued; return 0; }
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
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.log"\nexit 0\n' "$T" > "$H/bin/beat.sh"
cat > "$H/bin/lead-verdict.sh" <<LV
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lv.log"
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

reset_case() { # reset_case <result-line> <remote-sha> <cmp-status>
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/build-queue/project-5"/.[!.]* \
           "$H/state/fly-pool/project-5"/*.json "$H/state/pool/project-5"/* \
           "$H/builds"/* "$T/relay"/* "$T/relay2"/* "$T/sink" "$T/gh-calls.log" "$T"/pr-body-posted-*.md \
           "$T/cmp-code" "$T/post-code" "$H/logs/ALERTS.log" "$T/beats.log" "$T/lv.log" "$T/lv-rc" "$T/lv-err" \
           "$T/pr-head" "$T/plan-code" "$T/branch-plan.md" "$T"/files-*.json "$T/dir-code" "$T/main-dir.json" \
           "$T/comment-code" "$T/comment-posted.md" "$T/result-line-2"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  printf '%s\nBUILD_DIR: /data/harness/builds/%s\n' "$1" "$MBD" > "$T/result-line"
  printf '%s\n' "$2" > "$T/remote-sha"
  printf '%s\n' "$3" > "$T/cmp-status"
  : > "$T/sink"; : > "$T/gh-calls.log"; : > "$H/logs/ALERTS.log"; : > "$T/beats.log"; : > "$T/lv.log"
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

# The main tree of prisma/sql for the M cases.
main_dir() {
  printf '[{"name":"0245_a.sql","path":"prisma/sql/0245_a.sql","type":"file"},{"name":"0246_connector_writes.sql","path":"prisma/sql/0246_connector_writes.sql","type":"file"},{"name":"README.md","path":"prisma/sql/README.md","type":"file"}]\n' > "$T/main-dir.json"
}

# ── R1: the BH-7383 replay ──────────────────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "R1: expected one pulls POST, got $(posts)"
  [ "$(lvreqs)" = 1 ] && ok || bad "R1: expected one lead review request, lv.log: $(cat "$T/lv.log")"
  grep -q "^request example-org/project-5 901 $S --notes .*\.harness/specs/BH-T1/plan\.md" "$T/lv.log" && ok \
    || bad "R1: the request must name the PR head $S and the plan path: $(cat "$T/lv.log")"
  [ "$(hbeats | grep -c .)" = 1 ] && ok || bad "R1: expected exactly one pr_created beat: $(cat "$T/beats.log")"
  LB=$(lastbeat)
  [ "$(jq -r '.stage' <<<"$LB" 2>/dev/null)" = pr_created ] && ok || bad "R1: the last build beat for BH-T1 must be pr_created, got $LB"
  [ "$(jq -r '.pr_url' <<<"$LB" 2>/dev/null)" = "$PRURL" ] && ok || bad "R1: the beat pr_url must be $PRURL"
  [ "$(jq -r '.verdict' <<<"$LB" 2>/dev/null)" = "" ] && ok || bad "R1: the beat verdict must be empty"
  [ "$(jq -r '.bkey' <<<"$LB" 2>/dev/null)" = "build:project-5:BH-T1:$MBD" ] && ok || bad "R1: the beat bkey must be the machine's, got $(jq -r '.bkey' <<<"$LB" 2>/dev/null)"
  [ "$(jq -r '.tier' <<<"$LB" 2>/dev/null)" = null ] && ok || bad "R1: no bound APPROVE -> tier null"
  [ "$(jq -r '.merged' <<<"$LB" 2>/dev/null)" = false ] && ok || bad "R1: merged must be false"
  [ "$(recf review-request.txt)" = "requested $S" ] && ok || bad "R1: review-request.txt must be 'requested $S', got '$(recf review-request.txt)'"
  [ "$(recf migration-check.txt)" = off ] && ok || bad "R1: no migration dir -> migration-check.txt 'off', got '$(recf migration-check.txt)'"
  grep -qF "push-rejected BH-T1: hand-off PR #901 head ${S:0:12}: row review, review requested, migrations off" "$H/logs/fly-pool.log" && ok \
    || bad "R1: the summary line is missing: $(grep push-rejected "$H/logs/fly-pool.log")"
  [ "$(grep -c '^done project-5 BH-T1 done' "$T/sink")" = 1 ] && ok || bad "R1: the row must close done once: $(cat "$T/sink")"
  [ "$(alerts)" = 0 ] && ok || bad "R1: an ALERTS line on a clean hand-off: $(halerts)"
}

# ── R2: a relayed APPROVE bound to the head ────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  printf '%s\nTIER: 2\nBUILD_DIR: /data/harness/builds/%s\n' "$RJ" "$MBD" > "$T/result-line"
  printf '## Review\n\nFine.\n\nVERDICT: APPROVE\n' > "$T/relay/review.md"
  printf '%s\n' "$S" > "$T/relay/reviewed-sha"
  # The full RESULT the reap relays carries the TIER line.
  printf '%s\nTIER: 2\nBUILD_DIR: /data/harness/builds/%s\n' "$RJ" "$MBD" > "$T/relay/RESULT"
  run_pool
  LB=$(lastbeat)
  [ "$(jq -r '.verdict' <<<"$LB" 2>/dev/null)" = APPROVE ] && ok || bad "R2: a bound APPROVE must beat verdict APPROVE, got $LB"
  [ "$(jq -r '.tier' <<<"$LB" 2>/dev/null)" = 2 ] && ok || bad "R2: a bound APPROVE beats the RESULT tier 2, got $(jq -r '.tier' <<<"$LB" 2>/dev/null)"
  [ "$(lvreqs)" = 0 ] && ok || bad "R2: a bound APPROVE must not ask for a lead review: $(cat "$T/lv.log")"
  [ "$(recf review-request.txt)" = "bound $S" ] && ok || bad "R2: review-request.txt must be 'bound $S', got '$(recf review-request.txt)'"
}

# ── R3: a request already stands (409) ─────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 1 > "$T/lv-rc"; printf 'HTTP 409\nlead-verdict: request refused: {"error":"exists"}\n' > "$T/lv-err"
  run_pool
  [ "$(recf review-request.txt)" = "requested $S (already)" ] && ok || bad "R3: 409 must read as already requested, got '$(recf review-request.txt)'"
  [ "$(alerts)" = 0 ] && ok || bad "R3: a 409 must not page: $(halerts)"
  grep -qF "review already" "$H/logs/fly-pool.log" && ok || bad "R3: the summary must say review already"
}

# ── R4: the request fails (500) ────────────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 1 > "$T/lv-rc"; printf 'HTTP 500\n' > "$T/lv-err"
  run_pool
  case "$(recf review-request.txt)" in "failed "*) ok ;; *) bad "R4: review-request.txt must start 'failed ', got '$(recf review-request.txt)'" ;; esac
  [ "$(halerts | grep -F '#901' | grep -cF "$S")" = 1 ] && [ "$(alerts)" = 1 ] && ok \
    || bad "R4: exactly one ALERTS line must name #901 and $S: $(halerts)"
  grep -qF "review failed" "$H/logs/fly-pool.log" && ok || bad "R4: the summary must say review failed"
  [ "$(grep -c '^done project-5 BH-T1' "$T/sink")" = 1 ] && grep -q '^done project-5 BH-T1 done' "$T/sink" && ok \
    || bad "R4: the row must close done exactly once: $(cat "$T/sink")"
  terminal && bad "R4: a terminal was written" || ok
  [ "$(hbeats | grep -c .)" = 1 ] && ok || bad "R4: the pr_created beat is still sent"
}

# ── R4b: two keys fail in one tick: two ALERTS lines ───────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 1 > "$T/lv-rc"; printf 'HTTP 500\n' > "$T/lv-err"
  printf 'BUILD_DEFERRED push of ticket/bh-t2 rejected at %s\nBUILD_DIR: /data/harness/builds/project-5-BH-T2-202610180000\n' "$S2" > "$T/result-line-2"
  printf '{"title":"Second fixture","labels":[]}\n' > "$T/relay2/ticket-meta.json"
  jq -nc '{machine:"m-t2",key:"BH-T2",ticket_id:"62",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-14T23:00:00Z"}' \
    > "$H/state/fly-pool/project-5/m-t2.json"
  run_pool
  [ "$(lvreqs 901)" = 1 ] && [ "$(lvreqs 902)" = 1 ] && ok || bad "R4b: one request per PR: $(cat "$T/lv.log")"
  [ "$(alerts)" = 2 ] && [ "$(halerts | grep -cF '#901')" = 1 ] && [ "$(halerts | grep -cF '#902')" = 1 ] && ok \
    || bad "R4b: exactly two ALERTS lines, one per PR: $(halerts)"
  [ "$(hbeats BH-T2 | jq -r '.pr_url' 2>/dev/null)" = https://github.com/example-org/project-5/pull/902 ] && ok \
    || bad "R4b: BH-T2 gets its own pr_created beat: $(cat "$T/beats.log")"
}

# ── H1: the head moved after the open ──────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  printf '%s\n' "$RAHEAD" > "$T/pr-head"
  run_pool
  grep -q "^request example-org/project-5 901 $RAHEAD " "$T/lv.log" && ok || bad "H1: the review must bind to the moved head: $(cat "$T/lv.log")"
}

# ── B1-B7: the bound-verdict table ─────────────────────────────────────────
bcase() { # bcase <name> <review.md text or -> <reviewed-sha or -> <pr head> <want APPROVE|"">
  reset_case "$RJ" "$S" identical
  [ "$2" = - ] || printf '%b' "$2" > "$T/relay/review.md"
  [ "$3" = - ] || printf '%s\n' "$3" > "$T/relay/reviewed-sha"
  printf '%s\n' "$4" > "$T/pr-head"
  run_pool
  local v; v=$(jq -r '.verdict' <<<"$(lastbeat)" 2>/dev/null)
  [ "$v" = "$5" ] && ok || bad "$1: beat verdict must be '$5', got '$v'"
  if [ "$5" = APPROVE ]; then
    [ "$(lvreqs)" = 0 ] && ok || bad "$1: a bound APPROVE makes no lead request"
  else
    [ "$(lvreqs)" = 1 ] && ok || bad "$1: an unbound head must get one lead request, got $(lvreqs)"
  fi
}
bcase B1 'VERDICT: APPROVE\n' "$S" "$S" APPROVE
bcase B2 'VERDICT: APPROVE\n' "$S" "$RAHEAD" ""
bcase B3 - - "$S" ""
bcase B4 'VERDICT: APPROVE\n' - "$S" ""
bcase B5 'VERDICT: BLOCK\n' "$S" "$S" ""
bcase B6 '## Round 1\n\nVERDICT: APPROVE\n\n## Round 2\n\nVERDICT: BLOCK\n' "$S" "$S" ""
bcase B7 'VERDICT: APPROVE\n' "${S:0:12}" "$S" ""

# ── P1-P3: the plan fallback ───────────────────────────────────────────────
{
  reset_case "$RJ" "$S" identical
  echo 200 > "$T/plan-code"; printf '# branch plan\n\n## Why\n\nThe branch plan says why.\n' > "$T/branch-plan.md"
  run_pool
  [ "$(gets 'contents/.harness/specs/')" = 0 ] && ok || bad "P1: a relayed plan must make no contents GET"
  grep -qF 'The dispatcher fixture needs a PR.' "$T/pr-body-posted-901.md" 2>/dev/null && ok || bad "P1: the relayed plan's why must be in the body"
  [ -f "$(rec)/plan-source" ] && bad "P1: plan-source written for a relayed plan" || ok

  reset_case "$RJ" "$S" identical
  scratch_rm "$T/relay/plan.md"
  echo 200 > "$T/plan-code"; printf '# branch plan\n\n## Why\n\nThe branch plan says why.\n\n## Scope\n\nx\n' > "$T/branch-plan.md"
  run_pool
  [ "$(gets "contents/.harness/specs/BH-T1/plan.md?ref=$BR")" = 1 ] && ok || bad "P2: one contents GET of the branch plan, got $(gets 'contents/.harness/specs/')"
  grep -qF 'The branch plan says why.' "$T/pr-body-posted-901.md" 2>/dev/null && ok \
    || bad "P2: the body ## Why must come from the branch plan: $(cat "$T/pr-body-posted-901.md" 2>/dev/null)"
  grep -qF 'plan.md was not relayed' "$T/pr-body-posted-901.md" 2>/dev/null && bad "P2: the body still says not relayed" || ok
  [ "$(recf plan-source)" = "branch:.harness/specs/BH-T1/plan.md@$BR" ] && ok || bad "P2: plan-source must name the branch file, got '$(recf plan-source)'"
  cmp -s "$(rec)/plan.md" "$T/branch-plan.md" && ok || bad "P2: the hub record plan.md must be the branch plan"

  reset_case "$RJ" "$S" identical
  scratch_rm "$T/relay/plan.md"
  run_pool
  [ "$(posts)" = 1 ] && ok || bad "P3: the PR must still open on a 404 plan"
  grep -qF 'plan.md was not relayed from the machine.' "$T/pr-body-posted-901.md" 2>/dev/null && ok || bad "P3: the body keeps the not-relayed text"
  [ -e "$(rec)/plan.md" ] && bad "P3: a plan.md was written on a 404" || ok
}

# ── M1-M10: the migration-number table ─────────────────────────────────────
mcase() { # mcase <name> <files-1 json> <want: collision|clean|off|could-not-run> [env...]
  local name="$1" files="$2" want="$3"; shift 3
  reset_case "$RJ" "$S" identical
  main_dir
  printf '%s\n' "$files" > "$T/files-1.json"
  run_pool MNR_DIR=prisma/sql "$@"
  local got; got=$(head -n 1 "$(rec)/migration-check.txt" 2>/dev/null | awk '{print $1}')
  [ "$got" = "$want" ] && ok || bad "$name: migration-check must be '$want', got '$(recf migration-check.txt)'"
  if [ "$want" = collision ]; then
    [ "$(comments)" = 1 ] && ok || bad "$name: exactly one comment POST, got $(comments)"
  else
    [ "$(comments)" = 0 ] && ok || bad "$name: no comment may be posted, got $(comments)"
  fi
}
mcase M1 '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]' collision
grep -qF 'prisma/sql/0246_agent_memory.sql' "$T/comment-posted.md" 2>/dev/null \
  && grep -qF 'prisma/sql/0246_connector_writes.sql' "$T/comment-posted.md" && ok \
  || bad "M1: the comment must name both files: $(cat "$T/comment-posted.md" 2>/dev/null)"
grep -qF "<!-- bh-7383 migration-number $S -->" "$T/comment-posted.md" 2>/dev/null && ok || bad "M1: the comment marker is missing"
grep -qF "migrations collision" "$H/logs/fly-pool.log" && ok || bad "M1: the summary must say migrations collision"
mcase M2 '[{"filename":"prisma/sql/0247_agent_memory.sql","status":"added"}]' clean
grep -qF "migrations clean" "$H/logs/fly-pool.log" && ok || bad "M2: the summary must say migrations clean"
mcase M3 '[{"filename":"prisma/sql/0246_connector_writes.sql","status":"modified"}]' clean
{ # M3b: main holds a legacy duplicate number; the PR only edits one of them
  reset_case "$RJ" "$S" identical
  printf '[{"name":"0246_connector_writes.sql","path":"prisma/sql/0246_connector_writes.sql","type":"file"},{"name":"0246_legacy.sql","path":"prisma/sql/0246_legacy.sql","type":"file"}]\n' > "$T/main-dir.json"
  printf '[{"filename":"prisma/sql/0246_legacy.sql","status":"modified"}]\n' > "$T/files-1.json"
  run_pool MNR_DIR=prisma/sql
  [ "$(recf migration-check.txt)" = clean ] && ok || bad "M3b: a modified main migration is not a collision, got '$(recf migration-check.txt)'"
  [ "$(comments)" = 0 ] && ok || bad "M3b: no comment for a modified main migration"
}
mcase M4 '[{"filename":"prisma/other/0246_x.sql","status":"added"}]' clean
mcase M5 '[{"filename":"prisma/sql/sub/0246_x.sql","status":"added"}]' clean
mcase M6 '[{"filename":"prisma/sql/README.md","status":"added"}]' clean
mcase M7 '[{"filename":"prisma/sql/0246_x.sql","status":"renamed","previous_filename":"prisma/sql/0300_x.sql"}]' collision
{ # M8: the colliding file is on page 2
  reset_case "$RJ" "$S" identical
  main_dir
  jq -nc '[range(0;100) | {filename:("src/f\(.).ts"),status:"added"}]' > "$T/files-1.json"
  printf '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]\n' > "$T/files-2.json"
  run_pool MNR_DIR=prisma/sql
  [ "$(recf migration-check.txt | head -n 1)" = collision ] && ok || bad "M8: a page-2 collision must be found, got '$(recf migration-check.txt)'"
  [ "$(comments)" = 1 ] && ok || bad "M8: one comment, got $(comments)"
}
{ # M9: the dir knob is empty
  reset_case "$RJ" "$S" identical
  main_dir
  printf '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]\n' > "$T/files-1.json"
  run_pool
  [ "$(recf migration-check.txt)" = off ] && ok || bad "M9: no dir -> off, got '$(recf migration-check.txt)'"
  [ "$(gets 'pulls/901/files')" = 0 ] && [ "$(gets 'contents/prisma/sql')" = 0 ] && ok || bad "M9: no files or contents GET when off"
  [ "$(comments)" = 0 ] && ok || bad "M9: no comment when off"
}
mcase M9b '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]' off MNR_MODE=off
{ # M10: the contents GET answers 500
  reset_case "$RJ" "$S" identical
  main_dir; echo 500 > "$T/dir-code"
  printf '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]\n' > "$T/files-1.json"
  run_pool MNR_DIR=prisma/sql
  case "$(recf migration-check.txt)" in could-not-run*) ok ;; *) bad "M10: a 500 must be could-not-run, got '$(recf migration-check.txt)'" ;; esac
  [ "$(comments)" = 0 ] && ok || bad "M10: no comment on a failed read"
  [ "$(grep -c '^done project-5 BH-T1 done' "$T/sink")" = 1 ] && ok || bad "M10: the row must close done once"
  terminal && bad "M10: a terminal was written" || ok
  [ "$(alerts)" = 0 ] && ok || bad "M10: a failed read must not page: $(halerts)"
}
{ # M11: the comment POST fails -> comment-failed and one ALERTS line
  reset_case "$RJ" "$S" identical
  main_dir; echo 500 > "$T/comment-code"
  printf '[{"filename":"prisma/sql/0246_agent_memory.sql","status":"added"}]\n' > "$T/files-1.json"
  run_pool MNR_DIR=prisma/sql
  [ "$(recf migration-check.txt | head -n 1)" = comment-failed ] && ok || bad "M11: a failed post must be comment-failed, got '$(recf migration-check.txt)'"
  [ "$(alerts)" = 1 ] && halerts | grep -qF '#901' && ok || bad "M11: one ALERTS line naming #901: $(halerts)"
}

# ── N1: a PR the machine opened itself ─────────────────────────────────────
{
  reset_case "PR_CREATED $PRURL" "$S" identical
  run_pool
  [ "$(hbeats | grep -c .)" = 0 ] && ok || bad "N1: a machine-opened PR gets no hand-off beat: $(cat "$T/beats.log")"
  [ "$(lvreqs)" = 0 ] && ok || bad "N1: no lead request for a machine-opened PR"
  [ -e "$(rec)/review-request.txt" ] && bad "N1: review-request.txt written" || ok
}

# ── N2: diverged, a failed open, the knob at 0 ─────────────────────────────
{
  reset_case "$RJ" "$RDIV" diverged
  run_pool
  [ "$(hbeats | grep -c .)" = 0 ] && [ "$(lvreqs)" = 0 ] && ok || bad "N2: a diverged reap gets no hand-off"
  reset_case "$RJ" "$S" identical
  echo 403 > "$T/post-code"
  run_pool
  [ "$(hbeats | grep -c .)" = 0 ] && [ "$(lvreqs)" = 0 ] && ok || bad "N2: a failed open gets no hand-off"
  reset_case "$RJ" "$S" identical
  run_pool POOL_PUSH_LANDED_OPEN=0
  [ "$(hbeats | grep -c .)" = 0 ] && [ "$(lvreqs)" = 0 ] && ok || bad "N2: POOL_PUSH_LANDED_OPEN=0 gets no hand-off"
}

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
