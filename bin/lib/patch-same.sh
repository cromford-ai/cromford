# shellcheck shell=bash
# bin/lib/patch-same.sh — did a PR head move WITHOUT its own patch changing?
# (BH-2310, #2310). Sourced, never run.
#
# WHY. The merge conductor, review-prs.sh and review-autopilot.sh buy a Fable
# review (up to 400K context) whenever a PR's head moves past the head that was
# reviewed. Most moves are not changes: a rebase train, or a fix round that only
# ran `git merge origin/main`. The conductor's patch-id rebind
# (bin/lib/mc/settle.sh) catches a plain rebase. It CANNOT catch a main merge
# whenever main touched a line next to one of the PR's hunks: the whole-diff
# patch-id includes context lines, the merge moves the merge-base, and the id
# changes although not one of the PR's own lines did (seen on #2131,
# 2026-09-25). This file is the deterministic answer, pure git, no model:
#
#   patch_same <git-dir> <main-ref> <reviewed> <head>
#     rc 0 and prints HOW when <head> carries exactly the patch <reviewed>
#     carried. rc 1 otherwise, and on anything it cannot establish. HOW is one of:
#       identical   the same commit.
#       main-merge  <head> descends from <reviewed>, and every commit between
#                   them that is not on <main-ref> is a CLEAN MERGE: a merge
#                   commit whose tree is exactly `git merge-tree` of its
#                   parents, with no conflict. So nothing but main came in, and
#                   no hand resolution slipped in with it.
#       patch-id    `git patch-id --verbatim` of the diff from the merge-base with
#                   <main-ref> is equal: a rebase that carried the patch across
#                   byte for byte. VERBATIM, never --stable: --stable strips all
#                   whitespace, and indentation is code in Python and YAML, so
#                   `rm -rf $D/ cache` read as `rm -rf $D/cache` (#2386 review).
#
#   There is deliberately NO range-diff rung (#2386 review): `git range-diff`
#   pairs a 644 -> 755 mode change and a file -> symlink swap as `=`. The two
#   rungs above cover a main merge and a byte-exact rebase, which is #2310's goal.
#
#   patch_same_fetch <git-dir> <reviewed> <head> [<pr-number>]
#     `git fetch origin main <head>` (and <reviewed> when the remote still has
#     it), so that origin/main and both commits exist locally. rc 1 when <head>
#     is still missing after every try, and then patch_same must not be asked.
#     BH-7043: one failed combined fetch is not the end. It then fetches
#     <head> alone, then main alone (best-effort: a concurrent fetch can hold
#     the origin/main ref lock), then, with a numeric <pr-number>, the PR ref
#     +refs/pull/<n>/head:refs/remotes/origin/pr/<n>. Success is <head>
#     resolving to a commit, never a fetch rc alone. <reviewed> is fetched
#     only when it does not resolve (by sha, then the PR ref), still
#     best-effort. A head this process already fetched into <git-dir> is not
#     fetched again (_PS_FETCHED). On rc 1, PS_FETCH_ERR holds the first git
#     error line, `://user:pass@` redacted, cut to 160 bytes; on rc 0 it is
#     empty. PS_FETCH_MAIN is 1 when origin/main was fetched for <git-dir> in
#     this process, else 0: a "patch changed" answer over a stale origin/main
#     is not settled.
#
# CONSERVATIVE BY CONSTRUCTION. Every answer needs positive evidence: a real
# 40-hex sha from rev-parse, a merge-tree that reported NO conflict, a non-empty
# commit list. An empty answer, a stubbed or broken git, a missing object, or an
# octopus merge is rc 1, and the caller buys the review exactly as before. It can
# say "the same patch". It can never say "close enough".

_ps_sha() { # _ps_sha <git-dir> <rev> -> the full commit sha, rc 1 unless it is one
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

_ps_tree() { # _ps_tree <git-dir> <commit> -> its tree sha
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{tree}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

# _ps_clean_merge <git-dir> <commit> — rc 0 when <commit> is a two-parent merge
# whose recorded tree is exactly what git merges its parents to, with no conflict.
_ps_clean_merge() {
  local g="$1" c="$2" parents want got out
  parents=$(git -C "$g" rev-list --parents -n 1 "$c" 2>/dev/null) || return 1
  read -r _ p1 p2 extra <<<"$parents"
  [[ "${p1:-}" =~ ^[0-9a-f]{40}$ ]] && [[ "${p2:-}" =~ ^[0-9a-f]{40}$ ]] && [ -z "${extra:-}" ] || return 1
  want=$(_ps_tree "$g" "$c") || return 1
  # merge-tree --write-tree prints the tree on its first line and exits 0 only
  # when the merge was clean; a conflict is exit 1 and never a pass.
  out=$(git -C "$g" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) || return 1
  got=$(head -1 <<<"$out")
  [[ "$got" =~ ^[0-9a-f]{40}$ ]] && [ "$got" = "$want" ]
}

_ps_main_merge() { # <git-dir> <main> <reviewed> <head>
  local g="$1" main="$2" rev="$3" head="$4" list c n=0
  git -C "$g" merge-base --is-ancestor "$rev" "$head" 2>/dev/null || return 1
  list=$(git -C "$g" rev-list "$head" "^$rev" "^$main" 2>/dev/null) || return 1
  for c in $list; do
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || return 1
    _ps_clean_merge "$g" "$c" || return 1
    n=$((n + 1))
  done
  # Nothing new that is not on main would mean the head is main's own history,
  # not a PR head that took main in. That is not this rule's shape.
  [ "$n" -gt 0 ]
}

_ps_patch_id() { # <git-dir> <main> <sha> -> the whole-diff patch-id
  local g="$1" base id
  base=$(git -C "$g" merge-base "$2" "$3" 2>/dev/null) || return 1
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
  id=$(git -C "$g" diff "$base" "$3" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
  [[ "$id" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$id"
}

patch_same() {
  local g="$1" main="$2" rev head m pr ph
  [ -n "$g" ] && [ -n "$main" ] || return 1
  rev=$(_ps_sha "$g" "${3:-}") || return 1
  head=$(_ps_sha "$g" "${4:-}") || return 1
  m=$(_ps_sha "$g" "$main") || return 1
  if [ "$rev" = "$head" ]; then printf 'identical'; return 0; fi
  if _ps_main_merge "$g" "$m" "$rev" "$head"; then printf 'main-merge'; return 0; fi
  if pr=$(_ps_patch_id "$g" "$m" "$rev") && ph=$(_ps_patch_id "$g" "$m" "$head") && [ "$pr" = "$ph" ]; then
    printf 'patch-id'; return 0
  fi
  return 1
}

declare -gA _PS_FETCHED=() _PS_MAIN_FETCHED=()
PS_FETCH_ERR=""; PS_FETCH_MAIN=0; _PS_ERR=""

# _ps_redact — stdin to stdout: the first line, credentials in a URL masked, 160 bytes.
_ps_redact() { head -n 1 | sed -E 's#://[^/@ ]+@#://***@#g' | head -c 160; }

# _ps_fetch <git-dir> <fetch args...> — one quiet `git fetch origin`; the first
#   failure's stderr is kept in _PS_ERR for PS_FETCH_ERR.
_ps_fetch() {
  local g="$1" e; shift
  e=$(git -C "$g" fetch -q origin "$@" 2>&1 >/dev/null) && return 0
  [ -n "$_PS_ERR" ] || _PS_ERR="${e:-git fetch origin $* failed with no message}"
  return 1
}

patch_same_fetch() { # <git-dir> <reviewed> <head> [<pr-number>]
  local g="$1" rev="${2:-}" head="${3:-}" pr="${4:-}" prref
  PS_FETCH_ERR=""; PS_FETCH_MAIN=0; _PS_ERR=""
  [ -d "$g/.git" ] || [ -f "$g/HEAD" ] || { PS_FETCH_ERR="no git dir at $g"; return 1; }
  [ -n "$head" ] || { PS_FETCH_ERR="no head sha"; return 1; }
  [[ "$pr" =~ ^[0-9]+$ ]] && prref="+refs/pull/$pr/head:refs/remotes/origin/pr/$pr" || prref=""
  if [ -z "${_PS_FETCHED[$g|$head]:-}" ] || ! _ps_sha "$g" "$head" >/dev/null; then
    if _ps_fetch "$g" main "$head"; then _PS_MAIN_FETCHED[$g]=1
    else
      _ps_fetch "$g" "$head"
      _ps_fetch "$g" main && _PS_MAIN_FETCHED[$g]=1
      if [ -n "$prref" ] && ! _ps_sha "$g" "$head" >/dev/null; then _ps_fetch "$g" "$prref"; fi
    fi
    if ! _ps_sha "$g" "$head" >/dev/null; then
      PS_FETCH_ERR=$(printf '%s\n' "${_PS_ERR:-$head is not a commit after the fetch}" | _ps_redact)
      [ -n "${_PS_MAIN_FETCHED[$g]:-}" ] && PS_FETCH_MAIN=1
      return 1
    fi
    _PS_FETCHED[$g|$head]=1
  fi
  # The reviewed sha may be gone from the remote (a force-push). In the main-merge
  # case it is an ancestor of <head> and arrived with it, so this is best-effort.
  if [ -n "$rev" ] && ! _ps_sha "$g" "$rev" >/dev/null; then
    _ps_fetch "$g" "$rev" || { [ -n "$prref" ] && _ps_fetch "$g" "$prref"; }
  fi
  [ -n "${_PS_MAIN_FETCHED[$g]:-}" ] && PS_FETCH_MAIN=1
  _PS_ERR=""
  return 0
}
