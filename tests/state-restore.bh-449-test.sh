#!/bin/bash
# tests/state-restore.bh-449-test.sh — bin/state-restore.sh against a scratch
# harness root, a fake S3 (a directory tree behind an `aws s3api` stand-in), a
# frozen clock and the REAL bin/restore-merge.sh underneath it. Nothing here
# touches a real box, a real bucket or the real crontab.
#
# WHY THE SCRIPT EXISTS (#388, 2026-09-15; parent #396). The hub's
# /root/harness/{env,bin,prompts,logs,builds} vanished under a running system.
# bin/state-backup.sh (#447) is the uploader; bin/restore-merge.sh (#446) is the
# merge policy; bin/state-restore.sh is the operator's one command that joins
# them — list what is in the bucket, pull it, prove the sha256, extract it,
# decrypt env/ with an identity the box does not hold, print the meta, and hand
# the tree to restore-merge.
#
# What is proved here:
#   C1   nothing configured is a refusal with the missing key NAMES and ZERO
#        bucket calls; a missing bin/restore-merge.sh is rc 2 before any call;
#   R1   no ts lists `<ts>  <bytes>` for the box prefix only, sorted, ignoring
#        every key that is not <8 digits>T<6 digits>Z.tar.zst; an empty listing
#        is `no backups for <box>` and rc 1;
#   R1b  a truncated listing is followed to the end, so `latest` is the newest
#        key in the BUCKET, not the newest key on page one;
#   R1c  a neighbouring prefix (small-2/) is never read as this box's;
#   R2   the default is a DRY RUN: the object lands on disk under $H/tmp, the
#        sha256 is checked against the stored metadata, meta/ is printed, the
#        merge is reported and not one byte of the live tree changes;
#   R3   --apply with the right identity restores env/ AND merges the rest by
#        restore-merge's own rules (ledger, union, keep-live, cursor last),
#        prints no secret, never lands env.tar.age in the live tree, and a
#        second run changes nothing;
#   R4   no identity: env/ is skipped out loud, the rest still restores, rc 0;
#   R4b  wrong identity: env/ is refused, the rest still merges, rc 1 so the
#        operator notices;
#   R5   a tampered object is refused on the sha256 before anything is
#        extracted and before restore-merge is ever called; absent metadata is
#        refused by default, with an explicit manual legacy override (R5b);
#   R6   an existing destination is refused rather than overwritten, a --dest
#        inside --live is rc 2, and a box name outside [a-z0-9-] never reaches
#        the bucket;
#   R7   usage: no args, an unknown flag and a malformed ts are rc 2; --help is
#        rc 0 and makes no bucket call;
#   D1   docs/RESTORE.md carries the sections and literals #449 names, claims
#        nothing this repo has not built, and every relative link resolves.
# Run from anywhere: tests/state-restore.bh-449-test.sh   (exit 0 = all pass)
#
# AGE_REQUIRED=1 turns "the real age/zstd binaries are missing here" from a
# stand-in into a hard failure — CI sets it so the encryption path is proven
# against the real tools, dev boxes without them still get the routing proof.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1789514400            # 2026-09-15T23:20:00Z — the frozen clock for both lanes
TSNOW=20260915T232000Z    # the object bin/state-backup.sh uploads under it
TSOLD=20260915T231500Z    # a second, older object planted for the paging case
KEY="small/$TSNOW.tar.zst"
CANARY=leakcanary-4491    # stands in for every secret in env/; must never reach stdout
CRONLINE='*/15 * * * * /root/harness/bin/state-backup.sh'
HEADSHA=4d1f0c8a9b2e5f7c3a6d8b0e2f4a6c8d0e2f4a6b

mkdir -p "$T/fakebin"

# ── the tools: real when the box has them, stand-ins when it does not ────────
AGE_MODE=real
command -v age        >/dev/null 2>&1 || AGE_MODE=stand-in
command -v age-keygen >/dev/null 2>&1 || AGE_MODE=stand-in
command -v zstd       >/dev/null 2>&1 || AGE_MODE=stand-in
if [ "$AGE_MODE" = stand-in ] && [ "${AGE_REQUIRED:-0}" = 1 ]; then
  bad "AGE_REQUIRED=1 but one of age, age-keygen, zstd is missing - CI must prove the real encryption path, not a stand-in"
  echo "state-restore: $PASS passed, $FAIL failed"
  exit 1
fi
echo "age mode: $AGE_MODE"

if ! command -v age >/dev/null 2>&1; then
  cat > "$T/fakebin/age" <<'SH'
#!/bin/bash
# age stand-in: base64 in place of the cipher. `-r RECIPIENT` encrypts stdin,
# `-d -i KEYFILE [FILE]` decrypts. What this suite proves with it is the ROUTING
# (env/ leaves the box only through this pipe, and comes back only through it);
# CI runs the same file with the real binary under AGE_REQUIRED=1.
# >>> bh-449: the stand-in checks the identity, so "wrong key" is a real red
# here and not only under the real binary. Real age refuses a garbage identity
# file with rc 1 for the same reason.
if [ "${1:-}" = "-d" ]; then
  shift
  ID=""; FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -i) ID="${2:-}"; shift 2 ;;
      -*) shift ;;
      *)  FILE="$1"; shift ;;
    esac
  done
  if [ -n "$ID" ] && ! grep -qx 'stand-in-key-material-not-a-real-identity' "$ID" 2>/dev/null; then
    echo "age: no identity matched any of the recipients" >&2
    exit 1
  fi
  if [ -n "$FILE" ]; then exec base64 -d -- "$FILE"; fi
  exec base64 -d
fi
# <<< bh-449
exec base64
SH
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
  # tar --zstd execs `zstd` to compress and `zstd -d` to read back; cat is both.
  printf '#!/bin/bash\nexec cat\n' > "$T/fakebin/zstd"
  chmod +x "$T/fakebin/zstd"
fi

cat > "$T/fakebin/crontab" <<SH
#!/bin/bash
printf '%s\n' '$CRONLINE'
SH
chmod +x "$T/fakebin/crontab"

cat > "$T/fakebin/git" <<SH
#!/bin/bash
for a in "\$@"; do
  [ "\$a" = rev-parse ] && { printf '%s\n' '$HEADSHA'; exit 0; }
done
exit 1
SH
chmod +x "$T/fakebin/git"

# ── the fake S3 ─────────────────────────────────────────────────────────────
# The block between the markers is tests/state-backup.bh-447-test.sh's, copied
# (that suite is neither sourced nor edited from here). The `# >>> bh-449`
# regions are this suite's only additions: a --continuation-token arm and a
# $S3ROOT/page-size knob, so the paging the real CLI does at 1000 keys can be
# exercised at 1.
cat > "$T/fakebin/aws" <<'SH'
#!/bin/bash
# >>> aws-stub
# `aws s3api` over a directory tree. Verbs: put-object, head-object,
# list-objects-v2, delete-objects, get-object. Objects are files at
# $S3ROOT/<bucket>/<key>, the sha256 handed to put-object is kept at
# $S3META/<bucket>/<key>, every argv is appended to $CALLS. Touch
# $S3ROOT/fail-put, $S3ROOT/fail-head or $S3ROOT/fail-list to make that verb
# fail the way the real CLI does: nonzero rc, nothing usable on stdout.
# Two more switches bend a verb that "succeeds" into the shapes that must never
# be read as a delivered backup: $S3ROOT/short-head makes head-object report one
# byte less than the object really is, $S3ROOT/blank-head makes it answer rc 0
# with no ContentLength at all, and $S3ROOT/fail-delete makes delete-objects
# answer rc 0 with a per-key Errors list and remove nothing.
S3ROOT="__S3ROOT__"
S3META="__S3META__"
CALLS="__CALLS__"
mkdir -p "$S3ROOT" "$S3META"
printf '%s\n' "$*" >> "$CALLS"
VERB=""
if [ "${1:-}" = s3api ]; then VERB="${2:-}"; shift 2; fi
BUCKET=""; KEY=""; BODY=""; PREFIX=""; META=""; DEL=""; OUTFILE=""
TOKEN=""                                          # >>> bh-449
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket)   BUCKET="${2:-}"; shift 2 ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --body)     BODY="${2:-}"; shift 2 ;;
    --prefix)   PREFIX="${2:-}"; shift 2 ;;
    --metadata) META="${2:-}"; shift 2 ;;
    --delete)   DEL="${2:-}"; shift 2 ;;
    --continuation-token) TOKEN="${2:-}"; shift 2 ;;    # >>> bh-449
    --endpoint-url|--output|--region) shift 2 ;;
    --*)        shift ;;
    *)          OUTFILE="$1"; shift ;;
  esac
done
case "$VERB" in
  put-object)
    [ -f "$S3ROOT/fail-put" ] && exit 255
    [ -f "$BODY" ] || exit 253
    mkdir -p "$(dirname "$S3ROOT/$BUCKET/$KEY")" "$(dirname "$S3META/$BUCKET/$KEY")"
    cp "$BODY" "$S3ROOT/$BUCKET/$KEY" || exit 253
    printf '%s\n' "${META#sha256=}" > "$S3META/$BUCKET/$KEY"
    printf '{"ETag":"stub"}\n'
    ;;
  head-object)
    [ -f "$S3ROOT/fail-head" ] && exit 254
    [ -f "$S3ROOT/$BUCKET/$KEY" ] || exit 254
    if [ -f "$S3ROOT/blank-head" ]; then
      printf '{"Metadata":{"sha256":"%s"}}\n' "$(cat "$S3META/$BUCKET/$KEY" 2>/dev/null)"
      exit 0
    fi
    SZ=$(stat -c%s "$S3ROOT/$BUCKET/$KEY")
    [ -f "$S3ROOT/short-head" ] && SZ=$((SZ - 1))
    printf '{"ContentLength":%s,"Metadata":{"sha256":"%s"}}\n' \
      "$SZ" "$(cat "$S3META/$BUCKET/$KEY" 2>/dev/null)"
    ;;
  list-objects-v2)
    [ -f "$S3ROOT/fail-list" ] && exit 255
    [ -d "$S3ROOT/$BUCKET" ] || { printf '{"Contents":[]}\n'; exit 0; }
    # >>> bh-449: page the listing when $S3ROOT/page-size holds N. The real CLI
    # caps a page at 1000 keys, answers them in lexicographic order and hands
    # back IsTruncated + NextContinuationToken; a caller that reads page one
    # only would call the OLDEST key the newest on any box past that cap.
    find "$S3ROOT/$BUCKET" -type f -printf '%s\t%P\n' \
      | awk -F'\t' -v p="$PREFIX" 'p == "" || index($2, p) == 1' \
      | LC_ALL=C sort -k2 > "$S3ROOT/.page-all"
    PS=$(cat "$S3ROOT/page-size" 2>/dev/null)
    case "$PS" in ''|*[!0-9]*) PS="" ;; esac
    if [ -n "$PS" ]; then
      awk -F'\t' -v tok="$TOKEN" 'tok == "" || $2 > tok' "$S3ROOT/.page-all" > "$S3ROOT/.page-rest"
      head -n "$PS" "$S3ROOT/.page-rest" > "$S3ROOT/.page-cur"
      if [ "$(wc -l < "$S3ROOT/.page-rest")" -gt "$(wc -l < "$S3ROOT/.page-cur")" ]; then
        NEXT=$(awk -F'\t' 'END { print $2 }' "$S3ROOT/.page-cur")
        jq -R -n -c --arg n "$NEXT" \
          '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}], IsTruncated: true, NextContinuationToken: $n}' \
          < "$S3ROOT/.page-cur"
      else
        jq -R -n -c \
          '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}], IsTruncated: false}' \
          < "$S3ROOT/.page-cur"
      fi
      exit 0
    fi
    # <<< bh-449
    jq -R -n -c '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}]}' \
      < "$S3ROOT/.page-all"
    ;;
  delete-objects)
    printf '%s' "$DEL" | jq -r '.Objects[].Key' > "$S3ROOT/del-keys" || exit 253
    QUIET=$(printf '%s' "$DEL" | jq -r '.Quiet // false' 2>/dev/null)
    if [ -f "$S3ROOT/fail-delete" ]; then
      if [ "$QUIET" = true ]; then
        jq -R -n -c '{Errors: [inputs | {Key: ., Code: "AccessDenied"}]}' < "$S3ROOT/del-keys"
      else
        jq -R -n -c '{Deleted: [], Errors: [inputs | {Key: ., Code: "AccessDenied"}]}' < "$S3ROOT/del-keys"
      fi
      exit 0
    fi
    sed "s|^|$S3ROOT/$BUCKET/|" "$S3ROOT/del-keys" | tr '\n' '\0' | xargs -0 -r rm -f
    [ "$QUIET" = true ] && exit 0
    jq -R -n -c '{Deleted: [inputs | {Key: .}], Errors: []}' < "$S3ROOT/del-keys"
    ;;
  get-object)
    [ -f "$S3ROOT/$BUCKET/$KEY" ] || exit 254
    cp "$S3ROOT/$BUCKET/$KEY" "$OUTFILE" || exit 253
    printf '{"ContentLength":%s}\n' "$(stat -c%s "$OUTFILE")"
    ;;
  *)
    printf 'aws-stub: unsupported verb %s\n' "$VERB" >&2
    exit 252
    ;;
esac
# <<< aws-stub
SH
sed -i -e "s|__S3ROOT__|$T/s3|" -e "s|__S3META__|$T/s3meta|" -e "s|__CALLS__|$T/s3/calls.log|" "$T/fakebin/aws"
chmod +x "$T/fakebin/aws"

AGEPUB=$(PATH="$T/fakebin:$PATH" age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
[ -n "$AGEPUB" ] && ok || bad "setup: age-keygen gave no public key"
printf 'not-the-identity-that-encrypted-this\n' > "$T/wrong.key"

# ── the fixture the object is made from ─────────────────────────────────────
SEEDALERT='2026-09-15T00:00:00Z [some-other-lane] a line this suite must never disturb'
mkfix() {
  rm -rf "$T/h" "$T/orch" "$T/checkout" "$T/s3" "$T/s3meta"
  mkdir -p "$T/h/env/tokens.d" "$T/h/state/quota" "$T/h/state/merge-conductor" \
           "$T/h/logs" "$T/h/flags" "$T/h/builds/b1" \
           "$T/orch/some" "$T/orch/node_modules/pkg" "$T/orch/.git" \
           "$T/checkout" "$T/s3" "$T/s3meta"
  {
    printf 'HARNESS_SECRET=%s\n' "$CANARY"
    printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
    printf 'BACKUP_S3_BUCKET=bkt\n'
    printf 'BACKUP_S3_ACCESS_KEY_ID=akid-canary-4491\n'
    printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-canary-4491\n'
    printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
  } > "$T/h/env/global.env"
  printf '%s\n' "$CANARY" > "$T/h/env/tokens.d/x"
  printf 'small\n' > "$T/h/state/box-id"
  printf '{"used":3}\n' > "$T/h/state/quota/a.json"
  printf 'k1\tsnap1\nk2\tsnap2\n' > "$T/h/state/merge-conductor/pr-state.tsv"
  printf '%s\n' "$SEEDALERT" > "$T/h/logs/ALERTS.log"
  for f in RESULT cost.csv plan.md review.md pipeline.log other.txt; do
    printf 'b1 %s\n' "$f" > "$T/h/builds/b1/$f"
  done
  printf 'orchestrator payload\n' > "$T/orch/some/file.txt"
  printf 'module.exports = 1\n' > "$T/orch/node_modules/pkg/index.js"
  printf 'ref: refs/heads/main\n' > "$T/orch/.git/HEAD"
}

CALLS="$T/s3/calls.log"
objects() { find "$T/s3/bkt" -type f 2>/dev/null | wc -l; }

# ── the object: made by the production uploader, not by hand ────────────────
mkfix
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/checkout" \
    ORCHESTRATOR_DIR="$T/orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW" \
    bash "$DIR/bin/state-backup.sh" > "$T/backup.out" 2>&1
BRC=$?
[ "$BRC" -eq 0 ] && ok || bad "setup: bin/state-backup.sh exited $BRC ($(tail -3 "$T/backup.out"))"
OBJ="$T/s3/bkt/$KEY"
[ -f "$OBJ" ] && ok || bad "setup: no object at $KEY"
[ "$(objects)" -eq 1 ] && ok || bad "setup: expected exactly one object, found $(objects)"
OBYTES=$(stat -c%s "$OBJ" 2>/dev/null)
OSHA=$(sha256sum "$OBJ" 2>/dev/null | cut -d' ' -f1)
[ "$(cat "$T/s3meta/bkt/$KEY" 2>/dev/null)" = "$OSHA" ] \
  && ok || bad "setup: the stored sha256 is not the object's"
cp "$OBJ" "$T/pristine.tar.zst"
BASE_CALLS=$(wc -l < "$CALLS" 2>/dev/null)

# The production entry point, driven exactly as an operator drives it.
rr() {
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" ETC_HARNESS_ENV="$T/no-such-etc" \
      RESTORE_NOW="$NOW" bash "$DIR/bin/state-restore.sh" "$@" > "$T/rr.out" 2>&1
}
calls_now() { wc -l < "$CALLS" 2>/dev/null; }
tree_hashes() { # tree_hashes <dir>... — a stable content list of every file
  find "$@" -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null
}

# ── C1: nothing configured, and no restore-merge.sh next door ───────────────
mkdir -p "$T/h-noconf/env"
grep -v '^BACKUP_S3_ENDPOINT=' "$T/h/env/global.env" > "$T/h-noconf/env/global.env"
C0=$(calls_now)
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h-noconf" ETC_HARNESS_ENV="$T/no-such-etc" \
    bash "$DIR/bin/state-restore.sh" small > "$T/rr.out" 2>&1
RC=$?
[ "$RC" -eq 1 ] && ok || bad "C1: an unconfigured root exited $RC, want 1 ($(tail -2 "$T/rr.out"))"
grep -q 'not configured' "$T/rr.out" && ok || bad "C1: no refusal line: $(cat "$T/rr.out")"
grep -q 'BACKUP_S3_ENDPOINT' "$T/rr.out" \
  && ok || bad "C1: the refusal does not name the missing key: $(cat "$T/rr.out")"
grep -qE 'sak-canary-4491|akid-canary-4491' "$T/rr.out" \
  && bad "C1: the refusal printed a credential value" || ok
[ "$(calls_now)" = "$C0" ] && ok || bad "C1: an unconfigured run called the bucket"

mkdir -p "$T/binonly"
cp -r "$DIR/bin/." "$T/binonly/"
rm -f "$T/binonly/restore-merge.sh"
C0=$(calls_now)
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" ETC_HARNESS_ENV="$T/no-such-etc" \
    bash "$T/binonly/state-restore.sh" small > "$T/rr.out" 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok || bad "C1: a missing restore-merge.sh exited $RC, want 2 ($(tail -2 "$T/rr.out"))"
grep -q 'restore-merge.sh' "$T/rr.out" \
  && ok || bad "C1: it does not say what is missing: $(cat "$T/rr.out")"
[ "$(calls_now)" = "$C0" ] && ok || bad "C1: it called the bucket without its merge half"

# ── R7: usage ───────────────────────────────────────────────────────────────
C0=$(calls_now)
rr; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R7: no arguments exited $RC, want 2"
rr small --nosuchflag; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R7: an unknown flag exited $RC, want 2"
rr small 2026-09-15; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R7: a malformed ts exited $RC, want 2"
rr small --identity; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R7: a flag with no value exited $RC, want 2"
rr --help; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R7: --help exited $RC, want 0"
grep -q 'state-restore.sh' "$T/rr.out" && ok || bad "R7: --help printed no usage"
[ "$(calls_now)" = "$C0" ] && ok || bad "R7: a usage error called the bucket"

# ── R1: list ────────────────────────────────────────────────────────────────
: > "$T/s3/bkt/small/junk.txt"
: > "$T/s3/bkt/small/20260901T0000Z.tar.zst"
mkdir -p "$T/s3/bkt/small-2"
: > "$T/s3/bkt/small-2/20260916T000000Z.tar.zst"
rr small; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R1: listing exited $RC, want 0 ($(cat "$T/rr.out"))"
[ "$(cat "$T/rr.out")" = "$TSNOW  $OBYTES" ] \
  && ok || bad "R1: listing printed '$(cat "$T/rr.out")', want '$TSNOW  $OBYTES'"
rr nosuchbox; RC=$?
[ "$RC" -eq 1 ] && ok || bad "R1: an empty listing exited $RC, want 1"
[ "$(cat "$T/rr.out")" = "no backups for nosuchbox" ] \
  && ok || bad "R1: an empty listing printed '$(cat "$T/rr.out")'"

# R1c: the neighbouring prefix is not this box's
rr small
grep -q '20260916T000000Z' "$T/rr.out" \
  && bad "R1c: small-2/ keys were listed for small" || ok

# R1b: a truncated listing is followed to the end
cp "$OBJ" "$T/s3/bkt/small/$TSOLD.tar.zst"
printf '1\n' > "$T/s3/page-size"
rr small; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R1b: a paged listing exited $RC ($(cat "$T/rr.out"))"
[ "$(wc -l < "$T/rr.out")" -eq 2 ] \
  && ok || bad "R1b: a paged listing printed $(wc -l < "$T/rr.out") rows, want 2: $(cat "$T/rr.out")"
[ "$(sed -n 1p "$T/rr.out" | cut -d' ' -f1)" = "$TSOLD" ] \
  && ok || bad "R1b: the paged listing is not sorted: $(cat "$T/rr.out")"
rr small latest --dest "$T/d1b" --live "$T/live1b" --orchestrator-live "$T/orch1b" 2>/dev/null
[ -d "$T/d1b/small/$TSNOW" ] \
  && ok || bad "R1b: latest off a truncated listing pulled $(ls "$T/d1b/small" 2>/dev/null), want $TSNOW"
rm -f "$T/s3/page-size" "$T/s3/bkt/small/$TSOLD.tar.zst"

# ── R2: the default is a dry run ────────────────────────────────────────────
mkdir -p "$T/live0/logs" "$T/live0/state/quota" "$T/orch0"
printf 'live one\nlive two\n' > "$T/live0/logs/ALERTS.log"
printf '{"used":9}\n' > "$T/live0/state/quota/a.json"
BEFORE=$(tree_hashes "$T/live0" "$T/orch0")
rr small latest --live "$T/live0" --orchestrator-live "$T/orch0"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R2: a dry run exited $RC ($(tail -5 "$T/rr.out"))"
grep -q "sha256 ok $OSHA" "$T/rr.out" \
  && ok || bad "R2: the sha256 was not verified: $(grep -i sha256 "$T/rr.out")"
grep -qxF -- '--- meta/checkout-head.txt ---' "$T/rr.out" \
  && ok || bad "R2: meta/checkout-head.txt was not printed"
grep -qxF "$HEADSHA" "$T/rr.out" && ok || bad "R2: the checkout head was not printed"
grep -qxF -- '--- meta/crontab.txt ---' "$T/rr.out" \
  && ok || bad "R2: meta/crontab.txt was not printed"
grep -qxF "$CRONLINE" "$T/rr.out" && ok || bad "R2: the crontab was not printed"
grep -q 'crontab is shown, not installed' "$T/rr.out" \
  && ok || bad "R2: it does not say the crontab is not installed"
grep -q '^ADD ' "$T/rr.out" && ok || bad "R2: restore-merge reported no ADD line"
grep -q 'SUMMARY mode=dry-run' "$T/rr.out" \
  && ok || bad "R2: no dry-run summary: $(tail -3 "$T/rr.out")"
grep -q 'ADD env.tar.age' "$T/rr.out" \
  && bad "R2: the encrypted env blob was offered to the live tree" || ok
[ "$(tree_hashes "$T/live0" "$T/orch0")" = "$BEFORE" ] \
  && ok || bad "R2: a dry run changed the live tree"
[ -f "$T/h/tmp/state-restore/small/$TSNOW/snapshot.tar.zst" ] \
  && ok || bad "R2: the object was not pulled to disk under \$H/tmp"
[ -f "$T/h/tmp/state-restore/small/$TSNOW/tree/state/box-id" ] \
  && ok || bad "R2: the tree was not extracted"
[ ! -e "$T/h/tmp/state-restore/small/$TSNOW/tree/env.tar.age" ] \
  && ok || bad "R2: env.tar.age is inside the tree handed to restore-merge"
grep -q "$CANARY" "$T/rr.out" && bad "R2: a secret reached stdout" || ok

# ── R3: --apply with the right identity ─────────────────────────────────────
mkdir -p "$T/live/logs" "$T/live/state/quota" "$T/live/state/merge-conductor" "$T/orch3"
printf 'live one\nlive two\n' > "$T/live/logs/ALERTS.log"
printf '{"used":9}\n' > "$T/live/state/quota/a.json"
printf 'k1\tlive1\n' > "$T/live/state/merge-conductor/pr-state.tsv"
cp "$T/live/logs/ALERTS.log" "$T/pre-alerts.log"
rr small latest --apply --identity "$T/age.key" --dest "$T/d3" --live "$T/live" \
   --backup-dir "$T/bk3" --orchestrator-live "$T/orch3"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R3: --apply exited $RC ($(tail -5 "$T/rr.out"))"
grep -q 'env/ decrypted' "$T/rr.out" \
  && ok || bad "R3: env/ was not decrypted: $(grep -i env "$T/rr.out")"
[ -f "$T/live/env/global.env" ] && ok || bad "R3: env/global.env did not land"
grep -q "$CANARY" "$T/live/env/global.env" 2>/dev/null \
  && ok || bad "R3: env/global.env landed without its content"
[ -f "$T/live/env/tokens.d/x" ] && ok || bad "R3: env/tokens.d/x did not land"
[ "$(cat "$T/live/logs/ALERTS.log")" = "$SEEDALERT
live one
live two" ] && ok || bad "R3: ALERTS.log merged wrong: $(cat "$T/live/logs/ALERTS.log")"
[ "$(cat "$T/live/state/merge-conductor/pr-state.tsv")" = "$(printf 'k1\tlive1\nk2\tsnap2')" ] \
  && ok || bad "R3: pr-state.tsv union is $(cat "$T/live/state/merge-conductor/pr-state.tsv")"
grep -q 'snap1' "$T/live/state/merge-conductor/pr-state.tsv" \
  && bad "R3: the snapshot overwrote a live pr-state row" || ok
[ "$(cat "$T/live/state/quota/a.json")" = '{"used":9}' ] \
  && ok || bad "R3: live quota was overwritten: $(cat "$T/live/state/quota/a.json")"
cmp -s "$T/bk3/logs/ALERTS.log" "$T/pre-alerts.log" \
  && ok || bad "R3: the replaced ALERTS.log was not backed up byte-for-byte"
[ "$(cat "$T/live/flags/.alerts-cursor" 2>/dev/null)" = "$(wc -c < "$T/live/logs/ALERTS.log")" ] \
  && ok || bad "R3: the alerts cursor is $(cat "$T/live/flags/.alerts-cursor" 2>/dev/null), want $(wc -c < "$T/live/logs/ALERTS.log")"
grep -q 'SUMMARY mode=apply' "$T/rr.out" \
  && ok || bad "R3: no apply summary: $(tail -3 "$T/rr.out")"
grep -q "$CANARY" "$T/rr.out" && bad "R3: a secret reached stdout" || ok
[ ! -e "$T/live/env.tar.age" ] && ok || bad "R3: the encrypted blob landed in the live tree"
[ -f "$T/orch3/some/file.txt" ] && ok || bad "R3: the orchestrator checkout did not land"
[ ! -e "$T/live/meta" ] && ok || bad "R3: meta/ was applied instead of shown"

AFTER3=$(tree_hashes "$T/live" "$T/orch3")
rr small latest --apply --identity "$T/age.key" --dest "$T/d3b" --live "$T/live" \
   --backup-dir "$T/bk3b" --orchestrator-live "$T/orch3"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R3: the second apply exited $RC ($(tail -5 "$T/rr.out"))"
[ "$(tree_hashes "$T/live" "$T/orch3")" = "$AFTER3" ] \
  && ok || bad "R3: a second apply changed the tree - it is not idempotent"

# ── R4: no identity ─────────────────────────────────────────────────────────
mkdir -p "$T/live4/logs" "$T/orch4"
printf 'live one\n' > "$T/live4/logs/ALERTS.log"
rr small latest --apply --dest "$T/d4" --live "$T/live4" \
   --backup-dir "$T/bk4" --orchestrator-live "$T/orch4"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R4: no identity exited $RC, want 0 ($(tail -5 "$T/rr.out"))"
grep -q 'env/ NOT decrypted (no identity given): env files will not be restored' "$T/rr.out" \
  && ok || bad "R4: it did not say env/ was skipped: $(grep -i env "$T/rr.out")"
[ ! -e "$T/live4/env" ] && ok || bad "R4: env/ landed without an identity"
grep -q 'SUMMARY mode=apply' "$T/rr.out" \
  && ok || bad "R4: the rest of the tree was not merged"
[ -f "$T/live4/state/box-id" ] && ok || bad "R4: state/ did not land"

# ── R4b: wrong identity ─────────────────────────────────────────────────────
mkdir -p "$T/live4b/logs" "$T/orch4b"
printf 'live one\n' > "$T/live4b/logs/ALERTS.log"
rr small latest --apply --identity "$T/wrong.key" --dest "$T/d4b" --live "$T/live4b" \
   --backup-dir "$T/bk4b" --orchestrator-live "$T/orch4b"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "R4b: a wrong identity exited $RC, want 1 ($(tail -5 "$T/rr.out"))"
grep -q 'REFUSED env/: age rc=' "$T/rr.out" \
  && ok || bad "R4b: it did not refuse env/ out loud: $(grep -i env "$T/rr.out")"
grep -q 'SUMMARY mode=' "$T/rr.out" \
  && ok || bad "R4b: the rest of the tree was not merged"
[ ! -e "$T/d4b/small/$TSNOW/tree/env" ] \
  && ok || bad "R4b: a partial decrypt was staged into the snapshot tree"
[ ! -e "$T/live4b/env" ] && ok || bad "R4b: env/ landed under a wrong identity"
grep -q "$CANARY" "$T/rr.out" && bad "R4b: a secret reached stdout" || ok

# ── R5: the object does not match its stored sha256 ─────────────────────────
mkdir -p "$T/live5/logs" "$T/orch5"
printf 'live one\n' > "$T/live5/logs/ALERTS.log"
BEFORE=$(tree_hashes "$T/live5")
printf 'x' >> "$OBJ"
rr small latest --apply --dest "$T/d5" --live "$T/live5" \
   --backup-dir "$T/bk5" --orchestrator-live "$T/orch5"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "R5: a tampered object exited $RC, want 1 ($(tail -5 "$T/rr.out"))"
grep -q 'REFUSED: sha256 mismatch' "$T/rr.out" \
  && ok || bad "R5: it did not refuse on the sha256: $(cat "$T/rr.out")"
grep -q 'SUMMARY' "$T/rr.out" \
  && bad "R5: it merged an object that failed its checksum" || ok
[ -z "$(find "$T/d5/small/$TSNOW/tree" -mindepth 1 2>/dev/null)" ] \
  && ok || bad "R5: it extracted an object that failed its checksum"
[ "$(tree_hashes "$T/live5")" = "$BEFORE" ] && ok || bad "R5: the live tree changed anyway"
cp "$T/pristine.tar.zst" "$OBJ"

# R5b: no stored metadata at all
mkdir -p "$T/live5b/logs" "$T/orch5b"
printf 'live one\n' > "$T/live5b/logs/ALERTS.log"
: > "$T/s3meta/bkt/$KEY"
rr small latest --dest "$T/d5b" --live "$T/live5b" --orchestrator-live "$T/orch5b"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "R5b: an unverifiable object exited $RC, want refusal ($(tail -5 "$T/rr.out"))"
grep -q 'sha256 unverified (no metadata)' "$T/rr.out" \
  && ok || bad "R5b: it did not say the object is unverified: $(grep -i sha256 "$T/rr.out")"
[ ! -f "$T/d5b/small/$TSNOW/tree/state/box-id" ] \
  && ok || bad "R5b: it extracted an object without proof"
rr small latest --allow-unverified --dest "$T/d5b-legacy" --live "$T/live5b" --orchestrator-live "$T/orch5b"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R5b: explicit manual legacy recovery exited $RC ($(tail -5 "$T/rr.out"))"
[ -f "$T/d5b-legacy/small/$TSNOW/tree/state/box-id" ] \
  && ok || bad "R5b: explicit legacy recovery did not extract the object"
printf '%s\n' "$OSHA" > "$T/s3meta/bkt/$KEY"

# ── R6: destination hygiene, and the box name never reaches the bucket ──────
mkdir -p "$T/live6" "$T/orch6"
rr small latest --dest "$T/d5b-legacy" --live "$T/live6" --orchestrator-live "$T/orch6"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "R6: an existing destination exited $RC, want 1"
grep -q 'already pulled at' "$T/rr.out" \
  && ok || bad "R6: it did not name the existing pull: $(cat "$T/rr.out")"
[ -f "$T/d5b-legacy/small/$TSNOW/tree/state/box-id" ] \
  && ok || bad "R6: it removed a destination it had refused"
rr small latest --dest "$T/live6/sub" --live "$T/live6"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R6: --dest under --live exited $RC, want 2"
rr small latest --dest "$T/live6/state" --live "$T/live6"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R6: --dest on top of live state/ exited $RC, want 2"
# ...but the SHIPPED default is <live>/tmp/state-restore, and that one has to
# work: on a real box $H and --live are the same directory.
mkdir -p "$T/live6t/logs" "$T/orch6t"
printf 'live one\n' > "$T/live6t/logs/ALERTS.log"
rr small latest --dest "$T/live6t/tmp/state-restore" --live "$T/live6t" \
   --orchestrator-live "$T/orch6t"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R6: the default dest (<live>/tmp) exited $RC, want 0 ($(tail -3 "$T/rr.out"))"
[ -f "$T/live6t/tmp/state-restore/small/$TSNOW/tree/state/box-id" ] \
  && ok || bad "R6: the default dest did not extract under <live>/tmp"
C0=$(calls_now)
rr ../x latest --dest "$T/d6" --live "$T/live6"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "R6: a box name outside [a-z0-9-] exited $RC, want 2"
[ "$(calls_now)" = "$C0" ] && ok || bad "R6: a refused run still called the bucket"

# the whole suite only ever spoke three verbs to the bucket
VERBS=$(tail -n +"$((BASE_CALLS + 1))" "$CALLS" | awk '{ print $2 }' | LC_ALL=C sort -u | tr '\n' ' ')
[ "$VERBS" = "get-object head-object list-objects-v2 " ] \
  && ok || bad "R1: state-restore spoke '$VERBS', want only get-object head-object list-objects-v2"

# ── D1: the doc ─────────────────────────────────────────────────────────────
DOC="$DIR/docs/RESTORE.md"
[ -f "$DOC" ] && ok || bad "D1: docs/RESTORE.md does not exist"
for want in 'crontab -r' 'tailscaled.state' 'Settings' 'BACKUP_AGE_RECIPIENT' \
            'harness-state' 'private key' 'bin/state-restore.sh' 'bin/restore-merge.sh'; do
  grep -qF -- "$want" "$DOC" 2>/dev/null && ok || bad "D1: docs/RESTORE.md does not mention '$want'"
done
grep -qx '## Setup' "$DOC" 2>/dev/null && ok || bad "D1: docs/RESTORE.md has no literal '## Setup' heading"
# INVERTED BY BH-399, not dropped. When #449 shipped, `fleet_status` and the
# freshness alert did not exist, so naming them in this doc was a FORWARD CLAIM
# and this loop refused it — correctly. #399 built both: bin/lib/backup-freshness.sh
# feeds backups.<box> into the fleet_status snapshot and bin/pipeline-health.sh's
# `# >>> backup freshness` block pages on it. The same two strings therefore have
# to be REQUIRED now, or the operator reading RESTORE.md still believes checking
# the stamp is a manual chore. The assertion count is unchanged; only its
# direction moved, with the repo.
for want in 'freshness alert' 'fleet_status'; do
  grep -qF -- "$want" "$DOC" 2>/dev/null \
    && ok || bad "D1: docs/RESTORE.md does not mention '$want' — BH-399 built it, and the restore doc is where an operator learns they do not have to watch the stamp by hand"
done
BADLINK=""
while IFS= read -r l; do
  case "$l" in http*|'#'*|'') continue ;; esac
  [ -e "$DIR/docs/$l" ] || BADLINK="$BADLINK $l"
done < <(grep -o '](\([^)]*\))' "$DOC" 2>/dev/null | sed 's/^](//; s/)$//')
[ -z "$BADLINK" ] && ok || bad "D1: docs/RESTORE.md has links that resolve to nothing:$BADLINK"
grep -qF 'docs/RESTORE.md' "$DIR/README.md" 2>/dev/null \
  && ok || bad "D1: README.md does not link docs/RESTORE.md"
# The index is generated and not committed (BH-1175); the entry files are the
# committed source, so that is what this reads.
# grep -r, not `cat … | grep -q`: this suite runs under `set -o pipefail`, and
# `grep -q` exits on the first hit, so cat takes a SIGPIPE and the pipeline
# reports failure on the very input that proved the assertion true.
grep -qrF 'state-restore.md' "$DIR/docs/verification-map/entries/" \
  && ok || bad "D1: the verification map has no state-restore entry"

echo "state-restore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
