#!/bin/bash
# bin/lib/plan-collisions.sh — the design-collision check at PLAN. Sourced,
# never executed. bin/plan-collisions.sh is the CLI, the `design collisions`
# block in bin/lib/rb/plan.sh runs it after the plan gate, and
# bin/lib/caller-check.sh reuses pc_symbols and pc_locate.
#
# WHY. Plans changed functions that another ticket changed after the plan's
# base, and the two designs met in review or in the merge: #4332 and #5163 both
# rewrote flag_active and flag_set, and that cost a rebuild and a decision from
# the operator. So the plan lists what it changes under `## Changed symbols`, and this
# asks git which commits touched each symbol since the plan's base: on main
# (base..origin/<base>) and in every open PR (merge-base..PR head). A hit the
# plan does not resolve under `## Design collisions` gets one repair pass in
# the rb block, then the plan stops as PLAN_BLOCKED.
#
# AN UNREAD ANSWER IS NEVER "NONE". A missing base object is `MAIN: unread`, a
# PR list that answers 44/75 is `OPEN_PRS: unread`; both are written as such in
# the note and neither refuses a plan (the #768 lesson).
#
# THE NOTE CARRIES NO PATH. bin/planned-files.sh turns any path in plan.md into
# this build's file claim, so the generated note names symbols, shas and PR
# numbers only, never a file or a branch. It also has no VALIDATE/SATISFIES
# line, so bin/plan-gate.sh scores the plan the same with or without it.
#
# Formats, knobs and verdicts: docs/notes/2026-10-10-BH-5791-design-collisions.md.
# No `set -e`, no `exit`, no side effect at source time. mawk-safe awk only.
# shellcheck shell=bash
if [ -n "${PLAN_COLLISIONS_LIB:-}" ]; then return 0 2>/dev/null; fi
PLAN_COLLISIONS_LIB=1

PC_ENFORCE=1; PC_MAX_PRS=100; PC_MAX_SYMBOLS=40; PC_CONF_WARN=""; PC_WHY=""; PC_PR_N=0
PC_GLOBS_SH=('*.sh')
PC_GLOBS_JS=('*.js' '*.mjs' '*.ts')

# pc_conf [project] — PC_ENFORCE, PC_MAX_PRS, PC_MAX_SYMBOLS from the knob rows
# (lib_env_apply design-collisions), else the env, else the code defaults.
# PC_CONF_WARN is one line for ALERTS when a value is not one the code reads.
pc_conf() {
  local p="${1:-}" root v
  root="${HARNESS:-${H:-}}"
  PC_CONF_WARN=""
  if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/lib/lane-gate.sh" 2>/dev/null || true
  fi
  if command -v lib_env_apply >/dev/null 2>&1; then lib_env_apply design-collisions "$p" >/dev/null 2>&1 || true; fi
  case "$(printf '%s' "${PLAN_COLLISION_ENFORCE:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) PC_ENFORCE=0 ;;
    1|''|true|yes|on) PC_ENFORCE=1 ;;
    *) PC_ENFORCE=1
       PC_CONF_WARN="PLAN_COLLISION_ENFORCE='${PLAN_COLLISION_ENFORCE:-}' is not a recognized on/off value — treating as ON (an unresolved design collision refuses the plan)" ;;
  esac
  v="${PLAN_COLLISION_MAX_PRS:-100}"
  case "$v" in
    ''|*[!0-9]*) PC_CONF_WARN="${PC_CONF_WARN:+$PC_CONF_WARN; }PLAN_COLLISION_MAX_PRS='$v' is not a whole number — using 100"; v=100 ;;
  esac
  PC_MAX_PRS=$((10#$v))
  v="${PLAN_COLLISION_MAX_SYMBOLS:-40}"
  case "$v" in
    ''|*[!0-9]*|0) PC_CONF_WARN="${PC_CONF_WARN:+$PC_CONF_WARN; }PLAN_COLLISION_MAX_SYMBOLS='$v' is not a whole number above 0 — using 40"; v=40 ;;
  esac
  PC_MAX_SYMBOLS=$((10#$v))
  return 0
}

# pc_plan_note — the planner instruction. It rides in front of the plan prompt
# (rb/plan.sh) and the pre-plan prompt (run-preplan.sh).
pc_plan_note() {
  printf '%s ' "CHANGED SYMBOLS (BH-5791): plan.md MUST carry a '## Changed symbols' section. Write one bullet per symbol this plan changes, as '- <kind> \`<name>\`: <what changes>', where kind is function, verb (a CLI command), route ('METHOD /path') or format (a file or section format). If the plan leaves a caller of a changed symbol alone on purpose, end that bullet with 'callers: left alone: <reason>'. Write 'None.' when the plan changes no symbol. After the plan is written, the build checks main since the plan's base and every open PR for changes to the same symbols. If one of them changed a symbol you list, add a '## Design collisions' section with one bullet per symbol: '- \`<name>\`: combine — <how the two designs combine>' or '- \`<name>\`: needs-human — <the question a person must answer>'. A collision with no such line gets one repair pass, and then the build stops as PLAN_BLOCKED."
}

# _pc_section <plan> <title> — the body of `## <title>` up to the next # or ##
# heading. rc 1 when the plan has no such heading.
_pc_section() {
  awk -v t="## $2" '
    f && /^##?[ \t]/ { exit }
    f { print }
    { l = $0; sub(/[ \t\r]+$/, "", l) }
    !f && l == t { f = 1; found = 1 }
    END { exit !found }' "$1"
}

# _pc_ere <text> — <text> escaped for an ERE.
_pc_ere() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'; }

# pc_locate <repo> <ref> <name> — one line per definition of function <name> at
# <ref>: `file<TAB>start<TAB>end<TAB>flag`. The end is the first later line at
# the def line's own indent that opens with `}`; a def whose braces close on
# its own line ends there; no end found is the def line with `(def line only)`.
pc_locate() {
  local repo="$1" ref="$2" name="$3" ere hits f n
  case "$name" in ''|*[!A-Za-z0-9_:.-]*) return 1 ;; esac
  ere=$(_pc_ere "$name")
  hits=$( { git -C "$repo" grep -nE -e "^[[:space:]]*(function[[:space:]]+)?${ere}[[:space:]]*\(\)" "$ref" -- "${PC_GLOBS_SH[@]}" 2>/dev/null
            git -C "$repo" grep -nE \
              -e "^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function\*?[[:space:]]+${ere}[[:space:]]*\(" \
              -e "^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+${ere}[[:space:]]*=" \
              "$ref" -- "${PC_GLOBS_JS[@]}" 2>/dev/null; } )
  [ -n "$hits" ] || return 1
  while IFS= read -r f; do
    f=${f#"$ref:"}
    n=${f#*:}; n=${n%%:*}; f=${f%%:*}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    git -C "$repo" show "$ref:$f" 2>/dev/null | awk -v s="$n" -v f="$f" '
      NR == s {
        ind = $0; sub(/[^ \t].*$/, "", ind)
        t = $0
        if (f ~ /\.sh$/) sub(/[ \t]#.*$/, "", t); else sub(/[ \t]\/\/.*$/, "", t)
        o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t)
        if (o == 0 || o <= c) { printf "%s\t%d\t%d\t\n", f, s, s; done = 1; exit }
        next
      }
      NR > s && substr($0, 1, length(ind) + 1) == ind "}" { printf "%s\t%d\t%d\t\n", f, s, NR; done = 1; exit }
      END { if (!done) printf "%s\t%d\t%d\t(def line only)\n", f, s, s }'
  done <<< "$hits"
  return 0
}

# pc_symbols <plan> [repo] [ref] — `listed|derived<TAB>kind<TAB>name<TAB>reason`.
# Listed rows come from `## Changed symbols` (reason: the text after
# `callers:`, without a leading `left alone:`). A section that says None gives
# no rows. No section: backticked identifiers that have a function definition
# at <ref> are `derived`, report-only.
pc_symbols() {
  local plan="$1" repo="${2:-.}" ref="${3:-HEAD}" sec cands re defs
  [ -r "$plan" ] || return 2
  if sec=$(_pc_section "$plan" "Changed symbols"); then
    printf '%s\n' "$sec" | awk '
      /^[ \t]*[-*][ \t]+/ {
        line = $0; sub(/^[ \t]*[-*][ \t]+/, "", line); gsub(/\t/, " ", line)
        kind = line; sub(/[ \t].*$/, "", kind); kind = tolower(kind)
        if (kind !~ /^(function|verb|route|format)$/) next
        i = index(line, "`"); if (!i) next
        rest = substr(line, i + 1); j = index(rest, "`"); if (j < 2) next
        name = substr(rest, 1, j - 1); sub(/\(\)$/, "", name)
        reason = ""; k = index(line, "callers:")
        if (k) { reason = substr(line, k + 8); sub(/^[ \t]+/, "", reason); sub(/^left alone:[ \t]*/, "", reason); sub(/[ \t\r]+$/, "", reason) }
        if (seen[kind SUBSEP name]++) next
        printf "listed\t%s\t%s\t%s\n", kind, name, reason
      }'
    return 0
  fi
  cands=$(grep -oE '`[A-Za-z_][A-Za-z0-9_]{3,}(\(\))?`' "$plan" | tr -d '`' | sed 's/()$//' | LC_ALL=C sort -u | awk 'NR <= 200')
  [ -n "$cands" ] || return 0
  re=$(printf '%s\n' "$cands" | paste -sd'|' -)
  defs=$( { git -C "$repo" grep -hE -e "^[[:space:]]*(function[[:space:]]+)?($re)[[:space:]]*\(\)" "$ref" -- "${PC_GLOBS_SH[@]}" 2>/dev/null
            git -C "$repo" grep -hE \
              -e "^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function\*?[[:space:]]+($re)[[:space:]]*\(" \
              -e "^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+($re)[[:space:]]*=" \
              "$ref" -- "${PC_GLOBS_JS[@]}" 2>/dev/null; } \
          | sed -E 's/^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function\*?[[:space:]]+|(const|let|var)[[:space:]]+)?//; s/[^A-Za-z0-9_].*$//' \
          | LC_ALL=C sort -u)
  [ -n "$defs" ] || return 0
  printf '%s\n' "$cands" | grep -Fx -f <(printf '%s\n' "$defs") | awk '{ printf "derived\tfunction\t%s\t\n", $0 }'
  return 0
}

# pc_hit <repo> <from> <to> <kind> <name> <where> — at most one line
# `<sha12><TAB><reason>`: the newest commit in from..to that changed the
# symbol. A located function is checked by its line range at <to> (`git log
# -L`), so a change to another function in the same file is not a hit. A def
# at <from> that is gone at <to> is `removed or renamed <where>`. Anything else
# (verb, route, format, an unlocated function) is a `-G` text match over code
# paths only: .harness/ and docs/ are prose.
pc_hit() {
  local repo="$1" from="$2" to="$3" kind="$4" name="$5" where="$6" defs f s e fl out=""
  [ "$(git -C "$repo" rev-parse -q --verify "$from^{commit}" 2>/dev/null)" = "$(git -C "$repo" rev-parse -q --verify "$to^{commit}" 2>/dev/null)" ] && return 0
  if [ "$kind" = function ]; then
    if defs=$(pc_locate "$repo" "$to" "$name"); then
      while IFS=$'\t' read -r f s e fl; do
        out=$(git -C "$repo" log -s --abbrev=12 --format=%h -L "$s,$e:$f" "$from..$to" 2>/dev/null)
        if [ -n "$out" ]; then printf '%s\tbody or signature changed\n' "${out%%$'\n'*}"; return 0; fi
      done <<< "$defs"
      return 0
    fi
    if defs=$(pc_locate "$repo" "$from" "$name"); then
      while IFS=$'\t' read -r f s e fl; do
        out=$(git -C "$repo" log --abbrev=12 --format=%h -S"$name" "$from..$to" -- "$f" 2>/dev/null)
        if [ -n "$out" ]; then printf '%s\tremoved or renamed %s\n' "${out%%$'\n'*}" "$where"; return 0; fi
      done <<< "$defs"
      return 0
    fi
  fi
  # THE TEXT MATCH READS CODE, NOT PROSE (review of 5af55a47). Another ticket's
  # plan (.harness/) or a doc or note (docs/) that only MENTIONS a verb, route
  # or format is no collision: on 2026-10-09, 9 of main's 71 commits named
  # run-build.sh and 39 named "## Size", nearly all in plans. The name goes
  # through _pc_ere (git -G is an ERE): a lone "(" made git die, read as no hit.
  out=$(git -C "$repo" log --abbrev=12 --format=%h -G"$(_pc_ere "$name")" "$from..$to" \
          -- . ':(exclude).harness/' ':(exclude)docs/' 2>/dev/null)
  [ -z "$out" ] || printf '%s\t(text match)\n' "${out%%$'\n'*}"
  return 0
}

# pc_main_hits <repo> <base> <main> <symbols-tsv> <out> — appends COLLISION
# rows for main. rc 0 read, 2 unread (PC_WHY says why).
pc_main_hits() {
  local repo="$1" base="$2" main="$3" syms="$4" out="$5" origin kind name rs hit
  PC_WHY=""
  if ! git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then PC_WHY="base not in clone"; return 2; fi
  if ! git -C "$repo" rev-parse -q --verify "$main^{commit}" >/dev/null 2>&1; then PC_WHY="main ref does not resolve"; return 2; fi
  while IFS=$'\t' read -r origin kind name rs; do
    [ -n "$name" ] || continue
    hit=$(pc_hit "$repo" "$base" "$main" "$kind" "$name" "on main")
    [ -z "$hit" ] || printf 'COLLISION\t%s\t%s\tmain\t%s\n' "$origin" "$name" "$hit" >> "$out"
  done < "$syms"
  return 0
}

# pc_pr_hits <repo> <main> <symbols-tsv> <out> <slug> <self-branch> <self-key>
#            <stack-base> <max> — appends COLLISION rows for each open PR.
# rc 0 read (PC_PR_N = PRs checked), 2 unread (PC_WHY), 4 off (max 0).
pc_pr_hits() {
  local repo="$1" main="$2" syms="$3" out="$4" slug="$5" self="$6" key="$7" stack="$8" max="$9"
  local list lf rc=0 kl ns nums n mb origin kind name rs hit lib r
  local -a specs=()
  PC_WHY=""; PC_PR_N=0
  [ "$max" = 0 ] && return 4
  if ! command -v gh_rest_pr_list_all >/dev/null 2>&1; then
    lib="$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh"
    # shellcheck source=bin/lib/gh-rest-list.sh
    [ -r "$lib" ] && . "$lib" 2>/dev/null
  fi
  if ! command -v gh_rest_pr_list_all >/dev/null 2>&1; then PC_WHY="no REST lib"; return 2; fi
  if [ -z "$slug" ]; then PC_WHY="no repo slug"; return 2; fi
  # In this shell, not in $(…): GH_REST_REASON must survive for the case below
  # (gh-rest-no-subshell-lint). The list goes through a scratch file instead.
  lf=$(mktemp "${TMPDIR:-/tmp}/pc-prs.XXXXXX") || { PC_WHY="no scratch file"; return 2; }
  gh_rest_pr_list_all "$slug" open "$max" > "$lf" || rc=$?
  list=$(cat "$lf"); rm -f "$lf"
  if [ "$rc" != 0 ]; then
    case "$rc:${GH_REST_REASON:-}" in
      75:rate*|75:quota*) PC_WHY="rate limited" ;;
      44:*) PC_WHY="repo not found" ;;
      *) PC_WHY="GitHub did not answer (rc $rc${GH_REST_REASON:+, ${GH_REST_REASON}})" ;;
    esac
    return 2
  fi
  if ! printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1; then PC_WHY="the PR list is not an array"; return 2; fi
  kl=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  nums=$(printf '%s' "$list" | jq -r --arg self "$self" --arg key "$key" --arg kl "$kl" --arg stack "$stack" '
    .[] | select(.number != null)
    | (.head.ref // "") as $h | (.title // "") as $t
    | select($h != $self)
    | select(($key != "" and ($t | startswith($key)) and ((($t | ltrimstr($key)) | test("^[0-9]")) | not)) | not)
    | select(($kl != "" and ($h | test("^ticket/" + $kl + "(-r[0-9]+)?$"))) | not)
    | select($stack == "" or $h != $stack)
    | .number' 2>/dev/null)
  ns=$(printf '%s' "$kl" | tr -c 'a-z0-9-' '-')
  [ -n "$ns" ] || ns=build
  for n in $nums; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    specs+=("+refs/pull/$n/head:refs/collision-check/$ns/pr/$n")
  done
  if [ "${#specs[@]}" = 0 ]; then return 0; fi
  if ! timeout 120 git -C "$repo" fetch --quiet --no-tags origin "${specs[@]}" 2>/dev/null; then
    _pc_drop_refs "$repo" "$ns"; PC_WHY="fetch failed"; return 2
  fi
  for n in $nums; do
    r="refs/collision-check/$ns/pr/$n"
    git -C "$repo" rev-parse -q --verify "$r" >/dev/null 2>&1 || continue
    PC_PR_N=$((PC_PR_N + 1))
    mb=$(git -C "$repo" merge-base "$main" "$r" 2>/dev/null) || continue
    while IFS=$'\t' read -r origin kind name rs; do
      [ -n "$name" ] || continue
      hit=$(pc_hit "$repo" "$mb" "$r" "$kind" "$name" "in the PR")
      [ -z "$hit" ] || printf 'COLLISION\t%s\t%s\t#%s\t%s\n' "$origin" "$name" "$n" "$hit" >> "$out"
    done < "$syms"
  done
  _pc_drop_refs "$repo" "$ns"
  return 0
}

_pc_drop_refs() { # _pc_drop_refs <repo> <namespace>
  local r
  for r in $(git -C "$1" for-each-ref --format='%(refname)' "refs/collision-check/$2/" 2>/dev/null); do
    git -C "$1" update-ref -d "$r" 2>/dev/null
  done
}

# pc_resolved <plan> <name> — rc 0 the plan's `## Design collisions` has a line
# for `name` that says combine with 20+ characters of how; rc 2 it says
# needs-human; rc 1 no such line. The decision word is the first word after the
# backticked name (separators `:`, dashes, spaces, `*` and `_` skipped); the
# same word later on the line does not count (BH-8813: "combine. ... the earlier
# needs-human stop" read as needs-human and BH-7305 looped 37 builds).
pc_resolved() {
  local sec
  sec=$(_pc_section "$1" "Design collisions") || return 1
  printf '%s\n' "$sec" | awk -v n="\`$2\`" '
    { i = index($0, n) }
    i {
      r = substr($0, i + length(n))
      sub(/^[ \t:*_—–-]+/, "", r)
      w = tolower(r); sub(/[^a-z-].*$/, "", w)
      if (w == "needs-human") { nh = 1; next }
      if (w == "combine") { r = substr(r, 8); gsub(/^[ \t:.*_—–-]+/, "", r); if (length(r) >= 20) ok = 1 }
    }
    END { if (nh) exit 2; if (ok) exit 0; exit 1 }'
}

# pc_listed_hits <collisions-file> — the unique names of LISTED collisions.
pc_listed_hits() { awk -F'\t' '$1 == "COLLISION" && $2 == "listed" && !s[$3]++ { print $3 }' "$1" 2>/dev/null; }

# pc_note <plan> <collisions-file> — replace any earlier `## Design collision
# check (BH-5791)` section with a fresh one. It goes in front of `## Size`, or
# else in front of the closing KIND/SIZE/SLICE lines, because the size gate and
# the XL split read those at the end of the file.
pc_note() {
  local plan="$1" col="$2" tmp note sym main prs drop cap
  [ -r "$plan" ] && [ -r "$col" ] || return 1
  sym=$(sed -n 's/^SYMBOLS: //p' "$col" | head -1)
  main=$(sed -n 's/^MAIN: //p' "$col" | head -1)
  prs=$(sed -n 's/^OPEN_PRS: //p' "$col" | head -1)
  drop=$(printf '%s' "$sym" | sed -n 's/.*dropped=\([0-9]*\).*/\1/p')
  cap=$(printf '%s' "$sym" | sed -n 's/.*cap=\([0-9]*\).*/\1/p')
  note=$(
    printf '## Design collision check (BH-5791)\n\n'
    printf 'Checked %s listed and %s derived symbols against ' \
      "$(printf '%s' "$sym" | sed -n 's/.*listed=\([0-9]*\).*/\1/p')" "$(printf '%s' "$sym" | sed -n 's/.*derived=\([0-9]*\).*/\1/p')"
    case "$main" in
      checked*) printf 'main %s' "${main#checked }" ;;
      *) printf 'main (%s)' "$main" ;;
    esac
    case "$prs" in
      checked*) printf ' and %s open PRs.\n' "${prs#checked }" ;;
      off) printf ' and no open PRs (the PR check is off).\n' ;;
      *) printf ' and no open PRs (%s).\n' "$prs" ;;
    esac
    case "$main" in unread*) printf 'Main could not be read, so this check is not complete.\n' ;; esac
    case "$prs" in unread*) printf 'The open PRs could not be read, so this check is not complete.\n' ;; esac
    case "$drop" in ''|0) ;; *) printf 'It dropped %s of the symbols over the cap of %s.\n' "$drop" "${cap:-?}" ;; esac
    if ! grep -q '^COLLISION	' "$col"; then
      printf -- '- `none`: no checked symbol changed after the base.\n'
    else
      awk -F'\t' '$1 == "SYMBOL" { k[$3] = $4 } $1 == "COLLISION" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" k[$3] }' "$col" \
      | while IFS=$'\t' read -r origin name where sha why kind; do
          case "$where" in main) where="main $sha" ;; *) where="PR $where $sha" ;; esac
          if [ "$origin" = listed ]; then
            pc_resolved "$plan" "$name"
            case $? in
              0) res="Resolution: combine." ;;
              2) res="Resolution: needs-human." ;;
              *) res="Resolution: none under ## Design collisions." ;;
            esac
          else
            res="Derived from the plan text, a note only."
          fi
          printf -- '- `%s` (%s, %s): %s, %s. %s\n' "$name" "${kind:-function}" "$origin" "$where" "$why" "$res"
        done
    fi
  )
  tmp=$(mktemp "${TMPDIR:-/tmp}/pc-note.XXXXXX") || return 1
  # The note reaches awk as a file, never through -v: -v rewrites backslashes.
  printf '%s\n' "$note" > "$tmp.note" || { rm -f "$tmp"; return 1; }
  awk -v nf="$tmp.note" '
    { l[NR] = $0 }
    END {
      n = NR; skip = 0; m = 0
      for (i = 1; i <= n; i++) {
        if (l[i] == "## Design collision check (BH-5791)") { skip = 1; continue }
        if (skip && l[i] ~ /^##?[ \t]/) skip = 0
        if (skip) continue
        o[++m] = l[i]
      }
      at = 0
      for (i = m; i >= 1; i--) if (o[i] ~ /^## Size[ \t]*$/) { at = i; break }
      if (!at) {
        for (i = m; i >= 1 && (o[i] ~ /^(KIND|SIZE|SLICE):/ || o[i] ~ /^[ \t]*$/); i--) if (o[i] !~ /^[ \t]*$/) at = i
      }
      if (!at) at = m + 1
      for (i = 1; i < at; i++) print o[i]
      if (at > 1 && o[at - 1] !~ /^[ \t]*$/) print ""
      while ((getline x < nf) > 0) print x
      print ""
      for (i = at; i <= m; i++) print o[i]
    }' "$plan" > "$tmp" && cat "$tmp" > "$plan"
  rm -f "$tmp" "$tmp.note"
  return 0
}
