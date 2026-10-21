#!/bin/bash
# tests/fly-harness-fetch.bh-7430-test.sh — BH-7430: fly/harness-fetch.sh, the
# pull-path machine's own harness fetch (the hub pins HARNESS_SHA).
#
# A local bare repo stands in for GitHub through GIT_FETCH_URL_OVERRIDE; the
# helper itself is the real file, run as fly/entrypoint.sh runs it.
# PINNED:
#   F1  the pinned sha extracts the shipped paths and stamps HARNESS_COMMIT
#   F2  the extract carries the runner executable; logs state locks builds exist
#   F3  a sha the repo does not have: rc 1 after 3 attempts, one FATAL line
#   F4  a bad sha or slug, a missing or empty token file: rc 2, no fetch
#   F5  no token text in stderr or stdout on any path; no scratch repo left
#   F6  the token rides as the Basic auth header (seen by a git wrapper)
# Run from anywhere: bash tests/fly-harness-fetch.bh-7430-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
HF="$DIR/fly/harness-fetch.sh"
[ -x "$HF" ] && ok || bad "F0: fly/harness-fetch.sh is missing or not executable"

# The source repo: the six shipped paths plus one that must NOT ship.
SRC="$T/src"; mkdir -p "$SRC/bin" "$SRC/prompts" "$SRC/rules" "$SRC/catalog" "$SRC/fly" "$SRC/tests"
printf '#!/bin/bash\necho runner\n' > "$SRC/fly/builder-runner.sh"; chmod +x "$SRC/fly/builder-runner.sh"
for d in bin prompts rules catalog tests; do echo "fixture $d" > "$SRC/$d/x"; done
echo "fixture fleet" > "$SRC/fleet.conf"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm one
SHA1=$(git -C "$SRC" rev-parse HEAD)
echo two > "$SRC/bin/y"
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm two
BARE="$T/bare.git"
git clone -q --bare "$SRC" "$BARE"
git -C "$BARE" config uploadpack.allowAnySHA1InWant true
URL="file://$BARE"

TOKF="$T/token"; printf 'tok-fixture-harness-0001\n' > "$TOKF"
mkdir -p "$T/fakebin"
# A git wrapper that records the auth header git was given (F6), then runs git.
REALGIT=$(command -v git)
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = -C ] && [ "\${3:-}" = fetch ]; then
  i=0; while [ "\$i" -lt "\${GIT_CONFIG_COUNT:-0}" ]; do
    k="GIT_CONFIG_KEY_\$i"; v="GIT_CONFIG_VALUE_\$i"
    echo "\${!k}=\${!v}" >> "$T/git-cfg.txt"; i=\$((i + 1))
  done
  echo fetch >> "$T/git-fetches.txt"
fi
exec "$REALGIT" "\$@"
EOF
printf '#!/bin/bash\necho "nap $*" >> "%s"\nexit 0\n' "$T/sleeps.txt" > "$T/fakebin/sleep"
chmod +x "$T/fakebin"/*
hf() { # hf <dest> <sha> <slug> <tokf> -> rc; stdout+stderr in $T/out
  : > "$T/git-cfg.txt"; : > "$T/git-fetches.txt"; : > "$T/sleeps.txt"
  env PATH="$T/fakebin:$PATH" GIT_FETCH_URL_OVERRIDE="$URL" bash "$HF" "$2" "$3" "$4" "$1" > "$T/out" 2>&1
}

# F1/F2: the pinned (older) sha, not the tip.
FD="$T/d1"
hf "$FD" "$SHA1" example-org/cromford "$TOKF"; RC=$?
[ "$RC" = 0 ] && ok || bad "F1: rc must be 0, got $RC: $(cat "$T/out")"
[ "$(cat "$FD/HARNESS_COMMIT" 2>/dev/null)" = "$SHA1" ] && ok || bad "F1: HARNESS_COMMIT must be the pinned sha"
[ -f "$FD/fleet.conf" ] && [ -f "$FD/bin/x" ] && [ -f "$FD/prompts/x" ] && [ -f "$FD/rules/x" ] && [ -f "$FD/catalog/x" ] && ok \
  || bad "F1: the shipped paths must extract: $(cd "$FD" && find . -type f | tr '\n' ' ')"
[ ! -e "$FD/bin/y" ] && ok || bad "F1: bin/y is in the tip only; the pinned sha must not carry it"
[ ! -e "$FD/tests" ] && ok || bad "F1: tests/ is not a shipped path"
[ -x "$FD/fly/builder-runner.sh" ] && ok || bad "F2: the runner must stay executable"
[ -d "$FD/logs" ] && [ -d "$FD/state" ] && [ -d "$FD/locks" ] && [ -d "$FD/builds" ] && ok || bad "F2: logs state locks builds must exist"
[ ! -e "$FD.fetch" ] && ok || bad "F5: the scratch repo $FD.fetch must be removed"
[ ! -s "$T/sleeps.txt" ] && ok || bad "F1: a first-try fetch must not sleep"
grep -q 'tok-fixture' "$T/out" && bad "F5: token text in the output" || ok
# F6: the header is Basic base64(x-access-token:<token>).
WANT="http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' tok-fixture-harness-0001 | base64 -w0)"
grep -qxF "$WANT" "$T/git-cfg.txt" && ok || bad "F6: the fetch must carry the Basic auth header: $(cut -c1-60 "$T/git-cfg.txt")"
# An existing /data/harness/state file survives the extract (the seed put it there).
mkdir -p "$T/d2/state"; echo keep > "$T/d2/state/bake-evidence.txt"
hf "$T/d2" "$SHA1" example-org/cromford "$TOKF"
[ "$(cat "$T/d2/state/bake-evidence.txt" 2>/dev/null)" = keep ] && ok || bad "F2: a seeded state file must survive the extract"

# F3: a sha the repo does not have.
NOSHA=0123456789abcdef0123456789abcdef01234567
hf "$T/d3" "$NOSHA" example-org/cromford "$TOKF"; RC=$?
[ "$RC" = 1 ] && ok || bad "F3: an unknown sha must exit 1, got $RC"
[ "$(grep -c . "$T/git-fetches.txt")" = 3 ] && ok || bad "F3: 3 fetch attempts, got $(grep -c . "$T/git-fetches.txt")"
[ "$(grep -c '^nap 5$' "$T/sleeps.txt")" = 2 ] && ok || bad "F3: 2 sleeps of 5 s between 3 attempts, got: $(tr '\n' '|' < "$T/sleeps.txt")"
[ "$(grep -c 'harness-fetch FATAL: fetch of 0123456789ab from example-org/cromford failed 3 times' "$T/out")" = 1 ] && ok \
  || bad "F3: one FATAL line naming the sha and slug: $(cat "$T/out")"
[ ! -e "$T/d3/HARNESS_COMMIT" ] && ok || bad "F3: no stamp on a failed fetch"
[ ! -e "$T/d3.fetch" ] && ok || bad "F5: no scratch repo left after a failure"
grep -q 'tok-fixture' "$T/out" && bad "F5: token text in the failure output" || ok
# F3b: the bare repo is gone (GitHub down): the same answer.
URL="file://$T/nowhere.git" hf "$T/d3b" "$SHA1" example-org/cromford "$TOKF"; RC=$?
URL="file://$BARE"
[ "$RC" = 1 ] && ok || bad "F3b: an unreachable repo must exit 1, got $RC"

# F4: bad arguments never fetch.
for CASE in "badsha:abc123:example-org/cromford:$TOKF" \
            "upper:${SHA1^^}:example-org/cromford:$TOKF" \
            "slug:$SHA1:example-org/board harness:$TOKF" \
            "slug2:$SHA1:cromford:$TOKF" \
            "notok:$SHA1:example-org/cromford:$T/nope"; do
  IFS=: read -r ID S L K <<<"$CASE"
  hf "$T/d4-$ID" "$S" "$L" "$K"; RC=$?
  [ "$RC" = 2 ] && ok || bad "F4($ID): rc must be 2, got $RC: $(cat "$T/out")"
  [ ! -s "$T/git-fetches.txt" ] && ok || bad "F4($ID): no fetch may run"
  grep -q '^harness-fetch FATAL: ' "$T/out" && ok || bad "F4($ID): one FATAL line: $(cat "$T/out")"
done
: > "$T/empty-token"
hf "$T/d4-empty" "$SHA1" example-org/cromford "$T/empty-token"; RC=$?
[ "$RC" = 2 ] && ok || bad "F4(empty): an empty token file must exit 2, got $RC"
printf '\n\n' > "$T/blank-token"
hf "$T/d4-blank" "$SHA1" example-org/cromford "$T/blank-token"; RC=$?
[ "$RC" = 2 ] && ok || bad "F4(blank): a blank token file must exit 2, got $RC"
hf "relative/dir" "$SHA1" example-org/cromford "$TOKF"; RC=$?
[ "$RC" = 2 ] && ok || bad "F4(relative): a relative dest must exit 2, got $RC"

echo "fly-harness-fetch (BH-7430): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
