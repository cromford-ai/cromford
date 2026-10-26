#!/bin/bash
# bin/lead-verdict.sh — BH-1525: record a head-bound review verdict in the jobs
# DB from any machine holding HARNESS_SECRET, and read a PR's verdict history.
#
# WHY. The lead's verdicts reached the merge lanes as files its tooling wrote
# on the hub over SSH (state/review-autopilot/... and a `provcleared` line in
# state/merge-conductor/attempts.txt). One row here does the same job for every
# merge lane — bin/lib/verdicts.sh is the reader — and needs no SSH:
#   MERGE / MERGE-WITH-NOTES (source lead|human) clears the conductor's
#     provenance hold and its autopilot read for THAT head;
#   BLOCK (source lead|human) stops every merge lane on THAT head, whatever a
#     box review said, until a push or a newer MERGE row.
#   A human row is final for its head (BH-8349): a later lead row on that
#     head is advice and does not change what stands (exit 5 below).
#
# THE LEAD TOKEN. A lead or human row also needs LEAD_VERDICT_TOKEN (the worker
# refuses it with 403 otherwise; HARNESS_SECRET alone writes only `box` rows).
# It is read from the FILE named by LEAD_VERDICT_TOKEN_FILE (default
# ~/.config/cromford/lead-verdict-token, mode 600), which exists only on
# the lead's Mac and the hub. It travels to curl in a 0600 header file, never
# on argv (ps shows argv) and never printed, and that file is removed on exit.
#
# FROM OPERATOR'S MAC (BH-7188): keychain item cromford/HARNESS_SECRET. No hub
# and no SSH are needed. bin/jobs-client.sh reads HARNESS_SECRET in this order:
# env, env/global.env, the keychain item above
#   (`security add-generic-password -U -s cromford -a HARNESS_SECRET -w`),
# then a 0600 file named by HARNESS_SECRET_FILE. The worker URL comes from env,
# env/global.env, the keychain item cromford/JOBS_URL, then the built-in
# default (https://harness-jobs.<HARNESS_WORKERS_SUBDOMAIN>.workers.dev). The
# lead token and the human token already sit in ~/.config/cromford/. A secret
# read from the keychain or the file is never exported, never on argv, never printed.
#
# THE PARTICIPANT TOKEN (BH-5352). With no readable lead token file, a
# --source lead post sends the token in HARNESS_PARTICIPANT_TOKEN_FILE (no
# default; an approved participant machine's own token) as x-participant-token,
# in the same 0600 header file. The worker records the row only when that
# machine holds the lead-review grant and a `done` lead review on this head,
# names the machine as the reviewer, and marks it auth=participant; the
# lead-verdict status description then starts `lead review by <name>: `.
#
# THE HUMAN TOKEN (BH-3831). The lead token is shared with the hub's lead lane,
# so on its own it cannot prove a person wrote a human row. A --source human post
# also sends x-human-verdict-token, read from HUMAN_VERDICT_TOKEN_FILE (default
# ~/.config/cromford/human-verdict-token, mode 600), which exists only on
# the operator's Mac. It rides in the same 0600 header file. Without it the post still
# goes out with one stderr line, and the worker decides by its human_verdict_mode
# settings row: shadow records the row as an UNVERIFIED human verdict (this
# prints so), enforce refuses it 403 (exit 1).
#
# THE SHA IS REQUIRED AND IS NEVER LOOKED UP. A verdict is a fact about the
# code that was read; resolving "the live head" at post time would bind it to
# whatever was pushed in between. Pass the sha the review actually read.
# IT IS COMPARED, THOUGH (BH-3348). `post` reads the PR's head over REST
# (pulls/<n> head.sha) first and refuses, exit 3, when the sha is not it: verdict
# #176 bound af9842fb1, a commit that never reached GitHub, and Mergify landed
# 4f4b3f914 under nobody's review. A head it cannot read is exit 1, never a post.
#
# THE lead-verdict STATUS (BH-3348). A lead|human row, once the worker has
# recorded it, is published as the `lead-verdict` commit status on that sha
# (bin/lib/verdict-status.sh): success for MERGE / MERGE-WITH-NOTES, failure for
# BLOCK. Mergify's queue_conditions require it on cromford. A box row
# never stands, so it never sets the gate. Row recorded, status refused: exit 4.
#
# REQUEST / LIST (BH-1952). `request` asks the lead for a review of ONE head:
# a row in lead_review_requests (POST /api/lead-reviews, lead token, through
# bin/lib/lead-reviews.sh). The same rule holds: the sha is the head you want
# read, never looked up. Any non-2xx (the route contract in that lib names 409
# for a duplicate head and 403 without the lead token) is printed as the worker
# said it and is exit 1, never retried.
# --priority <n> (BH-5151, 1..1000, higher first) puts the request ahead of
# older ones in the lead-review lane, instead of backdating created_at by hand.
# Sent again for the same head and notes, it re-orders a row still `requested`.
# A 2xx whose row does not carry that priority (the row is already running or
# finished, or the worker predates BH-5151) is exit 1 and says so.
# `list` prints the requests, optionally for one repo.
# RESET (BH-5400). `reset <request-id>` sends a finished request (done, failed
# or superseded) back to `requested` for a re-review, through
# POST /api/lead-reviews/<id>/reset (lead token). The worker clears its result
# and promoted stamp and records the reset, so bin/lead-review-land.sh lands
# the re-review's verdict over the earlier one. A request already requested is
# a 200 no-op. A running one with a fresh heartbeat is refused (exit 1, the
# worker's message printed); one whose heartbeat is older than the settings row
# lead_review_claim_stale_s (fallback 900 s) is reclaimed to `requested` (BH-7711).
#
# BASH 3.2 (BH-3565). The lead's Mac runs this under /bin/bash 3.2, where an
# empty "${arr[@]}" is unbound under set -u: every post died in gh-rest.sh
# before the head check. The libs a post sources are now lint-pinned 3.2 safe
# (tests/lead-verdict-bash32.bh-3565-test.sh). On top of that, a bash older than
# LV_BASH_MIN (4.4) re-execs this script under the first LV_BASH_CANDIDATES
# entry that is new enough (/opt/homebrew/bin/bash, /usr/local/bin/bash); with
# none it prints one stderr line and carries on. LV_BASH_REEXEC=1 marks the
# second pass, so it can never loop.
# THE CLIENT LEVEL (BH-3565). A lead|human post sends x-lead-verdict-client:
# LV_CLIENT_LEVEL, and the worker refuses (426, "git pull") a row from a client
# below the lead_verdict_min_client settings row (0 = off, the seed). An old
# checkout publishes no lead-verdict status, and only the worker can refuse it.
# At row 4 a checkout older than BH-6548 is refused, so it cannot leave a bot
# BLOCK standing on the head a person just merged.
#
# THE AUTHORITY RULE (BH-3683). The hub's lead-review lane is the verdict
# authority: its --source lead MERGE publishes lead-verdict with no Mac
# involved. On a repo with live lead_protected_paths rows (jobs worker), a lead MERGE /
# MERGE-WITH-NOTES first asks la_decide (bin/lib/lead-authority.sh), and the
# answer depends on lead_authority_mode (BH-4145; per repo
# lead_authority_mode.<owner>.<name>, else global):
#   lane  (the default, no row) — a protected path is reported, not withheld:
#         the status publishes, the row carries the note token
#         `authority:lane-protected`, and after the publish ONE PR comment says
#         `touches protected paths <paths>; cleared to merge on the lead verdict`, deduped
#         per head by state/lead-authority/lane-hit-<owner_name>-<pr>-<sha12>
#         (written only after the comment POST returned 0; a failed comment is
#         one stderr line and the next post retries it).
#   human — when the PR touches a protected path, or the repo's lead_authority
#         row is human or human:precision, the row is still recorded (it is
#         advice, and precision scoring reads it) with the note token
#         `authority:human-required`, NO status is published, and the exit is 5.
#         A `--source human` verdict then publishes it.
# An answer that cannot be read (mode row included) withholds the same way
# under either mode. A BLOCK always publishes failure.
# THE RISK TIER (BH-5022). bin/lead-review-enqueue.sh signs off a head that
# bin/lib/risk-tier.sh classified low with --source risk-tier: a MERGE only (the
# worker refuses any other word), posted with the lead token, put through the
# same la_decide check as a lead MERGE, and published with the --note text as
# the status description (`low risk: <reasons>`). A protected-path hit is never
# a risk-tier sign-off under either mode, and neither is a withheld authority:
# NO row is written (a standing risk-tier advice row would cancel the lead
# review the caller falls back to) and the exit is 5.
# `authority` prints the rule in force for a repo, and with <pr> <head-sha> the
# answer for that head; it writes nothing. The mode is changed with
# bin/jobs-client.sh setting-set lead_authority_mode[.<owner>.<name>] lane|human,
# the authority row (it only bites under human) with
# bin/jobs-client.sh setting-set lead_authority.<owner>.<name> lane|human.
#
# usage:
#   bin/lead-verdict.sh post <owner/repo> <pr> <head-sha> <MERGE|MERGE-WITH-NOTES|BLOCK>
#                            [--source lead|human|box|risk-tier] [--model <id>] [--reviewer <name>]
#                            [--report-url <https-url>] [--note "<one line>"]
#                            [--review-tier low|medium|high] [--review-mode full|intent|risk-tier]
#                            [--break-it clean|failed:<k>|could-not-run]
#   bin/lead-verdict.sh show <owner/repo> <pr> [<head-sha>]
#   bin/lead-verdict.sh request <owner/repo> <pr> <head-sha> [--notes <text>] [--prior <ref>]
#                               [--priority <1..1000>]   nudge (request) a lead review of that head
#   bin/lead-verdict.sh list [<owner/repo>]
#   bin/lead-verdict.sh reset <request-id>
#   bin/lead-verdict.sh authority <owner/repo> [<pr> <head-sha>]
# exit: 0 ok, 1 refused or the worker answered an error (its message printed),
#       2 usage, 3 (post) the sha is not the PR's head: nothing written,
#       4 (post) the row is recorded but the lead-verdict status is not published,
#       5 (post) the row is recorded as advice; the status is withheld until a
#         --source human verdict publishes it (BH-3683; lead_authority_mode=human,
#         or an undecidable authority under either mode). Under --source
#         risk-tier a 5 writes NO row: a lead review decides the head (BH-5022).
#         Under --source lead a 5 is also a head where a human verdict is
#         final: the worker answered human_final, the row is advice, and no
#         status is published (BH-8349; a push to a new head resets it).
if [ -z "${LV_BASH_REEXEC:-}" ]; then
  _lv_min="${LV_BASH_MIN:-4.4}"
  _lv_ge() { # _lv_ge <major> <minor> — is that bash at least LV_BASH_MIN
    [ "$1" -gt "${_lv_min%%.*}" ] || { [ "$1" -eq "${_lv_min%%.*}" ] && [ "$2" -ge "${_lv_min#*.}" ]; }
  }
  if ! _lv_ge "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" 2>/dev/null; then
    _lv_cands="${LV_BASH_CANDIDATES:-/opt/homebrew/bin/bash /usr/local/bin/bash}"
    for _lv_b in $_lv_cands; do
      [ -x "$_lv_b" ] || continue
      _lv_v=$("$_lv_b" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"' 2>/dev/null) || continue
      _lv_ge "${_lv_v%% *}" "${_lv_v#* }" 2>/dev/null || continue
      export LV_BASH_REEXEC=1
      exec "$_lv_b" "$0" "$@"
    done
    echo "lead-verdict: running under bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} (older than $_lv_min) and no newer bash found in $_lv_cands; carrying on, since the libs this script loads are lint-pinned bash-3.2 safe (tests/lead-verdict-bash32.bh-3565-test.sh). brew install bash to silence this" >&2
  fi
  unset -f _lv_ge; unset _lv_min _lv_cands _lv_b _lv_v
fi
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS:-$(cd "$SELF_DIR/.." && pwd)}"
export HARNESS
# shellcheck source=/dev/null
. "$SELF_DIR/jobs-client.sh" || { echo "lead-verdict: bin/jobs-client.sh did not load" >&2; exit 1; }

usage() { sed -n '/^# usage:/,/^#         --source human verdict/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "lead-verdict: $*" >&2; exit 1; }

# lv_req <method> <path> [body] — _jobs_req in THIS shell (not a substitution),
#   so JOBS_HTTP / JOBS_BODY survive for the error line: a 400 names the field
#   the worker refused, and swallowing it would make a typo look like an outage.
lv_req() {
  local out; out=$(mktemp "${TMPDIR:-/tmp}/lead-verdict.XXXXXX") || die "mktemp failed"
  if JOBS_ALERT=0 _jobs_req "$@" > "$out"; then cat "$out"; rm -f "$out"; return 0; fi
  rm -f "$out"
  die "worker refused or unreachable (http ${JOBS_HTTP:-none}): $(printf '%s' "${JOBS_BODY:-}" | jq -r '.error // .' 2>/dev/null)"
}

LEAD_VERDICT_TOKEN_FILE="${LEAD_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/lead-verdict-token}"
HUMAN_VERDICT_TOKEN_FILE="${HUMAN_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/human-verdict-token}"
# What this script can do, sent on every lead|human post (x-lead-verdict-client):
# 1 = the BH-1525 row only; 2 = + the BH-3348 head check and lead-verdict status,
# and bash-3.2 safe libs (BH-3565); 3 = + the BH-3683 authority check; 4 = + a
# lead|human MERGE dismisses the bot BLOCK on the same head (BH-6548, BH-6617).
# Raise it with the next capability the worker must be able to insist on.
LV_CLIENT_LEVEL=4

# lv_post_lead <json-body> <source> — POST /api/verdicts with the bearer AND the
#   lead token (and, for source human, the human token when its file is
#   readable), all in a header file. For source lead with no readable lead
#   token file it sends the participant token instead (BH-5352). Prints the worker's answer; dies with the
#   worker's own error on anything but 2xx. Never echoes a secret.
lv_post_lead() {
  local body="$1" source="${2:-}" tok htok="" hdr out code payload tfile="$LEAD_VERDICT_TOKEN_FILE" theader=x-lead-verdict-token
  local pfile="${HARNESS_PARTICIPANT_TOKEN_FILE:-}"
  # BH-5352: no lead token here, so a source=lead post goes as a participant.
  if [ "$source" = lead ] && [ ! -r "$LEAD_VERDICT_TOKEN_FILE" ] && [ -n "$pfile" ] && [ -r "$pfile" ]; then
    tfile="$pfile"; theader=x-participant-token
  fi
  [ -r "$tfile" ] || die "a lead/human verdict needs the lead token file (LEAD_VERDICT_TOKEN_FILE, now $LEAD_VERDICT_TOKEN_FILE), or for --source lead a participant token file (HARNESS_PARTICIPANT_TOKEN_FILE, now ${pfile:-unset}) — not readable"
  tok=$(head -1 "$tfile" | tr -d ' \r\n')
  [ -n "$tok" ] || die "the token file $tfile is empty"
  [ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is not set (env or env/global.env)"
  hdr=$(umask 077; mktemp "${TMPDIR:-/tmp}/lead-verdict-h.XXXXXX") || die "mktemp failed"
  trap 'rm -f "${hdr:-}"' EXIT
  printf 'authorization: Bearer %s\n%s: %s\nx-lead-verdict-client: %s\ncontent-type: application/json\n' \
    "$HARNESS_SECRET" "$theader" "$tok" "$LV_CLIENT_LEVEL" > "$hdr"
  unset tok
  if [ "$source" = human ]; then
    [ -r "$HUMAN_VERDICT_TOKEN_FILE" ] && htok=$(head -1 "$HUMAN_VERDICT_TOKEN_FILE" | tr -d ' \r\n')
    if [ -r "$HUMAN_VERDICT_TOKEN_FILE" ]; then
      # BH-3849: a warning, never a refusal. GNU stat on a box, BSD on the Mac.
      local m
      m=$(stat -c %a "$HUMAN_VERDICT_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$HUMAN_VERDICT_TOKEN_FILE" 2>/dev/null)
      [ "$m" = 600 ] || echo "lead-verdict: warning: $HUMAN_VERDICT_TOKEN_FILE is mode ${m:-unknown}, not 600 — chmod 600 it" >&2
    fi
    if [ -n "$htok" ]; then
      printf 'x-human-verdict-token: %s\n' "$htok" >> "$hdr"
    else
      echo "lead-verdict: no human verdict token (HUMAN_VERDICT_TOKEN_FILE, now $HUMAN_VERDICT_TOKEN_FILE): the worker records this human verdict as unverified in shadow mode and refuses it in enforce mode" >&2
    fi
    unset htok
  fi
  out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X POST \
          -H "@$hdr" --data-binary "$body" "$JOBS_URL/api/verdicts" 2>/dev/null) || { rm -f "$hdr"; die "worker unreachable ($JOBS_URL)"; }
  rm -f "$hdr"
  code="${out##*$'\n'}"; payload="${out%$'\n'*}"
  case "$code" in 2*) printf '%s' "$payload" ;;
    *) die "worker refused (http $code): $(printf '%s' "$payload" | jq -r '.error // .' 2>/dev/null)" ;; esac
}

lv_key_ok() { # lv_key_ok <repo> <pr> — the argument checks both verbs share
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo must be owner/name, got '$1'"
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "pr must be a positive integer, got '$2'"
}

# lv_head_check <repo> <pr> <sha> — the PR's head over REST, never the etag
#   cache (a 304 replay is an old answer). Returns when it is <sha>; exits 3 when
#   it is another sha, 1 when it cannot be read. The libs load here, not at the
#   top: show/request/list never touch GitHub.
lv_head_check() {
  local head rc=0
  # shellcheck source=bin/lib/verdict-status.sh
  command -v vs_publish >/dev/null 2>&1 || . "$SELF_DIR/lib/verdict-status.sh" 2>/dev/null \
    || die "bin/lib/verdict-status.sh did not load; the PR head cannot be checked"
  command -v _gh_rest_field >/dev/null 2>&1 || die "bin/lib/gh-rest.sh did not load; the PR head cannot be checked"
  head=$(GH_ETAG=0 _gh_rest_field "repos/$1/pulls/$2" '.head.sha') || rc=$?
  [ "$rc" = 0 ] || die "could not read the head of $1#$2 (gh_rest rc $rc); not posting a verdict that may bind a dead sha"
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  [ "$head" = "$3" ] && return 0
  echo "lead-verdict: head moved: $1#$2 is at ${head:0:12}, not ${3:0:12}; the verdict would bind a sha that is not the PR's head — nothing posted" >&2
  exit 3
}

# lv_lane_comment <repo> <pr> <sha> <paths> — BH-4145: ONE PR comment per head
#   when a lane MERGE published on a protected path. The marker is written only
#   after the POST returned 0; a failed POST is one stderr line, never a failed post.
lv_lane_comment() {
  local root mark grc=0
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || { echo "lead-verdict: no HARNESS root; the protected-path comment on $1#$2 is skipped" >&2; return 0; }
  mark="$root/state/lead-authority/lane-hit-$(printf '%s' "$1" | tr 'A-Z/' 'a-z_')-$2-${3:0:12}"
  [ -e "$mark" ] && return 0
  gh_rest POST "repos/$1/issues/$2/comments" -f "body=touches protected paths $4; cleared to merge on the lead verdict" >/dev/null 2>&1 || grc=$?
  if [ "$grc" != 0 ]; then
    echo "lead-verdict: the protected-path comment on $1#$2 did not post (gh_rest rc $grc); the next post retries" >&2
    return 0
  fi
  mkdir -p "${mark%/*}" 2>/dev/null && touch "$mark" 2>/dev/null
  return 0
}

# lv_dismiss_stale <repo> <pr> <sha> <verdict> <row-ref> <source> — BH-5213:
#   once a MERGE / MERGE-WITH-NOTES has published success on <sha>, the lead
#   lane's OWN standing CHANGES_REQUESTED reviews are dismissed
#   (bin/lib/lead-stale-review.sh; a person's review is never touched), so
#   Mergify's #changes-requested-reviews-by=0 lets the PR queue.
#   BH-6548: for source lead or human this includes a review AT <sha> (mode
#   verdict): the post is itself a verdict on that code, and only a post that
#   published reaches here. A risk-tier sign-off did not read the code, so it
#   dismisses older-head reviews only (mode merge).
#   Best effort: the row and the status already stand, so a failure is one
#   stderr line and never changes the exit; bin/pipeline-health.sh names what
#   is left (stale-review). In mode merge a head whose pass completed clean is
#   flagged under state/lead-stale-review/, and a second MERGE on it makes no
#   GitHub call. Mode verdict never uses the flag: a re-review can post a new
#   BLOCK on the same head after a clean pass, and the flag is per box, so a
#   flag would make the next MERGE skip that BLOCK. A lib whose LSR_MODES has
#   no verdict (an old checkout) gets the older-head pass and one stderr line.
#   LV_DISMISS_STALE=0 skips it (bin/lead-review-land.sh runs its own step 2d,
#   with retries, on the same head).
lv_dismiss_stale() {
  local root flag out mode=merge rc=0
  [ "${LV_DISMISS_STALE:-1}" = 0 ] && return 0
  case "${6:-}" in lead|human) mode=verdict ;; esac
  command -v lsr_dismiss_stale >/dev/null 2>&1 || . "$SELF_DIR/lib/lead-stale-review.sh" 2>/dev/null
  if ! command -v lsr_dismiss_stale >/dev/null 2>&1; then
    echo "lead-verdict: bin/lib/lead-stale-review.sh did not load; lead BLOCK reviews on $1#$2 not dismissed - re-run this post" >&2
    return 0
  fi
  root="${HARNESS:-}"
  flag="$root/state/lead-stale-review/clean-$(printf '%s' "$1" | tr 'A-Z/' 'a-z_')-$2-$3"
  [ "$mode" = merge ] && [ -n "$root" ] && [ -e "$flag" ] && return 0
  if ! out=$(mktemp "${TMPDIR:-/tmp}/lead-verdict-d.XXXXXX"); then
    echo "lead-verdict: no temp file; lead BLOCK reviews on $1#$2 not dismissed - re-run this post" >&2
    return 0
  fi
  if [ "$mode" = verdict ]; then
    case " ${LSR_MODES:-} " in
      *" verdict "*) lsr_dismiss_stale "$1" "$2" "$3" "$4" "$5" "" verdict "" > "$out" || rc=$? ;;
      *) echo "lead-verdict: $SELF_DIR/lib/lead-stale-review.sh predates BH-6548, so a lead BLOCK review on the same head ${3:0:12} of $1#$2 was not checked; git pull this checkout and re-run this post" >&2
         lsr_dismiss_stale "$1" "$2" "$3" "$4" "$5" > "$out" || rc=$? ;;
    esac
  else lsr_dismiss_stale "$1" "$2" "$3" "$4" "$5" > "$out" || rc=$?; fi
  if [ "$rc" = 0 ]; then
    [ "$LSR_DISMISSED" = 0 ] || echo "lead-verdict: dismissed $LSR_DISMISSED stale lead BLOCK review(s) on $1#$2 superseded by $4 on ${3:0:12}: $(tr '\n' ' ' < "$out")" >&2
    [ "$mode" = merge ] && [ -n "$root" ] && mkdir -p "${flag%/*}" 2>/dev/null && : > "$flag" 2>/dev/null
  elif [ "$mode" = verdict ]; then
    echo "lead-verdict: stale lead BLOCK reviews on $1#$2 not all dismissed ($LSR_FAILED failed or unreadable, HTTP ${GH_REST_STATUS:-000}): $(tr '\n' ' ' < "$out")- re-run this post to retry (bin/lead-stale-review-sweep.sh retries older-head reviews only)" >&2
  else
    echo "lead-verdict: stale lead BLOCK reviews on $1#$2 not all dismissed ($LSR_FAILED failed or unreadable, HTTP ${GH_REST_STATUS:-000}): $(tr '\n' ' ' < "$out")- the next MERGE post or bin/lead-stale-review-sweep.sh retries" >&2
  fi
  rm -f "$out"
  return 0
}

lv_post() {
  [ $# -ge 4 ] || usage
  local repo="$1" pr="$2" sha verdict="$4" source=lead model="" reviewer="" url="" note="" body resp state desc rtier="" rmode="" bi=""
  sha=$(printf '%s' "$3" | tr 'A-F' 'a-f'); shift 4
  lv_key_ok "$repo" "$pr"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "head-sha must be the full 40-hex sha the review read, got '$sha'"
  case "$verdict" in MERGE|MERGE-WITH-NOTES|BLOCK) ;; *) die "verdict must be MERGE, MERGE-WITH-NOTES or BLOCK, got '$verdict'" ;; esac
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --source) source="$2" ;; --model) model="$2" ;; --reviewer) reviewer="$2" ;;
      --report-url) url="$2" ;; --note) note="$2" ;;
      # BH-6967: the head's risk tier and the review that wrote the row. Checked
      # here so a bad value never reaches the worker (it refuses it 400 too).
      --review-tier)
        case "$2" in low|medium|high) rtier="$2" ;;
          *) echo "lead-verdict: review-tier must be low, medium or high, got '$2'" >&2; exit 2 ;; esac ;;
      --review-mode)
        case "$2" in full|intent|risk-tier) rmode="$2" ;;
          *) echo "lead-verdict: review-mode must be full, intent or risk-tier, got '$2'" >&2; exit 2 ;; esac ;;
      # BH-6970: the break-it verifier's result on this head (k = failing cases, 1..999).
      --break-it)
        case "$2" in clean|could-not-run|failed:[1-9]|failed:[1-9][0-9]|failed:[1-9][0-9][0-9]) bi="$2" ;;
          *) echo "lead-verdict: break-it must be clean, failed:<k> (k 1..999) or could-not-run, got '$2'" >&2; exit 2 ;; esac ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$reviewer" ] || reviewer="${JOBS_BOX:-$(hostname 2>/dev/null)}"
  if [ "$source" = risk-tier ]; then
    [ "$verdict" = MERGE ] || die "a risk-tier verdict can only be MERGE, got '$verdict'"
    [ -n "$note" ] || die "a risk-tier verdict needs --note (it is the status description)"
  fi
  desc="$note"
  lv_head_check "$repo" "$pr" "$sha"
  # BH-3683: may this lead row publish success? rc 1/2 = recorded as advice only.
  local withhold="" lane_hit=""
  if { [ "$source" = lead ] || [ "$source" = risk-tier ]; } && [ "$verdict" != BLOCK ] && command -v la_decide >/dev/null 2>&1; then
    if ! la_decide "$repo" "$pr" "$sha" lead; then
      withhold="$LA_REASON"
      note="${note:+$note }authority:human-required"
    elif [ "${LA_PROTECTED_HIT:-}" = 1 ] && [ "$source" = risk-tier ]; then
      # BH-5022: the classifier calls a protected path high, so this is a rule
      # that slipped. A rules sign-off never clears one, whatever the mode.
      withhold="a risk-tier sign-off on protected paths: $LA_PROTECTED_PATHS"
      note="${note:+$note }authority:human-required"
    elif [ "${LA_PROTECTED_HIT:-}" = 1 ]; then
      # BH-4145: lead_authority_mode=lane — reported, not withheld.
      lane_hit="$LA_PROTECTED_PATHS"
      note="${note:+$note }authority:lane-protected"
    fi
  fi
  # BH-5022: a withheld risk-tier sign-off writes NO row. risk-tier is a standing
  # source, so an advice row would stand on the head and make the enqueue skip it
  # and lead-review.sh supersede the lead review this exit 5 falls back to.
  if [ "$source" = risk-tier ] && [ -n "$withhold" ]; then
    echo "lead-verdict: risk-tier sign-off withheld on ${sha:0:12}: $withhold; no row written, a lead review decides this head" >&2
    exit 5
  fi
  body=$(jq -nc --arg r "$repo" --argjson p "$pr" --arg h "$sha" --arg v "$verdict" --arg s "$source" \
    --arg m "$model" --arg rv "$reviewer" --arg u "$url" --arg n "$note" --arg rt "$rtier" --arg rm "$rmode" --arg bi "$bi" \
    '{repo:$r,pr:$p,head_sha:$h,verdict:$v,source:$s}
     + (if $rt == "" then {} else {review_tier:$rt} end)
     + (if $rm == "" then {} else {review_mode:$rm} end)
     + (if $bi == "" then {} else {break_it:$bi} end)
     + (if $m == "" then {} else {reviewer_model:$m} end)
     + (if $rv == "" then {} else {reviewer:$rv} end)
     + (if $u == "" then {} else {report_url:$u} end)
     + (if $n == "" then {} else {note:$n} end)') || die "could not build the request body"
  case "$source" in
    lead|human|risk-tier) resp=$(lv_post_lead "$body" "$source") || exit 1 ;;
    *)                    resp=$(lv_req POST /api/verdicts "$body") || exit 1 ;;
  esac
  printf '%s' "$resp" | jq -r '.verdict | "recorded verdict #\(.id): \(.verdict) (\(.source)) on \(.repo)#\(.pr) @ \(.head_sha[0:12]) at \(.created_at)"'
  case "$source" in lead|human|risk-tier) ;; *) return 0 ;; esac
  if [ "$source" = human ] && [ "$(printf '%s' "$resp" | jq -r '.human_verified // false' 2>/dev/null)" != true ]; then
    echo "lead-verdict: recorded as an UNVERIFIED human verdict (no human verdict token); it will be refused once human_verdict_mode=enforce" >&2
  fi
  # BH-3905: the worker signed this row identically to an earlier one (same second).
  local dup
  dup=$(printf '%s' "$resp" | jq -r '.human_sig_duplicate_of // empty' 2>/dev/null)
  if [ -n "$dup" ]; then
    echo "lead-verdict: WARNING: this post repeats verdict #$dup within the same second and will read unproven; wait a second and post again if a protected PR needs it" >&2
  fi
  # BH-8349: a human verdict on this head is final. The worker recorded this
  # lead row as advice (note token human-final:#<id>, no gate fact); the status
  # the human row published stays as it is.
  local hfin
  if [ "$source" = lead ] && hfin=$(printf '%s' "$resp" | jq -er '.human_final | select(type == "object" and .id != null) | "#\(.id) (\(.verdict // "?"))"' 2>/dev/null); then
    echo "lead-verdict: status withheld on ${sha:0:12}: human verdict $hfin is final on this head; this lead row is advice" >&2
    exit 5
  fi
  if [ -n "$withhold" ]; then
    echo "lead-verdict: status withheld on ${sha:0:12}: $withhold; a --source human verdict publishes it (bin/lead-verdict.sh post $repo $pr $sha $verdict --source human)" >&2
    exit 5
  fi
  case "$verdict" in BLOCK) state=failure ;; *) state=success ;; esac
  case "$url" in https://*) ;; *) url="https://github.com/$repo/pull/$pr" ;; esac
  [ "$source" = risk-tier ] || desc="$verdict by $reviewer (verdict #$(printf '%s' "$resp" | jq -r '.verdict.id // "?"'))"
  # BH-7118: a replayed word says which reviewed head it was carried from.
  if [ "$source" != risk-tier ]; then
    local tk; local -a tks=()
    read -r -a tks <<<"$note"
    for tk in ${tks[@]+"${tks[@]}"}; do
      [[ "$tk" =~ ^lead-replay:([0-9a-f]{7,40})$ ]] && { desc="$desc, carried from ${BASH_REMATCH[1]}"; break; }
    done
  fi
  # BH-5352: the prefix follows the row the worker wrote, never this client's mode.
  desc=$(vs_lead_desc "$(printf '%s' "$resp" | jq -c '.verdict' 2>/dev/null)" "$desc")
  if vs_publish "$repo" "$sha" "$state" "$desc" "$url"; then
    [ -z "$lane_hit" ] || lv_lane_comment "$repo" "$pr" "$sha" "$lane_hit"
    [ "$verdict" = BLOCK ] || lv_dismiss_stale "$repo" "$pr" "$sha" "$verdict" "#$(printf '%s' "$resp" | jq -r '.verdict.id // "?"')" "$source"
    return 0
  fi
  echo "lead-verdict: row recorded, $(vs_context) status NOT published on ${sha:0:12}; Mergify will not queue this head until it is (re-run this post, or publish it by hand)" >&2
  exit 4
}

lv_show() {
  [ $# -ge 2 ] || usage
  local repo="$1" pr="$2" head="${3:-}" q resp
  lv_key_ok "$repo" "$pr"
  q="/api/verdicts?repo=$repo&pr=$pr"
  if [ -n "$head" ]; then
    head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "head-sha must be a full 40-hex sha, got '$head'"
    q="$q&head=$head"
  fi
  resp=$(lv_req GET "$q") || exit 1
  # A replayed or carried row (note `lead-replay:<G12>`, BH-8028) names its
  # source: `carried_from:#N`, else `ref:#N`, else the source head G12.
  printf '%s' "$resp" | jq -r '
    def carried: (.note // "") as $n
      | if ($n | contains("lead-replay:") | not) then ""
        elif ($n | test("(^| )carried_from:#[0-9]+")) then ", carried from #\($n | capture("(^| )carried_from:#(?<i>[0-9]+)").i)"
        elif ($n | test("(^| )ref:#[0-9]+")) then ", carried from #\($n | capture("(^| )ref:#(?<i>[0-9]+)").i)"
        else ", carried from \($n | capture("lead-replay:(?<g>[0-9a-fA-F]*)").g)" end;
    (if .head == null then empty
     elif .standing == null then "standing on \(.head[0:12]): none"
     else "standing on \(.head[0:12]): \(.standing.verdict) (\(.standing.source), #\(.standing.id)\(.standing | carried))" end),
    (.rows[] | "#\(.id)\t\(.created_at)\t\(.head_sha[0:12])\t\(.verdict)\t\(.source)\t\(.reviewer_model // "-")\t\(.report_url // "-")")'
}

# lv_lr_load — bin/lib/lead-reviews.sh, loaded by request/list only: post and
#   show never needed it and keep working on a box that does not carry it.
lv_lr_load() {
  command -v lr_post_lead >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/lead-reviews.sh
  . "$SELF_DIR/lib/lead-reviews.sh" 2>/dev/null || die "bin/lib/lead-reviews.sh did not load"
}

# lv_nudge <repo> <pr> <sha> — BH-4956: after a request is stored, the gate
#   fact nudged_sha puts the PR first on the needs-review worklist, and one
#   lead-review doorbell (lcw_ring) makes the owning box tick now. Both are
#   fail-open: the request already stands, so a failure is one stderr line and
#   the exit code does not change.
lv_nudge() {
  pr_gate_event_put "$1" "$2" "nudge@$3" nudge "nudged_sha=$3" >/dev/null 2>&1 \
    || echo "lead-verdict: nudge not recorded (the request stands; the lane reviews it from the request row)" >&2
  # shellcheck source=bin/lib/lead-chain-wake.sh
  if ! { command -v lcw_ring >/dev/null 2>&1 || . "$SELF_DIR/lib/lead-chain-wake.sh" 2>/dev/null; } \
     || ! ( lcw_ring lead-review "$1" "$2" "$3" ); then
    echo "lead-verdict: doorbell not rung (the lane's cron reviews it)" >&2
  fi
  return 0
}

lv_request() {
  [ $# -ge 3 ] || usage
  local repo="$1" pr="$2" sha notes="" prior="" pri="" body resp stored
  sha=$(printf '%s' "$3" | tr 'A-F' 'a-f'); shift 3
  lv_key_ok "$repo" "$pr"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "lead-verdict: head-sha must be the full 40-hex sha to review, got '$sha'" >&2; usage; }
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      # BH-6967: only bin/lead-review-enqueue.sh writes the review tier and mode
      # tokens; a hand request's text never sets them.
      --notes) notes="${2//review-tier:/review-tier=}"; notes="${notes//review-mode:/review-mode=}" ;;
      --prior) prior="$2" ;;
      --priority)
        [[ "$2" =~ ^[0-9]+$ ]] && [ "${#2}" -le 4 ] && [ "$((10#$2))" -ge 1 ] && [ "$((10#$2))" -le 1000 ] \
          || { echo "lead-verdict: --priority must be an integer 1..1000, got '$2'" >&2; usage; }
        pri="$((10#$2))" ;;
      *) usage ;;
    esac
    shift 2
  done
  body=$(jq -nc --arg r "$repo" --argjson p "$pr" --arg h "$sha" --arg by "${JOBS_BOX:-$(hostname 2>/dev/null)}" \
    --arg n "$notes" --arg pv "$prior" --arg pri "$pri" \
    '{repo:$r,pr:$p,head_sha:$h,requested_by:$by}
     + (if $n == "" then {} else {scope_notes:$n} end)
     + (if $pv == "" then {} else {prior_verdict_ref:$pv} end)
     + (if $pri == "" then {} else {priority:($pri|tonumber)} end)') || die "could not build the request body"
  lv_lr_load
  # lr_post_lead already wrote `HTTP <code>` (or why it made no call) to stderr.
  if ! resp=$(lr_post_lead '' "$body"); then
    [ -n "$resp" ] && echo "lead-verdict: request refused: $resp" >&2
    exit 1
  fi
  printf '%s' "$resp" | jq -er '.request | "requested lead review #\(.id) on \(.repo)#\(.pr) @ \(.head_sha[0:12]) (\(.status))"' 2>/dev/null \
    || printf '%s\n' "$resp"
  lv_nudge "$repo" "$pr" "$sha"
  [ -n "$pri" ] || return 0
  stored=$(printf '%s' "$resp" | jq -r '.request.priority // empty | tostring' 2>/dev/null)
  if [ "$stored" != "$pri" ]; then
    echo "lead-verdict: priority $pri was not stored (request #$(printf '%s' "$resp" | jq -r '.request.id // "?"' 2>/dev/null) is $(printf '%s' "$resp" | jq -r '.request.status // "?"' 2>/dev/null); a running or finished request keeps its order, or the worker predates BH-5151)" >&2
    exit 1
  fi
}

# lv_reset <request-id> — BH-5400: the sanctioned reset, never raw SQL.
lv_reset() {
  [ $# = 1 ] || usage
  local id="$1" resp
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "lead-verdict: request-id must be the request's id (letters, digits, . _ -), got '$id'" >&2; usage; }
  lv_lr_load
  # lr_post_lead already wrote `HTTP <code>` (or why it made no call) to stderr.
  if ! resp=$(lr_post_lead "/$id/reset" '{}'); then
    [ -n "$resp" ] && echo "lead-verdict: reset refused: $resp" >&2
    exit 1
  fi
  printf '%s' "$resp" | jq -er '(.existing // false) as $e | .request
    | "lead review \(.id): \(.status) (reset_count \(.reset_count // 0))\(if $e then ", already requested" else "" end)"' 2>/dev/null \
    || printf '%s\n' "$resp"
}

lv_list() {
  local repo="${1:-}" out rc
  [ -z "$repo" ] || [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo must be owner/name, got '$repo'"
  lv_lr_load
  out=$(mktemp "${TMPDIR:-/tmp}/lead-verdict.XXXXXX") || die "mktemp failed"
  # lr_get in THIS shell, so JOBS_BODY is still here when it fails.
  lr_get "${repo:+?repo=$repo}" > "$out"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    [ "$rc" -eq 75 ] && die "lead-review routes are not deployed on $JOBS_URL"
    die "worker refused or unreachable: ${JOBS_BODY:-}"
  fi
  jq -r '(.requests[] | "#\(.id)\t\(.created_at)\t\(.repo)#\(.pr)\t\(.head_sha[0:12])\t\(.status)"),
         (if .truncated then "(truncated)" else empty end)' "$out"; rc=$?
  rm -f "$out"
  return "$rc"
}

# lv_authority <owner/repo> [<pr> <head-sha>] — read only: the authority rule in
#   force for the repo, and with a head the answer a lead MERGE would get.
lv_authority() {
  [ $# = 1 ] || [ $# = 3 ] || usage
  local repo="$1" pr="${2:-}" sha="${3:-}" rc
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo must be owner/name, got '$repo'"
  # shellcheck source=bin/lib/verdict-status.sh
  command -v vs_publish >/dev/null 2>&1 || . "$SELF_DIR/lib/verdict-status.sh" 2>/dev/null
  command -v la_decide >/dev/null 2>&1 || die "bin/lib/lead-authority.sh did not load"
  echo "repo: $repo"
  _la_db_globs "$repo" || die "the protected paths of $repo could not be read (jobs worker down and no fresh cache); la_decide holds every lead MERGE (rc 2)"
  echo "globs (lead_protected_paths, from $LA_GLOBS_SRC): $(printf '%s' "$LA_GLOBS" | awk 'NF' | wc -l | tr -d ' ')"
  [ -z "$LA_GLOBS" ] || printf '%s\n' "$LA_GLOBS" | sed 's/^/  /'
  [ -z "${LA_GLOBS_FLOOR:-}" ] || echo "of which $(printf '%s\n' "$LA_GLOBS_FLOOR" | awk 'NF' | wc -l | tr -d ' ') have no DB row yet: the seed floor (catalog/lead-protected-paths.seed.tsv) still protects them; bin/lead-protected-paths-seed.sh on the hub turns them into rows"
  [ -n "$LA_GLOBS" ] || { echo "in scope: no (no live lead_protected_paths rows; the lane is the authority)"; return 0; }
  echo "in scope: yes"
  if _la_authority "$repo"; then echo "authority: $LA_AUTH ($LA_AUTH_SRC)"
  else echo "authority: UNREADABLE (settings row lead_authority.$(_la_key "$repo"))"; fi
  [ -n "$pr" ] || return 0
  lv_key_ok "$repo" "$pr"
  sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "head-sha must be a full 40-hex sha, got '$sha'"
  rc=0; la_decide "$repo" "$pr" "$sha" lead || rc=$?
  case "$rc" in
    0) echo "decision on #$pr @${sha:0:12}: a lead MERGE publishes ($LA_REASON)" ;;
    1) echo "decision on #$pr @${sha:0:12}: human required: $LA_REASON" ;;
    *) echo "decision on #$pr @${sha:0:12}: undecided, withheld: $LA_REASON" ;;
  esac
}

case "${1:-}" in
  post) shift; lv_post "$@" ;;
  authority) shift; lv_authority "$@" ;;
  show) shift; lv_show "$@" ;;
  request) shift; lv_request "$@" ;;
  list) shift; lv_list "$@" ;;
  reset) shift; lv_reset "$@" ;;
  *) usage ;;
esac
