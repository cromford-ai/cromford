#!/bin/bash
# bin/switch-migrate.sh [--dry-run] — BH-2320: copy this box's file kill switches into settings rows.
#
# For every switch registered in catalog/switches.d/<name>.json whose
# flags/<name> exists on this box and that has neither a box row
# `switch.<name>.<box>` nor a fleet row `switch.<name>`, write the BOX row
# `switch.<name>.<box>=1` (PUT /api/settings, actor switch-migrate). A box row,
# not a fleet row: the file stopped the thing on this box only, and so does the
# row. The file is left where it is. bin/lib/lane-switch.sh is the reader.
#
# One line per switch on stdout:
#   wrote <name> <key>        the row was written (2xx)
#   would-write <name> <key>  --dry-run: nothing was written
#   exists <name> <key>       a row already covers it; nothing written
#   absent <name>             no flags/<name> on this box
#   bare <name> <file:line>   a script still reads flags/<name> bare; not migrated
#   bare <name> <file>        a catalog reader never calls `lane_switch <name>`; not migrated
#   failed <name> <key> ...   the write did not land (or the key cannot exist)
#
# Exit: 0 all done, 1 a registry file was refused (nothing written) or a write
# failed, 75 the settings table could not be read (nothing written: without it
# there is no telling whether a row exists).
# A switch that some script in bin/ or fly/ still reads as a bare
# `[ -f .../flags/<name> ]` is skipped, `bare` (BH-2412). Its readers would
# split: removing the file re-arms the bare reader, while lane_switch's readers
# keep obeying the row (a row beats the file). It migrates on the first run
# after its last bare reader is converted. So is one that any of its catalog
# `readers` reads without `lane_switch <name>` (a `flag_on`, a `[ ! -f`, any
# shape): only a reader that goes through lane_switch obeys the row, so a
# switch migrates only once every registered reader does.
# Idempotent: a second run finds the row and writes nothing.
# bin/update-runners.sh runs it daily (BH-2412); by hand, `--dry-run` first.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/lane-switch.sh" || { echo "switch-migrate: cannot load bin/lib/lane-switch.sh" >&2; exit 1; }

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  *) echo "usage: switch-migrate.sh [--dry-run]" >&2; exit 2 ;;
esac

REG="$H/catalog/switches.d"
NAMES=(); BAD=0
for f in "$REG"/*.json; do
  [ -e "$f" ] || continue
  want=$(basename "$f" .json)
  n=$(jq -r '.name | strings' "$f" 2>/dev/null)
  if [ "$n" != "$want" ] || ! _ls_name_ok "$n"; then
    echo "refused $f: name '$n' must be the filename ($want) and match [a-z0-9_-]"
    BAD=1; continue
  fi
  NAMES+=("$n")
done
[ "$BAD" -eq 0 ] || { echo "switch-migrate: registry refused, nothing written" >&2; exit 1; }
[ "${#NAMES[@]}" -gt 0 ] || { echo "switch-migrate: no switches registered under $REG"; exit 0; }

_lg_ensure_client
command -v _jobs_req >/dev/null 2>&1 \
  || { echo "switch-migrate: no jobs client (bin/jobs-client.sh), nothing written" >&2; exit 75; }
# An empty table is an answer (no rows); a failed request, or a body with no
# settings array, is not.
RESP=$(_jobs_req GET /api/settings) && [ -n "$RESP" ] \
  && KEYS=$(printf '%s' "$RESP" | jq -r '.settings | if type == "array" then .[].key else error("no settings array") end' 2>/dev/null) \
  || { echo "switch-migrate: GET /api/settings unreadable (http=${JOBS_HTTP:-none}), nothing written" >&2; exit 75; }
has_key() { grep -qxF "$1" <<<"$KEYS"; }
# bare_reader <name> — the first code line in bin/ or fly/ that reads
# flags/<name> as a bare file test (the switch-ratchet pattern), as <file:line>.
bare_reader() {
  local root; root=$(cd "$HERE/.." && pwd)
  grep -rnE "\[ -[ef] [^]]*flags/$1([^a-z0-9_-]|\$)" "$root/bin" "$root/fly" 2>/dev/null \
    | awk -F: '$3 !~ /^[[:space:]]*#/ { print $1 ":" $2; exit }' | sed "s|^$root/||"
}
# unconverted_reader <name> — the first of catalog/switches.d/<name>.json's
# `readers` with no code line calling `lane_switch <name>`, or the registry
# file itself when it lists no reader.
unconverted_reader() {
  local root r any=0; root=$(cd "$HERE/.." && pwd)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    any=1
    grep -E "(^|[^a-z0-9_])lane_switch[[:space:]]+['\"]?$1(['\"]|[^a-z0-9_-]|\$)" "$root/$r" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' >/dev/null || { printf '%s\n' "$r"; return; }
  done < <(jq -r '.readers[]? | strings' "$REG/$1.json" 2>/dev/null)
  [ "$any" -eq 1 ] || printf 'catalog/switches.d/%s.json\n' "$1"
}

BOX=$(_lg_box | tr '[:upper:]' '[:lower:]')
FAILED=0; WROTE=0
for n in "${NAMES[@]}"; do
  [ -f "$H/flags/$n" ] || { echo "absent $n"; continue; }
  br=$(bare_reader "$n")
  [ -z "$br" ] || { echo "bare $n $br"; continue; }
  ur=$(unconverted_reader "$n")
  [ -z "$ur" ] || { echo "bare $n $ur"; continue; }
  fk=$(_ls_fleet_key "$n")
  if ! bk=$(_ls_box_key "$n"); then
    echo "failed $n switch.$n.$BOX (not a valid settings key: charset or >64 chars)"; FAILED=1; continue
  fi
  if has_key "$bk"; then echo "exists $n $bk"; continue; fi
  if has_key "$fk"; then echo "exists $n $fk"; continue; fi
  if [ "$DRY" -eq 1 ]; then echo "would-write $n $bk"; continue; fi
  body=$(jq -nc --arg k "$bk" --arg n "flags/$n on $BOX, migrated by bin/switch-migrate.sh" \
    '{key:$k, value:"1", actor:"switch-migrate", note:$n}')
  if _jobs_req PUT /api/settings "$body" >/dev/null && case "${JOBS_HTTP:-}" in 2*) true ;; *) false ;; esac; then
    echo "wrote $n $bk"; WROTE=$((WROTE+1))
  else
    echo "failed $n $bk (http=${JOBS_HTTP:-none})"; FAILED=1
  fi
done
mkdir -p "$H/logs" 2>/dev/null
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') box=$BOX dry=$DRY switches=${#NAMES[@]} wrote=$WROTE failed=$FAILED" \
  >> "$H/logs/switch-migrate.log" 2>/dev/null
[ "$FAILED" -eq 0 ]
