#!/bin/bash
# rule-miner.sh — trust-7: the incident-to-rule mining lane (TRUST-PROGRAM #7).
# Weekly HUB cron. Deterministically gathers the week's incidents — fleet-repo
# revert/rollback commits, board reopens (logs/reopens.csv), review/refuter
# BLOCK verdicts in build dirs, hand-filed manual notes, and (source (e), Wave A)
# review-finding FAMILIES that recurred PROMOTE_MIN+ times in 30 days — bundles
# their evidence under state/rule-mining/<date>/, and runs ONE fable session
# over them.
#
# TWO OUTPUT LANES, both PR-only, neither ever merged:
#   prose        -> candidate build-discipline.md rules, PR on the harness repo
#                   (the original lane; unchanged)
#   mechanizable -> a concrete check (semgrep / eslint / CI step) drafted into
#                   state/rule-mining/<date>/checks/<slug>/ and handed to
#                   bin/guardrail-promote.sh, which opens ONE PR per check on
#                   the TARGET PROJECT repo. The session decides which lane an
#                   incident belongs to via the objectivity test (measurable
#                   observation + named tool + explicit threshold); anything
#                   short of all three stays prose.
#
# A THIRD lane exists but the miner does not write it: checks/ holds the mined
# checks the HARNESS itself runs, over every diff bin/run-build.sh reviews and
# bin/merge-sweep.sh is about to merge (see checks/README.md). Families promoted
# there are already enforced mechanically, which is why the drafting session is
# pointed at that catalog too — so it does not spend a week drafting a check for
# a family a script already answers.
#
# Zero incidents, or an agent verdict of NO_RULE, ends the prose lane with one
# log line — a rule is only ever mined from a real incident, never fabricated.
# NO_RULE is the PROSE verdict only: a week can promote a check and add no rule.
# Kill switch: the settings row switch.rule-miner-disabled[.<box>] (lane_switch,
# bin/lib/lane-switch.sh); with no row, flag_active rule-miner-disabled (see
# below). Dry run: RULE_MINER_DRY=1 gathers +
# bundles + prints the incident inventory, then stops before the agent call.
# Idempotency: incidents cited in a previously opened rules PR are recorded in
# state/rule-mining/seen.txt and skipped forever after.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=rule-miner
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-rule-miner
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off rule-miner.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit rule-miner
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rule-miner
SELF="$(cd "$(dirname "$0")" && pwd)"
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$HARNESS/logs/rule-miner.log"
ALERTS="$HARNESS/logs/ALERTS.log"

mkdir -p "$HARNESS/locks" "$HARNESS/logs" "$HARNESS/state/rule-mining"
# global.env (HARNESS_SECRET) is sourced BEFORE the kill-switch test now,
# because the kill-switch test is a flag lookup and the flag lookup wants the
# coordination client. THE FILE IS STILL THE FLAG: flag_active reconciles
# flags/rule-miner-disabled from its DB row and then tests the FILE, so a
# console pause reaches this weekly lane while a 404 ("no row") or a worker
# outage leaves the box deciding exactly as it does today. With no client at
# all this is the bare file test it has always been. A switch.rule-miner-disabled
# row answers before any of that (lane_switch); flag_active is its no-row step.
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rule-miner
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# >>> model-route (BH-1510.2): model_routes role `rule.miner`; MINER_MODEL (env
# or settings row) still wins. Below the env load so both are seen. No route =
# rc 75 before any work, alerted by bin/lib/model-route.sh — never a guess.
. "$HARNESS/bin/lib/lane-model.sh"
MINER_MODEL=$(lane_model MINER_MODEL rule.miner) \
  || { echo "$(STAMP) no model route for role rule.miner — run skipped" >> "$LOG"; exit 75; }
# <<< model-route
# BH-1749.2: the call runs on the ROUTE's runner, pinned through
# AGENT_CALL_RUNNERS below — as stage `triage` the hub's RUNNER_TRIAGE=grok
# silently replaced it. Only the claude runner meters context, so the ceiling
# gate below means nothing on any other runner: refuse before any work.
MINER_RUNNER=$(lane_model_ladder rule.miner) \
  || { echo "$(STAMP) no model route for role rule.miner — run skipped" >> "$LOG"; exit 75; }
MINER_RUNNER=$(printf '%s\n' "$MINER_RUNNER" | awk -F'\t' 'NR==1{print $3}')
if [ "$MINER_RUNNER" != claude ]; then
  echo "$(STAMP) [rule-miner] rule.miner routes to runner ${MINER_RUNNER:-<none>}; only the claude runner is context-metered, so the ceiling cannot be enforced — run skipped. Route rule.miner to claude (PUT /api/model-routes/rule.miner) to re-enable" >> "$ALERTS"
  echo "$(STAMP) rule.miner routes to runner ${MINER_RUNNER:-<none>}, not claude — run skipped" >> "$LOG"
  exit 75
fi
# Two sets of repos in one run — every fleet repo, then the harness repo — so it
# arms once per repo and resets between them.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null
# shellcheck source=lib/lane-switch.sh
. "$SELF/lib/lane-switch.sh" || exit 1
lane_switch rule-miner-disabled && exit 0
exec 9>"$HARNESS/locks/rule-miner.lock"; flock -n 9 || exit 0

# --- Coordination row (phase 4) ----------------------------------------------
# The mining session is a real Fable call over a week of incident bundles, and
# it is the single longest-running unenrolled lane on the hub — an hour of
# gathering, cloning and drafting with nothing anywhere saying it was running.
# The claim is LAZY: a week with zero unseen incidents exits before it opens
# anything, because a row for a run that did no work is noise the console and
# the orphan watchdog both have to carry.
#
# JOB_ID is EXPORTED by job_lane_open, so bin/agent-call.sh posts the drafting
# session's dollars onto this row by itself — this script never computes a
# second copy of that figure.
_miner_finish() { # _miner_finish <rc>
  command -v job_lane_close >/dev/null 2>&1 && job_lane_close "${1:-1}" rule-miner
}
# _miner_spend_line — this run's and this week's rule-miner spend out of
# logs/cost.csv, read BY COLUMN NAME from the file's own header (a position is
# what moved under every $NF reader before). Absent is not zero: no rows is
# `none`, and a row with an empty cost_usd makes its figure UNPRICED.
_miner_spend_line() {
  awk -F, -v t0="${RUN_T0:-9999}" -v wk="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["project"] != "rule-miner" { next }
    $c["ts"] >= t0 { rn++; ctx += $c["input_toks"] + $c["cache_read"]
                     if ($c["cost_usd"] == "") ru = 1; else rc += $c["cost_usd"] }
    $c["ts"] >= wk { wn++; if ($c["cost_usd"] == "") wu = 1; else wc += $c["cost_usd"] }
    END {
      printf "context_tokens=%s cost_usd=%s week_spend_usd=%s\n", rn ? ctx : "none",
        !rn ? "none" : ru ? "UNPRICED" : sprintf("%.2f", rc),
        !wn ? "none" : wu ? "UNPRICED" : sprintf("%.2f", wc)
    }' "$HARNESS/logs/cost.csv" 2>/dev/null \
    || echo "context_tokens=none cost_usd=none week_spend_usd=none"
}

DATE=$(date -u +%Y%m%d)
SINCE_D=$(date -u -d '7 days ago' +%Y%m%d)
SINCE_ISO=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
MINDIR="$HARNESS/state/rule-mining/$DATE"
SEEN="$HARNESS/state/rule-mining/seen.txt"; touch "$SEEN"
mkdir -p "$MINDIR"
INV="$MINDIR/inventory.tsv"; : > "$INV"

seen() { grep -qxF "$1" "$SEEN"; }
add_incident() { # add_incident <id> <one-line summary> ; bundle body on stdin
  # Gather loops run in pipe subshells, so the count lives in the inventory
  # file (shared by all of them), never in a shell variable.
  local id="$1" summary="$2" nn slug f
  seen "$id" && { cat > /dev/null; return 0; }
  grep -qF $'\t'"$id"$'\t' "$INV" 2>/dev/null && { cat > /dev/null; return 0; }
  nn=$(printf '%02d' "$(($(wc -l < "$INV") + 1))")
  slug=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-80)
  f="$MINDIR/$nn-$slug.md"
  { printf 'INCIDENT: %s\nSUMMARY: %s\n\n' "$id" "$summary"; cat; } > "$f"
  printf '%s\t%s\t%s\t%s\n' "$nn" "$id" "$f" "$summary" >> "$INV"
}

# ── (a) Reverts: rollback/revert commits across fleet repos, last 7d ─────────
"$SELF/fleet-conf.sh" --projects 2>/dev/null | while IFS= read -r P; do
  SLUG=$("$SELF/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
  printf '%s\t%s\n' "$P" "$SLUG"
done | sort -u -k2,2 > "$MINDIR/.repos"
while IFS=$'\t' read -r P SLUG; do
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  gh api "repos/$SLUG/commits?since=$SINCE_ISO&per_page=100" \
    --jq '.[] | select(.commit.message | split("\n")[0] | test("^(Revert |Rollback)")) | [.sha, .html_url, .commit.message] | @base64' 2>/dev/null \
  | while IFS= read -r ROW; do
      DEC=$(printf '%s' "$ROW" | base64 -d 2>/dev/null | jq -r '.[0] + "\t" + .[1]' 2>/dev/null) || continue
      SHA=${DEC%%$'\t'*}; URL=${DEC#*$'\t'}
      MSG=$(printf '%s' "$ROW" | base64 -d 2>/dev/null | jq -r '.[2]' 2>/dev/null)
      [ -n "$SHA" ] || continue
      add_incident "revert:$SLUG:${SHA:0:12}" "revert/rollback commit in $SLUG ($P)" <<EOF
TYPE: revert
PROJECT: $P
REPO: $SLUG
COMMIT: $SHA
URL: $URL

COMMIT MESSAGE:
$MSG
EOF
    done
done < "$MINDIR/.repos"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
rm -f "$MINDIR/.repos"

# ── (b) Reopens: logs/reopens.csv rows from the last 7d ─────────────────────
REOPENS="$HARNESS/logs/reopens.csv"
if [ -s "$REOPENS" ]; then
  awk -F, -v s="$SINCE_D" 'NR>1 && $1>=s && NF>=5' "$REOPENS" | while IFS=, read -r RD RP RK RF RT; do
    add_incident "reopen:$RP:$RK:$RD" "$RP $RK reopened $RF -> $RT on $RD" <<EOF
TYPE: reopen
PROJECT: $RP
TICKET: $RK
DATE: $RD
STATUS: was "$RF", regressed to "$RT" after we called it $RF

CSV ROW: $RD,$RP,$RK,$RF,$RT
(A reopen means the client came back on work we marked $RF — the shipped change did not hold.)
EOF
  done
fi

# ── (c) Review/refuter/security BLOCKs: build dirs, hub + remote mirrors ─────
find "$HARNESS/builds" "$HARNESS/state/cost/remote-builds" -maxdepth 3 \
  \( -name review.md -o -name refute-review.md -o -name security-review.md \) \
  -mtime -7 2>/dev/null | sort | while IFS= read -r RF; do
  verdict_is BLOCK -L "$RF" 2>/dev/null || continue
  D=$(dirname "$RF"); B=$(basename "$D"); FN=$(basename "$RF")
  RESULT_LINE=$(head -1 "$D/RESULT" 2>/dev/null || echo "(no RESULT file)")
  add_incident "block:$B:$FN" "$FN ended VERDICT: BLOCK in build $B" <<EOF
TYPE: review-block
BUILD: $B
FILE: $RF
RESULT: $RESULT_LINE

BLOCKING VERDICT (findings, tail of $FN):
$(tail -n 60 "$RF" 2>/dev/null)
EOF
done

# ── (c2) REFUTED acceptance claims: evidence.json in build dirs, hub + mirrors ─
# The evidence contract (#527, bin/lib/evidence.sh) scores every plan's
# acceptance claims and writes <build>/evidence.json. A REFUTED claim is the
# build saying one thing and its own artifacts saying another — the same shape
# as a review BLOCK, so it is mined the same way and keyed the same way
# (<kind>:<build>, seen.txt one-shot). Read with jq -r only; nothing under a
# build dir is sourced or eval'd. `numbers` keeps a string-typed count from
# firing: jq orders every string above every number, so a bare `.refuted > 0`
# reads "1" > 0 as true on a file it never parsed as counts.
find "$HARNESS/builds" "$HARNESS/state/cost/remote-builds" -maxdepth 3 \
  -name evidence.json -mtime -7 2>/dev/null | sort | while IFS= read -r EF; do
  jq -e '(.refuted | numbers) > 0' "$EF" >/dev/null 2>&1 || continue
  D=$(dirname "$EF"); B=$(basename "$D")
  RESULT_LINE=$(head -1 "$D/RESULT" 2>/dev/null || echo "(no RESULT file)")
  [ -n "$RESULT_LINE" ] || RESULT_LINE="(no RESULT file)"
  add_incident "refuted:$B" "acceptance claim(s) REFUTED in build $B" <<EOF
TYPE: refuted-claim
BUILD: $B
FILE: $EF
RESULT: $RESULT_LINE

REFUTED CLAIMS (verdict REFUTED, from evidence.json):
$(jq -r '.claims[]? | select(.verdict == "REFUTED") | "CLAIM \(.n): \(.claim) :: \(.artifact) :: \(.note)"' "$EF" 2>/dev/null)
EOF
done

# ── (e) Recurring review findings: logs/findings.log, rolling 30d ───────────
# The other four sources are DAMAGE — a revert, a reopen, a BLOCK. This one is
# REPETITION: bin/findings-log.sh records every review finding with its
# root-cause family key, and a family that keeps coming back is a review comment
# we keep writing. That is a bug in the guardrails, not in that week's build,
# and it is the only source here that can promote into a mechanical check.
#
# 30 days, not 7: three occurrences of the same class inside one week is a busy
# week; three inside a month is a pattern. The window is deliberately wider than
# the rest of this script's.
FINDINGS="$HARNESS/logs/findings.log"
PROMOTE_MIN="${PROMOTE_MIN:-3}"
FREQ="$MINDIR/findings-frequency.tsv"; : > "$FREQ"

# REHYDRATE BEFORE ANYTHING READS OR APPENDS (BH-436). A wiped hub (#388) has no
# findings.log at all, and this lane would then mine an empty feed and report
# "no recurring families" — the dead-feed smell again, one layer down. The
# client is already sourced at the top of this file behind [ -r ... ], so
# `command -v` is the guard; with no client on the box this is a no-op. A
# non-empty file also costs nothing: log_rehydrate makes no request at all.
if command -v log_rehydrate >/dev/null 2>&1; then
  log_rehydrate findings "$FINDINGS" 30 >/dev/null 2>&1 || true
fi

# FEED THE LANE BEFORE READING IT. findings.log is written by run-build.sh, which
# runs on the BOXES — so the hub's copy only ever held the hub's own builds, and
# a "recurring across projects" threshold could never be crossed by remote work.
# A miner reading a feed that structurally cannot fill is the dead-feed smell:
# it returns "no recurring families" forever and looks exactly like good news.
# Source (c) already knows where the remote reviews land (the fly-results-ingest
# mirrors), so harvest those the same way here. Idempotent: findings-log.sh
# keeps a .findings-<lens> marker per build dir, so re-runs add nothing. This
# also backfills hub builds that predate the harvester.
if [ -x "$SELF/findings-log.sh" ]; then
  find "$HARNESS/builds" "$HARNESS/state/cost/remote-builds" -maxdepth 3 \
    \( -name review.md -o -name security-review.md -o -name refute-review.md \) \
    -mtime -30 2>/dev/null | sed 's|/[^/]*$||' | sort -u | while IFS= read -r BD; do
      B=$(basename "$BD")
      # Build dirs are <project>-<KEY>-<UTCstamp>; both project and key contain
      # dashes, so split from the RIGHT: drop the stamp, then the key is the
      # last two dash-fields and the project is whatever is left.
      case "$B" in
        *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) continue ;;
      esac
      BASE="${B%-*}"
      MKEY=$(printf '%s' "$BASE" | awk -F- 'NF>1 {print $(NF-1)"-"$NF}')
      MPROJ="${BASE%-"$MKEY"}"
      [ -n "$MKEY" ] && [ -n "$MPROJ" ] && [ "$MPROJ" != "$BASE" ] || continue
      "$SELF/findings-log.sh" "$BD" "$MPROJ" "$MKEY" >/dev/null 2>&1 || true
    done
fi

# OUTCOMES ARE THE SIXTH FEED, and they arrive through this same file. Sources
# (a)-(e) all measure what the fleet SAID before a merge — a reviewer's finding,
# a BLOCK, a hand-filed note. bin/outcome-metrics.sh measures what happened
# AFTER one: a merged PR that got reverted, whose ticket the client reopened, or
# whose merge commit turned main red. It writes those as findings.log rows with
# their own family keys, so they cross PROMOTE_MIN on exactly the terms every
# other finding does and need no branch of their own here.
#
# Called before the read for the reason stated above: a feed that fills after
# its consumer has run is a feed that never fills. The hub cron also fires it at
# 05:20Z; this call is idempotent (its own seen-file) so whichever ran first,
# the second adds nothing. RULE_MINER_DRY rides through — an operator inspecting
# the inventory must not cause a write to findings.log.
if [ -x "$SELF/outcome-metrics.sh" ]; then
  OUTCOME_DRY="${RULE_MINER_DRY:-0}" HARNESS="$HARNESS" "$SELF/outcome-metrics.sh" >/dev/null 2>&1 || true
fi

if [ -s "$FINDINGS" ]; then
  # BSD fallback keeps this lane runnable (and testable) off the Linux hub.
  SINCE30=$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null \
            || date -u -v-30d +%Y-%m-%d 2>/dev/null || echo 0000-00-00)
  awk -v s="$SINCE30" -v m="$PROMOTE_MIN" '
    $1 >= s {
      fam=""; proj=""; rule="";
      # STOP AT THE `::` SEPARATOR. Everything after it is a reviewer sentence,
      # not metadata — and a finding whose prose quotes "family=abc" was
      # reassigning its own row, because this loop took the LAST match in the
      # whole line. A parser that reads its own payload as metadata is a
      # parser an author can steer.
      for (i = 1; i <= NF; i++) {
        if ($i == "::") break
        else if (substr($i,1,7) == "family=") fam  = substr($i,8)
        else if (substr($i,1,5) == "rule=")   rule = substr($i,6)
        else if (proj == "" && substr($i,1,1) == "[") { proj = $i; gsub(/[][]/,"",proj) }
      }
      # "-" is the fallback findings-log.sh writes when alert_family could not
      # be imported. Counting it would merge every unkeyed finding in the fleet
      # into one enormous fake pattern that always crosses the threshold.
      # (No apostrophes in here: this awk program is single-quoted in bash.)
      if (fam == "" || fam == "-") next
      n[fam]++
      if (index("," projs[fam] ",", "," proj ",") == 0)
        projs[fam] = projs[fam] (projs[fam] == "" ? "" : ",") proj
      if (rule != "-" && rule != "" && index("," rules[fam] ",", "," rule ",") == 0)
        rules[fam] = rules[fam] (rules[fam] == "" ? "" : ",") rule
    }
    END { for (f in n) if (n[f] >= m)
            printf "%s\t%d\t%s\t%s\n", f, n[f], projs[f], (rules[f] == "" ? "-" : rules[f]) }
  ' "$FINDINGS" | sort -t"$(printf '\t')" -k2,2nr > "$FREQ"
fi
# A family is mined ONCE, like every other incident here (seen.txt). If it
# recurs after a drafted check landed, the check was wrong — that is a human
# observation, filed as a manual note, not something to re-draft automatically.
while IFS=$'\t' read -r FAM CNT PROJS RULES; do
  [ -n "$FAM" ] || continue
  add_incident "findings:$FAM" "review-finding family $FAM recurred ${CNT}x in 30d ($PROJS)" <<EOF
TYPE: recurring-finding
FAMILY: $FAM
COUNT_30D: $CNT
PROJECTS: $PROJS
RULES CITED: $RULES
PROMOTE_MIN: $PROMOTE_MIN

OCCURRENCES (up to 10 of $CNT, from logs/findings.log):
$(grep -aF "family=$FAM " "$FINDINGS" 2>/dev/null | tail -10)

(This is repetition, not damage: the same review comment written $CNT times.
Reviewers are catching it every time, which is the system working — and paying
for it every time, which is the system leaking.)
EOF
done < "$FREQ"

# 30-day recurrence of adopted rules (BH-3692). Before the empty-week exit so a quiet week still measures.
if [ "${RULE_MINER_DRY:-0}" = "1" ]; then
  "$SELF/rule-recur.sh" "$FINDINGS" "$HARNESS/prompts/rule-evidence" || true
else
  "$SELF/rule-recur.sh" "$FINDINGS" "$HARNESS/prompts/rule-evidence" >> "$LOG" 2>&1 || true
fi

# ── (g) Archie's repeated card answers (BH-8817), rolling window ─────────────
# REPETITION again, one lane down: Archie answering the same kind of Tackler
# card the same way (the same project, stall class, answer and lever) is a
# decision Tackler could make itself. Each group at or over
# RULE_MINER_ARCHIE_MIN (default 3) answers inside RULE_MINER_ARCHIE_DAYS
# (default 30) is ONE incident. RULE_MINER_ARCHIE_LIMIT (default 50, the
# fallback of the knob catalog/lanes.d/rule-miner.knobs.d/RULE_MINER_ARCHIE_LIMIT.json)
# caps the groups read per run; a run at the cap logs one line, keyed archie-card:<p>:<class>:<answer>:<lever>
# so seen.txt mines it once. The candidate rule goes in
# catalog/unblock-rules.d. No jobs client or no secret = this source is off,
# one log line; a failed read is one log line and no incident.
ARCHIE_MIN="${RULE_MINER_ARCHIE_MIN:-3}"; [[ $ARCHIE_MIN =~ ^[0-9]{1,3}$ ]] && [ "$ARCHIE_MIN" -ge 2 ] && [ "$ARCHIE_MIN" -le 100 ] || ARCHIE_MIN=3
ARCHIE_DAYS="${RULE_MINER_ARCHIE_DAYS:-30}"; [[ $ARCHIE_DAYS =~ ^[0-9]{1,2}$ ]] && [ "$ARCHIE_DAYS" -ge 1 ] && [ "$ARCHIE_DAYS" -le 90 ] || ARCHIE_DAYS=30
ARCHIE_LIMIT="${RULE_MINER_ARCHIE_LIMIT:-50}"; [[ $ARCHIE_LIMIT =~ ^[0-9]{1,3}$ ]] && [ "$ARCHIE_LIMIT" -ge 1 ] && [ "$ARCHIE_LIMIT" -le 200 ] || ARCHIE_LIMIT=50
# A per-run scratch file in /tmp, not under state/: the rows live in
# unblock_decisions and the loop below consumes the list at once (the
# no-state-files ratchet, BH-4159, refuses a new raw state/ writer in bin/).
ARCHIE_REP=$(mktemp /tmp/rule-miner-archie-XXXXXX) || ARCHIE_REP=/dev/null
# shellcheck source=bin/lib/unblock/archie-repeats.sh
if [ -n "${HARNESS_SECRET:-}" ] && command -v _jobs_req >/dev/null 2>&1 \
   && . "$SELF/lib/unblock/archie-repeats.sh" 2>/dev/null; then
  ARCHIE_SINCE=$(date -u -d "$ARCHIE_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  if uar_list "$ARCHIE_SINCE" "$ARCHIE_MIN" "$ARCHIE_LIMIT" > "$ARCHIE_REP"; then
    [ "$(grep -c . "$ARCHIE_REP")" -ge "$ARCHIE_LIMIT" ] \
      && echo "$(STAMP) archie card repeats: read the cap RULE_MINER_ARCHIE_LIMIT=$ARCHIE_LIMIT groups; groups past it wait for a later run" >> "$LOG"
  else
    echo "$(STAMP) archie card repeats unreadable (http ${JOBS_HTTP:-none}); source (g) mined nothing" >> "$LOG"
  fi
else
  echo "$(STAMP) archie card repeats: no jobs client or secret; source (g) off" >> "$LOG"
fi
while IFS=$'\t' read -r AP ACLASS AANS ALEVER ACNT ALAST; do
  [ -n "$AP" ] || continue
  add_incident "archie-card:$AP:$ACLASS:$AANS:$ALEVER" "Archie answered $ACLASS cards of $AP with $AANS ($ALEVER) ${ACNT}x in ${ARCHIE_DAYS}d" <<EOF
TYPE: archie-card-repeat
PROJECT: $AP
STALL_CLASS: $ACLASS
ANSWER: $AANS
LEVER: $ALEVER
COUNT: $ACNT in ${ARCHIE_DAYS}d (threshold RULE_MINER_ARCHIE_MIN=$ARCHIE_MIN)
NEWEST ROW: unblock_decisions id $ALAST

Tackler escalated this stall class to a card, and Archie gave the same answer
each time (bin/archie-cards.sh, answer_source archie). The candidate rule is
one file in catalog/unblock-rules.d that decides this class without a card:
hold or none as a wait or refuse rule, a lever as an act rule through
bin/lib/unblock/act.sh. Not a rule when the answers depend on facts the
collector record does not carry.
EOF
done < "$ARCHIE_REP"
[ "$ARCHIE_REP" = /dev/null ] || rm -f "$ARCHIE_REP"

# ── (d) Manual notes: hand-filed lessons in state/rule-mining/manual/*.md ───
# Anything the fleet learned that no automatic source (revert/reopen/BLOCK)
# would ever surface — orchestrator or the operator drops a .md here and the next
# weekly run drafts a rule from it. seen.txt keeps it one-shot.
if [ -d "$HARNESS/state/rule-mining/manual" ]; then
  find "$HARNESS/state/rule-mining/manual" -maxdepth 1 -type f -name '*.md' | sort | while IFS= read -r NOTE; do
    BASE=$(basename "$NOTE" .md)
    add_incident "manual:$BASE" "hand-filed lesson: $BASE" < "$NOTE"
  done
fi

# add_incident ran in subshells — the inventory file is the truth for count.
N=$(wc -l < "$INV" | tr -d ' ')
if [ "$N" -eq 0 ]; then
  echo "$(STAMP) no unseen incidents in the last 7d (reverts=0 reopens=0 blocks=0 manual=0 after seen-filter) — nothing to mine" >> "$LOG"
  rmdir "$MINDIR" 2>/dev/null || true
  exit 0
fi

# The session reads the DIGEST, never the bundles (BH-1749.2: "Read every
# bundle" was 8.05M input tokens on 2026-09-21). digest-ids.txt is what it
# covered, and the only thing mark_seen may bury.
DIGEST="$MINDIR/digest.md"; DIGEST_IDS="$MINDIR/digest-ids.txt"
FINDLOG="$FINDINGS"; [ -r "$FINDLOG" ] || FINDLOG=/dev/null
"$SELF/rule-miner-digest.sh" "$FINDLOG" "$INV" "$DIGEST" "$DIGEST_IDS"; DRC=$?
if [ "$DRC" -ne 0 ] || [ ! -s "$DIGEST" ]; then
  echo "$(STAMP) [rule-miner] digest failed rc=$DRC — no agent call made; see rule-miner-digest.sh stderr. $N incident(s) left unseen in $MINDIR" >> "$ALERTS"
  echo "$(STAMP) $N incident(s) gathered; digest failed rc=$DRC — no agent call made" >> "$LOG"
  exit 1
fi

# Real incidents exist: claim the lane before anything expensive starts. The
# dry run below deliberately claims nothing — it gathers and prints, it does not
# spend, and an operator inspecting the inventory is not a run to page about.
if [ "${RULE_MINER_DRY:-0}" != "1" ] && command -v job_lane_open >/dev/null 2>&1; then
  job_lane_open "mine/rule-miner/$MINER_RUNNER" "" mine \
    "$(jq -nc --arg l "rule-miner" --argjson n "$N" '{label:$l,incidents:$n}' 2>/dev/null)" >/dev/null 2>&1 || true
  trap 'MINER_RC=$?; _miner_finish "$MINER_RC"' EXIT
fi

if [ "${RULE_MINER_DRY:-0}" = "1" ]; then
  echo "RULE_MINER_DRY=1 — incident inventory for week ending $DATE ($N incident(s)); stopping before the agent call."
  echo "bundles: $MINDIR"
  awk -F'\t' '{printf "  [%s] %s\n      %s\n      bundle: %s\n", $1, $2, $4, $3}' "$INV"
  echo "digest: $DIGEST (~$(( $(wc -c < "$DIGEST") / 4 )) tokens)"
  exit 0
fi

# ── Fresh clone: style source for the drafting session + PR workspace ────────
WT=$(mktemp -d /tmp/rule-miner-XXXXXX)
# The workspace cleanup and the claim close share one EXIT trap; $? is captured
# FIRST because `rm` would otherwise overwrite the exit code the row records.
trap 'MINER_RC=$?; rm -rf "$WT"; _miner_finish "$MINER_RC"' EXIT
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$HARNESS_REPO" || true
if ! gh repo clone "$HARNESS_REPO" "$WT" -- -q 2>/dev/null; then
  echo "$(STAMP) [rule-miner] clone of $HARNESS_REPO failed — cannot draft or open a rules PR; needs gh auth or network (hub)" >> "$ALERTS"
  echo "$(STAMP) clone failed — aborted with $N incident(s) bundled in $MINDIR" >> "$LOG"
  exit 1
fi
DISC="$WT/prompts/build-discipline.md"
# BH-3714: NEXT counts every rules/mined-* branch on origin too, so two unmerged
# weeks never mint one D-number. A failed fetch leaves main's max, the old floor.
git -C "$WT" fetch -q origin '+refs/heads/rules/mined-*:refs/remotes/origin/rules/mined-*' 2>/dev/null || true
# shellcheck source=lib/rule-class.sh
if . "$SELF/lib/rule-class.sh" 2>/dev/null; then NEXT=$(rc_next "$WT")
else NEXT=$(( $(grep -oE '\*\*D[0-9]+' "$DISC" | grep -oE '[0-9]+' | sort -n | tail -1) + 1 )); fi
echo "$(STAMP) NEXT=D$NEXT (main + $(git -C "$WT" for-each-ref 'refs/remotes/origin/rules/mined-*' 2>/dev/null | wc -l | tr -d ' ') open rules/mined-* branch(es))" >> "$LOG"

# ── ONE drafting session (route runner, stage mine) over the digest ─────────
DRAFT="$MINDIR/draft.md"; rm -f "$DRAFT"
# The drafting session is told to read a real catalog as its format and quality
# bar. On 2026-08-26 it was pointed at $HARNESS/guardrails, which does not exist
# on a box — bin/harness-sync.sh deployed only bin/, prompts/ and catalog/ — and
# the session logged "The listed guardrails path isn't there", then drafted no
# check at all. Both paths are resolved HERE, against what is actually on disk,
# and a missing catalog is stated as missing rather than named as if it were
# readable.
for _d in "$HARNESS/guardrails" "$SELF/../guardrails"; do
  [ -d "$_d" ] && { GUARDRAIL_REF="$_d/"; break; }
done
GUARDRAIL_REF="${GUARDRAIL_REF:-(no guardrails/ catalog is present on this box — draft from the shape described above)}"
for _d in "$HARNESS/checks" "$SELF/../checks"; do
  [ -d "$_d" ] && { CHECKS_REF="$_d/"; break; }
done
CHECKS_REF="${CHECKS_REF:-(no checks/ catalog is present on this box)}"
PROMPT="You are the harness's weekly incident-to-rule miner. This week's evidence is $DIGEST — $N incident(s): production reverts, board reopens (a client came back on work we called done), adversarial-review BLOCK verdicts, and acceptance claims the evidence scorer REFUTED (a build's own artifacts contradicting its claim). Read it, and do not open the numbered bundle files or logs/findings.log. Then read $DISC end to end — it is the output format AND the quality bar: every rule in it was mined from a real blocked build, is written in imperative voice, states the failure mode sharply, and cites its incident inline. Your job: decide which of this week's incidents carry a GENERALIZABLE lesson — a mistake class a future build could repeat — and draft at most that many candidate rules. REJECT weather: a one-off infra flake, a vendor outage, an incident whose lesson an existing rule (D1-D$((NEXT - 1))) already covers, or anything too specific to recur is NOT a rule — fewer, sharper rules beat coverage, and 'no rule worth adding this week' is a fully acceptable answer. Never invent facts beyond the bundles; every rule must cite its incident (ticket key, build dir, or revert commit) the way D28/D29 cite TK-64/TK-70. Write your output to $DRAFT and nothing else: EITHER a first line that is exactly NO_RULE followed by one short line per rejected incident saying why it is weather, OR a markdown section starting with the exact header line '## Mined $(date -u +%Y-%m-%d) (rule-miner)' followed by one bullet per rule in the file's exact style: '- **D<n> <imperative title>.** <the rule, sharp and testable, with the incident citation inline>', followed on its own lines by '  CLASS: lint <repo-relative path of the check>' or '  CLASS: judgement', then '  EVIDENCE: <incident id>[, <incident id>…]' (ids exactly as the digest prints them) — numbered consecutively starting at D$NEXT. CLASS: lint only when a check that ALREADY exists on main under bin/, tests/, guardrails/, checks/ or .github/workflows/ enforces the rule and the rule text names that path; everything else is CLASS: judgement. Number the CLASS: lint rules FIRST, then the judgement rules. Do not renumber or edit existing rules, do not modify any repo file, do not commit.

TWO OUTPUT LANES. This week's incidents split into two kinds and each has its own artifact. (1) JUDGMENT-ONLY lessons stay prose — they go in $DRAFT exactly as described above, the lane that has always existed, unchanged. (2) MECHANIZABLE lessons become a CHECK that runs in the project's own CI. Apply the OBJECTIVITY TEST to every 'TYPE: recurring-finding' incident, and to any other incident whose lesson looks enforceable: a lesson is mechanizable ONLY if you can name all three of a MEASURABLE OBSERVATION (something a tool can see in a diff or a file — not something it must judge), a NAMED TOOL that can see it (an eslint no-restricted-syntax / no-restricted-imports rule, a semgrep rule, or a small CI shell step), and an EXPLICIT THRESHOLD (what pattern or count fails). Miss any one of the three and it is judgment-only: write it as prose in $DRAFT and draft NO check. 'Reviewers should think harder about X' is never mechanizable, however often it recurs.

For each mechanizable family write ONE directory $MINDIR/checks/<slug>/ containing exactly: TARGET (one line, the owner/repo this check belongs in — a PROJECT repo, from the incident's PROJECTS field and the fleet's repo slugs; NEVER $HARNESS_REPO, which is refused), the check itself (rule.yml for semgrep, check.sh for a CI step, or eslint.json for an eslint fragment), README.md (what it catches, an APPLICABILITY note naming which repos it fits and what must already exist in the repo before it can be adopted, and its known false positives), WHY.md (the family key, the 30-day count, and 2-3 of the real findings it was mined from), and ci-step.yml (the CI step that runs it). $GUARDRAIL_REF holds hand-written checks in exactly this shape — read one first; it is both the format and the quality bar. $CHECKS_REF is the harness-side sibling catalog (checks the harness itself runs over every diff, detection only) — read its README.md too, and note which of this week's families it ALREADY covers so you do not draft a duplicate.

THE ESCAPE HATCH IS MANDATORY IN EVERY ci-step.yml: the step must be skippable by a 'skip-guardrail' PR label AND must require a written justification (GUARDRAIL_JUSTIFICATION). Both halves — a step missing either one is refused and never becomes a PR. A guardrail with no way out gets deleted the first time it is wrong; a hatch that is a bare label makes the label the whole gate.

Ground everything in the digest: no invented families, no check for a rule nobody has actually broken. Zero mechanizable families is a completely normal week — leave $MINDIR/checks absent. Do not open PRs yourself; the harness does that."

# Pre-call ceiling gate (BH-1749.2): the projected context is everything the
# session is pointed at, bytes/4. FAIL CLOSED — an unreadable catalog, a missing
# lane or a ceiling that is not a positive integer refuses exactly like an over.
PROJECTED=$(( ( $(printf '%s' "$PROMPT" | wc -c) + $(wc -c < "$DIGEST") + $(wc -c < "$DISC" 2>/dev/null || echo 0) \
  + $( [ -f "${CHECKS_REF}README.md" ] && wc -c < "${CHECKS_REF}README.md" || echo 0) ) / 4 ))
CB="${CONTEXT_BUDGETS:-$HARNESS/catalog/context-budgets.json}"
CEIL=$(jq -r 'first(.lanes[] | select(.lane == "rule-miner") | .ceiling_tokens | numbers) // empty' "$CB" 2>/dev/null)
case "$CEIL" in ""|0|*[!0-9]*) CEIL="" ;; esac
if [ -z "$CEIL" ] || [ "$PROJECTED" -gt "$CEIL" ]; then
  echo "$(STAMP) CEILING REFUSED projected=$PROJECTED ceiling=${CEIL:-unknown} — no agent call made" >> "$LOG"
  echo "$(STAMP) [rule-miner] CEILING REFUSED projected=$PROJECTED ceiling=${CEIL:-unknown} ($CB) — lower RULE_MINER_DIGEST_MAX_TOKENS or raise the rule-miner lane's ceiling_tokens in catalog/context-budgets.json; $N incident(s) left unseen in $MINDIR" >> "$ALERTS"
  [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
    && job_event "$JOB_ID" mine CEILING_REFUSED "projected=$PROJECTED ceiling=${CEIL:-unknown}" >/dev/null 2>&1 || true
  exit 1
fi
RUN_T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
(cd "$WT" && AGENT_CALL_RUNNERS="$MINER_RUNNER" "$SELF/agent-call.sh" mine rule-miner "$MINER_MODEL" 1800 "$MINDIR/draft-run.txt" "$PROMPT" >/dev/null 2>&1) || true
SPEND=$(_miner_spend_line)

# ── Lane 2 (mechanizable): drafted checks -> one PR per check, on the TARGET
# project repo. Independent of the prose lane by design: a week can promote a
# check and add no rule, or add a rule and promote nothing. guardrail-promote.sh
# owns the refusals (no TARGET, the harness repo, no check file, a missing or
# label-only escape hatch) and has no merge path at all.
mark_seen() { cat "$DIGEST_IDS" >> "$SEEN"; }
# Partial-success marking. seen.txt is FOREVER: an id written here is never
# mined again. On the paths below the prose lane produced nothing, so marking
# the whole inventory would bury every revert, reopen and BLOCK this week
# collected — incidents no PR anywhere cites — while the alert told a human the
# re-run would pick them up. Mark exactly the families whose check PR actually
# opened (guardrail-promote.sh records them as it goes) and nothing else.
mark_seen_promoted() {
  local f="$MINDIR/checks/.promoted-families"
  [ -s "$f" ] || return 0
  sort -u "$f" >> "$SEEN"
}
NCHECKS=0
if [ -d "$MINDIR/checks" ]; then
  CHECK_URLS=$("$SELF/guardrail-promote.sh" "$MINDIR/checks" 2>/dev/null)
  NCHECKS=$(printf '%s\n' "$CHECK_URLS" | grep -c '^http')
  if [ "$NCHECKS" -gt 0 ]; then
    echo "$(STAMP) $NCHECKS guardrail check PR(s) opened on target repos: $(printf '%s' "$CHECK_URLS" | tr '\n' ' ')" >> "$LOG"
  else
    echo "$(STAMP) [rule-miner] the session drafted checks in $MINDIR/checks but none passed promotion — see the refusal lines above" >> "$ALERTS"
  fi
fi

if [ ! -s "$DRAFT" ]; then
  [ "$NCHECKS" -gt 0 ] && mark_seen_promoted
  echo "$(STAMP) [rule-miner] drafting session produced no $DRAFT — $N incident(s) bundled in $MINDIR unmined; re-run rule-miner.sh after checking the fable lane (draft-run.txt beside the bundles)" >> "$ALERTS"
  echo "$(STAMP) $N incident(s) gathered; agent produced no draft ($NCHECKS check PR(s)) — aborted ${SPEND:-}" >> "$LOG"
  exit 1
fi
if head -1 "$DRAFT" | grep -qx 'NO_RULE'; then
  [ "$NCHECKS" -gt 0 ] && mark_seen_promoted
  [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
    && job_event "$JOB_ID" mine NO_RULE "$N incident(s), $NCHECKS check PR(s)" >/dev/null 2>&1 || true
  echo "$(STAMP) $N incident(s) gathered; agent verdict: no prose rule worth adding this week ($DRAFT); $NCHECKS check PR(s) opened ${SPEND:-}" >> "$LOG"
  exit 0
fi
if ! grep -qE '^\- \*\*D[0-9]+ ' "$DRAFT" || ! head -1 "$DRAFT" | grep -q '^## '; then
  [ "$NCHECKS" -gt 0 ] && mark_seen_promoted
  echo "$(STAMP) [rule-miner] draft at $DRAFT matches neither NO_RULE nor the rule format — human read needed before any PR" >> "$ALERTS"
  echo "$(STAMP) $N incident(s) gathered; draft malformed — no PR opened ${SPEND:-}" >> "$LOG"
  exit 1
fi
NRULES=$(grep -cE '^\- \*\*D[0-9]+ ' "$DRAFT")

# ── Classify each rule (BH-3714): lint-backed rules go in their own PR, which
# the lead lane lands; judgement rules stay in the PR for the operator. Every rule gets
# its evidence record (bin/lib/rule-evidence.sh) before any branch exists.
# Sourced here, not at the top: only a run holding a valid draft needs them.
# shellcheck source=lib/rule-evidence.sh
if ! { . "$SELF/lib/rule-evidence.sh" && . "$SELF/lib/rule-class.sh" && . "$SELF/lib/gh-rest.sh"; } 2>/dev/null; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[rule-miner] cannot source the rule classification libs from $SELF/lib — $NRULES drafted rule(s) left in $DRAFT, no PR opened"
  echo "$(STAMP) $N incident(s), $NRULES rule(s) drafted — classification libs missing, no PR opened ${SPEND:-}" >> "$LOG"
  exit 1
fi
RD="$MINDIR/rules"; rm -rf "$RD" "$MINDIR/evidence"; mkdir -p "$RD" "$MINDIR/evidence"
awk -v d="$RD" '/^- \*\*D[0-9]+ /{ f = sprintf("%s/%02d.md", d, ++n) }
  { sub(/\r$/, ""); print > (n ? f : d "/header.md") }' "$DRAFT"
: > "$MINDIR/draft-lint.md"; : > "$MINDIR/draft-judgement.md"; : > "$MINDIR/lint-ids.txt"
: > "$MINDIR/lint-backed-ds.txt"; : > "$MINDIR/judgement-ds.txt"
NLINT=0; NJUDG=0; CLASSED=""
for RF in "$RD"/[0-9]*.md; do
  D=$(grep -oE '^- \*\*D[0-9]+' "$RF" | head -1 | cut -c5-)
  rc_evidence "$RF" "$INV" > "${RF%.md}.ids" 2>>"$LOG"
  IFS=$'\t' read -r CLS WHY < <(rc_class "$RF" "$WT")
  [ "$CLS" = lint-backed ] && [ ! -s "${RF%.md}.ids" ] && { CLS=judgement; WHY="no evidence"; }
  if [ "$CLS" = lint-backed ]; then CHK=$WHY; WHY="enforced by $CHK, named in the rule text"
    NLINT=$((NLINT + 1)); OUT="$MINDIR/draft-lint.md"; cat "${RF%.md}.ids" >> "$MINDIR/lint-ids.txt"
  else CHK=-; NJUDG=$((NJUDG + 1)); OUT="$MINDIR/draft-judgement.md"; fi
  rc_families "${RF%.md}.ids" "$FINDLOG" > "${RF%.md}.fams"
  EVS=$(paste -sd, "${RF%.md}.ids" | sed 's/,/, /g')
  [ -s "$OUT" ] || cat "$RD/header.md" > "$OUT"
  SFX=" (Evidence: ${EVS:-none}; check: ${CHK/#-/none})" awk '/^[[:space:]]*(CLASS|EVIDENCE):/ { next } { l[++n] = $0 }
    END { while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] (i == n ? ENVIRON["SFX"] : "") }' "$RF" >> "$OUT"
  SRC=$(cut -d: -f1 "${RF%.md}.ids" | awk '!s[$0]++' | paste -sd+)
  if ! re_write "$MINDIR/evidence/$D.json" "$D" "$CLS" "$CHK" "$WHY" "$(date -u +%Y-%m-%d)" "${SRC:-none}" "${RF%.md}.ids" "${RF%.md}.fams"; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[rule-miner] could not write the evidence record for $D ($MINDIR/evidence) — $NRULES drafted rule(s) left in $DRAFT, no PR opened"
    echo "$(STAMP) $N incident(s), $NRULES rule(s) drafted — evidence record for $D failed, no PR opened ${SPEND:-}" >> "$LOG"
    exit 1
  fi
  echo "$D" >> "$MINDIR/$CLS-ds.txt"
  CLASSED="$CLASSED $D=$CLS/$WHY"
done
echo "$(STAMP) classified: $NLINT lint-backed, $NJUDG judgement ($CLASSED )" >> "$LOG"

# ── Open the rules PR — for the operator's approval. NEVER merged from here. ─────────
#
# WHY THIS BLOCK IS FIVE NAMED STEPS AND NOT ONE `if (...)`. On 2026-08-26 the
# miner gathered 58 incidents, drafted D33, and logged "PR creation FAILED" —
# and that was the entire record. The whole sequence was one `&&` chain with
# every stderr sent to /dev/null, so nothing anywhere said WHICH of checkout /
# append / commit / push / create had failed or what git or gh actually said.
# The rules sat in $MINDIR and a human deleted the dangling branch. Every step
# below names itself, keeps its stderr in $PRLOG, and fails into ONE loud
# ALERTS line that says the step, the recovery path, and what the tool said.
RBRANCH="rules/mined-$DATE"
BODY="$MINDIR/pr-body.md"
PRLOG="$MINDIR/pr-step.log"; : > "$PRLOG"

# ONE loud, actionable ALERTS line per failure — never a silent rc. It names the
# step that failed, everything needed to finish by hand, and what the tool said,
# because "PR creation FAILED" with no stderr is indistinguishable from silence.
pr_fail() { # pr_fail <step> <what-to-do>
  local step="$1" hint="$2" said
  said=$(tail -c 700 "$PRLOG" 2>/dev/null | tr '\n\t' '  ' | tr -s ' ')
  echo "$(STAMP) [rule-miner] PR STEP FAILED at '$step' on $HARNESS_REPO — $NRULES drafted rule(s) from $N incident(s) are NOT in any PR. draft=$DRAFT body=$BODY ($(wc -c < "$BODY") bytes, $OMITTED bundle(s) omitted) branch=$RBRANCH steplog=$PRLOG. $hint. git/gh said: ${said:-(nothing on stderr)}" >> "$ALERTS"
  echo "$(STAMP) $N incident(s), $NRULES rule(s) drafted — PR creation FAILED at step '$step' (stderr in $PRLOG) ${SPEND:-}" >> "$LOG"
  [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
    && job_event "$JOB_ID" mine PR_FAILED "step=$step" >/dev/null 2>&1 || true
}

# >>> lint pr
# The lint-backed PR (BH-3714): rules/mined-<date>-lint, off main, holding only
# the lint rules and their evidence records. Same named steps and the same
# pr_fail line as the judgement PR below, which then stacks on this branch.
# Its open-PR read is REST (gh_rest_pr_list); rc 75 is "not known open", so the
# flow goes on to create, and a failed create is loud, never read as success.
LINT_URL=""
if [ "$NLINT" -gt 0 ]; then
  LBRANCH="rules/mined-$DATE-lint"; LDRAFT="$MINDIR/draft-lint.md"; LBODY="$MINDIR/pr-body-lint.md"
  LTITLE="rules: lint-backed, mined week of $DATE"
  if ! [[ $LBRANCH =~ $RE_LINT_HEAD_RE ]]; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[rule-miner] lint branch $LBRANCH does not match RE_LINT_HEAD_RE — no PR opened, $NRULES drafted rule(s) left in $DRAFT"
    exit 1
  fi
  {
    echo "Weekly rule mining (bin/rule-miner.sh): $NLINT lint-backed rule(s) from $N incident(s) ending $DATE. Each is enforced by a check already on main, and the rule text names it."
    echo
    echo "This PR merges through the lead lane once a lead MERGE stands on its head; nobody merges it by hand."
    echo
    while IFS= read -r D; do
      echo "- $D: check \`$(re_field "$MINDIR/evidence/$D.json" .check)\`; evidence $(re_field "$MINDIR/evidence/$D.json" '.incidents | join(", ")'); record \`$RE_DIR/$D.json\`"
    done < "$MINDIR/lint-backed-ds.txt"
    echo; echo "## Rules"; echo; cat "$LDRAFT"; echo
    echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  } > "$LBODY"
  lint_fail() { RBRANCH="$LBRANCH" BODY="$LBODY" DRAFT="$LDRAFT" NRULES="$NLINT" OMITTED=0 pr_fail "$@"; exit 1; }
  lint_adopt() { gh_rest_pr_list "$HARNESS_REPO" open "${HARNESS_REPO%%/*}:$LBRANCH" 5 2>>"$PRLOG" | jq -r '.[0].html_url // empty' 2>>"$PRLOG"; }
  # Step 0 — an open lint PR is adopted, and its branch checked out so the
  # judgement branch still stacks on it.
  LINT_URL=$(lint_adopt)
  if [ -n "$LINT_URL" ]; then
    echo "$(STAMP) lint PR for $LBRANCH was already open, adopted: $LINT_URL" >> "$LOG"
    (cd "$WT" && git fetch -q origin "$LBRANCH" && git checkout -qB "$LBRANCH" FETCH_HEAD) 2>>"$PRLOG" \
      || echo "$(STAMP) could not fetch $LBRANCH — judgement branch cut from main" >> "$LOG"
  else
    # Step 1 — branch, off main.
    (cd "$WT" && git checkout -qb "$LBRANCH") 2>>"$PRLOG" \
      || lint_fail "git checkout -b $LBRANCH" "re-run rule-miner.sh, or apply $LDRAFT to prompts/build-discipline.md by hand"
    # Step 2 — the append plus the lint evidence records, one commit.
    (cd "$WT" && mkdir -p "$RE_DIR" \
      && while IFS= read -r D; do cp "$MINDIR/evidence/$D.json" "$RE_DIR/" || exit 1; done < "$MINDIR/lint-backed-ds.txt" \
      && { printf '\n'; cat "$LDRAFT"; } >> prompts/build-discipline.md \
      && git add prompts/build-discipline.md "$RE_DIR" \
      && git -c user.name="rule-miner" -c user.email="harness@box" commit -qm "$LTITLE") 2>>"$PRLOG" \
      || lint_fail "git commit" "re-run rule-miner.sh, or append $LDRAFT and $MINDIR/evidence by hand"
    # Step 3 — push; --force-with-lease only on the miner-owned namespace.
    if ! (cd "$WT" && git push origin "$LBRANCH") 2>>"$PRLOG"; then
      echo "$(STAMP) [rule-miner] plain push of $LBRANCH rejected — retrying with --force-with-lease (miner-owned branch namespace)" >> "$LOG"
      (cd "$WT" && git push --force-with-lease origin "HEAD:refs/heads/$LBRANCH") 2>>"$PRLOG" \
        || lint_fail "git push origin $LBRANCH" "check gh auth and the credential helper on the hub (gh auth setup-git), then re-run"
    fi
    # Step 4 — the PR; a create that fails because it exists adopts it.
    # >>> pr trailers (BH-3987)
    [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
    if command -v pr_trailers_apply >/dev/null 2>&1; then
      pr_trailers_apply "$LBODY" lane:rule-miner none \
        || echo "$(STAMP) [rule-miner] pr trailers: could not write $LBODY — PR opened without trailers" >> "$LOG"
    fi
    LINT_URL=$(cd "$WT" && gh pr create -R "$HARNESS_REPO" -B main -H "$LBRANCH" -t "$LTITLE" --body-file "$LBODY" 2>>"$PRLOG")
    # <<< pr trailers
    [ -n "$LINT_URL" ] || LINT_URL=$(lint_adopt)
    [ -n "$LINT_URL" ] || lint_fail "gh pr create" "the branch IS pushed — finish with: gh pr create -R $HARNESS_REPO -B main -H $LBRANCH -t '$LTITLE' --body-file $LBODY"
  fi
  if [ "$NJUDG" -eq 0 ]; then
    mark_seen
    [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
      && job_event "$JOB_ID" mine PR_OPENED "$NLINT rule(s) from $N incident(s): lint=$LINT_URL judgement=none" >/dev/null 2>&1 || true
    echo "$(STAMP) $N incident(s) -> $NLINT lint-backed rule(s) (D$NEXT+) — lint PR for the lead lane: $LINT_URL ${SPEND:-}" >> "$LOG"
    echo "$LINT_URL"
    command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
    exit 0
  fi
  # Lint open, judgement not yet: the lint-cited ids are cited in an open PR now.
  sort -u "$MINDIR/lint-ids.txt" >> "$SEEN"
fi
# <<< lint pr

# The judgement PR: the two blocks below, fed the judgement rules only.
DRAFT="$MINDIR/draft-judgement.md"; NRULES=$NJUDG

# THE 2026-08-26 ROOT CAUSE. GitHub rejects a pull request body over 65,536
# characters with a 422 and creates nothing; `gh pr create` then prints that to
# stderr and exits nonzero. That week's body was 77,148 characters — 58 incident
# bundles at up to 1,800 bytes each — so the PR was refused by size alone, and
# it would have been refused again on every re-run. The body is now assembled
# under a budget: the drafted RULES always ride in full (they are the point),
# and evidence bundles are appended only while they fit. What did not fit is
# named and counted rather than silently dropped — the bundles are all on the
# hub at $MINDIR either way.
BODY_MAX="${RULE_MINER_BODY_MAX:-60000}"
# >>> pr body
{
  echo "Weekly incident-to-rule mining (trust-7, bin/rule-miner.sh). $NRULES candidate rule(s) drafted from $N incident(s) ending $DATE — reverts, reopens, review BLOCK verdicts, hand-filed notes, and review-finding families that recurred ${PROMOTE_MIN}+ times in 30 days. **For the operator's approval: the miner never merges.**"
  echo
  echo "Nothing merges these without a human: no lane lands a \`rules/mined-<date>\` PR, and this one carries no lead-lane marker."
  if [ -n "${LINT_URL:-}" ]; then
    echo
    echo "This branch is stacked on the lint-backed PR $LINT_URL, so its rules show in this diff too and land with whichever merges first."
  fi
  if [ "$NCHECKS" -gt 0 ]; then
    echo
    echo "Same run, mechanizable lane: **$NCHECKS guardrail check PR(s)** opened on target project repos (never merged either) — $(printf '%s' "$CHECK_URLS" | tr '\n' ' ')"
  fi
  echo
  echo "## Drafted rules"
  echo
  cat "$DRAFT"
  echo
  echo "## Incident evidence"
} > "$BODY"
OMITTED=0
while IFS=$'\t' read -r NN ID F SUMMARY; do
  # -c drops any byte sequence `head -c` cut mid-character; invalid UTF-8 in a
  # request body is a second way to earn a 422 for reasons nobody can see.
  CHUNK=$(printf '\n### [%s] %s\n%s\n\n```\n%s\n```\n' "$NN" "$ID" "$SUMMARY" \
    "$(head -c 1800 "$F" 2>/dev/null | iconv -f utf-8 -t utf-8 -c 2>/dev/null)")
  if [ $(( $(wc -c < "$BODY") + $(printf '%s' "$CHUNK" | wc -c) )) -gt "$BODY_MAX" ]; then
    OMITTED=$((OMITTED + 1)); continue
  fi
  printf '%s' "$CHUNK" >> "$BODY"
done < "$INV"
{
  echo
  if [ "$OMITTED" -gt 0 ]; then
    echo "_$OMITTED of $N incident bundle(s) are omitted here: the full body exceeded GitHub's 65,536-character limit. Every bundle, untruncated, is on the hub at \`$MINDIR\` (inventory: \`inventory.tsv\`). Nothing was dropped from the drafted rules above._"
    echo
  fi
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
} >> "$BODY"
# <<< pr body

# The judgement evidence records ride in the judgement commit (step 2 below).
if ! (mkdir -p "$WT/$RE_DIR" && while IFS= read -r D; do cp "$MINDIR/evidence/$D.json" "$WT/$RE_DIR/" || exit 1; done < "$MINDIR/judgement-ds.txt") 2>>"$PRLOG"; then
  pr_fail "copy evidence records" "re-run rule-miner.sh; the records are in $MINDIR/evidence"
  exit 1
fi

# >>> pr steps
# Step 0 — idempotent re-run. The alert above tells a human to "re-run", and a
# re-run that duplicated the PR (or died on an existing branch) would make that
# advice a trap. An already-open PR for this week's branch IS the success state.
PR_URL=$(gh pr list -R "$HARNESS_REPO" --head "$RBRANCH" --state open \
  --json url -q '.[0].url' 2>>"$PRLOG")
if [ -n "$PR_URL" ]; then
  echo "$(STAMP) $N incident(s), $NRULES rule(s) — PR for $RBRANCH was already open, adopted: $PR_URL ${SPEND:-}" >> "$LOG"
else
  # Step 1 — branch.
  if ! (cd "$WT" && git checkout -qb "$RBRANCH") 2>>"$PRLOG"; then
    pr_fail "git checkout -b $RBRANCH" "the clone at \$WT is gone by now; re-run rule-miner.sh, or apply $DRAFT to prompts/build-discipline.md by hand"
    exit 1
  fi
  # Step 2 — append the draft and commit it.
  if ! (cd "$WT" \
        && { printf '\n'; cat "$DRAFT"; } >> prompts/build-discipline.md \
        && git add prompts/build-discipline.md && { [ ! -d "${RE_DIR:-prompts/rule-evidence}" ] || git add "${RE_DIR:-prompts/rule-evidence}"; } \
        && git -c user.name="rule-miner" -c user.email="harness@box" \
             commit -qm "rules: mined from $N incidents week of $DATE") 2>>"$PRLOG"; then
    pr_fail "git commit" "re-run rule-miner.sh, or append $DRAFT to prompts/build-discipline.md by hand"
    exit 1
  fi
  # Step 3 — push. A plain push first; a rejection falls back to
  # --force-with-lease, which is safe HERE and only here: rules/mined-<date> is
  # a namespace only this script ever writes, one branch per week, and the only
  # thing that can be sitting on it is this same script's earlier attempt.
  if ! (cd "$WT" && git push origin "$RBRANCH") 2>>"$PRLOG"; then
    echo "$(STAMP) [rule-miner] plain push of $RBRANCH rejected — retrying with --force-with-lease (miner-owned branch namespace)" >> "$LOG"
    if ! (cd "$WT" && git push --force-with-lease origin "HEAD:refs/heads/$RBRANCH") 2>>"$PRLOG"; then
      pr_fail "git push origin $RBRANCH" "check gh auth and the credential helper on the hub (gh auth setup-git), then re-run"
      exit 1
    fi
  fi
  # Step 4 — the PR. stderr is CAPTURED, not discarded: this is the step that
  # failed on 2026-08-26 and the message it printed was the whole diagnosis.
  # >>> pr trailers (BH-3987)
  [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$BODY" lane:rule-miner none \
      || echo "$(STAMP) [rule-miner] pr trailers: could not write $BODY — PR opened without trailers" >> "$LOG"
  fi
  PR_URL=$(cd "$WT" && gh pr create -R "$HARNESS_REPO" -B main -H "$RBRANCH" \
    -t "rules: mined from $N incidents week of $DATE" \
    --body-file "$BODY" 2>>"$PRLOG")
  # <<< pr trailers
  if [ -z "$PR_URL" ]; then
    # gh also fails when a PR for this head already exists — that is success
    # wearing an error's clothes (bin/run-build.sh adopts the same way).
    PR_URL=$(gh pr list -R "$HARNESS_REPO" --head "$RBRANCH" --state open \
      --json url -q '.[0].url' 2>>"$PRLOG")
    [ -n "$PR_URL" ] && echo "$(STAMP) [rule-miner] pr create failed but an open PR exists on $RBRANCH — adopted $PR_URL ${SPEND:-}" >> "$LOG"
  fi
  if [ -z "$PR_URL" ]; then
    pr_fail "gh pr create" "the branch IS pushed — finish with: gh pr create -R $HARNESS_REPO -B main -H $RBRANCH -t 'rules: mined from $N incidents week of $DATE' --body-file $BODY"
    exit 1
  fi
fi
# <<< pr steps

# Only now are these incidents "cited in an open rules PR" — record them.
mark_seen
[ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
  && job_event "$JOB_ID" mine PR_OPENED "$NRULES rule(s) from $N incident(s): lint=${LINT_URL:-none} judgement=$PR_URL" >/dev/null 2>&1 || true
echo "$(STAMP) $N incident(s) -> $NLINT lint-backed + $NRULES judgement rule(s) drafted (D$NEXT+) — lint PR: ${LINT_URL:-none}; judgement PR awaiting the operator: $PR_URL ${SPEND:-}" >> "$LOG"
[ -n "$LINT_URL" ] && echo "$LINT_URL"
echo "$PR_URL"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
