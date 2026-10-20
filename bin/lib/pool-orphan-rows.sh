#!/bin/bash
# bin/lib/pool-orphan-rows.sh — release a `claimed` fly queue row that nothing
# on this hub owns any more (BH-7382, Fix 2: "claim cleared, queue row back to
# queued").
#
# The REAP closes the row of every job FILE it reaps. A row whose job file is
# already gone (a lost file, a spawn that died between claim and file) has no
# pool path that releases it: only bin/jobs-watchdog.sh does, at
# JOBS_QUEUE_CLAIM_MIN (360 min by default), because the watchdog cannot see
# the pool's evidence. On 2026-10-18 project-6-os waited up to 314 min inside
# that window. The pool tick CAN see the evidence: its job files, the queue
# files, the active key and a usable Fly listing. So it releases the row after
# POOL_ORPHAN_ROW_RELEASE_S, with positive proof that nothing owns it.
#
# TWO HALVES, the pool-underuse.sh shape.
#   1. pool_orphan_row_verdict: pure. Every input is an argument, the answer is
#      one line. tests/fly-pool-orphan-rows.bh-7382-test.sh drives it as a table.
#   2. pool_orphan_rows_step: runs in bin/fly-pool.sh's own shell inside the
#      dead-machine sweep, after the REAP. It reads the caller's P POOL HARNESS
#      LISTING LIST_OK and say, and _jobs_req, queue_release and JOBS_BOX from
#      the jobs client.

_por_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# pool_orphan_row_verdict <status> <target> <claimed_by> <this_box> <key>
#   <age_s> <threshold_s> <has_queue_file 0|1> <has_pool_file 0|1>
#   <is_active_key 0|1> <machine_state>
# -> `release`, `wait` or `keep<TAB><why>`. machine_state is the listing's
# state for the row's machine, `-` when the row names no machine, `absent`
# when the listing does not return it. A non-number age or threshold is
# `keep<TAB>bad-input` and rc 2.
pool_orphan_row_verdict() {
  local st="${1:-}" tg="${2:-}" by="${3:-}" me="${4:-}" key="${5:-}" age="${6:-}" thr="${7:-}" \
        qf="${8:-0}" pf="${9:-0}" af="${10:-0}" ms="${11:-}"
  _por_int "$age" && _por_int "$thr" || { printf 'keep\tbad-input\n'; return 2; }
  [ "$thr" = 0 ] && { printf 'keep\toff\n'; return 0; }
  [ "$st" = claimed ] || { printf 'keep\tnot-claimed\n'; return 0; }
  [ "$tg" = fly ] || { printf 'keep\tnot-fly\n'; return 0; }
  { [ -n "$me" ] && [ "$by" = "$me" ]; } || { printf 'keep\tother-claimant\n'; return 0; }
  # A dead rebase or re-review is closed FAILED by the reap on purpose; the
  # watchdog owns it.
  case "$key" in RB-*) printf 'keep\trebase\n'; return 0 ;; RR-*) printf 'keep\trereview\n'; return 0 ;; esac
  # A files-mode claim with its queue file is a job that waits, not an orphan.
  [ "$qf" = 1 ] && { printf 'keep\tqueued-file\n'; return 0; }
  [ "$pf" = 1 ] && { printf 'keep\tpool-file\n'; return 0; }
  [ "$af" = 1 ] && { printf 'keep\tactive-file\n'; return 0; }
  case "$ms" in
    started|starting|created|replacing) printf 'keep\tmachine-live\n'; return 0 ;;
    -|absent|stopped|destroyed|failed|suspended) ;;
    *) printf 'keep\tmachine-unknown\n'; return 0 ;;
  esac
  [ "$age" -lt "$thr" ] && { printf 'wait\n'; return 0; }
  printf 'release\n'
  return 0
}

# _por_knob <ENV> <default> <max> — the knob as a number, or the default with
# one say line naming the bad value.
_por_knob() {
  local n="${1:-}" d="${2:-}" mx="${3:-}" v
  v="${!n:-$d}"
  if ! _por_int "$v" || { [ -n "$mx" ] && [ "$v" -gt "$mx" ]; }; then
    declare -F say >/dev/null 2>&1 && say "$n=$v is not a number of 0-$mx — using $d"
    v="$d"
  fi
  printf '%s\n' "$v"
}

# pool_orphan_rows_step — one GET of this project's stale claimed fly rows,
# one verdict per row, a queue_release per `release` (at most
# POOL_ORPHAN_ROW_RELEASE_MAX per tick). One say line per release, written only
# after the PATCH returned 0, and one ALERTS line per tick that released any.
pool_orphan_rows_step() {
  local root="${HARNESS:-}" thr max smin resp rc asof now rows k st tg by mid cat ep age ms qf pf af \
        out why f released=() due=0 n=0 active="" pkeys=""
  [ "${LIST_OK:-0}" = 1 ] && [ -s "${LISTING:-}" ] || return 0
  command -v _jobs_req >/dev/null 2>&1 && command -v queue_release >/dev/null 2>&1 || return 0
  [ -n "$root" ] && [ -n "${P:-}" ] || return 0
  thr=$(_por_knob POOL_ORPHAN_ROW_RELEASE_S 900 21600)
  [ "$thr" = 0 ] && return 0
  max=$(_por_knob POOL_ORPHAN_ROW_RELEASE_MAX 20 200)
  [ "$max" -ge 1 ] || max=1
  smin=$((thr / 60)); [ "$smin" -ge 1 ] || smin=1
  resp=$(_jobs_req GET "/api/queue?project=$P&status=claimed&target=fly&stale_min=$smin&limit=500" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    declare -F say >/dev/null 2>&1 && say "orphan-rows: queue read failed (rc $rc) — nothing released"
    return 0
  fi
  asof=$(jq -r '.as_of // ""' <<<"$resp" 2>/dev/null)
  now=""; [ -n "$asof" ] && { now=$(date -u -d "$asof" +%s 2>/dev/null) || now=""; }
  _por_int "$now" || now=$(date -u +%s)
  active=$(jq -r '.key // ""' "$root/state/fly/$P-active.json" 2>/dev/null)
  # The keys the pool's job files name, read once: each one is the REAP's.
  for f in "${POOL:-/nonexistent}"/*.json; do
    [ -f "$f" ] && pkeys="$pkeys$(jq -r '.key // empty' "$f" 2>/dev/null)"$'\n'
  done
  rows=$(jq -r '.queue[]? | [(.ticket_key // ""),(.status // ""),(.target // ""),(.claimed_by // ""),
                (.machine // ""),(.claimed_at // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' \
                <<<"$resp" 2>/dev/null)
  # \x1f, not a tab: read collapses runs of a whitespace IFS, so an empty
  # machine would shift claimed_at into its field.
  while IFS=$'\x1f' read -r k st tg by mid cat; do
    [ -n "$k" ] || continue
    # An unknown claim time is not an old one: no claimed_at is age `x`,
    # which the verdict keeps as bad-input.
    ep=""; [ -n "$cat" ] && { ep=$(date -u -d "$cat" +%s 2>/dev/null) || ep=""; }
    if _por_int "$ep"; then age=$((now - ep)); [ "$age" -lt 0 ] && age=0; else age=x; fi
    # A read only: the queue file is the files-mode claim of the same key.
    if [ -f "$root/state/build-queue/$P/$k.json" ]; then qf=1; else qf=0; fi
    pf=0; grep -Fxq -- "$k" <<<"$pkeys" && pf=1
    af=0; [ -n "$active" ] && [ "$active" = "$k" ] && af=1
    if [ -z "$mid" ] || [ "$mid" = null ]; then
      ms=-; mid=""
    else
      ms=$(jq -r --arg m "$mid" '[.[] | select(.id == $m) | (.state // "")][0] // "absent"' "$LISTING" 2>/dev/null)
      [ -n "$ms" ] || ms=absent
    fi
    out=$(pool_orphan_row_verdict "$st" "$tg" "$by" "${JOBS_BOX:-}" "$k" "$age" "$thr" "$qf" "$pf" "$af" "$ms")
    [ "$out" = release ] || continue
    due=$((due + 1))
    [ "$n" -ge "$max" ] && continue
    why="orphan release: claimed by $by ${age}s ago, machine ${mid:-none} ${ms}, no hub owner"
    queue_release "$P" "$k" "$why" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
      n=$((n + 1)); released+=("$k")
      declare -F say >/dev/null 2>&1 \
        && say "orphan-row-release $k: claimed by $by ${age}s ago on machine ${mid:-none} ($ms), no hub owner — row back to queued"
    else
      n=$((n + 1))
      declare -F say >/dev/null 2>&1 && say "orphan-row-release $k: release failed (rc $rc) — row stays claimed"
    fi
  done <<<"$rows"
  if [ "$due" -gt "$max" ] && declare -F say >/dev/null 2>&1; then
    say "orphan-rows: $((due - max)) over POOL_ORPHAN_ROW_RELEASE_MAX this tick — next tick"
  fi
  if [ "${#released[@]}" -gt 0 ]; then
    out=$(printf '%s, ' "${released[@]}")
    HARNESS="$root" "$root/bin/alert-line.sh" \
      "[pool/$P] released ${#released[@]} claimed row(s) with no machine and no hub file: ${out%, } (orphan-row release, BH-7382)"
  fi
  return 0
}
