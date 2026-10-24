#!/bin/bash
# bin/lib/ready-queue.sh — ONE definition of "what is ready to build".
# Sourced, never executed.
#
# WHY IT EXISTS (BH-1033, state→DB slice 8). "This ticket is ready" has lived in
# logs/READY-QUEUE.log: a file on ONE box, read by four lanes, each with its own
# grep. bin/stale-owed-tickets.sh has to ssh into the owning box to append a
# line; bin/triage-gate.sh brakes the whole tick on `grep -qE '^[A-Z]+-[0-9]'`
# of that file, so a box whose append never landed triages nothing and says
# nothing; and the 45-minute skip fingerprint is the file's own bytes, so a
# ticket that exists only as a row is invisible to every one of them. The same
# fact now also lives as a `build_queue` row with `status='ready'`, which every
# box can read and any box can write.
#
# FOUR GREPS BECAME ONE READER. The union is here, not in each lane: a lane that
# kept its own grep would pass every behaviour test and still be blind to a row,
# which is exactly the shape of the bug this slice removes.
#
# THE FILE STILL WINS, AND THE FILE IS STILL WRITTEN. Its lines come out first
# and a key present in both is emitted once, from the file — the file is the
# format every consumer already parses, and for one full cycle it is also the
# fallback. Everything here is fail-open: flag off, no client, or an unreachable
# worker and each function degrades to precisely the grep it replaced, with one
# log line saying so.
#
# SCOPED TO THE PROJECT (BH-4120). The file is one per BOX, and a box can host
# several projects: box-small's file held ~50 of project-8's
# PB lines, rq_any answered "there is work" for harness-console (0 open issues),
# and the gate bought it a paid queue tick on every churn of the shared file.
# So with a project argument the FILE lines are filtered too (_rq_scope):
#   1. a line carrying `project=<name>` belongs to that project only;
#   2. otherwise a GitHub-Issues project (fleet.conf board_prefix `-`) owns the
#      lines whose key prefix is its own (BH- / HC-), read from its rendered
#      prompt exactly as preplan_key_prefix reads it;
#   3. an in-app project owns the untagged lines whose prefix is NO
#      GitHub-Issues project's — in-app boards have no prefix registry, and
#      several share TK-.
# fleet.conf's board_prefix column cannot answer rule 2 by itself: it is the
# board API PATH (/api/board), and every GitHub-Issues project has `-` there.
# FAIL-OPEN to the whole file when the answer cannot be read: no project, no
# bin/fleet-conf.sh, a project fleet.conf does not know, or a GitHub-Issues
# project whose prompt has no launch line. That is the pre-BH-4120 behaviour.
#
# Pure bash, set -u safe. No writes except rq_put / rq_drop and the log line.

# THE CLIENT IS SOURCED HERE, ONCE, so a call site needs one line and cannot
# forget the half that reads the rows. A tree with no client — a scratch
# fixture, a box that has not synced — falls straight through: rq_on is false
# and every function below is the grep it replaced.
# rq_root -> $HARNESS, else $H, else nothing (BH-2613). With no root the client
# is not loaded at all: bin/jobs-client.sh falls back to the literal box root
# for its env and logs, so no root reads exactly like a tree with no client.
rq_root() { printf '%s' "${HARNESS:-${H:-}}"; }
if ! command -v ready_queue_rows_on >/dev/null 2>&1 && [ -n "$(rq_root)" ]; then
  for _RQ_P in "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh" \
               "$(rq_root)/bin/jobs-client.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_RQ_P" ] && { . "$_RQ_P"; break; }
  done
  unset _RQ_P
fi

# rq_file <harness> — the log, which is still the log. Nothing with no root.
rq_file() { local h="${1:-$(rq_root)}"; [ -n "$h" ] || return 0; printf '%s' "$h/logs/READY-QUEUE.log"; }

# rq_log <harness> <message> — one line per fail-open, never a page. The ready
# set degrading to the file is normal; it becoming silently empty is not, and
# this is where an operator finds out which happened.
rq_log() {
  local h="${1:-$(rq_root)}" msg="${2:-}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s [ready-queue] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$msg" \
    >> "$h/logs/ready-queue.log" 2>/dev/null
  return 0
}

# rq_on — rc 0 when the ready ROWS are read. Absent client = off, which is the
# 2026-07-23 behaviour byte for byte.
# COST, EXACTLY. ready_queue_rows_on memoises per PROCESS, and every reader in
# bin/triage-gate.sh runs inside a command substitution (the rq_any queue brake
# under "# 2. queued build work", the rq_fp hash beside it, the PRNUMS
# rq_lines), so the memo dies with each subshell: three
# settings GETs per project per tick with the flag OFF, not one. They go to the
# coordination worker, never to GitHub, and no /api/queue request is made while
# the flag is off (asserted in tests/ready-queue-rows-test.sh §2).
rq_on() {
  command -v ready_queue_rows_on >/dev/null 2>&1 || return 1
  ready_queue_rows_on
}

# rq_rows <harness> [project] — the ready ROWS, as queue_ready_list's TSV.
#   One read, in one place, so the three readers below cannot drift apart in
#   what they consider a row. NOT MEMOISED, deliberately: every caller in this
#   file is reached through a command substitution or a pipeline, so a cache
#   written here would be written in a subshell and thrown away with it — a memo
#   that cannot work is worse than none, because the next reader believes it.
#   Each read is one request to the coordination worker (not GitHub); the lanes
#   that make three of them run every ten minutes.
#   rc 1 -> the read failed. The CALLER logs, because only the caller knows what
#           it was about to do with the set.
rq_rows() {
  local project="${2:-}"
  command -v queue_ready_list >/dev/null 2>&1 || return 1
  queue_ready_list "$project" 2>/dev/null
}

# _rq_key_prefix <harness> <project> — a GitHub-Issues project's ticket-key
#   prefix (BH, HC), from the launch line in its rendered prompt. The same
#   one-line read as bin/lib/preplan-lib.sh:preplan_key_prefix, which is not
#   sourced here because that lib is large; tests/ready-queue-scope.bh-4120-test.sh
#   pins that the two agree. Nothing and rc 1 when there is no launch line.
_rq_key_prefix() {
  local h="${1:-}" p="${2:-}" pfx
  [ -n "$h" ] && [ -n "$p" ] || return 1
  pfx=$(grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$h/prompts/$p.md" 2>/dev/null | head -1 | cut -d- -f1)
  [ -n "$pfx" ] || return 1
  printf '%s\n' "$pfx"
}

# _rq_scope <harness> <project> — stdin queue lines -> this project's lines, by
#   the three rules in the header. One awk pass (mawk-safe), plus a handful of
#   registry reads for an in-app project. Every case it cannot decide is `cat`.
#   No title mention-matching (bin/project-of.sh): it forks per line, and a PB
#   title that names "harness-console" would hand the line to the wrong board.
_rq_scope() {
  local h="${1:-}" project="${2:-}" fc bp mine="" foreign=" " g pfx
  fc="$h/bin/fleet-conf.sh"
  if [ -z "$project" ] || [ ! -x "$fc" ]; then cat; return 0; fi
  bp=$("$fc" "$project" board_prefix 2>/dev/null)
  if [ -z "$bp" ]; then cat; return 0; fi
  if [ "$bp" = - ]; then
    mine=$(_rq_key_prefix "$h" "$project") || { cat; return 0; }
  else
    # The GitHub-Issues projects: every project minus the ones with a board.
    for g in $(awk 'NR == FNR { b[$1] = 1; next } !($1 in b)' \
                 <("$fc" --projects-with-board 2>/dev/null) <("$fc" --projects 2>/dev/null)); do
      pfx=$(_rq_key_prefix "$h" "$g") && foreign="$foreign$pfx "
    done
  fi
  awk -v p="$project" -v mine="$mine" -v foreign="$foreign" '
    NF == 0 { next }
    {
      tok = ""
      if (match($0, /(^|[ \t])project=[a-z0-9-]+/)) {
        tok = substr($0, RSTART, RLENGTH); sub(/^[ \t]*project=/, "", tok)
      }
      if (tok != "") { if (tok == p) print; next }
      i = index($1, "-"); kp = (i > 1) ? substr($1, 1, i - 1) : $1
      if (mine != "") { if (kp == mine) print; next }
      if (index(foreign, " " kp " ") == 0) print
    }'
}

# rq_lines <harness> [project] — every ready ticket as a QUEUE LINE, file first.
#   With the flag off this is `grep -E '^[A-Z]+-[0-9]' READY-QUEUE.log` scoped
#   to the project by _rq_scope (BH-4120); with no project, or wherever the
#   scope cannot be read, it is exactly that grep, as all four callers ran it.
#   The row dedupe below keys on the SCOPED lines, so a row of ours whose key
#   appears only on another project's line still comes out.
#   A row with no `ready_line` in its meta is SYNTHESIZED into the shape the
#   consumers parse — `<KEY> <ticket-id> — ... project=<name>` — because
#   bin/project-of.sh and bin/preplan-candidates.sh bucket on that `project=`
#   token and a line without it is a ticket nobody pre-plans.
#   A row that DOES carry a line but no `project=` token gets the token appended
#   from the row's own project column, which is authoritative. The only
#   production writer of a ready_line is bin/stale-owed-tickets.sh:LINES, whose
#   shape was `<KEY> OWED-STALE <n>h [<status>/<waitingOn>] <title>` with no
#   `project=` in it until BH-4120 appended one, so rows written before that
#   still lack it. Without this, bin/preplan-candidates.sh falls
#   through to bin/project-of.sh mention-matching on the TITLE and drops the
#   line when the guess is not $PROJECT (rc: the row is never pre-plannable),
#   and bin/preplan-tick.sh — which reads rows fleet-wide — pre-plans it under
#   whichever project the title happens to mention. The row knows; the line
#   should say so.
# _rq_norm — stdin: READY-QUEUE.log; stdout: its live lines, each starting with
# the ticket key. A line that already starts with `<KEY>` passes unchanged. A line
# a session wrote timestamp-first (`<ISO> <project> <ticket-id> <KEY> size=…`) is
# re-led by its first `[A-Z]+-[0-9]+` token, the timestamp dropped and
# `project=<p>` appended when the word after the timestamp names a project and the
# line has none. Before this the readers below kept only `^[A-Z]+-[0-9]`, so such
# a line was dead: project-3 TK-319 (deferred 2026-10-21 23:38Z) sat ~45 h until the
# daily full sweep, and all 25 lines of that box's file had the shape. Every
# other line that does not start with a key (comments, `[HOTFIX] …`, prose) is
# dropped, exactly as before.
_rq_norm() {
  # The fleet's project names, so the word after a timestamp becomes project=
  # ONLY when it is a real project (lead review #8257: `<ISO> deferred TK-1 …`
  # must not become project=deferred, which _rq_scope would drop everywhere).
  local plist="" fc="${1:-${HARNESS:-}}/bin/fleet-conf.sh"
  [ -x "$fc" ] && plist=" $("$fc" --projects 2>/dev/null | tr '\n' ' ') "
  awk -v plist="$plist" '
    /^[A-Z]+-[0-9]/ { print; next }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0; proj = ""
      # ONLY a timestamp-first line is re-led. Any other shape that does not
      # start with a key (`[HOTFIX] BH-1 …`, prose) stays dropped, as before.
      if (!match(line, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][^ ]* +/)) next
      line = substr(line, RLENGTH + 1)
      if (match(line, /^[a-z][a-z0-9-]* /)) {
        w = substr(line, 1, RLENGTH - 1)
        if (index(plist, " " w " ")) proj = w
      }
      if (!match(line, /[A-Z]+-[0-9]+/)) next
      key = substr(line, RSTART, RLENGTH)
      rest = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
      gsub(/  +/, " ", rest); sub(/^ +/, "", rest); sub(/ +$/, "", rest)
      out = key (rest != "" ? " " rest : "")
      if (proj != "" && out !~ /(^| )project=/) out = out " project=" proj
      print out
    }'
}
rq_lines() {
  local h="${1:-$(rq_root)}" project="${2:-}" q file_lines="" keys rows
  local p key tid line lp
  q=$(rq_file "$h")
  [ -n "$q" ] && file_lines=$(_rq_norm "$h" < "$q" 2>/dev/null | _rq_scope "$h" "$project")
  [ -n "$file_lines" ] && printf '%s\n' "$file_lines"
  rq_on || return 0
  rows=$(rq_rows "$h" "$project") || {
    rq_log "$h" "ready rows unreachable (${project:-fleet}) — the READY-QUEUE.log lines are the whole queue this tick"
    return 0
  }
  [ -n "$rows" ] || return 0
  keys=$(printf '%s\n' "$file_lines" | grep -oE '^[A-Z]+-[0-9A-Za-z]+' | sort -u)
  # NEWLINE-WRAPPED AND MATCHED WITH `case`, NOT PIPED INTO `grep -q`. This
  # function runs under the `-o pipefail` bin/jobs-client.sh sets, and grep -q
  # exits at the first match: past the pipe buffer the `printf` feeding it takes
  # SIGPIPE, the pipeline is rc 141, the `&& continue` never fires and the row's
  # line is emitted a SECOND time for a key the file already carried. Same shape
  # as the BH-1044 dedupe read and as bin/preplan-tick.sh's sweeps (§15/§16).
  keys=$'\n'"$keys"$'\n'
  while IFS=$'\t' read -r p key tid line; do
    [ -n "${key:-}" ] || continue
    case "$keys" in *$'\n'"$key"$'\n'*) continue ;; esac
    lp="${p:-$project}"
    case "${line:--}" in
      ''|-) line="$key ${tid:--} — ready row project=$lp" ;;
      # `project=[a-z-]+` is verbatim what both consumers grep for.
      *project=[a-z-]*) : ;;
      *) [ -n "$lp" ] && line="$line project=$lp" ;;
    esac
    printf '%s\n' "$line"
  done <<EOF
$rows
EOF
  return 0
}

# rq_any <harness> [project] — rc 0 when there is ready work at all. This is the
# triage brake, and the whole point of the slice: a `ready` row with no log line
# is real work, and a tick that cannot see it does nothing and reports nothing.
rq_any() {
  local out
  out=$(rq_lines "${1:-}" "${2:-}")
  [ -n "$out" ]
}

# rq_fp <harness> [project] — the ready ROWS' contribution to a cost-brake
# fingerprint, timestamp-normalised.
#   EMPTY WITH THE FLAG OFF, deliberately: a fingerprint input that appeared out
#   of nowhere would read as new-world on every project at once and buy one paid
#   session per project for nothing.
#   The ISO timestamps are stripped for the reason the file's own hash strips
#   them (2026-08-22, the $90/day project-1 loop): sessions restamp "Re-checked
#   <ts>" / "last probe <ts>" on every no-action tick, which changed the hash
#   every 10 minutes and meant the 45-minute skip never engaged.
rq_fp() {
  local h="${1:-$(rq_root)}" project="${2:-}" rows
  rq_on || return 0
  rows=$(rq_rows "$h" "$project") || {
    rq_log "$h" "ready rows unreachable (${project:-fleet}) — the queue fingerprint is the file's bytes this tick"
    return 0
  }
  printf '%s' "$rows" | sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g'
  return 0
}

# rq_fp_file <harness> [project] — the FILE's contribution to the queue
#   fingerprint (bin/triage-gate.sh's QFP), scoped like rq_lines.
#   When scoping drops no key line — a single-project box, no project, any
#   fail-open — it is the whole file exactly as `cat` prints it, comments
#   included, so that box's fingerprint is byte-identical to before BH-4120 and
#   no project buys a paid tick on deploy. Otherwise only this project's key
#   lines, so another project's queue churn never re-offers this one.
rq_fp_file() {
  local h="${1:-$(rq_root)}" project="${2:-}" q all scoped
  q=$(rq_file "$h")
  [ -n "$q" ] && [ -r "$q" ] || return 0
  all=$(_rq_norm "$h" < "$q" 2>/dev/null)
  scoped=$(printf '%s\n' "$all" | _rq_scope "$h" "$project")
  if [ "$all" = "$scoped" ]; then cat "$q"; else printf '%s\n' "$scoped"; fi
  return 0
}

# rq_put <harness> <project> <key> [ticket-id] [line] — enqueue a ready ticket.
# The row is fleet-visible, so the box that owns the project needs no ssh to
# learn about it. The caller keeps appending the file line for one cycle.
rq_put() {
  local h="${1:-$(rq_root)}" project="${2:-}" key="${3:-}" tid="${4:-}" line="${5:-}"
  rq_on || return 0
  command -v queue_ready_put >/dev/null 2>&1 || return 0
  [ -n "$project" ] && [ -n "$key" ] || return 1
  queue_ready_put "$project" "$key" "$tid" "$line" >/dev/null 2>&1 && return 0
  rq_log "$h" "could not enqueue $project/$key as a ready row — the READY-QUEUE.log line is the whole enqueue"
  return 0
}

# rq_drop <harness> <project> <key>... — the row half of consuming a queue line.
#   With an EMPTY project the row set is asked which project each key belongs
#   to: bin/queue-line-drop.sh is handed keys and nothing else, and guessing a
#   project from a key would patch the wrong row on a fleet where two boards
#   share a prefix. EVERY project holding the key is dropped, not the first one
#   the worker listed (BH-1305): the file half of the same consume strips
#   `^<KEY>[[:space:]]` for every project's line, so a row half that forgot one
#   board leaves a `ready` row with no line — rq_any keeps answering "there is
#   work", the fingerprint never settles, and triage buys paid ticks for a key a
#   session already consumed. The two halves must forget the same thing.
#   Always rc 0. A key with no row is the common case and is not a failure; a
#   409 means the row is no longer `ready` (a box is building it) and the live
#   build keeps its row.
#   A REFUSAL AND AN OUTAGE GET DIFFERENT LINES. rc 9 is the worker answering
#   ("a box holds this build"); anything else is the worker not answering. One
#   line covering both would tell an operator the database was unreachable on
#   the launch-then-drop race, which is the normal shape of parallel triage.
# _rq_drop_row <harness> <project> <key> — ONE row's drop and its rc handling.
#   Hoisted out of rq_drop's loop so the rc 9 / outage split exists exactly once
#   now that a single key can drop N rows. Always rc 0.
_rq_drop_row() {
  local h="${1:-}" p="${2:-}" k="${3:-}" rc
  queue_ready_drop "$p" "$k" "consumed from logs/READY-QUEUE.log" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 9 ]; then
    rq_log "$h" "the ready row for $p/$k is no longer ready — a box holds this build, and it keeps its row; the file line is gone"
  else
    rq_log "$h" "could not drop the ready row for $p/$k — the worker is unreachable; the file line is gone either way"
  fi
  return 0
}

rq_drop() {
  local h="${1:-$(rq_root)}" project="${2:-}" rows k p projects
  shift 2 2>/dev/null || return 0
  rq_on || return 0
  command -v queue_ready_drop >/dev/null 2>&1 || return 0
  [ $# -gt 0 ] || return 0
  if [ -z "$project" ]; then
    rows=$(rq_rows "$h" "") || {
      rq_log "$h" "ready rows unreachable — dropped $* from the file only"
      return 0
    }
  fi
  for k in "$@"; do
    if [ -n "$project" ]; then
      _rq_drop_row "$h" "$project" "$k"
      continue
    fi
    # EVERY project holding the key, not the first. A key with no row anywhere
    # is the quiet common case and prints nothing, so the loop body never runs.
    projects=$(printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2==k {print $1}' | sort -u)
    # FED BY A HEREDOC, not `... | while read` — the same shape rq_lines uses
    # above. A pipeline runs the loop in a subshell, so anything a later edit
    # wants to carry out of it (a count, a "one of them refused" flag) would die
    # with that subshell, and this file runs under the `-o pipefail`
    # bin/jobs-client.sh sets, which turns every such surprise into an rc.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      _rq_drop_row "$h" "$p" "$k"
    done <<EOF
$projects
EOF
  done
  return 0
}
