#!/bin/bash
# tests/fly-pool-probe-pull.bh-7430-test.sh — BH-7430: bin/fly-pool-probe-pull.sh,
# the manual live-Fly probe (part 1). The live run needs a throwaway Fly app and
# FLY_API_TOKEN, so no suite can prove it against Fly. This suite pins what is
# true WITHOUT Fly: the preconditions refuse before anything is created, and the
# four checks read a stubbed fly the way they would read the real one.
#
# DRIVEN: the real script. fly (and flyctl) and timeout are stubs on PATH.
# 0 network calls: the fly stub answers from local files only.
# PINNED:
#   P1  bash -n
#   P2  no args / one arg: rc 2, usage, 0 fly calls
#   P3  no flyctl on PATH: rc 2, "no flyctl", 0 fly calls
#   P4  no jq on PATH: rc 2, "jq required", 0 fly calls
#   P5  no FLY_API_TOKEN / FLY_ACCESS_TOKEN: rc 2, names FLY_API_TOKEN, 0 fly calls
#   P6  a stubbed happy path: rc 0, all four checks PASS, the machine is
#       destroyed and the secret unset, the token is never printed
#   P7  a listing that carries the token value: rc 1, check 3 FAILs, the
#       token is still never printed, cleanup still runs
#   P8  a failed secrets import: rc 1, and the EXIT trap unsets the secret
#   P9  a runner env with SEED_ secrets: rc 1, check 2d FAILs (lead BLOCK
#       #3155 on #7556); P6 above answers 0 for that check
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-probe-pull.bh-7430-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }

PROBE="$DIR/bin/fly-pool-probe-pull.sh"
BASH_BIN=$(command -v bash)
MID=0123456789abcd
mkdir -p "$T/flybin" "$T/empty" "$T/onlyfly" "$T/state" "$T/tmp"

# The fly stub. It keeps the imported bundle, prints a machine id, answers the
# ssh console with what the entrypoint would leave, and lists the machine with
# its secret-backed file. STUB_LEAK=1 lists the token value; IMPORT_FAIL=1
# refuses the import; STUB_SEEDS=<n> is the SEED_ count in the runner env. Every call is one line in $FLY_SINK.
cat > "$T/flybin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
case "$*" in
  "secrets import --stage -a "*)
    [ "${IMPORT_FAIL:-0}" = 1 ] && { echo "Error: app not found" >&2; exit 1; }
    cat > "$STUB_DIR/import" ;;
  "machine run "*) echo "Machine ID: $STUB_MID" ;;
  "ssh console "*builder-runner*) echo "${STUB_SEEDS:-0}" ;;
  "ssh console "*)
    b64=$(cut -d= -f2- < "$STUB_DIR/import")
    mkdir -p "$STUB_DIR/x"
    printf '%s' "$b64" | base64 -d | tar -xzf - -C "$STUB_DIR/x"
    { sha256sum 2>/dev/null || shasum -a 256; } < "$STUB_DIR/x/run/harness-env/gh-token"
    echo 600 ;;
  "machines list "*)
    name=$(cut -d= -f1 < "$STUB_DIR/import")
    if [ "${STUB_LEAK:-0}" = 1 ]; then
      raw=$(base64 < "$STUB_DIR/x/run/harness-env/gh-token" | tr -d '\n')
      printf '[{"id":"%s","config":{"files":[{"guest_path":"/run/x","raw_value":"%s"}]}}]\n' "$STUB_MID" "$raw"
    else
      printf '[{"id":"%s","config":{"files":[{"guest_path":"/run/x","secret_name":"%s"}]}}]\n' "$STUB_MID" "$name"
    fi ;;
  "machine destroy "*|"secrets unset --stage -a "*) : ;;
  *) echo "fly stub: unexpected call: $*" >&2; exit 9 ;;
esac
exit 0
FLY
cp "$T/flybin/fly" "$T/flybin/flyctl"
cp "$T/flybin/fly" "$T/onlyfly/fly"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/flybin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/flybin/sleep"
chmod +x "$T/flybin"/* "$T/onlyfly"/*

export FLY_SINK="$T/fly.calls" STUB_DIR="$T/state" STUB_MID="$MID"
NCALLS() { [ -f "$FLY_SINK" ] && grep -c . "$FLY_SINK" || echo 0; }
# probe <PATH> [VAR=val ...] -- [args] — sets RC, OUT (stdout+stderr)
probe() {
  local p="$1"; shift
  local -a envs=(); while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$FLY_SINK"; rm -rf "$T/state"; mkdir -p "$T/state"
  OUT=$(env -u FLY_API_TOKEN -u FLY_ACCESS_TOKEN PATH="$p" TMPDIR="$T/tmp" ${envs[@]+"${envs[@]}"} \
        "$BASH_BIN" "$PROBE" "$@" 2>&1); RC=$?
}
FAKEPATH="$T/flybin:$PATH"

# ---- P1. syntax
"$BASH_BIN" -n "$PROBE" && ok || bad "P1: bash -n $PROBE"

# ---- P2. usage
probe "$FAKEPATH" FLY_API_TOKEN=x --
[ "$RC" = 2 ] && [ "$(NCALLS)" = 0 ] && case "$OUT" in *"usage: fly-pool-probe-pull.sh <test-app> <image>"*) true ;; *) false ;; esac \
  && ok || bad "P2: no args -> rc 2 + usage + 0 fly calls (rc $RC, calls $(NCALLS), out: $OUT)"
probe "$FAKEPATH" FLY_API_TOKEN=x -- probe-app
[ "$RC" = 2 ] && [ "$(NCALLS)" = 0 ] && ok || bad "P2: one arg -> rc 2 + 0 fly calls (rc $RC, calls $(NCALLS))"

# ---- P3. no flyctl
probe "$T/empty" FLY_API_TOKEN=x -- probe-app img:1
[ "$RC" = 2 ] && case "$OUT" in *"no flyctl on PATH"*) true ;; *) false ;; esac \
  && ok || bad "P3: no flyctl -> rc 2 (rc $RC, out: $OUT)"

# ---- P4. no jq (fly is on PATH, jq is not)
probe "$T/onlyfly" FLY_API_TOKEN=x -- probe-app img:1
[ "$RC" = 2 ] && [ "$(NCALLS)" = 0 ] && case "$OUT" in *"jq required"*) true ;; *) false ;; esac \
  && ok || bad "P4: no jq -> rc 2 + 0 fly calls (rc $RC, calls $(NCALLS), out: $OUT)"

# ---- P5. no token
probe "$FAKEPATH" -- probe-app img:1
[ "$RC" = 2 ] && [ "$(NCALLS)" = 0 ] && case "$OUT" in *"set FLY_API_TOKEN"*) true ;; *) false ;; esac \
  && ok || bad "P5: no token -> rc 2 + 0 fly calls (rc $RC, calls $(NCALLS), out: $OUT)"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "P2-P5: a refused run leaves no temp dir ($(ls -A "$T/tmp"))"

# ---- P6. stubbed happy path
probe "$FAKEPATH" FLY_API_TOKEN=fixture-fly -- probe-app img:1
TOK=$(cat "$T/state/x/run/harness-env/gh-token" 2>/dev/null)
[ "$RC" = 0 ] && ok || bad "P6: rc 0 (rc $RC, out: $OUT)"
for c in "1a the staged secret" "1b machine $MID started" "2a the token file has the same bytes" \
         "2b mode 600" "2c the rootfs bundle file is deleted" "3 the listing shows secret_name" \
         "4 the secret is unset" "all checks held"; do
  case "$OUT" in *"$c"*) ok ;; *) bad "P6: missing '$c' (out: $OUT)" ;; esac
done
grep -qE "^fly machine destroy $MID -a probe-app --force$" "$FLY_SINK" && ok || bad "P6: the machine is destroyed ($(cat "$FLY_SINK"))"
grep -qE '^fly secrets unset --stage -a probe-app SEED_[0-9]+_[0-9a-f]+$' "$FLY_SINK" && ok || bad "P6: the secret is unset ($(cat "$FLY_SINK"))"
case "$TOK" in probe-?*) ok ;; *) bad "P6: the bundle held a probe- token (got '$TOK')" ;; esac
[ -n "$TOK" ] && case "$OUT" in *"$TOK"*) bad "P6: the token value is printed" ;; *) ok ;; esac
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "P6: the temp dir is removed ($(ls -A "$T/tmp"))"

# ---- P7. the listing leaks the token
probe "$FAKEPATH" FLY_API_TOKEN=fixture-fly STUB_LEAK=1 -- probe-app img:1
TOK=$(cat "$T/state/x/run/harness-env/gh-token" 2>/dev/null)
[ "$RC" = 1 ] && case "$OUT" in *"FAIL 3 the machine listing holds the token value"*) true ;; *) false ;; esac \
  && ok || bad "P7: a leaky listing fails check 3 (rc $RC, out: $OUT)"
[ -n "$TOK" ] && case "$OUT" in *"$TOK"*) bad "P7: the token value is printed" ;; *) ok ;; esac
grep -q '^fly secrets unset --stage -a probe-app SEED_' "$FLY_SINK" && ok || bad "P7: the secret is still unset ($(cat "$FLY_SINK"))"

# ---- P8. the import fails: the EXIT trap unsets the staged name
probe "$FAKEPATH" FLY_API_TOKEN=fixture-fly IMPORT_FAIL=1 -- probe-app img:1
[ "$RC" = 1 ] && case "$OUT" in *"FAIL secrets import: Error: app not found"*) true ;; *) false ;; esac \
  && ok || bad "P8: a failed import -> rc 1 (rc $RC, out: $OUT)"
grep -q '^fly machine run' "$FLY_SINK" && bad "P8: no machine runs after a failed import ($(cat "$FLY_SINK"))" || ok
grep -q '^fly secrets unset --stage -a probe-app SEED_' "$FLY_SINK" && ok || bad "P8: the trap unsets the secret ($(cat "$FLY_SINK"))"

# ---- P9. the runner env holds SEED_ secrets: check 2d fails, cleanup still runs
probe "$FAKEPATH" FLY_API_TOKEN=fixture-fly STUB_SEEDS=2 -- probe-app img:1
[ "$RC" = 1 ] && case "$OUT" in *"FAIL 2d the runner env holds SEED_ secrets"*) true ;; *) false ;; esac \
  && ok || bad "P9: SEED_ in the runner env fails check 2d (rc $RC, out: $OUT)"
grep -q '^fly secrets unset --stage -a probe-app SEED_' "$FLY_SINK" && ok || bad "P9: the secret is still unset ($(cat "$FLY_SINK"))"

echo "fly-pool-probe-pull.bh-7430: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
