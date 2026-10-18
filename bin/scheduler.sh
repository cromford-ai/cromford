#!/bin/bash
# bin/scheduler.sh [<project>|--all] — BH-6978 (wave 2 of #6547): the
# scheduler computes the ready set. Hub only, every 5 min
# (cron/lanes/733-scheduler.cron, behind bin/hub-lease.sh check). No LLM call,
# no paid call. It DISPATCHES NOTHING itself: no code path here reaches
# bin/run-build.sh, bin/fly-dispatch.sh, the ready queue, the pool queue or
# POST /api/jobs. BH-6979 (wave 3): every tick posts the whole set (one
# verdict per candidate, in flight included), and with scheduler.mode=enforce
# the pool and run-build read it through bin/lib/sched-gate.sh
# (GET /api/scheduler/ready) and dispatch only from it. In enforce the tick
# also reads bin/sibling-serial.sh for its data (step 3b), because
# sibling-serial no longer decides in the pool.
#
# One run, per project:
#   1. Reads, in parallel: the open `ai-build` issues (GitHub REST, at most 3
#      pages), GET /api/ticket-edges, GET /api/scheduler/holds, GET /api/jobs
#      (build, 300), GET /api/ledger kind=pr_state (1000), the running file
#      claims (fclaim_list_dir), GET /api/preplans (planned files), GET
#      /api/decisions since the window start, GET /api/ledger kind=stack-wait,
#      bin/overlap-schedule.sh <p>, bin/free-slots.sh <p> and the window's
#      lines of logs/fly-pool.log.
#   2. In flight (not judged): a running build job, or the newest build job's
#      PR whose pr_state ledger row is not CLOSED.
#   3. Parent state per hard-edge parent: the newest build job's PR in the
#      pr_state ledger (MERGED -> merged, CLOSED -> step d, else open); no job
#      PR or no row -> ONE REST read of the PR with head ticket/<pfx>-<p>
#      (sw_parent_pr); d: in the open ai-build listing -> open, else ONE REST
#      read of the issue (closed -> closed-done). At most
#      scheduler.parent_reads_max (20) such reads per tick; past it -> unknown.
#      A branch is never read.
#   3b. Enforce only: bin/sibling-serial.sh parts <p> once, then one
#      `SIBLING_STACK=0 sibling-serial.sh check <p> <KEY>` per judged candidate
#      that is a part, ascending, at most scheduler.sibling_checks_max (20).
#      rc 3 `SIBLING_SERIAL <KEY> waits for <PFX>-<s> ...` -> <D>/sibling
#      `<n>\t<s>`; a part past the cap -> `<n>\t-` (unknown, sibling check cap).
#   4. sched_decide, sched_lanes_did, sched_compare (bin/lib/scheduler.sh).
#   5. logs/scheduler.log: one `SCHED ticket=<KEY> ready=yes|no|unknown
#      reason=<r>` line per judged candidate and one summary line
#      `SCHED-TICK project=<p> mode=<shadow|enforce> at=<AT> candidates= ready=
#      not_ready= unknown= in_flight= compared= agreed= idle= diffs=
#      post=ok|failed:<http> partial=<names|->`.
#   6. ONE POST /api/scheduler/diffs (idempotent on project+at), with
#      `verdicts`: every judged candidate (yes|no|unknown, its reason) and
#      every in-flight one (in-flight, `in flight`). AT is the
#      tick time cut to the minute. state/scheduler/<p>.last is written only
#      after a 2xx with ok:true, so a failed tick's window is read again.
#
# The window is (state/scheduler/<p>.last, AT] when that stamp is less than
# 900 s old (three */5 ticks), else (AT - 300 s, AT] (one tick).
#
# Exit paths, all rc 0: the lane switch is on -> nothing; scheduler.mode=off
# -> one `SCHED-TICK project=<p> mode=off` line; the lock is held -> one
# `skipped (running)` line; no key prefix or repo slug -> one `skipped=` line;
# a required input unreadable (issues, edges, holds, jobs, pr_state, claims,
# preplans; a 404 counts) -> one `skipped=inputs reads_failed=<names>` line,
# no POST; a lane input unreadable (decisions, stack-wait, pool-log, overlap)
# -> the verdicts are written and the POST carries compared=0 and no diffs.
#
# Settings rows: scheduler.mode (shadow; enforce; off; any other value runs
# shadow and says `mode=<v> not a mode`), scheduler.projects (cromford,
# the --all list, and the projects enforce applies to),
# scheduler.parent_reads_max (20), scheduler.sibling_checks_max (20). Those
# values are the code defaults when a row is missing.
#
# Test seam (catalog/lanes.d/scheduler.json, not settable): SCHED_NOW (epoch
# seconds used instead of the clock; only all-digit values are used).
#
# OFF: flags/lane-off-scheduler (bin/harness-ctl.sh off scheduler).
# Doc: docs/notes/2026-10-16-BH-6978-scheduler-shadow.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit scheduler
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply scheduler

mkdir -p "$H/logs" "$H/locks" "$H/state/scheduler" 2>/dev/null
LOG="$H/logs/scheduler.log"
if [[ "${SCHED_NOW:-}" =~ ^[0-9]+$ ]]; then NOW=$SCHED_NOW; else NOW=$(date -u +%s); fi
STAMP=$(date -u -d "@$NOW" +%FT%TZ)
line() { printf '%s %s\n' "$STAMP" "$1" >> "$LOG"; }

exec 8> "$H/locks/scheduler.lock" 2>/dev/null || { line "skipped (no lock file)"; exit 0; }
flock -n 8 || { line "skipped (running)"; exit 0; }

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" 2>/dev/null || { line "skipped (no jobs client)"; exit 0; }
# shellcheck source=bin/lib/gh-rest.sh
. "$SELF/lib/gh-rest.sh" 2>/dev/null
# shellcheck source=bin/lib/file-claims.sh
. "$SELF/lib/file-claims.sh" 2>/dev/null
# shellcheck source=bin/lib/preplan-lib.sh
. "$SELF/lib/preplan-lib.sh" 2>/dev/null
# shellcheck source=bin/lib/stack-wait.sh
. "$SELF/lib/stack-wait.sh" 2>/dev/null
# shellcheck source=bin/lib/scheduler.sh
. "$SELF/lib/scheduler.sh" || { line "skipped (no scheduler lib)"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sched.XXXXXX") || { line "skipped (mktemp)"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# setting <key> <default> — the row's value, or the default (no row, outage).
setting() { local v; v=$(setting_get "$1" 2>/dev/null | tr -d '[:space:]') && [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

MODE=$(setting scheduler.mode shadow)
case "$MODE" in
  shadow|off|enforce) ;;
  *) line "SCHED mode=$MODE not a mode; running shadow"; MODE=shadow ;;
esac
READS_MAX=$(setting scheduler.parent_reads_max 20)
[[ $READS_MAX =~ ^[0-9]+$ ]] || READS_MAX=20
SIB_MAX=$(setting scheduler.sibling_checks_max 20)
[[ $SIB_MAX =~ ^[0-9]+$ ]] || SIB_MAX=20

if [ "${1:-}" = --all ]; then PROJECTS=$(setting_get scheduler.projects 2>/dev/null) || PROJECTS=cromford
else PROJECTS="${1:-}"; fi
[ -n "${PROJECTS// /}" ] || { line "SCHED-TICK skipped=no-project"; exit 0; }

AT=$(date -u -d "@$((NOW - NOW % 60))" +%FT%H:%M:00Z)
AT_S=$((NOW - NOW % 60))

# get <name> <path> — one worker read into $D/<name>; a failed read leaves
# $D/.fail/<name>. A 404 is a failure here: an input that is not there is
# unreadable, never empty.
get() {
  _jobs_req GET "$2" > "$D/$1" 2>/dev/null || : > "$D/.fail/$1"
}

tick() {
  local p="$1" PFX SLUG D since last s fails partial n m k st
  [[ $p =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { line "SCHED-TICK project=$p skipped=bad-name"; return 0; }
  if [ "$MODE" = off ]; then line "SCHED-TICK project=$p mode=off"; return 0; fi
  PFX=$(preplan_key_prefix "$H" "$p") || { line "SCHED-TICK project=$p skipped=no-prefix"; return 0; }
  SLUG=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [[ $SLUG =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { line "SCHED-TICK project=$p skipped=no-slug"; return 0; }
  D="$TMP/$p"; mkdir -p "$D/.fail" "$D/planned" "$D/claims"

  local since_s=$((AT_S - 300))
  last=$(head -1 "$H/state/scheduler/$p.last" 2>/dev/null)
  if [[ $last =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    [ -n "$last" ] && s=$(date -u -d "$last" +%s 2>/dev/null) \
      && [ "$s" -lt "$AT_S" ] && [ $((AT_S - s)) -le 900 ] && since_s=$s
  fi
  since=$(date -u -d "@$since_s" +%FT%TZ)
  printf '%s\t%s\n' "$since" "$AT" > "$D/window"

  # ── the reads, independent ones in parallel ──────────────────────────────
  (
    : > "$D/issues.tsv"
    for k in 1 2 3; do
      gh_rest GET "repos/$SLUG/issues?state=open&labels=ai-build&per_page=100&page=$k" > "$D/issues.$k" 2>/dev/null \
        && jq -e 'type == "array"' "$D/issues.$k" >/dev/null 2>&1 || { : > "$D/.fail/issues"; exit 0; }
      jq -r '.[] | select(has("pull_request") | not) | .number' "$D/issues.$k" >> "$D/issues.tsv"
      [ "$(jq 'length' "$D/issues.$k")" -lt 100 ] && break
    done
  ) &
  get edges.json "/api/ticket-edges?project=$p" &
  get holds.json "/api/scheduler/holds?project=$p" &
  get jobs.json "/api/jobs?project=$p&kind=build&limit=300" &
  get prstate.json "/api/ledger?kind=pr_state&limit=1000" &
  get preplans.json "/api/preplans?project=$p" &
  get decisions.json "/api/decisions?project=$p&since=$(date -u -d "@$since_s" '+%Y-%m-%d%%20%H:%M:%SZ')&limit=500" &
  get stackwait.json "/api/ledger?kind=stack-wait&limit=1000" &
  { fclaim_list_dir "$p" "$D/claims" 2>/dev/null || : > "$D/.fail/claims"; } &
  { timeout 60 "$H/bin/overlap-schedule.sh" "$p" > "$D/overlap.out" 2>/dev/null || : > "$D/.fail/overlap"; } &
  { "$H/bin/free-slots.sh" "$p" 2>/dev/null | awk '{print $1; exit}' > "$D/cap"; } &
  {
    if [ -r "$H/logs/fly-pool.log" ]; then
      tail -n 5000 "$H/logs/fly-pool.log" | awk -v s="${since/T/ }" -v a="${AT/T/ }" \
        '{ t = $1 " " $2 } t > s && t <= a' > "$D/pool.log"
    else : > "$D/.fail/pool-log"; fi
  } &
  wait

  fails=""
  for n in issues edges.json holds.json jobs.json prstate.json claims preplans.json; do
    [ -e "$D/.fail/$n" ] && fails="$fails,${n%.json}"
  done
  jq -e '(.edges | type) == "array"' "$D/edges.json" >/dev/null 2>&1 || [ -e "$D/.fail/edges.json" ] || fails="$fails,edges"
  jq -e '(.holds | type) == "array"' "$D/holds.json" >/dev/null 2>&1 || [ -e "$D/.fail/holds.json" ] || fails="$fails,holds"
  if [ -n "$fails" ]; then line "SCHED-TICK project=$p mode=$MODE at=$AT skipped=inputs reads_failed=${fails#,}"; return 0; fi
  partial=""
  for n in decisions.json stackwait.json pool-log overlap; do [ -e "$D/.fail/$n" ] && partial="$partial,${n%.json}"; done
  jq -e '.truncated != true and (.rows | type) == "array"' "$D/decisions.json" >/dev/null 2>&1 \
    || [ -e "$D/.fail/decisions.json" ] || partial="$partial,decisions"
  partial=${partial#,}

  sort -n -u "$D/issues.tsv" > "$D/candidates"
  jq -r --arg x "$PFX-" '.preplans[]? | select((.ticket_key // "") | startswith($x)) | "\(.ticket_key)\t\(.planned_files // "" | @base64)"' \
    "$D/preplans.json" 2>/dev/null | while IFS=$'\t' read -r k s; do
      n=${k#"$PFX"-}; [[ $n =~ ^[1-9][0-9]*$ ]] && printf '%s' "$s" | base64 -d > "$D/planned/$n" 2>/dev/null
    done

  # newest build job per ticket number: <n>\t<status>\t<PR number or ->
  jq -r --arg x "$PFX-" --arg u "https://github.com/$SLUG/pull/" '.jobs[]? | select(.kind == "build")
      | select((.ticket_id // "") | startswith($x))
      | [(.ticket_id | ltrimstr($x)), .status,
         ((.meta // "" | tostring) | (index($u)) as $i | if $i == null then "-"
           else .[($i + ($u | length)):] | capture("^(?<n>[0-9]+)").n // "-" end)] | @tsv' \
    "$D/jobs.json" 2>/dev/null | awk -F'\t' '!seen[$1]++' > "$D/newest_job"
  jq -r '.ledgers[]? | "\(.key)\t\(.status)"' "$D/prstate.json" 2>/dev/null > "$D/prstate.tsv"
  prstate() { awk -F'\t' -v k="$SLUG#$1" '$1 == k {print $2; exit}' "$D/prstate.tsv"; }

  # ── in flight ────────────────────────────────────────────────────────────
  : > "$D/in_flight"
  while IFS= read -r n; do
    m=""
    IFS=$'\t' read -r _ _ m < <(awk -F'\t' -v n="$n" '$1 == n' "$D/newest_job")
    if jq -e --arg k "$PFX-$n" '[.jobs[]? | select(.kind == "build" and .ticket_id == $k and .status == "running")] | length > 0' \
        "$D/jobs.json" >/dev/null 2>&1; then echo "$n" >> "$D/in_flight"
    elif [ -n "${m:-}" ] && [ "$m" != - ] && [ "$(prstate "$m")" != CLOSED ]; then echo "$n" >> "$D/in_flight"
    fi
  done < "$D/candidates"

  # ── parents ──────────────────────────────────────────────────────────────
  local reads=0 pr br out
  : > "$D/parents"
  for k in $(jq -r '.edges[]? | select(.kind == "hard") | "\(.child) \(.parent)"' "$D/edges.json" \
      | awk 'NR == FNR {c[$1]; next} ($1 in c) {print $2}' <(grep -vxFf "$D/in_flight" "$D/candidates") - | sort -n -u); do
    st=""; pr=""
    IFS=$'\t' read -r _ _ pr < <(awk -F'\t' -v n="$k" '$1 == n' "$D/newest_job")
    if [ -z "$pr" ]; then
      if [ "$reads" -ge "$READS_MAX" ]; then printf '%s\tunknown\n' "$k" >> "$D/parents"; continue; fi
      reads=$((reads + 1))
      pr=$(_jobs_req GET "/api/jobs?project=$p&kind=build&ticket_id=$PFX-$k&limit=5" 2>/dev/null \
        | jq -r --arg u "https://github.com/$SLUG/pull/" '[.jobs[]? | select(.kind == "build")][0].meta // "" | tostring
            | (index($u)) as $i | if $i == null then "-" else .[($i + ($u | length)):] | capture("^(?<n>[0-9]+)").n // "-" end' 2>/dev/null)
    fi
    [ -n "$pr" ] && [ "$pr" != - ] && case "$(prstate "$pr")" in
      MERGED) st=merged ;; CLOSED) st=d ;; "") ;; *) st=open ;;
    esac
    if [ -z "$st" ]; then
      if [ "$reads" -ge "$READS_MAX" ]; then printf '%s\tunknown\n' "$k" >> "$D/parents"; continue; fi
      reads=$((reads + 1))
      br="ticket/${PFX,,}-$k"
      out=$(sw_parent_pr "$SLUG" "$br")
      case "${out%% *}" in
        merged) st=merged ;; open) st=open ;; closed|none) st=d ;; *) st=unknown ;;
      esac
    fi
    if [ "$st" = d ]; then
      if grep -qx "$k" "$D/candidates"; then st=open
      elif [ "$reads" -ge "$READS_MAX" ]; then st=unknown
      else
        reads=$((reads + 1))
        # To a file, never inside $( ): GH_REST_STATUS stays in this shell.
        : > "$D/issue.json"; gh_rest GET "repos/$SLUG/issues/$k" > "$D/issue.json" 2>/dev/null
        case "$(jq -r '.state // empty' "$D/issue.json" 2>/dev/null)" in
          closed) st=closed-done ;; open) st=open ;; *) st=unknown ;;
        esac
      fi
    fi
    printf '%s\t%s\n' "$k" "$st" >> "$D/parents"
  done

  # ── enforce: sibling-serial's data (it no longer decides in the pool) ───
  # A failed or timed-out `parts` or `check` is `?` (unknown / sibling check
  # failed), never yes: no part map is not "not a part" (BH-6979 review).
  if [ "$MODE" = enforce ] && [ -x "$H/bin/sibling-serial.sh" ]; then
    : > "$D/sibling"
    if ! timeout 60 "$H/bin/sibling-serial.sh" parts "$p" > "$D/parts" 2>/dev/null; then
      grep -vxFf "$D/in_flight" "$D/candidates" | sort -n -u | awk '{print $0 "\t?"}' > "$D/sibling"
      : > "$D/parts"
    fi
    local sc=0 sout src
    while IFS= read -r n; do
      awk -F'\t' -v k="$PFX-$n" '$1 == k {f = 1} END {exit !f}' "$D/parts" || continue
      if [ "$sc" -ge "$SIB_MAX" ]; then printf '%s\t-\n' "$n" >> "$D/sibling"; continue; fi
      sc=$((sc + 1))
      sout=$(SIBLING_STACK=0 timeout 30 "$H/bin/sibling-serial.sh" check "$p" "$PFX-$n" 2>/dev/null); src=$?
      if [ "$src" = 3 ] && [[ $sout =~ ^SIBLING_SERIAL\ $PFX-$n\ waits\ for\ $PFX-([1-9][0-9]*) ]]; then
        printf '%s\t%s\n' "$n" "${BASH_REMATCH[1]}" >> "$D/sibling"
      elif [ "$src" != 0 ]; then
        printf '%s\t?\n' "$n" >> "$D/sibling"
      fi
    done < <(grep -vxFf "$D/in_flight" "$D/candidates" | sort -n -u)
  fi

  # ── decide, read what the lanes did, compare ─────────────────────────────
  sched_decide "$D" > "$D/decide.tsv"
  sched_lanes_did "$D" "$PFX" "$p" > "$D/lanes.tsv"
  sched_compare "$D/decide.tsv" "$D/lanes.tsv" > "$D/compare.out"
  local cmp compared agreed idle
  cmp=$(head -1 "$D/compare.out")
  tail -n +2 "$D/compare.out" > "$D/diffs.tsv"
  compared=$(sed -n 's/.*compared=\([0-9]*\).*/\1/p' <<<"$cmp"); agreed=$(sed -n 's/.*agreed=\([0-9]*\).*/\1/p' <<<"$cmp")
  idle=$(sed -n 's/.*idle=\([0-9]*\).*/\1/p' <<<"$cmp")
  if [ -n "$partial" ]; then compared=0; agreed=0; idle=0; : > "$D/diffs.tsv"; fi

  while IFS=$'\t' read -r n st s; do
    line "SCHED ticket=$PFX-$n ready=$st reason=$s"
  done < "$D/decide.tsv"

  local cand ready notr unk infl nd cut=""
  cand=$(wc -l < "$D/candidates"); infl=$(wc -l < "$D/in_flight")
  ready=$(awk -F'\t' '$2 == "yes"' "$D/decide.tsv" | wc -l)
  notr=$(awk -F'\t' '$2 == "no"' "$D/decide.tsv" | wc -l)
  unk=$(awk -F'\t' '$2 == "unknown"' "$D/decide.tsv" | wc -l)
  nd=$(wc -l < "$D/diffs.tsv")
  [ "$nd" -gt 200 ] && cut=" (cut to 200)"

  # Every verdict, so a reader can tell a complete set (count = candidates).
  { cut -f1-3 "$D/decide.tsv"; awk 'NF {print $1 "\tin-flight\tin flight"}' "$D/in_flight"; } | head -1000 \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {ticket: .[0], ready: .[1], reason: ((.[2] // "") | .[0:200])})' > "$D/verdicts.json"
  head -200 "$D/diffs.tsv" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {ticket: .[0], scheduler_says: .[1], lanes_did: .[2], reason: .[3], reason_class: .[4]})' > "$D/diffs.json"
  jq -nc --arg p "$p" --arg at "$AT" --arg m "$MODE" --arg partial "$partial" --slurpfile d "$D/diffs.json" --slurpfile v "$D/verdicts.json" \
    --argjson c "{\"candidates\":$cand,\"ready\":$ready,\"not_ready\":$notr,\"unknown\":$unk,\"in_flight\":$infl,\"compared\":$compared,\"agreed\":$agreed,\"idle\":$idle}" \
    '{project: $p, at: $at, mode: $m, counts: $c, diffs: $d[0], verdicts: $v[0]} + (if $partial == "" then {} else {partial: $partial} end)' > "$D/body.json"
  local post prc=0
  # Into a file, never a $( ): JOBS_HTTP must stay in this shell.
  _jobs_req POST /api/scheduler/diffs "$(cat "$D/body.json")" > "$D/post.out" 2>/dev/null || prc=$?
  if [ "$prc" = 0 ] && jq -e '.ok == true' "$D/post.out" >/dev/null 2>&1; then
    post=ok
    printf '%s\n' "$AT" > "$H/state/scheduler/$p.last"
  else post="failed:${JOBS_HTTP:-none}"; fi
  line "SCHED-TICK project=$p mode=$MODE at=$AT candidates=$cand ready=$ready not_ready=$notr unknown=$unk in_flight=$infl compared=$compared agreed=$agreed idle=$idle diffs=$nd$cut post=$post partial=${partial:--}"
}

for P in $PROJECTS; do tick "$P"; done
exit 0
