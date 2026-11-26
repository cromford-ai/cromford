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
# NO `review` WITHOUT A LIVE PROBE (BH-9987). `review` asks the client to check
# the work in production, and at PR open nothing is merged or deployed. So with
# the gate on (bin/lib/review-probe.sh rp_required, row
# lib.review-probe.review_probe_require, default 1) an in-app PR_CREATED moves
# the ticket to `in_progress`. bin/merged-ticket-advance.sh moves it to `review`
# after the merge, once its main screen answers in production. Gate off, or no
# lib on the box: `review` at PR open, as before (the stderr line says why).
#
# A SLICE BUILD IS NEVER `done` (BH-8333). A board build whose plan says
# `SLICE: C<k> of #<this ticket>` shipped one slice of a split plan. On
# PR_MERGED this files the remaining slices as child tickets FIRST
# (bin/lib/slice-board.sh), then posts one comment that names them and says
# what is not live yet, then moves the master to `in_progress`.
# bin/decompose-parent-close.sh closes it when every child is done. A filer
# that cannot answer now (deferred) exits 1 with nothing posted, so the sweep
# carries it. On PR_CREATED the status is the one any PR open gets (below) and
# the comment says the rest is filed at merge.
# BH-10080: a weak slice marker (slice_board_marker: `SLICE: C0` with no
# `of #`, a SLICE-REASON line) is a slice too. The comment states what the
# filing step returned: `filed:` names the children, `exists:` names the
# children the master already has, and `unknown:` or any other answer says the
# rest is NOT filed and names who files it by hand (knob SLICE_BOARD_FILE_OWNER).
# After the post it writes <build>/slice-board/noted, so the conductor's park-1
# settle posts no second note.
#
# HONEST CLAIMS. The comment says what was actually verified: the adversarial
# review and the repo's own suite are named as build-proof, and the browser QA
# pass is claimed ONLY when qa.md really ends in QA: PASS. Nothing here has
# driven a UI by hand, so nothing here says it has.
#
# KILL FLAG: BUILDER_DIRECT=0 / flags/builder-direct-off -> exit 3 without
# posting anything (bin/lib/builder-direct.sh owns the flag).
#
# PRODUCTION RED (BH-8859): a PR_MERGED close-out says "merged" and moves the
# ticket to done, so while the project's production deploy is red
# (bin/lib/prod-red-defer.sh) it exits 4 before any request. The RESULT stays
# unmarked, and the sweep posts it after the next green deploy.
#
# exit 0 posted · 3 switched off · 4 not a close-out this lane words, or a
# merged close-out that waits for a green deploy · 1 could not post (the caller
# leaves the relay path to carry it, exactly as today).
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
# shellcheck source=bin/lib/prod-red-defer.sh
[ -r "$BIN/lib/prod-red-defer.sh" ] && . "$BIN/lib/prod-red-defer.sh"
# shellcheck source=bin/lib/release-model.sh
[ -r "$BIN/lib/release-model.sh" ] && . "$BIN/lib/release-model.sh"
# shellcheck source=bin/lib/review-probe.sh
[ -r "$BIN/lib/review-probe.sh" ] && . "$BIN/lib/review-probe.sh"
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
# >>> release model (BH-9862)
# A project whose merges deploy to STAGING (catalog/release-model.tsv). Two
# things change for it and nothing else. At PR open the comment is posted and
# the ticket goes to `in_progress`, never `review` (BH-9870): nothing is on any
# site yet, and a board that audits `review` against merged code moved every
# such ticket back with a comment the client saw. At merge the comment says
# "on staging", links staging, and the ticket stays `in_progress`, never
# `review` or `done` (BH-9876): on that board both mean live in production,
# production moves only with a release a person runs, and the app's own audit
# moves the ticket when that release is live. The production-red
# defer below is skipped too: a red production release says nothing about
# whether staging has the merge.
STAGING_BASE=""
command -v release_staging_base >/dev/null 2>&1 && STAGING_BASE=$(release_staging_base "$PROJECT")
# <<< release model
if [ "$TO_STATUS" = done ] && [ -z "$STAGING_BASE" ] && command -v prod_red_defers_dir >/dev/null 2>&1 \
   && prod_red_defers_dir "$HARNESS" "$PROJECT" "$BUILD"; then
  IFS=$'\t' read -r PRD_SINCE PRD_SHA _ <<<"$(prod_red_defer_state "$HARNESS" "$PROJECT")"
  say "production red since ${PRD_SINCE:-?} (commit ${PRD_SHA:-?}): the merged close-out waits for a green deploy — left for the sweep"
  exit 4
fi
PR_URL=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' <<<"$RLINE" | head -1)
[ -n "$PR_URL" ] || { say "no PR url on the RESULT line"; exit 4; }

PROD=$("$BIN/fleet-conf.sh" "$PROJECT" prod 2>/dev/null) || PROD=""
# BH-9862: where the links point. The board API stays on $PROD.
SEE_BASE="$PROD"; [ -n "$STAGING_BASE" ] && SEE_BASE="$STAGING_BASE"
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
  # Line 1 is the status marker bin/lib/plan-thread.sh skips (BH-8804).
  BODY=$(printf '<!-- harness-status: board-closeout -->\n%s\n\n%s\n\nPR: %s\n\n%s\n' \
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
# --- a SLICE build (BH-8333) ---------------------------------------------------
# The helper beside this script first, $HARNESS/bin/lib second. Without it, or
# with no SLICE line for THIS ticket, the path below is today's, unchanged.
SLICE_TOKEN=""; SLICE_K=""; SLICE_HTML=""; SLICE_NOTE=""
_SBL="$(cd "$(dirname "$0")" && pwd)/lib/slice-board.sh"; [ -r "$_SBL" ] || _SBL="$BIN/lib/slice-board.sh"
# shellcheck source=bin/lib/slice-board.sh
if [ -r "$_SBL" ] && . "$_SBL" 2>/dev/null && command -v slice_board_token >/dev/null 2>&1; then
  if SLICE_TOKEN=$(slice_board_token "$BUILD/plan.md" "$TICKET" "$KEY" 2>/dev/null); then
    SLICE_K=$(slice_board_line "$BUILD/plan.md" | cut -f1)
  else
    SLICE_TOKEN=""
    # A weak slice marker (BH-10080): TK-618's plan had no SLICE line, and the
    # ticket went to `done` with its rest never filed.
    if command -v slice_board_marker >/dev/null 2>&1 \
       && SLICE_K=$(slice_board_marker "$BUILD/plan.md" "" "$TICKET" "$KEY" 2>/dev/null); then
      SLICE_TOKEN="$TICKET"
    fi
  fi
fi
# Who files a remainder by hand: the knob SLICE_BOARD_FILE_OWNER (BH-10080).
SLICE_OWNER=""
[ -n "$SLICE_TOKEN" ] && command -v slice_board_owner >/dev/null 2>&1 && SLICE_OWNER=$(slice_board_owner 2>/dev/null)
SLICE_OWNER="${SLICE_OWNER:-the operator}"
SLICE_NOTED=0
if [ -n "$SLICE_TOKEN" ]; then
  if [ "$TO_STATUS" = done ]; then
    TO_STATUS=in_progress
    # Park 0: the filer files and records, and this script owns the one comment.
    SW=$(slice_board_settle "$PROJECT" "$KEY" "$PR_URL" "$BUILD" "$TICKET" 0 "$HARNESS" 2>/dev/null) || true
    say "slice C$SLICE_K: $SW"
    case "$SW" in
      filed:*)
        LI=""
        while IFS= read -r CK; do
          [ -n "$CK" ] || continue
          # children.txt line n is spec row n (fc_file_board writes it in order).
          N_=$(grep -nxF "$CK" "$BUILD/slice-board/children.txt" | head -1 | cut -d: -f1)
          CT=$(jq -r --argjson i "$(( ${N_:-1} - 1 ))" '.[$i].title // ""' "$BUILD/slice-board/children.json" 2>/dev/null)
          LI="$LI<li>$(esc "$CK"): $(esc "$CT")</li>"
        done < <(tr ',' '\n' <<<"${SW#filed:}")
        SLICE_HTML="<p>Not live yet: the rest of the plan. We filed each remaining slice as its own ticket:</p><ul>$LI</ul><p>This ticket stays in progress until they all land.</p>"
        SLICE_NOTE=" (slice C$SLICE_K; children ${SW#filed:})" ;;
      exists:*)
        # The parent already has children (BH-10080): nothing was filed now.
        SLICE_HTML="<p>Not live yet: the rest of the plan. The remaining work already has its own tickets: $(esc "${SW#exists:}").</p><p>This ticket stays in progress until they land.</p>"
        SLICE_NOTE=" (slice C$SLICE_K; already has children ${SW#exists:})" ;;
      unknown:*)
        SLICE_HTML="<p>Not live yet: the rest of the plan. The remaining slices are not filed yet: we could not read them from the plan, and we flagged it so a person files them. $(esc "$SLICE_OWNER") files them by hand.</p><p>This ticket stays in progress until they land.</p>"
        SLICE_NOTE=" (slice C$SLICE_K; remaining slices not filed: ${SW#unknown:})" ;;
      deferred:*)
        say "slice C$SLICE_K: the remaining slices are not filed yet ($SW) — nothing posted, left for the sweep"
        exit 1 ;;
      *)
        SLICE_HTML="<p>Not live yet: the rest of the plan. The remaining slices are not filed yet. $(esc "$SLICE_OWNER") files them by hand.</p><p>This ticket stays in progress until they land.</p>"
        SLICE_NOTE=" (slice C$SLICE_K; remaining slices not filed: ${SW:-no answer})" ;;
    esac
    SLICE_NOTED=1
  else
    SLICE_HTML="<p>This PR is slice C$SLICE_K of the plan. When it merges, we file the remaining slices as their own tickets, and this ticket stays open until they land. A comment here names each new ticket once it exists. If we cannot file them, we say so here.</p>"
    SLICE_NOTE=" (slice C$SLICE_K)"
  fi
fi

# >>> review probe (BH-9987): an in-app PR open goes to in_progress, not review.
RP_HOLD=0
if [ "$TO_STATUS" = review ] && [ -z "$STAGING_BASE" ]; then
  if ! command -v rp_required >/dev/null 2>&1; then
    say "bin/lib/review-probe.sh missing: the ticket goes to review at PR open, as before"
  elif [ "$(rp_required "$PROJECT")" = 1 ]; then
    RP_HOLD=1
  fi
fi
# <<< review probe
LINKS_HTML=""
SEE_LEAD="Where to see it:"
[ "$RP_HOLD" = 1 ] && SEE_LEAD="Where to see it after this merges:"
if [ -n "$STAGING_BASE" ]; then
  SEE_LEAD="Where to see it on staging:"
  [ "$TO_STATUS" = review ] && SEE_LEAD="Where to see it on staging after this merges:"
fi
if [ -n "$ROUTES" ]; then
  LINKS_HTML="<p>$SEE_LEAD</p><ul>"
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    LINKS_HTML="$LINKS_HTML<li><a href=\"$(esc "$SEE_BASE$R")\">$(esc "$SEE_BASE$R")</a></li>"
  done <<<"$ROUTES"
  LINKS_HTML="$LINKS_HTML</ul>"
else
  LINKS_HTML="<p>$SEE_LEAD <a href=\"$(esc "$SEE_BASE")\">$(esc "$SEE_BASE")</a></p>"
fi
case "$TO_STATUS" in
  done) LEAD="This is merged and on its way to production." ;;
  *)    LEAD="This is built and open for review." ;;
esac
[ "$TO_STATUS" = in_progress ] && LEAD="Slice C$SLICE_K of this ticket is merged and on its way to production."
# >>> release model (BH-9862): the words and the destination for a staging project.
if [ -n "$STAGING_BASE" ]; then
  NOT_LIVE="It is not live on production yet. It goes live with the next release."
  case "$TO_STATUS" in
    done)        LEAD="This is merged and on its way to staging. $NOT_LIVE"; TO_STATUS=in_progress ;;
    in_progress) LEAD="Slice C$SLICE_K of this ticket is merged and on its way to staging. $NOT_LIVE" ;;
    # PR open (BH-9870): in_progress, never review. The merge lane
    # (bin/merged-ticket-advance.sh) takes a ticket only in in_progress or
    # review, and nothing else moves a ticket out of todo, so a ticket left
    # in todo here got no merge comment and no move (TK-787, 2026-11-21).
    # Not review: the app audit moves a review ticket with an open PR back.
    *)           TO_STATUS=in_progress ;;
  esac
fi
# <<< release model
if [ "$RP_HOLD" = 1 ]; then
  TO_STATUS=in_progress
  LEAD="This is built and the PR is open. It moves to review after it merges and its main screen answers in production."
fi
BODY_HTML="<p>$(esc "$LEAD")</p>${WHAT_HTML}${SLICE_HTML}${LINKS_HTML}<p>Code: <a href=\"$(esc "$PR_URL")\">$(esc "$PR_URL")</a></p><p>$(esc "$VERIFIED")</p>"

RESP=$(CURL -X POST -d "$(jq -nc --arg b "$BODY_HTML" '{body:$b}')" \
  "$PROD$PREFIX/tickets/$TICKET/comments" 2>/dev/null)
# A board that answers with anything other than a comment object has NOT taken
# the comment, and saying so is the whole point: the caller then leaves the
# RESULT unmarked and the relay path carries the close-out exactly as today.
printf '%s' "$RESP" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1 \
  || { say "comment POST refused: $(printf '%.200s' "$RESP")"; exit 1; }
# This comment states what the filing step returned, so the conductor's park-1
# settle on the same ledger posts no second note (BH-10080).
[ "$SLICE_NOTED" = 1 ] && [ -d "$BUILD/slice-board" ] && touch "$BUILD/slice-board/noted" 2>/dev/null

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
echo "POSTED $PROJECT/$KEY -> $TO_STATUS$SLICE_NOTE"
