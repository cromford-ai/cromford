#!/bin/bash
# bin/lib/lane-gate.sh — BH-1132: ONE off-switch and ONE knob resolver for every
# automatic lane in the fleet. Sourced, never executed. No side effect at source
# time beyond defining functions.
#
# WHY. On 2026-09-20 there were 267 cron lines fleet-wide and ~40 distinct
# `flags/*` off-switches with inconsistent semantics, and no way to see them in
# one place or stop one without ssh-ing to a box. alert-triage burned $793 in 12
# hours (#1039) and the only way to stop it was to find its file flag. The
# registry (catalog/lanes.json) names every lane; this file is what a lane
# actually calls.
#
# THE GATE, in order (lane_gate_or_exit):
#   0. one scheduled run per (lane, project) (BH-7422): a cron tick that finds
#      another live run of the same lane and project exits 0 at once — see
#      `single run` below. Helper calls never claim.
#   1. all-off              — the master switch.
#   2. lane-off-<id>        — this lane, everywhere.
#   3. lane-off-<id>-<proj> — this lane on one project (project scope).
#   3b. lane-off-<id>.box.<box> — a `scope: "box"` lane on THIS box only
#      (BH-2327), <box> being _lg_box. Read only when there is no project.
#   3c. factory-stop — only for a lane whose manifest carries a `factory_stop`
#      tag, and only once 1-3b said run (BH-3687, bin/lib/factory-stop.sh).
#   Each of them is read the SAME way: reconcile the D1 `pause_flags` row
#   into flags/<name> with bin/jobs-client.sh's flag_sync (behind a 60s cache
#   under state/lane-gate/), then read the file. Never the file first — see
#   _lg_db_paused.
#   4. FAIL OPEN. An unreachable worker answers with the last cached answer, and
#      with nothing cached it answers "on". A control plane that can stop the
#      fleet when a database blinks is worse than no control plane: every
#      existing lane runs today with no gate at all, and that is the behaviour a
#      failure must degrade to.
#
# A GATED TICK EXITS 0. A skipped tick is not a failure: cron mails on nonzero
# and the pipeline-health lane counts nonzero exits, so exiting 1 here would
# turn "the operator turned this off" into a page.
#
# WHAT THIS DELIBERATELY DOES NOT DO: write a `lanes` row tick. The `lanes`
# table is keyed (project, box) and is the TRIAGE lane's staleness row — a
# `paused` tick posted by a gated merge-conductor or review-prs would refresh
# last_tick_at for that box's triage lane and silence the stale-lane pager for a
# lane that is genuinely dead. `paused since` is served instead from the
# pause_flags row's own updated_at (GET /api/lanes/status), which is when the
# operator flipped it rather than when a cron next noticed.
#
# THE KNOBS (lane_knob <id> <ENV> [project]), most specific first:
#   settings `lane.<id>.<project>.<env-lowercased>`
#   settings `lane.<id>.<env-lowercased>`
#   the process environment ($ENV, as today)
#   the registry default from catalog/lanes.json
# then clamped to the registry's [min,max] — but ONLY when the value came from a
# settings row. An env value is used as it stands and logged, because trimming
# what env/global.env already says would change fleet behaviour with nobody
# deciding. One GET /api/settings per tick fills
# state/settings-cache.json (60s TTL), so a lane reading 26 knobs costs one
# request, and an unreachable worker degrades to env-then-default.
#
# THE CONTRACT (BH-1511.1) — for a knob the registry marks `required: true`,
# the one whose `${VAR:-literal}` a conversion slice has deleted, so the script
# reads a bare `$VAR` and the literal can never drift from the registry again:
#   operator row (fresh)  >  the same row from state/settings-cache.json when
#   the worker is unreachable (one line in logs/lane-gate.log)  >  the process
#   env  >  the registry default  >  FAIL CLOSED: exit 75 with one ALERTS line
#   a day, never a lane body running on an empty value.
# A knob that is NOT required keeps its old behaviour byte for byte: only a
# row is exported. Default-filling is opt-in per knob because the registry
# default and the script's own read disagree for 15 knobs today (a computed
# `${X:-${Y:-lit}}`, `$(knob …)`, a `${X:+…}` read) and 35 are read outside
# their lane's script; filling those would move a running lane. The list is
# docs/config-inventory/registry-drift.tsv (tests/config-literal-lint.sh --drift).
# Rows written by POST /api/settings/seed-registry (actor `registry-seed`) are
# the DB's copy of the registry defaults, for the console. They are kept apart
# in the cache (`seeded`) and answer NOTHING here, so seeding the table changes
# no lane. Every liveness post carries this box's harness commit at most once an
# hour, which is what `harness-ctl seed-registry` checks before it seeds. Knobs read by shared bin/lib/*.sh live in the
# registry's `libs` scope (catalog/lanes.d/_lib.json), keyed
# `lib.<id>.<env lowercased>`, applied by lib_env_apply.
#
# Knobs: LANE_GATE_CACHE_S (60), LANE_GATE_LOG_EVERY_S (3600), LANE_GATE_NOW
# (epoch, injectable by tests), LANE_GATE_DISABLE=1 (the gate itself off — the
# escape hatch if this file is ever the thing that is wrong).

LANE_GATE_CACHE_S="${LANE_GATE_CACHE_S:-60}"
LANE_GATE_LOG_EVERY_S="${LANE_GATE_LOG_EVERY_S:-3600}"

# _lg_h — the root, "" when neither HARNESS nor H is set (BH-2649, contract rule
# 1). Every helper below that builds a path from it checks for "" first and
# gives the answer it already gives for an unreadable state dir; the entry point
# owns the /root/harness default (rule 4).
_lg_h()   { printf '%s' "${HARNESS:-${H:-}}"; }
# _lg_kind / _lg_kpfx — which registry scope a knob read is in: `lanes` (keys
# `lane.<id>.…`) unless _lg_env_apply has set `local _LG_KIND=libs` for the
# duration of a lib_env_apply (keys `lib.<id>.…`). Dynamic scope, so every
# helper below answers for the scope its caller is in and nothing leaks out.
_lg_kind() { printf '%s' "${_LG_KIND:-lanes}"; }
_lg_kpfx() { if [ "$(_lg_kind)" = libs ]; then printf lib; else printf lane; fi; }
# The actor POST /api/settings/seed-registry writes (worker/jobs core.js
# REGISTRY_SEED_ACTOR). A row it owns is a mirror of the registry default.
_LG_SEED_ACTOR=registry-seed
# The clock is `date`: the printf %(…)T builtin is bash >= 4.2, and this file
# runs under macOS bash 3.2 in the lead-post closure (BH-3565).
_lg_now() { if [ -n "${LANE_GATE_NOW:-}" ]; then printf '%s' "$LANE_GATE_NOW"; else date -u '+%s'; fi; }
_lg_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# _lg_name <id> [project] — the switch name. The charset is the one the worker
# enforces on a flag (and therefore the one that cannot escape flags/).
_lg_name() {
  local id="${1:-}" p="${2:-}"
  case "$id" in ''|*[!a-z0-9._-]*) return 1 ;; esac
  if [ -n "$p" ]; then
    case "$p" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    printf 'lane-off-%s-%s' "$id" "$p"
  else
    printf 'lane-off-%s' "$id"
  fi
}

# _lg_box_name <id> <box> — the per-box switch name (BH-2327). `.box.` and not
# `-`, so it can never be mistaken for the project form lane-off-<id>-<proj>.
# rc 1, and no name, for a box this box cannot name safely (empty, `unknown`,
# or a hostname outside the flag charset): the check is skipped and the lane
# runs, never a malformed name sent to the worker.
_lg_box_name() {
  local id="${1:-}" b="${2:-}"
  case "$id" in ''|*[!a-z0-9._-]*) return 1 ;; esac
  case "$b" in ''|unknown|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf 'lane-off-%s.box.%s' "$id" "$b"
}

# _lg_registry — the registry path, overridable so a suite can drive a fixture.
#
# catalog/lanes.json is GENERATED from catalog/lanes.d/ and no longer committed
# (BH-1247), so the path is resolved through the ONE loader, which renders it
# when it is missing or stale. The answer is MEMOISED for the life of the
# process: a lane calls this on every gate and knob read, and the loader digests
# catalog/lanes.d/ to decide staleness — cheap once, not worth paying per call
# inside a single tick. A tick that started before a registry change reading the
# registry it started with is the same guarantee the file gave before.
_LG_REG_CACHE=""
_lg_registry() {
  [ -n "${LANE_REGISTRY:-}" ] && { printf '%s' "$LANE_REGISTRY"; return 0; }
  [ -n "$_LG_REG_CACHE" ] && { printf '%s' "$_LG_REG_CACHE"; return 0; }
  # No root: no registry, and nothing memoised, so a later call with one resolves.
  [ -n "$(_lg_h)" ] || return 0
  if command -v lanes_json_path >/dev/null 2>&1; then
    _LG_REG_CACHE=$(lanes_json_path "$(_lg_h)" 2>/dev/null) || _LG_REG_CACHE=""
  elif [ -r "$(_lg_h)/bin/lib/lanes-registry.sh" ]; then
    # shellcheck source=lanes-registry.sh
    . "$(_lg_h)/bin/lib/lanes-registry.sh" 2>/dev/null \
      && { _LG_REG_CACHE=$(lanes_json_path "$(_lg_h)" 2>/dev/null) || _LG_REG_CACHE=""; }
  fi
  # Fail SOFT to the canonical path. Everything in this library already treats
  # an unreadable registry as "no row, run the lane" (BH-1132 fails open), so a
  # loader that could not render must not turn into a different failure here.
  [ -n "$_LG_REG_CACHE" ] || _LG_REG_CACHE="$(_lg_h)/catalog/lanes.json"
  printf '%s' "$_LG_REG_CACHE"
}

# _lg_cached <name> — prints 1 (paused) / 0 (running) from the cache when it is
# younger than the TTL, else nothing. rc 0 only when it printed.
_lg_cached() {
  local f age fetched
  [ -n "$(_lg_h)" ] || return 1
  f="$(_lg_h)/state/lane-gate/$1.json"
  [ -r "$f" ] || return 1
  fetched=$(jq -r '.fetched_at // 0' "$f" 2>/dev/null) || return 1
  case "$fetched" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(_lg_now) - fetched ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$LANE_GATE_CACHE_S" ] || return 1
  jq -r '.active // 0' "$f" 2>/dev/null
}

# _lg_cached_any <name> — the last answer at ANY age. This is the fail-open
# fallback: an unreachable worker must not silently un-pause a lane an operator
# stopped one minute ago.
_lg_cached_any() {
  local f
  [ -n "$(_lg_h)" ] || return 1
  f="$(_lg_h)/state/lane-gate/$1.json"
  [ -r "$f" ] || return 1
  jq -r '.active // 0' "$f" 2>/dev/null
}

_lg_cache_write() { # _lg_cache_write <name> <0|1>
  local d tmp
  [ -n "$(_lg_h)" ] || return 0
  d="$(_lg_h)/state/lane-gate"
  mkdir -p "$d" 2>/dev/null || return 0
  tmp=$(mktemp "$d/.$1.XXXXXX" 2>/dev/null) || return 0
  jq -nc --argjson a "$2" --argjson f "$(_lg_now)" '{active:$a,fetched_at:$f}' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$d/$1.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# _lg_ensure_client — the D1 half of the gate needs bin/jobs-client.sh's
# flag_sync, and five of the nine wired lanes never sourced it. Sourcing it here
# is what lets a row stop alert-triage (the lane that burned $793 in 12h, #1039)
# rather than only a file on the box.
#
# IT RESTORES pipefail. jobs-client.sh runs `set -uo pipefail` at its top level,
# so a bare source would switch pipefail ON inside bin/preplan-tick.sh, which
# deliberately runs with `set -u` alone. A control plane that changes how an
# unrelated pipeline reports failure is not additive.
_lg_ensure_client() {
  local h pf
  command -v flag_sync >/dev/null 2>&1 && return 0
  h=$(_lg_h)
  [ -n "$h" ] || return 1
  [ -r "$h/bin/jobs-client.sh" ] || return 1
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck disable=SC1091
  . "$h/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  return 0
}

# _lg_db_paused <name> — 0 = paused, 1 = running.
#
# THE FILE IS THE ANSWER, BUT ONLY AFTER IT HAS BEEN RECONCILED. flag_sync
# DRIVES flags/<name> from the row — it touches the file on active=1 and removes
# it on active=0 — so reading the file before calling it is reading a decision
# that may have been reversed. That was the shipped bug: the gate returned on
# `flags/<name>` before any flag_sync, and since flag_sync was what created that
# file from the active row, `harness-ctl on` (or the console writing
# active=0) left every OTHER box gated for ever. A stop that cannot be undone
# everywhere it took effect is not a switch. Sections 11a/11b of
# tests/lane-gate-test.sh are that reversal.
#
# The three-way rc is what makes this safe. rc 0 (reconciled) and rc 2 (no row
# at all) both mean the worker answered, so the file is now current and decides
# — and rc 2 leaves a hand-touched file alone, which is why a local touch or a
# cost autohalt still holds (section 12). Only rc 1, the outage, falls back: the
# file if it is there, else the last cached answer, so a row an operator wrote a
# minute ago is not undone by a blip.
_lg_db_paused() {
  local name="${1:-}" f v rc
  # WHERE the answer came from, for the caller that has to report it (BH-1165):
  # `row` = a pause_flags row drove it, `file` = a file on this box that no row
  # knows about. The page showed the second one as ON, which is how a hand
  # touch or a cost autohalt became invisible.
  _LG_SRC=row
  # No root: no file to read, which is the unreadable-flags-dir answer (running).
  f=""; [ -z "$(_lg_h)" ] || f="$(_lg_h)/flags/$name"
  # A fresh cache means "we reconciled within the TTL": the file standing on
  # disk is that reconciliation's result and costs no request to read.
  if _lg_cached "$name" >/dev/null; then
    [ -f "$f" ] || return 1
    # The cache remembers the ANSWER, not its provenance; the sighting marker
    # this box wrote is what says the last uncached reconcile found a file with
    # no row behind it.
    [ -f "$(_lg_h)/state/lane-gate/.seen-$name" ] && _LG_SRC=file
    return 0
  fi
  _lg_ensure_client
  if command -v flag_sync >/dev/null 2>&1; then
    flag_sync "$name" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
      # rc 2 is "no row at all", so a file still standing after it is box-local.
      [ "$rc" -eq 2 ] && _LG_SRC=file
      if [ -f "$f" ]; then _lg_cache_write "$name" 1; return 0; fi
      _lg_cache_write "$name" 0; return 1
    fi
  elif command -v flag_active >/dev/null 2>&1; then
    if flag_active "$name" >/dev/null 2>&1; then _lg_cache_write "$name" 1; return 0; fi
    _lg_cache_write "$name" 0; return 1
  fi
  # Nothing answered. The file if it is there, else the last thing that did.
  # An outage cannot tell a row-driven file from a hand-touched one, so this
  # path never claims either: the source stays `row` and no sighting is posted
  # for an answer nobody could reconcile.
  #
  # THE OUTAGE ANSWER IS CACHED TOO (BH-1165 review). Without this, a worker
  # that is down costs every one of 78 lanes, on every box, up to three
  # flag_sync round trips per tick — each `curl -m 8` with a retry — before it
  # does any work, and a per-minute lane (wake-loop, poll-commands, hub-lease)
  # can spend longer in timeouts than its own cadence. The cached answer is the
  # same answer this path just computed, so caching it changes nothing except
  # how often the fleet asks a worker that is not there. It expires on the same
  # LANE_GATE_CACHE_S as a successful one.
  if [ -f "$f" ]; then _lg_cache_write "$name" 1; return 0; fi
  v=$(_lg_cached_any "$name") && { _lg_cache_write "$name" "$v"; [ "$v" = 1 ]; return $?; }
  _lg_cache_write "$name" 0
  return 1
}

# _lg_log_throttled <id> <line> — one line per lane per LANE_GATE_LOG_EVERY_S.
# A lane on a */2 cron would otherwise write 720 identical lines a day into
# logs/lane-gate.log and bury the one that matters.
_lg_log_throttled() {
  local id="${1:-}" line="${2:-}" stampf last now h
  h=$(_lg_h); now=$(_lg_now)
  [ -n "$h" ] || return 0
  stampf="$h/state/lane-gate/.logged-$id"
  last=$(cat "$stampf" 2>/dev/null | tr -dc '0-9')
  if [ -n "$last" ] && [ "$(( now - last ))" -lt "$LANE_GATE_LOG_EVERY_S" ] && [ "$(( now - last ))" -ge 0 ]; then
    return 0
  fi
  mkdir -p "$h/state/lane-gate" "$h/logs" 2>/dev/null
  printf '%s\n' "$now" > "$stampf" 2>/dev/null
  printf '%s %s\n' "$(_lg_iso)" "$line" >> "$h/logs/lane-gate.log" 2>/dev/null
  return 0
}

# _lg_box — who is reporting. JOBS_BOX is what every other client uses; the
# hostname is the fallback so a box with an incomplete env still names itself
# rather than filing its rows under nothing.
_lg_box() { printf '%s' "${JOBS_BOX:-$(hostname -s 2>/dev/null || printf unknown)}"; }

# _lg_post <path> <json> — fire and forget. Every caller here is telling the
# control plane something; none of them may fail a lane for it, so an
# unreachable worker, a missing client and a 500 are all the same answer: rc 0,
# nothing said, the lane runs.
# rc 0 only when the worker actually took it. Every caller treats a failure as
# "say nothing, run the lane" — but _lg_flag_seen needs to know, or a post that
# never landed would be remembered as reported and the file would stay invisible
# on the page until the next hourly refresh (for a CLEAR, for ever).
#
# AN OUTAGE COSTS ONE ATTEMPT PER TTL, NOT ONE PER POST PER LANE PER TICK
# (BH-1165 review). The gate's flag reads and the settings GET are both cached
# through a miss stamp; this write was not, so a worker that was down still cost
# every tick of all 77 lanes on every box its full `curl -m 8 --connect-timeout
# 3` plus JOBS_RETRIES — ~7s against a black hole, up to ~17s against a host
# that accepts and hangs — BEFORE the lane did any work, for the whole outage.
# A per-minute lane (wake-loop, poll-commands) lost a quarter of its cadence to
# it. The first failure stamps .post-miss and every later post inside
# LANE_GATE_CACHE_S returns rc 1 without spending a request; the first success
# clears the stamp, so a healthy fleet posts exactly as often as it does today.
# rc 1 is what a failed post already returned, so the callers are unchanged:
# _lg_flag_seen leaves its marker where it was and reports again next tick, and
# _lg_liveness never looked.
_lg_post_throttled() {
  local f last age
  [ -n "$(_lg_h)" ] || return 1
  f="$(_lg_h)/state/lane-gate/.post-miss"
  [ -r "$f" ] || return 1
  last=$(tr -dc '0-9' < "$f" 2>/dev/null)
  [ -n "$last" ] || return 1
  age=$(( $(_lg_now) - last ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$LANE_GATE_CACHE_S" ]
}

_lg_post() {
  local d f h
  _lg_ensure_client
  command -v _jobs_req >/dev/null 2>&1 || return 1
  _lg_post_throttled && return 1
  # No root still SENDS (contract rule 6); it only keeps no .post-miss stamp.
  h=$(_lg_h); d="$h/state/lane-gate"; f="$d/.post-miss"
  if _jobs_req POST "$1" "$2" >/dev/null 2>&1; then
    [ -z "$h" ] || rm -f "$f" 2>/dev/null
    return 0
  fi
  # ONLY A TRANSPORT FAILURE ARMS IT. bin/jobs-client.sh hands the status back
  # through JOBS_HTTP and clears it per request, so a non-empty one means the
  # worker ANSWERED — a 400 for a lane id the registry does not know, a 500 —
  # and answering cost milliseconds, not the timeout this throttle exists to
  # stop paying. Arming on that would let one lane's bad request silence every
  # other lane's sightings on this box for a minute.
  [ -n "${JOBS_HTTP:-}" ] && return 1
  [ -n "$h" ] || return 1
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$(_lg_now)" > "$f" 2>/dev/null
  return 1
}

# _lg_liveness <id> <project> <outcome> [why] — THIS LANE's own tick row
# (BH-1165). Not the `lanes` table: that one is keyed (project, box) and is the
# TRIAGE lane's staleness row, so a merge-conductor tick written there refreshes
# a clock the stale-lane pager reads for something else (see the header). One
# row per (lane, project, box), written on every tick, `ran` or `paused` — a
# paused lane is still alive, and a page that could not tell "stopped" from
# "dead" is the thing phase A shipped without.
#
# THE BOX'S HARNESS COMMIT RIDES ALONG, ON CHANGE, ELSE HOURLY (BH-1511.1
# review, I2; BH-7304): the checkout HEAD bin/harness-sync.sh deploys from,
# which the worker stores in box_status. It is the proof `harness-ctl
# seed-registry` demands that this box runs a lane-gate that knows the
# registry-seed actor — a box on the old file never sends it — and the sha
# bin/fleet-version-check.sh judges against main. The stamp under
# state/lane-gate/ is `<epoch> <sha>`: a tick sends when the sha differs from
# the stamped one (so a sync is reported on the next tick, not up to an hour
# later), when the stamp is an hour old, or when there is no usable stamp (an
# old epoch-only stamp reads as "sha unknown"). Every other tick posts what it
# posted before. The stamp moves only when the worker took the post.
#
# A send tick also carries two sync facts for the version check:
# harness_synced_at (the time of the last `done` line in
# state/harness-sync-phase) and sync_timer (1 when the crontab runs
# bin/harness-sync-timer.sh, else 0; left out on a box that has no such script).
_lg_harness_commit() {
  local h stampf last="" ssha="" now sha="" co
  h=$(_lg_h); now=$(_lg_now)
  # The checkout sits beside the root (BH-2649); with neither, there is no sha.
  co="${HARNESS_CHECKOUT:-}"
  if [ -z "$co" ]; then [ -n "$h" ] || return 1; co="$h/../harness-checkout"; fi
  # A POOL BOX has no .git (BH-1632): /data/harness is a tarball, and
  # bin/lib/harness-tarball.sh stamps its source sha as HARNESS_COMMIT at the
  # root. A .git, when there is one, always wins; the stamp is read only
  # without one, and a stamp that is not 7-40 hex sends nothing.
  if [ -e "$co/.git" ]; then sha=$(_lg_git_head "$co") || return 1
  else { IFS= read -r sha < "$co/HARNESS_COMMIT"; } 2>/dev/null || [ -n "$sha" ] || return 1
       sha=${sha%$'\r'}; [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || return 1
  fi
  case "$sha" in ''|*[!0-9a-f]*) return 1 ;; esac
  if [ -n "$h" ]; then
    stampf="$h/state/lane-gate/.harness-commit-sent"
    # The braces own the redirect: `read < missing 2>/dev/null` leaks the `<`
    # error, because the redirect fails before 2>/dev/null applies (review N2).
    { read -r last ssha < "$stampf"; } 2>/dev/null
    ssha=${ssha%$'\r'}
    case "$last" in ''|*[!0-9]*) last="" ;; esac
    if [ -n "$last" ] && [ -n "$ssha" ] && [ "$ssha" = "$sha" ] \
       && [ "$(( now - last ))" -ge 0 ] && [ "$(( now - last ))" -lt 3600 ]; then return 1; fi
  fi
  printf '%s' "$sha"
}

# _lg_sync_facts — the JSON object of sync facts a send tick adds, `{}` when it
# knows none. Read only on send ticks: one read, one test and one crontab -l.
_lg_sync_facts() {
  local h phase psha pat="" timer=""
  h=$(_lg_h)
  if [ -n "$h" ]; then
    # One line `<phase> <sha40> <iso>` (bin/lib/harness-sync-step.sh). Only a
    # `done` line is a finished sync; `copied` or `step=<name>` sends nothing,
    # and the worker keeps the last value it has.
    { read -r phase psha pat < "$h/state/harness-sync-phase"; } 2>/dev/null
    [ "${phase:-}" = done ] && [[ "$pat" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || pat=""
    # No bin/harness-sync-timer.sh: this box cannot have the timer yet, so
    # the fact is not reported rather than reported as 0.
    if [ -f "$h/bin/harness-sync-timer.sh" ] && command -v crontab >/dev/null 2>&1; then
      if crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -q 'harness-sync-timer'; then timer=1; else timer=0; fi
    fi
  fi
  jq -nc --arg s "$pat" --arg t "$timer" \
    '(if $s == "" then {} else {harness_synced_at:$s} end) + (if $t == "" then {} else {sync_timer:($t | tonumber)} end)' 2>/dev/null \
    || printf '{}'
}

# _lg_git_head <checkout> — HEAD's sha read from the FILES, never by running
# git: this rides every lane's liveness post, and several lane suites stub
# `git` and assert exactly which git calls a tick makes (tier2-merge-sweep AT-5).
# Handles a `.git` directory or a `gitdir:` file (worktree, via commondir), a
# symbolic or detached HEAD, and loose or packed refs.
_lg_git_head() {
  local gd head ref common sha
  gd="$1/.git"
  if [ -f "$gd" ]; then gd=$(sed -n 's/^gitdir: //p' "$gd" 2>/dev/null); case "$gd" in /*) ;; *) gd="$1/$gd" ;; esac; fi
  [ -r "$gd/HEAD" ] || return 1
  common="$gd"; [ -r "$gd/commondir" ] && { common=$(cat "$gd/commondir"); case "$common" in /*) ;; *) common="$gd/$common" ;; esac; }
  head=$(cat "$gd/HEAD" 2>/dev/null)
  case "$head" in
    "ref: "*) ref=${head#ref: }
              sha=$(cat "$gd/$ref" 2>/dev/null || cat "$common/$ref" 2>/dev/null) \
                || sha=$(awk -v r="$ref" '$2==r{print $1; exit}' "$common/packed-refs" 2>/dev/null) ;;
    *) sha=$head ;;
  esac
  [ -n "$sha" ] && printf '%s' "$sha"
}
_lg_liveness() {
  local body sha="" facts='{}'
  command -v jq >/dev/null 2>&1 || return 0
  sha=$(_lg_harness_commit) || sha=""
  [ -z "$sha" ] || facts=$(_lg_sync_facts)
  [ -n "$facts" ] || facts='{}'
  body=$(jq -nc --arg l "${1:-}" --arg p "${2:-}" --arg b "$(_lg_box)" \
                --arg o "${3:-}" --arg w "${4:-}" --arg c "$sha" --argjson f "$facts" \
    '{lane:$l,project:$p,box:$b,outcome:$o,why:$w} + (if $c == "" then {} else {harness_commit:$c} + $f end)' 2>/dev/null) || return 0
  if _lg_post /api/lanes/liveness "$body" && [ -n "$sha" ] && [ -n "$(_lg_h)" ]; then
    mkdir -p "$(_lg_h)/state/lane-gate" 2>/dev/null
    printf '%s %s\n' "$(_lg_now)" "$sha" > "$(_lg_h)/state/lane-gate/.harness-commit-sent" 2>/dev/null
  fi
  return 0
}

# _lg_flag_seen <name> <id> <project> <1|0> — a box-local flag FILE, reported.
#
# THE SIGHTING IS NOT A DECISION. It would be one line to write the file back as
# a pause_flags row, and that line would turn one box's hand touch (or its cost
# autohalt) into a fleet-wide stop the next time every other box reconciled —
# a reporting mechanism that changes what it reports. So this is its own row,
# read by the page and by nothing that gates.
#
# ONE WRITE PER STATE CHANGE, plus an hourly refresh so the row's seen_at does
# not go stale under a lane that is still stopped. The marker under
# state/lane-gate/ is what remembers, so a tick that changes nothing costs no
# request.
_lg_flag_seen() {
  local name="${1:-}" id="${2:-}" p="${3:-}" on="${4:-0}" d marker last="" now body h
  [ -n "$name" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # No root: no marker, so a sighting posts every time and a clear has nothing to clear.
  h=$(_lg_h); d="$h/state/lane-gate"; marker="$d/.seen-$name"; now=$(_lg_now)
  if [ "$on" = 1 ]; then
    [ -z "$h" ] || last=$(cat "$marker" 2>/dev/null | tr -dc '0-9')
    if [ -n "$last" ] && [ "$(( now - last ))" -lt "$LANE_GATE_LOG_EVERY_S" ] && [ "$(( now - last ))" -ge 0 ]; then
      return 0
    fi
  else
    [ -n "$h" ] && [ -f "$marker" ] || return 0
  fi
  body=$(jq -nc --arg n "$name" --arg l "$id" --arg p "$p" --arg b "$(_lg_box)" \
                --argjson a "$([ "$on" = 1 ] && echo 1 || echo 0)" \
    '{name:$n,lane:$l,project:$p,box:$b,active:$a}' 2>/dev/null) || return 0
  # THE MARKER MOVES ONLY WHEN THE WORKER TOOK IT.
  _lg_post /api/lanes/flag-seen "$body" || return 0
  [ -n "$h" ] || return 0
  if [ "$on" = 1 ]; then
    mkdir -p "$d" 2>/dev/null
    printf '%s\n' "$now" > "$marker" 2>/dev/null
  else
    rm -f "$marker" 2>/dev/null
  fi
  return 0
}

# lane_paused <id> [project] — the gate's DECISION, without the exit (BH-1165).
#
# WHY A PREDICATE TOO. A multi-project lane (the retired tier-2 sweep) swept every project on the box
# in one tick, so "this project is off" cannot be an exit — the other seven
# projects still have work. A lane that has to skip part of its own tick asks
# this; a lane whose whole tick is the work calls lane_gate_or_exit.
#
# It publishes what it found in LANE_PAUSED_WHY / LANE_PAUSED_FLAG /
# LANE_PAUSED_SOURCE, and LANE_GATE_CHECKED lists the switch names it actually
# read — which is what lets the gate clear a sighting for a name it proved is
# no longer holding, and never for one it never looked at.
LANE_PAUSED_WHY=""; LANE_PAUSED_FLAG=""; LANE_PAUSED_SOURCE=""; LANE_GATE_CHECKED=""

# _lg_lane_scope <id> — the registry's `scope` for a lane, empty when the
# registry is unreadable or does not know it (which skips the box check: fail
# open). Memoised per process in the _LG_HELD_MEMO shape, so a lane that asks
# the gate more than once pays for one jq.
_LG_SCOPE_MEMO=""         # " <id>=<scope> …", for this process only
_lg_lane_scope() {
  local id="${1:-}" v
  case " $_LG_SCOPE_MEMO " in *" $id="*)
    v=${_LG_SCOPE_MEMO##*" $id="}; printf '%s' "${v%% *}"; return 0 ;;
  esac
  v=$(jq -r --arg i "$id" '[.lanes[]? | select(.id==$i) | .scope // empty][0] // empty' \
        "$(_lg_registry)" 2>/dev/null) || v=""
  case "$v" in *[!a-z]*) v="" ;; esac
  _LG_SCOPE_MEMO="$_LG_SCOPE_MEMO $id=$v"
  printf '%s' "$v"
}

# _lg_lane_fstop <id> — the registry's `factory_stop` tag for a lane
# (launch|merge|deploy), memoised like _lg_lane_scope. Empty when the lane has
# none, the registry is unreadable, or the value is anything else (logged
# once): an unreadable tag runs the lane, the same fail-open as scope.
_LG_FSTOP_MEMO=""         # " <id>=<tag> …", for this process only
_lg_lane_fstop() {
  local id="${1:-}" v
  case " $_LG_FSTOP_MEMO " in *" $id="*)
    v=${_LG_FSTOP_MEMO##*" $id="}; printf '%s' "${v%% *}"; return 0 ;;
  esac
  v=$(jq -r --arg i "$id" '[.lanes[]? | select(.id==$i) | .factory_stop // empty][0] // empty' \
        "$(_lg_registry)" 2>/dev/null) || v=""
  case "$v" in
    ''|launch|merge|deploy) ;;
    *) _lg_log_throttled "lane-fstop-$id" "[lane-gate] $id: factory_stop tag '$v' is not launch|merge|deploy, read as untagged"
       v="" ;;
  esac
  _LG_FSTOP_MEMO="$_LG_FSTOP_MEMO $id=$v"
  printf '%s' "$v"
}

# _lg_factory_stopped — factory_stopped from bin/lib/factory-stop.sh, sourced
# on first use so an untagged lane never loads it. A missing lib (a half-synced
# bin/) is NOT stopped, said once.
_lg_factory_stopped() {
  if ! command -v factory_stopped >/dev/null 2>&1; then
    # shellcheck source=factory-stop.sh
    if [ ! -r "$(dirname "${BASH_SOURCE[0]}")/factory-stop.sh" ] \
       || ! . "$(dirname "${BASH_SOURCE[0]}")/factory-stop.sh"; then
      _lg_log_throttled factory-stop-nolib "factory-stop: bin/lib/factory-stop.sh missing (half-synced box) — read as NOT stopped"
      return 1
    fi
  fi
  factory_stopped
}

lane_paused() {
  local id="${1:-}" p="${2:-}" name pname bname
  LANE_PAUSED_WHY=""; LANE_PAUSED_FLAG=""; LANE_PAUSED_SOURCE=""; LANE_GATE_CHECKED=""
  [ "${LANE_GATE_DISABLE:-0}" = 1 ] && return 1
  [ -n "$id" ] || return 1
  name=$(_lg_name "$id") || return 1
  pname=""
  if [ -n "$p" ]; then pname=$(_lg_name "$id" "$p") || pname=""; fi
  # EVERY candidate goes through _lg_db_paused, which reconciles the file from
  # the row before reading it. There is deliberately no "check the file first"
  # short cut here: the file is the DB's output, not an independent source, and
  # trusting it unreconciled is what made a stop permanent.
  LANE_GATE_CHECKED="all-off"
  if _lg_db_paused "all-off"; then
    LANE_PAUSED_WHY="all-off (fleet master switch)"; LANE_PAUSED_FLAG="all-off"
  else
    LANE_GATE_CHECKED="$LANE_GATE_CHECKED $name"
    if _lg_db_paused "$name"; then
      LANE_PAUSED_WHY="lane-off-$id"; LANE_PAUSED_FLAG="$name"
    elif [ -n "$pname" ]; then
      LANE_GATE_CHECKED="$LANE_GATE_CHECKED $pname"
      if _lg_db_paused "$pname"; then
        LANE_PAUSED_WHY="$pname"; LANE_PAUSED_FLAG="$pname"
      fi
    elif [ "$(_lg_lane_scope "$id")" = box ] && bname=$(_lg_box_name "$id" "$(_lg_box)"); then
      # A BOX LANE ON THIS BOX ONLY (BH-2327). Hub and project lanes never
      # read a box name: one runs on the hub alone, the other has its project
      # switch.
      LANE_GATE_CHECKED="$LANE_GATE_CHECKED $bname"
      if _lg_db_paused "$bname"; then
        LANE_PAUSED_WHY="$bname (this box only)"; LANE_PAUSED_FLAG="$bname"
      fi
    fi
  fi
  [ -n "$LANE_PAUSED_WHY" ] || return 1
  LANE_PAUSED_SOURCE="${_LG_SRC:-row}"
  return 0
}

# >>> project hold
# lane_project_held <id> <project> — BH-1463 (BH-1419.0): is THIS project held
# on a hub lane? rc 0 = held, rc 1 = run it.
#
# WHY. A hub-scoped lane can only be stopped FLEET-WIDE: harness-ctl refuses a
# project argument on one and the switches above are global, so pausing a fix
# round on one project meant stopping the lane for all of them. This is the
# per-project row the five hub lanes marked `per_project_hold` in
# catalog/lanes.d/ will read per project, while every other project keeps
# running and that project's builds stay on.
#
# IT READS ONE NAME. lane-off-<id>-<project>, through the same _lg_name and
# _lg_db_paused as everything else here, so it inherits reconcile-then-read and
# fail-open with no new code. It does NOT re-check all-off or lane-off-<id>:
# the lane already exited on those at its own lane_gate_or_exit, and asking
# again would double-count the sighting rail.
#
# AND IT SAYS NOTHING. No _lg_liveness row, no .paused stamp, no _lg_flag_seen
# sighting. The lane RAN this tick, and worker/jobs/src/routes/lanes.js filters
# lane_ticks by scope!=="project" on a hub lane — so a `paused` tick posted here
# would render the lane as paused on the HUB tab while it was merging every
# other project. The caller names the row in its own log through LANE_HELD_FLAG.
#
# MEMOISED per (id, project) for the life of the process, in the same plain
# string shape as _LG_REG_CACHE: bin/merge-sweep.sh walks hundreds of records a
# tick and would otherwise re-read the cache file and re-run jq per record. The
# key is the SANITISED name ([A-Za-z0-9._-] only), matched with its delimiters,
# so `lane-off-x-project-3=1` can never answer for `lane-off-x-project-3`. A hold
# flipped mid-tick is seen on the next tick, which is what the 60s cache already
# gives every other reader here.
LANE_HELD_FLAG=""
_LG_HELD_MEMO=""          # " <name>=0 <name>=1 …", for this process only
lane_project_held() {
  local id="${1:-}" p="${2:-}" name v
  LANE_HELD_FLAG=""
  # Before the memo, so the escape hatch still wins after an answer is cached.
  [ "${LANE_GATE_DISABLE:-0}" = 1 ] && return 1
  # An EMPTY project must never reach _lg_name: it would build the lane-wide
  # name and this function would answer for a switch that is not its question.
  # `-` is the "no project" placeholder several lanes pass.
  [ -n "$id" ] && [ -n "$p" ] && [ "$p" != "-" ] || return 1
  name=$(_lg_name "$id" "$p") || return 1
  case " $_LG_HELD_MEMO " in
    *" $name=1 "*) LANE_HELD_FLAG="$name"; return 0 ;;
    *" $name=0 "*) return 1 ;;
  esac
  if _lg_db_paused "$name"; then v=1; else v=0; fi
  _LG_HELD_MEMO="$_LG_HELD_MEMO $name=$v"
  [ "$v" = 1 ] || return 1
  LANE_HELD_FLAG="$name"
  return 0
}
# <<< project hold

# lane_start_offset <id> — whole seconds this box waits before the gate's first
# D1 read (BH-5781). Every D1 overload error on 2026-10-09 landed at minute
# :00/:15/:30/:45, when every box starts its quarter-hour lanes at once. The
# offset is cksum(box name) mod (spread+1): stable per box, different across
# boxes. It is 0 unless the UTC minute is 0/15/30/45 AND the lane's registry
# cadence minute is a number, a comma list, or */N with N >= 5 (a */2 lane
# would run into its next tick). A */N lane is capped at half its period.
# The spread: settings row lane_start_spread_s read from the cache FILE, fresh
# or stale (a refresh is the very read being spread), else LANE_START_SPREAD_S,
# else 0 (off). An integer 0..600 only; anything else is ignored. 0 = off.
# The row is seeded at 120 (schema.d/0017-bh-5781-lane-start-spread.sql), so a
# box with a settings cache spreads; a harness with no cache (a scratch test
# tree, a box before its first settings read) never sleeps. A code default of
# 120 made every suite that runs a real lane at :00/:15/:30/:45 sleep up to
# 120 s per run: tests/lookback-live.bh-3691-test.sh timed out in the merge
# queue (run 38058329244, rc 124 after 900 s).
# _lg_start_box — JOBS_BOX, else state/box-name, else _lg_box. The gate runs
# before the jobs client sets JOBS_BOX, and every Orgo box's hostname is the same.
_lg_start_box() {
  local box="${JOBS_BOX:-}"
  [ -n "$box" ] || [ -z "$(_lg_h)" ] || [ ! -r "$(_lg_h)/state/box-name" ] \
    || box=$(tr -dc 'A-Za-z0-9._-' < "$(_lg_h)/state/box-name" 2>/dev/null)
  [ -n "$box" ] || box=$(_lg_box)
  printf '%s' "$box"
}
lane_start_offset() {
  local id="${1:-}" reg cad min spread v off cap="" now
  now=$(_lg_now); min=$(( (now / 60) % 60 ))
  case "$min" in 0|15|30|45) ;; *) printf 0; return 0 ;; esac
  spread=0
  for v in "$(jq -r '.values.lane_start_spread_s // .seeded.lane_start_spread_s // empty' "$(_lg_settings_file)" 2>/dev/null)" \
           "${LANE_START_SPREAD_S:-}"; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "${#v}" -le 3 ] && [ "$v" -le 600 ] && { spread=$((10#$v)); break; }
  done
  reg=$(_lg_registry)
  cad=$(jq -r --arg i "$id" '.lanes[]? | select(.id==$i) | .cadence // empty' "$reg" 2>/dev/null | head -1)
  cad="${cad%% *}"
  case "$cad" in
    */*) cap="${cad#\*/}"; case "$cap" in ''|*[!0-9]*) printf 0; return 0 ;; esac
         [ "$cad" = "*/$cap" ] && [ "$cap" -ge 5 ] || { printf 0; return 0; }
         cap=$(( cap * 30 )) ;;
    ''|*[!0-9,]*) printf 0; return 0 ;;
  esac
  off=$(( $(printf '%s' "$(_lg_start_box)" | cksum | cut -d' ' -f1) % (spread + 1) ))
  [ -n "$cap" ] && [ "$off" -gt "$cap" ] && off=$cap
  printf '%s' "$off"
}

# >>> single run (BH-7422)
# ONE SCHEDULED RUN PER (LANE, PROJECT). Hub lanes stacked: cron started a
# lane again before the last run of the same lane and project ended, and on an
# overloaded hub each extra copy made every copy slower (2026-10-19: load
# 160-185 on 4 cores). The gate is the one call every lane makes, so the guard
# is here and nowhere else.
#
# ONLY THE SCHEDULED TICK IS GUARDED. A gated script is also called as a helper
# (harden-state --release under a caller's lock, cost-rows-push --box from a
# pool reap, lead-review one <id> in a build, a wake class's per-project kick).
# A helper call that exits 0 and does nothing is a silent loss, so a run claims
# ONLY when it is a tick:
#   LANE_SINGLE_RUN=0       never (a caller or a mode says "helper");
#   LANE_SINGLE_RUN=1       always (a launcher says "this is the schedule");
#   else LANE_GATE_RUN set  never: another gated run is above this process
#                           (the gate exports it on every run it lets through);
#   else                    a tick iff cron is an ancestor (LANE_TICK_PARENTS,
#                           default "cron crond", walked through /proc at most
#                           8 levels). An operator's shell, a build and a box
#                           with no /proc never claim. That is fail open.
# The gate unsets LANE_SINGLE_RUN once it has read it, so the word never
# reaches the run's own children.
#
# THE CLAIM IS A PID FILE, NOT A HELD FD. state/lane-runs/<id>/<project|->/<pid>
# holds the run's process start stamp. A later run counts the files whose
# process is still the same process (pid alive, not a zombie, same start stamp)
# and deletes the rest. The run's own exit is the release. An fd held for the
# life of the run would go to every child the lane starts (bash cannot set
# FD_CLOEXEC), and a detached daemon would hold the lane shut (fly-pool,
# 2026-09-12). flock on fd 211 only makes the count-and-write step atomic; fd
# 211 is closed before the gate returns. Busy for 5 s: count unlocked.
#
# THE KEY. The gate's project argument, else PL_PROJECT when the run is a
# project-lane-run child of this lane (BH-5913), else none (`-`). A script on
# two cron lines with no project (two modes: cost-reconcile --window 1h and
# 24h, jobs-watchdog and --resume) sets LANE_RUN_KEY=<mode> before the gate,
# so one mode's tick never turns the other away. It is a key only: it does not
# reach the off-switches or the liveness row the way a project would. A mode
# outside [A-Za-z0-9._-] does not claim (fail open). The gate unsets it.
#
# THE SWITCHES, most specific first: settings row lane.<id>.<project>.single_run,
# then lane.<id>.single_run (0|false|off|no, any case = off; anything else =
# on), then the manifest field `"single_run": false` (catalog/lanes.d/<id>.json,
# for a lane that fans out on purpose), then ON. They are read only when
# another run is live, so an uncontended start reads nothing. On a stale cache
# that read is one settings GET.
#
# HELD: exit 0 at once with one `skipped (running)` line, no ALERTS line, no
# liveness post, no D1 read. MEASURE: a claimed run that passes the off-switches
# writes one `ran … live=<n>` line. Both go to logs/lane-runs-cron.log, which
# disk-clean stage 10 bounds (*-cron.log).

# _lg_pid_start <pid> — _LG_PS = the process start stamp, "" when it is gone
# or a zombie. /proc/<pid>/stat field 22 (no fork); `ps -o lstart=` elsewhere.
_lg_pid_start() {
  local line rest IFS=' '
  _LG_PS=""
  if [ -d /proc/self ]; then
    { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 0
    rest=${line##*) }
    # shellcheck disable=SC2086 # split on purpose: numbers and a state letter
    set -- $rest
    [ "${1:-}" = Z ] && return 0
    _LG_PS=${20:-}
  elif kill -0 "$1" 2>/dev/null; then
    _LG_PS=$(ps -o lstart= -p "$1" 2>/dev/null)
    [ -n "$_LG_PS" ] || _LG_PS=alive
  fi
}

# _lg_tick_parent — rc 0 when a process named in LANE_TICK_PARENTS is an
# ancestor of this one. /proc only; no /proc answers "no" (fail open).
_lg_tick_parent() {
  local pid=$PPID i=0 line comm rest IFS=' '
  [ -d /proc/self ] || return 1
  while [ "$i" -lt 8 ] && [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
    { read -r line < "/proc/$pid/stat"; } 2>/dev/null || return 1
    comm=${line#*(}; comm=${comm%)*}
    case " ${LANE_TICK_PARENTS:-cron crond} " in *" $comm "*) return 0 ;; esac
    rest=${line##*) }
    # shellcheck disable=SC2086
    set -- $rest
    pid=${2:-0}; i=$((i + 1))
  done
  return 1
}

# _lg_is_tick — rc 0 when this run claims (see ONLY THE SCHEDULED TICK above).
_lg_is_tick() {
  case "${LANE_SINGLE_RUN:-}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  [ -z "${LANE_GATE_RUN:-}" ] || return 1
  _lg_tick_parent
}

# _lg_run_log <line> — one line in logs/lane-runs-cron.log.
_lg_run_log() {
  printf '%s [lane-run] %s\n' "$(_lg_iso)" "$1" >> "$(_lg_h)/logs/lane-runs-cron.log" 2>/dev/null
  return 0
}

# _lg_single_off <id> <project> — rc 0 when the guard is OFF for this run;
# _LG_SR_WHY says which switch answered.
_lg_single_off() {
  local id="$1" p="$2" key v
  _lg_settings_refresh
  for key in "$(_lg_setting_key "$id" single_run "$p")" "$(_lg_setting_key "$id" single_run)"; do
    [ -n "$key" ] || continue
    v=$(_lg_setting_lookup "$key") || continue
    _LG_SR_WHY="settings $key=$v"
    _lg_lower "$v"
    case "$_LG_LOW" in 0|false|off|no) return 0 ;; *) return 1 ;; esac
  done
  v=$(jq -r --arg i "$id" '[.lanes[]? | select(.id==$i) | .single_run | tostring][0] // empty' \
        "$(_lg_registry)" 2>/dev/null)
  _LG_SR_WHY="catalog/lanes.d/$id.json single_run:false"
  [ "$v" = false ]
}

# _lg_run_count <dir> — _LG_LIVE = live runs in <dir> other than this one,
# _LG_HOLDER = one of their pids. Files of exited runs, and names that are not
# a pid, are deleted. These are claim files under state/lane-runs/, never
# flags/; the loop variable is `cf` so tests/no-flag-files does not read a
# delete here as a flags/ write (it tracks `f`, a flags/ path elsewhere here).
_lg_run_count() {
  local cf pid st
  _LG_LIVE=0; _LG_HOLDER=""
  for cf in "$1"/*; do
    [ -f "$cf" ] || continue
    pid=${cf##*/}
    case "$pid" in ''|*[!0-9]*) rm -f "$cf"; continue ;; esac
    [ "$pid" = "$$" ] && continue
    st=""; { IFS= read -r st < "$cf"; } 2>/dev/null
    _lg_pid_start "$pid"
    if [ -n "$_LG_PS" ] && [ "$_LG_PS" = "$st" ]; then
      _LG_LIVE=$((_LG_LIVE + 1)); _LG_HOLDER=$pid
    else
      rm -f "$cf"
    fi
  done
}

# _lg_single_run <id> [project] — rc 3 when another live run holds this
# (lane, project) and the guard is on; rc 0 otherwise. _LG_SR_LINE is the
# measure line the gate writes once the run is past the off-switches ("" when
# this run did not claim).
_lg_single_run() {
  local id="$1" p="${2:-}" h d k rk lk=0 note=""
  _LG_SR_LINE=""
  _lg_is_tick || return 0
  h=$(_lg_h); [ -n "$h" ] || return 0
  [ -z "$p" ] && [ "${PL_LANE:-}" = "$id" ] && p="${PL_PROJECT:-}"
  [ "$p" = "-" ] && p=""
  case "$id" in ''|.*|*[!a-z0-9._-]*) return 0 ;; esac
  case "$p" in .*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  rk="${LANE_RUN_KEY:-}"
  case "$rk" in .*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  k="$id/${p:--}${rk:++$rk}"
  d="$h/state/lane-runs/$k"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 0
  [ -d "$h/locks/lane-run" ] || mkdir -p "$h/locks/lane-run" 2>/dev/null
  [ -d "$h/logs" ] || mkdir -p "$h/logs" 2>/dev/null
  if command -v flock >/dev/null 2>&1 \
     && { exec 211>"$h/locks/lane-run/$id.${p:--}${rk:++$rk}.lock"; } 2>/dev/null; then
    if flock -w "${LANE_RUN_LOCK_WAIT_S:-5}" 211 2>/dev/null; then lk=1
    else exec 211>&-; note=" (counted unlocked: claim lock busy ${LANE_RUN_LOCK_WAIT_S:-5} s)"; fi
  fi
  _lg_run_count "$d"
  if [ "$_LG_LIVE" -gt 0 ]; then
    [ "$lk" = 1 ] && exec 211>&-; lk=0
    if ! _lg_single_off "$id" "$p"; then
      _lg_run_log "$k skipped (running) pid=$$ holder=$_LG_HOLDER live=$_LG_LIVE"
      return 3
    fi
    note="$note (guard off: $_LG_SR_WHY)"
  fi
  _lg_pid_start "$$"
  printf '%s\n' "$_LG_PS" > "$d/$$" 2>/dev/null
  [ "$lk" = 1 ] && exec 211>&-
  _LG_SR_LINE="$k ran pid=$$ live=$((_LG_LIVE + 1))$note"
  return 0
}
# <<< single run

# lane_gate_or_exit <id> [project] — the whole gate. Returns 0 when the lane may
# run; EXITS 0 when it may not. Either way this tick is now a row on the page.
lane_gate_or_exit() {
  local id="${1:-}" p="${2:-}" h stampd n tag
  [ "${LANE_GATE_DISABLE:-0}" = 1 ] && return 0
  [ -n "$id" ] || return 0
  # One run per (lane, project) first (BH-7422): a held run leaves before the
  # start offset, the D1 reads and the liveness post.
  _lg_single_run "$id" "$p" || exit 0
  # Every run let through marks its process tree, so a gated script it calls
  # is a helper call and never claims; the tick word stops here too.
  export LANE_GATE_RUN="$id/${p:--}"
  unset LANE_SINGLE_RUN LANE_RUN_KEY
  n=$(lane_start_offset "$id")
  if [ "$n" -gt 0 ] 2>/dev/null; then
    _lg_log_throttled "$id-start-offset" "[lane-gate] $id start offset ${n}s on box $(_lg_start_box) (quarter-hour spread)"
    sleep "$n"
  fi
  h=$(_lg_h)
  if ! lane_paused "$id" "$p"; then
    # >>> factory stop (BH-3687) — a tagged lane the switches above cleared is
    # still stopped while switch.factory-stop is ON; it then takes the paused
    # path below. An untagged lane costs one memoised registry read.
    tag=$(_lg_lane_fstop "$id")
    if [ -n "$tag" ]; then
      LANE_GATE_CHECKED="$LANE_GATE_CHECKED factory-stop"
      if _lg_factory_stopped; then
        LANE_PAUSED_WHY="factory-stop ($tag lane; $(lane_switch_src factory-stop))"
        LANE_PAUSED_FLAG=factory-stop
        case "$FACTORY_STOP_SRC" in box-row|fleet-row) LANE_PAUSED_SOURCE=row ;; *) LANE_PAUSED_SOURCE=file ;; esac
      fi
    fi
    # <<< factory stop
    if [ -z "$LANE_PAUSED_WHY" ]; then
      # Every name this tick READ and found clear: if this box ever reported a
      # file behind one of them, the page is told it is gone.
      for n in $LANE_GATE_CHECKED; do _lg_flag_seen "$n" "$id" "$p" 0; done
      [ -z "${_LG_SR_LINE:-}" ] || _lg_run_log "$_LG_SR_LINE"
      _lg_liveness "$id" "$p" ran
      return 0
    fi
  fi
  for n in $LANE_GATE_CHECKED; do
    [ "$n" = "$LANE_PAUSED_FLAG" ] && continue
    _lg_flag_seen "$n" "$id" "$p" 0
  done
  [ "$LANE_PAUSED_SOURCE" = file ] && _lg_flag_seen "$LANE_PAUSED_FLAG" "$id" "$p" 1
  # No root: still paused (a pause is never dropped), but no stamp is written.
  if [ -n "$h" ]; then
    stampd="$h/state/lane-gate"
    mkdir -p "$stampd" 2>/dev/null
    printf '%s %s\n' "$(_lg_iso)" "$LANE_PAUSED_WHY" > "$stampd/$id${p:+-$p}.paused" 2>/dev/null
  fi
  # A box switch has no harness-ctl verb; the console's lane page is where it is cleared.
  case "$LANE_PAUSED_FLAG" in
    *.box.*) n="Settings → $id → BOXES to resume" ;;
    factory-stop) n="set settings switch.factory-stop to 0 (PUT /api/settings) to resume" ;;
    *)       n="bin/harness-ctl.sh on $id${p:+ $p} to resume" ;;
  esac
  _lg_log_throttled "$id${p:+-$p}" "[lane-gate] $id${p:+/$p} SKIPPED — $LANE_PAUSED_WHY ($n)"
  _lg_liveness "$id" "$p" paused "$LANE_PAUSED_WHY"
  exit 0
}

# --- knobs -------------------------------------------------------------------

# THE KNOB MEMO (BH-7251). A lane start used to run about 8 jq per knob (25
# for merge-conductor's lane_env_apply on the hub). Two memos, held in process
# memory, replace them:
#   registry  the knobs of one (registry, scope, id): ONE jq per triple, for
#             the life of the process — the same guarantee _LG_REG_CACHE
#             gives: a tick reads the registry it started with.
#   settings  the settings cache's operator values and every key: ONE jq per
#             distinct file CONTENT. Each read compares the raw text with the
#             text it parsed (the read builtin, no fork), so a refresh that
#             rewrites the file is seen at once.
# A command substitution inherits both, so `v=$(lane_knob …)` after
# lane_env_apply runs no jq at all. The records are NUL-separated, so a value
# with a space, a backslash, a `|` or a tab comes back byte for byte.
#
# BASH 3.2 (BH-3565). This file is in the lead-post closure, which runs under
# macOS /bin/bash 3.2: no associative arrays. Each memo entry is a plain shell
# variable whose NAME encodes its key, read back with ${!name}:
#   _LG_KM_T_<t>, _LG_KM_E_<t>   triple <t>'s "<reg>|<kind>|<id>" and its env list
#   _LG_KM_<t>_<field>_<ENV>     one knob field (sa sk rq ad default min max zero_means)
#   _LG_SK_<key>, _LG_SV_<key>   a settings key exists / its operator value
# A settings key is encoded `_`→`__`, `.`→`_d`, `-`→`_m` (prefix-free, so two
# keys never share a name). A key or ENV with any other character is not
# memoised; its read takes the one jq it took before BH-7251.
_LG_ALNUM=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
_LG_UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_LG_LOWER=abcdefghijklmnopqrstuvwxyz
: "${_LG_KM_TN:=0}" "${_LG_SC_NAMES=}" "${_LG_SK_N:=0}"
: "${_LG_SC_FILE=}" "${_LG_SC_RAW=}" "${_LG_SC_LOADED=0}" "${_LG_SFETCHED=0}"

# _lg_km_triple <reg> <kind> <id> — _LG_MI = the triple's slot; rc 1 when it
# was never loaded. A process loads a handful of triples, so a scan is enough.
_lg_km_triple() {
  local b="$1|$2|$3" i=0 n
  while [ "$i" -lt "$_LG_KM_TN" ]; do
    n=_LG_KM_T_$i
    [ "${!n-}" = "$b" ] && { _LG_MI=$i; return 0; }
    i=$((i + 1))
  done
  return 1
}

# _lg_km_get <reg> <kind> <id> <ENV> <field> — _LG_MV = that field, "" when the
# triple or the knob has none (what an unset key of the old array answered).
# rc 2 when <ENV> is not a shell name, so the caller asks jq instead.
_lg_km_get() {
  local n
  _LG_MV=""
  case "$4" in ''|*[!${_LG_ALNUM}_]*) return 2 ;; esac
  _lg_km_triple "$1" "$2" "$3" || return 0
  n="_LG_KM_${_LG_MI}_$5_$4"
  _LG_MV=${!n-}
  return 0
}

# _lg_km_load <reg> <lanes|libs> <id> — fill the registry memo for one entry.
# Fields per knob: sa (settable for _lg_env_apply: false only when
# .settable==false), sk (lane_knob_settable's reading: .settable as a string,
# "true" when absent), rq, ad (the default _lg_env_apply exports), and
# default/min/max/zero_means (each `// empty`, as _lg_knob_meta answered).
# _LG_KM_E_<t> is the ordered env list. The first record for an env wins,
# which is what `head -1` picked before.
_lg_km_load() {
  local reg="${1:-}" kind="${2:-lanes}" id="${3:-}" t e sa sk rq ad df mn mx zm envs="" p n
  _lg_km_triple "$reg" "$kind" "$id" && return 0
  [ -r "$reg" ] || return 0
  t=$_LG_KM_TN
  while IFS= read -r -d '' e && IFS= read -r -d '' sa && IFS= read -r -d '' sk \
     && IFS= read -r -d '' rq && IFS= read -r -d '' ad && IFS= read -r -d '' df \
     && IFS= read -r -d '' mn && IFS= read -r -d '' mx && IFS= read -r -d '' zm; do
    case "$e" in
      ''|*[!${_LG_ALNUM}_]*)
        # Not a shell name: listed once, never memoised (see _lg_km_get).
        case $'\n'"$envs" in *$'\n'"$e"$'\n'*) continue ;; esac ;;
      *)
        p="_LG_KM_${t}_"
        n="${p}sa_$e"
        [ -n "${!n+x}" ] && continue
        printf -v "${p}sa_$e" '%s' "$sa"; printf -v "${p}sk_$e" '%s' "$sk"
        printf -v "${p}rq_$e" '%s' "$rq"; printf -v "${p}ad_$e" '%s' "$ad"
        printf -v "${p}default_$e" '%s' "$df"; printf -v "${p}min_$e" '%s' "$mn"
        printf -v "${p}max_$e" '%s' "$mx"; printf -v "${p}zero_means_$e" '%s' "$zm" ;;
    esac
    envs="$envs$e"$'\n'
  done < <(jq -j --arg k "$kind" --arg i "$id" '
    def s: if . == null then "" elif type == "string" then . else tojson end;
    .[$k][]? | select(.id==$i) | .knobs[]? | select(.env)
    | ((.env|tostring),
       (if .settable==false then "false" else "true" end),
       (if has("settable") then (.settable|tostring) else "true" end),
       (if .required==true then "true" else "false" end),
       (if .default==null then "" else (.default|tostring) end),
       ((.default // null)|s), ((.min // null)|s), ((.max // null)|s),
       ((.zero_means // null)|s))
    | . + "\u0000"' "$reg" 2>/dev/null)
  printf -v "_LG_KM_T_$t" '%s' "$reg|$kind|$id"
  printf -v "_LG_KM_E_$t" '%s' "$envs"
  _LG_KM_TN=$((t + 1))
  return 0
}

# _lg_sc_name <key> — _LG_ENC = the settings key's variable suffix; rc 1 when
# the key has a character outside [A-Za-z0-9_.-] (such a key is not memoised).
_lg_sc_name() {
  local e
  case "$1" in ''|*[!${_LG_ALNUM}_.-]*) return 1 ;; esac
  e=${1//_/__}; e=${e//./_d}; e=${e//-/_m}
  _LG_ENC=$e
}

# _lg_sc_reset — forget every memoised settings key.
_lg_sc_reset() {
  # shellcheck disable=SC2086 # a list of variable names, split on purpose
  [ -z "$_LG_SC_NAMES" ] || unset $_LG_SC_NAMES
  _LG_SC_NAMES=""; _LG_SK_N=0; _LG_SFETCHED=0
}

# _lg_sc_load — fill the settings memo and _LG_SFETCHED from the settings
# cache. rc 1 (and an empty memo) when there is no readable cache. A corrupt
# file loads as fetched 0 with no values, which is what each jq answered
# before. _LG_SK_N counts every non-empty key, memoised or not.
_lg_sc_load() {
  local h f raw="" fa tot k hv v names=""
  h="${HARNESS:-${H:-}}"; f=""
  [ -n "$h" ] && f="$h/state/settings-cache.json"
  if [ -z "$f" ] || [ ! -r "$f" ]; then
    _lg_sc_reset; _LG_SC_LOADED=0; _LG_SC_FILE=""; _LG_SC_RAW=""
    return 1
  fi
  IFS= read -r -d '' raw < "$f" || :
  [ "$_LG_SC_LOADED" = 1 ] && [ "$f" = "$_LG_SC_FILE" ] && [ "$raw" = "$_LG_SC_RAW" ] && return 0
  _lg_sc_reset; fa=0; tot=0
  {
    IFS= read -r -d '' fa || fa=0
    IFS= read -r -d '' tot || tot=0
    while IFS= read -r -d '' k && IFS= read -r -d '' hv && IFS= read -r -d '' v; do
      _lg_sc_name "$k" || continue
      printf -v "_LG_SK_$_LG_ENC" 1; names="$names _LG_SK_$_LG_ENC"
      [ "$hv" = 1 ] || continue
      printf -v "_LG_SV_$_LG_ENC" '%s' "$v"; names="$names _LG_SV_$_LG_ENC"
    done
  # --arg src names the file the text came from, so a jq-counting shim that
  # looks for the cache's path counts this read (tests/conf-rows M4/M5).
  } < <(jq -j --arg src "$f" '
    ((.fetched_at // 0) | tostring) + "\u0000",
    ((.values // {}) | (try to_entries catch []) | map(select(.key != "")) | length | tostring) + "\u0000",
    ((.values // {}) | (try to_entries catch [])[]
     | .key + "\u0000"
       + (if .value != null and .value != false then "1" else "0" end) + "\u0000"
       + (.value | if . == null or . == false then "" elif type == "string" then . else tojson end)
       + "\u0000")' <<<"$raw" 2>/dev/null)
  case "$fa" in ''|*[!0-9]*) fa=0 ;; esac
  case "$tot" in ''|*[!0-9]*) tot=0 ;; esac
  _LG_SC_NAMES=$names; _LG_SK_N=$tot
  _LG_SFETCHED=$fa; _LG_SC_FILE=$f; _LG_SC_RAW=$raw; _LG_SC_LOADED=1
  return 0
}

# _lg_sc_has <key> — rc 0 when the loaded settings cache has <key> in
# `.values` (any value). A key the memo cannot hold asks jq, as before.
_lg_sc_has() {
  local n
  if _lg_sc_name "$1"; then n="_LG_SK_$_LG_ENC"; [ -n "${!n+x}" ]; return; fi
  [ -n "$_LG_SC_FILE" ] || return 1
  jq -e --arg k "$1" '(.values // {}) | (try has($k) catch false)' "$_LG_SC_FILE" >/dev/null 2>&1
}

# _lg_lower <WORD> — _LG_LOW = <WORD> with A-Z lowered; no fork, no ${x,,}.
_lg_lower() {
  local s="$1" o="" c t
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}; s=${s#?}
    case "$_LG_UPPER" in *"$c"*) t=${_LG_UPPER%%"$c"*}; c=${_LG_LOWER:${#t}:1} ;; esac
    o="$o$c"
  done
  _LG_LOW=$o
}

# _lg_settings_file / _lg_settings_refresh — ONE GET /api/settings per tick into
# state/settings-cache.json. Fail-open: a refresh that does not answer leaves
# whatever is there (however old), and a cache that was never written leaves
# every lane_knob on env-then-default, which is today's behaviour exactly.
# With no root there is no cache: "" reads as unreadable everywhere it is tested.
_lg_settings_file() { [ -n "$(_lg_h)" ] || return 0; printf '%s' "$(_lg_h)/state/settings-cache.json"; }

# _lg_settings_miss — remember that the worker did not answer, so the next tick
# inside the TTL does not ask again. Always rc 0: this is bookkeeping, never a
# reason to fail a lane.
_lg_settings_miss() {
  [ -n "$(_lg_h)" ] || return 0
  local d; d="$(_lg_h)/state/lane-gate"
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$(_lg_now)" > "$d/.settings-miss" 2>/dev/null
  return 0
}

_lg_settings_refresh() {
  local f age fetched resp tmp miss last
  # No root, nowhere to cache the answer: no GET, knobs fall to env then default.
  [ -n "$(_lg_h)" ] || return 0
  f=$(_lg_settings_file)
  if _lg_sc_load; then
    fetched=$_LG_SFETCHED
    age=$(( $(_lg_now) - fetched ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$LANE_GATE_CACHE_S" ] && return 0
  fi
  # A REFUSAL IS CACHED FOR THE SAME TTL (BH-1165 review). A worker that is not
  # answering must not be asked again by every lane on every tick: without this
  # stamp an outage costs one extra `curl -m 8` per lane per tick fleet-wide,
  # on top of the gate's own. The lane still degrades to env-then-default,
  # which is exactly today's behaviour.
  miss="$(_lg_h)/state/lane-gate/.settings-miss"
  if [ -r "$miss" ]; then
    last=$(tr -dc '0-9' < "$miss" 2>/dev/null)
    if [ -n "$last" ]; then
      age=$(( $(_lg_now) - last ))
      [ "$age" -ge 0 ] && [ "$age" -lt "$LANE_GATE_CACHE_S" ] && return 0
    fi
  fi
  _lg_ensure_client
  command -v _jobs_req >/dev/null 2>&1 || { _lg_settings_miss; return 0; }
  resp=$(_jobs_req GET /api/settings 2>/dev/null) || { _lg_settings_miss; return 0; }
  printf '%s' "$resp" | jq -e '.settings' >/dev/null 2>&1 || { _lg_settings_miss; return 0; }
  rm -f "$miss" 2>/dev/null
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  tmp=$(mktemp "$(dirname "$f")/.settings-cache.XXXXXX" 2>/dev/null) || return 0
  printf '%s' "$resp" | jq -c --argjson fa "$(_lg_now)" \
    --arg sa "$_LG_SEED_ACTOR" \
    '{fetched_at:$fa,
      values: (reduce (.settings[]? | select(.actor != $sa)) as $s ({}; .[$s.key] = $s.value)),
      seeded: (reduce (.settings[]? | select(.actor == $sa)) as $s ({}; .[$s.key] = $s.value))}' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# _lg_settings_state — `fresh` when the cache was filled inside the TTL (this
# tick or one just before it), `stale` when it is older (the refresh did not
# answer, so this is the last good answer), `none` when this box has none.
_lg_settings_state() {
  local fetched age
  _lg_sc_load || { printf none; return 0; }
  fetched=$_LG_SFETCHED
  age=$(( $(_lg_now) - fetched ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$LANE_GATE_CACHE_S" ]; then printf fresh; else printf stale; fi
}

# _lg_knob_meta <reg> <id> <ENV> <field> — one field of the registry knob entry.
# default/min/max/zero_means come from the memo (_lg_km_load); any other field
# is still one jq.
_lg_knob_meta() {
  local kind="${_LG_KIND:-lanes}"
  case "${4:-}" in
    default|min|max|zero_means)
      _lg_km_load "$1" "$kind" "$2"
      if _lg_km_get "$1" "$kind" "$2" "$3" "$4"; then
        [ -z "$_LG_MV" ] || printf '%s\n' "$_LG_MV"
        return 0
      fi ;;
  esac
  jq -r --arg k "$kind" --arg i "$2" --arg e "$3" --arg f "$4" \
    '.[$k][]? | select(.id==$i) | .knobs[]? | select(.env==$e) | .[$f] // empty' \
    "$1" 2>/dev/null
}

# lane_knob_settable <id> <ENV> — rc 0 when a SETTINGS ROW may drive this knob
# (BH-1165 review).
#
# WHY A REGISTRY FIELD AND NOT A NAME RULE AT THE READER. Wiring all 78 lanes
# registered every `${X:-...}` an automatic script reads — 306 of them — and
# about eighty are not numbers an operator tunes at all: they are the command a
# lane runs (`CLI_CHECK_SSH`, expanded UNQUOTED as `$SSH_CMD "root@$1" "bash
# -s"`; `PROMPT_EVAL_AGENT_CALL`; `OAUTH_USAGE_FETCH`, executed with the OAuth
# token in its environment), the HOST it talks to (`JOBS_URL` — every request of
# that tick carries `authorization: Bearer $HARNESS_SECRET`; `*_API_BASE` —
# `MIGRATION_TOKEN` is POSTed to it), the PATH it deletes under
# (`DISK_CLEAN_REPOS`), the IDENTITY it claims (`JOBS_BOX`, `HARNESS_PR_AUTHORS`)
# or a TEST SEAM (`AUTH_CHECK_LIB`, `BACKUP_NOW`).
#
# `lane_env_apply` exports a row into a lane that cron runs AS ROOT. Leaving
# those names in the settable set would make one `PUT /api/settings` row remote
# code execution and a credential exfil on every box — while `bin/poll-commands.sh`,
# the other thing the console can drive, deliberately runs a fixed verb list.
# The registry is the allow-list; `settable: false` is how a name stays
# REGISTERED (section 7 still demands every read be declared, and `show` still
# prints it) without being writable from a web page.
#
# Missing field = settable, so nothing that was tunable before this stops being
# tunable, and a NEW hazard-shaped name is refused by section 17 of
# tests/lanes-registry-test.sh until somebody marks it.
#
# NOT `_lg_knob_meta`: that helper ends in `// empty`, and in jq `false // x` is
# x — so a `settable: false` knob would come back as "no opinion" and read as
# settable, which is the one answer this function may never give by accident.
lane_knob_settable() {
  local reg kind="${_LG_KIND:-lanes}" v
  reg=$(_lg_registry)
  [ -r "$reg" ] || return 0
  _lg_km_load "$reg" "$kind" "${1:-}"
  if _lg_km_get "$reg" "$kind" "${1:-}" "${2:-}" sk; then
    [ "${_LG_MV:-true}" != false ]; return
  fi
  # An ENV that is not a shell name is not memoised: one jq, as before BH-7251.
  v=$(jq -r --arg k "$kind" --arg i "${1:-}" --arg e "${2:-}" \
    '.[$k][]?|select(.id==$i)|.knobs[]?|select(.env==$e)
     |(if has("settable") then (.settable|tostring) else "true" end)' "$reg" 2>/dev/null | head -1)
  [ "$v" != false ]
}

# _lg_setting_key <id> <ENV> [project] — the settings row key.
#
# `lane.<id>[.<project>].<env lowercased>`, the form published in
# docs/verification-map/lanes-status-contract.md and the one the Mission
# Control console writes (`settingKey()` in console-ui/src/lib/settings.js).
# THE WHOLE KEY IS LOWERCASED because PUT /api/settings validates every key
# against ^[a-z0-9_.-]{1,64}$ — an uppercase env name, lane id or project slug
# builds a key the worker refuses.
#
# An earlier draft of this file resolved the key through a short alias in the
# registry, to stay under 64 characters. It bought nothing (the longest real
# key across all eleven fleet.conf projects is 61 chars) and cost everything:
# the console wrote `lane.alert-triage.triage_max_families` and this reader
# looked up `lane.alert-triage.max_families`, so a knob set from the page landed
# on a row the lane never read, the page went on reporting "default", and
# nothing errored anywhere. One knob, one key, and it is the contract's.
_lg_setting_key() {
  local id="${1:-}" env="${2:-}" p="${3:-}" key
  if [ -n "$p" ]; then key="$(_lg_kpfx).$id.$p.$env"; else key="$(_lg_kpfx).$id.$env"; fi
  key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  case "$key" in *[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#key}" -le 64 ] || return 1
  printf '%s' "$key"
}

_lg_setting_lookup() { # _lg_setting_lookup <key> — prints the value, rc 0 if found
  local v n
  [ -n "${1:-}" ] || return 1
  _lg_sc_load || return 1
  if _lg_sc_name "$1"; then
    n="_LG_SV_$_LG_ENC"
    [ -n "${!n+x}" ] || return 1
    v=${!n}
  else
    # A key the memo cannot hold: one jq, as before BH-7251.
    v=$(jq -r --arg k "$1" '.values[$k] // empty' "$_LG_SC_FILE" 2>/dev/null) || return 1
  fi
  # The jq read went through $(…), which drops trailing newlines; so does this.
  while [ "${v%$'\n'}" != "$v" ]; do v=${v%$'\n'}; done
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# _lg_unlimited_key <id> <ENV> [project] — the explicit-unlimited row's key.
# The value key with `.unlimited` appended, so it sorts next to the knob it
# qualifies and needs no second naming scheme. It can overflow the worker's
# 64-character key limit where the value key barely fits; that is a refusal
# here (rc 1) and not a silently different key.
_lg_unlimited_key() {
  local k
  k=$(_lg_setting_key "$@") || return 1
  k="$k.unlimited"
  [ "${#k}" -le 64 ] || return 1
  printf '%s' "$k"
}

# _lg_unlimited_row <id> <ENV> [project] — rc 0 when an operator wrote the word.
# Anything but 0/false/off/empty counts as set: this row exists to be read by a
# human as a sentence, and refusing "yes" because it is not "1" would be a knob
# that silently did nothing.
_lg_unlimited_row() {
  local id="${1:-}" env="${2:-}" p="${3:-}" key v
  if [ -n "$p" ] && key=$(_lg_unlimited_key "$id" "$env" "$p"); then
    v=$(_lg_setting_lookup "$key") && { case "$v" in 0|false|off|no) return 1 ;; *) return 0 ;; esac; }
  fi
  key=$(_lg_unlimited_key "$id" "$env") || return 1
  v=$(_lg_setting_lookup "$key") || return 1
  case "$v" in 0|false|off|no) return 1 ;; *) return 0 ;; esac
}

# lane_knob_unlimited <id> <ENV> [project] — rc 0 when this knob is UNLIMITED
# right now (BH-1165).
#
# WHY A WORD AND NOT A ZERO. `0` does not mean the same thing twice in this
# fleet: it is "stop the lane" for TRIAGE_MAX_FAMILIES and "no ceiling" for the
# autopilot daily cap, and every reader had to remember which. The row says it:
# `lane.<id>[.<project>].<env lowercased>.unlimited = 1`.
#
# IT IS HONOURED ONLY WHERE 0 ALREADY MEANT UNLIMITED. On a knob whose 0 means
# OFF, reading "unlimited" as 0 would turn "spend without a ceiling" into "do
# not run at all" — the exact opposite of what was asked, arrived at silently.
# That row is refused, the value the operator set still stands, and the refusal
# is logged on the same once-an-hour throttle as every other line here.
#
# The legacy spelling keeps working: a resolved 0 on a zero_means=unlimited knob
# still reads as unlimited, because that is what every row written before this
# says.
lane_knob_unlimited() {
  local id="${1:-}" env="${2:-}" p="${3:-}" z
  [ -n "$id" ] && [ -n "$env" ] || return 1
  lane_knob_settable "$id" "$env" || return 1
  _lg_settings_refresh
  z=$(lane_knob_zero_means "$id" "$env")
  # The refusal LINE is written by lane_knob, which every reader goes through;
  # writing it here as well would double it on the one tick that reads the knob
  # and asks this question.
  [ "$z" = unlimited ] || return 1
  _lg_unlimited_row "$id" "$env" "$p" && return 0
  [ "$(lane_knob "$id" "$env" "$p")" = 0 ]
}

# lane_knob <id> <ENV> [project] — the resolved, clamped value on stdout.
# Always prints something and always returns 0: a knob reader that can print
# nothing is a lane that runs with an empty number.
lane_knob() {
  local id="${1:-}" env="${2:-}" p="${3:-}" reg key val def mn mx src was st
  [ -n "$id" ] && [ -n "$env" ] || return 0
  reg=$(_lg_registry)
  _lg_settings_refresh
  # Load the registry memo HERE, so the $(…) reads below inherit it.
  _lg_km_load "$reg" "${_LG_KIND:-lanes}" "$id"
  val=""; src=""
  # A NON-SETTABLE KNOB NEVER READS A ROW (BH-1165 review). The name is
  # registered so section 7 can see it and `show` can print it, but it is a
  # command, a host, a path, an identity or a test seam — not a number an
  # operator tunes — and this lane runs as root. If a row for one exists at all
  # somebody wrote it round the CLI and the page, so say so once an hour rather
  # than obey it silently.
  # ONE registry read for the answer, reused below: this function is called for
  # every knob of every lane on every tick.
  if lane_knob_settable "$id" "$env"; then st=1; else st=0; fi
  if [ "$st" = 1 ]; then
    if [ -n "$p" ] && key=$(_lg_setting_key "$id" "$env" "$p"); then
      val=$(_lg_setting_lookup "$key") && src=settings || val=""
    fi
    if [ -z "$val" ] && key=$(_lg_setting_key "$id" "$env"); then
      val=$(_lg_setting_lookup "$key") && src=settings || val=""
    fi
  else
    if { [ -n "$p" ] && key=$(_lg_setting_key "$id" "$env" "$p") && _lg_setting_lookup "$key" >/dev/null; } \
    || { key=$(_lg_setting_key "$id" "$env") && _lg_setting_lookup "$key" >/dev/null; }; then
      _lg_log_throttled "unsettable-$id-$env${p:+-$p}" \
        "[lane-gate] $id${p:+/$p} $env has a settings row and is NOT settable (it is a command/host/path/identity this lane runs as root) — IGNORED, the row was not applied (catalog/lanes.json: settable:false)"
    fi
  fi
  if [ -z "$val" ]; then val="${!env:-}"; [ -n "$val" ] && src=env; fi
  if [ -r "$reg" ]; then
    def=$(_lg_knob_meta "$reg" "$id" "$env" default)
    [ -z "$val" ] && { val="$def"; src=default; }
    mn=$(_lg_knob_meta "$reg" "$id" "$env" min)
    mx=$(_lg_knob_meta "$reg" "$id" "$env" max)
    # THE ENV IS NOT CLAMPED. A number in env/global.env is what this lane uses
    # today, and silently trimming it the first time a lane adopts lane_knob
    # would change fleet behaviour with nobody deciding — the opposite of
    # additive. Only a value an operator wrote as a settings row is clamped,
    # because that write went through a surface that showed them the bounds.
    # Either way the trim is never silent: one line per lane per knob per hour,
    # the same throttle the gate uses.
    if [ "$src" = settings ] && grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$val"; then
      was="$val"
      if grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$mn"; then
        awk -v v="$val" -v m="$mn" 'BEGIN{exit !(v<m)}' && val="$mn"
      fi
      if grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$mx"; then
        awk -v v="$val" -v m="$mx" 'BEGIN{exit !(v>m)}' && val="$mx"
      fi
      [ "$was" = "$val" ] || _lg_log_throttled "knob-$id-$env${p:+-$p}" \
        "[lane-gate] $id${p:+/$p} $env CLAMPED $was -> $val (registry bounds ${mn:--}..${mx:--}; the settings row still says $was)"
    elif [ "$src" = env ] && grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$val"; then
      if { grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$mn" && awk -v v="$val" -v m="$mn" 'BEGIN{exit !(v<m)}'; } \
      || { grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$mx" && awk -v v="$val" -v m="$mx" 'BEGIN{exit !(v>m)}'; }; then
        _lg_log_throttled "knob-$id-$env${p:+-$p}" \
          "[lane-gate] $id${p:+/$p} $env is $val from the environment, outside the registry's ${mn:--}..${mx:--} — USED AS IS, not clamped (env/global.env is today's behaviour; set a settings row to change it)"
      fi
    fi
  fi
  # A SEEDED ROW IS NOT A RUNG (BH-1511.1 review, I1). It is the DB's copy of
  # the registry default, for the console. Where the registry answers, it is
  # redundant; where the registry does NOT (unreadable, or the knob's default
  # removed and its orphan row not yet pruned) it would answer with a value
  # the code no longer has, where this function has always answered empty and
  # let the caller's own literal decide.
  # THE WORD BEATS THE NUMBER. An explicit `.unlimited` row resolves to this
  # lane's unlimited value — which is 0, the spelling every row written before
  # BH-1165 uses, so nothing downstream has to learn a second one. On a knob
  # whose 0 means OFF the row is REFUSED with a line and the value the operator
  # set stands: there, 0 stops the lane, and reading "unlimited" as 0 would be
  # the exact opposite of what was asked.
  #
  # This is decided here and not by calling lane_knob_unlimited, which resolves
  # the value through THIS function — one call each way is a loop that hangs
  # every lane on the fleet at its first knob read.
  if [ "$st" = 1 ] && _lg_unlimited_row "$id" "$env" "$p"; then
    if [ "$(lane_knob_zero_means "$id" "$env")" = unlimited ]; then val=0
    else
      _lg_log_throttled "unlim-$id-$env${p:+-$p}" \
        "[lane-gate] $id${p:+/$p} $env has an .unlimited settings row and its 0 does NOT mean unlimited — REFUSED, the value row still stands (bin/harness-ctl.sh set $id $env <n>)"
    fi
  fi
  printf '%s' "$val"
}

# lane_env_apply <id> [project] — put this lane's settings rows into its
# ENVIRONMENT, right after the gate (BH-1165).
#
# WHY NOT REWRITE EVERY READ. The 78 lanes read some 320 `${KNOB:-default}`
# variables between them. Rewriting each one into `lane_knob` is 320 chances to
# move a default by hand, in 69 scripts nobody would review line by line. This
# is one mechanism: for every knob the REGISTRY declares for this lane, if a
# settings row exists, export the resolved (and clamped) value, so the script's
# own unmodified read picks it up.
#
# NOTHING IS EXPORTED WITHOUT A ROW. Not the registry default, not the env: a
# box with no settings rows behaves byte-for-byte as it does today, which is the
# only migration story worth having for a fleet that is already running. The
# ONE exception is a knob marked `required: true` (BH-1511.1): its script has no
# literal left, so its registry default is exported when nothing else answers —
# see _lg_env_apply below.
#
# THE REGISTRY DECIDES WHICH NAMES EXIST, never the settings table. A settings
# row is operator input arriving over HTTP; walking the table instead of the
# lane's declared knobs would let `lane.alert-triage.path` export PATH into a
# lane that runs a model with a token in its environment. The loop is over
# catalog/lanes.json and the name must still be a legal shell identifier.
#
# AND ONLY THE SETTABLE ONES (BH-1165 review). Registering every read means the
# declared set now includes the command a lane runs, the host it sends its
# bearer to and the path it deletes under. Those carry `settable: false` and are
# skipped here, so a row can never export one into a lane cron runs as root —
# see lane_knob_settable.
lane_env_apply() { _lg_env_apply lanes "${1:-}" "${2:-}"; }

# lib_env_apply <lib-id> [project] — the same, for the knobs a SHARED library reads
# (BH-1511.1). bin/lib/wake-lanes.sh is sourced by ten lanes, so its knobs
# belong to no one lane: they are registered once, in the registry's `libs`
# scope (catalog/lanes.d/_lib.json), keyed `lib.<id>.<env lowercased>`, and the
# library calls this itself at the point it needs one. An optional project
# (BH-2604) reads `lib.<id>.<project>.<env lowercased>` first, as lanes do.
lib_env_apply() { _lg_env_apply libs "${1:-}" "${2:-}"; }

# _lg_alert_once <id> <message> — ONE ALERTS line per scope per DAY, the same
# reservoir bin/lib/model-route.sh uses, so a lane stuck failing closed pages
# once rather than on every tick.
_lg_alert_once() {
  local h flag
  h=$(_lg_h)
  [ -n "$h" ] || return 0
  flag="$h/flags/alerted-lane-gate-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null
  touch "$flag" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" >> "$h/logs/ALERTS.log" 2>/dev/null
  return 0
}

# _lg_env_apply <lanes|libs> <id> [project] — the body of both.
#
# FOR EVERY KNOB THE REGISTRY DECLARES for this scope, in one pass:
#   - an OPERATOR row (settable knobs only, see lane_knob_settable) is resolved
#     through lane_knob (clamp, `.unlimited`, logging) and exported, exactly as
#     before BH-1511.1. When the worker did not answer this tick, that row came
#     from the box cache: said once an hour per scope in logs/lane-gate.log;
#   - a `required: true` knob with no row keeps a non-empty env value, else is
#     exported at its registry default, else the lane FAILS CLOSED: exit 75,
#     one ALERTS line a day, the body never runs on an empty value;
#   - anything else is left alone — today's behaviour, byte for byte.
# THE REGISTRY DECIDES WHICH NAMES EXIST, never the settings table (see above),
# and an unreadable registry runs the lane untouched: nothing can be known
# about which knobs exist, and 78 lanes must not stop on a render failure.
_lg_env_apply() {
  local _LG_KIND="${1:-lanes}"
  local id="${2:-}" p="${3:-}" reg e st rq def low key v hit state b pfx envs
  local cached="" defaulted="" missing=""
  [ -n "$id" ] || return 0
  reg=$(_lg_registry)
  [ -r "$reg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  _lg_settings_refresh
  state=$(_lg_settings_state)
  # Both memos are loaded HERE, in the lane's own shell, so every lane_knob
  # below and every knob read the lane makes after this runs no jq.
  _lg_sc_load || :
  _lg_km_load "$reg" "$_LG_KIND" "$id"
  envs=""
  if _lg_km_triple "$reg" "$_LG_KIND" "$id"; then b="_LG_KM_E_$_LG_MI"; envs=${!b-}; fi
  if [ "$_LG_KIND" = libs ]; then pfx=lib; else pfx=lane; fi
  # The OPERATOR rows: any key in `.values` counts, even one with an empty
  # value. Seeded rows are not in `.values`, so a table the seed filled costs a
  # lane nothing.
  while IFS= read -r e; do
    case "$e" in ''|*[!A-Z0-9_]*|[0-9]*) continue ;; esac
    _lg_km_get "$reg" "$_LG_KIND" "$id" "$e" sa; st=$_LG_MV
    _lg_km_get "$reg" "$_LG_KIND" "$id" "$e" rq; rq=$_LG_MV
    _lg_km_get "$reg" "$_LG_KIND" "$id" "$e" ad; def=$_LG_MV
    if [ "$st" = true ] && [ "$_LG_SK_N" -gt 0 ]; then
      _lg_lower "$e"; low=$_LG_LOW; hit=""
      for key in ${p:+"$pfx.$id.$p.$low" "$pfx.$id.$p.$low.unlimited"} \
                 "$pfx.$id.$low" "$pfx.$id.$low.unlimited"; do
        _lg_sc_has "$key" && { hit=1; break; }
      done
      if [ -n "$hit" ]; then
        # lane_knob does the resolving, the clamping and the logging, so one
        # reader cannot see a number the other would have refused.
        v=$(lane_knob "$id" "$e" "$p")
        export "$e=$v"
        [ "$state" = fresh ] || cached="$cached $e"
        continue
      fi
    fi
    [ "$rq" = true ] || continue
    [ -n "${!e:-}" ] && continue
    if [ -n "$def" ]; then export "$e=$def"; defaulted="$defaulted $e"
    else missing="$missing $e"; fi
  done <<<"$envs"
  if [ -n "$cached" ]; then
    _lg_log_throttled "cache-$_LG_KIND-$id${p:+-$p}" \
      "[lane-gate] $id${p:+/$p}: worker unreachable — settings served from the box cache ($(_lg_settings_file)):$cached"
  fi
  if [ -n "$defaulted" ] && [ "$state" != fresh ]; then
    _lg_log_throttled "default-$_LG_KIND-$id${p:+-$p}" \
      "[lane-gate] $id${p:+/$p}: worker unreachable and no row cached — registry default for:$defaulted"
  fi
  if [ -n "$missing" ]; then
    _lg_log_throttled "closed-$_LG_KIND-$id${p:+-$p}" \
      "[lane-gate] $id${p:+/$p}: FAIL CLOSED — required knob(s) with no row, no env and no registry default:$missing"
    _lg_alert_once "$_LG_KIND-$id${p:+-$p}" \
      "[lane-gate] $id${p:+/$p} did NOT run: required knob(s)$missing have no settings row, no cached row, no env value and no registry default. Nothing was guessed — PUT /api/settings $(_lg_kpfx).$id.<env> or give the knob a default in catalog/lanes.d (BH-1511)."
    exit 75
  fi
  return 0
}

# lane_knob_zero_means <id> <ENV> — "off" | "unlimited" | "" — so a surface
# never shows a bare 0 and a reader can ask what this lane's 0 means rather than
# remembering that it means "off" for TRIAGE_MAX_FAMILIES and "unlimited" for
# the autopilot daily cap.
lane_knob_zero_means() {
  local reg; reg=$(_lg_registry)
  [ -r "$reg" ] || return 0
  _lg_knob_meta "$reg" "${1:-}" "${2:-}" zero_means
}
