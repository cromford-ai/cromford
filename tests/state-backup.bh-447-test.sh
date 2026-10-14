#!/bin/bash
# tests/state-backup.bh-447-test.sh — bin/state-backup.sh against a scratch harness
# root, a fake S3 (a directory tree behind an `aws s3api` stand-in) and a frozen
# clock. Nothing here touches a real box, a real bucket or the real crontab.
#
# WHY THE SCRIPT EXISTS (#388, 2026-09-15). The hub's /root/harness/{env,bin,
# prompts,logs,builds} vanished under a running system and there was no off-box
# copy of any of it. bin/state-backup.sh is the 15-minute copy: env/ encrypted
# with age, everything else tarred next to it, uploaded to an S3-compatible
# bucket (R2), verified, stamped, then pruned by retention.
#
# What is proved here:
#   S1   one run uploads exactly one object under the box prefix, the stamp in
#        state/backup-last.json matches the bytes and sha256 of what landed, the
#        tarball carries state/logs/flags/the builds summaries/the orchestrator
#        checkout/meta and NOT one plaintext env/ entry, and env.tar.age
#        decrypts back to env/global.env with its secret intact;
#   S1b  env/ as a symlink (the /etc/harness/env compat shape) is still tarred
#        by content, not as a dangling link;
#   S2   a failing put-object writes ONE actionable ALERTS line naming the
#        stage, never the key values, leaves the previous stamp byte-identical
#        and leaves no staging directory behind;
#   S2d  an object that lands but cannot be verified is NOT a backup: whether
#        head-object errors, answers without a ContentLength, or answers with a
#        size that is not the local one, the run alerts, leaves the previous
#        stamp byte-identical, prunes nothing and exits 1;
#   S2b  a held lock is a skip, not a queue;
#   S2c  missing configuration alerts once per UTC day, logs every run, uploads
#        nothing, and both kill switches stop it dead before any of that;
#   S2c-clock  a BACKUP_NOW (or box clock) that gives no usable timestamp is one
#        ALERTS line and rc 1, never an object named "<box>/.tar.zst";
#   S3   retention keeps everything younger than BACKUP_KEEP_ALL_DAYS, thins the
#        middle zone to the earliest object of each UTC day, deletes past
#        BACKUP_KEEP_DAILY_DAYS, batches deletes at 1000, never touches a
#        foreign/malformed/future key, skips the prune entirely when the
#        listing fails, reports a refused delete batch as an alert plus an
#        honest pruned count rather than counting it as deleted, and stays
#        silent when every batch succeeds (a quiet DeleteObjects prints nothing
#        on success, and that silence must not be read as a failed batch).
# Run from anywhere: tests/state-backup.bh-447-test.sh   (exit 0 = all pass)
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

NOW=1789514400            # 2026-09-15T23:20:00Z — every fixture age derives from this
TSNOW=20260915T232000Z    # what the script must name the object it uploads
KEY="small/$TSNOW.tar.zst"
CANARY=leakcanary-4471    # stands in for every secret in env/; must never leave env.tar.age
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
  echo "state-backup: $PASS passed, $FAIL failed"
  exit 1
fi
echo "age mode: $AGE_MODE"

if ! command -v age >/dev/null 2>&1; then
  cat > "$T/fakebin/age" <<'SH'
#!/bin/bash
# age stand-in: base64 in place of the cipher. `-r RECIPIENT` encrypts stdin,
# `-d -i KEYFILE` decrypts it. What this suite proves with it is the ROUTING
# (env/ leaves the box only through this pipe); CI runs the same file with the
# real binary under AGE_REQUIRED=1.
if [ "${1:-}" = "-d" ]; then exec base64 -d; fi
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
# The block between the markers is what the restore slice (#449) copies
# verbatim; the three paths are substituted below so the body stays literal.
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
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket)   BUCKET="${2:-}"; shift 2 ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --body)     BODY="${2:-}"; shift 2 ;;
    --prefix)   PREFIX="${2:-}"; shift 2 ;;
    --metadata) META="${2:-}"; shift 2 ;;
    --delete)   DEL="${2:-}"; shift 2 ;;
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
    find "$S3ROOT/$BUCKET" -type f -printf '%s\t%P\n' \
      | awk -F'\t' -v p="$PREFIX" 'p == "" || index($2, p) == 1' \
      | jq -R -n -c '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}]}'
    ;;
  delete-objects)
    printf '%s' "$DEL" | jq -r '.Objects[].Key' > "$S3ROOT/del-keys" || exit 253
    QUIET=$(printf '%s' "$DEL" | jq -r '.Quiet // false' 2>/dev/null)
    if [ -f "$S3ROOT/fail-delete" ]; then
      # the bucket refused the batch: rc 0, one Errors entry per key, and not
      # one object removed. This is how a real S3 reports a partial refusal —
      # Quiet suppresses the Deleted list, never the Errors.
      if [ "$QUIET" = true ]; then
        jq -R -n -c '{Errors: [inputs | {Key: ., Code: "AccessDenied"}]}' < "$S3ROOT/del-keys"
      else
        jq -R -n -c '{Deleted: [], Errors: [inputs | {Key: ., Code: "AccessDenied"}]}' < "$S3ROOT/del-keys"
      fi
      exit 0
    fi
    sed "s|^|$S3ROOT/$BUCKET/|" "$S3ROOT/del-keys" | tr '\n' '\0' | xargs -0 -r rm -f
    # A fully successful Quiet batch is an empty <DeleteResult/>: botocore parses
    # it to nothing once ResponseMetadata is stripped, and the CLI's JSON
    # formatter prints NOT ONE BYTE for an empty response. Anything printed here
    # would be a shape the real CLI never emits, and would hide a caller that
    # mistakes a silent success for an unreadable answer.
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

# ── the fixture ─────────────────────────────────────────────────────────────
SEEDALERT='2026-09-15T00:00:00Z [some-other-lane] a line this suite must never disturb'
mkfix() {
  rm -rf "$T/h" "$T/orch" "$T/checkout" "$T/s3" "$T/s3meta" "$T/x1" "$T/xenv" "$T/etc-env"
  mkdir -p "$T/h/env/tokens.d" "$T/h/state/quota" "$T/h/logs" "$T/h/flags" \
           "$T/h/builds/b1" "$T/orch/some" "$T/orch/node_modules/pkg" "$T/orch/.git" \
           "$T/checkout" "$T/s3" "$T/s3meta"
  {
    printf 'HARNESS_SECRET=%s\n' "$CANARY"
    printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
    printf 'BACKUP_S3_BUCKET=bkt\n'
    printf 'BACKUP_S3_ACCESS_KEY_ID=akid-canary-4471\n'
    printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-canary-4471\n'
    printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
  } > "$T/h/env/global.env"
  printf '%s\n' "$CANARY" > "$T/h/env/tokens.d/x"
  printf '%s\n' "$CANARY" > "$T/h/env/.watchdog-secret"
  printf 'small\n' > "$T/h/state/box-id"
  printf '{"used":3}\n' > "$T/h/state/quota/a.json"
  printf '%s\n' "$SEEDALERT" > "$T/h/logs/ALERTS.log"
  for f in RESULT cost.csv plan.md review.md pipeline.log other.txt; do
    printf 'b1 %s\n' "$f" > "$T/h/builds/b1/$f"
  done
  printf 'orchestrator payload\n' > "$T/orch/some/file.txt"
  printf 'module.exports = 1\n' > "$T/orch/node_modules/pkg/index.js"
  printf 'ref: refs/heads/main\n' > "$T/orch/.git/HEAD"
}

# The production entry point, driven exactly as cron will drive it.
run() { # run [VAR=VAL ...]
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/checkout" \
      ORCHESTRATOR_DIR="$T/orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW" \
      "$@" bash "$DIR/bin/state-backup.sh" > "$T/run.out" 2>&1
}
LOG="$T/h/logs/state-backup.log"
ALOG="$T/h/logs/ALERTS.log"
CALLS="$T/s3/calls.log"
verb_count() { # grep -c prints 0 and exits 1 on no match; a missing file prints nothing
  local n; n=$(grep -c -- "$1" "$CALLS" 2>/dev/null); printf '%s\n' "${n:-0}"
}
objects() { find "$T/s3/bkt" -type f 2>/dev/null | wc -l; }

# ── S1: one run, end to end ─────────────────────────────────────────────────
mkfix
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1: the happy path exited $RC ($(tail -3 "$T/run.out"))"

OBJ="$T/s3/bkt/$KEY"
[ -f "$OBJ" ] && ok || bad "S1: nothing landed at $KEY (bucket: $(find "$T/s3" -type f 2>/dev/null | head -5))"
[ "$(objects)" -eq 1 ] && ok || bad "S1: expected exactly one object, found $(objects)"

# the call order is the contract: upload, verify, only then list for the prune
ORDER=$(awk '{ print $2 }' "$CALLS" 2>/dev/null | tr '\n' ' ')
[ "$ORDER" = "put-object head-object list-objects-v2 " ] \
  && ok || bad "S1: call order was '$ORDER'"

LAST="$T/h/state/backup-last.json"
[ -f "$LAST" ] && ok || bad "S1: no state/backup-last.json"
[ "$(jq -r .key "$LAST" 2>/dev/null)" = "$KEY" ] \
  && ok || bad "S1: stamped key $(jq -r .key "$LAST" 2>/dev/null) want $KEY"
[ "$(jq -r .ts "$LAST" 2>/dev/null)" = "$TSNOW" ] \
  && ok || bad "S1: stamped ts $(jq -r .ts "$LAST" 2>/dev/null) want $TSNOW"
OBYTES=$(stat -c%s "$OBJ" 2>/dev/null)
OSHA=$(sha256sum "$OBJ" 2>/dev/null | cut -d' ' -f1)
[ "$(jq -r .bytes "$LAST" 2>/dev/null)" = "$OBYTES" ] \
  && ok || bad "S1: stamped bytes $(jq -r .bytes "$LAST" 2>/dev/null) want $OBYTES"
[ "$(jq -r .sha256 "$LAST" 2>/dev/null)" = "$OSHA" ] \
  && ok || bad "S1: stamped sha256 does not match the object that landed"
[ "$(cat "$T/s3meta/bkt/$KEY" 2>/dev/null)" = "$OSHA" ] \
  && ok || bad "S1: the sha256 handed to put-object is not the object's"
LSIZE=$(PATH="$T/fakebin:$PATH" aws s3api list-objects-v2 --bucket bkt --prefix small/ --output json \
        | jq -r '.Contents[0].Size' 2>/dev/null)
[ "$LSIZE" = "$OBYTES" ] && ok || bad "S1: the listed size $LSIZE is not the stamped $OBYTES"

ENTRIES=$(PATH="$T/fakebin:$PATH" tar --zstd -tf "$OBJ" 2>"$T/tar-t.err")
for want in env.tar.age state/box-id state/quota/a.json logs/ALERTS.log flags/ \
            builds/b1/RESULT builds/b1/cost.csv builds/b1/plan.md builds/b1/review.md \
            builds/b1/pipeline.log orchestrator/some/file.txt meta/crontab.txt \
            meta/checkout-head.txt meta/box.txt meta/ts.txt; do
  grep -qx "$want" <<<"$ENTRIES" \
    && ok || bad "S1: the tarball is missing $want"
done
for never in builds/b1/other.txt orchestrator/node_modules/pkg/index.js orchestrator/.git/HEAD; do
  grep -qx "$never" <<<"$(printf '%s\n' "$ENTRIES")" \
    && bad "S1: the tarball carries $never and must not" || ok
done
LEAKED=$(printf '%s\n' "$ENTRIES" | grep -Ec '^env(/|$)')
[ "$LEAKED" -eq 0 ] && ok || bad "S1: $LEAKED plaintext env/ entries in the tarball"

mkdir -p "$T/x1"
( cd "$T/x1" && PATH="$T/fakebin:$PATH" tar --zstd -xf "$OBJ" ) \
  && ok || bad "S1: the tarball does not extract"
grep -rq "$CANARY" "$T/x1" 2>/dev/null \
  && bad "S1: an env secret is readable in the tarball without the age key" || ok
[ "$(cat "$T/x1/meta/crontab.txt" 2>/dev/null)" = "$CRONLINE" ] \
  && ok || bad "S1: meta/crontab.txt is '$(cat "$T/x1/meta/crontab.txt" 2>/dev/null)'"
[ "$(cat "$T/x1/meta/checkout-head.txt" 2>/dev/null)" = "$HEADSHA" ] \
  && ok || bad "S1: meta/checkout-head.txt is '$(cat "$T/x1/meta/checkout-head.txt" 2>/dev/null)'"
[ "$(cat "$T/x1/meta/box.txt" 2>/dev/null)" = small ] \
  && ok || bad "S1: meta/box.txt is '$(cat "$T/x1/meta/box.txt" 2>/dev/null)'"
[ "$(cat "$T/x1/meta/ts.txt" 2>/dev/null)" = "$TSNOW" ] \
  && ok || bad "S1: meta/ts.txt is '$(cat "$T/x1/meta/ts.txt" 2>/dev/null)'"

PATH="$T/fakebin:$PATH" age -d -i "$T/age.key" < "$T/x1/env.tar.age" > "$T/env.tar" 2>/dev/null \
  && ok || bad "S1: env.tar.age does not decrypt with the recipient's key"
mkdir -p "$T/xenv"
tar -xf "$T/env.tar" -C "$T/xenv" 2>/dev/null
for want in env/global.env env/tokens.d/x env/.watchdog-secret; do
  [ -f "$T/xenv/$want" ] && ok || bad "S1: the encrypted env tar is missing $want"
done
grep -q "$CANARY" "$T/xenv/env/global.env" 2>/dev/null \
  && ok || bad "S1: env/global.env came back without its content"

[ "$(grep -c 'uploaded' "$LOG" 2>/dev/null)" -eq 1 ] \
  && ok || bad "S1: expected one uploaded line, log is: $(cat "$LOG" 2>/dev/null)"
grep -q "$KEY" "$LOG" && ok || bad "S1: the log line does not name the key"
[ "$(cat "$ALOG")" = "$SEEDALERT" ] \
  && ok || bad "S1: a clean run wrote to ALERTS.log: $(cat "$ALOG")"

# ── S1b: env/ as a symlink (the /etc/harness/env compat shape) ──────────────
mkfix
mkdir -p "$T/etc-env"
cp "$T/h/env/global.env" "$T/etc-env/global.env"
rm -rf "$T/h/env"
ln -s "$T/etc-env" "$T/h/env"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1b: a symlinked env/ exited $RC ($(tail -3 "$T/run.out"))"
rm -rf "$T/x1"; mkdir -p "$T/x1"
( cd "$T/x1" && PATH="$T/fakebin:$PATH" tar --zstd -xf "$T/s3/bkt/$KEY" ) >/dev/null 2>&1
PATH="$T/fakebin:$PATH" age -d -i "$T/age.key" < "$T/x1/env.tar.age" > "$T/env.tar" 2>/dev/null
rm -rf "$T/xenv"; mkdir -p "$T/xenv"
tar -xf "$T/env.tar" -C "$T/xenv" 2>/dev/null
grep -q "$CANARY" "$T/xenv/env/global.env" 2>/dev/null \
  && ok || bad "S1b: a symlinked env/ must be backed up by content, not as a link"

# ── S2: put-object fails ────────────────────────────────────────────────────
mkfix
touch "$T/s3/fail-put"
printf '{"ts":"20260901T000000Z","key":"small/20260901T000000Z.tar.zst","bytes":11,"sha256":"beef"}\n' \
  > "$T/h/state/backup-last.json"
SEEDSTAMP=$(cat "$T/h/state/backup-last.json")
run; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S2: a failed upload exited $RC, want 1"
NAL=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
[ "$NAL" -eq 1 ] && ok || bad "S2: expected one ALERTS line, got $NAL: $(cat "$ALOG")"
ALINE=$(grep '\[state-backup\]' "$ALOG")
grep -q 'put FAILED' <<<"$ALINE" \
  && ok || bad "S2: the alert does not name the stage: $ALINE"
grep -q 'last good off-box copy: 20260901T000000Z$' <<<"$ALINE" \
  && ok || bad "S2: the alert does not end with the last good copy: $ALINE"
grep -qE 'sak-canary-4471|akid-canary-4471' <<<"$(printf '%s\n' "$ALINE")" \
  && bad "S2: the alert printed a credential value: $ALINE" || ok
[ "$(cat "$T/h/state/backup-last.json")" = "$SEEDSTAMP" ] \
  && ok || bad "S2: a failed upload rewrote the stamp: $(cat "$T/h/state/backup-last.json")"
[ -z "$(find "$T/h/tmp" -maxdepth 1 -name 'state-backup.*' 2>/dev/null)" ] \
  && ok || bad "S2: staging was left behind: $(find "$T/h/tmp" -maxdepth 1 2>/dev/null)"
[ "$(verb_count head-object)" -eq 0 ] \
  && ok || bad "S2: a failed put must not be verified"
[ "$(objects)" -eq 0 ] && ok || bad "S2: something landed anyway"

# ── S2d: the object lands but head-object cannot confirm it ─────────────────
# A put that returned 0 is not a backup. Three answers say "unverified": the
# verb errors, it comes back without a ContentLength, or it reports a size that
# is not the one on disk. Each must alert, leave the previous stamp exactly as
# it was, prune nothing and exit 1 — otherwise state/backup-last.json can claim
# an off-box copy that is not there, which is the one lie this lane must not
# tell.
verify_case() { # verify_case <stub switch> <alert fragment> <label>
  mkfix
  touch "$T/s3/$1"
  printf '{"ts":"20260901T000000Z","key":"small/20260901T000000Z.tar.zst","bytes":11,"sha256":"beef"}\n' \
    > "$T/h/state/backup-last.json"
  local seed; seed=$(cat "$T/h/state/backup-last.json")
  run; local rc=$?
  [ "$rc" -eq 1 ] && ok || bad "S2d/$3: exited $rc, want 1 ($(tail -3 "$T/run.out"))"
  local n; n=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
  [ "${n:-0}" -eq 1 ] && ok || bad "S2d/$3: expected one ALERTS line, got $n: $(cat "$ALOG")"
  local line; line=$(grep '\[state-backup\]' "$ALOG")
  grep -q "$2" <<<"$line" \
    && ok || bad "S2d/$3: the alert does not say '$2': $line"
  grep -q 'last good off-box copy: 20260901T000000Z$' <<<"$line" \
    && ok || bad "S2d/$3: the alert does not end with the last good copy: $line"
  grep -qE 'sak-canary-4471|akid-canary-4471' <<<"$(printf '%s\n' "$line")" \
    && bad "S2d/$3: the alert printed a credential value: $line" || ok
  [ "$(cat "$T/h/state/backup-last.json")" = "$seed" ] \
    && ok || bad "S2d/$3: an unverified upload rewrote the stamp: $(cat "$T/h/state/backup-last.json")"
  [ "$(verb_count put-object)" -eq 1 ] && ok || bad "S2d/$3: the object never went up"
  [ "$(objects)" -eq 1 ] && ok || bad "S2d/$3: the put landed, it is the verify that failed"
  [ "$(verb_count head-object)" -eq 1 ] && ok || bad "S2d/$3: verification was not even attempted"
  [ "$(verb_count list-objects-v2)" -eq 0 ] \
    && ok || bad "S2d/$3: it went on to prune on the back of an unverified upload"
  [ "$(verb_count delete-objects)" -eq 0 ] \
    && ok || bad "S2d/$3: it deleted on the back of an unverified upload"
  [ -z "$(find "$T/h/tmp" -maxdepth 1 -name 'state-backup.*' 2>/dev/null)" ] \
    && ok || bad "S2d/$3: staging was left behind: $(find "$T/h/tmp" -maxdepth 1 2>/dev/null)"
}
verify_case fail-head  'verify FAILED (head-object rc=254'                          head-rc
verify_case blank-head 'verify FAILED (head-object returned no usable ContentLength' no-content-length
verify_case short-head 'size FAILED (remote'                                         short-size
# the size alert is only actionable if it carries both numbers
# (captured first, never `grep file | grep -q`: grep -q SIGPIPEs the upstream
# grep and pipefail then reports the pipeline red on correct code)
ALINE=$(grep '\[state-backup\]' "$ALOG")
grep -qE 'remote [0-9]+ != local [0-9]+ for key small/' <<<"$ALINE" \
  && ok || bad "S2d/short-size: the alert does not name both sizes: $ALINE"

# ── S2b: the lock is dedupe, never a queue ──────────────────────────────────
mkfix
mkdir -p "$T/h/locks"
exec 8>"$T/h/locks/state-backup.lock"
flock -n 8 && ok || bad "S2b: could not take the lock in the test shell"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S2b: a held lock exited $RC, want 0"
grep -q 'skip: a backup is still running' "$LOG" 2>/dev/null \
  && ok || bad "S2b: the skip is not in the log: $(cat "$LOG" 2>/dev/null)"
[ "$(verb_count put-object)" -eq 0 ] && ok || bad "S2b: it uploaded while another run held the lock"
exec 8>&-

# ── S2c: not configured, and the kill switches ──────────────────────────────
mkfix
grep -v '^BACKUP_AGE_RECIPIENT=' "$T/h/env/global.env" > "$T/h/env/global.env.new"
mv "$T/h/env/global.env.new" "$T/h/env/global.env"
rm -rf "$T/h/builds"        # a fresh box has no builds/ either
run; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S2c: an unconfigured box exited $RC, want 1"
NAL=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
[ "$NAL" -eq 1 ] && ok || bad "S2c: expected one ALERTS line, got $NAL: $(cat "$ALOG")"
ALINE=$(grep '\[state-backup\]' "$ALOG")
grep -q 'BACKUP_AGE_RECIPIENT' <<<"$ALINE" \
  && ok || bad "S2c: the alert does not name the missing key: $ALINE"
grep -q 'NEEDED FROM' <<<"$ALINE" \
  && ok || bad "S2c: the alert does not say what is needed and from whom: $ALINE"
[ -f "$T/h/state/state-backup-unconfigured-20260915" ] \
  && ok || bad "S2c: no per-day marker was written"
run; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S2c: the second unconfigured run exited $RC, want 1"
NAL=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
[ "$NAL" -eq 1 ] && ok || bad "S2c: the second run alerted again the same day ($NAL lines)"
[ "$(grep -c 'not configured' "$LOG" 2>/dev/null)" -eq 2 ] \
  && ok || bad "S2c: every run must log, got: $(cat "$LOG" 2>/dev/null)"
[ "$(objects)" -eq 0 ] && ok || bad "S2c: an unconfigured box uploaded something"

run STATE_BACKUP=0; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S2c: STATE_BACKUP=0 exited $RC, want 0"
[ "$(grep -c 'not configured' "$LOG" 2>/dev/null)" -eq 2 ] \
  && ok || bad "S2c: STATE_BACKUP=0 must stop before the config check"
[ "$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)" -eq 1 ] \
  && ok || bad "S2c: STATE_BACKUP=0 alerted"
touch "$T/h/flags/state-backup-off"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S2c: flags/state-backup-off exited $RC, want 0"
[ "$(grep -c 'not configured' "$LOG" 2>/dev/null)" -eq 2 ] \
  && ok || bad "S2c: flags/state-backup-off must stop before the config check"

# ── S2e: the keys land, and the unconfigured markers go with them ───────────
# The per-day marker is the ONLY evidence bin/lib/backup-freshness.sh (#399) has
# that the BACKUP_* keys are still a handoff, and that state never pages. Left
# lying after the keys land it latches the box: the Fleet screen keeps saying
# "backup not configured" about a box whose uploader is failing, and the
# backup-missing alert can never fire. Cleared before anything is staged, so a
# configured run that then FAILS still leaves the truth behind.
mkfix
touch "$T/h/state/state-backup-unconfigured-20260901" \
      "$T/h/state/state-backup-unconfigured-20260915"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S2e: the configured run exited $RC, want 0 ($(tail -3 "$T/run.out"))"
LEFT=$(find "$T/h/state" -maxdepth 1 -name 'state-backup-unconfigured-*' 2>/dev/null)
[ -z "$LEFT" ] \
  && ok || bad "S2e: a configured run must clear the unconfigured markers, left: $LEFT"
# ...and an unconfigured box still writes one, so the silent state stays sayable.
mkfix
grep -v '^BACKUP_AGE_RECIPIENT=' "$T/h/env/global.env" > "$T/h/env/global.env.new"
mv "$T/h/env/global.env.new" "$T/h/env/global.env"
run; RC=$?
[ -n "$(find "$T/h/state" -maxdepth 1 -name 'state-backup-unconfigured-*' 2>/dev/null)" ] \
  && ok || bad "S2e: an unconfigured box must still write its per-day marker (rc=$RC)"
# ...but it does not HOARD them. One marker per UTC day is the ALERTS dedupe;
# the older ones are litter (a box left unconfigured for a year carries 365 of
# them) and no reader ever looks past the freshest. The sweep sits outside the
# once-a-day `if`, so it runs on the ticks that write nothing — which is why
# today's marker already exists here.
touch "$T/h/state/state-backup-unconfigured-20260101" \
      "$T/h/state/state-backup-unconfigured-20260902"
run; RC=$?
LEFT=$(find "$T/h/state" -maxdepth 1 -name 'state-backup-unconfigured-*' 2>/dev/null | sort | tr '\n' ' ')
[ "$LEFT" = "$T/h/state/state-backup-unconfigured-20260915 " ] \
  && ok || bad "S2f: an unconfigured run must keep today's marker and sweep the rest (rc=$RC, left: $LEFT)"

# ── S2c-clock: no usable timestamp, no key ──────────────────────────────────
# An unparseable BACKUP_NOW or a mute box clock would otherwise name the object
# "<box>/.tar.zst" and overwrite the same key every run. The guard fires before
# the lock, before the config check and before one byte is staged, so the proof
# is: rc 1, one actionable ALERTS line naming the stage, not a single call to
# the bucket, nothing landed and nothing stamped.
mkfix
run BACKUP_NOW=notanumber; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S2c-clock: an unusable BACKUP_NOW exited $RC, want 1 ($(tail -3 "$T/run.out"))"
NAL=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
[ "$NAL" -eq 1 ] && ok || bad "S2c-clock: expected one ALERTS line, got $NAL: $(cat "$ALOG")"
ALINE=$(grep '\[state-backup\]' "$ALOG")
grep -q 'clock FAILED' <<<"$ALINE" \
  && ok || bad "S2c-clock: the alert does not name the clock stage: $ALINE"
grep -q 'last good off-box copy: never$' <<<"$ALINE" \
  && ok || bad "S2c-clock: the alert does not end with the last good copy: $ALINE"
[ ! -s "$CALLS" ] \
  && ok || bad "S2c-clock: it called the bucket without a timestamp: $(cat "$CALLS" 2>/dev/null)"
[ "$(objects)" -eq 0 ] \
  && ok || bad "S2c-clock: something landed: $(find "$T/s3/bkt" -type f 2>/dev/null)"
[ ! -f "$T/h/state/backup-last.json" ] \
  && ok || bad "S2c-clock: it stamped a copy it never made: $(cat "$T/h/state/backup-last.json" 2>/dev/null)"

# ── S3: retention ───────────────────────────────────────────────────────────
# 864 objects every 15 minutes back from NOW (9 days), plus 1100 past the
# 30-day line so the 1000-key batching is really exercised, plus six keys the
# matcher must never touch.
mkfix
mkdir -p "$T/s3/bkt/small" "$T/s3/bkt/smallx" "$T/s3/bkt/hub-old"
{
  k=1;  while [ "$k" -le 864 ];  do printf '@%s\n' "$((NOW - k * 900))"; k=$((k + 1)); done
  j=0;  while [ "$j" -le 1099 ]; do printf '@%s\n' "$((NOW - 2592000 - j * 900))"; j=$((j + 1)); done
} > "$T/seed-epochs"
date -u -f "$T/seed-epochs" +%Y%m%dT%H%M%SZ > "$T/seed-ts"
while IFS= read -r ts; do : > "$T/s3/bkt/small/$ts.tar.zst"; done < "$T/seed-ts"
for foreign in small/notes.txt small/2026090T0000Z.tar.zst \
               small/20260901T000000Z.tar.zst.tmp small/20261001T000000Z.tar.zst \
               smallx/20260901T000000Z.tar.zst hub-old/20260901T000000Z.tar.zst; do
  : > "$T/s3/bkt/$foreign"
done
SEEDED=$(objects)
[ "$SEEDED" -eq 1970 ] && ok || bad "S3: seeded $SEEDED objects, want 1970"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3: the prune run exited $RC ($(tail -3 "$T/run.out"))"

[ -f "$T/s3/bkt/$KEY" ] && ok || bad "S3: the run pruned the object it had just uploaded"
[ -f "$T/s3/bkt/small/20260908T000500Z.tar.zst" ] \
  && ok || bad "S3: the earliest object of 09-08 must survive the thinning"
[ -f "$T/s3/bkt/small/20260907T000500Z.tar.zst" ] \
  && ok || bad "S3: the earliest object of 09-07 must survive the thinning"
[ -f "$T/s3/bkt/small/20260906T232000Z.tar.zst" ] \
  && ok || bad "S3: the earliest object of 09-06 must survive the thinning"
[ -f "$T/s3/bkt/small/20260908T002000Z.tar.zst" ] \
  && bad "S3: a later object of 09-08 survived the thinning" || ok
[ -f "$T/s3/bkt/small/20260907T235000Z.tar.zst" ] \
  && bad "S3: a later object of 09-07 survived the thinning" || ok
# the youngest and the oldest of the keep-all zone, and its first casualty
[ -f "$T/s3/bkt/small/20260915T230500Z.tar.zst" ] \
  && ok || bad "S3: the newest object under the keep-all line was deleted"
[ -f "$T/s3/bkt/small/20260908T233500Z.tar.zst" ] \
  && ok || bad "S3: the object 6d23h45m old - the last one under the keep-all line - was deleted"
[ -f "$T/s3/bkt/small/20260908T232000Z.tar.zst" ] \
  && bad "S3: the object exactly 7 days old belongs to the thinned zone and was kept whole" || ok
for foreign in small/notes.txt small/2026090T0000Z.tar.zst \
               small/20260901T000000Z.tar.zst.tmp small/20261001T000000Z.tar.zst \
               smallx/20260901T000000Z.tar.zst hub-old/20260901T000000Z.tar.zst; do
  [ -f "$T/s3/bkt/$foreign" ] && ok || bad "S3: the matcher deleted $foreign"
done
LEFT=$(objects)
[ "$LEFT" -eq 681 ] && ok || bad "S3: $LEFT objects left, want 681"
[ "$(verb_count delete-objects)" -eq 2 ] \
  && ok || bad "S3: $(verb_count delete-objects) delete-objects calls, want 2"
B1=$(grep 'delete-objects' "$CALLS" | sed -n 1p | grep -o '"Key"' | wc -l)
B2=$(grep 'delete-objects' "$CALLS" | sed -n 2p | grep -o '"Key"' | wc -l)
[ "$B1" -eq 1000 ] && ok || bad "S3: first delete batch had $B1 keys, want 1000"
[ "$B2" -eq 290 ] && ok || bad "S3: second delete batch had $B2 keys, want 290"
grep -q 'pruned 1290' "$LOG" 2>/dev/null \
  && ok || bad "S3: the log does not report 1290 pruned: $(grep prune "$LOG" 2>/dev/null)"
# A prune where every batch succeeded is silent. The bucket answers a quiet
# DeleteObjects success with an empty body, and reading that silence as a failed
# batch would put a false line in ALERTS on every run from day 7 on.
grep -q 'prune batch failed' "$LOG" 2>/dev/null \
  && bad "S3: a successful prune was logged as a failed batch: $(grep prune "$LOG" 2>/dev/null)" || ok
[ "$(cat "$ALOG")" = "$SEEDALERT" ] \
  && ok || bad "S3: a successful prune wrote to ALERTS.log: $(cat "$ALOG")"

# negative: the listing fails, so nothing is pruned and the backup still stands
mkfix
mkdir -p "$T/s3/bkt/small"
: > "$T/s3/bkt/small/20260701T000000Z.tar.zst"
: > "$T/s3/bkt/small/20260702T000000Z.tar.zst"
touch "$T/s3/fail-list"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3: a failed listing exited $RC, want 0"
grep -q 'prune skipped' "$LOG" 2>/dev/null \
  && ok || bad "S3: a failed listing must say so: $(cat "$LOG" 2>/dev/null)"
[ -f "$T/s3/bkt/small/20260701T000000Z.tar.zst" ] && [ -f "$T/s3/bkt/small/20260702T000000Z.tar.zst" ] \
  && ok || bad "S3: a failed listing deleted something anyway"
[ "$(jq -r .key "$T/h/state/backup-last.json" 2>/dev/null)" = "$KEY" ] \
  && ok || bad "S3: the backup itself must still be stamped when the prune is skipped"
[ "$(verb_count delete-objects)" -eq 0 ] && ok || bad "S3: it deleted after a failed listing"

# ── S3b: the bucket refuses a delete batch ──────────────────────────────────
# The tarball is already up and stamped, so the run still ends 0. What it must
# not do is count the refused keys as pruned: the log says what really went and
# ALERTS carries the refusal.
mkfix
mkdir -p "$T/s3/bkt/small"
{ k=0; while [ "$k" -le 4 ]; do printf '@%s\n' "$((NOW - 3456000 - k * 900))"; k=$((k + 1)); done; } \
  > "$T/seed-epochs"          # 40 days old: every one of them is past the delete line
date -u -f "$T/seed-epochs" +%Y%m%dT%H%M%SZ > "$T/seed-ts"
while IFS= read -r ts; do : > "$T/s3/bkt/small/$ts.tar.zst"; done < "$T/seed-ts"
touch "$T/s3/fail-delete"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3b: a refused delete batch exited $RC, want 0 - the backup itself landed"
[ "$(verb_count delete-objects)" -eq 1 ] \
  && ok || bad "S3b: $(verb_count delete-objects) delete-objects calls, want 1"
[ "$(objects)" -eq 6 ] && ok || bad "S3b: $(objects) objects left, want 6 - a refused batch removes nothing"
grep -q 'prune batch failed: delete-objects rc=0 errors=5 keys=5' "$LOG" 2>/dev/null \
  && ok || bad "S3b: the log does not name the refused batch: $(grep prune "$LOG" 2>/dev/null)"
grep -q 'pruned 0 kept 0' "$LOG" 2>/dev/null \
  && ok || bad "S3b: refused keys were counted as pruned: $(grep pruned "$LOG" 2>/dev/null)"
NAL=$(grep -c '\[state-backup\]' "$ALOG" 2>/dev/null)
[ "$NAL" -eq 1 ] && ok || bad "S3b: expected one ALERTS line, got $NAL: $(cat "$ALOG")"
ALINE=$(grep '\[state-backup\]' "$ALOG")
grep -q 'prune FAILED' <<<"$ALINE" \
  && ok || bad "S3b: the alert does not name the prune stage: $ALINE"
[ "$(jq -r .key "$T/h/state/backup-last.json" 2>/dev/null)" = "$KEY" ] \
  && ok || bad "S3b: the backup must still be stamped when a delete batch is refused"

echo "state-backup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
