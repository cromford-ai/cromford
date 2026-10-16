#!/bin/bash
# bin/review-autopilot.sh — hub cron (hourly, :17). Harness-authored PRs that
# age past 12h stop being just an alert and get an adversarial review attached.
#
# Why this exists: pipeline-health check 7 (stalepr:*) has been reporting the
# same shape for weeks — built work open >12h with no merge owner. The alert
# names the backlog; it does not make the backlog cheaper to clear. This lane
# does the part a machine can do (read the diff, judge it against the ticket
# and the iron laws, write the verdict on the PR) and leaves the part that
# needs a human exactly where it was: MERGING IS STILL HUMAN. Nothing here
# merges, approves, closes, or pushes.
#
# Gap it fills: review-prs.sh deliberately SKIPS harness-generated operator PRs
# (a build dir RESULT references them, or the body carries the pipeline
# marker) — those are the ones that pile up. This lane covers exactly them.
# It also stands down when review-prs.sh already reviewed the same head, so a
# PR never buys two reviews of one sha.
#
# Everything except the review itself is deterministic (the operator, 2026-08-20):
# selection is a gh query + an age cutoff, dedup is a state file keyed on the
# head sha, spend is capped per project per UTC day, and the comment is posted
# by gh — no model decides what gets reviewed, only what the review says.
#
# THE LEDGER, AND WHY IT IS WRITTEN BEFORE THE POST (BH-1018, 2026-09-19).
# Until now the head key landed ONLY after `gh pr comment` succeeded, and an
# empty model answer wrote nothing at all. Both are non-success exits that left
# the dedup false, so the next hourly tick re-bought a review that had already
# been paid for: the runaway-spend audit of 2026-09-17..19 counted 156 of 372
# review spends as re-buys, one PR sixteen times. ~/.claude/rules/metered-api-dedup.md
# names the shape — a persisted check BEFORE the billable call, three outcomes
# rather than two, "succeeded but returned nothing" treated as billed and
# TERMINAL, and terminal state written on every non-success path.
#
# So state/review-autopilot/<slug>-<num>-<head12> now has five first lines, and
# the tick dispatches on them:
#
#   reviewed <stamp> verdict=<V>            posted. Terminal for this head. It
#                                           is this lane's OWN dedupe ledger
#                                           (BH-1018) and nothing else reads it
#                                           since BH-1951: the conductor's
#                                           mc_autopilot_verdict reads the
#                                           `source=box` row ap_box_row POSTs
#                                           just before this line is written,
#                                           then the PR comment. It lands only
#                                           after the comment is up AND the row
#                                           is recorded (or the row was skipped
#                                           as not configured, logged).
#   skipped <stamp>: …                      review-prs.sh covered this head.
#   status=reviewed-unposted <stamp> verdict=<V> tries=<n>
#                                           PAID FOR. The whole comment is
#                                           cached beside it in `<key>.body`,
#                                           and the next tick re-posts those
#                                           bytes with NO model call — or, when
#                                           the comment is already up and only
#                                           the verdict row failed, finds its
#                                           own marker, posts no second comment
#                                           and retries the row alone.
#   empty <stamp> n=1                       the model returned nothing. Billed.
#                                           One retry, then:
#   empty-terminal <stamp> n=2              billed twice, nothing there.
#                                           No further call for this head.
#   unposted-terminal <stamp> verdict=<V> tries=<n>
#                                           paid for, cached, and gh refused it
#                                           REVIEW_AUTOPILOT_POST_TRIES times.
#                                           The `.body` is KEPT so an operator
#                                           can post it by hand.
#   failed <stamp> n=<k> rc=<rc>            the agent call DIED (rc≠0, and not
#                                           one of the not-billed codes). Billed
#                                           or unknowable, so counted; whatever
#                                           is in the out file is NOT a review
#                                           and is never posted. Retried until:
#   failed-terminal <stamp> n=<k> rc=<rc>   REVIEW_AUTOPILOT_FAIL_TRIES deaths.
#                                           No further call for this head.
#
# THE RECORD IS A ROW WHEN THE `no-twin-ledgers` FLAG IS UP (BH-4156). A file
# on one machine is a record a wiped or replaced hub does not have, and it
# re-buys every review it ever dispatched. With the flag up this lane writes NO
# record file: each state line above (the whole text, sha= lines included) is
# the `ledgers` row review_autopilot <owner/repo>#<num>@<head12> (status = the
# state word), the cached comment is review_autopilot_body (same key, status
# `cached`), the daily count is review_autopilot_cap, and the PR's newest
# `reviewed` head (for the verdict replay) is review_autopilot_pr
# <owner/repo>#<num>. The ledger's detail column holds 4000 characters, so a
# comment over 4000 bytes is never cut into a row: it is cached in the local
# `<key>.body` file instead (a cache, not the record), and so is a body whose
# row write failed. ap_body_get reads the row, then that file, so a long review
# whose post fails is re-posted with no model call, asks the PR first, and goes
# `unposted-terminal` with an alert, as in file mode. A record row whose write
# failed is kept in `<key>.pending` until the next tick writes it (ap_rec_get),
# so a lost write never resets a bound. The row
# is read first, and an unreadable row (the worker down, a pending record that
# still did not write, or a legacy file that did not import) buys nothing and
# posts nothing for that head this tick. A leftover key file is imported once
# (ap_import_legacy) and removed; a body file stays as the local cache.
# diff-<repo>-<n>.txt stays a file: it is the model's scratch input, not a
# record. With the flag down, everything is the file record described above.
#
# AND THE RC THAT WRITES NOTHING AT ALL (BH-1066). bin/agent-call.sh exits
# 74/75/76/77/78/79 when nothing was called and nothing was billed — the lane's
# own spend/pathway gate (BH-1141), a lock, no account with headroom, the hub
# refusing build work, a no-tools refusal, an argv-only or cliff-routed
# refusal. Until now the rc was discarded (`|| true`)
# and the daily cap charged on the next line, so the one-line refusal marker in
# $OUT was POSTED to the PR as the review and stamped `reviewed verdict=UNPARSED`
# — a review nobody bought, on a head that could then never be reviewed again.
# Those five codes now write no key, charge no cap, post nothing, and retry on
# the next tick. "Succeeded but returned nothing" (rc 0, empty out) is still
# billed and still terminal — it is a different fact.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=review-autopilot
# The fleet convention, and what makes this lane drivable by a fixture suite:
# tests/review-autopilot-post-retry-test.sh runs the REAL script against a
# scratch $HARNESS. A hardcoded root is a lane no test can reach.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# --print-body <owner/repo> <num> <head12> — the operator's half of an
# `unposted-terminal` alert in row mode (BH-4156): print the cached comment
# from its review_autopilot_body row. Read-only, no lock, no lane gate.
if [ "${1:-}" = --print-body ]; then
  [[ "${2:-}" == */* ]] && [[ "${3:-}" =~ ^[0-9]+$ ]] && [[ "${4:-}" =~ ^[0-9a-f]{12}$ ]] \
    || { echo "usage: $0 --print-body <owner/repo> <num> <head12>" >&2; exit 2; }
  # shellcheck source=bin/jobs-client.sh
  [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
  # shellcheck source=bin/lib/ledger-twin.sh
  . "$H/bin/lib/ledger-twin.sh" || exit 1
  lt_row review_autopilot_body "$2#$3@$4"; PB_RC=$?
  if [ "$PB_RC" = 0 ] && [ "$LT_VAL" = cached ]; then printf '%s\n' "$LT_DETAIL"; exit 0; fi
  echo "no cached review body for $2#$3@$4 (ledger rc $PB_RC, status '${LT_VAL:-none}'; the no-twin-ledgers flag must be up)" >&2
  exit 1
fi

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-review-autopilot, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-autopilot.
# shellcheck disable=SC1091
. "${H}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${H}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# The same-patch test for the verdict replay below (BH-2310). Missing, nothing is
# replayed and every new head is reviewed as before.
. "${H}/bin/lib/patch-same.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/patch-same.sh" 2>/dev/null || true
# The trivial-diff measure and the review-saving events (BH-2545). Missing, no
# saving is recorded, as before.
. "${H}/bin/lib/review-saving.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/review-saving.sh" 2>/dev/null || true
# "Has a verdict already been bought on this head?" and the shared per-head
# guard fp (BH-3930). Missing, the ledger skip below is passed over and the fp
# falls back to the identical inline format, so the guard key never drifts.
. "${H}/bin/lib/review-bought.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/review-bought.sh" 2>/dev/null || true
command -v review_fp >/dev/null 2>&1 || review_fp() { printf 'review:%s#%s@%s' "$1" "$2" "$3"; }
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-autopilot
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-autopilot

mkdir -p "$H/logs" "$H/locks" "$H/state/review-autopilot"
exec 9>"$H/locks/review-autopilot.lock"; flock -n 9 || exit 0
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$H/bin/lib/wake-lanes.sh" ] && . "$H/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip review-autopilot fleet && exit 0
# <<< wake backstop
LOG="$H/logs/review-autopilot.log"
STATE="$H/state/review-autopilot"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
command -v gh >/dev/null || { echo "$(STAMP) gh not installed — nothing to do" >> "$LOG"; exit 0; }

NOW=$(date +%s)
# A pinned clock for a sandboxed suite only (tests/review-autopilot-rows.bh-4156-test.sh).
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${REVIEW_AUTOPILOT_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$REVIEW_AUTOPILOT_NOW; fi
CUTOFF=$(( NOW - 43200 ))                       # 12h, same threshold as stalepr
DAY=$(date -u -d "@$NOW" +%Y%m%d)
CAP="${REVIEW_AUTOPILOT_DAILY_CAP:-0}"          # dispatched reviews / project / UTC day; 0 = unlimited (default since 2026-09-14)
POST_TRIES="${REVIEW_AUTOPILOT_POST_TRIES:-6}"  # gh attempts at ONE cached review before it parks (no model spend either way)
FAIL_TRIES="${REVIEW_AUTOPILOT_FAIL_TRIES:-3}"  # agent calls that DIED (rc≠0, billed or unknowable) before this head is parked
# The reviewer's model: review_model (bin/lib/review-model.sh) per project at
# the call — REVIEW_MODEL when set, else the project's build.review route
# (BH-1510.1). Never a literal, here or at the call site.
MAXDIFF=307200                                  # ~300KB of diff rides inline
DISPATCHED=""                                   # "<slug>#<n> -> <verdict>" lines for the beat

# Housekeeping: day-counters are worthless after a week; head-keyed state rows
# stay ~90d so a long-lived PR is not re-reviewed for a sha it already answered.
# A `<key>.body` is EXEMPT (BH-1066). It is not state, it is the paid-for review
# itself, cached because gh would not take it, and an `unposted-terminal` head
# is exactly the one an operator posts by hand — weeks later, off an alert. The
# sweep deleted it at 90 days and the money went with it. It is dropped when its
# PR is no longer open instead (the drain below), and the KEY still ages out, so
# a head nobody ever merged is reviewed once more after a quarter.
find "$STATE" -maxdepth 1 -name 'count-*' -mtime +7 -delete 2>/dev/null
find "$STATE" -maxdepth 1 -type f ! -name 'count-*' ! -name '*.body' -mtime +90 -delete 2>/dev/null

# ap_unposted_alert <slug> <num> <key> <h12> <tries> — a head that ran out of
# post attempts is a PAID-FOR review sitting on disk that nobody will ever see
# unless someone is told. One ALERTS line + one beat, at the transition, naming
# the exact command that delivers it. "Stopping is an alert, not a whisper."
ap_unposted_alert() {
  local slug="$1" num="$2" key="$3" h12="$4" tries="$5" line where post
  where="$key.body"
  post="gh pr comment $num -R $slug --body-file $key.body (the .body is kept until the PR closes)"
  if [ "${AP_ROWS:-0}" = 1 ] && [ ! -s "$key.body" ]; then
    where="the ledger row review_autopilot_body $slug#$num@$h12"
    post="$H/bin/review-autopilot.sh --print-body $slug $num $h12 > /tmp/ra-$num.md && gh pr comment $num -R $slug --body-file /tmp/ra-$num.md (the row is kept)"
  fi
  # $tries counts POST ATTEMPTS AND COMMENT READS, because a failed marker read
  # falls through to tries+1 (deliberately: it is what keeps the lane bounded
  # when the comments endpoint stays down). Saying "gh refused to post it N
  # times" sends an operator hunting for N post failures that may never have
  # happened — one post and five dead reads reach the same bound.
  line="[review-autopilot] $slug#$num @$h12 unposted-terminal: review paid for and cached at $where but it could not be delivered $tries times (post attempts + comment reads), a box verdict row that would not record counting as one too — post it by hand: $post; if the PR already carries this head's review, record its row instead: bin/lead-verdict.sh post $slug $num <full-sha> <verdict> --source box"
  HARNESS="$H" "$H/bin/alert-line.sh" "$line"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "review-autopilot-unposted:$slug#$num:$h12" --arg l "$line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

# ap_post <slug> <num> <key> <verdict> <tries> — put the cached comment (the
# file AP_BODYF names: <key>.body, or this tick's copy of the body row) on the PR, record its box row (ap_box_row) and settle <key>.
# rc 0 = it is up and the key says `reviewed`; rc 1 = it is not, and the key
# says what the next tick does; rc 2 = an earlier post had landed, settled with
# nothing sent this tick; rc 3 = the comment is up but its box row failed, so
# the key is NOT `reviewed` and the next tick retries the row (no second comment).
# NOTHING here calls the model: a failed post costs one gh call an hour, for at
# most POST_TRIES hours, and never a second review.
# ONE NON-SUCCESS COUNTER. `empty <stamp> n=<k>` and `failed <stamp> n=<k>
# rc=<rc>` are two shapes of the same fact — "this head was billed and produced
# nothing usable, k times". Reading them with two regexes let a head that
# alternates the two reset its own counter every tick and never go terminal.
ap_attempts() { # ap_attempts <record text>
  local n
  n=$(sed -nE 's/^(empty|failed) .* n=([0-9]+).*$/\2/p' <<<"$1" 2>/dev/null | head -1)
  printf '%s' "${n:-0}"
}

# ap_sha_line <key> -> "sha=<40 hex>\n" when the loop's $SHA is this key's head,
# else nothing. The key's name carries only 12 hex; the full sha lets a later
# verdict replay (BH-2310) resolve the reviewed head exactly (#2386 review, note 4).
ap_sha_line() {
  [[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] && [ "${SHA:0:12}" = "${1##*-}" ] && printf 'sha=%s\n' "$SHA"
  return 0
}

# ap_box_row <slug> <num> <key> <verdict> [note] — BH-1951: POST the
#   `source=box` verdict row for this head to /api/verdicts, the row
#   mc_autopilot_verdict reads (vd_box_word) instead of the key file. The box
#   bearer only, never the lead token. Called right BEFORE every `reviewed`
#   write, and only on paths that already hold the paid-for review, so a failed
#   POST never buys a second one.
#   rc 0 recorded (2xx)
#   rc 3 NOT CONFIGURED, logged: no jobs client in this process, an empty
#        JOBS_URL, the worker's own unknown-endpoint 404 (a worker older than
#        BH-1525), or a verdict with no row vocabulary (UNPARSED). The caller
#        writes its key as it always did.
#   rc 1 FAILED, logged with the HTTP code: anything else, including $SHA not
#        being this key's head (a row is never posted for the wrong sha).
ap_box_row() {
  local slug="$1" num="$2" key="$3" verdict="$4" note="${5:-}" h12 body
  h12="${key##*-}"
  case "$verdict" in
    MERGE|MERGE-WITH-NOTES|BLOCK) ;;
    *) echo "$(STAMP) [$slug#$num] @$h12 verdict=$verdict has no verdict-row word — no box row posted (not configured for it)" >> "$LOG"; return 3 ;;
  esac
  if ! command -v _jobs_req >/dev/null 2>&1; then
    echo "$(STAMP) [$slug#$num] @$h12 no jobs client in this process — no box row posted (not configured)" >> "$LOG"; return 3
  fi
  if command -v jobs_configured >/dev/null 2>&1 && ! jobs_configured; then
    echo "$(STAMP) [$slug#$num] @$h12 JOBS_URL is empty — no box row posted (not configured)" >> "$LOG"; return 3
  fi
  if ! [[ "${SHA:-}" =~ ^[0-9a-f]{40}$ ]] || [ "${SHA:0:12}" != "$h12" ]; then
    echo "$(STAMP) [$slug#$num] @$h12 the loop's head '${SHA:-<unset>}' is not this key's full sha — box row NOT posted" >> "$LOG"; return 1
  fi
  body=$(jq -nc --arg r "$slug" --argjson p "$num" --arg h "$SHA" --arg v "$verdict" \
           --arg rv "review-autopilot@$JOBS_BOX" \
           --arg n "review-autopilot $h12${note:+ $note}" \
           '{repo:$r,pr:$p,head_sha:$h,verdict:$v,source:"box",reviewer:$rv,note:$n}') || {
    echo "$(STAMP) [$slug#$num] @$h12 could not build the box row body — box row NOT posted" >> "$LOG"; return 1; }
  JOBS_ALERT=0 _jobs_req POST /api/verdicts "$body" >/dev/null
  case "${JOBS_HTTP:-}" in 2*) return 0 ;; esac
  if [ "${JOBS_HTTP:-}" = 404 ] && command -v _vd_worker_404 >/dev/null 2>&1 && _vd_worker_404 "$JOBS_BODY"; then
    echo "$(STAMP) [$slug#$num] @$h12 POST /api/verdicts is not deployed on this worker (its own 404) — no box row posted (not configured)" >> "$LOG"; return 3
  fi
  echo "$(STAMP) [$slug#$num] @$h12 box row POST failed (HTTP ${JOBS_HTTP:-none}) — the key is not settled; the next tick retries the row with no model call" >> "$LOG"
  return 1
}

# ap_skip_only_block <review> <ci-state> <base> — rc 0 when the BLOCK may be
#   downgraded because its ONE reason is CI test jobs that were SKIPPED (BH-5795).
#   Decided from the structured CI state first, the words last, and every part
#   must hold (the lead review of #5805 showed loose words downgrading real
#   BLOCKs: "the curl exit code is not checked", "case A3 was skipped to get
#   green", "the migration was not run against prod"):
#     1. the base is main: there the merge-queue batch tests the head. On any
#        other base nothing guarantees a run, so the BLOCK stands.
#     2. <ci-state> (gh's statusCheckRollup, `name=CONCLUSION`) names at least one
#        SKIPPED check and no FAILURE, CANCELLED, TIMED_OUT, ERROR,
#        ACTION_REQUIRED or STARTUP_FAILURE.
#     3. the final VERDICT line's reason names CI test jobs as its subject: a
#        skipped check's own name from <ci-state>, or "test jobs", "test shards",
#        "test suites", "CI jobs" or "shards" as whole words.
#     4. ...and says they did not run: "skipped", "ran none", "never ran",
#        "did not run", "no ... ran".
#     5. the reason is one clause: no comma, semicolon, "and", "but", "plus", "&".
#     6. the review body carries no `[BLOCK]` finding (a reason the VERDICT line
#        may not repeat; lead review of 973ce2e9).
ap_skip_only_block() {
  local r ci="${2:-}" base="${3:-main}" names n hit=0
  [ "$base" = main ] || return 1
  grep -qE '=SKIPPED' <<<"$ci" || return 1
  grep -qE '=(FAILURE|CANCELLED|TIMED_OUT|ERROR|ACTION_REQUIRED|STARTUP_FAILURE)' <<<"$ci" && return 1
  # A [BLOCK] finding in the body is a blocking reason the VERDICT line may not
  # repeat: never rewrite over it.
  grep -qF '[BLOCK]' <<<"$1" && return 1
  r=$(printf '%s\n' "$1" | grep -E '^[[:space:]*_>]*VERDICT:' | tail -1 \
    | sed -E 's/^[^:]*:[[:space:]*_]*BLOCK[[:space:]*_]*//; s/^[[:space:]]*[—-]+[[:space:]]*//' | tr '[:upper:]' '[:lower:]')
  [ -n "$r" ] || return 1
  # The skipped checks' names, split on the `=CONCLUSION, ` boundaries (a name
  # may hold a comma: "Tests, traced (shard 0/1)"), each in full and without
  # its parenthesised tail. A name in the reason becomes the token <job>, so
  # its own comma is not read as a second clause.
  names=$(printf '%s' "$ci" | sed 's/.*checks=//' | sed -E 's/=([A-Z_]+)(, |$)/=\1\n/g' \
    | sed -n 's/=SKIPPED$//p' | tr '[:upper:]' '[:lower:]' \
    | awk '{print} {t=$0; sub(/ \(.*$/, "", t); if (t != $0) print t}' | awk 'length >= 6' | sort -u | awk '{print length "\t" $0}' | sort -rn | cut -f2-)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$r" in *"$n"*) r="${r//"$n"/<job>}"; hit=1 ;; esac
  done <<<"$names"
  grep -qE '[,;+&]| and | but | plus ' <<<"$r" && return 1
  # 3: the subject is the skipped CI jobs, by name or by a whole CI-job term.
  [ "$hit" = 1 ] || grep -qE '\b(test (jobs?|shards?|suites?)|ci (test )?jobs?|shards?)\b' <<<"$r" || return 1
  # 4: and they did not run.
  grep -qE '\b(skipped|ran none|never ran|did not run|no (ci )?(test )?(jobs?|shards?|suites?) (ran|have run|has run))\b' <<<"$r"
}
# ap_skip_downgrade <review> <base> — the review with its final VERDICT line
# replaced by MERGE-WITH-NOTES and one note above it that says why.
ap_skip_downgrade() {
  local why
  if [ "$2" = main ]; then why="the base is main, so the merge-queue batch runs this PR's impact set before it lands"
  else why="the base is $2: CI now plans this head's impact set against main, and the lead-review enqueue starts a run for it"; fi
  printf '%s\n' "$1" | awk -v why="$why" '
    { line[NR] = $0; if ($0 ~ /^[[:space:]*_>]*VERDICT:/) last = NR }
    END { for (i = 1; i <= NR; i++) {
            if (i == last) {
              print "**Note (BH-5795, deterministic):** this review BLOCKed only because CI test jobs were skipped on this head. That is not a blocking finding: " why "."
              print ""
              print "VERDICT: MERGE-WITH-NOTES — the only blocking reason was skipped CI test jobs; " why
            } else print line[i] } }'
}

# --- THE RECORD, FILE OR ROW (BH-4156) ---------------------------------------
# AP_ROWS=1 when the no-twin-ledgers flag is up (set below, once per process,
# after the ledger library is sourced). Every read and write of a head's record
# goes through these, so the dispatch below is the same in both modes.
AP_ROWS=0
AP_TMP=""
KSTATE=""; KREC=""; AP_REC_WHY=""; AP_REC_LINE=""; AP_BODYF=""; AP_BODY_LOCAL=""

# ap_rec_get <key-path> <rk> -> rc 0 (KSTATE = the first line, KREC = the whole
# text) | 2 no record | 1 unreadable (AP_REC_WHY says why).
ap_rec_get() {
  local first w
  KSTATE=""; KREC=""; AP_REC_WHY=""
  if [ "$AP_ROWS" != 1 ]; then
    [ -f "$1" ] || return 2
    KREC=$(cat "$1" 2>/dev/null); KSTATE=$(head -1 "$1" 2>/dev/null)
    return 0
  fi
  # A key file still on disk is a record whose import did not land. Reading
  # past it would buy the review it records, so it is unreadable until it imports.
  if [ -e "$1" ]; then AP_REC_WHY="the legacy file $1 is still on disk (its import did not land)"; return 1; fi
  # A record whose row write failed is newer than the row: write it first.
  if [ -e "$1.pending" ]; then
    first=$(head -1 "$1.pending" 2>/dev/null); w="${first%% *}"; w="${w#status=}"
    if [ -n "$w" ] && lt_put_rc review_autopilot "$2" "$w" "$(cat "$1.pending")"; then
      rm -f "$1.pending"
      echo "$(STAMP) row review_autopilot $2 recorded the pending '$first' from $1.pending" >> "$LOG"
    else
      AP_REC_WHY="the pending record $1.pending did not write to its row yet"; return 1
    fi
  fi
  lt_row review_autopilot "$2"
  case "$?" in
    0) ;;
    2) return 2 ;;
    *) AP_REC_WHY="the ledger did not answer"; return 1 ;;
  esac
  first="${LT_DETAIL%%$'\n'*}"; w="${first%% *}"; w="${w#status=}"
  if [ -n "$first" ] && [ "$w" = "$LT_VAL" ]; then
    KSTATE="$first"; KREC="$LT_DETAIL"
  elif [ "$LT_VAL" = reviewed ] || [ "$LT_VAL" = skipped ]; then
    # A row the BH-1036 twin wrote: the status word and a short detail. Both
    # words are settled states, so it reads as one.
    KSTATE="$LT_VAL (row written before BH-4156) ${LT_DETAIL//$'\n'/ }"; KREC="$KSTATE"
  else
    KSTATE="$LT_VAL: ${LT_DETAIL//$'\n'/ }"; KREC="$KSTATE"
  fi
  return 0
}

# ap_rec_put <key-path> <rk> <text> -> rc 0 recorded | 1 not. The file mode
# writes <text> byte for byte, as every printf here always did.
ap_rec_put() {
  local st
  AP_REC_LINE="${3%%$'\n'*}"
  if [ "$AP_ROWS" != 1 ]; then printf '%s' "$3" > "$1"; return; fi
  st="${AP_REC_LINE%% *}"; st="${st#status=}"
  lt_put_rc review_autopilot "$2" "$st" "$3" && { rm -f "$1.pending"; return 0; }
  # The record is kept locally until a later tick writes it (ap_rec_get), so a
  # failed write after a billed call never reads as "no record".
  printf '%s' "$3" > "$1.pending" 2>/dev/null
  echo "$(STAMP) row review_autopilot $2 did NOT record '$AP_REC_LINE' (ledger write failed or refused) — kept in $1.pending" >> "$LOG"
  return 1
}

# ap_body_put <key-path> <rk> <comment> -> rc 0 cached | 1 not cached (write
# failed). In row mode a body the row refuses (over the ledger's detail limit,
# rc 3) or a failed row write is cached in the local `<key>.body` file instead,
# and AP_BODY_LOCAL says why. Either way AP_BODYF names a file holding the
# comment, for this tick's post.
ap_body_put() {
  local rc
  AP_BODY_LOCAL=""
  if [ "$AP_ROWS" != 1 ]; then printf '%s' "$3" > "$1.body"; AP_BODYF="$1.body"; return 0; fi
  AP_BODYF="$AP_TMP/body"
  printf '%s' "$3" > "$AP_BODYF" || return 1
  lt_put_rc review_autopilot_body "$2" cached "$3"; rc=$?
  [ "$rc" = 0 ] && { rm -f "$1.body"; return 0; }
  printf '%s' "$3" > "$1.body" 2>/dev/null && [ -s "$1.body" ] || { rm -f "$1.body"; return 1; }
  AP_BODYF="$1.body"
  if [ "$rc" = 3 ]; then AP_BODY_LOCAL="it is over the ledger's $LT_DETAIL_MAX-byte detail limit"; else AP_BODY_LOCAL="the ledger write failed"; fi
  return 0
}

# ap_body_get <key-path> <rk> -> rc 0 (AP_BODYF names the cached comment) |
# 2 gone | 1 unreadable. Row mode reads the row, then the local `<key>.body`
# cache (ap_body_put).
ap_body_get() {
  local rc
  AP_BODYF=""
  if [ "$AP_ROWS" != 1 ]; then [ -s "$1.body" ] || return 2; AP_BODYF="$1.body"; return 0; fi
  lt_row review_autopilot_body "$2"; rc=$?
  if [ "$rc" = 0 ] && [ "$LT_VAL" = cached ] && [ -n "$LT_DETAIL" ]; then
    AP_BODYF="$AP_TMP/body"
    printf '%s' "$LT_DETAIL" > "$AP_BODYF" || return 1
    return 0
  fi
  [ -s "$1.body" ] && { AP_BODYF="$1.body"; return 0; }
  case "$rc" in 0|2) return 2 ;; *) return 1 ;; esac
}

# ap_settle <key-path> <rk> <text> — a `reviewed` record: the head's record, the
# PR's newest-reviewed pointer (row mode, for the verdict replay; best effort),
# and the cached comment dropped. rc is the record write's.
ap_settle() {
  ap_rec_put "$1" "$2" "$3" || return 1
  if [ "$AP_ROWS" = 1 ]; then
    lt_put_rc review_autopilot_pr "${2%@*}" reviewed "${2##*@}
$3" || echo "$(STAMP) row review_autopilot_pr ${2%@*} did not record (a later head is reviewed, not replayed)" >> "$LOG"
    lt_put_rc review_autopilot_body "$2" dropped "-" || true
  fi
  rm -f "$1.body"
  return 0
}

# ap_import_legacy <owner/repo> — row mode only. A key or body file left by the
# file mode is PUT as its row, then removed. Body first: a key imported without
# its body would read "cached body is gone" and buy the review again. A body
# the row refuses (over the detail limit) stays as the local cache that
# ap_body_get reads, so its key still imports. A row
# that is already there wins (it is newer than any file), so a re-run imports
# nothing twice and a stale file never overwrites a row. A file that does not
# import stays, and its head reads unreadable (ap_rec_get) until it does.
ap_import_legacy() {
  local slug="$1" pre f name num h12 rk txt st rc
  pre="$STATE/${slug//\//-}-"
  for f in "$pre"*; do
    [ -f "$f" ] || continue
    case "$f" in *.body) continue ;; esac
    name="${f#"$pre"}"; num="${name%-*}"; h12="${name##*-}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    [[ "$h12" =~ ^[0-9a-f]{12}$ ]] || continue
    rk="$slug#$num@$h12"
    lt_row review_autopilot "$rk"; rc=$?
    if [ "$rc" = 1 ]; then
      echo "$(STAMP) import of legacy key $f stopped: the ledger did not answer (the file is kept)" >> "$LOG"
      return 1
    fi
    if [ "$rc" = 0 ]; then
      rm -f "$f"
      lt_row review_autopilot_body "$rk" && [ "$LT_VAL" = cached ] && rm -f "$f.body"
      echo "$(STAMP) legacy key $f removed: row review_autopilot $rk is already there and wins" >> "$LOG"
      continue
    fi
    if [ -f "$f.body" ]; then
      lt_put_rc review_autopilot_body "$rk" cached "$(cat "$f.body")"; rc=$?
      case "$rc" in
        0) rm -f "$f.body" ;;
        3) echo "$(STAMP) legacy body $f.body is over the ledger's $LT_DETAIL_MAX-byte detail limit: NOT cached as a row, kept as the local cache that ap_body_get reads" >> "$LOG" ;;
        *) echo "$(STAMP) import of legacy body $f.body failed (the files are kept; the head buys nothing until it imports)" >> "$LOG"; continue ;;
      esac
    fi
    txt=$(cat "$f" 2>/dev/null); st="${txt%%[ $'\n']*}"; st="${st#status=}"
    if [ -n "$st" ] && lt_put_rc review_autopilot "$rk" "$st" "$txt"; then
      rm -f "$f"
      echo "$(STAMP) imported legacy key $f as row review_autopilot $rk ($st)" >> "$LOG"
    else
      echo "$(STAMP) import of legacy key $f failed ('$(head -c 80 "$f" 2>/dev/null | tr -d '\n')'; the file is kept and the head buys nothing until it imports)" >> "$LOG"
    fi
  done
  return 0
}

# ap_cap_charge — one review charged to today's count: the count file, or in
# row mode the review_autopilot_cap row (the tick's own count moves even when
# the write fails, so this tick never undercounts; the failure is logged).
ap_cap_charge() {
  if [ "$AP_ROWS" != 1 ]; then echo $(( CNT + 1 )) > "$CNTF"; return 0; fi
  LCAP=$(( CNT + 1 ))
  [ "$CAP_UNREAD" = 0 ] && lt_put_rc review_autopilot_cap "$P $DAY" "$LCAP" && return 0
  # The count file folds into the row on the next tick (the higher wins), so a
  # failed write never reads low.
  echo "$LCAP" > "$CNTF" 2>/dev/null
  echo "$(STAMP) [$P] the daily count row review_autopilot_cap '$P $DAY' did NOT record $LCAP — kept in $CNTF" >> "$LOG"
  return 0
}

ap_post() {
  local slug="$1" num="$2" key="$3" verdict="$4" tries="$5"
  # Declared one per line: a `local a=$(cmd) b` swallows the rc and `set -u`
  # only notices the missing name much later (the mc_autopilot_verdict lesson).
  local h12
  local raw
  local n
  local authors
  local do_post=1
  local row_failed=0
  local rk
  local txt
  h12="${key##*-}"
  # The row key is the head, exactly as the filename is (BH-1036, BH-4156).
  # The comment to post is the file AP_BODYF names (ap_body_put/ap_body_get).
  rk="$slug#$num@$h12"
  # A RE-POST ASKS THE PR FIRST (BH-1066). `gh pr comment` can put the comment
  # up and still exit nonzero — a 502 reading the response, a token that died
  # after the write — and the rc alone cannot tell that from "it never landed".
  # Probed: three identical reviews on one PR in three ticks. So before posting
  # the same bytes again, read the PR's comments once and look for THIS head's
  # marker; if it is there the review was delivered, and the key settles with no
  # second comment. The FIRST post skips this: nothing can have landed yet, and
  # the happy path must not buy an extra REST call. REST, never GraphQL (BH-994).
  if [ "$tries" -gt 0 ]; then
    do_post=0
    if raw=$(gh api "repos/$slug/issues/$num/comments?per_page=100" 2>/dev/null); then
      # AND THE AUTHOR IS THE OTHER HALF OF THE BINDING (round-2 review of
      # #1093, confirmed by probe). This path DELETES a paid-for review, so the
      # marker alone cannot be the credential: anyone with comment rights on the
      # repo could paste `<!-- harness-review-autopilot <head12> -->` on a parked
      # head, watch the key settle to the lane's own verdict, and the review
      # nobody ever read would go in the bin. The comment must be written by a
      # login in harness_verdict_authors_json — the verdict-author set, which
      # leaves out the builders App that opens pool PRs (BH-1668) — normalised the way bin/lib/gh-pr-list.sh normalises it (`app/`
      # prefix and `[bot]` suffix stripped), because REST, GraphQL and git each
      # hand us a different one of the three. Exactly the binding
      # mc_autopilot_verdict applies to the same marker, for the same reason.
      # No callable list, or an empty one, is FAIL-CLOSED: the marker counts as
      # absent and the bytes are posted. A duplicate comment is cheap; a review
      # that was bought and then deleted on a stranger's say-so is not.
      authors=""
      type harness_verdict_authors_json >/dev/null 2>&1 && authors=$(harness_verdict_authors_json 2>/dev/null)
      case "${authors:-}" in ''|'[]') authors="" ;; esac
      n=0
      if [ -n "$authors" ]; then
        n=$(jq -r --arg m "<!-- harness-review-autopilot $h12 -->" --argjson a "$authors" \
              '($a | map(sub("^app/"; "") | sub("\\[bot\\]$"; ""))) as $set
               | [.[]? | select((.body // "") | contains($m))
                       | select(((.user.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $l
                                | $set | index($l))]
               | length' <<<"$raw" 2>/dev/null) || n=0
      else
        echo "$(STAMP) [$slug#$num] no harness author set is readable — cannot tell our own marker for @$h12 from a stranger's, so it counts as absent and the cached review is posted" >> "$LOG"
      fi
      if [ "${n:-0}" -gt 0 ]; then
        # The row comes BEFORE the `reviewed` line (BH-1951), exactly as on the
        # first post: a failed row leaves the key unsettled and counted, and
        # the next tick finds this same marker and retries the row alone.
        if ap_box_row "$slug" "$num" "$key" "$verdict" || [ "$?" = 3 ]; then
          printf -v txt 'reviewed %s verdict=%s\n%s' "$(STAMP)" "$verdict" "$(ap_sha_line "$key")"
          ap_settle "$key" "$rk" "$txt" || return 3
          echo "$(STAMP) [$slug#$num] this lane's own marker for @$h12 is already on the PR (an earlier post landed but exited nonzero, or its box row failed) — promoted to reviewed without posting" >> "$LOG"
          # rc 2, NOT 0: the key is settled but NOTHING went to the PR this tick,
          # and the caller must not log a post or beat a dispatched review for a
          # comment an earlier tick already paid to deliver (review of #1093).
          return 2
        fi
        row_failed=1
      else
        do_post=1
      fi
    else
      # Delivery delayed by an hour beats a duplicate: POST_TRIES still bounds
      # this, so a comments endpoint that stays down parks the head as before.
      echo "$(STAMP) [$slug#$num] could not read the PR's comments — not re-posting blind this tick" >> "$LOG"
    fi
  fi
  if [ "$do_post" = 1 ] && gh pr comment "$num" -R "$slug" --body-file "$AP_BODYF" >/dev/null 2>&1; then
    # The comment is up; the row goes BEFORE the `reviewed` line (BH-1951).
    if ap_box_row "$slug" "$num" "$key" "$verdict" || [ "$?" = 3 ]; then
      printf -v txt 'reviewed %s verdict=%s\n%s' "$(STAMP)" "$verdict" "$(ap_sha_line "$key")"
      # A record that did not land is rc 3: the comment is up, and the next
      # tick finds this head's marker and settles it with no second comment.
      ap_settle "$key" "$rk" "$txt" || return 3
      return 0
    fi
    row_failed=1
  fi
  tries=$(( tries + 1 ))
  if [ "$tries" -ge "$POST_TRIES" ]; then
    # The body is deliberately NOT removed: it is paid-for work, and an
    # operator posting it by hand is cheaper than buying it again. Record the
    # terminal state first, then tell someone it is there.
    printf -v txt 'unposted-terminal %s verdict=%s tries=%s\n' "$(STAMP)" "$verdict" "$tries"
    ap_rec_put "$key" "$rk" "$txt"
    ap_unposted_alert "$slug" "$num" "$key" "$h12" "$tries"
  else
    printf -v txt 'status=reviewed-unposted %s verdict=%s tries=%s\n' "$(STAMP)" "$verdict" "$tries"
    ap_rec_put "$key" "$rk" "$txt"
  fi
  [ "$row_failed" = 1 ] && return 3
  return 1
}

PROJECTS=$(awk '$1!~/^#/ && NF>=2 {print $1}' "$H/fleet.conf" 2>/dev/null | grep -vE "redirect" || true)
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# WHOSE PRs ARE OURS. The harness author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS) — since bin/gh-token.sh went live a harness PR is authored
# by the GitHub App (`app/cromford`) as often as by the PAT, and a
# hardcoded login matches only half of them (2026-09-14, project-5 #696/#697).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done

# shellcheck source=bin/lib/gh-budget.sh
[ -r "$H/bin/lib/gh-budget.sh" ] && . "$H/bin/lib/gh-budget.sh"

# The body drain's per-PR read goes through the REST seam, never a raw `gh api`
# (BH-994 / the gh-app ratchet): `gh_rest_pr_state` maps 2xx/404/network onto
# rc 0/44/75, so "the PR is closed" and "we could not look" stay different facts.
# shellcheck source=bin/lib/gh-rest.sh
for _P in "$(dirname "$0")/lib/gh-rest.sh" "$H/bin/lib/gh-rest.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done

# The ledger client, for the already-reviewed check below (BH-1024). A tree
# without it keeps the file-only dedupe, which is what this lane shipped with.
# THE ROW TWIN of state/review-autopilot/ (BH-1036) rides the same client. Both
# markers this lane keeps — "this head already carries a review" and "how many
# reviews has this project bought today" — live on ONE machine, so a wiped hub
# re-buys every review it has ever dispatched and starts the daily cap at
# zero. Behind the no-twin-ledgers flag each of them also lands as a `ledgers`
# row; the file stays the write-through cache for this cycle.
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# _vd_worker_404 for ap_box_row's "route not deployed" judgement (BH-1951).
# Missing, that 404 is read as a failed POST: held, never silently skipped.
# shellcheck source=bin/lib/verdicts.sh
[ -r "$H/bin/lib/verdicts.sh" ] && . "$H/bin/lib/verdicts.sh"
# shellcheck source=bin/lib/review-model.sh
[ -r "$H/bin/lib/review-model.sh" ] && . "$H/bin/lib/review-model.sh"
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$H/bin/lib/ledger-twin.sh" ] && . "$H/bin/lib/ledger-twin.sh"
# A box mid-sync can carry this script without the library; every verb then
# answers "no row", which is today's behaviour exactly.
declare -F lt_on >/dev/null 2>&1 || { lt_on() { return 1; }; lt_get() { return 1; }; lt_read() { LT_VAL=""; return 1; }; lt_seen() { return 1; }; lt_put() { return 0; }; }
# The record mode, once per process (BH-4156). The flag up = rows only.
if lt_on; then
  AP_ROWS=1
  AP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-autopilot.XXXXXX") || { echo "$(STAMP) row mode: mktemp failed — nothing done this tick" >> "$LOG"; exit 0; }
  trap 'rm -rf "$AP_TMP"' EXIT
fi

# IS THIS PROJECT'S REVIEWING PAUSED (BH-1684, BH-1672)? A pause used to be an
# env edit on one box that nobody could see and that never expired; it is now a
# row with a reason, an actor and an expiry, mirrored into state/pauses.json and
# read ONLY through bin/lib/pause.sh (pause_why in pause-rows.sh adds the
# reason and age for the log line, re-confirming each row through
# pause_active). A box mid-sync without the lib gets no-ops: nothing is ever
# paused, which is today exactly.
# shellcheck source=bin/lib/pause.sh
[ -r "$H/bin/lib/pause.sh" ] && . "$H/bin/lib/pause.sh"
# shellcheck source=bin/lib/pause-rows.sh
[ -r "$H/bin/lib/pause-rows.sh" ] && . "$H/bin/lib/pause-rows.sh"
declare -F pause_active >/dev/null 2>&1 || { pause_active() { return 1; }; pause_label() { return 0; }; pause_refresh() { return 0; }; pause_env_shapes() { return 0; }; }
declare -F pause_why >/dev/null 2>&1 || pause_why() { return 0; }
# Once per tick, before any project is judged, so every project in this tick
# reads the same cache. A failed refresh keeps the last cache (#1683).
pause_refresh || true


for P in $PROJECTS; do
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null || true)
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue

  # >>> project hold
  # IS THIS PROJECT HELD (BH-1465)? Above the budget guard, above
  # gh_repo_use_token and above harness_pr_list, so a held project costs no
  # GitHub budget and buys no review — which is the point: the rate limit it
  # would have spent goes to the projects that are still running. A box
  # mid-sync without the gate library runs exactly as today.
  if command -v lane_project_held >/dev/null 2>&1 && lane_project_held review-autopilot "$P"; then
    echo "$(STAMP) $P: held — flags/$LANE_HELD_FLAG is set, so no PR was listed and no review was bought for it this tick" >> "$LOG"
    continue
  fi
  # <<< project hold

  # A REVIEWS PAUSE (BH-1684) skips the project here, below the hold and ABOVE
  # the budget guard, gh_repo_use_token and the PR list: a paused project spends
  # no GitHub budget and buys no review, and writes no state, so every head it
  # would have reviewed is simply offered again once the pause ends or expires.
  # The one TICK line carries the reason and age so the log answers "why did
  # reviews stop" without a trip to the console. With a fleet row and a project
  # row both live, the one expiring last is the one that is really holding it.
  if pause_active "$P" reviews; then
    echo "$(STAMP) TICK $P $(pause_label "$P")$(pause_why "$P" reviews)" >> "$LOG"
    continue
  fi
  # #1683's env shape for this lane's cap (env:review-cap=N) is REPORTED here
  # and nothing more (BH-1672): the cap below still does the capping, so a
  # reader of the log sees the knob that is throttling reviews by name.
  PLABEL=$(pause_label "$P")
  for PSHAPE in $(pause_env_shapes 2>/dev/null); do
    case "$PSHAPE" in env:review-cap=*) ;; *) continue ;; esac
    case "$PLABEL" in *"$PSHAPE"*) continue ;; esac
    echo "$(STAMP) TICK $P PAUSED($PSHAPE) cap=$CAP — reported only, the daily cap still applies" >> "$LOG"
  done

  # GitHub rate-limit guard: skip this project when the shared budget is low.
  # The library writes exactly one budget-low line per (lane, fetched_at).
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low review-autopilot; then
    continue
  fi

  # Deterministic selection: non-draft, harness-authored, older than 12h.
  # A repo the token cannot list is an ALERT, never an empty loop (2026-09-12).
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" || { gh_repo_invisible_alert review-autopilot "$SLUG" "$P: review autopilot skipped, no PR seen"; continue; }
  fi
  RAW_PRS=$(harness_pr_list "$SLUG" open number,createdAt,headRefOid,title,isDraft,baseRefName 2>/dev/null) || RAW_PRS=""
  PRS=$(jq -r --argjson cutoff "$CUTOFF" \
          '.[] | select((.isDraft | not) and ((.createdAt | fromdateiso8601) < $cutoff))
           | [.number, .headRefOid, (.baseRefName // "main"), .title] | @tsv' <<<"$RAW_PRS" 2>/dev/null) || true

  # >>> body drain — the cached review outlives the sweep, not its PR.
  # The sweep above no longer touches a `.body`, so something has to. The PR
  # being gone (merged, closed) is the honest end of a cached review's life.
  #
  # THE DELETE IS EARNED BY A POSITIVE READ, NEVER BY ABSENCE FROM A LIST
  # (head-bound review of #1093). `harness_pr_list` can return rc 0 and a SHORT
  # list: its REST rung walks a bounded number of pages of ALL open PRs,
  # newest-first, and only LOGS `cap_reached`; its `gh pr list` fallback returns
  # rc 0 when one author's list succeeded and another's failed (the BH-847
  # rate-limit shape). Both drop the OLDEST harness PRs — exactly the long-lived
  # heads that go `unposted-terminal` and own a paid-for body. So the list is
  # only ever a free "still open, skip" short-circuit; anything it does not
  # carry is ASKED, and only `state` coming back not-open deletes. A read that
  # failed proves nothing and keeps the body (D12). The key is left alone: it is
  # terminal state and the 90-day sweep owns it.
  [ "$AP_ROWS" = 1 ] && ap_import_legacy "$SLUG"
  OPEN_NUMS=""
  [ -n "$RAW_PRS" ] && OPEN_NUMS=$(jq -r '.[].number' <<<"$RAW_PRS" 2>/dev/null || echo "")
  for BODYF in "$STATE/${SLUG//\//-}"-*.body; do
    [ -e "$BODYF" ] || continue
    # Strip the KNOWN slug prefix before splitting, so an owner or repo with
    # dashes in it cannot make the PR number come out wrong.
    BNAME="${BODYF##*/}"; BNAME="${BNAME#"${SLUG//\//-}-"}"; BNAME="${BNAME%.body}"
    BNUM="${BNAME%-*}"
    case "$BNUM" in ''|*[!0-9]*) continue ;; esac
    [ -n "$OPEN_NUMS" ] && grep -qxF "$BNUM" <<<"$OPEN_NUMS" && continue
    command -v gh_rest_pr_state_var >/dev/null 2>&1 || continue
    # rc 0 with a state is the only thing that deletes. 44 (the token cannot see
    # it) and 75 (network, rate limit, unparseable) are "we could not look".
    # BH-1485: the `_var` variant — the capture was a subshell and the two
    # variables the library sets never reached this loop.
    PSTATE=""
    gh_rest_pr_state_var PSTATE "$SLUG" "$BNUM" 2>/dev/null || continue
    [ -n "$PSTATE" ] && [ "$PSTATE" != open ] || continue
    rm -f "$BODYF"
    echo "$(STAMP) [$P] #$BNUM is $PSTATE, not open — dropped the cached review body $BODYF" >> "$LOG"
  done

  [ -n "$PRS" ] || continue

  CNTF="$STATE/count-$P-$DAY"
  # THE CAP ROW IS READ ONCE PER PROJECT PER TICK (BH-1036 r1, I3), not once per
  # open PR. It cannot change inside a tick except by this lane's own writes,
  # and those move LCAP (ap_cap_charge) in the same breath — so a per-PR read bought nothing
  # and multiplied the cost of a hung worker by the size of the PR list.
  # Row mode (BH-4156): the row IS the count. An unreadable row is a count
  # nobody knows, so with a cap set nothing is bought for this project this
  # tick. A leftover count file folds into the row (the higher wins) and goes.
  LCAP=""; CAP_UNREAD=0
  if [ "$AP_ROWS" = 1 ]; then
    lt_read review_autopilot_cap "$P $DAY"
    case "$?" in
      0) LCAP="$LT_VAL"; case "$LCAP" in ''|*[!0-9]*) LCAP=""; CAP_UNREAD=1 ;; esac ;;
      2) LCAP=0 ;;
      *) CAP_UNREAD=1 ;;
    esac
    if [ -f "$CNTF" ]; then
      FCNT=$(cat "$CNTF" 2>/dev/null)
      case "$FCNT" in ''|*[!0-9]*) FCNT=0 ;; esac
      if [ "$CAP_UNREAD" = 1 ]; then :   # the file stays until the row can be read
      elif [ "$FCNT" -le "$LCAP" ]; then rm -f "$CNTF"
      elif lt_put_rc review_autopilot_cap "$P $DAY" "$FCNT"; then LCAP="$FCNT"; rm -f "$CNTF"
      else CAP_UNREAD=1
      fi
    fi
  fi
  while IFS=$'\t' read -r NUM SHA BASEREF TITLE; do
    [ -n "$NUM" ] && [ -n "$SHA" ] || continue
    HEAD12="${SHA:0:12}"
    KEY="$STATE/${SLUG//\//-}-$NUM-$HEAD12"
    RK="$SLUG#$NUM@$HEAD12"
    # THE DEDUP RUNS BEFORE THE SPEND, and it answers three things, not two:
    # already done, already PAID FOR but not delivered, or genuinely new. In
    # row mode an unreadable row is a fourth answer: buy nothing, post nothing.
    ap_rec_get "$KEY" "$RK"; REC_RC=$?
    if [ "$REC_RC" = 1 ]; then
      echo "$(STAMP) [$P] #$NUM @$HEAD12 row review_autopilot $RK is unreadable ($AP_REC_WHY) — not reviewing and not posting for this head this tick" >> "$LOG"
      continue
    fi
    if [ "$REC_RC" = 0 ]; then
      case "$KSTATE" in
        status=reviewed-unposted*)
          KVERDICT=$(sed -nE 's/^status=reviewed-unposted .* verdict=([A-Z-]+) tries=[0-9]+$/\1/p' <<<"$KSTATE")
          KTRIES=$(sed -nE 's/^status=reviewed-unposted .* tries=([0-9]+)$/\1/p' <<<"$KSTATE")
          ap_body_get "$KEY" "$RK"; BODY_RC=$?
          if [ "$BODY_RC" = 1 ]; then
            echo "$(STAMP) [$P] #$NUM @$HEAD12 the cached body row review_autopilot_body $RK is unreadable — not reviewing and not posting for this head this tick" >> "$LOG"
            continue
          fi
          if [ "$BODY_RC" = 0 ]; then
            ap_post "$SLUG" "$NUM" "$KEY" "${KVERDICT:-UNPARSED}" "${KTRIES:-0}"; AP_RC=$?
            case "$AP_RC" in
              0)
                echo "$(STAMP) [$P] #$NUM @$HEAD12 cached review posted on retry -> ${KVERDICT:-UNPARSED} (no model call) https://github.com/$SLUG/pull/$NUM" >> "$LOG"
                DISPATCHED="$DISPATCHED
$SLUG#$NUM -> ${KVERDICT:-UNPARSED}" ;;
              2)
                echo "$(STAMP) [$P] #$NUM @$HEAD12 cached review was already on the PR — settled without posting -> ${KVERDICT:-UNPARSED} (nothing sent this tick) https://github.com/$SLUG/pull/$NUM" >> "$LOG" ;;
              3)
                echo "$(STAMP) [$P] #$NUM @$HEAD12 the review is on the PR but its box verdict row or its record did not record ($AP_REC_LINE) — the next tick retries the row, no model call" >> "$LOG" ;;
              *)
                echo "$(STAMP) [$P] #$NUM @$HEAD12 cached review still would not post ($AP_REC_LINE)" >> "$LOG" ;;
            esac
            continue
          fi
          # The cache is gone (the PR-closed drain or a hand delete removed it,
          # or neither the row nor the local file could be written): there
          # is nothing left to post, so this head buys one review
          # again rather than sitting undelivered for ever.
          echo "$(STAMP) [$P] #$NUM @$HEAD12 was reviewed-unposted but the cached body is gone — reviewing again" >> "$LOG"
          ;;
        "empty "*"n=1") : ;;                     # one retry of an empty answer, then terminal
        "failed "*) : ;;                         # a call that died: retry until FAIL_TRIES
        reviewed\ *|skipped\ *|empty-terminal\ *|unposted-terminal\ *|failed-terminal\ *)
          continue ;;                            # settled: nothing to buy for this head
        *)
          # THE STATES ARE ENUMERATED, and anything else is LOUD (BH-1066). A
          # zero-byte or corrupt key used to fall into `*) continue` with no log
          # line, which disabled the lane for that head for ever and looked
          # exactly like "already reviewed". It still buys nothing — an
          # unreadable guard is not permission to spend — but now it says so
          # once per tick, with the path an operator deletes.
          AP_WHERE="key $KEY"; [ "$AP_ROWS" = 1 ] && AP_WHERE="row review_autopilot $RK"
          echo "$(STAMP) [$P] #$NUM @$HEAD12 $AP_WHERE has unreadable state ('$(head -c 80 < <(printf '%s' "$KSTATE") | tr -d '\n')') — not reviewing and not posting for this head until it is fixed or removed" >> "$LOG"
          continue ;;
      esac
    fi

    # >>> autopilot ledger skip (BH-1024, BH-3930; tests/verdict-single-home.bh-1024-test.sh and tests/review-autopilot-dedupe.bh-3930-test.sh drive this block)
    # The same question the file read below asks, asked of the ledger first — so
    # a review bought on ANOTHER box or by ANOTHER lane counts, which a file on
    # this one never could. Since BH-3930 any verdict bound to this exact head
    # stands the lane down (review-prs, mc-rereview, the lead, a BLOCK as much as
    # an APPROVE), except the builder's own: --except-builder keeps a harness
    # build's verdict from covering, because reading the adversarial second
    # opinion on harness PRs is the whole reason this lane exists. The old
    # verdict_single_home gate and source=review-prs filter are gone;
    # REVIEW_DEDUPE=0 is the kill switch. Until the review_bought reads land
    # (a BH-3930 sibling) the lib answers rc 2 and this block never skips.
    # rc 1 (unreadable) is logged; rc 1 and rc 2 fall through to the file and
    # then to the review, exactly as before.
    if command -v review_bought >/dev/null 2>&1 && command -v review_dedupe_on >/dev/null 2>&1 && review_dedupe_on; then
      review_bought "$SLUG" "$NUM" "$SHA" --except-builder >/dev/null 2>&1; RB_RC=$?
      case "$RB_RC" in
        0) RB_S=$(printf '%s' "$RB_SOURCE" | tr -cd 'A-Za-z0-9._-'); RB_W=$(printf '%s' "$RB_WORD" | tr -cd 'A-Z-')
           echo "$(STAMP) [$P] #$NUM @$HEAD12 already reviewed: $RB_S verdict $RB_W is the ledger verdict bound to this head — standing down" >> "$LOG"
           printf -v AP_TXT 'skipped %s: %s verdict %s bound to this head (ledger)\n' "$(STAMP)" "$RB_S" "$RB_W"
           ap_rec_put "$KEY" "$RK" "$AP_TXT"
           review_skip_log "$LOG" "$SLUG" "$NUM" "$SHA" review-autopilot
           continue ;;
        1) echo "$(STAMP) [$P] #$NUM @$HEAD12 review_dedupe unreadable (review_bought rc 1) — falling through to the file check" >> "$LOG" ;;
      esac
    fi
    # <<< autopilot ledger skip

    # review-prs.sh may have covered this head (a harness PR it did not classify
    # as harness-generated). One review per sha, whoever wrote it.
    XSHA=$(jq -r --arg n "$NUM" '.[$n].sha // ""' "$H/state/$P.pr-reviews.json" 2>/dev/null || echo "")
    if [ "$XSHA" = "$SHA" ]; then
      echo "$(STAMP) [$P] #$NUM @$HEAD12 already reviewed by review-prs — standing down" >> "$LOG"
      printf -v AP_TXT 'skipped %s: review-prs.sh reviewed this head\n' "$(STAMP)"
      ap_rec_put "$KEY" "$RK" "$AP_TXT"
      continue
    fi

    # >>> autopilot verdict replay (BH-2310; tests/review-autopilot-replay.bh-2310-test.sh drives this block)
    # A HEAD THAT MOVED WITHOUT ITS PATCH CHANGING is the change this lane already
    # judged: a fix round that only merged main, or a rebase that carried the
    # patch across byte for byte. The newest `reviewed` key this PR has at another
    # head names that head (12 hex, which resolves locally: in the main-merge case
    # it is an ancestor of the fetched new head). bin/lib/patch-same.sh proves the
    # same patch from the commits, with no model. The verdict is replayed onto
    # this head's key in the exact `reviewed <stamp> verdict=<V>` shape, with a
    # box row for this head (which mc_autopilot_verdict reads), and nothing is
    # bought, counted or posted.
    # Anything it cannot prove falls through to the review below, as before.
    # Row mode (BH-4156) reads the PR's newest `reviewed` head from its
    # review_autopilot_pr row (head12, then the record) instead of the files.
    AP_PREV12=""; AP_PREVREC=""
    if command -v patch_same >/dev/null 2>&1 && [ -d "${REPOS_ROOT:-/root/repos}/$P/.git" ]; then
      if [ "$AP_ROWS" = 1 ]; then
        if lt_row review_autopilot_pr "$SLUG#$NUM"; then
          AP_L="${LT_DETAIL#*$'\n'}"
          if [[ "${LT_DETAIL%%$'\n'*}" =~ ^[0-9a-f]{12}$ ]] && [ "${LT_DETAIL%%$'\n'*}" != "$HEAD12" ] \
             && [[ "${AP_L%%$'\n'*}" =~ ^reviewed\ .*\ verdict=[A-Z-]+$ ]]; then
            AP_PREV12="${LT_DETAIL%%$'\n'*}"; AP_PREVREC="$AP_L"
          fi
        fi
      else
        for AP_F in $(ls -t "$STATE/${SLUG//\//-}-$NUM-"* 2>/dev/null); do
          case "$AP_F" in "$KEY"|*.body|*.pending) continue ;; esac
          AP_L=$(head -1 "$AP_F" 2>/dev/null)
          if [[ "$AP_L" =~ ^reviewed\ .*\ verdict=[A-Z-]+$ ]]; then AP_PREV12="${AP_F##*-}"; AP_PREVREC=$(cat "$AP_F" 2>/dev/null); break; fi
        done
      fi
    fi
    if [ -n "$AP_PREV12" ]; then
      AP_REPO="${REPOS_ROOT:-/root/repos}/$P"
      AP_LINE="${AP_PREVREC%%$'\n'*}"
      # The full reviewed sha when the key recorded one (ap_sha_line); an older key
      # has only its 12-hex name, which resolves locally or fails closed.
      AP_PREVSHA=$(sed -n 's/^sha=\([0-9a-f]\{40\}\)$/\1/p' <<<"$AP_PREVREC" 2>/dev/null | head -1)
      [ "${AP_PREVSHA:0:12}" = "$AP_PREV12" ] || AP_PREVSHA=""
      if patch_same_fetch "$AP_REPO" "$AP_PREVSHA" "$SHA" \
         && AP_HOW=$(patch_same "$AP_REPO" origin/main "${AP_PREVSHA:-$AP_PREV12}" "$SHA"); then
        AP_V="${AP_LINE##*verdict=}"
        # The replayed verdict gets its own box row on THIS head first (BH-1951).
        # A failed row writes no key: the next tick replays again, for free, and
        # never falls through to the paid review below.
        ap_box_row "$SLUG" "$NUM" "$KEY" "$AP_V" "replayed_from=$AP_PREV12"; AP_ROW=$?
        if [ "$AP_ROW" = 1 ]; then
          echo "$(STAMP) [$P] #$NUM @$HEAD12 verdict replay from $AP_PREV12 ($AP_V) held: its box row did not record — no key written, no review bought; the next tick replays again" >> "$LOG"
          continue
        fi
        printf -v AP_TXT 'reviewed %s verdict=%s\nreplayed_from=%s how=%s\nsha=%s\n' "$(STAMP)" "$AP_V" "$AP_PREV12" "$AP_HOW" "$SHA"
        ap_settle "$KEY" "$RK" "$AP_TXT"
        echo "$(STAMP) [$P] #$NUM @$HEAD12 verdict REPLAYED from $AP_PREV12 ($AP_V): own patch unchanged ($AP_HOW) — no review bought, no post, cap unchanged" >> "$LOG"
        command -v review_saving_event >/dev/null 2>&1 \
          && review_saving_event "$P" review-autopilot "$SLUG" "$NUM" "$SHA" REUSED "from=$AP_PREV12 to=${SHA:0:12} how=$AP_HOW" || true
        continue
      fi
    fi
    # <<< autopilot verdict replay

    # THE CAP SURVIVES A WIPE TOO, or a fresh box buys a second day's worth of
    # reviews under a cap that reads zero: in row mode the count is the row
    # (BH-4156), and a row nobody could read buys nothing while a cap is set.
    if [ "$AP_ROWS" = 1 ]; then
      if [ "$CAP_UNREAD" = 1 ] && [ "$CAP" -gt 0 ]; then
        echo "$(STAMP) [$P] the daily count row review_autopilot_cap '$P $DAY' is unreadable with a cap of $CAP — #$NUM and any remaining PRs buy nothing this tick" >> "$LOG"
        break
      fi
      CNT="${LCAP:-0}"
    else
      CNT=$(cat "$CNTF" 2>/dev/null || echo 0)
    fi
    if [ "$CAP" -gt 0 ] && [ "${CNT:-0}" -ge "$CAP" ]; then
      echo "$(STAMP) [$P] daily review cap $CAP reached — #$NUM and any remaining PRs wait for tomorrow" >> "$LOG"
      break
    fi

    DIFF_FILE="$STATE/diff-${SLUG##*/}-$NUM.txt"
    gh pr diff "$NUM" -R "$SLUG" > "$DIFF_FILE" 2>/dev/null || true
    DSIZE=$(stat -c%s "$DIFF_FILE" 2>/dev/null || echo 0)
    [ "${DSIZE:-0}" -gt 0 ] || { echo "$(STAMP) [$P] #$NUM: empty diff from gh — skipping this tick" >> "$LOG"; rm -f "$DIFF_FILE"; continue; }
    DIFF=$(head -c "$MAXDIFF" "$DIFF_FILE")
    if [ "$DSIZE" -gt "$MAXDIFF" ]; then
      FILES=$(gh pr diff "$NUM" -R "$SLUG" --name-only 2>/dev/null | head -300)
      DIFF="[diff too large (${DSIZE}B) — reviewing file list + first ${MAXDIFF}B. Say so in your summary and keep the verdict honest about what you could not read.]

FILES CHANGED:
$FILES

FIRST ${MAXDIFF}B OF DIFF:
$DIFF"
    fi
    BODY=$(gh pr view "$NUM" -R "$SLUG" --json body -q .body 2>/dev/null | head -c 4000)
    CISTATE=$(gh pr view "$NUM" -R "$SLUG" --json mergeable,mergeStateStatus,statusCheckRollup \
      -q '"mergeable=\(.mergeable) mergeState=\(.mergeStateStatus) checks=" + ([.statusCheckRollup[]? | "\(.name // .context)=\(.conclusion // .state)"] | join(", "))' 2>/dev/null | head -c 2000)
    # E2E policy (the operator 2026-09-12, docs/E2E-POLICY.md point 6): whether this
    # diff touches an E2E path decides whether a red E2E / Production-QA /
    # deployment-targeted check is a blocker or a note. Computed here, not by
    # the model: bin/lib/e2e-paths.sh is the one definition. Fail closed —
    # no lib or no file list, and every red check is a blocker as before.
    E2E_NOTE="E2E-CLASS CHECKS ARE BLOCKING for this diff: the changed-file list was unavailable, so every red check counts."
    if [ -r "$H/bin/lib/e2e-paths.sh" ]; then # shellcheck source=bin/lib/e2e-paths.sh
      . "$H/bin/lib/e2e-paths.sh"
      if E2E_FILES=$(gh pr diff "$NUM" -R "$SLUG" --name-only 2>/dev/null) && [ -n "$E2E_FILES" ]; then
        if e2e_path_hit <<<"$E2E_FILES"; then
          E2E_NOTE="This diff TOUCHES an E2E path ($(grep -E "$E2E_PATH_RE" <<<"$E2E_FILES" | head -3 | tr '\n' ' ')...): a red E2E / Production QA / deployment-targeted check is a BLOCKING finding."
        else
          E2E_NOTE="This diff touches NO E2E path (app/ pages/ components/ ui/ middleware.* proxy.* route handlers, auth, e2e specs, package.json, next.config.*, global css): E2E / Production QA / deployment-targeted checks are ADVISORY — mention a red one as a note with its name, never BLOCK on it. Typecheck, lint, unit and harness-gate checks stay blocking."
        fi
      fi
    fi

    # SKIPPED TEST JOBS ARE NOT A FINDING (BH-5795). 22 of this lane's BLOCKs
    # (#4189..#5395) said "no suite ran on this head". On a base of main that is
    # the design: the merge-queue batch runs the PR's impact set on the tree that
    # lands. On another base, bin/ci-plan.sh plans the impact set against main
    # and the lead-review enqueue holds the head until a run starts. Decided
    # here, not by the model; ap_skip_guard below backs it up.
    if [ "${BASEREF:-main}" = main ]; then
      SKIP_NOTE="This PR's base is main. Test jobs that read SKIPPED here (CI plan, Tests traced shards, Pure-logic gate fixtures, Tests cannot touch a real harness, Mission Control SPA, Jobs worker) are skipped BY DESIGN: the merge-queue batch runs this PR's impact set on the tree that lands and merges nothing red. A skipped test job is NEVER a blocking finding. At most, add one note that the queue runs them. A FAILED check is still blocking."
    else
      SKIP_NOTE="This PR's base is $BASEREF, not main. CI plans this head's impact set against main on every push (BH-5795), and the lead-review enqueue starts a run for a head whose test jobs were skipped. A SKIPPED test job alone is not proof of a defect, but nothing tests a merge into this base: when no test job ran on this head, say so and judge whether the PR can land untested. A FAILED check is still blocking."
    fi
    CISTATE_RAW="$CISTATE"
    CISTATE=$(printf '%s' "$CISTATE" | sed 's/=SKIPPED/=SKIPPED (not a finding: see the skipped-test rule)/g')
    PROMPT="Adversarial review of a HARNESS-BUILT PR on $SLUG (#$NUM): \"$TITLE\".
This PR has been open more than 12 hours waiting for a merge owner. Your review is what a human reads before deciding. Judge the diff below; you may read files for context, but do NOT run installs or builds — this is a static review and you must say so in one clause.

YOUR OUTPUT IS POSTED VERBATIM AS A PR COMMENT. Write it for the human who will merge (or not): no preamble, no restating the PR body, no inventory of everything that checked out. A finding is what breaks, where (file:line), and the fix. Cut any sentence that does not change what the reader does next.

Judge, in this order:
1. Correctness vs the ticket's intent — does the diff do what the PR body says was asked, with the edge cases handled? Silently deferred load-bearing work is a finding, not a footnote.
2. The iron laws (read /root/.claude/CLAUDE.md): additive-only schema; RLS enabled on every new Supabase table; indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table; DB-driven config, never hardcoded (including no hardcoded claude-* model strings); no native browser dialogs; sortable headers and no dead rows on any new table/list UI, drill-down that reaches the atomic record; idempotent / exactly-once writes wherever money or records move; dedup-before-spend on metered or billable APIs (a PERSISTED 'have we already paid for this?' check BEFORE the billable call, keyed on a stable fingerprint of the input rather than a presigned/tokenized URL, with 'succeeded but returned nothing' treated as billed and TERMINAL); De-AI voice on AI-written human-facing text; mobile-responsive UI; no VERCEL_URL self-fetch; CRON_SECRET compared with .trim(); every new env var listed for all environments. PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content.
3. Test integrity — new behavior with no test in a repo that has test infra is a blocking finding, and any weakened, skipped, or deleted existing test is an instant BLOCK unless the PR body argues why the test was wrong.
4. Security — injection, authz/IDOR, secrets in code, fail-open access checks.
5. Merge readiness from the CI/mergeable state below: red checks or a dirty merge state belong in the verdict — subject to the E2E rule and the skipped-test rule under it.

CI / mergeable state (fetched deterministically, trust it over your reading of the diff):
$CISTATE
E2E rule for THIS diff (fleet policy docs/E2E-POLICY.md, decided deterministically): $E2E_NOTE
Skipped-test rule for THIS PR (BH-5795, decided deterministically): $SKIP_NOTE

PR body:
$BODY

DIFF:
$DIFF

End your output with EXACTLY this final line and nothing after it:
VERDICT: MERGE|MERGE-WITH-NOTES|BLOCK — <one-line reason>
(pick ONE of the three words; MERGE = land as-is, MERGE-WITH-NOTES = land but the notes are real follow-ups, BLOCK = do not land until a finding is fixed.)"

    # NO ROUTE, NO CALL (BH-1510.1): the same "nothing called" answer as the
    # 74..79 arm below — no key, no cap charge, no comment; retried next tick.
    RA_MODEL=""
    command -v review_model >/dev/null 2>&1 && RA_MODEL=$(review_model "$H" "$P")
    if [ -z "$RA_MODEL" ]; then
      echo "$(STAMP) [$P] #$NUM @$HEAD12 no model route for build.review (and no REVIEW_MODEL) — nothing called, nothing posted, no key written, cap unchanged; retries next tick" >> "$LOG"
      rm -f "$DIFF_FILE"
      continue
    fi
    # >>> autopilot trivial measure (BH-2545; tests/review-saving.bh-2545-test.sh drives this block)
    # Classified and recorded only. RA_MODEL is never changed here: this lane's
    # MERGE word is landed by the conductor with no tier to cap, so a cheap-model
    # read must not be the one it lands on. Any trivial class is TRIVIAL_SHADOW.
    if command -v review_trivial_pick >/dev/null 2>&1; then
      review_trivial_pick "$DIFF_FILE" "$P" "$RA_MODEL"
      if [ -n "$RT_ACTION" ]; then
        echo "$(STAMP) [$P] #$NUM @$HEAD12 trivial $RT_CLASS $RT_LINES lines: shadow (autopilot is never routed) model=$RA_MODEL" >> "$LOG"
        review_saving_event "$P" review-autopilot "$SLUG" "$NUM" "$SHA" TRIVIAL_SHADOW "class=$RT_CLASS lines=$RT_LINES model=$RA_MODEL" || true
      fi
    fi
    # <<< autopilot trivial measure
    OUT_FILE=$(mktemp); PROMPT_FILE=$(mktemp)
    printf '%s' "$PROMPT" > "$PROMPT_FILE"
    # Prompt rides @file, never argv: with the diff inline it clears 128KB and a
    # single argv element that big fails execve with E2BIG (agent-call header).
    # K3: the call-guard key is the shared per-head fp review:<slug>#<n>@<sha>
    # (bin/lib/review-bought.sh) under stage review-head at K=1, so every review
    # lane on this head shares one claim (BH-3930). The positional stage stays
    # `review`: it is the cost row's stage and the model route. A refusal is
    # rc 74, which the arm below already treats as "nothing called".
    AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$(review_fp "$SLUG" "$NUM" "$SHA")" \
    "$H/bin/agent-call.sh" review "$P" "$RA_MODEL" 3600 "$OUT_FILE" "@$PROMPT_FILE" </dev/null >/dev/null 2>&1
    AC_RC=$?
    REVIEW=$(cat "$OUT_FILE" 2>/dev/null)
    # The model that ACTUALLY wrote this review, for the footer (BH-1625, #1639
    # review): the first line of <out>.model, which bin/agent-call.sh writes
    # from the lane that served — the same source merge-conductor's
    # hb_model_label reads. Read before the sidecars are removed below.
    RA_SERVED=$(head -1 "$OUT_FILE.model" 2>/dev/null | tr -cd 'A-Za-z0-9._:/@+-' | head -c 120)
    [ -n "$RA_SERVED" ] || RA_SERVED="model unrecorded"
    # The first line, for the log only — it is what tells rc 79's two meanings
    # apart (PROMPT_TOO_LARGE vs a cliff-routed call) and it is never posted.
    AC_MARK=$(head -c 160 "$OUT_FILE" 2>/dev/null | tr '\n' ' ')
    rm -f "$OUT_FILE" "$OUT_FILE.runner" "$OUT_FILE.model" "$OUT_FILE.prompt" "$OUT_FILE.promptsha" "$PROMPT_FILE" "$DIFF_FILE"

    # THE RC IS THE FIRST FACT ABOUT THE CALL (BH-1066), and it decides all
    # three of what follows: whether the cap is charged, what the key says, and
    # whether anything is posted at all. Counting the SPEND rather than the
    # success is still right — but only for a call that happened.
    case "$AC_RC" in
      74|75|76|77|78|79)
        # bin/agent-call.sh's own contract: nothing was called and nothing was
        # billed (the lane's own gate / lock / no account with headroom / the
        # hub refusing build work / a no-tools refusal / an argv-only or
        # cliff-routed refusal). $OUT holds a one-line marker, not a review.
        # Write NOTHING — no key, no cap charge, no comment — so the next tick
        # buys what was never bought.
        #
        # 74 IS THE GATE'S OWN (BH-1141). Without it here, an operator setting
        # LLM_LANE_ENABLED=0 on review for one afternoon would spend this
        # lane's daily cap on calls nobody made and write a terminal key for
        # every PR it touched — none of them retried when the lane came back.
        echo "$(STAMP) [$P] #$NUM @$HEAD12 agent-call returned before billing (rc=$AC_RC: ${AC_MARK:-no marker}) — nothing called, nothing posted, no key written, cap unchanged; retries next tick" >> "$LOG"
        continue ;;
      0)
        # The count moves on EVERY path that charges — an rc-0 review here, a
        # call that died below. A count that only moved on the happy path would
        # read low, and a low cap is what buys the 41st review (BH-1036).
        ap_cap_charge ;;
      *)
        # It DIED: billed, or billed in a way we cannot see from here. Count it,
        # and never post what is in the out file — a partial review, or a
        # `CONTEXT KILL:` truncation, is a verdict on code nobody finished
        # reading. Bounded like every other retry on this lane.
        ap_cap_charge
        # ONE COUNTER FOR BOTH NON-SUCCESS TRACKS (head-bound review of #1093).
        # Read separately, `empty` and `failed` reset each other, so a head that
        # alternates rc!=0 and rc 0/empty cycles n=1 for ever — billed every
        # tick, never terminal, unbounded at the default cap of 0.
        FN=$(ap_attempts "$KREC")
        FN=$(( FN + 1 ))
        if [ "$FN" -ge "$FAIL_TRIES" ]; then
          printf -v AP_TXT 'failed-terminal %s n=%s rc=%s\n' "$(STAMP)" "$FN" "$AC_RC"; ap_rec_put "$KEY" "$RK" "$AP_TXT"
          echo "$(STAMP) [$P] #$NUM @$HEAD12 the review call died (rc=$AC_RC) $FN times — terminal, no further calls for this head (spend counted: $(( CNT + 1 ))/$CAP)" >> "$LOG"
        else
          printf -v AP_TXT 'failed %s n=%s rc=%s\n' "$(STAMP)" "$FN" "$AC_RC"; ap_rec_put "$KEY" "$RK" "$AP_TXT"
          echo "$(STAMP) [$P] #$NUM @$HEAD12 the review call died (rc=$AC_RC) — attempt $FN of $FAIL_TRIES, nothing posted (spend counted: $(( CNT + 1 ))/$CAP)" >> "$LOG"
        fi
        continue ;;
    esac

    if [ -z "$REVIEW" ]; then
      # BILLED, AND NOT A FAILURE TO RETRY FOR EVER. One more tick may catch a
      # transient; a second empty answer is the vendor saying there is nothing
      # here, and it is terminal. Writing nothing is what made this hourly.
      EN=$(ap_attempts "$KREC")     # shared with the failed track, see above
      EN=$(( EN + 1 ))
      if [ "$EN" -ge 2 ]; then
        printf -v AP_TXT 'empty-terminal %s n=%s\n' "$(STAMP)" "$EN"; ap_rec_put "$KEY" "$RK" "$AP_TXT"
        echo "$(STAMP) [$P] #$NUM @$HEAD12 produced an empty review twice — terminal, no further calls for this head (spend counted: $(( CNT + 1 ))/$CAP)" >> "$LOG"
      else
        printf -v AP_TXT 'empty %s n=%s\n' "$(STAMP)" "$EN"; ap_rec_put "$KEY" "$RK" "$AP_TXT"
        echo "$(STAMP) [$P] #$NUM @$HEAD12 produced an empty review — one retry left (spend counted: $(( CNT + 1 ))/$CAP)" >> "$LOG"
      fi
      continue
    fi
    # Tolerant of bold/indent (a formatting quirk must not read as "no
    # verdict"), and anchored to the review's final block through the one
    # shared reader (bin/lib/verdict-parse.sh, BH-1625) — the conductor's
    # mc_ap_read_verdict reads the posted comment back with the same one.
    VERDICT=$(printf '%s\n' "$REVIEW" | verdict_parse -w 'MERGE-WITH-NOTES|BLOCK|MERGE' 2>/dev/null) || VERDICT="UNPARSED"
    # >>> skipped-test guard (BH-5795): a BLOCK whose one reason is skipped CI
    # test jobs is not a BLOCK (SKIP_NOTE above). The final verdict line is
    # rewritten, so the box row and the posted comment (which the conductor
    # reads back) both say MERGE-WITH-NOTES. A reason that names anything else
    # keeps the BLOCK.
    if [ "$VERDICT" = BLOCK ] && ap_skip_only_block "$REVIEW" "${CISTATE_RAW:-}" "${BASEREF:-main}"; then
      REVIEW=$(ap_skip_downgrade "$REVIEW" "${BASEREF:-main}")
      VERDICT=MERGE-WITH-NOTES
      echo "$(STAMP) [$P] #$NUM @$HEAD12 BLOCK only for skipped CI test jobs (base ${BASEREF:-main}) -> MERGE-WITH-NOTES (BH-5795)" >> "$LOG"
    fi
    # <<< skipped-test guard

    POSTED="<!-- harness-review-autopilot $HEAD12 -->
$REVIEW

---
_Automatic adversarial review ($RA_SERVED) of \`$HEAD12\`, dispatched because this PR has been open >12h. Static review — no build was run. **Merging is human**: this lane never merges, approves, or closes. Push fixes and the next pass reviews the new head._

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

    # PAID FOR, SO WRITTEN DOWN FIRST. The comment is cached and the key moves
    # to reviewed-unposted BEFORE gh is asked to post it — a post that fails
    # (502, a token that expired mid-tick, a repo gone read-only) then costs one
    # gh call next hour instead of another Fable review. Body first, key second:
    # the key is the guard, and a guard whose payload is missing is worse than
    # neither (the dispatch above re-reviews that case rather than posting air).
    # Row mode (BH-4156): a comment over the ledger's detail limit is never
    # cut. It is cached in the local <key>.body file instead (ap_body_put), so a
    # failed post is re-posted with no model call, bounded by POST_TRIES.
    AP_CACHED=1
    ap_body_put "$KEY" "$RK" "$POSTED"; BODY_RC=$?
    if [ "$BODY_RC" != 0 ]; then
      AP_CACHED=0
      echo "$(STAMP) [$P] #$NUM @$HEAD12 the review is not cached: the body file write failed — it is posted now, and a failed post means the next tick reviews again" >> "$LOG"
    elif [ -n "$AP_BODY_LOCAL" ]; then
      echo "$(STAMP) [$P] #$NUM @$HEAD12 the review is cached in the local file $KEY.body, not as a row: $AP_BODY_LOCAL" >> "$LOG"
    fi
    printf -v AP_TXT 'status=reviewed-unposted %s verdict=%s tries=0\n' "$(STAMP)" "$VERDICT"
    ap_rec_put "$KEY" "$RK" "$AP_TXT"
    ap_post "$SLUG" "$NUM" "$KEY" "$VERDICT" 0; AP_RC=$?   # rc 2 (promote) is impossible at tries=0
    case "$AP_RC" in
      0)
        echo "$(STAMP) [$P] #$NUM @$HEAD12 reviewed -> $VERDICT (${DSIZE}B diff, $(( CNT + 1 ))/$CAP today) https://github.com/$SLUG/pull/$NUM" >> "$LOG"
        DISPATCHED="$DISPATCHED
$SLUG#$NUM -> $VERDICT" ;;
      3)
        echo "$(STAMP) [$P] #$NUM @$HEAD12 verdict=$VERDICT posted to the PR but its box verdict row did NOT record — the key stays unsettled and the next tick retries the row with no model call and no second comment https://github.com/$SLUG/pull/$NUM" >> "$LOG"
        DISPATCHED="$DISPATCHED
$SLUG#$NUM -> $VERDICT" ;;
      *)
        if [ "$AP_CACHED" = 1 ]; then
          AP_WHERE="$KEY.body"; [ "$AP_ROWS" = 1 ] && [ -z "$AP_BODY_LOCAL" ] && AP_WHERE="the row review_autopilot_body $RK"
          echo "$(STAMP) [$P] #$NUM @$HEAD12 verdict=$VERDICT but the comment did NOT post — the review is cached at $AP_WHERE and the next tick re-posts it with no model call" >> "$LOG"
        else
          echo "$(STAMP) [$P] #$NUM @$HEAD12 verdict=$VERDICT but the comment did NOT post — the review is not cached, so the next tick reviews again" >> "$LOG"
        fi ;;
    esac
  done <<<"$PRS"
done

# One consolidated beat per run, never one per PR — this lane reports work it
# did, it does not page anyone.
if [ -n "$DISPATCHED" ]; then
  LINE="review-autopilot: $(grep -c . <<<"$DISPATCHED") aging PR(s) reviewed (merge still human) —$(tr '\n' ' ' <<<"$DISPATCHED")"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "review-autopilot:$(date -u +%Y%m%d-%H)" --arg l "$LINE" \
    '{kind:"pr_review",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
fi
exit 0
