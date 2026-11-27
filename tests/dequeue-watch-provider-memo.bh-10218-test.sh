#!/bin/bash
# tests/dequeue-watch-provider-memo.bh-10218-test.sh — BH-10218 W3:
# bin/lib/dequeue-watch/provider-memo.sh (dqw_provider) and its call site in
# bin/dequeue-watch.sh.
#
#   T  3 ticks of bin/dequeue-watch.sh with no push: tick 1 makes 1
#      `.mergify.yml` and 1 `rulesets` read, ticks 2-3 make 0. A push wake
#      makes the next tick read, then 0. A pr or repo wake reads nothing.
#   A  age: DQW_PROVIDER_BACKSTOP_S - 1 serves, DQW_PROVIDER_BACKSTOP_S reads.
#   F  a 5xx read: mc_queue_provider's last-known-good word is used and NOT
#      stored; the next tick reads again.
#   Z  DQW_PROVIDER_BACKSTOP_S=0 reads every tick (the control: the caches
#      under mc_queue_provider are off in this suite); the fallback is 21600.
#   X  a torn store (2 columns) and a feed that cannot tell both read.
#   M  a stored `mergify` is served through dqw_provider.
#   E  the backstop read is conditional: gh_policy_read -> gh_rest sends
#      If-None-Match with the stored ETag, and the fixture 304 writes a ledger
#      row with counted 0.
# Fixture clocks (DQW_NOW) and fixture GitHub answers only.
#
# Run from anywhere: bash tests/dequeue-watch-provider-memo.bh-10218-test.sh (exit 0 = pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wake-feed-fixture.bh-10218.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/dequeue-watch/provider-memo.sh"
FX="$DIR/tests/fixtures/dequeue-watch/fixture.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "dequeue-watch-provider-memo: 0 passed, 1 failed"; exit 1; }
unset GH_TOKEN GITHUB_TOKEN

SLUG=o/r
H="$T/h"; F="$T/fix"; REQ="$F/requests.log"
mkdir -p "$H" "$T/shim" "$F/rest" "$F/rest404"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
for s in lane-alert lead-verdict needs-human-hold box-for agent-call; do
  rm -f "$H/bin/$s.sh"
  printf '#!/bin/bash\nprintf "SCRIPT %%s %%s\\n" "$(basename "$0")" "$*" >> "$DQW_FIX_DIR/requests.log"\n' > "$H/bin/$s.sh"
  chmod +x "$H/bin/$s.sh"
done
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$DQW_FIX_DIR/requests.log"\nexit 1\n' > "$T/shim/gh"
chmod +x "$T/shim/gh"
printf 'proj %s https://example.invalid - 5 box-2\n' "$SLUG" > "$H/fleet.conf"
wf_init
wf_wake "$SLUG" pr 7 10

# The suite's fixture: the BH-3730 fixture with three changes. mc_queue_provider
# is the REAL one (the shared fixture stubs it), /api/wakes and the summary
# come from the wake fixture, and a path under rest404/ answers GitHub's 404.
cat > "$T/fixture.sh" <<'EOF'
_dqwt_mqp=$(declare -f mc_queue_provider)
. "$DQWT_FX"
eval "$_dqwt_mqp"
eval "$(declare -f _jobs_req | sed '1s/^_jobs_req/_fx_jobs_req/')"
. "$WF_STUBS"
eval "$(declare -f _jobs_req | sed '1s/^_jobs_req/_wf_jobs_req/')"
_jobs_req() { case "$2" in "/api/wakes?"*) _wf_jobs_req "$@" ;; *) _fx_jobs_req "$@" ;; esac; }
eval "$(declare -f gh_rest | sed '1s/^gh_rest/_fx_gh_rest/')"
gh_rest() {
  if [ -e "$DQW_FIX_DIR/rest404/$(printf '%s' "$2" | tr '/?&=' '____')" ]; then
    printf 'REST %s %s\n' "$1" "$2" >> "$DQW_FIX_DIR/requests.log"; GH_REST_STATUS=404; return 44
  fi
  _fx_gh_rest "$@"
}
EOF
: > "$F/rest404/repos_o_r_contents_.mergify.yml"
mergify_n() { grep -c "^REST GET repos/$SLUG/contents/.mergify.yml\$" "$REQ" 2>/dev/null || true; }
rulesets_n() { grep -c "^REST GET repos/$SLUG/rulesets\$" "$REQ" 2>/dev/null || true; }
STORE="$H/state/dequeue-watch/provider/o_r"
tick() { # tick [VAR=value…] — one run of the lane; the reads it made into R
  : > "$REQ"
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret \
    HARNESS_TEST_SANDBOX=1 DEQUEUE_WATCH_FIXTURE="$T/fixture.sh" DQWT_FX="$FX" DQW_FIX_DIR="$F" \
    WF="$WF" WF_STUBS="$WF_STUBS" PR_SNAPSHOT_TTL_S=0 PR_SNAPSHOT_FEED_STALE_S=900 \
    MC_QUEUE_TTL=0 GH_POLICY_TTL_SECS=0 "$@" \
    bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
  RC=$?
  R="$(mergify_n) $(rulesets_n)"
}

# ══ T ══
tick; eq "T tick 1 reads .mergify.yml and rulesets once each" "$R" "1 1"; eq "T tick 1 rc" "$RC" 0
eq "T the store holds none and a mark" "$(awk -F'\t' '{print $1, NF, ($3 ~ /^[0-9]+$/)}' "$STORE" 2>/dev/null)" "none 3 1"
tick; eq "T tick 2 reads nothing" "$R" "0 0"
tick; eq "T tick 3 reads nothing" "$R" "0 0"
grep -q 'provider-unknown' "$H/logs/dequeue-watch.log" 2>/dev/null && bad "T a tick logged provider-unknown" || ok
wf_wake "$SLUG" pr 7 11
tick; eq "T a pr wake reads nothing" "$R" "0 0"
wf_wake "$SLUG" repo 99 12
tick; eq "T a repo wake reads nothing" "$R" "0 0"
wf_wake o/r-c push "$(printf 'b%.0s' {1..40})" 13
tick; eq "T another repo's push reads nothing" "$R" "0 0"
wf_wake "$SLUG" push "$(printf 'a%.0s' {1..40})" 14
tick; eq "T a push wake: the next tick reads" "$R" "1 1"
tick; eq "T then 0" "$R" "0 0"

# ══ A ══
ST=$(cut -f2 "$STORE")
tick DQW_NOW=$((ST + 21599)); eq "A age 21599 serves" "$R" "0 0"
tick DQW_NOW=$((ST + 21600)); eq "A age 21600 reads" "$R" "1 1"
tick DQW_NOW=$((ST + 21600)); eq "A then 0 (same fixture clock)" "$R" "0 0"

# ══ F ══
wf_wake "$SLUG" push "$(printf 'c%.0s' {1..40})" 15
rm -f "$F/rest404/repos_o_r_contents_.mergify.yml"   # absent fixture file = gh_rest 75
tick; eq "F a 5xx tick still read" "$R" "1 1"
[ -e "$STORE" ] && bad "F a failed read must not be stored: $(cat "$STORE")" || ok
tick; eq "F the next tick reads again" "$R" "1 1"
: > "$F/rest404/repos_o_r_contents_.mergify.yml"
tick; eq "F a good read is stored again" "$(cut -f1 "$STORE" 2>/dev/null)" none
tick; eq "F then 0" "$R" "0 0"

# ══ Z ══
tick DQW_PROVIDER_BACKSTOP_S=0; eq "Z backstop 0 reads (control: no cache under it)" "$R" "1 1"
tick DQW_PROVIDER_BACKSTOP_S=0; eq "Z backstop 0 reads every tick" "$R" "1 1"
eq "Z the code fallback is 21600" "$( . "$LIB"; DQW_PROVIDER_BACKSTOP_S=x dqw_provider_backstop)" 21600

# ══ X ══
tick
printf 'none\t%s\n' "$(date -u +%s)" > "$STORE"
tick; eq "X a torn store reads" "$R" "1 1"
tick; eq "X then 0" "$R" "0 0"
wf_down
tick; eq "X feed down reads" "$R" "1 1"
tick; eq "X feed down reads every tick" "$R" "1 1"
wf_up; wf_stale
tick; eq "X feed stale reads" "$R" "1 1"
wf_fresh

# ══ M: a stored mergify, through dqw_provider ══
M=$(set +u; export HARNESS="$H" HARNESS_TEST_SANDBOX=1 PR_SNAPSHOT_TTL_S=0 PR_SNAPSHOT_FEED_STALE_S=900
  . "$WF_STUBS"; . "$LIB"
  mc_queue_provider() { echo "CALLED" >> "$T/mqp.log"; printf none; }
  # The mirror's first complete read sets its coverage start; a stored stamp
  # older than that is "cannot tell" (rc 2) by design, so prime the mirror
  # first and take the stamp after it (the order a real tick has).
  wf_wake o/r-m pr 1 99; rcm_mark o/r-m >/dev/null 2>&1
  printf 'mergify\t%s\t%s\n' "$(date -u +%s)" 99 > "$H/state/dequeue-watch/provider/o_r-m"
  dqw_provider o/r-m)
eq "M a stored mergify is served" "$M" mergify
[ -e "$T/mqp.log" ] && bad "M mc_queue_provider was called for a served word" || ok

# ══ E: the conditional read under the store ══
mkdir -p "$T/ghbin" "$T/e"
cat > "$T/ghbin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/e/gh.log"
case "$*" in
  *'If-None-Match: "e1"'*) printf 'HTTP/2.0 304 Not Modified\r\nETag: "e1"\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Resource: core\r\n\r\n' ;;
  *'repos/o/r/contents/.mergify.yml'*) printf 'HTTP/2.0 200 OK\r\nETag: "e1"\r\nX-Ratelimit-Remaining: 4998\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Resource: core\r\n\r\n{"content":"cXVldWVfcnVsZXM6Cg==","encoding":"base64"}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/ghbin/gh"
erun() { ( set +u; export T PATH="$T/ghbin:$PATH" HARNESS="$T/e/h" GH_POLICY_TTL_SECS=0; unset GH_LEDGER_BY_CALLER
  . "$DIR/bin/lib/gh-rest.sh"; . "$DIR/bin/lib/gh-policy-cache.sh"
  gh_policy_read o/r mergify repos/o/r/contents/.mergify.yml > "$T/e/body"; echo "rc=$? st=$GH_REST_STATUS" ); }
eq "E read 1 is a 200" "$(erun)" "rc=0 st=200"
eq "E read 2 (the backstop read) answers from the ETag" "$(erun)" "rc=0 st=304"
grep -q 'If-None-Match: "e1"' "$T/e/gh.log" && ok || bad "E read 2 did not send If-None-Match: $(tail -1 "$T/e/gh.log")"
grep -q 'queue_rules' <(jq -r .content "$T/e/body" | base64 -d 2>/dev/null) && ok || bad "E the 304 must replay the cached body"
ROW304=$(cat "$T/e/h/state/gh-rest-ledger/"*.tsv 2>/dev/null | awk -F'\t' '$6 == 304')
[ -n "$ROW304" ] && ok || bad "E no ledger row for the 304: $(cat "$T/e/h/state/gh-rest-ledger/"*.tsv 2>/dev/null)"
eq "E the 304 row is counted 0" "$(printf '%s\n' "$ROW304" | awk -F'\t' 'NR==1{print $7}')" 0

# No network: the lane's GitHub reads were all the fixture's.
grep -q '^gh ' "$T/fix/requests.log" 2>/dev/null && bad "a raw gh call reached the shim: $(grep '^gh ' "$T/fix/requests.log" | head -2)" || ok

echo "dequeue-watch-provider-memo: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
