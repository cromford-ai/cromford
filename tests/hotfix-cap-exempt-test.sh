#!/bin/bash
# tests/hotfix-cap-exempt-test.sh — a hotfix is the one row allowed past a POOL
# CAP, and is still held by everything that is not a cap (#368/#418, the
# pool+dispatch+runner third of the hotfix lane).
#
# WHAT THIS PINS AND WHY. "Cap-exempt" is two claims that fail in opposite
# directions, and both fail silently:
#   * too little — the hotfix is deferred like any other ticket and the
#     emergency waits for a slot, which looks exactly like a busy fleet;
#   * too much — the exemption is read as "ignore everything", and a project
#     somebody PAUSED on purpose starts building again. A pause is a human
#     decision (#368 puts overriding it out of scope), so §4 asserts the
#     exemption is NOT applied there and that the wait is logged instead.
# And one more that is subtler than either: the exemption must be spent ONLY
# when the pool is actually AT cap. A hotfix that takes a free budget slot AND
# the exemption puts the pool one machine over a cap it never reached — §2b is
# that case, and it is the reason the guard reads `LAUNCHED -ge BUDGET`.
#
# THE FLAG IS THE WHOLE FEATURE, so every hop it takes is driven: the deferral
# requeue (§3), the death requeue (§3b), the reused-machine json (§5) and the
# hub's DB->file materialise (§7). A flag dropped in any one of them is an
# emergency that quietly stops being one — the next tick defers it for the cap
# it was exempt from a minute ago.
#
# The WIP gate half of this lane (bin/run-build.sh) is NOT driven here; it is
# tests/hotfix-wip-gate-test.sh (BH-417).
#
# Everything below runs the REAL scripts against a scratch $HARNESS with stubbed
# flyctl/ssh/curl — bin/fly-pool.sh in §2-§4, its next_job_or_destroy extracted
# verbatim in §5, bin/fly-dispatch.sh's own `# >>> next job pick` region in §6
# and the whole dispatcher in §7.
#
# Run from anywhere: tests/hotfix-cap-exempt-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX HOTFIX HOTFIX_LANE

# ══ the pool fixture: one live machine, an explicit cap of 1, two queued ════
H="$T/p"
mkdir -p "$H/bin" "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/build-queue/tproj" \
         "$H/builds" "$T/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/lib/hotfix-lib.sh" "$H/bin/lib/"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf '1\n' > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf 'registry.fly.io/builder-tproj:deployment-01\n' > "$H/state/fly/tproj.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# flyctl: the one live machine is mid-build (started, no RESULT, fresh
# heartbeat), so the reap leaves it alone and the SPAWN section is what this
# section is actually driving.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machines list"*)  echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   echo 5 ;;
  *RESULT*)           : ;;
  *"machine run"*) printf 'Machine ID: %s\n' "$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
  *) : ;;
esac
exit 0
STUB
cp "$T/fakebin/fly" "$T/fakebin/fly.spawn.bak"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

poolqueue() { # poolqueue — one plain job and one hotfix job, plus a live machine
  rm -f "$H/state/build-queue/tproj"/*.json "$H/state/fly-pool/tproj"/*.json
  jq -nc '{ticket_id:"1",key:"HF-1",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/build-queue/tproj/HF-1.json"
  jq -nc '{ticket_id:"2",key:"HF-2",attempt:0,deferrals:0,deaths:0,hotfix:true}' \
    > "$H/state/build-queue/tproj/HF-2.json"
  # THE PLAIN JOB IS EXPLICITLY THE OLDER ONE, with an absolute stamp rather
  # than whatever two back-to-back writes happen to produce. Two things depend
  # on it: mtime order alone must hand the tick HF-1, which is what makes
  # "the hotfix went first" a real observation rather than a coincidence; and
  # `ls -tr` breaks an mtime TIE by reverse name, so on a tie it hands back
  # HF-2 and the negatives in section 2c go red for a reason that has nothing
  # to do with the code under test. (Seen: 2026-09-17, one tick in ~4.)
  touch -d '2020-01-01' "$H/state/build-queue/tproj/HF-1.json"
  jq -nc '{machine:"m0",key:"HF-0",ticket_id:"0",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/fly-pool/tproj/m0.json"
}
pooltick() { # pooltick [env...] — one pass; prints the count of NEW machine jsons
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
  echo $(( $(ls "$H/state/fly-pool/tproj"/*.json 2>/dev/null | wc -l) - 1 ))
}
poolline() { grep -o 'pool tproj: .*' "$H/logs/fly-pool.log" | tail -1; }
spawnedkeys() { grep -h '"key"' "$H/state/fly-pool/tproj"/*.json 2>/dev/null | jq -r .key | grep -v '^HF-0$' | sort | tr '\n' ' '; }

# ══ 2. THE POOL CAP: the hotfix is the row that exceeds it, by one ══════════
poolqueue
N=$(pooltick)
[ "$N" = 1 ] && ok || bad "a full pool must still spawn ONE machine for the hotfix (got $N new)"
SPAWNED=$(spawnedkeys)
[ "$SPAWNED" = "HF-2 " ] && ok || bad "the machine that was spawned must be the HOTFIX's (got: $SPAWNED)"
[ -f "$H/state/build-queue/tproj/HF-1.json" ] && ok \
  || bad "the plain job must still be queued — the exemption is one row, not a free-for-all"
# THE SPAWNED MACHINE'S OWN JSON. This is not bookkeeping: the reap reads
# `.hotfix` back off the machine json, and both requeue paths rebuild the queue
# entry from it. A flag that does not make it onto the machine is a hotfix that
# loses the label the first time its build stands down — and the spawn path is
# the one that has to read it off a job file it is about to delete.
SPAWNJSON=$(ls "$H/state/fly-pool/tproj"/*.json 2>/dev/null | grep -v '/m0\.json$' | head -1)
[ -n "$SPAWNJSON" ] && [ "$(jq -r '.hotfix // "absent"' "$SPAWNJSON" 2>/dev/null)" = true ] && ok \
  || bad "the spawned machine json must carry the flag: $(cat "${SPAWNJSON:-/dev/null}" 2>/dev/null)"
[ "$(poolline)" = "pool tproj: queued=2 running=1 spawning=0 cap=1 hotfix=1" ] && ok \
  || bad "the per-tick line must report the hotfix count (got '$(poolline)')"
# AND THE EXEMPTION SAYS THE LINE IT EXCEEDED (docs: "Both exemptions log the
# line they exceeded"). The tick line above reports the BUDGET, which is 0 here
# either way — without this line a machine past the cap is indistinguishable in
# the log from a cap that was never reached.
grep -q 'hotfix HF-2: pool at cap 1 (budget spent) — exceeding it by one machine' "$H/logs/fly-pool.log" \
  && ok || bad "the pool must log the cap the exemption exceeded"
# ...and with no hotfix queued the line and the behaviour are byte-identical to
# what they were before #368.
poolqueue
rm -f "$H/state/build-queue/tproj/HF-2.json"
N=$(pooltick)
[ "$N" = 0 ] && ok || bad "with no hotfix queued a full pool must spawn nothing (got $N)"
[ "$(poolline)" = "pool tproj: queued=1 running=1 spawning=0 cap=1" ] && ok \
  || bad "a tick with no hotfix must log exactly today's line (got '$(poolline)')"
# The kill flag: HOTFIX_LANE=0 is pre-#368 behaviour.
poolqueue
N=$(pooltick HOTFIX_LANE=0)
[ "$N" = 0 ] && ok || bad "HOTFIX_LANE=0 must restore the plain cap (got $N)"
# A `"hotfix":"true"` STRING is a different value written by a different code
# path: a cap exemption granted on a type coercion is one nobody wrote down.
poolqueue
jq -nc '{ticket_id:"2",key:"HF-2",attempt:0,deferrals:0,deaths:0,hotfix:"true"}' \
  > "$H/state/build-queue/tproj/HF-2.json"
N=$(pooltick)
[ "$N" = 0 ] && ok || bad "a STRING \"true\" must not buy the exemption (got $N)"

# ══ 2b. THE EXEMPTION IS SPENT ONLY AT CAP (review fix F1) ══════════════════
# cap 2, one machine live, two queued: the pool has ONE free budget slot. The
# hotfix takes THAT, and the exemption stays unspent — otherwise the tick ends
# with 3 machines against a cap of 2, which is a cap exceeded for a pool that
# was never full.
printf '2\n' > "$H/flags/fly-pool-tproj"
poolqueue
N=$(pooltick)
[ "$N" = 1 ] && ok || bad "F1: below cap the hotfix spends the BUDGET, not the exemption — expected 1 new machine, got $N"
SPAWNED=$(spawnedkeys)
[ "$SPAWNED" = "HF-2 " ] && ok || bad "F1: the one machine below cap must still be the hotfix's (got: $SPAWNED)"
MCOUNT=$(ls "$H/state/fly-pool/tproj"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$MCOUNT" -le 2 ] && ok || bad "F1: the pool must never exceed a cap it had not reached (cap=2, machines=$MCOUNT)"
[ "$(poolline)" = "pool tproj: queued=2 running=1 spawning=1 cap=2 hotfix=1" ] && ok \
  || bad "F1: the tick line must show the budget slot the hotfix spent (got '$(poolline)')"
grep -q 'exceeding it by one machine' "$H/logs/fly-pool.log" \
  && bad "F1: a hotfix that rode a free budget slot must NOT claim it exceeded the cap" || ok
printf '1\n' > "$H/flags/fly-pool-tproj"

# ══ 2c. WHAT IS NOT A HOTFIX STILL TAKES ITS TURN ═══════════════════════════
# Below cap the budget is spent on SOMETHING either way, so "no exemption" is
# not an observable answer here — the ORDER is. Both cases below leave one free
# slot and two queued jobs, and assert the plain older job takes it: that is the
# only way to see that `job_is_hot` itself said no, rather than the outer HOT
# count happening to be 0 for its own reasons.
printf '2\n' > "$H/flags/fly-pool-tproj"
poolqueue
jq -nc '{ticket_id:"2",key:"HF-2",attempt:0,deferrals:0,deaths:0,hotfix:"true"}' \
  > "$H/state/build-queue/tproj/HF-2.json"
N=$(pooltick)
SPAWNED=$(spawnedkeys)
[ "$N" = 1 ] && [ "$SPAWNED" = "HF-1 " ] && ok \
  || bad "a STRING \"true\" must not jump the queue either — expected the older plain job (got $N new: $SPAWNED)"
# The kill flag reaches the ORDERING too, not only the exemption.
poolqueue
N=$(pooltick HOTFIX_LANE=0)
SPAWNED=$(spawnedkeys)
[ "$N" = 1 ] && [ "$SPAWNED" = "HF-1 " ] && ok \
  || bad "HOTFIX_LANE=0 must restore today's mtime order, not just the cap (got $N new: $SPAWNED)"
printf '1\n' > "$H/flags/fly-pool-tproj"

# ══ 3. THE FLAG SURVIVES A DEFERRAL REQUEUE ═════════════════════════════════
# A hotfix that is reaped as BUILD_DEFERRED goes back on the queue. If the flag
# is dropped there, the re-offer is a plain job and the next tick defers it for
# the same cap it was exempt from a minute ago — a hotfix that silently stops
# being one.
mkdir -p "$H/state/remote-results/tproj"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\necho OPEN\n' > "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/artifacts\?*) printf '{"artifacts":[]}\n200\n' ;;
  */api/queue)        printf '{"queued":{"ticket_key":"HF-2","status":"queued"}}\n201\n' ;;
  *)                  printf '{"ok":true}\n200\n' ;;
esac
STUB
cat > "$T/fakebin/base64" <<'STUB'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
STUB
cat > "$T/fakebin/fly-defer" <<'STUB'
#!/bin/bash
DEFER='BUILD_DEFERRED REFUSED box :: box max 1 already running'
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    printf '%s\n' "$DEFER" | /usr/bin/base64 -w0 ;;
  *base64*)           : ;;
  *head*RESULT*)      echo "$DEFER" ;;
  *stat*heartbeat*)   echo 5 ;;
  *) : ;;
esac
exit 0
STUB
# A machine that is simply GONE: no RESULT to read, `machine status` says
# destroyed. This is the death-requeue path, a different jq line from the
# deferral one above and the reason §3b exists at all.
cat > "$T/fakebin/fly-dead" <<'STUB'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: destroyed" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/*

reap_one() { # reap_one <fly-stub> <machine-json-jq> — one tick over one machine
  rm -f "$H/state/build-queue/tproj"/*.json "$H/state/fly-pool/tproj"/*.json
  for p in "$H/builds"/*; do scratch_rm "$p"; done; : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$H/logs/ALERTS.log"
  jq -nc "$2" > "$H/state/fly-pool/tproj/m1.json"
  cp "$T/fakebin/$1" "$T/fakebin/fly"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$H/fleet.conf" REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" \
           FLY_API_TOKEN_TPROJ=tok FLY_BIN_DIR="$T/fakebin"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
qpostmeta() { grep 'POST .*/api/queue ' "$T/req.txt" | head -1 | cut -d' ' -f3- \
                | jq -r '.meta' 2>/dev/null | jq -r '.hotfix' 2>/dev/null; }

reap_one fly-defer '{machine:"m1",key:"HF-2",ticket_id:"2",attempt:0,deferrals:0,hotfix:true}'
[ "$(jq -r '.hotfix' "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)" = true ] && ok \
  || bad "the deferral-requeued job file dropped the hotfix flag: $(cat "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)"
[ "$(qpostmeta)" = true ] && ok \
  || bad "the deferral-re-enqueued ROW dropped the hotfix flag: $(grep 'POST .*/api/queue ' "$T/req.txt" | head -1)"

# ══ 3b. THE FLAG SURVIVES A DEATH REQUEUE ═══════════════════════════════════
# A machine that dies before it writes a RESULT takes a DIFFERENT jq line home
# (deaths+1, no RESULT to read). The flag has to ride that one too, or a hotfix
# whose machine was preempted comes back as ordinary work.
reap_one fly-dead '{machine:"m2",key:"HF-2",ticket_id:"2",attempt:0,deferrals:0,deaths:0,hotfix:true}'
[ "$(jq -r '.hotfix' "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)" = true ] && ok \
  || bad "the death-requeued job file dropped the hotfix flag: $(cat "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)"
[ "$(jq -r '.deaths' "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)" = 1 ] && ok \
  || bad "precondition: §3b must actually take the DEATH path (deaths should be 1): $(cat "$H/state/build-queue/tproj/HF-2.json" 2>/dev/null)"
[ "$(qpostmeta)" = true ] && ok \
  || bad "the death-re-enqueued ROW dropped the hotfix flag: $(grep 'POST .*/api/queue ' "$T/req.txt" | head -1)"

# ══ 4. A PAUSE IS NOT A CAP ═════════════════════════════════════════════════
cp "$T/fakebin/fly.spawn.bak" "$T/fakebin/fly"; chmod +x "$T/fakebin/fly"
poolqueue
touch "$H/flags/paused-tproj"
N=$(pooltick)
[ "$N" = 0 ] && ok || bad "a paused project must get NO exemption and no machine (got $N new)"
grep -q 'waiting on the pause' "$H/logs/fly-pool.log" && ok \
  || bad "the pool must log that a hotfix is waiting on the pause: $(cat "$H/logs/fly-pool.log")"
rm -f "$H/flags/paused-tproj"
N=$(pooltick)
[ "$N" = 1 ] && ok || bad "lifting the pause must let the hotfix through (got $N)"

# ══ 5. A REUSED MACHINE TAKES THE HOTFIX JOB FIRST ══════════════════════════
# A spawn costs ~5 minutes; a reused machine is the FASTEST way an emergency can
# start building, so the job a reaped machine picks up matters as much as the
# one a new machine is spawned for. next_job_or_destroy is extracted and driven
# on its own here, exactly as tests/pool-account-routing-test.sh drives it —
# which is also the reason it must not hard-depend on helpers defined elsewhere
# in the file: sourced alone, a missing helper silently empties the job list and
# destroys a machine that had work waiting.
NR="$T/reuse"; mkdir -p "$NR/q" "$NR/pool" "$NR/bin/lib"
cp "$DIR/bin/lib/hotfix-lib.sh" "$NR/bin/lib/"
sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
sed -n '/^job_is_hot() {/,/^}/p;/^hotfix_first() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/helpers.sh"
[ -s "$NR/fn.sh" ] && grep -q 'REUSED=0' "$NR/fn.sh" && ok || bad "could not extract next_job_or_destroy"
[ -s "$NR/helpers.sh" ] && ok || bad "could not extract job_is_hot/hotfix_first"
printf '#!/bin/bash
echo "$*" >> "${FAKE_FLY_LOG:?}"
' > "$NR/fly"; chmod +x "$NR/fly"

reuse_pick() { # reuse_pick <with-helpers 0|1> -> the key the machine was handed
  rm -f "$NR/q"/*.json "$NR/pool"/*.json "$NR/flylog"; : > "$NR/log"
  # The PLAIN job is older, so mtime order alone would hand the machine TK-OLD.
  jq -nc '{key:"TK-OLD",ticket_id:"1",attempt:0}' > "$NR/q/TK-OLD.json"
  touch -d '2020-01-01' "$NR/q/TK-OLD.json"
  jq -nc '{key:"TK-HOT",ticket_id:"2",attempt:0,hotfix:true}' > "$NR/q/TK-HOT.json"
  jq -nc '{machine:"m1",key:"TK-DONE"}' > "$NR/pool/m1.json"
  ( set +u
    HARNESS="$NR"; P=tproj; APP=app; FLY="$NR/fly"; export FAKE_FLY_LOG="$NR/flylog"
    QDIR="$NR/q"; POOL="$NR/pool"; LOG="$NR/log"
    MID=m1; MSTATE=started; KEY=TK-DONE; MF="$NR/pool/m1.json"; MACCT=""
    STAMP() { echo now; }; say() { echo "$*" >> "$LOG"; }
    mexec() { return 0; }; mput() { return 0; }; push_preplan() { :; }
    pool_account_release() { :; }; pool_account_armed() { return 1; }
    HOTFIX_ON=1
    [ "$1" = 1 ] && { . "$NR/bin/lib/hotfix-lib.sh"; . "$NR/helpers.sh"; }
    . "$NR/fn.sh"
    next_job_or_destroy
    jq -r '.key // "none"' "$NR/pool/m1.json" 2>/dev/null )
}
[ "$(reuse_pick 1)" = TK-HOT ] && ok \
  || bad "a reused machine must take the HOTFIX job, not the oldest one (got $(reuse_pick 1))"
[ -f "$NR/q/TK-OLD.json" ] && ok || bad "the plain job must stay queued for the next machine"
[ "$(jq -r '.hotfix // "absent"' "$NR/pool/m1.json" 2>/dev/null)" = true ] && ok \
  || bad "the reused machine's json must carry the flag forward: $(cat "$NR/pool/m1.json" 2>/dev/null)"
# ...and with the helpers absent the loop must still hand out SOME job rather
# than destroying a machine with work waiting.
[ "$(reuse_pick 0)" = TK-OLD ] && ok \
  || bad "with no hotfix helpers the reuse path must fall back to today's order (got $(reuse_pick 0))"

# ══ 6. THE HUB DISPATCHER TAKES THE HOTFIX JOB FIRST ════════════════════════
# bin/fly-dispatch.sh's persistent-builder lane carries ONE job per project at a
# time, so which queue file it picks IS the ordering — an emergency behind an
# alphabetical accident waits a whole build for it.
D="$T/disp"; mkdir -p "$D/q" "$D/h/flags" "$D/h/bin/lib"
cp "$DIR/bin/lib/hotfix-lib.sh" "$D/h/bin/lib/"
awk '/^  # >>> next job pick/{f=1;next} /^  # <<< next job pick/{exit} f' "$DIR/bin/fly-dispatch.sh" > "$D/pick.sh"
[ -s "$D/pick.sh" ] && ok || bad "could not extract the dispatcher's next-job pick"
grep -q '^[[:space:]]*local[[:space:]]' "$D/pick.sh" \
  && bad "the pick region must not declare \`local\` — it is sourced outside a function here and by the dispatcher's own callers" || ok
# THE DECLARATION IS PART OF THE CONTRACT, so it is extracted verbatim too and
# never re-stated here. The region only ASSIGNS next_job when the lane is on, so
# under `set -u` a bare `local next_job` in the dispatcher aborts the whole
# project subshell the moment the kill flag is set. A `next_job=""` preset in
# this helper would paper over exactly that — production never presets it — so
# the helper sources the dispatcher's OWN declaration line, inside a function,
# the way dispatch_project does.
awk '/^  local next_job/{print; exit}' "$DIR/bin/fly-dispatch.sh" > "$D/decl.sh"
[ -s "$D/decl.sh" ] && ok || bad "could not extract the dispatcher's next_job declaration"
pick() { ( set -uo pipefail; qdir="$D/q"; HARNESS="$D/h"
           . "$D/h/bin/lib/hotfix-lib.sh"
           _pick() { . "$D/decl.sh"; . "$D/pick.sh"; basename "${next_job:-none}"; }
           _pick ) }
jq -nc '{key:"AA-1"}' > "$D/q/AA-1.json"
jq -nc '{key:"ZZ-9",hotfix:true}' > "$D/q/ZZ-9.json"
[ "$(pick)" = ZZ-9.json ] && ok \
  || bad "the dispatcher must take the hotfix job over the alphabetically-first one (got $(pick))"
# F4: the kill flag restores the alphabetical pick, exactly as the docs say.
touch "$D/h/flags/hotfix-lane-off"
[ "$(pick)" = AA-1.json ] && ok \
  || bad "F4: flags/hotfix-lane-off must restore today's alphabetical pick (got $(pick))"
rm -f "$D/h/flags/hotfix-lane-off"
[ "$(pick)" = ZZ-9.json ] && ok || bad "F4: removing the kill flag must restore the hotfix pick (got $(pick))"
rm -f "$D/q/ZZ-9.json"
[ "$(pick)" = AA-1.json ] && ok || bad "with no hotfix queued the pick must be today's (got $(pick))"
# A parked hotfix is not work: it is waiting for bin/blocked-resolver.sh.
jq -nc '{key:"ZZ-9",hotfix:true}' > "$D/q/ZZ-9.failed.json"
[ "$(pick)" = AA-1.json ] && ok || bad "a *.failed.json hotfix park must not be dispatched (got $(pick))"
rm -f "$D/q"/*.json
[ "$(pick)" = none ] && ok || bad "an empty queue must pick nothing (got $(pick))"

# ══ 7. THE FLAG SURVIVES THE DB -> FILE MATERIALISE ═════════════════════════
# The hub turns a coordination-DB row into the queue FILE bin/fly-pool.sh reads.
# A flag lost in this hop is an emergency that arrives at the pool as ordinary
# work — nothing logs a word, and it simply builds late.
DB="$T/db"
mkdir -p "$DB/h/bin" "$DB/h/logs" "$DB/h/flags" "$DB/h/locks" "$DB/h/builds" \
         "$DB/h/state/fly-pool/project-3" "$DB/h/env" "$DB/h/prompts" \
         "$DB/h/catalog/agent-contracts" "$DB/fakebin" "$DB/boxq"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$DB/h/bin/"
mkdir -p "$DB/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$DB/h/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$DB/h/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$DB/h/catalog/agent-contracts/"
: > "$DB/h/env/global.env"
: > "$DB/h/env/fly.env"                   # marks this tree as "the hub"
touch "$DB/h/flags/builder-fly-project-3"
printf '#!/bin/bash\necho "ssh $*" >> "$SSH_SINK"\nexit 0\n' > "$DB/fakebin/ssh"
printf '#!/bin/bash\necho "scp $*" >> "$SSH_SINK"\nexit 0\n'  > "$DB/fakebin/scp"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$DB/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$DB/fakebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$DB/fakebin/tailscale"
cat > "$DB/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
QROW='{"queue":[{"project":"project-3","ticket_key":"TK-9","ticket_id":"9","status":"queued","target":"fly","attempt":2,"claimed_by":null,"enqueued_at":"2026-09-10T01:00:00Z"'"${ROW_META:-}"'}]}'
# §7b drives the DISPATCH half and wants the queue to be exactly the files it
# wrote, so it asks for no rows at all. Unset (§7) is the row above, unchanged.
[ "${NO_QUEUE_ROWS:-}" = 1 ] && QROW='{"queue":[]}'
case "$URL" in
  */api/queue/claim) printf '{"queued":{"project":"project-3","ticket_key":"TK-9","ticket_id":"9","target":"fly","attempt":2,"status":"claimed"},"claimed":true}\n200\n' ;;
  */api/queue\?*)    printf '%s\n200\n' "$QROW" ;;
  *)                 printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$DB/fakebin"/*
dbqfile="$DB/h/state/build-queue/project-3/TK-9.json"
dispatch_db() { # dispatch_db <row-meta-json-fragment>
  rm -f "$dbqfile"; : > "$DB/ssh.txt"; : > "$DB/h/logs/fly-dispatch.log"
  ( export PATH="$DB/fakebin:$PATH" HARNESS="$DB/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           SSH_SINK="$DB/ssh.txt" BOXQ="$DB/boxq" ROW_META="$1" \
           FLEET_CONF="$DB/h/fleet.conf"
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
dispatch_db ',"meta":{"hotfix":true}'
[ -f "$dbqfile" ] && ok || bad "precondition: the queued row must materialise a queue file at all (§7 is vacuous without it)"
[ "$(jq -r '.source' "$dbqfile" 2>/dev/null)" = db ] && ok \
  || bad "precondition: §7 must be driving the DB materialise path: $(cat "$dbqfile" 2>/dev/null)"
[ "$(jq -r '.hotfix' "$dbqfile" 2>/dev/null)" = true ] && ok \
  || bad "the DB -> file materialise dropped the hotfix flag: $(cat "$dbqfile" 2>/dev/null)"
# An ordinary row must still write the file it has always written, key for key.
dispatch_db ''
[ "$(jq -r 'has("hotfix") | not' "$dbqfile" 2>/dev/null)" = true ] && ok \
  || bad "a row with no meta must write no hotfix key at all: $(cat "$dbqfile" 2>/dev/null)"

# ══ 7b. THE KILL FLAG MUST NOT KILL THE DISPATCHER ══════════════════════════
# §6 drives the pick region on its own. This drives the WHOLE bin/fly-dispatch.sh
# through dispatch_project, which is the only place the region actually runs:
# inside a function, under `set -u`, in a `( ... ) &` subshell whose death is
# silent. That is the difference that matters — an uninitialised next_job aborts
# the subshell BEFORE the alphabetical fallback and before the `|| say` at the
# call site, so flags/hotfix-lane-off would quietly stop dispatching every
# persistent-builder project instead of restoring the pre-#368 pick it promises.
# One stderr line, nothing in logs/fly-dispatch.log, and an idle machine.
mkdir -p "$DB/h/state/fly" "$DB/h/bin/lib"
# The lib has to be HERE for the kill flag to reach the pick at all: with no lib
# the dispatcher fails open to lane-on, which is the §7 tree's state and would
# make the case below pass for the wrong reason.
cp "$DIR/bin/lib/hotfix-lib.sh" "$DB/h/bin/lib/"
printf '{"app":"builder-project-3"}\n' > "$DB/h/state/fly/project-3.json"
printf '#!/bin/bash\ncase "${2:-}" in state|start) echo started ;; *) : ;; esac\nexit 0\n' > "$DB/h/bin/fly-api.sh"
printf '#!/bin/bash\nexit 0\n' > "$DB/h/bin/fly-sync-harness.sh"
printf '#!/bin/bash\necho OK\nexit 0\n' > "$DB/h/bin/triage-gate.sh"
printf '#!/bin/bash\ncase "$*" in *"ssh console"*) echo 1 ;; *) : ;; esac\nexit 0\n' > "$DB/fakebin/fly"
chmod +x "$DB/h/bin"/*.sh "$DB/fakebin"/*
# No fly-envbundle.sh stub on purpose: the tick stops at the env bundle and
# un-claims, which is after the pick and costs this fixture no secrets hop. The
# claim line is the observation — it names the file the pick chose.
dispatch_pick() { # dispatch_pick -> the KEY this tick claimed, or nothing
  rm -f "$DB/h/state/fly/project-3-active.json" "$DB/h/state/build-queue/project-3"/*.json
  : > "$DB/h/logs/fly-dispatch.log"
  jq -nc '{ticket_id:"1",key:"AA-1"}'             > "$DB/h/state/build-queue/project-3/AA-1.json"
  jq -nc '{ticket_id:"2",key:"ZZ-9",hotfix:true}' > "$DB/h/state/build-queue/project-3/ZZ-9.json"
  ( export PATH="$DB/fakebin:$PATH" HARNESS="$DB/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           SSH_SINK="$DB/ssh.txt" BOXQ="$DB/boxq" ROW_META="" NO_QUEUE_ROWS=1 \
           FLEET_CONF="$DB/h/fleet.conf" FLY_API_TOKEN_PROJECT_3_OS=tok
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
  sed -n 's/.*claiming job \([^ ]*\) -> active.*/\1/p' "$DB/h/logs/fly-dispatch.log" | head -1
}
[ "$(dispatch_pick)" = ZZ-9 ] && ok \
  || bad "the whole dispatcher must claim the hotfix job (got '$(dispatch_pick)')"
touch "$DB/h/flags/hotfix-lane-off"
[ "$(dispatch_pick)" = AA-1 ] && ok \
  || bad "F4: with the kill flag set the whole dispatcher must still claim a job, alphabetically (got '$(dispatch_pick)')"
rm -f "$DB/h/flags/hotfix-lane-off"
[ "$(dispatch_pick)" = ZZ-9 ] && ok \
  || bad "removing the kill flag must restore the hotfix claim (got '$(dispatch_pick)')"

# ══ 8. THE MACHINE CARRIES THE ANSWER, AND NEVER ASKS GITHUB AGAIN ══════════
# fly/builder-runner.sh runs ON the machine, where there is no test harness to
# drive it: the exec line is the contract, so it is pinned by count (0 fails,
# not passes, when the line is gone).
RUNHITS=$(grep -c 'HOTFIX="\$hotfix"' "$DIR/fly/builder-runner.sh")
[ "$RUNHITS" = 1 ] && ok \
  || bad "fly/builder-runner.sh must export HOTFIX into the run-build.sh exec line exactly once (found $RUNHITS)"
EXECHITS=$(grep -c 'BUILDER_EXEC=1 BUILDER_NO_MERGE=1 HARNESS_CHECKOUT="\$HARNESS" TARGET_BRANCH="\$adopt_head" STACK_BASE="\$stack_base"' "$DIR/fly/builder-runner.sh")
[ "$EXECHITS" = 1 ] && ok \
  || bad "the run-build.sh exec line must keep every variable it already carried (found $EXECHITS)"
JOBHITS=$(grep -c "jq -r '.hotfix // false' \"\$JOB\"" "$DIR/fly/builder-runner.sh")
[ "$JOBHITS" = 1 ] && ok \
  || bad "the runner must read .hotfix off the JOB FILE, not from GitHub (found $JOBHITS)"

echo "hotfix-cap-exempt: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
