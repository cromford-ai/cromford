#!/bin/bash
# tests/state-backup-lowpri.bh-6173-test.sh — bin/state-backup.sh runs at idle
# priority, compresses with a cheap zstd level, and ships nothing when no input
# changed since the last shipped archive (BH-6173).
#
# Drives the REAL bin/state-backup.sh (the cron entry point) against a scratch
# harness root and a directory-backed fake bucket. argv-recording stubs for
# nice, ionice and zstd write every call to $T/argv.log, then run the command.
#   S1  the archive tar runs under `nice -n 19 ionice -c3 -t`; zstd gets
#       `-<BACKUP_ZSTD_LEVEL> -T1` (default 1, a bad level says so and uses 1);
#       the object still lists back; no ionice on PATH means nice only.
#   S2  an unchanged-input run puts nothing, writes ONE skip line and moves
#       only .ts in the stamp; one changed input ships; the lane's own outputs,
#       state/scratch/ and the gate caches do not count as changes.
#   S3  the edges that ship anyway: BACKUP_FORCE=1, BACKUP_SKIP_UNCHANGED=0,
#       a legacy stamp, the BACKUP_FORCE_HOURS window, a future stamp, a last
#       object that is gone or the wrong size.
#   S4  bin/box-ops.sh backup_now forces an upload; the four knobs are
#       registered in catalog/lanes.d/state-backup.json.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

N1=1789514400             # 2026-09-15T23:20:00Z
TS1=20260915T232000Z
K1="small/$TS1.tar.zst"

REALZSTD=$(command -v zstd 2>/dev/null || true)
mkdir -p "$T/fakebin"
if ! command -v age >/dev/null 2>&1; then
  printf '#!/bin/bash\nif [ "${1:-}" = "-d" ]; then exec base64 -d; fi\nexec base64\n' > "$T/fakebin/age"
  chmod +x "$T/fakebin/age"
fi
if ! command -v age-keygen >/dev/null 2>&1; then
  cat > "$T/fakebin/age-keygen" <<'SH'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "$OUT" ] && printf 'stand-in-key-material-not-a-real-identity\n' > "$OUT"
printf 'Public key: age1standin-recipient-not-a-real-key\n' >&2
SH
  chmod +x "$T/fakebin/age-keygen"
fi
# argv recorders. nice and ionice drop their own options and exec the rest.
cat > "$T/fakebin/nice" <<SH
#!/bin/bash
printf 'nice %s\n' "\$*" >> "$T/argv.log"
[ "\${1:-}" = -n ] && shift 2
exec "\$@"
SH
cat > "$T/fakebin/ionice" <<SH
#!/bin/bash
printf 'ionice %s\n' "\$*" >> "$T/argv.log"
while [ \$# -gt 0 ]; do
  case "\$1" in
    -c|-n) shift 2 ;;
    -c*|-n*|-t) shift ;;
    *) break ;;
  esac
done
exec "\$@"
SH
cat > "$T/fakebin/zstd" <<SH
#!/bin/bash
printf 'zstd %s\n' "\$*" >> "$T/argv.log"
if [ -n "$REALZSTD" ]; then exec "$REALZSTD" "\$@"; fi
exec cat
SH
# A fixed crontab, so the meta input does not move under the suite.
printf '#!/bin/bash\nprintf "5 * * * * fixture-cron-line\\n"\n' > "$T/fakebin/crontab"
cat > "$T/fakebin/aws" <<SH
#!/bin/bash
# aws s3api over a directory tree. Every call lands in calls.log as
# "<verb> <key>". \$S3ROOT/fail-head holds a key whose head-object fails.
S3ROOT="$T/s3"
mkdir -p "\$S3ROOT"
VERB=""
if [ "\${1:-}" = s3api ]; then VERB="\${2:-}"; shift 2; fi
BUCKET=""; KEY=""; BODY=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --bucket) BUCKET="\${2:-}"; shift 2 ;;
    --key)    KEY="\${2:-}"; shift 2 ;;
    --body)   BODY="\${2:-}"; shift 2 ;;
    --endpoint-url|--output|--region|--prefix|--metadata|--delete) shift 2 ;;
    *)        shift ;;
  esac
done
printf '%s %s\n' "\$VERB" "\$KEY" >> "\$S3ROOT/calls.log"
case "\$VERB" in
  put-object)
    mkdir -p "\$(dirname "\$S3ROOT/\$BUCKET/\$KEY")"
    cp "\$BODY" "\$S3ROOT/\$BUCKET/\$KEY" || exit 253
    printf '{"ETag":"stub"}\n' ;;
  head-object)
    [ -f "\$S3ROOT/fail-head" ] && [ "\$(cat "\$S3ROOT/fail-head")" = "\$KEY" ] && exit 254
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    printf '{"ContentLength":%s}\n' "\$(stat -c%s "\$S3ROOT/\$BUCKET/\$KEY")" ;;
  list-objects-v2) printf '{"Contents":[]}\n' ;;
  *) exit 252 ;;
esac
SH
chmod +x "$T/fakebin/"*

AGEPUB=$(PATH="$T/fakebin:$PATH" age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
[ -n "$AGEPUB" ] && ok || bad "setup: age-keygen gave no public key"

H="$T/h"
mkfix() { # a fresh harness root and an empty bucket
  scratch_rm "$H"; scratch_rm "$T/s3"; scratch_rm "$T/realenv"
  mkdir -p "$H/env" "$H/state/quota" "$H/state/scratch" "$H/logs" "$H/flags" "$T/s3"
  {
    printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
    printf 'BACKUP_S3_BUCKET=bkt\n'
    printf 'BACKUP_S3_ACCESS_KEY_ID=akid-fixture-6173\n'
    printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-fixture-6173\n'
    printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
  } > "$H/env/global.env"
  printf 'small\n' > "$H/state/box-id"
  printf '{"a":1}\n' > "$H/state/quota/a.json"
  printf 'one line\n' > "$H/logs/other.log"
  : > "$H/logs/ALERTS.log"
}
# bk <now> [VAR=value ...] — one cron run; RC is the exit status.
bk() {
  local now="$1"; shift
  : > "$T/argv.log"
  env PATH="${BK_PATH:-$T/fakebin:$PATH}" HARNESS="$H" HARNESS_ROOT="$H" \
      HARNESS_CHECKOUT="$T/no-checkout" ORCHESTRATOR_DIR="$T/no-orch" \
      BACKUP_NOW="$now" "$@" bash "$DIR/bin/state-backup.sh" > "$T/run.out" 2>&1
  RC=$?
}
ts_of() { date -u -d "@$1" +%Y%m%dT%H%M%SZ; }
objs()  { find "$T/s3/bkt" -type f 2>/dev/null | wc -l; }
sj()    { jq -r "$1" "$H/state/backup-last.json" 2>/dev/null; }
loglines() { wc -l < "$H/logs/state-backup.log" 2>/dev/null || echo 0; }
# shipped <case> <now> — the run put a new object under its own key and
# stamped it as the shipped one.
shipped() {
  local k; k="small/$(ts_of "$2").tar.zst"
  [ "$RC" -eq 0 ] && [ -f "$T/s3/bkt/$k" ] && [ "$(sj .key)" = "$k" ] && [ "$(sj .shipped)" = "$(ts_of "$2")" ] \
    && ok || bad "$1: expected a shipped object at $k (rc=$RC key=$(sj .key) shipped=$(sj .shipped)): $(tail -2 "$H/logs/state-backup.log" 2>/dev/null)"
}
# skipped <case> <now> — nothing new in the bucket, the stamp still names K1,
# and .ts moved to this run.
skipped() {
  local n; n=$(objs)
  [ "$RC" -eq 0 ] && [ "$n" -eq 1 ] && [ "$(sj .key)" = "$K1" ] && [ "$(sj .ts)" = "$(ts_of "$2")" ] \
    && ok || bad "$1: expected a skip (rc=$RC objects=$n key=$(sj .key) ts=$(sj .ts)): $(tail -2 "$H/logs/state-backup.log" 2>/dev/null)"
}

# ── S1 priority and zstd level ───────────────────────────────────────────────
mkfix; bk "$N1"
[ "$RC" -eq 0 ] && ok || bad "S1: the default run exited $RC ($(tail -3 "$T/run.out"))"
ARCH=$(grep -E '^nice ' "$T/argv.log" | grep -F 'backup.tar.zst' | grep -E -- '-cf ' | head -1)
if [ -n "$ARCH" ] && grep -qE '^nice -n 19 ionice -c3 -t tar ' <<<"$ARCH"; then ok
else bad "S1a: the archive tar did not run under nice -n 19 ionice -c3 -t: '${ARCH:-<no nice line names backup.tar.zst>}'"; fi
grep -qx 'zstd -1 -T1' "$T/argv.log" && ok || bad "S1b: no 'zstd -1 -T1' call: $(grep '^zstd' "$T/argv.log" | tr '\n' '|')"
for f in 'find ' 'sha256sum ' 'age ' 'tar -cf - '; do
  grep -qE "^nice -n 19 ionice -c3 -t $f" "$T/argv.log" && ok || bad "S1g: '$f' does not run at idle priority"
done
ENTRIES=$(tar -I "$T/fakebin/zstd -d" -tf "$T/s3/bkt/$K1" 2>/dev/null)
grep -qx 'env.tar.age' <<<"$ENTRIES" && grep -qx 'state/box-id' <<<"$ENTRIES" \
  && ok || bad "S1e: the object does not list back with env.tar.age and state/box-id"

mkfix; bk "$N1" BACKUP_ZSTD_LEVEL=3
grep -qx 'zstd -3 -T1' "$T/argv.log" && ok || bad "S1c: BACKUP_ZSTD_LEVEL=3 gave no 'zstd -3 -T1' call"
for lv in abc 0 20; do
  mkfix; bk "$N1" BACKUP_ZSTD_LEVEL="$lv"
  { grep -qx 'zstd -1 -T1' "$T/argv.log" \
    && grep -q 'BACKUP_ZSTD_LEVEL is not 1-19 - using 1' "$H/logs/state-backup.log" 2>/dev/null; } \
    && ok || bad "S1d: BACKUP_ZSTD_LEVEL=$lv did not fall back to 1 with a log line"
done
mkfix; bk "$N1" BACKUP_FORCE_HOURS=abc
grep -q 'BACKUP_FORCE_HOURS is not a positive number - using 24' "$H/logs/state-backup.log" 2>/dev/null \
  && ok || bad "S1h: a bad BACKUP_FORCE_HOURS is not said out loud"
mkfix; bk "$N1" BACKUP_SKIP_UNCHANGED=off
grep -q 'BACKUP_SKIP_UNCHANGED is not 0 or 1 - using 1' "$H/logs/state-backup.log" 2>/dev/null \
  && ok || bad "S1i: a bad BACKUP_SKIP_UNCHANGED is not said out loud"

# No ionice on PATH: nice alone, one log line, and the backup still ships.
mkdir -p "$T/noion"
for d in /usr/local/bin /usr/bin /bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}
    [ "$b" = ionice ] && continue
    [ -e "$T/noion/$b" ] || ln -s "$f" "$T/noion/$b"
  done
done
# Swap in a stub only where fakebin has one. age and age-keygen get a stub only
# on a box without them; on a box with the real binaries (production) the real
# links stay, or the run stops with "missing: age" (lead review lr-6195).
for f in nice zstd crontab aws age age-keygen; do
  [ -e "$T/fakebin/$f" ] || continue
  rm -f "$T/noion/$f"; ln -s "$T/fakebin/$f" "$T/noion/$f"
done
mkfix; BK_PATH="$T/noion" bk "$N1"
{ [ "$RC" -eq 0 ] && grep -q 'ionice not found - running at nice 19 only' "$H/logs/state-backup.log" \
  && grep -qE '^nice -n 19 tar .*backup\.tar\.zst' "$T/argv.log"; } \
  && ok || bad "S1f: with no ionice the run is not nice-only with a log line (rc=$RC)"

# ── S2 skip unchanged inputs ─────────────────────────────────────────────────
N2=$((N1 + 900)); N3=$((N1 + 1800))
mkfix; bk "$N1"
[ "$RC" -eq 0 ] && [ "$(objs)" -eq 1 ] && ok || bad "S2a: run 1 did not ship (rc=$RC)"
R1KEY=$(sj .key); R1B=$(sj .bytes); R1S=$(sj .sha256); R1SH=$(sj .shipped); R1M=$(sj .manifest)
L0=$(loglines); A0=$(grep -c '\[state-backup\]' "$H/logs/ALERTS.log"); : > "$T/s3/calls.log"
bk "$N2"
skipped S2a "$N2"
[ "$(sj .bytes)" = "$R1B" ] && [ "$(sj .sha256)" = "$R1S" ] && [ "$(sj .shipped)" = "$R1SH" ] && [ "$R1SH" = "$TS1" ] \
  && [ "$R1KEY" = "$K1" ] && ok || bad "S2a: the skip changed a stamp field other than .ts: $(cat "$H/state/backup-last.json")"
grep -q '^put-object' "$T/s3/calls.log" && bad "S2a: the skip run called put-object" || ok
[ "$(grep -c "^head-object $K1\$" "$T/s3/calls.log")" -eq 1 ] && ok || bad "S2a: expected one head-object of $K1: $(tr '\n' '|' < "$T/s3/calls.log")"
NEW=$(tail -n +"$((L0 + 1))" "$H/logs/state-backup.log")
[ "$(grep -c . <<<"$NEW")" -eq 1 ] \
  && grep -qE "\[state-backup\] skip: inputs unchanged since $TS1 \($K1\) - shipped nothing\$" <<<"$NEW" \
  && ok || bad "S2a: expected exactly one skip line, got: $NEW"
[ "$(grep -c '\[state-backup\]' "$H/logs/ALERTS.log")" -eq "$A0" ] && ok || bad "S2a: the skip wrote an ALERTS line"
compgen -G "$H/tmp/state-backup.*" >/dev/null && bad "S2a: the skip left a staging dir" || ok
FACT=$( . "$DIR/bin/lib/backup-freshness.sh" && bf_facts_local "$H" | cut -f1 )
[ "$FACT" = "$(ts_of "$N2")" ] && ok || bad "S2a: bf_facts_local reads ts '$FACT' after a skip, want $(ts_of "$N2")"
printf 'x' >> "$H/state/quota/a.json"
bk "$N3"
shipped S2b "$N3"
[ "$(objs)" -eq 2 ] && [ "$(sj .manifest)" != "$R1M" ] && ok || bad "S2b: one changed file did not make a second object with a new manifest"

# The lane's own outputs, state/scratch/ and the gate caches are not inputs.
mkfix; bk "$N1"
printf 'more\n' >> "$H/logs/state-backup.log"; touch -d '@1789000000' "$H/state/backup-last.json"
printf 'new scratch\n' > "$H/state/scratch/oneoff.sh"
mkdir -p "$H/state/lane-gate"; printf '{"v":0}\n' > "$H/state/lane-gate/other-lane.json"
printf '{"rows":[]}\n' > "$H/state/settings-cache.json"
mkdir -p "$H/state/flags-cache"; printf '0\n' > "$H/state/flags-cache/x"
bk "$N2"; skipped "S2c/S2d" "$N2"

mkfix; bk "$N1"; printf 'NEW_KEY=fixture-value-longer\n' >> "$H/env/global.env"; bk "$N2"; shipped S2e "$N2"
# env/ as a symlink to the real dir (the /etc/harness/env compat shape).
mkfix; mv "$H/env" "$T/realenv"; ln -s "$T/realenv" "$H/env"
bk "$N1"; bk "$N2"; skipped "S2e-symlink-unchanged" "$N2"
printf 'X=fixture\n' > "$T/realenv/extra.env"; bk "$N3"; shipped "S2e-symlink" "$N3"
mkfix; bk "$N1"; printf '1\n' > "$H/flags/some-flag"; bk "$N2"; shipped "S2f-add" "$N2"
rm -f "$H/flags/some-flag"; bk "$N3"; shipped "S2f-remove" "$N3"

# ── S3 the edges that ship anyway ────────────────────────────────────────────
mkfix; bk "$N1"; bk "$N2" BACKUP_FORCE=1; shipped S3a "$N2"
mkfix; bk "$N1"; bk "$N2" BACKUP_SKIP_UNCHANGED=0; shipped S3b "$N2"
mkfix; bk "$N1"
printf '{"ts":"%s","key":"%s","bytes":%s,"sha256":"%s"}\n' "$TS1" "$K1" "$(sj .bytes)" "$(sj .sha256)" > "$H/state/backup-last.json"
bk "$N2"; shipped "S3c-legacy" "$N2"
mkfix; bk "$N1"; bk "$((N1 + 86400))"; shipped "S3d-24h" "$((N1 + 86400))"
mkfix; bk "$N1"; bk "$((N1 + 86399))"; skipped "S3d-24h-minus-1s" "$((N1 + 86399))"
mkfix; bk "$N1"; bk "$((N1 + 7200))" BACKUP_FORCE_HOURS=2; shipped "S3d-knob" "$((N1 + 7200))"
mkfix; bk "$N1"; bk "$((N1 - 3600))"; shipped "S3e-future" "$((N1 - 3600))"
mkfix; bk "$N1"; printf '%s' "$K1" > "$T/s3/fail-head"; bk "$N2"; shipped "S3f-head-fails" "$N2"
grep -q "skip refused: $K1 did not verify - shipping" "$H/logs/state-backup.log" \
  && ok || bad "S3f: no 'skip refused' line when head-object of the last key fails"
grep -q 'skip: inputs unchanged' "$H/logs/state-backup.log" && bad "S3f: a skip line was written for an unverified key" || ok
mkfix; bk "$N1"; rm -f "$T/s3/bkt/$K1"; bk "$N2"; shipped "S3f-object-gone" "$N2"
mkfix; bk "$N1"; jq -c '.bytes = 7' "$H/state/backup-last.json" > "$T/stamp" && mv "$T/stamp" "$H/state/backup-last.json"
bk "$N2"; shipped "S3g-size" "$N2"
mkfix; bk "$N1"; jq -c '.shipped = "garbage"' "$H/state/backup-last.json" > "$T/stamp" && mv "$T/stamp" "$H/state/backup-last.json"
bk "$N2"; shipped "S3h-unparseable-shipped" "$N2"

# ── S4 box-ops forces; the knobs are registered ──────────────────────────────
[ "$(grep -cE 'BACKUP_FORCE=1 +timeout .*state-backup\.sh' "$DIR/bin/box-ops.sh")" -eq 1 ] \
  && ok || bad "S4: bin/box-ops.sh backup_now does not run state-backup.sh with BACKUP_FORCE=1"
J="$DIR/catalog/lanes.d/state-backup.json"
kv() { jq -r --arg e "$1" ".knobs[] | select(.env == \$e) | $2" "$J" 2>/dev/null; }
[ "$(kv BACKUP_ZSTD_LEVEL .default)" = 1 ] && ok || bad "S4b: BACKUP_ZSTD_LEVEL default is not 1"
[ "$(kv BACKUP_SKIP_UNCHANGED .default)" = 1 ] && ok || bad "S4b: BACKUP_SKIP_UNCHANGED default is not 1"
[ "$(kv BACKUP_FORCE_HOURS .default)" = 24 ] && ok || bad "S4b: BACKUP_FORCE_HOURS default is not 24"
[ "$(kv BACKUP_FORCE .settable)" = false ] && ok || bad "S4b: BACKUP_FORCE is not settable:false"

echo "state-backup-lowpri: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
