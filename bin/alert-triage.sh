#!/bin/bash
# alert-writer: by-design — a beat it raises is collected by its own next tick and would feed itself (see WHY THIS ONE WRITES ALERTS.log DIRECTLY below)
# alert-triage.sh — first-line alert triage (the operator, 2026-08-06). HUB cron */10.
# Collects every box's quarantined fleet_alert beats (see beat.sh), runs ONE
# fable session that investigates and FIXES what is fixable within the medic's
# bounds, and escalates to the operator ONLY what genuinely needs him — with what was
# already done and the single action required. Everything is logged to
# logs/alert-triage.log whether escalated or not.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=alert-triage
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# BH-655 follow-up (F1a/F1b/F1c): this lane sources NO token library of its own.
# Both fix-PR state reads go through bin/gh-pr-state.sh, a child that arms the
# repo-scoped App token and answers on REST. gh_auth_reset restores the GH_TOKEN
# of the shell that SOURCED gh-app-auth.sh, so sourcing it here — above the env
# load, as this file did until now — would hand the pre-env snapshot back to
# every later step of the tick (the BH-470 regression). In a child it cannot.

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-alert-triage, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off alert-triage.
# bin/lib/lane-gate.sh sources bin/jobs-client.sh itself when this lane has not,
# which is a function library and no token library — the note above still holds.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
# shellcheck source=lib/lane-switch.sh
. "${HARNESS}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # no lib: the file, as before
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alert-triage
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alert-triage
# THE CONDUCTOR'S PAUSE (BH-1201). While the merge conductor is not running its
# own merges — mode kill-switch, observe, or no published mode at all — this
# lane HOLDS the alert lines the conductor itself raised
# (`[orchestrator/merge-conductor]` / `[merge-conductor]`) instead of buying a
# session to investigate a pull request whose owner is mid-pause. A held line is
# re-spooled, never dropped: it comes back on the next tick and, past
# TRIAGE_SPOOL_MAX_AGE_H, retires on STEP 0's audited path. `unknown` holds, so
# an unreachable worker costs a minute rather than two lanes writing to one PR.
# The knob is TRIAGE_CONDUCTOR_HOLD; set it to 0 to opt this lane out entirely.
# Absent library (a box whose sync lagged) = no function = today's behaviour.
# shellcheck disable=SC1091
[ -r "$HARNESS/bin/lib/conductor-mode.sh" ] && . "$HARNESS/bin/lib/conductor-mode.sh" 2>/dev/null

LOG="$HARNESS/logs/alert-triage.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# >>> per-project runner (BH-5942)
# No argument (the cron line) = the DISPATCH: it collects once (the quarantine
# reads below are destructive, so N runs cannot each drain a box), routes every
# line to state/alert-triage/<project>/inbox.tsv by its beat `project`, starts
# one run per project (bin/lib/project-lanes.sh) and buys nothing. With a
# project = one PROJECT RUN: that project's inbox and deferral spool only,
# under locks/alert-triage-<project>.lock only, on the project's own GitHub
# App token and pinned Claude account. There is no lane-wide lock. This sits
# below the lane gate and lane_env_apply on purpose: a lane that is off forks
# nothing. The dispatch lock only stops two collections at once; it is
# released before any run starts.
H="$HARNESS"; LLP_LOG="$LOG"
# shellcheck source=bin/lib/triage-inbox.sh
. "$HARNESS/bin/lib/triage-inbox.sh" \
  || { echo "$(STAMP) triage: bin/lib/triage-inbox.sh did not load — no collection, no run" >> "$LOG"; exit 1; }
TRIAGE_DISPATCH=0
if llp_is_dispatch "${1:-}"; then
  TRIAGE_DISPATCH=1
  mkdir -p "$HARNESS/locks"; exec 9>"$HARNESS/locks/alert-triage.dispatch.lock"; flock -n 9 || exit 0
else
  llp_enter alert-triage alert-triage "${1:-}"
  llp_arm
fi
TRIAGE_PROJECT=""; [ "$TRIAGE_DISPATCH" = 1 ] || TRIAGE_PROJECT="$LLP_PROJECT"
# <<< per-project runner

# >>> model-route (BH-1510.2): the strong tier is model_routes role
# `alert.triage`; the floor tier (and the cliff retry) is the housekeeping floor
# ladder, role `housekeeping.floor` (rung 0 = floor model + runner, rung 1 = the
# claude fallback). Resolved BEFORE anything is read, leased or stamped: no route
# = rc 75 with nothing touched, alerted by bin/lib/model-route.sh. Never a guess.
. "$HARNESS/bin/lib/lane-model.sh"
{ ALERT_MODEL=$(lane_role_model alert.triage) && lane_housekeeping_floor; } \
  || { echo "$(STAMP) triage pass: no model route for alert.triage/housekeeping.floor — pass skipped" >> "$LOG"; exit 75; }
# <<< model-route

# --- VOLUME CAPS (begin, BH-1039) -------------------------------------------
# The bound this lane was missing on 2026-09-20: $793 in 12 hours against a
# $39-$61/day baseline, entirely inside a session cap that never moved. What
# moved was the PRICE — grok cliff-routed and the ladder descended to codex and
# then Fable over OpenRouter at ~$4 a session — so the bound that actually holds
# is stated in dollars per day. bin/lib/lane-caps.sh reads it; the numbers live
# in catalog/lane-caps.conf (flags/lane-caps.conf overrides it with no deploy).
#
# cost_price_tokens rides along because the day total has to PRICE the rows this
# lane's runners left blank. A cap that reads a blank cost column as $0.00 would
# never fire on precisely the lanes it exists for.
#
# A BOX WHOSE SYNC HAS NOT LANDED THE LIBRARY BEHAVES EXACTLY AS BEFORE: the
# stubs below make the cap not trip and the evidence cut at the same 20000 bytes
# this lane has always used. A missing file may not turn the de-noising layer
# off.
# shellcheck source=bin/lib/cost-row.sh
. "$HARNESS/bin/lib/cost-row.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/cost-row.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lane-caps.sh
. "$HARNESS/bin/lib/lane-caps.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-caps.sh" 2>/dev/null || true
command -v lane_day_cap_tripped >/dev/null 2>&1 || lane_day_cap_tripped() { return 1; }
command -v lane_evidence_cap   >/dev/null 2>&1 || lane_evidence_cap()   { head -c 20000; }
command -v lane_noise_cap_tripped >/dev/null 2>&1 || lane_noise_cap_tripped() { return 1; }
command -v lane_noise_record      >/dev/null 2>&1 || lane_noise_record()      { :; }
# BH-2544: closing the D1 rows this lane settles on its own (BH-2570 fills the
# lib in: only a positive re-verify closes a row, see its header). Sourced
# fail-open like the two libs above, so a box whose sync has not landed the file
# ticks exactly as before. TRIAGE_RUNNERS, the runner allowlist knob, is read
# just before the family loop below.
# shellcheck source=bin/lib/triage-close.sh
. "$HARNESS/bin/lib/triage-close.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/triage-close.sh" 2>/dev/null || true
command -v triage_close_ids   >/dev/null 2>&1 || triage_close_ids()   { :; }
command -v triage_settled_ids >/dev/null 2>&1 || triage_settled_ids() { :; }
# triage-close-off and triage-registry-off are read by lane_switch (BH-2320):
# a settings row first, the flags/ file when there is none. Fail-open like the
# libs above: without the lib the file alone decides, as before.
# shellcheck source=bin/lib/lane-switch.sh
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }

# BEFORE ANY COLLECTION. The quarantine is DRAINED by the collector (that is
# what `: > "$Q"` does), so a cap checked after it would have to spool the whole
# batch back to stay honest. Checked here, nothing is read, nothing is consumed,
# and every alert is still sitting where it was when the money runs out.
if lane_day_cap_tripped alert-triage; then
  echo "$(STAMP) triage pass: STOPPED on the lane's daily spend cap — no collection, no session, nothing consumed (see ALERTS.log and $(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf))" >> "$LOG"
  exit 0
fi

# THE NOISE BUDGET (BH-1168), in the same place and for the same reason. A
# session that concludes `handled=0 escalated=0` costs full price and produces
# nothing; 150 of the 192 sessions on 2026-09-20 were exactly that. The dollar
# cap bounds the bill, this bounds the pointlessness, and it fires whatever a
# session costs. A session that handles or escalates something resets the count
# (see the record below), so a lane finding real problems is never stopped by
# this morning's noise. Checked BEFORE any collection: nothing is read, no box
# is reached, and every alert is still where it was.
if lane_noise_cap_tripped alert-triage; then
  echo "$(STAMP) triage pass: STOPPED on the lane's noise budget — $(command -v lane_noise_count >/dev/null 2>&1 && lane_noise_count alert-triage || echo '?') session(s) today concluded handled=0 escalated=0 against a budget of $(command -v lane_noise_cap >/dev/null 2>&1 && lane_noise_cap alert-triage || echo '?'). No collection, no session, nothing consumed; every alert stays quarantined or spooled until 00:00Z or the next session that finds something. Raise the noise row in $(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf), or for one run LANE_NOISE_CAP_ALERT_TRIAGE=off. See ALERTS.log." >> "$LOG"
  exit 0
fi
# --- VOLUME CAPS (end) -------------------------------------------------------

# --- SESSION CAP OF ZERO (begin, BH-1164) -----------------------------------
# ZERO MEANS ZERO. `TRIAGE_MAX_FAMILIES=0` is the operator's pause — the only
# stop this lane had before the dollar cap above — and on 2026-09-20 it did not
# stop it. The splitter clamps with `cap = max(1, int(capstr))`, so the first
# family of every tick crossed anyway: 16:10Z-21:20Z the hub logged
# `1 of 1037 line(s) across 1 famil(ies) — one session each` NEXT TO
# `deferred 659 families to next tick — session cap (0)`, bought one ~$2-4
# session every ten minutes, and every one of them concluded `noise=1`. $38 in
# two hours behind a knob the operator, the lane log and the registry all called
# off. A pause that still spends is worse than no pause: it reads as stopped.
#
# BEFORE ANY COLLECTION, for the same reason the dollar cap above is: the
# collector DRAINS state/alert-quarantine.jsonl on the hub and on every box, so
# a check after it would have to spool the whole batch back to stay honest. Here
# nothing is read, nothing is consumed, no box is reached, and every alert —
# quarantined or already spooled — is still exactly where it was when the
# operator turned the lane off. Each box's own alert-flush.sh dead-man still
# escalates at 45 min, so a long pause is visible rather than silent.
#
# AND IT DOES NOT PAGE. This is a deliberate setting, not a fault; at */10 a page
# per tick is 144 a day, which is how the real ones get missed. One lane-log
# line, every tick, naming the knob that has to change to resume.
MAX_FAMILIES="${TRIAGE_MAX_FAMILIES:-4}"; MAX_FAMILIES="${MAX_FAMILIES//[[:space:]]/}"
# A TYPO IS NEITHER A PAUSE NOR A CRASH (the same rule lane_cap_bytes follows).
# A non-integer used to reach `int(capstr)` in the splitter, which raised — so
# every tick re-spooled the whole batch and nothing was triaged, forever, behind
# a "the splitter could not be run" line. Ignored and NAMED: an operator typo
# must not silently remove the de-noising layer any more than it may silently
# remove a bound.
if ! [[ "$MAX_FAMILIES" =~ ^-?[0-9]+$ ]]; then
  echo "$(STAMP) triage pass: TRIAGE_MAX_FAMILIES='$MAX_FAMILIES' is not a whole number — IGNORED, the default (4) stands" >> "$LOG"
  MAX_FAMILIES=4
fi
if [ "$MAX_FAMILIES" -le 0 ]; then
  echo "$(STAMP) triage pass: STOPPED — TRIAGE_MAX_FAMILIES=$MAX_FAMILIES means zero sessions. No collection, no session, nothing consumed, \$0; every alert stays quarantined or spooled. Set TRIAGE_MAX_FAMILIES to a positive number to resume." >> "$LOG"
  exit 0
fi
# --- SESSION CAP OF ZERO (end) ----------------------------------------------

# WORK is a file that outlives the process (BH-5942). The dispatch's keeps the
# lines an inbox append refused, for the next dispatch; a project run's keeps
# what a run that died had collected, for that project's next run.
if [ "$TRIAGE_DISPATCH" = 1 ]; then
  WORK="$(ti_dir)/dispatch-work.tsv"
else
  WORK="$LLP_STATE/work.tsv"
fi
mkdir -p "${WORK%/*}" 2>/dev/null; touch "$WORK" 2>/dev/null \
  || { echo "$(STAMP) triage: cannot write $WORK — nothing collected, nothing consumed" >> "$LOG"; exit 1; }
GRAB='Q=/root/harness/state/alert-quarantine.jsonl; [ -s "$Q" ] || exit 0; ( exec 7>"$Q.lock"; flock 7; cat "$Q"; : > "$Q" )'

# Families the previous tick could not fit under the session cap go in FIRST, so
# a family that lost the cap race last time wins the next one — first-appearance
# order is what decides the cap below, and without this a busy fleet could
# starve a deferred family indefinitely. These lines already carry their source
# prefix (that is why they live here rather than back in the box quarantines:
# writing them into alert-quarantine.jsonl would lose which box they came from).
# BH-5942: a project run's spool is its own, $LLP_STATE/deferred.tsv, and every
# re-spool below writes it. The dispatch drains the legacy shared spool and
# routes it like any collected line.
if [ "$TRIAGE_DISPATCH" = 1 ]; then
  DEFER_SPOOL="$HARNESS/state/alert-triage-deferred.tsv"
else
  DEFER_SPOOL="$LLP_STATE/deferred.tsv"
fi
# Absent, not empty: a drained spool is an empty file. Read below (BH-2344).
# Only the dispatch restores, and only when no spool exists at all.
SPOOL_ABSENT=0; [ "$TRIAGE_DISPATCH" = 1 ] && ti_spools_absent && SPOOL_ABSENT=1
ti_move "$DEFER_SPOOL" "$WORK" || true
[ "$TRIAGE_DISPATCH" = 1 ] || ti_move "$(ti_inbox "$LLP_PROJECT")" "$WORK" || true

# >>> alerts db claim (BH-1071)
# The alerts TABLE, when the box is opted in (flags/alerts-db). A row this lane
# claims is one no other lane may buy a session for, and — the reason this is
# worth a request — a row from a box that has since dropped off the tailnet is
# still triaged from here, where today it is invisible until that box's own
# flush dead-man fires at 45 min.
#
# FAIL OPEN, like everything else that talks to the worker: any rc but 0 and
# this tick is byte-for-byte today's, including the unfiltered grab. The rows
# are rendered back into the quarantine's own source<TAB>epoch<TAB>payload shape
# right here, so everything downstream — the family brake, the split, the cap,
# the prompt — sees exactly what it has always seen.
ALERTS_DB=0; CRC=1
# shellcheck source=bin/lib/alert-state.sh
[ -r "$HARNESS/bin/lib/alert-state.sh" ] && . "$HARNESS/bin/lib/alert-state.sh" 2>/dev/null
declare -F alerts_db_on >/dev/null 2>&1 && alerts_db_on && ALERTS_DB=1

# >>> brake ledger (BH-2344)
# The DB copy of this lane's three "already paid for" files, so a rebuilt hub
# neither re-buys a family triaged <6h ago nor loses its deferred and parked
# lines. THE LOCAL FILES STAY PRIMARY: the DB is read as a union and written
# after the file, every call fails open, and with the flag off nothing here
# runs — no request, no file. A read that fails is never "the DB has none":
# nothing is merged and nothing is cleared on it.
TRIAGE_BRAKE_DB=0
if [ "$ALERTS_DB" = 1 ]; then
  # shellcheck source=bin/lib/brake-ledger.sh
  if . "$HARNESS/bin/lib/brake-ledger.sh" 2>/dev/null && brake_db_on; then
    TRIAGE_BRAKE_DB=1
  else
    echo "$(STAMP) triage brake-ledger: bin/lib/brake-ledger.sh did not load — local brake files only this tick" >> "$LOG"
  fi
fi
_BRAKE_WARNED=" "
brake_warn() { # brake_warn <what> <rc> — ONE lane-log line per <what> per tick
  case "$_BRAKE_WARNED" in *" $1 "*) return 0 ;; esac
  _BRAKE_WARNED="$_BRAKE_WARNED$1 "
  echo "$(STAMP) triage brake-ledger: $1 failed (rc=$2) — the local file stands; nothing is merged or cleared on a failed call" >> "$LOG"
}
# triage_mirror <linesfile> [dbspool] — which spool lines the ledger should
# hold. Mirrorable = not `"dbrow":true` (those are already rows in `alerts`),
# valid UTF-8, <=3800 bytes, and an encoded detail the worker will not tear
# (it slices detail at 4000). Prints `M<TAB>sha<TAB>detail` for each one not
# already among dbspool's keys, `C<TAB>sha` for each dbspool key no longer in
# the file, and last `S<TAB><n not mirrorable for size>`.
triage_mirror() {
  python3 - "$1" "${2:-}" <<'PYM'
import hashlib, json, sys
linesf, dbf = sys.argv[1], sys.argv[2]
have = set()
if dbf:
    for row in open(dbf, errors="ignore"):
        k = row.split("\t", 1)[0].strip()
        if k and not k.startswith("#"):
            have.add(k)
want, big = {}, 0
try:
    raw = open(linesf, "rb").read().split(b"\n")
except FileNotFoundError:
    raw = []
for b in raw:
    if not b.strip() or b'"dbrow":true' in b:
        continue
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        big += 1
        continue
    det = json.dumps({"line": s}, ensure_ascii=False, separators=(",", ":"))
    if len(b) > 3800 or len(det.encode("utf-16-le")) // 2 > 3970:
        big += 1
        continue
    want[hashlib.sha256(b).hexdigest()] = det
for k, det in want.items():
    if k not in have:
        print("M\t%s\t%s" % (k, det))
if dbf:
    for k in sorted(have - set(want)):
        print("C\t%s" % k)
print("S\t%d" % big)
PYM
}
DBSPOOL=""; DBFAMS=""; SPOOL_READ_RC=1
if [ "$TRIAGE_BRAKE_DB" = 1 ] && { [ "$TRIAGE_DISPATCH" != 1 ] || [ "$SPOOL_ABSENT" = 1 ]; }; then
  DBSPOOL=$(mktemp)
  BRAKE_NOW="${TRIAGE_NOW:-}" brake_read triage-deferred 604800 > "$DBSPOOL"; SPOOL_READ_RC=$?
  if [ "$SPOOL_READ_RC" -ne 0 ]; then
    brake_warn spool-read "$SPOOL_READ_RC"
  elif [ "$SPOOL_ABSENT" = 1 ]; then
    # The local spool is gone (a rebuilt hub): the ledger's lines go in FIRST,
    # where the drained spool would have put them. A detail whose line does not
    # hash back to its key is torn and is skipped, never re-injected.
    RESTORED=$(python3 - "$DBSPOOL" "$WORK" <<'PYR'
import hashlib, json, re, sys
dbf, work = sys.argv[1:3]
have = {hashlib.sha256(b.rstrip(b"\n")).hexdigest() for b in open(work, "rb")}
UN = {"\\": "\\", "t": "\t", "n": "\n", "r": "\r"}
n = torn = 0
with open(work, "ab") as out:
    for row in open(dbf, errors="ignore"):
        parts = row.rstrip("\n").split("\t")
        if len(parts) < 3 or parts[0].startswith("#") or parts[0] in have:
            continue
        try:
            line = json.loads(re.sub(r"\\(.)", lambda m: UN.get(m.group(1), m.group(0)), parts[2]))["line"]
            b = line.encode("utf-8")
        except Exception:
            torn += 1
            continue
        if not isinstance(line, str) or hashlib.sha256(b).hexdigest() != parts[0]:
            torn += 1
            continue
        out.write(b + b"\n")
        have.add(parts[0])
        n += 1
print(n, torn)
PYR
    ) || RESTORED=""
    [ -n "$RESTORED" ] && echo "$(STAMP) triage brake-ledger: restored ${RESTORED%% *} deferred line(s) from brake:triage-deferred (local spool absent); ${RESTORED##* } torn row(s) skipped" >> "$LOG"
  fi
  # BH-5942: a project run mirrors only ITS spool, so it keeps only the rows
  # whose line it owns — never a clear of another project's row. A filter that
  # fails reads as a failed read: nothing is marked or cleared this run.
  if [ "$TRIAGE_DISPATCH" != 1 ] && [ "$SPOOL_READ_RC" -eq 0 ] && ! ti_owned_db "$DBSPOOL"; then
    SPOOL_READ_RC=1
    echo "$(STAMP) triage brake-ledger: could not keep $TRIAGE_PROJECT's rows of brake:triage-deferred" >> "$LOG"
  fi
  grep -q '^#truncated' "$DBSPOOL" && echo "$(STAMP) triage brake-ledger: brake:triage-deferred read is truncated — no row is marked or cleared this tick" >> "$LOG"
  [ "$SPOOL_READ_RC" -ne 0 ] && echo "$(STAMP) triage brake-ledger: brake:triage-deferred read failed — no row is marked or cleared this tick" >> "$LOG"
  # END OF TICK, NOT PER APPEND SITE. Seven places append to the spool; one diff
  # of the FINAL spool against the one read above marks what is new and clears
  # what the tick drained and did not put back — after it was in $WORK, and
  # only when that read was complete. A line deferred tick after tick costs no
  # request after its first, and a tick killed before this runs clears nothing.
  # A FAILED OR TRUNCATED READ MARKS NOTHING EITHER (PR #2445 review). With no
  # complete read to subtract, every spooled line looks new: ~2,000 PUTs a tick
  # at the hub's spool, 7-17 s each on a partition, all under the lane lock.
  # Skipping loses nothing — the next complete read marks whatever is missing.
  triage_spool_reconcile() {
    local cur act key det now=${TRIAGE_NOW:-$(date -u +%s)}
    now=${now%%.*}
    cur=$(mktemp)
    ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cat "$DEFER_SPOOL" 2>/dev/null ) > "$cur"
    local read_ok=0
    [ "$SPOOL_READ_RC" -eq 0 ] && ! grep -q '^#truncated' "$DBSPOOL" && read_ok=1
    while IFS=$'\t' read -r act key det; do
      case "$act" in
        M) [ "$read_ok" = 1 ] || continue
           brake_mark triage-deferred "$key" "$now" "$det" >/dev/null 2>&1 || brake_warn spool-mark $? ;;
        C) [ "$read_ok" = 1 ] || continue
           brake_clear triage-deferred "$key" >/dev/null 2>&1 || brake_warn spool-clear $? ;;
        S) [ "${key:-0}" -gt 0 ] && echo "$(STAMP) triage brake-ledger: $key deferred line(s) over 3800 bytes not mirrored to brake:triage-deferred — local spool only" >> "$LOG" ;;
      esac
    done < <(triage_mirror "$cur" "$([ "$SPOOL_READ_RC" -eq 0 ] && echo "$DBSPOOL")")
    rm -f "$cur" "$DBSPOOL" ${DBFAMS:+"$DBFAMS"}
  }
  [ "$TRIAGE_DISPATCH" = 1 ] || trap triage_spool_reconcile EXIT
fi
# <<< brake ledger

if [ "$TRIAGE_DISPATCH" = 1 ] && [ "$ALERTS_DB" = 1 ]; then
  CLAIM=$(alert_claim alert-triage quarantined 0 200); CRC=$?
  if [ "$CRC" -eq 0 ]; then
    # A row in the table is the table's: the hub's own grab drains its local
    # quarantine and leaves out the entries the claim already handed us. The
    # per-box ssh loop below does NOT run on this path (BH-2366): a box entry is
    # the table's once beat.sh marked it, and one whose mark missed is re-marked
    # by that box's alert-flush.sh, or flushed raw by its 45m dead-man.
    GRAB='Q=/root/harness/state/alert-quarantine.jsonl; [ -s "$Q" ] || exit 0; ( exec 7>"$Q.lock"; flock 7; grep -v -F "\"dbrow\":true" "$Q"; : > "$Q" )'
    NCLAIM=0
    # WHY awk AND NOT `IFS=$'\t' read`: tab is IFS *whitespace*, so bash collapses
    # runs of it and drops leading ones — an empty middle column (project and
    # claimed_by are routinely empty) silently shifts every field after it, and
    # the row arrives with its state in the project slot and no line at all.
    # This re-emits the five columns this lane reads with a control separator,
    # keeping `line` last and its embedded tabs intact. NF>=13 also drops the
    # contract's `#truncated` marker, which is not a row.
    while IFS=$'\001' read -r RID RBOX RPROJ RFS RSEV RLINE; do
      [ -n "$RID" ] || continue
      # The same row can reach this tick twice: once from the deferral spool and
      # once re-offered by the 900s lease. One line per row, either way. Since
      # BH-5942 the row may also still sit in a project's inbox, spool or work
      # file (ti_queued).
      { grep -q -F "\"akey\":\"orclane:$RID\"" "$WORK" 2>/dev/null || ti_queued "$RID"; } && continue
      [ -n "$RFS" ] && EPOCH=$(date -u -d "$RFS" +%s 2>/dev/null) || EPOCH=$(date -u +%s)
      [ -n "$EPOCH" ] || EPOCH=$(date -u +%s)
      PAYLOAD=$(jq -nc --arg p "$RPROJ" --arg id "$RID" --arg sev "$RSEV" --arg line "$RLINE" \
        '{kind:"fleet_alert",project:$p,akey:("orclane:"+$id),alertid:$id,severity:$sev,line:$line,dbrow:true}') || continue
      printf '%s\t%s\t%s\n' "${RBOX:-hub}" "$EPOCH" "$PAYLOAD" >> "$WORK"
      NCLAIM=$((NCLAIM+1))
    done < <(printf '%s\n' "$CLAIM" | awk -F'\t' 'NF>=13 {
        printf "%s\001%s\001%s\001%s\001%s\001", $1, $3, $4, $7, $12
        for (i = 13; i <= NF; i++) printf "%s%s", (i > 13 ? "\t" : ""), $i
        printf "\n" }')
    echo "$(STAMP) triage claim: $NCLAIM row(s) claimed from the alerts table" >> "$LOG"
  else
    echo "$(STAMP) triage claim rc=$CRC — alerts table unreachable, ssh grab runs unfiltered this tick" >> "$LOG"
  fi
fi
# <<< alerts db claim
SKIP_BOXES=0
[ "$ALERTS_DB" = 1 ] && [ "$CRC" -eq 0 ] && SKIP_BOXES=1

# Hub's own queue first, then each worker box (unreachable box → its own
# alert-flush.sh dead-man still escalates at 45 min, so skipping is safe).
[ "$TRIAGE_DISPATCH" = 1 ] && { bash -c "$GRAB" 2>/dev/null | sed 's/^/hub\t/' >> "$WORK" || true; }
# THE BOX LIST COMES FROM fleet.conf (2026-09-11) — every box that owns a live
# project, at its `tailnet_ip`, in ONE registry read.
#
# THIS IS A DELIBERATE WIDENING, not just a de-duplication. The old list was
# five bare addresses; the derived one is eight. It DROPS the project-10
# box (PARKED and commented out of the registry since 2026-08-25, so it was
# being probed for nothing) and ADDS project-5, project-6/project-7, small and
# project-9 — boxes that have owned live projects for weeks while their alert
# queues went uncollected, because nobody remembered to extend a literal list.
# That is the failure this derivation exists to end: a new box now appears here
# with no code change at all.
#
# ONLY WHEN THE TABLE DID NOT ANSWER (BH-2366). With the flag on and the claim
# at rc 0 the table is the collector and the loop is skipped; the flag off or
# any claim rc but 0 (1 outage, 2 route absent, 9 conflict) runs it exactly as
# before. Either way ONE lane-log line says which path this tick took.
if [ "$TRIAGE_DISPATCH" != 1 ]; then
  :   # a project run collects nothing: its lines arrived through its inbox
elif [ "$SKIP_BOXES" = 1 ]; then
  echo "$(STAMP) triage collect: table claim ok, per-box ssh grab skipped (box quarantines are re-marked by alert-flush.sh, or flushed by its 45m dead-man)" >> "$LOG"
else
  if [ "$ALERTS_DB" = 1 ]; then WHY="claim rc=$CRC"; else WHY="flag off"; fi
  echo "$(STAMP) triage collect: per-box ssh grab ran ($WHY)" >> "$LOG"
  for BOX in $("${HARNESS:-/root/harness}/bin/fleet-conf.sh" --tailnet-ips 2>/dev/null); do
    timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$BOX" "$GRAB" 2>/dev/null \
      | sed "s/^/$BOX\t/" >> "$WORK" || true
  done
fi

# >>> dispatch: route, then start the runs (BH-5942)
# WRITE FIRST, THEN FORGET. WORK is removed only after every line landed in
# its owner's inbox; a refused append keeps exactly those lines in WORK for the
# next dispatch, and the log says where they are.
if [ "$TRIAGE_DISPATCH" = 1 ]; then
  if [ -s "$WORK" ]; then
    if ROUTED=$(ti_route "$WORK"); then
      rm -f "$WORK"
      echo "$(STAMP) triage dispatch: routed to inboxes: $ROUTED" >> "$LOG"
    else
      echo "$(STAMP) triage dispatch: $ROUTED — those line(s) stay in $WORK for the next dispatch. Nothing is dropped." >> "$LOG"
    fi
  else
    rm -f "$WORK"
  fi
  # The legacy spool exists from here on, so a later dispatch restores from the
  # brake ledger only on a hub that lost its state.
  [ -e "$DEFER_SPOOL" ] || : >> "$DEFER_SPOOL" 2>/dev/null
  rm -f "${DBSPOOL:-}"
  exec 9>&-
  llp_dispatch alert-triage
  exit $?
fi
# <<< dispatch

[ -s "$WORK" ] || { rm -f "$WORK"; exit 0; }

# ── STEP 0: DETERMINISTIC RETIREMENT (BH-979) ───────────────────────────────
# Measured on the hub 2026-09-19: the deferral spool held 2019 lines and had
# grown for 2.5 days (median age 24.5h, max 55h) because arrivals beat the
# TRIAGE_MAX_FAMILIES cap, and 93% of what a session then looked at was noise it
# confirmed in its OWN step 0 — a PR already CLOSED/MERGED, a heartbeat already
# recovered — at 60K-900K input tokens a time. Those three facts are answered by
# a clock and one REST read, so the harness answers them here, for $0, before
# any family reaches the brake or the cap below.
#
# Retirement is DECLARED AND ARCHIVED, never silent: every removed line lands in
# state/alert-triage-expired-<date>.tsv with its reason, which is what keeps
# this a retirement and not the drop the spool exists to prevent. Every doubt
# keeps the line — see bin/triage-spool-retire.sh.
#
# One clock read per tick, passed into every child and into the python brake
# below, so a fixture can pin the day (same pattern as bin/hub-lease.sh:25).
TRIAGE_NOW="${TRIAGE_NOW:-$(date -u +%s)}"
# stderr goes to the LANE LOG, never /dev/null: this script ends `exit 0`, so a
# python traceback or an unwritable archive in here would otherwise vanish and
# the tick would run with no STEP 0 line and no reason why.
# TRIAGE_RETIRE_IDS_OUT (BH-2544): where the retire step lists the D1 alert ids
# of the lines it retired, for the step0 close below. Created and removed in this
# block, so no exit path leaks it.
RETIRE_IDS=$(mktemp)
# BH-5942: project runs overlap, and the retire step rewrites one shared file,
# state/triage-prstate.json. It runs under a short shared lock; a wait past 5 s
# skips STEP 0 for this run (every line is kept, as on any retire failure).
RETIRE_RC=0
RETIRE=$( { flock -w 5 8 || exit 199
            HARNESS="$HARNESS" TRIAGE_NOW="$TRIAGE_NOW" TRIAGE_RETIRE_IDS_OUT="$RETIRE_IDS" "$HARNESS/bin/triage-spool-retire.sh" "$WORK"
          } 8>"$HARNESS/locks/triage-prstate.lock" 2>>"$LOG") || RETIRE_RC=$?
[ "$RETIRE_RC" = 0 ] || RETIRE=""
[ "$RETIRE_RC" = 199 ] && echo "$(STAMP) triage pass: STEP 0 skipped — another run held locks/triage-prstate.lock past 5 s; every line is kept this run (project=$TRIAGE_PROJECT)" >> "$LOG"
if [ -n "$RETIRE" ]; then
  echo "$(STAMP) triage pass: STEP 0 $RETIRE" >> "$LOG"
  # ONE ALERTS line per UTC day, not one per tick: this lane fires every 10
  # minutes and an alarm that always rings is an alarm nobody reads. The lane
  # log above carries every tick's counts; ALERTS.log carries the fact that the
  # harness is now retiring alerts on its own, once, where a human sees it.
  RETIRED_N=$(awk '{n=0; for(i=1;i<=NF;i++){split($i,kv,"="); if(kv[1]=="aged"||kv[1]=="condstate"||kv[1]=="stale") n+=kv[2];} print n+0}' <<<"$RETIRE")
  if [ "${RETIRED_N:-0}" -gt 0 ]; then
    RDAY=$(date -u -d "@$TRIAGE_NOW" +%Y%m%d 2>/dev/null) || RDAY=$(date -u +%Y%m%d)
    RFLAG="$HARNESS/flags/alerted-spoolretire-$TRIAGE_PROJECT-$RDAY"
    # One marker per day, and only TODAY's is kept: the flag is a dedupe for the
    # current UTC day, so yesterday's is dead weight (the `extra-usage` flag
    # prunes its predecessor the same way). The archive, not the flag, is the
    # durable record.
    #
    # WHY THIS ONE WRITES ALERTS.log DIRECTLY instead of going through
    # bin/lane-alert.sh (which is the rule everywhere else, and which lines
    # 448/463/482 of this same script also break): lane-alert.sh emits a
    # fleet_alert beat, and a beat raised BY the alert-triage lane is collected
    # BY the alert-triage lane on its next tick — this declaration would feed
    # itself back into the spool it exists to describe, forever. A line in
    # ALERTS.log is where a human reads it and is not an input to this lane.
    find "$HARNESS/flags" -maxdepth 1 -name 'alerted-spoolretire-*' \
      ! -name "alerted-spoolretire-*$RDAY" -delete 2>/dev/null || true
    [ -f "$RFLAG" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$RFLAG" 2>/dev/null
      echo "$(STAMP) [alert-triage] SPOOL RETIREMENT: $RETIRE — alert lines past their age ceiling (TRIAGE_SPOOL_MAX_AGE_H=${TRIAGE_SPOOL_MAX_AGE_H:-24}h, conductor state notes ${TRIAGE_CONDSTATE_MAX_AGE_H:-6}h) or naming only CLOSED/MERGED PRs were retired to state/alert-triage-expired-$RDAY.tsv with a reason column. First retirement of this UTC day for project $TRIAGE_PROJECT; per-tick counts are in logs/alert-triage.log." >> "$HARNESS/logs/ALERTS.log"; }
  fi
fi
# Log first (above), then close. The switch triage-close-off (row, then file) skips it.
lane_switch triage-close-off || triage_close_ids step0 "$RETIRE_IDS"
rm -f "$RETIRE_IDS"
# Everything collected this tick can be noise, and a tick with nothing left to
# judge must cost nothing rather than fall through to an empty session.
[ -s "$WORK" ] || { rm -f "$WORK"; exit 0; }
# ── STEP 0 (end) ────────────────────────────────────────────────────────────

# >>> conductor hold (BH-1201)
# The conductor's OWN lines go back to the deferral spool while it is paused.
# This sits AFTER step 0 on purpose: a line past the age ceiling is retired on
# the audited path first, so a pause that outlives the ceiling still ends in
# state/alert-triage-expired-<date>.tsv with a reason, never in a silent drop.
# It sits BEFORE the family split, so a held line is never counted, never
# stamped into state/alert-families.json and never reaches agent-call.sh.
if command -v conductor_hold_active >/dev/null 2>&1 \
   && COND_MODE=$(conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); then
  COND_HELD=$(mktemp); COND_KEEP=$(mktemp)
  # The match is on the beat's `.line` and nothing else: a project or akey that
  # happens to read like a lane tag must not hold an alert, and a beat with no
  # usable line is KEPT (an unparseable payload is the splitter's business, not
  # this block's). Same regex as bin/triage-spool-retire.sh:190.
  python3 - "$WORK" "$COND_HELD" "$COND_KEEP" <<'PYC'
import json, re, sys
work, heldf, keepf = sys.argv[1:4]
COND = re.compile(r"\[(?:orchestrator/)?merge-conductor\]")
def line_of(raw):
    for part in reversed(raw.split("\t")):
        part = part.strip()
        if part.startswith("{"):
            try:
                v = json.loads(part).get("line")
            except Exception:
                return ""
            return v if isinstance(v, str) else ""
    return ""
with open(heldf, "w") as held, open(keepf, "w") as keep:
    for raw in open(work, errors="ignore"):
        (held if COND.search(line_of(raw)) else keep).write(raw)
PYC
  COND_N=$(grep -c . "$COND_HELD" 2>/dev/null) || COND_N=0
  if [ "${COND_N:-0}" -gt 0 ]; then
    # WRITE FIRST, THEN FORGET. The spool append has to succeed before $WORK
    # loses the lines: if the spool is unwritable, the honest failure is to
    # triage them this tick, not to hold them into nothing.
    if ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cat "$COND_HELD" >> "$DEFER_SPOOL" ) 2>/dev/null; then
      mv -f "$COND_KEEP" "$WORK"
      echo "$(STAMP) triage pass: held $COND_N conductor line(s): conductor paused (mode=$COND_MODE) — not consumed, not stamped, no session" >> "$LOG"
    else
      echo "$(STAMP) triage pass: could not re-spool $COND_N conductor line(s) to $DEFER_SPOOL while the conductor is paused (mode=$COND_MODE) — triaged this tick instead. Nothing is dropped." >> "$LOG"
    fi
  fi
  rm -f "$COND_HELD" "$COND_KEEP"
  # A tick of nothing but conductor lines buys nothing and stamps nothing.
  [ -s "$WORK" ] || { rm -f "$WORK"; exit 0; }
fi
# <<< conductor hold

COUNT=$(wc -l < "$WORK")

# ── Family brake (2026-08-15, the operator): this lane was ~$190/day because every
# tick with ANY alert bought a full Fable session, and recurring families got
# re-investigated from scratch each time. Deterministic rule: a family the AI
# triaged <6h ago is a REPEAT — logged, dropped, $0. Only lines carrying at
# least one not-recently-triaged family reach a session. Tiering (2026-08-15
# principle, floor added 2026-08-20): a BRAND-NEW family (never seen) gets the
# strong investigator on the standing RUNNER_TRIAGE lane; re-occurrences (seen
# before, TTL expired) get the housekeeping floor — cheap open model, same
# prompt, same bounds, claude fallback via agent-call's standard ladder.
#
# ── Scope per unit (2026-08-25) ────────────────────────────────────────────
# The same normalization now does a SECOND job: it GROUPS the surviving lines
# into root-cause families, and each family gets its OWN agent-call below.
# Why: one call for the whole batch is one long session that interleaves
# unrelated units and re-sends each unit's investigation in every iteration of
# the others — measured at 2 alerts / 56 turns / 108K transcript / 2.8M
# cumulative context. The harness decides that boundary; the model never does.
# There is deliberately ONE family function here, used by the brake and the
# split alike — two implementations of one rule is how they silently diverge.
# BH-5942: the brake files are the project's own, seeded on its first run by a
# COPY of the shared file (stamps and refusal counts carry over; the shared
# file is never written again).
FAM="$LLP_STATE/alert-families.json"
ti_seed "$FAM" "$HARNESS/state/alert-families.json"
[ -s "$FAM" ] || echo '{}' > "$FAM"
CLIFFDB="$LLP_STATE/alert-triage-cliff.json"
ti_seed "$CLIFFDB" "$HARNESS/state/alert-triage-cliff.json"
FILTERED=$(mktemp)
DEFERRED=$(mktemp)
# MAX_FAMILIES is resolved and validated at the top of this file (BH-1164), so a
# cap of 0 has already exited before a single line was collected. Everything
# below is therefore guaranteed a positive whole number.

# ── FIX-PR BRAKE (2026-09-17, #655) ─────────────────────────────────────────
# The 6h TTL brake above stops a family being re-investigated every tick. It
# does not stop it being re-investigated forever: the .capped jq bug produced
# 163 ALERTS lines between Sep 15 and Sep 17 and was correctly diagnosed every
# single time, because a family whose fix is a PENDING PULL REQUEST is not
# "not recently triaged" — it is ANSWERED, and the only useful output is
# "merge PR N". So a family with a recorded fix PR that bin/gh-pr-state.sh
# confirms is still OPEN is diverted here, before any session is bought, and the
# lane says "merge it" once a day instead of paying a model to say it again.
#
# Every doubt FAILS OPEN — no ledger, torn ledger, an entry with no url, a read
# that cannot answer, the kill switch — and the family buys its session exactly
# as it does today, with the reason in the lane log. A suppression may only ever
# follow a positive OPEN read, because the cost of being wrong here is an alert
# nobody ever looks at.
FIXPR="$LLP_STATE/alert-fix-prs.json"
ti_seed "$FIXPR" "$HARNESS/state/alert-fix-prs.json"
FIXPR_STALE_HOURS="${FIXPR_STALE_HOURS:-24}"
# TRIAGE_NOW (the tick's ONE clock read, used for the calendar-day beat dedupe
# below) is set in STEP 0 above, because the retirement needs the same clock.
FIXPR_OFF=0; lane_switch fixpr-suppress-off file && FIXPR_OFF=1
ANSWERED=$(mktemp)
FIXNOTES=$(mktemp)

# SEND THEN STAMP, AND THE SEND HAS TO BE ABLE TO FAIL (F2). bin/beat.sh returns
# 0 whether or not the console took the beat unless BEAT_STRICT=1 is set, so the
# invariant below was only ever true against a test stub. Every beat in this lane
# goes through beat_send: rc 0 = the console took it, rc 2 = this box has no
# console configured (there is nothing to retry, so that counts as delivered),
# anything else = not delivered and NOT stamped, so the next tick retries.
beat_send() {  # beat_send <json>; rc 0 = delivered (or nowhere to deliver)
  local rc=0
  BEAT_STRICT=1 "$HARNESS/bin/beat.sh" "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ]
}

# Both stampers below run only after beat_send returned 0: a stamp written for a
# beat that never left would silence the day's only "merge this" message, so
# "stamped without delivery" is impossible by construction.
fixpr_stamp() {  # fixpr_stamp <family> <beat_day> [<stale_beat_at>]
  python3 - "$FIXPR" "$1" "$2" "${3:-}" <<'PYS'
import json, os, sys
path, fam, day, stale = sys.argv[1:5]
try:
    with open(path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    raise SystemExit(0)
e = d.get(fam)
if not isinstance(e, dict):
    raise SystemExit(0)
if day:
    e["beat_day"] = day
if stale:
    e["stale_beat_at"] = int(float(stale))
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, path)
PYS
}

fixpr_record() {  # fixpr_record <family> <url> <now> — upsert, keeping first_seen
  python3 - "$FIXPR" "$1" "$2" "$3" <<'PYS'
import json, os, sys
path, fam, url, now = sys.argv[1:5]
try:
    with open(path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
e = d.get(fam)
if not isinstance(e, dict):
    e = {}
# The latest word wins on the url; first_seen is the age of the SUPPRESSION,
# which is what the stale escalation is measured against, so it never moves.
e["pr_url"] = url
e.setdefault("first_seen", int(float(now)))
e["last_checked"] = int(float(now))
e.setdefault("suppressed_total", 0)
e.setdefault("beat_day", "")
e.setdefault("stale_beat_at", 0)
d[fam] = e
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, path)
PYS
}
SETTLED=$(mktemp)
# family<TAB>stamp-before-this-tick (or `-` for a family this lane had never
# seen). Only the CLIFF REFUSAL block below reads it: a family that never got a
# session has to go back to the stamp it had, not to "never seen" (BH-1039
# review, N2).
PRESTAMP=$(mktemp)
# RESTORE THE PRE-TICK STAMP, do not pop it (BH-1039 review, N2). The splitter
# stamped this family when it put it in `run`; a family that never got a session
# must not sit inside the 6h brake. But popping the key makes a family this lane
# HAS seen look brand new, which buys it the strong tier on the next tick — the
# expensive half of the very decision that just declined it. $PRESTAMP carries
# what the stamp was before the tick. ONE copy, two callers (the cliff refusal
# and the marker-only evidence skip); two copies of this is how they diverge.
triage_restore_stamp() { # triage_restore_stamp <family>
  python3 - "$FAM" "$1" "$PRESTAMP" <<'PYU' 2>/dev/null || true
import json, os, sys
path, fam, prestamp = sys.argv[1:4]
try:
    with open(path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    raise SystemExit(0)
prior = None
try:
    for row in open(prestamp):
        k, _, v = row.rstrip("\n").partition("\t")
        if k == fam:
            prior = None if v == "-" else float(v)
            break
except Exception:
    prior = None
if prior is None:
    d.pop(fam, None)
else:
    d[fam] = prior
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, path)
PYU
  # The DB copy goes back to the same prior: a clear for a never-seen family.
  if [ "$TRIAGE_BRAKE_DB" = 1 ]; then
    local prior
    prior=$(awk -F'\t' -v f="$1" '$1 == f {print $2; exit}' "$PRESTAMP")
    if [ -z "$prior" ] || [ "$prior" = "-" ]; then
      brake_clear triage-family "$1" >/dev/null 2>&1 || brake_warn family-restore $?
    else
      brake_mark triage-family "$1" "${prior%%.*}" >/dev/null 2>&1 || brake_warn family-restore $?
    fi
  fi
}
# THE DB HALF OF THE 6h BRAKE (BH-2344): `family<TAB>epoch-or-ISO` from the
# families this lane stamped `triaged` in the alerts table in the last 6h and
# from its own brake:triage-family rows. `triaged`, not bare claims: this
# tick's own claim is a quarantined row and must not brake itself. Empty (and
# no file at all) when the flag is off; a failed read contributes nothing.
if [ "$TRIAGE_BRAKE_DB" = 1 ]; then
  DBFAMS=$(mktemp)
  BROWS=$(alert_families alert-triage 21600 triaged); BRC=$?
  if [ "$BRC" -eq 0 ]; then
    printf '%s\n' "$BROWS" | awk -F'\t' 'NF >= 2 {print $1 "\t" $2}' >> "$DBFAMS"
  else
    brake_warn families-read "$BRC"
  fi
  BROWS=$(BRAKE_NOW="$TRIAGE_NOW" brake_read triage-family 604800); BRC=$?
  if [ "$BRC" -eq 0 ]; then
    grep -q '^#truncated' <<<"$BROWS" && echo "$(STAMP) triage brake-ledger: brake:triage-family read is truncated — the rows it returned still brake" >> "$LOG"
    printf '%s\n' "$BROWS" | awk -F'\t' 'NF >= 2 && $1 !~ /^#/ {print $1 "\t" $2}' >> "$DBFAMS"
  else
    brake_warn family-brake-read "$BRC"
  fi
fi
SPLIT=$(python3 - "$WORK" "$FAM" "$FILTERED" "$DEFERRED" "$MAX_FAMILIES" "$HARNESS/bin" \
                  "$FIXPR" "$TRIAGE_NOW" "$FIXPR_OFF" "$ANSWERED" "$FIXNOTES" "$SETTLED" \
                  "$PRESTAMP" "$DBFAMS" <<'PYF'
import sys, json, os, re, subprocess
work, famf, outf, deff, capstr, bindir = sys.argv[1:7]
fixprf, nowstr, offstr, ansf, notesf, setf, prestampf, dbfamf = sys.argv[7:15]
sys.path.insert(0, bindir)
from alert_family import family   # ONE implementation, shared with alerts-medic.sh
cap = max(1, int(capstr))
fams = json.load(open(famf))
# The DB brake merges in as max(local, db) BEFORE the 6h check and the tier
# choice below, so a family a rebuilt hub has never seen locally is still a
# repeat, or a re-occurrence, exactly as the old hub would have judged it.
if dbfamf:
    from datetime import datetime, timezone
    import math
    merged = 0
    for row in open(dbfamf, errors="ignore"):
        k, _, v = row.rstrip("\n").partition("\t")
        if not re.fullmatch(r"[0-9a-f]{12}", k):
            continue
        try:
            at = float(v)
        except ValueError:
            try:
                dt = datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
                at = (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp()
            except ValueError:
                continue
        if math.isfinite(at) and at > fams.get(k, 0):
            fams[k] = at
            merged += 1
    sys.stderr.write(f"brake-ledger: {merged} famil(ies) stamped from the DB copy\n")
# The clock comes from the caller (TRIAGE_NOW) so the calendar-day dedupe below
# is pinnable; in production it is one `date -u +%s` per tick.
now = float(nowstr)
TTL = 6 * 3600

# ── the fix-PR ledger ───────────────────────────────────────────────────────
# family key -> {pr_url, first_seen, last_checked, suppressed_total, beat_day,
# stale_beat_at}. Read here, written whole-file under the lane's own flock.
# Unreadable is not empty: it is declared and nothing is suppressed on that
# tick. The kill switch skips the read entirely, which is also why the write
# below is skipped — a disabled brake must not be able to erase the ledger the
# sessions are still filling.
off = offstr == "1"
notes, _noted = [], set()
def note(kind, f, url, val):
    if (kind, f) in _noted:
        return
    _noted.add((kind, f))
    notes.append((kind, f, url or "-", val))

fixprs = {}
if not off:
    try:
        with open(fixprf) as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            fixprs = loaded
        else:
            note("ledger", "-", "-", "not-an-object")
    except FileNotFoundError:
        pass
    except Exception:
        note("ledger", "-", "-", "unparseable")

_pr = {}
def pr_state(url):
    """(STATE, rc) — one deterministic REST read per url per tick, no model.

    bin/gh-pr-state.sh, not `gh pr view`: the read is armed with the repo's App
    installation token (so this hot path runs on the SAME identity as the
    record-time read below, not on whatever the keyring happens to hold), it is
    REST so a rate limit answers 75 rather than the empty string #768 was
    about, and it is a child process so the arming cannot touch this lane's own
    GH_TOKEN. rc 44 (no such PR) is left to the caller as "unchecked": this
    ledger gates a suppression, and only a literal OPEN may buy silence.
    """
    if url not in _pr:
        try:
            r = subprocess.run([os.path.join(bindir, "gh-pr-state.sh"), url],
                               capture_output=True, text=True, timeout=60)
            _pr[url] = (r.stdout.strip().upper(), 0) if r.returncode == 0 else ("", r.returncode)
        except Exception:
            _pr[url] = ("", -1)
    return _pr[url]

def project_of(line):
    """The .project of a raw quarantine line (source<TAB>epoch<TAB>beat-json)."""
    for part in reversed(line.split("\t")):
        part = part.strip()
        if part.startswith("{"):
            try:
                p = json.loads(part).get("project")
            except Exception:
                return "harness"
            return str(p) if p else "harness"
    return "harness"

order, groups, tiers, dropped = [], {}, {}, 0
answered = {}
for line in open(work, errors="ignore"):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    f = family(line)
    if now - fams.get(f, 0) < TTL:
        dropped += 1
        continue
    ent = fixprs.get(f)
    if isinstance(ent, dict):
        url = str(ent.get("pr_url") or "").strip()
        try:
            first_seen = float(ent.get("first_seen"))
        except (TypeError, ValueError):
            first_seen = None
        if not url or first_seen is None:
            note("badentry", f, url, "no-url-or-unreadable-first_seen")
        else:
            state, rc = pr_state(url)
            if state == "OPEN":
                # ANSWERED: no session, no stamp in the 6h brake (it was never
                # triaged), no place in `order` (so the family cap and the
                # deferral spool below never see it).
                answered.setdefault(f, []).append(line)
                ent["last_checked"] = int(now)
                ent["suppressed_total"] = int(ent.get("suppressed_total") or 0) + 1
                continue
            if state in ("MERGED", "CLOSED"):
                # The fix may not have worked. THIS tick's lines are the next
                # occurrence, so the family is grouped and tiered below exactly
                # as if no entry had ever existed.
                note("drop", f, url, state)
                fixprs.pop(f, None)
            else:
                note("unchecked", f, url, str(rc))
    if f not in groups:
        order.append(f)
        groups[f] = []
        # Tiering is PER FAMILY now, not per pass: a family nobody has ever seen
        # gets the strong investigator; a re-occurrence whose TTL has expired
        # gets the housekeeping floor. Per-pass tiering meant one new family
        # bought the flagship for every stale one riding along with it.
        tiers[f] = "strong" if f not in fams else "floor"
    groups[f].append(line)

# ── DETERMINISTIC SETTLEMENT (BH-1039) ──────────────────────────────────────
# 150 of the 192 sessions on 2026-09-20 concluded `handled=0 escalated=0
# noise=1`, at roughly $4 each. The prompt's own STEP 0 already asks the model
# to re-verify the claimed condition and log NOISE-STALE when it no longer
# holds — and for two shapes of alert this script can answer that itself, for
# nothing. BOTH RULES ARE POSITIVE: each one points at a specific line in THIS
# BATCH that makes the settled line redundant.
#
#   resolved     the family's NEWEST line is a RETRACTION — a beat the emitter
#                itself marked `"resolved":true` / `"alertstate":"resolve"`, or
#                (for a retraction that carries no such field) one whose `.line`
#                BEGINS with RESOLVED. The flapping sweepstall pair (#735,
#                #1073) put 12 retraction lines each into one night's backlog.
#   superseded   a strictly NEWER beat with the SAME akey is in this batch, so
#                the older one describes a moment the newer one has already
#                replaced. The newest beat of every akey always survives.
#
# AGE IS NOT A RULE HERE (BH-1039 review, B2). The first draft settled anything
# older than a TTL whose TEXT matched `stale|heartbeat|...`, on the premise that
# such a class "re-beats while it holds". That premise is false for the very
# emitters the pattern matched: bin/fleet-heartbeat.sh:78 emits `hb-stale` ONCE
# behind state/stale-$h and only clears it on recovery, bin/merge-queue.sh's
# `mq-stale` is a one-shot, and pipeline-health's `stalepr` re-raises at 21600s
# — six times the 3600s TTL. A watcher that died at 02:00 and sat behind the
# 485-family backlog would have been logged NOISE-STALE and never restarted:
# a silent loss wearing a working cap's clothes, which is exactly what this
# wave exists to prevent.
#
# An operator who has VERIFIED an emitter re-raises faster than the TTL can
# still opt that emitter in by AKEY PREFIX (TRIAGE_STALE_AKEYS, comma
# separated, e.g. `health:sweepstall:`). It is empty by default, it is matched
# against the akey and never the payload text, and the TTL it is measured
# against must exceed that emitter's re-raise cadence.
#
# TEXT ANYWHERE IN THE PAYLOAD IS NOT A RETRACTION (BH-1039 review r2, B1). The
# first draft of this rule ran `\bRESOLVED\b|has recovered|...` over the WHOLE
# quarantine line, and family() keys on that same text — so a family that matched
# consisted only of matching lines and the "newest line" qualifier was vacuous:
# the rule was "text matches -> settled". Two emitters put the word inside a
# FIRING line. bin/fleet-slo.sh:271 ends every SLO BREACH with "...clears itself
# with a RESOLVED line.", and bin/blocked-resolver.sh:2444 parks a rung with "no
# repo/branch could be resolved for ...". Both were settled at \$0 and logged
# "condition cleared" — a false verdict on a live alert, which is worse than the
# session it saved.
#
# So the STRUCTURED FIELD decides. bin/lane-alert.sh:107 and
# bin/pipeline-health.sh:749/820/1008 — every retraction emitter in this repo —
# set `resolved:true` on the beat, and bin/beat.sh:227 already reads it to keep
# the remediator off a retraction. The text rule survives only for a retraction
# that carries no such field, ANCHORED to the start of the beat's own `.line`
# (`RESOLVED ...` / `[pipeline-health] RESOLVED ...`), never as a substring.
#
# Every settlement is written out with the alert text that justified it, so a
# settled alert is a LOGGED verdict and never an absence.
#
# It runs BEFORE the cap below on purpose: a family that costs nothing must not
# consume one of the tick's four session slots.
try:
    STALE_TTL = max(0, int(os.environ.get("TRIAGE_STALE_TTL") or 3600))
except (TypeError, ValueError):
    STALE_TTL = 3600
STALE_AKEYS = [p.strip() for p in (os.environ.get("TRIAGE_STALE_AKEYS") or "").split(",")
               if p.strip()]
# The DEFAULT is anchored at the start of `.line`: `RESOLVED foo` (pipeline-health
# without its tag), `[pipeline-health] RESOLVED foo`, `RESOLVED [orchestrator/x]:
# foo` (lane-alert). TRIAGE_RESOLVED_PATTERNS replaces it for an operator who has
# a retraction emitter this does not know about; it is matched with .match(), so
# it is anchored at the start whatever is typed into it.
#
# AND IT IS GUARDED (BH-1039 review r2, I1). An unguarded re.compile on an
# operator-typed pattern raises re.error, which kills the whole splitter — and a
# dead splitter leaves $FILTERED and $DEFERRED empty after the quarantine has
# already been drained, so the tick reads as "all lines are repeats" and every
# alert in it is gone. A typo may cost the knob, never the tick.
RESOLVED_DEFAULT = r"\s*(\[[^\]]+\]\s*)?RESOLVED\b"
_rpat = os.environ.get("TRIAGE_RESOLVED_PATTERNS") or RESOLVED_DEFAULT
try:
    RESOLVED_RE = re.compile(_rpat, re.I)
except re.error as e:
    note("resolvedre", "-", _rpat[:80], str(e)[:80])
    RESOLVED_RE = re.compile(RESOLVED_DEFAULT, re.I)

def beat_epoch(line):
    """The beat's own epoch from source<TAB>epoch<TAB>payload, or None.

    None is the honest answer for a line whose shape we do not recognise, and a
    line with no age never settles on age.
    """
    parts = line.split("\t")
    if len(parts) >= 3 and parts[1].strip().isdigit():
        return int(parts[1].strip())
    return None

def beat_payload(line):
    """The beat JSON of a raw quarantine line (source<TAB>epoch<TAB>beat-json)."""
    parts = line.split("\t")
    return parts[2] if len(parts) >= 3 else line


def beat_retracted(line):
    """Is this beat the EMITTER'S OWN retraction?  Structured field first.

    `resolved:true` is what bin/lane-alert.sh and bin/pipeline-health.sh put on a
    retraction beat and what bin/beat.sh already keys the remediator skip on, so
    reading it here is one fact with one owner rather than a second guess made
    from the text. `alertstate:"resolve"` rides along because lane-alert writes
    both and a future emitter may write only that one.

    The TEXT fallback is for a retraction with neither field, and it is anchored
    at the START of the beat's own `.line` — never a substring of the payload,
    which is what settled live SLO breaches at \$0 (review r2, B1).
    """
    payload = beat_payload(line)
    o = None
    try:
        o = json.loads(payload)
    except Exception:
        o = None
    if isinstance(o, dict):
        if o.get("resolved") is True or str(o.get("alertstate") or "").lower() == "resolve":
            return True
        text = o.get("line")
        if not isinstance(text, str):
            text = ""
    else:
        # Unparseable payload: fall back to the regex-scraped fields, exactly as
        # beat_akey does, so a torn line degrades the same way everywhere.
        if re.search(r'"resolved"\s*:\s*true', payload) \
           or re.search(r'"alertstate"\s*:\s*"resolve"', payload, re.I):
            return True
        m = re.search(r'"line"\s*:\s*"((?:[^"\\]|\\.)*)"', payload)
        text = m.group(1) if m else payload
    return bool(RESOLVED_RE.match(text))


def beat_akey(line):
    """The beat's own akey, or None — from the payload's JSON, never the text.

    The akey is what the EMITTER chose to identify this condition by, which is
    the only thing that can say which emitter we are looking at. Matching the
    raw line instead (the first draft) let the substring `stale` anywhere in a
    payload settle it.
    """
    parts = line.split("\t")
    payload = parts[2] if len(parts) >= 3 else line
    try:
        o = json.loads(payload)
        if isinstance(o, dict) and isinstance(o.get("akey"), str) and o["akey"]:
            return o["akey"]
    except Exception:
        pass
    m = re.search(r'"akey"\s*:\s*"([^"]*)"', payload)
    return m.group(1) if (m and m.group(1)) else None

settled_rows = []
for f in list(order):
    lines = groups[f]
    dated = [(beat_epoch(l), l) for l in lines]
    newest = max((e for e, _l in dated if e is not None), default=None)
    if newest is not None and any(e == newest and beat_retracted(l) for e, l in dated):
        for l in lines:
            settled_rows.append(
                ("resolved: the newest line in this family is the emitter's own retraction", l))
        order.remove(f); del groups[f]
        continue
    # The newest DATED beat per akey — the one line of each akey that is never
    # settled, because nothing in this batch supersedes it.
    newest_by_akey = {}
    for e, l in dated:
        if e is None:
            continue
        k = beat_akey(l)
        if k is None:
            continue
        if k not in newest_by_akey or e > newest_by_akey[k]:
            newest_by_akey[k] = e
    keep = []
    for e, l in dated:
        k = beat_akey(l) if e is not None else None
        if k is not None and e < newest_by_akey.get(k, e):
            settled_rows.append(
                ("superseded: a newer beat with the same akey (%s) is in this same batch, %ds after it"
                 % (k, int(newest_by_akey[k] - e)), l))
            continue
        if (k is not None and STALE_AKEYS and (now - e) > STALE_TTL
                and any(k.startswith(p) for p in STALE_AKEYS)):
            settled_rows.append(
                ("stale-akey: %ds old against a %ds TTL, and akey %s is opted in by TRIAGE_STALE_AKEYS "
                 "as an emitter that re-raises faster than that" % (int(now - e), STALE_TTL, k), l))
            continue
        keep.append(l)
    if keep:
        groups[f] = keep
    else:
        order.remove(f); del groups[f]
with open(setf, "w") as sfh:
    for reason, l in settled_rows:
        sfh.write("%s\t%s\n" % (reason, l.replace("\t", " ")))

run, defer = order[:cap], order[cap:]
with open(outf, "w") as o:
    for f in run:
        for l in groups[f]:
            o.write(f"{f}\t{tiers[f]}\t{l}\n")
with open(deff, "w") as d:
    for f in defer:
        for l in groups[f]:
            d.write(l + "\n")
# Stamp ONLY the families that actually get a session this tick. Stamping a
# deferred family would put it inside the 6h brake before it was ever looked
# at, so the very next tick would drop it as a "repeat" — the deferral would
# silently become a loss, which is the one outcome this cap may not produce.
with open(prestampf, "w") as pfh:
    for f in run:
        prior = fams.get(f)
        pfh.write("%s\t%s\n" % (f, ("-" if prior is None else repr(float(prior)))))
for f in run:
    fams[f] = now
with open(famf + ".tmp", "w") as fh:
    json.dump({k: v for k, v in fams.items() if now - v < 7 * 86400}, fh)
os.replace(famf + ".tmp", famf)

# Prune, mirroring the 7-day prune above: an entry nobody has managed to
# re-check in 30 days is stale bookkeeping, not a suppression anyone would
# defend. Entries only ever enter from a session (at most TRIAGE_MAX_FAMILIES a
# tick), so the ledger cannot grow per-run unbounded.
if not off:
    for f in list(fixprs):
        e = fixprs.get(f)
        if not isinstance(e, dict):
            continue
        try:
            seen = max(float(e.get("last_checked") or 0), float(e.get("first_seen") or 0))
        except (TypeError, ValueError):
            continue
        if seen and now - seen > 30 * 86400:
            note("prune", f, str(e.get("pr_url") or "-"), "unchecked-for-30d")
            fixprs.pop(f, None)

# Empty fields are written as "-": tab is IFS whitespace in bash, so a genuinely
# empty column would collapse and shift every field after it.
with open(ansf, "w") as a:
    for f, lines in answered.items():
        e = fixprs.get(f) or {}
        a.write("\t".join([
            f, str(e.get("pr_url") or "-"), str(len(lines)),
            str(int(e.get("suppressed_total") or 0)),
            str(int(float(e.get("first_seen") or 0))),
            str(e.get("beat_day") or "-"),
            str(int(float(e.get("stale_beat_at") or 0))),
            project_of(lines[0]),
        ]) + "\n")
with open(notesf, "w") as n:
    for row in notes:
        n.write("\t".join(row) + "\n")
if not off:
    tmp = fixprf + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(fixprs, fh)
    os.replace(tmp, fixprf)
sys.stderr.write(f"kept={sum(len(groups[f]) for f in run)} dropped={dropped} "
                 f"answered={sum(len(v) for v in answered.values())}\n")
print(f"{len(run)} {len(defer)}")
PYF
) 2>>"$LOG"
SPLIT_RC=$?
# A SPLITTER THAT DIED MUST NOT LOOK LIKE A QUIET TICK (BH-1039 review r2, I1).
# The collector has already DRAINED every box's quarantine and the deferral
# spool into $WORK, so a python exception here leaves $FILTERED and $DEFERRED
# empty and the tick falls through to "all N line(s) are repeats of families
# triaged <6h ago" — a false log line over a total loss of the batch. The lines
# go back on the spool (which is where a family that did not get a session
# belongs), and the lane says what happened. Re-spooling can duplicate a line if
# the crash landed after the split files were written; a duplicate alert costs
# one extra family in the next tick's cap, a lost one costs the alert.
if [ "${SPLIT_RC:-0}" -ne 0 ]; then
  ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cat "$WORK" >> "$DEFER_SPOOL" ) 2>/dev/null || true
  echo "$(STAMP) triage pass: the splitter could not be run (rc=$SPLIT_RC, traceback above) — $COUNT line(s) RE-SPOOLED to $DEFER_SPOOL and nothing was triaged or settled this tick. Nothing is dropped." >> "$LOG"
  rm -f "$WORK" "$FILTERED" "$DEFERRED" "$ANSWERED" "$FIXNOTES" "$SETTLED" "$PRESTAMP"
  exit 0
fi
# THE DB MARK, RIGHT AFTER THE LOCAL STAMP (BH-2344). The splitter just wrote
# fams[f]=now for exactly the families in $PRESTAMP (the `run` set); deferred,
# answered and settled families are not in it and get no mark. It goes out
# before the sessions so a hub that dies mid-session does not re-buy the
# family; a family that then gets no session is put back by
# triage_restore_stamp, in the DB as in the file.
if [ "$TRIAGE_BRAKE_DB" = 1 ]; then
  while IFS=$'\t' read -r BFAM _; do
    [ -n "$BFAM" ] || continue
    brake_mark triage-family "$BFAM" "${TRIAGE_NOW%%.*}" >/dev/null 2>&1 || brake_warn family-mark $?
  done < "$PRESTAMP"
fi
RUN_FAMS=$(awk '{print $1+0}' <<<"$SPLIT")
DEFER_FAMS=$(awk '{print $2+0}' <<<"$SPLIT")

# --- FIX-PR ANSWERED (begin) ---
# Everything the python brake decided about fix PRs, declared. The notes first,
# because they are the fail-open cases: a lane that quietly bought a session it
# expected to skip, or quietly skipped one it expected to buy, reads identically
# to one that worked.
if [ -s "$FIXNOTES" ]; then
  while IFS=$'\t' read -r NKIND NFAM NURL NVAL; do
    case "$NKIND" in
      ledger)    echo "$(STAMP) triage pass: fix-pr ledger unreadable ($NVAL) — RESET TO EMPTY, nothing suppressed this tick" >> "$LOG" ;;
      badentry)  echo "$(STAMP) fix-pr ledger entry for family $NFAM is unreadable ($NVAL) — not suppressed, session proceeds" >> "$LOG" ;;
      drop)      echo "$(STAMP) fix PR $NURL for family $NFAM is $NVAL — entry dropped, family triages normally" >> "$LOG" ;;
      unchecked) echo "$(STAMP) fix PR $NURL for family $NFAM could not be checked (gh-pr-state rc=$NVAL; 75=unverifiable, 44=no such PR) — not suppressed, session proceeds" >> "$LOG" ;;
      prune)     echo "$(STAMP) fix PR $NURL for family $NFAM was $NVAL — entry pruned, family triages normally" >> "$LOG" ;;
      resolvedre) echo "$(STAMP) triage pass: TRIAGE_RESOLVED_PATTERNS='$NURL' is not a valid regex ($NVAL) — IGNORED, the built-in retraction rule stands and nothing was lost" >> "$LOG" ;;
    esac
  done < "$FIXNOTES"
fi
# The answered families: one lane-log line each, then at most ONE beat per
# family per calendar day, because the point of this brake is to keep saying
# "merge it" without paying to rediscover why.
ANSWERED_FAMS=0
if [ -s "$ANSWERED" ]; then
  TODAY=$(date -u -d "@$TRIAGE_NOW" +%Y%m%d 2>/dev/null) || TODAY=$(date -u +%Y%m%d)
  while IFS=$'\t' read -r AFAM AURL ALINES ATOTAL AFIRST ABDAY ASTALE APROJ; do
    [ -n "${AFAM:-}" ] || continue
    ANSWERED_FAMS=$((ANSWERED_FAMS + 1))
    echo "$(STAMP) ANSWERED-PENDING-MERGE family=$AFAM lines=$ALINES total=$ATOTAL fix=$AURL (no session, \$0)" >> "$LOG"
    HOURS=$(( (TRIAGE_NOW - AFIRST) / 3600 ))
    if [ "$HOURS" -ge "$FIXPR_STALE_HOURS" ] && [ "${ASTALE:-0}" -eq 0 ]; then
      # Past the stale window this stops being a queue and starts being a
      # decision, so it goes out on its own akey. Once: the louder line REPLACES
      # the day's ordinary beat rather than adding to it.
      #
      # ONE PAGE, NOT TWO (F3). This used to ALSO append the line to
      # logs/ALERTS.log — and bin/poll-commands.sh (hub cron, every minute)
      # re-beats every new ALERTS.log line on its own akey, so one stale fix PR
      # produced two console rows and two Telegram pages a day. The beat below
      # IS the escalation; the durable local record is the lane log line, which
      # is written whether or not the console was reachable.
      SLINE="FIX PR STALE: $AURL has been open for ${HOURS}h with $ATOTAL alert line(s) suppressed behind it (family $AFAM). Merging it or closing it is the decision now."
      echo "$(STAMP) $SLINE" >> "$LOG"
      if beat_send "{\"kind\":\"fleet_alert\",\"project\":\"$APROJ\",\"triaged\":true,\"akey\":\"triage-fixpr-stale:$AFAM\",\"line\":\"$SLINE\"}"; then
        fixpr_stamp "$AFAM" "$TODAY" "$TRIAGE_NOW"
      fi
    elif [ "$ABDAY" != "$TODAY" ]; then
      DLINE="This alert keeps firing ($ALINES line(s) this tick, $ATOTAL since $(date -u -d "@$AFIRST" +%Y-%m-%d 2>/dev/null)). The fix is already written: PR $AURL is open and unmerged. Merge it: $AURL"
      if beat_send "{\"kind\":\"fleet_alert\",\"project\":\"$APROJ\",\"triaged\":true,\"akey\":\"triage-fixpr:$AFAM\",\"line\":\"$DLINE\"}"; then
        fixpr_stamp "$AFAM" "$TODAY" ""
      fi
    fi
  done < "$ANSWERED"
fi
# --- FIX-PR ANSWERED (end) ---

# --- FAMILY REGISTRY (begin, BH-2544) ---
# bin/triage-family-scripts.sh settles or parks whole families by the rows of
# alert_family_scripts; its header is the protocol. It may rewrite $FILTERED,
# append to $SETTLED (logged by the settlement block below) and list the families
# it removed in $REG_REMOVED. Each of those goes back to its pre-tick stamp HERE,
# before either exit below, so every path out of the tick is covered and nothing
# after this point re-stamps a family no longer in $FILTERED. A failed pass is
# one log line and the tick goes on with whatever $FILTERED holds.
REG_REMOVED=$(mktemp)
if ! lane_switch triage-registry-off; then
  "$HARNESS/bin/triage-family-scripts.sh" "$FILTERED" "$SETTLED" "$REG_REMOVED" 2>>"$LOG"
  REG_RC=$?
  [ "$REG_RC" = 0 ] || echo "$(STAMP) triage pass: family registry rc=$REG_RC — skipped, tick continues" >> "$LOG"
fi
while read -r RFAM; do
  [ -n "$RFAM" ] && triage_restore_stamp "$RFAM"
done < "$REG_REMOVED"
rm -f "$REG_REMOVED"
# --- FAMILY REGISTRY (end) ---

# --- DETERMINISTIC SETTLEMENT (begin, BH-1039) ---
# One NOISE-STALE line per settled alert, with the reason that settled it and
# the alert's own text as the proof. This is the SAME verdict a session would
# have written after its STEP 0 re-verify (bin/alert-digest.sh counts NOISE the
# same either way) — it just did not cost $4. A settlement that were merely an
# absence would be indistinguishable from an alert nobody looked at, which is
# the one thing this lane may never produce.
SETTLED_N=0
if [ -s "$SETTLED" ]; then
  while IFS=$'\t' read -r SREASON SLINE2; do
    [ -n "${SREASON:-}" ] || continue
    SETTLED_N=$((SETTLED_N + 1))
    echo "$(STAMP) NOISE-STALE (deterministic, no model call) $SREASON :: $(head -c 300 <<<"$SLINE2")" >> "$LOG"
  done < "$SETTLED"
  echo "$(STAMP) triage pass: settled $SETTLED_N line(s) deterministically — no session, \$0" >> "$LOG"
fi
# --- DETERMINISTIC SETTLEMENT (end) ---
# The D1 rows behind those lines are closed only now, after their NOISE-STALE
# lines are in the log. The switch triage-close-off (row, then file) skips it.
if ! lane_switch triage-close-off; then
  SETTLE_IDS=$(mktemp)
  triage_settled_ids "$SETTLED" "$SETTLE_IDS"
  triage_close_ids settle "$SETTLE_IDS"
  rm -f "$SETTLE_IDS"
fi

if [ ! -s "$FILTERED" ]; then
  if [ "$SETTLED_N" -gt 0 ] && [ "$ANSWERED_FAMS" -eq 0 ]; then
    echo "$(STAMP) triage pass: every remaining line was settled deterministically — no session (\$0)" >> "$LOG"
  elif [ "$ANSWERED_FAMS" -gt 0 ]; then
    echo "$(STAMP) triage pass: all $COUNT line(s) are repeats (<6h) or answered by an open fix PR — no session (\$0)" >> "$LOG"
  else
    echo "$(STAMP) triage pass: all $COUNT quarantined line(s) are repeats of families triaged <6h ago — no session (\$0)" >> "$LOG"
  fi
  rm -f "$WORK" "$FILTERED" "$DEFERRED" "$ANSWERED" "$FIXNOTES" "$SETTLED" "$PRESTAMP"; exit 0
fi
KEPT=$(grep -c . "$FILTERED")
echo "$(STAMP) triage pass: $KEPT of $COUNT line(s) across $RUN_FAMS famil(ies) — one session each project=$TRIAGE_PROJECT" >> "$LOG"

# --- DEFERRAL (begin) ---
# Over the cap: park the rest for the next tick (cron is */10) instead of paying
# for them now. They are NOT dropped and NOT stamped — a deferral that cannot be
# distinguished from a drop is a drop, so it is both spooled and declared.
if [ "${DEFER_FAMS:-0}" -gt 0 ] && [ -s "$DEFERRED" ]; then
  ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cat "$DEFERRED" >> "$DEFER_SPOOL" ) 2>/dev/null || true
  echo "$(STAMP) triage pass: deferred $DEFER_FAMS families to next tick — session cap ($MAX_FAMILIES)" >> "$LOG"
  # That line is a RATE. Throughput here is cap x 6 = 24 families/hour, and above
  # that the backlog grows while every tick keeps logging the same shape — tick 3
  # and tick 60 read identically, and the oldest alert ages with no trace. So the
  # DEPTH gets declared too, and to ALERTS.log where a human sees it rather than
  # the lane log nobody reads. Declaration, not a hard bound: dropping the tail
  # would turn a visible backlog into exactly the silent loss the spool exists
  # to prevent.
  DEPTH=$(wc -l < "$DEFER_SPOOL" 2>/dev/null || echo 0); DEPTH="${DEPTH//[[:space:]]/}"
  [ "${DEPTH:-0}" -gt "${TRIAGE_SPOOL_ALERT:-40}" ] && \
    echo "$(STAMP) [alert-triage] DEFERRAL BACKLOG: $DEPTH lines spooled for project $TRIAGE_PROJECT — arrivals exceed $MAX_FAMILIES families/tick; oldest alert is not being triaged" >> "$HARNESS/logs/ALERTS.log"
fi
# --- DEFERRAL (end) ---

# --- ORIENTATION MAP (begin) ---
# Hoist the harness's own static map into the prompt (2026-08-25). A 56-turn
# reconstruction of this lane found 14 turns spent re-deriving facts that are
# identical in every session (log paths, box roster, ticket-fetch auth) and 8
# more hunting a Railway fix on a host with no railway CLI or credential. The
# map is rendered from fleet.conf + live probes, never hand-written.
# It must never block triage — and never be silently absent either, because a
# lane running blind that looks identical to one running with a map is exactly
# the failure this whole wave is about. So: proceed without it, and DECLARE it.
ORIENTATION=$("$HARNESS/bin/triage-map.sh" render 2>/dev/null) || ORIENTATION=""
if [ -z "$ORIENTATION" ]; then
  echo "$(STAMP) triage ran without orientation map — render failed" >> "$HARNESS/logs/ALERTS.log"
fi
# --- ORIENTATION MAP (end) ---

# >>> sentry apps
# WHICH apps to check Sentry for is the registry, not a hand-kept sentence. The
# four-plus-one list this replaces was written when the fleet had five projects:
# a session triaging a 500 on any project enrolled since was never told to look,
# and a lane that never looked reads exactly like one that looked and found
# nothing. Empty registry -> point at the orientation map rather than name a
# stale subset.
SENTRY_APPS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g')
if [ -z "$SENTRY_APPS" ]; then
  SENTRY_APPS="any owned app in the FLEET table above"
  # Honest in the prompt, but a lane running on a degraded prompt must not look
  # identical to one running on a full one — the same rule the orientation map
  # above follows. Deduped per day; this lane fires on a cron.
  SFLAG="$HARNESS/flags/alerted-noregistry-alert-triage-$(date -u +%Y%m%d)"
  [ -f "$SFLAG" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$SFLAG" 2>/dev/null
    echo "$(STAMP) [alert-triage] fleet.conf gave an EMPTY project list — the Sentry-first hint names no app this run, so sessions may skip Sentry on real app errors." >> "$HARNESS/logs/ALERTS.log"; }
fi
# <<< sentry apps

# --- FAMILY SPLIT (begin) ---
# One agent-call per root-cause family, SEQUENTIALLY. Sequential is deliberate:
# these sessions ssh to the same worker boxes and relaunch builds, and parallel
# lanes would race each other on a box's free slots — and per-call cost stays
# attributable. Per-session budget is unchanged; agent-call.sh resolves
# --max-budget-usd for this lane from the manifest.

#
# THE PER-SESSION CEILING IS ENFORCED, NOT ASKED FOR (BH-979). The prompt has
# said READ CAPPED since 2026-08-25 and one session on 2026-09-19 still read
# 900,174 input tokens for ONE alert line. The bound that actually bites is
# agent-call.sh's own context_meter, whose ceiling for this lane lives in
# catalog/context-budgets.json (context_kill_tokens) — a knob an operator edits
# without a deploy. TRIAGE_CONTEXT_KILL_TOKENS overrides it for this lane only,
# and when it is unset NOTHING is exported, so the manifest stays the single
# source: two readers of one number is how they drift.
if [ -n "${TRIAGE_CONTEXT_KILL_TOKENS:-}" ]; then
  export CONTEXT_KILL_TOKENS="$TRIAGE_CONTEXT_KILL_TOKENS"
fi
# THE RUNNER ALLOWLIST (BH-2570). TRIAGE_RUNNERS (settings row
# lane.alert-triage.triage_runners, via lane_env_apply above) names the runners
# this lane may reach; grok is kept off it because the context meter cannot see
# grok requests (docs/verification-map/responder-cliff-cap.md). It rides each
# agent-call as a per-command AGENT_CALL_RUNNERS, never an export, normalised
# the way agent-call does it so the unquoted ${…:+…} below cannot word-split.
# The floor calls INTERSECT it with FLOOR_RUNNERS_ONLY (a one-rung floor), so
# the knob can only narrow the floor. Empty knob = no prefix = today's ladder.
_norm_runners() { local v="${1//[[:space:],]/,}"
  while case "$v" in *,,*) true ;; *) false ;; esac; do v="${v//,,/,}"; done
  v="${v#,}"; printf '%s' "${v%,}"; }
TRIAGE_ALLOW=$(_norm_runners "${TRIAGE_RUNNERS:-}")
FLOOR_ONLY=$(_norm_runners "${FLOOR_RUNNERS_ONLY:-}")
FLOOR_ALLOW="${FLOOR_ONLY:-$TRIAGE_ALLOW}"; FLOOR_NONE=0
if [ -n "$FLOOR_ONLY" ] && [ -n "$TRIAGE_ALLOW" ]; then
  FLOOR_ALLOW=""
  for _r in ${FLOOR_ONLY//,/ }; do
    case ",$TRIAGE_ALLOW," in *",$_r,"*) FLOOR_ALLOW="$FLOOR_ALLOW${FLOOR_ALLOW:+,}$_r" ;; esac
  done
  [ -n "$FLOOR_ALLOW" ] || FLOOR_NONE=1
fi
FLOOR_NONE_WHY="no floor runner allowed (FLOOR_RUNNERS_ONLY=$FLOOR_ONLY ∩ TRIAGE_RUNNERS=$TRIAGE_ALLOW is empty)"
FAMILY_KEYS=$(cut -f1 "$FILTERED" | awk '!seen[$0]++')
for FKEY in $FAMILY_KEYS; do
  FROWS=$(awk -F'\t' -v f="$FKEY" '$1==f' "$FILTERED")
  FTIER=$(head -1 <<<"$FROWS" | cut -f2)
  FCOUNT=$(grep -c . <<<"$FROWS")
  # cut -f3- restores the raw quarantine line (source<TAB>epoch<TAB>payload):
  # the family key and tier are harness bookkeeping, not something the session
  # should reason about.
  # THE CUT IS DECLARED (BH-1039). `head -c 20000` ended the evidence
  # mid-sentence with nothing to say it had been cut, so a session working from
  # a third of a family's lines read exactly like one working from all of them.
  # lane_evidence_cap keeps the NEWEST lines and puts a marker where the rest
  # were; the ceiling is catalog/lane-caps.conf, per lane, no deploy to change.
  ALERTS=$(cut -f3- <<<"$FROWS" | lane_evidence_cap alert-triage); ECRC=$?
  # MARKER-ONLY EVIDENCE BUYS NOTHING (BH-1039 review r2, I4). rc 2 means not one
  # COMPLETE line fits the cap, so the prompt would carry the truncation marker
  # and no alert at all — a strong-tier session on zero evidence, whose family is
  # then stamped into the 6h brake having been read by nobody. The family goes
  # back on the spool at its pre-tick stamp (the same restore the cliff refusal
  # does) and the lane says which cap did it.
  if [ "${ECRC:-0}" -eq 2 ]; then
    ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$DEFER_SPOOL" ) 2>/dev/null || true
    triage_restore_stamp "$FKEY"
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: NO SESSION — not one complete alert line fits the lane's ${LANE_BYTES_CAP_ALERT_TRIAGE:-configured} byte cap ($(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf)), so the prompt would have been the truncation marker alone. Family re-spooled at its pre-tick stamp; raise the cap for this lane." >> "$LOG"
    # ...AND IT PAGES ONCE A DAY. Re-spooling forever is a queue that never
    # drains: the family comes back every tick, is skipped every tick, and the
    # only cure is a human raising the cap. A stop nobody is told about is the
    # dead-feed shape this whole wave exists to end; one line per lane per UTC
    # day is the same bound every other daily alert here uses.
    EFLAG="$HARNESS/flags/alerted-triage-evidence-$(date -u +%Y%m%d)"
    [ -f "$EFLAG" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null
      echo "$(STAMP) [alert-triage] EVIDENCE CAP TOO SMALL: family $FKEY ($FCOUNT line(s)) has no single alert line that fits the lane's byte cap, so it is being re-spooled on every tick and will never be triaged until the cap is raised (lane alert-triage in $(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf), or LANE_BYTES_CAP_ALERT_TRIAGE for one run). Nothing is dropped and nothing is being billed. This pages once a day; every later family today is in the lane log." >> "$HARNESS/logs/ALERTS.log"
      touch "$EFLAG" 2>/dev/null; }
    continue
  fi

PROMPT="You are the harness alert-triage lane on the hub ($(hostname -s 2>/dev/null)), the layer in front of the operator's Telegram. These fleet_alert beats were QUARANTINED before he saw them (format: source<TAB>epoch<TAB>beat-json):

$ALERTS

SCOPE: this session is ONE root-cause family ($FCOUNT line(s), key $FKEY). Any other alert in this tick is being triaged in its own session right now — do not go looking for it, do not read the quarantine to find it, and do not widen past the lines above.

$ORIENTATION

DIAGNOSTIC DOCTRINE: before theorizing, reproduce the failure with the CALLER'S OWN credentials/config (the failing app's key, the failing lane's env), never a healthy stand-in — the 2026-08-16 project-4 outage burned 6h on model/slug/allowlist theories when one call with the app's own OpenRouter key showed the billing pre-auth error at once.

STEP 0 — DETERMINISTIC RE-VERIFY (before any investigation): check whether each alert's claimed condition STILL HOLDS with a direct lookup — a PR claimed open/aging: gh pr view --json state; an endpoint claimed failing: one curl; a stuck file/build: stat it. Alerts age: on 2026-08-21, 3 of 5 'needs a human' items escalated to the operator were already resolved (merged PRs still flagged). Condition cleared -> log NOISE-STALE with the proof and do NOT forward.
SENTRY FIRST for app errors: if an alert involves a 500/timeout/exception on an owned app ($SENTRY_APPS), run /root/harness/bin/sentry-lookup.sh '<route or error text>' before theorizing — matching unresolved issues (event counts, stacks, permalinks) are primary evidence, and their absence is evidence too. (The script no-ops if SENTRY_API_TOKEN is unset.)

For EACH alert, in order:
1. INVESTIGATE from the real state (logs, endpoints, boxes over ssh), never from the alert text alone — alerts routinely describe stale or already-fixed conditions.
   READ CAPPED. Every file you open, open with a cap: \`tail -c 20000\` on any log, never \`cat\` a rolling one. This lane measured 400K-1.4M input tokens per call against a 20KB prompt — the difference is entirely YOUR OWN reads, and each one then rides in the context of every remaining call this turn. A whole-file read of a rolling log is where that comes from.
   The alerts are ALREADY ABOVE in full: do not re-read the quarantine file or ALERTS.log wholesale to \"see them again\". If a capped read genuinely is not enough for one specific alert, widen THAT read and say why — never widen by default.
   Prefer a targeted lookup to a broad one: \`grep -c\`, a single \`stat\`, one \`gh pr view --json state\`, \`sentry-lookup.sh\` — a question answered by one line does not need the file.
2. FIX what is fixable inside the standing bounds (same as the medic): ssh to worker boxes; read any log/build dir; relaunch a stuck build per the medic SOP; fire a project's DEPLOY_HOOK_URL when a merge is verifiably not serving; re-run alerts-groom.sh; resolve settled console alerts via POST \$CONSOLE_URL/api/alerts/resolve with Bearer \$HARNESS_SECRET; re-trigger a stuck ticket's triage via the app's internal token (the ONLY board endpoint you may POST to). HARD LIMITS: never gh pr merge, never push to main, never write any prod DB, never post board comments/status, no secrets in output.
3. DECIDE: if fully handled or noise (duplicate, stale, recovered, informational) — log it and DO NOT forward. If it needs the operator (account limits, credentials, sign-offs, anything outside the bounds) — forward ONE consolidated beat per root cause:
   /root/harness/bin/beat.sh '{\"kind\":\"fleet_alert\",\"project\":\"<project>\",\"triaged\":true,\"akey\":\"triage:<root-cause-key>\",\"line\":\"<what happened — what I already did — the ONE action needed from you, with a direct deep link>\"}'
   The \"triaged\":true field is what lets it through the quarantine — never omit it, and never forward a raw untriaged line.
4. APPEND one line per alert to /root/harness/logs/alert-triage.log: HANDLED/ESCALATED/NOISE, the root cause, and what you did.
   If the root cause's fix is ALREADY WRITTEN and sitting in an OPEN pull request, add exactly one line immediately before your summary line: FIX-PR: https://github.com/<owner>/<repo>/pull/<n>. The harness verifies that url is open, records it, and stops buying sessions for this family until that PR merges or closes, so name a PR you checked yourself and nothing else.

Group aggressively: ten beats about one root cause are ONE investigation and at most ONE escalation. Your last line of output: a one-line summary (handled=N escalated=N noise=N)."

  # BEFORE THE CALL, NOT AFTER (BH-1168). The top-of-tick gate above stops the
  # NEXT tick; without this one the tick that crosses the budget would go on
  # buying up to TRIAGE_MAX_FAMILIES-1 more sessions on a lane that has already
  # been told it is finding nothing. Same shape as the rc-74 gate refusal: the
  # family goes back on the spool at its PRE-TICK stamp, so nothing is dropped
  # and nothing is marked seen by a session that never ran.
  if lane_noise_cap_tripped alert-triage; then
    ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$DEFER_SPOOL" ) 2>/dev/null || true
    triage_restore_stamp "$FKEY"
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: NO SESSION — the lane has spent its noise budget for today ($(command -v lane_noise_cap >/dev/null 2>&1 && lane_noise_cap alert-triage || echo '?') session(s) concluding handled=0 escalated=0). Nothing called, nothing billed; the family is re-spooled at its pre-tick stamp and waits for 00:00Z, a raised noise row in $(command -v lane_caps_source >/dev/null 2>&1 && lane_caps_source || echo catalog/lane-caps.conf), or LANE_NOISE_CAP_ALERT_TRIAGE=off." >> "$LOG"
    continue
  fi
  # NO FLOOR RUNNER LEFT (BH-2570): the knob and a one-rung floor share no
  # runner. The rc-74 refusal's three moves, with no call made.
  if [ "$FTIER" = "floor" ] && [ "$FLOOR_NONE" = 1 ]; then
    ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$DEFER_SPOOL" ) 2>/dev/null || true
    triage_restore_stamp "$FKEY"
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: NO SESSION — $FLOOR_NONE_WHY; family re-spooled at its pre-tick stamp" >> "$LOG"
    continue
  fi

  OUT=$(mktemp)
  # The ledger position BEFORE the call, so the tokens attributed below are this
  # session's own rows and not the lane's running total.
  COSTCSV="$HARNESS/logs/cost.csv"
  CSVPRE=$(wc -l < "$COSTCSV" 2>/dev/null || echo 0); CSVPRE="${CSVPRE//[[:space:]]/}"
  if [ "$FTIER" = "floor" ]; then
    # Housekeeping floor (cost lever, the operator 2026-08-20): re-occurring families run
    # on the cheap open-model lane. The claude model arg is what the standard
    # fallback ladder uses if the floor lane exits nonzero.
    env ${FLOOR_ALLOW:+AGENT_CALL_RUNNERS="$FLOOR_ALLOW"} RUNNER_TRIAGE="$FLOOR_RUNNER" FIREWORKS_MODEL="$FLOOR_MODEL" \
      "$HARNESS/bin/agent-call.sh" triage alert-triage "$FLOOR_FALLBACK" 2400 "$OUT" "$PROMPT" >/dev/null 2>&1
    ARC=$?
  else
    env ${TRIAGE_ALLOW:+AGENT_CALL_RUNNERS="$TRIAGE_ALLOW"} \
      "$HARNESS/bin/agent-call.sh" triage alert-triage "$ALERT_MODEL" 2400 "$OUT" "$PROMPT" >/dev/null 2>&1
    ARC=$?
  fi

  # --- CLIFF REFUSAL (begin, BH-1039) ---
  # rc 79 with agent-call's own cliff marker on $OUT means: the lane routed AWAY
  # from its runner ON PRICE and then refused to buy the same work on a rung
  # that costs ~100x (see the refuse gate in bin/agent-call.sh). Nothing ran,
  # nothing was billed.
  #
  # THE FLOOR RETRY IS THE EXIT PATH (BH-1039 review, B3). A refusal writes no
  # cost row, and agent-call's projection is the median of this lane's last ten
  # rc-0 rows — so a lane that refuses only refuses harder: the number that
  # caused it cannot move, every refused family comes back strong-tier next
  # tick, and after three ticks each one is dropped. The floor lane has no
  # cliff at this size and costs cents, so ONE retry there both triages the
  # family and writes the rc-0 row that lets the projection fall again.
  # TRIAGE_CLIFF_FLOOR_RETRY=0 turns it off.
  CLIFFED=0
  if [ "${ARC:-0}" -eq 79 ] && head -1 "$OUT" 2>/dev/null | grep -q '^AGENT_CALL_CLIFF_ROUTED'; then
    CLIFFED=1
  fi
  if [ "$CLIFFED" = 1 ] && [ "$FTIER" != "floor" ] && [ "${TRIAGE_CLIFF_FLOOR_RETRY:-1}" = 1 ] && [ "$FLOOR_NONE" = 1 ]; then
    # BH-2570: no runner the floor may use is on the knob — the retry is not
    # bought, and the family takes the refused-retry deferral below.
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: CLIFF REFUSED on the strong tier and the floor retry is skipped — $FLOOR_NONE_WHY; deferring" >> "$LOG"
  elif [ "$CLIFFED" = 1 ] && [ "$FTIER" != "floor" ] && [ "${TRIAGE_CLIFF_FLOOR_RETRY:-1}" = 1 ]; then
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: CLIFF REFUSED on the strong tier (nothing called, nothing billed) — retrying ONCE on the housekeeping floor, which has no cliff at this size" >> "$LOG"
    env ${FLOOR_ALLOW:+AGENT_CALL_RUNNERS="$FLOOR_ALLOW"} RUNNER_TRIAGE="$FLOOR_RUNNER" FIREWORKS_MODEL="$FLOOR_MODEL" \
      "$HARNESS/bin/agent-call.sh" triage alert-triage "$FLOOR_FALLBACK" 2400 "$OUT" "$PROMPT" >/dev/null 2>&1
    ARC=$?
    if [ "${ARC:-0}" -eq 79 ] && head -1 "$OUT" 2>/dev/null | grep -q '^AGENT_CALL_CLIFF_ROUTED'; then
      echo "$(STAMP) triage session [family $FKEY]: the floor retry was refused too — deferring" >> "$LOG"
    else
      CLIFFED=0
      FTIER="floor-after-cliff"
    fi
  fi
  if [ "$CLIFFED" = 1 ]; then
    [ -s "$CLIFFDB" ] || echo '{}' > "$CLIFFDB"
    CREFUSALS=$(python3 - "$CLIFFDB" "$FKEY" bump <<'PYC'
import json, os, sys
path, fam, mode = sys.argv[1:4]
try:
    with open(path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
n = int(d.get(fam) or 0) + 1 if mode == "bump" else 0
d[fam] = n
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, path)
print(n)
PYC
) || CREFUSALS=1
    if [ "${CREFUSALS:-1}" -le "${TRIAGE_CLIFF_MAX_REFUSALS:-3}" ]; then
      ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$DEFER_SPOOL" ) 2>/dev/null || true
      triage_restore_stamp "$FKEY"
      echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: CLIFF REFUSED (attempt $CREFUSALS of ${TRIAGE_CLIFF_MAX_REFUSALS:-3}) — nothing called, nothing billed; family re-spooled and returned to its pre-tick stamp for the next tick" >> "$LOG"
    else
      # PARKED, NOT DROPPED (BH-1039 review, I1). The first draft stopped
      # re-spooling AND deleted the lines, while its page said "$FCOUNT alert
      # line(s) are waiting on it" — they were not waiting anywhere. They go to
      # a parked file an operator can re-queue with one `cat >>` once the
      # routing is fixed, and the page says where they are.
      CPARK="$HARNESS/state/alert-triage-cliff-parked.tsv"
      ( exec 8>"$CPARK.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$CPARK" ) 2>/dev/null || true
      # The DB copy of the parked lines (BH-2344): marked on append, same filter
      # and key as the deferred mirror. Nothing re-queues from it — a rebuilt
      # hub's operator reads the rows and re-queues by hand, as with the file.
      CPARK_DB=""
      if [ "$TRIAGE_BRAKE_DB" = 1 ]; then
        CPARK_DB=" (DB copy: kind=brake:triage-cliff)"
        CPARK_LINES=$(mktemp)
        cut -f3- <<<"$FROWS" > "$CPARK_LINES"
        while IFS=$'\t' read -r CACT CKEY CDET; do
          case "$CACT" in
            M) brake_mark triage-cliff "$CKEY" "${TRIAGE_NOW%%.*}" "$CDET" >/dev/null 2>&1 \
                 || { brake_warn cliff-mark $?; CPARK_DB=" (DB copy kind=brake:triage-cliff is INCOMPLETE — see logs/alert-triage.log)"; } ;;
            S) [ "${CKEY:-0}" -gt 0 ] && CPARK_DB=" (DB copy kind=brake:triage-cliff lacks $CKEY line(s) over 3800 bytes)" ;;
          esac
        done < <(triage_mirror "$CPARK_LINES")
        rm -f "$CPARK_LINES"
      fi
      echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: CLIFF REFUSED $CREFUSALS times — no longer re-spooled; parked in $CPARK$CPARK_DB and escalated" >> "$LOG"
      # WRITE AFTER RECORD (BH-1327), the same ordering the medic's own park
      # mirror uses (bin/alerts-medic.sh:391). The park FILE is the primary and
      # the table only mirrors it — but a claimed row left `quarantined` is
      # re-offered by the worker's 900s lease, refused again, and appended to
      # this file again, every other tick, forever. `quarantined -> parked` is
      # an allowed edge and the claim filters on `state=quarantined`, so a
      # parked row is out of the queue by construction.
      #
      # ONLY THE ROWS THIS LANE CLAIMED. A `"dbrow":true` line came from
      # alert_claim and carries a lease; a beat `alertid` served over ssh has
      # neither, and parking it would be this lane stamping a row it never
      # claimed (one a writer-on box owns and the medic may still list).
      #
      # BEST EFFORT, NEVER RETRIED: a miss costs one more refusal at :900, and
      # the log says so rather than leaving a silent difference between a stamp
      # that works and one that fails every tick.
      if [ "$ALERTS_DB" = 1 ]; then
        for RID in $(grep -F '"dbrow":true' <<<"$FROWS" | grep -o '"alertid":"[^"]*"' | cut -d'"' -f4 | sort -u); do
          alert_state_set "$RID" parked alert-triage >/dev/null 2>&1; PRC=$?
          [ "$PRC" -eq 0 ] \
            || echo "$(STAMP) parked stamp rc=$PRC for $RID — parked in $CPARK, not by this lane in the table; if the row is still quarantined the lease re-offers it" >> "$LOG"
        done
      fi
      # ONE page per LANE per UTC day (BH-1039 review, B3) — not one per family.
      # The condition is a routing fact that is the same for every family on the
      # lane, and the 2026-09-20 backlog was 485 families: per-family paging
      # would have been ~485 pages about one unchanged fact.
      CFLAG="$HARNESS/flags/alerted-triage-cliff-$(date -u +%Y%m%d)"
      [ -f "$CFLAG" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null
        echo "$(STAMP) [alert-triage] CLIFF REFUSALS: this lane's projected context is past its runner's price cliff and the rung below costs more, so families are being refused (first one past the cap: $FKEY, $CREFUSALS refusals). Nothing has been billed and nothing has been triaged. Their lines are PARKED in $CPARK$CPARK_DB — re-queue with: cat $CPARK >> $HARNESS/state/alert-triage-deferred.tsv (the next dispatch routes it). Fix the routing (catalog/context-budgets.json: the alert-triage lane's cliff_route/cliff_refuse, or RUNNER_TRIAGE). This pages once a day; every later family today is in the lane log." >> "$HARNESS/logs/ALERTS.log"
        touch "$CFLAG" 2>/dev/null; }
    fi
    rm -f "$OUT"
    continue
  fi
  # >>> llm-gate-refusal
  # THE LANE'S OWN GATE REFUSED THIS CALL (BH-1141). rc 74 is agent-call's
  # before-billing family: the lane is disabled, the rung is outside
  # LLM_RUNNER_ALLOWED, or the day's LLM_USD_CAP_DAY is reached. Nothing ran and
  # nothing was billed — and the refusal already left a zero-cost
  # row_source=refused row in the ledger, so this branch does not have to
  # record the spend, only the WORK.
  #
  # PLACED AFTER THE CLIFF BLOCK ON PURPOSE: $ARC is final here. BH-1039's
  # floor retry re-runs agent-call and reassigns it, and a gate refusal on
  # that second call has to be read exactly like one on the first — from
  # above the cliff block it would have fallen through to the session log as
  # though the floor had answered.
  #
  # THE FAMILY GOES BACK, WITH ITS PRE-TICK STAMP. Falling through would log the
  # refusal marker as though it were a triage summary and consume the family's
  # stamp: the alert lines would be marked seen and never triaged, so turning a
  # lane off for an afternoon would quietly throw away every alert that arrived
  # during it. Re-spooling is a move, not a copy — the next tick reads the spool
  # — so a lane left off does not grow the file per tick.
  if [ "${ARC:-0}" -eq 74 ]; then
    ( exec 8>"$DEFER_SPOOL.lock"; flock 8; cut -f3- <<<"$FROWS" >> "$DEFER_SPOOL" ) 2>/dev/null || true
    triage_restore_stamp "$FKEY"
    echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s)]: REFUSED BY THE LANE'S OWN GATE (rc 74) — nothing called, nothing billed; the family is re-spooled at its pre-tick stamp and waits for the lane. See logs/failovers.log for which control refused it, and bin/harness-ctl.sh show alert-triage for the knobs." >> "$LOG"
    rm -f "$OUT"
    continue
  fi
  # <<< llm-gate-refusal

  # A session that RAN clears the family's refusal count: a lane that cliffed
  # twice last week must not be one refusal away from escalation today.
  if [ -s "$CLIFFDB" ]; then
    python3 - "$CLIFFDB" "$FKEY" <<'PYZ' 2>/dev/null || true
import json, os, sys
path, fam = sys.argv[1:3]
try:
    with open(path) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    raise SystemExit(0)
if fam not in d:
    raise SystemExit(0)
d[fam] = 0
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh)
os.replace(tmp, path)
PYZ
  fi
  # --- CLIFF REFUSAL (end) ---
  # THE NUMBER GOES WHERE THE OUTCOME IS. handled/escalated/noise landed in this
  # log and the input tokens landed in logs/cost.csv, so "93% noise at 400K-900K
  # tokens a session" took a join across two files to see. bin/lib/cost-row.sh's
  # COST_ROW_HDR columns 9 and 11 are input_toks and cache_read — the same unit the lane's ceiling in
  # catalog/context-budgets.json is declared in. `-` when the ledger wrote no
  # row for this call, which is itself worth seeing.
  #
  # FILTERED ON THE PROJECT AND STAGE COLUMNS, because logs/cost.csv is ONE
  # ledger for the whole box: on the hub the last 300 rows interleave
  # alert-triage (164), medic (99), responder (8) and cromford review (20),
  # and every one of those that lands while this session runs would otherwise be
  # attributed to it. bin/lib/cost-row.sh columns 3 and 4 are project and stage.
  SESS_TOKS=$(tail -n "+$((CSVPRE + 1))" "$COSTCSV" 2>/dev/null \
    | awk -F, -v p=alert-triage -v st=triage \
        '$3 == p && $4 == st && NF >= 13 {s += $9 + $11; n++}
         END {if (n) printf "%d", s; else printf "-"}')
  echo "$(STAMP) triage session [family $FKEY, $FCOUNT line(s), tier=$FTIER, in_toks=${SESS_TOKS:--}]: $(tail -1 "$OUT" 2>/dev/null | head -c 200)" >> "$LOG"

  # --- NOISE BUDGET RECORD (begin, BH-1168) ---
  # The verdict, read from $OUT rather than from the line above — the log line
  # is cut at 200 characters and a summary that lands past the cut would read as
  # a session with no verdict at all.
  #
  # BOTH FIELDS OR NOTHING (D9). A session that died, or answered without its
  # one-line summary, is neither a noise verdict nor a useful one: it must not
  # bump the budget (a broken runner would then stop the lane) and it must not
  # clear a real count either. Only sessions that were BOUGHT reach this line —
  # deterministic settlement, the cliff refusal (rc 79) and the gate refusal
  # (rc 74) all `continue` above — so nothing free is ever counted.
  NSUM=$(tail -1 "$OUT" 2>/dev/null)
  NHANDLED=$(grep -oE '\bhandled=[0-9]+' <<<"$NSUM" | head -1 | cut -d= -f2)
  NESC=$(grep -oE '\bescalated=[0-9]+' <<<"$NSUM" | head -1 | cut -d= -f2)
  if [ -n "$NHANDLED" ] && [ -n "$NESC" ]; then
    lane_noise_record alert-triage "$NHANDLED" "$NESC"
  fi
  # --- NOISE BUDGET RECORD (end) ---

  # --- FIX-PR RECORD (begin) ---
  # agent-call.sh writes only the session's LAST message to $OUT, which is why
  # the step-4 contract asks for the line immediately before the summary line.
  # The match is anchored: a url mentioned mid-sentence, an /issues/ path or a
  # bare "PR #573" is not a record. And the harness verifies the state itself
  # before writing, because this ledger gates a suppression — a hallucinated,
  # merged or closed PR must never be able to buy silence.
  FIXURL=$(grep -oE '^FIX-PR: *https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$OUT" 2>/dev/null | head -1 | sed 's/^FIX-PR: *//')
  if [ -n "$FIXURL" ]; then
    # Same reader as the per-tick brake above (F1b): one identity, one protocol,
    # one place to change. Anything that is not a literal OPEN is not recorded.
    FIXST=$(timeout 60 "$HARNESS/bin/gh-pr-state.sh" "$FIXURL" 2>/dev/null | tr -d '[:space:]')
    if [ "$FIXST" = OPEN ]; then
      fixpr_record "$FKEY" "$FIXURL" "$TRIAGE_NOW"
      echo "$(STAMP) triage session [family $FKEY] named fix PR $FIXURL (OPEN) — recorded; no session for this family until it merges or closes" >> "$LOG"
    else
      echo "$(STAMP) triage session [family $FKEY] named fix PR $FIXURL but it reads ${FIXST:-unverifiable} — not recorded" >> "$LOG"
    fi
  fi
  # --- FIX-PR RECORD (end) ---

  # WRITE AFTER BUY (BH-1071). The row is stamped triaged only once
  # agent-call.sh has returned, never before: a stamp that outruns the
  # session is how an alert gets marked handled and is never handled. Best
  # effort — a PATCH that fails costs at most one duplicate session when the
  # 900s lease re-offers a row THIS LANE CLAIMED (BH-1327: not every id here is
  # one), which is the cheap direction of this trade.
  if [ "$ALERTS_DB" = 1 ]; then
    # WHICH IDS ARE ROWS THIS LANE HOLDS (BH-1327). The stamp is attempted for
    # every `alertid` in the family and stays that way: a row a writer-on box
    # created is exactly what must not be left `new` for bin/alerts-medic.sh to
    # list and buy a second session for. But bin/lane-alert.sh and
    # bin/claude-auth-check.sh also emit `alertid` beats that have NO row unless
    # that box's writer side is on, and for those a 404 is not a failed stamp —
    # there is no row, and no lease to re-offer anything.
    DBIDS=$(grep -F '"dbrow":true' <<<"$FROWS" | grep -o '"alertid":"[^"]*"' | cut -d'"' -f4 | sort -u)
    for RID in $(grep -o '"alertid":"[^"]*"' <<<"$FROWS" | cut -d'"' -f4 | sort -u); do
      # A miss is survivable but never silent: with no line here a stamp that
      # fails every tick looks exactly like one that works, while the lease
      # re-offers the row and the lane buys the same session again at :900.
      alert_state_set "$RID" triaged alert-triage >/dev/null 2>&1; SRC=$?
      [ "$SRC" -eq 0 ] && continue
      # An EMPTY $DBIDS here-string still carries one empty line, and
      # `grep -qxF ""` matches it — which would label every beat alertid a
      # claimed row. The same trap bin/alerts-medic.sh:449 guards.
      if [ -n "$DBIDS" ] && grep -qxF "$RID" <<<"$DBIDS"; then
        echo "$(STAMP) triaged stamp rc=$SRC for $RID — the row is re-offered when its lease lapses" >> "$LOG"
      elif [ "$SRC" -eq 2 ]; then
        echo "$(STAMP) triaged stamp: no table row for $RID (a beat alertid this lane never claimed) — nothing to stamp, nothing is re-offered" >> "$LOG"
      else
        echo "$(STAMP) triaged stamp rc=$SRC for $RID (a beat alertid this lane never claimed) — no lease here to re-offer it" >> "$LOG"
      fi
    done
  fi
  rm -f "$OUT"
done
# --- FAMILY SPLIT (end) ---
rm -f "$WORK" "$FILTERED" "$DEFERRED" "$ANSWERED" "$FIXNOTES" "$SETTLED" "$PRESTAMP"
exit 0
