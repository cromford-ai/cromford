#!/bin/bash
# tests/nightly-ticket-app-token.bh-6957-test.sh — the nightly-red filer opens
# and labels its issues as the harness App (NT_APP_TOKEN), not as the
# workflow's own github.token, so the `labeled ai-build` actor is one the
# trigger-actor gate accepts (BH-6957).
#
# Drives the real bin/nightly-ticket.sh against a stub gh that records the
# GH_TOKEN of every call (`<token><TAB><argv>`):
#   A1  NT_APP_TOKEN set: the create POST carries the App token; the open-issue
#       search carries the workflow token; the tsv row is written
#   A2  GitHub drops the label on create: the labels POST carries the App token
#   A3  NT_APP_TOKEN empty: no create at all, ONE refusal line on stderr for
#       two refused creates, rc 1 (BH-8272 replaced the old file-as-GH_TOKEN)
#   A4  the comment-on-an-open-issue path carries the workflow token; no output
#       and no tsv row ever holds the App token
#   A4b neither the filer nor the workflow touches a trigger.actors row
#   A5  the App create fails: rc 1, and no silent retry as the workflow token
#   W1  harness-nightly.yml mints the App token before the verdict step and
#       hands it over as NT_APP_TOKEN; on main the mint always runs and a
#       failed mint fails the job (BH-8272)
# Run from anywhere: tests/nightly-ticket-app-token.bh-6957-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NT="$DIR/bin/nightly-ticket.sh"
WF="$DIR/.github/workflows/harness-nightly.yml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "nightly-ticket-app-token: jq missing — skipping"; exit 0; }

WF_TOK=wf-tok-fixture
APP_TOK=app-tok-fixture

cat > "$T/gh" <<'GH'
#!/bin/bash
printf '%s\t%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_SINK"
JQ=""; POST=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    api) ;;
    --jq) JQ="$2"; shift ;;
    -X) [ "$2" = POST ] && POST=1; shift ;;
    -F|-f) shift ;;
    --paginate) ;;
    *) P="$1" ;;
  esac
  shift
done
if [ "$POST" = 1 ]; then
  case "$P" in
    */labels) printf '[{"name":"ai-build"}]\n' | jq -r "${JQ:-.}"; exit 0 ;;
    */comments) printf '{"id":1}\n' | jq -r "${JQ:-.}"; exit 0 ;;
  esac
  [ -n "${FAKE_FAIL_CREATE:-}" ] && exit 1
  N=$(( $(cat "$FAKE_N" 2>/dev/null || echo 100) + 1 )); echo "$N" > "$FAKE_N"
  printf '%s\n' "$FAKE_CREATE_JSON" | jq --argjson n "$N" '.number = $n' | jq -r "${JQ:-.}"
  exit 0
fi
jq -r "$JQ" "$FAKE_OPEN"
GH
chmod +x "$T/gh"

mkdir -p "$T/v" "$T/v2"
printf 'tests=1\nfailed=1\n' > "$T/v/shard-0.txt"
printf -- '--- tests/a-test.sh rc=1 1s\n' > "$T/v/shard-0.log"
printf 'tests=2\nfailed=2\n' > "$T/v2/shard-0.txt"
printf -- '--- tests/a-test.sh rc=1 1s\n--- tests/b-test.sh rc=1 1s\n' > "$T/v2/shard-0.log"
MARK='<!-- harness-nightly-red:tests/a-test.sh -->'
printf '[]\n' > "$T/none.json"
jq -n --arg m "$MARK" '[{number:77,body:("old " + $m)}]' > "$T/open.json"
LABELLED='{"number":0,"labels":[{"name":"ai-build"}]}'
DROPPED='{"number":0,"labels":[]}'

run() { # run <verdict-dir> <open.json> <create-json> [VAR=value ...]
  local v="$1" open="$2" create="$3"; shift 3
  : > "$T/sink"; rm -f "$T/n"
  OUT=$(env GH_TOKEN="$WF_TOK" NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_N="$T/n" FAKE_OPEN="$open" FAKE_CREATE_JSON="$create" \
          NT_REPO=o/r NT_SHA=abc NT_PLAN_RESULT=success NT_PLAN_N=1 "$@" \
          bash "$NT" "$v" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
tok_of() { grep -P "^[^\t]*\t$1" "$T/sink" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//'; }
CREATE='api -X POST repos/o/r/issues -f'
SEARCH='api --paginate repos/o/r/issues\?state=open'

# ── A1 ──────────────────────────────────────────────────────────────────────
run "$T/v" "$T/none.json" "$LABELLED" NT_APP_TOKEN="$APP_TOK"
[ "$RC" = 0 ] && ok || bad "A1: rc $RC (err: $ERR)"
[ "$(tok_of "$CREATE")" = "$APP_TOK" ] && ok || bad "A1: the create call must carry the App token, got '$(tok_of "$CREATE")' ($(cat "$T/sink"))"
[ "$(tok_of "$SEARCH")" = "$WF_TOK" ] && ok || bad "A1: the open-issue search must keep the workflow token, got '$(tok_of "$SEARCH")'"
grep -q "^tests/a-test.sh	.*	new	https://github.com/o/r/issues/101$" "$T/v/ticket-requests.tsv" && ok \
  || bad "A1: the tsv must carry the new row: $(cat "$T/v/ticket-requests.tsv")"
case "$ERR" in *"NT_APP_TOKEN not set"*) bad "A1: no warning when the App token is set ($ERR)" ;; *) ok ;; esac
case "$OUT$ERR$(cat "$T/v/ticket-requests.tsv")" in *"$APP_TOK"*) bad "A1: the App token leaked into stdout, stderr or the tsv" ;; *) ok ;; esac

# ── A2 ──────────────────────────────────────────────────────────────────────
run "$T/v" "$T/none.json" "$DROPPED" NT_APP_TOKEN="$APP_TOK"
[ "$RC" = 0 ] && ok || bad "A2: rc $RC (err: $ERR)"
LBL='api -X POST repos/o/r/issues/101/labels'
[ "$(grep -cP "\t$LBL " "$T/sink")" = 1 ] && ok || bad "A2: expected one labels POST: $(cat "$T/sink")"
[ "$(tok_of "$LBL")" = "$APP_TOK" ] && ok || bad "A2: the labels POST must carry the App token, got '$(tok_of "$LBL")'"

# ── A3 ──────────────────────────────────────────────────────────────────────
# BH-8272: with no App token the filer refuses; it never files as GH_TOKEN.
run "$T/v2" "$T/none.json" "$LABELLED" NT_APP_TOKEN=
[ "$RC" = 1 ] && ok || bad "A3: rc $RC (err: $ERR)"
[ "$(grep -cP "\t$CREATE" "$T/sink")" = 0 ] && ok || bad "A3: two suites, no create: $(cat "$T/sink")"
[ -z "$(tok_of "$CREATE")" ] && ok || bad "A3: with no App token no create is made as any token, got '$(tok_of "$CREATE")'"
# Anchored: under GitHub Actions the script also prints the same text as an
# ::error:: annotation (A3b checks that one), and an unanchored count saw 2.
[ "$(grep -c '^nightly-ticket: no App token; refusing to file a ticket the trigger-actor gate would ignore' "$T/err")" = 1 ] && ok \
  || bad "A3: exactly one refusal line expected: $ERR"
# the same with NT_APP_TOKEN absent from the environment, under Actions
OUT=$(env -u NT_APP_TOKEN GH_TOKEN="$WF_TOK" GITHUB_ACTIONS=true NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_N="$T/n" \
        FAKE_OPEN="$T/none.json" FAKE_CREATE_JSON="$LABELLED" NT_REPO=o/r NT_SHA=abc NT_PLAN_N=1 \
        bash "$NT" "$T/v" 2>"$T/err"); RC=$?
[ "$RC" = 1 ] && ok || bad "A3b: rc $RC"
[ "$(grep -c '^::error::' "$T/err")" = 1 ] && ok || bad "A3b: under GitHub Actions the refusal is one ::error:: annotation: $(cat "$T/err")"
grep -q '^::warning::' "$T/err" && bad "A3b: the ::warning:: path is gone: $(cat "$T/err")" || ok

# ── A4 ──────────────────────────────────────────────────────────────────────
run "$T/v" "$T/open.json" "$LABELLED" NT_APP_TOKEN="$APP_TOK"
[ "$RC" = 0 ] && ok || bad "A4: rc $RC"
CMT='api -X POST repos/o/r/issues/77/comments'
[ "$(tok_of "$CMT")" = "$WF_TOK" ] && ok || bad "A4: the comment keeps the workflow token, got '$(tok_of "$CMT")'"
grep -qP "\t$CREATE" "$T/sink" && bad "A4: an open issue must not be created again" || ok
case "$OUT$ERR$(cat "$T/v/ticket-requests.tsv")" in *"$APP_TOK"*) bad "A4: the App token leaked" ;; *) ok ;; esac

# ── A4b ─────────────────────────────────────────────────────────────────────
[ -r "$NT" ] && [ -r "$WF" ] && ok || bad "A4b: filer or workflow missing"
grep -n 'trigger\.actors' "$NT" "$WF" && bad "A4b: the filer and the workflow must not touch a trigger.actors row" || ok

# ── A5 ──────────────────────────────────────────────────────────────────────
run "$T/v" "$T/none.json" "$LABELLED" NT_APP_TOKEN="$APP_TOK" FAKE_FAIL_CREATE=1
[ "$RC" = 1 ] && ok || bad "A5: a refused App create is rc 1 (got $RC)"
[ "$(tok_of "$CREATE")" = "$APP_TOK" ] && ok || bad "A5: no create may be retried as the workflow token, got '$(tok_of "$CREATE")'"

# ── W1 ──────────────────────────────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  W1=$(python3 - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["verdict"]["steps"]
names = [s.get("name", "") for s in steps]
errs = []
vi = next((i for i, s in enumerate(steps) if "nightly-ticket.sh" in str(s.get("run", ""))), None)
ai = next((i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/create-github-app-token@")), None)
if vi is None: errs.append("no verdict step runs bin/nightly-ticket.sh")
if ai is None: errs.append("no actions/create-github-app-token step in the verdict job")
if vi is not None and ai is not None:
    a, v = steps[ai], steps[vi]
    if ai > vi: errs.append("the app-token step must come before the verdict step")
    if a.get("id") != "app-token": errs.append(f"app-token step id is {a.get('id')!r}")
    if a.get("continue-on-error") is True: errs.append("a mint failure must fail the job (continue-on-error must not be true)")
    w = a.get("with") or {}
    if "secrets.HARNESS_APP_PRIVATE_KEY" not in str(w.get("private-key", "")): errs.append(f"private-key: {w.get('private-key')!r}")
    if "vars.HARNESS_APP_ID" not in str(w.get("app-id", "")): errs.append(f"app-id: {w.get('app-id')!r}")
    if "vars.HARNESS_APP_ID" in str(a.get("if", "")) or "refs/heads/main" not in str(a.get("if", "")):
        errs.append(f"the mint must run on every main run, an unset app id is a failed mint: if: {a.get('if')!r}")
    env = v.get("env") or {}
    if str(env.get("NT_APP_TOKEN", "")).replace(" ", "") != "${{steps.app-token.outputs.token}}":
        errs.append(f"verdict NT_APP_TOKEN is {env.get('NT_APP_TOKEN')!r}")
    if "github.token" not in str(env.get("GH_TOKEN", "")): errs.append("GH_TOKEN must stay github.token for reads and comments")
print("\n".join(errs))
PY
)
  [ -z "$W1" ] && ok || bad "W1: $W1"
else
  echo "nightly-ticket-app-token: python3 with yaml missing — W1 skipped"
fi

echo "nightly-ticket-app-token: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
