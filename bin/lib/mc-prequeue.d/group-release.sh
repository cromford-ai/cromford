#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/group-release.sh — A PASSED PREQUEUE GROUP RELEASES ITS
# MEMBERS ON THE NEXT TICK (BH-8610). Sourced by bin/lib/mc-prequeue.sh's hook
# loop, never executed; no side effect at source time.
#
# WHY. A group's verdict was read only in a member's own READY arm (pq_settle
# -> pq_group_read). A row held prequeue-pending keeps its pr-state.tsv line
# unchanged, so after MC_BACKSTOP_UNCHANGED_SKIP keyed runs the backstop
# skipped every member (BH-8310) until the row changed. On 2026-10-27 group
# g1793106162712d passed at 13:03Z and its 6 PRs were still not queued when
# main moved at 13:49Z; each then re-gated alone.
#
# THE RULE. mc_pq_group_tick_end calls pq_group_release_sweep <slug> on every
# conductor tick of the project, keyed or full, before pq_group_flush. For
# each dispatched group (`.run`) of this repo with no `<gid>.released` marker:
#   - no `<gid>.verdicts` yet: read the run once with _pq_gread_run under the
#     `<gid>.read.lock` that pq_group_read uses (the same per-tick run-list
#     memo). Not completed (rc 1) or a failed read (rc 75): the next tick asks.
#   - `<gid>.verdicts` present: remove each member's backstop-unchanged
#     counter ($MC_STATE_DIR/backstop-unchanged/, first field `<slug>#<num>`,
#     case-insensitive), write `<gid>.released`, and log one
#     `PREQUEUE group-release <slug> group=<gid> main=<12> n=<k> prs=...` line.
# The sweep writes no cache entry, posts no status and enqueues nothing: the
# next keyed run of each member reads its verdict from the file in its own
# READY arm (enqueue, lead fence and status as before). A red member parks
# there. No `.run` file: no lock and no call.
#
#   pq_group_release_sweep <slug>   always rc 0

# pq_group_release_sweep <slug> — see the header.
pq_group_release_sweep() {
  local slug="$1" gd pre f name rest main gid vf rk w rc num head n prs key ud u uk
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "$slug" ] || return 0
  gd=$(_pq_gdir); pre="${slug//\//_}_"
  compgen -G "$gd/$pre*.run" >/dev/null 2>&1 || return 0
  ud="$MC_STATE_DIR/backstop-unchanged"
  for f in "$gd/$pre"*.run; do
    [ -r "$f" ] || continue
    name="${f##*/}"; rest="${name#"$pre"}"; rest="${rest%.run}"
    # `<main>_<gid>` only: a repo whose name extends this one never matches.
    [[ "$rest" =~ ^([0-9a-f]{40})_(g[0-9a-f]+)$ ]] || continue
    main="${BASH_REMATCH[1]}"; gid="${BASH_REMATCH[2]}"
    [ -e "$gd/$gid.released" ] && continue
    vf="$gd/$gid.verdicts"
    if [ ! -s "$vf" ]; then
      rk="$gd/$gid.read.lock"; { : >> "$rk"; } 2>/dev/null || continue
      w=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S); rc=0
      ( flock -w "$w" 7 || exit 3; [ -s "$vf" ] && exit 0; _pq_gread_run "$slug" "$gid" "$main" "$vf" ) 7>"$rk" || rc=$?
      [ "$rc" = 0 ] && [ -s "$vf" ] || continue
    fi
    n=0; prs=""
    while read -r num head; do
      [[ "$num" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
      n=$((n + 1)); prs="${prs:+$prs,}#$num"
      key="${slug,,}#$num"
      for u in "$ud"/*; do
        [ -f "$u" ] || continue
        uk=""; IFS=$'\t' read -r uk _ < "$u" 2>/dev/null
        [ "${uk,,}" = "$key" ] && rm -f "$u"
      done
    done < <(tail -n +2 "$f")
    if printf 'released %s %s\n' "$(date +%s)" "$n" > "$gd/$gid.released.tmp.$$" 2>/dev/null \
       && mv -f "$gd/$gid.released.tmp.$$" "$gd/$gid.released" 2>/dev/null; then
      mc_log "PREQUEUE group-release $slug group=$gid main=${main:0:12} n=$n prs=$prs"
    else
      rm -f "$gd/$gid.released.tmp.$$" 2>/dev/null
      mc_log "PREQUEUE group-release $slug group=$gid: could not write the .released marker; the next tick releases again"
    fi
  done
  return 0
}
