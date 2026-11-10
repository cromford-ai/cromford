#!/bin/bash
# tests/remote-gate-image.bh-9177-test.sh — the test host says which image it
# runs, and how long each suite took (BH-9177, slice C1 of #9063).
#
# bin/remote-gate.sh --image-id prints one `IMAGE <ref|->` line (the host's
# FLY_IMAGE_REF), and its suites job prints `IMAGE <ref|->` once and
# `TIME <secs> <suite>` per suite. bin/lib/suite-fingerprint.sh turns a ref into
# an image id. The REAL bin/remote-gate.sh runs with PATH shims for flyctl,
# ssh, rsync, nc and ssh-keygen; the composed job is RUN locally (RG_RUN_DIR),
# never grepped. Nothing talks to Fly.
#
#   I1  the suites job: one `IMAGE <ref>` line, `TIME <n> tests/a.sh` after
#       `PASS tests/a.sh`, `TIME <n> tests/b.sh` after its FAIL; the exit code
#       and the `remote-gate: N suites, F failing` line are unchanged
#   I2  --image-id over a stub transport (openssh and fly-ssh): exactly
#       `IMAGE <ref>`, rc 0, no rsync call
#   I3  no FLY_IMAGE_REF in the env: the ref from the machine's init environ;
#       neither: `IMAGE -`, rc 0; a ref with a space: `IMAGE -`; no route: rc 125
#   I4  --image-id with a directory argument: rc 2
#   I5  sfp_fly_image_id: digest, plain ref, and every refusal
#   I6  sfp_image_id order: SUITE_IMAGE_ID > gh > fly > os
#   I7  bin/selection-gate.sh reads a run.txt with IMAGE/TIME lines the same
#       way (one red, one green; the base run's bl_class sees the red)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/remote-gate-image.bh-9177-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
SFP="$DIR/bin/lib/suite-fingerprint.sh"
SG="$DIR/bin/selection-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
[ -f "$GATE" ] && [ -f "$SFP" ] && [ -f "$SG" ] || { echo "FAIL: a script under test is missing"; exit 1; }

FIX="$T/fix"; FB="$T/fakebin"
mkdir -p "$FIX" "$FB" "$T/wt" "$T/h/flags" "$T/h/logs" "$T/home" "$T/tmp"
: > "$T/h/flags/lane-off-testhost-tick"
echo "a worktree file" > "$T/wt/file.txt"
export FIX
REF=registry.fly.io/bh-testhost-fixture:testhost-7
DIG=$(printf 'ab%.0s' $(seq 32))

# flyctl: proxy (unless proxy-refuses), and ssh console for the fly-ssh
# transport: `-C hostname` prints a machine id, `bash -s` RUNS the script.
cat > "$FB/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*) [ -f "$FIX/proxy-refuses" ] && exit 1; : > "$FIX/proxy-up"; exit 0 ;;
  "ssh console")
    cmd=""; while [ $# -gt 0 ]; do [ "$1" = -C ] && { cmd=$2; break; }; shift; done
    case "$cmd" in
      hostname) echo 0f1c7e5000aa01; exit 0 ;;
      "bash -s") exec bash -s ;;
    esac
    exit 1 ;;
esac
exit 0
STUB
cat > "$FB/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
cat > "$FB/rsync" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/rsync-calls"
exit 0
STUB
# ssh: a job sent to `bash -s` is kept in $FIX/job and, with $FIX/exec,
# also RUN here as the host would.
cat > "$FB/ssh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ssh-calls"
case "$*" in
  *"bash -s"*) cat > "$FIX/job"; [ -f "$FIX/exec" ] && exec bash "$FIX/job"; exit 0 ;;
esac
exit 0
STUB
printf '#!/bin/bash\necho "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"\n' > "$FB/ssh-keygen"
chmod +x "$FB"/*
printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"

# run <env assignments...> -- <gate args...> — OUT (stdout), ERR, RC. env -i:
# nothing from this box (a Fly machine has its own FLY_IMAGE_REF).
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$FIX"/fly-calls "$FIX"/ssh-calls "$FIX"/rsync-calls "$FIX"/job
  OUT=$(cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T/home" HARNESS="$T/h" FIX="$FIX" TMPDIR="$T/tmp" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org TESTHOST_KEY="$T/key" \
    REMOTE_GATE_PROXY_WAIT_S=2 RG_PROC_ENVIRON="$T/no-environ" \
    ${envs[@]+"${envs[@]}"} bash "$GATE" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}

# ── I1: the suites job, run as the host runs it ─────────────────────────────
: > "$FIX/proxy-up"; rm -f "$FIX/exec"
run -- "$T/wt" tests/a.sh tests/b.sh
[ -s "$FIX/job" ] && ok "I1 a suites job was composed" || bad "I1 no job (rc $RC): $ERR"
mkdir -p "$T/run1/base/tests"
printf '#!/bin/bash\necho a-ran\nexit 0\n' > "$T/run1/base/tests/a.sh"
printf '#!/bin/bash\necho b-ran\nexit 3\n' > "$T/run1/base/tests/b.sh"
env -i RG_RUN_DIR="$T/run1" PATH="/usr/bin:/bin" FLY_IMAGE_REF="$REF" RG_PROC_ENVIRON="$T/no-environ" \
  bash "$FIX/job" > "$T/i1.out" 2>&1; JRC=$?
[ "$JRC" = 1 ] && ok "I1 the exit code is still the failing count" || bad "I1 job rc $JRC: $(cat "$T/i1.out")"
[ "$(grep -c '^IMAGE ' "$T/i1.out")" = 1 ] && grep -qxF "IMAGE $REF" "$T/i1.out" && ok "I1 one IMAGE line with the host's ref" \
  || bad "I1 IMAGE lines: $(grep '^IMAGE' "$T/i1.out")"
grep -qE '^TIME [0-9]+ tests/a\.sh$' "$T/i1.out" && grep -qE '^TIME [0-9]+ tests/b\.sh$' "$T/i1.out" && ok "I1 a TIME line per suite" \
  || bad "I1 TIME lines: $(grep '^TIME' "$T/i1.out")"
awk '/^PASS tests\/a\.sh$/ { p = NR } /^TIME [0-9]+ tests\/a\.sh$/ { t = NR } END { exit !(p && t > p) }' "$T/i1.out" \
  && awk '/^FAIL tests\/b\.sh \(rc 3\)$/ { p = NR } /^TIME [0-9]+ tests\/b\.sh$/ { t = NR } END { exit !(p && t > p) }' "$T/i1.out" \
  && ok "I1 each TIME line follows its PASS/FAIL line" || bad "I1 order: $(cat "$T/i1.out")"
grep -qxF 'remote-gate: 2 suites, 1 failing' "$T/i1.out" && ok "I1 the summary line is unchanged" || bad "I1 summary: $(tail -3 "$T/i1.out")"
mkdir -p "$T/run1b"; cp -a "$T/run1/base" "$T/run1b/base" 2>/dev/null || mkdir -p "$T/run1b/base/tests"
env -i RG_RUN_DIR="$T/run1b" PATH="/usr/bin:/bin" RG_PROC_ENVIRON="$T/no-environ" bash "$FIX/job" > "$T/i1b.out" 2>&1
grep -qxF 'IMAGE -' "$T/i1b.out" && ok "I1 a host with no ref says IMAGE -" || bad "I1b: $(grep '^IMAGE' "$T/i1b.out")"

# ── I2: --image-id, openssh and fly-ssh ─────────────────────────────────────
: > "$FIX/exec"; : > "$FIX/proxy-up"
run FLY_IMAGE_REF="$REF@sha256:$DIG" -- --image-id
{ [ "$RC" = 0 ] && [ "$OUT" = "IMAGE $REF@sha256:$DIG" ]; } && ok "I2 openssh: exactly the IMAGE line, rc 0" || bad "I2 rc=$RC out='$OUT' err=$ERR"
[ ! -s "$FIX/rsync-calls" ] && ok "I2 no upload" || bad "I2 rsync was called: $(cat "$FIX/rsync-calls")"
E="$T/env"; mkdir -p "$E"; chmod 700 "$E"
printf 'REMOTE_GATE_TRANSPORT=fly-ssh\nFLY_API_TOKEN=FlyV1 fm2_fixture-token-9177\n' > "$E/testhost.env"
run HARNESS_ENV_DIR="$E" FLY_IMAGE_REF="$REF" -- --image-id
{ [ "$RC" = 0 ] && [ "$OUT" = "IMAGE $REF" ] && [ ! -s "$FIX/rsync-calls" ]; } && ok "I2 fly-ssh: exactly the IMAGE line, rc 0, no upload" \
  || bad "I2 fly-ssh rc=$RC out='$OUT' err=$ERR"
grep -q -- '--machine 0f1c7e5000aa01 -q -C bash -s' "$FIX/fly-calls" && ok "I2 fly-ssh: the probe goes to the pinned machine" \
  || bad "I2 fly calls: $(cat "$FIX/fly-calls")"

# ── I3: where the ref comes from, and no route ──────────────────────────────
printf 'HOME=/root\0FLY_IMAGE_REF=%s\0FLY_REGION=fixture\0' "$REF" > "$T/environ"
run RG_PROC_ENVIRON="$T/environ" -- --image-id
{ [ "$RC" = 0 ] && [ "$OUT" = "IMAGE $REF" ]; } && ok "I3 the ref from the machine's init environ" || bad "I3 environ rc=$RC out='$OUT'"
run -- --image-id
{ [ "$RC" = 0 ] && [ "$OUT" = "IMAGE -" ]; } && ok "I3 no ref anywhere: IMAGE -, rc 0" || bad "I3 none rc=$RC out='$OUT' err=$ERR"
run "FLY_IMAGE_REF=a b" -- --image-id
[ "$OUT" = "IMAGE -" ] && ok "I3 a ref with a space is no ref" || bad "I3 space out='$OUT'"
rm -f "$FIX/proxy-up"; : > "$FIX/proxy-refuses"
run FLY_IMAGE_REF="$REF" -- --image-id
{ [ "$RC" = 125 ] && [ -z "$OUT" ]; } && ok "I3 no route: rc 125, no IMAGE line" || bad "I3 no route rc=$RC out='$OUT'"
rm -f "$FIX/proxy-refuses"; : > "$FIX/proxy-up"

# ── I4 ──────────────────────────────────────────────────────────────────────
run -- --image-id "$T/wt"
{ [ "$RC" = 2 ] && [ ! -s "$FIX/ssh-calls" ]; } && ok "I4 --image-id with a directory: rc 2, nothing sent" || bad "I4 rc=$RC err=$ERR"

# ── I5 / I6: the image id ───────────────────────────────────────────────────
fid() { ( . "$SFP" && sfp_fly_image_id "$1" ); }
img() { ( unset ImageOS ImageVersion SUITE_IMAGE_ID FLY_IMAGE_REF; for a in "$@"; do export "${a?}"; done
          . "$SFP" && sfp_image_id ) 2>/dev/null; }
[ "$(fid "$REF@sha256:$DIG")" = "fly:sha256:$DIG" ] && ok "I5 a digest ref: fly:sha256:<hex>" || bad "I5 digest '$(fid "$REF@sha256:$DIG")'"
[ "$(fid "$REF")" = "fly:$REF" ] && ok "I5 a plain ref: fly:<ref>" || bad "I5 plain '$(fid "$REF")'"
UP=$(printf 'AB%.0s' $(seq 32))
[ "$(fid "r@sha256:$UP")" = "fly:r@sha256:$UP" ] && ok "I5 an upper-case digest is not a digest: fly:<ref>" || bad "I5 upper '$(fid "r@sha256:$UP")'"
[ "$(fid "r@sha256:${DIG:0:63}")" = "fly:r@sha256:${DIG:0:63}" ] && ok "I5 a 63-hex digest is not a digest" || bad "I5 63 hex"
LONG=$(printf 'r%.0s' $(seq 125))
for bad_ref in "" "a b" 'a$b' "$LONG"; do
  if out=$(fid "$bad_ref"); then bad "I5 '${bad_ref:0:20}' was accepted as '$out'"; else ok "I5 refused: '${bad_ref:0:20}' (${#bad_ref} chars)"; fi
done
OS=$(img)
[[ "$OS" =~ ^os: ]] && ok "I6 nothing set: os: ($OS)" || bad "I6 default '$OS'"
[ "$(img FLY_IMAGE_REF="$REF")" = "fly:$REF" ] && ok "I6 FLY_IMAGE_REF beats os:" || bad "I6 fly '$(img FLY_IMAGE_REF="$REF")'"
[ "$(img FLY_IMAGE_REF="$REF" ImageOS=ubuntu24 ImageVersion=20261101.1)" = gh:ubuntu24:20261101.1 ] && ok "I6 the GitHub pair beats fly" \
  || bad "I6 gh '$(img FLY_IMAGE_REF="$REF" ImageOS=ubuntu24 ImageVersion=20261101.1)'"
[ "$(img FLY_IMAGE_REF="$REF" SUITE_IMAGE_ID=img-x ImageOS=ubuntu24 ImageVersion=1)" = img-x ] && ok "I6 SUITE_IMAGE_ID beats all" || bad "I6 override"
[ "$(img "FLY_IMAGE_REF=a b")" = "$OS" ] && ok "I6 a bad Fly ref falls to os:" || bad "I6 bad fly '$(img "FLY_IMAGE_REF=a b")'"
[ "$(img "FLY_IMAGE_REF=$LONG")" = "$OS" ] && ok "I6 a too-long Fly ref falls to os:" || bad "I6 long fly"

# ── I7: the selection gate reads the I1 output the same way ────────────────
R="$T/repo"; mkdir -p "$R/tests"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
printf 'exit 0\n' > "$R/tests/a.sh"; printf 'exit 0\n' > "$R/tests/b.sh"
g init -q -b main; g add -A; g commit -qm base
g checkout -q -b ticket/bh-1; echo c > "$R/c.txt"; g add -A; g commit -qm change
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf 'tests/a.sh\ntests/b.sh\n' > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
cat > "$T/runner.sh" <<SH
#!/bin/bash
cat "$T/i1.out"; exit 1
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
sg() { # sg <case> [VAR=value...]
  local c="$1"; shift; mkdir -p "$T/$c/h" "$T/$c/tmp"
  env -u CI_QUARANTINE -u SELECTION_GATE_SUITE_REUSE -u SELECTION_GATE_BASELINE_RUN HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" REPO_SLUG= \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- "$@" \
    bash "$SG" --tree "$R" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  SRC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
sg i7
{ [ "$SRC" = 1 ] && [ "$(gv i7 red)" = tests/b.sh ] && [ "$(gv i7 why)" = - ]; } && ok "I7 the FAIL parser names only the red suite" \
  || bad "I7 rc=$SRC $(cat "$T/i7/out/gate.txt" "$T/i7/stdout")"
sg i7b SELECTION_GATE_BASELINE_RUN=1
{ [ "$SRC" = 0 ] && [ "$(gv i7b baseline-red)" = tests/b.sh ] && [ "$(gv i7b red)" = - ]; } && ok "I7 bl_class reads the red on the base the same way" \
  || bad "I7b rc=$SRC $(cat "$T/i7b/out/gate.txt" "$T/i7b/stdout")"

echo "remote-gate-image: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
