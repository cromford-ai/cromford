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

afr_render() {
  local f="$1" mode="${2:-unknown}" stl="${3:-}" stl_json='[]'
  jq -e '.ok == true and (.day | type == "string")' "$f" >/dev/null 2>&1 || return 1
  if [ -n "$stl" ] && [ -s "$stl" ]; then
    stl_json=$(jq -Rsc 'split("\n") | map(select(. != "") | split("\t")
      | {incident: .[1], class: .[2], age: (.[3] | tonumber), id: .[4]})' "$stl") || stl_json='[]'
  fi
  jq -r --arg mode "$mode" --argjson stl "$stl_json" '
    def money: if . == null then "unknown" else "$" + ((. * 100 | round) / 100 | tostring
      | if test("\\.") then (if test("\\.[0-9]$") then . + "0" else . end) else . + ".00" end) end;
    def kv($o): [$o | to_entries[] | "\(.key) \(.value)"] | join(", ");
    def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
    def head($s; $name; f): if ($s.ok != true) then "\($name): not measured: \($s.error // "the read failed")."
      elif ($s.empty_reason // "") != "" then "\($name): none: \($s.empty_reason)."
      else ($s | f) end;
    def where: "\(.repo)\(if (.pr // 0) > 0 then "#\(.pr)" else "" end)";
    def link: if (.url // "") != "" then " \(.url)" elif (.alert_id // "") != "" then " alert \(.alert_id)" else "" end;
    . as $r
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
    + [ head($r.spend; "Spend vs caps"; "Spend vs caps: \(plural(.by_project | length; "project")).") ]
    + (if $r.spend.ok == true then [$r.spend.by_project[]
        | "- \(.project): \(.usd | money) of a \(.cap_usd | money) day cap" +
          (if .over then ", OVER the cap" else "" end) +
          (if .usd == null then " (\(plural(.calls; "call")), none priced)"
           elif .unpriced_calls > 0 then " (partial: \(.unpriced_calls) of \(.calls) calls unpriced)" else "" end) + "."] else [] end)
    + [ if ($r.totals.ok // false) != true then "Archie actions: not measured: \($r.totals.error // "the read failed")."
        elif $r.totals.total == 0 then "Archie actions: none: \($r.actions.empty_reason // "no action row on \($r.day)")."
        else "Archie actions: \($r.totals.total) (\(kv($r.totals.by_outcome)))." +
          (if ($r.actions.truncated // false) then " The console lists the first \($r.actions.rows | length)." else "" end) end ]
    | .[]
  ' "$f" | sed 's/—/-/g; s/–/-/g'
}
