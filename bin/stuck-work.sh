#!/bin/bash
# bin/stuck-work.sh — BH-3781: the stuck-work hub lane. Every 5 min it reads
# every open PR and ai-build ticket, classifies each one into the state that
# names who owes the next move (bin/lib/stuck-work/classify.sh), and pages an
# item ONCE when it has sat past its state's SLA, and once more at
# STUCK_WORK_REPAGE_FACTOR x SLA. The switch/disabled/all-off handling is the
# BH-3789 contract's; BH-3793 (BH-3781.4) filled the body below it.
#
# THREE MODES:
#   stuck-work.sh --dispatch   the cron line. Starts one detached
#       `stuck-work.sh <project>` per fleet project through the shared runner
#       (bin/lib/project-lanes.sh pl_dispatch), each at a stable offset inside
#       STUCK_WORK_DISPATCH_SPREAD_S (default 240), and exits. It takes no lock
#       and reads no fact. Its one line goes to logs/stuck-work-cron.log.
#   stuck-work.sh <project>    one project's run. Exits 0 at once, before the
#       lane gate and any fact read, when the project is not watched
#       (STUCK_WORK_PROJECTS below). Its only read is the TTL-shared settings
#       cache.
#   stuck-work.sh              the home project's run (hand runs).
# A bad argument, a project fleet.conf does not resolve, or a name that is also
# a cache dir under state/stuck-work/ (ci, thread, seen, led) exits 2 before any
# worker request.
#
# THE WATCHED SET, STUCK_WORK_PROJECTS: `self` (default, also empty) = only the
# home project; `all` = every fleet project; or a comma list of names (exact
# match). Any other value is one stderr line and reads as `self`. The HOME
# project is the first fleet.conf project whose repo is sw_repo, else
# `cromford`. The home run keeps today's names: logs/stuck-work.log,
# state/stuck-work/{no-token,outage}-*, pages --project <home>, ticket prefix
# STUCK_WORK_KEY_PREFIX (BH), snapshot stuck_work_snapshot/latest. Any other
# project: logs/stuck-work-<p>.log, marks in $PL_STATE_DIR (state/stuck-work/<p>),
# pages --project <p>, the ticket prefix from the launch line in
# prompts/<p>.md (no prefix = PRs only), snapshot stuck_work_snapshot/<p>.
#
# LOCKS (dedupe, never a wait): locks/stuck-work-<project>.lock, which the
# runner already holds on fd 9 (PL_LOCK_FD) or this script takes with
# pl_lock_take; the home run also takes the legacy locks/stuck-work.lock on
# fd 8. Either held = summary `busy`, exit 0.
#
# One run:
#   1. gather FACTS lines: swf_pr_facts <repo>, then swf_ticket_facts <repo>
#      <file of PR items>. Any rc but 0 from either is incomplete=1; the items a
#      reader did not print are simply not looked at this run.
#   2. per item: sw_state, sw_sla_s, sw_age_s, the stuck_work row for
#      <sw_key>, sw_decide. The row is read from the local mirror
#      state/stuck-work/led/<sha1 of key> when it parses, else job_ledger_row
#      stuck_work <key>. The mirror holds only rows a GET or a PUT of this lane
#      returned or wrote (only this lane writes the kind), so it never adds a
#      page; a corrupt or empty-status mirror falls back to the GET.
#   3. page/repage: WRITE FIRST (job_ledger_put stuck_work <key> paged|repaged),
#      then bin/alert-line.sh --severity warn --id stuck-work only on rc 0. The
#      mirror is written after the PUT succeeded, never on a failed one.
#   4. an item that would page but whose row could not be read or written is
#      unpaged: ONE `STUCK-WORK ledger unreachable` line per UTC hour
#      (outage-<YYYYMMDDHH>, written after the send).
#   5. the stuck_work_snapshot row the daily digest reads (`latest`, home).
#   6. memo and mirror files older than 30 days are deleted.
#   7. one line in logs/stuck-work-profile.log:
#      <ts> project=<p> secs=<n> facts_s=<n> loop_s=<n> items=<n> seen_hit=<n>
#      seen_miss=<n> led_hit=<n> led_miss=<n> ci_hit=<n> ci_miss=<n> thread_skip=<n>
# No GitHub App token (and no GH_TOKEN/GITHUB_TOKEN): summary `no-token` and one
# lane-alert a UTC day (no-token-<YYYYMMDD>).
#
# Summary line: <ts> off | <ts> disabled | <ts> busy | <ts> no-token |
#   <ts> no-classifier (classify.sh did not load) | <ts> no-tmp |
#   <ts> items=N states=<s:n,...> past_sla=N paged=N repaged=N incomplete=0|1
#   [unpaged=N] [snap=fail]
# past_sla counts waiting-on-human (digest only, never paged), not excluded.
# A non-home run on a lane-run machine (LANE_RUN_ID set) writes the line to
# logs/stuck-work.log as `<ts> project=<p> <text>`: only logs/<lane>.log rides
# back to the hub, and bin/lib/lane-move/stuck-work.sh counts it (BH-7423).
#
# Test seams, honoured only under HARNESS_TEST_SANDBOX=1: STUCK_WORK_FIXTURE (a
# file of FACTS lines read instead of GitHub, or a directory holding
# <project>.txt) and STUCK_WORK_NOW (all digits).
#
# OFF: settings row / flags/stuck-work-off (lane_switch), flags/lane-off-stuck-work
# (bin/harness-ctl.sh off stuck-work), or STUCK_WORK_ENABLED=0. One project:
# flags/lane-off-stuck-work-<p> (the dispatcher skips it).
# Registry: catalog/lanes.d/stuck-work.json. Cron: cron/lanes/723-stuck-work.cron.
# Doc: docs/notes/2026-10-01-BH-3781-stuck-work.md,
# docs/notes/2026-10-11-BH-5943-stuck-work-runner.md.
#
# gh-identity: app-token
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
}
# The shared per-project lane runner (BH-5913). A box mid-sync without it still
# runs by hand; --dispatch then says so and starts nothing.
# shellcheck source=bin/lib/project-lanes.sh
[ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"
# sw_home_project — the fleet project whose repo is sw_repo, else cromford.
sw_home_project() {
  local repo="" p
  command -v sw_repo >/dev/null 2>&1 && repo=$(sw_repo 2>/dev/null)
  if [ -n "$repo" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)" = "$repo" ] && { printf '%s\n' "$p"; return 0; }
    done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  fi
  printf 'cromford\n'
}

# sw_watched <project> <home> — rc 0 when STUCK_WORK_PROJECTS watches it.
sw_watched() {
  local p="$1" home="$2" list="${STUCK_WORK_PROJECTS:-self}"
  case "$list" in
    all) return 0 ;;
    self) ;;
    *[!A-Za-z0-9._,-]*|,*|*,|*,,*)
      echo "stuck-work: STUCK_WORK_PROJECTS='$list' is not self, all or a comma list of project names; read as self" >&2 ;;
    *) case ",$list," in *",$p,"*) return 0 ;; esac
       return 1 ;;
  esac
  [ "$p" = "$home" ]
}

# Arguments, checked before any worker request.
usage() { echo "usage: stuck-work.sh [--dispatch | <project>]" >&2; exit 2; }
MODE=run; PROJECT=""
case "$#" in
  0) ;;
  1) case "$1" in --dispatch) MODE=dispatch ;; -*|'') usage ;; *) PROJECT=$1 ;; esac ;;
  *) usage ;;
esac
# The classifier is pure (no read); the dispatcher does not need it.
HOME_P=""
if [ "$MODE" = run ]; then
  # shellcheck source=bin/lib/stuck-work/classify.sh
  . "$SELF/lib/stuck-work/classify.sh" 2>/dev/null || true
  HOME_P=$(sw_home_project)
fi
if [ -n "$PROJECT" ]; then
  case "$PROJECT" in ''|.*|*[!A-Za-z0-9._-]*) echo "stuck-work: bad project name '$PROJECT'" >&2; usage ;; esac
  case "$PROJECT" in
    ci|thread|seen|led) echo "stuck-work: '$PROJECT' is a reserved name (a cache dir under state/stuck-work/); not run" >&2; exit 2 ;;
  esac
  if [ "$PROJECT" != "$HOME_P" ]; then
    case "$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)" in
      */*) ;;
      *) echo "stuck-work: fleet.conf has no repo for project '$PROJECT'" >&2; exit 2 ;;
    esac
  fi
fi
[ -n "$PROJECT" ] || PROJECT=$HOME_P

# The knobs first: STUCK_WORK_PROJECTS can be a settings row. lane_env_apply
# reads the box settings cache, which the dispatcher refreshed seconds before
# (TTL LANE_GATE_CACHE_S), so a dispatched run makes no request here.
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply stuck-work
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

# A project this box does not watch: no gate, no liveness row, no flag read,
# no stamp, no log (BH-5943 review F1). It does no work, so it needs no gate,
# and a liveness `ran` from it would hide a dead home run.
if [ "$MODE" = run ] && ! sw_watched "$PROJECT" "$HOME_P"; then exit 0; fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit stuck-work

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/stuck-work.log"; SUMTAG=""
if [ "$MODE" = run ] && [ "$PROJECT" != "$HOME_P" ]; then
  if [ -n "${LANE_RUN_ID:-}" ]; then SUMTAG="project=$PROJECT "; else LOG="$H/logs/stuck-work-$PROJECT.log"; fi
fi
summary() { printf '%s%s\n' "$(date -u +%FT%TZ)" "${1:+ $SUMTAG$1}" >> "$LOG"; }

if lane_switch stuck-work-off file; then summary off; exit 0; fi
[ "${STUCK_WORK_ENABLED:-1}" = 0 ] && { summary disabled; exit 0; }

if [ "$MODE" = dispatch ]; then
  if ! command -v pl_dispatch >/dev/null 2>&1; then
    echo "$(date -u +%FT%TZ) stuck-work dispatch: bin/lib/project-lanes.sh is not loaded — no project run started"
    exit 1
  fi
  SPREAD="${STUCK_WORK_DISPATCH_SPREAD_S:-240}"
  case "$SPREAD" in
    ''|*[!0-9]*) echo "$(date -u +%FT%TZ) stuck-work dispatch: STUCK_WORK_DISPATCH_SPREAD_S='$SPREAD' is not a number of seconds; using 240"
                 SPREAD=240 ;;
  esac
  rc=0; line=$(pl_dispatch stuck-work "$SPREAD" "$H/bin/stuck-work.sh") || rc=$?
  echo "$(date -u +%FT%TZ) $line"
  exit "$rc"
fi

mkdir -p "$H/locks" "$H/state/stuck-work" 2>/dev/null
if [ -n "${PL_LOCK_FD:-}" ] && [ "${PL_LANE:-}" = stuck-work ] && [ "${PL_PROJECT:-}" = "$PROJECT" ]; then
  :  # the runner holds locks/stuck-work-<project>.lock on PL_LOCK_FD
elif command -v pl_lock_take >/dev/null 2>&1; then
  pl_lock_take stuck-work "$PROJECT" 9 || { summary busy; exit 0; }
else
  exec 9>"$H/locks/stuck-work-$PROJECT.lock"
  flock -n 9 || { summary busy; exit 0; }
fi
if [ "$PROJECT" = "$HOME_P" ]; then
  exec 8>"$H/locks/stuck-work.lock"
  flock -n 8 || { summary busy; exit 0; }
fi
# Loaded only now: bin/lib/mc/queue.sh reads its knobs from the worker when it
# is sourced, and nothing above the lock may make a request a busy run would.
# shellcheck disable=SC1090,SC1091
{
  for _f in seen facts-pr facts-ticket; do . "$SELF/lib/stuck-work/$_f.sh" 2>/dev/null || true; done
  # what swf_pr_facts calls; a verb that did not load makes its fields `?`
  for _f in gh-rest-list verdict-status verdicts mc/log mc/classify mc/queue jobs/dequeue-watch gh-app-default; do
    . "$SELF/lib/$_f.sh" 2>/dev/null || true
  done
  unset _f
}
command -v sw_state >/dev/null 2>&1 || { summary "no-classifier"; exit 0; }

T_START=$(date +%s)
NOW=$(date -u +%s)
SANDBOX=0; [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && SANDBOX=1
[ "$SANDBOX" = 1 ] && [[ "${STUCK_WORK_NOW:-}" =~ ^[0-9]+$ ]] && NOW=$STUCK_WORK_NOW
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stuck-work.XXXXXX") || { summary "no-tmp"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/facts"
[ -n "${SWF_COUNT_FILE:-}" ] || { SWF_COUNT_FILE="$TMP/count"; export SWF_COUNT_FILE; }
incomplete=0

# Per-project names. The home project keeps every name it had before BH-5943.
if [ "$PROJECT" = "$HOME_P" ]; then
  MARKD="$H/state/stuck-work"; SNAPKEY=latest
else
  MARKD="$H/state/stuck-work/$PROJECT"
  [ "${PL_PROJECT:-}" = "$PROJECT" ] && [ -n "${PL_STATE_DIR:-}" ] && MARKD=$PL_STATE_DIR
  SNAPKEY=$PROJECT
  mkdir -p "$MARKD" 2>/dev/null
fi

FIX=""
if [ "$SANDBOX" = 1 ] && [ -n "${STUCK_WORK_FIXTURE:-}" ]; then
  if [ -d "$STUCK_WORK_FIXTURE" ]; then FIX="$STUCK_WORK_FIXTURE/$PROJECT.txt"; else FIX=$STUCK_WORK_FIXTURE; fi
fi
if [ -n "$FIX" ] && [ -r "$FIX" ] && [ -f "$FIX" ]; then
  cp "$FIX" "$TMP/facts"
else
  if [ "$PROJECT" = "$HOME_P" ]; then
    REPO=$(sw_repo); PFX="${STUCK_WORK_KEY_PREFIX:-BH}"
  else
    REPO=""; [ "${PL_PROJECT:-}" = "$PROJECT" ] && REPO="${PL_SLUG:-}"
    [ -n "$REPO" ] || REPO=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
    PFX=$(grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$H/prompts/$PROJECT.md" 2>/dev/null | head -1 | cut -d- -f1)
  fi
  # global.env may have set GH_TOKEN: a run started by the runner re-arms its
  # own project's App token (the runner contract), a hand run of another
  # project arms it here.
  if [ "${PL_PROJECT:-}" = "$PROJECT" ] && [ -n "${PL_SLUG:-}" ]; then
    command -v pl_token >/dev/null 2>&1 && { pl_token || true; }
  elif [ "$PROJECT" != "$HOME_P" ] && command -v pl_token >/dev/null 2>&1; then
    PL_SLUG=$REPO pl_token || true
  fi
  if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    if command -v gh_app_default_token >/dev/null 2>&1 && GH_TOKEN=$(gh_app_default_token "$REPO") && [ -n "$GH_TOKEN" ]; then
      export GH_TOKEN
    else
      unset GH_TOKEN
      summary no-token
      mark="$MARKD/no-token-$(date -u -d "@$NOW" +%Y%m%d)"
      if [ ! -e "$mark" ]; then
        "$H/bin/lane-alert.sh" --id stuck-work-no-token --severity warn stuck-work \
          "STUCK-WORK no GitHub App token for $REPO; no open work is being watched"
        touch "$mark" 2>/dev/null
      fi
      exit 0
    fi
  fi
  rc=0; swf_pr_facts "$REPO" > "$TMP/prs" || rc=$?
  [ "$rc" = 0 ] || incomplete=1
  cat "$TMP/prs" >> "$TMP/facts"
  cut -f2 "$TMP/prs" > "$TMP/pr-items"
  # A project with no ticket prefix has no GitHub-Issues board: PRs only.
  if [ -n "$PFX" ]; then
    rc=0; STUCK_WORK_KEY_PREFIX=$PFX swf_ticket_facts "$REPO" "$TMP/pr-items" >> "$TMP/facts" || rc=$?
    [ "$rc" = 0 ] || incomplete=1
  fi
fi
T_FACTS=$(date +%s)

# The stuck_work row mirror. Same root rule as the CI cache (_swf_state_dir).
LEDD=""; command -v _swf_state_dir >/dev/null 2>&1 && LEDD=$(_swf_state_dir led 2>/dev/null)
led_file() { [ -n "$LEDD" ] && printf '%s/%s' "$LEDD" "$(printf '%s' "$1" | sha1sum | cut -c1-40)"; }
led_keep() { # led_keep <file|""> <row-json>
  [ -n "$1" ] || return 0
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null
  rm -f "$1.tmp.$$" 2>/dev/null
  return 0
}
count() { printf '%s %s\n' "$1" "$2" >> "$SWF_COUNT_FILE" 2>/dev/null; return 0; }

declare -A states=() past=()
n=0 paged=0 repaged=0 unpaged=0 unread=0
max=$(sw_max_items); factor=$(sw_repage_factor)
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  if [ "$n" -ge "$max" ]; then incomplete=1; break; fi
  n=$((n + 1))
  IFS=$'\t' read -r st owner entered oa <<< "$(sw_state "$line")"
  item=$(cut -f2 <<< "$line"); url=$(cut -f3 <<< "$line")
  # excluded (drafts, held tickets) has no SLA: counted, never past it
  if [ "$st" = excluded ]; then states[$st]=$(( ${states[$st]:-0} + 1 )); continue; fi
  if ! sla=$(sw_sla_s "$st"); then st=unclassified; owner=stuck-work; sla=0; fi
  age=$(sw_age_s "$NOW" "$entered" "$oa")
  states[$st]=$(( ${states[$st]:-0} + 1 ))
  [ "$age" -ge "$sla" ] || continue
  past[$st]=$(( ${past[$st]:-0} + 1 ))
  key=$(sw_key "$item" "$st" "$entered") || continue
  lf=$(led_file "$key"); rrc=0; row=""
  if [ -n "$lf" ] && [ -r "$lf" ] && row=$(jq -ce 'select((.status // "") != "")' "$lf" 2>/dev/null); then
    count LED-HIT "$key"
  else
    rrc=0; row=$(job_ledger_row stuck_work "$key") || rrc=$?
    count LED-MISS "$key"
    [ "$rrc" = 0 ] && led_keep "$lf" "$row"
  fi
  case "$rrc" in
    0) led=$(jq -r '.status // "?"' <<< "$row" 2>/dev/null) || led='?' ;;
    2) led=- ;;
    *) led='?' ;;
  esac
  d=$(sw_decide "$sla" "$age" "$led" "$factor" "$st")
  if [ "$led" = '?' ]; then
    # a row we could not read may already be paged: counted as unread, an upper bound
    [ "$(sw_decide "$sla" "$age" - "$factor" "$st")" = page ] && { unpaged=$((unpaged + 1)); unread=$((unread + 1)); }
    continue
  fi
  case "$d" in page|repage) ;; *) continue ;; esac
  if [ "$d" = page ]; then
    detail=$(jq -nc --arg o "$owner" --argjson s "$sla" --argjson t "$NOW" '{owner:$o,sla_s:$s,paged_at:$t,repaged_at:null}')
    status=paged
  else
    pa=$(jq -r '.detail | fromjson? | .paged_at // empty | numbers' <<< "$row" 2>/dev/null)
    detail=$(jq -nc --arg o "$owner" --argjson s "$sla" --arg p "$pa" --argjson t "$NOW" \
      '{owner:$o,sla_s:$s,paged_at:($p | tonumber? // null),repaged_at:$t}')
    status=repaged
  fi
  if job_ledger_put stuck_work "$key" "$status" "$detail" >/dev/null 2>&1; then
    led_keep "$lf" "$(jq -nc --arg s "$status" --arg d "$detail" '{status:$s, detail:$d}')"
    "$H/bin/alert-line.sh" --severity warn --id stuck-work --project "$PROJECT" \
      "$(sw_page_text "$item" "$st" "$owner" "$age" "$sla" "$url")"
    if [ "$d" = page ]; then paged=$((paged + 1)); else repaged=$((repaged + 1)); fi
  else
    unpaged=$((unpaged + 1))
  fi
done < "$TMP/facts"
T_LOOP=$(date +%s)

if [ "$unpaged" -gt 0 ]; then
  mark="$MARKD/outage-$(date -u -d "@$NOW" +%Y%m%d%H)"
  if [ ! -e "$mark" ]; then
    "$H/bin/alert-line.sh" --severity warn --id stuck-work-ledger --project "$PROJECT" \
      "STUCK-WORK ledger unreachable — $([ "$unread" -gt 0 ] && echo "up to ")$unpaged items past SLA unpaged$([ "$unread" -gt 0 ] && echo " ($unread could not be read, so may already be paged)")"
    touch "$mark" 2>/dev/null
  fi
fi

total=0; by_state='{}'; st_list=""
for st in $(printf '%s\n' "${!past[@]}" | LC_ALL=C sort); do
  total=$((total + past[$st]))
  by_state=$(jq -c --arg k "$st" --argjson v "${past[$st]}" '. + {($k): $v}' <<< "$by_state")
done
for st in $(printf '%s\n' "${!states[@]}" | LC_ALL=C sort); do st_list+="${st_list:+,}$st:${states[$st]}"; done
snap=""
detail=$(jq -nc --argjson at "$NOW" --argjson c "$([ "$incomplete" = 0 ] && echo true || echo false)" \
  --argjson b "$by_state" --argjson t "$total" '{at:$at,complete:$c,by_state:$b,total:$t}')
job_ledger_put stuck_work_snapshot "$SNAPKEY" ok "$detail" >/dev/null 2>&1 || snap=" snap=fail"
extra=""; [ "$unpaged" -gt 0 ] && extra=" unpaged=$unpaged"
summary "items=$n states=${st_list:--} past_sla=$total paged=$paged repaged=$repaged incomplete=$incomplete$extra$snap"

# Memo and mirror files of items gone for 30 days.
_d=""; command -v _swf_state_dir >/dev/null 2>&1 && _d=$(_swf_state_dir . 2>/dev/null)
[ -n "$_d" ] && find "$_d/led" "$_d/seen" -type f -mtime +30 -delete 2>/dev/null

T_END=$(date +%s)
pc() { local c; c=$(grep -c "^$1 " "$SWF_COUNT_FILE" 2>/dev/null); printf '%s' "${c:-0}"; }
printf '%s project=%s secs=%s facts_s=%s loop_s=%s items=%s seen_hit=%s seen_miss=%s led_hit=%s led_miss=%s ci_hit=%s ci_miss=%s thread_skip=%s\n' \
  "$(date -u +%FT%TZ)" "$PROJECT" "$((T_END - T_START))" "$((T_FACTS - T_START))" "$((T_LOOP - T_FACTS))" "$n" \
  "$(pc SEEN-HIT)" "$(pc SEEN-MISS)" "$(pc LED-HIT)" "$(pc LED-MISS)" "$(pc CI-HIT)" "$(pc CI-MISS)" "$(pc THREAD-SKIP)" \
  >> "$H/logs/stuck-work-profile.log" 2>/dev/null
exit 0
