#!/bin/bash
# alert-writer: by-design — the medic triages the alerts table; its lines stay off the emit-time path so they reach the table via the poll-commands re-beat, not mid-pass while it is triaging.
# Alerts medic — the self-healing layer. HUB cron every 30 min: if open console
# alerts exist that the groomer could not settle and the medic has not yet
# examined, run ONE fable session that diagnoses and REMEDIATES within strict
# bounds, then escalates (single beat) anything it cannot fix. This automates
# what the orchestrator has been doing by hand between the operator's messages.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=alerts-medic
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-alerts-medic, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off alerts-medic.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alerts-medic
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alerts-medic
# THE CONDUCTOR'S PAUSE (BH-1201). While the merge conductor is not running its
# own merges — mode kill-switch, observe, or no published mode at all — this
# lane leaves the alerts the conductor itself raised
# (`[orchestrator/merge-conductor]` / `[merge-conductor]`) alone: they are
# dropped from this pass's candidates before anything is claimed, so the row
# stays `new` on the console and in the alerts table and is re-offered next
# pass. Nothing is claimed, parked, stamped or marked seen for a held row.
# `unknown` holds, so an unreachable worker costs one pass rather than a
# diagnosis of a pull request whose owner is mid-pause. The knob is
# MEDIC_CONDUCTOR_HOLD; set it to 0 to opt this lane out entirely. Absent
# library (a box whose sync lagged) = no function = today's behaviour.
# shellcheck disable=SC1091
[ -r "$HARNESS/bin/lib/conductor-mode.sh" ] && . "$HARNESS/bin/lib/conductor-mode.sh" 2>/dev/null

[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
LOG="$HARNESS/logs/medic.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# --- PER-PROJECT RUNNER (BH-5942) ----------------------------------------------
# No global lock. With no argument (the cron line, bin/watchdog-poll.sh) this
# is the DISPATCH: it grooms once, below, then starts one detached run per
# fleet.conf project (bin/lib/llm-lane-project.sh over bin/lib/project-lanes.sh),
# and each run holds only locks/alerts-medic-<project>.lock. `alerts-medic.sh
# <project>` is one project's run: it reads only that project's alerts, keeps
# its state in state/alerts-medic/<project>/, and calls the model on the
# project's own account and GitHub App token. The dispatch sits below the lane
# gate and the two caps, so a lane that is off or stopped forks nothing.
H="$HARNESS"
LLP_LOG="$LOG"
# shellcheck source=bin/lib/llm-lane-project.sh
. "$HARNESS/bin/lib/llm-lane-project.sh" || { echo "$(STAMP) medic: bin/lib/llm-lane-project.sh is missing — no dispatch, no run" >> "$LOG"; exit 1; }

# --- VOLUME CAPS (begin, BH-1039) -------------------------------------------
# Same bound as alert-triage, for the same reason: this lane's session count is
# capped and its per-session PRICE is not (1.1M input tokens a session, 465M
# over three days, every row unpriced). bin/lib/lane-caps.sh states the bound in
# dollars per UTC day and prices the blank rows so the total is not a fiction.
# A box whose sync has not landed the library behaves exactly as before.
# shellcheck source=bin/lib/cost-row.sh
. "$HARNESS/bin/lib/cost-row.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/cost-row.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lane-caps.sh
. "$HARNESS/bin/lib/lane-caps.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-caps.sh" 2>/dev/null || true
command -v lane_day_cap_tripped >/dev/null 2>&1 || lane_day_cap_tripped() { return 1; }
# NO CAP is the fallback here, not 20000: this lane has never capped its
# evidence, so a stub that started truncating would be a behaviour change
# arriving on the boxes that are furthest behind.
command -v lane_evidence_cap   >/dev/null 2>&1 || lane_evidence_cap()   { cat; }

# BEFORE THE GROOM AND THE FETCH. The console API is this lane's queue and it
# holds everything until it is resolved, so a stopped pass consumes nothing: the
# alerts are re-offered, oldest first, the moment the lane can afford them.
if lane_day_cap_tripped medic; then
  echo "$(STAMP) medic pass: STOPPED on the lane's daily spend cap — no fetch, no session, nothing consumed (see ALERTS.log)" >> "$LOG"
  exit 0
fi
# --- VOLUME CAPS (end) -------------------------------------------------------

# --- SESSION CAP OF ZERO (begin, BH-1164) -----------------------------------
# The identical clamp alert-triage had: the splitter below reads the cap as
# `max(1, int(capstr))`, so `MEDIC_MAX_FAMILIES=0` — the operator's pause — let
# the first family of every pass through anyway and bought it a session. Zero
# means zero, checked BEFORE the groom and the fetch, like the dollar cap above:
# the console is this lane's queue and it holds every alert until it is
# resolved, so a stopped pass consumes nothing and the alerts are re-offered
# oldest-first the moment the lane is turned back on. No page: at every 30 min a
# deliberate pause that pages is 48 pages a day.
MAX_FAMILIES="${MEDIC_MAX_FAMILIES:-4}"; MAX_FAMILIES="${MAX_FAMILIES//[[:space:]]/}"
if ! [[ "$MAX_FAMILIES" =~ ^-?[0-9]+$ ]]; then
  echo "$(STAMP) medic pass: MEDIC_MAX_FAMILIES='$MAX_FAMILIES' is not a whole number — IGNORED, the default (4) stands" >> "$LOG"
  MAX_FAMILIES=4
fi
if [ "$MAX_FAMILIES" -le 0 ]; then
  echo "$(STAMP) medic pass: STOPPED — MEDIC_MAX_FAMILIES=$MAX_FAMILIES means zero sessions. No groom, no fetch, no session, nothing consumed, \$0. Set MEDIC_MAX_FAMILIES to a positive number to resume." >> "$LOG"
  exit 0
fi
# --- SESSION CAP OF ZERO (end) ----------------------------------------------

# Groom first so the medic only sees genuinely unsettled alerts. The groom is
# fleet-wide with its own lock, so it runs ONCE, in the dispatch, before any
# project run starts (BH-5942). A project run never grooms.
if llp_is_dispatch "${1:-}"; then
  "$HARNESS/bin/alerts-groom.sh" >/dev/null 2>&1 || true
  llp_dispatch alerts-medic
  exit $?
fi
llp_enter alerts-medic medic "${1:-}"
llp_arm
# THIS PROJECT'S STATE (BH-5942). The seen ids, the 6h family stamps and the
# parks live in state/alerts-medic/<project>/. The shared files of the global
# lane are read, never written: the old seen list is a second, read-only source
# (an alert seen before the move is not examined again), and the families and
# parks are COPIED into a project's own file on its first run, so a 6h stamp or
# a park carries over.
SEEN="$LLP_STATE/medic-seen.txt"; touch "$SEEN"
SEEN_OLD=""; [ -r "$HARNESS/state/medic-seen.txt" ] && SEEN_OLD="$HARNESS/state/medic-seen.txt"
medic_seed() { # medic_seed <project file> — copy the shared file once, never move it
  local f="$1" shared
  shared="$HARNESS/state/$(basename "$1")"
  [ -e "$f" ] && return 0
  [ -s "$shared" ] || return 0
  cp "$shared" "$f.seed.$$" 2>/dev/null && mv -f "$f.seed.$$" "$f" || rm -f "$f.seed.$$"
}
# medic_own_rows — reads "<project><\001><row>" lines, prints <row> for the rows
# whose project field this run owns (llp_owns: exact name, or the home run for
# no project, `harness` or a name not in fleet.conf). One llp_owns per value.
declare -A MEDIC_OWNC=()
medic_owns() {
  local k="k${1-}"
  if [ -z "${MEDIC_OWNC[$k]+x}" ]; then
    if llp_owns "${1-}"; then MEDIC_OWNC[$k]=1; else MEDIC_OWNC[$k]=0; fi
  fi
  [ "${MEDIC_OWNC[$k]}" = 1 ]
}
medic_own_rows() {
  local p r
  while IFS=$'\001' read -r p r; do
    [ -n "$r" ] || continue
    medic_owns "$p" && printf '%s\n' "$r"
  done
  return 0
}

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open") || exit 0
jq -e '.alerts' <<<"$RESP" >/dev/null 2>&1 || exit 0
# >>> alerts db gate (BH-1071)
# The alerts TABLE, when this box is opted in (flags/alerts-db). Everything it
# buys is below: unclaimed rows join the candidate list, a claim decides what
# this pass may pay for, and the family brake gains a fleet-wide view. Every one
# of those calls FAILS OPEN — any rc but 0 and this pass is byte-for-byte
# today's. The gate sits here, after the console fetch, so the two exits above
# stay exactly as they are and nothing is created on a path that cannot use it.
ALERTS_DB=0
# shellcheck source=bin/lib/alert-state.sh
[ -r "$HARNESS/bin/lib/alert-state.sh" ] && . "$HARNESS/bin/lib/alert-state.sh" 2>/dev/null
declare -F alerts_db_on >/dev/null 2>&1 && alerts_db_on && ALERTS_DB=1
# candidate id -> table row id, for this pass only. The claim and the park need
# ROW ids; a candidate carries a console id whenever the console saw it first.
# Created only when the flag is on — with it off this pass touches nothing at
# all, not even a temp file, and every `rm -f "$ROWMAP"` below is then a no-op.
ROWMAP=""; DBFAMS=""
if [ "$ALERTS_DB" = 1 ]; then ROWMAP=$(mktemp); DBFAMS=$(mktemp); fi
# <<< alerts db gate
# >>> brake ledger (BH-2316.2)
# The three brakes below (seen ids, the 6h family stamp, parked families) live
# in state/ files, and a rebuilt hub starts with those empty. Behind the same
# flag, each one also writes through to ledgers(kind,key) and is read back as a
# union every pass. The local file stays primary and is written first. Flag off
# or the library absent: no request at all. A read that fails brakes nothing
# extra and clears nothing — the local files decide alone, exactly as today.
BRAKE_DB=0; SEENDB=""; DBPARKS=""
# shellcheck source=bin/lib/brake-ledger.sh
[ "$ALERTS_DB" = 1 ] && [ -r "$HARNESS/bin/lib/brake-ledger.sh" ] && . "$HARNESS/bin/lib/brake-ledger.sh" 2>/dev/null
[ "$ALERTS_DB" = 1 ] && declare -F brake_read brake_mark brake_clear >/dev/null 2>&1 && BRAKE_DB=1
# brake_union <name> <window_s> — the set rows' TSV, never the `#truncated`
# marker (it is not a key). A capped read is still used, and said to be partial.
brake_union() {
  local out rc
  out=$(brake_read "$1" "$2"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(STAMP) medic db: $1 ledger read rc=$rc — local $1 state only this pass" >> "$LOG"
    return "$rc"
  fi
  grep -qx '#truncated' <<<"$out" \
    && echo "$(STAMP) medic db: $1 ledger read hit its page cap — the union is partial" >> "$LOG"
  printf '%s\n' "$out" | awk -F'\t' '$1 !~ /^#/ && $1 != ""'
}
[ "$BRAKE_DB" = 1 ] && { SEENDB=$(mktemp); brake_union medic-seen 604800 | cut -f1 > "$SEENDB"; }
# <<< brake ledger
# Unseen alerts older than 20 min (fresh ones get a chance to self-resolve).
CUTOFF=$(date -u -d '20 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
# ── NEVER INVESTIGATE AN ESCALATION (2026-08-31) ──────────────────────────────
# An alert in the `medic:` or `triage:` akey namespace is not an incident. It is
# a lane's own conclusion, already investigated, addressed to a human, naming the
# ONE action a human must take. Reading it back in was a closed loop that ran all
# night: medic escalates -> the escalation is a fresh unseen console row -> 20 min
# later it is a candidate -> its family is hashed from the LLM's own free-text
# prose, which differs every pass, so the 6h brake sees a BRAND-NEW family ->
# medic buys a full session to re-verify its own message -> escalates again under
# yet another key. Observed 2026-08-31: one project-2 condition wearing two
# family keys (bb1c4472dc0a, 2370fcfa03a5) and paging into its "6th session",
# and 34 distinct medic akeys covering ~8 real problems.
# The escalations stay OPEN and visible for the human; alerts-groom.sh and
# alerts-supersede.py's TTL are what close them. No LLM is owed to them.
ESCALATION_NS='^(medic|triage):'
# `tostring` is load-bearing, not decoration: `test` on a non-string akey aborts
# the WHOLE jq program, and the fallback below is the same program — so a single
# malformed row would empty NEW and this lane would exit 0 with the entire queue
# unread, looking perfectly healthy.
# BH-5942: each row is prefixed with its project field and \001, and
# medic_own_rows keeps only this run's rows and strips the prefix.
SELECT_OPEN='[.alerts[] | select(.createdAt < $c) | select(((.akey // "" | tostring) | test($ns)) | not)] | sort_by(.createdAt) | .[] | (((.project // "") | tostring | gsub("[\u0001\n\r]"; " ")) + "\u0001" + ([.id, .line] | @tsv))'
# OLDEST FIRST. This is the medic's anti-starvation guarantee, and it replaces
# alert-triage's deferral spool: the console API is the durable queue here — an
# alert stays open until it is resolved — so a family the cap defers does not
# need parking anywhere, it simply must not be consumed (see the SEEN and family
# stamping below) and must be first in line next pass. Sorting by createdAt is
# strictly better than a spool's drained-first ordering, because it is the
# alert's real age rather than the order we happened to park things in.
NEW=$(jq -r --arg c "$CUTOFF" --arg ns "$ESCALATION_NS" "$SELECT_OPEN" <<<"$RESP" | medic_own_rows \
      | grep -v -F -f <(cut -f1 "$SEEN" ${SEEN_OLD:+"$SEEN_OLD"} ${SEENDB:+"$SEENDB"} | sed 's/^/^/;s/$/\t/') 2>/dev/null || \
      jq -r --arg c "$CUTOFF" --arg ns "$ESCALATION_NS" "$SELECT_OPEN" <<<"$RESP" | medic_own_rows)
# >>> alerts db candidates (BH-1071)
# The table's own unclaimed rows join the candidate list. This is the case that
# has no other route in: a box that inserted a row and then dropped off the
# tailnet has nobody to carry its alert to the console. A row whose line is
# already a console row is NOT a second candidate — the console row governs, and
# all we keep is which table row it is, so the claim and the park can name it.
#
# WHY awk AND NOT `IFS=$'\t' read`: tab is IFS *whitespace*, so bash collapses
# runs of it — an empty column (claimed_by is empty on every unclaimed row)
# shifts every field after it and the row arrives with no line at all. NF>=13
# also drops the contract's `#truncated` marker, which is not a row.
if [ "$ALERTS_DB" = 1 ]; then
  DBROWS=$(alerts_list --state new --older-than 1200 --limit 200); LRC=$?
  if [ "$LRC" -eq 0 ]; then
    DBADD=""; ADDED=0
    while IFS=$'\001' read -r RID RCB RPROJ RLINE; do
      [ -n "$RID" ] || continue
      [ -z "$RCB" ] || continue                      # another lane holds it
      CID=$(jq -r --arg l "$RLINE" '[.alerts[]? | select(((.line // "") | tostring) == $l) | .id] | first // empty' <<<"$RESP" 2>/dev/null)
      if [ -n "$CID" ]; then printf '%s\t%s\n' "$CID" "$RID" >> "$ROWMAP"; continue; fi
      # BH-5942: a table row joins only its own project's run (column 4).
      medic_owns "$RPROJ" || continue
      printf '%s\t%s\n' "$RID" "$RID" >> "$ROWMAP"
      DBADD="$DBADD$RID"$'\t'"$RLINE"$'\n'; ADDED=$((ADDED+1))
    done < <(printf '%s\n' "$DBROWS" | awk -F'\t' 'NF>=13 {
        printf "%s\001%s\001%s\001", $1, $9, $4
        for (i = 13; i <= NF; i++) printf "%s%s", (i > 13 ? "\t" : ""), $i
        printf "\n" }')
    [ -n "$DBADD" ] && NEW=$(printf '%s\n%s' "$NEW" "$DBADD" | grep -v '^[[:space:]]*$')
    echo "$(STAMP) medic db: $ADDED unclaimed row(s) added from the alerts table" >> "$LOG"
  else
    echo "$(STAMP) medic db: alerts list rc=$LRC — console-only candidates this pass" >> "$LOG"
  fi
fi
# <<< alerts db candidates
# robust unseen filter — DB-sourced ids pass through it too, so a row this lane
# dispatched before is never re-added even if its claim has since lapsed.
NEW=$(while IFS=$'\t' read -r ID LINE; do grep -q "^$ID$" "$SEEN" ${SEEN_OLD:+"$SEEN_OLD"} ${SEENDB:+"$SEENDB"} || printf '%s\t%s\n' "$ID" "$LINE"; done <<<"$NEW")
[ -n "$SEENDB" ] && rm -f "$SEENDB"
NEW="${NEW#"${NEW%%[![:space:]]*}"}"   # medic-found bug: empty queue yields a lone tab
[ -n "${NEW//[[:space:]]/}" ] || { rm -f "$ROWMAP" "$DBFAMS"; exit 0; }

# >>> conductor hold (BH-1201)
# Drop the conductor's own lines from this pass's candidates while it is paused.
# Here, before CANDIDATES is written, is the only place that costs nothing: the
# claim (alert_claim), the 6h family stamp and the SEEN write all run over what
# survives this filter, so a row removed here is left exactly as it was found.
# The row part is everything AFTER the first tab, so an id can never match.
if command -v conductor_hold_active >/dev/null 2>&1 \
   && COND_MODE=$(conductor_hold_active alerts-medic MEDIC_CONDUCTOR_HOLD); then
  COND_RE=$'^[^\t]*\t.*\\[(orchestrator/)?merge-conductor\\]'
  COND_N=$(grep -cE "$COND_RE" <<<"$NEW") || COND_N=0
  if [ "${COND_N:-0}" -gt 0 ]; then
    NEW=$(grep -vE "$COND_RE" <<<"$NEW")
    echo "$(STAMP) medic pass: held $COND_N conductor alert(s): conductor paused (mode=$COND_MODE) — left unclaimed and unstamped" >> "$LOG"
  fi
  [ -n "${NEW//[[:space:]]/}" ] || { rm -f "$ROWMAP" "$DBFAMS"; exit 0; }
fi
# <<< conductor hold

# >>> own mismatch line (BH-1837)
# This lane's own call (agent-call.sh triage medic, with the floor's runner and
# its fallback MODEL) writes `[medic] MODEL/RUNNER MISMATCH: …` into ALERTS.log
# whenever those two disagree, and that line comes back here as an alert.
# Diagnosing it buys one more call of exactly that shape. Same seam and the same
# semantics as the conductor hold: dropped before the claim, the family stamp
# and the SEEN write, so the row stays `new` on the console for a human. Only a
# row whose OWN leading project tag is [medic] (after the id tab and an optional
# stamp) matches; another project's mismatch line, or a [medic] quoted in some
# other row's text, still reaches the medic.
SELF_MM_RE=$'^[^\t]*\t([0-9-]+ [0-9:]+Z )?\\[medic\\] MODEL/RUNNER MISMATCH: '
SELF_MM_N=$(grep -cE "$SELF_MM_RE" <<<"$NEW") || SELF_MM_N=0
if [ "${SELF_MM_N:-0}" -gt 0 ]; then
  NEW=$(grep -vE "$SELF_MM_RE" <<<"$NEW")
  echo "$(STAMP) medic pass: held $SELF_MM_N own MODEL/RUNNER MISMATCH alert(s) — this lane's own call, left unclaimed and unstamped" >> "$LOG"
  [ -n "${NEW//[[:space:]]/}" ] || { rm -f "$ROWMAP" "$DBFAMS"; exit 0; }
fi
# <<< own mismatch line

# FAMILY COST BRAKE (2026-08-16, cost review): recurring incidents re-beat with
# a FRESH alert id each time, so the id-based SEEN filter never catches them and
# each pass pays a full Fable diagnosis of the same story ($45/day at peak).
# The family key is now bin/alert_family.py, shared with alert-triage — this
# lane used to carry its OWN normalization while its comment claimed it was the
# "same normalization as alert-triage's". It was not (7+ hex and lowercased vs
# 8+ hex case-sensitive), so one incident could be a single family to one lane
# and two to the other. Adopting the shared key changes THIS lane's signatures
# once: the first pass after deploy sees its existing families as unseen and
# re-examines them. That is one pass of cache misses, bounded by the cap below,
# and nothing is lost.
#
# ── Scope per unit (2026-08-25, wave 2) ────────────────────────────────────
# The same key now also GROUPS: this lane handed its whole batch to one session
# (24h: 14 calls at 4.37M mean input, 55x its 80K ceiling), so unrelated units
# interleaved and each one's investigation rode in the context of every other's.
# One agent-call per family instead. The harness decides that boundary.
#
# ── PARKED FAMILIES (2026-08-31) ─────────────────────────────────────────────
# The 6h brake is a rate limit, not a stop condition: it assumes another pass
# might FIX the thing. For a family whose one action is out of these bounds — a
# repo PR, a merge, a signed-in operator — no pass ever can, so the brake just
# buys the same diagnosis four times a day forever. When a session escalates a
# family, that family is PARKED: the medic has said its piece and the ball is in
# a human's court. Parked families are skipped until MEDIC_PARK_TTL expires (so
# a genuinely forgotten problem does come back), and the daily digest reports the
# parked set, so parking is a declared wait and never a silent drop.
FAM="$LLP_STATE/medic-families.json"; medic_seed "$FAM"; [ -s "$FAM" ] || echo '{}' > "$FAM"
PARKED="$LLP_STATE/medic-parked.json"; medic_seed "$PARKED"; [ -s "$PARKED" ] || echo '{}' > "$PARKED"
PARK_TTL="${MEDIC_PARK_TTL:-604800}"   # 7 days
# Which families are currently escalated? Read straight off the console, from the
# escalations' permanent addresses (`medic:<fkey>`) — deterministic, and it does
# not depend on a session having run in THIS pass, so an escalation made hours
# ago can still park its family.
#
# READ, not anchor. The park is RECORDED from this and then stands on its own:
# alerts-groom.sh (which this lane runs at line 17) invokes alerts-supersede.py,
# which resolves medic rows on a 72h TTL and collapses any that name the same
# ticket or PR as another machine alert. A park derived from what is still on the
# console would therefore be deleted by our own groomer — MEDIC_PARK_TTL would be
# dead config, capped at 72h and often minutes, and the loop would be slowed
# rather than closed. The escalation row is a page for a human, with its own
# lifecycle; the park is this lane's memory, with a different one.
ESCFILE=$(mktemp)
# The `(:.*)?` tail accepts the pre-2026-08-31 `medic:<fkey>:<utc-hour>` shape as
# well as the current bare one. Escalations live on the console for up to 72h, so
# without this every escalation written before the deploy would fail to park AND
# be reported as contract drift — the fix would arrive looking like a new fault.
ESC_AKEY='^medic:[0-9a-f]+(:.*)?$'
# BH-5942: EVERY escalation parks its family, in every project run. The
# escalation's project field is the model's pick (from the whole FLEET table, or
# empty), so a run that owns the family cannot depend on it (lead BLOCK at
# 897dab888); a park only acts on this run's own candidate rows anyway.
jq -r --arg re "$ESC_AKEY" '.alerts[]? | select(((.akey // "" | tostring)) | test($re))
       | ((.akey | tostring | sub("^medic:";"") | sub(":.*$";"")) + "\t" + ((.line // "") | tostring))' \
  <<<"$RESP" 2>/dev/null > "$ESCFILE"
# CONTRACT DRIFT: an akey in the medic namespace that is not a bare family key
# still gets excluded from re-investigation (the exclusion match is loose), but
# it can never park — so the lane would quietly fall back to 6h-brake cost with
# nothing saying why. Name it instead of absorbing it.
DRIFT=$(jq -r --arg re "$ESC_AKEY" '.alerts[]? | select((.akey // "" | tostring) | startswith("medic:"))
               | select((.akey | tostring) | test($re) | not)
               | (((.project // "") | tostring | gsub("[\u0001\n\r]"; " ")) + "\u0001" + (.akey | tostring))' \
          <<<"$RESP" 2>/dev/null | medic_own_rows | head -3 | tr '\n' ' ')
[ -n "${DRIFT// /}" ] && \
  echo "$(STAMP) [alerts-medic] ESCALATION AKEY DRIFT: $DRIFT — not of the form medic:<family>, so these families cannot park and this lane is paying 6h-brake cost for them" >> "$HARNESS/logs/ALERTS.log"
DISPATCH=$(mktemp)
CANDIDATES=$(mktemp); printf '%s\n' "$NEW" > "$CANDIDATES"
# MAX_FAMILIES is resolved and validated at the top of this file (BH-1164): a
# cap of 0 exited before the groom, so it is a positive whole number here.
# The candidate rows go in as a FILE, not on a pipe: `python3 - <<'PYF'` already
# claims stdin for the program text, so a piped payload is silently swallowed.
# (shellcheck SC2259 caught exactly that here — the lane would have run on an
# empty batch and looked perfectly healthy doing it.)
PARKLOG=$(mktemp)
SPLITERR=$(mktemp)
# The 6h brake, fleet-wide (BH-1071): a family another lane already claimed
# inside the window is one this pass must not re-diagnose. Flag off (or the
# worker unreachable) leaves an empty file, an empty set, and identical
# decisions — the local stamp is still the only brake.
if [ "$ALERTS_DB" = 1 ]; then
  alert_families medic 21600 > "$DBFAMS" 2>/dev/null || : > "$DBFAMS"
  # BH-2316.2: and this lane's own 6h stamps, from the ledger. Appended, so the
  # claim view above is never replaced; the window is the brake's, 6 hours.
  [ "$BRAKE_DB" = 1 ] && brake_union medic-family 21600 >> "$DBFAMS"
fi
# The parks the ledger holds inside PARK_TTL, merged under the local file's.
[ "$BRAKE_DB" = 1 ] && { DBPARKS=$(mktemp); brake_union medic-parked "$PARK_TTL" > "$DBPARKS"; }
SPLIT=$(python3 - "$CANDIDATES" "$FAM" "$DISPATCH" "$MAX_FAMILIES" "$HARNESS/bin" "$PARKED" "$PARK_TTL" "$ESCFILE" "$PARKLOG" "$DBFAMS" ${DBPARKS:+"$DBPARKS"} 2>"$SPLITERR" <<'PYF'
import sys, json, time, re
srcf, famf, outf, capstr, bindir, parkf, parkttl, escf, parklog, dbfamsf = sys.argv[1:11]
dbparksf = sys.argv[11] if len(sys.argv) > 11 else ""
sys.path.insert(0, bindir)
from alert_family import family   # ONE implementation, shared with alert-triage.sh
cap = max(1, int(capstr))
try: fams = json.load(open(famf))
except Exception: fams = {}
try: parked = json.load(open(parkf))
except Exception: parked = {}
# 0 is a legitimate TTL (it means "park nothing"), so only a non-integer falls
# back to the default — clamping it away would make the setting untestable.
try: park_ttl = int(parkttl)
except Exception: park_ttl = 604800
# Families claimed by this lane fleet-wide inside the brake window. Absent file,
# empty file, unreachable worker: an empty set, and the local stamp decides
# alone — exactly today.
try:
    dbfams = {l.split("\t")[0] for l in open(dbfamsf, errors="ignore") if l.strip()}
except Exception:
    dbfams = set()
now = time.time()

rows = []
for row in open(srcf, errors="ignore").read().splitlines():
    if "\t" not in row: continue
    _id, line = row.split("\t", 1)
    rows.append((_id, line, family(line)))

# Tolerate the pre-2026-08-31 shape ({fkey: ts}) so an in-place upgrade does not
# throw away a live park and re-page everything it was holding.
for k, v in list(parked.items()):
    if not isinstance(v, dict):
        parked[k] = {"since": v, "ids": [], "line": ""}

# BH-2316.2: parks the ledger remembers and this box does not (a rebuilt hub).
# Merged BEFORE the escalation loop below, so a restored park keeps its own
# `since` rather than being re-stamped `now`. The local record wins a tie. A
# hand-edited row never throws: a throw here would empty $SPLIT.
if dbparksf:
    try:
        for l in open(dbparksf, errors="ignore").read().splitlines():
            f = l.split("\t", 2)
            if len(f) < 3 or not f[0] or f[0].startswith("#") or f[0] in parked:
                continue
            # brake_read emits the detail through jq @tsv, which doubles every
            # backslash: a `line` holding `"` reads back as `\\"` and no longer
            # parses. Undo @tsv's escapes before giving up on the row.
            try: d = json.loads(f[2])
            except Exception:
                tsv = {"\\\\": "\\", "\\t": "\t", "\\n": "\n", "\\r": "\r"}
                try: d = json.loads(re.sub(r"\\[\\tnr]", lambda m: tsv[m.group(0)], f[2]))
                except Exception: d = {}
            if not isinstance(d, dict): d = {}
            try: since = float(d.get("since", f[1]))
            except Exception: since = float(f[1]) if f[1].isdigit() else now
            ids = d.get("ids") if isinstance(d.get("ids"), list) else []
            parked[f[0]] = {"since": since, "ids": [str(i) for i in ids],
                            "line": str(d.get("line", ""))}
    except Exception:
        pass

# RECORD a park for any family whose escalation is open, remembering WHICH
# alerts it covers. `since` is set once and never re-stamped: refreshing it on
# every sighting would put the TTL permanently out of reach and turn a bounded
# wait into a permanent silence.
escalated = []
newparks = []
for eline in open(escf, errors="ignore").read().splitlines():
    if "\t" not in eline: continue
    fkey, etext = eline.split("\t", 1)
    escalated.append(fkey)
    if fkey not in parked:
        parked[fkey] = {"since": now,
                        "ids": sorted({i for i, _l, s in rows if s == fkey}),
                        "line": etext[:400]}
        newparks.append(fkey)   # BH-1071: the rows whose state becomes `parked`

# Only the TTL releases a park on time. (An escalation resolving does NOT: our
# own groomer resolves them, so that would unpark almost immediately.)
kept = {k: v for k, v in parked.items() if now - v.get("since", 0) < park_ttl}
# BH-2316.2: every park this pass RELEASES, by the TTL here or by a new id below,
# is cleared in the ledger. Only these two decisions clear a row — never a key
# missing from a read, so a ledger outage cannot clear anything.
unparked = [k for k in parked if k not in kept and k not in newparks]
parked = kept

order, groups, held, held_rows = [], {}, 0, []
for _id, line, sig in rows:
    p = parked.get(sig)
    if p is not None:
        # A park covers the situation the medic actually looked at. An alert id
        # it has never seen is a DIFFERENT incident in the same family — very
        # possibly one this lane is allowed to fix (a second stuck build under a
        # ticket whose first build is awaiting a human merge). Release the park
        # rather than sit on it for a week.
        if _id in p.get("ids", []):
            held += 1; held_rows.append(f"{_id}\t{line[:200]}")
            continue
        del parked[sig]
        unparked.append(sig)
    if now - fams.get(sig, 0) < 6 * 3600:
        continue
    if sig in dbfams:          # another lane's session inside the same window
        continue
    if sig not in groups:
        order.append(sig); groups[sig] = []
    groups[sig].append(f"{_id}\t{line}")
run, defer = order[:cap], order[cap:]
# What was actually held, and what each parked family is waiting on. A count
# alone cannot tell an operator which problem stopped being worked.
with open(parklog, "w") as pl:
    for r in held_rows:
        pl.write("HELD\t" + r + "\n")
    # Parks RECORDED THIS PASS, one line per alert the park covers. The caller
    # writes those rows' state through to the table; a park recorded on an
    # earlier pass is already there, so re-announcing it would be N PATCHes a
    # pass for as long as the escalation stays open.
    for k in newparks:
        for i in parked.get(k, {}).get("ids", []):
            pl.write("NEWPARK\t%s\t%s\n" % (k, i))
    # BH-2316.2: the ledger's copy of each new park. The worker slices detail at
    # 4000 chars and a cut JSON reads back as {} (losing `since`), so trailing
    # ids are dropped from the ROW until it fits; the local park keeps them all.
    for k in newparks:
        if k not in parked: continue
        v = parked[k]; ids = list(v.get("ids", []))
        while True:
            d = json.dumps({"since": int(v["since"]), "ids": ids, "line": v.get("line", "")},
                           separators=(",", ":"))
            if len(d) <= 3900 or not ids: break
            ids.pop()
        pl.write("PARKREC\t%s\t%d\t%s\n" % (k, int(v["since"]), d))
    for k in unparked:
        pl.write("UNPARK\t%s\n" % k)
    for k, v in sorted(parked.items()):
        pl.write("PARKED\t%s\t%d\t%s\n" % (k, int(now - v.get("since", now)), v.get("line", "")[:200]))
# Stamp ONLY the families that actually get a session. A deferred family that
# got stamped would sit inside the 6h brake without ever having been looked at,
# so the next pass would skip it as a "repeat" — the deferral would silently
# become a loss. The caller marks only DISPATCHED ids seen, for the same reason:
# between the two of them, an unexamined alert must come back.
for f in run: fams[f] = now
# State BEFORE the dispatch file, and every write guarded. If a state write dies
# (read-only state dir, disk full) an unguarded exception here would leave the
# caller with a populated DISPATCH and an EMPTY $SPLIT, so its `awk '{print $N+0}'`
# would read 0 for every count and the pass would log numbers it never computed.
# A park that cannot be persisted is also a park that never ages: `since` would
# be re-stamped `now` on every pass and the TTL would never arrive. Say so.
state_err = ""
for path, obj in ((famf, {k: v for k, v in fams.items() if now - v < 7 * 86400}),
                  (parkf, parked)):
    try:
        json.dump(obj, open(path, "w"))
    except Exception as e:
        state_err = f"{path}: {e}"
with open(outf, "w") as o:
    for f in run:
        for r in groups[f]:
            o.write(f"{f}\t{r}\n")
print(f"{len(run)} {len(defer)} {held} {len(parked)}")
if state_err:
    sys.stderr.write(state_err + "\n")
PYF
)
[ -n "$DBPARKS" ] && rm -f "$DBPARKS"
RUN_FAMS=$(awk '{print $1+0}' <<<"$SPLIT")
DEFER_FAMS=$(awk '{print $2+0}' <<<"$SPLIT")
HELD_ALERTS=$(awk '{print $3+0}' <<<"$SPLIT")
PARK_N=$(awk '{print $4+0}' <<<"$SPLIT")
# Report the ACTUAL parked set the splitter computed, not the escalations read
# off the console: those differ the moment a park expires while its escalation
# is still open, and an earlier draft of this block cheerfully logged a family
# as parked one line before running a session for it.
if [ -s "$PARKLOG" ]; then
  while IFS=$'\t' read -r KIND A B C; do
    case "$KIND" in
      HELD)   echo "$(STAMP) medic held alert $A in a parked family — already escalated, awaiting a human :: $B" >> "$LOG" ;;
      # medic-parked.json is written before this file is read, so the local
      # record always exists first and the PATCH only mirrors it. Best effort in
      # both directions: a row that is not in the table 404s, silently.
      NEWPARK) if [ "$ALERTS_DB" = 1 ]; then
                 NPR=$(awk -F'\t' -v c="$B" '$1==c{print $2; exit}' "$ROWMAP")
                 alert_state_set "${NPR:-$B}" parked medic >/dev/null 2>&1; PRC=$?
                 # Silent is not an option: the local park stands either way, but
                 # a table that never hears about it keeps the row looking live.
                 [ "$PRC" -eq 0 ] \
                   || echo "$(STAMP) parked stamp rc=$PRC for ${NPR:-$B} — parked locally, not in the table" >> "$LOG"
               fi ;;
      PARKED) echo "$(STAMP) medic parked family $A (${B}s) — not re-diagnosed until a human acts or MEDIC_PARK_TTL (${PARK_TTL}s) expires :: ONE ACTION: $C" >> "$LOG" ;;
      # BH-2316.2: the ledger mirror of a park recorded or released this pass.
      # at = since, so the ledger ages a park out on the same clock as the file.
      PARKREC) [ "$BRAKE_DB" = 1 ] && { brake_mark medic-parked "$A" "$B" "$C" >/dev/null 2>&1 \
                 || echo "$(STAMP) medic db: park mark failed for family $A — parked locally only" >> "$LOG"; } ;;
      UNPARK)  [ "$BRAKE_DB" = 1 ] && { brake_clear medic-parked "$A" >/dev/null 2>&1 \
                 || echo "$(STAMP) medic db: park clear failed for family $A — released locally only" >> "$LOG"; } ;;
    esac
  done < "$PARKLOG"
fi
[ "${HELD_ALERTS:-0}" -gt 0 ] && \
  echo "$(STAMP) medic pass: held $HELD_ALERTS alert(s) across $PARK_N parked family(ies)" >> "$LOG"
if [ ! -s "$DISPATCH" ]; then
  echo "$(STAMP) medic skip: all unseen alerts in recently-examined families" >> "$LOG"
  rm -f "$DISPATCH" "$CANDIDATES" "$ESCFILE" "$PARKLOG" "$SPLITERR" "$ROWMAP" "$DBFAMS"; exit 0
fi
COUNT=$(grep -c . "$DISPATCH")
echo "$(STAMP) medic pass: $COUNT alert(s) across $RUN_FAMS famil(ies) — one session each project=$LLP_PROJECT" >> "$LOG"

# >>> claim before you buy (BH-1071)
# The claim is the persisted "has anyone already paid for this row?" check, and
# it is issued HERE — after the split, before the first agent-call. Only rows it
# returns are dispatched.
#
# AFTER the split and not before it, deliberately: claiming every candidate up
# front would stamp claimed_at on over-cap families too, and the fleet-wide
# brake above would then drop them next pass — a deferral turned into a loss.
# Claiming only what is about to be dispatched keeps claimed_at meaning exactly
# what the local stamp means, "a session ran".
#
# rc 0 with an EMPTY set is a real answer, not an outage: another lane holds
# those rows, and this pass buys nothing. Only rc != 0 falls back to today's set.
if [ "$ALERTS_DB" = 1 ]; then
  WANT=$(while IFS=$'\t' read -r FK CID LINE; do
           [ -n "$CID" ] || continue
           RID=$(awk -F'\t' -v c="$CID" '$1==c{print $2; exit}' "$ROWMAP")
           # No map entry means the console saw this one first and the table
           # never listed it: the row id is then the one every producer derives.
           [ -n "$RID" ] || RID=$(alert_state_key "$LINE")
           # Still nothing (no python3 on this box) means no derivable row id:
           # fall back to the candidate id. It claims nothing on the worker, so
           # the row is held back rather than dispatched behind the claim's back.
           [ -n "$RID" ] || RID="$CID"
           printf '%s\t%s\n' "$CID" "$RID"
         done < "$DISPATCH")
  NWANT=$(grep -c . <<<"$WANT")
  if [ "${NWANT:-0}" -gt 0 ]; then
    mapfile -t WIDS < <(cut -f2 <<<"$WANT" | sort -u)
    CLAIMED=$(alert_claim medic new 0 "$NWANT" "${WIDS[@]}"); CRC=$?
    if [ "$CRC" -eq 0 ]; then
      CIDS=$(printf '%s\n' "$CLAIMED" | awk -F'\t' 'NF>=13 {print $1}')
      KEEP=$(mktemp)
      while IFS=$'\t' read -r FK CID LINE; do
        [ -n "$CID" ] || continue
        RID=$(awk -F'\t' -v c="$CID" '$1==c{print $2; exit}' <<<"$WANT")
        # An empty RID would match the empty line an empty $CIDS here-string
        # still carries, and dispatch a row the claim never returned.
        [ -n "$RID" ] || continue
        grep -qxF "$RID" <<<"$CIDS" && printf '%s\t%s\t%s\n' "$FK" "$CID" "$LINE" >> "$KEEP"
      done < "$DISPATCH"
      # A family whose rows all came back unclaimed keeps its local 6h stamp
      # (they are held elsewhere) and is named here rather than vanishing.
      for FK in $(cut -f1 "$DISPATCH" | awk '!seen[$0]++'); do
        KN=$(awk -F'\t' -v f="$FK" '$1==f{n++} END{print n+0}' "$KEEP")
        [ "$KN" -gt 0 ] || echo "$(STAMP) medic claim: family $FK 0 of $(awk -F'\t' -v f="$FK" '$1==f{n++} END{print n+0}' "$DISPATCH") rows claimed — no session" >> "$LOG"
      done
      mv -f "$KEEP" "$DISPATCH"
      echo "$(STAMP) medic claim: $(grep -c . "$DISPATCH") of $NWANT candidate row(s) claimed" >> "$LOG"
      if [ ! -s "$DISPATCH" ]; then
        echo "$(STAMP) medic skip: the table claimed none of this pass's candidates — no session" >> "$LOG"
        rm -f "$DISPATCH" "$CANDIDATES" "$ESCFILE" "$PARKLOG" "$SPLITERR" "$ROWMAP" "$DBFAMS"; exit 0
      fi
    else
      echo "$(STAMP) medic claim rc=$CRC — alerts table unreachable, dispatching today's set" >> "$LOG"
    fi
  else
    echo "$(STAMP) medic claim: no candidate carried a row id — nothing claimed, dispatching today's set" >> "$LOG"
  fi
fi
# <<< claim before you buy

# --- DEFERRAL (begin) ---
# Over the cap: left for the next pass. Nothing is parked, because the console
# API still holds them — they are simply not consumed (not marked seen, not
# stamped) and, being older, they sort first next pass. A deferral that cannot
# be told apart from a drop is a drop, so it is declared either way; and past a
# threshold the DEPTH goes to ALERTS.log, because a per-pass count is a RATE and
# a reader cannot tell pass 3 from pass 60 while the oldest alert ages.
if [ "${DEFER_FAMS:-0}" -gt 0 ]; then
  echo "$(STAMP) medic pass: deferred $DEFER_FAMS famil(ies) to next pass — session cap ($MAX_FAMILIES); left unseen and unstamped so the console re-offers them" >> "$LOG"
  # BH-5942: one line per project per UTC day. N project runs evaluate this
  # every 30 min; the flag is per project, so one project cannot silence another.
  BFLAG="$HARNESS/flags/alerted-medic-backlog-$LLP_PROJECT-$(date -u +%Y%m%d)"
  if [ "$DEFER_FAMS" -gt "${MEDIC_BACKLOG_ALERT:-8}" ] && [ ! -e "$BFLAG" ]; then
    echo "$(STAMP) [alerts-medic] DEFERRAL BACKLOG: $DEFER_FAMS families still open and unexamined after this pass — arrivals exceed $MAX_FAMILIES families/pass and this lane runs every 30 min; the oldest alert is not being triaged (project $LLP_PROJECT; pages once a day per project)" >> "$HARNESS/logs/ALERTS.log"
    mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$BFLAG" 2>/dev/null
  fi
fi
# --- DEFERRAL (end) ---

# --- ORIENTATION MAP (begin) ---
# Same hoist as alert-triage.sh (2026-08-25): the harness's static map — log
# paths, box roster, ticket-fetch auth, and what this host actually CAN and
# CANNOT reach — rendered deterministically instead of rediscovered per session.
# Never blocks the medic; a failed render is declared in ALERTS.log rather than
# leaving the lane quietly mapless.
ORIENTATION=$("$HARNESS/bin/triage-map.sh" render 2>/dev/null) || ORIENTATION=""
if [ -z "$ORIENTATION" ]; then
  echo "$(STAMP) medic ran without orientation map — render failed" >> "$HARNESS/logs/ALERTS.log"
fi
# --- ORIENTATION MAP (end) ---

# --- FAMILY SPLIT (begin) ---
# One agent-call per root-cause family, SEQUENTIALLY. Sequential is deliberate:
# these sessions ssh to the same worker boxes and relaunch builds, so parallel
# lanes would race on a box's free slots, and per-call cost stays attributable.
# Per-session budget is unchanged; agent-call.sh resolves --max-budget-usd for
# this lane from the manifest. medic-run.txt is truncated once and then appended
# per family, so it still holds exactly this pass's output.
# >>> model-route (BH-1510.2): the medic runs on the housekeeping floor ladder,
# model_routes role `housekeeping.floor` (rung 0 = floor model + runner, rung 1
# = the claude fallback). No route = rc 75 before any family is bought, alerted
# by bin/lib/model-route.sh; nothing is guessed and no alert is marked seen.
. "$HARNESS/bin/lib/lane-model.sh"
lane_housekeeping_floor || {
  echo "$(STAMP) medic: no model route for role housekeeping.floor — pass skipped" >> "$LOG"
  rm -f "$DISPATCH" "$CANDIDATES" "$ESCFILE" "$PARKLOG" "$SPLITERR" "$ROWMAP" "$DBFAMS"; exit 75; }
# <<< model-route
MEDIC_RUN="$HARNESS/logs/medic-run.$LLP_PROJECT.txt"
: > "$MEDIC_RUN"
FAMILY_KEYS=$(cut -f1 "$DISPATCH" | awk '!seen[$0]++')
for FKEY in $FAMILY_KEYS; do
  FROWS=$(awk -F'\t' -v f="$FKEY" '$1==f' "$DISPATCH")
  FCOUNT=$(grep -c . <<<"$FROWS")
  # cut -f2- restores the rows exactly as the prompt has always received them
  # (id<TAB>line); the family key is harness bookkeeping, not the session's problem.
  # The RAW rows and the PROMPT's copy are two different things (BH-1039).
  # $FALERTS is what the model sees, cut to the lane's byte cap with a declared
  # marker; this lane has never had one, and one session was measured at 1.1M
  # input tokens.
  #
  # AND THE SEEN LIST IS DERIVED FROM THE CAPPED COPY, not the raw one (BH-1039
  # review, I2). The first draft marked every id in $FALERTS_RAW seen — including
  # ids the cap had dropped, which the model therefore never read. A seen id is
  # filtered out of every later pass for as long as it sits in the 500-line SEEN
  # window, so those alerts would have been silently retired without anyone
  # looking at them — the exact opposite of this file's own rule three lines
  # down ("not consuming an alert is how it comes back"). Dropped ids stay
  # unseen and come back next pass as a smaller family.
  FALERTS_RAW=$(cut -f2- <<<"$FROWS")
  FALERTS=$(printf '%s' "$FALERTS_RAW" | lane_evidence_cap medic); ECRC=$?
  # MARKER-ONLY EVIDENCE BUYS NOTHING (BH-1039 review r2, I4). rc 2 means not one
  # COMPLETE `id<TAB>line` record fits the cap, so the prompt would be the
  # truncation marker and no alert at all. Here that is worse than in the triage
  # lane: nothing would be marked SEEN either, so the same family would be
  # re-offered — and re-paid for — on every pass, forever. No session, nothing
  # SEEN, and the console keeps the alerts (not consuming one is how it comes
  # back), with the cap that did it named.
  if [ "${ECRC:-0}" -eq 2 ]; then
    echo "$(STAMP) medic session [family $FKEY, $FCOUNT alert(s)]: NO SESSION — not one complete alert fits the medic lane's byte cap ($(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf)), so the prompt would have been the truncation marker alone. Nothing marked seen; the alerts stay open. Raise the cap for lane medic." >> "$LOG"
    # ...AND IT PAGES ONCE A DAY, for the same reason the triage lane does: the
    # console keeps re-offering a family nothing can read, so without a human
    # raising the cap this repeats until the alert is aged out by someone else.
    EFLAG="$HARNESS/flags/alerted-medic-evidence-$(date -u +%Y%m%d)"
    [ -f "$EFLAG" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null
      echo "$(STAMP) [alerts-medic] EVIDENCE CAP TOO SMALL: family $FKEY ($FCOUNT alert(s)) has no single alert that fits the medic lane's byte cap, so it is skipped on every pass and stays open until the cap is raised (lane medic in $(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf), or LANE_BYTES_CAP_MEDIC for one run). Nothing is dropped and nothing is being billed. This pages once a day." >> "$HARNESS/logs/ALERTS.log"
      touch "$EFLAG" 2>/dev/null; }
    continue
  fi

PROMPT="You are the harness SRE medic on the hub ($(hostname -s 2>/dev/null)). These console alerts are open, older than 20 minutes, and the deterministic groomer could not settle them:

$FALERTS

SCOPE: this session is ONE root-cause family ($FCOUNT alert(s), key $FKEY). Any other alert open right now is being handled in its own session — do not go looking for it and do not widen past the alerts above.

$ORIENTATION

For EACH alert: STEP 0 — DETERMINISTIC RE-VERIFY: first check the claimed condition still holds with a direct lookup (gh pr view for PR claims, one curl for endpoint claims, stat for stuck files) — stale alerts get resolved with proof, not investigated. SENTRY FIRST for app errors: a 500/timeout/exception on an owned app gets /root/harness/bin/sentry-lookup.sh '<route or error text>' <project> before any theory (the fleet project name picks its own Sentry org and token; no-op without a token); app speed or failed API calls on a project with a PostHog source get /root/harness/bin/posthog-lookup.sh <project> --report api-failures (24 h) or /root/harness/bin/posthog-lookup.sh <project> --report web-vitals (p75 LCP, CLS, INP by route, 7 days), counts and routes only. Then DIAGNOSTIC DOCTRINE — before theorizing, reproduce the failure with the CALLER'S OWN credentials/config (the failing app's key, the failing lane's env), not a healthy stand-in: the 2026-08-16 project-4 outage burned 6 hours walking model/slug/allowlist theories when one call with the app's own OpenRouter key showed the billing pre-auth error immediately. Then diagnose the current truth, then act within these bounds ONLY:
- ALLOWED: ssh to any worker box listed in the FLEET table above (ssh root@<box>, key already set up); read any log/build dir; detach a slot worktree and delete a stale UNPUSHED ticket branch that blocks builds; relaunch a build (setsid /root/harness/bin/run-build.sh <project> <ticket-id> <KEY> — get the ticket id from the board API per /root/harness/prompts/<project>.md, and NEVER launch if the same KEY already has a running build or /root/harness/bin/free-slots.sh <project> reports 0 free — its first word; 'unlimited' there means the project is Fly-routed, the launch is enqueued to the pool and no local slot is consumed, so the gate does not apply); fire a project's DEPLOY_HOOK_URL (in its env file) when a merge is verifiably not serving; re-run /root/harness/bin/alerts-groom.sh; resolve alerts you have verified settled via POST $CONSOLE_URL/api/alerts/resolve with Bearer \$HARNESS_SECRET and body {\"ids\":[...]}. Additionally ALLOWED (widened per the operator, 2026-07-28): firing a triage RE-TRIGGER on a specific stuck ticket — POST {app_base}/api/board/tickets/{id}/triage (project-1; project-2 uses the same path; project-3 /api/feature-board/tickets/{id}/triage; project-4 /api/accounting/requests-board/tickets/{id}/triage) with the app's internal bearer token. This is idempotent and client-invisible (it only nudges the app's own triage queue). It is the ONLY board endpoint you may POST to — comments, tickets, status, turn remain FORBIDDEN.
- FORBIDDEN: merging or closing PRs, pushing code, editing any script or env file, touching databases beyond the migrations-status endpoints, posting board comments, creating tickets, anything on the project-1 production DB. If a fix requires any of these, ESCALATE instead.
- Escalation: at most ONE beat for THIS family: /root/harness/bin/beat.sh '{\"kind\":\"fleet_alert\",\"triaged\":true,\"project\":\"<the project this is about, spelled exactly as in the FLEET table (the FLEET table above is the authoritative list, rendered from fleet.conf on this run - a name typed from memory that no longer matches routes nowhere). Leave it EMPTY only when the problem is genuinely fleet-wide and belongs to no single project — the project is what routes this alert to its own Telegram topic, so a blank one buries a project problem in the General channel with everybody else's.)\",\"akey\":\"medic:$FKEY\",\"line\":\"MEDIC: <what is truly broken + the one action a human/orchestrator must take>\"}' — copy the akey EXACTLY as written: \"medic:$FKEY\", no timestamp, no hour, no counter, nothing appended. That key is this family's permanent address. If the same problem is still unfixed next pass, re-beating the SAME key is how the console collapses it into the one open row instead of minting another page; a key you decorate with the time is a brand-new alert every hour, which is precisely the loop this contract exists to prevent. \"triaged\":true is also mandatory: you already did the investigation, so this goes straight to the human rather than back through the triage lane for a second opinion on your own words. Only for problems you verified are REAL and cannot fix within bounds. Healthy-looking or already-recovered situations get resolved, not escalated. Escalating PARKS this family: you will not be asked about it again until a human acts or ${PARK_TTL}s elapse, so say everything the human needs in this one line.
- Append one line per alert to /root/harness/logs/medic.log: '<utc> <alert-id> <diagnosis> -> <action taken>'.

Work the list completely. Be a skeptic: verify before acting, prefer the smallest intervention, and never repeat an action another process is already performing."

# Housekeeping floor (cost lever, the operator 2026-08-20): the medic only ever sees
# family-brake-filtered, groomer-resistant alerts, and its bounds are strict —
# run it on the cheap open-model lane instead of the flagship. Any nonzero rc
# falls back through agent-call's standard ladder to claude (the model arg).
  OUT=$(mktemp)
  env ${FLOOR_RUNNERS_ONLY:+AGENT_CALL_RUNNERS="$FLOOR_RUNNERS_ONLY"} RUNNER_TRIAGE="$FLOOR_RUNNER" FIREWORKS_MODEL="$FLOOR_MODEL" \
    "$HARNESS/bin/agent-call.sh" triage medic "$FLOOR_FALLBACK" 1800 "$OUT" "$PROMPT" >/dev/null 2>&1
  RC=$?
  { echo "=== $(STAMP) family $FKEY ($FCOUNT alert(s)) rc=$RC ==="; cat "$OUT" 2>/dev/null; } >> "$MEDIC_RUN"
  # >>> llm-gate-refusal
  # NOTHING RAN, SO NOTHING IS CONSUMED (BH-1141 round 2, I4). rc 74..79 is
  # bin/agent-call.sh's before-billing family — the lane's own gate refused it
  # (LLM_LANE_ENABLED=0, a rung outside LLM_RUNNER_ALLOWED, the day's
  # LLM_USD_CAP_DAY), a lock, no account with headroom, the hub refusing build
  # work, a no-tools refusal, an argv-only or cliff-routed refusal. No model read
  # these alerts, and the SEEN list is a one-way door: an id in it is filtered
  # out of every later pass for as long as it sits in the 500-line window. Two
  # lines above, this file's own doctrine says "not consuming an alert is how it
  # comes back" — so an operator turning this lane off for an afternoon must not
  # silently throw away every alert that arrived during it. That is exactly the
  # loss BH-1141 closed one lane over, in bin/alert-triage.sh, while shipping the
  # knob that causes it here.
  if [ "$RC" -ge 74 ] && [ "$RC" -le 79 ]; then
    # AND THE 6h FAMILY BRAKE IS GIVEN BACK. The splitter stamps every
    # DISPATCHED family before the session, on the rule it states in its own
    # comment: "a deferred family that got stamped would sit inside the 6h brake
    # without ever having been looked at". A refused family is precisely that,
    # so the stamp this pass wrote is removed and the next pass offers it again.
    # Unconsumed ids with a stamped brake would come back in six hours, which is
    # the same loss wearing a clock.
    jq -c --arg k "$FKEY" 'del(.[$k])' "$FAM" > "$FAM.tmp" 2>/dev/null \
      && mv "$FAM.tmp" "$FAM" || rm -f "$FAM.tmp"
    echo "$(STAMP) medic session [family $FKEY, $FCOUNT alert(s)] NOT RUN (rc=$RC: nothing called, nothing billed) — the family is left unconsumed, its 6h brake stamp is released, and the console re-offers it next pass. See logs/failovers.log for which control refused it, and bin/harness-ctl.sh show alerts-medic for the knobs." >> "$LOG"
    rm -f "$OUT"
    continue
  fi
  # <<< llm-gate-refusal
  # Mark ONLY THIS family's ids seen, and only after its session ran. The ids of
  # a deferred family stay unseen on purpose: the console API is this lane's
  # queue, and not consuming an alert is how it comes back.
  # The cap's marker line carries no id and no tab; it is not an alert and must
  # never enter the SEEN list.
  # BH-2316.2: the ledger copy follows each local write (seen ids, and the 6h
  # family stamp the splitter already wrote locally), only now that a session ran.
  SEEN_N=0; SEEN_BAD=0
  while IFS=$'\t' read -r ID LINE; do
    case "$ID" in ''|'-- [capped:'*) continue ;; esac
    echo "$ID" >> "$SEEN"
    if [ "$BRAKE_DB" = 1 ]; then
      SEEN_N=$((SEEN_N+1))
      brake_mark medic-seen "$ID" "$(date +%s)" >/dev/null 2>&1 || SEEN_BAD=$((SEEN_BAD+1))
    fi
  done <<<"$FALERTS"
  if [ "$BRAKE_DB" = 1 ]; then
    [ "$SEEN_BAD" -eq 0 ] \
      || echo "$(STAMP) medic db: $SEEN_BAD of $SEEN_N seen marks failed for family $FKEY — seen locally only" >> "$LOG"
    brake_mark medic-family "$FKEY" "$(date +%s)" >/dev/null 2>&1 \
      || echo "$(STAMP) medic db: family mark failed for $FKEY — stamped locally only" >> "$LOG"
  fi
  echo "$(STAMP) medic session [family $FKEY, $FCOUNT alert(s)] rc=$RC" >> "$LOG"
  rm -f "$OUT"
done
# --- FAMILY SPLIT (end) ---
tail -500 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
rm -f "$DISPATCH" "$CANDIDATES" "$ESCFILE" "$PARKLOG" "$SPLITERR" "$ROWMAP" "$DBFAMS"
exit 0
