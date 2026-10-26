#!/bin/bash
# tests/security-audit-caps.bh-7910-test.sh — BH-7910: bin/security-audit.sh
# stops the audit session at either cap and keeps the partial outputs.
#
#   C1  cap-minutes: SA_MINUTE_S=2 --cap-minutes 1 and a stub claude that sleeps
#       60 s: stopped in under 20 s, summary stopped cap-minutes, the partial
#       findings.json written before the sleep is kept and counted, no process
#       of the session is left running
#   C2  cap-usd near misses: ledger rows of another project, another stage,
#       another host and a ts before the start, together far over the cap,
#       stop nothing (the run ends completed)
#   C3  cap-usd: a matching audit row of 1.50 against --cap-usd 1 stops the
#       session, summary stopped cap-usd, cost_usd >= 1.5, cost_source ledger
#   C4  sa_cost_usd: an empty ledger and no transcript is cost null, source
#       none (never 0); a live transcript is priced and outranks a lower ledger
#   C5  cap-usd, the REAL live path: the stub claude writes a priced transcript
#       where the CLI does (its config root, its slug of the dotted .scratch
#       cwd) and NO ledger row; the runner finds it, stops cap-usd, and the
#       summary keeps a non-null live cost after the kill
#   C6  the same through agent-call's ACCOUNT_ROUTING: the child runs under an
#       account's own CLAUDE_CONFIG_DIR (env/accounts.d), not the runner's
#   C7  sa_project_slug: dots and other non-alphanumerics become "-"; a slug
#       over 200 characters is a 200-character prefix plus a "-*" glob
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/security-audit-caps.bh-7910-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/security-audit-fixture.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git pgrep; do command -v "$c" >/dev/null 2>&1 || { echo "$c missing — skipping"; exit 0; }; done

PJ=fixture-caps
sa_fixture_setup "$PJ" || { echo "FAIL: fixture setup"; exit 1; }
OUT="$T/out"
last_summary() { echo "$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json"; }

# ── C1: cap-minutes ──────────────────────────────────────────────────────────
echo sleep > "$T/claude-mode"
T0=$(date +%s)
RC=$(SA_MINUTE_S=2 sa_run "$PJ" --out "$OUT" --cap-minutes 1)
EL=$(( $(date +%s) - T0 ))
S=$(last_summary)
[ "$RC" = 0 ] && ok || bad "C1 rc $RC: $(cat "$T/run.out")"
[ "$EL" -lt 20 ] && ok || bad "C1 took ${EL}s, want < 20 s"
[ "$(jq -r .stopped "$S")" = cap-minutes ] && ok || bad "C1 stopped $(jq -r .stopped "$S"), want cap-minutes"
[ -f "$(dirname "$S")/findings.json" ] && ok || bad "C1 the partial findings.json is gone"
[ "$(jq -r .counts.needs_validation "$S")" = 1 ] && ok || bad "C1 partial counts $(jq -c .counts "$S")"
pgrep -f "$T/fakebin/claude" >/dev/null && bad "C1 the stub claude is still running" || ok

# ── C2: near-miss ledger rows stop nothing ───────────────────────────────────
echo short > "$T/claude-mode"
# Each near miss differs from a matching row in ONE field; the first three are
# dated after any run start, so only that field keeps them out.
NOW=2099-01-01T00:00:00Z; HOSTN=$(hostname)
{ echo "$NOW,$HOSTN,other-proj,audit,claude,m,0,1,1,1,0,0,50"
  echo "$NOW,$HOSTN,$PJ,execute,claude,m,0,1,1,1,0,0,50"
  echo "$NOW,fixture-other-host,$PJ,audit,claude,m,0,1,1,1,0,0,50"
  echo "2020-01-01T00:00:00Z,$HOSTN,$PJ,audit,claude,m,0,1,1,1,0,0,50"; } >> "$T/logs/cost.csv"
RC=$(sa_run "$PJ" --out "$OUT" --cap-usd 1 --again)
S=$(last_summary)
[ "$(jq -r .stopped "$S")" = completed ] && ok || bad "C2 near-miss rows stopped the run: $(jq -r .stopped "$S"), cost $(jq -r .cost_usd "$S")"
awk -v c="$(jq -r .cost_usd "$S")" 'BEGIN{exit !(c < 1)}' && ok || bad "C2 cost $(jq -r .cost_usd "$S") counts a near-miss row"

# ── C3: a matching row over the cap ──────────────────────────────────────────
echo cost > "$T/claude-mode"; echo 1.50 > "$T/claude-cost-usd"
T0=$(date +%s)
RC=$(sa_run "$PJ" --out "$OUT" --cap-usd 1 --again)
EL=$(( $(date +%s) - T0 ))
S=$(last_summary)
[ "$RC" = 0 ] && ok || bad "C3 rc $RC: $(cat "$T/run.out")"
[ "$(jq -r .stopped "$S")" = cap-usd ] && ok || bad "C3 stopped $(jq -r .stopped "$S"), want cap-usd"
[ "$EL" -lt 20 ] && ok || bad "C3 took ${EL}s, want < 20 s"
awk -v c="$(jq -r .cost_usd "$S")" 'BEGIN{exit !(c >= 1.5)}' && ok || bad "C3 cost_usd $(jq -r .cost_usd "$S"), want >= 1.5"
[ "$(jq -r .cost_source "$S")" = ledger ] && ok || bad "C3 cost_source $(jq -r .cost_source "$S")"
[ "$(jq -r .counts.confirmed "$S")" = 1 ] && ok || bad "C3 the partial findings were not counted: $(jq -c .counts "$S")"
pgrep -f "$T/fakebin/claude" >/dev/null && bad "C3 the stub claude is still running" || ok

# ── C4: sa_cost_usd ──────────────────────────────────────────────────────────
. "$REPO_DIR/bin/lib/security-audit.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
echo 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd' > "$T/empty.csv"
[ "$(sa_cost_usd "$T/empty.csv" "$PJ" "$HOSTN" 1000 "$T/no-such-dir")" = "null none" ] && ok \
  || bad "C4 empty ledger: $(sa_cost_usd "$T/empty.csv" "$PJ" "$HOSTN" 1000 "$T/no-such-dir")"
[ "$(sa_cost_usd "$T/missing.csv" "$PJ" "$HOSTN" 1000 "")" = "null none" ] && ok || bad "C4 a missing ledger is not null none"
# A live transcript (one priced API response) outranks a lower ledger sum.
mkdir -p "$T/tdir"
MODEL=$(jq -r '[.. | objects | to_entries[] | select(.key | startswith("claude-"))][0].key // empty' "$REPO_DIR/catalog/model-prices.json" 2>/dev/null)
if [ -n "$MODEL" ]; then
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:10Z","message":{"id":"msg_fixture_1","model":"%s","usage":{"input_tokens":1000000,"output_tokens":1000000}}}\n' "$MODEL" > "$T/tdir/s-fixture.jsonl"
  touch -d @2000 "$T/tdir/s-fixture.jsonl"
  echo "2026-01-01T00:00:00Z,$HOSTN,$PJ,audit,claude,m,0,1,1,1,0,0,0.01" >> "$T/empty.csv"
  R=$(HARNESS="$REPO_DIR" sa_cost_usd "$T/empty.csv" "$PJ" "$HOSTN" 1000 "$T/tdir")
  [ "${R#* }" = live ] && awk -v c="${R%% *}" 'BEGIN{exit !(c > 0.01)}' && ok || bad "C4 live transcript: got '$R'"
else
  bad "C4 no claude-* model in catalog/model-prices.json to price the fixture transcript"
fi

# ── C5/C6: the live meter on the real transcript path ────────────────────────
TD=""
live_case() { # live_case <name> — run, then assert a live cap-usd stop; TD = the stub's dir
  local n="$1" el s td
  rm -f "$T/claude-tdir"
  T0=$(date +%s)
  RC=$(sa_run "$PJ" --out "$OUT" --cap-usd 1 --again)
  el=$(( $(date +%s) - T0 ))
  s=$(last_summary); td=$(cat "$T/claude-tdir" 2>/dev/null)
  [ "$RC" = 0 ] && ok || bad "$n rc $RC: $(cat "$T/run.out")"
  case "$td" in *--scratch-*) ok ;; *) bad "$n the stub wrote no transcript under a dotted-cwd slug: '$td'" ;; esac
  [ "$(jq -r .stopped "$s")" = cap-usd ] && ok || bad "$n stopped $(jq -r .stopped "$s"), want cap-usd (transcript $td)"
  [ "$el" -lt 20 ] && ok || bad "$n took ${el}s, want < 20 s"
  [ "$(jq -r .cost_source "$s")" = live ] && ok || bad "$n cost_source $(jq -r .cost_source "$s"), want live"
  awk -v c="$(jq -r .cost_usd "$s")" 'BEGIN{exit !(c >= 1)}' && ok || bad "$n cost_usd $(jq -r .cost_usd "$s") after the stop, want >= 1 (non-null)"
  pgrep -f "$T/fakebin/claude" >/dev/null && bad "$n the stub claude is still running" || ok
  TD="$td"
}
if [ -n "$MODEL" ]; then
  echo transcript > "$T/claude-mode"; printf '%s' "$MODEL" > "$T/claude-transcript-model"
  # The ledger holds no row for this run: every earlier row is another run's.
  head -1 "$T/logs/cost.csv" > "$T/logs/cost.csv.new" && mv "$T/logs/cost.csv.new" "$T/logs/cost.csv"
  live_case C5
  case "$TD" in "$T/.claude/projects/"*) ok ;; *) bad "C5 transcript not under the runner's root: '$TD'" ;; esac

  mkdir -p "$T/env/accounts.d" "$T/acct-cfg"
  printf 'ACCOUNT_NAME=fixture-acct\nCLAUDE_CONFIG_DIR=%s\n' "$T/acct-cfg" > "$T/env/accounts.d/fixture-acct.env"
  cat > "$T/bin/account-pick.sh" <<SH
#!/bin/bash
printf 'name=fixture-acct\nlabel=fixture-acct\nreason=fixture\nexport CLAUDE_CONFIG_DIR=%s\n' '$T/acct-cfg'
SH
  chmod +x "$T/bin/account-pick.sh"
  SA_ACCOUNT_ROUTING=1 live_case C6
  case "$TD" in "$T/acct-cfg/projects/"*) ok ;; *) bad "C6 the routed child did not write under the account's config dir: '$TD'" ;; esac
  rm -f "$T/bin/account-pick.sh"
fi

# ── C7: sa_project_slug ──────────────────────────────────────────────────────
[ "$(sa_project_slug /a/b.c/.scratch-12)" = "-a-b-c--scratch-12" ] && ok || bad "C7 slug $(sa_project_slug /a/b.c/.scratch-12)"
LONG="/$(printf 'x%.0s' $(seq 1 250))/.scratch-1"
SL=$(sa_project_slug "$LONG")
[ "${#SL}" = 202 ] && [ "${SL: -2}" = "-*" ] && ok || bad "C7 long slug '${SL:0:20}...' length ${#SL}"

echo "security-audit-caps: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
