#!/bin/bash
# tests/auth-probe-classify-test.sh — "the probe said nothing" must never be
# read as "the account is dead" (2026-08-27, the false hub AUTH DOWN).
#
# The 17:51Z page told the operator to re-login operator@example.com on the strength of a
# BLANK probe result with rc=137. rc=137 is SIGKILL: the process was killed
# before Claude answered. The account was fine the whole time. The cost of that
# class of mistake is not the page — it is that a believed-dead Claude lane is
# exactly what sends stages to OpenRouter to re-buy the same context at API
# price. So AUTH DOWN is now claimed only on positive credential evidence, and
# everything else that is not "ok" is INCONCLUSIVE.
#
# classify_probe is sourced directly (AUTH_CHECK_LIB=1 returns before the box
# loop), so this test drives the real classifier, not a copy of it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The scratch tree lives in T and ONLY T is ever removed. The sourced script
# below assigns its own H (2026-09-15: it resolved H to /root/harness inside
# this shell, and the old `trap 'rm -rf "$H"'` then deleted the live hub
# install — the 16:50Z wipe). Nothing sourced may be allowed to steer the trap.
case "$T" in /tmp/*|"${TMPDIR:-/nonexistent}"*|/private/*|/var/folders/*) ;; *) echo "FAIL: scratch dir $T is not under a temp root"; exit 1;; esac
H="$T"
mkdir -p "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/bin"
# shellcheck disable=SC1090
AUTH_CHECK_LIB=1 HARNESS="$T" . "$DIR/bin/claude-auth-check.sh" || true
H="$T"   # re-pin: the sourced file sets H for itself; this test's H is the scratch tree

if ! declare -F classify_probe >/dev/null; then
  echo "FAIL: classify_probe is not exposed (AUTH_CHECK_LIB early-return missing)"; exit 1
fi

check() { # check <expected> <label> <probe output>
  local got; got=$(classify_probe "$3")
  [ "$got" = "$1" ] && ok || bad "$2: expected $1, got $got  <<$3>>"
}

# --- the incident itself -------------------------------------------------
check inconclusive "blank probe (the rc=137 kill)" ""
check inconclusive "killed probe, INCONCLUSIVE marker" \
  "INCONCLUSIVE probe did not answer (rc=137) — process killed or silent, no credential verdict"
check inconclusive "unrecognised noise is not an auth verdict" \
  "Error: connection reset by peer"

# --- real auth failures still page ---------------------------------------
check authdown "not logged in" "Invalid API key · Please run /login"
check authdown "expired setup-token" "Your token has expired, run claude setup-token"
check authdown "401" "API error: 401 unauthorized"

# --- healthy / degraded unchanged ----------------------------------------
check ok "plain ok" "ok"
check degraded "credits-dry ladder" "DEGRADED claude-fable-5 is out of usage credits; claude-opus-5 is serving"

# --- the probe body retries a kill before reporting anything -------------
grep -q 'killed && ask' "$DIR/bin/claude-auth-check.sh" \
  && ok || bad "the probe no longer retries once on a killed run"
grep -q 'inconclusive_note' "$DIR/bin/claude-auth-check.sh" \
  && ok || bad "inconclusive probes have no reporting path"
# an inconclusive probe must not touch the auth-down state file, or the next
# real outage would be deduped away as 'already alerted'
grep -q 'STATE' <<<"$(grep -A6 '^inconclusive_note()' "$DIR/bin/claude-auth-check.sh")" \
  && bad "inconclusive_note writes the auth-down state file" || ok

# --- BH-1019: this probe is the merge conductor's recovery event -----------
# A quota 429 / spend limit is `inconclusive` above and never reaches $STATE by
# design. The merge conductor keeps its OWN state/merge-conductor/lane-down
# marker for that class and buys no head-bound re-review while it stands — so
# during such an outage nothing the conductor runs ever asks the vendor again.
# This hourly end-to-end probe is the one thing on the box that still does, and
# when it answers `ok` the lane IS up whatever $STATE says. Driven by lifting
# the real block, not grepped: a redirection attached to the wrong arm would
# pass a grep and strand every parked PR.
SRC="$DIR/bin/claude-auth-check.sh"
CLB=$(awk '/# >>> conductor lane marker/,/# <<< conductor lane marker/' "$SRC")
[ -n "$CLB" ] && ok || bad "the conductor lane-marker block is missing from claude-auth-check.sh"
OKLN=$(grep -n 'classify_probe "$OUT")" = ok' "$SRC" | head -1 | cut -d: -f1)
BLN=$(grep -n '# >>> conductor lane marker' "$SRC" | head -1 | cut -d: -f1)
ELN=$(awk -v s="${OKLN:-0}" 'NR>s && $0=="  else" {print NR; exit}' "$SRC")
{ [ -n "$OKLN" ] && [ -n "$BLN" ] && [ -n "$ELN" ] && [ "$BLN" -gt "$OKLN" ] && [ "$BLN" -lt "$ELN" ]; } \
  && ok || bad "the lane-marker clear must sit INSIDE the ok arm (ok=$OKLN block=$BLN else=$ELN) — clearing it on a failed probe would be the opposite of the fix"
MK="$H/state/merge-conductor/lane-down"
mkdir -p "$H/state/merge-conductor"
declare -A BOXES=( [hub]=local [other]=10.0.0.9 )
printf 'the claude review lane errored (HTTP 429)\n' > "$MK"
BOX=hub; eval "$CLB"
[ -f "$MK" ] && bad "an ok probe on THIS box must clear the conductor's lane-down marker" || ok
printf 'the claude review lane errored (HTTP 429)\n' > "$MK"
BOX=other; eval "$CLB"
[ -f "$MK" ] && ok || bad "a REMOTE box answering says nothing about this box's account — its marker must stand"
rm -f "$MK"

# --- V1 alert hygiene: the verdict is the EXIT CODE and a SENTINEL, never prose.
# 2026-09-23..25: every box paged "CLAUDE AUTH DOWN" / "AUTH PROBE INCONCLUSIVE"
# daily because the model answered "ok" and then added a note that the Vercel
# MCP plugin "needs authorization ... can't run the OAuth flow". The probe kept
# only the LAST line of that answer, and auth_evidence() grepped it for
# oauth|authorization|/login. The account was fine on every box.
#
# Driven end to end: the REAL probe body runs against a stub `claude` on PATH,
# and the real classifier judges what it printed.
if ! command -v timeout >/dev/null 2>&1; then
  echo "SKIP: probe-body cases need coreutils timeout (run in the test image)"
else
  STUB="$T/stubbin"; mkdir -p "$STUB"
  cat > "$STUB/claude" <<'SH'
#!/bin/bash
# argv: -p <prompt> --model <m>. The prompt asks the model to JOIN a word and a
# per-run code with a hyphen; the stub does the transformation a model would, so
# it never hardcodes the token and the prompt never contains it literally.
PROMPT="$2"; MODEL="$4"
printf '%s\n' "$PROMPT" >> "${PROMPT_LOG:-/dev/null}"
CODE=$(printf '%s' "$PROMPT" | grep -oE 'code [0-9a-f]+' | awk '{print $2}' | head -1)
TOKEN="AUTHPROBE-$CODE"
NOTE='Also, the Vercel MCP server (`plugin:vercel:vercel`) needs authorization before I can use it. Run `claude mcp` or `/mcp` in an interactive session; this headless session cannot run the OAuth flow.'
case "$STUB_MODE" in
  sentinel-note) printf '%s\n\n%s\n' "$TOKEN" "$NOTE"; exit 0 ;;
  prose-only)    printf 'ok\n\n%s\n' "$NOTE"; exit 0 ;;
  loggedout)     printf 'Invalid API key · Please run /login\n'; exit 1 ;;
  killed)        exit 137 ;;
  credits)       if [ "$MODEL" = m-fallback ]; then printf '%s\n' "$TOKEN"; exit 0; fi
                 printf 'Claude AI usage credits exhausted for this model\n'; exit 1 ;;
  neterr)        printf 'Error: connection reset by peer\n'; exit 1 ;;
  # B2 (review of #2290): an ERROR that echoes the request back. A fixed token
  # in the prompt read as OK here; the transformed token never appears in it.
  echo-err)      printf 'API Error 500: request failed: %s\n' "$PROMPT"; exit 1 ;;
  echo-ok0)      printf 'You asked: %s\n' "$PROMPT"; exit 0 ;;
  token-rc1)     printf '%s\n' "$TOKEN"; exit 1 ;;
  loggedout-rc0) printf 'Invalid API key · Please run /login\n'; exit 0 ;;
  notlogged-rc0) printf 'Not logged in · Please run /login\n'; exit 0 ;;
  # Review nits of #2290: the CLI's phrase counts only from the CLI (stderr, or
  # the start of a line); mid-sentence in the model's answer it is prose. And a
  # usage-credits refusal that exits 0 still climbs the ladder.
  notlogged-err0) printf 'Not logged in · Please run /login\n' >&2; exit 0 ;;
  prose-notlogged) printf 'Sure. Note that the Vercel plugin says you are Not logged in there, so Please run /login in an interactive session.\n'; exit 0 ;;
  # Second review of #2290: the model's OWN answer mentions usage credits (and
  # OAuth), exit 0; the fallback then fails. Must never become AUTH DOWN.
  credits-prose0) if [ "$MODEL" = m-fallback ]; then printf 'Error: overloaded\n'; exit 1; fi
                 printf 'Sure. Note: your usage credits page and the OAuth authorization for the plugin are separate.\n'; exit 0 ;;
  # Third review of #2290: a healthy answer whose SECOND line starts with the
  # words "Not logged in" — the original incident shape — exit 0.
  mcp-notlogged0) printf 'I cannot comply.\nNot logged in to the Vercel MCP server, so I skipped it.\n'; exit 0 ;;
  credits-line0-fbfail) if [ "$MODEL" = m-fallback ]; then printf 'Error: overloaded; OAuth token refresh pending\n'; exit 1; fi
                 printf 'Usage credits exhausted for this model\n'; exit 0 ;;
  credits-rc0)   if [ "$MODEL" = m-fallback ]; then printf '%s\n' "$TOKEN"; exit 0; fi
                 printf 'Claude AI usage credits exhausted for this model\n'; exit 0 ;;
  credits-echo)  if [ "$MODEL" = m-fallback ]; then printf 'error: %s\n' "$PROMPT"; exit 1; fi
                 printf 'Claude AI usage credits exhausted for this model\n'; exit 1 ;;
esac
SH
  chmod +x "$STUB/claude"
  printf '#!/bin/bash\n# BH-2560: the probe now calls agent-call.sh; forward it to the stub claude on PATH\nclaude -p "$6" --model "$3" >"$5" 2>"$5.err"; rc=$?; echo "${SERVED_MODEL:-$3}" > "$5.model"; exit $rc\n' > "$T/bin/agent-call.sh"; chmod +x "$T/bin/agent-call.sh"
  # TEST-CHANGE (BH-9125): the canary model override is AUTH_CANARY_MODEL (TRIAGE_MODEL no longer steers it).
  probe() { STUB_MODE="$1" AUTH_CANARY_MODEL=m-primary AUTH_FALLBACK_MODEL=m-fallback PATH="$STUB:$PATH" bash -c "$PROBE_BODY" 2>/dev/null; }

  OUT=$(probe sentinel-note)
  [ "$(classify_probe "$OUT")" = ok ] && ok \
    || bad "V1a: an answer carrying the sentinel is ok whatever prose follows it (the Vercel MCP incident): $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe prose-only)
  C=$(classify_probe "$OUT")
  [ "$C" != authdown ] && ok \
    || bad "V1b: model PROSE mentioning authorization/OAuth must never read as AUTH DOWN <<$OUT>>"
  [ "$C" = inconclusive ] && ok || bad "V1c: rc 0 with no sentinel is inconclusive, got $C <<$OUT>>"
  OUT=$(probe loggedout)
  [ "$(classify_probe "$OUT")" = authdown ] && ok \
    || bad "V1d: a FAILED CLI (rc!=0) saying 'Please run /login' is still AUTH DOWN: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe killed)
  [ "$(classify_probe "$OUT")" = inconclusive ] && ok \
    || bad "V1e: a killed probe stays inconclusive: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe credits)
  [ "$(classify_probe "$OUT")" = degraded ] && ok \
    || bad "V1f: primary out of credits + fallback answering the sentinel is degraded: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe neterr)
  [ "$(classify_probe "$OUT")" = inconclusive ] && ok \
    || bad "V1g: a failed CLI with no credential evidence is inconclusive: $(classify_probe "$OUT") <<$OUT>>"

  # --- B2 (review of #2290): OK needs rc 0 AND the transformed per-run token.
  OUT=$(probe echo-err)
  [ "$(classify_probe "$OUT")" != ok ] && ok \
    || bad "B2a: an error that echoes the prompt must never read as ok <<$OUT>>"
  OUT=$(probe echo-ok0)
  [ "$(classify_probe "$OUT")" != ok ] && ok \
    || bad "B2b: an rc-0 answer that only repeats the prompt must never read as ok <<$OUT>>"
  OUT=$(probe token-rc1)
  [ "$(classify_probe "$OUT")" != ok ] && ok \
    || bad "B2c: the token with a non-zero exit is not ok (rc 0 AND token) <<$OUT>>"
  OUT=$(probe credits-echo)
  [ "$(classify_probe "$OUT")" != degraded ] && [ "$(classify_probe "$OUT")" != ok ] && ok \
    || bad "B2d: a fallback that fails while echoing the prompt is not DEGRADED-and-serving <<$OUT>>"
  OUT=$(probe loggedout-rc0)
  [ "$(classify_probe "$OUT")" = authdown ] && ok \
    || bad "B2e: the CLI's own 'Invalid API key · Please run /login' is AUTH DOWN even with exit 0 <<$OUT>>"
  OUT=$(probe notlogged-rc0)
  [ "$(classify_probe "$OUT")" = authdown ] && ok \
    || bad "B2f: 'Not logged in' is AUTH DOWN even with exit 0 <<$OUT>>"
  OUT=$(probe notlogged-err0)
  [ "$(classify_probe "$OUT")" = authdown ] && ok \
    || bad "N1a: 'Not logged in' on the CLI's stderr with exit 0 is AUTH DOWN <<$OUT>>"
  OUT=$(probe prose-notlogged)
  [ "$(classify_probe "$OUT")" = inconclusive ] && ok \
    || bad "N1b: the phrases mid-sentence in the model's answer are prose, not AUTH DOWN: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe credits-prose0)
  C=$(classify_probe "$OUT")
  [ "$C" != authdown ] && ok \
    || bad "N3: the model's own prose about 'usage credits ... OAuth authorization' (exit 0) + a failing fallback must never be AUTH DOWN <<$OUT>>"
  [ "$C" = inconclusive ] && ok || bad "N3: it is inconclusive (the model answered without the token), got $C <<$OUT>>"
  OUT=$(probe mcp-notlogged0)
  [ "$(classify_probe "$OUT")" = inconclusive ] && ok \
    || bad "N5: an exit-0 answer with a line starting 'Not logged in to the X MCP server' is prose, not AUTH DOWN: $(classify_probe "$OUT") <<$OUT>>"
  # N4: a genuine exit-0 credits refusal whose FALLBACK fails (with OAuth words
  # in its error) is judged on the exit-0 primary: inconclusive, never AUTH DOWN.
  OUT=$(probe credits-line0-fbfail)
  [ "$(classify_probe "$OUT")" = inconclusive ] && ok \
    || bad "N4: exit-0 credits refusal + failing fallback must be inconclusive: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(probe credits-rc0)
  [ "$(classify_probe "$OUT")" = degraded ] && ok \
    || bad "N2: a usage-credits refusal with exit 0 + fallback answering is DEGRADED: $(classify_probe "$OUT") <<$OUT>>"
  # BH-2560 review: agent-call walks its own claude ladder, so an ask for the
  # primary can come back answered by another model (a Fable box out of
  # credits served on Opus). The served model is in $PF.model; anything but
  # the asked model is DEGRADED, never ok.
  OUT=$(SERVED_MODEL=claude-opus-x probe sentinel-note)
  [ "$(classify_probe "$OUT")" = degraded ] && ok \
    || bad "F1a: an answer agent-call served on a different model than asked is DEGRADED, not ok: $(classify_probe "$OUT") <<$OUT>>"
  OUT=$(SERVED_MODEL=m-primary probe sentinel-note)
  [ "$(classify_probe "$OUT")" = ok ] && ok \
    || bad "F1b: an answer served on the asked model stays ok: $(classify_probe "$OUT") <<$OUT>>"
  # the token is per run and never literal in the prompt
  PL="$T/prompts.log"; : > "$PL"
  PROMPT_LOG="$PL" probe sentinel-note >/dev/null; PROMPT_LOG="$PL" probe sentinel-note >/dev/null
  P1=$(sed -n 1p "$PL"); P2=$(sed -n 2p "$PL")
  [ -n "$P1" ] && [ "$P1" != "$P2" ] && ok || bad "B2g: the probe prompt must carry a fresh nonce each run ('$P1' vs '$P2')"
  grep -qE 'AUTHPROBE-[0-9a-f]' "$PL" && bad "B2h: the expected token must never appear literally in the prompt: $(cat "$PL")" || ok
fi

# --- B1 (review of #2290): recovery closes the SAME console row the outage
# opened (akey authdown:<box>, resolved:true), and never opens a new row.
BEATS="$T/b1-beats.txt"; : > "$BEATS"
mkdir -p "$T/bin/lib"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$BEATS" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
if declare -F auth_recovered >/dev/null; then
  ( H="$T"; auth_recovered hub fleet ) >/dev/null 2>&1
  jq -e 'select(.akey == "authdown:hub" and .resolved == true and .alertid == "authdown-hub")' "$BEATS" >/dev/null 2>&1 \
    && ok || bad "B1a: recovery must send resolved:true on the outage's own akey authdown:hub: $(cat "$BEATS")"
  [ "$(grep -c . "$BEATS")" = 1 ] && ok || bad "B1b: exactly one recovery beat: $(cat "$BEATS")"
  grep -q '"akey":"orclane:\|"akey":"authok:' "$BEATS" && bad "B1c: recovery must not open a row under another akey: $(cat "$BEATS")" || ok
else
  bad "B1: auth_recovered is not defined (library mode)"
fi
SRC="$DIR/bin/claude-auth-check.sh"
[ "$(grep -c 'auth_recovered "\$BOX"' "$SRC")" -ge 2 ] && ok \
  || bad "B1d: both the box loop's ok arm and the project-1-lane ok path must call auth_recovered"
grep -q 'lane-alert.sh" --resolve --id "authdown' "$SRC" && bad "B1e: the orclane:<id> resolve (a different akey) must be gone" || ok

# The structured markers the probe body prints are judged on their own, so a
# marker line can never be re-read as prose.
check ok           "V1h: PROBE_OK marker" "PROBE_OK rc=0 model=m"
check inconclusive "V1i: NOSENTINEL marker carrying OAuth prose" \
  "PROBE_NOSENTINEL rc=0 model=m: Also, the Vercel MCP server needs authorization; cannot run the OAuth flow. Run /login"
check authdown     "V1j: FAILED marker with CLI credential evidence" "PROBE_FAILED rc=1 model=m: Invalid API key · Please run /login"
check inconclusive "V1k: FAILED marker without credential evidence" "PROBE_FAILED rc=1 model=m: Error: overloaded"

# --- V1: the canary's own beats key on the CONDITION, never on the date/hour.
# A date in an akey mints a fresh console row every day for the same condition.
grep -nE 'akey "(authprobe|pooldry|ghinvisible|authdown|authok|lanedown):[^"]*\$\(date' "$DIR/bin/claude-auth-check.sh" \
  && bad "V1l: claude-auth-check.sh still stamps a date/hour into an akey (lines above)" || ok

echo "auth-probe-classify: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
