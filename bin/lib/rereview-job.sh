#!/bin/bash
# bin/lib/rereview-job.sh — the MACHINE side of a pool re-review (BH-7635).
# Sourced, never executed: no `set -e`, no `exit`, no output and no file written
# at source time. fly/builder-runner.sh's run_rereview_job is its one caller.
#
# WHAT THIS FILE IS. A lane-run machine cannot run the conductor's detached
# re-review: the job file would never reach the hub. So the re-review is queued
# as a pool row, the same way a rebase is (bin/lib/rebase-job.sh), and a pool
# machine runs it here. The hub half is mc_pool_rereview_apply
# (bin/lib/mc/rebase.sh), which turns the RESULT below into the job file the
# conductor's headbound_review already reads.
#
# THE JOB the runner reads (bin/lib/queue-row-job.sh writes it from the row):
#
#   {
#     "key": "RR-<num>-<head8>",          # mc_pool_rereview_key
#     ...
#     "rereview": {
#       "kind": "rereview", "slug": "owner/repo",
#       "url": "https://github.com/owner/repo/pull/<num>", "pr": <num>,
#       "reviewed": "<40 hex>|-", "head": "<40 hex>",
#       "reason": ""|"noverdict"|"prov", "dedup": "..."
#     }
#   }
#
# THE RESULT the hub reads back. Line 1 is one of these words, and nothing else
# is a RESULT (bin/result-prefix-ok.sh is the gate):
#
#   REREVIEWED APPROVE|BLOCK          mc_rereview rc 0, a verdict
#   REREVIEW_NOVERDICT                rc 1 (or rc 0 with no verdict word)
#   REREVIEW_LANE_FAILED <why>        rc 2, or a review body over the cap
#   REREVIEW_DEFERRED <why>           rc 3, the call-guard refused the read
#   REREVIEW_SETUP_FAILED <why>       the job was refused before any read
#
# then, one per line, in this order:
#
#   PR: <url>
#   HEAD: <head>
#   REVIEWED: <reviewed|->
#   REASON: <reason|->
#   MODEL: <first line of out.model|->
#   RUNNER: <first line of out.runner|->
#
# and ONLY after REREVIEWED, the line `--- review ---` and the review text
# verbatim. The FIRST such line splits the RESULT; a review that quotes it is
# kept whole. A body over RR_JOB_BODY_MAX bytes (262144) is never cut: line 1
# becomes `REREVIEW_LANE_FAILED review body over <n> bytes` and no body is
# written, so the hub retries the read instead of posting half a review.
#
# ONE READ AT MOST. mc_rereview runs exactly once, under the call-guard fp
# `review:<slug>#<num>@<head>[~reason]` the hub job uses, so a repeat of the
# same head is refused before it is billed. The job writes nothing to GitHub.
#
# rereview_job_run <slug> <num> <project> <url> <reviewed> <head> <reason> <result-file> [<harness>]
#   Writes <result-file>. rc 0 only on REREVIEWED.
rereview_job_run() {
  local slug="${1:-}" num="${2:-}" project="${3:-}" url="${4:-}" rev="${5:-}" head="${6:-}" reason="${7:-}" rf="${8:-}"
  local harness="${9:-${HARNESS:-}}" max="${RR_JOB_BODY_MAX:-262144}"
  local line="" bad="" wd="" out="" v="" rc=0 why model="-" runner="-" sz body=0 lib
  [ -n "$rf" ] || return 1
  [ -n "$rev" ] || rev="-"
  # --- 1. the job's fields, before any read -----------------------------------
  case "$num" in ''|*[!0-9]*) bad=num ;; esac
  case "$slug" in ''|*[!A-Za-z0-9._/-]*) bad=slug ;; esac
  case "$head" in ''|*[!0-9a-f]*) bad=head ;; *) [ "${#head}" = 40 ] || bad=head ;; esac
  case "$rev" in -) ;; ''|*[!0-9a-f]*) bad=reviewed ;; *) [ "${#rev}" = 40 ] || bad=reviewed ;; esac
  case "$reason" in ''|noverdict|prov) ;; *) bad=reason ;; esac
  [ -n "$url" ] || url="https://github.com/$slug/pull/$num"
  [ -n "$bad" ] && line="REREVIEW_SETUP_FAILED $bad"
  # --- 2. the conductor lib, from the HARNESS copy ----------------------------
  # Probed in a subshell first: the lib `exit 1`s when its mc/ modules do not
  # load, and a sourced exit would end the runner.
  if [ -z "$line" ] && ! type mc_rereview >/dev/null 2>&1; then
    lib="$harness/bin/lib/merge-conductor-lib.sh"
    if [ -n "$harness" ] && [ -r "$lib" ] && ( HARNESS="$harness"; . "$lib" ) >/dev/null 2>&1 </dev/null; then
      mkdir -p "$harness/logs" >/dev/null 2>&1
      local HARNESS="$harness"
      # shellcheck source=bin/lib/merge-conductor-lib.sh
      . "$lib" >/dev/null 2>&1
    fi
    type mc_rereview >/dev/null 2>&1 || line="REREVIEW_SETUP_FAILED no conductor lib"
  fi
  # --- 3. the one read ---------------------------------------------------------
  if [ -z "$line" ]; then
    wd=$(mktemp -d "${TMPDIR:-/tmp}/rereview-job.XXXXXX" 2>/dev/null) || line="REREVIEW_SETUP_FAILED no temp dir"
  fi
  if [ -z "$line" ]; then
    out="$wd/review.out"
    v=$(MC_RR_REASON="$reason" mc_rereview "$slug" "$num" "$project" "$url" "$rev" "$head" "" "$out"); rc=$?
    why=$(head -1 "$out.lanefail" 2>/dev/null)
    case "$rc:$v" in
      0:APPROVE|0:BLOCK) line="REREVIEWED $v"; body=1 ;;
      0:*|1:*) line="REREVIEW_NOVERDICT" ;;
      2:*) line="REREVIEW_LANE_FAILED ${why:-the review lane failed}" ;;
      3:*) line="REREVIEW_DEFERRED ${why:-call-guard repeat}" ;;
      *)   line="REREVIEW_LANE_FAILED mc_rereview answered rc $rc" ;;
    esac
    [ -s "$out.model" ] && model=$(head -1 "$out.model")
    [ -s "$out.runner" ] && runner=$(head -1 "$out.runner")
    if [ "$body" = 1 ]; then
      sz=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
      if [ -z "$sz" ] || [ "$sz" = 0 ]; then line="REREVIEW_LANE_FAILED the review text is empty"; body=0
      elif [ "$sz" -gt "$max" ]; then line="REREVIEW_LANE_FAILED review body over $max bytes"; body=0; fi
    fi
  fi
  # --- 4. ONE write, temp then mv, so a reader never sees half a RESULT --------
  {
    printf '%s\nPR: %s\nHEAD: %s\nREVIEWED: %s\nREASON: %s\nMODEL: %s\nRUNNER: %s\n' \
      "$line" "$url" "${head:--}" "$rev" "${reason:--}" "$model" "$runner"
    if [ "$body" = 1 ]; then printf -- '--- review ---\n'; cat "$out"; fi
  } > "$rf.tmp" 2>/dev/null && mv -f "$rf.tmp" "$rf"
  # A VERDICT IS TERMINAL (BH-2358), the same row mc_rereview_run writes: a lost
  # job file never buys this head again. Only when the verdict reached the RESULT.
  if [ "$body" = 1 ]; then
    ( [ -r "$harness/bin/jobs-client.sh" ] && ! declare -F _jobs_req >/dev/null 2>&1 && . "$harness/bin/jobs-client.sh"
      command -v mc_rows_twin_on >/dev/null 2>&1 && mc_rows_twin_on && mc_attempt_put "rrjob $slug#$num $head done" ) >/dev/null 2>&1
  fi
  [ -n "$wd" ] && rm -rf "$wd"
  [ "$body" = 1 ]
}
