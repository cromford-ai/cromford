#!/bin/bash
# bin/lib/plan-thread.sh — THE PLAN THREAD GATE (BH-5799). Sourced; functions
# only. The knob is resolved when a caller asks for it (ptg_enforce).
#
# Twelve review BLOCKs in 300 PRs had one shape: a later comment by the operator or the
# triage changed the scope (a new column, a cadence, "do not merge", an input
# folded in) and the plan built the ticket body anyway. The plan prompt already
# says the newest comment wins; this is the mechanical half. A plan that does
# not cite, by id, a comment that is newer than the plan is refused and planned
# again. On a GitHub-issue project the TICKET_FP gates in bin/lib/rb/plan.sh are
# off (no board fingerprint), so before this nothing compared a reused or
# adopted plan with the thread at all.
#
# WHO COUNTS. A comment counts when its author is a person (`user.type` is not
# Bot; that includes the PAT login, which is also the operator's hand) or one of this
# fleet's own Apps (hs_ours from bin/lib/harness-self.sh, the triage voice).
# A third-party bot never counts. A comment whose normalized body is in this
# build's own-post ledger (ptg_own_post) never counts: the build's replan
# comment and its BUILD BLOCKED notice must not refuse its own plan. A comment
# by one of our Apps whose first non-blank line matches a registered status
# marker (catalog/plan-thread-status-markers.txt, BH-8804) never counts: a
# GATE_RED notice or a stop report is not steering, and before this one
# restarted the build it reported on (#8775). A person's comment never skips.
#
# NEWER. created_at OR updated_at after the plan's stamp: an edit is a new turn.
#
# CITED. plan.md carries the comment's numeric id as a whole token (so
# `#issuecomment-<id>` counts and `1<id>7` does not), or its node_id.
#
# FAIL OPEN. An unreadable thread (a non-zero gh_rest, a page that is not an
# array, more than 1000 comments) is rc 2 and the callers continue with one
# pipeline.log line, the same rule as every other thread gate in plan.sh.
#
# Root: ${HARNESS:-${H:-}} only (D43). No root, no network call: rc 2.
# shellcheck shell=bash

PTG_EPOCH='1970-01-01T00:00:00Z'

# ptg_norm_sha <file> -> sha256 of the body with CR removed, trailing
# whitespace stripped per line, and trailing blank lines dropped.
ptg_norm_sha() {
  tr -d '\r' < "$1" | sed 's/[[:space:]]*$//' \
    | awk '{a[NR]=$0} END{n=NR; while (n>0 && a[n]=="") n--; for (i=1;i<=n;i++) print a[i]}' \
    | sha256sum | cut -d' ' -f1
}

# _ptg_markers -> the catalog EREs that start `^<!-- `, one per line. The
#   catalog is ${PTG_STATUS_MARKERS:-catalog/plan-thread-status-markers.txt};
#   an unreadable one prints nothing (no markers, nothing skipped).
_ptg_markers() {
  local f="${PTG_STATUS_MARKERS:-${BASH_SOURCE[0]%/*}/../../catalog/plan-thread-status-markers.txt}"
  [ -r "$f" ] || return 0
  grep -v -e '^#' -e '^[[:space:]]*$' "$f" 2>/dev/null | cut -f1 | grep -e '^\^<!-- '
  return 0
}

# ptg_classify <plan.md> <since-iso> <comments-json> <apps-json> [<own-sha-file>]
#   PURE: jq, sha256sum and the marker catalog only, no network, no clock.
#   rc 0 `ok<TAB><n> newer by a person or our App, each cited, our own post or a status report, <k> status comment(s) skipped`
#   rc 1 `refuse<TAB><id> <login> <created_at>[; ...]` (five ids, then `+N more`)
#   rc 2 `unreadable<TAB><why>`
ptg_classify() {
  local plan="$1" since="$2" comments="$3" apps="$4" own="${5:-}" cand id login created bodyb64 ours sha n=0 k=0 out="" more=0 tmp mk
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || { printf 'unreadable\tno plan stamp\n'; return 2; }
  [ -r "$plan" ] || { printf 'unreadable\tno plan.md\n'; return 2; }
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || . "${BASH_SOURCE[0]%/*}/harness-self.sh" 2>/dev/null
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || { printf 'unreadable\tno harness-self definition\n'; return 2; }
  # Newer, by a person or our App, and not cited. Bodies ride base64 so a
  # multi-line comment stays one row.
  cand=$(jq -r --arg since "$since" --argjson apps "$apps" --rawfile plan "$plan" "$HARNESS_SELF_JQ_DEF"'
    def cited($c): ($c.id | tostring) as $i
      | ($plan | test("(^|[^0-9A-Za-z_])" + $i + "([^0-9A-Za-z_]|$)"))
        or (($c.node_id // "") as $nd | ($nd | length) >= 8 and ($plan | contains($nd)));
    .[] | select(type == "object" and .id != null)
    | select(((.user.type // "") | ascii_downcase) != "bot" or hs_ours($apps))
    | select((.created_at // "") > $since or (.updated_at // "") > $since)
    | select(cited(.) | not)
    | [(.id | tostring), (.user.login // "unknown"), (.created_at // "unknown"), ((.body // "") | @base64),
       (if ((.user.type // "") | ascii_downcase) == "bot" and hs_ours($apps) then "1" else "0" end)] | @tsv' \
    <<<"$comments" 2>/dev/null) || { printf 'unreadable\tthe thread is not a comment array\n'; return 2; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ptg-body.XXXXXX") || { printf 'unreadable\tno temp file\n'; return 2; }
  mk=$(mktemp "${TMPDIR:-/tmp}/ptg-mk.XXXXXX") || { rm -f "$tmp"; printf 'unreadable\tno temp file\n'; return 2; }
  _ptg_markers > "$mk"
  while IFS=$'\t' read -r id login created bodyb64 ours; do
    [ -n "$id" ] || continue
    if [ -n "$own" ] && [ -s "$own" ]; then
      printf '%s' "$bodyb64" | base64 -d > "$tmp" 2>/dev/null
      sha=$(ptg_norm_sha "$tmp")
      grep -qx "$sha" "$own" && continue
    fi
    # Our App's status report: its first non-blank line is a registered
    # marker. A bad ERE (grep rc 2) is no match.
    if [ "$ours" = 1 ] && [ -s "$mk" ] \
      && printf '%s' "$bodyb64" | base64 -d 2>/dev/null | tr -d '\r' | awk 'NF {print; exit}' | grep -qE -f "$mk" 2>/dev/null; then
      k=$((k+1)); continue
    fi
    n=$((n+1))
    if [ "$n" -le 5 ]; then out="${out:+$out; }$id $login $created"; else more=$((more+1)); fi
  done <<<"$cand"
  rm -f "$tmp" "$mk"
  if [ "$n" -gt 0 ]; then
    [ "$more" -gt 0 ] && out="$out; +$more more"
    printf 'refuse\t%s\n' "$out"; return 1
  fi
  # The count is of the comments the rule judged: newer, by a person or our App.
  n=$(jq --arg since "$since" --argjson apps "$apps" "$HARNESS_SELF_JQ_DEF"'
    [.[] | select(type == "object" and .id != null)
     | select(((.user.type // "") | ascii_downcase) != "bot" or hs_ours($apps))
     | select((.created_at // "") > $since or (.updated_at // "") > $since)] | length' <<<"$comments" 2>/dev/null)
  printf 'ok\t%s newer by a person or our App, each cited, our own post or a status report, %s status comment(s) skipped\n' "${n:-0}" "$k"
  return 0
}

# ptg_check <project> <key> <plan.md> <since-iso> [<own-sha-file>]
#   The network wrapper: rc as ptg_classify, plus `n/a` (rc 0) on an in-app
#   board, whose plans the TICKET_FP gates already compare with the thread.
#   gh_rest is the caller's (bin/lib/gh-rest.sh); without it, rc 2.
ptg_check() {
  local project="$1" key="$2" plan="$3" since="$4" own="${5:-}" root prefix repo issue t page rc acc='[]' apps
  root=${HARNESS:-${H:-}}
  [ -n "$root" ] || { printf 'unreadable\tno harness root\n'; return 2; }
  prefix=$("$root/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null)
  [ -n "$prefix" ] || { printf 'unreadable\tno board prefix for %s\n' "$project"; return 2; }
  [ "$prefix" = "-" ] || { printf 'n/a\tin-app board (TICKET_FP gates cover it)\n'; return 0; }
  repo=$("$root/bin/fleet-conf.sh" "$project" repo 2>/dev/null)
  issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$key")
  [ -n "$repo" ] && [ "$repo" != "-" ] && [ -n "$issue" ] || { printf 'unreadable\tno repo or issue number for %s\n' "$key"; return 2; }
  command -v gh_rest >/dev/null 2>&1 || { printf 'unreadable\tno gh_rest\n'; return 2; }
  t=$(mktemp "${TMPDIR:-/tmp}/ptg-thread.XXXXXX") || { printf 'unreadable\tno temp file\n'; return 2; }
  for page in 1 2 3 4 5 6 7 8 9 10; do
    rc=0; gh_rest GET "repos/$repo/issues/$issue/comments?per_page=100&page=$page" > "$t" 2>/dev/null || rc=$?
    { [ "$rc" = 0 ] && jq -e 'type == "array"' "$t" >/dev/null 2>&1; } \
      || { rm -f "$t"; printf 'unreadable\tpage %s of the thread did not read (rc %s)\n' "$page" "$rc"; return 2; }
    acc=$(jq -sc '.[0] + .[1]' <(printf '%s\n' "$acc") "$t" 2>/dev/null) \
      || { rm -f "$t"; printf 'unreadable\tpage %s did not merge\n' "$page"; return 2; }
    [ "$(jq 'length' "$t")" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$t"; printf 'unreadable\tmore than 1000 comments\n'; return 2; }
  done
  rm -f "$t"
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || . "${BASH_SOURCE[0]%/*}/harness-self.sh" 2>/dev/null
  apps=$(harness_self_apps_json 2>/dev/null); [ -n "$apps" ] || apps='[]'
  ptg_classify "$plan" "$since" "$acc" "$apps" "$own"
}

# ptg_since <build-dir> -> `<since-iso><TAB><source>`; rc 1 when there is none.
#   stamp   plan-thread-at, written before the plan session started;
#   an adopted pre-plan with no stamp (a DB row published before the
#   preplans.thread_at column) cannot say when it read the thread, so every
#   comment counts as newer;
#   any other plan with no stamp (a dir from before BH-5799): plan.md's mtime.
ptg_since() {
  local b="$1" s
  s=$(head -1 "$b/plan-thread-at" 2>/dev/null)
  if [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\tstamp\n' "$s"; return 0
  fi
  case "$(head -1 "$b/preplan-outcome" 2>/dev/null)" in
    HIT*) printf '%s\tadopted pre-plan with no stamp, every comment counts as newer\n' "$PTG_EPOCH"; return 0 ;;
  esac
  s=$(date -u -r "$b/plan.md" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  printf '%s\tno stamp, using plan.md mtime\n' "$s"
}

# ptg_ids <refuse-detail> -> the comment ids, space separated
ptg_ids() {
  printf '%s\n' "$1" | tr ';' '\n' | awk '$1 ~ /^[0-9]+$/ {printf "%s%s", (n++ ? " " : ""), $1}'
}

# ptg_refuse_plan <build-dir> — the refused plan can never be reused: plan.md
#   is moved aside, and the stamp and both fingerprints written with it go.
ptg_refuse_plan() {
  mv -f "$1/plan.md" "$1/plan.md.thread-refused" 2>/dev/null
  rm -f "$1/plan-thread-at" "$1/ticket-fp" "$1/call-fp"
}

# ptg_own_post <build-dir> <bodyfile> — one line in the build's own-post
#   ledger. Call it only after the post returned 0.
ptg_own_post() {
  [ -d "$1" ] && [ -r "$2" ] || return 1
  ptg_norm_sha "$2" >> "$1/own-comments.sha256"
}

# ptg_stamp <file> — the time the plan session starts reading the thread.
ptg_stamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ > "$1"
}

# ptg_enforce -> 1 (refuse) or 0 (warn only). PLAN_THREAD_GATE_ENFORCE is
#   registered in catalog/lanes.d/_lib.plan-thread.json and resolved through
#   lib_env_apply plan-thread in a subshell, the way bin/lib/harness-self.sh
#   does it. Anything but a resolved 0 is 1: the registry default.
ptg_enforce() {
  local v
  v=$(
    exec 3>&1
    _PTG_R=$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd) || exit 0
    command -v lib_env_apply >/dev/null 2>&1 || . "$_PTG_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_PTG_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_PTG_R" 2>/dev/null) && export LANE_REGISTRY
    fi
    trap 'printf "%s" "${PLAN_THREAD_GATE_ENFORCE:-}" >&3' EXIT
    lib_env_apply plan-thread >/dev/null 2>&1)
  [ "$v" = 0 ] && echo 0 || echo 1
}
