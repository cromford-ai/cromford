#!/bin/bash
# tests/data-lane-rereview.bh-6467-test.sh — a review that blocks only on an
# unapplied data-lane migration keeps its branch as a draft PR, and the human
# step re-reviews that same head after a prod probe (BH-6467).
#
# THE DEFECT. TK-165, TK-166 and TK-52 (project-6-os) ended REVIEW_BLOCKED
# whose only BLOCK was `DATA_LANE: prisma/sql/<file>.sql`. LENS_REFUSE wrote
# REVIEW_BLOCKED and opened no PR, so the ticket had no owner and
# bin/orphan-reconcile.sh launched a fresh full build after its grace.
#
# Every case drives a production entry point:
#   A1   LENS_REFUSE (cut from the flattened pipeline, as
#        tests/review-needs-human.bh-3444-test.sh does) on a data-lane-only
#        review opens ONE draft PR, labels it data-lane-pending and writes the
#        marker; RESULT and rc 6 are unchanged; the branch stays on origin.
#   A1b  an open PR on the branch is adopted: no create, the label goes on it.
#   A1c  the reviewed head is not on origin: no PR, no marker.
#   A1d  the create fails: no marker, one ALERTS line, RESULT unchanged.
#   A4   DATA_LANE + a code BLOCK: no PR, no marker (today's behaviour).
#   A4b  data-lane-only review, but the security lens blocked: no PR.
#   A2   the REAL bin/review-rescue.sh on the A1 record, a person's
#        HUMAN-STEP-DONE naming the file, the ledger has the row: one probe,
#        one re-review of the marker's head, then `gh pr ready` and the label
#        DELETE, RESULT PR_CREATED <draft url>, no PR create, no build.
#   A2b  HUMAN-STEP-DONE that does not name the file: no probe, no review.
#   A2c  `gh pr ready` fails: one ALERTS line naming the url, no "ready" claim.
#   A3   the ledger has no row: no review, ONE ticket comment naming the file;
#        a second tick posts no second comment and spends no attempt.
#   A3b  the status route answers 500: no review, no comment, no attempt, no
#        alert inside the window, and a second tick says nothing new.
#   A3c  the status route answers 401 after HUMAN-STEP-DONE: one ALERTS line
#        naming the token at once; a second tick adds none (B1).
#   A3d  the ledger has no row 25 h after HUMAN-STEP-DONE: one ALERTS line.
#   W1   no done comment, the draft is 25 h old: one ALERTS line; a second
#        tick adds none; RESCUE_DATA_LANE_WAIT_ALERT_H=0 gives none.
#   P1   bin/pr-owner-sweep.sh: a draft labelled data-lane-pending is PARKED.
#   R1   bin/blocked-resolver.sh: the record offered as rescue-giving-up is
#        held (no rebuild); R2 with RESCUE_HUMAN_STEP=0 the rung runs;
#        R3 an in-app board record with no draft marker is not held.
#   A5   bin/orphan-reconcile.sh: an open draft on ticket/TK-41 owns the
#        ticket (no launch); with no PR the ticket is an ORPHAN and launches.
#   M1   bin/data-lane-rereview-report.sh on a fixture builds tree.
#
# MUTATION (D1), run by hand in the build: drop the draft field -> A1 red;
# skip the probe -> A3 red; skip dlp_finish -> A2 red; remove the park line
# -> P1 red; remove the resolver guard -> R1 red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
# The scratch hub has no catalog: export the real verdict reader and its window
# (tests/lib/verdict-fixture.sh), or every review.md reads `unknown` and shape D
# never takes the record.
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
unset JOB_ID JOB_PHASE_ID REVIEW_MODEL RESCUE_ONLY RESCUE_PER_TICK RESCUE_HUMAN_STEP RESCUE_HUMAN_STEP_PER_TICK RESCUE_DATA_LANE_WAIT_ALERT_H
export GH_TOKEN="" GH_ETAG=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
MIG=prisma/sql/0087_x.sql
DRAFT=https://github.com/o/tproj/pull/501

# ── stubs on PATH: gh (REST envelope + the CLI arms), curl (worker + status) ─
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac
done
exec "$@"
EOF
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
S="$STUBHUB"
printf '%s\n' "$*" >> "$S/gh-calls.log"
ev() { printf '%s\n' "$1" >> "$S/events.log"; }
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
if [ "$1 $2 $3" = "api -i -X" ]; then
  M="$4"; P="$5"; shift 5
  case "$M $P" in
    "GET repos/o/tproj/issues/87/comments"*)
      case "$P" in *"&page=1"|*"/comments") ;; *) send 200 '[]' ;; esac
      send 200 "$(cat "$S/comments-87.json" 2>/dev/null || echo '[]')" ;;
    "POST repos/o/tproj/issues/87/comments")
      B=""; for a in "$@"; do case "$a" in body=@*) B=$(cat "${a#body=@}") ;; esac; done
      ev "issue-comment"
      printf '%s\n----\n' "$B" >> "$S/issue-comments.txt"
      jq -c --arg b "$B" '. + [{body:$b, created_at:"2026-10-15T00:00:00Z", user:{login:"cromford[bot]", type:"Bot"}}]' \
        "$S/comments-87.json" > "$S/c.tmp" && mv "$S/c.tmp" "$S/comments-87.json"
      send 201 '{"id":9}' ;;
    "GET repos/o/tproj/issues/87") send 200 '{"number":87,"state":"open"}' ;;
    "GET repos/o/tproj/pulls") ev "pr-list-head $*"; send 200 "$(cat "$S/open-prs.json" 2>/dev/null || echo '[]')" ;;
    "POST repos/o/tproj/pulls")
      ev "pr-create-rest $*"
      for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" > "$S/draft-body.txt" ;; esac; done
      st=$(cat "$S/st-create" 2>/dev/null || echo 201)
      case "$st" in 2*) send "$st" "{\"html_url\":\"https://github.com/o/tproj/pull/501\",\"number\":501,\"draft\":true}" ;; esac
      send "$st" '{"message":"Validation Failed"}' ;;
    "POST repos/o/tproj/issues/"*"/labels") ev "label-add $P $*"; send 200 '[]' ;;
    "GET repos/o/tproj/pulls/"*) send 200 "{\"number\":${P##*/},\"draft\":true}" ;;
    "DELETE repos/o/tproj/issues/"*"/labels/data-lane-pending") ev "label-del $P"; send 200 '[]' ;;
  esac
  send 404 '{}'
fi
case "$*" in
  "api rate_limit"*) exit 1 ;;
  "pr list"*"--search"*) cat "$S/prlist.out" 2>/dev/null; exit 0 ;;
  "pr list"*"--head"*) [ -s "$S/prlist.out" ] && awk '{print $3}' "$S/prlist.out"; exit 0 ;;
  "pr create"*) ev "gh-pr-create"; echo "https://github.com/o/tproj/pull/777"; exit 0 ;;
  "pr ready"*) ev "ready $3"; exit "$(cat "$S/ready-rc" 2>/dev/null || echo 0)" ;;
  "pr review"*) ev "pr-review"; exit 0 ;;
  "pr comment"*) ev "pr-comment"; exit 0 ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
S="$STUBHUB"
URL="${!#}"; METHOD=GET; BODY=""; OUTF=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && OUTF="$a"; prev="$a"; done
case "$URL" in
  */api/internal/migrations/status)
    printf '%s\n' "$*" >> "$S/probe-argv.log"
    printf 'probe\n' >> "$S/events.log"
    [ -n "$OUTF" ] && cat "$S/status-body" > "$OUTF" 2>/dev/null
    printf '%s' "$(cat "$S/status-code" 2>/dev/null || echo 200)"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$S/req.txt"
case "$METHOD" in PUT|POST) printf '{"ok":true}\n200\n'; exit 0 ;; esac
printf '{}\n404\n'
EOF
chmod +x "$T/fakebin/"*
export PATH="$T/fakebin:$PATH"

# ── one origin: main, and ticket/tp-87 that adds the migration file ──────────
O="$T/o.git"; W="$T/o-work"
git init -q --bare "$O"
mkdir -p "$W"
(
  cd "$W" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@t; git config user.name t
  echo src > app.js; git add -A; git commit -qm init; git branch -M main
  git remote add origin "$O"; git push -q -u origin main
  git checkout -q -b ticket/tp-87
  mkdir -p prisma/sql
  printf 'CREATE FUNCTION fixture_fn() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;\n' > "$MIG"
  echo 'export const x = 1' > feature.ts
  git add -A; git commit -qm "TP-87: the feature"; git push -q -u origin ticket/tp-87
) >/dev/null 2>&1
git -C "$O" symbolic-ref HEAD refs/heads/main
HEAD87=$(git -C "$O" rev-parse refs/heads/ticket/tp-87)
SUM87=$(git -C "$O" show "$HEAD87:$MIG" | sha256sum | cut -c1-64)
[[ "$HEAD87" =~ ^[0-9a-f]{40}$ ]] && ok || { echo "FAIL: fixture origin"; exit 1; }

DATA_REVIEW="## Findings

B1 migration $MIG not applied in prod — the RPC is called on every load.

DATA_LANE: $MIG
TIER: 2
VERDICT: BLOCK"
CODE_REVIEW="## Findings

B1 migration $MIG not applied in prod.
B2 the guard returns early on empty input.

DATA_LANE: $MIG
TIER: 2
VERDICT: BLOCK"

# ── a scratch hub per case, never reused ─────────────────────────────────────
mkhub() { # mkhub <name>
  H="$T/$1"
  mkdir -p "$H/builds" "$H/logs" "$H/flags" "$H/locks" "$H/env"
  for s in bin/review-rescue.sh bin/jobs-client.sh bin/alert-line.sh bin/fleet-projects-or-alert.sh bin/fleet-conf.sh bin/project-of.sh bin/data-lane-rereview-report.sh; do
    scratch_install_closure "$s" "$H" >/dev/null 2>&1 || bad "closure install for $s"
  done
  printf 'tproj o/tproj - - 2 box-tproj\n' > "$H/fleet.conf"
  : > "$H/env/global.env"
  printf 'DATA_LANE_APP_BASE=https://app.example.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$H/env/tproj.env"
  : > "$H/req.txt"; : > "$H/gh-calls.log"; : > "$H/events.log"; : > "$H/probe-argv.log"
  printf '501 ticket/tp-87 %s\n' "$DRAFT" > "$H/prlist.out"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.log"\nexit 0\n' "$H" > "$H/bin/run-build.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/placer.calls"\nexit 0\n' "$H" > "$H/bin/needs-human-hold.sh"
  chmod +x "$H/bin/run-build.sh" "$H/bin/needs-human-hold.sh"
  : > "$H/run-build.log"
  # The review agent: records the HEAD it ran on and its prompt, appends a round.
  cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$(git rev-parse HEAD 2>/dev/null)" >> "$HARNESS/agent-calls.log"
printf 'agent\n' >> "$HARNESS/events.log"
printf '%s\n----\n' "${6:-}" >> "$HARNESS/prompts.log"
RM=$(printf '%s' "${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
case "$(cat "$HARNESS/agent-mode" 2>/dev/null || echo approve)" in
  approve) [ -n "$RM" ] && printf 'The migration is applied; the diff is sound.\nTIER: 2\nVERDICT: APPROVE\n' >> "$RM" ;;
  block)   [ -n "$RM" ] && printf 'B2 the handler ignores an empty org id (D11)\nTIER: 2\nVERDICT: BLOCK\n' >> "$RM" ;;
esac
[ -n "${5:-}" ] && : > "$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
  echo '[]' > "$H/comments-87.json"
  mkdir -p "$T/repos-$1"
  git clone -q "$O" "$T/repos-$1/tproj" 2>/dev/null
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null) || n=0; printf '%s' "$n"; }
calls() { cnt . "$H/agent-calls.log"; }
evn() { cnt "$1" "$H/events.log"; }
stage() { awk -F'\t' -v k="$1" '$1==k {print $3}' "$H/state/ticket-stage/tproj.tsv" 2>/dev/null; }
stage_reason() { awk -F'\t' -v k="$1" '$1==k {print $5}' "$H/state/ticket-stage/tproj.tsv" 2>/dev/null; }
no_build() { # no_build <case>
  [ -s "$H/run-build.log" ] && bad "$1: run-build.sh must not run: $(cat "$H/run-build.log")" || ok
  grep -E '^(PUT|POST) [^ ]*/api/queue' "$H/req.txt" >/dev/null 2>&1 && bad "$1: nothing may be enqueued" || ok
}

# ── LENS_REFUSE, cut from the pipeline text ──────────────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_fn() { awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"; }
cut_block "stage lane verdict" "$T/lane.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn DLP_DRAFT_AT_BLOCK; cut_fn LENS_REFUSE; cut_fn LENS_APPROVED; } > "$T/lens.sh"
grep -q '^LENS_APPROVED() {' "$T/lens.sh" && bash -n "$T/lens.sh" && ok || bad "setup: LENS_APPROVED is not cut whole from the pipeline"
cut_fn LENS_REFUSE | grep -q 'DLP_DRAFT_AT_BLOCK' && ok || bad "A1: LENS_REFUSE does not call DLP_DRAFT_AT_BLOCK"
# refuse <build-dir> <review text> [lenses] [security verdict] — "<rc> <RESULT line 1>"
refuse() {
  local B="$1"
  mkdir -p "$B"; printf '%s\n' "$2" > "$B/review.md"
  printf '# TP-87 the RPC feature\n' > "$B/plan.md"
  [ -n "${4:-}" ] && printf 'S1 finding\nVERDICT: %s\n' "$4" > "$B/security-review.md"
  ( cd "$W" && git checkout -q ticket/tp-87
    BUILD="$B"; PROJECT=tproj; KEY=TP-87; BASE=main; BRANCH=ticket/tp-87
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=0; LENSES="${3:-review}"; LENSES_PARALLEL=1
    NH_ISSUE=87; NH_SLUG=o/tproj; HARNESS="$H"; ALERTS="$H/logs/ALERTS.log"
    STAMP() { echo 2026-10-15T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090,SC1091
    . "$H/bin/lib/verdict-parse.sh"; . "$H/bin/lib/needs-human.sh"; . "$H/bin/lib/data-lane-pending.sh"
    # shellcheck disable=SC1090
    . "$T/lane.sh"; . "$T/lens.sh"
    LENS_REFUSE review ) >/dev/null 2>"$B/stderr"
  echo "$? $(head -1 "$B/RESULT" 2>/dev/null || echo none)"
}
REC="builds/tproj-TP-87-202610131800"

# ══ A1 — the draft at block time ═══════════════════════════════════════════
mkhub a1
export STUBHUB="$H"
B="$H/$REC"
OUT=$(refuse "$B" "$DATA_REVIEW")
[[ "$OUT" == "6 REVIEW_BLOCKED $B/review.md"* ]] && ok || bad "A1: rc 6 and REVIEW_BLOCKED stay, got '$OUT' ($(tail -3 "$B/stderr"))"
[ "$(evn '^pr-create-rest ')" = 1 ] && ok || bad "A1: one POST repos/o/tproj/pulls, got: $(cat "$H/events.log")"
grep '^pr-create-rest ' "$H/events.log" | grep -q 'draft=true' && ok || bad "A1: the create carries draft=true: $(grep pr-create "$H/events.log")"
grep '^pr-create-rest ' "$H/events.log" | grep -q 'head=ticket/tp-87' && ok || bad "A1: the create's head is the branch"
grep -q "apply $MIG to production, then post \`HUMAN-STEP-DONE: $MIG\` on #87" "$H/draft-body.txt" 2>/dev/null && ok \
  || bad "A1: the draft body names the next step: $(cat "$H/draft-body.txt" 2>/dev/null)"
grep -q '^label-add repos/o/tproj/issues/501/labels .*labels\[\]=data-lane-pending' "$H/events.log" && ok || bad "A1: the label POST on #501: $(cat "$H/events.log")"
[ "$(cat "$B/data-lane-pending" 2>/dev/null)" = "$(printf 'url=%s\nfile=%s\nhead=%s' "$DRAFT" "$MIG" "$HEAD87")" ] && ok \
  || bad "A1: the marker, got '$(cat "$B/data-lane-pending" 2>/dev/null)'"
[ "$(git -C "$O" rev-parse -q --verify refs/heads/ticket/tp-87)" = "$HEAD87" ] && ok || bad "A1: the branch stays on origin"
grep -q "data-lane draft opened $DRAFT" "$B/pipeline.log" 2>/dev/null && ok || bad "A1: pipeline.log names the draft: $(cat "$B/pipeline.log" 2>/dev/null)"
[ "$(evn gh-pr-create)" = 0 ] && ok || bad "A1: no gh pr create"
no_build A1
A1H="$H"

# ══ A1b — an open PR on the branch is adopted ══════════════════════════════
mkhub a1b; export STUBHUB="$H"; B="$H/$REC"
echo '[{"number":640,"html_url":"https://github.com/o/tproj/pull/640","draft":false}]' > "$H/open-prs.json"
OUT=$(refuse "$B" "$DATA_REVIEW")
[ "$(evn '^pr-create-rest ')" = 0 ] && ok || bad "A1b: an open PR is adopted, no create: $(cat "$H/events.log")"
grep -q '^label-add repos/o/tproj/issues/640/labels' "$H/events.log" && ok || bad "A1b: the label goes on #640"
grep -qx 'url=https://github.com/o/tproj/pull/640' "$B/data-lane-pending" 2>/dev/null && ok || bad "A1b: the marker names #640"

# ══ A1c — the reviewed head is not on origin ════════════════════════════════
mkhub a1c; export STUBHUB="$H"; B="$H/$REC"
( cd "$W" && git checkout -q ticket/tp-87 && echo more >> feature.ts && git commit -qam local ) >/dev/null 2>&1
OUT=$(refuse "$B" "$DATA_REVIEW")
( cd "$W" && git reset -q --hard "$HEAD87" ) >/dev/null 2>&1
[ "$(evn '^pr-')" = 0 ] && [ ! -e "$B/data-lane-pending" ] && ok || bad "A1c: an unpushed head opens nothing: $(cat "$H/events.log")"
[[ "$OUT" == "6 REVIEW_BLOCKED"* ]] && ok || bad "A1c: RESULT unchanged, got '$OUT'"

# ══ A1d — the create fails ═════════════════════════════════════════════════
mkhub a1d; export STUBHUB="$H"; B="$H/$REC"
echo 422 > "$H/st-create"
OUT=$(refuse "$B" "$DATA_REVIEW")
[[ "$OUT" == "6 REVIEW_BLOCKED"* ]] && ok || bad "A1d: RESULT unchanged, got '$OUT'"
[ ! -e "$B/data-lane-pending" ] && ok || bad "A1d: no marker without a PR"
[ "$(cnt 'data-lane draft not opened for TP-87' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A1d: one ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(evn '^label-add')" = 0 ] && ok || bad "A1d: no label without a PR"

# ══ A4 — DATA_LANE + a code BLOCK: today's behaviour ═══════════════════════
mkhub a4; export STUBHUB="$H"; B="$H/$REC"
OUT=$(refuse "$B" "$CODE_REVIEW")
[[ "$OUT" == "6 REVIEW_BLOCKED $B/review.md"* ]] && ok || bad "A4: RESULT as on main, got '$OUT'"
[ "$(evn '^pr-')" = 0 ] && [ "$(evn '^label')" = 0 ] && ok || bad "A4: no PR call: $(cat "$H/events.log")"
[ ! -e "$B/data-lane-pending" ] && ok || bad "A4: no marker"

# ══ A4b — another lens blocked ═════════════════════════════════════════════
mkhub a4b; export STUBHUB="$H"; B="$H/$REC"
OUT=$(refuse "$B" "$DATA_REVIEW" "review security" BLOCK)
[ "$(evn '^pr-')" = 0 ] && [ ! -e "$B/data-lane-pending" ] && ok || bad "A4b: the security lens blocked, no draft: $(cat "$H/events.log")"
mkhub a4c; export STUBHUB="$H"; B="$H/$REC"
OUT=$(refuse "$B" "$DATA_REVIEW" "review security" APPROVE)
[ "$(evn '^pr-create-rest ')" = 1 ] && ok || bad "A4b: with the security lens approved the draft opens: $(cat "$H/events.log")"

# ── the rescue lane on an A1 record ─────────────────────────────────────────
run_lane() {
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" REPOS_ROOT="$T/repos-$HN" \
           HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.invalid JOBS_BOX=test-box REVIEW_MODEL=stub
    [ -n "${HS:-}" ] && export RESCUE_HUMAN_STEP="$HS"
    [ -n "${WAITH:-}" ] && export RESCUE_DATA_LANE_WAIT_ALERT_H="$WAITH"
    bash "$H/bin/review-rescue.sh" ) >>"$H/stdout.txt" 2>&1
}
# rec_hub <name> — a hub whose builds dir holds an A1 record (the marker
# written by the real LENS_REFUSE), its RESULT 2 h old.
rec_hub() {
  mkhub "$1"; HN="$1"; export STUBHUB="$H"; B="$H/$REC"
  refuse "$B" "$DATA_REVIEW" >/dev/null
  [ -s "$B/data-lane-pending" ] || bad "$1: setup — the A1 record has no marker"
  touch -d "@$((NOW - 7200))" "$B/RESULT"
  : > "$H/events.log"
}
done_cmt() { # done_cmt <body> [age-s]
  jq -c --arg b "$1" --arg c "$(ISO "${2:-3600}")" \
    '. + [{body:$b, created_at:$c, html_url:"https://github.com/o/tproj/issues/87#issuecomment-1", user:{login:"operator", type:"User"}}]' \
    "$H/comments-87.json" > "$H/c.tmp" && mv "$H/c.tmp" "$H/comments-87.json"
}
status_rows() { # status_rows <filename> <checksum> | none
  if [ "$1" = none ]; then echo '{"applied":[],"pending":[]}' > "$H/status-body"
  else jq -nc --arg f "$1" --arg c "$2" '{applied:[{filename:$f, checksum:$c, appliedAt:"2026-10-15T10:00:00Z", actor:"fixture-operator"}], pending:[]}' > "$H/status-body"; fi
}
line_of() { grep -n -- "$1" "$H/events.log" | head -1 | cut -d: -f1; }

# ══ A2 — confirmed: re-review the same head, then ready + unlabel ══════════
rec_hub a2
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod"
status_rows 0087_x.sql "$SUM87"
run_lane
[ "$(evn '^probe$')" = 1 ] && ok || bad "A2: one status probe, got $(evn '^probe$'): $(cat "$H/events.log")"
[ "$(calls)" = 1 ] && ok || bad "A2: one re-review, got $(calls). log: $(tail -5 "$H/logs/review-rescue.log" 2>/dev/null)"
[ "$(awk '{print $2}' "$H/agent-calls.log" 2>/dev/null | head -1)" = "$HEAD87" ] && ok || bad "A2: the review ran on the marker head $HEAD87"
grep -q "^=== human-step re-review ${HEAD87:0:8}" "$B/review.md" && ok || bad "A2: the header names the head: $(grep '^===' "$B/review.md")"
grep -q 'ledger: 0087_x.sql applied at 2026-10-15T10:00:00Z by fixture-operator' "$H/prompts.log" 2>/dev/null && ok || bad "A2: the prompt carries the probe line"
RL=$(line_of '^ready '); DL=$(line_of '^label-del '); AL=$(line_of '^agent$')
[ -n "$RL" ] && [ -n "$DL" ] && [ -n "$AL" ] && [ "$RL" -gt "$AL" ] && [ "$DL" -gt "$AL" ] && ok \
  || bad "A2: ready and the label DELETE come after the review: $(cat "$H/events.log")"
grep -q "^ready $DRAFT\$" "$H/events.log" && grep -q '^label-del repos/o/tproj/issues/501/labels/data-lane-pending' "$H/events.log" && ok \
  || bad "A2: ready on the draft url and the label DELETE on #501: $(cat "$H/events.log")"
[ "$(head -1 "$B/RESULT")" = "PR_CREATED $DRAFT" ] && ok || bad "A2: RESULT line 1 is PR_CREATED <draft>, got '$(head -1 "$B/RESULT")'"
[ "$(evn '^pr-create-rest ')" = 0 ] && [ "$(evn gh-pr-create)" = 0 ] && ok || bad "A2: no PR create: $(cat "$H/events.log")"
[ "$(stage TP-87)" = rereview-approve ] && ok || bad "A2: stage rereview-approve, got '$(stage TP-87)'"
grep -q 'marked ready' <<<"$(stage_reason TP-87)" && ok || bad "A2: the stage says the draft is ready: '$(stage_reason TP-87)'"
grep -q 'tok-fixture-1' "$H/probe-argv.log" && bad "A2: the token reached curl's argv" || ok
no_build A2

# ══ A2b — the done comment does not name the file ══════════════════════════
rec_hub a2b
done_cmt "HUMAN-STEP-DONE: applied"
status_rows 0087_x.sql "$SUM87"
run_lane
[ "$(evn '^probe$')" = 0 ] && [ "$(calls)" = 0 ] && ok || bad "A2b: no probe and no review, got probe $(evn '^probe$') calls $(calls)"
[ "$(stage TP-87)" = human-step-waiting ] && grep -q "does not name $MIG" <<<"$(stage_reason TP-87)" && ok \
  || bad "A2b: stage human-step-waiting naming the file, got '$(stage TP-87)' '$(stage_reason TP-87)'"
[ -e "$B/.rescue-attempts" ] && bad "A2b: no attempt spent" || ok

# ══ A2c — gh pr ready fails ════════════════════════════════════════════════
rec_hub a2c
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod"
status_rows 0087_x.sql "$SUM87"
echo 1 > "$H/ready-rc"
run_lane
[ "$(calls)" = 1 ] && ok || bad "A2c: the re-review ran"
[ "$(cnt "gh pr ready $DRAFT" "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A2c: one ALERTS line naming the url: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'marked ready' <<<"$(stage_reason TP-87)" && bad "A2c: no 'ready' claim when gh pr ready failed: '$(stage_reason TP-87)'" || ok

# ══ A3 — the ledger has no row: one comment, no review, no attempt ═════════
rec_hub a3
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod"
status_rows none
run_lane
[ "$(calls)" = 0 ] && ok || bad "A3: no review on a missing row, got $(calls)"
[ "$(evn '^issue-comment$')" = 1 ] && ok || bad "A3: one ticket comment, got $(evn '^issue-comment$')"
grep -q 'no schema_migration row for 0087_x.sql' "$H/issue-comments.txt" 2>/dev/null && ok || bad "A3: the comment names what is missing: $(cat "$H/issue-comments.txt" 2>/dev/null)"
[ "$(stage TP-87)" = human-step-waiting ] && grep -q 'probe:' <<<"$(stage_reason TP-87)" && ok || bad "A3: stage human-step-waiting 'probe: …', got '$(stage_reason TP-87)'"
[ -e "$B/.rescue-attempts" ] && bad "A3: no attempt spent" || ok
touch -d "@$((NOW - 7200))" "$B/RESULT"
run_lane
[ "$(evn '^probe$')" = 2 ] && ok || bad "A3: the second tick probes again, got $(evn '^probe$')"
[ "$(evn '^issue-comment$')" = 1 ] && ok || bad "A3: the second tick posts no second comment, got $(evn '^issue-comment$')"
[ "$(calls)" = 0 ] && [ ! -e "$B/.rescue-attempts" ] && ok || bad "A3: the second tick spends nothing"

# ══ A3b — the status route answers 500 ═════════════════════════════════════
rec_hub a3b
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod"
status_rows none; echo 500 > "$H/status-code"
run_lane
[ "$(evn '^probe$')" = 1 ] && [ "$(calls)" = 0 ] && [ "$(evn '^issue-comment$')" = 0 ] && ok \
  || bad "A3b: a 500 gives no review and no comment: $(cat "$H/events.log")"
[ -e "$B/.rescue-attempts" ] && bad "A3b: no attempt spent" || ok

[ "$(cnt 'probe for' "$H/logs/ALERTS.log")" = 0 ] && ok || bad "A3b: a 1 h old done comment with a 500 does not page yet: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
touch -d "@$((NOW - 7200))" "$B/RESULT"
run_lane
[ "$(evn '^probe$')" = 2 ] && ok || bad "A3b: the second tick probes again, got $(evn '^probe$')"
[ "$(cnt 'could not answer' "$H/logs/review-rescue.log")" = 1 ] && ok || bad "A3b: the same unknown is said once, not every tick: $(grep -c 'could not answer' "$H/logs/review-rescue.log" 2>/dev/null)"

# ══ A3c — a refused token after HUMAN-STEP-DONE pages at once ══════════════
rec_hub a3c
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod"
status_rows none; echo 401 > "$H/status-code"
run_lane
[ "$(calls)" = 0 ] && [ ! -e "$B/.rescue-attempts" ] && ok || bad "A3c: a 401 spends nothing"
[ "$(cnt "TP-87 draft $DRAFT: HUMAN-STEP-DONE at .*token was refused.*MIGRATION_TOKEN" "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "A3c: one ALERTS line naming the refused token: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
touch -d "@$((NOW - 7200))" "$B/RESULT"
run_lane
[ "$(evn '^probe$')" = 2 ] && ok || bad "A3c: the second tick probes again"
[ "$(cnt 'token was refused' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A3c: a second tick adds no alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ══ A3d — no ledger row long after HUMAN-STEP-DONE pages once ══════════════
rec_hub a3d
touch -d "@$((NOW - 100000))" "$B/RESULT"
done_cmt "HUMAN-STEP-DONE: applied $MIG in prod" 90000
status_rows none
run_lane
[ "$(calls)" = 0 ] && ok || bad "A3d: no review on a missing row"
[ "$(cnt "TP-87 draft $DRAFT: HUMAN-STEP-DONE at .*no schema_migration row" "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "A3d: one ALERTS line for a missing row 25 h after the done comment: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ══ W1 — the draft waits: one alert after the window ═══════════════════════
rec_hub w1
touch -d "@$((NOW - 90000))" "$B/data-lane-pending"
run_lane
[ "$(cnt "draft $DRAFT waits" "$H/logs/ALERTS.log")" = 1 ] && ok || bad "W1: one wait alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
touch -d "@$((NOW - 7200))" "$B/RESULT"
run_lane
[ "$(cnt "draft $DRAFT waits" "$H/logs/ALERTS.log")" = 1 ] && ok || bad "W1: a second tick adds no alert"
[ "$(calls)" = 0 ] && [ "$(evn '^probe$')" = 0 ] && ok || bad "W1: no done comment, no probe and no review"
rec_hub w1b
touch -d "@$((NOW - 90000))" "$B/data-lane-pending"
WAITH=0 run_lane
[ "$(cnt 'waits' "$H/logs/ALERTS.log")" = 0 ] && ok || bad "W1: RESCUE_DATA_LANE_WAIT_ALERT_H=0 gives no alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
rec_hub w1c
touch -d "@$((NOW - 3600))" "$B/data-lane-pending"
run_lane
[ "$(cnt 'waits' "$H/logs/ALERTS.log")" = 0 ] && ok || bad "W1: a 1 h old draft gives no alert"

# ══ P1 — pr-owner-sweep parks the labelled draft ═══════════════════════════
PH="$T/ph"
mkdir -p "$PH/logs" "$PH/locks" "$PH/state/merge-conductor" "$PH/state/pr-owners" "$PH/flags" "$PH/env" "$PH/fixture" "$T/pbin"
cp -R "$DIR/bin" "$PH/"
printf 'HARNESS_SECRET=s3cret-fixture\nJOBS_URL=https://jobs.test\n' > "$PH/env/global.env"
printf 'cromford example-org/cromford - -\n' > "$PH/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$PH/bin/lane-alert.sh"
cat > "$T/pbin/gh" <<'SH'
#!/bin/bash
F="$HARNESS/fixture"
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*) cat "$F/open.json"; exit 0 ;;
  *"pr list"*"--state merged"*) echo '[]'; exit 0 ;;
esac
if [ "$1 $2 $3" = "api -i -X" ]; then
  printf '%s %s\n' "$4" "$5" >> "$HARNESS/writes.log"
  printf 'HTTP/2 404 X\r\n\r\n{}\n'; exit 0
fi
case "$1 $2" in "api repos/"*) echo 1234; exit 0 ;; esac
exit 1
SH
cat > "$T/pbin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET https://jobs.test/api/jobs"*)  printf '{"jobs":[]}\n200\n' ;;
  "GET https://jobs.test/api/queue"*) printf '{"queue":[]}\n200\n' ;;
  "GET https://jobs.test/api/verdicts"*) printf '{"standing":null,"rows":[]}\n200\n' ;;
  "GET https://jobs.test/"*) printf '{"error":"none"}\n404\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/pbin/gh" "$T/pbin/curl" "$PH/bin/lane-alert.sh"
: > "$PH/state/merge-conductor/pr-state.tsv"
P_OLD=$(ISO 259200)
popen() { # popen <labels-json>
  jq -nc --arg old "$P_OLD" --argjson l "$1" \
    '[{number:700,title:"BH-900: the draft",headRefName:"ticket/bh-900",baseRefName:"main",headRefOid:("7"*40),author:{login:"operator"},
       labels:$l,body:"",mergeable:"MERGEABLE",updatedAt:$old,createdAt:$old,url:"https://github.com/example-org/cromford/pull/700",isDraft:true}]' \
    > "$PH/fixture/open.json"
}
psweep() { PATH="$T/pbin:$PATH" env HARNESS="$PH" FLEET_CONF="$PH/fleet.conf" GH_TOKEN=x-fixture GH_BUDGET_TTL_S=0 GH_ETAG=0 JOBS_RETRIES=0 \
             BOX_NAME=box-hub HUB_BOX_NAME=box-hub bash "$PH/bin/pr-owner-sweep.sh" --explain --repo example-org/cromford 2>/dev/null \
             | awk -F'\t' '$1=="700" {print $2"\t"$3"\t"$5}'; }
popen '[{"name":"data-lane-pending"}]'
OUT=$(psweep)
[[ "$OUT" == "PARKED	none	park: data-lane-pending"* ]] && ok || bad "P1: a labelled draft is PARKED with no action, got '$OUT'"
popen '[]'; rm -f "$PH/state/pr-owners/"*.json
OUT=$(psweep)
[[ "$OUT" == ORPHAN* ]] && ok || bad "P1 control: without the label the draft is an ORPHAN, got '$OUT'"

# ══ R1/R2 — the resolver holds a pending record, and only then ═════════════
RH="$T/rh"
mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/state" "$RH/flags" "$RH/locks" "$RH/env" "$RH/builds" \
         "$RH/state/merge-conductor" "$RH/state/build-queue/tproj" "$T/rbin" "$T/rrepos"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$RH/bin/"
scratch_install_closure bin/blocked-resolver.sh "$RH" >/dev/null || bad "R: closure install"
chmod +x "$RH/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$RH/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$RH" tproj
: > "$RH/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh; do printf '#!/bin/bash\nexit 0\n' > "$RH/bin/$f"; chmod +x "$RH/bin/$f"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.txt"\nexit 0\n' "$T" > "$RH/bin/run-build.sh"
printf '#!/bin/bash\nprintf "ACCEPT\\n" > "$5"\nexit 0\n' > "$RH/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/r-placer.txt"\nexit 0\n' "$T" > "$RH/bin/needs-human-hold.sh"
chmod +x "$RH/bin/run-build.sh" "$RH/bin/agent-call.sh" "$RH/bin/needs-human-hold.sh"
cat > "$T/rbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X "*) GHT="$T/rgh"; mkdir -p "\$GHT"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo '{"number":87,"state":"open","labels":[{"name":"ai-build"}],"title":"TP-87: x","body":""}' ;;
  *) echo "" ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/br-ssh"
chmod +x "$T/rbin/"*
cat > "$RH/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/r-queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$RH/flags/fly-pool-tproj"
# The built branch is readable, as on a box: the BH-4926 route reads the
# record's diff and finds this path is not its own (dl_candidate rc 1).
git clone -q "$O" "$T/rrepos/tproj" 2>/dev/null
r_run() { ( PATH="$T/rbin:$PATH" HARNESS="$RH" FLEET_CONF="$RH/fleet.conf" REPOS_ROOT="$T/rrepos" BR_SSH="$T/rbin/br-ssh" \
             BR_UNCHANGED_RECHECK_S=0 env "$@" bash "$RH/bin/blocked-resolver.sh" >>"$T/r-run.log" 2>&1 ) || true; }
r_rec() { # r_rec <stamp> — the A1 record shape, RESULT 7 h old
  local r="$RH/builds/tproj-TP-87-$1"
  scratch_rm "$RH/builds"; scratch_rm "$RH/state/blocked-resolver"; mkdir -p "$r"
  printf 'REVIEW_BLOCKED review.md\nTICKET_ID: 87\n' > "$r/RESULT"
  printf '%s\n' "$DATA_REVIEW" > "$r/review.md"
  printf 'url=%s\nfile=%s\nhead=%s\n' "$DRAFT" "$MIG" "$HEAD87" > "$r/data-lane-pending"
  printf '%s\n' "$HEAD87" > "$r/review-head"
  touch -d "@$((NOW - 25200))" "$r/RESULT"
  : > "$T/r-queue.txt"; : > "$RH/logs/blocked-resolver.log"
}
r_enq() { grep -c . "$T/r-queue.txt" 2>/dev/null || true; }
r_said() { grep -c 'data-lane-pending: waits on the migration apply' "$RH/logs/blocked-resolver.log" 2>/dev/null || true; }
r_rec 202610130001
r_run X=1
[ "$(r_enq)" = 0 ] && ok || bad "R1: a pending data-lane record is not rebuilt: $(cat "$T/r-queue.txt")"
[ "$(r_said)" = 1 ] && ok || bad "R1: one hold line, got $(r_said): $(tail -5 "$RH/logs/blocked-resolver.log")"
r_run X=1
[ "$(r_enq)" = 0 ] && [ "$(r_said)" = 1 ] && ok || bad "R1: the next tick neither rebuilds nor says it again"
r_rec 202610130002
r_run RESCUE_HUMAN_STEP=0
[ "$(r_said)" = 0 ] && ok || bad "R2: RESCUE_HUMAN_STEP=0 holds nothing"
grep -qE -- '-> (rebuild-fresh|rebuild-retry)' "$RH/logs/blocked-resolver.log" && ok \
  || bad "R2: the resolver's rung runs as on main: $(tail -5 "$RH/logs/blocked-resolver.log")"
# R3/R3b — an in-app board (board_prefix not "-"): no draft can exist and
# shape D never offers the record, so a record with no marker is not held
# (lead review lr-7013-57430030077b BLOCK); a record with a marker still is.
printf 'tproj o/tproj https://app.example.test /api/board 2 box-tproj 192.0.2.9\n' > "$RH/fleet.conf"
r_rec 202610130003
rm -f "$RH/builds/tproj-TP-87-202610130003/data-lane-pending"
r_run X=1
[ "$(r_said)" = 0 ] && ok || bad "R3: an in-app board record with no draft is not held: $(tail -5 "$RH/logs/blocked-resolver.log")"
grep -qE -- '-> (rebuild-fresh|rebuild-retry|needs-human)' "$RH/logs/blocked-resolver.log" && ok \
  || bad "R3: the resolver's rung runs on the in-app board record: $(tail -5 "$RH/logs/blocked-resolver.log")"
r_rec 202610130004
r_run X=1
[ "$(r_said)" = 1 ] && [ "$(r_enq)" = 0 ] && ok || bad "R3b: a record with a draft marker is held on any board: $(tail -5 "$RH/logs/blocked-resolver.log")"
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$RH/fleet.conf"

# ══ A5 — reconcile: an open draft owns the ticket ══════════════════════════
AH="$T/ah"
mkdir -p "$AH/bin/lib/jobs" "$AH/logs" "$AH/state" "$AH/locks" "$AH/flags" "$AH/env" "$AH/prompts" "$AH/builds" "$AH/fixture" "$T/abin"
for s in bin/orphan-reconcile.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$AH" >/dev/null 2>&1 || bad "A5: closure install for $s"
done
ln -sf "$DIR/bin/fleet-conf.sh" "$AH/bin/fleet-conf.sh"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$AH/prompts/project-5.md"
printf 'HARNESS_SECRET=s3cret-fixture\nJOBS_URL=https://jobs.test\n' > "$AH/env/global.env"
printf '#!/bin/bash\n:\n' > "$AH/bin/lane-alert.sh"; chmod +x "$AH/bin/lane-alert.sh"
cat > "$AH/bin/run-build.sh" <<'SH'
printf '%s\n' "$*" >> "$HARNESS/launches.log"
d="$HARNESS/builds/$1-$3-x"
mkdir -p "$d" && echo "BUILD_REFUSED refused by the fixture" > "$d/RESULT" && : > "$d/COMMENTED"
SH
chmod +x "$AH/bin/run-build.sh"
cat > "$T/abin/gh" <<'SH'
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  "api repos/"*" -q .id") echo 1234; exit 0 ;;
  *"/issues/"*"/comments"*) SEND 200 '[]' ;;
  *"/pulls"*) SEND 200 "$(cat "$HARNESS/fixture/prs.json")" ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*) SEND 200 "$(cat "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/abin/curl" <<'SH'
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/routing/*) printf '{"error":"no row"}\n404\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/ledger*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/abin/gh" "$T/abin/curl"
jq -nc --arg u "$(ISO 7200)" '[{number:41, title:"TK-41 a ticket with a data-lane draft", body:"## Scope", comments:0, updated_at:$u, labels:[{name:"ai-build"}]}]' > "$AH/fixture/open.json"
a_run() { : > "$AH/launches.log"; scratch_rm "$AH/state/orphan-reconcile"
          PATH="$T/abin:$PATH" HARNESS="$AH" FLEET_CONF="$DIR/fleet.conf" ORPHAN_GRACE_MIN=0 ORPHAN_MAX_PER_RUN=20 \
            "$AH/bin/orphan-reconcile.sh" project-5 --explain 2>/dev/null | awk -F'\t' '$1=="TK-41" {print $3"\t"$4}'; }
echo '[{"number":905,"title":"TK-41: the feature","draft":true,"head":{"ref":"ticket/TK-41"},"labels":[{"name":"data-lane-pending"}],"body":""}]' > "$AH/fixture/prs.json"
OUT=$(a_run)
[ "$OUT" = "OWNED	pr:#905 is open" ] && ok || bad "A5: the open draft owns the ticket, got '$OUT'"
[ -s "$AH/launches.log" ] && bad "A5: no launch while the draft is open: $(cat "$AH/launches.log")" || ok
echo '[]' > "$AH/fixture/prs.json"
OUT=$(a_run)
[ "$(cut -f1 <<<"$OUT")" = ORPHAN ] && [ "$(grep -c 'TK-41' "$AH/launches.log" 2>/dev/null)" = 1 ] && ok \
  || bad "A5 mutation: with no PR the ticket is an ORPHAN and launches once, got '$OUT' / $(cat "$AH/launches.log" 2>/dev/null)"

# ══ M1 — the metric report ═════════════════════════════════════════════════
mkhub m1
mrec() { # mrec <dir> <review text> [stamp1 stamp2]
  local d="$H/builds/$1"; mkdir -p "$d"
  printf 'REVIEW_BLOCKED review.md\n' > "$d/RESULT"
  printf '%s\n' "$2" > "$d/review.md"
  printf '%s [tproj/x] start\n%s [tproj/x] end\n' "${3:-2026-10-13 10:00:00Z}" "${4:-2026-10-13 10:30:00Z}" > "$d/pipeline.log"
}
mrec tproj-TP-90-202610131000 "$DATA_REVIEW"
mrec tproj-TP-91-202610131100 "$DATA_REVIEW"
mrec tproj-TP-92-202610131200 "$DATA_REVIEW"
mrec tproj-TP-93-202610131300 "$CODE_REVIEW"
mrec tproj-TP-94-202610131400 "$(printf 'B1 the guard is wrong.\nTIER: 2\nVERDICT: BLOCK')"
mrec tproj-TP-90-202610131500 "$(printf 'All good.\nTIER: 2\nVERDICT: APPROVE')" "2026-10-13 15:00:00Z" "2026-10-13 15:45:00Z"
printf 'PR_CREATED https://github.com/o/tproj/pull/9\n' > "$H/builds/tproj-TP-90-202610131500/RESULT"
printf '{"total_cost_usd":0.25}\n' > "$H/builds/tproj-TP-90-202610131500/execute-run.txt.json"
OUT=$(HARNESS="$H" bash "$H/bin/data-lane-rereview-report.sh" --last 30 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "M1: rc 0, got $RC: $OUT"
grep -q 'fallback 1 of 4' <<<"$OUT" && ok || bad "M1: 'fallback 1 of 4', got: $OUT"
OUT=$(HARNESS="$H" bash "$H/bin/data-lane-rereview-report.sh" --keys TP-90 2>&1)
grep -qE 'tproj-TP-90-202610131000.*30.*unknown' <<<"$OUT" && ok || bad "M1: the blocked build's minutes and unknown dollars: $OUT"
grep -qE 'tproj-TP-90-202610131500.*45.*0\.25' <<<"$OUT" && ok || bad "M1: the later build's minutes and dollars: $OUT"
HARNESS="$H" bash "$H/bin/data-lane-rereview-report.sh" --last x >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "M1: bad usage is rc 2, got $RC"

echo "data-lane-rereview.bh-6467: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
