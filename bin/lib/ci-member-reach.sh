#!/bin/bash
# bin/lib/ci-member-reach.sh — THE MEMBER UNION of a merge-queue batch
# (BH-7290, BH-7033.4). Sourced by bin/ci-plan.sh, never executed.
#
# WHY. A batch selects through `bin/test-impact.sh select --changed` over its
# combined diff, and ONE path the map does not know (`full: unknown reach (<p>)`
# or `full: unmapped path (<p>)`) sent the whole batch, every member, to the
# full corpus. The union plans what the members select instead: each unmapped
# path is taken out of the diff and replaced by its directory's suites plus the
# infra canaries, and the rest of the diff selects as usual. A member's own
# selection is the union of its paths' picks plus the always set, so the union
# of the members' selections is this one list. It is computed from the tree and
# the diff only (no network), so every shard re-plans the same list.
#
#   cmr_canaries <root> <out>   the canary list (#7287's catalog/ci-infra-canary.txt,
#                               or CI_INFRA_CANARY_FILE), validated, sorted, unique.
#                               rc 1 with CMR_WHY on any doubt.
#   cmr_dir_suites <map> <path> the suites with a map row under dirname(<path>)/
#                               (recursive). `*` rows and the whole-tree root rows
#                               (bin/ bin/lib/ catalog/) do not count. A top-level
#                               path takes the rows on top-level files only.
#   cmr_union <impact> <changed> <out> <tmpdir>
#                               rc 0: <out> is the union, CMR_REASON says why.
#                               rc 1: off, CMR_WHY says why; the caller keeps the
#                               full corpus. rc 2: a select failed; the caller
#                               exits 2 (never a green of nothing).
#
# OFF (rc 1), the batch stays full: CI_PLAN_MEMBER_UNION=0 (the rollback knob),
# a canary list that is absent, empty or has a bad line, a map that cannot be
# built, more than CMR_MAX_UNMAPPED unmapped paths, or any other full answer on
# the rest of the diff (an infra path, an empty selection).
[ -n "${_CMR_LOADED:-}" ] && return 0
_CMR_LOADED=1
CMR_MAX_UNMAPPED=20

cmr_canaries() {
  local root="$1" out="$2" f l
  f="${CI_INFRA_CANARY_FILE:-$root/catalog/ci-infra-canary.txt}"
  CMR_WHY=""
  : > "$out" || { CMR_WHY="cannot write the canary list"; return 1; }
  { [ -f "$f" ] && [ -r "$f" ]; } || { CMR_WHY="cannot read ${f#"$root"/}"; return 1; }
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l =~ ^[[:space:]]*(#|$) ]] && continue
    case "$l" in
      *..*|*[*?[]*|*[[:space:]]*) CMR_WHY="a glob, a .. or a space: $l"; return 1 ;;
      tests/*.sh) ;;
      *) CMR_WHY="not a tests/<name>.sh path: $l"; return 1 ;;
    esac
    [ -f "$root/$l" ] || { CMR_WHY="no such suite: $l"; return 1; }
    printf '%s\n' "$l" >> "$out"
  done < "$f"
  grep -q . "$out" || { CMR_WHY="no suite listed"; return 1; }
  LC_ALL=C sort -u -o "$out" "$out"
}

cmr_dir_suites() {
  local d
  d=$(dirname -- "$2")
  awk -F'\t' -v d="$d" '
    $2 == "*" || $2 == "bin/" || $2 == "bin/lib/" || $2 == "catalog/" { next }
    d == "." { if (index($2, "/") == 0) print $1; next }
    index($2, d "/") == 1 { print $1 }
  ' "$1" | LC_ALL=C sort -u
}

cmr_union() {
  local impact="$1" changed="$2" out="$3" tmp="$4" r p k=0 first="" d c
  CMR_WHY=""; CMR_REASON=""
  [ "${CI_PLAN_MEMBER_UNION:-1}" != 0 ] || { CMR_WHY="CI_PLAN_MEMBER_UNION=0"; return 1; }
  cmr_canaries "$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)" "$tmp/cmr.canaries" \
    || { CMR_WHY="canary list unreadable ($CMR_WHY)"; return 1; }
  "$impact" map --out "$tmp/cmr.map" 2>/dev/null && [ -s "$tmp/cmr.map" ] \
    || { CMR_WHY="the map could not be built"; return 1; }
  cp "$changed" "$tmp/cmr.rest" 2>/dev/null || { CMR_WHY="the changed list could not be read"; return 1; }
  : > "$tmp/cmr.unmapped"
  while :; do
    TI_BATCH_SELECT=1 "$impact" select --changed "$tmp/cmr.rest" --map "$tmp/cmr.map" \
      --out "$tmp/cmr.sel" 2>"$tmp/cmr.why" || return 2
    r=$(sed -n 's/^impact: [0-9]* of [0-9]* suites (\(.*\))$/\1/p' "$tmp/cmr.why" | tail -1)
    [ -n "$r" ] || return 2
    case "$r" in
      "full: unknown reach ("*")") p="${r#full: unknown reach (}" ;;
      "full: unmapped path ("*")") p="${r#full: unmapped path (}" ;;
      "full: "*) CMR_WHY="another full answer: ${r#full: }"; return 1 ;;
      *) break ;;
    esac
    p="${p%)}"
    k=$((k + 1))
    [ "$k" -le "$CMR_MAX_UNMAPPED" ] || { CMR_WHY="more than $CMR_MAX_UNMAPPED unmapped paths"; return 1; }
    [ -n "$first" ] || first="$p"
    printf '%s\n' "$p" >> "$tmp/cmr.unmapped"
    # The path must leave the list, or the next select answers the same.
    grep -vxF -- "$p" "$tmp/cmr.rest" > "$tmp/cmr.rest2"
    cmp -s "$tmp/cmr.rest" "$tmp/cmr.rest2" && return 2
    mv "$tmp/cmr.rest2" "$tmp/cmr.rest"
  done
  [ "$k" -gt 0 ] || { CMR_WHY="the select did not answer unmapped again"; return 1; }
  : > "$tmp/cmr.dir"
  while IFS= read -r p; do
    cmr_dir_suites "$tmp/cmr.map" "$p" >> "$tmp/cmr.dir"
  done < "$tmp/cmr.unmapped"
  LC_ALL=C sort -u -o "$tmp/cmr.dir" "$tmp/cmr.dir"
  LC_ALL=C sort -u "$tmp/cmr.sel" "$tmp/cmr.dir" "$tmp/cmr.canaries" > "$out" || return 2
  grep -q . "$out" || return 2
  d=$(grep -c . "$tmp/cmr.dir"); c=$(grep -c . "$tmp/cmr.canaries")
  CMR_REASON="member union (BH-7033.4): $k unmapped path(s) ($first): $d directory + $c canaries; $r"
}
