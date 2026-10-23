#!/bin/bash
# tests/hub-move-seed-immutable-key.bh-8108-test.sh — bin/hub-move.sh seed and
# an immutable target ssh key (BH-8108).
#
# bin/harden-state.sh sets `chattr +i` on the target's /root/.ssh/id_ed25519*
# after a no-write tick. The seed copied every hub key with one bulk scp, which
# cannot open an immutable file, so every later seed exited 4 with
# "scp ssh keys to <ip>" and the cutover stopped at C4. The key on the target
# was byte-identical. This suite pins the fix, one key at a time:
#   I1-I2   same sha256 (immutable or not): no copy, no chattr, one log line.
#   I3, I8  different and immutable: chattr -i, copy, chmod 600, chattr +i.
#   I4-I7   different and not immutable (or lsattr cannot tell): copy, no chattr.
#   I9-I11  chattr -i fails (exit 4, no copy); scp fails (the flag comes back,
#           exit 4); chattr +i fails (a WARN line, exit 0).
#   B0      no vendor call.
#
# No real vendor is called. ssh, scp, rsync, chattr and lsattr are PATH stubs.
# ssh runs its command on this box against a scratch "target". Immutability is
# a marker file $C/immut/<basename>, and the scp stub refuses a destination
# with a marker the way the live scp did ("dest open ... Permission denied").
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-move-seed-immutable-key.bh-8108-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
HM_REL=bin/hub-move.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in: ${2:0:900}"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }
yn() { [ -e "$1" ] && echo yes || echo no; }

export HUB_MOVE_NOW=1700000000
STUB="$T/stub"; mkdir -p "$STUB"

# ---- PATH stubs: each appends "<name> <argv>" to $VC -------------------------
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
host=""; while [ $# -gt 1 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) host="$1"; shift; break ;; esac; done
printf 'ssh %s %s\n' "$host" "$*" >> "$VC"
exec bash -c "$*"
EOF
# scp: a destination with an immutable marker is refused, as on the live target.
# $C/scp-fail makes every copy of an id_* key fail.
cat > "$STUB/scp" <<'EOF'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$VC"
args=(); while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -q) shift ;; *) args+=("$1"); shift ;; esac; done
dst="${args[-1]#*:}"; unset 'args[-1]'
rc=0
for s in "${args[@]}"; do
  if [ -d "$dst" ]; then d="$dst/$(basename "$s")"; else d="$dst"; fi
  b=$(basename "$d")
  case "$b" in id_*) [ -e "$IMMUT/../scp-fail" ] && { echo "scp: forced failure" >&2; rc=1; continue; } ;; esac
  if [ -e "$IMMUT/$b" ]; then echo "scp: dest open \"$d\": Permission denied" >&2; rc=1; continue; fi
  cp "$s" "$d" || rc=1
done
exit "$rc"
EOF
# lsattr -d <f>: `i` when the marker exists. $C/lsattr-mode: fail (rc 1, no
# output) or upper (an upper-case I only, a near miss).
cat > "$STUB/lsattr" <<'EOF'
#!/bin/bash
printf 'lsattr %s\n' "$*" >> "$VC"
f="${!#}"; m=$(cat "$IMMUT/../lsattr-mode" 2>/dev/null)
case "$m" in
  fail) exit 1 ;;
  upper) echo "-------------I-e------- $f"; exit 0 ;;
esac
if [ -e "$IMMUT/$(basename "$f")" ]; then echo "----i---------e------- $f"; else echo "--------------e------- $f"; fi
EOF
# chattr -i|+i <f>: removes or creates the marker, logs to $C/chattr.log.
# $C/chattr-fail-<flag> makes that flag fail.
cat > "$STUB/chattr" <<'EOF'
#!/bin/bash
printf 'chattr %s\n' "$*" >> "$VC"
flag="$1"; f="$2"; b=$(basename "$f")
[ -e "$IMMUT/../chattr-fail-$flag" ] && { echo "chattr: Operation not permitted while setting flags on $f" >&2; exit 1; }
printf 'chattr %s %s\n' "$flag" "$b" >> "$IMMUT/../chattr.log"
case "$flag" in -i) rm -f "$IMMUT/$b" ;; +i) : > "$IMMUT/$b" ;; *) exit 2 ;; esac
EOF
cat > "$STUB/rsync" <<'EOF'
#!/bin/bash
printf 'rsync %s\n' "$*" >> "$VC"
EOF
for n in gh curl flyctl tailscale crontab wrangler claude codex aws npx; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$VC"\n' "$n" > "$STUB/$n"
done
chmod +x "$STUB"/*
BASEPATH="$STUB:$PATH"

# ---- per-case scratch --------------------------------------------------------
# newcase <name>: $C, $H (old hub), $TGT (target harness), $TS (target ssh dir),
# $HS (hub ssh dir, with id_ed25519 and id_ed25519.pub). Nothing is shared
# between cases.
newcase() {
  C="$T/$1"; H="$C/h"; TGT="$C/target"; TS="$C/tssh"; HS="$C/hssh"
  mkdir -p "$H/state/hub-move" "$H/flags" "$H/logs" "$H/env" "$TGT/state/hub-move" "$TGT/flags" "$HS" "$TS" "$C/immut" "$C/home"
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
  printf '{"provider":"hetzner","ts_ip":"192.0.2.44","ts_hostname":"bh-hub-2"}\n' > "$H/state/hub-move/target.json"
  export VC="$C/vendor-calls" CALLS="$C/calls" IMMUT="$C/immut"
  : > "$VC"; : > "$CALLS"
  export HARNESS="$H" HARNESS_ENV_DIR="$H/env" HUB_MOVE_TARGET_HARNESS="$TGT"
  export HUB_MOVE_TARGET_SECRETS="$C/tsec" HUB_MOVE_TARGET_SSH_DIR="$TS" HUB_MOVE_SSH_DIR="$HS"
  export HARNESS_CHECKOUT="$C/co" HUB_MOVE_IMAGE="registry.example/hub:fixture"
  export HUB_MOVE_ORCH="$C/lorch" HUB_MOVE_TARGET_ORCH="$C/torch" HUB_MOVE_FLY_HOME_BIN="$C/flyhome"
  export FLY_BIN_DIR="$C/flybin" HOME="$C/home" BACKUP_AGE_IDENTITY_FILE="$C/age.key"
  export HUB_MOVE_TS_WAIT_S=0 HUB_MOVE_LEASE_WAIT_S=0 HUB_MOVE_DRAIN_TIMEOUT_S=1
  export PATH="$BASEPATH"
  printf 'PRIVATE-KEY-HUB\n' > "$HS/id_ed25519"
  printf 'ssh-ed25519 AAAAhub hub@example\n' > "$HS/id_ed25519.pub"
  chmod 600 "$HS"/id_*
  printf 'BACKUP_S3_ENDPOINT=https://s3.example\nBACKUP_S3_ACCESS_KEY_ID=akid-fixture\nBACKUP_S3_SECRET_ACCESS_KEY=secret-fixture-value\n' > "$H/env/global.env"
  printf 'AGE-SECRET-KEY-FIXTURE\n' > "$C/age.key"
  local side dir n
  for side in h target; do
    dir="$C/$side/bin"
    for n in bootstrap-machine migrate-env-dir; do
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
[ -z "\$orch" ] || { mkdir -p "\$orch"; printf 'snap\n' > "\$orch/orch-state"; }
EOF
    chmod +x "$dir"/*.sh
  done
}
hm() { bash "$H/bin/hub-move.sh" "$@"; }
# tkey <basename> <content> [immutable] — a key file on the target.
tkey() { printf '%s\n' "$2" > "$TS/$1"; chmod 600 "$TS/$1"; [ "${3:-}" = immutable ] && : > "$IMMUT/$1"; true; }
keyscp() { grep -c "^scp .*/$1 " "$VC"; }
clog() { [ -f "$C/chattr.log" ] && tr '\n' '|' < "$C/chattr.log"; true; }
SAME_PRIV='PRIVATE-KEY-HUB'; SAME_PUB='ssh-ed25519 AAAAhub hub@example'

# ==== I1: same keys, both immutable (the no-write tick case) ====================
newcase i1
tkey id_ed25519 "$SAME_PRIV" immutable; tkey id_ed25519.pub "$SAME_PUB" immutable
hm seed latest >"$C/out" 2>"$C/err"; check I1-rc "$?" 0
out=$(cat "$C/out" "$C/err")
has I1-skip-priv "$out" "seed: id_ed25519 on the target is the same as the hub key; copy skipped"
has I1-skip-pub "$out" "seed: id_ed25519.pub on the target is the same as the hub key; copy skipped"
hasnt I1-no-scp-fail "$out" "scp ssh keys"
check I1-no-key-scp "$(grep -c '^scp .*id_ed25519' "$VC")" 0
check I1-no-chattr "$(clog)" ""
check I1-marker-priv "$(yn "$IMMUT/id_ed25519")" yes
check I1-marker-pub "$(yn "$IMMUT/id_ed25519.pub")" yes
has I1-done "$out" "seed: done (latest)"
check I1-restored "$(grep -c 'target:state-restore' "$CALLS")" 1

# ==== I2: same keys, not immutable ==============================================
newcase i2
tkey id_ed25519 "$SAME_PRIV"; tkey id_ed25519.pub "$SAME_PUB"
out=$(hm seed latest 2>&1); check I2-rc "$?" 0
has I2-skip "$out" "seed: id_ed25519 on the target is the same as the hub key; copy skipped"
check I2-no-key-scp "$(grep -c '^scp .*id_ed25519' "$VC")" 0
check I2-no-chattr "$(clog)" ""

# ==== I3: the private key differs and is immutable ===============================
newcase i3
tkey id_ed25519 "PRIVATE-KEY-OLD" immutable; tkey id_ed25519.pub "$SAME_PUB"
out=$(hm seed latest 2>&1); check I3-rc "$?" 0
check I3-chattr-cycle "$(clog)" "chattr -i id_ed25519|chattr +i id_ed25519|"
check I3-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
check I3-marker-back "$(yn "$IMMUT/id_ed25519")" yes
check I3-mode "$(stat -c %a "$TS/id_ed25519")" 600
has I3-says-minus "$out" "seed: id_ed25519 on the target is immutable and differs; chattr -i"
has I3-says-plus "$out" "seed: chattr +i id_ed25519 again"
check I3-one-priv-scp "$(keyscp id_ed25519)" 1
check I3-no-pub-scp "$(keyscp id_ed25519.pub)" 0
has I3-done "$out" "seed: done (latest)"

# ==== I4: differs, not immutable ================================================
newcase i4
tkey id_ed25519 "PRIVATE-KEY-OLD"; tkey id_ed25519.pub "$SAME_PUB"
out=$(hm seed latest 2>&1); check I4-rc "$?" 0
check I4-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
check I4-no-chattr "$(clog)" ""
check I4-one-priv-scp "$(keyscp id_ed25519)" 1

# ==== I5: the target ssh dir is empty ===========================================
newcase i5
out=$(hm seed latest 2>&1); check I5-rc "$?" 0
check I5-priv "$(cat "$TS/id_ed25519" 2>/dev/null)" "$SAME_PRIV"
check I5-pub "$(cat "$TS/id_ed25519.pub" 2>/dev/null)" "$SAME_PUB"
check I5-no-chattr "$(clog)" ""
hasnt I5-no-skip-line "$out" "copy skipped"

# ==== I6: differs; lsattr fails with no output ===================================
newcase i6
tkey id_ed25519 "PRIVATE-KEY-OLD"; tkey id_ed25519.pub "$SAME_PUB"; echo fail > "$C/lsattr-mode"
out=$(hm seed latest 2>&1); check I6-rc "$?" 0
check I6-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
check I6-no-chattr "$(clog)" ""

# ==== I7: differs; flags carry an upper-case I only (not immutable) ==============
newcase i7
tkey id_ed25519 "PRIVATE-KEY-OLD"; tkey id_ed25519.pub "$SAME_PUB"; echo upper > "$C/lsattr-mode"
out=$(hm seed latest 2>&1); check I7-rc "$?" 0
check I7-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
check I7-no-chattr "$(clog)" ""

# ==== I8: .pub same + immutable, private differs + immutable =====================
newcase i8
tkey id_ed25519 "PRIVATE-KEY-OLD" immutable; tkey id_ed25519.pub "$SAME_PUB" immutable
out=$(hm seed latest 2>&1); check I8-rc "$?" 0
has I8-pub-skip "$out" "seed: id_ed25519.pub on the target is the same as the hub key; copy skipped"
check I8-chattr-priv-only "$(clog)" "chattr -i id_ed25519|chattr +i id_ed25519|"
check I8-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
check I8-markers "$(yn "$IMMUT/id_ed25519")$(yn "$IMMUT/id_ed25519.pub")" yesyes
check I8-no-pub-scp "$(keyscp id_ed25519.pub)" 0

# ==== I9: differs + immutable, chattr -i fails ===================================
newcase i9
tkey id_ed25519 "PRIVATE-KEY-OLD" immutable; tkey id_ed25519.pub "$SAME_PUB"; : > "$C/chattr-fail--i"
hm seed latest >"$C/out" 2>"$C/err"; check I9-rc "$?" 4
has I9-stderr "$(cat "$C/err")" "chattr -i ssh key id_ed25519 on 192.0.2.44"
check I9-content-unchanged "$(cat "$TS/id_ed25519")" "PRIVATE-KEY-OLD"
check I9-marker-kept "$(yn "$IMMUT/id_ed25519")" yes
check I9-no-priv-scp "$(keyscp id_ed25519)" 0
check I9-no-restore "$(grep -c 'state-restore' "$CALLS")" 0
hasnt I9-no-minus-line "$(cat "$C/out")" "chattr -i"

# ==== I10: differs + immutable, scp fails: the flag comes back, exit 4 ===========
newcase i10
tkey id_ed25519 "PRIVATE-KEY-OLD" immutable; tkey id_ed25519.pub "$SAME_PUB"; : > "$C/scp-fail"
hm seed latest >"$C/out" 2>"$C/err"; check I10-rc "$?" 4
has I10-stderr "$(cat "$C/err")" "scp ssh key id_ed25519 on 192.0.2.44"
check I10-chattr-ends-plus "$(tail -1 "$C/chattr.log" 2>/dev/null)" "chattr +i id_ed25519"
check I10-marker-back "$(yn "$IMMUT/id_ed25519")" yes
check I10-no-restore "$(grep -c 'state-restore' "$CALLS")" 0

# ==== I11: differs + immutable, chattr +i fails: WARN, exit 0 ====================
newcase i11
tkey id_ed25519 "PRIVATE-KEY-OLD" immutable; tkey id_ed25519.pub "$SAME_PUB"; : > "$C/chattr-fail-+i"
out=$(hm seed latest 2>&1); check I11-rc "$?" 0
has I11-warn "$out" "seed: WARN chattr +i id_ed25519 failed on 192.0.2.44"
check I11-content "$(cat "$TS/id_ed25519")" "$SAME_PRIV"
hasnt I11-no-again-line "$out" "seed: chattr +i id_ed25519 again"
has I11-done "$out" "seed: done (latest)"

# ==== B0: no vendor call in any case ============================================
check B0-no-vendor "$(cat "$T"/i*/vendor-calls | grep -cE '^(gh|curl|flyctl|wrangler|claude|codex|aws|npx) ')" 0

echo "hub-move-seed-immutable-key.bh-8108: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
