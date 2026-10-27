#!/bin/bash
# tests/blocked-resolver-pr-hold.bh-8474-test.sh — BH-8474: a per-PR hold label
# (`resolver-hold`) stops every rung of bin/blocked-resolver.sh on that PR, the
# hold expires after BR_PR_HOLD_TTL_SECS with one alert, and the BH-8328
# human-push defer window defaults to 60 minutes.
#
# THE CASES (plan ## Acceptance tests):
#   P0        the fragment exists and parses
#   P1, P1b   driver: a fix-round park at the fix cap carrying the label is not
#             closed, not ABANDONED, and the log names the hold once
#   P1q       driver, hub: an under-cap park with the label queues 0 fix rounds
#   P3        driver: a ladder park with the label runs no mechanical rung
#   P7        driver: two ticks, one PR HOLD line each, `since` kept
#   P13       0 real GitHub calls: every gh call went to the fake
#   P2, P4-P6c, P7b-P12: the fragment and br_abandon driven directly on the real
#             bin/lib/br modules (the BH-8328 suite's U pattern)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-pr-hold.bh-8474-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

FRAG="$DIR/bin/blocked-resolver.d/bh-8474-pr-hold.sh"
ZFRAG="$DIR/bin/blocked-resolver.d/bh-8328-zero-rung.sh"
# P0. The fragment exists and parses.
[ -r "$FRAG" ] && bash -n "$FRAG" && ok || bad "P0: bin/blocked-resolver.d/bh-8474-pr-hold.sh is missing or does not parse"

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || exit 1
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# Every fragment rides with the driver copy, as bin/harness-sync.sh puts them on a box.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
# The hub's fix round is a fix_round_jobs row (BH-2674): the fake worker behind a
# `curl` shim that also logs every call.
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
for lib in bin/lib/jobs/req.sh bin/lib/fix-round-queue.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || exit 1
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nFRW_STATE=%q exec python3 %q "$@"\n' \
  "$T/curl.txt" "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret-fixture; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
} >> "$H/bin/jobs-client.sh" || exit 1
# The PR object the shared stub serves carries no labels. This wrapper adds
# $T/prlabels (a JSON array of {name}) to the `pulls/<n>` read when it exists.
mv "$T/fakebin/gh" "$T/fakebin/gh-base" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
out=\$("$T/fakebin/gh-base" "\$@"); rc=\$?
lab=0
for a in "\$@"; do [[ "\$a" =~ /pulls/[0-9]+\$ ]] && lab=1; done
case "\$*" in *"-i -X GET"*) ;; *) lab=0 ;; esac
if [ "\$lab" = 1 ] && [ -f "$T/prlabels" ]; then
  hdr="\${out%%\$'\r\n\r\n'*}"; body="\${out#*\$'\r\n\r\n'}"
  nb=\$(printf '%s' "\$body" | jq -c --slurpfile l "$T/prlabels" '.labels = \$l[0]' 2>/dev/null) && body="\$nb"
  printf '%s\r\n\r\n%s' "\$hdr" "\$body"
else
  printf '%s' "\$out"
fi
exit "\$rc"
EOF
chmod +x "$T/fakebin/gh" || exit 1
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 1\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
LOGF="$H/logs/blocked-resolver.log"
PR91="https://github.com/o/tproj/pull/91"
CK91=tproj-TK-91
RECF91="$H/state/blocked-resolver/tproj/$CK91.json"
H91=$(osha ticket/TK-91)
HUBENV=(HUB_BOX_NAME=hubx BOX_NAME=hubx)
HOLDLAB='[{"name":"resolver-hold"}]'

RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/tmp/brfix"
  mkdir -p "$H/state/blocked-resolver/tproj"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/blocked-resolver-cron.lock" "$T/prlabels"
  : > "$LOGF"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"
  : > "$T/agent.txt"; : > "$T/comment-bodies.txt"; : > "$T/rebase.txt"
  rm -f "$T/prcomments" "$T/prcomments.json" "$T/prreviews.json"
  : > "$T/findings"
  scratch_rm "$FRW"; mkdir -p "$FRW"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" branch -D "brfix/$CK91" >/dev/null 2>&1
  printf 'ticket/TK-91' > "$T/prbranch"; printf '%s' "$H91" > "$T/prhead"; echo OPEN > "$T/prstate"
  BRENV=()
}
REC() { jq -r "$1" "$RECF91" 2>/dev/null; }
CLOSES() { grep -c -- '-X PATCH.*pulls/91' "$T/closed.txt" 2>/dev/null; }
ROWS() { jq 'length' "$FRW/rows.json" 2>/dev/null || echo 0; }
HOLDLINES() { grep -c "PR HOLD — https://github.com/o/tproj/pull/91 carries label resolver-hold" "$LOGF"; }
PARK() { ROW "o/tproj#91" "$1" "$PR91"; }
# Two REAL fix rounds on the current head, cap 2: without a hold this closes
# once and records ABANDONED (BH-8328 suite Z7).
CAPREC() {
  jq -nc --arg u "$PR91" --arg h "$H91" '
    {project:"tproj",rkey:"tproj-TK-91",rebuilds:0,mechanicals:0,regens:0,fixrounds:2,adjudications:0,outcome:"",
     attempts:[{at:"2026-10-25 16:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h},
               {at:"2026-10-25 16:30:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h}],
     rung_head:$h,rung_pr:$u}' > "$RECF91"
}

# ============================================================================
# P1c (control, no label): the cap park closes. Without this, P1 would be
# green on a fixture that never reaches the close.
# ============================================================================
RESET; CAPREC
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 1 ] && [ "$(REC .outcome)" = ABANDONED ] && ok \
  || bad "P1c: control — an unlabelled cap park must close once (closes $(CLOSES), outcome $(REC .outcome); log: $(tail -4 "$LOGF"))"
grep -q 'PR HOLD' "$LOGF" && bad "P1c: an unlabelled PR prints no PR HOLD line" || ok

# ============================================================================
# P1 (acceptance 1). The same park with the label: 0 closes, no ABANDONED,
# one PR HOLD line that names the url and the label.
# ============================================================================
RESET; CAPREC; printf '%s' "$HOLDLAB" > "$T/prlabels"
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 0 ] && ok || bad "P1: a labelled PR must NOT be closed (closed: $(cat "$T/closed.txt"); log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" != ABANDONED ] && ok || bad "P1: no ABANDONED outcome may be recorded"
[ "$(HOLDLINES)" = 1 ] && ok || bad "P1: exactly one PR HOLD line naming the url and label (got $(HOLDLINES); log: $(tail -4 "$LOGF"))"
grep -q "\-> " "$LOGF" && bad "P1: no rung may be dispatched (log: $(grep -- '-> ' "$LOGF"))" || ok
[ "$(REC .pr_hold.url)" = "$PR91" ] && [ "$(REC .pr_hold.alerted)" = false ] && ok \
  || bad "P1: the record keeps pr_hold {url, since, alerted:false} (got $(REC ".pr_hold|tojson"))"
[ -s "$T/agent.txt" ] && bad "P1: no agent may run" || ok

# P1b. The label among three others.
RESET; CAPREC
printf '%s' '[{"name":"ai-build"},{"name":"hotfix"},{"name":"resolver-hold"},{"name":"needs-review"}]' > "$T/prlabels"
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 0 ] && [ "$(HOLDLINES)" = 1 ] && ok \
  || bad "P1b: the label among others holds the PR (closes $(CLOSES); log: $(tail -3 "$LOGF"))"

# P1n. Near miss: a label that only contains the name does not hold.
RESET; CAPREC; printf '%s' '[{"name":"resolver-hold-off"},{"name":"do-not-merge"}]' > "$T/prlabels"
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 1 ] && ok || bad "P1n: resolver-hold-off / do-not-merge are not the hold label (closes $(CLOSES))"

# ============================================================================
# P1q. The hub, an under-cap fix-round park: without the label a fix round is
# queued (one fix_round_jobs row); with it, 0 rows and no queue call.
# ============================================================================
RESET
PARK review-changes-requested; BRENV=("${HUBENV[@]}")
RUN
[ "$(ROWS)" = 1 ] && ok || bad "P1q: control — the hub queues one fix round for an unlabelled park (rows $(ROWS); log: $(tail -4 "$LOGF"))"
RESET; printf '%s' "$HOLDLAB" > "$T/prlabels"
PARK review-changes-requested; BRENV=("${HUBENV[@]}")
RUN
[ "$(ROWS)" = 0 ] && ok || bad "P1q: a labelled park queues 0 fix rounds (rows $(ROWS); log: $(tail -4 "$LOGF"))"
grep -q 'fix round queued' "$LOGF" && bad "P1q: no 'fix round queued' line" || ok
[ "$(HOLDLINES)" = 1 ] && ok || bad "P1q: one PR HOLD line (got $(HOLDLINES))"

# ============================================================================
# P3. A ladder park (conflict-unresolvable): without the label the mechanical
# rung asks mc_rebase; with it, no rebase and no `-> ladder` line.
# ============================================================================
RESET
PARK conflict-unresolvable
RUN
[ -s "$T/rebase.txt" ] && ok || bad "P3: control — an unlabelled ladder park runs the mechanical rung (log: $(tail -4 "$LOGF"))"
RESET; printf '%s' "$HOLDLAB" > "$T/prlabels"
PARK conflict-unresolvable
RUN
[ -s "$T/rebase.txt" ] && bad "P3: a labelled ladder park runs no mechanical rung ($(cat "$T/rebase.txt"))" || ok
grep -q -- '-> ladder' "$LOGF" && bad "P3: no '-> ladder' dispatch line" || ok
[ "$(REC '.mechanicals // 0')" = 0 ] && ok || bad "P3: no counter moves (mechanicals $(REC .mechanicals))"

# ============================================================================
# P7. Two ticks with the label: one PR HOLD line per tick, `since` written on
# tick 1 and read unchanged on tick 2 (the record bytes are equal).
# ============================================================================
RESET; CAPREC; printf '%s' "$HOLDLAB" > "$T/prlabels"
PARK review-changes-requested; BRENV=(BR_REVIEW_FIX_ROUNDS=2 BR_UNCHANGED_RECHECK_S=3600)
RUN
cp "$RECF91" "$T/rec-tick1.json"
[ "$(HOLDLINES)" = 1 ] && ok || bad "P7: tick 1 prints one PR HOLD line (got $(HOLDLINES))"
: > "$LOGF"
RUN
[ "$(HOLDLINES)" = 1 ] && ok || bad "P7: tick 2 prints one PR HOLD line too: a held row is never a quiet skip (got $(HOLDLINES); log: $(tail -3 "$LOGF"))"
cmp -s "$RECF91" "$T/rec-tick1.json" && ok || bad "P7: tick 2 writes nothing (diff: $(diff "$T/rec-tick1.json" "$RECF91"))"
[ "$(CLOSES)" = 0 ] && ok || bad "P7: two held ticks close nothing"
# Removing the label lifts the hold: the next tick clears pr_hold and closes.
rm -f "$T/prlabels"; : > "$LOGF"
RUN
grep -q "PR HOLD — lifted on $PR91" "$LOGF" && ok || bad "P7: a removed label is said once as lifted (log: $(tail -3 "$LOGF"))"
[ "$(REC '.pr_hold // "none"')" = none ] && ok || bad "P7: a lifted hold clears pr_hold (got $(REC ".pr_hold|tojson"))"
[ "$(CLOSES)" = 1 ] && ok || bad "P7: the lifted PR is processed again (closes $(CLOSES))"

# ============================================================================
# P13. 0 real GitHub calls: the fake gh answered every PR read, the token is
# empty, and no curl call left for a GitHub host.
# ============================================================================
grep -q 'pulls/91' "$T/gh.txt" && ok || bad "P13: the PR reads went to the fake gh"
[ -z "${GH_TOKEN:-}" ] && ok || bad "P13: GH_TOKEN must be empty in the suite"
grep -q 'api\.github\.com' "$T/curl.txt" 2>/dev/null && bad "P13: a curl call reached a GitHub host ($(grep github "$T/curl.txt"))" || ok

# ============================================================================
# U. The fragment and br_abandon, driven directly: the real record.sh,
#    ladder.sh and headgate.sh modules, GitHub's PR object served from a file.
# ============================================================================
U="$T/u"; mkdir -p "$U/state/tproj" "$U/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$U" > "$U/bin/lane-alert.sh"
chmod +x "$U/bin/lane-alert.sh"
UNOW=1793000000
cat > "$T/u-pre.sh" <<EOF
set -u
unset BR_PR_HOLD_TTL_SECS BR_PR_HOLD_LABEL BR_ZERO_RUNG_REBRIEFS BR_HUMAN_PUSH_SETTLE_SECS
H="$U"; ST="$U/state"; LOG="$U/log"; OBSERVE="\${OBSERVE:-0}"
STAMP() { printf '2026-10-26 18:00:00Z'; }
say() { printf '%s\n' "\$*" >> "\$LOG"; }
br_now() { printf '%s' "$UNOW"; }
br_is_sha() { [[ "\${1:-}" =~ ^[0-9a-f]{40}\$ ]]; }
br_slug_of_url() { case "\${1:-}" in https://github.com/*/*/pull/*) local s="\${1#https://github.com/}"; printf '%s' "\${s%/pull/*}" ;; *) return 1 ;; esac; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
br_pr_field() {
  printf '%s\n' "\$1" >> "$U/prreads"
  local rc; rc=\$(cat "$U/pr-rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || return "\$rc"
  jq -r "\$2 // empty" "$U/pr.json"
}
gh_rest() {
  printf '%s\n' "\$*" >> "$U/ghreads"
  GH_REST_STATUS=200; cat "$U/commit.json"
}
. "$DIR/bin/lib/br/record.sh" || exit 9
. "$DIR/bin/lib/br/ladder.sh" || exit 9
. "$DIR/bin/lib/br/headgate.sh" || exit 9
. "$ZFRAG" || exit 9
[ -r "$FRAG" ] && { . "$FRAG" || exit 9; }
eval "\$(declare -f br_save | sed '1s/^br_save/br_save_real/')"
br_save() { [ -e "$U/save-fail" ] && return 1; br_save_real "\$@"; }
EOF
URF="$U/state/tproj/$CK91.json"
UNIT() { ( . "$T/u-pre.sh"; eval "$1" ) 2>>"$U/err"; }
UHOLD() { UNIT "${1:-} prh_gate tproj o-tproj-91 review-changes-requested $PR91 TK-91; echo rc=\$?"; }
# UPR <state> <labels-json> [merged_at]
UPR() { jq -nc --arg s "$1" --argjson l "$2" --arg m "${3:-}" '{state:$s, merged_at:(if $m == "" then null else $m end), head:{sha:"'"$H91"'"}, labels:$l}' > "$U/pr.json"; rm -f "$U/pr-rc"; }
# USEED <jq-filter> — an open record for TK-91, edited by the filter.
USEED() {
  jq -nc --arg u "$PR91" --arg h "$H91" '{project:"tproj",rkey:"tproj-TK-91",rebuilds:0,mechanicals:0,regens:0,fixrounds:0,outcome:"",attempts:[]}' \
    | jq -c --arg u "$PR91" --arg h "$H91" "$1" > "$URF"
  : > "$U/log"; : > "$U/alerts"; : > "$U/ghreads"; : > "$U/prreads"; rm -f "$U/save-fail"
  UPR open "$HOLDLAB"
}
ALERTS() { grep -c 'br-pr-hold-expired:' "$U/alerts"; }

# P2. The PR read fails: held, one 'could not be read' line, record unchanged.
USEED '.'; cp "$URF" "$T/before.json"; echo 75 > "$U/pr-rc"
[ "$(UHOLD)" = rc=1 ] && ok || bad "P2: an unreadable PR is held this tick (got '$(UHOLD)')"
[ "$(grep -c 'could not be read' "$U/log")" -ge 1 ] && cmp -s "$URF" "$T/before.json" && ok \
  || bad "P2: one 'could not be read' line, nothing written (log: $(cat "$U/log"))"
# P2a. An absent PR (44) is the ladder's own case: rc 0.
USEED '.'; echo 44 > "$U/pr-rc"
[ "$(UHOLD)" = rc=0 ] && ok || bad "P2a: an absent PR is not held (got '$(UHOLD)')"

# P5. Not held: no labels; a partial match; another case; closed; merged; another label.
P5() { USEED '.'; UPR "$2" "$3" "${4:-}"; local got; got=$(UHOLD)
  [ "$got" = rc=0 ] && ok || bad "$1: want rc=0, got '$got' (log: $(cat "$U/log"))"
  grep -q 'PR HOLD' "$U/log" && bad "$1: no PR HOLD line" || ok; }
P5 P5 open '[]'
P5 P5b open '[{"name":"resolver-hold-off"}]'
P5 P5c open '[{"name":"Resolver-Hold"}]'
P5 P5d closed "$HOLDLAB"
P5 P5e closed "$HOLDLAB" 2026-10-26T10:00:00Z
P5 P5f open '[{"name":"do-not-merge"},{"name":"hold"}]'
# P5g. The field absent (the shape of a PR body other suites serve): not held.
USEED '.'; jq -nc '{state:"open", head:{sha:"x"}}' > "$U/pr.json"
[ "$(UHOLD)" = rc=0 ] && ok || bad "P5g: a PR object with no labels field is not held"

# P1u. Held on first sight: rc 1, since = now, alerted false, one line.
USEED '.'
[ "$(UHOLD)" = rc=1 ] && ok || bad "P1u: a labelled open PR is held (log: $(cat "$U/log"))"
[ "$(jq -c '.pr_hold' "$URF")" = "{\"url\":\"$PR91\",\"since\":$UNOW,\"alerted\":false}" ] && ok \
  || bad "P1u: pr_hold is {url, since: now, alerted: false} (got $(jq -c .pr_hold "$URF"))"
[ "$(grep -c "PR HOLD — $PR91 carries label resolver-hold (seen since 2026-10-26T.*expires in 86400s) — no fix round, no rung, no close" "$U/log")" = 1 ] && ok \
  || bad "P1u: one hold line with since and expiry (log: $(cat "$U/log"))"

# P6. Expired (since = now - 86400, no knob): processed, alerted written, ONE alert.
USEED ".pr_hold = {url:\$u, since:$((UNOW - 86400)), alerted:false}"
[ "$(UHOLD)" = rc=0 ] && ok || bad "P6: an expired hold is processed again (log: $(cat "$U/log"))"
[ "$(jq -r .pr_hold.alerted "$URF")" = true ] && ok || bad "P6: pr_hold.alerted is written"
[ "$(ALERTS)" = 1 ] && grep -q "br-pr-hold-expired:o/tproj#91:$((UNOW - 86400))" "$U/alerts" && ok \
  || bad "P6: exactly one alert with id br-pr-hold-expired:o/tproj#91:<since> (alerts: $(cat "$U/alerts"))"
grep -q 'PR HOLD EXPIRED' "$U/log" && ok || bad "P6: the log says PR HOLD EXPIRED"
# P6c. The next tick: rc 0, no new alert.
: > "$U/log"
[ "$(UHOLD)" = rc=0 ] && [ "$(ALERTS)" = 1 ] && ok || bad "P6c: an alerted hold is processed with no new alert (alerts $(ALERTS))"
grep -q 'alerted) — processed as normal' "$U/log" && ok || bad "P6c: the line says already alerted (log: $(cat "$U/log"))"
# P6b. One minute short of the TTL: still held, no alert.
USEED ".pr_hold = {url:\$u, since:$((UNOW - 86340)), alerted:false}"
[ "$(UHOLD)" = rc=1 ] && [ "$(ALERTS)" = 0 ] && ok || bad "P6b: 23h59m is still held, no alert (log: $(cat "$U/log"))"
grep -q 'expires in 60s' "$U/log" && ok || bad "P6b: the line says expires in 60s (log: $(cat "$U/log"))"
# P6d. The knob shortens the TTL.
USEED ".pr_hold = {url:\$u, since:$((UNOW - 600)), alerted:false}"
[ "$(UHOLD BR_PR_HOLD_TTL_SECS=600)" = rc=0 ] && [ "$(ALERTS)" = 1 ] && ok || bad "P6d: BR_PR_HOLD_TTL_SECS=600 expires a 600 s hold"
# P6e. A non-number TTL: the fallback 86400, said once.
USEED '.'
[ "$(UHOLD BR_PR_HOLD_TTL_SECS=x)" = rc=1 ] && grep -q "BR_PR_HOLD_TTL_SECS is 'x'" "$U/log" && ok \
  || bad "P6e: a non-number TTL is the fallback (log: $(cat "$U/log"))"

# P7b. The record's pr_hold is another PR of the ticket: since resets to now, held.
USEED '.pr_hold = {url:"https://github.com/o/tproj/pull/8", since:1000, alerted:true}'
[ "$(UHOLD)" = rc=1 ] && ok || bad "P7b: an inherited hold of another PR does not expire this one"
[ "$(jq -r '.pr_hold.url + " " + (.pr_hold.since|tostring) + " " + (.pr_hold.alerted|tostring)' "$URF")" = "$PR91 $UNOW false" ] && ok \
  || bad "P7b: pr_hold is reset to this PR and now (got $(jq -c .pr_hold "$URF"))"
[ "$(ALERTS)" = 0 ] && ok || bad "P7b: no alert"

# P8. TTL 0: the label is not honoured, one line.
USEED '.'
[ "$(UHOLD BR_PR_HOLD_TTL_SECS=0)" = rc=0 ] && grep -q 'BR_PR_HOLD_TTL_SECS=0' "$U/log" && ok \
  || bad "P8: TTL 0 is not honoured and says so (log: $(cat "$U/log"))"
[ "$(jq -r '.pr_hold // "none"' "$URF")" = none ] && ok || bad "P8: TTL 0 writes nothing"

# P9. The first-sight write fails: held, no alert, nothing written.
USEED '.'; touch "$U/save-fail"
[ "$(UHOLD)" = rc=1 ] && [ "$(ALERTS)" = 0 ] && [ "$(jq -r '.pr_hold // "none"' "$URF")" = none ] && ok \
  || bad "P9: a failed write is held, no alert, nothing written (log: $(cat "$U/log"))"
grep -q 'could not be written' "$U/log" && ok || bad "P9: the line says it could not be written"
# P9b. The expiry mark fails: no alert, held one more tick.
USEED ".pr_hold = {url:\$u, since:$((UNOW - 90000)), alerted:false}"; touch "$U/save-fail"
[ "$(UHOLD)" = rc=1 ] && [ "$(ALERTS)" = 0 ] && ok || bad "P9b: a failed alert mark sends no alert and holds (alerts $(ALERTS))"

# Observe mode: held, the line says so, nothing written.
USEED '.'; cp "$URF" "$T/before.json"
[ "$(UHOLD OBSERVE=1)" = rc=1 ] && cmp -s "$URF" "$T/before.json" && grep -q 'observe mode' "$U/log" && ok \
  || bad "observe: held, nothing written (log: $(cat "$U/log"))"

# P12. A label knob that is not a plain name: the fallback, one line.
USEED '.'; UPR open '[]'
[ "$(UHOLD "BR_PR_HOLD_LABEL='x\" or true'")" = rc=0 ] && grep -q "BR_PR_HOLD_LABEL is 'x\" or true'" "$U/log" && ok \
  || bad "P12: a quoted label knob falls back and an unlabelled PR is not held (log: $(cat "$U/log"); err: $(tail -2 "$U/err"))"
USEED '.'
[ "$(UHOLD "BR_PR_HOLD_LABEL='x\" or true'")" = rc=1 ] && ok || bad "P12: with the fallback, resolver-hold still holds"
# P12b. A custom label knob is honoured, and resolver-hold is then not the label.
USEED '.'; UPR open '[{"name":"mac-fixing"}]'
[ "$(UHOLD BR_PR_HOLD_LABEL=mac-fixing)" = rc=1 ] && ok || bad "P12b: BR_PR_HOLD_LABEL=mac-fixing holds a PR with that label"
USEED '.'
[ "$(UHOLD BR_PR_HOLD_LABEL=mac-fixing)" = rc=0 ] && ok || bad "P12b: with another knob value, resolver-hold does not hold"

# P4. br_abandon itself (the real function, out of the driver): a labelled PR is
#     rc 5 and br_close_pr is never called; an unlabelled one reaches it.
BRAB="$T/br-abandon.sh"
sed -n '/^br_abandon() {/,/^}/p' "$DIR/bin/blocked-resolver.sh" > "$BRAB"
[ -s "$BRAB" ] || bad "P4: br_abandon not found in the driver"
P4PRE="br_is_external() { return 1; }; zr_close_gate() { return 0; }; br_head_gate() { return 0; }
br_close_pr() { printf '%s\n' \"\$1\" >> $U/closes; return 75; }; br_close_facts() { :; }; . $BRAB"
USEED '.'; : > "$U/closes"
OUT=$(UNIT "$P4PRE; br_abandon tproj $CK91 review-changes-requested $PR91 - 'fix cap spent' TK-91; echo rc=\$?")
[ "$OUT" = rc=5 ] && [ ! -s "$U/closes" ] && ok || bad "P4: br_abandon on a labelled PR is rc 5 with no close call (got '$OUT'; closes: $(cat "$U/closes"))"
USEED '.'; UPR open '[]'; : > "$U/closes"
UNIT "$P4PRE; br_abandon tproj $CK91 review-changes-requested $PR91 - 'fix cap spent' TK-91" >/dev/null
[ "$(grep -c . "$U/closes")" = 1 ] && ok || bad "P4: control — an unlabelled PR reaches br_close_pr (closes: $(cat "$U/closes"); log: $(cat "$U/log"))"

# P10. THE HUMAN-PUSH DEFER window with no knob set is 60 minutes (BH-8328's
#      zr_close_gate on a head the ladder was reset to, a red-twice reason).
P10() { # P10 <case> <want-rc> <seconds-ago>
  USEED ".ladder_reset = {url:\$u, from:\"1111111111111111111111111111111111111111\", to:\$h, base:{}}"
  UPR open '[]'
  jq -nc --arg d "$(date -u -d "@$((UNOW - $3))" '+%Y-%m-%dT%H:%M:%SZ')" '{sha:"x", author:{login:"person-fixture"}, commit:{committer:{date:$d}}}' > "$U/commit.json"
  local got; got=$(UNIT "zr_close_gate tproj $CK91 red-twice $PR91; echo rc=\$?")
  [ "$got" = "rc=$2" ] && ok || bad "$1: want rc=$2, got '$got' (log: $(cat "$U/log"))"
}
P10 P10a 5 2000
P10 P10b 5 3599
P10 P10c 0 3600
P10 P10d 0 4000

# P11. The knob rows' defaults are the code fallbacks the cases above proved
#      (P1u/P6/P6b: 86400 and resolver-hold; P10: 3600).
KD="$DIR/catalog/lanes.d/blocked-resolver.knobs.d"
[ "$(jq -r .default "$KD/BR_PR_HOLD_TTL_SECS.json" 2>/dev/null)" = 86400 ] && ok || bad "P11: BR_PR_HOLD_TTL_SECS default 86400"
[ "$(jq -r .default "$KD/BR_PR_HOLD_LABEL.json" 2>/dev/null)" = resolver-hold ] && ok || bad "P11: BR_PR_HOLD_LABEL default resolver-hold"
[ "$(jq -r .default "$KD/BR_HUMAN_PUSH_SETTLE_SECS.json" 2>/dev/null)" = 3600 ] && ok || bad "P11: BR_HUMAN_PUSH_SETTLE_SECS default 3600"

echo "blocked-resolver-pr-hold.bh-8474: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
