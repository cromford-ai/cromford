#!/bin/bash
# tests/triage-trigger-facts.bh-8933-test.sh — event-wake triage reads the
# trigger-actor gate's answer, not a stale refusal comment (BH-8933).
#
# THE CASE (example-org/project-6, 2026-11-02). github-actions[bot] put ai-build
# on #3524 at 05:46:34Z; the gate refused it and posted "We didn't start a
# build for this one" at 05:57Z; operator (on the trigger list) took the label
# off at 06:44:47Z and put it back at 06:44:54Z (event 34882072491). The gate
# allowed the relabel, but event-wake triage read the refusal comment, judged
# the labeler in prose and logged `skip`, so no queue row was made.
#
# HOW IT DRIVES.
#   U cases: the REAL bin/lib/trigger-actor.sh, bin/lib/harness-self.sh and
#     bin/jobs-client.sh; only the wire is stubbed (_jobs_req, gh_rest,
#     gh_rest_comment, lane_switch, bin/fleet-conf.sh), the shape of
#     tests/trigger-actor-rearm.bh-6957-test.sh. ta_triage_fact and ta_gate
#     are called directly.
#   I cases: the REAL bin/run-triage.sh and bin/lib/rt/*.sh (roots rewritten,
#     the tests/event-wake-scope-test.sh precedent), the REAL
#     triage-shards-lib.sh, triage-trigger-facts.sh, trigger-actor.sh and
#     harness-self.sh. Stubbed: the gate, gate-diff, unblocked-children, the
#     model (bin/agent-call.sh), the GitHub wire (bin/lib/gh-rest.sh), the
#     settings row (bin/jobs-client.sh) and lane_switch. A `gh` and a `curl`
#     on PATH record every call and fail: 0 real vendor calls (B1).
#   The fake model decides like the real one did: it queues 3524 only when
#   the prompt's TRIGGER ACTOR line says allow, and otherwise skips on the
#   refusal comment.
#
#   U1   bot label, refusal, listed relabel -> allow listed (the case)
#   U1b  the person only UNLABELED after the bot -> ignore not-listed
#   U1c  a listed person's label OLDER than the bot's -> ignore
#   U1d  a listed person's newer label is `bug`, not ai-build -> ignore
#   U1e  the relabel on events page 2 -> allow listed
#   U2   no row, newer human RETRY -> allow rearm
#   U3   no row, a User label -> allow human-default
#   U4   trigger-actor-off -> allow switched-off, 0 events reads
#   U5   no U case writes the ledger or posts a comment
#   U5b  events rate-limited -> unverifiable
#   U6   ta_gate gives the same answer for the U1 / U1b fixtures
#   C1   the triage contract carries the TRIGGER ACTOR rule
#   I1   event-wake, the case -> prompt line, queue row, log line
#   I2   event-wake, newest label still the bot -> ignore line, no queue row
#   I3   knob 0 -> no section, 0 reads; I3b a keyless wake -> no section
#   I4   shards on -> the shard prompt carries the line; no work dir left
#   B1   0 real vendor calls across the I cases
# Run from anywhere: tests/triage-trigger-facts.bh-8933-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "triage-trigger-facts: jq missing — skipping"; exit 0; }

# ── fixture builders (shared) ──────────────────────────────────────────────
# ev <id> <event> <login> <type> <created_at> [label]
ev() {
  jq -nc --argjson id "$1" --arg e "$2" --arg l "$3" --arg t "$4" --arg c "$5" --arg n "${6:-ai-build}" \
    '{id:$id, event:$e, actor:{login:$l, type:$t}, label:{name:$n}, created_at:$c, performed_via_github_app:null}'
}
# cm <id> <login> <type> <created_at> <body>
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg b "$5" \
    '{id:$id, user:{login:$l, type:$t}, created_at:$c, updated_at:$c, body:$b, performed_via_github_app:null}'
}
BOT_LABEL() { ev 34882000001 labeled 'github-actions[bot]' Bot 2026-11-02T05:46:34Z; }
OPERATOR_UNLABEL() { ev 34882068124 unlabeled operator User 2026-11-02T06:44:47Z; }
OPERATOR_LABEL() { ev 34882072491 labeled operator User 2026-11-02T06:44:54Z; }
REFUSAL_BODY="We didn't start a build for this one. The \`ai-build\` label was added by \`github-actions[bot]\`, and only the people on this project's trigger list (or the harness itself) can start a build. If it should be built, someone on the list can take the label off and put it back."
REFUSAL() { cm 7001 cromford-board-app Bot 2026-11-02T05:57:00Z "$REFUSAL_BODY"; }

# ══ U cases: ta_triage_fact on the real lib ════════════════════════════════
H="$T/h"
mkdir -p "$H/bin/lib" "$H/locks" "$H/logs" "$T/fx" "$T/work" "$T/build"
for s in bin/lib/trigger-actor.sh bin/lib/harness-self.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in
  board_prefix) printf '%s\n' - ;;
  repo)         printf '%s\n' "example-org/tproj" ;;
  *)            exit 1 ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"

cat > "$T/stubs.sh" <<'SH'
. "$REPO_DIR/bin/jobs-client.sh"
_jobs_req() {
  local m="$1" p="$2" b="${3:-}"
  case "$m $p" in
    "GET /api/settings/"*)
      [ "${p#/api/settings/}" = "trigger.actors.tproj" ] || return 2
      case "${SET_RC:-2}" in
        0) jq -nc --arg v "$SET_VAL" '{setting:{key:"trigger.actors.tproj",value:$v}}'; return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
      esac ;;
    "GET /api/ledger?"*)
      [ -s "$LEDGER" ] || return 2
      jq -c '{ledger: .}' "$LEDGER"; return 0 ;;
    "PUT /api/ledger")
      printf '%s\n' "$b" >> "$CALLS/puts"
      printf '%s' "$b" | jq -c '{status, detail}' > "$LEDGER"; return 0 ;;
  esac
  return 1
}
gh() { :; }
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$CALLS/gh"
  local pg; pg=$(printf '%s' "$2" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p'); pg="${pg:-1}"
  case "$1 $2" in
    "GET repos/example-org/tproj/issues/77/events?"*)
      [ "${EV_RC:-0}" = 0 ] || { GH_REST_REASON=rate-limit; return "$EV_RC"; }
      if [ -r "$FX/events-p$pg.json" ]; then cat "$FX/events-p$pg.json"; else echo '[]'; fi
      return 0 ;;
    "GET repos/example-org/tproj/issues/77/comments?"*)
      if [ -r "$FX/comments-p$pg.json" ]; then cat "$FX/comments-p$pg.json"; else echo '[]'; fi
      return 0 ;;
  esac
  return 75
}
gh_rest_comment() {
  { echo "--- $1#$2"; cat "$3"; echo; } >> "$CALLS/comments"
  return 0
}
lane_switch() { [ "$1" = trigger-actor-off ] && [ "${SW_ON:-0}" = 1 ]; }
SH

export REPO_DIR="$DIR" FX="$T/fx" LEDGER="$T/ledger.json" CALLS="$T/calls" STUBS="$T/stubs.sh"
export HARNESS="$H" BUILD="$T/build" WORK="$T/work"
export HARNESS_SELF_APPS="cromford cromford-board cromford-builders"
export HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.example.test
export PROJECT_2_EVENTS_RETRIES=0
export -n GH_ISSUES_REPO 2>/dev/null; unset GH_ISSUES_REPO

events() { printf '%s\n' "$@" | jq -s . > "$FX/events-p1.json"; }
comments() { if [ $# -eq 0 ]; then echo '[]' > "$FX/comments-p1.json"; else printf '%s\n' "$@" | jq -s . > "$FX/comments-p1.json"; fi; }
ureset() {
  rm -f "$FX"/*.json "$LEDGER"
  scratch_rm "$CALLS" || exit 1; mkdir -p "$CALLS"
  unset SET_RC SET_VAL EV_RC SW_ON
  comments "$(REFUSAL)"
}
# fact — LINE from one real ta_triage_fact call (FRC its rc)
fact() {
  local out
  out=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; rc=0
                 ta_triage_fact tproj example-org/tproj 77 "$WORK" || rc=$?
                 printf "%s\n" "$rc"' 2>"$T/stderr")
  LINE=$(printf '%s\n' "$out" | sed -n 1p); FRC=$(printf '%s\n' "$out" | tail -1)
}
run_gate() {
  local out
  out=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; rc=0
                 ta_gate tproj BH-77 77 "$BUILD" || rc=$?
                 printf "%s\n%s\n" "$rc" "$PROJECT_2_LINE"' 2>"$T/stderr")
  GRC=$(sed -n 1p <<<"$out"); GLINE=$(sed -n 2p <<<"$out")
}
cnt() { if [ -f "$CALLS/$1" ]; then grep -c "${2:-.}" "$CALLS/$1"; else echo 0; fi; }
# no_writes <case> — U5: a triage fact never writes the ledger or comments
no_writes() {
  [ ! -e "$CALLS/puts" ] && ok || bad "U5 ($1): ta_triage_fact wrote the ledger: $(cat "$CALLS/puts")"
  [ ! -e "$CALLS/comments" ] && ok || bad "U5 ($1): ta_triage_fact posted a comment"
  [ "$(ls -A "$WORK" 2>/dev/null)" = "" ] && ok || bad "U5 ($1): ta_triage_fact left files in its work dir: $(ls -A "$WORK")"
}

# ── U1: the case ────────────────────────────────────────────────────────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)" "$(OPERATOR_LABEL)"
fact
[ "$LINE" = "77 :: allow listed actor=operator event=34882072491 labeled_at=2026-11-02T06:44:54Z" ] && ok \
  || bad "U1: the listed relabel must be the fact, was '$LINE' (stderr: $(head -c 300 "$T/stderr"))"
[ "$FRC" = 0 ] && ok || bad "U1: rc must be 0, was $FRC"
no_writes U1

# ── U1b: the person only took the label off ────────────────────────────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)"
fact
case "$LINE" in "77 :: ignore not-listed actor=github-actions[bot] event=34882000001 labeled_at=2026-11-02T05:46:34Z"*) ok ;;
  *) bad "U1b: an unlabel is not a label, the bot's label stands: '$LINE'" ;; esac
no_writes U1b

# ── U1c: the listed label is OLDER than the bot's ──────────────────────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(ev 34881000000 labeled operator User 2026-11-02T05:00:00Z)" "$(BOT_LABEL)"
fact
case "$LINE" in "77 :: ignore not-listed actor=github-actions[bot]"*) ok ;; *) bad "U1c: the newest label decides: '$LINE'" ;; esac
no_writes U1c

# ── U1d: a newer label by the listed person, but another label name ─────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)" "$(ev 34882072491 labeled operator User 2026-11-02T06:44:54Z bug)"
fact
case "$LINE" in "77 :: ignore not-listed actor=github-actions[bot]"*) ok ;; *) bad "U1d: a 'bug' label is not ai-build: '$LINE'" ;; esac
no_writes U1d

# ── U1e: the relabel is on events page 2 ───────────────────────────────────
ureset; export SET_RC=0 SET_VAL=operator
{ BOT_LABEL
  for i in $(seq 1 99); do
    jq -nc --argjson id "$((34882000100 + i))" '{id:$id, event:"subscribed", actor:{login:"someone", type:"User"}, created_at:"2026-11-02T06:00:00Z"}'
  done; } | jq -s . > "$FX/events-p1.json"
printf '%s\n' "$(OPERATOR_UNLABEL)" "$(OPERATOR_LABEL)" | jq -s . > "$FX/events-p2.json"
fact
case "$LINE" in "77 :: allow listed actor=operator event=34882072491"*) ok ;; *) bad "U1e: page 2's relabel must decide: '$LINE'" ;; esac
[ "$(cnt gh 'events?.*page=2')" = 1 ] && ok || bad "U1e: events page 2 must be read: $(cat "$CALLS/gh")"
no_writes U1e

# ── U2: no row, a newer human RETRY re-arms ────────────────────────────────
ureset
events "$(BOT_LABEL)"
comments "$(REFUSAL)" "$(cm 501 operator User 2026-11-02T06:40:00Z RETRY)"
fact
case "$LINE" in "77 :: allow rearm actor=operator event=comment-501"*) ok ;; *) bad "U2: a human RETRY must re-arm: '$LINE'" ;; esac
no_writes U2

# ── U3: no row, a User label ───────────────────────────────────────────────
ureset
events "$(OPERATOR_LABEL)"
fact
case "$LINE" in "77 :: allow human-default actor=operator event=34882072491"*) ok ;; *) bad "U3: '$LINE'" ;; esac
no_writes U3

# ── U4: the kill switch ────────────────────────────────────────────────────
ureset; SW_ON=1
events "$(BOT_LABEL)"
SW_ON=1 fact
case "$LINE" in "77 :: allow switched-off"*) ok ;; *) bad "U4: '$LINE'" ;; esac
[ "$(cnt gh)" = 0 ] && ok || bad "U4: a switched-off gate must read no events: $(cat "$CALLS/gh")"
no_writes U4

# ── U5b: a rate-limited events read ────────────────────────────────────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)"
EV_RC=75 fact
[ "$LINE" = "77 :: unverifiable events page 1 rc=75 rate-limit" ] && ok || bad "U5b: '$LINE'"
[ "$FRC" = 0 ] && ok || bad "U5b: a printed line is rc 0, was $FRC"
no_writes U5b

# ── U6: one decider — ta_gate reads the same fixtures the same way ──────────
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)" "$(OPERATOR_LABEL)"
SET_RC=0 SET_VAL=operator run_gate
[ "$GRC" = 0 ] && ok || bad "U6: ta_gate must build the relabel (rc=$GRC line=$GLINE)"
case "$GLINE" in "allow listed actor=operator event=34882072491"*) ok ;; *) bad "U6: ta_gate PROJECT_2_LINE was '$GLINE'" ;; esac
ureset; export SET_RC=0 SET_VAL=operator
events "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)"
SET_RC=0 SET_VAL=operator run_gate
[ "$GRC" = 1 ] && ok || bad "U6: ta_gate must ignore the bot label (rc=$GRC line=$GLINE)"
case "$GLINE" in "ignored not-listed actor=github-actions[bot] event=34882000001"*) ok ;; *) bad "U6: ta_gate PROJECT_2_LINE was '$GLINE'" ;; esac

# ══ C1: the triage contract ═════════════════════════════════════════════════
CL=$(grep '^TRIGGER ACTOR:' "$DIR/catalog/agent-contracts/triage-system-append.txt")
[ -n "$CL" ] && ok || bad "C1: catalog/agent-contracts/triage-system-append.txt must have a 'TRIGGER ACTOR:' line"
grep -qE '(^|[^A-Za-z])(RETRY|REBUILD|RESUME|UNHOLD)([^A-Za-z]|$)' <<<"$CL" \
  && bad "C1: the contract line must carry no capital re-arm word" || ok

# ══ I cases: the real triage driver ═════════════════════════════════════════
IH="$T/ih"; P=project-5
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$IH/bin/lib/rt" "$IH/bin/lib/jobs" "$IH/logs" "$IH/state" "$IH/locks" "$IH/env" "$IH/flags" "$IH/prompts" \
         "$IH/builds" "$IH/fixture" "$T/icalls" "$T/repos" "$T/pathbin" "$T/tmp"
: > "$IH/env/global.env"
echo "SOP for $P. Fetch the thread. Do the work." > "$IH/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"
sed -e "s|/root/harness|$IH|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$IH/bin/run-triage.sh"
chmod +x "$IH/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$IH|g" -e "s|/root/repos|$T/repos|g" "$s" > "$IH/bin/lib/rt/$(basename "$s")"; done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$IH/bin/$s"; done
# scratch-closure-allow: the closure would install lane-gate.sh, which the driver then sources, and the wire libs (gh-rest, jobs-client, lane-switch) are stubbed below on purpose
for s in triage-shards-lib.sh triage-trigger-facts.sh trigger-actor.sh harness-self.sh; do
  [ -f "$DIR/bin/lib/$s" ] && cp "$DIR/bin/lib/$s" "$IH/bin/lib/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$IH/bin/box-name.sh"; chmod +x "$IH/bin/box-name.sh"

cat > "$IH/bin/triage-gate.sh" <<STUB
#!/bin/bash
PRJ="\$1"; MODE="\${2:-}"
cp "$IH/fixture/pending.json" "$IH/state/\$PRJ.gate.pending"
[ "\$MODE" = "--pending" ] && exit 0
cat "$IH/fixture/gate-decision"
exit 0
STUB
cat > "$IH/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$IH/fixture/diff" ] || exit 2
cat "$IH/fixture/diff"
STUB
printf '#!/bin/sh\ncat >/dev/null; exit 0\n' > "$IH/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$IH/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$IH/bin/beat.sh"
# The fake model: it acts the way the real one did on 2026-11-02, except that
# it reads the TRIGGER ACTOR line when the prompt has one.
cat > "$IH/bin/agent-call.sh" <<STUB
#!/bin/bash
PR="\$6"; case "\$PR" in @/*) PR=\$(cat "\${PR#@}") ;; esac
F=\$(mktemp "$T/icalls/prompt-XXXXXXXX.txt")
printf '%s' "\$PR" > "\$F"
if grep -q '^3524 :: allow ' <<<"\$PR"; then
  echo "TK-3524 3524 size=S kind=bug reason=relabelled-by-listed-person" >> "$IH/logs/READY-QUEUE.log"
  D="DECISION: 3524 :: queue :: the trigger-actor gate allows the newest label"
else
  D="DECISION: 3524 :: skip :: label was added by github-actions[bot], harness already commented"
fi
echo "\$D" >> "$T/icalls/decisions.log"
echo "\$D" > "\$5"
exit 0
STUB
chmod +x "$IH/bin/"*.sh
# The GitHub wire and the settings row: the seams trigger-actor.sh reads.
cat > "$IH/bin/lib/gh-rest.sh" <<STUB
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/icalls/gh_rest"
  local pg; pg=\$(printf '%s' "\$2" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p'); pg="\${pg:-1}"
  case "\$1 \$2" in
    "GET repos/example-org/project-5/issues/3524/events?"*)
      if [ -r "$IH/fixture/events-p\$pg.json" ]; then cat "$IH/fixture/events-p\$pg.json"; else echo '[]'; fi; return 0 ;;
    "GET repos/example-org/project-5/issues/3524/comments?"*)
      cat "$IH/fixture/comments.json"; return 0 ;;
  esac
  GH_REST_REASON=bad-args; return 75
}
gh_rest_comment() { echo "\$*" >> "$T/icalls/gh_rest_comment"; return 1; }
STUB
cat > "$IH/bin/jobs-client.sh" <<STUB
setting_get() {
  [ "\$1" = "trigger.actors.$P" ] && [ -s "$IH/fixture/allowlist" ] || return 2
  cat "$IH/fixture/allowlist"
}
STUB
cat > "$IH/bin/lib/lane-switch.sh" <<'STUB'
lane_switch() { [ -n "${HARNESS:-}" ] && [ -f "$HARNESS/flags/$1" ]; }
STUB
# B1: a real vendor CLI on PATH is a recorder that fails.
for v in gh curl; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s/icalls/vendor-%s"\nexit 1\n' "$T" "$v" > "$T/pathbin/$v"
  chmod +x "$T/pathbin/$v"
done

FP='{"issues":[{"number":3524,"state":"OPEN","title":"fix main red"}],"prs":[]}'
DIFF='board issues: CHANGED 3524 "fix main red" (labels: -ai-build +ai-build; activity)'
ireset() { # ireset <events: case|bot> [wake-keys]
  rm -rf "$T/icalls" "$IH/state" "$IH/locks" "$IH/logs" "$IH/builds" "$T/tmp"
  model_routes_fixture "$IH" project-5 || exit 1
  mkdir -p "$T/icalls" "$IH/state" "$IH/locks" "$IH/logs" "$IH/builds" "$T/tmp"
  printf '%s' "$FP" > "$IH/fixture/pending.json"
  printf '%s' "$FP" > "$IH/state/$P.gate.json"
  echo "RUN event-wake" > "$IH/fixture/gate-decision"
  printf '%s' "$DIFF" > "$IH/fixture/diff"
  : > "$IH/logs/READY-QUEUE.log"
  echo operator > "$IH/fixture/allowlist"
  printf '%s\n' "$(REFUSAL)" | jq -s . > "$IH/fixture/comments.json"
  case "$1" in
    case) printf '%s\n' "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)" "$(OPERATOR_LABEL)" | jq -s . > "$IH/fixture/events-p1.json" ;;
    bot)  printf '%s\n' "$(BOT_LABEL)" "$(OPERATOR_UNLABEL)" | jq -s . > "$IH/fixture/events-p1.json" ;;
  esac
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$IH/state/wake-keys-$P"
  return 0
}
irun() { HARNESS="$IH" PATH="$T/pathbin:$PATH" TMPDIR="$T/tmp" TRIAGE_SHARDS="${SHARDS:-0}" "$IH/bin/run-triage.sh" "$P" >"$T/irun.out" 2>&1; }
iprompt() { cat "$(ls "$T/icalls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null; }
ireads() { if [ -f "$T/icalls/gh_rest" ]; then grep -c 'events?' "$T/icalls/gh_rest"; else echo 0; fi; }
vendor_calls() { cat "$T/icalls"/vendor-* 2>/dev/null | grep -c .; }
VENDOR=0

# ── I1: the case, end to end ───────────────────────────────────────────────
ireset case 3524
irun
grep -q '^TRIGGER ACTOR (deterministic' <<<"$(iprompt)" && ok || bad "I1: the event-wake prompt must carry the TRIGGER ACTOR section"
grep -q '^3524 :: allow listed actor=operator event=34882072491' <<<"$(iprompt)" && ok \
  || bad "I1: the prompt must carry the gate's answer for 3524: $(grep -n '3524 ::' <<<"$(iprompt)" | head -3)"
grep -q '^TK-3524 3524 ' "$IH/logs/READY-QUEUE.log" && ok || bad "I1: triage must make a queue row for the relabelled ticket"
grep -q '^DECISION: 3524 :: queue' "$T/icalls/decisions.log" 2>/dev/null && ok || bad "I1: the model must decide queue: $(cat "$T/icalls/decisions.log" 2>/dev/null)"
grep -q 'trigger-actor facts: 3524=allow listed' "$IH/logs/$P.log" && ok || bad "I1: the project log must name the fact: $(grep -i trigger "$IH/logs/$P.log" | head -2)"
[ ! -e "$T/icalls/gh_rest_comment" ] && ok || bad "I1: triage must post no comment through the gate lib"
VENDOR=$((VENDOR + $(vendor_calls)))

# ── I2: the newest labeled event is still the bot ──────────────────────────
ireset bot 3524
irun
grep -q '^3524 :: ignore not-listed actor=github-actions\[bot\]' <<<"$(iprompt)" && ok || bad "I2: the prompt must carry the ignore line: $(grep -n '3524 ::' <<<"$(iprompt)" | head -3)"
[ ! -s "$IH/logs/READY-QUEUE.log" ] && ok || bad "I2: no queue row when the gate ignores the label: $(cat "$IH/logs/READY-QUEUE.log")"
grep -q '^DECISION: 3524 :: skip' "$T/icalls/decisions.log" 2>/dev/null && ok || bad "I2: the model must still skip"
VENDOR=$((VENDOR + $(vendor_calls)))

# ── I3: the knob at 0 turns the section off ────────────────────────────────
ireset case 3524
TRIAGE_TRIGGER_FACT_MAX_KEYS=0 irun
grep -q 'TRIGGER ACTOR (deterministic' <<<"$(iprompt)" && bad "I3: knob 0 must add no section" || ok
grep -q 'CHANGED 3524 ' <<<"$(iprompt)" && ok || bad "I3: the tick must still run its scope"
[ "$(ireads)" = 0 ] && ok || bad "I3: knob 0 must read no events ($(ireads))"
VENDOR=$((VENDOR + $(vendor_calls)))

# ── I3b: a keyless wake has no board key, so no section and no reads ────────
ireset case
irun
grep -q 'TRIGGER ACTOR (deterministic' <<<"$(iprompt)" && bad "I3b: a keyless wake must add no section" || ok
[ "$(ireads)" = 0 ] && ok || bad "I3b: a keyless wake must read no events ($(ireads))"
VENDOR=$((VENDOR + $(vendor_calls)))

# ── I4: shards on — the shard prompt carries the fact too ──────────────────
ireset case 3524
SHARDS=1 irun
SPF="$IH/state/triage-shards/$P/3524.prompt"
[ -f "$SPF" ] && ok || bad "I4: the tick must shard 3524 (no $SPF; prompts: $(ls "$T/icalls"))"
grep -q '^3524 :: allow listed actor=operator event=34882072491' "$SPF" 2>/dev/null && ok || bad "I4: the shard prompt must carry the fact line"
[ -z "$(ls -d "$T/tmp"/trigger-fact.* 2>/dev/null)" ] && ok || bad "I4: the work dir must be removed: $(ls -d "$T/tmp"/trigger-fact.*)"
for _ in $(seq 1 50); do [ -s "$T/icalls/decisions.log" ] && break; sleep 0.1; done
VENDOR=$((VENDOR + $(vendor_calls)))

# ── B1: 0 real vendor calls ────────────────────────────────────────────────
[ "$VENDOR" = 0 ] && ok || bad "B1: the I cases made $VENDOR real gh/curl call(s)"

echo "triage-trigger-facts: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
