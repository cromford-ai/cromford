#!/bin/bash
# shellcheck shell=bash
# bin/lib/queue-row-job.sh — ONE `build_queue` row -> ONE job.json (BH-1026.3).
# Sourced by bin/fly-dispatch.sh and bin/fly-pool.sh, never run.
#
# WHY IT IS A LIBRARY AND NOT A SECOND COPY. This is the mapping
# bin/fly-dispatch.sh has carried inline since 2026-09-10: the field extraction,
# the two rebase-meta shapes normalised into one object, and the CHARSET REFUSAL
# that stops a row whose `branch` is `x;rm -rf` from reaching a git command on a
# builder. Under `build_queue_rows_only` three callers need exactly that mapping
# — the dispatcher's flag-off materialise, its flag-on single-machine dispatch,
# and the pool's per-tick materialise — and three copies of a security check are
# three chances for two of them to drift.
#
# THE FLAG-OFF FILE IS BYTE-FOR-BYTE THE ONE THE INLINE CODE WROTE. Every field
# that was absent then is absent now: `deaths` is emitted only when the row's
# meta carries it (the pool's death requeue does; nothing else ever has), and
# `rebuild` only when the meta carries `blocked_resolver`.
# tests/fly-lane-db-test.sh, tests/hotfix-cap-exempt-test.sh, tests/stacked-child-builds-test.sh and
# tests/rebase-on-pool-reap.bh-542-test.sh pin that.

# queue_row_job_file <project> <dest> <key> <ticket_id> <attempt> <meta-json>
#   <dest> is the job file to write, or `-` to VALIDATE ONLY and write nothing
#   (the rows path refuses a bad rebase row before any claim, and must not leave
#   a file behind while doing it).
#   rc 0 -> written (or validated, for `-`)
#   rc 3 -> REFUSED. The row is closed `failed` through queue_done when the
#           client is there, one line is appended to ALERTS.log, and the one-line
#           `say` text is printed on stdout for the caller's own log.
#   rc 1 -> the jq or the mv failed, or the arguments were unusable. Nothing was
#           written; the CALLER owns handing the row back (it is the one that
#           knows whether it had claimed it).
queue_row_job_file() {
  local project="${1:-}" dest="${2:-}" key="${3:-}" ticket="${4:-}" attempt="${5:-}" meta="${6:-}"
  local h="${HARNESS:-/root/harness}" tag="${QRJ_TAG:-fly-dispatch/${1:-}}"
  local ts def sb hf fs rb bad bf bv dth tmp brs cb
  [ -n "$project" ] && [ -n "$dest" ] && [ -n "$key" ] || return 1
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  case "${ticket:-}" in -) ticket="" ;; esac
  case "${attempt:-}" in ''|*[!0-9]*) attempt=0 ;; esac
  # VALIDATE-ONLY SKIPS THE FIELDS IT WILL NOT WRITE. The dispatcher's rows path
  # asks this question of EVERY queued row on EVERY tick, and four extra `jq`
  # processes per row per tick is a cost with no reader — the only thing a
  # validate-only call can answer is the rebase refusal.
  if [ "$dest" = "-" ]; then def=0; dth=""; sb=""; hf=false; fs=false; brs=false; cb=""
  else
    # `deferrals` is the stand-down count, carried in the row's meta so it
    # survives this hub-side round trip; `attempt` stays the death count. Losing
    # it here would reset bin/fly-pool.sh's cap on every materialise.
    def=$(printf '%s' "${meta:-}" | jq -r '.deferrals // 0' 2>/dev/null)
    case "${def:-}" in ''|*[!0-9]*) def=0 ;; esac
    # `deaths` is the count bin/fly-pool.sh's reap OBSERVED, and it only ever
    # appears on a requeue that reap wrote. Absent -> no field, which is what
    # every file this mapping wrote before carried.
    dth=$(printf '%s' "${meta:-}" | jq -r '.deaths // ""' 2>/dev/null)
    case "${dth:-}" in ''|*[!0-9]*) dth="" ;; esac
    # `stack_base` travels the same way and for the same reason (2026-09-14,
    # stacked child builds): the watcher that decided this ticket is buildable on
    # top of an open parent PR knows the branch, and the machine that will build it
    # is two hops away. A bad value drops to "no field" — a child built against
    # main is still the build that was asked for.
    sb=$(printf '%s' "${meta:-}" | jq -r '.stack_base // ""' 2>/dev/null)
    case "${sb:-}" in *[!A-Za-z0-9._/-]*) sb="" ;; esac
    # `hotfix` rides the row meta the same way (#368): a flag lost in this hop is
    # an emergency that arrives at the pool as ordinary work.
    hf=$(printf '%s' "${meta:-}" | jq -r '.hotfix // false' 2>/dev/null)
    case "${hf:-}" in true) hf=true ;; *) hf=false ;; esac
    # `fresh_spawn` likewise (BH-5025.2): a hotfix that deferred on a reused
    # machine, which the pool's reuse handoff leaves for a fresh spawn.
    fs=$(printf '%s' "${meta:-}" | jq -r '.fresh_spawn // false' 2>/dev/null)
    case "${fs:-}" in true) fs=true ;; *) fs=false ;; esac
    # `rebuild` (BH-6350): a blocked-resolver rebuild (br_enqueue_fresh puts
    # `blocked_resolver` in the row meta) is a ticket that was admitted once
    # already, so the pool's dispatch-mode filter (dm_job_admit) lets it pass.
    brs=$(printf '%s' "${meta:-}" | jq -r 'if type == "object" then ((.blocked_resolver // "") | tostring) else "" end' 2>/dev/null)
    case "${brs:-}" in ''|null|false) brs=false ;; *) brs=true ;; esac
    # `continue_branch` (BH-6821): the pool reap requeued a build whose push was
    # rejected on a remote that diverged, and the next one starts from the
    # remote head. It reaches `git` on the machine as TARGET_BRANCH, so a value
    # outside the stack_base charset is REFUSED, not dropped: a build that lost
    # it would push over the same diverged branch again.
    cb=$(printf '%s' "${meta:-}" | jq -r 'if type == "object" then (.continue_branch // "") else "" end' 2>/dev/null)
    case "${cb:-}" in
      *[!A-Za-z0-9._/-]*)
        command -v queue_done >/dev/null 2>&1 \
          && { queue_done "$project" "$key" failed "continue_branch rejected (charset)" >/dev/null 2>&1 || true; }
        [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" \
          "[$tag] $key: this row's continue_branch is not a branch name — the row is closed FAILED and NO queue file was written."
        printf '%s: continue_branch rejected — row closed failed, no queue file written\n' "$key"
        return 3 ;;
    esac
  fi
  # `rebase` is the WHOLE meta object, carried across in one piece (BH-486.2,
  # #542). Under REBASE_ON_POOL the conductor's enqueue writes a row whose meta
  # IS the job — {kind,slug,url,pr,branch,head,base} — and bin/lib/rebase-job.sh
  # documents the machine reading it back as a top-level `rebase:{...}` on
  # job.json. Re-serialising through jq is both the shape the runner expects and
  # the sanitation jq gives for free.
  #
  # TWO META SHAPES, ONE NORMALISED OBJECT. The producer writes the fields FLAT,
  # which is what mc_pool_rebase_enqueue sends; bin/lib/merge-conductor-lib.sh's
  # own comment still documents the NESTED form ({kind:"rebase",rebase:{…}}).
  # Both are accepted and collapsed to the flat object BEFORE the charset checks,
  # so a nested row is validated — and refused on a bad field — exactly like a
  # flat one, rather than failing as "slug missing".
  rb=""
  if [ "$(printf '%s' "${meta:-}" | jq -r 'if type=="object" then (.kind // "") else "" end' 2>/dev/null)" = rebase ]; then
    rb=$(printf '%s' "$meta" | jq -c 'select(type=="object") | if (.rebase|type)=="object" then (.rebase + {kind:"rebase"}) else . end' 2>/dev/null)
    bad=""
    # The same charset `stack_base` is held to, on every field that reaches a git
    # command on the machine; `pr` is a number and nothing else. `url` is exempt
    # on purpose: it rides jq-encoded into job.json and bin/lib/rebase-job.sh
    # never hands it to git or curl, and the charset here would reject every
    # `https://`.
    for bf in slug branch base head; do
      bv=$(printf '%s' "$rb" | jq -r --arg f "$bf" '.[$f] // ""' 2>/dev/null)
      case "$bv" in ''|*[!A-Za-z0-9._/-]*) bad="$bf" ;; esac
    done
    bv=$(printf '%s' "$rb" | jq -r '.pr // ""' 2>/dev/null)
    case "$bv" in ''|*[!0-9]*) bad=pr ;; esac
    if [ -n "$bad" ]; then
      # AN UNUSABLE REBASE OBJECT IS REFUSED, NOT DROPPED. Dropping it would
      # leave {ticket_id:"21",key:"RB-21-…"} — which the pool dispatches as an
      # ordinary BUILD of "ticket 21" of this project, with a PR and a board
      # comment nobody asked for. So the row is closed `failed` (a release would
      # re-offer the same bad row every two minutes forever), it says so once in
      # ALERTS.log, and no queue file is written.
      command -v queue_done >/dev/null 2>&1 \
        && { queue_done "$project" "$key" failed "rebase meta rejected ($bad)" >/dev/null 2>&1 || true; }
      mkdir -p "$h/logs" 2>/dev/null
      echo "$ts [$tag] $key: this row's rebase meta is unusable (field '$bad') — the row is closed FAILED and NO queue file was written, because a rebase job that lost its rebase object is dispatched as an ordinary build of ticket ${ticket:-?}. Fix the producer (mc_pool_rebase_enqueue in bin/lib/merge-conductor-lib.sh)." >> "$h/logs/ALERTS.log"
      printf '%s: rebase meta rejected (field %s) — row closed failed, no queue file written\n' "$key" "'$bad'"
      return 3
    fi
  fi
  # VALIDATE-ONLY: the rows path asks this function the refusal question before
  # anything is claimed, and must not leave a file behind asking it.
  [ "$dest" = "-" ] && return 0
  # Dot-prefixed temp then mv, exactly as the scp path does: bin/fly-pool.sh runs
  # on the same */2 cron and its *.json glob must never see a partial file (it
  # read TK-730.json as empty and quarantined a valid job, 2026-08-17).
  tmp="$(dirname "$dest")/.$(basename "$dest").db"
  jq -nc --arg t "$ticket" --arg k "$key" --argjson a "$attempt" --argjson d "$def" \
     --arg ts "$ts" --arg sb "${sb:-}" --arg hf "${hf:-false}" --arg rb "${rb:-}" \
     --arg dx "${dth:-}" --arg fs "${fs:-false}" --arg rbd "${brs:-false}" --arg cb "${cb:-}" \
       '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,enqueued_at:$ts,source:"db"}
        + (if $sb == "" then {} else {stack_base:$sb} end)
        + (if $cb == "" then {} else {continue_branch:$cb} end)
        + (if $hf == "true" then {hotfix:true} else {} end)
        + (if $fs == "true" then {fresh_spawn:true} else {} end)
        + (if $rbd == "true" then {rebuild:true} else {} end)
        + (if $rb == "" then {} else {rebase:($rb|fromjson)} end)
        + (if $dx == "" then {} else {deaths:($dx|tonumber)} end)' > "$tmp" \
    && mv "$tmp" "$dest" && return 0
  rm -f "$tmp"
  return 1
}
