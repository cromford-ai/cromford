#!/bin/bash
# bin/lib/verdicts.sh — BH-1525: the ONE reader of the `verdicts` table for
# every merge lane. Sourced (by bin/lib/block-gate.sh, so every lane that has
# the conductor lib has it), never executed.
#
# WHAT IT REPLACES. A lead verdict reached the merge lanes as two FILES the
# Mac's tooling wrote on the hub over SSH: state/review-autopilot/<slug>-<pr>-
# <sha12> (read by mc_autopilot_verdict) and a `provcleared <slug>#<pr> <sha>`
# line in state/merge-conductor/attempts.txt (read by mc_prov_cleared). Those
# two readers now ask the table FIRST; mc_prov_cleared keeps its line as the
# fallback, and mc_autopilot_verdict no longer reads the file at all (BH-1951:
# rows — vd_clear_word, then vd_box_word — then the PR comment), and
# the block gate (bg_scan_read) asks it for a BLOCK, so a lead/human BLOCK on
# the live head stops every lane that merges — the conductor, merge-sweep, the
# box merge queue (and through it the tier-2 sweep, which only enqueues),
# batch-resolve and the tier-1 gate — even when a box review said APPROVE.
#
# BOUND TO THE LIVE HEAD. Every function takes the head the caller is about to
# act on and asks the worker for the row standing on THAT sha. A push is a new
# sha with no row, so a verdict never outlives the code it read.
#
# STANDING = the newest lead/human row on the head (worker/jobs/src/routes/
# verdicts.js decides it, in SQL). A box row is history and never stands.
# BH-8349: a final human row on the head stands over any newer lead row.
#
# UNREADABLE IS rc 2, AND WHAT IT MEANS DEPENDS ON THE QUESTION (BH-1525 r2).
# An unreachable worker, no HARNESS_SECRET, a non-2xx answer, or a head that
# is not a full sha answers rc 2 and is logged (logs/verdicts.log). A process
# with no jobs client loaded at all answers rc 1 (see vd_standing).
#   * THE MERGE DECISION FAILS CLOSED. vd_block_line hands rc 2 to the block
#     gate, which answers "could not read verdicts": every lane skips the merge
#     for this tick — no park, no relabel, no dequeue — and asks again next
#     tick, the gh-rest rc-75 rule ("unverifiable = skip the tick"). A worker
#     outage therefore holds merges, loudly (bg_streak_note alerts at K ticks),
#     instead of letting one land over a BLOCK nobody could read.
#   * EXCEPT THE WORKER'S OWN 404, WHICH IS "NOT DEPLOYED" (review F2 on #1536,
#     narrowed in round 3). The route itself answers 400/503, never 404, so the
#     jobs worker's own unknown-endpoint answer — the body {"error":"unknown
#     endpoint"} exactly (a worker older than BH-1525), or that plus
#     "worker":"harness-jobs" (every worker since) — means this worker has no
#     /api/verdicts, and no row can have been written through it. ANY OTHER 404
#     is not proof of anything: a deleted or mistyped JOBS_URL host behind
#     Cloudflare answers 404 "error code: 1042", a proxy or CDN answers HTML,
#     and reading those as "no verdict" would pass every lane over a lead BLOCK.
#     They are rc 2 like any other unreadable answer. bin/ ships
#     ahead of the worker (#1548), after a failed worker deploy, or past a
#     rollback. That is rc 1, "no standing verdict": the merge proceeds on its
#     other gates, and ONE line per lane per hour names the missing route.
#     Transport failures, timeouts, 5xx, 401/403 and malformed answers stay rc 2.
#   * THE CLEARANCE READS FAIL OPEN. vd_clears answers "not cleared" and
#     mc_prov_cleared falls back to its hub line; mc_autopilot_verdict falls
#     to the PR comment read (never to a file, BH-1951). Both are the
#     conservative direction already: no clear, no merge.
#
# NOT MEMOISED. Every caller reaches this through a command substitution, where
# a cached answer would die with the subshell; one GET per question is the
# honest cost (at most three per PR per conductor tick, only on PRs that got as
# far as a merge decision).

_vd_home() { printf '%s' "${HARNESS:-${MC_H:-/root/harness}}"; }
_vd_log() {
  mkdir -p "$(_vd_home)/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [verdicts] $*" >> "$(_vd_home)/logs/verdicts.log" 2>/dev/null
}
# _vd_worker_404 <body> — rc 0 when the body is EXACTLY the jobs worker's own
#   unknown-endpoint 404: {"error":"unknown endpoint"} (a pre-BH-1525 worker) or
#   {"error":"unknown endpoint","worker":"harness-jobs"}. No other key, no other
#   value: anything else was not written by this worker.
_vd_worker_404() {
  printf '%s' "${1:-}" | jq -e 'type == "object"
    and .error == "unknown endpoint"
    and ((keys - ["error","worker"]) == [])
    and ((has("worker") | not) or .worker == "harness-jobs")' >/dev/null 2>&1
}

# _vd_route_missing — the 404 line, once per lane (the script that sourced this)
#   per UTC hour, keyed by a stamp file so every subshell of one tick shares it.
_vd_route_missing() {
  local lane stamp
  lane=$(basename "${0:-lane}" .sh | tr -c 'A-Za-z0-9._-' '_')
  stamp="$(_vd_home)/state/verdicts/route-missing-$lane-$(date -u +%Y%m%d%H)"
  [ -e "$stamp" ] && return 0
  mkdir -p "${stamp%/*}" 2>/dev/null && : > "$stamp" 2>/dev/null
  _vd_log "GET /api/verdicts is not deployed on ${JOBS_URL:-the jobs worker} (HTTP 404) — lane $lane treats every PR as having no standing verdict until the worker ships BH-1525; said once per lane per hour"
}

# _vd_client <label> — load the jobs client if the caller did not; rc 1 (logged)
#   when there is none to load.
_vd_client() {
  # THE CLIENT IS LOADED HERE IF THE CALLER DID NOT (BH-1525 r2), so "no
  # client" can never be a lane that merely forgot to source it: every merge
  # lane already does (conductor, merge-sweep, merge-queue, tier-2, review-prs,
  # batch-resolve, run-build), and this is the backstop. Both the client and
  # its bin/lib/jobs/ modules must be there first — jobs-client.sh exits when a
  # module is missing, which inside this function would read as "no block".
  if ! command -v _jobs_req >/dev/null 2>&1 && [ -r "$(_vd_home)/bin/jobs-client.sh" ] \
     && [ -r "$(_vd_home)/bin/lib/jobs/req.sh" ]; then
    # shellcheck source=/dev/null
    . "$(_vd_home)/bin/jobs-client.sh" 2>/dev/null
  fi
  # NO CLIENT FILE AT ALL = THE CHECK IS NOT WIRED INTO THIS PROCESS, not an
  # outage: a tree with no bin/jobs-client.sh cannot reach the worker for
  # anything (a test that sources block-gate.sh on its own, or a broken
  # install, which fails far louder elsewhere). rc 1, logged.
  command -v _jobs_req >/dev/null 2>&1 || { _vd_log "$1: no jobs client under $(_vd_home)/bin — verdict check not wired here"; return 1; }
}

# _vd_get <label> <path-and-query> — ONE verdicts GET and its 404 judgement,
#   shared by vd_standing and vd_box_word so the two cannot drift.
#   rc 0 + the body on stdout | rc 1 the worker's own 404 (route not deployed,
#   said once per lane per hour) | rc 2 anything else unreadable (logged).
_vd_get() {
  local label="$1" tmp rc
  # _jobs_req runs in THIS shell (its answer goes through a file, not a command
  # substitution) so JOBS_HTTP / JOBS_BODY are readable for the 404 judgement.
  tmp=$(mktemp "${TMPDIR:-/tmp}/verdicts.XXXXXX") || { _vd_log "$label: mktemp failed — unverifiable"; return 2; }
  JOBS_ALERT=0 _jobs_req GET "$2" > "$tmp"; rc=$?
  # _jobs_req's rc 2 is an HTTP 404 (bin/lib/jobs/req.sh); only the WORKER'S
  # OWN unknown-endpoint body is "not deployed" — see the header.
  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    if [ "${JOBS_HTTP:-}" = 404 ] && _vd_worker_404 "${JOBS_BODY:-}"; then _vd_route_missing; return 1; fi
    _vd_log "$label: HTTP 404 that is not the jobs worker's own answer (body: $(printf '%s' "${JOBS_BODY:-}" | tr -d '\n' | head -c 80)) — unverifiable; check JOBS_URL"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    _vd_log "$label: verdicts read failed (transport, 5xx, 401/403 or no secret; see logs/jobs-client.log) — unverifiable"
    return 2
  fi
  cat "$tmp"; rm -f "$tmp"
}

# vd_standing <owner/repo> <num> <head-sha>
#   rc 0 -> prints one TSV line: verdict, source, id, created_at, report_url|-, reviewer|-
#   rc 1 -> nothing stands on this head
#   rc 2 -> could not ask (no secret, worker down, non-2xx, or a head that is
#           not a full sha — a row binds to a full sha, so an unread or short
#           head cannot be checked against one)
vd_standing() {
  local slug="$1" num="$2" head resp rc line
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  case "$slug" in */*) ;; *) return 1 ;; esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  _vd_client "$slug#$num" || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _vd_log "$slug#$num: head '${head:-<unread>}' is not a full sha — unverifiable"; return 2; }
  resp=$(_vd_get "$slug#$num ${head:0:8}" "/api/verdicts?repo=$slug&pr=$num&head=$head&standing_only=1"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  line=$(printf '%s' "$resp" | jq -r '.standing // empty
    | [.verdict, .source, (.id|tostring), .created_at, (.report_url // "-"), (.reviewer // "-")] | @tsv' 2>/dev/null) \
    || { _vd_log "$slug#$num ${head:0:8}: unparseable verdicts answer — unverifiable"; return 2; }
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# vd_clear_word <owner/repo> <num> <head> — prints MERGE or MERGE-WITH-NOTES when
#   that is the standing verdict on this head; nothing (rc 1) otherwise. A
#   standing BLOCK prints nothing HERE on purpose: the conductor's autopilot arm
#   would route a BLOCK to the blocked-resolver's agent fix round, and a lead's
#   BLOCK is the lead's to act on. The BLOCK is enforced by the block gate.
vd_clear_word() {
  local line v
  line=$(vd_standing "$@") || return 1
  v=$(cut -f1 <<<"$line")
  case "$v" in MERGE|MERGE-WITH-NOTES) printf '%s' "$v"; return 0 ;; esac
  return 1
}

# vd_clears <owner/repo> <num> <head> — rc 0 when a lead/human MERGE or
#   MERGE-WITH-NOTES stands on this head (what `provcleared` recorded).
vd_clears() { vd_clear_word "$@" >/dev/null; }

# vd_box_word <owner/repo> <num> <head> — BH-1951: the verdict of the NEWEST
#   `source=box` row on THIS exact head (bin/review-autopilot.sh writes one per
#   posted review), which is what mc_autopilot_verdict reads in place of the
#   hub file state/review-autopilot/<key>. It is a read of history, not of
#   standing: a box row never stands (the worker's SQL decides that), so
#   vd_block_line never answers from one and a box BLOCK stops nothing here.
#   rc 0 + the word | rc 1 no box row on this head (a `truncated:true` history
#   with no match too, logged), no client, or the worker's own 404 | rc 2
#   unreadable — the same contract as vd_standing.
vd_box_word() {
  local slug="$1" num="$2" head resp rc v trunc
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  case "$slug" in */*) ;; *) return 1 ;; esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  _vd_client "$slug#$num" || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _vd_log "$slug#$num: head '${head:-<unread>}' is not a full sha — unverifiable"; return 2; }
  resp=$(_vd_get "$slug#$num ${head:0:8}" "/api/verdicts?repo=$slug&pr=$num&head=$head"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # .rows are id DESC, so the first match is the newest.
  v=$(printf '%s' "$resp" | jq -er --arg h "$head" '.rows | if type == "array" then . else error("no rows") end
        | [.[] | select(.source == "box" and ((.head_sha // "") | ascii_downcase) == $h) | .verdict] | first // ""' 2>/dev/null)     || { _vd_log "$slug#$num ${head:0:8}: unparseable verdicts answer — unverifiable"; return 2; }
  if [ -z "$v" ]; then
    trunc=$(printf '%s' "$resp" | jq -r '.truncated // false' 2>/dev/null)
    [ "$trunc" = true ] && _vd_log "$slug#$num ${head:0:8}: no box row on this head in a truncated history (the worker returns the newest 100 rows of the PR) — read as none"
    return 1
  fi
  printf '%s' "$v"
}

# vd_block_line <owner/repo> <num> <pr-url> <head>
#   rc 0 + prints the block gate's scan line (url, login, at, id — the shape
#   bg_scan_read prints for a blocking comment) when a lead/human BLOCK stands
#   on this head; rc 1 when none does; rc 2 when that cannot be known (the
#   gate then refuses THIS tick's merge — see the header). The id is `verdict-<row id>`, which keys bg_refuse's
#   one-comment-per-(PR, head, block) ledger and tells it which sentence to post.
vd_block_line() {
  local url="$3" line rc v src id at rurl
  line=$(vd_standing "$1" "$2" "$4"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  IFS=$'\t' read -r v src id at rurl _ <<<"$line"
  [ "$v" = BLOCK ] || return 1
  case "$rurl" in ''|-) rurl="$url" ;; esac
  printf '%s\t%s-verdict\t%s\tverdict-%s' "$rurl" "$src" "$at" "$id"
  return 0
}
