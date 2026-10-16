# shellcheck shell=bash
# bin/lib/stuck-work/facts-pr.sh — BH-3791 (BH-3781.2): the open-PR fact reader,
# on the contract BH-3789 fixed. Sourced, never executed.
#
#   swf_pr_facts <repo>   -> one FACTS line (kind pr) per open PR, oldest first
#                            (created_at, then number), the format fixed in
#                            bin/lib/stuck-work/classify.sh
#   rc 0 = the set of PRs is whole. A field that could not be read is `?` on
#          its own line and does not change the rc.
#   rc 3 = incomplete: the list read failed (nothing printed — the list helper
#          never hands back a partial list) or there were more open PRs than
#          STUCK_WORK_MAX_ITEMS (fallback 300; the oldest that many are printed).
#   rc 1 = not wired: a bad <repo>, or gh_rest_pr_list_all / jq not loaded.
#
# This lib only CALLS existing verbs and loads none of them but one: the lane
# sources bin/lib/gh-rest-list.sh, verdict-status.sh, verdicts.sh, the jobs
# client, bin/lib/mc/*, bin/lib/jobs/dequeue-watch.sh and seen.sh first. A verb
# that is not loaded makes ITS fields `?`, never `-`. The one it loads itself is
# bin/lib/pr-snapshot.sh (BH-4660, below).
#
# Per PR, REST only (gh_rest), never GraphQL:
#   6,7   lead_status(_at)  the head's combined status, context $(vs_context)
#   8-10  verdict, verdict_sha, verdict_at   vd_standing on the head
#   12    mergify  mc_mergify_check_live -> failed | checking | queued | merged | -
#   13,14 cond_state, cond_since  ONE paged pr_state_page read per call (<= 5 pages)
#   15    resolver_at  mc_resolver_claim_get <repo#n> <head>, col 4 (active_at)
#   16    dqw_action_at  newest dqw_actions_list updated_at, read ONLY when the
#                        labels hold `dequeued` or mergify is `failed`
#   22    first_seen  sw_first_seen "<repo#n>|<head12>|<mergify>"; not asked
#                     when mergify is `?`, so an outage never plants a clock
# Fields 17-21 belong to tickets and are always `-` here. Every time is epoch.
#
# BH-4660 (BH-4656.2): the open list comes from prs_open_list (bin/lib/pr-snapshot.sh,
# loaded here on first use) when it loads, else gh_rest_pr_list_all. Fields 6, 7
# and 12 are cached per PR at state/stuck-work/ci/<owner_repo>-<n>, one line
# <head>\t<updated_at>\t<epoch>\t<lead_status>\t<lead_status_at>\t<mergify>, and
# both reads are skipped only on a hit (_swf_ci_hit). A read that answered `?` is
# never cached. SWF_COUNT_FILE, when set, gets CI-HIT|CI-MISS <n> per PR.
#
# gh-rest: no-graphql

_swf_fn() { [ "$(type -t "$1")" = function ]; }

# _swf_epoch <value> — digits as they are, ISO-8601 through date, anything else `?`.
_swf_epoch() {
  local v="${1:-}" e
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
  if [ -n "$v" ] && [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && e=$(date -u -d "$v" +%s 2>/dev/null) && [[ "$e" =~ ^[0-9]+$ ]]; then
    printf '%s' "$e"; return 0
  fi
  printf '?'
}

# _swf_mergify <status|conclusion|title lines> — the one word for the phase.
_swf_mergify() {
  printf '%s\n' "${1:-}" | awk -F'|' '
    NF < 2 { next }
    { s = tolower($1); c = tolower($2); t = tolower($3) }
    s == "completed" && c ~ /^(failure|cancelled|timed_out|action_required)$/ { f = 1 }
    s != "completed" { if (t ~ /check|embark|batch/) k = 1; else q = 1 }
    s == "completed" && c == "success" { m = 1 }
    END { if (f) print "failed"; else if (k) print "checking"; else if (q) print "queued"; else if (m) print "merged"; else print "-" }'
}

# _swf_state_dir <sub> — print state/stuck-work/<sub> under the harness root,
#   creating it; rc 1 = no cache. The root is ${HARNESS:-${H:-}}, and under
#   HARNESS_TEST_SANDBOX=1 only an explicit HARNESS, so a test never writes into
#   a live tree. Losing the dir costs reads, never correctness.
_swf_state_dir() {
  local h="${HARNESS:-}"
  [ -n "$h" ] || [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] || h="${H:-}"
  [ -n "$h" ] && mkdir -p "$h/state/stuck-work/$1" 2>/dev/null || return 1
  printf '%s' "$h/state/stuck-work/$1"
}
# _swf_now — STUCK_WORK_NOW under HARNESS_TEST_SANDBOX=1 when all digits (seen.sh's rule).
_swf_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${STUCK_WORK_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$STUCK_WORK_NOW"; else date -u +%s; fi
}
# _swf_put <file> — stdin into <file> through a temp file and mv, never torn.
_swf_put() { cat > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null; rm -f "$1.tmp.$$"; return 0; }
_swf_count() { [ -n "${SWF_COUNT_FILE:-}" ] && printf '%s %s\n' "$1" "$2" >> "$SWF_COUNT_FILE" 2>/dev/null; return 0; }

# _swf_ci_hit <file> <repo> <n> <head> <updated_at> <now> — print the cached
#   `lead_status\tlead_status_at\tmergify` and rc 0 only when the line is 6 fields,
#   its head and updated_at equal these (neither empty or `-`), no `checks <head>`
#   or `pr <n>` wake arrived since it was written (no prs_wake_seen: the TTL
#   decides), and it is younger than STUCK_WORK_CI_TTL_S (900; 0 never hits).
#   BH-6976: when the feed answers rc 1 for BOTH (healthy, no wake), the age
#   limit is max(TTL, STUCK_WORK_CI_QUIET_TTL_S) (1800; 0 = off; 1-1799 read as
#   1800). An rc 2 on either keeps the TTL.
_swf_ci_hit() {
  local f="$1" repo="$2" n="$3" head="$4" upd="$5" now="$6" ttl="${STUCK_WORK_CI_TTL_S:-900}" h u e a b c wrc age
  local quiet="${STUCK_WORK_CI_QUIET_TTL_S:-1800}" lim q1=0
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=900
  [ "$((10#$ttl))" -gt 0 ] || return 1
  [[ "$quiet" =~ ^[0-9]+$ ]] || quiet=1800
  quiet=$((10#$quiet)); [ "$quiet" -gt 0 ] && [ "$quiet" -lt 1800 ] && quiet=1800
  case "$head" in ''|-) return 1 ;; esac
  case "$upd" in ''|-) return 1 ;; esac
  [ -r "$f" ] && [ "$(awk -F'\t' 'END { print NR ":" NF }' "$f")" = 1:6 ] || return 1
  IFS=$'\t' read -r h u e a b c < "$f" || return 1
  [ "$h" = "$head" ] && [ "$u" = "$upd" ] && [[ "$e" =~ ^[0-9]+$ ]] || return 1
  for wrc in "$a" "$b" "$c"; do case "$wrc" in ''|'?') return 1 ;; esac; done
  age=$((now - 10#$e)); lim=$((10#$ttl))
  [ "$quiet" -gt "$lim" ] && lim="$quiet"
  [ "$age" -ge 0 ] && [ "$age" -lt "$lim" ] || return 1
  if _swf_fn prs_wake_seen; then
    wrc=0; prs_wake_seen "$repo" checks "$head" "$e" || wrc=$?
    [ "$wrc" = 0 ] && return 1
    [ "$wrc" = 1 ] && q1=1
    wrc=0; prs_wake_seen "$repo" pr "$n" "$e" || wrc=$?
    [ "$wrc" = 0 ] && return 1
    [ "$wrc" = 1 ] || q1=0
  fi
  # Past the TTL only a feed that said "no wake" twice keeps the line.
  [ "$age" -lt "$((10#$ttl))" ] || [ "$q1" = 1 ] || return 1
  printf '%s\t%s\t%s\n' "$a" "$b" "$c"
}

# _swf_cond_read <repo> <outfile> — number\tstate\tsince for every pr_state row
#   on at most 5 pages of 1000. rc 0 = read to the end, 3 = stopped at the
#   bound (a PR missing from the file is unknown, not absent), 1 = failed.
_swf_cond_read() {
  local repo="$1" out="$2" before="" page=0 resp rc n
  : > "$out"
  _swf_fn pr_state_page || return 1
  while [ "$page" -lt 5 ]; do
    page=$((page+1))
    resp=$(pr_state_page 1000 "$before" "$repo"); rc=$?
    case "$rc" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    printf '%s' "$resp" | jq -r '.rows[] | [(.number|tostring), (.state // "-"), (.since // "-")] | @tsv' >> "$out" 2>/dev/null || return 1
    n=$(printf '%s' "$resp" | jq -r '.rows | length' 2>/dev/null)
    before=$(printf '%s' "$resp" | jq -r '.rows[-1].id // empty' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && [[ "$before" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -lt 1000 ] && return 0
  done
  return 3
}

swf_pr_facts() {
  local repo="${1:-}" max="${STUCK_WORK_MAX_ITEMS:-300}" tmp rc=0 total out=0 crc
  local num url draft labels head upd ls lsa v vs va mg cs cc ra da fs line row ci hit now _l
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  _swf_fn gh_rest_pr_list_all && command -v jq >/dev/null 2>&1 || return 1
  # shellcheck source=bin/lib/pr-snapshot.sh
  _swf_fn prs_open_list || { _l="$(dirname "${BASH_SOURCE[0]}")/../pr-snapshot.sh"; [ -r "$_l" ] && . "$_l"; }
  [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || max=300
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/swf-pr.XXXXXX") || return 3
  if _swf_fn prs_open_list; then prs_open_list "$repo" "$tmp/list" || rc=$?
  else gh_rest_pr_list_all "$repo" open 1000 > "$tmp/list" || rc=$?; fi
  if [ "$rc" != 0 ]; then rm -rf "$tmp"; return 3; fi
  # Every field non-empty here, so `read` on tabs cannot slide a column.
  jq -r --argjson max "$max" 'sort_by(.created_at, .number) | length as $n | .[:$max][]
    | [(.number|tostring), (.html_url // "-"), (if .draft then "1" else "0" end),
       ([.labels[]?.name | gsub("[\t\r\n]"; "")] | join(",") | if . == "" then "-" else . end),
       (.head.sha // "-" | if . == "" then "-" else . end),
       (.updated_at // "-" | if . == "" then "-" else . end)] | @tsv' "$tmp/list" > "$tmp/prs" 2>/dev/null \
    && total=$(jq 'length' "$tmp/list" 2>/dev/null) && [[ "$total" =~ ^[0-9]+$ ]] \
    || { rm -rf "$tmp"; return 3; }
  # The list helper stops at 1000 rows: a list that long may not be all of them.
  [ "$total" -gt "$max" ] || [ "$total" -ge 1000 ] && out=3
  [ -s "$tmp/prs" ] || { rm -rf "$tmp"; return "$out"; }
  crc=0; _swf_cond_read "$repo" "$tmp/cond" || crc=$?
  ci=$(_swf_state_dir ci) || ci=""
  now=$(_swf_now)
  while IFS=$'\t' read -r num url draft labels head upd; do
    ls='?'; lsa='?'; mg='?'; hit=""
    if [ -n "$ci" ] && hit=$(_swf_ci_hit "$ci/${repo/\//_}-$num" "$repo" "$num" "$head" "$upd" "$now"); then
      IFS=$'\t' read -r ls lsa mg <<<"$hit"
      _swf_count CI-HIT "$num"
    else
      hit=""; _swf_count CI-MISS "$num"
    fi
    # 6,7 — the lead-verdict commit status on the head.
    if [ -z "$hit" ] && _swf_fn vs_context && _swf_fn gh_rest && [ "$head" != - ] \
       && gh_rest GET "repos/$repo/commits/$head/status" -F per_page=100 > "$tmp/st"; then
      row=$(jq -r --arg c "$(vs_context)" '.statuses | if type == "array" then . else error("no statuses") end
            | map(select(.context == $c)) | if length == 0 then "-\t-" else (.[0] | "\(.state // "?")\t\(.updated_at // "?")") end' "$tmp/st" 2>/dev/null) \
        && [ -n "$row" ] && { ls=${row%%$'\t'*}; lsa=${row#*$'\t'}; [ "$lsa" = - ] || lsa=$(_swf_epoch "$lsa"); }
    fi
    # 8-10 — the standing verdict on THIS head.
    v='?'; vs='?'; va='?'
    if _swf_fn vd_standing && _swf_fn _jobs_req; then
      row=$(vd_standing "$repo" "$num" "$head"); rc=$?
      case "$rc" in
        0) v=$(cut -f1 <<<"$row"); vs=$head; va=$(_swf_epoch "$(cut -f4 <<<"$row")"); [ -n "$v" ] || v='?' ;;
        1) v=-; vs=-; va=- ;;
      esac
    fi
    # 12 — the Mergify phase.
    if [ -z "$hit" ] && _swf_fn mc_mergify_check_live && [ "$head" != - ]; then
      row=$(mc_mergify_check_live "$repo" "$url" "$head") && mg=$(_swf_mergify "$row")
    fi
    # A miss whose three fields all read is cached; a `?` never is.
    if [ -z "$hit" ] && [ -n "$ci" ] && [ "$head" != - ] && [ "$upd" != - ] \
       && [ "$ls" != '?' ] && [ "$lsa" != '?' ] && [ "$mg" != '?' ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$head" "$upd" "$now" "$ls" "$lsa" "$mg" | _swf_put "$ci/${repo/\//_}-$num"
    fi
    # 13,14 — the conductor row.
    cs='?'; cc='?'
    if [ "$crc" = 0 ] || [ "$crc" = 3 ]; then
      row=$(awk -F'\t' -v n="$num" '$1 == n { print $2 "\t" $3; exit }' "$tmp/cond")
      if [ -n "$row" ]; then
        cs=${row%%$'\t'*}; cc=$(_swf_epoch "${row#*$'\t'}")
      elif [ "$crc" = 0 ]; then
        cs=-; cc=-
      fi
    fi
    # 15 — the resolver's claim on this head.
    ra='?'
    if _swf_fn mc_resolver_claim_get && [ -n "${MC_RESOLVER_CLAIM_DIR:-}" ]; then
      if row=$(mc_resolver_claim_get "$repo#$num" "$head"); then ra=$(_swf_epoch "$(cut -f4 <<<"$row")"); else ra=-; fi
    fi
    # 16 — dequeue owner actions, only when something says it was dequeued.
    da=-
    if [[ ",$labels," == *,dequeued,* ]] || [ "$mg" = failed ]; then
      da='?'
      if _swf_fn dqw_actions_list && row=$(dqw_actions_list "$repo" "$num" "$head"); then
        row=$(jq -r '[.rows[]?.updated_at | select(. != null)] | max // "-"' <<<"$row" 2>/dev/null) && [ -n "$row" ] \
          && { if [ "$row" = - ]; then da=-; else da=$(_swf_epoch "$row"); fi; }
      fi
    fi
    # 22 — the clock anchor.
    fs='?'
    if [ "$mg" != '?' ] && _swf_fn sw_first_seen; then
      fs=$(sw_first_seen "$repo#$num|${head:0:12}|$mg")
    fi
    line=""
    for row in pr "$repo#$num" "$url" "$draft" "$labels" "$ls" "$lsa" "$v" "$vs" "$va" "$head" "$mg" \
               "$cs" "$cc" "$ra" "$da" - - - - - "$fs"; do
      line+="${row:--}"$'\t'
    done
    printf '%s\n' "${line%$'\t'}"
  done < "$tmp/prs"
  rm -rf "$tmp"
  return "$out"
}
