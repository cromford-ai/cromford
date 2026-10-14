#!/bin/bash
# bin/env-diff.sh — announce a change to this box's runner env keys. Cron */15.
#
# WHY (BH-19, the operator 2026-09-24: "A billing-mode change is an architecture change
# and must never be silent"). Which runner a stage uses, how it is billed, which
# model and effort it asks for all live in env files on the box: RUNNER_*,
# *_BILLING, *_MODEL, *_EFFORT. A flip of GROK_BILLING from subscription to api
# changes what every build costs, and until this lane nothing said so. The
# ticket named bin/fleet-heartbeat.sh as the home; BH-1031 deleted that script,
# so this is the "small companion" the ticket allowed.
#
# WHAT IT DOES. Each tick it PARSES (never sources) $HENV/*.env at the top level,
# keeps the matching keys as `file<TAB>KEY<TAB>value` rows, and diffs them
# against state/env-diff/snapshot.tsv. Any difference is ONE fleet_alert naming
# the box and every item as old→new (∅ for absent), sent "triaged":true so
# alert-state, quarantine and the remediators cannot settle it before the operator
# reads it — the console dedupes on its akey, which is a hash of the change
# itself, so a retry of the same change collapses and a new change is new.
#
# DELIVERY BEFORE BOOKKEEPING. The snapshot advances only when beat.sh (with
# BEAT_STRICT=1) says the console took it (rc 0), or when there is no console
# (rc 2) and the line went to logs/ALERTS.log instead. A failed POST advances
# nothing, so the next tick sends the same change again under the same akey.
#
# WHAT IT DOES NOT DO. The first run (or a lost snapshot) is a silent baseline,
# not a change. An env file it cannot read keeps its previous rows: absent is
# not removed. A value is stored and reported as a hash, never in the clear,
# when EITHER the key name looks like a secret (KEY/TOKEN/SECRET/PASS) OR the
# value shape does (value_is_secret, BH-1993): URL userinfo, a credential
# query parameter, a known token prefix, or a long letters-and-digits run. A
# snapshot written before BH-1993 is masked the same way as it is read, so a
# raw value it still holds is never echoed and is rewritten masked.
#
# Off with ENV_DIFF=0 in env/global.env, or flags/lane-off-env-diff.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-$(cd "$HERE/.." && pwd)}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-env-diff
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off env-diff.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit env-diff
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    env-diff
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env"; set +a; fi
# Applied again below the env load: `set -a; . env/global.env` re-assigns every
# name it carries, which would drop a settings row for a knob the file also sets
# (BH-1165 review; section 16 of tests/lanes-registry-test.sh is the ordering).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    env-diff
[ "${ENV_DIFF:-1}" = 0 ] && exit 0

BOX="${ENV_DIFF_BOX:-$(hostname 2>/dev/null)}"
[ -n "$BOX" ] || BOX="(hostname unavailable)"
MAX="${ENV_DIFF_MAX_ITEMS:-20}"
case "$MAX" in ''|*[!0-9]*|0) MAX=20 ;; esac
SDIR="$H/state/env-diff"
SNAP="$SDIR/snapshot.tsv"
LOG="$H/logs/env-diff.log"
ALERTS="$H/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }
alert() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) [env-diff] $*" >> "$ALERTS"; }

# Dedupe, never a queue: a tick already running owns this one.
mkdir -p "$H/locks" "$SDIR" 2>/dev/null
exec 9>"$H/locks/env-diff.lock" || { say "env-diff: cannot open locks/env-diff.lock — skipped"; exit 0; }
flock -n 9 || exit 0

if ! command -v jq >/dev/null 2>&1; then
  alert "env-diff cannot build its beat: jq missing on $BOX. NEEDED: install jq on this box; until then runner/billing env changes here are not announced."
  exit 0
fi
if [ ! -d "$HENV" ]; then
  say "env-diff: env dir $HENV missing — snapshot left alone"
  exit 0
fi

# parse_env <file> — `KEY<TAB>value` for every matching assignment, last wins.
# Parsed, never sourced: sourcing would run whatever the file contains and lose
# which file a value came from.
parse_env() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      eq = index(line, "="); k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
      if (k !~ /^(RUNNER_[A-Z0-9_]+|[A-Z0-9_]+_(BILLING|MODEL|EFFORT))$/) next
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\x27.*\x27$/) v = substr(v, 2, length(v) - 2)
      else sub(/[[:space:]]+#.*$/, "", v)
      gsub(/\t/, " ", v)
      val[k] = v; if (!(k in seen)) { seen[k] = 1; order[++n] = k }
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], val[order[i]] }
  ' "$1"
}
is_secret() { grep -qiE 'KEY|TOKEN|SECRET|PASS' <<<"$1"; }
# value_is_secret <value> — rc 0 when the VALUE carries a credential, whatever
# the key is called (BH-1993: RUNNER_URL=https://user:tok@host went out raw).
# It errs toward masking: a masked model name costs a human one lookup, an
# unmasked token is a leak. `/` is not part of the long-run class, so a path-
# shaped value (accounts/fireworks/models/…) is judged segment by segment.
# BASE64 IS THE EXCEPTION (#2045 lead review): its alphabet has `/` and `+`, so
# about half of all base64 keys split into short segments and leaked. A second
# run class takes `/` in, and such a run counts only when it mixes upper case,
# lower case and digits: random base64 of 32+ characters practically always
# does, a filesystem or URL path practically never does.
# A query name may carry `_`/`-` separated words before the credential word
# (auth_token, client_secret, x-api-key), but not a bare prefix (monkey=).
_VS_USERINFO='[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]]+@'
_VS_QUERY='[?&#;]([a-z0-9]*[_-])*(token|access_token|api_key|apikey|key|secret|password|pass|sig|signature|auth)='
_VS_PREFIX='(^|[^A-Za-z0-9_])(sk-|ghp_|ghs_|gho_|ghu_|github_pat_|xai-)'
_VS_RUN='[A-Za-z0-9_+=-]{32,}'
_VS_B64='[A-Za-z0-9+/]{32,}'
value_is_secret() {
  local v="$1" r
  [[ $v =~ $_VS_USERINFO ]] && return 0
  [[ ${v,,} =~ $_VS_QUERY ]] && return 0
  [[ $v =~ $_VS_PREFIX ]] && return 0
  while [[ $v =~ $_VS_RUN ]]; do
    r="${BASH_REMATCH[0]}"
    [[ $r =~ [0-9] && $r =~ [A-Za-z] ]] && return 0
    v="${v#*"$r"}"
  done
  v="$1"
  while [[ $v =~ $_VS_B64 ]]; do
    r="${BASH_REMATCH[0]}"
    [[ $r =~ [A-Z] && $r =~ [a-z] && $r =~ [0-9] ]] && return 0
    v="${v#*"$r"}"
  done
  return 1
}
# mask_rows — `file<TAB>KEY<TAB>value` rows in, the same rows out with every
# secret value replaced by sha256:<12 hex>. A value already in that form is
# kept: it is a hash this script wrote, and hashing it again would read as a
# change on every tick.
mask_rows() {
  local b k v
  while IFS=$'\t' read -r b k v; do
    if [[ ! $v =~ ^sha256:[0-9a-f]{12}$ ]] && { is_secret "$k" || value_is_secret "$v"; }; then
      v="sha256:$(printf '%s' "$v" | sha256sum | cut -c1-12)"
    fi
    printf '%s\t%s\t%s\n' "$b" "$k" "$v"
  done
}

CUR=$(mktemp "$SDIR/cur.XXXXXX") || { say "env-diff: cannot write in $SDIR — skipped"; exit 0; }
trap 'rm -f "$CUR" "$CUR.sorted" 2>/dev/null' EXIT
READ=0
for f in "$HENV"/*.env; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  b=$(basename "$f")
  if ! rows=$(parse_env "$f" 2>/dev/null); then
    # Unreadable: its previous rows carry forward. Absent is not removed.
    # They are masked on the way through: a pre-BH-1993 snapshot can hold a
    # raw credential, which must not be written back (or beat every tick).
    say "env-diff: $b unreadable — its previous rows kept"
    [ -f "$SNAP" ] && awk -F'\t' -v b="$b" '$1 == b' "$SNAP" | mask_rows >> "$CUR"
    continue
  fi
  READ=$((READ + 1))
  [ -n "$rows" ] || continue
  printf '%s\n' "$rows" | awk -v b="$b" '{ print b "\t" $0 }' | mask_rows >> "$CUR"
done
if [ "$READ" = 0 ]; then
  say "env-diff: no readable env file in $HENV — snapshot left alone"
  exit 0
fi
LC_ALL=C sort -u "$CUR" > "$CUR.sorted"

advance() { mv -f "$CUR.sorted" "$SNAP"; }

if [ ! -f "$SNAP" ]; then
  advance && say "env-diff: baseline written ($(wc -l < "$SNAP" | tr -d ' ') keys) — a baseline is not a change"
  exit 0
fi

# One item per changed (file, KEY), sorted. FILENAME, not NR == FNR: a box
# whose baseline held no matching key has an EMPTY snapshot, and NR == FNR
# would then read the current rows as the old ones (every addition a removal).
# The old side is masked too: a snapshot from before BH-1993 can hold a raw
# credential, and it must neither be echoed nor read as a change of its own.
OLD="$SDIR/old.masked"
trap 'rm -f "$CUR" "$CUR.sorted" "$OLD" 2>/dev/null' EXIT
mask_rows < "$SNAP" | LC_ALL=C sort -u > "$OLD"
ITEMS=$(awk -F'\t' -v snap="$OLD" '
  FILENAME == snap { old[$1 "\t" $2] = $3; k[$1 "\t" $2] = 1; next }
  { new[$1 "\t" $2] = $3; k[$1 "\t" $2] = 1 }
  END {
    for (x in k) {
      o = (x in old); n = (x in new)
      if (o && n && old[x] == new[x]) continue
      split(x, p, "\t")
      if (toupper(p[2]) ~ /KEY|TOKEN|SECRET|PASS/ || old[x] ~ /^sha256:[0-9a-f]+$/ || new[x] ~ /^sha256:[0-9a-f]+$/) {
        verb = (o && n) ? "changed" : (n ? "added" : "removed")
        printf "%s %s %s (value redacted)\n", p[1], p[2], verb
      } else {
        printf "%s %s %s→%s\n", p[1], p[2], (o ? old[x] : "∅"), (n ? new[x] : "∅")
      }
    }
  }' "$OLD" "$CUR.sorted" | LC_ALL=C sort)
if [ -z "$ITEMS" ]; then
  # Nothing changed. A snapshot that still held a raw value is rewritten masked.
  cmp -s "$OLD" "$SNAP" || { advance && say "env-diff: snapshot rewritten with secret values masked"; }
  exit 0
fi

TOTAL=$(printf '%s\n' "$ITEMS" | wc -l | tr -d ' ')
AKEY="envdiff:$BOX:$(printf '%s\n' "$ITEMS" | sha256sum | cut -c1-16)"
SHOWN=$(head -n "$MAX" <<<"$ITEMS" | paste -sd ';' - | sed 's/;/; /g')
MORE=""
[ "$TOTAL" -gt "$MAX" ] && MORE=" (+$((TOTAL - MAX)) more; full list in logs/env-diff.log)"
LINE="ENV CHANGE on $BOX: $SHOWN$MORE (runner/billing config is architecture: confirm this was intended)"
PAYLOAD=$(jq -nc --arg line "$LINE" --arg akey "$AKEY" \
  '{kind:"fleet_alert",project:"fleet",triaged:true,severity:"warn",akey:$akey,line:$line}') || {
  say "env-diff: could not build the beat payload — snapshot left alone"; exit 0; }

say "env-diff: $TOTAL change(s) akey=$AKEY"
printf '%s\n' "$ITEMS" | sed 's/^/  /' >> "$LOG"

BEAT_STRICT=1 "$HERE/beat.sh" "$PAYLOAD"; RC=$?
case "$RC" in
  0) advance && say "env-diff: delivered, snapshot advanced" ;;
  2) if alert "$LINE"; then
       advance && say "env-diff: no console configured — written to ALERTS.log, snapshot advanced"
     else
       say "env-diff: no console and ALERTS.log not writable — snapshot left alone"
     fi ;;
  *) say "env-diff: beat rc=$RC — snapshot left alone, the next tick re-sends akey=$AKEY" ;;
esac
exit 0
