#!/bin/bash
# tests/deploy-rollback-board.bh-4915-test.sh — a deploy-train revert reopens
# the ticket it rolled back (BH-4915).
#
# WHAT IS UNDER TEST. The real bin/deploy-train.sh, run against a scratch
# $HARNESS, fails its verify, opens a rollback PR, and through
# "$HARNESS/bin/deploy-rollback-board.sh" (installed with its whole bin/lib
# closure) moves each reverted merge's ticket out of done:
#   1  board project: ONE comment naming the revert PR, the merge PR and the
#      reason, THEN one move to in_progress; a `deploy_rollback` ledger row
#      `reopened`; the local marker. The token never reaches a log or a body.
#   2  the same batch fails again (it stays queued): the train opens no second
#      rollback PR (BH-7506) and nothing new is posted, whether the ledger row
#      (2b) or only the local marker (2c) says so.
#   3  GitHub-Issues project: one issue comment, then PATCH state=open.
#   4  VERIFIED departure: no tracker call, no deploy_rollback row, no marker.
#   5  DEPLOY_ROLLBACK=off, and a revert that cannot be prepared: no call.
#   6  a member with no job.json: a `flagged` row, no tracker call.
#   7  the board refuses the comment: no marker, `comment-failed`, an ALERTS
#      line; the next failing departure with the board healthy posts once.
#   8  the board answers the move without the status: `commented-unmoved`.
#   9  rows mode (deploy_queue rows): the build dir comes from the row.
# Run from anywhere: bash tests/deploy-rollback-board.bh-4915-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=2 TRAIN_POLL_SECS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls"
# A two-commit repo with real content (a revert of an empty commit fails).
git init -q "$T/repo" && (cd "$T/repo" && echo one > f && git add f && git commit -q -m one \
  && echo two > f && git commit -q -am two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin HEAD:main \
  && git fetch -q origin)
TARGET=$(git -C "$T/repo" rev-parse HEAD); OLD=$(git -C "$T/repo" rev-parse HEAD~1)
export DEPLOY_TRAIN_REPO_DIR="$T/repo"

# ── stubs (written BEFORE the closure install, which never clobbers them) ────
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in repo) echo "org/repo" ;; board_prefix) cat "$HARNESS/prefix" ;; *) exit 1 ;; esac
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$HARNESS/calls/beat"
SH
cat > "$T/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do shift; done
echo "ALERT $1" >> "$HARNESS/logs/ALERTS.log"
SH
printf '#!/bin/bash\nexit 0\n' > "$T/bin/merge-queue.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
# curl: the version endpoint, the deploy hook, and the board's comment/move routes.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
url=""; data=""; prev=""
for a in "$@"; do
  [ "$prev" = --data-binary ] && data="${a#@}"
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */tickets/*/comments)
    if [ -f "$HARNESS/board-down" ]; then echo "comment-refused" >> "$HARNESS/calls/order"; exit 22; fi
    echo "comment" >> "$HARNESS/calls/order"
    { echo "URL $url"; cat "$data"; echo; } >> "$HARNESS/calls/board-comment"
    echo '{"comment":{"id":1}}' ;;
  */tickets/*/move)
    echo "move" >> "$HARNESS/calls/order"
    { echo "URL $url"; cat "$data"; } >> "$HARNESS/calls/board-move"
    s=$(jq -r .toStatus "$data"); [ -f "$HARNESS/board-nomove" ] && s=done
    printf '{"ticket":{"id":7,"status":"%s"}}' "$s" ;;
  */version) printf '{"sha":"%s"}' "$(cat "$HARNESS/live")" ;;
  *) echo hook >> "$HARNESS/calls/hook" ;;
esac
SH
# gh: `pr create` opens the revert PR and replays it in the open-PR list the
# rollback gate reads (BH-7506); `api -i` is gh_rest (list, issue comment, PATCH).
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
if [ "${1:-} ${2:-}" = "pr create" ]; then
  n=$(( $(cat "$HARNESS/prnum" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$HARNESS/prnum"
  head=""; bf=""; prev=""
  for a in "$@"; do [ "$prev" = -H ] && head="$a"; [ "$prev" = --body-file ] && bf="$a"; prev="$a"; done
  [ -n "$bf" ] && [ "$bf" != - ] && jq -nc --argjson n "$n" --arg h "$head" --rawfile b "$bf" \
    --arg c "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{number:$n, html_url:("https://github.com/org/repo/pull/"+($n|tostring)), head:{ref:$h}, body:$b, created_at:$c}' \
    >> "$HARNESS/open-prs.jsonl"
  echo "https://github.com/org/repo/pull/$n"; exit 0
fi
if [ "${1:-} ${2:-}" = "api -i" ]; then
  m="$4"; p="$5"; bf=""
  for a in "$@"; do case "$a" in body=@*) bf="${a#body=@}" ;; esac; done
  case "$m $p" in
    "GET repos/org/repo/pulls")
      printf 'HTTP/2 200\r\n\r\n'
      if [ -s "$HARNESS/open-prs.jsonl" ]; then jq -sc . "$HARNESS/open-prs.jsonl"; else echo '[]'; fi ;;
    "POST repos/org/repo/issues/"*/comments)
      echo "ghcomment" >> "$HARNESS/calls/order"; { echo "PATH $p"; cat "$bf"; echo; } >> "$HARNESS/calls/gh-comment"
      printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
    "PATCH repos/org/repo/issues/"*)
      echo "ghmove $p $*" >> "$HARNESS/calls/order"
      printf 'HTTP/2 200\r\n\r\n{"state":"open"}\n' ;;
    *) printf 'HTTP/2 404\r\n\r\n{}\n' ;;
  esac
fi
exit 0
SH
# The coordination client: a ledger that answers what was put, and the
# deploy_queue rows verbs (on only when $HARNESS/rows-on exists).
cat > "$T/bin/jobs-client.sh" <<'SH'
setting_get() { return 1; }
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "$HARNESS/calls/ledger"; }
job_ledger_get() {
  local s
  [ -f "$HARNESS/worker-down" ] && return 1
  s=$(awk -F'\t' -v k="${1:-}" -v key="${2:-}" '$1==k && $2==key {s=$3} END{print s}' "$HARNESS/calls/ledger" 2>/dev/null)
  [ -n "$s" ] || return 2
  printf '%s' "$s"
}
job_ledger_row() {
  local r
  [ -f "$HARNESS/worker-down" ] && return 1
  r=$(awk -F'\t' -v k="${1:-}" -v key="${2:-}" '$1==k && $2==key {r=$3"\t"$4} END{print r}' "$HARNESS/calls/ledger" 2>/dev/null)
  [ -n "$r" ] || return 2
  jq -nc --arg s "${r%%	*}" --arg d "${r#*	}" '{status:$s, detail:$d}'
}
deploy_queue_rows_on() { [ -f "$HARNESS/rows-on" ]; }
deploy_queue_put() { return 0; }
deploy_queue_list() {
  case "${2:-}" in queued) cat "$HARNESS/rows" ;; *) : ;; esac
}
deploy_queue_claim() { return 0; }
deploy_queue_depart() { echo "depart $*" >> "$HARNESS/calls/depart"; return 0; }
SH
cp "$DIR/bin/internal-token-for.sh" "$T/bin/"
scratch_install_closure bin/deploy-rollback-board.sh "$T" >/dev/null \
  || echo "note: bin/deploy-rollback-board.sh closure not installed"
scratch_install_closure bin/lib/deploy-rollback-guard.sh "$T" >/dev/null \
  || echo "note: bin/lib/deploy-rollback-guard.sh closure not installed"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"

TOKEN=sekret-token-4915
write_env() { # write_env <on|off>
  printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=%s\nP_APP_BASE=https://app.example.test\nP_INTERNAL_API_TOKEN=%s\n' \
    "$1" "$TOKEN" > "$T/env/p.env"
}
mkbuild() { # mkbuild <dir> <ticket_id> <KEY> <merge pr n>
  mkdir -p "$T/builds/$1"
  jq -nc --arg t "$2" --arg k "$3" '{project:"p",ticket_id:$t,key:$k}' > "$T/builds/$1/job.json"
  echo "PR_MERGED https://github.com/org/repo/pull/$4" > "$T/builds/$1/RESULT"
}
mkbuild p-TK-7-x 7 TK-7 459
mkbuild p-TK-8-x 8 TK-8 460
mkdir -p "$T/builds/mq-x"   # a merge-queue member: no job.json
enqueue() { # enqueue <sha> <build dir>
  printf '%s %s\n' "$1" "$2" > "$T/state/deploy-queue/p/$(( $(date +%s) - 1800 ))-${1:0:8}"
}
drop_rollback_branches() { # a re-departure in the same minute pushes the same branch name
  git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/heads/rollback | while read -r r; do
    git -C "$T/origin.git" update-ref -d "$r"; done
}
reset() {
  rm -rf "$T/calls" "$T/state/deploy-rollback" "$T/worker-down" "$T/board-down" "$T/board-nomove" "$T/rows-on" "$T/rows" "$T/prnum" "$T/open-prs.jsonl"
  rm -f "$T/state/deploy-queue/p/"* "$T/logs/"*
  mkdir -p "$T/calls"; drop_rollback_branches
  echo /api/board > "$T/prefix"; write_env on
}
run() { "$DIR/bin/deploy-train.sh" p >/dev/null 2>&1; }
cnt() { if [ -f "$1" ]; then grep -c "${2:-.}" "$1"; else echo 0; fi; }
rbrows() { awk -F'\t' '$1=="deploy_rollback"' "$T/calls/ledger" 2>/dev/null; }
S8=${TARGET:0:8}
MARK="$T/state/deploy-rollback/p/TK-7-${TARGET:0:12}"

# 1. board project, production stuck on OLD, rollback on.
reset; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
grep -q "rollback PR https://github.com/org/repo/pull/901 enqueued" "$T/logs/deploy-train.log" 2>/dev/null \
  && ok || bad "case1 precondition: the train must open the rollback PR ($(tail -3 "$T/logs/deploy-train.log" 2>/dev/null))"
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case1: exactly one board comment (order: $(cat "$T/calls/order" 2>/dev/null))"
grep -q "^URL https://app.example.test/api/board/tickets/7/comments$" "$T/calls/board-comment" 2>/dev/null \
  && ok || bad "case1: the comment goes to ticket 7 on the project's board base"
grep -q "https://github.com/org/repo/pull/901" "$T/calls/board-comment" 2>/dev/null && ok || bad "case1: comment names the revert PR"
grep -q "https://github.com/org/repo/pull/459" "$T/calls/board-comment" 2>/dev/null && ok || bad "case1: comment names the merge PR"
grep -q "production still not serving $S8" "$T/calls/board-comment" 2>/dev/null && ok || bad "case1: comment carries the train's reason"
[ "$(cnt "$T/calls/order" '^move$')" = 1 ] && ok || bad "case1: exactly one move"
grep -q '"toStatus":"in_progress"' "$T/calls/board-move" 2>/dev/null && ok || bad "case1: the move is to in_progress ($(cat "$T/calls/board-move" 2>/dev/null))"
[ "$(paste -sd, "$T/calls/order" 2>/dev/null)" = "comment,move" ] && ok || bad "case1: comment BEFORE move (got $(paste -sd, "$T/calls/order" 2>/dev/null))"
R=$(rbrows)
[ "$(printf '%s' "$R" | grep -c .)" = 1 ] && ok || bad "case1: one deploy_rollback ledger row (got: $R)"
[ "$(cut -f2 <<<"$R")" = "p TK-7@$S8" ] && [ "$(cut -f3 <<<"$R")" = reopened ] && ok || bad "case1: row key/status (got: $R)"
D=$(cut -f4 <<<"$R")
jq -e --arg s "$TARGET" '.key=="TK-7" and .ticket_id=="7" and .sha==$s and .merge_pr=="https://github.com/org/repo/pull/459"
  and .revert_pr=="https://github.com/org/repo/pull/901" and (.reason|test("not serving"))' >/dev/null 2>&1 <<<"$D" \
  && ok || bad "case1: row detail (got: $D)"
[ -f "$MARK" ] && ok || bad "case1: marker $MARK written"
grep -rqF "$TOKEN" "$T/logs" "$T/calls/board-comment" 2>/dev/null && bad "case1: the token leaked into a log or a body" || ok

# 2. the same batch is still queued and fails again: no second PR, nothing new.
[ -n "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "case2 precondition: the batch stays queued after a rollback"
drop_rollback_branches
run
grep -q "rollback skipped (dup)" "$T/logs/deploy-train.log" 2>/dev/null \
  && ok || bad "case2: the second departure on the same target is a dup ($(tail -1 "$T/logs/deploy-train.log" 2>/dev/null))"
[ "$(cnt "$T/calls/gh" '^pr create')" = 1 ] && ok || bad "case2: the second departure opens no second rollback PR"
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case2: a re-run posts no second comment"
[ "$(cnt "$T/calls/order" '^move$')" = 1 ] && ok || bad "case2: a re-run makes no second move"
[ "$(rbrows | grep -c .)" = 1 ] && ok || bad "case2: no second ledger put ($(rbrows))"

# 2c. the worker is down: the local marker alone stops it.
touch "$T/worker-down"; drop_rollback_branches
run
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case2c: with the ledger unreadable the marker stops the comment"
rm -f "$T/worker-down"

# 2b. the ledger alone (another box's marker, not ours) also stops it.
rm -rf "$T/state/deploy-rollback"; drop_rollback_branches
run
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case2b: a ledger row from elsewhere stops the comment"

# 3. GitHub-Issues project.
reset; echo - > "$T/prefix"; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
[ "$(cnt "$T/calls/order" '^ghcomment$')" = 1 ] && ok || bad "case3: one issue comment (order: $(cat "$T/calls/order" 2>/dev/null))"
grep -q "^PATH repos/org/repo/issues/7/comments$" "$T/calls/gh-comment" 2>/dev/null && ok || bad "case3: comment on issue 7"
grep -q "https://github.com/org/repo/pull/901" "$T/calls/gh-comment" 2>/dev/null && ok || bad "case3: comment names the revert PR"
grep -q "^ghmove repos/org/repo/issues/7 .*state=open" "$T/calls/order" 2>/dev/null && ok || bad "case3: PATCH state=open"
[ "$(cut -d' ' -f1 "$T/calls/order" 2>/dev/null | paste -sd,)" = "ghcomment,ghmove" ] && ok || bad "case3: comment before reopen"
[ "$(rbrows | cut -f3)" = reopened ] && ok || bad "case3: row reopened ($(rbrows))"
[ "$(cnt "$T/calls/order" '^comment$')" = 0 ] && ok || bad "case3: no board call on a GitHub-Issues project"

# 4. VERIFIED: nothing.
reset; printf '%s' "$TARGET" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
grep -q "train VERIFIED live" "$T/logs/deploy-train.log" 2>/dev/null && ok || bad "case4 precondition: verified"
[ ! -s "$T/calls/order" ] && ok || bad "case4: no tracker call on a verified departure"
[ -z "$(rbrows)" ] && ok || bad "case4: no deploy_rollback row"
[ ! -e "$T/state/deploy-rollback" ] && ok || bad "case4: no marker dir"

# 5a. DEPLOY_ROLLBACK=off: alert only, no board change.
reset; write_env off; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
grep -q "DEPLOY_ROLLBACK=off" "$T/logs/deploy-train.log" 2>/dev/null && ok || bad "case5a precondition: alert-only branch"
[ ! -s "$T/calls/order" ] && [ -z "$(rbrows)" ] && ok || bad "case5a: no tracker call, no row"
# 5b. a sha that is not on main: the rollback gate cannot read its commit time,
# so no revert is prepared (BH-7506; before the gate this was "rollback prep failed").
reset; printf '%s' "$OLD" > "$T/live"; enqueue "$(printf 'd%.0s' {1..40})" "$T/builds/p-TK-7-x"
run
grep -q "rollback skipped (unknown): commit time of dddddddd unreadable" "$T/logs/deploy-train.log" 2>/dev/null \
  && ok || bad "case5b precondition: no revert for an unreadable sha ($(tail -1 "$T/logs/deploy-train.log" 2>/dev/null))"
[ ! -s "$T/calls/order" ] && [ -z "$(rbrows)" ] && ok || bad "case5b: no tracker call, no row"

# 6. a member with no job.json: flagged, never a tracker call.
reset; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/mq-x"
run
[ ! -s "$T/calls/order" ] && ok || bad "case6: no tracker call for an unmapped member"
R=$(rbrows)
[ "$(cut -f2 <<<"$R")" = "p $S8" ] && [ "$(cut -f3 <<<"$R")" = flagged ] && ok || bad "case6: flagged row keyed p <sha8> (got: $R)"
drop_rollback_branches; run
[ "$(rbrows | grep -c .)" = 1 ] && ok || bad "case6: the flag is written once ($(rbrows))"

# 7. the board refuses the comment; the next departure with a healthy board posts once.
reset; touch "$T/board-down"; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
[ ! -e "$MARK" ] && ok || bad "case7: no marker after a refused comment"
[ "$(cnt "$T/calls/order" '^move$')" = 0 ] && ok || bad "case7: no move after a refused comment"
[ "$(rbrows | cut -f3)" = comment-failed ] && ok || bad "case7: row comment-failed ($(rbrows))"
grep -q "TK-7" "$T/logs/ALERTS.log" 2>/dev/null && grep -q "pull/901" "$T/logs/ALERTS.log" && ok || bad "case7: one ALERTS line naming the ticket and revert PR"
rm -f "$T/board-down"; drop_rollback_branches; run
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case7: the retry posts exactly one comment"
[ "$(rbrows | tail -1 | cut -f3)" = reopened ] && ok || bad "case7: the retry ends reopened ($(rbrows))"
drop_rollback_branches; run
[ "$(cnt "$T/calls/order" '^comment$')" = 1 ] && ok || bad "case7: and then nothing more"

# 8. the board answers the move without the status.
reset; touch "$T/board-nomove"; printf '%s' "$OLD" > "$T/live"; enqueue "$TARGET" "$T/builds/p-TK-7-x"
run
[ "$(rbrows | cut -f3)" = commented-unmoved ] && ok || bad "case8: a refused move is commented-unmoved ($(rbrows))"
[ -e "$MARK" ] && ok || bad "case8: the delivered comment still writes the marker"

# 9. rows mode: the build dir comes from the deploy_queue row.
reset; touch "$T/rows-on"; printf '%s' "$OLD" > "$T/live"
printf '1\t%s\tp\t%s\tqueued\t%s\n' "$TARGET" "$T/builds/p-TK-8-x" "$(date -u -d '-30 min' '+%Y-%m-%dT%H:%M:%SZ')" > "$T/rows"
run
grep -q "^URL https://app.example.test/api/board/tickets/8/comments$" "$T/calls/board-comment" 2>/dev/null \
  && ok || bad "case9: rows mode comments on the row's ticket ($(cat "$T/calls/order" 2>/dev/null))"
grep -q "https://github.com/org/repo/pull/460" "$T/calls/board-comment" 2>/dev/null && ok || bad "case9: rows mode merge PR"
[ "$(rbrows | cut -f2,3)" = "p TK-8@$S8	reopened" ] && ok || bad "case9: rows mode row ($(rbrows))"

# 10. the script alone: missing args is rc 2, and a failure never leaks out.
"$DIR/bin/deploy-rollback-board.sh" p >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "case10: missing args rc 2 (got $RC)"

echo "deploy-rollback-board.bh-4915: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
