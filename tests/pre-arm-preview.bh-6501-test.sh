#!/bin/bash
# tests/pre-arm-preview.bh-6501-test.sh — the Vercel preview gate (BH-6501).
#   D1-D17  pap_check rows of bin/lib/pre-arm-preview.sh on fixture snapshots
#   K1-K3   knob defaults, the empty project list, a settings row
#   RT1     the writer's own jq (bin/vercel-deploy-snapshot.sh) read back by pap_check
#   E1-E7   the whole bin/pre-arm-guards.sh against a gh shim
# Run from anywhere: bash tests/pre-arm-preview.bh-6501-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/pre-arm-preview.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 2026-10-15 14:00:00Z; the snapshot was written 2 minutes before.
NOW=1792072800
NOW_MS=$((NOW * 1000))
GEN="2026-10-15 13:58:00Z"
HEAD=a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0
OTHER=0000000000000000000000000000000000000001
TWIN=a1b2c3d4e5f6ffffffffffffffffffffffffffff   # the same first 12 chars as HEAD
URL_ERR=https://project-3-fixture-err.example.test
URL_OK=https://project-3-fixture-ok.example.test

mkdir -p "$T/state/vercel-deploys" "$T/bin"
cat > "$T/fleet.conf" <<'EOF'
# project repo prod board slot box ip (fixture)
project-3   example-org/project-3   https://project-3-fixture.example.test  /api/feature-board 6 box-fixture 192.0.2.1
project-4   example-org/project-4   https://project-4-fixture.example.test  /api/board         8 box-fixture 192.0.2.2
project-6 example-org/project-6 https://mk-fixture.example.test    /api/board         9 box-fixture 192.0.2.3
EOF

# row <sha> <state> <createdAt json> [url]
row() { printf '{"sha":"%s","url":"%s","state":"%s","createdAt":%s}' "$1" "${4:-$URL_ERR}" "$2" "$3"; }
# snap <project> <generated_at> <rows json array> — the per-project snapshot file
snap() { jq -nc --arg g "$2" --arg p "$1" --argjson r "$3" '{generated_at:$g, project:$p, previews:$r}' > "$T/state/vercel-deploys/$1.json"; }
clear_snaps() { rm -f "$T/state/vercel-deploys/"*.json "$T/state/vercel-deploy-status.json"; }

# chk <label> <slug> <head> <ref> <word> [detail-substring] — pap_check in a clean env
chk() {
  local label="$1" slug="$2" h="$3" ref="$4" want="$5" sub="${6:-}" out w d
  out=$(env -u PRE_ARM_PREVIEW_PROJECTS -u PRE_ARM_PREVIEW_EXEMPT_BRANCHES -u PRE_ARM_PREVIEW_WAIT_MIN \
          -u PRE_ARM_PREVIEW_STALE_MIN ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
          HARNESS="$T" PAP_NOW="$NOW" bash -c '. "$1" || exit 9; pap_check "$2" "$3" "$4"' _ "$LIB" "$slug" "$h" "$ref")
  IFS=$'\t' read -r w d <<<"$out"
  if [ "$w" = "$want" ] && { [ -z "$sub" ] || [[ "$d" == *"$sub"* ]]; }; then ok
  else bad "$label: want $want${sub:+ ~ '$sub'}, got '$out'"; fi
}
EXTRA_ENV=()

# ---------- D: pap_check rows ------------------------------------------------
snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 300000)))]"
chk "D1 newest row ERROR" example-org/project-3 "$HEAD" feat/x-fixture red "Vercel preview ERROR on a1b2c3d4e5f6 ($URL_ERR)"

snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 600000))),$(row "$HEAD" READY $((NOW_MS - 60000)) "$URL_OK")]"
chk "D2 ERROR then a newer READY" example-org/project-3 "$HEAD" feat/x-fixture pass READY

snap project-3 "$GEN" "[$(row "$OTHER" ERROR $((NOW_MS - 60000)))]"
chk "D3 ERROR on another sha only" example-org/project-3 "$HEAD" feat/x-fixture unseen

snap project-3 "$GEN" "[$(row "$HEAD" BUILDING $((NOW_MS - 300000)))]"
chk "D4 BUILDING 5 min" example-org/project-3 "$HEAD" feat/x-fixture wait "Vercel preview BUILDING on a1b2c3d4e5f6 for 5m"
snap project-3 "$GEN" "[$(row "$HEAD" QUEUED "$NOW_MS")]"
chk "D5 QUEUED 0 min" example-org/project-3 "$HEAD" feat/x-fixture wait "QUEUED on a1b2c3d4e5f6 for 0m"
snap project-3 "$GEN" "[$(row "$HEAD" BUILDING $((NOW_MS - 1200000)))]"
chk "D6 BUILDING exactly 20 min" example-org/project-3 "$HEAD" feat/x-fixture pass BUILDING
snap project-3 "$GEN" "[$(row "$HEAD" BUILDING '"soon"')]"
chk "D7 BUILDING, non-numeric createdAt" example-org/project-3 "$HEAD" feat/x-fixture pass BUILDING

snap project-3 "$GEN" "[$(row "$HEAD" CANCELED $((NOW_MS - 60000)))]"
chk "D8 CANCELED" example-org/project-3 "$HEAD" feat/x-fixture pass CANCELED

snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "D9 rollback branch" example-org/project-3 "$HEAD" rollback/2026-10-08-fixture exempt 'rollback/*'
chk "D10 revert branch" example-org/project-3 "$HEAD" revert-486-fixture exempt 'revert-*'
chk "D10b glob anchors at the start" example-org/project-3 "$HEAD" feat/rollback-fixture red
chk "D10c ERROR with the head in upper case" example-org/project-3 "$(tr '[:lower:]' '[:upper:]' <<<"$HEAD")" feat/x-fixture red

snap project-4 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "D11 project-4 is not gated" example-org/project-4 "$HEAD" feat/x-fixture off
chk "D11b slug not in fleet.conf" example-org/nowhere-fixture "$HEAD" feat/x-fixture off

clear_snaps
chk "D12 no snapshot file and no status file" example-org/project-3 "$HEAD" feat/x-fixture blind "snapshot unreadable"
echo '{}' > "$T/state/vercel-deploys/project-3.json"
chk "D13 {}" example-org/project-3 "$HEAD" feat/x-fixture blind "snapshot unreadable"
echo 'not json' > "$T/state/vercel-deploys/project-3.json"
chk "D13b not JSON" example-org/project-3 "$HEAD" feat/x-fixture blind "snapshot unreadable"
snap project-3 "2026-10-15 13:29:00Z" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "D14 snapshot 31 min old" example-org/project-3 "$HEAD" feat/x-fixture blind "snapshot 31m old"
snap project-3 "2026-10-15 13:31:00Z" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "D15 snapshot 29 min old, ERROR" example-org/project-3 "$HEAD" feat/x-fixture red

clear_snaps
jq -nc --arg g "$GEN" --argjson r "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]" \
  '{generated_at:$g, projects:{"project-3":{domain:"project-3-fixture.example.test", previews:$r}}}' > "$T/state/vercel-deploy-status.json"
chk "D16 box fallback: vercel-deploy-status.json only" example-org/project-3 "$HEAD" feat/x-fixture red "$URL_ERR"

clear_snaps
snap project-3 "$GEN" "[$(row "$TWIN" ERROR $((NOW_MS - 60000)))]"
chk "D17 a sha that shares 12 chars with the head" example-org/project-3 "$HEAD" feat/x-fixture unseen
chk "D17b empty head" example-org/project-3 "" feat/x-fixture blind "no head sha"
snap project-3 "$GEN" "[$(row "$HEAD" READY $((NOW_MS - 60000)) "$URL_OK"),$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "D17c same createdAt: ERROR wins" example-org/project-3 "$HEAD" feat/x-fixture red

# ---------- K: knobs ----------------------------------------------------------
snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
snap project-6 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
chk "K1 defaults: project-3 is gated" example-org/project-3 "$HEAD" feat/x-fixture red
chk "K1 defaults: project-6 is not" example-org/project-6 "$HEAD" feat/x-fixture off
EXTRA_ENV=(PRE_ARM_PREVIEW_PROJECTS=)
chk "K2 empty project list" example-org/project-3 "$HEAD" feat/x-fixture off
EXTRA_ENV=(PRE_ARM_PREVIEW_PROJECTS="project-3 project-6")
chk "K2b project-6 opted in" example-org/project-6 "$HEAD" feat/x-fixture red
EXTRA_ENV=()

# K3: pap_knobs reads a settings row (lib.pre-arm-preview.*) through lib_env_apply.
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"
jq -e '.libs[] | select(.id == "pre-arm-preview") | .knobs | length == 4' "$REG" >/dev/null 2>&1 \
  && ok || bad "K3 the registry carries the pre-arm-preview lib with 4 knobs"
jq -n --argjson fa "$NOW" '{fetched_at:$fa, values:{"lib.pre-arm-preview.pre_arm_preview_projects":"project-6"}, seeded:{}}' \
  > "$T/state/settings-cache.json"
K3=$(env -u PRE_ARM_PREVIEW_PROJECTS HARNESS="$T" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' PAP_NOW="$NOW" \
     bash -c '. "$1" || exit 9; pap_knobs; printf "%s|" "$PRE_ARM_PREVIEW_PROJECTS"; pap_check example-org/project-3 "$2" f; pap_check example-org/project-6 "$2" f' _ "$LIB" "$HEAD" 2>"$T/k3.err")
[ "$K3" = "$(printf 'project-6|off\t-\nred\tVercel preview ERROR on a1b2c3d4e5f6 (%s)' "$URL_ERR")" ] \
  && ok || bad "K3 settings row PRE_ARM_PREVIEW_PROJECTS=project-6 moves the gate (got '$K3', err $(head -3 "$T/k3.err"))"
rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"

# ---------- RT1: the writer's own jq, read back -------------------------------
WRITER="$DIR/bin/vercel-deploy-snapshot.sh"
BLOCK=$(awk '/PREVIEWS=\$\(api/{f=1} f{print} f && /\|\| PREVIEWS=/{exit}' "$WRITER")
PROG=${BLOCK#*jq -c \'}; PROG=${PROG%%\' 2>/dev/null*}
WRAP=$(grep -F 'project:$p, previews:$prevs' "$WRITER" | head -1); WRAP=${WRAP#*\'}; WRAP=${WRAP%%\'*}
if [ -z "$PROG" ] || [ "$PROG" = "$BLOCK" ] || [ -z "$WRAP" ]; then
  bad "RT1 could not extract the writer's jq from $WRITER"
else
  API=$(jq -nc --arg h "$HEAD" --argjson c $((NOW_MS - 120000)) \
    '{deployments:[{uid:"dpl_fixture1", url:"project-3-fixture-err.example.test", state:"ERROR", created:$c, meta:{githubCommitSha:$h}},
                   {uid:"dpl_fixture2", url:"project-3-fixture-ok.example.test", state:"READY", created:($c - 600000), meta:{githubCommitSha:$h}}]}')
  PREVS=$(jq -c "$PROG" <<<"$API")
  clear_snaps
  jq -nc --arg ts "$GEN" --arg p project-3 --argjson prevs "$PREVS" "$WRAP" > "$T/state/vercel-deploys/project-3.json"
  chk "RT1 writer's format read back" example-org/project-3 "$HEAD" feat/x-fixture red "($URL_ERR)"
fi

# ---------- E: the whole bin/pre-arm-guards.sh --------------------------------
# gh shim: the PR read answers the head from $T/pr-head ("<sha> <ref>"), or 500
# when it holds "fail"; there is no static-guards.yml (404). Every call is logged.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "workflow run") exit 0 ;;
  "api -i")
    case "$*" in
      *repos/*/pulls/*)
        read -r s r < "$PR_HEAD_FILE"
        [ "$s" = fail ] && { printf 'HTTP/2.0 500\r\n\r\n{"message":"fixture failure"}\n'; exit 1; }
        printf 'HTTP/2.0 200\r\n\r\n{"number":77,"head":{"sha":"%s","ref":"%s"}}\n' "$s" "$r" ;;
      *actions/workflows/static-guards.yml*) printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
      *) printf 'HTTP/2.0 404\r\n\r\n{}\n'; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
# The gate script under test, run in place. HARNESS is the scratch tree, so
# fleet.conf, the snapshot and gh-app-auth's env all resolve inside $T.
guard() {
  : > "$T/gh.calls"; printf '%s %s\n' "$1" "$2" > "$T/pr-head"
  env -u PRE_ARM_PREVIEW_PROJECTS -u PRE_ARM_PREVIEW_EXEMPT_BRANCHES -u PRE_ARM_PREVIEW_WAIT_MIN \
      -u PRE_ARM_PREVIEW_STALE_MIN PATH="$T/bin:$PATH" HARNESS="$T" HOME="$T" PAP_NOW="$NOW" \
      GH_CALLS="$T/gh.calls" PR_HEAD_FILE="$T/pr-head" GH_ETAG=0 PRE_ARM_WAIT_SECS=1 PRE_ARM_POLL_SECS=0 \
      "$DIR/bin/pre-arm-guards.sh" "$3" 77 2>"$T/err"
}

clear_snaps
snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
snap project-4 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
OUT=$(guard "$HEAD" feat/x-fixture example-org/project-3); RC=$?
[ "$RC" -eq 1 ] && ok || bad "E1 red head → rc 1 (rc=$RC err=$(cat "$T/err"))"
[ "$OUT" = "vercel-preview: Vercel preview ERROR on a1b2c3d4e5f6 ($URL_ERR)" ] && [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] \
  && [[ "$OUT" != *$'\t'* ]] && ok || bad "E1 stdout is one tab-free vercel-preview line (got '$OUT')"
grep -q 'repos/example-org/project-3/pulls/77' "$T/gh.calls" && ok || bad "E1 the PR head was read (calls: $(cat "$T/gh.calls"))"
! grep -qE 'workflow run|actions/workflows' "$T/gh.calls" && ok || bad "E1 no workflow lookup or dispatch after a red preview (calls: $(cat "$T/gh.calls"))"
grep -q 'pre-arm preview: RED example-org/project-3#77 — Vercel preview ERROR on a1b2c3d4e5f6' "$T/err" \
  && ok || bad "E2 stderr names RED, the slug and the PR (err: $(cat "$T/err"))"

OUT=$(guard "$HEAD" feat/x-fixture example-org/project-4); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'no static-guards.yml on example-org/project-4' "$T/err" \
  && ok || bad "E3 project-4 runs the old path (rc=$RC out=$OUT err=$(cat "$T/err"))"
! grep -q '/pulls/' "$T/gh.calls" && ok || bad "E3 a non-gated repo costs no PR read (calls: $(cat "$T/gh.calls"))"
! grep -q 'pre-arm preview' "$T/err" && ok || bad "E3 off prints nothing (err: $(cat "$T/err"))"

clear_snaps
OUT=$(guard "$HEAD" feat/x-fixture example-org/project-3); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'pre-arm preview: blind example-org/project-3#77 — snapshot unreadable' "$T/err" \
  && grep -q 'no static-guards.yml on example-org/project-3' "$T/err" \
  && ok || bad "E4 blind snapshot falls through to the old path (rc=$RC out=$OUT err=$(cat "$T/err"))"

snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
OUT=$(guard "$HEAD" rollback/2026-10-08-fixture example-org/project-3); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'pre-arm preview: exempt example-org/project-3#77 — rollback/\*' "$T/err" \
  && ok || bad "E5 rollback branch with ERROR runs the old path (rc=$RC out=$OUT err=$(cat "$T/err"))"

snap project-3 "$GEN" "[$(row "$HEAD" BUILDING $((NOW_MS - 300000)))]"
OUT=$(guard "$HEAD" feat/x-fixture example-org/project-3); RC=$?
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && grep -q 'pre-arm preview: WAIT example-org/project-3#77 — Vercel preview BUILDING' "$T/err" \
  && ok || bad "E6 building preview → rc 3 (rc=$RC out=$OUT err=$(cat "$T/err"))"
! grep -qE 'workflow run|actions/workflows' "$T/gh.calls" && ok || bad "E6 no workflow lookup or dispatch on wait (calls: $(cat "$T/gh.calls"))"

snap project-3 "$GEN" "[$(row "$HEAD" ERROR $((NOW_MS - 60000)))]"
OUT=$(guard fail x example-org/project-3); RC=$?
[ "$RC" -eq 2 ] && grep -q 'pre-arm preview: blind example-org/project-3#77 — no head sha' "$T/err" \
  && ok || bad "E7 a failed PR read is blind and never red (rc=$RC out=$OUT err=$(cat "$T/err"))"

echo "pre-arm-preview.bh-6501: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
