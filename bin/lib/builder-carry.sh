# shellcheck shell=bash
# bin/lib/builder-carry.sh — does a builder APPROVE on head A stand on head B,
# because B carries exactly A's patch? (BH-7043). Sourced, never run. Needs
# bin/lib/patch-same.sh loaded first.
#
# WHY. The builder's APPROVE is bound to the head it reviewed. When main moves
# and the PR only takes it in (a clean `git merge origin/main`, or a byte-exact
# rebase), the new head has no builder APPROVE, so the lead replay of BH-5294
# found it "unapproved" and the head waited on CI or a new builder review
# (#6988, 2026-10-16: `no builder APPROVE on this head and CI not known green`).
# The PR's own files did not change, so the APPROVE is carried, with no model
# call. The decision is patch_same (bin/lib/patch-same.sh): identical,
# main-merge (only clean merges of main since A) or patch-id (--verbatim).
#
#   bc_carry <clone> <slug> <n> <approved-sha> <head> <state-dir>
#     rc 0  BC_HOW = identical|main-merge|patch-id: the APPROVE on A carries to B.
#     rc 1  BC_WHY = `patch changed since <A12>`: git settled that it does not.
#     rc 2  BC_WHY names why it could not decide (a failed fetch with the
#           redacted git error, no checkout, the lib not loaded, a bad
#           argument). Nothing is cached, and the caller does what it did before.
#
# CACHE. <state-dir>/builder-carry.tsv, one TAB row per settled answer:
#   <epoch> <slug> <n> <approved> <head> <carried <how>|refused>
# Both shas are immutable, so a row never goes stale: a repeat call answers
# from it with no fetch. Only rc 0 and rc 1 are written, and rc 1 only when
# origin/main was fetched in this process (PS_FETCH_MAIN): a refusal over a
# stale origin/main is asked again. Retention: bc_prune <state-dir> drops rows
# older than 7 days, the window of the enqueue's delta.tsv.
#
# It records nothing else. It posts no verdict row and writes no head-bound
# artifact: the merge conductor reads a `source=box` row as a review
# (bin/lib/mc/classify.sh vd_box_word), and `reapproved@<head>` is trusted by
# the merge and land lanes. A carry only tells the lead lane that B is approved.

bc_carry() {
  local clone="${1:-}" slug="${2:-}" n="${3:-}" a h st="${6:-}" f row how
  BC_HOW=""; BC_WHY=""
  a=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f'); h=$(printf '%s' "${5:-}" | tr 'A-F' 'a-f')
  if ! [[ "$a" =~ ^[0-9a-f]{40}$ && "$h" =~ ^[0-9a-f]{40}$ && "$n" =~ ^[0-9]+$ ]] || [ -z "$slug" ] || [ -z "$st" ]; then
    BC_WHY="bad arguments to bc_carry"; return 2
  fi
  f="$st/builder-carry.tsv"
  row=$(awk -F'\t' -v s="$slug" -v n="$n" -v a="$a" -v h="$h" '$2 == s && $3 == n && $4 == a && $5 == h {r = $6} END {print r}' "$f" 2>/dev/null)
  case "$row" in
    "carried "*) BC_HOW=${row#carried }; return 0 ;;
    refused) BC_WHY="patch changed since ${a:0:12}"; return 1 ;;
  esac
  if ! command -v patch_same >/dev/null 2>&1 || ! command -v patch_same_fetch >/dev/null 2>&1; then
    BC_WHY="patch-same.sh not loaded"; return 2
  fi
  [ -d "$clone/.git" ] || { BC_WHY="no checkout at $clone"; return 2; }
  if ! patch_same_fetch "$clone" "$a" "$h" "$n"; then
    BC_WHY="fetch of ${a:0:12}/${h:0:12} failed (${PS_FETCH_ERR:-no git error text})"; return 2
  fi
  mkdir -p "$st" 2>/dev/null
  if how=$(patch_same "$clone" origin/main "$a" "$h"); then
    BC_HOW=$how
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$a" "$h" "carried $how" >> "$f" 2>/dev/null || true
    return 0
  fi
  # A refusal is settled only when A itself is here: an A the fetches never
  # brought in is not an answer about the patch.
  _ps_sha "$clone" "$a" >/dev/null || { BC_WHY="fetch of ${a:0:12}/${h:0:12} failed (${a:0:12} is not in $clone)"; return 2; }
  BC_WHY="patch changed since ${a:0:12}"
  [ "${PS_FETCH_MAIN:-0}" = 1 ] \
    && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$a" "$h" refused >> "$f" 2>/dev/null
  return 1
}

# bc_prune <state-dir> — drop builder-carry.tsv rows older than 7 days.
bc_prune() {
  local f="${1:-}/builder-carry.tsv"
  [ -n "${1:-}" ] && [ -f "$f" ] || return 0
  awk -F'\t' -v c=$(( $(date +%s) - 604800 )) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  rm -f "$f.tmp.$$" 2>/dev/null
  return 0
}
