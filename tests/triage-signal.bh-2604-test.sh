#!/bin/bash
# tests/triage-signal.bh-2604-test.sh — BH-2604: four follow-ups on the BH-2542
# no-signal settle (PR #2593).
#
#   S  a settle writes row_source=settled (not refused); cost-rollup and the
#      unpriced-pair skip treat it like refused; the LLM Sites entry says so
#   R  the empty-allowlist guard is a deduped alert row (bin/lane-alert.sh --id,
#      one id per project per day), never a flags/ file; --log-only when the
#      alert state machine is off
#   H  a comment WE posted opts back IN as signal when its first non-blank line
#      starts `[human]` or `SIGNAL:` — and only then
#   I  the self identities are per-project settings rows
#      (lib.triage-signal[.<p>].triage_signal_self_identities), not a literal
#
# The llm-spend `settled` count is pinned by
# worker/jobs/test/llm-spend-settled.bh-2604.test.js (run at the end when node
# is present).
#
# Run from anywhere: tests/triage-signal.bh-2604-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 78 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
unset HARNESS_SECRET JOBS_URL TRIAGE_SIGNAL_SELF_IDENTITIES SELF_IDENTITIES
HEX16='^[0-9a-f]{16}$'
SIGPY="$DIR/bin/triage-signal.py"
SIGLIB="$DIR/bin/lib/triage-signal.sh"
TODAY=$(date -u +%Y%m%d)

# ═══ H / I — the digest, bin/triage-signal.py ═══════════════════════════════
A="$T/a"; mkdir -p "$A"
cat > "$A/in.json" <<'JSON'
{"ticket":{"id":"101","title":"Fee toggle","description":"Remove the discount toggle","status":"open",
 "waitingOn":"us","comments":[
  {"id":"c1","author":{"userId":"u-carol","name":"Carol Client"},"body":"please remove it"},
  {"id":"c2","author":{"userId":"u-h","name":"project-1 Team Harness"},"body":"on it"}]}}
JSON
# dig <file> [SELF_IDENTITIES] — unset when the second argument is absent
dig() {
  if [ "$#" -ge 2 ]; then
    SELF_ACTORS="project-1 Team Harness" SELF_IDENTITIES="$2" python3 "$SIGPY" --kind inapp < "$1"
  else
    SELF_ACTORS="project-1 Team Harness" python3 "$SIGPY" --kind inapp < "$1"
  fi
}
# withc <comment-json> — the base thread plus one comment, into $A/v.json
withc() { jq -c --argjson c "$1" '.ticket.comments += [$c]' "$A/in.json" > "$A/v.json"; }
# moves <label> <comment-json> [ids...] / same <label> <comment-json> [ids...]
moves() { local l="$1" c="$2" b d; shift 2; withc "$c"; b=$(dig "$A/in.json" "$@"); d=$(dig "$A/v.json" "$@")
  grep -qE "$HEX16" <<<"$d" && [ "$d" != "$b" ] && ok || bad "$l MUST move the digest ($d vs $b)"; }
same()  { local l="$1" c="$2" b d; shift 2; withc "$c"; b=$(dig "$A/in.json" "$@"); d=$(dig "$A/v.json" "$@")
  grep -qE "$HEX16" <<<"$b" && [ "$d" = "$b" ] && ok || bad "$l must NOT move the digest ($d vs $b)"; }
ours() { # ours <body-json-value> — a comment by our self actor
  printf '{"id":"c3","author":{"userId":"u-h","name":"project-1 Team Harness"},"body":%s}' "$1"; }

# H — opt-in markers on our own comments
moves "(H1) our comment starting [human]" "$(ours '"[human] From Dana'"'"'s email: approve the fee"')"
moves "(H2) our comment starting SIGNAL:" "$(ours '"SIGNAL: client said go"')"
moves "(H3) our comment starting '  [HUMAN]' (leading space, any case)" "$(ours '"  [HUMAN] relayed from the call"')"
moves "(H4) our comment whose first NON-BLANK line is [human]" "$(ours '"\n  \n[human] after a blank line\nrest"')"
moves "(H5) our comment with the marker in .content (no body)" \
  '{"id":"c3","author":{"userId":"u-h","name":"project-1 Team Harness"},"content":"[human] from the phone"}'
moves "(H6) an authorActor-marked comment with [human]" \
  '{"id":"c3","author":{"userId":"u-bh","name":"Build Harness"},"authorActor":"agent:build-harness","body":"[human] Dana: yes"}' \
  agent:build-harness
# H-neg — the saving survives: unmarked or mis-marked content of ours stays OUT
same "(H-neg) our comment with no marker" "$(ours '"triage: holding"')"
same "(H-neg) marker not at line start (Triage: [human] review needed)" "$(ours '"Triage: [human] review needed"')"
same "(H-neg) a quoted marker (> [human] quoted)" "$(ours '"> [human] quoted"')"
same "(H-neg) lowercase signal: (only the exact SIGNAL: counts)" "$(ours '"signal: none"')"
same "(H-neg) SIGNALS: x" "$(ours '"SIGNALS: x"')"
same "(H-neg) [humans] x" "$(ours '"[humans] x"')"
same "(H-neg) our comment quoting a client, no marker" "$(ours '"Carol wrote: \"[human] approve it\"\nholding"')"
same "(H-neg) the marker on the SECOND non-blank line" "$(ours '"holding\n[human] later line"')"
same "(H-neg) a null body" "$(ours 'null')"
same "(H-neg) a non-string body" "$(ours '{"x":"[human] y"}')"
# humans are unchanged either way
moves "(H-human) a human comment with no marker" '{"id":"c3","author":{"userId":"u-carol","name":"Carol Client"},"body":"go"}'
moves "(H-human) a human comment starting [human]" '{"id":"c3","author":{"userId":"u-carol","name":"Carol Client"},"body":"[human] go"}'

# I — identities from SELF_IDENTITIES, never a literal
BH='{"id":"c3","author":{"userId":"u-bh","name":"Build Harness"},"authorActor":"agent:build-harness","body":"built"}'
SB='{"id":"c3","author":{"userId":"u-project-9-bot","name":"Anything"},"body":"triage: holding"}'
moves "(I1) SELF_IDENTITIES unset: an agent:build-harness marker is NOT ours (no literal left)" "$BH"
moves "(I1b) SELF_IDENTITIES empty: same" "$BH" ""
same  "(I2) SELF_IDENTITIES=agent:build-harness: the marker is ours" "$BH" agent:build-harness
same  "(I2b) SELF_IDENTITIES=' AGENT:Build-Harness , ' matches the lowercase marker (D17)" "$BH" " AGENT:Build-Harness , "
same  "(I2c) the identity may be one of several" "$BH" "u-other,agent:build-harness"
same  "(I3) SELF_IDENTITIES=u-project-9-bot: a comment by that userId (no marker) is ours" "$SB" u-project-9-bot
same  "(I3b) SELF_IDENTITIES by author name, spaces inside kept" \
  '{"id":"c3","author":{"userId":"u-9","name":"project-9 Team Bot"},"body":"x"}' "a,project-9 Team Bot"
moves "(I3c) on the default identity a project-9 userId is NOT ours" "$SB" agent:build-harness
moves "(I-neg) a marker that only contains the identity (agent:build-harness-2)" \
  '{"id":"c3","author":{"userId":"u-bh","name":"Build Harness"},"authorActor":"agent:build-harness-2","body":"built"}' agent:build-harness
moves "(I-neg) displayName equal to an identity" \
  '{"id":"c3","author":{"userId":"u-dan","name":"Dev Dan","displayName":"u-project-9-bot"},"body":"x"}' u-project-9-bot
moves "(I-neg) authorName equal to an identity beside an author object" \
  '{"id":"c3","author":{"userId":"u-dan","name":"Dev Dan"},"authorName":"u-project-9-bot","body":"x"}' u-project-9-bot
moves "(I-neg) a recordedBy comment by an identity stays a person's words" \
  '{"id":"c3","author":{"userId":"u-project-9-bot","name":"Anything","recordedBy":"x"},"body":"x"}' u-project-9-bot

# ═══ I5 — the REAL bin/triage-gate.sh forwards TRIAGE_SIGNAL_SELF_IDENTITIES ═
G="$T/g"
mkdir -p "$G/bin/lib" "$G/env" "$G/state" "$G/logs" "$G/fixture"
for s in triage-gate.sh fleet-conf.sh triage-signal.py; do cp "$DIR/bin/$s" "$G/bin/$s"; done
for s in board-creds.sh internal-token.sh gh-rest.sh gh-rest-var.sh gate-self-comments.sh harness-self.sh env-path.sh; do
  [ -r "$DIR/bin/lib/$s" ] && cp "$DIR/bin/lib/$s" "$G/bin/lib/$s"
done
chmod +x "$G/bin/"*.sh
printf 'sg   org/sg   https://x.invalid /api/board 1 box-1\n' > "$G/fleet.conf"
: > "$G/env/global.env"
printf 'SG_APP_BASE=https://x.invalid\nSG_INTERNAL_API_TOKEN=tok-sg\nBOARD_SELF_ACTORS="project-1 Team"\n' > "$G/env/sg.env"
cat > "$G/bin/board-fetch.sh" <<STUB
#!/bin/bash
cat "$G/fixture/thread.json"
STUB
chmod +x "$G/bin/board-fetch.sh"
gsig() { env HARNESS="$G" HARNESS_ENV_DIR="$G/env" FLEET_CONF="$G/fleet.conf" "$@" bash "$G/bin/triage-gate.sh" sg --signal 101 2>/dev/null; }
cp "$A/in.json" "$G/fixture/thread.json"; G0=$(gsig)
withc "$SB"; cp "$A/v.json" "$G/fixture/thread.json"
G1=$(gsig TRIAGE_SIGNAL_SELF_IDENTITIES=u-project-9-bot); G2=$(gsig)
grep -qE "$HEX16" <<<"$G0" && [ "$G1" = "$G0" ] && ok \
  || bad "(I5) the real gate must hand TRIAGE_SIGNAL_SELF_IDENTITIES to the digest (with it: $G1, base $G0)"
grep -qE "$HEX16" <<<"$G2" && [ "$G2" != "$G0" ] && ok \
  || bad "(I5) with no identities the same comment must move the digest ($G2 vs $G0)"

# ═══ E box — the REAL bin/run-triage.sh, gate stubbed (as tests/…bh-2542) ═══
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" project-5 project-1 || exit 1
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/fixture" "$T/calls" "$T/repos" "$T/datebin"
: > "$H/env/global.env"
export FLEET_CONF="$DIR/fleet.conf"
for p in project-5 project-1; do echo "SOP for $p. Fetch the thread. Do the work." > "$H/prompts/$p.md"; done
for s in run-triage.sh triage-shard.sh lane-alert.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" -e "s|/root/orchestrator|$T/orc|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
cp "$SIGLIB" "$H/bin/lib/triage-signal.sh"
cp "$SIGPY" "$H/bin/triage-signal.py"
cp "$DIR/bin/alert_family.py" "$H/bin/alert_family.py"
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh gh-budget.sh cost-row.sh harness-self.sh alert-state.sh lane-gate.sh env-path.sh; do
  sed -e "s|/root/harness|$H|g" "$DIR/bin/lib/$s" > "$H/bin/lib/$s"
done
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
# the registry this box reads: the committed fragment itself, so the default
# and the settable flag under test are the ones that ship
export LANE_REGISTRY="$DIR/catalog/lanes.d/_lib.triage-signal.json"
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
# lane-alert: the REAL script, behind a wrapper that records its argv
mv "$H/bin/lane-alert.sh" "$H/bin/lane-alert-real.sh"
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$H/fixture/lane-alert-argv"
exec "$H/bin/lane-alert-real.sh" "\$@"
STUB
chmod +x "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/fixture/beats"\nexit 0\n' "$H" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# the gate stub: --signal behaves as the real gate's in-app / gh arms, including
# the TRIAGE_SIGNAL_SELF_IDENTITIES -> SELF_IDENTITIES hand-off pinned by I5
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
case "\$MODE" in
  --buildable) echo OK; exit 0 ;;
  --signal)
    printf '%s %s ids=%s\n' "\$P" "\$3" "\${TRIAGE_SIGNAL_SELF_IDENTITIES:-}" >> "$H/fixture/signal-calls"
    F="$H/fixture/\$P/thread-\$3.json"; [ -s "\$F" ] || exit 1
    K=inapp; [ "\$P" = project-5 ] && K=gh
    SELF_ACTORS="project-1 Team Harness" SELF_APPS_JSON='["cromford"]' \
      SELF_IDENTITIES="\${TRIAGE_SIGNAL_SELF_IDENTITIES:-}" python3 "$H/bin/triage-signal.py" --kind "\$K" < "\$F"
    exit \$? ;;
esac
cp "$H/fixture/\$P/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
cat > "$H/bin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/gh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '2026-09-25T00:00:00Z,box,%s,%s,claude,%s,,,,,,,0.9100\n' "$2" "$1" "$3" >> "$COSTCSV"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"
# a `date` that answers one day far ahead for the alert-id format only (R2)
cat > "$T/datebin/date" <<'STUB'
#!/bin/bash
[ "$*" = "-u +%Y%m%d" ] && { echo 20990101; exit 0; }
exec /bin/date "$@"
STUB
chmod +x "$T/datebin/date"

held() { [ -e "$1" ] || return 1; if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi; return 0; }
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
ncost()  { grep -c ',triage,' "$H/logs/cost.csv" 2>/dev/null | tr -d ' ' || true; }
nsig()   { grep -c . "$H/fixture/signal-calls" 2>/dev/null | tr -d ' ' || true; }
calledfor() { grep -l "Work ONLY ticket $1 this tick" "$T/calls"/prompt-* >/dev/null 2>&1; }
settle() {
  local i=0 busy L
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "${1:-0}" ]; then
      busy=0
      for L in "$H"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  sleep 1; return 1
}
nextick() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$H/logs/cost.csv"; : > "$H/fixture/signal-calls"; }
run() { CALLDIR="$T/calls" COSTCSV="$H/logs/cost.csv" PATH="$H/bin:$PATH" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
tick() { nextick; run "$@"; settle "${WANT_CALLS:-0}" >/dev/null; }
reset_box() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"; scratch_rm "$H/flags"
  model_routes_fixture "$H" project-5 project-1 || exit 1
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds" "$H/flags" "$H/fixture/$P"
  : > "$H/logs/READY-QUEUE.log"; : > "$H/logs/cost.csv"
  : > "$H/fixture/lane-alert-argv"; : > "$H/fixture/beats"
  echo "RUN board-changed" > "$H/fixture/gate-decision"
}
# settings_row <key> <value> — one operator row in the box's settings cache
settings_row() {
  jq -nc --argjson fa "$(date -u +%s)" --arg k "$1" --arg v "$2" \
    '{fetched_at:$fa, values:{($k):$v}, seeded:{}}' > "$H/state/settings-cache.json"
}

tk() { printf '{"id":"%s","status":"open","waitingOn":"%s","triageVerdict":null,"commentCount":%s,"lastActivityAt":"%s","title":"T%s"}' \
    "$1" "${4:-us}" "$2" "$3" "$1"; }
pend_in() { printf '{"b1":[%s,%s]}' "$1" "$2" > "$H/fixture/$P/pending.json"; }
thr() { jq -c --arg id "$1" '.ticket.id=$id | .ticket.title=("T"+$id)' "$A/in.json" > "$H/fixture/$P/thread-$1.json"; }
addc() { local f="$H/fixture/$P/thread-$1.json"
  jq -c --argjson c "$2" '.ticket.comments += [$c]' "$f" > "$f.new" && mv "$f.new" "$f"; }
base_inapp() { # the first tick over 101 and 102 has been paid for
  P=project-1; reset_box
  [ -n "${1:-}" ] && settings_row "$1" "$2"
  thr 101; thr 102
  pend_in "$(tk 101 2 2026-09-25T01:00:00Z)" "$(tk 102 2 2026-09-25T01:00:00Z)"
  cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
  printf 'board b1: CHANGED 101 "T101" (comments: 1 -> 2)\nboard b1: CHANGED 102 "T102" (comments: 1 -> 2)\n' > "$H/fixture/diff"
  WANT_CALLS=2 tick
}
only101() { # 101 alone moves by one comment
  pend_in "$(tk 101 3 2026-09-25T02:00:00Z)" "$(tk 102 2 2026-09-25T01:00:00Z)"
  printf 'board b1: CHANGED 101 "T101" (comments: 2 -> 3)\n' > "$H/fixture/diff"
}

# ═══ S1 — a settle is a row_source=settled row ══════════════════════════════
base_inapp
[ "$(ncost)" = 2 ] && ok || bad "(S1) precondition: the first tick buys 101 and 102 (got $(ncost))"
addc 101 "$(ours '"triage: holding"')"; only101
WANT_CALLS=0 tick
[ "$(ncost)" = 0 ] && ok || bad "(S1) precondition: our own comment settles (got $(ncost) sessions)"
PRE=$(grep ',triage-precheck,' "$H/logs/cost.csv" 2>/dev/null)
[ "$(printf '%s\n' "$PRE" | grep -c ',triage-precheck,')" = 1 ] && ok || bad "(S1) exactly one triage-precheck row (got: $PRE)"
printf '%s' "$PRE" | awk -F, '$4=="triage-precheck" && $13=="0" && $18=="settled" && $20=="101" && $24=="settled:no-signal" && NF==25 {f=1} END{exit !f}' && ok \
  || bad "(S1) the settle row must say row_source=settled, cost 0, ticket 101, note settled:no-signal, 25 columns: $PRE"
grep -q . <<<"$(awk -F, '$4=="triage-precheck" && $18=="refused"' "$H/logs/cost.csv")" \
  && bad "(S1) a settle must write NO row_source=refused row" || ok

# ═══ I4 — end to end: the identities row is per project ═════════════════════
base_inapp lib.triage-signal.project-1.triage_signal_self_identities u-project-9-bot
addc 101 "$SB"; only101
WANT_CALLS=0 tick
[ "$(ncost)" = 0 ] && ok || bad "(I4) a comment by the identity project-1's row names must settle (got $(ncost) sessions)"
[ "$(awk -F, '$4=="triage-precheck" && $18=="settled" && $20=="101"' "$H/logs/cost.csv" | grep -c .)" = 1 ] && ok \
  || bad "(I4) the settle must write one settled row: $(cat "$H/logs/cost.csv")"
grep -q '^project-1 101 ids=u-project-9-bot$' "$H/fixture/signal-calls" && ok \
  || bad "(I4) the gate must be handed this project's identities: $(cat "$H/fixture/signal-calls")"
base_inapp lib.triage-signal.project-5.triage_signal_self_identities u-project-9-bot
addc 101 "$SB"; only101
WANT_CALLS=1 tick
[ "$(ncost)" = 1 ] && calledfor 101 && ok || bad "(I4) a row scoped to ANOTHER project must not apply: the key dispatches (got $(ncost))"
grep -q '^project-1 101 ids=agent:build-harness$' "$H/fixture/signal-calls" && ok \
  || bad "(I4) with no row for this project the registry default reaches the gate: $(cat "$H/fixture/signal-calls")"
base_inapp lib.triage-signal.triage_signal_self_identities u-project-9-bot
addc 101 "$SB"; only101
WANT_CALLS=0 tick
[ "$(ncost)" = 0 ] && ok || bad "(I4) a FLEET-wide identities row applies to every project (got $(ncost))"

# ═══ R — GitHub board, HARNESS_SELF_APPS empty: an alert row, not a flag ════
P=project-5
reset_box
cat > "$H/fixture/$P/thread-563.json" <<'JSON'
{"issue":{"number":563,"title":"c","body":"b","state":"open","labels":[]},"comments":[{"id":11,"user":{"login":"client-carl","type":"User"},"body":"hi"}]}
JSON
ghpend() { printf '{"issues":[{"number":563,"state":"OPEN","title":"c","comments":2,"updatedAt":"%s"}],"prs":[]}' "$1" > "$H/fixture/$P/pending.json"; }
ghpend 2026-09-25T01:00:00Z
cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
printf 'board issues: CHANGED 563 "c" (comments: 1 -> 2)\n' > "$H/fixture/diff"
ID="triage-signal-self-apps-project-5-$TODAY"
for n in 1 2 3; do
  ghpend "2026-09-25T1${n}:00:00Z"
  WANT_CALLS=1 tick env HARNESS_SELF_APPS=
  [ "$(ncost)" = 1 ] && ok || bad "(R1.$n) an empty allowlist still dispatches (got $(ncost))"
done
[ "$(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "(R1) three ticks must write exactly one ALERTS line (got $(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null))"
[ "$(jq -r '.count' "$H/state/alerts/$ID.json" 2>/dev/null)" = 3 ] && ok \
  || bad "(R1) the alert row $ID must exist, unsanitised, with count 3: $(ls "$H/state/alerts" 2>/dev/null | tr '\n' ' ')"
[ "$(ls "$H"/flags/alerted-triage-signal-* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && ok \
  || bad "(R1) no flags/alerted-triage-signal-* file may be written: $(ls "$H/flags")"
[ "$(grep -c -- "--id $ID --severity warn triage-signal " "$H/fixture/lane-alert-argv")" = 3 ] && ok \
  || bad "(R1) one lane-alert call per tick with the per-day id at warn: $(cat "$H/fixture/lane-alert-argv")"
grep -q -- '--log-only' "$H/fixture/lane-alert-argv" && bad "(R1) the state machine is on: no --log-only" || ok
[ "$(grep -c 'no-signal settle is OFF for this GitHub board' "$H/logs/$P.log" 2>/dev/null)" = 3 ] && ok \
  || bad "(R1) the per-tick project-log line stays"
[ "$(grep -c '"alertid":"'"$ID"'"' "$H/fixture/beats")" = 1 ] && ok \
  || bad "(R1) the state machine sends ONE fleet_alert beat for the id, the repeats are suppressed: $(grep fleet_alert "$H/fixture/beats")"
# R2 — the next day is a new id and one more line
ghpend 2026-09-25T15:00:00Z
WANT_CALLS=1 tick env HARNESS_SELF_APPS= PATH="$T/datebin:$H/bin:$PATH"
[ "$(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null)" = 2 ] && ok \
  || bad "(R2) a new day's id must fire one more ALERTS line (got $(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null))"
[ -s "$H/state/alerts/triage-signal-self-apps-project-5-20990101.json" ] && ok || bad "(R2) the new day's row must exist"
# R3 — the alert state machine is off: lane-alert would ignore --id and page
# every tick, so the guard sends a log-only notice instead
reset_box
ghpend 2026-09-25T01:00:00Z
cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
ghpend 2026-09-25T02:00:00Z
WANT_CALLS=1 tick env HARNESS_SELF_APPS= ALERT_STATE_ENABLED=0
grep -q -- "--log-only" "$H/fixture/lane-alert-argv" && ok || bad "(R3) with ALERT_STATE_ENABLED=0 lane-alert must get --log-only: $(cat "$H/fixture/lane-alert-argv")"
grep -q fleet_alert "$H/fixture/beats" && bad "(R3) a log-only notice posts no fleet_alert beat: $(grep fleet_alert "$H/fixture/beats")" || ok
[ "$(grep -c 'HARNESS_SELF_APPS is empty' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "(R3) the notice is still an ALERTS line"
reset_box
touch "$H/flags/alert-state-off"
ghpend 2026-09-25T01:00:00Z
cp "$H/fixture/$P/pending.json" "$H/state/$P.gate.json"
ghpend 2026-09-25T02:00:00Z
WANT_CALLS=1 tick env HARNESS_SELF_APPS=
grep -q -- "--log-only" "$H/fixture/lane-alert-argv" && ! grep -q fleet_alert "$H/fixture/beats" && ok \
  || bad "(R3b) flags/alert-state-off must also mean --log-only, no beat: $(cat "$H/fixture/lane-alert-argv")"

# ═══ S2 / S3 — cost-rollup: settled is not unpriced ═════════════════════════
C="$T/c"; mkdir -p "$C/bin/lib" "$C/logs" "$C/flags" "$C/state/cost"
cp "$DIR/bin/cost-rollup.sh" "$C/bin/cost-rollup.sh"; chmod +x "$C/bin/cost-rollup.sh"
# The rollup reads the fleet from the cost_rows table and stops before writing
# state/cost/ when it cannot (BH-2527), so the table answers here — empty, and
# the rows under test are the hub's own logs/cost.csv, which the union still reads.
cp "$DIR/bin/lib/cost-rows-read.sh" "$C/bin/lib/"
: > "$C/fleet.conf"
echo '{"per_token":{"claude-opus-5":{"prompt":0.000005,"completion":0.000025}}}' > "$C/state/model-prices.json"
printf 'job_ledger_get() { return 2; }\njob_ledger_put() { return 0; }\n' > "$C/bin/jobs-client.sh"
printf '_jobs_req() { case "$2" in /api/metrics/cost-rows*) echo %s ;; *) return 1 ;; esac; }\n' "'{\"cost_rows\":[]}'" >> "$C/bin/jobs-client.sh"
NOWC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id"
  # a settle, exactly as triage_signal_count writes it
  echo "$NOWC,hub,sproj,triage-precheck,none,none,0,0,0,0,0,0,0,none,none,unknown,,settled,0,101,,,,settled:no-signal,run-triage"
  # a gate refusal
  echo "$NOWC,hub,sproj,triage,claude,claude-opus-5,0,0,0,0,0,0,0,none,none,unknown,,refused,0,,,,,refused:cap,run-triage"
  # a real call the ledger could not price
  echo "$NOWC,hub,sproj,triage,grok,grok-9,0,60,0,0,0,0,0,metered,,,,none,,,,,,,run-triage"
  # a priced call
  echo "$NOWC,hub,sproj,triage,claude,claude-opus-5,0,60,1000,100,0,0,1.20,metered,,,,none,,,,,,,run-triage"
  # a settled row stored with a BLANK cost (a D1 NULL round-trip), billed tokens
  echo "$NOWC,hub,sproj,triage-precheck,settledrunner,settledmodel,0,0,10,10,0,0,,none,none,unknown,,settled,0,102,,,,settled:no-signal,run-triage"
} > "$C/logs/cost.csv"
( export HARNESS="$C" WINDOWS_ONLY=1 COST_ROLLUP_TIMEBOXED=1
  bash "$C/bin/cost-rollup.sh" >"$T/c.out" 2>"$T/c.err" ); CRC=$?
[ "$CRC" = 0 ] && ok || bad "(S2) the rollup must exit 0 (rc=$CRC): $(tail -5 "$T/c.err")"
# (the project is not in this box's empty fleet.conf, so it rolls up as `other`;
# the fleet sum is the number the cost-capture-parity rule reads)
U=$(jq -r '.fleet_unpriced_calls_24h' "$C/state/cost/summary.json" 2>/dev/null)
[ "$U" = 1 ] && ok || bad "(S2) settled and refused are not unpriced: only the grok row counts (fleet_unpriced_calls_24h=$U)"
jq -e '.fleet_ledger_unpriced_pairs_24h | map(select(.runner=="settledrunner")) | length == 0' "$C/state/cost/summary.json" >/dev/null 2>&1 && ok \
  || bad "(S3) the unpriced-pair skip must drop a settled row: $(jq -c '.fleet_ledger_unpriced_pairs_24h' "$C/state/cost/summary.json" 2>/dev/null)"

# ═══ S4 — the LLM Sites record names the settle row ═════════════════════════
jq -e '.sites[] | select(.id=="triage-shard") | .note | test("row_source=settled")' "$DIR/catalog/llm-sites.json" >/dev/null 2>&1 && ok \
  || bad "(S4) catalog/llm-sites.json triage-shard note must name row_source=settled"

# ═══ T5 registry — the knob is registered, settable, with today's default ═══
jq -e '.libs[] | select(.id=="triage-signal") | .knobs[] | select(.env=="TRIAGE_SIGNAL_SELF_IDENTITIES")
       | .default=="agent:build-harness" and .required==true and (.settable != false) and .type=="string"' \
  "$DIR/catalog/lanes.d/_lib.triage-signal.json" >/dev/null 2>&1 && ok \
  || bad "(I) TRIAGE_SIGNAL_SELF_IDENTITIES must be registered: string, default agent:build-harness, required, settable"

# ═══ worker — /api/metrics/llm-spend counts settled apart from refused ══════
if command -v node >/dev/null 2>&1; then
  # the worker imports the generated, git-ignored catalog/lanes.json (BH-1247),
  # which CI renders the same way before its node step
  [ -r "$DIR/catalog/lanes.json" ] || (cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --write >/dev/null 2>&1)
  NT=$(cd "$DIR/worker/jobs" && node --test test/llm-spend-settled.bh-2604.test.js 2>&1); NRC=$?
  [ "$NRC" = 0 ] && ok || bad "(S5) worker/jobs/test/llm-spend-settled.bh-2604.test.js failed (rc=$NRC): $(printf '%s' "$NT" | grep -E 'not ok|Error|expected|actual' | head -12)"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
