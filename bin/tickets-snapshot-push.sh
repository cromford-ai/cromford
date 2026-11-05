#!/bin/bash
# bin/tickets-snapshot-push.sh — hub cron (*/10): push a compact ticket-status
# snapshot for all four boards to the watchdog worker's KV, so Mission Control
# can render truthful kanban columns without holding board tokens on the CF
# side (the operator, 2026-08-24 "execute this yourself", after the dash showed stale
# statuses fleet-wide while every board read answered correctly).
#
# Consumer contract: GET $WATCHDOG_URL/api/tickets-snapshot with the dedicated bearer
# -> {"generated_at":<epoch>,"projects":{"<proj>":
# {"board_id":"...","tickets":[{"key","status","title","updatedAt"}]}}}.
# The dash reads it same-origin via a console-worker pass-through (see
# docs/DASH-TICKETS-SNAPSHOT.md). Secret resolution mirrors watchdog-ping.sh.
# Fail-quiet per board (a down app must not kill the other three); one ALERTS
# line per day if the final POST fails.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-tickets-snapshot-push
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off tickets-snapshot-push.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit tickets-snapshot-push
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    tickets-snapshot-push
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    tickets-snapshot-push
S=""
[ -r "$HENV/.watchdog-secret" ] && S=$(tr -d '\r\n' < "$HENV/.watchdog-secret" 2>/dev/null)
[ -n "$S" ] || S="${WATCHDOG_SECRET:-}"
[ -n "$S" ] || exit 0
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$H/bin/lib/wake-lanes.sh" ] && . "$H/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip tickets-snapshot-push fleet && exit 0
# <<< wake backstop
# WATCHDOG_URL through bin/lib/watchdog-url.sh (BH-2091), BEFORE any board or
# GitHub read: empty means no run at all and one line a day in
# logs/watchdog-url.log. No lib means no call, never a guessed host.
# shellcheck source=bin/lib/watchdog-url.sh
. "${HARNESS:-/root/harness}/bin/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }
BASEURL=$(watchdog_url tickets-snapshot-push "$H") || exit 0
# WHOSE PRs ARE OURS. The harness author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS) — since bin/gh-token.sh went live a harness PR is authored
# by the GitHub App (`app/cromford`) as often as by the PAT, and a
# hardcoded login matches only half of them (2026-09-14, project-5 #696/#697).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done

OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
echo "{\"generated_at\":$(date +%s),\"projects\":{" > "$OUT"
FIRST=1
# >>> board projects
# Every fleet.conf row with a real board prefix, not the four this loop used to
# name. A board absent from this snapshot is a whole project missing from the
# console's tickets tab — which renders as a project with no work, not as an
# error. The base URL is fleet.conf column 3 and the prefix column 4; the token
# resolved by bin/internal-token-for.sh, which requires the env file to define
# exactly ONE *_INTERNAL_API_TOKEN — the VARIABLE NAMES are per project and the
# registry does not record them (PROJECT_1_API_BASE / PROJECT_2_APP_BASE / PROJECT_4_API_BASE
# were the old table), so the suffix is the contract and ambiguity is an alert.
# An empty list here would push a snapshot with NO projects in it, which the
# console renders as a fleet with no tickets rather than as a broken push.
BOARD_PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" tickets-snapshot --with-board) || exit 1
token_for() { # token_for <project> — exactly one *_INTERNAL_API_TOKEN, or empty
  "$H/bin/internal-token-for.sh" "$1" 2>/dev/null || true
}
# <<< board projects
for P in $BOARD_PROJECTS; do
  ( set -a; . "$HENV/$P.env" 2>/dev/null; set +a
    BASE=$("$H/bin/fleet-conf.sh" "$P" prod); [ "$BASE" = "-" ] && BASE=""
    PFX=$("$H/bin/fleet-conf.sh" "$P" board_prefix)
    TOK=$(token_for "$P")
    [ -n "$BASE" ] && [ -n "$TOK" ] || exit 0
    BID=$(curl -sf -m 20 -H "Authorization: Bearer $TOK" -H "User-Agent: curl/8" "$BASE$PFX/boards" \
      | jq -r 'if type=="array" then .[0].id else .boards[0].id end' 2>/dev/null)
    [ -n "$BID" ] && [ "$BID" != null ] || exit 0
    # A ticket nobody has triaged yet reports "untriaged", NOT an empty string.
    # "we have not assessed this" and "assessed, nothing blocking" must never
    # render identically — an absent flag reads as no-problem, and ~89 tickets
    # fleet-wide have no verdict. Naming the unknown beats every renderer
    # downstream remembering to treat "" as unknown rather than as fine.
    # triage_verdict + waiting_on carry the standing product-board rule:
    # triageVerdict=needs_clarification with waitingOn=client means triage asked a
    # question the client has not answered, so the ticket is NOT buildable. The
    # board tab is exactly where that has to show, and it was lost when the tab
    # moved to this snapshot. Four different board APIs feed this, so both
    # casings are accepted rather than assuming one.
    # id/url are passed through ONLY if the API returns them — a URL pattern
    # guessed per app would render confident dead links, worse than none.
    curl -sf -m 30 -H "Authorization: Bearer $TOK" -H "User-Agent: curl/8" "$BASE$PFX/boards/$BID/tickets" \
      | jq -c --arg bid "$BID" \
        '{board_id:$bid, tickets:[(if type=="array" then .[] else .tickets[] end)
          | {key:(.key // ((.number|tostring))), status, title:(.title|tostring|.[0:80]),
             updatedAt:(.updatedAt // .updated_at // ""),
             triage_verdict:((.triageVerdict // .triage_verdict // "") | if . == "" then "untriaged" else . end),
             waiting_on:(.waitingOn // .waiting_on // ""),
             id:((.id // "")|tostring),
             url:(.url // .href // "")}]}' \
      > "/tmp/snap-$P.json" 2>/dev/null
  ) || true
done

# --- Lane enrichment (the operator 2026-08-24, "see all the fleet also with third
# party boxes"): third-party harnesses (partner on project-1, external teams)
# never ping our watchdog, so they can't appear as boxes — but their work IS
# visible where it lands: GitHub. For every in_progress/review ticket, find
# the open PR (or, failing that, the branch) carrying its key and attach
# claim:{actor,fleet,kind,ref,pr,pr_url,at}. fleet=true means the actor is one
# of OURS — the shared PAT or the GitHub App that now opens half the fleet's PRs
# (HARNESS_PR_AUTHORS, bin/lib/gh-pr-list.sh; REST spells the App
# `cromford[bot]`, which is why the set carries every spelling) — i.e. ANY
# of our harness lanes, indistinguishable by design; false = a third-party lane
# (collaborator-1, partner-dev, human devs).
# Per-project external_lanes rolls the non-fleet claims up so the dash can
# render third-party harnesses as pseudo-boxes. Key match demands a
# non-alphanumeric boundary before and a non-digit after (TK-24 must not
# claim agent/TK-249). Branch-only matches carry the commit date honestly —
# a stale branch reads as stale, not as active. Fail-quiet throughout: a
# GitHub hiccup costs the enrichment, never the snapshot.
FLEET_ACTORS=$(harness_pr_authors_json 2>/dev/null); [ -n "$FLEET_ACTORS" ] || FLEET_ACTORS='[]'

# BH-1586: every GitHub read below goes through gh_rest (bin/lib/gh-rest.sh,
# sourced by gh-pr-list.sh above): ledgered, and a GET that repeats an
# unchanged answer rides its ETag as If-None-Match and comes back a 304, which
# GitHub does not count. snap_get <outvar> <api path> assigns the body (empty
# on any non-0) and returns gh_rest's own rc. No gh_rest on the box = no
# enrichment, the same fail-quiet the raw reads had.
snap_get() {
  local _sg_t _sg_rc=0 _sg_v=""
  command -v gh_rest >/dev/null 2>&1 || { printf -v "$1" '%s' ""; return 75; }
  _sg_t=$(mktemp) || { printf -v "$1" '%s' ""; return 75; }
  gh_rest GET "$2" > "$_sg_t" || _sg_rc=$?
  [ "$_sg_rc" = 0 ] && _sg_v=$(cat "$_sg_t" 2>/dev/null)
  rm -f "$_sg_t"
  printf -v "$1" '%s' "$_sg_v"
  return "$_sg_rc"
}
# A MERGED PR IS TERMINAL (BH-1586). The branch->merged answer is persisted per
# (repo, branch, tip sha) and never asked again: this lane used to spend a
# closed-PR lookup every ten minutes on branches whose PR merged days ago. Keyed
# on the tip sha too, so a branch name reused for new work is asked afresh.
MERGED_DB="$H/state/tickets-snapshot/merged-branches.tsv"
merged_known() { # merged_known <repo> <ref> <sha> -> the stored claim JSON, or nothing
  awk -F'\t' -v r="$1" -v b="$2" -v s="$3" '$1==r && $2==b && $3==s {c=$4} END {if (c != "") print c}' "$MERGED_DB" 2>/dev/null
}
merged_remember() { # merged_remember <repo> <ref> <sha> <claim JSON> — best effort
  mkdir -p "${MERGED_DB%/*}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr -d '\t\n')" "$(date +%s)" >> "$MERGED_DB" 2>/dev/null || true
}
# BOUNDED (#1605 review): column 5 is when the answer was written, and an entry
# older than TICKETS_SNAPSHOT_MERGED_KEEP_DAYS (a required lane knob, no literal
# here) is dropped once per run. A pruned branch that is still around is simply
# asked again. An unclear knob value prunes nothing.
merged_prune() {
  local days="${TICKETS_SNAPSHOT_MERGED_KEEP_DAYS:-}" cutoff
  case "$days" in ''|*[!0-9]*|0) return 0 ;; esac
  [ -s "$MERGED_DB" ] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))
  awk -F'\t' -v c="$cutoff" '($5 + 0) >= c' "$MERGED_DB" > "$MERGED_DB.$$" 2>/dev/null \
    && mv -f "$MERGED_DB.$$" "$MERGED_DB" 2>/dev/null || rm -f "$MERGED_DB.$$" 2>/dev/null
  return 0
}
merged_prune

for P in $BOARD_PROJECTS; do
  [ -s "/tmp/snap-$P.json" ] || continue
  R=$("$H/bin/fleet-conf.sh" "$P" repo)
  [ -n "$R" ] || continue
  snap_get PRS "repos/$R/pulls?state=open&per_page=100" \
    && PRS=$(jq -c '[.[]|{n:.number,br:.head.ref,by:.user.login,up:.updated_at,url:.html_url,t:.title}]' <<<"$PRS" 2>/dev/null)
  [ -n "$PRS" ] || PRS='[]'
  snap_get REFS "repos/$R/git/matching-refs/heads/" \
    && REFS=$(jq -c '[.[]|{ref:(.ref|sub("refs/heads/";"")),sha:.object.sha}]' <<<"$REFS" 2>/dev/null)
  [ -n "$REFS" ] || REFS='[]'
  CLM='{}'
  for K in $(jq -r '.tickets[]|select(.status=="in_progress" or .status=="review")|.key' "/tmp/snap-$P.json" 2>/dev/null); do
    # Pure-numeric keys (a board's .number fallback — project-4 returns key:null)
    # collide with anything ("6" matched an unrelated PR title on first live
    # run). For those, demand a letter prefix + hyphen (TK-1126, TK-1126),
    # which is how every branch/PR actually spells them.
    case "$K" in
      *[!0-9]*) RX="(^|[^A-Za-z0-9])${K}([^0-9]|\$)" ;;
      *)        RX="(^|[^A-Za-z0-9])[A-Za-z]{1,6}-${K}([^0-9]|\$)" ;;
    esac
    C=$(jq -c --arg rx "$RX" \
        '[.[]|select((.br+" "+.t)|test($rx;"i"))]|sort_by(.up)|if length>0 then (last|{actor:.by,kind:"pr",state:"open",ref:.br,pr:.n,pr_url:.url,at:.up}) else empty end' \
        <<<"$PRS" 2>/dev/null)
    if [ -z "$C" ]; then
      BR=$(jq -r --arg rx "$RX" \
           '[.[]|select(.ref|test($rx;"i"))]|if length>0 then (last|.sha+" "+.ref) else empty end' \
           <<<"$REFS" 2>/dev/null)
      if [ -n "$BR" ]; then
        SHA=${BR%% *}; REF=${BR#* }
        # A branch with no OPEN PR is not necessarily abandoned work: the PR may
        # have MERGED and the branch simply not been deleted. 2026-09-10: eight
        # project-4 tickets rendered as "stale branch — no PR, tip is 8d old" while
        # every one of their PRs had merged days earlier and the only thing
        # left undone was the ticket's own close-out. One exact lookup by head
        # ref (cheap: one call per branch-only ticket, never a full PR page
        # walk) tells the two apart; the claim then says merged, with the merge
        # time, so the console can show "shipped, ticket still open" instead of
        # a lane nobody is running.
        OWNER=${R%%/*}
        C=$(merged_known "$R" "$REF" "$SHA")
        if [ -z "$C" ]; then
          snap_get C "repos/$R/pulls?state=closed&head=$OWNER:$REF&per_page=5" \
            && C=$(jq -c '[.[]|select(.merged_at != null)]|sort_by(.merged_at)|if length>0 then (last|{actor:.user.login,kind:"pr",state:"merged",ref:.head.ref,pr:.number,pr_url:.html_url,at:.merged_at}) else empty end' <<<"$C" 2>/dev/null)
          [ -n "$C" ] && merged_remember "$R" "$REF" "$SHA" "$C"
        fi
        if [ -z "$C" ]; then
          snap_get C "repos/$R/commits/$SHA" \
            && C=$(jq -c '{actor:(.author.login // .commit.author.name),at:.commit.committer.date}' <<<"$C" 2>/dev/null)
          [ -n "$C" ] && C=$(jq -c --arg ref "$REF" '. + {kind:"branch",ref:$ref,pr:null,pr_url:null}' <<<"$C" 2>/dev/null)
        fi
      fi
    fi
    [ -n "$C" ] && CLM=$(jq -c --arg k "$K" --argjson c "$C" --argjson fa "$FLEET_ACTORS" \
        '. + {($k): ($c + {fleet:(($fa | index($c.actor)) != null)})}' <<<"$CLM" 2>/dev/null || echo "$CLM")
  done
  jq -c --argjson clm "$CLM" \
     '.tickets = [.tickets[] | if $clm[.key] then . + {claim:$clm[.key]} else . end]
      | . + {external_lanes:[ $clm | to_entries[] | select(.value.fleet|not) | {ticket:.key} + .value ]}' \
     "/tmp/snap-$P.json" > "/tmp/snap-$P.enriched" 2>/dev/null
  if [ -s "/tmp/snap-$P.enriched" ] && jq -e . "/tmp/snap-$P.enriched" >/dev/null 2>&1; then
    mv "/tmp/snap-$P.enriched" "/tmp/snap-$P.json"
  fi
  rm -f "/tmp/snap-$P.enriched"
done

for P in $BOARD_PROJECTS; do
  [ -s "/tmp/snap-$P.json" ] || continue
  [ "$FIRST" = 1 ] || printf ',' >> "$OUT"
  FIRST=0
  printf '"%s":' "$P" >> "$OUT"
  cat "/tmp/snap-$P.json" >> "$OUT"
  rm -f "/tmp/snap-$P.json"
done
echo "}}" >> "$OUT"
jq -e . "$OUT" >/dev/null 2>&1 || { HARNESS="$H" "$H/bin/alert-line.sh" "[tickets-snapshot] assembled JSON invalid — not pushed"; exit 0; }

# How many tickets actually carried each new field, AND the distinct vocabulary
# each board actually uses. Counts catch a field going missing; the value lists
# catch a board quietly changing its words — "Needs Clarification" with a space
# and a capital is a different string from needs_clarification, and the card that
# keys off that pair would stop matching while still rendering happily. Case is
# normalised downstream, separator drift is not, and the producer is the only
# place that sees all four boards at once. Lists are capped at 8 values with a
# +N suffix, so a free-text waiting_on cannot bloat the line.
COV=$(jq -r '[.projects | to_entries[] | .key + ": " + (.value.tickets|length|tostring) + " tickets"
      + " verdict=" + ([.value.tickets[]|select(.triage_verdict != "" and .triage_verdict != "untriaged")]|length|tostring)
      + " untriaged=" + ([.value.tickets[]|select(.triage_verdict == "untriaged")]|length|tostring)
      + " waiting_on=" + ([.value.tickets[]|select(.waiting_on != "")]|length|tostring)
      + " url=" + ([.value.tickets[]|select(.url != "")]|length|tostring)
      + " verdicts=" + (([.value.tickets[].triage_verdict] | map(if . == "" then "(empty)" else . end) | unique) as $v
          | "[" + ($v[0:8] | join(",")) + (if ($v|length) > 8 then ",+" + (($v|length)-8|tostring) else "" end) + "]")
      + " waiting=" + (([.value.tickets[].waiting_on] | map(if . == "" then "(empty)" else . end) | unique) as $w
          | "[" + ($w[0:8] | join(",")) + (if ($w|length) > 8 then ",+" + (($w|length)-8|tostring) else "" end) + "]")
      ] | join(" | ")' "$OUT" 2>/dev/null)
[ -n "$COV" ] && echo "$(STAMP) [tickets-snapshot] field coverage — $COV" >> "$H/logs/agent-rules.log"

LANES=$(jq -r '[.projects | to_entries[] | .key + ": claims=" + ([.value.tickets[]|select(.claim)]|length|tostring)
      + " external=" + ((.value.external_lanes // [])|length|tostring)
      + " actors=[" + (([.value.tickets[].claim.actor?]|map(select(.))|unique|join(",")) ) + "]"
      ] | join(" | ")' "$OUT" 2>/dev/null)
[ -n "$LANES" ] && echo "$(STAMP) [tickets-snapshot] lane coverage — $LANES" >> "$H/logs/agent-rules.log"

if ! watchdog_curl -sf -m 30 -X POST --data-binary @"$OUT" -H "Content-Type: application/json" \
     "$BASEURL/api/tickets-snapshot" >/dev/null 2>&1; then
  FLAG="$H/flags/alerted-tickets-snapshot-$(date -u +%Y%m%d)"
  [ -f "$FLAG" ] || { touch "$FLAG"; HARNESS="$H" "$H/bin/alert-line.sh" "[tickets-snapshot] push to watchdog FAILED — Mission Control kanban will go stale"; }
fi
exit 0
