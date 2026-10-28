#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/group.sh — ONE PRE-QUEUE GATE RUN PER MAIN SHA FOR A
# GROUP OF READY HEADS (BH-8327). Sourced by bin/lib/mc-prequeue.sh's hook loop,
# never executed; the only side effect at source time is the knob defaults.
#
# WHY. pq_resolve dispatched prequeue-gate.yml once per (PR, head, main). Five
# READY heads on one main made five runs (#8152: 20 runs on one main).
#
# THE RULE. A head that reaches the dispatch point of pq_resolve (after the
# cache, reuse, adopt, impact-reuse and veto rules) JOINS the open group of
# this repo and main for this conductor run instead of dispatching. Its cache
# entry is `pending <now> -` and `<path>.group` names the group id. The gate
# answers hold. After every PR worker of the repo answered, the conductor calls
# pq_group_flush once (bin/merge-conductor.sh), which dispatches ONE run of
# .github/workflows/prequeue-group-gate.yml per open group. That run is a
# matrix: one job per head, and each job calls the unchanged per-head
# prequeue-gate.yml (workflow_call). So each head keeps its own merge onto main,
# its own suites and its own prequeue-verdict annotation. On a later tick,
# pq_settle reads a grouped head through pq_group_read: one run-list read, one
# jobs read and one annotation read per gate job, ONCE per group (the verdicts
# file). Each head gets its own row, so a red head parks only itself.
# A head that asks after the flush opens the next group. A dispatched group
# (`.run`) is never flushed again.
#
# THE SHARE RULE (BH-8610, knob MC_PREQUEUE_GROUP_SHARE_S, default 300, 0 = the
# BH-8327 rule). The backstop and the wakes start one keyed conductor run per
# PR (BH-6000), each with its own tick id. Under the BH-8327 rule each of them
# opened its own group, and each flush abandoned the others' groups: a re-gate
# of 6 PRs after a main move became n=1 groups and abandons. Now a head may
# also join an open group of this repo and main that ANOTHER run opened less
# than the knob's seconds ago, and it writes `<gid>.joined.<tick>`. A flush
# dispatches an open group of its own tick, or one this run joined that is
# still younger than the knob. Every other open group is abandoned as before,
# so a run with no member in a group still abandons it. The completed group
# run is read on every tick by pq_group_release_sweep (group-release.sh).
#
# NOT GROUPED, per head as before: the knob is 0; the repo has no
# prequeue-group-gate.yml (probe 404, or a probe that is unreadable); a named
# suites run (batch-solo.sh calls pq_dispatch directly). A per-PR machine run
# (MC_ON_MACHINE=1 without the project lease and its fence) dispatches
# nothing: it holds and writes the defer word `prequeue-group`, and the hub
# runs that PR on its next tick, where the head joins the hub's group.
# An open group that its own run did not flush (a worker crash, a lock that
# stayed busy) is abandoned by the next flush: its members' pending entries
# go, nothing is dispatched, and the members ask again.
#
# THE STORE ($MC_STATE_DIR/prequeue/groups/; pq_prune deletes files there
# after 7 days, as for every cache file):
#   <slug_>_<main>_<gid>.open|.run|.refused
#       line 1 `open|dispatched|refused <opened_at> <tick_id|-> <main>`, then
#       one `<num> <head>` line per member
#   <gid>.verdicts      one `<head> <verdict> <run_id> <suites|-> [why]` line
#                       per member, written once from the completed run
#   <gid>.joined.<tick> empty: the run <tick> has a member in this open group
#                       (BH-8610); removed when the group is dispatched or
#                       abandoned
#   <gid>.released      `released <epoch> <n>`: the sweep released the members
#                       (BH-8610, group-release.sh)
#   <gid>.<head>.why|fail|timing  that head's invariant sidecars
# And next to each member's cache entry: `<path>.group`, one line `<gid>`.
#
# THE KNOBS (lane merge-conductor, catalog/lanes.d/merge-conductor.knobs.d/):
#   MC_PREQUEUE_GROUP       1 = group (default), 0 = one run per head; row
#                           lane.merge-conductor.<project>.mc_prequeue_group
#   MC_PREQUEUE_GROUP_MAX   heads per group run (default 10); a full group
#                           opens the next one. The jobs read asks for MAX + 1
#                           jobs (the plan job and the gate jobs).
#   MC_PREQUEUE_GROUP_PAGE  runs per run-list read (default 30)
#   MC_PREQUEUE_GROUP_SHARE_S  seconds another run's open group stays joinable
#                           (default 300, 0 = same run only; THE SHARE RULE)
# The group lock waits MC_PREQUEUE_GIT_LOCK_WAIT_S; the group dispatch is
# bounded by MC_PREQUEUE_CALL_BUDGET_S (0 = no bound).
#
#   pq_group_wf_present <slug>      sets _pq_gwf to yes, no or unknown
#   pq_group_title <gid> <main>     the group run's run-name
#   pq_group_join <slug> <num> <head> <main> <path>
#       rc 0 joined (_pq_gid set), 1 not grouped (the caller dispatches per
#       head), 3 the key is busy or already written, 4 nothing could be
#       written, 5 deferred to the hub (PQ_WHY set)
#   pq_group_flush <slug>           dispatch or abandon each open group
#   pq_group_read <slug> <num> <head> <main> <path>
#       `<verdict> <run_id> <suites|-> [why]`, or nothing while it is pending

PQ_GROUP_WF=prequeue-group-gate.yml
case " ${PQ_KNOB_DEFAULTS:-} " in
  *" MC_PREQUEUE_GROUP="*) ;;
  *) PQ_KNOB_DEFAULTS="${PQ_KNOB_DEFAULTS:-} MC_PREQUEUE_GROUP=1 MC_PREQUEUE_GROUP_MAX=10 MC_PREQUEUE_GROUP_PAGE=30 MC_PREQUEUE_GROUP_SHARE_S=300" ;;
esac

# pq_group_title <gid> <main> — the run-name of prequeue-group-gate.yml.
pq_group_title() { printf 'prequeue group=%s main=%s' "$1" "$2"; }

# _pq_gdir — the group store.
_pq_gdir() { printf '%s/prequeue/groups' "${MC_STATE_DIR:-}"; }

# pq_group_wf_present <slug> — one probe per repo per tick (memo in
#   MC_TICK_DIR). yes only when the answer names the group workflow's path, so
#   a stub or a proxy that answers 200 for any path is no.
pq_group_wf_present() {
  local slug="$1" memo="" raw="" rc=0
  _pq_gwf=unknown
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-gwf.${slug//\//_}"
  if [ -n "$memo" ] && [ -s "$memo" ]; then read -r _pq_gwf < "$memo"; return 0; fi
  mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_GROUP_WF" || rc=$?
  case "$rc" in
    0) if [ "$(jq -r '.path // empty' <<<"$raw" 2>/dev/null)" = ".github/workflows/$PQ_GROUP_WF" ]; then _pq_gwf=yes; else _pq_gwf=no; fi ;;
    44) _pq_gwf=no ;;
    *) return 0 ;;
  esac
  [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null && printf '%s\n' "$_pq_gwf" > "$memo" 2>/dev/null
  return 0
}

# _pq_glock <slug> — the repo's group lock file, created; rc 1 when it cannot be.
_pq_glock() {
  local lk="$MC_H/locks/prequeue-group-${1//\//_}.lock"
  mkdir -p "${lk%/*}" 2>/dev/null; { : >> "$lk"; } 2>/dev/null || return 1
  printf '%s' "$lk"
}

# _pq_gwrite <file> <line 1> [member lines on stdin] — one atomic write.
_pq_gwrite() {
  local f="$1" t="$1.tmp.$$"
  { printf '%s\n' "$2"; cat; } > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
}

# pq_group_join <slug> <num> <head> <main> <path> — see the header.
pq_group_join() {
  local slug="$1" num="$2" head="$3" main="$4" path="$5" lk glk gd w out rc=0
  _pq_gid=""
  [ "$(pq_knob MC_PREQUEUE_GROUP)" != 0 ] || return 1
  [ -n "${MC_H:-}" ] && [ -n "${MC_STATE_DIR:-}" ] && [ -n "$path" ] || return 1
  pq_group_wf_present "$slug"
  [ "$_pq_gwf" = yes ] || return 1
  if [ "${MC_ON_MACHINE:-}" = 1 ] && ! { [ "${MC_LEASED_RUN:-}" = 1 ] && [ -n "${MC_LEASE_FENCE:-}" ]; }; then
    declare -F mc_defer_word >/dev/null && mc_defer_word prequeue-group "$slug#$num"
    PQ_WHY="prequeue group dispatch is the hub's; asked on its next tick"
    mc_log "PREQUEUE group-defer #$num head=${head:0:12} main=${main:0:12} -> hub" 2>/dev/null
    return 5
  fi
  lk="$MC_H/locks/prequeue-${slug//\//_}-$num-$head.lock"
  mkdir -p "${lk%/*}" 2>/dev/null; { : >> "$lk"; } 2>/dev/null || return 4
  glk=$(_pq_glock "$slug") || return 4
  gd=$(_pq_gdir); mkdir -p "$gd" 2>/dev/null || return 4
  w=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S)
  out=$( {
    flock -n 9 || exit 3
    [ -n "$(pq_cache_get "$path")" ] && exit 3
    flock -w "$w" 8 || exit 3
    max=$(pq_knob MC_PREQUEUE_GROUP_MAX); tick="${MC_TICK_ID:--}"; g=""; n=0
    share=$(pq_knob MC_PREQUEUE_GROUP_SHARE_S); now=$(date +%s)
    for f in "$gd/${slug//\//_}_${main}_"*.open; do
      [ -r "$f" ] || continue
      read -r st oat tk _ < "$f"
      [ "$st" = open ] || continue
      # THE SHARE RULE: this run's group, or another run's young one.
      [[ "$oat" =~ ^[0-9]+$ ]] || oat=0
      [ "$tk" = "$tick" ] || { [ "$share" -gt 0 ] && [ $((now - oat)) -lt "$share" ]; } || continue
      n=$(( $(grep -c . "$f") - 1 ))
      [ "$n" -lt "$max" ] && { g="$f"; break; }
    done
    if [ -z "$g" ]; then
      gid="g$(date +%s)$(od -An -tx1 -N2 /dev/urandom 2>/dev/null | tr -d ' \n')"
      [[ "$gid" =~ ^g[0-9]+[0-9a-f]{4}$ ]] || exit 4
      g="$gd/${slug//\//_}_${main}_$gid.open"; n=0
      _pq_gwrite "$g" "open $(date +%s) $tick $main" < /dev/null || exit 4
    fi
    gid="${g##*_}"; gid="${gid%.open}"
    { tail -n +2 "$g"; printf '%s %s\n' "$num" "$head"; } | _pq_gwrite "$g" "$(head -n1 "$g")" || exit 4
    if ! { printf '%s\n' "$gid" > "$path.group" 2>/dev/null && pq_cache_put "$path" pending "$(date +%s)" - ""; }; then
      rm -f "$path.group" "$path" 2>/dev/null
      grep -vx "$num $head" "$g" | { read -r l1; _pq_gwrite "$g" "$l1"; }
      exit 4
    fi
    : > "$gd/$gid.joined.${tick//[^A-Za-z0-9._-]/_}" 2>/dev/null
    printf '%s %s\n' "$gid" "$((n + 1))"
  } 9>"$lk" 8>"$glk" ) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  read -r _pq_gid n <<<"$out"
  mc_log "PREQUEUE group-join #$num head=${head:0:12} main=${main:0:12} group=$_pq_gid n=$n"
  return 0
}

# _pq_gmembers <group file> <slug> <gid> <main> — the members still waiting on
#   this group: `<num> <head> <path> <at>` for each one whose entry is pending
#   and whose `.group` names this gid.
_pq_gmembers() {
  local f="$1" slug="$2" gid="$3" main="$4" num head p st at g
  tail -n +2 "$f" | while read -r num head; do
    [[ "$num" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    p=$(pq_key "$slug" "$num" "$head" "$main")
    read -r st at _ <<<"$(pq_cache_get "$p")"
    g=""; [ -r "$p.group" ] && read -r g < "$p.group"
    [ "$st" = pending ] && [ "$g" = "$gid" ] && printf '%s %s %s %s\n' "$num" "$head" "$p" "${at:-0}"
  done
}

# pq_group_flush <slug> — after the PR workers: dispatch each open group of
#   this repo once, or abandon it. No open group: no lock and no call.
pq_group_flush() {
  local slug="$1" gd glk w
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "${MC_H:-}" ] && [ -n "$slug" ] || return 0
  gd=$(_pq_gdir)
  compgen -G "$gd/${slug//\//_}_*.open" >/dev/null 2>&1 || return 0
  glk=$(_pq_glock "$slug") || return 0
  w=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S)
  (
    if ! flock -w "$w" 8; then
      mc_log "PREQUEUE group-flush $slug: the group lock was busy; the next run flushes or abandons"; exit 0
    fi
    knob=$(pq_knob MC_PREQUEUE_GROUP); tick="${MC_TICK_ID:--}"; b=$(pq_knob MC_PREQUEUE_CALL_BUDGET_S)
    share=$(pq_knob MC_PREQUEUE_GROUP_SHARE_S); now=$(date +%s)
    for f in "$gd/${slug//\//_}_"*.open; do
      [ -r "$f" ] || continue
      read -r st oat tk m < "$f"
      gid="${f##*_}"; gid="${gid%.open}"
      [ "$st" = open ] && [[ "$m" =~ ^[0-9a-f]{40}$ ]] || { rm -f "$f"; continue; }
      mapfile -t mem < <(_pq_gmembers "$f" "$slug" "$gid" "$m")
      # THE SHARE RULE: another run's group is this run's to dispatch when this
      # run joined it and it is still younger than the knob.
      mine=0; [ "$tk" = "$tick" ] && mine=1
      [[ "$oat" =~ ^[0-9]+$ ]] || oat=0
      [ "$mine" = 0 ] && [ "$share" -gt 0 ] && [ -e "$gd/$gid.joined.${tick//[^A-Za-z0-9._-]/_}" ] \
        && [ $((now - oat)) -lt "$share" ] && mine=1
      rm -f "$gd/$gid.joined."* 2>/dev/null
      if [ "$mine" = 0 ] || [ "$knob" = 0 ] || [ "${#mem[@]}" = 0 ]; then
        why="the group is from another run"; [ "$knob" = 0 ] && why="MC_PREQUEUE_GROUP=0"; [ "${#mem[@]}" = 0 ] && why="no member waits on it"
        for r in "${mem[@]}"; do read -r _ _ p _ <<<"$r"; rm -f "$p" "$p.group"; done
        rm -f "$f"
        mc_log "PREQUEUE group-abandon $slug main=${m:0:12} group=$gid n=${#mem[@]} ($why): nothing dispatched; the members ask again"
        continue
      fi
      list=""; prs=""
      for r in "${mem[@]}"; do read -r n h _ _ <<<"$r"; list="${list:+$list,}$n:$h"; prs="${prs:+$prs,}#$n"; done
      mc_use_token "$slug"
      args=(-f "main=$m" -f "group_id=$gid" -f "members=$list")
      # shellcheck disable=SC2207
      declare -F pq_invariants_args >/dev/null && args+=($(pq_invariants_args))
      # shellcheck disable=SC2207
      declare -F pq_learned_args >/dev/null && args+=($(pq_learned_args))
      to=(); [ "$b" != 0 ] && to=(timeout "$b")
      if "${to[@]}" gh workflow run "$PQ_GROUP_WF" -R "$slug" --ref main "${args[@]}" >/dev/null 2>&1; then
        mc_log "PREQUEUE group-dispatch $slug main=${m:0:12} group=$gid n=${#mem[@]} prs=$prs"
        # The .run file lists the members this run was dispatched for, no other.
        if printf '%s\n' "${mem[@]}" | cut -d' ' -f1,2 | _pq_gwrite "${f%.open}.run" "dispatched $oat $tk $m"; then rm -f "$f"
        else mc_log "PREQUEUE group-dispatch $slug group=$gid: could not record the dispatch; the next flush abandons it"; fi
        continue
      fi
      for r in "${mem[@]}"; do read -r _ _ p at <<<"$r"; pq_cache_put "$p" could-not-run "$at" group-dispatch-refused "" alerted; done
      printf '%s\n' "${mem[@]}" | cut -d' ' -f1,2 | _pq_gwrite "${f%.open}.refused" "refused $oat $tk $m" && rm -f "$f"
      mc_log "PREQUEUE group-refused $slug main=${m:0:12} group=$gid n=${#mem[@]} prs=$prs"
      if [ -x "$MC_H/bin/lane-alert.sh" ]; then
        "$MC_H/bin/lane-alert.sh" --severity warn merge-conductor \
          "$slug prequeue group $gid on main ${m:0:12} could not be dispatched (group-dispatch-refused) for $prs: enqueued without it, the batch is the backstop" >/dev/null 2>&1 || true
      fi
    done
    exit 0
  ) 8>"$glk"
  return 0
}

# _pq_gread_run <slug> <gid> <main> <out> — read the completed group run once
#   and write <out> (the verdicts file) and the head sidecars. rc 0 written,
#   1 no completed run yet, 75 a read failed.
_pq_gread_run() {
  local slug="$1" gid="$2" main="$3" out="$4" gd raw="" memo="" id st jid page max msgs='[]' f h r v su why
  local gf num head n green=0 red=0 other=0
  gd=$(_pq_gdir); gf="$gd/${slug//\//_}_${main}_$gid.run"
  [ -r "$gf" ] || return 1
  page=$(pq_knob MC_PREQUEUE_GROUP_PAGE); max=$(pq_knob MC_PREQUEUE_GROUP_MAX)
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-gruns.${slug//\//_}"
  if [ -n "$memo" ] && [ -s "$memo" ]; then raw=$(cat "$memo" 2>/dev/null)
  else
    mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_GROUP_WF/runs?event=workflow_dispatch&per_page=$page" || return 75
    jq -e '.workflow_runs | type == "array"' >/dev/null 2>&1 <<<"$raw" || return 75
    [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null && printf '%s\n' "$raw" > "$memo" 2>/dev/null
  fi
  read -r id st <<<"$(jq -r --arg t "$(pq_group_title "$gid" "$main")" '[.workflow_runs[]? | select(.display_title == $t)]
    | sort_by(.created_at) | last // empty | "\(.id) \(.status)"' <<<"$raw" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] && [ "$st" = completed ] || return 1
  mc_rest_var raw gh_rest GET "repos/$slug/actions/runs/$id/jobs?per_page=$((max + 1))" || return 75
  # The plan job prints no verdict; each gate job that concluded success is read.
  for jid in $(jq -r '.jobs[]? | select(.name != "plan" and .conclusion == "success") | .id // empty' <<<"$raw" 2>/dev/null); do
    [[ "$jid" =~ ^[0-9]+$ ]] || continue
    mc_rest_var raw gh_rest GET "repos/$slug/check-runs/$jid/annotations" || return 75
    msgs=$(jq -c --argjson a "$msgs" --arg j "$jid" '$a + [.[]? | select(.title | IN("prequeue-verdict", "prequeue-invariant-timing",
      "prequeue-invariant-fail", "prequeue-invariant-slow")) | {job: $j, title, message}]' <<<"$raw" 2>/dev/null) || return 75
  done
  : > "$out.tmp.$$" 2>/dev/null || return 75
  while read -r num head; do
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    # The verdict messages that name this head; the head field is the only key.
    n=$(jq --arg h "$head" '[.[] | select(.title == "prequeue-verdict" and (((.message // "") | capture("head=(?<h>[0-9a-f]{40})").h) // "") == $h)] | length' <<<"$msgs" 2>/dev/null)
    if [ "$n" != 1 ]; then
      printf '%s could-not-run %s - annotation-count-%s\n' "$head" "$id" "${n:-0}" >> "$out.tmp.$$"; other=$((other + 1)); continue
    fi
    r=$(jq -c --arg h "$head" '[.[] | select(.title == "prequeue-verdict" and (((.message // "") | capture("head=(?<h>[0-9a-f]{40})").h) // "") == $h)][0]' <<<"$msgs")
    read -r v su why <<<"$(pq_parse_verdict "$(jq -r '.message' <<<"$r")" "$head" "$main")"
    printf '%s %s %s %s%s\n' "$head" "$v" "$id" "${su:--}" "${why:+ $why}" >> "$out.tmp.$$"
    case "$v" in green) green=$((green + 1)) ;; red) red=$((red + 1)) ;; *) other=$((other + 1)) ;; esac
    [ "$v" = could-not-run ] && continue
    jid=$(jq -r '.job' <<<"$r")
    for f in why fail timing; do
      case "$f" in
        why) h=""; [ "$v" = red ] && h="$why" ;;
        fail) h=$(jq -r --arg j "$jid" '.[] | select(.job == $j and .title == "prequeue-invariant-fail") | .message
          | (index(": ") // -1) as $i | if $i < 0 then "### \(.)\n" else "### \(.[:$i])\n\(.[$i + 2:])\n" end' <<<"$msgs" 2>/dev/null) ;;
        timing) h=$(jq -r --arg j "$jid" '[.[] | select(.job == $j)] | ([.[] | select(.title == "prequeue-invariant-timing") | .message] | first // empty) as $t
          | if $t then ([$t] + [.[] | select(.title == "prequeue-invariant-slow") | .message]) | .[] else empty end' <<<"$msgs" 2>/dev/null) ;;
      esac
      [ -n "$h" ] && printf '%s\n' "$h" > "$gd/$gid.$head.$f" 2>/dev/null
    done
  done < <(tail -n +2 "$gf")
  mv -f "$out.tmp.$$" "$out" 2>/dev/null || { rm -f "$out.tmp.$$"; return 75; }
  mc_log "PREQUEUE group-read $slug group=$gid run=$id green=$green red=$red other=$other"
  return 0
}

# pq_group_read <slug> <num> <head> <main> <path> — see the header.
pq_group_read() {
  local slug="$1" num="$2" head="$3" main="$4" path="$5" gid="" gd base vf rk w h v id rest f
  [ -r "$path.group" ] && read -r gid < "$path.group"
  [[ "$gid" =~ ^g[0-9a-f]+$ ]] || return 0
  gd=$(_pq_gdir); base="$gd/${slug//\//_}_${main}_$gid"; vf="$gd/$gid.verdicts"
  [ -e "$base.open" ] && return 0
  [ -e "$base.refused" ] && { echo "could-not-run - - group-dispatch-refused"; return 0; }
  if [ ! -s "$vf" ]; then
    [ -e "$base.run" ] || return 0
    rk="$gd/$gid.read.lock"; { : >> "$rk"; } 2>/dev/null || return 0
    w=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S)
    ( flock -w "$w" 7 || exit 3; [ -s "$vf" ] && exit 0; _pq_gread_run "$slug" "$gid" "$main" "$vf" ) 7>"$rk" || return 0
    [ -s "$vf" ] || return 0
  fi
  while read -r h v id rest; do
    [ "$h" = "$head" ] || continue
    for f in why fail timing; do
      [ -r "$gd/$gid.$head.$f" ] || continue
      if cp -f "$gd/$gid.$head.$f" "$path.$f" 2>/dev/null; then
        [ "$f" = timing ] && mc_log "$slug#$num PREQUEUE_INVARIANTS head ${head:0:8} main ${main:0:12}: $(head -n1 "$path.timing")"
      else mc_log "$slug#$num prequeue: could not write the .$f sidecar for ${head:0:8} on main ${main:0:12}"; fi
    done
    echo "$v $id $rest"; return 0
  done < "$vf"
  read -r _ _ id _ < "$vf"
  echo "could-not-run ${id:--} - missing-head"
}
