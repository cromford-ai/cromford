#!/bin/bash
# bin/lib/rules-pack-checks.sh — the rules pack's built-in checks (BH-3510).
# Sourced, never executed. Functions only. No root default (BH-2613 rule 4):
# the tree and the base are arguments. bin/rules-pack.sh runs each one for a
# catalog row of kind `builtin`: rc 0 clean, 1 findings (one per stdout line,
# `<path>: <why>`), 125 could not run.
#
# rp_grep_q <tree>
#   tests/*.sh lines that pipe a file-grep into `grep -q`, the shape that
#   flakes under pipefail (the regex is rollup-crash-loud-test.sh section 5).
#
# rp_model_id_delta <tree> <base>
#   `+` lines of `git diff <base>` over bin/ catalog/ worker/ (the price and
#   slug maps excluded, as alert-triage-runners R6 and triage-route-off-grok S7
#   exclude them) that carry a model id literal. Diffs the working tree, as
#   R6/S7 do. A worker whose schema is composed (BH-4987: worker/<w>/schema.d/
#   in the tree or at the base) is judged as ONE logical file per side instead:
#   its schema.d/ fragments in name order when it has them, else its schema.sql.
#   The model-id lines of the two sides are compared as a multiset, so a seed
#   row moved from schema.sql into a fragment, or between fragments, cancels
#   out, and a line that is new on the logical file is a finding on the
#   fragment that holds it, with or without a re-rendered schema.sql.
#
# rp_schema_fragment <tree> <base>
#   `+` lines of `git diff <base>` over worker/*/schema.d/*.sql that open a
#   CREATE [TEMP|TEMPORARY|VIRTUAL] TABLE in a fragment that exists at the base.
#   A new table goes in a NEW fragment (BH-5788): an append to an existing one
#   is the shared-EOF conflict schema.d/ exists to remove. A fragment that is
#   new against the base is never judged. `<path>:<line>: ...`, new-side line.
#
# rp_schema_fragment_name <tree> <base>
#   worker/*/schema.d/ files that are new against the base (added, renamed into
#   place, or untracked). The stamp form <yyyymmddhhmm>-<key>-<name>.sql is the
#   one to use: the stamp is a real UTC minute (year 2020-2099) and <key> a
#   lower-case ticket key (`bh-5788`, a child `bh-6005-4`). A picked NNNN
#   collides with the next build's pick (BH-5788); the key cannot, and the stamp
#   orders the composition. A new NNNN fragment is a finding only when its
#   number already exists at the base (the real collision); otherwise it passes
#   here and catalog/pr-self-check.tsv's body-schema-stamp row notes it, so the
#   PRs already open with an NNNN fragment are not turned red. Any other name is
#   a finding.
#   The stamp must also be LATER than every stamp-key fragment of the same
#   worker at the base: a fragment may use a table an earlier one made, so
#   order must follow dependency, and a stamp older than the base's newest would
#   sort before it. Existing NNNN fragments are never judged. `<path>: ...`.
#
# rp_discipline_dupes <tree>
#   `- **D<n> ` rule openers in prompts/build-discipline.md whose number an
#   earlier opener already claimed. Gaps and order are not judged. A tree with
#   no such file is clean.

rp_grep_q() {
  local hits p n=0
  hits=$(grep -ln 'grep [^|]*"\$[A-Z_]*" *| *grep -q' "$1"/tests/*.sh 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "${p#"$1"/}: pipes a file-grep into grep -q (flakes under pipefail; rollup-crash-loud section 5)"
    n=$((n+1))
  done <<< "$hits"
  [ "$n" -eq 0 ]
}

rp_model_id_delta() {
  local d l path="" n=0 w f t=""
  local -a ws=() ex=()
  # Bracketed so this file never matches its own pattern.
  local re='claude-[a-z]+-[0-9]|grok-[0-9]|gpt[-]|accounts/fireworks/model[s]'
  [ -n "${2:-}" ] || return 125
  # The composed workers: a schema.d/ in the tree or at the base.
  for f in "$1"/worker/*/schema.d; do
    [ -d "$f" ] || continue
    w=${f%/schema.d}; ws+=("${w##*/}")
  done
  while IFS= read -r w; do
    w=${w#worker/}
    git -C "$1" cat-file -e "$2:worker/$w/schema.d" 2>/dev/null || continue
    case " ${ws[*]} " in *" $w "*) ;; *) ws+=("$w") ;; esac
  done < <(git -C "$1" ls-tree -d --name-only "$2" worker/ 2>/dev/null)
  for w in "${ws[@]}"; do ex+=(":(exclude)worker/$w/schema.sql" ":(exclude)worker/$w/schema.d"); done
  d=$(git -C "$1" diff "$2" -- bin catalog worker \
        ':(exclude)catalog/model-prices.json' ':(exclude)catalog/model-slugs.json' "${ex[@]}") || return 125
  while IFS= read -r l; do
    case "$l" in
      '+++ b/'*) path=${l#+++ b/}; continue ;;
      '+++'*) continue ;;
      +*) [[ $l =~ $re ]] || continue
          echo "$path: adds a model id literal (R6/S7): ${l#+}"; n=$((n+1)) ;;
    esac
  done <<< "$d"
  [ "${#ws[@]}" -eq 0 ] || t=$(mktemp -d "${TMPDIR:-/tmp}/rules-pack.mid.XXXXXX") || return 125
  for w in "${ws[@]}"; do
    # The base side: the logical file's model-id lines.
    if git -C "$1" cat-file -e "$2:worker/$w/schema.d" 2>/dev/null; then
      while IFS= read -r f; do
        git -C "$1" show "$2:worker/$w/schema.d/$f" 2>/dev/null
      done < <(git -C "$1" ls-tree --name-only "$2:worker/$w/schema.d" 2>/dev/null | LC_ALL=C sort)
    else
      git -C "$1" show "$2:worker/$w/schema.sql" 2>/dev/null
    fi | { grep -E "$re" || true; } > "$t/base"
    # The tree side, `<path>\t<line>` in composition order.
    if [ -d "$1/worker/$w/schema.d" ]; then
      while IFS= read -r f; do
        awk -v p="worker/$w/schema.d/$f" -v re="$re" '$0 ~ re { print p "\t" $0 }' "$1/worker/$w/schema.d/$f"
      done < <(for f in "$1/worker/$w/schema.d"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done | LC_ALL=C sort)
    elif [ -f "$1/worker/$w/schema.sql" ]; then
      awk -v p="worker/$w/schema.sql" -v re="$re" '$0 ~ re { print p "\t" $0 }' "$1/worker/$w/schema.sql"
    fi > "$t/tree"
    # Multiset: each base line cancels one equal tree line; what is left is new.
    while IFS= read -r l; do
      echo "$l"; n=$((n+1))
    done < <(awk -F'\t' -v b="$t/base" '
      FILENAME == b { have[$0]++; next }
      { l = substr($0, length($1) + 2)
        if (have[l] > 0) { have[l]--; next }
        print $1 ": adds a model id literal (R6/S7): " l }' "$t/base" "$t/tree")
  done
  [ -z "$t" ] || { rm -f "$t/base" "$t/tree"; rmdir "$t"; }
  [ "$n" -eq 0 ]
}

rp_schema_fragment() {
  local l path="" ln=0 n=0 skip=1 re
  re='^[[:space:]]*create[[:space:]]+((temp|temporary|virtual)[[:space:]]+)?table([[:space:]]|$)'
  [ -n "${2:-}" ] || return 125
  git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1 || return 125
  while IFS= read -r l; do
    case "$l" in
      '+++ b/'*) path=${l#+++ b/}
                 # A fragment the base does not have is new: any table may open there.
                 if git -C "$1" cat-file -e "$2:$path" 2>/dev/null; then skip=0; else skip=1; fi ;;
      '+++'*) skip=1 ;;
      '@@ '*) ln=${l#*+}; ln=${ln%% *}; ln=${ln%%,*} ;;
      +*) [ "$skip" = 0 ] || continue
          l=${l#+}
          if [[ ${l,,} =~ $re ]]; then
            echo "$path:$ln: schema-fragment: a new table goes in a new schema.d fragment"; n=$((n+1))
          fi
          ln=$((ln+1)) ;;
    esac
  done < <(git -C "$1" diff --no-renames --no-color -U0 "$2" -- 'worker/*/schema.d/*.sql' 2>/dev/null)
  [ "$n" -eq 0 ]
}

rp_schema_fragment_name() {
  local f b n=0 re top tt
  re='^(20[2-9][0-9])(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([01][0-9]|2[0-3])[0-5][0-9]-[a-z]+-[0-9]+-[a-z0-9][a-z0-9_-]*\.sql$'
  [ -n "${2:-}" ] || return 125
  git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1 || return 125
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b=${f##*/}
    if [[ $b =~ ^[0-9]{4}-[a-z0-9][a-z0-9_-]*\.sql$ ]]; then
      # A picked NNNN is refused only when the base already has that number:
      # that is the real collision. Any other new NNNN fragment passes here, and
      # the self-check row body-schema-stamp NOTES it (open NNNN PRs stay green
      # until a follow-up tightens it).
      top=$(git -C "$1" ls-tree --name-only "$2" -- "${f%/*}/" 2>/dev/null | grep -F -- "/${b:0:4}-" | LC_ALL=C sort | head -n 1)
      if [ -n "$top" ]; then
        echo "$f: schema-fragment-name: number ${b:0:4} is already taken at the base by $top; name a new fragment <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key)"
        n=$((n+1))
      fi
      continue
    fi
    if ! [[ $b =~ $re ]]; then
      echo "$f: schema-fragment-name: a new fragment is named <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key), never a picked number"
      n=$((n+1)); continue
    fi
    # The newest stamp-key fragment of this worker at the base. Names sort by
    # stamp first, so the last one under LC_ALL=C is the newest.
    top=$(git -C "$1" ls-tree --name-only "$2" -- "${f%/*}/" 2>/dev/null \
          | while IFS= read -r t; do [[ ${t##*/} =~ $re ]] && printf '%s\n' "$t"; done | LC_ALL=C sort | tail -n 1)
    tt=${top##*/}
    if [ -n "$top" ] && ! [[ ${b:0:12} > ${tt:0:12} ]]; then
      echo "$f: schema-fragment-name: the stamp must be later than every fragment at the base, so this one sorts after any table it may use (take the current UTC minute); newest at the base: $top"
      n=$((n+1))
    fi
  done < <({ git -C "$1" diff --no-renames --name-only --diff-filter=A "$2" -- 'worker/*/schema.d/*' 2>/dev/null
             git -C "$1" ls-files --others --exclude-standard -- 'worker/*/schema.d/*' 2>/dev/null; } | LC_ALL=C sort -u)
  [ "$n" -eq 0 ]
}

rp_discipline_dupes() {
  local f="$1/prompts/build-discipline.md"
  [ -f "$f" ] || return 0
  awk '
    match($0, /^- \*\*D[0-9]+ /) {
      d = substr($0, 6, RLENGTH - 6) + 0
      if (d in first) { print "prompts/build-discipline.md:" NR ": duplicate D" d " (first at line " first[d] ")"; n++ }
      else first[d] = NR
    }
    END { exit n > 0 }' "$f"
}
