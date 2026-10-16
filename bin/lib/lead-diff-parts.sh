# shellcheck shell=bash
# bin/lib/lead-diff-parts.sh — read an oversize PR diff in parts, for the lead review.
#
# Sourced by bin/lead-review.sh. Functions only: no set -e, no network, no model,
# and no harness root (git and text on the worktree it is given).
#
# A full-review diff over LEAD_REVIEW_DIFF_MAX_BYTES used to be cut with
# `head -c` in git's file order, so the PR's tests, the files its plan names and
# generated files fell off the end at random, and the reviewer answered BLOCK on
# what it could not read. ldp_build packs the diff in priority order instead:
#
#   1. plan   the files a .harness/specs/*/plan.md in this diff names (the plan
#             file itself too), whole files only
#   2. test   the PR's own tests
#   3. rest   everything else
#
# Generated files and fixtures (ldp_class digest) are never read: the coverage
# section lists them by path and size. A file that does not fit is skipped and
# named, never cut in half. When a test file does not fit, the review cannot
# judge the PR, so ldp_build also writes a proposed split and returns 2.
#
#   ldp_class <path> [digest-flag]
#       prints digest | test | rest. digest-flag 1 = the caller found the path
#       binary or linguist-generated.
#   ldp_build <wt> <base-ref> <sha> <budget-bytes> <out-parts> <out-split> [any]
#       rc 0  <out-parts> holds `## Diff coverage` then `## Diff`, at or under
#             the budget, and every test file was read
#       rc 2  the same, plus <out-split>: at least one test file did not fit,
#             or, with `any`, any file that is not generated or a fixture did
#             not fit (the operator, #5803: nothing merges unread)
#       rc 1  git could not list or read the diff, the budget is too small, or
#             nothing was left to drop and it still did not fit (coverage lists that
#             outgrow LDP_RESERVE first move read files to the not-read list). The
#             caller answers split required: no reviewer reads a cut diff
#   After rc 0 or 2 these globals hold the summary for the report header:
#     LDP_TOTAL_FILES LDP_TOTAL_BYTES LDP_READ_FILES LDP_DIGEST_FILES
#     LDP_TEST_FILES LDP_TEST_UNREAD LDP_UNREAD (newline list, non-digest)
#   ldp_unread_line
#       LDP_UNREAD on one line for the report header: up to 20 paths, then an
#       exact "+N more", or "none".

LDP_RESERVE=32768   # room kept for the coverage section inside the budget
LDP_LIST_MAX=200    # rows in the coverage lists; past it an exact "+N more"

ldp_class() {
  local p="${1:-}" b
  b="${p##*/}"
  [ "${2:-0}" = 1 ] && { echo digest; return 0; }
  case "$p" in
    fixtures/*|*/fixtures/*|testdata/*|*/testdata/*|__snapshots__/*|*/__snapshots__/*|generated/*|*/generated/*)
      echo digest; return 0 ;;
  esac
  case "$b" in
    *.snap|*.generated.*|*.min.js|*.min.css|*.map|package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|Cargo.lock|poetry.lock|composer.lock|Gemfile.lock|go.sum)
      echo digest; return 0 ;;
  esac
  case "$p" in
    tests/*|test/*|e2e/*|__tests__/*|__mocks__/*|*/tests/*|*/test/*|*/__tests__/*|*/__mocks__/*)
      echo test; return 0 ;;
  esac
  case "$b" in
    *.test.*|*.spec.*|*_test.*|*-test.sh|*Test.java) echo test; return 0 ;;
  esac
  echo rest
}

# _ldp_rows <file> — at most LDP_LIST_MAX lines of <file>, then the exact remainder.
_ldp_rows() {
  local n
  n=$(wc -l < "$1" | tr -d ' ')
  head -n "$LDP_LIST_MAX" "$1"
  [ "$n" -gt "$LDP_LIST_MAX" ] && printf '+%s more files, not listed\n' "$((n - LDP_LIST_MAX))"
  return 0
}

ldp_unread_line() {
  local n
  n=$(printf '%s' "$LDP_UNREAD" | grep -c .)
  [ "$n" -gt 0 ] || { printf 'none'; return 0; }
  head -n 20 <<<"$LDP_UNREAD" | paste -sd, - | sed 's/,/, /g' | tr -d '\n'
  [ "$n" -gt 20 ] && printf ', +%s more' "$((n - 20))"
  return 0
}

# _ldp_emit — the parts file on stdout: `## Diff coverage`, then `## Diff`.
# Called only from ldp_build, whose locals (d, n, budget, rp, rt, rr) it reads.
_ldp_emit() {
    printf '## Diff coverage\n'
    printf 'The diff is %s bytes in %s files. That is over the review limit of %s bytes, so it is read in parts: the files the plan names first, then the tests, then the rest. Only whole files are read; no file is cut.\n' \
      "$LDP_TOTAL_BYTES" "$n" "$budget"
    if [ -s "$d/plans" ]; then printf 'Plan file: %s\n' "$(paste -sd, "$d/plans" | sed 's/,/, /g')"
    else printf 'Plan file: no plan file in this diff\n'; fi
    printf 'Read in full: %s of %s files (plan files %s, tests %s, rest %s).\n' "$LDP_READ_FILES" "$n" "$rp" "$rt" "$rr"
    if [ "$LDP_TEST_FILES" -eq 0 ]; then printf 'Tests: no test files in this diff.\n'
    else printf 'Tests: %s of %s test files read.\n' "$((LDP_TEST_FILES - LDP_TEST_UNREAD))" "$LDP_TEST_FILES"; fi
    if [ -s "$d/unread" ]; then
      printf 'Not read (did not fit the limit), %s files:\n' "$(wc -l < "$d/unread" | tr -d ' ')"
      _ldp_rows "$d/unread"
    else
      printf 'Not read: none.\n'
    fi
    if [ -s "$d/digest" ]; then
      printf 'Digest (generated files and fixtures, listed by path and size, not read), %s files:\n' "$LDP_DIGEST_FILES"
      _ldp_rows "$d/digest"
    else
      printf 'Digest: none.\n'
    fi
    printf '\n## Diff\n'
    cat "$d/packed"
}

ldp_build() {
  local wt="$1" base="$2" sha="$3" budget="$4" outp="$5" outs="$6" any="${7:-}"
  local cap d rec add rest path i n bytes cls plantxt t f j a u used part pb fits
  local -a P=() BIN=() GEN=() CLS=() SZ=() ORD=() TIER=() ANCH=() UNIT=()
  LDP_TOTAL_FILES=0 LDP_TOTAL_BYTES=0 LDP_READ_FILES=0 LDP_DIGEST_FILES=0
  LDP_TEST_FILES=0 LDP_TEST_UNREAD=0 LDP_UNREAD=""
  [ -n "$wt" ] && [ -n "$base" ] && [ -n "$sha" ] && [ -n "$outp" ] && [ -n "$outs" ] || return 1
  case "$budget" in ''|*[!0-9]*) return 1 ;; esac
  cap=$((budget - LDP_RESERVE))
  [ "$cap" -gt 0 ] || return 1
  d="$outp.d"; rm -rf "$d" "$outs"; mkdir -p "$d" || return 1

  # The changed paths, with git's binary flag.
  git -C "$wt" diff --no-renames -z --numstat "$base...$sha" > "$d/numstat" 2>/dev/null || { rm -rf "$d"; return 1; }
  while IFS= read -r -d '' rec; do
    add="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"; path="${rest#*$'\t'}"
    [ -n "$path" ] || continue
    P+=("$path"); BIN+=("$([ "$add" = - ] && echo 1 || echo 0)"); GEN+=(0)
  done < "$d/numstat"
  n=${#P[@]}
  [ "$n" -gt 0 ] || { rm -rf "$d"; return 1; }

  # linguist-generated, read from the PR head's own .gitattributes.
  printf '%s\0' "${P[@]}" | git -C "$wt" check-attr --stdin -z linguist-generated > "$d/attr" 2>/dev/null \
    || { rm -rf "$d"; return 1; }
  declare -A GENSET=()
  while IFS= read -r -d '' path && IFS= read -r -d '' a && IFS= read -r -d '' u; do
    case "$u" in set|true) GENSET["$path"]=1 ;; esac
  done < "$d/attr"

  # Each file's own diff, and its size.
  plantxt="$d/plantext"; : > "$plantxt"
  for ((i = 0; i < n; i++)); do
    path="${P[$i]}"
    [ -n "${GENSET[$path]+x}" ] && GEN[i]=1
    git -C "$wt" diff --no-renames "$base...$sha" -- ":(literal)$path" > "$d/f$i" 2>/dev/null || { rm -rf "$d"; return 1; }
    if [ "${BIN[$i]}" = 1 ]; then
      SZ[i]=$(git -C "$wt" cat-file -s "$sha:$path" 2>/dev/null || echo 0)
    else
      SZ[i]=$(wc -c < "$d/f$i" | tr -d ' ')
    fi
    LDP_TOTAL_BYTES=$((LDP_TOTAL_BYTES + $(wc -c < "$d/f$i" | tr -d ' ')))
    cls=$(ldp_class "$path" "$([ "${BIN[$i]}" = 1 ] || [ "${GEN[$i]}" = 1 ] && echo 1 || echo 0)")
    CLS[i]="$cls"
    case "$path" in
      .harness/specs/*/plan.md)
        [ -r "$wt/$path" ] && { cat "$wt/$path" >> "$plantxt"; printf '\n' >> "$plantxt"; echo "$path" >> "$d/plans"; } ;;
    esac
  done
  LDP_TOTAL_FILES=$n

  # Tiers: plan files and the files a plan names, then tests, then the rest.

  for ((i = 0; i < n; i++)); do
    path="${P[$i]}"
    if [ "${CLS[$i]}" = digest ]; then TIER[i]=digest
    elif grep -qxF -- "$path" "$d/plans" 2>/dev/null || { [ -s "$plantxt" ] && grep -qF -- "$path" "$plantxt"; }; then TIER[i]=plan
    else TIER[i]="${CLS[$i]}"; fi
    [ "${CLS[$i]}" = test ] && LDP_TEST_FILES=$((LDP_TEST_FILES + 1))
  done
  ORD=()
  for t in plan test rest; do
    for ((i = 0; i < n; i++)); do [ "${TIER[$i]}" = "$t" ] && ORD+=("$i"); done
  done

  # Pack whole files, greedy, in that order. A file that does not fit is skipped.
  local -A READ=()
  local rp=0 rt=0 rr=0
  used=0; : > "$d/packed"; : > "$d/unread"; : > "$d/digest"
  for i in "${ORD[@]}"; do
    bytes=$(wc -c < "$d/f$i" | tr -d ' ')
    if [ $((used + bytes)) -le "$cap" ]; then
      cat "$d/f$i" >> "$d/packed"; used=$((used + bytes)); READ[$i]=1
      case "${TIER[$i]}" in plan) rp=$((rp + 1)) ;; test) rt=$((rt + 1)) ;; *) rr=$((rr + 1)) ;; esac
    else
      printf -- '- %s (%s, %s bytes)\n' "${P[$i]}" "${TIER[$i]}" "$bytes" >> "$d/unread"
      LDP_UNREAD="${LDP_UNREAD:+$LDP_UNREAD$'\n'}${P[$i]}"
      [ "${CLS[$i]}" = test ] && LDP_TEST_UNREAD=$((LDP_TEST_UNREAD + 1))
    fi
  done
  for ((i = 0; i < n; i++)); do
    [ "${TIER[$i]}" = digest ] || continue
    LDP_DIGEST_FILES=$((LDP_DIGEST_FILES + 1))
    printf -- '- %s (%s bytes%s)\n' "${P[$i]}" "${SZ[$i]}" "$([ "${BIN[$i]}" = 1 ] && echo ', binary')" >> "$d/digest"
  done
  LDP_READ_FILES=$((rp + rt + rr))

  # Emit, and while the coverage lists outgrow LDP_RESERVE (many long paths), move
  # the last file read (the lowest tier first) to the not-read list and emit
  # again. The result always fits the budget with its coverage section; rc 1 only
  # when nothing is left to drop (lead review BLOCK at b5426ef9d: rc 1 handed the
  # reviewer a cut diff with no coverage).
  while :; do
    LDP_READ_FILES=$((rp + rt + rr))
    _ldp_emit > "$outp" || { rm -rf "$d"; return 1; }
    [ "$(wc -c < "$outp" | tr -d ' ')" -le "$budget" ] && break
    j=""
    for i in "${ORD[@]}"; do [ -n "${READ[$i]+x}" ] && j="$i"; done
    [ -n "$j" ] || { rm -rf "$d"; return 1; }
    unset "READ[$j]"
    case "${TIER[$j]}" in plan) rp=$((rp - 1)) ;; test) rt=$((rt - 1)) ;; *) rr=$((rr - 1)) ;; esac
    printf -- '- %s (%s, %s bytes)\n' "${P[$j]}" "${TIER[$j]}" "$(wc -c < "$d/f$j" | tr -d ' ')" >> "$d/unread"
    LDP_UNREAD="${LDP_UNREAD:+$LDP_UNREAD$'\n'}${P[$j]}"
    [ "${CLS[$j]}" = test ] && LDP_TEST_UNREAD=$((LDP_TEST_UNREAD + 1))
    : > "$d/packed"
    for i in "${ORD[@]}"; do [ -n "${READ[$i]+x}" ] && cat "$d/f$i" >> "$d/packed"; done
  done

  if [ -z "$LDP_UNREAD" ] || { [ "$any" != any ] && [ "$LDP_TEST_UNREAD" -eq 0 ]; }; then rm -rf "$d"; return 0; fi

  # The proposed split. A unit is one non-test file (plan files first) plus every
  # test whose diff names that file's path or basename; a test goes to the first
  # such file. A test that names none is its own unit.

  local -A OWNER=()
  for i in "${ORD[@]}"; do [ "${CLS[$i]}" != test ] && ANCH+=("$i"); done
  for i in "${ORD[@]}"; do
    [ "${CLS[$i]}" = test ] || continue
    for a in "${ANCH[@]}"; do
      if grep -qF -- "${P[$a]}" "$d/f$i" || grep -qF -- "${P[$a]##*/}" "$d/f$i"; then OWNER[$i]="$a"; break; fi
    done
  done
  for a in "${ANCH[@]}"; do
    u="$a"
    for i in "${ORD[@]}"; do [ "${OWNER[$i]:-}" = "$a" ] && u="$u $i"; done
    UNIT+=("$u")
  done
  for i in "${ORD[@]}"; do
    [ "${CLS[$i]}" = test ] && [ -z "${OWNER[$i]:-}" ] && UNIT+=("$i")
  done
  {
    printf 'Each part holds at most %s bytes of diff (the %s-byte review limit less the coverage reserve), except a part marked over the limit alone. A test stays in the part of the file it names.\n' "$cap" "$budget"
    part=0; pb=0; local line=""
    for u in "${UNIT[@]}"; do
      t=0; f=""
      for j in $u; do
        bytes=$(wc -c < "$d/f$j" | tr -d ' ')
        t=$((t + bytes)); f="${f:+$f, }${P[$j]} ($bytes bytes)"
      done
      if [ "$t" -gt "$cap" ]; then
        [ -n "$line" ] && printf -- '- Part %s (%s bytes): %s\n' "$part" "$pb" "$line"
        part=$((part + 1)); line=""; pb=0
        printf -- '- Part %s (%s bytes): %s; over the limit alone: split this change\n' "$part" "$t" "$f"
        continue
      fi
      if [ -n "$line" ] && [ $((pb + t)) -gt "$cap" ]; then
        printf -- '- Part %s (%s bytes): %s\n' "$part" "$pb" "$line"; line=""; pb=0
      fi
      [ -z "$line" ] && part=$((part + 1))
      line="${line:+$line, }$f"; pb=$((pb + t))
    done
    [ -n "$line" ] && printf -- '- Part %s (%s bytes): %s\n' "$part" "$pb" "$line"
    if [ -s "$d/digest" ]; then
      printf 'Generated files and fixtures ride with the part that regenerates them:\n'
      _ldp_rows "$d/digest"
    fi
  } > "$outs" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
  return 2
}
