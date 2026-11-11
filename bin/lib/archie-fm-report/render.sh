#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-report/render.sh — BH-4588 (BH-4574.6): the daily factory
# report as plain text. Sourced by bin/archie-fm-report.sh, never run.
#
#   afr_render <report-json-file> <mode> [stl-due-file]
#     report-json-file  the GET /api/archie/factory-report answer
#     mode              on | observe | off | unknown (afm_mode hub; unknown
#                       when the settings could not be read)
#     stl-due-file      afr_stl_scan's open stop-the-line incidents (optional)
#   -> the text on stdout, rc 0; rc 1 when the file is not a report.
#
# A pure function: no request, no model call, no clock. The brief-operator rules
# as a fixed template: the one thing first (an open stop-the-line incident
# outranks the route's one_thing), numbers over adjectives, a direct link on
# every PR and ticket line, no em or en dash, plain text. Every section prints
# a line: `none: <empty_reason>` when it is empty, `not measured: <error>` when
# its read failed, never a bare heading and never a 0 it did not read (D12).
#
#   afr_render_short <report-json-file> <mode> <stl-due-file> <min-usd>
#                    <cap-pct> <unknown-min-usd> <mc-url>
#   -> the short Telegram text on stdout, rc 0; rc 1 when the file is not a
#      report. The lane reads the three numbers from the settings rows
#      report.spend_min_usd, report.spend_cap_pct and
#      report.spend_unknown_min_usd; <mc-url> is the Mission Control link to
#      the day's full report. The same pure-function rules as afr_render.
#      What needs the operator comes first, one item per line with its link; then the
#      mode, merge counts per project (no PR links), the spend total against
#      the total of the day caps, and the link. A section that is empty is
#      left out; a section whose read failed keeps one "not measured" line.
#      An unread actions, totals or stuck read is a needs-you line ("Not
#      measured: ..."), so "Nothing needs you" never hides a failed read.
#
# Both renders roll a per-build spend key <project>.<number>.<hex> into its
# parent row (AFR_JQ_DEFS rollup) and print "partial: U of C calls unpriced"
# once, as a total.

# The jq defs both renders share.
# shellcheck disable=SC2016
AFR_JQ_DEFS='
  def money: if . == null then "unknown" else "$" + ((. * 100 | round) / 100 | tostring
    | if test("\\.") then (if test("\\.[0-9]$") then . + "0" else . end) else . + ".00" end) end;
  def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
  def parentof: (capture("^(?<p>.+)\\.[0-9]+\\.[0-9a-f]+$").p) // .;
  # rollup: the route rows -> one row per parent project. usd is the sum of
  # the priced members (null only when every member is null), calls and
  # unpriced_calls are sums, the cap is the cap of the bare parent key (else
  # the cap of the first member), over is recomputed. Sorted as the route sorts.
  def rollup:
    (map(select(.project == (.project | parentof)) | {key: .project, value: .cap_usd}) | from_entries) as $bare
    | group_by(.project | parentof)
    | map((.[0].project | parentof) as $p
        | {project: $p,
           usd: (map(.usd | select(. != null)) | if length == 0 then null else add end),
           calls: (map(.calls // 0) | add),
           unpriced_calls: (map(.unpriced_calls // 0) | add),
           cap_usd: (if $bare | has($p) then $bare[$p] else .[0].cap_usd end)}
        | .over = (.usd != null and .cap_usd != null and .usd > .cap_usd))
    | sort_by([(if .usd == null then 1 else 0 end), -(.usd // 0), .project]);
  def partial: (map(.unpriced_calls // 0) | add // 0) as $u | (map(.calls // 0) | add // 0) as $c
    | if $u > 0 then "partial: \($u) of \($c) calls unpriced" else "" end;
'

# _afr_stl_json <stl-due-file> -> the open incidents as a JSON array ([] when none).
_afr_stl_json() {
  local stl="${1:-}" j='[]'
  if [ -n "$stl" ] && [ -s "$stl" ]; then
    j=$(jq -Rsc 'split("\n") | map(select(. != "") | split("\t")
      | {incident: .[1], class: .[2], age: (.[3] | tonumber), id: .[4]})' "$stl") || j='[]'
  fi
  printf '%s' "$j"
}

afr_render() {
  local f="$1" mode="${2:-unknown}" stl_json
  jq -e '.ok == true and (.day | type == "string")' "$f" >/dev/null 2>&1 || return 1
  stl_json=$(_afr_stl_json "${3:-}")
  jq -r --arg mode "$mode" --argjson stl "$stl_json" "$AFR_JQ_DEFS"'
    def kv($o): [$o | to_entries[] | "\(.key) \(.value)"] | join(", ");
    def head($s; $name; f): if ($s.ok != true) then "\($name): not measured: \($s.error // "the read failed")."
      elif ($s.empty_reason // "") != "" then "\($name): none: \($s.empty_reason)."
      else ($s | f) end;
    def where: "\(.repo)\(if (.pr // 0) > 0 then "#\(.pr)" else "" end)";
    def link: if (.url // "") != "" then " \(.url)" elif (.alert_id // "") != "" then " alert \(.alert_id)" else "" end;
    . as $r
    | (if $r.spend.ok == true then ($r.spend.by_project | rollup) else [] end) as $sp
    | (if $mode == "off" then ["Archie is off (archie.manage=off) and took no action."] else [] end)
    + [ if ($stl | length) > 0 then
          "Stop the line: \(plural($stl | length; "open incident")), first \($stl[0].class) (alert \($stl[0].id), open \($stl[0].age) min)."
        else ($r.one_thing.text // "The one thing could not be read.") end ]
    + [ if $mode == "on" then "Mode: Archie is on (archie.manage=on)."
        elif $mode == "observe" then "Mode: observe (archie.manage=observe): Archie recorded what it would do and acted on nothing."
        elif $mode == "off" then "Mode: off."
        else "Mode: unknown (settings unreadable)." end,
        "Factory report for \($r.day) (UTC)\(if $r.project then ", project \($r.project)" else "" end).", "" ]
    + [ head($r.merges; "Merges"; "Merges: \(plural(.total; "merge")) across \(plural(.by_project | length; "project")).") ]
    + (if $r.merges.ok == true then [$r.merges.by_project[] | "- \(.project): \(.n). " + ([.prs[].url] | join(" "))] else [] end)
    + [ head($r.queue; "Queue"; "Queue: \(.batches.total) batch\(if .batches.total == 1 then "" else "es" end) finished" +
          (if .batches.total > 0 then " (\(kv(.batches.by_outcome)))" else "" end) +
          ". Queue actions: \(.actions.total)" + (if .actions.total > 0 then " (\(kv(.actions.by_outcome)))" else "" end) + ".") ]
    + [ head($r.stuck; "Stuck items"; "Stuck items: \(.cleared) cleared, \(.open) open, \(.failed) failed" +
          (if .would > 0 then ", \(.would) would" else "" end) + "." +
          (if .truncated then " (list partial: \(.items | length) shown)" else "" end)) ]
    + (if $r.stuck.ok == true then [$r.stuck.items[]
        | "- \(if .outcome == "done" then "cleared" elif .outcome == "failed" then "failed" elif .outcome == "would" then "would" else "open" end): \(.playbook) on \(where), \(.action): \(.why).\(link)"] else [] end)
    + [ head($r.tickets; "Tickets"; "Tickets: \(.filed) filed, \(.commented) commented, \(.shipped) shipped, \(.verified) verified" +
          (if .reopened > 0 then ", \(.reopened) reopened" else "" end) + (if .would > 0 then ", \(.would) would" else "" end) + ".") ]
    + (if $r.tickets.ok == true then [$r.tickets.items[] | "- \(.kind // .action): \(.why).\(link)"] else [] end)
    + [ head($r.spend; "Spend vs caps"; "Spend vs caps: \(plural($sp | length; "project")).") ]
    + [$sp[] | "- \(.project): \(.usd | money) of a \(.cap_usd | money) day cap" +
          (if .over then ", OVER the cap" else "" end) +
          (if .usd == null then " (\(plural(.calls; "call")), none priced)" else "" end) + "."]
    + ($sp | partial | if . == "" then [] else ["Spend \(.)."] end)
    + [ if ($r.totals.ok // false) != true then "Archie actions: not measured: \($r.totals.error // "the read failed")."
        elif $r.totals.total == 0 then "Archie actions: none: \($r.actions.empty_reason // "no action row on \($r.day)")."
        else "Archie actions: \($r.totals.total) (\(kv($r.totals.by_outcome)))." +
          (if ($r.actions.truncated // false) then " The console lists the first \($r.actions.rows | length)." else "" end) end ]
    | .[]
  ' "$f" | sed 's/—/-/g; s/–/-/g'
}

afr_render_short() {
  local f="$1" mode="${2:-unknown}" stl_json
  jq -e '.ok == true and (.day | type == "string")' "$f" >/dev/null 2>&1 || return 1
  stl_json=$(_afr_stl_json "${3:-}")
  jq -r --arg mode "$mode" --argjson stl "$stl_json" --arg min "${4:-}" --arg pct "${5:-}" \
    --arg unk "${6:-}" --arg mc "${7:-}" "$AFR_JQ_DEFS"'
    def where: "\(.repo)\(if (.pr // 0) > 0 then "#\(.pr)" else "" end)";
    def nm($s; $name): "\($name): not measured: \($s.error // "the read failed").";
    ($min | tonumber) as $min | ($pct | tonumber) as $pct | ($unk | tonumber) as $unk
    | . as $r
    | (if $r.spend.ok == true then ($r.spend.by_project | rollup) else [] end) as $sp
    # What needs the operator. An unread section is never an item (D12).
    | ([$stl[] | "Stop the line: \(.class), open \(.age) min, alert \(.id)."]) as $i_stl
    | (if $r.actions.ok == true then [$r.actions.rows[] | select(.outcome == "failed")] else [] end) as $failed
    | ([$failed[] | "Failed: \(.playbook) on \(where): \(.why). " +
          (if (.pr // 0) > 0 then "https://github.com/\(.repo)/pull/\(.pr)" else $mc end)]) as $i_failed
    | ([$sp[] | select(.over) | "\(.project) spent \(.usd | money), over its \(.cap_usd | money) day cap. \($mc)"]) as $i_over
    | (if $r.stuck.ok == true then [$r.stuck.items[] | select(.outcome == "started" or .outcome == "requested" or .outcome == "deferred")] else [] end) as $open
    | ([$open[] | "Open: \(.playbook) on \(where), \(.action): \(.why). \(if (.url // "") != "" then .url else $mc end)"]) as $i_open
    | ((if ($r.totals.ok // false) == true then ($r.totals.by_outcome.failed // 0) - ($failed | length) else 0 end | if . < 0 then 0 else . end)
       + (if $r.stuck.ok == true then ($r.stuck.open // 0) - ($open | length) else 0 end | if . < 0 then 0 else . end)) as $more
    | ($i_stl + $i_failed + $i_over + $i_open
       + (if $more > 0 then ["\($more) more on Mission Control: \($mc)"] else [] end)) as $items
    # An unread actions or stuck read is not a quiet day (BH-4588 D12): it gets
    # one line with the link, and "Nothing needs you" is never printed then.
    | ((if ($r.actions.ok // false) != true or ($r.totals.ok // false) != true then
          ["Not measured: Archie actions (\((if ($r.actions.ok // false) != true then $r.actions.error else null end) // $r.totals.error // "the read failed")). \($mc)"]
        else [] end)
       + (if ($r.stuck.ok // false) != true then
          ["Not measured: stuck items (\($r.stuck.error // "the read failed")). \($mc)"]
        else [] end)) as $i_nm
    | (if ($items | length) > 0 then $items + $i_nm
       elif ($r.one_thing.kind // "") == "none" then
         (if ($i_nm | length) > 0 then $i_nm else [$r.one_thing.text // "Nothing needs you from \($r.day)."] end)
       else ["\($r.one_thing.text // "The one thing could not be read.") \($mc)"] + $i_nm end)
    + [ if $mode == "on" then "Mode: on."
        elif $mode == "observe" then "Mode: observe (Archie acted on nothing)."
        elif $mode == "off" then "Mode: off (Archie took no action)."
        else "Mode: unknown (settings unreadable)." end ]
    + ( if $r.merges.ok != true then [nm($r.merges; "Merges")]
        elif ($r.merges.empty_reason // "") != "" or ($r.merges.total // 0) == 0 then []
        else ["Merges: \($r.merges.total) across \(plural($r.merges.by_project | length; "project")) (" +
              ([$r.merges.by_project[] | "\(.project) \(.n)"] | join(", ")) + ")."] end )
    + ( if $r.spend.ok != true then [nm($r.spend; "Spend")]
        elif ($sp | length) == 0 then []
        else
          ($sp | map(select(.project != "unknown"))
            | map(. + {listed: (.usd != null and (.usd > $min
                 or (.cap_usd != null and .cap_usd > 0 and (.usd * 100 / .cap_usd) > $pct)))})) as $rows
          | ([$sp[] | select(.project == "unknown" and .usd != null and .usd > $unk)]) as $unknown
          | ([$rows[] | select(.listed) | "\(.project) \(.usd | money)" + (if .cap_usd != null then " of \(.cap_usd | money)" else "" end)]
             + [$unknown[] | "unknown \(.usd | money) (\(plural(.calls; "call")))"]) as $listed
          | ([$rows[] | select(.listed | not)]) as $other
          | ($sp | partial) as $part
          | ["Spend: \([$sp[] | .usd | select(. != null)] | add // 0 | money) of \([$sp[] | .cap_usd | select(. != null)] | add // 0 | money) in day caps" +
             (if $part != "" then " (\($part))" else "" end) + "." +
             (if ($listed | length) > 0 then " Listed: " + ($listed | join(", ")) + "." else "" end)]
          + (if ($other | length) > 0 then ["\(plural($other | length; "other project")): \([$other[] | .usd | select(. != null)] | add // 0 | money) in total."] else [] end)
        end )
    + [ "Full report: \($mc)" ]
    | .[]
  ' "$f" | sed 's/—/-/g; s/–/-/g'
}
