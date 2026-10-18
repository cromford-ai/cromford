#!/bin/bash
# bin/box-lists-check.sh [--root <dir>] — do the box lists agree with fleet.conf?
#
# A box is named in nine lists (docs/ADDING-A-BOX.md has the table). fleet.conf
# is the registry; every other list must name each of its boxes, and must name
# no box it does not. This compares them in both directions. It reads files
# only: no network, no ssh, no write.
#
# THE BOX UNIVERSE
#   required U = bin/fleet-conf.sh --box-ids, plus hub
#   allowed    = U, plus the box ids of the `# @retired <project> <box>` lines
#                and of the `# @boxrole <box> <box_id> <role>` lines (a box with
#                no project row, such as a review or gate box). Those may be
#                listed; they are never required.
#   HOST(id)   = cron_watchdog_name_for (bin/lib/cron-lines.sh), the one inverse
#                of cron_box_id_for. Neither mapping is spelled again here.
#
# OUTPUT: one line per finding, then `box-lists: <n> finding(s) over <k> boxes`.
#   MISSING <list> <box>   a required box is not in that list
#   EXTRA <list> <box>     the list names a box outside the allowed set
#   BAD <list> <detail>    the list names the box wrongly
# EXIT: 0 no finding; 1 findings; 2 an input could not be read. A missing or
# unparsable file is never "no finding".
#
# Both FLEET_CONF and LANE_REGISTRY come from --root, never from the caller's
# environment: a check of a scratch tree must not read the live registry.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) echo "usage: box-lists-check.sh [--root <dir>]" >&2; exit 2 ;;
  esac
done
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || { echo "box-lists-check: no directory $ROOT" >&2; exit 2; }
export FLEET_CONF="$ROOT/fleet.conf"
unset LANE_REGISTRY
die() { echo "box-lists-check: $*" >&2; exit 2; }
[ -f "$FLEET_CONF" ] || die "cannot read $FLEET_CONF"
BIN="$ROOT/bin"
# shellcheck source=bin/lib/cron-lines.sh
. "$BIN/lib/cron-lines.sh" || die "cannot source $BIN/lib/cron-lines.sh"

CA="$ROOT/catalog/cost-accounts.json"
WD="$ROOT/worker/watchdog/src/boxes.json"
MAP="$ROOT/bin/share/mapping.py"
LD="$ROOT/catalog/lanes.d"
jq -e '.box_aliases and .accounts' "$CA" >/dev/null 2>&1 || die "cannot parse $CA"
jq -e 'type == "array"' "$WD" >/dev/null 2>&1 || die "cannot parse $WD"
[ -d "$LD" ] || die "no $LD"
[ -f "$LD/watchdog-ping.json" ] || die "no $LD/watchdog-ping.json"

U=$( { "$BIN/fleet-conf.sh" --box-ids || exit 1; echo hub; } | sort -u) || die "fleet-conf.sh --box-ids failed"
RET_HOSTS=$("$BIN/fleet-conf.sh" --retired | awk '$2 != "-" {print $2}' | sort -u)
RET_IDS=$(while read -r H; do [ -n "$H" ] && cron_box_id_for "$H"; done <<< "$RET_HOSTS" | sort -u)
ROLE_IDS=$("$BIN/fleet-conf.sh" --boxes-with-roles | cut -f2 | sort -u) || die "fleet-conf.sh --boxes-with-roles failed"
ALLOWED=$(printf '%s\n%s\n%s\n' "$U" "$RET_IDS" "$ROLE_IDS" | grep . | sort -u)
declare -A HOST
for ID in $U; do
  HOST[$ID]=$(cron_watchdog_name_for "$ID") || die "the registry names no host for box $ID"
done
HOSTS_ALLOWED=$( { for ID in $U; do echo "${HOST[$ID]}"; done; printf '%s\n' "$RET_HOSTS"; } | grep . | sort -u)

FINDINGS=""
say() { FINDINGS="$FINDINGS$*"$'\n'; }
# A here-string, not a pipe: under pipefail, `printf | grep -q` can fail on
# SIGPIPE when grep exits first, and that reads as "not in the set".
in_set() { grep -qxF -- "$1" <<< "$2"; }

# 1. ids — a hyphen breaks the sanitizer and the lane registry (7c91e62ae).
for ID in $U; do
  [[ "$ID" =~ ^[a-z][a-z0-9]*$ ]] || say "BAD ids $ID"
done

# 2. cron-boxes — every box has its fragment dir; no dir or .order for a stranger.
#    A `_` name (cron/boxes/_template.d) is a template, never a box (BH-5650).
for ID in $U; do [ -d "$ROOT/cron/boxes/$ID.d" ] || say "MISSING cron-boxes $ID"; done
for F in "$ROOT"/cron/boxes/*.d "$ROOT"/cron/boxes/*.order; do
  [ -e "$F" ] || continue
  B=$(basename "$F"); B="${B%.d}"; B="${B%.order}"
  case "$B" in _*) continue ;; esac
  in_set "$B" "$ALLOWED" || say "EXTRA cron-boxes $B"
done

# 3. lanes — no lane names a stranger; every box pings the watchdog (a box with
#    no ping is invisible: the watchdog cannot page about what it never heard).
LANE_BOXES=$(jq -r '.boxes[]?' "$LD"/*.json 2>/dev/null) || die "cannot parse $LD/*.json"
for B in $(printf '%s\n' "$LANE_BOXES" | sort -u); do
  in_set "$B" "$ALLOWED" || say "EXTRA lanes $B"
done
PING=$(jq -r '.boxes[]?' "$LD/watchdog-ping.json") || die "cannot parse $LD/watchdog-ping.json"
for ID in $U; do in_set "$ID" "$PING" || say "MISSING watchdog-ping $ID"; done

# 4. box_aliases (host -> id) — every box has one, and its key is HOST(id).
ALIAS=$(jq -r '.box_aliases | to_entries[] | "\(.key) \(.value)"' "$CA")
ALIAS_IDS=$(printf '%s\n' "$ALIAS" | awk 'NF {print $2}' | sort -u)
for ID in $U; do in_set "$ID" "$ALIAS_IDS" || say "MISSING box_aliases $ID"; done
while read -r K V; do
  [ -n "${K:-}" ] || continue
  if ! in_set "$V" "$ALLOWED"; then say "EXTRA box_aliases $V"; continue; fi
  in_set "$V" "$U" || continue
  [ "$K" = "${HOST[$V]}" ] || say "BAD box_aliases $K maps to $V, whose host is ${HOST[$V]}"
done <<< "$ALIAS"

# 5. cost_rows — every box is in exactly one account (two would bill it twice).
ROWS=$(jq -r '.accounts[] | .boxes.cost_rows[]?' "$CA")
for B in $(printf '%s\n' "$ROWS" | sort -u); do
  in_set "$B" "$ALLOWED" || say "EXTRA cost_rows $B"
done
for ID in $U; do
  C=$(printf '%s\n' "$ROWS" | grep -cxF -- "$ID")
  case "$C" in
    0) say "MISSING cost_rows $ID" ;;
    1) ;;
    *) say "BAD cost_rows $ID in $C accounts" ;;
  esac
done

# 6. jobs — hosts of allowed boxes, or a glob (fly pool machine ids).
for J in $(jq -r '.accounts[] | .boxes.jobs[]?' "$CA" | sort -u); do
  case "$J" in *'*'*) continue ;; esac
  in_set "$J" "$HOSTS_ALLOWED" || say "EXTRA jobs $J"
done

# 7. watchdog — the worker's box list is HOST(U) (retired hosts allowed).
WDL=$(jq -r '.[]' "$WD")
for ID in $U; do in_set "${HOST[$ID]}" "$WDL" || say "MISSING watchdog $ID"; done
for W in $(printf '%s\n' "$WDL" | sort -u); do
  in_set "$W" "$HOSTS_ALLOWED" || say "EXTRA watchdog $W"
done

# 8. tailnet_ips — every fleet.conf address has a redaction entry, or the share
#    mirror publishes it. Forward only: the table also maps the hub's address and
#    old addresses that no row names, and dropping those would leak them.
#    The dict is PARSED, never imported: a check does not run mapping.py.
#    The public mirror ships no bin/share/ and so has no table: one NOTE, and
#    the check is skipped. A table that IS there and does not parse is rc 2.
if [ ! -e "$MAP" ]; then
  echo "NOTE tailnet_ips skipped: no $MAP (the public mirror has no redaction table)"
else
KEYS=$(python3 -I - "$MAP" <<'PY' 2>/dev/null
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "TAILNET_IPS" for t in node.targets):
        for k in ast.literal_eval(node.value):
            print(k)
        sys.exit(0)
sys.exit(1)
PY
) || die "cannot parse TAILNET_IPS in $MAP"
while read -r P B IP; do
  [ -n "${IP:-}" ] || continue
  [ "$B" != "-" ] || B=$("$BIN/box-for.sh" "$P" 2>/dev/null) || continue
  in_set "$IP" "$KEYS" || say "MISSING tailnet_ips $(cron_box_id_for "$B")"
done < <(awk '!/^[[:space:]]*(#|$)/ {print $1, ($6 == "" ? "-" : $6), $7}' "$FLEET_CONF")
fi

# 9. cost-rollup — run the real overage block and compare what it collects
#    with U minus hub. (The hub's meter is collected beside it, not in it.)
BLOCK=$(sed -n '/^# >>> overage boxes (BH-5747)$/,/^# <<< overage boxes$/p' "$BIN/cost-rollup.sh")
[ -n "$BLOCK" ] || die "no '# >>> overage boxes (BH-5747)' block in $BIN/cost-rollup.sh"
COLL=$(bash -c "$BLOCK"$'\nprintf "%s\\n" $OVERAGE_BOXES' "$BIN/cost-rollup.sh" | grep . | sort -u)
for ID in $U; do
  [ "$ID" = hub ] && continue
  in_set "$ID" "$COLL" || say "MISSING cost-rollup $ID"
done
for B in $COLL; do in_set "$B" "$U" || say "EXTRA cost-rollup $B"; done

OUTL=$(printf '%s' "$FINDINGS" | awk 'NF && !seen[$0]++')
[ -z "$OUTL" ] || printf '%s\n' "$OUTL"
N=$(printf '%s' "$OUTL" | grep -c .)
echo "box-lists: $N finding(s) over $(printf '%s\n' "$U" | grep -c .) boxes"
[ "$N" = 0 ]
