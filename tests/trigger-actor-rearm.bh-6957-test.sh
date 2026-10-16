#!/bin/bash
# tests/trigger-actor-rearm.bh-6957-test.sh — a human RETRY after a refused
# `ai-build` label re-arms the trigger inside ta_gate (BH-6957), so the pool's
# pre-spawn check and the builder's gate give the same answer.
#
# HOW IT DRIVES: the REAL bin/lib/trigger-actor.sh, the REAL
# bin/lib/harness-self.sh and the REAL bin/jobs-client.sh (setting_get,
# job_ledger_row, job_ledger_put); only the wire is stubbed (_jobs_req, gh_rest,
# gh_rest_comment, lane_switch, bin/fleet-conf.sh) — the stub shape of
# tests/trigger-actor-gate.bh-4490-test.sh. ta_gate is called directly, the way
# bin/lib/rb/gates.sh and bin/lib/pool-actor-gate.sh call it.
#
#   R1  bot label, newer `RETRY` by a User, no allowlist row -> allow rearm
#   R2  allowlist armed with the commenter, newer `RETRY` -> allow rearm
#   R3  a `RETRY` older than the bot label -> ignored
#   R4  a newer `RETRY` by a Bot -> ignored
#   R5  allowlist armed, newer `RETRY` by an unlisted login -> ignored
#   R6  negated / conditional / lower-case text -> ignored
#   R7  the comments read fails -> ignored, PROJECT_2_LINE says `re-arm read`
#   R8  a newer `RETRY` posted through the harness App (self) -> ignored
#   R9  a re-arm closes an open ignore episode (ledger row -> allowed), posts
#       no comment; a listed re-label needs no comments read at all
# Run from anywhere: tests/trigger-actor-rearm.bh-6957-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "trigger-actor-rearm: jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/locks" "$H/logs" "$T/fx" "$T/build"
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
      if [ -r "$FX/events-p$pg.json" ]; then cat "$FX/events-p$pg.json"; else echo '[]'; fi
      return 0 ;;
    "GET repos/example-org/tproj/issues/77/comments?"*)
      [ "${CM_RC:-0}" = 0 ] || { GH_REST_REASON=rate-limit; return "$CM_RC"; }
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
export HARNESS="$H" BUILD="$T/build"
export HARNESS_SELF_APPS="cromford cromford-board cromford-builders"
export HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.example.test
export PROJECT_2_EVENTS_RETRIES=0
export -n GH_ISSUES_REPO 2>/dev/null; unset GH_ISSUES_REPO

LABEL_AT=2026-10-15T08:00:00Z
# ev <id> <login> <type> <created_at> [app-slug]
ev() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg s "${5:-}" \
    '{id:$id, event:"labeled", actor:{login:$l, type:$t}, label:{name:"ai-build"}, created_at:$c,
      performed_via_github_app:(if $s == "" then null else {slug:$s} end)}'
}
# cm <id> <login> <type> <created_at> <body> [app-slug] — the comment shape GitHub answers
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg b "$5" --arg s "${6:-}" \
    '{id:$id, user:{login:$l, type:$t}, created_at:$c, updated_at:$c, body:$b,
      performed_via_github_app:(if $s == "" then null else {slug:$s} end)}'
}
events() { printf '%s\n' "$@" | jq -s . > "$FX/events-p1.json"; }
comments() { if [ $# -eq 0 ]; then echo '[]' > "$FX/comments-p1.json"; else printf '%s\n' "$@" | jq -s . > "$FX/comments-p1.json"; fi; }
reset() {
  rm -f "$FX"/*.json "$LEDGER"
  scratch_rm "$CALLS" || exit 1; mkdir -p "$CALLS"
  unset SET_RC SET_VAL CM_RC
  events "$(ev 9001 'github-actions[bot]' Bot "$LABEL_AT")"
  comments
}
# run_gate — RC and LINE from one real ta_gate call
run_gate() {
  local out
  out=$(bash -c '. "$STUBS"; . "$HARNESS/bin/lib/trigger-actor.sh"; rc=0
                 ta_gate tproj BH-77 77 "$BUILD" || rc=$?
                 printf "%s\n%s\n" "$rc" "$PROJECT_2_LINE"' 2>"$T/stderr")
  RC=$(sed -n 1p <<<"$out"); LINE=$(sed -n 2p <<<"$out")
}
cnt() { if [ -f "$CALLS/$1" ]; then grep -c "${2:-.}" "$CALLS/$1"; else echo 0; fi; }

# ── baseline: the bot label alone is ignored ────────────────────────────────
reset
run_gate
[ "$RC" = 1 ] && ok || bad "R0: a bot label with no comment must be ignored (rc=$RC line=$LINE)"
case "$LINE" in "ignored bot actor=github-actions[bot] event=9001"*) ok ;; *) bad "R0: PROJECT_2_LINE was '$LINE'" ;; esac

# ── R1 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 501 operator User 2026-10-15T09:00:00Z 'RETRY')"
run_gate
[ "$RC" = 0 ] && ok || bad "R1: a newer human RETRY must re-arm (rc=$RC line=$LINE)"
case "$LINE" in "allow rearm actor=operator event=comment-501"*) ok ;; *) bad "R1: PROJECT_2_LINE must start 'allow rearm actor=operator event=comment-501', was '$LINE'" ;; esac
grep -q "GET repos/example-org/tproj/issues/77/comments?.*since=$LABEL_AT" "$CALLS/gh" && ok \
  || bad "R1: the comments read must ask since the label time: $(cat "$CALLS/gh")"
[ "$(cnt comments)" = 0 ] && ok || bad "R1: a re-arm posts no refusal comment"

# ── R2 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 502 operator User 2026-10-15T09:00:00Z 'please RETRY now')"
SET_RC=0 SET_VAL="operator alice" run_gate
[ "$RC" = 0 ] && ok || bad "R2: a listed human's RETRY must re-arm (rc=$RC line=$LINE)"
case "$LINE" in "allow rearm actor=operator event=comment-502"*) ok ;; *) bad "R2: PROJECT_2_LINE was '$LINE'" ;; esac

# ── R3 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 503 operator User 2026-10-15T07:59:59Z 'RETRY')"
run_gate
[ "$RC" = 1 ] && ok || bad "R3: a RETRY older than the bot label must not re-arm (rc=$RC line=$LINE)"
# the same second as the label is not newer either
reset
comments "$(cm 504 operator User "$LABEL_AT" 'RETRY')"
run_gate
[ "$RC" = 1 ] && ok || bad "R3b: a RETRY at the label's own second must not re-arm (rc=$RC line=$LINE)"

# ── R4 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 505 'dependabot[bot]' Bot 2026-10-15T09:00:00Z 'RETRY')"
run_gate
[ "$RC" = 1 ] && ok || bad "R4: a Bot's RETRY must not re-arm (rc=$RC line=$LINE)"
# a Bot type with a human-looking login is still a Bot
reset
comments "$(cm 506 helper Bot 2026-10-15T09:00:00Z 'RETRY')"
run_gate
[ "$RC" = 1 ] && ok || bad "R4b: user.type Bot must not re-arm whatever the login (rc=$RC)"
# a Bot on an armed allowlist may re-label, but its comment never re-arms
reset
comments "$(cm 514 'helper-app[bot]' Bot 2026-10-15T09:00:00Z 'RETRY')"
SET_RC=0 SET_VAL="operator helper-app[bot]" run_gate
[ "$RC" = 1 ] && ok || bad "R4c: a listed Bot's RETRY comment must not re-arm (rc=$RC line=$LINE)"

# ── R5 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 507 someone-else User 2026-10-15T09:00:00Z 'RETRY')"
SET_RC=0 SET_VAL="operator alice" run_gate
[ "$RC" = 1 ] && ok || bad "R5: an unlisted login on an armed project must not re-arm (rc=$RC line=$LINE)"
case "$LINE" in "ignored not-listed actor=github-actions[bot]"*) ok ;; *) bad "R5: the label refusal must stand: '$LINE'" ;; esac

# ── R6 ──────────────────────────────────────────────────────────────────────
for body in 'do not RETRY yet' 'If needed, comment `RETRY` on the ticket' 'Rebuilt this ticket fresh against current main' 'retry please'; do
  reset
  comments "$(cm 508 operator User 2026-10-15T09:00:00Z "$body")"
  run_gate
  [ "$RC" = 1 ] && ok || bad "R6: '$body' must not re-arm (rc=$RC line=$LINE)"
done
# the harness's own refusal text (what _ta_post posts) must never re-arm
reset
run_gate                                   # posts the refusal comment once
REFUSAL=$(sed '1d' "$CALLS/comments" 2>/dev/null)
[ -n "$REFUSAL" ] && ok || bad "R6: the baseline refusal comment was not captured"
reset
comments "$(cm 509 operator User 2026-10-15T09:00:00Z "$REFUSAL")"
run_gate
[ "$RC" = 1 ] && ok || bad "R6: the harness's own refusal comment must not re-arm (rc=$RC)"
# a negated RETRY then a plain one: the plain one wins
reset
comments "$(cm 510 operator User 2026-10-15T09:00:00Z 'do not RETRY yet')" "$(cm 511 operator User 2026-10-15T10:00:00Z 'RETRY')"
run_gate
[ "$RC" = 0 ] && case "$LINE" in *"event=comment-511"*) true ;; *) false ;; esac && ok \
  || bad "R6b: the later plain RETRY must re-arm (rc=$RC line=$LINE)"

# ── R7 ──────────────────────────────────────────────────────────────────────
reset
CM_RC=75 run_gate
[ "$RC" = 1 ] && ok || bad "R7: a failed comments read keeps the ignore (rc=$RC line=$LINE)"
case "$LINE" in *"re-arm read"*) ok ;; *) bad "R7: PROJECT_2_LINE must say 're-arm read': '$LINE'" ;; esac

# ── R8 ──────────────────────────────────────────────────────────────────────
reset
comments "$(cm 512 operator User 2026-10-15T09:00:00Z 'RETRY' cromford)"
run_gate
[ "$RC" = 1 ] && ok || bad "R8: a RETRY performed via the harness App must not re-arm (rc=$RC line=$LINE)"

# ── R9 ──────────────────────────────────────────────────────────────────────
reset
run_gate                                   # the ignore episode opens, comments once
[ "$(jq -r .status "$LEDGER" 2>/dev/null)" = ignored ] && ok || bad "R9: the ignore must open an episode: $(cat "$LEDGER" 2>/dev/null)"
scratch_rm "$CALLS" || exit 1; mkdir -p "$CALLS"
comments "$(cm 513 operator User 2026-10-15T09:00:00Z 'RETRY')"
run_gate
[ "$RC" = 0 ] && ok || bad "R9: the RETRY must re-arm (rc=$RC line=$LINE)"
[ "$(jq -r .status "$LEDGER" 2>/dev/null)" = allowed ] && ok || bad "R9: the re-arm must close the episode: $(cat "$LEDGER" 2>/dev/null)"
[ "$(jq -r '.detail | fromjson | .why + "|" + .event + "|" + .actor' "$LEDGER" 2>/dev/null)" = "rearm|comment-513|operator" ] && ok \
  || bad "R9: the closing row must record why=rearm event=comment-513 actor=operator: $(cat "$LEDGER")"
[ "$(cnt comments)" = 0 ] && ok || bad "R9: the re-arm must post no comment"
# a listed re-label is allowed on the label alone: no comments read
reset
events "$(ev 9001 'github-actions[bot]' Bot "$LABEL_AT")" "$(ev 9002 operator User 2026-10-15T19:29:00Z)"
run_gate
[ "$RC" = 0 ] && ok || bad "R9b: a human re-label must build (rc=$RC line=$LINE)"
[ "$(cnt gh comments)" = 0 ] && ok || bad "R9b: an allowed label must not read the comments: $(cat "$CALLS/gh")"

echo "trigger-actor-rearm: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
