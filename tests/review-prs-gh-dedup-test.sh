#!/bin/bash
# BH-1017 — the paid-review dedup must survive a wiped ledger.
#
# bin/review-prs.sh buys one Fable session per unreviewed PR head and dedupes
# that spend on state/<project>.pr-reviews.json ALONE. BH-977 stopped the file
# lying about its own contents; it did nothing about the file being GONE. A
# reseeded (or restored-from-an-old-snapshot, or hand-deleted) ledger still
# reads as "nothing has ever been reviewed", so every open head is bought again
# — while GitHub is holding the review we already paid for, and the D1 jobs
# ledger is holding the verdict row, and neither was ever consulted.
# project-5 2026-09-18/19: 460 verdicts across 122 distinct PR+head pairs,
# #229 reviewed 52 times, USD 1.1K in two days.
#
# So the ledger file is a CACHE. The truth is GitHub (a review authored by a
# harness identity whose body carries `of <sha>` for the CURRENT head) and the
# D1 verdict row. This suite drives the REAL script with `gh`, `agent-call` and
# the jobs client stubbed, and counts the one thing that costs money: how many
# times agent-call.sh ran.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

REAL_JQ=$(command -v jq)
export REAL_JQ TEST_ROOT="$T"
STATE="$T/h/state/project-1.pr-reviews.json"
HEAD=head7aaaaaaa
OLDHEAD=old7bbbbbbb
# The receipt this lane posts on every review. Spelled here as a LITERAL on
# purpose: a suite that imported the script's own variable would still pass if
# the marker silently changed, and the marker is the whole dedup.
MARK='Automated harness review (Fable) of'

mkdir -p "$T/fakebin"

# One open, non-draft external PR. `gh api` answers two different questions:
# the CI run list (empty — the debounce only applies to a head that already has
# a verdict, and these cases start from a ledger with none) and this lane's own
# review list, which is what is under test. The review list is served as REAL
# JSON and the caller's own `-q` filter is applied with the real jq, exactly as
# gh does — a stub that printed the post-filter shape would prove the fixture
# parses, not the script.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '7\thead7aaaaaaa\texternaldev\tChange under review\n'
elif [ "${1:-}" = api ] && [[ "$*" == */pulls/*/reviews* ]]; then
  # BH-8419: the lane's own review is the App's (cromford[bot], type Bot).
  case "${GH_REVIEWS_MODE:-none}" in
    fail) echo "gh: Something went wrong (HTTP 502)" >&2; exit 1 ;;
    none) JSON='[]' ;;
    head) JSON='[{"user":{"login":"cromford[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","body":"Static review.\n\n1. A finding.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of head7aaaaaaa. Static review — no build run._"}]' ;;
    headapp) JSON='[{"user":{"login":"cromford[bot]"},"state":"CHANGES_REQUESTED","body":"Static review.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of head7aaaaaaa. Static review — no build run._"}]' ;;
    old)  JSON='[{"user":{"login":"cromford[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","body":"Static review.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n_Automated harness review (Fable) of old7bbbbbbb. Static review — no build run._"}]' ;;
    stranger) JSON='[{"user":{"login":"passing-contributor"},"state":"COMMENTED","body":"I ran the Automated harness review (Fable) of head7aaaaaaa myself, looks fine."}]' ;;
    noverdict) JSON='[{"user":{"login":"cromford[bot]","type":"Bot"},"state":"APPROVED","body":"Static review.\n\n---\n_Automated harness review (Fable) of head7aaaaaaa. Static review — no build run._"}]' ;;
    *) JSON='[]' ;;
  esac
  Q=""; prev=""
  for a in "$@"; do [ "$prev" = "-q" ] && Q="$a"; prev="$a"; done
  printf '%s' "$JSON" | "$REAL_JQ" -r "${Q:-.}"
elif [ "${1:-}" = api ]; then
  # The CI run list behind the re-review debounce. A head that already has a
  # record only reviews once its checks are green, so a case that needs to
  # reach the spend boundary with a PRIOR record on file has to say so.
  case "${GH_CI_MODE:-none}" in
    green) printf '{"s":"completed","c":"success","n":"Tests"}\n' ;;
    *) : ;;
  esac
elif [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf '%s\n' "$*" >> "$TEST_ROOT/merges.log"
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  # GH_DIFF_FAIL=1 is a transient read outage: the real gh exits non-zero and
  # the script's `>` has already truncated the diff file, so DIFF comes out
  # empty and the tick skips the PR having spent nothing.
  if [[ "$*" == *--name-only* ]]; then printf 'lib/pricing.ts\n'
  elif [ "${GH_DIFF_FAIL:-0}" = 1 ]; then echo "gh: HTTP 502" >&2; exit 1
  else printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  # merge_retry asks this one before it merges; OPEN CLEAN is the answer that
  # lets it through, which is what makes a stale verdict dangerous.
  if [[ "$*" == *"state,mergeStateStatus"* ]]; then printf 'OPEN CLEAN\n'
  else printf '\n'; fi
elif [ "${1:-}" = pr ] && { [ "${2:-}" = review ] || [ "${2:-}" = comment ]; }; then
  :
fi
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
# K3: the call-guard key the lane hands agent-call.sh, recorded per call.
printf '%s\n' "${AGENT_CALL_FP:-}" >> "$TEST_ROOT/agent-call-fps.log"
# AC_MODE=refused plays agent-call.sh's before-billing refusal (rc 74, the
# marker in $OUT): the call-guard saying this head already had its reviews.
if [ "${AC_MODE:-}" = refused ]; then
  printf 'AGENT_CALL_REFUSED call-guard repeat review paid=2/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"
  exit 74
fi
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

# A jobs client that answers the D1 verdict read. JOBS_VERDICT holds the TSV
# job_verdict prints (verdict, tier, provenance, merge_sha, job_id, reviewed_sha)
# and JOBS_RC its rc, so a case can drive "the ledger knows", "no row" (rc 2)
# and "outage" (rc 1) without a worker.
cat > "$T/jobs-client.sh" <<'STUB'
#!/bin/bash
# Mirrors bin/lib/jobs/req.sh: an UNSET JOBS_URL defaults to the fleet worker,
# and jobs_configured judges on JOBS_URL alone (BH-2315; BH-2457; BH-2492).
JOBS_URL="${JOBS_URL-https://harness-jobs.operator.workers.dev}"
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }
job_verdict() {
  printf '%s\n' "${JOBS_CALLS:-}" >> "$TEST_ROOT/jobs-calls.log"
  [ -n "${JOBS_VERDICT:-}" ] || return "${JOBS_RC:-2}"
  printf '%s' "$JOBS_VERDICT"
  return "${JOBS_RC:-0}"
}
STUB

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() { # fresh_harness [jobs]
  scratch_rm "$T/h" || return 1
  rm -f "$T/agent-calls.log" "$T/jobs-calls.log" "$T/merges.log" "$T/beats.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" project-1
  cp "$DIR/bin/lib/e2e-paths.sh" "$T/h/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  # beat.sh records its argv: a withheld APPROVE has to announce itself, and
  # "the beat fired" is the only way to tell that from silence.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$TEST_ROOT/beats.log"\nexit 0\n' > "$T/h/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/merge-queue.sh"
  chmod +x "$T/h/bin/beat.sh" "$T/h/bin/deploy-request.sh" "$T/h/bin/merge-queue.sh"
  [ "${1:-}" = jobs ] && cp "$T/jobs-client.sh" "$T/h/bin/jobs-client.sh"
  printf '{}\n' > "$STATE"
  return 0
}

GH_REVIEWS_MODE=none
GH_DIFF_FAIL=0
GH_CI_MODE=none
JOBS_VERDICT=""
JOBS_RC=2
RC=0

run_lane() { # run_lane [script] — sets RC
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" \
    GH_REVIEWS_MODE="$GH_REVIEWS_MODE" GH_DIFF_FAIL="$GH_DIFF_FAIL" \
    GH_CI_MODE="$GH_CI_MODE" JOBS_VERDICT="$JOBS_VERDICT" JOBS_RC="$JOBS_RC" \
    bash "${1:-$RP}" project-1 >/dev/null 2>&1
  RC=$?
}

calls() { if [ -f "$T/agent-calls.log" ]; then wc -l < "$T/agent-calls.log"; else echo 0; fi; }
merges() { if [ -f "$T/merges.log" ]; then wc -l < "$T/merges.log"; else echo 0; fi; }
beats() { if [ -f "$T/beats.log" ]; then wc -l < "$T/beats.log"; else echo 0; fi; }
alerts() { if [ -f "$T/h/logs/ALERTS.log" ]; then wc -l < "$T/h/logs/ALERTS.log"; else echo 0; fi; }
log_count() { local n; n=$(grep -c "$1" "$T/h/logs/pr-reviews.log" 2>/dev/null); echo "${n:-0}"; }
field() { "$REAL_JQ" -r --arg f "$1" '."7"[$f] // ""' "$STATE" 2>/dev/null; }

# A copy of the script with the dedup block removed, so the suite proves the
# guard is load-bearing rather than decorative.
mutant() { # mutant <dir>
  local d="$1"
  mkdir -p "$d/lib"
  cp "$DIR/bin/fleet-conf.sh" "$d/fleet-conf.sh"
  cp "$DIR/bin/lib/gh-pr-list.sh" "$d/lib/gh-pr-list.sh"
  # TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
  cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$d/lib/"
  awk '/^[[:space:]]*# >>> review-prs gh dedup/ {skip=1}
       skip==0 {print}
       /^[[:space:]]*# <<< review-prs gh dedup/ {skip=0}' "$RP" > "$d/review-prs.sh"
  chmod +x "$d/review-prs.sh"
}

# ── G1 (acceptance a) — wiped ledger, GitHub holds the review for THIS head ──
fresh_harness
GH_REVIEWS_MODE=head
run_lane
[ "$RC" -eq 0 ] && ok || bad "G1 exited $RC, expected 0"
[ "$(calls)" -eq 0 ] \
  && ok || bad "G1 re-bought a review GitHub already held: $(calls) agent-call(s), expected 0"
[ "$(field sha)" = "$HEAD" ] \
  && ok || bad "G1 did not rehydrate the ledger entry: $(cat "$STATE")"
[ "$(field verdict)" = REQUEST_CHANGES ] \
  && ok || bad "G1 rehydrated the wrong verdict: $(field verdict)"
[ "$(field tier)" = 2 ] && ok || bad "G1 rehydrated the wrong tier: $(field tier)"
[ "$(field rehydrated_from)" = github ] \
  && ok || bad "G1 did not record where the entry came from: $(cat "$STATE")"
[ "$(log_count 'rehydrated')" -ge 1 ] \
  && ok || bad "G1 rehydrated silently — no pr-reviews.log line"
[ "$(alerts)" -eq 0 ] && ok || bad "G1 alerted on a healthy rehydration: $(cat "$T/h/logs/ALERTS.log")"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "G1 tick 2 bought a review: $(calls), expected 0"

# ── G1b — the same, when the review was posted under the App identity ────────
fresh_harness
GH_REVIEWS_MODE=headapp
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G1b did not recognise an App-authored harness review: $(calls) call(s), expected 0"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G1b did not rehydrate: $(cat "$STATE")"

# ── G2 (acceptance b) — the review on file is for an OLDER head ──────────────
fresh_harness
GH_REVIEWS_MODE=old
run_lane
[ "$(calls)" -eq 1 ] \
  && ok || bad "G2 made $(calls) call(s) for a head nobody has reviewed, expected 1"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G2 did not record the new head: $(cat "$STATE")"
[ "$(field rehydrated_from)" = "" ] \
  && ok || bad "G2 claimed a rehydration it did not do: $(cat "$STATE")"

# ── G3 (acceptance c) — the GitHub read fails: fail OPEN, say so once ────────
fresh_harness
GH_REVIEWS_MODE=fail
run_lane
[ "$RC" -eq 0 ] && ok || bad "G3 exited $RC on a GitHub read failure, expected 0"
[ "$(calls)" -eq 1 ] \
  && ok || bad "G3 let a GitHub outage block the review: $(calls) call(s), expected 1"
[ "$(log_count 'could not read')" -eq 1 ] \
  && ok || bad "G3 wrote $(log_count 'could not read') fail-open log lines, expected exactly 1"
[ "$(alerts)" -eq 0 ] \
  && ok || bad "G3 paged for one GitHub read failure: $(cat "$T/h/logs/ALERTS.log")"

# ── G4 (acceptance d) — a 0-byte ledger behaves like G1 ──────────────────────
fresh_harness
: > "$STATE"
GH_REVIEWS_MODE=head
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G4 re-bought after a 0-byte ledger: $(calls) call(s), expected 0"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G4 did not rehydrate: $(cat "$STATE")"
# BH-977's own reseed line still fires, and only that one.
[ "$(alerts)" -eq 1 ] \
  && ok || bad "G4 wrote $(alerts) ALERTS line(s), expected 1 (the BH-977 reseed)"

# ── G5 — a stranger's comment carrying the marker is not our receipt ─────────
fresh_harness
GH_REVIEWS_MODE=stranger
run_lane
[ "$(calls)" -eq 1 ] \
  && ok || bad "G5 trusted a non-harness author's body as a paid review: $(calls) call(s), expected 1"

# ── G6 — an unparseable body is still proof we paid; the head goes terminal ──
fresh_harness
GH_REVIEWS_MODE=noverdict
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G6 re-bought a review whose body had no VERDICT line: $(calls), expected 0"
[ "$(field sha)" = "$HEAD" ] \
  && ok || bad "G6 left the head unrecorded, so the next tick re-buys: $(cat "$STATE")"
[ "$(field verdict)" = APPROVE ] \
  && ok || bad "G6 did not fall back to the review STATE for the verdict: $(field verdict)"

# ── G7 — the D1 verdict row answers, and carries real provenance ─────────────
fresh_harness jobs
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'APPROVE\t1\tclaude\t-\t4242\t%s' "$HEAD")
JOBS_RC=0
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G7 ignored a head-bound D1 verdict row: $(calls) call(s), expected 0"
[ "$(field rehydrated_from)" = jobs ] \
  && ok || bad "G7 did not record the jobs ledger as the source: $(cat "$STATE")"
[ "$(field served)" = claude ] \
  && ok || bad "G7 dropped the provenance the D1 row carries: $(field served)"
[ "$(field verdict)" = APPROVE ] && ok || bad "G7 verdict: $(field verdict)"

# ── G7b — a D1 row with NO provenance is not guessed as claude ───────────────
# Same rule as the GitHub rung: a verdict whose lane is unknown rehydrates as
# `rehydrated`, so merge_retry is not armed by a guess (review round 2 on #1048).
fresh_harness jobs
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'APPROVE\t1\t-\t-\t4242\t%s' "$HEAD")
JOBS_RC=0
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G7b re-bought a review the D1 row already answers: $(calls) call(s), expected 0"
[ "$(field served)" = rehydrated ] \
  && ok || bad "G7b GUESSED provenance for a D1 row that carries none: served=$(field served), expected rehydrated"
[ "$(field verdict)" = APPROVE ] && ok || bad "G7b verdict: $(field verdict)"
# ...and, exactly like the GitHub rung, it must SAY SO. `served:"rehydrated"`
# is the record merge_retry refuses on every later tick, so a rung that writes
# it without beating leaves an approved PR open with nothing pointing at it.
# The hub's own review of 5376a75e found this rung returning before the beat.
[ "$(beats)" -eq 1 ] \
  && ok || bad "G7b the D1 rung withheld an APPROVE silently — $(beats) beat(s), expected 1"
grep -q "provenance:project-1:7:$HEAD" "$T/beats.log" 2>/dev/null \
  && ok || bad "G7b D1 beat does not carry the live path's akey: $(cat "$T/beats.log" 2>/dev/null)"
grep -q 'fleet_alert' "$T/beats.log" 2>/dev/null \
  && ok || bad "G7b D1 beat is not a fleet_alert: $(cat "$T/beats.log" 2>/dev/null)"
# Once per HEAD, not once per tick: the ledger holds the record from here on,
# so later ticks dedupe before the rung and nothing re-announces.
run_lane
run_lane
[ "$(beats)" -eq 1 ] \
  && ok || bad "G7b re-announced across three ticks: $(beats) beat(s), expected 1"
[ "$(calls)" -eq 0 ] && ok || bad "G7b bought a review on a later tick: $(calls)"

# ── G7c — a D1 row that DOES carry provenance is not a withheld APPROVE ──────
# It rehydrates as `claude`, merge_retry is armed normally, and nothing is
# waiting on a person — so beating here would be crying wolf.
fresh_harness jobs
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'APPROVE\t1\tclaude\t-\t4242\t%s' "$HEAD")
JOBS_RC=0
run_lane
[ "$(field served)" = claude ] && ok || bad "G7c served: $(field served)"
[ "$(beats)" -eq 0 ] \
  && ok || bad "G7c beat fired for a verdict whose lane is known: $(cat "$T/beats.log")"

# ── G7d — a rehydrate keeps the CI-debounce bookkeeping it found ─────────────
# The rehydrate write used to be wholesale, so it dropped `deferred_sha`,
# `deferred_at` and `ci_alerted_sha` — harmless on a wiped ledger, but on a
# LIVE one it reset that PR's debounce clock and bought an extra pair of
# GitHub reads on the next head. It merges now; the judgement fields are still
# replaced, because a record being rehydrated may hold an older head's verdict.
fresh_harness
GH_REVIEWS_MODE=head
printf '%s\n' "{\"7\":{\"deferred_sha\":\"$OLDHEAD\",\"deferred_at\":1700000000,\"ci_alerted_sha\":\"$OLDHEAD\",\"verdict\":\"APPROVE\",\"served\":\"claude\",\"merge_retries\":3,\"merge_retry_sha\":\"$OLDHEAD\"}}" > "$STATE"
run_lane
[ "$(field deferred_sha)" = "$OLDHEAD" ] \
  && ok || bad "G7d rehydrate dropped deferred_sha: $(cat "$STATE")"
[ "$(field deferred_at)" = 1700000000 ] \
  && ok || bad "G7d rehydrate dropped deferred_at: $(cat "$STATE")"
[ "$(field ci_alerted_sha)" = "$OLDHEAD" ] \
  && ok || bad "G7d rehydrate dropped ci_alerted_sha: $(cat "$STATE")"
[ "$(field verdict)" = REQUEST_CHANGES ] \
  && ok || bad "G7d rehydrate kept the OLD head's verdict: $(cat "$STATE")"
[ "$(field served)" = rehydrated ] \
  && ok || bad "G7d rehydrate kept the OLD head's provenance: $(cat "$STATE")"
[ "$(field merge_retries)" = "" ] \
  && ok || bad "G7d rehydrate kept a stale merge counter: $(cat "$STATE")"
[ "$(field merge_retry_sha)" = "" ] \
  && ok || bad "G7d rehydrate kept a stale merge_retry_sha: $(cat "$STATE")"
GH_REVIEWS_MODE=none   # this case drove the GitHub rung; the next one must not inherit it

# ── G8 — a D1 row bound to an OLDER head is not an answer ────────────────────
fresh_harness jobs
JOBS_VERDICT=$(printf 'APPROVE\t1\tclaude\t-\t4242\t%s' "$OLDHEAD")
JOBS_RC=0
run_lane
[ "$(calls)" -eq 1 ] \
  && ok || bad "G8 deduped on a verdict bound to another head: $(calls) call(s), expected 1"

# ── G9 — a D1 outage falls through to GitHub rather than to a purchase ───────
fresh_harness jobs
JOBS_VERDICT=""
JOBS_RC=1
GH_REVIEWS_MODE=head
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G9 bought a review when D1 was down but GitHub held the answer: $(calls)"
[ "$(field rehydrated_from)" = github ] \
  && ok || bad "G9 source: $(cat "$STATE")"

# ── G10 — the in-flight marker: a crash mid-call re-buys once, then stops ────
# The ledger is seeded with what a killed tick leaves behind.
fresh_harness
GH_REVIEWS_MODE=none
JOBS_RC=2
printf '%s\n' "{\"7\":{\"reviewing_sha\":\"$HEAD\",\"reviewing_attempts\":1}}" > "$STATE"
run_lane
[ "$(calls)" -eq 1 ] \
  && ok || bad "G10 refused the one retry a crashed review is owed: $(calls) call(s), expected 1"

fresh_harness
printf '%s\n' "{\"7\":{\"reviewing_sha\":\"$HEAD\",\"reviewing_attempts\":2}}" > "$STATE"
run_lane
[ "$(calls)" -eq 0 ] \
  && ok || bad "G10 kept buying a head that died twice mid-review: $(calls) call(s), expected 0"
[ "$(field sha)" = "$HEAD" ] \
  && ok || bad "G10 wrote no terminal state, so the next tick re-buys: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] \
  && ok || bad "G10 wrote $(alerts) ALERTS line(s) for a head it gave up on, expected 1"

# ── G11 — a normal tick leaves an in-flight marker before it spends ──────────
# Proven through the mutant-free path: agent-call records the ledger it saw.
fresh_harness
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
cp "$HARNESS/state/project-1.pr-reviews.json" "$TEST_ROOT/ledger-at-call.json"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/h/bin/agent-call.sh"
run_lane
[ "$("$REAL_JQ" -r '."7".reviewing_sha // ""' "$T/ledger-at-call.json" 2>/dev/null)" = "$HEAD" ] \
  && ok || bad "G11 spent before persisting the in-flight marker: $(cat "$T/ledger-at-call.json" 2>/dev/null)"
[ "$(field reviewing_sha)" = "" ] \
  && ok || bad "G11 left the in-flight marker behind after finalizing: $(cat "$STATE")"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G11 did not finalize: $(cat "$STATE")"

# ── G12 — mutation: without the dedup block the wiped ledger re-buys ─────────
mutant "$T/mut"
fresh_harness
GH_REVIEWS_MODE=head
run_lane "$T/mut/review-prs.sh"
[ "$(calls)" -eq 1 ] \
  && ok || bad "G12 mutation: without the dedup block G1 should buy a review (got $(calls), expected 1)"

# ── G14 — a FROZEN head carries no verdict, so nothing merges it ─────────────
# The in-flight cap's terminal write used to be `(.[$n] // {}) + {sha:$s}`,
# which kept the PREVIOUS head's APPROVE and `served:claude` on the NEW sha.
# The next tick then read `DONE == SHA`, ran merge_retry, found APPROVE on a
# Claude lane and a PR that was OPEN CLEAN, and squash-merged a head no
# reviewer had ever read. The ledger below is exactly that: PR #7 approved at
# an old head, the author pushed a new one, and two ticks died mid-review.
fresh_harness
GH_REVIEWS_MODE=none
GH_CI_MODE=green
printf '%s\n' "{\"7\":{\"sha\":\"$OLDHEAD\",\"verdict\":\"APPROVE\",\"tier\":\"1\",\"served\":\"claude\",\"reviewing_sha\":\"$HEAD\",\"reviewing_attempts\":2}}" > "$STATE"
run_lane
[ "$(field sha)" = "$HEAD" ] && ok || bad "G14 did not freeze the new head: $(cat "$STATE")"
[ "$(field verdict)" = "" ] \
  && ok || bad "G14 carried the old head's verdict onto the frozen sha: $(cat "$STATE")"
[ "$(field served)" = "" ] \
  && ok || bad "G14 carried the old head's provenance onto the frozen sha: $(cat "$STATE")"
[ "$(field tier)" = "" ] && ok || bad "G14 carried a stale tier: $(cat "$STATE")"
[ "$(field reviewing_gave_up)" = true ] \
  && ok || bad "G14 did not mark the head given-up: $(cat "$STATE")"
run_lane
[ "$(merges)" -eq 0 ] \
  && ok || bad "G14 MERGED A HEAD NOBODY REVIEWED: $(cat "$T/merges.log")"
[ "$(calls)" -eq 0 ] && ok || bad "G14 bought a review for a frozen head: $(calls)"

GH_CI_MODE=none

# ── G15 — the same, through the pre-existing no-verdict cap ──────────────────
# Two empty reviews on one head freeze it too, and that write had the same
# shape. No `sha` in the seed, so the CI debounce is not in play and the review
# runs immediately; `noverdict` is already at 1, so this tick is the second.
fresh_harness
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
: > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/h/bin/agent-call.sh"
printf '%s\n' "{\"7\":{\"verdict\":\"APPROVE\",\"tier\":\"1\",\"served\":\"claude\",\"noverdict\":1,\"noverdict_sha\":\"$HEAD\"}}" > "$STATE"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "G15 setup: expected one no-verdict review, got $(calls)"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G15 no-verdict cap did not freeze: $(cat "$STATE")"
[ "$(field verdict)" = "" ] \
  && ok || bad "G15 no-verdict freeze kept a stale verdict: $(cat "$STATE")"
[ "$(field served)" = "" ] \
  && ok || bad "G15 no-verdict freeze kept a stale provenance: $(cat "$STATE")"
run_lane
[ "$(merges)" -eq 0 ] \
  && ok || bad "G15 MERGED A HEAD TWO REVIEWERS FAILED TO READ: $(cat "$T/merges.log")"

# ── G16 — a GitHub read outage must not spend the attempt budget ─────────────
# The in-flight marker charges a SESSION. `gh pr diff` failing is a free read
# failing: no session started, so nothing may be counted and nothing frozen.
# Two dead ticks then a healthy one must buy exactly one review.
fresh_harness
GH_REVIEWS_MODE=none
GH_DIFF_FAIL=1
run_lane
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "G16 bought a review with no diff: $(calls)"
[ "$(field reviewing_attempts)" = "" ] \
  && ok || bad "G16 charged the session budget for a failed free read: $(cat "$STATE")"
[ "$(field sha)" = "" ] \
  && ok || bad "G16 froze a head that was never reviewed: $(cat "$STATE")"
[ "$(alerts)" -eq 0 ] \
  && ok || bad "G16 paged about sessions it never bought: $(cat "$T/h/logs/ALERTS.log")"
GH_DIFF_FAIL=0
run_lane
[ "$(calls)" -eq 1 ] \
  && ok || bad "G16 did not review once GitHub recovered: $(calls) call(s), expected 1"
[ "$(field sha)" = "$HEAD" ] && ok || bad "G16 did not record the head: $(cat "$STATE")"

# ── G17 — a withheld rehydrated APPROVE announces itself ─────────────────────
# merge_retry returns silently on served:"rehydrated" every tick from here on,
# and no other lane lists an external author's PR — so the beat is the only
# thing between an approved PR and silence.
fresh_harness
GH_REVIEWS_MODE=noverdict   # body has no VERDICT line; review state is APPROVED
run_lane
[ "$(field verdict)" = APPROVE ] && ok || bad "G17 setup: $(cat "$STATE")"
[ "$(beats)" -ge 1 ] \
  && ok || bad "G17 withheld an APPROVE silently — no beat fired"
grep -q 'fleet_alert' "$T/beats.log" 2>/dev/null \
  && ok || bad "G17 beat is not a fleet_alert: $(cat "$T/beats.log" 2>/dev/null)"
grep -q "provenance:project-1:7:$HEAD" "$T/beats.log" 2>/dev/null \
  && ok || bad "G17 beat does not carry the live path's akey: $(cat "$T/beats.log" 2>/dev/null)"
[ "$(beats)" -eq 1 ] && ok || bad "G17 fired $(beats) beats on one tick, expected 1"
run_lane
run_lane
[ "$(beats)" -eq 1 ] \
  && ok || bad "G17 re-announced across three ticks: $(beats) beat(s), expected 1"
# A REQUEST_CHANGES rehydration is not news: nothing is waiting on a person.
fresh_harness
GH_REVIEWS_MODE=head
run_lane
[ "$(beats)" -eq 0 ] \
  && ok || bad "G17 beat fired for a rehydrated REQUEST_CHANGES: $(cat "$T/beats.log")"

# ── G13 — static pin: the marker is spelled once ─────────────────────────────
# The body writer and the body reader must share one string. Two copies is how
# a dedup comes to look for text nothing posts any more.
# ── G18 (K3) — the call-guard key, and a before-billing refusal ─────────────
# The lane names the work to bin/agent-call.sh's pre-call guard: this PR at this
# head. And when agent-call answers rc 74 (nothing called, nothing billed — the
# call-guard refusing a repeat of this head), the one-line marker is NOT a
# review: no no-verdict strike, no "NO VERDICT twice" page, and the in-flight
# charge is taken back, because that budget counts sessions.
fresh_harness
GH_REVIEWS_MODE=none
rm -f "$T/agent-call-fps.log"
run_lane
# TEST-CHANGE (BH-3940): the key is the shared per-head one, review:<slug>#<n>@<head>.
grep -q "^review:[^ ]*#7@$HEAD\$" "$T/agent-call-fps.log" 2>/dev/null \
  && ok || bad "G18a the lane did not hand agent-call its PR+head key: $(cat "$T/agent-call-fps.log" 2>/dev/null)"
fresh_harness
GH_REVIEWS_MODE=none
export AC_MODE=refused
run_lane
run_lane
run_lane
unset AC_MODE
[ "$(calls)" -eq 3 ] && ok || bad "G18b expected the lane to ask agent-call once per tick (3), got $(calls)"
[ "$(field noverdict)" = "" ] \
  && ok || bad "G18c a before-billing refusal was counted as a no-verdict review: $(cat "$STATE")"
[ "$(field reviewing_attempts)" = 0 ] \
  && ok || bad "G18d the in-flight charge was not taken back: reviewing_attempts=$(field reviewing_attempts)"
grep -q 'NO VERDICT\|started a review' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && bad "G18e a refusal paged as a dead review: $(cat "$T/h/logs/ALERTS.log")" || ok
[ "$(log_count 'returned before billing')" -ge 1 ] \
  && ok || bad "G18f the refusal left no pr-reviews.log line"

# ═══ BH-2315: the D1 verdict is read BEFORE any paid review; the file is a cache ═══
# The $328/day class: a ledger file that is gone, and a D1 ledger that either
# holds the answer in a word the lane did not recognise, or cannot be read and
# is "failed open" into a purchase. D1 is the truth; the file only caches it.
# A CONFIGURED jobs client is a non-empty JOBS_URL (every fleet box; BH-2457
# dropped the HARNESS_SECRET half); a box without one keeps the GitHub rung
# and today's fail-open (G3). "Without one" is an EMPTY JOBS_URL, req.sh's
# only "no worker here" answer: an UNSET one defaults to the fleet worker, in
# production and in the stub above, so it reads as configured (BH-2492).
d1_on()  { export JOBS_URL=https://jobs.example.test HARNESS_SECRET=FIXTURE-secret; }
d1_off() { export JOBS_URL=; unset HARNESS_SECRET; }
held_beats() { local n; n=$(grep -c 'review-d1-unreadable:project-1:' "$T/beats.log" 2>/dev/null); echo "${n:-0}"; }

# V1 — file absent, D1 holds the verdict for the LIVE head: 0 calls, replayed.
fresh_harness jobs; d1_on
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'APPROVE\t1\tclaude\t-\t4242\t%s' "$HEAD"); JOBS_RC=0
rm -f "$STATE"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "V1 file absent + D1 verdict for the live head bought a review: $(calls) call(s), expected 0"
[ "$(field verdict)" = APPROVE ] && [ "$(field rehydrated_from)" = jobs ] \
  && ok || bad "V1 the D1 verdict was not replayed into the cache: $(cat "$STATE" 2>/dev/null)"

# V2 — D1 records a REQUEST_CHANGES review as BLOCK (the verdict_single_home
# row's word): that is the same answer, replayed as REQUEST_CHANGES, 0 calls.
fresh_harness jobs; d1_on
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'BLOCK\t2\tclaude\t-\t4243\t%s' "$HEAD"); JOBS_RC=0
rm -f "$STATE"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "V2 a D1 BLOCK for the live head was not recognised: $(calls) call(s), expected 0"
[ "$(field verdict)" = REQUEST_CHANGES ] && ok || bad "V2 BLOCK must replay as REQUEST_CHANGES (got '$(field verdict)')"

# V3 — D1 UNREADABLE (configured client, worker down) and GitHub holds nothing:
# fail CLOSED — no paid call, the PR is held, ONE alert for the project.
fresh_harness jobs; d1_on
GH_REVIEWS_MODE=none
JOBS_VERDICT=""; JOBS_RC=1
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "V3 an unreadable D1 was failed OPEN into a purchase: $(calls) call(s), expected 0"
[ "$(log_count 'D1 verdict ledger could not be read')" -eq 1 ] && ok || bad "V3 the hold must be one pr-reviews.log line (got $(log_count 'D1 verdict ledger could not be read'))"
[ "$(held_beats)" -eq 1 ] && ok || bad "V3 exactly ONE alert for the held project (beats: $(cat "$T/beats.log" 2>/dev/null))"
[ "$(field sha)" = "" ] && ok || bad "V3 a held head must not be recorded as reviewed: $(cat "$STATE")"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "V3 tick 2 with D1 still down bought a review: $(calls)"
[ "$(grep 'review-d1-unreadable:project-1:' "$T/beats.log" | sed -E 's/.*"akey":"([^"]*)".*/\1/' | sort -u | wc -l | tr -d ' ')" = 1 ] \
  && ok || bad "V3 a second held tick must reuse the day's alert key (one announcement a day): $(cat "$T/beats.log")"
# D1 back: the head is reviewed exactly once.
JOBS_RC=2
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "V3 once D1 answers 'no row' the head is reviewed exactly once: $(calls) call(s)"

# V4 — D1 unreadable AND GitHub unreadable: still held, never paid.
fresh_harness jobs; d1_on
GH_REVIEWS_MODE=fail
JOBS_VERDICT=""; JOBS_RC=1
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "V4 both ledgers unreadable was failed open: $(calls) call(s), expected 0"

# V5 — a NEW head (D1's verdict is for the old one), file absent: exactly 1 call,
# and the next tick replays from the cache (and D1) — still 1.
fresh_harness jobs; d1_on
GH_REVIEWS_MODE=none
JOBS_VERDICT=$(printf 'APPROVE\t1\tclaude\t-\t4244\t%s' "$OLDHEAD"); JOBS_RC=0
rm -f "$STATE"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "V5 a new head must be reviewed exactly once: $(calls) call(s)"
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "V5 tick 2 on the same head bought again: $(calls) call(s), expected 1 total"

# V6 — no jobs client CONFIGURED (a worker-less box): D1 rc 1 is "not wired",
# not an outage — the GitHub rung and today's behaviour (a review is bought).
fresh_harness jobs; d1_off
GH_REVIEWS_MODE=none
JOBS_VERDICT=""; JOBS_RC=1
run_lane
[ "$(calls)" -eq 1 ] && ok || bad "V6 a box with no worker configured must keep today's fail-open: $(calls) call(s), expected 1"
[ "$(held_beats)" -eq 0 ] && ok || bad "V6 no D1 hold alert on a worker-less box: $(cat "$T/beats.log" 2>/dev/null)"
JOBS_VERDICT=""; JOBS_RC=2

[ "$(grep -cF "$MARK" "$RP")" -eq 1 ] \
  && ok || bad "bin/review-prs.sh spells the review marker $(grep -cF "$MARK" "$RP") times, expected 1"
grep -q 'gh api "repos/\$SLUG/pulls/\$NUM/reviews' "$RP" \
  && ok || bad "the dedup read must be REST (gh api .../pulls/<n>/reviews), never GraphQL"
# Scoped to the dedup block itself. The lane has a PRE-EXISTING GraphQL thread
# read (`gh pr view --json comments,reviews`) that feeds the review prompt and
# is none of this pin's business; a repo-wide grep either misses it or forbids
# it, and both readings are wrong. What must never go GraphQL is the read that
# decides whether to spend.
# Comment-only lines are dropped before the grep: the pin is about the code
# that runs, and a pin that trips on the word "gh pr" inside an explanation
# gets "fixed" by mangling the explanation.
awk '/^# >>> review-prs gh dedup \(/{f=1} f {print} /^# <<< review-prs gh dedup$/{exit}' \
  "$RP" | grep -v '^[[:space:]]*#' > "$T/dedup-block.sh"
[ -s "$T/dedup-block.sh" ] \
  && ok || bad "could not extract the dedup block — markers missing?"
grep -q 'gh api ' "$T/dedup-block.sh" \
  && ok || bad "the dedup block makes no REST call"
[ "$(grep -c 'gh pr ' "$T/dedup-block.sh")" -eq 0 ] \
  && ok || bad "the dedup block's CODE reaches GitHub through gh pr (GraphQL): $(grep 'gh pr ' "$T/dedup-block.sh")"

echo "review-prs-gh-dedup (BH-1017, BH-2315): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
