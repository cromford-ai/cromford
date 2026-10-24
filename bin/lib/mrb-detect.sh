# shellcheck shell=bash
# bin/lib/mrb-detect.sh — main-red-bisect: find the red episodes on main and
# check an episode is still red. Sourced, never run.
#
# BH-3685 contract (BH-3693): siblings replace the bodies, never the
# signatures. The file defines functions only: no shell options, no exit, no
# output when sourced.
#
# THE EPISODE FILE. One `key=value` per line, no quoting, value to end of line.
# Written by mrb_detect_episodes:
#   source=flag|nightly|full  what reported the red
#   slug=<owner/repo>
#   red=<sha>               first red main sha seen
#   green=<sha>             last green main sha before it
#   run=<id>                the red CI run
#   wf=<name>               its workflow
#   job=<id>                the red job
#   suites=<paths>          red suites, space-separated tests/ paths
#   outcome=                empty (bisect it) | nosuite | noanchor
# Appended by the driver:
#   culprit=<sha>           the merge the bisect found
#   pr=<number>             the PR that merge landed
#   pr_title=<title>
#   pr_branch=<branch>
#   steps=<n>               probe calls the bisect spent
#   bisect=<path>           a table file of every probed sha and its answer
#   outcome=<word>          the driver's verdict
# A key may appear more than once; the LAST line wins. The driver appends a
# second outcome= after detect's, and a reader takes that one.
#
# BH-3695 fills in the two bodies below. REST reads go through gh_rest_var,
# never a `$( )` around a gh_rest helper. Log and artifact BYTES are the one
# `gh api` call here (_mrb_bytes, with --allow-escape-sequences): they
# are not JSON, and gh_rest's body handling is for JSON. The file sources nothing at source time. bin/lib/gh-rest.sh,
# bin/lib/gh-app-auth.sh and bin/lib/mrb-probe.sh load on the first call.
#
# gh-identity: app-token
# gh-rest: no-graphql

# mrb_detect_episodes <slug> <repo-dir> <out-dir>
#   Writes one episode file per red episode on <slug>'s main into <out-dir>.
#   rc: 0 done (zero files written means no episodes) | 75 the forge is
#       unreachable. 75 is never read as "no episodes".
#   Three sources, each writing at most one file, named by its run id:
#     flag-<run>.ep     $HARNESS/flags/main-red-<owner>-<repo> names a run=.
#                       Suites come from the logs of that run's failed
#                       `Tests, traced (shard ...)` jobs.
#     nightly-<run>.ep  the newest completed harness-nightly.yml run on main
#                       failed. Suites come from the shard-*.log members of
#                       its live nightly-verdict-* artifacts.
#     full-<run>.ep     the newest completed workflow_dispatch run of
#                       harness-ci.yml on main (the daily full run, BH-4970)
#                       failed. Suites come from its failed traced shard jobs,
#                       as for the flag; only a green dispatch run anchors it.
#   red is the run's head on main. For a merge-queue batch, red is the batch
#   head's merge-base with origin/main, so the batch's own PRs never appear.
#   A batch red suite that is not in main's tree at red is the batch's own and
#   is dropped, with one log line; a batch with no red suite left writes no
#   file, and a tree that cannot be read at red returns 75 (BH-4875).
#   A batch red is skipped, with one log line and no file, when a successful
#   run of the same workflow on main at exactly red already ran every red
#   suite with rc=0 in its traced shards: the batch's own PRs broke them.
#   green is the newest success of the same workflow and run class whose main
#   sha is a strict ancestor of red, at most MAIN_RED_BISECT_MAX_MERGES
#   (default 40, 1..400) first-parent merges below it. Otherwise
#   outcome=noanchor. No red suite, or a log or artifact that is gone (404/410),
#   gives outcome=nosuite. Any other failed read (5xx, 429, 403, network, a
#   failed git fetch) returns 75, and that source writes no file.
mrb_detect_episodes() {
  local slug="${1:-}" repo="${2:-}" out="${3:-}" root="${HARNESS:-${H:-}}" rc=0 worst=0
  local _MRB_TMP _MRB_GREEN= _MRB_CLEARED_BY= _MRB_KEPT= _MRB_ABSENT= _MRB_BYTES_WHY=
  _mrb_slug_ok "$slug" || { _mrb_log "${slug:-?}: bad slug"; return 75; }
  [ -n "$root" ] || { _mrb_log "$slug: no HARNESS root"; return 75; }
  { [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; } || { _mrb_log "$slug: $repo is not a git checkout"; return 75; }
  { [ -n "$out" ] && mkdir -p "$out" 2>/dev/null && [ -w "$out" ]; } || { _mrb_log "$slug: cannot write $out"; return 75; }
  _mrb_deps || { _mrb_log "$slug: cannot load gh-rest/gh-app-auth/mrb-probe"; return 75; }
  _MRB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mrb-detect.XXXXXX") || return 75
  gh_auth_for "$slug" || true
  _mrb_flag "$slug" "$repo" "$out" "$root" || rc=$?
  [ "$rc" = 0 ] || worst=75
  rc=0
  _mrb_nightly "$slug" "$repo" "$out" || rc=$?
  [ "$rc" = 0 ] || worst=75
  rc=0
  _mrb_full "$slug" "$repo" "$out" || rc=$?
  [ "$rc" = 0 ] || worst=75
  gh_auth_reset
  case "$_MRB_TMP" in */mrb-detect.*) rm -rf "$_MRB_TMP" ;; esac
  return "$worst"
}

# mrb_episode_still_red <episode-file>
#   rc: 0 main is still red for this episode | 1 stale, main has gone green.
#   source=flag: the flag still names the episode's run, or the same red sha.
#   source=nightly: the newest completed main nightly is still that run, and
#   it failed. source=full: the same, for the newest completed dispatch run of
#   harness-ci.yml on main. A read that fails answers 1: nothing is acted on from a red
#   that cannot be re-confirmed. So do a missing file, an unknown source and
#   an empty HARNESS root.
mrb_episode_still_red() {
  local ep="${1:-}" root="${HARNESS:-${H:-}}" src slug run red f url fid fsha r x rc=0
  { [ -n "$root" ] && [ -r "$ep" ]; } || return 1
  src=$(_mrb_val "$ep" source); slug=$(_mrb_val "$ep" slug)
  run=$(_mrb_val "$ep" run); red=$(_mrb_val "$ep" red)
  _mrb_slug_ok "$slug" || return 1
  case "$src" in
    flag)
      f="$root/flags/main-red-${slug//\//-}"
      [ -f "$f" ] || return 1
      url=$(_mrb_val "$f" run)
      [ -n "$url" ] || return 1
      fid=$(_mrb_run_id "$url"); fsha=$(_mrb_val "$f" sha)
      if [ -n "$fid" ] && [ "$fid" = "$run" ]; then return 0; fi
      if [ -n "$fsha" ] && [ "$fsha" = "$red" ]; then return 0; fi
      return 1 ;;
    nightly|full)
      _mrb_deps || return 1
      url="repos/$slug/actions/workflows/harness-nightly.yml/runs?branch=main&status=completed&per_page=1"
      [ "$src" = full ] && url="repos/$slug/actions/workflows/harness-ci.yml/runs?branch=main&event=workflow_dispatch&status=completed&per_page=1"
      gh_auth_for "$slug" || true
      gh_rest_var r GET "$url" || rc=$?
      gh_auth_reset
      if [ "$rc" != 0 ]; then
        _mrb_log "$slug: $src re-read answered rc $rc (HTTP $GH_REST_STATUS), treating episode run $run as stale"
        return 1
      fi
      x=$(jq -r '.workflow_runs[0] // {} | "\(.id) \(.conclusion)"' <<<"$r" 2>/dev/null) || return 1
      [ "$x" = "$run failure" ] && return 0
      return 1 ;;
  esac
  return 1
}

# ── private ───────────────────────────────────────────────────────────────────

_mrb_log() { echo "mrb-detect: $*" >&2; }

_mrb_slug_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# _mrb_val <file> <key> — the value of the LAST <key>= line (the contract's rule).
_mrb_val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# _mrb_run_id <run-url> — the digits after /actions/runs/ (an /attempts/<n> tail is ignored).
_mrb_run_id() { sed -n 's#.*/actions/runs/\([0-9][0-9]*\).*#\1#p' <<<"${1:-}"; }

_mrb_deps() {
  local d="${BASH_SOURCE[0]%/*}"
  declare -F gh_rest_var >/dev/null || . "$d/gh-rest.sh" 2>/dev/null
  declare -F gh_auth_for >/dev/null || . "$d/gh-app-auth.sh" 2>/dev/null
  declare -F mrb_suites_from_log >/dev/null || . "$d/mrb-probe.sh" 2>/dev/null
  declare -F gh_rest_var >/dev/null && declare -F gh_auth_for >/dev/null \
    && declare -F gh_auth_reset >/dev/null && declare -F mrb_suites_from_log >/dev/null
}

_mrb_max_merges() {
  local m="${MAIN_RED_BISECT_MAX_MERGES:-40}"
  if [[ "$m" =~ ^[0-9]{1,3}$ ]] && [ "$m" -ge 1 ] && [ "$m" -le 400 ]; then echo "$m"; return 0; fi
  _mrb_log "MAIN_RED_BISECT_MAX_MERGES=$m is not 1..400, using 40"
  echo 40
}

# _mrb_bytes <api-path> <out-file> — log or zip bytes. rc 0 read | 44 gone
# (404/410: expired or deleted) | 76 gh refused to print bytes that hold
# terminal escapes | 75 anything else, network included. Sets _MRB_BYTES_WHY
# to `gh-refused: <gh line>` (76) or `gh: <gh line>` (75), empty otherwise.
# BH-8223: gh prints a job log with ANSI escapes to a non-tty only with
# --allow-escape-sequences; without it every log read failed and read as 75.
# The flag follows the path. A gh too old to know the flag gets one bare retry.
_mrb_bytes() {
  local err="$_MRB_TMP/bytes.err" rc=0 msg
  _MRB_BYTES_WHY=
  gh api "$1" --allow-escape-sequences > "$2" 2> "$err" && return 0
  rc=$?
  if grep -qF 'unknown flag: --allow-escape-sequences' "$err" 2>/dev/null; then
    gh api "$1" > "$2" 2> "$err" && return 0
    rc=$?
  fi
  msg=$(grep -m1 . "$err" 2>/dev/null | tr -d '\r')
  case "$(cat "$err" 2>/dev/null)" in
    *"HTTP 404"*|*"HTTP 410"*) return 44 ;;
    *"terminal escape sequences"*) _MRB_BYTES_WHY="gh-refused: $msg"; return 76 ;;
  esac
  _MRB_BYTES_WHY="gh: ${msg:-exit $rc}"
  return 75
}

# _mrb_main_sha <repo> <sha> <head-branch> — prints the main sha a run stands
# for. rc 0 | 1 not a main or merge-queue run (skip it) | 75 fetch failed.
_mrb_main_sha() {
  local repo="$1" sha="$2" red
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 75
  case "$3" in
    main)
      git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
        || git -C "$repo" fetch -q origin "$sha" 2>/dev/null || return 75
      echo "$sha" ;;
    mergify/merge-queue/*)
      git -C "$repo" fetch -q origin "$sha" 2>/dev/null || return 75
      # once per tick; a marker file, because this runs inside `$( )`
      if [ ! -e "$_MRB_TMP/main-fetched" ]; then
        git -C "$repo" fetch -q origin main 2>/dev/null || return 75
        : > "$_MRB_TMP/main-fetched"
      fi
      red=$(git -C "$repo" merge-base "$sha" origin/main) || return 75
      echo "$red" ;;
    *) return 1 ;;
  esac
}

# _mrb_green <slug> <repo> <workflow> <red> <main|batch> [event] — sets
# _MRB_GREEN, empty when there is no anchor within the merge cap. With [event]
# only runs of that trigger anchor. rc 0 | 75.
_mrb_green() {
  local slug="$1" repo="$2" red="$4" cls="$5" q r list sha br s depth max rc
  _MRB_GREEN=
  max=$(_mrb_max_merges)
  q="repos/$slug/actions/workflows/$3/runs?status=success"
  [ "$cls" = main ] && q="$q&branch=main"
  [ -n "${6:-}" ] && q="$q&event=$6"
  gh_rest_var r GET "$q&per_page=100" || return 75
  list=$(jq -r '.workflow_runs[] | [.head_sha, .head_branch] | @tsv' <<<"$r" 2>/dev/null) || return 75
  while IFS=$'\t' read -r sha br; do
    [ -n "$sha" ] || continue
    case "$cls:$br" in main:main|batch:mergify/merge-queue/*) ;; *) continue ;; esac
    rc=0; s=$(_mrb_main_sha "$repo" "$sha" "$br") || rc=$?
    [ "$rc" = 75 ] && return 75
    [ "$rc" = 0 ] || continue
    [ "$s" != "$red" ] || continue
    git -C "$repo" merge-base --is-ancestor "$s" "$red" 2>/dev/null || continue
    depth=$(git -C "$repo" rev-list --count --first-parent --merges "$s..$red") || return 75
    [ "$depth" -le "$max" ] && _MRB_GREEN=$s
    return 0
  done <<<"$list"
  return 0
}

# _mrb_write <out> <name> <source> <slug> <red> <green> <run> <wf> <job> <suites> <outcome>
# Keys in contract order, via a tmp file and mv, so a partial file never exists.
_mrb_write() {
  local t="$1/.$2.tmp"
  printf 'source=%s\nslug=%s\nred=%s\ngreen=%s\nrun=%s\nwf=%s\njob=%s\nsuites=%s\noutcome=%s\n' \
    "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" > "$t" \
    && mv -f "$t" "$1/$2" && return 0
  rm -f "$t"
  return 75
}

# _mrb_outcome <suites> — nosuite | noanchor | empty, from _MRB_GREEN.
_mrb_outcome() {
  if [ -z "$1" ]; then echo nosuite
  elif [ -z "$_MRB_GREEN" ]; then echo noanchor
  fi
}

# _mrb_passed_suites_from_log — stdin: job log text; stdout: the tests/ paths
# with an `rc=0` result line, sorted unique. mrb_suites_from_log's anchor, the
# other polarity. sed reads all of stdin, so a big log never SIGPIPEs its writer.
_mrb_passed_suites_from_log() {
  sed -E 's/\r$//; s/^[0-9][0-9TZ:.-]* //' \
    | sed -n 's/^--- \(tests\/[^ ]*\) rc=0\( .*\)\{0,1\}$/\1/p' | LC_ALL=C sort -u
  return 0
}

# _mrb_main_cleared <slug> <repo> <wfid> <red> <suites> — did a successful run
# of workflow <wfid> on main at exactly <red> run every one of <suites> (space-
# separated) with rc=0, all in ONE run? Only traced shards that succeeded are
# evidence; a skipped shard or a gone log is not. Sets _MRB_CLEARED_BY to the
# run id. rc 0 cleared | 1 no evidence (a 404 included) | 75 a read failed.
_mrb_main_cleared() {
  local slug="$1" wfid="$3" red="$4" suites="$5" r j ids mid jids jid rc s n=0
  local one="$_MRB_TMP/main-job.log" pass="$_MRB_TMP/main-pass.txt"
  _MRB_CLEARED_BY=
  [ -n "$suites" ] || return 1
  rc=0; gh_rest_var r GET "repos/$slug/actions/workflows/$wfid/runs?branch=main&head_sha=$red&status=success&per_page=5" || rc=$?
  [ "$rc" = 44 ] && return 1
  [ "$rc" = 0 ] || return 75
  ids=$(jq -r --arg red "$red" --argjson w "$wfid" '.workflow_runs[]
    | select(.head_branch == "main" and .head_sha == $red and .workflow_id == $w and .conclusion == "success") | .id' <<<"$r" 2>/dev/null) || return 75
  for mid in $ids; do
    [[ "$mid" =~ ^[0-9]+$ ]] || return 75
    n=$((n+1)); [ "$n" -le 3 ] || break
    rc=0; gh_rest_var j GET "repos/$slug/actions/runs/$mid/jobs?filter=latest&per_page=100" || rc=$?
    [ "$rc" = 44 ] && continue
    [ "$rc" = 0 ] || return 75
    jids=$(jq -r '.jobs[] | select(.conclusion == "success" and (.name | startswith("Tests, traced (shard"))) | .id' <<<"$j" 2>/dev/null) || return 75
    : > "$pass"
    for jid in $jids; do
      rc=0; _mrb_bytes "repos/$slug/actions/jobs/$jid/logs" "$one" || rc=$?
      case "$rc" in
        0) _mrb_passed_suites_from_log < "$one" >> "$pass" ;;
        44) ;;
        *) _mrb_log "$slug: job $jid log read failed rc=$rc $_MRB_BYTES_WHY"; return 75 ;;
      esac
    done
    for s in $suites; do
      grep -qxF -- "$s" "$pass" || continue 2
    done
    _MRB_CLEARED_BY=$mid
    return 0
  done
  return 1
}

# _mrb_present_at <repo> <sha> <suites> — splits <suites> (space-separated)
# into the ones in <sha>'s tree (_MRB_KEPT) and the ones not (_MRB_ABSENT).
# rc 0 | 75 the tree at <sha> cannot be read: a failed read is never "absent".
_mrb_present_at() {
  local repo="$1" sha="$2" s
  _MRB_KEPT= _MRB_ABSENT=
  git -C "$repo" cat-file -e "$sha^{tree}" 2>/dev/null || return 75
  for s in $3; do
    if git -C "$repo" cat-file -e "$sha:$s" 2>/dev/null; then
      _MRB_KEPT="$_MRB_KEPT $s"
    else
      _MRB_ABSENT="$_MRB_ABSENT $s"
    fi
  done
  _MRB_KEPT=${_MRB_KEPT# }; _MRB_ABSENT=${_MRB_ABSENT# }
}

# Source A: the main-red flag.
_mrb_flag() {
  local slug="$1" repo="$2" out="$3" f url reason id r j x sha br wfid wfpath red cls jids jid job='' rc suites
  local log="$_MRB_TMP/flag.log" one="$_MRB_TMP/job.log"
  f="$4/flags/main-red-${slug//\//-}"
  [ -f "$f" ] || return 0
  url=$(_mrb_val "$f" run); reason=$(_mrb_val "$f" reason)
  if [ "$reason" = pr-pair-suspected ] || [ -z "$url" ]; then
    _mrb_log "$slug: flag has no run (reason=${reason:-none}), skipped"; return 0
  fi
  id=$(_mrb_run_id "$url")
  [ -n "$id" ] || { _mrb_log "$slug: flag run=$url does not parse, skipped"; return 0; }
  gh_rest_var r GET "repos/$slug/actions/runs/$id" || { _mrb_log "$slug: run $id read failed (HTTP $GH_REST_STATUS)"; return 75; }
  x=$(jq -r '[.head_sha, .head_branch, .workflow_id, .path] | @tsv' <<<"$r" 2>/dev/null) || return 75
  IFS=$'\t' read -r sha br wfid wfpath <<<"$x"
  [[ "$wfid" =~ ^[0-9]+$ ]] || return 75
  rc=0; red=$(_mrb_main_sha "$repo" "$sha" "$br") || rc=$?
  if [ "$rc" = 1 ]; then _mrb_log "$slug: run $id is on $br, not main or a merge-queue batch, skipped"; return 0; fi
  [ "$rc" = 0 ] || { _mrb_log "$slug: cannot fetch $sha for run $id"; return 75; }
  cls=main; [ "$br" = main ] || cls='batch'
  gh_rest_var j GET "repos/$slug/actions/runs/$id/jobs?filter=latest&per_page=100" || { _mrb_log "$slug: run $id jobs read failed (HTTP $GH_REST_STATUS)"; return 75; }
  jids=$(jq -r '.jobs[] | select(.conclusion == "failure" and (.name | startswith("Tests, traced (shard"))) | .id' <<<"$j" 2>/dev/null) || return 75
  : > "$log"
  for jid in $jids; do
    [ -n "$job" ] || job=$jid
    rc=0; _mrb_bytes "repos/$slug/actions/jobs/$jid/logs" "$one" || rc=$?
    case "$rc" in
      0) cat "$one" >> "$log" ;;
      44) _mrb_log "$slug: job $jid log is gone" ;;
      *) _mrb_log "$slug: job $jid log read failed rc=$rc $_MRB_BYTES_WHY"; return 75 ;;
    esac
  done
  suites=$(mrb_suites_from_log < "$log" | sort -u | tr '\n' ' ')
  suites=${suites% }
  if [ "$cls" = batch ] && [ -n "$suites" ]; then
    _mrb_present_at "$repo" "$red" "$suites" || { _mrb_log "$slug: cannot read main's tree at $red"; return 75; }
    if [ -n "$_MRB_ABSENT" ]; then
      _mrb_log "$slug: batch run $id red on $_MRB_ABSENT, not in main at $red: the batch's own PRs added them, dropped"
      [ -n "$_MRB_KEPT" ] || return 0
      suites=$_MRB_KEPT
    fi
    rc=0; _mrb_main_cleared "$slug" "$repo" "$wfid" "$red" "$suites" || rc=$?
    case "$rc" in
      0) _mrb_log "$slug: batch run $id red on $suites, but main run $_MRB_CLEARED_BY at $red ran them all rc=0: the batch's own PRs broke them, skipped"
         return 0 ;;
      1) ;;
      *) _mrb_log "$slug: main runs at $red read failed${_MRB_BYTES_WHY:+: $_MRB_BYTES_WHY}"; return 75 ;;
    esac
  fi
  _mrb_green "$slug" "$repo" "$wfid" "$red" "$cls" || { _mrb_log "$slug: green anchor read failed"; return 75; }
  _mrb_write "$out" "flag-$id.ep" flag "$slug" "$red" "$_MRB_GREEN" "$id" "${wfpath##*/}" "$job" "$suites" "$(_mrb_outcome "$suites")"
}

# Source B: the newest completed nightly on main.
_mrb_nightly() {
  local slug="$1" repo="$2" out="$3" r a x id sha br concl wfpath red aids aid rc=0 suites
  local log="$_MRB_TMP/nightly.log" zip="$_MRB_TMP/a.zip"
  gh_rest_var r GET "repos/$slug/actions/workflows/harness-nightly.yml/runs?branch=main&status=completed&per_page=1" || rc=$?
  [ "$rc" = 44 ] && return 0
  [ "$rc" = 0 ] || { _mrb_log "$slug: nightly read failed (HTTP $GH_REST_STATUS)"; return 75; }
  x=$(jq -r '.workflow_runs[0] // empty | [.id, .head_sha, .head_branch, .conclusion, .path] | @tsv' <<<"$r" 2>/dev/null) || return 75
  [ -n "$x" ] || return 0
  IFS=$'\t' read -r id sha br concl wfpath <<<"$x"
  [ "$concl" = failure ] || return 0
  [[ "$id" =~ ^[0-9]+$ ]] || return 75
  rc=0; red=$(_mrb_main_sha "$repo" "$sha" main) || rc=$?
  [ "$rc" = 0 ] || { _mrb_log "$slug: cannot fetch $sha for nightly $id"; return 75; }
  gh_rest_var a GET "repos/$slug/actions/runs/$id/artifacts?per_page=100" || { _mrb_log "$slug: nightly $id artifacts read failed (HTTP $GH_REST_STATUS)"; return 75; }
  aids=$(jq -r '.artifacts[] | select((.name | startswith("nightly-verdict-")) and .expired == false) | .id' <<<"$a" 2>/dev/null) || return 75
  : > "$log"
  for aid in $aids; do
    rc=0; _mrb_bytes "repos/$slug/actions/artifacts/$aid/zip" "$zip" || rc=$?
    case "$rc" in
      0) python3 - "$zip" >> "$log" 2>/dev/null <<'PY' || { _mrb_log "$slug: artifact $aid is not a readable zip"; return 75; }
import fnmatch, os, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        if fnmatch.fnmatch(os.path.basename(n), "shard-*.log"):
            sys.stdout.buffer.write(z.read(n))
            sys.stdout.buffer.write(b"\n")
PY
        ;;
      44) _mrb_log "$slug: artifact $aid is gone" ;;
      *) _mrb_log "$slug: artifact $aid read failed rc=$rc $_MRB_BYTES_WHY"; return 75 ;;
    esac
  done
  suites=$(mrb_suites_from_log < "$log" | sort -u | tr '\n' ' ')
  suites=${suites% }
  _mrb_green "$slug" "$repo" harness-nightly.yml "$red" main || { _mrb_log "$slug: nightly green anchor read failed"; return 75; }
  _mrb_write "$out" "nightly-$id.ep" nightly "$slug" "$red" "$_MRB_GREEN" "$id" "${wfpath##*/}" "" "$suites" "$(_mrb_outcome "$suites")"
}

# _mrb_failed_shard_suites <slug> <run> <log> — the failed `Tests, traced
# (shard` jobs of <run>: their logs into <log>, the first one's id in
# _MRB_JOB. A gone log is skipped with a line. rc 0 | 75.
_mrb_failed_shard_suites() {
  local slug="$1" run="$2" log="$3" j jids jid rc one="$_MRB_TMP/job.log"
  _MRB_JOB=
  gh_rest_var j GET "repos/$slug/actions/runs/$run/jobs?filter=latest&per_page=100" || { _mrb_log "$slug: run $run jobs read failed (HTTP $GH_REST_STATUS)"; return 75; }
  jids=$(jq -r '.jobs[] | select(.conclusion == "failure" and (.name | startswith("Tests, traced (shard"))) | .id' <<<"$j" 2>/dev/null) || return 75
  : > "$log"
  for jid in $jids; do
    [ -n "$_MRB_JOB" ] || _MRB_JOB=$jid
    rc=0; _mrb_bytes "repos/$slug/actions/jobs/$jid/logs" "$one" || rc=$?
    case "$rc" in
      0) cat "$one" >> "$log" ;;
      44) _mrb_log "$slug: job $jid log is gone" ;;
      *) _mrb_log "$slug: job $jid log read failed rc=$rc $_MRB_BYTES_WHY"; return 75 ;;
    esac
  done
  return 0
}

# Source C: the newest completed dispatch run of harness-ci.yml on main, the
# daily full run (BH-4970). No such run yet is no episode.
_mrb_full() {
  local slug="$1" repo="$2" out="$3" r x id sha br concl wfpath red rc=0 suites _MRB_JOB=
  local log="$_MRB_TMP/full.log"
  gh_rest_var r GET "repos/$slug/actions/workflows/harness-ci.yml/runs?branch=main&event=workflow_dispatch&status=completed&per_page=1" || rc=$?
  [ "$rc" = 44 ] && return 0
  [ "$rc" = 0 ] || { _mrb_log "$slug: full run read failed (HTTP $GH_REST_STATUS)"; return 75; }
  x=$(jq -r '.workflow_runs[0] // empty | [.id, .head_sha, .head_branch, .conclusion, .path] | @tsv' <<<"$r" 2>/dev/null) || return 75
  [ -n "$x" ] || return 0
  IFS=$'\t' read -r id sha br concl wfpath <<<"$x"
  [ "$concl" = failure ] || return 0
  [[ "$id" =~ ^[0-9]+$ ]] || return 75
  rc=0; red=$(_mrb_main_sha "$repo" "$sha" main) || rc=$?
  [ "$rc" = 0 ] || { _mrb_log "$slug: cannot fetch $sha for full run $id"; return 75; }
  _mrb_failed_shard_suites "$slug" "$id" "$log" || return 75
  suites=$(mrb_suites_from_log < "$log" | sort -u | tr '\n' ' ')
  suites=${suites% }
  _mrb_green "$slug" "$repo" harness-ci.yml "$red" main workflow_dispatch || { _mrb_log "$slug: full run green anchor read failed"; return 75; }
  _mrb_write "$out" "full-$id.ep" full "$slug" "$red" "$_MRB_GREEN" "$id" "${wfpath##*/}" "$_MRB_JOB" "$suites" "$(_mrb_outcome "$suites")"
}
