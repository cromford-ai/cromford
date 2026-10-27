# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8592-fixround-nochange.sh — BH-8592: a fix round
# that changed no file is never pushed, and an innocent twice-ejected PR goes
# back in the Mergify queue on the SAME head.
#
# WHY. On 2026-10-27 two fix rounds found that a queue ejection was a batch
# sibling's fault and committed `--allow-empty` ("... no change": 7fcdde11 on
# #8128, 73aadc64 on #8550). br_fix_round saw HEAD != lease and pushed the
# empty commit. The head moved, Mergify dequeued #8550 from batch #8588
# (PULL_REQUEST_UPDATED) and the batch merged nothing.
#
# WHAT. Four one-line call sites in bin/blocked-resolver.sh, each `command -v`
# guarded, so a lifted br_fix_round or BR_OPT_OFF=bh-8592-fixround-nochange
# runs as before. The logic lives here, not in the driver: the driver is at
# its tests/br/driver-ceiling.tsv `lines` row (batch #8615).
#   br_fix_round  brnc_fix_exit before the "no verified commit" test: rc 0 =
#                 brnc_round took a queue-ejected-twice park (the round
#                 returns); else it sets the caller's nctail on any other
#                 no-change park (the "no verified commit" exit). And
#                 brnc_queued_guard right before hold_push.
#   br_fix_adopt  `done)`: brnc_settle_pending (the hub half of a hopped round).
#   br_one        brnc_one_gate before the ladder rung: on a
#                 queue-ejected-twice park, brnc_settle_pending (a settle that
#                 could not read GitHub last tick is retried; the round's
#                 fixrounds bump would otherwise send the park to
#                 rebuild-fresh).
# The requeue runs on the hub only (no BR_FIX_HERE, no LANE_RUN_ID): the
# conductor's rows and MC_ATTEMPTS live there.
#
# Record fields: nochange_heads (heads a no-change round ended on),
# nochange_noted_heads (PR comment posted), nochange_requeued_heads (requeue
# done or already queued), nochange_declined_heads (no requeue; the ladder
# takes the park). Attempt actions: fix-round-nochange, fix-round-queued.
#
# Knobs (settings rows in catalog/lanes.d/blocked-resolver.knobs.d/):
#   BR_NOCHANGE_REQUEUE     1     0 = record + comment, no requeue
#   BR_NOCHANGE_NOTE_BYTES  3000  bytes of the round's commit messages in the
#                                 PR comment (200..20000)

# brnc_not <wt> <lease> <mref> — the refs a round's OWN commits are reachable
#   from none of: the PR head, origin/main and, on a stacked child, its base.
#   The guard-silenced gate's set.
brnc_not() {
  local not="$2"
  git -C "$1" rev-parse --verify -q origin/main >/dev/null 2>&1 && not="$not origin/main"
  [ "${3:-main}" != main ] && git -C "$1" rev-parse --verify -q "origin/$3" >/dev/null 2>&1 && not="$not origin/$3"
  printf '%s' "$not"
}

# brnc_nochange <wt> <lease> <mref> <conflicts> <reason> — rc 0 when the round
#   changed nothing worth a push, and prints its own commit count (empty
#   commits). rc 1 otherwise: a real file change, a resolved conflict, a git
#   read that failed, or a clean main merge on a park that is not a queue one.
#   On queue-ejected-twice a clean main merge alone is also no change: the queue
#   tests every PR on current main, so that push only moves the head.
brnc_nochange() {
  local wt="$1" lease="$2" mref="${3:-main}" conflicts="${4:-}" reason="${5:-}" not own n
  [ -z "$conflicts" ] && [ -n "$lease" ] && [ -d "$wt" ] || return 1
  not=$(brnc_not "$wt" "$lease" "$mref")
  # shellcheck disable=SC2086  # $not is a list of refs
  own=$(git -C "$wt" log --no-merges --name-only --format= HEAD --not $not 2>/dev/null) || return 1
  [ -z "$(printf '%s' "$own" | sed '/^$/d')" ] || return 1
  # shellcheck disable=SC2086
  n=$(git -C "$wt" rev-list --no-merges --count HEAD --not $not 2>/dev/null) || return 1
  if [ "$reason" != queue-ejected-twice ]; then
    git -C "$wt" diff --quiet "$lease" HEAD -- 2>/dev/null || return 1
  fi
  printf '%s' "${n:-0}"
}

# brnc_fix_exit <p> <ck> <rkey> <reason> <url> <slug> <wt> <lease> <mref> <head> <rec> <tkey> <rc> <vrc> <conflicts>
#   br_fix_round's no-change exit. Only after an agent rc 0 and a verify rc 0,
#   and only when brnc_nochange says the round changed no file:
#     queue-ejected-twice  brnc_round, rc 0: the caller returns 0 (no push,
#                          no "no verified commit" record).
#     any other park       sets the CALLER's `nctail` (bash dynamic scope; the
#                          driver declares it local) so the "no verified
#                          commit" test takes the round, and posts brnc_note
#                          when the round made empty commits. rc 1.
#   Anything else: rc 1, nctail untouched.
brnc_fix_exit() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" slug="$6" wt="$7" lease="$8" mref="${9:-main}"
  local h="${10:-}" rec="${11:-}" tkey="${12:-}" brnc_arc="${13:-}" brnc_vrc="${14:-}" conflicts="${15:-}" ncn
  [ "$brnc_arc" = 0 ] && [ "$brnc_vrc" = 0 ] || return 1
  ncn=$(brnc_nochange "$wt" "$lease" "$mref" "$conflicts" "$reason") || return 1
  [ "$reason" = queue-ejected-twice ] && { brnc_round "$p" "$ck" "$rkey" "$reason" "$url" "$slug" "$wt" "$lease" "$mref" "$h" "$ncn" "$rec" "$tkey"; return 0; }
  nctail=" · tree unchanged ($ncn empty commit(s)), not pushed"
  [ "$ncn" -gt 0 ] 2>/dev/null && brnc_note "$p" "$ck" "$url" "$wt" "$lease" "$mref" "$reason" "${h:-$lease}"
  return 1
}

# brnc_one_gate <p> <ck> <rkey> <reason> <url> <rec> <tkey> — br_one's check
#   before the ladder rung. rc 0 = a queue-ejected-twice park's pending
#   no-change head was handled this tick (the caller takes no rung); rc 1 =
#   another reason, or brnc_settle_pending's rc 1. Prints nothing.
brnc_one_gate() {
  [ "${4:-}" = queue-ejected-twice ] || return 1
  brnc_settle_pending "$1" "$2" "$3" "$4" "$5" "$6" "$7" >/dev/null
}

# brnc_note_bytes — BR_NOCHANGE_NOTE_BYTES, or its fallback 3000 (settings row
#   catalog/lanes.d/blocked-resolver.knobs.d/BR_NOCHANGE_NOTE_BYTES.json).
brnc_note_bytes() {
  local b="${BR_NOCHANGE_NOTE_BYTES:-3000}"
  case "$b" in ''|*[!0-9]*) b=3000 ;; esac
  { [ "$((10#$b))" -ge 200 ] && [ "$((10#$b))" -le 20000 ]; } || b=3000
  printf '%s' "$((10#$b))"
}

# brnc_note_body <wt> <lease> <mref> — the round's own commit messages, cut at
#   brnc_note_bytes. Captured whole, then cut: a `head -c` on the pipe would
#   SIGPIPE git.
brnc_note_body() {
  local not body
  not=$(brnc_not "$1" "$2" "${3:-main}")
  # shellcheck disable=SC2086
  body=$(git -C "$1" log --no-merges --format='%B' HEAD --not $not 2>/dev/null) || body=""
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || { printf 'The round committed no message.'; return 0; }
  head -c "$(brnc_note_bytes)" <<<"$body"
}

# brnc_note <p> <ck> <url> <wt> <lease> <mref> <reason> <head> — ONE PR comment
#   per head with what the round found. The head is recorded BEFORE the post;
#   a record that will not write posts nothing (no comment every tick). A
#   failed post is logged and not retried: the attempt row keeps the finding.
brnc_note() {
  local p="$1" ck="$2" url="$3" wt="$4" lease="$5" mref="$6" reason="$7" h="$8" body
  [ -n "$url" ] && [ "$url" != - ] && [ -n "$h" ] || return 0
  br_has_field_value "$(br_load "$p" "$ck")" nochange_noted_heads "$h" && return 0
  body=$(brnc_note_body "$wt" "$lease" "$mref")
  if ! br_push_field "$p" "$ck" nochange_noted_heads "$h"; then
    say "$p/$ck [$reason]: could NOT record ${h:0:8} in nochange_noted_heads — no PR comment posted"
    return 0
  fi
  br_pr_comment "$url" "Fix round by \`bin/blocked-resolver.sh\` ($reason): the round changed no file, so nothing was pushed and the head stays \`${h:0:12}\`. What the round found:

$body" >/dev/null 2>&1 || say "$p/$ck [$reason]: the no-change comment on $url did not post — the finding is on the fix-round-nochange attempt"
  return 0
}

# brnc_round <p> <ck> <rkey> <reason> <url> <slug> <wt> <lease> <mref> <head> <n> <rec> <tkey>
#   A queue-ejected-twice round that changed no file: recorded (the round was
#   spent), noted on the PR, NOT pushed. The worktree and brfix/<ck> are
#   dropped: an empty commit must not seed a later round. On the hub the
#   requeue is asked at once; a hopped round leaves it to br_fix_adopt.
brnc_round() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" slug="$6" wt="$7" lease="$8" mref="$9"
  local h="${10:-}" n="${11:-0}" rec="${12:--}" tkey="${13:--}"
  [ -n "$h" ] || h="$lease"
  br_record "$p" "$ck" fix-round-nochange "$reason" "the round changed no file ($n own commit(s), all empty) — not pushed, the head stays ${h:0:8}" fixrounds "$url" "$h"
  br_push_field "$p" "$ck" nochange_heads "$h" \
    || say "$p/$rkey [$reason]: could NOT record ${h:0:8} in nochange_heads — the requeue is not asked for this head"
  brnc_note "$p" "$ck" "$url" "$wt" "$lease" "$mref" "$reason" "$h"
  br_event resolver_fix_nochange "$p" "$ck" "$reason" "fix round on ${h:0:8} changed no file — not pushed"
  say "$p/$rkey [$reason]: fix-round-nochange — the round changed no file ($n empty commit(s)); NOT pushed, the head stays ${h:0:8}"
  br_wt_drop "the round changed no file"
  git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
  mc_git_auth_clear 2>/dev/null
  brnc_settle_pending "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$slug" >/dev/null
  return 0
}

# brnc_pending <state-json> — rc 0 when the record's last no-change head has
#   neither been requeued nor declined.
brnc_pending() {
  printf '%s' "${1:-}" | jq -e '((.nochange_heads // [])[-1] // "") as $h
    | $h != "" and (((.nochange_requeued_heads // []) | index($h)) == null)
      and (((.nochange_declined_heads // []) | index($h)) == null)' >/dev/null 2>&1
}

# brnc_decline <p> <ck> <head> <why> — records the head in
#   nochange_declined_heads and prints `declined <why>`.
brnc_decline() {
  br_push_field "$1" "$2" nochange_declined_heads "$3" \
    || say "$1/$2: could NOT record ${3:0:8} in nochange_declined_heads"
  printf 'declined %s' "$4"
}

# brnc_settle <p> <ck> <rkey> <reason> <url> [slug] — the requeue of the last
#   no-change head. Prints one answer, always rc 0:
#     requeued            `@mergifyio requeue` posted, Mergify's witness seen
#     requeued awaiting   posted, the witness not seen yet (row WAIT_CI)
#     queued              Mergify already holds the head (row QUEUED), or this
#                         head was already requeued: 0 requeues
#     declined <why>      no requeue; the head is in nochange_declined_heads
#     unread <why>        a read failed; nothing written, asked again next tick
#     observe             observe mode, one WOULD line
#   Gates in order: the knob, already done, Mergify, the live head, a culprit
#   mark, the approval at this head, the queue state. Marks BEFORE the post
#   (BH-636): a crash after them never posts twice.
brnc_settle() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" slug="${6:-}" st h num key live rev qs err rrc=0
  st=$(br_load "$p" "$ck")
  h=$(printf '%s' "$st" | jq -r '(.nochange_heads // [])[-1] // empty' 2>/dev/null)
  [ -n "$h" ] || { printf 'declined no-head'; return 0; }
  br_has_field_value "$st" nochange_requeued_heads "$h" && { printf 'queued'; return 0; }
  case "${BR_NOCHANGE_REQUEUE:-1}" in
    0) say "$p/$rkey [$reason]: BR_NOCHANGE_REQUEUE=0 — ${h:0:8} is not requeued; the ladder takes the park"
       brnc_decline "$p" "$ck" "$h" knob-off; return 0 ;;
  esac
  [ -n "$slug" ] || slug=$(mc_slug_of_url "$url" 2>/dev/null)
  num=$(mc_num_of_url "$url" 2>/dev/null)
  [ -n "$slug" ] && [ -n "$num" ] || { brnc_decline "$p" "$ck" "$h" "no-pr"; return 0; }
  key="$slug#$num"
  if [ "$(mc_queue_provider "$slug" 2>/dev/null)" != mergify ]; then
    say "$p/$rkey [$reason]: $slug does not queue on Mergify — ${h:0:8} is not requeued"
    brnc_decline "$p" "$ck" "$h" not-mergify; return 0
  fi
  if ! live=$(mc_pr_live_head "$slug" "$num" 2>/dev/null) || [ -z "$live" ]; then
    say "$p/$rkey [$reason]: the live head of $key could not be read — the requeue of ${h:0:8} is asked again next tick"
    printf 'unread live-head'; return 0
  fi
  if [ "$live" != "$h" ]; then
    say "$p/$rkey [$reason]: $key moved to ${live:0:8} after the no-change round on ${h:0:8} — no requeue, the new head enters the queue on its own merits"
    brnc_decline "$p" "$ck" "$h" head-moved; return 0
  fi
  if mc_attempt_has "dqwculprit $key $h" 2>/dev/null; then
    say "$p/$rkey [$reason]: $key ${h:0:8} carries a culprit mark (dqwculprit) — never requeued on this head"
    brnc_decline "$p" "$ck" "$h" culprit; return 0
  fi
  rev=$(mc_row_field "$key" 5 2>/dev/null)
  if [ "$rev" != "$h" ]; then
    say "$p/$rkey [$reason]: the conductor's approval for $key is on ${rev:0:8}, not ${h:0:8} — no requeue"
    brnc_decline "$p" "$ck" "$h" not-approved-at-head; return 0
  fi
  qs=$(mc_queue_state "$url" "$h" 2>/dev/null)
  case "$qs" in
    queued)
      br_push_field "$p" "$ck" nochange_requeued_heads "$h" \
        || say "$p/$rkey [$reason]: could NOT record ${h:0:8} in nochange_requeued_heads"
      mc_transition "$key" QUEUED "already in the Mergify queue on ${h:0:8}; the fix round found a batch sibling's fault and pushed nothing" "$h" "$rev" "$url" - - - >/dev/null
      say "$p/$rkey [$reason]: $key is already queued on ${h:0:8} — no requeue, row QUEUED"
      printf 'queued'; return 0 ;;
    merged)
      say "$p/$rkey [$reason]: $key merged — no requeue"
      brnc_decline "$p" "$ck" "$h" merged; return 0 ;;
    ejected) ;;
    *)
      say "$p/$rkey [$reason]: the queue state of $key on ${h:0:8} could not be read (${qs:-no answer}) — the requeue is asked again next tick"
      printf 'unread queue-state'; return 0 ;;
  esac
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD requeue $key on ${h:0:8} (the fix round found a batch sibling's fault and pushed nothing) — observe mode"
    printf 'observe'; return 0
  fi
  if ! br_push_field "$p" "$ck" nochange_requeued_heads "$h"; then
    say "$p/$rkey [$reason]: could NOT record ${h:0:8} in nochange_requeued_heads — no requeue posted, asked again next tick"
    printf 'unread record-write'; return 0
  fi
  mc_requeued_record "$key" "$h"
  mc_attempt_clear reejected "$key" "$h"
  err=$(mc_requeue_mergify "$slug" "$url" "$h" 2>/dev/null) || rrc=$?
  case "$rrc" in
    0|2)
      mc_transition "$key" QUEUED "requeued on ${h:0:8} by the blocked-resolver: the fix round found a batch sibling's fault and pushed nothing" "$h" "$rev" "$url" - - - >/dev/null
      say "$p/$rkey [$reason]: requeued $key on ${h:0:8} — Mergify acknowledged it; the head did not change"
      br_event resolver_fix_requeued "$p" "$ck" "$reason" "requeued ${h:0:8}: the no-change round pushed nothing"
      printf 'requeued' ;;
    3)
      mc_transition "$key" WAIT_CI "requeued on ${h:0:8}, awaiting Mergify's witness" "$h" "$rev" "$url" - - - >/dev/null
      say "$p/$rkey [$reason]: asked Mergify to requeue $key on ${h:0:8}, awaiting Mergify's witness"
      br_event resolver_fix_requeued "$p" "$ck" "$reason" "requeue asked on ${h:0:8}, awaiting Mergify's witness"
      printf 'requeued awaiting' ;;
    *)
      say "$p/$rkey [$reason]: the requeue of $key on ${h:0:8} was refused (rc $rrc: ${err:-no reason}) — not asked again on this head; the ladder takes the park"
      br_push_field "$p" "$ck" nochange_declined_heads "$h" >/dev/null 2>&1
      printf 'declined requeue-refused' ;;
  esac
  return 0
}

# brnc_settle_pending <p> <ck> <rkey> <reason> <url> <rec> <tkey> [slug]
#   rc 0 = the pending no-change head is handled this tick (requeued, already
#   queued, observe, a read to retry, or a held ticket): the caller takes no
#   rung. rc 1 = nothing pending, not the hub, or declined: the caller goes on.
brnc_settle_pending() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" rec="${6:--}" tkey="${7:--}" slug="${8:-}" ans
  [ "${BR_FIX_HERE:-0}" != 1 ] && [ -z "${LANE_RUN_ID:-}" ] || return 1
  brnc_pending "$(br_load "$p" "$ck")" || return 1
  if command -v br_rung_hold_gate >/dev/null 2>&1 && ! br_rung_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; then
    say "$p/$rkey [$reason]: the ticket is held — the no-change head is not requeued this tick"
    return 0
  fi
  ans=$(brnc_settle "$p" "$ck" "$rkey" "$reason" "$url" "$slug")
  printf '%s\n' "$ans"
  case "$ans" in declined*) return 1 ;; esac
  return 0
}

# brnc_queued_guard <p> <ck> <rkey> <reason> <url> <lease> <head> — rc 0 push.
#   rc 1 NOT pushed: Mergify holds the PR (queued/checking). A push would
#   dequeue it and kill its batch. The round is recorded (it was spent), the
#   worktree is dropped and brfix/<ck> is KEPT, so a round after an ejection
#   starts from it. merged, ejected and unknown push as before; unknown says so.
brnc_queued_guard() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" lease="$6" h="${7:-}" qs
  command -v mc_queue_state >/dev/null 2>&1 || return 0
  [ -n "$url" ] && [ "$url" != - ] || return 0
  qs=$(mc_queue_state "$url" "$lease" 2>/dev/null)
  case "$qs" in
    queued)
      say "$p/$rkey [$reason]: fix round NOT pushed — Mergify holds the PR (queued/checking) on ${lease:0:8}; a push would dequeue it. brfix/$ck is kept"
      br_record "$p" "$ck" fix-round-queued "$reason" "not pushed: Mergify holds the PR (queued/checking) on ${lease:0:12}" fixrounds "$url" "${h:-$lease}"
      br_event resolver_fix_queued "$p" "$ck" "$reason" "fix round on ${lease:0:8} not pushed: the PR is in the Mergify queue"
      br_wt_drop "Mergify holds the PR"
      mc_git_auth_clear 2>/dev/null
      return 1 ;;
    merged|ejected) return 0 ;;
    *) say "$p/$rkey [$reason]: the queue state of the PR is unknown (no queue on this repo, or the read failed) — pushing as before"
       return 0 ;;
  esac
}
