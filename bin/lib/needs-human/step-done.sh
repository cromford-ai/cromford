# bin/lib/needs-human/step-done.sh — a review BLOCK on a human step only, after
# the person did the step (BH-6536). Contracts are in bin/lib/needs-human.sh.
# Sourced, never executed; the root is ${HARNESS:-${H:-}} and nothing else (D43).
#
# TK-232 (project-6-os, 2026-10-13) ended REVIEW_BLOCKED on "migration 0020 not
# applied in prod". The person applied it and posted HUMAN-STEP-DONE, and the
# built branch was never re-reviewed: bin/review-rescue.sh skips a record that
# has a verdict, and the release reader needs a NEEDS-HUMAN: marker TK-232 never
# got. These functions say which records are in that state, whether a person
# answered, and write the one reason row the kanban, triage and the pool read.
# shellcheck shell=bash

# A migration a reviewer says is not applied yet. Algorithm constant, like the
# NH_RE_* shapes in classify.sh.
NH_SD_RE_MIGRATION='\bmigration\b.{0,80}\bnot (yet )?(been )?applied\b|\bapply\b.{0,40}\bmigration\b.{0,80}\b(to|in|on) prod'
# The states a ticket_stage row can hold. Every one is in the kanban's review column.
NH_SD_STATES='human-step-waiting human-step-done rereview-approve rereview-block rereview-gave-up handed-to-resolver'

_nh_sd_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# _nh_sd_block_re — DL_BLOCK_RE, from bin/lib/data-lane.sh beside this lib when
# the caller has not loaded it. Empty when it cannot be loaded.
_nh_sd_block_re() {
  if [ -z "${DL_BLOCK_RE:-}" ] && [ -r "$_nh_sd_dir/../data-lane.sh" ]; then
    # shellcheck source=bin/lib/data-lane.sh
    . "$_nh_sd_dir/../data-lane.sh" 2>/dev/null || true
  fi
  printf '%s' "${DL_BLOCK_RE:-}"
}

# _nh_sd_signal <line> <data-lane paths> — rc 0 when the line is a human-step
# line: one of the needs-human shapes or a migration not applied (and no
# negative), or a line naming a DATA_LANE: path.
_nh_sd_signal() {
  local l="${1:-}" p
  printf '%s\n' "$l" | grep -iE "$NH_RE_HUMAN|$NH_RE_HUB|$NH_RE_PASTE|$NH_RE_CRED|$NH_SD_RE_MIGRATION" \
    | grep -qviE "$NH_RE_NEG" && return 0
  while IFS= read -r p; do
    [ -n "$p" ] && case "$l" in *"$p"*) return 0 ;; esac
  done <<<"${2:-}"
  return 1
}

# _nh_sd_round <review.md> — the newest round (text after a `=== ` header, or
# the whole file before the first one) that holds a VERDICT line. A re-review
# that died before its verdict leaves an empty round under its header; that
# round is not the judgement, the one above it still is (BH-6536 review B1).
_nh_sd_round() {
  awk 'function keepv() { if (v) keep = cur }
       /^=== / { keepv(); cur = ""; v = 0; next }
       { cur = cur $0 "\n" }
       /^[[:space:]]*VERDICT:[[:space:]]*(APPROVE|BLOCK)[[:space:]]*$/ { v = 1 }
       END { keepv(); printf "%s", keep }' "$1" 2>/dev/null
}

# nh_sd_human_only <review.md> — rc 0 prints "human-step<TAB><action>" when the
# file's last VERDICT line is BLOCK, the newest round with a verdict
# (_nh_sd_round) names a human step, and every blocking finding line of that
# round is itself a human-step line. rc 1 prints "none". rc 2 unreadable
# (nothing printed).
nh_sd_human_only() {
  local f="${1:-}" verdict lines bre paths line val low action="" sig=0 blocking hit
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 2
  type _nh_final >/dev/null 2>&1 && type _nh_lines >/dev/null 2>&1 || return 2
  bre=$(_nh_sd_block_re); [ -n "$bre" ] || return 2
  verdict=$(sed -nE 's/^[[:space:]]*VERDICT:[[:space:]]*(APPROVE|BLOCK)[[:space:]]*$/\1/p' "$f" 2>/dev/null | sed -n '$p')
  [ "$verdict" = BLOCK ] || { printf 'none\n'; return 1; }
  lines=$(_nh_sd_round "$f" | tr -d '\r' | _nh_lines)
  # The structured NEEDS_HUMAN: value (placeholders skipped, as nh_classify).
  while IFS= read -r line; do
    val=$(_nh_clean "$(printf '%s' "$line" | sed -E 's/^NEEDS_HUMAN:[[:space:]]*//')")
    low=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "${low%.}" in ''|none|n/a|na|no|nothing|-|'<'*'>') continue ;; esac
    action="$val"; sig=1; break
  done < <(printf '%s\n' "$lines" | grep -E '^NEEDS_HUMAN:[ 	]*[^ 	]' || true)
  # Any DATA_LANE: path counts, wherever the project keeps its migrations.
  paths=$(printf '%s\n' "$lines" | sed -nE 's/^DATA_LANE:[[:space:]]*([^[:space:]]+).*$/\1/p')
  [ -n "$paths" ] && sig=1
  hit=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | grep -qE '^(NEEDS_HUMAN|DATA_LANE):' && continue
    if _nh_sd_signal "$line" "$paths"; then sig=1; [ -n "$hit" ] || hit="$line"; fi
  done <<<"$lines"
  [ "$sig" = 1 ] || { printf 'none\n'; return 1; }
  # Every blocking finding must be a human-step line itself.
  blocking=$(printf '%s\n' "$lines" | grep -E "$bre" || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _nh_sd_signal "$line" "$paths" || { printf 'none\n'; return 1; }
  done <<<"$blocking"
  [ -n "$action" ] || action=$(_nh_clean "${hit:-$(printf '%s' "$paths" | sed -n 1p)}")
  printf 'human-step\t%s\n' "$action"
  return 0
}

# nh_sd_done_after <comments-json> <since-iso> — pure. The newest non-Bot
# comment created after <since-iso> whose first non-blank line starts
# HUMAN-STEP-DONE:, or is a "## Hub probe … PASS" header with no FAIL. No
# NEEDS-HUMAN: marker is needed. rc 0 prints "comment: <url>", "author:
# @<login> at <created_at>" and the first 40 body lines. rc 1 no evidence,
# nothing printed. rc 2 a non-array thread or a since that is not ISO.
nh_sd_done_after() {
  local thread="${1:-}" since="${2:-}" out
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 2
  printf '%s' "$thread" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  out=$(printf '%s' "$thread" | jq -r --arg since "$since" --arg done "${NH_DONE_PREFIX:-HUMAN-STEP-DONE:}" '
    [ to_entries[] | select((.value | type) == "object")
      | ((.value.body // "") | tostring | gsub("\r"; "")) as $b
      | { b: $b, i: .key,
          at: ((.value.created_at // "") | tostring),
          url: ((.value.html_url // "") | tostring),
          who: (((.value.user // {}).login // "") | tostring),
          bot: ((((.value.user // {}).type // "") | tostring | ascii_downcase) == "bot"),
          first: ([ $b | split("\n")[] | sub("^[ \t]+"; "") | select(length > 0) ] | first // "") }
      | select(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ] | sort_by([.at, .i])
    | [ .[] | select(.at > $since) | select(.bot | not)
        | select((.first | startswith($done))
                 or ((.first | test("^##[ \t]+Hub probe\\b.*\\bPASS\\b")) and (.first | test("\\bFAIL\\b") | not))) ]
    | last // empty
    | "comment: \(.url)", "author: @\(.who) at \(.at)", (.b | split("\n") | .[:40][])' 2>/dev/null) || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# nh_sd_rescue_on [project] — rc 0 when bin/review-rescue.sh will run shape D
# for this project: RESCUE_HUMAN_STEP resolves to 1 and the review-rescue lane
# is not off. The knob belongs to the review-rescue lane, and lane-gate.sh
# exports a knob only into the lane that owns it, so a caller in another lane
# (bin/blocked-resolver.sh) reads it here through lane_knob, settings row
# first. Without lane-gate.sh (a scratch tree) the env value decides. The lane
# check runs in a subshell: lane_paused sets the caller's LANE_PAUSED_* globals.
nh_sd_rescue_on() {
  local p="${1:-}" v
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob review-rescue RESCUE_HUMAN_STEP "$p" 2>/dev/null)
  else
    v="${RESCUE_HUMAN_STEP:-1}"
  fi
  [ "$v" = 0 ] && return 1
  if command -v lane_paused >/dev/null 2>&1 && ( lane_paused review-rescue "$p" ) >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# nh_sd_pending <record-dir> [project] — rc 0 when the record waits for the
# rescue lane's human-step re-review: line 1 REVIEW_BLOCKED, no .review-rescued,
# not superseded or abandoned by bin/blocked-resolver.sh, shape D is on for the
# project (nh_sd_rescue_on), and the review is a human-step-only BLOCK.
# Otherwise rc 1.
nh_sd_pending() {
  local r="${1:-}" p="${2:-}"
  [ -n "$r" ] && [ -d "$r" ] || return 1
  nh_sd_rescue_on "$p" || return 1
  case "$(head -1 "$r/RESULT" 2>/dev/null)" in REVIEW_BLOCKED*) ;; *) return 1 ;; esac
  [ -e "$r/.review-rescued" ] || [ -e "$r/.blocked-resolver-superseded" ] \
    || [ -e "$r/.blocked-resolver-abandoned" ] && return 1
  nh_sd_human_only "$r/review.md" >/dev/null 2>&1
}

# nh_sd_stage_put <project> <issue> <key> <state> <reason> — the one reason row
# for a ticket in this flow. The hub-local copy state/ticket-stage/<project>.tsv
# first (one line per key: KEY, column, state, iso, reason), then the
# ticket_stage ledger row, key <project>#<issue>, status = the kanban column,
# detail "<state> by <lane> at <iso>: <reason>". No write when the key's line
# already holds this state and reason. rc 0 always; a failed PUT is logged to
# stderr and changes nothing.
nh_sd_stage_put() {
  local p="${1:-}" n="${2:-}" key="${3:-}" state="${4:-}" reason="${5:-}" root f iso lane cur col=review
  [ -n "$p" ] && [ -n "$key" ] && [ -n "$state" ] || return 0
  case " $NH_SD_STATES " in *" $state "*) ;; *) return 0 ;; esac
  case "$key$p" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  reason=$(printf '%s' "$reason" | tr '\n\t\r' '   ' \
    | sed -E 's/(^|[^A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{16,}/\1\2[masked]/g; s/[[:space:]]+/ /g' | cut -c1-300)
  iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  lane="${AGENT_CALL_LANE:-review-rescue}"
  root="${HARNESS:-${H:-}}"
  if [ -n "$root" ]; then
    f="$root/state/ticket-stage/$p.tsv"
    cur=$(awk -F'\t' -v k="$key" '$1==k {s=$3 "\t" $5} END {print s}' "$f" 2>/dev/null)
    [ "$cur" = "$state"$'\t'"$reason" ] && return 0
    # Parallel rescues of one project rewrite this one file: a short mkdir
    # lock around the read-modify-move (at most ~5 s, never across other work).
    # A lock older than a minute is a dead writer's and is taken over.
    if mkdir -p "$root/state/ticket-stage" 2>/dev/null; then
      local i=0 tmp="$f.tmp.$BASHPID"
      until mkdir "$f.lockd" 2>/dev/null; do
        i=$((i+1))
        [ -n "$(find "$f.lockd" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$f.lockd" 2>/dev/null
        [ "$i" -lt 50 ] || break
        sleep 0.1
      done
      { awk -F'\t' -v k="$key" '$1!=k' "$f" 2>/dev/null
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$col" "$state" "$iso" "$reason"; } > "$tmp" \
        && mv -f "$tmp" "$f" || rm -f "$tmp"
      [ "$i" -lt 50 ] && rmdir "$f.lockd" 2>/dev/null
    fi
  fi
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put ticket_stage "$p#$n" "$col" "$state by $lane at $iso: $reason" \
    || echo "nh_sd_stage_put: ticket_stage $p#$n did not write (ledger rc $?) — the local copy stands" >&2
  return 0
}

# nh_sd_stage_lines <project> — the hub-local rows newer than
# NH_SD_STAGE_MAX_AGE_S (default 604800), as stored. rc 0; no root or no file
# prints nothing.
nh_sd_stage_lines() {
  local p="${1:-}" root max now key col state iso reason ep
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -n "$p" ] || return 0
  max="${NH_SD_STAGE_MAX_AGE_S:-604800}"
  case "$max" in ''|*[!0-9]*) max=604800 ;; esac
  now=$(date -u +%s)
  [ -r "$root/state/ticket-stage/$p.tsv" ] || return 0
  while IFS=$'\t' read -r key col state iso reason; do
    [ -n "$key" ] && [ -n "$iso" ] || continue
    ep=$(date -u -d "$iso" +%s 2>/dev/null) || continue
    [ $((now - ep)) -le "$max" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$col" "$state" "$iso" "$reason"
  done < "$root/state/ticket-stage/$p.tsv"
  return 0
}
