#!/bin/bash
# bin/split-watchdog.sh [project...] — BH-1808 (BH-1793.3): the split-family
# watchdog lane. A hub cron lane, bash + REST only, no model call.
#
# WHAT IT DOES. For every project named in SPLIT_WATCHDOG_PROJECTS it finds the
# split families (a parent and the children decomposition filed for it), reads
# each child's state into the 14-column TSV bin/lib/split-watchdog.sh documents,
# and hands that TSV to the contract's two functions:
#   sw_next_step  (bin/lib/split-watchdog.sh)      decides at most ONE step
#   sw_act        (bin/lib/split-watchdog-act.sh)  carries it out
# It never implements a step itself. It never merges, pushes, rebases, writes
# board status or calls a model; the board, GitHub and worker reads it makes
# are GETs.
#
# FAMILIES.
#   in-app board (fleet.conf board_prefix != -): GET <base><prefix>/boards, then
#     /boards/<id>/tickets. A family is a ticket with a non-empty children[]
#     whose own status is not done. Land order is the newest
#     builds/[pool-]<p>-<parentKey>-*/RESULT that starts `DECOMPOSED k1,k2,…`,
#     else children[] order.
#   GitHub board (board_prefix -): candidate parents are the ones a
#     line-anchored `Part of #N` (the bin/decompose-parent-close.sh parse) names
#     in the open issue list and the newest 1000 of all states. The parent must
#     read OPEN through gh_rest_issue_state; closed drops the family, and a read
#     that fails defers it (never read as open or closed). Its children come
#     from the parent's own timeline, and a family whose `Order: i of n` lines
#     are not exactly 1..n is deferred (see gh_families). A body that only
#     MENTIONS #N is not a child. A HOLD counts when its author is the owner by
#     the harness's human-authority rule (gh_holder).
#   At most SPLIT_WATCHDOG_MAX_FAMILIES open families per project per tick, in
#   ascending parent id; the rest count as deferred.
#
# UNKNOWN IS NEVER NONE. A GitHub read that answers rc 44/75, a worker that does
# not answer the queue read, a board list that did not come back: each of those
# fields is `unknown`, or the whole project is deferred, so the decider's rules
# that need them do not fire. deploy_serves_merge is always `unknown`: fleet.conf
# names no version endpoint to probe.
#
# THE TICK. SPLIT_WATCHDOG_TICK_CAP decisions (acted + skipped) per tick; a due
# family past it counts deferred. flags/automerge-disabled is OBSERVE: the
# decision is logged as an `OBSERVE` line and sw_act is not called. sw_act rc 1
# is `worker-unreachable`: nothing else is acted for that project this tick.
# Exactly one summary line per tick goes to logs/split-watchdog.log:
#   <ts> projects=<n> families=<n> acted=<n> skipped=<n> deferred=<n>[ worker-unreachable]
# `skipped` also counts the failed/stalled outcomes and observe decisions.
#
# OFF: flags/lane-off-split-watchdog (bin/harness-ctl.sh off split-watchdog), or
# leave SPLIT_WATCHDOG_PROJECTS empty (the default: the lane walks nothing).
# Registry: catalog/lanes.d/split-watchdog.json. Note:
# docs/notes/2026-09-23-BH-1793-split-watchdog.md.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  . "$SELF/lib/preplan-lib.sh" 2>/dev/null || true
  . "$SELF/lib/split-watchdog.sh" 2>/dev/null || true
  . "$SELF/lib/split-watchdog-act.sh" 2>/dev/null || true
}
# The suite's seam: a file that overrides sw_next_step/sw_act with recorders.
# Sandbox only, and settable:false in the registry, so no settings row reaches it.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${SPLIT_WATCHDOG_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$SPLIT_WATCHDOG_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit split-watchdog
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply split-watchdog
command -v sw_next_step >/dev/null 2>&1 && command -v sw_act >/dev/null 2>&1 || {
  echo "split-watchdog: contract libs missing (bin/lib/split-watchdog*.sh)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "split-watchdog: jq is required" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
exec 9>"$H/locks/split-watchdog.lock" || exit 0
flock -n 9 || exit 0

LOG="$H/logs/split-watchdog.log"
TAB=$'\t'
knum() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
# The tick cap is per TICK, so it is read once at lane level.
TICK_CAP=$(knum "${SPLIT_WATCHDOG_TICK_CAP:-5}" 5)
# automerge-disabled is the pause flag, not a lane_switch switch: read it the way
# merge-sweep does, through flag_active (the pause_flags row, then the file).
# The client is what sw_act acts through, so with no client nothing is acted
# on anyway (worker-unreachable) and OBSERVE has nothing to hold back.
OBSERVE=0; command -v flag_active >/dev/null 2>&1 && flag_active automerge-disabled && OBSERVE=1
HOST_S=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")

if [ $# -gt 0 ]; then PROJECTS=$(printf '%s\n' "$@")
else PROJECTS=$("$SELF/fleet-projects-or-alert.sh" split-watchdog) || exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/split-watchdog.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ── per-child state ─────────────────────────────────────────────────────────
iso_epoch() { # <iso|empty> -> epoch, `-` for empty/null, `unknown` for unparseable
  case "${1:-}" in ''|null|-) printf -- '-'; return 0 ;; esac
  [ -n "$1" ] && date -u -d "$1" +%s 2>/dev/null || printf unknown
}
flat() { local v; v=$(printf '%s' "${1:-}" | tr '\t\r\n' '   '); printf '%s' "${v:--}"; }

# pr_fields <project> <repo> <KEY> -> pr_state \t pr_url \t merged_at \t mergeable \t head_sha
pr_fields() {
  local p="$1" repo="$2" key="$3" d first url="" num="" slug="$2" rc low
  # The newest build record first: FIELD TWO of `PR_CREATED <url> | …`.
  for d in $(ls -1dt "$H/builds/$p-$key"-*/ "$H/builds/pool-$p-$key"-*/ 2>/dev/null); do
    first=$(head -1 "$d/RESULT" 2>/dev/null)
    case "$first" in
      "PR_CREATED http"*|"PR_MERGED http"*) url=$(printf '%s' "$first" | awk '{print $2}'); break ;;
    esac
  done
  if [ -n "$url" ]; then
    num=${url##*/pull/}; num=${num%%[!0-9]*}
    slug=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/.*#\1#p')
    [ -n "$slug" ] || slug="$repo"
  else
    low=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
    rc=0; gh_rest_pr_list "$repo" all "${repo%%/*}:ticket/$low" > "$TMP/prl.json" || rc=$?
    [ "$rc" = 0 ] || { printf 'unknown\t-\tunknown\tunknown\tunknown'; return 0; }
    num=$(jq -r 'if type=="array" then (.[0].number // empty) else "x" end' "$TMP/prl.json" 2>/dev/null)
    [ "$num" = x ] && { printf 'unknown\t-\tunknown\tunknown\tunknown'; return 0; }
    [ -n "$num" ] || { printf 'none\t-\t-\t-\t-'; return 0; }
  fi
  [ -n "$num" ] || { printf 'unknown\t%s\tunknown\tunknown\tunknown' "${url:--}"; return 0; }
  rc=0; gh_rest GET "repos/$slug/pulls/$num" > "$TMP/pr.json" || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type=="object" and has("state")' "$TMP/pr.json" >/dev/null 2>&1; then
    printf 'unknown\t%s\tunknown\tunknown\tunknown' "${url:--}"; return 0
  fi
  jq -r --arg u "$url" '[
      (if .merged_at != null then "merged" elif .state == "closed" then "closed" else "open" end),
      (.html_url // (if $u == "" then "-" else $u end)),
      (.merged_at // "-"),
      (if .mergeable_state == "clean" or .mergeable_state == "dirty" then .mergeable_state else "unknown" end),
      (.head.sha // "unknown") ] | @tsv' "$TMP/pr.json" > "$TMP/pr.tsv" 2>/dev/null \
    || { printf 'unknown\t%s\tunknown\tunknown\tunknown' "${url:--}"; return 0; }
  local st u m mg sha
  IFS="$TAB" read -r st u m mg sha < "$TMP/pr.tsv"
  printf '%s\t%s\t%s\t%s\t%s' "$st" "$u" "$(iso_epoch "$m")" "$mg" "$sha"
}

# lock_field <project> <KEY> -> 0 | 1 | unknown
lock_field() {
  local b f="$H/locks/build-key-$1-$2.lock"
  b=$("$SELF/box-for.sh" "$1" 2>/dev/null | head -1)
  if [ -n "$b" ] && { [ "$b" = local ] || [ "$b" = "$HOST_S" ]; }; then
    [ -e "$f" ] || { printf 0; return 0; }
    if flock -n "$f" true 2>/dev/null; then printf 0; else printf 1; fi
    return 0
  fi
  if [ "$ROUTE" = pool ]; then printf 0; else printf unknown; fi
}

# queue_fields <project> <KEY> -> status \t reason \t finished_epoch
# queue_row's rc contract (0 row, 2 none, 1 outage) over ONE read, because
# queue_row does not print finished_at and the contract needs it.
queue_fields() {
  local resp rc=0 row st rs fin
  resp=$(_jobs_req GET "/api/queue?project=$1&key=$2&limit=1" 2>/dev/null) || rc=$?
  [ "$rc" = 2 ] && { printf 'none\t-\t-'; return 0; }
  [ "$rc" = 0 ] || { printf 'unknown\tunknown\tunknown'; return 0; }
  row=$(printf '%s' "$resp" | jq -r 'if (.queue|type) != "array" then "BAD" else (.queue[0] // empty
          | [ (.status // "unknown"), ((.reason // "-") | tostring | gsub("[\n\t\r]+"; " ")), (.finished_at // "-") ] | @tsv) end' 2>/dev/null) \
    || row=BAD
  [ "$row" = BAD ] && { printf 'unknown\tunknown\tunknown'; return 0; }
  [ -n "$row" ] || { printf 'none\t-\t-'; return 0; }
  IFS="$TAB" read -r st rs fin <<<"$row"
  printf '%s\t%s\t%s' "$st" "$(flat "$rs")" "$(iso_epoch "$fin")"
}

# child_row <project> <repo> <KEY> <ticket_id> <board_status> <waiting>
child_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tunknown\n' "$3" "$4" "$5" "$6" \
    "$(pr_fields "$1" "$2" "$3")" "$(lock_field "$1" "$3")" "$(queue_fields "$1" "$3")"
}

# ── family discovery ────────────────────────────────────────────────────────
# Each writes $TMP/fam.list: `<parent sort id>\t<family label>\t<members file>`,
# one per open family, and prints the number it could not resolve (deferred).
# A members file is `<KEY>\t<ticket_id>\t<board_status>\t<waiting>` per child,
# in land order.

inapp_families() { # <project> <prefix>
  local p="$1" bp="$2" bvar base tok code bid n=0 pid pkey kids dk f k
  : > "$TMP/fam.list"
  bvar=$(grep -oE '^[A-Z_]+_(API|APP)_BASE' "$HENV/$p.env" 2>/dev/null | head -1)
  base=""
  # shellcheck disable=SC1090
  [ -n "$bvar" ] && base=$(set -a; . "$HENV/$p.env" 2>/dev/null; printf '%s' "${!bvar:-}")
  [ -n "$base" ] || base=$("$SELF/fleet-conf.sh" "$p" prod 2>/dev/null)
  tok=$("$SELF/internal-token-for.sh" "$p" 2>/dev/null) || tok=""
  if [ -z "$base" ] || [ "$base" = - ] || [ -z "$tok" ]; then echo 1; return 0; fi
  code=$(curl -s -m 30 -o "$TMP/boards.json" -w '%{http_code}' -H "Authorization: Bearer $tok" \
         "$base$bp/boards" </dev/null 2>/dev/null) || code=000
  [ "$code" = 200 ] || { echo 1; return 0; }
  echo '[]' > "$TMP/all.json"
  for bid in $(jq -r '(.boards? // .) | .[]?.id // empty' "$TMP/boards.json" 2>/dev/null); do
    n=$((n + 1))
    code=$(curl -s -m 30 -o "$TMP/list-$n.json" -w '%{http_code}' -H "Authorization: Bearer $tok" \
           "$base$bp/boards/$bid/tickets" </dev/null 2>/dev/null) || code=000
    # One board that did not answer makes the project's families unknown.
    [ "$code" = 200 ] || { echo 1; : > "$TMP/fam.list"; return 0; }
    jq -s '.[0] + ((.[1].tickets? // .[1]) | if type=="array" then . else [] end)' \
      "$TMP/all.json" "$TMP/list-$n.json" > "$TMP/all2.json" 2>/dev/null && mv "$TMP/all2.json" "$TMP/all.json"
  done
  jq -r '.[] | select(type=="object")
         | select((.children|type)=="array" and (.children|length) > 0)
         | select(((.status // "")|ascii_downcase) != "done")
         | [ (.id|tostring), (.key // (.id|tostring)) ] | @tsv' "$TMP/all.json" 2>/dev/null |
  while IFS="$TAB" read -r pid pkey; do
    f="$TMP/m-$pid"
    # Land order: the newest DECOMPOSED record, else children[] order.
    dk=""
    for d in $(ls -1dt "$H/builds/$p-$pkey"-*/ "$H/builds/pool-$p-$pkey"-*/ 2>/dev/null); do
      first=$(head -1 "$d/RESULT" 2>/dev/null)
      case "$first" in "DECOMPOSED "*) dk=$(printf '%s' "${first#DECOMPOSED }" | tr ',' ' '); break ;; esac
    done
    kids=$(jq -r --arg pid "$pid" '.[] | select((.id|tostring)==$pid) | .children[] | (.key // (.id|tostring))' "$TMP/all.json")
    : > "$f"
    for k in $dk $kids; do
      grep -qxF "$k" <<<"$kids" || continue
      grep -q "^$k$TAB" "$f" && continue
      # waiting: client, needs_clarification, or a child the list did not carry.
      jq -r --arg k "$k" --arg pid "$pid" '
        ([.[] | select(.key == $k or (.id|tostring) == $k)] | first) as $t
        | (.[] | select((.id|tostring)==$pid) | .children[] | select((.key // (.id|tostring)) == $k)) as $c
        | [ $k, (($c.id // $t.id // "-")|tostring),
            (((($t.status // $c.status) // "unknown")|ascii_downcase)),
            (if $t == null then "1"
             elif ($t.waitingOn == "client") or ($t.triageVerdict == "needs_clarification") then "1"
             else "0" end) ] | @tsv' "$TMP/all.json" 2>/dev/null | head -1 >> "$f"
    done
    printf '%s\t%s\t%s\n' "$pid" "$pkey" "$f" >> "$TMP/fam.list"
  done
  echo 0
}

# gh_holder <repo> <comments file> -> rc 0 when a HOLD on the thread is the
# owner's, rc 1 when none is. The harness's human-authority rule
# (bin/lib/block-gate.sh bg_bot_login / bg_reviewer_can_write): never a bot, and
# OWNER, MEMBER or COLLABORATOR; any other association but NONE is asked once
# more, because GitHub reports the fleet owner as CONTRIBUTOR on an org repo. A
# permission read that fails is a hold: unknown is never "not waiting".
gh_holder() {
  local repo="$1" login assoc perm rc
  while IFS="$TAB" read -r login assoc; do
    [ -n "$login" ] || continue
    case "$assoc" in
      OWNER|MEMBER|COLLABORATOR) return 0 ;;
      NONE|'') continue ;;
    esac
    rc=0; gh_rest GET "repos/$repo/collaborators/$login/permission" > "$TMP/perm.json" </dev/null || rc=$?
    [ "$rc" = 0 ] || return 0
    perm=$(jq -r '.permission // empty' "$TMP/perm.json" 2>/dev/null)
    case "$perm" in admin|maintain|write|'') return 0 ;; esac
  done < <(jq -r '.[] | select(type=="object")
      | select((.body // "") | test("^\\s*HOLD\\b"))
      | (.user.login // "") as $l
      | select((.user.type // "") != "Bot" and ($l | endswith("[bot]") | not) and ($l | startswith("app/") | not))
      | [ $l, (.author_association // "") ] | @tsv' "$2" 2>/dev/null)
  return 1
}

# FAMILIES FROM THEIR PARENTS (review of BH-1808). A window over the issue list
# is 1000 rows of issues AND pull requests, which on a busy repo is a few days:
# the stalled families this lane exists for fall out of it first, and one that
# straddles the cut arrives with its first children missing — a child k+1 that
# reads as child 1 and can be enqueued past predecessors that never merged. So:
#   candidates  every parent a line-anchored `Part of #N` names in the OPEN list
#               (complete: a list that reaches the page cap defers the project)
#               and in the newest 1000 of all states (the parents whose children
#               have all closed; older ones are bin/decompose-parent-close.sh's).
#   members     read from the open parent's OWN timeline: each cross-referenced
#               issue of this repo whose body carries `Part of #<parent>`.
#   complete    every member carries `Order: i of n`, one n, and the orders are
#               exactly 1..n. Anything else — a timeline at the page cap too —
#               defers the family (PARTIAL_FAMILY in the lane log), never walks it.
gh_families() { # <project> <repo> <max>
  local p="$1" repo="$2" max="$3" pfx rc parent st got=0 def=0 f n
  : > "$TMP/fam.list"
  pfx=$(preplan_key_prefix "$H" "$p" 2>/dev/null) || pfx=""
  [ -n "$pfx" ] || { echo 0; return 0; }
  rc=0; _gh_rest_list "$repo" issues 1000 '.' -f state=open > "$TMP/open.json" || rc=$?
  [ "$rc" = 0 ] || { echo 1; return 0; }
  n=$(jq 'length' "$TMP/open.json" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 1; return 0 ;; esac
  [ "$n" -lt 1000 ] || { echo 1; return 0; }
  rc=0; gh_rest_issue_list "$repo" all "" 1000 > "$TMP/recent.json" || rc=$?
  [ "$rc" = 0 ] || { echo 1; return 0; }
  jq -r '.[] | select(type=="object" and has("number") and .pull_request == null)
         | (.body // "" | split("\n"))[]
         | capture("^[\\s>*_#-]*part[- ]of\\b[^#]*#(?<n>[0-9]+)"; "i").n' \
    "$TMP/open.json" "$TMP/recent.json" 2>/dev/null | sort -n -u > "$TMP/parents"
  for parent in $(cat "$TMP/parents"); do
    if [ "$got" -ge "$max" ]; then def=$((def + 1)); continue; fi
    rc=0; gh_rest_issue_state "$repo" "$parent" > "$TMP/pst" || rc=$?
    [ "$rc" = 0 ] || { def=$((def + 1)); continue; }
    st=$(cat "$TMP/pst")
    [ "$st" = open ] || continue
    got=$((got + 1))
    rc=0; _gh_rest_list "$repo" "issues/$parent/timeline" 1000 '.' > "$TMP/tl.json" || rc=$?
    n=$(jq 'length' "$TMP/tl.json" 2>/dev/null)
    if [ "$rc" != 0 ] || ! [ "${n:-1000}" -lt 1000 ] 2>/dev/null; then def=$((def + 1)); continue; fi
    # order \t total \t number \t state \t labelled, one per child, or `PARTIAL`.
    jq -r --arg r "$repo" --arg p "$parent" '
        [ .[] | select(type=="object" and .event == "cross-referenced")
          | .source.issue // empty | select(type=="object" and .pull_request == null)
          | select(((.repository.full_name // "") | ascii_downcase) == ($r | ascii_downcase))
          | . as $i | ((.body // "") | split("\n")) as $ls
          | select(any($ls[]; (capture("^[\\s>*_#-]*part[- ]of\\b[^#]*#(?<n>[0-9]+)"; "i").n) == $p))
          | ([ $ls[] | capture("^[\\s>*_#-]*order\\s*:?\\s*(?<i>[0-9]+)\\s+of\\s+(?<n>[0-9]+)"; "i") ] | first) as $o
          | { o: ($o.i // "" | tonumber? // null), t: ($o.n // "" | tonumber? // null),
              n: $i.number, s: ($i.state // "unknown"),
              l: (if any(($i.labels // [])[]; (.name // .) == "ai-build") then "1" else "0" end) } ]
        | unique_by(.n) | sort_by(.o)
        | if length > 0 and all(.[]; .o != null and .t != null) and (map(.t) | unique | length) == 1
             and (map(.o)) == [range(1; .[0].t + 1)]
          then .[] | [ .o, .t, .n, .s, .l ] | map(tostring) | @tsv
          else "PARTIAL" end' "$TMP/tl.json" > "$TMP/kids.tsv" 2>/dev/null || echo PARTIAL > "$TMP/kids.tsv"
    if [ ! -s "$TMP/kids.tsv" ] || grep -qx PARTIAL "$TMP/kids.tsv"; then
      printf '%s PARTIAL_FAMILY %s %s\n' "$(date -u +%FT%TZ)" "$p" "$parent" >> "$LOG"
      def=$((def + 1)); continue
    fi
    f="$TMP/m-$parent"
    while IFS="$TAB" read -r _ _ num cst lab; do
      w=0
      if [ "$cst" = open ]; then
        if [ "$lab" != 1 ]; then w=1
        else
          rc=0; gh_rest_issue_comments "$repo" "$num" 100 > "$TMP/cm.json" </dev/null || rc=$?
          if [ "$rc" != 0 ] || gh_holder "$repo" "$TMP/cm.json"; then w=1; fi
        fi
      fi
      printf '%s\t%s\t%s\t%s\n' "$pfx-$num" "$num" "$cst" "$w"
    done < "$TMP/kids.tsv" > "$f"
    printf '%s\t%s\t%s\n' "$parent" "$parent" "$f" >> "$TMP/fam.list"
  done
  echo "$def"
}

# ── one project, in a subshell so its settings rows never leak into the next ─
# Prints `families acted skipped deferred unreachable` on its last line.
run_project() { # <project> <decisions already spent this tick>
  local p="$1" used="$2" repo bp max def fams=0 acted=0 skipped=0 wu=0 pid label f tsv out step child reason word rc
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply split-watchdog "$p"
  local nmin mmin rre
  nmin=$(knum "${SPLIT_WATCHDOG_N_MIN:-10}" 10)
  mmin=$(knum "${SPLIT_WATCHDOG_RETRY_M_MIN:-30}" 30)
  max=$(knum "${SPLIT_WATCHDOG_MAX_FAMILIES:-25}" 25)
  rre="${SPLIT_WATCHDOG_RETRY_REASONS:-plan session produced no output|PLAN_STALE}"
  repo=$("$SELF/fleet-conf.sh" "$p" repo 2>/dev/null) || repo=""
  bp=$("$SELF/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  ROUTE=box
  if command -v routing_builder >/dev/null 2>&1; then
    [ "$(routing_builder "$p" 2>/dev/null)" = pool ] && ROUTE=pool
  elif flag_on fly-pool "$p"; then ROUTE=pool
  fi
  if [ -n "$bp" ] && [ "$bp" != - ]; then
    def=$(inapp_families "$p" "$bp")
    sort -t "$TAB" -k1,1n "$TMP/fam.list" > "$TMP/fam.sorted"
    # The cap for in-app boards: the list already carries every parent's status.
    awk -v M="$max" 'NR > M {n++} END {print n+0}' "$TMP/fam.sorted" > "$TMP/over"
    def=$((def + $(cat "$TMP/over")))
    head -n "$max" "$TMP/fam.sorted" > "$TMP/fam.list"
  else
    def=$(gh_families "$p" "$repo" "$max")
  fi
  while IFS="$TAB" read -r pid label f; do
    [ -n "$pid" ] || continue
    fams=$((fams + 1))
    if [ "$wu" = 1 ]; then def=$((def + 1)); continue; fi
    tsv="$TMP/fam-$pid.tsv"
    while IFS="$TAB" read -r k tid bst w; do
      child_row "$p" "$repo" "$k" "$tid" "$bst" "$w" </dev/null
    done < "$f" > "$tsv"
    out=$(sw_next_step "$(date +%s)" "$nmin" "$mmin" "$rre" < "$tsv" | head -1)
    [ -n "$out" ] || continue
    if [ $((used + acted + skipped)) -ge "$TICK_CAP" ]; then def=$((def + 1)); continue; fi
    IFS="$TAB" read -r step child reason extra <<<"$out"
    if [ -z "$step" ] || [ -z "$child" ] || [ -z "$reason" ] || [ -n "${extra:-}" ]; then
      printf '%s BAD_DECISION %s %s %s\n' "$(date -u +%FT%TZ)" "$p" "$label" "$(flat "$out")" >> "$LOG"
      skipped=$((skipped + 1)); continue
    fi
    if [ "$OBSERVE" = 1 ]; then
      printf '%s OBSERVE %s %s %s %s %s\n' "$(date -u +%FT%TZ)" "$p" "$label" "$step" "$child" "$reason" >> "$LOG"
      skipped=$((skipped + 1)); continue
    fi
    rc=0; word=$(sw_act "$p" "$label" "$ROUTE" "$step" "$child" "$reason" < "$tsv") || rc=$?
    # The family this happened on is deferred too, so acted+skipped+deferred
    # still adds up to the due families.
    if [ "$rc" = 1 ]; then wu=1; def=$((def + 1)); continue; fi
    case "$(head -1 <<<"$word")" in
      acted) acted=$((acted + 1)) ;;
      *) skipped=$((skipped + 1)) ;;
    esac
  done < "$TMP/fam.list"
  echo "$fams $acted $skipped $def $wu"
}

ENABLED=" $(printf '%s' "${SPLIT_WATCHDOG_PROJECTS:-}" | tr ',' ' ') "
NP=0; NF=0; NA=0; NS=0; ND=0; WU=0
for p in $PROJECTS; do
  case "$ENABLED" in *" $p "*) ;; *) continue ;; esac
  "$SELF/fleet-conf.sh" "$p" repo >/dev/null 2>&1 || continue
  command -v lane_project_held >/dev/null 2>&1 && lane_project_held split-watchdog "$p" && continue
  NP=$((NP + 1))
  res=$( run_project "$p" $((NA + NS)) | tail -1 )
  # A project that died before its count line is unknown, never zero.
  case "$res" in *[0-9]" "*[0-9]" "*[0-9]" "*[0-9]" "[01]) ;; *) ND=$((ND + 1)); continue ;; esac
  read -r f a s d w <<<"$res"
  NF=$((NF + $(knum "$f" 0))); NA=$((NA + $(knum "$a" 0))); NS=$((NS + $(knum "$s" 0)))
  ND=$((ND + $(knum "$d" 0))); [ "${w:-0}" = 1 ] && WU=1
done
printf '%s projects=%d families=%d acted=%d skipped=%d deferred=%d%s\n' "$(date -u +%FT%TZ)" \
  "$NP" "$NF" "$NA" "$NS" "$ND" "$([ "$WU" = 1 ] && printf ' worker-unreachable')" >> "$LOG"
exit 0
