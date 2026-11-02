#!/bin/bash
# bin/lib/box-ops-orgo.sh — the Orgo verbs of bin/box-ops.sh. Sourced, never
# run. Defines functions only. The operator's guide is docs/ADDING-A-BOX.md,
# "Box operations".
#
#   box-ops.sh restart <id> [--host <name>] [--account <a>] [--apply]
#   box-ops.sh resize  <id> --account <a> [--vcpus N] [--mem-gb N] [--disk-gb N]
#                      [--apply --confirm-monthly-usd <n>]
#   box-ops.sh stop    <id> [--host <name>] [--account <a>] [--apply]
#   box-ops.sh retire  <id> [--host <name>] [--to <box-id>] [--ip <old-ip>] [--root <dir>] [--apply] [--delete]
#
# DRY RUN IS THE DEFAULT. Without --apply a verb prints one `PLAN ...` line per
# step and changes nothing (it may GET from Orgo to read the computer).
#
#   restart  POST /computers/<oid>/restart, then GET until .status is running.
#   stop     flag_set paused-<p> on for each project on the box (the
#            pause_flags row, then the file). A row that does not land stops the
#            verb before the POST. Then POST /computers/<oid>/stop (skipped when
#            the computer already reports stopped) and GET until stopped. It
#            never lifts a pause.
#   resize   GET the specs; the target is the flags given, the rest unchanged.
#            Checks the catalog limits, prices the change from
#            catalog/orgo-plans.json and, when a dimension grows, the account
#            pool (short: `NEEDS PURCHASE`, exit 3). A change that costs money
#            needs --confirm-monthly-usd equal to the added $/mo (else a `COST:`
#            line, exit 2). Then ssh root@<ip> quiesce-for-resize.sh (its last
#            line must be SAFE_TO_RESIZE), PATCH /computers/<oid>/resize with
#            the changed keys, check every key in the answer's `results` array,
#            and GET the specs again: they must equal the target.
#   retire   With a project still on the box and no --to: refused. --to moves
#            each project (bin/box-register.sh <to> --ip <to-ip> --project <p>),
#            then bin/box-register.sh --retire <id>. Both write the working
#            tree only. --delete --apply deletes the Orgo computer only after
#            origin/main no longer names the box (else `WAITING`, exit 4).
#
# The box id must match ^[a-z][a-z0-9]*$; hub and the box that runs the command
# are refused. Host: --host <name> when given (restart, stop, retire), else the
# fleet.conf name, then catalog/cost-accounts.json .box_aliases, then
# state/box-ops/<id>.json, then HARNESS_BOX_PREFIX<id>.
# Orgo id: state/box-launch/<id>.json, state/box-ops/<id>.json, then the one
# computer on GET /computers with that name (0 or 2+ matches are refused).
# With --host, a state file whose .host names another box is skipped.
#
# --host is for a box id that two boxes share: bin/box-move.sh keeps the old
# box id on the new box (BH-8322), so the id alone names the new box. The id is
# SHARED when bin/fleet-conf.sh --boxes-with-roles has a box other than --host
# with that id and a role other than retired. retire --host without --delete
# on a shared id is refused (box-register --retire <id> would strip the other
# box's lists). retire --host --delete --apply on an id shared on origin/main
# skips only the cron/boxes/<id>.d check (that list is the other box's); the
# check that origin/main fleet.conf no longer names --host stays.
# Key: the --account catalog key_env, else ORGO_API_KEY. The name of an unset
# key is printed, never a value. Timeouts: BOX_LAUNCH_CALL_TIMEOUT_S,
# BOX_LAUNCH_POLL_S, BOX_LAUNCH_DEADLINE_S. Dedupe lock (--apply only):
# locks/box-ops-orgo-<id>.lock, flock -n, held = exit 0.
#
# The last stdout line is always (except on a held lock, which prints only
# `box-ops: <id> already running`)
#   box-ops: verb=<v> box=<id> orgo=<oid|-> result=<OK|FAIL|PLAN|WAITING|REFUSED> <detail>
# EXIT (the bin/box-launch.sh contract): 0 done or planned; 1 a step failed;
# 2 usage, refusal, not configured or COST; 3 NEEDS PURCHASE; 4 WAITING.
#
# UNPROVEN: POST /computers/<id>/stop, PATCH /computers/<id>/resize, DELETE
# /computers/<id> and the shape of the resize `results` array have not been
# called from this repo. tests/box-ops-orgo.bh-5749-test.sh stubs them.

# box_ops_orgo <verb> <id> [flags] — runs in a subshell, so a verb's exit is
# its return code.
box_ops_orgo() (
  set -uo pipefail
  H="${HARNESS:-${H:-}}"
  VERB="${1:-}"; shift
  ID=""; ACCOUNT=""; VCPUS=""; MEMGB=""; DISKGB=""; APPLY=0; CONFIRM=""; TO=""; OLDIP=""; DELETE=0; ROOT=""
  HOSTARG=""; HOSTSET=0; SHARED=""
  OID=""; KEYENV=ORGO_API_KEY; TOHOST=""; TOIP=""
  LIBD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BIN="$(cd "$LIBD/.." && pwd)"

  summary() { echo "box-ops: verb=$VERB box=${ID:--} orgo=${OID:--} result=$1${2:+ $2}"; }
  finish() {  # finish <rc> <result> [detail]
    summary "$2" "${3:-}"
    if [ "$APPLY" = 1 ] && [ -n "$H" ]; then
      mkdir -p "$H/logs" 2>/dev/null \
        && printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$(summary "$2" "${3:-}")" >> "$H/logs/box-ops-orgo.log"
    fi
    exit "$1"
  }
  refuse() { echo "box-ops: $*" >&2; finish 2 REFUSED "$*"; }
  fail()   { echo "box-ops: $*" >&2; finish 1 FAIL "$*"; }
  usage()  { echo "usage: box-ops.sh restart|stop <id> [--host <name>] [--account <a>] [--apply]" >&2
             echo "       box-ops.sh resize <id> --account <a> [--vcpus N] [--mem-gb N] [--disk-gb N] [--apply --confirm-monthly-usd <n>]" >&2
             echo "       box-ops.sh retire <id> [--host <name>] [--to <box-id>] [--ip <old-ip>] [--root <dir>] [--apply] [--delete]" >&2
             finish 2 REFUSED "usage"; }

  [ -n "$H" ] || { echo "box-ops: no harness root (HARNESS unset)" >&2; exit 1; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --account) ACCOUNT="${2-}"; shift 2 || usage ;;
      --vcpus)   [ "$VERB" = resize ] || usage; VCPUS="${2-}"; shift 2 || usage ;;
      --mem-gb)  [ "$VERB" = resize ] || usage; MEMGB="${2-}"; shift 2 || usage ;;
      --disk-gb) [ "$VERB" = resize ] || usage; DISKGB="${2-}"; shift 2 || usage ;;
      --confirm-monthly-usd) [ "$VERB" = resize ] || usage; CONFIRM="${2-}"; shift 2 || usage ;;
      --to)      [ "$VERB" = retire ] || usage; TO="${2-}"; shift 2 || usage ;;
      --ip)      [ "$VERB" = retire ] || usage; OLDIP="${2-}"; shift 2 || usage ;;
      --root)    ROOT="${2-}"; shift 2 || usage ;;
      --delete)  [ "$VERB" = retire ] || usage; DELETE=1; shift ;;
      --host)    case "$VERB" in restart|stop|retire) ;; *) usage ;; esac
                 [ $# -ge 2 ] || usage; HOSTARG="$2"; HOSTSET=1; shift 2 ;;
      --apply)   APPLY=1; shift ;;
      -*) echo "box-ops: unknown flag $1" >&2; usage ;;
      *) [ -z "$ID" ] || usage; ID="$1"; shift ;;
    esac
  done
  [ -n "$ID" ] || usage
  [[ "$ID" =~ ^[a-z][a-z0-9]*$ ]] || refuse "box id '$ID' must match ^[a-z][a-z0-9]*\$"
  [ "$ID" != hub ] || refuse "hub is not operated by box-ops verbs"
  [ "$VERB" != resize ] || [ -n "$ACCOUNT" ] || refuse "resize needs --account (prices are per account)"
  [ "$HOSTSET" = 0 ] || { [[ "$HOSTARG" != *$'\n'* ]] && [[ "$HOSTARG" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; } \
    || refuse "--host '$HOSTARG' must match ^[a-z0-9][a-z0-9-]{0,62}\$"
  if [ -n "$ROOT" ]; then ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || refuse "--root is not a directory"
  else ROOT=$(cd "$BIN/.." && pwd); fi
  export FLEET_CONF="$ROOT/fleet.conf"
  [ -f "$FLEET_CONF" ] || refuse "no $FLEET_CONF"

  # shellcheck source=bin/lib/env-path.sh
  . "$LIBD/env-path.sh" || exit 1
  set -a
  # shellcheck disable=SC1091
  . "$(harness_env_dir "$H")/global.env" 2>/dev/null
  set +a
  # shellcheck source=bin/lib/deployment.sh
  . "$LIBD/deployment.sh" || exit 1
  # shellcheck source=bin/lib/cron-lines.sh
  . "$LIBD/cron-lines.sh" || exit 1
  # shellcheck source=bin/lib/restore-drill-orgo.sh
  . "$LIBD/restore-drill-orgo.sh" || exit 1
  export RESTORE_DRILL_CALL_TIMEOUT_S="${BOX_LAUNCH_CALL_TIMEOUT_S:-300}"

  SELF=$("$BIN/box-name.sh" 2>/dev/null | tr -dc 'A-Za-z0-9._-')
  [ -n "$SELF" ] && [ "$(cron_box_id_for "$SELF")" = "$ID" ] && refuse "box $ID runs this command; operate it from another box"
  POLL=${BOX_LAUNCH_POLL_S:-15}; DEADLINE=${BOX_LAUNCH_DEADLINE_S:-900}
  [[ "$POLL" =~ ^[1-9][0-9]*$ ]]     || refuse "BOX_LAUNCH_POLL_S '$POLL' is not a positive integer"
  [[ "$DEADLINE" =~ ^[1-9][0-9]*$ ]] || refuse "BOX_LAUNCH_DEADLINE_S '$DEADLINE' is not a positive integer"
  [[ "$RESTORE_DRILL_CALL_TIMEOUT_S" =~ ^[1-9][0-9]*$ ]] \
    || refuse "BOX_LAUNCH_CALL_TIMEOUT_S '$RESTORE_DRILL_CALL_TIMEOUT_S' is not a positive integer"

  # ---------- catalog entry and key ----------
  A=""
  if [ -n "$ACCOUNT" ]; then
    A=$(jq -ce --arg a "$ACCOUNT" '.accounts[$a] // empty' "$ROOT/catalog/orgo-plans.json" 2>/dev/null) \
      || refuse "account '$ACCOUNT' is not a key of catalog/orgo-plans.json .accounts"
    KEYENV=$(jq -r '.key_env // "ORGO_API_KEY"' <<< "$A")
    [[ "$KEYENV" =~ ^[A-Z_][A-Z0-9_]*$ ]] || refuse "key_env '$KEYENV' is not an env var name"
  fi
  cj() { jq -r "$1 | if . == null then \"\" else tostring end" <<< "$A"; }
  ORGO_API_KEY="${!KEYENV:-}"  # the orgo() seam reads ORGO_API_KEY

  # ---------- resize targets: validated before any network call ----------
  if [ "$VERB" = resize ]; then
    [ -n "$VCPUS$MEMGB$DISKGB" ] || refuse "resize needs --vcpus, --mem-gb or --disk-gb"
    for v in ${VCPUS:+"vcpus:$VCPUS"} ${MEMGB:+"mem-gb:$MEMGB"} ${DISKGB:+"disk-gb:$DISKGB"}; do
      [[ "${v#*:}" =~ ^[1-9][0-9]*$ ]] || refuse "--${v%%:*} '${v#*:}' is not a positive integer"
    done
    if [ -n "$VCPUS" ]; then
      MAXV=$(cj .limits.max_vcpus_per_computer)
      [[ "$MAXV" =~ ^[0-9]+$ ]] || refuse "limits.max_vcpus_per_computer not recorded in catalog/orgo-plans.json"
      [ "$VCPUS" -le "$MAXV" ] || refuse "--vcpus $VCPUS is over the plan cap of $MAXV per computer"
    fi
    if [ -n "$MEMGB" ]; then
      jq -e --argjson m "$MEMGB" '.limits.ram_tiers_gb | index($m) != null' <<< "$A" >/dev/null 2>&1 \
        || refuse "--mem-gb $MEMGB is not a RAM tier ($(jq -c .limits.ram_tiers_gb <<< "$A"))"
    fi
    [ -n "$CONFIRM" ] && ! [[ "$CONFIRM" =~ ^[0-9]+(\.[0-9]+)?$ ]] && refuse "--confirm-monthly-usd '$CONFIRM' is not a number"
  fi

  # ---------- host, projects, retire target ----------
  BOXST="$H/state/box-ops/$ID.json"
  if [ "$HOSTSET" = 1 ]; then
    HOST="$HOSTARG"
    SHARED=$(shared_box)
  else
    HOST=$(cron_watchdog_name_for "$ID" 2>/dev/null) \
      || HOST=$(jq -r --arg id "$ID" '[.box_aliases | to_entries[] | select(.value == $id) | .key][0] // empty' "$ROOT/catalog/cost-accounts.json" 2>/dev/null)
    [ -n "$HOST" ] || HOST=$(jq -r '.host // empty' "$BOXST" 2>/dev/null)
    [ -n "$HOST" ] || HOST="${HARNESS_BOX_PREFIX}${ID}"
  fi
  PROJECTS=$("$BIN/fleet-conf.sh" --projects-on-box "$HOST" | tr '\n' ' '); PROJECTS="${PROJECTS% }"
  if [ "$VERB" = retire ] && [ -n "$TO" ]; then
    [[ "$TO" =~ ^[a-z][a-z0-9]*$ ]] && [ "$TO" != hub ] || refuse "--to '$TO' must match ^[a-z][a-z0-9]*\$ and must not be hub"
    [ "$TO" != "$ID" ] || refuse "--to $TO is the box being retired"
    TOHOST=$(cron_watchdog_name_for "$TO" 2>/dev/null) \
      || TOHOST=$(jq -r --arg id "$TO" '[.box_aliases | to_entries[] | select(.value == $id) | .key][0] // empty' "$ROOT/catalog/cost-accounts.json" 2>/dev/null)
    [ -n "$TOHOST" ] || TOHOST="${HARNESS_BOX_PREFIX}${TO}"
    TOIP=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$TOHOST" 2>/dev/null) \
      || refuse "fleet.conf has no tailnet address for $TOHOST (box $TO)"
  fi

  # Which verbs call Orgo on --apply: a missing key is refused before any call.
  NEEDKEY=1
  [ "$VERB" = retire ] && [ "$DELETE" = 0 ] && NEEDKEY=0
  if [ "$APPLY" = 1 ]; then
    [ "$NEEDKEY" = 0 ] || [ -n "$ORGO_API_KEY" ] || refuse "not configured: $KEYENV unset"
    mkdir -p "$H/locks" || exit 1
    exec 8>"$H/locks/box-ops-orgo-$ID.lock"
    flock -n 8 || { echo "box-ops: $ID already running"; exit 0; }
  fi

  # ---------- Orgo id ----------
  IDRE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  resolve_oid() {  # sets OID; no key in a dry run leaves it empty
    local f m
    for f in "$H/state/box-launch/$ID.json" "$BOXST"; do
      if [ "$HOSTSET" = 1 ]; then
        m=$(jq -r '.host // empty' "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" != "$HOST" ]; then
          echo "box-ops: note: $f names host $m, not $HOST; skipped"
          continue
        fi
      fi
      OID=$(jq -r '.orgo_id // empty | tostring' "$f" 2>/dev/null)
      [ -n "$OID" ] && break
    done
    if [ -z "$OID" ]; then
      [ -n "$ORGO_API_KEY" ] || return 0
      orgo GET /computers || fail "GET /computers HTTP $ORGO_HTTP"
      m=$(printf '%s' "$ORGO_BODY" | jq -ce --arg h "$HOST" '
        (if type == "array" then . elif (.computers | type) == "array" then .computers else error("shape") end)
        | [.[] | select(.name == $h) | .id | tostring]' 2>/dev/null) || fail "unreadable computer list from GET /computers"
      [ "$(jq length <<< "$m")" = 1 ] || refuse "$(jq length <<< "$m") Orgo computers named $HOST; want exactly 1 (record orgo_id in $BOXST)"
      OID=$(jq -r '.[0]' <<< "$m")
    fi
    [[ "$OID" =~ $IDRE ]] || fail "Orgo id '$OID' for $HOST is not usable"
  }
  P_OID() { printf '%s' "${OID:-<orgo-id>}"; }
  # status_wait <want>: GET /computers/<oid> until .status is <want>, or fail.
  status_wait() {
    local s start; start=$(date +%s)
    while :; do
      s=""
      orgo GET "/computers/$OID" && s=$(printf '%s' "$ORGO_BODY" | jq -r '.status // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
      [ "$s" = "$1" ] && return 0
      [ $(( $(date +%s) - start )) -ge "$DEADLINE" ] && fail "computer $OID not $1 after ${DEADLINE}s (last status '${s:-HTTP $ORGO_HTTP}')"
      sleep "$POLL"
    done
  }
  orgo_status() { orgo GET "/computers/$OID" && printf '%s' "$ORGO_BODY" | jq -r '.status // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

  case "$VERB" in
    restart) verb_restart ;;
    stop)    verb_stop ;;
    resize)  verb_resize ;;
    retire)  verb_retire ;;
  esac
)

# ---------- the verbs: called inside box_ops_orgo's subshell ----------

verb_restart() {
  resolve_oid
  if [ "$APPLY" = 0 ]; then
    echo "PLAN restart POST /computers/$(P_OID)/restart"
    echo "PLAN wait for status running (deadline ${DEADLINE}s)"
    finish 0 PLAN "dry run"
  fi
  orgo POST "/computers/$OID/restart" || fail "restart HTTP $ORGO_HTTP"
  status_wait running
  finish 0 OK "running"
}

verb_stop() {
  local p
  resolve_oid
  if [ "$APPLY" = 0 ]; then
    [ -n "$PROJECTS" ] || echo "stop: no project on $ID"
    for p in $PROJECTS; do echo "PLAN pause paused-$p"; done
    echo "PLAN stop POST /computers/$(P_OID)/stop"
    finish 0 PLAN "dry run"
  fi
  if [ -n "$PROJECTS" ]; then
    # shellcheck source=bin/jobs-client.sh
    . "$BIN/jobs-client.sh" || exit 1
    for p in $PROJECTS; do
      flag_set "paused-$p" on "box-ops stop $ID" || fail "pause flag paused-$p not published; box not stopped"
      echo "stop: paused-$p on"
    done
  else
    echo "stop: no project on $ID"
  fi
  if [ "$(orgo_status)" = stopped ]; then
    echo "stop: $OID already stopped"
  else
    orgo POST "/computers/$OID/stop" || fail "stop HTTP $ORGO_HTTP"
    status_wait stopped
  fi
  for p in $PROJECTS; do echo "NEXT: lift with bin/jobs-client.sh flag-set paused-$p off"; done
  finish 0 OK "stopped"
}

verb_resize() {
  local cur tgt body delta oldusd newusd short ip out rc last res k p got
  resolve_oid
  if [ -z "$OID" ]; then
    echo "PLAN resize not read ($KEYENV unset): drain, PATCH /computers/<orgo-id>/resize, verify"
    finish 0 PLAN "dry run, specs not read"
  fi
  orgo GET "/computers/$OID" || fail "GET /computers/$OID HTTP $ORGO_HTTP"
  cur=$(printf '%s' "$ORGO_BODY" | jq -ce --arg d "${DISKGB:+1}" '
    if (.cpu|type) == "number" and (.ram|type) == "number" and ($d == "" or (.disk|type) == "number")
    then {cpu, ram, disk} else error("fields") end' 2>/dev/null) \
    || fail "GET /computers/$OID has no numeric cpu/ram${DISKGB:+/disk}"
  tgt=$(jq -c --arg v "$VCPUS" --arg m "$MEMGB" --arg d "$DISKGB" '
    {cpu: (if $v == "" then .cpu else ($v|tonumber) end),
     ram: (if $m == "" then .ram else ($m|tonumber) end),
     disk: (if $d == "" then .disk else ($d|tonumber) end)}' <<< "$cur")
  body=$(jq -nc --argjson c "$cur" --argjson t "$tgt" '[$t | to_entries[] | select($c[.key] != .value)] | from_entries')
  SPECS=$(jq -r '"\(.cpu)c/\(.ram)gb/\(.disk // "-")gb"' <<< "$tgt")
  if [ "$body" = "{}" ]; then echo "resize: $ID already $SPECS"; finish 0 OK "already $SPECS"; fi
  # Price of each changed dimension: a null price refuses, never zero.
  for k in $(jq -r 'keys[]' <<< "$body"); do
    case "$k" in cpu) p=vcpu ;; ram) p=ram_gb ;; disk) p=disk_gb ;; esac
    [ -n "$(cj ".prices_usd_mo.$p")" ] || refuse "price $p not recorded in catalog/orgo-plans.json"
  done
  delta=$(jq -nr --argjson c "$cur" --argjson t "$tgt" --argjson a "$A" --argjson b "$body" '
    [$b | keys[] | . as $k | ({cpu:"vcpu", ram:"ram_gb", disk:"disk_gb"}[$k]) as $p
     | (($t[$k] - $c[$k]) * $a.prices_usd_mo[$p])] | add')
  usd_of() { jq -nr --argjson s "$1" --argjson a "$A" '$a.prices_usd_mo as $p
    | if ($s.disk != null and $p.disk_gb == null) or $p.computer == null or $p.vcpu == null or $p.ram_gb == null then "n/a"
      else $p.computer + $s.cpu * $p.vcpu + $s.ram * $p.ram_gb + (if $s.disk == null then 0 else $s.disk * $p.disk_gb end) end'; }
  oldusd=$(usd_of "$cur"); newusd=$(usd_of "$tgt")
  echo "resize: $ID $(jq -r '"\(.cpu)c/\(.ram)gb/\(.disk // "-")gb"' <<< "$cur") -> $SPECS, delta \$$delta/mo"

  # Capacity: only a dimension that grows needs pool room.
  short=""
  if jq -en --argjson c "$cur" --argjson t "$tgt" 'any(["cpu","ram","disk"][]; ($t[.] // 0) > ($c[.] // 0))' >/dev/null; then
    local nopool
    nopool=$(jq -nr --argjson c "$cur" --argjson t "$tgt" --argjson a "$A" '
      [{cpu:"vcpus", ram:"ram_gb", disk:"disk_gb"} | to_entries[]
       | select(($t[.key] // 0) > ($c[.key] // 0)) | select($a.pool[.value] == null) | .value] | join(" ")')
    if [ -n "$nopool" ]; then
      [ "$APPLY" = 1 ] && refuse "not configured: pool $nopool not recorded in catalog/orgo-plans.json"
      echo "PLAN capacity not checked: pool $nopool not recorded in catalog/orgo-plans.json"
    else
      orgo GET /computers || fail "GET /computers HTTP $ORGO_HTTP"
      local list
      list=$(printf '%s' "$ORGO_BODY" | jq -ce 'if type == "array" then . elif (.computers | type) == "array" then .computers else error("shape") end' 2>/dev/null) \
        || fail "unreadable computer list from GET /computers"
      short=$(jq -nr --argjson l "$list" --argjson c "$cur" --argjson t "$tgt" --argjson a "$A" --arg o "$OID" '
        [["cpu","vcpus","vcpu","vcpu"],["ram","ram_gb","ram_gb","ram-gb"],["disk","disk_gb","disk_gb","disk-gb"]][]
        | . as [$k, $pk, $pr, $name]
        | select(($t[$k] // 0) > ($c[$k] // 0))
        | if all($l[]; (.[$k]|type) == "number") then . else error("fields") end
        | (([$l[] | select((.id|tostring) != $o) | .[$k]] | add // 0) + $t[$k] - $a.pool[$pk]) as $q
        | select($q > 0) | "NEEDS PURCHASE: \($name) \($q) $\($q * $a.prices_usd_mo[$pr])/mo"' 2>/dev/null) \
        || fail "unreadable computer list: an entry has no numeric value for a growing dimension"
      if [ -n "$short" ]; then printf '%s\n' "$short"; finish 3 REFUSED "needs purchase"; fi
      echo "capacity: the pool fits $SPECS"
    fi
  fi

  if [ "$APPLY" = 0 ]; then
    jq -en --argjson d "$delta" '$d > 0' >/dev/null && echo "PLAN cost +\$$delta/mo (now \$$oldusd/mo, after \$$newusd/mo); --apply needs --confirm-monthly-usd $delta"
    echo "PLAN drain ssh root@<tailnet-ip of $HOST> /root/harness/bin/quiesce-for-resize.sh (expects SAFE_TO_RESIZE)"
    echo "PLAN PATCH /computers/$OID/resize $body"
    echo "PLAN verify the results array names $(jq -r 'keys | join(",")' <<< "$body"), then GET /computers/$OID shows $SPECS"
    finish 0 PLAN "dry run"
  fi
  if jq -en --argjson d "$delta" '$d > 0' >/dev/null; then
    if [ -z "$CONFIRM" ] || ! jq -en --argjson a "$CONFIRM" --argjson b "$delta" '$a == $b' >/dev/null; then
      echo "COST: resize $ID +\$$delta/mo (now \$$oldusd/mo, after \$$newusd/mo) — re-run with --confirm-monthly-usd $delta"
      finish 2 REFUSED "cost not confirmed"
    fi
  fi

  # Drain on the box itself; no SAFE_TO_RESIZE = no PATCH.
  ip=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$HOST" 2>/dev/null) || refuse "fleet.conf has no tailnet address for $HOST"
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$ip" /root/harness/bin/quiesce-for-resize.sh </dev/null); rc=$?
  last=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)
  [ "$rc" = 0 ] && [[ "$last" == SAFE_TO_RESIZE* ]] || fail "drain failed: quiesce-for-resize.sh rc=$rc, last line '${last}'"
  echo "drain: $last"

  orgo PATCH "/computers/$OID/resize" "$body" || fail "resize HTTP $ORGO_HTTP"
  res=$(printf '%s' "$ORGO_BODY" | jq -ce '.results | if type == "array" then . else error("x") end' 2>/dev/null) \
    || fail "resize answered HTTP $ORGO_HTTP with no results array"
  for k in $(jq -r 'keys[]' <<< "$body"); do
    jq -e --arg k "$k" 'any(.[]; ((.key // .field // .name) == $k)
        and (.ok != false) and (.success != false) and ((.error // null) == null)
        and ((.status // "" | ascii_downcase) as $s | ($s != "failed" and $s != "ignored" and $s != "error")))' <<< "$res" >/dev/null 2>&1 \
      || fail "Orgo ignored resize key $k"
  done
  orgo GET "/computers/$OID" || fail "re-read GET /computers/$OID HTTP $ORGO_HTTP"
  got=$(printf '%s' "$ORGO_BODY" | jq -c '{cpu, ram, disk}' 2>/dev/null)
  [ "$got" = "$tgt" ] || fail "after resize GET /computers/$OID shows $got, want $tgt"
  echo "NEXT: watchers on $ID are paused by quiesce (flags/paused-* on the box); lift them when the box is back"
  finish 0 OK "$SPECS"
}

verb_retire() {
  local p rc onmain mainshared mainconf
  if [ -n "$SHARED" ] && [ "$DELETE" = 0 ]; then
    refuse "box id $ID also belongs to $SHARED; box-register --retire $ID would strip its lists; use --delete only"
  fi
  if [ -n "$PROJECTS" ] && [ -z "$TO" ] && [ "$DELETE" = 0 ]; then
    refuse "projects still point at box $ID: $PROJECTS; pass --to <box-id>"
  fi
  inlists() {
    awk -v h="$HOST" '!/^[[:space:]]*(#|$)/ && $6 == h {f=1} END {exit !f}' "$FLEET_CONF" || [ -d "$ROOT/cron/boxes/$ID.d" ]
  }
  if [ "$APPLY" = 0 ]; then
    if [ -n "$PROJECTS" ] && [ -z "$TO" ]; then
      echo "PLAN --apply refuses: projects still point at box $ID: $PROJECTS; pass --to <box-id>"
    fi
    for p in $PROJECTS; do
      [ -n "$TO" ] && echo "PLAN move bin/box-register.sh $TO --ip $TOIP --project $p --root $ROOT --apply"
    done
    if [ -n "$SHARED" ]; then
      echo "PLAN no box-register --retire: box id $ID also belongs to $SHARED"
    else
      echo "PLAN retire bin/box-register.sh --retire $ID${OLDIP:+ --ip $OLDIP} --root $ROOT --apply"
    fi
    [ "$DELETE" = 1 ] && echo "PLAN delete DELETE /computers/<orgo-id> after origin/main no longer names $HOST"
    finish 0 PLAN "dry run"
  fi

  if [ "$DELETE" = 0 ]; then
    # Step 1: remember the host and the Orgo id before the lists forget them.
    local soid=""
    soid=$(jq -r '.orgo_id // empty | tostring' "$H/state/box-launch/$ID.json" 2>/dev/null)
    [ -n "$soid" ] || soid=$(jq -r '.orgo_id // empty | tostring' "$BOXST" 2>/dev/null)
    box_state '.id = $i | .host = $h | .orgo_id = (if $o == "" then (.orgo_id // null) else $o end)' \
      --arg i "$ID" --arg h "$HOST" --arg o "$soid" || fail "cannot write $BOXST"
    OID=$soid
    # Step 2: move each project.
    for p in $PROJECTS; do
      "$BIN/box-register.sh" "$TO" --ip "$TOIP" --project "$p" --root "$ROOT" --apply; rc=$?
      [ "$rc" = 0 ] || fail "move $p to $TO: bin/box-register.sh rc=$rc"
    done
    # Step 3: out of every list, unless it already is.
    if inlists; then
      "$BIN/box-register.sh" --retire "$ID" ${OLDIP:+--ip "$OLDIP"} --root "$ROOT" --apply; rc=$?
      case "$rc" in
        0) ;;
        # Exit 3 is NEEDS PURCHASE in this contract, so box-register's rc 3
        # (the BH-1965 trap-eval order) is a refusal here, as its rc 2 is.
        2|3) echo "box-ops: bin/box-register.sh --retire $ID refused (rc $rc); the moves above stay in the working tree" >&2
             finish 2 REFUSED "box-register --retire rc=$rc" ;;
        *) fail "bin/box-register.sh --retire $ID rc=$rc" ;;
      esac
    else
      echo "retire: $ID is already in no list"
    fi
    echo "NEXT: commit, open the PR, merge, then re-run with --delete --apply"
    finish 0 OK "retired in the working tree"
  fi

  # --delete --apply: only after origin/main forgets the box.
  git -C "$ROOT" fetch -q origin main || fail "git fetch origin main failed"
  onmain=""
  git -C "$ROOT" show origin/main:fleet.conf 2>/dev/null \
    | awk -v h="$HOST" '!/^[[:space:]]*(#|$)/ && $6 == h {f=1} END {exit !f}' && onmain="fleet.conf names $HOST"
  mainshared=""
  if [ "$HOSTSET" = 1 ]; then
    mainconf=$(mktemp) || fail "mktemp failed"
    if git -C "$ROOT" show origin/main:fleet.conf > "$mainconf" 2>/dev/null; then
      mainshared=$(FLEET_CONF="$mainconf" shared_box)
    fi
    rm -f "$mainconf"
  fi
  if [ -n "$mainshared" ]; then
    echo "retire: box id $ID belongs to $mainshared on origin/main; cron/boxes/$ID.d is its list, not checked"
  else
    git -C "$ROOT" cat-file -e "origin/main:cron/boxes/$ID.d" 2>/dev/null && onmain="${onmain:+$onmain; }cron/boxes/$ID.d exists"
  fi
  if [ -n "$onmain" ]; then
    echo "WAITING: origin/main still has the box ($onmain); merge the retire PR, then re-run"
    finish 4 WAITING "$onmain"
  fi
  if [ -n "$(jq -r '.deleted_at // empty' "$BOXST" 2>/dev/null)" ]; then
    OID=$(jq -r '.orgo_id // empty | tostring' "$BOXST" 2>/dev/null)
    echo "retire: $ID already deleted"
    finish 0 OK "already deleted"
  fi
  resolve_oid
  box_state '.id = $i | .host = $h | .orgo_id = $o' --arg i "$ID" --arg h "$HOST" --arg o "$OID" || fail "cannot write $BOXST"
  orgo DELETE "/computers/$OID" || [ "$ORGO_HTTP" = 404 ] || fail "DELETE /computers/$OID HTTP $ORGO_HTTP"
  if ! orgo GET "/computers/$OID"; then
    [ "$ORGO_HTTP" = 404 ] || fail "GET /computers/$OID after DELETE answered HTTP $ORGO_HTTP; the computer may still exist"
  else
    orgo GET /computers || fail "GET /computers HTTP $ORGO_HTTP after DELETE"
    printf '%s' "$ORGO_BODY" | jq -e --arg o "$OID" '
      (if type == "array" then . elif (.computers | type) == "array" then .computers else error("shape") end)
      | all(.[]; (.id|tostring) != $o)' >/dev/null 2>&1 || fail "computer $OID is still on the Orgo account after DELETE"
  fi
  box_state '.deleted_at = $t' --arg t "$(date -u +%FT%TZ)" || fail "computer $OID deleted, but $BOXST was not stamped"
  finish 0 OK "deleted"
}

# shared_box — the first box other than $HOST that the rows (FLEET_CONF)
# give box id $ID with a role other than retired; empty when none. The
# origin/main read sets REGISTRY_SOURCE=file through its own FLEET_CONF.
shared_box() {
  local src="${REGISTRY_SOURCE:-}"
  [ "${FLEET_CONF:-}" = "$ROOT/fleet.conf" ] || src=file
  REGISTRY_SOURCE="$src" "$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null \
    | awk -F'\t' -v id="$ID" -v h="$HOST" '$2 == id && $1 != h && $3 != "retired" {print $1; exit}'
}

# box_state <jq filter> [jq args...] — update state/box-ops/<id>.json, tmp+mv.
box_state() {
  local f="$1"; shift
  mkdir -p "$(dirname "$BOXST")" || return 1
  if [ -f "$BOXST" ]; then jq "$@" "$f" "$BOXST"; else jq -n "$@" "{} | $f"; fi > "$BOXST.tmp.$$" \
    && mv "$BOXST.tmp.$$" "$BOXST"
}
