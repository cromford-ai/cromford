#!/bin/bash
# bin/cost-caps-seed.sh [--dry-run]            (BH-2565, BH-2511.2)
#
# Turns the two reviewed cap files, catalog/cost-caps.conf and
# catalog/lane-caps.conf, into settings rows under actor `registry-seed`:
# POST /api/cost-caps/seed {rows:[{key,value}]}. The route's contract is
# #2564's: insert absent rows, follow seed rows whose value moved, prune seed
# rows missing from the body, never touch an operator row. Until #2564 merges
# the route is a 501 stub (BH-2563), so a real run exits 1.
#
# bin/harness-sync.sh runs it on every deploy on the hub, through
# bin/cost-caps-seed-sync.sh, whenever either catalog file's bytes moved since
# the last seed that landed (BH-4155): a seed row binds above the file, so this
# is what carries a reviewed catalog edit to the running caps. It is still not
# a cron lane (no lock, no cron line, no lanes.d entry), and running it by hand
# is harmless. `--dry-run` prints the body and sends nothing.
#
# THE KEYS (the ones bin/lib/cost-budget.sh and bin/lib/lane-caps.sh read):
#   cost-caps.conf  budget <p> <rest>   conf.cost-caps.budget.<p>
#                   default <rest>      conf.cost-caps.default
#                   ceiling <rest>      conf.cost-caps.ceiling
#   lane-caps.conf  lane <l> <rest>     conf.lane-caps.lane.<l>
#                   noise <l> <rest>    conf.lane-caps.noise.<l>
#                   default <rest>      conf.lane-caps.default
# The value is the rest of the line with whitespace squeezed to single spaces.
# Everything from the first `#` is a comment, as in _lc_load.
#
# A seed row binds above the catalog file and below an operator row (BH-4155):
# both readers layer the `seeded` rows over the file line, and an operator row
# (or flags/<file>) over the seed (tests/cost-caps.bh-2565-test.sh H2/H3,
# tests/caps-seed-rows.bh-4155-test.sh). worker/jobs/schema.sql seeds the same
# rows on every deploy, INSERT OR IGNORE, which never moves a row that exists:
# only this script makes an existing seed row follow the file.
#
# WHAT IT REFUSES, with nothing sent and exit 1:
#   - either file missing or unreadable. The route (#2564) prunes seed rows absent from
#     the body, so seeding one family alone would delete the other's rows;
#   - zero rows parsed across both files;
#   - a POST that fails, answers non-2xx, or answers 2xx with no changed_keys
#     array. One stderr line names the http code and the head of the answer.
# A line it cannot map (unknown directive, a name that is not a key segment, no
# value) is printed as `skipped:` and left out. A key seen twice takes its last
# line, as the file readers do, and is printed as `duplicate:`. Values are not
# validated here: the route (#2564 W1) refuses the whole request on one bad row.
set -uo pipefail
H="${HARNESS:-/root/harness}"
USAGE="usage: cost-caps-seed.sh [--dry-run]"

dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

COST_F="$H/catalog/cost-caps.conf"
LANE_F="$H/catalog/lane-caps.conf"
for f in "$COST_F" "$LANE_F"; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "cost-caps-seed: $f missing or unreadable — nothing sent" >&2; exit 1; }
done

declare -A VAL
NROWS=0   # a count, not ${#VAL[@]}: an EMPTY associative array is unbound under -u
# _ccs_parse <file> <family> — fills VAL[key]=value and counts NROWS.
_ccs_parse() {
  local file="$1" fam="$2" row n=0 kw name val key
  local -a w
  while IFS= read -r row || [ -n "$row" ]; do
    n=$((n+1))
    row="${row%%#*}"
    read -ra w <<<"$row"
    [ "${#w[@]}" -gt 0 ] || continue
    kw="${w[0]}"; name=""
    case "$fam:$kw" in
      cost:budget|lane:lane|lane:noise) name="${w[1]:-}"; val="${w[*]:2}" ;;
      cost:default|cost:ceiling|lane:default) val="${w[*]:1}" ;;
      *) echo "skipped: $file:$n: unknown directive '$kw'"; continue ;;
    esac
    case "$fam:$kw" in
      cost:default|cost:ceiling|lane:default) key="conf.$fam-caps.$kw" ;;
      *)
        if ! [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
          echo "skipped: $file:$n: bad name '$name'"; continue
        fi
        key="conf.$fam-caps.$kw.$name" ;;
    esac
    [ -n "$val" ] || { echo "skipped: $file:$n: no value"; continue; }
    if [ -n "${VAL[$key]+x}" ]; then echo "duplicate: $key (line $n wins)"; else NROWS=$((NROWS+1)); fi
    VAL[$key]="$val"
  done < "$file"
}
_ccs_parse "$COST_F" cost
_ccs_parse "$LANE_F" lane

[ "$NROWS" -gt 0 ] || { echo "cost-caps-seed: no rows parsed from $COST_F or $LANE_F — nothing sent" >&2; exit 1; }

body=$(for k in "${!VAL[@]}"; do printf '%s\t%s\n' "$k" "${VAL[$k]}"; done \
  | jq -Rn '{rows: ([inputs | split("\t") | {key: .[0], value: .[1]}] | sort_by(.key))}') \
  || { echo "cost-caps-seed: could not build the request body (jq) — nothing sent" >&2; exit 1; }

if [ "$dry" = 1 ]; then
  printf '%s\n' "$body" | jq .
  exit 0
fi

# shellcheck source=bin/jobs-client.sh
if [ -r "$H/bin/jobs-client.sh" ]; then . "$H/bin/jobs-client.sh"
else . "$(dirname "$0")/jobs-client.sh" || { echo "cost-caps-seed: no bin/jobs-client.sh — nothing sent" >&2; exit 1; }; fi

# Not `$( )`: _jobs_req sets JOBS_HTTP/JOBS_BODY in the shell that calls it,
# and a subshell would lose the status the failure line has to name.
outf=$(mktemp "${TMPDIR:-/tmp}/cost-caps-seed.XXXXXX") || { echo "cost-caps-seed: mktemp failed — nothing sent" >&2; exit 1; }
trap 'rm -f "$outf"' EXIT
_jobs_req POST /api/cost-caps/seed "$body" > "$outf"
rc=$?
out=$(cat "$outf")
if [ "$rc" -ne 0 ]; then
  echo "cost-caps-seed: POST /api/cost-caps/seed failed (http=${JOBS_HTTP:-none}): $(head -c 200 < <(printf '%s' "${JOBS_BODY:-}") | tr '\n' ' ')" >&2
  exit 1
fi
if ! printf '%s' "$out" | jq -e '.changed_keys | type == "array"' >/dev/null 2>&1; then
  echo "cost-caps-seed: POST /api/cost-caps/seed answered http=${JOBS_HTTP:-none} without a changed_keys array: $(head -c 200 < <(printf '%s' "$out") | tr '\n' ' ')" >&2
  exit 1
fi
printf '%s' "$out" | jq -r '
  (.changed_keys) as $c | ((.pruned_keys | arrays) // []) as $p
  | "changed_keys: \($c | length)", ($c[] | "  \(.)"),
    "pruned_keys: \($p | length)", ($p[] | "  \(.)")'
exit 0
