#!/bin/bash
# tests/onboard-box-pool.bh-7939-test.sh — the `box` station, path `pool`
# (bin/lib/onboard-box.sh obx_pool, reached through obs_box in
# bin/lib/onboard-stations.sh; BH-7975, slice BH-7939.1).
#
# Each case sources the REAL station lib in a fresh subshell inside its own
# scratch checkout $T/<case>/R. Stubs: ssh (the shared bootstrap block), a
# hostname that is never the box, bin/fly-onboard.sh (logs; the station must
# never run it), `_jobs_req` (serves the case's settings JSON) and OBX_SLEEP
# (one call per poll; it runs the case's act.<n> file, which plays
# bin/fly-onboard.sh and bin/harness-sync.sh writing to disk, and moves the
# case's clock, which OBX_NOW reads, by the poll seconds). No real clock, no
# network, no shared file.
#   P1  queue: the absent line is appended once as `<p> <ISO>`, the drain parse
#       of bin/fly-pool-tick.sh yields <p>; a present line adds nothing;
#       bin/fly-onboard.sh is called 0 times
#   P2  an OK verdict after the offset -> rc 0; pool_app, image, smoke done
#       from the rollout lines; the verdict format pin on bin/fly-onboard.sh
#   P3  ALREADY -> rc 0, the subs with no line are skipped already fly-routed
#   P4  FAILED -> rc 1, the last 20 lines after the offset, redacted
#   P5  the negative verdict table: no row ends the wait; the wait times out
#   P6  timeout -> rc 1 `no FLY_ONBOARD verdict`, the attempts file named
#   P7  already routed -> rc 0, no queue write
#   P8  the queue line removed between polls -> re-appended once
#   P9  the log truncated below the offset, then OK -> rc 0
#   P10 the read-only cancel probe (obs_run_cancelled, BH-7975 comment
#       IC_kwDOTh6ir88AAAABhMfEVA): rc 0 on poll 2 -> rc 1 after exactly 2
#       probes; never rc 0 (worker unreachable) -> the wait runs to its
#       timeout; 0 POST requests across a 3-poll wait (no beat of any kind);
#       gave-up flag -> rc 1 at once; a failed shared bootstrap -> rc 1
#       before any queue write; a bad project name -> rc 1, no ssh
#   K1  every onboard.box_* knob the lib reads is a seed row with the same default
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-box-pool.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected '$3' in: $2"; else ok "$1"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
count() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "$n"; }
STAMP='2026-10-27 11:00:00Z'

# mk_case <name> [project]: the checkout, its stubs and its settings.
mk_case() {
  local C="$T/$1"
  mkdir -p "$C/R/logs" "$C/R/fly" "$C/R/flags" "$C/R/state/fly-onboard" "$C/R/bin" "$C/stub" "$C/env"
  for L in bin/lib/onboard-stations.sh bin/lib/onboard-box.sh bin/lib/cron-lines.sh; do
    ( cd "$DIR" && scratch_install_closure "$L" "$C/R" ) >/dev/null || { bad "$1 could not install $L"; return 1; }
  done
  : > "$C/calls.log"; : > "$C/ssh.log"
  printf '# fly/onboard-queue.conf\nother-os 2026-10-01T00:00:00Z\n' > "$C/R/fly/onboard-queue.conf"
  # Old history before the offset, the same project's FAILED among it.
  printf '%s [fly-onboard/%s] FLY_ONBOARD %s FAILED: an older attempt\n%s [%s] image build FAILED — skipping project\n' \
    "$STAMP" "${2:-acme-os}" "${2:-acme-os}" "$STAMP" "${2:-acme-os}" > "$C/R/logs/fly-pool-rollout.log"
  for i in $(seq 1 8); do echo "$STAMP [other-os] an older rollout step line $i" >> "$C/R/logs/fly-pool-rollout.log"; done
  cat > "$C/R/bin/fly-onboard.sh" <<'S'
#!/bin/bash
echo "fly-onboard.sh $*" >> "$CALLS"
S
  cat > "$C/stub/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$SSH_LOG"
cat >/dev/null
echo "bootstrap block ran"
exit "${SSH_RC:-0}"
S
  cat > "$C/stub/hostname" <<'S'
#!/bin/bash
echo not-the-box
S
  cat > "$C/stub/obx-sleep" <<'S'
#!/bin/bash
n=$(( $(cat "$CASE/sleep.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/sleep.n"
echo $(( $(cat "$CASE/clock" 2>/dev/null || echo 0) + ${1:-0} )) > "$CASE/clock"
[ ! -f "$CASE/act.$n" ] || bash "$CASE/act.$n"
exit 0
S
  # The station's clock (OBX_NOW): epoch 1761562800 plus the seconds the
  # sleep stub was asked to sleep. A poll is the only thing that moves it.
  cat > "$C/stub/obx-now" <<'S'
#!/bin/bash
echo $(( 1761562800 + $(cat "$CASE/clock" 2>/dev/null || echo 0) ))
S
  chmod +x "$C/R/bin/fly-onboard.sh" "$C/stub/"*
  knobs "$1" 4 1
}
# knobs <case> <pool_timeout_s> <poll_s>: the settings answer.
knobs() {
  jq -nc --arg t "$2" --arg p "$3" '{settings: [{key: "onboard.box_pool_timeout_s", value: $t}, {key: "onboard.box_poll_s", value: $p}, {key: "other.key", value: "x"}]}' > "$T/$1/settings.json"
}
# act <case> <n> <shell>: what happens on disk during poll <n>.
act() { printf '%s\n' "$3" > "$T/$1/act.$2"; }
# vline <p> <OK|ALREADY|FAILED>: the verdict line bin/fly-onboard.sh writes.
vline() { printf '%s [fly-onboard/%s] FLY_ONBOARD %s %s: /h/flags/fly-pool-%s=present(cap 4) /h/flags/builder-fly-%s=present free-slots="2"' "$STAMP" "$1" "$1" "$2" "$1" "$1"; }

# station <case> <code> [project]: the real lib in a fresh subshell.
station() {
  local C="$T/$1"
  (
    cd "$C/R" || exit 99
    export CALLS="$C/calls.log" SSH_LOG="$C/ssh.log" CASE="$C"
    PATH="$C/stub:$PATH"
    ROOT="$C/R"
    PROJECT="${3:-acme-os}" SLUG="Acme/${3:-acme-os}" REPO="Acme/${3:-acme-os}" PROD=- BOX=zzz-box PREFIX=AO BASE=main
    HARNESS_REPO=o/h HARNESS_ENV_DIR="$C/env" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake"
    export OBS_BOX_PATH=pool OBX_SLEEP="$C/stub/obx-sleep" OBX_NOW="$C/stub/obx-now"
    unset REGISTRY_SOURCE REG_MODE OBS_HAVE_BOX
    _jobs_req() { echo "$1 $2" >> "$CASE/req.log"; [ "$1 $2" = "GET /api/settings" ] || return 1; cat "$CASE/settings.json"; }
    # shellcheck source=bin/lib/onboard-stations.sh
    . bin/lib/onboard-stations.sh || { echo "source failed"; exit 98; }
    eval "$2"
  ) 2>&1
}
qlines() { grep -cE "^${2:-acme-os}([[:space:]]|$)" "$T/$1/R/fly/onboard-queue.conf"; }
LOGF() { printf '%s' "$T/$1/R/logs/fly-pool-rollout.log"; }

# P1 — the queue append, and the drain's own parse reads it.
mk_case p1
act p1 1 "echo '$(vline acme-os OK)' >> '$(LOGF p1)'"
out=$(station p1 'obs_box; echo "rc=$?"')
has "P1 rc 0" "$out" "rc=0"
eq "P1 one queue line" "$(qlines p1)" 1
eq "P1 the line is <p> <ISO>" "$(grep -cE '^acme-os [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$T/p1/R/fly/onboard-queue.conf")" 1
eq "P1 the drain parse yields the project" "$(grep -vE '^[[:space:]]*(#|$)' "$T/p1/R/fly/onboard-queue.conf" | awk '{print $1}' | tr '\n' ' ')" "other-os acme-os "
has "P1 queue beat" "$out" "BEAT box.queue done queued offset="
eq "P1 bin/fly-onboard.sh called 0 times" "$(grep -c fly-onboard "$T/p1/calls.log")" 0
has "P1 the shared bootstrap ran first" "$out" "BEAT box.bootstrap done"
eq "P1 ssh ran the bootstrap block once" "$(grep -c 'root@zzz-box' "$T/p1/ssh.log")" 1
eq "P1 the shared bootstrap keeps the default host-key policy" "$(grep -c 'StrictHostKeyChecking' "$T/p1/ssh.log")" 0
rm -f "$T/p1/sleep.n"; act p1 1 "echo '$(vline acme-os OK)' >> '$(LOGF p1)'"
out=$(station p1 'obs_box; echo "rc=$?"')
eq "P1 a second run adds no line" "$(qlines p1)" 1
has "P1 a second run says already queued" "$out" "BEAT box.queue done already queued"

# P2 — OK after the offset, the rollout step lines become sub-lines.
mk_case p2
act p2 1 "{ echo '$STAMP [acme-os] building image (depot)'; echo '$STAMP [acme-os] image: registry.fly.io/builder-acme-os:deploy-01'; echo '$STAMP [other-os] SMOKE_OK on pool machine 1'; }  >> '$(LOGF p2)'"
act p2 2 "{ echo '$STAMP [acme-os] SMOKE_OK on pool machine e2860f1c4a7d98'; echo '$(vline acme-os OK)'; } >> '$(LOGF p2)'"
out=$(station p2 'obs_box; echo "rc=$?"')
has "P2 rc 0" "$out" "rc=0"
has "P2 pool_app done" "$out" "BEAT box.pool_app done"
has "P2 image done with the ref" "$out" "BEAT box.image done registry.fly.io/builder-acme-os:deploy-01"
has "P2 smoke done" "$out" "BEAT box.smoke done SMOKE_OK on pool machine e2860f1c4a7d98"
has "P2 queue done on the verdict" "$out" "BEAT box.queue done FLY_ONBOARD acme-os OK"
eq "P2 the summary is the last block, in path order" "$(sed -n '/^== box summary ==$/,$p' <<<"$out" | grep -oE '^BEAT box\.[a-z_]+' | tr '\n' ' ')" "BEAT box.bootstrap BEAT box.queue BEAT box.pool_app BEAT box.image BEAT box.smoke "
# The format the station reads is the format bin/fly-onboard.sh writes.
has "P2 pin: say() tags the line [fly-onboard/<p>]" "$(cat "$DIR/bin/fly-onboard.sh")" "printf '%s [fly-onboard/%s] %s\n' \"\$(STAMP)\" \"\$P\" \"\$*\""
has "P2 pin: the verdict is FLY_ONBOARD \$P \$1:" "$(cat "$DIR/bin/fly-onboard.sh")" 'say "FLY_ONBOARD $P $1: '

# P3 — ALREADY.
mk_case p3
act p3 1 "echo '$(vline acme-os ALREADY)' >> '$(LOGF p3)'"
out=$(station p3 'obs_box; echo "rc=$?"')
has "P3 rc 0" "$out" "rc=0"
for s in pool_app image smoke; do has "P3 $s skipped" "$out" "BEAT box.$s skipped already fly-routed"; done

# P4 — FAILED: the tail, redacted.
mk_case p4
GHS="ghs_fixture$(printf 'A%.0s' $(seq 1 29))"
{
  for i in $(seq 1 6); do echo "echo '$STAMP [other-os] filler line $i' >> '$(LOGF p4)'"; done
  echo "echo '$STAMP [acme-os] deploy token FlyV1 fm2_fixtureAbC123/xyz=' >> '$(LOGF p4)'"
  echo "echo '$STAMP [acme-os] key tskey-auth-k123fixture-abc' >> '$(LOGF p4)'"
  echo "echo '$STAMP [acme-os] clone with $GHS' >> '$(LOGF p4)'"
  for i in $(seq 7 22); do echo "echo '$STAMP [acme-os] step line $i' >> '$(LOGF p4)'"; done
  echo "echo '$STAMP [acme-os] smoke FAILED (push_ok=0 step=none) — skipping project' >> '$(LOGF p4)'"
  echo "echo '$(vline acme-os FAILED)' >> '$(LOGF p4)'"
} > "$T/p4/act.1"
out=$(station p4 'obs_box; echo "rc=$?"')
has "P4 rc 1" "$out" "rc=1"
has "P4 smoke failed" "$out" "BEAT box.smoke failed smoke FAILED"
has "P4 queue failed with the verdict" "$out" "BEAT box.queue failed FLY_ONBOARD acme-os FAILED"
hasnt "P4 no Fly token" "$out" "fm2_fixtureAbC123"
hasnt "P4 no Tailscale key" "$out" "tskey-auth-k123fixture"
hasnt "P4 no GitHub token" "$out" "$GHS"
has "P4 redacted" "$out" "<redacted>"
TAIL=$(sed -n '/^== rollout log tail ==$/,/^== box summary ==$/p' <<<"$out" | sed '1d;$d')
eq "P4 the tail is 20 lines" "$(grep -c . <<<"$TAIL")" 20
has "P4 the tail ends with the verdict" "$(tail -1 <<<"$TAIL")" "FLY_ONBOARD acme-os FAILED"
hasnt "P4 the tail starts after the offset" "$TAIL" "an older attempt"
has "P4 line 7 of the act is in the tail" "$TAIL" "step line 7"
hasnt "P4 the oldest filler is cut" "$TAIL" "filler line 1"

# P5 — the negative table: no row is a verdict for acme-os after the offset.
mk_case p5
knobs p5 3 1
{
  echo "echo '$STAMP [fly-onboard/acme-osx] FLY_ONBOARD acme-osx OK: x' >> '$(LOGF p5)'"
  echo "echo '$STAMP [fly-onboard/acme] FLY_ONBOARD acme FAILED: x' >> '$(LOGF p5)'"
  echo "echo '$STAMP [fly-onboard/acme-os] FLY_ONBOARD acme-os OKAY: x' >> '$(LOGF p5)'"
  echo "echo '$STAMP [fly-onboard/acme-os] FLY_ONBOARD acme-os ok: x' >> '$(LOGF p5)'"
  echo "echo \"Check on the hub:  grep 'FLY_ONBOARD acme-os' logs/fly-pool-rollout.log\" >> '$(LOGF p5)'"
  echo "echo '$STAMP [pool/acme-os] fly-onboard queued line -> launching' >> '$(LOGF p5)'"
  echo "echo '$STAMP [fly-onboard/acme-os] FLY_ONBOARD other-os OK: x' >> '$(LOGF p5)'"
  echo "echo '$STAMP FLY_ONBOARD acme-os OK: no tag' >> '$(LOGF p5)'"
  echo "echo '$STAMP [fly-onboard/other-os] FLY_ONBOARD acme-os OK: another project tag' >> '$(LOGF p5)'"
} > "$T/p5/act.1"
out=$(station p5 'obs_box; echo "rc=$?"')
has "P5 rc 1" "$out" "rc=1"
has "P5 no row ended the wait" "$out" "no FLY_ONBOARD verdict for acme-os in 3s"
has "P5 the old FAILED before the offset did not end it" "$out" "BEAT box.queue failed no FLY_ONBOARD verdict"

# P6 — timeout, with the drain ledger named.
mk_case p6
knobs p6 2 1
echo 1 > "$T/p6/R/state/fly-onboard/acme-os.attempts"; echo 1761562800 > "$T/p6/R/state/fly-onboard/acme-os.last"
out=$(station p6 'obs_box; echo "rc=$?"')
has "P6 rc 1" "$out" "rc=1"
has "P6 timeout text" "$out" "BEAT box.queue failed no FLY_ONBOARD verdict for acme-os in 2s"
has "P6 the attempts are named" "$out" "attempts=1"
eq "P6 two polls" "$(cat "$T/p6/sleep.n")" 2

# P7 — already routed: no queue write.
mk_case p7
: > "$T/p7/R/flags/fly-pool-acme-os"; : > "$T/p7/R/flags/builder-fly-acme-os"
out=$(station p7 'obs_box; echo "rc=$?"')
has "P7 rc 0" "$out" "rc=0"
eq "P7 no queue line" "$(qlines p7)" 0
for s in pool_app image smoke; do has "P7 $s skipped" "$out" "BEAT box.$s skipped already fly-routed"; done
eq "P7 no poll" "$(cat "$T/p7/sleep.n" 2>/dev/null || echo 0)" 0

# P8 — harness-sync rewrites the queue file between polls.
mk_case p8
act p8 1 "sed -i '/^acme-os /d' '$T/p8/R/fly/onboard-queue.conf'"
act p8 3 "sed -i '/^acme-os /d' '$T/p8/R/fly/onboard-queue.conf'"
act p8 4 "echo '$(vline acme-os OK)' >> '$(LOGF p8)'"
knobs p8 10 1
out=$(station p8 'obs_box; echo "rc=$?"')
has "P8 rc 0" "$out" "rc=0"
eq "P8 the line is back" "$(qlines p8)" 1
eq "P8 re-queued said once" "$(grep -c 're-queued after a sync' <<<"$(sed '/^== box summary ==$/,$d' <<<"$out")")" 1

# P9 — the log is rotated below the offset, then OK.
mk_case p9
act p9 1 ": > '$(LOGF p9)'; echo '$(vline acme-os OK)' >> '$(LOGF p9)'"
out=$(station p9 'obs_box; echo "rc=$?"')
has "P9 rc 0" "$out" "rc=0"
has "P9 OK read from the new log" "$out" "BEAT box.queue done FLY_ONBOARD acme-os OK"

# P10 — the cancel probe is a read: it ends the wait only on its rc 0.
mk_case p10
knobs p10 10 1
PROBE='obs_run_cancelled() { local n; n=$(( $(cat "$CASE/probe.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/probe.n"; [ "$n" -ge "${CANCEL_AT:-999}" ]; }'
out=$(CANCEL_AT=2 station p10 "$PROBE; export CANCEL_AT; obs_box; echo \"rc=\$?\"")
has "P10 cancelled rc 1" "$out" "rc=1"
has "P10 cancelled text" "$out" "box: the run was cancelled"
has "P10 cancelled beat" "$out" "BEAT box.queue failed the run was cancelled"
eq "P10 exactly 2 probes" "$(cat "$T/p10/probe.n")" 2
eq "P10 2 polls" "$(cat "$T/p10/sleep.n")" 2
mk_case p10x
knobs p10x 3 1
out=$(station p10x "$PROBE; obs_box; echo \"rc=\$?\"")
has "P10 an unreachable worker: the wait runs to its timeout" "$out" "BEAT box.queue failed no FLY_ONBOARD verdict for acme-os in 3s"
has "P10 an unreachable worker: rc 1" "$out" "rc=1"
eq "P10 an unreachable worker: one probe per poll" "$(cat "$T/p10x/probe.n")" 3
hasnt "P10 an unreachable worker: not read as a cancel" "$out" "the run was cancelled"
eq "P10 a 3-poll wait sends 0 POST requests" "$(grep -c '^POST' "$T/p10x/req.log")" 0
eq "P10 a 3-poll wait reads the settings once" "$(grep -c '^GET /api/settings$' "$T/p10x/req.log")" 1
mk_case p10b
: > "$T/p10b/R/flags/alerted-fly-onboard-gaveup-acme-os"
out=$(station p10b 'obs_box; echo "rc=$?"')
has "P10 gave up rc 1" "$out" "rc=1"
has "P10 gave up names the attempts file" "$out" "rm state/fly-onboard/acme-os.attempts"
has "P10 gave up names the flag" "$out" "rm flags/alerted-fly-onboard-gaveup-acme-os"
eq "P10 gave up: no queue line" "$(qlines p10b)" 0
eq "P10 gave up: no poll" "$(cat "$T/p10b/sleep.n" 2>/dev/null || echo 0)" 0
mk_case p10c
out=$(SSH_RC=3 station p10c 'obs_box; echo "rc=$?"')
has "P10 failed bootstrap rc" "$out" "rc=1"
has "P10 failed bootstrap beat" "$out" "BEAT box.bootstrap failed"
eq "P10 failed bootstrap: no queue line" "$(qlines p10c)" 0
mk_case p10d
out=$(station p10d 'obs_box; echo "rc=$?"' 'Bad_Name')
has "P10 bad project name rc 1" "$out" "rc=1"
eq "P10 bad project name: no ssh" "$(count "$T/p10d/ssh.log")" 0

# K1 — the knob rows: every key the lib reads is seeded, with the code default.
FRAG=$(ls "$DIR"/worker/jobs/schema.d/*-bh-7939-onboard-box-settings.sql 2>/dev/null | head -1)
[ -n "$FRAG" ] && ok "K1 the fragment exists" || bad "K1 no worker/jobs/schema.d/*-bh-7939-onboard-box-settings.sql"
LIBK=$(grep -oE "_obx_k[sn] \"\\\$s\" onboard\.box_[a-z_]+ '[^']*'" "$DIR/bin/lib/onboard-box.sh" | awk '{print $3, $4}' | sort)
SEEDK=$(grep -oE "\('onboard\.box_[a-z_]+','[^']*'" "${FRAG:-/dev/null}" | sed -E "s/^\('//; s/','/ '/" | sort)
eq "K1 the lib reads 7 knobs" "$(grep -c . <<<"$LIBK")" 7
eq "K1 the seed rows equal the lib knobs and defaults" "$SEEDK" "$LIBK"
# Behaviour: with no settings answer the defaults run (pool timeout 3600 shows up in the timeout text).
mk_case k1
echo 'not json' > "$T/k1/settings.json"
out=$(station k1 '. bin/lib/onboard-box.sh && obx_knobs_dump')
has "K1 default pool timeout" "$out" "pool_timeout_s=3600"
has "K1 default region" "$out" "region=iad"
knobs k1 99999999 1
out=$(station k1 '. bin/lib/onboard-box.sh && obx_knobs_dump')
has "K1 an out-of-range row is the default" "$out" "pool_timeout_s=3600"

echo "onboard-box-pool.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
