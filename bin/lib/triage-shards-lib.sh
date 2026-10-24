#!/bin/bash
# bin/lib/triage-shards-lib.sh — the shared vocabulary of "which ticket does this
# scope line belong to, and may a session for it start right now".
#
# WHY (the operator, 2026-09-14, 04:2xZ: "can we get multiple triagers like we have
# multiple builders? ... do that"). Builders already fan out — one pool machine
# per queued build. Triage did not. bin/run-triage.sh ran ONE session per project
# per tick, under ONE per-project flock, and that single agent call worked every
# changed ticket, every queue line and every result dir one after another with a
# 10800s timeout. A board with thirty moved tickets waited for one reader to read
# thirty threads in series, and the next tick exited "previous run still active,
# skipping" the whole time it did. That is the ceiling this removes: the tick
# becomes a DISPATCHER and each ticket key gets its own detached session.
#
# WHY A LIB. bin/run-triage.sh decides what to launch and bin/triage-shard.sh is
# what runs; they have to agree on the same four facts — which key a scope line
# belongs to, what that key's lock is called, whether shards are armed at all,
# and how many may run — and a second opinion on any of them is either two
# sessions on one client ticket or a ticket nobody triaged. So they are functions
# here and both callers read them.
#
# Sourced, never executed. Safe under `set -u`. Nothing here logs, alerts or
# launches anything: every function answers a question and the CALLER decides
# what it means.

# BH-2318: a re-arm edits the consumed fingerprint, so the project's
# ledgers(kind=triage_gate) row has to follow it (triage_shard_rearm below).
# No lib = no row, today's behaviour.
# No HARNESS/H = no root = only the sibling copy is tried (BH-2650).
_TSH_R="${HARNESS:-${H:-}}"
for _TSH_P in "$(dirname "${BASH_SOURCE[0]}")/triage-gate-ledger.sh" ${_TSH_R:+"$_TSH_R/bin/lib/triage-gate-ledger.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_TSH_P" ] && { . "$_TSH_P"; break; }
done
unset _TSH_P _TSH_R

# _tsh_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, the same way bin/lib/preplan-lib.sh:_preplan_env and
#   bin/lib/build-caps.sh:build_slots do — a function asked an arithmetic question
#   must never be the reason a box's secrets enter a caller's environment.
_tsh_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -n "$h" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# triage_shards_on [harness] -> 1 | 0     (DEFAULT 1 — shards are ON)
#
# THE KILL FLAG. 0 restores the single session exactly: one agent call over the
# whole tick scope, the per-project flock held across it, byte for byte what
# bin/run-triage.sh did before this change. flags/triage-shards-off is honoured
# beside the env var because an operator killing this at 3am should not have to
# edit env/global.env on every box — the shape every other flag in flags/ has.
# BH-2437: read through lane_switch, so the `switch.triage-shards-off` settings
# row decides first (or flags/triage-shards-off when no row exists).
triage_shards_on() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -n "${HARNESS:-${H:-}}" ] && [ -f "${HARNESS:-${H:-}}/flags/$1" ]; }
  [ -n "$h" ] && HARNESS="$h" lane_switch triage-shards-off && { printf '0\n'; return 0; }
  v=$(_tsh_env "$h" TRIAGE_SHARDS 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# triage_shards_max [harness] -> concurrent shards allowed on THIS BOX, 0 = no cap
#
# DEFAULT 0, and that is the point (the operator, 2026-09-13: "we never lock and
# serialize"). A cap here would be the same mistake BUILD_SLOTS stopped making:
# nothing queues, so over a cap the unit is simply LEFT IN SCOPE and re-offered
# next tick. Non-numeric text reads as 0 rather than inventing a ceiling nobody
# set — an unreadable knob must never be the thing that stops triage.
triage_shards_max() {
  local v; v=$(_tsh_env "${1:-${HARNESS:-${H:-}}}" TRIAGE_SHARDS_MAX 0)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s\n' "$v"
}

# triage_shard_timeout [harness] -> per-shard agent-call timeout in seconds
#   The tick's own 10800 stays the default: a shard is one ticket, but a ticket
#   whose thread needs an hour still needs an hour. This is a ceiling, not a
#   budget — agent-call.sh resolves the dollar cap from the lane manifest.
triage_shard_timeout() {
  local v; v=$(_tsh_env "${1:-${HARNESS:-${H:-}}}" TRIAGE_SHARD_TIMEOUT 10800)
  case "$v" in ''|*[!0-9]*) v=10800 ;; esac
  printf '%s\n' "$v"
}

# triage_shard_gh <harness> <project> -> 1 when this project's board is GitHub
#   Issues, else 0.
#
# It decides ONE thing: whether `TK-563` and `563` are the same ticket. They are
# on a GitHub-Issues board — bin/gate-diff.sh names a changed issue by its bare
# NUMBER while READY-QUEUE.log and every build dir spell it `<PREFIX>-<number>` —
# and on an in-app board they are not (a board fingerprint there carries cuids).
# Getting it wrong is not dangerous in either direction: a missed merge means two
# shards for one ticket, each scoped to a different concern.
#
# Two independent signals because fleet.conf is not readable everywhere this
# runs: the registry's board-prefix column ("-" IS the GitHub-Issues marker,
# bin/triage-gate.sh reads it the same way), and the stored fingerprint itself,
# which bin/triage-gate.sh writes as {"issues":...,"prs":...} on exactly these
# boards. Either one answering yes is enough.
triage_shard_gh() {
  local h="${1:-}" p="${2:-}" bp
  bp=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null || true)
  [ "$bp" = "-" ] && { printf '1\n'; return 0; }
  case "$(head -c 11 "$h/state/$p.gate.json" 2>/dev/null)" in
    '{"issues":') printf '1\n'; return 0 ;;
  esac
  printf '0\n'
}

# triage_shard_canon <key> <gh> -> the canonical unit key, rc 1 when unusable
#
# Canonical, because the same ticket reaches the dispatcher under two spellings
# and one shard must own both (see triage_shard_gh). It is also a FILENAME — a
# lock, an out file, a prompt — so anything outside [A-Za-z0-9._-] is refused
# rather than mangled: a key we cannot name is a key we decline to shard, and
# the caller falls back to the single session that has always handled it.
triage_shard_canon() {
  local k="${1:-}" gh="${2:-0}"
  case "$k" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#k}" -le 48 ] || return 1
  if [ "$gh" = 1 ]; then
    case "$k" in
      [A-Za-z]*-[0-9]*) case "${k##*-}" in *[!0-9]*) : ;; *) k="${k##*-}" ;; esac ;;
    esac
  fi
  printf '%s\n' "$k"
}

# triage_shard_key <class> <project> <gh> <line> -> canonical key, rc 1 on any
#   line this function cannot place.
#
# THE THREE SCOPE SHAPES bin/run-triage.sh already computes, and nothing else:
#   board   bin/gate-diff.sh / bin/unblocked-children.sh:
#           `board <boardid>: NEW|CHANGED|REMOVED|UNBLOCKED|STACKABLE <id> ...`
#   queue   READY-QUEUE.log lines and queue_list rows — both start with the key
#   result  `<build-dir> :: <first RESULT line>` from the sweep scope
#
# A `board prs:` line names a PULL REQUEST, not a ticket, and it is kept as its
# own unit (`pr-<n>`) rather than dissolved into a ticket nobody named: on a
# GitHub-Issues board that line is how a merge or a close reaches the tick, and
# it is deliberately NOT canonicalised — `pr-611` must never collapse onto issue
# 611 and take that ticket's lock.
#
# rc 1 IS THE FAIL-OPEN. One unplaceable line makes the dispatcher abandon the
# whole split and run the single session, because a scope line assigned to no
# shard is a client comment nobody reads.
triage_shard_key() {
  local cls="${1:-}" p="${2:-}" gh="${3:-0}" line="${4:-}" k
  case "$cls" in
    board)
      case "$line" in
        'board prs: '*)
          k=$(printf '%s' "$line" | sed -nE 's/^board prs: [A-Z]+ ([0-9]+).*/\1/p')
          [ -n "$k" ] || return 1
          printf 'pr-%s\n' "$k"; return 0 ;;
        'board '*)
          k=$(printf '%s' "$line" | sed -nE 's/^board [^:]+: [A-Z]+ ([^ ]+).*/\1/p') ;;
        *) return 1 ;;
      esac ;;
    queue)
      k=$(printf '%s' "$line" | sed -nE 's/^([A-Za-z]+-[0-9]+)([^0-9].*)?$/\1/p') ;;
    result)
      # `<dir> :: <line>`; the dir is <project>-<KEY>-<stamp> or the hub's
      # pool-<project>-<KEY>-<stamp> relay copy. The KEY is what sits directly
      # after the project name, which is why the project is an argument.
      k=$(basename "$(printf '%s' "$line" | sed 's/ :: .*//')" 2>/dev/null)
      k="${k#pool-}"
      case "$k" in "$p"-*) k="${k#"$p"-}" ;; *) return 1 ;; esac
      k=$(printf '%s' "$k" | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$k" ] || return 1
  triage_shard_canon "$k" "$gh"
}

# triage_shard_held <lockfile> -> rc 0 when some OTHER process holds this flock
#
# Same census bin/lib/preplan-lib.sh:preplan_held does, and for the same reason:
# a `pgrep -f` match counts anything that merely MENTIONS the script — an agent
# session whose prompt names it, a log tail — and a dispatcher that miscounts
# stands down having launched nothing, silently. The flock files are the
# harness's own statement of what is in flight.
#
# Non-destructive: opening a lock file for write creates nothing that was not
# already there, and the subshell drops the descriptor immediately.
triage_shard_held() {
  local f="${1:-}"
  [ -e "$f" ] || return 1
  ( exec 9>"$f" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null && return 1
  return 0
}

# triage_shard_rearm <harness> <project> <key> <gh>
#   Drop this key from the CONSUMED board fingerprint, so the next tick's
#   bin/gate-diff.sh reports it again and a shard is offered for it again.
#
# WHY IT EXISTS. The old tick consumed state/<p>.gate.pending only on rc=0: one
# session did all the work, so one exit code was the honest answer to "was this
# board state worked". A dispatcher has no such exit code — it hands the board
# state to N owners and leaves within seconds. So the fingerprint is consumed at
# DISPATCH, and every unit that did not get an owner (its key lock is held, the
# box cap bound, the ledger refused) or whose shard came back nonzero is put
# BACK by deleting its own entry from the consumed copy. The next diff sees that
# ticket as NEW and offers it again; nothing else on the board is re-read.
#
# Fail-open and quiet. No python3, no fingerprint, unparseable JSON -> rc 1 and
# the caller says so in its log line; the daily full sweep is the backstop that
# has always been there.
triage_shard_rearm() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" g="${1:-}/state/${2:-}.gate.json"
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  [ -s "$g" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # Under the gate file's own sidecar lock: two shards of one project finishing
  # in the same second would otherwise read-modify-write the same fingerprint and
  # one of the two re-arms would be lost — which is the silent-drop this function
  # exists to prevent, reintroduced by the fix for it.
  (
    exec 9>"$g.lock" 2>/dev/null || exit 1
    flock -w 10 9 2>/dev/null || exit 1
    TSH_KEY="$k" TSH_GH="$gh" python3 - "$g" <<'PYEOF'
import json, os, sys

key, gh = os.environ["TSH_KEY"], os.environ.get("TSH_GH") == "1"


def canon(v):
    v = str(v)
    if gh and "-" in v:
        head, _, tail = v.rpartition("-")
        if head.isalpha() and tail.isdigit():
            return tail
    return v


path = sys.argv[1]
try:
    with open(path, errors="ignore") as f:
        fp = json.load(f)
    if not isinstance(fp, dict):
        raise ValueError("fingerprint is not an object")
except Exception:
    sys.exit(1)

dropped = 0
if key.startswith("pr-"):
    # A PR unit lives only in the `prs` list; an issue with the same number is a
    # different ticket and must not be touched.
    want, lists = key[3:], [("prs", "number")]
else:
    lists = [(k, "number" if k in ("issues", "prs") else "id") for k in fp]
    lists = [(k, f) for k, f in lists if k != "prs"]
    want = key

for name, field in lists:
    rows = fp.get(name)
    if not isinstance(rows, list):
        continue
    keep = [r for r in rows
            if not (isinstance(r, dict) and canon(r.get(field)) == want)]
    dropped += len(rows) - len(keep)
    fp[name] = keep

if not dropped:
    sys.exit(1)
tmp = path + ".tsh"
with open(tmp, "w") as f:
    json.dump(fp, f, sort_keys=True, separators=(",", ":"))
os.replace(tmp, path)
PYEOF
  ) || return 1
  # BH-2318: after the sidecar lock is released, never inside it (no lock held
  # across a network call). A row still carrying the pre-re-arm sha would let a
  # box the project moves to SKIP the ticket this re-arm put back.
  command -v tgl_put_gate >/dev/null 2>&1 && tgl_put_gate "$h" "$p"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# THE SHARD STORM (2026-09-14, 18:45Z-19:46Z on box-project-5-1)
# ═══════════════════════════════════════════════════════════════════════════════
# #333 gave bin/run-triage.sh an `event-wake` arm, so a webhook delivery started
# adopting the SAME scope a board-changed tick adopts: the whole board diff. The
# dispatcher above then fanned that scope out, one session per line. The hub rang
# the doorbell ~110 times an hour for one repo, ~13 of those got past the 60s
# triage cooldown, and each of those 13 ticks bought a session for every ticket
# that had moved since the last CONSUMED tick — not for the one issue the webhook
# was about. 190 shards landed in the 19Z hour against 4-7 in every hour before
# it, 129 of them concluding `buildable=0`, and the box's own cost.csv put the
# hour at $54.99 of stage=triage against a $2.66-$10.20 baseline.
#
# The three functions this file gained are the three brakes:
#   triage_runner / triage_shard_runner / triage_model — ONE selection, so the
#     tick and its shards can never disagree about what is being bought, and the
#     log line says what actually ran (see the note on triage_runner).
#   triage_shards_per_hour / triage_shard_usd_per_hour + the hourly counters —
#     a per-project rolling-hour ceiling on sessions AND on dollars.
# The scope fix itself is in bin/run-triage.sh and bin/wake-loop.sh: a wake now
# carries the key of the object that changed, and that key IS the scope.

# _tsh_num <harness> <VAR> <default> -> a non-negative integer
#   Non-numeric text reads as the DEFAULT, never as 0: on a cap, 0 means
#   "unlimited", so a typo'd knob must not be the thing that removes the ceiling.
_tsh_num() {
  local v; v=$(_tsh_env "$1" "$2" "$3")
  case "$v" in ''|*[!0-9]*) v="$3" ;; esac
  printf '%s\n' "$v"
}

# _tsh_usd <harness> <VAR> <default> -> a non-negative dollar amount (may be
#   fractional). Same rule as _tsh_num: unparseable text falls back to the
#   default rather than to the cap-removing 0.
_tsh_usd() {
  local v; v=$(_tsh_env "$1" "$2" "$3")
  case "$v" in
    ''|*[!0-9.]*|*.*.*) v="$3" ;;
  esac
  printf '%s\n' "$v"
}

# triage_runner [harness] -> the runner label the triage STAGE runs on
#
# THE LIE THIS REMOVES. bin/agent-call.sh picks its runner from `RUNNER_<STAGE>`
# and the MODEL ARGUMENT IS ONLY READ BY THE CLAUDE LANE — with RUNNER_TRIAGE=grok
# (fleet-wide since 08-19) the claude model a caller passes is inert. Both
# callers here passed it anyway and then PRINTED it as `model=`, so all 149 shard
# lines of the 19Z storm named the Fable model while all 178 cost rows of the
# same hour said grok. The storm was read off those log lines as
# "it also ran on the most expensive model"; it did not. A label nobody can trust
# is worse than no label, so the selection lives here, both callers read it, and
# the finish line reports the runner bin/agent-call.sh actually used ($OUT.runner).
triage_runner() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  v=$(_tsh_env "$h" RUNNER_TRIAGE claude)
  case "$v" in ''|*[!A-Za-z0-9._-]*) v=claude ;; esac
  printf '%s\n' "$v"
}

# triage_shard_runner [harness] -> the runner a SHARD runs on
#   The tick's runner, unless TRIAGE_SHARD_RUNNER names another. The override
#   exists so a box can move the fan-out lane onto a cheaper runner without
#   moving the serial tick with it (the serial tick is what runs when shards are
#   disarmed, and it must stay comparable). Unset = identical to the tick, which
#   is the whole point of deliverable A: a shard is the tick, split.
triage_shard_runner() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  v=$(_tsh_env "$h" TRIAGE_SHARD_RUNNER "")
  case "$v" in ''|*[!A-Za-z0-9._-]*) triage_runner "$h"; return 0 ;; esac
  printf '%s\n' "$v"
}

# triage_model <harness> <gate-reason> [project] -> the model argument for this tick
#   the operator 2026-08-14's routing principle, moved out of bin/run-triage.sh so a
#   shard and its tick cannot resolve it differently: JUDGMENT (board-changed,
#   event-wake, daily-sweep, forced) runs on the strong model, the mechanical
#   close-out sweeps run light. TRIAGE_MODEL_LIGHT deliberately wins over an
#   explicitly set TRIAGE_MODEL on a sweep tick — that is what the inline `case`
#   this replaces did, and the sweep is the high-volume tick type.
#   BH-1510.2: the env var (process env, else env/global.env) still wins when
#   set; otherwise the model is model_routes role `triage.light` / `triage` for
#   the project. No route = rc 75 and nothing on stdout — the caller skips the
#   call, it never substitutes a model (bin/lib/model-route.sh alerted the role).
triage_model() {
  local h="${1:-${HARNESS:-${H:-}}}" g="${2:-}" p="${3:-}" var role v
  case "$g" in
    results-sweep|remote-results-pending) var=TRIAGE_MODEL_LIGHT; role=triage.light ;;
    *)                                    var=TRIAGE_MODEL;       role=triage ;;
  esac
  v=$(_tsh_env "$h" "$var" "")
  [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  # shellcheck source=bin/lib/lane-model.sh
  # No root = no route read (lane-model.sh resolves its own root, BH-2650):
  # the same rc 75 "no route" answer, nothing on stdout.
  [ -n "$h" ] || return 75
  command -v lane_role_model >/dev/null 2>&1 || . "$h/bin/lib/lane-model.sh" 2>/dev/null \
    || . "$(dirname "${BASH_SOURCE[0]}")/lane-model.sh" 2>/dev/null || return 75
  HARNESS="$h" lane_role_model "$role" "$p"
}

# triage_caps_on [harness] -> 1 | 0     (DEFAULT 1 — the hourly caps are ON)
#
# OFF BY DEFAULT since 2026-09-15 (the operator: "there shouldn't be a triage shard
# cap, we said everything unlimited"). The 09-14 storm that motivated the caps
# was a duplicate-launch bug fixed by wake coalescing in the same PR; the rate
# ceiling itself was holding real project-5 work back at 30 shards/hour with
# the queue full, which is the opposite of the standing program. The counters
# still record every launch (state/triage-shards/<p>/hourly) so the rate stays
# observable; TRIAGE_SHARD_CAPS=1 in env/global.env turns the ceilings back on
# (then TRIAGE_SHARDS_PER_HOUR / TRIAGE_SHARD_USD_PER_HOUR size them),
# the `switch.triage-shard-caps-off` settings row (or flags/triage-shard-caps-off
# when no row exists) wins over everything (BH-2437, read through lane_switch).
triage_caps_on() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -n "${HARNESS:-${H:-}}" ] && [ -f "${HARNESS:-${H:-}}/flags/$1" ]; }
  [ -n "$h" ] && HARNESS="$h" lane_switch triage-shard-caps-off && { printf '0\n'; return 0; }
  v=$(_tsh_env "$h" TRIAGE_SHARD_CAPS 0)
  case "$v" in 1|yes|on|true) printf '1\n' ;; *) printf '0\n' ;; esac
}

# triage_shards_per_hour [harness]   -> sessions per PROJECT per rolling hour, 0 = unlimited
# triage_shard_usd_per_hour [harness] -> dollars per PROJECT per rolling hour, 0 = unlimited
#
# 30 and 60 are sized off the incident, not off a feeling. The baseline this lane
# ran at all day was 4-9 triage sessions and $2.66-$10.20 an hour per project; the
# storm hour was 190 and $54.99. 30/$60 is ~4x headroom over a busy normal hour
# and ~1/6 of the storm — a genuinely busy board is never touched, and a runaway
# is stopped inside the hour it starts rather than the morning after.
triage_shards_per_hour()    { _tsh_num "${1:-${HARNESS:-${H:-}}}" TRIAGE_SHARDS_PER_HOUR   30; }
triage_shard_usd_per_hour() { _tsh_usd "${1:-${HARNESS:-${H:-}}}" TRIAGE_SHARD_USD_PER_HOUR 60; }

# triage_hour_file <harness> <project> -> state/triage-shards/<project>/hourly
#   `<launch-epoch>\t<key>` per dispatched shard. Its own file rather than a
#   count in a name, because the window is ROLLING: a counter keyed on the clock
#   hour lets 30 shards fire at :59 and 30 more at :01.
triage_hour_file() { printf '%s/state/triage-shards/%s/hourly\n' "${1:-}" "${2:-}"; }

# triage_hour_count <harness> <project> -> shards dispatched in the last 3600s
#   Prints 0 for anything it cannot read. A cap whose counter is unreadable must
#   fail OPEN — the ceiling exists to stop a runaway, not to stop triage.
triage_hour_count() {
  local f n cut
  f=$(triage_hour_file "${1:-}" "${2:-}")
  [ -r "$f" ] || { printf '0\n'; return 0; }
  cut=$(( $(date +%s) - 3600 ))
  n=$(awk -F'\t' -v c="$cut" '$1 ~ /^[0-9]+$/ && $1+0 >= c' "$f" 2>/dev/null | grep -c .)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# triage_hour_record <harness> <project> <key> -> rc 0 when the launch was counted
#   Prune and append in one locked read-modify-write: two ticks of one project
#   dispatching in the same second would otherwise each rewrite the file from
#   their own read and one launch would vanish from the census — which is the
#   silent over-spend the census exists to prevent, reintroduced by its own
#   bookkeeping (the lesson triage_shard_rearm learned the same way).
triage_hour_record() {
  local h="${1:-}" p="${2:-}" k="${3:-}" f d now cut
  [ -n "$h" ] && [ -n "$p" ] || return 1
  f=$(triage_hour_file "$h" "$p"); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null || return 1
  now=$(date +%s); cut=$(( now - 3600 ))
  (
    exec 9>"$f.lock" 2>/dev/null || exit 1
    flock -w 5 9 2>/dev/null || exit 1
    { [ -r "$f" ] && awk -F'\t' -v c="$cut" '$1 ~ /^[0-9]+$/ && $1+0 >= c' "$f" 2>/dev/null
      printf '%s\t%s\n' "$now" "$k"; } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  )
}

# triage_hour_usd <harness> <project> -> stage=triage dollars for <project> in the
#   last 3600s, from logs/cost.csv (the ledger every runner already writes).
#
# NOT from the shards' own log lines. Those sum `tail -n +<lines-before-my-call>`
# of cost.csv, which counts every SIBLING's row too — that is how the 19Z hour
# read as ~$713 when the rows themselves add to $54.99. This reads the rows once,
# for the window, which is the only number that is nobody's double count.
#
# ISO-8601 Z timestamps compare correctly as strings, so no per-row date(1). Only
# the tail is scanned: cost.csv is append-only and unbounded, and an hour of it is
# never more than a few hundred rows.
triage_hour_usd() {
  local h="${1:-}" p="${2:-}" f cut
  f="$h/logs/cost.csv"
  [ -r "$f" ] || { printf '0\n'; return 0; }
  cut=$(date -u -d '60 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
    || cut=$(date -u -v-60M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || cut=""
  [ -n "$cut" ] || { printf '0\n'; return 0; }
  tail -n "${TRIAGE_COST_SCAN_LINES:-4000}" "$f" 2>/dev/null \
    | awk -F, -v p="$p" -v c="$cut" \
        '$3==p && $4=="triage" && $1 >= c && $13 ~ /^[0-9]+(\.[0-9]+)?$/ {s+=$13}
         END{printf "%.2f\n", s+0}'
}

# triage_usd_over <spent> <cap> -> rc 0 when <spent> has reached <cap>
#   awk, not `[ -ge ]`: both sides are dollars and shell integer tests would read
#   $59.99 and $9.99 as equal nonsense. cap 0 = unlimited, always rc 1.
triage_usd_over() {
  awk -v s="${1:-0}" -v c="${2:-0}" 'BEGIN{ exit !(c+0 > 0 && s+0 >= c+0) }'
}

# ═══════════════════════════════════════════════════════════════════════════════
# THE PER-TICKET FINGERPRINT (BH-1015, the 2026-09-17..19 runaway-spend audit)
# ═══════════════════════════════════════════════════════════════════════════════
# bin/triage-gate.sh already brakes the TICK on state/<project>.queuefp. That
# brake is ALL-OR-NOTHING: one ticket's queue line gaining a word un-brakes the
# whole tick, and the dispatcher above then buys a session for every key in
# scope — including the dozen whose world is byte-identical to the last time
# somebody paid to read them. A shard that concludes "hold, nothing to do" is a
# billed empty result, and it was re-offered on every RUN tick: project-4 2,073
# shards in 3 days, project-1 TK-265 153 on one ticket, cromford $896/day.
#
# So the unit of dedup moves to where the unit of SPEND already is: the ticket.
# The rule these four functions implement is the fleet's
# (~/.claude/rules/metered-api-dedup.md): a PERSISTED check, keyed on a
# fingerprint of the INPUT, that runs BEFORE the billable call.
#
# WHAT IS IN THE FINGERPRINT, and why each part:
#   the key's own scope lines  — a queue line is normalised to its MACHINE
#     tokens (below), because a no-action session rewrites its prose and its
#     "Re-checked <ts>" on every tick and that churn is what defeated the
#     tick-level brake. Board and result lines are kept verbatim (minus ISO
#     timestamps): those are produced by bin/gate-diff.sh and by the sweep, they
#     carry comment counts and dir names, and every byte of them is signal.
#   the state of every PR the queue line names — READ FROM THE TICK'S OWN gh
#     CALL (line 3 of state/<project>.queuefp, written by bin/triage-gate.sh's
#     PR-gate check). A guard that added a gh call per key per tick would trade
#     a dollar problem for a rate-limit problem.
#   this key's build dirs and their RESULT/COMMENTED marks — a finished build
#     reaches a queue-pending tick as no scope line at all, so without this a
#     close-out could be deduped away and a client would never hear back.
#
# WHAT IS DELIBERATELY NOT IN IT: state/<project>.result-rows. It is a single
# project-global watermark with no ticket in it, so folding it in would move
# EVERY key's fingerprint whenever any build anywhere in the project finished —
# which is the tick brake's job, not this one. The build it announces reaches
# the key through its own dirs, above.
#
# THREE OUTCOMES, NEVER TWO. triage_shard_fp_fresh answers fresh / stale /
# unreadable, and unreadable dispatches: a guard that read corruption as
# "already paid" would stop answering that ticket until the daily sweep, which
# is the more expensive failure by far.

# triage_shard_fp_ttl [harness] -> how long a fingerprint may vouch for a key
#   4h, the same hard backstop bin/triage-gate.sh's queue brake uses, and for
#   the same reason: however deterministic the inputs look, something the
#   fingerprint cannot see moves eventually, and a ticket must never be able to
#   go dark for longer than one working stretch. 0 = the off switch (nothing can
#   be younger than zero seconds), restoring pre-BH-1015 behaviour exactly.
triage_shard_fp_ttl() { _tsh_num "${1:-${HARNESS:-${H:-}}}" TRIAGE_SHARD_FP_TTL_S 14400; }

# triage_shard_fp_file <harness> <project> <key> -> state/triage-shards/<p>/<k>.fp
#   `<fingerprint>\n<epoch>\n`, the shape state/<project>.queuefp already has.
triage_shard_fp_file() { printf '%s/state/triage-shards/%s/%s.fp\n' "${1:-}" "${2:-}" "${3:-}"; }

# _tsh_fp_iso <text> -> the text with ISO-8601 stamps removed
#   Byte-for-byte the expression bin/triage-gate.sh:QFP uses, so the two brakes
#   agree about what a re-stamp is.
_tsh_fp_iso() { sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g'; }

# _tsh_fp_qnorm <queue-line> -> that line's machine skeleton
#
# A queue line is written partly by deterministic producers
# (bin/stale-owed-tickets.sh, bin/preplan-candidates.sh) and partly by a triage
# session's own sentence. The producers write TOKENS — the ticket key, a
# `PR #12` reference, `project=<repo>`, `base=<branch>`, a `[status/waitingOn]`
# bracket, an ALL-CAPS status word like OWED-STALE or STACKABLE. The session
# writes prose, and rewrites it every time it re-reads the ticket. Keeping the
# tokens and dropping the rest is the whole difference between a brake that
# engages and one that never fires.
#
# Sorted and de-duplicated, so a producer that reorders its own tokens does not
# read as a new world.
_tsh_fp_qnorm() {
  printf '%s' "${1:-}" | _tsh_fp_iso \
    | grep -oE 'PR ?#[0-9]+|\[[^]]*\]|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+|[A-Z][A-Z0-9_-]{2,}' \
    | sed -E 's/^PR ?#/pr#/' \
    | LC_ALL=C sort -u | tr '\n' ' '
}

# _tsh_fp_builds <harness> <project> <key> <gh> -> `<dir> <R|RC|>` per build dir
#   whose key canonicalises to <key>, sorted. The dirs are named for the FULL
#   ticket key (`project-5-TK-563-<stamp>`) while the unit key may be the bare
#   number, so the shipped triage_shard_key does the matching rather than a glob
#   that would have to re-derive the same rule and get it wrong.
_tsh_fp_builds() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" d b dk st
  for d in "$h/builds/$p"-*/ "$h/builds/pool-$p"-*/; do
    [ -d "$d" ] || continue
    b=$(basename "${d%/}")
    dk=$(triage_shard_key result "$p" "$gh" "$b :: x" 2>/dev/null) || continue
    [ "$dk" = "$k" ] || continue
    st=""
    [ -f "$d/RESULT" ] && st="R"
    [ -f "$d/COMMENTED" ] && st="${st}C"
    printf '%s %s\n' "$b" "$st"
  done | LC_ALL=C sort
}

# ── THE CARRIED-FORWARD PR-STATE LEDGER (BH-1015 review, block 1) ────────────
# The fingerprint needs "what state is PR #12 in", and the obvious source —
# line 3 of state/<project>.queuefp, where bin/triage-gate.sh parks its own
# lookup — is unusable, because the gate writes that line on ONE of its three
# write branches and erases it on the other two. Probed against the real gate:
# a first tick writes 2 lines, a quiet 50-minute tick writes 3 with `12=OPEN;`,
# and the next reworded-prose tick writes 2 again. So the same unchanged world
# gave the same key two different fingerprints, and it bought a session on each
# flip — twice per 45-minute cycle, on exactly the "still waiting on PR #X"
# line this ticket is about. Worse in the other direction: with the stamp taken
# in the `?` state, a merge stamped during a 2-line stretch was invisible until
# the 4h TTL. And bin/lib/rt/shards.sh deletes queuefp whenever the hourly cap
# defers a unit (live on all six boxes), which erased the vector for every key.
#
# So the states get their own file, which nothing else writes and nothing
# deletes. It is FED from the gate's free lookup when there is one, REFRESHED
# once per tick by REST when the newest entry has aged past the gate's own 45
# minute window, and CARRIED FORWARD otherwise. `?` therefore appears only
# before the first successful read on a box, and never flaps back.
#   format: `<pr-number>\t<STATE>\t<epoch>` per line, STATE in OPEN/CLOSED/MERGED

# triage_prstates_file <harness> <project> -> state/<project>.prstates
triage_prstates_file() { printf '%s/state/%s.prstates\n' "${1:-}" "${2:-}"; }

# triage_prstates_ttl [harness] -> how long an entry may go unrefreshed
#   2700s = the gate's own queue-brake window, so the REST refresh below only
#   ever fires on ticks where the gate's free lookup did not.
triage_prstates_ttl() { _tsh_num "${1:-${HARNESS:-${H:-}}}" TRIAGE_PRSTATES_TTL_S 2700; }

# triage_prstates_prune_s [harness] -> how long an entry no queue line names may
#   sit in the ledger. 604800s = 7 days, comfortably longer than any blocking PR
#   this fleet has left open while its queue line churned.
triage_prstates_prune_s() { _tsh_num "${1:-${HARNESS:-${H:-}}}" TRIAGE_PRSTATES_PRUNE_S 604800; }

# triage_prstates_get <harness> <project> <number> -> OPEN|CLOSED|MERGED|?
#   `?` for anything unknown, and it STAYS `?` until a read succeeds — a value
#   that oscillates is worse here than one that is merely missing.
triage_prstates_get() {
  local f v
  f=$(triage_prstates_file "${1:-}" "${2:-}")
  v=$(awk -F'\t' -v n="${3:-}" '$1==n{v=$2} END{print v}' "$f" 2>/dev/null)
  case "$v" in ''|*[!A-Za-z_]*) v='?' ;; esac
  printf '%s\n' "$v"
}

# _tsh_prstates_ts <harness> <project> <number> -> that entry's epoch, or empty
#   Empty means "no entry at all", which is NOT the same as an entry stamped 0 —
#   the ingest below writes over the first and compares ages against the second.
_tsh_prstates_ts() {
  local v
  v=$(awk -F'\t' -v n="${3:-}" '$1==n{v=$3} END{print v}' \
      "$(triage_prstates_file "${1:-}" "${2:-}")" 2>/dev/null)
  case "$v" in *[!0-9]*) v="" ;; esac
  printf '%s\n' "$v"
}

# _tsh_prstates_put <harness> <project> <number> <state> [epoch]
#   One locked read-modify-write, the shape triage_hour_record uses: two ticks
#   of one project refreshing in the same second would otherwise each rewrite
#   from their own read and one update would vanish.
#
#   UNCONDITIONAL ON PURPOSE, and the caller owns the age rule. The REST refresh
#   below has just read GitHub, so its answer is by definition the newest thing
#   anyone has; triage_prstates_ingest is replaying a vector of unknown age and
#   does the newer-wins compare itself before calling here.
_tsh_prstates_put() {
  local h="${1:-}" p="${2:-}" n="${3:-}" st="${4:-}" ts="${5:-}" f d
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$n" ] || return 1
  case "$st" in ''|*[!A-Za-z_]*) return 1 ;; esac
  case "$ts" in ''|*[!0-9]*) ts=$(date +%s) ;; esac
  f=$(triage_prstates_file "$h" "$p"); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null || return 1
  (
    exec 9>"$f.lock" 2>/dev/null || exit 1
    flock -w 5 9 2>/dev/null || exit 1
    { [ -r "$f" ] && awk -F'\t' -v n="$n" '$1!=n' "$f" 2>/dev/null
      printf '%s\t%s\t%s\n' "$n" "$st" "$ts"; } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  )
}

# triage_prstates_ingest <harness> <project>
#   Fold the gate's OWN lookup into the ledger, for free. Line 3 of
#   state/<project>.queuefp is `<n>=<STATE>;` pairs when the gate took its
#   45-minute PR-gate read this tick, and nothing when it did not. Absent is
#   simply nothing to ingest — never a reason to forget what we already knew.
#
#   THE VECTOR CARRIES ITS OWN AGE, and using `now` instead was a spend defect
#   (BH-1079). Line 3 SURVIVES every tick the gate did not re-read on — it is
#   rewritten only when the gate takes its 45-minute lookup, and erased on the
#   other two write branches — so the same `12=OPEN;` is re-read tick after
#   tick. Stamped `now` and written unconditionally, that ten-minute-old OPEN
#   replaced the MERGED the REST refresh had just established, every key naming
#   PR #12 flipped its fingerprint, and each one bought a session on a merge
#   that had already happened. So the epoch is queuefp's OWN line 2 (the stamp
#   the gate wrote beside the vector) and an entry is only replaced when that
#   epoch is not OLDER than the one already on file.
#
#   NOT-OLDER, not strictly-newer, and the tie is not where it looks. It is NOT
#   this tick's refresh: triage_prstates_refresh runs AFTER this ingest and
#   skips every row younger than TRIAGE_PRSTATES_TTL_S, so a row just stamped
#   here is never re-read or re-stamped by it. It is TWO GATE READS landing in
#   the same second — 45 minutes apart in production, back to back at test
#   speed — and equal seconds are no evidence of staleness: both vectors read
#   the same GitHub, so letting the later one land costs one identical rewrite,
#   while a strict `-gt` drops a real merge and holds the stale value for the
#   gate's whole 45-minute window. (tests/triage-shards-ticket-fp-test.sh case
#   (B) pins it through the gate's own 2/2/3/2-line write sequence; (B5) in
#   tests/triage-shards-prstates.bh-1079-test.sh pins the equality at the lib.)
triage_prstates_ingest() {
  local h="${1:-}" p="${2:-}" prv ep pair n st old
  prv=$(sed -n 3p "$h/state/$p.queuefp" 2>/dev/null)
  [ -n "$prv" ] || return 0
  # A vector with no readable age cannot claim to be newer than anything, so it
  # ingests nothing rather than being stamped with a time it was not read at.
  ep=$(sed -n 2p "$h/state/$p.queuefp" 2>/dev/null)
  case "$ep" in ''|*[!0-9]*) return 0 ;; esac
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    n="${pair%%=*}"; st="${pair#*=}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    old=$(_tsh_prstates_ts "$h" "$p" "$n")
    [ -z "$old" ] || [ "$ep" -ge "$old" ] || continue
    _tsh_prstates_put "$h" "$p" "$n" "$st" "$ep" || true
  done <<EOF
$(printf '%s' "$prv" | tr ';' '\n')
EOF
  return 0
}

# _tsh_gh_budget_low <harness> <lane> -> rc 0 low, 1 healthy, 2 unknown
#   A SUBSHELL, not a source: bin/lib/gh-budget.sh runs `set -uo pipefail` at
#   source time and evaluates its own root from HARNESS right there, so sourcing
#   it into a dispatcher that does neither would change both. rc 2 (no library,
#   or a rate_limit endpoint that did not answer) is "unknown", and every
#   consumer of gh_budget_low treats unknown as proceed — a broken endpoint must
#   not be able to freeze a ledger.
_tsh_gh_budget_low() {
  local h="${1:-}" lane="${2:-triage}"
  [ -n "$h" ] || return 2
  (
    [ -r "$h/bin/lib/gh-budget.sh" ] || exit 2
    export HARNESS="$h"
    # shellcheck source=bin/lib/gh-budget.sh
    . "$h/bin/lib/gh-budget.sh"
    gh_budget_low "$lane"
  )
}

# triage_prstates_refresh <harness> <project> <units-file>
#   ONE PASS PER TICK, never per key. Every PR number this tick's queue lines
#   name, capped at 20 exactly like the gate's own lookup, and only the ones
#   whose entry is missing or older than triage_prstates_ttl.
#
# THROUGH bin/lib/gh-rest.sh, NEVER A RAW `gh` CALL (BH-1015 review round 2 —
# tests/gh-app-ratchet-test.sh caught the first cut of this function as a new
# raw reader). Three reasons, and the ratchet is only the third:
#   * gh_rest is no-graphql by construction. `gh pr view` is a GraphQL wrapper
#     and the accounts this fleet runs on are rate-limited out of GraphQL.
#   * ITS THREE EXIT CODES ARE THE WHOLE REASON THIS IS SAFE ON A SCHEDULE.
#     A raw call collapses "GitHub said 404" and "GitHub said come back later"
#     into one empty string (incident #768). Here 44 is a real answer worth
#     caching, and 75 — a rate limit, a network failure, an empty body — leaves
#     the previous value AND its stamp alone, because a transient outage that
#     turned a known OPEN into `?` would buy a session for every key naming it.
#   * The App identity is armed for the repo around the pass and reset after,
#     so this read comes out of a short-lived repo-scoped token rather than the
#     one fleet-wide PAT bucket.
#
# The three states are spelled the way bin/triage-gate.sh spells them, so a
# value ingested from the gate's own lookup and one refreshed here are the same
# string. A 404 is cached as ABSENT for the same TTL: a queue line naming a PR
# that does not exist must not re-ask every tick for ever.
#   MERGED AND CLOSED ARE TERMINAL (BH-1079): neither can change back on its
#   own, so re-reading one once per TTL for as long as its queue line lives is
#   pure spend. A reopen still reaches the ledger — through the gate's own
#   vector, which triage_prstates_ingest folds in above whenever it is newer.
triage_prstates_refresh() {
  local h="${1:-}" p="${2:-}" u="${3:-}" slug ttl now n st ts rc armed=0 want stamp old age
  [ -n "$h" ] && [ -n "$p" ] && [ -s "$u" ] || return 0
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  [ -n "$slug" ] || return 0
  # shellcheck source=bin/lib/gh-rest.sh
  # BH-1485: the name asked for is the one this function CALLS. The refresh
  # below reads through gh_rest_pr_state_var so the rc-75 line can name the
  # status; a guard that probed the old name would find it, skip the source,
  # and die on the variant a moment later.
  command -v gh_rest_pr_state_var >/dev/null 2>&1 \
    || { [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh"; }
  command -v gh_rest_pr_state_var >/dev/null 2>&1 || return 0
  # shellcheck source=bin/lib/gh-app-auth.sh
  command -v gh_auth_for >/dev/null 2>&1 \
    || { [ -r "$h/bin/lib/gh-app-auth.sh" ] && . "$h/bin/lib/gh-app-auth.sh"; }
  ttl=$(triage_prstates_ttl "$h"); now=$(date +%s)
  # WHICH NUMBERS ACTUALLY NEED A CALL, decided before anything is spent
  # (BH-1079). Built first so a tick with nothing to look up — the common
  # one — reads neither GitHub nor the budget cache and stays free.
  want=""
  for n in $(awk -F'\t' '$2=="queue"{print $3}' "$u" 2>/dev/null \
             | grep -oE 'PR ?#[0-9]+' | grep -oE '[0-9]+' | LC_ALL=C sort -un | head -20); do
    case "$(triage_prstates_get "$h" "$p" "$n")" in MERGED|CLOSED) continue ;; esac
    ts=$(_tsh_prstates_ts "$h" "$p" "$n"); [ -n "$ts" ] || ts=0
    [ $(( now - ts )) -lt "$ttl" ] && continue
    want="$want $n"
  done
  [ -n "$want" ] || return 0
  # A PR-state refresh is the textbook non-essential read: skipping it costs a
  # carried-forward value, which is exactly what this ledger is for. rc 0 = low,
  # rc 2 = unknown, and unknown proceeds as healthy — the idiom every other lane
  # uses (bin/review-autopilot.sh, bin/wake-loop.sh, bin/orphan-reconcile.sh).
  _tsh_gh_budget_low "$h" triage-prstates && return 0
  stamp=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" && armed=1
  for n in $want; do
    # BH-1485: the `_var` variant, so the rc-75 arm below can name the status.
    rc=0; st=""
    gh_rest_pr_state_var st "$slug" "$n" || rc=$?
    if [ "$rc" = 0 ]; then
      case "$st" in
        open)   _tsh_prstates_put "$h" "$p" "$n" OPEN   "$now" || true ;;
        merged) _tsh_prstates_put "$h" "$p" "$n" MERGED "$now" || true ;;
        closed) _tsh_prstates_put "$h" "$p" "$n" CLOSED "$now" || true ;;
      esac
    elif [ "$rc" = 44 ]; then
      _tsh_prstates_put "$h" "$p" "$n" ABSENT "$now" || true
    else
      # rc 75 (rate limit / network failure / empty body) is UNVERIFIABLE: no
      # write, no stamp — the carried-forward value stands, but silence made
      # that indistinguishable from a successful read, so it gets a line
      # (BH-1079). Bounded by the same head -20 as the loop above.
      old=$(triage_prstates_get "$h" "$p" "$n")
      ts=$(_tsh_prstates_ts "$h" "$p" "$n")
      if [ -n "$ts" ]; then age="$(( now - ts ))s ago"; else age="never read"; fi
      echo "$stamp [$p] prstates refresh: PR #$n lookup failed (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — keeping $old from $age" \
        >> "$h/logs/$p.log" 2>/dev/null || true
    fi
  done
  [ "$armed" = 1 ] && gh_auth_reset
  return 0
}

# triage_prstates_prune <harness> <project>
#   The ledger is bounded by the distinct PR numbers a project's queue lines
#   have ever named, which only ever grows. Drop the entries that are BOTH
#   unnamed by any current queue line AND older than TRIAGE_PRSTATES_PRUNE_S
#   (7 days) — either condition alone keeps the row, because a long-lived
#   blocking PR is exactly the entry this ledger exists to carry. A missing
#   READY-QUEUE.log means nothing is named and age alone decides; a row whose
#   epoch is unreadable is kept, since prune is not the place to lose data.
#   One locked rewrite per tick, under the same sidecar lock as the writer.
triage_prstates_prune() {
  local h="${1:-}" p="${2:-}" f cutoff names
  [ -n "$h" ] && [ -n "$p" ] || return 1
  f=$(triage_prstates_file "$h" "$p")
  [ -s "$f" ] || return 0
  cutoff=$(( $(date +%s) - $(triage_prstates_prune_s "$h") ))
  # The same extraction bin/triage-gate.sh and the refresh above already use.
  # _rq_norm (bin/lib/ready-queue.sh) when loaded, so a timestamp-first line's
  # PR numbers still count; the bare grep is the fallback for a box without it.
  names=$({ if declare -F _rq_norm >/dev/null; then _rq_norm < "$h/logs/READY-QUEUE.log"; else grep -E '^[A-Z]+-[0-9]' "$h/logs/READY-QUEUE.log"; fi; } 2>/dev/null \
          | grep -oE 'PR ?#[0-9]+' | grep -oE '[0-9]+' | LC_ALL=C sort -un | tr '\n' ' ')
  (
    exec 9>"$f.lock" 2>/dev/null || exit 1
    flock -w 5 9 2>/dev/null || exit 1
    awk -F'\t' -v names=" $names" -v cut="$cutoff" '
      { keep = (index(names, " " $1 " ") > 0) || ($3 !~ /^[0-9]+$/) || ($3 + 0 >= cut)
        if (keep) print }
    ' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  )
}

# _tsh_fp_bnorm <board-line> -> that line's diff-VERB-INDEPENDENT skeleton
#
# WHY THE VERB GOES (BH-1015 review, block 2). bin/gate-diff.sh names a ticket
# NEW when the consumed fingerprint lacks it and CHANGED when it has it, and
# ONLY the CHANGED line carries the `(comments: 5 -> 6)` parenthetical. Which of
# the two a ticket gets is a fact about state/<p>.gate.json — not about the
# ticket — and a key that was re-armed out of that file sits on `NEW <id>
# "<title>"`, which is byte-identical whether the thread has five comments or
# six. Fingerprinting that text would let a client's reply land on a re-armed
# key and be skipped until the TTL, webhook wake included.
#
# So the verb and its description are normalised away here, and the ticket's own
# entry in state/<p>.gate.pending carries the truth instead (_tsh_fp_pending).
# Lines that are NOT diff output — the UNBLOCKED / STACKABLE lines
# bin/unblocked-children.sh prints, which carry dependency facts no fingerprint
# holds — do not match and are kept verbatim.
_tsh_fp_bnorm() {
  printf '%s' "${1:-}" | _tsh_fp_iso \
    | sed -E 's/^(board [^:]+: )(NEW|CHANGED|REMOVED) ([^ ]+).*$/\1DIFF \3/'
}

# _tsh_fp_line <class> <line> -> that unit line's contribution
#   A top-level function rather than a `case` inlined in the command
#   substitution inside triage_shard_fp: bash 3.2 (macOS) cannot parse `;;`
#   inside `$( … )`, and this lib is occasionally sourced from a Mac session.
_tsh_fp_line() {
  case "${1:-}" in
    queue) printf 'q %s\n' "$(_tsh_fp_qnorm "${2:-}")" ;;
    board) printf 'b %s\n' "$(_tsh_fp_bnorm "${2:-}")" ;;
    *)     printf '%s %s\n' "${1:-}" "$(printf '%s' "${2:-}" | _tsh_fp_iso)" ;;
  esac
}

# _tsh_fp_pending <harness> <project> <key> <gh> -> this ticket's own entry in
#   the LIVE board fingerprint, canonicalised; rc 1 when it cannot be read.
#
# This is the world, where the diff line is only a statement about what we
# consumed. For a GitHub-Issues board it is the issue's {number,state,title,
# comments,updatedAt} row (or, for a `pr-<n>` unit, the open-PR row, whose
# ABSENCE is how a merge reads); for an in-app board it is the ticket object,
# which carries status, waitingOn, triageVerdict and commentCount. A new client
# comment moves it, every time, whatever bin/gate-diff.sh chose to call the line.
_tsh_fp_pending() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" f
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  f="$h/state/$p.gate.pending"
  # The pending copy is what this tick fetched; gate.json is the last consumed
  # one and is only a fallback for a tick that did not refresh pending.
  [ -s "$f" ] || f="$h/state/$p.gate.json"
  [ -s "$f" ] || return 1
  TSH_KEY="$k" TSH_GH="$gh" python3 - "$f" <<'PYEOF'
import json, os, sys

key, gh = os.environ["TSH_KEY"], os.environ.get("TSH_GH") == "1"


def canon(v):
    v = str(v)
    if gh and "-" in v:
        head, _, tail = v.rpartition("-")
        if head.isalpha() and tail.isdigit():
            return tail
    return v


try:
    with open(sys.argv[1], errors="ignore") as f:
        fp = json.load(f)
    if not isinstance(fp, dict):
        raise ValueError("fingerprint is not an object")
except Exception:
    sys.exit(1)

if key.startswith("pr-"):
    want, lists = key[3:], [("prs", "number")]
else:
    lists = [(k, "number" if k in ("issues", "prs") else "id") for k in fp]
    lists = [(k, f) for k, f in lists if k != "prs"]
    want = key

for name, field in lists:
    rows = fp.get(name)
    if not isinstance(rows, list):
        continue
    for r in rows:
        if isinstance(r, dict) and canon(r.get(field)) == want:
            print("pend " + name + " " + json.dumps(r, sort_keys=True,
                                                    separators=(",", ":")))
            sys.exit(0)
# Absent is a real answer and a STABLE one: a merged PR leaves the open list, a
# closed issue leaves the ai-build list, and "gone" has to move the fingerprint
# rather than fail it.
print("pend absent " + want)
PYEOF
}

# triage_shard_fp <harness> <project> <key> <gh> <units-file> [pend] -> 16 hex chars
#   rc 1 when it cannot be computed (no units file, no sha256sum, or a key with
#   a board line whose live entry could not be read). The caller then
#   dispatches: a fingerprint nobody could take is not a licence to skip.
#   [pend], when non-empty, stands in for the live board entry of a key with a
#   board line (BH-2542: bin/lib/triage-signal.sh passes the thread's signal
#   digest), so both fingerprints share one composition.
triage_shard_fp() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" u="${5:-}" po="${6:-}" out pend n
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] && [ -s "$u" ] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  # THE LIVE ENTRY IS REQUIRED ONLY FOR A KEY THE BOARD NAMED THIS TICK. A
  # queue- or result-only key has no board line, so its fingerprint stays on the
  # queue/PR/build inputs alone and does not gain a component that could flip
  # between readable and unreadable — which is the same instability that made
  # queuefp line 3 unusable (block 1). Any board movement on such a ticket
  # arrives as a BOARD_SEC line, which puts the key in this branch anyway.
  pend=""
  if awk -F'\t' -v k="$k" '$1==k && $2=="board"{f=1} END{exit !f}' "$u" 2>/dev/null; then
    if [ -n "$po" ]; then pend="$po"; else pend=$(_tsh_fp_pending "$h" "$p" "$k" "$gh") || return 1; fi
  fi
  out=$(
    {
      awk -F'\t' -v k="$k" '$1==k' "$u" 2>/dev/null | while IFS=$'\t' read -r _uk ucls uline; do
        _tsh_fp_line "$ucls" "$uline"
      done | LC_ALL=C sort
      [ -n "$pend" ] && printf '%s\n' "$pend"
      # The PR states come from the CARRIED-FORWARD ledger, never from
      # state/<p>.queuefp: the gate writes that vector on one branch and erases
      # it on every other one, so reading it directly made an unchanged
      # "waiting on PR #12" key flip between `?` and `OPEN` and buy two sessions
      # per 45-minute cycle (block 1 of the BH-1015 review).
      for n in $(awk -F'\t' -v k="$k" '$1==k && $2=="queue"{print $3}' "$u" 2>/dev/null \
                 | grep -oE 'PR ?#[0-9]+' | grep -oE '[0-9]+' | LC_ALL=C sort -un); do
        printf 'pr %s=%s\n' "$n" "$(triage_prstates_get "$h" "$p" "$n")"
      done
      _tsh_fp_builds "$h" "$p" "$k" "$gh"
    } | sha256sum | cut -c1-16
  )
  case "$out" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# triage_shard_fp_fresh <harness> <project> <key> <fingerprint>
#   rc 0  this exact world was already handed to a shard, recently -> SKIP
#   rc 1  never stamped, a different world, or the stamp aged out -> DISPATCH
#   rc 2  the stamp file exists and cannot be read -> DISPATCH, and say so
triage_shard_fp_fresh() {
  local h="${1:-}" p="${2:-}" k="${3:-}" want="${4:-}" f old ts ttl
  [ -n "$want" ] || return 1
  f=$(triage_shard_fp_file "$h" "$p" "$k")
  [ -e "$f" ] || return 1
  old=$(head -1 "$f" 2>/dev/null); ts=$(sed -n 2p "$f" 2>/dev/null)
  case "$old" in ''|*[!0-9a-f]*) return 2 ;; esac
  case "$ts"  in ''|*[!0-9]*)    return 2 ;; esac
  [ "$old" = "$want" ] || return 1
  ttl=$(triage_shard_fp_ttl "$h")
  [ "$ttl" -gt 0 ] || return 1
  [ $(( $(date +%s) - ts )) -lt "$ttl" ] || return 1
  return 0
}

# triage_shard_fp_put <harness> <project> <key> <fingerprint> -> rc 0 when stored
#   Called BEFORE the shard is launched, never after: a ledger written once the
#   answer is back has already paid for it, and that is the single most
#   expensive bug shape in this class.
triage_shard_fp_put() {
  local h="${1:-}" p="${2:-}" k="${3:-}" fp="${4:-}" f d
  [ -n "$fp" ] || return 1
  f=$(triage_shard_fp_file "$h" "$p" "$k"); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s\n%s\n' "$fp" "$(date +%s)" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

# triage_shard_fp_clear <harness> <project> <key>
#   THE STAMP MEANS "a shard owns this world", so every path where the shard
#   turns out NOT to own it has to take the stamp back: a held key lock, a
#   refused ledger claim, a missing contract, a nonzero exit. Those are exactly
#   bin/triage-shard.sh's four REARM sites, and the clear lives beside the
#   re-arm there rather than inside triage_shard_rearm — the DISPATCHER also
#   re-arms (for keys it skipped as unchanged), and clearing on that path would
#   delete the very stamp that skip was made from.
triage_shard_fp_clear() {
  rm -f "$(triage_shard_fp_file "${1:-}" "${2:-}" "${3:-}")" 2>/dev/null
  return 0
}
