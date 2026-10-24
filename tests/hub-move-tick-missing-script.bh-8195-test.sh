#!/bin/bash
# tests/hub-move-tick-missing-script.bh-8195-test.sh — BH-8195: a hub-move
# tick names a missing script in one line, in place of a bash error.
#
#   THE INCIDENT (2026-10-23). On the new hub bh-hub-2 a lane whose script was
#   absent showed only bash's `No such file or directory` in the tick output,
#   and the reader could not tell which path was gone.
#
#   M1  a cron line `$TGT/bin/hub-lease.sh check && $TGT/bin/gone.sh >> ...`
#       prints exactly one `tick: gone: missing script $TGT/bin/gone.sh` line
#       on stdout, no `No such file or directory`, and the TSV row has rc 127.
#   M2  the lane's kept .out holds the same one line.
#   M3  a present script lane runs as before (rc 0); the summary ends missing=1.
#   M4  every NOT-MISSING row of the plan's decision table runs, none flagged.
#   M5  a quoted missing path is flagged.
#
# Stubs and the scratch target are those of tests/hub-move-tick-safety.bh-8038-test.sh
# (copied, not sourced). Every tick here is --real on a seeded target.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-move-tick-missing-script.bh-8195-test.sh
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

# ---- PATH stubs: each appends "<name> <argv>" to $VC -------------------------
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
cat > "$STUB/flyctl" <<'EOF'
#!/bin/bash
printf 'flyctl %s\n' "$*" >> "$VC"
echo '[]'
EOF
cat > "$STUB/tailscale" <<'EOF'
#!/bin/bash
printf 'tailscale %s\n' "$*" >> "$VC"
echo '{"Peer":{}}'
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
cat > "$STUB/journalctl" <<'EOF'
#!/bin/bash
printf 'journalctl %s\n' "$*" >> "$VC"
[ -f "${JOURNAL_FIXTURE:-}" ] || exit 1
cat "$JOURNAL_FIXTURE"
EOF
cat > "$STUB/rsync" <<'EOF'
#!/bin/bash
printf 'rsync %s\n' "$*" >> "$VC"
EOF
for n in gh curl wrangler claude codex aws npx; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$VC"\n' "$n" > "$STUB/$n"
done
chmod +x "$STUB"/*
BASEPATH="$STUB:$PATH"

# ---- per-case scratch --------------------------------------------------------
# newcase <name>: $C, $H (old hub), $TGT (target, seeded: state/hub-move/target-seeded).
newcase() {
  C="$T/$1"; H="$C/h"; TGT="$C/target"
  mkdir -p "$H/state" "$H/flags" "$H/logs" "$H/env" "$TGT/state/hub-move" "$TGT/flags" "$C/hssh"
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
  printf 'seeded fixture\n' > "$TGT/state/hub-move/target-seeded"
  export VC="$C/vendor-calls" CALLS="$C/calls" CRONTAB_FILE="$C/crontab"
  : > "$VC"; : > "$CALLS"
  # Every path hub-move.sh writes or reads, and every default that names /root.
  export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HUB_MOVE_TARGET_HARNESS="$TGT"
  export HUB_MOVE_TARGET_SECRETS="$C/tsec" HUB_MOVE_TARGET_SSH_DIR="$C/tssh" HUB_MOVE_SSH_DIR="$C/hssh"
  export HARNESS_CHECKOUT="$C/co" HUB_MOVE_IMAGE="registry.example/hub:fixture"
  export HUB_MOVE_ORCH="$C/lorch" HUB_MOVE_TARGET_ORCH="$C/torch" HUB_MOVE_FLY_HOME_BIN="$C/flyhome"
  export FLY_BIN_DIR="$C/flybin" HOME="$C/home"
  export HUB_MOVE_TS_WAIT_S=0 HUB_MOVE_LEASE_WAIT_S=0 HUB_MOVE_DRAIN_TIMEOUT_S=1
  unset BACKUP_AGE_IDENTITY_FILE HUB_MOVE_TICK_PARALLEL HUB_MOVE_TICK_TIMEOUT_S HUB_MOVE_NOWRITE HUB_MOVE_C1_ALLOW HUB_MOVE_C1_OLD_WINDOW_S JOURNAL_FIXTURE
  # C1 reads the old hub's cron journal from this file (absent by default).
  export HUB_MOVE_CRON_JOURNAL="$C/cron-journal"
  export PATH="$BASEPATH"
  mkdir -p "$C/home"
  printf 'ssh-ed25519 AAAAfixture hub@example\n' > "$C/hssh/id_ed25519.pub"
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
    printf '#!/bin/bash\nif [ "$1" = --projects ]; then printf "alpha-os\\n"; fi\n' > "$dir/fleet-conf.sh"
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
  : > "$C/cron.txt"
}
tick() { HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick "$@"; }
hm() { bash "$H/bin/hub-move.sh" "$@"; }
tfile() { printf '%s\n' "$1" | sed -n 's/^tick-file: //p' | tail -1; }
row() { awk -F'\t' -v l="$2" '$1==l{print $2"/"$4}' "$1"; }
# outof <tick-file> <lane> — that lane's kept output (row n of the table = n.out).
outof() { local n; n=$(grep -v '^#' "$1" | tail -n +2 | awk -F'\t' -v l="$2" '$1==l{print NR; exit}'); cat "${1%.tsv}.out/$n.out" 2>/dev/null; }

# ==== M1-M3: a missing script, a present one ===================================
newcase m
mkdir -p "$TGT/logs"
cat > "$C/cron.txt" <<CRON
*/5 * * * * $TGT/bin/hub-lease.sh check && $TGT/bin/gone.sh >> $TGT/logs/g.log 2>&1
*/5 * * * * $TGT/bin/hub-load-report.sh >> $TGT/logs/hlr.log 2>&1
CRON
out=$(tick --real 2>&1); check M1-rc "$?" 0
f=$(tfile "$out")
check M1-one-line "$(grep -c 'missing script' <<<"$out")" 1
check M1-line "$(grep 'missing script' <<<"$out")" "tick: gone: missing script $TGT/bin/gone.sh"
hasnt M1-no-bash-error "$out" "No such file or directory"
check M1-rc-127 "$(awk -F'\t' '$1=="gone"{print $2}' "$f")" 127
hasnt M1-not-run "$(cat "$CALLS")" "target:hub-lease"
check M2-out "$(outof "$f" gone)" "tick: gone: missing script $TGT/bin/gone.sh"
check M3-present-rc "$(awk -F'\t' '$1=="hub-load-report"{print $2}' "$f")" 0
has M3-present-ran "$(cat "$CALLS")" "target:hub-load-report"
case "$(grep '^tick: lanes=' <<<"$out")" in
  "tick: lanes=2 ok=1 fail=1 timeout=0 refused_writes=0 mode=real skipped=0 missing=1") ok ;;
  *) bad "M3-summary: got [$(grep '^tick: lanes=' <<<"$out")]" ;;
esac

# ==== M4: the NOT-MISSING rows =================================================
newcase m4
FLOCK=$(command -v flock)
mkdir -p "$TGT/locks" "$TGT/logs"
printf '#!/bin/bash\necho ran-ok >> "%s/ran"\n' "$C" > "$TGT/bin/ok.sh"; chmod +x "$TGT/bin/ok.sh"
cat > "$C/cron.txt" <<CRON
* * * * * $TGT/bin/ok.sh
* * * * * N=ok; $TGT/bin/\${N}.sh
* * * * * $FLOCK -n $TGT/locks/l $TGT/bin/ok.sh
* * * * * echo bin-log >> $TGT/logs/bin.log
* * * * * TGT=$TGT; [ -x \$TGT/bin/x.sh ] || echo unexpanded >> $C/ran
* * * * * cd $TGT && [ -x bin/x.sh ] || echo relative >> $C/ran
* * * * * printf 'x\n' > $C/newcron; echo crontab-shape >> $C/ran
CRON
out=$(tick --real 2>&1); check M4-rc "$?" 0
hasnt M4-none-flagged "$out" "missing script"
check M4-all-ran "$(sort "$C/ran" 2>/dev/null | tr '\n' ' ')" "crontab-shape ran-ok ran-ok ran-ok relative unexpanded "
check M4-bin-log "$(cat "$TGT/logs/bin.log" 2>/dev/null)" bin-log
has M4-summary "$out" "skipped=0 missing=0"

# ==== M5: a quoted missing path =================================================
newcase m5
printf "* * * * * '%s/bin/gone.sh' --x >> %s/logs/q.log 2>&1\n" "$TGT" "$TGT" > "$C/cron.txt"
out=$(tick --real 2>&1); check M5-rc "$?" 0
check M5-line "$(grep 'missing script' <<<"$out")" "tick: gone: missing script $TGT/bin/gone.sh"
has M5-summary "$out" "missing=1"

echo "hub-move-tick-missing-script.bh-8195: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
