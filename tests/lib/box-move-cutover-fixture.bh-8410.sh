#!/bin/bash
# tests/lib/box-move-cutover-fixture.bh-8410.sh — the shared fixture of the
# bin/box-move.sh cutover and rollback suites (BH-8410). Sourced after
# tests/lib/scratch.sh, with REPO set to the checkout. Never executed.
#
# It sources the C0 fixture (tests/lib/box-move-fixture.bh-8322.sh) and adds,
# per case (bmc_newcase <name>):
#   - a hub bin/registry.sh stub (the registry seam's fake). It records argv in
#     $CALLS as `registry <argv>` and edits the case's fixture fleet.conf, so
#     bin/fleet-conf.sh reads the change back: move-project rewrites cols 6/7
#     of the project row, add-box adds `# @box` and `# @boxrole` lines (and,
#     like the real route, answers 409 when the box exists with any other
#     ip, id or role), set-box-role rewrites the `@boxrole` line. A file $C/reg-fail-once-<p>
#     fails the next move-project of <p> once (rc 1).
#   - REGISTRY_SOURCE=db with REGISTRY_ADMIN_TOKEN and HARNESS_SECRET set to
#     fixture values, and JOBS_URL empty: fleet-conf.sh then reads the case's
#     FLEET_CONF (the registry is "not configured"), so 0 network calls.
#   - on the OLD box: the bin/hub-move.sh closure (drain) and jobs-client.sh
#     (flags), and a bin/state-backup.sh stub that writes a new
#     state/backup-last.json ts unless $C/backup-stuck exists.
#   - on the NEW box: a bin/update-runners.sh stub that installs a fixture
#     crontab through the crontab stub and records whether the
#     state/hub-move/target-seeded marker was still there.
#   - a rendered crontab of harmless lanes (tick --real runs them for real).
#
# bmc_tick_table [<line1>] [<rows>] writes a no-write tick table into the hub
# copy dir (state/box-move/<newbox>/tick-20261026T000000Z.tsv), in the format
# of bin/hub-move.sh cmd_tick.
. "$(dirname "${BASH_SOURCE[0]}")/box-move-fixture.bh-8322.sh" || return 1

BMC_ADMIN_TOKEN=reg-admin-fixture-token-8410

bmc_newcase() {
  bm_newcase "$1"
  scratch_install_closure bin/hub-move.sh "$OLD" >/dev/null || bad "$1: hub-move closure into old"
  # scratch-closure-allow: bin/lib/flags.sh loads bin/jobs-client.sh and its bin/lib/jobs modules at run time, which the closure scan cannot follow
  mkdir -p "$OLD/bin/lib/jobs" && cp "$REPO/bin/jobs-client.sh" "$OLD/bin/" && cp "$REPO"/bin/lib/jobs/*.sh "$OLD/bin/lib/jobs/" \
    || bad "$1: jobs-client into old"
  export REGISTRY_SOURCE=db REGISTRY_ADMIN_TOKEN="$BMC_ADMIN_TOKEN" HARNESS_SECRET=fixture-secret JOBS_URL=""
  unset BOX_MOVE_DRAIN_TIMEOUT_S BOX_MOVE_TICK_MAX_AGE_S BOX_MOVE_B1_ALLOW RESTORE_BOX_ID
  cat > "$H/bin/registry.sh" <<'EOF'
#!/bin/bash
printf 'registry %s\n' "$*" >> "$CALLS"
verb="$1"; shift
name="$1"; shift
ip=""; id=""; role=""; box=""; arg2=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ip) ip="$2"; shift 2 ;; --id) id="$2"; shift 2 ;; --role) role="$2"; shift 2 ;;
    --box) box="$2"; shift 2 ;; --like|--actor) shift 2 ;;
    *) arg2="$1"; shift ;;
  esac
done
f="$FLEET_CONF"
case "$verb" in
  add-box)
    # As worker/jobs/src/routes/registry-write.js POST /api/registry/boxes: an
    # existing box with any other field (ip, id, role) is a 409.
    if grep -q "^# @box $name " "$f"; then
      hip=$(awk -v b="$name" '$1 == "#" && $2 == "@box" && $3 == b {print $4; exit}' "$f")
      hrl=$(awk -v b="$name" '$1 == "#" && $2 == "@boxrole" && $3 == b {print $4 " " $5; exit}' "$f")
      want=""; [ -z "$role" ] || want="$id $role"
      if [ "$hip" != "$ip" ] || [ "$hrl" != "$want" ]; then
        echo "registry: add-box $name: HTTP 409 box $name exists with different fields; PATCH it" >&2; exit 1
      fi
    else
      echo "# @box $name $ip" >> "$f"
      [ -z "$role" ] || echo "# @boxrole $name $id $role" >> "$f"
    fi ;;
  move-project)
    if [ -e "$(dirname "$f")/../reg-fail-once-$name" ]; then
      rm -f "$(dirname "$f")/../reg-fail-once-$name"
      echo "registry: move-project $name: HTTP 500 fixture failure" >&2; exit 1
    fi
    nip=$(awk -v b="$box" '$1 == "#" && $2 == "@box" && $3 == b {print $4; exit}' "$f")
    [ -n "$nip" ] || nip=$(awk -v b="$box" '!/^[[:space:]]*(#|$)/ && $6 == b {print $7; exit}' "$f")
    awk -v p="$name" -v b="$box" -v i="$nip" '!/^[[:space:]]*(#|$)/ && $1 == p {$6 = b; $7 = i} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  set-box-role)
    bid=$(awk -v b="$name" '$1 == "#" && $2 == "@boxrole" && $3 == b {print $4; exit}' "$f")
    awk -v b="$name" '!($1 == "#" && $2 == "@boxrole" && $3 == b)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "# @boxrole $name ${bid:-project-6-os} $arg2" >> "$f" ;;
  *) echo "registry stub: unknown verb $verb" >&2; exit 2 ;;
esac
echo "registry: $verb changed=1 version=2"
EOF
  chmod +x "$H/bin/registry.sh"
  cat > "$OLD/bin/state-backup.sh" <<'EOF'
#!/bin/bash
printf 'old:state-backup BACKUP_FORCE=%s\n' "${BACKUP_FORCE:-}" >> "$CALLS"
root="$(cd "$(dirname "$0")/.." && pwd)"
[ -e "$root/../backup-stuck" ] && exit 0
printf '{"ts":"20261026T010203Z","key":"project-6-os/20261026T010203Z.tar.zst"}\n' > "$root/state/backup-last.json"
EOF
  chmod +x "$OLD/bin/state-backup.sh"
  cat > "$NEW/bin/update-runners.sh" <<'EOF'
#!/bin/bash
root="$(cd "$(dirname "$0")/.." && pwd)"
m=absent; [ -e "$root/state/hub-move/target-seeded" ] && m=present
printf 'new:update-runners marker=%s\n' "$m" >> "$CALLS"
t=$(mktemp) && printf '* * * * * /root/harness/bin/a.sh\n*/5 * * * * /root/harness/bin/b.sh\n* * * * * /root/harness/bin/c.sh\n' > "$t" && crontab "$t"; rc=$?
rm -f "$t"; exit "$rc"
EOF
  chmod +x "$NEW/bin/update-runners.sh"
  # tick --real runs the rendered lanes for real: harmless commands only.
  printf '* * * * * echo lane-a\n*/5 * * * * echo lane-b\n' > "$C/cron.txt"
}

bmc_tick_table() {
  local l1="${1:-# mode=nowrite at=$HUB_MOVE_NOW}" rows="${2:-}"
  mkdir -p "$H/state/box-move/$BM_NEW"
  {
    printf '%s\n' "$l1"
    printf '# reach ssh=0 flyctl=0 host=%s\n' "$BM_OLD_IP"
    printf 'lane\trc\tsecs\trefused\ttimed_out\n'
    printf 'harness-sync-deploy\t0\t1\t0\t0\n'
    if [ -n "$rows" ]; then printf '%b' "$rows"; else printf 'a\t0\t1\t0\t0\nb\t0\t1\t1\t0\n'; fi
  } > "$H/state/box-move/$BM_NEW/${3:-tick-20261026T000000Z.tsv}"
}

# cstep <args...> — bin/box-move.sh cutover <args> <oldbox> <newbox>.
cstep() { bm cutover "$@" "$BM_OLD" "$BM_NEW"; }
rb() { bm rollback "$@" "$BM_OLD" "$BM_NEW"; }
# bmc_steps — the steps.tsv rows of the case, `<step>:<status>` per line.
bmc_steps() { awk -F'\t' '{print $2":"$3}' "$H/state/box-move/$BM_NEW/steps.tsv" 2>/dev/null | tr '\n' ' '; }
bmc_status() { awk -F'\t' -v s="$1" '$2 == s {v = $3} END {print v}' "$H/state/box-move/$BM_NEW/steps.tsv" 2>/dev/null; }
# bmc_through <Bn> — the steps B1..<Bn> --confirm, each asserted rc 0.
bmc_through() {
  local s n="${1#B}" i
  for i in $(seq 1 "$n"); do
    s="B$i"
    cstep --step "$s" --confirm >"$C/out-$s" 2>&1 || bad "$C: setup $s rc=$? $(tail -3 "$C/out-$s")"
  done
}
bmc_active() { grep -cvE '^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null; }
bmc_flag() { if [ -e "$1/flags/$2" ]; then echo on; else echo off; fi; }
