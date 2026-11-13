#!/bin/bash
# tests/gh-session-token.bh-9354-test.sh — a triage session's gh keeps a valid
# token for the whole session (BH-9354).
#
# THE INCIDENT. On 2026-11-09 four triage sessions on the small box got `HTTP
# 401 Bad credentials` from gh while the box's App token and PAT answered 200.
# The tick mints one App token and exports it; bin/gh-ledger/gh only picks an
# identity when GH_TOKEN is empty, so a token that went bad stayed in the
# session to the end.
#
# WHAT IS PINNED (the session is armed by the real triage_gh_session_arm, then
# runs `gh` from a cron-shaped PATH: the wrapper, a copy of bin/gh-ledger/gh, a
# fake real gh):
#   D   the 401 decision table and the retry eligibility (bin/lib/gh-session-token.sh)
#   R1  an expired armed token: rung 0 re-mints, the call succeeds, no alert
#   R2  rung 0 hands the same bad token, --fresh a good one: one response body,
#       one recovered line in the project log, no alert
#   R3  the mint fails or hands only bad tokens: env/gh-pat answers, no alert
#   R4  a mint that prints the PAT is not an App rung (rung 0 keeps the armed
#       token; GH_SESSION_PAT_FALLBACK=0 means no PAT ever)
#   A1  every credential refused, box probe app=200 pat=200: ONE alert naming
#       ghs_, the expiry, the pat rung and the probe; no "dead"/"lost"; the
#       stderr line for the agent; the call-guard marker; gh's rc
#   A2  probe refused too -> "also refused"; A3 probe cannot run -> "could not run";
#       A3b a PAT from the probe's mint is not an app= result
#   A4  a second all-401 call inside the window writes no second alert
#   S   no token value in ALERTS.log, a project log or stderr
#   P   pass-through: not armed, a caller's own token, GH_SESSION_DEPTH,
#       GH_SESSION_REMINT=0 after arming (the knob row is the off switch)
#   N   403 / rate limit / 404: one call, output unchanged
#   L   wrapper copies and gh-ledger on one PATH: gh runs once, no rc 127
#
# Nothing touches the network: bin/gh-token.sh and the real gh are stubs.
# Run from anywhere: bash tests/gh-session-token.bh-9354-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v sha256sum >/dev/null || { echo "sha256sum missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/env" "$H/flags" "$H/logs" "$H/state" "$T/real" "$T/home" "$T/tmp" "$T/wcopy"
for s in bin/gh-session/gh bin/gh-ledger/gh bin/lib/gh-session-token.sh bin/lib/triage-gh-token.sh \
         bin/lib/gh-app-default.sh; do
  if [ -f "$DIR/$s" ]; then
    scratch_install_closure "$s" "$H" >/dev/null || bad "fixture: cannot install the closure of $s"
  fi
done
[ -x "$H/bin/gh-session/gh" ] && ok || bad "fixture: bin/gh-session/gh is not shipped (or not executable)"

ARMED="ghs_fixtureexpiredarmed000000000000000"
GOOD1="ghs_fixturegoodmint0000000000000000000"
GOOD2="ghs_fixturefreshmint000000000000000000"
PAT="ghp_fixturepatfromfile0000000000000000"
fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
printf 'GH_TOKEN=%s\n' "$PAT" > "$H/env/gh-pat"

# bin/gh-token.sh — records its argv, answers per mode (TOKSTUB_MIN for
# --min-life, TOKSTUB_FRESH for --fresh, TOKSTUB_PLAIN for a bare slug).
cat > "$H/bin/gh-token.sh" <<STUB
#!/bin/bash
printf '%s|depth=%s|tok=%s\n' "\$*" "\${GH_SESSION_DEPTH:-}" "\${GH_TOKEN:+set}" >> "$T/mints.txt"
case "\$1" in
  --expires-at) echo 2026-11-09T18:00:00Z; exit 0 ;;
  --min-life) m="\${TOKSTUB_MIN:-good1}" ;;
  --fresh)    m="\${TOKSTUB_FRESH:-good2}" ;;
  *)          m="\${TOKSTUB_PLAIN:-good1}" ;;
esac
case "\$m" in
  good1) echo "$GOOD1" ;; good2) echo "$GOOD2" ;; armed) echo "$ARMED" ;;
  pat) echo "$PAT" ;; fail) exit 1 ;;
esac
STUB
chmod +x "$H/bin/gh-token.sh"

# The real gh: logs each call's token FINGERPRINT and argv; a token in
# FAKE_GOOD answers, anything else gets gh's 401. FAKE_MODE forces a non-401 error.
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
# gh-ledger's one-off trace-format probe is not a call under test.
[ "${1:-} ${2:-}" = "api rate_limit" ] && exit 0
f=$(printf '%s' "${GH_TOKEN:-}" | sha256sum | cut -c1-16)
printf '%s|%s\n' "$f" "$*" >> "$GH_STUB_CALLS"
case "${FAKE_MODE:-}" in
  403int) echo 'HTTP 403: Resource not accessible by integration (https://api.github.com/repos/example-org/x/issues)' >&2; exit 1 ;;
  403rl)  echo 'API rate limit exceeded for installation ID 4242. (HTTP 403)' >&2; exit 1 ;;
  404)    echo '{"message":"Not Found","note":"Bad credentials (HTTP 401) quoted in a body"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
esac
good=0
for g in ${FAKE_GOOD:-}; do [ "$g" = "${GH_TOKEN:-}" ] && good=1; done
if [ "${1:-} ${2:-}" = "api -i" ]; then
  if [ "$good" = 1 ]; then printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"full_name":"example-org/x"}\n'; exit 0; fi
  printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'; echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1
fi
if [ "$good" = 1 ]; then echo '{"number":2,"title":"fixture body"}'; exit 0; fi
echo '{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}'
echo 'gh: Bad credentials (HTTP 401)' >&2
exit 1
STUB
chmod +x "$T/real/gh"
# a second copy of the wrapper at another path, ahead of the real one (section L)
[ -f "$DIR/bin/gh-session/gh" ] && cp "$DIR/bin/gh-session/gh" "$T/wcopy/gh" && chmod +x "$T/wcopy/gh"

# srun <gh argv…> — a triage session: arm with the real triage_gh_session_arm
# on GH_TOKEN=$SR_TOKEN (default the armed App token), then `gh <argv>`.
# SR_TOK2 = the token a caller sets AFTER arming; SR_OFF=1 sets the knob
# GH_SESSION_REMINT=0 after arming; SR_PATH_HEAD = dirs put before everything; SR_ENV = extra K=V.
DEFGOOD="$GOOD1 $GOOD2 $PAT"
srun() {
  : > "$T/calls.txt"; : > "$T/mints.txt"; rm -f "$T/marker"
  # shellcheck disable=SC2086
  env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
    HARNESS="$H" HARNESS_ENV_DIR="$H/env" GH_STUB_CALLS="$T/calls.txt" GH_CACHE_TTL_S=0 \
    GH_TOKEN="${SR_TOKEN:-$ARMED}" GH_SESSION_AUTH_FAIL_FILE="$T/marker" \
    FAKE_GOOD="${FAKE_GOOD-$DEFGOOD}" FAKE_MODE="${FAKE_MODE:-}" \
    TOKSTUB_MIN="${TOKSTUB_MIN:-good1}" TOKSTUB_FRESH="${TOKSTUB_FRESH:-good2}" TOKSTUB_PLAIN="${TOKSTUB_PLAIN:-good1}" \
    SR_TOK2="${SR_TOK2:-}" SR_OFF="${SR_OFF:-}" SR_PATH_HEAD="${SR_PATH_HEAD:-}" ${SR_ENV:-} \
    bash -c '
      . "$HARNESS/bin/lib/triage-gh-token.sh" 2>/dev/null
      command -v triage_gh_session_arm >/dev/null 2>&1 && { triage_gh_session_arm example-org/x fixproj || true; }
      [ -n "$SR_TOK2" ] && export GH_TOKEN="$SR_TOK2"
      [ -n "$SR_OFF" ] && export GH_SESSION_REMINT=0
      [ -n "$SR_PATH_HEAD" ] && export PATH="$SR_PATH_HEAD:$PATH"
      exec gh "$@"' _ "$@" > "$T/out.txt" 2> "$T/err.txt"
  SRC=$?
  cat "$T/err.txt" >> "$T/allerr.txt"
}
ncalls() { grep -c . "$T/calls.txt" 2>/dev/null; }
call_fps() { cut -d'|' -f1 "$T/calls.txt" | tr '\n' ' '; }
nalerts() { grep -c '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null || true; }
# the dedupe stamp is gh_app_default_alert's (bin/lib/gh-app-default.sh): state/gh-app-default.alerted/gh-session-<slug>
reset_alerts() { scratch_rm "$H/state/gh-app-default.alerted"; : > "$H/logs/ALERTS.log"; }
: > "$T/allerr.txt"; reset_alerts

# ── D. the decision table ───────────────────────────────────────────────────
if [ -r "$DIR/bin/lib/gh-session-token.sh" ]; then
  # shellcheck source=bin/lib/gh-session-token.sh
  . "$DIR/bin/lib/gh-session-token.sh"
  dcase() { # <name> <rc> <stderr text> <want 0|1>
    printf '%s\n' "$3" > "$T/d.err"
    gh_session_is_401 "$2" "$T/d.err"; local got=$?
    [ "$got" = "$4" ] && ok || bad "D $1: gh_session_is_401 rc=$2 stderr='$3' gave $got, want $4"
  }
  dcase "gh api 401"          1 'gh: Bad credentials (HTTP 401)' 0
  dcase "pr view graphql 401" 1 'HTTP 401: Bad credentials (https://api.github.com/graphql)' 0
  dcase "requires auth"       1 'Requires authentication (HTTP 401)' 0
  dcase "403 integration"     1 'HTTP 403: Resource not accessible by integration' 1
  dcase "403 rate limit"      1 'API rate limit exceeded for installation ID 1. (HTTP 403)' 1
  dcase "404"                 1 'HTTP 404: Not Found' 1
  dcase "HTTP 4010"           1 'HTTP 4010: malformed' 1
  dcase "rc 0 stderr warning" 0 'warning: Bad credentials (HTTP 401) seen earlier' 1
  dcase "rc 1 clean stderr"   1 '' 1
  # stdout is never read: the decision only ever gets the stderr file
  printf 'gh: Not Found (HTTP 404)\n' > "$T/d.err"
  gh_session_is_401 1 "$T/d.err" && bad "D 404 with 401 text on stdout must not read as 401" || ok
  gh_session_is_401 1 "$T/no-such-file" && bad "D a missing stderr file is not a 401" || ok
  rcase() { # <want 0|1> <argv…>
    local want="$1"; shift
    gh_session_retry_ok "$@"; local got=$?
    [ "$got" = "$want" ] && ok || bad "D retry_ok '$*' gave $got, want $want"
  }
  rcase 1 api graphql --input -
  rcase 1 issue comment 1 --body-file -
  rcase 1 api repos/x -F body=@-
  rcase 1 issue create --body-file=-
  rcase 1 run watch 123
  rcase 1 pr checks 2 --watch
  rcase 1 auth status
  rcase 1 api repos/x --input /dev/stdin
  rcase 0 api repos/x
  rcase 0 issue comment 1 --body hi
  rcase 0 pr view 2
  [ "$(gh_session_tok_desc "$GOOD1")" = "ghs_ len ${#GOOD1}" ] && ok || bad "D tok_desc names prefix and length, got '$(gh_session_tok_desc "$GOOD1")'"
  [ "$(gh_session_tok_fp "$GOOD1")" = "$(fp "$GOOD1")" ] && ok || bad "D tok_fp is the sha256 16-hex prefix"
  [ "$(gh_session_verdict 'app=200 pat=401')" != "$(gh_session_verdict 'app=401 pat=401')" ] && ok || bad "D verdict differs between a 200 probe and a refused one"
else
  bad "D: bin/lib/gh-session-token.sh is not shipped"
fi

# ── R1. expired armed token: rung 0 re-mints ────────────────────────────────
srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && ok || bad "R1: gh must succeed on the re-minted token (rc $SRC, stderr: $(head -c 300 "$T/err.txt"))"
[ "$(call_fps)" = "$(fp "$GOOD1") " ] && ok || bad "R1: the real gh must see only the re-minted token, saw fps '$(call_fps)' (armed=$(fp "$ARMED") good=$(fp "$GOOD1"))"
grep -q '"number":2' "$T/out.txt" && ok || bad "R1: the response reaches stdout"
grep -q -- "--min-life 600 example-org/x|depth=1|tok=" "$T/mints.txt" && ok || bad "R1: rung 0 asks gh-token.sh --min-life 600 with no GH_TOKEN and GH_SESSION_DEPTH=1 (mints: $(tr '\n' ';' < "$T/mints.txt"))"
[ "$(nalerts)" = 0 ] && ok || bad "R1: no ALERTS line on a recovered session"
[ ! -e "$T/marker" ] && ok || bad "R1: no call-guard marker"

# ── R2. rung 0 hands the same bad token, --fresh a good one ─────────────────
TOKSTUB_MIN=armed srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && ok || bad "R2: gh must succeed on the fresh mint (rc $SRC)"
[ "$(call_fps)" = "$(fp "$ARMED") $(fp "$GOOD2") " ] && ok || bad "R2: 401 on the armed token, then the fresh one, saw '$(call_fps)'"
[ "$(grep -c '"number":2' "$T/out.txt")" = 1 ] && ok || bad "R2: ONE response body on stdout"
grep -q 'Bad credentials' "$T/out.txt" && bad "R2: the refused attempt's body must not reach stdout" || ok
grep -q 'Bad credentials' "$T/err.txt" && bad "R2: the refused attempt's stderr must not reach the caller" || ok
grep -q "gh-session: recovered 401 for example-org/x on rung 1 (refused token ghs_ len ${#ARMED}" "$H/logs/fixproj.log" 2>/dev/null \
  && ok || bad "R2: one recovered line in logs/fixproj.log naming the refused token"
[ "$(nalerts)" = 0 ] && ok || bad "R2: no ALERTS line"
# the same through `gh api`
TOKSTUB_MIN=armed srun api repos/example-org/x/issues/2
[ "$SRC" = 0 ] && [ "$(grep -c '"number":2' "$T/out.txt")" = 1 ] && ok || bad "R2 api: rc 0 and one body (rc $SRC)"

# ── R3. no App token works: env/gh-pat answers ──────────────────────────────
TOKSTUB_MIN=fail TOKSTUB_FRESH=fail srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && ok || bad "R3a: mint fails, the PAT rung must answer (rc $SRC)"
[ "$(call_fps)" = "$(fp "$ARMED") $(fp "$PAT") " ] && ok || bad "R3a: armed token, then env/gh-pat, saw '$(call_fps)'"
[ "$(nalerts)" = 0 ] && [ ! -e "$T/marker" ] && ok || bad "R3a: no ALERTS line, no marker"
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && ok || bad "R3b: both mints hand the bad token, the PAT must answer (rc $SRC)"
[ "$(call_fps)" = "$(fp "$ARMED") $(fp "$PAT") " ] && ok || bad "R3b: a rung that repeats a tried token is skipped, saw '$(call_fps)'"
grep -q "on rung 2" "$H/logs/fixproj.log" 2>/dev/null && ok || bad "R3b: the recovered line names rung 2"

# ── R4. a mint that prints the PAT (gh-token.sh's failed-mint answer) is not an App rung
TOKSTUB_MIN=pat TOKSTUB_FRESH=pat FAKE_GOOD="$GOOD1 $GOOD2" SR_ENV="GH_SESSION_PAT_FALLBACK=0" srun pr view 2 -R example-org/x
# the session call runs on the armed token only; the last two calls are the box probe (App, then env/gh-pat)
[ "$(call_fps)" = "$(fp "$ARMED") $(fp "$GOOD1") $(fp "$PAT") " ] && ok || bad "R4: with the PAT rung off, a mint that prints the PAT must not be a session rung; saw '$(call_fps)' (pat=$(fp "$PAT"))"
TOKSTUB_MIN=pat srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && [ "$(call_fps)" = "$(fp "$ARMED") $(fp "$GOOD2") " ] && ok || bad "R4: rung 0 keeps the armed token when the cache answers a PAT, then --fresh answers (rc $SRC, '$(call_fps)')"

# ── A1. every credential refused, the box probe answers 200 ─────────────────
reset_alerts
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed FAKE_GOOD="$GOOD1 $PAT" SR_ENV="GH_SESSION_PAT_FALLBACK=0" srun pr view 2 -R example-org/x
[ "$SRC" = 1 ] && ok || bad "A1: rc is gh's rc (1), got $SRC"
[ "$(nalerts)" = 1 ] && ok || bad "A1: exactly ONE [gh-session] ALERTS line, got $(nalerts)"
AL=$(grep '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null)
for want in "ghs_ len ${#ARMED}" "2026-11-09T18:00:00Z" "pat" "app=200 pat=200" "The box credentials are valid" "example-org/x"; do
  case "$AL" in *"$want"*) ok ;; *) bad "A1: the alert must name '$want': $AL" ;; esac
done
grep -qE "\\[gh-session\\] [^ ]+ fixproj gh 401 on every credential for example-org/x: tried " <<<"$AL" && ok || bad "A1: the alert line shape is '[gh-session] <host> <project> gh 401 on every credential for <slug>: tried …': $AL"
[ -s "$H/state/gh-app-default.alerted/gh-session-example-org-x" ] && ok || bad "A1: the dedupe stamp is gh_app_default_alert's, source gh-session"
grep -qiE 'dead|lost' <<<"$AL" && bad "A1: the alert must not call the box token dead or lost: $AL" || ok
grep -q 'gh-session: every credential this session holds got 401' "$T/err.txt" && ok || bad "A1: the stderr line for the agent is missing"
grep -q 'The box credentials are valid' "$T/err.txt" && ok || bad "A1: the stderr line carries the probe verdict"
[ -e "$T/marker" ] && ok || bad "A1: the call-guard marker (GH_SESSION_AUTH_FAIL_FILE) must exist"
[ "$(grep -c 'Bad credentials' "$T/out.txt")" = 1 ] && ok || bad "A1: the last attempt's output reaches the caller once"
# A1b: the PAT rung is on and refused too; the App probe still answers 200
reset_alerts
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed FAKE_GOOD="$GOOD1" srun pr view 2 -R example-org/x
AL=$(grep '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null)
case "$AL" in *"ghp_ len ${#PAT}"*"app=200 pat=401"*"The box credentials are valid"*) ok ;; *) bad "A1b: the alert names the refused PAT and app=200 pat=401: $AL" ;; esac
[ "$(call_fps)" = "$(fp "$ARMED") $(fp "$PAT") $(fp "$GOOD1") $(fp "$PAT") " ] && ok || bad "A1b: two session calls, then the two probe GETs, saw '$(call_fps)'"

# ── A2. the probe is refused too ────────────────────────────────────────────
reset_alerts
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed TOKSTUB_PLAIN=armed FAKE_GOOD="" srun pr view 2 -R example-org/x
AL=$(grep '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null)
case "$AL" in *"app=401 pat=401"*"The box credentials are also refused."*) ok ;; *) bad "A2: probe refused -> 'also refused': $AL" ;; esac
case "$AL" in *"are valid"*) bad "A2: must not say the box credentials are valid: $AL" ;; *) ok ;; esac

# ── A4. a second all-401 call inside the window adds no alert ──────────────
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed TOKSTUB_PLAIN=armed FAKE_GOOD="" srun pr view 2 -R example-org/x
[ "$(nalerts)" = 1 ] && ok || bad "A4: one alert per slug per window, got $(nalerts)"
[ -e "$T/marker" ] && ok || bad "A4: the marker is still written on a deduped alert"
# with the window at 0 every all-401 call alerts
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed TOKSTUB_PLAIN=armed FAKE_GOOD="" SR_ENV="GH_SESSION_ALERT_EVERY_S=0" srun pr view 2 -R example-org/x
[ "$(nalerts)" = 2 ] && ok || bad "A4: GH_SESSION_ALERT_EVERY_S=0 alerts again, got $(nalerts)"

# ── A3. the probe cannot run ────────────────────────────────────────────────
reset_alerts
mv "$H/env/gh-pat" "$T/gh-pat.away"
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed TOKSTUB_PLAIN=fail FAKE_GOOD="" srun pr view 2 -R example-org/x
AL=$(grep '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null)
case "$AL" in *"app=none pat=none"*"The box probe could not run."*) ok ;; *) bad "A3: no probe credential -> 'could not run': $AL" ;; esac
mv "$T/gh-pat.away" "$H/env/gh-pat"
# A3b: the probe's mint prints the PAT: that is not an App probe
reset_alerts
TOKSTUB_MIN=armed TOKSTUB_FRESH=armed TOKSTUB_PLAIN=pat FAKE_GOOD="$PAT" SR_ENV="GH_SESSION_PAT_FALLBACK=0" srun pr view 2 -R example-org/x
AL=$(grep '\[gh-session\]' "$H/logs/ALERTS.log" 2>/dev/null)
case "$AL" in *"app=none pat=200"*) ok ;; *) bad "A3b: a PAT from the probe's mint is not reported as app=: $AL" ;; esac

# ── P. pass-through ─────────────────────────────────────────────────────────
SR_TOKEN="$PAT" srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && [ "$(call_fps)" = "$(fp "$PAT") " ] && ok || bad "P1: a PAT session is not armed: one call on its own token (rc $SRC, '$(call_fps)')"
grep -q -- '--min-life' "$T/mints.txt" && bad "P1: no re-mint when not armed" || ok
SR_TOK2="$GOOD2" srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && [ "$(call_fps)" = "$(fp "$GOOD2") " ] && ok || bad "P2: a caller's own token passes untouched ('$(call_fps)')"
grep -q -- '--min-life' "$T/mints.txt" && bad "P2: no re-mint for a caller's own token" || ok
SR_ENV="GH_SESSION_DEPTH=1" srun pr view 2 -R example-org/x
[ "$SRC" = 1 ] && [ "$(call_fps)" = "$(fp "$ARMED") " ] && ok || bad "P3: GH_SESSION_DEPTH=1 execs straight through, one call, no retry (rc $SRC, '$(call_fps)')"
SR_OFF=1 srun pr view 2 -R example-org/x
[ "$SRC" = 1 ] && [ "$(call_fps)" = "$(fp "$ARMED") " ] && ok || bad "P4: GH_SESSION_REMINT=0 passes through (rc $SRC, '$(call_fps)')"

# ── N. non-401 failures run once and reach the caller unchanged ────────────
for m in 403int 403rl 404; do
  FAKE_MODE=$m srun pr view 2 -R example-org/x
  [ "$SRC" = 1 ] && [ "$(ncalls)" = 1 ] && ok || bad "N $m: one call, rc 1 (rc $SRC, calls $(ncalls))"
  case "$m" in
    403int) grep -q 'Resource not accessible by integration' "$T/err.txt" && ok || bad "N $m: stderr reaches the caller" ;;
    403rl)  grep -q 'API rate limit exceeded' "$T/err.txt" && ok || bad "N $m: stderr reaches the caller" ;;
    404)    grep -q '"message":"Not Found"' "$T/out.txt" && grep -q 'HTTP 404' "$T/err.txt" && ok || bad "N $m: stdout and stderr reach the caller" ;;
  esac
done
[ ! -e "$T/marker" ] && ok || bad "N: no marker on a non-401 failure"

# ── L. no loop with copies on PATH ──────────────────────────────────────────
SR_PATH_HEAD="$T/wcopy" srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "L: a second wrapper copy ahead on PATH: gh runs once, rc 0 (rc $SRC, calls $(ncalls), stderr $(head -c 200 "$T/err.txt"))"
mkdir -p "$T/ledger2"; cp "$DIR/bin/gh-ledger/gh" "$T/ledger2/gh"; chmod +x "$T/ledger2/gh"
SR_PATH_HEAD="$T/wcopy:$T/ledger2" srun pr view 2 -R example-org/x
[ "$SRC" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "L: wrapper : gh-ledger copy : wrapper : gh-ledger: gh runs once, rc 0 (rc $SRC, calls $(ncalls))"

# ── S. no token value anywhere ──────────────────────────────────────────────
for t in "$ARMED" "$GOOD1" "$GOOD2" "$PAT"; do
  if grep -qF -- "$t" "$H/logs/ALERTS.log" "$H"/logs/*.log "$T/allerr.txt" 2>/dev/null; then
    bad "S: a token value (${t:0:4}…) reached a log or stderr"
  else ok; fi
done

echo "gh-session-token.bh-9354: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
