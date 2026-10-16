#!/bin/bash
# Console alerts groomer — HUB cron every 2h. Resolves alerts whose subject is
# verifiably settled so the Alerts screen only shows live problems.
# FAILS SOFT until the console worker ships /api/alerts/open + /api/alerts/resolve
# (spec: docs/ALERTS-GROOMING-SPEC.md in cromford).
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-alerts-groom
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off alerts-groom.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alerts-groom
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alerts-groom
# >>> alert-flag groom (BH-1954)
# flags/alerted-*-YYYYMMDD are once-a-day dedupe markers (bin/internal-token-for.sh
# alone adds one per project per day). A producer only ever checks TODAY's name,
# so an old one dedupes nothing and just piles up. Kept ALERT_FLAG_RETENTION_DAYS
# days (settings row lane.alerts-groom.alert_flag_retention_days; code fallback 7
# when unset), judged by the date in the NAME, never the mtime. A value below 2
# or not a whole number deletes nothing (reject, never clamp a destructive knob),
# so today's and yesterday's flag always survive. Local filesystem work: it runs
# before, and does not depend on, the console env below.
# The same knob and cutoff also groom three dated box flag families (BH-5934),
# each written once a day and checked only by today's name: degraded-<box>-<day>
# and authprobe-inconclusive-<box>-<day> (bin/claude-auth-check.sh), dated by the
# last segment, and lane-caps-degraded-<lane>-<day>-<cksum> (bin/lib/lane-caps.sh),
# dated by the segment BEFORE an all-digit cksum. One loop and one rm serve all
# four families (the BH-4154 flags/ writer ratchet counts each rm); the box
# families get their own log line and count.
groom_alert_flags() {
  local days="${ALERT_FLAG_RETENTION_DAYS-7}" cutoff f d n=0 m=0
  local glog="$HARNESS/logs/alerts-groom.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$((10#$days))" -lt 2 ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') flag groom skipped: ALERT_FLAG_RETENTION_DAYS=$days is not a whole number >= 2" >> "$glog"
    return 0
  fi
  days=$((10#$days))
  cutoff=$(date -u -d "-${days} days" +%Y%m%d 2>/dev/null || date -u -v-"${days}"d +%Y%m%d 2>/dev/null)
  if ! [[ "$cutoff" =~ ^[0-9]{8}$ ]]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') flag groom skipped: could not compute the cutoff date" >> "$glog"
    return 0
  fi
  for f in "$HARNESS"/flags/alerted-* "$HARNESS"/flags/degraded-* "$HARNESS"/flags/authprobe-inconclusive-* "$HARNESS"/flags/lane-caps-degraded-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "${f##*/}" in
      lane-caps-degraded-*) [[ "${f##*-}" =~ ^[0-9]+$ ]] || continue; d="${f%-*}"; d="${d##*-}" ;;
      *) d="${f##*-}" ;;
    esac
    [[ "$d" =~ ^[0-9]{8}$ ]] || continue
    [ "$d" -lt "$cutoff" ] || continue
    rm -f "$f" || continue
    case "${f##*/}" in alerted-*) n=$((n+1)) ;; *) m=$((m+1)) ;; esac
  done
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') flag groom: removed $n alerted-* flag(s) dated before $cutoff (retention ${days}d)" >> "$glog"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') flag groom: removed $m dated box flag(s) (degraded-, authprobe-inconclusive-, lane-caps-degraded-) dated before $cutoff (retention ${days}d)" >> "$glog"
}
groom_alert_flags
# <<< alert-flag groom
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
exec 9>"$HARNESS/locks/alerts-groom.lock"; flock -n 9 || exit 0
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip alerts-groom fleet && exit 0
# <<< wake backstop
LOG="$HARNESS/logs/alerts-groom.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# >>> alerts db resolve (BH-1071)
# The console row and the table row are two records of one condition, so a
# settle closes both. The console POST stays FIRST and unchanged; the table is
# a second, best-effort write whose failure is declared rather than absorbed.
ALERTS_DB=0
# shellcheck source=bin/lib/alert-state.sh
[ -r "$HARNESS/bin/lib/alert-state.sh" ] && . "$HARNESS/bin/lib/alert-state.sh" 2>/dev/null
declare -F alerts_db_on >/dev/null 2>&1 && alerts_db_on && ALERTS_DB=1
ROW_IDS=()
# <<< alerts db resolve
# >>> component stamp (BH-6971)
# Every open alerts row gets the component that owns it: catalog/components.tsv
# through bin/component-of.sh, or `unowned`. The read is `component IS NULL`, so
# a stamped row is never read again, which is why `unowned` is stamped too.
# ALERTS_GROOM_COMPONENT_MAX rows a tick (lane knob, 0 = off). It labels and
# never acts, and it never exits: one log line, then the console half runs.
groom_component_stamp() {
  local max="${ALERTS_GROOM_COMPONENT_MAX:-200}" rows rc trunc="" pairs map errf read stamped unowned
  [ "$ALERTS_DB" = 1 ] || return 0
  if ! [[ "$max" =~ ^[0-9]+$ ]]; then
    echo "$(STAMP) component stamp skipped: ALERTS_GROOM_COMPONENT_MAX=$max is not a whole number" >> "$LOG"
    return 0
  fi
  max=$((10#$max))
  [ "$max" -ge 1 ] || return 0
  if [ ! -x "$HARNESS/bin/component-of.sh" ]; then
    echo "$(STAMP) component stamp skipped: bin/component-of.sh is not on this box" >> "$LOG"
    return 0
  fi
  rows=$(alerts_list --state '!resolved' --unstamped --limit "$max"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(STAMP) component stamp: rc=$rc (list), stamped 0" >> "$LOG"
    return 0
  fi
  grep -qx '#truncated' <<<"$rows" && trunc=" truncated"
  # id is field 1 and the line is field 13 on (an embedded tab becomes a space).
  pairs=$(grep -vx '#truncated' <<<"$rows" | awk -F'\t' 'NF >= 13 { l = $13; for (i = 14; i <= NF; i++) l = l " " $i; print $1 "\t" l }')
  read=$(grep -c . <<<"$pairs")
  if [ "$read" -eq 0 ]; then
    echo "$(STAMP) component stamp: read 0 stamped 0 unowned 0$trunc" >> "$LOG"
    return 0
  fi
  errf=$(mktemp) || return 0
  map=$("$HARNESS/bin/component-of.sh" --batch <<<"$pairs" 2>"$errf"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(STAMP) component stamp: catalog invalid: $(head -1 "$errf")" >> "$LOG"
    rm -f "$errf"
    return 0
  fi
  rm -f "$errf"
  unowned=$(awk -F'\t' '$2 == "unowned"' <<<"$map" | grep -c .)
  stamped=$(alert_components_stamp <<<"$map"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(STAMP) component stamp: rc=$rc (stamp), stamped ${stamped:-0}" >> "$LOG"
    return 0
  fi
  echo "$(STAMP) component stamp: read $read stamped $stamped unowned $unowned$trunc" >> "$LOG"
}
groom_component_stamp
# <<< component stamp
# BH-2526: rules 2-4 read the coordination DB (lanes rows, job_artifacts, and
# stage_events) instead of ssh-ing to the box that owns the project. Absent lib =
# the helpers are undefined and those rules hold every remote row.
# shellcheck source=bin/lib/groom-db.sh
[ -r "$HARNESS/bin/lib/groom-db.sh" ] && . "$HARNESS/bin/lib/groom-db.sh" 2>/dev/null
# A row held because its box is dead, or because the DB could not answer, is
# counted into the pass summary so that pass never reads like a quiet one.
DEAD_N=0; UNK_N=0
groom_ask() { # groom_ask <helper> <args...> -> GROOM_OUT, "unknown no-lib" when the lib is absent
  GROOM_OUT="unknown no-lib"
  declare -F "$1" >/dev/null 2>&1 && "$@"
  return 0
}
hold_unknown() { # hold_unknown <id> <rule> <line>
  UNK_N=$((UNK_N+1))
  echo "$(STAMP) hold $1 ($2-unknown: ${GROOM_OUT#unknown }): $(head -c 100 <<<"$3")" >> "$LOG"
}
# Refuse on an empty registry: three of the four settle checks below resolve a
# project from the alert line, so without the registry this pass silently grooms
# less and leaves rows open — visible only as an Alerts screen that stops
# shrinking, which is indistinguishable from a busy week.
"$HARNESS/bin/fleet-projects-or-alert.sh" alerts-groom >/dev/null || exit 1

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open") || exit 0
jq -e '.alerts' <<<"$RESP" >/dev/null 2>&1 || exit 0   # endpoint not shipped yet -> quiet

RESOLVE="[]"
# The PR-open subjects rule 1 may settle (V1). Knob: env, flags/alerts.conf, or
# (with the V1 settings-row support) a settings row; the default is the three
# lanes whose alert is about a PR being stuck open.
PR_SUBJECT_RE='Merge queue: #|\[rebase-train\]|\[blocked-resolver\] ESCALATED'
command -v alert_cfg >/dev/null 2>&1 && PR_SUBJECT_RE=$(alert_cfg ALERTS_PR_SUBJECT_RE "$PR_SUBJECT_RE")
# One GitHub answer per PR per pass (V1): several rows name the same PR.
declare -A PR_STATE=()
while IFS=$'\t' read -r ID AKEY LINE; do
  [ -n "$ID" ] || continue
  SETTLED=""

  # 1. References a PR that is now merged/closed?
  # V1 alert hygiene (2026-09-25): the repo part was [a-z-]+, so a row about
  # example-org/project-9 or example-org/project-7 (capitals) or a repo with a dot
  # or digit never matched and never settled. And a merge-queue row keyed
  # mq-<kind>:<project>:<N> whose line carries no URL is resolved through the
  # registry's repo for that project.
  #
  # ONLY A PR-OPEN SUBJECT SETTLES ON THE PR CLOSING (V1, review of #2292). This
  # rule used to resolve ANY row naming a PR once it was MERGED/CLOSED — and a
  # merge is where POST-MERGE PROD QA FAILED / NOT RUN and HOTFIX POST-DEPLOY
  # APPLY FAILED / CLOSE-OUT OWED START. So the row must be about the PR being
  # open: an mq-* akey, or a line matching ALERTS_PR_SUBJECT_RE. Anything else
  # costs no GitHub call and waits for its own check (or the 48h auto-stale).
  PRURL=""
  PRSUBJ=0
  [[ "$AKEY" =~ ^mq- ]] && PRSUBJ=1
  grep -qE "$PR_SUBJECT_RE" <<<"$LINE" && PRSUBJ=1
  [ "$PRSUBJ" = 1 ] && PRURL=$(grep -oiE "github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+" <<<"$LINE" | head -1)
  if [ "$PRSUBJ" = 1 ] && [ -z "$PRURL" ] && [[ "$AKEY" =~ ^mq-[a-z-]+:([a-z0-9-]+):([0-9]+)$ ]]; then
    MQN="${BASH_REMATCH[2]}"
    MQS=$("$HARNESS/bin/fleet-conf.sh" "${BASH_REMATCH[1]}" repo 2>/dev/null)
    [ -n "$MQS" ] && [ "$MQS" != "-" ] && PRURL="github.com/$MQS/pull/$MQN"
  fi
  if [ -n "$PRURL" ]; then
    if [ -z "${PR_STATE[$PRURL]+x}" ]; then
      # #425: alert rows can name different repos, so the row is the repo boundary.
      command -v gh_auth_for_url >/dev/null 2>&1 && gh_auth_for_url "https://$PRURL" || true
      PR_STATE[$PRURL]=$(gh pr view "https://$PRURL" --json state -q .state 2>/dev/null)
    fi
    ST="${PR_STATE[$PRURL]}"
    [ "$ST" = "MERGED" ] || [ "$ST" = "CLOSED" ] && SETTLED="pr-$ST"
    # A head-bound or failed-typecheck merge-queue row whose PR MERGED means
    # unreviewed or failing code reached main: that is not settled, it got
    # worse. Only a close without merge ends it.
    case "$AKEY" in mq-headbound:*|mq-tc:*) [ "$ST" = MERGED ] && SETTLED="" ;; esac
  fi

  # 2. MIGRATION-PR ping whose migration the autopilot has applied?
  # >>> migration pending
  # BH-2526: the fact comes from the DB. bin/migration-autopilot.sh closes a
  # kind=migration job per file with a stage_event APPLIED / FAILED / FLAGGED /
  # SKIPPED whose detail names `PR#<n>`; one APPLIED for this PR and no FAILED or
  # FLAGGED settles the row. A migration applied by hand leaves no event, so its
  # row waits for the 72h TTL (alerts-supersede.py). A hub-local project also
  # keeps the older probe of the app's own status endpoint: the project comes
  # from the registry (bin/project-of.sh), the base URL from fleet.conf column 3,
  # and the token from whichever *_MIGRATION_TOKEN that project's env file
  # defines (PROJECT_2_MIGRATION_TOKEN, PROJECT_4_MIGRATION_TOKEN). The jq sums BOTH shapes
  # the apps return, a flat .pending and project-4's .targets.<env>.pending.
  if [ -z "$SETTLED" ] && grep -q "MIGRATION-PR merged" <<<"$LINE"; then
    P=""; MUNK=0
    MP=$("$HARNESS/bin/project-of.sh" "$LINE" 2>/dev/null || echo "")
    MN=$(grep -oE "MIGRATION-PR merged: #[0-9]+" <<<"$LINE" | head -1 | grep -oE "[0-9]+$")
    if [ -n "$MP" ] && [ -n "$MN" ]; then
      groom_ask groom_migration_applied "$MP" "$MN"
      case "$GROOM_OUT" in
        applied) SETTLED="migration-applied" ;;
        unknown*) MUNK=1 ;;
      esac
    fi
    if [ -z "$SETTLED" ] && [ -n "$MP" ]; then
      MBASE=$("$HARNESS/bin/fleet-conf.sh" "$MP" prod 2>/dev/null); [ "$MBASE" = "-" ] && MBASE=""
      MBOX=$("$HARNESS/bin/box-for.sh" "$MP" 2>/dev/null || echo "")
      MSNIP='PJ="$1"; BS="$2"
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf "%s\n" /root/harness/env; }; E=$(harness_env_dir)
set -a; . "$E/$PJ.env" 2>/dev/null; set +a
TK=$(grep -hoE "^(export[[:space:]]+)?[A-Z0-9_]*MIGRATION_TOKEN=.*" "$E/$PJ.env" 2>/dev/null | head -1 | sed -E "s/^(export[[:space:]]+)?[^=]*=//" | tr -d "\"")
[ -n "$TK" ] && [ -n "$BS" ] || exit 0
curl -s -m 15 -H "Authorization: Bearer $TK" "$BS/api/internal/migrations/status" \
  | jq -r "((.pending // []) | length) + ([(.targets // {}) | to_entries[] | (.value.pending // []) | length] | add // 0)"'
      if [ -n "$MBASE" ] && { [ -z "$MBOX" ] || [ "$MBOX" = local ]; }; then
        P=$(bash -c "$MSNIP" _ "$MP" "$MBASE" 2>/dev/null)
      fi
    fi
    [ "$P" = "0" ] && SETTLED="migrations-clean"
    # Declared only when the hub-local probe did not settle it either.
    [ -z "$SETTLED" ] && [ "$MUNK" = 1 ] && hold_unknown "$ID" migration "$LINE"
  fi
  # <<< migration pending

  # 3. References a build dir whose RESULT was handled (COMMENTED marker)?
  # BH-2526: the owning box mirrors its COMMENTED file into a job_artifacts
  # `commented` row (bin/commented-mirror.sh, run on every triage tick), so the
  # hub asks the DB. A hub-local build is also checked on the hub's own disk.
  if [ -z "$SETTLED" ]; then
    BDIR=$(grep -oE "/root/harness/builds/[a-zA-Z0-9._-]+" <<<"$LINE" | head -1)
    if [ -n "$BDIR" ]; then
      D="${BDIR%%/plan.md}"; D="${D%%/RESULT}"; D="${D%%/pipeline.log}"; D="${D%%/review.md}"
      # Which box holds the build dir: registry, not three literal names.
      BOX=""
      BP=$("$HARNESS/bin/project-of.sh" "$LINE" 2>/dev/null || echo "")
      [ -n "$BP" ] && BOX=$("$HARNESS/bin/box-for.sh" "$BP" 2>/dev/null || echo "")
      [ "$BOX" = local ] && BOX=""
      if [ -n "$BP" ]; then
        groom_ask groom_commented "$BP" "$D"
        case "$GROOM_OUT" in
          yes) SETTLED="build-handled" ;;
          unknown*) [ -n "$BOX" ] && hold_unknown "$ID" build "$LINE" ;;
        esac
      fi
      [ -z "$SETTLED" ] && [ -z "$BOX" ] && [ -f "$D/COMMENTED" ] && SETTLED="build-handled"
    fi
  fi

  # 4. STUCK / rc!=0 watcher alert for a project whose latest cycle recovered?
  # BH-2526: a remote box answers through its triage lane's row (lane_tick ->
  # GET /api/lanes). A stale row is a DEAD box, whatever its last tick said: the
  # row is held and the pass says so, rather than going quiet as a failed ssh did.
  if [ -z "$SETTLED" ] && grep -qE "STUCK|exited rc=1|rc=1 " <<<"$LINE"; then
    PROJ=$("$HARNESS/bin/project-of.sh" "$LINE" 2>/dev/null || echo "")
    if [ -n "$PROJ" ]; then
      BOX=$("$HARNESS/bin/box-for.sh" "$PROJ" 2>/dev/null || echo local)
      case "$BOX" in
        ''|local)
          LAST=$(tail -1 "$HARNESS/logs/$PROJ.log" 2>/dev/null)
          grep -qE "rc=0|rc=skip" <<<"$LAST" && SETTLED="watcher-recovered" ;;
        *)
          groom_ask groom_watcher_state "$PROJ" "$BOX"
          case "$GROOM_OUT" in
            recovered) SETTLED="watcher-recovered" ;;
            dead*)
              DEAD_N=$((DEAD_N+1))
              read -r _ DBOX DAT <<<"$GROOM_OUT"
              echo "$(STAMP) hold $ID (watcher-dead: $DBOX last tick $DAT): $(head -c 100 <<<"$LINE")" >> "$LOG" ;;
            unknown*) hold_unknown "$ID" watcher "$LINE" ;;
          esac ;;
      esac
    fi
  fi

  if [ -n "$SETTLED" ]; then
    RESOLVE=$(jq -c --arg i "$ID" '. + [$i]' <<<"$RESOLVE")
    # The table keys on the alert-state id, which is derived from the LINE (the
    # console id is a different namespace). Same rule every producer uses.
    if [ "$ALERTS_DB" = 1 ]; then
      RK=$(alert_state_key "$LINE" 2>/dev/null)
      [ -n "$RK" ] && ROW_IDS+=("$RK")
    fi
    echo "$(STAMP) resolve $ID ($SETTLED): $(head -c 100 <<<"$LINE")" >> "$LOG"
  fi
# "-" for an empty akey: tab is IFS whitespace, so an empty middle field would
# collapse and shift the line into AKEY.
done < <(jq -r '.alerts[] | [.id, ((.akey // "") | if . == "" then "-" else . end), ((.line // "") | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$RESP")

N=$(jq 'length' <<<"$RESOLVE")
if [ "$N" -gt 0 ]; then
  curl -s --max-time 20 -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson ids "$RESOLVE" '{ids:$ids}')" "$CONSOLE_URL/api/alerts/resolve" >/dev/null
  # One request for the whole batch, after the console's. `resolved rows=0` on a
  # failure and never the count we hoped for: this line is what an operator
  # greps to tell a closed row from a row we only meant to close.
  if [ "$ALERTS_DB" = 1 ] && [ "${#ROW_IDS[@]}" -gt 0 ]; then
    alert_resolve "${ROW_IDS[@]}" >/dev/null 2>&1; RRC=$?
    if [ "$RRC" -eq 0 ]; then
      echo "$(STAMP) resolved rows=${#ROW_IDS[@]}" >> "$LOG"
    else
      echo "$(STAMP) resolved rows=0 (alerts table rc=$RRC; console resolve already done)" >> "$LOG"
    fi
  fi
fi
# Every pass, N=0 included (BH-2526): rows held on a dead box or an unanswered
# DB read are counted here, so such a pass never reads like a quiet one.
echo "$(STAMP) pass done: resolved $N dead=$DEAD_N unknown=$UNK_N" >> "$LOG"
# Close-the-loop pass: collapse re-fires of the same subject to the newest row,
# close self-declared-settled rows, TTL anything older than 72h. Without this
# every re-verification opened a NEW console row and nothing ever closed one
# (2026-08-26: 66 open rows for ~12 real problems).
# >>> merge alerts resolve (BH-3997)
# pipeline-health's awaiting-merge / not-in-queue rows close (or shrink to the
# PRs still open) once their PRs merge, close or get queued. Before supersede,
# so a row this settles is never collapsed onto first.
[ -x "$HARNESS/bin/alerts-merge-resolve.sh" ] && "$HARNESS/bin/alerts-merge-resolve.sh" >> "$LOG" 2>&1 || true
# <<< merge alerts resolve
python3 "$HARNESS/bin/alerts-supersede.py" >> "$LOG" 2>&1

command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
