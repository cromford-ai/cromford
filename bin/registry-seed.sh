#!/bin/bash
# bin/registry-seed.sh [--root <dir>] [--emit] [--actor <name>] — BH-5649
# (BH-5633.1): import today's committed registry files into the D1 fleet
# registry, once, through harness-jobs POST /api/registry/import.
#
#   fleet.conf               -> projects (rows, `# @retired`), boxes (column 6
#                               and 7, `# @standby`)
#   the lane registry        -> lane_boxes, one row per (lane, .boxes[] entry);
#                               read through lanes_json_path, the ONE loader
#   catalog/cost-accounts.json -> boxes (box_aliases keys, cost_box) and
#                               box_accounts (login.box, boxes.cost_rows[],
#                               boxes.jobs[]; globs such as pool-* verbatim)
#
# It reads FILES only (REGISTRY_SOURCE=file for its own reads), so it can never
# seed the DB from the DB. The route is idempotent on natural keys: a second
# run with the same files changes 0 rows, writes no audit row and keeps the
# version. Rows in D1 that the files no longer carry are not deleted; the
# answer counts them as stale.
#
#   --emit    print the canonical payload and exit 0. No network: the dry run.
#   --root    the tree to read (default: this checkout)
#   --actor   the audit actor (default registry-seed)
#
#   --force   import even into a registry that is already seeded (see below)
#   --from-export <dir|import.json>
#             restore D1 from a nightly snapshot of bin/registry-export.sh
#             --snapshot: <dir>/import.json, or <dir>/latest/import.json when
#             <dir> is the export root. The committed files are not read.
#
# THE FILES ARE AN EXPORT ONCE THE REGISTRY IS SEEDED (BH-5651). Before the POST
# it asks GET /api/registry/version. Version 0, or 503 `registry schema not
# applied`, proceeds. Version >= 1 is rc 1 with no POST unless --force: a change
# goes through bin/registry.sh, a restore through --from-export --force. A
# transport failure or any other answer is rc 1 too (an empty registry is not
# proven).
#
# Without --emit it needs JOBS_URL (or the fleet default from
# bin/lib/deployment.sh), HARNESS_SECRET and REGISTRY_ADMIN_TOKEN; a missing one
# is rc 2 and named. Both credentials go to curl in a mode-600 header file,
# never argv. Output: `registry-seed: changed=<n> version=<v> stale=<k>`.
# rc 0 = a 2xx answer; 1 = any other answer (body on stderr); 2 = refused
# before any call (bad files, missing env, another seed running).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EMIT=0; ACTOR=registry-seed; FORCE=0; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a dir}"; shift 2 ;;
    --emit) EMIT=1; shift ;;
    --actor) ACTOR="${2:?--actor needs a name}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --from-export) FROM="${2:?--from-export needs a snapshot dir or import.json}"; shift 2 ;;
    *) echo "usage: registry-seed.sh [--root <dir>] [--emit] [--actor <name>] [--force] [--from-export <dir|import.json>]" >&2; exit 2 ;;
  esac
done
die() { echo "registry-seed: $*" >&2; exit 2; }
[[ "$ACTOR" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--actor must be 1-64 of [A-Za-z0-9._-]"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ -n "$FROM" ]; then
  # A restore: the snapshot's import.json IS the payload; no committed file is read.
  if [ -d "$FROM" ]; then
    if [ -f "$FROM/import.json" ]; then FROM="$FROM/import.json"; else FROM="$FROM/latest/import.json"; fi
  fi
  [ -f "$FROM" ] || die "--from-export: no $FROM"
  jq -e '.projects | type == "array" and length > 0' "$FROM" >/dev/null 2>&1 || die "--from-export: $FROM has no projects"
  jq --arg actor "$ACTOR" '.actor = $actor' "$FROM" > "$TMP/payload.json" || die "--from-export: cannot read $FROM"
fi

export REGISTRY_SOURCE=file
CONF="$ROOT/fleet.conf"
COST="$ROOT/catalog/cost-accounts.json"
if [ -z "$FROM" ]; then
  [ -f "$CONF" ] || die "no $CONF"
  [ -f "$COST" ] || die "no $COST"
  # shellcheck source=bin/lib/cron-lines.sh
  . "$HERE/lib/cron-lines.sh" || die "cannot load bin/lib/cron-lines.sh"
  # shellcheck source=bin/lib/lanes-registry.sh
  . "$HERE/lib/lanes-registry.sh" || die "cannot load bin/lib/lanes-registry.sh"
  LANES=$(lanes_json_path "$ROOT") || die "no lane registry for $ROOT"


  # One TSV line per fact, with the same awk predicates bin/fleet-conf.sh uses.
  #   P <project> <repo> <prod> <prefix> <offset> <box|-> <position>
  #   R <project> <box|->      S <box> <hub-name> <hub-id>      I <box> <ip>
  awk -v OFS='\t' '
    $1 == "#" && $2 == "@standby" && NF >= 5 { print "S", $3, $4, $5; next }
    $1 == "#" && $2 == "@retired" && NF >= 3 { print "R", $3, (NF >= 4 ? $4 : "-"); next }
    /^[[:space:]]*(#|$)/ { next }
    NF < 5 { printf "row %d has %d fields, a row needs at least 5\n", NR, NF > "/dev/stderr"; bad = 1; next }
    { print "P", $1, $2, $3, $4, $5, ($6 == "" ? "-" : $6), n++
      if ($6 != "" && $7 != "") print "I", $6, $7 }
    END { exit bad }' "$CONF" > "$TMP/facts" || die "fleet.conf: refused (see above)"

  # One box, one address: two rows that disagree are a registry nobody can serve.
  CLASH=$(awk -F'\t' '$1 == "I" { if (($2 in ip) && ip[$2] != $3) print $2 " has two IPs: " ip[$2] " and " $3; ip[$2] = $3 }' "$TMP/facts")
  [ -z "$CLASH" ] || die "fleet.conf: box $CLASH"

  # cron_box_id_for per hostname, computed here because the rule lives in bash.
  {
    awk -F'\t' '($1 == "P" && $7 != "-") { print $7 } ($1 == "R" && $3 != "-") { print $3 } $1 == "S" { print $2 }' "$TMP/facts"
    jq -r '(.box_aliases // {}) | keys[]' "$COST"
  } | LC_ALL=C sort -u | while read -r B; do
    [ -n "$B" ] && printf '%s\t%s\n' "$B" "$(cron_box_id_for "$B")"
  done > "$TMP/box-ids"

  jq -n -S \
    --arg actor "$ACTOR" \
    --rawfile facts "$TMP/facts" \
    --rawfile ids "$TMP/box-ids" \
    --slurpfile cost "$COST" \
    --slurpfile lanes "$LANES" '
    def rows($k): $facts | split("\n") | map(select(length > 0) | split("\t")) | map(select(.[0] == $k));
    def dash: if . == "-" then null else . end;
    (rows("I") | map({key: .[1], value: .[2]}) | from_entries) as $ip
    | (rows("S") | map({key: .[1], value: {n: .[2], i: .[3]}}) | from_entries) as $sb
    | ($cost[0].box_aliases // {}) as $al
    | (rows("P") | map({project: .[1], repo: .[2], prod: .[3], board_prefix: .[4],
          cron_offset: (.[5] | tonumber), box: (.[6] | dash), position: (.[7] | tonumber), status: "active"})) as $act
    | {
        actor: $actor,
        projects: ($act + (rows("R") | to_entries | map({project: .value[1], repo: "-", prod: "-", board_prefix: "-",
          cron_offset: 0, box: (.value[2] | dash), position: (($act | length) + .key), status: "retired"}))),
        boxes: ($ids | split("\n") | map(select(length > 0) | split("\t"))
          | map({box: .[0], box_id: .[1], tailnet_ip: $ip[.[0]], cost_box: $al[.[0]],
                 standby_hub_name: $sb[.[0]].n, standby_hub_id: $sb[.[0]].i})),
        lane_boxes: ([$lanes[0].lanes[] | .id as $l | (.boxes // [])[] | {lane: $l, box_id: .}] | unique | sort_by(.lane, .box_id)),
        box_accounts: ([$cost[0].accounts // {} | to_entries[] | .key as $a | .value
          | (if (.login.box // null) != null then {account: $a, kind: "login", box: .login.box} else empty end),
            ((.boxes.cost_rows // [])[] | {account: $a, kind: "cost_rows", box: .}),
            ((.boxes.jobs // [])[] | {account: $a, kind: "jobs", box: .})] | unique | sort_by(.account, .kind, .box))
      }' > "$TMP/payload.json" || die "could not build the payload"
fi

if [ "$EMIT" = 1 ]; then cat "$TMP/payload.json"; exit 0; fi

# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$HERE/lib/deployment.sh}" 2>/dev/null || :
JOBS_URL="${JOBS_URL-${HARNESS_WORKERS_SUBDOMAIN:+https://harness-jobs.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}}"
[ -n "${JOBS_URL:-}" ] || die "JOBS_URL is empty: no harness-jobs worker to seed"
[ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is unset"
[ -n "${REGISTRY_ADMIN_TOKEN:-}" ] || die "REGISTRY_ADMIN_TOKEN is unset (the worker secret that gates registry writes)"

H="${HARNESS:-/root/harness}"
mkdir -p "$H/state/registry" || die "cannot create $H/state/registry"
exec 9>"$H/state/registry/.seed.lock"
flock -n 9 || die "another registry-seed.sh holds $H/state/registry/.seed.lock"

( umask 077; printf 'authorization: Bearer %s\nx-registry-admin-token: %s\ncontent-type: application/json\n' \
    "$HARNESS_SECRET" "$REGISTRY_ADMIN_TOKEN" > "$TMP/headers" )

# The seed guard (BH-5651): a seeded registry is not overwritten from files.
if [ "$FORCE" != 1 ]; then
  GOUT=$(curl -sS -m "${JOBS_TIMEOUT:-30}" --connect-timeout 3 -w $'\n%{http_code}' \
    -H "@$TMP/headers" "$JOBS_URL/api/registry/version" 2>"$TMP/curl.err")
  GRC=$?
  if [ "$GRC" -ne 0 ]; then
    rm -f "$TMP/headers"
    echo "registry-seed: cannot read the registry version (transport rc=$GRC $(head -c 200 "$TMP/curl.err")); not proven empty, nothing imported" >&2; exit 1
  fi
  GHTTP="${GOUT##*$'\n'}"; GBODY="${GOUT%$'\n'*}"
  GV=$(jq -er '.version | select(type == "number")' <<<"$GBODY" 2>/dev/null)
  if [ "$GHTTP" = 200 ] && [ -n "$GV" ] && [ "$GV" -ge 1 ] 2>/dev/null; then
    rm -f "$TMP/headers"
    echo "registry-seed: the registry is already seeded (v$GV); the committed files are an export now, not an input. Use bin/registry.sh for a change, --from-export <snapshot> to restore, --force to overwrite from the files." >&2
    exit 1
  elif [ "$GHTTP" = 200 ] && [ "$GV" = 0 ]; then :
  elif [ "$GHTTP" = 503 ] && [ "$(jq -r '.error // empty' <<<"$GBODY" 2>/dev/null)" = "registry schema not applied" ]; then :
  else
    rm -f "$TMP/headers"
    echo "registry-seed: GET /api/registry/version answered http=$GHTTP $(head -c 200 <<<"$GBODY"); not proven empty, nothing imported" >&2
    exit 1
  fi
fi
OUT=$(curl -sS -m "${JOBS_TIMEOUT:-30}" --connect-timeout 3 -w $'\n%{http_code}' -X POST \
  -H "@$TMP/headers" --data-binary "@$TMP/payload.json" "$JOBS_URL/api/registry/import" 2>"$TMP/curl.err")
RC=$?
rm -f "$TMP/headers"
if [ "$RC" -ne 0 ]; then echo "registry-seed: transport rc=$RC $(head -c 200 "$TMP/curl.err")" >&2; exit 1; fi
HTTP="${OUT##*$'\n'}"; BODY="${OUT%$'\n'*}"
case "$HTTP" in
  2*) jq -er 'select(.ok == true and (.version | type == "number"))
        | "registry-seed: changed=\(.changed) version=\(.version) stale=\(.stale | length)"' <<<"$BODY" 2>/dev/null \
        || { echo "registry-seed: http=$HTTP but the answer is not an import result: $(head -c 200 <<<"$BODY")" >&2; exit 1; } ;;
  *) echo "registry-seed: http=$HTTP $(head -c 200 <<<"$BODY")" >&2; exit 1 ;;
esac
