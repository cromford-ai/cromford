# shellcheck shell=bash
# bin/lib/lead-prev.sh — what a lead re-review needs to know about the review
# before it (BH-6391). Sourced by bin/lead-review-enqueue.sh, bin/lead-review.sh
# and bin/lead-review-land.sh, never run.
#
# WHY. In 7 days (2026-10-06 to 2026-10-13) the lead gave 908 verdicts on 415
# PRs. 158 re-reviews followed only a main merge, with no new own commit, and
# 30 of those changed the verdict on the same PR code. After a small own push,
# 28 approvals turned into a BLOCK. A full re-read finds new items each time,
# and each new BLOCK starts a fix round. So a re-review now gets the earlier
# review and the delta since it, and a new BLOCK on a line that did not change
# since an approved head is kept as a NOTE.
#
# THE TOKEN. The enqueue adds ONE group to a request's scope_notes when the PR
# has an earlier lead row (MERGE, MERGE-WITH-NOTES or BLOCK, not a lead-replay:
# row) on another head G:
#   lead-prev:<G40> word:<W> report:state/lead-reviews/lr-<pr>-<G12>.md
#     own-commits:<n|?> own-files:<csv|-|?|+n> main-files:<csv|-|?|+n>
# own-commits counts `git rev-list --no-merges H ^G ^main` when G is an ancestor
# of H, else `?` (a rebase). own-files is the own delta: the diff from "G's patch
# carried onto H's main base" (lead-delta.sh _ld_base_tree) to H. main-files is
# what main changed between merge-base(main,G) and merge-base(main,H), only the
# paths the PR touches (mg..G or mh..H). A list holds plain paths
# ([A-Za-z0-9._/@+-]) only; `,+<k>` ends a list that left k paths out, `-` is
# empty, `?` is "git could not answer" (never "no delta"), `+<n>` is a list
# lpv_fit turned into its count.
#
# EVERY UNKNOWN KEEPS THE MODEL'S WORD. A G or H git cannot resolve, a diff that
# fails, a finding with no path:line: the NOTE pass changes nothing.
#
# lpv_delta_files <git-dir> <main-ref> <G> <H>
#                 prints `commits\t<n|?>`, then `own\t<path>` lines, then
#                 `main\t<path>` lines (git order). rc 1, nothing printed, when a
#                 sha does not resolve or a git command fails.
# lpv_note <git-dir> <main-ref> <G> <word> <H> <pr>
#                 prints the token group. When lpv_delta_files fails, the three
#                 delta fields are `?`.
# lpv_parse <notes>
#                 sets LPV_PREV LPV_WORD LPV_REPORT LPV_OWNC LPV_OWN LPV_MAIN from
#                 the first group. rc 1, all empty, when there is none, G is not
#                 40 hex, or the word is not one of the three verdict words.
# lpv_fit <notes> <max-chars>
#                 over max, turns the own-files list, then the main-files list,
#                 into its count. Never cuts any other text. Prints the notes.
# lpv_section <git-dir> <main-ref> <pr> <repo> <H> <report-dir> <with-report 0|1>
#                 prints the body of the prompt's `## Re-review` section from the
#                 parsed LPV_*, and sets LPV_MAINF (main files) and LPV_OWNF (own
#                 files), one per line.
# lpv_downgrade <git-dir> <G> <H> <answer-file> <main-files-file> [<own-files-file>]
#                 the NOTE pass. A `- [BLOCK] <path>:<n>[-<m>]` line whose <path>
#                 is a file in H's tree, whose lines did not change between G and
#                 H, and that does not end with `main-cause: <p>` for a <p> in the
#                 main-files file or `own-cause: <p>` for a <p> in the own-files
#                 file, becomes `- [NOTE unchanged-since <G12>]`. A <path> that is
#                 not a file in H (a short path, `./x`, a typo) is an unknown and
#                 keeps its BLOCK. A file deleted or binary between G and H counts
#                 as changed. `[BLOCK needs-human]` and
#                 `[BLOCK split-required]` are never touched. When no `- [BLOCK`
#                 line is left, the last `VERDICT:` line becomes MERGE-WITH-NOTES.
#                 Prints k (lines rewritten). rc 0 = k >= 1; rc 1 = nothing to
#                 rewrite; rc 2 = git failed. On rc 1 and 2 the file is untouched.
# lpv_flip <notes> <verdict>
#                 rc 0 and prints `<G12> <W> own-commits:0` when the group says
#                 own-commits:0 and the verdict class (BLOCK vs MERGE and
#                 MERGE-WITH-NOTES) differs from <W>. rc 1 otherwise; rc 2 when
#                 the notes have no group.

_LPV_LIB="${BASH_SOURCE[0]%/*}"
# _ld_base_tree comes from lead-delta.sh; a caller that has not sourced it gets it here.
command -v _ld_base_tree >/dev/null 2>&1 || { [ -r "$_LPV_LIB/lead-delta.sh" ] && . "$_LPV_LIB/lead-delta.sh"; }

_lpv_sha() { # <git-dir> <rev> -> full commit sha, rc 1 unless it is one
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

lpv_delta_files() {
  local g="$1" main="$2" gs hs mg mh tree n own pr mainchg
  command -v _ld_base_tree >/dev/null 2>&1 || return 1
  gs=$(_lpv_sha "$g" "${3:-}") && hs=$(_lpv_sha "$g" "${4:-}") && _lpv_sha "$g" "$main" >/dev/null || return 1
  mg=$(git -C "$g" merge-base "$main" "$gs" 2>/dev/null) && [[ "$mg" =~ ^[0-9a-f]{40}$ ]] || return 1
  mh=$(git -C "$g" merge-base "$main" "$hs" 2>/dev/null) && [[ "$mh" =~ ^[0-9a-f]{40}$ ]] || return 1
  if git -C "$g" merge-base --is-ancestor "$gs" "$hs" 2>/dev/null; then
    n=$(git -C "$g" rev-list --count --no-merges "$hs" "^$gs" "^$main" 2>/dev/null) && [[ "$n" =~ ^[0-9]+$ ]] || return 1
  else
    n='?'
  fi
  tree=$(_ld_base_tree "$g" "$main" "$gs" "$hs") || return 1
  own=$(git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$tree" "$hs" 2>/dev/null) || return 1
  pr=$( { git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$mg" "$gs" || echo "<lpv-fail>"
          git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$mh" "$hs" || echo "<lpv-fail>"; } 2>/dev/null)
  case "$pr" in *"<lpv-fail>"*) return 1 ;; esac
  mainchg=$(git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$mg" "$mh" 2>/dev/null) || return 1
  printf 'commits\t%s\n' "$n"
  [ -n "$own" ] && printf '%s\n' "$own" | awk 'NF {print "own\t" $0}'
  [ -n "$mainchg" ] && [ -n "$pr" ] \
    && awk 'NR == FNR { if ($0 != "") t[$0] = 1; next } ($0 in t) {print "main\t" $0}' <(printf '%s\n' "$pr") <(printf '%s\n' "$mainchg")
  return 0
}

# _lpv_csv <kind> — reads lpv_delta_files lines on stdin, prints that kind's list.
_lpv_csv() {
  awk -F'\t' -v k="$1" '$1 == k { if ($2 ~ /^[A-Za-z0-9._\/@+-]+$/) l = l (l == "" ? "" : ",") $2; else u++ }
    END { if (u) l = l (l == "" ? "" : ",") "+" u; print (l == "" ? "-" : l) }'
}

lpv_note() {
  local g="$1" main="$2" gs="$3" w="$4" hs="$5" pr="$6" d n="?" own="?" mf="?"
  if d=$(lpv_delta_files "$g" "$main" "$gs" "$hs"); then
    n=$(printf '%s\n' "$d" | awk -F'\t' '$1 == "commits" {print $2; exit}')
    own=$(printf '%s\n' "$d" | _lpv_csv own)
    mf=$(printf '%s\n' "$d" | _lpv_csv main)
  fi
  printf 'lead-prev:%s word:%s report:state/lead-reviews/lr-%s-%s.md own-commits:%s own-files:%s main-files:%s' \
    "$gs" "$w" "$pr" "${gs:0:12}" "${n:-?}" "$own" "$mf"
}

lpv_parse() {
  local s="${1:-}" grp re='(^|[ ;])lead-prev:([0-9a-f]{40})( [^;]*)?(;|$)' t toks
  LPV_PREV=""; LPV_WORD=""; LPV_REPORT=""; LPV_OWNC=""; LPV_OWN=""; LPV_MAIN=""
  [[ "$s" =~ $re ]] || return 1
  LPV_PREV="${BASH_REMATCH[2]}"; grp="${BASH_REMATCH[3]}"
  read -ra toks <<<"$grp"
  for t in "${toks[@]}"; do
    case "$t" in
      word:*) LPV_WORD="${t#word:}" ;;
      report:*) LPV_REPORT="${t#report:}" ;;
      own-commits:*) LPV_OWNC="${t#own-commits:}" ;;
      own-files:*) LPV_OWN="${t#own-files:}" ;;
      main-files:*) LPV_MAIN="${t#main-files:}" ;;
    esac
  done
  case "$LPV_WORD" in
    MERGE|MERGE-WITH-NOTES|BLOCK) return 0 ;;
  esac
  LPV_PREV=""; LPV_WORD=""; LPV_REPORT=""; LPV_OWNC=""; LPV_OWN=""; LPV_MAIN=""
  return 1
}

# _lpv_count <csv> — the paths a list names: plain entries plus each +<k>.
_lpv_count() {
  local c=0 e es
  IFS=, read -ra es <<<"$1"
  for e in "${es[@]}"; do
    case "$e" in +*) c=$((c + ${e#+})) ;; ?*) c=$((c + 1)) ;; esac
  done
  printf '%s' "$c"
}

lpv_fit() {
  local s="${1:-}" max="${2:-4000}" f re l
  for f in own-files main-files; do
    [ "${#s}" -le "$max" ] && break
    re="(^|[ ;])$f:([^ ;]*)"
    [[ "$s" =~ $re ]] || continue
    l="${BASH_REMATCH[2]}"
    case "$l" in -|'?'|+*) continue ;; esac
    s="${s/ $f:$l/ $f:+$(_lpv_count "$l")}"
  done
  printf '%s' "$s"
}

# _lpv_list <csv> — one path per line from a token list; `-`, `?` and +<k> name nothing.
_lpv_list() {
  local e es
  IFS=, read -ra es <<<"$1"
  for e in "${es[@]}"; do
    case "$e" in -|'?'|+*|'') ;; *) printf '%s\n' "$e" ;; esac
  done
}

lpv_section() {
  local g="$1" main="$2" pr="$3" repo="$4" hs="$5" rdir="$6" withr="${7:-1}" d="" own mainl log k rep g12
  g12="${LPV_PREV:0:12}"
  printf 'This is a re-review. The lead reviewed this PR before at %s (%s) and answered %s.\n' "$g12" "$LPV_PREV" "$LPV_WORD"
  if d=$(lpv_delta_files "$g" "$main" "$LPV_PREV" "$hs"); then
    own=$(printf '%s\n' "$d" | awk -F'\t' '$1 == "own" {print $2}')
    mainl=$(printf '%s\n' "$d" | awk -F'\t' '$1 == "main" {print $2}')
  else
    d=""
    own=$(_lpv_list "$LPV_OWN"); mainl=$(_lpv_list "$LPV_MAIN")
  fi
  LPV_MAINF="$mainl"; LPV_OWNF="$own"
  printf '\nOwn commits since %s (main merges left out):\n' "$g12"
  if [ -n "$d" ] && git -C "$g" merge-base --is-ancestor "$LPV_PREV" "$hs" 2>/dev/null \
     && log=$(git -C "$g" log --no-merges --format='%h %s' "$hs" "^$LPV_PREV" "^$main" 2>/dev/null); then
    k=$(printf '%s\n' "$log" | awk 'NF' | wc -l | tr -d ' ')
    if [ "$k" = 0 ]; then printf '(none: only main merges since %s)\n' "$g12"
    else
      printf '%s\n' "$log" | awk 'NF' | head -n 50
      [ "$k" -gt 50 ] && printf '(+%s more)\n' "$((k - 50))"
    fi
  elif [ -n "$d" ]; then
    printf '(%s is not an ancestor of this head: the branch was rebased, so there is no own-commit list)\n' "$g12"
  else
    printf '(git on this box could not read %s; the request said own-commits:%s)\n' "$g12" "${LPV_OWNC:-?}"
  fi
  printf '\nOwn files changed since %s: %s\n' "$g12" "$(if [ -n "$own" ]; then printf '%s\n' "$own" | paste -sd, - | sed 's/,/, /g'; elif [ -n "$d" ]; then echo none; else echo "${LPV_OWN:-?}"; fi)"
  printf 'Main files the merge brought into files this PR touches: %s\n' "$(if [ -n "$mainl" ]; then printf '%s\n' "$mainl" | paste -sd, - | sed 's/,/, /g'; elif [ -n "$d" ]; then echo none; else echo "${LPV_MAIN:-?}"; fi)"
  case "$LPV_WORD" in
    MERGE|MERGE-WITH-NOTES)
      printf '\nThe rules in `## Re-review rules` apply: a finding on a line that did not change since %s is a [NOTE], unless it ends with `main-cause: <one of the main files above>` or `own-cause: <one of the own files above>`.\n' "$g12" ;;
  esac
  [ "$withr" = 1 ] || return 0
  rep="$rdir/lr-$pr-$g12.md"
  if [ -f "$rep" ] && [ "$(lr_report_title "$rep" 2>/dev/null)" = "# Lead review lr-$pr-$g12 ($repo#$pr at $LPV_PREV)" ]; then
    printf '\n### Prior lead report\n'
    cat "$rep"
  else
    printf '\n(the lead report for %s is not on this box)\n' "$g12"
  fi
  return 0
}

lpv_downgrade() {
  local g="$1" gs="$2" hs="$3" ans="$4" mf="${5:-}" of="${6:-}" k tmp
  [ -f "$ans" ] || return 1
  [ -n "$mf" ] && [ -f "$mf" ] || mf=/dev/null
  [ -n "$of" ] && [ -f "$of" ] || of=/dev/null
  gs=$(_lpv_sha "$g" "$gs") && hs=$(_lpv_sha "$g" "$hs") || return 2
  tmp="$ans.tmp.$$"
  git -C "$g" -c core.quotepath=off diff -U0 --no-renames --no-color "$gs" "$hs" > "$tmp.diff" 2>/dev/null || { rm -f "$tmp.diff"; return 2; }
  # The files of H: a finding path git does not hold at H is an unknown, never "unchanged".
  git -C "$g" -c core.quotepath=off ls-tree -r --name-only "$hs" > "$tmp.tree" 2>/dev/null || { rm -f "$tmp.diff" "$tmp.tree"; return 2; }
  k=$(awk -v g12="${gs:0:12}" -v out="$tmp" -v dfile="$tmp.diff" -v mfile="$mf" -v ofile="$of" -v tfile="$tmp.tree" '
    FILENAME == dfile {
      # renames off, so the line is "diff --git a/P b/P": P is half of what is left.
      if ($0 ~ /^diff --git a\//) { dg = substr($0, 14, (length($0) - 16) / 2); next }
      # A binary change has no hunks: every line of it counts as changed.
      if ($0 ~ /^Binary files /) { all[dg] = 1; next }
      if ($0 ~ /^--- /) { old = substr($0, 5); sub(/^a\//, "", old); next }
      if ($0 ~ /^\+\+\+ /) {
        cur = substr($0, 5)
        if (cur == "/dev/null") { cur = old; all[cur] = 1 } else sub(/^b\//, "", cur)
        next
      }
      if ($0 ~ /^@@ /) {
        split($0, f, " "); h = substr(f[3], 2); n = split(h, p, ",")
        c = p[1] + 0; d = (n > 1) ? p[2] + 0 : 1
        if (d == 0) { ch[cur, c] = 1; ch[cur, c + 1] = 1 }
        else for (i = c; i < c + d; i++) ch[cur, i] = 1
      }
      next
    }
    FILENAME == tfile { if ($0 != "") inh[$0] = 1; next }
    FILENAME == mfile { if ($0 != "") mainf[$0] = 1; next }
    FILENAME == ofile { if ($0 != "") ownf[$0] = 1; next }
    { line[++nl] = $0 }
    END {
      k = 0
      for (i = 1; i <= nl; i++) {
        s = line[i]
        if (s !~ /^- \[BLOCK\][[:space:]]/) continue
        r = s; sub(/^- \[BLOCK\][[:space:]]+`?/, "", r)
        if (!match(r, /^[A-Za-z0-9._\/@+-]+:[0-9]+(-[0-9]+)?/)) continue
        loc = substr(r, 1, RLENGTH); ci = match(loc, /:[0-9]+(-[0-9]+)?$/)
        path = substr(loc, 1, ci - 1); rg = substr(loc, ci + 1)
        a = rg + 0; b = a; if (rg ~ /-/) { split(rg, q, "-"); a = q[1] + 0; b = q[2] + 0 }
        if (b < a) continue
        if (!(path in inh)) continue
        if (path in all) continue
        changed = 0
        for (j = a; j <= b && j - a < 100000; j++) if ((path, j) in ch) { changed = 1; break }
        if (changed) continue
        if (match(s, /main-cause:[[:space:]]*`?[A-Za-z0-9._\/@+-]+/)) {
          mc = substr(s, RSTART, RLENGTH); sub(/^main-cause:[[:space:]]*`?/, "", mc); sub(/[.,;:]+$/, "", mc)
          if (mc in mainf) continue
        }
        if (match(s, /own-cause:[[:space:]]*`?[A-Za-z0-9._\/@+-]+/)) {
          oc = substr(s, RSTART, RLENGTH); sub(/^own-cause:[[:space:]]*`?/, "", oc); sub(/[.,;:]+$/, "", oc)
          if (oc in ownf) continue
        }
        sub(/^- \[BLOCK\]/, "- [NOTE unchanged-since " g12 "]", s); line[i] = s; k++
      }
      left = 0
      for (i = 1; i <= nl; i++) if (line[i] ~ /^- \[BLOCK/) left = 1
      if (k > 0 && !left) {
        for (i = nl; i >= 1; i--) if (line[i] ~ /^(\*\*)?VERDICT:(\*\*)?[[:space:]]/) { line[i] = "VERDICT: MERGE-WITH-NOTES"; break }
      }
      if (k > 0) for (i = 1; i <= nl; i++) print line[i] > out
      print k
    }' "$tmp.diff" "$tmp.tree" "$mf" "$of" "$ans") || { rm -f "$tmp" "$tmp.diff" "$tmp.tree"; return 2; }
  rm -f "$tmp.diff" "$tmp.tree"
  [[ "$k" =~ ^[0-9]+$ ]] || { rm -f "$tmp"; return 2; }
  if [ "$k" -gt 0 ]; then
    mv -f "$tmp" "$ans" || { rm -f "$tmp"; return 2; }
    printf '%s' "$k"; return 0
  fi
  rm -f "$tmp"; return 1
}

lpv_flip() {
  local v="${2:-}" a b
  lpv_parse "${1:-}" || return 2
  [ "$LPV_OWNC" = 0 ] || return 1
  case "$LPV_WORD" in BLOCK) a=B ;; *) a=M ;; esac
  case "$v" in BLOCK) b=B ;; MERGE|MERGE-WITH-NOTES) b=M ;; *) return 1 ;; esac
  [ "$a" != "$b" ] || return 1
  printf '%s %s own-commits:0' "${LPV_PREV:0:12}" "$LPV_WORD"
}
