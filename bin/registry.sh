#!/bin/bash
# bin/registry.sh — BH-5650 (BH-5633.2): the operator CLI for the D1 fleet
# registry. Every write goes through a harness-jobs write route, which writes
# the rows, one audit row per changed row and one version bump in one batch.
#
#   registry.sh show
#       Print the registry version, then one line per box:
#       <box> <box_id> <ip|-> projects=<p,p|-> lanes=<n>. Read-only.
#   registry.sh add-box <name> --ip <tailnet-ip> --like <box-id> [--id <box-id>]
#                       [--role <role>]
#       Add a box with the lane memberships and the exact account rows of an
#       existing box. --id defaults to the cron box id of <name>
#       (box-x -> x). A retry of the same add changes nothing.
#       --role sets the box role (no --role = null, the readers' default).
#   registry.sh set-box-role <box> <role>
#       Set a box's role: build review gate standby hub gate-only retired. The
#       route refuses any other value (400). A gate-only or retired box is
#       skipped by the version check and gets no watchdog ping row.
#   registry.sh move-project <project> --box <box>
#       Put a project on another box. Its cron offset stays.
#   registry.sh drain-box <box>
#       Remove every lane membership of the box. Refused (409) while an active
#       project is on the box: move those first.
#   registry.sh add-project <project> --repo <owner/name> --prod <url|->
#                           --offset <0-9> --box <box> [--prefix <path|->]
#       Add a project row (bin/load-project.sh uses this when
#       REGISTRY_SOURCE=db).
#
#   --actor <name> on any write: the audit actor (default
#   registry-cli-<short hostname>).
#
# Env: JOBS_URL (or the fleet default from bin/lib/deployment.sh) and
# HARNESS_SECRET for every verb; REGISTRY_ADMIN_TOKEN for a write. Both
# credentials go to curl in a mode-600 header file, never argv. After a 2xx
# write, the local registry cache (state/registry) is refreshed when it exists.
# Output of a write: `registry: <verb> changed=<n> version=<v>`.
# rc 0 = a 2xx answer; 1 = any other answer (status and body on stderr);
# 2 = refused before any call (usage, missing env).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
die() { echo "registry: $*" >&2; exit 2; }

VERB="${1:-}"; [ -n "$VERB" ] || usage
shift
ACTOR=""; IP=""; LIKE=""; ID=""; TOBOX=""; REPO=""; PROD=""; OFFSET=""; PREFIX="-"; NAME=""; ROLE=""; ARG2=""
while [ $# -gt 0 ]; do
  case "$1" in
    --actor) ACTOR="${2:?--actor needs a name}"; shift 2 ;;
    --ip) IP="${2:?--ip needs an address}"; shift 2 ;;
    --like) LIKE="${2:?--like needs a box id}"; shift 2 ;;
    --id) ID="${2:?--id needs a box id}"; shift 2 ;;
    --box) TOBOX="${2:?--box needs a box}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs owner/name}"; shift 2 ;;
    --prod) PROD="${2:?--prod needs a url or -}"; shift 2 ;;
    --offset) OFFSET="${2:?--offset needs 0-9}"; shift 2 ;;
    --prefix) PREFIX="${2:?--prefix needs a path or -}"; shift 2 ;;
    --role) ROLE="${2:?--role needs a role}"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ "$VERB" = set-box-role ] && [ -z "$ARG2" ]; then ARG2="$1"
      else die "one name only (got $NAME and $1)"; fi
      shift ;;
  esac
done

if [ -z "$ACTOR" ]; then
  ACTOR="registry-cli-$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
  ACTOR="${ACTOR:0:64}"
fi
[[ "$ACTOR" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--actor must be 1-64 of [A-Za-z0-9._-]"
uri() { jq -rn --arg v "$1" '$v | @uri'; }

# The request: METHOD, PATH and the JSON BODY (empty = none).
METHOD=""; RPATH=""; BODY=""; WRITE=1
case "$VERB" in
  show)
    [ -z "$NAME" ] || die "show takes no name"
    METHOD=GET; RPATH=/api/registry; WRITE=0 ;;
  add-box)
    [ -n "$NAME" ] || die "add-box needs a box name"
    [ -n "$IP" ] || die "add-box needs --ip <tailnet-ip>"
    [ -n "$LIKE" ] || die "add-box needs --like <existing box id>"
    if [ -z "$ID" ]; then
      # shellcheck source=bin/lib/cron-lines.sh
      . "$HERE/lib/cron-lines.sh" || die "cannot load bin/lib/cron-lines.sh"
      ID=$(cron_box_id_for "$NAME")
    fi
    METHOD=POST; RPATH=/api/registry/boxes
    BODY=$(jq -cn --arg box "$NAME" --arg id "$ID" --arg ip "$IP" --arg like "$LIKE" --arg actor "$ACTOR" --arg role "$ROLE" \
      '{box: $box, box_id: $id, tailnet_ip: $ip, like: $like, actor: $actor} + (if $role == "" then {} else {role: $role} end)') ;;
  set-box-role)
    [ -n "$NAME" ] || die "set-box-role needs a box"
    [ -n "$ARG2" ] || die "set-box-role needs a role (build, review, gate, standby, hub, gate-only, retired)"
    METHOD=PATCH; RPATH="/api/registry/boxes/$(uri "$NAME")"
    BODY=$(jq -cn --arg role "$ARG2" --arg actor "$ACTOR" '{role: $role, actor: $actor}') ;;
  move-project)
    [ -n "$NAME" ] || die "move-project needs a project"
    [ -n "$TOBOX" ] || die "move-project needs --box <box>"
    METHOD=PATCH; RPATH="/api/registry/projects/$(uri "$NAME")"
    BODY=$(jq -cn --arg box "$TOBOX" --arg actor "$ACTOR" '{box: $box, actor: $actor}') ;;
  drain-box)
    [ -n "$NAME" ] || die "drain-box needs a box"
    METHOD=POST; RPATH="/api/registry/boxes/$(uri "$NAME")/drain"
    BODY=$(jq -cn --arg actor "$ACTOR" '{actor: $actor}') ;;
  add-project)
    [ -n "$NAME" ] || die "add-project needs a project"
    [ -n "$REPO" ] && [ -n "$PROD" ] && [ -n "$OFFSET" ] && [ -n "$TOBOX" ] \
      || die "add-project needs --repo, --prod, --offset and --box"
    # A number on the wire only when it is one: "3x" is sent as a string, so
    # the route refuses it instead of this script guessing.
    METHOD=POST; RPATH=/api/registry/projects
    BODY=$(jq -cn --arg p "$NAME" --arg repo "$REPO" --arg prod "$PROD" --arg pre "$PREFIX" \
      --arg off "$OFFSET" --arg box "$TOBOX" --arg actor "$ACTOR" \
      '{project: $p, repo: $repo, prod: $prod, board_prefix: $pre,
        cron_offset: ($off | if test("^[0-9]+$") then tonumber else . end), box: $box, actor: $actor}') ;;
  -h|--help|help) usage ;;
  *) die "unknown verb $VERB (show, add-box, set-box-role, move-project, drain-box, add-project)" ;;
esac

# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$HERE/lib/deployment.sh}" 2>/dev/null || :
JOBS_URL="${JOBS_URL-${HARNESS_WORKERS_SUBDOMAIN:+https://harness-jobs.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}}"
[ -n "${JOBS_URL:-}" ] || die "JOBS_URL is empty: no harness-jobs worker to call"
[ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is unset"
if [ "$WRITE" = 1 ] && [ -z "${REGISTRY_ADMIN_TOKEN:-}" ]; then
  die "REGISTRY_ADMIN_TOKEN is unset (the worker secret that gates registry writes)"
fi

TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
( umask 077
  { printf 'authorization: Bearer %s\n' "$HARNESS_SECRET"
    [ "$WRITE" = 0 ] || printf 'x-registry-admin-token: %s\ncontent-type: application/json\n' "$REGISTRY_ADMIN_TOKEN"
  } > "$TMP/headers" ) || die "cannot write the header file"
ARGS=(-sS -m "${JOBS_TIMEOUT:-30}" --connect-timeout 3 -w $'\n%{http_code}' -X "$METHOD" -H "@$TMP/headers")
if [ -n "$BODY" ]; then printf '%s' "$BODY" > "$TMP/body"; ARGS+=(--data-binary "@$TMP/body"); fi
OUT=$(curl "${ARGS[@]}" "$JOBS_URL$RPATH" 2>"$TMP/curl.err")
RC=$?
rm -f "$TMP/headers"
if [ "$RC" -ne 0 ]; then echo "registry: $VERB: transport rc=$RC $(head -c 200 "$TMP/curl.err")" >&2; exit 1; fi
HTTP="${OUT##*$'\n'}"; RESP="${OUT%$'\n'*}"
case "$HTTP" in
  2*) ;;
  *) echo "registry: $VERB: http=$HTTP $(head -c 400 <<<"$RESP")" >&2; exit 1 ;;
esac

if [ "$WRITE" = 0 ]; then
  jq -er '
    (.boxes // []) as $b | (.projects // []) as $p | (.lane_boxes // []) as $l
    | "registry: version=\(.version) boxes=\($b | length) projects=\($p | length)",
      ($b[] | . as $x
        | [$x.box, $x.box_id, ($x.tailnet_ip // "-"),
           "projects=" + ([$p[] | select(.box == $x.box and (.status // "active") == "active") | .project] | if length == 0 then "-" else join(",") end),
           "lanes=" + ([$l[] | select(.box_id == $x.box_id)] | length | tostring)]
        | join(" "))' <<<"$RESP" 2>/dev/null \
    || { echo "registry: show: http=$HTTP but the answer is not a registry: $(head -c 200 <<<"$RESP")" >&2; exit 1; }
  exit 0
fi

LINE=$(jq -er --arg verb "$VERB" 'select(.ok == true and (.changed | type == "number") and (.version | type == "number"))
  | "registry: \($verb) changed=\(.changed) version=\(.version)"' <<<"$RESP" 2>/dev/null) \
  || { echo "registry: $VERB: http=$HTTP but the answer is not a write result: $(head -c 200 <<<"$RESP")" >&2; exit 1; }
echo "$LINE"

# The local cache, refreshed now so this box reads its own write at once.
# Other boxes see it within REGISTRY_CACHE_TTL_S. A failed refresh is not a
# failed write: the write is already committed, and the read ladder alerts.
if [ -d "$H/state/registry" ]; then
  # shellcheck source=bin/lib/registry.sh
  if . "$HERE/lib/registry.sh" 2>/dev/null; then
    HARNESS="$H" REGISTRY_CACHE_TTL_S=0 registry_conf_path >/dev/null 2>&1 \
      || echo "registry: $VERB: written, but the local cache did not refresh" >&2
  fi
fi
exit 0
