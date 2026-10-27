#!/bin/bash
# bin/lib/ci-batch-escalate.sh — DOES THIS CHANGED PATH MAKE A MERGE-QUEUE BATCH
# RUN THE WHOLE CORPUS? (BH-4968) Sourced, never executed; no side effects at
# source time.
#
#   cbe_rules [root]    prints the composed rules (BH-8608): the env file
#                       CI_BATCH_ESCALATE_TSV when it is set, else
#                       <root>/catalog/ci-batch-escalate.tsv and then every
#                       <root>/catalog/ci-batch-escalate.d/*.tsv in LC_ALL=C
#                       name order. Root defaults to this lib's checkout. Each
#                       source ends with a newline. rc 1 when a source cannot
#                       be read; a missing folder is zero fragments.
#   cbe_rules_path <path>
#                       rc 0 when <path> is a rules source: the old file or a
#                       catalog/ci-batch-escalate.d/<name>.tsv one level down.
#   cbe_rules_diff <root> <base>
#                       the `git diff --no-renames -U0 <base> HEAD` of both
#                       sources in <root>, one diff, so a row moved between
#                       them is not a delete. rc is git's.
#   cbe_check [root]    the lint: one `ci-batch-escalate: <file>:<line>:
#                       <problem>` line per problem, rc 1 on any. A row has 3
#                       tab fields, a pattern, a known kind and a why; no
#                       (pattern, kind) is in two source files; the directory
#                       of the pattern's literal prefix exists; the folder
#                       holds only readable *.tsv files and README.md.
#   cbe_reason <path>   prints `selection input: <path>` and rc 0 when an
#                       escalate row matches and no allow row does; else prints
#                       nothing, rc 1
#   cbe_affects <spa|worker> <path>
#                       rc 0 when the path can change what the console-ui job
#                       (spa) or the worker-jobs job (worker) tests, rc 1 when
#                       it cannot (BH-4969). A path is affected when it is under
#                       the job's own tree (console-ui/, worker/ — built in, so
#                       deleting a row cannot un-gate the job) or a row of that
#                       kind matches. FAILS CLOSED: an unreadable rules file or
#                       an unknown kind answers rc 0.
#   cbe_add_only <diff-file>
#                       rc 0 when the `git diff -U0` output in <diff-file> (of
#                       the rules file) only ADDS rows (BH-6371): no removed
#                       line, at least one added row, and every added line is
#                       blank, a # comment, or `pattern<TAB>kind<TAB>why` with
#                       a non-empty pattern and kind escalate, spa or worker.
#                       Prints the added kinds, one per line, sorted and
#                       unique. Anything else is rc 1, an empty or missing
#                       file and a header line it does not know included.
#                       The header lines are diff --git, index, ---, +++,
#                       new/deleted file mode and old/new mode (BH-8608: an
#                       added or deleted fragment file).
#   cbe_infra <path>    rc 0 when an infra row matches and no allow row does
#                       (BH-7287): the batch runs the path's self and reads
#                       suites plus catalog/ci-infra-canary.txt, not the
#                       corpus. Silent. Reads the committed rules with no
#                       CI_FULL_TRIGGERS delta (the delta adds and removes
#                       escalate rows only). An unreadable rules file is rc 1
#                       here, because cbe_reason escalates every path on it
#                       and the callers ask cbe_reason first.
#   cbe_deletes_row <diff-file>
#                       rc 1 only when the `git diff -U0` output in
#                       <diff-file> (of the rules file) deletes no row
#                       (BH-7287): it is readable and non-empty, every line is
#                       one cbe_add_only understands, every added line is
#                       blank, a # comment, or `pattern<TAB>kind<TAB>why` with
#                       a non-empty pattern and a known kind, no added allow
#                       row is new (an allow row removes an escalation), and
#                       every removed row's `pattern<TAB>kind` key is added
#                       back. So a kind change is a delete, and a why edit, a
#                       comment edit or a moved row is not. Everything else is
#                       rc 0: treat it as a delete.
#   cbe_delta_norm <delta>
#                       the full-trigger delta (BH-6838), normalised: the kept
#                       tokens, first place kept, space-joined, or `-` for
#                       none. One stderr line per dropped token.
#   cbe_delta_apply <rules> <delta>
#                       prints <rules> with the delta applied, rc 1 when
#                       <rules> cannot be read. Silent: cbe_delta_norm says
#                       what it drops.
#
# THE FULL-TRIGGER DELTA (BH-6838) is CI_FULL_TRIGGERS: the settings row
# `CI_FULL_TRIGGERS` on the ci-plan-settings lane, projected into the repo
# variable of the same name by bin/ci-plan-settings.sh. Tokens are
# whitespace-separated. `+<pattern>` adds an escalate row; `-<pattern>` removes
# the escalate row with exactly that pattern. A token with no +/- sign, with
# `..`, or a `-` of a self row (_CBE_SELF: the files that decide what a batch
# runs) is dropped. Unset, empty or `-` is the committed file, byte for byte.
# cbe_reason reads the rules with the delta applied.
#
# The rules are catalog/ci-batch-escalate.tsv (see its header) plus the
# fragments in catalog/ci-batch-escalate.d/ (see its README), or
# CI_BATCH_ESCALATE_TSV; every reader reads them through cbe_rules. The kinds are escalate, infra (BH-7287), allow, spa
# and worker; cbe_reason reads escalate and allow only. FAILS CLOSED: rules that cannot be read (any source), or
# rules with no escalate row, answers `selection input: catalog/ci-batch-escalate.tsv
# unreadable` for every path, because an empty rule set must never mean
# "nothing escalates".
_CBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _cbe_match <path> <pattern> — a trailing / is a prefix, anything else a glob.
_cbe_match() {
  case "$2" in
    */) [[ $1 == "$2"* ]] ;;
    *)  # shellcheck disable=SC2053 # the pattern IS a glob
        [[ $1 == $2 ]] ;;
  esac
}

# _cbe_cat <file> — the file with a final newline, rc 1 when it is not a
# readable regular file.
_cbe_cat() { [ -f "$1" ] && [ -r "$1" ] && LC_ALL=C awk 1 "$1"; }

cbe_rules() {
  local root="${1:-$_CBE_DIR/../..}"
  if [ -n "${CI_BATCH_ESCALATE_TSV:-}" ]; then _cbe_cat "$CI_BATCH_ESCALATE_TSV"; return; fi
  _cbe_cat "$root/catalog/ci-batch-escalate.tsv" || return 1
  ( shopt -s nullglob; LC_ALL=C
    for f in "$root"/catalog/ci-batch-escalate.d/*.tsv; do _cbe_cat "$f" || exit 1; done )
}

cbe_rules_path() {
  case "$1" in
    catalog/ci-batch-escalate.tsv) return 0 ;;
    catalog/ci-batch-escalate.d/*/*) return 1 ;;
    catalog/ci-batch-escalate.d/?*.tsv) return 0 ;;
  esac
  return 1
}

cbe_rules_diff() {
  git -C "$1" diff --no-renames -U0 "$2" HEAD -- catalog/ci-batch-escalate.tsv ':(glob)catalog/ci-batch-escalate.d/*.tsv'
}

cbe_check() {
  local root="${1:-$_CBE_DIR/../..}" d f n srcs=() bad=0 tag file line dir
  d="$root/catalog/ci-batch-escalate.d"
  if [ -f "$root/catalog/ci-batch-escalate.tsv" ] && [ -r "$root/catalog/ci-batch-escalate.tsv" ]; then
    srcs+=("$root/catalog/ci-batch-escalate.tsv")
  else
    echo "ci-batch-escalate: catalog/ci-batch-escalate.tsv:0: not a readable file"; bad=1
  fi
  if [ -d "$d" ]; then
    while IFS= read -r f; do
      n="catalog/ci-batch-escalate.d/${f##*/}"
      case "${f##*/}" in
        README.md) [ -f "$f" ] || { echo "ci-batch-escalate: $n:0: README.md must be a file"; bad=1; } ;;
        ?*.tsv) if [ -f "$f" ] && [ -r "$f" ]; then srcs+=("$f")
                else echo "ci-batch-escalate: $n:0: not a readable file"; bad=1; fi ;;
        *) if [ -d "$f" ]; then echo "ci-batch-escalate: $n:0: a sub-folder; fragments are <name>.tsv one level down"
           else echo "ci-batch-escalate: $n:0: only <name>.tsv and README.md belong in the folder"; fi
           bad=1 ;;
      esac
    done < <(shopt -s nullglob dotglob; LC_ALL=C; for f in "$d"/*; do printf '%s\n' "$f"; done)
  fi
  [ "${#srcs[@]}" -gt 0 ] || return 1
  while IFS=$'\t' read -r tag file line dir; do
    case "$tag" in
      P) echo "ci-batch-escalate: $file:$line: $dir"; bad=1 ;;
      D) [ -d "$root/$dir" ] || { echo "ci-batch-escalate: $file:$line: no directory $dir for the pattern"; bad=1; } ;;
    esac
  done < <(LC_ALL=C awk -F'\t' -v root="$root/" '
    FNR == 1 { name = FILENAME; if (index(name, root) == 1) name = substr(name, length(root) + 1) }
    /^[ \t]*$/ || /^#/ { next }
    {
      if (NF < 3) { print "P\t" name "\t" FNR "\tfewer than 3 tab-separated fields"; next }
      if ($1 == "") { print "P\t" name "\t" FNR "\tan empty pattern"; next }
      if ($2 != "escalate" && $2 != "infra" && $2 != "allow" && $2 != "spa" && $2 != "worker") {
        print "P\t" name "\t" FNR "\tunknown kind " $2 " (escalate, infra, allow, spa or worker)"; next }
      if ($3 ~ /^[ \t]*$/) { print "P\t" name "\t" FNR "\tan empty why"; next }
      k = $1 "\t" $2
      if (!(k in at)) { at[k] = name ":" FNR; src[k] = name }
      else if (src[k] != name) print "P\t" name "\t" FNR "\tduplicate of " at[k] " (" $1 " " $2 ")"
      lit = $1; g = match(lit, /[*?[]/); if (g > 0) lit = substr(lit, 1, g - 1)
      dir = lit; if (g > 0 || lit !~ /\/$/) sub(/[^\/]*$/, "", dir)
      if (dir == "") dir = "."
      print "D\t" name "\t" FNR "\t" dir
    }' "${srcs[@]}")
  [ "$bad" = 0 ]
}

# The self rows: a delta can never remove these (BH-6838). The two runner rows
# (tests/lib/scratch.sh, bin/lib/suite-runner.sh) are here because the plan
# keeps them: removing one lets a runner change land untested.
_CBE_SELF=' .github/ bin/ci-plan.sh bin/test-impact*.sh catalog/ci-batch-escalate.tsv catalog/ci-batch-escalate.d/ bin/lib/ci-batch-escalate.sh catalog/ci-batch-regression.d/ tests/lib/scratch.sh bin/lib/suite-runner.sh '

# _cbe_delta_tokens <delta> — `<token>\t<why>` per token, why `ok` or the drop reason.
_cbe_delta_tokens() {
  local t seen=' ' toks=()
  read -r -d '' -a toks <<<"${1:-}" || true
  for t in ${toks[@]+"${toks[@]}"}; do
    case "$t" in
      -) continue ;;
      *..*) printf '%s\tignored (..)\n' "$t"; continue ;;
      [+-]) printf '%s\tignored (no pattern)\n' "$t"; continue ;;
      +*) ;;
      -*) case "$_CBE_SELF" in *" ${t#-} "*) printf '%s\trefused (a self row)\n' "$t"; continue ;; esac ;;
      *) printf '%s\tignored (no + or - sign)\n' "$t"; continue ;;
    esac
    case "$seen" in *" $t "*) continue ;; esac
    seen="$seen$t "
    printf '%s\tok\n' "$t"
  done
}

cbe_delta_norm() {
  local t why out=""
  while IFS=$'\t' read -r t why; do
    [ -n "$t" ] || continue
    if [ "$why" = ok ]; then out="$out${out:+ }$t"
    else echo "ci-batch-escalate: CI_FULL_TRIGGERS token $t $why" >&2; fi
  done < <(_cbe_delta_tokens "${1:-}")
  printf '%s\n' "${out:--}"
}

cbe_delta_apply() {
  local rules="$1" delta="${2:-}" t why add="" del=" "
  [ -r "$rules" ] || return 1
  while IFS=$'\t' read -r t why; do
    [ "$why" = ok ] || continue
    case "$t" in +*) add="$add${t#+}"$'\n' ;; -*) del="$del${t#-} " ;; esac
  done < <(_cbe_delta_tokens "$delta")
  if [ -z "$add" ] && [ "$del" = " " ]; then cat "$rules"; return; fi
  LC_ALL=C awk -F'\t' -v del="$del" '$2 == "escalate" && index(del, " " $1 " ") > 0 { next } { print }' "$rules" || return 1
  printf '%s' "$add" | while IFS= read -r t; do
    [ -n "$t" ] && printf '%s\tescalate\tCI_FULL_TRIGGERS (the ci-plan-settings row, BH-6838)\n' "$t"
  done
}

cbe_reason() {
  local p="$1" rules pat kind _why rows=0 esc=0 allow=0
  if rules=$(cbe_rules); then
    while IFS=$'\t' read -r pat kind _why; do
      case "$pat" in ''|'#'*) continue ;; esac
      case "$kind" in
        escalate) rows=$((rows + 1)); _cbe_match "$p" "$pat" && esc=1 ;;
        allow)    _cbe_match "$p" "$pat" && allow=1 ;;
      esac
    done < <(cbe_delta_apply <(printf '%s\n' "$rules") "${CI_FULL_TRIGGERS:-}")
  fi
  if [ "$rows" -eq 0 ]; then
    echo "selection input: catalog/ci-batch-escalate.tsv unreadable"; return 0
  fi
  [ "$esc" = 1 ] && [ "$allow" = 0 ] || return 1
  echo "selection input: $p"
}

cbe_affects() {
  local k="$1" p="$2" rules pat kind _why
  case "$k" in
    spa)    _cbe_match "$p" console-ui/ && return 0 ;;
    worker) _cbe_match "$p" worker/ && return 0 ;;
    *)      return 0 ;;
  esac
  rules=$(cbe_rules) || return 0
  while IFS=$'\t' read -r pat kind _why; do
    case "$pat" in ''|'#'*) continue ;; esac
    [ "$kind" = "$k" ] && _cbe_match "$p" "$pat" && return 0
  done <<<"$rules"
  return 1
}

cbe_add_only() {
  [ -s "${1:-}" ] && [ -r "$1" ] || return 1
  local kinds
  kinds=$(LC_ALL=C awk '
    /^diff --git / { hunk = 0; next }
    !hunk && (/^index / || /^--- / || /^\+\+\+ / || /^(new|deleted) file mode / || /^(old|new) mode /) { next }
    /^@@ / { hunk = 1; next }
    !hunk { bad = 1; exit }
    /^\\ / { next }
    /^ / { next }
    /^-/ { bad = 1; exit }
    /^\+/ { l = substr($0, 2)
            if (l ~ /^[ \t]*$/ || l ~ /^#/) next
            n = split(l, f, "\t")
            if (n < 3 || f[1] == "" || (f[2] != "escalate" && f[2] != "spa" && f[2] != "worker")) { bad = 1; exit }
            rows++; print f[2]; next }
    { bad = 1; exit }
    END { exit((bad || rows == 0) ? 1 : 0) }
  ' "$1") || return 1
  printf '%s\n' "$kinds" | LC_ALL=C sort -u
}

cbe_infra() {
  local p="$1" rules pat kind _why inf=0
  rules=$(cbe_rules) || return 1
  while IFS=$'\t' read -r pat kind _why; do
    case "$pat" in ''|'#'*) continue ;; esac
    case "$kind" in
      infra) _cbe_match "$p" "$pat" && inf=1 ;;
      allow) _cbe_match "$p" "$pat" && return 1 ;;
    esac
  done <<<"$rules"
  [ "$inf" = 1 ]
}

cbe_deletes_row() {
  [ -s "${1:-}" ] && [ -r "$1" ] || return 0
  LC_ALL=C awk '
    /^diff --git / { hunk = 0; next }
    !hunk && (/^index / || /^--- / || /^\+\+\+ / || /^(new|deleted) file mode / || /^(old|new) mode /) { next }
    /^@@ / { hunk = 1; next }
    !hunk { bad = 1; exit }
    /^\\ / { next }
    /^ / { next }
    /^[-+]/ { sign = substr($0, 1, 1); l = substr($0, 2); changed++
              if (l ~ /^[ \t]*$/ || l ~ /^#/) next
              n = split(l, f, "\t")
              if (sign == "-") { if (n >= 2) del[f[1] "\t" f[2]] = 1; else bad = 1; next }
              if (n < 3 || f[1] == "" || (f[2] != "escalate" && f[2] != "infra" && f[2] != "spa" && f[2] != "worker" && f[2] != "allow")) { bad = 1; exit }
              add[f[1] "\t" f[2]] = 1; next }
    { bad = 1; exit }
    END {
      if (bad || changed == 0) exit 0
      for (k in add) if (k ~ /\tallow$/ && !(k in del)) exit 0
      for (k in del) if (!(k in add)) exit 0
      exit 1
    }
  ' "$1"
}
