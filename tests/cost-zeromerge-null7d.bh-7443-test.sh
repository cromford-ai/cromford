#!/bin/bash
# tests/cost-zeromerge-null7d.bh-7443-test.sh — the zero-merge breaker (A2 of
# the `cost budget` block in bin/pipeline-health.sh) must not read an UNKNOWN
# 7d merge count as 0 (BH-7443).
#
# 2026-10-19 03:29Z: project-9 had merged_prs_7d null (the 7d search call
# failed), merged_prs_24h 0, merged_prs_status ok and $548.74 of 7d delivery
# spend. M7 took the 24h count (0), so the 7d rule paged a false CRITICAL and
# held a project that merged 3 PRs that week.
#
# The block is extracted VERBATIM by its markers and driven the way
# tests/cost-containment.k1-test.sh drives it (stubbed flag_set, alert,
# page_critical, fleet-conf.sh, ssh). Defaults: 24h $300, 7d $400, min 1.
#   N1 project-9  — ZN7 null, ZN24 0, $548.74/7d: no page, no hold (the ticket)
#   N2 null7dhi — ZN7 null, ZN24 3, $900/7d: no page, no hold
#   N3 null7d24 — ZN7 null, ZN24 0, $400/24h: the 24h rule pages, no hold, and
#                 the page says the 7d count could not be taken
#   P1 known0   — ZN7 0, ZN24 0, $500/7d: the 7d rule still fires on a known 0
#   P2 late     — ZN7 0, ZN24 2, $500/7d: max(7d, 24h) still used, no page
#   P3 null24   — ZN7 0, ZN24 null, $500/7d: a null 24h does not mask a known 0
#   P4 under    — ZN7 null, ZN24 0, $399.99/7d: no page
#
# Run from anywhere: tests/cost-zeromerge-null7d.bh-7443-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }
NOW=$(date +%s)

mkdir -p "$T/bin/lib" "$T/logs" "$T/state/cost" "$T/flags" "$T/stub"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"
for f in bin/lib/cost-budget.sh bin/alert-line.sh; do
  scratch_install_closure "$f" "$T" >/dev/null || { echo "cannot install the closure of $f"; exit 1; }
done

cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/fleet-conf.sh"
cat > "$T/stub/ssh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/stub/ssh"

cat > "$T/fleet.conf" <<'CONF'
# fixture registry
project-9   Acme/project-9  - - 1 box-a 192.0.2.1
null7dhi  Acme/n7hi     - - 2 box-a 192.0.2.1
null7d24  Acme/n724     - - 3 box-a 192.0.2.1
known0    Acme/known0   - - 4 box-a 192.0.2.1
late      Acme/late     - - 5 box-a 192.0.2.1
null24    Acme/null24   - - 6 box-a 192.0.2.1
under     Acme/under    - - 7 box-a 192.0.2.1
CONF

CONF="$T/caps.conf"
cat > "$CONF" <<'CONF'
default 80 5
ceiling 100000
CONF

cat > "$T/state/cost/summary.json" <<'JSON'
{ "projects": {
  "project-9":  {"delivery_cost_24h": 50, "merged_prs_24h": 0, "cost_7d": 548.74, "product_7d": 0,
               "merged_prs_7d": null, "merged_prs_status": "ok"},
  "null7dhi": {"delivery_cost_24h": 50, "merged_prs_24h": 3, "cost_7d": 900, "product_7d": 0,
               "merged_prs_7d": null, "merged_prs_status": "ok"},
  "null7d24": {"delivery_cost_24h": 400, "merged_prs_24h": 0, "cost_7d": 900, "product_7d": 0,
               "merged_prs_7d": null, "merged_prs_status": "ok"},
  "known0":   {"delivery_cost_24h": 50, "merged_prs_24h": 0, "cost_7d": 500, "product_7d": 0,
               "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "late":     {"delivery_cost_24h": 50, "merged_prs_24h": 2, "cost_7d": 500, "product_7d": 0,
               "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "null24":   {"delivery_cost_24h": 50, "merged_prs_24h": null, "cost_7d": 500, "product_7d": 0,
               "merged_prs_7d": 0, "merged_prs_status": "ok"},
  "under":    {"delivery_cost_24h": 50, "merged_prs_24h": 0, "cost_7d": 399.99, "product_7d": 0,
               "merged_prs_7d": null, "merged_prs_status": "ok"}
} }
JSON
printf '%s\n' "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note" > "$T/logs/cost.csv"

drive() {
  : > "$T/alerts.txt"; : > "$T/pages.txt"; rm -f "$T/flags/"*
  echo 0 > "$T/state/costbreaker.stamp"
  ( export T NOW
    export HARNESS="$T" COST_CAPS_CONF="$CONF" PATH="$T/stub:$PATH"
    bash -c '
      set -uo pipefail
      H="$T"
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/pages.txt"; }
      flag_set() { [ "$2" = on ] && : > "$T/flags/$1"; return 0; }
      . "$T/cap.sh"; . "$0"' "$T/blk.sh" >"$T/out.txt" 2>"$T/err.txt" )
}
# every line (page or alert) that carries the key costzeromerge:<p>
zl() { cat "$T/pages.txt" "$T/alerts.txt" 2>/dev/null | grep "|costzeromerge:$1|"; }
held() { [ -e "$T/flags/spend-hold-$1" ]; }

drive

# N1 — the ticket case
[ -z "$(zl project-9)" ] && ok || bad "N1: ZN7 null, ZN24 0, \$548.74/7d must not page: $(zl project-9)"
held project-9 && bad "N1: an unknown 7d count must not hold project-9" || ok

# N2
[ -z "$(zl null7dhi)" ] && ok || bad "N2: ZN7 null, ZN24 3 must not page: $(zl null7dhi)"
held null7dhi && bad "N2: null7dhi must not be held" || ok

# N3 — the 24h rule still pages, does not hold, and says why
L=$(grep "|costzeromerge:null7d24|" "$T/pages.txt")
[ "$(printf '%s' "$L" | grep -c .)" = 1 ] && ok || bad "N3: want exactly one 24h page, got: $L"
grep -q 'in 24h' <<<"$L" && ok || bad "N3: the page must name the 24h window: $L"
grep -q 'could not be taken' <<<"$L" && ok || bad "N3: the page must say the 7d count could not be taken: $L"
grep -q 'null merged' <<<"$L" && bad "N3: the page must not print 'null merged': $L" || ok
held null7d24 && bad "N3: an unknown 7d count must not hold null7d24" || ok

# P1 — a known 0 still fires the 7d rule
grep -q 'in 7d' <<<"$(zl known0)" && ok || bad "P1: a known 0 over \$500/7d must page the 7d rule: $(zl known0)"
held known0 && ok || bad "P1: known0 must be held"

# P2 — max(7d, 24h) still used
[ -z "$(zl late)" ] && ok || bad "P2: 2 merged today counts toward 7d, no page: $(zl late)"
held late && bad "P2: late must not be held" || ok

# P3 — a null 24h does not mask a known 7d 0
grep -q 'in 7d' <<<"$(zl null24)" && ok || bad "P3: ZN7 0, ZN24 null must page the 7d rule: $(zl null24)"
held null24 && ok || bad "P3: null24 must be held"

# P4 — spend just under the 7d line
[ -z "$(zl under)" ] && ok || bad "P4: \$399.99/7d is under the line: $(zl under)"
held under && bad "P4: under must not be held" || ok

[ -s "$T/err.txt" ] && grep -qi 'syntax error\|command not found' "$T/err.txt" && bad "block stderr: $(head -5 "$T/err.txt")"

echo "cost-zeromerge-null7d: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
