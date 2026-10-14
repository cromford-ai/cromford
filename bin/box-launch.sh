#!/bin/bash
# bin/box-launch.sh — make one Orgo box, put the harness on it, register it,
# bootstrap it, smoke it.
#
#   box-launch.sh <id> --project <p> --account <orgo-account>
#                 [--vcpus N --mem-gb N --disk-gb N] [--root <dir>]
#                 [--apply --confirm-monthly-usd <n>]
#
# DRY RUN IS THE DEFAULT. Without --apply it reads the Orgo computer list (GET
# only, and only when ORGO_API_KEY is set), prints one `PLAN <step> ...` line
# per step that is not done, prints the summary line and exits 0. It makes no
# POST, no remote command, no ssh and no file write.
#
# THE STEPS. Each step is stamped in the state file after its effect is
# verified. A re-run starts at the first step that is not stamped.
#   capacity   catalog/orgo-plans.json pool minus the sum of GET /computers.
#              Re-read on every run until the state has an Orgo id.
#              Short: one `NEEDS PURCHASE: <dim> <qty> $<n>/mo` line per short
#              dimension, exit 3, nothing created.
#   create     POST /computers {name:<host>, template_ref, ram, cpu[, disk]}.
#              A computer named <host> on the list is adopted, never re-bought.
#   running    GET /computers/<oid> until .status is running.
#   tailnet    Orgo bash: start sshd, cron, tailscaled; tailscale up; read the
#              100.64/10 address.
#   hubkey     Orgo bash: the hub public key into authorized_keys; then ssh.
#   harness    ssh: clone or pull /root/harness-checkout, sync /root/harness,
#              with a short-lived token the hub mints (bin/gh-token.sh) on stdin.
#   envfiles   scp global.env, <p>.env and the optional files; compare sha256
#              hub vs box. Prints `envfile <name> match|differ`, never a value
#              or a hash.
#   migrate    ssh: bin/migrate-env-dir.sh.
#   ghapp      ssh: bin/ensure-box-gh-app-default.sh <p> (rc 3 = done-warn).
#   register   <root>/bin/box-register.sh ... --apply. It writes the working
#              tree and never commits. Commit it, open its PR, merge it.
#   merged     the <p> row of origin/main:fleet.conf names <host> <ip>. Not yet:
#              `WAITING: ...`, exit 4.
#   bootstrap  ssh: harness-sync, state/box-id = <id>, bin/bootstrap-machine.sh <p>.
#   smoke      ssh: state/box-id, the fleet-managed crontab block, sshd,
#              tailscale status.
# The last stdout line is always the summary (not on exit 2):
#   box-launch: box=<id> orgo=<oid> ip=<ip> specs=<v>c/<m>gb/<d>gb usd_mo=<n> smoke=<PASS|FAIL|PENDING>
#
# SPEND GATE. The create step is the only spend. --apply needs
# --confirm-monthly-usd equal to the computed $/mo, unless the state already has
# an Orgo id. --apply also refuses (exit 2), before any network call, while
# ORGO_API_KEY, the catalog template_ref or pool, BOX_LAUNCH_TS_AUTHKEY or the
# hub public key is missing for a step that is not done.
#
# STATE: $HARNESS/state/box-launch/<id>.json, one file per box id, written
# tmp+mv. It is bound to --project, --account and the specs: a re-run with
# other values is refused (exit 2). Dedupe lock: locks/box-launch-<id>.lock
# (flock -n; held = exit 0).
#
# Knobs (env, env-templates/lanes/380-box-launch.env.example):
# BOX_LAUNCH_TS_AUTHKEY (secret), BOX_LAUNCH_HUB_PUBKEY, BOX_LAUNCH_ENV_FILES_OPTIONAL,
# BOX_LAUNCH_POLL_S, BOX_LAUNCH_DEADLINE_S, BOX_LAUNCH_CALL_TIMEOUT_S.
# The Orgo seam is bin/lib/restore-drill-orgo.sh (ORGO_API_KEY, ORGO_API_BASE).
# Docs: docs/ADDING-A-BOX.md, "Launching an Orgo box".
#
# EXIT: 0 done (or the dry run printed); 1 a step failed; 2 usage error,
# refusal or not configured; 3 NEEDS PURCHASE; 4 WAITING for the register merge.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"
ROOT="$HERE/.."
ID=""; PROJECT=""; ACCOUNT=""; VCPUS=""; MEMGB=""; DISKGB=""; APPLY=0; CONFIRM=""
usage() { echo "usage: box-launch.sh <id> --project <p> --account <a> [--vcpus N --mem-gb N --disk-gb N] [--root <dir>] [--apply --confirm-monthly-usd <n>]" >&2; exit 2; }
refuse() { echo "box-launch: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2-}"; shift 2 || usage ;;
    --account) ACCOUNT="${2-}"; shift 2 || usage ;;
    --vcpus)   VCPUS="${2-}"; shift 2 || usage ;;
    --mem-gb)  MEMGB="${2-}"; shift 2 || usage ;;
    --disk-gb) DISKGB="${2-}"; shift 2 || usage ;;
    --root)    ROOT="${2-}"; shift 2 || usage ;;
    --apply)   APPLY=1; shift ;;
    --confirm-monthly-usd) CONFIRM="${2-}"; shift 2 || usage ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    -*) usage ;;
    *) [ -z "$ID" ] || usage; ID="$1"; shift ;;
  esac
done
[ -n "$ID" ] && [ -n "$PROJECT" ] && [ -n "$ACCOUNT" ] || usage
[[ "$ID" =~ ^[a-z][a-z0-9]*$ ]] && [ "$ID" != hub ] \
  || refuse "box id '$ID' must match ^[a-z][a-z0-9]*\$ and must not be hub"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || refuse "--root is not a directory"

# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" || exit 1
HENV=$(harness_env_dir "$H")
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a
# shellcheck source=bin/lib/deployment.sh
. "$HERE/lib/deployment.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-orgo.sh
. "$HERE/lib/restore-drill-orgo.sh" || exit 1
export RESTORE_DRILL_CALL_TIMEOUT_S="${BOX_LAUNCH_CALL_TIMEOUT_S:-300}"

# ---------- inputs: fleet.conf row, catalog entry, specs, price ----------
awk -v p="$PROJECT" '!/^[[:space:]]*(#|$)/ && $1 == p {f=1} END {exit !f}' "$ROOT/fleet.conf" 2>/dev/null \
  || refuse "$ROOT/fleet.conf has no row for project '$PROJECT'"
CAT="$ROOT/catalog/orgo-plans.json"
A=$(jq -ce --arg a "$ACCOUNT" '.accounts[$a] // empty' "$CAT" 2>/dev/null) \
  || refuse "account '$ACCOUNT' is not a key of catalog/orgo-plans.json .accounts"
cj() { jq -r "$1 | if . == null then \"\" else tostring end" <<< "$A"; }
KEYENV=$(cj .key_env)
[[ "${KEYENV:-ORGO_API_KEY}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || refuse "key_env '$KEYENV' is not an env var name"
KEYENV=${KEYENV:-ORGO_API_KEY}; ORGO_API_KEY="${!KEYENV:-}"  # the orgo() seam reads ORGO_API_KEY
[ -n "$VCPUS" ] || VCPUS=$(cj .defaults.vcpus)
[ -n "$MEMGB" ] || MEMGB=$(cj .defaults.mem_gb)
[ -n "$DISKGB" ] || DISKGB=$(cj .defaults.disk_gb)
[ -n "$VCPUS" ] || refuse "no --vcpus and no defaults.vcpus in catalog/orgo-plans.json"
[ -n "$MEMGB" ] || refuse "no --mem-gb and no defaults.mem_gb in catalog/orgo-plans.json"
for v in "vcpus:$VCPUS" "mem-gb:$MEMGB" ${DISKGB:+"disk-gb:$DISKGB"}; do
  [[ "${v#*:}" =~ ^[1-9][0-9]*$ ]] || refuse "--${v%%:*} '${v#*:}' is not a positive integer"
done
MAXV=$(cj .limits.max_vcpus_per_computer)
[[ "$MAXV" =~ ^[0-9]+$ ]] || refuse "limits.max_vcpus_per_computer not recorded in catalog/orgo-plans.json"
[ "$VCPUS" -le "$MAXV" ] || refuse "--vcpus $VCPUS is over the plan cap of $MAXV per computer"
jq -e --argjson m "$MEMGB" '.limits.ram_tiers_gb | index($m) != null' <<< "$A" >/dev/null 2>&1 \
  || refuse "--mem-gb $MEMGB is not a RAM tier ($(jq -c .limits.ram_tiers_gb <<< "$A"))"
for k in computer vcpu ram_gb ${DISKGB:+disk_gb}; do
  [ -n "$(cj ".prices_usd_mo.$k")" ] || refuse "price $k not recorded in catalog/orgo-plans.json"
done
USD=$(jq -r --argjson v "$VCPUS" --argjson m "$MEMGB" --argjson d "${DISKGB:-0}" \
  '.prices_usd_mo | .computer + $v*.vcpu + $m*.ram_gb + (if $d > 0 then $d*.disk_gb else 0 end)' <<< "$A")
HOST="${HARNESS_BOX_PREFIX}${ID}"
SPECS="${VCPUS}c/${MEMGB}gb/${DISKGB:--}gb"

# ---------- state ----------
SDIR="$H/state/box-launch"; ST="$SDIR/$ID.json"
OID=""; IP=""; SMOKE=PENDING
if [ -f "$ST" ]; then
  jq -e . "$ST" >/dev/null 2>&1 || refuse "state file $ST does not parse; fix or delete it"
  got=$(jq -c '[.project, .account, .specs.vcpus, .specs.mem_gb, .specs.disk_gb]' "$ST")
  want=$(jq -nc --arg p "$PROJECT" --arg a "$ACCOUNT" --argjson v "$VCPUS" --argjson m "$MEMGB" \
    --argjson d "${DISKGB:-null}" '[$p, $a, $v, $m, $d]')
  [ "$got" = "$want" ] || refuse "state says $got (project, account, vcpus, mem_gb, disk_gb), args say $want; pass the same args or delete $ST"
  OID=$(jq -r '.orgo_id // empty' "$ST"); IP=$(jq -r '.ip // empty' "$ST"); SMOKE=$(jq -r '.smoke // "PENDING"' "$ST")
fi
done_step() { [ -f "$ST" ] && jq -e --arg s "$1" '.steps[$s] // empty' "$ST" >/dev/null 2>&1; }
st_write() {  # st_write <jq filter> [jq args...]
  local f="$1"; shift
  mkdir -p "$SDIR" || return 1
  if [ -f "$ST" ]; then jq "$@" "$f" "$ST"; else
    jq -n "$@" --arg st_i "$ID" --arg st_p "$PROJECT" --arg st_a "$ACCOUNT" --arg st_h "$HOST" \
      --argjson st_v "$VCPUS" --argjson st_m "$MEMGB" --argjson st_d "${DISKGB:-null}" --argjson st_u "$USD" \
      '{id:$st_i, project:$st_p, account:$st_a, host:$st_h, orgo_id:null, ip:null,
        specs:{vcpus:$st_v, mem_gb:$st_m, disk_gb:$st_d}, usd_mo:$st_u, steps:{}} | '"$f"
  fi > "$ST.tmp.$$" && mv "$ST.tmp.$$" "$ST"
}
stamp() { st_write '.steps[$s] = $v' --arg s "$1" --arg v "${2:-$(date -u +%FT%TZ)}" || { echo "box-launch: cannot write $ST" >&2; exit 1; }; }
summary() { echo "box-launch: box=$ID orgo=${OID:--} ip=${IP:--} specs=$SPECS usd_mo=$USD smoke=$SMOKE"; }
finish() { summary; exit "$1"; }
fail() { echo "box-launch: $*" >&2; finish 1; }
alert() { "$HERE/alert-line.sh" --project "$PROJECT" "box-launch: $*"; }

STEPS="capacity create running tailnet hubkey harness envfiles migrate ghapp register merged bootstrap smoke"
PENDING=""
for s in $STEPS; do done_step "$s" || PENDING="$PENDING $s "; done
pend() { [[ "$PENDING" == *" $1 "* ]]; }

# ---------- preflight: everything --apply needs, before any network call ----------
POLL=${BOX_LAUNCH_POLL_S:-15}; DEADLINE=${BOX_LAUNCH_DEADLINE_S:-900}
[[ "$POLL" =~ ^[1-9][0-9]*$ ]]     || refuse "BOX_LAUNCH_POLL_S '$POLL' is not a positive integer"
[[ "$DEADLINE" =~ ^[1-9][0-9]*$ ]] || refuse "BOX_LAUNCH_DEADLINE_S '$DEADLINE' is not a positive integer"
TPL=$(cj .template_ref)
NEED_POOL=""
for k in computers vcpus ram_gb ${DISKGB:+disk_gb}; do [ -n "$(cj ".pool.$k")" ] || NEED_POOL="$NEED_POOL $k"; done
PUBKEY_F="${BOX_LAUNCH_HUB_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
PUBKEY=""
if [ -r "$PUBKEY_F" ] && [ "$(grep -c . "$PUBKEY_F")" = 1 ]; then
  PUBKEY=$(grep . "$PUBKEY_F")
  [[ "$PUBKEY" =~ ^ssh-[a-z0-9-]+\ [A-Za-z0-9+/=]+(\ [^\']*)?$ ]] || PUBKEY=""
fi
NOTCONF=""
if [ -z "$OID" ]; then
  { pend capacity || pend create; } && [ -n "$NEED_POOL" ] && NOTCONF="$NOTCONF; pool$NEED_POOL not recorded in catalog/orgo-plans.json"
  pend create && [ -z "$TPL" ] && NOTCONF="$NOTCONF; template_ref not recorded in catalog/orgo-plans.json"
fi
for s in capacity create running tailnet hubkey; do
  pend "$s" && { [ -n "${ORGO_API_KEY:-}" ] || NOTCONF="$NOTCONF; $KEYENV unset"; break; }
done
pend tailnet && [ -z "${BOX_LAUNCH_TS_AUTHKEY:-}" ] && NOTCONF="$NOTCONF; BOX_LAUNCH_TS_AUTHKEY unset"
pend hubkey && [ -z "$PUBKEY" ] && NOTCONF="$NOTCONF; hub public key $PUBKEY_F is not one ssh- line"

if [ "$APPLY" = 1 ]; then
  [ -z "$NOTCONF" ] || refuse "not configured: ${NOTCONF#; }"
  if [ -z "$OID" ]; then
    if ! [[ "$CONFIRM" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       || ! jq -en --argjson a "$CONFIRM" --argjson b "$USD" '$a == $b' >/dev/null; then
      echo "COST: box $ID \$$USD/mo — re-run with --confirm-monthly-usd $USD"
      exit 2
    fi
  fi
  mkdir -p "$H/locks" || exit 1
  exec 9>"$H/locks/box-launch-$ID.lock"
  flock -n 9 || { echo "box-launch: $ID already running"; exit 0; }
fi

# ---------- S1 capacity ----------
# read_list: LIST = the computer array, or exit 1. Never "zero used".
read_list() {
  orgo GET /computers || fail "GET /computers HTTP $ORGO_HTTP"
  LIST=$(printf '%s' "$ORGO_BODY" | jq -ce 'if type == "array" then . elif (.computers | type) == "array" then .computers else error("shape") end' 2>/dev/null) \
    || fail "unreadable computer list from GET /computers"
}
# Re-read while no Orgo id is in state, even if capacity is stamped: a create
# that failed after the stamp must not POST against a stale reading.
ADOPTABLE=0
if [ -z "$OID" ]; then
  if [ -z "${ORGO_API_KEY:-}" ]; then
    echo "PLAN capacity not read ($KEYENV unset)"
  elif [ -n "$NEED_POOL" ]; then
    echo "PLAN capacity not checked: pool$NEED_POOL not recorded in catalog/orgo-plans.json"
  else
    read_list
    if jq -e --arg h "$HOST" 'any(.[]; .name == $h)' <<< "$LIST" >/dev/null; then
      ADOPTABLE=1
      echo "capacity: $HOST is already on the Orgo account; it is adopted, not bought"
    else
      USED=$(jq -ce --arg d "${DISKGB:+1}" '
        if all(.[]; (.cpu|type) == "number" and (.ram|type) == "number" and ($d == "" or (.disk|type) == "number"))
        then {computers: length, vcpus: (map(.cpu)|add // 0), ram_gb: (map(.ram)|add // 0), disk_gb: (map(.disk // 0)|add // 0)}
        else error("fields") end' <<< "$LIST" 2>/dev/null) \
        || fail "unreadable computer list: an entry has no numeric cpu/ram${DISKGB:+/disk}"
      SHORT=$(jq -nr --argjson u "$USED" --argjson c "$A" --argjson v "$VCPUS" --argjson m "$MEMGB" --argjson d "${DISKGB:-0}" '
        [["computer","computers","computer",1],["vcpu","vcpus","vcpu",$v],["ram-gb","ram_gb","ram_gb",$m],["disk-gb","disk_gb","disk_gb",$d]][]
        | select(.[3] > 0) | (($u[.[1]] + .[3]) - $c.pool[.[1]]) as $q
        | select($q > 0) | "NEEDS PURCHASE: \(.[0]) \($q) $\($q * $c.prices_usd_mo[.[2]])/mo"')
      if [ -n "$SHORT" ]; then printf '%s\n' "$SHORT"; finish 3; fi
      echo "capacity: pool fits $SPECS (used $(jq -r '"\(.computers) computers, \(.vcpus) vCPU, \(.ram_gb) GB RAM"' <<< "$USED"))"
    fi
  fi
  [ "$APPLY" = 1 ] && pend capacity && stamp capacity
fi

# ---------- dry run: one PLAN line per step not done ----------
if [ "$APPLY" = 0 ]; then
  [ -n "$NOTCONF" ] && echo "PLAN --apply refuses until configured: ${NOTCONF#; }"
  for s in $STEPS; do
    pend "$s" || continue
    case "$s" in
      capacity)  [ -n "$OID" ] && echo "PLAN capacity skipped (Orgo id $OID in state)" ;;
      create)    [ "$ADOPTABLE" = 1 ] && echo "PLAN create adopt $HOST from the Orgo account, no POST"
                 [ -z "$OID" ] && [ "$ADOPTABLE" = 0 ] && echo "PLAN create POST /computers name=$HOST specs=$SPECS \$$USD/mo (needs --confirm-monthly-usd $USD)" ;;
      running)   echo "PLAN running wait for the computer to report running (deadline ${DEADLINE}s)" ;;
      tailnet)   echo "PLAN tailnet start sshd/cron/tailscaled, tailscale up --hostname=$HOST, read the 100.64/10 address" ;;
      hubkey)    echo "PLAN hubkey add $PUBKEY_F to /root/.ssh/authorized_keys, then ssh root@<ip> true" ;;
      harness)   echo "PLAN harness clone or pull /root/harness-checkout ($HARNESS_REPO), sync /root/harness" ;;
      envfiles)  echo "PLAN envfiles copy global.env $PROJECT.env and the optional files that exist, compare by sha256" ;;
      migrate)   echo "PLAN migrate bin/migrate-env-dir.sh" ;;
      ghapp)     echo "PLAN ghapp bin/ensure-box-gh-app-default.sh $PROJECT" ;;
      register)  LIKE=$(cj .register_like)
                 echo "PLAN register bin/box-register.sh $ID --ip <ip> --project $PROJECT --account $(cj .cost_account)${LIKE:+ --like $LIKE} --apply" ;;
      merged)    echo "PLAN merged wait until origin/main:fleet.conf names $HOST <ip> for $PROJECT" ;;
      bootstrap) echo "PLAN bootstrap state/box-id=$ID, bin/bootstrap-machine.sh $PROJECT" ;;
      smoke)     echo "PLAN smoke box-id, fleet-managed crontab block, sshd, tailscale status" ;;
    esac
  done
  finish 0
fi

# ---------- S2 create: exactly one computer ----------
IDRE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
if [ -z "$OID" ]; then
  read_list
  ADOPT=$(jq -r --arg h "$HOST" '[.[] | select(.name == $h) | .id | tostring] | first // empty' <<< "$LIST")
  if [ -n "$ADOPT" ]; then
    [[ "$ADOPT" =~ $IDRE ]] || fail "the $HOST computer on Orgo has an unusable id"
    OID=$ADOPT
    echo "create: adopted $HOST (Orgo id $OID), no POST"
  else
    BODY=$(jq -nc --arg n "$HOST" --arg t "$TPL" --argjson r "$MEMGB" --argjson c "$VCPUS" --argjson d "${DISKGB:-null}" \
      '{name:$n, template_ref:$t, ram:$r, cpu:$c} + (if $d then {disk:$d} else {} end)')
    if orgo POST /computers "$BODY"; then
      OID=$(printf '%s' "$ORGO_BODY" | jq -r '.id // empty | tostring' 2>/dev/null)
      if ! [[ "$OID" =~ $IDRE ]]; then
        OID=""
        alert "create answered HTTP $ORGO_HTTP with no usable computer id; a $HOST computer may exist on the Orgo account (a re-run adopts it by name)"
        fail "create returned no id"
      fi
    elif [ "$ORGO_HTTP" = 403 ] && [[ "$ORGO_BODY" == *RAM_ADDON* ]]; then
      echo "NEEDS PURCHASE: ram-gb $MEMGB \$$(jq -n --argjson m "$MEMGB" --argjson c "$A" '$m * $c.prices_usd_mo.ram_gb')/mo"
      finish 3
    else
      fail "create HTTP $ORGO_HTTP"
    fi
    echo "create: $HOST is Orgo id $OID"
  fi
  st_write '.orgo_id = $o' --arg o "$OID" || { alert "Orgo id $OID for $HOST was not written to $ST"; fail "cannot write $ST"; }
fi
pend create && stamp create

# ---------- S3 running ----------
if pend running; then
  START=$(date +%s)
  while :; do
    S=""
    orgo GET "/computers/$OID" && S=$(printf '%s' "$ORGO_BODY" | jq -r '.status // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [ "$S" = running ] && break
    [ $(( $(date +%s) - START )) -ge "$DEADLINE" ] && fail "computer $OID not running after ${DEADLINE}s (last status '${S:-HTTP $ORGO_HTTP}')"
    sleep "$POLL"
  done
  stamp running
fi

# ---------- S4 tailnet (Orgo bash) ----------
TSD='setsid -f /usr/sbin/tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/tmp/tailscaled.log 2>&1'
if pend tailnet; then
  CMD="pgrep -x sshd >/dev/null || /usr/sbin/sshd; pgrep -x cron >/dev/null || /usr/sbin/cron;"
  CMD="$CMD command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh;"
  CMD="$CMD pgrep -x tailscaled >/dev/null || { $TSD; sleep 3; };"
  CMD="$CMD [ -n \"\$(tailscale ip -4 2>/dev/null)\" ] || tailscale up --auth-key=$(printf '%q' "$BOX_LAUNCH_TS_AUTHKEY") --hostname=$HOST >/dev/null 2>&1;"
  CMD="$CMD tailscale ip -4"
  remote "$OID" "box-launch:$ID:tailnet" "$CMD"; rc=$?
  [ "$rc" = 0 ] || fail "tailnet: the Orgo bash command answered rc=$rc"
  IP=$(printf '%s\n' "$REMOTE_OUT" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$' | tail -n 1)
  [ -n "$IP" ] || fail "tailnet: no 100.64/10 address from tailscale ip -4"
  st_write '.ip = $ip' --arg ip "$IP" || fail "cannot write $ST"
  stamp tailnet
  echo "tailnet: $HOST is $IP"
fi
[ -n "$IP" ] || fail "state has no tailnet address; delete the tailnet stamp in $ST and re-run"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "root@$IP")

# ---------- S5 hubkey ----------
if pend hubkey; then
  CMD="mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys"
  CMD="$CMD && { grep -qxF '$PUBKEY' /root/.ssh/authorized_keys || printf '%s\n' '$PUBKEY' >> /root/.ssh/authorized_keys; }"
  CMD="$CMD && chmod 600 /root/.ssh/authorized_keys"
  remote "$OID" "box-launch:$ID:hubkey" "$CMD"; rc=$?
  [ "$rc" = 0 ] || fail "hubkey: the Orgo bash command answered rc=$rc"
  "${SSH[@]}" true </dev/null || fail "hubkey: ssh root@$IP true failed"
  stamp hubkey
fi

# ---------- S6 harness ----------
# A new box has no GitHub credential until envfiles (S7) and ghapp (S9). So the
# hub mints a short-lived token (bin/gh-token.sh) and sends it as the first
# stdin line, never in argv. The box script uses it only for the clone, the
# pull and harness-sync, through gh's git credential helper.
if pend harness; then
  GT=$("$HERE/gh-token.sh" "$HARNESS_REPO" 2>/dev/null) && [ -n "$GT" ] \
    || fail "harness: bin/gh-token.sh $HARNESS_REPO printed no token on the hub (check env/github-app.env + .pem, or env/gh-pat)"
  { printf '%s\n' "$GT"; cat <<'REMOTE'; } | "${SSH[@]}" "IFS= read -r GH_TOKEN && export GH_TOKEN && exec bash -s -- $HARNESS_REPO" \
    || { unset GT; fail "harness: clone/sync on the box failed"; }
set -euo pipefail
HREPO="$1"; GT="$GH_TOKEN"; unset GH_TOKEN
withgh() {
  GH_TOKEN="$GT" GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' "$@"
}
if [ -d /root/harness-checkout/.git ]; then
  withgh git -C /root/harness-checkout pull --ff-only -q
else
  withgh gh repo clone "$HREPO" /root/harness-checkout -- -q
fi
mkdir -p /root/harness
if [ -x /root/harness/bin/harness-sync.sh ]; then
  withgh /root/harness/bin/harness-sync.sh
else
  cp -r /root/harness-checkout/bin /root/harness/
  cp -r /root/harness-checkout/prompts /root/harness/
  cp /root/harness-checkout/fleet.conf /root/harness/fleet.conf
  for d in catalog rules; do
    if [ -d "/root/harness-checkout/$d" ]; then cp -r "/root/harness-checkout/$d" /root/harness/; fi
  done
fi
REMOTE
  unset GT
  stamp harness
fi

# ---------- S7 envfiles: by name and hash only ----------
if pend envfiles; then
  FILES="global.env $PROJECT.env"
  for f in global.env "$PROJECT.env"; do [ -f "$HENV/$f" ] || fail "envfiles: $f is missing on the hub"; done
  for f in ${BOX_LAUNCH_ENV_FILES_OPTIONAL-github-app.env github-app.pem}; do
    [ -f "$HENV/$f" ] && FILES="$FILES $f"
  done
  # The box's env dir comes from the box's own resolver, in the clone the
  # harness step just made (bin/lib/env-path.sh), never a literal path.
  BOXENV=$("${SSH[@]}" ". /root/harness/bin/lib/env-path.sh && harness_env_dir /root/harness" </dev/null) \
    && [ -n "$BOXENV" ] || fail "envfiles: the box's env dir did not resolve (bin/lib/env-path.sh on the box)"
  "${SSH[@]}" "mkdir -p $BOXENV && chmod 700 $BOXENV" </dev/null || fail "envfiles: cannot make $BOXENV on the box"
  DIFF=0
  for f in $FILES; do
    scp -p -q -o BatchMode=yes -o ConnectTimeout=15 "$HENV/$f" "root@$IP:$BOXENV/$f" </dev/null \
      || fail "envfiles: scp $f failed"
    "${SSH[@]}" "chmod 600 $BOXENV/$f" </dev/null || fail "envfiles: chmod $f failed"
    hub=$(sha256sum "$HENV/$f" | awk '{print $1}')
    box=$("${SSH[@]}" "sha256sum $BOXENV/$f" </dev/null | awk '{print $1}')
    if [ -n "$hub" ] && [ "$hub" = "$box" ]; then echo "envfile $f match"; else echo "envfile $f differ"; DIFF=1; fi
  done
  [ "$DIFF" = 0 ] || fail "envfiles: an env file on the box differs from the hub"
  stamp envfiles
fi

# ---------- S8 migrate, S9 ghapp ----------
if pend migrate; then
  "${SSH[@]}" "bash /root/harness/bin/migrate-env-dir.sh" </dev/null || fail "migrate: bin/migrate-env-dir.sh failed"
  stamp migrate
fi
if pend ghapp; then
  "${SSH[@]}" "/root/harness/bin/ensure-box-gh-app-default.sh $PROJECT" </dev/null; rc=$?
  case "$rc" in
    0) stamp ghapp ;;
    3) stamp ghapp "done-warn logout deferred"; echo "ghapp: installed, keyring logout deferred (rc 3)" ;;
    *) fail "ghapp: bin/ensure-box-gh-app-default.sh $PROJECT rc=$rc" ;;
  esac
fi

# ---------- S10 register, S11 merged ----------
if pend register; then
  LIKE=$(cj .register_like)
  "$ROOT/bin/box-register.sh" "$ID" --ip "$IP" --project "$PROJECT" --account "$(cj .cost_account)" \
    ${LIKE:+--like "$LIKE"} --root "$ROOT" --apply; rc=$?
  [ "$rc" = 0 ] || fail "register: bin/box-register.sh rc=$rc"
  stamp register
fi
if pend merged; then
  git -C "$ROOT" fetch -q origin main || fail "merged: git fetch origin main failed"
  ROW=$(git -C "$ROOT" show origin/main:fleet.conf 2>/dev/null \
    | awk -v p="$PROJECT" '!/^[[:space:]]*(#|$)/ && $1 == p {print $6, $7; exit}')
  if [ "$ROW" != "$HOST $IP" ]; then
    echo "WAITING: commit the box-register change, open its PR, merge it, then re-run"
    finish 4
  fi
  stamp merged
fi

# ---------- S12 bootstrap ----------
if pend bootstrap; then
  "${SSH[@]}" bash -s -- "$ID" "$PROJECT" <<'REMOTE' || fail "bootstrap: bin/bootstrap-machine.sh failed"
set -euo pipefail
ID="$1"; P="$2"
if [ -x /root/harness/bin/harness-sync.sh ]; then
  /root/harness/bin/harness-sync.sh
else
  git -C /root/harness-checkout pull --ff-only -q
  cp /root/harness-checkout/fleet.conf /root/harness/fleet.conf
fi
mkdir -p /root/harness/state
[ "$(cat /root/harness/state/box-id 2>/dev/null)" = "$ID" ] || printf '%s\n' "$ID" > /root/harness/state/box-id
/root/harness/bin/bootstrap-machine.sh "$P"
REMOTE
  stamp bootstrap
fi

# ---------- S13 smoke ----------
if pend smoke; then
  OUT=$("${SSH[@]}" bash -s -- "$ID" "$PROJECT" <<'REMOTE'
f=0
[ "$(cat /root/harness/state/box-id 2>/dev/null)" = "$1" ] || { echo "smoke box-id FAIL"; f=1; }
crontab -l 2>/dev/null | grep -qF "# BEGIN fleet-managed project=$2" || { echo "smoke crontab FAIL"; f=1; }
pgrep -x sshd >/dev/null || { echo "smoke sshd FAIL"; f=1; }
tailscale status >/dev/null 2>&1 || { echo "smoke tailscale FAIL"; f=1; }
[ "$f" = 0 ] && echo SMOKE_PASS
exit "$f"
REMOTE
  ); rc=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT" | grep -v '^SMOKE_PASS$'
  if [ "$rc" = 0 ] && grep -qx SMOKE_PASS <<<"$OUT"; then
    SMOKE=PASS
    st_write '.smoke = "PASS"' || fail "cannot write $ST"
    stamp smoke
  else
    SMOKE=FAIL
    st_write '.smoke = "FAIL"'
    fail "smoke: FAIL on $HOST"
  fi
fi
finish 0
