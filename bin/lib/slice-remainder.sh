#!/bin/bash
# bin/lib/slice-remainder.sh — file the rest of a sliced issue when one slice
# merges (BH-5961). A plan that says `SLICE: C<k> of #N` builds one slice and
# names the others (C<k+1>..C<m>) as list items. When that merge finds no open
# child issue, the close-out used to post "No child issue carries the rest yet"
# and stop, so the parent stalled. This reads the remainder from the build
# record's plan.md and files one child issue per slice through the existing
# GitHub-Issues filer (fc_file_issues, kind `slice`), which also comments on the
# parent and takes `ai-build` off it. bin/decompose-parent-close.sh closes the
# parent once every `Part of #N` child has merged.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time. Safe under `set -u`. The root is ${HARNESS:-${H:-}} or the caller's
# argument, never a literal.
#
#   slice_remainder_parse <plan.md> <parent-n> <out.json> [pr-url]
#       -> ok:<m> rc 0 (out.json written) | none rc 2 | bad:<why> rc 2
#   slice_remainder_settle <repo-slug> <n> <pr-url> <record-dir> [harness]
#       -> remainder-filed:#a,#b rc 0 | remainder-deferred:<why> rc 1
#        | remainder-unknown:<why> rc 2 (paged) | remainder-skip:<why> rc 3
#
# Operator notes (the four words, the record files, the switch) are in
# docs/verification-map/slice-remainder.md.

_slr_dir() { dirname "${BASH_SOURCE[0]}"; }

# _slr_env <harness> <VAR> <default> — issue-state-lib's reader when it is
# loaded (env, then env/global.env, then the default), else env then default.
_slr_env() {
  if command -v _issue_env >/dev/null 2>&1; then _issue_env "$@"; return 0; fi
  local v; eval "v=\${$2:-}"; printf '%s\n' "${v:-$3}"
}

# The exclusion labels (BH-8329). A heading, a coverage-matrix Requirement cell
# or a sub-heading whose text IS one of them, or starts with one followed by
# `:`, `(` or a dash, names work the ticket rules out, never remaining work.
# Fallback of the settings row lib.slice-closeout.slice_closeout_exclude_headings
# (BH-8329); the knob is catalog/lanes.d/_lib.slice-closeout.knobs.d/SLICE_CLOSEOUT_EXCLUDE_HEADINGS.json.
_SLR_EXCLUDE_DEFAULT="out of scope|non-goals|non-goal|not in scope|excluded|won't do"

# slr_exclude_headings — the |-separated exclusion list: the knob through
# sco_knob when slice-closeout.sh is loaded, else the env, else the fallback
# above. `none` prints an empty line (exclusion off).
slr_exclude_headings() {
  local v
  if command -v sco_knob >/dev/null 2>&1; then v=$(sco_knob SLICE_CLOSEOUT_EXCLUDE_HEADINGS)
  else v="${SLICE_CLOSEOUT_EXCLUDE_HEADINGS:-}"; fi
  [ -n "${v//[[:space:]]/}" ] || v="$_SLR_EXCLUDE_DEFAULT"
  case "$(printf '%s' "$v" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in none) v="" ;; esac
  printf '%s\n' "$v"
}

# _SLR_EXCL_AWK — the awk functions both libs prepend to their program, so the
# rule is one text. exinit() reads -v EX; isexcl(s) is 1 when s is an
# exclusion. xnorm: lower case, no `*_ emphasis, no ' or U+2019, " - " to an
# em dash, other hyphens to spaces, spaces collapsed, trimmed. A match is the
# whole text, or the label then (after one optional space) `:`, `(`, an em dash
# or an en dash. A label then a word ("Excluded tenants see nothing") is not.
# mawk-safe, and index() rather than byte counts so a UTF-8 gawk agrees.
# shellcheck disable=SC2016 # awk text, not shell
_SLR_EXCL_AWK='
    function xnorm(s) {
      s = tolower(s); gsub(/[`*_]/, "", s); gsub(/\047/, "", s); gsub(/\342\200\231/, "", s)
      gsub(/ - /, " \342\200\224 ", s); gsub(/-/, " ", s); gsub(/[ \t]+/, " ", s)
      sub(/^ /, "", s); sub(/ $/, "", s); return s
    }
    function exinit(   a, i, n, e) {
      NEX = 0; n = split(EX, a, "|")
      for (i = 1; i <= n; i++) { e = xnorm(a[i]); if (e != "") EXL[++NEX] = e }
    }
    function isexcl(s,   i, e, r) {
      if (NEX == 0) return 0
      s = xnorm(s)
      for (i = 1; i <= NEX; i++) {
        e = EXL[i]
        if (s == e) return 1
        if (index(s, e) != 1) continue
        r = substr(s, length(e) + 1); sub(/^ /, "", r)
        if (index(r, ":") == 1 || index(r, "(") == 1 || index(r, "\342\200\224") == 1 || index(r, "\342\200\223") == 1) return 1
      }
      return 0
    }
'

# _slr_scan <plan.md> <parent-n> [exclusions] — ONE awk pass, mawk-safe (no match() arrays,
# no gensub, no interval expressions, no POSIX classes). Tab-separated records:
#   K <k>              the merged slice, from the first SLICE line for #n
#   I <j> <text>       a remainder item C<j>, j > k, first line
#   P <j> <text>       the item's parenthesis, read for blockers only
#   C <j> <text>       a continuation line of item j
#   B <j> <i>          item j names `after C<i>` (or blocked by / depends on / needs)
#   T <j> <text>       an acceptance test tagged for slice j
# A level 2+ heading that is an exclusion (isexcl, BH-8329; the list is the
# third argument, default slr_exclude_headings) hides its items like the
# acceptance and test sections do.
_slr_scan() {
  local ex
  if [ "$#" -ge 3 ]; then ex="$3"; else ex=$(slr_exclude_headings); fi
  awk -v N="$2" -v EX="$ex" "$_SLR_EXCL_AWK"'
    function lead(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function clean(s) { gsub(/\t/, " ", s); gsub(/\*\*/, "", s); return trim(s) }
    # cnums(s) -> the distinct C<digits> tokens with a non-alphanumeric left
    # edge, space-joined; the count is in CN.
    function cnums(s,   out, t, pre) {
      out = ""; CN = 0
      while (match(s, /C[0-9]+/)) {
        pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        t = substr(s, RSTART + 1, RLENGTH - 1) + 0
        if (pre !~ /[A-Za-z0-9_]/ && index(" " out " ", " " t " ") == 0) { out = out (out == "" ? "" : " ") t; CN++ }
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    function blockers(j, s,   t, d) {
      s = tolower(s)
      while (match(s, /(after|blocked by|blocked-by:|depends on|needs) c[0-9]+/)) {
        t = substr(s, RSTART, RLENGTH)
        d = t; sub(/^.* c/, "", d)
        printf "B\t%d\t%d\n", j, d + 0
        s = substr(s, RSTART + RLENGTH)
      }
    }
    BEGIN { k = -1; fch = ""; flen = 0; cur = -1; excl = 0; acc = 0; subj = -1; exinit() }
    { sub(/\r$/, "") }
    # The merged slice: the guard regex of issue_close_guard, on any line.
    k < 0 && ($0 ~ ("^[ \t*_>]*SLICE:[ \t*_]*C[0-9]+[ \t]+of[ \t]+#" N "([^0-9]|$)") || $0 ~ /^[ \t*_>]*The build for THIS ticket is C[0-9]+/) {
      s = $0
      if (match(s, /SLICE:[ \t*_]*C[0-9]+/)) { s = substr(s, RSTART, RLENGTH); sub(/^.*C/, "", s) }
      else { match(s, /is C[0-9]+/); s = substr(s, RSTART + 4, RLENGTH - 4) }
      k = s + 0; printf "K\t%d\n", k
    }
    # Fences: a run of 3+ backticks or tildes opens; the same character at a
    # length >= the opening one, and nothing after it, closes. Unterminated
    # hides the rest of the file.
    {
      t = $0; sub(/^[ \t]+/, "", t)
      if (fch != "") {
        if (lead(t, fch) >= flen && trim(substr(t, lead(t, fch) + 1)) == "") fch = ""
        cur = -1; next
      }
      if (lead(t, "`") >= 3) { fch = "`"; flen = lead(t, "`"); cur = -1; next }
      if (lead(t, "~") >= 3) { fch = "~"; flen = lead(t, "~"); cur = -1; next }
    }
    /^ ? ? ?>/ { cur = -1; next }
    /^#+ / {
      lvl = lead($0, "#"); h = tolower($0); cur = -1
      if (excl && lvl <= exlvl) excl = 0
      if (acc && lvl <= aclvl) { acc = 0; subj = -1 }
      if (acc && lvl > aclvl) {
        cs = cnums($0); subj = (CN == 1) ? cs + 0 : -1
      }
      # An H1 is the document title, never a section: "# BH-3690 Post-merge
      # live verification contract" must not hide the whole plan.
      if (lvl < 2) next
      if (!excl && h ~ /acceptance|requirement|verification|reproduction|test|qa|regression|size|invariant|sibling/) { excl = 1; exlvl = lvl }
      if (!excl) { ht = $0; sub(/^#+[ \t]+/, "", ht); if (isexcl(ht)) { excl = 1; exlvl = lvl } }
      if (!acc && h ~ /acceptance/) { acc = 1; aclvl = lvl; subj = -1 }
      next
    }
    /^[ \t]*$/ { cur = -1; next }
    /^ ? ? ?[-*+] +/ {
      cur = -1
      rest = $0; sub(/^ ? ? ?[-*+] +/, "", rest)
      if (acc) {
        tj = -1
        if (match(rest, /[\[(]C[0-9]+[\])]/)) tj = substr(rest, RSTART + 2, RLENGTH - 3) + 0
        else if (subj >= 0) tj = subj
        if (tj > k && k >= 0) printf "T\t%d\t%s\n", tj, clean(rest)
      }
      if (excl || k < 0) next
      r = rest
      if (substr(r, 1, 2) == "**") r = substr(r, 3)
      if (!match(r, /^C[0-9]+/)) next
      j = substr(r, 2, RLENGTH - 1) + 0
      r = substr(r, RLENGTH + 1)
      # A range or a list is not one slice.
      if (r ~ /^(\342\200\223|\342\200\224|-|\/|,)/ || r ~ /^(\*\*)?[ \t]+(and|to)[ \t]+C[0-9]/) next
      paren = ""
      if (substr(r, 1, 2) == " (" && index(r, ")") > 0) { paren = substr(r, 3, index(r, ")") - 3); r = substr(r, index(r, ")") + 1) }
      if (substr(r, 1, 2) == "**") r = substr(r, 3)
      if (substr(r, 1, 1) == ":") r = substr(r, 2)
      else if (r != "" && r !~ /^[ \t]/) next
      if (j <= k) next
      printf "I\t%d\t%s\n", j, clean(r)
      if (paren != "") printf "P\t%d\t%s\n", j, clean(paren)
      blockers(j, paren " " r)
      cur = j; next
    }
    # A continuation: indented 2+ spaces, under a live item.
    cur >= 0 && /^  / { printf "C\t%d\t%s\n", cur, clean($0); blockers(cur, $0); next }
    { cur = -1 }
  ' "$1"
}

# _slr_title <text> — up to the first `. ` or `: `, cut at a word boundary to
# 80 characters, with a trailing `.` removed. A cut that leaves a `(` open
# drops it and what follows, then any trailing `,;+-`, so a title never ends
# mid-parenthesis.
_slr_title() {
  local s="${1:-}" c o x
  s="${s%%. *}"; s="${s%%: *}"
  if [ "${#s}" -gt 80 ]; then
    c="${s:0:81}"
    if [ "${c:80:1}" = " " ]; then s="${c:0:80}"
    else c="${c:0:80}"; [[ "$c" == *" "* ]] && s="${c% *}" || s="$c"; fi
    o="${s//[^(]/}"; x="${s//[^)]/}"
    if [ "${#o}" -gt "${#x}" ] && [[ "$s" == *" ("* ]]; then s="${s% (*}"; fi
    while [[ "$s" == *[[:space:],\;+-] ]]; do s="${s%?}"; done
  fi
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%.}"
  printf '%s' "$s"
}

slice_remainder_parse() {
  local plan="${1:-}" n="${2:-}" out="${3:-}" pr="${4:-}" h="${HARNESS:-${H:-}}"
  local recs k js j prev="" cnt max i ti tsv="" title text tests after where
  case "$n" in ''|*[!0-9]*) printf 'bad:no-slice-line\n'; return 2 ;; esac
  [ -r "$plan" ] && [ -n "$out" ] || { printf 'bad:no-slice-line\n'; return 2; }
  command -v jq >/dev/null 2>&1 || { printf 'bad:no-jq\n'; return 2; }
  recs=$(_slr_scan "$plan" "$n") || { printf 'bad:scan\n'; return 2; }
  k=$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "K" { print $2; exit }')
  [ -n "$k" ] || { printf 'bad:no-slice-line\n'; return 2; }
  js=$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "I" { print $2 }')
  [ -n "$js" ] || { printf 'none\n'; return 2; }
  # Set validation: unique, contiguous from k+1, inside the cap.
  cnt=0; prev="$k"
  for j in $(printf '%s\n' "$js" | sort -n); do
    [ "$j" = "$prev" ] && [ "$cnt" -gt 0 ] && { printf 'bad:duplicate:C%s\n' "$j"; return 2; }
    [ "$j" = $((prev + 1)) ] || { printf 'bad:gap:C%s\n' "$j"; return 2; }
    prev="$j"; cnt=$((cnt + 1))
  done
  max=$(_slr_env "$h" SLICE_REMAINDER_MAX 6)
  case "$max" in ''|*[!0-9]*|0) max=6 ;; esac
  [ "$cnt" -le "$max" ] || { printf 'bad:too-many:%s\n' "$cnt"; return 2; }
  where="the merged pull request${pr:+ $pr}"
  i=$((k + 1))
  while [ "$i" -le "$prev" ]; do
    text=$(printf '%s\n' "$recs" | awk -F'\t' -v j="$i" '($1 == "I" || $1 == "C") && $2 == j { print $3 }')
    title=$(_slr_title "$(head -1 <<<"$text")")
    [ -n "$title" ] || { printf 'bad:empty:C%s\n' "$i"; return 2; }
    tests=$(printf '%s\n' "$recs" | awk -F'\t' -v j="$i" '$1 == "T" && $2 == j { print "- " $3 }')
    [ -n "$tests" ] || tests="None were named for this slice. Its own plan writes them."
    # Blockers inside the remainder become 1-based positions; an earlier,
    # merged slice or a later one is dropped and said so on stderr.
    after=""
    for ti in $(printf '%s\n' "$recs" | awk -F'\t' -v j="$i" '$1 == "B" && $2 == j { print $3 }'); do
      if [ "$ti" -gt "$k" ] && [ "$ti" -lt "$i" ]; then
        case " $after " in *" $((ti - k)) "*) ;; *) after="${after:+$after }$((ti - k))" ;; esac
      else
        printf 'slice-remainder: C%s: dropped "after C%s" (only a slice between C%s and C%s can block it)\n' "$i" "$ti" "$((k + 1))" "$((i - 1))" >&2
      fi
    done
    tsv="$tsv$(jq -nc --argjson o "$i" --arg t "$title" --arg after "$after" \
      --arg b "Remaining slice C$i of #$n, as the plan of $where wrote it:

$text

Acceptance tests the plan named for this slice:
$tests" \
      '{ordinal: $o, title: $t, body: $b, after: ($after | split(" ") | map(select(. != "") | tonumber))}')"$'\n'
    i=$((i + 1))
  done
  printf '%s' "$tsv" | jq -s '.' > "$out" 2>/dev/null || { printf 'bad:json\n'; return 2; }
  printf 'ok:%s\n' "$cnt"
  return 0
}

# _slr_alert <harness> <id> <msg> — one critical page through bin/lane-alert.sh.
_slr_alert() {
  if [ -n "$1" ] && [ -x "$1/bin/lane-alert.sh" ]; then
    "$1/bin/lane-alert.sh" --severity critical --id "$2" slice-closeout "$3" >/dev/null 2>&1 || true
  else
    echo "slice-remainder: $3 (no bin/lane-alert.sh to page with)" >&2
  fi
}

slice_remainder_settle() {
  local slug="${1:-}" n="${2:-}" pr="${3:-}" rec="${4:-}" h="${5:-${HARNESS:-${H:-}}}" d rc=0
  # Optional (BH-6308): a plan read from elsewhere than <record>/plan.md (a
  # remote build's merged spec), and the key and project when the record name
  # does not carry them. Five args behave exactly as before.
  local plan="${6:-${4:-}/plan.md}"
  local _SLR_KEY="${7:-}" _SLR_PROJECT="${8:-}" _SLR_PLAN="$plan"
  # The switch: lane_switch slice-remainder-off (a settings row, else
  # flags/slice-remainder-off), or SLICE_REMAINDER_FILE=0 (env or
  # env/global.env). Default on.
  # shellcheck source=bin/lib/lane-switch.sh
  command -v lane_switch >/dev/null 2>&1 || . "$(_slr_dir)/lane-switch.sh" 2>/dev/null
  if [ -n "$h" ] && command -v lane_switch >/dev/null 2>&1 && HARNESS="$h" lane_switch slice-remainder-off file; then
    printf 'remainder-skip:off\n'; return 3
  fi
  case "$(_slr_env "$h" SLICE_REMAINDER_FILE 1)" in 0|no|off|false) printf 'remainder-skip:off\n'; return 3 ;; esac
  [ -n "$rec" ] && [ -d "$rec" ] || { printf 'remainder-skip:no-record\n'; return 3; }
  [ -r "$plan" ] || { printf 'remainder-skip:no-plan\n'; return 3; }
  d="$rec/slice-remainder"
  mkdir -p "$d" 2>/dev/null || { printf 'remainder-deferred:record-write\n'; return 1; }
  # A DEDUPE, not a queue: a second lane on the same record skips and is
  # re-offered next tick. Held only for the length of this call.
  if command -v flock >/dev/null 2>&1; then
    _slr_settle_locked "$slug" "$n" "$pr" "$rec" "$h" "$d" 9>"$d/.lock" || rc=$?
  else
    _slr_settle_locked "$slug" "$n" "$pr" "$rec" "$h" "$d" || rc=$?
  fi
  return "$rc"
}

_slr_settle_locked() {
  local slug="$1" n="$2" pr="$3" rec="$4" h="$5" d="$6" out st key base project prn w why
  local lib frc=0 want got nums
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { printf 'remainder-deferred:locked\n'; return 1; }
  fi
  # LEDGER FIRST: the second merge event is answered before any read or write,
  # even while the timeline does not yet show the children.
  if [ -s "$d/filed" ]; then printf 'remainder-filed:%s\n' "$(head -1 "$d/filed")"; return 0; fi
  # An unknown is terminal for the record: it paged once and stays paged.
  if [ -e "$d/unknown-paged" ]; then printf 'remainder-unknown:%s\n' "$(head -1 "$d/unknown-paged")"; return 2; fi
  out=$(_issue_arm "$slug" 2>/dev/null; gh_rest GET "repos/$slug/issues/$n" 2>/dev/null) || { printf 'remainder-deferred:parent-read\n'; return 1; }
  st=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)
  [ -n "$st" ] || { printf 'remainder-deferred:parent-read\n'; return 1; }
  [ "$st" = open ] || { printf 'remainder-skip:parent-closed\n'; return 3; }
  # bin/run-build.sh names a record <project>-<KEY>-<12-digit stamp>.
  if [ -n "${_SLR_KEY:-}" ]; then
    key="$_SLR_KEY"; project="${_SLR_PROJECT:-}"
  else
    base=$(basename "$rec")
    [[ "$base" =~ -([A-Za-z][A-Za-z0-9]*-$n)-[0-9]{12}$ ]] || { printf 'remainder-skip:no-key\n'; return 3; }
    key="${BASH_REMATCH[1]}"
    project="${base%-"$key"-*}"; project="${project#pool-}"
  fi
  prn="${pr##*/pull/}"; prn="${prn%%/*}"
  # The spec is decided once per record: a plan edited later never yields a
  # second, different set of children.
  if [ ! -s "$d/children.json" ]; then
    w=$(slice_remainder_parse "${_SLR_PLAN:-$rec/plan.md}" "$n" "$d/children.json.tmp" "$pr" 2>>"$d/parse.log")
    if [ "${w%%:*}" = ok ]; then
      mv -f "$d/children.json.tmp" "$d/children.json"
    else
      rm -f "$d/children.json.tmp"
      why="${w:-bad:parse}"
      # The page goes BEFORE the marker: a crash between them pages twice, and
      # the --id collapses that. It is never silent.
      _slr_alert "$h" "slice-remainder-unknown:$slug#$n:$prn" \
        "SLICE_REMAINDER_UNKNOWN issue $slug#$n: PR $pr merged a slice but the plan names no remainder it can file ($why); file the rest as child issues by hand"
      printf '%s\n' "$why" > "$d/unknown-paged"
      printf 'remainder-unknown:%s\n' "$why"; return 2
    fi
  fi
  lib=$(_slr_dir)
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-issues.sh" ] || lib="$h/bin/lib"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-issues.sh" ] || { printf 'remainder-skip:no-filer\n'; return 3; }
  [ -s "$rec/ticket-meta.json" ] && [ ! -e "$d/ticket-meta.json" ] && cp "$rec/ticket-meta.json" "$d/ticket-meta.json" 2>/dev/null
  # A SUBSHELL: the filer exports GH_TOKEN and sources its own libs, and none
  # of that may leak into the lane that called this.
  (
    # shellcheck source=bin/lib/file-children.sh
    . "$lib/file-children.sh" || exit 1
    # shellcheck source=bin/lib/fc-issues.sh
    . "$lib/fc-issues.sh" || exit 1
    HARNESS="$h" GH_ISSUES_REPO="$slug" FC_PROJECT="$project" FC_PARENT="$n" FC_KEY="$key" \
      FC_BUILD="$d" FC_SPEC="$d/children.json" FC_KIND=slice FC_LANE=issues \
      FC_SLICE_BASE="$(( $(jq '.[0].ordinal' "$d/children.json") - 1 ))" FC_SLICE_PR="$prn"
    export FC_SLICE_BASE FC_SLICE_PR
    fc_file_issues || { printf '%s\n' "${FC_ERROR:-fc_file_issues failed}" > "$d/fc-error.txt"; exit 1; }
    fc_dry && exit 10
    exit 0
  ) >>"$d/fc-out.txt" 2>&1 || frc=$?
  [ "$frc" = 10 ] && { printf 'remainder-skip:dry-run\n'; return 3; }
  want=$(jq 'length' "$d/children.json" 2>/dev/null)
  got=$(grep -cE '^[A-Za-z]+-[0-9]+$' "$d/children.txt" 2>/dev/null)
  if [ "$frc" = 0 ] && [ -n "$want" ] && [ "${got:-0}" = "$want" ]; then
    nums=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/#\1/p' "$d/children.txt" | paste -sd, -)
    printf '%s\n' "$nums" > "$d/filed"
    printf 'remainder-filed:%s\n' "$nums"; return 0
  fi
  [ -s "$d/fc-error.txt" ] || printf 'the filer filed %s of %s children (rc %s)\n' "${got:-0}" "${want:-?}" "$frc" > "$d/fc-error.txt"
  _slr_alert "$h" "slice-remainder-failed:$slug#$n:$prn" \
    "slice-remainder-failed issue $slug#$n: filing the remaining slices of PR $pr did not finish ($(head -c 300 "$d/fc-error.txt")); the next close-out tick resumes from $d"
  printf 'remainder-deferred:file-failed\n'
  return 1
}
