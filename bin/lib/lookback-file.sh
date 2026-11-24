#!/bin/bash
# bin/lib/lookback-file.sh — BH-1795.3: lookback_file_harness, the filer
# bin/lookback.sh calls for each cluster whose target is `harness`. Sourced,
# never executed; defining functions is its only effect. The cluster and ledger
# shapes and the rc convention are the ones in bin/lib/lookback-common.sh.
#
# lookback_file_harness <cluster_json> <run_dir> files ONE `ai-build` issue per
# cluster on $LOOKBACK_HARNESS_REPO, or comments on the open one already there:
#   1. ledger row lookback_cluster/<fingerprint>, read FIRST. An outage returns
#      75 and the driver stops all filing (never file blind). A row whose issue
#      is open gets a comment; a closed (or 404) one is remembered as
#      prior_issue and the walk goes on.
#   2. the open issues of the repo, searched for the body marker
#      `<!-- lookback-cluster: <fingerprint> -->` (lowest number wins). A hit
#      gets a comment and the row is written: that is how a row lost after a
#      201 heals.
#   3. POST repos/<repo>/issues. Only a 201 carrying a `number` counts, and only
#      then is the row written. A failed create writes nothing.
# A comment lists only item ids the row (or, with no row, the issue body) does
# not already list; with none new nothing is posted (rc 4). A GitHub read that
# cannot be verified (state, or an open list that failed or hit the 1000-row
# cap) returns 1 for this cluster alone. Links are printed verbatim from the
# bundle or the REST response, never built. Every posted title and body has its
# em dashes replaced by hyphens.
#
# gh-rest: no-graphql
[ "$(type -t gh_rest)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null
[ "$(type -t gh_rest_issue_list)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1
LOOKBACK_HARNESS_REPO="${LOOKBACK_HARNESS_REPO:-$HARNESS_REPO}"

_lookback_dash() { sed 's/—/-/g'; }

# _lookback_evidence <run_dir> <ids_json> — one line per id, from bundle.json.
_lookback_evidence() {
  { cat "$1/bundle.json" 2>/dev/null || echo '{}'; } | jq -r --argjson ids "$2" '
    (.items // []) as $all | $ids[] as $id | ([$all[] | select(.id == $id)][0]) as $x
    | if $x == null then "- `\($id)` (not in this week'"'"'s bundle)"
      else "- `\($id)` " + ([ $x.project,
          (if $x.ticket != null then "ticket: \($x.ticket)" else empty end),
          (if $x.pr != null then "PR: \($x.pr)" else empty end),
          (if ($x.files // []) != [] then "files: \($x.files | join(", "))" else empty end),
          (if $x.lane != null then "lane: \($x.lane)" else empty end),
          (if $x.reason != null then "reason: \($x.reason)" else empty end),
          (if ($x.comment // null) != null then "client comment: \($x.comment.author) (\($x.comment.at)): \($x.comment.text)" else empty end)
        ] | map(select(. != null)) | join(", ")) end'
}

# _lookback_comment <n> <known_ids_json> <filed_at_fallback> — the comment path.
# Reads the caller's locals (repo fp title ids detail status run tmp mark).
_lookback_comment() {
  local n="$1" known="$2" new k lw="" d
  new=$(jq -nc --argjson a "$ids" --argjson k "$known" '[$a[] | select(. as $x | $k | index($x) | not)]')
  k=$(jq 'length' <<<"$new")
  if [ "$k" = 0 ]; then echo "#$n already lists every item"; return 4; fi
  { printf 'This cluster came back this week with %s new item%s.\n\nEvidence:\n' "$k" "$([ "$k" = 1 ] || echo s)"
    _lookback_evidence "$run" "$new"
    printf '\n%s\n' "$mark"; } | _lookback_dash > "$tmp/comment"
  if ! gh_rest_comment "$repo" "$n" "$tmp/comment"; then echo "comment failed #$n (HTTP $GH_REST_STATUS)"; return 1; fi
  d=$(jq -c --arg r "$repo" --argjson n "$n" --argjson all "$(jq -nc --argjson k "$known" --argjson w "$new" '$k + $w')" \
        --argjson c "$cluster" --arg at "$3" '
      {key_kind: $c.key_kind, key_value: $c.key_value, project: $c.project, target: $c.target, filed_at: $at}
      + . + {repo: $r, issue: $n, item_ids: $all, items: ($all | length)}' <<<"$detail")
  job_ledger_put lookback_cluster "$fp" "${status:-filed}" "$d" || lw=" (ledger write failed)"
  echo "#$n $title +$k item$([ "$k" = 1 ] || echo s)$lw"
  return 3
}

lookback_file_harness() {
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lookback-file.XXXXXX") || { echo "no temp dir"; return 1; }
  _lookback_file_harness "$tmp" "$@" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_lookback_file_harness() { # <tmp> <cluster_json> <run_dir>
  local tmp="$1" cluster="${2:-}" run="${3:-}" repo="$LOOKBACK_HARNESS_REPO"
  local fp title ids row="" rrc=0 detail='{}' status="" n="" prior="" rc st len hit known num url d lw="" mark now
  fp=$(jq -r '.fingerprint // ""' <<<"$cluster" 2>/dev/null) || fp=""
  title=$(jq -r '.title // ""' <<<"$cluster" 2>/dev/null | _lookback_dash) || title=""
  ids=$(jq -c 'if (.item_ids | type) == "array" then .item_ids else empty end' <<<"$cluster" 2>/dev/null) || ids=""
  if ! [[ "$fp" =~ ^[A-Za-z0-9_-]+$ ]] || [ -z "$title" ] || [ -z "$ids" ]; then echo "bad cluster $fp"; return 4; fi
  if [ "$(type -t gh_rest)" != function ] || [ "$(type -t gh_rest_issue_list)" != function ]; then
    echo "gh-rest helpers missing"; return 1
  fi
  if [ "$(type -t job_ledger_row)" != function ]; then echo "ledger client missing"; return 75; fi
  mark="<!-- lookback-cluster: $fp -->"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 1. the ledger row, first; an outage is never "no row"
  row=$(job_ledger_row lookback_cluster "$fp") || rrc=$?
  case "$rrc" in
    0) status=$(jq -r '.status // ""' <<<"$row" 2>/dev/null) || status=""
       detail=$(jq -c '.detail | if type == "string" then (fromjson? // {}) else . end
                       | if type == "object" then . else {} end' <<<"$row" 2>/dev/null) || detail='{}'
       [ -n "$detail" ] || detail='{}' ;;
    2) ;;
    *) echo "ledger read failed $fp"; return 75 ;;
  esac
  if [ "$(jq -r '.repo // ""' <<<"$detail")" = "$repo" ]; then
    n=$(jq -r '.issue | numbers' <<<"$detail")
    if [ -n "$n" ]; then
      rc=0
      gh_rest_issue_state "$repo" "$n" > "$tmp/state" || rc=$?
      st=$(cat "$tmp/state" 2>/dev/null)
      if [ "$rc" = 0 ] && [ "$st" = open ]; then
        _lookback_comment "$n" "$(jq -c '.item_ids // [] | if type == "array" then . else [] end' <<<"$detail")" "$now"
        return
      elif [ "$rc" = 44 ] || { [ "$rc" = 0 ] && [ "$st" = closed ]; }; then
        prior=$n
      else
        echo "issue state unverifiable #$n (HTTP $GH_REST_STATUS)"; return 1
      fi
    fi
  fi

  # 2. the marker in an open issue; a partial list proves nothing absent
  rc=0
  gh_rest_issue_list "$repo" open "" 1000 > "$tmp/list" || rc=$?
  len=$(jq 'length' "$tmp/list" 2>/dev/null) || len=""
  if [ "$rc" != 0 ] || ! [[ "$len" =~ ^[0-9]+$ ]]; then echo "open issue list unverifiable (HTTP $GH_REST_STATUS)"; return 1; fi
  if [ "$len" -ge 1000 ]; then echo "open issue list truncated"; return 1; fi
  hit=$(jq -c --arg m "$mark" '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0] // empty' "$tmp/list")
  if [ -n "$hit" ]; then
    n=$(jq -r '.number' <<<"$hit")
    known=$(jq -c --argjson d "$detail" --argjson ids "$ids" '
      (($d.item_ids // []) | if type == "array" then . else [] end) as $row
      | [(.body // "") | scan("`([^`]+)`")[0] | select(. as $x | $ids | index($x))] as $body
      | reduce ($row + $body)[] as $x ([]; if index($x) then . else . + [$x] end)' <<<"$hit")
    _lookback_comment "$n" "$known" "$(jq -r --arg now "$now" '.created_at // $now' <<<"$hit")"
    return
  fi

  # 3. create; only a 201 with a number counts, and only then is the row written
  { jq -r '.cause // ""' <<<"$cluster"
    printf '\nEvidence:\n'
    _lookback_evidence "$run" "$ids"
    printf '\nProposed fix:\n'
    jq -r '.proposed_fix // ""' <<<"$cluster"
    printf '\n%s\n' "$mark"; } | _lookback_dash > "$tmp/body"
  jq -n --arg t "$title" --rawfile b "$tmp/body" '{title: $t, body: $b, labels: ["ai-build"]}' > "$tmp/payload"
  rc=0
  gh_rest POST "repos/$repo/issues" --input "$tmp/payload" > "$tmp/created" || rc=$?
  num=$(jq -e '.number | numbers' "$tmp/created" 2>/dev/null) || num=""
  if [ "$rc" != 0 ] || [ "$GH_REST_STATUS" != 201 ] || [ -z "$num" ]; then
    echo "create failed HTTP $GH_REST_STATUS"; return 1
  fi
  url=$(jq -r '.html_url // ""' "$tmp/created")
  d=$(jq -c --arg r "$repo" --argjson n "$num" --arg u "$url" --arg at "$now" --arg prior "$prior" --argjson ids "$ids" '
      {repo: $r, issue: $n, url: (if $u == "" then null else $u end), filed_at: $at,
       key_kind, key_value, project, target, items: ($ids | length), item_ids: $ids}
      + (if $prior == "" then {} else {prior_issue: ($prior | tonumber)} end)' <<<"$cluster")
  job_ledger_put lookback_cluster "$fp" filed "$d" || lw=" (ledger write failed, step 2 heals next run)"
  echo "#$num $title ($(jq 'length' <<<"$ids") items) $url$lw"
  return 0
}
