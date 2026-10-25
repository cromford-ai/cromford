#!/bin/bash
# tests/hub-move-reach.bh-8123-test.sh — BH-8123: hub-move proves the new hub
# can reach the fleet before a cut-over.
#
#   THE INCIDENT (2026-10-23). The new hub bh-hub-2 had an Orgo ssh config
#   that sent every ssh through a SOCKS proxy on 127.0.0.1:1055, and nothing
#   listened there. Every ssh to a fleet box failed. C1 and C6 passed (they
#   tested no ssh and no flyctl), and the new hub built nothing for 3 h.
#
#   P1-P13  hmr_proxy_check_script: the ProxyCommand decision table (ss stub,
#           and the /dev/tcp fallback with no ss on PATH).
#   S1-S4   seed refuses a target ssh config that proxies through a dead
#           loopback port, before any copy; seed never copies an ssh config.
#   R1-R8   tick runs one ssh to a fleet box and one `flyctl version`, writes
#           `# reach ...` as line 2 of the tick table, and fails (exit 4) with a
#           `-reach-failed` stub table when either fails.
#   K1      a bad HUB_MOVE_REACH_HOST value is exit 2.
#   C1a-C1g C1 refuses a table with a failed or missing reach line, and
#           HUB_MOVE_C1_ALLOW does not cover it; C1c reads R1's table.
#   C6a     C6 fails when the real tick cannot reach the fleet.
#   A1      dry run: the seed probe passes, the fleet ssh fails; dry-run exit
#           4, then C1 exit 4 and its text names the ssh config.
#   B0      no real vendor is called.
#
# No real vendor is called. ssh, scp, rsync, ss, flyctl, crontab, journalctl
# and tailscale are PATH stubs that record argv in $VC. ssh runs its command on
# this box against the scratch target. Each case has its own scratch dirs.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-move-reach.bh-8123-test.sh
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
yn() { [ -e "$1" ] && echo yes || echo no; }

export HUB_MOVE_NOW=1700000000
STUB="$T/stub"; mkdir -p "$STUB"
ORGO='ProxyCommand /usr/bin/nc -x 127.0.0.1:1055 %h %p'

# ---- PATH stubs: each appends "<name> <argv>" to $VC -------------------------
# ssh: `ssh -G <host>` prints $SSH_G_FILE (the resolved config); `ssh <host>
# true` exits 255 when <host> is $SSH_FAIL_HOST (a dead proxy); anything else
# runs its command here.
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -G ]; then
  printf 'ssh -G %s\n' "$2" >> "$VC"
  printf 'hostname %s\n' "$2"; [ -f "${SSH_G_FILE:-}" ] && cat "$SSH_G_FILE"
  exit 0
fi
host=""; while [ $# -gt 1 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) host="$1"; shift; break ;; esac; done
printf 'ssh %s %s\n' "$host" "$*" >> "$VC"
if [ -n "${SSH_FAIL_HOST:-}" ] && [ "$host" = "root@$SSH_FAIL_HOST" ]; then
  echo "kex_exchange_identification: Connection closed by remote host" >&2; exit 255
fi
exec bash -c "$*"
EOF
cat > "$STUB/flyctl" <<'EOF'
#!/bin/bash
printf 'flyctl %s\n' "$*" >> "$VC"
if [ "${1:-}" = version ]; then
  printf '%s\n' "$PATH" > "${VC%/*}/fly-version-path"
  echo "flyctl v0.0.0-fixture"; exit "${FLY_VERSION_RC:-0}"
fi
echo '[]'
EOF
# ss: a LISTEN line for each port in $SS_LISTEN that the filter names.
cat > "$STUB/ss" <<'EOF'
#!/bin/bash
printf 'ss %s\n' "$*" >> "$VC"
for p in ${SS_LISTEN:-}; do
  case "$*" in *":$p") printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$p" ;; esac
done
exit 0
EOF
cat > "$STUB/crontab" <<'EOF'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "$VC"
[ "${1:-}" = -u ] && shift 2
case "${1:-}" in
  -l) [ -f "$CRONTAB_FILE" ] || { echo "no crontab for root" >&2; exit 1; }; cat "$CRONTAB_FILE" ;;
  -r) rm -f "$CRONTAB_FILE" ;;
  -)  cat > "$CRONTAB_FILE" ;;
  *)  cp "$1" "$CRONTAB_FILE" ;;
esac
EOF
cat > "$STUB/tailscale" <<'EOF'
#!/bin/bash
printf 'tailscale %s\n' "$*" >> "$VC"
echo '{"Peer":{}}'
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
cat > "$STUB/journalctl" <<'EOF'
#!/bin/bash
printf 'journalctl %s\n' "$*" >> "$VC"
exit 1
EOF
for n in gh curl wrangler claude codex aws npx; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$VC"\n' "$n" > "$STUB/$n"
done
chmod +x "$STUB"/*
BASEPATH="$STUB:$PATH"

# ---- per-case scratch --------------------------------------------------------
# newcase <name>: $C, $H (old hub), $TGT (target). The target is NOT seeded;
# `seeded` marks it the way seed does.
newcase() {
  C="$T/$1"; H="$C/h"; TGT="$C/target"
  mkdir -p "$H/state/hub-move" "$H/flags" "$H/logs" "$H/env" "$TGT/state/hub-move" "$TGT/flags" "$C/hssh" "$C/tssh"
  scratch_install_closure "$HM_REL" "$H" >/dev/null || bad "$1: closure into h"
  scratch_install_closure "$HM_REL" "$TGT" >/dev/null || bad "$1: closure into target"
  export HARNESS_SECRET=fixture-secret
  local jside
  for jside in "$H" "$TGT"; do
    # scratch-closure-allow: bin/lib/flags.sh loads bin/jobs-client.sh and its JC_MODULES at run time, which the closure scan cannot follow
    mkdir -p "$jside/bin/lib/jobs" && cp "$REPO/bin/jobs-client.sh" "$jside/bin/" && cp "$REPO"/bin/lib/jobs/*.sh "$jside/bin/lib/jobs/" \
      || bad "$1: jobs-client into $jside"
  done
  printf 'hub\n' > "$H/state/box-id"; printf 'box-hub\n' > "$H/state/box-name"
  printf 'hub\n' > "$TGT/state/box-id"; printf 'box-hub\n' > "$TGT/state/box-name"
  printf '{"provider":"hetzner","ts_ip":"192.0.2.55","ts_hostname":"hub-fixture"}\n' > "$H/state/hub-move/target.json"
  export VC="$C/vendor-calls" CALLS="$C/calls" CRONTAB_FILE="$C/crontab"
  : > "$VC"; : > "$CALLS"
  export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HUB_MOVE_TARGET_HARNESS="$TGT"
  export HUB_MOVE_TARGET_SECRETS="$C/tsec" HUB_MOVE_TARGET_SSH_DIR="$C/tssh" HUB_MOVE_SSH_DIR="$C/hssh"
  export HARNESS_CHECKOUT="$C/co" HUB_MOVE_IMAGE="registry.example/hub:fixture"
  export HUB_MOVE_ORCH="$C/lorch" HUB_MOVE_TARGET_ORCH="$C/torch" HUB_MOVE_FLY_HOME_BIN="$C/flyhome"
  export FLY_BIN_DIR="$C/flybin" HOME="$C/home"
  export HUB_MOVE_TS_WAIT_S=0 HUB_MOVE_LEASE_WAIT_S=0 HUB_MOVE_DRAIN_TIMEOUT_S=1
  export HUB_MOVE_REACH_HOST=192.0.2.20 HUB_MOVE_CRON_JOURNAL="$C/cron-journal"
  export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
  unset HUB_MOVE_TICK_PARALLEL HUB_MOVE_TICK_TIMEOUT_S HUB_MOVE_NOWRITE HUB_MOVE_C1_ALLOW HUB_MOVE_C1_OLD_WINDOW_S
  unset SSH_FAIL_HOST SSH_G_FILE SS_LISTEN FLY_VERSION_RC FLY_SYSTEM_DIRS
  export PATH="$BASEPATH"
  mkdir -p "$C/home"
  printf 'ssh-ed25519 AAAAfixture hub@example\n' > "$C/hssh/id_ed25519.pub"
  printf 'fixture-private-key\n' > "$C/hssh/id_ed25519"
  printf 'BACKUP_S3_ENDPOINT=https://s3.example\nBACKUP_S3_ACCESS_KEY_ID=akid-fixture\nBACKUP_S3_SECRET_ACCESS_KEY=secret-fixture-value\n' > "$H/env/global.env"
  printf 'AGE-SECRET-KEY-FIXTURE\n' > "$C/age.key"
  local side dir n
  for side in h target; do
    dir="$C/$side/bin"
    for n in state-backup bootstrap-machine update-runners registry-sync fleet-propagate hub-lease hub-load-report migrate-env-dir harness-sync alert-line; do
      cat > "$dir/$n.sh" <<EOF
#!/bin/bash
printf '%s:%s %s\n' "$side" "$n" "\$*" >> "\$CALLS"
EOF
    done
    # --tailnet-ips prints $FLEET_IPS (empty: no fleet box address).
    printf '#!/bin/bash\ncase "$1" in --projects) printf "alpha-os\\n" ;; --tailnet-ips) [ -n "${FLEET_IPS:-}" ] && printf "%%s\\n" $FLEET_IPS ;; esac\nexit 0\n' > "$dir/fleet-conf.sh"
    cat > "$dir/state-restore.sh" <<EOF
#!/bin/bash
printf '%s:state-restore %s\n' "$side" "\$*" >> "\$CALLS"
live=""; orch=""
while [ \$# -gt 0 ]; do case "\$1" in --live) live="\$2"; shift 2 ;; --orchestrator-live) orch="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$live" ] || exit 2
mkdir -p "\$live/state" "\$live/flags"
printf 'hub\n' > "\$live/state/box-id"; printf 'box-hub\n' > "\$live/state/box-name"
: > "\$live/flags/automerge-disabled"
[ -z "\$orch" ] || { mkdir -p "\$orch"; printf 'snap\n' > "\$orch/orch-state"; }
EOF
    chmod +x "$dir"/*.sh
  done
  mkdir -p "$C/co/bin" "$C/co/cron/lanes"
  printf '#!/bin/bash\ncat "%s/cron.txt"\n' "$C" > "$C/co/bin/render-cron.sh"
  chmod +x "$C/co/bin/render-cron.sh"
  printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
}
seeded() { printf 'seeded fixture\n' > "$TGT/state/hub-move/target-seeded"; : > "$TGT/flags/all-off"; }
tick() { HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick "$@"; }
hm() { bash "$H/bin/hub-move.sh" "$@"; }
tfile() { printf '%s\n' "$1" | sed -n 's/^tick-file: //p' | tail -1; }
c1state() { awk -F'\t' '$2=="C1"{v=$3} END{print v}' "$H/state/hub-move/steps.tsv" 2>/dev/null; }

# ==== P: the proxy check script (T1) ============================================
LIB="$REPO/bin/lib/hub-move-reach.sh"
# shellcheck source=bin/lib/hub-move-reach.sh
. "$LIB" || bad "P0: cannot source $LIB"
# pcheck <config text> [<PATH>] — run the check script on a fixture config.
pcheck() {
  local d="$C/pcfg"; mkdir -p "$d"
  printf '%s\n' "$1" > "$d/config"
  hmr_proxy_check_script "$d" | PATH="${2:-$BASEPATH}" "$BASH" -s
}
newcase p
check P1-listening "$(SS_LISTEN=1055 pcheck "$ORGO")" ""
check P2-orgo-dead "$(pcheck "$ORGO")" "dead 1055 $ORGO"
has P2-ss-asked "$(cat "$VC")" "ss -ltnH sport = :1055"
check P3-indented-lower "$(pcheck "$(printf 'Host *\n    proxycommand nc -X 5 -x localhost:1055 %%h %%p')")" "dead 1055 proxycommand nc -X 5 -x localhost:1055 %h %p"
check P4-equals-no-space "$(pcheck 'ProxyCommand=nc -x127.0.0.1:1055 %h %p')" "dead 1055 ProxyCommand=nc -x127.0.0.1:1055 %h %p"
check P5-ncat-proxy "$(pcheck 'ProxyCommand ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p')" "dead 1055 ProxyCommand ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p"
check P5b-no-port-1080 "$(pcheck 'ProxyCommand nc -x 127.0.0.1 %h %p')" "dead 1080 ProxyCommand nc -x 127.0.0.1 %h %p"
check P5c-ipv6 "$(pcheck 'ProxyCommand nc -x [::1]:1055 %h %p')" "dead 1055 ProxyCommand nc -x [::1]:1055 %h %p"
check P5d-socat-S "$(pcheck 'ProxyCommand connect -S 127.0.0.1:1055 %h %p')" "dead 1055 ProxyCommand connect -S 127.0.0.1:1055 %h %p"
check P5e-only-dead-port "$(SS_LISTEN=1055 pcheck "$(printf '%s\n%s' "$ORGO" 'ProxyCommand nc -x 127.0.0.1:1066 %h %p')")" "dead 1066 ProxyCommand nc -x 127.0.0.1:1066 %h %p"
check P7-commented "$(pcheck "# $ORGO")" ""
check P7b-commented-indented "$(pcheck "   #$ORGO")" ""
check P8-remote-proxy "$(pcheck 'ProxyCommand nc -x 192.0.2.5:1080 %h %p')" ""
check P9-proxyjump "$(pcheck 'ProxyJump bastion')" ""
check P10-ssh-W "$(pcheck 'ProxyCommand ssh -W %h:%p bastion')" ""
check P11-none "$(pcheck 'ProxyCommand none')" ""
check P12-localforward "$(pcheck 'LocalForward 1055 127.0.0.1:1055')" ""
: > "$VC"
check P13-no-config "$(hmr_proxy_check_script "$C/nocfg" | "$BASH" -s; echo "rc=$?")" "rc=0"
check P13-no-ss-call "$(grep -c '^ss ' "$VC")" 0
# P6: no ss on PATH: a /dev/tcp connect decides. A real listener on a free
# port reads listening; the same port after it closes reads dead.
mkdir -p "$C/nopath"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$C/port" "$C/stop" <<'PY' &
import os, socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5); s.settimeout(0.2)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".tmp", sys.argv[1])
end = time.time() + 20
while time.time() < end and not os.path.exists(sys.argv[2]):
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
s.close()
PY
  LPID=$!
  i=0; until [ -s "$C/port" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded wait for the listener to bind, 10 s cap
  LPORT=$(cat "$C/port" 2>/dev/null)
  check P6-devtcp-listening "$(pcheck "ProxyCommand nc -x 127.0.0.1:$LPORT %h %p" "$C/nopath")" ""
  : > "$C/stop"; wait "$LPID" 2>/dev/null
  check P6-devtcp-dead "$(pcheck "ProxyCommand nc -x 127.0.0.1:$LPORT %h %p" "$C/nopath")" "dead $LPORT ProxyCommand nc -x 127.0.0.1:$LPORT %h %p"
else
  echo "SKIP P6: no python3 for a local listener"
  check P6-devtcp-dead-only "$(pcheck 'ProxyCommand nc -x 127.0.0.1:1 %h %p' "$C/nopath")" "dead 1 ProxyCommand nc -x 127.0.0.1:1 %h %p"
fi

# ==== S: seed refuses a dead proxy port (T2) ===================================
newcase s1
printf 'Host *\n  %s\n' "$ORGO" > "$C/tssh/config"
out=$(hm seed 20261022T120000Z 2>&1); check S1-rc "$?" 4
has S1-names-config "$out" "$C/tssh/config"
has S1-names-port "$out" "127.0.0.1:1055"
has S1-says-nothing-listens "$out" "nothing on the target listens on port 1055"
check S1-no-secret-scp "$(grep -c '^scp .*age-identity' "$VC")" 0
check S1-no-key-scp "$(grep -c '^scp ' "$VC")" 0
check S1-not-seeded "$(yn "$TGT/state/hub-move/target-seeded")" no
check S1-no-all-off "$(yn "$TGT/flags/all-off")" no
check S1-no-restore "$(grep -c state-restore "$CALLS")" 0

newcase s2
printf 'Host *\n  %s\n' "$ORGO" > "$C/tssh/config"
SS_LISTEN=1055 hm seed 20261022T120000Z >"$C/out" 2>&1; check S2-rc "$?" 0
check S2-seeded "$(yn "$TGT/state/hub-move/target-seeded")" yes

newcase s3
hm seed 20261022T120000Z >"$C/out" 2>&1; check S3-rc "$?" 0
check S3-no-ss-call "$(grep -c '^ss ' "$VC")" 0

newcase s4
printf 'Host *\n  %s\n' "$ORGO" > "$C/hssh/config"
hm seed 20261022T120000Z >"$C/out" 2>&1; check S4-rc "$?" 0
check S4-key-copied "$(cat "$C/tssh/id_ed25519" 2>/dev/null)" fixture-private-key
check S4-no-config-scp "$(grep '^scp ' "$VC" | grep -c 'hssh/config')" 0
check S4-no-target-config "$(yn "$C/tssh/config")" no

# ==== R: the tick reach check (T3) =============================================
newcase r1; seeded
printf '* * * * * echo lane >> %s/ran\n* * * * * true\n' "$C" > "$C/cron.txt"
out=$(tick 2>&1); check R1-rc "$?" 0
R1F=$(tfile "$out")
check R1-header "$(sed -n 1p "$R1F" | cut -d' ' -f2)" "mode=nowrite"
check R1-reach-line "$(sed -n 2p "$R1F")" "# reach ssh=0 flyctl=0 host=192.0.2.20"
has R1-says "$out" "tick: reach ssh=0 flyctl=0 host=192.0.2.20"
check R1-lane-ran "$(cat "$C/ran" 2>/dev/null)" lane
check R1-out-files "$(ls "${R1F%.tsv}.out" | wc -l)" 3
check R1-reach-out-sibling "$(yn "${R1F%.tsv}.reach.out")" yes
check R1-all-off-again "$(yn "$TGT/flags/all-off")" yes
cp "$R1F" "$T/r1-table.tsv"

newcase r2; seeded
printf 'Host *\n  %s\n' "$ORGO" > "$C/tssh/config"
printf 'proxycommand /usr/bin/nc -x 127.0.0.1:1055 %%h %%p\n' > "$C/ssh-G"
out=$(SSH_FAIL_HOST=192.0.2.20 SSH_G_FILE="$C/ssh-G" tick 2>&1); check R2-rc "$?" 4
R2F=$(tfile "$out")
check R2-header "$(sed -n 1p "$R2F" | cut -d' ' -f2)" "mode=nowrite-reach-failed"
check R2-reach-line "$(sed -n 2p "$R2F")" "# reach ssh=255 flyctl=0 host=192.0.2.20"
check R2-no-lane "$(yn "$C/ran")" no
check R2-no-lane-rows "$(grep -v '^#' "$R2F" | tail -n +2 | wc -l)" 0
has R2-names-config "$out" "$C/tssh/config"
has R2-names-proxy "$out" "proxycommand /usr/bin/nc -x 127.0.0.1:1055"
has R2-reach-out "$(cat "${R2F%.tsv}.reach.out" 2>/dev/null)" "proxycommand /usr/bin/nc -x 127.0.0.1:1055"
check R2-all-off-kept "$(yn "$TGT/flags/all-off")" yes
check R2-no-deploy "$(grep -c 'harness-sync' "$CALLS")" 0
cp "$R2F" "$T/r2-table.tsv"

newcase r3; seeded
out=$(FLY_VERSION_RC=1 tick 2>&1); check R3-rc "$?" 4
check R3-reach-line "$(sed -n 2p "$(tfile "$out")")" "# reach ssh=0 flyctl=1 host=192.0.2.20"
check R3-no-lane "$(yn "$C/ran")" no

newcase r4; seeded
out=$(SSH_FAIL_HOST=192.0.2.20 tick --real 2>&1); check R4-rc "$?" 4
check R4-header "$(sed -n 1p "$(tfile "$out")" | cut -d' ' -f2)" "mode=real-reach-failed"
check R4-no-lane "$(yn "$C/ran")" no

newcase r5; seeded
out=$(env -u HUB_MOVE_REACH_HOST HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check R5-rc "$?" 4
check R5-reach-line "$(sed -n 2p "$(tfile "$out")")" "# reach ssh=2 flyctl=0 host=-"
has R5-says "$out" "no fleet box address"
check R5-no-fleet-ssh "$(grep -c '^ssh .* true$' "$VC")" 0

newcase r6; seeded
mkdir -p "$C/nofly" "$C/emptyfly"
for n in "$STUB"/*; do case "$(basename "$n")" in flyctl|fly) ;; *) ln -s "$n" "$C/nofly/$(basename "$n")" ;; esac; done
out=$(FLY_BIN_DIR="$C/emptyfly" FLY_SYSTEM_DIRS= PATH="$C/nofly:/usr/bin:/bin" HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1)
check R6-rc "$?" 4
R6F=$(tfile "$out")
check R6-header "$(sed -n 1p "$R6F" | cut -d' ' -f2)" "mode=nowrite-reach-failed"
check R6-reach-line "$(sed -n 2p "$R6F")" "# reach ssh=0 flyctl=127 host=192.0.2.20"
has R6-says "$out" "flyctl not found on this box"
check R6-no-lane "$(yn "$C/ran")" no

newcase r7; seeded
tick >/dev/null 2>&1; check R7-rc "$?" 0
check R7-one-ssh "$(grep -c '^ssh root@192.0.2.20 true$' "$VC")" 1
check R7-one-version "$(grep -c '^flyctl version$' "$VC")" 1
hasnt R7-not-through-shim "$(cat "$C/fly-version-path" 2>/dev/null || echo missing)" "/shim"
hasnt R7-version-ran "$(cat "$C/fly-version-path" 2>/dev/null || echo missing)" "missing"

newcase r8; seeded
out=$(env -u HUB_MOVE_REACH_HOST FLEET_IPS="192.0.2.21 192.0.2.22" HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check R8-rc "$?" 0
check R8-reach-line "$(sed -n 2p "$(tfile "$out")")" "# reach ssh=0 flyctl=0 host=192.0.2.21"
check R8-ssh-first "$(grep -c '^ssh root@192.0.2.21 true$' "$VC")" 1

newcase k1; seeded
HUB_MOVE_REACH_HOST='x;touch pwned' tick >/dev/null 2>&1; check K1-bad-host-rc "$?" 2
check K1-no-lane "$(yn "$C/ran")" no

# ==== C1: the reach line gates C1 (T4) =========================================
newcase c1a
cp "$T/r2-table.tsv" "$H/state/hub-move/tick-a.tsv"
out=$(hm cutover --step C1 --confirm 2>&1); check C1a-rc "$?" 4
has C1a-names-ssh-config "$out" "ssh config"
has C1a-rcs "$out" "ssh=255 flyctl=0 host=192.0.2.20"
check C1a-step-fail "$(c1state)" fail
out=$(HUB_MOVE_C1_ALLOW=hub-move-reach,harness-sync-deploy hm cutover --step C1 --confirm 2>&1); check C1d-allow-no-cover "$?" 4

newcase c1b
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-b.tsv"
out=$(hm cutover --step C1 --confirm 2>&1); check C1b-no-reach-line-rc "$?" 4
has C1b-says "$out" "ssh config"

newcase c1c
cp "$T/r1-table.tsv" "$H/state/hub-move/tick-c.tsv"
out=$(hm cutover --step C1 --confirm 2>&1); check C1c-round-trip-rc "$?" 0
check C1c-step-ok "$(c1state)" ok

newcase c1e
printf '# mode=nowrite at=1699990000\n# reach ssh=0 host=192.0.2.20\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-e.tsv"
hm cutover --step C1 --confirm >/dev/null 2>&1; check C1e-partial-rc "$?" 4

newcase c1f
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\n# reach ssh=0 flyctl=0 host=192.0.2.20\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-f.tsv"
hm cutover --step C1 --confirm >/dev/null 2>&1; check C1f-line3-rc "$?" 4

newcase c1g
printf '# mode=nowrite at=1699990000\n# reach ssh=255 flyctl=0 host=192.0.2.20\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-g.tsv"
hm cutover --step C1 --confirm >/dev/null 2>&1; check C1g-nonzero-rc "$?" 4
printf '# mode=nowrite at=1699990000\n# reach ssh=0 flyctl=0 host=192.0.2.20\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-g.tsv"
hm cutover --step C1 --confirm >/dev/null 2>&1; check C1g-zero-rc "$?" 0

# ==== C6a: the real tick's reach failure fails C6 ===============================
newcase c6a; seeded
printf 'x\tC5\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
out=$(SSH_FAIL_HOST=192.0.2.20 hm cutover --step C6 --confirm 2>&1); check C6a-rc "$?" 4
has C6a-says-reach "$(grep "^hub-move: failed: C6:" <<<"$out")" "C6: tick --real failed: hub-move: failed: tick: reach check failed: ssh root@192.0.2.20 rc=255"
check C6a-step-fail "$(awk -F'\t' '$2=="C6"{v=$3} END{print v}' "$H/state/hub-move/steps.tsv")" fail
check C6a-marker-kept "$(yn "$TGT/state/hub-move/target-seeded")" yes
check C6a-no-update-runners "$(grep -c update-runners "$CALLS")" 0
check C6a-no-lane "$(yn "$C/ran")" no
has C6a-reach-host-forwarded "$(grep '^ssh root@192.0.2.55 ' "$VC")" "HUB_MOVE_REACH_HOST=192.0.2.20 HARNESS=$TGT"

# ==== A1: a dry run against a target whose fleet ssh fails stops at C1 ===========
newcase a1
printf 'Host *\n  %s\n' "$ORGO" > "$C/tssh/config"
printf 'proxycommand /usr/bin/nc -x 127.0.0.1:1055 %%h %%p\n' > "$C/ssh-G"
export SS_LISTEN=1055 SSH_FAIL_HOST=192.0.2.20 SSH_G_FILE="$C/ssh-G"
hm dry-run >"$C/out" 2>&1; check A1-dry-run-rc "$?" 4
check A1-seed-ran "$(yn "$TGT/state/hub-move/target-seeded")" yes
check A1-no-lane "$(yn "$C/ran")" no
has A1-reach-host-forwarded "$(grep '^ssh root@192.0.2.55 ' "$VC")" "HUB_MOVE_REACH_HOST=192.0.2.20 HARNESS=$TGT"
nf=$(ls -t "$H"/state/hub-move/tick-*.tsv 2>/dev/null | head -1)
check A1-table-fetched "$(head -1 "$nf" 2>/dev/null | cut -d' ' -f2)" "mode=nowrite-reach-failed"
out=$(hm cutover --step C1 --confirm 2>&1); check A1-c1-rc "$?" 4
has A1-c1-names-ssh-config "$out" "ssh config $C/tssh/config"
check A1-c1-fail "$(c1state)" fail
unset SS_LISTEN SSH_FAIL_HOST SSH_G_FILE

# ==== B0: no real vendor was called ===============================================
check B0-no-vendor "$(cat "$T"/*/vendor-calls 2>/dev/null | grep -cE '^(gh|curl|wrangler|claude|codex|aws|npx) ')" 0
for n in ssh scp rsync ss flyctl crontab gh curl wrangler claude aws; do
  check "B0-$n-stub" "$(PATH="$BASEPATH" command -v "$n")" "$STUB/$n"
done

echo "hub-move-reach.bh-8123: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
