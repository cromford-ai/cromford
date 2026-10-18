#!/bin/bash
# shellcheck shell=bash
# bin/lib/scheduler.sh — the scheduler's ready-set rule and its compare with
# what the existing lanes did (BH-6978, wave 2 of #6547). Sourced, never
# executed: no `set -e`, no `exit`, nothing runs at source time. No network:
# every function reads files in one inputs directory and prints TSV. The lane
# that fills that directory is bin/scheduler.sh. Contract:
# docs/notes/2026-10-16-BH-6978-scheduler-shadow.md.
#
# sched_decide <D>
#   Inputs in <D>:
#     candidates      one issue number per line (open, ai-build, not a PR)
#     in_flight       issue numbers with a build in flight (not judged)
#     edges.json      the GET /api/ticket-edges?project= body
#     parents         <n>\t<merged|open|closed-done|unknown> per parent number
#     holds.json      the GET /api/scheduler/holds body (latest row per ticket)
#     planned/<n>     the candidate's planned files
#     claims/<KEY>    fclaim_list_dir output (running claims)
#     cap             an integer, or `unlimited`
#     sibling         optional (BH-6979, enforce only): <n>\t<s> when
#                     bin/sibling-serial.sh says part <n> waits for sibling #<s>,
#                     <n>\t- when the tick's check cap left <n> unchecked,
#                     <n>\t? when `parts` or `check` failed or timed out.
#                     Absent: the output is byte-identical to wave 2.
#   Rule per candidate, ascending issue number, FIRST HIT WINS:
#     1. a hard edge to an `open` parent  -> no      parent #<p> open
#        a hard edge to an `unknown` (or unlisted) parent
#                                         -> unknown parent #<p> unreadable
#        merged and closed-done parents clear the edge; soft edges are ignored
#     2. the latest hold row is `hold`    -> no      hold by <by>
#     3. a planned path equal to a path another ticket's running claim holds
#                                         -> no      files claimed by #<m>
#     3b. <D>/sibling names the candidate    -> no      files claimed by #<s>
#         (`-`, the check cap)               -> unknown sibling check cap
#         (`?`, parts/check failed)          -> unknown sibling check failed
#     4. otherwise ready; past the first <cap> ready tickets -> no  wip cap
#   Prints `<n>\t<yes|no|unknown>\t<reason>` (reason empty on yes).
#
# sched_lanes_did <D> <PFX> [project]
#   What the lanes did in the window `<since>\t<at>` of <D>/window (ISO, UTC).
#   Inputs: decisions.json (GET /api/decisions body), jobs.json (GET /api/jobs
#   body), pool.log (fly-pool.log lines of the window), overlap.out (this
#   tick's bin/overlap-schedule.sh stdout), stackwait.json (GET
#   /api/ledger?kind=stack-wait body). A missing file is no entry.
#   Prints `<n>\t<lanes_did>\t<lane reason>`; lanes_did is `dispatched` or
#   `held:<lane>[+<lane>...]` in the order triage, sibling-serial,
#   overlap-schedule, stacked-wait. dispatched wins over any hold.
#
# sched_compare <decide-out> <lanes-out>
#   Prints `compared=<c> agreed=<a> idle=<i>`, then one line per disagreement:
#   `<n>\t<ready|not-ready>\t<lanes_did>\t<reason>\t<reason_class>`.
#     yes + dispatched -> agree;  yes + held -> diff (reason = the lane's,
#     class lanes-held:<first lane>);  yes + none -> idle (not compared);
#     no + held|none -> agree;  no + dispatched -> diff (reason = the
#     scheduler's, class parent-open|hold|files-claimed|wip-cap);
#     unknown -> not compared.

# The words a triage decision uses when it starts a build.
SCHED_DISPATCH_ACTIONS="build launch relaunch rebuild queue enqueue dispatch"

sched_decide() {
  local d="${1:-}" n st reason p by f k m cap ready=0
  [ -n "$d" ] && [ -r "$d/candidates" ] || return 1
  local edges holds
  edges=$(jq -r '.edges[]? | select(.kind == "hard") | "\(.child)\t\(.parent)"' "$d/edges.json" 2>/dev/null)
  holds=$(jq -r '.holds[]? | "\(.ticket)\t\(.state)\t\(.by)"' "$d/holds.json" 2>/dev/null)
  cap=$(tr -d '[:space:]' < "$d/cap" 2>/dev/null)
  [[ $cap =~ ^[0-9]+$ ]] || cap=unlimited
  while IFS= read -r n; do
    [[ $n =~ ^[1-9][0-9]*$ ]] || continue
    grep -qx "$n" "$d/in_flight" 2>/dev/null && continue
    st=yes; reason=""
    # 1. hard edges: an open parent is a no, else an unreadable one is unknown.
    local open="" unk=""
    for p in $(awk -F'\t' -v c="$n" '$1 == c {print $2}' <<<"$edges" | sort -n -u); do
      case "$(awk -F'\t' -v p="$p" '$1 == p {print $2; exit}' "$d/parents" 2>/dev/null)" in
        merged|closed-done) ;;
        open) [ -z "$open" ] && open=$p ;;
        *) [ -z "$unk" ] && unk=$p ;;
      esac
    done
    if [ -n "$open" ]; then st=no; reason="parent #$open open"
    elif [ -n "$unk" ]; then st=unknown; reason="parent #$unk unreadable"
    fi
    # 2. the latest hold row.
    if [ "$st" = yes ]; then
      by=$(awk -F'\t' -v c="$n" '$1 == c && $2 == "hold" {print $3; exit}' <<<"$holds")
      [ -n "$by" ] && { st=no; reason="hold by $by"; }
    fi
    # 3. a planned path another ticket's running claim holds.
    if [ "$st" = yes ] && [ -s "$d/planned/$n" ] && [ -d "$d/claims" ]; then
      m=""
      for f in "$d"/claims/*; do
        [ -f "$f" ] || continue
        k=${f##*/}
        [[ $k =~ ^[A-Za-z]+-([0-9]+) ]] || continue
        k=${BASH_REMATCH[1]}
        [ "$k" = "$n" ] && continue
        if grep -vE '^(SOURCE:|[[:space:]]*$)' "$d/planned/$n" | grep -qxFf - "$f" 2>/dev/null; then
          { [ -z "$m" ] || [ "$k" -lt "$m" ]; } && m=$k
        fi
      done
      [ -n "$m" ] && { st=no; reason="files claimed by #$m"; }
    fi
    # 3b. a sibling part sibling-serial says this part waits for (BH-6979).
    if [ "$st" = yes ] && [ -s "$d/sibling" ]; then
      m=$(awk -F'\t' -v c="$n" '$1 == c {print $2; exit}' "$d/sibling")
      case "$m" in
        "") ;;
        -) st=unknown; reason="sibling check cap" ;;
        "?") st=unknown; reason="sibling check failed" ;;
        *) st=no; reason="files claimed by #$m" ;;
      esac
    fi
    # 4. the WIP cap, in ascending issue order.
    if [ "$st" = yes ]; then
      if [ "$cap" != unlimited ] && [ "$ready" -ge "$cap" ]; then st=no; reason="wip cap"
      else ready=$((ready + 1)); fi
    fi
    printf '%s\t%s\t%s\n' "$n" "$st" "$reason"
  done < <(sort -n -u "$d/candidates")
}

# _sched_num <PFX> <ticket> — the issue number of BH-12, bh-12, #12 or 12.
_sched_num() {
  local t="${2:-}"
  t=${t#"#"}
  [[ ${t^^} == "${1^^}-"* ]] && t=${t:${#1}+1}
  [[ $t =~ ^[1-9][0-9]{0,8}$ ]] && printf '%s' "$t"
}

sched_lanes_did() {
  local d="${1:-}" pfx="${2:-}" proj="${3:-}" since at
  [ -n "$d" ] && [ -n "$pfx" ] && [ -r "$d/window" ] || return 1
  IFS=$'\t' read -r since at < "$d/window"
  [ -n "$since" ] && [ -n "$at" ] || return 1
  {
    # triage: one decisions row per ticket it acted on. The row's line ends
    # `<ticket> :: <action> :: <reason>`; its stamp is `YYYY-MM-DD HH:MM:SSZ`.
    jq -r --arg s "$since" --arg a "$at" '.rows[]?
        | ((.stamp // "") | sub(" "; "T")) as $st
        | select($st > $s and $st <= $a)
        | (.line // "" | split(" :: ")) as $f
        | select(($f | length) >= 2)
        | [(.ticket // ""), ($f[1] | ascii_downcase | split(" ")[0]), ($f[2:] | join(" :: ") | gsub("[\t\n]"; " ") | .[0:200])]
        | @tsv' "$d/decisions.json" 2>/dev/null \
      | while IFS=$'\t' read -r t act why; do
          t=$(_sched_num "$pfx" "$t") || continue
          if [[ " $SCHED_DISPATCH_ACTIONS " == *" $act "* ]]; then printf '%s\t0\tdispatched\t%s\n' "$t" "triage $act"
          else printf '%s\t1\ttriage\t%s\n' "$t" "${why:-triage $act}"; fi
        done
    # a build job opened in the window.
    jq -r --arg s "$since" --arg a "$at" '.jobs[]? | select(.kind == "build")
        | ((.created_at // "")[0:19] + "Z") as $c | select($c > $s and $c <= $a)
        | "\(.ticket_id // "")\t\(.id // "")"' "$d/jobs.json" 2>/dev/null \
      | while IFS=$'\t' read -r t id; do
          t=$(_sched_num "$pfx" "$t") || continue
          printf '%s\t0\tdispatched\t%s\n' "$t" "build job $id"
        done
    # sibling-serial, from the pool log and from overlap-schedule.
    sed -n "s/^.*SIBLING_SERIAL \($pfx-[0-9][0-9]*\) waits for /\1\t/p" "$d/pool.log" 2>/dev/null \
      | while IFS=$'\t' read -r t why; do
          t=$(_sched_num "$pfx" "$t") || continue
          printf '%s\t2\tsibling-serial\t%s\n' "$t" "waits for ${why:0:180}"
        done
    sed -n "s/^HELD: \($pfx-[0-9][0-9]*\) /\1\t/p" "$d/overlap.out" 2>/dev/null \
      | while IFS=$'\t' read -r t why; do
          t=$(_sched_num "$pfx" "$t") || continue
          case "$why" in
            *"(SIBLING_SERIAL)") printf '%s\t2\tsibling-serial\t%s\n' "$t" "${why:0:200}" ;;
            *) printf '%s\t3\toverlap-schedule\t%s\n' "$t" "${why:0:200}" ;;
          esac
        done
    # STACKED_WAIT: a waiting stack-wait ledger row.
    jq -r --arg p "$proj" '.ledgers[]? | select(.status == "waiting") | (.key // "" | split(" ")) as $k
        | select(($k | length) >= 2 and ($p == "" or $k[0] == $p))
        | "\($k[1])\t\($k[2] // "")"' "$d/stackwait.json" 2>/dev/null \
      | while IFS=$'\t' read -r t par; do
          t=$(_sched_num "$pfx" "$t") || continue
          printf '%s\t4\tstacked-wait\t%s\n' "$t" "waits for parent branch ${par:-?}"
        done
  } | sort -t$'\t' -k1,1n -k2,2n -s | awk -F'\t' '
      function flush() { if (cur == "") return
        if (disp != "") print cur "\tdispatched\t" disp; else print cur "\theld:" lanes "\t" why }
      $1 != cur { flush(); cur = $1; disp = ""; lanes = ""; why = ""; seen = "" }
      $2 == 0 { if (disp == "") disp = $4; next }
      { if (index(" " seen " ", " " $3 " ")) next
        seen = seen " " $3; lanes = (lanes == "" ? $3 : lanes "+" $3); if (why == "") why = $4 }
      END { flush() }'
}

sched_compare() {
  local dec="${1:-}" lanes="${2:-}"
  [ -r "$dec" ] || return 1
  awk -F'\t' -v L="${lanes:-}" '
    BEGIN { if (L != "") while ((getline ln < L) > 0) { split(ln, f, "\t"); did[f[1]] = f[2]; why[f[1]] = f[3] } }
    $2 == "unknown" { next }
    { l = ($1 in did) ? did[$1] : "none"
      if ($2 == "yes") {
        if (l == "dispatched") { c++; a++ }
        else if (l == "none") { i++ }
        else { c++; first = substr(l, 6); sub(/\+.*/, "", first)
               r = why[$1]; if (r == "") r = "held by " first
               out = out sprintf("%s\tready\t%s\t%s\tlanes-held:%s\n", $1, l, r, first) }
      } else {
        c++
        if (l != "dispatched") { a++; next }
        cls = $3 ~ /^parent #/ ? "parent-open" : $3 ~ /^hold by/ ? "hold" : $3 ~ /^files claimed/ ? "files-claimed" : $3 == "wip cap" ? "wip-cap" : "other"
        out = out sprintf("%s\tnot-ready\tdispatched\t%s\t%s\n", $1, $3, cls)
      } }
    END { printf "compared=%d agreed=%d idle=%d\n%s", c, a, i, out }' "$dec"
}
