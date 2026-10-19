#!/bin/bash
# tests/deploy-train-rollback-dedupe.bh-7506-test.sh — the deploy train opens
# at most one automatic rollback PR per failed target (BH-7506).
#
# WHAT IS UNDER TEST. The real bin/deploy-train.sh, with DEPLOY_ROLLBACK=on, a
# failing verify, and the gate in bin/lib/deploy-rollback-guard.sh (installed
# with its closure). A gh shim answers `pr create` (numbers from 901) and the
# REST reads the gate makes: the open-PR list (paged), the close comment, the
# PATCH and its re-read. A PR the shim created is replayed in the open list.
#   D1-D6  dedupe: same target (ledger row, body line, legacy body, same
#          reverted set, page 2) is `dup`; the near misses are not.
#   R1     the opened PR body carries `Rollback-Target: <full sha>`, and the
#          ledger row `deploy_train_rollback p@<sha>` is `opened`.
#   C1-C3  cap; S1-S3 age guard; U1-U2 unknown list + gh_auth_reset;
#   W1-W3  sweep of stale harness rollback PRs; P1 revert conflict; K1-K3 knob parse.
# Run from anywhere: bash tests/deploy-train-rollback-dedupe.bh-7506-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=2 TRAIN_POLL_SECS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_AUTHOR_DATE=2026-10-13T14:00:00Z GIT_COMMITTER_DATE=2026-10-13T14:00:00Z
unset DEPLOY_ROLLBACK_MAX_OPEN DEPLOY_ROLLBACK_MAX_AGE_MIN GH_TOKEN
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls"
# Three commits with real content, so a revert of one or two of them applies.
git init -q "$T/repo" && (cd "$T/repo" && echo zero > f && git add f && git commit -q -m zero \
  && echo one > f && git commit -q -am one && echo two > f && git commit -q -am two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin HEAD:main \
  && git fetch -q origin)
TARGET=$(git -C "$T/repo" rev-parse HEAD); MID=$(git -C "$T/repo" rev-parse HEAD~1)
ROOT0=$(git -C "$T/repo" rev-parse HEAD~2)
CT=$(git -C "$T/repo" show -s --format=%ct HEAD)
T8=${TARGET:0:8}
# A different full sha with the same 8-char prefix as TARGET (D3b).
TWIN="${TARGET:0:8}$(printf '0%.0s' {1..32})"; [ "$TWIN" = "$TARGET" ] && TWIN="${TARGET:0:8}$(printf '1%.0s' {1..32})"
OTHER=$(printf 'a%.0s' {1..40})
export DEPLOY_TRAIN_REPO_DIR="$T/repo"

# ── stubs (written BEFORE the closure install, which never clobbers them) ────
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in repo) echo "org/repo" ;; *) exit 1 ;; esac
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$HARNESS/calls/beat"
SH
printf '#!/bin/bash\nexit 0\n' > "$T/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/merge-queue.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in */version) printf '{"sha":"%s"}' "$(cat "$HARNESS/live")"; exit 0 ;; esac; done
exit 0
SH
# gh: `pr create` opens a PR and replays it in the open list; `api -i` is gh_rest.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
if [ "${1:-} ${2:-}" = "pr create" ]; then
  n=$(( $(cat "$HARNESS/prnum" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$HARNESS/prnum"
  head=""; bf=""; prev=""
  for a in "$@"; do
    [ "$prev" = -H ] && head="$a"; [ "$prev" = --body-file ] && bf="$a"; prev="$a"
  done
  if [ -n "$bf" ] && [ "$bf" != - ]; then cp "$bf" "$HARNESS/calls/body-$n"; else cat > "$HARNESS/calls/body-$n"; fi
  jq -nc --argjson n "$n" --arg h "$head" --rawfile b "$HARNESS/calls/body-$n" \
    --arg c "$(date -u -d "@$DEPLOY_ROLLBACK_NOW" '+%Y-%m-%dT%H:%M:%SZ')" \
    '{number:$n, html_url:("https://github.com/org/repo/pull/"+($n|tostring)), head:{ref:$h}, body:$b, created_at:$c}' \
    >> "$HARNESS/open-prs.jsonl"
  echo "https://github.com/org/repo/pull/$n"; exit 0
fi
if [ "${1:-} ${2:-}" = "api -i" ]; then
  m="$4"; p="$5"; page=1; prev=""
  for a in "$@"; do case "$prev $a" in "-F page="*) page="${a#page=}" ;; esac; prev="$a"; done
  case "$m $p" in
    "GET repos/org/repo/pulls")
      [ -f "$HARNESS/list-500" ] && { printf 'HTTP/2 500\r\n\r\n{}\n'; exit 1; }
      printf 'HTTP/2 200\r\n\r\n'
      if [ -s "$HARNESS/open-prs.jsonl" ]; then
        jq -sc --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$HARNESS/open-prs.jsonl"
      else echo '[]'; fi ;;
    "POST repos/org/repo/issues/"*/comments)
      echo "comment $p" >> "$HARNESS/calls/rest"; printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
    "PATCH repos/org/repo/pulls/"*)
      echo "close $p $*" >> "$HARNESS/calls/rest"; echo "${p##*/}" >> "$HARNESS/closed"
      printf 'HTTP/2 200\r\n\r\n{"state":"closed"}\n' ;;
    "GET repos/org/repo/pulls/"*)
      if grep -qx "${p##*/}" "$HARNESS/closed" 2>/dev/null; then
        printf 'HTTP/2 200\r\n\r\n{"state":"closed","merged_at":null}\n'
      else printf 'HTTP/2 200\r\n\r\n{"state":"open","merged_at":null}\n'; fi ;;
    *) printf 'HTTP/2 404\r\n\r\n{}\n'; exit 1 ;;
  esac
fi
exit 0
SH
# The coordination client: a ledger that answers what was put (rc 1 when the
# worker is down), settings from a fixture file, and the auth arm/disarm pair.
cat > "$T/bin/jobs-client.sh" <<'SH'
setting_get() {
  local v
  [ -f "$HARNESS/worker-down" ] && return 1
  v=$(awk -F'\t' -v k="${1:-}" '$1==k {v=$2} END{print v}' "$HARNESS/settings" 2>/dev/null)
  [ -n "$v" ] || return 2
  printf '%s' "$v"
}
job_ledger_put() {
  [ -f "$HARNESS/worker-down" ] && return 1
  printf '%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "$HARNESS/calls/ledger"
}
job_ledger_row() {
  local r
  [ -f "$HARNESS/worker-down" ] && return 1
  r=$(awk -F'\t' -v k="${1:-}" -v key="${2:-}" '$1==k && $2==key {r=$3"\t"$4} END{print r}' "$HARNESS/calls/ledger" 2>/dev/null)
  [ -n "$r" ] || return 2
  jq -nc --arg s "${r%%	*}" --arg d "${r#*	}" '{status:$s, detail:$d}'
}
job_ledger_get() {
  local s
  [ -f "$HARNESS/worker-down" ] && return 1
  s=$(awk -F'\t' -v k="${1:-}" -v key="${2:-}" '$1==k && $2==key {s=$3} END{print s}' "$HARNESS/calls/ledger" 2>/dev/null)
  [ -n "$s" ] || return 2
  printf '%s' "$s"
}
deploy_queue_rows_on() { return 1; }
gh_auth_for() { echo "for ${1:-}" >> "$HARNESS/calls/auth"; return 0; }
gh_auth_reset() { echo reset >> "$HARNESS/calls/auth"; return 0; }
SH
scratch_install_closure bin/lib/deploy-rollback-guard.sh "$T" >/dev/null \
  || echo "note: bin/lib/deploy-rollback-guard.sh closure not installed"
# The real auth lib would replace the stubs above when the train sources it.
rm -f "$T/bin/lib/gh-app-auth.sh" "$T/bin/lib/gh-limit-logger.sh"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=on\n' > "$T/env/p.env"

iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
enqueue() { # enqueue <sha> [age_s] — the mtime sets the batch order (`ls -tr`)
  local e=$(( $(date +%s) - ${2:-1800} ))
  printf '%s -\n' "$1" > "$T/state/deploy-queue/p/$e-${1:0:8}"
  touch -d "@$e" "$T/state/deploy-queue/p/$e-${1:0:8}"
}
addpr() { # addpr <n> <head> <body> <created epoch>
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --arg c "$(iso "$4")" \
    '{number:$n, html_url:("https://github.com/org/repo/pull/"+($n|tostring)), head:{ref:$h}, body:$b, created_at:$c}' \
    >> "$T/open-prs.jsonl"
}
hbody() { # hbody <target line or -> <failed-to-serve sha> <reverted shas...>
  local tl="$1" fs="$2"; shift 2
  printf 'Automatic rollback (deploy train, per the operator 2026-07-28): production failed to serve %s after the batch below merged. Reverting to restore last known-good.\n\nReverted: %s \n' "${fs:0:8}" "$*"
  [ "$tl" = - ] || printf 'Rollback-Target: %s\n' "$tl"
}
setk() { printf '%s\t%s\n' "$1" "$2" >> "$T/settings"; }
reset() {
  rm -rf "$T/calls" "$T/worker-down" "$T/list-500" "$T/prnum" "$T/open-prs.jsonl" "$T/closed" "$T/settings" "$T/state/merge-queue"
  rm -f "$T/state/deploy-queue/p/"* "$T/logs/"*
  mkdir -p "$T/calls"; : > "$T/settings"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/heads/rollback | while read -r r; do
    git -C "$T/origin.git" update-ref -d "$r"; done
  printf '%s' "$ROOT0" > "$T/live"
  export DEPLOY_ROLLBACK_NOW=$(( CT + 1800 ))
}
drop_rollback_branches() {
  git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/heads/rollback | while read -r r; do
    git -C "$T/origin.git" update-ref -d "$r"; done
}
run() { "$SRC/bin/deploy-train.sh" p >/dev/null 2>&1; }
cnt() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1"; else echo 0; fi; }
creates() { cnt "$T/calls/gh" '^pr create'; }
beats() { cnt "$T/calls/beat"; }
rbrow() { awk -F'\t' -v k="p@$1" '$1=="deploy_train_rollback" && $2==k' "$T/calls/ledger" 2>/dev/null | tail -1; }
logl() { cat "$T/logs/deploy-train.log" 2>/dev/null; }
skipped() { cnt "$T/logs/deploy-train.log" "rollback skipped ($1)"; }

# D1 (THE REPRO). Two runs on the same failing target open exactly one PR.
reset; enqueue "$TARGET"
run
[ "$(creates)" = 1 ] && ok || bad "D1 precondition: run 1 opens one rollback PR ($(logl | tail -3))"
drop_rollback_branches; run
[ "$(creates)" = 1 ] && ok || bad "D1: two runs on one target must open exactly 1 PR (got $(creates))"
[ "$(skipped dup)" = 1 ] && ok || bad "D1: run 2 logs one 'rollback skipped (dup)' line ($(logl | tail -2))"
[ "$(beats)" = 1 ] && ok || bad "D1: run 2 sends no beat (beats: $(beats))"
R=$(rbrow "$TARGET")
[ "$(cut -f3 <<<"$R")" = opened ] && ok || bad "D1: ledger row deploy_train_rollback p@<target> opened (got: $R)"
jq -e '.pr==901 and .url=="https://github.com/org/repo/pull/901"' >/dev/null 2>&1 <<<"$(cut -f4 <<<"$R")" \
  && ok || bad "D1: row detail names PR 901 ($(cut -f4 <<<"$R"))"
[ "$(awk -F'\t' '$1=="deploy_train_rollback"' "$T/calls/ledger" | grep -c .)" = 1 ] && ok || bad "D1: one rollback row, not one per run"
# R1. The body carries the full target line.
grep -qx "Rollback-Target: $TARGET" "$T/calls/body-901" 2>/dev/null && ok || bad "R1: body carries Rollback-Target: <full sha>"
# U2 (dup exit). gh_auth_reset ran on the dup exit as well as on run 1.
[ "$(cnt "$T/calls/auth" '^reset$')" = 2 ] && ok || bad "U2: gh_auth_reset on the open and the dup exit ($(paste -sd, "$T/calls/auth" 2>/dev/null))"

# D2. The ledger is down; run 1's PR body line in the open list still dedupes.
reset; enqueue "$TARGET"; run
touch "$T/worker-down"; drop_rollback_branches; run
[ "$(creates)" = 1 ] && ok || bad "D2: ledger down, the open PR's Rollback-Target line is a dup (creates $(creates))"
logl | grep -q "rollback skipped (dup): open PR #901 names target $T8" && ok || bad "D2: dup reason names PR #901 ($(logl | tail -1))"

# D3. A legacy body (no Rollback-Target line) that names the 8-char target.
reset; enqueue "$TARGET"; addpr 700 rollback/202610131403 "$(hbody - "$TARGET" "$TARGET")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 0 ] && [ "$(skipped dup)" = 1 ] && ok || bad "D3: legacy 'failed to serve <t8>' body is a dup ($(logl | tail -1))"
# D3b. A Rollback-Target of a different sha with the same prefix is NOT ours.
reset; enqueue "$TARGET"; setk deploy_train.rollback_max_open.p 2
addpr 700 rollback/202610131403 "$(hbody "$TWIN" "$TWIN" "$OTHER")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 1 ] && ok || bad "D3b: same prefix, other full sha is not a dup ($(logl | tail -1))"

# D4. The same reverted set in another order is a dup; a strict subset is not.
reset; enqueue "$MID" 1900; enqueue "$TARGET" 1800
addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$TARGET" "$MID")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 0 ] && logl | grep -q "rollback skipped (dup): open PR #700 reverts the same" && ok || bad "D4: same Reverted set is a dup ($(logl | tail -1))"
reset; enqueue "$MID" 1900; enqueue "$TARGET" 1800; setk deploy_train.rollback_max_open.p 2
addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$MID")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 1 ] && ok || bad "D4: a strict subset of the batch is not a dup ($(logl | tail -1))"

# D5. The matching PR is the 101st (page 2 of the list).
reset; enqueue "$TARGET"
for i in $(seq 1 100); do addpr "$i" "ticket/bh-$i" "fixture body $i" "$DEPLOY_ROLLBACK_NOW"; done
addpr 700 rollback/202610131403 "$(hbody "$TARGET" "$TARGET" "$TARGET")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 0 ] && logl | grep -q "open PR #700 names target" && ok || bad "D5: a match on page 2 is a dup ($(logl | tail -1))"

# D6. Not ours: a non-rollback head with the marker, a rollback/ head without
# it, the marker in prose on another head. None counts; the train opens.
reset; enqueue "$TARGET"
addpr 701 ticket/rollback-fix "$(hbody "$TARGET" "$TARGET" "$TARGET")" "$DEPLOY_ROLLBACK_NOW"
addpr 702 rollback/x "a human revert of $TARGET" "$DEPLOY_ROLLBACK_NOW"
addpr 703 docs/notes "We quote it: Automatic rollback (deploy train ... $TARGET" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 1 ] && ok || bad "D6: none of the look-alikes is ours, the train opens ($(logl | tail -1))"

# C1. Over the cap: one open harness PR for another target, max 1.
reset; enqueue "$TARGET"; addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$OTHER")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 0 ] && ok || bad "C1: over the cap opens 0 PRs"
[ "$(beats)" = 1 ] && ok || bad "C1: over the cap sends 1 beat (got $(beats))"
jq -e --arg k "rollback-cap:p:$T8" '.severity=="critical" and .akey==$k and (.line|startswith("DEPLOY TRAIN:"))' \
  >/dev/null 2>&1 < "$T/calls/beat" && ok || bad "C1: beat is critical, akey rollback-cap:p:<t8> ($(cat "$T/calls/beat" 2>/dev/null))"
[ "$(cut -f3 <<<"$(rbrow "$TARGET")")" = capped ] && ok || bad "C1: row capped ($(rbrow "$TARGET"))"
logl | grep -q "rollback skipped (cap): 1 open >= max 1" && ok || bad "C1: log line ($(logl | tail -1))"
# C2. The next run on the same target sends no second beat.
run
[ "$(beats)" = 1 ] && [ "$(creates)" = 0 ] && ok || bad "C2: second run sends 0 beats (got $(beats))"
# C3. A settings row raises the cap.
reset; enqueue "$TARGET"; setk deploy_train.rollback_max_open.p 2
addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$OTHER")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(creates)" = 1 ] && ok || bad "C3: max_open.p=2 with 1 open opens ($(logl | tail -1))"

# S1. The batch is 121 minutes old: no revert, one beat, row stale.
reset; enqueue "$TARGET"; export DEPLOY_ROLLBACK_NOW=$(( CT + 121*60 ))
run
[ "$(creates)" = 0 ] && ok || bad "S1: a stale target opens 0 PRs"
[ "$(beats)" = 1 ] && jq -e --arg k "rollback-stale:p:$T8" '.akey==$k' >/dev/null 2>&1 < "$T/calls/beat" \
  && ok || bad "S1: one beat, akey rollback-stale:p:<t8> ($(cat "$T/calls/beat" 2>/dev/null))"
[ "$(cut -f3 <<<"$(rbrow "$TARGET")")" = stale ] && ok || bad "S1: row stale ($(rbrow "$TARGET"))"
logl | grep -q "rollback skipped (stale): batch age 121m > 120m" && ok || bad "S1: log line ($(logl | tail -1))"
run
[ "$(beats)" = 1 ] && ok || bad "S2: second run on the stale target sends 0 beats (got $(beats))"
[ "$(cnt "$T/calls/auth" '^reset$')" = 2 ] && ok || bad "U2: gh_auth_reset on the stale and the dup exit"
# S3. Exactly 120 minutes is not stale.
reset; enqueue "$TARGET"; export DEPLOY_ROLLBACK_NOW=$(( CT + 120*60 ))
run
[ "$(creates)" = 1 ] && ok || bad "S3: exactly 120m is not stale ($(logl | tail -1))"

# U1. The open-PR list does not answer: fail closed, one beat, no row.
reset; enqueue "$TARGET"; touch "$T/list-500"
run
[ "$(creates)" = 0 ] && ok || bad "U1: an unanswered list opens 0 PRs"
[ "$(beats)" = 1 ] && jq -e --arg k "rollback-unknown:p:$T8" '.akey==$k' >/dev/null 2>&1 < "$T/calls/beat" \
  && ok || bad "U1: one beat, akey rollback-unknown:p:<t8> ($(cat "$T/calls/beat" 2>/dev/null))"
[ -z "$(rbrow "$TARGET")" ] && ok || bad "U1: no ledger row on unknown ($(rbrow "$TARGET"))"
[ "$(skipped unknown)" = 1 ] && ok || bad "U1: log line ($(logl | tail -1))"
[ "$(cnt "$T/calls/auth" '^reset$')" = 1 ] && ok || bad "U2: gh_auth_reset on the unknown exit"
# U2 (cap exit).
reset; enqueue "$TARGET"; addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$OTHER")" "$DEPLOY_ROLLBACK_NOW"
run
[ "$(cnt "$T/calls/auth" '^reset$')" = 1 ] && ok || bad "U2: gh_auth_reset on the cap exit"

# W1. A harness rollback PR 121 minutes old is swept, which frees the cap.
reset; enqueue "$TARGET"; mkdir -p "$T/state/merge-queue/p"; touch "$T/state/merge-queue/p/700"
addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$OTHER")" $(( DEPLOY_ROLLBACK_NOW - 121*60 ))
run
grep -q "^comment repos/org/repo/issues/700/comments$" "$T/calls/rest" 2>/dev/null && ok || bad "W1: close comment on PR 700 ($(cat "$T/calls/rest" 2>/dev/null))"
grep -q "^close repos/org/repo/pulls/700 .*state=closed" "$T/calls/rest" 2>/dev/null && ok || bad "W1: PATCH pulls/700 state=closed"
[ ! -e "$T/state/merge-queue/p/700" ] && ok || bad "W1: merge-queue marker removed"
[ "$(cut -f3 <<<"$(rbrow "$OTHER")")" = closed ] && ok || bad "W1: the swept PR's target row is closed ($(rbrow "$OTHER"))"
logl | grep -q "rollback swept PR #700 (age 121m > 120m)" && ok || bad "W1: sweep log line ($(logl | tail -2))"
[ "$(creates)" = 1 ] && ok || bad "W1: a swept PR does not count toward the cap ($(logl | tail -1))"
# W2. 119 minutes old, and a non-harness rollback/ head 300 minutes old: kept.
reset; enqueue "$TARGET"
addpr 700 rollback/202610131403 "$(hbody "$OTHER" "$OTHER" "$OTHER")" $(( DEPLOY_ROLLBACK_NOW - 119*60 ))
addpr 701 rollback/x "a human revert" $(( DEPLOY_ROLLBACK_NOW - 300*60 ))
run
[ ! -s "$T/calls/rest" ] && ok || bad "W2: no comment or close on a fresh or a foreign PR ($(cat "$T/calls/rest" 2>/dev/null))"
[ "$(skipped cap)" = 1 ] && ok || bad "W2: the kept harness PR still counts toward the cap ($(logl | tail -1))"
# W3. 21 stale harness PRs: 20 closes this run, and the log says 1 is left.
reset; enqueue "$TARGET"
for i in $(seq 1 21); do
  addpr $(( 700 + i )) "rollback/2026101314$(printf '%02d' "$i")" "$(hbody "$OTHER" "$OTHER" "$OTHER")" $(( DEPLOY_ROLLBACK_NOW - 3*86400 ))
done
run
[ "$(cnt "$T/calls/rest" '^close ')" = 20 ] && ok || bad "W3: at most 20 closes in one run (got $(cnt "$T/calls/rest" '^close '))"
logl | grep -q "1 left" && ok || bad "W3: the log says how many are left ($(logl | grep swept | tail -1))"
[ "$(creates)" = 0 ] && ok || bad "W3: the stale PR left open still counts toward the cap"

# P1. The gate says open but the revert conflicts: the prep-failed path is
# unchanged (one escalation beat, no PR, no opened row).
reset; enqueue "$TARGET" 1900; enqueue "$MID" 1800
run
logl | grep -q "rollback prep failed (partial)" && ok || bad "P1: a conflicting revert still escalates ($(logl | tail -1))"
[ "$(creates)" = 0 ] && [ "$(beats)" = 1 ] && [ -z "$(rbrow "$TARGET")" ] && ok || bad "P1: no PR, one beat, no row"

# K1. No row, no env: max_open 1, max_age 120.
reset; enqueue "$TARGET"; run
logl | grep -q "rollback guard: max_open=1 max_age_min=120" && ok || bad "K1: defaults 1 / 120 ($(logl | grep 'rollback guard' | tail -1))"
# K2. A bad value: the default and one log line.
reset; enqueue "$TARGET"; setk deploy_train.rollback_max_open.p abc; setk deploy_train.rollback_max_age_min 1.5
run
logl | grep -q "rollback guard: max_open=1 max_age_min=120" && ok || bad "K2: bad values fall back to defaults"
[ "$(cnt "$T/logs/deploy-train.log" 'bad value')" = 2 ] && ok || bad "K2: one log line per bad value ($(logl | grep 'bad value'))"
# K2b. No row: the env value is used.
reset; enqueue "$TARGET"; DEPLOY_ROLLBACK_MAX_AGE_MIN=200 "$SRC/bin/deploy-train.sh" p >/dev/null 2>&1
logl | grep -q "max_age_min=200" && ok || bad "K2b: env fallback when there is no row"
# K3. max_open 0 caps with 0 open.
reset; enqueue "$TARGET"; setk deploy_train.rollback_max_open.p 0
run
[ "$(creates)" = 0 ] && logl | grep -q "rollback skipped (cap): 0 open >= max 0" && ok || bad "K3: max 0 caps with 0 open ($(logl | tail -1))"

echo "deploy-train-rollback-dedupe.bh-7506: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
