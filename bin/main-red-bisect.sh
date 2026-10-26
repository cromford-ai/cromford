#!/bin/bash
# bin/main-red-bisect.sh — BH-3696 (BH-3685.3): the main-red-bisect hub lane.
# Every 10 minutes: find the red episodes on main, prove the red is real (P0/P1),
# bisect main's first-parent merges to the one that turned it red, and hand the
# verdict to the act functions. Bash + git only, no model call, no gh call.
#
# IT CALLS ONLY THE CONTRACT (BH-3693), never a body of its own:
#   mrb_detect_episodes, mrb_episode_still_red   bin/lib/mrb-detect.sh
#   mrb_probe, mrb_bisect                        bin/lib/mrb-probe.sh
#   mrb_act_culprit, mrb_act_notmerge            bin/lib/mrb-act.sh
# The episode file format is the one bin/lib/mrb-detect.sh documents; this lane
# appends the driver keys (culprit, pr, pr_title, pr_branch, steps, shortcut,
# bisect, outcome) to a working copy of it.
#
# PER EPISODE, in order:
#   1. KEY = <slug>@<red>@<first 12 hex of sha256(suites sorted -u, one a line)>.
#      `bin/jobs-client.sh ledger-get main_red_bisect KEY` FIRST: rc 0 is a
#      terminal row (skip), rc 2 a real miss (go on), anything else means the
#      ledger is unreachable: skip the rest of the repo this tick, probe nothing.
#   2. state/main-red-bisect/pending/<sha256(KEY):16>.ep exists: an earlier tick
#      reached a verdict whose act (or row write) did not finish. Re-dispatch it
#      without probing again.
#   3. detect said nosuite|noanchor: one warn, terminal row.
#   4. ONE MERGE (BH-6747): when `git rev-list --first-parent green..red` is
#      exactly one commit and its subject is a PR merge, that merge is the
#      culprit at once: no P0, no P1, no bisect, steps=0, shortcut=one-merge.
#      Any other span takes the path below.
#      P0 at green: norun -> aborted. P1 at red: green -> flake, norun ->
#      aborted. P0 red gives notmerge only when P1 is also red (BH-4318).
#      Then `mrb_bisect _mrb_probe_at <MAX_STEPS-2> <merges>`
#      over `git rev-list --first-parent --reverse green..red`. More than
#      MAX_MERGES merges is `bounded` without a bisect. `found` is `culprit` only
#      when the merge subject is `Merge pull request #N from O/<branch>`.
#   5. culprit|notmerge: mrb_episode_still_red rc 1 is `stale` (no act).
#      Otherwise the episode is written to the pending file, then acted on. The
#      terminal row is written ONLY on act rc 0; any other rc keeps the pending
#      file and the next tick re-dispatches.
# flake, bounded, aborted, nosuite, noanchor and stale get one warn line (not
# stale) and their terminal row directly. A failed row write keeps a pending
# file carrying the verdict, so the next tick retries the write, not the probes.
# After an act answered 0 the pending file also carries `acted=1` (written
# BEFORE the row), and a re-dispatch of it retries ONLY the row write: no
# still-red check, no second act. The act is irreversible (a revert PR, a
# quarantine), so the driver never relies on it being idempotent.
#
# OUTPUTS. One line per repo per tick to logs/main-red-bisect.log:
#   <ts> <slug> episodes=<n> <key>:<outcome> …   (or `<slug> unsupported`,
#   `<slug> forge-unreachable rc=<n> http=<s> reason=<r> why=<line>`, `… ledger-unreachable`)
#   (BH-8195: http/reason are GH_REST_STATUS/GH_REST_REASON, why is the detect's
#   last `mrb-detect: ` stderr line; `-` when there is none. The word is
#   `log-read-failed` instead when http is 2xx, `forge-unreachable` for 000,
#   4xx and 5xx.)
# state/main-red-bisect/<owner>-<repo>.last: outcome= red= green= culprit=
# steps= at= of the last episode handled (outcome=none when there were none).
# Alerts only through bin/lane-alert.sh --severity warn.
#
# OFF: flags/lane-off-main-red-bisect (bin/harness-ctl.sh off main-red-bisect).
# Registry: catalog/lanes.d/main-red-bisect.json. Cron:
# cron/lanes/721-main-red-bisect.cron. Suite: tests/main-red-bisect.bh-3685-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165): exits 0 on flags/all-off or flags/lane-off-main-red-bisect.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit main-red-bisect
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-bisect
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# Again below the env load: global.env re-assigns what the row exported (section
# 16 of tests/lanes-registry-test.sh).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-bisect
export HARNESS="$H"
# shellcheck disable=SC1091
{
  . "$H/bin/lib/hub-box.sh" 2>/dev/null || true
  . "$H/bin/lib/mrb-probe.sh" 2>/dev/null || true
  . "$H/bin/lib/mrb-detect.sh" 2>/dev/null || true
  . "$H/bin/lib/mrb-act.sh" 2>/dev/null || true
}
# The suite's seam: a file that redefines the contract functions as recorders.
# Sandbox only, and settable:false in the registry, so no settings row reaches it.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MAIN_RED_BISECT_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$MAIN_RED_BISECT_FIXTURE"
fi
for f in is_hub_box local_box_name mrb_detect_episodes mrb_episode_still_red mrb_probe mrb_bisect \
         mrb_act_culprit mrb_act_notmerge; do
  command -v "$f" >/dev/null 2>&1 || { echo "main-red-bisect: $f is missing (bin/lib/)" >&2; exit 1; }
done

is_hub_box "$(local_box_name)" || exit 0

ST="$H/state/main-red-bisect"
LOG="$H/logs/main-red-bisect.log"
mkdir -p "$H/logs" "$H/locks" "$ST/pending" 2>/dev/null
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }
exec 9>"$H/locks/main-red-bisect.lock" || exit 0
flock -n 9 || { log "another main-red-bisect tick holds the lock, skipping"; exit 0; }

TMP=$(mktemp -d /tmp/mrb-XXXXXX) || exit 1
trap 'case "$TMP" in /tmp/mrb-?*) rm -rf "$TMP" ;; esac' EXIT

# kint <value> <default> <min> <max> — an int knob, the default when invalid or out of range.
kint() {
  case "$1" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  [ "${#1}" -le 6 ] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ] \
    && printf '%s' "$((10#$1))" || printf '%s' "$2"
}
MAIN_RED_BISECT_MAX_STEPS=$(kint "${MAIN_RED_BISECT_MAX_STEPS:-8}" 8 2 32)
MAIN_RED_BISECT_MAX_MERGES=$(kint "${MAIN_RED_BISECT_MAX_MERGES:-40}" 40 1 400)
MAIN_RED_BISECT_SUITE_TIMEOUT_S=$(kint "${MAIN_RED_BISECT_SUITE_TIMEOUT_S:-900}" 900 60 3600)
MAIN_RED_BISECT_REVERT=$(kint "${MAIN_RED_BISECT_REVERT:-1}" 1 0 1)
MAIN_RED_BISECT_QUARANTINE_MAX=$(kint "${MAIN_RED_BISECT_QUARANTINE_MAX:-3}" 3 0 20)
MAIN_RED_BISECT_PROTECTED_RE="${MAIN_RED_BISECT_PROTECTED_RE:-(ratchet|switch-|merge-|approval|spend|brake|scratch|trace-safety)}"
export MAIN_RED_BISECT_MAX_STEPS MAIN_RED_BISECT_MAX_MERGES MAIN_RED_BISECT_SUITE_TIMEOUT_S \
  MAIN_RED_BISECT_REVERT MAIN_RED_BISECT_QUARANTINE_MAX MAIN_RED_BISECT_PROTECTED_RE
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
REPOS="${MAIN_RED_BISECT_REPOS:-$HARNESS_REPO}"

JC="$H/bin/jobs-client.sh"
ep_get() { awk -F= -v k="$2" '$1==k {v=substr($0, length(k)+2)} END {print v}' "$1" 2>/dev/null; }
sha() { printf '%s' "$1" | sha256sum | cut -c1-"$2"; }
warn() { # warn <what> <text>
  "$H/bin/lane-alert.sh" --severity warn --id "mrb:$1:$KH" main-red-bisect "$2" >/dev/null 2>&1
}
# suite_lines <space-separated suites> — one per line, newline-terminated; nothing for none.
suite_lines() { tr -s ' \t' '\n\n' <<< "$1" | sed '/^$/d'; }
have() { git -C "$REPO_DIR" cat-file -e "$1^{commit}" 2>/dev/null; }

# _mrb_probe_at <sha> — the probe callback mrb_bisect calls as `<fn> <sha>`.
# Records every probe in the episode's bisect table. Anything but red|green is norun.
_mrb_probe_at() {
  local a
  a=$(mrb_probe "$REPO_DIR" "$1" "$TMP/suites" 2>/dev/null)
  a=${a%%$'\n'*}; a=${a//[[:space:]]/}
  case "$a" in red|green|norun) ;; *) a=norun ;; esac
  printf '%s\t%s\n' "$1" "$a" >> "$BTAB"
  printf '%s\n' "$a"
}

# culprit_keys <ep> <sha> <steps> [shortcut] — appends the culprit keys to <ep>
# when <sha>'s subject is `Merge pull request #N from O/<branch>`. rc 1: not a
# PR merge, nothing written. The one-merge path and the bisect path share it.
culprit_keys() {
  local subj
  subj=$(git -C "$REPO_DIR" log -1 --format=%s "$2" 2>/dev/null)
  [[ "$subj" =~ ^Merge\ pull\ request\ \#([0-9]+)\ from\ [^/]+/(.+)$ ]] || return 1
  { echo "culprit=$2"; echo "pr=${BASH_REMATCH[1]}"
    echo "pr_title=$(git -C "$REPO_DIR" log -1 --format=%b "$2" 2>/dev/null | sed -n '/[^[:space:]]/{p;q}')"
    echo "pr_branch=${BASH_REMATCH[2]}"; echo "steps=$3"
    [ -z "${4:-}" ] || echo "shortcut=$4"; } >> "$1"
}

# verdict <ep> — probes and bisects; prints the outcome word, appends the driver
# keys to <ep>. Every non-acting outcome but flake-free ones warns here.
verdict() {
  local ep="$1" p0 p1 cands n line kind cul st subj
  # One PR merge past the last green is the culprit without a probe (BH-6747).
  { have "$GREEN" && have "$RED"; } || git -C "$REPO_DIR" fetch -q origin main >/dev/null 2>&1
  if have "$GREEN" && have "$RED"; then
    git -C "$REPO_DIR" rev-list --first-parent --reverse "$GREEN..$RED" > "$TMP/cands" 2>/dev/null
    if [ "$(grep -c . "$TMP/cands")" = 1 ] && culprit_keys "$ep" "$(head -1 "$TMP/cands")" 0 one-merge; then
      echo culprit; return
    fi
  fi
  p0=$(_mrb_probe_at "$GREEN")
  case "$p0" in
    norun) warn aborted "main-red-bisect: $SLUG P0 at green $GREEN could not run the suites. Nothing acted."
           echo aborted; return ;;
  esac
  # P0 red alone is not notmerge (BH-4318): P1 must reproduce the red too.
  p1=$(_mrb_probe_at "$RED")
  case "$p0 $p1" in
    "red green") warn flake "main-red-bisect: $SLUG P0 at green $GREEN ran red but P1 at red $RED ran green, so the probe does not reproduce this red. Nothing acted."
           echo flake; return ;;
    "red red") echo notmerge; return ;;
  esac
  case "$p1" in
    green) warn flake "main-red-bisect: $SLUG P1 at red $RED ran green, so this red is a flake. Nothing acted."
           echo flake; return ;;
    norun) warn aborted "main-red-bisect: $SLUG P1 at red $RED could not run the suites. Nothing acted."
           echo aborted; return ;;
  esac
  { have "$GREEN" && have "$RED"; } || git -C "$REPO_DIR" fetch -q origin main >/dev/null 2>&1
  if ! { have "$GREEN" && have "$RED"; }; then
    warn aborted "main-red-bisect: $SLUG green $GREEN or red $RED is not in $REPO_DIR after a fetch. Nothing acted."
    echo aborted; return
  fi
  git -C "$REPO_DIR" rev-list --first-parent --reverse "$GREEN..$RED" > "$TMP/cands" 2>/dev/null
  n=$(grep -c . "$TMP/cands")
  if [ "$n" -eq 0 ]; then
    warn aborted "main-red-bisect: $SLUG $GREEN..$RED holds no merge to bisect. Nothing acted."
    echo aborted; return
  fi
  if [ "$n" -gt "$MAIN_RED_BISECT_MAX_MERGES" ]; then
    warn bounded "main-red-bisect: $SLUG $GREEN..$RED holds $n merges, over MAX_MERGES=$MAIN_RED_BISECT_MAX_MERGES. Not bisected, nothing acted."
    echo bounded; return
  fi
  mapfile -t cands < "$TMP/cands"
  line=$(mrb_bisect _mrb_probe_at "$((MAIN_RED_BISECT_MAX_STEPS - 2))" "${cands[@]}" 2>/dev/null)
  read -r kind cul st _ <<< "$line"
  case "$kind" in
    found)
      culprit_keys "$ep" "$cul" "$(( ${st:-0} + 2 ))" && { echo culprit; return; }
      subj=$(git -C "$REPO_DIR" log -1 --format=%s "$cul" 2>/dev/null)
      warn aborted "main-red-bisect: $SLUG culprit $cul is not a PR merge (subject: $subj). Nothing acted."
      echo aborted ;;
    bounded)
      warn bounded "main-red-bisect: $SLUG the culprit is in $cul..$st, the bisect budget ran out. Nothing acted."
      echo bounded ;;
    *)
      warn aborted "main-red-bisect: $SLUG bisect of $GREEN..$RED answered '$line'. Nothing acted."
      echo aborted ;;
  esac
}

# finish <ep> <outcome> — act when the outcome acts, then the terminal row.
# Sets OUTW (the verdict) and OUT (the word for the log line). rc 0 always.
finish() {
  local ep="$1" o="$2" rc detail
  OUT="$o"; OUTW="$o"; LCUL=$(ep_get "$ep" culprit); LSTEPS=$(ep_get "$ep" steps)
  # acted=1 on the pending file: an earlier tick's act returned 0 and only its
  # row write failed. Retry the write alone; the act never runs twice.
  [ "$ep" = "$PEND" ] && [ "$(ep_get "$ep" acted)" = 1 ] && o="$o+acted"
  case "$o" in *+acted) o="${o%+acted}"; OUT="$o"; OUTW="$o" ;;
  culprit|notmerge)
    rc=0; mrb_episode_still_red "$ep" || rc=$?
    if [ "$rc" = 1 ]; then o=stale; OUT=stale; OUTW=stale
    elif [ "$rc" != 0 ]; then OUT="$o(still-red-rc=$rc)"; return 0
    else
      [ "$ep" = "$PEND" ] || {
        [ -s "$BTAB" ] && cp "$BTAB" "${PEND%.ep}.bisect" && echo "bisect=${PEND%.ep}.bisect" >> "$ep"
        echo "outcome=$o" >> "$ep"; cp "$ep" "$PEND"; ep="$PEND"; }
      rc=0
      if [ "$o" = culprit ]; then mrb_act_culprit "$ep" || rc=$?; else mrb_act_notmerge "$ep" || rc=$?; fi
      [ "$rc" = 0 ] || { OUT="$o(act-rc=$rc retry-next-tick)"; return 0; }
      echo "acted=1" >> "$PEND"
    fi ;;
  esac
  [ "$ep" = "$PEND" ] || { echo "outcome=$o" >> "$ep"; }
  detail="green=$GREEN red=$RED culprit=$(ep_get "$ep" culprit) pr=$(ep_get "$ep" pr) steps=$(ep_get "$ep" steps)"
  if "$JC" ledger-put main_red_bisect "$KEY" "$o" "$detail" >/dev/null 2>&1; then
    rm -f "$PEND" "${PEND%.ep}.bisect"
  else
    OUT="$o(ledger-put-failed)"
    [ "$ep" = "$PEND" ] || { cp "$ep" "$PEND"; }
    echo "outcome=$o" >> "$PEND"
  fi
  return 0
}

# episode <ep> — one episode end to end. rc 3: the ledger is unreachable.
episode() {
  local src="$1" ep suites o
  RED=$(ep_get "$src" red); GREEN=$(ep_get "$src" green); suites=$(ep_get "$src" suites)
  KEY="$SLUG@$RED@$(suite_lines "$suites" | LC_ALL=C sort -u | sha256sum | cut -c1-12)"
  KH=$(sha "$KEY" 16); PEND="$ST/pending/$KH.ep"; BTAB="$TMP/bisect.$KH"
  : > "$BTAB"
  "$JC" ledger-get main_red_bisect "$KEY" >/dev/null 2>&1
  case "$?" in
    0) PARTS="$PARTS $KEY:seen"; return 0 ;;
    2) ;;
    *) return 3 ;;
  esac
  if [ -f "$PEND" ]; then
    o=$(ep_get "$PEND" outcome); finish "$PEND" "$o"
  else
    ep="$TMP/work.$KH"; cp "$src" "$ep"
    o=$(ep_get "$src" outcome)
    case "$o" in
      nosuite|noanchor)
        warn "$o" "main-red-bisect: $SLUG red $RED cannot be bisected (detect: $o). Nothing acted." ;;
      '')
        if [ -z "$RED" ] || [ -z "$GREEN" ]; then
          warn aborted "main-red-bisect: $SLUG episode has no red or green sha. Nothing acted."; o=aborted
        else
          suite_lines "$suites" > "$TMP/suites"
          o=$(verdict "$ep")
        fi ;;
      *) warn aborted "main-red-bisect: $SLUG detect answered outcome=$o, which this lane does not know. Nothing acted."
         o=aborted ;;
    esac
    [ "$o" = culprit ] || [ -n "$(ep_get "$ep" steps)" ] || echo "steps=$(grep -c . "$BTAB")" >> "$ep"
    finish "$ep" "$o"
  fi
  PARTS="$PARTS $KEY:$OUT"
  printf 'outcome=%s\nred=%s\ngreen=%s\nculprit=%s\nsteps=%s\n' "$OUTW" "$RED" "$GREEN" "$LCUL" "$LSTEPS" > "$TMP/last"
  return 0
}

n=0
for SLUG in $(printf '%s' "$REPOS" | tr ',' ' '); do
  n=$((n+1))
  if [ "$SLUG" != "$HARNESS_REPO" ]; then log "$SLUG unsupported"; continue; fi
  REPO_DIR="${REPOS_ROOT:-/root/repos}/${SLUG#*/}"
  # mrb_act_culprit cuts the revert in this checkout (bin/lib/mrb-act.sh's contract).
  export MRB_REPO_DIR="$REPO_DIR"
  EPD="$TMP/ep.$n"; mkdir -p "$EPD"
  # BH-8195: the cron line drops stderr, so the detect's reason goes in the log line.
  rc=0; mrb_detect_episodes "$SLUG" "$REPO_DIR" "$EPD" 2>"$TMP/detect.$n.err" || rc=$?
  if [ "$rc" != 0 ]; then
    why=$(grep '^mrb-detect: ' "$TMP/detect.$n.err" 2>/dev/null | tail -1 | tr -d '\r' | tr '\t' ' ')
    # BH-8223: a failure after a 2xx read is not the forge; gh refused or a read broke.
    case "${GH_REST_STATUS:-000}" in 2[0-9][0-9]) word=log-read-failed ;; *) word=forge-unreachable ;; esac
    log "$SLUG $word rc=$rc http=${GH_REST_STATUS:--} reason=${GH_REST_REASON:--} why=${why:--}"
    continue
  fi
  PARTS=""; echo "outcome=none" > "$TMP/last"; cnt=0
  for f in "$EPD"/*; do [ -f "$f" ] && cnt=$((cnt+1)); done
  for f in "$EPD"/*; do
    [ -f "$f" ] || continue
    episode "$f" || { PARTS="$PARTS ledger-unreachable"; break; }
  done
  log "$SLUG episodes=$cnt$PARTS"
  { cat "$TMP/last"; echo "at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } > "$ST/${SLUG%%/*}-${SLUG#*/}.last"
done
exit 0
