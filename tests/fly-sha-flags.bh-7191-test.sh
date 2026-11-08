#!/bin/bash
# tests/fly-sha-flags.bh-7191-test.sh — BH-7305 (BH-7191 child C4): Fly
# machines carry the harness sha they booted with as `--metadata harness_sha`,
# and every job start record sends the sha the job ran as `harness_commit`.
#
# PINNED:
#   P1-P4  DRIVEN (`bash bin/fly-pool.sh project-5` against a scratch $HARNESS):
#          a push spawn from a git checkout -> `--metadata harness_sha=<HEAD>`;
#          no git HEAD -> no flag and the launch still runs; a push spawn never
#          gets `-e HARNESS_SHA` (fly/entrypoint.sh reads it as "pull this
#          sha"); a pull spawn gets `--metadata` and `-e HARNESS_SHA`.
#   C1-C3  psr_claim_machine (the REAL lib, stub _jobs_req): the 4th arg sha
#          rides in the body as harness_commit; empty -> no key; 3 args ->
#          $HARNESS/HARNESS_COMMIT when it is a sha.
#   H1-H8  lfi_image_commit / lfi_machine_commit (the REAL lib) on fixture
#          listings: tag match, digest match, `unknown` -> empty, another tag
#          -> empty, empty listing -> empty, newest created_at wins.
#   L1-L4  DRIVEN (`bash bin/lane-fleet.sh tick` against the REAL jobs worker,
#          tests/lib/lane-fleet-worker.bh-6126.mjs): a new machine run gets both
#          flags and its lane_machines row the sha; no label / `unknown` -> no
#          flag and a NULL row; a reuse records the machine's own label.
#   W1-W2  DRIVEN (`bin/lane-run-worker.sh --once` against the REAL jobs worker,
#          tests/lib/lane-runs-worker.bh-6124.mjs): the claimed run's
#          GET /api/lane-runs/<id> carries $H/HARNESS_COMMIT; no file -> null.
# Run from anywhere: bash tests/fly-sha-flags.bh-7191-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
SHA_RE='^[0-9a-f]{40}$'

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT

# ══ the driven pool (scaffold of tests/fly-pool-rootfs.bh-8640) ═════════════
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/state/build-notes/project-5" \
         "$H/state/vercel-deploys" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_PROJECT_5=tok-fixture-fly\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
cat > "$H/bin/lib/pool-account.sh" <<'PA'
#!/bin/bash
pool_account_lease() { echo "name=default reason=unarmed"; }
pool_account_rebind() { return 0; }
pool_account_release() { return 0; }
pool_account_others_ok() { return 1; }
pool_account_prune() { :; }
pool_account_armed() { return 1; }
pool_account_cooldown() { :; }
pool_account_unpin() { :; }
PA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" \
   "$DIR/bin/alert-line.sh" "$DIR/bin/fly-envbundle.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/ssh" <<'SSH'
#!/bin/bash
printf '===GLOBAL===\n'
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude-base\nHARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.invalid\n'
printf 'OPENROUTER_API_KEY=fixture-or\nGH_TOKEN=fixture-pat\n'
printf '===PROJECT===\n'
printf 'BOARD_TOKEN=fixture-board\n'
exit 0
SSH
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$*" in
  *"secrets list"*) echo '[{"Name":"HBUNDLE_G_HARNESS_SECRET","Digest":"d1"},{"Name":"HBUNDLE_SYNCED_AT","Digest":"d2"}]' ;;
  *"secrets import"*) cat > /dev/null ;;
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run --help"*) printf 'Usage:\n  flyctl machine run <image> [flags]\n      --vm-size string\n' ;;
  *"machine run"*) printf 'Machine ID: 0123456789abcd\n' ;;
esac
exit 0
FLY
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" =~ issues/[0-9]+ ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" =~ git/ref/heads/ticket/bh-[0-9]+ ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
printf '{}\n404\n'
STUB
printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
cat > "$H/bin/gh-token.sh" <<'GT'
#!/bin/bash
case " $* " in
  *" --installation-id "*) echo 4242 ;;
  *" --expires-at "*) echo 2026-11-02T05:00:00Z ;;
  *" --extra-read "*) echo tok-fixture-read ;;
  *) echo tok-fixture-app ;;
esac
exit 0
GT
chmod +x "$H/bin"/*.sh "$T/fakebin"/*
# The harness checkout: ${HARNESS}-checkout is what the pull path pins; the
# push path tars POOL_HARNESS_SRC (never the box's /root/harness-checkout).
HCO="$H-checkout"
mkdir -p "$HCO/bin" "$HCO/prompts" "$HCO/rules" "$HCO/catalog" "$HCO/fly"
echo fixture > "$HCO/bin/x"; echo fixture > "$HCO/fleet.conf"
for d in prompts rules catalog fly; do echo fixture > "$HCO/$d/x"; done
git -C "$HCO" init -q && git -C "$HCO" -c user.email=t@t -c user.name=t add -A \
  && git -C "$HCO" -c user.email=t@t -c user.name=t commit -qm fixture
HEAD_SHA=$(git -C "$HCO" rev-parse HEAD)
NOGIT="$T/nogit"
mkdir -p "$NOGIT/bin" "$NOGIT/prompts" "$NOGIT/rules" "$NOGIT/catalog" "$NOGIT/fly"
echo fixture > "$NOGIT/fleet.conf"

POOLD="$H/state/fly-pool/project-5"; QD="$H/state/build-queue/project-5"
run_pool() { # run_pool [VAR=val ...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 FLY_SINK="$T/fly.txt" \
           FLY_API_TOKEN_PROJECT_5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_case() { # reset_case <key>
  local p
  for p in "$QD"/* "$QD"/.??* "$POOLD"/*.json "$POOLD"/.??* "$H/state/pool/project-5"/* \
           "$H/state/build-notes/project-5"/* "$H/state/vercel-deploys"/* "$H/state/settings-cache.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$T/fly.txt"; : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  jq -nc --arg k "$1" --arg id "${1#BH-}" '{ticket_id:$id,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-11-02T00:00:00Z"}' > "$QD/$1.json"
  return 0
}
plog() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
runline() { grep 'fly machine run' "$T/fly.txt" | grep -v -- 'machine run --help' | head -1; }

echo "P1-P3: a push spawn"
[[ "$HEAD_SHA" =~ $SHA_RE ]] && ok "P0 the fixture checkout has a git HEAD" || bad "P0 no HEAD in the fixture checkout"
reset_case BH-7311
run_pool POOL_HARNESS_SRC="$HCO" POOL_MACHINE_PULL=0
L=$(runline)
grep -q -- " --metadata harness_sha=$HEAD_SHA " <<<"$L " && ok "P1 --metadata harness_sha=<the stamped HEAD>" \
  || bad "P1 the push argv must carry --metadata harness_sha=$HEAD_SHA: $L / $(tail -n 3 "$H/logs/fly-pool.log")"
grep -q -- '-e HARNESS_SHA=' <<<"$L" && bad "P3 a push spawn must not get -e HARNESS_SHA: $L" || ok "P3 no -e HARNESS_SHA on the push path"
grep -q 'spawned 0123456789abcd for BH-7311' "$H/logs/fly-pool.log" && ok "P1 the spawn lands" || bad "P1 no spawn: $(plog)"

reset_case BH-7312
run_pool POOL_HARNESS_SRC="$NOGIT" POOL_MACHINE_PULL=0
L=$(runline)
[ -n "$L" ] && ok "P2 with no git HEAD the launch still runs" || bad "P2 no machine run: $(plog)"
grep -q -- '--metadata' <<<"$L" && bad "P2 no stamp must give no --metadata: $L" || ok "P2 no --metadata"
grep -q -- 'HARNESS_SHA' <<<"$L" && bad "P2 no stamp must give no HARNESS_SHA: $L" || ok "P2 no HARNESS_SHA"
grep -q 'ships with no HARNESS_COMMIT stamp' "$H/logs/fly-pool.log" && ok "P2 the existing no-stamp line" || bad "P2 log: $(plog)"

echo "P4: a pull spawn"
reset_case BH-7314
run_pool POOL_HARNESS_SRC="$HCO" POOL_MACHINE_PULL=1
L=$(runline)
grep -q -- " -e HARNESS_SHA=$HEAD_SHA " <<<"$L " && ok "P4 -e HARNESS_SHA=<the pinned sha> (the pull path)" \
  || bad "P4 precondition: the pull path must send -e HARNESS_SHA=$HEAD_SHA: $L / $(plog)"
grep -q -- " --metadata harness_sha=$HEAD_SHA " <<<"$L " && ok "P4 --metadata harness_sha=<the pinned sha>" \
  || bad "P4 the pull argv must carry --metadata harness_sha=$HEAD_SHA: $L"
[ "$(grep -o -- '--metadata' <<<"$L" | wc -l | tr -d ' ')" = 1 ] && ok "P4 one --metadata flag" || bad "P4 metadata count: $L"

# ══ C: psr_claim_machine, the real lib ══════════════════════════════════════
echo "C1-C3: psr_claim_machine"
PSR="$DIR/bin/lib/pool-state-rows.sh"
mkdir -p "$T/ch"
# cbody <harness-root> <args...> -> the body _jobs_req got
cbody() {
  local root="$1"; shift
  env -i PATH="$PATH" HARNESS="$root" JOBS_BOX=hub OUT="$OUT" bash -c '
    _jobs_req() { printf "%s\n" "$3" > "$OUT"; }
    . "$1" || exit 9; shift; psr_claim_machine "$@"' _ "$PSR" "$@" 2>/dev/null
}
OUT="$T/cbody.json"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd "$HEAD_SHA"
[ "$(jq -r '.harness_commit // "absent"' "$OUT")" = "$HEAD_SHA" ] && [ "$(jq -r .machine "$OUT")" = 0123456789abcd ] \
  && ok "C1 the 4th arg rides as harness_commit" || bad "C1 body: $(cat "$OUT")"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd ""
[ "$(jq -r 'has("harness_commit")' "$OUT")" = false ] && [ "$(jq -r .key "$OUT")" = BH-1 ] \
  && ok "C2 an empty 4th arg sends no harness_commit" || bad "C2 body: $(cat "$OUT")"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd main
[ "$(jq -r 'has("harness_commit")' "$OUT")" = false ] && ok "C2 a 4th arg 'main' sends no harness_commit" || bad "C2 main body: $(cat "$OUT")"
printf '%s\n' "$HEAD_SHA" > "$T/ch/HARNESS_COMMIT"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd
[ "$(jq -r '.harness_commit // "absent"' "$OUT")" = "$HEAD_SHA" ] && ok "C3 3 args read \$HARNESS/HARNESS_COMMIT" || bad "C3 body: $(cat "$OUT")"
printf 'main\n' > "$T/ch/HARNESS_COMMIT"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd
[ "$(jq -r 'has("harness_commit")' "$OUT")" = false ] && ok "C3 'main' in the file sends no key" || bad "C3 main body: $(cat "$OUT")"
printf '%s\n' "$HEAD_SHA" > "$T/ch/HARNESS_COMMIT"
: > "$OUT"; cbody "$T/ch" alpha-os BH-1 0123456789abcd ""
[ "$(jq -r 'has("harness_commit")' "$OUT")" = false ] && ok "C3 4 args never read the file (the hub's own tree)" || bad "C3 4-arg body: $(cat "$OUT")"

# ══ H: the label helpers, the real lib ══════════════════════════════════════
echo "H1-H8: lfi_image_commit / lfi_machine_commit"
LFI="$DIR/bin/lib/lane-fleet-image.sh"
SA=0123456789abcdef0123456789abcdef01234567; SB=fedcba9876543210fedcba9876543210fedcba98
# hm <id>:<tag>:<digest>:<label|->:<created> -> one listing machine
hlist() { local a out="[]" id tg dg lb cr
  for a in "$@"; do IFS=: read -r id tg dg lb cr <<<"$a"
    out=$(jq -c --arg i "$id" --arg t "$tg" --arg d "$dg" --arg l "$lb" --arg c "2026-11-0${cr}T00:00:00Z" '
      . + [{id:$i, state:"started", created_at:$c,
            image_ref:({registry:"registry.fly.io", repository:"lane-run", tag:$t, digest:("sha256:"+$d)}
              + (if $l == "-" then {} else {labels:{"harness.commit":$l}} end))}]' <<<"$out")
  done; printf '%s\n' "$out" > "$T/hl.json"; }
hic() { env -i PATH="$PATH" bash -c '. "$1" || exit 9; lfi_image_commit "$2" "$3"' _ "$LFI" "$T/hl.json" "$1" 2>/dev/null; }
hmc() { env -i PATH="$PATH" bash -c '. "$1" || exit 9; lfi_machine_commit "$2" "$3"' _ "$LFI" "$T/hl.json" "$1" 2>/dev/null; }
hlist "m1:latest:d1:$SA:1"
[ "$(hic registry.fly.io/lane-run:latest)" = "$SA" ] && ok "H1 tag match -> the label" || bad "H1 got '$(hic registry.fly.io/lane-run:latest)'"
[ "$(hic registry.fly.io/lane-run@sha256:d1)" = "$SA" ] && ok "H2 digest match -> the label" || bad "H2 got '$(hic registry.fly.io/lane-run@sha256:d1)'"
[ -z "$(hic registry.fly.io/lane-run@sha256:d2)" ] && ok "H2 another digest -> empty" || bad "H2 other digest got '$(hic registry.fly.io/lane-run@sha256:d2)'"
hlist "m1:latest:d1:unknown:1"
[ -z "$(hic registry.fly.io/lane-run:latest)" ] && ok "H3 label unknown -> empty" || bad "H3 got '$(hic registry.fly.io/lane-run:latest)'"
hlist "m1:latest:d1:-:1"
[ -z "$(hic registry.fly.io/lane-run:latest)" ] && ok "H3 no label -> empty" || bad "H3 no label got '$(hic registry.fly.io/lane-run:latest)'"
hlist "m1:deploy-01:d1:$SA:1"
[ -z "$(hic registry.fly.io/lane-run:latest)" ] && ok "H4 another tag -> empty" || bad "H4 got '$(hic registry.fly.io/lane-run:latest)'"
printf '[]\n' > "$T/hl.json"
[ -z "$(hic registry.fly.io/lane-run:latest)" ] && ok "H5 empty listing -> empty" || bad "H5 got '$(hic registry.fly.io/lane-run:latest)'"
printf 'not json\n' > "$T/hl.json"
[ -z "$(hic registry.fly.io/lane-run:latest)" ] && ok "H5 unreadable listing -> empty" || bad "H5 bad json got '$(hic registry.fly.io/lane-run:latest)'"
hlist "m1:latest:d1:$SA:1" "m2:latest:d1:$SB:3" "m3:latest:d1:$SA:2"
[ "$(hic registry.fly.io/lane-run:latest)" = "$SB" ] && ok "H6 two matches -> the newest created_at" || bad "H6 got '$(hic registry.fly.io/lane-run:latest)'"
[ "$(hmc m3)" = "$SA" ] && [ "$(hmc m2)" = "$SB" ] && ok "H7 lfi_machine_commit -> that machine's label" || bad "H7 got '$(hmc m3)' / '$(hmc m2)'"
hlist "m1:latest:d1:main:1"
[ -z "$(hmc m1)" ] && [ -z "$(hmc nosuch)" ] && ok "H8 a non-sha label or no machine -> empty" || bad "H8 got '$(hmc m1)' / '$(hmc nosuch)'"

# ══ the jobs worker the lane tests drive ═══════════════════════════════════
# start_worker <server.mjs> <name> [epoch] -> sets JOBS_URL; rc 3 = no node:sqlite
start_worker() {
  local pid i
  : > "$T/$2.port"
  node "$1" "$T/$2.log" ${3:+"$3"} > "$T/$2.port" 2> "$T/$2.err" &
  pid=$!; PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/$2.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  WPORT=$(head -1 "$T/$2.port")
  if [ -z "$WPORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$WPORT"
}
NODE_OK=1
command -v node >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || NODE_OK=0
if [ "$NODE_OK" = 1 ]; then
  "$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { bad "setup: cannot compose catalog/llm-sites.json"; NODE_OK=0; }
  [ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
    || { bad "setup: cannot compose catalog/lanes.json"; NODE_OK=0; }
  [ -f "$DIR/catalog/context-budgets.json" ] || "$DIR/bin/context-budgets-build.sh" --compose >/dev/null \
    || { bad "setup: cannot compose catalog/context-budgets.json"; NODE_OK=0; }
else
  bad "setup: node, flock or python3 missing: the L and W sections cannot run"
fi

# ══ L: the lane-fleet launch, driven ════════════════════════════════════════
if [ "$NODE_OK" = 1 ]; then
echo "L1-L4: bin/lane-fleet.sh"
LH="$T/lh"; FX="$T/fx"
mkdir -p "$LH/bin" "$LH/logs" "$LH/locks" "$LH/state" "$LH/env" "$LH/flags" "$LH/catalog" "$FX"
printf 'FLY_API_TOKEN=fixture-fly-token\n' > "$LH/env/fly.env"
for L in bin/lane-fleet.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$LH" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$DIR/catalog/fly-prices.json" "$LH/catalog/fly-prices.json"
chmod +x "$LH/bin/"*.sh 2>/dev/null
cat > "$T/flyctl" <<EOF
#!/bin/bash
echo "\$*" >> "$FX/fly.argv"
case "\$1 \$2" in
  "machine list") cat "$FX/list.json" ;;
  "machine run") printf 'Machine ID: fixturenew01\nState: created\n' ;;
  "machine start") echo "fixture started" ;;
  "machine stop") echo "fixture stopped" ;;
  "machine destroy") exit 0 ;;
  *) echo "stub: unknown \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$T/flyctl"
LNOW=1791000030
lf_fresh() {
  rm -f "$FX"/*; : > "$FX/fly.argv"; echo '[]' > "$FX/list.json"
  : > "$LH/logs/ALERTS.log"; : > "$LH/logs/lane-fleet.log"; rm -f "$LH/flags/"alerted-lane-fleet-*
  scratch_rm "$LH/state/lane-fleet"
  start_worker "$DIR/tests/lib/lane-fleet-worker.bh-6126.mjs" "lfw$1" "$LNOW"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
lsql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
queued() { lsql "INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status) VALUES ('demo','p1','[\"bin/x.sh\"]',?,'queued')" "$(iso $((LNOW - 300)))" >/dev/null; }
# llist <id>:<state>:<label|-> ... — machines of registry.fly.io/lane-run:latest
llist() { local a out="[]" id st lb
  for a in "$@"; do IFS=: read -r id st lb <<<"$a"
    out=$(jq -c --arg i "$id" --arg s "$st" --arg u "$(iso $((LNOW - 1000)))" --arg l "$lb" '
      . + [{id:$i, state:$s, created_at:$u, updated_at:$u,
            config:{image:"registry.fly.io/lane-run:latest", guest:{cpu_kind:"shared", cpus:2, memory_mb:2048}},
            image_ref:({registry:"registry.fly.io", repository:"lane-run", tag:"latest", digest:"sha256:d1"}
              + (if $l == "-" then {} else {labels:{"harness.commit":$l}} end))}]' <<<"$out")
  done; printf '%s\n' "$out" > "$FX/list.json"; }
ltick() { ( export HARNESS="$LH" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub \
              JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 LANE_FLEET_FLY="$T/flyctl" \
              LANE_GATE_NOW=$LNOW LANE_FLEET_NOW=$LNOW
            bash "$LH/bin/lane-fleet.sh" tick ) >/dev/null 2>&1; }
lrow() { lsql "SELECT harness_commit FROM lane_machines WHERE machine_id=?" "$1" | jq -r '.rows[0] | if . == null then "norow" else (.harness_commit // "null") end'; }
runargv() { grep '^machine run' "$FX/fly.argv" | head -1; }
llog() { cat "$LH/logs/lane-fleet.log"; }

# L1: a labelled machine of $IMAGE exists (it is failed, so not reused); a new run
if lf_fresh 1; then
  llist "fixturefail1:failed:$SA"; queued; ltick
  A=$(runargv)
  [ -n "$A" ] && ok "L1 precondition: the tick runs a new machine" || bad "L1 precondition: no machine run: $(cat "$FX/fly.argv") / $(llog)"
  grep -q -- " --metadata harness_sha=$SA " <<<"$A " && ok "L1 --metadata harness_sha=<label>" || bad "L1 argv: $A"
  grep -q -- " -e HARNESS_SHA=$SA " <<<"$A " && ok "L1 -e HARNESS_SHA=<label>" || bad "L1 argv: $A"
  [ "$(lrow fixturenew01)" = "$SA" ] && ok "L1 the lane_machines row stores the label" || bad "L1 row: $(lrow fixturenew01)"
  grep -q '\[lane-fleet\] start fixturenew01: machine run image=registry.fly.io/lane-run:latest$' "$LH/logs/lane-fleet.log" \
    && ok "L1 the start log line is unchanged" || bad "L1 log: $(llog)"
else bad "L setup: the lane-fleet worker did not start: $(cat "$T/lfw1.err")"; fi

# L2: no labelled machine -> no flag, a NULL row
if lf_fresh 2; then
  llist "fixturefail1:failed:-"; queued; ltick
  A=$(runargv)
  [ -n "$A" ] && ok "L2 precondition: the tick runs a new machine" || bad "L2 precondition: no machine run: $(llog)"
  grep -q -- 'harness_sha\|HARNESS_SHA' <<<"$A" && bad "L2 no label must give no sha flag: $A" || ok "L2 neither flag"
  [ "$(lrow fixturenew01)" = null ] && ok "L2 the row's harness_commit is NULL" || bad "L2 row: $(lrow fixturenew01)"
else bad "L2 setup: the lane-fleet worker did not start"; fi

# L3: label unknown -> no flag, a NULL row
if lf_fresh 3; then
  llist "fixturefail1:failed:unknown"; queued; ltick
  A=$(runargv)
  [ -n "$A" ] && ok "L3 precondition: the tick runs a new machine" || bad "L3 precondition: no machine run: $(llog)"
  grep -q -- 'harness_sha\|HARNESS_SHA' <<<"$A" && bad "L3 label unknown must give no sha flag: $A" || ok "L3 neither flag"
  [ "$(lrow fixturenew01)" = null ] && ok "L3 the row's harness_commit is NULL" || bad "L3 row: $(lrow fixturenew01)"
else bad "L3 setup: the lane-fleet worker did not start"; fi

# L4: a reuse records the reused machine's own label; machine start gets no flag
if lf_fresh 4; then
  llist "fixturestop2:stopped:$SB" "fixturefail1:failed:$SA"; queued; ltick
  S=$(grep '^machine start' "$FX/fly.argv" | head -1)
  [ -n "$S" ] && ok "L4 precondition: the tick reuses the stopped machine" || bad "L4 precondition: no machine start: $(cat "$FX/fly.argv") / $(llog)"
  [ "$S" = "machine start fixturestop2 -a lane-run" ] && ok "L4 machine start carries no new flag" || bad "L4 start argv: $S"
  [ "$(lrow fixturestop2)" = "$SB" ] && ok "L4 the row stores the reused machine's own label" || bad "L4 row: $(lrow fixturestop2)"
else bad "L4 setup: the lane-fleet worker did not start"; fi
fi

# ══ W: the lane-run claim, driven ═══════════════════════════════════════════
if [ "$NODE_OK" = 1 ]; then
echo "W1-W2: bin/lane-run-worker.sh --once"
WH="$T/wh"
mkdir -p "$WH/bin" "$WH/logs" "$WH/locks" "$WH/state" "$WH/env" "$WH/flags"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$WH" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$WH/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$WH/bin/lane-alert.sh"
printf '#!/bin/bash\necho "PROF okay x=1"\nexit 0\n' > "$WH/bin/okay.sh"
chmod +x "$WH/bin/"*.sh 2>/dev/null
if start_worker "$DIR/tests/lib/lane-runs-worker.bh-6124.mjs" lrw; then
  wapi() { curl -sS -X "$1" -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' ${3:+-d "$3"} "$JOBS_URL$2"; }
  wenq() { wapi POST /api/lane-runs "$(jq -nc --arg l "$1" '{lane:$l,project:"p1",args:["bin/okay.sh"]}')" | jq -r .id; }
  wwork() { ( export HARNESS="$WH" FLEET_CONF="$WH/fleet.conf" HARNESS_SECRET=fixture-harness-secret \
                GH_TOKEN=tok-fixture-default JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
                BOX_NAME=fixture-box LANE_RUN_NOW=1791000000
              "$WH/bin/lane-run-worker.sh" --once --machine m1 ) > "$T/work.out" 2>&1; }
  wsha() { wapi GET "/api/lane-runs/$1" | jq -r '.run | if has("harness_commit") then (.harness_commit // "null") else "absent" end'; }
  printf '%s\n' "$SA" > "$WH/HARNESS_COMMIT"
  ID=$(wenq lane-w1); wwork
  [ "$(wapi GET "/api/lane-runs/$ID" | jq -r .run.claimed_by)" = m1 ] && ok "W1 precondition: m1 claimed the run" || bad "W1 precondition: $(wapi GET "/api/lane-runs/$ID") / $(cat "$T/work.out")"
  [ "$(wsha "$ID")" = "$SA" ] && ok "W1 the run carries \$H/HARNESS_COMMIT" || bad "W1 harness_commit: $(wsha "$ID")"
  scratch_rm "$WH/HARNESS_COMMIT"
  ID=$(wenq lane-w2); wwork
  [ "$(wapi GET "/api/lane-runs/$ID" | jq -r .run.claimed_by)" = m1 ] && ok "W2 precondition: m1 claimed the run" || bad "W2 precondition: $(cat "$T/work.out")"
  [ "$(wsha "$ID")" = null ] && ok "W2 no HARNESS_COMMIT file -> null" || bad "W2 harness_commit: $(wsha "$ID")"
else
  bad "W setup: the lane-runs worker did not start: $(cat "$T/lrw.err")"
fi
fi

echo "fly-sha-flags (BH-7305): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
