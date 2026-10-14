#!/bin/bash
# Goodhart audit (2026-08-18, graph-engineering review): "tickets cleared" is
# gameable — the reality anchor is whether the client comes BACK. Daily hub
# cron snapshots every board's {key,status,waitingOn} and counts REOPENS: a
# ticket that was review/done in a prior snapshot and has regressed to an
# earlier status (or done -> anything not done). Rows append to
# logs/reopens.csv; a rolling 14d rate per project lands in
# state/reopen-rate.json (reopens vs merges, both windowed to the same 14d), so the
# scorecard reads outcome, not output. Measure-only here: the DEMOTION this
# feeds lives in run-build.sh's tier gate (Wave D, 2026-08-25).
#
# Fleet generalization (Wave D, 2026-08-25): the project list came from a
# hardcoded four-name loop, so every project enrolled since — and every one
# enrolled next — was measured at zero and read as perfectly trusted. The list
# is now fleet.conf (bin/fleet-conf.sh --projects), and the two board KINDS are
# handled separately:
#   * app-board projects (fleet.conf board-api-prefix is a path): unchanged —
#     daily {key,status} snapshot, status-rank diff against yesterday.
#   * GitHub-Issues projects (board-api-prefix "-"): issue events via gh —
#     a `reopened` event, or the ai-build label re-added while the issue is
#     closed. Same logs/reopens.csv schema, same state/reopen-rate.json shape.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
BIN="$(cd "$(dirname "$0")" && pwd)"
SNAPDIR="$H/state/board-snapshots"
CSV="$H/logs/reopens.csv"
TODAY=$(date -u +%Y%m%d)
mkdir -p "$SNAPDIR" "$H/logs" "$H/state"
[ -s "$CSV" ] || echo "date,project,key,from,to" > "$CSV"

set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-reopen-metrics
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off reopen-metrics.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit reopen-metrics
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    reopen-metrics

# GitHub reads run on the example-org fine-grained admin PAT when present: it
# covers project-5 + project-4 issues, which the shared operator PAT cannot see.
if [ -f "$HENV/github-admin.env" ]; then
  set -a; . "$HENV/github-admin.env"; set +a
  [ -n "${GH_ADMIN_TOKEN:-}" ] && export GH_TOKEN="$GH_ADMIN_TOKEN"
fi
# App token per repo (#425): sourced AFTER the admin block so gh_auth_reset puts
# back the admin PAT this lane deliberately switches to, not the one before it.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"

# GNU date on the hub; the -v form keeps this runnable on a dev Mac so the
# window arithmetic can be checked without a Linux box.
SINCE=$(date -u -d '14 days ago' +%Y%m%d 2>/dev/null || date -u -v-14d +%Y%m%d)
SINCE_ISO=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)

shift_day() { # shift_day <YYYYMMDD> <+N|-N days> -> YYYYMMDD (echoes input if it cannot)
  date -u -d "$1 $2 days" +%Y%m%d 2>/dev/null \
    || date -u -j -v"$2"d -f %Y%m%d "$1" +%Y%m%d 2>/dev/null \
    || printf '%s' "$1"
}
prev_day() { shift_day "$1" -1; }
next_day() { shift_day "$1" +1; }

# board_conn <project> — sets BASE TOKEN BP for an app board; rc 1 when any is
# missing or the board is GitHub Issues. Loads the project env, so call it in a
# subshell (snapshot() and the reason pass both do).
board_conn() {
  local P=$1
  set -a; [ -f "$HENV/$P.env" ] && . "$HENV/$P.env"; set +a
  case "$P" in
    project-1)   BASE="${PROJECT_1_API_BASE:-}"; TOKEN="${PROJECT_1_INTERNAL_API_TOKEN:-}"; BP="/api/board" ;;
    project-2) BASE="${PROJECT_2_APP_BASE:-}";       TOKEN="${PROJECT_2_INTERNAL_API_TOKEN:-}";       BP="/api/board" ;;
    project-3)       BASE="${PROJECT_3_APP_BASE:-}";     TOKEN="${PROJECT_3_INTERNAL_API_TOKEN:-}";     BP="/api/feature-board" ;;
    project-4)       BASE="${PROJECT_4_API_BASE:-}";     TOKEN="${PROJECT_4_INTERNAL_API_TOKEN:-}";     BP="/api/accounting/requests-board" ;;
    # Projects enrolled after the four originals carry no bespoke env-var names
    # here. Resolve from the registry + the project's own env file instead: the
    # prod URL is fleet.conf column 3, the board prefix column 4, and the token
    # is whatever *_INTERNAL_API_TOKEN that env file defines. A project whose
    # env file names its token differently resolves to empty and is skipped
    # loudly (ALERTS) rather than counted as zero reopens.
    *)
      BASE=$("$BIN/fleet-conf.sh" "$P" prod 2>/dev/null); [ "$BASE" = "-" ] && BASE=""
      BP=$("$BIN/fleet-conf.sh" "$P" board_prefix 2>/dev/null)
      TOKEN=$(awk -F= '/^(export[[:space:]]+)?[A-Z0-9_]*INTERNAL_API_TOKEN=/{sub(/^export[[:space:]]+/,"");
               v=$0; sub(/^[^=]*=/,"",v); gsub(/^["'"'"']|["'"'"']$/,"",v); print v; exit}' \
               "$HENV/$P.env" 2>/dev/null)
      [ -n "$TOKEN" ] || TOKEN="${INTERNAL_TOKEN:-}"
      ;;
  esac
  [ -n "$BASE" ] && [ -n "$TOKEN" ] && [ -n "$BP" ] && [ "$BP" != "-" ]
}

snapshot() { # snapshot <project> -> prints JSON [{key,id,status,waitingOn}] or nothing
  local P=$1 BASE TOKEN BP
  board_conn "$P" || return 1
  local ids bid out='[]'
  ids=$(curl -sf -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASE$BP/boards" \
    | jq -r '(.boards? // .) | .[]?.id') || return 1
  [ -n "$ids" ] || return 1
  while IFS= read -r bid; do
    local page
    page=$(curl -sf -m 30 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASE$BP/boards/$bid/tickets" \
      | jq -c '[(.tickets? // .) | .[]? | {key: (.key // ("#" + ((.number // 0)|tostring))), id: (.id // null), status, waitingOn}]') || return 1
    out=$(jq -c --argjson p "$page" '. + $p' <<<"$out") || return 1
  done <<<"$ids"
  printf '%s' "$out"
}

RANK() { # earlier-ness of a status; higher = further along
  case "$1" in
    done) echo 4 ;; review) echo 3 ;; in_progress) echo 2 ;; todo|open) echo 1 ;; *) echo 2 ;;
  esac
}

# >>> gh reopen decision
# gh_reopens_from_events <events-json-file> <since-iso> <build-label>
#   -> lines "YYYYMMDD<TAB>#<issue-number>", deduped.
#
# The GitHub analogue of the status-rank diff. A board ticket regresses in
# STATUS; an issue regresses in EVENTS, and there are exactly two shapes worth
# counting:
#   * `reopened` — the literal thing. An issue cannot be reopened without
#     having been closed, so no prior `closed` event has to be in the page for
#     this to be trustworthy.
#   * `labeled` with the build label while the issue is CLOSED — the client
#     re-queued shipped work. This one DOES need the close in the page, so an
#     unknown prior state counts as not-closed: under-counting is the safe
#     direction for a signal that only ever removes autonomy.
# ONE BOUNCE IS ONE REOPEN. A single client bounce usually fires BOTH signals
# minutes apart — the label goes back on and the issue is reopened — and if
# those minutes happen to straddle midnight the two land on different dates,
# which a same-string dedup cannot see. That is not a rounding error: one
# bounce becoming 2/12 = 0.17 crosses the 0.15 demotion threshold on its own.
# So candidates are collapsed PER ISSUE within a 24h refractory window, keeping
# the earliest, before any date is ever derived.
#
# Split out as a function so a fixture can drive it with no network: the whole
# decision is here, and the caller only supplies the page.
gh_reopens_from_events() {
  jq -r --arg since "$2" --arg label "$3" '
    map(select(.created_at != null and (.issue.number // null) != null))
    | sort_by(.created_at)
    | reduce .[] as $e ({closed:{}, out:[]};
        ($e.issue.number|tostring) as $n
        | if $e.event == "closed" then .closed[$n] = true
          elif $e.event == "reopened" then
            (if $e.created_at >= $since then .out += [[$e.created_at, $n]] else . end)
            | .closed[$n] = false
          elif $e.event == "labeled" and (($e.label.name // "") == $label) and (.closed[$n] == true) then
            (if $e.created_at >= $since then .out += [[$e.created_at, $n]] else . end)
          else . end)
    | .out
    # 24h refractory collapse, per issue, on the TIMESTAMP — not the date.
    | reduce .[] as $c ({last:{}, keep:[]};
        ($c[0] | fromdateiso8601) as $t
        | if (.last[$c[1]] == null) or (($t - .last[$c[1]]) > 86400)
          then .last[$c[1]] = $t | .keep += [$c]
          else . end)
    | .keep[] | ((.[0][0:10] | gsub("-";"")) + "\t#" + .[1])
  ' "$1" 2>/dev/null | sort -u
}
# <<< gh reopen decision

gh_events_page() { # gh_events_page <slug> <page> -> JSON array (or nothing)
  gh api -H "Accept: application/vnd.github+json" \
    "repos/$1/issues/events?per_page=100&page=$2" 2>/dev/null
}

gh_reopens() { # gh_reopens <project> <slug> -> writes CSV rows; rc 1 = could not read
  local P=$1 SLUG=$2 PAGE=1 OLDEST EV TMP
  command -v gh >/dev/null 2>&1 || return 1
  TMP=$(mktemp); : > "$TMP"
  # /issues/events is most-recent-first, so walk pages until one predates the
  # window. Capped at 5 pages (500 events): a bounded read that costs the same
  # on a busy repo as a quiet one, and the daily cadence means the window is
  # only ever a few days of real traffic.
  while [ "$PAGE" -le 5 ]; do
    EV=$(gh_events_page "$SLUG" "$PAGE") || { rm -f "$TMP"; return 1; }
    [ -n "$EV" ] || break
    [ "$(jq -r 'length' <<<"$EV" 2>/dev/null || echo 0)" -gt 0 ] || break
    jq -c '.[]' <<<"$EV" >> "$TMP" 2>/dev/null
    OLDEST=$(jq -r '[.[].created_at] | min // ""' <<<"$EV" 2>/dev/null)
    [ -n "$OLDEST" ] && [ "$OLDEST" \< "$SINCE_ISO" ] && break
    PAGE=$((PAGE + 1))
  done
  # THREE OUTCOMES, not two. A repo that answered with no events is measured
  # and quiet — 0 reopens, and correct. Only a repo we could not READ is a
  # failure, and only that one gets the alert; collapsing the two would page
  # on every quiet week and teach everyone to ignore the line.
  [ -s "$TMP" ] || { rm -f "$TMP"; return 0; }
  local ARR; ARR=$(mktemp)
  jq -s '.' "$TMP" > "$ARR" 2>/dev/null || { rm -f "$TMP" "$ARR"; return 1; }
  # Idempotence: this runs daily over a 14-day window, so without a
  # dedup every past reopen would be re-appended every night and the rate
  # would climb on its own. The CSV itself is the ledger.
  #
  # The guard spans the ADJACENT day as well as the same one. The refractory
  # collapse above keeps the earliest of a pair, which is stable only while
  # both events are still in the fetched pages; on a repo busy enough to push
  # the earlier one past the 5-page cap, the later half would come back as a
  # fresh "first" and write a second row for a bounce already recorded. Two
  # layers because one bounce becoming two rows is the difference between
  # under the threshold and demoted.
  gh_reopens_from_events "$ARR" "$SINCE_ISO" "${REOPEN_GH_LABEL:-ai-build}" | while IFS=$'\t' read -r D K; do
    [ -n "$D" ] && [ -n "$K" ] || continue
    if grep -qE "^($D|$(prev_day "$D")|$(next_day "$D")),$P,$K," "$CSV" 2>/dev/null; then continue; fi
    echo "$D,$P,$K,done,open" >> "$CSV"
  done
  rm -f "$TMP" "$ARR"
  return 0
}

# >>> reopen reason (BH-6159): the comments around each reopen, saved as the
# ticket's reopen reason (bin/lib/reopen-reason.sh). jobs-client is sourced
# here, earlier than the BH-117 block, whose own guard then skips it.
if ! command -v job_ledger_put >/dev/null 2>&1 \
   && [ -r "$BIN/jobs-client.sh" ] && [ -r "$BIN/lib/jobs/settings.sh" ]; then
  # shellcheck source=/dev/null
  . "$BIN/jobs-client.sh" >/dev/null 2>&1 || true
fi
# shellcheck source=lib/reopen-reason.sh
. "$BIN/lib/reopen-reason.sh" 2>/dev/null || true
RR_ON=0; command -v rr_on >/dev/null 2>&1 && rr_on && RR_ON=1
RR_RUN=$(mktemp -d); trap 'rm -rf "$RR_RUN"' EXIT
# <<< reopen reason
# >>> revert reason (BH-6160): the failure signal of each revert on a
# project's default branch, saved for the ticket's rebuild
# (bin/lib/revert-reason.sh). Read only; its run files share $RR_RUN.
# shellcheck source=lib/revert-reason.sh
. "$BIN/lib/revert-reason.sh" 2>/dev/null || true
RV_ON=0; command -v rv_on >/dev/null 2>&1 && rv_on && RV_ON=1
RV_SINCE_ISO=""; [ "$RV_ON" = 1 ] && RV_SINCE_ISO=$(rv_since_iso)
# <<< revert reason
PROJECTS=$("$BIN/fleet-conf.sh" --projects 2>/dev/null)
# Fail-open to the original four rather than measuring nothing — but SAY SO.
# A fallback that runs silently is worse than no fallback: the rate rows for
# the four keep updating from the CSV, so the JSON looks healthy while every
# project enrolled since goes unmeasured, and the only symptom would be a
# reopen count that stopped moving. The four also route explicitly to the
# snapshot lane: with no registry, a board_prefix lookup fails, "-" would
# divert them to the GitHub lane, the repo lookup would fail too, and all four
# would `continue` without a word.
REGISTRY_OK=1
if [ -z "$PROJECTS" ]; then
  REGISTRY_OK=0
  PROJECTS="project-1 project-2 project-3 project-4"
  HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] fleet.conf unreadable — fell back to the four original projects; every project enrolled since is UNMEASURED this run"
fi

for P in $PROJECTS; do
  if [ "$RV_ON" = 1 ] && [ -n "$RV_SINCE_ISO" ]; then
    RV_SLUG=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null)
    if [ -n "$RV_SLUG" ] && [ "$RV_SLUG" != "-" ]; then
      ( RV_RUN="$RR_RUN" rv_capture "$P" "$RV_SLUG" "$RV_SINCE_ISO" )
    fi
  fi
  if [ "$REGISTRY_OK" = 0 ]; then
    BP="app-board"   # snapshot() carries these four prefixes itself
  else
    BP=$("$BIN/fleet-conf.sh" "$P" board_prefix 2>/dev/null || echo "-")
  fi
  if [ "$BP" = "-" ]; then
    SLUG=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null)
    if [ -z "$SLUG" ] || [ "$SLUG" = "-" ]; then
      HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] $P has no board API and no repo slug — unmeasurable, skipped"
      continue
    fi
    # Once per repo, at the loop top: gh_reopens walks up to 5 event pages, so
    # arming inside it would fork a mint per page.
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
    gh_reopens "$P" "$SLUG" \
      || HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] $P gh issue events unreadable — skipped"
    [ "$RR_ON" = 1 ] && ( RR_RUN="$RR_RUN" rr_capture_rows "$P" gh "$SINCE" "$CSV" "$SLUG" )
    command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
    continue
  fi
  SNAP=$(snapshot "$P") || { HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] $P snapshot failed — skipped"; continue; }
  PDIR="$SNAPDIR/$P"; mkdir -p "$PDIR"
  printf '%s' "$SNAP" > "$PDIR/$TODAY.json"
  PREV=$(ls "$PDIR" | grep -E '^[0-9]{8}\.json$' | sort | tail -2 | head -1)
  # No earlier snapshot: diff today against itself (no rows), so the reason
  # pass below still runs for the rows already in the CSV.
  [ -n "$PREV" ] && [ "$PREV" != "$TODAY.json" ] || PREV="$TODAY.json"
  # A reopen = status rank fell from >=3 (review/done) to <3.
  jq -nr --argjson old "$(cat "$PDIR/$PREV")" --argjson new "$SNAP" '
    ($old | map({(.key): .status}) | add // {}) as $o
    | $new[] | select($o[.key] != null)
    | select((($o[.key] == "done") or ($o[.key] == "review"))
             and (.status != "done") and (.status != "review"))
    | [.key, $o[.key], .status] | @csv' 2>/dev/null | while IFS= read -r ROW; do
    echo "$TODAY,$P,$(tr -d '"' <<<"$ROW")" >> "$CSV"
  done
  [ "$RR_ON" = 1 ] && ( board_conn "$P" && RR_BASE="$BASE" RR_TOKEN="$TOKEN" RR_BP="$BP" RR_RUN="$RR_RUN" \
    rr_capture_rows "$P" app "$SINCE" "$CSV" "$PDIR/$TODAY.json" )
  # keep 30 snapshots per project
  ls "$PDIR" | sort | head -n -30 | while read -r F; do rm -f "$PDIR/$F"; done
done

[ "$RR_ON" = 1 ] && RR_RUN="$RR_RUN" rr_capture_report
[ "$RV_ON" = 1 ] && RV_RUN="$RR_RUN" rv_capture_report

# Rolling 14d rate per project: reopens vs merged builds (metrics.csv PR_MERGED
# plus merge-sweep ledger lines are approximated by PR_CREATED+PR_MERGED kinds).
# BOTH sides are windowed to $SINCE (BH-115). builds_total used to count every
# PR-shaped build ever, so the rate only diluted as history grew: at 500
# lifetime builds a project needed 75 reopens in 14 days to cross 0.15, and the
# demoter could never fire on a mature project. The key keeps its name so the
# file, the D1 row and every reader stay the same shape, but it now means
# "PR-shaped builds dated on or after $SINCE". A metrics.csv row is dated by
# merged_at, else pr_at, else started, else run-build's -YYYYMMDDHHMM build_dir
# suffix; a build dir by that suffix, else its RESULT's mtime. A build with no
# date from any of those is NOT counted: it cannot be shown to be in the window.
{
  echo '{'
  FIRST=1
  for P in $PROJECTS; do
    RE=$(awk -F, -v p="$P" -v s="$SINCE" 'NR>1 && $2==p && $1>=s' "$CSV" 2>/dev/null | wc -l)
    MG=$(awk -F, -v p="$P" -v s="$SINCE" '
      function day(x) { gsub(/-/, "", x); x = substr(x, 1, 8); return (x ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/) ? x : "" }
      NR>1 && $2==p && ($7=="PR_MERGED" || $7=="PR_CREATED") {
        d = day($6 != "" ? $6 : ($5 != "" ? $5 : $4))
        if (d == "" && match($1, /-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/)) d = day(substr($1, RSTART+1))
        if (d != "" && d >= s) n++
      }
      END { print n+0 }' "$H/logs/metrics.csv" 2>/dev/null)
    # metrics-collect.sh derives its project column from a regex over the four
    # original -os names, so every other project has ZERO rows there however
    # many builds it ran. Counting build dirs with a PR-shaped RESULT is the
    # cheapest local source that is actually true for them; it is a fallback,
    # not a replacement, so the four originals keep the exact denominator they
    # have always reported.
    # The glob is a PREFIX, and project names nest: builds/project-10-nav-*
    # matches builds/project-10-* too, which would silently credit one
    # project's builds to another's denominator. Longer registry names that
    # start with this one are subtracted back out. (Over-counting only ever
    # lowers the rate, so this errs toward fewer demotions either way — but a
    # denominator that is wrong is not worth defending.)
    if [ "${MG:-0}" -eq 0 ]; then
      SIBS=$(printf '%s\n' $PROJECTS | grep -E "^$P-" || true)
      MG=$(grep -lsE '^(PR_MERGED|PR_CREATED)' "$H/builds/$P-"*/RESULT 2>/dev/null \
           | { if [ -n "$SIBS" ]; then grep -vE "/builds/($(printf '%s\n' "$SIBS" | paste -sd'|' -))-"; else cat; fi; } \
           | while IFS= read -r RF; do
               BD=${RF%/RESULT}; BD=${BD##*/}
               if [[ $BD =~ -([0-9]{12})$ ]]; then BD=${BASH_REMATCH[1]:0:8}
               else BD=$(date -u -r "$RF" +%Y%m%d 2>/dev/null); fi
               [[ $BD =~ ^[0-9]{8}$ ]] && [ "$BD" -ge "$SINCE" ] && echo "$RF"
             done \
           | wc -l)
    fi
    [ "$FIRST" = 1 ] || echo ','
    FIRST=0
    printf '  "%s": {"reopens_14d": %d, "builds_total": %d}' "$P" "${RE:-0}" "${MG:-0}"
  done
  echo ''
  echo '}'
} > "$H/state/reopen-rate.json"

# >>> reopen rate rows (BH-117)
# The file above only exists on the hub, so a watcher box's build read no reopen
# signal at all. Each project's numbers now also go to a D1 `ledgers` row
# (kind=reopen_rate) that every builder reads through jobs-client; the file stays
# as the hub's fallback and bin/cost-rollup.sh's input. The rows are read back
# from the file just written, so the two cannot disagree about a value. A failed
# PUT is never counted as written: those boxes keep yesterday's row, and ONE
# ALERTS line names them.
if ! command -v reopen_rate_put >/dev/null 2>&1 \
   && [ -r "$BIN/jobs-client.sh" ] && [ -r "$BIN/lib/jobs/settings.sh" ]; then
  # shellcheck source=/dev/null
  . "$BIN/jobs-client.sh" >/dev/null 2>&1 || true
fi
if ! command -v reopen_rate_put >/dev/null 2>&1; then
  HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] jobs-client unavailable — reopen_rate rows NOT written; watcher boxes keep their previous row or read no signal"
else
  RR_OK=0; RR_FAILED=""
  while IFS=$'\t' read -r RR_P RR_N RR_D; do
    [ -n "$RR_P" ] || continue
    if reopen_rate_put "$RR_P" "$RR_N" "$RR_D"; then RR_OK=$((RR_OK+1))
    else RR_FAILED="$RR_FAILED $RR_P"; fi
  done < <(jq -r 'to_entries[] | [.key, .value.reopens_14d, .value.builds_total] | @tsv' "$H/state/reopen-rate.json" 2>/dev/null)
  RR_FAILN=$(printf '%s\n' $RR_FAILED | grep -c .)
  [ -z "$RR_FAILED" ] || HARNESS="$H" "$H/bin/alert-line.sh" "[reopen-metrics] reopen_rate rows not written for:$RR_FAILED — those boxes keep yesterday's row; see logs/jobs-client.log (worker or HARNESS_SECRET)"
  echo "reopen_rate rows: $RR_OK written, $RR_FAILN failed"
fi
# <<< reopen rate rows
exit 0
