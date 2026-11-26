#!/bin/bash
# tests/state-backup-bundle-cache.bh-9889-test.sh — the hub's env bundle cache
# never leaves the box through the off-box backup (BH-9889 security review).
#
# bin/fly-envbundle.sh keeps a plaintext copy of each pool project's env
# bundle at state/bundle-cache/<project>.raw. bin/state-backup.sh tars state/
# to the bucket with no outer encryption, so that copy must stay behind. This
# suite drives bin/state-backup.sh (the production entry point, as cron drives
# it) against a scratch harness root and a fake bucket:
#   B1  no state/bundle-cache entry and no byte of the cached marker value is
#       in the object that landed; the rest of state/ still is;
#   B2  a change to the cache alone is not an input change: the next run
#       skips (the manifest prunes the cache, as the tar excludes it);
#   B3  the leak check is a second wall: a tar that ignores the exclusion
#       makes the run refuse with a leak-check alert, and nothing uploads.
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

MARK="bh9889-fixture-cache-marker-$$-not-a-real-token"
mkdir -p "$T/h/env" "$T/h/state/bundle-cache" "$T/h/logs" "$T/h/flags" "$T/s3"
{
  printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
  printf 'BACKUP_S3_BUCKET=bkt\n'
  printf 'BACKUP_S3_ACCESS_KEY_ID=akid-9889\n'
  printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-9889\n'
  printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
} > "$T/h/env/global.env"
printf 'small\n' > "$T/h/state/box-id"
chmod 700 "$T/h/state/bundle-cache"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s-fixture\n' "$MARK" > "$T/h/state/bundle-cache/proj.raw"
chmod 600 "$T/h/state/bundle-cache/proj.raw"

run_backup() { # run_backup <now> [extra PATH dir]
  env PATH="${2:+$2:}$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/no-checkout" \
      ORCHESTRATOR_DIR="$T/no-orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$1" \
      bash "$DIR/bin/state-backup.sh"
}

# ---- B1 ----------------------------------------------------------------------
run_backup "$NOW" > "$T/run1.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "B1: the backup run exited $RC ($(tail -3 "$T/run1.out"))"
OBJ="$T/s3/bkt/$KEY"
[ -f "$OBJ" ] && ok || bad "B1: nothing landed at $KEY"
ENTRIES=$(PATH="$T/fakebin:$PATH" tar --zstd -tf "$OBJ" 2>/dev/null)
grep -qE '^state/bundle-cache(/|$)' <<<"$ENTRIES" \
  && bad "B1: the bundle cache rode into the off-box copy: $(grep -E '^state/bundle-cache' <<<"$ENTRIES")" \
  || ok
grep -qx 'state/box-id' <<<"$ENTRIES" \
  && ok || bad "B1: the exclusion took state/box-id with it: $(head -20 <<<"$ENTRIES")"
mkdir -p "$T/x1"
PATH="$T/fakebin:$PATH" tar --zstd -xf "$OBJ" -C "$T/x1" 2>/dev/null
grep -rqF "$MARK" "$T/x1" \
  && bad "B1: the cached marker value is in the uploaded object" || ok
[ -f "$T/h/state/bundle-cache/proj.raw" ] \
  && ok || bad "B1: the backup removed the cache file instead of skipping it"

# ---- B2 ----------------------------------------------------------------------
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s-fixture-rotated\n' "$MARK" > "$T/h/state/bundle-cache/proj.raw"
touch -d '@'"$((NOW + 60))" "$T/h/state/bundle-cache/proj.raw"
run_backup "$((NOW + 900))" > "$T/run2.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "B2: the second run exited $RC ($(tail -3 "$T/run2.out"))"
grep -rq 'skip: inputs unchanged' "$T/run2.out" "$T/h/logs/state-backup.log" 2>/dev/null \
  && ok || bad "B2: a cache-only change shipped a new object ($(tail -3 "$T/h/logs/state-backup.log" 2>/dev/null))"

# ---- B3 ----------------------------------------------------------------------
# A tar that drops the bundle-cache exclusion: the leak check must refuse.
REALTAR=$(command -v tar)
mkdir -p "$T/leakbin"
cat > "$T/leakbin/tar" <<SH
#!/bin/bash
A=()
for a in "\$@"; do
  case "\$a" in --exclude=state/bundle-cache|--exclude=state/bundle-cache/\*) ;; *) A+=("\$a") ;; esac
done
exec "$REALTAR" "\${A[@]}"
SH
chmod +x "$T/leakbin/tar"
rm -rf "$T/s3/bkt"
: > "$T/h/logs/ALERTS.log"
run_backup "$((NOW + 1800))" "$T/leakbin" > "$T/run3.out" 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok || bad "B3: a tarball carrying the bundle cache was not refused (rc 0)"
grep -q 'leak-check' "$T/h/logs/ALERTS.log" \
  && ok || bad "B3: no leak-check alert ($(tail -2 "$T/h/logs/ALERTS.log"))"
grep -qF "$MARK" "$T/h/logs/ALERTS.log" "$T/run3.out" \
  && bad "B3: the alert or the run output printed the cached value" || ok
[ -z "$(find "$T/s3/bkt" -type f 2>/dev/null)" ] \
  && ok || bad "B3: an object uploaded despite the leak: $(find "$T/s3/bkt" -type f)"

echo "state-backup-bundle-cache: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
