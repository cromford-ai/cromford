#!/bin/bash
# bin/box-register.sh — write one box into every box list, or take it out.
#
#   box-register.sh <id> --ip <tailnet-ip> --project <p> [--account <a>] [--like <box-id>]
#                   [--root <dir>] [--apply]
#   box-register.sh <id> --trap-eval [--like <box-id>] [--root <dir>] [--apply]
#   box-register.sh --retire <id> [--ip <tailnet-ip>] [--root <dir>] [--apply]
#   box-register.sh --retire <id> --trap-eval [--root <dir>] [--apply]
#
# DRY RUN IS THE DEFAULT. Without --apply it prints one PLAN line per change and
# writes nothing. --apply makes the changes, then runs bin/box-lists-check.sh
# (and, on register, bin/render-cron.sh <id>) as its post-check. It never
# commits, pushes, or touches a crontab. It calls no network service and no ssh.
# docs/ADDING-A-BOX.md is the operator's guide.
#
# THE LISTS (L9, the cost-rollup collect loop, reads fleet.conf: no edit)
#   L1 fleet.conf col 6 + 7          the --project row gets <host> <ip>
#   L2 cron/boxes/<id>.d/            000-path.cron (hub's) + 001-fleet-managed.cron,
#                                    or a copy of the --like box's fragments
#   L3 cron/boxes/<id>.order         only with --like, when that box has one
#   L4 catalog/lanes.d/*.json .boxes the lanes EVERY other active watcher box runs,
#                                    or the --like box's lanes (trap-eval excepted)
#   L5 catalog/cost-accounts.json .box_aliases[<host>] = <id>
#   L6   .accounts[<a>].boxes.cost_rows += <id>, .jobs += <host> (before a glob)
#   L7 worker/watchdog/src/boxes.json += <host>
#   L8 bin/share/mapping.py TAILNET_IPS  "<ip>": "10.0.0.<next>" (the mirror's
#                                    redaction table)
#
# The id is a box ID ([a-z][a-z0-9]*, no hyphen, never hub). Its host is the
# fleet.conf name of a box that already has one (cron_watchdog_name_for), else
# <HARNESS_BOX_PREFIX><id>. The --project row must already exist
# (bin/load-project.sh adds it); setting it here is also how a project MOVES.
# --account is required until the box is in an account; one box, one account.
#
# BH-1965: a branch diff that touches catalog/lanes.d/trap-eval.json AND cron/
# turns tests/trap-eval-e2e.bh-128-test.sh red. So trap-eval.json is its own
# step (--trap-eval), on its own branch: register first, trap-eval after that
# merges; retire trap-eval first, the rest after that merges. Each step refuses
# (rc 3) when the branch already carries the other step's files.
#
# Retire refuses while a fleet.conf row points at the box, for a `# @standby`
# box, and for hub. L8 is removed only with --ip, and only when no other
# tracked file names the address: the table is a redaction table, and dropping
# an address a note still quotes would publish it.
#
# EXIT: 0 done (or the dry run printed); 1 an apply step or the post-check
# failed; 2 usage error or refusal; 3 refused by the BH-1965 order.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
ID=""; RETIRE=0; IP=""; PROJECT=""; ACCOUNT=""; LIKE=""; TRAP=0; APPLY=0
usage() { echo "usage: box-register.sh <id> --ip <ip> --project <p> [--account <a>] [--like <id>] [--root <dir>] [--apply]" >&2
          echo "       box-register.sh <id> --trap-eval | --retire <id> [--ip <ip>] [--trap-eval]  (see -h)" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --retire)    RETIRE=1; ID="${2-}"; shift 2 || usage ;;
    --ip)        IP="${2-}"; shift 2 || usage ;;
    --project)   PROJECT="${2-}"; shift 2 || usage ;;
    --account)   ACCOUNT="${2-}"; shift 2 || usage ;;
    --like)      LIKE="${2-}"; shift 2 || usage ;;
    --root)      ROOT="${2-}"; shift 2 || usage ;;
    --trap-eval) TRAP=1; shift ;;
    --apply)     APPLY=1; shift ;;
    --dry-run)   APPLY=0; shift ;;
    -h|--help)   awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    -*)          echo "box-register: unknown flag $1" >&2; usage ;;
    *)           [ -z "$ID" ] || { echo "box-register: unexpected argument $1" >&2; usage; }; ID="$1"; shift ;;
  esac
done
refuse() { echo "REFUSED: $*" >&2; exit 2; }
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || refuse "no directory $ROOT"
export FLEET_CONF="$ROOT/fleet.conf" PYTHONDONTWRITEBYTECODE=1
unset LANE_REGISTRY
BIN="$ROOT/bin"
[ -f "$FLEET_CONF" ] || refuse "no $FLEET_CONF"
# shellcheck source=bin/lib/cron-lines.sh
. "$BIN/lib/cron-lines.sh" || refuse "cannot source $BIN/lib/cron-lines.sh"

CA="$ROOT/catalog/cost-accounts.json"
WD="$ROOT/worker/watchdog/src/boxes.json"
MAP="$ROOT/bin/share/mapping.py"
LD="$ROOT/catalog/lanes.d"
TE="catalog/lanes.d/trap-eval.json"

# ---------- validation: nothing is written before all of it passes ----------
[ -n "$ID" ] || usage
[[ "$ID" =~ ^[a-z][a-z0-9]*$ ]] || refuse "box id '$ID' must match ^[a-z][a-z0-9]*\$ (no hyphen, no capital)"
[ "$ID" != hub ] || refuse "hub is not registered or retired by this script"
for F in "$CA" "$WD" "$LD/watchdog-ping.json"; do [ -f "$F" ] || refuse "no $F"; done
jq -e '.box_aliases and .accounts' "$CA" >/dev/null 2>&1 || refuse "cannot parse $CA"

# rows: "<project> <id> <ip|->" for every active fleet.conf row
ROWS=$(while read -r P B R_IP; do
         [ -n "$P" ] || continue
         [ "$B" != "-" ] || B=$("$BIN/box-for.sh" "$P" 2>/dev/null) || continue
         echo "$P $(cron_box_id_for "$B") $R_IP"
       done < <(awk '!/^[[:space:]]*(#|$)/ {print $1, ($6 == "" ? "-" : $6), ($7 == "" ? "-" : $7)}' "$FLEET_CONF"))
HOST=$(cron_watchdog_name_for "$ID" 2>/dev/null) \
  || HOST=$(jq -r --arg id "$ID" '[.box_aliases | to_entries[] | select(.value == $id) | .key][0] // empty' "$CA")
[ -n "$HOST" ] || HOST="${HARNESS_BOX_PREFIX}${ID}"
CUR_ACCOUNTS=$(jq -r --arg id "$ID" '.accounts | to_entries[] | select(.value.boxes.cost_rows | index($id)) | .key' "$CA")

if [ -n "$IP" ]; then
  # 100.64/10 (second octet 64-127): the tailnet's CGNAT range. Anything else
  # is a typo or a LAN.
  [[ "$IP" =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    && [ "${BASH_REMATCH[1]}" -ge 64 ] && [ "${BASH_REMATCH[1]}" -le 127 ] \
    && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] \
    || refuse "--ip $IP is not a tailnet address (the CGNAT range 100.64/10)"
fi

if [ "$RETIRE" = 0 ] && [ "$TRAP" = 0 ]; then
  [ -n "$IP" ] && [ -n "$PROJECT" ] || refuse "register needs --ip and --project"
  "$BIN/fleet-conf.sh" "$PROJECT" repo >/dev/null 2>&1 \
    || refuse "fleet.conf has no row for project '$PROJECT'. Add it first: bin/load-project.sh <owner/repo> --project $PROJECT --box $HOST --no-bootstrap"
  OTHER=$(awk -v ip="$IP" -v id="$ID" '$3 == ip && $2 != id {print $2 " (project " $1 ")"; exit}' <<< "$ROWS")
  [ -z "$OTHER" ] || refuse "--ip $IP is already the address of box $OTHER"
  # "-" is a row with no tailnet_ip column (optional, fleet.conf header): it
  # names no address, so it cannot conflict with --ip.
  OLDIP=$(awk -v ip="$IP" -v id="$ID" '$2 == id && $3 != "-" && $3 != ip {print $3 " (project " $1 ")"; exit}' <<< "$ROWS")
  [ -z "$OLDIP" ] || refuse "box $ID already has the address $OLDIP; it cannot also be $IP"
  if [ -n "$LIKE" ]; then
    [ "$LIKE" != hub ] || refuse "--like hub: the hub's lanes are not a watcher box's lanes"
    [[ "$LIKE" =~ ^[a-z][a-z0-9]*$ ]] && [ -d "$ROOT/cron/boxes/$LIKE.d" ] || refuse "--like $LIKE: no cron/boxes/$LIKE.d"
  fi
  KEYS=$(jq -r '.accounts | keys[]' "$CA")
  if [ -n "$ACCOUNT" ]; then
    grep -qxF -- "$ACCOUNT" <<< "$KEYS" \
      || refuse "--account $ACCOUNT is not an account in catalog/cost-accounts.json. The accounts are: $(echo $KEYS)"
    [ -z "$CUR_ACCOUNTS" ] || [ "$CUR_ACCOUNTS" = "$ACCOUNT" ] \
      || refuse "box $ID is already in account $(echo $CUR_ACCOUNTS); one box, one account"
  else
    case "$(printf '%s' "$CUR_ACCOUNTS" | grep -c .)" in
      1) ;;
      0) refuse "box $ID is in no account yet: give --account <one of: $(echo $KEYS)>" ;;
      *) refuse "box $ID is in more than one account ($(echo $CUR_ACCOUNTS)); fix catalog/cost-accounts.json first" ;;
    esac
    ACCOUNT="$CUR_ACCOUNTS"
  fi
fi
if [ "$RETIRE" = 1 ]; then
  while read -r SB _; do
    [ -n "${SB:-}" ] || continue
    [ "$(cron_box_id_for "$SB")" != "$ID" ] || refuse "box $ID is a @standby box in fleet.conf; remove that directive first"
  done < <("$BIN/fleet-conf.sh" --standby)
  ON=$(awk -v id="$ID" '$2 == id {print $1}' <<< "$ROWS")
  [ -z "$ON" ] || refuse "projects still run on box $ID: $(echo $ON). Move each one first (box-register.sh <other-box> --ip <its ip> --project <p>)"
fi
if [ "$TRAP" = 1 ] && [ "$RETIRE" = 0 ]; then
  [ -d "$ROOT/cron/boxes/$ID.d" ] || refuse "box $ID is not registered: run the main step first"
fi

# ---------- BH-1965 change-set guard ----------
CHANGED=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  GBASE=$(git -C "$ROOT" merge-base origin/main HEAD 2>/dev/null) || GBASE=HEAD
  CHANGED=$( { git -C "$ROOT" diff --name-only "$GBASE" 2>/dev/null
               git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null; } | sort -u)
else
  echo "NOTE: $ROOT is not a git tree, so the BH-1965 change-set guard did not run"
fi
TRAP_CMD="bin/box-register.sh $ID --trap-eval${LIKE:+ --like $LIKE} --apply"
[ "$RETIRE" = 0 ] || TRAP_CMD="bin/box-register.sh --retire $ID --trap-eval --apply"
if [ "$TRAP" = 1 ]; then
  if grep -q '^cron/' <<< "$CHANGED"; then
    echo "REFUSED: this branch already changes cron/. $TE must not be in the same change set (BH-1965)." >&2
    echo "NEXT: commit and merge this branch, then run '$TRAP_CMD' on a fresh branch from origin/main." >&2
    exit 3
  fi
else
  if grep -qxF "$TE" <<< "$CHANGED"; then
    echo "REFUSED: this branch already changes $TE. The main step must not be in the same change set (BH-1965)." >&2
    exit 3
  fi
  if [ "$RETIRE" = 1 ] && jq -e --arg id "$ID" '.boxes | index($id)' "$ROOT/$TE" >/dev/null 2>&1; then
    echo "REFUSED: $TE still lists $ID. Retire takes it out of trap-eval FIRST, on its own branch (BH-1965)." >&2
    echo "NEXT: $TRAP_CMD" >&2
    echo "NEXT: commit and merge that, then run this command again on a fresh branch from origin/main." >&2
    exit 3
  fi
fi

# ---------- steps ----------
FAILED=0; TOUCHED=""
did()  { # <L> <file> <what>: a change; dry run plans it, apply has made it
  if [ "$APPLY" = 1 ]; then echo "DONE $1 $2 $3"; else echo "PLAN $1 $2 $3"; fi
  TOUCHED="$TOUCHED $2"; }
same() { echo "OK   $1 $2 already: $3"; }
fail() { echo "FAILED $1 $2 $3" >&2; FAILED=1; }
atomic_jq() { # <file> <jq args...>: write through a temp file, never in place
  local F="$1" TMP; shift
  TMP=$(mktemp "$F.XXXXXX") || return 1
  if jq "$@" "$F" > "$TMP"; then mv -f "$TMP" "$F"; else rm -f "$TMP"; return 1; fi
}

# lanes_edit <file> <add|remove|has> <id>: a TEXT edit of the "boxes" array only.
# Five lane files are not `jq .`-stable (review-prs.json escapes a dash), so a
# jq rewrite would reformat the whole file. rc 0 changed (or, for has, listed),
# 3 nothing to do, 1 refused (the JSON outside .boxes would have changed).
lanes_edit() {
  local W="$APPLY"; [ "$2" = has ] && W=0
  python3 -I - "$1" "$2" "$3" "$W" <<'PY'
import json, re, sys
path, op, bid, write = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
old = open(path, encoding="utf-8").read()
m = re.search(r'^([ \t]*)"boxes": \[(.*?)\]', old, re.S | re.M)
if not m:
    sys.exit(3)
ind, items = m.group(1), json.loads("[" + m.group(2) + "]")
if op == "has":
    sys.exit(0 if bid in items else 3)
if op == "add":
    if bid in items:
        sys.exit(3)
    at = next((i for i, x in enumerate(items) if x > bid), len(items))
    items.insert(at, bid)
else:
    if bid not in items:
        sys.exit(3)
    items = [x for x in items if x != bid]
if items:
    body = "[\n" + ",\n".join(ind + "  " + json.dumps(x) for x in items) + "\n" + ind + "]"
else:
    body = "[]"
new = old[:m.start()] + ind + '"boxes": ' + body + old[m.end():]
want = json.loads(old)
want["boxes"] = items
if json.loads(new) != want:
    sys.exit(1)
if write:
    open(path + ".tmp", "w", encoding="utf-8").write(new)
    import os
    os.replace(path + ".tmp", path)
PY
}

# tailnet_edit <add|remove|has> <ip>: TAILNET_IPS in bin/share/mapping.py, parsed
# with ast (never imported). add puts the next 10.0.0.<N> above the "Not a fleet
# box" comment. rc 0 changed (has: present), 3 nothing to do, 1 refused.
tailnet_edit() {
  local W="$APPLY"; [ "$1" = has ] && W=0
  python3 -I - "$MAP" "$1" "$2" "$W" <<'PY'
import ast, os, re, sys
path, op, ip, write = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
src = open(path, encoding="utf-8").read()
def table(text):
    for node in ast.parse(text).body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "TAILNET_IPS" for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit(1)
cur = table(src)
if op == "has":
    sys.exit(0 if ip in cur else 3)
lines = src.split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("TAILNET_IPS = {"))
end = next(i for i in range(start, len(lines)) if lines[i] == "}")
if op == "add":
    if ip in cur:
        sys.exit(3)
    n = max(int(v.rsplit(".", 1)[1]) for v in cur.values()) + 1
    at = next((i for i in range(start, end) if lines[i].strip().startswith("# Not a fleet box")), end)
    lines.insert(at, '    "%s": "10.0.0.%d",' % (ip, n))
    print("10.0.0.%d" % n)
else:
    if ip not in cur:
        sys.exit(3)
    lines = [l for i, l in enumerate(lines) if not (start < i < end and re.match(r'\s*"%s":' % re.escape(ip), l))]
new = "\n".join(lines)
after = table(new)
if (ip in after) != (op == "add") or {k: v for k, v in after.items() if k != ip} != {k: v for k, v in cur.items() if k != ip}:
    sys.exit(1)
if write:
    open(path + ".tmp", "w", encoding="utf-8").write(new)
    os.replace(path + ".tmp", path)
PY
}

# The lane set for a new box. Default: the lanes every OTHER active watcher box
# runs (derived from the registry, never a list here). --like: that box's lanes.
lane_set() {
  local OTHERS
  if [ -n "$LIKE" ]; then
    lanes_listing "$LIKE"
    return
  fi
  OTHERS=$(awk -v id="$ID" '$2 != id && $2 != "hub" {print $2}' <<< "$ROWS" | sort -u | jq -R . | jq -cs .)
  [ "$OTHERS" != "[]" ] || return 0
  jq -r --argjson o "$OTHERS" 'select(((.boxes // []) as $b | $o - $b) == []) | input_filename' "$LD"/*.json \
    | while read -r F; do basename "$F" .json; done
}
# lanes_listing <box-id>: the lane ids whose .boxes name that box (one jq pass).
lanes_listing() {
  jq -r --arg b "$1" 'select((.boxes // []) | index($b)) | input_filename' "$LD"/*.json \
    | while read -r F; do basename "$F" .json; done
}

# The register step's lane set is decided BEFORE anything is written.
SET=""
if [ "$RETIRE" = 0 ] && [ "$TRAP" = 0 ] && { [ -n "$LIKE" ] || ! lanes_edit "$LD/watchdog-ping.json" has "$ID"; }; then
  SET=$(lane_set | grep -vx trap-eval)
  [ -n "$SET" ] || refuse "no lane set for $ID: no other watcher box to derive it from. Use --like <box-id>."
  # watchdog-ping goes LAST: it is the marker that the lane step finished.
  SET=$( { printf '%s\n' "$SET" | grep -vx watchdog-ping; printf '%s\n' "$SET" | grep -x watchdog-ping; } )
fi

if [ "$TRAP" = 1 ]; then
  # ---------- the trap-eval step alone ----------
  if [ "$RETIRE" = 1 ]; then
    lanes_edit "$ROOT/$TE" remove "$ID"; RC=$?
  else
    if [ -n "$LIKE" ]; then
      lanes_edit "$ROOT/$TE" has "$LIKE"; INSET=$?
    else
      # Captured first: under pipefail, `lane_set | grep -q` can fail on SIGPIPE.
      LSET=$(lane_set); grep -qx trap-eval <<< "$LSET"; INSET=$?
    fi
    if [ "$INSET" != 0 ]; then
      same L4 "$TE" "trap-eval is not in box $ID's lane set"; RC=9
    else
      lanes_edit "$ROOT/$TE" add "$ID"; RC=$?
    fi
  fi
  case "$RC" in
    0) did L4 "$TE" "$([ "$RETIRE" = 1 ] && echo remove || echo add) $ID" ;;
    3) same L4 "$TE" "$([ "$RETIRE" = 1 ] && echo "does not list $ID" || echo "lists $ID")" ;;
    9) ;;
    *) fail L4 "$TE" "the edit would change more than .boxes" ;;
  esac
elif [ "$RETIRE" = 0 ]; then
  # ---------- register ----------
  # L1: the project row. Cols 1-5 stay byte for byte; col 6/7 become host + ip.
  ROWNOW=$(awk -v p="$PROJECT" '!/^[[:space:]]*(#|$)/ && $1 == p {print $6, $7; exit}' "$FLEET_CONF")
  FROM_ID=$(awk -v p="$PROJECT" '$1 == p {print $2; exit}' <<< "$ROWS")
  if [ "$ROWNOW" = "$HOST $IP" ]; then
    same L1 fleet.conf "project $PROJECT is on $HOST $IP"
  else
    if [ "$APPLY" = 1 ]; then
      python3 -I - "$FLEET_CONF" "$PROJECT" "$HOST" "$IP" <<'PY' || fail L1 fleet.conf "could not rewrite the $PROJECT row"
import os, re, sys
path, proj, host, ip = sys.argv[1:5]
lines = open(path, encoding="utf-8").read().split("\n")
for i, l in enumerate(lines):
    if re.match(r"\s*(#|$)", l) or l.split()[0] != proj:
        continue
    m = re.match(r"(\s*(?:\S+\s+){4}\S+)(\s*)", l)
    if not m:
        sys.exit(1)
    lines[i] = m.group(1) + (m.group(2) or " ") + host + " " + ip
    break
else:
    sys.exit(1)
open(path + ".tmp", "w", encoding="utf-8").write("\n".join(lines))
os.replace(path + ".tmp", path)
PY
      [ "$("$BIN/fleet-conf.sh" "$PROJECT" box) $("$BIN/fleet-conf.sh" "$PROJECT" tailnet_ip)" = "$HOST $IP" ] \
        || fail L1 fleet.conf "re-read of the $PROJECT row does not say $HOST $IP"
    fi
    did L1 fleet.conf "project $PROJECT -> $HOST $IP (was: ${ROWNOW:-none})"
  fi

  # L2/L3: the fragment dir, made in a temp dir and moved in whole.
  if [ -d "$ROOT/cron/boxes/$ID.d" ]; then
    same L2 "cron/boxes/$ID.d" "exists"
  else
    if [ "$APPLY" = 1 ]; then
      TMPD=$(mktemp -d "$ROOT/cron/boxes/.$ID.XXXXXX") || fail L2 "cron/boxes/$ID.d" "cannot make a temp dir"
      if [ -n "$LIKE" ]; then
        cp -p "$ROOT/cron/boxes/$LIKE.d"/* "$TMPD/"
      else
        cp -p "$ROOT/cron/boxes/hub.d/000-path.cron" "$TMPD/000-path.cron" \
          && printf '# @fleet-managed\n' > "$TMPD/001-fleet-managed.cron"
      fi && chmod 755 "$TMPD" && mv "$TMPD" "$ROOT/cron/boxes/$ID.d" || fail L2 "cron/boxes/$ID.d" "could not write the fragments"
    fi
    did L2 "cron/boxes/$ID.d" "create (${LIKE:+copy of $LIKE.d}${LIKE:-000-path.cron + 001-fleet-managed.cron})"
  fi
  if [ -n "$LIKE" ] && [ -f "$ROOT/cron/boxes/$LIKE.order" ]; then
    if cmp -s "$ROOT/cron/boxes/$LIKE.order" "$ROOT/cron/boxes/$ID.order"; then
      same L3 "cron/boxes/$ID.order" "a copy of $LIKE.order"
    else
      [ "$APPLY" = 0 ] || cp "$ROOT/cron/boxes/$LIKE.order" "$ROOT/cron/boxes/$ID.order" || fail L3 "cron/boxes/$ID.order" "copy failed"
      did L3 "cron/boxes/$ID.order" "copy of $LIKE.order"
    fi
  fi

  # L4: lanes. A box watchdog-ping already lists keeps its own lane set unless
  # --like says otherwise, so a project move never adds lanes a box dropped on
  # purpose (project-6-os has no healthcheck).
  if [ -z "$SET" ]; then
    same L4 catalog/lanes.d "box $ID is registered; it keeps its lane set"
  else
    if [ -n "$LIKE" ] && grep -qx healthcheck <<< "$SET" \
       && [ "$("$BIN/fleet-conf.sh" "$PROJECT" prod 2>/dev/null)" = "-" ]; then
      echo "WARN: the $LIKE lane set has healthcheck, and project $PROJECT has no prod URL (fleet.conf prod is -). The lane is kept; remove it by hand if you do not want it (9247f3c1b dropped it for project-6-os)."
    fi
    for L in $SET; do
      lanes_edit "$LD/$L.json" add "$ID"
      case $? in
        0) did L4 "catalog/lanes.d/$L.json" "add $ID" ;;
        3) same L4 "catalog/lanes.d/$L.json" "lists $ID" ;;
        *) fail L4 "catalog/lanes.d/$L.json" "the edit would change more than .boxes" ;;
      esac
    done
  fi

  # L5/L6/L7: jq (both files are jq .-stable).
  if jq -e --arg h "$HOST" --arg id "$ID" '.box_aliases[$h] == $id' "$CA" >/dev/null; then
    same L5 catalog/cost-accounts.json "box_aliases[$HOST] = $ID"
  else
    [ "$APPLY" = 0 ] || atomic_jq "$CA" --arg h "$HOST" --arg id "$ID" '.box_aliases[$h] = $id' || fail L5 catalog/cost-accounts.json "jq failed"
    did L5 catalog/cost-accounts.json "box_aliases[$HOST] = $ID"
  fi
  if jq -e --arg a "$ACCOUNT" --arg id "$ID" '.accounts[$a].boxes.cost_rows | index($id)' "$CA" >/dev/null; then
    same L6 catalog/cost-accounts.json "account $ACCOUNT cost_rows has $ID"
  else
    [ "$APPLY" = 0 ] || atomic_jq "$CA" --arg a "$ACCOUNT" --arg id "$ID" '.accounts[$a].boxes.cost_rows += [$id]' || fail L6 catalog/cost-accounts.json "jq failed"
    did L6 catalog/cost-accounts.json "account $ACCOUNT cost_rows += $ID"
  fi
  if jq -e --arg a "$ACCOUNT" --arg h "$HOST" '.accounts[$a].boxes.jobs | index($h)' "$CA" >/dev/null; then
    same L6 catalog/cost-accounts.json "account $ACCOUNT jobs has $HOST"
  else
    [ "$APPLY" = 0 ] || atomic_jq "$CA" --arg a "$ACCOUNT" --arg h "$HOST" \
      '.accounts[$a].boxes.jobs |= ((map(contains("*")) | index(true)) as $i | if $i then .[:$i] + [$h] + .[$i:] else . + [$h] end)' \
      || fail L6 catalog/cost-accounts.json "jq failed"
    did L6 catalog/cost-accounts.json "account $ACCOUNT jobs += $HOST"
  fi
  if jq -e --arg h "$HOST" 'index($h)' "$WD" >/dev/null; then
    same L7 worker/watchdog/src/boxes.json "has $HOST"
  else
    [ "$APPLY" = 0 ] || atomic_jq "$WD" --arg h "$HOST" '. + [$h]' || fail L7 worker/watchdog/src/boxes.json "jq failed"
    did L7 worker/watchdog/src/boxes.json "add $HOST"
  fi

  # L8: the mirror's redaction table. The public mirror ships no bin/share/.
  if [ ! -e "$MAP" ]; then
    echo "NOTE L8 bin/share/mapping.py skipped: no redaction table in this tree"
  elif tailnet_edit has "$IP"; then
    same L8 bin/share/mapping.py "TAILNET_IPS maps $IP"
  else
    PH=$(tailnet_edit add "$IP"); RC=$?
    [ "$RC" = 0 ] && did L8 bin/share/mapping.py "TAILNET_IPS += $IP -> $PH" || fail L8 bin/share/mapping.py "the TAILNET_IPS edit was refused (rc $RC)"
  fi
else
  # ---------- retire ----------
  for D in "cron/boxes/$ID.d" "cron/boxes/$ID.order"; do
    [ -e "$ROOT/$D" ] || continue
    [ "$APPLY" = 0 ] || rm -rf -- "${ROOT:?}/$D" || fail L2 "$D" "remove failed"
    did "$([ "${D%.order}" = "$D" ] && echo L2 || echo L3)" "$D" remove
  done
  for L in $(lanes_listing "$ID" | grep -vx trap-eval); do
    lanes_edit "$LD/$L.json" remove "$ID"
    case $? in
      0) did L4 "catalog/lanes.d/$L.json" "remove $ID" ;;
      3) ;;
      *) fail L4 "catalog/lanes.d/$L.json" "the edit would change more than .boxes" ;;
    esac
  done
  if jq -e --arg id "$ID" '[.box_aliases[] | select(. == $id)] | length > 0' "$CA" >/dev/null; then
    [ "$APPLY" = 0 ] || atomic_jq "$CA" --arg id "$ID" '.box_aliases |= with_entries(select(.value != $id))' || fail L5 catalog/cost-accounts.json "jq failed"
    did L5 catalog/cost-accounts.json "box_aliases -= $ID"
  fi
  if jq -e --arg id "$ID" --arg h "$HOST" '[.accounts[].boxes | (.cost_rows[]?, .jobs[]?) | select(. == $id or . == $h)] | length > 0' "$CA" >/dev/null; then
    [ "$APPLY" = 0 ] || atomic_jq "$CA" --arg id "$ID" --arg h "$HOST" \
      '.accounts[].boxes |= (.cost_rows |= map(select(. != $id)) | .jobs |= map(select(. != $h)))' || fail L6 catalog/cost-accounts.json "jq failed"
    did L6 catalog/cost-accounts.json "cost_rows -= $ID, jobs -= $HOST"
  fi
  if jq -e --arg h "$HOST" 'index($h)' "$WD" >/dev/null; then
    [ "$APPLY" = 0 ] || atomic_jq "$WD" --arg h "$HOST" 'map(select(. != $h))' || fail L7 worker/watchdog/src/boxes.json "jq failed"
    did L7 worker/watchdog/src/boxes.json "remove $HOST"
  fi
  if [ -n "$IP" ] && [ ! -e "$MAP" ]; then
    echo "NOTE L8 bin/share/mapping.py skipped: no redaction table in this tree"
  elif [ -n "$IP" ] && tailnet_edit has "$IP"; then
    REFS=""
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      REFS=$(git -C "$ROOT" grep -lF -- "$IP" 2>/dev/null | grep -vx 'bin/share/mapping.py')
    fi
    if [ -n "$REFS" ]; then
      echo "KEPT L8 bin/share/mapping.py $IP stays in TAILNET_IPS: tracked files still name it: $(echo $REFS)"
    else
      tailnet_edit remove "$IP"; RC=$?
      [ "$RC" = 0 ] && did L8 bin/share/mapping.py "TAILNET_IPS -= $IP" || fail L8 bin/share/mapping.py "the TAILNET_IPS edit was refused (rc $RC)"
    fi
  fi
fi

TOUCHED=$(printf '%s\n' $TOUCHED | sort -u | tr '\n' ' ')
if [ "$APPLY" = 0 ]; then
  echo "DRY RUN: nothing written. Re-run with --apply."
  exit 0
fi
[ "$FAILED" = 0 ] || { echo "box-register: an apply step failed. Nothing is rolled back: read 'git -C $ROOT status' and the FAILED lines." >&2; exit 1; }

# ---------- post-check ----------
# A LEAVING box has no fleet.conf row now but is still in the lists: the retire
# target before its main step lands, or the box a project just moved off when
# that was its last project. Its EXTRA lines are the expected state until the
# retire lands. Every other finding fails the post-check.
LEAVING=""
[ "$RETIRE" = 0 ] || LEAVING="$ID"
if [ -n "${FROM_ID:-}" ] && [ "$FROM_ID" != "$ID" ] && [ "$FROM_ID" != hub ] \
   && ! grep -qxF -- "$FROM_ID" <<< "$("$BIN/fleet-conf.sh" --box-ids)"; then
  LEAVING="$FROM_ID"
fi
CHK=$("$BIN/box-lists-check.sh" --root "$ROOT" 2>&1); CRC=$?
if [ "$CRC" != 0 ]; then
  LH=$(jq -r --arg id "$LEAVING" '.box_aliases | to_entries[] | select(.value == $id) | .key' "$CA" 2>/dev/null)
  REST=$(printf '%s\n' "$CHK" | grep -E '^(MISSING|EXTRA|BAD) ' \
         | awk -v id="${LEAVING:-.}" -v h="${LH:-.}" '!($1 == "EXTRA" && NF == 3 && ($3 == id || $3 == h))')
  if [ "$CRC" = 1 ] && [ -n "$LEAVING" ] && [ -z "$REST" ]; then
    printf '%s\n' "$CHK" | grep '^EXTRA ' | sed 's/^/NOTE: expected until box '"$LEAVING"' is retired: /'
    [ "$RETIRE" = 1 ] || echo "NEXT: box $LEAVING has no project now. Retire it: bin/box-register.sh --retire $LEAVING --trap-eval --apply, merge, then bin/box-register.sh --retire $LEAVING --apply"
  else
    printf '%s\n' "$CHK"
    echo "box-register: the post-check found the box lists out of parity (above)." >&2; exit 1
  fi
else
  printf '%s\n' "$CHK"
fi
if [ "$RETIRE" = 0 ] && [ "$TRAP" = 0 ] && ! "$BIN/render-cron.sh" --root "$ROOT" "$ID" >/dev/null; then
  echo "box-register: bin/render-cron.sh $ID does not render." >&2; exit 1
fi
if [ "$TRAP" = 0 ] && [ "$RETIRE" = 0 ]; then
  echo "NEXT: commit this change set alone and open its PR. After it merges, on a fresh branch from origin/main: $TRAP_CMD (BH-1965)"
  echo "NEXT: on box $ID, after the merge: bin/render-crontab.sh $ID | crontab -"
fi
[ -z "${TOUCHED// /}" ] || echo "NEXT: git add -A -- $TOUCHED"
exit 0
