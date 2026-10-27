#!/bin/bash
# tests/batch-resolve-mergify-queued.bh-8623-test.sh — BH-8623: no harness push
# to a PR that Mergify holds, and Mergify's own check runs are not own CI.
#
# THE INCIDENT. At 16:06Z on 2026-10-27 bin/batch-resolve.sh read a CANCELLED
# run of Mergify's `Rule: queue on the harness label (queue)` check on #8570 as
# the PR's own CI being red. It rebased the PR and force-pushed it while the PR
# sat in Mergify batch #8620. The push dequeued #8570 and dissolved the batch.
#
#   U1-U8  mrt_own_red drops Mergify's own runs (app slug, else the name ERE)
#          and still counts every other app's run, whatever its name
#   P1-P4  mrt_rebase_pure asks mc_mergify_holds at the push: held = rc 4 and
#          nothing pushed; not held, unreadable or no URL = pushed as before
#   L1-L3  the SHIPPED lane against a real bare origin, provider mergify
#   L4     the blocked-resolver conflict rung (_brm_conflict) on rc 4
#
# `gh` is stubbed everywhere: 0 GitHub calls. Real git, real bare origin.
#
# Run from anywhere: tests/batch-resolve-mergify-queued.bh-8623-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
if [ -n "${BATCH_TEST_KEEP:-}" ]; then echo "fixture kept at $T"; else trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os

# ============================================================================
# U. mrt_own_red, over stubbed check-run bodies.
# ============================================================================
# OWNRED <body> -> "<rc>|<output>"
OWNRED() {
  ( . "$DIR/bin/lib/mc/train.sh" >/dev/null 2>&1 || exit 9
    FXBODY="$1"
    if [ "$1" = UNREADABLE ]; then gh_rest_var() { return 1; }
    else gh_rest_var() { printf -v "$1" %s "$FXBODY"; }; fi
    out=$(mrt_own_red "$SLUG" abc123); rc=$?
    printf '%s|%s' "$rc" "$out" )
}
MRULE_CANC='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"cancelled","app":{"slug":"mergify"}}'
MRULE_PROG='{"name":"Rule: queue on the harness label (queue)","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked in merge queue"}}'
R=$(OWNRED "{\"check_runs\":[$MRULE_CANC]}")
[ "$R" = "1|" ] && ok || bad "U1 a cancelled Mergify queue-rule run is not own CI (got: $R)"
R=$(OWNRED '{"check_runs":[{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"cancelled"}]}')
[ "$R" = "1|" ] && ok || bad "U2 the same name with no app object is Mergify's (got: $R)"
R=$(OWNRED '{"check_runs":[{"name":"Queue: Embarked in merge queue","status":"completed","conclusion":"failure","app":{"slug":"mergify"}}]}')
[ "$R" = "1|" ] && ok || bad "U3 a Mergify Queue: run is not own CI (got: $R)"
R=$(OWNRED '{"check_runs":[{"name":"Summary","status":"completed","conclusion":"failure","app":{"slug":"mergify"}}]}')
[ "$R" = "1|" ] && ok || bad "U4 any run of the mergify app is not own CI (got: $R)"
R=$(OWNRED '{"check_runs":[{"name":"lint (queue)","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}]}')
[ "$R" = "0|lint (queue)" ] && ok || bad "U5 a github-actions job named '(queue)' is own CI (got: $R)"
R=$(OWNRED '{"check_runs":[{"name":"queue-lint","status":"completed","conclusion":"failure"}]}')
[ "$R" = "0|queue-lint" ] && ok || bad "U6 'queue-lint' with no app is own CI (got: $R)"
R=$(OWNRED "{\"check_runs\":[{\"name\":\"Harness CI / shard 0\",\"status\":\"completed\",\"conclusion\":\"failure\",\"app\":{\"slug\":\"github-actions\"}},$MRULE_CANC]}")
[ "$R" = "0|Harness CI / shard 0" ] && ok || bad "U7 a mixed list names only the own-CI failure (got: $R)"
R=$(OWNRED UNREADABLE)
[ "${R%%|*}" = 2 ] && ok || bad "U8 an unreadable answer is still rc 2 (got: $R)"

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.skippedCherryPicks false
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts"
printf 'export const base = 1\n' > "$S/src/base.ts"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
printf '#!/bin/sh\nls src/*.ts | sort | jq -R . | jq -sc "{imports:.}" > scripts/worker-import-set.json\n' > "$S/scripts/regen.sh"
chmod +x "$S/scripts/regen.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/ci-stub.sh"; chmod +x "$S/ci-stub.sh"
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `bash scripts/regen.sh` |
ARCH
cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

```bash
bash ci-stub.sh
```
CLAUDEMD
git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$S" push -q origin main
BASE=$(git -C "$S" rev-parse HEAD)

# mkplain <branch> <marker> — one new source file off BASE, so a rebase onto the
# advanced main is a pure replay and the verdict carries.
mkplain() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const %s = 1\n' "$2" > "$S/src/plain-$2.ts"
  git -C "$S" add -A && git -C "$S" commit -qm "$2" >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_P=$(mkplain ticket/tk-p p)
HEAD_C=$(mkplain ticket/tk-13 c)
HEAD_M=$(mkplain ticket/tk-m m)
git -C "$S" checkout -q main
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null && git -C "$S" push -q origin main
remote_head() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }

# ============================================================================
# P. mrt_rebase_pure asks Mergify at the push. hold_push is a plain leased push
#    here; the lane cases below drive the real one.
# ============================================================================
git clone -q "$T/origin.git" "$T/prepo" 2>/dev/null
PURL="https://github.com/$SLUG/pull/77"
# PURE <holds-rc> [url] -> "<rc>|<output>"; $T/holds-calls.txt counts the reads.
PURE() {
  ( . "$DIR/bin/lib/mc/train.sh" >/dev/null 2>&1 || exit 9
    HRC="$1"
    mc_slug_of_url() { sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$1"; }
    mc_queue_provider() { printf mergify; }
    mc_mergify_holds() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/holds-calls.txt"
                         [ "$HRC" = 0 ] && printf 'Mergify queue check "embarked"'; return "$HRC"; }
    hold_push() { shift 3; git -C "$1" push -q --force-with-lease="refs/heads/$4:$5" "$2" "$3:refs/heads/$4"; }
    git -C "$T/prepo" fetch -q origin
    out=$(mrt_rebase_pure "$T/prepo" origin origin/main ticket/tk-p "$(remote_head ticket/tk-p)" /dev/null "" "$PROJ" ${2:+"$2"}); rc=$?
    printf '%s|%s' "$rc" "$out" )
}
: > "$T/holds-calls.txt"
R=$(PURE 0 "$PURL")
[ "${R%%|*}" = 4 ] && ok || bad "P1 a held PR returns rc 4 (got: $R)"
grep -q 'embarked' <<<"$R" && ok || bad "P1 and prints the Mergify reason (got: $R)"
[ "$(remote_head ticket/tk-p)" = "$HEAD_P" ] && ok || bad "P1 and pushes NOTHING"
grep -q "^$SLUG $PURL $HEAD_P\$" "$T/holds-calls.txt" && ok \
  || bad "P1 the read names the slug, url and pre-rebase head (calls: $(cat "$T/holds-calls.txt"))"
grep -q 'mrt-rb-' <<<"$(git -C "$T/prepo" worktree list)" && bad "P1 the worktree must be removed on rc 4" || ok
R=$(PURE 1 "$PURL")
[ "${R%%|*}" = 0 ] && [ "$(remote_head ticket/tk-p)" != "$HEAD_P" ] && ok \
  || bad "P2 an unheld PR is rebased and pushed (got: $R)"
git -C "$T/origin.git" update-ref refs/heads/ticket/tk-p "$HEAD_P"
R=$(PURE 2 "$PURL")
[ "${R%%|*}" = 0 ] && [ "$(remote_head ticket/tk-p)" != "$HEAD_P" ] && ok \
  || bad "P3 an unreadable Mergify answer pushes as before (got: $R)"
git -C "$T/origin.git" update-ref refs/heads/ticket/tk-p "$HEAD_P"
: > "$T/holds-calls.txt"
R=$(PURE 0)
[ "${R%%|*}" = 0 ] && [ "$(remote_head ticket/tk-p)" != "$HEAD_P" ] && ok \
  || bad "P4 no URL is today's behaviour: pushed (got: $R)"
[ ! -s "$T/holds-calls.txt" ] && ok || bad "P4 and Mergify is not read"

# ============================================================================
# L. The SHIPPED lane (bin/batch-resolve.sh) on a repo whose provider is
#    Mergify. Setup follows tests/batch-resolve-trains.bh-1269-test.sh.
# ============================================================================
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" \
         "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
# The lane's whole source closure (D46), except the ticket-ownership fence,
# which tests/batch-resolve-lead-fence.bh-1630-test.sh pins. Same as
# tests/batch-resolve-train-heads.bh-5804-test.sh.
: > "$H/bin/lib/ticket-ownership.sh"
scratch_install_closure bin/batch-resolve.sh "$H" >/dev/null || { echo "FAIL: the lane's closure could not be installed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
: > "$H/env/github-app.env"
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "'"$T"'/alerts.txt"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
flag_active() { [ -f "$T/h/flags/\$1" ]; }
flag_set() { :; }
merge_train_put() { echo "\$3"; }
EOF
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
hold_fixture_libs "$DIR" "$H" || exit 1
MERGIFY_B64=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# The block gate's paginated thread reads (bg_read): an empty thread, no BLOCK.
case "\$*" in *"--paginate -q"*) printf '%s\n' "\$*" >> "$T/gh-calls.txt"; exit 0 ;; esac
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
sha=\$(printf '%s\n' "\$*" | grep -oE 'commits/[0-9a-f]+' | head -1 | sed 's#commits/##')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"--json headRefOid"*)
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  # THE PROVIDER IS MERGIFY: the default branch carries queue_rules.
  *"contents/.mergify.yml"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"content":"$MERGIFY_B64"}\n'; exit 0 ;;
  # hold-push's stacked-children read (BH-5234): no PR is based on a ticket branch.
  *"pulls?state=open&base="*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0 ;;
  *"repos/$SLUG/rulesets"*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/commits/"*)
    if [ -f "$T/checks-\$sha.json" ]; then B=\$(cat "$T/checks-\$sha.json")
    else B='{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}'; fi
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$B"; exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"workflow_runs":[]}\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n'; exit 0 ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*) echo "https://github.com/$SLUG/pull/900"; exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

mkpr() { # mkpr <num> <branch> <head>
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg slug "$SLUG" '
    [{number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:"2026-10-27T15:00:00Z", labels:[]}]'
}
mkrec() { # mkrec <issue> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026102700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 13 103 "$HEAD_C"
run() { TRAIN_PARALLEL=1 bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
reset() {
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"
  rm -f "$T"/checks-*.json 2>/dev/null
  scratch_rm "$H/state/batch-resolve"
  git -C "$T/origin.git" update-ref refs/heads/ticket/tk-13 "$HEAD_C"
  echo "$HEAD_C" > "$H/builds/$PROJ-TK-13-202610270013/reviewed-sha"
}
REPLAY_RED='{"name":"replay-evals","status":"completed","conclusion":"failure"}'

# L1. THE INCIDENT: only Mergify's queue-rule runs on the head (one cancelled,
#     one in progress). Not own CI red, so no rebase and no push.
reset
mkpr 103 ticket/tk-13 "$HEAD_C" > "$T/prs.json"
printf '{"check_runs":[%s,%s]}' "$MRULE_CANC" "$MRULE_PROG" > "$T/checks-$HEAD_C.json"
run
[ "$(remote_head ticket/tk-13)" = "$HEAD_C" ] && ok || bad "L1 a Mergify-queued PR must not be pushed (log: $(grep '#103' "$LOG" | head -2))"
# NOT VACUOUS: the lane really read #103's check runs on a Mergify repo.
grep -q "commits/$HEAD_C/check-runs" "$T/gh-calls.txt" && ok \
  || bad "L1 the lane must reach #103's own-CI read (log: $(tail -3 "$LOG"))"
grep -q 'contents/.mergify.yml' "$T/gh-calls.txt" && ok || bad "L1 the provider probe must run"
grep -q 'own CI is red' "$LOG" && bad "L1 Mergify's queue rule must not read as own CI red: $(grep 'own CI is red' "$LOG" | head -1)" || ok
grep -q 'PARKED' "$LOG" && bad "L1 and must not park the PR" || ok
grep -qxF "103 $HEAD_C" "$STATE/own-red.txt" 2>/dev/null && bad "L1 own-red.txt must not name it" || ok
grep -qxF "103 $HEAD_C" "$STATE/rebased.txt" 2>/dev/null && bad "L1 rebased.txt must not name it" || ok

# L2. Own CI really is red, but Mergify holds the PR: nothing is pushed and the
#     rebase budget is not spent.
reset
mkpr 103 ticket/tk-13 "$HEAD_C" > "$T/prs.json"
printf '{"check_runs":[%s,%s]}' "$REPLAY_RED" "$MRULE_PROG" > "$T/checks-$HEAD_C.json"
run
[ "$(remote_head ticket/tk-13)" = "$HEAD_C" ] && ok || bad "L2 a Mergify-held PR must not be pushed even when own CI is red"
grep -q 'Mergify holds it' "$LOG" && grep -q 'nothing was pushed' "$LOG" && ok \
  || bad "L2 the hold must be said out loud (log: $(grep '#103' "$LOG" | head -3))"
grep -qxF "103 $HEAD_C" "$STATE/rebased.txt" 2>/dev/null && bad "L2 the rebase must not be spent: $(cat "$STATE/rebased.txt")" || ok
grep -qxF "103 $HEAD_C" "$STATE/own-red.txt" 2>/dev/null && bad "L2 and the PR must not be parked" || ok

# L3. CONTROL: own CI red, no Mergify check — the normal rebase still happens.
reset
mkpr 103 ticket/tk-13 "$HEAD_C" > "$T/prs.json"
printf '{"check_runs":[%s]}' "$REPLAY_RED" > "$T/checks-$HEAD_C.json"
run
[ "$(remote_head ticket/tk-13)" != "$HEAD_C" ] && ok || bad "L3 an unheld own-red PR is still rebased (log: $(grep '#103' "$LOG" | head -2))"
grep -q 'CARRIED' "$LOG" && ok || bad "L3 and the carry is said out loud"

# ============================================================================
# L4. The blocked-resolver conflict rung, _brm_conflict, with its ladder deps
#     stubbed (as tests/blocked-resolver-conflict-class.bh-1470-test.sh does for
#     its classifier) and the REAL mrt_rebase_pure under it.
# ============================================================================
scratch_install_closure bin/lib/br/opt/mechanical.sh "$H" >/dev/null || { echo "FAIL: the conflict rung's closure could not be installed"; exit 1; }
: > "$T/br.txt"
git -C "$T/repos/$PROJ" fetch -q origin
( export HARNESS="$H"; H="$H"; REPOS="$T/repos"
  . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  . "$H/bin/lib/br/opt/mechanical.sh" >/dev/null 2>&1
  say() { printf '%s\n' "$*" >> "$T/br.txt"; }
  br_ladder_class() { echo rebase-conflict; }
  br_cap_key() { echo ck; }
  br_pr_ref() { printf 'OPEN ticket/tk-m %s' "$HEAD_M"; }
  _brm_repo() { return 0; }
  br_conflict_kind() { echo "derived scripts/worker-import-set.json"; }
  mc_project_base() { echo main; }
  mc_queue_provider() { printf mergify; }
  mc_mergify_holds() { printf 'Mergify queue check "embarked"'; return 0; }
  br_record() { printf 'record %s\n' "$*" >> "$T/br.txt"; }
  br_event()  { printf 'event %s\n' "$*" >> "$T/br.txt"; }
  br_count()  { printf 'count %s\n' "$*" >> "$T/br.txt"; }
  MC_REMOTE=origin
  _brm_conflict "$PROJ" TK-m conflict-unresolvable "https://github.com/$SLUG/pull/88" "" TK-m
  echo "rc=$?" >> "$T/br.txt" )
[ "$(remote_head ticket/tk-m)" = "$HEAD_M" ] && ok || bad "L4 the conflict rung must not push a Mergify-held PR (br: $(cat "$T/br.txt"))"
grep -q 'Mergify holds the PR' "$T/br.txt" && ok || bad "L4 the hold is said out loud (br: $(cat "$T/br.txt"))"
grep -q '^count mechanical' "$T/br.txt" && bad "L4 no mechanical rung is counted" || ok
grep -q '^rc=1$' "$T/br.txt" && ok || bad "L4 the rung returns 1, today's ladder owns it (br: $(cat "$T/br.txt"))"

grep -q 'api.github.com\|https://api' "$T/gh-calls.txt" 2>/dev/null && bad "no real GitHub call is made" || ok

echo "batch-resolve-mergify-queued (BH-8623): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
