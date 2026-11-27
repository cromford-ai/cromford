#!/bin/bash
# tests/br-read-after-change.bh-10198-test.sh — BH-10198: the blocked resolver
# reads a quiet park again only after a change
# (bin/blocked-resolver.d/bh-10198-read-after-change.sh + bin/lib/br/opt/unchanged.sh).
#
# The REAL bin/blocked-resolver.sh runs over a scratch $HARNESS
# (tests/lib/br-repeat-cuts-fixture.sh). The jobs client is a fake that answers
# the wakes feed and the PR record from files under $T/f. No network call: every
# gh call goes to the fixture's gh stub and is recorded in $T/gh.txt.
#
# Each case: run 1 reads the quiet rows and marks them; the ledger epoch is then
# moved 2 hours back (past the 1800 s window, inside the 6 hour backstop); run 2
# is the tick under test.
#   R1  an unchanged park makes 0 GitHub calls (the gate) — and the same tick with
#       the fragment off reads every park again (red-first evidence, measured)
#   R2  a wake (issue, pr, checks) for one park reads that park, only that one
#   R3  a PR record change, or no record row, reads that park, only that one
#   R4  a wakes feed that cannot answer reads every park (today's behavior)
#   R7  the ledger prune keeps a quiet park's line to the backstop
#   R8  an issue-only park (no PR record) is unknown: read past 1800 s
#   R9  inside the 1800 s window: today's skip, 0 record peeks
#   R6  one tick of 40 quiet parks, gate on vs off: the call count, and the
#       resolver's actions are equal
#   R10 a wake whose worker time is before the look on the box clock is seen
#   R11 a job-abandoned park is unknown (a job row makes no wake)
#   R12 the record version is taken before the reads, not after
#
# Run from anywhere: tests/br-read-after-change.bh-10198-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
. "$(dirname "$0")/lib/br-repeat-cuts-fixture.sh" || exit 1
BRF_MODULES="profile unchanged"
brf_setup || { echo "fixture setup failed"; exit 1; }
FRAG=bin/blocked-resolver.d/bh-10198-read-after-change.sh
[ -r "$DIR/$FRAG" ] || bad "$FRAG is missing"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR/$FRAG" "$H/$FRAG" 2>/dev/null || true
for l in bin/lib/pr-snapshot.sh bin/lib/pr-snapshot-wakes.sh bin/lib/pr-record.sh bin/lib/tracker.sh; do
  scratch_install_closure "$l" "$H" >/dev/null 2>&1 || cp "$DIR/$l" "$H/$l"
done

# The fake jobs client. Wakes: $T/f/wakes.json ({"wakes":[...]}), served above
# the `since` id; the summary names o/tproj as fresh with the highest id.
# $T/f/wakes-down makes every wakes path answer nothing (rc 2). Records:
# $T/f/rec-<n>.json is the pr_records row of #<n>; no file = no row.
cat > "$H/bin/jobs-client.sh" <<EOF
jobs_configured() { return 0; }
_jobs_log() { :; }
_jobs_req() {
  printf '_jobs_req %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  local F="$T/f" w="$T/f/wakes.json" since n
  [ -r "\$w" ] || w=/dev/null
  case "\$1 \$2" in
    "GET /api/wakes/summary"*)
      [ -e "\$F/wakes-down" ] && return 2
      jq -nc --arg at "$(ISO 0)" --argjson top "\$(jq -s '[.[0].wakes[]?.id] | max // 0' "\$w" 2>/dev/null || echo 0)" \
        '{repos:[{repo:"o/tproj", n:1, last_at:\$at, kinds:"pr", last_id:\$top}]}'
      return 0 ;;
    "GET /api/wakes?"*)
      [ -e "\$F/wakes-down" ] && return 2
      since=\$(printf '%s' "\$2" | sed -nE 's/.*since=([0-9]+).*/\1/p')
      jq -c --argjson s "\${since:-0}" '{wakes: [(.wakes // [])[] | select(.id > \$s)]}' "\$w" 2>/dev/null || echo '{"wakes":[]}'
      return 0 ;;
    "GET /api/pr-records?"*)
      n=\$(printf '%s' "\$2" | sed -nE 's/.*number=([0-9]+).*/\1/p')
      if [ -r "\$F/rec-\$n.json" ]; then jq -c '{row: ., age_s: 1}' "\$F/rec-\$n.json"; else echo '{"row":null}'; fi
      return 0 ;;
  esac
  return 2
}
job_ticket_abandoned() { printf 'job_ticket_abandoned %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"; return 1; }
job_artifact_feed() { return 0; }
queue_put() { printf 'queue_put %s\n' "\$*" >> "$T/jobs.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
wakes_summary() {
  local resp
  resp=\$(_jobs_req GET "/api/wakes/summary?hours=\${1:-168}") || return 1
  printf '%s' "\$resp" | jq -r '.repos[]? | [ .repo, (.n // "-"), (.last_at // "-"), (.kinds // "-"), (.last_id // "-") ] | @tsv'
}
EOF
export PR_SNAPSHOT_FEED_STALE_S=86400 PR_SNAPSHOT_TTL_S=0

LOOKS="$ST/tproj/.looks"
PARKS="81 82 83 84 85 86"
# PARKSET — six HELD parks with a HOLD comment and a PR record each.
PARKSET() {
  local n
  for n in $PARKS; do
    PRADD "$n"; CROW "$n" 'head-not-reapproved: BLOCK on the head'; HOLDCMT "$n"
    SEED "tproj-TK-$n" '{"outcome":"HELD"}'
    REC "$n" 1
  done
  echo '{"wakes":[]}' > "$T/f/wakes.json"
}
# REC <n> <version> [<refresh>] — the pr_records row of #<n>. A new version
# changes a field the park depends on (its labels); a new refresh moves only
# refreshed_at, which is not a change.
REC() {
  jq -nc --argjson n "$1" --arg h "$(HEAD_OF "$1")" --arg v "v$2" --arg r "2026-11-26T10:00:0${3:-1}Z" \
    '{repo:"o/tproj", number:$n, state:"open", head_sha:$h, labels:[$v], refreshed_at:$r}' > "$T/f/rec-$1.json"
}
# WAKE <id> <kind> <key> [<secs>] — one wake row whose worker time is <secs>
# (default 300) BEFORE the file's clock read: every look of this suite is after
# it on the box clock, as on a box whose clock runs ahead of the worker. Only
# the wake id may say it is new.
WAKE() {
  jq --argjson id "$1" --arg k "$2" --arg y "$3" --arg at "$(ISO "${4:-300}")" \
    '.wakes += [{id:$id, repo:"o/tproj", kind:$k, key:$y, at:$at}]' "$T/f/wakes.json" > "$T/f/wakes.t" && mv "$T/f/wakes.t" "$T/f/wakes.json"
}
# AGE — move every ledger epoch 2 hours back (column 3 only; the mark stays).
AGE() {
  local f
  for f in "$LOOKS"/o-tproj-*; do
    [ -f "$f" ] || continue
    awk -F'\t' -v OFS='\t' -v e="$((NOW - 7200))" '{ $3 = e; print }' "$f" > "$f.t" && mv "$f.t" "$f"
  done
}
CLEARREC() { : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/agent.txt"; }
NISSUE() { NGH "repos/o/tproj/issues/$1([/?]|$)"; }
# READS <n> — GitHub reads of park #<n> past discovery's one pulls/<n> head read.
READS() { echo $(( $(NISSUE "$1") + $(NGH "repos/o/tproj/pulls/$1([/?]|$)") - 1 )); }
# ROWGH — GitHub calls of the park rows (all gh calls but rate_limit and the list).
ROWGH() { grep -cvE '^api rate_limit|pulls\?|repos/o/tproj/pulls( |$)' "$T/gh.txt" 2>/dev/null; }
# RESET — brf_reset plus the wakes mirror, so no wake of an earlier case is seen.
RESET() { brf_reset; scratch_rm "$H/state/pr-snapshot"; }
RUN1() { RESET; PARKSET; TICK; AGE; CLEARREC; }

# ===========================================================================
# R0 — run 1 stores the change mark: the wakes watermark (digits) and the
# record version (a content hash and the head).
# ===========================================================================
RUN1
L=$(cat "$LOOKS/o-tproj-81" 2>/dev/null)
[ "$(cut -f2 <<<"$L")" = held ] && ok || bad "R0: #81's ledger class must be held: '$L' (log: $(LOG | tail -3))"
[[ "$(cut -f4 <<<"$L")" =~ ^[0-9]+$ ]] && ok || bad "R0: #81's ledger must carry the wakes watermark (digits) in column 4: '$L'"
[[ "$(cut -f5 <<<"$L")" =~ ^[0-9a-f]{40}\|$(HEAD_OF 81)$ ]] && ok || bad "R0: #81's ledger must carry '<sha1>|<head>' in column 5: '$L'"

# ===========================================================================
# R1 — an unchanged park makes 0 GitHub calls; with the fragment off the same
# aged parks are read again (red-first evidence, measured in the run).
# ===========================================================================
TICK
ON=$(ROWGH)
for n in $PARKS; do
  [ "$(READS "$n")" = 0 ] && ok || bad "R1: unchanged park #$n must make 0 GitHub reads, got $(READS "$n"): $(grep -E "/$n([/?]|$)" "$T/gh.txt" | head -3)"
done
[ "$(PFIELD unchanged)" = 6 ] && ok || bad "R1: the prof: line must say unchanged=6, got '$(PROF)'"
CLEARREC; BRENV=(BR_OPT_OFF=bh-10198-read-after-change); TICK; BRENV=()
OFF=$(ROWGH)
OFFREADS=0; for n in $PARKS; do OFFREADS=$(( OFFREADS + $(READS "$n") )); done
[ "$OFFREADS" -ge 6 ] && ok || bad "R1 red: with the fragment off the 6 aged parks must be read again, got $OFFREADS reads"
[ "$ON" -lt "$OFF" ] && ok || bad "R1: the gate must make fewer GitHub calls than no gate: on=$ON off=$OFF"

# ===========================================================================
# R2 + R3 + R10 — one tick, six parks, one change each (or none). Every wake
# carries a worker time BEFORE the look on the box clock (R10: the box clock
# 120 s and 300 s ahead of the worker); the wake id alone says it is new.
#   81 a wake on its ticket issue (a RESUME comment)    -> read
#   82 a pr wake (a review, a new commit, a label)      -> read
#   83 a checks wake on its head (CI)                   -> read
#   84 a PR record change with no wake (a self-App echo) -> read
#   85 no record row (the record cannot answer)         -> read: unknown is not quiet
#   86 only refreshed_at moved (a list sync)           -> 0 reads
# ===========================================================================
RUN1
WAKE 1 issue 81 120; WAKE 2 pr 82; WAKE 3 checks "$(HEAD_OF 83)"; REC 84 2; rm -f "$T/f/rec-85.json"; REC 86 1 5
TICK
[ "$(NISSUE 81)" -ge 1 ] && ok || bad "R10: a wake for issue 81 timed 120 s before the look by the box clock must read #81's issue, got $(NISSUE 81)"
[ "$(READS 82)" -ge 1 ] && ok || bad "R2: a pr wake for #82 must read #82, got $(READS 82)"
[ "$(READS 83)" -ge 1 ] && ok || bad "R2: a checks wake on #83's head must read #83, got $(READS 83)"
[ "$(READS 84)" -ge 1 ] && ok || bad "R3: a record change of #84 must read #84, got $(READS 84)"
[ "$(READS 85)" -ge 1 ] && ok || bad "R3: #85 with no record row must be read (unknown is not quiet), got $(READS 85)"
[ "$(READS 86)" = 0 ] && ok || bad "R2: #86 (refreshed_at only) had no change and must make 0 reads, got $(READS 86): $(grep -E '/86([/?]|$)' "$T/gh.txt" | head -3)"

# ===========================================================================
# R4 — the wakes feed cannot answer: every aged park is read, as today.
# ===========================================================================
RUN1; : > "$T/f/wakes-down"; TICK
DOWN=0; for n in $PARKS; do [ "$(READS "$n")" -ge 1 ] && DOWN=$((DOWN + 1)); done
[ "$DOWN" = 6 ] && ok || bad "R4: with no wakes feed all 6 aged parks must be read, got $DOWN"
rm -f "$T/f/wakes-down"

# ===========================================================================
# R9 — inside the 1800 s window the gate asks nothing: today's skip holds, and
# no PR record is peeked (lead review NOTE: up to 600 jobs GETs a tick).
# ===========================================================================
RESET; PARKSET; TICK; CLEARREC; TICK
PEEKS=$(grep -c '/api/pr-records' "$T/jobs.txt" 2>/dev/null)
[ "$PEEKS" = 0 ] && ok || bad "R9: rows inside the 1800 s window must make 0 record peeks, got $PEEKS"
[ "$(PFIELD unchanged)" = 6 ] && ok || bad "R9: the 6 rows inside the window must be skipped, got '$(PROF)'"

# ===========================================================================
# R7 — the ledger prune keeps a quiet park's line to the backstop (lead review
# BLOCK). The prune works on file mtime, so the mtimes are set with touch -d:
# 81..85 are 2 hours old (past 2 x 1800 s, inside the 6 hour backstop), 86 is
# 9 hours old. After the prune 81..85 are still skipped and 86 is gone.
# ===========================================================================
RUN1
for n in $PARKS; do touch -d "@$((NOW - 7200))" "$LOOKS/o-tproj-$n"; done
touch -d "@$((NOW - 32400))" "$LOOKS/o-tproj-86"
touch -d "@$((NOW - 7200))" "$LOOKS/.pruned"
( ST="$ST"; H="$H"; br_count() { :; }
  . "$H/bin/lib/br/opt/unchanged.sh"; . "$H/$FRAG"
  _br_uc_prune "$LOOKS" "$NOW" )
for n in 81 82 83 84 85; do
  [ -f "$LOOKS/o-tproj-$n" ] && ok || bad "R7: the prune must keep #$n's line (2 hours old, inside the backstop)"
done
[ -f "$LOOKS/o-tproj-86" ] && bad "R7: the prune must remove #86's line (9 hours old, past the backstop)" || ok
TICK
for n in 81 82 83 84 85; do
  [ "$(READS "$n")" = 0 ] && ok || bad "R7: #$n must still be skipped after the prune, got $(READS "$n") reads"
done

# ===========================================================================
# R8 — an issue-only park (no PR, so no record version) is unknown, not quiet:
# a RESUME through the App identity or a label change makes no wake. Past the
# 1800 s window it is read (lead review BLOCK).
# ===========================================================================
R8=$( ( ST="$ST"; H="$H"; OUT=""
  br_count() { :; }; br_cap_key() { printf 'tproj-TK-90'; }
  . "$H/bin/lib/br/opt/unchanged.sh"; . "$H/$FRAG"
  prs_wake_seen() { return 1; }; prs_changed() { return 0; }; pr_record_peek() { return 1; }
  trk_gh_issue_number() { printf '90\n'; }; tracker_kind() { echo github-issues; }
  _br_rac_load() { return 0; }
  br_opt_unchanged_fp() { printf 'fp90'; }
  OUT="due=$(br_rac_due tproj TK-90 - 0 - held)"
  mkdir -p "$ST/tproj/.looks"
  printf 'fp90\theld\t%s\t0\t-\n' "$((NOW - 7200))" > "$ST/tproj/.looks/tproj-TK-90"
  if br_opt_unchanged_skip tproj tproj-TK-90 needs-human - - TK-90 queue; then OUT="$OUT skip=yes"; else OUT="$OUT skip=no"; fi
  printf '%s' "$OUT" ) )
[ "${R8%% *}" = due=unknown ] && ok || bad "R8: an issue-only park must answer unknown, got '$R8'"
[ "${R8##* }" = skip=no ] && ok || bad "R8: an issue-only park past 1800 s must be read, not skipped, got '$R8'"

# Shared stubs of the unit cases R11 and R12: the mirror is complete and fresh
# with watermark 0 and no wake; the record row is $T/unit-row.json.
UNIT_STUBS() {
  br_count() { :; }
  . "$H/bin/lib/br/opt/unchanged.sh"; . "$H/$FRAG"
  mkdir -p "$T/unit-prs"; echo 0 > "$T/unit-prs/wakes.wm"; : > "$T/unit-prs/changed.tsv"
  _br_rac_load() { return 0; }; prs_changed() { return 0; }; prs_feed_fresh() { return 0; }
  _prs_dir() { printf '%s' "$T/unit-prs"; }; prs_wake_seen() { return 1; }
  pr_record_peek() { cat "$T/unit-row.json"; }
  trk_gh_issue_number() { printf '%s\n' "${2##*-}"; }; tracker_kind() { echo github-issues; }
}
UROW() { # UROW <n> <label> <refresh> — the unit record row
  jq -nc --arg h "$(HEAD_OF "$1")" --arg l "$2" --arg r "2026-11-26T10:00:0$3Z" \
    '{state:"open", head_sha:$h, labels:[$l], refreshed_at:$r}' > "$T/unit-row.json"
}

# ===========================================================================
# R11 — a job-abandoned park with a PR is unknown: a newer job row makes no
# wake and moves no record (lead review NOTE b). The same row as `held` is quiet.
# ===========================================================================
UROW 91 a 1
R11=$( ( ST="$ST"; H="$H"; UNIT_STUBS; U=https://github.com/o/tproj/pull/91
  RV=$(br_rac_version "$U")
  printf 'held=%s abandoned=%s' "$(br_rac_due tproj TK-91 "$U" 0 "$RV" held)" "$(br_rac_due tproj TK-91 "$U" 0 "$RV" job-abandoned)" ) )
[ "${R11%% *}" = held=quiet ] && ok || bad "R11 setup: the held park must answer quiet, got '$R11'"
[ "${R11##* }" = abandoned=unknown ] && ok || bad "R11: a job-abandoned park must answer unknown, got '$R11'"

# ===========================================================================
# R12 — the record version is the one before the GitHub reads (lead review
# NOTE a): a record change during the reads (a self-App echo, no wake) must not
# be folded into the mark.
# ===========================================================================
UROW 92 a 1
R12=$( ( ST="$ST"; H="$H"; UNIT_STUBS; U=https://github.com/o/tproj/pull/92
  command -v br_rac_pre >/dev/null 2>&1 && br_rac_pre tproj tproj-TK-92 "$U"
  A=$(br_rac_version "$U")
  UROW 92 b 2
  br_opt_unchanged_fp() { printf fp92; }
  br_opt_unchanged_mark held tproj tproj-TK-92 head-not-reapproved "$U" - TK-92 conductor tproj-TK-92
  printf '%s %s' "${A:-none}" "$(cut -f5 "$ST/tproj/.looks/tproj-TK-92" 2>/dev/null)" ) )
[ "${R12%% *}" != none ] && [ "${R12%% *}" = "${R12##* }" ] && ok \
  || bad "R12: the ledger must carry the version from before the reads: '$R12' (before after)"

# ===========================================================================
# R6 — one tick of 40 quiet parks aged past 1800 s, gate on, then off: the
# GitHub calls, and the resolver's actions (the tick line's rung counters, the
# jobs queue writes, the model calls and the bytes of every state record),
# which must be equal.
# ===========================================================================
PARKS40=$(seq 101 140 | tr '\n' ' ')
ACTIONS() {
  LOG | grep ' tick: ' | tail -1 | grep -oE ' (candidates|carried|mechanical|families|llm_rungs|rungs|rebuilds)=[^ ]*' | tr -d '\n'
  printf ' queue=%s agent=%s state=' "$(grep -c queue_put "$T/jobs.txt")" "$(grep -c . "$T/agent.txt")"
  cat "$ST"/tproj/tproj-TK-*.json 2>/dev/null | sha1sum | cut -c1-12
}
RESET
for n in $PARKS40; do
  PRADD "$n"; CROW "$n" 'head-not-reapproved: BLOCK on the head'; HOLDCMT "$n"
  SEED "tproj-TK-$n" '{"outcome":"HELD"}'; REC "$n" 1
done
echo '{"wakes":[]}' > "$T/f/wakes.json"
TICK; AGE; CLEARREC
TICK
ON40=$(ROWGH); ACT_ON=$(ACTIONS); R40=0
for n in $PARKS40; do R40=$(( R40 + $(READS "$n") )); done
CLEARREC; BRENV=(BR_OPT_OFF=bh-10198-read-after-change); TICK; BRENV=()
OFF40=$(ROWGH); ACT_OFF=$(ACTIONS)
[ "$R40" = 0 ] && ok || bad "R6: 40 unchanged parks must make 0 GitHub reads with the gate, got $R40"
[ "$ON40" -lt "$OFF40" ] && ok || bad "R6: the gate must make fewer GitHub calls: on=$ON40 off=$OFF40"
[ -n "$ACT_ON" ] && [ "$ACT_ON" = "$ACT_OFF" ] && ok || bad "R6: the actions must be equal with the gate on and off: on='$ACT_ON' off='$ACT_OFF'"
echo "R6 one tick, 40 quiet parks aged past 1800 s: GitHub calls with the gate = $ON40, without = $OFF40, saved = $((OFF40 - ON40)); actions on='$ACT_ON' off='$ACT_OFF'"

echo "br-read-after-change: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
