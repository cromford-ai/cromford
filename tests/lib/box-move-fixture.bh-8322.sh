#!/bin/bash
# tests/lib/box-move-fixture.bh-8322.sh — the shared fixture of the
# bin/box-move.sh suites (BH-8322). Sourced after tests/lib/scratch.sh, with
# REPO set to the checkout. Never executed.
#
# No real vendor is called. flyctl, tailscale, ssh, scp, rsync, crontab, tar
# (create only, on request), gh, curl, wrangler, claude, codex, aws and npx are
# PATH stubs under $T/stub that record their argv in the case's $VC file.
#
# ssh maps root@<ip> to that host's scratch root through the case's $HOSTS
# file and runs the command there with HARNESS, HARNESS_ENV_DIR and FLEET_CONF
# removed, ETC_HARNESS_ENV pointed at a path that does not exist and
# CRONTAB_FILE set to the host's own crontab file. An unknown host is rc 255.
#
# bm_newcase <name> builds $C (the case dir), $H (the hub harness), $OLD (the
# old box harness) and $NEW (the new box harness), a fixture fleet.conf, the
# env of each side and the bin stubs; each case is its own tree.
BM_REL=bin/box-move.sh
BM_OLD=box-project-6-os-1
BM_NEW=box-mkfly
BM_OLD_IP=192.0.2.21
BM_NEW_IP=192.0.2.22
BM_SECRET=BM_FIXTURE_SECRET_8322
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in: ${2:0:600}"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }

export HUB_MOVE_NOW=1700000000
STUB="$T/stub"; mkdir -p "$STUB"
BM_REAL_TAR=$(command -v tar)

cat > "$STUB/flyctl" <<'EOF'
#!/bin/bash
printf 'flyctl %s\n' "$*" >> "$VC"
D="$FLYD"; mkdir -p "$D"
[ -e "$D/ratelimit" ] && { echo "Error: 429 Too Many Requests: rate limited" >&2; exit 1; }
case "$1 $2" in
  "version "*|"version") echo "flyctl v0.0.0-fixture" ;;
  "apps list")    [ -e "$D/fail-list" ] && { echo "Error: boom" >&2; exit 1; }
                  if [ -s "$D/apps" ]; then jq -R '{Name:.}' "$D/apps" | jq -s .; else echo '[]'; fi ;;
  "apps create")  echo "$3" >> "$D/apps" ;;
  "volumes list") [ -e "$D/fail-vol" ] && { echo "Error: boom" >&2; exit 1; }
                  cat "$D/volumes.json" 2>/dev/null || echo '[]' ;;
  "volumes create") printf '[{"id":"vol_fixture1","name":"%s"}]\n' "$3" > "$D/volumes.json" ;;
  "machine list") [ -e "$D/fail-mach" ] && { echo "Error: boom" >&2; exit 1; }
                  cat "$D/machines.json" 2>/dev/null || echo '[]' ;;
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
host=""; while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) host="$1"; shift; break ;; esac; done
printf 'ssh %s %s\n' "$host" "$*" >> "$VC"
ip="${host#*@}"
root=$(awk -v i="$ip" '$1 == i {print $2; exit}' "$HOSTS" 2>/dev/null)
[ -n "$root" ] || { echo "ssh: connect to host $ip port 22: No route to host" >&2; exit 255; }
[ -e "$root/.ssh-down" ] && { echo "ssh: connect to host $ip port 22: Connection refused" >&2; exit 255; }
cd "$root" || exit 255
exec env -u HARNESS -u HARNESS_ENV_DIR -u FLEET_CONF ETC_HARNESS_ENV="$root/etc-harness-env-absent" \
  CRONTAB_FILE="$root/crontab" bash -c "$*"
EOF
cat > "$STUB/scp" <<'EOF'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$VC"
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
# tar: the real one, except a create when the case asks for a failure:
# BM_FAIL_TAR_CREATE=1 writes nothing and exits 2 (S2); =late writes the whole
# archive and then exits 2, as a tar that read a file while it changed (S2b).
cat > "$STUB/tar" <<EOF
#!/bin/bash
if [ -n "\${BM_FAIL_TAR_CREATE:-}" ]; then
  for a in "\$@"; do case "\$a" in -cf|-c|--create)
    [ "\$BM_FAIL_TAR_CREATE" = late ] && "$BM_REAL_TAR" "\$@"
    echo "tar: fixture create failure" >&2; exit 2 ;; esac; done
fi
exec "$BM_REAL_TAR" "\$@"
EOF
# curl: a POST lands one line in the jobs fixture row file, the write a real
# worker call would make.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$VC"
case " $* " in *" -X POST "*|*" -d "*) printf 'row %s\n' "$*" >> "$JOBS_ROWS" ;; esac
EOF
for n in gh wrangler claude codex aws npx; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$VC"\n' "$n" > "$STUB/$n"
done
chmod +x "$STUB"/*
BM_BASEPATH="$STUB:$PATH"

# bm_stub <file> <tag> — a bin stub that records "<tag> <argv>" in $CALLS.
bm_stub() {
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$CALLS"\n' "$2" > "$1"
  chmod +x "$1"
}

bm_newcase() {
  C="$T/$1"; H="$C/hub"; OLD="$C/old"; NEW="$C/new"
  mkdir -p "$H/state" "$H/env" "$H/catalog" "$OLD/state" "$OLD/flags" "$OLD/env" "$NEW/state" "$NEW/flags" "$C/hssh" "$C/fly"
  scratch_install_closure "$BM_REL" "$H" >/dev/null || bad "$1: closure into hub"
  scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "$1: fleet-conf closure into hub"
  scratch_install_closure bin/box-for.sh "$H" >/dev/null || bad "$1: box-for closure into hub"
  scratch_install_closure bin/lib/env-path.sh "$OLD" >/dev/null || bad "$1: env-path into old"
  scratch_install_closure bin/hub-move.sh "$NEW" >/dev/null || bad "$1: hub-move closure into new"
  cp "$REPO/catalog/fly-idle-signals.json" "$H/catalog/" || bad "$1: catalog"
  # bin/lib/flags.sh loads bin/jobs-client.sh and its JC_MODULES at run time.
  # scratch-closure-allow: bin/lib/flags.sh loads bin/jobs-client.sh and its bin/lib/jobs modules at run time, which the closure scan cannot follow
  mkdir -p "$NEW/bin/lib/jobs" && cp "$REPO/bin/jobs-client.sh" "$NEW/bin/" && cp "$REPO"/bin/lib/jobs/*.sh "$NEW/bin/lib/jobs/" \
    || bad "$1: jobs-client into new"
  export HARNESS_SECRET=fixture-secret
  export VC="$C/vendor-calls" CALLS="$C/calls" FLYD="$C/fly" TSJSON="$C/ts.json" HOSTS="$C/hosts" JOBS_ROWS="$C/jobs-rows"
  : > "$VC"; : > "$CALLS"; : > "$JOBS_ROWS"
  printf '%s %s\n%s %s\n' "$BM_OLD_IP" "$OLD" "$BM_NEW_IP" "$NEW" > "$HOSTS"
  export HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_CHECKOUT="$C/co"
  export BOX_MOVE_OLD_HARNESS="$OLD" BOX_MOVE_TARGET_HARNESS="$NEW" BOX_MOVE_SSH_DIR="$C/hssh"
  export BOX_MOVE_TARGET_ORCH="$C/torch" BOX_MOVE_IMAGE="registry.example/hub:fixture" BOX_MOVE_TS_WAIT_S=0
  unset BOX_MOVE_APP BOX_MOVE_REGION BOX_MOVE_VM_SIZE BOX_MOVE_MEM_MB BOX_MOVE_VOLUME_GB BOX_MOVE_TS_HOSTNAME \
    BOX_MOVE_PROC_LOADAVG BOX_MOVE_NPROC BM_FAIL_TAR_CREATE REGISTRY_SOURCE HUB_MOVE_NOWRITE FLY_BIN_DIR \
    BACKUP_AGE_IDENTITY_FILE HUB_MOVE_REACH_HOST
  # hub-move tick runs on the new box: its own path knobs stay in scratch.
  export HUB_MOVE_TARGET_HARNESS="$NEW" HUB_MOVE_TARGET_ORCH="$C/torch" HUB_MOVE_ORCH="$C/lorch"
  export HUB_MOVE_TARGET_SECRETS="$C/tsec" HUB_MOVE_TARGET_SSH_DIR="$C/tssh" HUB_MOVE_FLY_HOME_BIN="$C/flyhome"
  export PATH="$BM_BASEPATH"
  cat > "$H/fleet.conf" <<EOF
# fixture registry (BH-8322)
# @boxrole box-idle idle build
# @box box-idle 192.0.2.24
alpha-os o/alpha https://alpha.example /api/board 2 $BM_OLD $BM_OLD_IP
beta-os  o/beta  https://beta.example  /api/board 4 $BM_OLD $BM_OLD_IP
gamma-os o/gamma https://gamma.example /api/board 6 box-other 192.0.2.23
EOF
  printf 'ssh-ed25519 AAAAfixture hub@example\n' > "$C/hssh/id_ed25519.pub"
  printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN="FlyV1 tok-fixture-1"\nTS_AUTHKEY_BOX=tskey-fixture-box\n' > "$H/env/fly.env"
  bm_stub "$H/bin/alert-line.sh" hub:alert-line
  # The old box: its env (the marker value must reach only the new box), its
  # own state/box-id that disagrees with the rows (rows win), its crontab.
  printf 'BACKUP_S3_ENDPOINT=https://s3.example\nBACKUP_S3_ACCESS_KEY_ID=akid-fixture\nBACKUP_S3_SECRET_ACCESS_KEY=secret-fixture-value\nGH_APP_SECRET=%s\n' "$BM_SECRET" > "$OLD/env/global.env"
  printf 'export ALPHA_TOKEN=alpha-fixture-token\n' > "$OLD/env/alpha-os.env"
  printf 'wrong\n' > "$OLD/state/box-id"
  printf '{"ts":"20261025T120000Z","key":"project-6-os/20261025T120000Z.tar.zst"}\n' > "$OLD/state/backup-last.json"
  printf 'PATH=/usr/bin:/bin\n# a comment\n* * * * * /root/harness/bin/a.sh\n*/5 * * * * /root/harness/bin/b.sh\n' > "$OLD/crontab"
  # The new box: bin stubs for the steps seed and tick call there.
  local n
  for n in bootstrap-machine harness-sync alert-line migrate-env-dir; do bm_stub "$NEW/bin/$n.sh" "new:$n"; done
  cat > "$NEW/bin/state-restore.sh" <<'EOF'
#!/bin/bash
printf 'new:state-restore %s\n' "$*" >> "$CALLS"
box="$1"; live=""; orch=""
while [ $# -gt 0 ]; do case "$1" in --live) live="$2"; shift 2 ;; --orchestrator-live) orch="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$live" ] || exit 2
put() { [ -e "$1" ] && return 0; mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
put "$live/state/box-id" "${RESTORE_BOX_ID:-$box}"
put "$live/state/box-name" "box-project-6-os-1"
put "$live/state/cursor" "snapshot"
put "$live/flags/automerge-disabled" ""
put "$live/logs/old.log" "snapshot log"
put "$live/builds/BH-1/RESULT" "snapshot"
[ -z "$orch" ] || put "$orch/orch-state" "snapshot"
echo "env/ NOT decrypted (no identity given): env files will not be restored"
EOF
  chmod +x "$NEW/bin/state-restore.sh"
  # The checkout render-cron.sh: the old box's crontab for box id project-6-os only.
  mkdir -p "$C/co/bin"
  printf '#!/bin/bash\n[ "$1" = project-6-os ] || { echo "render-cron.sh: no box %%s" "$1" >&2; exit 1; }\ncat "%s/cron.txt"\n' "$C" > "$C/co/bin/render-cron.sh"
  chmod +x "$C/co/bin/render-cron.sh"
  printf '* * * * * /root/harness/bin/a.sh\n*/5 * * * * /root/harness/bin/b.sh\n* * * * * /root/harness/bin/c.sh\n' > "$C/cron.txt"
}
bm() { bash "$H/bin/box-move.sh" "$@"; }
bm_peer_json() { printf '{"Peer":{"n1":{"HostName":"%s","TailscaleIPs":["%s","fd7a::22"]}}}\n' "$BM_NEW" "$BM_NEW_IP" > "$TSJSON"; }
bm_target_ready() {
  mkdir -p "$H/state/box-move/$BM_NEW"
  printf '{"provider":"fly","app":"%s","ts_ip":"%s","box_id":"project-6-os"}\n' "$BM_NEW" "$BM_NEW_IP" > "$H/state/box-move/$BM_NEW/target.json"
}
# bm_seeded_target — the new box as seed leaves it: box id, local all-off, marker.
bm_seeded_target() {
  bm_target_ready
  printf 'project-6-os\n' > "$NEW/state/box-id"; printf '%s\n' "$BM_NEW" > "$NEW/state/box-name"
  mkdir -p "$NEW/state/hub-move" "$NEW/env"; printf 'seeded fixture\n' > "$NEW/state/hub-move/target-seeded"
  : > "$NEW/flags/all-off"
}
bm_tree_sum() { (cd "$1" && find . -type f ! -path './locks/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1; }
bm_done() {
  echo "$1: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]
}
