#!/bin/bash
# bin/lib/migration-number.sh — BH-7325: pick and reserve the next numbered
# migration (<dir>/NNNN_<name>.sql) before a build writes one, and refuse a PR
# that adds a number main or another open PR already holds. Sourced, never
# executed: no `exit`, no output at source time. Deterministic, no model call.
#
# WHY. On 2026-10-17 builders on example-org/project-6 picked a taken number five
# times (#1140, #1149, #1150, #1173, #1178). Each read only origin/main's
# prisma/sql/ and did not see the numbers open PRs and other builds held.
#
# WHO IS AFFECTED. Only a project with a migrations_glob.<project> settings row
# (bin/lib/migrations-glob.sh, MG_SRC = migrations_glob.<project>) AND at least
# one numbered file on main. Every other project gets no prompt line, no
# reservation and no review finding.
#
# A NUMBERED FILE is <dir>/NNNN_<name>.sql: 4 digits, an underscore, a name, no
# subdirectory. `158_x.sql`, `0158-x.sql`, `<dir>/sub/0158_x.sql` and
# `0158_x.sql.bak` are not numbered files.
#
# mn_dir <project>       the migration dir, or nothing when the project has no
#                        migrations_glob row (the fleet default does not count).
#                        Sets MN_DIR and MN_DIR_SRC (mg_glob's MG_SRC). Call it
#                        as `mn_dir p >/dev/null; dir=$MN_DIR` where the source
#                        matters: a $(...) call loses MN_DIR_SRC.
# mn_dir_unread          rc 0 when the last mn_dir could not read the setting
#                        (MN_DIR_SRC unreadable or no-client): the dir is not
#                        known, so the feature is NOT known to be off (BH-7325
#                        review: a silent off is the collision this lib stops)
# mn_holder <project> <number>
#                        GET /api/migration-numbers/holder: prints the ticket key
#                        that holds <number> in migration_reservations, nothing
#                        when no row does. rc 1 when the worker did not answer.
# mn_num_of <dir> <path> prints NNNN when <path> is a numbered file of <dir>
# mn_main_numbers <repo> <ref> <dir>
#                        `NNNN<TAB>path` for each numbered file on <ref>
# mn_open_pr_files <slug> <dir> [exclude-ref] [exclude-sha]
#                        the numbered files each open PR ADDS (status added or
#                        renamed; a renamed file counts under its new name).
#                        Sets MN_PR_ROWS (`NNNN<TAB>#<n><TAB>path` lines),
#                        MN_PRS_READ and MN_INCOMPLETE (empty, or why the read
#                        is not whole: a failed read, more than 300 open PRs, a
#                        PR with more than 300 files). Skips the PR whose head
#                        ref or head sha is the exclusion. rc 0 whole, 2 not.
# mn_floor <repo> <ref> <dir> <slug> [exclude-ref] [exclude-sha]
#                        1 + the highest NNNN on <ref> and in the open PRs,
#                        4 digits. Prints it; sets MN_FLOOR, MN_MAIN_MAX,
#                        MN_PR_MAX. Gaps are never filled: a lower number could
#                        order a new migration before one already applied.
# mn_reserve <project> <key> <floor>
#                        POST /api/migration-numbers/reserve. The worker answers
#                        max(floor, highest reserved + 1), or the key's own row
#                        when it is already >= floor. Prints the number; sets
#                        MN_NUMBER and MN_RESERVED=reserved|reused. Any failure:
#                        prints nothing, MN_RESERVED=unreserved, rc 1.
# mn_plan_note <project> <key> <repo> <ref> [exclude-ref]
#                        the plan-stage entry (bin/lib/rb/plan.sh). Off when
#                        the settings row migration_number.reserve is 0 (or
#                        the env MIGRATION_NUMBER_RESERVE=0 on the box), when
#                        mn_dir is empty, or when <ref> has no numbered file.
#                        When the migrations_glob read failed (mn_dir_unread)
#                        it writes `MIGRATION_NUMBER: - unreserved ...
#                        incomplete=settings-unreadable (<src>)` and a prompt
#                        sentence that tells the builder to reserve by hand and
#                        not to take main's max + 1. Otherwise it reserves,
#                        writes $BUILD/migration-number.txt (one line
#                        `MIGRATION_NUMBER: <n> <reserved|reused|unreserved>
#                        floor=<f> main_max=<m> pr_max=<p> prs_read=<k>
#                        incomplete=<no|why>`) and prints one prompt sentence.
#                        A worker or GitHub failure never stops the build: the
#                        sentence then says the number is NOT reserved.
# mn_taken <repo> <base> <head> <slug> <dir> [project]
#                        for each numbered file the diff base...head ADDS:
#                        `NNNN<TAB>taken by main (<path>)` when <base> holds the
#                        number under another path, `NNNN<TAB>taken by #<n>
#                        (<path>)` when another open PR adds it AND that PR
#                        wins: the other ticket holds the number in
#                        migration_reservations, or no ticket of the two holds
#                        it and #<n> is older (a lower PR number; a branch with
#                        no PR yet is newer than every open PR). When THIS PR
#                        wins the line is `NNNN<TAB>note: also added by #<n>
#                        (<path>) ...`, a NOTE, never a refusal: only one of
#                        the two PRs renumbers. The local branch and the head
#                        sha are excluded (the PR itself). [project] (arg 6)
#                        turns the reservation lookup on; own key is
#                        $PSC_PR_KEY, else the ticket/<key> branch.
#                        Sets MN_NEXT (1 + the highest number seen) and
#                        MN_INCOMPLETE. rc 0 none, 1 some, 2 none found but the
#                        open PRs could not be read whole.
# mn_psc_check <repo> <base> <head> <mode> <rule-id>
#                        the `migration-number` rule of bin/lib/pr-self-check.sh.
#                        Project: $PSC_PROJECT, else fleet.conf column 2 = the
#                        origin slug. No project or no dir: silent. Prints
#                        `REFUSE|NOTE <id>: migration number NNNN taken by ...;
#                        next free: NNNN or above, reserve it first: ...` and
#                        rc 1 when it refused. A partial PR read is one NOTE,
#                        never a refusal on its own. A settings read that
#                        failed (mn_dir_unread) is one NOTE, never silence.
#
# The root is ${HARNESS:-${H:-}} (D43): empty means no fleet.conf, so the rule
# finds no project and stays silent.

_MN_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=bin/lib/migrations-glob.sh
. "$_MN_LIB_DIR/migrations-glob.sh" 2>/dev/null || :

MN_PR_ROWS=""; MN_PR_REFS=""; MN_SELF_PR=""; MN_PRS_READ=0; MN_INCOMPLETE=""; MN_DIR=""; MN_DIR_SRC=""
MN_FLOOR=""; MN_MAIN_MAX=0; MN_PR_MAX=0; MN_NUMBER=""; MN_RESERVED=""; MN_NEXT=""
MN_PAGE_MAX=3

mn_dir() {
  MN_DIR=""; MN_DIR_SRC=""
  command -v mg_glob >/dev/null 2>&1 || return 0
  mg_glob "${1:-}" >/dev/null 2>&1
  MN_DIR_SRC=$MG_SRC
  [ "$MG_SRC" = "migrations_glob.${1:-}" ] || return 0
  MN_DIR=${MG_GLOB%/\*.sql}
  printf '%s\n' "$MN_DIR"
}

mn_dir_unread() { case "$MN_DIR_SRC" in unreadable|no-client) return 0 ;; esac; return 1; }

mn_holder() {
  local p="$1" n="$2" out
  [[ "$n" =~ ^[0-9]{1,6}$ ]] || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  out=$(JOBS_ALERT=0 _jobs_req GET "/api/migration-numbers/holder?project=$p&number=$((10#$n))" 2>/dev/null) || return 1
  jq -e 'has("ticket_key")' <<<"$out" >/dev/null 2>&1 || return 1
  jq -r '.ticket_key // empty' <<<"$out"
}

# _mn_key_root <key> — BH-7325.2 -> BH-7325, upper case (a ticket's second
# migration reserves <KEY>.2, and it is still that ticket)
_mn_key_root() { local k="${1%.[0-9]*}"; printf '%s\n' "${k^^}"; }

mn_num_of() {
  local dir="$1" p="$2" rest
  [ -n "$dir" ] || return 1
  case "$p" in "$dir"/*) ;; *) return 1 ;; esac
  rest=${p#"$dir"/}
  [[ $rest =~ ^([0-9]{4})_[^/]+\.sql$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

mn_main_numbers() {
  local repo="$1" ref="$2" dir="$3" mode type sha p n
  [ -n "$dir" ] || return 0
  while IFS=$'\t' read -r mode p; do
    read -r mode type sha <<<"$mode"
    [ "$type" = blob ] || continue
    n=$(mn_num_of "$dir" "$p") || continue
    printf '%s\t%s\n' "$n" "$p"
  done < <(git -C "$repo" ls-tree "$ref" -- "$dir/" 2>/dev/null)
}

# _mn_gh — gh_rest_var, sourced beside this lib when the caller has none.
_mn_gh() {
  declare -F gh_rest_var >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/gh-rest.sh
  . "$_MN_LIB_DIR/gh-rest.sh" 2>/dev/null || return 1
  declare -F gh_rest_var >/dev/null 2>&1
}

mn_open_pr_files() {
  local slug="$1" dir="$2" xref="${3:-}" xsha="${4:-}" pg fp raw cnt prs="" n ref sha f num
  MN_PR_ROWS=""; MN_PR_REFS=""; MN_SELF_PR=""; MN_PRS_READ=0; MN_INCOMPLETE=""
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { MN_INCOMPLETE="no repo slug"; return 2; }
  _mn_gh || { MN_INCOMPLETE="no gh-rest lib"; return 2; }
  for ((pg = 1; pg <= MN_PAGE_MAX; pg++)); do
    # gh_rest_var, never $(gh_rest ...): GH_REST_STATUS must live in this shell (gh-rest-no-subshell-lint).
    if ! gh_rest_var raw GET "repos/$slug/pulls?state=open&per_page=100&page=$pg" 2>/dev/null; then
      MN_INCOMPLETE="open PR list read failed (HTTP ${GH_REST_STATUS:-000})"; return 2
    fi
    cnt=$(jq 'length' <<<"$raw" 2>/dev/null) || { MN_INCOMPLETE="open PR list did not parse"; return 2; }
    prs="$prs$(jq -r '.[] | [.number, .head.ref, .head.sha] | @tsv' <<<"$raw")"$'\n'
    [ "$cnt" -ge 100 ] || break
    [ "$pg" -lt "$MN_PAGE_MAX" ] || MN_INCOMPLETE="more than $((MN_PAGE_MAX * 100)) open PRs"
  done
  while IFS=$'\t' read -r n ref sha; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if { [ -n "$xref" ] && [ "$ref" = "$xref" ]; } || { [ -n "$xsha" ] && [ "$sha" = "$xsha" ]; }; then
      MN_SELF_PR=$n; continue
    fi
    MN_PR_REFS="$MN_PR_REFS#$n"$'\t'"$ref"$'\n'
    for ((fp = 1; fp <= MN_PAGE_MAX; fp++)); do
      if ! gh_rest_var raw GET "repos/$slug/pulls/$n/files?per_page=100&page=$fp" 2>/dev/null; then
        MN_INCOMPLETE="files of #$n read failed (HTTP ${GH_REST_STATUS:-000})"; continue 2
      fi
      cnt=$(jq 'length' <<<"$raw" 2>/dev/null) || { MN_INCOMPLETE="files of #$n did not parse"; continue 2; }
      while IFS= read -r f; do
        num=$(mn_num_of "$dir" "$f") || continue
        MN_PR_ROWS="$MN_PR_ROWS$num"$'\t'"#$n"$'\t'"$f"$'\n'
      done < <(jq -r '.[] | select(.status == "added" or .status == "renamed") | .filename' <<<"$raw")
      [ "$cnt" -ge 100 ] || break
      [ "$fp" -lt "$MN_PAGE_MAX" ] || MN_INCOMPLETE="#$n has more than $((MN_PAGE_MAX * 100)) files"
    done
    MN_PRS_READ=$((MN_PRS_READ + 1))
  done <<<"$prs"
  [ -z "$MN_INCOMPLETE" ] || return 2
  return 0
}

# _mn_max <rows> — the highest NNNN in column 1, as a plain integer (0 = none)
_mn_max() { awk -F'\t' 'NF && $1 ~ /^[0-9]+$/ { v = $1 + 0; if (v > m) m = v } END { print m + 0 }' <<<"$1"; }

mn_floor() {
  local repo="$1" ref="$2" dir="$3" slug="$4" xref="${5:-}" xsha="${6:-}" m
  MN_MAIN_MAX=$(_mn_max "$(mn_main_numbers "$repo" "$ref" "$dir")")
  mn_open_pr_files "$slug" "$dir" "$xref" "$xsha"
  MN_PR_MAX=$(_mn_max "$MN_PR_ROWS")
  m=$MN_MAIN_MAX; [ "$MN_PR_MAX" -gt "$m" ] && m=$MN_PR_MAX
  MN_FLOOR=$(printf '%04d' $((m + 1)))
  printf '%s\n' "$MN_FLOOR"
}

mn_reserve() {
  local p="$1" k="$2" f="$3" body out n
  MN_NUMBER=""; MN_RESERVED=unreserved
  [[ "$f" =~ ^[0-9]{1,6}$ ]] || return 1
  command -v _jobs_req >/dev/null 2>&1 || return 1
  body=$(jq -nc --arg p "$p" --arg k "$k" --argjson f "$((10#$f))" '{project: $p, ticket_key: $k, floor: $f}') || return 1
  out=$(JOBS_ALERT=0 _jobs_req POST /api/migration-numbers/reserve "$body" 2>/dev/null) || return 1
  n=$(jq -r '.number // empty' <<<"$out" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  MN_NUMBER=$(printf '%04d' $((10#$n)))
  if [ "$(jq -r '.reused' <<<"$out" 2>/dev/null)" = true ]; then MN_RESERVED=reused; else MN_RESERVED=reserved; fi
  printf '%s\n' "$MN_NUMBER"
}

# mn_slug <repo> [project] — owner/repo: fleet.conf column 2 for the project,
# else the origin remote's URL.
mn_slug() {
  local repo="$1" p="${2:-}" root="${HARNESS:-${H:-}}" s="" u o r
  if [ -n "$p" ] && { [ -n "${FLEET_CONF:-}" ] || [ -n "$root" ]; }; then
    s=$(awk -v p="$p" '$1 !~ /^#/ && $1 == p {print $2; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  fi
  if [ -z "$s" ] && u=$(git -C "$repo" remote get-url origin 2>/dev/null); then
    u=${u%/}; u=${u%.git}; r=${u##*/}; u=${u%/*}; o=${u##*[/:]}
    s="$o/$r"
  fi
  [[ "$s" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && printf '%s\n' "$s"
  return 0
}

# mn_project_of <slug> — the fleet.conf project whose column 2 is <slug>
mn_project_of() {
  local root="${HARNESS:-${H:-}}"
  [ -n "${1:-}" ] || return 0
  [ -n "${FLEET_CONF:-}" ] || [ -n "$root" ] || return 0
  awk -v r="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '$1 !~ /^#/ && tolower($2) == r {print $1; exit}' \
    "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null
}

mn_plan_note() {
  local p="$1" k="$2" repo="$3" ref="$4" xref="${5:-}" dir slug n state inc out=""
  [ -n "${BUILD:-}" ] && [ -d "$BUILD" ] && out="$BUILD/migration-number.txt" && rm -f "$out"
  [ "${MIGRATION_NUMBER_RESERVE:-1}" = 0 ] && return 0
  if command -v setting_get >/dev/null 2>&1 && [ "$(setting_get migration_number.reserve 2>/dev/null)" = 0 ]; then return 0; fi
  mn_dir "$p" >/dev/null; dir=$MN_DIR
  if [ -z "$dir" ] && mn_dir_unread; then
    [ -z "$out" ] || printf 'MIGRATION_NUMBER: - unreserved floor=- main_max=- pr_max=- prs_read=0 incomplete=settings-unreadable (%s)\n' "$MN_DIR_SRC" > "$out"
    printf 'MIGRATION NUMBER (BH-7325): the migrations_glob.%s setting could not be read (%s), so no migration number is reserved. ' "$p" "$MN_DIR_SRC"
    printf 'If this ticket adds a numbered migration (NNNN_<name>.sql), do not take main max + 1: open PRs may hold it. Run bin/migration-number.sh reserve %s %s and use the number it prints.' "$p" "$k"
    return 0
  fi
  [ -n "$dir" ] || return 0
  [ -n "$(mn_main_numbers "$repo" "$ref" "$dir")" ] || return 0
  slug=$(mn_slug "$repo" "$p")
  mn_floor "$repo" "$ref" "$dir" "$slug" "$xref" >/dev/null
  if mn_reserve "$p" "$k" "$MN_FLOOR" >/dev/null; then n=$MN_NUMBER; else n=$MN_FLOOR; fi
  state=$MN_RESERVED; inc=${MN_INCOMPLETE:-no}
  [ -z "$out" ] || printf 'MIGRATION_NUMBER: %s %s floor=%s main_max=%04d pr_max=%04d prs_read=%s incomplete=%s\n' \
    "$n" "$state" "$MN_FLOOR" "$MN_MAIN_MAX" "$MN_PR_MAX" "$MN_PRS_READ" "$inc" > "$out"
  printf 'MIGRATION NUMBER (BH-7325): if this ticket adds a migration under %s/, name it %s/%s_<name>.sql. ' "$dir" "$dir" "$n"
  if [ "$state" = unreserved ]; then
    printf '%s is NOT reserved (the reservation service did not answer), so another build may pick it; the review check refuses a number main or an open PR already holds (main max %04d, open PRs max %04d). ' "$n" "$MN_MAIN_MAX" "$MN_PR_MAX"
  else
    printf '%s is reserved for %s (main max %04d, open PRs max %04d). ' "$n" "$k" "$MN_MAIN_MAX" "$MN_PR_MAX"
  fi
  [ -z "$MN_INCOMPLETE" ] || printf 'The open PRs were not read whole (%s). ' "$MN_INCOMPLETE"
  printf 'A second migration needs its own number: run bin/migration-number.sh reserve %s %s.2 .' "$p" "$k"
}

mn_taken() {
  local repo="$1" base="$2" head="$3" slug="$4" dir="$5" proj="${6:-}" added="" f num main row xref xsha hits=0 m n p
  local own="" oref okey holder hstate
  MN_NEXT=""; MN_INCOMPLETE=""; MN_PR_ROWS=""; MN_PR_REFS=""; MN_SELF_PR=""
  while IFS= read -r f; do
    num=$(mn_num_of "$dir" "$f") || continue
    added="$added$num"$'\t'"$f"$'\n'
  done < <(git -C "$repo" diff --diff-filter=AR --name-only "$base...$head" 2>/dev/null)
  [ -n "$added" ] || return 0
  main=$(mn_main_numbers "$repo" "$base" "$dir")
  xref=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
  xsha=$(git -C "$repo" rev-parse -q --verify "$head^{commit}" 2>/dev/null)
  mn_open_pr_files "$slug" "$dir" "$xref" "$xsha"
  own=${PSC_PR_KEY:-}
  [ -n "$own" ] || case "$xref" in ticket/*) own=${xref#ticket/} ;; esac
  [ -z "$own" ] || own=$(_mn_key_root "$own")
  m=$(_mn_max "$main"); [ "$(_mn_max "$MN_PR_ROWS")" -gt "$m" ] && m=$(_mn_max "$MN_PR_ROWS")
  MN_NEXT=$(printf '%04d' $((m + 1)))
  while IFS=$'\t' read -r num f; do
    [ -n "$num" ] || continue
    while IFS=$'\t' read -r row p; do
      [ "$row" = "$num" ] && [ "$p" != "$f" ] || continue
      printf '%s\ttaken by main (%s)\n' "$num" "$p"; hits=1
    done <<<"$main"
    while IFS=$'\t' read -r row n p; do
      [ "$row" = "$num" ] || continue
      # Who renumbers: the reservation holder wins, else the older PR.
      oref=$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' <<<"$MN_PR_REFS")
      okey=""; case "$oref" in ticket/*) okey=$(_mn_key_root "${oref#ticket/}") ;; esac
      holder=""; hstate=unknown
      if [ -n "$proj" ] && holder=$(mn_holder "$proj" "$num"); then
        hstate=none; [ -z "$holder" ] || { holder=$(_mn_key_root "$holder"); hstate=other; }
        [ -n "$holder" ] && [ -n "$own" ] && [ "$holder" = "$own" ] && hstate=own
        [ -n "$holder" ] && [ -n "$okey" ] && [ "$holder" = "$okey" ] && hstate=theirs
      fi
      if [ "$hstate" = own ]; then
        printf '%s\tnote: also added by %s (%s); %s holds %s in migration_reservations, so %s renumbers\n' "$num" "$n" "$p" "$own" "$num" "$n"
      elif [ "$hstate" = theirs ] || [ -z "$MN_SELF_PR" ] || [ "${n#\#}" -lt "$MN_SELF_PR" ]; then
        printf '%s\ttaken by %s (%s)\n' "$num" "$n" "$p"; hits=1
      else
        printf '%s\tnote: also added by %s (%s), a newer PR (this is #%s) with no reservation of %s, so %s renumbers\n' "$num" "$n" "$p" "$MN_SELF_PR" "$num" "$n"
      fi
    done <<<"$MN_PR_ROWS"
  done <<<"$added"
  [ "$hits" = 1 ] && return 1
  [ -z "$MN_INCOMPLETE" ] || return 2
  return 0
}

mn_psc_check() {
  local repo="$1" base="$2" head="$3" mode="$4" id="$5" project dir slug tf num why refused=0
  slug=$(mn_slug "$repo")
  project="${PSC_PROJECT:-}"; [ -n "$project" ] || project=$(mn_project_of "$slug")
  [ -n "$project" ] || return 0
  mn_dir "$project" >/dev/null; dir=$MN_DIR
  if [ -z "$dir" ] && mn_dir_unread; then
    echo "NOTE $id: migrations_glob.$project could not be read ($MN_DIR_SRC), so migration numbers are not checked; reserve one with bin/migration-number.sh reserve $project <KEY>"
    return 0
  fi
  [ -n "$dir" ] || return 0
  tf=$(mktemp "${TMPDIR:-/tmp}/mn-taken.XXXXXX" 2>/dev/null) || { echo "NOTE $id: no temp file, migration numbers not checked"; return 0; }
  mn_taken "$repo" "$base" "$head" "$slug" "$dir" "$project" > "$tf"
  # next free: the reservations can hold numbers above MN_NEXT, so the text
  # sends the builder to the reserve verb, never to a bare number.
  local rk="${PSC_PR_KEY:-<KEY>}"
  while IFS=$'\t' read -r num why; do
    [ -n "$num" ] || continue
    case "$why" in note:*) [ "$mode" = off ] || echo "NOTE $id: migration number $num ${why#note: }"; continue ;; esac
    case "$mode" in
      refuse) echo "REFUSE $id: migration number $num $why; next free: $MN_NEXT or above, reserve it first: bin/migration-number.sh reserve $project $rk"; refused=1 ;;
      note) echo "NOTE $id: migration number $num $why; next free: $MN_NEXT or above, reserve it first: bin/migration-number.sh reserve $project $rk" ;;
    esac
  done < "$tf"
  rm -f "$tf"
  [ -z "$MN_INCOMPLETE" ] || echo "NOTE $id: open PRs not read ($MN_INCOMPLETE), only main was checked"
  [ "$refused" = 0 ]
}
