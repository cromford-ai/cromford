#!/bin/bash
# tests/hub-move.bh-7715-test.sh — bin/hub-move.sh, its Fly seam
# (bin/lib/hub-move-fly.sh), its no-write shim (bin/lib/hub-move-nowrite.sh)
# and the hub entrypoint (fly/hub/entrypoint.sh) (BH-7715).
#
# No real vendor is called. flyctl, tailscale, ssh, scp, rsync, crontab and the
# no-write shim's "real" binaries are PATH stubs that record their argv. ssh
# runs its command on this box against a scratch "target" harness, so a remote
# step reads and writes the target fixture. Each case builds its own scratch
# old hub and target under $T/<case>.
#
# Cases: F1-F6 Fly seam, E1-E4 entrypoint, P1-P7 provision and inventory,
# W1-W21 the shim decision table, D1-D13 seed/tick/dry-run, C1-C12 cutover,
# rollback, proof and the no-reference grep, R1 target.json round trip, S1 the
# test-sandbox path guard, B1 no real vendor binary on the suite's PATH.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-move.bh-7715-test.sh
# determinism: ok-file race-wall-bound the tick timeout and parallel cases time real child processes on purpose, with 1-5 s margins
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
HM_REL=bin/hub-move.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in: ${2:0:600}"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }

export HUB_MOVE_NOW=1700000000
STUB="$T/stub"; mkdir -p "$STUB"

# ---- PATH stubs (vendors) ----------------------------------------------------
# Every stub appends "<name> <argv>" to $VC (the case's vendor-call log).
cat > "$STUB/flyctl" <<'EOF'
#!/bin/bash
printf 'flyctl %s\n' "$*" >> "$VC"
D="$FLYD"; mkdir -p "$D"
[ -e "$D/ratelimit" ] && { echo "Error: 429 Too Many Requests: rate limited" >&2; exit 1; }
case "$1 $2" in
  "apps list")    [ -e "$D/fail-list" ] && { echo "Error: boom" >&2; exit 1; }
                  if [ -s "$D/apps" ]; then jq -R '{Name:.}' "$D/apps" | jq -s .; else echo '[]'; fi ;;
  "apps create")  echo "$3" >> "$D/apps" ;;
  "volumes list") [ -e "$D/fail-vol" ] && { echo "Error: boom" >&2; exit 1; }
                  cat "$D/volumes.json" 2>/dev/null || echo '[]' ;;
  "volumes create") printf '[{"id":"vol_fixture1","name":"%s"}]\n' "$3" > "$D/volumes.json" ;;
  "machine list") cat "$D/machines.json" 2>/dev/null || echo '[]' ;;
  "machine run")  echo '[{"id":"m_fixture1"}]' > "$D/machines.json" ;;
  "secrets import") sed 's/=.*//' >> "$D/secret-keys" ;;
  *) echo "flyctl stub: unknown $*" >&2; exit 9 ;;
esac
EOF
cat > "$STUB/tailscale" <<'EOF'
#!/bin/bash
printf 'tailscale %s\n' "$*" >> "$VC"
case "$1" in
  status) cat "$TSJSON" 2>/dev/null || echo '{"Peer":{}}' ;;
  ip) echo 192.0.2.10 ;;
esac
EOF
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
host=""; while [ $# -gt 1 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) host="$1"; shift; break ;; esac; done
printf 'ssh %s %s\n' "$host" "$*" >> "$VC"
exec bash -c "$*"
EOF
cat > "$STUB/scp" <<'EOF'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$VC"
args=(); while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -q) shift ;; *) args+=("$1"); shift ;; esac; done
dst="${args[-1]}"; unset 'args[-1]'
cp "${args[@]}" "${dst#*:}"
EOF
cat > "$STUB/rsync" <<'EOF'
#!/bin/bash
printf 'rsync %s\n' "$*" >> "$VC"
EOF
cat > "$STUB/crontab" <<'EOF'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "$VC"
case "${1:-}" in
  -l) [ -f "$CRONTAB_FILE" ] || { echo "no crontab for root" >&2; exit 1; }; cat "$CRONTAB_FILE" ;;
  -r) rm -f "$CRONTAB_FILE" ;;
  *)  cp "$1" "$CRONTAB_FILE" ;;
esac
EOF
for n in gh curl wrangler claude codex; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$VC"\n' "$n" > "$STUB/$n"
done
chmod +x "$STUB"/*
BASEPATH="$STUB:$PATH"

# ---- per-case scratch --------------------------------------------------------
# newcase <name>: $C, $H (old hub), $TGT (target), stubs, env for hub-move.
newcase() {
  C="$T/$1"; H="$C/h"; TGT="$C/target"
  mkdir -p "$H/state" "$H/flags" "$H/logs" "$H/env" "$TGT/state" "$TGT/flags" "$C/hssh" "$C/fly"
  scratch_install_closure "$HM_REL" "$H" >/dev/null || bad "$1: closure into h"
  scratch_install_closure "$HM_REL" "$TGT" >/dev/null || bad "$1: closure into target"
  # bin/lib/flags.sh loads bin/jobs-client.sh and its bin/lib/jobs modules at
  # run time, which the closure scan does not follow; copy them as the other
  # flag suites do. JOBS_URL is empty (tests/lib/scratch.sh) and global.env
  # names none, so every flag verb takes the no-worker flags/ file path
  # (BH-4153); a fixture secret keeps that path quiet (no alerted-* marker).
  export HARNESS_SECRET=fixture-secret
  local jside
  for jside in "$H" "$TGT"; do
    # scratch-closure-allow: bin/lib/flags.sh loads bin/jobs-client.sh and its JC_MODULES at run time, which the closure scan cannot follow
    mkdir -p "$jside/bin/lib/jobs" && cp "$REPO/bin/jobs-client.sh" "$jside/bin/" && cp "$REPO"/bin/lib/jobs/*.sh "$jside/bin/lib/jobs/" \
      || bad "$1: jobs-client into $jside"
  done
  printf 'hub\n' > "$H/state/box-id"; printf 'box-hub\n' > "$H/state/box-name"
  # BH-8038: a no-write tick runs only on a box seed marked as the target.
  mkdir -p "$TGT/state/hub-move"; printf 'seeded fixture\n' > "$TGT/state/hub-move/target-seeded"
  export VC="$C/vendor-calls" CALLS="$C/calls" FLYD="$C/fly" TSJSON="$C/ts.json" CRONTAB_FILE="$C/crontab"
  : > "$VC"; : > "$CALLS"
  export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HUB_MOVE_TARGET_HARNESS="$TGT"
  export HUB_MOVE_TARGET_SECRETS="$C/tsec" HUB_MOVE_TARGET_SSH_DIR="$C/tssh" HUB_MOVE_SSH_DIR="$C/hssh"
  export HARNESS_CHECKOUT="$C/co" HUB_MOVE_IMAGE="registry.example/hub:fixture"
  export HUB_MOVE_TS_WAIT_S=0 HUB_MOVE_LEASE_WAIT_S=0 HUB_MOVE_DRAIN_TIMEOUT_S=1
  unset BACKUP_AGE_IDENTITY_FILE HUB_MOVE_VOLUME_GB HUB_MOVE_TICK_PARALLEL HUB_MOVE_TICK_TIMEOUT_S FLY_BIN_DIR FLYCTL_INSTALL HUB_MOVE_NOWRITE
  # An empty stand-in for /root/.fly/bin, so a box with a real flyctl there does not refuse each no-write tick.
  export HUB_MOVE_FLY_HOME_BIN="$C/flyhome"
  # The orchestrator trees the seed and rollback swap. Every case gets its own:
  # an unset pair defaults to /root/orchestrator, the hub's real tree (BH-7715).
  export HUB_MOVE_ORCH="$C/lorch" HUB_MOVE_TARGET_ORCH="$C/torch"
  export PATH="$BASEPATH"
  printf 'ssh-ed25519 AAAAfixture hub@example\n' > "$C/hssh/id_ed25519.pub"
  printf 'fixture-private-key\n' > "$C/hssh/id_ed25519"
  printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN="FlyV1 tok-fixture-1"\nTS_AUTHKEY_HUB=tskey-fixture-1\n' > "$H/env/fly.env"
  printf 'BACKUP_S3_ENDPOINT=https://s3.example\nBACKUP_S3_ACCESS_KEY_ID=akid-fixture\nBACKUP_S3_SECRET_ACCESS_KEY=secret-fixture-value\nGH_APP_SECRET=ghvalue-fixture-zz\n' > "$H/env/global.env"
  printf 'AGE-SECRET-KEY-FIXTURE\n' > "$C/age.key"
  # bin stubs on both sides: "<side>:<name> <argv>" into $CALLS.
  local side dir n
  for side in h target; do
    dir="$C/$side/bin"
    for n in state-restore state-backup bootstrap-machine update-runners hub-lease hub-load-report migrate-env-dir harness-sync alert-line; do
      cat > "$dir/$n.sh" <<EOF
#!/bin/bash
printf '%s:%s %s\n' "$side" "$n" "\$*" >> "\$CALLS"
EOF
    done
    printf '#!/bin/bash\nif [ "$1" = --projects ]; then printf "alpha-os\\nbeta-os\\n"; fi\n' > "$dir/fleet-conf.sh"
    # The DEPLOYED bin has no cron/ sibling, so its render-cron.sh fails the
    # way /root/harness/bin/render-cron.sh does; the checkout's renders (D13).
    printf '#!/bin/bash\necho "render-cron.sh: no %s/cron/lanes" >&2; exit 1\n' "$C/$side" > "$dir/render-cron.sh"
    chmod +x "$dir"/*.sh
  done
  # The git checkout (HARNESS_CHECKOUT) that hub-move renders the crontab from.
  # No .git, so seed does not rsync it.
  mkdir -p "$C/co/bin" "$C/co/cron/lanes"
  printf '#!/bin/bash\ncat "%s/cron.txt"\n' "$C" > "$C/co/bin/render-cron.sh"
  chmod +x "$C/co/bin/render-cron.sh"
  # state-restore on both sides: it writes the snapshot into --live (and
  # --orchestrator-live) the way bin/restore-merge.sh does, KEEP-LIVE (rule 5):
  # a file that already exists is never overwritten. Lead BLOCK #3203 on #7757:
  # the old stub wrote unconditionally, so the suite could not see that a
  # restore over a live tree keeps the live state.
  for side in h target; do
    dir="$C/$side/bin"
    cat > "$dir/state-restore.sh" <<EOF
#!/bin/bash
printf '%s:state-restore %s\n' "$side" "\$*" >> "\$CALLS"
live=""; orch=""
while [ \$# -gt 0 ]; do case "\$1" in --live) live="\$2"; shift 2 ;; --orchestrator-live) orch="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$live" ] || exit 2
put() { [ -e "\$1" ] && return 0; mkdir -p "\$(dirname "\$1")"; printf '%s\n' "\$2" > "\$1"; }
put "\$live/state/box-id" "\${RESTORE_BOX_ID:-hub}"
put "\$live/state/box-name" "\${RESTORE_BOX_NAME:-box-hub}"
put "\$live/flags/automerge-disabled" ""
put "\$live/state/cursor" "snapshot-\${RESTORE_SNAP_TAG:-x}"
put "\$live/builds/BH-1/RESULT" "snapshot-\${RESTORE_SNAP_TAG:-x}"
put "\$live/env/snap.env" "SNAP=\${RESTORE_SNAP_TAG:-x}"
[ -z "\$orch" ] || put "\$orch/orch-state" "snapshot-\${RESTORE_SNAP_TAG:-x}"
EOF
    chmod +x "$dir/state-restore.sh"
  done
  : > "$C/cron.txt"
}
hm() { bash "$H/bin/hub-move.sh" "$@"; }
peer_json() { printf '{"Peer":{"n1":{"HostName":"box-hub","TailscaleIPs":["192.0.2.44","fd7a::1"]}}}\n' > "$TSJSON"; }
target_ready() { mkdir -p "$H/state/hub-move"; printf '{"app":"harness-hub","ts_ip":"192.0.2.44"}\n' > "$H/state/hub-move/target.json"; }

# ==== F: Fly seam ==============================================================
newcase f
. "$H/bin/lib/hub-move-fly.sh"
hmf_app_exists app-x; check F1-absent "$?" 1
echo app-x > "$FLYD/apps"
hmf_app_exists app-x; check F1-present "$?" 0
touch "$FLYD/fail-list"; hmf_app_exists app-x 2>/dev/null; check F2-unreadable-is-2 "$?" 2; rm -f "$FLYD/fail-list"
touch "$FLYD/ratelimit"; hmf_app_exists app-x 2>/dev/null; check F3-ratelimit-75 "$?" 75; rm -f "$FLYD/ratelimit"
v=$(hmf_volume_find app-x hub_data); check F3-vol-absent "$?" 1
printf '[{"id":"vol_a","name":"other"},{"id":"vol_b","name":"hub_data"}]' > "$FLYD/volumes.json"
v=$(hmf_volume_find app-x hub_data); check F3-vol-id "$v" vol_b
printf 'not json' > "$FLYD/volumes.json"
hmf_volume_find app-x hub_data >/dev/null; check F3-vol-badjson-2 "$?" 2
printf 'tskey-fixture-9\n' | hmf_secret_set_stage app-x TS_AUTHKEY
check F3-secret-key-only "$(cat "$FLYD/secret-keys")" TS_AUTHKEY
hasnt F3-secret-not-in-argv "$(cat "$VC")" tskey-fixture-9

# F4: a second provision makes 0 create calls; F5: an unreadable find creates nothing.
newcase f4; peer_json
hm provision >/dev/null 2>&1; check F4-first-rc "$?" 0
: > "$VC"
hm provision >/dev/null 2>&1; check F4-second-rc "$?" 0
check F4-second-no-create "$(grep -cE 'apps create|volumes create|machine run|secrets import' "$VC")" 0
newcase f5; peer_json; touch "$FLYD/fail-list"
hm provision >/dev/null 2>&1; check F5-rc "$?" 4
check F5-no-create "$(grep -cE 'create|machine run|secrets' "$VC")" 0
check F5-no-target-json "$( [ -e "$H/state/hub-move/target.json" ] && echo yes || echo no)" no
newcase f5b; peer_json; echo harness-hub > "$FLYD/apps"; touch "$FLYD/fail-vol"
hm provision >/dev/null 2>&1; check F5b-vol-unreadable-rc "$?" 4
check F5b-no-create "$(grep -cE 'volumes create|machine run' "$VC")" 0
newcase f6; peer_json; touch "$FLYD/ratelimit"
hm provision >/dev/null 2>&1; check F6-ratelimit-rc "$?" 75

# ==== E: entrypoint ============================================================
newcase e
ER="$C/root"; mkdir -p "$ER/data" "$C/estub"
for n in tailscaled sshd cron ssh-keygen; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/ecalls"\n' "$n" "$C" > "$C/estub/$n"
done
printf '#!/bin/bash\nprintf "tailscale %%s\\n" "$*" >> "%s/ecalls"\n' "$C" > "$C/estub/tailscale"
printf '#!/bin/bash\nf=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done; echo key > "$f"\n' > "$C/estub/ssh-keygen"
chmod +x "$C/estub"/*
mkdir -p "$ER/root/.claude"; echo rules > "$ER/root/.claude/CLAUDE.md"
boot() { HUB_TS_SOCKET_WAIT_S=0 HUB_ENTRYPOINT_ROOT="$ER" PATH="$C/estub:$PATH" HUB_TS_HOSTNAME=box-hub "$@" bash "$REPO/fly/hub/entrypoint.sh" >"$C/eout" 2>&1; }
boot env TS_AUTHKEY=tskey-fixture-e HUB_AUTHORIZED_KEY="ssh-ed25519 AAAAfixture op@example"; check E1-rc "$?" 0
for p in root/harness root/harness-checkout etc/harness root/repos root/.ssh root/.claude root/.config var/spool/cron/crontabs; do
  [ -L "$ER/$p" ] && [ -d "$ER/$p/" ] && ok || bad "E1: $p is not a symlink to a dir"
done
check E1-image-dir-kept "$(cat "$ER/data/root-claude/CLAUDE.md" 2>/dev/null)" rules
has E1-hostname "$(cat "$C/ecalls")" "--hostname box-hub"
has E1-cron-last "$(tail -1 "$C/ecalls")" "cron -f"
check E1-authkey-once "$(grep -c AAAAfixture "$ER/data/root-ssh/authorized_keys")" 1
echo keep > "$ER/data/harness/marker"; mkdir -p "$ER/data/cron-spool"
boot env TS_AUTHKEY= HUB_AUTHORIZED_KEY="ssh-ed25519 AAAAfixture op@example" < /dev/null
check E2-rc-resume-needs-state "$?" 1
echo state > "$ER/data/tailscaled.state"
boot env TS_AUTHKEY= HUB_AUTHORIZED_KEY="ssh-ed25519 AAAAfixture op@example"; check E2-second-boot-rc "$?" 0
check E2-data-kept "$(cat "$ER/root/harness/marker")" keep
check E2-authkey-not-duplicated "$(grep -c AAAAfixture "$ER/data/root-ssh/authorized_keys")" 1
check E3-no-crontab "$(ls -A "$ER/data/cron-spool" | wc -l)" 0
hasnt E3-no-crontab-call "$(cat "$C/ecalls")" crontab
rm -f "$ER/data/tailscaled.state"; : > "$C/ecalls"
boot env TS_AUTHKEY=; check E4-fail-closed-rc "$?" 1
hasnt E4-no-cron "$(cat "$C/ecalls")" "cron -f"

# ==== P: provision and inventory ===============================================
newcase p1
out=$(hm provision --plan 2>&1); check P1-rc "$?" 0
check P1-six-actions "$(printf '%s\n' "$out" | grep -c '^PLAN provision [1-6]/6')" 6
check P1-no-vendor-call "$(wc -l < "$VC")" 0
newcase p2; peer_json
hm provision >"$C/out" 2>&1; check P2-rc "$?" 0
check P2-order "$(grep -oE 'apps create|volumes create|machine run' "$VC" | tr '\n' ',')" "apps create,volumes create,machine run,"
has P2-size "$(grep 'machine run' "$VC")" "--vm-size performance-16x --vm-memory 32768"
has P2-volume "$(grep 'volumes create' "$VC")" "--size 200"
has P2-image "$(grep 'machine run' "$VC")" "registry.example/hub:fixture"
check P2-secrets "$(sort "$FLYD/secret-keys" | tr '\n' ' ')" "HUB_AUTHORIZED_KEY TS_AUTHKEY "
hasnt P2-no-secret-in-argv "$(cat "$VC")" tskey-fixture-1
check P2-ts-ip "$(jq -r .ts_ip "$H/state/hub-move/target.json")" 192.0.2.44
check P2-machine "$(jq -r .machine_id "$H/state/hub-move/target.json")" m_fixture1
check P2-volume-id "$(jq -r .volume_id "$H/state/hub-move/target.json")" vol_fixture1
hasnt P2-no-orgo "$(cat "$VC" "$CALLS")" orgo
# The app provision creates is exempt from bin/fly-idle-reaper.sh, which runs on the hub.
app=$(jq -r .app "$H/state/hub-move/target.json")
check P2-app-default "$app" harness-hub
check P2-app-reaper-exempt "$(jq -r --arg a "$app" '.apps[$a].source // "none"' "$REPO/catalog/fly-idle-signals.json")" exempt
newcase p3
HUB_MOVE_VOLUME_GB=abc hm provision >/dev/null 2>&1; check P3-rc "$?" 2
check P3-no-call "$(wc -l < "$VC")" 0
HUB_MOVE_APP='Bad App' hm provision --plan >/dev/null 2>&1; check P3-bad-name-rc "$?" 2
newcase p4
sed -i '/TS_AUTHKEY_HUB/d' "$H/env/fly.env"
hm provision >/dev/null 2>"$C/err"; check P4-rc "$?" 3
check P4-no-call "$(wc -l < "$VC")" 0
has P4-alert "$(cat "$CALLS")" "h:alert-line --id hub-move-preflight"
newcase p5
out=$(hm inventory 2>&1)
hasnt P5-no-secret-value "$out" secret-fixture-value
hasnt P5-no-secret-value2 "$out" ghvalue-fixture-zz
hasnt P5-no-token "$out" tok-fixture-1
has P5-key-names "$out" "BACKUP_S3_SECRET_ACCESS_KEY GH_APP_SECRET"
newcase p6
{ echo 'PATH=/usr/bin:/bin'; echo '# comment'; for i in $(seq 1 170); do echo "* * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/lane-$i.sh"; done; } > "$C/cron.txt"
out=$(hm inventory 2>&1)
has P6-lines "$out" "lines=172 commands=170 gated=170"
has P6-repos "$out" "alpha-os beta-os"
newcase p7
hm provision >/dev/null 2>&1; check P7-rc "$?" 4
check P7-no-ts-ip "$(jq -r '.ts_ip // "none"' "$H/state/hub-move/target.json")" none
check P7-machine-kept "$(jq -r .machine_id "$H/state/hub-move/target.json")" m_fixture1

# ==== W: no-write shim =========================================================
newcase w
. "$H/bin/lib/hub-move-nowrite.sh"
REAL="$C/real"; mkdir -p "$REAL"
for n in gh curl git flyctl fly rsync wrangler ssh scp claude codex aws npx; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/real-calls"\n' "$n" "$C" > "$REAL/$n"
done
chmod +x "$REAL"/*
pl=$(PATH="$REAL:/usr/bin:/bin" hmn_make_dir "$C/shim"); check W0-rc "$?" 0
SHPATH="${pl#PATH=}"
case "$SHPATH" in "$C/shim:$REAL:"*) ok ;; *) bad "W0: PATH line [$SHPATH]" ;; esac
export HUB_MOVE_NOWRITE_LOG="$C/nw.log"
allow() { # allow <case> <argv...>
  local id="$1"; shift; : > "$C/real-calls"; : > "$HUB_MOVE_NOWRITE_LOG"
  PATH="$SHPATH" "$@" >/dev/null 2>&1; check "$id-rc" "$?" 0
  check "$id-ran-real" "$(wc -l < "$C/real-calls")" 1
  check "$id-logged-allow" "$(cut -f3 "$HUB_MOVE_NOWRITE_LOG")" allow
}
deny() { # deny <case> <argv...>
  local id="$1"; shift; : > "$C/real-calls"; : > "$HUB_MOVE_NOWRITE_LOG"
  local err; err=$(PATH="$SHPATH" "$@" 2>&1 >/dev/null); check "$id-rc" "$?" 75
  check "$id-real-not-run" "$(wc -l < "$C/real-calls")" 0
  check "$id-one-refuse-line" "$(grep -c $'\trefuse\t' "$HUB_MOVE_NOWRITE_LOG")" 1
  has "$id-stderr" "$err" "hub-move nowrite: refused $1"
}
allow W1 gh api repos/x/pulls
allow W2 gh api -X GET repos/x
allow W3 gh pr view 1 --json state
allow W4 curl -s https://x.example
allow W5 curl -I https://x.example
allow W6 git fetch origin
allow W7 rsync -a /a/ /b/
allow W7b flyctl machine list -a x
allow W7c git -C /tmp log
deny W8 gh pr merge 1
deny W9 gh api -X POST repos/x/issues
deny W10 gh api repos/x/issues -f title=t
deny W10b gh api --method PATCH repos/x
deny W11 gh issue comment 1 -b x
deny W12 curl -X POST https://x.example
deny W13 curl -d a=b https://x.example
deny W13b curl -sd a=b https://x.example
deny W13c curl -sXPOST https://x.example
deny W14 curl --json '{}' https://x.example
deny W15 git push origin main
deny W15b git -C /tmp push origin main
deny W16 wrangler deploy
deny W17 claude -p hi
deny W18 ssh root@x.example true
deny W19 rsync -a /a host.example:/b
deny W20 flyctl machine destroy m1
deny W21 scp a host.example:b
# W22-W23 (lead BLOCK #3203): state-backup's aws s3api writes the live backup
# bucket, and npx wrangler walks past the wrangler shim. Both refuse always.
deny W22 aws s3api put-object --bucket b --key k
deny W22b aws s3 ls s3://b
deny W23 npx --yes wrangler deploy
unset HUB_MOVE_NOWRITE_LOG

# ==== D: seed, tick, dry-run ===================================================
newcase d1
out=$(hm dry-run --plan 2>&1); check D1-rc "$?" 0
for w in "PLAN dry-run 1/4: provision" "PLAN dry-run 2/4: seed latest" "PLAN dry-run 3/4" "PLAN provision 6/6"; do has "D1 $w" "$out" "$w"; done
check D1-no-vendor "$(wc -l < "$VC")" 0
check D1-no-bin-call "$(wc -l < "$CALLS")" 0
check D1-no-lock-or-state "$(ls -A "$H/locks" "$H/state/hub-move" 2>/dev/null | wc -l)" 0

newcase d2
cat > "$C/cron.txt" <<EOF
PATH=/usr/bin:/bin
SHELL=/bin/bash
# a comment
@reboot echo boot >> $C/ran
* * * * * echo one >> $C/ran
*/5 * * * * /bin/true && echo two >> $C/ran
13 5 * * * echo three >> $C/ran # trailing note
@hourly echo four >> $C/ran
0 0 * * 1 echo five >> $C/ran
EOF
out=$(HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check D2-rc "$?" 0
check D2-each-once "$(sort "$C/ran" | tr '\n' ' ')" "five four one three two "
has D2-deploy-first "$(cat "$CALLS")" "target:harness-sync deploy"
f=$(printf '%s\n' "$out" | sed -n 's/^tick-file: //p')
check D9-rows "$(grep -v '^#' "$f" | tail -n +2 | wc -l)" 6
has D9-summary "$out" "tick: lanes=6 ok=6 fail=0 timeout=0 refused_writes=0 mode=nowrite"
check D9-mode-header "$(head -1 "$f")" "# mode=nowrite at=1700000000"
check D9-lane-output-kept "$(cat "${f%.tsv}.out/1.out" 2>/dev/null; ls "${f%.tsv}.out" | wc -l)" 6

newcase d3
printf '* * * * * gh pr merge 7 --squash\n* * * * * gh pr view 7\n' > "$C/cron.txt"
out=$(HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1)
f=$(printf '%s\n' "$out" | sed -n 's/^tick-file: //p')
check D3-merge-refused "$(awk -F'\t' '$1=="gh"{print $2"/"$4}' "$f")" "75/1"
check D3-view-allowed "$(awk -F'\t' '$1=="gh~2"{print $2"/"$4}' "$f")" "0/0"
has D3-summary "$out" "refused_writes=1 mode=nowrite"
check D3-real-gh-once "$(grep -c '^gh ' "$VC")" 1
has D3-only-view "$(grep '^gh ' "$VC")" "gh pr view 7"

newcase d4
printf '* * * * * sleep 5\n* * * * * true\n' > "$C/cron.txt"  # determinism: ok the sleep is the lane payload the 1 s tick timeout must kill, not a wait
out=$(HUB_MOVE_TICK_TIMEOUT_S=1 HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1)
f=$(printf '%s\n' "$out" | sed -n 's/^tick-file: //p')
check D4-timeout-row "$(awk -F'\t' '$1=="sleep"{print $2"/"$5}' "$f")" "124/1"
has D4-summary "$out" "timeout=1"

newcase d5
for i in 1 2 3 4 5; do echo "* * * * * echo + >> $C/par; sleep 1; echo - >> $C/par"; done > "$C/cron.txt"
HUB_MOVE_TICK_PARALLEL=2 HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick --real >/dev/null 2>&1
check D5-max-2 "$(awk '/\+/{n++; if(n>m)m=n} /-/{n--} END{print m}' "$C/par")" 2
check D5-all-ran "$(grep -c + "$C/par")" 5

newcase d6; target_ready; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
RESTORE_BOX_ID=hub2 hm seed latest >/dev/null 2>&1; check D6-rc "$?" 4
check D6-no-bootstrap "$(grep -c bootstrap-machine "$CALLS")" 0
newcase d6b; target_ready; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
hm seed 20261020T120000Z >"$C/out" 2>&1; check D6b-seed-rc "$?" 0
has D6b-restore-args "$(cat "$CALLS")" "target:state-restore hub 20261020T120000Z --apply --identity $C/tsec/age-identity --live $TGT/tmp/hub-move-fresh-"
has D6b-restore-own-dest "$(cat "$CALLS")" "--dest $TGT/tmp/hub-move-restore-"
check D6b-bootstrap-each "$(grep -c 'target:bootstrap-machine .* --repos-only' "$CALLS")" 2
check D6b-identity-copied "$(cat "$C/tsec/age-identity")" AGE-SECRET-KEY-FIXTURE
check D6b-only-bucket-keys "$(sed 's/=.*//' "$C/tsec/backup-s3.env" | tr '\n' ' ')" "BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY "
check D6b-key-mode "$(stat -c %a "$C/tsec/age-identity")" 600
check D6b-ssh-key-copied "$(cat "$C/tssh/id_ed25519")" fixture-private-key
hasnt D6b-no-secret-in-log "$(cat "$C/out")" secret-fixture-value
# D6c (lead BLOCK #3203): the C4 seed lands on a target the dry-run already
# seeded and ticked. The snapshot must win over that dry-run-era state, flags
# and orchestrator; the replaced dirs are kept under tmp/hub-move-prev-*.
newcase d6c; target_ready; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
printf 'dryrun-era\n' > "$TGT/state/cursor"; touch "$TGT/flags/lane-off-dryrun-only"
export HUB_MOVE_TARGET_ORCH="$C/torch"; mkdir -p "$C/torch"; printf 'dryrun-era\n' > "$C/torch/orch-state"
RESTORE_SNAP_TAG=c4 hm seed 20261020T153000Z >"$C/out" 2>&1; check D6c-seed-rc "$?" 0
check D6c-state-from-snapshot "$(cat "$TGT/state/cursor" 2>/dev/null)" snapshot-c4
check D6c-flag-not-kept "$( [ -e "$TGT/flags/lane-off-dryrun-only" ] && echo kept || echo gone)" gone
check D6c-orch-from-snapshot "$(cat "$C/torch/orch-state" 2>/dev/null)" snapshot-c4
check D6c-identity "$(cat "$TGT/state/box-id" 2>/dev/null)" hub
check D6c-prev-kept "$(cat "$TGT"/tmp/hub-move-prev-*/state/cursor 2>/dev/null)" dryrun-era
check D6c-fresh-removed "$(ls -d "$TGT"/tmp/hub-move-fresh-* 2>/dev/null | wc -l)" 0
unset HUB_MOVE_TARGET_ORCH
# D6d (lead BLOCK on dee06491): the build summaries the snapshot carries land,
# the build files it does not carry stay, and an env compat link keeps
# pointing at its dir, whose content is the snapshot's.
newcase d6d; target_ready; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
mkdir -p "$TGT/builds/BH-1" "$C/etcenv"; printf 'old\n' > "$TGT/builds/BH-1/RESULT"; printf 'keep\n' > "$TGT/builds/BH-1/reviewed-sha"
scratch_rm "$TGT/env"; printf 'OLD=1\n' > "$C/etcenv/old.env"; ln -s "$C/etcenv" "$TGT/env"
RESTORE_SNAP_TAG=d hm seed 20261020T153000Z >"$C/out" 2>&1; check D6d-seed-rc "$?" 0
check D6d-summary-from-snapshot "$(cat "$TGT/builds/BH-1/RESULT" 2>/dev/null)" snapshot-d
check D6d-other-build-file-kept "$(cat "$TGT/builds/BH-1/reviewed-sha" 2>/dev/null)" keep
check D6d-env-still-link "$( [ -L "$TGT/env" ] && echo link || echo not-link)" link
check D6d-env-dir-from-snapshot "$(cat "$C/etcenv/snap.env" 2>/dev/null)" SNAP=d
check D6d-old-env-moved-aside "$( [ -e "$C/etcenv/old.env" ] && echo still || echo moved)" moved
check D6d-old-env-kept-in-prev "$(cat "$TGT"/tmp/hub-move-prev-*/env-real/old.env 2>/dev/null)" OLD=1
newcase d7; mkdir -p "$H/state/hub-move"; echo '{"app":"x","ts_ip":""}' > "$H/state/hub-move/target.json"
export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
hm seed latest >/dev/null 2>&1; check D7-rc "$?" 3
check D7-no-ssh "$(grep -cE '^(ssh|scp|rsync) ' "$VC")" 0

newcase d8
printf '* * * * * echo "$PATH" > %s/path\n' "$C" > "$C/cron.txt"
HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick --real >"$C/out" 2>&1
hasnt D8-no-shim "$(cat "$C/path")" "/shim"
hasnt D8-no-deploy "$(cat "$CALLS")" "harness-sync deploy"
has D8-mode "$(cat "$C/out")" "mode=real"
newcase d8b
printf '* * * * * echo "$PATH" > %s/path\n' "$C" > "$C/cron.txt"
HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick >/dev/null 2>&1
has D8b-nowrite-has-shim "$(cat "$C/path")" "/shim:"

# D10: no flyctl on the box = tick fails before any lane runs (the pool lanes need it, and fly-pool-tick.sh exits 0 without it).
newcase d10
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
mkdir -p "$C/nofly" "$C/emptyfly"
for n in "$STUB"/*; do case "$(basename "$n")" in flyctl|fly) ;; *) ln -s "$n" "$C/nofly/$(basename "$n")" ;; esac; done
for m in "" --real; do
  out=$(HOME="$C" FLY_BIN_DIR="$C/emptyfly" PATH="$C/nofly:/usr/bin:/bin" HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick $m 2>&1)
  check "D10-rc${m}" "$?" 4
  has "D10-says${m}" "$out" "flyctl not found on this box"
done
check D10-no-lane-ran "$( [ -e "$C/ran" ] && echo yes || echo no)" no
newcase d10b
printf '* * * * * true\n' > "$C/cron.txt"
out=$(HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check D10b-rc "$?" 0
has D10b-names-flyctl "$out" "tick: flyctl=$STUB/flyctl"

# D11: a flyctl in /root/.fly/bin is put before the shim by fly-pool.sh, fly-dispatch.sh and
# fly-image-refresh.sh, so a no-write tick refuses; a real tick still runs.
newcase d11
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
mkdir -p "$HUB_MOVE_FLY_HOME_BIN"; ln -s "$STUB/flyctl" "$HUB_MOVE_FLY_HOME_BIN/flyctl"
out=$(HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check D11-rc "$?" 4
has D11-says "$out" "$HUB_MOVE_FLY_HOME_BIN/flyctl exists"
check D11-no-lane-ran "$( [ -e "$C/ran" ] && echo yes || echo no)" no
check D11-no-tick-file "$(ls "$TGT/state/hub-move"/tick-*.tsv 2>/dev/null | wc -l)" 0
HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick --real >/dev/null 2>&1; check D11-real-rc "$?" 0
check D11-real-ran "$(cat "$C/ran")" lane

# D12: a no-write lane gets FLY_BIN_DIR = the shim dir (fly-pool.sh prepends it) and
# HUB_MOVE_NOWRITE=1 (bin/alerts-supersede.py reads it as --dry); a real lane gets neither.
newcase d12
printf '* * * * * echo "${FLY_BIN_DIR:-none} ${HUB_MOVE_NOWRITE:-none}" > %s/env\n' "$C" > "$C/cron.txt"
HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick >/dev/null 2>&1
read -r fbd hmn < "$C/env"
case "$fbd" in */shim) ok ;; *) bad "D12-fly-bin-dir-shim: got [$fbd]" ;; esac
check D12-nowrite-env "$hmn" 1
HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick --real >/dev/null 2>&1
check D12-real-env "$(cat "$C/env")" "none none"

# D13: the deployed tree (/root/harness) has bin/ but no cron/, and its
# render-cron.sh resolves ROOT as the parent of its own bin, so it fails (seen
# on the new hub 2026-10-21: "no /root/harness/cron/lanes"). tick and
# inventory render from the checkout (HARNESS_CHECKOUT) instead.
newcase d13
for side in "$H" "$TGT"; do
  # scratch-closure-allow: the REAL render-cron.sh and its registry loader, so the deployed-tree failure is the real one
  cp "$REPO/bin/render-cron.sh" "$side/bin/render-cron.sh" && cp "$REPO/bin/lib/lanes-registry.sh" "$side/bin/lib/" || bad "D13: copy render-cron into $side"
  mkdir -p "$side/catalog"; printf '{"lanes":[]}\n' > "$side/catalog/lanes.json"
done
bash "$TGT/bin/render-cron.sh" hub >/dev/null 2>"$C/err"; check D13-deployed-copy-fails "$?" 1
has D13-deployed-says "$(cat "$C/err")" "no $TGT/cron/lanes"
printf '* * * * * echo checkout-lane >> %s/ran\n' "$C" > "$C/cron.txt"
out=$(HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check D13-tick-rc "$?" 0
hasnt D13-tick-no-fail "$out" "failed: render-cron.sh"
check D13-tick-ran-checkout-lane "$(cat "$C/ran" 2>/dev/null)" checkout-lane
has D13-tick-summary "$out" "tick: lanes=2 ok=2 fail=0"
out=$(hm inventory 2>&1)
has D13-inventory-row "$out" "| Cron lanes | $C/co/bin/render-cron.sh hub | lines=1 commands=1 gated=0 |"
# A checkout that cannot render shows an error value, not a silently empty row.
export HARNESS_CHECKOUT="$C/no-checkout"
out=$(hm inventory 2>&1)
has D13-inventory-error "$out" "| Cron lanes | $C/no-checkout/bin/render-cron.sh hub | ERROR render-cron.sh rc="
hasnt D13-inventory-not-empty "$out" "lines=0 commands=0"
export HARNESS_CHECKOUT="$C/co"

# ==== I: the hub image has a pinned flyctl outside /root/.fly/bin =============
DF="$REPO/fly/hub/Dockerfile"
has I1-flyctl-arg "$(cat "$DF")" "ARG FLYCTL_VERSION"
has I1-flyctl-pinned "$(cat "$DF")" 'bake_require FLYCTL_VERSION'
has I1-flyctl-sha "$(cat "$DF")" 'bake_sha256 /tmp/flyctl.tar.gz'
has I1-flyctl-usr-local "$(cat "$DF")" 'tar -xzf /tmp/flyctl.tar.gz -C /usr/local/bin flyctl'
hasnt I1-not-fly-home "$(grep -v '^#' "$DF")" 'install.sh'
has I1-runbook-build-arg "$(cat "$REPO/docs/notes/2026-10-20-BH-7715-hub-move.md")" "--build-arg FLYCTL_VERSION="
# I2: a pinned pnpm, because bootstrap-machine.sh installs pnpm repos with pnpm
has I2-pnpm-arg "$(cat "$DF")" "ARG PNPM_VERSION"
has I2-pnpm-pinned "$(cat "$DF")" 'bake_require PNPM_VERSION'
has I2-pnpm-verify "$(cat "$DF")" 'bake_verify pnpm "$PNPM_VERSION" pnpm --version'
has I2-runbook-build-arg "$(cat "$REPO/docs/notes/2026-10-20-BH-7715-hub-move.md")" "--build-arg PNPM_VERSION="

# ==== R1: provision then seed then dry-run off one target.json ===============
newcase r1; peer_json; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
printf '* * * * * %s/bin/hub-lease.sh check && gh pr merge 1\n* * * * * echo ok\n' "$TGT" > "$C/cron.txt"
out=$(hm dry-run 2>&1); check R1-rc "$?" 0
has R1-ssh-to-provisioned-ip "$(grep '^ssh ' "$VC" | head -1)" "root@192.0.2.44"
has R1-tick-summary "$out" "mode=nowrite"
check R1-tick-fetched "$(ls "$H/state/hub-move"/tick-*.tsv 2>/dev/null | wc -l)" 1
has R1-inventory "$out" "| Cron lanes |"

# ==== C: cutover, rollback, proof ==============================================
newcase c1; target_ready
hm cutover --step C2 >"$C/out" 2>&1; check C1-rc "$?" 0
has C1-would "$(cat "$C/out")" "WOULD RUN C2 pause merge"
check C1-no-flag "$(ls "$H/flags" | wc -l)" 0
check C1-no-steps "$( [ -e "$H/state/hub-move/steps.tsv" ] && echo yes || echo no)" no
hm cutover --all >/dev/null 2>&1; check C1-all-rc "$?" 0
check C1-all-no-steps "$( [ -e "$H/state/hub-move/steps.tsv" ] && echo yes || echo no)" no

newcase c2; target_ready
hm cutover --step C3 --confirm >/dev/null 2>&1; check C2-refused-rc "$?" 3
check C2-crontab-untouched "$(grep -c 'crontab' "$VC")" 0

# C1 preflight on a fresh no-write tick; a lane that failed without a refusal refuses.
newcase c1p; target_ready; mkdir -p "$H/state/hub-move"
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\na\t0\t1\t0\t0\nb\t75\t1\t1\t0\n' > "$H/state/hub-move/tick-a.tsv"
hm cutover --step C1 --confirm >/dev/null 2>&1; check C1p-ok-rc "$?" 0
check C1p-ok "$(awk -F'\t' '$2=="C1"{print $3}' "$H/state/hub-move/steps.tsv")" ok
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\na\t1\t1\t0\t0\n' > "$H/state/hub-move/tick-b.tsv"
touch -d '+1 minute' "$H/state/hub-move/tick-b.tsv"
hm cutover --step C1 --confirm >/dev/null 2>"$C/err"; check C1p-fail-rc "$?" 4
has C1p-names-lane "$(cat "$C/err")" "a(rc=1)"
HUB_MOVE_NOW=1800000000 hm cutover --step C1 --confirm >/dev/null 2>"$C/err"; check C1p-stale-rc "$?" 4

newcase c3; target_ready; mkdir -p "$H/state/hub-move"
printf 'x\tC1\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
hm cutover --step C2 --confirm >/dev/null 2>&1; check C3-rc "$?" 0
# flag_set answers through bin/jobs-client.sh, which drops its once-a-day
# alerted-jobs-not-configured-<day> marker in flags/ on a box with no worker;
# that marker is not a flag, so the flag listings below leave alerted-* out.
check C3-flags "$(ls "$H/flags" | grep -v '^alerted-' | sort | tr '\n' ' ')" "automerge-disabled lane-off-merge-conductor "

newcase c4; target_ready; mkdir -p "$H/state/hub-move"
printf 'x\tC2\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
printf '* * * * * /root/harness/bin/a.sh\n' > "$CRONTAB_FILE"
printf '#!/bin/bash\nsleep 30\n' > "$H/bin/fake-lane.sh"
bash "$H/bin/fake-lane.sh" & LPID=$!
hm cutover --step C3 --confirm >/dev/null 2>"$C/err"; check C4-drain-timeout-rc "$?" 4
has C4-lists-pid "$(cat "$C/err")" "$LPID"
check C4-crontab-saved "$(cat "$H/state/hub-move/old-crontab")" "* * * * * /root/harness/bin/a.sh"
check C4-crontab-removed "$( [ -e "$CRONTAB_FILE" ] && echo yes || echo no)" no
hm cutover --step C3 --confirm --force-drain >/dev/null 2>&1; check C4-force-rc "$?" 0
check C4-saved-not-clobbered "$(cat "$H/state/hub-move/old-crontab")" "* * * * * /root/harness/bin/a.sh"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null

newcase c5; target_ready; mkdir -p "$H/state/hub-move"; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
printf 'x\tC3\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
echo '{"ts":"20261019T000000Z"}' > "$H/state/backup-last.json"
cat > "$H/bin/state-backup.sh" <<EOF
#!/bin/bash
printf 'h:state-backup %s BACKUP_FORCE=%s\n' "\$*" "\${BACKUP_FORCE:-}" >> "\$CALLS"
echo '{"ts":"20261020T153000Z"}' > "$H/state/backup-last.json"
EOF
hm cutover --step C4 --confirm >/dev/null 2>&1; check C5-rc "$?" 0
has C5-forced "$(cat "$CALLS")" "h:state-backup  BACKUP_FORCE=1"
has C5-exact-ts "$(cat "$CALLS")" "target:state-restore hub 20261020T153000Z --apply"
hasnt C5-not-latest "$(cat "$CALLS")" "state-restore hub latest"
check C5-all-off "$( [ -e "$H/flags/all-off" ] && echo yes || echo no)" yes
# C5 split-brain: refuses while the old crontab is not empty, passes once it is.
printf '* * * * * x\n' > "$CRONTAB_FILE"
hm cutover --step C5 --confirm >/dev/null 2>&1; check C6-c5-refuses-rc "$?" 4
check C6-c5-fail "$(awk -F'\t' '$2=="C5"{v=$3} END{print v}' "$H/state/hub-move/steps.tsv")" fail
rm -f "$CRONTAB_FILE"
hm cutover --step C5 --confirm >/dev/null 2>&1; check C6-c5-ok-rc "$?" 0

newcase c7; target_ready; mkdir -p "$H/state/hub-move"
printf 'x\tC5\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
printf '#!/bin/bash\nprintf "target:hub-lease %%s\\n" "$*" >> "$CALLS"\n[ "$1" = check ] && exit 1\nexit 0\n' > "$TGT/bin/hub-lease.sh"
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
hm cutover --step C6 --confirm >/dev/null 2>&1; check C7-lease-refused-rc "$?" 4
check C7-no-tick "$( [ -e "$C/ran" ] && echo yes || echo no)" no
check C7-no-update-runners "$(grep -c update-runners "$CALLS")" 0
printf '#!/bin/bash\nprintf "target:hub-lease %%s\\n" "$*" >> "$CALLS"\nexit 0\n' > "$TGT/bin/hub-lease.sh"
hm cutover --step C6 --confirm >"$C/out" 2>&1; check C7-ok-rc "$?" 0
check C7-real-tick-ran "$(cat "$C/ran")" lane
has C7-update-runners "$(cat "$CALLS")" "target:update-runners"
has C7-mode-real "$(cat "$C/out")" "mode=real"

newcase c8; target_ready; mkdir -p "$H/state/hub-move"
printf 'x\tC6\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
touch "$H/flags/automerge-disabled" "$H/flags/lane-off-merge-conductor" "$TGT/flags/automerge-disabled" "$TGT/flags/lane-off-merge-conductor"
hm cutover --step C7 --confirm >/dev/null 2>&1; check C8-rc "$?" 0
check C8-target-cleared "$(ls "$TGT/flags" | grep -vc '^alerted-')" 0
check C8-old-kept "$(ls "$H/flags" | grep -v '^alerted-' | sort | tr '\n' ' ')" "automerge-disabled lane-off-merge-conductor "
out=$(HUB_MOVE_OLD_VM_ID=vm-fixture hm cutover --step C8 --confirm 2>&1); check C8-standby-rc "$?" 0
check C8-standby-until "$(cat "$TGT/state/hub-move/cold-standby-until")" "2023-11-21T22:13:20Z"
has C8-retire "$out" "retire the old hub VM vm-fixture"

newcase c9; target_ready; mkdir -p "$H/state/hub-move"
printf 'SHELL=/bin/bash\n# saved\n* * * * * /root/harness/bin/a.sh  # tail  \n\n' > "$H/state/hub-move/old-crontab"
touch "$H/flags/all-off"
printf '#!/bin/bash\nprintf "target:state-backup %%s\\n" "$*" >> "$CALLS"\necho %s > %s/state/backup-last.json\n' "'{\"ts\":\"20261021T010000Z\"}'" "$TGT" > "$TGT/bin/state-backup.sh"
hm rollback >/dev/null 2>&1; check C9-no-confirm-rc "$?" 0
check C9-no-confirm-no-call "$(wc -l < "$CALLS")" 0
hm rollback --confirm >"$C/out" 2>&1; check C9-rc "$?" 0
cmp -s "$H/state/hub-move/old-crontab" "$CRONTAB_FILE" && ok || bad "C9: crontab not restored byte for byte"
has C9-restore-exact "$(cat "$CALLS")" "h:state-restore hub 20261021T010000Z --apply --live $H/tmp/hub-move-fresh-"
has C9-restore-own-dest "$(cat "$CALLS")" "--dest $H/tmp/hub-move-restore-"
check C9-old-all-off-removed "$( [ -e "$H/flags/all-off" ] && echo yes || echo no)" no
check C9-target-all-off "$( [ -e "$TGT/flags/all-off" ] && echo yes || echo no)" yes
has C9-merge-paused-note "$(cat "$C/out")" "Merge is still paused"
# C9b (lead BLOCK #3203): rollback lands the target's snapshot over the old
# hub's pre-C3 tree, keeps this hub's own hub-move record, and keeps merge paused.
newcase c9b; target_ready; mkdir -p "$H/state/hub-move"
printf 'SHELL=/bin/bash\n* * * * * /root/harness/bin/a.sh\n' > "$H/state/hub-move/old-crontab"
printf 'pre-c3\n' > "$H/state/cursor"; touch "$H/flags/all-off"
export HUB_MOVE_ORCH="$C/lorch"; mkdir -p "$C/lorch"; printf 'pre-c3\n' > "$C/lorch/orch-state"
printf '#!/bin/bash\nprintf "target:state-backup %%s\\n" "$*" >> "$CALLS"\necho %s > %s/state/backup-last.json\n' "'{\"ts\":\"20261021T010000Z\"}'" "$TGT" > "$TGT/bin/state-backup.sh"
RESTORE_SNAP_TAG=target hm rollback --confirm >"$C/out" 2>&1; check C9b-rc "$?" 0
check C9b-state-from-target "$(cat "$H/state/cursor" 2>/dev/null)" snapshot-target
check C9b-orch-from-target "$(cat "$C/lorch/orch-state" 2>/dev/null)" snapshot-target
cmp -s "$H/state/hub-move/old-crontab" "$CRONTAB_FILE" && ok || bad "C9b: the old crontab was not carried over the swap and restored"
check C9b-merge-paused "$( [ -e "$H/flags/automerge-disabled" ] && [ -e "$H/flags/lane-off-merge-conductor" ] && echo yes || echo no)" yes
check C9b-prev-kept "$(cat "$H"/tmp/hub-move-prev-*/state/cursor 2>/dev/null)" pre-c3
# C9c (lead NOTE on dee06491): after a rollback no cut-over step reads ok, so a
# later `cutover --all` starts at C1 and runs C5 again.
check C9c-c5-not-ok "$(awk -F'\t' '$2=="C5"{v=$3} END{print v}' "$H/state/hub-move/steps.tsv" 2>/dev/null)" reset
check C9c-c1-not-ok "$(awk -F'\t' '$2=="C1"{v=$3} END{print v}' "$H/state/hub-move/steps.tsv" 2>/dev/null)" reset
unset HUB_MOVE_ORCH

# S1 (BH-7715): under HARNESS_TEST_SANDBOX=1 an orchestrator (or harness) path
# outside the scratch tree is refused before anything runs: exit 2, no call.
newcase s1; target_ready; mkdir -p "$H/state/hub-move"
printf '* * * * * x\n' > "$H/state/hub-move/old-crontab"
out=$(HARNESS_TEST_SANDBOX=1 HUB_MOVE_ORCH=/root/orchestrator hm rollback --confirm 2>&1); check S1-lorch-rc "$?" 2
has S1-lorch-says "$out" "HUB_MOVE_ORCH=/root/orchestrator is outside the test scratch root"
out=$(HARNESS_TEST_SANDBOX=1 HUB_MOVE_TARGET_ORCH=/root/orchestrator hm seed 20261020T153000Z 2>&1); check S1-torch-rc "$?" 2
has S1-torch-says "$out" "HUB_MOVE_TARGET_ORCH=/root/orchestrator is outside the test scratch root"
out=$(HARNESS_TEST_SANDBOX=1 HUB_MOVE_ORCH="$T/../hub-move-outside" hm rollback --confirm 2>&1); check S1-outside-rc "$?" 2
out=$(env -u HUB_MOVE_ORCH HARNESS_TEST_SANDBOX=1 bash "$H/bin/hub-move.sh" rollback --confirm 2>&1); check S1-unset-rc "$?" 2
has S1-unset-says "$out" "HUB_MOVE_ORCH=/root/orchestrator"
check S1-no-vendor-call "$(wc -l < "$VC")" 0
check S1-no-bin-call "$(wc -l < "$CALLS")" 0
check S1-no-lock "$( [ -e "$H/locks/hub-move.lock" ] && echo yes || echo no)" no

newcase c10
echo '40.00 81.00 57.00 12/900 4242' > "$C/loadavg"
out=$(HUB_MOVE_PROC_LOADAVG="$C/loadavg" HUB_MOVE_NPROC=4 hm proof 2>&1); check C10-rc "$?" 0
has C10-per-vcpu "$out" "load5=81.00 load15=57.00 nproc=4 load5_per_vcpu=20.25"
out=$(HUB_MOVE_PROC_LOADAVG="$C/loadavg" HUB_MOVE_NPROC=16 hm proof --since 2026-10-20T00:00Z --until 2026-10-21T00:00Z 2>&1)
has C10-16 "$out" "load5_per_vcpu=5.06"
has C11-passthrough "$(cat "$CALLS")" "h:hub-load-report --since 2026-10-20T00:00Z --until 2026-10-21T00:00Z"

# C12: nothing committed dials the hub by tailnet name, so ticket item 2 needs no reference edit.
hits=$(cd "$REPO" && grep -rnE 'ts\.net|root@box-hub|box-hub' bin cron catalog console-ui/functions worker/*/src 2>/dev/null | grep -v '^bin/hub-move.sh:')
check C12-no-hub-reference "$hits" ""

# ==== B1: no real vendor binary is reachable on the suite's PATH ===============
for n in flyctl tailscale ssh scp rsync crontab gh curl wrangler claude codex; do
  check "B1-$n" "$(PATH="$BASEPATH" command -v "$n")" "$STUB/$n"
done

echo "hub-move.bh-7715: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
