#!/bin/bash
# bin/lib/mc-prequeue.d/fast-lints.sh — THE FAST LINT SET ON THE HEAD MERGED
# ONTO CURRENT MAIN, BEFORE THE QUEUE (BH-8473). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source
# time.
#
# WHY. On 2026-10-25/26 nine Mergify batch drafts went red on fast,
# deterministic lints that one PR merged onto main fails in seconds, and each
# red batch dropped every innocent member. With MC_PREQUEUE_GATE=0 (BH-8062)
# nothing tested a head against current main before a batch.
#
# pq_gate calls pq_fastlint <slug> <num> <url> <head> <main> [<left_s>] after
# the restamp and migration-number hooks, in both gate modes, only when
# pq_fastlint_wanted answers rc 0. It prints one word line:
#   green            every item green, preexisting, unfinished or could-not-run
#   red <suites>     at least one item red on the merged tree and green on main;
#                    <suites> is the comma list of their catalog suite names.
#                    pq_gate answers red and the READY arm parks the row
#                    `prequeue-red: <suites> on main <m12> — …`
#   none <why>       the set did not run: conflict, lock-busy, fetch-failed,
#                    could-not-run. pq_gate goes on as before (fail open)
#
# THE PREPARE, under the project's git lock (mc_git_locked, the gate's
# MC_PREQUEUE_GIT_LOCK_WAIT_S wait), a short critical section: the fetch of
# main and the head into the conductor's clone (mc_merge_tree_fetch, git
# transport only), `git merge-tree --write-tree <main> <head>` and `git
# commit-tree` (a local object, no ref, no push). After the lock: the snapshot
# (bin/lib/rules-pack-snapshot.sh: <w>/repo is main then the merged tree,
# <w>/base is main), read from the object store with auto gc off. A dangling
# commit is never pruned inside git's 2-week window, so no lock is needed.
# THE RUN. bin/prequeue-fast-lints.sh and catalog/prequeue-fast-lints.tsv from
# the hub ($MC_H, not the PR's copies) are copied into <w>, and run as nobody
# with a clean environment (rp_snapshot_run): no token reaches an item. <w> is
# $MC_H/tmp/prequeue-fast/<slug>_<num>.<pid>, or a mktemp dir under /tmp when
# nobody cannot reach that path. <w> is removed on every path.
# THE BASELINE CACHE. $MC_STATE_DIR/prequeue/fastlint-main/<main>.<id> holds
# the rc of item <id> on main <main>; pq_prune's 7-day find removes it.
#
# Log line, one per call:
#   <key> PREQUEUE_FAST_LINT <green|red|none> head=<h12> main=<m12> s=<n>
#     red=<ids|none> unfinished=<ids|none> preexisting=<ids|none>
#     could-not-run=<ids|none> reason=<text>
#
# THE KNOBS (lane merge-conductor; defaults in PQ_KNOB_DEFAULTS):
#   MC_PREQUEUE_FAST_LINTS           1 = on, 0 = off
#   MC_PREQUEUE_FAST_LINTS_BUDGET_S  the set's wall budget; never more than the
#                                    gate's call budget left minus the reserve
#   MC_PREQUEUE_FAST_LINTS_RESERVE_S the seconds kept back from the gate's call
#                                    budget so the call bound never cuts the hook
#   MC_PREQUEUE_FAST_LINTS_JOBS      items at once
#   MC_PREQUEUE_FAST_LINTS_SET       a comma list of catalog ids; empty = every row
# P, KEY and ACTIONS are the READY arm's variables (bin/merge-conductor.sh).

_pq_fl_dir="${BASH_SOURCE[0]%/*}"

# pq_fastlint_wanted — rc 0 = run the hook. No git, no network.
pq_fastlint_wanted() {
  [ "$(pq_knob MC_PREQUEUE_FAST_LINTS)" != 0 ] || return 1
  [ "${ACTIONS:-0}" = 1 ] || return 1
  [ -n "${MC_H:-}" ] && [ -r "$MC_H/bin/prequeue-fast-lints.sh" ] && [ -r "$MC_H/catalog/prequeue-fast-lints.tsv" ]
}

# _pq_fl_read <results.tsv> — sets _PQ_FL_RED, _PQ_FL_SUITES, _PQ_FL_UNF,
#   _PQ_FL_PRE and _PQ_FL_CNR (comma lists). rc 1 when the file has no row.
_pq_fl_read() {
  local id suite rc secs st n=0
  _PQ_FL_RED=""; _PQ_FL_SUITES=""; _PQ_FL_UNF=""; _PQ_FL_PRE=""; _PQ_FL_CNR=""
  [ -r "${1:-}" ] || return 1
  while IFS=$'\t' read -r id suite rc secs st; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    case "$st" in
      red) _PQ_FL_RED="$_PQ_FL_RED,$id"
           case ",$_PQ_FL_SUITES," in *",$suite,"*) ;; *) _PQ_FL_SUITES="$_PQ_FL_SUITES,$suite" ;; esac ;;
      unfinished) _PQ_FL_UNF="$_PQ_FL_UNF,$id" ;;
      preexisting) _PQ_FL_PRE="$_PQ_FL_PRE,$id" ;;
      could-not-run) _PQ_FL_CNR="$_PQ_FL_CNR,$id" ;;
    esac
  done < "$1"
  _PQ_FL_RED=${_PQ_FL_RED#,}; _PQ_FL_SUITES=${_PQ_FL_SUITES#,}; _PQ_FL_UNF=${_PQ_FL_UNF#,}
  _PQ_FL_PRE=${_PQ_FL_PRE#,}; _PQ_FL_CNR=${_PQ_FL_CNR#,}
  [ "$n" -gt 0 ]
}

# _pq_fl_line <word> <head> <main> <s> <reason> — the one log line.
_pq_fl_line() {
  mc_log "${KEY:-$_pq_fl_key} PREQUEUE_FAST_LINT $1 head=${2:0:12} main=${3:0:12} s=$4 red=${_PQ_FL_RED:-none} unfinished=${_PQ_FL_UNF:-none} preexisting=${_PQ_FL_PRE:-none} could-not-run=${_PQ_FL_CNR:-none} reason=$5" 2>/dev/null
}

# _pq_fl_prep <slug> <num> <head> <main> — the prepare, under the git lock.
#   Sets _PQ_FL_PREP: ok | conflict <paths> | fetch-failed <why> |
#   could-not-run <why>; on ok, _PQ_FL_REPO (the clone) and _PQ_FL_MERGED
#   (the merge commit).
_pq_fl_prep() {
  local slug="$1" num="$2" head="$3" main="$4" repo why tree merged out rc=0
  _PQ_FL_PREP=""; _PQ_FL_REPO=""; _PQ_FL_MERGED=""
  mc_funnel_repo "$slug" "${P:-}" || { _PQ_FL_PREP="fetch-failed no checkout of $slug could be authed"; return 0; }
  repo="$MC_FUNNEL_WT"
  if ! why=$(mc_merge_tree_fetch "$repo" "$MC_REMOTE" "$head" "$num"); then
    mc_git_auth_clear; _PQ_FL_PREP="fetch-failed $why"; return 0
  fi
  git -C "$repo" cat-file -e "$main^{commit}" 2>/dev/null \
    || { mc_git_auth_clear; _PQ_FL_PREP="fetch-failed main ${main:0:12} is not in the clone"; return 0; }
  out=$(git -C "$repo" merge-tree --write-tree --name-only "$main" "$head" 2>/dev/null) || rc=$?
  case "$rc" in
    0) tree=$(head -n1 <<<"$out") ;;
    1) mc_git_auth_clear; _PQ_FL_PREP="conflict $(printf '%s\n' "$out" | awk 'f{print} /^$/{f=1}' | tr '\n' ' ' | cut -c1-200)"; return 0 ;;
    *) mc_git_auth_clear; _PQ_FL_PREP="could-not-run git merge-tree rc $rc"; return 0 ;;
  esac
  merged=$(git -C "$repo" -c user.email=prequeue@harness -c user.name=prequeue commit-tree "$tree" -p "$main" -p "$head" -m "prequeue fast lint merge" 2>/dev/null) \
    || { mc_git_auth_clear; _PQ_FL_PREP="could-not-run git commit-tree failed"; return 0; }
  # The auth stays set for the snapshot build (a blob:none clone fetches the
  # blobs git archive reads); pq_fastlint clears it after the build.
  _PQ_FL_REPO="$repo"; _PQ_FL_MERGED="$merged"; _PQ_FL_PREP=ok
}

# _pq_fl_none <reason> — the set did not run: the log line, <w> removed, and
#   `none <first word of the reason>`.
_pq_fl_none() {
  _pq_fl_line none "$_pq_fl_h" "$_pq_fl_m" "$((SECONDS - _pq_fl_t0))" "$1"
  [ -n "$_pq_fl_w" ] && rm -rf "$_pq_fl_w"
  printf 'none %s\n' "${1%% *}"
}

# pq_fastlint <slug> <num> <url> <head> <main> [<left_s>] — see the header.
pq_fastlint() {
  local slug="${1:-}" num="${2:-}" head="${4:-}" main="${5:-}" left="${6:-0}"
  local root="${MC_H:-}" w parent b j set cdir id f rc=0 word reason
  # The git lock wait is the gate's (THE GIT LOCK WAIT, bin/lib/mc-prequeue.sh).
  local MC_GIT_LOCK_WAIT; MC_GIT_LOCK_WAIT=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S)
  _pq_fl_key="$slug#$num"; _pq_fl_h="$head"; _pq_fl_m="$main"; _pq_fl_t0=$SECONDS; _pq_fl_w=""
  _PQ_FL_RED=""; _PQ_FL_UNF=""; _PQ_FL_PRE=""; _PQ_FL_CNR=""
  [ -n "$root" ] && [ -n "$head" ] && [ -n "$main" ] || { _pq_fl_none "could-not-run no harness root, head or main"; return 0; }
  command -v rp_snapshot_build >/dev/null 2>&1 || . "$_pq_fl_dir/../rules-pack-snapshot.sh" 2>/dev/null
  command -v rp_snapshot_build >/dev/null 2>&1 || { _pq_fl_none "could-not-run no bin/lib/rules-pack-snapshot.sh"; return 0; }
  rp_snapshot_probe 2>/dev/null || { _pq_fl_none "could-not-run setpriv cannot switch to nobody here"; return 0; }
  b=$(pq_knob MC_PREQUEUE_FAST_LINTS_BUDGET_S); j=$(pq_knob MC_PREQUEUE_FAST_LINTS_JOBS)
  local rs; rs=$(pq_knob MC_PREQUEUE_FAST_LINTS_RESERVE_S)
  if [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -gt 0 ] && [ $((left - rs)) -lt "$b" ]; then b=$((left - rs)); fi
  [ "$b" -ge 1 ] && [ "$j" -ge 1 ] || { _pq_fl_none "could-not-run no time left in the gate's call budget"; return 0; }
  set=$(lane_knob merge-conductor MC_PREQUEUE_FAST_LINTS_SET "${P:-}" 2>/dev/null)
  set=${set//[!a-z0-9,-]/}

  parent="$root/tmp/prequeue-fast"
  mkdir -p "$parent" 2>/dev/null && chmod 711 "$parent" 2>/dev/null
  if rp_snapshot_reachable "$parent"; then
    w="$parent/${slug//\//_}_${num}.$BASHPID"
    rm -rf "$w"; mkdir "$w" 2>/dev/null || w=""
  else
    # nobody cannot reach $MC_H (a root-only /root): the rules pack's fallback.
    w=$(mktemp -d /tmp/prequeue-fast.XXXXXX 2>/dev/null) || w=""
  fi
  [ -n "$w" ] || { _pq_fl_none "could-not-run no work dir nobody can reach"; return 0; }
  _pq_fl_w="$w"
  mkdir -p "$w/runner/bin" "$w/runner/catalog" "$w/cache" && chmod 711 "$w" \
    || { _pq_fl_none "could-not-run cannot make $w"; return 0; }
  cp "$root/bin/prequeue-fast-lints.sh" "$w/runner/bin/" && cp "$root/catalog/prequeue-fast-lints.tsv" "$w/runner/catalog/" \
    || { _pq_fl_none "could-not-run cannot copy the runner"; return 0; }
  cdir="${MC_STATE_DIR:-}/prequeue/fastlint-main"
  for f in "$cdir/$main".*; do [ -r "$f" ] && cp "$f" "$w/cache/${f##*/$main.}.rc"; done

  mc_git_locked "${P:-}" _pq_fl_prep "$slug" "$num" "$head" "$main" || rc=$?
  [ "$rc" = 99 ] && { _pq_fl_none "lock-busy the git lock for ${P:-?} was busy"; return 0; }
  case "$_PQ_FL_PREP" in
    ok) ;;
    '') _pq_fl_none "could-not-run the prepare did not answer (rc $rc)"; return 0 ;;
    *) _pq_fl_none "$_PQ_FL_PREP"; return 0 ;;
  esac
  # A big commit would start a detached `git gc --auto` that writes into <w>
  # while it is removed: auto gc and auto maintenance are off for the build.
  rc=0
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false \
    rp_snapshot_build "$_PQ_FL_REPO" "$main" "$_PQ_FL_MERGED" "$w" >/dev/null 2>"$w/build.err" || rc=$?
  mc_git_auth_clear
  [ "$rc" = 0 ] || { _pq_fl_none "could-not-run $(head -n1 "$w/build.err" 2>/dev/null)"; return 0; }
  # The set gets what the gate's call budget has left after the prepare.
  if [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -gt 0 ] && [ $((left - (SECONDS - _pq_fl_t0) - rs)) -lt "$b" ]; then
    b=$((left - (SECONDS - _pq_fl_t0) - rs))
    [ "$b" -ge 1 ] || { _pq_fl_none "could-not-run no time left in the gate's call budget after the prepare"; return 0; }
  fi

  rp_snapshot_run "$w/repo" bash "$w/runner/bin/prequeue-fast-lints.sh" --run --catalog "$w/runner/catalog/prequeue-fast-lints.tsv" \
    --tree "$w/repo" --base origin/main --base-tree "$w/base" --out "$w/out" --cache-dir "$w/cache" \
    --budget-s "$b" --jobs "$j" ${set:+--set "$set"} > "$w/run.out" 2>&1
  if ! _pq_fl_read "$w/out/results.tsv"; then
    _pq_fl_none "could-not-run the runner wrote no results ($(tail -n1 "$w/run.out" 2>/dev/null))"; return 0
  fi
  if [ -n "${MC_STATE_DIR:-}" ] && mkdir -p "$cdir" 2>/dev/null; then
    for f in "$w/cache/"*.rc; do
      [ -r "$f" ] || continue
      id=${f##*/}; id=${id%.rc}
      [[ "$id" =~ ^[a-z0-9-]+$ ]] && [[ "$(cat "$f")" =~ ^[0-9]+$ ]] && cp "$f" "$cdir/$main.$id"
    done
  fi
  if [ -n "$_PQ_FL_RED" ] && [ -n "$_PQ_FL_SUITES" ]; then word="red $_PQ_FL_SUITES"; reason="red on the merged tree, green on main"
  else word=green; reason="no item red on the merged tree and green on main"; fi
  _pq_fl_line "${word%% *}" "$head" "$main" "$((SECONDS - _pq_fl_t0))" "$reason"
  rm -rf "$w"
  printf '%s\n' "$word"
}
