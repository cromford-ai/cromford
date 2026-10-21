#!/bin/bash
# tests/fly-pool-machine-pull.bh-7430-test.sh — BH-7430 (BH-6896 S3): the hub's
# spawn ends at ONE `fly machine run` plus the machine record.
#
# The cost (spec note docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md, s.2):
# every spawned job made the hub ssh to the owning box for the env bundle
# (bin/fly-envbundle.sh), sleep a fixed 20 s, `ssh sftp put` a 6.49 MB harness
# tarball, untar it over `ssh console` and push 4 to 9 more files over
# `ssh console` (mput). With POOL_MACHINE_PULL=1 and every precondition held,
# the machine gets all of that by itself: the harness by a pinned git fetch
# (HARNESS_SHA), the static env from Fly app secrets (HBUNDLE_*), and the
# per-machine lines plus the job as `--file-local` seed files.
#
# DRIVEN, NOT GREPPED: `bash bin/fly-pool.sh project-5` runs against a scratch
# $HARNESS with a counting shim on fly, ssh, sleep and curl. The real
# bin/fly-envbundle.sh runs, so a box ssh is a real ssh call to the shim.
#
# PINNED:
#   P1-P8   3 queued jobs, knob 1: 3 `machine run`, 0 `ssh sftp`, 0 `ssh
#           console`, 0 box ssh, 0 sleep; each run carries the job seed and
#           HARNESS_SHA; 3 machine jsons; one `(pull)` line per json.
#   D1-D10  the decision table: each case's path (pull or push) and its reason.
#   S1-S3   the seed carries the same remote paths the push path's mputs do.
#   R1-R3   the round trip: the entrypoint's real seed block, fed this seed and
#           the secrets the real sync writes, composes the same global.env and
#           <p>.env the push path pushes, key by key.
#   N1-N4   no machine id: the lease, the cap slot and the row go back.
#   B1      knob 0: the shim log is byte-identical to the base script's.
#   L1      no `machines list` output (base64 seed values) lands in any log.
# Run from anywhere: bash tests/fly-pool-machine-pull.bh-7430-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ══ the scratch harness ══════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/state/build-notes/project-5" \
         "$H/state/vercel-deploys" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"
: > "$H/env/global.env"
# Seven columns: the box is remote (192.0.2.9), so the real bundler ssh-es.
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The account lib stub (installed before the closure, so the closure keeps it).
# PA_NAME leases a named account and REPLACES the token line, as the real one.
cat > "$H/bin/lib/pool-account.sh" <<'PA'
#!/bin/bash
pool_account_lease() {
  echo "lease $4" >> "$ORDER"
  # P8: mark the seed temp dir ($3 is <tmp>/global.env) with THIS run's id.
  [ -n "${RUN_MARK:-}" ] && printf '%s\n' "$RUN_MARK" > "$(dirname "$3")/.bh7430-marker"
  if [ -n "${PA_NAME:-}" ]; then
    { grep -v '^CLAUDE_CODE_OAUTH_TOKEN=' "$3"; echo "CLAUDE_CODE_OAUTH_TOKEN=fixture-lease-$PA_NAME"; } > "$3.n" && mv "$3.n" "$3"
    echo "name=$PA_NAME reason=lease_rank leases=1 five_h=10"
  else echo "name=default reason=unarmed"; fi
}
pool_account_rebind() { echo "rebind $*" >> "$ORDER"; return 0; }
pool_account_release() { echo "release $*" >> "$ORDER"; return 0; }
pool_account_others_ok() { [ "${PA_OTHERS:-0}" = 1 ]; }
pool_account_prune() { :; }
pool_account_armed() { return 1; }
pool_account_cooldown() { :; }
pool_account_unpin() { :; }
PA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" \
   "$DIR/bin/alert-line.sh" "$DIR/bin/fly-envbundle.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/fly-pool-secrets-sync.sh "$H" >/dev/null 2>&1 || true
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/sleep" <<'SL'
#!/bin/bash
echo "nap $*" >> "${SLEEP_SINK:-/dev/null}"
exit 0
SL
# The owning box: one ssh answers the whitelisted bundle the real extractor
# prints. EXECUTE_MODEL rides <p>.env, as on a real box.
cat > "$T/fakebin/ssh" <<'SSH'
#!/bin/bash
echo "ssh $*" >> "${SSH_SINK:-/dev/null}"
printf '===GLOBAL===\n'
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude-base\nCONSOLE_URL=https://console.invalid\n'
printf 'HARNESS_SECRET=fixture-secret\nRUNNER_LADDER=claude,codex\nJOBS_URL=https://jobs.invalid\n'
printf 'OPENROUTER_API_KEY=fixture-or\n'
[ "${EB_PAT:-1}" = 1 ] && printf 'GH_TOKEN=fixture-pat\n'
printf '===PROJECT===\n'
printf 'BOARD_TOKEN=fixture-board\nEXECUTE_MODEL=fixture-model\n'
exit 0
SSH
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in -d|-D) DEC=1 ;; -w0|-w) W0=1 ;; 0|-*) ;; *) FILE="$a" ;; esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0); fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
# Fly stub. Records every call in $FLY_SINK. `machine run` copies each
# --file-local seed into $SEEDCAP/<mid>/<guest path> (the hub removes its
# temp dir right after); `ssh console` decodes each mput into
# $PUSHCAP/<remote path>. MID_UNIQUE gives each machine its own id.
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$*" in
  *"secrets list"*)
    case "${FLY_SECRETS:-ok}" in
      ok)   echo '[{"Name":"HBUNDLE_G_HARNESS_SECRET","Digest":"d1"},{"Name":"HBUNDLE_SYNCED_AT","Digest":"d2"}]' ;;
      lower) echo '[{"name":"HBUNDLE_SYNCED_AT","digest":"d2"}]' ;;
      old)  echo '[{"Name":"HBUNDLE_SYNCED_AT_OLD","Digest":"d2"}]' ;;
      fail) exit 1 ;;
      hang) exit 124 ;;
      stale) printf '[{"Name":"HBUNDLE_SYNCED_AT","Digest":"d2"},{"Name":"SEED_1000000000_aaaaaaaaaaaa","Digest":"d3"},{"Name":"SEED_%s_bbbbbbbbbbbb","Digest":"d4"}]\n' "$(date +%s)" ;;
    esac ;;
  *"secrets import"*)
    if [ -n "${SECRETSTORE:-}" ]; then
      mkdir -p "$SECRETSTORE"
      while IFS= read -r l; do [ -n "$l" ] && printf '%s' "${l#*=}" > "$SECRETSTORE/${l%%=*}"; done
    else cat > /dev/null; fi ;;
  *"secrets unset"*) : ;;
  *"machine status"*) echo "State: started" ;;
  *"ssh sftp put"*)
    if [ -n "${BYTES_SINK:-}" ]; then
      prev=""; for a in "$@"; do case "$a" in /run/harness/.hsync.tgz) stat -c %s "$prev" >> "$BYTES_SINK" ;; esac; prev="$a"; done
    fi ;;
  *"ssh console"*)
    [ -n "${BYTES_SINK:-}" ] && printf '%s' "$*" | tr -d '\\' | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' | base64 -d 2>/dev/null | wc -c >> "$BYTES_SINK"
    C=$(printf '%s' "$*" | tr -d '\\')
    P=$(printf '%s' "$C" | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d > \([^ ]*\) .*/\2/p')
    B=$(printf '%s' "$C" | sed -n 's/.*echo \([A-Za-z0-9+/=]*\) | base64 -d > \([^ ]*\) .*/\1/p')
    if [ -n "$P" ] && [ -n "${PUSHCAP:-}" ]; then
      mkdir -p "$PUSHCAP$(dirname "$P")"; printf '%s' "$B" | base64 -d > "$PUSHCAP$P"
    fi ;;
  *"machines list"*)
    STATIC='[{"id":"0000000000aaaa","config":{"image":"registry.fly.io/pool-project-5:deploy-01","files":[{"guest_path":"/run/harness-seed/x","raw_value":"SEEDB64MARKfixture"}]}}]'
    # What flyctl stores for each machine this stub launched: --file-local as
    # raw_value (base64 of the content), --file-secret as secret_name only.
    if [ -s "${LISTCAP:-/nonexistent}" ]; then jq -sc --argjson s "$STATIC" '$s + .' "$LISTCAP"; else echo "$STATIC"; fi ;;
  *"machine run"*)
    [ "${FLY_NOMID:-0}" = 1 ] && exit 0
    if [ "${MID_UNIQUE:-0}" = 1 ]; then MID=$(printf '%014x' "$$"); else MID=1234567890abcd; fi
    if [ -n "${SEEDCAP:-}" ]; then
      prev=""
      for a in "$@"; do
        if [ "$prev" = --file-local ]; then
          g="${a%%=*}"; l="${a#*=}"
          mkdir -p "$SEEDCAP/$MID$(dirname "$g")"; cp "$l" "$SEEDCAP/$MID$g" 2>/dev/null
        fi
        prev="$a"
      done
    fi
    if [ -n "${LISTCAP:-}" ]; then
      files='[]'; envs='{}'; prev=""
      for a in "$@"; do
        case "$prev" in
          --file-local) files=$(jq -c --arg g "${a%%=*}" --arg v "$(base64 -w0 < "${a#*=}")" '. + [{guest_path:$g,raw_value:$v}]' <<<"$files") ;;
          --file-secret) files=$(jq -c --arg g "${a%%=*}" --arg s "${a#*=}" '. + [{guest_path:$g,secret_name:$s}]' <<<"$files")
                         if [ -n "${SEEDCAP:-}" ] && [ -r "${SECRETSTORE:-/x}/${a#*=}" ]; then
                           mkdir -p "$SEEDCAP/$MID$(dirname "${a%%=*}")"; cp "$SECRETSTORE/${a#*=}" "$SEEDCAP/$MID${a%%=*}"
                         fi ;;
          -e) envs=$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '. + {($k):$v}' <<<"$envs") ;;
        esac
        prev="$a"
      done
      jq -nc --arg id "$MID" --argjson f "$files" --argjson e "$envs" '{id:$id,config:{env:$e,files:$f}}' >> "$LISTCAP"
    fi
    if [ -n "${SEEDBYTES_SINK:-}" ]; then
      prev=""; for a in "$@"; do [ "$prev" = --file-local ] && stat -c %s "${a#*=}" >> "$SEEDBYTES_SINK"; prev="$a"; done
    fi
    printf 'Machine ID: %s\n' "$MID" ;;
esac
exit 0
FLY
# gh stub: open ai-build tickets 1..9, no branch, no open PR.
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
echo "curl $*" >> "${CURL_SINK:-/dev/null}"
printf '{}\n404\n'
STUB
# The App mint: the project token, its installation, its expiry, and the
# harness read token (`--extra-read example-org/cromford`).
printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
cat > "$H/bin/gh-token.sh" <<'GT'
#!/bin/bash
echo "mint $*" >> "$ORDER"
case " $* " in
  *" --installation-id "*) echo 4242 ;;
  *" --expires-at "*) [ -n "${APP_TOK-tok-fixture-app}" ] && echo 2026-10-19T05:00:00Z ;;
  *" --extra-read "*"cromford"*) [ -n "${HARNESS_TOK-tok-fixture-harness}" ] && echo "${HARNESS_TOK-tok-fixture-harness}" ;;
  *" --extra-read "*) echo tok-fixture-read ;;
  *) [ -n "${APP_TOK-tok-fixture-app}" ] && echo "${APP_TOK-tok-fixture-app}" ;;
esac
exit 0
GT
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

# The harness checkout the hub pins: a scratch repo with one commit.
# bin/fly-pool.sh reads ${HARNESS}-checkout (/root/harness-checkout in production).
HCO="$H-checkout"
mkdir -p "$HCO/bin" "$HCO/prompts" "$HCO/rules" "$HCO/catalog" "$HCO/fly"
echo fixture > "$HCO/bin/x"; echo fixture > "$HCO/fleet.conf"
for d in prompts rules catalog fly; do echo fixture > "$HCO/$d/x"; done
git -C "$HCO" init -q && git -C "$HCO" -c user.email=t@t -c user.name=t add -A \
  && git -C "$HCO" -c user.email=t@t -c user.name=t commit -qm fixture
HSHA=$(git -C "$HCO" rev-parse HEAD)

# P8's per-run marker: /dev/shm is shared by every run on the box, so P8 counts
# only the seed dirs that hold THIS value (the bundle-before-spawn suite's way).
RUN_MARK="bh7430-$$-${T##*/}"   # the pid and this run's own scratch dir name
ORDER="$T/order.txt"; POOLD="$H/state/fly-pool/project-5"; QD="$H/state/build-queue/project-5"
run_pool() { # run_pool [script] -- [VAR=val ...]
  local script="$DIR/bin/fly-pool.sh"
  if [ "${1:-}" != -- ]; then script="$1"; fi; shift
  [ "${1:-}" = -- ] && shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 FLY_SINK="$T/fly.txt" SSH_SINK="$T/ssh.txt" \
           SLEEP_SINK="$T/sleep.txt" CURL_SINK="$T/curl.txt" ORDER="$ORDER" RUN_MARK="$RUN_MARK" \
           SEEDCAP="$T/seed" PUSHCAP="$T/push" SECRETSTORE="$T/secrets" LISTCAP="$T/listcap.jsonl" \
           FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$script" project-5 >/dev/null 2>&1 )
}
reset_case() { # reset_case <n-jobs>
  local p i
  for p in "$QD"/* "$QD"/.??* "$POOLD"/*.json "$POOLD"/.??* "$H/state/pool/project-5"/* \
           "$H/state/build-notes/project-5"/* "$H/state/vercel-deploys"/* "$T/seed" "$T/push" "$T/secrets" "$T/listcap.jsonl"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$ORDER"; : > "$T/fly.txt"; : > "$T/ssh.txt"; : > "$T/sleep.txt"; : > "$T/curl.txt"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  for i in $(seq 1 "${1:-1}"); do
    jq -nc --arg i "$i" '{ticket_id:$i,key:("BH-"+$i),attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-19T00:00:00Z"}' > "$QD/BH-$i.json"
  done
  return 0
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
cnt() { grep -c -- "$1" "$2" 2>/dev/null | head -1; }
runs() { grep -c 'fly machine run' "$T/fly.txt"; }
runlines() { grep 'fly machine run' "$T/fly.txt"; }
is_pull() { grep -q -- "-e HARNESS_SHA=$HSHA" <<<"$(runlines)" && ! grep -q 'ssh sftp put' "$T/fly.txt"; }
is_push() { grep -q 'ssh sftp put' "$T/fly.txt" && ! grep -q -- '-e HARNESS_SHA=' <<<"$(runlines)"; }

# ══ P1-P8: 3 jobs on the pull path ═══════════════════════════════════════════
reset_case 3
run_pool -- POOL_MACHINE_PULL=1 MID_UNIQUE=1
[ "$(runs)" = 3 ] && ok || bad "P1: 3 jobs must make 3 machine run, got $(runs): $(log)"
[ "$(cnt 'ssh sftp' "$T/fly.txt")" = 0 ] && ok || bad "P2: no ssh sftp from the hub, got $(cnt 'ssh sftp' "$T/fly.txt")"
[ "$(cnt 'ssh console' "$T/fly.txt")" = 0 ] && ok || bad "P3: no ssh console (mput/mexec) from the hub, got $(cnt 'ssh console' "$T/fly.txt")"
[ ! -s "$T/ssh.txt" ] && ok || bad "P4: no box ssh (fly-envbundle.sh), got: $(cat "$T/ssh.txt")"
[ ! -s "$T/sleep.txt" ] && ok || bad "P5: no sleep, got: $(tr '\n' '|' < "$T/sleep.txt")"
N=$(grep 'fly machine run' "$T/fly.txt" | grep -c -- '--file-local /run/harness-seed/run/harness/job.json=')
[ "$N" = 3 ] && ok || bad "P6: each machine run must carry the job.json seed, got $N"
N=$(grep 'fly machine run' "$T/fly.txt" | grep -cE -- "-e HARNESS_SHA=[0-9a-f]{40}( |$)")
[ "$N" = 3 ] && ok || bad "P7: each machine run must carry -e HARNESS_SHA=<40hex>, got $N"
grep 'fly machine run' "$T/fly.txt" | grep -q -- "-e HARNESS_SHA=$HSHA -e HARNESS_SLUG=example-org/cromford" && ok \
  || bad "P7: the sha is the checkout HEAD and the slug the harness repo: $(grep 'machine run' "$T/fly.txt" | head -1)"
NJ=$(ls "$POOLD"/*.json 2>/dev/null | grep -c .)
NL=$(grep -cE 'spawned [0-9a-f]{14} for BH-[0-9] \(pull' "$H/logs/fly-pool.log")
[ "$NJ" = 3 ] && [ "$NL" = 3 ] && ok || bad "P8: 3 machine jsons and 3 '(pull)' lines, got jsons=$NJ lines=$NL: $(log)"
[ "$(ls "$QD"/BH-*.json 2>/dev/null | grep -c .)" = 0 ] && ok || bad "P8: the dispatched queue files must be gone"
[ "$(cnt 'fly secrets list' "$T/fly.txt")" = 1 ] && ok || bad "P8: one secrets list per tick, not per spawn, got $(cnt 'fly secrets list' "$T/fly.txt")"
# No seed temp dir survives. Only dirs that hold THIS run's marker count: a
# parallel run of this suite, or of a suite that spawns (warmup,
# bundle-before-spawn), owns its own /dev/shm/pool.* dirs.
own_seed_dirs() {
  local d n=0
  for d in /dev/shm/pool.*; do
    [ -f "$d/.bh7430-marker" ] && grep -qxF "$RUN_MARK" "$d/.bh7430-marker" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
[ "$(grep -c '^lease ' "$ORDER")" = 3 ] && ok || bad "P8 precondition: the lease (which marks the seed dir) ran 3 times, got $(grep -c '^lease ' "$ORDER")"
LEFT=$(own_seed_dirs)
[ "$LEFT" = 0 ] && ok || bad "P8: $LEFT seed temp dir(s) of this run survived in /dev/shm"

# ══ L1: machines list output never reaches a log ═════════════════════════════
grep -rq SEEDB64MARK "$H/logs" && bad "L1: machines list output (seed values) landed in a log" || ok

# ══ T1-T7: no token value in any machine listing or config (BH-7430 review) ═══
# flyctl stores --file-local content as config.files[].raw_value, readable from
# `machines list --json` with the app's Fly token, also after the machine is
# destroyed (bin/fly-idle-reaper.sh, bin/lane-fleet.sh and bin/fly-pool.sh write
# that listing to hub files). The tokens must travel as a Fly secret-backed file
# (secret_name) and never as raw_value. The stub builds the listing the way
# flyctl does from the real `machine run` arguments.
reset_case 1
printf '{"accounts":[{"name":"max3","token":"fixture-acct-secret-MARK"}]}\n' > "$H/state/auth-accounts.local.json"
run_pool -- POOL_MACHINE_PULL=1 PA_NAME=max3
is_pull && ok || bad "T0: the token case must take the pull path: $(log)"
LISTING=$(PATH="$T/fakebin:$PATH" LISTCAP="$T/listcap.jsonl" fly machines list --json 2>/dev/null)
DECODED=$(jq -r '.[]?.config.files[]?.raw_value // empty' <<<"$LISTING" | while IFS= read -r v; do printf '%s' "$v" | base64 -d 2>/dev/null; echo; done)
for tok in tok-fixture-app tok-fixture-harness fixture-lease-max3 fixture-acct-secret-MARK; do
  if grep -qF -- "$tok" <<<"$LISTING" || grep -qF -- "$tok" <<<"$DECODED"; then
    bad "T1: the machine listing holds the token value $tok (raw_value or env)"
  else ok; fi
  grep -qF -- "$tok" "$T/fly.txt" && bad "T2: the token $tok is on a flyctl command line" || ok
done
NS=$(ls "$T/secrets"/SEED_* 2>/dev/null | grep -c .)
[ "$NS" = 1 ] && ok || bad "T3: one per-machine SEED_ secret is imported, got $NS"
SN=$(ls "$T/secrets"/SEED_* 2>/dev/null | head -1 | xargs -r basename)
grep -qE -- "--file-secret /run/harness-seed-secret/bundle.b64=$SN( |$)" "$T/fly.txt" && ok || bad "T4: machine run carries --file-secret for $SN: $(runlines | cut -c1-300)"
[ "$(jq -r --arg n "$SN" '[.[]?.config.files[]? | select(.secret_name == $n)] | length' <<<"$LISTING")" = 1 ] && ok || bad "T4: the listing shows the file as secret_name $SN only"
BUNDLE=$(base64 -d < "$T/secrets/$SN" 2>/dev/null | tar -xzO 2>/dev/null)
for tok in tok-fixture-app tok-fixture-harness fixture-lease-max3 fixture-acct-secret-MARK; do
  grep -qF -- "$tok" <<<"$BUNDLE" && ok || bad "T5: the secret bundle must carry $tok to the machine"
done
grep -q 'secrets import --stage -a pool-project-5' "$T/fly.txt" && ok || bad "T6: the import is staged (no redeploy of live machines)"
grep -qE 'secrets (import|set)' "$T/fly.txt" && ! grep -qE 'secrets set' "$T/fly.txt" && ok || bad "T6: values go by stdin import, never secrets-set argv"
# T7: a hub tick that finds an old SEED_ secret unsets it; a fresh one stays.
reset_case 1
run_pool -- POOL_MACHINE_PULL=1 FLY_SECRETS=stale
grep -qE 'secrets unset --stage -a pool-project-5 SEED_1000000000_aaaaaaaaaaaa( |$)' "$T/fly.txt" && ok || bad "T7: the stale SEED_ secret is unset: $(grep 'secrets' "$T/fly.txt" | tr '\n' '|')"
grep -E 'secrets unset' "$T/fly.txt" > "$T/unset.txt"
grep -q 'bbbbbbbbbbbb' "$T/unset.txt" && bad "T7: a fresh SEED_ secret must stay" || ok

# ══ H1-H2: a hung `fly secrets list` costs one bounded wait, not one per tick ═
reset_case 1
run_pool -- POOL_MACHINE_PULL=1 FLY_SECRETS=hang
is_push && grep -qF 'BH-1: push path (fly secrets list timed out' "$H/logs/fly-pool.log" && ok || bad "H1: a hung secrets list takes the push path with its reason: $(log)"
: > "$T/fly.txt"; : > "$H/logs/fly-pool.log"   # keep the marker: no reset_case
jq -nc '{ticket_id:"1",key:"BH-1",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-19T00:00:00Z"}' > "$QD/BH-1.json"
run_pool -- POOL_MACHINE_PULL=1 FLY_SECRETS=hang
[ "$(cnt 'secrets list' "$T/fly.txt")" = 0 ] && ok || bad "H2: the next tick within 5 minutes does not call secrets list again, got $(cnt 'secrets list' "$T/fly.txt")"
rm -f "$POOLD"/.secrets-list-hang

# ══ S1-S3: the seed carries the push path's remote paths ═════════════════════
# One job with a build note and a deploy snapshot, both paths, same fixture.
seed_fixtures() {
  printf 'note for BH-1\n' > "$H/state/build-notes/project-5/BH-1.md"
  printf '{"deploys":[]}\n' > "$H/state/vercel-deploys/project-5.json"
}
reset_case 1; seed_fixtures
run_pool -- POOL_MACHINE_PULL=0 PA_NAME=max3
PUSHP=$(cd "$T/push" 2>/dev/null && find . -type f | sed 's|^\.||' | sort)
cp "$T/push/run/harness-env/global.env" "$T/push-global.env" 2>/dev/null
cp "$T/push/run/harness-env/project-5.env" "$T/push-project.env" 2>/dev/null
reset_case 1; seed_fixtures
run_pool -- POOL_MACHINE_PULL=1 PA_NAME=max3
is_pull && ok || bad "S0: the seed case must take the pull path: $(log)"
# The seed is two carriers now: the --file-local tree (no token) and the one
# --file-secret bundle (every token file). The union is what the push path wrote.
SEEDP=$( { (cd "$T/seed/1234567890abcd/run/harness-seed" 2>/dev/null && find . -type f | sed 's|^\.||')
           base64 -d < "$T/seed/1234567890abcd/run/harness-seed-secret/bundle.b64" 2>/dev/null | tar -tz 2>/dev/null | sed 's|^\./|/|'; } | sort)
# No token file is in the --file-local tree (it would be raw_value in the config).
for tf in /run/harness-env/global.override.env /run/harness-env/gh-token /run/harness-env/gh-token-harness /data/harness/state/auth-accounts.local.json; do
  [ -e "$T/seed/1234567890abcd/run/harness-seed$tf" ] && bad "S2: $tf must not be a --file-local seed file" || ok
done
for p in $PUSHP; do
  case "$p" in
    /run/harness-env/global.env|/run/harness-env/project-5.env) continue ;;
  esac
  grep -qx -- "$p" <<<"$SEEDP" && ok || bad "S1: push path $p is not in the seed: $(tr '\n' ' ' <<<"$SEEDP")"
done
grep -qx /run/harness/build-note-project-5-BH-1.md <<<"$PUSHP" && ok || bad "S1 precondition: the push run must push the build note: $PUSHP"
grep -qx /run/harness-env/global.override.env <<<"$SEEDP" && ok || bad "S2: the seed carries global.override.env: $SEEDP"
grep -qx /run/harness-env/gh-token-harness <<<"$SEEDP" && ok || bad "S2: the seed carries the harness read token: $SEEDP"
grep -qx /run/harness-env/project-5.env <<<"$SEEDP" && bad "S2: <p>.env comes from the secrets, not the seed" || ok
[ ! -e "$H/state/build-notes/project-5/BH-1.md" ] && ok || bad "S3: the build note is consumed after a pull launch"
grep -q 'relayed the carried build note for BH-1 to 1234567890abcd' "$H/logs/fly-pool.log" && ok || bad "S3: the build note relay line: $(log)"
[ -s "$POOLD/.1234567890abcd.snapmt" ] && ok || bad "S3: the snapshot mtime is recorded for the reap"
[ "$(jq -r '.auth_account // ""' "$POOLD/1234567890abcd.json" 2>/dev/null)" = max3 ] && ok || bad "S3: the machine json keeps auth_account"
grep -qE '^rebind pre-BH-1-[0-9]+-[0-9]+ 1234567890abcd max3 project-5 BH-1$' "$ORDER" && ok || bad "S3: the lease moves to the machine id: $(tr '\n' '|' < "$ORDER")"
cp -r "$T/seed/1234567890abcd" "$T/seed-keep"

# ══ R1-R3: the round trip through the real sync mapping and entrypoint block ═
EBLOCK=$(sed -n '/^# >>> seed (BH-7430)/,/^# <<< seed (BH-7430)/p' "$DIR/fly/entrypoint.sh")
[ -n "$EBLOCK" ] && ok || bad "R0: the '# >>> seed (BH-7430)' block is not in fly/entrypoint.sh"
# The secrets the real sync writes for this fixture (its --dry-run off; the
# fly stub records the import stdin).
SYNC="$DIR/bin/fly-pool-secrets-sync.sh"
IMPORT="$T/import.txt"; : > "$IMPORT"
mkdir -p "$T/syncbin"
cat > "$T/syncbin/fly" <<SF
#!/bin/bash
case "\$*" in *"secrets import"*) cat > "$IMPORT" ;; *"secrets list"*) echo '[]' ;; esac
exit 0
SF
chmod +x "$T/syncbin/fly"
( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" SSH_SINK=/dev/null \
         FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/syncbin"
  bash "$SYNC" project-5 >/dev/null 2>&1 ) || bad "R0: the sync must run: rc $?"
grep -q '^HBUNDLE_SYNCED_AT=' "$IMPORT" && ok || bad "R0: the sync import carries the marker: $(cut -d= -f1 "$IMPORT" | tr '\n' ' ')"
ER="$T/eroot"; mkdir -p "$ER/run/harness-env" "$ER/run/harness" "$ER/data/harness/state"
cp -r "$T/seed-keep/run/harness-seed" "$ER/run/harness-seed"
cp -r "$T/seed-keep/run/harness-seed-secret" "$ER/run/harness-seed-secret"
cat > "$T/eseed.sh" <<EOF
log() { echo "entrypoint: \$*" >> "$T/e.log"; }
BOOT_ROOT="$ER"
PROJECT=project-5
$EBLOCK
env | grep -c '^HBUNDLE_' > "$T/e.left"
EOF
# The values ride verbatim, as Fly sets them: no shell parse of the import.
( while IFS= read -r l; do export "${l%%=*}=${l#*=}"; done < "$IMPORT"; bash "$T/eseed.sh" ) >/dev/null 2>&1
same_env() { # same_env <a> <b> -> rc 0 when the KEY=VAL sets are equal
  diff <(grep -v '^[[:space:]]*$' "$1" | sort) <(grep -v '^[[:space:]]*$' "$2" | sort) >/dev/null
}
if same_env "$ER/run/harness-env/global.env" "$T/push-global.env"; then ok; else
  bad "R1: composed global.env differs from the pushed one: $(diff <(sort "$T/push-global.env") <(sort "$ER/run/harness-env/global.env") | sed 's/=.*//' | tr '\n' ' ')"; fi
if same_env "$ER/run/harness-env/project-5.env" "$T/push-project.env"; then ok; else
  bad "R2: composed project-5.env differs from the pushed one: $(diff <(sort "$T/push-project.env") <(sort "$ER/run/harness-env/project-5.env") | sed 's/=.*//' | tr '\n' ' ')"; fi
[ "$(cat "$T/e.left" 2>/dev/null)" = 0 ] && ok || bad "R3: no HBUNDLE_ var is left after the compose: $(cat "$T/e.left" 2>/dev/null)"
[ "$(grep -c '^GH_TOKEN=' "$ER/run/harness-env/global.env")" = 1 ] && ok || bad "R3: exactly one GH_TOKEN line"
grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=fixture-lease-max3' "$ER/run/harness-env/global.env" && ok || bad "R3: the leased token replaces the base one"
[ -s "$ER/run/harness/job.json" ] && [ "$(jq -r .key "$ER/run/harness/job.json")" = BH-1 ] && ok || bad "R3: job.json lands at /run/harness/job.json"
[ -s "$ER/run/harness/build-note-project-5-BH-1.md" ] && ok || bad "R3: the build note lands at its push path"
[ -s "$ER/data/harness/state/vercel-deploys/project-5.json" ] && ok || bad "R3: the deploy snapshot lands at its push path"
[ ! -e "$ER/run/harness-seed" ] && ok || bad "R3: the seed dir is removed"
[ ! -e "$ER/run/harness-seed-secret/bundle.b64" ] && [ ! -e "$ER/run/harness-env/.sealed" ] && ok || bad "R3: the secret file and the unpack dir are removed"
[ "$(cat "$ER/run/harness-env/gh-token-harness" 2>/dev/null)" = tok-fixture-harness ] && [ "$(stat -c %a "$ER/run/harness-env/gh-token-harness" 2>/dev/null)" = 600 ] \
  && ok || bad "R3: the harness read token lands from the secret bundle, mode 600"
grep -q 'fixture-acct-secret-MARK' "$ER/data/harness/state/auth-accounts.local.json" 2>/dev/null && ok || bad "R3: auth-accounts.local.json lands from the secret bundle"
# R4: the DEFAULT account (no lease): the base token must survive the override,
# and the placeholder must never reach the machine.
reset_case 1
run_pool -- POOL_MACHINE_PULL=0
cp "$T/push/run/harness-env/global.env" "$T/push-global-default.env" 2>/dev/null
reset_case 1
run_pool -- POOL_MACHINE_PULL=1
ER2="$T/eroot2"; mkdir -p "$ER2/run/harness-env" "$ER2/run/harness" "$ER2/data/harness/state"
cp -r "$T/seed/1234567890abcd/run/harness-seed" "$ER2/run/harness-seed" 2>/dev/null
cp -r "$T/seed/1234567890abcd/run/harness-seed-secret" "$ER2/run/harness-seed-secret" 2>/dev/null
sed "s|BOOT_ROOT=\"$ER\"|BOOT_ROOT=\"$ER2\"|" "$T/eseed.sh" > "$T/eseed2.sh"
( while IFS= read -r l; do export "${l%%=*}=${l#*=}"; done < "$IMPORT"; bash "$T/eseed2.sh" ) >/dev/null 2>&1
if same_env "$ER2/run/harness-env/global.env" "$T/push-global-default.env"; then ok; else
  bad "R4: default account: composed global.env differs from the pushed one: $(diff <(sort "$T/push-global-default.env") <(sort "$ER2/run/harness-env/global.env") | sed 's/=.*//' | tr '\n' ' ')"; fi
grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude-base' "$ER2/run/harness-env/global.env" && ok || bad "R4: the base token stays when no account is leased"
grep -rq __HBUNDLE_BASE__ "$ER2" && bad "R4: the placeholder reached the machine" || ok

# ══ D1-D10: the decision table (one job each) ════════════════════════════════
dcase() { # dcase <id> <want pull|push> <reason-or-""> -- [VAR=val ...]
  local id="$1" want="$2" why="$3"; shift 3; [ "${1:-}" = -- ] && shift
  reset_case 1
  run_pool -- "$@"
  if [ "$want" = pull ]; then
    is_pull && ok || bad "$id: want the pull path: $(grep 'machine run' "$T/fly.txt" | head -1) / $(log)"
    grep -q 'spawned 1234567890abcd for BH-1 (pull' "$H/logs/fly-pool.log" && ok || bad "$id: the (pull) spawn line: $(log)"
  else
    is_push && ok || bad "$id: want the push path: $(log)"
    if [ -n "$why" ]; then
      grep -qF "BH-1: push path ($why)" "$H/logs/fly-pool.log" && ok || bad "$id: the log must say 'push path ($why)': $(log)"
    else
      grep -q 'push path (' "$H/logs/fly-pool.log" && bad "$id: knob off must log no pull reason: $(log)" || ok
    fi
  fi
}
dcase D1 pull "" -- POOL_MACHINE_PULL=1
dcase D2 push "no HBUNDLE_SYNCED_AT in the pool-project-5 secrets" -- POOL_MACHINE_PULL=1 FLY_SECRETS=old
dcase D2b push "no HBUNDLE_SYNCED_AT in the pool-project-5 secrets" -- POOL_MACHINE_PULL=1 FLY_SECRETS=fail
dcase D2c pull "" -- POOL_MACHINE_PULL=1 FLY_SECRETS=lower
dcase D3 push "no harness read token" -- POOL_MACHINE_PULL=1 HARNESS_TOK=
dcase D4 push "no App token" -- POOL_MACHINE_PULL=1 APP_TOK=
dcase D6 push "" -- POOL_MACHINE_PULL=0
dcase D7 pull "" -- "POOL_MACHINE_PULL=1 "
dcase D8 push "" -- POOL_MACHINE_PULL=true
dcase D8b push "" -- POOL_MACHINE_PULL=01x
mv "$HCO/.git" "$T/hco.git"
dcase D9 push "no git HEAD in the harness checkout" -- POOL_MACHINE_PULL=1
mv "$T/hco.git" "$HCO/.git"
# D4 near miss: the push path still ships the PAT there, as today.
reset_case 1
run_pool -- POOL_MACHINE_PULL=1 APP_TOK=
grep -q 'shipping the PAT' "$H/logs/fly-pool.log" && ok || bad "D4: the push fallback ships the PAT as today: $(log)"
# D5 needs a real big file: the build note.
reset_case 1
head -c 6000 /dev/zero | tr '\0' 'n' > "$H/state/build-notes/project-5/BH-1.md"
run_pool -- POOL_MACHINE_PULL=1 POOL_SEED_MAX_BYTES=4096
is_push && grep -qF 'BH-1: push path (seed too big:' "$H/logs/fly-pool.log" && ok || bad "D5: a 6000-byte note over a 4096 cap takes the push path: $(log)"
[ -s "$H/state/build-notes/project-5/BH-1.md" ] && bad "D5: the push path then relays (consumes) the note" || ok

# ══ N1-N4: no machine id on the pull path ═════════════════════════════════════
reset_case 1
run_pool -- POOL_MACHINE_PULL=1 FLY_NOMID=1 PA_NAME=max3
grep -q 'machine run FAILED for BH-1' "$H/logs/fly-pool.log" && ok || bad "N1: the failure line: $(log)"
grep -qE '^release pre-BH-1-[0-9]+-[0-9]+$' "$ORDER" && ok || bad "N2: the pre-launch lease is released: $(tr '\n' '|' < "$ORDER")"
[ ! -s "$H/state/pool/project-5/BH-1.spawns" ] && ok || bad "N3: the cap slot is given back: $(cat "$H/state/pool/project-5/BH-1.spawns" 2>/dev/null)"
[ -f "$QD/BH-1.json" ] && [ "$(ls "$POOLD"/*.json 2>/dev/null | grep -c .)" = 0 ] && ok || bad "N4: the job stays queued and no machine json is written"

# ══ B1: knob 0 is byte-identical to the base script ═════════════════════════
# The base is the PR's merge base (BH7430_BASE_REF overrides it). On main after
# the merge it is HEAD itself, and there is nothing to compare: the case says so.
BASE="${BH7430_BASE_REF:-$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null || true)}"
[ -n "$BASE" ] && [ "$(git -C "$DIR" rev-parse "$BASE" 2>/dev/null)" = "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" ] && BASE=""
if [ -n "$BASE" ] && git -C "$DIR" show "$BASE:bin/fly-pool.sh" > "$T/base-fly-pool.sh" 2>/dev/null; then
  norm() { sed -E 's#/tmp/poolsync-[A-Za-z0-9]+\.tgz#TB#g; s#/dev/shm/pool\.[A-Za-z0-9]+#TMP#g' "$1"; }
  reset_case 1; seed_fixtures
  run_pool "$T/base-fly-pool.sh" -- PA_NAME=max3
  cat "$T/fly.txt" "$T/ssh.txt" "$T/sleep.txt" > "$T/shim.base"
  reset_case 1; seed_fixtures
  run_pool -- POOL_MACHINE_PULL=0 PA_NAME=max3
  cat "$T/fly.txt" "$T/ssh.txt" "$T/sleep.txt" > "$T/shim.head"
  [ -s "$T/shim.base" ] && ok || bad "B1 precondition: the base run recorded nothing"
  if diff <(norm "$T/shim.base") <(norm "$T/shim.head") >/dev/null; then ok; else
    bad "B1: knob 0 must be byte-identical to the base ($BASE): $(diff <(norm "$T/shim.base") <(norm "$T/shim.head") | head -5 | cut -c1-200)"; fi
else
  echo "NOTE: B1 not run here: no base to compare (no merge base with origin/main, or HEAD is the base)"
fi

# ══ T7 numbers (opt-in: BH7430_MEASURE=1) ═══════════════════════════════════
# 3 jobs, base script against head, same fixture. The base copy's harness
# checkout points at this repo so its tarball has a real size. CPU is the
# tick's user+sys with its children (bash `time`), divided by 3. The stubs are
# bash scripts, so a real flyctl `ssh console` (a Go binary per call) costs the
# base more than shown here.
if [ "${BH7430_MEASURE:-0}" = 1 ] && [ -n "${BASE:-}" ]; then
  sed "s#/root/harness-checkout#$DIR#g" "$T/base-fly-pool.sh" > "$T/base-measure.sh"
  sed "s#/root/harness-checkout#$DIR#g" "$DIR/bin/fly-pool.sh" > "$T/head-measure.sh"
  tick_cpu() { # tick_cpu <n-jobs> <script> [VAR=val ...] -> "user sys" of one tick
    local n="$1" script="$2"; shift 2
    reset_case "$n"; : > "$T/bytes.txt"; : > "$T/seedbytes.txt"
    TIMEFORMAT='%U %S'
    { time run_pool "$script" -- MID_UNIQUE=1 BYTES_SINK="$T/bytes.txt" SEEDBYTES_SINK="$T/seedbytes.txt" "$@" ; } 2>&1 | tail -1
  }
  measure() { # measure <label> <script> [VAR=val ...]
    local label="$1" script="$2" cpu c0; shift 2
    c0=$(tick_cpu 0 "$script" "$@")
    cpu=$(tick_cpu 3 "$script" "$@")
    awk -v l="$label" -v c="$cpu" -v z="$c0" \
        -v ss="$(awk '{s+=$2} END {print s+0}' "$T/sleep.txt")" \
        -v b="$(awk '{s+=$1} END {print s+0}' "$T/bytes.txt")" \
        -v sb="$(awk '{s+=$1} END {print s+0}' "$T/seedbytes.txt")" \
        -v sftp="$(grep -c 'ssh sftp' "$T/fly.txt")" -v con="$(grep -c 'ssh console' "$T/fly.txt")" -v box="$(grep -c '^ssh ' "$T/ssh.txt")" \
        'BEGIN { split(c, t, " "); split(z, u, " "); printf "MEASURE %s: hub CPU s per spawn %.3f (3-job tick %.3f s, 0-job tick %.3f s); hub sleep s per spawn %.1f; bytes pushed after launch per spawn %d; seed bytes in the launch per spawn %d; per 3 spawns: sftp %d, ssh console %d, box ssh %d\n", l, (t[1]+t[2]-u[1]-u[2])/3, t[1]+t[2], u[1]+u[2], ss/3, b/3, sb/3, sftp, con, box }'
  }
  measure "base ${BASE:0:12}" "$T/base-measure.sh"
  measure "head knob=1" "$T/head-measure.sh" POOL_MACHINE_PULL=1
  measure "head knob=0" "$T/head-measure.sh" POOL_MACHINE_PULL=0
fi

echo "fly-pool-machine-pull (BH-7430): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
