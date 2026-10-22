#!/bin/bash
# alert-writer: by-design — its lines report a coordination-DB outage; the helper notes rows through this client
# jobs-client.sh — thin, FAIL-OPEN client for the harness-jobs coordination DB.
# Spec: docs/DB-COORDINATION-SPEC.md (phase 1). Worker: worker/jobs/.
#
# Source it (`. "$HARNESS/bin/jobs-client.sh"`) for job_open / job_update /
# job_event / job_cap / job_ledger_get / job_ledger_put, or run it directly
# for the same verbs plus catalog-sync / catalog-probe.
#
# THE ONE RULE HERE IS FAIL-OPEN. Every helper returns nonzero and prints
# nothing when the API is unreachable, unauthed, slow or wrong; callers keep
# today's file behavior byte for byte. A coordination database that can block a
# build is worse than no coordination database — the failure mode this layer
# exists to remove (a build that cannot run because a config did not land) must
# not be reintroduced by the fix. Outages leave one line in logs/jobs-client.log
# and, once a day, one line in ALERTS.log; never a nonzero exit into a pipeline.
set -uo pipefail

JOBS_HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; _JC_ENV=$(harness_env_dir "$JOBS_HARNESS")
# THE SECRET COMES WITH THE LIBRARY (2026-09-11). Every lane that sources this
# file needs HARNESS_SECRET, and a cron-launched script that never sourced
# env/global.env got a silent empty answer from every call: bin/fly-dispatch.sh
# pulled zero queued rows for six hours while nine builds sat in the ledger
# (project-2 TK-233 from 00:54Z, project-4 x4, project-3, project-5 x3). The daily
# "HARNESS_SECRET unset" line fired once and drowned. So when the secret is not
# in the environment, read it from the harness env file here, at the one place
# every caller passes through — never overriding a value the caller already set.
if [ -z "${HARNESS_SECRET:-}" ] && [ -r "$_JC_ENV/global.env" ]; then
  HARNESS_SECRET=$(sed -n 's/^HARNESS_SECRET=//p' "$_JC_ENV/global.env" | head -1 | tr -d '"'"'"' ')
  [ -n "$HARNESS_SECRET" ] && export HARNESS_SECRET
  _JC_URL=$(sed -n 's/^JOBS_URL=//p' "$_JC_ENV/global.env" | head -1 | tr -d '"'"'"' ')
  [ -z "${JOBS_URL:-}" ] && [ -n "$_JC_URL" ] && JOBS_URL="$_JC_URL"
  # A `JOBS_URL=` line with NO value is an answer too (BH-1957): "not
  # configured". Adopted only when the caller never set JOBS_URL, so it cannot
  # fall through to the legacy default in bin/lib/jobs/req.sh.
  [ -z "${JOBS_URL+set}" ] && grep -q '^JOBS_URL=' "$_JC_ENV/global.env" && JOBS_URL="$_JC_URL"
  unset _JC_URL
fi
# BH-7188 (TOC lever 5a): OFF THE HUB. A lead/human verdict posts from any
# trusted machine, not only the box that owns env/global.env. With no secret from
# the environment or global.env, read it from the macOS keychain item
# `cromford` / HARNESS_SECRET, then from a file named by HARNESS_SECRET_FILE
# (refused unless mode 0600). The worker URL has the same keychain home, account
# JOBS_URL, and only when JOBS_URL is UNSET (an empty value stays "no worker").
# A secret found here is NOT exported and rides to curl in a 0600 header file
# (JOBS_AUTH_VIA_FILE=1, bin/lib/jobs/req.sh), never on argv. The hub path above
# is unchanged byte for byte.
# Inline on purpose: this shim defines no functions (jobs-client-modules, BH-1194).
if [ -z "${HARNESS_SECRET:-}" ]; then
  _JC_S=""
  if command -v security >/dev/null 2>&1; then
    _JC_S=$(security find-generic-password -s cromford -a HARNESS_SECRET -w 2>/dev/null) || _JC_S=""
  fi
  if [ -z "$_JC_S" ] && [ -n "${HARNESS_SECRET_FILE:-}" ] && [ -r "$HARNESS_SECRET_FILE" ]; then
    _JC_M=$(stat -c %a "$HARNESS_SECRET_FILE" 2>/dev/null || stat -f %Lp "$HARNESS_SECRET_FILE" 2>/dev/null)
    if [ "$_JC_M" = 600 ]; then _JC_S=$(head -1 "$HARNESS_SECRET_FILE" | tr -d ' \r\n'); fi
    unset _JC_M
  fi
  if [ -n "$_JC_S" ]; then
    HARNESS_SECRET="$_JC_S"; JOBS_AUTH_VIA_FILE=1
  else
    unset HARNESS_SECRET
  fi
  unset _JC_S
fi
if [ -z "${JOBS_URL+set}" ] && command -v security >/dev/null 2>&1; then
  _JC_URL=$(security find-generic-password -s cromford -a JOBS_URL -w 2>/dev/null) || _JC_URL=""
  if [ -n "$_JC_URL" ]; then JOBS_URL="$_JC_URL"; fi
  unset _JC_URL
fi
# >>> jobs modules
# BH-1194: the client is a SHIM over bin/lib/jobs/. Everything below the
# bootstrap above lives in one of the nine modules named on the literal line
# below — the list is the single source of truth for what a copy of this file
# needs beside it, and the suites read it off this line, so it stays a literal.
#
# Modules resolve off BASH_SOURCE, not off $HARNESS, because this file is copied
# standalone into scratch harnesses by ~100 fixture suites and must find its own
# modules wherever it was put. A module that is not there is a box whose bin/
# arrived in two pieces (or a fixture that copied the client and not the
# modules): the client refuses to half-load rather than leave a lane holding a
# client with a hole in it, because a missing verb here surfaces as rc 127
# inside somebody else's `2>/dev/null` subshell and reads exactly like the
# degraded mode this file is designed to have.
JC_MODULES="req queue flags settings lanes cost jobs machines alerts boxes conductor routing split-watchdog hub-probe dequeue-watch utilization"
JC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/jobs"
for _jc_m in $JC_MODULES; do
  [ -r "$JC_LIB_DIR/$_jc_m.sh" ] || {
    mkdir -p "$JOBS_HARNESS/logs" 2>/dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [jobs-client] missing module $JC_LIB_DIR/$_jc_m.sh on $(hostname 2>/dev/null) — this copy of bin/jobs-client.sh has no bin/lib/jobs/ beside it (a half-synced bin/, or a fixture that copied the client without copying bin/lib/jobs/*.sh)" \
      >> "$JOBS_HARNESS/logs/ALERTS.log" 2>/dev/null
    echo "jobs-client: missing module $JC_LIB_DIR/$_jc_m.sh — copy bin/lib/jobs/*.sh next to bin/jobs-client.sh (a fixture that copies the client must copy the modules too)" >&2
    exit 1; }
  # shellcheck source=/dev/null
  . "$JC_LIB_DIR/$_jc_m.sh" || {
    echo "jobs-client: module $JC_LIB_DIR/$_jc_m.sh did not load — refusing to run with half a client" >&2
    exit 1; }
done
unset _jc_m
# <<< jobs modules

# Direct invocation: same verbs, for hot-deploy hooks and by-hand checks.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # shellcheck source=/dev/null
  [ -f "$_JC_ENV/global.env" ] && { set -a; . "$_JC_ENV/global.env"; set +a; }
  # BH-7456: a NEW verb is a fragment, never a new arm below (catalog/list-files.tsv).
  # bin/jobs-client.d/<ticket-key>-<verb>.sh: its `#: <verb> <args>` line(s) at
  # column 0 and one function jc_verb_<verb, - as _>. Read only for a verb no arm takes.
  JC_FRAG_DIR="${JC_LIB_DIR%/lib/jobs}/jobs-client.d"
  _jc_frags() { [ -d "$JC_FRAG_DIR" ] || return 0; find "$JC_FRAG_DIR" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort; }
  # The usage line: the `    #: ` lines inside `case "$CMD" in`, in arm order,
  # then each fragment's `#: ` lines, in fragment file-name order.
  _jc_usage() {
    local f
    printf 'usage: jobs-client.sh {%s}\n' "$( { awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit} f&&sub(/^    #: /,""){print}' "${BASH_SOURCE[0]}"
      while IFS= read -r f; do [ -n "$f" ] && sed -n 's/^#: //p' "$f"; done < <(_jc_frags); } | sed '/^$/d' | paste -sd'|')"
  }
  # WHICH SOURCE ANSWERED (BH-2643). flag-active answers through flag_active,
  # which decides from the pause_flags row and falls back to the flags/ file
  # only when there is no row to read (BH-5004). On 2026-09-26 the hub read
  # rc=1 from a file its own flag-set had removed while the row it failed to
  # write stayed active for 70 more minutes. One stderr line says which source
  # this answer is, read from flag_active's own _FLAG_SRC and cached row (no
  # second request); stdout and rc are exactly flag_active's.
  _flag_cli_source() { # _flag_cli_source <name>
    local name="$1"
    case "${_FLAG_SRC:-unreadable}" in
      file-newer)
        echo "flag-active $name: source: flags/$name file, newer than the row (active=0, updated_at ${_FLAG_ROW_UPD:-?}); builders claim against the row and are NOT paused" ;;
      row)
        echo "flag-active $name: source: pause_flags row (active=${_FLAG_ROW_ACTIVE:-?}, updated_at ${_FLAG_ROW_UPD:-?})" ;;
      no-row) echo "flag-active $name: source: flags/$name file ONLY: there is no pause_flags row (rc 2); builders claim against the row, so this answer is not theirs" ;;
      *) echo "flag-active $name: source: flags/$name file ONLY: the pause_flags row could not be read (rc ${_FLAG_ROW_RC:-1}); builders claim against the row, so this answer is not theirs" ;;
    esac >&2
  }
  # BH-4153: the same line for a ported name, read from the row path.
  _flag_cli_source_row() { # _flag_cli_source_row <name> <answer-rc>
    local name="$1" ans="$2" scope cur age
    scope=$(_flag_default_scope "$name" 2>/dev/null) || scope="?"
    cur=$(_flag_cache_read "$scope" "$name" 2>/dev/null)
    case "${FLAG_SRC:-unknown}" in
      db)    echo "flag-active $name: source: harness_flags row (scope $scope, set_at $(jq -r '.set_at // "-"' <<<"$cur"), cleared_at $(jq -r '.cleared_at // "-"' <<<"$cur"))" ;;
      cache) age=$(( $(date -u +%s) - $(jq -r '.stamp // 0' <<<"$cur") ))
             echo "flag-active $name: source: cache (age ${age}s): the worker did not answer; this is the last good row, not the current one" ;;
      local) echo "flag-active $name: source: local hold (written on this box while the worker was unreachable, or a flags/$name file not imported yet)" ;;
      *)     if [ "$ans" = 0 ]; then echo "flag-active $name: source: unknown → read as ON (the worker did not answer and nothing is cached; a stop switch fails closed)"
             else echo "flag-active $name: source: unknown (the worker did not answer and nothing is cached)"; fi ;;
    esac >&2
  }
  CMD="${1:-}"; shift || true
  # Each verb's rc is the SCRIPT's rc — a trailing echo must not launder a
  # failed call into exit 0 (harness-sync's catalog sha-state relies on this).
  # The `#:` line above each arm IS the usage: _jc_usage joins them. A new verb
  # is a fragment file in bin/jobs-client.d/ (BH-7456), not a new arm here.
  case "$CMD" in
    #: open <project> <ticket> <kind> <stage> [lane] [meta]
    open)          job_open "$@"; RC=$?; echo ;;
    #: update <id> k=v...
    update)        job_update "$@"; RC=$? ;;
    #: event <id> <stage> [verdict] [detail]
    event)         job_event "$@"; RC=$? ;;
    #: cap <lane>
    cap)           job_cap "$@"; RC=$?; echo ;;
    #: catalog-sync [file]
    catalog-sync)  catalog_sync "$@"; RC=$?; echo ;;
    #: catalog-probe [file]
    catalog-probe) catalog_probe "$@"; RC=$? ;;
    #: ledger-get <kind> <key>
    ledger-get)    job_ledger_get "$@"; RC=$?; echo ;;
    #: ledger-put <kind> <key> <status> [detail]
    ledger-put)    job_ledger_put "$@"; RC=$? ;;
    #: heartbeat <id> [note]
    heartbeat)     job_heartbeat "$@"; RC=$? ;;
    #: phase-open <phase> [runner] [model] [note] [job-id]
    phase-open)    job_phase_open "$@"; RC=$?; echo "$JOB_PHASE_ID" ;;
    #: phase-close [rc] [spend] [note] [phase-id]
    phase-close)   job_phase_close "$@"; RC=$? ;;
    #: phase-close-open <job-id> <status> [rc] [note]
    phase-close-open) job_phase_close_open "$@"; RC=$?; echo ;;
    #: stale <minutes>
    stale)         job_stale "$@"; RC=$? ;;
    #: retry-judge <job-id> [detail]
    retry-judge)   job_retry_judge "$@"; RC=$? ;;
    #: rules
    rules)         job_rules "$@"; RC=$? ;;
    #: rule-set <scope> <selector> <kind> <max> [note]
    rule-set)      job_rule_set "$@"; RC=$? ;;
    #: rule-unset <scope> [selector] [kind]
    rule-unset)    job_rule_unset "$@"; RC=$? ;;
    #: retry-policy <lane>
    retry-policy)  job_retry_policy "$@"; RC=$? ;;
    #: retry-policy-set <lane> <max-attempts> [backoff-s] [escalate 0|1] [note]
    retry-policy-set) job_retry_policy_set "$@"; RC=$? ;;
    #: artifact-put <kind> <ref> [detail] [job-id]
    artifact-put)  job_artifact_put "$@"; RC=$? ;;
    #: result-put <job-id> <facts-json>
    result-put)    job_result_put "$@"; RC=$? ;;
    #: evidence-put <build-dir> [tier] [note] [job-id]
    evidence-put)  job_evidence_put "$@"; RC=$? ;;
    #: artifacts [job-id]
    artifacts)     job_artifacts "$@"; RC=$? ;;
    #: transcript-put <body-file> [stage] [runner] [model] [source] [attempt] [truncated] [redactions] [job-id]
    transcript-put) job_transcript_put "$@"; RC=$? ;;
    #: transcripts [job-id]
    transcripts)   job_transcripts "$@"; RC=$? ;;
    #: transcript-get <job-id> [phase-id] [attempt]
    #: transcript-get <job-id> source=<plan_md|review_md|decompose_run>
    transcript-get)
                   case "${2:-}" in
                     source=*) job_transcript_get_source "${1:-}" "${2#source=}" ;;
                     *)        job_transcript_get "$@" ;;
                   esac; RC=$? ;;
    #: verdict <pr-url>
    verdict)       job_verdict "$@"; RC=$? ;;
    #: verdict-headbound <pr-url>
    verdict-headbound) job_verdict_headbound "$@"; RC=$? ;;
    #: verdict-rebind <pr-url> <sha>
    verdict-rebind) job_verdict_rebind "$@"; RC=$? ;;
    #: verdict-history <pr-url>
    verdict-history) job_verdict_history "$@"; RC=$? ;;
    #: ledger-list <kind> [limit]
    ledger-list)   job_ledger_list "$@"; RC=$? ;;
    #: pr-facts <pr-url>
    pr-facts)      job_pr_facts "$@"; RC=$?; echo ;;
    #: contracts
    contracts)     job_contracts "$@"; RC=$? ;;
    #: contract-set <phase> <artifact-kind> [pattern] [note]
    contract-set)  job_contract_set "$@"; RC=$? ;;
    #: cap-row <lane>
    cap-row)       job_cap_row "$@"; RC=$?; echo ;;
    #: cap-explicit <lane> 0|1 [reason]
    cap-explicit)  job_cap_explicit "$@"; RC=$? ;;
    #: metric-burn <day> <calls> <in> <out> <cr> <cw> <usd> <peak> <avg>
    metric-burn)   metric_burn "$@"; RC=$? ;;
    #: metric-pr-costs <csv>
    metric-pr-costs) metric_pr_costs "$@"; RC=$? ;;
    #: metric-cost-rows <csv> <cursor-file> [box]
    metric-cost-rows) metric_cost_rows "$@"; RC=$? ;;
    #: model-prices-put <prices-json> [source]
    model-prices-put) model_prices_put "$@"; RC=$? ;;
    #: model-prices-get <out-file>
    model-prices-get) model_prices_get "$@"; RC=$? ;;
    #: model-price-source <model> <vendor-direct|openrouter> [prompt completion [cache_read cache_write cliff]]
    model-price-source) model_price_source_set "$@"; RC=$? ;;
    #: metric-extra-usage <box> <ts> <sess> <week> <resets> <enabled> <usd> <slr> <overage> [limit] [pct] [status]
    metric-extra-usage) metric_extra_usage "$@"; RC=$? ;;
    #: metric-vendor-spend <vendor> <ts> <win-start> <win-end> <usd> <kind> <status> <balance> <cumulative> <note> [raw]
    metric-vendor-spend)  metric_vendor_spend "$@"; RC=$? ;;
    #: metric-vendor-spends [vendor] [since] [limit]
    metric-vendor-spends) metric_vendor_spend_list "$@"; RC=$? ;;
    #: metric-outcome <repo> <pr> <outcome> <day> <evidence> [repairs]
    metric-outcome) metric_outcomes "$@"; RC=$? ;;
    #: metric-cli-version <box> <cli> <before> <after> <method> <ok> <at> [path] [note] [source]
    metric-cli-version) metric_cli_version "$@"; RC=$? ;;
    #: metric-cli-versions <rows-json-file>
    metric-cli-versions) metric_cli_versions "$@"; RC=$? ;;
    #: metric-cli-versions-list [limit] [box]
    metric-cli-versions-list) metric_cli_versions_list "$@"; RC=$? ;;
    #: metric-outcomes [limit]
    metric-outcomes) metric_outcomes_list "$@"; RC=$? ;;
    #: metric-flake <repo> <workflow> <test> <head> [day] [flake|red]
    metric-flake) metric_flake "$@"; RC=$? ;;
    #: metric-flakes [limit] [repo] [since]
    metric-flakes) metric_flakes_list "$@"; RC=$? ;;
    #: review-gate
    review-gate)          review_gate_list "$@"; RC=$? ;;
    #: review-gate-put <repo> <0|1> <rate> <bad> <merges> <window> <tighten-rate> <clear-rate> <min-merges> <scope> <decision> <evidence>
    review-gate-put)      review_gate_put "$@"; RC=$? ;;
    #: review-gate-thresholds <repo>
    review-gate-thresholds) review_gate_thresholds "$@"; RC=$?; echo ;;
    #: review-gate-threshold-set <scope> <window-days> <min-merges> <tighten-rate> <clear-rate> [note]
    review-gate-threshold-set) review_gate_threshold_set "$@"; RC=$? ;;
    #: review-tighten-active <repo>
    review-tighten-active) review_tighten_active "$@"; RC=$? ;;
    #: review-tighten-set <repo> on|off [reason]
    review-tighten-set)    review_tighten_set "$@"; RC=$? ;;
    #: setting-get <key>
    setting-get)   setting_get "$@"; RC=$?; echo ;;
    #: setting-set <key> <value> [note]
    setting-set)   setting_set "$@"; RC=$? ;;
    #: artifact-feed <kind> <project> [since] [limit]
    artifact-feed) job_artifact_feed "$@"; RC=$? ;;
    #: queue-put <project> <key> [ticket-id] [target local|fly, default: project routing] [attempt] [meta]
    queue-put)     queue_put "$@"; RC=$?; echo ;;
    #: deploy-put <project> <sha> [build-dir]
    deploy-put)    deploy_queue_put "$@"; RC=$?; echo ;;
    #: deploy-list [project] [status] [stale-min]
    deploy-list)   deploy_queue_list "$@"; RC=$? ;;
    #: deploy-claim <project> <sha> [stale-min]
    deploy-claim)  deploy_queue_claim "$@"; RC=$? ;;
    #: deploy-depart <project> <sha> done|failed|queued [reason]
    deploy-depart) deploy_queue_depart "$@"; RC=$? ;;
    #: mq-put <project> <pr> [repo] [reason]
    mq-put)        merge_queue_put "$@"; RC=$?; echo ;;
    #: mq-list [project] [status]
    mq-list)       merge_queue_list "$@"; RC=$? ;;
    #: mq-set <project> <pr> queued|blocked|landed|dropped [reason]
    mq-set)        merge_queue_set "$@"; RC=$? ;;
    #: mt-put <project> <branch> <creating|open|landed|abandoned> [k=v...]
    mt-put)        merge_train_put "$@"; RC=$?; echo ;;
    #: mt-list [project] [outcome] [limit]
    mt-list)       merge_train_list "$@"; RC=$? ;;
    #: wakes [since] [repo]
    wakes)         wakes_list "$@"; RC=$? ;;
    #: wakes-ack <id>...
    wakes-ack)     wakes_ack "$@"; RC=$? ;;
    #: wakes-summary [hours]
    wakes-summary) wakes_summary "$@"; RC=$? ;;
    #: wakes-prune <days>
    wakes-prune)   wakes_prune "$@"; RC=$? ;;
    #: wake-put <repo> <kind> <key>
    wake-put)      wake_put "$@"; RC=$? ;;
    #: wake-lane-put <repo> <kind> <pr> <dedupe>
    wake-lane-put) wake_lane_put "$@"; RC=$? ;;
    #: queue-list [project] [status] [target]
    queue-list)    queue_list "$@"; RC=$? ;;
    #: queue-claim <project> [target] [key]
    queue-claim)   queue_claim "$@"; RC=$? ;;
    #: queue-status <project> <key>
    queue-status)  queue_status "$@"; RC=$?; echo ;;
    #: queue-row <project> <key>
    queue-row)     queue_row "$@"; RC=$?; echo ;;
    #: queue-stale <minutes>
    queue-stale)   queue_stale "$@"; RC=$? ;;
    #: queue-done <project> <key> [status] [reason]
    queue-done)    queue_done "$@"; RC=$? ;;
    #: queue-release <project> <key> [reason]
    queue-release) queue_release "$@"; RC=$? ;;
    #: ready-put <project> <key> [ticket-id] [line]
    ready-put)     queue_ready_put "$@"; RC=$?; echo ;;
    #: ready-list [project]
    ready-list)    queue_ready_list "$@"; RC=$? ;;
    #: ready-drop <project> <key> [reason]
    ready-drop)    queue_ready_drop "$@"; RC=$? ;;
    #: closeout-aged-put <project> <build-dir> [result-head] [reason]
    closeout-aged-put) closeout_aged_put "$@"; RC=$? ;;
    #: closeout-aged-has <build-dir>
    closeout-aged-has) closeout_aged_has "$@"; RC=$? ;;
    #: preplan-put <project> <key> <plan-dir>
    preplan-put)   preplan_put "$@"; RC=$? ;;
    #: preplan-get <project> <key>
    preplan-get)   preplan_get "$@"; RC=$? ;;
    #: preplan-index <project>
    preplan-index) preplan_index "$@"; RC=$? ;;
    #: lane-tick <project> [kind]
    lane-tick)     lane_tick "$@"; RC=$? ;;
    #: lanes-expect <json-array>
    lanes-expect)  lanes_expect "$@"; RC=$? ;;
    #: lanes
    lanes)         lanes_list "$@"; RC=$? ;;
    #: lane-proc-beat <lane> start|beat|done [pid] [interval_s] [expect_s] [note]
    lane-proc-beat) lane_proc_beat "$@"; RC=$? ;;
    #: lane-procs [stale]
    lane-procs)    lane_procs "$@"; RC=$? ;;
    #: box-backup-set <ts> <off> <unconfigured>
    box-backup-set) box_backup_set "$@"; RC=$? ;;
    #: box-backups
    box-backups)   box_backups "$@"; RC=$? ;;
    #: lane-alert <project> <box> on|off
    lane-alert)    lane_alert_set "$@"; RC=$? ;;
    #: flag-sync <name>
    flag-sync)     flag_sync "$@"; RC=$? ;;
    #: flag-active <name>
    flag-active)   if [ -n "${1:-}" ] && _flag_ported "$1" && _flag_db_configured; then
                     # BH-4153: a harness_flags row; say which source answered.
                     flag_active "$1"; RC=$?; _flag_cli_source_row "$1" "$RC"
                   else
                     # BH-5004: every other name, or no worker configured.
                     flag_active "${1:-}" 2>/dev/null; RC=$?
                     [ -n "${1:-}" ] && _flag_cli_source "$1"
                   fi ;;
    #: flag-has [--scope S] [--cached] <name>
    flag-has)      flag_has "$@"; RC=$?; echo "flag-has: ${FLAG_SRC:-unknown}" >&2 ;;
    #: flag-clear [--scope S] [--local-only] <name> [reason]
    flag-clear)    flag_clear "$@"; RC=$? ;;
    #: flag-list [--scope S] [--cached] <prefix>
    flag-list)     flag_list "$@"; RC=$? ;;
    #: flag-set <name> on|off [reason]
    flag-set)      flag_set "$@"; RC=$?
                   # The flag name, past any --scope S / --hold-local.
                   _FS_N=""; _FS_SK=0
                   for _a in "$@"; do
                     [ "$_FS_SK" = 1 ] && { _FS_SK=0; continue; }
                     case "$_a" in --scope) _FS_SK=1 ;; --*) ;; *) _FS_N="$_a"; break ;; esac
                   done
                   # Only when the name and state were valid, so the file WAS changed.
                   if [ "$RC" != 0 ] && [ -n "${1:-}" ] && { ! _flag_ported "$_FS_N" || ! _flag_db_configured; }; then
                     case "$1" in *[!A-Za-z0-9._-]*) ;; *)
                       case "${2:-}" in on|1|true|off|0|false)
                         echo "flag-set $1: the flags/$1 file was changed on this box but the pause_flags row was NOT written; builders still see the old row" >&2 ;;
                       esac ;;
                     esac
                   elif [ "$RC" != 0 ]; then
                     # BH-4153: a ported name writes no file; say what is (not) in force.
                     case " $* " in
                       *" --hold-local "*) echo "flag-set $_FS_N: the harness_flags row was NOT written; it is held on this box only (a local hold) until a row is written" >&2 ;;
                       *) echo "flag-set $_FS_N: the harness_flags row was NOT written; nothing changed" >&2 ;;
                     esac
                   fi ;;
    #: pr-owners-put <repo> <project> <state-json-file>
    pr-owners-put) pr_owners_put "$@"; RC=$? ;;
    #: pr-owners-list <repo>
    pr-owners-list) pr_owners_list "$@"; RC=$?; echo ;;
    #: decisions-put <project> <rows-json-file>
    decisions-put) decisions_put "$@"; RC=$? ;;
    #: findings-put <project> <rows-json-file>
    findings-put)  findings_put "$@"; RC=$? ;;
    #: log-rehydrate <decisions|findings> <file> [days=30] [project]
    log-rehydrate) log_rehydrate "$@"; RC=$? ;;
    #: topics
    topics)        telegram_topics_get "$@"; RC=$?; echo ;;
    #: topic-set <project> <thread_id>
    topic-set)     telegram_topic_set "$@"; RC=$? ;;
    #: topics-sync <file> [max_age_secs=600]
    topics-sync)   telegram_topics_sync "$@"; RC=$? ;;
    #: ledger-page <kind> <limit> [before]
    ledger-page)   ledger_page "$@"; RC=$?; echo ;;
    #: machines-rows-on
    machines-rows-on) machines_rows_on; RC=$? ;;
    #: machine-put <project> <app> <machine-id> <role> [key] [ticket] [auth-account] [image] [state]
    machine-put)     machine_put "$@"; RC=$? ;;
    #: machines-observe <project> <app> <listing-json-file>
    machines-observe) machines_observe "$@"; RC=$? ;;
    #: machine-close <project> <app> <machine-id> <state> [detail]
    machine-close)   machine_close "$@"; RC=$? ;;
    #: machines-list [project] [live]
    machines-list)   machines_list "$@"; RC=$? ;;
    #: routing-rows-on
    routing-rows-on) routing_rows_on; RC=$? ;;
    #: routing-get <project>
    routing-get)     routing_get "$@"; RC=$? ;;
    #: routing-sync <project>
    routing-sync)    routing_sync "$@"; RC=$? ;;
    #: routing-sync-all
    routing-sync-all) routing_sync_all; RC=$? ;;
    #: routing-set <project> <local|fly1|pool> [pool-app] [halted 0|1] [actor] [reason]
    routing-set)     routing_set "$@"; RC=$? ;;
    #: routing-list
    routing-list)    routing_list; RC=$? ;;
    #: routing-builder <project>
    routing-builder) routing_builder "$@"; RC=$? ;;
    #: routing-pool-app <project>
    routing-pool-app) routing_pool_app "$@"; RC=$? ;;
    #: routing-halted <project>
    routing-halted)  routing_halted "$@"; RC=$? ;;
    #: route-rules
    route-rules)     route_rules_list; RC=$?; echo ;;
    #: route-rule-put <json-file>
    route-rule-put)  route_rule_put "$@"; RC=$?; echo ;;
    #: route-shadow [since] [project] [limit]
    route-shadow)    route_shadow_list "$@"; RC=$?; echo ;;
    #: route-shadow-bounce <project> [rule] [days]
    route-shadow-bounce) route_shadow_bounce "$@"; RC=$?; echo ;;
    #: triage-state-get <project> <key>
    triage-state-get)  triage_state_get "$@"; RC=$?; echo ;;
    #: triage-state-list <project> [due] [limit]
    triage-state-list) triage_state_list "$@"; RC=$?; echo ;;
    #: triage-state-put <json-file>
    triage-state-put)  triage_state_put "$@"; RC=$?; echo ;;
    #: alert-note <id> <family> <box> <project> <severity> <line> [reminder_s] [close_s] [state]
    alert-note)    alert_note "$@"; RC=$? ;;
    #: alert-state <id> <state> [actor]
    alert-state)   alert_state_set "$@"; RC=$? ;;
    #: alert-resolve <id>...
    alert-resolve) alert_resolve "$@"; RC=$? ;;
    #: alert-claim <lane> <state> [min_age_s] [limit] [id...]
    alert-claim)   alert_claim "$@"; RC=$? ;;
    #: alert-flush [box]
    alert-flush)   alert_flush_claim "$@"; RC=$? ;;
    #: alerts [--state s] [--family f] [--box b] [--older-than s] [--since s] [--limit n]
    alerts)        alerts_list "$@"; RC=$? ;;
    #: alert-families <lane> <claimed_since_s>
    alert-families) alert_families "$@"; RC=$? ;;
    #: conductor-mode-publish <mode> <held-summary>
    conductor-mode-publish) conductor_mode_publish "$@"; RC=$? ;;
    #: held-page-put <repo> <num> <state> <head> <kind> <text> <mark> <mode>
    held-page-put)     held_page_put "$@"; RC=$? ;;
    #: held-pages-list [limit]
    held-pages-list)   held_pages_list "$@"; RC=$? ;;
    #: held-page-release <repo> <num> <state> <head> <kind> <why>
    held-page-release) held_page_release "$@"; RC=$? ;;
    #: call-guard [project] [stage] [hours]
    call-guard)    call_guard_list "$@"; RC=$?; echo ;;
    #: call-guard-reset <project> <stage> <fp> [reason]
    call-guard-reset) call_guard_reset "$@"; RC=$?; echo ;;
    *)  # A verb no arm takes: a fragment's jc_verb_<verb>, else the usage.
        if [[ $CMD =~ ^[a-z][a-z0-9-]*$ ]]; then
          while IFS= read -r _jc_f; do
            # shellcheck source=/dev/null
            [ -n "$_jc_f" ] && { . "$_jc_f" 2>/dev/null || echo "jobs-client: fragment $_jc_f did not load" >&2; }
          done < <(_jc_frags)
        fi
        if [[ $CMD =~ ^[a-z][a-z0-9-]*$ ]] && declare -F "jc_verb_${CMD//-/_}" >/dev/null; then
          "jc_verb_${CMD//-/_}" "$@"; RC=$?
        else _jc_usage >&2; exit 2; fi ;;
  esac
  exit "$RC"
fi
