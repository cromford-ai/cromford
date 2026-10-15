#!/bin/bash
# tests/lane-fleet-image.bh-6817-test.sh — BH-6817 item 4: lane-fleet logs the
# image a lane-run machine runs, its digest and the harness commit the image
# carries (the `harness.commit` label of fly/lane-run.Dockerfile).
#
# Driven through a REAL bin/lane-fleet.sh tick (bin/lib/lane-fleet-image.sh
# lfi_log_images) with the stub flyctl of tests/lane-fleet.bh-6126-test.sh on
# LANE_FLEET_FLY, against the REAL jobs worker
# (tests/lib/lane-fleet-worker.bh-6126.mjs).
#
#   I1  a started machine with digest d1 and harness.commit=<40 hex> -> one
#       `image` line with both
#   I2  the next tick, same digest -> no line; a new digest -> a line again;
#       the state file holds only the listed started machines
#   I3  no labels -> harness_commit=unknown; no image_ref -> digest=-
#   I4  a `machine run` start logs `image=<lane_fleet.image>`; a reused
#       stopped machine logs the image Fly lists for it
#
# Run from anywhere: tests/lane-fleet-image.bh-6817-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/lane-fleet-worker.bh-6126.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v python3 >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or python3 missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$T/fx"
# BH-6741: the tick loads the Fly token from env/fly.env and makes no Fly call without one.
printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$H/env/fly.env"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$REPO/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -x "$H/bin/lane-fleet.sh" ] && ok "closure installs bin/lane-fleet.sh" || bad "closure lacks bin/lane-fleet.sh"

# The stub flyctl: argv to fx/fly.argv, answers from fx/ files.
FX="$T/fx"
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
case "\$1 \$2" in
  "machine list") if [ -f "$FX/list.fail" ]; then echo "Error: fixture list failure" >&2; exit 1; fi; cat "$FX/list.json" ;;
  "machine run") cat "$FX/run.out" ;;
  "machine start") if [ -f "$FX/start.fail" ]; then echo "Error: fixture start failure" >&2; exit 1; fi; echo "fixture started" ;;
  "machine stop") echo "fixture stopped" ;;
  "machine destroy") cat "$FX/destroy.out" 2>/dev/null; exit "\$(cat "$FX/destroy.rc" 2>/dev/null || echo 0)" ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl"
NOW0=1791000030   # 2026-10-03T04:00:30Z
export LANE_GATE_NOW=$NOW0

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
# fresh <epoch> — a new worker with an empty database, its clock at <epoch>;
# clears the stub's files, the logs and the alert flags.
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  NOW=$1; export LANE_FLEET_NOW=$1
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$1" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list.json"
  printf 'Machine ID: %s\nState: created\n' fixturenew01 > "$FX/run.out"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-fleet.log"; rm -f "$H/flags/"alerted-lane-fleet-*
}
clock() { NOW=$1; export LANE_FLEET_NOW=$1; curl -sS -X PUT "$JOBS_URL/__clock" -d "{\"epoch\":$1}" >/dev/null; }
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL$2" ${3:+-d "$3"}; }
# row <mid> <state> <started epoch> — a lane_machines row through the real route.
row() { api POST /api/lane-fleet/machines "$(jq -nc --arg m "$1" --arg s "$2" --arg a "$(iso "$3")" \
  '{machine_id:$m, state:$s, started_at:$a, cpu_kind:"shared", cpus:2, memory_mb:2048}')" >/dev/null; }
# listing <id>:<state>:<updated epoch> ... — the stub's `machine list --json`.
listing() { local a out="[]" id st up
  for a in "$@"; do IFS=: read -r id st up <<<"$a"
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso "$up")" \
      '. + [{id:$i, state:$s, created_at:$u, updated_at:$u, config:{image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:"shared", cpus:2, memory_mb:2048}}}]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list.json"; }
# queued <seconds ago> — one queued lane_runs row.
queued() { sql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES ('demo','p1','[\"bin/x.sh\"]',?,'queued')" "$(iso $((NOW - $1)))" >/dev/null; }
tick() { bash "$H/bin/lane-fleet.sh" tick; TRC=$?; LAST=$(tail -n 1 "$H/logs/lane-fleet.log"); }
nfly() { grep -c -- "$1" "$FX/fly.argv"; }
nalerts() { grep -c "$1" "$H/logs/ALERTS.log"; }
lm() { sql "SELECT machine_id, state FROM lane_machines ORDER BY machine_id" | jq -r '.rows[] | "\(.machine_id)=\(.state)"' | tr '\n' ' '; }

[ -f "$REPO/bin/lib/lane-fleet-image.sh" ] && [ -f "$H/bin/lib/lane-fleet-image.sh" ] && ok "closure installs bin/lib/lane-fleet-image.sh" || bad "closure lacks bin/lib/lane-fleet-image.sh"
HC=0123456789abcdef0123456789abcdef01234567
# ilisting <id>:<state>:<digest|->:<commit|-|none> ... — a listing with image_ref.
# digest `-` = no image_ref at all; commit `-` = no labels.
ilisting() { local a out="[]" id st dg hc
  for a in "$@"; do IFS=: read -r id st dg hc <<<"$a"
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso $((NOW - 1000)))" --arg d "$dg" --arg h "$hc" '
      . + [{id:$i, state:$s, created_at:$u, updated_at:$u,
            config:{image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:"shared", cpus:2, memory_mb:2048}}}
           + (if $d == "-" then {} else {image_ref:({registry:"registry.fly.io", repository:"lane-run", tag:"latest", digest:("sha256:"+$d)}
              + (if $h == "-" then {} else {labels:{"harness.commit":$h}} end))} end)]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list.json"; }
nimg() { grep -c " \[lane-fleet\] image $1 " "$H/logs/lane-fleet.log"; }
imgline() { grep " \[lane-fleet\] image $1 " "$H/logs/lane-fleet.log" | tail -n 1 | sed 's/.*\[lane-fleet\] //'; }

# ============================================================================
echo "I1: a started machine with a digest and a harness.commit label"
fresh $NOW0
row fixtureimg01 started $((NOW0 - 1000)); ilisting "fixtureimg01:started:d1:$HC"; tick
[ "$TRC" = 0 ] && ok "I1 tick rc 0" || bad "I1 rc=$TRC"
[ "$(imgline fixtureimg01)" = "image fixtureimg01 registry.fly.io/lane-run:latest digest=sha256:d1 harness_commit=$HC" ] \
  && ok "I1 one image line with the digest and the commit" || bad "I1 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(nimg fixtureimg01)" = 1 ] && ok "I1 exactly one line" || bad "I1 lines: $(nimg fixtureimg01)"
case "$LAST" in *"[lane-fleet] tick "*) ok "I1 the tick line is still the last line" ;; *) bad "I1 last: $LAST" ;; esac

# ============================================================================
echo "I2: the same digest logs once; a new digest logs again"
tick
[ "$(nimg fixtureimg01)" = 1 ] && ok "I2 the next tick, same digest: no line" || bad "I2 lines: $(nimg fixtureimg01)"
ilisting "fixtureimg01:started:d2:$HC"; tick
[ "$(nimg fixtureimg01)" = 2 ] && grep -q 'digest=sha256:d2' <<<"$(imgline fixtureimg01)" && ok "I2 a new digest: a second line" \
  || bad "I2 new digest: $(cat "$H/logs/lane-fleet.log")"
[ "$(cat "$H/state/lane-fleet/images.tsv")" = "$(printf 'fixtureimg01\tsha256:d2')" ] && ok "I2 images.tsv holds the listed machine" \
  || bad "I2 tsv: $(cat "$H/state/lane-fleet/images.tsv")"

# ============================================================================
echo "I3: no labels, no image_ref"
fresh $NOW0
row fixtureimg02 started $((NOW0 - 1000)); row fixtureimg03 started $((NOW0 - 1000))
ilisting "fixtureimg02:started:d3:-" "fixtureimg03:started:-:-"; tick
[ "$(imgline fixtureimg02)" = "image fixtureimg02 registry.fly.io/lane-run:latest digest=sha256:d3 harness_commit=unknown" ] \
  && ok "I3 no labels -> harness_commit=unknown" || bad "I3 log: $(cat "$H/logs/lane-fleet.log")"
[ "$(imgline fixtureimg03)" = "image fixtureimg03 - digest=- harness_commit=unknown" ] \
  && ok "I3 no image_ref -> digest=-" || bad "I3 log: $(cat "$H/logs/lane-fleet.log")"
grep -q 'fixtureimg01' "$H/state/lane-fleet/images.tsv" && bad "I3 a machine no longer listed stays in the tsv" || ok "I3 the tsv is bounded by the listing"

# ============================================================================
echo "I4: the start line names the image"
fresh $NOW0; queued 300; tick
grep -q '\[lane-fleet\] start fixturenew01: machine run image=registry.fly.io/lane-run:latest$' "$H/logs/lane-fleet.log" \
  && ok "I4 machine run: image=registry.fly.io/lane-run:latest" || bad "I4 log: $(cat "$H/logs/lane-fleet.log")"
fresh $NOW0; ilisting "fixturestop2:stopped:d9:$HC"; tick
grep -q "\[lane-fleet\] start fixturestop2: machine start image=registry.fly.io/lane-run:latest digest=sha256:d9 harness_commit=$HC\$" "$H/logs/lane-fleet.log" \
  && ok "I4 machine start: the image Fly lists for the reused machine" || bad "I4 reuse log: $(cat "$H/logs/lane-fleet.log")"

# ============================================================================
echo "I5: the Dockerfile's stamp line, run as shipped under sh"
# The RUN line that writes /opt/harness/HARNESS_COMMIT, joined, aimed at a
# scratch root. No docker on a test box, so the line itself is what runs.
STAMP=$(awk '/^RUN if printf/ {on=1} on {sub(/\\$/, ""); printf "%s ", $0; if ($0 !~ /\\ *$/ && $0 ~ /fi$/) exit}' "$REPO/fly/lane-run.Dockerfile" | sed 's/^RUN //')
case "$STAMP" in *HARNESS_COMMIT*/opt/harness/HARNESS_COMMIT*) ok "I5 the stamp line is found" ;; *) bad "I5 no stamp line: $STAMP" ;; esac
mkdir -p "$T/img"
for v in "$HC:yes" "abc1234:yes" "unknown:no" "ABCDEF1:no" "abc12:no"; do
  rm -f "$T/img/HARNESS_COMMIT"
  HARNESS_COMMIT="${v%%:*}" sh -c "${STAMP//\/opt\/harness/$T/img}"
  if [ "${v##*:}" = yes ]; then
    [ "$(cat "$T/img/HARNESS_COMMIT" 2>/dev/null)" = "${v%%:*}" ] && ok "I5 ${v%%:*} is written" || bad "I5 ${v%%:*} not written"
  else
    [ ! -e "$T/img/HARNESS_COMMIT" ] && ok "I5 ${v%%:*} writes no file" || bad "I5 ${v%%:*} wrote $(cat "$T/img/HARNESS_COMMIT")"
  fi
done
grep -q '^ARG HARNESS_COMMIT=unknown$' "$REPO/fly/lane-run.Dockerfile" && grep -q '^LABEL harness.commit=\$HARNESS_COMMIT$' "$REPO/fly/lane-run.Dockerfile" \
  && ok "I5 the image carries the harness.commit label" || bad "I5 no ARG/LABEL"

echo "lane-fleet-image: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
