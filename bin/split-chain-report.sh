#!/bin/bash
# gh-identity: app-token
# bin/split-chain-report.sh — measure what splitting a ticket costs (BH-5520).
#
#   split-chain-report.sh [--slug owner/repo] [--days 14] [--repo <clone>] [--json <out>]
#
# One-shot operator report. For the trailing window it measures:
#   (a) lead time, first PR open -> last PR merge. "split" is a parent whose
#       child tickets merged 2 or more PRs in the window; "unsplit" is a ticket
#       that is neither a child nor a parent.
#   (b) the real product size of each merged split-child PR (its merge commit,
#       paths through bin/size-scope.sh --filter, so tests and docs do not
#       count), against the budget its issue promised (`Size budget: at most N
#       lines of product code across F files.`, written by fc_child_footer).
# Then it applies Rule A (plan BH-5520) and writes one `decision`:
#   "propose 1200/30" only when the split median lead > the unsplit median
#   lead, the child product-line p75 <= 1200, the child product-file p90 <= 30,
#   and n >= 5 on both sides. Otherwise "no change: <first failed condition>".
#
# Reads: GitHub REST only (`gh api`, explicit pages of 100). A ticket's key is
# the first BH-<n> in its PR title (the form bin/lib/gh-pr-create.sh writes),
# and BH-<n> is issue #<n>. A child issue names its parent as `Part of #<n>`.
#
# Exit: 0 report written. 2 INCOMPLETE: a read failed or rate-limited (75),
# the report has no `decision`, and stdout starts `INCOMPLETE: <why>`. 1 usage.
# An empty window is not INCOMPLETE: it is n=0 and "no change: n<5".
#
# Writes: one JSON file, default $HARNESS/state/split-chain/report-<UTC date>.json.
# No D1 write, no counter, no cron lane. SPLIT_CHAIN_NOW pins the clock (tests).
# SPLIT_CHAIN_MAX_PAGES (default 30) bounds the pages read per list; a list
# that hits it sets sources.capped=true.
#
# gh-rest: no-graphql
set -uo pipefail

# ---- pure helpers (sourced by tests/split-chain-report.bh-5520-test.sh) ----

split_chain_median() { # split_chain_median <v>... -> median (mean of the middle two), empty on n=0
  [ $# -gt 0 ] || return 0
  printf '%s\n' "$@" | sort -g | awk '{ a[NR] = $1 }
    END { if (NR % 2) m = a[(NR + 1) / 2]; else m = (a[NR / 2] + a[NR / 2 + 1]) / 2
          s = sprintf("%.1f", m); sub(/\.0$/, "", s); print s }'
}

split_chain_pct() { # split_chain_pct <p> <v>... -> nearest-rank percentile, empty on n=0
  local p="$1"; shift
  [ $# -gt 0 ] || return 0
  printf '%s\n' "$@" | sort -g | awk -v p="$p" '{ a[NR] = $1 }
    END { r = p * NR / 100; i = int(r); if (i < r) i++; if (i < 1) i = 1
          s = sprintf("%.1f", a[i]); sub(/\.0$/, "", s); print s }'
}

split_chain_title_key() { # split_chain_title_key <title> -> the first BH-<n> number, or empty
  [[ "${1:-}" =~ BH-([0-9]+) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

split_chain_body_parent() { # split_chain_body_parent <body> -> N of the first `Part of #N`, or empty
  [[ "${1:-}" =~ Part\ of\ \#([0-9]+) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

split_chain_body_budget() { # split_chain_body_budget <body> -> "<lines> <files>", or empty
  [[ "${1:-}" =~ Size\ budget:\ at\ most\ ([0-9]+)\ lines\ of\ product\ code\ across\ ([0-9]+)\ files ]] \
    && printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  return 0
}

# Rule A. The order of the checks is the order of the plan's table.
split_chain_decide() { # <split med h> <unsplit med h> <lines p75> <files p90> <n split> <n unsplit>
  local sm="${1:-}" um="${2:-}" l75="${3:-}" f90="${4:-}" ns="${5:-0}" nu="${6:-0}"
  if [ "${ns:-0}" -lt 5 ] || [ "${nu:-0}" -lt 5 ]; then echo "no change: n<5"; return 0; fi
  if ! awk -v a="$sm" -v b="$um" 'BEGIN { exit !(a + 0 > b + 0) }'; then
    echo "no change: split not slower"; return 0; fi
  if [ -z "$l75" ] || [ -z "$f90" ]; then echo "no change: no measured child"; return 0; fi
  if awk -v a="$l75" 'BEGIN { exit !(a + 0 > 1200) }'; then echo "no change: child p75 > 1200"; return 0; fi
  if awk -v a="$f90" 'BEGIN { exit !(a + 0 > 30) }'; then echo "no change: child files p90 > 30"; return 0; fi
  echo "propose 1200/30"
}

# ---- executable body ----

_scr_usage() {
  echo "usage: split-chain-report.sh [--slug owner/repo] [--days N] [--repo <clone>] [--json <out>]" >&2
  exit 1
}

_scr_incomplete() { # _scr_incomplete <why> -> writes a decision-less report, exit 2
  echo "INCOMPLETE: $1"
  mkdir -p "$(dirname "$JSON")" 2>/dev/null
  jq -n --arg why "$1" --arg s "$START_ISO" --arg e "$NOW_ISO" --argjson d "$DAYS" --arg slug "$SLUG" \
    '{slug:$slug, window:{days:$d, start:$s, end:$e}, incomplete:$why}' > "$JSON" 2>/dev/null
  exit 2
}

# _scr_read_pages <kind> <path without page> <out file> <stop-epoch or empty>
# Reads page 1.. until a short page, an empty page, or (pulls) a page whose
# oldest updated_at is before the window. Concatenates into one array.
_scr_read_pages() {
  local kind="$1" path="$2" out="$3" stop="$4" page=1 f rc len oldest
  : > "$W/$kind.parts"
  while :; do
    if [ "$page" -gt "$MAX_PAGES" ]; then CAPPED=true; break; fi
    f="$W/$kind-$page.json"
    rc=0
    gh api "${path}&page=${page}" > "$f" 2>"$W/$kind.err" || rc=$?
    [ "$rc" = 0 ] || _scr_incomplete "$kind page $page read failed (rc $rc)$(head -c 160 "$W/$kind.err" 2>/dev/null | tr '\n' ' ' | sed 's/^./: &/')"
    jq -e 'type == "array"' "$f" >/dev/null 2>&1 || _scr_incomplete "$kind page $page is not a JSON array"
    printf '%s\n' "$f" >> "$W/$kind.parts"
    len=$(jq 'length' "$f")
    [ "$len" -ge 100 ] || break
    if [ -n "$stop" ]; then
      oldest=$(jq '[.[].updated_at // empty | fromdateiso8601] | min // 0' "$f")
      [ "$oldest" -ge "$stop" ] || break
    fi
    page=$((page + 1))
  done
  # shellcheck disable=SC2046
  jq -s 'add // []' $(cat "$W/$kind.parts") > "$out"
}

# _scr_measure <sha> -> "<product lines> <product files>", rc 1 when the commit is missing
_scr_measure() {
  local sha="$1" num paths
  if ! git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    timeout 60 git -C "$REPO" fetch -q origin "$sha" >/dev/null 2>&1
    git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  fi
  num=$(git -C "$REPO" diff --no-renames --numstat "${sha}^1" "$sha" 2>/dev/null) || return 1
  paths=$(printf '%s\n' "$num" | cut -f3- | bash "$SELF_DIR/size-scope.sh" --filter) || return 1
  awk -F'\t' 'NR == FNR { if ($0 != "") keep[$0] = 1; next }
    NF >= 3 && ($3 in keep) { f++; l += ($1 == "-" ? 0 : $1) + ($2 == "-" ? 0 : $2) }
    END { printf "%d %d\n", l, f }' <(printf '%s\n' "$paths") <(printf '%s\n' "$num")
}

_scr_main() {
  SLUG=""; DAYS=14; REPO="."; JSON=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) [ $# -ge 2 ] || _scr_usage; SLUG="$2"; shift 2 ;;
      --days) [ $# -ge 2 ] || _scr_usage; DAYS="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || _scr_usage; REPO="$2"; shift 2 ;;
      --json) [ $# -ge 2 ] || _scr_usage; JSON="$2"; shift 2 ;;
      -h|--help) _scr_usage ;;
      *) _scr_usage ;;
    esac
  done
  # An explicit --slug is checked here; the default is filled and checked below.
  [ -z "$SLUG" ] || [[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || _scr_usage
  [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 0 ] || _scr_usage
  command -v jq >/dev/null 2>&1 || { echo "split-chain-report: jq missing" >&2; exit 1; }

  HARNESS="${HARNESS:-/root/harness}"
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -z "$SLUG" ]; then
    # The default slug is the harness's own repo, from its one home (BH-4080).
    # shellcheck source=bin/lib/deployment.sh
    . "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" \
      || { echo "split-chain-report: bin/lib/deployment.sh unavailable" >&2; exit 2; }
    SLUG="${HARNESS_REPO:-}"
    [[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
      || { echo "split-chain-report: no usable default slug (HARNESS_REPO='$SLUG'); pass --slug <owner/repo>" >&2; exit 2; }
  fi
  MAX_PAGES="${SPLIT_CHAIN_MAX_PAGES:-30}"
  [[ "$MAX_PAGES" =~ ^[0-9]+$ ]] && [ "$MAX_PAGES" -gt 0 ] || MAX_PAGES=30
  NOW="${SPLIT_CHAIN_NOW:-$(date +%s)}"
  [[ "$NOW" =~ ^[0-9]+$ ]] || _scr_usage
  START=$((NOW - DAYS * 86400))
  NOW_ISO=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  START_ISO=$(date -u -d "@$START" +%Y-%m-%dT%H:%M:%SZ)
  ISSUE_SINCE=$(date -u -d "@$((START - 14 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
  [ -n "$JSON" ] || JSON="$HARNESS/state/split-chain/report-$(date -u -d "@$NOW" +%Y-%m-%d).json"
  CAPPED=false

  W=$(mktemp -d "${TMPDIR:-/tmp}/split-chain.XXXXXX") || { echo "INCOMPLETE: no temp dir"; exit 2; }
  # The App identity for $SLUG, armed before the first gh call and reset on
  # exit (gh-app-ratchet). Without App config gh_auth_for returns 1 and the
  # reads run on the box default, as before.
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$SELF_DIR/lib/gh-app-auth.sh" ] && . "$SELF_DIR/lib/gh-app-auth.sh" || true
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  trap 'rm -rf "$W"; command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset || true' EXIT

  _scr_read_pages pulls "repos/$SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
    "$W/pulls.json" "$START"
  _scr_read_pages issues "repos/$SLUG/issues?state=all&since=$ISSUE_SINCE&per_page=100" \
    "$W/issues.json" ""

  local prs_read issues_read
  prs_read=$(jq 'length' "$W/pulls.json")
  issues_read=$(jq 'length' "$W/issues.json")

  # Child issue -> parent and budget. Pull requests in the issues list are not issues.
  declare -A PARENT_OF=() BUDGET_OF=() IS_PARENT=()
  local n body par bud
  while IFS=$'\t' read -r n body; do
    [ -n "$n" ] || continue
    body=$(printf '%s' "$body" | base64 -d 2>/dev/null)
    par=$(split_chain_body_parent "$body")
    [ -n "$par" ] || continue
    PARENT_OF[$n]="$par"; IS_PARENT[$par]=1
    bud=$(split_chain_body_budget "$body")
    [ -n "$bud" ] && BUDGET_OF[$n]="$bud"
  done < <(jq -r '.[] | select(has("pull_request") | not) | [(.number|tostring), ((.body // "") | @base64)] | @tsv' "$W/issues.json")

  # Merged PRs in the window: number, created epoch, merged epoch, sha, title.
  declare -A G_MIN=() G_MAX=() G_CNT=() U_MIN=() U_MAX=()
  local SPLIT_H=() UNSPLIT_H=() LINES=() FILES=() unmeasured=0 over=0
  local num c m sha title key g meas l f bl bf
  while IFS=$'\t' read -r num c m sha title; do
    [ -n "$num" ] || continue
    key=$(split_chain_title_key "$title")
    [ -n "$key" ] || continue
    if [ -n "${PARENT_OF[$key]:-}" ]; then
      g="${PARENT_OF[$key]}"
      G_CNT[$g]=$(( ${G_CNT[$g]:-0} + 1 ))
      { [ -z "${G_MIN[$g]:-}" ] || [ "$c" -lt "${G_MIN[$g]}" ]; } && G_MIN[$g]=$c
      { [ -z "${G_MAX[$g]:-}" ] || [ "$m" -gt "${G_MAX[$g]}" ]; } && G_MAX[$g]=$m
      if [ -n "$sha" ] && meas=$(_scr_measure "$sha"); then
        read -r l f <<< "$meas"
        LINES+=("$l"); FILES+=("$f")
        if [ -n "${BUDGET_OF[$key]:-}" ]; then
          read -r bl bf <<< "${BUDGET_OF[$key]}"
          { [ "$l" -gt "$bl" ] || [ "$f" -gt "$bf" ]; } && over=$((over + 1))
        fi
      else
        unmeasured=$((unmeasured + 1))
      fi
    elif [ -z "${IS_PARENT[$key]:-}" ]; then
      { [ -z "${U_MIN[$key]:-}" ] || [ "$c" -lt "${U_MIN[$key]}" ]; } && U_MIN[$key]=$c
      { [ -z "${U_MAX[$key]:-}" ] || [ "$m" -gt "${U_MAX[$key]}" ]; } && U_MAX[$key]=$m
    fi
  done < <(jq -r --argjson s "$START" '.[] | select(.merged_at != null)
      | (.merged_at | fromdateiso8601) as $m | select($m >= $s)
      | [(.number|tostring), ((.created_at | fromdateiso8601)|tostring), ($m|tostring),
         (.merge_commit_sha // ""), (.title // "" | gsub("[\t\n]"; " "))] | @tsv' "$W/pulls.json")

  for g in "${!G_CNT[@]}"; do
    [ "${G_CNT[$g]}" -ge 2 ] || continue
    SPLIT_H+=("$(awk -v d="$(( G_MAX[$g] - G_MIN[$g] ))" 'BEGIN { printf "%.4f", d / 3600 }')")
  done
  for key in "${!U_MIN[@]}"; do
    UNSPLIT_H+=("$(awk -v d="$(( U_MAX[$key] - U_MIN[$key] ))" 'BEGIN { printf "%.4f", d / 3600 }')")
  done

  local s_med s_p75 u_med u_p75 l50 l75 l90 f75 f90 decision
  s_med=$(split_chain_median "${SPLIT_H[@]}");  s_p75=$(split_chain_pct 75 "${SPLIT_H[@]}")
  u_med=$(split_chain_median "${UNSPLIT_H[@]}"); u_p75=$(split_chain_pct 75 "${UNSPLIT_H[@]}")
  l50=$(split_chain_median "${LINES[@]}"); l75=$(split_chain_pct 75 "${LINES[@]}"); l90=$(split_chain_pct 90 "${LINES[@]}")
  f75=$(split_chain_pct 75 "${FILES[@]}"); f90=$(split_chain_pct 90 "${FILES[@]}")
  decision=$(split_chain_decide "$s_med" "$u_med" "$l75" "$f90" "${#SPLIT_H[@]}" "${#UNSPLIT_H[@]}")

  mkdir -p "$(dirname "$JSON")" 2>/dev/null
  jq -n --arg slug "$SLUG" --argjson d "$DAYS" --arg s "$START_ISO" --arg e "$NOW_ISO" \
    --argjson sn "${#SPLIT_H[@]}" --arg sm "$s_med" --arg sp "$s_p75" \
    --argjson un "${#UNSPLIT_H[@]}" --arg um "$u_med" --arg up "$u_p75" \
    --argjson cn "${#LINES[@]}" --argjson cu "$unmeasured" --argjson co "$over" \
    --arg l50 "$l50" --arg l75 "$l75" --arg l90 "$l90" --arg f75 "$f75" --arg f90 "$f90" \
    --argjson pr "$prs_read" --argjson ir "$issues_read" --argjson cap "$CAPPED" --arg dec "$decision" '
    def n: if . == "" then null else tonumber end;
    {slug:$slug, window:{days:$d, start:$s, end:$e},
     split:{n:$sn, median_h:($sm|n), p75_h:($sp|n)},
     unsplit:{n:$un, median_h:($um|n), p75_h:($up|n)},
     children:{n:$cn, unmeasured:$cu, lines_p50:($l50|n), lines_p75:($l75|n), lines_p90:($l90|n),
               files_p75:($f75|n), files_p90:($f90|n), over_budget_n:$co},
     sources:{prs_read:$pr, issues_read:$ir, capped:$cap},
     decision:$dec}' > "$JSON" || { echo "INCOMPLETE: cannot write $JSON"; exit 2; }

  printf 'split-chain %s %sd: split n=%s median %sh p75 %sh | unsplit n=%s median %sh p75 %sh | children n=%s unmeasured=%s lines p75 %s files p90 %s over-budget %s | decision: %s | %s\n' \
    "$SLUG" "$DAYS" "${#SPLIT_H[@]}" "${s_med:--}" "${s_p75:--}" "${#UNSPLIT_H[@]}" "${u_med:--}" "${u_p75:--}" \
    "${#LINES[@]}" "$unmeasured" "${l75:--}" "${f90:--}" "$over" "$decision" "$JSON"
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _scr_main "$@"
fi
