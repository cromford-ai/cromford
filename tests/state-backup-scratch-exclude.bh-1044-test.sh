#!/bin/bash
# tests/state-backup-scratch-exclude.bh-1044-test.sh — state/scratch/ is operator
# scratch, and operator scratch does not ride into the off-box copy (#1044).
#
# bin/disk-clean.sh stage 6 moves state/*.sh, *.done and *.bak-* under
# state/scratch/. That directory is the one part of state/ a restore does not
# want back — it is the ~40 hand-run one-offs and 25 .bak copies the 2026-09-19
# audit found loose in state/ on the hub. This suite drives bin/state-backup.sh
# (the production entry point, as cron drives it) against a scratch harness root
# and a fake bucket, and asserts on the object that really landed:
#   X1  nothing under state/scratch/ is in the tarball;
#   X2  the rest of state/ still is, and the upload path still stamps
#       state/backup-last.json — the exclusion did not cost the backup.
# The bh-447 suite owns everything else about this lane.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1789514400            # 2026-09-15T23:20:00Z
KEY="small/20260915T232000Z.tar.zst"

mkdir -p "$T/fakebin"
# The real binaries when the box has them (CI installs age and zstd), stand-ins
# when it does not. The recipient is generated either way: handing the REAL age
# a made-up recipient fails the encrypt stage, and this suite would then be red
# on CI for a reason that has nothing to do with what it proves.
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
if ! command -v zstd >/dev/null 2>&1; then
  printf '#!/bin/bash\nexec cat\n' > "$T/fakebin/zstd"; chmod +x "$T/fakebin/zstd"
fi
cat > "$T/fakebin/aws" <<SH
#!/bin/bash
# aws s3api over a directory tree: put-object copies the body in, head-object
# reports its size, list-objects-v2 answers empty so the prune is a no-op.
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
    --*)      shift ;;
    *)        shift ;;
  esac
done
case "\$VERB" in
  put-object)
    mkdir -p "\$(dirname "\$S3ROOT/\$BUCKET/\$KEY")"
    cp "\$BODY" "\$S3ROOT/\$BUCKET/\$KEY" || exit 253
    printf '{"ETag":"stub"}\n' ;;
  head-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    printf '{"ContentLength":%s}\n' "\$(stat -c%s "\$S3ROOT/\$BUCKET/\$KEY")" ;;
  list-objects-v2) printf '{"Contents":[]}\n' ;;
  *) exit 252 ;;
esac
SH
chmod +x "$T/fakebin/aws"

AGEPUB=$(PATH="$T/fakebin:$PATH" age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
[ -n "$AGEPUB" ] && ok || bad "setup: age-keygen gave no public key"

mkdir -p "$T/h/env" "$T/h/state/scratch" "$T/h/logs" "$T/h/flags" "$T/s3"
{
  printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
  printf 'BACKUP_S3_BUCKET=bkt\n'
  printf 'BACKUP_S3_ACCESS_KEY_ID=akid-1044\n'
  printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-1044\n'
  printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
} > "$T/h/env/global.env"
printf 'small\n' > "$T/h/state/box-id"
printf 'one-off nobody needs back\n' > "$T/h/state/scratch/oneoff.sh"
printf 'a marker\n' > "$T/h/state/scratch/backfill.done"

env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/no-checkout" \
    ORCHESTRATOR_DIR="$T/no-orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW" \
    bash "$DIR/bin/state-backup.sh" > "$T/run.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "X1: the backup run exited $RC ($(tail -3 "$T/run.out"))"
OBJ="$T/s3/bkt/$KEY"
[ -f "$OBJ" ] && ok || bad "X1: nothing landed at $KEY"

ENTRIES=$(PATH="$T/fakebin:$PATH" tar --zstd -tf "$OBJ" 2>/dev/null)
grep -qE '^state/scratch(/|$)' <<<"$(printf '%s\n' "$ENTRIES")" \
  && bad "X1: operator scratch rode into the off-box copy: $(printf '%s\n' "$ENTRIES" | grep -E '^state/scratch')" \
  || ok
grep -qx 'state/box-id' <<<"$ENTRIES" \
  && ok || bad "X2: the exclusion took state/box-id with it: $(head -20 <<<"$ENTRIES")"
grep -qx 'env.tar.age' <<<"$ENTRIES" \
  && ok || bad "X2: the encrypted env tar is missing from the object"
[ -f "$T/h/state/backup-last.json" ] \
  && ok || bad "X2: the upload path no longer stamps state/backup-last.json"
[ -e "$T/h/state/scratch/oneoff.sh" ] \
  && ok || bad "X2: the backup deleted the scratch file instead of skipping it"

echo "state-backup-scratch-exclude: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
