#!/bin/bash
# tests/batch-resolve-test.sh — bin/batch-resolve.sh (BH-498): land approved
# siblings whose ONLY conflicts are registry / union / regenerable files as ONE
# merge-time train, instead of one rebase + one full CI run per PR.
#
# THE POLICY THIS PINS, and it is the reason the suite exists at all: one
# ticket, one PR, one review, ALWAYS. Batching is a merge-time optimization,
# never a review-time one. So every assertion below is about what happens AFTER
# each PR already has its own head-bound APPROVE — a PR without one must never
# reach the union branch, and the union branch itself is never reviewed.
#
# WHY THE GIT HALF IS DRIVEN AGAINST A REAL REPOSITORY (the merge-funnel suite's
# rule, for the same reason): every claim here is about what `git merge`,
# `git merge-tree` and a `merge=union` attribute actually do. A stubbed git
# would only prove the shell around them is spelled right, which was never the
# part in doubt. A real bare origin is built with four branches and the fake
# remote url is pointed at it with `url.<path>.insteadOf` — real git, real
# merges, no network. `gh` IS stubbed, always: nothing here may touch GitHub.
#
# The one thing worth knowing before reading the fixture: git honours
# `merge=union` in BOTH `git merge` and `git merge-tree --write-tree` (probed on
# git 2.55), so a union-marked registry file never surfaces as a conflict at all
# — it is concatenated silently. The assertion for it is therefore on the landed
# TREE (all three markers present), not on a resolver being called.
#
# Run from anywhere: tests/batch-resolve-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-6672: this suite printed a pool box's real App token. No credential, HOME
# or gh login from the box reaches it, even if scratch.sh ever stops unsetting.
unset GH_TOKEN GITHUB_TOKEN
export HOME="$T/home" GH_CONFIG_DIR="$T/gh-config"
mkdir -p "$HOME"
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# BATCH_TEST_KEEP=1 leaves the whole fixture world behind (a real bare origin, a
# real harness tree, every log) — the only practical way to debug a failure in a
# suite whose subject clones, merges and pushes.
if [ -n "${BATCH_TEST_KEEP:-}" ]; then echo "fixture kept at $T"; else trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os

# --- a real repository, and a real remote that never leaves this box ---------
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
# The remote can be made to refuse a push, which is the only honest way to drive
# the refusal path: the lane names its own branch, so a test cannot collide with
# it from outside.
cat > "$T/origin.git/hooks/update" <<HOOK
#!/bin/sh
case "\$1" in
  refs/heads/batch/*) [ -f "$T/push-block" ] && { echo "fixture: pushes to batch/* are blocked" >&2; exit 1; } ;;
esac
exit 0
HOOK
chmod +x "$T/origin.git/hooks/update"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts" "$S/tests"

# tests/static-guards.txt is the UNION file; scripts/worker-import-set.json is
# the REGENERABLE one. Both shapes are taken from the real conflict tail this
# ticket came from.
printf 'tests/static-guards.txt merge=union\n' > "$S/.gitattributes"
printf 'guard-base\n' > "$S/tests/static-guards.txt"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
printf 'export const base = 1\n' > "$S/src/base.ts"
printf 'export const shared = "M1"\n' > "$S/src/shared.ts"

# The stub regenerate command: it COUNTS its own runs (that is the whole point
# of the deferred-regenerate design — three members must not buy three runs)
# and rewrites the registry deterministically from the tree it is run against.
cat > "$S/scripts/regen.sh" <<REGEN
#!/bin/sh
echo ran >> "$T/regen-count.txt"
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"

# The stub verification contract. Two armable failures, because the split has two
# shapes worth driving: one half red (ci-fails-on-c), and the WHOLE union red
# with both halves green (ci-fails-on-quad) — which is the case that used to push
# two conflicting trains in one pass.
cat > "$S/ci-stub.sh" <<CISTUB
#!/bin/sh
if [ -f "$T/ci-fails-on-c" ] && grep -q guard-c tests/static-guards.txt; then
  echo "union is red: guard-c" >&2
  exit 1
fi
if [ -f "$T/ci-fails-on-quad" ] \\
   && grep -q guard-a tests/static-guards.txt && grep -q guard-b tests/static-guards.txt \\
   && grep -q guard-c tests/static-guards.txt && grep -q guard-e tests/static-guards.txt; then
  echo "union is red: all four together" >&2
  exit 1
fi
exit 0
CISTUB
chmod +x "$S/ci-stub.sh"

# The two per-repo declarations bin/batch-resolve.sh reads: the regenerate table
# (without which the lane is OFF for this repo) and the verification contract.
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

These are regenerated, never hand-edited.

| File | Regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `bash scripts/regen.sh` |
ARCH

cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

Load-bearing suite, run in full before any merge:

```bash
bash ci-stub.sh
```
CLAUDEMD

git -C "$S" add -A && git -C "$S" commit -qm base && git -C "$S" push -q origin main
BASE=$(git -C "$S" rev-parse HEAD)

# mkbranch <name> <marker> — one approved sibling: a new source file of its own,
# a line appended to the UNION registry, and a whole-file rewrite of the
# REGENERABLE one. Against main each is clean; against EACH OTHER both registry
# files collide, which is exactly the tail this lane exists for.
mkbranch() {
  local br="$1" m="$2"
  git -C "$S" checkout -q -b "$br" "$BASE"
  printf 'export const %s = 1\n' "$m" > "$S/src/feature-$m.ts"
  printf 'guard-base\nguard-%s\n' "$m" > "$S/tests/static-guards.txt"
  printf '{"imports":["src/base.ts","src/feature-%s.ts"]}\n' "$m" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$m" && git -C "$S" push -q origin "$br"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mkbranch ticket/tk-11 a)
HEAD_B=$(mkbranch ticket/tk-12 b)
HEAD_C=$(mkbranch ticket/tk-13 c)
# A fourth sibling of the same shape, so a red union can be split into two halves
# that are BOTH green — the case that must still push exactly one train.
HEAD_E=$(mkbranch ticket/tk-15 e)

# The fourth: it collides with main in a SOURCE file, which is the one thing
# that must keep a PR out of the batch.
git -C "$S" checkout -q -b ticket/tk-14 "$BASE"
printf 'export const shared = "D"\n' > "$S/src/shared.ts"
git -C "$S" add -A && git -C "$S" commit -qm d && git -C "$S" push -q origin ticket/tk-14
HEAD_D=$(git -C "$S" rev-parse HEAD)

git -C "$S" checkout -q main
printf 'export const shared = "M2"\n' > "$S/src/shared.ts"
git -C "$S" add -A && git -C "$S" commit -qm advance && git -C "$S" push -q origin main

# --- the harness tree --------------------------------------------------------
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" \
         "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
# gh-rest.sh rides along because the conductor lib sources it (BH-784) and the
# issue close-out this lane makes goes through it. Without the file the lib's
# close-out shim calls a function that does not exist and every close "fails".
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-1586: the hotfix proof's PR-files read is the paged gh_rest list reader.
cp "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/" 2>/dev/null
# BH-1606: a train PR opens ONLY under the repo's App installation token, never
# the lead's PAT (a PAT-authored train reads as a lead PR and is fenced for ever).
# This box can mint one: the App env file and a gh-token.sh answering ghs_.
cp "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/"; : > "$H/env/github-app.env"
# TEST-CHANGE (BH-1630): the lane now reads the token's expiry (`gh-token.sh
# --expires-at`) before it pushes a union, so the stub answers one, far ahead.
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
# board_prefix "-" = a GitHub-issue project, so the member close-out is an issue
# close and this suite can assert it without a board API.
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "'"$T"'/alerts.txt"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# The jobs client: the ledger is a file, and nothing else is defined — every
# other job_* call must fail-open, which is the production contract too.
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\${4:-}" >> "$T/mqueue.tsv"; echo queued; }
EOF

# The hub clone bin/batch-resolve.sh prefers, and MC_REPOS points at it.
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# --- the fake gh -------------------------------------------------------------
# Every call is logged. The PR list is a fixture file; the train's state is a
# fixture file; every write is recorded and never performed.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
# A COMMENT BODY TRAVELS BY FILE, NEVER ON ARGV (BH-781/BH-784): gh_rest_comment
# posts it as -F body=@<tmpfile>, so the sentence the assertions read is not in
# "\$*" at all. The file's content is logged next to the call, or a body claim
# can only be checked by a test that reaches into the lane's temp files.
for a in "\$@"; do
  case "\$a" in body=@*) cat "\${a#body=@}" >> "$T/gh-calls.txt" 2>/dev/null; echo >> "$T/gh-calls.txt" ;; esac
done
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  # The close-out is REST since BH-784: this tree has no bin/lib/issue-state-lib.sh,
  # so the conductor lib's shim runs, and that shim now posts the comment and
  # PATCHes the issue through bin/lib/gh-rest.sh. Same claims, new verb — and
  # gh_rest_close only believes the PATCH after a fresh GET says closed, so the
  # PATCH has to actually move the issue in this stub's world.
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    if [ -f "$T/comment-fails-\$num" ]; then printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"no"}\n'; exit 0; fi
    printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n'; exit 0 ;;
  *"api -i -X PATCH repos/$SLUG/issues/"*)
    if [ -f "$T/close-fails-\$num" ]; then printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"no"}\n'; exit 0; fi
    touch "$T/issue-closed-\$num"
    printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n'; exit 0 ;;
  # TEST-CHANGE (BH-1585): the proof-comment read is the paged gh_rest reader
  # (\`api -i -X GET …/issues/N/comments -F per_page=100 -F page=1\`), the same
  # as #1605's files read: one page of REST comment objects from the same
  # fixture, the production filter running in the lib.
  *"api -i -X GET "*"/issues/"*"/comments"*)
    cnum=\$(printf '%s\n' "\$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    if [ -f "$T/comments-\$cnum.json" ]; then jq -c '.comments | map({body: .body, user: {login: "operator"}})' "$T/comments-\$cnum.json"
    else printf '[]\n'; fi
    exit 0 ;;
  *"api -i -X GET repos/$SLUG/issues/"*)
    if [ -f "$T/issue-closed-\$num" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n'
    else printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; fi; exit 0 ;;
  # The member's CURRENT head, re-read at settle time. A fixture file per PR
  # overrides it, which is how "somebody pushed to a member branch while the
  # train was in flight" is driven.
  *"--json headRefOid"*)
    cat "$T/head-\$num.txt" 2>/dev/null && exit 0
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  # BH-1586: a gh_rest read — the contents object with base64 content, or 404.
  *"contents/.mergify.yml"*)
    [ -f "$T/mergify-on" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n{"content":"%s"}\n' "\$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')"; exit 0 ;;
  *"rulesets"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  # BH-1586: the hotfix proof's files read is the paged gh_rest reader
  # (\`api -i -X GET …/pulls/N/files -F per_page=100 -F page=1\`); the production
  # jq filter now runs in the lib, so the fixture answers the raw REST array.
  *"api -i -X GET "*"/pulls/"*"/files"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    if [ -f "$T/files-\$num.json" ]; then cat "$T/files-\$num.json"; else printf '[]'; fi
    echo; exit 0 ;;
  # The two reads the hotfix migration-proof gate makes (BH-370.2). The
  # PRODUCTION --jq expression is applied to the fixture with REAL jq, so what
  # is under test is the expression bin/lib/merge-conductor-lib.sh ships and not
  # a paraphrase of it. No fixture file = the answer GitHub gives for a PR with
  # no added files / no comments.
  *"/pulls/"*"/files"*)
    jqx=""; want=0
    for a in "\$@"; do
      [ "\$want" = 1 ] && { jqx="\$a"; want=0; continue; }
      case "\$a" in --jq|-q) want=1 ;; esac
    done
    if [ -f "$T/files-\$num.json" ]; then jq -r "\${jqx:-.}" "$T/files-\$num.json"
    else printf '[]' | jq -r "\${jqx:-.}"; fi
    exit 0 ;;
  *"--json comments"*)
    jqx=""; want=0
    for a in "\$@"; do
      [ "\$want" = 1 ] && { jqx="\$a"; want=0; continue; }
      case "\$a" in --jq|-q) want=1 ;; esac
    done
    cnum=\$(printf '%s\n' "\$*" | sed -nE 's#.*pr view ([0-9]+).*#\1#p')
    if [ -f "$T/comments-\$cnum.json" ]; then jq -r "\${jqx:-.}" "$T/comments-\$cnum.json"
    else printf '{"comments":[]}' | jq -r "\${jqx:-.}"; fi
    exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  # (BH-781) settle_member writes through bin/lib/gh-rest.sh, so these three
  # arms answer in that library's wire shape: a status line, a blank line, then
  # the body. The close is a PATCH plus a VERIFYING RE-READ — gh_rest_close
  # returns 0 only once the re-read agrees the PR is closed, which is why a
  # refused PATCH
  # can no longer be followed by a ledger row.
  *"api -i -X PATCH repos/$SLUG/pulls/"*)
    if [ -f "$T/close-fails-\$num" ]; then
      printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"close refused for \$num"}\n'; exit 1; fi
    # AN ACCEPTED CLOSE MOVES THE OBJECT. A refused one does not, which is what
    # makes the next pass a real retry and not a replay against a constant.
    # A MERGED PR NEVER BECOMES PLAIN 'closed': GitHub takes 'state=closed' on a
    # merged PR with a 200 and keeps merged_at, so gh_rest_pr_state keeps saying
    # 'merged' and gh_rest_close keeps answering 75. Flattening it here would
    # hide exactly the "this member never settles" bug F6 is for.
    [ "\$(cat "$T/pr-state-\$num.txt" 2>/dev/null)" = merged ] \
      || printf 'closed\n' > "$T/pr-state-\$num.txt"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
  # THE MEMBER PR AS AN OBJECT, not a constant (BH-781 fix round). There are now
  # TWO reads on this path with opposite meanings: settle_member reads the state
  # BEFORE it writes (an already-merged member must not be commented on or
  # PATCHed, or it never settles and the train never closes), and gh_rest_close
  # re-reads AFTER its PATCH. Answering "closed" to both made the pre-read
  # believe every member was already settled. Default is OPEN; a scenario writes
  # \$T/pr-state-<n>.txt to say otherwise.
  *"api -i -X GET repos/$SLUG/pulls/"*)
    case "\$(cat "$T/pr-state-\$num.txt" 2>/dev/null)" in
      closed) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n' ;;
      merged) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":"2026-09-19T00:00:00Z"}\n' ;;
      *)      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
    esac
    exit 0 ;;
  *"pr create"*)
    [ -f "$T/pr-create-fails" ] && { echo "gh: pr create refused" >&2; exit 1; }
    # --body-file <path> is copied out so the members listed in the train's body
    # can be asserted on.
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$T/train-body.txt"
      prev="\$a"
    done
    cat "$T/train-url.txt" 2>/dev/null || echo "https://github.com/$SLUG/pull/900"
    exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/9"*)
    # the TRAIN's own PR
    cat "$T/train-state.json" 2>/dev/null || echo '{}'
    exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# macOS has no flock(1), and the lane takes the fleet's ordinary dedupe lock. On
# the platform of record — Debian, bin/run-tests-in-docker.sh — the real one is
# used and this shim is never installed; it exists so the suite can be iterated
# on a Mac at all.
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

# mkpr <num> <branch> <head> <mergeState> <created> [labels-csv]
mkpr() {
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg m "$4" --arg c "$5" --arg slug "$SLUG" \
         --arg lbl "${6:-}" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:$m, mergeable:"MERGEABLE", state:"OPEN", createdAt:$c,
     labels:(if $lbl == "" then [] else ($lbl|split(",")|map({name:.})) end)}'
}
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-16T03:00:00Z
  mkpr 104 ticket/tk-14 "$HEAD_D" DIRTY 2026-09-16T04:00:00Z; } | jq -sc '.' > "$T/prs.json"

# The build records that carry each PR's own head-bound APPROVE. The record NAME
# is what mc_issue_of reads the issue number out of.
mkrec() { # mkrec <issue> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026091600$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 11 101 "$HEAD_A"
mkrec 12 102 "$HEAD_B"
mkrec 13 103 "$HEAD_C"
mkrec 14 104 "$HEAD_D"
mkrec 15 105 "$HEAD_E"

run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
reset() {
  # Under BATCH_TEST_KEEP every scenario's log is kept, in order, in one file:
  # each scenario starts from an empty log so its own assertions are about its
  # own lines, and a debugger still needs the whole run.
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"
                                     echo "--- stdout/stderr ---"; cat "$T/run.out"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$T/regen-count.txt"; : > "$T/ledger.tsv"
  : > "$T/mqueue.tsv"; : > "$LOG"; : > "$T/run.out"; : > "$T/alerts.txt"
  rm -f "$T/train-body.txt" "$T/train-state.json"
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor/batch-hold"; scratch_rm "$H/state/merge-queue"
  rm -f "$H/state/merge-conductor/attempts.txt"
  rm -f "$H/tmp/merge-queue-"*.provider 2>/dev/null
  rm -f "$T"/head-*.txt "$T"/close-fails-* "$T"/comment-fails-* "$T"/pr-state-*.txt \
        "$T/pr-create-fails" "$T/mergify-on" "$T/push-block"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
}
batch_branches() {
  git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/'
}
nbatch() { batch_branches | grep -c . ; }

# ============================================================================
# 1. THE KILL FLAGS. Neither may so much as look at GitHub.
# ============================================================================
reset
touch "$H/flags/batch-resolve-off"
run
[ ! -s "$T/gh-calls.txt" ] && ok || bad "flags/batch-resolve-off must stop the lane before any gh call"
[ "$(nbatch)" = 0 ] && ok || bad "flags/batch-resolve-off must push no batch branch"
rm -f "$H/flags/batch-resolve-off"

reset
printf 'BATCH_RESOLVE=0\n' > "$H/env/$PROJ.env"
run
[ ! -s "$T/gh-calls.txt" ] && ok || bad "BATCH_RESOLVE=0 must stop the lane for that project"
[ "$(nbatch)" = 0 ] && ok || bad "BATCH_RESOLVE=0 must push no batch branch"
rm -f "$H/env/$PROJ.env"

# ============================================================================
# 2. A REPO THAT DECLARES NO REGENERATE TABLE IS OFF BY DEFAULT
#    The lane's whole premise is that the repo has told us which files are
#    machine-written. Without that list every conflict is a source conflict.
# ============================================================================
reset
git -C "$S" checkout -q main
git -C "$S" rm -q AGENT_ARCHITECTURE.md
git -C "$S" commit -qm "drop the generated-files table" && git -C "$S" push -q origin main
run
[ "$(nbatch)" = 0 ] && ok || bad "a repo with no regenerate table must do nothing"
grep -q 'no regenerate' "$LOG" && ok || bad "and must say why, once"
git -C "$S" revert --no-edit HEAD >/dev/null 2>&1 && git -C "$S" push -q origin main

# ============================================================================
# 3. THE HAPPY PATH: one union branch, one regenerate, three members, one train
# ============================================================================
reset
run
[ "$(nbatch)" = 1 ] && ok || bad "exactly one union branch must be pushed (got $(nbatch))"
BR=$(batch_branches)
case "$BR" in batch/$PROJ/*) ok ;; *) bad "the union branch must be batch/<project>/<stamp> (got '$BR')" ;; esac
[ "$(grep -c . "$T/regen-count.txt")" = 1 ] && ok \
  || bad "the regenerate command must run exactly ONCE for the whole union (got $(grep -c . "$T/regen-count.txt"))"

# the landed tree: every member's work is in it, the union file carries all
# three markers, and the registry is what the regenerate command produced.
TREE=$(git -C "$T/origin.git" show "$BR:tests/static-guards.txt" 2>/dev/null)
grep -q guard-a <<<"$TREE" && grep -q guard-b <<<"$TREE" && grep -q guard-c <<<"$TREE" && ok \
  || bad "the union file must carry all three members' lines (got: $(tr '\n' ' ' <<<"$TREE"))"
REG=$(git -C "$T/origin.git" show "$BR:scripts/worker-import-set.json" 2>/dev/null)
for m in a b c; do
  grep -q "src/feature-$m.ts" <<<"$REG" || { bad "the regenerated registry must list src/feature-$m.ts (got $REG)"; break; }
done
grep -q "src/feature-c.ts" <<<"$REG" && ok || true
git -C "$T/origin.git" cat-file -e "$BR:src/shared.ts" 2>/dev/null && \
  [ "$(git -C "$T/origin.git" show "$BR:src/shared.ts")" = 'export const shared = "M2"' ] && ok \
  || bad "the union branch must be cut from current main"

# the fourth PR is left out, and said so
grep -q '104' "$LOG" && ok || bad "the excluded PR must be named in the log"
grep -qE '#104.*(src/shared.ts|source)' "$LOG" && ok \
  || bad "the log must say WHICH file kept #104 out (its source conflict)"
[ -f "$T/train-body.txt" ] && ok || bad "a train PR must be opened with a body"
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" && grep -q '#102' <<<"$B" && grep -q '#103' <<<"$B" && ok \
  || bad "the train body must list every member PR"
grep -q '#104' <<<"$B" && bad "the train body must not list the PR that was left out" || ok
grep -qi 'review' <<<"$B" && ok || bad "the train body must state that every member was reviewed on its own"

# the train is enqueued through the existing queue path, ONCE
[ "$(grep -c . "$T/mqueue.tsv")" = 1 ] && ok || bad "the train must be enqueued exactly once (got $(grep -c . "$T/mqueue.tsv"))"
grep -q '900' "$T/mqueue.tsv" && ok || bad "the queue entry must be the TRAIN's PR number"
# ...and no member PR is ever enqueued or merged by this lane
grep -q 'pr merge' "$T/gh-calls.txt" && bad "batch-resolve must never merge anything itself" || ok

# nothing has landed yet, so nothing is settled yet
[ ! -s "$T/ledger.tsv" ] && ok || bad "no member may be settled before the train has merged"

# ============================================================================
# 4. THE LANDING. A later tick sees the train merged and settles every member.
# ============================================================================
: > "$T/gh-calls.txt"
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0001"}}' > "$T/train-state.json"
run
[ "$(grep -c 'merged_via=batch:batchsha0001' "$T/ledger.tsv")" = 3 ] && ok \
  || bad "all three members need a ledger row carrying merged_via=batch:<sha> (got $(grep -c 'merged_via=batch' "$T/ledger.tsv"))"
[ "$(grep -c '^pr_merged' "$T/ledger.tsv")" = 3 ] && ok \
  || bad "the ledger rows must be pr_merged rows (got: $(cut -f1 "$T/ledger.tsv" | tr '\n' ' '))"
for n in 101 102 103; do
  grep -q "pulls/$n" "$T/gh-calls.txt" || { bad "member #$n must be closed by REST"; break; }
done
grep -q 'pulls/103' "$T/gh-calls.txt" && ok || true
[ "$(grep -c 'issues/10.*comments' "$T/gh-calls.txt")" -ge 3 ] && ok \
  || bad "each member must get a comment naming the train before it is closed"
grep -q 'batchsha0001' "$T/gh-calls.txt" && ok || bad "the member comment must name the train's merge sha"
# BH-784: the close verb is `gh api -i -X PATCH repos/<slug>/issues/<n>` — the
# same claim about the same three issues, through the contract that can tell a
# refusal from an answer.
[ "$(grep -c 'PATCH repos/.*/issues/' "$T/gh-calls.txt")" = 3 ] && ok \
  || bad "each member's issue must be closed (got $(grep -c 'PATCH repos/.*/issues/' "$T/gh-calls.txt"))"

# and it is idempotent: a second tick over a settled train writes nothing new
: > "$T/ledger.tsv"; : > "$T/gh-calls.txt"
run
[ ! -s "$T/ledger.tsv" ] && ok || bad "a settled train must never be settled twice"

# THE GATE STILL BITES ONCE THE TRAINS ARE SETTLED. The state DIRECTORY outlives
# the trains in it, so a gate that tested for the directory would let a switched
# -off project read PRs for ever.
: > "$T/gh-calls.txt"; : > "$LOG"
touch "$H/flags/batch-resolve-off"
run
[ ! -s "$T/gh-calls.txt" ] && ok \
  || bad "with only settled trains on disk the kill flag must stop the lane dead: $(cat "$T/gh-calls.txt")"
grep -q 'nothing to do' "$LOG" && ok \
  || bad "a gate with no train IN FLIGHT must stop at the gate, not walk the settle pass first (got: $(tail -1 "$LOG"))"
rm -f "$H/flags/batch-resolve-off"

# ============================================================================
# 5. RED UNION -> BINARY SPLIT. A+B land; C goes back to the resolver.
# ============================================================================
reset
touch "$T/ci-fails-on-c"
run
[ "$(nbatch)" = 1 ] && ok || bad "the split must leave exactly one landed union branch (got $(nbatch))"
BR=$(batch_branches)
TREE=$(git -C "$T/origin.git" show "$BR:tests/static-guards.txt" 2>/dev/null)
grep -q guard-a <<<"$TREE" && grep -q guard-b <<<"$TREE" && ok \
  || bad "the green half must carry A and B (got: $(tr '\n' ' ' <<<"$TREE"))"
grep -q guard-c <<<"$TREE" && bad "the red member must not be in the landed branch" || ok
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#103' <<<"$B" && bad "the red member must not be listed as a train member" || ok
grep -qE '#103.*(resolver|deferred to the next pass)' "$LOG" && ok \
  || bad "the member left out of the landed half must be named and released, by name"
grep -qxF "103 $HEAD_C" "$H/state/batch-resolve/$PROJ/red.txt" 2>/dev/null \
  && bad "#103's own half was never tested — it must not be marked red on the strength of the four-way union" || ok
grep -qi 'split' "$LOG" && ok || bad "the split must be logged"
rm -f "$T/ci-fails-on-c"

# ============================================================================
# 6. A LONE CANDIDATE WITH NOTHING TO SAVE IS NOT A BATCH
#
#    BH-1269 made BATCH_TRAIN_MIN 1, so "fewer than two" is no longer the reason
#    a lone PR does not ride: a train of one costs exactly the CI run a direct
#    merge costs and keeps the closure. What still holds it back — and what this
#    scenario now pins — is the OTHER refusal, which BH-1269 deliberately left
#    alone: #101 is CLEAN against main and against every sibling, so a train
#    would save nothing that the ordinary one-at-a-time merge does not already
#    do, and building one would only race the conductor for the same merge.
#    The assertion that matters (no branch is pushed) is unchanged; only the
#    sentence the lane logs about it moved.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
  mkpr 104 ticket/tk-14 "$HEAD_D" DIRTY 2026-09-16T04:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 0 ] && ok || bad "one candidate with no conflict is not a train"
grep -qi 'fewer than \|1 candidate\|not one conflict' "$LOG" && ok || bad "and the lane must say so"

# An UNAPPROVED sibling is not a candidate, whatever it conflicts on.
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-16T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
printf 'findings\nTIER: 2\nVERDICT: BLOCK\n' > "$H/builds/$PROJ-TK-13-202609160013/review.md"
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#103' <<<"$B" && bad "a BLOCKed PR must never reach the union branch" || ok
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$H/builds/$PROJ-TK-13-202609160013/review.md"

# An approval bound to a sha that is NOT the head is not an approval.
reset
echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$H/builds/$PROJ-TK-13-202609160013/reviewed-sha"
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#103' <<<"$B" && bad "a PR whose head moved past its approval must not be batched" || ok
echo "$HEAD_C" > "$H/builds/$PROJ-TK-13-202609160013/reviewed-sha"

# ===========================================================================
# THE ADVERSARIAL-REVIEW FINDINGS ON PR #522. Every one of these was a real bug
# a reviewer reproduced against this very fixture; each assertion below failed
# before its fix.
# ===========================================================================

holds() { ls "$H/state/merge-conductor/batch-hold" 2>/dev/null | grep -c . ; }
held()  { [ -s "$H/state/merge-conductor/batch-hold/${SLUG//\//_}_$1" ]; }
trains_open() { grep -l '"status":"open"' "$H/state/batch-resolve/$PROJ"/train-*.json 2>/dev/null | grep -c . ; }
ghcount() { grep -c "$1" "$T/gh-calls.txt" 2>/dev/null || true; }
# (BH-781) A close is now a PATCH plus a VERIFYING RE-READ — two calls on the
# same path — so "was this member closed" counts the PATCH, not every mention of
# the path. gh_rest_close returns 0 only when that re-read says `closed`.
closecount() { grep -c "X PATCH repos/$SLUG/pulls/$1" "$T/gh-calls.txt" 2>/dev/null || true; }
allprs() { { mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
             mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-16T02:00:00Z
             mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-16T03:00:00Z
             mkpr 104 ticket/tk-14 "$HEAD_D" DIRTY 2026-09-16T04:00:00Z; } | jq -sc '.' > "$T/prs.json"; }

# ---------------------------------------------------------------------------
# F0. THE TRAIN IS THE THIRD WAY A PR'S COMMITS REACH MAIN (BH-370.2). The
#     conductor's migration-proof guard lives in pr_worker, and a train never
#     goes through pr_worker: it is a new PR of its own, with no hotfix label,
#     landed by mc_enqueue or the box queue. So a hotfix held in
#     `WAIT_CI hotfix migration proof missing` would ride into main inside a
#     union branch unless THIS lane asks the same question. It asks it here.
# ---------------------------------------------------------------------------
SQL=scripts/migrations/2026-09-16-hotfix.sql
BLOB=4444444444444444444444444444444444444444
# The contract's fingerprint: sha256 of the sorted "<path> <blob sha>" lines.
FP_HF=$(printf '%s\n' "$SQL $BLOB" | sort | sha256sum | awk '{print $1}')
printf '[{"filename":"%s","sha":"%s","status":"added"}]\n' "$SQL" "$BLOB" > "$T/files-101.json"
hf_prs() { # 101 is the hotfix carrying the added SQL; 102 and 103 are plain
  { mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z hotfix
    mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-16T02:00:00Z
    mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-16T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
}
hf_proof() { # hf_proof <fp> <decision> — the marker bin/hotfix-migrate.sh posts
  jq -n --arg b "$(printf '<!-- hotfix-migrate-proof fp=%s decision=%s -->\n\nI ran it.\n' "$1" "$2")" \
    '{comments:[{body:$b}]}' > "$T/comments-101.json"
}

reset
hf_prs
rm -f "$T/comments-101.json"
run
[ "$(nbatch)" = 1 ] && ok || bad "F0: the two plain siblings must still form a train (got $(nbatch) branches)"
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" \
  && bad "F0a: a hotfix with UNPROVEN migration SQL must never be a train member (body: $(tr '\n' ' ' <<<"$B"))" || ok
grep -q '#102' <<<"$B" && grep -q '#103' <<<"$B" && ok \
  || bad "F0b: the plain siblings must not be punished for it (body: $(tr '\n' ' ' <<<"$B"))"
grep -qE '#101.*(proof|hotfix)' "$LOG" && ok \
  || bad "F0c: the log must say WHY #101 was left out (got: $(grep 101 "$LOG" | tr '\n' ' '))"
# ...and the union branch really does not carry its work.
BR=$(batch_branches)
git -C "$T/origin.git" cat-file -e "$BR:src/feature-a.ts" 2>/dev/null \
  && bad "F0d: the unproven hotfix's commits must not be in the landed union tree" || ok

# A HOLD is not an approval either, and neither is a proof for OTHER SQL.
FP_OTHER=$(printf 'somebody elses sql\n' | sha256sum | awk '{print $1}')
reset; hf_prs; hf_proof "$FP_HF" hold
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" \
  && bad "F0e: decision=hold must not put the hotfix on a train (body: $(tr '\n' ' ' <<<"$B"))" || ok
reset; hf_prs; hf_proof "$FP_OTHER" applied
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" \
  && bad "F0e2: a proof for OTHER SQL is not a proof for this head (body: $(tr '\n' ' ' <<<"$B"))" || ok

# THE ACCEPTED PROOF LETS IT RIDE. Nothing else about the lane changes.
reset; hf_prs; hf_proof "$FP_HF" applied
run
B=$(cat "$T/train-body.txt" 2>/dev/null)
grep -q '#101' <<<"$B" && ok \
  || bad "F0f: a hotfix with an accepted proof is an ordinary member (body: $(tr '\n' ' ' <<<"$B"))"

# FAIL CLOSED both ways, and free for every PR that is not a labelled hotfix:
# an unlabelled PR carrying the same SQL costs ZERO extra gh calls.
reset; allprs
run
[ "$(ghcount 'pulls/101/files')" = 0 ] && ok \
  || bad "F0g: a PR without the hotfix label must cost no migration-proof read (calls: $(grep pulls "$T/gh-calls.txt" | tr '\n' ' '))"
rm -f "$T/files-101.json" "$T/comments-101.json"

# ---------------------------------------------------------------------------
# F1. The settle path must be REACHABLE. The conductor spawns this lane off a
#     count of approved PRs it classified — but a held member returns early and
#     is never counted, so once a train carries every approved PR the count is
#     zero, the lane is never spawned, and the landing is never read. The
#     decision is therefore a function, and an OPEN TRAIN is reason enough.
# ---------------------------------------------------------------------------
reset
( . "$H/bin/lib/merge-conductor-lib.sh"; mc_batch_should_spawn "$PROJ" 0 ) 2>/dev/null \
  && bad "no train and nothing batchable must NOT spawn the lane" || ok
( . "$H/bin/lib/merge-conductor-lib.sh"; mc_batch_should_spawn "$PROJ" 2 ) 2>/dev/null \
  && ok || bad "two batchable PRs must spawn the lane"
mkdir -p "$H/state/batch-resolve/$PROJ"
jq -nc '{status:"open",train_url:"https://github.com/x/y/pull/1",members:[]}' \
  > "$H/state/batch-resolve/$PROJ/train-probe.json"
( . "$H/bin/lib/merge-conductor-lib.sh"; mc_batch_should_spawn "$PROJ" 0 ) 2>/dev/null \
  && ok || bad "an OPEN train must spawn the lane whatever the batchable count — otherwise nothing ever reads its landing"
jq -nc '{status:"landed"}' > "$H/state/batch-resolve/$PROJ/train-probe.json"
( . "$H/bin/lib/merge-conductor-lib.sh"; mc_batch_should_spawn "$PROJ" 0 ) 2>/dev/null \
  && bad "a SETTLED train must not keep spawning the lane for ever" || ok
scratch_rm "$H/state/batch-resolve/$PROJ"
# ...and the conductor must actually ask, and must count a held PR as batchable.
grep -q 'mc_batch_should_spawn' "$DIR/bin/merge-conductor.sh" && ok \
  || bad "bin/merge-conductor.sh must decide through mc_batch_should_spawn"
grep -A 12 'mc_batch_held "\$SLUG" "\$NUM" "\$HEAD"' "$DIR/bin/merge-conductor.sh" \
  | grep -q 'batchable' && ok \
  || bad "the held-member early return must still count the PR as batchable"

# ---------------------------------------------------------------------------
# F2. ONE train per pass. A red union that splits into two GREEN halves used to
#     push both: two branches off the same base, each rewriting the same
#     generated registry, so the second is permanently dirty the moment the
#     first lands — and the in-flight guard then blocks the project for ever.
# ---------------------------------------------------------------------------
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" CLEAN 2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" CLEAN 2026-09-16T03:00:00Z
  mkpr 105 ticket/tk-15 "$HEAD_E" CLEAN 2026-09-16T05:00:00Z; } | jq -sc '.' > "$T/prs.json"
touch "$T/ci-fails-on-quad"
run
[ "$(nbatch)" = 1 ] && ok || bad "a red union with two green halves must push exactly ONE branch (got $(nbatch))"
[ "$(ghcount 'pr create')" = 1 ] && ok || bad "exactly one train PR may be opened per pass (got $(ghcount 'pr create'))"
[ "$(trains_open)" = 1 ] && ok || bad "exactly one train may be in flight (got $(trains_open))"
[ "$(holds)" = 2 ] && ok || bad "only the landed half's members may be held (got $(holds))"
held 101 && held 102 && ok || bad "the landed half's members must be held"
held 103 && bad "the deferred half must NOT be held" || ok
held 105 && bad "the deferred half must NOT be held" || ok
grep -qxF "103 $HEAD_C" "$H/state/batch-resolve/$PROJ/red.txt" 2>/dev/null \
  && bad "a GREEN half that merely waited its turn must never be marked red" || ok
grep -qiE '#10[35].*(defer|next pass)' "$LOG" && ok \
  || bad "the deferred half must say it is deferred to the next pass"
rm -f "$T/ci-fails-on-quad"

# ---------------------------------------------------------------------------
# F3. The branch name must be unique WITHOUT a subshell counter, and a refused
#     push must never mark its members red. (`br=$(batch_branch_name)` ran the
#     increment in a subshell, so every branch in a pass had the same name; the
#     second push was refused non-fast-forward and its two GREEN members were
#     excluded until their heads moved, under a log line blaming the push.)
# ---------------------------------------------------------------------------
reset
allprs
run
BR=$(batch_branches)
grep -qE "^batch/$PROJ/[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$" <<<"$BR" && ok \
  || bad "the branch name must carry a per-process component, not a subshell counter (got '$BR')"
grep -q 'BRANCH_SEQ' "$DIR/bin/batch-resolve.sh" \
  && bad "the subshell counter must be gone, not merely worked around" || ok

# ---------------------------------------------------------------------------
# F-ID (BH-1606, #1624 round-2 review). A TRAIN OPENS ONLY AS THE APP. A train
#     PR authored by the lead's PAT reads as a LEAD PR, and every merge lane now
#     fences a lead PR until a lead verdict row stands on its head — so a PAT
#     train would sit held with all its members behind it. When this box cannot
#     mint the repo's App installation token the lane REFUSES to open the train
#     (no push, no PR, members released) and says so loudly — it never falls
#     back to the PAT.
# ---------------------------------------------------------------------------
reset
allprs
rm -f "$H/env/github-app.env"      # the App cannot be minted on this box
run
[ "$(ghcount 'pr create')" = 0 ] && ok \
  || bad "F-ID: THE DEFECT — with no App token the lane must NOT open a train PR (it would be authored by the lead's PAT)"
[ "$(nbatch)" = 0 ] && ok || bad "F-ID: and nothing is pushed (got $(nbatch) batch branch(es))"
[ "$(holds)" = 0 ] && ok || bad "F-ID: the members are released, not held under a train that never opened (got $(holds))"
#     ASKED AT THE TOP OF THE PASS (#1624 round-3 review): a box that cannot
#     mint must not build a union and run the verification contract every pass
#     only to refuse at the end of it.
grep -q 'building a train' "$LOG" \
  && bad "F-ID: THE DEFECT — with no App token the pass must stop BEFORE building the union ($(grep 'building a train' "$LOG" | head -1))" || ok
[ -s "$T/regen-count.txt" ] && bad "F-ID: no regenerate / verification ran on a box that cannot open the train ($(wc -l < "$T/regen-count.txt") run(s))" || ok
grep -qi 'app' "$T/alerts.txt" 2>/dev/null && ok \
  || bad "F-ID: the refusal raises an alert naming the App identity ($(cat "$T/alerts.txt" 2>/dev/null); log $(tail -3 "$LOG"))"
#     …and a gh-token.sh that answers the PAT (its mint-failure fallback) is
#     refused the same way: only an installation token (ghs_) opens a train.
reset
allprs
: > "$H/env/github-app.env"
printf '#!/bin/bash\necho github_pat_fallback\n' > "$H/bin/gh-token.sh"
run
[ "$(ghcount 'pr create')" = 0 ] && ok \
  || bad "F-ID: a PAT handed back by a failed mint must not open a train"
# TEST-CHANGE (BH-1630): the lane now reads the token's expiry (`gh-token.sh
# --expires-at`) before it pushes a union, so the stub answers one, far ahead.
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"
#     control: armed again, the same set opens its train.
reset
allprs
run
[ "$(ghcount 'pr create')" = 1 ] && ok || bad "F-ID: with the App token the train opens as before (got $(ghcount 'pr create'); log $(tail -3 "$LOG"))"
#     …and the refusal alert is RESOLVED when a train opens (not left open for ever).
grep -q -- '--resolve.*batch-train-no-app-token' "$T/alerts.txt" 2>/dev/null && ok \
  || bad "F-ID: a train that opens resolves the no-app-token alert ($(cat "$T/alerts.txt" 2>/dev/null))"
#     THE APP TOKEN IS THE TRAIN PR'S ONLY (round-3 review): it is armed for
#     `gh pr create` and the lane's own identity is back for every gh call after
#     it. On a Mergify repo the train's enqueue (a label POST + a queue comment)
#     follows the create in the same pass — it must not go out on the App token.
reset
allprs
touch "$T/mergify-on"
mv "$T/fakebin/gh" "$T/fakebin/gh.real"
# TEST-CHANGE (BH-6672): the wrapper logs the token's first 4 characters plus
# `*` (`ghs_*`, or `none`), never the value, so no failure message can print it.
printf '#!/bin/bash\nt="${GH_TOKEN:-}"; [ -n "$t" ] && t="${t:0:4}*" || t=none\nprintf "%%s\\t%%s\\n" "$t" "$*" >> "%s/gh-tokens.txt"\nexec "%s/fakebin/gh.real" "$@"\n' "$T" "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"; : > "$T/gh-tokens.txt"
run
grep -q $'^ghs_[^\t]*\tpr create' "$T/gh-tokens.txt" \
  && ok || bad "F-ID: the train PR itself is opened on the App token ($(grep 'pr create' "$T/gh-tokens.txt"))"
AFTER=$(awk -F'\t' 'seen{print} $2 ~ /^pr create/{seen=1}' "$T/gh-tokens.txt")
[ -n "$AFTER" ] && ok || bad "F-ID: the fixture must make a gh call after the create, or nothing below is proven ($(tail -3 "$T/gh-tokens.txt"))"
grep -q '^ghs_' <<<"$AFTER" \
  && bad "F-ID: THE DEFECT — a gh call after the train PR was made on the App token ($(grep '^ghs_' <<<"$AFTER" | head -2))" || ok
mv -f "$T/fakebin/gh.real" "$T/fakebin/gh"
rm -f "$T/mergify-on"


# A REFUSED PUSH, refused by the remote itself. Pre-creating a ref named from
# the TEST shell's pid could never collide with the lane's own branch name, so
# that version of this check passed without exercising anything; the origin's
# update hook refuses the push whatever the branch is called.
reset
allprs
touch "$T/push-block"
run
grep -q 'push was REFUSED' "$LOG" && ok || bad "the fixture must actually refuse the push (nothing else here is exercised)"
[ "$(nbatch)" = 0 ] && ok || bad "a refused push must leave no branch on the remote"
[ "$(ghcount 'pr create')" = 0 ] && ok || bad "and must not open a train PR"
grep -q "101 $HEAD_A" "$H/state/batch-resolve/$PROJ/red.txt" 2>/dev/null \
  && bad "a push refusal must NEVER write red.txt — those members were green" || ok
grep -qE '#101.*deferred to the next pass' "$LOG" && ok \
  || bad "a push refusal must defer its members by name, not mark them red"
[ "$(holds)" = 0 ] && ok || bad "a refused push must leave nothing held"
rm -f "$T/push-block"
reset

# ---------------------------------------------------------------------------
# F4. The settle is idempotent per MEMBER. A kill after the first member used to
#     leave the train `open` with no per-member marker, so the next pass
#     re-commented on already-closed PRs and wrote a second ledger row each.
# ---------------------------------------------------------------------------
reset
allprs
run                                   # builds the train
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0002"}}' > "$T/train-state.json"
: > "$T/gh-calls.txt"; : > "$T/ledger.tsv"
run                                   # settles all three
[ "$(ghcount 'issues/101/comments')" = 1 ] && ok || bad "#101 must settle once in the first pass"
# THE STATE A KILL LEAVES BEHIND, built rather than signalled: the train is
# still open (nothing flipped it) and only the member that finished carries its
# marker. A signal aimed at the gh stub would only kill a command substitution,
# which is a close FAILURE, not a crash — a different case, covered under C.
TF=$(ls "$H/state/batch-resolve/$PROJ"/train-*.json | head -1)
jq -c '.status="open" | del(.merge_sha)' "$TF" > "$TF.t" && mv "$TF.t" "$TF"
grep -xF "101 $HEAD_A" "$H/state/batch-resolve/$PROJ/landed.txt" > "$T/l.t" \
  && mv "$T/l.t" "$H/state/batch-resolve/$PROJ/landed.txt"
# The crash is "the pass died after #101 finished", so GitHub's side rewinds
# with it: #102 and #103 were never commented on and never closed, and they are
# OPEN when the next pass reaches them. Before BH-781's fix round the stub
# answered `closed` to every pull read, so this line had nothing to undo; now
# that settle_member reads the member BEFORE it writes, a stub left saying
# `closed` would model a crash that somehow closed them anyway.
rm -f "$T/pr-state-102.txt" "$T/pr-state-103.txt"
: > "$T/gh-calls.txt"; : > "$T/ledger.tsv"
run                                   # the pass that picks up the pieces
[ "$(ghcount 'issues/101/comments')" = 0 ] && ok \
  || bad "a member settled before the crash must NOT be commented on again"
[ "$(grep -c 'merged_via=batch' "$T/ledger.tsv")" = 2 ] && ok \
  || bad "only the two unsettled members may write a ledger row (got $(grep -c 'merged_via=batch' "$T/ledger.tsv"))"
[ "$(ghcount 'issues/102/comments')" = 1 ] && [ "$(ghcount 'issues/103/comments')" = 1 ] && ok \
  || bad "the remaining members must each settle exactly once"

# ---------------------------------------------------------------------------
# F5. A member whose head MOVED while the train was in flight is not closed.
#     The train landed an older head; closing it would silently discard the
#     commits pushed since.
# ---------------------------------------------------------------------------
reset
allprs
run
echo "cafebabecafebabecafebabecafebabecafebabe" > "$T/head-103.txt"
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0003"}}' > "$T/train-state.json"
: > "$T/gh-calls.txt"; : > "$T/ledger.tsv"
run
[ "$(closecount 103)" = 0 ] && ok \
  || bad "a member whose head moved must NOT be closed (got $(closecount 103) close calls)"
[ "$(closecount 101)" = 1 ] && [ "$(closecount 102)" = 1 ] && ok \
  || bad "the members that did not move must still be closed"
grep -q 'issues/103/comments' "$T/gh-calls.txt" && ok \
  || bad "the moved member must still be told what happened"
grep -qiE '#103.*(older head|head moved|moved)' "$LOG" && ok \
  || bad "the log must say the train landed an older head of #103"
[ "$(ghcount 'PATCH repos/.*/issues/')" = 2 ] && ok \
  || bad "the moved member's issue must stay OPEN (got $(ghcount 'PATCH repos/.*/issues/') closes)"
held 103 && bad "the moved member's hold must be released" || ok

# ---------------------------------------------------------------------------
# F6. A member somebody ELSE merged while the train was in flight — Mergify, a
#     human — with its head unchanged, so F5's arm never sees it. gh_rest_close
#     refuses to call a merged PR closed (`merged` is not the literal `closed`
#     its verifying re-read demands), so it answers 75 for ever: the close-out
#     comment landed AGAIN on that client-visible PR every */5 pass and the
#     train stayed open until the age budget abandoned it. The raw PATCH path
#     this replaced simply landed it. Reading the member BEFORE writing settles
#     it in one pass with zero writes, and the ledger row still goes down —
#     "this PR's commits are in the base branch" is true either way.
# ---------------------------------------------------------------------------
reset
allprs
run
printf 'merged\n' > "$T/pr-state-102.txt"
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0006"}}' > "$T/train-state.json"
: > "$T/gh-calls.txt"; : > "$T/ledger.tsv"
run
[ "$(ghcount 'issues/102/comments')" = 0 ] && ok \
  || bad "an already-merged member must not be commented on (got $(ghcount 'issues/102/comments'))"
[ "$(closecount 102)" = 0 ] && ok \
  || bad "an already-merged member must not be PATCHed closed (got $(closecount 102))"
[ "$(grep -c 'merged_via=batch' "$T/ledger.tsv")" = 3 ] && ok \
  || bad "every member, the already-merged one included, must write its ledger row (got $(grep -c 'merged_via=batch' "$T/ledger.tsv"))"
[ "$(trains_open)" = 0 ] && ok \
  || bad "an already-merged member must not hold the train open"
[ "$(holds)" = 0 ] && ok || bad "and must not leave its hold behind"
: > "$T/gh-calls.txt"
run
[ "$(ghcount 'issues/102/comments')" = 0 ] && ok \
  || bad "a settled member must never be re-commented on a later pass: $(cat "$T/gh-calls.txt")"

# ---------------------------------------------------------------------------
# A. The dedupe lock's fd must not leak into the repo's own commands: a
#    verification contract that leaves a background process would otherwise hold
#    the flock for that process's life and the lane would never run again.
# ---------------------------------------------------------------------------
[ "$(grep -c '9>&-' "$DIR/bin/batch-resolve.sh")" -ge 2 ] && ok \
  || bad "both the regenerate and the verification eval must close fd 9"

# ---------------------------------------------------------------------------
# B. A train that never merges is ABANDONED on an age budget. Without one it
#    holds its members until the 7-day gc and disables the lane for the project.
# ---------------------------------------------------------------------------
reset
allprs
run
TF=$(ls "$H/state/batch-resolve/$PROJ"/train-*.json | head -1)
DEADBR=$(batch_branches)
jq -c '.created_at = 1' "$TF" > "$TF.t" && mv "$TF.t" "$TF"   # pushed in 1970
jq -nc '{state:"OPEN"}' > "$T/train-state.json"
# THE CANDIDATES ARE STILL THERE ON PURPOSE. The abandon used to release the
# holds and then the very same pass rebuilt an identical train from the same
# three PRs: a new train PR and a fresh alert every BATCH_TRAIN_TTL, for ever,
# on a client's repo — for a train that can never merge (a required check the
# queue never satisfies, a paused queue, branch protection the token cannot
# meet). The log line claiming the members went back to the ordinary path was
# simply false.
: > "$T/gh-calls.txt"; : > "$T/alerts.txt"
run
[ "$(trains_open)" = 0 ] && ok || bad "a train past its age budget must not stay in flight"
[ "$(holds)" = 0 ] && ok || bad "an abandoned train must release every member (got $(holds) still held)"
grep -q "pulls/900" "$T/gh-calls.txt" && ok || bad "an abandoned train's PR must be closed"
[ -s "$T/alerts.txt" ] && ok || bad "an abandoned train must alert once"
grep -qi 'age budget\|never merged\|abandon' "$LOG" && ok || bad "and must say why"
[ "$(ghcount 'pr create')" = 0 ] && ok \
  || bad "the abandoning pass must NOT rebuild the same train it just gave up on (got $(ghcount 'pr create') pr create)"
git -C "$T/origin.git" show-ref --verify --quiet "refs/heads/$DEADBR" \
  && bad "the abandoned train's branch $DEADBR must be deleted from the remote, not left behind" || ok
# ...and it stays given up on across passes, until something actually changes.
: > "$T/gh-calls.txt"; : > "$T/alerts.txt"
run
[ "$(ghcount 'pr create')" = 0 ] && ok \
  || bad "the next pass must not rebuild it either — the members are excluded at those heads"
[ ! -s "$T/alerts.txt" ] && ok || bad "and must not alert again about the same stuck set"
grep -qxF "101 $HEAD_A" "$H/state/batch-resolve/$PROJ/abandoned.txt" 2>/dev/null && ok \
  || bad "each member must be excluded by (PR, head), so a push to it makes it eligible again"

# ---------------------------------------------------------------------------
# C. The log must match the code, and D. no gh error body may be swallowed.
# ---------------------------------------------------------------------------
reset
allprs
run
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0004"}}' > "$T/train-state.json"
touch "$T/comment-fails-101"
: > "$T/gh-calls.txt"
run
[ "$(closecount 101)" = 0 ] && ok \
  || bad "a member whose close-out comment FAILED must not be closed — the log says it is left open"
# (BH-781) The library parses the status and discards the vendor sentence, so
# what must reach the log is the STATUS — the actionable half, and the one a
# 403 and a 500 differ on. A refusal that logged nothing is still the defect.
grep -q 'the batch close-out comment could not be posted — HTTP 403' "$LOG" && ok \
  || bad "a refused comment must name its HTTP status in the log, never /dev/null: $(tail -3 "$LOG")"
[ "$(trains_open)" = 1 ] && ok \
  || bad "a train with an unsettled member must stay open so the next pass really does retry it"
rm -f "$T/comment-fails-101"
: > "$T/gh-calls.txt"
run
[ "$(closecount 101)" = 1 ] && ok || bad "and the next pass must finish it"
[ "$(trains_open)" = 0 ] && ok || bad "once every member is settled the train is landed"

# ---------------------------------------------------------------------------
# E. The box merge queue is fed ONLY where it is the lander. On a Mergify repo a
#    queue entry would let bin/merge-queue.sh squash the train past the batch
#    verification the queue exists for.
# ---------------------------------------------------------------------------
reset
allprs
run
[ -e "$H/state/merge-queue/$PROJ/900" ] && ok \
  || bad "with no provider queue the box queue is the lander and must get the entry"
reset
allprs
touch "$T/mergify-on"
run
[ -e "$H/state/merge-queue/$PROJ/900" ] \
  && bad "on a Mergify repo the box queue must NOT be fed — it would bypass the batch verification" || ok
grep -q 'mergify' "$LOG" && ok || bad "the provider enqueue must be logged"
rm -f "$T/mergify-on"
# O4 (BH-3806): BH-3683 withholds the lead-verdict status on the train's head
# (la_decide rc 1). The train is opened, but it gets no merge-queue label and no
# `@mergifyio` ask, and the run says why, naming the human command. The stub
# verdict-status.sh exists for this case only: the lib loads it from the
# scratch harness, and every other case runs without it.
reset
allprs
touch "$T/mergify-on"
cat > "$H/bin/lib/verdict-status.sh" <<EOF
la_decide() { printf '%s\n' "\$*" >> "$T/o4-la.txt"; LA_REASON="touches protected paths: tests/static-guards.txt"; return 1; }
la_human_needed() { return 0; }
vs_publish() { printf '%s\n' "\$*" >> "$T/o4-vs.txt"; return 0; }
vs_context() { echo lead-verdict; }
EOF
: > "$T/o4-la.txt"; : > "$T/o4-vs.txt"
run
[ "$(ghcount 'pr create')" = 1 ] && ok || bad "O4 setup: the train PR is opened ($(tail -3 "$LOG"))"
[ -s "$T/o4-la.txt" ] && ok || bad "O4 setup: the train's enqueue asked la_decide ($(tail -3 "$LOG"))"
[ "$(ghcount 'issues/900/labels')" = 0 ] && ok || bad "O4: no merge-queue label on the train while its verdict is withheld ($(grep labels "$T/gh-calls.txt"))"
[ "$(grep -ci '@mergifyio' "$T/gh-calls.txt")" = 0 ] && ok || bad "O4: no @mergifyio ask on the train ($(grep -i mergifyio "$T/gh-calls.txt"))"
[ ! -s "$T/o4-vs.txt" ] && ok || bad "O4: no status published ($(cat "$T/o4-vs.txt"))"
grep -qF -- "--source human" <<<"$(grep -F "train https://github.com/$SLUG/pull/900 was NOT enqueued" "$LOG")" && ok \
  || bad "O4: the run says the train was not enqueued and names the --source human command ($(grep -F 'pull/900' "$LOG" | tail -3))"
rm -f "$T/mergify-on" "$H/bin/lib/verdict-status.sh" "$T/o4-la.txt" "$T/o4-vs.txt"

# ---------------------------------------------------------------------------
# F. A crash between opening the train PR and recording it must not leave an
#    orphan PR on a client's repo that nothing settles.
# ---------------------------------------------------------------------------
reset
allprs
touch "$T/pr-create-fails"
run
[ "$(trains_open)" = 0 ] && ok || bad "a train PR that was never opened must not count as in flight"
ls "$H/state/batch-resolve/$PROJ"/train-*.json >/dev/null 2>&1 && ok \
  || bad "the branch was pushed, so SOMETHING must record it for the reconcile"
grep -q '"status":"creating"' "$H/state/batch-resolve/$PROJ"/train-*.json 2>/dev/null && ok \
  || bad "the record written before the create must say creating"
ORPHAN=$(batch_branches)
rm -f "$T/pr-create-fails"
# Nothing left to batch, so the reconciling pass cannot immediately build a new
# train and re-hold its members — the assertions below are about the orphan.
mkpr 104 ticket/tk-14 "$HEAD_D" DIRTY 2026-09-16T04:00:00Z | jq -sc '.' > "$T/prs.json"
: > "$T/gh-calls.txt"
run
[ "$(holds)" = 0 ] && ok || bad "the reconcile must release the members of a train that never opened"
grep -qi 'reconcil\|never opened\|orphan' "$LOG" && ok || bad "and must say what it did"
# ...and THAT branch is really gone from the remote (the pass goes on to build a
# fresh train, so the count is not the test — the orphan's own ref is). The
# settle runs before the checkout is set up, so a reconcile that does not ask
# for one pushes from the wrong directory and logs "could not be deleted" for
# ever, leaving the branch behind.
git -C "$T/origin.git" show-ref --verify --quiet "refs/heads/$ORPHAN" \
  && bad "the orphan branch $ORPHAN must be DELETED from the remote, not merely logged about" || ok

# ---------------------------------------------------------------------------
# AND THE EXCLUSION EXPIRES WHEN THE HEAD MOVES. An abandoned train must not
# exclude its members for ever — only the heads that were in it.
# ---------------------------------------------------------------------------
reset
allprs
run                                            # a train
TF=$(ls "$H/state/batch-resolve/$PROJ"/train-*.json | head -1)
jq -c '.created_at = 1' "$TF" > "$TF.t" && mv "$TF.t" "$TF"
jq -nc '{state:"OPEN"}' > "$T/train-state.json"
: > "$T/gh-calls.txt"
run                                            # abandoned; members excluded
[ "$(ghcount 'pr create')" = 0 ] && ok || bad "the abandoned set must not rebuild"
# #102 and #103 each get a new commit and a new approved head. The exclusion is
# per (PR, head), so only those two come back — #101 has not changed and stays
# out of the batch lane (it merges the ordinary way, which is where the abandon
# released it to), and two is what a train needs.
newhead() {  # newhead <branch> <marker-file> <record>
  git -C "$S" checkout -q "$1"
  printf 'export const more = 2\n' >> "$S/$2"
  git -C "$S" add -A && git -C "$S" commit -qm more >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD > "$T/nh"
  git -C "$S" checkout -q main
  cat "$T/nh" > "$H/builds/$PROJ-$3/reviewed-sha"
  cat "$T/nh"
}
HEAD_B2=$(newhead ticket/tk-12 src/feature-b.ts TK-12-202609160012)
HEAD_C2=$(newhead ticket/tk-13 src/feature-c.ts TK-13-202609160013)
{ mkpr 101 ticket/tk-11 "$HEAD_A" CLEAN 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B2" CLEAN 2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C2" CLEAN 2026-09-16T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
rm -f "$H/state/batch-resolve/$PROJ"/train-*.json   # the settled record is done with
: > "$T/gh-calls.txt"
run
[ "$(ghcount 'pr create')" = 1 ] && ok \
  || bad "members whose heads MOVED must be batchable again — the exclusion is keyed on the head, not the PR"
grep -qxF "101 $HEAD_A" "$H/state/batch-resolve/$PROJ/abandoned.txt" 2>/dev/null && ok \
  || bad "and the member that did NOT move must stay excluded at its head"

echo "batch-resolve-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
