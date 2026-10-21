# shellcheck shell=bash
# bin/lib/mc/project-placement.sh — BH-6890 (BH-6881.6): the merge conductor
# for a WHOLE project on a lane-run machine. Sourced by
# bin/lib/mc/fly-workers.sh (mc_fly_project_gate), never run. Not a conductor
# module (no module header): the hub tick calls it before any GitHub read.
#
# With lane_placement.merge-conductor.<project> = fly (bin/lib/lane-placement.sh
# reads the project row first), the hub's tick of that project does no PR work.
# It enqueues ONE lane_runs row (lane merge-conductor, project <project>, args
# bin/merge-conductor-project.sh <project>), and a machine running
# bin/lane-run-worker.sh claims it. The machine holds the project lease for the
# whole run and lands (docs/notes/2026-10-19-BH-6890-conductor-per-project.md).
# The partial unique index lane_runs_live keeps one live row per project.
#
# The fallback row lane_fallback.merge-conductor.<project> is `hub` (no row,
# any other value, or a settings outage) or `off` (the trimmed, lowercased
# value `off` only).
#
#   mc_proj_fly <project>
#       rc 0 when the project is placed fly or box:<name> (lp_decide
#       merge-conductor <project>). Sets LP_WHY, MC_PROJ_BOX (the box name, or
#       empty for fly) and MC_PROJ_TAG (the log tag: project-fly or
#       project-box(<name>)).
#
# BOX PLACEMENT (BH-7636). lane_placement.merge-conductor.<project> =
# box:<name> runs the gate exactly as fly: the row is enqueued the same way,
# and only the box <name> claims it (bin/lane-run-worker.sh --box <name>, from
# the box's own cron; the jobs worker routes the row). Two things differ. A
# claimed row whose lease ran out <stale-s> ago or more is stale
# (box-silent): the box died mid-run, so the gate withdraws it with
# expired:1 and takes the project back. And a take-back writes ONE ALERTS
# line per outage (bin/lane-alert.sh --id mc-project-box-<project>), held by
# the <project>.box-down mark, in place of the BH-7462 no-capacity streak
# line. The mark goes when the box answers again (a live claimed row, or a
# done, deferred or failed row with a run result) or the placement is hub.
#   mc_proj_fallback <project>
#       prints hub or off.
#   mc_proj_newest <rows-json> <project> <now-epoch> <stale-s> [box 0|1]
#       one line `<kind> <id> <detail>` for the NEWEST row of <project> in a
#       by-prefix answer. kind: none (no row), live (queued less than <stale-s>
#       ago, or claimed), stale (queued <stale-s> or more, detail = its age;
#       with box 1, also claimed with a lease_until <stale-s> or more in the
#       past, detail box-silent;
#       or died with a prof_line that starts `withdrawn `, detail withdrawn:
#       the hub takes it back once (.taken, .nocap-at) and, after
#       mc_project_fly.nocap_backoff_s, enqueues a new row),
#       failed (died, failed, a done rc that is not 0, or a done row with no
#       `PROF mc-project` line; detail names which), deferred (a clean done
#       row whose PROF line has deferred=<w> with w not `-`; detail = w),
#       done (a clean done row). rc 1 when the answer does not parse.
#   mc_proj_defer_field <keys-file> <slug>
#       BH-7635, on the machine: the value of the PROF field deferred_prs= from
#       the run's MC_PR_DEFERRED_KEYS_FILE (lines `<word> <slug>#<n>`, written
#       by mc_defer_word). Prints `<count>:<word>/<n>,...` (sorted, unique,
#       only lines of <slug>, case-insensitive), `-` when there are none, and
#       `overflow` past MC_PROJ_DEFER_FIELD_MAX bytes.
#   mc_proj_defer_keys <rows-json> <project> <slug> <words>
#       BH-7635, on the hub: rc 0 prints the PR keys `<slug>#<n>,...` of the
#       newest row of <project> when its deferred_prs= field names a PR for
#       every word of <words> (the row's deferred= value), and sets
#       MC_PROJ_DEFER_ROUTE (`<word> -> hub keyed <keys>; ...`) and
#       MC_PROJ_DEFER_OUT (what it printed). rc 1 prints
#       why not (no PR names, overflow, list truncated, bad token <t>,
#       step <s> not in deferred=, <word> has no PR): the hub keeps the full
#       tick for that row.
#   mc_proj_alert <project> <text>
#       ONE ALERTS line (bin/lane-alert.sh --id mc-project-fly-<project>) per
#       project per settings row mc_project_fly.alert_s (fallback 3600 s): the
#       stamp is
#       state/merge-conductor/project-fly/<project>.alert-at.
#   mc_proj_publish <project>
#       applies the project's pending write-backs and publishes its snapshot
#       (bin/lib/lane-run-inputs.sh), so the run starts from the hub's files
#       of now. At most once per mc_project_fly.publish_min_s (fallback 120 s)
#       per project (stamp <project>.published-at). Both lib calls wait up to
#       mc_project_fly.publish_lock_wait_s (fallback 30 s, at most 600) for
#       the per-project snapshot lock the cron publisher
#       (lane-snapshot-publish.sh --lane merge-conductor) also takes. A
#       failure logs one line with its reason (`rc=<n>, no output` when the
#       lib printed none). After a failed publish it reads the current
#       snapshot (_mc_proj_snap_fresh): rc 0 when the cron publisher's
#       snapshot is fresh enough (no stamp written), rc 1 with
#       MC_PROJ_PUB_WHY set when it is not, and then no row is enqueued
#       (BH-7520: run 12126 got a stale snapshot and ended rc 66).
#   mc_proj_gate <project> <stale-s>
#       the hub's decision for one project tick. rc 1 = not placed fly, or a
#       hub fallback: run today's hub tick. rc 2 = a hub fallback for a
#       finished row (failed, or deferred with no full PR list): run the WHOLE
#       project on the hub once, keyed or not. rc 4 (BH-7635) = a deferred row
#       whose PROF line names the PR of every deferred step: run a keyed hub
#       tick of only those PRs (MC_PROJ_TAKEBACK_KEYS, mc_proj_takeback_keyed),
#       never a full tick. A deferred row logs one route line that says where
#       each step went. rc 0 = handled here: the hub runs nothing more for
#       this project this tick (a row was enqueued or is live, or the fallback
#       is off). One log line per decision. A placement that cannot be read
#       (mc_proj_fly rc 3) fails closed for a project last placed fly
#       (<project>.placed) or with a live row: rc 0. Before any hub fallback
#       it applies the project's pending write-backs and writes the hub mark,
#       under the gate lock; a stale row is withdrawn first.
#   mc_proj_takeback_full <project>
#       a keyed hub tick's take-back: ONE full tick of <project> under the
#       BH-5463 full-tick lock (the driver's tick_project calls it on rc 2).
#   mc_proj_takeback_keyed <project> <keys>
#       BH-7635: the hub runs a machine's deferred steps as ONE keyed tick of
#       <keys> (MC_ONLY_PR), in the foreground of the marked tick, with no
#       full-tick lock (a keyed tick never takes it). tick_project calls it on
#       rc 4.
#   mc_proj_hub_mark <project>
#       writes this subshell's pid ($BASHPID) to <project>.hubtick. The gate
#       calls it, under its lock, before it answers a hub fallback.
#   mc_proj_hub_unmark <project>
#       removes <project>.hubtick when this subshell wrote it, under
#       <project>.lock (BH-7462), so it never removes the mark of a later
#       tick. When the lock is not taken in 10 s the mark is left; it ends
#       with its pid.
#
# Files under state/merge-conductor/project-fly/ (hub only):
#   <project>.owed      one line: a wake came while the row was live. The next
#                       tick that finds the row finished enqueues again.
#   <project>.taken     the id of the finished row the hub already took back,
#                       so the next tick enqueues a new row instead of taking
#                       the same row back again.
#   <project>.lock      serialises two hub ticks deciding for one project.
#   <project>.placed    the last placement read was fly (fail closed when the
#                       next read cannot be answered).
#   <project>.failed-n  consecutive machine-failed take-backs; at
#                       mc_project_fly.failed_alert_n (3) one held ALERTS line.
#   <project>.nocap-n   consecutive no-capacity cycles (a stale row withdrawn
#                       unclaimed and taken back) with the fallback hub; at
#                       mc_project_fly.nocap_alert_n (3) one held ALERTS line
#                       (BH-7462). A row a machine claimed resets it.
#   <project>.box-down  a box placement's take-back alerted (BH-7636): no
#                       second ALERTS line until the box answers again.
#   <project>.hubtick   `<pid> <start stamp> <epoch>` of the hub tick that runs
#                       <project> as a fallback (mc_proj_hub_mark), removed
#                       when it ends (mc_proj_hub_unmark, under
#                       <project>.lock). While that pid
#                       lives with that start stamp and the mark is younger
#                       than mc_project_fly.hubtick_max_s, no
#                       new row is enqueued: a machine and the hub never start
#                       work on one repo at the same time from this gate.
#
# The root is ${HARNESS:-${H:-}}. Defines functions only.

MC_PROJ_LANE=merge-conductor
# Code fallbacks of the settings rows mc_project_fly.alert_s,
# mc_project_fly.publish_min_s, mc_project_fly.failed_alert_n,
# mc_project_fly.hubtick_max_s, mc_project_fly.nocap_backoff_s,
# mc_project_fly.nocap_alert_n, mc_project_fly.publish_lock_wait_s and
# mc_project_fly.snapshot_margin_s (_mc_proj_int).
MC_PROJ_ALERT_S=3600
MC_PROJ_PUBLISH_MIN_S=120
MC_PROJ_FAILED_ALERT_N=3
MC_PROJ_HUBTICK_MAX_S=3600
MC_PROJ_NOCAP_BACKOFF_S=600
MC_PROJ_NOCAP_ALERT_N=3
MC_PROJ_PUBLISH_LOCK_WAIT_S=30
MC_PROJ_SNAPSHOT_MARGIN_S=300
# BH-7635: the longest deferred_prs= value. bin/lane-run-worker.sh keeps 512
# bytes of the PROF line, and the rest of an mc-project line is under 140.
MC_PROJ_DEFER_FIELD_MAX=360

_mc_proj_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_mc_proj_dir() { printf '%s/state/merge-conductor/project-fly' "$(_mc_proj_root)"; }

# _mc_proj_int <settings key> <fallback> — a whole number of seconds from
# the row, 1..86400, else the fallback.
_mc_proj_int() {
  local v=""
  _mc_proj_client >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null)
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [[ $v =~ ^[0-9]{1,5}$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 86400 ] || v="$2"
  printf '%s' "$((10#$v))"
}

# _mc_proj_put <file> <line> — one line into a state file, its dir made
# first; silent when it cannot be written (a hub with no project-fly dir yet).
_mc_proj_put() {
  { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; } 2>/dev/null
  return 0
}

_mc_proj_log() {
  if command -v mc_log >/dev/null 2>&1; then mc_log "$*"; else printf '%s\n' "$*" >&2; fi
}

# _mc_proj_client — rc 0 when lp_decide, lp_enqueue, setting_get and _jobs_req
# exist; sources bin/lib/lane-placement.sh when they do not.
_mc_proj_client() {
  local root
  if ! command -v lp_decide >/dev/null 2>&1; then
    root=$(_mc_proj_root)
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] || return 1
    # shellcheck source=bin/lib/lane-placement.sh
    . "$root/bin/lib/lane-placement.sh" || return 1
  fi
  _lp_client
}

# mc_proj_fly <project> — rc 0 placed fly, rc 1 hub, rc 3 not known (no jobs
# client, or the settings row could not be read: a stale cache and a D1
# outage). Sets LP_WHY.
mc_proj_fly() {
  local p="${1:-}"
  MC_PROJ_BOX=""; MC_PROJ_TAG=project-fly
  [ -n "$p" ] || return 1
  _mc_proj_client || { LP_WHY="no jobs client"; return 3; }
  lp_decide "$MC_PROJ_LANE" "$p"
  [ "$LP_PLACE" = fly ] && return 0
  if [ "$LP_PLACE" = box ] && [ -n "${LP_BOX:-}" ]; then
    MC_PROJ_BOX="$LP_BOX"; MC_PROJ_TAG="project-box($LP_BOX)"; return 0
  fi
  case "$LP_WHY" in "no jobs client"|"settings unreadable") return 3 ;; esac
  return 1
}

# mc_proj_none_fly — rc 0 when a FRESH box settings cache
# (state/settings-cache.json, the lane-gate copy setting_get reads) says no
# merge-conductor placement row is fly, box: or fly-dedicated (BH-7716)
# (lane_placement.merge-conductor,
# lane_placement.merge-conductor.<project>, lane_placement.default), and no
# project carries a <project>.placed mark. One jq read for every project, so
# the hub tick skips the gate with no settings read per project. rc 1 = gate
# each project (a fly row, a mark, or no fresh cache).
mc_proj_none_fly() {
  local root f ttl ans
  root=$(_mc_proj_root); f="$root/state/settings-cache.json"
  compgen -G "$(_mc_proj_dir)/*.placed" >/dev/null 2>&1 && return 1
  [ -r "$f" ] || return 1
  ttl="${JOBS_SETTINGS_CACHE_S:-${LANE_GATE_CACHE_S:-60}}"
  [[ $ttl =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ] || return 1
  ans=$(jq -r --argjson now "$(date -u +%s)" --argjson ttl "$ttl" '
    ((.fetched_at | tonumber?) // 0) as $f
    | if ($now - $f) < 0 or ($now - $f) >= $ttl then "stale"
      else [((.seeded // {}) + (.values // {})) | to_entries[]
             | select(.key == "lane_placement.default" or (.key | startswith("lane_placement.merge-conductor")))
             | select(.key | endswith(".hub_only") | not)
             | (.value | tostring | ascii_downcase | gsub("\\s"; ""))]
           | if any(. == "fly" or startswith("box:") or . == "fly-dedicated") then "fly" else "none" end
      end' "$f" 2>/dev/null)
  [ "$ans" = none ]
}

mc_proj_fallback() {
  local p="${1:-}" v
  if _mc_proj_client && _setting_key_ok "lane_fallback.$MC_PROJ_LANE.$p" \
     && v=$(setting_get "lane_fallback.$MC_PROJ_LANE.$p" 2>/dev/null) \
     && [ "$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" = off ]; then
    printf off; return 0
  fi
  printf hub
}

mc_proj_newest() {
  local box=0; [ "${5:-0}" = 1 ] && box=1
  printf '%s' "${1:-}" | jq -r --arg p "${2:-}" --argjson now "${3:-0}" --argjson st "${4:-600}" --argjson box "$box" '
    (.rows | if type == "array" then . else error("no rows") end)
    | (first(.[] | select(.project == $p)) // null) as $r
    | if $r == null then "none - -"
      else ($r.status // "") as $s | ($r.prof_line // "") as $pl | ($r.id | tostring) as $id
        | if $s == "died" and ($pl | startswith("withdrawn ")) then "stale \($id) withdrawn"
          elif $s == "claimed" and $box == 1
               and ((($r.lease_until // "") | try fromdateiso8601 catch null) as $l | $l != null and ($now - $l) >= $st)
            then "stale \($id) box-silent"
          elif $s == "claimed" then "live \($id) claimed"
          elif $s == "queued" then
            ((($r.enqueued_at // "") | try fromdateiso8601 catch null)) as $t
            | if $t != null and ($now - $t) >= $st then "stale \($id) \($now - $t)" else "live \($id) queued" end
          elif $s == "died" then "failed \($id) died"
          elif $s == "failed" then "failed \($id) rc=\($r.rc)"
          elif $s != "done" then "live \($id) \($s)"
          elif ($r.rc != null and $r.rc != 0) then "failed \($id) rc=\($r.rc)"
          elif ($pl | test("(^| )PROF mc-project ")) | not then "failed \($id) no-prof"
          else ($pl | capture("(^| )deferred=(?<d>[^ ]+)").d // "-") as $d
            | if $d != "-" then "deferred \($id) \($d)" else "done \($id) -" end
          end
      end' 2>/dev/null
}

mc_proj_defer_field() {
  local v n
  v=$(awk -v s="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')" '
    NF == 2 && $1 ~ /^[a-z]+$/ {
      k = tolower($2); i = index(k, "#")
      if (i > 1 && substr(k, 1, i - 1) == s && substr(k, i + 1) ~ /^[0-9]+$/) print $1 "/" substr(k, i + 1)
    }' "${1:-}" 2>/dev/null | sort -u)
  [ -n "$v" ] || { printf -; return 0; }
  n=$(printf '%s\n' "$v" | wc -l | tr -d ' ')
  v="$n:$(printf '%s\n' "$v" | paste -sd, -)"
  [ "${#v}" -le "$MC_PROJ_DEFER_FIELD_MAX" ] || v=overflow
  printf '%s' "$v"
}

# _mc_proj_dk_no <why> — mc_proj_defer_keys' rc 1 answer: MC_PROJ_DEFER_OUT
# and stdout carry <why>.
_mc_proj_dk_no() { MC_PROJ_DEFER_OUT="$1"; printf '%s\n' "$1"; }

mc_proj_defer_keys() {
  local p="${2:-}" slug="${3:-}" words="${4:-}" v n t w step num keys="" route="" rstep="" rkeys="" cover=","
  local -a toks wl
  MC_PROJ_DEFER_ROUTE=""; MC_PROJ_DEFER_OUT=""
  v=$(printf '%s' "${1:-}" | jq -r --arg p "$p" '
    (first(.rows[]? | select(.project == $p)) // {}) | (.prof_line // "")
    | (capture("(^| )deferred_prs=(?<v>[^ ]+)").v // "")' 2>/dev/null)
  case "$v" in
    ""|-) _mc_proj_dk_no "no PR names"; return 1 ;;
    overflow) _mc_proj_dk_no overflow; return 1 ;;
  esac
  [[ $v =~ ^([0-9]{1,4}):([^:]+)$ ]] || { _mc_proj_dk_no "bad token $v"; return 1; }
  n=${BASH_REMATCH[1]}
  IFS=, read -r -a toks <<<"${BASH_REMATCH[2]}"
  [ "${#toks[@]}" = "$((10#$n))" ] || { _mc_proj_dk_no "list truncated"; return 1; }
  for t in "${toks[@]}"; do
    [[ $t =~ ^([a-z]+)/([0-9]+)$ ]] || { _mc_proj_dk_no "bad token $t"; return 1; }
    step=${BASH_REMATCH[1]}; num=${BASH_REMATCH[2]}
    case ",$words," in *",$step,"*) ;; *) _mc_proj_dk_no "step $step not in deferred="; return 1 ;; esac
    cover="$cover$step,"
    keys="$keys$slug#$num"$'\n'
    if [ "$step" != "$rstep" ]; then
      [ -n "$rstep" ] && route="${route:+$route; }$rstep -> hub keyed $rkeys"
      rstep=$step; rkeys="$slug#$num"
    else
      rkeys="$rkeys,$slug#$num"
    fi
  done
  route="${route:+$route; }$rstep -> hub keyed $rkeys"
  IFS=, read -r -a wl <<<"$words"
  for w in "${wl[@]}"; do
    case "$cover" in *",$w,"*) ;; *) _mc_proj_dk_no "$w has no PR"; return 1 ;; esac
  done
  MC_PROJ_DEFER_ROUTE="$route"
  MC_PROJ_DEFER_OUT=$(printf '%s' "$keys" | sort -t'#' -k2,2n -u | paste -sd, -)
  printf '%s\n' "$MC_PROJ_DEFER_OUT"
}

mc_proj_alert() {
  local p="$1" text="$2" d stamp now last
  d=$(_mc_proj_dir); stamp="$d/$p.alert-at"; now=$(date -u +%s)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  local every; every=$(_mc_proj_int mc_project_fly.alert_s "$MC_PROJ_ALERT_S")
  if [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$every" ]; then
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: alert held (one per ${every}s): $text"
    return 0
  fi
  mkdir -p "$d" 2>/dev/null
  _mc_proj_put "$stamp" "$now"
  local a; a="$(_mc_proj_root)/bin/lane-alert.sh"
  [ -x "$a" ] && "$a" --severity warn --id "mc-project-fly-$p" merge-conductor \
    "merge-conductor $p (placed fly, fallback $(mc_proj_fallback "$p")): $text" >/dev/null 2>&1
  return 0
}

# _mc_proj_why <rc> <output> — the last non-empty line of a lib call's
# output, else `rc=<rc>, no output`.
_mc_proj_why() {
  local w
  w=$(printf '%s\n' "$2" | awk 'NF {l = $0} END {print l}')
  [ -n "$w" ] || w="rc=$1, no output"
  printf '%s' "$w"
}

# _mc_proj_snap_fresh <project> — rc 0 and the age when the project's current
# snapshot is fresh enough for a machine to claim: age_s +
# mc_project_fly.snapshot_margin_s <= lane_snapshot.max_age_s (the bound
# lri_fetch refuses past). rc 1 and the reason otherwise: no client, no
# snapshot, a failed read, an age that is not a whole number, or too old.
_mc_proj_snap_fresh() {
  local p="$1" f rc age max margin
  _mc_proj_client >/dev/null 2>&1 || { printf 'no jobs client'; return 1; }
  f=$(mktemp "${TMPDIR:-/tmp}/mc-proj-snap.XXXXXX") || { printf 'mktemp failed'; return 1; }
  # Into a file, not $( ): JOBS_HTTP must survive the call to be named.
  _jobs_req GET "/api/lane-snapshots/$MC_PROJ_LANE/$p" > "$f" 2>/dev/null; rc=$?
  age=$(jq -r '.age_s' "$f" 2>/dev/null); rm -f "$f"
  case "$rc" in
    0) ;;
    2) printf 'no snapshot'; return 1 ;;
    *) printf 'snapshot read failed (http %s)' "${JOBS_HTTP:-none}"; return 1 ;;
  esac
  [[ $age =~ ^[0-9]{1,9}$ ]] || { printf 'unreadable age'; return 1; }
  age=$((10#$age))
  max=$(_mc_proj_int lane_snapshot.max_age_s 1200)
  margin=$(_mc_proj_int mc_project_fly.snapshot_margin_s "$MC_PROJ_SNAPSHOT_MARGIN_S")
  if [ $((age + margin)) -le "$max" ]; then printf '%s' "$age"; return 0; fi
  printf 'snapshot %ss old, max %ss less margin %ss' "$age" "$max" "$margin"
  return 1
}

mc_proj_publish() {
  local p="$1" root out stamp now last w rc why fresh
  MC_PROJ_PUB_WHY=""
  root=$(_mc_proj_root)
  # At most one publish per project per MC_PROJ_PUBLISH_MIN_S: a snapshot is
  # a tar of the project's records, and the hub's CPU is what this lane frees.
  stamp="$(_mc_proj_dir)/$p.published-at"; now=$(date -u +%s)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$(_mc_proj_int mc_project_fly.publish_min_s "$MC_PROJ_PUBLISH_MIN_S")" ] && return 0
  if ! command -v lri_publish >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-run-inputs.sh
    [ -r "$root/bin/lib/lane-run-inputs.sh" ] && . "$root/bin/lib/lane-run-inputs.sh" 2>/dev/null
  fi
  if command -v lri_publish >/dev/null 2>&1; then
    # The cron publisher holds the same per-project lock across its file
    # walk and tar: wait for it within the bound (BH-7520).
    w=$(_mc_proj_int mc_project_fly.publish_lock_wait_s "$MC_PROJ_PUBLISH_LOCK_WAIT_S")
    [ "$w" -le 600 ] || w="$MC_PROJ_PUBLISH_LOCK_WAIT_S"
    out=$(LRI_LOCK_WAIT_S="$w" lri_apply_pending "$MC_PROJ_LANE" "$p" 2>&1); rc=$?
    [ "$rc" = 0 ] || _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: write-back apply failed ($(_mc_proj_why "$rc" "$out"))"
    out=$(LRI_LOCK_WAIT_S="$w" lri_publish "$MC_PROJ_LANE" "$p" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then _mc_proj_put "$stamp" "$now"; return 0; fi
    why=$(_mc_proj_why "$rc" "$out")
  else
    why="no lane-run-inputs lib"
  fi
  # The publish failed: a machine row runs on the cron publisher's snapshot,
  # and only when lri_fetch on the machine will still take it.
  if fresh=$(_mc_proj_snap_fresh "$p"); then
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: snapshot publish failed ($why) — the cron publisher's snapshot is used (${fresh}s old)"
    return 0
  fi
  MC_PROJ_PUB_WHY="$fresh"
  _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: snapshot publish failed ($why) — no fresh snapshot ($fresh); this tick of $p stays on the hub"
  return 1
}

# _mc_proj_apply <project> — the hub takes in what the machines wrote BEFORE
# it works the project itself (the BR_PRE_APPLY rule, bin/blocked-resolver.sh):
# a hub tick on stale state would change this project's lines, and the next
# compare-and-set apply of the machine's write-back would then keep the hub's
# copy and drop the machine's (a QUEUED row lost, its settle never run).
# rc 0 = applied, or nothing to apply; rc 1 = not applied.
_mc_proj_apply() {
  local p="$1" root out
  root=$(_mc_proj_root)
  if ! command -v lri_apply_pending >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-run-inputs.sh
    [ -r "$root/bin/lib/lane-run-inputs.sh" ] && . "$root/bin/lib/lane-run-inputs.sh" 2>/dev/null
  fi
  command -v lri_apply_pending >/dev/null 2>&1 || { MC_PROJ_APPLY_WHY="no lane-run-inputs lib"; return 1; }
  out=$(lri_apply_pending "$MC_PROJ_LANE" "$p" 2>&1) || { MC_PROJ_APPLY_WHY=$(printf '%s' "$out" | tail -n 1); return 1; }
  MC_PROJ_APPLY_WHY="$out"
  return 0
}

# _mc_proj_fallback <project> <word> <detail> <rc-for-hub> — the hub fallback,
# or with lane_fallback=off one held ALERTS line and rc 0. Sets MC_PROJ_OFF=1
# when the fallback is off. Before a hub fallback it applies the project's
# pending write-backs (_mc_proj_apply) and writes the hub mark; when the apply
# fails the hub does no PR work for the project this tick (rc 0, owed).
_mc_proj_fallback() {
  local p="$1" w="$2" det="$3" hubrc="$4"
  MC_PROJ_OFF=0
  if [ "$(mc_proj_fallback "$p")" = off ]; then
    MC_PROJ_OFF=1
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: $w ($det) and lane_fallback.$MC_PROJ_LANE.$p=off — the hub runs nothing for $p this tick"
    mc_proj_alert "$p" "$w ($det); the hub runs nothing for this project while the fallback row is off. Rollback: set lane_placement.merge-conductor.$p to hub."
    return 0
  fi
  if ! _mc_proj_apply "$p"; then
    _mc_proj_put "$(_mc_proj_dir)/$p.owed" "owed $(date -u +%s)"
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: fallback=$w ($det) held — the machine's write-backs were not applied (${MC_PROJ_APPLY_WHY:-?}); no hub work for $p this tick, owed"
    return 0
  fi
  mc_proj_hub_mark "$p"
  _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: fallback=$w ($det) — this tick of $p runs on the hub (${MC_PROJ_APPLY_WHY:-applied})"
  return "$hubrc"
}

# _mc_proj_withdraw <project> <id> <why> [expired] — end a stale queued row
# before the hub takes the project (POST /api/lane-runs/<id>/withdraw). With
# expired = 1 (BH-7636, a box-silent row) the body carries expired:1, so a
# claimed row whose lease ran out ends too. rc 0 = ended;
# rc 2 = the route does not answer (an older worker: today's fallback, the row
# stays queued); rc 3 = the row is no longer queued (a machine claimed it):
# the row is live.
_mc_proj_withdraw() {
  local id="$2" why="$3" ex="${4:-0}" by rc
  by="hub-$(hostname 2>/dev/null)"; by="${by//[^A-Za-z0-9._-]/_}"; by="${by:0:64}"
  _jobs_req POST "/api/lane-runs/$id/withdraw" "$(jq -nc --arg b "$by" --arg w "$why" --arg e "$ex" \
    '{by:$b, why:$w} + (if $e == "1" then {expired:1} else {} end)')" >/dev/null; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 9 ] && [ "$(printf '%s' "${JOBS_BODY:-}" | jq -r '.reason // empty' 2>/dev/null)" = not_queued ]; then return 3; fi
  _mc_proj_log "${1:-} ${MC_PROJ_TAG:-project-fly}: withdraw of row $id not answered (http ${JOBS_HTTP:-none}) — a machine may still claim it; its landings wait on the project lease"
  return 2
}

# _mc_proj_pid_start <pid> — the process start stamp: field 22 of
# /proc/<pid>/stat on Linux (the _lg_pid_start rule of #7438), `ps -o lstart`
# elsewhere. Empty when the pid is gone or a zombie.
_mc_proj_pid_start() {
  local line rest IFS=' '
  if [ -d /proc/self ]; then
    { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 0
    rest=${line##*) }
    # shellcheck disable=SC2086 # split on purpose: numbers and a state letter
    set -- $rest
    [ "${1:-}" = Z ] && return 0
    printf '%s' "${20:-}"
  elif kill -0 "$1" 2>/dev/null; then
    ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_' | tr -d '\n'
  fi
}

# mc_proj_hub_mark <project> — <project>.hubtick = `<pid> <start stamp>
# <epoch>` of this subshell (the hub tick that takes the project back).
mc_proj_hub_mark() {
  local d pid; d=$(_mc_proj_dir); pid="${BASHPID:-$$}"
  mkdir -p "$d" 2>/dev/null
  _mc_proj_put "$d/${1:-}.hubtick" "$pid $(_mc_proj_pid_start "$pid") $(date -u +%s)"
  return 0
}

# mc_proj_hub_unmark <project> — remove <project>.hubtick when this subshell
# wrote it. The driver calls it when tick_project of the project returns,
# after the gate closed its lock fd. The read and the remove run under
# <project>.lock (BH-7462): a later tick writes its mark under the same lock,
# so this unmark never removes it. rc 0 on every path.
mc_proj_hub_unmark() {
  local p="${1:-}" d f pid fd
  d=$(_mc_proj_dir); f="$d/$p.hubtick"
  [ -f "$f" ] || return 0
  if ! { exec {fd}>>"$d/$p.lock"; } 2>/dev/null; then
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: hub mark of $p left in place (lock not opened) — it ends with its pid"
    return 0
  fi
  if ! flock -w 10 "$fd"; then
    exec {fd}>&-
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: hub mark of $p left in place — another hub tick is deciding for $p; the mark ends with its pid"
    return 0
  fi
  { read -r pid _ < "$f"; } 2>/dev/null && [ "$pid" = "${BASHPID:-$$}" ] && rm -f "$f"
  exec {fd}>&-
  return 0
}

# _mc_proj_hub_busy <project> — rc 0 + the pid when the hub tick that took
# <project> back still runs: its pid lives with the SAME start stamp (a
# reused pid is not it), and the mark is younger than
# mc_project_fly.hubtick_max_s (fallback 3600 s). tick_project waits for its
# PR workers by pid, so they are covered while it lives; a lane it detaches
# (rebase, re-review, deploy-verify, batch) lands nothing.
_mc_proj_hub_busy() {
  local pid start at now
  { read -r pid start at < "$(_mc_proj_dir)/${1:-}.hubtick"; } 2>/dev/null || return 1
  [[ $pid =~ ^[0-9]+$ ]] && [[ ${at:-} =~ ^[0-9]+$ ]] && [ -n "${start:-}" ] || return 1
  now=$(date -u +%s)
  [ $((now - at)) -lt "$(_mc_proj_int mc_project_fly.hubtick_max_s "$MC_PROJ_HUBTICK_MAX_S")" ] || return 1
  [ "$(_mc_proj_pid_start "$pid")" = "$start" ] || return 1
  printf '%s' "$pid"
}

# _mc_proj_nocap_backoff <project> — rc 0 while the last no-capacity
# take-back is younger than mc_project_fly.nocap_backoff_s (fallback 600 s);
# MC_PROJ_BACKOFF_LEFT = the seconds left.
_mc_proj_nocap_backoff() {
  local at b now
  at=$(head -n 1 "$(_mc_proj_dir)/$1.nocap-at" 2>/dev/null); [[ $at =~ ^[0-9]+$ ]] || return 1
  b=$(_mc_proj_int mc_project_fly.nocap_backoff_s "$MC_PROJ_NOCAP_BACKOFF_S"); now=$(date -u +%s)
  MC_PROJ_BACKOFF_LEFT=$((at + b - now))
  [ "$MC_PROJ_BACKOFF_LEFT" -gt 0 ]
}

# _mc_proj_enqueue <project> — publish, then one lp_enqueue. rc 0 = a row is
# queued or live, or a hub fallback tick still runs (owed); rc 1 = not
# enqueued. A failed publish with no fresh snapshot is rc 1 before any
# lp_enqueue, with MC_PROJ_ENQ_WHY set (BH-7520).
_mc_proj_enqueue() {
  local p="$1" d rc pid
  MC_PROJ_ENQ_WHY=""
  d=$(_mc_proj_dir)
  if pid=$(_mc_proj_hub_busy "$p"); then
    _mc_proj_put "$d/$p.owed" "owed $(date -u +%s)"
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: a hub tick of $p still runs (pid $pid) — owed, no row enqueued this tick"
    return 0
  fi
  mc_proj_publish "$p" || { MC_PROJ_ENQ_WHY="no fresh snapshot: $MC_PROJ_PUB_WHY"; return 1; }
  lp_enqueue "$MC_PROJ_LANE" "$p" "$(_mc_proj_root)/bin/merge-conductor-project.sh" "$p"; rc=$?
  case "$rc" in
    0) rm -f "$d/$p.owed"; _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: enqueued $MC_PROJ_LANE $p — no hub work for $p this tick"; return 0 ;;
    3) _mc_proj_put "$d/$p.owed" "owed $(date -u +%s)"
       _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: a row of $p is already live — owed, enqueued again after it is done"; return 0 ;;
  esac
  return 1
}

# _mc_proj_failed_count <project> <inc|reset> — the consecutive
# machine-failed take-backs; prints the count.
_mc_proj_failed_count() {
  local f n; f="$(_mc_proj_dir)/$1.failed-n"
  n=$(head -n 1 "$f" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] || n=0
  if [ "$2" = inc ]; then n=$((n + 1)); else n=0; fi
  _mc_proj_put "$f" "$n"
  printf '%s' "$n"
}

# _mc_proj_nocap_count <project> <inc|reset> — the consecutive no-capacity
# cycles (BH-7462); prints the count.
_mc_proj_nocap_count() {
  local f n; f="$(_mc_proj_dir)/$1.nocap-n"
  n=$(head -n 1 "$f" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] || n=0
  if [ "$2" = inc ]; then n=$((n + 1)); else n=0; fi
  _mc_proj_put "$f" "$n"
  printf '%s' "$n"
}

# _mc_proj_box_down <project> <id> <detail> <stale-s> — a box placement's
# take-back (the withdraw answered 200): ONE ALERTS line per outage. The
# <project>.box-down mark holds it, and is written only after bin/lane-alert.sh
# answers rc 0, so a failed alert is tried again on the next take-back.
_mc_proj_box_down() {
  local p="$1" id="$2" det="$3" st="$4" f a what
  f="$(_mc_proj_dir)/$p.box-down"
  if [ -e "$f" ]; then
    _mc_proj_log "$p $MC_PROJ_TAG: row $id taken back ($det); the box-down alert of this outage is already sent"
    return 0
  fi
  what="it did not claim row $id within ${st}s"
  [ "$det" = box-silent ] && what="it claimed row $id and then stopped answering for ${st}s or more"
  a="$(_mc_proj_root)/bin/lane-alert.sh"
  [ -x "$a" ] || return 0
  "$a" --severity warn --id "mc-project-box-$p" merge-conductor \
    "merge-conductor $p is placed on box $MC_PROJ_BOX, and $what. The hub withdrew the row and took the project back to the hub. The box gets a new row after mc_project_fly.nocap_backoff_s. Check the box cron (lane-run-worker.sh --box $MC_PROJ_BOX) and its logs/lane-run-worker.log. Undo: set lane_placement.merge-conductor.$p to hub." \
    >/dev/null 2>&1 || return 0
  _mc_proj_put "$f" "$id $(date -u +%s)"
  return 0
}

# _mc_proj_box_up <project> — the box answered: the outage (if any) ends.
_mc_proj_box_up() {
  local f; f="$(_mc_proj_dir)/$1.box-down"
  [ -e "$f" ] || return 0
  rm -f "$f"
  _mc_proj_log "$1 $MC_PROJ_TAG: the box answers again — the next take-back alerts again"
}

mc_proj_gate() {
  local p="${1:-}" st="${2:-600}" d rows kind id det taken rc fd frc nf nc wrc keys slug hubrc boxed=0
  d=$(_mc_proj_dir)
  mc_proj_fly "$p"; frc=$?
  case "$frc" in
    0) ;;
    3) # Not known. A project last seen fly, or with a live row, does no hub
       # PR work (fail closed); any other project runs today's tick.
       if [ -e "$d/$p.placed" ]; then
         _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: placement not readable ($LP_WHY) and $p was last placed fly — no hub work for $p this tick"
         return 0
       fi
       rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_PROJ_LANE&project_prefix=$p&live=1&limit=10" 2>/dev/null)
       if [ "$(printf '%s' "$rows" | jq -r --arg p "$p" '[.rows[]? | select(.project == $p)] | length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
         _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: placement not readable ($LP_WHY) and a $MC_PROJ_LANE row of $p is live — no hub work for $p this tick"
         return 0
       fi
       return 1 ;;
    *) rm -f "$d/$p.placed" "$d/$p.box-down" 2>/dev/null; return 1 ;;
  esac
  mkdir -p "$d" 2>/dev/null
  [ -n "${MC_PROJ_BOX:-}" ] && boxed=1
  _mc_proj_put "$d/$p.placed" "${MC_PROJ_BOX:+box:}${MC_PROJ_BOX:-fly}"
  exec {fd}>>"$d/$p.lock" || { _mc_proj_fallback "$p" lock-failed "$d/$p.lock" 1; return; }
  if ! flock -w 10 "$fd"; then
    exec {fd}>&-
    _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: another hub tick is deciding for $p — nothing more this tick"
    return 0
  fi
  rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_PROJ_LANE&project_prefix=$p&limit=10") \
    && read -r kind id det < <(mc_proj_newest "$rows" "$p" "$(date -u +%s)" "$st" "$boxed") && [ -n "$kind" ] \
    || { kind=read-failed; id=-; det="http ${JOBS_HTTP:-none}"; }
  taken=$(head -n 1 "$d/$p.taken" 2>/dev/null)
  case "$kind" in
    live)
      [ "$det" = claimed ] && { _mc_proj_nocap_count "$p" reset >/dev/null; _mc_proj_box_up "$p"; }
      _mc_proj_put "$d/$p.owed" "owed $(date -u +%s)"
      _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: row $id is $det — owed, no hub work for $p this tick"; rc=0 ;;
    stale)
      if [ "$det" = withdrawn ] && [ "$id" = "$taken" ]; then
        # A withdrawn row the hub already took back: after the no-capacity
        # backoff the machines get a new row; inside it the hub keeps the
        # project (BH-6890 re-review N1: never a dead end on a withdrawn row).
        if [ "$(mc_proj_fallback "$p")" = hub ] && _mc_proj_nocap_backoff "$p"; then
          _mc_proj_fallback "$p" no-capacity "row $id withdrawn, backoff ${MC_PROJ_BACKOFF_LEFT}s left" 1; rc=$?
        else
          _mc_proj_enqueue "$p" || { _mc_proj_fallback "$p" enqueue-failed "${MC_PROJ_ENQ_WHY:-http ${JOBS_HTTP:-none}}" 1; }; rc=$?
        fi
      else
        wrc=2
        if [ "$det" = withdrawn ]; then wrc=0
        elif [ "$(mc_proj_fallback "$p")" = hub ]; then
          if [ "$det" = box-silent ]; then _mc_proj_withdraw "$p" "$id" box-silent 1; wrc=$?
          else _mc_proj_withdraw "$p" "$id" "stale-${det}s"; wrc=$?; fi
          if [ "$wrc" = 3 ]; then
            _mc_proj_put "$d/$p.owed" "owed $(date -u +%s)"
            _mc_proj_log "$p ${MC_PROJ_TAG:-project-fly}: row $id was claimed before the withdraw — owed, no hub work for $p this tick"
            exec {fd}>&-; return 0
          fi
        fi
        # An ended row is taken back once; the next ticks run the backoff.
        if [ "$wrc" = 0 ]; then
          _mc_proj_put "$d/$p.taken" "$id"; _mc_proj_put "$d/$p.nocap-at" "$(date -u +%s)"
        fi
        _mc_proj_fallback "$p" no-capacity "row $id unclaimed: $det" 1; rc=$?
        # A box placement: ONE alert per outage (BH-7636), not the streak.
        [ "$boxed" = 1 ] && [ "$wrc" = 0 ] && [ "${MC_PROJ_OFF:-0}" = 0 ] && _mc_proj_box_down "$p" "$id" "$det" "$st"
        # One no-capacity cycle per ended row, with the fallback hub (the
        # off path already alerts on each stale row).
        if [ "$boxed" = 0 ] && [ "$wrc" = 0 ] && [ "${MC_PROJ_OFF:-0}" = 0 ]; then
          nc=$(_mc_proj_nocap_count "$p" inc)
          if [ "$nc" -ge "$(_mc_proj_int mc_project_fly.nocap_alert_n "$MC_PROJ_NOCAP_ALERT_N")" ]; then
            mc_proj_alert "$p" "$nc no-capacity cycles in a row: no lane-run machine claimed a merge-conductor row of $p within ${st}s (row $id); the hub runs $p only in the backoff windows. Check the lane-run machine count and logs/lane-run-worker.log."
          fi
        fi
        # Fallback off and an ended row: the machines get a new row.
        [ "${MC_PROJ_OFF:-0}" = 1 ] && [ "$wrc" = 0 ] && { _mc_proj_enqueue "$p" || true; }
      fi ;;
    failed|deferred)
      if [ "$id" = "$taken" ]; then
        _mc_proj_enqueue "$p" || { _mc_proj_fallback "$p" enqueue-failed "${MC_PROJ_ENQ_WHY:-http ${JOBS_HTTP:-none}}" 1; }; rc=$?
      else
        _mc_proj_put "$d/$p.taken" "$id"
        # A machine claimed this row: the no-capacity streak ends. A row the
        # box ran to a result ends a box outage; a `died` row (its lease ran
        # out) is no answer from the box.
        _mc_proj_nocap_count "$p" reset >/dev/null
        [ "$det" = died ] || _mc_proj_box_up "$p"
        if [ "$kind" = failed ]; then
          kind="machine-failed"; nf=$(_mc_proj_failed_count "$p" inc)
          if [ "$nf" -ge "$(_mc_proj_int mc_project_fly.failed_alert_n "$MC_PROJ_FAILED_ALERT_N")" ]; then
            mc_proj_alert "$p" "$nf machine runs in a row failed ($det at row $id); the hub takes each one back. Check logs/lane-run-worker.log on the lane-run machines."
          fi
        else
          kind="machine-deferred"; _mc_proj_failed_count "$p" reset >/dev/null
        fi
        # BH-7635: a deferred row that names the PR of every step is a keyed
        # hub tick of those PRs (rc 4), never a full tick of the project.
        hubrc=2; MC_PROJ_TAKEBACK_KEYS=""
        if [ "$kind" = machine-deferred ]; then
          slug=$("$(_mc_proj_root)/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
          case "$slug" in
            */*) mc_proj_defer_keys "$rows" "$p" "$slug" "$det" >/dev/null && { hubrc=4; MC_PROJ_TAKEBACK_KEYS="$MC_PROJ_DEFER_OUT"; }
                 keys="$MC_PROJ_DEFER_OUT" ;;
            *) keys="no fleet.conf repo for $p" ;;
          esac
        fi
        _mc_proj_fallback "$p" "$kind" "row $id: $det" "$hubrc"; rc=$?
        if [ "$rc" = 4 ]; then
          _mc_proj_log "$p project-fly: deferred row $id: $MC_PROJ_DEFER_ROUTE — no full hub tick"
        elif [ "$rc" = 2 ] && [ "$kind" = machine-deferred ]; then
          _mc_proj_log "$p project-fly: deferred row $id: $det -> hub full tick ($keys)"
        fi
        # Fallback off: the machine tries again with a new row.
        [ "${MC_PROJ_OFF:-0}" = 1 ] && { _mc_proj_enqueue "$p" || true; }
      fi ;;
    none|done)
      [ "$kind" = "done" ] && { _mc_proj_failed_count "$p" reset >/dev/null; _mc_proj_nocap_count "$p" reset >/dev/null; _mc_proj_box_up "$p"; }
      _mc_proj_enqueue "$p" || { _mc_proj_fallback "$p" enqueue-failed "${MC_PROJ_ENQ_WHY:-http ${JOBS_HTTP:-none}}" 1; }; rc=$? ;;
    *)
      _mc_proj_fallback "$p" enqueue-failed "lane_runs read: $det" 1; rc=$? ;;
  esac
  exec {fd}>&-
  return "$rc"
}

# mc_proj_takeback_full <project> — BH-6890: a keyed tick that the gate told
# to take a machine's finished row back runs ONE full tick of <project>
# (MC_ONLY_PROJECT, MC_PROJ_TAKEBACK=1 so the child's gate steps aside) under
# the same full-tick lock a cron full tick holds, so the two never run side by
# side. The lock is held on fd 5 by this subshell for the child's whole run;
# the child's tick_project subshell closes fd 5 like every full tick, so no
# lane it detaches holds it. A held lock clears <project>.taken: the next
# tick takes the row back again. Called from bin/merge-conductor.sh's
# tick_project, so mc_log, mc_safe_name, MC_LOCK_DIR and H are the driver's.
mc_proj_takeback_full() {
  local p="$1" lk
  mkdir -p "$MC_LOCK_DIR" 2>/dev/null
  lk="$MC_LOCK_DIR/merge-conductor-$(mc_safe_name "$p")-fulltick.lock"
  (
    exec 5>"$lk" || exit 3
    flock -n 5 || exit 3
    mc_log "TICK $p: the hub takes the machine's work back — one full tick of $p (keyed tick)"
    env -u MC_ONLY_PR MC_ONLY_PROJECT="$p" MC_PROJ_TAKEBACK=1 MC_FULL_TICK_SINGLE=0 "$H/bin/merge-conductor.sh" </dev/null
  )
  if [ "$?" = 3 ]; then
    rm -f "$(_mc_proj_dir)/$p.taken" 2>/dev/null
    mc_log "TICK $p: a full tick of $p already runs — the take-back waits for the next tick"
  fi
  return 0
}

# mc_proj_takeback_keyed <project> <keys> — BH-7635: the gate answered rc 4,
# so the hub runs ONLY the PRs the machine deferred a step of: one keyed tick
# (MC_ONLY_PR=<keys>, MC_PROJ_TAKEBACK=1 so the child's gate steps aside) in
# the foreground, so the hub mark of this tick covers it. No full-tick lock:
# a keyed tick never takes it, and per-PR locks keep two workers off one PR.
# A non-zero exit is logged; the next tick decides again. Called from
# bin/merge-conductor.sh's tick_project, so mc_log and H are the driver's.
mc_proj_takeback_keyed() {
  local p="$1" keys="$2" rc
  mc_log "TICK $p: the hub runs the machine's deferred steps — a keyed tick of $keys (no full tick)"
  env MC_ONLY_PR="$keys" MC_ONLY_PROJECT="$p" MC_PROJ_TAKEBACK=1 MC_FULL_TICK_SINGLE=0 "$H/bin/merge-conductor.sh" </dev/null; rc=$?
  [ "$rc" = 0 ] || mc_log "TICK $p: the keyed tick of $keys ended rc $rc — the next tick decides again"
  return 0
}
