#!/bin/bash
# bin/fly-pool-probe-pull.sh <test-app> <image> — BH-7430 probe, part 1 of 2.
#
# WHAT IT PROVES (the part that needs real Fly, which no suite can reach):
#   1. A machine started with `--file-secret` gets the token bundle from a
#      staged app secret (`fly secrets import --stage` + `fly machine run`
#      picks it up).
#   2. fly/entrypoint.sh unpacks it into the tmpfs: the token file is at its push
#      path with mode 600 and the SAME bytes, and the rootfs bundle file is gone.
#   3. NO token value is in `fly machines list --json` for that machine, so a
#      listing written to a hub file carries no token (the review BLOCK, #7556).
#   4. The secret is gone from the app at the end (unset --stage).
#   5. NO SEED_ secret is in the env of the machine's builder-runner.sh (check
#      2d): Fly gives every app secret to every machine, so the entrypoint
#      unsets them before the runner starts (lead BLOCK #3155 on #7556).
# The token is a throwaway `probe-<random>` value. It is never printed.
#
# WHAT IT DOES NOT PROVE: a fixture job to RESULT and the hub CPU number. Those
# are part 2, and need a test pool app with a synced bundle:
#   docs/notes/2026-10-19-BH-7430-pool-secrets-sync.md, section "Probe".
#
# NEEDS: flyctl, jq, and a Fly token for the TEST app in FLY_API_TOKEN (or
# FLY_ACCESS_TOKEN). Run it against a throwaway app, never a production pool app:
# it creates one machine (destroyed at the end) and one secret (unset at the end).
# Exit 0 = all four checks held. Exit 1 = a check failed (the line says which).
# Exit 2 = a precondition is missing (nothing was created).
set -uo pipefail

APP="${1:-}"; IMAGE="${2:-}"
[ -n "$APP" ] && [ -n "$IMAGE" ] || { echo "usage: fly-pool-probe-pull.sh <test-app> <image>" >&2; exit 2; }
FLY=$(command -v fly || command -v flyctl) || { echo "probe: no flyctl on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "probe: jq required" >&2; exit 2; }
[ -n "${FLY_API_TOKEN:-${FLY_ACCESS_TOKEN:-}}" ] || { echo "probe: set FLY_API_TOKEN to a token for the TEST app" >&2; exit 2; }
export FLY_ACCESS_TOKEN="${FLY_ACCESS_TOKEN:-$FLY_API_TOKEN}"

T=$(mktemp -d "${TMPDIR:-/tmp}/pull-probe.XXXXXX") || exit 2
chmod 700 "$T"
MID=""; SECRET=""; FAILS=0
pass() { echo "probe: PASS $*"; }
fail() { echo "probe: FAIL $*"; FAILS=$((FAILS + 1)); }
cleanup() {
  [ -z "$MID" ] || timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force >/dev/null 2>&1
  [ -z "$SECRET" ] || timeout 60 "$FLY" secrets unset --stage -a "$APP" "$SECRET" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

# The bundle: one token file at its push path, as bin/fly-pool.sh pool_pull_seal builds it.
TOKEN="probe-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
mkdir -p "$T/b/run/harness-env"
printf '%s\n' "$TOKEN" > "$T/b/run/harness-env/gh-token"
sha() { sha256sum 2>/dev/null || shasum -a 256; }   # GNU on Linux, shasum on a Mac
WANT=$(sha < "$T/b/run/harness-env/gh-token" | cut -d' ' -f1)
tar -C "$T/b" -czf "$T/b.tgz" ./run/harness-env/gh-token && base64 < "$T/b.tgz" | tr -d '\n' > "$T/b.b64" || { echo "probe: could not build the bundle" >&2; exit 2; }
SECRET="SEED_$(date +%s)_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

{ printf '%s=' "$SECRET"; cat "$T/b.b64"; printf '\n'; } | timeout 60 "$FLY" secrets import --stage -a "$APP" >/dev/null 2>"$T/err" \
  || { echo "probe: FAIL secrets import: $(tail -n 1 "$T/err" | cut -c1-200)"; exit 1; }
pass "1a the staged secret $SECRET is imported"

MID=$(timeout 180 "$FLY" machine run "$IMAGE" -a "$APP" --detach -e PROJECT=probe -e POOL_MODE=1 -e WARMUP_WAIT_S=300 \
      --file-secret "/run/harness-seed-secret/bundle.b64=$SECRET" 2>"$T/err" | grep -i 'machine id' | grep -oE '[0-9a-f]{14}' | head -1)
[ -n "$MID" ] || { echo "probe: FAIL machine run: $(tail -n 1 "$T/err" | cut -c1-200)"; exit 1; }
pass "1b machine $MID started with --file-secret"

# The entrypoint needs a few seconds to mount the tmpfs and unpack.
GOT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  GOT=$(timeout 60 "$FLY" ssh console -a "$APP" --machine "$MID" -C "/bin/sh -c 'sha256sum < /run/harness-env/gh-token; stat -c %a /run/harness-env/gh-token; test -e /run/harness-seed-secret/bundle.b64 && echo BUNDLE_LEFT'" 2>/dev/null | tr '\n' ' ')
  case "$GOT" in *"$WANT"*) break ;; esac
  sleep 5
done
case "$GOT" in *"$WANT"*) pass "2a the token file has the same bytes on the machine" ;; *) fail "2a the token file is missing or differs on $MID (got: ${GOT:-nothing})" ;; esac
case "$GOT" in *" 600 "*|*" 600") pass "2b mode 600" ;; *) fail "2b mode is not 600 (got: $GOT)" ;; esac
case "$GOT" in "") fail "2c no answer from $MID, so the bundle file state is unknown" ;; *BUNDLE_LEFT*) fail "2c the rootfs bundle file was not deleted" ;; *) pass "2c the rootfs bundle file is deleted" ;; esac

# 2d: the runner's own env holds no SEED_ secret (lead BLOCK #3155 on #7556).
# Counts names only; no value is printed.
NSEED=$(timeout 60 "$FLY" ssh console -a "$APP" --machine "$MID" -C "/bin/sh -c 'for p in \$(pgrep -f builder-runner.sh); do tr \"\\000\" \"\\n\" < /proc/\$p/environ; done | grep -c ^SEED_; pgrep -f builder-runner.sh >/dev/null || echo NO_RUNNER'" 2>/dev/null | tr '\n' ' ')
case "$NSEED" in *NO_RUNNER*) fail "2d no builder-runner.sh process to read on $MID" ;; "0 "|0) pass "2d the runner env holds no SEED_ secret" ;; *) fail "2d the runner env holds SEED_ secrets (count: ${NSEED:-unreadable})" ;; esac

timeout 60 "$FLY" machines list -a "$APP" --json > "$T/list.json" 2>/dev/null
if [ -s "$T/list.json" ]; then
  DEC=$(jq -r --arg m "$MID" '.[] | select(.id == $m) | .config.files[]? | .raw_value // empty' "$T/list.json" | while IFS= read -r v; do printf '%s' "$v" | base64 -d 2>/dev/null; echo; done)
  if grep -qF -- "$TOKEN" "$T/list.json" || grep -qF -- "$TOKEN" <<<"$DEC"; then
    fail "3 the machine listing holds the token value"
  elif jq -e --arg m "$MID" --arg s "$SECRET" '.[] | select(.id == $m) | .config.files[]? | select(.secret_name == $s)' "$T/list.json" >/dev/null 2>&1; then
    pass "3 the listing shows secret_name $SECRET and no token value"
  else
    fail "3 the listing has no secret_name entry for $MID (the file may not be secret-backed)"
  fi
else
  fail "3 could not read machines list --json"
fi

timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force >/dev/null 2>&1 && MID=""
if timeout 60 "$FLY" secrets unset --stage -a "$APP" "$SECRET" >/dev/null 2>&1; then SECRET=""; pass "4 the secret is unset"; else fail "4 could not unset $SECRET"; fi

[ "$FAILS" = 0 ] && { echo "probe: all checks held"; exit 0; }
echo "probe: $FAILS check(s) FAILED"; exit 1
