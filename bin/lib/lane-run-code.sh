# shellcheck shell=bash
# bin/lib/lane-run-code.sh — the code sync of a lane-run machine (BH-6817).
# Sourced by bin/lane-run-worker.sh, never run.
#
# The image of the Fly app lane-run bakes bin, catalog, fleet.conf, prompts,
# rules and fly at build time, and nothing rebuilds it when main changes. So
# before a claim, at most once every lane_run.code_check_s, the worker fetches
# main of the harness repo by git and swaps in its bin, catalog, fleet.conf,
# prompts, rules and fly, then re-execs itself. The last three are the tree a
# pool spawn tars from POOL_HARNESS_SRC (BH-7516), so they follow
# HARNESS_COMMIT too. No run is in flight at that point, so the exec loses no row.
#
#   lrc_enabled
#       rc 0 only when LANE_RUN_CODE_SYNC=1 (set by fly/lane-run-entrypoint.sh),
#       the root has no .git (not a checkout, not the hub), the root has no
#       populated builds/ (not a box), and the settings row lane_run.code_sync
#       is not 0. No row, or a settings outage, is on.
#   lrc_due
#       rc 0 when state/lane-run-code/checked.at is missing or holds an epoch
#       lane_run.code_check_s (30..3600, fallback 120) or more seconds old.
#   lrc_sync
#       touches checked.at, fetches main (depth 1) into state/lane-run-code/
#       repo.git and compares it with $root/HARNESS_COMMIT. Prints ONE line:
#         rc 0  `code current <sha12>`
#         rc 10 `code <old12|unknown> -> <new12>` — swapped; the caller re-execs
#         rc 1  `code sync failed: <why>` — the tree is unchanged, and at most
#               one `lane-alert.sh --id lane-run-code-sync` per hour is sent
#       The repo is `bin/fleet-conf.sh cromford repo` and the token is
#       `bin/gh-token.sh --read <repo>`, sent as an http.extraHeader through
#       GIT_CONFIG_* env, never in the URL, argv or a log. LANE_RUN_CODE_URL
#       replaces the URL and the token (a test seam).
#       The stage (git archive of bin catalog fleet.conf, plus prompts rules fly
#       each only when the fetched commit lists it: a path the commit lacks is
#       not swapped, and a failed archive of a listed one fails the sync) must have
#       bin/lane-run-worker.sh, bin/project-lane-run.sh and bin/jobs-client.sh,
#       each passing `bash -n`. catalog/llm-sites.json and
#       catalog/context-budgets.json are git-ignored renders: the stage's own
#       composers write them, and any top-level catalog file the stage still
#       lacks is carried over from the old tree (catalog/lanes.json renders on
#       demand, bin/lib/lanes-registry.sh). The swap is two renames per path
#       of _LRC_SWAP, bin last; HARNESS_COMMIT is written before the old copy is removed.
#
# The clock is LANE_RUN_NOW (epoch) when set. The root is ${HARNESS:-${H:-}};
# with no root every function answers rc 1.

_lrc_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_lrc_now() {
  if [[ ${LANE_RUN_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$LANE_RUN_NOW"; else date -u +%s; fi
}

# _lrc_setting <key> — the trimmed value, or empty (no row, outage, no client).
_lrc_setting() {
  command -v setting_get >/dev/null 2>&1 || return 0
  setting_get "$1" 2>/dev/null | tr -d '[:space:]'
}

_lrc_check_s() {
  local v
  v=$(_lrc_setting lane_run.code_check_s)
  case "$v" in ''|*[!0-9]*) v=120 ;; esac
  [ "$v" -ge 30 ] && [ "$v" -le 3600 ] || v=120
  printf '%s' "$v"
}

lrc_enabled() {
  local root
  root=$(_lrc_root); [ -n "$root" ] || return 1
  [ "${LANE_RUN_CODE_SYNC:-}" = 1 ] || return 1
  [ ! -e "$root/.git" ] || return 1
  [ -z "$(ls -A "$root/builds" 2>/dev/null)" ] || return 1
  [ "$(_lrc_setting lane_run.code_sync)" != 0 ]
}

lrc_due() {
  local root last
  root=$(_lrc_root); [ -n "$root" ] || return 1
  last=$(head -n 1 "$root/state/lane-run-code/checked.at" 2>/dev/null)
  [[ $last =~ ^[0-9]+$ ]] || return 0
  [ $(( $(_lrc_now) - last )) -ge "$(_lrc_check_s)" ]
}

# _lrc_fail <root> <why> — the failure line, and at most one alert an hour.
_lrc_fail() {
  local root="$1" why="$2" stamp now last
  stamp="$root/state/lane-run-code/alert.at"
  now=$(_lrc_now)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  if ! [[ $last =~ ^[0-9]+$ ]] || [ $((now - last)) -ge 3600 ]; then
    if [ -x "$root/bin/lane-alert.sh" ]; then
      "$root/bin/lane-alert.sh" --severity warn --id lane-run-code-sync lane-run-worker \
        "lane machine ${FLY_MACHINE_ID:-$(hostname 2>/dev/null)} could not sync harness code ($why); it keeps running commit $(_lrc_commit "$root"). Check that the lane-run GitHub App installation can read the harness repo." \
        >/dev/null 2>&1
      printf '%s\n' "$now" > "$stamp" 2>/dev/null
    fi
  fi
  printf 'code sync failed: %s\n' "$why"
  return 1
}

# _lrc_commit <root> — the 12-character HARNESS_COMMIT, else `unknown`.
_lrc_commit() {
  local c
  c=$(head -n 1 "$1/HARNESS_COMMIT" 2>/dev/null | tr -d '[:space:]')
  [[ $c =~ ^[0-9a-f]{7,40}$ ]] && printf '%s' "${c:0:12}" || printf unknown
}

# The swap order of lrc_sync and _lrc_restore. bin is last: the running
# worker's own code moves only after every other path is in place.
_LRC_SWAP="fleet.conf catalog prompts rules fly bin"
_LRC_OPTIONAL="prompts rules fly"

lrc_sync() {
  local root st url repo tok="" head cur stage old p f listed
  root=$(_lrc_root); [ -n "$root" ] || return 1
  st="$root/state/lane-run-code"
  mkdir -p "$st" 2>/dev/null || { printf 'code sync failed: cannot create %s\n' "$st"; return 1; }
  printf '%s\n' "$(_lrc_now)" > "$st/checked.at"
  if [ -n "${LANE_RUN_CODE_URL:-}" ]; then
    url="$LANE_RUN_CODE_URL"
  else
    repo=$("$root/bin/fleet-conf.sh" cromford repo 2>/dev/null)
    [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { _lrc_fail "$root" "no cromford repo in fleet.conf"; return 1; }
    url="https://github.com/$repo.git"
    tok=$("$root/bin/gh-token.sh" --read "$repo" 2>/dev/null)
    [ -n "$tok" ] || { _lrc_fail "$root" "no GitHub token for $repo"; return 1; }
  fi
  if [ ! -d "$st/repo.git" ]; then
    git init -q --bare "$st/repo.git" >/dev/null 2>&1 || { _lrc_fail "$root" "git init failed"; return 1; }
  fi
  # The header rides in exported GIT_CONFIG_* of a subshell: no argv holds it.
  if ! (
    if [ -n "$tok" ]; then
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 -w 0)"
      export GIT_CONFIG_VALUE_0
    fi
    GIT_TERMINAL_PROMPT=0 git -C "$st/repo.git" fetch -q --depth 1 "$url" main >/dev/null 2>&1
  ); then
    _lrc_fail "$root" "git fetch of main failed"; return 1
  fi
  head=$(git -C "$st/repo.git" rev-parse FETCH_HEAD 2>/dev/null)
  [[ $head =~ ^[0-9a-f]{40}$ ]] || { _lrc_fail "$root" "no FETCH_HEAD after the fetch"; return 1; }
  cur=$(head -n 1 "$root/HARNESS_COMMIT" 2>/dev/null | tr -d '[:space:]')
  if [ "$cur" = "$head" ]; then printf 'code current %s\n' "${head:0:12}"; return 0; fi
  cur=$(_lrc_commit "$root"); [ "$cur" = unknown ] && cur=""

  stage="$st/stage-${head:0:12}"
  rm -rf "$stage"; mkdir -p "$stage"
  if ! git -C "$st/repo.git" archive FETCH_HEAD bin catalog fleet.conf 2>/dev/null | tar -x -C "$stage" 2>/dev/null; then
    rm -rf "$stage"; _lrc_fail "$root" "git archive of ${head:0:12} failed"; return 1
  fi
  listed=" $(git -C "$st/repo.git" ls-tree --name-only FETCH_HEAD 2>/dev/null | tr '\n' ' ') "
  for p in $_LRC_OPTIONAL; do
    [[ $listed == *" $p "* ]] || continue
    if ! git -C "$st/repo.git" archive FETCH_HEAD "$p" 2>/dev/null | tar -x -C "$stage" 2>/dev/null; then
      rm -rf "$stage"; _lrc_fail "$root" "git archive of $p at ${head:0:12} failed"; return 1
    fi
  done
  for f in bin/lane-run-worker.sh bin/project-lane-run.sh bin/jobs-client.sh; do
    if [ ! -f "$stage/$f" ] || ! bash -n "$stage/$f" 2>/dev/null; then
      rm -rf "$stage"; _lrc_fail "$root" "${head:0:12} refused: $f is missing or fails bash -n"; return 1
    fi
  done
  # The git-ignored renders: the stage's composers first, then the old copy.
  for f in llm-sites-build.sh context-budgets-build.sh; do
    [ -x "$stage/bin/$f" ] && HARNESS="$stage" "$stage/bin/$f" --compose --repo "$stage" >/dev/null 2>&1
  done
  for f in "$root"/catalog/*; do
    [ -f "$f" ] && [ ! -e "$stage/catalog/${f##*/}" ] && cp -p "$f" "$stage/catalog/" 2>/dev/null
  done

  old="$st/old-$$"
  rm -rf "$old"; mkdir -p "$old"
  for p in $_LRC_SWAP; do
    [ -e "$stage/$p" ] || continue
    [ -e "$root/$p" ] && { mv "$root/$p" "$old/$p" || { _lrc_restore "$root" "$old"; rm -rf "$stage"; _lrc_fail "$root" "swap of $p failed"; return 1; }; }
    mv "$stage/$p" "$root/$p" || { _lrc_restore "$root" "$old"; rm -rf "$stage"; _lrc_fail "$root" "swap of $p failed"; return 1; }
  done
  printf '%s\n' "$head" > "$root/HARNESS_COMMIT.tmp" && mv "$root/HARNESS_COMMIT.tmp" "$root/HARNESS_COMMIT"
  rm -rf "$old" "$stage"
  printf 'code %s -> %s\n' "${cur:-unknown}" "${head:0:12}"
  return 10
}

# _lrc_restore <root> <old> — put back every path the swap moved out.
_lrc_restore() {
  local root="$1" old="$2" p
  for p in $_LRC_SWAP; do
    [ -e "$old/$p" ] || continue
    rm -rf "${root:?}/$p"; mv "$old/$p" "$root/$p"
  done
  rm -rf "$old"
}
