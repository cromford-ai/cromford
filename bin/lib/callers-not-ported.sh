#!/bin/bash
# bin/lib/callers-not-ported.sh — BH-7815: a NOTE when the merge of the base and
# the PR head still names a path the PR deletes or renames. Main can add a new
# reader of the old path after the plan read its callers; the PR's own CI does
# not run that reader, so the merge queue goes red. This lint finds it before
# the review. It is a NOTE only: it never refuses, never holds and never changes
# a verdict. Sourced; defines functions only, no output at source time.
#
# cnp_scan <repo> <base-ref> <head>
#   One finding per line, no prefix, rc 0 on every path:
#     <file>:<line> still references <old>, which this PR deletes or renames;
#     port it after you merge main.[ (<file> was added by <sha12>, not in this PR's diff)]
#   1. The old paths: `git diff --name-status -M --diff-filter=DR` of the merge
#      base against the head (D rows and the old side of R rows). None = no
#      output and no further git call.
#   2. The merged tree: `git merge-tree --write-tree <base> <head>`. A conflict
#      (rc 1) still writes a tree with every file, and it is read.
#   3. An old path the merged tree still has is dropped (main kept or re-added it).
#   4. ONE `git grep -F` over the merged tree, binary files and the frozen
#      records under .harness/specs/ and docs/notes/ excepted.
#   5. A hit is a reference only on a path boundary: the char before it is not
#      [A-Za-z0-9_.-]; the char after it is not [A-Za-z0-9_/-], and not a `.`
#      followed by [A-Za-z0-9]. So `catalog/x.tsv.` counts, `catalog/x.tsv.bak`
#      does not. One finding per (file, line, old path), sorted by file and line.
#   6. A referencing file the PR does not change gets the suffix naming the
#      commit on the base that added it (at most 20 lookups).
#   Caps: 500 old paths (past that, one `could not run` line), 20 findings
#   (then `and <n> more`). A step that cannot run prints one
#   `could not run: <why>` line, never silence that reads as clean.
# psc_cnp_check <repo> <base> <head> <id>
#   The self-check rule callers-not-ported (bin/lib/pr-self-check.sh): every
#   cnp_scan line as `NOTE <id>: <line>`, the shape self_check_hold
#   (bin/lead-review-enqueue.sh) and lgsc_notes (bin/lib/lead-gates-selfcheck.sh)
#   forward into the lead review notes. rc 0 on every path.
# The CLI is bin/callers-not-ported-lint.sh.

cnp_scan() {
  local repo="${1:-}" base="${2:-}" head="${3:-}" mb old p keep="" n=0 mt mrc tree hits grc changed f sha out total
  local -A added=()
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "could not run: $repo is not a git repository"; return 0; }
  mb=$(git -C "$repo" merge-base "$base" "$head" 2>/dev/null) && [ -n "$mb" ] \
    || { echo "could not run: no merge base of $base and ${head:0:12}"; return 0; }
  old=$(git -C "$repo" diff --name-status -M --diff-filter=DR "$mb" "$head" 2>/dev/null) \
    || { echo "could not run: git diff of the merge base and ${head:0:12} failed"; return 0; }
  old=$(awk -F'\t' '$1 == "D" || $1 ~ /^R/ { print $2 }' <<<"$old")
  [ -n "$old" ] || return 0
  mt=$(git -C "$repo" merge-tree --write-tree "$base" "$head" 2>/dev/null); mrc=$?
  tree=${mt%%$'\n'*}
  if { [ "$mrc" != 0 ] && [ "$mrc" != 1 ]; } || ! [[ "$tree" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "could not run: git merge-tree --write-tree failed (rc $mrc)"; return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git -C "$repo" cat-file -e "$tree:$p" 2>/dev/null && continue
    keep="$keep$p"$'\n'; n=$((n + 1))
  done <<<"$old"
  [ -n "$keep" ] || return 0
  if [ "$n" -gt 500 ]; then echo "could not run: $n deleted or renamed paths, over the cap of 500"; return 0; fi
  # -z: `<tree>:<path>\0<line>\0<text>`. NUL becomes \001 so awk can split it.
  hits=$(printf '%s' "$keep" | git -C "$repo" grep --no-color -z -n -I -F -f - "$tree" \
           -- . ':(exclude).harness/specs' ':(exclude)docs/notes' 2>/dev/null | tr '\000' '\001'; exit "${PIPESTATUS[1]}"); grc=$?
  [ "$grc" = 1 ] && return 0
  [ "$grc" = 0 ] || { echo "could not run: git grep failed (rc $grc)"; return 0; }
  hits=$(CNP_OLD="$keep" LC_ALL=C awk -F'\001' '
    BEGIN { np = split(ENVIRON["CNP_OLD"], P, "\n") }
    function ref(t, p,   s, i, b, a, a2) {
      s = 0
      while ((i = index(substr(t, s + 1), p)) > 0) {
        i += s; s = i
        b = (i > 1) ? substr(t, i - 1, 1) : ""
        a = substr(t, i + length(p), 1); a2 = substr(t, i + length(p) + 1, 1)
        if (b ~ /[A-Za-z0-9_.-]/) continue
        if (a ~ /[A-Za-z0-9_\/-]/) continue
        if (a == "." && a2 ~ /[A-Za-z0-9]/) continue
        return 1
      }
      return 0
    }
    NF >= 3 {
      f = $1; sub(/^[0-9a-f]+:/, "", f); ln = $2
      t = $3; for (k = 4; k <= NF; k++) t = t "\001" $k
      for (j = 1; j <= np; j++) if (P[j] != "" && ref(t, P[j])) print f "\t" ln "\t" P[j]
    }' <<<"$hits" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2n -k3,3 -u)
  [ -n "$hits" ] || return 0
  changed=$(git -C "$repo" diff --no-renames --name-only "$mb" "$head" 2>/dev/null)
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF -- "$f" <<<"$changed" && continue
    n=$((n + 1)); [ "$n" -le 20 ] || break
    sha=$(git -C "$repo" log -1 --format=%H --diff-filter=A "$base" -- "$f" 2>/dev/null)
    [ -n "$sha" ] && added[$f]=${sha:0:12}
  done < <(cut -f1 <<<"$hits" | awk '!seen[$0]++')
  total=0
  while IFS=$'\t' read -r f n p; do
    total=$((total + 1)); [ "$total" -le 20 ] || continue
    out="$f:$n still references $p, which this PR deletes or renames; port it after you merge main."
    [ -n "${added[$f]:-}" ] && out="$out ($f was added by ${added[$f]}, not in this PR's diff)"
    printf '%s\n' "$out"
  done <<<"$hits"
  [ "$total" -gt 20 ] && echo "and $((total - 20)) more"
  return 0
}

psc_cnp_check() {
  local repo="$1" base="$2" head="$3" id="${4:-callers-not-ported}" l
  while IFS= read -r l; do
    [ -n "$l" ] && printf 'NOTE %s: %s\n' "$id" "$l"
  done < <(cnp_scan "$repo" "$base" "$head")
  return 0
}
