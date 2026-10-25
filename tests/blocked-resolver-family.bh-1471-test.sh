#!/bin/bash
# tests/blocked-resolver-family.bh-1471-test.sh — BH-1471: family-batched
# iron-law adjudication, bin/lib/br/opt/family.sh.
#
# WHAT IT PINS. One Fable ruling per (check, code shape) carries to every other
# parked PR whose flagged lines normalize to the same thing: five PRs from one
# family pay for one read instead of five. The thing that must never happen is
# the other direction — a carry onto a PR nobody ruled on — so most of this file
# is negatives, and each of them asserts the EXPENSIVE answer (the model was
# called) rather than merely the absence of a marker.
#
# HOW IT ASSERTS. Every case but case 1 drives the REAL bin/blocked-resolver.sh
# against a scratch $HARNESS (D2) and reads what the run DID: the
# ironlaw-head-accept rows (BH-4157) the sweep and the conductor look for, as
# claims the jobs stub records (a "marker" below is one such row), the
# state jsons, the store under state/blocked-resolver/.families/, the `EVENT
# family-carried` lines, the `tick:` line's counters, the recorded
# bin/agent-call.sh argv and the posted comment BODIES. Nothing greps the source
# of the module (D3).
#
# WHY A NEGATIVE TICK RULES `MAYBE`. A second PR that adjudicates ACCEPT writes
# its own ironlaw-head-accept row through the lane's normal arm, so "no marker"
# could not tell a carry from a ruling. ADJ_VERDICT=MAYBE is a session that came
# back with no word: the call is billed and counted, no marker is written by
# anybody, and nothing is stored — so a marker on that record could only have
# come from a carry, which is exactly the claim.
#
# Run from anywhere: tests/blocked-resolver-family.bh-1471-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v sha1sum >/dev/null || { echo "sha1sum missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# THE MODULE UNDER TEST travels explicitly: br_modules_install copies
# bin/lib/br/*.sh and never the opt/ subdirectory, which is deliberate —
# tests/blocked-resolver-opt-hooks.bh-1468-test.sh case 1 asserts that a fixture
# has NO bin/lib/br/opt/ at all, and a ratchet that installed one would break it.
mkdir -p "$H/bin/lib/br/opt"
cp "$DIR/bin/lib/br/opt/family.sh" "$H/bin/lib/br/opt/family.sh"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# The carry writes the ironlaw-head-accept row through ila_put (BH-7804).
( cd "$DIR" && scratch_install_closure bin/lib/ironlaw-carry.sh "$H" >/dev/null ) || exit 1
chmod +x "$H/bin/"*.sh
{ for I in 1 2; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$I" "$I" "$I" "$I"; done; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1 p2
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
: > "$T/agent.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

# THE PR STUB. Per-PR head shas and per-PR diffs, because this whole slice is
# about telling two PRs apart by what their diffs say: a fixture with one shared
# head would make every marker name identical and every shape the same.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    if [ -f "$T/nohead-\$N" ]; then : > "$T/prhead"
    else printf 'eadbeef%033d' "\$N" > "$T/prhead"; fi
    [ -f "$T/prdiff-\$N" ] && cp "$T/prdiff-\$N" "$T/prdiff"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"
: > "$T/comment-bodies.txt"; : > "$T/ssh.txt"; : > "$T/run.log"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""

JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
# The ironlaw-head-accept write (ila_put): one "<kind> <key>" line per claim,
# rc 1 (an outage) while \$T/claim-down exists.
job_ledger_claim() { [ -f "$T/claim-down" ] && return 1; printf '%s %s\n' "\$1" "\$2" >> "$T/claims.txt"; return 0; }
EOF
}
for I in 1 2; do touch "$H/flags/fly-pool-p$I"; done
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
FAM="$ST/.families"
BRENV=()
RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || RC=$?; }
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
STATEJSON() { cat "$ST/$1/$2.json" 2>/dev/null; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
# NFAM — how many rows the family store holds. A dotfile directory, so the glob
# that would find it has to name the dot (A5, and case 2f is the other half).
NFAM() { find "$FAM" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
FAMFILE() { find "$FAM" -maxdepth 1 -name '*.json' 2>/dev/null | head -1; }
FAMQ() { jq -r "$1" "$(FAMFILE)" 2>/dev/null; }
# FAMEDIT <jq args…> <filter> — rewrite the single store row in place. The path
# is guarded because it must be: `jq … > "$(FAMFILE).edit"` with no row on disk
# writes `.edit` into the CHECKOUT, which is the whole reason tests/lib/scratch.sh
# exists.
FAMEDIT() {
  local f; f=$(FAMFILE)
  [ -n "$f" ] || { bad "FAMEDIT: there is no store row to edit"; return 1; }
  jq -c "$@" "$f" > "$f.edit" && mv "$f.edit" "$f"
}
NTMP() { find "$FAM" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
# A head is 40 lower-case hex: ila_key refuses anything else (BH-7804).
PRHEAD() { printf 'eadbeef%033d' "$1"; }
# NMARK <pr> — the ironlaw-head-accept rows written for THAT PR (BH-7804: the
# row replaced the iron-law-accepted-<sha> file). NMARKALL — all of them.
NMARK() { grep -c "^ironlaw-head-accept o/p1#$1@" "$T/claims.txt" 2>/dev/null; }
NMARKALL() { grep -c '^ironlaw-head-accept ' "$T/claims.txt" 2>/dev/null; }
# CARRIED — the carry comment bodies, one per line (the body is a single line).
CARRIED() { grep -c 'We ruled on this exact shape already' "$T/comment-bodies.txt" 2>/dev/null; }

# RECMK <pr> [check-slug] — the build record mc_record_for finds for that PR, so
# the ACCEPT arm and the carry both have somewhere real to write their marker.
RECMK() {
  mkdir -p "$H/builds/p1-TK-$1-1"
  printf 'PR_CREATED https://github.com/o/p1/pull/%s (harness build)\n' "$1" \
    > "$H/builds/p1-TK-$1-1/RESULT"
  if [ -n "${2:-}" ]; then
    printf 'CHECK-HIT %s src/agent.ts:3 flagged added line\n' "$2" \
      > "$H/builds/p1-TK-$1-1/checks.txt"
  else
    rm -f "$H/builds/p1-TK-$1-1/checks.txt"
  fi
  return 0
}
# PRDIFF <pr> — the unified diff that PR's REST diff read answers with.
PRDIFF() { cat > "$T/prdiff-$1"; }

CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          rm -f "$H/flags/blocked-resolver-observe"
          RESET; rm -f "$T"/st-* "$T"/nohead-*; }
# RESET — between two ticks of ONE case. Everything but $ST, because the family
# store IS what the second tick is about.
RESET() { : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"; : > "$T/comments.txt"
          : > "$T/comment-bodies.txt"; : > "$T/claims.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(date -u -d "@$((NOW - 604800))" '+%Y-%m-%dT%H:%M:%SZ')" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in $(seq 1 90); do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

IRONLAW="iron-law: hardcoded model string in src/agent.ts"
MODEL='claude-'"opus-5"   # split so this fixture is not itself an iron-law hit

# The base family: one flagged added line plus an unflagged neighbour.
FAM_A() { printf '+++ b/src/agent.ts\n+  const model = "%s";\n+  return call(model);\n' "$MODEL"; }
# The same code, re-indented — normalization strips leading/trailing whitespace,
# so this is the SAME family (the one positive among the negatives).
FAM_AW() { printf '+++ b/src/agent.ts\n+\t\t  const model = "%s";   \n+  return call(model);\n' "$MODEL"; }
# One renamed identifier — a DIFFERENT family.
FAM_B() { printf '+++ b/src/agent.ts\n+  const llm = "%s";\n+  return call(llm);\n' "$MODEL"; }

# ============================================================================
# 1. br_family_key — the fingerprint. The ONE case that sources the module
#    rather than driving the lane: this is a pure function of (reason, record,
#    diff) and the lane can only show it through six other moving parts.
# ============================================================================
say() { :; }
br_slug_of_url() { case "${1:-}" in https://github.com/*/*/pull/*) printf 'o/p1' ;; *) return 1 ;; esac; }
mc_num_of_url()  { grep -oE '[0-9]+$' <<<"${1:-}"; }
# The diff read br_family_key makes, answered from a file per PR number. No file
# is an UNREADABLE diff (rc 75), which is the gh-rest contract's own word for it.
gh_rest() { local n="${2##*/}"; [ -s "$T/kd-$n" ] || return 75; cat "$T/kd-$n"; }
# shellcheck source=bin/lib/br/opt/family.sh
. "$DIR/bin/lib/br/opt/family.sh" || { echo "FAIL: 1: the module must source"; exit 1; }

mkdir -p "$T/r1" "$T/r2" "$T/r3" "$T/r4"
FAM_A  > "$T/kd-1"
FAM_AW > "$T/kd-2"
FAM_B  > "$T/kd-3"
FAM_A  > "$T/kd-5"
printf 'CHECK-HIT sql-command-injection src/agent.ts:3 templated query\n' > "$T/r3/checks.txt"
printf 'DELETED_CASES:\n  beta case\n  alpha case\nOTHER:\n' > "$T/r1/test-tamper.txt"
printf 'DELETED_CASES:\n  alpha case\n  beta case\nOTHER:\n' > "$T/r2/test-tamper.txt"

K1=$(br_family_key iron-law "$T/r1" "https://github.com/o/p1/pull/1")
K2=$(br_family_key iron-law "$T/r2" "https://github.com/o/p1/pull/2")
K3=$(br_family_key iron-law "$T/r4" "https://github.com/o/p1/pull/3")
K4=$(br_family_key iron-law "$T/r4" "https://github.com/o/p1/pull/4")
K5=$(br_family_key iron-law "$T/r3" "https://github.com/o/p1/pull/5")
K6=$(br_family_key test-tamper "$T/r1" -)
K7=$(br_family_key test-tamper "$T/r2" -)
K8=$(br_family_key rebase-gate-red "$T/r1" "https://github.com/o/p1/pull/1")

[ -n "$K1" ] && [ "$K1" = "$K2" ] && ok \
  || bad "1a: an indentation-only difference is the SAME family ($K1 vs $K2)"
[ -n "$K3" ] && [ "$K3" != "$K1" ] && ok \
  || bad "1b: a renamed identifier is a DIFFERENT family ($K1 vs $K3)"
[ -z "$K4" ] && ok || bad "1c: an unreadable diff has no family (got '$K4')"
[ "${K5%%:*}" = "sql-command-injection" ] && ok \
  || bad "1d: the checks.txt slug scopes the key (got '$K5')"
[ "${K1%%:*}" = ironlaw ] && ok || bad "1e: no checks.txt is the literal ironlaw slug (got '$K1')"
[ "${K5##*:}" = "${K1##*:}" ] && ok \
  || bad "1d2: the same lines under a different check share the SHAPE and not the key ($K5 vs $K1)"
[ "$K5" != "$K1" ] && ok || bad "1d3: and the keys must differ ($K5 vs $K1)"
[ -n "$K6" ] && [ "$K6" = "$K7" ] && ok \
  || bad "1f: DELETED_CASES in two orders is one family ($K6 vs $K7)"
[ "${K6%%:*}" = test-tamper ] && ok || bad "1f2: and its slug is test-tamper (got '$K6')"
[ "$K6" != "$K1" ] && [ "$K6" != "$K5" ] && ok \
  || bad "1f3: a tamper family is never an iron-law family ($K6 / $K1 / $K5)"
[ "$(printf '%s' "${K1##*:}" | wc -c | tr -d ' ')" = 12 ] && ok \
  || bad "1g: the shape is 12 hex (got '${K1##*:}')"
[ -z "$K8" ] && ok || bad "1h: a reason with no family rule answers empty (got '$K8')"

unset -f say br_slug_of_url mc_num_of_url gh_rest

# ============================================================================
# 2. THE STORE. Three PRs of one family across two ticks: the first buys the
#    ruling, the other two carry it. One file, one key, uses climbing.
# ============================================================================
CLEAN
for N in 31 32 33 34; do RECMK "$N"; FAM_A | PRDIFF "$N"; done
ROWADD "o/p1#31" "$((NOW - 300))" "$IRONLAW" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$((NOW - 200))" "$IRONLAW" "https://github.com/o/p1/pull/32"
BRENV=(BR_PER_TICK=2 ADJ_VERDICT=ACCEPT)
RUN
BRENV=()
[ "$RC" = 0 ] && ok || bad "2: the tick must exit 0 (rc $RC)"
[ "$(NFAM)" = 1 ] && ok || bad "2a: exactly one row per family (got $(NFAM): $(find "$FAM" 2>/dev/null))"
MISS=""
for F in key slug shape verdict ruled_at ruled_by uses; do
  [ "$(FAMQ "has(\"$F\")")" = true ] || MISS="$MISS $F"
done
[ -z "$MISS" ] && ok || bad "2a2: the row carries every declared field, missing:$MISS ($(FAMQ .))"
[ "$(FAMQ .verdict)" = ACCEPT ] && ok || bad "2a3: verdict=ACCEPT (got $(FAMQ .verdict))"
[ "$(FAMQ .slug)" = ironlaw ] && ok || bad "2a4: slug=ironlaw (got $(FAMQ .slug))"
[ "$(basename "$(FAMFILE)")" = "$(FAMQ .key).json" ] && ok \
  || bad "2a5: the file NAME is the key ($(basename "$(FAMFILE)") vs $(FAMQ .key))"
[ "$(FAMQ .uses)" = 1 ] && ok || bad "2: one carry in the first tick (uses=$(FAMQ .uses))"
[ "$(NAGENT)" = 1 ] && ok || bad "2: and exactly one model call (agent: $(cat "$T/agent.txt"))"
[ "$(NTMP)" = 0 ] && ok || bad "2c: tmp+mv leaves no partial file ($(find "$FAM"))"
[ "$(NMARK 32)" = 1 ] && ok || bad "2: the carried PR got its marker (got $(NMARK 32))"
grep -qx "ironlaw-head-accept o/p1#32@$(PRHEAD 32)" "$T/claims.txt" && ok \
  || bad "2: bound to THAT PR's head ($(grep 'o/p1#32@' "$T/claims.txt"))"

# 2b. A SECOND TICK, a third PR, a different record path and a different PR
#     number — and still ONE row. The key is the fingerprint, not the url.
KEY1=$(FAMQ .key)
RESET
ROWADD "o/p1#33" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/33"
RUN
[ "$(NFAM)" = 1 ] && ok || bad "2b: still one row for one family (got $(NFAM))"
[ "$(FAMQ .key)" = "$KEY1" ] && ok || bad "2b2: and the same key ($(FAMQ .key) vs $KEY1)"
[ "$(FAMQ .uses)" = 2 ] && ok || bad "2e: uses=2 after the second carry (got $(FAMQ .uses))"
[ "$(NAGENT)" = 0 ] && ok || bad "2b3: the second tick bought nothing (agent: $(cat "$T/agent.txt"))"
[ "$(NMARK 33)" = 1 ] && ok || bad "2b4: and PR 33 is unparked (got $(NMARK 33))"
[ "$(LFIELD families)" = 1 ] && ok || bad "2b5: families=1 (tick: $(LASTTICK))"
[ "$(LFIELD candidates)" = 1 ] && ok \
  || bad "2f: the store is never read as a project (tick: $(LASTTICK))"
[ "$(FAMQ .ruled_by)" = "p1/o-p1-31 https://github.com/o/p1/pull/31" ] && ok \
  || bad "2: ruled_by names the project, the row and the PR (got $(FAMQ .ruled_by))"

# 2d. OUT OF TTL. The same family, a ruled_at older than BR_FAMILY_TTL_SECS:
#     no carry, the PR buys its own ruling, and the file is NOT deleted.
FAMEDIT --argjson at "$((NOW - 600))" '.ruled_at = $at'
RESET
ROWADD "o/p1#34" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/34"
BRENV=(BR_FAMILY_TTL_SECS=60 ADJ_VERDICT=ACCEPT)
RUN
BRENV=()
[ "$(NLINES 'EVENT family-carried')" = 0 ] && ok \
  || bad "2d: an out-of-TTL ruling must not carry (log: $(LOG | grep family | head -3))"
[ "$(NAGENT)" = 1 ] && ok || bad "2d2: so the PR buys its own ruling (agent: $(cat "$T/agent.txt"))"
[ "$(NFAM)" = 1 ] && [ -s "$(FAMFILE)" ] && ok || bad "2d3: and the row is NOT deleted (got $(NFAM))"
[ "$(FAMQ .ruled_at)" = "$((NOW - 600))" ] && ok \
  || bad "2d4: an existing row is never overwritten, so the TTL cannot be refreshed (got $(FAMQ .ruled_at))"
[ "$(FAMQ .uses)" = 2 ] && ok || bad "2d5: and uses is unbumped (got $(FAMQ .uses))"

# ============================================================================
# 3. FIVE PARKS, ONE FAMILY, ONE CALL. The whole point of the slice.
# ============================================================================
CLEAN
for N in 41 42 43 44 45; do RECMK "$N"; FAM_A | PRDIFF "$N"; done
ROWADD "o/p1#41" "$((NOW - 500))" "$IRONLAW" "https://github.com/o/p1/pull/41"
ROWADD "o/p1#42" "$((NOW - 400))" "$IRONLAW" "https://github.com/o/p1/pull/42"
ROWADD "o/p1#43" "$((NOW - 300))" "$IRONLAW" "https://github.com/o/p1/pull/43"
ROWADD "o/p1#44" "$((NOW - 200))" "$IRONLAW" "https://github.com/o/p1/pull/44"
ROWADD "o/p1#45" "$((NOW - 100))" "$IRONLAW" "https://github.com/o/p1/pull/45"
BRENV=(BR_PER_TICK=5 ADJ_VERDICT=ACCEPT)
RUN
BRENV=()
[ "$(NAGENT)" = 1 ] && ok || bad "3a: five parks, ONE model call (agent: $(cat "$T/agent.txt"))"
[ "$(NMARKALL)" = 5 ] && ok || bad "3b: five markers, one per record (got $(NMARKALL))"
MISS=""
for N in 41 42 43 44 45; do
  grep -qx "ironlaw-head-accept o/p1#$N@$(PRHEAD "$N")" "$T/claims.txt" || MISS="$MISS $N"
done
[ -z "$MISS" ] && ok || bad "3b2: each marker is named for THAT PR's head, missing:$MISS"
[ "$(LFIELD families)" = 4 ] && ok || bad "3c: families=4 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok || bad "3c2: llm_rungs=1 (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT family-carried')" = 4 ] && ok \
  || bad "3d: four family-carried events (got $(NLINES 'EVENT family-carried'))"
ADJF=0; ADJN=0
for N in 42 43 44 45; do
  [ "$(STATEJSON p1 "o-p1-$N" | jq -r '[.attempts[]|select(.action=="adjudicate-family")]|length')" = 1 ] \
    && ADJF=$((ADJF+1))
  [ "$(STATEJSON p1 "o-p1-$N" | jq -r '.adjudications // 0')" = 0 ] && ADJN=$((ADJN+1))
done
[ "$ADJF" = 4 ] && ok || bad "3d2: four adjudicate-family attempts (got $ADJF)"
[ "$ADJN" = 4 ] && ok || bad "3d3: and no adjudication counter is spent (got $ADJN of 4)"
[ "$(CARRIED)" = 4 ] && ok || bad "3e: four carry comments (bodies: $(cat "$T/comment-bodies.txt"))"
[ "$(grep -c 'We ruled on this exact shape already, on https://github.com/o/p1/pull/41\.' "$T/comment-bodies.txt")" = 4 ] && ok \
  || bad "3e2: each names the PR the ruling came from (bodies: $(cat "$T/comment-bodies.txt"))"
grep -qE '—|reviewed|_Adjudication by' <<<"$(grep 'We ruled on this exact shape' "$T/comment-bodies.txt")" \
  && bad "3e3: the carry comment is human-voiced and claims no review ($(grep 'We ruled' "$T/comment-bodies.txt" | head -1))" || ok

# 3f. THE COMMENT FAILS TO POST. The marker STANDS — a failed comment must never
#     retract a marker that has already unparked a judged sha.
RESET
RECMK 46; FAM_A | PRDIFF 46
echo 500 > "$T/st-comment"
ROWADD "o/p1#46" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/46"
RUN
rm -f "$T/st-comment"
[ "$(NMARK 46)" = 1 ] && ok || bad "3f: the marker stands when the comment fails (got $(NMARK 46))"
[ "$(NLINES 'the comment did not post')" = 1 ] && ok \
  || bad "3f2: and exactly one line says so (got $(NLINES 'the comment did not post'))"

# 3g. A STORED ROW WITH NO URL posts nothing (D26) and still carries.
RESET
RECMK 47; FAM_A | PRDIFF 47
FAMEDIT '.ruled_by = "p1/o-p1-41 -"'
ROWADD "o/p1#47" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/47"
RUN
[ "$(NMARK 47)" = 1 ] && ok || bad "3g: a url-less ruling still carries (got $(NMARK 47))"
[ "$(CARRIED)" = 0 ] && ok || bad "3g2: and posts no comment (bodies: $(cat "$T/comment-bodies.txt"))"
[ "$(NLINES 'names no PR url')" = 1 ] && ok \
  || bad "3g3: one line says why (got $(NLINES 'names no PR url'))"

# ============================================================================
# 4. THE NEGATIVES. A carried ACCEPT unparks a PR for the merge sweep, so each
#    of these must buy its own ruling instead.
#
#    NEG/POS drive two ticks: PR <a> rules ACCEPT and stores the family, then PR
#    <b> is parked. The second tick rules MAYBE (no verdict), so the ONLY thing
#    that could write a marker on <b>'s record is a carry.
# ============================================================================
NEG() { # NEG <label> <a> <b>
  local label="$1" a="$2" b="$3"
  RESET
  ROWADD "o/p1#$a" "$((NOW - 100))" "$IRONLAW" "https://github.com/o/p1/pull/$a"
  BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
  [ "$(NFAM)" -ge 1 ] || bad "4 ($label): the seeding tick must store a ruling (log: $(LOG | tail -3))"
  RESET
  ROWADD "o/p1#$b" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/$b"
  BRENV=(ADJ_VERDICT=MAYBE); RUN; BRENV=()
  [ "$(NMARK "$b")" = 0 ] && [ "$(NLINES 'EVENT family-carried')" = 0 ] && [ "$(NAGENT)" = 1 ] && ok \
    || bad "4 ($label): #$b must buy its own ruling — markers=$(NMARK "$b") carried=$(NLINES 'EVENT family-carried') agent=$(NAGENT)"
}
POS() { # POS <label> <a> <b> — the wanted positive, same shape of drive.
  local label="$1" a="$2" b="$3"
  RESET
  ROWADD "o/p1#$a" "$((NOW - 100))" "$IRONLAW" "https://github.com/o/p1/pull/$a"
  BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
  RESET
  ROWADD "o/p1#$b" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/$b"
  BRENV=(ADJ_VERDICT=MAYBE); RUN; BRENV=()
  [ "$(NMARK "$b")" = 1 ] && [ "$(NLINES 'EVENT family-carried')" = 1 ] && [ "$(NAGENT)" = 0 ] && ok \
    || bad "4 ($label): #$b must carry — markers=$(NMARK "$b") carried=$(NLINES 'EVENT family-carried') agent=$(NAGENT)"
}

# N1. Same check slug, different lines.
CLEAN
RECMK 51 sql-command-injection; RECMK 52 sql-command-injection
printf '+++ b/src/db.ts\n+  return db.query(`select * from m where id = "%s"`);\n' "$MODEL" | PRDIFF 51
printf '+++ b/src/db.ts\n+  return exec(`select * from m where id = "%s"`);\n' "$MODEL" | PRDIFF 52
NEG "n1 same slug, different lines" 51 52

# N2. Same lines, different check.
CLEAN
RECMK 53 secret-literals; RECMK 54 client-id-trust
FAM_A | PRDIFF 53; FAM_A | PRDIFF 54
NEG "n2 same lines, different check" 53 54

# N3. The ticket's own false positive, inverted: a model slug as a VALUE in a
#     catalog must not carry to the same slug as a hardcoded literal in an
#     agent's model: argument.
CLEAN
RECMK 55; RECMK 56
printf '+++ b/catalog/models.json\n+    "default": "%s",\n' "$MODEL" | PRDIFF 55
printf '+++ b/src/agent.ts\n+  await call({ model: "%s" });\n' "$MODEL" | PRDIFF 56
NEG "n3 catalog value vs hardcoded literal" 55 56

# N4a. The positive control: whitespace only DOES carry.
CLEAN
RECMK 57; RECMK 58
FAM_A | PRDIFF 57; FAM_AW | PRDIFF 58
POS "n4 whitespace-only carries" 57 58

# N4b. One renamed identifier does NOT.
CLEAN
RECMK 59; RECMK 60
FAM_A | PRDIFF 59; FAM_B | PRDIFF 60
NEG "n4 a renamed identifier does not carry" 59 60

# N5. A REJECT is never stored, so the family has no file at all.
CLEAN
RECMK 61; RECMK 62
FAM_A | PRDIFF 61; FAM_A | PRDIFF 62
RESET
ROWADD "o/p1#61" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/61"
BRENV=(ADJ_VERDICT=REJECT); RUN; BRENV=()
[ "$(NFAM)" = 0 ] && ok || bad "4 (n5): a REJECT is never stored (got $(NFAM): $(find "$FAM" 2>/dev/null))"
RESET
ROWADD "o/p1#62" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/62"
BRENV=(ADJ_VERDICT=MAYBE); RUN; BRENV=()
[ "$(NMARK 62)" = 0 ] && [ "$(NAGENT)" = 1 ] && ok \
  || bad "4 (n5b): and never carried — markers=$(NMARK 62) agent=$(NAGENT)"

# N7. An unreadable diff has no family, in the lane and not only in case 1.
CLEAN
RECMK 63; RECMK 64
FAM_A | PRDIFF 63; FAM_A | PRDIFF 64
RESET
ROWADD "o/p1#63" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/63"
BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
RESET
echo 500 > "$T/st-diff"
ROWADD "o/p1#64" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/64"
BRENV=(ADJ_VERDICT=MAYBE); RUN; BRENV=()
rm -f "$T/st-diff"
[ "$(NMARK 64)" = 0 ] && [ "$(NLINES 'EVENT family-carried')" = 0 ] && ok \
  || bad "4 (n7): an unreadable diff matches nothing — markers=$(NMARK 64) carried=$(NLINES 'EVENT family-carried')"

# 4b. NO VERDICT IS NEVER STORED. The call is billed and counted; a paid-for
#     empty answer must not become a free carried ACCEPT.
CLEAN
RECMK 65; FAM_A | PRDIFF 65
ROWADD "o/p1#65" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/65"
BRENV=(ADJ_VERDICT=MAYBE); RUN; BRENV=()
[ "$(NFAM)" = 0 ] && ok || bad "4b: a no-verdict run stores nothing (got $(NFAM))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok || bad "4b2: and the call was billed (tick: $(LASTTICK))"

# 4c. A1 — THE ASYMMETRY. br_family_key answers for test-tamper and the store
#     keeps a test-tamper ruling, but br_opt_family_pre carries IRON-LAW ONLY:
#     the lane's tamper ACCEPT arm writes a TEST-CHANGE block and rebuilds, so a
#     carry that wrote only a marker would silently drop the park. Two tamper
#     records of one family in one tick: one row stored, two rulings bought.
CLEAN
for N in 71 72; do
  D="$H/builds/p1-TK-$N-1"; mkdir -p "$D"
  printf 'REVIEW_BLOCKED test-tamper 2 case(s) removed\n' > "$D/RESULT"
  printf 'DELETED_CASES:\n  alpha case\n  beta case\nJUSTIFICATION: NONE-GIVEN\n' > "$D/test-tamper.txt"
  : > "$D/.review-rescued"
  touch -d "@$((NOW - 40000))" "$D/RESULT"
done
BRENV=(BR_PER_TICK=2 ADJ_VERDICT=ACCEPT); RUN; BRENV=()
[ "$(NFAM)" = 1 ] && [ "$(FAMQ .slug)" = test-tamper ] && ok \
  || bad "4c: one test-tamper family row (got $(NFAM), slug $(FAMQ .slug); log: $(LOG | tail -4))"
[ "$(NAGENT)" = 2 ] && ok || bad "4c2: and BOTH parks bought a ruling (agent: $(cat "$T/agent.txt"))"
[ "$(NMARKALL)" = 0 ] && ok || bad "4c3: a tamper carry writes no marker (got $(NMARKALL))"
[ "$(NLINES 'EVENT family-carried')" = 0 ] && ok \
  || bad "4c4: and nothing is carried (got $(NLINES 'EVENT family-carried'))"

# ============================================================================
# 5. NO HEAD READ ⇒ NO MARKER, no attempt, no uses bump. The marker is bound to
#    the sha it judged, so a head this tick could not read buys nothing at all
#    and the adjudication is offered again next tick.
# ============================================================================
CLEAN
RECMK 81; RECMK 82
FAM_A | PRDIFF 81; FAM_A | PRDIFF 82
RESET
ROWADD "o/p1#81" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/81"
BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
USES0=$(FAMQ .uses)
RESET
: > "$T/nohead-82"
ROWADD "o/p1#82" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/82"
BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
[ "$(NMARK 82)" = 0 ] && ok || bad "5: no head read, no marker (got $(NMARK 82))"
[ "$(FAMQ .uses)" = "$USES0" ] && ok || bad "5b: and no uses bump ($(FAMQ .uses) vs $USES0)"
[ "$(NLINES 'EVENT family-carried')" = 0 ] && ok \
  || bad "5c: and no carry event (got $(NLINES 'EVENT family-carried'))"
[ "$(NAGENT)" = 0 ] && ok || bad "5d: and nothing is bought this tick (agent: $(cat "$T/agent.txt"))"
[ "$(NLINES 'the head could not be read')" = 1 ] && ok \
  || bad "5e: one line says so (log: $(LOG | tail -4))"

# ============================================================================
# 6. THE KILL SWITCH. BR_OPT_OFF=family with a ruling on disk is today's
#    per-PR adjudication, byte for byte.
# ============================================================================
CLEAN
RECMK 83; RECMK 84
FAM_A | PRDIFF 83; FAM_A | PRDIFF 84
RESET
ROWADD "o/p1#83" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/83"
BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
RESET
ROWADD "o/p1#84" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/84"
BRENV=(BR_OPT_OFF=family ADJ_VERDICT=ACCEPT); RUN; BRENV=()
[ "$(NAGENT)" = 1 ] && ok || bad "6: the lane does its own work (agent: $(cat "$T/agent.txt"))"
[ "$(LFIELD families)" = 0 ] && ok || bad "6b: families=0 (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT family-carried')" = 0 ] && ok || bad "6c: and nothing is carried"
grep -q '_Adjudication by' "$T/comment-bodies.txt" && ok \
  || bad "6d: the ordinary ruling comment is posted (bodies: $(head -c 200 "$T/comment-bodies.txt"))"

# ============================================================================
# 7. OBSERVE MODE. The hook is asked BEFORE the lane's observe check precisely
#    so it can log what it WOULD have done; it writes no marker, no row, no
#    comment, and the lane does not also log `WOULD adjudicate` for that row.
# ============================================================================
CLEAN
RECMK 85; RECMK 86
FAM_A | PRDIFF 85; FAM_A | PRDIFF 86
RESET
ROWADD "o/p1#85" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/85"
BRENV=(ADJ_VERDICT=ACCEPT); RUN; BRENV=()
FAMBEFORE=$(NFAM); USES1=$(FAMQ .uses)
RESET
touch "$H/flags/blocked-resolver-observe"
ROWADD "o/p1#86" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/86"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NLINES 'WOULD carry family')" = 1 ] && ok \
  || bad "7: exactly one WOULD carry family line (log: $(LOG | tail -4))"
[ "$(NLINES 'WOULD adjudicate')" = 0 ] && ok \
  || bad "7b: and not also WOULD adjudicate (log: $(LOG | tail -4))"
[ "$(NMARK 86)" = 0 ] && ok || bad "7c: observe writes no marker (got $(NMARK 86))"
[ "$(NFAM)" = "$FAMBEFORE" ] && [ "$(FAMQ .uses)" = "$USES1" ] && ok \
  || bad "7d: and no store write ($(NFAM)/$(FAMQ .uses) vs $FAMBEFORE/$USES1)"
[ "$(CARRIED)" = 0 ] && ok || bad "7e: and no comment (bodies: $(cat "$T/comment-bodies.txt"))"
[ "$(NAGENT)" = 0 ] && ok || bad "7f: and no model call (agent: $(cat "$T/agent.txt"))"

echo "blocked-resolver family adjudication (BH-1471): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
