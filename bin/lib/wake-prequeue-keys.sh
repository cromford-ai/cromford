#!/bin/bash
# bin/lib/wake-prequeue-keys.sh — turn a checks wake's MAIN sha into the READY
# PRs whose pre-queue gate run on that main has finished (BH-8173). Sourced by
# bin/wake-loop.sh and bin/merge-conductor-wake.sh, never executed.
#
# WHY. pq_dispatch runs prequeue-gate.yml with --ref main, so the check_run of
# a gate run carries the main sha, not a PR head. wck_sha_prs can never place
# that sha (GET commits/<sha>/pulls answers no open PR), so the wake was
# dropped and every PR held prequeue-pending on that main waited for the
# hourly full tick. The conductor's own pre-queue cache already names them:
#   state/merge-conductor/prequeue/<owner_repo>_<num>_<head40>_<main40>
# with first word `pending` (pq_key / pq_cache_put, bin/lib/mc-prequeue.sh).
#
# GROUPS (BH-8610). A head that joined a BH-8327 group has a `<entry>.group`
# sidecar (one line, the group id). Its run is prequeue-group-gate.yml, titled
# `prequeue group=<gid> main=<main>`, also dispatched with --ref main. Before
# BH-8610 the wake read only prequeue-gate.yml runs, so a finished group run
# woke none of its members. Now ONE group runs read places every member.
#
# gh-rest: no-graphql
#
# No side effect at source time, no `exit`, no root default (D43).

if ! command -v gh_rest_var >/dev/null 2>&1; then
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"
fi

# wpk_title <num> <head> <main> — the gate run's title. The same format as
# pq_run_title (bin/lib/mc-prequeue.d/dispatch.sh); a test pins the two equal.
wpk_title() { printf 'prequeue pr=%s head=%s main=%s' "$1" "$2" "$3"; }

# wpk_group_title <gid> <main> — the group run's title. The same format as
# pq_group_title (bin/lib/mc-prequeue.d/group.sh); a test pins the two equal.
wpk_group_title() { printf 'prequeue group=%s main=%s' "$1" "$2"; }

# wpk_gid <state_dir> <lrepo> <num> <head> <sha> — the group id in the entry's
# `.group` sidecar, or nothing (no sidecar, or a line that is not a gid). The
# entry's file name keeps the slug's case, so the match is case-insensitive.
wpk_gid() {
  local dir="$1" pre="${2//\//_}_" f name g=""
  for f in "$dir/prequeue/"*"_$3_$4_$5.group"; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name,,}"
    [ "$name" = "$pre$3_$4_$5.group" ] || continue
    read -r g < "$f" 2>/dev/null
    [[ "$g" =~ ^g[0-9a-f]+$ ]] && { printf '%s' "$g"; return 0; }
  done
  return 0
}

# _wpk_titles <var> <workflow> <lrepo> <sha> <page> — one completed-runs read
# into <var>, the titles one per line. rc 1 when the read fails or the body is
# not a run list.
_wpk_titles() {
  local -n _wt="$1"; local body=""
  # gh_rest_var, never $(gh_rest ...): a command substitution drops the
  # GH_REST_STATUS the helper sets (gh-rest-no-subshell-lint).
  command -v gh_rest_var >/dev/null 2>&1 \
    && gh_rest_var body GET "repos/$3/actions/workflows/$2/runs?event=workflow_dispatch&head_sha=$4&status=completed&per_page=$5" \
    && _wt=$(jq -r 'if (.workflow_runs | type) == "array" then .workflow_runs[]
         | select(.status == "completed") | (.display_title // empty) else error("not a run list") end' <<<"$body" 2>/dev/null)
}

# wpk_pending <state_dir> <lrepo> <sha> — print `<num> TAB <head40>` for each
# cache entry of <lrepo> that is `pending` on main <sha>. A local scan, no
# network. Exact 40-hex sha only; a named-suites entry (`_<fp>` suffix), a
# sidecar or a .tmp file never matches. rc 0 = one or more printed, else rc 1.
wpk_pending() {
  local dir="${1:-}" lrepo="${2:-}" sha="${3:-}" pre f name rest st out=""
  lrepo="${lrepo,,}"
  [[ "$lrepo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "$dir" ] && [ -d "$dir/prequeue" ] || return 1
  pre="${lrepo//\//_}_"
  for f in "$dir/prequeue/"*"_$sha"; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name,,}"
    [[ "$name" == "$pre"* ]] || continue
    rest="${name#"$pre"}"; rest="${rest%_"$sha"}"
    [[ "$rest" =~ ^([0-9]+)_([0-9a-f]{40})$ ]] || continue
    st=""; read -r st _ < "$f" 2>/dev/null
    [ "$st" = pending ] || continue
    out+="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\n'
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# wpk_done_prs <state_dir> <lrepo> <sha> [page] — print `<lrepo>#<n>` for each
# PR pending on main <sha> whose gate run has completed, sorted, deduped.
#   rc 1  nothing pending on <sha>: no output and NO read. The caller goes on
#         to wck_sha_prs as before.
#   rc 0  the reads answered; the PRs printed have a completed run.
#   rc 3  the reads answered and no pending PR's run has completed yet.
#   rc 2  a read failed or did not answer a run list: FAIL-OPEN, every PR
#         pending on <sha> is printed and the conductor makes the call.
# The reads, each only when a pending head needs it (so one lookup makes one
# read, or two when <sha> has both kinds):
#   per-head  GET repos/<lrepo>/actions/workflows/prequeue-gate.yml/runs
#             ?event=workflow_dispatch&head_sha=<sha>&status=completed&per_page=<page>
#             a head with no valid `.group` sidecar matches wpk_title.
#   group     the same query on prequeue-group-gate.yml (BH-8610); a head
#             whose sidecar names <gid> matches wpk_group_title <gid> <sha>,
#             so one completed group run prints every member.
# <page> is 1..100, else 100. The callers pass the knob WAKE_CONDUCTOR_PREQUEUE_PAGE
# (lane wake-loop) or MC_WAKE_PREQUEUE_PAGE (lane merge-conductor-wake); 100
# (the API maximum) is the documented fallback of both rows. A run past that
# page is a miss here; its own workflow_run `pr` wake still wakes its PR.
wpk_done_prs() {
  local dir="${1:-}" lrepo="${2:-}" sha="${3:-}" page="${4:-100}" pend num head g out=""
  local per="" grp="" ptitles="" gtitles=""
  lrepo="${lrepo,,}"
  case "$page" in ''|*[!0-9]*) page=100 ;; esac
  { [ "$page" -ge 1 ] && [ "$page" -le 100 ]; } 2>/dev/null || page=100
  pend=$(wpk_pending "$dir" "$lrepo" "$sha") || return 1
  while IFS=$'\t' read -r num head; do
    [ -n "$num" ] || continue
    g=$(wpk_gid "$dir" "$lrepo" "$num" "$head" "$sha")
    if [ -n "$g" ]; then grp+="$num $g"$'\n'; else per+="$num $head"$'\n'; fi
  done <<<"$pend"
  if { [ -n "$per" ] && ! _wpk_titles ptitles prequeue-gate.yml "$lrepo" "$sha" "$page"; } \
     || { [ -n "$grp" ] && ! _wpk_titles gtitles prequeue-group-gate.yml "$lrepo" "$sha" "$page"; }; then
    cut -f1 <<<"$pend" | sort -n -u | sed "s|^|$lrepo#|"
    return 2
  fi
  while read -r num head; do
    [ -n "$num" ] || continue
    grep -qxF -- "$(wpk_title "$num" "$head" "$sha")" <<<"$ptitles" && out+="$num"$'\n'
  done <<<"$per"
  while read -r num g; do
    [ -n "$num" ] || continue
    grep -qxF -- "$(wpk_group_title "$g" "$sha")" <<<"$gtitles" && out+="$num"$'\n'
  done <<<"$grp"
  [ -n "$out" ] || return 3
  printf '%s' "$out" | sort -n -u | sed "s|^|$lrepo#|"
}
