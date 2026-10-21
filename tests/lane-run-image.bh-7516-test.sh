#!/bin/bash
# tests/lane-run-image.bh-7516-test.sh — BH-7516: a lane-run machine carries
# what bin/fly-pool-project.sh --preflight checks for a pool tick on Fly
# (#7515): flyctl (`fly-binary`), the harness tree (`harness-src`) and the
# Fly token (`fly-token`). `env-bundle` is BH-6896 S3 and stays missing.
#
#   I1  fly/lane-run.Dockerfile has `ARG FLYCTL_VERSION` with no default, and
#       no line of its `bake-flyctl` block names `latest`
#   I2  the block calls bake_require FLYCTL_VERSION, bake_sha256 and
#       bake_verify flyctl "$FLYCTL_VERSION"
#   I3  it installs /root/.fly/bin/flyctl, links /root/.fly/bin/fly, and puts
#       /root/.fly/bin on PATH
#   I5  the block's RUN line as shipped (paths moved into the scratch tree),
#       a stub curl serving a fixture release: rc 0 installs flyctl and the
#       fly link from the pinned URLs; an empty arg, a checksum mismatch and a
#       version mismatch each FATAL
#   I4  COPY prompts, rules and fly into /opt/harness, ENV POOL_HARNESS_SRC=
#       /opt/harness; the pool image (fly/Dockerfile) sets no POOL_HARNESS_SRC
#   H1  lrc_sync on an old-image root (bin catalog fleet.conf only) and a
#       commit that has prompts rules fly: rc 10, all six paths match the
#       commit; a near-miss top-level `promptsx/` is not copied
#   H2  an archive of `rules` that fails: rc 1, the tree unchanged, one
#       `code sync failed` line, the stage removed
#   H3  a commit with no prompts/rules/fly: rc 10, the root's own copies of
#       those paths are untouched
#   H4  the lib's header names the six paths
#   K1  fly/lane-run.toml names FLY_API_TOKEN_project-6_OS, the stdin
#       `secrets import -a lane-run-mk --stage` and the FLYCTL_VERSION build
#       arg; bin/lane-fleet.sh's app-secrets alert names FLY_API_TOKEN_
#   K2  the REAL entrypoint with FLY_API_TOKEN_project-6_OS and FLY_API_TOKEN
#       writes fly.env mode 600; sourced in a clean shell, fly_token_resolve
#       project-6-os takes FLY_API_TOKEN_project-6_OS; a value with `=` is kept
#       whole; no value on stdout/stderr
#   K3  FLY_ACCESS_TOKEN, FLY_API_TOKENX, XFLY_API_TOKEN_A, FLY_MACHINE_ID set,
#       no real token: fly.env exists, mode 600, empty
#   K4  fly.env cannot be written: rc 78, stderr names fly.env, no value
#   P1  a machine root built from the Dockerfile's own COPY lines and ENV
#       POOL_HARNESS_SRC, a stub flyctl in FLY_BIN_DIR and the K2 fly.env:
#       when bin/fly-pool-project.sh exists, --preflight project-6-os answers
#       exactly `missing env-bundle`; else the three ingredient checks of
#       pfp_missing pass one by one. No token value in any output.
#
# Run from anywhere: tests/lane-run-image.bh-7516-test.sh (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git missing"; exit 0; }
LDF="$REPO/fly/lane-run.Dockerfile"; PDF="$REPO/fly/Dockerfile"
TOML="$REPO/fly/lane-run.toml"; LRC="$REPO/bin/lib/lane-run-code.sh"
extract() { # extract <marker> <file>
  awk -v m="$1" '$0 ~ "^# >>> " m "$" {f=1; next} $0 ~ "^# <<< " m "$" {f=0} f {print}' "$2"
}
BLK=$(extract bake-flyctl "$LDF")

echo "I1-I4: the Dockerfile"
grep -qx 'ARG FLYCTL_VERSION' <<<"$BLK" && ! grep -q '^ARG FLYCTL_VERSION=' "$LDF" \
  && ok "I1 ARG FLYCTL_VERSION has no default" || bad "I1 no bare ARG FLYCTL_VERSION in the bake-flyctl block"
[ -n "$BLK" ] && ! grep -qi 'latest' <<<"$BLK" && ok "I1 the bake-flyctl block never names latest" \
  || bad "I1 bake-flyctl block missing or names latest"
grep -q 'bake_require FLYCTL_VERSION "${FLYCTL_VERSION:-}"' <<<"$BLK" && ok "I2 bake_require FLYCTL_VERSION" || bad "I2 no bake_require"
grep -q 'bake_sha256 "/tmp/$A" "$U/checksums.txt" "$A"' <<<"$BLK" && ok "I2 bake_sha256 against checksums.txt" || bad "I2 no bake_sha256"
grep -q 'bake_verify flyctl "$FLYCTL_VERSION" /root/.fly/bin/flyctl version' <<<"$BLK" && ok "I2 bake_verify flyctl" || bad "I2 no bake_verify"
grep -q 'tar -xzf "/tmp/$A" -C /root/.fly/bin flyctl' <<<"$BLK" && grep -q 'ln -sf flyctl /root/.fly/bin/fly' <<<"$BLK" \
  && ok "I3 /root/.fly/bin/flyctl and the fly link" || bad "I3 install path or link"
grep -q '^ENV PATH=/root/.fly/bin:\$PATH' <<<"$BLK" && ok "I3 /root/.fly/bin on PATH" || bad "I3 no ENV PATH"
for d in prompts rules fly; do
  grep -qx "COPY $d /opt/harness/$d" "$LDF" && ok "I4 COPY $d" || bad "I4 no COPY $d /opt/harness/$d"
done
grep -qx 'ENV POOL_HARNESS_SRC=/opt/harness' "$LDF" && ok "I4 ENV POOL_HARNESS_SRC=/opt/harness" || bad "I4 no POOL_HARNESS_SRC"
! grep -q POOL_HARNESS_SRC "$PDF" && ok "I4 the pool image sets no POOL_HARNESS_SRC" || bad "I4 fly/Dockerfile sets POOL_HARNESS_SRC"
# I5: the RUN line as shipped, against a stub curl serving a fixture release.
# Paths move into $T (the block writes /root/.fly/bin and /tmp).
FR="$T/fr"; REL="$T/rel"; SB="$T/sbin"; mkdir -p "$FR/tmp" "$REL" "$SB"
# /tmp/ first, and only after a quote: $FR itself sits under /tmp.
awk '/^RUN /{f=1} f{print} f && !/\\$/{exit}' <<<"$BLK" | sed -e '1s/^RUN //' -e "s|\"/tmp/|\"$FR/tmp/|g" \
  -e "s|/opt/fly-boot/bake-pin.sh|$REPO/fly/bake-pin.sh|g" -e "s|/root/.fly/bin|$FR/bin|g" > "$T/flyctl-run.sh"
cat > "$SB/curl" <<EOF
#!/bin/bash
o=""; u=""
while [ "\$#" -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2 ;; -*) shift ;; *) u="\$1"; shift ;; esac; done
echo "\$u" >> "$T/curl.urls"
f="$REL/\${u##*/}"; [ -f "\$f" ] || exit 22
if [ -n "\$o" ]; then cp "\$f" "\$o"; else cat "\$f"; fi
EOF
chmod +x "$SB/curl"
mkrel() { # mkrel <version the binary reports> [bad-sum]
  scratch_rm "$T/relsrc"; mkdir -p "$T/relsrc"
  printf '#!/bin/sh\necho "flyctl v%s linux/amd64 Commit: abc1234 BuildDate: 2026-10-01T00:00:00Z"\n' "$1" > "$T/relsrc/flyctl"
  chmod +x "$T/relsrc/flyctl"
  tar -czf "$REL/flyctl_0.3.209_Linux_x86_64.tar.gz" -C "$T/relsrc" flyctl
  if [ -n "${2:-}" ]; then printf '%064d  flyctl_0.3.209_Linux_x86_64.tar.gz\n' 0 > "$REL/checksums.txt"
  else ( cd "$REL" && sha256sum flyctl_0.3.209_Linux_x86_64.tar.gz > checksums.txt ); fi
}
brun() { scratch_rm "$FR/bin"; : > "$T/curl.urls"; env PATH="$SB:$PATH" FLYCTL_VERSION="$1" sh "$T/flyctl-run.sh" > "$T/brun.out" 2>&1; BRC=$?; }
mkrel 0.3.209; brun 0.3.209
[ "$BRC" = 0 ] && [ -x "$FR/bin/flyctl" ] && [ "$(readlink "$FR/bin/fly")" = flyctl ] && "$FR/bin/fly" version | grep -q 'v0.3.209' \
  && ok "I5 the block as shipped installs flyctl 0.3.209 and the fly link" || bad "I5 rc=$BRC: $(tail -5 "$T/brun.out")"
grep -qx 'https://github.com/superfly/flyctl/releases/download/v0.3.209/flyctl_0.3.209_Linux_x86_64.tar.gz' "$T/curl.urls" \
  && grep -qx 'https://github.com/superfly/flyctl/releases/download/v0.3.209/checksums.txt' "$T/curl.urls" \
  && ok "I5 it fetches the pinned asset and its checksums.txt" || bad "I5 urls: $(cat "$T/curl.urls")"
brun ""
[ "$BRC" != 0 ] && grep -q 'FATAL: build arg FLYCTL_VERSION is required' "$T/brun.out" && [ ! -s "$T/curl.urls" ] \
  && ok "I5 an empty FLYCTL_VERSION FATALs before any download" || bad "I5 empty arg rc=$BRC"
mkrel 0.3.209 bad; brun 0.3.209
[ "$BRC" != 0 ] && grep -q 'FATAL: flyctl_0.3.209_Linux_x86_64.tar.gz sha256' "$T/brun.out" && ok "I5 a checksum mismatch FATALs" || bad "I5 sum rc=$BRC"
mkrel 0.3.208; brun 0.3.209
[ "$BRC" != 0 ] && grep -q 'FATAL: flyctl reports 0.3.208, expected 0.3.209' "$T/brun.out" && ok "I5 a version mismatch FATALs" || bad "I5 version rc=$BRC"
# The two BH-6260 marker blocks stay byte-identical (the new block is outside them).
for m in bake-node cli-pin-verify; do
  [ "$(extract "$m" "$LDF")" = "$(extract "$m" "$PDF")" ] && ok "I4 $m block still identical" || bad "I4 $m block drifted"
done

echo "H1-H4: the code sync carries prompts rules fly"
S="$T/src"; mkdir -p "$S/bin/lib" "$S/catalog" "$S/prompts" "$S/rules" "$S/fly" "$S/promptsx"
( cd "$REPO" && scratch_install_closure bin/lib/lane-run-code.sh "$S" ) >/dev/null 2>&1 || bad "H1 setup: closure"
for f in lane-run-worker.sh project-lane-run.sh jobs-client.sh; do printf '#!/bin/bash\nexit 0\n' > "$S/bin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$T" > "$S/bin/lane-alert.sh"
chmod +x "$S/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$S/fleet.conf"
printf '{"fixture":true}\n' > "$S/catalog/fixture.json"
printf 'prompt A\n' > "$S/prompts/p.md"; printf 'rules A\n' > "$S/rules/CLAUDE.md"
printf 'fly A\n' > "$S/fly/x.sh"; printf 'near miss\n' > "$S/promptsx/n.md"
git_s() { git -C "$S" -c user.email=fixture@example.invalid -c user.name=fixture "$@"; }
git_s init -q -b main . && git_s add -A && git_s commit -q -m A || { echo "setup: git repo"; exit 1; }
A=$(git_s rev-parse HEAD)
M="$T/m"; mkdir -p "$M"
git_s archive HEAD bin catalog fleet.conf | tar -x -C "$M"   # the old image shape
printf 'old prompt\n' > "$M/old-marker"
: > "$T/alerts.txt"
# sync [env...] — one lrc_sync on M; rc in SRC, its line in SOUT.
sync() { SOUT=$(env "$@" HARNESS="$M" LANE_RUN_CODE_URL="file://$S" bash -c '. "$HARNESS/bin/lib/lane-run-code.sh" && lrc_sync'); SRC=$?; }
same() { diff -r "$S/$1" "$M/$1" >/dev/null 2>&1; }
treesum() { ( cd "$M" && find bin catalog fleet.conf prompts rules fly -type f -exec md5sum {} + 2>/dev/null | sort | md5sum ); }
sync
[ "$SRC" = 10 ] && [ "$SOUT" = "code unknown -> ${A:0:12}" ] && ok "H1 rc 10, code unknown -> A12" || bad "H1 rc=$SRC out=$SOUT"
for p in bin catalog fleet.conf prompts rules fly; do
  same "$p" && ok "H1 $p matches the commit" || bad "H1 $p differs from the commit"
done
[ ! -e "$M/promptsx" ] && ok "H1 the near miss promptsx/ is not copied" || bad "H1 promptsx/ copied"
[ "$(head -1 "$M/HARNESS_COMMIT")" = "$A" ] && ok "H1 HARNESS_COMMIT = A" || bad "H1 HARNESS_COMMIT"

# H2: a git whose archive of `rules` fails, the real git for everything else.
printf 'rules B\n' > "$S/rules/CLAUDE.md"; printf 'prompt B\n' > "$S/prompts/p.md"
git_s commit -q -am B; B=$(git_s rev-parse HEAD)
GB="$T/gitbin"; mkdir -p "$GB"; RG=$(command -v git)
cat > "$GB/git" <<EOF
#!/bin/bash
case " \$* " in *" archive "*" rules"*) echo "fixture: archive of rules fails" >&2; exit 128 ;; esac
exec "$RG" "\$@"
EOF
chmod +x "$GB/git"
SUM=$(treesum)
sync PATH="$GB:$PATH"
[ "$SRC" = 1 ] && ok "H2 rc 1" || bad "H2 rc=$SRC out=$SOUT"
[ "$(grep -c '^code sync failed' <<<"$SOUT")" = 1 ] && ok "H2 one failure line: $SOUT" || bad "H2 out=$SOUT"
[ "$(treesum)" = "$SUM" ] && [ "$(head -1 "$M/HARNESS_COMMIT")" = "$A" ] && ok "H2 the tree and HARNESS_COMMIT unchanged" || bad "H2 tree changed"
[ -z "$(ls -d "$M"/state/lane-run-code/stage-* "$M"/state/lane-run-code/old-* 2>/dev/null)" ] && ok "H2 no stage or old copy left" \
  || bad "H2 left: $(ls "$M/state/lane-run-code")"
sync
[ "$SRC" = 10 ] && same rules && same prompts && ok "H2 control: the real git swaps to B" || bad "H2 control rc=$SRC $SOUT"

# H3: main drops prompts rules fly; the root keeps its own copies.
git_s rm -rq prompts rules fly && git_s commit -q -m C; C=$(git_s rev-parse HEAD)
SUM3=$( cd "$M" && find prompts rules fly -type f -exec md5sum {} + 2>/dev/null | sort | md5sum )
sync
[ "$SRC" = 10 ] && [ "$(head -1 "$M/HARNESS_COMMIT")" = "$C" ] && ok "H3 rc 10, HARNESS_COMMIT = C" || bad "H3 rc=$SRC $SOUT"
[ -f "$M/rules/CLAUDE.md" ] && [ "$( cd "$M" && find prompts rules fly -type f -exec md5sum {} + 2>/dev/null | sort | md5sum )" = "$SUM3" ] \
  && ok "H3 prompts rules fly untouched" || bad "H3 the root's prompts/rules/fly changed"

HDR=$(sed -n '1,45p' "$LRC")
grep -q 'swaps in its bin, catalog, fleet.conf,$' <<<"$HDR" && grep -q 'git archive of bin catalog fleet.conf, plus prompts rules fly' <<<"$HDR" \
  && grep -qx '_LRC_SWAP="fleet.conf catalog prompts rules fly bin"' "$LRC" \
  && ok "H4 the header names the six paths" || bad "H4 header"

echo "K1: the secret list and the operator command"
grep -q 'FLY_API_TOKEN_project-6_OS' "$TOML" && ok "K1 the toml names FLY_API_TOKEN_project-6_OS" || bad "K1 toml lacks the token"
grep -qF '. /etc/harness/env/fly.env' "$TOML" && grep -qF "printf 'FLY_API_TOKEN_project-6_OS=%s\\n' \"\$FLY_API_TOKEN_project-6_OS\"" "$TOML" \
  && grep -q 'flyctl secrets import -a lane-run-mk --stage' "$TOML" \
  && ok "K1 the staging command reads stdin (no value in argv)" || bad "K1 no stdin secrets import"
grep -qF -- '--build-arg FLYCTL_VERSION=$($JC setting-get bake.flyctl.version)' "$TOML" && ok "K1 FLYCTL_VERSION build arg" || bad "K1 no FLYCTL_VERSION arg"
grep 'lf_alert app-secrets' "$REPO/bin/lane-fleet.sh" | grep -q 'FLY_API_TOKEN_' \
  && ok "K1 the app-secrets alert names FLY_API_TOKEN_" || bad "K1 lane-fleet.sh alert"

echo "K2-K4: the entrypoint writes fly.env"
E="$T/e"; mkdir -p "$E/bin/lib" "$E/env" "$T/home"
( cd "$REPO" && scratch_install_closure fly/lane-run-entrypoint.sh "$E" ) >/dev/null 2>&1 || bad "K2 setup: closure"
printf '#!/bin/bash\nenv > "%s/w.env"\n' "$T" > "$E/bin/lane-run-worker.sh"; chmod +x "$E/bin/lane-run-worker.sh"
TOK='FlyV1 fm2_fixture-TK-7516=tail,a/b+c'; ORG='FlyV1 fixture-org-7516'
boot() { # boot <out> [env...]
  local o="$1"; shift
  ( env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-hs-7516 \
      JOBS_URL=http://192.0.2.1 FLY_MACHINE_ID=fixturemid75 "$@" bash "$E/fly/lane-run-entrypoint.sh" ) > "$o" 2>&1
}
boot "$T/k2.out" FLY_API_TOKEN_project-6_OS="$TOK" FLY_API_TOKEN="$ORG"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/w.env" ] && ok "K2 the entrypoint exec'd the worker" || bad "K2 rc=$rc: $(cat "$T/k2.out")"
[ "$(stat -c %a "$E/env/fly.env" 2>/dev/null || stat -f %Lp "$E/env/fly.env" 2>/dev/null)" = 600 ] && ok "K2 fly.env mode 600" || bad "K2 fly.env mode/missing"
[ "$(grep -c . "$E/env/fly.env")" = 2 ] && ok "K2 fly.env has the two token lines" || bad "K2 fly.env lines: $(grep -c . "$E/env/fly.env")"
R=$(env -i PATH="$PATH" bash -c 'set -a; . "$1"; set +a; . "$2"; fly_token_resolve project-6-os && printf "%s|%s" "$FLY_TOKEN_SRC" "$([ "$FLY_TOKEN_VAL" = "$3" ] && echo same)"' \
  _ "$E/env/fly.env" "$REPO/bin/lib/fly-token.sh" "$TOK")
[ "$R" = 'FLY_API_TOKEN_project-6_OS|same' ] && ok "K2 fly_token_resolve on the sourced file: FLY_API_TOKEN_project-6_OS" || bad "K2 resolve: $R"
R=$(env -i PATH="$PATH" bash -c 'set -a; . "$1"; set +a; . "$2"; fly_token_resolve project-3 && printf "%s" "$FLY_TOKEN_SRC"' _ "$E/env/fly.env" "$REPO/bin/lib/fly-token.sh")
[ "$R" = FLY_API_TOKEN ] && ok "K2 another project falls back to FLY_API_TOKEN" || bad "K2 org fallback: $R"
grep -q -e 'fixture-TK-7516' -e "$ORG" "$T/k2.out" && bad "K2 a token reached stdout/stderr" || ok "K2 no token on stdout/stderr"

boot "$T/k3.out" FLY_ACCESS_TOKEN=fixture-access-7516 FLY_API_TOKENX=fixture-x-7516 XFLY_API_TOKEN_A=fixture-xa-7516; rc=$?
[ "$rc" = 0 ] && [ -f "$E/env/fly.env" ] && [ ! -s "$E/env/fly.env" ] && ok "K3 fly.env exists and is empty" || bad "K3 rc=$rc fly.env: $(cat "$E/env/fly.env" 2>&1)"
[ "$(stat -c %a "$E/env/fly.env" 2>/dev/null || stat -f %Lp "$E/env/fly.env" 2>/dev/null)" = 600 ] && ok "K3 fly.env mode 600" || bad "K3 mode"
bash -n "$E/env/fly.env" && ( set -u; . "$E/env/fly.env" ) && ok "K3 the empty fly.env sources clean" || bad "K3 source"

scratch_rm "$E/env/fly.env"; mkdir "$E/env/fly.env"   # a directory: no write, even as root
boot "$T/k4.out" FLY_API_TOKEN_project-6_OS="$TOK"; rc=$?
[ "$rc" = 78 ] && ok "K4 rc 78" || bad "K4 rc=$rc"
grep -q 'lane-run-entrypoint: cannot write .*/fly.env' "$T/k4.out" && ok "K4 stderr names fly.env" || bad "K4 out: $(cat "$T/k4.out")"
grep -q 'fixture-TK-7516' "$T/k4.out" && bad "K4 the token reached stderr" || ok "K4 no value in stderr"
rmdir "$E/env/fly.env"

echo "P1: the preflight ingredients on the image's own tree"
IMG="$T/img"
PHS=$(sed -n 's/^ENV POOL_HARNESS_SRC=//p' "$LDF")
[ -n "$PHS" ] || bad "P1 setup: no ENV POOL_HARNESS_SRC in the Dockerfile"
# Each `COPY <src> /opt/harness/<dst>` the Dockerfile has, from the build context.
while read -r src dst; do
  mkdir -p "$IMG$(dirname "$dst")"; cp -R "$REPO/$src" "$IMG$dst"
done < <(awk '$1 == "COPY" && $3 ~ "^/opt/harness/" {print $2, $3}' "$LDF")
SRCDIR="$IMG${PHS:-/nonexistent}"
mkdir -p "$T/flybin"; printf '#!/bin/bash\necho "flyctl v0.0.0-fixture"\n' > "$T/flybin/flyctl"; chmod +x "$T/flybin/flyctl"
boot "$T/p1-boot.out" FLY_API_TOKEN_project-6_OS="$TOK"
mkdir -p "$T/p1home"
if [ -x "$SRCDIR/bin/fly-pool-project.sh" ]; then
  printf 'project-6-os example-org/project-6 https://os.example.com - 1 box-project-6-os-1 192.0.2.81\n' > "$SRCDIR/fleet.conf"
  OUT=$(env -i PATH="/usr/bin:/bin" HOME="$T/p1home" HARNESS="$SRCDIR" FLEET_CONF="$SRCDIR/fleet.conf" FLY_BIN_DIR="$T/flybin" \
    POOL_HARNESS_SRC="$SRCDIR" ETC_HARNESS_ENV="$T/no-etc" bash -c 'set -a; . "$1"; set +a; exec "$2/bin/fly-pool-project.sh" --preflight project-6-os' \
    _ "$E/env/fly.env" "$SRCDIR" 2>&1)
  [ "$OUT" = 'preflight project-6-os: missing env-bundle' ] && ok "P1 the real preflight: only env-bundle missing" || bad "P1 preflight: $OUT"
else
  echo "P1 note: bin/fly-pool-project.sh absent (#7515 not merged); ingredient checks only"
  OUT=""
  [ -x "$T/flybin/flyctl" ] && ok "P1 fly-binary: \$FLY_BIN_DIR/flyctl" || bad "P1 fly-binary"
  R=$(env -i PATH="/usr/bin:/bin" bash -c 'set -a; . "$1"; set +a; . "$2/bin/lib/fly-token.sh" && fly_token_resolve project-6-os && printf "%s" "$FLY_TOKEN_SRC"' \
    _ "$E/env/fly.env" "$SRCDIR" 2>&1)
  [ "$R" = FLY_API_TOKEN_project-6_OS ] && ok "P1 fly-token: FLY_API_TOKEN_project-6_OS from the image's fly-token.sh" || bad "P1 fly-token: $R"
  miss=""
  for d in bin prompts rules catalog fly; do [ -d "$SRCDIR/$d" ] || miss+=" $d"; done
  [ -z "$miss" ] && ok "P1 harness-src: $PHS holds bin prompts rules catalog fly" || bad "P1 harness-src: missing$miss under ${PHS:-<unset>}"
fi
grep -q 'fixture-TK-7516' <<<"$OUT$(cat "$T/p1-boot.out")" && bad "P1 the token reached an output" || ok "P1 no token in any output"

echo
echo "lane-run-image.bh-7516: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
