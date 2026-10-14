#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/lib/mc-batch-eject.sh inside the merge conductor, which has already armed the identity that can see this repo; its one raw read (a batch run's failed log) belongs to that lane, and a second mint here would override that choice.
# bin/lib/mc-noverdict.sh — A BATCH THAT FAILED ONLY BECAUSE A CI SHARD LEFT
# NO VERDICT PUTS ITS PR BACK IN THE QUEUE ONCE, WITH NO FIX ROUND (BH-6336).
# Sourced by bin/lib/mc-batch-eject.sh, never executed.
#
# THE CASE (2026-10-12 22:06Z). Batch draft #6316 held PR #5443 alone. The job
# `Tests, traced (shard 5/8)` was cancelled, so bin/ci-verdicts.sh printed
# "shard 5/8 left no verdict" and both fan-in checks went red. Mergify ejected
# #5443. The re-entry arm called the single-PR draft `solo`, fr_reentry_gate
# could not attribute a job-named failure (`unknown` on Mergify's UNSTABLE),
# so it was never put back, and the next tick posted a culprit comment on a PR
# that did nothing wrong. A person requeued it by hand.
#
# THE RULE (nv_gate, asked by bej_reentry_gate before its own verdict). The
# newest dequeued Mergify comment bound to THIS head (fr_dequeue_batch) names
# the failing batch runs. For each run, every job that did not pass is read:
#   - a job named `Tests, traced (shard i/N)` is a shard job. It must be a
#     shard that a "shard i/N left no verdict" line names.
#   - any other job is a fan-in. It must print at least one error line, and
#     every error line except the runner's "Process completed with exit code
#     N." must be a bin/ci-verdicts.sh "shard i/N left no verdict" line.
# A run that passes both tests is `noverdict`. Anything else is `real`: a test
# that failed, a trace hit, a failed plan job, "ran 0 tests", a failed lint.
# A run whose jobs or log cannot be read in full is unread, and one unread run
# is never outvoted by the others (BH-3776).
#   noverdict  every run is noverdict. Re-queued once per head when the
#              main-red freeze is down and the head's own checks are green
#              (_bej_head_green). The requeue is the arm's own tail: the
#              `requeued` mark, merge mode, the pre-queue gate, the tick
#              budget, mc_requeue_mergify and fr_requeue_note's PR line.
#              Nothing goes to the flake ledger.
#   real/none  bej_reentry_gate decides exactly as before. `none` is a dequeue
#              with no failing runs (a conflict or review dequeue), or no
#              dequeue comment for this head.
#   unread     a failing run's jobs or log could not be read: the row waits
#              with its own reason. The third unread tick on a head hands it
#              to bej_reentry_gate's rule. A comment that cannot be read, or
#              that lists a check that is not an Actions run, is not unread
#              here: bej_reentry_gate's rule decides at once.
# A head the arm already re-queued never reaches this gate again (the arm
# stops on its `requeued` mark first), so the second ejection of a no-verdict
# head is `queue-ejected-twice` as before. nv_twice_note, asked first by
# mc_eject_fix_now, sends ONE critical alert when that second batch also left
# no verdict: a CI runner that fails twice is an infra incident.
#
# State, all in MC_ATTEMPTS (append-only):
#   nvv <key> <head> <comment id> <word> <draft> <run ids,> <shards,>
#                              the verdict, read once per head (and once more
#                              for the second dequeue, by nv_twice_note)
#   nvunread <key> <head>      one per unread gate tick (at most 2)
#   nvtwice <key> <head>       the second-strike answer, written BEFORE the
#                              alert (a crash costs the page, never a page
#                              per tick)
#   nvtwiceunread <key> <head> one per unread second-strike read (at most 2)
# Log lines go through _bej_log_once (one per head and word): NOVERDICT_RETRY,
# NOVERDICT_UNREAD, NOVERDICT_TWICE. No root of its own: MC_ATTEMPTS and
# MC_STATE_DIR are the conductor's.

NV_RE='^shard ([0-9]+)/([0-9]+) left no verdict'
NV_SHARD_JOB_RE='^Tests, traced \(shard ([0-9]+)/([0-9]+)\)$'
NV_WORD=""; NV_CID=""; NV_DRAFT=""; NV_RUNS=""; NV_SHARDS=""

# nv_run_word <owner/repo> <run id>
#   -> "noverdict<TAB><i/N,...>" or "real<TAB>-", rc 0
#   rc 2 the jobs or the failed-job log could not be read in full (the read
#   failed, the page did not hold every job, no job failed, the log is empty or
#   longer than FLAKY_LOG_MAX bytes).
nv_run_word() {
  local slug="$1" id="$2" max="${FLAKY_LOG_MAX:-0}" jraw failed tmp sz j errs e nvs="" shards="" one
  case "$max" in ''|*[!0-9]*) return 2 ;; esac
  [ "$max" -gt 0 ] || return 2
  case "$id" in ''|*[!0-9]*) return 2 ;; esac
  command -v gh_ci_api >/dev/null 2>&1 || return 2
  jraw=$(GH_CI_READ_WHAT="actions/runs/<id>/jobs" gh_ci_api "$slug" "repos/$slug/actions/runs/$id/jobs?per_page=100") || return 2
  failed=$(jq -r '(.jobs // null) as $j
    | if ($j | type) != "array" or (.total_count // 0) > ($j | length) then error("partial")
      else $j[] | select((.conclusion // "") | IN("success","skipped","neutral") | not) | (.name // "") end' \
    <<<"$jraw" 2>/dev/null) || return 2
  failed=$(printf '%s\n' "$failed" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr -d '\t' | grep -av '^$' | awk '!s[$0]++')
  [ -n "$failed" ] || return 2
  tmp=$(mktemp "${TMPDIR:-/tmp}/nv-log.XXXXXX" 2>/dev/null) || return 2
  if ! gh run view "$id" -R "$slug" --log-failed > "$tmp" 2>/dev/null </dev/null; then rm -f "$tmp"; return 2; fi
  sz=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*|0) rm -f "$tmp"; return 2 ;; esac
  [ "$sz" -le "$max" ] || { rm -f "$tmp"; return 2; }
  while IFS= read -r j; do
    if [[ "$j" =~ $NV_SHARD_JOB_RE ]]; then
      shards+="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"$'\n'; continue
    fi
    # A fan-in: its own section of the log (first tab field = the job name).
    errs=$(NV_J="$j" awk -F'\t' '$1 == ENVIRON["NV_J"]' "$tmp" \
           | sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g; s/\r$//' \
           | grep -aE '##\[error\]|::error::' | sed -E 's/.*(##\[error\]|::error::)//')
    one=0
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case "$e" in "Process completed with exit code "*) continue ;; esac
      if [[ "$e" =~ $NV_RE ]]; then nvs+="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"$'\n'; one=1
      else one=x; break; fi
    done <<<"$errs"
    [ "$one" = 1 ] || { rm -f "$tmp"; printf 'real\t-\n'; return 0; }
  done <<<"$failed"
  rm -f "$tmp"
  [ -n "$nvs" ] || { printf 'real\t-\n'; return 0; }
  # Every failed shard job must be one that a no-verdict line names.
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    grep -qxF -- "$j" <<<"$nvs" || { printf 'real\t-\n'; return 0; }
  done <<<"$shards"
  printf 'noverdict\t%s\n' "$(printf '%s' "$nvs" | sort -t/ -k1,1n -u | paste -sd, -)"
}

# nv_batch_word <owner/repo> <num> <key> <head> — sets NV_WORD (noverdict |
#   real | none), NV_CID (the dequeue comment id), NV_DRAFT, NV_RUNS (run ids,
#   comma-joined) and NV_SHARDS. A definitive word is cached as an `nvv` line
#   per (head, comment): the same comment is never read twice. No dequeue
#   comment for this head is `none` and is not cached: Mergify may post it
#   later.
#   rc 2 a failing run's jobs or log could not be read: the batch may still be
#        a no-verdict one (nothing is cached)
#   rc 3 nothing here can classify it: the readers are not loaded, or
#        fr_dequeue_batch answered rc 2 (the comments could not be read, or a
#        failing check is not an Actions run, which no shard can explain).
#        The caller's own rule reads the same comment and decides.
nv_batch_word() {
  local slug="$1" num="$2" key="$3" head="$4" b d ids ck line w s id out rc any_unread=0 sh=""
  NV_WORD=""; NV_CID=""; NV_DRAFT=""; NV_RUNS=""; NV_SHARDS=""
  command -v fr_dequeue_batch >/dev/null 2>&1 && command -v gh_ci_api >/dev/null 2>&1 || return 3
  rc=0; b=$(fr_dequeue_batch "$slug" "$num" "$head") || rc=$?
  case "$rc" in 0) ;; 1) NV_WORD=none; return 0 ;; *) return 3 ;; esac
  IFS=$'\t' read -r d ids ck <<<"$b"
  NV_CID="${ck%%@*}"; [ -n "$NV_CID" ] && [ "$NV_CID" != - ] || return 3
  [ "$d" = - ] || NV_DRAFT="$d"
  if [ -s "${MC_ATTEMPTS:-}" ] && line=$(grep -m1 -F "nvv $key $head $NV_CID " "$MC_ATTEMPTS" 2>/dev/null) && [ -n "$line" ]; then
    read -r _ _ _ _ w d ids s <<<"$line"
    case "$w" in noverdict|real|none) ;; *) return 3 ;; esac
    NV_WORD="$w"; [ "$d" = - ] || NV_DRAFT="$d"; [ "$ids" = - ] || NV_RUNS="$ids"; [ "$s" = - ] || NV_SHARDS="$s"
    return 0
  fi
  if [ "$ids" = - ]; then
    w=none
  else
    w=noverdict
    for id in $ids; do
      rc=0; out=$(nv_run_word "$slug" "$id") || rc=$?
      if [ "$rc" != 0 ]; then any_unread=1; continue; fi
      case "${out%%$'\t'*}" in
        noverdict) sh="${sh:+$sh,}${out#*$'\t'}" ;;
        *) w=real; break ;;
      esac
    done
    [ "$w" = real ] || [ "$any_unread" = 0 ] || return 2
    NV_RUNS="${ids// /,}"
    [ "$w" = noverdict ] && NV_SHARDS=$(tr ',' '\n' <<<"$sh" | sort -t/ -k1,1n -u | paste -sd, -)
  fi
  NV_WORD="$w"
  mc_attempt_put "nvv $key $head $NV_CID $w ${NV_DRAFT:--} ${NV_RUNS:--} ${NV_SHARDS:--}"
  return 0
}

# nv_gate <owner/repo> <num> <key> <head> <raw mergeState> — sets FR_LINE /
#   FR_WHY / FR_FLAKES like fr_reentry_gate.
#   rc 0 may re-queue: every failing run left no verdict, the head is green,
#        the freeze is down (FR_LINE is the PR line)
#   rc 1 no-verdict, but wait: the main-red freeze (FR_WHY), or a head whose
#        own checks are not green (the arm's own reason)
#   rc 2 a failing run of the batch could not be read this tick (FR_WHY)
#   rc 3 not a no-verdict batch, nothing here can classify it, or the third
#        unread tick: the caller decides exactly as before
#   The verdict of a head is read once: a cached `nvv` line answers later
#   ticks without a read.
nv_gate() {
  local slug="$1" num="$2" key="$3" head="$4" ms="$5" line rc n w d ids s
  FR_LINE=""; FR_WHY=""
  NV_WORD=""
  if [ -s "${MC_ATTEMPTS:-}" ] && line=$(grep -m1 -F "nvv $key $head " "$MC_ATTEMPTS" 2>/dev/null) && [ -n "$line" ]; then
    read -r _ _ _ NV_CID w d ids s <<<"$line"
    NV_WORD="$w"; NV_DRAFT="$d"; NV_RUNS="$ids"; NV_SHARDS="$s"
    [ "$d" = - ] && NV_DRAFT=""; [ "$ids" = - ] && NV_RUNS=""; [ "$s" = - ] && NV_SHARDS=""
  else
    rc=0; nv_batch_word "$slug" "$num" "$key" "$head" || rc=$?
    [ "$rc" = 3 ] && return 3
    if [ "$rc" != 0 ]; then
      n=$(mc_attempt_count nvunread "$key" "$head")
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      if [ "$n" -ge 2 ]; then
        _bej_log_once NOVERDICT_UNREAD "$key" "$head" "whether its batch left no verdict could not be read on 3 ticks; #4428's rule decides"
        return 3
      fi
      mc_attempt_put_n nvunread "$key" "$head"
      w="its batch"; [ -n "$NV_DRAFT" ] && w="batch draft #$NV_DRAFT"
      FR_WHY="queue-ejected — whether $w left no verdict could not be read this tick; asked again next tick"
      return 2
    fi
  fi
  [ "$NV_WORD" = noverdict ] || return 3
  if [ -n "${MAIN_RED:-}" ]; then
    FR_WHY="queue-ejected — main-red freeze is on; re-queued when it lifts"
    return 1
  fi
  _bej_head_green "$slug" "$head" "$ms" || return 1
  FR_FLAKES=""
  FR_LINE="re-queued: Mergify's batch draft #${NV_DRAFT:-?} failed only because CI shard(s) ${NV_SHARDS//,/, } left no verdict (cancelled, or died before its scan finished). That is an infra retry, not a failure of this PR. This head gets one retry."
  _bej_log_once NOVERDICT_RETRY "$key" "$head" "draft #${NV_DRAFT:-?} run ${NV_RUNS:-?}: shard(s) ${NV_SHARDS:-?} left no verdict; an infra retry: one requeue allowed, no fix round"
  return 0
}

# nv_twice_note <project> <owner/repo> <key> <head> <url> -> rc 0
#   Asked by mc_eject_fix_now for every queue-ejected-twice park. Acts once per
#   head, and only on a head this lib re-queued for no verdict (an `nvv …
#   noverdict` line and the arm's `requeued` mark). The NEWEST dequeue for the
#   head is classified:
#     noverdict  `nvtwice` first, then ONE critical mc_alert
#     real/none  `nvtwice`, no alert (a real failure takes the resolver ladder)
#     unread, or still the first dequeue's comment: nothing marked, asked again
#                on the next tick; the third such tick marks `nvtwice` and
#                sends the alert with "could not be confirmed" wording
#   The fix round itself is unchanged: mc_eject_fix_now goes on as before.
nv_twice_note() {
  local slug="$2" key="$3" head="$4" url="$5" first fcid fd rc n d2
  [ -n "$key" ] && [ -n "$head" ] && [ -s "${MC_ATTEMPTS:-}" ] || return 0
  mc_attempt_has "nvtwice $key $head" 2>/dev/null && return 0
  first=$(grep -m1 -E "^nvv $key $head [^ ]+ noverdict " "$MC_ATTEMPTS" 2>/dev/null) || return 0
  [ -n "$first" ] && [ -n "$(mc_requeued_mark "$key" "$head")" ] || return 0
  read -r _ _ _ fcid _ fd _ <<<"$first"
  rc=0; nv_batch_word "$slug" "${key##*#}" "$key" "$head" || rc=$?
  # The first dequeue's own comment is no answer about the second ejection.
  [ "$rc" = 0 ] && [ "$NV_CID" = "$fcid" ] && rc=2
  if [ "$rc" = 0 ]; then
    mc_attempt_put "nvtwice $key $head"
    [ "$NV_WORD" = noverdict ] || return 0
    d2="${NV_DRAFT:-?}"
    command -v mc_alert >/dev/null 2>&1 && mc_alert "$key" BLOCKED_HUMAN \
      "$url left no verdict twice on ${head:0:12} (batch drafts #$fd, #$d2; shard(s) ${NV_SHARDS:-?}). A CI runner is failing. This is an infra incident, not this PR." crit
    _bej_log_once NOVERDICT_TWICE "$key" "$head" "drafts #$fd and #$d2 both left no verdict (shard(s) ${NV_SHARDS:-?}); one alert sent, the resolver ladder goes on"
    return 0
  fi
  n=$(mc_attempt_count nvtwiceunread "$key" "$head")
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt 2 ]; then
    mc_attempt_put_n nvtwiceunread "$key" "$head"
    mc_log "$key queue-ejected-twice after a no-verdict retry: the second batch could not be read (read $((n + 1)) of 3); asked again next tick"
    return 0
  fi
  mc_attempt_put "nvtwice $key $head"
  command -v mc_alert >/dev/null 2>&1 && mc_alert "$key" BLOCKED_HUMAN \
    "$url was ejected again on ${head:0:12} after a no-verdict retry (batch draft #$fd). Whether the second batch also left no verdict could not be confirmed. Check the CI runners." crit
  _bej_log_once NOVERDICT_TWICE "$key" "$head" "ejected again after a no-verdict retry (draft #$fd); the second batch could not be read on 3 ticks; one alert sent"
  return 0
}
