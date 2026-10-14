#!/bin/bash
# bin/board-closeout.sh <project> <ticket-id> <key> <build-dir>
#
# THE WHAT-SHIPPED COMMENT, POSTED BY THE MACHINE THAT BUILT IT (W2-B, the operator
# 2026-09-14: "4000 builder boxes submitting PRs all day; every throughput
# ceiling is a bug").
#
# Until now the close-out was the last hop of a funnel that ran through the hub:
# the builder's RESULT was relayed to the hub, the hub pushed it to the owning
# box, the box's next triage tick staged it, and a paid session then read the
# RESULT and wrote the comment. The comment is the part a CLIENT sees, so every
# clock in that chain is a client waiting. A builder already holds the project
# env, the board token and the finished record — the only thing it was missing
# was permission to say so.
#
# WHAT THIS IS NOT. It does not replace the triage session's judgement. It words
# exactly ONE shape: a build that ended with a PR (PR_CREATED / PR_MERGED). Every
# other RESULT — a deferral, a PLAN_BLOCKED, a refusal — exits 4 untouched and
# travels the path it travels today, because those need a sentence about WHY and
# that is not a sentence a shell script should be writing to a client.
#
# STATUS FOLLOWS THE BOARD CONTRACT, not a preference (docs/BOARD-API-CONTRACT.md,
# "The ticket model"): built work goes to `review`, and `done` MEANS MERGED — a
# `done` ticket with an open PR is an invariant alert in bin/board-invariants.sh.
# So PR_CREATED -> review, PR_MERGED -> done, and nothing else moves a status.
#
# HONEST CLAIMS. The comment says what was actually verified: the adversarial
# review and the repo's own suite are named as build-proof, and the browser QA
# pass is claimed ONLY when qa.md really ends in QA: PASS. Nothing here has
# driven a UI by hand, so nothing here says it has.
#
# KILL FLAG: BUILDER_DIRECT=0 / flags/builder-direct-off -> exit 3 without
# posting anything (bin/lib/builder-direct.sh owns the flag).
#
# exit 0 posted · 3 switched off · 4 not a close-out this lane words · 1 could
# not post (the caller leaves the relay path to carry it, exactly as today).
#
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?project}"; TICKET="${2:?ticket-id}"; KEY="${3:?ticket-key}"; BUILD="${4:?build-dir}"
HARNESS="${HARNESS:-/root/harness}"
BIN="$HARNESS/bin"
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [closeout/$PROJECT/$KEY] $*" >&2; }

command -v jq >/dev/null 2>&1 || { say "jq required"; exit 1; }
# shellcheck source=bin/lib/builder-direct.sh
[ -r "$BIN/lib/builder-direct.sh" ] && . "$BIN/lib/builder-direct.sh"
command -v builder_direct_on >/dev/null 2>&1 || { say "bin/lib/builder-direct.sh missing"; exit 3; }
[ "$(builder_direct_on "$HARNESS")" = 1 ] || { say "builder-direct is off"; exit 3; }
[ -s "$BUILD/RESULT" ] || { say "no RESULT in $BUILD"; exit 4; }

RLINE=$(head -1 "$BUILD/RESULT")
# Already carries the marker: this build has been closed out once. Posting again
# would put a second comment on a client's ticket, which is the one failure this
# whole path must not have.
bd_closed_out "$RLINE" && { say "already closed out"; exit 4; }
case "$RLINE" in
  PR_CREATED\ http*) TO_STATUS=review ;;
  PR_MERGED\ http*)  TO_STATUS=done ;;
  *) say "not a PR close-out ($(printf '%.40s' "$RLINE")) — left for the sweep"; exit 4 ;;
esac
PR_URL=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' <<<"$RLINE" | head -1)
[ -n "$PR_URL" ] || { say "no PR url on the RESULT line"; exit 4; }

PROD=$("$BIN/fleet-conf.sh" "$PROJECT" prod 2>/dev/null) || PROD=""
PREFIX=$("$BIN/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || PREFIX=""

# --- what shipped -------------------------------------------------------------
# The commit subjects this build added, written by the caller next to the rest of
# the record. Absent (an older record, a resumed dir) degrades to the PR link
# alone rather than inventing a summary.
WHAT=$(grep -v '^[[:space:]]*$' "$BUILD/what.txt" 2>/dev/null | head -8)
# The routes the plan itself named for the QA pass. These are the DIRECT LINKS
# the standing rule asks for and they are the only ones this lane can honestly
# produce: they come from the plan's own '## QA screens' section, not from a
# guess about where a feature lives.
ROUTES=$(awk '/^##[[:space:]]*QA screens/{f=1;next} f&&/^##[[:space:]]/{exit} f' "$BUILD/plan.md" 2>/dev/null \
  | grep -oE '(^|[^A-Za-z0-9._~:/?#@!$&()*+,;=-])/[A-Za-z0-9][A-Za-z0-9._~/-]*' \
  | sed -E 's#^[^/]*##' | grep -vE '^/(root|tmp|usr|var|etc|home)(/|$)' | sort -u | head -4)
QA_OK=""
tail -1 "$BUILD/qa.md" 2>/dev/null | grep -q 'QA: PASS' && QA_OK=1

esc() { printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

VERIFIED="The repo's own build and test suite ran green in this build, and an adversarial review read the diff before the PR opened."
[ -n "$QA_OK" ] && VERIFIED="$VERIFIED A browser pass drove the preview at desktop and phone widths and passed."
[ -n "$QA_OK" ] || VERIFIED="$VERIFIED Nobody drove the live app by hand, so treat this as build-proof until you click it."

# --- client-court guard -----------------------------------------------------
# A finished build must not close-out a ticket that is still waiting on the
# client, not ready, or whose newest comment is from the harness/system. The
# gate is fail-open OK, so a broken fetch never blocks a legitimate close-out.
GB=$("$BIN/triage-gate.sh" "$PROJECT" --buildable "$TICKET" 2>/dev/null) || GB="OK"
case "$GB" in
  BLOCKED*) say "client-court, not posting ($GB)"; exit 4 ;;
esac

# --- the GitHub-Issues lane ---------------------------------------------------
# fleet.conf column 4 is "-": the ticket IS a GitHub issue, so the close-out is
# an issue comment. No status move — the PR body's "Closes #n" and
# bin/run-build.sh's CLOSE_ISSUE_AFTER_MERGE already own that transition, and a
# second actor closing issues is how two lanes come to disagree about state.
if [ "$PREFIX" = "-" ]; then
  REPO=$("$BIN/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || REPO=""
  ISSUE=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  [ -n "$REPO" ] && [ -n "$ISSUE" ] && command -v gh >/dev/null 2>&1 || { say "no repo/issue/gh for the issues lane"; exit 1; }
  # The freshest token this machine has been handed (2026-09-14, TK-680/681/682).
  # A close-out is the LAST thing a build does, an hour or more after its env
  # bundle was written, and a builder's installation token dies in an hour — so
  # the one client-visible step of the whole pipeline was the one most likely to
  # 401. No file (a watcher, an unarmed box) means the environment is untouched.
  # shellcheck source=bin/lib/gh-token-live.sh
  [ -r "$BIN/lib/gh-token-live.sh" ] && . "$BIN/lib/gh-token-live.sh"
  command -v gh_token_live >/dev/null 2>&1 && gh_token_live "${REPO:-}"
  # gh_token_live exports GH_TOKEN, which is exactly the ambient credential the
  # REST contract reads and the identity gh_rest_alert labels `explicit`.
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$BIN/lib/gh-rest.sh" ] && . "$BIN/lib/gh-rest.sh"
  BODY=$(printf '%s\n\n%s\n\nPR: %s\n\n%s\n' \
    "Built and opened for review." "${WHAT:-- see the PR for the change list}" "$PR_URL" "$VERIFIED")
  # The body goes by FILE (BH-781): a client-facing comment is the longest
  # argument this lane ever builds and argv is a process list.
  BF=$(mktemp "${TMPDIR:-/tmp}/closeout-body.XXXXXX") || { say "no temp file for the comment body"; exit 1; }
  printf '%s\n' "$BODY" > "$BF"
  gh_rest_comment "$REPO" "$ISSUE" "$BF" || { rm -f "$BF"; say "the issue comment could not be posted — HTTP ${GH_REST_STATUS:-000}"; exit 1; }
  rm -f "$BF"
  echo "POSTED $REPO#$ISSUE"
  exit 0
fi

# --- the in-app product board -------------------------------------------------
[ -n "$PROD" ] && [ "$PROD" != "-" ] && [ -n "$PREFIX" ] || { say "no prod origin / board prefix in fleet.conf"; exit 1; }
TOKEN=$("$BIN/internal-token-for.sh" "$PROJECT" 2>/dev/null) || TOKEN=""
[ -n "$TOKEN" ] || { say "no internal board token for $PROJECT"; exit 1; }
CURL() { curl -s --max-time 25 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
                -H "User-Agent: curl/8" "$@"; }

WHAT_HTML=""
if [ -n "$WHAT" ]; then
  WHAT_HTML="<ul>"
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    WHAT_HTML="$WHAT_HTML<li>$(esc "${L#- }")</li>"
  done <<<"$WHAT"
  WHAT_HTML="$WHAT_HTML</ul>"
fi
LINKS_HTML=""
if [ -n "$ROUTES" ]; then
  LINKS_HTML="<p>Where to see it:</p><ul>"
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    LINKS_HTML="$LINKS_HTML<li><a href=\"$(esc "$PROD$R")\">$(esc "$PROD$R")</a></li>"
  done <<<"$ROUTES"
  LINKS_HTML="$LINKS_HTML</ul>"
else
  LINKS_HTML="<p>Where to see it: <a href=\"$(esc "$PROD")\">$(esc "$PROD")</a></p>"
fi
case "$TO_STATUS" in
  done) LEAD="This is merged and on its way to production." ;;
  *)    LEAD="This is built and open for review." ;;
esac
BODY_HTML="<p>$(esc "$LEAD")</p>${WHAT_HTML}${LINKS_HTML}<p>Code: <a href=\"$(esc "$PR_URL")\">$(esc "$PR_URL")</a></p><p>$(esc "$VERIFIED")</p>"

RESP=$(CURL -X POST -d "$(jq -nc --arg b "$BODY_HTML" '{body:$b}')" \
  "$PROD$PREFIX/tickets/$TICKET/comments" 2>/dev/null)
# A board that answers with anything other than a comment object has NOT taken
# the comment, and saying so is the whole point: the caller then leaves the
# RESULT unmarked and the relay path carries the close-out exactly as today.
printf '%s' "$RESP" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1 \
  || { say "comment POST refused: $(printf '%.200s' "$RESP")"; exit 1; }

# THE COMMENT FIRST, THE STATUS SECOND, and never the other way round. A ticket
# moved to `review` with no comment is a client seeing work change state with no
# explanation; a comment with no move is one status the next tick fixes.
MOVED=$(CURL -X POST -d "$(jq -nc --arg s "$TO_STATUS" '{toStatus:$s,sortOrder:999999}')" \
  "$PROD$PREFIX/tickets/$TICKET/move" 2>/dev/null)
if ! grep -q "$TO_STATUS" <<<"$MOVED"; then
  say "commented, but the move to $TO_STATUS was refused: $(printf '%.160s' "$MOVED")"
  echo "POSTED $PROJECT/$KEY (status not moved)"
  exit 0
fi
echo "POSTED $PROJECT/$KEY -> $TO_STATUS"
