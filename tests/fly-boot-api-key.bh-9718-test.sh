#!/bin/bash
# tests/fly-boot-api-key.bh-9718-test.sh — BH-9718: a Fly machine of a project
# whose settings row claude_auth.<project> is `api-key`.
#
# ENTRYPOINT (B): fly/entrypoint.sh from `# >>> seed (BH-7430)` through
# `# <<< api-key (BH-9718)` is lifted by its markers and run on a scratch root
# (BOOT_ROOT), with a stub harness fetch and a counting fake curl (the
# BH-7430 technique). The block stages the app secret ANTHROPIC_API_KEY_<P> in
# RAM as claude-api-key.env and unsets every ANTHROPIC_API_KEY_* name.
# RUNNER (R): fly/builder-runner.sh's real load_env and the head of warm_up
# (through its api-key guard) are lifted and run in one shell.
#
# PINNED:
#   B1 the secret is staged: one line, mode 600; no ANTHROPIC_API_KEY_* name is
#      left for the runner; the log names the secret, not the value.
#   B2 two projects' secrets on one app: only this project's key is staged.
#   B3 pull path, marker, no secret: ONE `BUILD_DEFERRED api-key:` PUT, exit 1,
#      the runner not reached.
#   B4 pull path, marker, secret: no PUT, the runner reached.
#   B5 push path (no global.env yet), no secret: no stop.
#   B6 oauth bundle on the pull path, no secret: no stop, no file.
#   B7 project p.key: no valid secret name, nothing staged, the marker stops it.
#   B8 no log or captured output holds the key value.
#   R1 marker + staged file: ANTHROPIC_API_KEY is the staged value, no OAuth token.
#   R2 marker + an inherited ANTHROPIC_API_KEY, no file: the key is dropped,
#      warm_up returns 1.
#   R3 marker, no file: warm_up returns 1, the log names the file.
#   R4 no marker, file present: no key exported, the OAuth token kept.
#   R5 api-key job then oauth job in one shell: the second has no key, no mode.
#   R6 oauth job then api-key job: the second has the key and no OAuth token.
#   R7 marker value API-KEY: treated as oauth, no key exported.
# Run from anywhere: bash tests/fly-boot-api-key.bh-9718-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/warmup-guard.bh-9783.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Built at run time: no key-shaped literal sits in this file.
KEY_A="sk-ant-api""03-FIXTURE-p-key-own-key"
KEY_B="sk-ant-api""03-FIXTURE-other-project-key"
TOK="sk-ant-oat""01-FIXTURE-oauth-token"

# ══ B: the entrypoint block ═════════════════════════════════════════════════
EP="$DIR/fly/entrypoint.sh"
BLOCK=$(sed -n '/^# >>> seed (BH-7430)/,/^# <<< api-key (BH-9718)/p' "$EP")
# A lift with no end marker runs to the end of the file, and that execs the
# runner at its real path. So a missing marker stops the suite here.
if grep -q '^# >>> api-key (BH-9718)' <<<"$BLOCK" && grep -q '^# <<< api-key (BH-9718)' <<<"$BLOCK" \
   && grep -q '^# <<< harness pull (BH-7430)' <<<"$BLOCK"; then ok; else
  bad "B0: the api-key block (# >>> / # <<< api-key (BH-9718)) must follow '# <<< harness pull (BH-7430)' in fly/entrypoint.sh"
  echo "fly-boot-api-key (BH-9718): $PASS passed, $FAIL failed"; exit 1
fi
mkdir -p "$T/fakebin" "$T/cap"
cat > "$T/fakebin/curl" <<'C'
#!/bin/bash
m=GET; d=""; u=""; prev=""
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary) d="$a" ;; esac
  case "$a" in http*) u="$a" ;; esac
  prev="$a"
done
printf '%s %s %s\n' "$m" "$u" "$d" >> "$CURL_SINK"
C
printf '#!/bin/bash\n:\n' > "$T/fakebin/sleep"
chmod +x "$T/fakebin"/*
mkroot() { # mkroot <case> -> R
  R="$T/root-$1"
  mkdir -p "$R/run/harness-env" "$R/run/harness" "$R/data/harness/fly" "$R/opt/fly-boot"
  printf '#!/bin/bash\necho runner\n' > "$R/data/harness/fly/builder-runner.sh"; chmod +x "$R/data/harness/fly/builder-runner.sh"
  printf '#!/bin/bash\necho "harness-fetch: ok"\n' > "$R/opt/fly-boot/harness-fetch.sh"; chmod +x "$R/opt/fly-boot/harness-fetch.sh"
  printf '{"key":"BH-1"}\n' > "$R/run/harness/job.json"
}
# boot <case> <project> [VAR=val ...] -> rc in BRC, log $T/cap/<case>.log, PUTs $T/cap/<case>.curl
boot() {
  local c="$1" p="$2"; shift 2
  : > "$T/cap/$c.curl"; rm -f "$T/cap/$c.reached" "$T/cap/$c.env"
  cat > "$T/boot-$c.sh" <<EOF
log() { echo "entrypoint: \$*" >> "$T/cap/$c.log"; }
PROJECT=$p HOST=pool-$p-m1 FLY_MACHINE_ID=m1fixture BOOT_ROOT="$R"
$BLOCK
env > "$T/cap/$c.env"
echo REACHED > "$T/cap/$c.reached"
EOF
  env -i PATH="$T/fakebin:$PATH" CURL_SINK="$T/cap/$c.curl" "$@" bash "$T/boot-$c.sh" >"$T/cap/$c.out" 2>&1
  BRC=$?
}
STAGED() { printf '%s' "$R/run/harness-env/claude-api-key.env"; }
PULL_KEY=(HARNESS_SHA=0123456789abcdef0123456789abcdef01234567 HBUNDLE_SYNCED_AT=2026-11-16T00:00:00Z
          HBUNDLE_G_CLAUDE_AUTH_MODE=api-key HBUNDLE_G_JOBS_URL=https://jobs.invalid HBUNDLE_G_HARNESS_SECRET=FIXTURE-secret)
PULL_OAUTH=(HARNESS_SHA=0123456789abcdef0123456789abcdef01234567 HBUNDLE_SYNCED_AT=2026-11-16T00:00:00Z
          HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN="$TOK" HBUNDLE_G_JOBS_URL=https://jobs.invalid HBUNDLE_G_HARNESS_SECRET=FIXTURE-secret)
puts() { grep -c '^PUT ' "$T/cap/$1.curl" 2>/dev/null || true; }

# B1: push path, the secret is set
mkroot b1; boot b1 p-key ANTHROPIC_API_KEY_P_KEY="$KEY_A"
[ "$BRC" = 0 ] && [ -f "$T/cap/b1.reached" ] && ok || bad "B1: the boot must reach the runner (rc $BRC): $(cat "$T/cap/b1.out")"
[ "$(cat "$(STAGED)" 2>/dev/null)" = "ANTHROPIC_API_KEY=$KEY_A" ] && ok || bad "B1: claude-api-key.env must hold one ANTHROPIC_API_KEY line"
[ "$(stat -c %a "$(STAGED)" 2>/dev/null)" = 600 ] && ok || bad "B1: claude-api-key.env must be mode 600"
grep -q '^ANTHROPIC_API_KEY' "$T/cap/b1.env" && bad "B1: an ANTHROPIC_API_KEY* name reached the runner env" || ok
grep -q 'api-key: staged ANTHROPIC_API_KEY_P_KEY in RAM' "$T/cap/b1.log" && ok || bad "B1: the log must name the staged secret, got: $(cat "$T/cap/b1.log")"
[ "$(puts b1)" = 0 ] && ok || bad "B1: no PUT expected"
cp "$(STAGED)" "$T/b1-staged.env"

# B2: another project's secret on the same app
mkroot b2; boot b2 p-key ANTHROPIC_API_KEY_P_KEY="$KEY_A" ANTHROPIC_API_KEY_P_OTHER="$KEY_B"
grep -qF "$KEY_B" "$(STAGED)" && bad "B2: another project's key was staged" || ok
grep -qxF "ANTHROPIC_API_KEY=$KEY_A" "$(STAGED)" && ok || bad "B2: this project's key must be staged"
grep -q '^ANTHROPIC_API_KEY' "$T/cap/b2.env" && bad "B2: both secret names must be unset for the runner" || ok

# B3: pull path, marker, no secret → one deferral, exit 1
mkroot b3; boot b3 p-key "${PULL_KEY[@]}"
[ "$BRC" = 1 ] && [ ! -f "$T/cap/b3.reached" ] && ok || bad "B3: must exit 1 before the runner (rc $BRC)"
[ "$(puts b3)" = 1 ] && grep -q 'BUILD_DEFERRED api-key: no Fly secret ANTHROPIC_API_KEY_P_KEY' "$T/cap/b3.curl" && ok \
  || bad "B3: one BUILD_DEFERRED api-key PUT expected, got: $(cat "$T/cap/b3.curl")"
grep -q 'FATAL: CLAUDE_AUTH_MODE=api-key and no Fly secret ANTHROPIC_API_KEY_P_KEY' "$T/cap/b3.log" && ok || bad "B3: the FATAL log line is missing: $(cat "$T/cap/b3.log")"
[ ! -e "$(STAGED)" ] && ok || bad "B3: nothing may be staged"

# B4: pull path, marker, secret → runs
mkroot b4; boot b4 p-key "${PULL_KEY[@]}" ANTHROPIC_API_KEY_P_KEY="$KEY_A"
[ "$BRC" = 0 ] && [ -f "$T/cap/b4.reached" ] && [ "$(puts b4)" = 0 ] && ok || bad "B4: must reach the runner with no PUT (rc $BRC, puts $(puts b4))"
grep -qx 'CLAUDE_AUTH_MODE=api-key' "$R/run/harness-env/global.env" && ok || bad "B4: the composed global.env keeps the marker"

# B5: push path, no secret → no stop here (warm_up decides)
mkroot b5; boot b5 p-key
[ "$BRC" = 0 ] && [ -f "$T/cap/b5.reached" ] && [ "$(puts b5)" = 0 ] && ok || bad "B5: the push path must not stop at boot (rc $BRC)"
[ ! -e "$(STAGED)" ] && ok || bad "B5: nothing to stage"

# B6: oauth bundle on the pull path, no secret → no stop, no file
mkroot b6; boot b6 p-oauth "${PULL_OAUTH[@]}"
[ "$BRC" = 0 ] && [ -f "$T/cap/b6.reached" ] && [ "$(puts b6)" = 0 ] && ok || bad "B6: an oauth boot must not stop (rc $BRC)"
[ ! -e "$(STAGED)" ] && ok || bad "B6: an oauth boot stages no key file"

# B7: a project name with no valid secret name
mkroot b7; boot b7 p.key "${PULL_KEY[@]}" "ANTHROPIC_API_KEY_P_KEY=$KEY_A"
[ ! -e "$(STAGED)" ] && ok || bad "B7: p.key must stage nothing (P.KEY is not a valid secret name)"
[ "$BRC" = 1 ] && [ "$(puts b7)" = 1 ] && ok || bad "B7: the marker must stop the boot (rc $BRC, puts $(puts b7))"
grep -q '^ANTHROPIC_API_KEY' "$T/cap/b7.env" 2>/dev/null && bad "B7: the secret name must still be unset" || ok

# ══ R: the runner ═══════════════════════════════════════════════════════════
RN="$DIR/fly/builder-runner.sh"
LOADENV=$(sed -n '/^load_env() {/,/^}/p' "$RN")
WARMHEAD=$(sed -n '/^warm_up() {/,/APIKEY_MISSING:-}" \] ||/p' "$RN")
grep -q '^load_env() {' <<<"$LOADENV" && ok || bad "R0: could not lift load_env from fly/builder-runner.sh"
# BH-9783: the line after load_env is the guard (not a line count), so a new
# local or comment above load_env keeps R0 green.
if grep -q 'APIKEY_MISSING' <<<"$WARMHEAD" && warmup_guard_ok "$RN"; then ok; else
  bad "R0: warm_up must check APIKEY_MISSING right after load_env"
  echo "fly-boot-api-key (BH-9718): $PASS passed, $FAIL failed"; exit 1
fi
E="$T/renv"; mkdir -p "$E" "$T/rh"
cat > "$T/runner.sh" <<EOF
set -uo pipefail
PROJECT=p-key ENVDIR="$E" HARNESS="$T/rh"
log() { echo "runner: \$*" >> "$T/cap/runner.log"; }
live_git_credentials() { :; }
$LOADENV
$WARMHEAD
  return 0
}
show() { printf '%s|key=%s|tok=%s|mode=%s|missing=%s\n' "\$1" "\${ANTHROPIC_API_KEY:-}" "\${CLAUDE_CODE_OAUTH_TOKEN:-}" "\${CLAUDE_AUTH_MODE:-}" "\${APIKEY_MISSING:-}"; }
genv() { printf '%s\n' "\$@" > "$E/global.env"; }
EOF
# rcase <steps...> — run steps in one shell, print its output
rcase() { bash -c ". '$T/runner.sh'; $1" 2>&1; }
APIG="genv CONSOLE_URL=x CLAUDE_AUTH_MODE=api-key"
OAG="genv CONSOLE_URL=x CLAUDE_CODE_OAUTH_TOKEN=$TOK"

# R1: the file the entrypoint wrote in B1
cp "$T/b1-staged.env" "$E/claude-api-key.env"
o=$(rcase "export CLAUDE_CODE_OAUTH_TOKEN=$TOK; $APIG; warm_up; echo rc=\$?; show r1")
[ "$o" = "rc=0
r1|key=$KEY_A|tok=|mode=api-key|missing=" ] && ok || bad "R1: got [$o]"
o=$(rcase "$APIG; warm_up >/dev/null; env | grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' ; env | grep -c '^ANTHROPIC_API_KEY='")
[ "$o" = "0
1" ] && ok || bad "R1: the exported env must hold the key and no OAuth token, got [$o]"

# R2: an inherited key does not count
rm -f "$E/claude-api-key.env"; : > "$T/cap/runner.log"
o=$(rcase "export ANTHROPIC_API_KEY=$KEY_B; $APIG; warm_up; echo rc=\$?; show r2")
[ "$o" = "rc=1
r2|key=|tok=|mode=api-key|missing=1" ] && ok || bad "R2: got [$o]"

# R3: no file → warm_up returns 1, the log names the file
: > "$T/cap/runner.log"
o=$(rcase "$APIG; warm_up; echo rc=\$?")
[ "$o" = "rc=1" ] && ok || bad "R3: warm_up must return 1, got [$o]"
grep -q "$E/claude-api-key.env" "$T/cap/runner.log" && grep -q 'warm-up: api-key project with no key' "$T/cap/runner.log" && ok \
  || bad "R3: the log must name the staged file and the stop, got: $(cat "$T/cap/runner.log")"

# R4: no marker, file present → oauth as today
cp "$T/b1-staged.env" "$E/claude-api-key.env"
o=$(rcase "$OAG; warm_up; echo rc=\$?; show r4")
[ "$o" = "rc=0
r4|key=|tok=$TOK|mode=|missing=" ] && ok || bad "R4: got [$o]"

# R5: api-key then oauth in one shell
o=$(rcase "$APIG; load_env; $OAG; load_env; show r5")
[ "$o" = "r5|key=|tok=$TOK|mode=|missing=" ] && ok || bad "R5: got [$o]"

# R6: oauth then api-key in one shell
o=$(rcase "$OAG; load_env; $APIG; load_env; show r6")
[ "$o" = "r6|key=$KEY_A|tok=|mode=api-key|missing=" ] && ok || bad "R6: got [$o]"

# R7: a marker that is not exactly api-key
o=$(rcase "genv CONSOLE_URL=x CLAUDE_AUTH_MODE=API-KEY CLAUDE_CODE_OAUTH_TOKEN=$TOK; warm_up; echo rc=\$?; show r7")
[ "$o" = "rc=0
r7|key=|tok=$TOK|mode=API-KEY|missing=" ] && ok || bad "R7: got [$o]"

# ── B8: the key value is only in the staged files ──────────────────────────
LEAK=$(grep -rlF -e "$KEY_A" -e "$KEY_B" "$T/cap" 2>/dev/null | grep -v '\.curl$')
[ -z "$LEAK" ] && ok || bad "B8: a key value reached a log or output: $LEAK"
grep -qF -e "$KEY_A" -e "$KEY_B" "$T"/cap/*.curl 2>/dev/null && bad "B8: a key value reached a ledger PUT" || ok

echo "fly-boot-api-key (BH-9718): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
