#!/bin/bash
# tests/fly-entrypoint-seed.bh-7430-test.sh — BH-7430: fly/entrypoint.sh's
# pull-path boot step (the seed move, the env compose, the harness fetch, the
# row stamp).
#
# THE REAL BLOCKS RUN: `# >>> seed (BH-7430)` through `# <<< harness pull
# (BH-7430)` are lifted by their markers and run on a scratch root (BOOT_ROOT),
# with a stub fetch helper at <root>/opt/fly-boot/harness-fetch.sh and a
# counting shim on curl and sleep.
# PINNED:
#   E1-E8  the 8-row table: seed dir present or absent x HBUNDLE_SYNCED_AT set
#          or unset x HARNESS_SHA set or unset. Each effect is independent; the
#          row with all three absent (a persistent builder) is today's boot.
#   O1-O4  the override: `KEY=VAL` replaces the base key (one GH_TOKEN line),
#          `-KEY` removes it; mode 600; no HBUNDLE_ var left for the runner.
#   X1     a seed file outside the push paths is not placed.
#   F1-F3  a failed fetch: ONE pool-result PUT `BUILD_DEFERRED harness-fetch:`,
#          exit 1, the runner never reached.
#   K1-K6  the token bundle (--file-secret): unpacked into the tmpfs, placed, deleted;
#          a member outside the push paths skipped; a bad bundle defers the job.
#   C1-C2  POOL_CLAIM_MACHINE=1: ONE claim-machine PUT with the machine id; unset: none.
#   S1     no SEED_<epoch>_<hex> app secret reaches the runner. Fly puts every
#          app secret in every machine's env, so another machine's token
#          bundle would ride into this runner (lead BLOCK #3155 on #7556).
# Run from anywhere: bash tests/fly-entrypoint-seed.bh-7430-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

EP="$DIR/fly/entrypoint.sh"
BLOCK=$(sed -n '/^# >>> seed (BH-7430)/,/^# <<< harness pull (BH-7430)/p' "$EP")
grep -q '^# <<< seed (BH-7430)' <<<"$BLOCK" && grep -q '^# >>> harness pull (BH-7430)' <<<"$BLOCK" && ok \
  || bad "E0: the seed and harness pull blocks are not in fly/entrypoint.sh"

# The harness the stub fetch "extracts": the real row-stamp closure.
HT="$T/harness-tree"; mkdir -p "$HT/fly"
for c in bin/jobs-client.sh bin/lib/pool-state-rows.sh; do
  ( cd "$DIR" && scratch_install_closure "$c" "$HT" ) >/dev/null || { echo "setup: closure $c"; exit 1; }
done
printf '#!/bin/bash\necho runner\n' > "$HT/fly/builder-runner.sh"; chmod +x "$HT/fly/builder-runner.sh"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'C'
#!/bin/bash
m=GET; d=""; u=""; prev=""
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary) d="$a" ;; esac
  case "$a" in http*) u="$a" ;; esac
  prev="$a"
done
printf '%s %s %s\n' "$m" "$u" "$d" >> "$CURL_SINK"
printf '{"ok":true}\n200'
C
cat > "$T/fakebin/sleep" <<'S'
#!/bin/bash
echo "nap $*" >> "$SLEEP_SINK"
S
chmod +x "$T/fakebin"/*

# mkroot <case>: a fresh scratch root; the fetch stub answers FETCH_MODE.
mkroot() {
  R="$T/root-$1"
  [ -e "$R" ] && scratch_rm "$R"
  mkdir -p "$R/run/harness-env" "$R/run/harness" "$R/data/harness/state" "$R/opt/fly-boot"
  printf '#!/bin/bash\necho floor\n' > "$R/opt/fly-boot/builder-runner.sh"; chmod +x "$R/opt/fly-boot/builder-runner.sh"
  cat > "$R/opt/fly-boot/harness-fetch.sh" <<EOF
#!/bin/bash
echo "fetch \$*" >> "$T/fetch.calls"
if [ "\${FETCH_MODE:-ok}" = fail ]; then echo "harness-fetch FATAL: fetch of 0123456789ab from example-org/cromford failed 3 times" >&2; exit 1; fi
cp -r "$HT/." "\$4/"; printf '%s\n' "\$1" > "\$4/HARNESS_COMMIT"; echo "harness-fetch: ok"
EOF
  chmod +x "$R/opt/fly-boot/harness-fetch.sh"
}
# seed <root>: the files a pull spawn seeds (the fly-pool suite drives the real
# writer; this is its layout).
seed() {
  local s="$1/run/harness-seed"
  mkdir -p "$s/run/harness-env" "$s/run/harness" "$s/data/harness/state/vercel-deploys" "$s/etc"
  printf 'GH_TOKEN=tok-fixture-app\nGH_TOKEN_INSTALLATION_ID=4242\n-CLAUDE_CODE_OAUTH_TOKEN\n' > "$s/run/harness-env/global.override.env"
  printf 'tok-fixture-app\n' > "$s/run/harness-env/gh-token"
  printf 'tok-fixture-harness\n' > "$s/run/harness-env/gh-token-harness"
  printf '{"deploys":[]}\n' > "$s/data/harness/state/vercel-deploys/project-5.json"
  printf 'note\n' > "$s/run/harness/build-note-project-5-BH-1.md"
  printf '{"key":"BH-1","ticket_id":"1"}\n' > "$s/run/harness/job.json"
  printf 'evil\n' > "$s/etc/fixture-escape"
}
SHA=0123456789abcdef0123456789abcdef01234567
# boot <root> [VAR=val ...]: run the real blocks; rc in $T/rc, log in $T/e.log.
boot() {
  local r="$1"; shift
  : > "$T/e.log"; : > "$T/curl.txt"; : > "$T/sleep.txt"; : > "$T/fetch.calls"; rm -f "$T/left" "$T/seedleft" "$T/reached"
  cat > "$T/boot.sh" <<EOF
log() { echo "entrypoint: \$*" >> "$T/e.log"; }
PROJECT=project-5 HOST=pool-project-5-m1 FLY_MACHINE_ID=m1fixture BOOT_ROOT="$r"
$BLOCK
env | grep -c '^HBUNDLE_' > "$T/left"
env | grep -c '^SEED_' > "$T/seedleft"
echo REACHED > "$T/reached"
EOF
  env -i PATH="$T/fakebin:$PATH" CURL_SINK="$T/curl.txt" SLEEP_SINK="$T/sleep.txt" "$@" bash "$T/boot.sh" >/dev/null 2>&1
  echo $? > "$T/rc"
}
SYNCED=(HBUNDLE_SYNCED_AT=2026-10-19T00:00:00Z HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN=fixture-base-claude
        HBUNDLE_G_GH_TOKEN=fixture-base-pat HBUNDLE_G_JOBS_URL=https://jobs.invalid
        HBUNDLE_G_HARNESS_SECRET=fixture-secret "HBUNDLE_G_RUNNER_NOTE=a b \$c" HBUNDLE_P_BOARD_TOKEN=fixture-board
        HBUNDLE_P_REPO_SLUG=example-org/project-5)

# ══ E1-E8: the table ════════════════════════════════════════════════════════
for SD in 1 0; do for SY in 1 0; do for SH in 1 0; do
  ID="E[seed=$SD synced=$SY sha=$SH]"
  mkroot "$SD$SY$SH"
  [ "$SD" = 1 ] && seed "$R"
  ARGS=()
  [ "$SY" = 1 ] && ARGS+=("${SYNCED[@]}")
  [ "$SH" = 1 ] && ARGS+=(HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford)
  boot "$R" ${ARGS[@]+"${ARGS[@]}"}
  [ -s "$T/reached" ] && [ "$(cat "$T/rc")" = 0 ] && ok || bad "$ID: the boot must reach the runner: rc $(cat "$T/rc") $(cat "$T/e.log")"
  [ "$(cat "$T/left" 2>/dev/null)" = 0 ] && ok || bad "$ID: no HBUNDLE_ var may reach the runner, got $(cat "$T/left" 2>/dev/null)"
  # seed effect
  if [ "$SD" = 1 ]; then
    [ "$(jq -r .key "$R/run/harness/job.json" 2>/dev/null)" = BH-1 ] && ok || bad "$ID: job.json at /run/harness/job.json"
    [ -s "$R/run/harness-env/gh-token" ] && [ -s "$R/run/harness/build-note-project-5-BH-1.md" ] \
      && [ -s "$R/data/harness/state/vercel-deploys/project-5.json" ] && ok || bad "$ID: the seed files at their push paths"
    [ "$(stat -c %a "$R/run/harness-env/gh-token")" = 600 ] && [ "$(stat -c %a "$R/run/harness/job.json")" = 600 ] && ok \
      || bad "$ID: placed files are mode 600"
    [ ! -e "$R/run/harness-seed" ] && ok || bad "$ID: the seed dir must be removed"
    [ ! -e "$R/etc/fixture-escape" ] && ok || bad "X1: a seed file outside the push paths must not be placed"
    grep -q 'seed: skipped /etc/fixture-escape (not a push path)' "$T/e.log" && ok || bad "X1: the skip is logged: $(cat "$T/e.log")"
  else
    [ ! -e "$R/run/harness/job.json" ] && ok || bad "$ID: no seed, no job.json"
    grep -q 'seed:' "$T/e.log" && bad "$ID: no seed, no seed line" || ok
  fi
  # env effect
  if [ "$SY" = 1 ]; then
    G="$R/run/harness-env/global.env"
    [ -s "$G" ] && [ -s "$R/run/harness-env/project-5.env" ] && ok || bad "$ID: global.env and project-5.env composed"
    grep -qx 'JOBS_URL=https://jobs.invalid' "$G" && grep -qx 'RUNNER_NOTE=a b $c' "$G" && ok || bad "$ID: base lines verbatim: $(cut -d= -f1 "$G" | tr '\n' ' ')"
    grep -qx 'BOARD_TOKEN=fixture-board' "$R/run/harness-env/project-5.env" && ok || bad "$ID: the project lines"
    [ "$(stat -c %a "$G")" = 600 ] && ok || bad "$ID: global.env is mode 600"
    if [ "$SD" = 1 ]; then
      [ "$(grep -c '^GH_TOKEN=' "$G")" = 1 ] && grep -qx 'GH_TOKEN=tok-fixture-app' "$G" && ok || bad "O1: the override replaces GH_TOKEN, one line: $(grep '^GH_TOKEN' "$G" | sed 's/=.*/=…/')"
      grep -qx 'GH_TOKEN_INSTALLATION_ID=4242' "$G" && ok || bad "O2: an override key the base lacks is added"
      grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$G" && bad "O3: -CLAUDE_CODE_OAUTH_TOKEN removes the base line" || ok
      [ ! -e "$R/run/harness-env/global.override.env" ] && ok || bad "O4: the override file is removed after the compose"
    else
      grep -qx 'GH_TOKEN=fixture-base-pat' "$G" && grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=fixture-base-claude' "$G" && ok \
        || bad "$ID: no override, the base lines stay"
    fi
  else
    [ ! -e "$R/run/harness-env/global.env" ] && ok || bad "$ID: not synced, no global.env written"
    grep -q 'env: composed' "$T/e.log" && bad "$ID: not synced, no compose line" || ok
  fi
  # harness effect
  if [ "$SH" = 1 ]; then
    grep -qx "fetch $SHA example-org/cromford $R/run/harness-env/gh-token-harness $R/data/harness" "$T/fetch.calls" && ok \
      || bad "$ID: the fetch helper gets sha, slug, the seeded token path and /data/harness: $(cat "$T/fetch.calls")"
    [ "$(cat "$R/data/harness/HARNESS_COMMIT" 2>/dev/null)" = "$SHA" ] && ok || bad "$ID: the fetched harness is in place"
    [ ! -s "$T/sleep.txt" ] && ok || bad "$ID: the pull path never waits: $(sort "$T/sleep.txt" | uniq -c | tr '\n' ' ')"
  else
    [ ! -s "$T/fetch.calls" ] && ok || bad "$ID: no HARNESS_SHA, no fetch"
    [ "$(grep -c '^nap 5$' "$T/sleep.txt")" = 24 ] && ok || bad "$ID: no HARNESS_SHA keeps the 120 s wait (24 x 5 s), got $(grep -c . "$T/sleep.txt")"
    grep -q 'no tarball runner after 120s — using image floor' "$T/e.log" \
      && [ "$(sed -n 2p "$R/data/harness/fly/builder-runner.sh" 2>/dev/null)" = 'echo floor' ] && ok \
      || bad "$ID: then the image floor: $(cat "$T/e.log")"
  fi
  [ ! -s "$T/curl.txt" ] && ok || bad "$ID: a good boot without POOL_CLAIM_MACHINE makes no request: $(cat "$T/curl.txt")"
done; done; done

# The wait ends as soon as a pushed runner appears (the push path, unchanged).
mkroot pushed
mkdir -p "$R/data/harness/fly"; printf '#!/bin/bash\n' > "$R/data/harness/fly/builder-runner.sh"; chmod +x "$R/data/harness/fly/builder-runner.sh"
boot "$R"
grep -q 'tarball runner arrived after 0s' "$T/e.log" && [ ! -s "$T/sleep.txt" ] && ok || bad "E9: a pushed runner ends the wait at once: $(cat "$T/e.log")"

# ══ F1-F3: the fetch fails ═══════════════════════════════════════════════════
mkroot ffail; seed "$R"
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford FETCH_MODE=fail
[ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/reached" ] && ok || bad "F1: a failed fetch exits 1 before the runner, rc $(cat "$T/rc")"
[ "$(grep -c '^PUT https://jobs.invalid/api/ledger ' "$T/curl.txt")" = 1 ] && ok || bad "F2: ONE pool-result PUT, got: $(cat "$T/curl.txt")"
BODY=$(grep '^PUT https://jobs.invalid/api/ledger ' "$T/curl.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r .kind <<<"$BODY" 2>/dev/null)" = pool-result ] && [ "$(jq -r .key <<<"$BODY")" = project-5/BH-1 ] \
  && [ "$(jq -r .status <<<"$BODY")" = result ] && ok || bad "F2: the row is pool-result project-5/BH-1 status result: $BODY"
DET=$(jq -r .detail <<<"$BODY" 2>/dev/null)
[ "$(jq -r .rline <<<"$DET" 2>/dev/null)" = "BUILD_DEFERRED harness-fetch: fetch of 0123456789ab from example-org/cromford failed 3 times" ] \
  && [ "$(jq -r .machine <<<"$DET")" = m1fixture ] && ok || bad "F2: the detail carries the deferral line and the machine: $DET"
"$DIR/bin/result-prefix-ok.sh" "$(jq -r .rline <<<"$DET")" && ok || bad "F3: the reap must read the line as a RESULT"
# F3: no env, no row (nothing to authenticate with), still exit 1.
mkroot ffail2; seed "$R"
boot "$R" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford FETCH_MODE=fail
[ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/curl.txt" ] && ok || bad "F3: no env: exit 1, no request: rc $(cat "$T/rc") $(cat "$T/curl.txt")"
grep -q 'the pool-result row was not written' "$T/e.log" && ok || bad "F3: the missing row is logged: $(cat "$T/e.log")"

# ══ C1-C2: the row stamp ═════════════════════════════════════════════════════
mkroot claim; seed "$R"
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford POOL_CLAIM_MACHINE=1
[ -s "$T/reached" ] && ok || bad "C1: the boot goes on: $(cat "$T/e.log")"
[ "$(grep -c '^PUT https://jobs.invalid/api/pool-state/claim-machine ' "$T/curl.txt")" = 1 ] && ok || bad "C1: ONE claim-machine PUT, got: $(cat "$T/curl.txt")"
CB=$(grep 'claim-machine' "$T/curl.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r .machine <<<"$CB" 2>/dev/null)" = m1fixture ] && [ "$(jq -r .key <<<"$CB")" = BH-1 ] && [ "$(jq -r .project <<<"$CB")" = project-5 ] \
  && ok || bad "C1: the stamp names project, key and machine: $CB"
grep -q 'row project-5/BH-1 stamped with machine m1fixture' "$T/e.log" && ok || bad "C1: the stamp is logged: $(cat "$T/e.log")"
# C2: the stamp fails (no env): logged, the boot goes on.
mkroot claim2; seed "$R"
boot "$R" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford POOL_CLAIM_MACHINE=1
[ -s "$T/reached" ] && grep -q 'could not be stamped with machine m1fixture — the build goes ahead' "$T/e.log" && ok \
  || bad "C2: a failed stamp is fail-open: $(cat "$T/e.log")"

# ══ K1-K5: the token bundle (--file-secret) lands in the tmpfs, not the config ═
# fly/entrypoint.sh unpacks /run/harness-seed-secret/bundle.b64 (a base64 tar.gz
# of the token files, written by Fly from the app secret SEED_*) into the
# tmpfs, places each file at its push path, and deletes the bundle.
mkbundle() { # mkbundle <root> [extra member path]  (token files here, job.json in the --file-local seed)
  local r="$1" b="$T/bundle-src"
  [ -e "$b" ] && scratch_rm "$b"
  mkdir -p "$b/run/harness-env" "$b/data/harness/state"
  printf 'GH_TOKEN=tok-fixture-app\n-CLAUDE_CODE_OAUTH_TOKEN\n' > "$b/run/harness-env/global.override.env"
  printf 'tok-fixture-app\n' > "$b/run/harness-env/gh-token"
  printf 'tok-fixture-harness\n' > "$b/run/harness-env/gh-token-harness"
  printf '{"accounts":[{"token":"fixture-acct-secret-MARK"}]}\n' > "$b/data/harness/state/auth-accounts.local.json"
  [ -n "${2:-}" ] && { mkdir -p "$b$(dirname "$2")"; printf 'evil\n' > "$b$2"; }
  mkdir -p "$r/run/harness-seed-secret" "$r/run/harness-seed/run/harness"
  ( cd "$b" && tar -czf - . ) | base64 -w0 > "$r/run/harness-seed-secret/bundle.b64"
  printf '{"key":"BH-1","ticket_id":"1"}\n' > "$r/run/harness-seed/run/harness/job.json"
}
mkroot k1; mkbundle "$R"
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford
[ -s "$T/reached" ] && [ "$(cat "$T/rc")" = 0 ] && ok || bad "K1: the boot reaches the runner: rc $(cat "$T/rc") $(cat "$T/e.log")"
[ "$(cat "$R/run/harness-env/gh-token-harness" 2>/dev/null)" = tok-fixture-harness ] && [ "$(stat -c %a "$R/run/harness-env/gh-token" 2>/dev/null)" = 600 ] \
  && grep -q fixture-acct-secret-MARK "$R/data/harness/state/auth-accounts.local.json" 2>/dev/null && ok || bad "K1: the token files land at their push paths, mode 600: $(cat "$T/e.log")"
grep -qx 'GH_TOKEN=tok-fixture-app' "$R/run/harness-env/global.env" && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$R/run/harness-env/global.env" && ok \
  || bad "K2: the unsealed override applies over the secrets base (one GH_TOKEN, the base token dropped)"
[ ! -e "$R/run/harness-seed-secret/bundle.b64" ] && [ ! -e "$R/run/harness-env/.sealed" ] && [ ! -e "$R/run/harness-seed" ] && ok \
  || bad "K3: the bundle file, the unpack dir and the seed dir are all removed"
grep -q 'tok-fixture\|fixture-acct-secret' "$T/e.log" "$T/curl.txt" && bad "K3: no token value in the boot log or a request" || ok
# K6: the bundle as Fly writes it. Fly base64-decodes a --file-secret value
# before it writes the file (seen live 2026-10-20 on a throwaway app: a secret of
# base64("hello-plain") gave a file holding hello-plain), so the file is the raw
# tar.gz, not base64. It must unpack and place the files too.
mkroot k6; mkbundle "$R"
base64 -d < "$R/run/harness-seed-secret/bundle.b64" > "$R/run/harness-seed-secret/bundle.raw" \
  && mv -f "$R/run/harness-seed-secret/bundle.raw" "$R/run/harness-seed-secret/bundle.b64"
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford
[ -s "$T/reached" ] && [ "$(cat "$T/rc")" = 0 ] && ok || bad "K6: a raw tar.gz bundle (Fly's decoded file) reaches the runner: rc $(cat "$T/rc") $(cat "$T/e.log")"
[ "$(cat "$R/run/harness-env/gh-token-harness" 2>/dev/null)" = tok-fixture-harness ] && [ "$(stat -c %a "$R/run/harness-env/gh-token" 2>/dev/null)" = 600 ] && ok \
  || bad "K6: a raw tar.gz bundle places the token files, mode 600: $(cat "$T/e.log")"
[ ! -e "$R/run/harness-seed-secret/bundle.b64" ] && ok || bad "K6: the raw bundle file is removed"
# K4: a bundle member outside the push paths is not placed.
mkroot k4; mkbundle "$R" /etc/fixture-bundle-escape
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford
[ ! -e "$R/etc/fixture-bundle-escape" ] && grep -q 'skipped /etc/fixture-bundle-escape' "$T/e.log" && ok || bad "K4: a member outside the push paths must be skipped: $(cat "$T/e.log")"
# K5: a bundle that does not unpack defers the job (one pool-result row) and exits 1.
mkroot k5; mkbundle "$R"; printf 'not-a-tarball' | base64 -w0 > "$R/run/harness-seed-secret/bundle.b64"
boot "$R" "${SYNCED[@]}" HARNESS_SHA="$SHA" HARNESS_SLUG=example-org/cromford
[ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/reached" ] && [ ! -s "$T/fetch.calls" ] && ok || bad "K5: a bad bundle exits 1 before the fetch and the runner: rc $(cat "$T/rc")"
BODY=$(grep '^PUT https://jobs.invalid/api/ledger ' "$T/curl.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.detail | fromjson | .rline' <<<"$BODY" 2>/dev/null)" = "BUILD_DEFERRED seed-unseal: the token bundle did not unpack" ] && ok || bad "K5: the deferral row names seed-unseal: $BODY"
[ ! -e "$R/run/harness-seed-secret/bundle.b64" ] && ok || bad "K5: the bad bundle file is removed too"

# ══ S1: no other machine's SEED_ secret reaches the runner ═════════════════════
mkroot s1
boot "$R" "${SYNCED[@]}" SEED_1792500000_aabbccddeeff=fixture-other-bundle SEED_1792500001_001122334455=fixture-own-bundle
[ -s "$T/reached" ] && [ "$(cat "$T/rc")" = 0 ] && ok || bad "S1: the boot must reach the runner: rc $(cat "$T/rc") $(cat "$T/e.log")"
[ "$(cat "$T/seedleft" 2>/dev/null)" = 0 ] && ok || bad "S1: no SEED_ var may reach the runner, got $(cat "$T/seedleft" 2>/dev/null)"

echo "fly-entrypoint-seed (BH-7430): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
