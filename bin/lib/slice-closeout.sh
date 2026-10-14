#!/bin/bash
# bin/lib/slice-closeout.sh — a slice close-out that finds no open child never
# leaves the parent open with no child (BH-6308).
#
# WHAT HAPPENED (#5240, 2026-10-12). #6170 delivered the whole of #5240 as its
# slice C1. The build ran remote, so its record held no plan.md, and the PR said
# `Part of #5240`, so the close guard answered slice:no-keyword. No open child
# carried the rest because nothing was left, and the close-out posted "No child
# issue carries the rest yet" and kept the issue open. #5241 is hard-blocked on
# #5240, so three tickets waited 11 hours on a ticket that was done.
#
# WHAT THIS DECIDES. issue_slice_settle and mc_close_shipped call sco_settle
# after a complete children read found none. It reads the merged plan (the
# record's plan.md, else `.harness/specs/<KEY>/plan.md` at the PR's merge
# commit, which every merged build carries) and asks its `## Requirements
# coverage` matrix, the scope-to-evidence table the plan stage writes (D32):
#   every row covered          close the parent with the merged slice PR links,
#                              unless the PR is a partial build (BH-5798): then
#                              its not-met items are the rest, as below
#   a row not covered, or the
#   check cannot decide        file ONE child issue with the rest, then close
#   the plan names C<k+1>..    a remote build's remainder goes to
#                              slice_remainder_settle (BH-5961), parent open
# A transient read failure decides nothing: it defers to the next tick.
#
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
# Safe under `set -u`. The root is the caller's argument or ${HARNESS:-${H:-}}.
#
#   sco_knob <NAME> [project]                         the knob value
#   sco_plan_fetch <slug> <n> <pr-url> <rec> <dir>    ok:<key> rc 0 | none:<why> rc 2 | err:<why> rc 1
#   sco_coverage <plan.md> <k>                        covered rc 0 | uncovered<TAB><n> rc 2
#                                                     | undecided<TAB><why> rc 3; then one row per line
#   sco_settle <slug> <n> <pr-url> <guard-word> <rec> [harness]
#       -> closed:covered:<prs> | closed:child:#c:<prs>   rc 4 (the parent is closed)
#        | filed:<slice_remainder_settle word>            rc 0 (children filed, parent open)
#        | deferred:<why>                                 rc 1 (nothing more written; next tick)
#        | skip:<why>                                     rc 3 (the caller's own path runs)
#
# Ledger: <rec>/slice-closeout/, or $H/state/slice-closeout/<owner>_<repo>-<n>-pr<prn>
# with no record. plan.md, key, k, verdict and rows.txt are frozen once, so a
# later tick never decides differently; child, close-commented and closed are
# written only after the write they record succeeded. The operator notes are in
# docs/verification-map/entries/BH-6308.md.

_SCO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/gh-rest-list.sh
command -v gh_rest_issue_list >/dev/null 2>&1 || { [ -r "$_SCO_LIB/gh-rest-list.sh" ] && . "$_SCO_LIB/gh-rest-list.sh"; }
# shellcheck source=bin/lib/slice-prs.sh
command -v slice_merged_prs >/dev/null 2>&1 || { [ -r "$_SCO_LIB/slice-prs.sh" ] && . "$_SCO_LIB/slice-prs.sh"; }
# shellcheck source=bin/lib/slice-remainder.sh
command -v slice_remainder_settle >/dev/null 2>&1 || { [ -r "$_SCO_LIB/slice-remainder.sh" ] && . "$_SCO_LIB/slice-remainder.sh"; }

# sco_knob <NAME> [project] — the sp_knob shape (bin/lib/stale-parent.sh):
# settings row > env > the registry default in
# catalog/lanes.d/_lib.slice-closeout.json, resolved in a subshell so the lane
# gate's fail-closed exit cannot end the caller.
sco_knob() {
  local name="${1:-}" v
  v=$(
    exec 3>&1
    # shellcheck disable=SC2016 # expanded by the trap, at exit
    trap 'printf "%s" "${!name:-}" >&3' EXIT
    command -v lib_env_apply >/dev/null 2>&1 || . "$_SCO_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    lib_env_apply slice-closeout "${2:-}" >/dev/null 2>&1) || true
  case "$name" in
    SLICE_CLOSEOUT_SETTLE) case "$v" in 0) printf '0\n' ;; *) printf '1\n' ;; esac ;;
    *) printf '%s\n' "$v" ;;
  esac
}

_sco_arm() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"; return 0; }

# _sco_dry — FILE_CHILDREN_DRY_RUN / DECOMPOSE_DRY_RUN, as fc_dry reads them.
_sco_dry() {
  local v
  for v in "${FILE_CHILDREN_DRY_RUN:-}" "${DECOMPOSE_DRY_RUN:-}"; do
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0 ;; esac
  done
  return 1
}

sco_plan_fetch() {
  local slug="${1:-}" n="${2:-}" pr="${3:-}" rec="${4:-}" dir="${5:-}" prn out key="" sha merged rc=0
  [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null || { printf 'err:dir\n'; return 1; }
  prn="${pr##*/pull/}"; prn="${prn%%/*}"
  if [ -n "$rec" ] && [ -r "$rec/plan.md" ]; then
    cp "$rec/plan.md" "$dir/plan.md" 2>/dev/null || { printf 'err:copy\n'; return 1; }
    [[ "$(basename "$rec")" =~ -([A-Z][A-Z0-9]*-$n)- ]] && key="${BASH_REMATCH[1]}"
    printf '%s\n' "$key" > "$dir/key"
    # A record whose name does not carry -<KEY>-$n- is another ticket's (or an
    # unnamed one's): its plan never decides this close, as on the remote
    # branch below (lead review lr-6333 of 5db9a1f05).
    [ -n "$key" ] || { printf 'none:key-mismatch\n'; return 2; }
    printf 'ok:%s\n' "$key"; return 0
  fi
  out=$(_sco_arm "$slug"; gh_rest GET "repos/$slug/pulls/$prn" 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 44) printf 'none:pr-404\n'; return 2 ;; *) printf 'err:pr-read\n'; return 1 ;; esac
  key=$(printf '%s' "$out" | jq -r '(.title // "") | capture("^[[:space:]\\[]*(?<k>[A-Z][A-Z0-9]*-[0-9]+)").k // ""' 2>/dev/null)
  sha=$(printf '%s' "$out" | jq -r '.merge_commit_sha // ""' 2>/dev/null)
  merged=$(printf '%s' "$out" | jq -r '.merged_at // ""' 2>/dev/null)
  printf '%s\n' "$key" > "$dir/key"
  printf '%s' "$out" | jq -r '.body // ""' > "$dir/pr-body.md" 2>/dev/null || rm -f "$dir/pr-body.md"
  [ -n "$merged" ] && [ -n "$sha" ] || { printf 'none:unmerged\n'; return 2; }
  [ -n "$key" ] || { printf 'none:no-key\n'; return 2; }
  # One ticket's plan never decides another ticket's close (the local branch
  # checks the same thing with `-$n-` in the record's name).
  [ "${key##*-}" = "$n" ] || { printf 'none:key-mismatch\n'; return 2; }
  rc=0
  out=$(_sco_arm "$slug"; gh_rest GET "repos/$slug/contents/.harness/specs/$key/plan.md?ref=$sha" 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 44) printf 'none:spec-404\n'; return 2 ;; *) printf 'err:spec-read\n'; return 1 ;; esac
  [ "$(printf '%s' "$out" | jq -r '.encoding // ""' 2>/dev/null)" = base64 ] || { printf 'err:spec-encoding\n'; return 1; }
  printf '%s' "$out" | jq -r '.content // ""' 2>/dev/null | tr -d '\n' | base64 -d > "$dir/plan.md.tmp" 2>/dev/null \
    && [ -s "$dir/plan.md.tmp" ] || { rm -f "$dir/plan.md.tmp"; printf 'err:spec-decode\n'; return 1; }
  mv -f "$dir/plan.md.tmp" "$dir/plan.md"
  printf 'ok:%s\n' "$key"; return 0
}

# _sco_partial <slug> <prn> <rec> <dir> — is the merged PR a PARTIAL build
# (BH-5798)? A partial build's PR says `Refs #n` with an `## Acceptance
# self-check` list of what is not met, so its plan's matrix records what the
# plan intended, not what merged. The not-met items go to <dir>/notmet.txt, one
# per line: the record's REFUTED evidence claims, else the PR body's unchecked
# self-check items. rc 0 partial | rc 2 not partial | rc 1 the PR read failed.
_sco_partial() {
  local slug="$1" prn="$2" rec="$3" dir="$4" out rc=0
  : > "$dir/notmet.txt"
  if [ -n "$rec" ] && [ -r "$rec/evidence.json" ]; then
    jq -r '.claims[]? | select(.verdict == "REFUTED") | "claim \(.n): \(.claim // "" | .[0:200]) (not met: REFUTED)"' \
      "$rec/evidence.json" > "$dir/notmet.txt" 2>/dev/null || : > "$dir/notmet.txt"
    [ -s "$dir/notmet.txt" ] && return 0
  fi
  if [ ! -e "$dir/pr-body.md" ]; then
    out=$(_sco_arm "$slug"; gh_rest GET "repos/$slug/pulls/$prn" 2>/dev/null) || rc=$?
    case "$rc" in 0) ;; 44) return 2 ;; *) return 1 ;; esac
    printf '%s' "$out" | jq -r '.body // ""' > "$dir/pr-body.md.tmp" 2>/dev/null \
      && mv -f "$dir/pr-body.md.tmp" "$dir/pr-body.md" || { rm -f "$dir/pr-body.md.tmp"; return 1; }
  fi
  awk '{ sub(/\r$/, "") }
       /^##[ \t]+[Aa]cceptance self-check/ { f = 1; seen = 1; next }
       f && /^## / { f = 0 }
       f && /^[ \t]*- \[ \][ \t]/ { sub(/^[ \t]*- \[ \][ \t]+/, ""); print; n++ }
       END { if (seen && !n) print "an acceptance item the merged PR lists as not met" }' \
    "$dir/pr-body.md" > "$dir/notmet.txt" 2>/dev/null
  [ -s "$dir/notmet.txt" ] && return 0
  return 2
}

# _sco_rows <plan.md> <k> — ONE awk pass, mawk-safe, over the `## Requirements
# coverage` section outside fences: `<class><TAB><requirement>` per data row, or
# NOSEC when there is no such section. A Task cell is (A3 of the plan):
#   uncovered   empty or `-`, a later slice C<j> (j > k), a word that says
#               the work is elsewhere (later/next slice, remaining, deferred,
#               follow-up, out of scope, not covered, not built, TODO, TBD,
#               child), or a NEGATION (not, no, isn't) next to a slice, C<j> or
#               `on main` ("NOT in C1 (A2)", "not on main yet")
#   covered     a task of this plan (T<n>, Task <n>, `all`, `scope`), `on main`,
#               or C<j> with j <= k
#   undecided   anything else, and any C<j> when k is unknown
# The words match whole words only ("children" and "child-issue" are not
# "child"). The OTHER cells of the row (Test, notes) are read for the same
# deferral words and for `slice C<j>` with j > k, so "| T1 | child slice C2 |"
# is uncovered; a bare C<j> there is a test case ID and is not read
# (lead review lr-6333: .harness/specs/BH-5653/plan.md, "NOT in C1 (A2) |
# child slice C2", read covered at k=1 before).
_sco_rows() {
  awk -v K="${2:--1}" '
    function lead(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # norm(s): lower case, no markdown emphasis, trimmed, and padded with one
    # space each side so the word tests below can use [^a-z0-9-] as a bound.
    function norm(s) { s = tolower(s); gsub(/[`*_]/, "", s); return trim(s) }
    function defer(s) {
      s = " " s " "
      return s ~ /[^a-z0-9-](later slice|next slice|remaining|deferred|follow-up|follow up|out of scope|not covered|not built|todo|tbd|child)[^a-z0-9-]/
    }
    # negated(s, cells): a negation next to a slice, `on main` or (in the Task
    # cell only, cells == 0) a bare C<j>. In the other cells a bare C<j> is a
    # test case ID, not a slice (lead review lr-6333 of 65b1c1765).
    function negated(s, cells) {
      s = " " s " "
      if (s !~ /[^a-z0-9-](not|no|isn.t|isnt)[^a-z0-9-]/) return 0
      if (s ~ /(on main|slice)/) return 1
      return !cells && s ~ /[^a-z0-9_]c[0-9]+/
    }
    # laterslice(s): `slice C<j>` or `C<j> slice` with j > k, in the cells
    # beside the Task cell ("child slice C2"). A bare C<j> there is a test
    # case ID ("route-suite C4–C7", BH-4008) and never a slice.
    function laterslice(s,   j) {
      s = " " s " "
      while (match(s, /slice[ \t:#-]*c[0-9]+|[^a-z0-9_]c[0-9]+[ \t)]*slice/)) {
        j = substr(s, RSTART, RLENGTH); match(j, /c[0-9]+/); j = substr(j, RSTART + 1, RLENGTH - 1) + 0
        if (K >= 0 && j > K) return 1
        s = substr(s, RSTART + RLENGTH)
      }
      return 0
    }
    function klass(t, rest,   s, pre, j, unk, lo) {
      t = norm(t); rest = norm(rest)
      if (t == "" || t == "-" || t == "\342\200\224" || t == "\342\200\223") return "uncovered"
      if (defer(t) || negated(t, 0)) return "uncovered"
      if (defer(rest) || negated(rest, 1) || laterslice(rest)) return "uncovered"
      s = t; unk = 0; lo = 0
      while (match(s, /c[0-9]+/)) {
        pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        j = substr(s, RSTART + 1, RLENGTH - 1) + 0
        if (pre !~ /[a-z0-9_]/) { if (K < 0) unk = 1; else if (j > K) return "uncovered"; else lo = 1 }
        s = substr(s, RSTART + RLENGTH)
      }
      if (unk) return "undecided"
      if (lo || t ~ /(^|[^a-z0-9_])t[0-9]+([^0-9]|$)/ || t ~ /task [0-9]/ || t ~ /on main/) return "covered"
      # "all" (every task of this plan) and "scope" (a NEGATIVE row this plan
      # meets by not doing it) name work of this plan (the BH-4008 matrix).
      if (t ~ /^(all|all tasks|every task|scope)$/) return "covered"
      return "undecided"
    }
    BEGIN { fch = ""; sec = 0; seen = 0; hdr = 0 }
    { sub(/\r$/, "") }
    {
      t = $0; sub(/^[ \t]+/, "", t)
      if (fch != "") { if (lead(t, fch) >= flen && trim(substr(t, lead(t, fch) + 1)) == "") fch = ""; next }
      if (lead(t, "`") >= 3) { fch = "`"; flen = lead(t, "`"); next }
      if (lead(t, "~") >= 3) { fch = "~"; flen = lead(t, "~"); next }
    }
    /^## / { sec = (tolower($0) ~ /^##[ \t]+requirements coverage/) ? 1 : 0; if (sec) { seen = 1; hdr = 0 }; next }
    sec && /^[ \t]*\|/ {
      if (!hdr) { hdr = 1; next }
      r = $0; gsub(/[ \t|:-]/, "", r); if (r == "") next
      n = split($0, c, "|")
      if (n < 3) next
      req = trim(c[2]); gsub(/\t/, " ", req)
      rest = ""; for (i = 4; i < n; i++) rest = rest " " c[i]
      printf "%s\t%s\n", klass(c[3], rest), substr(req, 1, 200)
    }
    END { if (!seen) print "NOSEC" }
  ' "$1"
}

sco_coverage() {
  local plan="${1:-}" k="${2:-}" rows nu nd
  case "$k" in ''|*[!0-9]*) k=-1 ;; esac
  [ -r "$plan" ] || { printf 'undecided\tno-plan\n'; return 3; }
  rows=$(_sco_rows "$plan" "$k") || { printf 'undecided\tscan\n'; return 3; }
  [ "$rows" = NOSEC ] && { printf 'undecided\tno-matrix\n'; return 3; }
  [ -n "$rows" ] || { printf 'undecided\tno-rows\n'; return 3; }
  nu=$(printf '%s\n' "$rows" | grep -c '^uncovered	')
  nd=$(printf '%s\n' "$rows" | grep -c '^undecided	')
  if [ "$nu" -gt 0 ]; then
    printf 'uncovered\t%s\n' "$nu"; printf '%s\n' "$rows" | sed -n 's/^uncovered	//p'; return 2
  fi
  if [ "$nd" -gt 0 ]; then
    printf 'undecided\trows:%s\n' "$nd"; printf '%s\n' "$rows" | sed -n 's/^undecided	//p'; return 3
  fi
  printf 'covered\n'; return 0
}

# _sco_alert <harness> <id> <msg> — one critical page through bin/lane-alert.sh.
_sco_alert() {
  if [ -n "$1" ] && [ -x "$1/bin/lane-alert.sh" ]; then
    "$1/bin/lane-alert.sh" --severity critical --id "$2" slice-closeout "$3" >/dev/null 2>&1 || true
  else
    echo "slice-closeout: $3 (no bin/lane-alert.sh to page with)" >&2
  fi
}

sco_settle() {
  local slug="${1:-}" n="${2:-}" pr="${3:-}" g="${4:-}" rec="${5:-}" h="${6:-${HARNESS:-${H:-}}}" d prn rc=0
  [ "$(sco_knob SLICE_CLOSEOUT_SETTLE)" = 0 ] && { printf 'skip:off\n'; return 3; }
  _sco_dry && { printf 'skip:dry-run\n'; return 3; }
  case "$n" in ''|*[!0-9]*) printf 'skip:args\n'; return 3 ;; esac
  [[ "$pr" =~ /pull/([0-9]+)/?$ ]] || { printf 'skip:pr-url\n'; return 3; }
  prn="${BASH_REMATCH[1]}"
  command -v jq >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v slice_merged_prs >/dev/null 2>&1 \
    || { printf 'skip:no-libs\n'; return 3; }
  if [ -n "$rec" ] && [ -d "$rec" ]; then d="$rec/slice-closeout"
  elif [ -n "$h" ]; then d="$h/state/slice-closeout/${slug//\//_}-$n-pr$prn"
  else printf 'skip:no-ledger\n'; return 3; fi
  mkdir -p "$d" 2>/dev/null || { printf 'deferred:ledger-write\n'; return 1; }
  # A DEDUPE, not a queue (D33): the conductor, rb/pr.sh, batch-resolve and the
  # hotfix lane can race on one merge. A second lane skips and is re-offered on
  # its next tick, where the ledger answers it. Held only for this call.
  if command -v flock >/dev/null 2>&1; then
    _sco_settle_locked "$slug" "$n" "$pr" "$g" "$rec" "$h" "$d" "$prn" 8>"$d/.lock" || rc=$?
  else
    _sco_settle_locked "$slug" "$n" "$pr" "$g" "$rec" "$h" "$d" "$prn" || rc=$?
  fi
  return "$rc"
}

_sco_settle_locked() {
  local slug="$1" n="$2" pr="$3" g="$4" rec="$5" h="$6" d="$7" prn="$8"
  local out st w frc pw verdict k key project prs nums urls cw
  if command -v flock >/dev/null 2>&1; then
    flock -n 8 || { printf 'deferred:locked\n'; return 1; }
  fi
  # LEDGER FIRST: a closed parent is answered with no read and no write.
  if [ -s "$d/closed" ]; then printf 'closed:%s\n' "$(head -1 "$d/closed")"; return 4; fi
  out=$(_sco_arm "$slug"; gh_rest GET "repos/$slug/issues/$n" 2>/dev/null) || { printf 'deferred:parent-read\n'; return 1; }
  st=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)
  [ -n "$st" ] || { printf 'deferred:parent-read\n'; return 1; }
  [ "$st" = open ] || { printf 'skip:parent-closed\n'; return 3; }
  printf '%s' "$out" | jq -r '.body // ""' > "$d/parent-body.md" 2>/dev/null

  if [ ! -s "$d/verdict" ]; then
    w=$(sco_plan_fetch "$slug" "$n" "$pr" "$rec" "$d"); frc=$?
    case "$frc" in
      1) printf 'deferred:plan-read\n'; return 1 ;;
      0)
        k=$(_slr_scan "$d/plan.md" "$n" 2>/dev/null | awk -F'\t' '$1 == "K" { print $2; exit }')
        printf '%s\n' "$k" > "$d/k"
        pw=$(slice_remainder_parse "$d/plan.md" "$n" "$d/remainder.json" "$pr" 2>/dev/null)
        rm -f "$d/remainder.json"
        case "$pw" in
          ok:*)
            # The record's own plan goes through BH-5961's filer unchanged.
            if [ "$g" = slice:plan ] && [ -n "$rec" ] && [ -r "$rec/plan.md" ]; then
              printf 'skip:remainder-local\n'; return 3
            fi
            verdict=remainder ;;
          none|bad:no-slice-line)
            # No remainder named (or no SLICE line, which a whole-ticket plan
            # with no Closes keyword has): the coverage matrix decides.
            cw=$(sco_coverage "$d/plan.md" "$k")
            verdict=$(head -1 <<<"$cw")
            tail -n +2 <<<"$cw" > "$d/rows.txt"
            # A matrix that is all covered on a PARTIAL build is the plan's
            # intent, not proof: its not-met items are the rest.
            if [ "$verdict" = covered ]; then
              _sco_partial "$slug" "$prn" "$rec" "$d"; frc=$?
              case "$frc" in
                0) verdict="partial	$(grep -c . "$d/notmet.txt")"; cp "$d/notmet.txt" "$d/rows.txt" ;;
                1) rm -f "$d/rows.txt"; printf 'deferred:pr-read\n'; return 1 ;;
              esac
            fi ;;
          *) verdict="undecided	remainder-${pw#bad:}" ;;
        esac ;;
      *) verdict="undecided	no-plan:${w#none:}" ;;
    esac
    printf '%s\n' "$verdict" > "$d/verdict"
  fi
  verdict=$(head -1 "$d/verdict")
  key=$(head -1 "$d/key" 2>/dev/null)
  [ -n "$key" ] || key="#$n"
  k=$(head -1 "$d/k" 2>/dev/null)
  project=""
  [ -n "$h" ] && [ -r "$h/fleet.conf" ] && project=$(awk -v s="$slug" '$1 !~ /^#/ && $2 == s { print $1; exit }' "$h/fleet.conf")
  if [ -z "$project" ] && [ -n "$rec" ]; then
    project=$(basename "$rec"); project="${project%-"$key"-*}"; project="${project#pool-}"
  fi
  [ -n "$project" ] || project="${slug#*/}"

  if [ "$verdict" = remainder ]; then
    w=$(slice_remainder_settle "$slug" "$n" "$pr" "$d" "$h" "$d/plan.md" "$key" "$project"); frc=$?
    case "$frc" in
      0) printf 'filed:%s\n' "$w"; return 0 ;;
      1) printf 'deferred:remainder\n'; return 1 ;;
    esac
    verdict="undecided	remainder-${w#remainder-}"
    printf '%s\n' "$verdict" > "$d/verdict"
  fi

  # The merged slices, newest first. The PR under close-out is one of them even
  # when the timeline has not caught up with its merge.
  prs=$(slice_merged_prs "$slug" "$n" "$h") || { printf 'deferred:%s\n' "${prs#ERR:}"; return 1; }
  printf '%s\n' "$prs" | awk -F'\t' -v p="$prn" '$3 == p { f = 1 } END { exit !f }' || prs=$(printf '0\t%s\t%s\n%s' "$pr" "$prn" "$prs")
  prs=$(printf '%s\n' "$prs" | awk -F'\t' 'NF >= 3' | sort -t$'\t' -k1,1nr -k3,3nr)
  nums=$(printf '%s\n' "$prs" | awk -F'\t' '{ printf "%s#%s", (NR > 1 ? "," : ""), $3 }')
  urls=$(printf '%s\n' "$prs" | cut -f2)

  case "$verdict" in
    covered) _sco_close "$slug" "$n" "$h" "$d" "covered:$nums" \
      "Everything in this ticket is now on main. The plan of the last merged slice maps every requirement to merged work. Merged slices:
$urls

Closing it."
      return $? ;;
  esac
  _sco_file_rest "$slug" "$n" "$pr" "$prn" "$h" "$d" "$key" "$project" "$k" "$verdict" "$urls" || return 1
  local c why
  c=$(head -1 "$d/child")
  case "$verdict" in
    uncovered*) why="$(grep -c . "$d/rows.txt" 2>/dev/null) item(s) the merged plan did not cover" ;;
    partial*)   why="$(grep -c . "$d/rows.txt" 2>/dev/null) acceptance item(s) the merged PR did not meet" ;;
    undecided*rows:*) why="$(grep -c . "$d/rows.txt" 2>/dev/null) item(s) the merged plan could not prove" ;;
    *) why="the close-out could not prove the merged slices delivered the whole scope" ;;
  esac
  _sco_close "$slug" "$n" "$h" "$d" "child:$c:$nums" \
    "The merged slices delivered part of this ticket:
$urls

$c carries the rest: $why. Closing this issue. The rest is tracked on $c."
}

# _sco_file_rest ... — ONE child issue with the rest, through the existing
# filer (fc_file_issues, kind slice) in a subshell, the way _slr_settle_locked
# runs it. FC_PARENT_NOTE=0: the parent gets this lib's close comment instead of
# the filer's "this issue stays open" note, and the close takes the label off.
_sco_file_rest() {
  local slug="$1" n="$2" pr="$3" prn="$4" h="$5" d="$6" key="$7" project="$8" k="$9" verdict="${10}" urls="${11}"
  local lib title first lead items deps rc=0 dl frc=0 got
  [ -s "$d/child" ] && return 0
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  if [ ! -s "$d/children.json" ]; then
    first=$(head -1 "$d/rows.txt" 2>/dev/null)
    if [ -n "$first" ]; then title="Rest of $key: $(_slr_title "$first")"
    else title="Rest of $key: scope the merged slices did not prove"; fi
    case "$verdict" in
      uncovered*)       lead="The plan of the last merged slice did not map these items to merged work:"
                        items=$(sed 's/^/- /' "$d/rows.txt") ;;
      undecided*rows:*) lead="The plan of the last merged slice could not prove these items were built:"
                        items=$(sed 's/^/- /' "$d/rows.txt") ;;
      partial*)         lead="The last merged slice was a partial build. Its acceptance self-check lists these items as not met:"
                        items=$(sed 's/^/- /' "$d/rows.txt") ;;
      *)
        case "$verdict" in
          *no-plan:*)  lead="The merged slice has no plan the close-out could read (${verdict#*no-plan:}), so it could not prove the scope was built." ;;
          *no-matrix*|*no-rows*) lead="The plan of the last merged slice has no requirements coverage table, so the close-out could not prove the scope was built." ;;
          *)           lead="The close-out could not read what the plan of the last merged slice left for later (${verdict#*	})." ;;
        esac
        lead="$lead The parent's scope, as written:"
        items=$(awk '/^##[ \t]+[Ss]cope/ { f = 1; next } f && /^## / { exit } f' "$d/parent-body.md" 2>/dev/null)
        [ -n "$(printf '%s' "$items" | tr -d '[:space:]')" ] || items=$(head -n 60 "$d/parent-body.md" 2>/dev/null) ;;
    esac
    rc=0; dl=$(_sco_arm "$slug"; gh_rest_issue_list "$slug" open "" 300 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ]; then
      deps=$(printf '%s' "$dl" | jq -r --argjson n "$n" '
        ("^[ \t>*_#-]*blocked[- ]by\\b.*#" + ($n|tostring) + "([^0-9]|$)") as $re
        | [ .[] | select(.number != $n) | select((.body // "") | split("\n") | map(sub("\r$"; "")) | any(test($re; "i"))) | "#\(.number)" ]
        | join(", ")' 2>/dev/null) || rc=1
    fi
    if [ "$rc" != 0 ]; then deps="The open issues could not be read, so check by hand for a Blocked-by: #$n line that should move here."
    elif [ -n "$deps" ]; then deps="These open issues wait on #$n with a Blocked-by line: $deps. #$n is closed now, so move their blocker to this issue."
    else deps="No open issue names #$n in a Blocked-by line."; fi
    jq -nc --argjson o "$((k + 1))" --arg t "$title" --arg b "The merged slices of #$n delivered part of it:
$urls

This issue carries the rest. $lead

$items

$deps" '[{ordinal: $o, title: $t, body: $b, after: []}]' > "$d/children.json.tmp" 2>/dev/null \
      && mv -f "$d/children.json.tmp" "$d/children.json" || { rm -f "$d/children.json.tmp"; printf 'deferred:spec-write\n'; return 1; }
  fi
  lib="$_SCO_LIB"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-issues.sh" ] || lib="$h/bin/lib"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-issues.sh" ] || { printf 'deferred:no-filer\n'; return 1; }
  # A SUBSHELL: the filer exports GH_TOKEN and sources its own libs.
  (
    # shellcheck source=bin/lib/file-children.sh
    . "$lib/file-children.sh" || exit 1
    # shellcheck source=bin/lib/fc-issues.sh
    . "$lib/fc-issues.sh" || exit 1
    HARNESS="$h" GH_ISSUES_REPO="$slug" FC_PROJECT="$project" FC_PARENT="$n" FC_KEY="$key" \
      FC_BUILD="$d" FC_SPEC="$d/children.json" FC_KIND=slice FC_LANE=issues \
      FC_SLICE_BASE="$k" FC_SLICE_PR="$prn" FC_PARENT_NOTE=0
    export FC_SLICE_BASE FC_SLICE_PR FC_PARENT_NOTE
    fc_file_issues || { printf '%s\n' "${FC_ERROR:-fc_file_issues failed}" > "$d/fc-error.txt"; exit 1; }
    exit 0
  ) >>"$d/fc-out.txt" 2>&1 || frc=$?
  got=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/#\1/p' "$d/children.txt" 2>/dev/null)
  if [ "$frc" = 0 ] && [ "$(printf '%s' "$got" | grep -c .)" = 1 ]; then
    printf '%s\n' "$got" > "$d/child"; return 0
  fi
  [ -s "$d/fc-error.txt" ] || printf 'the filer did not record one child (rc %s)\n' "$frc" > "$d/fc-error.txt"
  _sco_alert "$h" "slice-closeout-failed:$slug#$n:$prn" \
    "slice-closeout-failed issue $slug#$n: filing the rest of PR $pr as a child issue did not finish ($(head -c 300 "$d/fc-error.txt")); nothing was closed, and the next close-out tick resumes from $d"
  printf 'deferred:file-failed\n'
  return 1
}

# _sco_close <slug> <n> <harness> <ledger> <closed-word> <comment> — comment
# once, close, record, strip. The strip runs only after a verified close, so
# "unlabelled but open" cannot happen here; a failed comment does not stop the
# close and adds `,comment-failed` to the word.
_sco_close() {
  local slug="$1" n="$2" h="$3" d="$4" word="$5" body="$6" sfx="" s
  if [ ! -e "$d/close-commented" ]; then
    if command -v _issue_comment >/dev/null 2>&1 && _issue_comment "$slug" "$n" "$body"; then
      touch "$d/close-commented"
    else
      sfx=",comment-failed"
    fi
  fi
  if ! (_sco_arm "$slug"; gh_rest_close "$slug" "$n" >/dev/null 2>&1); then
    printf 'deferred:close-failed\n'; return 1
  fi
  printf '%s\n' "$word" > "$d/closed"
  s=$(issue_strip_ai_build "$slug" "$n" "$h" 2>/dev/null)
  printf '%s\n' "$s" > "$d/strip"
  case "$s" in strip-failed) sfx="$sfx+strip-failed" ;; esac
  printf 'closed:%s%s\n' "$word" "$sfx"
  return 4
}
