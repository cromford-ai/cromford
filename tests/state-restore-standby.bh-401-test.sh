#!/bin/bash
# tests/state-restore-standby.bh-401-test.sh — bin/state-restore.sh --standby,
# the 15-minute state stream a standby box runs against its hub's newest R2
# tarball (#1923, part of #401). Scratch roots, a fake S3 (a directory tree
# behind an `aws s3api` stand-in), a curl stand-in that records what would have
# been POSTed, and the REAL bin/state-backup.sh + bin/restore-merge.sh on either
# side. Nothing here touches a real box, a real bucket or the real watchdog.
#
# What is proved here:
#   M1   --standby without --apply, without a ts, or with a --dest outside
#        $H/tmp/ (it deletes its own run dirs) is a usage error (rc 2) and
#        makes no bucket call;
#   G1   --standby refuses (rc 1, zero bucket calls, live tree unchanged, no
#        watermark, nothing reported) on <hub> itself, on a box whose
#        hub-lease.sh check says it holds the lease, on a live cache saying
#        held=1, and when live state/standby-of names another box; a
#        standby-of naming <hub> streams;
#   S7   --standby without an identity: rc 1, BACKUP_AGE_IDENTITY_FILE named,
#        zero bucket calls, nothing reported;
#   S3   live gains the snapshot's env/, state/ and orchestrator/ files, and live
#        logs/ and builds/ are byte-identical before and after;
#   S4   a snapshot ALERTS.log longer than live's leaves live's ALERTS.log AND
#        flags/.alerts-cursor byte-identical;
#   S5   the hub's identity files (box-id, box-name, hub-lease*, standby-of,
#        standby-stream.json) never land; live's own box-id is untouched;
#   MODE the default dest is $H/tmp/standby-restore, mode 700, and meta/ is not
#        printed;
#   S6a  success removes the per-run dir and writes the watermark
#        {of, snapshot, key, rc:0, at};
#   S6c  a re-run on the same snapshot is `up to date <ts>`, rc 0, NO get-object,
#        and it re-reports; a watermark for a different hub is not up to date;
#   S6b  two failures on distinct snapshots leave exactly ONE *.failed, and a
#        same-snapshot retry over a leftover run dir is not `already pulled`;
#   S12  every run passing the configured check reports {of, snapshot, ok} to
#        /api/standby/<self>; a failed run says ok:false; a curl that fails
#        changes no rc; no secret reaches stdout; an unset secret skips out loud.
# Run from anywhere: tests/state-restore-standby.bh-401-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW1=1789514400             # 2026-09-15T23:20:00Z
TS1=20260915T232000Z
TS2=20260915T233500Z        # a newer, corrupt object for the second failure
CANARY=leakcanary-4011      # stands in for every secret; must never reach stdout
WDSECRET=wdsecret-fixture-4011

mkdir -p "$T/fakebin"
touch "$T/curl.log"

# ── the tools: real when the box has them, stand-ins when it does not ────────
# Copied in the style of tests/state-restore.bh-449-test.sh (not sourced).
if ! command -v age >/dev/null 2>&1; then
  cat > "$T/fakebin/age" <<'SH'
#!/bin/bash
# age stand-in: base64 in place of the cipher; -d checks the identity.
if [ "${1:-}" = "-d" ]; then
  shift; ID=""; FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in -i) ID="${2:-}"; shift 2 ;; -*) shift ;; *) FILE="$1"; shift ;; esac
  done
  if [ -n "$ID" ] && ! grep -qx 'stand-in-key-material-not-a-real-identity' "$ID" 2>/dev/null; then
    echo "age: no identity matched any of the recipients" >&2; exit 1
  fi
  if [ -n "$FILE" ]; then exec base64 -d -- "$FILE"; fi
  exec base64 -d
fi
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
  printf '#!/bin/bash\nexec cat\n' > "$T/fakebin/zstd"
  chmod +x "$T/fakebin/zstd"
fi
printf '#!/bin/bash\necho "*/15 * * * * true"\n' > "$T/fakebin/crontab"
printf '#!/bin/bash\necho 0000000000000000000000000000000000000000\n' > "$T/fakebin/git"
chmod +x "$T/fakebin/crontab" "$T/fakebin/git"

# curl stand-in: every argv (one per line, then a blank line) to $T/curl.log,
# the --data body to $T/curl.body (last call wins), exits $CURL_RC.
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
printf '%s\n' "\$@" >> "$T/curl.log"; echo >> "$T/curl.log"
while [ \$# -gt 0 ]; do
  case "\$1" in --data) printf '%s\n' "\${2:-}" > "$T/curl.body"; shift 2 ;; *) shift ;; esac
done
exit "\${CURL_RC:-0}"
SH
chmod +x "$T/fakebin/curl"

# ── the fake S3: put-object, head-object, list-objects-v2, get-object ────────
cat > "$T/fakebin/aws" <<SH
#!/bin/bash
S3ROOT="$T/s3"; S3META="$T/s3meta"
mkdir -p "\$S3ROOT" "\$S3META"
printf '%s\n' "\$*" >> "\$S3ROOT/calls.log"
VERB=""
if [ "\${1:-}" = s3api ]; then VERB="\${2:-}"; shift 2; fi
BUCKET=""; KEY=""; BODY=""; PREFIX=""; META=""; OUTFILE=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --bucket) BUCKET="\$2"; shift 2 ;;
    --key) KEY="\$2"; shift 2 ;;
    --body) BODY="\$2"; shift 2 ;;
    --prefix) PREFIX="\$2"; shift 2 ;;
    --metadata) META="\$2"; shift 2 ;;
    --endpoint-url|--output|--region|--continuation-token) shift 2 ;;
    --*) shift ;;
    *) OUTFILE="\$1"; shift ;;
  esac
done
case "\$VERB" in
  put-object)
    mkdir -p "\$(dirname "\$S3ROOT/\$BUCKET/\$KEY")" "\$(dirname "\$S3META/\$BUCKET/\$KEY")"
    cp "\$BODY" "\$S3ROOT/\$BUCKET/\$KEY" || exit 253
    printf '%s\n' "\${META#sha256=}" > "\$S3META/\$BUCKET/\$KEY"
    printf '{"ETag":"stub"}\n' ;;
  head-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    printf '{"ContentLength":%s,"Metadata":{"sha256":"%s"}}\n' \
      "\$(stat -c%s "\$S3ROOT/\$BUCKET/\$KEY")" "\$(cat "\$S3META/\$BUCKET/\$KEY" 2>/dev/null)" ;;
  list-objects-v2)
    [ -d "\$S3ROOT/\$BUCKET" ] || { printf '{"Contents":[]}\n'; exit 0; }
    find "\$S3ROOT/\$BUCKET" -type f -printf '%s\t%P\n' \
      | awk -F'\t' -v p="\$PREFIX" 'index(\$2, p) == 1' | LC_ALL=C sort -k2 \
      | jq -R -n -c '{Contents: [inputs | split("\t") | {Key: .[1], Size: (.[0] | tonumber)}]}' ;;
  get-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    cp "\$S3ROOT/\$BUCKET/\$KEY" "\$OUTFILE" || exit 253
    printf '{"ContentLength":%s}\n' "\$(stat -c%s "\$OUTFILE")" ;;
  *) exit 252 ;;
esac
SH
chmod +x "$T/fakebin/aws"
CALLS="$T/s3/calls.log"
gets() { grep -c '^s3api get-object' "$CALLS" 2>/dev/null || true; }
calls_now() { wc -l < "$CALLS" 2>/dev/null || echo 0; }
curls() { grep -c '^-X$' "$T/curl.log" 2>/dev/null || true; }

AGEPUB=$(PATH="$T/fakebin:$PATH" age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
[ -n "$AGEPUB" ] && ok || bad "setup: age-keygen gave no public key"

# ── the HUB and its object, made by the production uploader ─────────────────
S3ENV=$(printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\nBACKUP_S3_BUCKET=bkt\nBACKUP_S3_ACCESS_KEY_ID=akid-canary-4011\nBACKUP_S3_SECRET_ACCESS_KEY=sak-canary-4011\n')
mkdir -p "$T/hub/env/tokens.d" "$T/hub/state" "$T/hub/logs" "$T/hub/flags" "$T/hub/builds/b" \
         "$T/hub-orch" "$T/checkout" "$T/s3"
{ printf '%s\n' "$S3ENV"; printf 'HARNESS_SECRET=%s\nBACKUP_AGE_RECIPIENT=%s\n' "$CANARY" "$AGEPUB"; } \
  > "$T/hub/env/global.env"
printf '%s\n' "$CANARY" > "$T/hub/env/tokens.d/x"
printf 'hub\n' > "$T/hub/state/box-id"
printf 'box-hub\n' > "$T/hub/state/box-name"
printf '{"holder":"hub"}\n' > "$T/hub/state/hub-lease.json"
printf '1789514000\n' > "$T/hub/state/hub-lease-failing-since"
printf 'someone\n' > "$T/hub/state/standby-of"
printf '{"of":"x","snapshot":"y","rc":0}\n' > "$T/hub/state/standby-stream.json"
printf '{"hub":"state"}\n' > "$T/hub/state/x.json"
printf 'hub a.log line\n' > "$T/hub/logs/a.log"
printf 'hub alert one\nhub alert two\nhub alert three\n' > "$T/hub/logs/ALERTS.log"
printf '9999\n' > "$T/hub/flags/.alerts-cursor"
printf 'hub RESULT\n' > "$T/hub/builds/b/RESULT"
printf 'orchestrator payload\n' > "$T/hub-orch/o.txt"
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/hub" HARNESS_CHECKOUT="$T/checkout" \
    ORCHESTRATOR_DIR="$T/hub-orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW1" \
    bash "$DIR/bin/state-backup.sh" > "$T/backup.out" 2>&1
BRC=$?
[ "$BRC" -eq 0 ] && ok || bad "setup: bin/state-backup.sh exited $BRC ($(tail -3 "$T/backup.out"))"
OBJ1="$T/s3/bkt/hub/$TS1.tar.zst"
[ -f "$OBJ1" ] && ok || bad "setup: no object at hub/$TS1.tar.zst"
cp "$OBJ1" "$T/pristine1"

# ── the STANDBY's own harness root and live trees ───────────────────────────
SB="$T/sb"
mkdir -p "$SB/env"
printf '%s\n' "$S3ENV" > "$SB/env/global.env"
printf '%s\n' "$WDSECRET" > "$SB/env/.watchdog-secret"
DEST="$SB/tmp/standby-restore"

mklive() { # mklive <live> <orch>
  mkdir -p "$1/logs" "$1/flags" "$1/state" "$1/builds/own" "$1/env" "$2"
  printf 'standby alert\n' > "$1/logs/ALERTS.log"
  printf '5\n' > "$1/flags/.alerts-cursor"
  printf 'standby own log\n' > "$1/logs/own.log"
  printf 'standby RESULT\n' > "$1/builds/own/RESULT"
  printf 'standby-box\n' > "$1/state/box-id"
}
tree_hashes() { find "$@" -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum 2>/dev/null; }

# The production entry point, driven as the standby's cron would drive it.
rs() {
  env -u HARNESS_SECRET PATH="$T/fakebin:$PATH" HARNESS_ROOT="$SB" ETC_HARNESS_ENV="$T/no-such-etc" \
      BOX_NAME="${RS_BOX:-standby-box}" WATCHDOG_URL=https://wd.test.invalid CURL_RC="${CURL_RC:-0}" \
      bash "$DIR/bin/state-restore.sh" "$@" > "$T/rs.out" 2>&1
}

# ── M1: usage ───────────────────────────────────────────────────────────────
mklive "$T/l0" "$T/o0"
C0=$(calls_now)
rs hub latest --standby --identity "$T/age.key" --live "$T/l0" --orchestrator-live "$T/o0"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "M1: --standby without --apply exited $RC, want 2"
rs hub --standby --apply --identity "$T/age.key" --live "$T/l0" --orchestrator-live "$T/o0"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "M1: --standby without a ts exited $RC, want 2"
rs hub latest --apply --standby --identity "$T/age.key" --dest "$T/elsewhere" --live "$T/l0" --orchestrator-live "$T/o0"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "M1: --standby --dest outside \$H/tmp/ exited $RC, want 2"
[ ! -e "$T/elsewhere" ] && ok || bad "M1: a refused --standby --dest was created"
[ "$(calls_now)" = "$C0" ] && ok || bad "M1: a usage error called the bucket"

# ── S7: no identity ─────────────────────────────────────────────────────────
C0=$(calls_now)
rs hub latest --apply --standby --live "$T/l0" --orchestrator-live "$T/o0"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S7: no identity exited $RC, want 1 ($(cat "$T/rs.out"))"
grep -q 'not configured - missing: BACKUP_AGE_IDENTITY_FILE' "$T/rs.out" \
  && ok || bad "S7: the refusal does not name BACKUP_AGE_IDENTITY_FILE: $(cat "$T/rs.out")"
[ "$(calls_now)" = "$C0" ] && ok || bad "S7: an identity-less standby called the bucket"
[ ! -s "$T/curl.log" ] && ok || bad "S7: an unconfigured standby reported to the watchdog"
[ ! -e "$T/l0/state/standby-stream.json" ] && ok || bad "S7: an unconfigured standby wrote a watermark"

# ── G1: never into the hub, a lease holder, or another box's standby ────────
# state/standby-of AS bin/standby-install.sh WRITES IT: "<hub-name> <hub-id>".
# The format is lifted from the installer's own write statement, so a change
# there changes this fixture (and a missing statement fails here, loudly);
# tests/standby-install.bh-401-test.sh S9 pins its output as "box-hub hub".
SBFMT=$(sed -n "s/^printf '\\([^']*\\)' \"\\\$HUB_NAME\" \"\\\$HUB_ID\".*/\\1/p" "$DIR/bin/standby-install.sh")
[ -n "$SBFMT" ] && ok || bad "G1: bin/standby-install.sh no longer writes state/standby-of as printf '<fmt>' \"\$HUB_NAME\" \"\$HUB_ID\""
sbof() { # sbof <file> <hub-name> <hub-id> — written exactly as the installer writes it
  # shellcheck disable=SC2059  # the format IS the installer's
  printf "$SBFMT" "$2" "$3" > "$1"
}
g1() { # g1 <label> <live> [rs args...]: a refusal that touched nothing
  local label="$1" live="$2" pre c0 k0 rc; shift 2
  pre=$(tree_hashes "$live"); c0=$(calls_now); k0=$(curls)
  rs "$@" --live "$live" --orchestrator-live "$T/og"; rc=$?
  [ "$rc" -eq 1 ] && ok || bad "G1 $label: exited $rc, want 1 ($(cat "$T/rs.out"))"
  [ "$(grep -c . "$T/rs.out")" -eq 1 ] && grep -q '^REFUSED: --standby' "$T/rs.out" \
    && ok || bad "G1 $label: not one REFUSED line: $(cat "$T/rs.out")"
  [ "$(calls_now)" = "$c0" ] && ok || bad "G1 $label: called the bucket"
  [ "$(curls)" = "$k0" ] && ok || bad "G1 $label: reported to the watchdog"
  [ "$(tree_hashes "$live")" = "$pre" ] && ok || bad "G1 $label: the live tree changed"
}
mklive "$T/lg" "$T/og"
RS_BOX=hub g1 "self" "$T/lg" hub latest --apply --standby --identity "$T/age.key"
mkdir -p "$SB/state"
printf '{"holder":"standby-box","held":1,"fetched_at":%s}\n' "$NOW1" > "$SB/state/hub-lease.json"
HUB_LEASE_NOW="$NOW1" HUB_LEASE_EPOCH_CHECK=0 \
  g1 "hub-lease check" "$T/lg" hub latest --apply --standby --identity "$T/age.key"
rm -f "$SB/state/hub-lease.json"
printf '{"holder":"standby-box","held":1}\n' > "$T/lg/state/hub-lease.json"
g1 "lease cache" "$T/lg" hub latest --apply --standby --identity "$T/age.key"
rm -f "$T/lg/state/hub-lease.json"
sbof "$T/lg/state/standby-of" box-9 other-hub
g1 "standby-of" "$T/lg" hub latest --apply --standby --identity "$T/age.key"
# The self leg against the HUB NAME: the installer's cron passes the hub ID as
# <box>, so a box whose own name is the hub name standby-of lists IS that hub.
sbof "$T/lg/state/standby-of" box-hub hub
RS_BOX=box-hub g1 "self by hub name" "$T/lg" hub latest --apply --standby --identity "$T/age.key"
rm -f "$T/lg/state/standby-of"

# ── S3 / S4 / S5 / MODE / S6a: the first stream run ─────────────────────────
mklive "$T/l1" "$T/o1"
LB=$(tree_hashes "$T/l1/logs" "$T/l1/builds")
cp "$T/l1/logs/ALERTS.log" "$T/pre-alerts"; cp "$T/l1/flags/.alerts-cursor" "$T/pre-cursor"
cp "$T/l1/state/box-id" "$T/pre-boxid"
G0=$(gets)
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3: the stream run exited $RC ($(tail -8 "$T/rs.out"))"
[ "$(gets)" -eq $((G0 + 1)) ] && ok || bad "S3: the stream run did not pull exactly once"
# S3
[ -f "$T/l1/env/tokens.d/x" ] && ok || bad "S3: env/tokens.d/x did not land"
[ "$(cat "$T/l1/state/x.json" 2>/dev/null)" = '{"hub":"state"}' ] && ok || bad "S3: state/x.json did not land"
[ -f "$T/o1/o.txt" ] && ok || bad "S3: orchestrator/o.txt did not land"
[ ! -e "$T/l1/logs/a.log" ] && ok || bad "S3: the hub's logs/a.log landed in live"
[ ! -e "$T/l1/builds/b" ] && ok || bad "S3: the hub's builds/b landed in live"
[ "$(tree_hashes "$T/l1/logs" "$T/l1/builds")" = "$LB" ] && ok || bad "S3: live logs/ or builds/ changed"
# S4
cmp -s "$T/l1/logs/ALERTS.log" "$T/pre-alerts" && ok || bad "S4: live ALERTS.log changed: $(cat "$T/l1/logs/ALERTS.log")"
cmp -s "$T/l1/flags/.alerts-cursor" "$T/pre-cursor" \
  && ok || bad "S4: live flags/.alerts-cursor changed to $(cat "$T/l1/flags/.alerts-cursor")"
grep -q '^CURSOR flags/.alerts-cursor ->' "$T/rs.out" && bad "S4: restore-merge rewrote the cursor" || ok
# S5
cmp -s "$T/l1/state/box-id" "$T/pre-boxid" && ok || bad "S5: live state/box-id is $(cat "$T/l1/state/box-id")"
for f in box-name hub-lease.json hub-lease-failing-since standby-of; do
  [ ! -e "$T/l1/state/$f" ] && ok || bad "S5: the hub's state/$f landed in live"
done
[ "$(jq -r .of "$T/l1/state/standby-stream.json" 2>/dev/null)" = hub ] \
  && ok || bad "S5: the hub's standby-stream.json replaced the standby's watermark"
# MODE
[ "$(stat -c %a "$DEST" 2>/dev/null)" = 700 ] && ok || bad "MODE: $DEST is mode $(stat -c %a "$DEST" 2>/dev/null), want 700"
grep -q -- '--- meta/' "$T/rs.out" && bad "MODE: meta/ was printed in standby mode" || ok
grep -q 'pruned tree to env/ state/ orchestrator/' "$T/rs.out" && ok || bad "S3: no prune line"
# S6a
[ ! -e "$DEST/hub/$TS1" ] && ok || bad "S6a: the run dir $DEST/hub/$TS1 survived a success"
W="$T/l1/state/standby-stream.json"
[ "$(jq -r '[.of,.snapshot,.key,(.rc|tostring)]|join(" ")' "$W" 2>/dev/null)" = "hub $TS1 hub/$TS1.tar.zst 0" ] \
  && ok || bad "S6a: watermark is $(cat "$W" 2>/dev/null)"
[ -n "$(jq -r '.at // empty' "$W" 2>/dev/null)" ] && ok || bad "S6a: watermark has no .at"
# S12 on success
[ "$(jq -c '[.of,.snapshot,.ok]' "$T/curl.body" 2>/dev/null)" = "[\"hub\",\"$TS1\",true]" ] \
  && ok || bad "S12: the success report body is $(cat "$T/curl.body" 2>/dev/null)"
grep -qx "https://wd.test.invalid/api/standby/standby-box" "$T/curl.log" \
  && ok || bad "S12: the report URL is wrong: $(grep http "$T/curl.log")"
grep -qE "$CANARY|$WDSECRET|sak-canary" "$T/rs.out" && bad "S12: a secret reached stdout" || ok

# ── S6c: up to date ─────────────────────────────────────────────────────────
G0=$(gets); K0=$(curls)
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S6c: the up-to-date re-run exited $RC ($(tail -3 "$T/rs.out"))"
grep -qx "up to date $TS1" "$T/rs.out" && ok || bad "S6c: no 'up to date $TS1': $(cat "$T/rs.out")"
[ "$(gets)" = "$G0" ] && ok || bad "S6c: the up-to-date re-run called get-object"
[ "$(curls)" -eq $((K0 + 1)) ] && ok || bad "S6c: the up-to-date re-run did not re-report"
[ "$(jq -c .ok "$T/curl.body" 2>/dev/null)" = true ] && ok || bad "S6c: the re-report is not ok:true"

# ── ENV: OUT/TS/KEY exported by the caller never reach the EXIT trap ────────
# OUT is an rm -rf target: an early exit (up to date, no backups) must not act
# on an inherited path, and an inherited TS/KEY must not be reported.
mkdir -p "$T/victim"; printf 'keep\n' > "$T/victim/precious"
OUT="$T/victim" TS=19990101T000000Z KEY=bogus/key \
  rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
[ "$RC" -eq 0 ] && grep -qx "up to date $TS1" "$T/rs.out" && ok || bad "ENV: the up-to-date run exited $RC ($(cat "$T/rs.out"))"
[ -f "$T/victim/precious" ] && ok || bad "ENV: an up-to-date run deleted an inherited \$OUT"
mklive "$T/l3" "$T/o3"
OUT="$T/victim" TS=19990101T000000Z KEY=bogus/key \
  rs nobody latest --apply --standby --identity "$T/age.key" --live "$T/l3" --orchestrator-live "$T/o3"; RC=$?
[ "$RC" -eq 1 ] && grep -q 'no backups for nobody' "$T/rs.out" && ok || bad "ENV: the no-backups run exited $RC ($(cat "$T/rs.out"))"
[ -f "$T/victim/precious" ] && ok || bad "ENV: a no-backups run deleted an inherited \$OUT"
[ ! -e "$T/victim.failed" ] && ok || bad "ENV: a no-backups run moved an inherited \$OUT to .failed"
[ "$(jq -r '[.snapshot,.key]|join("|")' "$T/l3/state/standby-stream.json" 2>/dev/null)" = "|" ] \
  && ok || bad "ENV: the no-backups watermark carries an inherited TS/KEY: $(cat "$T/l3/state/standby-stream.json" 2>/dev/null)"
[ "$(jq -r .snapshot "$T/curl.body" 2>/dev/null)" = "" ] && ok || bad "ENV: the no-backups report names an inherited TS: $(cat "$T/curl.body")"

# a watermark for another hub (the stream was re-pointed) is NOT up to date
jq '.of = "other-hub"' "$W" > "$W.x" && mv "$W.x" "$W"
G0=$(gets)
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S6c: the re-pointed run exited $RC"
[ "$(gets)" -eq $((G0 + 1)) ] && ok || bad "S6c: a watermark for another hub skipped the pull"
# a watermark that is only a PREFIX of the snapshot id is NOT up to date
jq --arg s "${TS1%Z}" '.snapshot = $s' "$W" > "$W.x" && mv "$W.x" "$W"
G0=$(gets)
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l1" --orchestrator-live "$T/o1"
[ "$(gets)" -eq $((G0 + 1)) ] && ok || bad "S6c: a prefix-matching watermark skipped the pull"

# ── S6b / S12: failures ─────────────────────────────────────────────────────
mklive "$T/l2" "$T/o2"
W2="$T/l2/state/standby-stream.json"
printf 'x' >> "$OBJ1"                                   # sha256 mismatch on TS1
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l2" --orchestrator-live "$T/o2"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S6b: a tampered object exited $RC, want 1"
grep -q 'REFUSED: sha256 mismatch' "$T/rs.out" && ok || bad "S6b: no sha256 refusal: $(cat "$T/rs.out")"
[ -d "$DEST/hub/$TS1.failed" ] && ok || bad "S6b: the failed run was not kept as $TS1.failed"
[ "$(jq -r .rc "$W2" 2>/dev/null)" = 1 ] && ok || bad "S12: watermark rc after a failure is $(jq -r .rc "$W2" 2>/dev/null), want 1"
[ "$(jq -c '[.of,.snapshot,.ok]' "$T/curl.body" 2>/dev/null)" = "[\"hub\",\"$TS1\",false]" ] \
  && ok || bad "S12: the failure report body is $(cat "$T/curl.body" 2>/dev/null)"
# the same failure with a curl that fails: rc unchanged
CURL_RC=7 rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l2" --orchestrator-live "$T/o2"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S12: a failed run with a failing curl exited $RC, want 1"
grep -q 'standby report failed (fail-open)' "$T/rs.out" && ok || bad "S12: a failed report was not said"
cp "$T/pristine1" "$OBJ1"

# a second failure on a DISTINCT, newer snapshot: a corrupt tarball whose
# stored sha256 matches, so it fails at extraction, not at the checksum
head -c 4096 /dev/urandom > "$T/s3/bkt/hub/$TS2.tar.zst"
sha256sum "$T/s3/bkt/hub/$TS2.tar.zst" | cut -d' ' -f1 > "$T/s3meta/bkt/hub/$TS2.tar.zst"
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l2" --orchestrator-live "$T/o2"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "S6b: a corrupt tarball exited $RC, want 1 ($(tail -3 "$T/rs.out"))"
grep -q 'REFUSED: tar rc=' "$T/rs.out" && ok || bad "S6b: no tar refusal: $(cat "$T/rs.out")"
NF=$(find "$DEST/hub" -mindepth 1 -maxdepth 1 -name '*.failed' | wc -l)
[ "$NF" -eq 1 ] && ok || bad "S6b: $NF *.failed dirs after two failures, want 1"
[ -d "$DEST/hub/$TS2.failed" ] && ok || bad "S6b: the kept *.failed is not the latest failure"
[ "$(jq -r .snapshot "$W2" 2>/dev/null)" = "$TS2" ] && ok || bad "S6b: the watermark does not name $TS2"
rm -f "$T/s3/bkt/hub/$TS2.tar.zst" "$T/s3meta/bkt/hub/$TS2.tar.zst"

# a same-snapshot retry after a failure, over a leftover run dir (a killed
# earlier run), pulls again and is not refused as already pulled
mkdir -p "$DEST/hub/$TS1/tree"
jq '.snapshot = "'"$TS1"'" | .rc = 1' "$W2" > "$W2.x" && mv "$W2.x" "$W2"
G0=$(gets)
rs hub "$TS1" --apply --standby --identity "$T/age.key" --live "$T/l2" --orchestrator-live "$T/o2"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S6b: the retry exited $RC ($(tail -5 "$T/rs.out"))"
grep -q 'already pulled' "$T/rs.out" && bad "S6b: the retry was refused as already pulled" || ok
[ "$(gets)" -eq $((G0 + 1)) ] && ok || bad "S6b: a watermark with rc 1 skipped the pull"
[ "$(jq -r .rc "$W2" 2>/dev/null)" = 0 ] && ok || bad "S6b: the retry's watermark rc is not 0"

# ── S12: a success with a failing curl keeps rc 0; no secret skips out loud ──
mklive "$T/l3" "$T/o3"
CURL_RC=7 rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l3" --orchestrator-live "$T/o3"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S12: a success with a failing curl exited $RC, want 0"
grep -q 'standby report failed (fail-open)' "$T/rs.out" && ok || bad "S12: the failed report was not said"
[ "$(jq -r .rc "$T/l3/state/standby-stream.json" 2>/dev/null)" = 0 ] && ok || bad "S12: watermark rc != process rc 0"

mv "$SB/env/.watchdog-secret" "$T/wds.bak"
mklive "$T/l4" "$T/o4"
# G1: a standby-of naming <hub>, in the installer's real "<name> <id>" form, streams
sbof "$T/l4/state/standby-of" box-hub hub
K0=$(curls)
rs hub latest --apply --standby --identity "$T/age.key" --live "$T/l4" --orchestrator-live "$T/o4"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S12: no secret exited $RC, want 0"
grep -q 'standby report skipped: watchdog secret not configured' "$T/rs.out" \
  && ok || bad "S12: an unset secret did not skip out loud: $(tail -3 "$T/rs.out")"
[ "$(curls)" = "$K0" ] && ok || bad "S12: it reported with no secret"
mv "$T/wds.bak" "$SB/env/.watchdog-secret"

echo "state-restore-standby: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
