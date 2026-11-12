#!/bin/bash
# tests/wrangler-npx-selfheal.bh-9460-test.sh — one wrangler helper heals a
# broken npx cache, names a tool failure, and a stale worker pages again
# (BH-9460).
#
# WHY. A half-written ~/.npm/_npx/<hash> made every `npx --yes wrangler` fail
# with `npm error code ENOTEMPTY` before wrangler started. harness-sync never
# repaired it, retried 131 times, alerted `schema.sql statement 1/23 failed
# against D1` (a SQL error that never happened), and the deploy alert was held
# by its repeat window on a folded --id, so nobody was paged.
#
#   S1  ENOTEMPTY once, then green: rc 0, _npx/h1 moved aside, 2 npx calls
#   S2  ENOTEMPTY always: rc 87, 2 calls, the tool-error file holds the code
#   S3  banner + SQL error: rc 1, 1 call, nothing moved aside
#   S4  no path in the npm output: <cache>/_npx is moved; one aside is kept
#   D1  the tool-failure classifier, 10 cases (5 positive, 5+ negative)
#   I1  the pinned install writes current/.spec + .version, and the next
#       wrangler_run uses wrangler@<ver> on that cache
#   I2  an install killed mid-way leaves no current; the next run removes the
#       stage dir it left
#   I3  the install lock is held: rc 0 and no npx call
#   I4  a failed install is not retried inside HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S
#   I5  the pinned version is read from the package.json npx installed
#   A1  harness-sync: d1 execute always ENOTEMPTY: one `wrangler could not
#       start: ENOTEMPTY` alert, no `statement` alert, no per-statement re-run
#   A2  harness-sync: a real SQL error still alerts `statement 1/… failed
#       against D1`
#   A3  harness-sync: deploy tool failure alerts `wrangler could not start`
#       and leaves worker-deployed-<w> unchanged
#   P1  last deploy 6 h + 1 s old and the deploy fails: one stale page
#   P2  three more failures inside 6 h: still one stale page
#   P3  6 h + 1 s after the page: a second stale page
#   P4  last deploy 5 h 59 m old: no page; knob 0: no page
#   P5  a successful deploy removes the paged stamp
#   D2  stale page: no worker-deployed-<w> file = no page; a paged stamp in
#       the future counts as absent = page
#   C1  console-pages-deploy: an always-ENOTEMPTY npx alerts `wrangler could
#       not start: ENOTEMPTY`
#
# No network, no real npm: npx is a PATH stub. Every run has its own scratch.
# Run from anywhere: tests/wrangler-npx-selfheal.bh-9460-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null \
  || { echo "git/flock/timeout missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/wrangler-run.sh"
# line_has FILE FIXED REGEX: one line of FILE holds the fixed string and matches
# the regex. One awk read, no grep pipe into grep -q (flakes under pipefail).
line_has() { awk -v a="$2" -v b="$3" 'index($0, a) && $0 ~ b { f = 1 } END { exit !f }' "$1" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# Part 1: the helper, sourced directly.
# ════════════════════════════════════════════════════════════════════════════
U="$T/u"
mkdir -p "$U/state" "$U/locks" "$U/sbin" "$U/cache"
CALLS="$U/calls.log"
# The stub npx. $U/mode picks what it does:
#   enotempty-once   fail ENOTEMPTY (path under _npx/h1) on call 1, then pass
#   enotempty        always fail ENOTEMPTY with that path
#   nopath-once      fail EINTEGRITY with no _npx path on call 1, then pass
#   sqlerr           banner + a D1 SQL error, rc 1
#   install          `--version`: put wrangler 4.45.0 into $npm_config_cache
#   install-kill     `--version`: write half a cache, then kill its group
#   ok               banner, rc 0
cat > "$U/sbin/npx" <<EOF
#!/bin/bash
U="$U"
EOF
cat >> "$U/sbin/npx" <<'EOF'
printf '%s|cache=%s\n' "$*" "${npm_config_cache:-}" >> "$U/calls.log"
n=$(( $(cat "$U/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$U/count"
mode=$(cat "$U/mode" 2>/dev/null)
enotempty() {
  echo "npm warn exec The following package was not found and will be installed: wrangler@4.45.0"
  echo "npm error code ENOTEMPTY"
  echo "npm error syscall rename"
  echo "npm error path ${npm_config_cache}/_npx/h1/node_modules/@cloudflare/workerd-linux-64"
  echo "npm error dest ${npm_config_cache}/_npx/h1/node_modules/@cloudflare/.workerd-linux-64-x1"
  echo "npm error errno -39"
  exit 1
}
case "$mode" in
  enotempty-once) [ "$n" = 1 ] && enotempty; echo " ⛅️ wrangler 4.45.0"; exit 0 ;;
  enotempty) enotempty ;;
  nopath-once)
    if [ "$n" = 1 ]; then echo "npm error code EINTEGRITY"; echo "npm error sha512 mismatch"; exit 1; fi
    echo " ⛅️ wrangler 4.45.0"; exit 0 ;;
  sqlerr)
    echo " ⛅️ wrangler 4.45.0"; echo "───────────────────"
    echo '✘ [ERROR] near "CREAT": syntax error at offset 0: SQLITE_ERROR'; exit 1 ;;
  install|install-kill)
    case "$*" in *--version*) ;; *) echo " ⛅️ wrangler 4.45.0"; exit 0 ;; esac
    h=$(printf '%s' "$2" | md5sum | cut -c1-8)
    mkdir -p "$npm_config_cache/_npx/$h/node_modules/wrangler"
    if [ "$mode" = install-kill ]; then
      : > "$npm_config_cache/_npx/$h/node_modules/wrangler/half-written"
      kill -KILL 0
    fi
    v=$(cat "$U/ver" 2>/dev/null || echo 4.45.0)
    printf '{\n  "name": "wrangler",\n  "version": "%s"\n}\n' "$v" > "$npm_config_cache/_npx/$h/node_modules/wrangler/package.json"
    echo " ⛅️ wrangler 4.45.0"; exit 0 ;;
esac
echo " ⛅️ wrangler 4.45.0"; exit 0
EOF
chmod +x "$U/sbin/npx"

ureset() { rm -f "$CALLS" "$U/count" "$U/state/wrangler-tool-error"; scratch_rm "$U/cache"; mkdir -p "$U/cache"; echo "$1" > "$U/mode"; }
ncalls() { local n; n=$(grep -c . "$CALLS" 2>/dev/null) || n=0; printf '%s' "$n"; }
# urun <fn> <args…> — call one lib function in a fresh shell. stdout -> $U/out.
urun() {
  ( export HARNESS="$U" PATH="$U/sbin:$PATH" npm_config_cache="$U/cache"
    unset HARNESS_SYNC_WRANGLER_SPEC HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S
    . "$LIB" || exit 99
    "$@" ) >"$U/out" 2>&1
  URC=$?
}

[ -f "$LIB" ] && ok || bad "lib: $LIB exists"

# ── S1 ───────────────────────────────────────────────────────────────────────
ureset enotempty-once; mkdir -p "$U/cache/_npx/h1/node_modules"
urun wrangler_run 5 d1 execute db --command x
[ "$URC" = 0 ] && ok || bad "S1: a healed ENOTEMPTY returns 0 (rc $URC): $(cat "$U/out")"
[ "$(ncalls)" = 2 ] && ok || bad "S1: the stub ran exactly twice: $(cat "$CALLS" 2>/dev/null)"
[ ! -e "$U/cache/_npx/h1" ] && ls -d "$U/cache/_npx/h1.aside-"* >/dev/null 2>&1 && ok \
  || bad "S1: _npx/h1 is moved to h1.aside-*: $(ls -a "$U/cache/_npx" 2>&1)"
grep -q 'wrangler-run: npx cache healed (ENOTEMPTY), moved .*/_npx/h1 aside' "$U/out" && ok \
  || bad "S1: one heal line: $(cat "$U/out")"
grep -q 'd1 execute db --command x' "$CALLS" 2>/dev/null && grep -q -- '--yes wrangler d1' "$CALLS" && ok \
  || bad "S1: the argv is npx --yes wrangler <args>: $(cat "$CALLS" 2>/dev/null)"

# ── S2 ───────────────────────────────────────────────────────────────────────
ureset enotempty; mkdir -p "$U/cache/_npx/h1/node_modules"
urun wrangler_run 5 deploy
[ "$URC" = 87 ] && ok || bad "S2: a tool failure that survives the retry returns 87 (rc $URC): $(cat "$U/out")"
[ "$(ncalls)" = 2 ] && ok || bad "S2: one retry, 2 calls: $(cat "$CALLS" 2>/dev/null)"
[ "$(cat "$U/state/wrangler-tool-error" 2>/dev/null)" = ENOTEMPTY ] && ok \
  || bad "S2: state/wrangler-tool-error = ENOTEMPTY: $(cat "$U/state/wrangler-tool-error" 2>&1)"
grep -q 'healed' "$U/out" && bad "S2: no heal line when the retry failed: $(cat "$U/out")" || ok

# ── S3 ───────────────────────────────────────────────────────────────────────
ureset sqlerr; mkdir -p "$U/cache/_npx/h1"
urun wrangler_run 5 d1 execute db --command x
[ "$URC" = 1 ] && ok || bad "S3: a SQL error returns wrangler's rc 1 (rc $URC)"
[ "$(ncalls)" = 1 ] && ok || bad "S3: no retry on a SQL error: $(cat "$CALLS" 2>/dev/null)"
[ -d "$U/cache/_npx/h1" ] && ! ls -d "$U/cache/_npx/"*.aside-* >/dev/null 2>&1 && ok \
  || bad "S3: nothing is moved aside: $(ls -a "$U/cache/_npx" 2>&1)"
grep -q 'SQLITE_ERROR' "$U/out" && ok || bad "S3: wrangler's output reaches the caller: $(cat "$U/out")"

# ── S4 ───────────────────────────────────────────────────────────────────────
ureset nopath-once; mkdir -p "$U/cache/_npx/zz"
urun wrangler_run 5 deploy
[ "$URC" = 0 ] && [ ! -e "$U/cache/_npx" ] && [ "$(ls -d "$U/cache/_npx.aside-"* 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "S4: no path in the output moves <cache>/_npx aside (rc $URC): $(ls -a "$U/cache" 2>&1)"
rm -f "$U/count"; mkdir -p "$U/cache/_npx/yy"
# A second heal a second later replaces the first aside copy.
mv "$U/cache/"_npx.aside-* "$U/cache/_npx.aside-1000" 2>/dev/null
urun wrangler_run 5 deploy
[ "$URC" = 0 ] && [ "$(ls -d "$U/cache/_npx.aside-"* 2>/dev/null | wc -l)" = 1 ] && [ ! -e "$U/cache/_npx.aside-1000" ] && ok \
  || bad "S4: a second heal keeps only one aside copy (rc $URC): $(ls -a "$U/cache" 2>&1)"

# ── D1: the classifier ───────────────────────────────────────────────────────
cls() { printf '%b' "$2" > "$U/cls.txt"; urun wrangler_tool_code "$U/cls.txt"; local got; got=$(cat "$U/out")
  [ "$got" = "$1" ] && ok || bad "D1 $3: want '$1', got '$got'"; }
cls ENOTEMPTY 'npm error code ENOTEMPTY\nnpm error syscall rename\nnpm error path /root/.npm/_npx/abc123/node_modules/@cloudflare/workerd-linux-64\n' "(a) ENOTEMPTY"
cls ENOENT 'npm ERR! code ENOENT\nnpm ERR! syscall open\n' "(b) old npm ERR! format"
cls EINTEGRITY 'npm error code EINTEGRITY\n' "(c) EINTEGRITY"
cls ENOTEMPTY 'npm warn a\nnpm warn b\nnpm warn c\nnpm error code ENOTEMPTY\n' "(d) after 3 warn lines"
cls '' ' ⛅️ wrangler 4.45.0\n✘ [ERROR] near "CREAT": syntax error at offset 0: SQLITE_ERROR\n' "(e) SQL error after the banner"
cls '' ' ⛅️ wrangler 4.45.0\nAuthentication error [code: 10000]\n' "(f) auth error"
cls '' '' "(g) empty output (killed)"
cls '' ' ⛅️ wrangler 4.45.0\nbuild failed:\nnpm error code E404\n' "(h) npm line AFTER the banner"
cls '' 'npm error code\n' "(i) no E-code"
cls '' 'D1_ERROR: ENOTEMPTY in a message\n' "(j) ENOTEMPTY with no npm prefix"
cls '' 'wrangler 3.114.0\nnpm ERR! code ENOENT\n' "(k) plain banner then npm line"

# ── I1: the pinned install ───────────────────────────────────────────────────
ureset install
urun wrangler_install
CUR="$U/state/wrangler-npx/current"
[ "$URC" = 0 ] && [ -L "$CUR" ] && [ "$(cat "$CUR/.version" 2>/dev/null)" = 4.45.0 ] && [ "$(cat "$CUR/.spec" 2>/dev/null)" = wrangler ] && ok \
  || bad "I1: current/.version = 4.45.0, .spec = wrangler (rc $URC): $(cat "$U/out"; ls -la "$U/state/wrangler-npx" 2>&1)"
grep -q 'wrangler-install: current is wrangler@4.45.0' "$U/out" && ok || bad "I1: the install logs its version: $(cat "$U/out")"
ls -d "$U/state/wrangler-npx/.stage."* >/dev/null 2>&1 && bad "I1: no stage dir is left" || ok
rm -f "$CALLS"
urun wrangler_run 5 deploy
REAL=$(readlink -f "$CUR")
[ "$URC" = 0 ] && grep -qF -- "--yes wrangler@4.45.0 deploy|cache=$REAL" "$CALLS" 2>/dev/null && ok \
  || bad "I1: wrangler_run uses wrangler@4.45.0 on the pinned cache (rc $URC): $(cat "$CALLS" 2>/dev/null)"
rm -f "$CALLS"
urun wrangler_run --spec wrangler@3 5 pages deploy dist
grep -qF -- "--yes wrangler@3 pages deploy dist|cache=$U/cache" "$CALLS" 2>/dev/null && ok \
  || bad "I1: an explicit --spec keeps the shared cache: $(cat "$CALLS" 2>/dev/null)"
rm -f "$CALLS"
urun wrangler_install
[ "$URC" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "I1: an install that is current makes no npx call: $(cat "$CALLS" 2>/dev/null)"

# ── I5: the version comes from the installed package.json ──────────────────
scratch_rm "$U/state/wrangler-npx"; ureset install; echo 4.46.1 > "$U/ver"
urun wrangler_install
[ "$URC" = 0 ] && [ "$(cat "$U/state/wrangler-npx/current/.version" 2>/dev/null)" = 4.46.1 ] && grep -q -- '--yes wrangler@4.46.1 --version' "$CALLS" && ok \
  || bad "I5: the pinned version is the one npx installed (rc $URC): $(cat "$U/out"; cat "$CALLS")"
rm -f "$U/ver"

# ── I2: killed mid-install ───────────────────────────────────────────────────
scratch_rm "$U/state/wrangler-npx"; ureset install-kill
{ ( export HARNESS="$U" PATH="$U/sbin:$PATH" npm_config_cache="$U/cache"
    setsid -w bash -c '. "$1" && wrangler_install' _ "$LIB" ) >/dev/null 2>&1; } 2>/dev/null
[ ! -e "$U/state/wrangler-npx/current" ] && ok || bad "I2: a killed install leaves no current"
ls -d "$U/state/wrangler-npx/.stage."* >/dev/null 2>&1 && ok || bad "I2: the kill left its stage dir (fixture check)"
echo install > "$U/mode"
urun wrangler_install
[ "$URC" = 0 ] && ! ls -d "$U/state/wrangler-npx/.stage."* >/dev/null 2>&1 && [ "$(cat "$U/state/wrangler-npx/current/.version" 2>/dev/null)" = 4.45.0 ] && ok \
  || bad "I2: the next install removes the old stage and completes (rc $URC): $(ls -la "$U/state/wrangler-npx" 2>&1)"

# ── I3: the lock is held ─────────────────────────────────────────────────────
scratch_rm "$U/state/wrangler-npx"; ureset install
exec 5>"$U/locks/wrangler-install.lock"; flock -n 5
urun wrangler_install
exec 5>&-
[ "$URC" = 0 ] && [ "$(ncalls)" = 0 ] && [ ! -e "$U/state/wrangler-npx/current" ] && ok \
  || bad "I3: a held lock returns 0 with no npx call (rc $URC): $(cat "$CALLS" 2>/dev/null)"

# ── I4: a failed install backs off ───────────────────────────────────────────
scratch_rm "$U/state/wrangler-npx"; ureset ok
urun wrangler_install
[ "$URC" = 1 ] && [ ! -e "$U/state/wrangler-npx/current" ] && ! ls -d "$U/state/wrangler-npx/.stage."* >/dev/null 2>&1 && ok \
  || bad "I4: an install with no package.json fails, current untouched, stage removed (rc $URC): $(cat "$U/out")"
n1=$(ncalls)
urun wrangler_install
[ "$URC" = 0 ] && [ "$(ncalls)" = "$n1" ] && ok || bad "I4: a retry inside the window makes no npx call: $(cat "$CALLS")"
( export HARNESS="$U" PATH="$U/sbin:$PATH" npm_config_cache="$U/cache" HARNESS_SYNC_WRANGLER_INSTALL_RETRY_S=0
  . "$LIB" && wrangler_install ) >/dev/null 2>&1
[ "$(ncalls)" -gt "$n1" ] && ok || bad "I4: knob 0 retries at once"

# ════════════════════════════════════════════════════════════════════════════
# Part 2: bin/harness-sync.sh, the production caller.
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/prompts" \
         "$H/fly" "$H/catalog" "$H/checks" "$H/guardrails" "$H/config" "$H/env" "$H/fakebin" "$H/npmcache"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
ALERTS="$H/logs/ALERTS.log"; ULOG="$H/logs/update-runners.log"; NPXLOG="$H/npx.log"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$H/env/cloudflare.env"
# npx: $H/d1.mode and $H/deploy.mode are ok | enotempty | sqlerr.
cat > "$H/fakebin/npx" <<EOF
#!/bin/bash
H="$H"
EOF
cat >> "$H/fakebin/npx" <<'EOF'
printf '%s | %s\n' "$PWD" "$(printf '%s ' "$@" | tr '\n\t' '  ')" >> "$H/npx.log"
case "$*" in
  *"d1 execute"*) m=$(cat "$H/d1.mode" 2>/dev/null) ;;
  *" deploy"*)    m=$(cat "$H/deploy.mode" 2>/dev/null) ;;
  *) exit 0 ;;
esac
case "$m" in
  enotempty) echo "npm error code ENOTEMPTY"; echo "npm error path ${npm_config_cache}/_npx/h1/node_modules/x"; exit 1 ;;
  sqlerr) echo " ⛅️ wrangler 4.45.0"; echo '✘ [ERROR] near "CREAT": syntax error at offset 0: SQLITE_ERROR'; exit 1 ;;
esac
echo " ⛅️ wrangler 4.45.0"; exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/fakebin/npm"
chmod +x "$H/fakebin/npx" "$H/fakebin/npm"
if ! command -v rsync >/dev/null; then
  cat > "$H/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$H/fakebin/rsync"
fi

git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" "$T/ck/worker/jobs/src" "$T/ck/worker/jobs/schema.d"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"; printf 'f\n' > "$T/ck/fly/f.txt"; printf 'fleet\n' > "$T/ck/fleet.conf"
printf 'CREATE TABLE IF NOT EXISTS t1 (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0001-t1.sql"
printf 'CREATE TABLE IF NOT EXISTS t2 (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0002-t2.sql"
# The composer: concatenate the fragments into --to.
cat > "$T/ck/bin/schema-build.sh" <<'EOF'
#!/bin/bash
to=""; root=""; w=""
while [ $# -gt 0 ]; do case "$1" in --to) to=$2; shift 2 ;; --root) root=$2; shift 2 ;; --worker) w=$2; shift 2 ;; *) shift ;; esac; done
cat "$root/worker/$w/schema.d/"*.sql > "$to"
EOF
chmod +x "$T/ck/bin/schema-build.sh"
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js",
  "d1_databases": [ { "binding": "DB", "database_name": "jobs-db", "database_id": "x" } ] }
EOF
printf 'export default {};\n' > "$T/ck/worker/jobs/src/index.js"
git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null; git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$T/ck" PATH="$H/fakebin:$PATH" npm_config_cache="$H/npmcache"
    bash "$DIR/bin/harness-sync.sh" ) >"$H/out.txt" 2>"$H/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; }
count() { local n; n=$(grep -cF -- "$1" "$ALERTS" 2>/dev/null) || n=0; printf '%s' "$n"; }
d1calls() { local n; n=$(grep -c 'd1 execute' "$NPXLOG" 2>/dev/null) || n=0; printf '%s' "$n"; }
deploys() { local n; n=$(grep -c 'wrangler deploy\|wrangler@[0-9.]* deploy' "$NPXLOG" 2>/dev/null) || n=0; printf '%s' "$n"; }
bump() { printf 'export default { v: %s };\n' "$1" > "$T/ck/worker/jobs/src/index.js"
  git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "bump $1"; git -C "$T/ck" push -q origin main; }
DEP="$H/state/worker-deployed-jobs"; PAGED="$H/state/worker-stale-paged/jobs"

# Setup: a clean first pass applies the schema and deploys.
echo ok > "$H/d1.mode"; echo ok > "$H/deploy.mode"; reset_run
sync
[ "$RC" = 0 ] && [ -s "$DEP" ] && ok || bad "setup: the first pass deploys jobs (rc $RC): $(cat "$NPXLOG") $(cat "$H/err.txt")"

# ── A1: d1 execute tool failure ─────────────────────────────────────────────
# A new schema statement, so the apply has 1 statement to send... two, so the
# batch path runs first.
printf 'CREATE TABLE IF NOT EXISTS t3 (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0003-t3.sql"
printf 'CREATE TABLE IF NOT EXISTS t4 (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0004-t4.sql"
bump 1; reset_run; echo enotempty > "$H/d1.mode"; D0=$(cat "$DEP")
sync
[ "$(count 'wrangler could not start: ENOTEMPTY')" = 1 ] && ok \
  || bad "A1: one 'wrangler could not start: ENOTEMPTY' alert: $(cat "$ALERTS")"
[ "$(count 'statement')" = 0 ] && ok || bad "A1: no statement alert on a tool failure: $(cat "$ALERTS")"
line_has "$ALERTS" 'wrangler could not start' 'no SQL reached D1 jobs-db' && ok \
  || bad "A1: the alert says no SQL reached D1: $(cat "$ALERTS")"
[ "$(d1calls)" = 2 ] && ok || bad "A1: the batch and its one retry, no per-statement re-run: $(cat "$NPXLOG")"
[ "$(deploys)" = 0 ] && [ "$(cat "$DEP")" = "$D0" ] && ok || bad "A1: no deploy: $(cat "$NPXLOG")"
[ -s "$H/state/worker-wrangler-tool-failing-jobs" ] && ok || bad "A1: the wrangler-tool failing state is kept"

# ── A2: a real SQL error keeps its statement alert ──────────────────────────
reset_run; echo sqlerr > "$H/d1.mode"; rm -f "$H/state/worker-wrangler-tool-failing-jobs"
sync
line_has "$ALERTS" 'statement 1/' 'failed against D1' && ok \
  || bad "A2: a SQL error alerts 'statement 1/… failed against D1': $(cat "$ALERTS")"
[ "$(count 'wrangler could not start')" = 0 ] && ok || bad "A2: a SQL error is not a tool failure: $(cat "$ALERTS")"

# ── A3: deploy tool failure ──────────────────────────────────────────────────
reset_run; echo ok > "$H/d1.mode"; echo enotempty > "$H/deploy.mode"
sync
line_has "$ALERTS" 'wrangler could not start: ENOTEMPTY' 'deploy of jobs SKIPPED, LIVE WORKER IS STALE' && ok \
  || bad "A3: a deploy tool failure alerts 'wrangler could not start': $(cat "$ALERTS")"
[ "$(cat "$DEP")" = "$D0" ] && ok || bad "A3: worker-deployed-jobs is unchanged"
[ "$(deploys)" = 2 ] && ok || bad "A3: the deploy ran once plus one retry: $(cat "$NPXLOG")"

# ── P1-P4, D2: the stale page ───────────────────────────────────────────────
NOW=3000000000
stale() { local n; n=$(grep -cF 'behind origin/main' "$ALERTS" 2>/dev/null) || n=0; printf '%s' "$n"; }
rm -f "$H"/state/worker-*-failing-jobs "$PAGED"; : > "$ALERTS"
touch -d "@$((NOW - 21601))" "$DEP"
HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 1 ] && ok || bad "P1: a 6 h + 1 s stale worker pages once: $(cat "$ALERTS")"
line_has "$ALERTS" 'behind origin/main' 'worker/jobs is 6h behind origin/main [(]last deploy .*[)] — LIVE WORKER IS STALE' && ok \
  || bad "P1: the page text: $(cat "$ALERTS")"
[ "$(cat "$PAGED" 2>/dev/null)" = "$NOW" ] && ok || bad "P1: the paged stamp is written: $(cat "$PAGED" 2>&1)"
for s in 600 1200 1800; do HARNESS_SYNC_NOW=$((NOW + s)) sync; done
[ "$(stale)" = 1 ] && ok || bad "P2: three more failures inside 6 h: still one page: $(grep -F 'behind' "$ALERTS")"
HARNESS_SYNC_NOW=$((NOW + 21601)) sync
[ "$(stale)" = 2 ] && ok || bad "P3: 6 h + 1 s later: a second page: $(grep -F 'behind' "$ALERTS")"
: > "$ALERTS"; rm -f "$PAGED"; touch -d "@$((NOW - 21540))" "$DEP"
HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 0 ] && ok || bad "P4: a 5 h 59 m stale worker does not page: $(cat "$ALERTS")"
touch -d "@$((NOW - 90000))" "$DEP"
HARNESS_SYNC_WORKER_STALE_PAGE_S=0 HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 0 ] && ok || bad "P4: knob 0 does not page: $(cat "$ALERTS")"
# D2 (g): a paged stamp in the future counts as absent.
echo $((NOW + 99999)) > "$PAGED"
HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 1 ] && ok || bad "D2 (g): a future paged stamp counts as absent: $(cat "$ALERTS")"
# D2 (e): no worker-deployed file: no page.
: > "$ALERTS"; rm -f "$PAGED"; mv "$DEP" "$DEP.keep"
HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 0 ] && ok || bad "D2 (e): a never-deployed worker does not page: $(cat "$ALERTS")"
mv "$DEP.keep" "$DEP"
# D2 (a2): the stale page also rides a real SQL-statement failure.
: > "$ALERTS"; rm -f "$PAGED"; echo sqlerr > "$H/d1.mode"
printf 'CREATE TABLE IF NOT EXISTS t5 (id INTEGER);\n' > "$T/ck/worker/jobs/schema.d/0005-t5.sql"; bump 2
touch -d "@$((NOW - 30000))" "$DEP"
HARNESS_SYNC_NOW=$NOW sync
[ "$(stale)" = 1 ] && [ "$(count 'failed against D1')" = 1 ] && ok \
  || bad "D2: a SQL-statement failure on a stale worker pages too: $(cat "$ALERTS")"

# ── P5: a good deploy clears the paged stamp and the tool state ─────────────
echo ok > "$H/d1.mode"; echo ok > "$H/deploy.mode"; reset_run
HARNESS_SYNC_NOW=$NOW sync
[ "$(cat "$DEP")" != "$D0" ] && [ ! -e "$PAGED" ] && [ ! -e "$H/state/worker-wrangler-tool-failing-jobs" ] && ok \
  || bad "P5: a good deploy removes the paged stamp and the wrangler-tool state: $(ls "$H/state")"

# ════════════════════════════════════════════════════════════════════════════
# Part 3: bin/console-pages-deploy.sh, the other hub caller.
# ════════════════════════════════════════════════════════════════════════════
C="$T/c"
mkdir -p "$C/bin/lib" "$C/env" "$C/logs" "$C/state" "$C/locks" "$C/sbin"
( cd "$DIR" && scratch_install_closure bin/console-pages-deploy.sh "$C" ) >/dev/null || { echo "setup: could not install the deployer closure"; exit 1; }
[ -f "$C/bin/lib/wrangler-run.sh" ] && ok || bad "C1: the deployer's closure carries bin/lib/wrangler-run.sh"
printf 'CLOUDFLARE_API_TOKEN=fixture-tok-9460\n' > "$C/env/cloudflare.env"
CK2="$T/ck2"
g() { git -C "$CK2" -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkdir -p "$CK2/console-ui" "$CK2/worker/jobs"
echo '{"name":"console-ui"}' > "$CK2/console-ui/package.json"
printf '{ "account_id": "acct123" }\n' > "$CK2/worker/jobs/wrangler.jsonc"
g init -q -b main "$CK2"; g add -A; g commit -q -m base
cat > "$C/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
[ "$1" = setting-get ] && exit 2
exit 0
EOF
cat > "$C/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf 'lane-alert %s\n' "\$*" >> "$C/calls.log"
EOF
cat > "$C/sbin/npm" <<'EOF'
#!/bin/bash
case "$1" in
  ci) mkdir -p node_modules ;;
  test) printf 'TAP version 13\nok 1 - t\n# pass 1\n# fail 0\n' ;;
  run) mkdir -p dist; echo '<html>' > dist/index.html ;;
esac
exit 0
EOF
cat > "$C/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$C/calls.log"
echo "npm error code ENOTEMPTY"; exit 1
EOF
printf '#!/bin/bash\nprintf 403\n' > "$C/sbin/curl"
chmod +x "$C/bin/"*.sh "$C/sbin/"*
( env -u CLOUDFLARE_API_TOKEN HARNESS="$C" HARNESS_CHECKOUT="$CK2" HARNESS_ENV_DIR="$C/env" PATH="$C/sbin:$PATH" \
    npm_config_cache="$C/npmcache" CONSOLE_PAGES_PROBE_WAIT_S=0 bash "$C/bin/console-pages-deploy.sh" ) >"$C/run.log" 2>&1
line_has "$C/calls.log" '--id console-pages-deploy-failed' 'wrangler could not start: ENOTEMPTY' && ok \
  || bad "C1: console-pages-deploy alerts 'wrangler could not start: ENOTEMPTY': $(cat "$C/calls.log" 2>/dev/null) $(tail -5 "$C/run.log")"
[ "$(grep -c '^npx ' "$C/calls.log" 2>/dev/null)" = 2 ] && grep -q '^npx --yes wrangler@3 pages deploy dist' "$C/calls.log" && ok \
  || bad "C1: the argv is unchanged and the call is retried once: $(cat "$C/calls.log" 2>/dev/null)"

echo "wrangler-npx-selfheal.bh-9460-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
