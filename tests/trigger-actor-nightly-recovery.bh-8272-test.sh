#!/bin/bash
# tests/trigger-actor-nightly-recovery.bh-8272-test.sh — when the trigger-actor
# gate refuses an `ai-build` label added by github-actions[bot] on an issue the
# nightly red lane filed, the refusal comment says why and how to recover
# (BH-8272). Any other refusal keeps today's text.
#
# HOW IT DRIVES: the REAL bin/lib/trigger-actor.sh, bin/lib/harness-self.sh and
# bin/jobs-client.sh; only the wire is stubbed (_jobs_req, gh_rest,
# gh_rest_comment, lane_switch, bin/fleet-conf.sh), the stub shape of
# tests/trigger-actor-rearm.bh-6957-test.sh. ta_gate is called directly.
#   G1  github-actions[bot], body with the per-suite marker: rc 1, one comment
#       with the base text AND the recovery sentence
#   G2  the same with the run-level marker
#   G3  github-actions[bot], body without the marker: base text only
#   G4  dependabot[bot] with the marker: base text only, no issue read
#   G5  github-actions[bot], `harness-nightly-redx`, no comment opener, or a
#       null body: base text only
#   G6  github-actions[bot], the issue read fails (rc 75): base text, rc 1, the
#       ledger row is `ignored` with commented `yes`
#   G7  the posted comment never matches PROJECT_2_REARM_RE
# Run from anywhere: tests/trigger-actor-nightly-recovery.bh-8272-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "trigger-actor-nightly-recovery: jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/locks" "$H/logs" "$T/fx" "$T/build"
for s in bin/lib/trigger-actor.sh bin/lib/harness-self.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in
  board_prefix) printf '%s\n' - ;;
  repo)         printf '%s\n' "example-org/tproj" ;;
  *)            exit 1 ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"

cat > "$T/stubs.sh" <<'SH'
. "$REPO_DIR/bin/jobs-client.sh"
_jobs_req() {
  local m="$1" p="$2" b="${3:-}"
  case "$m $p" in
    "GET /api/settings/"*) return 2 ;;
    "GET /api/ledger?"*)
      [ -s "$LEDGER" ] || return 2
      jq -c '{ledger: .}' "$LEDGER"; return 0 ;;
    "PUT /api/ledger")
      printf '%s' "$b" | jq -c '{status, detail}' > "$LEDGER"; return 0 ;;
  esac
  return 1
}
gh() { :; }
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$CALLS/gh"
  case "$1 $2" in
    "GET repos/example-org/tproj/issues/77/events?"*) cat "$FX/events.json"; return 0 ;;
    "GET repos/example-org/tproj/issues/77/comments?"*) echo '[]'; return 0 ;;
    "GET repos/example-org/tproj/issues/77")
      [ "${ISSUE_RC:-0}" = 0 ] || { GH_REST_REASON=rate-limit; return "$ISSUE_RC"; }
      cat "$FX/issue.json"; return 0 ;;
  esac
  return 75
}
gh_rest_comment() { cat "$3" >> "$CALLS/comments"; return 0; }
lane_switch() { return 1; }
SH

export REPO_DIR="$DIR" FX="$T/fx" LEDGER="$T/ledger.json" CALLS="$T/calls" STUBS="$T/stubs.sh"
export HARNESS="$H" BUILD="$T/build"
export HARNESS_SELF_APPS="cromford cromford-board cromford-builders"
export HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.example.test
export PROJECT_2_EVENTS_RETRIES=0
export -n GH_ISSUES_REPO 2>/dev/null; unset GH_ISSUES_REPO

# The two markers bin/nightly-ticket.sh writes (SMARK and MARK).
SMARK='<!-- harness-nightly-red:tests/a-test.sh -->'
RMARK='<!-- harness-nightly-red -->'
BASE="only the people on this project's trigger list (or the harness itself) can start a build"
RECOVER='nightly red lane'
RECOVER2='take `ai-build` off and put it back'

# setup <actor> <issue body as a JSON value>
setup() {
  rm -f "${FX:?}/events.json" "${FX:?}/issue.json" "${LEDGER:?}"
  scratch_rm "$CALLS" || exit 1; mkdir -p "$CALLS"
  unset ISSUE_RC
  jq -nc --arg l "$1" '[{id:9001, event:"labeled", actor:{login:$l, type:"Bot"}, label:{name:"ai-build"},
                         created_at:"2026-10-24T08:00:00Z", performed_via_github_app:null}]' > "$FX/events.json"
  jq -nc --argjson b "$2" '{number:77, title:"Nightly: tests/a-test.sh red on main", body:$b}' > "$FX/issue.json"
}
run_gate() {
  local out
  out=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; rc=0
                 ta_gate tproj BH-77 77 "$BUILD" || rc=$?
                 printf "%s\n%s\n" "$rc" "$PROJECT_2_LINE"' 2>"$T/stderr")
  RC=$(sed -n 1p <<<"$out"); LINE=$(sed -n 2p <<<"$out")
  CMT=$(cat "$CALLS/comments" 2>/dev/null)
}
has() { grep -qF -- "$1" <<<"$CMT"; }
issue_reads() { grep -c '^GET repos/example-org/tproj/issues/77$' "$CALLS/gh" 2>/dev/null; }
js() { jq -n --arg s "$1" '$s'; }

# ── G1 ──────────────────────────────────────────────────────────────────────
setup 'github-actions[bot]' "$(js "$SMARK
The nightly run on main is red for \`tests/a-test.sh\`.")"
run_gate
[ "$RC" = 1 ] && ok || bad "G1: the bot label is still refused (rc=$RC line=$LINE)"
[ "$(grep -c "can start a build" "$CALLS/comments" 2>/dev/null)" = 1 ] && ok || bad "G1: exactly one comment: $CMT"
has "$BASE" && ok || bad "G1: the base text stays: $CMT"
has "$RECOVER" && has "$RECOVER2" && ok || bad "G1: the recovery sentence is added: $CMT"
G1CMT="$CMT"

# ── G2 ──────────────────────────────────────────────────────────────────────
setup 'github-actions[bot]' "$(js "$RMARK
The nightly run on main failed on \`abc\`.")"
run_gate
[ "$RC" = 1 ] && ok || bad "G2: rc=$RC"
has "$BASE" && has "$RECOVER" && has "$RECOVER2" && ok || bad "G2: the run-level marker adds the sentence too: $CMT"
G2CMT="$CMT"

# ── G3 ──────────────────────────────────────────────────────────────────────
setup 'github-actions[bot]' "$(js 'A bug a workflow filed. No nightly marker here.')"
run_gate
[ "$RC" = 1 ] && ok || bad "G3: rc=$RC"
has "$BASE" && ok || bad "G3: base text: $CMT"
has "$RECOVER" && bad "G3: no recovery sentence without the marker: $CMT" || ok
[ "$(issue_reads)" = 1 ] && ok || bad "G3: one issue read for the bot actor: $(cat "$CALLS/gh")"

# ── G4 ──────────────────────────────────────────────────────────────────────
setup 'dependabot[bot]' "$(js "$SMARK")"
run_gate
[ "$RC" = 1 ] && ok || bad "G4: rc=$RC"
has "$BASE" && ok || bad "G4: base text: $CMT"
has "$RECOVER" && bad "G4: another actor gets no recovery sentence: $CMT" || ok
[ "$(issue_reads)" = 0 ] && ok || bad "G4: another actor makes no issue read: $(cat "$CALLS/gh")"

# ── G5 ──────────────────────────────────────────────────────────────────────
for body in 'quoted <!-- harness-nightly-redx:tests/a-test.sh -->' 'mentions harness-nightly-red: in prose' null; do
  if [ "$body" = null ]; then setup 'github-actions[bot]' null; else setup 'github-actions[bot]' "$(js "$body")"; fi
  run_gate
  [ "$RC" = 1 ] && ok || bad "G5 ($body): rc=$RC"
  has "$BASE" && ok || bad "G5 ($body): base text: $CMT"
  has "$RECOVER" && bad "G5 ($body): a near-miss body gets no recovery sentence: $CMT" || ok
done

# ── G6 ──────────────────────────────────────────────────────────────────────
setup 'github-actions[bot]' "$(js "$SMARK")"
export ISSUE_RC=75
run_gate
unset ISSUE_RC
[ "$RC" = 1 ] && ok || bad "G6: a failed issue read still refuses (rc=$RC)"
has "$BASE" && ok || bad "G6: the plain comment still posts: $CMT"
has "$RECOVER" && bad "G6: no recovery sentence when the read failed: $CMT" || ok
[ "$(issue_reads)" = 1 ] && ok || bad "G6: the issue read was tried once: $(cat "$CALLS/gh")"
[ "$(jq -r '.status' "$LEDGER" 2>/dev/null)" = ignored ] && ok || bad "G6: ledger status: $(cat "$LEDGER" 2>/dev/null)"
[ "$(jq -r '.detail | fromjson | .commented' "$LEDGER" 2>/dev/null)" = yes ] && ok || bad "G6: ledger commented: $(cat "$LEDGER" 2>/dev/null)"

# ── G7 ──────────────────────────────────────────────────────────────────────
RE=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; printf "%s" "$PROJECT_2_REARM_RE"')
[ -n "$RE" ] && ok || bad "G7: PROJECT_2_REARM_RE not read"
for c in "$G1CMT" "$G2CMT"; do
  grep -qP -- "$RE" <<<"$c" && bad "G7: the comment carries a capital re-arm word: $c" || ok
done

echo "trigger-actor-nightly-recovery: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
