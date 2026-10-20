#!/bin/bash
# tests/postmerge-qa.bh-1022-test.sh — BH-1022: a merged build whose sha prod
# never serves stops being re-offered.
#
# THE DEFECT THIS PINS. bin/postmerge-qa.sh's deploy gate has exactly one answer
# for "prod is not serving the merge sha": say it and come back next tick. It
# reads no clock and writes no state, so a merge that never deploys is re-offered
# on every wake forever — 30,698 requeue lines for one project in three days, a
# feed that never drains and nobody told that a merge never reached production.
#
# WHAT IS DRIVEN HERE, against the REAL script in a scratch harness:
#
#   1. AFTER THE LIMIT IT IS TERMINAL, ONCE. A build merged longer ago than
#      POSTMERGE_QA_DEPLOY_MAX_HOURS that still fails the gate gets one
#      NOT_COVERED_DEPLOY_TIMEOUT row, one ALERTS line naming the sha and what is
#      needed, one fleet_alert beat — and nothing is driven, so no spend.
#   2. THE SECOND TICK IS SILENT. The done row is the dedup; no second alert, no
#      second beat, no re-offer.
#   3. UNDER THE LIMIT NOTHING CHANGES. Same requeue line, no done row, no alert.
#   4. ABSENT IS NOT OLD. No mergedAt = no clock = requeue forever, never a
#      terminal state on missing data.
#   5. THE DEPLOYED PATH IS UNTOUCHED. 13 h old but actually served is driven
#      exactly as before.
#   6. THE KNOB IS THE THRESHOLD. 0 = off; a non-number says so and uses 12.
#   7. A TIMED-OUT BUILD DOES NOT SPEND THE POSTMERGE_QA_MAX SLOT.
#   8. A SUPERSEDED MERGE IS A SERVED MERGE. A VERSION_URL reports the sha prod
#      serves NOW, which is the newest merge; this one is live if the reported
#      sha IS it or DESCENDS from it (the rule bin/deploy-train.sh already uses).
#      An unrelated live sha still ages out; a live sha the clone has never seen
#      is "cannot tell" and never terminal.
#   9. ONLY "NOT YET" AGES OUT. "Cannot tell" (rc 2 — curl/gh unreadable) is a
#      per-BOX fact, so twelve hours of it must never write every merged build
#      of every project terminal in one tick.
#  10. AN EMPTY mergeCommit.oid DOES NOT SHIFT THE FIELDS. A merged PR whose oid
#      GitHub leaves null is skipped, never probed with a timestamp for a sha.
#
# Every assertion is on what the run WROTE (the done file, ALERTS.log, the beat
# argv, the drive sink) — never on the script's source text.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-1022-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_CLERK=https://api.clerk.com
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"

# ONE clock read for the whole suite; every fixture age is derived from it, so a
# case cannot mean a different number of hours depending on when it runs.
# determinism: ok-file clock-date-cmd clock-rolling-window NOW is pinned once here and every fixture age is relative to it
NOW=$(date +%s)
ago_h() { date -u -d "@$((NOW - ${1} * 3600))" '+%Y-%m-%dT%H:%M:%SZ'; }

SHA_A=deadbeefcafe1234
SHA_B=feedfacecafe5678

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
new_harness() {
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin" "$T/fakebin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" \
           "$T/builds" "$T/clerk" "$T/repo"
  local F
  for F in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh qa-account.sh \
           fleet-conf.sh prod-url.sh findings-log.sh alert_family.py; do
    cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
  done
  # BH-1941: the Clerk base URL resolves through bin/lib/endpoints.sh, shipped beside the script.
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$T/bin/lib/"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  # BH-1510.1: this lane's model is a model_routes row (postmerge.qa); this
  # worker-less box carries the resolver beside the lane and its cache of #1507's table.
  mkdir -p "$T/bin/lib"
  mrs_fixture "$T" project-3
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$T/env/project-3.env"
  echo active > "$T/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/bin/beat.sh"
  chmod +x "$T/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/agent-calls.txt"\nexit "${AGENT_RC:-0}"\n' "$T" > "$T/bin/agent-call.sh"
  chmod +x "$T/bin/agent-call.sh"
  # Fake gh. Same shape as tests/postmerge-qa-test.sh's, plus the mergedAt field
  # this ticket reads, and a SECOND PR (pull/8) whose sha prod does serve — the
  # slot-consumption case needs two builds that answer the gate differently.
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "\$GH_SINK"
# A null column is rendered the way the CALLER'S OWN -q expression says to —
# the filter is right there in argv, so the fake answers \`// "-"\` with the
# sentinel and \`// ""\` with an empty field, exactly as real gh + jq would. That
# keeps the expression load-bearing: revert the sentinel and the empty middle
# column comes back, which is the field shift case P is about.
SENT=0; case "\$*" in *'// "-"'*) SENT=1 ;; esac
col() { if [ -n "\$1" ]; then printf '%s' "\$1"; elif [ "\$SENT" = 1 ]; then printf -- '-'; fi; }
case "\$*" in
  *"pr view"*state,mergeCommit*)
    # A field the caller did not ask for is not in the JSON, so \`.mergedAt // "-"\`
    # yields the sentinel — which is exactly what a caller that forgets the
    # field gets, and why the mutation of that argv has to go red.
    AT=""; AT_B=""
    # Matched on the --json FIELD LIST, not on \$* — the -q expression names
    # .mergedAt too, so a looser glob would answer the field to a caller that
    # never requested it and the argv would stop being load-bearing.
    case "\$*" in *"--json state,mergeCommit,mergedAt"*) AT="\${MERGED_AT:-}"; AT_B="\${MERGED_AT_B:-}" ;; esac
    # \${MERGE_SHA-…}, not \${MERGE_SHA:-…}: an explicitly EMPTY merge sha is the
    # null-oid case and must reach the script as the sentinel, not as the default.
    case "\$*" in
      *pull/8*) printf '%s\t%s\t%s\n' "\${PR_STATE:-MERGED}" "\$(col "\${MERGE_SHA_B-$SHA_B}")" "\$(col "\$AT_B")" ;;
      *)        printf '%s\t%s\t%s\n' "\${PR_STATE:-MERGED}" "\$(col "\${MERGE_SHA-$SHA_A}")" "\$(col "\$AT")" ;;
    esac ;;
  *"deployments/88/statuses"*)   echo success ;;
  *"deployments/"*"/statuses"*)  echo "\${DEPLOY_STATE:-success}" ;;
  *deployments*)
    [ "\${DEPLOY_API:-ok}" = down ] && exit 1
    case "\$*" in *"\${MERGE_SHA_B:-$SHA_B}"*) echo 88 ;; *) echo "\${DEPLOY_ID:-99}" ;; esac ;;
  *"pr comment"*) : ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
[ -n "${CURL_SINK:-}" ] && echo "$*" >> "$CURL_SINK"
URL="${!#}"
case "$URL" in
  *"/v1/users/"*)
    UID_="${URL##*/v1/users/}"; UID_="${UID_%%/*}"
    SF="$CLERK_STATE_DIR/$UID_"; [ -f "$SF" ] || echo active > "$SF"
    case "$URL" in
      */ban)   echo banned > "$SF"; printf '200'; exit 0 ;;
      */unban) echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    if [ "$(cat "$SF")" = banned ]; then B=true; else B=false; fi
    printf '{"id":"%s","banned":%s}' "$UID_" "$B" ;;
  *) printf '%s' "${VERSION_BODY:-}" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/curl"
  cat > "$T/fakebin/node" <<'EOF'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT=""
for A in "$@"; do case "$A" in */qa-prod-shots) OUT="$A" ;; esac; done
[ -n "$OUT" ] && { mkdir -p "$OUT"; : > "$OUT/root-1280.png"; }
echo "LANDED:https://os.project-3.test/dashboard"
echo "QA COVERAGE: screens=1 flows=0 shots=1"
echo "QA: PASS"
exit 0
EOF
  chmod +x "$T/fakebin/node"
  printf '%s' "$T"
}

seed_build() { # seed_build <harness> <name> [pr-number]
  local T="$1" name="$2" pr="${3:-7}"
  local d="$T/builds/$name"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/$pr" > "$d/RESULT"
  printf '# plan\n\n## QA screens\n\n/clients\n' > "$d/plan.md"
  printf '%s' "$d"
}

run() { # run <harness> [env assignments...]
  local T="$1"; shift
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" GH_SINK="$T/gh.txt" NODE_SINK="$T/node.txt" \
      CURL_SINK="$T/curl.txt" \
      QA_REPO_DIR="$T/repo" "$@" "$T/bin/postmerge-qa.sh" project-3 2>&1
}
run_one() { # run_one <harness> <build-dir> [env assignments...] — the manual
            # re-run path the timeout alert tells an operator to use.
  local T="$1" BD="$2"; shift 2
  env -i ENDPOINT_CLERK="$ENDPOINT_CLERK" PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" \
      HARNESS="$T" FLEET_CONF="$T/fleet.conf" QA_ACCOUNTS="$T/state/qa-accounts.json" \
      CLERK_STATE_DIR="$T/clerk" GH_SINK="$T/gh.txt" NODE_SINK="$T/node.txt" \
      CURL_SINK="$T/curl.txt" \
      QA_REPO_DIR="$T/repo" "$@" "$T/bin/postmerge-qa.sh" project-3 "$BD" 2>&1
}

# A REAL git clone for the ancestry the deploy gate has to do: base -> M -> D on
# main, plus U on a side branch off base. M is the merge under test, D the sha a
# later merge put in production, U a commit that is NOT a descendant of M (a
# pinned or rolled-back domain). Built outside the `env -i` run so the commits
# get an identity without leaking one into the script's environment.
seed_repo() { # seed_repo <harness> -> prints "<M> <D> <U>"
  local T="$1" R="$1/repo" g
  g=(git -C "$R" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
  git init -q -b main "$R"
  echo base > "$R/f"; "${g[@]}" add f; "${g[@]}" commit -qm base
  echo m > "$R/f"; "${g[@]}" add f; "${g[@]}" commit -qm merge
  local M; M=$("${g[@]}" rev-parse HEAD)
  echo d > "$R/f"; "${g[@]}" add f; "${g[@]}" commit -qm descendant
  local D; D=$("${g[@]}" rev-parse HEAD)
  "${g[@]}" checkout -q -b side "$M~1"
  echo u > "$R/f"; "${g[@]}" add f; "${g[@]}" commit -qm unrelated
  local U; U=$("${g[@]}" rev-parse HEAD)
  "${g[@]}" checkout -q main
  printf '%s %s %s' "$M" "$D" "$U"
}
# grep -c PRINTS 0 and exits 1 on no match, so `|| echo 0` would append a second
# zero; the case that needs a default is a sink that was never written at all.
drives() { [ -f "$1/node.txt" ] || { echo 0; return 0; }; grep -c 'qa-drive.mjs' "$1/node.txt"; }
alerts() { [ -f "$1/logs/ALERTS.log" ] || { echo 0; return 0; }; grep -c 'POST-MERGE PROD QA NOT RUN' "$1/logs/ALERTS.log"; }
beats()  { [ -f "$1/beats.txt" ] || { echo 0; return 0; }; grep -c 'prodqa-deploy' "$1/beats.txt"; }

# ===========================================================================
# A. PAST THE LIMIT: terminal state, one alert, one beat, nothing driven
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-1-202609180000 >/dev/null
run "$T" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=pending >/dev/null
grep -q "project-3-TK-1-202609180000 deadbeef NOT_COVERED_DEPLOY_TIMEOUT" "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "A: a build 13 h past its merge with prod still not serving it must be marked NOT_COVERED_DEPLOY_TIMEOUT (done file: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
[ "$(alerts "$T")" = 1 ] && ok || bad "A: exactly one ALERTS line, got $(alerts "$T")"
grep -q "deadbeef" "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "A: the alert must name the sha"
grep -q 'https://github.com/example-org/project-3/pull/7' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "A: the alert must name the PR"
grep -q 'Needed: confirm deadbeef reached https://os.project-3.test' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "A: the alert must say what is needed and where"
grep -q 'has NOT been observed in production' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "A: the alert must say the shipped screen was never observed — this is not a defect claim"
[ "$(beats "$T")" = 1 ] && ok || bad "A: exactly one fleet_alert beat, got $(beats "$T")"
grep -q "prodqa-deploy:project-3:$SHA_A" "$T/beats.txt" 2>/dev/null \
  && ok || bad "A: the beat akey must be per (project, sha)"
grep -q 'fleet_alert' "$T/beats.txt" 2>/dev/null && ok || bad "A: the beat must be a fleet_alert"
[ "$(drives "$T")" = 0 ] && ok || bad "A: nothing may be driven for a build prod is not serving"
[ ! -f "$T/agent-calls.txt" ] && ok || bad "A: the age-out must add no agent spend"
grep -q 'NOT_COVERED_DEPLOY_TIMEOUT, not re-offered' "$T/logs/postmerge-qa.log" \
  && ok || bad "A: the run log must say the build is no longer offered"

# ===========================================================================
# B. THE SECOND TICK IS SILENT — the done row is the dedup
# ===========================================================================
run "$T" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=pending >/dev/null
[ "$(alerts "$T")" = 1 ] && ok || bad "B: a second tick must not re-alert, got $(alerts "$T")"
[ "$(beats "$T")" = 1 ] && ok || bad "B: a second tick must not re-beat, got $(beats "$T")"
[ "$(grep -c 'project-3-TK-1-202609180000' "$T/state/postmerge-qa-done.txt")" = 1 ] \
  && ok || bad "B: a second tick must not write a second done row"
[ "$(grep -c 'requeued' "$T/logs/postmerge-qa.log" 2>/dev/null || true)" = 0 ] \
  && ok || bad "B: a timed-out build must never be requeued again"
[ "$(drives "$T")" = 0 ] && ok || bad "B: a second tick must drive nothing"

# ===========================================================================
# C. UNDER THE LIMIT: today's behaviour, byte for byte
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-1-202609180000 >/dev/null
run "$T" MERGED_AT="$(ago_h 1)" DEPLOY_STATE=pending >/dev/null
grep -q "prod not yet serving deadbeef — requeued" "$T/logs/postmerge-qa.log" \
  && ok || bad "C: under the limit the requeue line must be unchanged (got: $(cat "$T/logs/postmerge-qa.log"))"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "C: under the limit the build stays eligible"
[ "$(alerts "$T")" = 0 ] && ok || bad "C: under the limit nothing alerts"
[ "$(beats "$T")" = 0 ] && ok || bad "C: under the limit nothing beats"

# ===========================================================================
# D. OLD BUT ACTUALLY SERVED: the deployed path is untouched
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" project-3-TK-2-202609180000)
run "$T" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=success >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "D: a served build must still be driven whatever its age"
grep -q ' PASS$' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "D: a served build's verdict must be its QA verdict"
grep -rq 'NOT_COVERED_DEPLOY_TIMEOUT' "$T/state" "$T/logs" 2>/dev/null \
  && bad "D: the age check must not reach a build that passed the gate" || ok
[ "$(alerts "$T")" = 0 ] && ok || bad "D: a served build must not alert about deploys"

# ===========================================================================
# E. KNOB 0 = OFF. A 30 h old undeployed build is still requeued forever.
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-3-202609180000 >/dev/null
run "$T" POSTMERGE_QA_DEPLOY_MAX_HOURS=0 MERGED_AT="$(ago_h 30)" DEPLOY_STATE=pending >/dev/null
grep -q 'requeued' "$T/logs/postmerge-qa.log" && ok || bad "E: with the knob at 0 the build must requeue"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "E: with the knob at 0 nothing is terminal"
[ "$(alerts "$T")" = 0 ] && ok || bad "E: with the knob at 0 nothing alerts"

# ===========================================================================
# F. A KNOB THAT IS NOT A NUMBER SAYS SO AND USES THE DEFAULT (12)
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-4-202609180000 >/dev/null
run "$T" POSTMERGE_QA_DEPLOY_MAX_HOURS=abc MERGED_AT="$(ago_h 13)" DEPLOY_STATE=pending >/dev/null
grep -q "POSTMERGE_QA_DEPLOY_MAX_HOURS='abc' is not a whole number" "$T/logs/postmerge-qa.log" \
  && ok || bad "F: a non-numeric knob must be said out loud (got: $(cat "$T/logs/postmerge-qa.log"))"
grep -q 'NOT_COVERED_DEPLOY_TIMEOUT' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "F: a non-numeric knob must fall back to 12, not to no limit"

# ===========================================================================
# G. ABSENT IS NOT OLD. No mergedAt = no clock = requeue, never terminal.
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-5-202609180000 >/dev/null
run "$T" MERGED_AT= DEPLOY_STATE=pending >/dev/null
grep -q 'prod not yet serving deadbeef — requeued' "$T/logs/postmerge-qa.log" \
  && ok || bad "G: with no mergedAt the build must requeue as before"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "G: an unknown merge time must never age anything out"
[ "$(alerts "$T")" = 0 ] && ok || bad "G: an unknown merge time must not alert"

# ...and neither does a mergedAt that is not a date.
T=$(new_harness); seed_build "$T" project-3-TK-5-202609180000 >/dev/null
run "$T" MERGED_AT=not-a-date DEPLOY_STATE=pending >/dev/null
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "G: an unparseable merge time must never age anything out"
[ "$(alerts "$T")" = 0 ] && ok || bad "G: an unparseable merge time must not alert"

# ===========================================================================
# H. "CANNOT TELL" NEVER AGES OUT. rc 2 means the SIGNAL was unreadable (curl
#    or `gh api` failed on this box), which is a per-box fact and not a per-build
#    one: gh auth expiring or the version host being unreachable from the hub for
#    twelve hours would otherwise write EVERY merged build of EVERY project
#    terminal in a single tick, and none of them would ever be driven once the
#    signal came back. Only rc 1 — read the signal, it is not this sha — ages.
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-6-202609180000 >/dev/null
run "$T" MERGED_AT="$(ago_h 13)" DEPLOY_API=down >/dev/null
[ ! -s "$T/state/postmerge-qa-done.txt" ] \
  && ok || bad "H: an unreadable deploy signal must never write a terminal row (done: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
grep -q 'cannot determine' "$T/logs/postmerge-qa.log" 2>/dev/null \
  && ok || bad "H: the run log must still say the signal could not be read (got: $(cat "$T/logs/postmerge-qa.log"))"
grep -q 'requeued' "$T/logs/postmerge-qa.log" 2>/dev/null \
  && ok || bad "H: an unreadable deploy signal must requeue, whatever the age"
[ "$(alerts "$T")" = 0 ] && ok || bad "H: an unreadable deploy signal must not alert per build, got $(alerts "$T")"
[ "$(beats "$T")" = 0 ] && ok || bad "H: an unreadable deploy signal must not beat per build, got $(beats "$T")"
[ "$(drives "$T")" = 0 ] && ok || bad "H: an unreadable deploy signal must still drive nothing"

# ===========================================================================
# I. A TIMED-OUT BUILD DOES NOT CONSUME THE POSTMERGE_QA_MAX SLOT
# ===========================================================================
T=$(new_harness)
seed_build "$T" project-3-TK-1-202609180000 7 >/dev/null
seed_build "$T" project-3-TK-2-202609180001 8 >/dev/null
run "$T" MERGED_AT="$(ago_h 13)" MERGED_AT_B="$(ago_h 1)" DEPLOY_STATE=pending >/dev/null
grep -q 'project-3-TK-1-202609180000 deadbeef NOT_COVERED_DEPLOY_TIMEOUT' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "I: the stale build must still age out"
[ "$(drives "$T")" = 1 ] \
  && ok || bad "I: the served build must still be driven in the same tick (drives=$(drives "$T"))"
grep -q 'project-3-TK-2-202609180001 feedface PASS' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "I: the served build must reach its own verdict (done file: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"

# ===========================================================================
# J. THE RECOVERY THE ALERT PRESCRIBES ACTUALLY WORKS. The ALERTS line tells an
#    operator to remove the done row and re-run the stage for that one build
#    once the sha is deployed. A prescription nobody executed is a guess.
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" project-3-TK-7-202609180000)
run "$T" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=pending >/dev/null
grep -q 'NOT_COVERED_DEPLOY_TIMEOUT' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "J: setup — the build must age out first"
# The re-run BEFORE the row is removed changes nothing: terminal means terminal.
run_one "$T" "$B" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=success >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "J: a hand re-run must not resurrect a build whose done row still stands"
# Now the documented two steps: drop the row, re-run for that build.
grep -v 'project-3-TK-7-202609180000' "$T/state/postmerge-qa-done.txt" > "$T/state/tmp" 2>/dev/null
mv "$T/state/tmp" "$T/state/postmerge-qa-done.txt"
run_one "$T" "$B" MERGED_AT="$(ago_h 13)" DEPLOY_STATE=success >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "J: after the documented recovery the build must be driven"
grep -q 'project-3-TK-7-202609180000 deadbeef PASS' "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "J: the recovered build must reach its real QA verdict (done: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"

# ===========================================================================
# K. THE KNOB IS DOCUMENTED WHERE AN OPERATOR SETS IT
# ===========================================================================
grep -q 'POSTMERGE_QA_DEPLOY_MAX_HOURS' "$DIR/env-templates/project.env.example" \
  && ok || bad "K: the knob must be documented in env-templates/project.env.example"

# ===========================================================================
# L. A SUPERSEDED MERGE IS A SERVED MERGE (the arm the age-out actually meets).
#    Four fleet projects carry VERSION_URL, and that endpoint reports the ONE
#    sha prod is serving now — the newest merge. A strict match on this merge's
#    sha therefore answers "not serving" forever for a merge that went live
#    minutes after it landed, which is what the audited feed was made of: every
#    sampled project-5 sha was an ancestor of the sha prod was serving. Serving
#    = this sha, or any DESCENDANT of it — the rule bin/deploy-train.sh uses.
# ===========================================================================
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-8-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 13)" \
    VERSION_URL=https://os.project-3.test/api/version VERSION_BODY="{\"sha\":\"$D_SHA\",\"ref\":\"main\"}" >/dev/null
[ "$(drives "$T")" = 1 ] \
  && ok || bad "L: a merge whose sha prod's live build DESCENDS from is live and must be driven (log: $(cat "$T/logs/postmerge-qa.log"))"
grep -rq 'NOT_COVERED_DEPLOY_TIMEOUT' "$T/state" 2>/dev/null \
  && bad "L: a live-but-superseded merge must never be written NOT_COVERED_DEPLOY_TIMEOUT" || ok
[ "$(alerts "$T")" = 0 ] && ok || bad "L: a live-but-superseded merge must not alert, got $(alerts "$T")"
[ "$(beats "$T")" = 0 ] && ok || bad "L: a live-but-superseded merge must not beat (alert-triage charges per beat family), got $(beats "$T")"

# ...and the exact sha is still the exact sha.
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-8-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 13)" \
    VERSION_URL=https://os.project-3.test/api/version VERSION_BODY="{\"sha\":\"$M_SHA\"}" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "L: the merge sha itself must still pass the gate"

# ...and a body that is not JSON keeps the substring answer it always had.
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-8-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 13)" \
    VERSION_URL=https://os.project-3.test/version.txt VERSION_BODY="build $M_SHA ok" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "L: a non-JSON version body naming the sha must still pass the gate"

# ===========================================================================
# M. AN UNRELATED LIVE SHA STILL AGES OUT. The backstop has to survive the fix:
#    a domain pinned to an old build, or rolled back, is a merge that genuinely
#    never reached production, and that is what the alert is for.
# ===========================================================================
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-9-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 13)" \
    VERSION_URL=https://os.project-3.test/api/version VERSION_BODY="{\"sha\":\"$U_SHA\"}" >/dev/null
grep -q "${M_SHA:0:8} NOT_COVERED_DEPLOY_TIMEOUT" "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "M: a merge prod's live sha does not descend from must still age out (done: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
[ "$(alerts "$T")" = 1 ] && ok || bad "M: the genuinely undeployed merge must still alert once, got $(alerts "$T")"
[ "$(drives "$T")" = 0 ] && ok || bad "M: nothing may be driven for a merge prod is not serving"

# ===========================================================================
# N. A LIVE SHA THE CLONE HAS NEVER SEEN IS "CANNOT TELL", NOT "NOT SERVING".
#    `git merge-base --is-ancestor` exits non-zero for an unknown object exactly
#    as it does for a real no — reading that as "no" is how a deployed merge
#    gets written off on a box whose clone is stale.
# ===========================================================================
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-10-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 13)" \
    VERSION_URL=https://os.project-3.test/api/version \
    VERSION_BODY='{"sha":"0123456789abcdef0123456789abcdef01234567"}' >/dev/null
[ ! -s "$T/state/postmerge-qa-done.txt" ] \
  && ok || bad "N: an unknown live sha must never write a terminal row (done: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
[ "$(alerts "$T")" = 0 ] && ok || bad "N: an unknown live sha must not alert, got $(alerts "$T")"
grep -q 'cannot determine' "$T/logs/postmerge-qa.log" \
  && ok || bad "N: an unknown live sha must be logged as cannot-determine (got: $(cat "$T/logs/postmerge-qa.log"))"

# ===========================================================================
# O. THE VERSION REQUEST CARRIES VERSION_AUTH. deploy-train.sh sends it; a gate
#    that does not gets a 401 body for a protected endpoint, which reads as
#    "not serving" for every merge on that project, forever.
# ===========================================================================
T=$(new_harness); read -r M_SHA D_SHA U_SHA <<<"$(seed_repo "$T")"
seed_build "$T" project-3-TK-11-202609180000 >/dev/null
run "$T" MERGE_SHA="$M_SHA" MERGED_AT="$(ago_h 1)" \
    VERSION_URL=https://os.project-3.test/api/version VERSION_AUTH='Authorization: Bearer tok_v' \
    VERSION_BODY="{\"sha\":\"$U_SHA\"}" >/dev/null
grep -q 'Authorization: Bearer tok_v' "$T/curl.txt" 2>/dev/null \
  && ok || bad "O: the version probe must send VERSION_AUTH (curl argv: $(grep 'api/version' "$T/curl.txt" 2>/dev/null))"

# ===========================================================================
# P. AN EMPTY mergeCommit.oid MUST NOT SHIFT THE FIELDS. `read` collapses runs
#    of separators (tab included, even when IFS is just tab), so a merged PR
#    with a null oid and a real mergedAt would otherwise land the TIMESTAMP in
#    the sha variable: past the `-n "$MSHA"` guard, probing prod for a date, and
#    requeueing forever with an age nobody can compute.
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-12-202609180000 >/dev/null
run "$T" MERGE_SHA= MERGED_AT="$(ago_h 13)" DEPLOY_STATE=pending >/dev/null
[ ! -s "$T/state/postmerge-qa-done.txt" ] \
  && ok || bad "P: a merged PR with no merge sha must be skipped, not terminal (done: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
[ "$(drives "$T")" = 0 ] && ok || bad "P: a merged PR with no merge sha must drive nothing"
grep -q 'serving 20[0-9][0-9]-' "$T/logs/postmerge-qa.log" 2>/dev/null \
  && bad "P: the merge timestamp must never be read as the merge sha (log: $(cat "$T/logs/postmerge-qa.log"))" || ok
[ "$(alerts "$T")" = 0 ] && ok || bad "P: a merged PR with no merge sha must not alert, got $(alerts "$T")"

# ===========================================================================
# Q1. POOL BUILDS (2026-10-20). A pool build dir is pool-<project>-<KEY>-<stamp>
#     (bin/fly-pool.sh). It must be collected, keyed on its own basename, and
#     its ticket key must drop the pool- prefix. Before the fix it was never
#     collected, so merged-ticket-advance skipped its ticket as no-audit.
# ===========================================================================
T=$(new_harness); B=$(seed_build "$T" pool-project-3-TK-9-202610040021)
run "$T" MERGED_AT="$(ago_h 1)" >/dev/null
[ "$(drives "$T")" = 1 ] && ok || bad "Q1: a merged, served pool build must be driven once, got $(drives "$T") (log: $(cat "$T/logs/postmerge-qa.log" 2>/dev/null))"
grep -q "pool-project-3-TK-9-202610040021 deadbeef PASS" "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "Q1: the done row must be keyed on the pool dir basename with PASS (done file: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"
head -1 "$B/qa-prod.md" 2>/dev/null | grep -qx '# Post-merge production QA — TK-9' \
  && ok || bad "Q1: the ticket key must strip the pool- prefix (report header: $(head -1 "$B/qa-prod.md" 2>/dev/null))"

# ===========================================================================
# Q2. Another project's pool dir is not collected
# ===========================================================================
T=$(new_harness); seed_build "$T" pool-other-app-TK-9-202610040021 >/dev/null
run "$T" MERGED_AT="$(ago_h 1)" >/dev/null
[ "$(drives "$T")" = 0 ] && ok || bad "Q2: another project's pool dir must not be driven, got $(drives "$T")"
[ ! -s "$T/state/postmerge-qa-done.txt" ] && ok || bad "Q2: another project's pool dir must not get a done row"

# ===========================================================================
# Q3. A plain build is still driven
# ===========================================================================
T=$(new_harness); seed_build "$T" project-3-TK-3-202610040021 >/dev/null
run "$T" MERGED_AT="$(ago_h 1)" >/dev/null
grep -q "project-3-TK-3-202610040021 deadbeef PASS" "$T/state/postmerge-qa-done.txt" 2>/dev/null \
  && ok || bad "Q3: a plain build must still be audited (done file: $(cat "$T/state/postmerge-qa-done.txt" 2>/dev/null))"

echo "postmerge-qa.bh-1022-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
