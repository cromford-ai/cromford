#!/bin/bash
# tests/hub-move-tick-safety.bh-8038-test.sh — bin/hub-move.sh tick safety (BH-8038).
#
# On 2026-10-22 a no-write `tick` on the hub-move target ran
# bin/update-runners.sh, which installed the full hub crontab on the target.
# The target ran live hub lanes for 8 minutes (a split brain). This suite pins
# the fix:
#   A  a no-write tick never installs a crontab: the shim refuses `crontab`
#      writes, the cron installers (update-runners, registry-sync,
#      fleet-propagate) are skipped, and the tick runs only on a seeded target.
#      The tick lifts the target's local flags/all-off for its lanes and sets
#      it again at the end.
#   B  a crontab on the target before or after a tick is removed, saved, a
#      local flags/all-off is written, one ALERTS line goes out, and the tick
#      exits non-zero. The tick table is marked so C1 refuses it.
#   O  a lane's output is kept even when its cron line ends in >/dev/null 2>&1.
#   L  C1 takes the reviewed allow-list HUB_MOVE_C1_ALLOW.
#   S  C1 reads the old hub's cron journal: a lane that failed with the same
#      rc on the old hub in the same window is `same-on-old-hub`, not a target
#      failure. An rc it cannot read stays a failure and says why.
#   T  a tick stopped by the before-guard leaves a `-crontab-found` stub table,
#      and dry-run fetches it, so C1 never reads an older clean table.
#   E  a non-Fly target (target.json provider=hetzner, no machine_id): seed,
#      dry-run, C5-C8 and rollback run; provision refuses.
#   G  the HARNESS_TEST_SANDBOX=1 guard refuses a crontab binary outside the
#      scratch tree.
#
# No real vendor is called. crontab, flyctl, tailscale, ssh, scp and rsync are
# PATH stubs that record their argv. ssh runs its command on this box against
# a scratch "target" harness. Every path hub-move.sh writes is under $T.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-move-tick-safety.bh-8038-test.sh
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

# ==== W: the shim's crontab row =================================================
newcase w
(
  . "$H/bin/lib/hub-move-nowrite.sh"
  pl=$(hmn_make_dir "$C/shim") || exit 9
  export PATH="${pl#PATH=}" HUB_MOVE_NOWRITE_LOG="$C/nw.log"
  printf '* * * * * echo planted\n' > "$C/f"
  crontab -l >/dev/null 2>&1; echo "l=$?"
  crontab -u root -l >/dev/null 2>&1; echo "ul=$?"
  crontab "$C/f" 2>/dev/null; echo "file=$?"
  printf 'x\n' | crontab - 2>/dev/null; echo "stdin=$?"
  crontab -r 2>/dev/null; echo "r=$?"
  crontab -e 2>/dev/null; echo "e=$?"
  crontab </dev/null 2>/dev/null; echo "none=$?"
) > "$C/w.out" 2>&1
w=$(tr '\n' ' ' < "$C/w.out")
check W1-table "$w" "l=1 ul=1 file=75 stdin=75 r=75 e=75 none=75 "
check W1-never-installed "$(yn "$CRONTAB_FILE")" no
check W1-real-argv "$(cut -d' ' -f2- "$VC" | sort -u | tr '\n' '|')" "-l|-u root -l|"
check W1-refusals-logged "$(grep -c $'\tcrontab\trefuse\t' "$C/nw.log" 2>/dev/null)" 5

# ==== A: a no-write tick never installs a crontab ===============================
newcase a
cat > "$C/cron.txt" <<EOF
* * * * * printf '* * * * * echo live\n' > $C/newcron; crontab $C/newcron
17 5 * * * $TGT/bin/update-runners.sh
*/5 * * * * $TGT/bin/registry-sync.sh >/dev/null 2>&1
*/5 * * * * $TGT/bin/hub-lease.sh check && $TGT/bin/fleet-propagate.sh >> $TGT/logs/fp.log 2>&1
* * * * * crontab -l; echo read-ok >> $C/ran
* * * * * if [ -e $TGT/flags/all-off ]; then echo on; else echo off; fi > $C/during
EOF
touch "$TGT/flags/all-off"
out=$(tick 2>&1); check A1-rc "$?" 0
check A1-no-crontab-installed "$(yn "$CRONTAB_FILE")" no
hasnt A1-no-install-call "$(cat "$VC")" "crontab $C/newcron"
f=$(tfile "$out")
check A1-install-refused "$(row "$f" printf)" "75/1"
has A1-summary-refused "$out" "refused_writes=1 mode=nowrite"
has A1-shim-says "$(outof "$f" printf)" "hub-move nowrite: refused crontab"
check A1-read-allowed "$(cat "$C/ran" 2>/dev/null)" read-ok
for l in update-runners registry-sync fleet-propagate; do
  hasnt "A1-$l-not-run" "$(cat "$CALLS")" "target:$l"
  has "A1-$l-skipped" "$out" "tick: skipped $l"
  check "A1-$l-no-row" "$(awk -F'\t' -v l="$l" '$1==l' "$f" | wc -l)" 0
done
check A1-lanes-ran-without-all-off "$(cat "$C/during" 2>/dev/null)" off
check A1-all-off-after "$(yn "$TGT/flags/all-off")" yes
# A2: a no-write tick sets all-off on a seeded target that had none.
newcase a2
printf '* * * * * true\n' > "$C/cron.txt"
tick >/dev/null 2>&1; check A2-rc "$?" 0
check A2-all-off-set "$(yn "$TGT/flags/all-off")" yes
# A3: a no-write tick refuses a box that is not a seeded target (the live hub).
newcase a3
scratch_rm "$TGT/state/hub-move/target-seeded"
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
out=$(tick 2>&1); check A3-rc "$?" 3
has A3-says "$out" "not a seeded hub-move target"
check A3-no-lane "$(yn "$C/ran")" no
check A3-no-all-off "$(yn "$TGT/flags/all-off")" no
check A3-no-crontab-call "$(grep -c '^crontab' "$VC")" 0

# ==== B: a crontab on the target stops the tick =================================
newcase b
# The lane calls crontab by its absolute path, past the shim.
printf '* * * * * printf "* * * * * echo live\\n" | %s/crontab -\n' "$STUB" > "$C/cron.txt"
out=$(tick 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "B1-rc: want non-zero got 0"
check B1-crontab-removed "$(yn "$CRONTAB_FILE")" no
check B1-saved "$(cat "$TGT"/state/hub-move/target-crontab-found-*.txt 2>/dev/null)" "* * * * * echo live"
check B1-all-off "$(yn "$TGT/flags/all-off")" yes
check B1-one-alert "$(grep -c 'target:alert-line --id hub-move-tick-crontab' "$CALLS")" 1
has B1-says "$out" "a crontab is installed on this box after the tick"
f=$(ls "$TGT"/state/hub-move/tick-*.tsv 2>/dev/null | head -1)
case "$(head -1 "$f" 2>/dev/null)" in "# mode=nowrite at="*) bad "B1-table-marked: C1 would accept $f" ;; *) ok ;; esac
# C1 on that table refuses.
mkdir -p "$H/state/hub-move"; cp "$f" "$H/state/hub-move/"
hm cutover --step C1 --confirm >/dev/null 2>&1; check B1-c1-refuses "$?" 4
# B2: a crontab already there before the tick: no lane runs.
newcase b2
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
printf 'SHELL=/bin/bash\n# saved\n@reboot /root/harness/bin/x.sh\n' > "$CRONTAB_FILE"
out=$(tick 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "B2-rc: want non-zero got 0"
check B2-no-lane "$(yn "$C/ran")" no
check B2-crontab-removed "$(yn "$CRONTAB_FILE")" no
check B2-all-off "$(yn "$TGT/flags/all-off")" yes
has B2-says "$out" "before the tick"
f=$(tfile "$out")
check B2-stub-table "$(head -1 "$f" 2>/dev/null | cut -d' ' -f2)" "mode=nowrite-crontab-found"
check B2-stub-is-newest "$(ls -t "$TGT"/state/hub-move/tick-*.tsv 2>/dev/null | head -1)" "$f"
# B3: comments and env lines only are not an active crontab.
newcase b3
printf '* * * * * true\n' > "$C/cron.txt"
printf 'SHELL=/bin/bash\n# only a note\n\n' > "$CRONTAB_FILE"
tick >/dev/null 2>&1; check B3-rc "$?" 0
check B3-kept "$(yn "$CRONTAB_FILE")" yes
# B4: a real tick on a seeded target (C6) checks too.
newcase b4
printf '* * * * * printf "* * * * * echo live\\n" | crontab -\n' > "$C/cron.txt"
tick --real >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok || bad "B4-rc: want non-zero got 0"
check B4-crontab-removed "$(yn "$CRONTAB_FILE")" no

# ==== O: lane output is kept despite >/dev/null 2>&1 ============================
newcase o
cat > "$C/cron.txt" <<EOF
* * * * * sh -c 'echo visible-out; echo visible-err >&2; exit 1' >/dev/null 2>&1
* * * * * echo to-log >> $C/lane.log 2>&1
* * * * * echo both-gone 2>/dev/null > /dev/null
* * * * * sh -c 'echo or-true-out; exit 3' >/dev/null 2>&1 || true
EOF
out=$(tick 2>&1); check O1-rc "$?" 0
f=$(tfile "$out")
has O1-stdout "$(outof "$f" sh)" visible-out
has O1-stderr "$(outof "$f" sh)" visible-err
check O1-rc-kept "$(row "$f" sh)" "1/0"
check O2-log-redirect-kept "$(cat "$C/lane.log" 2>/dev/null)" to-log
hasnt O2-not-in-out "$(outof "$f" echo)" to-log
has O3-stripped-both "$(outof "$f" 'echo~2')" both-gone
has O4-or-true-kept "$(outof "$f" 'sh~2')" or-true-out
check O4-or-true-rc "$(row "$f" 'sh~2')" "0/0"

# ==== L: C1 allow-list ===========================================================
newcase l; mkdir -p "$H/state/hub-move"
printf '{"ts_ip":"192.0.2.44"}\n' > "$H/state/hub-move/target.json"
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\nregistry-export\t1\t1\t0\t0\nlib\t1\t1\t0\t0\nlib~2\t1\t1\t0\t0\n' > "$H/state/hub-move/tick-a.tsv"
out=$(hm cutover --step C1 --confirm 2>&1); check L1-without-allow-rc "$?" 4
has L1-names "$out" "registry-export(rc=1)"
out=$(HUB_MOVE_C1_ALLOW=registry-export,lib hm cutover --step C1 --confirm 2>&1); check L2-allowed-rc "$?" 0
has L2-line "$out" "HUB_MOVE_C1_ALLOW=registry-export,lib"
has L2-allowed-lanes "$out" "allowed failures: registry-export(rc=1) lib(rc=1) lib~2(rc=1)"
st=$(awk -F'\t' '$2=="C1"{v=$3"|"$4} END{print v}' "$H/state/hub-move/steps.tsv")
has L2-steps-ok "$st" "ok|"
has L2-steps-allow "$st" "allow=registry-export,lib"
has L2-steps-allowed "$st" "allowed_failed=registry-export(rc=1),lib(rc=1),lib~2(rc=1)"
printf 'other\t2\t1\t0\t0\n' >> "$H/state/hub-move/tick-a.tsv"
out=$(HUB_MOVE_C1_ALLOW=registry-export,lib hm cutover --step C1 --confirm 2>&1); check L3-other-blocks-rc "$?" 4
has L3-names-other "$out" "other(rc=2)"
hasnt L3-allowed-not-blocking "$(printf '%s\n' "$out" | grep 'failed with no refused write')" "registry-export(rc=1)"
out=$(HUB_MOVE_C1_ALLOW='lib other;rm' hm cutover --step C1 --confirm 2>&1); check L4-bad-value-rc "$?" 2
out=$(HUB_MOVE_C1_ALLOW=lib hm cutover --step C1 2>&1); check L5-would-rc "$?" 0
has L5-would-names-allow "$out" "HUB_MOVE_C1_ALLOW=lib"

# ==== S: same-on-old-hub (the old hub's cron journal) ===========================
# C1 renders the old hub's crontab (co/bin/render-cron.sh prints cron.txt) to
# map each tick lane id to its cron command, then reads the cron journal
# (journalctl -t CRON -o short-unix, or the file HUB_MOVE_CRON_JOURNAL).
newcase s; mkdir -p "$H/state/hub-move"
printf '{"ts_ip":"192.0.2.44"}\n' > "$H/state/hub-move/target.json"
RX='/root/harness/bin/registry-export.sh --snapshot /root/harness/state/registry/export >/dev/null 2>&1'
SLO='/root/harness/bin/hub-lease.sh check && /root/harness/bin/fleet-slo.sh --dry-run >/dev/null 2>&1'
BC='/root/harness/bin/hub-lease.sh check && /root/harness/bin/board-conformance.sh --all >/dev/null 2>&1'
CBA='/root/harness/bin/lib/cadence-backstop.sh merge-conductor'
CBB='/root/harness/bin/lib/cadence-backstop.sh blocked-resolver'
cat > "$C/cron.txt" <<EOF
SHELL=/bin/bash
41 3 * * * $RX
*/10 * * * * $SLO
35 7 * * * $BC
*/30 * * * * $CBA
4,34 * * * * $CBB
* * * * * /root/harness/bin/other.sh
EOF
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\nregistry-export\t1\t1\t0\t0\nfleet-slo\t1\t1\t0\t0\nboard-conformance\t1\t1\t0\t0\nlib\t1\t1\t0\t0\nlib~2\t1\t1\t0\t0\nother\t2\t1\t0\t0\ngone\t1\t1\t0\t0\n' > "$H/state/hub-move/tick-s.tsv"
cat > "$C/cron-journal" <<EOF
1699900000.000001 hub CRON[90]: (root) CMD ($CBB)
1699900001.000001 hub CRON[90]: (CRON) error (grandchild #91 failed with exit status 1)
1699995000.000001 hub CRON[100]: (root) CMD ($RX)
1699995009.000001 hub CRON[100]: (CRON) error (grandchild #101 failed with exit status 1)
1699996000.000001 hub CRON[300]: (root) CMD ($BC)
1699996001.000001 hub CRON[300]: (CRON) error (grandchild #301 failed with exit status 2)
1699997000.000001 hub CRON[400]: (root) CMD ($CBA)
1699997001.000001 hub CRON[400]: (CRON) error (grandchild #401 failed with exit status 1)
1699998000.000001 hub CRON[200]: (root) CMD ($SLO)
1699999000.000001 hub CRON[201]: (root) CMD ($SLO)
1699999100.000001 hub CRON[200]: (CRON) error (grandchild #202 failed with exit status 1)
EOF
out=$(hm cutover --step C1 --confirm 2>&1); check S1-rc "$?" 4
has S1-same "$out" "same-on-old-hub: registry-export(rc=1) lib(rc=1)"
blk=$(printf '%s\n' "$out" | grep 'failed with no refused write')
hasnt S1-same-not-blocking "$blk" "registry-export(rc=1"
hasnt S1-lib-not-blocking "$blk" " lib(rc=1"
has S1-newest-run-ok "$blk" "fleet-slo(rc=1) old hub rc=0"
has S1-other-rc "$blk" "board-conformance(rc=1) old hub rc=2"
has S1-outside-window "$blk" "lib~2(rc=1) old hub rc unreadable: no run in the cron journal since @1699903600"
has S1-no-run "$blk" "other(rc=2) old hub rc unreadable: no run in the cron journal since @1699903600"
has S1-not-in-crontab "$blk" "gone(rc=1) old hub rc unreadable: not in the old hub crontab (render-cron.sh hub)"
check S1-no-journalctl "$(grep -c '^journalctl' "$VC")" 0
# S2: only lanes that fail on the old hub too: C1 passes and records them.
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\nregistry-export\t1\t1\t0\t0\nlib\t1\t1\t0\t0\n' > "$H/state/hub-move/tick-s.tsv"
out=$(hm cutover --step C1 --confirm 2>&1); check S2-rc "$?" 0
has S2-same "$out" "same-on-old-hub: registry-export(rc=1) lib(rc=1)"
st=$(awk -F'\t' '$2=="C1"{v=$3"|"$4} END{print v}' "$H/state/hub-move/steps.tsv")
has S2-steps-ok "$st" "ok|"
has S2-steps-same "$st" "same_on_old_hub=registry-export(rc=1),lib(rc=1)"
# S3: the journal cannot be read: the failure stays and C1 says why.
mv "$C/cron-journal" "$C/cron-journal.saved"
out=$(hm cutover --step C1 --confirm 2>&1); check S3-rc "$?" 4
has S3-why "$out" "registry-export(rc=1) old hub rc unreadable: cannot read the cron journal file $C/cron-journal"
# S4: the allow-list still overrides; the journal covers the rest.
mv "$C/cron-journal.saved" "$C/cron-journal"
printf 'fleet-slo\t1\t1\t0\t0\n' >> "$H/state/hub-move/tick-s.tsv"
out=$(HUB_MOVE_C1_ALLOW=fleet-slo hm cutover --step C1 --confirm 2>&1); check S4-rc "$?" 0
has S4-allowed "$out" "allowed failures: fleet-slo(rc=1)"
has S4-same "$out" "same-on-old-hub: registry-export(rc=1) lib(rc=1)"
# S5: the default source is journalctl -t CRON from the window start.
unset HUB_MOVE_CRON_JOURNAL; export JOURNAL_FIXTURE="$C/cron-journal"
out=$(HUB_MOVE_C1_ALLOW=fleet-slo hm cutover --step C1 --confirm 2>&1); check S5-rc "$?" 0
has S5-same "$out" "same-on-old-hub: registry-export(rc=1) lib(rc=1)"
jc=$(grep '^journalctl' "$VC")
has S5-tag "$jc" "-t CRON"
has S5-since "$jc" "--since @1699903600"
has S5-format "$jc" "-o short-unix"
# S6: journalctl fails: the failure stays.
export JOURNAL_FIXTURE="$C/nope"
out=$(hm cutover --step C1 --confirm 2>&1); check S6-rc "$?" 4
has S6-why "$out" "registry-export(rc=1) old hub rc unreadable: journalctl -t CRON failed (rc=1)"
# S7: a shorter window leaves the daily run outside it.
export HUB_MOVE_CRON_JOURNAL="$C/cron-journal"
sed -i '1s/.*/# mode=nowrite at=1699999950/' "$H/state/hub-move/tick-s.tsv"
out=$(HUB_MOVE_C1_OLD_WINDOW_S=60 hm cutover --step C1 --confirm 2>&1); check S7-rc "$?" 4
has S7-why "$out" "registry-export(rc=1) old hub rc unreadable: no run in the cron journal since @1699999890"
out=$(HUB_MOVE_C1_OLD_WINDOW_S=x hm cutover --step C1 --confirm 2>&1); check S7-bad-knob "$?" 2

# ==== T: dry-run fetches the stub table of a tick the before-guard stopped =======
newcase t; mkdir -p "$H/state/hub-move"; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
printf '{"provider":"hetzner","ts_ip":"192.0.2.55"}\n' > "$H/state/hub-move/target.json"
printf '# mode=nowrite at=1699990000\nlane\trc\tsecs\trefused\ttimed_out\nok-lane\t0\t1\t0\t0\n' > "$H/state/hub-move/tick-old.tsv"
touch -t 202001010000 "$H/state/hub-move/tick-old.tsv"
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
printf '* * * * * echo planted\n' > "$CRONTAB_FILE"
hm dry-run >"$C/out" 2>&1; check T1-dry-run-fails "$?" 4
check T1-no-lane "$(yn "$C/ran")" no
nf=$(ls -t "$H"/state/hub-move/tick-*.tsv | head -1)
check T1-stub-fetched "$(head -1 "$nf" | cut -d' ' -f2)" "mode=nowrite-crontab-found"
hm cutover --step C1 --confirm >"$C/out" 2>&1; check T1-c1-refuses "$?" 4
has T1-c1-says "$(cat "$C/out")" "is not a no-write tick"

# ==== E: a non-Fly target (Hetzner) ===============================================
newcase e; mkdir -p "$H/state/hub-move"; export BACKUP_AGE_IDENTITY_FILE="$C/age.key"
scratch_rm "$TGT/state/hub-move/target-seeded"
printf '{"provider":"hetzner","ts_ip":"192.0.2.55","ts_hostname":"bh-hub-2"}\n' > "$H/state/hub-move/target.json"
out=$(hm provision 2>&1); check E1-provision-refuses "$?" 3
has E1-says "$out" "provision is Fly-only"
hm seed 20261022T120000Z >"$C/out" 2>&1; check E2-seed-rc "$?" 0
check E2-target-all-off "$(yn "$TGT/flags/all-off")" yes
check E2-target-marked "$(yn "$TGT/state/hub-move/target-seeded")" yes
printf '* * * * * true\n' > "$C/cron.txt"
out=$(hm dry-run 2>&1); check E3-dry-run-rc "$?" 0
has E3-provision-skipped "$out" "provision skipped"
has E3-ticked "$out" "mode=nowrite"
check E3-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
out=$(hm dry-run --plan 2>&1); check E3-plan-rc "$?" 0
has E3-plan-skip "$out" "provision skipped"
printf 'x\tC4\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
touch "$H/flags/all-off"
hm cutover --step C5 --confirm >"$C/out" 2>&1; check E4-c5-rc "$?" 0
hm cutover --step C6 --confirm >"$C/out" 2>&1; check E4-c6-rc "$?" 0
check E4-c6-all-off-cleared "$(yn "$TGT/flags/all-off")" no
check E4-c6-mark-removed "$(yn "$TGT/state/hub-move/target-seeded")" no
has E4-c6-update-runners "$(cat "$CALLS")" "target:update-runners"
hm cutover --step C7 --confirm >/dev/null 2>&1; check E4-c7-rc "$?" 0
out=$(hm cutover --step C8 --confirm 2>&1); check E4-c8-rc "$?" 0
has E4-c8-provider "$out" "hetzner"
check E4-c8-standby "$(yn "$TGT/state/hub-move/cold-standby-until")" yes
printf '* * * * * /root/harness/bin/a.sh\n' > "$H/state/hub-move/old-crontab"
printf '#!/bin/bash\necho %s > %s/state/backup-last.json\n' "'{\"ts\":\"20261022T130000Z\"}'" "$TGT" > "$TGT/bin/state-backup.sh"
hm rollback --confirm >"$C/out" 2>&1; check E5-rollback-rc "$?" 0
check E5-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
# E6: C5 refuses while the target has no all-off (a seed that did not finish).
newcase e6; mkdir -p "$H/state/hub-move"
printf '{"provider":"hetzner","ts_ip":"192.0.2.55"}\n' > "$H/state/hub-move/target.json"
printf 'x\tC4\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
touch "$H/flags/all-off" "$TGT/flags/automerge-disabled"
hm cutover --step C5 --confirm >/dev/null 2>&1; check E6-c5-refuses "$?" 4
# E7: the same C5 passes once the target reads all-off.
touch "$TGT/flags/all-off"
hm cutover --step C5 --confirm >/dev/null 2>&1; check E7-c5-ok "$?" 0
# E9: update-runners installs the crontab and then fails. A C6 rerun must keep
# that crontab (the marker is gone, so its tick does not remove it).
newcase e9; mkdir -p "$H/state/hub-move"
printf '{"provider":"hetzner","ts_ip":"192.0.2.55"}\n' > "$H/state/hub-move/target.json"
printf 'x\tC5\tok\tfixture\n' > "$H/state/hub-move/steps.tsv"
printf '* * * * * true\n' > "$C/cron.txt"
printf '#!/bin/bash\nprintf "* * * * * echo new-hub\\n" > "$CRONTAB_FILE"\nexit 1\n' > "$TGT/bin/update-runners.sh"
hm cutover --step C6 --confirm >/dev/null 2>&1; check E9-c6-fails "$?" 4
check E9-mark-gone "$(yn "$TGT/state/hub-move/target-seeded")" no
printf '#!/bin/bash\nprintf "* * * * * echo new-hub\\n" > "$CRONTAB_FILE"\n' > "$TGT/bin/update-runners.sh"
hm cutover --step C6 --confirm >/dev/null 2>&1; check E9-c6-rerun-rc "$?" 0
check E9-crontab-kept "$(cat "$CRONTAB_FILE" 2>/dev/null)" "* * * * * echo new-hub"
check E9-no-all-off "$(yn "$TGT/flags/all-off")" no
# E8: an unknown provider refuses.
newcase e8; mkdir -p "$H/state/hub-move"
printf '{"provider":"orgo","ts_ip":"192.0.2.55"}\n' > "$H/state/hub-move/target.json"
hm dry-run >/dev/null 2>&1; check E8-unknown-provider "$?" 3

# ==== G: the sandbox guard refuses a crontab binary outside the scratch tree ====
# The guard's scratch root is ${TMPDIR}/scratch.??????. This case moves TMPDIR
# to $T/g-tmp and builds its trees in $T/g-tmp/scratch.gcase0, so every path
# passes the guard except $STUB/crontab, which is now outside the scratch root.
# Nothing is written outside $T. Every other case runs under the same guard
# (the runner sets HARNESS_TEST_SANDBOX=1) with the stub inside it.
newcase g-tmp/scratch.gcase0/c
printf '* * * * * echo lane >> %s/ran\n' "$C" > "$C/cron.txt"
out=$(TMPDIR="$T/g-tmp" HARNESS_TEST_SANDBOX=1 HARNESS="$TGT" bash "$TGT/bin/hub-move.sh" tick 2>&1); check G1-rc "$?" 2
has G1-says "$out" "crontab=$STUB/crontab is outside the test scratch root"
check G1-no-lane "$(yn "$C/ran")" no
check G1-no-crontab-call "$(grep -c '^crontab' "$VC")" 0

echo "hub-move-tick-safety.bh-8038: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
