# shellcheck shell=bash
# bin/lib/repo-meta.sh — BH-10218: repo metadata from memos, with a push or
# repository wake as the change signal. Sourced, never run.
#
# WHY. The hub ledger (2026-11-26 10:00Z-10:33Z) counted about 160 spent
# `repos/<owner>/<repo>` GETs an hour from main-red-pr-pair, pr-owner-sweep,
# fly-pool, overlap-guard and ci-shard-watch. Every one of them is the token
# ladder's visibility probe (bin/lib/gh-repo-token.sh `gh api repos/<slug> -q
# .id`, one per rung): "which credential can see this repo". The answer moves
# only when the repo moves.
#
#   repo_meta_arm
#       In the CALLER's shell (never inside `$( )`): points the ladder's probe
#       memo at state/repo-meta/probe/ with REPO_META_BACKSTOP_S as its age,
#       and defines the ladder's two hooks (_ghrt_memo_mark,
#       _ghrt_memo_changed), so a memo row carries the repo's change mark and
#       is void once a push or repository wake arrives above it. rc 1 = no
#       harness root (nothing armed). The memo is a separate dir from the
#       merge conductor's state/gh-repo-probe/, so the conductor's 2-column
#       rows and its 300 s TTL are untouched.
#   repo_meta_get <slug> default_branch
#       Prints the default branch, rc 0. Served from the BH-9938 memo
#       state/prr-default-branch/<owner>_<repo> when its stamp
#       <memo>.meta (`<epoch>\t<mark>`) is younger than REPO_META_BACKSTOP_S
#       and rcm_moved says quiet for kinds push,repo. Otherwise ONE
#       `gh_rest GET repos/<slug>` (ETag on, as every gh_rest GET), then the
#       memo and a new stamp, the mark taken BEFORE the read. A failed read
#       (gh_rest 44 or 75, or a body with no valid default_branch) writes
#       nothing and returns that code (75 for a bad body). rc 2 = bad args
#       or no root. No mark (the feed cannot tell) = the memo is written and
#       the stamp removed, so the next call reads GitHub again.
#
# FIELDS THE CALLERS USE (the plan's table): the five lanes read only the
# ladder's visibility verdict (`.id` answered, per rung). The default branch is
# the field pr_record_open_rest gates the record list on (bin/lib/pr-record.sh).
#
# KNOB: REPO_META_BACKSTOP_S (catalog/lanes.d/_lib.repo-meta.json, settings row
# lib.repo-meta.repo_meta_backstop_s), resolved once per process the
# bin/lib/wake-backstop.sh way: lib_env_apply in a SUBSHELL, handing back on
# fd 3 what resolved. 0 = no memo: every call reads GitHub. Not a number = the
# code fallback below.
#
# The root is ${HARNESS:-${H:-}} and nothing else. No `set -e`, no `exit`.
if [ -n "${REPO_META_LIB:-}" ]; then return 0 2>/dev/null; fi
REPO_META_LIB=1
REPO_META_BACKSTOP_DEFAULT=86400   # fallback only: the knob is REPO_META_BACKSTOP_S in catalog/lanes.d/_lib.repo-meta.json
_RM_LIBDIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=bin/lib/repo-change-mark.sh
declare -F rcm_moved >/dev/null 2>&1 || . "$_RM_LIBDIR/repo-change-mark.sh" 2>/dev/null

_RM_KV=$(
  exec 3>&1
  _RM_R=$(cd "$_RM_LIBDIR/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_RM_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_RM_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_RM_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'printf "REPO_META_BACKSTOP_S\t%s\n" "${REPO_META_BACKSTOP_S:-}" >&3' EXIT
  lib_env_apply repo-meta >/dev/null 2>&1)
while IFS=$'\t' read -r _RM_K _RM_V; do
  if [ "$_RM_K" = REPO_META_BACKSTOP_S ] && [ -n "$_RM_V" ]; then REPO_META_BACKSTOP_S="$_RM_V"; fi
done <<<"$_RM_KV"
unset _RM_KV _RM_K _RM_V

_rm_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${REPO_META_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#$REPO_META_NOW))"
  else date +%s; fi
}
# repo_meta_backstop — the resolved backstop in seconds (the fallback when unset
# or not a number).
repo_meta_backstop() {
  local v="${REPO_META_BACKSTOP_S:-}"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$REPO_META_BACKSTOP_DEFAULT"
  printf '%s' "$((10#$v))"
}

# The memo path, the BH-9938 normalization (pr-record.sh _prr_db_file): a
# lower-cased owner_repo under state/prr-default-branch/. rc 1 = no root or a
# slug that is not owner/repo.
_rm_db_file() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s/state/prr-default-branch/%s' "$root" "$(printf '%s' "${1//\//_}" | tr 'A-Z' 'a-z')"
}

_rm_put() { # _rm_put <file> <line> — tmp + mv
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null
  local rc=$?
  rm -f "$1.tmp.$$" 2>/dev/null
  return "$rc"
}

repo_meta_get() {
  local slug="${1:-}" field="${2:-}" f v ep mk back now mark t rc=0
  [ "$field" = default_branch ] || return 2
  f=$(_rm_db_file "$slug") || return 2
  back=$(repo_meta_backstop)
  now=$(_rm_now)
  if [ "$back" -gt 0 ]; then
    v=$(head -1 "$f" 2>/dev/null)
    IFS=$'\t' read -r ep mk _ < "$f.meta" 2>/dev/null || ep=""
    if [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$ep" =~ ^[0-9]{1,12}$ ]] && [[ "${mk:-}" =~ ^[0-9]{1,18}$ ]] \
       && [ $((now - ep)) -ge 0 ] && [ $((now - ep)) -lt "$back" ]; then
      rc=0; rcm_moved "$slug" push,repo "$mk" "$ep" >/dev/null 2>&1 || rc=$?
      [ "$rc" = 1 ] && { printf '%s\n' "$v"; return 0; }
    fi
  fi
  mark=$(rcm_mark "$slug" 2>/dev/null) || mark=""
  # The stamp's epoch is the moment the mark was taken: never before the
  # mirror's first complete read (its coverage start), never after the read.
  now=$(_rm_now)
  command -v gh_rest >/dev/null 2>&1 || . "$_RM_LIBDIR/gh-rest.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1 || return 75
  t=$(mktemp "${TMPDIR:-/tmp}/repo-meta.XXXXXX") || return 75
  rc=0; gh_rest GET "repos/$slug" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return "$rc"; fi
  v=$(jq -r '.default_branch // empty' "$t" 2>/dev/null)
  rm -f "$t"
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$v" != *..* ]] || return 75
  mkdir -p "${f%/*}" 2>/dev/null || { printf '%s\n' "$v"; return 0; }
  [ "$(head -1 "$f" 2>/dev/null)" = "$v" ] || _rm_put "$f" "$v" || rm -f "$f.meta" 2>/dev/null
  if [ "$back" -gt 0 ] && [[ "$mark" =~ ^[0-9]{1,18}$ ]] && [ "$(head -1 "$f" 2>/dev/null)" = "$v" ]; then
    _rm_put "$f.meta" "$(printf '%s\t%s' "$now" "$mark")" || rm -f "$f.meta" 2>/dev/null
  else
    rm -f "$f.meta" 2>/dev/null
  fi
  printf '%s\n' "$v"
  return 0
}

repo_meta_arm() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  _GHRT_PROBE_MEMO_DIR="$root/state/repo-meta/probe"
  _GHRT_PROBE_MEMO_TTL_S=$(repo_meta_backstop)
  _ghrt_memo_mark() { rcm_mark "$1"; }
  _ghrt_memo_changed() { rcm_moved "$1" push,repo "$2" "$3"; }
  return 0
}
