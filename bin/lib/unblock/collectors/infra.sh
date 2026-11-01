#!/bin/bash
# bin/lib/unblock/collectors/infra.sh — the Tackler infra collector (BH-7725,
# UNB-3). Sourced, never executed. Defines functions and does nothing else.
#
# It prints one JSON stall record per line for the rules in
# catalog/unblock-rules.d: U8 (box restart), U9 (throughput knob), U10 (branch
# fix round) and U12 (the escalation card). 0 model calls. 0 writes.
#
#   unblock_infra_src <name> [arg]   THE ONE INPUT SEAM. rc 0 + the source on
#                                    stdout, rc 1 unreadable (no output).
#     box_health        GET /api/box-health (BH-7710's route, mapped here to
#                       the record view by _unblock_infra_box_view, BH-8553)
#     pool_status <p>   GET /api/pool/status?project=<p>  (#7709's declared shape)
#     setting <key>     GET /api/settings/<key>          (the worker's own route;
#                       a key with no row is 200 {"setting": null})
#     parks             GET /api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=<n>
#                       (BH-8735): the conductor's pr_state ledger rows, which
#                       mc_ledger_put writes on every state change, as the
#                       8-column TSV (key state since head reviewed alerted
#                       reason url) mc_rows_rehydrate builds from the same rows.
#                       A row whose detail does not parse is skipped. A page of
#                       exactly <n> rows (UNBLOCK_PARKS_READ_LIMIT, default
#                       1000) ends with a `#page-full` line.
#     Any answer that is not a 2xx, an empty body or not a JSON object is rc 1.
#     The HTTP reads go through _jobs_req (bin/lib/jobs/req.sh), which the
#     caller loads; without it every HTTP source is rc 1.
#
#   unblock_collect_infra [--project <p>]... [--repo <owner/repo>]
#                         [--family box|pool|park|starve|reach]
#     Prints the records. No --project: the projects of fleet.conf
#     (FLEET_CONF, else $HARNESS/fleet.conf). No --family: all three. rc 0
#     always (rc 2 on a bad argument). An unreadable source is a
#     `source-unreadable` record that names it, never "nothing stalled".
#     With exactly one --project (the tick) every record gets a project and
#     goes to one tick only: a park to its repo's tick (--repo), a box or
#     hub source to the UNBLOCK_HUB_PROJECT tick (BH-8498; see the function).
#
# THE RECORD. Every record carries family "infra", kind, project, subject,
# subject_kind, stall_at (ISO), day (UTC date), truncated and unknown (the
# fields that could not be read; empty when every field read). Kinds:
#   box-hung      one per box whose ssh is not reachable. box, orgo_hosted,
#                 orgo_state, ssh_unreachable_min, envbundle_fail_1h,
#                 last_restart_min_ago, build_claim_10m (null = unknown),
#                 hung_min_threshold (UNBLOCK_BOX_HUNG_MIN, default 30) and
#                 stall_at_hour, the UTC hour of the first unreachable reading.
#                 At most 50 boxes.
#   pool-starved  one per project with queued > 4 x running and a last tick
#                 that stopped on max-ticks, cap or shed. Carries a proposal.
#   respawn-loop  one per ticket key respawned more than UNBLOCK_RESPAWN_MAX_DAY
#                 (default 6) times today with last result PLAN_BLOCKED. The
#                 proposal is lane.fly-pool.<p>.pool_record_read = 1.
#   branch-park   one per parks row (key state since head reviewed alerted
#                 reason url [hold_class]) in BLOCKED_HUMAN whose reason
#                 starts conflict-unresolvable (mechanical_rung failed) or
#                 rebase-gate-red (mechanical_rung n/a). fixrounds is
#                 br_rows_count <url> fixround (bin/lib/br/record.sh, loaded by
#                 the caller); null when that lib is absent or the read fails.
#                 At most 100 rows; a `#page-full` parks page is truncated too.
#   ticket-starved (BH-8390, U13-STARVE)  one per ticket logs/pipeline-health.log
#                 calls "queued <N>m with no spawn" since its last RESOLVED
#                 line, at or over both starve thresholds, that does not wait
#                 on an open parent (see _unblock_infra_starve). --project only.
#   stack-parent-stuck (BH-8766)  one per open parent that a starved ticket
#                 waits on and that has had no progress for
#                 UNBLOCK_STACK_PARENT_STALE_H (24) hours. Subject is the
#                 parent; U12 cards it. --project only; needs --repo and gh_rest.
#   build-reach-blocked (BH-8390, U13-REACH)  one per ticket whose newest
#                 `stranded:` line in logs/<p>.log ends REVIEW_BLOCKED
#                 suite-reach (see _unblock_infra_reach). --project only;
#                 has_pr needs --repo and gh_rest.
#   source-unreadable  one per source that answered rc 1: unknown [<source>].
# A log source (pipeline-health, logs/<p>.log) that exists and cannot be read,
# or whose lines the parser cannot read, is one source-unreadable record.
# A capped family sets truncated: true on every record of that family.
#
# THE PROPOSAL (U9), computed with no model: key, old (the settings row),
# new, min and max (catalog/lanes.d/<lane>.knobs.d/<ENV>.json for a
# lane.<lane>[.<p>].<env> key, else null), in_range (null when a bound or new
# is null), key_allowlisted (a glob match against the unblock.knob_allowlist
# row; null when that row is unreadable), person_set_24h (the row's actor is
# not seed and not tackler:*, and it was updated under 24 h ago; null when
# unreadable) and rollback_note. For pool_tick_max_parallel new is
# min(max, old x 2); old 0 means unlimited and proposes nothing (proposal null).
# G6: a row whose actor starts tackler: is never a person change, and a record
# built from such a row is dropped.
#
# The root is ${HARNESS:-${H:-}} (fleet.conf); no source reads a file under it.

_unblock_infra_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# The clock. UNBLOCK_NOW is the suites' seam, read only in the sandbox.
_unblock_infra_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${UNBLOCK_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s\n' "$UNBLOCK_NOW"
  else date -u +%s; fi
}

# _unblock_infra_int <value> <default> — a non-negative integer, else the default.
_unblock_infra_int() { if [[ ${1:-} =~ ^[0-9]{1,6}$ ]]; then printf '%s' "$((10#$1))"; else printf '%s' "$2"; fi; }

unblock_infra_src() {
  local name="${1:-}" arg="${2:-}" path out lim
  case "$name" in
    parks)
      # Knob: catalog/lanes.d/unblock.knobs.d/UNBLOCK_PARKS_READ_LIMIT.json.
      # 1000 is the route's own page ceiling and the fallback.
      lim=$(_unblock_infra_int "${UNBLOCK_PARKS_READ_LIMIT:-}" 1000)
      { [ "$lim" -ge 101 ] && [ "$lim" -le 1000 ]; } || lim=1000
      path="/api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=$lim" ;;
    box_health) path=/api/box-health ;;
    pool_status) [[ $arg =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1; path="/api/pool/status?project=$arg" ;;
    setting) [[ $arg =~ ^[a-z0-9_.-]{1,64}$ ]] || return 1; path="/api/settings/$arg" ;;
    *) return 1 ;;
  esac
  type _jobs_req >/dev/null 2>&1 || return 1
  out=$(_jobs_req GET "$path" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || return 1
  if [ "$name" = box_health ]; then _unblock_infra_box_view <<<"$out"; return; fi
  if [ "$name" = parks ]; then _unblock_infra_parks_view "$lim" <<<"$out"; return; fi
  printf '%s\n' "$out"
}

# _unblock_infra_parks_view <limit> — a GET /api/ledger list body (stdin) to the
# parks TSV (BH-8735). The projection is mc_rows_rehydrate's MC_REHYDRATE_JQ
# (bin/lib/mc/settle.sh; this file does not source it): `detail` is the JSON
# mc_ledger_put wrote, a row whose detail is not a JSON object emits nothing,
# and tabs and newlines in a field become spaces. rc 1, no output, when the
# body has no ledgers array. A page of exactly <limit> rows ends `#page-full`.
_unblock_infra_parks_view() {
  jq -er --argjson lim "$1" '
    def c(v): (v // "-") | tostring | gsub("[\t\r\n]"; " ") | if . == "" then "-" else . end;
    def ep(v): (v // "") | tostring
      | if test("^[0-9]+$") then .
        elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then (try (fromdateiso8601 | tostring) catch "-")
        else "-" end;
    if (.ledgers | type) != "array" then error("no ledgers array") else . end
    | (.ledgers | length) as $n
    | ((.ledgers[]
        | (try (.detail | fromjson) catch null) as $d
        | select(($d | type) == "object")
        | [ c(.key), c(.status), ep($d.since), c($d.head_sha), c($d.reviewed_sha),
            c($d.alerted), c($d.reason), c($d.url) ]
        | join("\t")),
       (if $n >= $lim then "#page-full" else empty end))' 2>/dev/null
  # -e: an empty page prints nothing and exits 4; that is a read, not an error.
  case $? in 0|4) return 0 ;; *) return 1 ;; esac
}

# _unblock_infra_box_view — the GET /api/box-health body (stdin) to the record
# view _unblock_infra_boxes reads (BH-8553). rc 1, no output, when the body has
# no boxes array or the probe sub-read failed (partial has "ssh"): that is an
# unreadable source, never "every box is fine". A "vm" partial makes the Orgo
# fields null; a "heartbeat" partial changes nothing (U8 reads no heartbeat).
# A box is in the view only with a probe row (ssh.rc an integer) probed no
# more than UNBLOCK_BOX_PROBE_STALE_S ago: a box with no probe row (the hub, no
# tailnet IP) or a stale probe says nothing about now. Per box:
#   ssh_reachable          ssh.rc == 0
#   ssh_unreachable_since  ssh.last_ok_at when rc != 0 (null: never answered)
#   ssh_unreachable_min    whole minutes since last_ok_at (0 when reachable)
#   orgo_hosted/_state     1 live VM: true and its status; 0 live with
#                          vm_complete true: false and null; else null, null
#   envbundle_fail_1h      lane_ssh_failures.count when its window is 1..3600 s
#                          (a lower bound of the 1 h count), else null
#   last_restart_min_ago, build_claim_10m  null: the route does not carry them,
#                          and a restart is never decided on an invented fact.
_unblock_infra_box_view() {
  local stale
  # Knob: catalog/lanes.d/unblock.knobs.d/UNBLOCK_BOX_PROBE_STALE_S.json. 600 is
  # its documented fallback, used for a value that is not 120..86400.
  stale=$(_unblock_infra_int "${UNBLOCK_BOX_PROBE_STALE_S:-}" 600)
  { [ "$stale" -ge 120 ] && [ "$stale" -le 86400 ]; } || stale=600
  jq -ce --argjson now "$_UBI_NOW" --argjson stale "$stale" '
    def ep: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
    select((.boxes | type) == "array" and ((.partial // []) | index("ssh")) == null)
    | (.vm_complete == true) as $vmc
    | {as_of, boxes: [.boxes[]
        | select(type == "object" and (.box | type) == "string" and (.ssh | type) == "object"
                 and (.ssh.rc | type) == "number" and (.ssh.rc | floor) == .ssh.rc)
        | (.ssh.probed_at | ep) as $pt
        | select($pt != null and $now - $pt <= $stale)
        | (.ssh.rc == 0) as $up
        | (if $up then null else .ssh.last_ok_at end) as $since
        | ($since | ep) as $st
        | (if (.vm | type) != "object" or (.vm.live | type) != "array" then [null, null]
           elif (.vm.live | length) == 1 then [true, (.vm.live[0].status // null)]
           elif (.vm.live | length) == 0 and $vmc then [false, null]
           else [null, null] end) as $orgo
        | (.lane_ssh_failures | if type == "object" and (.count | type) == "number"
             and (.window_s | type) == "number" and .window_s >= 1 and .window_s <= 3600
           then .count else null end) as $ebf
        | {name: .box, ssh_reachable: $up,
           ssh_unreachable_since: (if $st == null then null else $since end),
           ssh_unreachable_min: (if $up then 0 elif $st == null then null else ((($now - $st) / 60) | floor) end),
           orgo_hosted: $orgo[0], orgo_state: $orgo[1], envbundle_fail_1h: $ebf,
           last_restart_min_ago: null, build_claim_10m: null}]}' 2>/dev/null || return 1
}

# _unblock_infra_unreadable <source> [project]
_unblock_infra_unreadable() {
  jq -nc --arg s "$1" --arg p "${2:-}" --argjson now "$_UBI_NOW" '($now | todate) as $at
    | {family: "infra", kind: "source-unreadable", project: (if $p == "" then null else $p end),
       subject: ("source:" + $s + (if $p == "" then "" else ":" + $p end)), subject_kind: "lane",
       source: $s, stall_at: $at, day: $at[0:10], truncated: false, unknown: [$s]}'
}

_unblock_infra_boxes() {
  local out thr
  out=$(unblock_infra_src box_health) || { _unblock_infra_unreadable box_health; return 0; }
  thr=$(_unblock_infra_int "${UNBLOCK_BOX_HUNG_MIN:-}" 30)
  jq -c --argjson now "$_UBI_NOW" --argjson thr "$thr" --argjson cap 50 '
    [(.boxes // [])[] | select(type == "object" and (.name | type) == "string" and .ssh_reachable != true)] as $hung
    | ($hung | length > $cap) as $trunc
    | $hung[:$cap][]
    | (if (.ssh_unreachable_since | type) == "string" and (.ssh_unreachable_since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}"))
         then .ssh_unreachable_since
       elif (.ssh_unreachable_min | type) == "number" then (($now - .ssh_unreachable_min * 60) | todate)
       else ($now | todate) end) as $at
    | {family: "infra", kind: "box-hung", project: .project, subject: ("box:" + .name), subject_kind: "box",
       box: .name, orgo_hosted, orgo_state, ssh_reachable, ssh_unreachable_min, envbundle_fail_1h,
       last_restart_min_ago, build_claim_10m, hung_min_threshold: $thr,
       stall_at: $at, stall_at_hour: $at[0:13], day: ($now | todate)[0:10], truncated: $trunc}
    | .unknown = [("orgo_hosted", "orgo_state", "ssh_unreachable_min", "envbundle_fail_1h",
                   "last_restart_min_ago", "build_claim_10m") as $f | select(.[$f] == null) | $f]' <<<"$out" 2>/dev/null \
    || _unblock_infra_unreadable box_health
}

# _unblock_infra_allowlist — read the unblock.knob_allowlist row once per run.
# Sets _UBI_AL_RC (0 read, 1 unreadable) and _UBI_AL (the comma list).
_unblock_infra_allowlist() {
  [ -n "${_UBI_AL_RC:-}" ] && return 0
  local row
  if row=$(unblock_infra_src setting unblock.knob_allowlist); then
    _UBI_AL_RC=0; _UBI_AL=$(jq -r '.setting.value // ""' <<<"$row" 2>/dev/null)
  else
    _UBI_AL_RC=1; _UBI_AL=""
  fi
}

# _unblock_infra_proposal <key> <double|one|none> <why> — sets _UBI_PROP to
# the proposal JSON ("null" for no proposal) and appends unread fields to
# _UBI_UNK. Runs in the caller's shell: never call it in $(...). rc 3 = the
# row is Tackler-authored: drop the record (G6).
_unblock_infra_proposal() {
  local key="$1" mode="$2" why="$3" root row setting="null" old="null" person="null" new="null"
  local min="null" max="null" allowed="null" lane env f g
  _UBI_PROP=null
  if [[ $key =~ ^[a-z0-9_.-]{1,64}$ ]]; then
    if row=$(unblock_infra_src setting "$key"); then
      setting=$(jq -c '.setting // null' <<<"$row" 2>/dev/null) || setting="null"
      if [ "$setting" = null ]; then
        person=false
      else
        case "$(jq -r '.actor // ""' <<<"$setting")" in tackler:*) return 3 ;; esac
        old=$(jq -c '.value | if type == "number" then . elif type == "string" and test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber else null end' <<<"$setting" 2>/dev/null) || old="null"
        person=$(jq -c --argjson now "$_UBI_NOW" '(.actor // "") as $a
          | ((.updated_at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $t
          | if $a == "seed" then false elif $t == null then null else ($now - $t) < 86400 end' <<<"$setting" 2>/dev/null) || person="null"
      fi
    else
      _UBI_UNK+=("setting:$key")
    fi
  fi
  [ "$old" = null ] && _UBI_UNK+=("proposal.old")
  case "$mode" in
    double)
      [ "$old" = 0 ] && return 0
      [ "$old" != null ] && new=$(jq -n --argjson o "$old" '$o * 2') ;;
    one) new=1 ;;
  esac
  root=$(_unblock_infra_root)
  if [ -n "$root" ] && [[ $key =~ ^lane\.([a-z0-9_-]+)\.([a-z0-9_.-]+\.)?([a-z0-9_]+)$ ]]; then
    lane="${BASH_REMATCH[1]}"; env="${BASH_REMATCH[3]}"
    f="$root/catalog/lanes.d/$lane.knobs.d/${env^^}.json"
    if [ -r "$f" ]; then
      min=$(jq -c '.min | if type == "number" then . else null end' "$f" 2>/dev/null) || min="null"
      max=$(jq -c '.max | if type == "number" then . else null end' "$f" 2>/dev/null) || max="null"
    fi
  fi
  [ "$new" != null ] && [ "$max" != null ] && new=$(jq -n --argjson n "$new" --argjson m "$max" '[$n, $m] | min')
  _unblock_infra_allowlist
  if [ "$_UBI_AL_RC" = 0 ]; then
    allowed=false
    local IFS=','
    for g in $_UBI_AL; do
      g="${g// /}"
      [ -n "$g" ] || continue
      # shellcheck disable=SC2053
      [[ $key == $g ]] && { allowed=true; break; }
    done
    unset IFS
  else
    _UBI_UNK+=("unblock.knob_allowlist")
  fi
  _UBI_PROP=$(jq -nc --arg k "$key" --argjson old "$old" --argjson new "$new" --argjson min "$min" --argjson max "$max" \
    --argjson al "$allowed" --argjson ps "$person" --arg why "$why" '
    {key: $k, old: $old, new: $new, min: $min, max: $max,
     in_range: (if ([$new, $min, $max] | all(type == "number")) then ($min <= $new and $new <= $max) else null end),
     key_allowlisted: $al, person_set_24h: $ps,
     rollback_note: (if $old != null and $new != null then "\($why); roll back by setting \($k)=\($old)" else null end)}') || _UBI_PROP=null
}

# _unblock_infra_pool_record <base-json> <proposal-json> — the record, with
# _UBI_UNK as its unknown list.
_unblock_infra_pool_record() {
  local unk
  unk=$(printf '%s\n' "${_UBI_UNK[@]}" | jq -R . | jq -sc 'map(select(. != ""))')
  jq -c --argjson p "$2" --argjson u "$unk" '. + {proposal: $p, unknown: $u}' <<<"$1"
}

_unblock_infra_pools() {
  local p st base key rmax mode rc row
  rmax=$(_unblock_infra_int "${UNBLOCK_RESPAWN_MAX_DAY:-}" 6)
  for p in "$@"; do
    st=$(unblock_infra_src pool_status "$p") || { _unblock_infra_unreadable pool_status "$p"; continue; }
    base=$(jq -c --arg p "$p" --argjson now "$_UBI_NOW" '
      select((.queued | type) == "number" and (.running | type) == "number" and .queued > 4 * .running
             and ((.last_tick.stop // "") | IN("max-ticks", "cap", "shed")))
      | ((.last_tick.at // "") | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then . else ($now | todate) end) as $at
      | {family: "infra", kind: "pool-starved", project: $p, subject: ("pool:" + $p), subject_kind: "lane",
         queued, running, stop: .last_tick.stop, cap: .last_tick.cap, stop_knob: .last_tick.knob,
         stall_at: $at, day: ($now | todate)[0:10], truncated: false}' <<<"$st" 2>/dev/null)
    if [ -n "$base" ]; then
      case "$(jq -r .stop <<<"$base")" in
        max-ticks) key=lane.fly-pool-tick.pool_tick_max_parallel ;;
        shed) key=hub_load.shed ;;
        *) key=$(jq -r '.stop_knob // ""' <<<"$base") ;;
      esac
      _UBI_UNK=()
      if [ -z "$key" ]; then
        _UBI_UNK+=("stop_knob"); _UBI_PROP=null; rc=0
      else
        mode=none; [ "$key" = lane.fly-pool-tick.pool_tick_max_parallel ] && mode=double
        rc=0; _unblock_infra_proposal "$key" "$mode" \
          "pool $p starved: $(jq -r '"\(.queued) queued, \(.running) running, last tick stop \(.stop)"' <<<"$base")" || rc=$?
      fi
      [ "$rc" = 3 ] || _unblock_infra_pool_record "$base" "$_UBI_PROP"
    fi
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      _UBI_UNK=()
      rc=0; _unblock_infra_proposal "lane.fly-pool.$p.pool_record_read" one \
        "$(jq -r '"\(.respawn_key) respawned \(.respawn_count) times today, last result PLAN_BLOCKED"' <<<"$row")" || rc=$?
      [ "$rc" = 3 ] || _unblock_infra_pool_record "$row" "$_UBI_PROP"
    done < <(jq -c --arg p "$p" --argjson now "$_UBI_NOW" --argjson max "$rmax" '
      (.respawns // [])[] | select(type == "object" and (.key | type) == "string" and (.count | type) == "number"
                                   and .count > $max and .last_result == "PLAN_BLOCKED")
      | ((.last_at // "") | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then . else ($now | todate) end) as $at
      | {family: "infra", kind: "respawn-loop", project: $p, subject: ("respawn:" + $p + ":" + .key), subject_kind: "build",
         respawn_key: .key, respawn_count: .count, last_result, respawn_max_day: $max,
         stall_at: $at, day: ($now | todate)[0:10], truncated: false}' <<<"$st" 2>/dev/null)
  done
}

_unblock_infra_parks() {
  local tsv rows n trunc=false key state since head reviewed alerted reason url hold rung fr unk
  tsv=$(unblock_infra_src parks) || { _unblock_infra_unreadable parks; return 0; }
  rows=$(awk -F'\t' '$2 == "BLOCKED_HUMAN" && $1 ~ /^[^#[:space:]]+#[0-9]+$/ && ($7 ~ /^conflict-unresolvable/ || $7 ~ /^rebase-gate-red/)' <<<"$tsv")
  n=$(grep -c . <<<"$rows")
  [ "$n" -gt 100 ] && trunc=true
  grep -qx '#page-full' <<<"$tsv" && trunc=true
  while IFS=$'\t' read -r key state since head reviewed alerted reason url hold; do
    [ -n "$key" ] || continue
    case "$reason" in conflict-unresolvable*) rung=failed ;; *) rung=n/a ;; esac
    fr=""
    if type br_rows_count >/dev/null 2>&1; then fr=$(br_rows_count "$url" fixround 2>/dev/null); fi
    [[ $fr =~ ^[0-9]+$ ]] || fr=null
    unk='[]'; [ "$fr" = null ] && unk='["fixrounds"]'
    jq -nc --arg key "$key" --arg since "$since" --arg head "$head" --arg reason "$reason" --arg url "$url" \
      --arg hold "${hold:-}" --arg rung "$rung" --argjson fr "$fr" --argjson unk "$unk" --argjson tr "$trunc" \
      --argjson now "$_UBI_NOW" '
      (if ($since | test("^[0-9]+$")) then ($since | tonumber | todate) else ($now | todate) end) as $at
      | {family: "infra", kind: "branch-park", project: null, subject: $key, subject_kind: "pr",
         repo: ($key | sub("#[0-9]+$"; "")), pr: ($key | sub("^.*#"; "") | tonumber),
         head: (if $head == "" or $head == "-" then null else $head end), url: $url, park_reason: $reason,
         hold_class: (if $hold == "" then null else $hold end), mechanical_rung: $rung, fixrounds: $fr,
         stall_at: $at, day: ($now | todate)[0:10], truncated: $tr, unknown: $unk}'
  done < <(head -n 100 <<<"$rows")
}

# _unblock_infra_tail <file>: the last UNBLOCK_LOG_SCAN_LINES lines (default
# 5000). rc 0 and nothing when the file does not exist (the lane never wrote
# it on this box); rc 1 when it exists and cannot be read.
_unblock_infra_tail() {
  local n
  [ -e "$1" ] || return 0
  [ -r "$1" ] || return 1
  n=$(_unblock_infra_int "${UNBLOCK_LOG_SCAN_LINES:-}" 5000)
  tail -n "$n" "$1" 2>/dev/null
}

# _unblock_infra_starve <project>... — BH-8390 (U13-STARVE), BH-8766. One
# ticket-starved record per ticket that logs/pipeline-health.log calls
# "queued <N>m with no spawn" since its last RESOLVED line, inside
# UNBLOCK_STARVE_WINDOW_H (6) hours, when BOTH hold: queued_min >= starve_min
# (UNBLOCK_STARVE_MIN, 120) AND passes >= starve_passes (UNBLOCK_STARVE_PASSES,
# 3). A ticket under either threshold is not starved yet: no record, one
# `starve-skip` line. A ticket over both whose newest pool record is a
# dependency wait (_unblock_infra_dep_wait) on a parent that is open, or whose
# state cannot be read, is waiting, not starved: no record, one `starve-skip`
# line. An unread parent, or a list over UNBLOCK_STACK_PARENT_MAX parents,
# holds the record only while queued_min < UNBLOCK_STACK_PARENT_STALE_H * 60;
# then it goes out with dep_unread (the parent, or `over <n> parents`). An
# open parent idle UNBLOCK_STACK_PARENT_STALE_H hours or more is ONE
# stack-parent-stuck record per parent (its waiting children folded).
# Fields: ticket, queued_min (the newest pass), passes, first_at, last_at,
# starve_min, starve_passes, triage_out (a logs/<p>.triage-<KEY>.out newer
# than the first pass), day.
_unblock_infra_starve() {
  local root txt win smin spass stale p key out qm np deps src par pk st idle why unread bp
  local -a pars
  local -A stuck_kids=() stuck_src=()
  # An unread log is one source-unreadable record PER project asked about, so
  # each project's tick sees it (a record with no project goes only to the
  # hub project's tick, BH-8498).
  root=$(_unblock_infra_root)
  if [ -z "$root" ] || ! txt=$(_unblock_infra_tail "$root/logs/pipeline-health.log"); then
    for p in "$@"; do _unblock_infra_unreadable pipeline_health_log "$p"; done
    return 0
  fi
  [ -n "$txt" ] || return 0
  win=$(_unblock_infra_int "${UNBLOCK_STARVE_WINDOW_H:-}" 6)
  smin=$(_unblock_infra_int "${UNBLOCK_STARVE_MIN:-}" 120)
  spass=$(_unblock_infra_int "${UNBLOCK_STARVE_PASSES:-}" 3)
  # Knob: catalog/lanes.d/unblock.knobs.d/UNBLOCK_STACK_PARENT_STALE_H.json. 24
  # (the STACK_WAIT_CAP_H default) is its documented fallback, used for a value
  # that is not 1..336.
  stale=$(_unblock_infra_int "${UNBLOCK_STACK_PARENT_STALE_H:-}" 24)
  { [ "$stale" -ge 1 ] && [ "$stale" -le 336 ]; } || stale=24
  declare -gA _UBI_PS=()
  local recs
  for p in "$@"; do
    stuck_kids=(); stuck_src=()
    # A project with a product board (fleet.conf board_prefix not `-`) keys its
    # tickets on the board, not on GitHub issue numbers: no parent read there.
    bp=$("$root/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
    recs=$(jq -Rnc --arg p "$p" --argjson now "$_UBI_NOW" --argjson win "$win" --argjson smin "$smin" --argjson spass "$spass" '
      def ep($a): ($a | sub(" "; "T") + "Z" | fromdateiso8601);
      [inputs | (capture("^(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})Z (?<p>[A-Za-z0-9._-]+) (?<key>[A-Za-z0-9.-]+) queued (?<min>[0-9]+)m with no spawn") | . + {ev: "q"}),
                (capture("^(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})Z RESOLVED stuckqueue:(?<p>[A-Za-z0-9._-]+):(?<key>[A-Za-z0-9.-]+)\\.json") | . + {ev: "r"})
       | select(.p == $p) | . + {t: ep(.at)} | select(.t >= $now - $win * 3600)]
      | group_by(.key)[] | sort_by(.t)
      | (map(.ev) | rindex("r")) as $r
      | (if $r == null then . else .[($r + 1):] end) as $q
      | select(($q | length) > 0)
      | {family: "infra", kind: "ticket-starved", project: $p, subject: ("ticket:" + $p + ":" + $q[0].key), subject_kind: "build",
         ticket: $q[0].key, queued_min: ($q | last | .min | tonumber), passes: ($q | length),
         first_at: ($q[0].at + "Z"), last_at: ($q | last | .at + "Z"), first_epoch: $q[0].t,
         starve_min: $smin, starve_passes: $spass, window_h: $win,
         stall_at: (($q[0].t) | todate), day: ($now | todate)[0:10], truncated: false, unknown: []}' <<<"$txt" 2>/dev/null) || { _unblock_infra_unreadable pipeline_health_log "$p"; continue; }
    while IFS= read -r out; do
      [ -n "$out" ] || continue
      read -r key qm np < <(jq -r '"\(.ticket) \(.queued_min) \(.passes)"' <<<"$out")
      if [ "$qm" -lt "$smin" ] || [ "$np" -lt "$spass" ]; then
        _unblock_infra_skip "$p" "$key" "under thresholds (${qm}m of $smin, $np of $spass passes)"
        continue
      fi
      deps=$(_unblock_infra_dep_wait "$p" "$key")
      unread=""
      if [ -n "$deps" ]; then
        src=${deps%% *}; read -r -a pars <<<"${deps#* }"
        why=""
        if [ "${pars[0]}" = OVER ]; then
          # Over UNBLOCK_STACK_PARENT_MAX parents: none is read, and the list
          # is unread, never "no dependency".
          why="waits on over $(_unblock_infra_parent_max) parents: not read"; unread="over ${pars[1]} parents"; pars=()
        fi
        for par in "${pars[@]}"; do
          _unblock_infra_parent_state "${_UBI_REPO:-}" "$par" "$bp"
          read -r st _ <<<"${_UBI_PS[$par]}"
          [ "$st" = open ] || continue
          read -r _ _ idle pk _ <<<"${_UBI_PS[$par]}"
          [ -n "$why" ] || why="waits on open parent $par$([ "$pk" != - ] && printf ' (PR #%s)' "$pk"), idle ${idle}h of ${stale}h"
          if [ "$idle" -ge "$stale" ]; then
            stuck_kids[$par]="${stuck_kids[$par]:+${stuck_kids[$par]} }$key"
            [ -n "${stuck_src[$par]:-}" ] || stuck_src[$par]=$src
          fi
        done
        if [ -z "$why" ]; then
          for par in "${pars[@]}"; do
            read -r st _ <<<"${_UBI_PS[$par]}"
            [ "$st" = unread ] && { why="waits on parent $par: state unread"; unread=$par; break; }
          done
        fi
        # An unread parent (or list) holds the record only until the ticket
        # has been queued UNBLOCK_STACK_PARENT_STALE_H hours: past that the
        # record goes out with dep_unread, so a lasting read failure pages.
        if [ -n "$unread" ] && [ "$qm" -ge $((stale * 60)) ]; then why=""
        else unread=""; fi
        # Every parent read closed: not a wait, the record stands.
        if [ -n "$why" ]; then _unblock_infra_skip "$p" "$key" "$why"; continue; fi
      fi
      local tf="$root/logs/$p.triage-$key.out" to=false first
      first=$(jq -r .first_epoch <<<"$out")
      if [ -e "$tf" ]; then
        if [ "$(stat -c %Y "$tf" 2>/dev/null || stat -f %m "$tf" 2>/dev/null || echo 0)" -ge "$first" ]; then to=true; fi
      fi
      jq -c --argjson to "$to" --arg du "$unread" 'del(.first_epoch) + {triage_out: $to}
        + (if $du == "" then {} else {dep_unread: $du} end)' <<<"$out"
    done <<<"$recs"
    for par in "${!stuck_kids[@]}"; do
      read -r _ _ idle pk url head <<<"${_UBI_PS[$par]}"
      jq -nc --arg p "$p" --arg repo "${_UBI_REPO:-}" --arg par "$par" --arg pk "$pk" --arg url "$url" --arg head "$head" \
        --argjson idle "$idle" --argjson stale "$stale" --arg kids "${stuck_kids[$par]}" --arg src "${stuck_src[$par]}" \
        --argjson now "$_UBI_NOW" '
        def opt($v): if $v == "-" then null else $v end;
        ($now | todate) as $at
        | {family: "infra", kind: "stack-parent-stuck", project: $p, repo: (if $repo == "" then null else $repo end),
           subject: ("ticket:" + $p + ":" + $par), subject_kind: "build", parent: $par,
           parent_issue: ($par | sub("^.*-"; "") | tonumber), parent_pr: (opt($pk) | if . == null then null else tonumber end),
           parent_pr_url: opt($url), head: opt($head), parent_idle_h: $idle, parent_stale_h: $stale,
           children: ($kids | split(" ") | unique), dep_source: $src,
           stall_at: (($now - $idle * 3600) | todate), day: $at[0:10], truncated: false, unknown: []}'
    done
  done
}

# _unblock_infra_skip <project> <KEY> <reason> — the one `starve-skip` line per
# ticket per tick, through the tick's logger (ubt_log, bin/unblock.sh); with no
# tick logger it goes to stderr, never nowhere.
_unblock_infra_skip() {
  if declare -F ubt_log >/dev/null; then ubt_log "starve-skip $1 $2: $3"
  else printf 'starve-skip %s %s: %s\n' "$1" "$2" "$3" >&2; fi
}

# _unblock_infra_dep_wait <project> <KEY> — BH-8766. Prints `<source>
# <PARENT>...` when the ticket's newest pool record (builds/pool-<p>-<KEY>-*/,
# greatest RESULT mtime: plan-blocked-stop.sh _pbs_newest's rule) is a
# dependency wait, else nothing:
#   after       plan-blocked.after (plan-blocked-stop.sh `After: <KEY>` lines)
#               and no plan-blocked.released
#   stack-wait  RESULT starts `BUILD_DEFERRED stack-wait` and holds
#               `Blocked-by #<n>` (bin/lib/rb/gates.sh)
# A parent token loses a leading #; a bare number N is <child prefix>-N; any
# shape but <PREFIX>-<digits> is dropped. Over UNBLOCK_STACK_PARENT_MAX
# distinct parents it prints `<source> OVER <count>` instead: the caller reads
# no parent and treats the list as unread, never as "no dependency".
_unblock_infra_dep_wait() {
  local p="$1" key="$2" root f mt nt=-1 newest="" line tok src="" pfx out=""
  local -a toks=()
  root=$(_unblock_infra_root); [ -n "$root" ] || return 0
  for f in "$root/builds/pool-$p-$key-"*/RESULT; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mt" -ge "$nt" ] && { nt=$mt; newest="${f%/RESULT}"; }
  done
  [ -n "$newest" ] || return 0
  if [ -e "$newest/plan-blocked.after" ] && [ ! -e "$newest/plan-blocked.released" ]; then
    src=after
    while IFS= read -r line; do
      [[ $line =~ ^After:[[:space:]]*([^[:space:]]+) ]] && toks+=("${BASH_REMATCH[1]}")
    done < "$newest/plan-blocked.after"
  else
    line=$(head -n1 "$newest/RESULT" 2>/dev/null)
    if [[ $line == "BUILD_DEFERRED stack-wait"* ]] && [[ $line =~ Blocked-by[[:space:]]+#([0-9]+) ]]; then
      src=stack-wait; toks=("${BASH_REMATCH[1]}")
    fi
  fi
  [ -n "$src" ] || return 0
  pfx=${key%-*}; [ "$pfx" != "$key" ] || pfx=""
  local n=0
  for tok in "${toks[@]}"; do
    tok=${tok#\#}
    if [[ $tok =~ ^[0-9]+$ ]]; then [ -n "$pfx" ] || continue; tok="$pfx-$tok"
    elif ! [[ $tok =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]]; then continue; fi
    case " $out " in *" $tok "*) continue ;; esac
    out="${out:+$out }$tok"; n=$((n + 1))
  done
  [ -n "$out" ] || return 0
  if [ "$n" -gt "$(_unblock_infra_parent_max)" ]; then printf '%s OVER %s\n' "$src" "$n"
  else printf '%s %s\n' "$src" "$out"; fi
  return 0
}

# _unblock_infra_parent_max — the parent cap. Knob:
# catalog/lanes.d/unblock.knobs.d/UNBLOCK_STACK_PARENT_MAX.json. 5 is its
# documented fallback, used for a value that is not 1..50.
_unblock_infra_parent_max() {
  local m
  m=$(_unblock_infra_int "${UNBLOCK_STACK_PARENT_MAX:-}" 5)
  { [ "$m" -ge 1 ] && [ "$m" -le 50 ]; } || m=5
  printf '%s' "$m"
}

# _unblock_infra_parent_state <repo> <PARENT> [<board_prefix>] — BH-8766. Sets
# _UBI_PS[<PARENT>] to `<state> <progress_epoch> <idle_h> <pr> <pr_url>
# <head>` (`-` for a missing value). state is open, closed or unread: no
# repo, no gh_rest or _UBI_TMP, a failed read or a body that is not the issue object is
# unread, never closed. A board_prefix that is set and not `-` (a product-board
# project: its keys are not GitHub issue numbers) is unread with no gh call. When open, the PR is the open one from
# ticket/<parent lowercased> (_unblock_infra_reach's query); progress is that
# PR's updated_at, else the issue's. Cached in _UBI_PS for the call. Runs in
# the caller's shell: never call it in $(...).
_unblock_infra_parent_state() {
  local repo="$1" par="$2" bp="${3:-}" root n body st up pr=- url=- head=- pu prs pt
  [ -n "${_UBI_PS[$par]+x}" ] && return 0
  _UBI_PS[$par]="unread - - - - -"
  [ -n "$bp" ] && [ "$bp" != - ] && return 0
  n=${par##*-}; root=$(_unblock_infra_root)
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ $n =~ ^[0-9]+$ ]] || return 0
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || { [ -n "$root" ] && . "$root/bin/lib/gh-rest.sh" 2>/dev/null; } || true
  declare -F gh_rest >/dev/null && [ -d "${_UBI_TMP:-}" ] || return 0
  gh_rest GET "repos/$repo/issues/$n" > "$_UBI_TMP/parent-issue.json" 2>/dev/null || return 0
  body=$(cat "$_UBI_TMP/parent-issue.json")
  read -r st up < <(jq -r 'if type == "object" and (.state == "open" or .state == "closed") and (.updated_at | type) == "string"
      then "\(.state) \(.updated_at | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch "-")" else "- -" end' <<<"$body" 2>/dev/null)
  case "$st" in open|closed) ;; *) return 0 ;; esac
  if [ "$st" = closed ]; then _UBI_PS[$par]="closed - - - - -"; return 0; fi
  [[ $up =~ ^[0-9]+$ ]] || return 0
  gh_rest GET "repos/$repo/pulls?state=open&head=${repo%%/*}:ticket/$(printf '%s' "$par" | tr '[:upper:]' '[:lower:]')&per_page=10" > "$_UBI_TMP/parent-pr.json" 2>/dev/null || return 0
  prs=$(cat "$_UBI_TMP/parent-pr.json")
  read -r pr url head pu < <(jq -r 'if type != "array" then "x" elif length == 0 then "- - - -"
      else (sort_by(.updated_at) | last) as $q
        | "\($q.number // "-") \($q.html_url // "-") \($q.head.sha // "-") \(($q.updated_at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch "-")" end' <<<"$prs" 2>/dev/null)
  [ "$pr" = x ] || [ -z "$pr" ] && return 0
  pt=$up; [[ $pu =~ ^[0-9]+$ ]] && pt=$pu
  _UBI_PS[$par]="open $pt $(( (_UBI_NOW - pt) / 3600 < 0 ? 0 : (_UBI_NOW - pt) / 3600 )) $pr $url $head"
}

# _unblock_infra_reach <project> <repo> — BH-8390 (U13-REACH, the #8481
# case). One build-reach-blocked record per ticket whose newest `stranded:`
# line in logs/<p>.log says its build ended REVIEW_BLOCKED suite-reach (the
# execute stage's gate: no PR was opened). Fields: ticket, issue, suites (the
# tests/*.sh the line names), detail (at most UNBLOCK_DETAIL_MAX_CHARS, 400),
# stranded_at,
# age_min, reach_stuck_min (UNBLOCK_REACH_STUCK_MIN, 45), has_pr (an open PR
# from ticket/<key lowercased>; null unread), day.
_unblock_infra_reach() {
  local p="$1" repo="${2:-}" root txt rec key br hp owner
  root=$(_unblock_infra_root); [ -n "$root" ] || { _unblock_infra_unreadable project_log "$p"; return 0; }
  txt=$(_unblock_infra_tail "$root/logs/$p.log") || { _unblock_infra_unreadable project_log "$p"; return 0; }
  [ -n "$txt" ] || return 0
  local recs
  recs=$(jq -Rnc --arg p "$p" --argjson now "$_UBI_NOW" --argjson stuck "$(_unblock_infra_int "${UNBLOCK_REACH_STUCK_MIN:-}" 45)" --argjson dmax "$(_unblock_infra_int "${UNBLOCK_DETAIL_MAX_CHARS:-}" 400)" '
    def ep($a): ($a | sub(" "; "T") + "Z" | fromdateiso8601);
    [inputs | capture("^(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})Z \\[[^\\]]*\\] stranded: (?<key>[A-Za-z0-9.-]+) \\(issue #(?<issue>[0-9]+)\\)(?<rest>.*)$")]
    | group_by(.key)[] | sort_by(.at) | last
    | select(.rest | test("REVIEW_BLOCKED suite-reach"))
    | (.rest | sub("^.*REVIEW_BLOCKED suite-reach: "; "")) as $detail
    | {family: "infra", kind: "build-reach-blocked", project: $p, subject: ("ticket:" + $p + ":" + .key), subject_kind: "build",
       ticket: .key, issue: (.issue | tonumber), suites: ([$detail | scan("tests/[A-Za-z0-9._/-]+\\.sh")] | unique),
       detail: $detail[0:$dmax], stranded_at: (.at + "Z"), age_min: ((($now - ep(.at)) / 60) | floor),
       reach_stuck_min: $stuck, stall_at: (.at + "Z"), day: ($now | todate)[0:10], truncated: false}' <<<"$txt" 2>/dev/null) || { _unblock_infra_unreadable project_log "$p"; return 0; }
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || . "$root/bin/lib/gh-rest.sh" 2>/dev/null || true
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    key=$(jq -r .ticket <<<"$rec"); hp=null
    br="ticket/$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"; owner="${repo%%/*}"
    if [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && declare -F gh_rest >/dev/null \
       && gh_rest GET "repos/$repo/pulls?state=open&head=$owner:$br&per_page=10" > "$_UBI_TMP/reach-pr.json" 2>/dev/null; then
      hp=$(jq -c 'if type == "array" then length > 0 else null end' "$_UBI_TMP/reach-pr.json" 2>/dev/null) || hp=null
    fi
    jq -c --argjson hp "$hp" '. + {has_pr: $hp, unknown: (if $hp == null then ["has_pr"] else [] end)}' <<<"$rec"
  done <<<"$recs"
}

unblock_collect_infra() {
  local fam="" repo="" hub tmp
  local -a projects=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) [ -n "${2:-}" ] || return 2; projects+=("$2"); shift ;;
      --repo) [ -n "${2:-}" ] || return 2; repo="$2"; shift ;;
      --family) case "${2:-}" in box|pool|park|starve|reach) fam="$2" ;; *) return 2 ;; esac; shift ;;
      *) return 2 ;;
    esac
    shift
  done
  _UBI_NOW=$(_unblock_infra_now); _UBI_AL_RC=""; _UBI_AL=""
  if [ "${#projects[@]}" != 1 ]; then
    _unblock_collect_infra_body "$fam" "${projects[@]}"
    return 0
  fi
  # ONE --project (the tick's contract call, BH-8498). The claim route refuses
  # a decision with no project (2026-10-26: 6 x 400 project), and the tick
  # runs once per project, so each record goes to exactly one tick:
  #   branch-park  the parks ledger is fleet-wide: a park is kept only in the tick
  #                of its own repo (--repo, compared case-blind) and takes that
  #                tick's project. Another repo's park is its own tick's. No
  #                --repo keeps no park.
  #   box-hung, and a source-unreadable record with no project (box_health,
  #                parks): hub-wide, so they are emitted only in the tick whose
  #                project is UNBLOCK_HUB_PROJECT (default cromford), and
  #                a null project becomes that knob, never the tick's.
  #   the rest     (pool records) carry their own project and pass unchanged.
  # Every line is parsed on its own: a line that is not a JSON object is
  # dropped and counted, the lines after it still pass, and one
  # source-unreadable record (subject source:collect:<p>) says so. A filter
  # that fails is the same record, never a clean collect.
  hub="${UNBLOCK_HUB_PROJECT:-}"
  [[ $hub =~ ^[A-Za-z0-9._-]{1,64}$ ]] || hub=cromford
  # The body runs in this shell (a redirect, not a pipe), so the globals it
  # sets (_UBI_AL*) outlive it.
  tmp=$(mktemp "${TMPDIR:-/tmp}/ubi.XXXXXX") || { _unblock_infra_unreadable collect "${projects[0]}"; return 0; }
  _unblock_collect_infra_body "$fam" "${projects[0]}" > "$tmp"
  jq -R -n -c --arg p "${projects[0]}" --arg repo "$repo" --arg hub "$hub" --argjson now "$_UBI_NOW" '
    [inputs | select(test("\\S")) | (try fromjson catch null)] as $all
    | ([$all[] | select(type != "object")] | length) as $bad
    | ($all[] | select(type == "object")
       | if .kind == "branch-park" then
           select($repo != "" and ((.repo // "") | ascii_downcase) == ($repo | ascii_downcase)) | .project = $p
         elif .kind == "box-hung" or (.kind == "source-unreadable" and .project == null) then
           select($p == $hub) | .project = (.project // $hub)
         else . end),
      (if $bad > 0 then
         ($now | todate) as $at
         | {family: "infra", kind: "source-unreadable", project: $p, subject: ("source:collect:" + $p),
            subject_kind: "lane", source: "collect", bad_lines: $bad, stall_at: $at, day: $at[0:10],
            truncated: false, unknown: ["collect"]}
       else empty end)' < "$tmp" 2>/dev/null \
    || _unblock_infra_unreadable collect "${projects[0]}"
  rm -f "$tmp"
  return 0
}

# _unblock_collect_infra_body <family|''> [project...] — the record readers.
_unblock_collect_infra_body() {
  local fam="$1" p conf root
  shift
  _UBI_REPO="${repo:-}"
  local -a projects=("$@")
  case "$fam" in ''|box) _unblock_infra_boxes ;; esac
  case "$fam" in ''|pool)
    if [ "${#projects[@]}" = 0 ]; then
      root=$(_unblock_infra_root); conf="${FLEET_CONF:-${root:+$root/fleet.conf}}"
      if [ -n "$conf" ] && [ -r "$conf" ]; then
        while read -r p _; do
          case "$p" in ''|'#'*) continue ;; esac
          projects+=("$p")
        done < "$conf"
      else
        _unblock_infra_unreadable fleet_conf
      fi
    fi
    [ "${#projects[@]}" = 0 ] || _unblock_infra_pools "${projects[@]}" ;;
  esac
  case "$fam" in ''|park) _unblock_infra_parks ;; esac
  case "$fam" in ''|starve|reach)
    _UBI_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ubi.XXXXXX") || return 0
    if [ "${#projects[@]}" -gt 0 ]; then
      case "$fam" in ''|starve) _unblock_infra_starve "${projects[@]}" ;; esac
      case "$fam" in ''|reach) for p in "${projects[@]}"; do _unblock_infra_reach "$p" "$repo"; done ;; esac
    fi
    rm -rf "$_UBI_TMP" ;;
  esac
  return 0
}

# ub_collect_infra <project> <repo> — the UNB-0 collector contract entry
# (bin/lib/unblock/collect.sh calls ub_collect_<family> with these two args).
# Without it the tick logged "unwired infra (no ub_collect_infra defined)"
# and collected nothing (2026-10-26). <repo> picks this tick's parks out of
# the fleet-wide parks ledger (BH-8498, BH-8735) and gives build-reach-blocked its
# has_pr read (BH-8390); `-` or empty keeps none.
ub_collect_infra() {
  [ -n "${1:-}" ] || return 2
  local r="${2:-}"
  [ "$r" = - ] && r=""
  if [ -n "$r" ]; then unblock_collect_infra --project "$1" --repo "$r"
  else unblock_collect_infra --project "$1"; fi
}
