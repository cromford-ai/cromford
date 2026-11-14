#!/bin/bash
# tests/load-project-claude-auth.bh-9677-test.sh — BH-9677 (BH-9334.3):
# bin/load-project.sh --claude-auth oauth|api-key, --runner-lock claude and
# --fly-app <app>; the Fly-side GET /v1/models key probe (the seam
# bin/lib/vendor/fly-anthropic-probe.sh); the claude rows written through
# bin/protected-setting.sh.
#
#   C1  each accepted flag set runs to the end (rc 0, --no-bootstrap)
#   C2  each refused flag set is rc 2: no protected-setting call, no fly call,
#       no fleet.conf row, no prompt, no commit
#   C3  the two probe timeouts: registry defaults 30 / 120; an env value out of
#       5..300 / 10..600 is rc 2 with no fly call (refused, never clamped); the
#       values reach curl -m and timeout
#   P1  fake mode: the seam prints the seeded answer, an unseeded app is rc 70,
#       0 fly calls, VENDOR_CALL_LOG stays empty
#   P2  real mode, the fly stub runs the REAL remote script locally with a stub
#       curl: a good key answers 200, a bad key 401, no secret `nosecret`;
#       x-api-key header, no Authorization, URL ends /v1/models, the key is on
#       no argv. A2: the same bad key through load-project stops and names 401
#   P3  the key values are in no file under the scratch dir and in no output
#   P4  bad seam arguments are rc 2 with no fly call
#   D1-D10  the probe verdict table (plan "Failure modes" D1)
#   W1-W5  the row writes: order, oauth, a failed write, the old path, and
#       every written value is in the real bin/lib/claude-auth.sh lists
#
# gh, git's network verbs, flyctl, curl, timeout, bin/jobs-client.sh and
# bin/protected-setting.sh are stubs; the checkout is a scratch git repo.
# 0 vendor calls.
#   HARNESS_TEST_SANDBOX=1 bash tests/load-project-claude-auth.bh-9677-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
has() { if grep -qF -- "$3" "$2"; then ok; else bad "$1: no '$3' in: $(cat "$2")"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1: '$3' found in: $(cat "$2")"; else ok; fi; }
lines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

SEAM="$DIR/bin/lib/vendor/fly-anthropic-probe.sh"
GOOD='fixture-good-key-bh9677'
BADK='fixture-bad-key-bh9677'
GOOD_SHA=$(printf '%s' "$GOOD" | sha256sum | cut -d' ' -f1)
export LP_GOOD_SHA="$GOOD_SHA"

REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
# flyctl: logs its argv. LP_FLY_EXEC=1 runs the -C argument with sh -c here
# (the machine's shell, with this process's env as the machine env); else it
# prints LP_FLY_OUT (default `KEYPROBE 200`) and exits LP_FLY_RC.
cat > "$T/stub/flyctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${LP_FLY:-/dev/null}"
if [ "${LP_FLY_EXEC:-0}" = 1 ]; then
  cmd=""
  while [ $# -gt 0 ]; do [ "$1" = -C ] && { cmd="$2"; break; }; shift; done
  exec sh -c "$cmd"
fi
if [ -n "${LP_FLY_OUT:-}" ]; then cat "$LP_FLY_OUT"; else echo "KEYPROBE 200"; fi
exit "${LP_FLY_RC:-0}"
STUB
cp "$T/stub/flyctl" "$T/stub/fly"
# curl: argv to LP_CURL_ARGV, the config on stdin to LP_CURL_CFG with the key
# replaced by <KEY>; answers 200 for the key whose sha256 is LP_GOOD_SHA, else
# 401. No file ever holds a key.
cat > "$T/stub/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${LP_CURL_ARGV:-/dev/null}"
cfg=$(cat)
key=$(printf '%s\n' "$cfg" | sed -n 's/^header = "x-api-key: \(.*\)"$/\1/p')
printf '%s\n' "$cfg" | sed 's/x-api-key: .*"/x-api-key: <KEY>"/' >> "${LP_CURL_CFG:-/dev/null}"
sha=$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)
if [ -n "$key" ] && [ "$sha" = "$LP_GOOD_SHA" ]; then printf 200; else printf 401; fi
STUB
# timeout: records its seconds argument, then runs the command.
cat > "$T/stub/timeout" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "${LP_TO:-/dev/null}"
shift
exec "$@"
STUB
chmod +x "$T/stub/"*

JC_STUB='#!/bin/bash
setting_get() { return 2; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 1; fi'
# protected-setting: records `<key>\t<value>\t<note>\trow=<yes|no>` for each
# write that succeeds; a key that starts with LP_PSFAIL fails (rc 1).
PS_STUB='#!/bin/bash
if [ -n "${LP_PSFAIL:-}" ]; then case "$1" in "$LP_PSFAIL"*) echo "protected-setting: http 403" >&2; exit 1 ;; esac; fi
row=no; grep -q "^$LP_PROJECT " fleet.conf 2>/dev/null && row=yes
printf "%s\t%s\t%s\trow=%s\n" "$1" "$2" "$3" "$row" >> "$LP_PS"
echo "$1 = $2  signed=true sig_seq=1"'

TPL="$T/tpl"
mkdir -p "$TPL/prompts/_template"
for s in bin/load-project.sh bin/fleet-conf.sh bin/box-for.sh bin/lib/tracker.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$TPL" ) >/dev/null || { echo "FAIL: closure $s"; exit 1; }
done
printf '%s\n' "$JC_STUB" > "$TPL/bin/jobs-client.sh"
printf '%s\n' "$PS_STUB" > "$TPL/bin/protected-setting.sh"
chmod +x "$TPL/bin/jobs-client.sh" "$TPL/bin/protected-setting.sh"
cp "$DIR/prompts/TEMPLATE-GH.md" "$TPL/prompts/TEMPLATE-GH.md"
cp "$DIR/prompts/_template/trk-commands.md" "$TPL/prompts/_template/trk-commands.md"
printf 'alpha  Acme/alpha  -  -  2  box-small\n' > "$TPL/fleet.conf"
(
  cd "$TPL" || exit 1
  "$REAL_GIT" init -q .
  "$REAL_GIT" config user.email t@t
  "$REAL_GIT" config user.name t
  "$REAL_GIT" add -A
  "$REAL_GIT" commit -qm base
) >/dev/null 2>&1

# load <name> [VAR=val ...] -- <args...> — a fresh copy of the template, the
# real loader. rc in RC; output $T/<name>.out; writes $T/<name>.ps; fly argv
# $T/<name>.fly; the repo is $T/r-<name>.
load() {
  local n="$1"; shift
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  local R="$T/r-$n"
  scratch_rm "$R"; cp -a "$TPL" "$R"
  : > "$T/$n.ps"; : > "$T/$n.fly"; : > "$T/$n.to"; : > "$T/$n.curl"; : > "$T/$n.cfg"
  RC=0
  ( cd "$R" && env -u REGISTRY_SOURCE -u JOBS_URL -u HARNESS_SECRET -u HARNESS_VENDOR_FAKE \
      -u LOAD_PROJECT_KEY_PROBE_TIMEOUT_S -u LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S \
      PATH="$T/stub:$PATH" HARNESS="$R" LP_PS="$T/$n.ps" LP_FLY="$T/$n.fly" LP_TO="$T/$n.to" \
      LP_CURL_ARGV="$T/$n.curl" LP_CURL_CFG="$T/$n.cfg" LP_PROJECT=newp \
      ENDPOINT_ANTHROPIC=https://api.anthropic.test "${e[@]}" \
      bash bin/load-project.sh Acme/newp --box box-small --no-bootstrap "$@" ) > "$T/$n.out" 2>&1 || RC=$?
}
ps_rows() { cut -f1,2 "$T/$1.ps" | tr '\t' '=' | tr '\n' ' '; }
norow() { # norow <case> — nothing of the onboarding was written
  grep -q '^newp ' "$T/r-$1/fleet.conf" && bad "$1 a fleet.conf row was written" || ok
  [ -e "$T/r-$1/prompts/newp.md" ] && bad "$1 a prompt was rendered" || ok
  eq "$1 no commit" "$("$REAL_GIT" -C "$T/r-$1" rev-list --count HEAD)" 1
}
# seam <name> [VAR=val ...] -- <args...> — the seam alone, in a child bash.
seam() {
  local n="$1"; shift
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : > "$T/$n.fly"; : > "$T/$n.curl"; : > "$T/$n.cfg"; : > "$T/$n.to"
  RC=0
  env -u HARNESS_VENDOR_FAKE PATH="$T/stub:$PATH" LP_FLY="$T/$n.fly" LP_CURL_ARGV="$T/$n.curl" \
    LP_CURL_CFG="$T/$n.cfg" LP_TO="$T/$n.to" "${e[@]}" \
    bash -c '. "$1" || exit 98; shift; fly_anthropic_key_probe "$@"' _ "$SEAM" "$@" \
    > "$T/$n.out" 2> "$T/$n.err" || RC=$?
}

# ---- C1 accepted flag sets ------------------------------------------------------------
i=0
for args in "--claude-auth oauth" "--claude-auth api-key --fly-app pool-x" "--runner-lock claude" \
            "--claude-auth api-key --runner-lock claude --fly-app pool-x"; do
  i=$((i+1))
  # shellcheck disable=SC2086 # the flag list is split on purpose
  load c1-$i -- $args
  eq "C1 '$args' rc" "$RC" 0
  [ "$RC" = 0 ] || tail -5 "$T/c1-$i.out"
  grep -q '^newp ' "$T/r-c1-$i/fleet.conf" && ok || bad "C1 '$args' no fleet.conf row"
done

# ---- C2 refused flag sets ----------------------------------------------------------------
i=0
while IFS= read -r args; do
  i=$((i+1))
  # shellcheck disable=SC2086 # the flag list is split on purpose
  eval "set -- $args"
  load c2-$i -- "$@"
  eq "C2 [$args] rc" "$RC" 2
  eq "C2 [$args] no protected-setting call" "$(lines "$T/c2-$i.ps")" 0
  eq "C2 [$args] no fly call" "$(lines "$T/c2-$i.fly")" 0
  has "C2 [$args] says nothing was written" "$T/c2-$i.out" "nothing was written"
    case "$args" in
    "--claude-auth "[!\']*) case "$args" in *--fly-app*|"--claude-auth api-key") ;; *) has "C2 [$args] names the allowed modes" "$T/c2-$i.out" "--claude-auth takes one of: oauth api-key" ;; esac ;;
    "--runner-lock "[!\']*) has "C2 [$args] names the allowed locks" "$T/c2-$i.out" "--runner-lock takes one of: claude" ;;
  esac
  norow c2-$i
done <<'ROWS'
--claude-auth API-KEY --fly-app pool-x
--claude-auth apikey --fly-app pool-x
--claude-auth api_key --fly-app pool-x
--claude-auth API-KEY
--claude-auth apikey
--claude-auth Oauth
--claude-auth ''
--runner-lock codex
--runner-lock Claude
--runner-lock ''
--claude-auth api-key
--claude-auth api-key --fly-app Pool_X
--claude-auth api-key --fly-app ../x
--fly-app pool-x
--claude-auth oauth --fly-app pool-x
--claude-auth
--runner-lock
--fly-app
ROWS
# a project name with a `.` cannot form a Fly secret name
load c2-dot -- --project a.b --claude-auth api-key --fly-app pool-x
eq "C2 project a.b rc" "$RC" 2
has "C2 project a.b names the secret" "$T/c2-dot.out" "cannot form a Fly secret name"
eq "C2 project a.b no fly call" "$(lines "$T/c2-dot.fly")" 0

# ---- C3 the probe timeout knobs -----------------------------------------------------------
KJ="$DIR/catalog/lanes.d/_lib.load-project-key-probe.json"
eq "C3 registry default curl timeout" "$(jq -r '.libs[0].knobs[] | select(.env=="LOAD_PROJECT_KEY_PROBE_TIMEOUT_S") | .default' "$KJ" 2>/dev/null)" 30
eq "C3 registry default ssh timeout" "$(jq -r '.libs[0].knobs[] | select(.env=="LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S") | .default' "$KJ" 2>/dev/null)" 120
eq "C3 registry lib id" "$(jq -r '.libs[0].id' "$KJ" 2>/dev/null)" load-project-key-probe
i=0
for kv in LOAD_PROJECT_KEY_PROBE_TIMEOUT_S=4 LOAD_PROJECT_KEY_PROBE_TIMEOUT_S=301 LOAD_PROJECT_KEY_PROBE_TIMEOUT_S=abc \
          LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S=9 LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S=601; do
  i=$((i+1))
  load c3-$i "$kv" -- --claude-auth api-key --fly-app pool-x
  eq "C3 $kv rc" "$RC" 2
  eq "C3 $kv no fly call" "$(lines "$T/c3-$i.fly")" 0
  eq "C3 $kv no protected-setting call" "$(lines "$T/c3-$i.ps")" 0
done
# the defaults (no row, no env) and an env value reach the call
load c3-def LP_FLY_EXEC=1 ANTHROPIC_API_KEY_NEWP="$GOOD" -- --claude-auth api-key --fly-app pool-x
eq "C3 default rc" "$RC" 0
has "C3 default curl -m 30" "$T/c3-def.curl" "-m 30"
eq "C3 default ssh timeout 120" "$(cat "$T/c3-def.to")" 120
load c3-env LP_FLY_EXEC=1 ANTHROPIC_API_KEY_NEWP="$GOOD" LOAD_PROJECT_KEY_PROBE_TIMEOUT_S=45 \
  LOAD_PROJECT_KEY_PROBE_SSH_TIMEOUT_S=200 -- --claude-auth api-key --fly-app pool-x
eq "C3 env rc" "$RC" 0
has "C3 env curl -m 45" "$T/c3-env.curl" "-m 45"
eq "C3 env ssh timeout 200" "$(cat "$T/c3-env.to")" 200

# ---- P1 fake mode --------------------------------------------------------------------------
mkdir -p "$T/seed"
printf '{"key_probe":{"pool-t":"200","pool-b":"401"}}\n' > "$T/seed/fly-anthropic-probe.json"
: > "$T/vcl"
seam p1a HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/seed" VENDOR_CALL_LOG="$T/vcl" -- \
  pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120
eq "P1 seeded answer" "$RC $(cat "$T/p1a.out")" "0 200"
eq "P1 seeded no fly call" "$(lines "$T/p1a.fly")" 0
seam p1b HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/seed" VENDOR_CALL_LOG="$T/vcl" -- \
  pool-u ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120
eq "P1 unseeded rc" "$RC" 70
eq "P1 unseeded no fly call" "$(lines "$T/p1b.fly")" 0
load p1c HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/seed" VENDOR_CALL_LOG="$T/vcl" -- \
  --claude-auth api-key --fly-app pool-b
eq "P1 load-project fake 401 rc" "$RC" 3
has "P1 load-project fake 401 named" "$T/p1c.out" "the key probe answered 401"
eq "P1 load-project fake no fly call" "$(lines "$T/p1c.fly")" 0
eq "P1 budget: VENDOR_CALL_LOG stays empty in fake mode" "$(lines "$T/vcl")" 0

# ---- P2 real mode, the remote script run locally -----------------------------------------
: > "$T/vcl2"
seam p2a LP_FLY_EXEC=1 ANTHROPIC_API_KEY_NEWP="$GOOD" VENDOR_CALL_LOG="$T/vcl2" -- \
  pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120
eq "P2 good key" "$RC $(cat "$T/p2a.out")" "0 200"
eq "P2 one fly call" "$(lines "$T/p2a.fly")" 1
eq "P2 one curl call" "$(lines "$T/p2a.curl")" 1
eq "P2 the real-mode call is logged once" "$(lines "$T/vcl2")" 1
has "P2 x-api-key header" "$T/p2a.cfg" 'header = "x-api-key: <KEY>"'
has "P2 anthropic-version header" "$T/p2a.cfg" 'header = "anthropic-version: 2023-06-01"'
has "P2 the URL ends /v1/models" "$T/p2a.cfg" 'url = "https://api.anthropic.test/v1/models"'
if grep -qi 'authorization' "$T/p2a.cfg" "$T/p2a.curl"; then bad "P2 an Authorization header was sent"; else ok; fi
has "P2 curl reads its config from stdin" "$T/p2a.curl" "-K -"
has "P2 fly ssh console on the app" "$T/p2a.fly" "ssh console -a pool-t"
hasnt "P2 the key is not on fly's argv" "$T/p2a.fly" "$GOOD"
hasnt "P2 the key is not on curl's argv" "$T/p2a.curl" "$GOOD"
seam p2b LP_FLY_EXEC=1 ANTHROPIC_API_KEY_NEWP="$BADK" -- pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120
eq "P2 bad key" "$RC $(cat "$T/p2b.out")" "0 401"
hasnt "P2 the bad key is not on curl's argv" "$T/p2b.curl" "$BADK"
seam p2c LP_FLY_EXEC=1 -- pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120
eq "P2 no secret" "$RC $(cat "$T/p2c.out")" "0 nosecret"
eq "P2 no secret: no curl call" "$(lines "$T/p2c.curl")" 0
# A2 (parent acceptance): load-project --claude-auth api-key with a bad key stops and names the 401
load a2 LP_FLY_EXEC=1 ANTHROPIC_API_KEY_NEWP="$BADK" -- --claude-auth api-key --fly-app pool-t
eq "A2 bad key rc" "$RC" 3
has "A2 bad key names 401" "$T/a2.out" "REFUSED: the key probe answered 401: Anthropic refused ANTHROPIC_API_KEY_NEWP (invalid key)"
eq "A2 no protected-setting call" "$(lines "$T/a2.ps")" 0
norow a2

# ---- P3 no key in any file or output ---------------------------------------------------------
eq "P3 the good key is in no file under the scratch dir" "$(grep -rlF -- "$GOOD" "$T" 2>/dev/null)" ""
eq "P3 the bad key is in no file under the scratch dir" "$(grep -rlF -- "$BADK" "$T" 2>/dev/null)" ""

# ---- P4 bad seam arguments ----------------------------------------------------------------------
i=0
for a in "A_B ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 120" \
         "pool-t x https://api.anthropic.test 30 120" \
         "pool-t ANTHROPIC_API_KEY_NEWP http://x 30 120" \
         "pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 3x 120" \
         "pool-t ANTHROPIC_API_KEY_NEWP https://api.anthropic.test 30 ''"; do
  i=$((i+1))
  eval "set -- $a"
  seam p4-$i LP_FLY_EXEC=1 -- "$@"
  eq "P4 [$a] rc" "$RC" 2
  eq "P4 [$a] no fly call" "$(lines "$T/p4-$i.fly")" 0
done

# ---- D1-D10 the verdict table ----------------------------------------------------------------------
dcase() { # dcase <name> <ssh rc> <printf format for the ssh stdout>
  local n="$1" rc="$2" fmt="$3"
  # shellcheck disable=SC2059 # the format is the fixture
  printf "$fmt" > "$T/$n.sshout"
  load "$n" LP_FLY_OUT="$T/$n.sshout" LP_FLY_RC="$rc" -- --claude-auth api-key --fly-app pool-t
}
refused() { # refused <case> <text>
  eq "$1 rc" "$RC" 3
  has "$1 names the verdict" "$T/$1.out" "$2"
  has "$1 says nothing was written" "$T/$1.out" "nothing was written: no settings row, no fleet.conf row, no prompt, no commit, no box."
  eq "$1 no protected-setting call" "$(lines "$T/$1.ps")" 0
  norow "$1"
}
dcase d1 0 'KEYPROBE 200\n'
eq "D1 rc" "$RC" 0
has "D1 the 200 line" "$T/d1.out" "key probe: ANTHROPIC_API_KEY_NEWP on pool-t answered 200"
dcase d1b 0 'Connecting to fdaa::3... complete\nKEYPROBE 200\r\n'
eq "D1b banner + CR rc" "$RC" 0
dcase d2 0 'KEYPROBE 401\n'
refused d2 "REFUSED: the key probe answered 401: Anthropic refused ANTHROPIC_API_KEY_NEWP (invalid key)"
dcase d3 0 'KEYPROBE 403\n'
refused d3 "REFUSED: the key probe answered 403: the key has no access (disabled key or org)"
dcase d4 0 'KEYPROBE nosecret\n'
refused d4 "REFUSED: no secret ANTHROPIC_API_KEY_NEWP on Fly app pool-t (fly secrets set -a pool-t ANTHROPIC_API_KEY_NEWP=...)"
i=0
for code in 429 529 000 404; do
  i=$((i+1))
  dcase d5-$i 0 "KEYPROBE $code\\n"
  refused d5-$i "REFUSED: the key probe answered $code; the key is not proven, re-run"
done
i=0
for fmt in 'KEYPROBE 2000\n' 'XKEYPROBE 200\n' 'KEYPROBE 200 ok\n' 'HTTP/1.1 200 OK\n' '' 'KEYPROBE  200\n'; do
  i=$((i+1))
  dcase d6-$i 0 "$fmt"
  refused d6-$i "REFUSED: could not run the key probe on Fly app pool-t"
  hasnt "D6-$i no 200 line" "$T/d6-$i.out" "answered 200"
done
dcase d7 1 'Error: no machines\n'
refused d7 "REFUSED: could not run the key probe on Fly app pool-t (no machine, no flyctl or no ssh access)"
dcase d8 124 ''
refused d8 "REFUSED: could not run the key probe on Fly app pool-t"
dcase d9 1 'KEYPROBE 200\n'
refused d9 "REFUSED: could not run the key probe on Fly app pool-t"
# D10: no Anthropic endpoint resolves (no env, no registry in the scratch)
load d10 ENDPOINT_ANTHROPIC= -- --claude-auth api-key --fly-app pool-t
refused d10 "no Anthropic endpoint"
eq "D10 no fly call" "$(lines "$T/d10.fly")" 0

# ---- W1-W5 the row writes -----------------------------------------------------------------------------
load w1 -- --claude-auth api-key --runner-lock claude --fly-app pool-t
eq "W1 rc" "$RC" 0
eq "W1 rows, runner_lock first" "$(ps_rows w1)" "runner_lock.newp=claude claude_auth.newp=api-key "
eq "W1 both before the fleet.conf row" "$(cut -f4 "$T/w1.ps" | sort -u)" "row=no"
grep -q '^newp ' "$T/r-w1/fleet.conf" && ok || bad "W1 no fleet.conf row"
eq "W1 one fly call" "$(lines "$T/w1.fly")" 1
# the 200 line comes before the settings lines
w1p=$(grep -n 'answered 200' "$T/w1.out" | head -1 | cut -d: -f1)
w1s=$(grep -n '^settings: runner_lock.newp=claude' "$T/w1.out" | head -1 | cut -d: -f1)
w1c=$(grep -n '^settings: claude_auth.newp=api-key' "$T/w1.out" | head -1 | cut -d: -f1)
[ -n "$w1p" ] && [ -n "$w1s" ] && [ -n "$w1c" ] && [ "$w1p" -lt "$w1s" ] && [ "$w1s" -lt "$w1c" ] && ok \
  || bad "W1 order of the probe and settings lines: probe=$w1p lock=$w1s auth=$w1c"
has "W1 the note names the flag" "$T/w1.ps" "load-project --claude-auth api-key"

load w2 -- --claude-auth oauth
eq "W2 rc" "$RC" 0
eq "W2 one oauth row" "$(ps_rows w2)" "claude_auth.newp=oauth "
eq "W2 no fly call" "$(lines "$T/w2.fly")" 0

load w3 LP_PSFAIL=claude_auth. -- --claude-auth api-key --runner-lock claude --fly-app pool-t
eq "W3 rc" "$RC" 1
has "W3 FATAL names the failed row" "$T/w3.out" "FATAL: could not write the settings row claude_auth.newp"
has "W3 names runner_lock as written" "$T/w3.out" "runner_lock.newp"
eq "W3 only runner_lock was written" "$(ps_rows w3)" "runner_lock.newp=claude "
hasnt "W3 no settings line for the failed row" "$T/w3.out" "settings: claude_auth.newp"
norow w3

load w4 --
eq "W4 rc" "$RC" 0
eq "W4 no protected-setting call" "$(lines "$T/w4.ps")" 0
eq "W4 no fly call" "$(lines "$T/w4.fly")" 0
hasnt "W4 no probe line" "$T/w4.out" "key probe"

# W5: every written value is in the reader's lists
# shellcheck disable=SC2016 # expanded by the child shell
LISTS=$(bash -c '. "$1" >/dev/null 2>&1 || exit 9; printf "%s|%s" "$CLAUDE_AUTH_MODES" "$RUNNER_LOCKS"' _ "$DIR/bin/lib/claude-auth.sh")
cat "$T/w1.ps" "$T/w2.ps" > "$T/w5.ps"
while IFS=$'\t' read -r k v _; do
  case "$k" in
    claude_auth.*) case " ${LISTS%%|*} " in *" $v "*) ok ;; *) bad "W5 $k=$v not in CLAUDE_AUTH_MODES (${LISTS%%|*})" ;; esac ;;
    runner_lock.*) case " ${LISTS##*|} " in *" $v "*) ok ;; *) bad "W5 $k=$v not in RUNNER_LOCKS (${LISTS##*|})" ;; esac ;;
    *) bad "W5 unexpected row $k" ;;
  esac
done < "$T/w5.ps"
eq "W5 rows checked" "$(lines "$T/w5.ps")" 3

echo "load-project-claude-auth.bh-9677-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
