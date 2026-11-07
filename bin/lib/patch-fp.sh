# shellcheck shell=bash
# bin/lib/patch-fp.sh — the review fingerprint of ONE PR head, and the ticket
# key of a PR (BH-9154, Fix 3 of #9066). Sourced, never run.
#
# WHY. bin/lib/patch-same.sh compares two heads it already has side by side.
# The ticket replay (bin/lib/lead-gates.d/52-ticket-replay.sh) must compare a
# head with a head of ANOTHER PR that it does not have: the second PR of one
# ticket (a rebuild, a re-plan) often carries the reviewed patch byte for byte,
# on a newer main and with its schema fragments restamped. So the lead's
# verdict is stored under a fingerprint of the patch (the lead_ticket_verdicts
# table of harness-jobs), and a head is looked up by its own fingerprint.
#
#   patch_review_fp <git-dir> <main-ref> <sha>
#     rc 0 and prints `v1-<64 hex>`: sha256 of the normalized `--raw` summary
#     (old mode, new mode, status, path per file) and the `git patch-id
#     --verbatim` of the normalized diff, both from the merge-base of <sha>
#     with <main-ref>. NORMALIZED means: each worker/<w>/schema.d/<12-digit
#     stamp>-<suffix>.sql fragment the head adds is replaced by the placeholder
#     patch_same_restamp uses (`@PS_STAMP_<w>_<i>@<suffix>`, _ps_restamp_norm),
#     so a restamp alone does not change the fingerprint; nothing else is
#     normalized. VERBATIM, never --stable: indentation and trailing spaces are
#     a change (#2386). A mode change is a change (the --raw summary).
#     rc 1 on anything it cannot establish: no merge-base, an empty diff, a
#     binary file, a git or python failure, or bin/lib/patch-same.sh missing.
#
#   patch_ticket_key <head-ref> [<title>]
#     rc 0 and prints the ticket key, upper case: from a head ref
#     `ticket/<key>` or `ticket/<key>-r<N>` (a rebuild; the shared
#     ticket_branch_key in bin/lib/ticket-branch.sh, BH-3835), else from a title
#     that starts with `<KEY>:`, `<KEY> ` or `<type>(<KEY>):`. A key is
#     letters, a dash and digits (`BH-9154`). rc 1 when neither names one.
#     The same function runs at the writer (bin/lib/lead-review/result.sh) and
#     at the reader (gate 52), so a key is normalized once, the same way (D17).

_pf_dir="${BASH_SOURCE[0]%/*}"
command -v _ps_restamp_norm >/dev/null 2>&1 || { [ -r "$_pf_dir/patch-same.sh" ] && . "$_pf_dir/patch-same.sh"; }
command -v ticket_branch_key >/dev/null 2>&1 || { [ -r "$_pf_dir/ticket-branch.sh" ] && . "$_pf_dir/ticket-branch.sh"; }

# _pf_map <git-dir> <base> <sha> <map-file> — one `<dir><TAB><basename><TAB>
#   <placeholder>` line per stamp fragment <sha> adds since <base> (the
#   _ps_restamp_maps line format). rc 1 when the list is unreadable or a
#   basename repeats.
_pf_map() {
  local frags p w pw="" n=0 b
  frags=$(_ps_frags "$1" "$2" "$3") || return 1
  : > "$4" || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b=${p##*/}; w=${p#worker/}; w=${w%%/*}
    [ "$w" = "$pw" ] || { pw=$w; n=0; }
    printf '%s\t%s\t@PS_STAMP_%s_%s@%s\n' "${p%/*}" "$b" "$w" "$n" "${b:12}" >> "$4"
    n=$((n + 1))
  done <<<"$frags"
  [ -z "$(cut -f2 "$4" | LC_ALL=C sort | uniq -d)" ]
}

# _pf_plain <git-dir> <base> <sha> — the normalized text of a head that adds no
#   stamp fragment, in _ps_restamp_norm's output format: `#raw` lines, then
#   the patch with its `index` lines dropped. rc 1 on a failure, a binary
#   file or an empty diff.
_pf_plain() {
  local -a gd=(git -C "$1" -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv)
  local num raw patch
  num=$("${gd[@]}" --numstat "$2" "$3" 2>/dev/null) && [ -n "$num" ] || return 1
  ! grep -qE $'^-\t-\t' <<<"$num" || return 1
  raw=$("${gd[@]}" --raw --no-abbrev "$2" "$3" 2>/dev/null) || return 1
  patch=$("${gd[@]}" --src-prefix=a/ --dst-prefix=b/ "$2" "$3" 2>/dev/null) && [ -n "$patch" ] || return 1
  awk -F'\t' 'NF >= 2 { split(substr($1, 2), f, " "); if (f[5] == "") exit 1; print "#raw " f[1] " " f[2] " " f[5] "\t" $2 }' <<<"$raw" || return 1
  grep -av '^index ' <<<"$patch"
}

patch_review_fp() {
  local g="${1:-}" main="${2:-}" sha base td rc=1 id raw
  [ -n "$g" ] && [ -n "$main" ] || return 1
  command -v _ps_restamp_norm >/dev/null 2>&1 && command -v _ps_frags >/dev/null 2>&1 || return 1
  sha=$(_ps_sha "$g" "${3:-}") || return 1
  base=$(_ps_base "$g" "$main" "$sha") || return 1
  td=$(mktemp -d "${TMPDIR:-/tmp}/patch-fp.XXXXXX") || return 1
  if _pf_map "$g" "$base" "$sha" "$td/map"; then
    if [ -s "$td/map" ]; then
      _ps_restamp_norm "$g" "$main" "$sha" "$td/map" > "$td/norm" || : > "$td/norm"
    else
      _pf_plain "$g" "$base" "$sha" > "$td/norm" || : > "$td/norm"
    fi
    if [ -s "$td/norm" ] && grep -a '^#raw ' "$td/norm" > "$td/raw" && [ -s "$td/raw" ] && id=$(_ps_norm_id "$td/norm"); then
      raw=$(sha256sum < "$td/raw" | cut -d' ' -f1)
      [[ "$raw" =~ ^[0-9a-f]{64}$ ]] && rc=0
    fi
  fi
  rm -rf "$td"
  [ "$rc" = 0 ] || return 1
  printf 'v1-%s' "$(printf '%s\n%s\n' "$raw" "$id" | sha256sum | cut -d' ' -f1)"
}

patch_ticket_key() {
  local ref="${1:-}" title="${2:-}" k=""
  if k=$(ticket_branch_key "$ref" 2>/dev/null); then :
  elif [[ "$title" =~ ^([A-Za-z]+-[0-9]+)(:|[[:space:]]) ]]; then k="${BASH_REMATCH[1]}"
  elif [[ "$title" =~ ^[a-z]+\(([A-Za-z]+-[0-9]+)\): ]]; then k="${BASH_REMATCH[1]}"
  fi
  [ -n "$k" ] || return 1
  printf '%s' "${k^^}"
}
