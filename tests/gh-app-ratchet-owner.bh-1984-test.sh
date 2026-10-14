#!/bin/bash
# tests/gh-app-ratchet-owner.bh-1984-test.sh — BH-1984: THE RAW-PAT MARKERS
# NAME A LIVE OWNER, AND CI READS THAT OWNER WITH AN APP TOKEN.
#
# The three raw-pat markers in bin/ cited BH-425, the App-token rollout parent,
# after it closed on 2026-09-22. Block 3d of tests/gh-app-ratchet-test.sh is
# the check that says so, and CI never ran it: the shard step exported no
# token, so every read came back empty and printed a SKIP. A stale owner hid.
#
#   1  no marker in bin/ still reads `raw-pat (BH-425)`
#   2  every raw-pat marker cites a ticket key, and none of them is 425
#   3  each raw-pat script's registry note names the key its marker cites
#   4  the REAL ratchet suite hands GH_APP_RATCHET_OWNER_TOKEN to its owner
#      read as GH_TOKEN; unset, the read carries no caller credential (BH-6672:
#      tests/lib/scratch.sh strips the caller's GH_TOKEN)
#   5  the same suite goes red with `is CLOSED` when the owner read says closed
#   6  the workflow: the shard job may read issues, the tests/ step gets the
#      token on pull requests only, and no step in the job sets GH_TOKEN
#
# 4 and 5 drive tests/gh-app-ratchet-test.sh itself, in a scratch checkout,
# against a PATH stub `gh`.
# No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The marker line of every raw-pat file, as "<path under bin/><TAB><key>".
MARKERS="$T/markers.tsv"
grep -rn --include='*.sh' '^# gh-identity: raw-pat' "$DIR/bin" \
  | sed -n 's|^'"$DIR"'/bin/\([^:]*\):[0-9]*:# gh-identity: raw-pat (\([^)]*\)).*|\1\t\2|p' \
  > "$MARKERS"

# ── 1. no marker cites BH-425 ─────────────────────────────────────────────
if grep -rl --include='*.sh' '^# gh-identity: raw-pat (BH-425)' "$DIR/bin"; then
  bad "case 1: a raw-pat marker in bin/ still cites BH-425, which is CLOSED"
else
  ok
fi

# ── 2. every raw-pat marker cites a key, and none of them is 425 ─────────
NRAW=$(grep -rl --include='*.sh' '^# gh-identity: raw-pat' "$DIR/bin" | wc -l)
NKEY=$(wc -l < "$MARKERS")
if [ "$NRAW" -eq 0 ]; then
  ok   # every raw-pat file converted; nothing left to cite a ticket
elif [ "$NKEY" -ne "$NRAW" ]; then
  bad "case 2: $NRAW raw-pat markers but only $NKEY of them cite a (KEY)"
else
  while IFS=$'\t' read -r f key; do
    case "$key" in
      BH-[0-9]*|\#[0-9]*) : ;;
      *) bad "case 2: bin/$f cites '$key', not a ticket key"; continue ;;
    esac
    [ "${key##*[-#]}" = 425 ] && bad "case 2: bin/$f still cites $key"
  done < "$MARKERS"
  ok
fi

# ── 3. the registry note names the same owner as the marker ──────────────
while IFS=$'\t' read -r f key; do
  reg="$DIR/tests/gh-app-ratchet-baseline/$f.txt"
  n=${key##*[-#]}
  if [ ! -f "$reg" ]; then
    bad "case 3: bin/$f is raw-pat but has no registry note tests/gh-app-ratchet-baseline/$f.txt"
  elif ! grep -Eq "(BH-|#)$n([^0-9]|$)" "$reg"; then
    bad "case 3: tests/gh-app-ratchet-baseline/$f.txt does not name $key, the owner its marker cites"
  elif grep -Eq '#425 owns|425 owns' "$reg"; then
    bad "case 3: tests/gh-app-ratchet-baseline/$f.txt still says #425 owns it"
  else
    ok
  fi
done < "$MARKERS"

# ── 4/5. the real ratchet suite against a stub gh ────────────────────────
# Run in a scratch copy that is a checkout with an origin, because block 3d
# skips without one, and the gate runs this suite from an export that has none
# (the same slice tests/ratchet-markers-test.sh builds).
SRC="$T/src"; mkdir -p "$SRC/tests"
cp -a "$DIR/bin" "$SRC/bin"
cp -a "$DIR/tests/lib" "$DIR/tests/gh-app-ratchet-baseline" \
      "$DIR/tests/gh-app-ratchet-by-design" "$DIR/tests/gh-app-ratchet-test.sh" "$SRC/tests/"
git -C "$SRC" init -q . >/dev/null 2>&1
git -C "$SRC" remote add origin https://github.com/example-org/cromford.git >/dev/null 2>&1
# The stub answers the owner read with $STUB_STATE and logs the GH_TOKEN that
# read went out on. Anything else is rc 1, which the suite treats as absent.
SB="$T/stubbin"; mkdir -p "$SB"
cat > "$SB/gh" <<SH
#!$BASH_BIN
if [ "\$1" = api ] && [[ "\$2" == repos/*/issues/* ]]; then
  printf 'token=%s\n' "\${GH_TOKEN:-<unset>}" >> "$T/gh.log"
  echo "\$STUB_STATE"; exit 0
fi
exit 1
SH
chmod +x "$SB/gh"

run_suite() { # run_suite <state> <owner token or -> <ambient GH_TOKEN>
  : > "$T/gh.log"
  if [ "$2" = - ]; then
    env -u GH_APP_RATCHET_OWNER_TOKEN PATH="$SB:$PATH" STUB_STATE="$1" GH_TOKEN="$3" \
      HARNESS_TEST_SANDBOX=1 "$BASH_BIN" "$SRC/tests/gh-app-ratchet-test.sh" > "$T/out.txt" 2>&1
  else
    env PATH="$SB:$PATH" STUB_STATE="$1" GH_TOKEN="$3" GH_APP_RATCHET_OWNER_TOKEN="$2" \
      HARNESS_TEST_SANDBOX=1 "$BASH_BIN" "$SRC/tests/gh-app-ratchet-test.sh" > "$T/out.txt" 2>&1
  fi
}

if [ ! -s "$MARKERS" ]; then
  ok   # no raw-pat marker means block 3d reads nothing; cases 4-5 have no subject
elif [ -z "$(git -C "$SRC" config --get remote.origin.url 2>/dev/null)" ]; then
  bad "cases 4-5: could not make the scratch copy a checkout with an origin (is git on PATH?)"
else
  run_suite open tok-FIXTURE-1984 ambient-FIXTURE-1984; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "case 4: the ratchet suite was rc $rc with the owner answering open"; sed 's/^/    /' "$T/out.txt"
  elif ! grep -qx 'token=tok-FIXTURE-1984' "$T/gh.log"; then
    bad "case 4: the owner read did not go out on GH_APP_RATCHET_OWNER_TOKEN (log: $(tr '\n' ' ' < "$T/gh.log"))"
  elif grep -q 'token=ambient-FIXTURE-1984' "$T/gh.log"; then
    bad "case 4: an owner read went out on the ambient GH_TOKEN although the owner token was set"
  else
    ok
  fi

  run_suite open - ambient-FIXTURE-1984; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "case 4: the ratchet suite was rc $rc with no owner token"; sed 's/^/    /' "$T/out.txt"
  # TEST-CHANGE (BH-6672): tests/lib/scratch.sh strips every inherited GitHub
  # credential, so with no owner token the read carries NO caller GH_TOKEN (it
  # used to go out on the caller's own token). The ambient fixture must never
  # reach the stub, and the read still happens (one logged call, token unset).
  elif grep -q 'token=ambient-FIXTURE-1984' "$T/gh.log" || ! grep -qx 'token=<unset>' "$T/gh.log"; then
    bad "case 4: without GH_APP_RATCHET_OWNER_TOKEN the read must carry no caller credential (log: $(tr '\n' ' ' < "$T/gh.log"))"
  else
    ok
  fi

  run_suite closed tok-FIXTURE-1984 ambient-FIXTURE-1984; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "case 5: the ratchet suite passed with the owner answering closed"
  elif ! grep -q 'is CLOSED' "$T/out.txt"; then
    bad "case 5: rc $rc but no 'is CLOSED' finding"; sed 's/^/    /' "$T/out.txt"
  else
    ok
  fi
fi

# ── 6. the workflow wiring, parsed ───────────────────────────────────────
if ! python3 -c 'import yaml' 2>/dev/null; then
  bad "case 6: PyYAML is not importable here, so the workflow could not be parsed"
else
  out=$(python3 - "$WF" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
job = wf["jobs"].get("tests-shard")
errs = []
if job is None:
    print("no tests-shard job"); sys.exit(0)
perms = job.get("permissions") or {}
for scope in ("contents", "issues"):
    if perms.get(scope) != "read":
        errs.append(f"permissions.{scope} is {perms.get(scope)!r}, want 'read'")
steps = job.get("steps") or []
suite = [s for s in steps if str(s.get("name", "")).startswith("tests/ suite")]
if len(suite) != 1:
    errs.append(f"{len(suite)} 'tests/ suite' steps, want 1")
else:
    expr = str((suite[0].get("env") or {}).get("GH_APP_RATCHET_OWNER_TOKEN", ""))
    if "github.event_name == 'pull_request'" not in expr:
        errs.append(f"the owner token is not gated on pull_request: {expr!r}")
    if "github.token" not in expr:
        errs.append(f"the owner token is not github.token: {expr!r}")
for s in steps:
    if "GH_TOKEN" in (s.get("env") or {}) or "GH_TOKEN=" in str(s.get("run", "")):
        errs.append(f"step {s.get('name') or s.get('uses')!r} sets GH_TOKEN")
if "GH_TOKEN" in (job.get("env") or {}):
    errs.append("the job sets GH_TOKEN")
print("\n".join(errs))
PY
)
  if [ -n "$out" ]; then
    while IFS= read -r l; do bad "case 6: $l"; done <<< "$out"
  else
    ok
  fi
fi

echo "gh-app-ratchet-owner.bh-1984-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
