#!/bin/bash
# tests/watchdog-url-offbox.bh-2091-test.sh — the two WATCHDOG_URL callers that
# do not run on a box's harness (BH-3323, part 4 of BH-2091).
#
# WHY. bin/mac/mac-burn-push.sh (the operator's Mac) and publish-cromford.yml's stamp step
# (a GitHub runner) both carried the fleet watchdog host as a literal default.
# A fork running either one sent its shared secret to this fleet's worker. Both
# now take the URL from catalog/fleet-watchdog.json, and only when the checkout
# (Mac) or the repository (workflow) IS the catalog's repo.
#
# M  the REAL bin/mac/mac-burn-push.sh, run in place against scratch clones
# W  the stamp step's own `run:` body, extracted and run under bash -eo pipefail
# E  the env template: WATCHDOG_URL stays a comment in the render
# H  the fleet host is written literally in none of this child's files
#
# Fixtures use http://watchdog.invalid; the fleet host is only ever assembled
# from pieces here. Run from anywhere (0 = pass).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v python3 >/dev/null \
  || { echo "jq/git/python3 missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/mac/mac-burn-push.sh"
WF="$DIR/.github/workflows/publish-cromford.yml"
TPL="$DIR/env-templates/lanes/020-watchdog-dead-man-ping.env.example"
FLEET_HOST='harness-watchdog.'"operator"'.workers'"."'dev'

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/ledger/proj"
CALLS="$T/curl-calls.log"
cat > "$T/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$T/bin/curl"
printf 'fixture-watchdog-secret' > "$T/secret"
printf '{"timestamp":"%s.000Z","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%S')" > "$T/ledger/proj/s.jsonl"
printf '{"per_token": {"m": {"prompt": 0.01, "completion": 0.05, "cache_read": 0.001, "cache_write": 0.0125}}}\n' > "$T/prices.json"

# clone <name> <origin-url>: a tiny git checkout holding the catalog, origin set
clone() {
  local c="$T/$1"
  mkdir -p "$c/catalog"
  git -C "$c" init -q 2>/dev/null
  printf '{"repo":"example-org/cromford","watchdog_url":"https://%s"}\n' "$FLEET_HOST" > "$c/catalog/fleet-watchdog.json"
  git -C "$c" remote add origin "$2"
  printf '%s\n' "$c"
}

# mac <home> <checkout> [WATCHDOG_URL value] — the real script, in place
mac() {
  HOME="$1" PATH="$T/bin:$PATH" MACBURN_CHECKOUT="$2" MACBURN_SECRET_FILE="$T/secret" \
    MACBURN_LEDGER_DIR="$T/ledger" MACBURN_PRICES="$T/prices.json" \
    WATCHDOG_URL="${3-}" bash "$SCRIPT"
}
notset_count() { grep -cF '[mac-burn] WATCHDOG_URL not set' "$1/.mk-macburn.log" 2>/dev/null; }

# ── M1 fork origin: one not-set line, no curl, no scan, rc 0 ─────────────────
FORK=$(clone fork https://github.com/someone/cromford.git)
H1="$T/h1"; mkdir -p "$H1"; rm -f "$CALLS"
mac "$H1" "$FORK" ""; RC=$?
[ "$RC" -eq 0 ] && ok || bad "M1: fork origin must exit 0 (got $RC)"
[ ! -s "$CALLS" ] && ok || bad "M1: fork origin made a network call: $(head -1 "$CALLS")"
[ "$(notset_count "$H1")" = 1 ] && ok || bad "M1: want exactly one not-set line in \$HOME/.mk-macburn.log (log: $(cat "$H1/.mk-macburn.log" 2>/dev/null))"
grep -qE 'pushed|scan|push FAILED' "$H1/.mk-macburn.log" 2>/dev/null \
  && bad "M1: the scan/push ran for a fork: $(cat "$H1/.mk-macburn.log")" || ok

# ── M4 hourly rerun the same UTC day: still one line ─────────────────────────
mac "$H1" "$FORK" "" >/dev/null 2>&1
[ "$(notset_count "$H1")" = 1 ] && ok || bad "M4: second run the same day must not add a not-set line (count $(notset_count "$H1"))"
[ ! -s "$CALLS" ] && ok || bad "M4: second fork run made a network call"

# ── M2 / M2b the fleet's own origin (https and ssh): POST to the catalog URL ──
for pair in "M2 https://github.com/example-org/cromford.git" "M2b git@github.com:example-org/cromford.git"; do
  id=${pair%% *}; url=${pair#* }
  CK=$(clone "ck-$id" "$url"); HM="$T/home-$id"; mkdir -p "$HM"; rm -f "$CALLS"
  mac "$HM" "$CK" ""; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "$id: fleet origin must exit 0 (got $RC; log: $(cat "$HM/.mk-macburn.log" 2>/dev/null))"
  grep -qF "https://$FLEET_HOST/api/mac-burn" "$CALLS" 2>/dev/null && ok \
    || bad "$id: POST did not go to the catalog URL (curl: $(cat "$CALLS" 2>/dev/null | cut -c1-200))"
  [ "$(notset_count "$HM")" = 0 ] && ok || bad "$id: resolved URL but still logged not-set"
done

# ── M3 explicit WATCHDOG_URL wins over the catalog, trailing / stripped ──────
CK=$(clone ck-m3 https://github.com/example-org/cromford.git); HM="$T/home-m3"; mkdir -p "$HM"; rm -f "$CALLS"
mac "$HM" "$CK" "http://watchdog.invalid/"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "M3: explicit URL run must exit 0 (got $RC)"
grep -qF "http://watchdog.invalid/api/mac-burn" "$CALLS" 2>/dev/null && ok \
  || bad "M3: explicit WATCHDOG_URL did not win (curl: $(cut -c1-200 "$CALLS" 2>/dev/null))"
grep -qF "$FLEET_HOST" "$CALLS" 2>/dev/null && bad "M3: catalog URL used despite explicit WATCHDOG_URL" || ok

# ── W the stamp step, executed ───────────────────────────────────────────────
# step_body <workflow> <step-name-prefix> — the `run: |` body, dedented
# (same extraction as tests/gitleaks-pin.bh-2115-test.sh).
step_body() {
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
want = sys.argv[2].lower()
for i, l in enumerate(lines):
    m = re.match(r"^(\s*)- name:\s*(.*)$", l)
    if not (m and m.group(2).lower().startswith(want)):
        continue
    ind = len(m.group(1))
    for j in range(i + 1, len(lines)):
        s = lines[j]
        if re.match(r"^\s*- ", s) and len(s) - len(s.lstrip()) <= ind:
            break
        if re.match(r"^\s*run:\s*\|", s):
            rind = len(s) - len(s.lstrip())
            out = []
            for k in range(j + 1, len(lines)):
                b = lines[k]
                if b.strip() and len(b) - len(b.lstrip()) <= rind:
                    break
                out.append(b.strip("\n"))
            dd = min((len(b) - len(b.lstrip()) for b in out if b.strip()), default=0)
            print("\n".join(b[dd:] for b in out))
            sys.exit(0)
    break
sys.exit(1)
PY
}
BODY=$(step_body "$WF" "stamp the outside dead-man") || bad "W: no 'Stamp the outside dead-man' step with a run: body in publish-cromford.yml"
WD_DIR="$T/wf"; mkdir -p "$WD_DIR/catalog"
printf '{"repo":"example-org/cromford","watchdog_url":"https://%s"}\n' "$FLEET_HOST" > "$WD_DIR/catalog/fleet-watchdog.json"
# stamp <repo> <secret> — runs the body as GitHub would; stdout to $T/stamp.out
stamp() {
  local b="${BODY//'${{ github.repository }}'/$1}"
  rm -f "$CALLS"
  (cd "$WD_DIR" && STAMP_SECRET="$2" PATH="$T/bin:$PATH" bash --noprofile --norc -eo pipefail -c "$b") > "$T/stamp.out" 2>&1
}
ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }

stamp example-org/cromford s; RC=$?
[ "$RC" -eq 0 ] && ok || bad "W1: stamp step rc $RC ($(cat "$T/stamp.out"))"
[ "$(ncalls)" = 1 ] && grep -qF "https://$FLEET_HOST/api/stamp/share-mirror?s=s" "$CALLS" && ok \
  || bad "W1: want one POST to the catalog URL (curl: $(cat "$CALLS" 2>/dev/null))"

stamp someone/fork s; RC=$?
[ "$RC" -eq 0 ] && ok || bad "W2: fork stamp rc $RC ($(cat "$T/stamp.out"))"
grep -q 'no stamp' "$T/stamp.out" && ok || bad "W2: fork must print 'no stamp' (got: $(cat "$T/stamp.out"))"
[ "$(ncalls)" = 0 ] && ok || bad "W2: fork made a network call: $(cat "$CALLS")"

stamp example-org/cromford s; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncalls)" = 1 ] && grep -qF "https://$FLEET_HOST/api/stamp/share-mirror?s=s" "$CALLS" && ok \
  || bad "W3: repo match must be case-insensitive (rc $RC, curl: $(cat "$CALLS" 2>/dev/null))"

stamp example-org/cromford ""; RC=$?
[ "$RC" -eq 0 ] && ok || bad "W4: missing secret rc $RC"
grep -qF 'WATCHDOG_STAMP_SECRET not set: no stamp' "$T/stamp.out" && ok || bad "W4: missing secret message absent ($(cat "$T/stamp.out"))"
[ "$(ncalls)" = 0 ] && ok || bad "W4: missing secret made a network call"

# ── E the env template render ────────────────────────────────────────────────
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-env-example.sh" --check >"$T/e1.out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "E1: render-env-example --check rc $RC ($(tail -3 "$T/e1.out"))"
"$DIR/bin/render-env-example.sh" > "$T/render.txt" 2>/dev/null || bad "E2: render-env-example failed"
N=$(grep -c '^WATCHDOG_URL=' "$T/render.txt")
[ "$N" = 0 ] && ok || bad "E2: the render sets WATCHDOG_URL ($N lines) — it must stay a comment"
grep -qxF '# WATCHDOG_URL=https://<your-watchdog>.workers.dev' "$T/render.txt" && ok \
  || bad "E2: the render lacks the commented '# WATCHDOG_URL=https://<your-watchdog>.workers.dev' line"
grep -qF 'seeded' "$TPL" && grep -qF 'catalog/fleet-watchdog.json' "$TPL" && ok \
  || bad "E2: the template must say boxes get WATCHDOG_URL seeded from catalog/fleet-watchdog.json"

# ── H the fleet host literal lives only in catalog/ and docs/ ────────────────
for f in "$SCRIPT" "$WF" "$TPL" "$DIR/tests/watchdog-url-offbox.bh-2091-test.sh" \
         "$DIR/docs/notes/2026-09-28-BH-3323-watchdog-url-offbox.md"; do
  [ -f "$f" ] || { bad "H1: ${f#"$DIR"/} is missing"; continue; }
  grep -qF "$FLEET_HOST" "$f" && bad "H1: ${f#"$DIR"/} writes the fleet watchdog host literally" || ok
done

echo "watchdog-url-offbox.bh-2091: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
