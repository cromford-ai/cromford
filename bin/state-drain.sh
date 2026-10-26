#!/bin/bash
# bin/state-drain.sh [--dry-run|--report] — archive, then delete, the drained
# top-level entries of state/ on every box (C1 of #4159).
#
# WHY. Harness state moved from box-local files under state/ to DB rows. A
# family whose writers are gone leaves its directory behind on every box, and
# `find state -type f` on the hub should list only allowlisted caches. The
# writer census of tests/no-state-files.bh-4159-test.sh is not a safe delete
# test: it does not see a path built in a function (state/alerts counts 0 there
# and is live, bin/lib/alert-state.sh) or a dynamic name ($PROJECT.gate-meta).
# So this lane deletes only what no deployed code names at all.
#
# WHAT. One pass over the TOP LEVEL of the state dir, in name order. Entry E is
#   1. kept `allowlisted` when E is a cache or box-local path of
#      catalog/state-paths.json or gh-policy-cache (or a dot sibling of one:
#      settings-cache.json.tmp);
#   2. kept `catalog` when E is any other path of that catalog (class rows),
#      or a dot sibling of one. A rows family drains only after a reviewed PR
#      removes its catalog row;
#   3. kept `link` when E is a symlink, socket or FIFO, or sits on another
#      mount than the state dir;
#   4. kept `referenced:<key>` when a key of E appears as a fixed string in any
#      file under $H/bin or $H/catalog, or in the box crontab (crontab -l and
#      /etc/cron.d/*). The keys of a name N: N; N with each trailing .tmp
#      .new .prev .lock .err or mktemp-like .[A-Za-z0-9]{6,12} stripped,
#      repeated; the head before the first `.` when it has 4 or more chars; the
#      tail from the first `.` (dot included) when it has 5 or more chars
#      (.gate-meta). Over-keeping is the safe error;
#   5. kept `fresh` when the newest mtime anywhere inside E is not older than
#      STATE_DRAIN_MIN_IDLE_DAYS, or `unreadable` when that read does not
#      finish in STATE_DRAIN_SCAN_TIMEOUT_S;
#   6. else E is drained. A dry run logs `would-drain <name> <kb> KB
#      idle_days=<n>`. A real run, at most STATE_DRAIN_MAX_PER_RUN entries:
#      `tar -czf` to <archive>/<UTC stamp>/<name>.tgz, `tar -tzf` proves the
#      archive reads back, then the entry is removed and `[ ! -e ]` proves it.
#      `drained <name> <kb> KB idle_days=<n> archive=<path>` is logged only
#      after both proofs. An archive that fails keeps E (`archive-failed`).
# Each decision is printed on stdout as `<decision>\t<name>` (drain, or the
# keep reason above). Removal works by basename inside the state dir.
#
# REFUSALS. A missing or invalid catalog, an empty or missing $H/bin, an
# unreadable corpus, or an invalid knob: nothing is drained, the log says
# `refused (<why>)`, the ledger row is `refused` and the warn
# state-drain:refused-<host> is raised (resolved by the next good run).
#
# AFTER THE PASS. The observable: the count of files under the state dir whose
# first segment is not allowlisted (step 1's set). Then, real runs only, the
# archive retention: an archive run dir whose stamp is older than
# STATE_DRAIN_ARCHIVE_KEEP_DAYS is removed (`archive-pruned <dir>`).
# One summary line in logs/state-drain.log:
#   run dry=<0|1> entries= allowlisted= catalog= link= referenced= fresh=
#   unreadable= drained= would= failed= left= unallowlisted_files= archives_pruned=
# One ledger row per box (kind state_drain, key `state-drain <host>`, status
# ok|partial|refused, detail = the same counts plus dry and at) through
# bin/jobs-client.sh; a failed write is a log line. Warns (bin/lane-alert.sh,
# severity warn, the batched digest): state-drain:failed-<host> on a real run
# with failed>0, resolved by a real run with failed=0.
#
# --dry-run forces a dry run. --report prints every file under the state dir
# whose first segment is not allowlisted, one path a line relative to the state
# dir, then `unallowlisted_files=<n> segments=<n>` on stderr; it changes
# nothing and writes no row and no log line. Exit 0 on every path except a
# usage error (2).
#
# Off: flags/lane-off-state-drain. Knobs: catalog/lanes.d/state-drain.json.
# Test seams (not settable): STATE_DRAIN_STATE_DIR, STATE_DRAIN_ARCHIVE_DIR,
# STATE_DRAIN_CRONTAB_FILE (read instead of crontab -l and /etc/cron.d/*),
# STATE_DRAIN_NOW. Under HARNESS_TEST_SANDBOX=1 with no STATE_DRAIN_STATE_DIR
# the run is skipped, so a suite never drains the real state dir.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"

MODE=run
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --report)  MODE=report ;;
  '') ;;
  *) echo "usage: bin/state-drain.sh [--dry-run|--report]" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")
# Same gate and knob order as bin/tmp-sweep.sh: rows, then env/global.env, then
# the rows again so the box's env file cannot shadow a settings row.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit state-drain
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    state-drain
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    state-drain

STATE="${STATE_DRAIN_STATE_DIR:-$H/state}"
ARCH="${STATE_DRAIN_ARCHIVE_DIR:-$H/archive/state-drain}"
NOW_S="${STATE_DRAIN_NOW:-$(date +%s)}"
CATALOG="$H/catalog/state-paths.json"
HOST=$(hostname)
ALLOW_EXTRA=(gh-policy-cache)

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/state-drain.log"
NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
say() { [ "$MODE" = report ] && return 0; printf '%s %s\n' "$NOW" "$*" >> "$LOG"; }

# int_knob <value> <min> [max] — the value as a number, rc 1 when it is not a
# whole number inside the bounds. These numbers gate a delete, so a guessed one
# is never used.
int_knob() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -ge "$2" ] || return 1
  [ -z "${3:-}" ] || [ "$((10#$1))" -le "$3" ] || return 1
  printf '%s' "$((10#$1))"
}

# in_set <name> <list> — the name is a line of the list, or a dot sibling of one
in_set() {
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$1" in "$a"|"$a".*) return 0 ;; esac
  done <<< "$2"
  return 1
}

# keys_of <name> — the reference keys of a name, one a line (see the header)
keys_of() {
  local n="$1" k prev head tail
  printf '%s\n' "$n"
  k="$n"
  while :; do
    prev="$k"
    case "$k" in
      ?*.tmp|?*.new|?*.prev|?*.lock|?*.err) k="${k%.*}" ;;
      *) [[ $k =~ ^(.+)\.[A-Za-z0-9]{6,12}$ ]] && k="${BASH_REMATCH[1]}" ;;
    esac
    [ "$k" = "$prev" ] && break
    printf '%s\n' "$k"
  done
  case "$n" in
    *.*)
      head="${n%%.*}"; tail=".${n#*.}"
      [ "${#head}" -ge 4 ] && printf '%s\n' "$head"
      [ "${#tail}" -ge 5 ] && printf '%s\n' "$tail"
      ;;
  esac
}

kb_of() { # kb_of <path> — KB on this filesystem, empty when unreadable
  local k
  k=$(du -skx -- "$1" 2>/dev/null | cut -f1)
  case "$k" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

# ── the guards: sandbox, catalog, bin, knobs ─────────────────────────────────
SKIP=""; WHY=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -z "${STATE_DRAIN_STATE_DIR:-}" ]; then
  SKIP="STATE_DRAIN_STATE_DIR unset under HARNESS_TEST_SANDBOX"
fi
ALLOW=""; ROWS=""
if [ -z "$SKIP" ]; then
  if [ ! -f "$CATALOG" ]; then
    WHY="catalog $CATALOG missing"
  elif ! jq -e '.paths | type == "array"' "$CATALOG" >/dev/null 2>&1; then
    WHY="catalog $CATALOG is not JSON with a .paths list"
  else
    ALLOW=$(jq -r '.paths[] | select(.class == "cache" or .class == "box-local") | .path' "$CATALOG" 2>/dev/null)
    ALLOW=$(printf '%s\n' "$ALLOW" "${ALLOW_EXTRA[@]}")
    ROWS=$(jq -r '.paths[] | .path' "$CATALOG" 2>/dev/null)
  fi
fi
if [ -z "$SKIP" ] && [ -z "$WHY" ] && [ "$MODE" != report ]; then
  if [ -z "$(find "$H/bin" -type f -print -quit 2>/dev/null)" ]; then
    WHY="bin $H/bin missing or empty"
  elif [ "$MODE" = dry ]; then
    DRY=1
  elif ! DRY=$(int_knob "${STATE_DRAIN_DRY_RUN:-1}" 0 1); then
    # lane.state-drain.state_drain_dry_run (fallback 1: dry-run first)
    WHY="STATE_DRAIN_DRY_RUN invalid (${STATE_DRAIN_DRY_RUN:-})"
  fi
  # lane.state-drain.state_drain_min_idle_days (fallback 30)
  [ -z "$WHY" ] && ! IDLE_D=$(int_knob "${STATE_DRAIN_MIN_IDLE_DAYS:-30}" 7) \
    && WHY="STATE_DRAIN_MIN_IDLE_DAYS invalid (${STATE_DRAIN_MIN_IDLE_DAYS:-})"
  # lane.state-drain.state_drain_archive_keep_days (fallback 90)
  [ -z "$WHY" ] && ! KEEP_D=$(int_knob "${STATE_DRAIN_ARCHIVE_KEEP_DAYS:-90}" 7) \
    && WHY="STATE_DRAIN_ARCHIVE_KEEP_DAYS invalid (${STATE_DRAIN_ARCHIVE_KEEP_DAYS:-})"
  # lane.state-drain.state_drain_max_per_run (fallback 20)
  [ -z "$WHY" ] && ! MAX=$(int_knob "${STATE_DRAIN_MAX_PER_RUN:-20}" 1 500) \
    && WHY="STATE_DRAIN_MAX_PER_RUN invalid (${STATE_DRAIN_MAX_PER_RUN:-})"
  # lane.state-drain.state_drain_scan_timeout_s (fallback 60)
  [ -z "$WHY" ] && ! SCAN_T=$(int_knob "${STATE_DRAIN_SCAN_TIMEOUT_S:-60}" 5) \
    && WHY="STATE_DRAIN_SCAN_TIMEOUT_S invalid (${STATE_DRAIN_SCAN_TIMEOUT_S:-})"
fi
if [ -z "$SKIP" ] && [ -z "$WHY" ]; then
  STATEREAL=$(cd -P -- "$STATE" 2>/dev/null && pwd)
  [ -n "$STATEREAL" ] && [ "$STATEREAL" != / ] || WHY="state dir $STATE unreadable or /"
fi

# ── the observable: files whose first segment is not allowlisted ─────────────
# unallowlisted <dir> — one path a line, relative to <dir>, sorted
unallowlisted() {
  local p seg
  while IFS= read -r -d '' p; do
    seg="${p%%/*}"
    in_set "$seg" "$ALLOW" || printf '%s\n' "$p"
  done < <(find "$1" -xdev -mindepth 1 -type f -printf '%P\0' 2>/dev/null) | LC_ALL=C sort
}

if [ "$MODE" = report ]; then
  if [ -n "$SKIP" ]; then echo "skipped ($SKIP)" >&2; exit 0; fi
  if [ -n "$WHY" ]; then echo "refused ($WHY)" >&2; exit 0; fi
  LIST=$(unallowlisted "$STATEREAL")
  [ -n "$LIST" ] && printf '%s\n' "$LIST"
  n=$(printf '%s' "$LIST" | grep -c '^' || true)
  segs=$(printf '%s' "$LIST" | cut -d/ -f1 | sort -u | grep -c '^' || true)
  echo "unallowlisted_files=$n segments=$segs" >&2
  exit 0
fi

# Dedupe, never a queue: a run still going owns this slot.
exec 9>"$H/locks/state-drain.lock" || exit 0
flock -n 9 || exit 0

if [ -n "$SKIP" ]; then say "skipped ($SKIP)"; exit 0; fi

alert() { # alert <raise|resolve> <id> <message>
  local la="$H/bin/lane-alert.sh"
  [ -x "$la" ] || return 0
  if [ "$1" = raise ]; then
    "$la" --id "$2" --severity warn state-drain "$3" >/dev/null 2>&1 || true
  else
    "$la" --resolve --id "$2" state-drain "$3" >/dev/null 2>&1 || true
  fi
}
ledger() { # ledger <status> <detail json>
  if [ -r "$H/bin/jobs-client.sh" ]; then
    HARNESS="$H"
    # shellcheck disable=SC1091
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  if ! command -v job_ledger_put >/dev/null 2>&1; then
    say "audit row not written (no jobs client)"; return 0
  fi
  if [ -z "$2" ]; then say "audit row not written (no jq)"; return 0; fi
  job_ledger_put state_drain "state-drain $HOST" "$1" "$2" >/dev/null 2>&1; local rc=$?
  [ "$rc" = 0 ] || say "audit row not written (rc=$rc)"
}

CORPUS=""
trap '[ -n "$CORPUS" ] && rm -f -- "$CORPUS"' EXIT
if [ -z "$WHY" ]; then
  CORPUS=$(mktemp "${TMPDIR:-/tmp}/state-drain-corpus.XXXXXX" 2>/dev/null) || { CORPUS=""; WHY="corpus temp file not created"; }
fi
if [ -z "$WHY" ]; then
  if ! find "$H/bin" "$H/catalog" -type f -exec cat -- {} + > "$CORPUS" 2>/dev/null; then
    WHY="corpus unreadable (a file under $H/bin or $H/catalog)"
  else
    if [ -n "${STATE_DRAIN_CRONTAB_FILE:-}" ]; then
      cat -- "$STATE_DRAIN_CRONTAB_FILE" >> "$CORPUS" 2>/dev/null
    else
      crontab -l >> "$CORPUS" 2>/dev/null
      cat /etc/cron.d/* >> "$CORPUS" 2>/dev/null
    fi
    [ -s "$CORPUS" ] || WHY="corpus empty"
  fi
fi

if [ -n "$WHY" ]; then
  say "refused ($WHY)"
  ledger refused "$(jq -nc --arg w "$WHY" --arg at "$NOW" '{refused:$w, at:$at}' 2>/dev/null)"
  alert raise "state-drain:refused-$HOST" "state-drain on $HOST refused to run: $WHY. Nothing was deleted. See logs/state-drain.log."
  exit 0
fi

# referenced_key <name> — the first key of <name> found in the corpus
referenced_key() {
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    LC_ALL=C grep -qaF -e "$k" -- "$CORPUS" && { printf '%s' "$k"; return 0; }
  done < <(keys_of "$1")
  return 1
}

entries=0; n_allow=0; n_cat=0; n_link=0; n_ref=0; n_fresh=0; n_unread=0
drained=0; would=0; failed=0; left=0; pruned=0
CUT=$((NOW_S - IDLE_D * 86400))
STATEMNT=$(stat -c %m -- "$STATEREAL" 2>/dev/null)
STAMP=$(date -u -d "@$NOW_S" +%Y%m%dT%H%MZ)
while IFS= read -r -d '' name; do
  entries=$((entries + 1))
  e="$STATEREAL/$name"
  if in_set "$name" "$ALLOW"; then
    n_allow=$((n_allow + 1)); printf 'allowlisted\t%s\n' "$name"; continue
  fi
  if in_set "$name" "$ROWS"; then
    n_cat=$((n_cat + 1)); printf 'catalog\t%s\n' "$name"; continue
  fi
  if [ -L "$e" ] || [ -S "$e" ] || [ -p "$e" ] || [ "$(stat -c %m -- "$e" 2>/dev/null)" != "$STATEMNT" ]; then
    n_link=$((n_link + 1)); printf 'link\t%s\n' "$name"; continue
  fi
  if key=$(referenced_key "$name"); then
    n_ref=$((n_ref + 1)); printf 'referenced:%s\t%s\n' "$key" "$name"; continue
  fi
  newest=$(timeout "$SCAN_T" find -P "$e" -xdev -printf '%T@\n' 2>/dev/null \
           | awk -F. '{ n = $1 + 0; if (!seen || n > m) { m = n; seen = 1 } } END { if (seen) print m }'
           exit "${PIPESTATUS[0]}")
  rc=$?
  case "$rc:$newest" in
    0:[0-9]*) ;;
    *) n_unread=$((n_unread + 1)); printf 'unreadable\t%s\n' "$name"; continue ;;
  esac
  if [ "$newest" -ge "$CUT" ]; then
    n_fresh=$((n_fresh + 1)); printf 'fresh\t%s\n' "$name"; continue
  fi
  printf 'drain\t%s\n' "$name"
  kb=$(kb_of "$e") || kb=0
  idle=$(( (NOW_S - newest) / 86400 ))
  if [ "$DRY" = 1 ]; then
    would=$((would + 1)); say "would-drain $name $kb KB idle_days=$idle"; continue
  fi
  if [ "$drained" -ge "$MAX" ]; then left=$((left + 1)); continue; fi
  arc="$ARCH/$STAMP/$name.tgz"
  if [ -e "$arc" ] || ! mkdir -p -- "$ARCH/$STAMP" 2>/dev/null \
     || ! tar -czf "$arc" -C "$STATEREAL" -- "$name" 2>/dev/null \
     || ! tar -tzf "$arc" >/dev/null 2>&1; then
    failed=$((failed + 1)); say "archive-failed $name"; continue
  fi
  # by basename inside the state dir: a path is never built from two seams
  ( cd -P -- "$STATEREAL" && rm -rf --one-file-system -- "$name" ) 2>/dev/null
  if [ ! -e "$e" ] && [ ! -L "$e" ]; then
    drained=$((drained + 1)); say "drained $name $kb KB idle_days=$idle archive=$arc"
  else
    failed=$((failed + 1)); say "delete-failed $name (archive kept at $arc)"
  fi
done < <(find "$STATEREAL" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null | LC_ALL=C sort -z)

UNALLOW=$(unallowlisted "$STATEREAL" | grep -c '^' || true)

# ── archive retention (real runs only) ───────────────────────────────────────
if [ "$DRY" = 0 ] && [ -d "$ARCH" ]; then
  KEEP_CUT=$((NOW_S - KEEP_D * 86400))
  while IFS= read -r -d '' d; do
    st="${d##*/}"
    [[ $st =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})Z$ ]] || continue
    ep=$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}" +%s 2>/dev/null) || continue
    [ "$ep" -lt "$KEEP_CUT" ] || continue
    rm -rf --one-file-system -- "$d" 2>/dev/null
    if [ ! -e "$d" ]; then pruned=$((pruned + 1)); say "archive-pruned $d"; else say "archive-prune-failed $d"; fi
  done < <(find "$ARCH" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

say "run dry=$DRY entries=$entries allowlisted=$n_allow catalog=$n_cat link=$n_link referenced=$n_ref fresh=$n_fresh unreadable=$n_unread drained=$drained would=$would failed=$failed left=$left unallowlisted_files=$UNALLOW archives_pruned=$pruned"

STATUS=ok; [ "$failed" -gt 0 ] && STATUS=partial
ledger "$STATUS" "$(jq -nc --argjson dry "$DRY" --argjson entries "$entries" --argjson al "$n_allow" \
  --argjson ca "$n_cat" --argjson li "$n_link" --argjson re "$n_ref" --argjson fr "$n_fresh" \
  --argjson un "$n_unread" --argjson dr "$drained" --argjson wo "$would" --argjson fa "$failed" \
  --argjson le "$left" --argjson ua "$UNALLOW" --argjson ap "$pruned" --arg at "$NOW" \
  '{dry:$dry, entries:$entries, allowlisted:$al, catalog:$ca, link:$li, referenced:$re, fresh:$fr,
    unreadable:$un, drained:$dr, would:$wo, failed:$fa, left:$le, unallowlisted_files:$ua,
    archives_pruned:$ap, at:$at}' 2>/dev/null)"

alert resolve "state-drain:refused-$HOST" "state-drain on $HOST runs again."
if [ "$DRY" = 0 ]; then
  if [ "$failed" -gt 0 ]; then
    alert raise "state-drain:failed-$HOST" "state-drain on $HOST could not drain $failed state entries. Each one is kept. See logs/state-drain.log."
  else
    alert resolve "state-drain:failed-$HOST" "state-drain on $HOST drained with 0 failures."
  fi
fi
exit 0
