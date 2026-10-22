#!/bin/bash
# tests/mc-required-ci.bh-8012-test.sh — BH-8012: the conductor's READY gate
# decides on the repo's REQUIRED checks (.mergify.yml queue_rules
# check-success names), not on every workflow and not on mergeable_state.
#
# Incident: project-6 #2296 at 09:26Z sat `WAIT_CI ... merge=UNSTABLE
# reason=checks pending` while only the non-required `E2E n/4` jobs ran, and
# autoenqueue said "the conductor did not clear this head READY this tick".
#
# Part A (unit) sources bin/lib/mc-required-ci.sh with its seams stubbed
# (mc_mergify_required_checks, gh_rest, ae_mergify_admit_checks):
#   U1-U5  mcr_ci_override fires (prints green, rc 0)
#   N1-N14 mcr_ci_override does not fire (prints nothing, rc 1)
#   G1-G6  mcr_ae_unstable_ok: G5 may pass `unstable` (harness row, knob on,
#          names from .mergify.yml) or not (external, override check, knob 0,
#          names unreadable, legacy fallback)
# Part B (whole tick) drives the WHOLE bin/merge-conductor.sh in a scratch tree
# on a Mergify repo whose .mergify.yml requires `check-success=ci`:
#   T1 (the repro) required `ci` green, `E2E 1/4` in progress, UNSTABLE, lead
#      MERGE on the head -> READY, one CI_REQUIRED_GREEN line, one
#      `@mergifyio queue` POST in the same tick
#   T2 a red non-required workflow -> READY, no red strike, no rerun
#   T3 two ticks -> one CI_REQUIRED_GREEN line, one cireqgreen attempts line
#   T4 no alert line
#   T5 required `ci` in progress -> WAIT_CI checks pending, no POST
#   T6 a cancelled non-required run beside the override -> no flake rerun
#   K1 MC_CI_REQUIRED_ONLY=0 -> the T1 shape stays WAIT_CI checks pending
#   A1 the T1 POST passes G5 on `unstable`; A2 `blocked` refused; A4
#      MC_AUTOENQUEUE_CHECK set refused; A5 knob 0 refused; A6 legacy check
#      list refused
#   V1 every curl went to a .test host
# 0 network calls: the fake gh and curl are first on PATH.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-required-ci.bh-8012-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-required-ci: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID MC_CI_REQUIRED_ONLY MC_AUTOENQUEUE_CHECK
LIB="$DIR/bin/lib/mc-required-ci.sh"
FRAG="$DIR/bin/merge-conductor.d/bh-8012-required-ci.sh"

H1=$(printf 'a%.0s' $(seq 40))
SLUG=example-org/mkey-os

# cr <name|status|conclusion|started_at|completed_at>... — a check-runs page.
cr() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc '[inputs | split("|")
  | {name: .[0], status: .[1], conclusion: (if .[2] == "" then null else .[2] end),
     started_at: .[3], completed_at: (if (.[4] // "") == "" then null else .[4] end)}]
  | {total_count: length, check_runs: .}'; }
# runs <name|status|conclusion|started>... — an actions/runs page.
runs() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc '[inputs | split("|")] | to_entries
  | map({id: (.key + 100), name: .value[0], status: .value[1], conclusion: (if .value[2] == "" then null else .value[2] end),
         run_started_at: .value[3], run_attempt: 1})
  | {total_count: length, workflow_runs: .}'; }
OK_CI='ci|completed|success|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z'
E2E_RUN='E2E 1/4|in_progress||2026-10-22T09:01:00Z|'

# ============================================================================
# Part A — the lib, seams stubbed. In a subshell; exits with its fail count.
# ============================================================================
(
  F=0; no() { F=$((F+1)); echo "FAIL: mc-required-ci: $1"; }
  [ -r "$LIB" ] || { no "U0 bin/lib/mc-required-ci.sh is missing (part A not run)"; exit 1; }
  A="$T/a"; FXD="$A/fx"; mkdir -p "$FXD"
  export TMPDIR="$A"
  mc_mergify_required_checks() { echo "$1" >> "$FXD/req.log"; [ -e "$FXD/req-fail" ] && return 75; cat "$FXD/req" 2>/dev/null; return 0; }
  gh_rest() { echo "$2" >> "$FXD/rest.log"; [ -e "$FXD/cr-fail" ] && { GH_REST_STATUS=502; return 75; }; GH_REST_STATUS=200; cat "$FXD/cr.json"; }
  mc_ci_read_timeout_s() { echo 30; }
  # shellcheck source=bin/lib/mc-required-ci.sh
  . "$LIB" || exit 90
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD"; printf 'ci\n' > "$FXD/req"; unset MC_CI_REQUIRED_ONLY; }
  # fire <label> <raw> [slug] [provider] — want green, rc 0
  fire() { local out rc; out=$(mcr_ci_override "${3:-$SLUG}" "$H1" "$2" "${4:-mergify}"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = green ] || no "$1 must fire (rc $rc out '$out')"; }
  # hold <label> <raw> [slug] [provider] — want nothing, rc 1
  hold() { local out rc; out=$(mcr_ci_override "${3:-$SLUG}" "$H1" "$2" "${4:-mergify}"); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] || no "$1 must not fire (rc $rc out '$out')"; }

  reset; cr "$OK_CI" "$E2E_RUN" > "$FXD/cr.json"; fire "U1 ci success + E2E 1/4 in_progress" pending
  grep -qx "repos/$SLUG/commits/$H1/check-runs?per_page=100" "$FXD/rest.log" || no "U1 one check-runs read of this head ($(cat "$FXD/rest.log"))"
  mcr_ci_override "$SLUG" "$H1" pending mergify >/dev/null
  [[ ${MCR_WHY:-} == "required ci green; pending is non-required" ]] || no "U1 MCR_WHY names the required set ($MCR_WHY)"
  reset; cr "$OK_CI" 'E2E 2/4|completed|failure|2026-10-22T09:01:00Z|2026-10-22T09:05:00Z' > "$FXD/cr.json"; fire "U2 ci success + E2E 2/4 failure (raw red)" red
  reset; cr 'ci|in_progress|success|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z' "$E2E_RUN" > "$FXD/cr.json"; fire "U3 ci in_progress/success with completed_at (BH-7121)" pending
  reset; printf 'ci\ne2e-ratchet\n' > "$FXD/req"
  cr "$OK_CI" 'e2e-ratchet|completed|success|2026-10-22T09:00:00Z|2026-10-22T09:12:00Z' "$E2E_RUN" > "$FXD/cr.json"; fire "U4 two required names green" pending
  reset; cr 'ci|in_progress||2026-10-22T09:00:00Z|' 'ci|completed|success|2026-10-22T09:20:00Z|2026-10-22T09:30:00Z' "$E2E_RUN" > "$FXD/cr.json"
  fire "U5 an older ci in_progress, the newest ci success" pending

  reset; cr 'ci|in_progress||2026-10-22T09:00:00Z|' "$E2E_RUN" > "$FXD/cr.json"; hold "N1 required ci in_progress" pending
  mcr_ci_override "$SLUG" "$H1" pending mergify >/dev/null
  [[ ${MCR_WHY:-} == "required 'ci' is in_progress/none" ]] || no "N1 MCR_WHY names the held check ($MCR_WHY)"
  reset; cr 'ci|completed|failure|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z' > "$FXD/cr.json"; hold "N2 required ci failure" red
  reset; cr "$E2E_RUN" > "$FXD/cr.json"; hold "N3 required ci absent" pending
  reset; printf 'ci\ne2e-ratchet\n' > "$FXD/req"; cr "$OK_CI" 'e2e-ratchet|in_progress||2026-10-22T09:00:00Z|' > "$FXD/cr.json"; hold "N4 one of two required pending" pending
  reset; cr "$OK_CI" "$E2E_RUN" | jq -c '.total_count = 120' > "$FXD/cr.json"; hold "N5 total_count past page 1" pending
  reset; : > "$FXD/req-fail"; cr "$OK_CI" > "$FXD/cr.json"; hold "N6 .mergify.yml unreadable" pending
  [ ! -s "$FXD/rest.log" ] || no "N6 no check-runs read when the required list is unread"
  mcr_ci_override "$SLUG" "$H1" pending mergify >/dev/null; [ "${MCR_WHY:-}" = required-unread ] || no "N6 MCR_WHY required-unread ($MCR_WHY)"
  reset; : > "$FXD/req"; cr "$OK_CI" > "$FXD/cr.json"; hold "N7 no check-success name" pending
  mcr_ci_override "$SLUG" "$H1" pending mergify >/dev/null; [ "${MCR_WHY:-}" = required-none ] || no "N7 MCR_WHY required-none ($MCR_WHY)"
  reset; cr "$OK_CI" "$E2E_RUN" > "$FXD/cr.json"; hold "N8 project-4" pending example-org/project-4
  [ ! -s "$FXD/req.log" ] && [ ! -s "$FXD/rest.log" ] || no "N8 project-4 reads nothing"
  reset; cr "$OK_CI" "$E2E_RUN" > "$FXD/cr.json"; hold "N9 provider github" pending "$SLUG" github
  hold "N9 provider none" pending "$SLUG" none
  for w in none unavailable green ''; do hold "N10 raw '$w'" "$w"; done
  [ ! -s "$FXD/rest.log" ] || no "N9/N10 no read for a provider or word the override never applies to"
  reset; cr "$OK_CI" "$E2E_RUN" > "$FXD/cr.json"; MC_CI_REQUIRED_ONLY=0; hold "N11 knob 0" pending; unset MC_CI_REQUIRED_ONLY
  reset; cr 'ci-extra|completed|success|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z' 'ci|in_progress||2026-10-22T09:00:00Z|' > "$FXD/cr.json"; hold "N12 a near-miss name" pending
  reset; cr "$OK_CI" 'ci|in_progress||2026-10-22T09:20:00Z|' > "$FXD/cr.json"; hold "N13 the newest ci run is in_progress" pending
  reset; : > "$FXD/cr-fail"; hold "N14 the check-runs read failed" pending
  reset; echo 'not json' > "$FXD/cr.json"; hold "N14 an unparseable page" pending
  reset; cr 'ci|completed|neutral|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z' > "$FXD/cr.json"; hold "N14 neutral is not success" pending
  for x in 0 1 '' abc; do MC_CI_REQUIRED_ONLY="$x"; mcr_enabled; r=$?
    case "$x" in 0) [ "$r" = 1 ] || no "K0 knob '$x' is off" ;; *) [ "$r" = 0 ] || no "K0 knob '$x' is on" ;; esac; done
  unset MC_CI_REQUIRED_ONLY

  # G — mcr_ae_unstable_ok (autoenqueue G5).
  ae_mergify_admit_checks() { [ -e "$FXD/adm-fail" ] && return 1; cat "$FXD/adm" 2>/dev/null; return 0; }
  greset() { reset; printf 'ci\n' > "$FXD/adm"; AE_CHECKS=ci; AE_EXTERNAL=0; unset MC_AUTOENQUEUE_CHECK; }
  greset; mcr_ae_unstable_ok "$SLUG" || no "G1 harness row, names from .mergify.yml: unstable passes"
  greset; AE_EXTERNAL=1; mcr_ae_unstable_ok "$SLUG" && no "G2 an external row keeps clean only (BH-4572)"
  greset; MC_AUTOENQUEUE_CHECK=ci; mcr_ae_unstable_ok "$SLUG" && no "G3 MC_AUTOENQUEUE_CHECK set: clean only"
  greset; MC_CI_REQUIRED_ONLY=0; mcr_ae_unstable_ok "$SLUG" && no "G4 knob 0: clean only"; unset MC_CI_REQUIRED_ONLY
  greset; : > "$FXD/adm-fail"; mcr_ae_unstable_ok "$SLUG" && no "G5 .mergify.yml unreadable: clean only"
  greset; : > "$FXD/adm"; AE_CHECKS='Build + Unit tests'; mcr_ae_unstable_ok "$SLUG" && no "G6 the legacy fallback list: clean only"
  greset; AE_CHECKS=''; mcr_ae_unstable_ok "$SLUG" && no "G6 no checks: clean only"
  greset; printf 'ci\ne2e-ratchet\n' > "$FXD/adm"; AE_CHECKS=$'ci\ne2e-ratchet'; mcr_ae_unstable_ok "$SLUG" || no "G1 two names from .mergify.yml: unstable passes"
  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# ============================================================================
# Part B — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
# The fragment and its lib. Before BH-8012 neither exists, and the tick runs as on main.
if [ -r "$FRAG" ]; then ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-8012-required-ci.sh "$CH" >/dev/null ) || exit 1; fi
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
printf 'mkey %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
REC="$CH/builds/pool-mkey-TK-31-202610220001"; mkdir -p "$REC"
U="https://github.com/$SLUG/pull"
YML_CI=$(printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=ci\n    merge_method: squash\n' | base64 | tr -d '\n')
YML_NONE=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
mkdir -p "$C/fakebin"
# The fake curl: the jobs worker. FX/standing is the standing verdict row.
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/verdicts\?*) emit 200 "\$(cat "$FX/standing" 2>/dev/null || echo '{"standing":null}')" ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
# The fake gh. FX/yml .mergify.yml (base64), FX/runs.json actions/runs,
# FX/cr.json commits/<head>/check-runs, FX/pms the REST mergeable state word.
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"run rerun"*|*"/rerun"*) printf '%s\n' "\$*" >> "$FX/reruns.txt" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"\$(cat "$FX/yml")\"}" ;;
  *"actions/runs?head_sha="*) restpr --raw 200 "\$(cat "$FX/runs.json")" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) printf '%s\n' "\$*" >> "$FX/cr-reads.txt"; restpr --raw 200 "\$(cat "$FX/cr.json")" ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/31/labels"*) printf '%s\n' "\$*" >> "$FX/label-posts.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$FX/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$FX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST "*|*"api -X POST "*) printf '%s\n' "\$*" >> "$FX/other-posts.txt"; restpr --raw 201 '{}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/TK-31 main "" MERGEABLE "\$(cat "$FX/pms")" operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) jq -c --arg m "\$(cat "$FX/mstate")" '.[0].mergeStateStatus = \$m' "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
cat > "$C/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/TK-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
CLOG="$CH/logs/merge-conductor.log"
ATT="$CH/state/merge-conductor/attempts.txt"
# fresh — the T1 shape: required ci green on actions/runs and check-runs, the
# non-required e2e workflow / E2E 1/4 check in progress, UNSTABLE on both
# reads, builder APPROVE and a standing lead MERGE-WITH-NOTES on the head.
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; mkdir -p "$CH/state" "$FX"
  : > "$CLOG"; : > "$CH/logs/ALERTS.log"; : > "$FX/calls.txt"
  echo "$YML_CI" > "$FX/yml"; echo UNSTABLE > "$FX/mstate"; echo UNSTABLE > "$FX/pms"
  runs 'ci|completed|success|2026-10-22T09:00:00Z' 'e2e|in_progress||2026-10-22T09:01:00Z' > "$FX/runs.json"
  cr "$OK_CI" "$E2E_RUN" > "$FX/cr.json"
  jq -nc '{standing:{verdict:"MERGE-WITH-NOTES",source:"lead",id:3490,created_at:"2026-10-22T09:20:00Z",report_url:"-",reviewer:"lead"}}' > "$FX/standing"
  echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
}
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
clog() { grep -E '#31' "$CLOG" | tail -"${1:-6}"; }
crow() { awk -F'\t' -v k="$SLUG#31" '$1==k {print $2 "|" $7}' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
reqline() { grep -c "$SLUG#31 CI_REQUIRED_GREEN" "$CLOG" 2>/dev/null || true; }

# T1 — the repro: READY and enqueued in the same tick.
fresh; tick
[ "$(crow)" = "READY|clean, approved, checks green" ] && ok || bad "T1 required ci green + E2E in progress: READY (row: $(crow); log: $(clog))"
[ "$(n "$FX/queue-posts.txt")" = 1 ] && ok || bad "T1/A1 one @mergifyio queue POST in the same tick (queue $(n "$FX/queue-posts.txt"); log: $(clog 10))"
grep -qF "$SLUG#31 CI_REQUIRED_GREEN on ${H1:0:8}: required ci green; pending is non-required" "$CLOG" && ok \
  || bad "T1 one CI_REQUIRED_GREEN line naming ci and the head (log: $(clog))"
! grep -q "#31 not enqueued at" "$CLOG" && ok || bad "T1 no autoenqueue refusal ($(grep 'not enqueued' "$CLOG"))"
[ "$(n "$FX/merges.txt")" = 0 ] && ok || bad "T1 no direct merge on a Mergify repo"
# T3 — a second tick on the same head: one line, one attempts line.
tick
[ "$(reqline)" = 1 ] && [ "$(grep -c "^cireqgreen $SLUG#31 $H1\$" "$ATT" 2>/dev/null)" = 1 ] && ok \
  || bad "T3 two ticks: 1 CI_REQUIRED_GREEN line ($(reqline)), 1 cireqgreen attempts line ($(grep -c cireqgreen "$ATT" 2>/dev/null))"
# T4 — no alert from any of it.
[ "$(n "$CH/logs/ALERTS.log")" = 0 ] && ok || bad "T4 no alert line ($(cat "$CH/logs/ALERTS.log"))"

# T2 — a RED non-required workflow, required ci green: READY, no strike, no rerun.
fresh
runs 'ci|completed|success|2026-10-22T09:00:00Z' 'e2e|completed|failure|2026-10-22T09:01:00Z' > "$FX/runs.json"
cr "$OK_CI" 'E2E 2/4|completed|failure|2026-10-22T09:01:00Z|2026-10-22T09:05:00Z' > "$FX/cr.json"
tick
[ "$(crow)" = "READY|clean, approved, checks green" ] && [ "$(n "$FX/queue-posts.txt")" = 1 ] && ok \
  || bad "T2 a red non-required workflow: READY and enqueued (row $(crow); queue $(n "$FX/queue-posts.txt"); log: $(clog))"
! grep -q "^red $SLUG#31 " "$ATT" 2>/dev/null && [ "$(n "$FX/reruns.txt")" = 0 ] && ok \
  || bad "T2 no red strike ($(grep "^red " "$ATT" 2>/dev/null)), no rerun ($(cat "$FX/reruns.txt" 2>/dev/null))"

# T5 — required ci in progress: WAIT_CI checks pending, nothing posted (acceptance 2).
fresh
runs 'ci|in_progress||2026-10-22T09:00:00Z' 'e2e|in_progress||2026-10-22T09:01:00Z' > "$FX/runs.json"
cr 'ci|in_progress||2026-10-22T09:00:00Z|' "$E2E_RUN" > "$FX/cr.json"
tick
[ "$(crow)" = "WAIT_CI|checks pending" ] && [ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(reqline)" = 0 ] && ok \
  || bad "T5 required ci pending: WAIT_CI checks pending, no POST, no CI_REQUIRED_GREEN (row $(crow); queue $(n "$FX/queue-posts.txt"))"

# T6 — a cancelled non-required run beside the override: no flake rerun.
fresh
runs 'ci|completed|success|2026-10-22T09:00:00Z' 'e2e|in_progress||2026-10-22T09:01:00Z' 'lint|completed|cancelled|2026-10-22T09:02:00Z' > "$FX/runs.json"
tick
[ "$(crow)" = "READY|clean, approved, checks green" ] && [ "$(n "$FX/reruns.txt")" = 0 ] && ! grep -q 'would re-run\|flake rerun' "$CLOG" && ok \
  || bad "T6 a cancelled non-required run: READY, no rerun (row $(crow); reruns $(cat "$FX/reruns.txt" 2>/dev/null); log: $(clog))"

# K1 — the kill switch: the T1 shape stays WAIT_CI checks pending, as before BH-8012.
fresh; tick MC_CI_REQUIRED_ONLY=0
[ "$(crow)" = "WAIT_CI|checks pending" ] && [ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(reqline)" = 0 ] && ok \
  || bad "K1 MC_CI_REQUIRED_ONLY=0: WAIT_CI checks pending, no POST (row $(crow); queue $(n "$FX/queue-posts.txt"))"

# A — G5 on a READY row whose every workflow is green (no override needed).
green_runs() { runs 'ci|completed|success|2026-10-22T09:00:00Z' > "$FX/runs.json"; cr "$OK_CI" > "$FX/cr.json"; }
# A2 — `blocked` is refused.
fresh; green_runs; echo blocked > "$FX/pms"; tick
[ "$(n "$FX/queue-posts.txt")" = 0 ] && grep -q "#31 not enqueued at ${H1:0:8}: mergeable — mergeable_state blocked, not clean" "$CLOG" && ok \
  || bad "A2 G5 refuses blocked (queue $(n "$FX/queue-posts.txt"); log: $(clog))"
# A1b — a green row, REST unstable: enqueued.
fresh; green_runs; tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && ok || bad "A1 G5 passes unstable on a harness row (queue $(n "$FX/queue-posts.txt"); log: $(clog))"
# A4 — MC_AUTOENQUEUE_CHECK set: clean only.
fresh; green_runs; tick MC_AUTOENQUEUE_CHECK=ci
[ "$(n "$FX/queue-posts.txt")" = 0 ] && grep -q "mergeable_state unstable, not clean" "$CLOG" && ok \
  || bad "A4 MC_AUTOENQUEUE_CHECK set: unstable refused (queue $(n "$FX/queue-posts.txt"); log: $(clog))"
# A5 — knob 0: clean only.
fresh; green_runs; tick MC_CI_REQUIRED_ONLY=0
[ "$(n "$FX/queue-posts.txt")" = 0 ] && grep -q "mergeable_state unstable, not clean" "$CLOG" && ok \
  || bad "A5 knob 0: unstable refused (queue $(n "$FX/queue-posts.txt"); log: $(clog))"
# A6 — .mergify.yml names no check: the legacy list, clean only.
fresh; green_runs; echo "$YML_NONE" > "$FX/yml"
cr "$OK_CI" 'Build + Unit tests|completed|success|2026-10-22T09:00:00Z|2026-10-22T09:10:00Z' > "$FX/cr.json"; tick
[ "$(n "$FX/queue-posts.txt")" = 0 ] && grep -q "mergeable_state unstable, not clean" "$CLOG" && ok \
  || bad "A6 legacy check list: unstable refused (queue $(n "$FX/queue-posts.txt"); log: $(clog))"

# V1 — every curl went to a .test host.
OUT=$(awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "V1 a curl left the fixture hosts: $OUT"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-required-ci.bh-8012: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
