#!/bin/bash
# tests/gh-policy-reads.bh-1586-test.sh — BH-1586: merge-conductor and
# tickets-snapshot-push stop making raw, unledgered, uncached GitHub reads.
#
# WHY (gh-reads audit, 2026-09-23). Every conductor tick read the repo's
# rulesets, its .mergify.yml and its branch protection with a bare `gh api`
# (~300-400/h across the fleet), and the snapshot lane asked "did this branch's
# PR merge?" again every ten minutes for branches whose PR merged days ago.
# None of it went through bin/lib/gh-rest.sh, so none of it was ledgered or
# ETag-cached. Policy does not change between two ticks; a merge is terminal.
#
# WHAT THIS PINS, by driving the code against a stub `gh` that counts calls and
# FAILS any read not shaped the way gh_rest makes it (`gh api -i -X GET …`):
#   A  two conductor ticks inside GH_POLICY_TTL_SECS read rulesets, the ruleset,
#      .mergify.yml and branch protection ONCE; the knob off (0) and an aged
#      entry each buy a fresh read; a 403 is never cached; a 404 is.
#   B  a second snapshot tick for a branch already known merged makes 0
#      closed-PR and 0 commits reads, and still reports the merged claim.
#   C  the snapshot's two list reads send If-None-Match on the second tick.
#   D  the conductor's CI / comment / check-run / file reads answer through
#      gh_rest (no raw `gh api repos/…` GET left at the audited sites).
#   E  the TTL is a registered lib knob (default 3600, required), not a literal.
# Run from anywhere: tests/gh-policy-reads.bh-1586-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp -R "$DIR/bin/lib" "$T/h/bin/lib"
# lane-gate.sh would go looking for settings rows; this suite sets its knob in
# the environment, and section E proves the registry default separately.
rm -f "$T/h/bin/lib/lane-gate.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# --- the stub gh ---------------------------------------------------------------
# Logs every argv. A GET that is NOT `api -i -X GET` (i.e. a raw `gh api repos/…`
# read that bypasses gh_rest) is logged as RAW and fails. Answers come from
# files under $T/ans/<name>: line 1 is the status, the rest is the body. An
# `If-None-Match` matching the served ETag answers 304.
mkdir -p "$T/ans"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
A="\$*"
case "\$A" in
  "api -i -X GET "*) ;;
  "api -i -X "*) printf 'HTTP/1.1 201 Created\r\n\r\n{}'; exit 0 ;;
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api "*) printf 'RAW %s\n' "\$A" >> "$T/raw.txt"; echo "raw read refused by stub" >&2; exit 1 ;;
  *) exit 0 ;;
esac
name=""
case "\$A" in
  *"/rulesets/9"*)                     name=ruleset9 ;;
  *"/rulesets"*)                       name=rulesets ;;
  *"contents/.mergify.yml"*)           name=mergify ;;
  *"/branches/main/protection"*)       name=protection ;;
  *"/actions/runs"*)                   name=runs ;;
  *"/check-runs"*)                     name=checkruns ;;
  *"/issues/"*"/comments"*)            name=comments ;;
  *"/pulls/"*"/files"*)                name=files ;;
  *"head=example-org:ticket/ab-8"*)      name=closed8 ;;
  *"pulls?state=closed"*|*"state=closed"*"head="*) name=closed ;;
  *"/pulls"*)                          name=openprs ;;
  *"matching-refs"*)                   name=refs ;;
  *"/commits/"*)                       name=commit ;;
esac
f="$T/ans/\$name"
# A per-TOKEN answer (protection.<GH_TOKEN>) wins when the fixture has one.
[ -n "\${GH_TOKEN:-}" ] && [ -r "\$f.\$GH_TOKEN" ] && f="\$f.\$GH_TOKEN"
[ -n "\$name" ] && [ -r "\$f" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
st=\$(head -1 "\$f")
etag=""; [ -r "\$f.etag" ] && etag=\$(cat "\$f.etag")
if [ -n "\$etag" ] && grep -qF "If-None-Match: \$etag" <<<"\$A"; then
  printf 'HTTP/1.1 304 Not Modified\r\nETag: %s\r\n\r\n' "\$etag"; exit 0
fi
printf 'HTTP/1.1 %s Stub\r\n' "\$st"
[ -n "\$etag" ] && printf 'ETag: %s\r\n' "\$etag"
printf '\r\n'; tail -n +2 "\$f"
exit 0
EOF
chmod +x "$T/fakebin/gh"
ans() { printf '%s\n%s' "$2" "$3" > "$T/ans/$1"; }   # ans <name> <status> <body>
cnt() { grep -c -- "$1" "$T/gh-calls.txt" 2>/dev/null || true; }
export PATH="$T/fakebin:$PATH"

SLUG=example-org/policy-os
MGFY=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')
ans rulesets 200 '[{"id":9,"enforcement":"active"}]'
ans ruleset9 200 '{"id":9,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"pull_request"}]}'
ans mergify 200 "{\"content\":\"$MGFY\"}"
ans protection 200 '{"required_status_checks":{"strict":true,"contexts":["ci"]}}'

# One conductor TICK is one process, exactly as cron runs it. MC_QUEUE_TTL=0
# takes the per-tick provider-word cache out of the way, so what is counted is
# the policy reads themselves.
tick() { # tick [ENV=VAL ...] -> "<provider>|<protection answer>"
  env MC_QUEUE_TTL=0 "$@" bash -c '
    . "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    . "$HARNESS/bin/lib/gh-push-identity.sh" >/dev/null 2>&1
    p=$(mc_queue_provider "'"$SLUG"'")
    IFS=$'"'"'\t'"'"' read -r pst _ <<<"$(gh_branch_protection "'"$SLUG"'" main)"
    printf "%s|%s\n" "$p" "$pst"' 2>/dev/null
}

# === A. policy reads: through gh_rest, once per TTL ===========================
: > "$T/gh-calls.txt"; : > "$T/raw.txt"
R1=$(tick GH_POLICY_TTL_SECS=3600)
R2=$(tick GH_POLICY_TTL_SECS=3600)
[ "$R1" = "mergify|ok" ] && ok || bad "A0 tick 1 must answer mergify|ok (got '$R1'; raw reads: $(tr '\n' ';' < "$T/raw.txt"))"
[ "$R2" = "mergify|ok" ] && ok || bad "A0 tick 2 must answer the same from cache (got '$R2')"
[ ! -s "$T/raw.txt" ] && ok || bad "A1 a policy read bypassed gh_rest: $(tr '\n' ';' < "$T/raw.txt")"
[ "$(grep -cE "X GET repos/$SLUG/rulesets( |$)" "$T/gh-calls.txt")" = 1 ] && ok \
  || bad "A2 two ticks inside the TTL must list rulesets ONCE (got $(grep -cE "X GET repos/$SLUG/rulesets( |$)" "$T/gh-calls.txt"))"
[ "$(cnt "/rulesets/9")" = 1 ] && ok || bad "A3 two ticks inside the TTL must read ruleset 9 ONCE (got $(cnt /rulesets/9))"
[ "$(cnt "contents/.mergify.yml")" = 1 ] && ok || bad "A4 two ticks inside the TTL must read .mergify.yml ONCE (got $(cnt contents/.mergify.yml))"
[ "$(cnt "/branches/main/protection")" = 1 ] && ok || bad "A5 two ticks inside the TTL must read branch protection ONCE (got $(cnt /branches/main/protection))"

# The knob at 0 is "no cache": every tick reads.
tick GH_POLICY_TTL_SECS=0 >/dev/null
[ "$(cnt "contents/.mergify.yml")" = 2 ] && ok || bad "A6 GH_POLICY_TTL_SECS=0 must read .mergify.yml again (got $(cnt contents/.mergify.yml))"
[ "$(cnt "/branches/main/protection")" = 2 ] && ok || bad "A7 GH_POLICY_TTL_SECS=0 must read protection again (got $(cnt /branches/main/protection))"

# An entry older than the TTL is not served. The entry is AGED by rewriting its
# epoch (line 1 is "<epoch> <rc>"), never by sleeping past it.
age_cache() { # age_cache <seconds> — push every entry's epoch that far back
  local f at rc
  for f in "$T"/h/state/gh-policy-cache/*/*; do
    [ -f "$f" ] || continue
    read -r at rc < "$f"
    { printf '%s %s\n' "$((at - $1))" "$rc"; tail -n +2 "$f"; } > "$f.aged" && mv "$f.aged" "$f"
  done
}
tick GH_POLICY_TTL_SECS=3600 >/dev/null     # re-seeds the cache (A6's TTL=0 tick wrote nothing)
[ "$(cnt "contents/.mergify.yml")" = 2 ] && ok || bad "A8a a fresh entry from tick 1 must still be served (got $(cnt contents/.mergify.yml), want 2)"
age_cache 7200
tick GH_POLICY_TTL_SECS=3600 >/dev/null
[ "$(cnt "contents/.mergify.yml")" = 3 ] && ok || bad "A8 an entry older than the TTL must be re-read (got $(cnt contents/.mergify.yml), want 3)"
[ "$(cnt "/branches/main/protection")" = 3 ] && ok || bad "A8b an aged protection entry must be re-read (got $(cnt /branches/main/protection), want 3)"

# A 403 is unverifiable: never cached, reported with its status.
rm -rf "$T/h/state/gh-policy-cache"; : > "$T/gh-calls.txt"
ans protection 403 '{"message":"Resource not accessible by integration"}'
P1=$(tick GH_POLICY_TTL_SECS=3600); P2=$(tick GH_POLICY_TTL_SECS=3600)
[ "${P1#*|}" = "unreadable 403" ] && [ "${P2#*|}" = "unreadable 403" ] && ok \
  || bad "A9 a 403 on protection must read 'unreadable 403' on both ticks (got '$P1' / '$P2')"
[ "$(cnt "/branches/main/protection")" -ge 2 ] && ok || bad "A10 a 403 must not be cached (protection reads: $(cnt /branches/main/protection))"
# A 404 is NEVER cached (#1605 review BLOCKING-1). A negative queue-policy
# answer is the fail-OPEN direction: a cached "no .mergify.yml" keeps the
# provider at `none` and every merger does a direct `gh pr merge` around the
# queue. A cached "unprotected" is token-dependent (GitHub 404s what a token
# cannot see). So both are re-asked, and the cost is an ETag'd read.
rm -rf "$T/h/state/gh-policy-cache"; : > "$T/gh-calls.txt"
rm -f "$T/ans/mergify" "$T/ans/protection"
N1=$(tick GH_POLICY_TTL_SECS=3600); N2=$(tick GH_POLICY_TTL_SECS=3600)
[ "$N1" = "none|unprotected" ] && [ "$N2" = "none|unprotected" ] && ok || bad "A11 404s must read none|unprotected (got '$N1' / '$N2')"
[ "$(cnt "contents/.mergify.yml")" = 2 ] && [ "$(cnt "/branches/main/protection")" = 2 ] && ok \
  || bad "A12 a 404 must never be cached (mergify $(cnt contents/.mergify.yml), protection $(cnt /branches/main/protection), want 2 and 2)"

# Mergify ENABLED after a 404: the next provider probe (MC_QUEUE_TTL expiry,
# here 0) must say mergify — the earlier 404 must not stand for the TTL.
ans mergify 200 "{\"content\":\"$MGFY\"}"
E1=$(tick GH_POLICY_TTL_SECS=3600)
[ "${E1%%|*}" = mergify ] && ok || bad "A13 a 404 then Mergify enabled must read mergify at the next probe (got '$E1')"

# ROLLBACK fast path (docs/MERGIFY.md §4): with `mergify` cached (positive,
# inside the TTL), .mergify.yml goes away and the operator deletes the
# provider file. The very next probe — MC_QUEUE_TTL at its real 300, no
# override — must say none: deleting the provider file drops the repo's
# policy entries too.
rm -rf "$T/h/state/gh-policy-cache"
R14s=$(tick GH_POLICY_TTL_SECS=3600)
[ "${R14s%%|*}" = mergify ] && ok || bad "A14s the seeding tick must read (and cache) mergify (got '$R14s')"
rm -f "$T/ans/mergify"
PF="$T/h/tmp/merge-queue-${SLUG//\//_}.provider"
[ -f "$PF" ] && ok || bad "A14a the provider word file must exist at $PF"
rm -f "$PF"
R14=$(tick GH_POLICY_TTL_SECS=3600 MC_QUEUE_TTL=300)
[ "${R14%%|*}" = none ] && ok || bad "A14 deleting the .provider file must flip mergify -> none at once (got '$R14')"
# …and the other direction: .mergify.yml appears, provider file deleted.
ans mergify 200 "{\"content\":\"$MGFY\"}"; rm -f "$PF"
R15=$(tick GH_POLICY_TTL_SECS=3600 MC_QUEUE_TTL=300)
[ "${R15%%|*}" = mergify ] && ok || bad "A15 deleting the .provider file must flip none -> mergify at once (got '$R15')"

# Two TOKENS get their own protection answers: tokA cannot see the branch
# (404 -> unprotected), tokB can (200 -> ok). Neither may be served the
# other's answer from the cross-process cache, in either order.
rm -rf "$T/h/state/gh-policy-cache"
ans protection.tokA 404 '{"message":"Not Found"}'
ans protection.tokB 200 '{"required_status_checks":{"strict":true,"contexts":["ci"]}}'
TB1=$(tick GH_POLICY_TTL_SECS=3600 GH_TOKEN=tokB); TA1=$(tick GH_POLICY_TTL_SECS=3600 GH_TOKEN=tokA)
TB2=$(tick GH_POLICY_TTL_SECS=3600 GH_TOKEN=tokB)
[ "${TB1#*|}" = ok ] && [ "${TA1#*|}" = unprotected ] && [ "${TB2#*|}" = ok ] && ok \
  || bad "A16 two tokens must get separate protection answers (tokB '$TB1', tokA '$TA1', tokB again '$TB2')"
rm -f "$T/ans/protection.tokA" "$T/ans/protection.tokB"

# === D. the conductor's other audited reads answer through gh_rest ===========
: > "$T/gh-calls.txt"; : > "$T/raw.txt"
ans runs 200 '{"workflow_runs":[{"id":71,"name":"ci","status":"completed","conclusion":"success","run_started_at":"2026-09-22T00:00:00Z","run_attempt":1},{"id":72,"name":"e2e","status":"completed","conclusion":"cancelled","run_started_at":"2026-09-22T00:00:00Z","run_attempt":1}]}'
ans comments 200 '[{"user":{"login":"mergify[bot]"},"body":"## Reason\n> - `github-review-approved`\n"}]'
ans checkruns 200 '{"check_runs":[]}'
D=$(bash -c '
  . "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  printf "ci=%s flake=%s dq=%s\n" "$(mc_ci_state "'"$SLUG"'" deadbeef)" "$(mc_ci_flake_runs "'"$SLUG"'" deadbeef | tr "\n" ,)" \
    "$(mc_dequeue_reason "'"$SLUG"'" "https://github.com/'"$SLUG"'/pull/5" deadbeef)"' 2>/dev/null)
[ "$D" = "ci=green flake=72|e2e, dq=github-review-approved" ] && ok || bad "D1 CI/flake/dequeue reads must answer through gh_rest (got '$D'; raw: $(tr '\n' ';' < "$T/raw.txt"))"
[ ! -s "$T/raw.txt" ] && ok || bad "D2 a conductor read bypassed gh_rest: $(tr '\n' ';' < "$T/raw.txt")"
# The audited raw sites are gone: no bare `gh api "repos/…` GET at any of them.
for pat in 'repos/$slug/rulesets' 'contents/.mergify.yml' 'actions/runs?head_sha=' 'pulls/$num/files' \
           'issues/$num/comments?per_page=100' 'commits/$head/check-runs' 'branches/$branch/protection'; do
  hits=$(grep -nF "gh api \"$pat" "$DIR/bin/lib/mc/queue.sh" "$DIR/bin/lib/mc/classify.sh" "$DIR/bin/lib/gh-push-identity.sh" 2>/dev/null
         grep -nF "gh api --paginate \"$pat" "$DIR/bin/lib/mc/queue.sh" "$DIR/bin/lib/mc/classify.sh" 2>/dev/null
         grep -nE "gh api \"repos/[^\"]*${pat//\$/\\\$}" "$DIR/bin/lib/mc/queue.sh" "$DIR/bin/lib/mc/classify.sh" "$DIR/bin/lib/gh-push-identity.sh" 2>/dev/null)
  hits=$(printf '%s\n' "$hits" | grep -v '^\s*$' | grep -vE '^[^:]+:[0-9]+:\s*#' | grep -v -- '-X ' || true)
  [ -z "$hits" ] && ok || bad "D3 raw read left at '$pat': $hits"
done
for pat in 'pulls?state=open' 'git/matching-refs' 'pulls?state=closed' 'commits/$SHA'; do
  hits=$(grep -nF "gh api \"repos/\$R/$pat" "$DIR/bin/tickets-snapshot-push.sh" || true)
  [ -z "$hits" ] && ok || bad "D4 raw snapshot read left at '$pat': $hits"
done

# === B/C. tickets-snapshot-push: merged is terminal, lists carry an ETag =====
S="$T/snap"; mkdir -p "$S/h/bin" "$S/h/env" "$S/h/logs" "$S/h/state" "$S/h/flags"
cp -R "$DIR/bin/lib" "$S/h/bin/lib"; rm -f "$S/h/bin/lib/lane-gate.sh" "$S/h/bin/lib/wake-lanes.sh"
cp "$DIR/bin/tickets-snapshot-push.sh" "$S/h/bin/"
P=p1586x$$
echo secret > "$S/h/env/.watchdog-secret"
: > "$S/h/env/global.env"; : > "$S/h/env/$P.env"
printf '#!/bin/bash\necho %s\n' "$P" > "$S/h/bin/fleet-projects-or-alert.sh"
cat > "$S/h/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo https://board.example ;; board_prefix) echo /api ;; repo) echo example-org/snap-os ;; *) echo - ;; esac
EOF
printf '#!/bin/bash\necho tok\n' > "$S/h/bin/internal-token-for.sh"
chmod +x "$S/h/bin/"*.sh
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    */boards)          echo '[{"id":"b1"}]'; exit 0 ;;
    */boards/b1/tickets) echo '[{"key":"AB-7","status":"in_progress","title":"merged work"},{"key":"AB-8","status":"in_progress","title":"live branch"}]'; exit 0 ;;
    @*) n=\$(ls "$T"/pushed-*.json 2>/dev/null | wc -l | tr -d ' '); cp "\${a#@}" "$T/pushed-\$n.json" ;;
  esac
done
exit 0
EOF
chmod +x "$T/fakebin/curl"
ans openprs 200 '[]'; echo '"W/\"open-1\""' > "$T/ans/openprs.etag"
ans refs 200 '[{"ref":"refs/heads/ticket/ab-7","object":{"sha":"a7a7a7"}},{"ref":"refs/heads/ticket/ab-8","object":{"sha":"b8b8b8"}}]'
echo '"W/\"refs-1\""' > "$T/ans/refs.etag"
# The closed-PR lookup: AB-7's branch merged; AB-8's has no PR at all.
ans closed 200 '[{"number":77,"merged_at":"2026-09-20T10:00:00Z","html_url":"https://github.com/example-org/snap-os/pull/77","user":{"login":"operator"},"head":{"ref":"ticket/ab-7"}}]'
ans commit 200 '{"author":{"login":"partner"},"commit":{"committer":{"date":"2026-09-21T00:00:00Z"}}}'
# Every closed lookup answers AB-7's merged PR except AB-8's own (its head is
# ticket/ab-8), which the stub routes to closed8: no PR at all.
ans closed8 200 '[]'
# lane-gate is not in this tree, so the lane's required knob comes from the env
# exactly as lane_env_apply would export it.
# TEST-CHANGE: BH-3321 — an unset WATCHDOG_URL now stops the lane before any read.
snap() { ( cd "$S" && HARNESS="$S/h" PATH="$T/fakebin:$PATH" TICKETS_SNAPSHOT_MERGED_KEEP_DAYS="${KEEP:-30}" \
           WATCHDOG_URL=http://watchdog.invalid \
           bash "$S/h/bin/tickets-snapshot-push.sh" ) >/dev/null 2>&1; }
: > "$T/gh-calls.txt"; : > "$T/raw.txt"
snap
AB7_CLOSED_1=$(cnt "head=example-org:ticket/ab-7"); AB7_COMMIT_1=$(cnt "commits/a7a7a7")
snap
AB7_CLOSED_2=$(cnt "head=example-org:ticket/ab-7"); AB7_COMMIT_2=$(cnt "commits/a7a7a7")
[ ! -s "$T/raw.txt" ] && ok || bad "B0 a snapshot read bypassed gh_rest: $(tr '\n' ';' < "$T/raw.txt")"
[ "$AB7_CLOSED_1" = 1 ] && ok || bad "B1 tick 1 must ask once whether AB-7's branch merged (got $AB7_CLOSED_1)"
[ "$AB7_CLOSED_2" = "$AB7_CLOSED_1" ] && [ "$AB7_COMMIT_2" = "$AB7_COMMIT_1" ] && ok \
  || bad "B2 tick 2 must make 0 closed/commits reads for a branch known merged (closed $AB7_CLOSED_1->$AB7_CLOSED_2, commits $AB7_COMMIT_1->$AB7_COMMIT_2)"
LAST=$(ls "$T"/pushed-*.json 2>/dev/null | sort | tail -1)
CL=$(jq -c --arg p "$P" '.projects[$p].tickets[] | select(.key=="AB-7") | .claim' "$LAST" 2>/dev/null)
[ "$(jq -r '.state + " " + (.pr|tostring)' <<<"$CL" 2>/dev/null)" = "merged 77" ] && ok \
  || bad "B3 tick 2 must still report AB-7 as merged PR 77 from the persisted answer (got '$CL')"
[ "$(cnt "head=example-org:ticket/ab-8")" = 2 ] && ok || bad "B4 a branch NOT known merged is still asked every tick (got $(cnt head=example-org:ticket/ab-8))"
CL8=$(jq -r --arg p "$P" '.projects[$p].tickets[] | select(.key=="AB-8") | .claim.kind' "$LAST" 2>/dev/null)
[ "$CL8" = branch ] && ok || bad "B5 an unmerged branch still claims kind=branch (got '$CL8')"
# C: the second tick's list reads carry the ETag the first one got.
grep -F "pulls" "$T/gh-calls.txt" | grep -F "state=open" | tail -1 | grep -qF 'If-None-Match: "W/\"open-1\""' && ok \
  || bad "C1 the open-PR list must send If-None-Match on tick 2: $(grep -F state=open "$T/gh-calls.txt" | tail -1)"
grep -F "matching-refs" "$T/gh-calls.txt" | tail -1 | grep -qF 'If-None-Match: "W/\"refs-1\""' && ok \
  || bad "C2 the matching-refs list must send If-None-Match on tick 2: $(grep -F matching-refs "$T/gh-calls.txt" | tail -1)"

# B6: the merged-branch store is BOUNDED (#1605 review). An entry older than
# TICKETS_SNAPSHOT_MERGED_KEEP_DAYS is pruned on the next run; a fresh one stays.
DB="$S/h/state/tickets-snapshot/merged-branches.tsv"
[ -s "$DB" ] && ok || bad "B6a the merged answer must be persisted at $DB"
OLD=$(( $(date +%s) - 40*86400 ))
printf 'example-org/snap-os\tticket/gone-1\tdeadbeef\t{"kind":"pr","state":"merged"}\t%s\n' "$OLD" >> "$DB"
snap
grep -q 'ticket/gone-1' "$DB" && bad "B6 an entry older than the keep window must be pruned: $(cat "$DB")" || ok
grep -q 'ticket/ab-7' "$DB" && ok || bad "B6b a fresh entry must survive the prune: $(cat "$DB")"
[ "$(cnt "head=example-org:ticket/ab-7")" = "$AB7_CLOSED_1" ] && ok || bad "B6c pruning must not cost a fresh merged branch its memory (closed reads $(cnt head=example-org:ticket/ab-7))"

# === E. the TTL is a registry knob, not a literal ============================
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "E0 registry did not render"
K=$(jq -c '.libs[] | select(.id=="gh-policy-cache") | .knobs[] | select(.env=="GH_POLICY_TTL_SECS") | {default,required}' "$REG" 2>/dev/null)
[ "$K" = '{"default":3600,"required":true}' ] && ok || bad "E1 GH_POLICY_TTL_SECS must be a required lib knob defaulting to 3600 (got '$K')"
if grep -nE '\$\{GH_POLICY_TTL_SECS:[-=][^}]' "$DIR"/bin/lib/*.sh "$DIR"/bin/lib/mc/*.sh "$DIR"/bin/*.sh 2>/dev/null; then
  bad "E2 GH_POLICY_TTL_SECS carries a literal default in code"
else ok; fi
K2=$(jq -c '.lanes[] | select(.id=="tickets-snapshot-push") | .knobs[] | select(.env=="TICKETS_SNAPSHOT_MERGED_KEEP_DAYS") | {default,required}' "$REG" 2>/dev/null)
[ "$K2" = '{"default":30,"required":true}' ] && ok || bad "E3 TICKETS_SNAPSHOT_MERGED_KEEP_DAYS must be a required lane knob defaulting to 30 (got '$K2')"
if grep -nE '\$\{TICKETS_SNAPSHOT_MERGED_KEEP_DAYS:[-=][^}]' "$DIR"/bin/*.sh 2>/dev/null; then
  bad "E4 TICKETS_SNAPSHOT_MERGED_KEEP_DAYS carries a literal default in code"
else ok; fi

echo "gh-policy-reads.bh-1586: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
