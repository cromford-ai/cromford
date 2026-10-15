# shellcheck shell=bash
# bin/lib/lead-delta.sh — how much of a lead review does a moved PR head need?
# (BH-5294). Sourced by bin/lead-review-enqueue.sh and bin/lead-review.sh, never run.
#
# WHY. On 2026-10-07 about 55 PRs waited for a lead review, and most were heads
# where an agent or the resolver had only merged origin/main in to clear a
# conflict. The lead had already approved the PR's own change at an earlier head
# G. Each new head H still bought a full Opus review of code the lead approved.
# This file answers, with git alone and no model, which of three a head needs:
#
#   replay  H carries exactly G's patch (bin/lib/patch-same.sh says so): the
#           lead's word on G is posted on H, no model call.
#   delta   the PR's own files changed by at most LEAD_DELTA_REVIEW_MAX_LINES
#           lines between G and H: the lead reviews on the SAME lead.review
#           model route, but reads G's report, the inter-diff and the conflict
#           resolutions instead of the whole branch.
#   full    anything else: the review it always got.
#
# NO MODEL CHOICE LIVES HERE. Delta mode changes what the reviewer reads, never
# which model reads it: bin/lead-review.sh resolves model_for lead.review exactly
# as for a full review.
#
# THE OWN DELTA (BH-5582) is the PR's own change between G and H, with what a
# main merge brought in taken out. git builds the tree "G's patch carried onto
# H's main base": with mg = merge-base(main, G) and mh = merge-base(main, H),
# that is G's tree when mg = mh, else `git merge-tree --write-tree
# --merge-base=mg mh G`. The own delta is the diff from that tree to H, over
# all paths, renames off. A file only main changed is the same on both sides,
# so it is not in it. A conflict leaves its markers in the base tree, so a
# hand resolution counts its lines plus the markers: more than the truth,
# never less. Any merge-tree answer but clean (rc 0) or conflict (rc 1) is
# full diff-unavailable. Before BH-5582 the count was G..H over the PR's
# files, and a main merge that touched one of them was counted as the PR's
# own (the over-max 342/499 lines of #5582).
#
# PROTECTED PATHS. .mergify.yml, .github/, a schema or migrations file, or one
# of the repo's lead protected paths (bin/lib/lead-authority.sh la_globs: the
# live lead_protected_paths rows plus the seed floor). A replay never
# crosses one in the own delta. A delta covers one only when the lead's word
# on G was MERGE or MERGE-WITH-NOTES, the own delta is at most
# LEAD_DELTA_PROTECTED_MAX_LINES lines (0 = never), and every protected path
# is plain enough to ride a space-split scope note ([A-Za-z0-9._/@+-]). Then
# the delta line names them and bin/lead-review.sh tells the reviewer to read
# each one with full-review scrutiny. Anything else is a full review. A
# protected list that cannot be read is a full review too.
#
# EVERY UNKNOWN IS A FULL REVIEW. A knob that does not resolve, a commit that
# is not here, a git command that fails, a binary file numstat cannot size, an
# unreadable protected list: each answers `full <reason>`. A
# LEAD_DELTA_PROTECTED_MAX_LINES that does not resolve acts as 0.
#
# ld_knob <ENV>     LEAD_DELTA_REVIEW_MAX_LINES | LEAD_DELTA_REVIEW_MAX_BYTES |
#                   LEAD_DELTA_PROTECTED_MAX_LINES, a
#                   knob of catalog/lanes.d/_lib.lead-delta.json: operator row >
#                   cached row > env > registry default, through lane-gate.sh's
#                   lib_env_apply in a subshell (fix-delta-review.sh's fdr_knob
#                   is the precedent). Not digits = rc 1, never small or off.
# ld_files <git-dir> <main-ref> <G> <H>
#                   prints the PR's own files (from the merge base with main, at
#                   G and at H) that changed G..H, one per line (maybe none); rc 1
#                   when git could not say. ld_classify runs it as a probe only.
# ld_protected <slug>   reads file paths on stdin. rc 0 and prints the first hit
#                   when one is protected, rc 1 when none is, rc 2 when the
#                   repo's protected list could not be read.
# ld_classify <git-dir> <main-ref> <G> <H> <slug> [<lead word on G>]
#                   prints ONE line, always rc 0:
#                     replay <how>                      (how: patch_same's answer)
#                     delta <lines> <max> <files>[ protected:<p1>[,<p2>..]]
#                     full <reason>    reason: knob-unresolved knob-off no-commit
#                                      diff-unavailable protected:<path>
#                                      protected-unreadable binary over-max:<n>
#                   <lines> and <files> are the own delta's. An empty word (an
#                   old 5-argument caller) never allows a protected delta.
#                   The caller fetches first (patch_same_fetch).
# ld_build <git-dir> <main-ref> <G> <H> <out>
#                   writes the delta a reviewer reads to <out>: the own delta
#                   (the same base tree ld_classify counts from), then each merge
#                   commit's conflict resolution (git show
#                   --remerge-diff). Prints `delta <bytes>` (rc 0), or `full
#                   <reason>` (rc 1, <out> removed): knob-unresolved knob-off
#                   no-commit diff-unavailable over-bytes.

_LD_LIB="${BASH_SOURCE[0]%/*}"

ld_knob() {
  local k="${1:-}" v
  case "$k" in LEAD_DELTA_REVIEW_MAX_LINES|LEAD_DELTA_REVIEW_MAX_BYTES|LEAD_DELTA_PROTECTED_MAX_LINES) ;; *) return 1 ;; esac
  v=$(
    # The lib root contract (BH-2613): no literal fallback; an empty root
    # reads this checkout's own lane-gate.sh beside the lib.
    root="${HARNESS:-${H:-}}"; lg=""
    [ -n "$root" ] && lg="$root/bin/lib/lane-gate.sh"
    { [ -n "$lg" ] && [ -r "$lg" ]; } || lg="$_LD_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply lead-delta >/dev/null 2>&1
    printf '%s' "${!k:-}"
  ) || v=""
  if [ -z "$v" ]; then
    v=$(jq -r --arg k "$k" '.libs[]? | select(.id == "lead-delta") | .knobs[]?
               | select(.env == $k) | .default // empty' \
          "$_LD_LIB/../../catalog/lanes.d/_lib.lead-delta.json" 2>/dev/null)
  fi
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$v))"
}

_ld_sha() { # <git-dir> <rev> -> full commit sha, rc 1 unless it is one
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

ld_files() {
  local g="$1" main="$2" gs="$3" hs="$4" mg mh own chg
  mg=$(git -C "$g" merge-base "$main" "$gs" 2>/dev/null) && [[ "$mg" =~ ^[0-9a-f]{40}$ ]] || return 1
  mh=$(git -C "$g" merge-base "$main" "$hs" 2>/dev/null) && [[ "$mh" =~ ^[0-9a-f]{40}$ ]] || return 1
  own=$( { git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$mg" "$gs" || echo "<ld-fail>"
           git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$mh" "$hs" || echo "<ld-fail>"; } 2>/dev/null)
  case "$own" in *"<ld-fail>"*) return 1 ;; esac
  chg=$(git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$gs" "$hs" 2>/dev/null) || return 1
  [ -n "$chg" ] && [ -n "$own" ] || return 0
  # The intersection, in git's order.
  awk 'NR == FNR { if ($0 != "") own[$0] = 1; next } ($0 in own)' <(printf '%s\n' "$own") <(printf '%s\n' "$chg")
}

ld_protected() {
  local slug="${1:-}" globs="" rc=0 p g
  if command -v la_scope >/dev/null 2>&1 && command -v la_globs >/dev/null 2>&1; then
    la_scope "$slug" || rc=$?
    case "$rc" in
      0) rc=0; globs=$(la_globs "$slug") || rc=$?; [ "$rc" = 0 ] || return 2 ;;
      1) globs="" ;;
      *) return 2 ;;
    esac
  else
    return 2
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      .mergify.yml|.github/*|*[Ss][Cc][Hh][Ee][Mm][Aa]*|migrations/*|*/migrations/*) printf '%s' "$p"; return 0 ;;
    esac
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      g="${g//\*\*/*}"
      # shellcheck disable=SC2053
      [[ $p == $g ]] && { printf '%s' "$p"; return 0; }
    done <<< "$globs"
  done
  return 1
}

# _ld_base_tree <git-dir> <main-ref> <G sha> <H sha> — the tree "G's patch
# carried onto H's main base" (header, THE OWN DELTA). rc 1 on any failure.
_ld_base_tree() {
  local g="$1" main="$2" gs="$3" hs="$4" mg mh t rc=0
  mg=$(git -C "$g" merge-base "$main" "$gs" 2>/dev/null) && [[ "$mg" =~ ^[0-9a-f]{40}$ ]] || return 1
  mh=$(git -C "$g" merge-base "$main" "$hs" 2>/dev/null) && [[ "$mh" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ "$mg" = "$mh" ]; then
    t=$(git -C "$g" rev-parse --verify --quiet "$gs^{tree}" 2>/dev/null) || return 1
  else
    t=$(git -C "$g" merge-tree --write-tree --merge-base="$mg" "$mh" "$gs" 2>/dev/null) || rc=$?
    case "$rc" in 0|1) ;; *) return 1 ;; esac
    t=${t%%$'\n'*}
  fi
  [[ "$t" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$t"
}

ld_classify() {
  local g="$1" main="$2" slug="${5:-}" word="${6:-}" gs hs max pmax tree ns own p hit hits="" plain=1 prc how sum n
  max=$(ld_knob LEAD_DELTA_REVIEW_MAX_LINES) || { echo "full knob-unresolved"; return 0; }
  pmax=$(ld_knob LEAD_DELTA_PROTECTED_MAX_LINES) || pmax=0
  gs=$(_ld_sha "$g" "${3:-}") && hs=$(_ld_sha "$g" "${4:-}") && _ld_sha "$g" "$main" >/dev/null \
    || { echo "full no-commit"; return 0; }
  ld_files "$g" "$main" "$gs" "$hs" >/dev/null || { echo "full diff-unavailable"; return 0; }
  tree=$(_ld_base_tree "$g" "$main" "$gs" "$hs") || { echo "full diff-unavailable"; return 0; }
  ns=$(git -C "$g" -c core.quotepath=off diff --no-renames --numstat "$tree" "$hs" 2>/dev/null) \
    || { echo "full diff-unavailable"; return 0; }
  own=$(printf '%s\n' "$ns" | awk -F'\t' 'NF >= 3 {print $3}')
  # Every protected path of the own delta, in git's order; ld_protected names one at a time.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    prc=0; hit=$(printf '%s\n' "$p" | ld_protected "$slug") || prc=$?
    case "$prc" in
      0) hits="${hits:+$hits,}$hit"; [[ "$hit" =~ ^[A-Za-z0-9._/@+-]+$ ]] || plain=0 ;;
      1) ;;
      *) echo "full protected-unreadable"; return 0 ;;
    esac
  done <<< "$own"
  if [ -z "$hits" ] && command -v patch_same >/dev/null 2>&1 && how=$(patch_same "$g" "$main" "$gs" "$hs"); then
    echo "replay $how"; return 0
  fi
  if grep -qE $'^-\t' <<<"$ns"; then echo "full binary"; return 0; fi
  sum=$(printf '%s\n' "$ns" | awk -F'\t' 'NF >= 3 {s += $1 + $2} END {print s + 0}')
  n=$(printf '%s\n' "$own" | awk 'NF' | wc -l | tr -d ' ')
  if [ -n "$hits" ]; then
    if ! { [ "$pmax" -gt 0 ] && { [ "$word" = MERGE ] || [ "$word" = MERGE-WITH-NOTES ]; } \
           && [ "$sum" -le "$pmax" ] && [ "$plain" = 1 ]; }; then
      echo "full protected:${hits%%,*}"; return 0
    fi
  fi
  [ "$max" -gt 0 ] || { echo "full knob-off"; return 0; }
  [ "$sum" -le "$max" ] || { echo "full over-max:$sum"; return 0; }
  echo "delta $sum $max $n${hits:+ protected:$hits}"
}

ld_build() {
  local g="$1" main="$2" out="${5:-}" gs hs maxb tree c merges
  [ -n "$out" ] || { echo "full no-out"; return 1; }
  maxb=$(ld_knob LEAD_DELTA_REVIEW_MAX_BYTES) || { echo "full knob-unresolved"; return 1; }
  [ "$maxb" -gt 0 ] || { echo "full knob-off"; return 1; }
  gs=$(_ld_sha "$g" "${3:-}") && hs=$(_ld_sha "$g" "${4:-}") || { echo "full no-commit"; return 1; }
  tree=$(_ld_base_tree "$g" "$main" "$gs" "$hs") || { echo "full diff-unavailable"; return 1; }
  # A subshell, so a failed git exits it alone.
  (
    printf '### Inter-diff %s..%s (the PR'"'"'s own change since the reviewed head; what a main merge brought in is left out)\n' "${gs:0:12}" "${hs:0:12}"
    d=$(git -C "$g" diff --no-color --no-renames "$tree" "$hs") || exit 1
    if [ -n "$d" ]; then
      printf '%s\n' "$d"
    else
      printf '(none: the PR'"'"'s own change is the same at the two heads)\n'
    fi
    if git -C "$g" merge-base --is-ancestor "$gs" "$hs" 2>/dev/null; then
      merges=$(git -C "$g" rev-list --merges "$hs" "^$gs" "^$main" 2>/dev/null) || exit 1
      for c in $merges; do
        printf '\n### Conflict resolution in merge %s (empty when the merge was clean)\n' "${c:0:12}"
        git -C "$g" show --no-color --remerge-diff --format='%H %s' "$c" 2>/dev/null \
          || printf '(git show --remerge-diff is not available here; the inter-diff above carries the resolved lines)\n'
      done
    else
      printf '\n(%s is not an ancestor of %s: the branch was rebased, so there are no merge commits to show)\n' "${gs:0:12}" "${hs:0:12}"
    fi
  ) > "$out" 2>/dev/null || { rm -f "$out"; echo "full diff-unavailable"; return 1; }
  [ "$(wc -c < "$out" | tr -d ' ')" -le "$maxb" ] || { rm -f "$out"; echo "full over-bytes"; return 1; }
  echo "delta $(wc -c < "$out" | tr -d ' ')"
}
