#!/bin/bash
# alert-writer: by-design — the state machine behind beat.sh, which bin/alert-line.sh calls; routing its writes through the helper would recurse
# bin/lib/alert-state.sh — THE alert state machine. Sourced by bin/lane-alert.sh
# (the writer side) and bin/beat.sh (the chokepoint every other emitter already
# goes through). Not executable on its own.
#
# WHY (the operator, 2026-09-15: "the alerts topic is noise on my phone"). 24h of
# ALERTS.log: 68 EXTRA-USAGE lines for ONE account in ONE overage (its marker
# keyed on a resets_at timestamp whose microseconds move every poll, so the
# dedupe could never hit), ~35 pipeline-health RESOLVED lines for the same
# condition clearing and re-clearing, 10 SILENT triage rows paged one by one,
# 5 LANE DOWN lines every canary from a box that is deliberately parked. Every
# one of those is a CONDITION, and a condition has a lifecycle: it starts, it
# persists, it ends. The fleet had no place to keep that, so every emitter
# re-invented a marker file and each one was wrong in its own way.
#
# The model, one place, for every alert:
#   id          a stable key for the condition. Explicit (--id) where the
#               emitter knows what it is watching; otherwise DERIVED from a
#               normalised hash of the line (bin/alert_family.py's row_key, the
#               fleet's one normalisation rule), so an emitter nobody has
#               retrofitted is still deduped without touching its script.
#   fire        first sighting of an id -> the alert goes out.
#   suppress    same id while open -> count++, one line in logs/alerts-state.log
#               and NOTHING sent.
#   remind      same id, still open, ALERT_REMINDER_S since the last send ->
#               one send carrying "still firing, n=...".
#   resolve     --resolve on an open id -> exactly one send. On a closed or
#               unknown id -> silence (a retraction of nothing is noise too).
#   severity    critical -> send now; warn -> batched into the digest cadence;
#               info -> logged only.
#
# State: state/alerts/<id>.json {first_seen,last_seen,last_notified,count,
# severity,resolved_at,line}. ALERTS.log stays APPEND-ONLY and keeps its exact
# line shape — this layer only ever writes FEWER lines to it, never different
# ones, so every existing grep-based reader still works.
#
# FAIL OPEN is load-bearing, exactly as in beat.sh: no jq, no python3, no state
# dir, a lock we could not take — any of those and the decision is `fire`. A
# bug in the noise filter must cost a duplicate page, never a missed one.
# Kill switch: ALERT_STATE_ENABLED=0, or the settings row
# switch.alert-state-off[.<box>] (flags/alert-state-off when no row).

# Guard against double-sourcing (beat.sh may be re-entered by a remediation).
[ -n "${_ALERT_STATE_LIB:-}" ] && return 0
_ALERT_STATE_LIB=1

# BH-1138: a sourced lib exports it for the caller too — bin/lib/alert-state.sh
# runs bin/alert_family.py on every alert, and its callers (bin/lane-alert.sh,
# bin/beat.sh) spawn more python of their own. No __pycache__ is ever written
# beside bin/*.py, so no whole-tree `git add -A` can re-commit one.
export PYTHONDONTWRITEBYTECODE=1

_AS_H="${HARNESS:-/root/harness}"
_AS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -n "$_AS_BIN" ] || _AS_BIN="$_AS_H/bin"
_AS_CONF="${ALERTS_CONF:-$_AS_H/flags/alerts.conf}"

# ── CONFIG ──────────────────────────────────────────────────────────────────
# Precedence: environment > settings row `conf.alerts.<name lowercased>[.<box>]`
# (BH-2411, bin/lib/conf-row.sh; not read when $ALERTS_CONF names a fixture)
# > flags/alerts.conf `set <NAME> <value>` > the code default named at the
# call site. Only the `set` scalars have rows; the rule tables and `parked`
# lists below are read from the file alone. A row _as_row_ok refuses (BH-2478;
# plus ALERT_BUILTIN_RULES, ALERTS_PR_SUBJECT_RE and ALERTS_SWEEP_AUTH_PROSE_RE at
# any value and ALERT_DEFAULT_SEVERITY info, V1)
# is logged and read as no row, so the file answers, never the code default. The conf file is machine-local (flags/ is
# gitignored, like flags/cost-caps.conf); env-templates/alerts.conf.example is
# the documented copy and docs/ALERTS-STATE-MACHINE.md is the contract. A box
# with no conf file at all behaves exactly as the defaults below say.
#
# PARSED, NOT SOURCED. The file carries rule tables as well as scalars, and a
# config file that can execute is a config file that can be an exploit.
# shellcheck source=conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/conf-row.sh" 2>/dev/null || true
# _as_cfg_ok <NAME> <value> — is this a value the scalar's readers can use.
#   Switches are 0|1, *_S and *_MAX are non-negative integers, the severity is
#   one of the three, a *_RE compiles as an ERE (grep -E rc 2 = bad pattern);
#   anything else needs only to be non-empty.
_as_cfg_ok() {
  case "$1" in
    *_ENABLED|ALERT_BUILTIN_RULES) case "$2" in 0|1) return 0 ;; esac; return 1 ;;
    *_S|*_MAX) case "$2" in ''|*[!0-9]*) return 1 ;; esac; return 0 ;;
    ALERT_DEFAULT_SEVERITY) case "$2" in info|warn|critical) return 0 ;; esac; return 1 ;;
    *_RE) [ -n "$2" ] || return 1; printf '' | grep -E -- "$2" >/dev/null 2>&1; [ "$?" != 2 ]; return ;;
  esac
  [ -n "$2" ]
}

# _as_row_ok <NAME> <value> — _as_cfg_ok, plus what a settings ROW may never set
# (the #2291 allow-list, on conf-row). A row is written from the console for the
# whole fleet, so it may tune alerting, never gut it:
#   ALERT_BUILTIN_RULES      any value: 0 would drop every shipped collapse,
#                            severity and logonly rule on every box at once
#   ALERT_DEFAULT_SEVERITY   info: would mute every emitter nobody retrofitted
#   ALERTS_PR_SUBJECT_RE     any value: it decides which rows the groomer and the
#                            sweep may settle on a PR close; "." would settle every
#                            PR-naming row on merge (the #2293 bug)
#   ALERTS_SWEEP_AUTH_PROSE_RE  any value: it decides which auth pages the sweep
#                            closes as false; "." would close real ones
# The environment and flags/alerts.conf still set both. A refused row is logged
# by conf_row_refused and read as no row (BH-2478). tests/alert-hygiene.v1-test.sh R9.
_as_row_ok() {
  case "$1" in
    ALERT_BUILTIN_RULES|ALERTS_PR_SUBJECT_RE|ALERTS_SWEEP_AUTH_PROSE_RE) return 1 ;;
    ALERT_DEFAULT_SEVERITY) [ "$2" = info ] && return 1 ;;
  esac
  _as_cfg_ok "$1" "$2"
}

alert_cfg() { # alert_cfg <NAME> <default>
  local n="$1" d="$2" v="${!1:-}" k
  if [ -z "$v" ] && [ -z "${ALERTS_CONF:-}" ] && command -v conf_row >/dev/null 2>&1; then
    k="${n,,}"
    if v=$(conf_row alerts "$k" "$_AS_H") && [ -n "$v" ]; then
      if _as_row_ok "$n" "$v"; then
        conf_row_note_file alerts "$_AS_CONF" "$k"
      else
        conf_row_refused alerts "$k" "$v" "$_AS_CONF" "$_AS_H"
        v=""
      fi
    else
      v=""
    fi
  fi
  if [ -z "$v" ] && [ -r "$_AS_CONF" ]; then
    # The VALUE is everything after the name, not $3: ALERT_PARK_DOWNGRADE_RE is
    # an alternation with spaces in it, and a config value silently truncated at
    # the first space is config that looks set and is not.
    v=$(awk -v k="$n" '$1=="set" && $2==k { $1=""; $2=""; sub(/^ +/,""); v=$0 } END{print v}' "$_AS_CONF" 2>/dev/null)
  fi
  case "$v" in '') printf '%s' "$d" ;; *) printf '%s' "$v" ;; esac
}

# _as_preload — the alerts rows into THIS shell, once (BH-2478): alert_cfg is
# called as `$(…)`, and without this every call re-read the settings cache.
# The two gates below are what every alert-state caller runs before its first
# `$(alert_cfg …)`, so they carry it.
_as_preload() {
  [ -z "${ALERTS_CONF:-}" ] && command -v conf_rows_preload >/dev/null 2>&1 \
    && conf_rows_preload alerts "$_AS_H"
  return 0
}

alert_state_enabled() {
  # The switch lib is loaded here, on the first read, not when this file is
  # sourced. LANE_GATE_DISABLE=1 (where lane_switch answers the file anyway) and
  # a fixture $ALERTS_CONF load nothing, as conf_rows_preload does, and read the
  # file alone. Loading the lib and reading the row can source jobs-client.sh,
  # which sets -uo pipefail, so the caller's options are saved and restored
  # around both, as alerts_db_on does.
  local _as_opts _as_off=1
  _as_opts=$(set +o)
  if ! command -v lane_switch >/dev/null 2>&1; then
    if [ "${LANE_GATE_DISABLE:-}" != 1 ] && [ -z "${ALERTS_CONF:-}" ]; then
      # shellcheck source=lane-switch.sh
      . "$_AS_BIN/lib/lane-switch.sh" >/dev/null 2>&1 || true
    fi
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$_AS_H/flags/$1" ]; }
  fi
  HARNESS="$_AS_H" lane_switch alert-state-off file >/dev/null 2>&1 && _as_off=0
  eval "$_as_opts" 2>/dev/null
  [ "$_as_off" = 0 ] && return 1
  _as_preload
  [ "$(alert_cfg ALERT_STATE_ENABLED 1)" = "0" ] && return 1
  return 0
}

# alerts_db_on — the ONE gate every script tests before making any /api/alerts*
# call. Rc 0 only when the box-level flag file exists, the kill switch is not 0,
# and the jobs-client library can be loaded. The source is guarded and happens
# INSIDE this function so the off path loads nothing new.
alerts_db_on() {
  [ -f "$_AS_H/flags/alerts-db" ] || return 1
  _as_preload
  [ "$(alert_cfg ALERTS_DB_ENABLED 1)" = "0" ] && return 1
  # jobs-client.sh sets `-uo pipefail` at ITS top level, and sourcing it here
  # would leave those on in the caller — beat.sh runs -u without pipefail, so
  # the first on-path gate call would change pipeline rc for the rest of that
  # run. The caller's option set is captured and restored around the source.
  local _as_opts rc=1
  _as_opts=$(set +o)
  [ -r "$_AS_H/bin/jobs-client.sh" ] && . "$_AS_H/bin/jobs-client.sh" >/dev/null 2>&1 && rc=0
  eval "$_as_opts" 2>/dev/null
  return "$rc"
}

_as_dir() { printf '%s' "${ALERT_STATE_DIR:-$_AS_H/state/alerts}"; }
_as_log() { printf '%s' "${ALERT_STATE_LOG:-$_AS_H/logs/alerts-state.log}"; }

# One tab-free line per decision, for the operator and for the tests. This is
# the "still firing, n=..." record: it is deliberately NOT ALERTS.log, because
# 68 suppressed repeats in the alert record would be the same wall of text one
# file over, and poll-commands.sh re-beats new ALERTS.log lines.
as_log() { # as_log <text>
  local f; f="$(_as_log)"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$f" 2>/dev/null || true
}

# ── RULE TABLES: the conf's rules first, then the ones that ship ────────────
# The `collapse` and `severity` tables below are DEFAULTS IN CODE, on purpose.
# flags/ is machine-local and is not one of the directories harness-sync rsyncs,
# so a rule that lives only in env-templates/alerts.conf.example takes effect on
# exactly the boxes where somebody remembered to copy a file — and the three
# emitters these cover (bin/jobs-watchdog.sh, bin/pipeline-health.sh) are owned
# by other lanes and cannot be fixed at the source. A default that needs an
# operator to arrive is not a default; it is a plan.
#
# A conf rule is matched FIRST and wins, so a box can always override or extend
# these; `set ALERT_BUILTIN_RULES 0` drops them entirely. Each line is
# "<ERE>\t<target>", which is the shape both readers below already parse.
_as_builtin_rules() { # _as_builtin_rules collapse|severity|logonly
  [ "$(alert_cfg ALERT_BUILTIN_RULES 1)" = "0" ] && return 0
  case "$1" in
    collapse)
      # Ten SILENT rows naming ten tickets are ONE dead lane, and the watchdog
      # emits them one per row. row_key keeps them apart (correctly, for its own
      # purpose: two stuck builds are two problems), so the collapse is per
      # PROJECT, which is the unit the reader would act on.
      printf '%s\t%s\n' '\[jobs-watchdog\] SILENT job: ([a-z0-9-]+)' 'jobs-watchdog-silent-\1'
      printf '%s\t%s\n' '\[jobs-watchdog\] LANE SILENT: ([a-z0-9-]+)@([a-z0-9-]+)' 'jobs-watchdog-lane-silent-\1-\2'
      # BH-3997: pipeline-health's three merge alerts key on the CONDITION, not
      # the text. row_key hashed the PR list, the labels and the age, so a
      # shorter list or a new label minted a sibling row and nothing closed the
      # old one. Awaiting-merge lists many PRs, so it is one row per repo; the
      # two not-in-queue alerts are one PR each, so they key on the PR too
      # (two stuck PRs must not overwrite one row). The awaiting-merge rule needs
      # the `prs=` token, so a legacy line without it keeps its old key.
      # bin/alerts-merge-resolve.sh closes these rows when their PRs settle.
      printf '%s\t%s\n' '\[pipeline-health\] [a-z0-9._-]+: harness PR\(s\) [#0-9,]+ open >[0-9]+h awaiting merge.* prs=([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#' 'ph-awaitmerge-\1-\2'
      printf '%s\t%s\n' '\[pipeline-health\] ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) #([0-9]+) has lead-verdict success .* not in the merge queue' 'ph-leadunqueued-\1-\2-\3'
      printf '%s\t%s\n' '\[pipeline-health\] https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) is APPROVE .*OPEN and CLEAN .*not in the merge queue' 'ph-approveunqueued-\1-\2-\3'
      # The canary says LANE DOWN TWICE for one failure, in two different
      # sentences: bin/claude-auth-check.sh writes "[auth] <box>-<lane> LANE
      # DOWN" straight into ALERTS.log AND beats "RUNNER LANE DOWN: <lane> on
      # <box> box failed its canary". poll-commands.sh re-beats that log line,
      # so the second sentence arrives here a minute later as a condition this
      # file has never seen. Mapping it onto the id the beat declared
      # (lanedown-<box>-<lane>) is what makes one failure one alert.
      printf '%s\t%s\n' '\[auth\] ([a-z0-9_.-]+) LANE DOWN' 'lanedown-\1'
      # BH-2337: main-red's RED and its GREEN are ONE condition per repo, so the
      # GREEN's `lane-alert.sh --resolve` closes exactly the id the RED opened
      # (the RED's text carries a sha and a run URL, so its derived key could
      # never be re-derived from the GREEN's). BH-2381: STILL RED (a new red sha
      # on a main already red) is that same condition, so the GREEN closes it too.
      printf '%s\t%s\n' '\[orchestrator/main-red\] ([^ ]+) main is RED' 'main-red-\1'
      printf '%s\t%s\n' '\[orchestrator/main-red\] ([^ ]+) main is STILL RED' 'main-red-\1'
      printf '%s\t%s\n' '\[orchestrator/main-red\] ([^ ]+) main is GREEN again' 'main-red-\1'
      # The visibility canary's blind-repo line is written to ALERTS.log AND
      # beaten with alertid ghdefault-<slug>; the re-beat lands on that id and
      # is a counted repeat, not a second row.
      printf '%s\t%s\n' '\[auth\] DEFAULT GH TOKEN CANNOT SEE ([^ ]+) ' 'ghdefault-\1'
      # V1 alert hygiene (2026-09-25): the auth canary's other ALERTS.log lines
      # carry the probe's own words after the colon, which differ every run —
      # so row_key minted a new condition, and a new console row, per probe.
      # Each maps onto the id its beat declares (bin/claude-auth-check.sh), so
      # one box's one condition is one alert however the text is worded.
      printf '%s\t%s\n' '\[auth\] ([a-z0-9_.-]+) AUTH PROBE INCONCLUSIVE' 'authprobe-\1'
      printf '%s\t%s\n' '\[auth\] ([a-z0-9_.-]+) CLAUDE AUTH DOWN' 'authdown-\1'
      printf '%s\t%s\n' '\[auth\] ([a-z0-9_.-]+) MODEL POOL EXHAUSTED' 'pooldry-\1'
      ;;
    logonly)
      # BH-2337 (2026-09-25: 180 of 377 open alerts were these). Success and
      # recovery are STATE, not alerts: each line below is written to
      # ALERTS.log for the audit and never becomes a row. Each ERE is anchored
      # on the success wording AND its count (BH-2381), so the failure sibling
      # cannot match: 7/8 boxes or 2/3 rebaked is not \1/\1, and a partial
      # propagate says "FAILED in part".
      printf '%s\t%s\n' '^\[orchestrator/fleet-propagate\] propagated [0-9a-f]+ to the fleet: ([0-9]+)/\1 boxes synced' log
      printf '%s\t%s\n' '^\[orchestrator/fleet-propagate\] drained the pool images debounced earlier at [0-9a-f]+: ([0-9]+)/\1 rebaked' log
      # Hotfix NOTICES only; a hotfix failure line (APPLY FAILED, CLOSE-OUT OWED,
      # could NOT be labelled) never says "HOTFIX <event>: " and still pages.
      printf '%s\t%s\n' '^\[[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\] HOTFIX (seen|pr_open|merged): ' log
      printf '%s\t%s\n' '^\[orchestrator/main-red\] (RESOLVED: )?[^ ]+ main is GREEN again' log
      # The default PAT is blind but the admin token covers it: lanes keep
      # working, and the per-repo status is a gh_visibility ledger row.
      printf '%s\t%s\n' '^\[auth\] DEFAULT GH TOKEN CANNOT SEE [^ ]+ \([^)]*\)( \(new\))?: the admin token CAN see it' log
      printf '%s\t%s\n' '^\[auth\] ghdefault-[A-Za-z0-9_.-]+ RECOVERED — the default gh token sees [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ again$' log
      # BH-4054: pipeline-health's retraction is a structured resolve beat
      # (alertid ph-<key>, resolved:true), which closes the row its alert
      # opened and is exempt from this table. This is its TEXT copy: the
      # ALERTS.log audit line, beaten by bin/alert-line.sh or re-beaten by
      # poll-commands.sh. Noted, it would open a new row saying something is
      # fine. Anchored on the epilogue's own "RESOLVED <key> — " shape, so a
      # "RESOLVED: ..." sentence from any other emitter still routes.
      printf '%s\t%s\n' '^\[pipeline-health\] RESOLVED [^ ]+ — ' log
      ;;
    severity)
      # DELIBERATELY NO rule on the word RESOLVED. A resolve is the CLOSING
      # EDGE of an alert somebody was actually paged about, and demoting those
      # to info is how "fire once, resolve once" quietly becomes "fire once" —
      # caught by tests/alert-state-machine-test.sh the first time it was
      # tried. pipeline-health's own RESOLVED text used to be demoted here;
      # since BH-4054 its structured resolve rides the condition's open
      # severity (bin/beat.sh) and its text copy is a logonly notice above.
      # Recovery lines that their emitters write STRAIGHT into ALERTS.log, and
      # which therefore arrive here only through poll-commands.sh's re-beat —
      # carrying no severity, so the default would turn each one into a fresh
      # critical page announcing that something is FINE.
      printf '%s\t%s\n' '\[auth\] [a-z0-9_.-]+ RECOVERED' 'info'
      printf '%s\t%s\n' '\[jobs-watchdog\] LANE RESUMED' 'info'
      # P1: bin/cache-hit-report.sh's per-lane cache-efficiency line is a
      # daily cost trend, not an outage — its default ceiling sits near the
      # pre-profile baseline, so at the critical default it would page every
      # morning. Warn = the digest. Deterministic on purpose: no LLM lane is in
      # this line's path.
      printf '%s\t%s\n' '\[cache-hit\] lane [^ ]+: cache WRITES are ' 'warn'
      # C2 (lead review of #2231): an App mint that failed, or a CI read the PAT
      # had to answer, is a fleet-drifting-back-to-the-PAT signal. It is real but
      # not a 3am page: the batched warn digest (bin/alert-digest.sh --warn-batch).
      # The emitter rate-limits to one line per slug per hour.
      printf '%s\t%s\n' '\[gh-app-default\] APP MINT FAILED for ' 'warn'
      printf '%s\t%s\n' '\[gh-ci-read\] PAT RUNG for ' 'warn'
      # bin/gh-pat-charge-alert.sh counts a migration down to zero: a lane still
      # spending a PAT's quota is a digest item, not a phone call. Its lines carry
      # the day's counts, so each day is a new row key; at the default critical
      # the known backlog would page ~6-12 times a day.
      printf '%s\t%s\n' '\[gh-pat-charge-alert\]' 'warn'
      # K3: bin/lib/call-guard.sh's once-a-day lines. A refused repeat call is
      # the guard WORKING (nothing was bought), and an unreadable counter is
      # already paged by jobs-client's own outage line — both are the digest,
      # never a phone. Deterministic, like the rule above.
      printf '%s\t%s\n' '\[call-guard\] (REPEAT CALLS REFUSED|COUNTER UNREADABLE|ROUTE MISSING) ' 'warn'
      # V1 alert hygiene (2026-09-25): STATUS EVENTS ARE NOT ALERTS. Each of
      # these says the system did the right thing on its own, and nobody has an
      # action to take — measured on the console that week, they were a large
      # share of the ~459 open rows. They stay in ALERTS.log (the record) and
      # logs/alerts-state.log; they never reach a phone. What stays critical is
      # the line that means a human is now owed something: the DEFERRED that
      # FAILED the queue row, POOL_SPAWN_CAP_WAIT (POOL_DEFER_TO_HUMAN until
      # BH-4859; its routing is unchanged), a hotfix failure line.
      # HOTFIX seen/pr_open/merged and the admin-covered GH-token line are not
      # here: they are `logonly` notices (BH-2337, BH-2381), dropped before
      # routing.
      #   an account ran dry, another serves, the ticket is requeued unchanged
      printf '%s\t%s\n' 'account [^ ]+ ran out .*no project hold.*requeued' 'info'
      #   a pool build deferred and requeued for another attempt
      printf '%s\t%s\n' 'pool build DEFERRED .* requeued attempt [0-9]+' 'info'
      ;;
  esac
}

# _as_rules <collapse|severity|logonly> — the conf's table, then the shipped one.
_as_rules() {
  [ -r "$_AS_CONF" ] && awk -v k="$1" '$1==k && NF>=3 { t=$NF; $1=""; $NF="";
        sub(/^ +/,""); sub(/ +$/,""); printf "%s\t%s\n", $0, t }' "$_AS_CONF" 2>/dev/null
  _as_builtin_rules "$1"
}

# alert_state_logonly <line> — rc 0 when <line> is a notice, not an alert: a
# `logonly <ERE> log` rule from the conf or the shipped table matches it (after
# the leading stamp is stripped). Such a line keeps its ALERTS.log copy and is
# never noted or sent (BH-2337). No rule, no grep: rc 1, and the line pages.
alert_state_logonly() { # alert_state_logonly <line>
  local line re t
  line=$(as_strip_stamp "${1:-}")
  [ -n "$line" ] || return 1
  while IFS=$'\t' read -r re t; do
    [ -n "$re" ] || continue
    grep -qE -- "$re" <<<"$line" 2>/dev/null && return 0
  done < <(_as_rules logonly)
  return 1
}

# ── THE ID ──────────────────────────────────────────────────────────────────
# A leading UTC timestamp is stripped BEFORE hashing. Two paths carry the same
# condition to the console — the emitter's own fleet_alert beat and
# poll-commands.sh re-beating the new ALERTS.log line (kind:"alert", line
# prefixed with the log timestamp) — and without this strip they hash apart and
# every alert pages twice.
as_strip_stamp() { # as_strip_stamp <line>
  printf '%s' "$1" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2} ?Z? *//'
}

# An id becomes a FILENAME, so anything outside [A-Za-z0-9_.-] is folded rather
# than sanitised away silently, and the length is capped (same reasoning as
# beat.sh's akey guard).
as_sanitize_id() { # as_sanitize_id <raw>
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-120
}

# alert_state_key <line> — the derived id for an emitter that names none.
#
# Order: a `collapse <ERE> <id-template>` rule from the conf (first match wins,
# \1..\9 available), then row_key() from bin/alert_family.py. row_key and NOT
# family: family() folds every digit run, so TK-1 and TK-99 are one signature —
# right for magnitudes, catastrophic for identities, and this key decides
# whether a condition gets its own page. That is the same call poll-commands.sh
# makes, for the same reason, against the same implementation.
#
# Collapse rules are how an emitter this lane may not edit gets a coarser key
# than its text deserves: 10 SILENT triage rows naming 10 different tickets are
# 10 row_keys and ONE problem, so the shipped conf collapses them per project.
alert_state_key() { # alert_state_key <line>
  local line rule re tmpl k
  line=$(as_strip_stamp "$1")
  while IFS=$'\t' read -r re tmpl; do
    [ -n "$re" ] && [ -n "$tmpl" ] || continue
    k=$(printf '%s' "$line" | sed -nE "s|^.*$re.*\$|$tmpl|p" 2>/dev/null | head -1)
    [ -n "$k" ] && { as_sanitize_id "$k"; return 0; }
  done < <(_as_rules collapse)
  command -v python3 >/dev/null 2>&1 || return 0   # fail open: no key, no dedupe
  k=$(python3 "$_AS_BIN/alert_family.py" row_key "$line" 2>/dev/null) || k=""
  [ -n "$k" ] || return 0
  k=$(as_sanitize_id "auto-$k")
  # ALIASES. An emitter that named its own --id writes the SAME text into
  # ALERTS.log, and poll-commands.sh re-beats every new ALERTS.log line as
  # kind:"alert" — a second arrival at this chokepoint that knows nothing about
  # the explicit id and would therefore page the condition a second time. The
  # alias is the emitter saying "this text is that condition", recorded once
  # when it fires.
  local a; a="$(_as_dir)/alias/$k"
  if [ -s "$a" ]; then
    k=$(head -1 "$a" 2>/dev/null | tr -dc 'A-Za-z0-9_.-')
    [ -n "$k" ] || k=$(as_sanitize_id "auto-$(python3 "$_AS_BIN/alert_family.py" row_key "$line" 2>/dev/null)")
  fi
  printf '%s' "$k"
}

# alert_state_alias <line> <id> — record that <line>'s derived key means <id>.
# Best-effort in every direction: a missing alias costs one duplicate page.
alert_state_alias() { # alert_state_alias <line> <id>
  local k d
  [ -n "${2:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  k=$(python3 "$_AS_BIN/alert_family.py" row_key "$(as_strip_stamp "$1")" 2>/dev/null) || return 0
  [ -n "$k" ] || return 0
  k=$(as_sanitize_id "auto-$k")
  [ "$k" = "$2" ] && return 0
  d="$(_as_dir)/alias"; mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$d/$k" 2>/dev/null || true
}

# ── SEVERITY ROUTING ────────────────────────────────────────────────────────
# alert_state_route <line> <declared-severity> — the severity actually used.
#
# 1. `severity <ERE> <level>` rules from the conf, first match wins. This is how
#    a whole class ("[pipeline-health] RESOLVED ...") is demoted without editing
#    the script that emits it.
# 2. PARKED BOXES. A box under a paused-<box> flag, or named by a `parked <box>`
#    directive, is deliberately not running: its canary failing is the expected
#    outcome, not news. Any DOWN/SILENT/UNREACHABLE line naming such a box is
#    downgraded to info. This is a downgrade only — it can never RAISE severity,
#    and it never touches a line about a box that is actually in service.
# alert_state_retired_tokens — every name fleet.conf retires: the project, its
# box, and the box's short label (box-<label>), space-separated. Empty
# when the registry cannot be read — the fail-open direction, nothing is muted.
#
# A LIVE NAME IS NEVER RETIRED (review of #2291). A directive that names a
# project still watched (fleet-conf.sh --projects) or a box/label a live project
# still runs on is dropped and logged as `retired-conflict` in
# logs/alerts-state.log: muting a live box because someone left a stale line is
# the exact failure this layer must not be able to cause.
alert_state_retired_tokens() {
  [ -x "$_AS_BIN/fleet-conf.sh" ] || return 0
  local live t out=""
  live=" $(
    while read -r p; do
      [ -n "$p" ] || continue
      printf '%s ' "$p"
      b=$("$_AS_BIN/fleet-conf.sh" "$p" box 2>/dev/null)
      [ -n "$b" ] && [ "$b" != local ] && printf '%s %s ' "$b" "${b#box-}"
    done < <("$_AS_BIN/fleet-conf.sh" --projects 2>/dev/null)
  ) "
  for t in $("$_AS_BIN/fleet-conf.sh" --retired 2>/dev/null | awk '
      { if ($1 != "") print $1
        if ($2 != "" && $2 != "-") { print $2; b = $2; sub(/^box-/, "", b); if (b != $2) print b } }' | sort -u); do
    case "$live" in
      *" $t "*) as_log "retired-conflict: '$t' is named by a # @retired directive but is a live project/box in fleet.conf — ignored" ;;
      *) out="$out $t" ;;
    esac
  done
  printf '%s' "${out# }"
}

# _as_names_word <line> <name> — rc 0 when <name> appears in <line> as a whole
# word (its neighbours are not [A-Za-z0-9_-]), so `gone` never matches
# `gonebox-staging` and `project-10` never matches `project-10-nav`.
_as_names_word() {
  local n; n=$(printf '%s' "$2" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
  grep -qE -- "(^|[^A-Za-z0-9_-])${n}([^A-Za-z0-9_-]|\$)" 2>/dev/null <<<"$1"
}

alert_state_route() { # alert_state_route <line> <severity>
  local line="$1" sev="$2" re lvl parked box
  [ -n "$sev" ] || sev=$(alert_cfg ALERT_DEFAULT_SEVERITY critical)
  case "$sev" in info|warn|critical) : ;; *) sev=critical ;; esac
  while IFS=$'\t' read -r re lvl; do
    [ -n "$re" ] && [ -n "$lvl" ] || continue
    if grep -qE "$re" 2>/dev/null < <(printf '%s' "$line"); then
      case "$lvl" in info|warn|critical) sev="$lvl"; break ;; esac
    fi
  done < <(_as_rules severity)
  [ "$sev" = info ] && { printf '%s' "$sev"; return 0; }
  # Does this line even claim something is down? A parked box appearing in an
  # unrelated alert must not mute that alert.
  grep -qE "$(alert_cfg ALERT_PARK_DOWNGRADE_RE 'LANE DOWN|AUTH DOWN|LANE SILENT|watcher stale|UNREACHABLE|CANARY FAILED')" 2>/dev/null < <(printf '%s' "$line") \
    || { printf '%s' "$sev"; return 0; }
  parked=""
  # BH-4153: paused-<box> is a harness_flags row; flag_list answers from the DB
  # or its last good list. An unknown answer (rc 2) parks nobody: the
  # fail-open direction, nothing is muted. No client: the files, as before.
  if command -v flag_list >/dev/null 2>&1; then
    for box in $(flag_list paused- 2>/dev/null); do parked="$parked ${box#paused-}"; done
  else
    for box in "$_AS_H"/flags/paused-*; do
      [ -e "$box" ] || continue
      parked="$parked ${box##*/paused-}"
    done
  fi
  [ -r "$_AS_CONF" ] && parked="$parked $(awk '$1=="parked" {print $2}' "$_AS_CONF" 2>/dev/null | tr '\n' ' ')"
  # RETIRED IN THE REGISTRY (V1 alert hygiene). fleet.conf's `# @retired
  # <project> [box]` directives are the fleet-wide statement that a project and
  # its box are gone; a box that nobody remembered to touch a flag or a conf line
  # on must not page forever about being down. Same downgrade, same guard.
  # Retired names match WHOLE WORDS only and never a live project/box (see
  # alert_state_retired_tokens); the paused/parked names keep their old reading.
  for box in $parked; do
    [ -n "$box" ] || continue
    if grep -qF -- "$box" 2>/dev/null <<<"$line"; then
      printf 'info'; return 0
    fi
  done
  for box in $(alert_state_retired_tokens); do
    _as_names_word "$line" "$box" && { printf 'info'; return 0; }
  done
  printf '%s' "$sev"
}

# ── THE STATE ───────────────────────────────────────────────────────────────
# _as_db_write_file <file> <decision> <count> <severity> <line> — the
# write-through cache of a row the worker just decided. Same keys today's
# readers expect, so nothing downstream has to know where the decision came
# from. The wrapper prints only "<decision> <count>", so the timestamps are
# derived from the DECISION: a `fire` is the start of an incident, a `remind`
# is a send, a `suppress` changes neither. Best-effort in every direction — a
# file we could not write costs an audit line, never a page.
_as_db_write_file() { # _as_db_write_file <file> <decision> <count> <sev> <line>
  local f="$1" dec="$2" cnt="$3" sev="$4" line="$5" now
  now=$(date -u +%s)
  ( exec 7>"$f.lock" 2>/dev/null || exit 0
    flock -w 5 7 2>/dev/null || exit 0
    local first=0 notify=0
    if [ -s "$f" ]; then
      IFS=$'\t' read -r first notify < <(
        jq -r '[(.first_seen//0),(.last_notified//0)]|@tsv' "$f" 2>/dev/null)
    fi
    case "$first" in ''|*[!0-9]*) first=0 ;; esac
    case "$notify" in ''|*[!0-9]*) notify=0 ;; esac
    case "$dec" in
      fire)   first="$now"; notify="$now" ;;
      remind) notify="$now"; [ "$first" -eq 0 ] && first="$now" ;;
      *)      [ "$first" -eq 0 ] && first="$now"; [ "$notify" -eq 0 ] && notify="$now" ;;
    esac
    jq -nc --argjson f "$first" --argjson l "$now" --argjson n "$notify" \
       --argjson c "$cnt" --arg s "$sev" --arg t "$line" \
       '{first_seen:$f,last_seen:$l,last_notified:$n,count:$c,severity:$s,resolved_at:null,line:$t}' \
       > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null ) 2>/dev/null
  return 0
}

# alert_state_note <id> <severity> [line] [project] — prints "<decision>
# <count>" where decision is fire | remind | suppress. Every early return
# prints `fire`.
#
# THE ROW IS THE PRIMARY once flags/alerts-db is on (BH-1070). Two boxes can
# see one condition — a hub lane and the box the condition is about — and a
# per-box json can only ever dedupe the box it lives on. The worker's
# compare-and-swap is the fleet's single decision point; this file becomes its
# write-through cache.
#
# THE REQUEST IS MADE OUTSIDE THE PER-ID FLOCK, on purpose. The serialisation
# that matters is the worker's CAS, and holding a 5s-timeout local lock across
# a network call would make every same-id sibling time out and print `fire 1` —
# a duplicate page manufactured by the dedupe layer itself.
#
# FAIL OPEN, unchanged: rc 1 (outage), rc 2 (route absent / no row) and an
# answer that is not "<fire|remind|suppress> <int>" all fall through to today's
# file logic; rc 9 (another box won the CAS) is a `fire`, never a suppress.
alert_state_note() { # alert_state_note <id> <severity> [line] [project]
  local id="$1" sev="${2:-critical}" line="${3:-}" project="${4:-}" d f
  [ -n "$id" ] || { echo "fire 1"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "fire 1"; return 0; }
  d="$(_as_dir)"; mkdir -p "$d" 2>/dev/null || { echo "fire 1"; return 0; }
  f="$d/$id.json"
  _as_gc
  if alerts_db_on; then
    local family="" out rc dec cnt
    command -v python3 >/dev/null 2>&1 \
      && family=$(python3 "$_AS_BIN/alert_family.py" family "$line" 2>/dev/null)
    out=$(alert_note "$id" "$family" "${JOBS_BOX:-}" "$project" "$sev" \
            "$(as_strip_stamp "$line" | cut -c1-2000)" \
            "$(alert_cfg ALERT_REMINDER_S 21600)" "$(alert_cfg ALERT_AUTO_CLOSE_S 21600)"); rc=$?
    case "$rc" in
      0)
        read -r dec cnt <<<"$out"
        case "${dec:-}" in fire|remind|suppress) ;; *) dec="" ;; esac
        case "${cnt:-}" in ''|*[!0-9]*) dec="" ;; esac
        if [ -n "$dec" ]; then
          _as_db_write_file "$f" "$dec" "$cnt" "$sev" "$line"
          echo "$dec $cnt"; return 0
        fi
        # An answer that is not a decision is not "no repeat" (D11) — it is an
        # answer we cannot read, and the file path is the one that pages.
        as_log "db-miss id=$id rc=parse out=$(printf '%s' "$out" | tr -d '\n' | cut -c1-80)" ;;
      9) as_log "db-race id=$id -> fire"; echo "fire 1"; return 0 ;;
      *) as_log "db-miss id=$id rc=$rc" ;;
    esac
  fi
  ( exec 7>"$f.lock" 2>/dev/null || { echo "fire 1"; exit 0; }
    flock -w 5 7 2>/dev/null || { echo "fire 1"; exit 0; }
    local now first last notify count resolved remind close decision
    now=$(date -u +%s)
    remind=$(alert_cfg ALERT_REMINDER_S 21600)
    close=$(alert_cfg ALERT_AUTO_CLOSE_S 21600)
    first=0; last=0; notify=0; count=0; resolved=0
    if [ -s "$f" ]; then
      IFS=$'\t' read -r first last notify count resolved < <(
        jq -r '[(.first_seen//0),(.last_seen//0),(.last_notified//0),(.count//0),(.resolved_at//0)]|@tsv' "$f" 2>/dev/null)
    fi
    case "$first$last$notify$count$resolved" in *[!0-9]*|'') first=0; last=0; notify=0; count=0; resolved=0 ;; esac
    # A NEW incident when: never seen, explicitly resolved, or gone quiet for
    # longer than the auto-close window. That last case is what keeps a
    # condition nobody ever calls --resolve on from being silenced forever.
    if [ "$first" -eq 0 ] || [ "$resolved" -ne 0 ] || [ $(( now - last )) -ge "$close" ]; then
      first="$now"; count=1; notify="$now"; decision=fire
    else
      count=$(( count + 1 ))
      if [ $(( now - notify )) -ge "$remind" ]; then notify="$now"; decision=remind
      else decision=suppress; fi
    fi
    jq -nc --argjson f "$first" --argjson l "$now" --argjson n "$notify" \
       --argjson c "$count" --arg s "$sev" --arg t "$line" \
       '{first_seen:$f,last_seen:$l,last_notified:$n,count:$c,severity:$s,resolved_at:null,line:$t}' \
       > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    echo "$decision $count" )
}

# alert_state_resolve <id> — prints "resolve <count> <severity>" when an OPEN id
# closes, "silent 0 info" otherwise. Resolving something that was never firing is
# itself a page about nothing, which is the failure mode this whole file exists
# to end.
#
# The severity is the one the CONDITION was opened at, not a fresh judgement. A
# retraction belongs on the channel its alert used: a `warn` lane canary that
# recovers must not page when the outage itself only reached the digest — that
# hands the noise back with one sign flipped, which is exactly the shape of the
# ~35 pipeline-health RESOLVED lines a day.
#
# WITH THE ROW ON, the count of rows the worker actually closed is what decides
# (BH-1070): a condition opened on one box and resolved from another has no
# local file to read, and the file-only reading would go silent on exactly the
# cross-box retraction the table exists to carry.
alert_state_resolve() { # alert_state_resolve <id>
  local id="$1" d f
  [ -n "$id" ] || { echo "silent 0 info"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "silent 0 info"; return 0; }
  d="$(_as_dir)"; f="$d/$id.json"
  if alerts_db_on; then
    local n rc count sev now
    n=$(alert_resolve "$id"); rc=$?
    if [ "$rc" -eq 0 ]; then
      case "${n:-}" in ''|*[!0-9]*) as_log "db-miss id=$id rc=parse"; rc=1 ;; esac
    fi
    if [ "$rc" -eq 0 ]; then
      if [ "$n" -ge 1 ]; then
        count=1; sev=critical
        if [ -s "$f" ]; then
          IFS=$'\t' read -r count sev < <(
            jq -r '[(.count//1),(.severity//"critical")]|@tsv' "$f" 2>/dev/null)
          case "${count:-}" in ''|*[!0-9]*) count=1 ;; esac
          case "${sev:-}" in info|warn|critical) ;; *) sev=critical ;; esac
          now=$(date -u +%s)
          ( exec 7>"$f.lock" 2>/dev/null || exit 0
            flock -w 5 7 2>/dev/null || exit 0
            jq --argjson r "$now" '.resolved_at=$r' "$f" > "$f.tmp" 2>/dev/null \
              && mv -f "$f.tmp" "$f" 2>/dev/null ) 2>/dev/null
        fi
        echo "resolve $count $sev"; return 0
      fi
      echo "silent 0 info"; return 0
    fi
    as_log "db-miss id=$id rc=$rc"
  fi
  [ -s "$f" ] || { echo "silent 0 info"; return 0; }
  ( exec 7>"$f.lock" 2>/dev/null || { echo "silent 0 info"; exit 0; }
    flock -w 5 7 2>/dev/null || { echo "silent 0 info"; exit 0; }
    local count resolved first sev now
    IFS=$'\t' read -r count resolved first sev < <(
      jq -r '[(.count//0),(.resolved_at//0),(.first_seen//0),(.severity//"critical")]|@tsv' "$f" 2>/dev/null)
    case "$count$resolved$first" in *[!0-9]*|'') echo "silent 0 info"; exit 0 ;; esac
    [ "$resolved" -ne 0 ] && { echo "silent 0 info"; exit 0; }
    case "$sev" in info|warn|critical) : ;; *) sev=critical ;; esac
    now=$(date -u +%s)
    jq --argjson r "$now" '.resolved_at=$r' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    echo "resolve $count $sev" )
}

# alert_state_age <id> — seconds the condition has been open, "" if unknown.
# Used only to make a resolve line say how long the thing actually lasted.
alert_state_age() { # alert_state_age <id>
  local f; f="$(_as_dir)/$1.json"
  [ -s "$f" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local first; first=$(jq -r '.first_seen//0' "$f" 2>/dev/null)
  case "$first" in ''|*[!0-9]*|0) return 0 ;; esac
  echo $(( $(date -u +%s) - first ))
}

# Closed rows are kept for audit, but not forever: this directory is written to
# every quarter hour by every box. Swept at most hourly so the sweep itself is
# not the cost.
_as_gc() {
  local d stamp now keep
  d="$(_as_dir)"; stamp="$d/.gc"
  now=$(date -u +%s)
  [ -f "$stamp" ] && [ $(( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) )) -lt 3600 ] && return 0
  touch "$stamp" 2>/dev/null
  keep=$(alert_cfg ALERT_STATE_RETENTION_S 604800)
  find "$d" -maxdepth 1 -name '*.json' -type f \
    -mmin +$(( keep / 60 )) -delete 2>/dev/null || true
  find "$d" -maxdepth 1 -name '*.json.lock' -type f -mmin +$(( keep / 60 )) -delete 2>/dev/null || true
  find "$d/alias" -maxdepth 1 -type f -mmin +$(( keep / 60 )) -delete 2>/dev/null || true
}

# ── WARN BATCHING ───────────────────────────────────────────────────────────
# A warn does not page on its own; it waits for the digest cadence and arrives
# as one message with everything else that happened. The spool is a jsonl of
# "<epoch>\t<payload>", exactly the shape state/alert-quarantine.jsonl uses, so
# the same flock discipline and the same readers' habits apply.
_as_warn_file() { printf '%s' "${ALERT_WARN_BATCH:-$_AS_H/state/alert-warn-batch.jsonl}"; }

# alert_state_batch_warn <payload> — spool it, and NEVER let it rot there.
# Every box drains its own spool every 30 min (cron/lanes/665-alert-warn-flush.cron),
# but a box whose crontab has not picked that line up yet still must not sit on
# a warn, so the spool carries its own dead-man: once its oldest entry is older than ALERT_WARN_BATCH_MAX_AGE_S
# the next warn flushes the batch inline. Nothing waits silently.
alert_state_batch_warn() { # alert_state_batch_warn <payload>
  local f max oldest now age
  f="$(_as_warn_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  max=$(alert_cfg ALERT_WARN_BATCH_MAX 60)
  ( exec 7>"$f.lock" 2>/dev/null || exit 1
    flock -w 5 7 2>/dev/null || exit 1
    printf '%s\t%s\n' "$(date -u +%s)" "$1" >> "$f"
    # Oldest-first trim: a spool that grows without bound is a digest that
    # eventually cannot be sent at all.
    if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt "$max" ]; then
      tail -n "$max" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    fi ) 2>/dev/null || return 1
  age=$(alert_cfg ALERT_WARN_BATCH_MAX_AGE_S 5400)
  oldest=$(head -1 "$f" 2>/dev/null | cut -f1)
  case "$oldest" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date -u +%s)
  [ $(( now - oldest )) -ge "$age" ] || return 0
  [ -x "$_AS_BIN/alert-digest.sh" ] || return 0
  timeout 60 "$_AS_BIN/alert-digest.sh" --warn-batch >/dev/null 2>&1 || true
}
