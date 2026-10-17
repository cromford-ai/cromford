#!/bin/bash
# shellcheck shell=bash
# module: settle after: rebase
# bin/lib/mc/settle.sh — BH-477: closed-settled, the row file + ledger + rehydrate, patch-id rebind, mc_settle_merged. Sourced by bin/lib/merge-conductor-lib.sh, never run.
# THE DECISION READS GO THROUGH REST (BH-784), and the marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. It moved here
# with the code when BH-477.3 emptied bin/lib/merge-conductor-lib.sh: the lib
# carried the marker while it carried these calls, and a module holding them
# unmarked would be a call site the guard silently stopped policing.
# gh-rest: no-graphql


# --- A CLOSED PR IS NOT AN OUTCOME UNTIL IT HAS SETTLED (2026-09-15) ---------
# mc_kick_ci above closes a PR and reopens it one REST call later. tick_project
# holds locks/merge-conductor-<project>.lock across that pair, so no other
# conductor tick can see the gap — but two OTHER lanes run on the same box on
# the same */10 cron and read the same PRs, and neither takes that lock:
#
#   bin/reconcile-prs.sh   `state == CLOSED` clears the build's console row,
#                          permanently (bin/lib/cron-lines.sh).
#   bin/merge-sweep.sh     `state == CLOSED` writes `sweep_record <pr> closed`,
#                          which sweep_seen then reads as terminal for ever
#                          (cron/hub.cron still runs it every 10 minutes).
#
# Either one landing inside the kick's window retires a PR that is about to be
# open again, and nothing walks that back. So both ask this first: a closure
# YOUNGER than MC_CLOSED_SETTLE is skipped this pass and re-read on the next
# one, by which time the PR is either genuinely closed or open again. The cost
# is one extra pass on a real closure.
#
# FAIL-OPEN, everywhere. No closed_at, an unparseable one, or a window of 0 all
# answer "settled", i.e. exactly the behaviour these two lanes had before this
# existed. A guard that could park every closed PR on a date-format change
# would be worse than the race it closes.
MC_CLOSED_SETTLE="${MC_CLOSED_SETTLE:-180}"

# mc_closed_settled <closed_at-iso8601> -> rc 0 when this closure may be
#   treated as an outcome; rc 1 while it is still inside the settle window.
mc_closed_settled() {
  local at="${1:-}" win="${MC_CLOSED_SETTLE:-180}" epoch=""
  [ -n "$at" ] && [ "$at" != null ] && [ "$at" != "-" ] || return 0
  case "$win" in ''|*[!0-9]*) return 0 ;; esac
  [ "$win" -gt 0 ] || return 0
  # GNU date on the boxes, BSD date on a laptop; neither parsing it is a reason
  # to stop the lane.
  epoch=$(date -u -d "$at" +%s 2>/dev/null) || epoch=""
  [ -n "$epoch" ] || epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$at" +%s 2>/dev/null) || epoch=""
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(( $(mc_now) - epoch ))" -ge "$win" ]
}


# --- Rows: the file mirror + the ledger --------------------------------------
# Row file columns (tab): key state since head reviewed alerted reason url
mc_row_get() { awk -F'\t' -v k="$1" '$1==k {print; exit}' "$MC_ROWS" 2>/dev/null; }
mc_row_field() { # mc_row_field <key> <n>
  mc_row_get "$1" | cut -f"$2"
}
# THE ROW FILE IS REWRITTEN WHOLE, SO IT IS WRITTEN UNDER A LOCK (2026-09-14).
# bin/merge-conductor.sh now ticks every project in its own background subshell,
# and a read-modify-write of one shared file from two of them at once loses
# whichever row lost the race. The critical section is one awk over a few
# hundred bytes. It is the ONLY shared state the tick rewrites: attempts.txt,
# the re-review cap file and the log are append-only, and every other file the
# tick touches is keyed by project, repo or PR.
mc_row_put() { # mc_row_put <key> <state> <since> <head> <reviewed> <alerted> <reason> <url>
  local key="$1" tmp
  tmp=$(mktemp) || return 1
  ( flock 9 2>/dev/null
    awk -F'\t' -v k="$key" '$1!=k' "$MC_ROWS" > "$tmp" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$tmp"
    mv -f "$tmp" "$MC_ROWS"
  ) 9>>"$MC_ROWS.lock" 2>/dev/null
  rm -f "$tmp"
}
# --- Rehydrate: an EMPTY row file, rebuilt from D1 (BH-435) ------------------
# Every transition has been mirrored to `ledgers(kind=pr_state)` since phase 2
# (mc_ledger_put, below). pr-state.tsv is still the ledger of record and still
# per-box — so a rebuilt hub comes up with an empty file next to a full table:
# every `since` restarts at now, every `alerted` mark is gone, and the first
# tick pages again about every closed-unmerged PR the old box already paged
# about. The rows are right there. This reads them back into a file that is
# still empty — and, under the pr-state-rows flag, merges the pr_state view into
# a non-empty one on every mc_init too (BH-2361, mc_rows_merge below).
#
# WHAT IT COSTS: flag down, nothing on a normal tick — a non-empty file returns
# before the first request. An empty file, or any mc_init with the flag up, buys
# at most MC_REHYDRATE_PAGES GETs.
MC_REHYDRATE="${MC_REHYDRATE:-1}"                 # 0 = never rebuild, keep today's empty file
MC_REHYDRATE_PAGES="${MC_REHYDRATE_PAGES:-5}"     # pages of 1000 rows, the worker's own cap

# The per-page projection. `detail` is a TEXT column holding the JSON
# mc_ledger_put wrote, so it is parsed here, not indexed into: a row whose
# detail is null or not JSON emits NOTHING and is counted as skipped rather
# than becoming a row with `-` where its state should be. Tabs and newlines in
# any field become spaces, because the file they are going into is a TSV.
MC_REHYDRATE_JQ='
def c(v): (v // "-") | tostring | gsub("[\t\r\n]"; " ") | if . == "" then "-" else . end;
def ep(v): (v // "") | tostring
  | if test("^[0-9]+$") then .
    elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then (try (fromdateiso8601 | tostring) catch "-")
    else "-" end;
(.ledgers // [])[]
| (try (.detail | fromjson) catch null) as $d
| select(($d | type) == "object")
| [ c(.key), c(.status), ep($d.since), c($d.head_sha), c($d.reviewed_sha),
    c($d.alerted), c($d.reason), c($d.url) ]
| join("\t")'

# The same projection over the pr_state VIEW (BH-1387). The view keeps one
# column per field, so there is no `detail` to parse; what it emits is the
# file's own eight columns in mc_row_put's order, with the key rebuilt from
# repo + number and `since` through ep(), because the view carries ISO and
# mc_budget_check does `$(mc_now) - since`. A row missing repo, number or state,
# or whose since does not parse, emits nothing and is counted as skipped.
MC_REHYDRATE_VIEW_JQ="$(sed -n '/^def c(v)/,/else "-" end;$/p' <<<"$MC_REHYDRATE_JQ")"'
(.rows // [])[]
| select(((.repo // "") | tostring) != "" and ((.number // "") | tostring) != "" and ((.state // "") | tostring) != "")
| [ ((.repo | tostring) + "#" + (.number | tostring)), c(.state), ep(.since),
    c(.head), c(.reviewed), c(.alerted), c(.reason), c(.url) ]
| select(.[2] != "-")
| join("\t")'

# mc_rows_rehydrate_view — the pr_state view half of mc_rows_rehydrate (BH-1387).
#   rc 0 = handled: rows written, or another lane filled the file first.
#   rc 1 = fall through to the ledger path. Same page cap and the same
#   whole-or-nothing rule as that path: an empty or unreachable page, or a cap
#   reached with pages still outstanding, drops everything read so far — a
#   partial view is never written as if it were the fleet (D12).
#   --merge (BH-2361, a NON-empty file): the same read, merged into the file.
#   Always rc 0 there; an incomplete read leaves the file as it is.
mc_rows_rehydrate_view() {
  local merge=""; [ "${1:-}" = --merge ] && merge=1
  local maxp="${MC_REHYDRATE_PAGES:-5}"
  case "$maxp" in ''|*[!0-9]*|0) maxp=5 ;; esac
  local before="" pages=0 total=0 skipped=0 resp rc rows lines n acc tmp wrote=0
  acc=$(mktemp) || return 1
  while :; do
    if [ "$pages" -ge "$maxp" ]; then rc=cap; break; fi
    resp=$(pr_state_page 1000 "$before"); rc=$?
    [ "$rc" -eq 0 ] || break
    rows=$(printf '%s' "$resp" | jq -r '(.rows // []) | length' 2>/dev/null)
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    lines=$(printf '%s' "$resp" | jq -r "$MC_REHYDRATE_VIEW_JQ" 2>/dev/null)
    n=0
    [ -n "$lines" ] && { printf '%s\n' "$lines" >> "$acc"; n=$(printf '%s\n' "$lines" | grep -c .); }
    total=$((total + n)); skipped=$((skipped + rows - n)); pages=$((pages + 1))
    [ "$rows" -lt 1000 ] && { rc=0; break; }
    before=$(printf '%s' "$resp" | jq -r '(.rows // []) | last | .id // empty' 2>/dev/null)
    [ -n "$before" ] || { rc=cursor; break; }
  done
  if [ "$rc" != 0 ] || [ "$total" -eq 0 ]; then
    rm -f "$acc"
    if [ -n "$merge" ]; then
      mc_log "pr-state rehydrate(merge): view empty/unreachable (rc=${rc}, rows=$total) — pr-state.tsv left as is"
      return 0
    fi
    mc_log "pr-state rehydrate: pr_state view empty/unreachable (rc=${rc}, rows=$total) — falling back to ledgers"
    return 1
  fi
  tmp=$(mktemp "$MC_STATE_DIR/pr-state.rehydrate.XXXXXX") || { rm -f "$acc"; return 1; }
  awk -F'\t' '!seen[$1]++' "$acc" > "$tmp" 2>/dev/null
  rm -f "$acc"
  n=$(grep -c . "$tmp" 2>/dev/null || true)
  if [ -n "$merge" ]; then
    mc_rows_merge "$tmp" "$n"
    rm -f "$tmp"
    return 0
  fi
  ( flock 9 2>/dev/null
    [ -s "$MC_ROWS" ] && exit 9
    mv -f "$tmp" "$MC_ROWS" || exit 1
  ) 9>>"$MC_ROWS.lock" 2>/dev/null
  case $? in 0) wrote=1 ;; esac
  rm -f "$tmp"
  if [ "$wrote" = 1 ]; then
    mc_log "rehydrated $n pr-state rows from the pr_state view (skipped=$skipped)"
  else
    mc_log "pr-state rehydrate: another lane filled pr-state.tsv first — dropped $n row(s)"
  fi
  return 0
}

# mc_rows_merge <view-tsv> <n> — a COMPLETE view read merged into a non-empty
# pr-state.tsv under mc_row_put's lock, re-reading the file inside it so a row
# written during the fetch is merged too. Keys match with the repo case-folded
# (BH-1841). A local row is kept where the view has none, or where its numeric
# `since` is newer (a transition whose event write failed). On the SAME state and
# `since` the local columns are kept too and only the view's `alerted` mark can
# land, where the file has none or an earlier one for that entry (review D12:
# taking the view's head there released a page held for the current head as
# "moved"). Otherwise the view's columns land under the LOCAL key spelling.
# View-only keys are added.
mc_rows_merge() {
  local view="$1" n="$2" out stats rc
  out=$(mktemp "$MC_STATE_DIR/pr-state.merge.XXXXXX") || return 0
  stats=$(
    ( flock 9 2>/dev/null
      awk -F'\t' -v OFS='\t' '
        function k(x,  i) { i = index(x, "#"); return tolower(substr(x, 1, i - 1)) substr(x, i) }
        NR == FNR { v[k($1)] = $0; order[++nv] = k($1); next }
        { key = k($1)
          if (!(key in v)) { print; next }
          split(v[key], f, "\t"); used[key] = 1
          if ($3 ~ /^[0-9]+$/ && f[3] ~ /^[0-9]+$/ && $3 + 0 > f[3] + 0) { print; kept++; next }
          if ($3 ~ /^[0-9]+$/ && $3 == f[3] && $2 == f[2]) {
            # SAME STATE ENTRY: the file is the writer, the view only catches up.
            # mc_transition refreshes head/reviewed/reason with no event write,
            # and a mark whose event POST failed is in the file alone, so the
            # local columns stand. The view is authoritative for one thing: a
            # mark this file lost, or a later mark for the same entry
            # (`STATE@since` -> `STATE@since@day`, a later day).
            m = $2 "@" $3
            if (f[6] != "-" && f[6] != "" && index(f[6], m) == 1 &&
                ($6 == "-" || $6 == "" || (index($6, m) == 1 && f[6] > $6))) $6 = f[6]
            print; next }
          f[1] = $1; line = f[1]; for (i = 2; i <= 8; i++) line = line OFS f[i]; print line }
        END { for (i = 1; i <= nv; i++) if (!(order[i] in used)) { print v[order[i]]; added++ }
              printf "%d %d\n", kept, added > "/dev/stderr" }' "$view" "$MC_ROWS" 2>&1 >"$out" || exit 1
      # Local rows are always kept, so a merge of a non-empty file is never
      # empty: an empty result is a failed awk, never written (D11).
      [ -s "$out" ] || exit 1
      cmp -s "$out" "$MC_ROWS" || mv -f "$out" "$MC_ROWS"
    ) 9>>"$MC_ROWS.lock"
  ); rc=$?
  rm -f "$out"
  if [ "$rc" -ne 0 ]; then
    mc_log "pr-state rehydrate(merge): the merge failed (rc=$rc) — pr-state.tsv left as is"
    return 0
  fi
  mc_log "pr-state rehydrate(merge): $n from view, ${stats% *} local kept newer, ${stats#* } added"
}

# mc_rows_rehydrate — called at the end of mc_init. Always rc 0; every early
# return leaves the file exactly as it found it.
#   EVERY TICK UNDER THE ROW FLAG (BH-2361): a non-empty file is no longer a
#   reason not to ask. With pr-state-rows up, a complete pr_state view read is
#   merged in (mc_rows_merge), so a rebuilt hub's stale `alerted` column comes
#   back before the tick pages. Flag down, a non-empty file returns here as it
#   always has, before any request.
mc_rows_rehydrate() {
  [ "${MC_REHYDRATE:-1}" != 0 ] || return 0
  if [ -s "$MC_ROWS" ]; then
    type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 0
    type pr_state_page >/dev/null 2>&1 || return 0
    [ -n "${HARNESS_SECRET:-}" ] || return 0
    # Only a caller that exports MC_TICK_ID before mc_init reaches this latch;
    # merge-conductor.sh sets its tick id after mc_init, so there it never fires.
    [ -n "${MC_TICK_ID:-}" ] && [ -e "$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pr-rows-down" ] && return 0
    mc_rows_rehydrate_view --merge
    return 0
  fi
  # The same source guard mc_rebase_run uses: a lane that never sourced the
  # client gets it here, and one that did keeps its own.
  # shellcheck source=/dev/null
  type _jobs_req >/dev/null 2>&1 || { [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"; }
  # A stub client with no verbs (several suites write one function and call it a
  # file) and an unenrolled box with no secret are both NOT CONFIGURED, not an
  # outage: no request, no log line, no page.
  type ledger_page >/dev/null 2>&1 || return 0
  [ -n "${HARNESS_SECRET:-}" ] || return 0
  # THE VIEW FIRST WHEN THE ROW FLAG IS UP (BH-1387); rc 1 falls through to the
  # ledger path below, unchanged.
  type pr_state_page >/dev/null 2>&1 && pr_rows_on && mc_rows_rehydrate_view && return 0

  local maxp="${MC_REHYDRATE_PAGES:-5}"
  case "$maxp" in ''|*[!0-9]*|0) maxp=5 ;; esac
  local before="" pages=0 total=0 skipped=0 truncated=false
  local resp rc rows lines n acc tmp wrote=0
  acc=$(mktemp) || return 0
  while :; do
    [ "$pages" -lt "$maxp" ] || { truncated=true; break; }
    resp=$(ledger_page pr_state 1000 "$before"); rc=$?
    if [ "$rc" -ne 0 ]; then
      # WHOLE OR NOTHING. rc 1 is the worker being unreachable (jobs-client has
      # already written its once-a-day ALERTS line; there is no second alert
      # here), rc 2 is a D1 with no rows yet. Either way the file stays empty
      # and the next tick asks again — a half-written mirror would look like a
      # complete one to every reader.
      rm -f "$acc"
      mc_log "pr-state rehydrate: ledger unreachable/empty (rc=$rc) after $pages page(s) — pr-state.tsv left empty"
      return 0
    fi
    rows=$(printf '%s' "$resp" | jq -r '(.ledgers // []) | length' 2>/dev/null)
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    [ "$rows" -eq 0 ] && break
    lines=$(printf '%s' "$resp" | jq -r "$MC_REHYDRATE_JQ" 2>/dev/null)
    n=0
    [ -n "$lines" ] && { printf '%s\n' "$lines" >> "$acc"; n=$(printf '%s\n' "$lines" | grep -c .); }
    total=$((total + n))
    skipped=$((skipped + rows - n))
    pages=$((pages + 1))
    [ "$rows" -lt 1000 ] && break
    before=$(printf '%s' "$resp" | jq -r '(.ledgers // []) | last | .updated_at // empty' 2>/dev/null)
    [ -n "$before" ] || { truncated=true; break; }
  done

  if [ "$total" -eq 0 ]; then
    rm -f "$acc"
    mc_log "pr-state rehydrate: D1 holds no usable pr_state rows (skipped=$skipped) — pr-state.tsv left empty"
    return 0
  fi
  tmp=$(mktemp "$MC_STATE_DIR/pr-state.rehydrate.XXXXXX") || { rm -f "$acc"; return 0; }
  # Pages come back updated_at DESC, so the first sighting of a key is its
  # newest row and a key repeated across pages cannot double. The boundary risk
  # runs the other way: the cursor is a strict `updated_at < before`, so rows
  # sharing the last row's exact second are dropped, not repeated. That needs
  # two transitions in the same second landing on a 1000-row boundary, and it
  # costs a row the next transition rewrites — never a duplicate or a wrong row.
  awk -F'\t' '!seen[$1]++' "$acc" > "$tmp" 2>/dev/null
  rm -f "$acc"
  n=$(grep -c . "$tmp" 2>/dev/null || true)
  # mc_row_put's own lock, and a critical section that is one `mv`. The
  # conductor and bin/blocked-resolver.sh both reach mc_init on the hub: both
  # may fetch, only the first to take the lock writes, and the second drops its
  # copy rather than overwriting rows that are already being used.
  ( flock 9 2>/dev/null
    [ -s "$MC_ROWS" ] && exit 9
    mv -f "$tmp" "$MC_ROWS" || exit 1
  ) 9>>"$MC_ROWS.lock" 2>/dev/null
  case $? in 0) wrote=1 ;; esac
  rm -f "$tmp"
  if [ "$wrote" = 1 ]; then
    mc_log "rehydrated $n pr-state rows from D1 (skipped=$skipped, truncated=$truncated)"
  else
    mc_log "pr-state rehydrate: another lane filled pr-state.tsv first — dropped $n row(s)"
  fi
  return 0
}

# mc_ledger_put <key> <state> <since> <head> <reviewed> <verdict> <mstate> <reason> <record> <url> <alerted>
#   The console's copy (kind=pr_state). Fail-open: no client, no row, no change.
mc_ledger_put() {
  type job_ledger_put >/dev/null 2>&1 || return 0
  local detail
  detail=$(jq -nc --arg s "$3" --arg h "$4" --arg r "$5" --arg v "$6" --arg m "$7" --arg w "$8" \
    --arg rec "$9" --arg u "${10}" --arg a "${11}" \
    '{since:$s,head_sha:$h,reviewed_sha:$r,verdict:$v,merge_state:$m,reason:$w,record:$rec,url:$u,alerted:$a}' 2>/dev/null) || return 0
  job_ledger_put pr_state "$1" "$2" "$detail" >/dev/null 2>&1 || true
  # THE EVENT ROW IS WRITTEN THIRD (BH-1387): the file (mc_row_put, in the
  # caller), then the ledgers row above, then this. Both callers — mc_transition
  # and mc_budget_check's alert mark — come through here, so each writes one
  # pr_state_events row; its rc is ignored, and a failed POST changes nothing.
  mc_state_event_put "$1" "$2" "$3" "$4" "$5" "$8" "${10}" "${11}"
}

# mc_state_event_put <key> <state> <since-iso> <head> <reviewed> <reason> <url> <alerted>
#   One pr_state_events row under the flag; always rc 0. mc_ledger_put calls it
#   after its ledgers row, and the held-page flush's alert mark (mc_hold_flush_one,
#   which writes no ledgers row) calls it directly after its mc_row_put.
mc_state_event_put() {
  type pr_state_event_put >/dev/null 2>&1 && pr_rows_on && pr_state_event_put "${1%#*}" "${1##*#}" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >/dev/null 2>&1 || true
  return 0
}

# mc_transition <key> <new-state> <reason> <head> <reviewed> <url> <verdict> <mstate> <record>
#   Compares with the row; on a change: ONE log line, since=now, alerted reset,
#   file + ledger written. On no change: refresh head/reviewed only. Prints the
#   state's `since` epoch either way so the caller can age it.
mc_transition() {
  local key="$1" new="$2" why="$3" head="$4" rev="$5" url="$6" v="$7" ms="$8" rec="$9"
  local row prev since alerted
  row=$(mc_row_get "$key")
  prev=$(cut -f2 <<<"$row"); since=$(cut -f3 <<<"$row"); alerted=$(cut -f6 <<<"$row")
  if [ "$prev" != "$new" ]; then
    since=$(mc_now); alerted="-"
    mc_log "$key ${prev:--} -> $new head=${head:0:8} reviewed=${rev:0:8} merge=${ms:--} reason=$why"
    mc_row_put "$key" "$new" "$since" "$head" "$rev" "$alerted" "$why" "$url"
    mc_ledger_put "$key" "$new" "$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$since")" \
      "$head" "$rev" "$v" "$ms" "$why" "${rec:--}" "$url" "$alerted"
    # THE HAND-OFF IS RECORDED WHERE THE PARK IS MADE, so every one of the seven
    # sites that writes this state gets it without a seventh copy of the rule.
    if [ "$new" = BLOCKED_HUMAN ] && mc_handoff_owns "$why"; then
      mc_handoff_record "$key" "$head" "$why" "$url"
    fi
  else
    [ -n "$since" ] || since=$(mc_now)
    local prevwhy; prevwhy=$(cut -f7 <<<"$row")
    mc_row_put "$key" "$new" "$since" "$head" "$rev" "${alerted:--}" "$why" "$url"
    # A PARK RE-REASONED ONTO A HAND-OFF IS A HAND-OFF (BH-594). A row already
    # parked on a reason nobody owns (provenance) that a head-bound BLOCK moves
    # to head-not-reapproved never changes STATE, so the branch above never ran
    # and the resolver was never told. Only non-owned -> owned: owned -> owned
    # (the resolver's own no-verdict -> head-not-reapproved) would rewrite the
    # hand-off stamp and clear its release marker on every tick.
    if [ "$new" = BLOCKED_HUMAN ] && ! mc_handoff_owns "$prevwhy" && mc_handoff_owns "$why"; then
      mc_handoff_record "$key" "$head" "$why" "$url"
      mc_log "$key BLOCKED_HUMAN re-reasoned ${prevwhy:--} -> $why head=${head:0:8} — a hand-off: recorded for bin/blocked-resolver.sh"
    fi
  fi
  printf '%s' "$since"
}


# --- Patch-id approval rebind (2026-09-14, the operator: "yes that's a good change") --
# THE PROBLEM. Iron rule 1 binds an approval to the sha that was reviewed. After
# every batch merge the sibling PRs go DIRTY, each is rebased, and each rebase
# moves the head — so each one bought a full re-review of a change that is byte
# for byte the change a reviewer already approved.
#
# THE TEST. `git patch-id --verbatim` hashes the DIFF CONTENT, context lines and
# whitespace included, of <sha> against its merge-base with origin/main. A pure rebase
# keeps that id; ANY real content change — a new commit, a line edited, a
# hand-resolved conflict, even the same change against different surrounding
# code — changes it. So it is conservative by construction: it can say "this is
# the same patch" and it can never say "close enough".

# mc_patch_id <owner/repo> <project> <sha> -> the patch-id, rc 1 when it cannot
#   be computed (no token that can read the repo, or a sha the remote no longer
#   has — a force-pushed-away reviewed sha is exactly that case, and the caller
#   then buys the re-review).
# mc_patch_wt <owner/repo> <project> -> SETS MC_PATCH_WT to the checkout
#   mc_patch_id and mc_patch_same read (the hub's clone of the project, else the
#   conductor's own blobless clone), with `origin` pointed at the authenticated
#   remote. rc 1 when there is none. On rc 0 the caller owns mc_git_auth_clear.
#   It sets a global and prints nothing for mc_git_auth's reason: called as
#   `wt=$(mc_patch_wt …)` it armed the askpass helper in the substitution's
#   subshell, the caller's clear saw MC_ASKPASS empty, and every call leaked one
#   ${TMPDIR:-/tmp}/mc-askpass-* (32,510 on the hub by 2026-10-04, BH-4464) and
#   fetched with no GIT_ASKPASS exported.
MC_PATCH_WT=""
mc_patch_wt() {
  local slug="$1" project="$2" repo wt
  MC_PATCH_WT=""
  mc_git_auth "$slug" || { mc_git_auth_clear; return 1; }
  repo="${MC_REPOS:-/root/repos}/$project"
  if [ -d "$repo/.git" ]; then
    wt="$repo"
    git -C "$wt" remote set-url origin "$MC_REMOTE" >/dev/null 2>&1 || true
  else
    wt="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$wt")"
    if [ ! -d "$wt/.git" ]; then
      git -c credential.helper= clone -q --filter=blob:none "$MC_REMOTE" "$wt" >/dev/null 2>&1 || { mc_git_auth_clear; return 1; }
    else
      git -C "$wt" remote set-url origin "$MC_REMOTE" >/dev/null 2>&1 || true
    fi
  fi
  MC_PATCH_WT="$wt"
}

mc_patch_id() {
  local slug="$1" project="$2" sha="$3" wt base id
  [ -n "$sha" ] && [ "$sha" != "-" ] || return 1
  mc_patch_wt "$slug" "$project" || return 1; wt="$MC_PATCH_WT"
  git -C "$wt" -c credential.helper= fetch -q origin main "$sha" >/dev/null 2>&1 || { mc_git_auth_clear; return 1; }
  base=$(git -C "$wt" merge-base origin/main "$sha" 2>/dev/null)
  [ -n "$base" ] || { mc_git_auth_clear; return 1; }
  # --verbatim, never --stable (#2386 review): --stable strips every whitespace
  # change, so an indentation-only edit in Python or YAML, or `$D/cache` ->
  # `$D/ cache`, kept the approved id and was rebound and merged unreviewed.
  id=$(git -C "$wt" diff "$base" "$sha" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
  mc_git_auth_clear
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# mc_patch_id_file <record-or-empty> <owner/repo> <num> <sha> -> where the
#   patch-id of <sha> is kept: beside the build record when there is one (it
#   travels with the build, like reviewed-sha), else under the conductor's own
#   state, so a pool build with no local record still survives a tick.
mc_patch_id_file() {
  local rec="$1" slug="$2" num="$3" sha="$4"
  if [ -n "$rec" ] && [ -d "$rec" ]; then printf '%s/patch-id.%s' "$rec" "$sha"; return 0; fi
  mkdir -p "$MC_STATE_DIR/patch-id" 2>/dev/null
  printf '%s/patch-id/%s_%s_%s' "$MC_STATE_DIR" "${slug//\//_}" "$num" "$sha"
}

# mc_patch_id_remember <record-or-empty> <owner/repo> <project> <num> <sha>
#   Record the patch-id of a head an APPROVE is bound to, once. rc 0 when a
#   stored id exists afterwards.
mc_patch_id_remember() {
  local rec="$1" slug="$2" project="$3" num="$4" sha="$5" f id
  f=$(mc_patch_id_file "$rec" "$slug" "$num" "$sha")
  [ -s "$f" ] && return 0
  id=$(mc_patch_id "$slug" "$project" "$sha") || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id" > "$f"
  return 0
}

# mc_patch_id_rebind <owner/repo> <project> <num> <record-or-empty> <reviewed> <head>
#   Prints the patch-id and rc 0 when the MOVED head carries exactly the patch
#   the approved sha carried — i.e. the head moved because of a rebase and for
#   no other reason. rc 1 = different patch, or no id could be computed for
#   either sha, and the caller buys the detached re-review exactly as before.
mc_patch_id_rebind() {
  local slug="$1" project="$2" num="$3" rec="$4" rev="$5" head="$6" f old new
  f=$(mc_patch_id_file "$rec" "$slug" "$num" "$rev")
  old=$(head -1 "$f" 2>/dev/null || true)
  if [ -z "$old" ]; then
    old=$(mc_patch_id "$slug" "$project" "$rev") || return 1
    [ -n "$old" ] || return 1
    printf '%s\n' "$old" > "$f"
  fi
  new=$(mc_patch_id "$slug" "$project" "$head") || new=""
  if [ -n "$new" ] && [ "$new" = "$old" ]; then
    printf '%s\n' "$new" > "$(mc_patch_id_file "$rec" "$slug" "$num" "$head")"
    printf '%s' "$new"
    return 0
  fi
  # THE SECOND TEST (BH-2310). A whole-diff patch-id includes context lines and
  # is taken against the merge-base, which a main merge moves, so a fix round
  # that only merged main misses whenever main touched a line near a hunk
  # (#2131). mc_patch_same asks bin/lib/patch-same.sh, which proves "only clean
  # main merges since the reviewed head"
  # from the commits themselves (a clean-main-merge proof, or a byte-exact
  # patch-id). It prints `same:<how>` on rc 0.
  mc_patch_same "$slug" "$project" "$rev" "$head" || return 1
}

# mc_patch_same <owner/repo> <project> <reviewed> <head> -> `same:<how>` and rc 0
#   when bin/lib/patch-same.sh proves <head> carries exactly <reviewed>'s patch.
#   rc 1 on a different patch, a missing lib, or anything it cannot fetch, and
#   the caller buys the re-review exactly as before.
mc_patch_same() {
  local slug="$1" project="$2" rev="$3" head="$4" wt how
  # Sourced here, at call time and off this module's directory, not at module
  # load: the lib's functions are bin/lib/patch-same.sh's, and a module that
  # sourced them would read as defining them (tests/mc-split-layout-test.sh). A
  # box without the lib keeps today's rule.
  command -v patch_same >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/../patch-same.sh" ] && . "${BASH_SOURCE[0]%/*}/../patch-same.sh"; }
  command -v patch_same >/dev/null 2>&1 || return 1
  [ -n "$rev" ] && [ "$rev" != "-" ] && [ -n "$head" ] && [ "$head" != "-" ] || return 1
  mc_patch_wt "$slug" "$project" || return 1; wt="$MC_PATCH_WT"
  # The conductor's fetch shape (token URL, no credential helper), as mc_patch_id.
  if ! git -C "$wt" -c credential.helper= fetch -q origin main "$head" >/dev/null 2>&1; then mc_git_auth_clear; return 1; fi
  git -C "$wt" -c credential.helper= fetch -q origin "$rev" >/dev/null 2>&1 || true
  how=$(patch_same "$wt" origin/main "$rev" "$head"); local rc=$?
  mc_git_auth_clear
  [ "$rc" = 0 ] && [ -n "$how" ] || return 1
  printf 'same:%s' "$how"
}


# mc_settle_merged <key> <url> <project> <slug> <branch> <record> <job>
#   Everything a LANDING owes, in the order bin/merge-conductor.sh has always
#   done it: the merge ledger row, the sweep's done-file, the merge_sha artifact
#   on the BUILD's job, the issue close for issue-driven projects, the deploy
#   train hand-off, the ship beat. Prints the merge sha.
#
#   IT IS A SEPARATE FUNCTION BECAUSE THE LANDING IS NO LONGER IN THE SAME TICK
#   AS THE MERGE CALL. Under a native merge queue the conductor enqueues on one
#   tick and GitHub merges minutes later, so these consequences fire from the
#   QUEUED -> MERGED transition instead — and a PR merged out of a queue LEAVES
#   THE OPEN PR LIST, so without this pass nothing would ever run them: no issue
#   close, and production would wait for deploy-train's 20-minute self-source
#   floor on every single merge.
#
#   Safe to run twice, because it can be: every write in it is idempotent
#   (job_ledger_put upserts, the done-file is grep -qxF guarded, gh issue close
#   on a closed issue is a no-op) EXCEPT deploy-request.sh, which appends a
#   timestamped file to the deploy queue — two settles would depart two trains.
#   That one is guarded by an MC_ATTEMPTS line, the shape mc_attempted uses.
mc_settle_merged() { # … <head> [merge-sha]
  local key="$1" url="$2" project="$3" slug="$4" br="$5" rec="$6" job="$7" head="${8:-}" msha issue first=1 note="" w=""
  [ -n "$head" ] && note=", reviewed head $head"
  type job_ledger_put >/dev/null 2>&1 && job_ledger_put merge "$url" merged "merge-conductor" >/dev/null 2>&1 || true
  mkdir -p "$MC_H/state" 2>/dev/null
  grep -qxF "$url" "$MC_H/state/merge-sweep-done.txt" 2>/dev/null || echo "$url" >> "$MC_H/state/merge-sweep-done.txt"
  # When mc_merge landed this PR over REST the caller has GitHub's own merge
  # sha in hand — mc_merge printed it, conductor_settle passes it as the ninth
  # argument (BH-892) — and the read below is only the fallback. Only a hex
  # string is believed: a caller that hands over a reason line by mistake gets
  # the read, not a deploy train pointed at prose. The fallback read is REST
  # (BH-784), the same pull object every other decision read here comes from.
  msha=""
  case "${9:-}" in ""|*[!0-9a-f]*) ;; *) msha="$9" ;; esac
  [ -n "$msha" ] || msha=$(mc_pr_view "$url" '.merge_commit_sha // ""' 2>/dev/null)
  [ -n "$job" ] && [ "$job" != "-" ] && [ -n "$msha" ] && type job_artifact_put >/dev/null 2>&1 \
    && job_artifact_put merge_sha "$msha" "$(jq -nc --arg p "$url" '{by:"merge-conductor",pr:$p}')" "$job" >/dev/null 2>&1 || true
  # Issue-driven projects: comment + close the issue the PR was built for
  # (#262's "issue close after merge" rule; mc_issue_of derives the number).
  if [ "$("$MC_H/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null)" = "-" ]; then
    issue=$(mc_issue_of "$rec" "$br")
    # Comment, then close, then strip `ai-build`, in that order and never out of
    # it — mc_close_shipped answers 0 only after a fresh read says the issue
    # really is closed, so "closed issue #n" is never written off a PATCH that
    # 403'd. The comment is paid for ONCE: the `issue-commented` marker lives in
    # the build record the sweep also writes, so whichever lane comments first,
    # the other one does not say it twice. The strip word is logged beside the
    # close so `strip-failed` stays greppable on a box (BH-637 §3b: the label is
    # the handoff, and a shipped issue still carrying it re-offers finished work
    # to every selector in the fleet). A failure takes the branch it always did:
    # bin/reconcile-prs.sh is the retry lane here.
    # BH-2477: the PR url lets the close-out see a merge that only SLICED the
    # issue (no Closes keyword, a C<n> plan, open children); that one is left
    # open with a "Slice delivered" comment and logged as exactly that.
    if [ -n "$issue" ]; then
      if w=$(mc_close_shipped "$slug" "$issue" "Merged in $url (merge conductor$note). Closing this issue." "$rec" "$url"); then
        case "$w" in
          kept-slice*) mc_log "$key left issue #$issue open, slice delivered ($w)" ;;
          *)           mc_log "$key closed issue #$issue (ai-build: $w)" ;;
        esac
      else
        mc_log "$key merged but issue #$issue could not be closed ($w, HTTP $(mc_rest_status)) — bin/reconcile-prs.sh re-reads merged PRs and closes it on a later tick"
      fi
    fi
  fi
  if [ -z "$msha" ]; then
    # GitHub says merged but has not published the commit. Nothing to deploy
    # against and nothing to guard, so say so rather than enqueue a blank train:
    # deploy-train's self-source floor is the net this case was built for.
    mc_log "$key merged but GitHub published no merge commit — NO deploy request (deploy-train's self-source floor covers it)"
  elif mc_attempt_has "deployreq $key $msha" 2>/dev/null; then
    first=0
    mc_log "$key already handed ${msha:0:8} to the deploy train — not enqueuing a second"
  else
    mc_attempt_put "deployreq $key $msha"
    # THE VERIFIER IS A LANE, NOT A CHILD OF THIS TICK (2026-09-14). See
    # mc_dv_spawn: this function runs with the project's flock held on fd 9, and
    # deploy-request.sh's non-train branch used to spawn a 20-minute poll from
    # right here. MC_DETACHED_DEPLOY_VERIFY=0 calls it inline again.
    if [ "${MC_DETACHED_DEPLOY_VERIFY:-1}" = 0 ]; then
      [ -x "$MC_H/bin/deploy-request.sh" ] && "$MC_H/bin/deploy-request.sh" "$project" "$slug" "$msha" "${rec:-$MC_STATE_DIR}" >/dev/null 2>&1 || true
    elif mc_dv_spawn "$project" "$slug" "$msha" "${rec:-$MC_STATE_DIR}"; then
      mc_log "$key DEPLOY_VERIFY_SPAWNED — detached lane for ${msha:0:8} (job $(mc_dv_file "$project" "$msha"))"
    else
      mc_log "$key deploy-verify lane could NOT be spawned for ${msha:0:8} — nothing is watching that deploy"
      mc_alert "$key" MERGED "merged ${msha:0:8} but the deploy-verify lane could not be spawned — production is unverified for this sha: $url" 1
    fi
  fi
  [ "$first" = 1 ] && "$MC_H/bin/beat.sh" "$(jq -nc --arg pr "$url" --arg p "$project" \
    '{kind:"build",project:$p,stage:"conductor_merged",pr_url:$pr,merged:true,detail:"merge-conductor: READY, head-bound APPROVE, checks green"}')" >/dev/null 2>&1 || true
  printf '%s' "$msha"
  return 0
}
# closed_watch_dir — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
closed_watch_dir() { printf '%s/%s' "$MC_CLOSED_WATCH_DIR" "$(mc_safe_name "$1")"; }

# closed_watch_put — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
closed_watch_put() { # closed_watch_put <slug> <num> <state> <epoch> <url> <branch>
  local d; d=$(closed_watch_dir "$1")
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "${6:--}" > "$d/$2.tmp.$$" 2>/dev/null && mv -f "$d/$2.tmp.$$" "$d/$2" 2>/dev/null
  return 0
}

# closed_watch_seen — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# closed_watch_seen <slug> <list-row>... — a memo for every PR on this tick's
# open list that has none yet. No API call. An existing memo is never rewritten
# from the list, so a probe's epoch survives.
closed_watch_seen() {
  local slug="$1" d row num url br; shift
  d=$(closed_watch_dir "$slug")
  for row in "$@"; do
    IFS=$'\t' read -r num url _ br _ <<<"$row"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    [ -e "$d/$num" ] || closed_watch_put "$slug" "$num" open 0 "$url" "$br"
  done
  return 0
}

# closed_watch_reoffer — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# closed_watch_reoffer <slug> <num> — a settle skipped for a held PR lock goes
# back to "never probed", so the next tick reads it first instead of the memo
# saying closed about a PR nothing settled.
closed_watch_reoffer() {
  local f url br
  f="$(closed_watch_dir "$1")/$2"
  IFS=$'\t' read -r _ _ url br < "$f" 2>/dev/null || { url="https://github.com/$1/pull/$2"; br=-; }
  closed_watch_put "$1" "$2" open 0 "$url" "$br"
}

# closed_unmerged_rows — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# closed_unmerged_rows <project> <slug> <open-nums> — prints NUM TAB URL TAB
# BRANCH TAB CLOSED_AT for each candidate a probe this tick found closed without
# merging; always rc 0. Order: least recently probed first (never = 0), then
# newest PR number. A read that is not 200/304/404 stops the pass: nothing is
# memo'd and the PR is neither open nor closed (D9); it leads the next tick.
closed_unmerged_rows() {
  local slug="$2" open=" ${3:-} " d budget now line num url tmp rc st br cat
  local total probed=0 closed=0
  d=$(closed_watch_dir "$slug")
  budget="${GH_PR_LIST_REST_PAGES:-3}"
  case "$budget" in ''|*[!0-9]*) budget=3 ;; esac
  [ "$budget" -gt 0 ] || budget=3
  local -a CAND=()
  mapfile -t CAND < <( {
      awk -F'\t' -v p="$slug#" 'index($1, p) == 1 { print "R\t" substr($1, length(p) + 1) "\t" $2 "\t" $8 }' "$MC_ROWS" 2>/dev/null
      awk -v pre="https://github.com/$slug/pull/" \
        'FNR == 1 { if ($1 == "PR_CREATED" && index($2, pre) == 1) print "B\t" substr($2, length(pre) + 1) "\t" $2 }' \
        "$MC_H"/builds/*/RESULT 2>/dev/null
      awk -F'\t' 'FNR == 1 { n = FILENAME; sub(/.*\//, "", n); print "W\t" n "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' \
        "$d"/* 2>/dev/null
    } | awk -F'\t' -v open="$open" -v slug="$slug" '
      function url_ok(u) { return u != "" && u != "-" }
      $2 !~ /^[0-9]+$/ { next }
      { seen[$2] = 1 }
      $1 == "R" { if ($3 == "CLOSED" || $3 == "MERGED") term[$2] = 1; if (url_ok($4)) ru[$2] = $4 }
      $1 == "B" { if (url_ok($3)) bu[$2] = $3 }
      $1 == "W" { ws[$2] = $3; we[$2] = $4; if (url_ok($5)) wu[$2] = $5 }
      END {
        for (n in seen) {
          if (term[n] || index(open, " " n " ")) continue
          if (ws[n] == "merged" || ws[n] == "closed" || ws[n] == "gone") continue
          u = (n in ru) ? ru[n] : (n in bu) ? bu[n] : (n in wu) ? wu[n] : "https://github.com/" slug "/pull/" n
          e = (we[n] ~ /^[0-9]+$/) ? we[n] : 0
          print e "\t" n "\t" u
        }
      }' | sort -t$'\t' -k1,1n -k2,2nr )
  total=${#CAND[@]}
  [ "$total" -gt 0 ] || return 0
  now=$(mc_now)
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-closed.XXXXXX") || return 0
  for line in "${CAND[@]}"; do
    [ "$probed" -lt "$budget" ] || break
    IFS=$'\t' read -r _ num url <<<"$line"
    # `> file`, never `$( )`: GH_REST_STATUS has to reach the log line below.
    rc=0; mc_rest_pr_json "$slug" "$num" > "$tmp" || rc=$?
    if [ "$rc" = 44 ]; then
      probed=$((probed + 1))
      closed_watch_put "$slug" "$num" gone "$now" "$url" -
      mc_log "$slug#$num: closed probe answered 404 — memo'd gone, not read again until the memo ages out"
      continue
    fi
    if [ "$rc" != 0 ]; then
      mc_log "$slug: closed probe of #$num unreadable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — $((total - probed)) candidates deferred to the next tick"
      break
    fi
    IFS=$'\t' read -r st br cat < <(jq -r '[.STATE, (.head.ref // "-"), (.closed_at // "-")] | @tsv' "$tmp" 2>/dev/null)
    case "$st" in
      CLOSED) closed_watch_put "$slug" "$num" closed "$now" "$url" "$br"; closed=$((closed + 1))
              printf '%s\t%s\t%s\t%s\n' "$num" "$url" "$br" "$cat" ;;
      MERGED) closed_watch_put "$slug" "$num" merged "$now" "$url" "$br" ;;
      OPEN)   closed_watch_put "$slug" "$num" open "$now" "$url" "$br" ;;
      *)      mc_log "$slug: closed probe of #$num answered no state — $((total - probed)) candidates deferred to the next tick"
              break ;;
    esac
    probed=$((probed + 1))
  done
  rm -f "$tmp"
  mc_log "$slug CLOSED-PROBE candidates=$total probed=$probed closed=$closed deferred=$((total - probed)) budget=$budget"
  return 0
}

# conductor_settle — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# conductor_settle <key> <url> <project> <slug> <branch> <record> <job> <head>
#                  <reviewed> <verdict> <mstate> <reason> [merge-sha]
#   The PR landed — synchronously (no queue) or out of GitHub's merge queue.
#   One log line, the MERGED row, then mc_settle_merged's consequence block.
#   <merge-sha> is what mc_merge printed on its rc 0 — the sha GitHub's REST
#   200 carried (BH-892) — captured by the `ERR=$(mc_merge_locked …)` at the
#   call site and handed on so the settle needs no GraphQL read for it. Empty
#   (a queue landing, a gh-line merge) means the settle reads it as before.
#   The consequences are GitHub WRITES (an issue close) and a production deploy,
#   so they run only in merge mode; a landing seen while the flags are off is
#   recorded and PAGED instead, because the alternative is a merged PR whose
#   issue stays open and whose sha never reaches the deploy train, silently.
conductor_settle() {
  local key="$1" url="$2" proj="$3" slug="$4" br="$5" rec="$6" job="$7" head="$8" rev="$9" v="${10}" ms="${11}" why="${12}" msha="${13:-}"
  # NEVER ON A LANE-RUN MACHINE (BH-6495). The machine lands nothing, so no
  # caller reaches this there; if one does, it writes nothing. The issue
  # close, the deployreq row, the stack follow and the deploy-verify are the
  # hub's, and the hub's QUEUED pass settles this PR on its next tick.
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo settle >> "$MC_PR_DEFERRED_FILE"
    mc_log "$key MERGED but seen on a lane-run machine — not settled here; the hub settles it (deferred=settle)"
    return 0
  fi
  # A held project lease that was lost (BH-6887): the same exit, so the QUEUED
  # pass settles it later under a lease of its own.
  if ! mc_lease_fence_ok; then
    [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo settle >> "$MC_PR_DEFERRED_FILE"
    mc_log "$key MERGED but the project lease was lost — not settled here (deferred=settle)"
    return 0
  fi
  mc_log "MERGED $key by conductor (record ${rec:-none})"
  mc_transition "$key" MERGED "$why" "$head" "$rev" "$url" "$v" "$ms" "$rec" >/dev/null
  # EVERY CONTESTED HOLD THIS MERGE WINS ENDS HERE (BH-589). The losers move to
  # NEEDS_REBASE (mc_contested_release: rows first, file last) and the next tick
  # reclassifies them from GitHub — all but a loser some OTHER live hold still
  # names, which that release deliberately leaves parked for the hold that still
  # owns it (BH-587). No alert — the winner landing is the good
  # outcome, not a page — and it runs whatever the merge flags say, because what
  # the losers are waiting on is the winner's ROW, not the issue close below.
  local cf
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    mc_contested_live "$cf" || continue
    [ "$(jq -r 'select(type=="object")|.winner_url // empty' "$cf" 2>/dev/null)" = "$url" ] || continue
    mc_contested_release "$cf" "winner merged"
  done < <(mc_contested_list "$proj")
  if [ "$MERGES" = 1 ]; then
    mc_settle_merged "$key" "$url" "$proj" "$slug" "$br" "$rec" "$job" "$head" "$msha" >/dev/null
  else
    mc_log "$key landed while merges are disabled — issue close and deploy request NOT run"
    mc_alert "$key" MERGED "landed (merge queue) while the conductor's merge flag was off: the issue was NOT closed and NO deploy was requested — turn flags/merge-conductor-merge on and the next tick settles both, or run bin/deploy-request.sh for this sha: $url" 1
  fi
  # EVERY OPEN CHILD OF THIS BRANCH IS FOLLOWED ONTO THE BASE (BH-1670): the
  # retarget, then `rebase --onto <base> <this head>`, then one push. The owed
  # work is written first; a child whose own worker holds its lock is left to
  # that worker (flock -n, never a wait). mc_stack_follow says what it did.
  [ -n "$br" ] && [ -n "$head" ] || return 0
  local kids kid pn="${url##*/}" base
  if ! kids=$(mc_stack_children "$slug" "$br"); then
    mc_log "$key: children of $br unreadable ($kids) — no restack this tick; a child still based on $br is retargeted by the stacked block's MERGED arm"
    return 0
  fi
  base=$(mc_project_base "$proj")
  for kid in $kids; do
    case "$kid" in ''|*[!0-9]*) continue ;; esac
    mc_stack_pending_put "$slug" "$kid" "$pn" "$url" "$br" "$head" "$base" \
      || { mc_log "$slug#$kid: the owed restack after $key merged could not be recorded — not followed"; continue; }
    # A subshell owns the child's lock fd, so it is released when the follow
    # ends, whatever the follow does (fixed fd 8: bash 3.2 has no {var}>).
    ( exec 8>"$(mc_pr_lock "$proj" "$kid")"
      flock -n 8 || exit 42
      mc_stack_follow "$proj" "$slug" "$kid" "$pn" "$url" "$br" "$head" "$base" >/dev/null
      exit 0 )
    [ "$?" = 42 ] && mc_log "$slug#$kid: its own conductor worker holds the PR lock — the restack after $key merged is left to that worker"
  done
  return 0
}

# rebind_patch_id — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# rebind_patch_id <key> <project> <slug> <num> <url> <record> <reviewed> <head>
#   CHANGE 2 (the operator, 2026-09-14: "yes that's a good change"). The head moved and
#   the PATCH DID NOT: `git patch-id --verbatim` of the current head equals the
#   one stored for the approved sha, so this is the same change a reviewer
#   already approved, sitting on a new parent. The approval is REBOUND to the
#   new sha — record `reviewed-sha`, the ledger rebind, a line in the record's
#   rebind.log — and NO re-review is bought. rc 0 when it was rebound.
#
#   It is conservative by construction: patch-id hashes the diff content
#   including context lines, so a new commit, an edited line or a hand-resolved
#   conflict all change the id and fall through to the detached re-review.
rebind_patch_id() {
  local key="$1" proj="$2" slug="$3" num="$4" url="$5" rec="$6" rev="$7" head="$8" id
  id=$(mc_patch_id_rebind "$slug" "$proj" "$num" "$rec" "$rev" "$head") || return 1
  local why
  case "$id" in
    same:*) why="own commits unchanged (${id#same:}, bin/lib/patch-same.sh; no content change)" ;;
    *)      why="patch-id $id unchanged (rebase only, no content change)" ;;
  esac
  if [ -n "$rec" ] && [ -d "$rec" ]; then
    echo "$head" > "$rec/reviewed-sha"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') approval rebound $rev -> $head $why" >> "$rec/rebind.log"
  fi
  type job_verdict_rebind >/dev/null 2>&1 && job_verdict_rebind "$url" "$head" >/dev/null 2>&1 || true
  mc_log "$key REBOUND ${rev:0:8} -> ${head:0:8}: $why — approval rebound, no re-review bought"
  # The saving, as a stage_events row (BH-2545). Sourced here at call time, as
  # mc_patch_same does, so this module never reads as defining the lib.
  command -v review_saving_event >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/../review-saving.sh" ] && . "${BASH_SOURCE[0]%/*}/../review-saving.sh"; }
  local how="patch-id"
  case "$id" in same:*) how="${id#same:}" ;; esac
  command -v review_saving_event >/dev/null 2>&1 \
    && review_saving_event "$proj" merge-conductor "$slug" "$num" "$head" REUSED "from=${rev:0:12} to=${head:0:12} how=$how" || true
  mc_rebind_publish "$key" "$proj" "$slug" "$num" "$url" "$head" "$rev" || true
  return 0
}

# mc_rebind_publish <key> <project> <slug> <num> <url> <head> [reviewed]
#   A REBOUND APPROVAL CARRIES ITS lead-verdict STATUS ONTO THE NEW HEAD (BH-4596).
#   A commit status is keyed by sha, so a rebind leaves the new head with none,
#   and a Mergify row that stays QUEUED across the push never reaches
#   mc_enqueue_mergify, the one conductor publisher. Mergify then waits on
#   `check-success = "lead-verdict"` for good (#4375, #4415, #4357).
#
#   With <reviewed> (a sha): called by both rebind arms the moment they rebind.
#   Publishes success on <head>, once per (PR, head) (`vsrebind` attempt line).
#   Without it: pr_worker's per-tick retry. It does nothing unless a publish is
#   OWED (state/merge-conductor/vs-owed/<key>, `<head>\t<reviewed>\t<url>`), and
#   then retries only while the owed head IS <head>; a moved head drops it.
#   With `-`: no approval is bound to <head> this tick, so anything owed is void.
#
#   IT CARRIES, IT NEVER CLEARS (BH-4596 review F2). A rebind publishes only
#   when the row is QUEUED (the queue already took this PR, the incident shape)
#   or the old head already carried lead-verdict success. Any other row (READY
#   above all, which the main-red freeze, a PR dependency or the unread-diff
#   hold may be holding) gets nothing here: its own mc_enqueue_mergify
#   publishes once those gates pass, and a status ahead of them is a queue
#   clearance the conductor never gave. An unreadable old status counts as
#   not success.
#
#   A failed publish, an undecidable lead authority (mc_la_decide rc 2), or
#   actions/merges off writes the owed file and one log line (the merges-off
#   line once per head, not once per tick); the next tick retries. la_decide rc 1 (protected path, revoked authority) publishes
#   nothing ever: the NEEDS_HUMAN_VERDICT gate owns that head. Not Mergify: a
#   no-op, the status gates only Mergify's queue_conditions. Always rc 0.
#   After a published success it also calls pq_status_ensure (BH-5441), so the
#   new head gets prequeue-verdict success unless a red verdict stands on it.
mc_rebind_publish() {
  local key="$1" proj="$2" slug="$3" num="$4" url="$5" head="$6" rev="${7:-}" f old orev ourl err lac=0 pst ovs
  [ "${PROVIDER:-}" = mergify ] || return 0
  command -v vs_publish >/dev/null 2>&1 || return 0
  [ -n "$head" ] && [ "$head" != "-" ] || return 0
  f="$MC_STATE_DIR/vs-owed/$(mc_handoff_id "$key")"
  if [ -z "$rev" ] || [ "$rev" = "-" ]; then
    # The retry: the file is read BEFORE anything else, so a PR that owes
    # nothing (every PR, in steady state) costs one stat and no gh call.
    [ -s "$f" ] || return 0
    IFS=$'\t' read -r old orev ourl < "$f" || true
    if [ "$old" != "$head" ]; then
      rm -f "$f"
      mc_log "$key VS_REBIND_DROPPED ${old:0:8}: head moved to ${head:0:8} — the owed lead-verdict publish is void; the new head is judged on its own"
      return 0
    fi
    if [ "$rev" = "-" ]; then
      rm -f "$f"
      mc_log "$key VS_REBIND_DROPPED ${old:0:8}: no approval is bound to it any more — the owed lead-verdict publish is void"
      return 0
    fi
    rev="$orev"; [ -n "$ourl" ] && url="$ourl"
  else
    # The rebind itself: the carry gate. A retry skips it, because only a
    # rebind that passed it ever writes the owed file.
    pst=$(mc_row_field "$key" 2 2>/dev/null)
    if [ "$pst" != QUEUED ]; then
      ovs=""
      command -v mc_vs_state_on >/dev/null 2>&1 && ovs=$(mc_vs_state_on "$slug" "$rev" 2>/dev/null)
      if [ "$ovs" != success ]; then
        mc_log "$key lead-verdict not carried to ${head:0:8}: the row is ${pst:-new} and ${rev:0:8} had no lead-verdict success (${ovs:-unread}) — the READY arm's enqueue publishes once its gates pass"
        return 0
      fi
    fi
  fi
  if mc_attempt_has "vsrebind $key $head" 2>/dev/null; then rm -f "$f"; return 0; fi
  if [ "${ACTIONS:-0}" != 1 ] || [ "${MERGES:-0}" != 1 ]; then
    [ -s "$f" ] && IFS=$'\t' read -r old _ < "$f" || old=""
    mkdir -p "${f%/*}" 2>/dev/null; printf '%s\t%s\t%s\n' "$head" "$rev" "$url" > "$f"
    [ "$old" = "$head" ] \
      || mc_log "$key WOULD publish lead-verdict=success on ${head:0:8} (rebound from ${rev:0:12}) — merges are off this tick; owed until they are on"
    return 0
  fi
  if command -v mc_la_decide >/dev/null 2>&1; then
    mc_la_decide "$slug" "$num" "$head" || lac=$?
  fi
  case "$lac" in
    0) ;;
    1) rm -f "$f"
       mc_log "$key lead-verdict withheld on ${head:0:8} (${LA_REASON:-no reason given}) — the NEEDS_HUMAN_VERDICT gate owns it; the rebind publishes nothing"
       return 0 ;;
    *) mkdir -p "${f%/*}" 2>/dev/null; printf '%s\t%s\t%s\n' "$head" "$rev" "$url" > "$f"
       mc_log "$key VS_REBIND_OWED on ${head:0:8}: the lead authority could not be decided (${LA_REASON:-no reason given}) — retried next tick"
       return 0 ;;
  esac
  # In a substitution, as mc_enqueue_mergify does it: the HTTP answer is the
  # one vs_publish's stderr line names.
  if err=$(vs_publish "$slug" "$head" success "harness verdict rebound from ${rev:0:12} to ${head:0:12}" "$url" 2>&1 >/dev/null); then
    mc_attempt_put "vsrebind $key $head"
    rm -f "$f"
    mc_log "$key VS_REBIND_PUBLISHED $head lead-verdict=success (rebound from ${rev:0:12})"
    command -v pq_status_ensure >/dev/null 2>&1 && pq_status_ensure "$slug" "$head" "$url" "rebound from ${rev:0:12}"
  else
    mkdir -p "${f%/*}" 2>/dev/null; printf '%s\t%s\t%s\n' "$head" "$rev" "$url" > "$f"
    mc_log "$key VS_REBIND_OWED on ${head:0:8}: $(head -1 <<<"${err:-vs_publish failed}") — retried next tick"
  fi
  return 0
}
