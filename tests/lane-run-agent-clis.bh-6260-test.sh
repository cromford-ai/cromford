#!/bin/bash
# tests/lane-run-agent-clis.bh-6260-test.sh — BH-6260 review BLOCK fix.
# blocked-resolver moves to the Fly lane-run machines, and its agent rungs
# (test-tamper adjudication, the inline fix agent) call bin/agent-call.sh,
# whose runner_ready refuses a runner whose CLI is not installed. the operator,
# 2026-10-17: "definitely let the fly machines have credentials". So the
# lane-run image must bake claude and codex the way the pool image does, and
# a lane-run machine must get the same agent credentials a pool machine gets.
#
#   C1  fly/lane-run.Dockerfile has the `bake-node`, `cli-pin-verify` and
#       (BH-7594, the web-task lane's browser) `bake-playwright` blocks,
#       byte-identical to the same blocks in fly/Dockerfile (the pool
#       image), and the CLI block installs @anthropic-ai/claude-code and
#       @openai/codex. It copies fly/bake-pin.sh, which the node block sources.
#   C2  the lane-run CLI block, run as shipped against stub npm/claude/codex:
#       rc 0 when both CLIs report the pinned args; FATAL on an empty arg and
#       on a version mismatch.
#   C3  ARG HARNESS_COMMIT comes after the tool layers (it changes on every
#       commit and would rebuild node and the CLIs).
#   C4  the credential names: every agent credential variable the pool bundle
#       ships (bin/fly-envbundle.sh whitelist, *TOKEN / *API_KEY names) and the
#       codex files bin/fly-dispatch.sh pushes (/root/.codex/auth.json,
#       config.toml) reach a lane-run machine: the REAL entrypoint writes the
#       token into global.env and the files into $HOME/.codex, mode 600, and
#       fly/lane-run.toml names each secret and the three version build args.
#       No value reaches stdout/stderr; the file secrets are not in the
#       worker's env.
#   C5  without the credential secrets the entrypoint still execs the worker,
#       global.env has no token line and no .codex dir is made.
#
# Run from anywhere: tests/lane-run-agent-clis.bh-6260-test.sh (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
LDF="$REPO/fly/lane-run.Dockerfile"; PDF="$REPO/fly/Dockerfile"
extract() { # extract <marker> <file>
  awk -v m="$1" '$0 ~ "^# >>> " m "$" {f=1; next} $0 ~ "^# <<< " m "$" {f=0} f {print}' "$2"
}

echo "C1: the lane-run image bakes the pool image's node + CLI blocks"
for m in bake-node cli-pin-verify bake-playwright; do
  L=$(extract "$m" "$LDF"); P=$(extract "$m" "$PDF")
  [ -n "$P" ] || bad "C1 fly/Dockerfile has no $m block (markers moved?)"
  [ -n "$L" ] && [ "$L" = "$P" ] && ok "C1 $m block is byte-identical to the pool image's" \
    || bad "C1 $m block missing or drifted in fly/lane-run.Dockerfile"
done
CLI=$(extract cli-pin-verify "$LDF")
grep -q 'npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}"' <<<"$CLI" \
  && ok "C1 installs claude and codex at the pinned versions" || bad "C1 no pinned claude+codex install"
grep -qx 'COPY fly/bake-pin.sh /opt/fly-boot/bake-pin.sh' "$LDF" && ok "C1 copies bake-pin.sh" || bad "C1 bake-pin.sh not copied"
grep -q 'xz-utils' "$LDF" && ok "C1 xz-utils for the node tarball" || bad "C1 no xz-utils"

echo "C2: the CLI block, run as shipped"
SN="$T/cli.sh"; grep -v '^ARG ' <<<"$CLI" | sed '1s/^RUN //' > "$SN"
DB="$T/dbin"; mkdir -p "$DB"
printf '#!/bin/bash\nexit 0\n' > "$DB/npm"
printf '#!/bin/bash\necho "%s (Claude Code)"\n' "${STUB_CV:-2.1.300}" > "$DB/claude"
printf '#!/bin/bash\necho "codex-cli 0.160.1"\n' > "$DB/codex"
chmod +x "$DB/npm" "$DB/claude" "$DB/codex"
OUT=$(env -i PATH="$DB:/usr/bin:/bin" CLAUDE_CODE_VERSION=2.1.300 CODEX_VERSION=0.160.1 bash "$SN" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "C2 matching versions: rc 0" || bad "C2 rc=$rc: $OUT"
OUT=$(env -i PATH="$DB:/usr/bin:/bin" CLAUDE_CODE_VERSION= CODEX_VERSION=0.160.1 bash "$SN" 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q 'FATAL: CLAUDE_CODE_VERSION and CODEX_VERSION build args are required' <<<"$OUT" \
  && ok "C2 empty arg: FATAL, never latest" || bad "C2 empty arg rc=$rc: $OUT"
OUT=$(env -i PATH="$DB:/usr/bin:/bin" CLAUDE_CODE_VERSION=2.1.301 CODEX_VERSION=0.160.1 bash "$SN" 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q 'FATAL: claude --version reports 2.1.300, expected 2.1.301' <<<"$OUT" \
  && ok "C2 version mismatch: FATAL" || bad "C2 mismatch rc=$rc: $OUT"

echo "C3: HARNESS_COMMIT is below the tool layers"
la=$(grep -n '^ARG HARNESS_COMMIT=' "$LDF" | cut -d: -f1); lc=$(grep -n '^# <<< cli-pin-verify$' "$LDF" | cut -d: -f1)
[ -n "$la" ] && [ -n "$lc" ] && [ "$la" -gt "$lc" ] && ok "C3 ARG HARNESS_COMMIT (line $la) after the CLI layer (line $lc)" \
  || bad "C3 ARG HARNESS_COMMIT line ${la:-none}, CLI block end ${lc:-none}"

echo "C4: the pool's credential names reach a lane-run machine"
POOLV=$(sed -n 's/^for v in \(.*CLAUDE_CODE_OAUTH_TOKEN.*\); do$/\1/p' "$REPO/bin/fly-envbundle.sh" | head -1)
CREDS=$(tr ' ' '\n' <<<"$POOLV" | grep -E '(TOKEN|API_KEY)$' | sort -u)
[ -n "$CREDS" ] && grep -qx CLAUDE_CODE_OAUTH_TOKEN <<<"$CREDS" && ok "C4 pool bundle credential names: $(tr '\n' ' ' <<<"$CREDS")" \
  || bad "C4 could not read the pool bundle's credential names (whitelist line moved?)"
for f in auth.json config.toml; do
  grep -q "/root/.codex/$f" "$REPO/bin/fly-dispatch.sh" && ok "C4 the pool pushes .codex/$f" || bad "C4 fly-dispatch.sh no longer pushes .codex/$f"
done
E="$T/e"; mkdir -p "$E/bin/lib" "$E/env" "$T/home"
( cd "$REPO" && scratch_install_closure fly/lane-run-entrypoint.sh "$E" ) >/dev/null 2>&1 || bad "C4 setup: closure"
printf '#!/bin/bash\nenv > "%s/w.env"\n' "$T" > "$E/bin/lane-run-worker.sh"; chmod +x "$E/bin/lane-run-worker.sh"
CENV=(); for c in $CREDS; do CENV+=("$c=fixture-$c-6260"); done
( env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-hs-6260 JOBS_URL=http://192.0.2.1 \
    FLY_MACHINE_ID=fixturemid60 "${CENV[@]}" CODEX_AUTH_JSON='{"fixture":"codex-auth-6260"}' CODEX_CONFIG_TOML='model = "fixture-cfg-6260"' \
    bash "$E/fly/lane-run-entrypoint.sh" ) > "$T/e.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -s "$T/w.env" ] && ok "C4 the entrypoint exec'd the worker" || bad "C4 rc=$rc: $(cat "$T/e.out")"
for c in $CREDS; do
  grep -qx "$c=fixture-$c-6260" "$E/env/global.env" && ok "C4 global.env carries $c" || bad "C4 global.env lacks $c"
done
[ "$(cat "$T/home/.codex/auth.json" 2>/dev/null)" = '{"fixture":"codex-auth-6260"}' ] && ok "C4 .codex/auth.json written" || bad "C4 auth.json"
[ "$(cat "$T/home/.codex/config.toml" 2>/dev/null)" = 'model = "fixture-cfg-6260"' ] && ok "C4 .codex/config.toml written" || bad "C4 config.toml"
for f in "$E/env/global.env" "$T/home/.codex/auth.json" "$T/home/.codex/config.toml"; do
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)" = 600 ] && ok "C4 $(basename "$f") mode 600" || bad "C4 $f mode"
done
grep -q -e 'fixture-' -e 'codex-auth-6260' -e 'fixture-cfg-6260' "$T/e.out" && bad "C4 a secret reached stdout/stderr" || ok "C4 no secret in stdout/stderr"
grep -q -e '^CODEX_AUTH_JSON=' -e '^CODEX_CONFIG_TOML=' "$T/w.env" && bad "C4 a codex file secret is in the worker env" || ok "C4 codex file secrets unset before the worker"
TOML="$REPO/fly/lane-run.toml"
for c in $CREDS CODEX_AUTH_JSON CODEX_CONFIG_TOML; do
  grep -q "secrets set.*$c=\.\.\.\|^#  *$c=\.\.\." "$TOML" && ok "C4 fly/lane-run.toml names secret $c" || bad "C4 fly/lane-run.toml does not name secret $c"
done
for a in NODE_VERSION CLAUDE_CODE_VERSION CODEX_VERSION; do
  grep -q -- "--build-arg $a=" "$TOML" && ok "C4 the deploy step passes $a" || bad "C4 the deploy step lacks --build-arg $a"
done
! grep -q -e 'CLAUDE_CODE_OAUTH_TOKEN=' -e 'CODEX_AUTH_JSON=' -e 'CODEX_CONFIG_TOML=' "$LDF" && ok "C4 the Dockerfile sets no credential" || bad "C4 the Dockerfile sets a credential"

echo "C5: no credential secrets: the machine still boots"
scratch_rm "$E/env/global.env"; mkdir -p "$T/home2"
( env -i PATH="$PATH" HOME="$T/home2" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-hs-6260 JOBS_URL=http://192.0.2.1 \
    FLY_MACHINE_ID=fixturemid60 bash "$E/fly/lane-run-entrypoint.sh" ) > "$T/e2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "C5 rc 0" || bad "C5 rc=$rc: $(cat "$T/e2.out")"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$E/env/global.env" && bad "C5 a token line with no secret" || ok "C5 no token line"
[ -e "$T/home2/.codex" ] && bad "C5 .codex made with no secret" || ok "C5 no .codex dir"

echo
echo "lane-run-agent-clis.bh-6260: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
