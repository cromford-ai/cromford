#!/bin/bash
# bin/lib/daily-digest-render.sh — BH-3707 (BH-3688.4): the daily-digest
# renderer. Sourced by bin/daily-digest.sh.
#
#   dd_render <json-file> <console-base> <lead-precision-file|-> <spotcheck-pct> <max-items> <summary-file|->
#
# The signature is frozen by the contract (BH-3703). Every input arrives as an
# argument; it reads no env. It prints the digest text for the route's JSON
# (worker/jobs/src/routes/daily-digest.js) and returns 0. Fewer than 6 args, or
# a max-items that is not a positive integer, is rc 2. A JSON file that is
# unreadable or not an object is rc 1 with nothing on stdout.
#
# The rules it keeps:
#   - every line that carries a number ends with the console URL it drills
#     into, and every URL is a console-ui ROUTES path;
#   - a section with ok:false prints `n/a (read failed: <80 chars>)`, never 0;
#   - `Open work past SLA` (BH-3781) adds `(as of HH:MMZ, stale)` when the
#     stuck-work snapshot is older than the route's 30 min, and prints
#     `unreadable (<80 chars>)` rather than `n/a (read failed: ...)` on ok:false;
#   - `PR health` (BH-3936) prints one line per project, `(as of <day>)` when
#     that project's row is from another day than the digest's;
#   - lists are cut at max-items with `+N more`, and a route-side cut says so;
#   - `<`, `>` and `&` are stripped from every value it interpolates;
#   - `Outcome gap` (BH-4017) follows Spend only when the JSON has an
#     .outcome_gap key (bin/daily-digest.sh merges it from
#     GET /api/metrics/outcome-gap): a total line, one line per project, its
#     tickets under it, each list cut at max-items; ok:false is n/a, and
#     tickets_n 0 is `none (...)`;
#   - `Factory manager` (BH-4583) is the last line, only when the JSON has a
#     .factory_manager key (bin/daily-digest.sh merges it from
#     GET /api/archie/actions?summary=1): ONE line, `no actions` on a quiet
#     day, never blank; ok:false is n/a. Observe-mode rows count as would-do,
#     never as restacked. `repaired` (BH-4585, rebase-repair pushes) reads 0
#     from a worker that predates it. `, <n> pushed with no local suites`
#     (BH-4784) is added only when .no_local_suites is above 0, so an older
#     worker or a zero renders the line as before. It links the console root
#     until the Factory screen (wave 6) exists;
#   - `Factory manager, data lane` (BH-4927) follows it only when that summary
#     carries .data_lane with a total above 0: `applied N migrations ahead of
#     merge, M escalated`. An older worker without the key prints no line,
#     never a false `applied 0`;
#   - `Self-healed` (BH-4724) follows Tripwires only when the JSON has a
#     .self_heals key: one line, the count and `(<source> <n>, ...)`;
#   - lead precision comes from the named file only: `-` or an unreadable file
#     is `n/a (no precision run for <D>)`, never an older file;
#   - the spot-check sample is lrl_spotcheck's (bin/lead-review-land.sh), and
#     dd_spotcheck_bucket is that expression copied verbatim.
# The approve command is printed from this file's own harness root (the hub's
# install root on the hub), so the lib carries no root literal.

# dd_spotcheck_bucket <repo> <pr> <head> -> 0..99, as lrl_spotcheck computes it.
dd_spotcheck_bucket() {
  set -- x "$1" "$2" "$3"
  printf '%s\n' "$(( $(printf '%s' "$2#$3@$4" | cksum | awk '{print $1}') % 100 ))"
}

dd_render() {
  if [ "$#" -lt 6 ]; then
    echo "usage: dd_render <json-file> <console-base> <lead-precision-file|-> <spotcheck-pct> <max-items> <summary-file|->" >&2
    return 2
  fi
  local json=$1 base=${2%/} prec=$3 pct=$4 max=$5 sumf=$6 root day lp summary="" sampled="[]" pct_on=false
  if ! [[ $max =~ ^[0-9]+$ ]] || [ "$((10#$max))" -lt 1 ]; then
    echo "dd_render: max-items must be a positive integer, got '$max'" >&2
    return 2
  fi
  if ! jq -e 'type == "object"' "$json" >/dev/null 2>&1; then
    echo "dd_render: $json is unreadable or not a JSON object" >&2
    return 1
  fi
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  day=$(jq -r '.day // "" | tostring | gsub("[<>&]"; "")' "$json")

  # Lead precision: the named file or nothing.
  lp="n/a (no precision run for $day)"
  if [ "$prec" != - ] && [ -r "$prec" ]; then
    lp=$(jq -r '[.repos[]?.prs[]? | select(.reverted != null)] as $s
      | ($s | map(select(.reverted == true or .batch_failed == true)) | length) as $bad
      | if ($s | length) == 0 then "n/a (0 scored)"
        else "\((((($s | length) - $bad) * 100 / ($s | length)) | round) / 100) (\(($s | length) - $bad)/\($s | length))" end' \
      "$prec" 2>/dev/null) || lp="n/a (no precision run for $day)"
    [ -n "$lp" ] || lp="n/a (no precision run for $day)"
  fi

  if [ "$sumf" != - ] && [ -s "$sumf" ]; then summary=$(cat "$sumf"); fi

  # Spot-checks: the bucket needs cksum, so the sample is chosen here and the
  # jq program below only prints it.
  if [[ $pct =~ ^[0-9]+$ ]] && [ "$((10#$pct))" -gt 0 ]; then
    pct=$((10#$pct)); pct_on=true
    local i=0 repo pr head idx=()
    while IFS=$'\t' read -r repo pr head; do
      [ "$(dd_spotcheck_bucket "$repo" "$pr" "$head")" -lt "$pct" ] && idx+=("$i")
      i=$((i + 1))
    done < <(jq -r '.spotcheck_candidates.rows[]? | [.repo, .pr, .head_sha] | map(tostring) | @tsv' "$json")
    sampled=$(printf '%s\n' "${idx[@]}" | jq -sc 'map(select(. != null))')
  fi

  jq -r --arg c "$base" --arg root "$root" --arg lp "$lp" --arg sum "$summary" \
    --argjson max "$((10#$max))" --arg pct "$pct" --argjson pct_on "$pct_on" --argjson sampled "$sampled" '
    def s: tostring | gsub("[<>&]"; "");
    def seg: s | @uri;
    def num: if . == null then "n/a" else s end;
    def money: (. * 100 | round) as $c
      | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
    def dur: floor | "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m";
    def failed($name; $link): "\($name): n/a (read failed: \(.error // "unknown" | s | .[0:80])) \($c)\($link)";
    # cut(rows; total; truncated; link): the first $max rows (already strings),
    # then `+N more` when the total is past them.
    def cut($rows; $total; $trunc; $link):
      ($rows[:$max][]),
      ((($total // ($rows | length)) - ([$rows | length, $max] | min)) as $more
        | if $more > 0 then "  +\($more) more\(if $trunc then " (list cut at the source)" else "" end) \($c)\($link)"
          elif $trunc then "  (list cut at the source) \($c)\($link)" else empty end);
    . as $d
    | "Daily digest \(.day | s) (UTC)",
      (if $sum != "" then "Summary: \($sum | s)" else empty end),
      (if .empty == true then "Nothing happened on \(.day | s)." else empty end),

      # Throughput
      (.throughput | if .ok != true then failed("Throughput"; "/dora?days=1") else
        "Throughput: merged \(.merged | num) \($c)/dora?days=1",
        cut([.by_project[]? | "  \(.project | s): \(.merged | num) \($c)/p/\(.project | seg)"];
            (.by_project | length); false; "/dora?days=1"),
        (.filing_to_merge as $f
          | if $f.p50_s == null then "  filing→merge p50 n/a (\($f.measured_n // 0 | s) measured) \($c)/dora?days=1"
            else "  filing→merge p50 \($f.p50_s | dur) (measured \($f.measured_n | num), unmeasured \($f.unmeasured_n | num)) \($c)/dora?days=1" end)
      end),

      # Spend
      (.spend | if .ok != true then failed("Spend"; "/costs") else
        (if .usd == null then "Spend: n/a (all unpriced) over \(.calls | num) calls \($c)/costs"
         else "Spend: \(.usd | money) over \(.calls | num) calls \($c)/costs" end),
        "  unpriced: \(.unpriced_calls | num) calls \($c)/costs"
      end),
      ("  $/merged PR: " + (
        if ($d.spend.ok != true) or ($d.throughput.ok != true) then "n/a (read failed)"
        elif $d.throughput.merged == 0 then "n/a (0 merges)"
        elif $d.spend.usd == null or $d.spend.usd_per_merged_pr == null then "n/a (all unpriced)"
        else ($d.spend.usd_per_merged_pr | money) end) + " \($c)/costs"),
      (.spend | if .ok == true then
        cut([.top_tickets.rows[]? | "  \(.ticket | s) \(if .usd == null then "unpriced" else (.usd | money) end) \($c)/jobs/\(.job_id | seg)"];
            null; (.top_tickets.truncated == true); "/costs")
      else empty end),

      # Outcome gap (BH-4017): only when the lane merged .outcome_gap
      (if has("outcome_gap") then (.outcome_gap | if .ok != true then failed("Outcome gap"; "/costs")
       elif .tickets_n == 0 then "Outcome gap: none (every ticket over \(.min_usd | money) has a merged harness PR) \($c)/costs"
       else
        "Outcome gap: \(.total_usd | money) over \(.tickets_n | num) tickets with build spend over \(.min_usd | money) and no merged harness PR \(.days | num)+ days\(if .truncated == true then " (cut at the source)" else "" end) \($c)/costs",
        cut([.projects[]? | . as $p
              | (["  \(.project | s): \(.usd | money) over \(.tickets_n | num) tickets \($c)/p/\(.project | seg)",
                  cut([.tickets.rows[]? | "    \(.ticket | s) \(if .usd == null then "unpriced" else (.usd | money) end) \($c)\(
                         if .last_job_id == null then "/p/\($p.project | seg)" else "/jobs/\(.last_job_id | seg)" end)"];
                      .tickets_n; (.tickets.truncated == true); "/p/\($p.project | seg)")] | join("\n"))];
            (.projects | length); false; "/costs")
       end) else empty end),

      # Autonomy
      (.autonomy | if .ok != true then failed("Autonomy"; "/history") else
        "Autonomy:",
        (.batch_dequeues | "  batch dequeues \(.n | num) (target 0)\(if .basis then " (\(.basis | s))" else "" end) \($c)/merge-queue",
          cut([.rows[]? | "    \(.source | s) \(.project | s) \(.key | s) \(.at | s) \($c)/p/\(.project | seg)"]; .n; (.truncated == true); "/merge-queue")),
        (.manual_requeues | "  manual requeues \(.n | num) (target 0) \($c)/history",
          cut([.rows[]? | "    \(.project | s) \(.key | s) \(.verdict | s) by \(.actor // "unknown" | s) \(.at | s) \($c)/p/\(.project | seg)"]; .n; (.truncated == true); "/history")),
        (.rebuild_loops | "  rebuild loops \(.n | num) (target 0), abandoned \(.abandoned | num) \($c)/outcomes",
          cut([.rows[]? | "    \(.project | s) \(.key | s) rebuilt \(.rebuilds | num)x \(.at | s) \($c)/p/\(.project | seg)"]; .n; (.truncated == true); "/outcomes")),
        (.human_interventions | "  human interventions \(.n | num) (target 0) \($c)/history",
          ([(.by_table // {}) | to_entries[] | select(.value != 0) | "\(.key | s) \(.value | num)"] | join(", ")
            | if . == "" then empty else "    \(.) \($c)/history" end))
      end),
      "  lead precision \($lp) \($c)/outcomes",

      # Tripwires
      (.tripwires | if .ok != true then failed("Tripwires"; "/alerts") else
        "Tripwires: \(.n | num) \($c)/alerts",
        cut([.rows[]? | "  \(.kind | s) \(.project | s) \(.key | s) \(.at | s) \($c)/p/\(.project | seg)"]; .n; (.truncated == true); "/alerts")
      end),

      # Self-healed (BH-4724): only when the route answered .self_heals
      (if has("self_heals") then (.self_heals | if .ok != true then failed("Self-healed"; "/alerts") else
        "Self-healed: \(.n | num)"
        + ([(.by_source // {}) | to_entries[] | "\(.key | s) \(.value | num)"] | join(", ") | if . == "" then "" else " (\(.))" end)
        + " \($c)/alerts" end) else empty end),

      # Holds
      (.holds | if .ok != true then failed("Holds"; "/needs") else
        "Holds: \(.n | num)\(if .basis then " (\(.basis | s))" else "" end) \($c)/needs",
        cut([.rows[]? | "  \(.source | s) \(.project | s) \(.key | s) since \(.since | s) \($c)/p/\(.project | seg)"]; .n; (.truncated == true); "/needs")
      end),

      # Open work past SLA (BH-3781): the last stuck-work snapshot
      # ok:false prints the literal `unreadable` the ticket asks for, never a 0
      (.past_sla | if .ok != true then "Open work past SLA: unreadable (\(.error // "unknown" | s | .[0:80])) \($c)/alerts" else
        "Open work past SLA: \(.total | num)"
        + ([(.by_state // {}) | to_entries[] | select(.value != 0) | "\(.key | s) \(.value | num)"] | join(", ") | if . == "" then "" else " (\(.))" end)
        + (if .stale == true then " (as of \(.as_of | s | .[11:16])Z, stale)" else "" end)
        + " \($c)/alerts" end),

      # PR health (BH-3936): one line per project from the pr-owner sweep
      # pr_health rows; `<1d` and `>7d` are template text, values are stripped
      (.pr_health | if .ok != true then failed("PR health"; "/merge-queue") else
        "PR health: \(.rows | length) repo(s) \($c)/merge-queue",
        (.rows[]? | "  \(.project | s): \(.open | num) open (\(.age.lt1d | num) <1d, \(.age["1to3d"] | num) 1-3d, \(.age["3to7d"] | num) 3-7d, \(.age.gt7d | num) >7d), \(.ownerless | num) ownerless, \(.approved_not_merged | num) approved not merged, \(.blocked_ci_only | num) blocked on CI only\(if .day != $d.day then " (as of \(.day | s))" else "" end) \($c)/p/\(.project | seg)"),
        (if (.skipped // 0) > 0 then "  \(.skipped | num) unreadable pr_health row(s) \($c)/merge-queue" else empty end)
      end),

      # PRs awaiting a human verdict
      (.human_verdict_prs | if .ok != true then failed("PRs awaiting a human verdict"; "/needs") else
        "PRs awaiting a human verdict: \(.n | num) \($c)/needs",
        cut([.rows[]? | "  \(.repo | s)#\(.number | s) \(.reason | s) since \(.since | s) \($c)/pr/\(.project | seg)/\(.number | seg)"]; .n; (.truncated == true); "/needs")
      end),
      "  protected paths: not tracked yet (BH-3683)",

      # Model watch
      (.model_watch | if .ok != true then failed("Model watch"; "/models") else
        "Model watch: \(.rows | length) \($c)/models",
        cut([.rows[]? | (.suggestion // "" | s | test("\\S")) as $sug
               | "  \(.vendor | s) \(.model_id | s)\(if $sug then ": \(.suggestion | s)" else "" end) \($c)/models"
                 + (if $sug then "\n    approve: \($root)/bin/model-watch-approve.sh \(.vendor | s) \(.model_id | s)" else "" end)];
            null; (.truncated == true); "/models")
      end),

      # Spot-checks
      (if $pct_on | not then "Spot-checks: spot-check sampling off"
       else .spotcheck_candidates | if .ok != true then failed("Spot-checks"; "/outcomes") else
         [.rows // [] | to_entries[] | select(.key as $k | $sampled | index($k)) | .value] as $pick
         | "Spot-checks: sampled \($pick | length) of \(.rows | length) at \($pct)% \($c)/outcomes",
           cut([$pick[] | "  \(.repo | s)#\(.pr | s) @\(.head_sha | s | .[0:12]) \($c)/pr/\(.project | seg)/\(.pr | seg)"];
               null; (.truncated == true); "/outcomes")
       end end),

      # Factory stop
      (.factory | if .ok != true then failed("Factory stop"; "/") else
        (.factory_stop as $f
          | if $f.set != true then "Factory stop: not set \($c)/"
            elif ($f.value | tostring) == "1" or ($f.value | tostring) == "true" then
              "Factory stop: STOPPED since \($f.updated_at | s) by \($f.actor // "unknown" | s) \($c)/"
            elif ($f.value | tostring) == "0" or ($f.value | tostring) == "false" then "Factory stop: not set \($c)/"
            else "Factory stop: not set (row unreadable: \($f.value | s | .[0:40])) \($c)/" end),
        (if .all_off.set == true then "  ALL LANES OFF since \(.all_off.since | s) by \(.all_off.actor // "unknown" | s) \($c)/" else empty end),
        (.fleet_pauses[]? | "  \(.what | s) paused until \(.expires_at | s) by \(.actor // "unknown" | s) \($c)/")
      end),

      # Factory manager (BH-4583): only when the lane merged .factory_manager
      (if has("factory_manager") then (.factory_manager | if .ok != true then failed("Factory manager"; "/")
       elif .total == 0 then "Factory manager: no actions \($c)/"
       else "Factory manager: \(.total | num) actions (\(.restacked | num) restacked, \((.repaired // 0) | num) repaired, \(.fix_rounds | num) fix rounds asked, \(.would | num) would-do in observe, \(.deferred | num) deferred, \(.failed | num) failed\(if (.no_local_suites // 0) > 0 then ", \(.no_local_suites | num) pushed with no local suites" else "" end)) \($c)/" end)
       else empty end),
      (if (.factory_manager.ok? == true) and ((.factory_manager.data_lane.total? | type) == "number") and (.factory_manager.data_lane.total > 0)
       then "Factory manager, data lane: applied \(.factory_manager.data_lane.applied | num) migrations ahead of merge, \(.factory_manager.data_lane.escalated | num) escalated \($c)/"
       else empty end),

      # Scheduler shadow (BH-6978): only when the lane merged .scheduler_shadow
      (if has("scheduler_shadow") then (.scheduler_shadow | if .ok != true then failed("Scheduler shadow"; "/")
       elif (.projects | length) == 0 then "Scheduler shadow: no ticks on \(.day // $d.day | s). \($c)/"
       else .projects[] | "Scheduler shadow, \(.project | s): \(if .rate == null then "no compared verdicts"
           else "\(.rate * 1000 | round / 10)% agree" end) (\(.agreed | num) of \(.compared | num) compared, \(.idle | num) idle, \(.ticks | num) ticks).\(
           if (.top | length) == 0 then "" else " Top disagreements: \([.top[:5][] | "\(.reason_class | s) \(.n | num)"] | join(", "))." end) \($c)/"
       end) else empty end)
  ' "$json"
}
