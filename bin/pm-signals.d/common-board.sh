# shellcheck shell=bash
# pm-signals adapter: board tickets and client comments, read only (BH-7259).
# The fleet registry's board_prefix picks the read path:
#   "-"     GitHub Issues on the registry repo, through bin/lib/gh-rest.sh
#           gh_rest GET (no etag cache, 10 s bound). Issues updated in the last
#           30 days (pages 1-3 of 100) and issue comments of the last 30 days
#           (pages 1-3); PR items are dropped. No `gh auth token` = not-configured.
#           A client comment: not a Bot user, and neither the login nor
#           performed_via_github_app is one of the harness's own Apps
#           (HARNESS_SELF_APPS, else its registry default in
#           catalog/lanes.d/_lib.harness-self.json; bin/lib/harness-self.sh is
#           not sourced, because its source-time knob read can call the worker).
#   a path  The in-app board API at <app base var><prefix>, token from the
#           internal token var of $(harness_env_dir)/<project>.env
#           (bin/lib/internal-token.sh names both). The board-creds lib is
#           not used: it writes an ALERTS line on a miss. GET /boards (board 0),
#           GET /boards/<id>/tickets, then GET /tickets/<id> for each ticket
#           active in 30 days, newest first, until half of
#           PM_SIGNALS_ADAPTER_TIMEOUT_S has passed. A client comment: inside
#           30 days, and the author name does not end in "Harness" (any case;
#           every board self actor in bin/triage-gate.sh does). An empty author
#           is not counted.
# Rows: board.status.<status> (status lowercased, [^a-z0-9_] to _),
# board.tickets, board.active_30d (in-app), board.client_comments_30d. A page
# cap, a failed thread read or the deadline makes the metric *_min (a floor).
# Link: the board page, never an API URL with a credential. No registry row,
# no credential = one board.tickets not-configured row; a configured read that
# fails = error rows with value null.
_PMSB_DIR=$(dirname "${BASH_SOURCE[0]}")
. "$_PMSB_DIR/../lib/pm-signals-adapter.sh" || return 1
. "$_PMSB_DIR/../lib/gh-rest.sh" || return 1
. "$_PMSB_DIR/../lib/internal-token.sh" || return 1
. "$_PMSB_DIR/../lib/env-path.sh" || return 1

# _pmsb_status_rows <statuses.json> <metric> <window> <link> — one row per status.
_pmsb_status_rows() {
  local s n
  while IFS=$'\t' read -r s n; do
    [ -n "$s" ] && { _pmsa_row "board.status.$s" board "$2" "$n" "$3" "$4" ok || return 1; }
  done < <(jq -r 'map((. // "unknown") | tostring | ascii_downcase | gsub("[^a-z0-9_]"; "_") | if . == "" then "unknown" else . end)
                  | group_by(.) | .[] | [.[0], length] | @tsv' "$1")
}

_pmsb_self_apps() {
  local list=${HARNESS_SELF_APPS:-}
  [ -n "$list" ] || list=$(jq -r '.libs[]? | select(.id == "harness-self") | .knobs[]? | select(.env == "HARNESS_SELF_APPS") | .default // empty' \
    "$_PMSB_DIR/../../catalog/lanes.d/_lib.harness-self.json" 2>/dev/null)
  printf '%s' "$list" | tr ' ' '\n' | sed 's/^app\///; s/\[bot\]$//' | tr '[:upper:]' '[:lower:]' | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

# _pmsb_gh_pages <path-without-page> <dir> <tag> — pages 1-3 into <dir>/<tag>.json
# (one array). rc 0 all read (prints "cut" when page 3 was full), rc 2 a read failed.
_pmsb_gh_pages() {
  local page rc n cut=""
  for page in 1 2 3; do
    rc=0
    gh_rest GET "$1&page=$page" > "$2/$3.$page" || rc=$?
    [ "$rc" = 0 ] || return 2
    n=$(jq 'if type == "array" then length else -1 end' "$2/$3.$page" 2>/dev/null) || return 2
    [ "$n" -ge 0 ] || return 2
    [ "$n" -lt 100 ] && break
    [ "$page" = 3 ] && cut=1
  done
  jq -s 'add' "$2/$3".[1-3] > "$2/$3.json" 2>/dev/null || return 2
  [ -n "$cut" ] && echo cut
  return 0
}

_pmsb_github() {
  local repo="$1" now="$2" link="https://github.com/$1/issues" since cut d m cutf apps n
  local GH_ETAG=0 GH_REST_TIMEOUT_S=10
  if ! gh auth token >/dev/null 2>&1; then _pmsa_nc board.tickets board tickets 30d "$link"; return; fi
  cut=$((now - 30*86400)); since=$(_pmsa_iso "$cut")
  d=$(mktemp -d "${TMPDIR:-/tmp}/pms-board.XXXXXX") || return 1
  if cutf=$(_pmsb_gh_pages "repos/$repo/issues?state=all&since=$since&per_page=100" "$d" i); then
    m=tickets; [ -n "$cutf" ] && m=tickets_min
    jq 'map(select(.pull_request == null) | .state)' "$d/i.json" > "$d/st.json" || { rm -rf "$d"; return 1; }
    _pmsb_status_rows "$d/st.json" "$m" 30d "$link" || { rm -rf "$d"; return 1; }
    _pmsa_row board.tickets board "$m" "$(jq length "$d/st.json")" 30d "$link" ok || { rm -rf "$d"; return 1; }
  else
    _pmsa_err board.tickets board tickets 30d "$link" || { rm -rf "$d"; return 1; }
  fi
  if cutf=$(_pmsb_gh_pages "repos/$repo/issues/comments?since=$since&per_page=100" "$d" c); then
    m=client_comments; [ -n "$cutf" ] && m=client_comments_min
    apps=$(_pmsb_self_apps)
    n=$(jq --argjson apps "${apps:-[]}" --argjson cut "$cut" --argjson now "$now" '
      [.[] | select((.html_url // "") | contains("/pull/") | not)
           | select(((.user.type // "") | ascii_downcase) != "bot")
           | select(((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) as $l | ($apps | index($l)) == null)
           | select(((.performed_via_github_app.slug // "") | ascii_downcase) as $s | $s == "" or ($apps | index($s)) == null)
           | ((.created_at // "") | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) as $t
           | select($t != null and $t >= $cut and $t <= $now)] | length' "$d/c.json") || { rm -rf "$d"; return 1; }
    _pmsa_row board.client_comments_30d board "$m" "$n" 30d "$link" ok || { rm -rf "$d"; return 1; }
  else
    _pmsa_err board.client_comments_30d board client_comments 30d "$link" || { rm -rf "$d"; return 1; }
  fi
  rm -rf "$d"
}

# _pmsb_get <url> — one in-app board GET; the token rides in a header file.
_pmsb_get() {
  curl -fsS --max-time 5 -H @<(printf 'authorization: Bearer %s\n' "$_PMSB_TOK") -H "User-Agent: curl/8" "$1" 2>/dev/null
}

_pmsb_app() {
  local p="$1" prefix="$2" prod="$3" now="$4" root envf bv tv vals base link d bid cut t0 budget id floor=0 n total=0
  [ "$prod" = - ] && prod=""
  link="$prod$prefix"
  root=$(_pmsa_root); [ -n "$root" ] || { _pmsa_nc board.tickets board tickets now "$link"; return; }
  envf="$(harness_env_dir "$root")/$p.env"
  if [ ! -r "$envf" ] || ! bv=$(app_base_var "$envf") || ! tv=$(internal_token_var "$envf"); then
    _pmsa_nc board.tickets board tickets now "$link"; return
  fi
  vals=$(set -a; . "$envf" >/dev/null 2>&1; printf '%s\n%s' "${!bv:-}" "${!tv:-}")
  base=$(sed -n 1p <<<"$vals"); local _PMSB_TOK; _PMSB_TOK=$(sed -n 2p <<<"$vals")
  if [ -z "$base" ] || [ -z "$_PMSB_TOK" ]; then _pmsa_nc board.tickets board tickets now "$link"; return; fi
  base="${base%/}$prefix"
  t0=${EPOCHREALTIME/./}; budget=$(( ${PM_SIGNALS_ADAPTER_TIMEOUT_S:-30} * 500000 ))
  d=$(mktemp -d "${TMPDIR:-/tmp}/pms-board.XXXXXX") || return 1
  if ! _pmsb_get "$base/boards" > "$d/boards" \
     || ! bid=$(jq -er '(.boards? // .) | .[0].id | strings' "$d/boards" 2>/dev/null) \
     || [[ ! $bid =~ ^[A-Za-z0-9._-]+$ ]] \
     || ! _pmsb_get "$base/boards/$bid/tickets" > "$d/list" \
     || ! jq -e '(.tickets? // .) | arrays' "$d/list" > "$d/tickets" 2>/dev/null; then
    rm -rf "$d"
    _pmsa_err board.tickets board tickets now "$link" || return 1
    _pmsa_err board.client_comments_30d board client_comments 30d "$link" || return 1
    return 0
  fi
  cut=$((now - 30*86400))
  jq 'map(.status)' "$d/tickets" > "$d/st.json" || { rm -rf "$d"; return 1; }
  _pmsb_status_rows "$d/st.json" tickets now "$link" || { rm -rf "$d"; return 1; }
  _pmsa_row board.tickets board tickets "$(jq length "$d/st.json")" now "$link" ok || { rm -rf "$d"; return 1; }
  jq -r --argjson cut "$cut" '
    [.[] | {id: (.id | tostring), t: ((.lastActivityAt // "") | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null)}
         | select(.t != null and .t >= $cut)] | sort_by(-.t) | .[].id' "$d/tickets" > "$d/active" || { rm -rf "$d"; return 1; }
  _pmsa_row board.active_30d board tickets "$(grep -c . "$d/active")" 30d "$link" ok || { rm -rf "$d"; return 1; }
  while IFS= read -r id; do
    if [ $(( ${EPOCHREALTIME/./} - t0 )) -ge "$budget" ]; then floor=1; break; fi
    [[ $id =~ ^[A-Za-z0-9._-]+$ ]] || { floor=1; continue; }
    if ! _pmsb_get "$base/tickets/$id" > "$d/thread" \
       || ! n=$(jq --argjson cut "$cut" --argjson now "$now" '
            [(.comments? // .ticket.comments? // .data.comments? // [])[]?
             | ((if (.author | type) == "object" then (.author.name // "") else (.author // "") end) | tostring) as $a
             | ((.createdAt // .created_at // "") | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) as $t
             | select($a != "" and ($a | ascii_downcase | endswith("harness") | not) and $t != null and $t >= $cut and $t <= $now)]
            | length' "$d/thread" 2>/dev/null); then
      floor=1; continue
    fi
    total=$((total + n))
  done < "$d/active"
  rm -rf "$d"
  if [ "$floor" = 1 ]; then
    _pmsa_row board.client_comments_30d board client_comments_min "$total" 30d "$link" ok
  else
    _pmsa_row board.client_comments_30d board client_comments "$total" 30d "$link" ok
  fi
}

pms_board() {
  local p="$1" prefix repo prod now
  now=$(_pmsa_now)
  if ! prefix=$(_pmsa_fleet "$p" board_prefix); then
    _pmsa_nc board.tickets board tickets now "" || return 1
    return 0
  fi
  if [ "$prefix" = - ]; then
    if ! repo=$(_pmsa_fleet "$p" repo) || [[ ! $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      _pmsa_nc board.tickets board tickets 30d "" || return 1
      return 0
    fi
    _pmsb_github "$repo" "$now"
  else
    prod=$(_pmsa_fleet "$p" prod) || prod=""
    _pmsb_app "$p" "$prefix" "$prod" "$now"
  fi
}
