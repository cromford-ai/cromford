#!/bin/bash
# bin/merged-ticket-advance.sh <project> [--cooled] [--dry-run]
#
# MERGED TICKETS ADVANCE ON IN-APP BOARDS (BH-3927, part 5 of BH-3921). A build
# opens a PR, the PR merges, bin/postmerge-qa.sh audits the deploy, and the
# ticket sat in `in_progress` or `review` until somebody moved it by hand. On a
# split, that also kept the parent open, because bin/decompose-parent-close.sh
# only closes a parent whose children are all `done`.
#
# So: on an in-app board, find the `in_progress`/`review` tickets whose NEWEST
# build on this box opened a PR that passed the deploy audit, post one comment
# that says so, then move the ticket:
#   * filed by `system` (the harness itself)     -> done
#   * filed by anyone else, now in `in_progress` -> review (the client checks it)
#   * filed by anyone else, already in `review`  -> left alone, counted
# A missing reporter is a client, never a guess at `system` (D11).
#
# WHAT COUNTS AS AUDITED. The LAST line of state/postmerge-qa-done.txt whose
# basename field is exactly the newest build dir's name, verdict PASS or
# NOT_COVERED_NO_QA_ENV. The `postmerge_qa` ledger row is the fallback when the
# file has no line; it carries the verdict only, so a ledger-only advance names
# no commit and uses the build dir's stamp as its dedupe token. Anything else
# (FAIL, NOT_COVERED_DEPLOY_TIMEOUT, no line, a line for an older build of the
# same key) is not merged-and-serving, and the ticket stays put.
#
# WHAT HOLDS IT. A newer build dir for the key whose own RESULT is not a PR
# (`newer-build`), and a client comment on the thread after the audit stamp
# (`client-spoke`: the client said something the move would talk over). The
# harness's own comments are not the client: author userId `system`, author
# name the board's self actor (bin/lib/prebuild-repro/thread.sh's table, else
# `${BOARD_SELF_ACTORS:-System} Harness`, as bin/triage-gate.sh reads it), or a
# body carrying this lane's own sentence `This is merged and` together with
# this audit's witness (`commit <sha8>`, else the PR URL); a client quoting the
# sentence is still the client. Without that,
# the lane's own comment held a comment-only ticket forever and its move was
# never retried.
#
# FAIRNESS. A held ticket costs a GET and counts against MERGED_ADVANCE_MAX,
# and it can stay held for days. So a capped run records the next candidate's
# id in state/merged-advance-<p>.next and the next run starts there, wrapping
# round: tickets held at the head of the list never starve the rest.
#
# THE RUNG. PASS says the post-merge check passed in production.
# NOT_COVERED_NO_QA_ENV says production is serving it and nobody has clicked
# through it yet. Neither says live or shipped.
#
# GATES, in order, each before any request: board prefix empty or `-`; kill
# switch flags/merged-advance-off; MERGED_ADVANCE_MAX 0; --cooled inside
# MERGED_ADVANCE_COOLDOWN_S; no board env or token. Every one of those exits 0
# with no log line.
#
# WRITES. Comment, then the marker (ledger row + state file, comment-mark.sh),
# then the move. A comment that did not land means no marker and no move. The
# move counts only when its 2xx echo carries the target status; otherwise it is
# `comment-only` and the next run, finding the marker or its own sentence on the
# thread, retries the move alone, up to MERGED_ADVANCE_MOVE_TRIES runs; then it
# gives up on that ticket with one MERGED_ADVANCE_GAVE_UP line and one alert
# (`move-gave-up`). An echoed move writes a MOVED marker (ledger row + state
# file `<…>.moved`). A ticket that carries it and is open again was moved back
# by a person: that wins, it is held as `moved-back` and never moved again
# (lead review lr-4034-93265e68e589). Both POSTs carry an Idempotency-Key bound
# to (project, ticket, sha8). It prints the KEY of each ticket it moved.
#
# PEER-BUILT TICKETS (BH-8786). A ticket with no build dir on this box (a peer
# fleet built it) takes the peer path instead of being dropped. Destination
# first (system -> done, client in_progress -> review, client review -> left
# alone), then one GET of the ticket (it counts against MERGED_ADVANCE_MAX).
#   build fact  the newest thread comment with a PR URL on the project repo
#               (fleet.conf slug, case-insensitive). None: `no-pr-in-thread`.
#               Two PR numbers in that comment: `pr-ambiguous`.
#   merge fact  GitHub REST pulls/<n> through bin/lib/gh-rest.sh, with the
#               credential bin/lib/gh-repo-token.sh picks. merged_at null:
#               `pr-open`. A failed read or no 40-hex merge sha: `peer-unread`.
#               A repo no credential can see: one alert a day, `peer-unread`.
#   deploy fact the prod version route (VERSION_URL, else <prod>/api/internal/
#               version, with VERSION_AUTH or the board bearer), read once a
#               run. Its sha is the merge, or GitHub compare says `ahead` or
#               `identical`: deployed. `behind`/`diverged`: `deploy-behind`. A
#               404 means no version route: deployed once
#               MERGED_ADVANCE_DEPLOY_GRACE_S passed after merged_at (else
#               `deploy-behind`), and the comment says "merged, deploy not
#               confirmed from here". Any other answer: `peer-unread`.
# The dedupe token is `pr-<n>-<merge sha8>`, the client-spoke cutoff is
# merged_at, and the holds, markers and retries are the ones above. Every
# candidate on this path counts `no-local-build` as well as its outcome.
#
# SLICE PLANS (BH-9865). bin/board-closeout.sh (BH-8333) keeps a slice ticket
# in `in_progress`, and bin/decompose-parent-close.sh closes the master when
# every child is done. So a ticket whose plan carries a SLICE line for THIS
# ticket (slice_board_token, bin/lib/slice-board.sh, rc 0) is held: no comment,
# no move, no turn, counted `slice-plan`. Local path: the newest build dir's
# plan.md, read after the audit check and before the ticket GET. Peer path: the
# merged PR's body from the pulls/<n> read the lane already makes; the version
# route is not read for it. A SLICE line for another ticket does not hold. With
# no lib on the box (mid-sync) nothing is held, as before.
# BH-10080: a weak slice marker (slice_board_marker: `SLICE: C0` with no
# `of #`, a SLICE-REASON line, a `<KEY>: C0` PR title on the peer path) holds
# too. A held slice whose ledger (<build>/slice-board/, or
# state/slice-board/<project>-<KEY>-pr<n>/ on the peer path) has no terminal
# file (filed, exists, unknown-paged) spawns bin/slice-board-settle.sh
# --ticket <id> --park 1, detached, output to logs/slice-board.log: one
# MERGED_ADVANCE_SLICE_SETTLE <KEY> <pr> line each, counted `slice-settle`.
# MERGED_ADVANCE_MAX bounds it, and --dry-run spawns nothing.
#
# A LIVE PROBE BEFORE `review` (BH-9987). A client-filed move to `review`
# whose audit is not PASS (NOT_COVERED_NO_QA_ENV, or a peer build) first makes
# ONE unauthenticated GET of the ticket's primary screen in production
# (bin/lib/review-probe.sh): <prod-url.sh> + the first static route of the
# plan's `## QA screens`, else `/` (always `/` on the peer path). `served` or
# `signin` adds one paragraph with the probed URL to the comment and the move
# goes on. Anything else is a hold: no comment, no marker, no move, no .tries
# bump, one MERGED_ADVANCE_PROBE_HOLD line, counted `no-live-probe`, and one
# alert per ticket and audit token (cm_put: a `commented` ledger row, then state/<…>.probe-alerted). The next run
# probes again. PASS (a signed-in QA drive), a move to `done`, a staging hold
# and a move retry (our comment is already there) make no probe. Row
# lib.review-probe.review_probe_require at 0 turns it off; no lib on the box
# (mid-sync) makes no probe, as before.
#
# THE TURN. After an echoed move to `review` (either path) the lane gives the
# turn to the client: POST /tickets/<id>/turn {"to":"client"}. A move does not
# change the turn. A failed turn is one MERGED_ADVANCE_TURN_FAILED line; the
# move still counts.
#
# One log line per run that read the board:
#   MERGED_ADVANCE moved=N comment-only=N skipped: no-audit=N audit-fail=N newer-build=N client-spoke=N client-review=N moved-back=N move-gave-up=N no-local-build=N no-pr-in-thread=N pr-open=N deploy-behind=N peer-unread=N pr-ambiguous=N no-live-probe=N slice-plan=N slice-settle=N
# plus MERGED_ADVANCE_CAPPED when MERGED_ADVANCE_MAX stopped the loop early.
#
# Called from inapp_released_lines (bin/lib/rt/scope.sh) right before the
# in-app parent close, so a split's last child reaching `done` closes its
# parent in the same tick. No model call. GitHub reads on the peer path, and
# for a staging project (BH-9876) on the local path too: the PR's merge commit
# and one compare with what production serves. REST only:
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?usage: merged-ticket-advance.sh <project> [--cooled] [--dry-run]}"
shift
COOLED=0; DRY=0
for a in "$@"; do
  case "$a" in
    --cooled)  COOLED=1 ;;
    --dry-run) DRY=1 ;;
    *) ;;
  esac
done
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
SELF="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
MA_LOG() { # MA_LOG <line> -> one line in this project's own log, never a secret
  mkdir -p "$HARNESS/logs" 2>/dev/null || true
  echo "$(STAMP) [$PROJECT] $1" >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null || true
}

# --- gates: none of these makes a request ------------------------------------
BP=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || BP=""
[ -n "$BP" ] && [ "$BP" != "-" ] || exit 0
# The kill switch is read through lane_switch, so a settings row
# switch.merged-advance-off[.<box>] settles it before the file does.
# shellcheck source=bin/lib/lane-switch.sh
. "$SELF/lib/lane-switch.sh" 2>/dev/null || true
# The builds/ archive index (BH-7437): _ma_builds lists archived dirs too.
# shellcheck source=bin/lib/build-archive.sh
. "$SELF/lib/build-archive.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # no lib: the file, as before
lane_switch merged-advance-off file && exit 0

# The settings rows win over the env (catalog/lanes.d/_lib.merged-advance.json).
# shellcheck source=bin/lib/lane-gate.sh
[ -r "$SELF/lib/lane-gate.sh" ] && . "$SELF/lib/lane-gate.sh" 2>/dev/null
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply merged-advance "$PROJECT" 2>/dev/null
MAX="${MERGED_ADVANCE_MAX:-10}"
case "$MAX" in ''|*[!0-9]*) MAX=10 ;; esac
# A move that keeps failing is tried this many times (one per run), then the
# lane gives up on that ticket with one alert (lead review lr-4034-93265e68e589).
TRIES="${MERGED_ADVANCE_MOVE_TRIES:-3}"
case "$TRIES" in ''|*[!0-9]*|0) TRIES=3 ;; esac
# How long after merged_at a peer-built ticket waits when prod has no version
# route (BH-8786). knob lib.merged-advance MERGED_ADVANCE_DEPLOY_GRACE_S; 1800 is its fallback.
GRACE="${MERGED_ADVANCE_DEPLOY_GRACE_S:-1800}"
case "$GRACE" in ''|*[!0-9]*) GRACE=1800 ;; esac
[ "$MAX" -gt 0 ] || exit 0

# Same pacing as the parent close: the in-app tick calls this every time, and a
# hand run (no --cooled) is never held.
MARK="$HARNESS/state/merged-advance-$PROJECT.last"
COOL="${MERGED_ADVANCE_COOLDOWN_S:-600}"
case "$COOL" in ''|*[!0-9]*) COOL=600 ;; esac
if [ "$COOLED" = 1 ] && [ "$COOL" -gt 0 ]; then
  LAST=0
  [ -r "$MARK" ] && LAST=$(tr -dc '0-9' < "$MARK" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  [ $(( $(date +%s) - LAST )) -ge "$COOL" ] || exit 0
  mkdir -p "$HARNESS/state" 2>/dev/null || true
  date +%s > "$MARK" 2>/dev/null || true
fi

command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
[ -r "$HENV/$PROJECT.env" ] || exit 0
# Same discovery as the parent close: the SUFFIX is the contract.
set -a; # shellcheck disable=SC1090
. "$HENV/$PROJECT.env" 2>/dev/null; set +a
# >>> release model (BH-9862): for a project whose merges deploy to staging,
# the deploy fact is read from staging and the comment says "on staging".
# shellcheck source=bin/lib/release-model.sh
. "$SELF/lib/release-model.sh" 2>/dev/null || true
command -v release_model_apply >/dev/null 2>&1 && release_model_apply "$PROJECT"
STG_BASE=""; command -v release_staging_base >/dev/null 2>&1 && STG_BASE=$(release_staging_base "$PROJECT")
# <<< release model
BVAR=$(grep -oE '^[A-Z_]+_(API|APP)_BASE' "$HENV/$PROJECT.env" 2>/dev/null | head -1)
BASE=""; [ -n "$BVAR" ] && BASE="${!BVAR:-}"
MA_TOKEN=$("$SELF/internal-token-for.sh" "$PROJECT" 2>/dev/null) || MA_TOKEN=""
[ -n "$BASE" ] && [ -n "$MA_TOKEN" ] || exit 0
API="$BASE$BP"
# The board's self actor, read the way bin/triage-gate.sh does.
# shellcheck source=bin/lib/prebuild-repro/thread.sh
[ -r "$SELF/lib/prebuild-repro/thread.sh" ] && . "$SELF/lib/prebuild-repro/thread.sh" 2>/dev/null
SELF_NAME=""
declare -F _prt_self_actor >/dev/null 2>&1 && SELF_NAME=$(_prt_self_actor "$PROJECT")
[ -n "$SELF_NAME" ] || SELF_NAME="${BOARD_SELF_ACTORS:-System} Harness"

# shellcheck source=/dev/null
[ -r "$SELF/jobs-client.sh" ] && . "$SELF/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$SELF/lib/ledger-twin.sh" ] && . "$SELF/lib/ledger-twin.sh" 2>/dev/null
# shellcheck source=bin/lib/comment-mark.sh
[ -r "$SELF/lib/comment-mark.sh" ] && . "$SELF/lib/comment-mark.sh" 2>/dev/null
# A box mid-sync: no ledger means "no row", no marker lib means the file alone.
declare -F lt_read >/dev/null 2>&1 || lt_read() { LT_VAL=""; return 1; }
declare -F cm_has >/dev/null 2>&1 || cm_has() { [ -e "$3" ]; }
declare -F cm_put >/dev/null 2>&1 || cm_put() { mkdir -p "$(dirname "$3")" 2>/dev/null; : > "$3"; }
# The peer path's GitHub seam (BH-8786): REST reads and the credential ladder.
# Sourcing makes no request.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$SELF/lib/gh-rest.sh" ] && . "$SELF/lib/gh-rest.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$SELF/lib/gh-repo-token.sh" ] && . "$SELF/lib/gh-repo-token.sh" 2>/dev/null
# The slice test board-closeout uses (BH-9865). No lib: no hold, as before.
# shellcheck source=bin/lib/slice-board.sh
[ -r "$SELF/lib/slice-board.sh" ] && . "$SELF/lib/slice-board.sh" 2>/dev/null
declare -F slice_board_token >/dev/null 2>&1 || slice_board_token() { return 1; }
declare -F slice_board_marker >/dev/null 2>&1 || slice_board_marker() { return 1; }
# The live probe before `review` (BH-9987). Its knobs are applied HERE, in this
# shell, so REVIEW_PROBE_TIMEOUT_S reaches rp_probe. No lib: no probe.
# shellcheck source=bin/lib/review-probe.sh
[ -r "$SELF/lib/review-probe.sh" ] && . "$SELF/lib/review-probe.sh" 2>/dev/null
RP_ON=0
if command -v rp_required >/dev/null 2>&1; then
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply review-probe "$PROJECT" 2>/dev/null
  RP_ON=$(rp_required "$PROJECT")
fi
SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || SLUG=""
PROD=$("$SELF/prod-url.sh" "$PROJECT" 2>/dev/null) || PROD=""

# </dev/null because the candidate loop reads a file on stdin.
_ma_get() { # _ma_get <url> <outfile> -> the HTTP code
  local c
  c=$(curl -s -m 20 -o "$2" -w '%{http_code}' \
        -H "Authorization: Bearer $MA_TOKEN" -H "User-Agent: curl/8" \
        "$1" </dev/null 2>/dev/null) || c=""
  printf '%s' "${c:-000}"
}
_ma_post() { # _ma_post <url> <bodyfile> <idempotency-key> <outfile> -> HTTP code
  local c
  c=$(curl -s -m 30 -o "$4" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $MA_TOKEN" -H "Content-Type: application/json" \
        -H "Idempotency-Key: $3" -H "User-Agent: curl/8" \
        --data-binary @"$2" "$1" </dev/null 2>/dev/null) || c=""
  printf '%s' "${c:-000}"
}
_ma_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# _ma_newest <key> -> "<12-digit stamp>\t<dir>" of every build dir for the key,
# newest first. Only names whose remainder after `<KEY>-` is 12 digits, so CX-1
# never collects CX-12's dirs; ordered by that stamp, never by mtime.
_ma_builds() {
  local key="$1" d bn rest
  { for d in "$HARNESS/builds/$PROJECT-$key"-*/ "$HARNESS/builds/pool-$PROJECT-$key"-*/; do
      printf '%s\n' "$d"
    done
    # Dirs bin/builds-retention.sh moved to builds-archive/ (BH-7437).
    command -v ba_dirs >/dev/null 2>&1 && ba_dirs "$HARNESS" "$PROJECT" "$key" 2>/dev/null
  } | while IFS= read -r d; do
    [ -d "$d" ] || continue
    bn=$(basename "$d")
    case "$bn" in fly-*) continue ;; esac
    rest="${bn#*"$PROJECT-$key-"}"
    case "$rest" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) ;; *) continue ;; esac
    printf '%s\t%s\n' "${rest:0:12}" "${d%/}"
  done | sort -r -k1,1
}
# _ma_pr <dir> -> field two of a PR RESULT line, or nothing
_ma_pr() {
  local first
  first=$(head -1 "$1/RESULT" 2>/dev/null)
  case "$first" in
    "PR_CREATED http"*|"PR_MERGED http"*) set -- $first; printf '%s' "$2" ;;
  esac
}

_ma_turn() { # _ma_turn <id> <key> <token>: give the turn to the client after a move to review
  local c
  printf '{"to":"client"}' > "$TMP/turn.json"
  c=$(_ma_post "$API/tickets/$1/turn" "$TMP/turn.json" "advance-$PROJECT-$1-$3-turn" "$TMP/turn-resp.json")
  case "$c" in 2??) ;; *) MA_LOG "MERGED_ADVANCE_TURN_FAILED $2 HTTP $c" ;; esac
}

# --- the peer path (BH-8786) ---------------------------------------------------
# _ma_peer_pr <ticket json> -> the distinct PR numbers (space separated) of the
# newest comment that names a PR on $SLUG; nothing when none does. An
# unparseable createdAt sorts as the oldest; equal times keep thread order.
_ma_peer_pr() {
  jq -r --arg slug "$SLUG" '
    ("https://github\\.com/" + ($slug | gsub("\\."; "\\.")) + "/pull/([0-9]+)") as $re
    | [ (.comments? // .ticket.comments? // .data.comments? // [])[]
        | select(type == "object")
        | ((.createdAt // "") | tostring | sub("\\.[0-9]+Z$"; "Z")) as $t
        | { e: ((try ($t | fromdateiso8601) catch null) // -1),
            n: ([ (.body // "" | tostring) | match($re; "gi") | .captures[0].string | tonumber ] | unique) }
        | select(.n | length > 0) ]
    | sort_by(.e) | last | (.n // []) | map(tostring) | join(" ")' "$1" 2>/dev/null
}
# _ma_gh_ready: rc 0 when a credential can see $SLUG. Asked once a run; a repo
# no credential sees is one alert (deduped per day by the lib) and rc 1.
GH_STATE=""
_ma_gh_ready() {
  if [ -z "$GH_STATE" ]; then
    GH_STATE=off
    if command -v gh_rest >/dev/null 2>&1 && command -v gh_repo_use_token >/dev/null 2>&1; then
      if gh_repo_use_token "$SLUG"; then GH_STATE=ok
      else gh_repo_invisible_alert merged-advance "$SLUG" "peer-built ticket advance" >/dev/null 2>&1
      fi
    fi
  fi
  [ "$GH_STATE" = ok ]
}
# _ma_gh_pr <n> -> PR_AT, PR_SHA, PR_EP. rc 0 merged, 1 not merged (open or
# closed unmerged), 2 unread (a failed read, no 40-hex merge sha, a bad time).
_ma_gh_pr() {
  local rc=0
  PR_AT=""; PR_SHA=""; PR_EP=""
  gh_rest GET "repos/$SLUG/pulls/$1" > "$TMP/pr.json" || rc=$?
  [ "$rc" = 0 ] || return 2
  jq -e 'type == "object"' "$TMP/pr.json" >/dev/null 2>&1 || return 2
  PR_AT=$(jq -r '.merged_at // empty' "$TMP/pr.json" 2>/dev/null)
  [ -n "$PR_AT" ] || return 1
  PR_SHA=$(jq -r '.merge_commit_sha // empty' "$TMP/pr.json" 2>/dev/null)
  [[ "$PR_SHA" =~ ^[0-9a-f]{40}$ ]] || return 2
  PR_EP=$(jq -rn --arg c "$PR_AT" '$c | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || PR_EP=""
  case "$PR_EP" in ''|*[!0-9]*) return 2 ;; esac
  return 0
}
# _ma_live_sha: ONE read of the prod version route per run -> LIVE_ST sha
# (LIVE_SHA set), none (404: no version route) or err (anything else). An
# anonymous read 404s on a fail-closed route (docs/LESSONS.md, TK-44), so it
# carries VERSION_AUTH, else the board bearer.
LIVE_ST=""; LIVE_SHA=""
_ma_live_sha() {
  local url c hdr
  [ -n "$LIVE_ST" ] && return 0
  LIVE_ST=err
  url="${VERSION_URL:-}"; [ -n "$url" ] || { [ -n "$PROD" ] && url="${PROD%/}/api/internal/version"; }
  [ -n "$url" ] || return 0
  hdr="Authorization: Bearer $MA_TOKEN"; [ -n "${VERSION_AUTH:-}" ] && hdr="$VERSION_AUTH"
  # BH-9862: the production board token is not sent to a staging site.
  [ -n "$STG_BASE" ] && hdr="X-Release-Model: staging"
  c=$(curl -s -m 20 -o "$TMP/version.json" -w '%{http_code}' -H "$hdr" -H "User-Agent: curl/8" \
        "$url" </dev/null 2>/dev/null) || c=""
  case "$c" in
    200) LIVE_SHA=$(jq -r '.sha // .commit // empty' "$TMP/version.json" 2>/dev/null | tr 'A-F' 'a-f')
         if [[ "$LIVE_SHA" =~ ^[0-9a-f]{7,40}$ ]]; then LIVE_ST=sha; else LIVE_SHA=""; fi ;;
    404) LIVE_ST=none ;;
  esac
  return 0
}
# _ma_deployed -> DEP: yes-version | yes-grace | behind | unknown. Unknown is
# never yes (D11).
_ma_deployed() {
  local rc=0 st
  DEP=unknown
  _ma_live_sha
  case "$LIVE_ST" in
    sha)
      if [ "${LIVE_SHA:0:7}" = "${PR_SHA:0:7}" ]; then DEP=yes-version; return 0; fi
      gh_rest GET "repos/$SLUG/compare/$PR_SHA...$LIVE_SHA" > "$TMP/cmp.json" || rc=$?
      [ "$rc" = 0 ] || return 0
      st=$(jq -r '.status // empty' "$TMP/cmp.json" 2>/dev/null)
      case "$st" in
        identical|ahead) DEP=yes-version ;;
        behind|diverged) DEP=behind ;;
      esac ;;
    none)
      if [ $(( $(date +%s) - PR_EP )) -ge "$GRACE" ]; then DEP=yes-grace; else DEP=behind; fi ;;
  esac
  return 0
}

# --- a staging project: does PRODUCTION serve the merge? (BH-9876) ------------
# TK-787 (2026-11-21): the lane read only staging, so it said "not live on
# production yet" 51 minutes after production served the commit, and moved a
# system-filed ticket to done on a merge that it called not live.
# _ma_prod_live: ONE read of the production version route per run -> PLIVE_ST
# sha (PLIVE set) or err. The address is the board's own base, never
# VERSION_URL: release_model_apply pointed that one at staging. The bearer is
# the production board token, sent to production only.
PLIVE_ST=""; PLIVE=""
_ma_prod_live() {
  local c
  [ -n "$PLIVE_ST" ] && return 0
  PLIVE_ST=err
  c=$(curl -s -m 20 -o "$TMP/pversion.json" -w '%{http_code}' \
        -H "Authorization: Bearer $MA_TOKEN" -H "User-Agent: curl/8" \
        "${BASE%/}/api/internal/version" </dev/null 2>/dev/null) || c=""
  [ "$c" = 200 ] || return 0
  PLIVE=$(jq -r '.sha // .commit // empty' "$TMP/pversion.json" 2>/dev/null | tr 'A-F' 'a-f')
  if [[ "$PLIVE" =~ ^[0-9a-f]{7,40}$ ]]; then PLIVE_ST=sha; else PLIVE=""; fi
  return 0
}
# _ma_prod_serves -> PSERVE: yes | no | unknown, for the merge commit in PR_SHA.
# Unknown is never yes and never no: the caller posts nothing on it.
_ma_prod_serves() {
  local rc=0 st
  PSERVE=unknown
  [[ "${PR_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || return 0
  _ma_prod_live
  [ "$PLIVE_ST" = sha ] || return 0
  if [ "${PLIVE:0:7}" = "${PR_SHA:0:7}" ]; then PSERVE=yes; return 0; fi
  _ma_gh_ready || return 0
  gh_rest GET "repos/$SLUG/compare/$PR_SHA...$PLIVE" > "$TMP/pcmp.json" || rc=$?
  [ "$rc" = 0 ] || return 0
  st=$(jq -r '.status // empty' "$TMP/pcmp.json" 2>/dev/null)
  case "$st" in
    identical|ahead) PSERVE=yes ;;
    behind|diverged) PSERVE=no ;;
  esac
  return 0
}

TMP=$(mktemp -d) || exit 0
trap 'rm -rf "$TMP"' EXIT
rc=$(_ma_get "$API/boards" "$TMP/boards.json")
[ "$rc" = 200 ] || exit 0
BIDS=$(jq -r '(.boards? // .) | .[]?.id' "$TMP/boards.json" 2>/dev/null) || BIDS=""
[ -n "$BIDS" ] || exit 0

: > "$TMP/cands.tsv"
n=0
while IFS= read -r bid; do
  [ -n "$bid" ] || continue
  n=$((n + 1))
  rc=$(_ma_get "$API/boards/$bid/tickets" "$TMP/list-$n.json")
  [ "$rc" = 200 ] || continue
  jq -r '(.tickets? // .) | .[]? | select(type == "object")
         | ((.status // "") | ascii_downcase) as $s
         | select($s == "in_progress" or $s == "review")
         | [ (.id | tostring), (.key // (.id | tostring)), $s,
             ((if (.reporter | type) == "object" then .reporter.userId else null end)
               // .reporterId // "") ]
         | @tsv' "$TMP/list-$n.json" 2>/dev/null >> "$TMP/cands.tsv"
done <<<"$BIDS"

# Start where the last capped run stopped (FAIRNESS above). An id no longer
# on the list starts from the top.
NEXT="$HARNESS/state/merged-advance-$PROJECT.next"
nid=""; [ -r "$NEXT" ] && nid=$(head -1 "$NEXT" 2>/dev/null)
if [ -n "$nid" ]; then
  awk -F'\t' -v id="$nid" '$1 == id {f = 1} f' "$TMP/cands.tsv" > "$TMP/rot.tsv"
  if [ -s "$TMP/rot.tsv" ]; then
    awk -F'\t' -v id="$nid" '$1 == id {exit} {print}' "$TMP/cands.tsv" >> "$TMP/rot.tsv"
    mv "$TMP/rot.tsv" "$TMP/cands.tsv"
  fi
fi

MOVED=0; CONLY=0; S_NOAUDIT=0; S_AUDITFAIL=0; S_NEWER=0; S_SPOKE=0; S_CREVIEW=0; S_BACK=0; S_GAVEUP=0
S_NOLOCAL=0; S_NOPR=0; S_PROPEN=0; S_BEHIND=0; S_PEERUNREAD=0; S_AMBIG=0; S_SLICE=0; S_SETTLE=0; S_NOPROBE=0
EXAMINED=0; LEFT=0; IDX=0; STOPAT=""
NCANDS=$(grep -c . "$TMP/cands.tsv" 2>/dev/null) || NCANDS=0

while IFS="$(printf '\t')" read -r tid tkey tst trep; do
  [ -n "$tid" ] || continue
  IDX=$((IDX + 1))
  if [ "$EXAMINED" -ge "$MAX" ]; then LEFT=$((NCANDS - IDX + 1)); STOPAT="$tid"; break; fi

  # 2. the newest build for the key must itself be a PR
  newest=$(_ma_builds "$tkey" | head -1)
  PEER=0; splan=""; stitle=""; srec="-"; sledger=""
  if [ -z "$newest" ]; then
    # 2p. no build dir on this box: the peer path (header, BH-8786). Where it
    # goes first, so a client review ticket costs no request (as step 4).
    PEER=1; S_NOLOCAL=$((S_NOLOCAL + 1))
    if [ "$trep" = system ]; then to=done
    elif [ "$tst" = in_progress ]; then to=review
    else S_CREVIEW=$((S_CREVIEW + 1)); continue
    fi
    EXAMINED=$((EXAMINED + 1))
    rc=$(_ma_get "$API/tickets/$tid" "$TMP/t.json")
    rst=""
    [ "$rc" = 200 ] && { rst=$(jq -r '((.status? // .ticket.status? // "") | ascii_downcase)' "$TMP/t.json" 2>/dev/null) || rst=""; }
    if [ -z "$SLUG" ] || [ "$rst" != "$tst" ]; then S_PEERUNREAD=$((S_PEERUNREAD + 1)); continue; fi
    prn=$(_ma_peer_pr "$TMP/t.json")
    case "$prn" in
      '') S_NOPR=$((S_NOPR + 1)); continue ;;
      *[!0-9]*) S_AMBIG=$((S_AMBIG + 1)); continue ;;
    esac
    _ma_gh_ready || { S_PEERUNREAD=$((S_PEERUNREAD + 1)); continue; }
    prc=0; _ma_gh_pr "$prn" || prc=$?
    case "$prc" in
      0) ;;
      1) S_PROPEN=$((S_PROPEN + 1)); continue ;;
      *) S_PEERUNREAD=$((S_PEERUNREAD + 1)); continue ;;
    esac
    jq -r '.body // ""' "$TMP/pr.json" > "$TMP/prbody.md" 2>/dev/null || : > "$TMP/prbody.md"
    splan="$TMP/prbody.md"
    stitle=$(jq -r '.title // ""' "$TMP/pr.json" 2>/dev/null) || stitle=""
    sledger="$HARNESS/state/slice-board/$PROJECT-$tkey-pr$prn"
    sha="${PR_SHA:0:8}"; verdict=PEER; token="pr-$prn-$sha"
    pr="https://github.com/$SLUG/pull/$prn"
    cutoff=$(date -u -d "@$PR_EP" '+%Y-%m-%dT%H:%M:%SZ')
  else
    ndir="${newest#*	}"
    pr=$(_ma_pr "$ndir")
    if [ -z "$pr" ]; then
      older=0
      while IFS="$(printf '\t')" read -r _ od; do
        [ -n "$(_ma_pr "$od")" ] && { older=1; break; }
      done < <(_ma_builds "$tkey" | tail -n +2)
      [ "$older" = 1 ] && S_NEWER=$((S_NEWER + 1))
      continue
    fi
    bn=$(basename "$ndir")
    bstamp="${newest%%	*}"

    # 3. the deploy audit for exactly that build
    aline=$(awk -v b="$bn" '$3 == b' "$HARNESS/state/postmerge-qa-done.txt" 2>/dev/null | tail -1)
    sha=""; verdict=""; cutoff=""
    if [ -n "$aline" ]; then
      set -- $aline
      sha="${4:-}"; verdict="${5:-}"
      cutoff="${1}T${2}"
    elif lt_read postmerge_qa "$bn"; then
      verdict="$LT_VAL"
      # No stamp in a ledger row: RESULT's mtime is earlier than the audit, so a
      # client comment between the two holds the ticket (more cautious, not less).
      cutoff=$(date -u -d "@$(stat -c %Y "$ndir/RESULT" 2>/dev/null || echo 0)" '+%Y-%m-%dT%H:%M:%SZ')
    fi
    if [ -z "$verdict" ]; then S_NOAUDIT=$((S_NOAUDIT + 1)); continue; fi
    case "$verdict" in
      PASS|NOT_COVERED_NO_QA_ENV) ;;
      *) S_AUDITFAIL=$((S_AUDITFAIL + 1)); continue ;;
    esac
    case "$sha" in ''|*[!0-9a-f]*) sha="" ;; esac
    token="${sha:-$bstamp}"
    splan="$ndir/plan.md"
    srec="$ndir"; sledger="$ndir/slice-board"
  fi

  # 2s. a slice plan for THIS ticket (BH-9865): board-closeout keeps it in
  # progress and decompose-parent-close closes it. No comment, no move. A
  # weak slice marker holds too (BH-10080), and a held slice whose ledger has
  # no terminal answer gets its settle spawned, detached (a hand-opened PR
  # reaches no conductor settle).
  if slice_board_token "$splan" "$tid" "$tkey" >/dev/null 2>&1 \
     || slice_board_marker "$splan" "$stitle" "$tid" "$tkey" >/dev/null 2>&1; then
    S_SLICE=$((S_SLICE + 1))
    if [ "$DRY" = 0 ] && [ -n "$sledger" ] && [ -x "$SELF/slice-board-settle.sh" ] \
       && [ ! -s "$sledger/filed" ] && [ ! -s "$sledger/exists" ] && [ ! -e "$sledger/unknown-paged" ]; then
      mkdir -p "$HARNESS/logs" 2>/dev/null
      ( HARNESS="$HARNESS" setsid "$SELF/slice-board-settle.sh" "$PROJECT" "$tkey" "$pr" "$srec" --ticket "$tid" --park 1 \
          </dev/null >>"$HARNESS/logs/slice-board.log" 2>&1 9>&- 8>&- & ) 2>/dev/null
      S_SETTLE=$((S_SETTLE + 1))
      MA_LOG "MERGED_ADVANCE_SLICE_SETTLE $tkey $pr"
    fi
    continue
  fi

  # 3b. this lane's own earlier outcome for this ticket and audit
  #   moved   our move landed (echoed). Finding the ticket open again means a
  #           person moved it back: that wins, and it is never moved again.
  #   gave up the move failed MERGED_ADVANCE_MOVE_TRIES times: one alert was
  #           sent, nothing more is tried for this token.
  mkey="advanced $PROJECT $tid $token"
  mbase="$HARNESS/state/merged-advance-$PROJECT-$tid-$token"
  if cm_has "$mkey" - "$mbase.moved"; then S_BACK=$((S_BACK + 1)); continue; fi
  if [ -e "$mbase.gaveup" ]; then S_GAVEUP=$((S_GAVEUP + 1)); continue; fi

  if [ "$PEER" = 0 ]; then
    # 4. where it goes
    if [ "$trep" = system ]; then to=done
    elif [ "$tst" = in_progress ]; then to=review
    else S_CREVIEW=$((S_CREVIEW + 1)); continue
    fi

    # 5. the ticket's own record: same status, nobody spoke since the audit
    EXAMINED=$((EXAMINED + 1))
    rc=$(_ma_get "$API/tickets/$tid" "$TMP/t.json")
    [ "$rc" = 200 ] || continue
    rst=$(jq -r '((.status? // .ticket.status? // "") | ascii_downcase)' "$TMP/t.json" 2>/dev/null) || rst=""
    [ "$rst" = "$tst" ] || continue
  else
    # 5p. deployed? The ticket record was read in 2p; it is not read again.
    _ma_deployed
    case "$DEP" in
      yes-*) ;;
      behind) S_BEHIND=$((S_BEHIND + 1)); continue ;;
      *) S_PEERUNREAD=$((S_PEERUNREAD + 1)); continue ;;
    esac
  fi
  cutep=$(jq -rn --arg c "$cutoff" '$c | sub(" "; "T") | fromdateiso8601' 2>/dev/null) || cutep=""
  case "$cutep" in ''|*[!0-9]*) continue ;; esac
  # This lane's own comment carries its sentence AND this audit's witness
  # (`commit <sha8>`, else the PR URL). A client who quotes the sentence is
  # still the client (lead review lr-4034-93265e68e589).
  witness="commit $sha"; [ -n "$sha" ] || witness="$(_ma_esc "$pr")"
  spoke=$(jq -r --argjson cut "$cutep" --arg me "$SELF_NAME" --arg w "$witness" '
      [ (.comments? // .ticket.comments? // .data.comments? // [])[]
        | select(type == "object")
        | select((.author | if type == "object" then (.userId // "") else (. // "") end) != "system")
        | select((.author | if type == "object" then (.name // "") else "" end) != $me)
        | select((.body // "" | tostring) as $b | ($b | contains("This is merged and")) and ($b | contains($w)) | not)
        | ((.createdAt // "") | tostring | sub("\\.[0-9]+Z$"; "Z")) as $t
        | (try ($t | fromdateiso8601) catch null) as $e
        | select($e == null or $e > $cut) ] | length' "$TMP/t.json" 2>/dev/null) || spoke=""
  case "$spoke" in ''|*[!0-9]*) continue ;; esac
  if [ "$spoke" -gt 0 ]; then S_SPOKE=$((S_SPOKE + 1)); continue; fi

  # 6. dedupe before the write
  ckey="advance $PROJECT $tid $token"
  cmark="$HARNESS/state/merged-advance-$PROJECT-$tid-$token.mark"
  already=0
  if cm_has "$ckey" - "$cmark"; then already=1
  elif jq -r '[(.comments? // .ticket.comments? // .data.comments? // [])[] | (.body // "")] | .[]' \
         "$TMP/t.json" 2>/dev/null | grep -F 'This is merged and' | grep -qF "$witness"; then
    already=1
  fi

  # 6s. a staging project (BH-9876): the words and the move follow what
  # PRODUCTION serves. yes -> the production comment and the normal move.
  # no -> the staging comment and NO move: the app's own audit moves the
  # ticket when the release is live. unknown -> nothing this run.
  # ikind: the production comment of a staging project has its own
  # idempotency key, so a board that dedupes on the key does not drop it as a
  # repeat of the staging comment.
  stg_hold=0; stg_live=0; ikind=""
  if [ -n "$STG_BASE" ]; then
    if [ "$PEER" = 0 ]; then
      # The merge commit of THIS ticket's PR, never one left by an earlier ticket.
      PR_SHA=""; lprn="${pr##*/pull/}"; lprn="${lprn%%[!0-9]*}"
      if [ -n "$lprn" ] && [ -n "$SLUG" ] && _ma_gh_ready; then
        _ma_gh_pr "$lprn" || PR_SHA=""
      fi
    fi
    _ma_prod_serves
    case "$PSERVE" in
      yes) stg_live=1; ikind="live-"
           # The production comment is "already there" only when the THREAD has
           # one of this lane's comments for this witness that does not say
           # "not live". The marker is not asked: it can stand for the staging
           # comment (a run that stopped before the hold marker), and the
           # close-out's "on its way to staging ... not live" comment matches
           # the witness when that is the PR address. Moving on either one
           # leaves "not live" as the last word on a moved ticket (TK-787).
           already=0
           mine=$(jq -r --arg w "$witness" '[(.comments? // .ticket.comments? // .data.comments? // [])[]
                    | (.body // "" | tostring)
                    | select(contains("This is merged and") and contains($w))
                    | select(contains("not live on production yet") | not)] | length' "$TMP/t.json" 2>/dev/null) || mine=""
           case "$mine" in ''|*[!0-9]*|0) ;; *) already=1 ;; esac ;;
      no)  if [ "$tst" != in_progress ]; then S_CREVIEW=$((S_CREVIEW + 1)); continue; fi
           stg_hold=1 ;;
      *)   S_PEERUNREAD=$((S_PEERUNREAD + 1)); continue ;;
    esac
  fi

  # 6p. a live probe of the primary screen before `review` (BH-9987, header).
  probe_html=""
  if [ "$RP_ON" = 1 ] && [ "$to" = review ] && [ "$stg_hold" = 0 ] && [ "$already" = 0 ] \
     && [ "$verdict" != PASS ]; then
    proute=/; [ "$PEER" = 0 ] && proute=$(rp_primary_route "$splan")
    purl="${PROD%/}$proute"
    rp_probe "$PROD" "$proute" >/dev/null
    [ "$DRY" = 1 ] && printf 'DRYRUN PROBE %s %s %s\n' "$purl" "$RP_OUTCOME" "$RP_CODE" >&2
    if ! rp_passes "$RP_OUTCOME"; then
      S_NOPROBE=$((S_NOPROBE + 1))
      [ "$DRY" = 1 ] && continue
      MA_LOG "MERGED_ADVANCE_PROBE_HOLD $tkey $purl $RP_OUTCOME HTTP $RP_CODE"
      # The one-alert dedupe is a `commented` ledger row first and the file
      # second (bin/lib/comment-mark.sh), so this script adds no raw state/ write.
      if ! cm_has "probe-alerted $PROJECT $tid" "$token" "$mbase.probe-alerted"; then
        cm_put "probe-alerted $PROJECT $tid" "$token" "$mbase.probe-alerted" || true
        [ -x "$HARNESS/bin/alert-line.sh" ] && HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" \
          "[$PROJECT] merged-advance: $tkey held: its main screen $purl did not answer in production ($RP_OUTCOME HTTP $RP_CODE). It stays in progress; the next run probes again." >/dev/null 2>&1
      fi
      continue
    fi
    epurl=$(_ma_esc "$purl")
    if [ "$RP_OUTCOME" = served ]; then
      probe_html="<p>We opened its main screen in production ($epurl) and it answered.</p>"
    else
      probe_html="<p>We opened its main screen in production ($epurl). It asks for sign-in, so nobody has checked it signed in yet.</p>"
    fi
  fi

  # 7. the comment
  epr=$(_ma_esc "$pr")
  if [ "$verdict" = PASS ]; then
    body="<p>This is merged and the post-merge check passed in production (${sha:+commit $sha, }<a href=\"$epr\">$epr</a>).</p>"
  elif [ "$verdict" = PEER ] && [ "$DEP" = yes-grace ]; then
    body="<p>This is merged and in main (commit $sha, <a href=\"$epr\">$epr</a>). Status: merged, deploy not confirmed from here.</p>"
  else
    body="<p>This is merged and production is serving it (${sha:+commit $sha, }<a href=\"$epr\">$epr</a>). Nobody has clicked through it in production yet.</p>"
  fi
  # BH-9862: a staging project. Same lead words (`This is merged and`, the
  # dedupe reads them), the site named is staging, and it never says live.
  # BH-9876: only while production does not serve the merge (stg_hold).
  if [ "$stg_live" = 1 ]; then
    body="<p>This is merged and production is serving it (${sha:+commit $sha, }<a href=\"$epr\">$epr</a>). Nobody has clicked through it in production yet.</p>"
  elif [ "$stg_hold" = 1 ]; then
    estg=$(_ma_esc "$STG_BASE")
    if [ "$verdict" = PASS ]; then
      body="<p>This is merged and on staging: <a href=\"$estg\">$estg</a>. The post-merge check passed there (${sha:+commit $sha, }<a href=\"$epr\">$epr</a>).</p>"
    elif [ "$verdict" = PEER ] && [ "$DEP" = yes-grace ]; then
      body="<p>This is merged and in main (commit $sha, <a href=\"$epr\">$epr</a>). Status: merged, staging deploy not confirmed from here.</p>"
    else
      body="<p>This is merged and on staging: <a href=\"$estg\">$estg</a> (${sha:+commit $sha, }<a href=\"$epr\">$epr</a>). Nobody has clicked through it on staging yet.</p>"
    fi
    body="$body<p>It is not live on production yet. It goes live with the next release.</p>"
  fi
  body="$body$probe_html"
  if [ "$stg_hold" = 1 ]; then body="$body<p>The ticket stays in progress until the release is live.</p>"
  elif [ "$to" = done ]; then body="$body<p>Moving it to done.</p>"
  else body="$body<p>Moving it to review so you can check it.</p>"; fi
  jq -n --arg b "$body" '{body: $b}' > "$TMP/comment.json" 2>/dev/null || continue
  printf '{"toStatus":"%s","sortOrder":999999}' "$to" > "$TMP/move.json"

  if [ "$DRY" = 1 ]; then
    [ "$already" = 0 ] && printf 'DRYRUN POST %s\n%s\n' "$API/tickets/$tid/comments" "$body" >&2
    [ "$stg_hold" = 1 ] && continue
    printf 'DRYRUN POST %s {"toStatus":"%s"}\n' "$API/tickets/$tid/move" "$to" >&2
    [ "$to" = review ] && printf 'DRYRUN POST %s {"to":"client"}\n' "$API/tickets/$tid/turn" >&2
    continue
  fi

  # 8. comment, marker, move
  if [ "$already" = 0 ]; then
    c=$(_ma_post "$API/tickets/$tid/comments" "$TMP/comment.json" \
          "advance-$PROJECT-$tid-$token-${ikind}comment" "$TMP/resp.json")
    case "$c" in
      2??) cm_put "$ckey" - "$cmark" ;;
      *) MA_LOG "MERGED_ADVANCE_FAILED $tkey comment HTTP $c"; continue ;;
    esac
  fi
  # BH-9876: comment only. The marker ends this lane's work for this token.
  if [ "$stg_hold" = 1 ]; then
    cm_put "$mkey" - "$mbase.moved"
    CONLY=$((CONLY + 1)); continue
  fi
  m=$(_ma_post "$API/tickets/$tid/move" "$TMP/move.json" \
        "advance-$PROJECT-$tid-$token-move" "$TMP/resp.json")
  case "$m" in
    2??) if jq -e --arg to "$to" '[.. | strings] | index($to)' "$TMP/resp.json" >/dev/null 2>&1; then
           cm_put "$mkey" - "$mbase.moved"; rm -f "$mbase.tries" 2>/dev/null
           MOVED=$((MOVED + 1)); printf '%s\n' "$tkey"
           [ "$to" = review ] && _ma_turn "$tid" "$tkey" "$token"
           continue
         fi ;;
  esac
  # A failed move: count the attempt. At the cap, give up once, with an alert.
  n=0; [ -r "$mbase.tries" ] && n=$(tr -dc '0-9' < "$mbase.tries" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$mbase.tries" 2>/dev/null || true
  if [ "$n" -ge "$TRIES" ]; then
    : > "$mbase.gaveup" 2>/dev/null || true
    MA_LOG "MERGED_ADVANCE_GAVE_UP $tkey move to $to failed $n time(s) (last HTTP $m); the comment stands, the ticket is not moved again"
    [ -x "$HARNESS/bin/alert-line.sh" ] && HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" \
      "[$PROJECT] merged-advance: $tkey could not be moved to $to after $n attempt(s) (last HTTP $m). Move it by hand; the lane stops trying." >/dev/null 2>&1
    S_GAVEUP=$((S_GAVEUP + 1)); continue
  fi
  CONLY=$((CONLY + 1))
done < "$TMP/cands.tsv"

if [ "$DRY" = 0 ]; then
  if [ -n "$STOPAT" ]; then
    mkdir -p "$HARNESS/state" 2>/dev/null || true
    printf '%s\n' "$STOPAT" > "$NEXT" 2>/dev/null || true
  else
    rm -f "$NEXT" 2>/dev/null || true
  fi
fi
[ "$LEFT" -gt 0 ] && MA_LOG "MERGED_ADVANCE_CAPPED $LEFT left for the next run (MERGED_ADVANCE_MAX=$MAX)"
MA_LOG "MERGED_ADVANCE moved=$MOVED comment-only=$CONLY skipped: no-audit=$S_NOAUDIT audit-fail=$S_AUDITFAIL newer-build=$S_NEWER client-spoke=$S_SPOKE client-review=$S_CREVIEW moved-back=$S_BACK move-gave-up=$S_GAVEUP no-local-build=$S_NOLOCAL no-pr-in-thread=$S_NOPR pr-open=$S_PROPEN deploy-behind=$S_BEHIND peer-unread=$S_PEERUNREAD pr-ambiguous=$S_AMBIG no-live-probe=$S_NOPROBE slice-plan=$S_SLICE slice-settle=$S_SETTLE"
exit 0
