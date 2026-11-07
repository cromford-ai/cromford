#!/bin/bash
# tests/poll-commands-whitelist-unreadable.bh-2009-test.sh — a console merge
# whose whitelist could not be READ retries; it never acks a terminal refusal.
#
# THE DEFECT (BH-2009, 2026-09-24). The merge_pr handler built its whitelist in
# one command substitution that dropped every `fleet-conf.sh` exit code, so a
# fleet.conf that was missing or unreadable for a moment gave an empty (or
# partial) whitelist, and a registered PR acked `refused: not a whitelisted
# example-org PR`. Since BH-932 the console reads a `refused:` result prefix as
# its TERMINAL `refused` status, so that PR was never re-leased.
#
# WHAT THIS PINS:
#   A  `--projects` exits 1           -> retryable `merge failed: whitelist unreadable`
#   B  `--projects` prints nothing    -> the same
#   C  one project's `repo` read fails, url is that project's -> the same
#   D  same partial read, url is a project that WAS read -> it merges
#   E  a full read and a foreign url  -> `refused: not a whitelisted …`, unchanged
#   F  the real `# >>> command ack` block sends case A as {ok:false,result}, no outcome
#   A-C also spend no merge call (no REST, no gh) and never start `refused:`.
#
# POLL_COMMANDS overrides the script the blocks are extracted from (the repro
# runs this suite against origin/main's copy). Missing markers fail loudly.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${POLL_COMMANDS:-$DIR/bin/poll-commands.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

PR_PROJECT_4="https://github.com/example-org/project-4/pull/1598"
PR_PROJECT_3="https://github.com/example-org/project-3/pull/77"

# fleet-conf.sh stub, driven by env: FC_PROJECTS_RC (rc of --projects),
# FC_EMPTY=1 (--projects prints nothing), FC_FAIL_REPO=<project> (that
# project's `repo` read exits 1 with no output).
mkdir -p "$T/h/bin" "$T/h/logs"
cat > "$T/h/bin/fleet-conf.sh" <<'CONF'
#!/bin/bash
if [ "$1" = --projects ]; then
  [ "${FC_EMPTY:-0}" = 1 ] || printf 'project-4\nproject-3\n'
  exit "${FC_PROJECTS_RC:-0}"
fi
if [ "${2:-}" = repo ]; then
  [ "$1" = "${FC_FAIL_REPO:-}" ] && exit 1
  printf 'example-org/%s\n' "$1"; exit 0
fi
exit 1
CONF
chmod +x "$T/h/bin/fleet-conf.sh"
mkdir -p "$T/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.log"\nexit 1\n' "$T" > "$T/bin/gh"
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

extract_handler() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$SRC" | sed -e "1s/^    ${1})//" -e '$s/ ;;$//'
}
extract_handler merge_pr > "$T/merge_pr.body"
[ -s "$T/merge_pr.body" ] || { echo "FAIL: could not extract the merge_pr handler from $SRC — markers missing?"; exit 1; }
awk '/^    # >>> command ack/{f=1; next} /^    # <<< command ack/{exit} f{print}' "$SRC" > "$T/ack.body"

run() { # run <url> [VAR=value ...]  -> OK= / RESULT= / OUTCOME= lines
  local url="$1"; shift
  : > "$T/gh-calls.log"; : > "$T/rest-calls.log"
  env "$@" HARNESS="$T/h" ID=17001 PROJECT=project-4 PAYLOAD="{\"pr_url\":\"$url\",\"sha\":\"abc12345\"}" T="$T" \
    bash -c '
      set -uo pipefail
      OK=false; RESULT=""; OUTCOME=""
      # TEST-CHANGE (BH-2199): `none`, was `mergify`. This suite drives the REST
      # merge ladder; a Mergify queue_rules repo now enqueues instead and never
      # reaches it (tests/poll-commands-mergify.bh-2199-test.sh), so a no-queue
      # repo is the provider that takes the path under test. Assertions unchanged.
      mc_queue_provider() { printf none; }
      mc_pr_queued() { return 1; }
      gh_pr_merge_rest() { printf "%s\n" "$*" >> "$T/rest-calls.log"; printf %s deadbeef; return 0; }
      . "$0"
      printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"' "$T/merge_pr.body"
}
okof()  { sed -n 's/^OK=//p' <<<"$1"; }
resof() { sed -n 's/^RESULT=//p' <<<"$1"; }
outof() { sed -n 's/^OUTCOME=//p' <<<"$1"; }
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

retryable() { # retryable <case> <output>
  [ "$(okof "$2")" = false ] && ok || bad "$1: an unreadable whitelist must ack OK=false, got '$2'"
  [ -z "$(outof "$2")" ] && ok || bad "$1: an unreadable whitelist must ack no OUTCOME (it is not a verdict), got '$2'"
  grep -q '^merge failed: whitelist unreadable' <<<"$(resof "$2")" \
    && ok || bad "$1: RESULT must start 'merge failed: whitelist unreadable', got '$(resof "$2")'"
  ! grep -q '^refused:' <<<"$(resof "$2")" \
    && ok || bad "$1: RESULT must never start 'refused:' — the console reads that prefix as terminal, got '$(resof "$2")'"
  [ "$(nlines "$T/rest-calls.log")" = 0 ] && ok || bad "$1: an unreadable whitelist must spend no REST merge call, got $(nlines "$T/rest-calls.log")"
  [ "$(nlines "$T/gh-calls.log")" = 0 ] && ok || bad "$1: an unreadable whitelist must spend no gh call, got: $(cat "$T/gh-calls.log")"
}

# ── A. --projects exits 1 ────────────────────────────────────────────────────
OUT_A=$(run "$PR_PROJECT_4" FC_PROJECTS_RC=1 FC_EMPTY=1)
retryable A "$OUT_A"
grep -q 'rc 1' <<<"$(resof "$OUT_A")" && ok || bad "A: RESULT must name what failed (rc 1), got '$(resof "$OUT_A")'"

# ── B. --projects exits 0 but lists nothing ─────────────────────────────────
retryable B "$(run "$PR_PROJECT_4" FC_EMPTY=1)"

# ── C. one project's repo read fails, and the url is that project's ─────────
OUT_C=$(run "$PR_PROJECT_3" FC_FAIL_REPO=project-3)
retryable C "$OUT_C"
grep -q 'project-3' <<<"$(resof "$OUT_C")" && ok || bad "C: RESULT must name the project whose read failed, got '$(resof "$OUT_C")'"

# ── D. the same partial read still merges a url whose slug WAS read ─────────
OUT=$(run "$PR_PROJECT_4" FC_FAIL_REPO=project-3)
[ "$(okof "$OUT")" = true ] && ok || bad "D: a url whose slug was read must merge despite another project's failed read, got '$OUT'"
grep -q "^merged $PR_PROJECT_4" <<<"$(resof "$OUT")" && ok || bad "D: RESULT must be 'merged …', got '$(resof "$OUT")'"
[ "$(nlines "$T/rest-calls.log")" = 1 ] && ok || bad "D: exactly one REST merge call, got $(nlines "$T/rest-calls.log")"
grep -q '^example-org/project-4 1598 ' "$T/rest-calls.log" && ok || bad "D: the REST call must target example-org/project-4 1598, got: $(cat "$T/rest-calls.log")"

# ── E. a full read and a foreign url: the refusal is unchanged ──────────────
OUT=$(run "https://github.com/someone/else/pull/1")
[ "$(okof "$OUT")" = false ] && ok || bad "E: a non-whitelisted url must stay OK=false, got '$OUT'"
[ -z "$(outof "$OUT")" ] && ok || bad "E: the whitelist refusal carries no OUTCOME, got '$OUT'"
[ "$(resof "$OUT")" = "refused: not a whitelisted fleet PR" ] \
  && ok || bad "E: RESULT must be exactly 'refused: not a whitelisted fleet PR', got '$(resof "$OUT")'"
{ [ "$(nlines "$T/rest-calls.log")" = 0 ] && [ "$(nlines "$T/gh-calls.log")" = 0 ]; } \
  && ok || bad "E: a non-whitelisted url must spend no merge call"

# ── F. the real ack POST for case A is today's {ok:false,result} ────────────
if [ -s "$T/ack.body" ]; then
  RES_A=$(resof "$OUT_A")
  CONSOLE_URL="https://console.example" ID=17001 OK="$(okof "$OUT_A")" RESULT="$RES_A" OUTCOME="$(outof "$OUT_A")" T="$T" bash -c '
    set -uo pipefail
    API() { printf "%s\n" "$@" > "$T/api-args"; }
    . "$0"' "$T/ack.body"
  BODY=$(awk 'p{print; exit} $0=="-d"{p=1}' "$T/api-args")
  jq -e --arg r "$RES_A" '. == {ok:false, result:$r}' <<<"$BODY" >/dev/null \
    && ok || bad "F: case A's ack body must be {ok:false,result} with no outcome key, got '$BODY'"
else
  bad "F: could not extract the '# >>> command ack' block from $SRC — markers missing?"
fi

echo "poll-commands-whitelist-unreadable.bh-2009-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
