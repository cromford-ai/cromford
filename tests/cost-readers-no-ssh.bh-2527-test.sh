#!/bin/bash
# tests/cost-readers-no-ssh.bh-2527-test.sh — THE COST READERS READ D1, AND
# NOTHING ELSE (BH-2527).
#
# Five hub lanes used to answer "what did the fleet spend" by reaching across
# the tailnet for each box's files: bin/cost-rollup.sh (four ssh calls: the
# remote build-dir tar, the per-box cost.csv fallback, each box's
# extra-usage.csv and extra-usage-unavailable), the fleet ceiling in
# bin/pipeline-health.sh section B, bin/cap-loss-detector.sh (scp of
# failovers.log + cost.csv), bin/cost-report.sh and bin/cost-readout.sh. Every
# one of those facts is in the harness-jobs D1 database already: `cost_rows`
# (bin/lib/cost-rows-read.sh) and `extra_usage_snapshots`
# (bin/lib/extra-usage-read.sh). A box that cannot be reached read as a box
# that spent nothing; a table that cannot be read is now NAMED instead.
#
#   N1  the ratchet: no command-position ssh/scp/rsync in bin/cost-*.sh,
#       bin/cap-loss-detector.sh or pipeline-health.sh section B (the section
#       markers must exist, or the slice is empty and the check proves nothing)
#   N2  the matcher flags `timeout 30 ssh …`, `scp -q …`, `X=$(ssh h)`
#   N3  the matcher does NOT flag a comment, `echo "no ssh"`, `SSH_LOG=x`,
#       `flyctl ssh console`
#   E1-E4  bin/lib/extra-usage-read.sh, driven with a stubbed _jobs_req
#   R1-R4  the REAL bin/cost-rollup.sh in a scratch $HARNESS
#   B1  pipeline-health's cost budget block with cost_rows unreadable
#   C1-C3  the REAL bin/cap-loss-detector.sh
#   P1  the REAL bin/cost-report.sh and bin/cost-readout.sh
#
# Every script run gets `ssh`, `scp` and `rsync` stubs on PATH that record
# their argv, so "no ssh" is observed, not grepped. A script that still pins
# HARNESS=/root/harness is NOT run (it would write into the live harness); that
# is recorded as a failure.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-readers-no-ssh.bh-2527-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "python3/jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

# ── the remote-access stubs every run gets ──────────────────────────────────
mkdir -p "$T/stub"
for c in ssh scp rsync; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "${REMOTE_LOG:-/dev/null}"\nexit 0\n' "$c" > "$T/stub/$c"
done
printf '#!/bin/bash\nexit 1\n' > "$T/stub/gh"
printf '#!/bin/bash\nexit 7\n' > "$T/stub/curl"
cat > "$T/stub/crontab" <<'SH'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "${CRONTAB_LOG:-/dev/null}"
[ "${1:-}" = -l ] && echo "0 5 * * * /root/harness/bin/placeholder.sh"
[ "${1:-}" = - ] && cat >/dev/null
exit 0
SH
chmod +x "$T/stub/"*

# ============================================================================
# N. the ratchet
# ============================================================================
cat > "$T/remote-cmd.py" <<'PY'
"""Print file:line for every command-position ssh/scp/rsync, comments stripped."""
import re, sys

PREFIX = (r"(?:(?:timeout(?:\s+-\S+(?:\s+\d\S*)?)*\s+\d\S*"
          r"|nohup|exec|command|sudo|time|if|while|until|then|do|else|!"
          r"|env(?:\s+-\S+)*|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*")
PAT = re.compile(r"(?:^|[;&|({`]|\$\()\s*" + PREFIX + r"(ssh|scp|rsync)(?=\s|$|\))")


def strip_comment(line):
    q = None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
            elif ch == "\\" and q == '"':
                continue
        elif ch in "'\"":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            return line[:i]
    return line


def hits(label, text, first=1):
    out = []
    for n, line in enumerate(text.splitlines(), first):
        code = strip_comment(line)
        m = PAT.search(code)
        if m:
            out.append("%s:%d: %s" % (label, n, line.strip()))
    return out


if __name__ == "__main__":
    bad = []
    for arg in sys.argv[1:]:
        # path[@first-line] — a slice extracted from a bigger file keeps its
        # own line numbers in the report.
        path, _, first = arg.partition("@")
        with open(path, errors="replace") as fh:
            bad += hits(path, fh.read(), int(first or 1))
    print("\n".join(bad))
    sys.exit(1 if bad else 0)
PY

PH="$DIR/bin/pipeline-health.sh"
BSTART=$(grep -n '^  # ---- B\. ' "$PH" | head -1 | cut -d: -f1)
BEND=$(grep -n '^  # ---- C\. ' "$PH" | head -1 | cut -d: -f1)
if [ -n "$BSTART" ] && [ -n "$BEND" ] && [ "$BEND" -gt "$BSTART" ]; then
  ok
  sed -n "${BSTART},${BEND}p" "$PH" > "$T/ph-section-b.sh"
else
  bad "N1: pipeline-health.sh has lost its '# ---- B.' / '# ---- C.' markers — the section-B slice is empty and the ratchet would pass on nothing"
  : > "$T/ph-section-b.sh"
fi
[ -s "$T/ph-section-b.sh" ] && grep -q 'cost_rows_fetch' "$T/ph-section-b.sh" \
  && ok || bad "N1: the section-B slice does not carry the ceiling's cost_rows read — markers moved?"
FILES=$(ls "$DIR"/bin/cost-*.sh "$DIR/bin/cap-loss-detector.sh")
[ "$(printf '%s\n' "$FILES" | wc -l)" -ge 6 ] && ok || bad "N1: expected >= 6 cost-* files, got: $FILES"
# shellcheck disable=SC2086
N1=$(python3 "$T/remote-cmd.py" $FILES "$T/ph-section-b.sh@${BSTART:-1}"); N1RC=$?
[ "$N1RC" = 0 ] && ok || bad "N1: command-position ssh/scp/rsync in a cost reader:
$N1"

cat > "$T/n2.sh" <<'SH'
timeout 30 ssh -o BatchMode=yes root@x cat f
  scp -q a b
X=$(ssh h)
[ -n "$A" ] && ssh -o ConnectTimeout=15 "$A" "tail f"
timeout -k 60 90 rsync -a x y
SH
[ "$(python3 "$T/remote-cmd.py" "$T/n2.sh" | grep -c .)" = 5 ] \
  && ok || bad "N2: the matcher must flag all 5 remote calls: $(python3 "$T/remote-cmd.py" "$T/n2.sh")"
cat > "$T/n3.sh" <<'SH'
# ssh fallback removed
# no ssh
echo "no ssh"
SSH_LOG=x
flyctl ssh console -a app
x=1  # timeout 30 ssh root@x
grep -q 'ssh -o BatchMode=yes' file
SH
N3=$(python3 "$T/remote-cmd.py" "$T/n3.sh")
[ -z "$N3" ] && ok || bad "N3: the matcher flagged something that is not a remote call: $N3"

# ============================================================================
# E. bin/lib/extra-usage-read.sh
# ============================================================================
EUHDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status'
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EARLIER=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
RESETS=$(date -u -d '3 days' '+%Y-%m-%dT%H:%M:%SZ')
# snap <ts> <used|null> <status> — one extra_usage_snapshots row as the route
# answers it (booleans are stored 0/1).
snap() {
  jq -nc --arg ts "$1" --argjson u "$2" --arg st "$3" --arg r "$RESETS" \
    '{box:"x", ts:$ts, session_pct:10, weekly_pct:40.5, weekly_resets_at:$r,
      extra_enabled:1, extra_used_usd:$u, spend_limit_reached:0, in_overage:0,
      extra_limit_usd:null, extra_pct:null, status:(if $st == "" then null else $st end)}'
}
# newest-first, like the route
eu_json() { jq -sc '{snapshots: ., as_of: "now"}'; }
{ snap "$NOW" 12.5 ok; snap "$EARLIER" null no-login; } | eu_json > "$T/eu-good.json"

EUL="$DIR/bin/lib/extra-usage-read.sh"
if [ -r "$EUL" ]; then
  ok
  bash -n "$EUL" && ok || bad "E0: bash -n failed on bin/lib/extra-usage-read.sh"
  E=$(
    _jobs_req() { printf '%s %s\n' "$1" "$2" >> "$T/e-req.log"
                  case "${EU_MODE:-good}" in good) cat "$T/eu-good.json" ;; junk) echo 'not json' ;;
                    shape) echo '{"snapshots":"x"}' ;; *) return 1 ;; esac; }
    # shellcheck source=/dev/null
    . "$EUL"
    extra_usage_fetch project-2 "$T/e1.csv"; echo "e1rc=$?"
    EU_MODE=down extra_usage_fetch project-2 "$T/e2.csv"; echo "e2rc=$?"
    EU_MODE=junk extra_usage_fetch project-2 "$T/e3.csv"; echo "e3rc=$?"
    EU_MODE=shape extra_usage_fetch project-2 "$T/e3b.csv"; echo "e3brc=$?"
    printf '{"accounts":{"hub-gmail":{"login":{"box":"hub","config_dir":"/root/.claude"}},
      "project-6-account":{"login":{"box":"hub","config_dir":"/root/.claude-project-6"}},
      "project-2":{"login":{"box":"project-2","config_dir":"/root/.claude"}}}}' > "$T/accts.json"
    echo "project-2=$(COST_ACCOUNTS_FILE="$T/accts.json" extra_usage_label_for_box project-2)"
    echo "hub=$(COST_ACCOUNTS_FILE="$T/accts.json" extra_usage_label_for_box hub)"
    echo "unk=$(COST_ACCOUNTS_FILE="$T/accts.json" extra_usage_label_for_box project-9)"
  )
  # E1 — the tracker's header, oldest-first, NULL rendered empty
  grep -q '^e1rc=0$' <<<"$E" && ok || bad "E1: an answered GET must return rc 0: $E"
  [ "$(head -1 "$T/e1.csv" 2>/dev/null)" = "$EUHDR" ] && ok || bad "E1: header must be the tracker's HDR, got '$(head -1 "$T/e1.csv" 2>/dev/null)'"
  [ "$(sed -n 2p "$T/e1.csv" | cut -d, -f1)" = "$EARLIER" ] && [ "$(sed -n 3p "$T/e1.csv" | cut -d, -f1)" = "$NOW" ] \
    && ok || bad "E1: rows must be oldest-first so the last row is the newest: $(cat "$T/e1.csv" 2>/dev/null)"
  [ "$(sed -n 2p "$T/e1.csv" | cut -d, -f6)" = "" ] && [ "$(sed -n 2p "$T/e1.csv" | cut -d, -f11)" = "no-login" ] \
    && ok || bad "E1: a NULL meter must render empty (not 'None'/'null'): $(sed -n 2p "$T/e1.csv")"
  [ "$(sed -n 3p "$T/e1.csv" | cut -d, -f6)" = "12.5" ] && [ "$(sed -n 3p "$T/e1.csv" | cut -d, -f5)" = "1" ] \
    && ok || bad "E1: the meter and the 0/1 booleans must come through: $(sed -n 3p "$T/e1.csv")"
  grep -q 'GET /api/metrics/extra-usage?box=project-2&limit=1000' "$T/e-req.log" \
    && ok || bad "E1: the read must ask the route for this label, limit 1000: $(cat "$T/e-req.log")"
  # E2/E3 — unreadable is rc 1 and NO file
  grep -q '^e2rc=1$' <<<"$E" && [ ! -e "$T/e2.csv" ] && ok || bad "E2: a failed GET must be rc 1 with no file: $E"
  grep -q '^e3rc=1$' <<<"$E" && [ ! -e "$T/e3.csv" ] && ok || bad "E3: an unparseable body must be rc 1 with no file: $E"
  grep -q '^e3brc=1$' <<<"$E" && [ ! -e "$T/e3b.csv" ] && ok || bad "E3: a body without a snapshots list must be rc 1 with no file: $E"
  # E4 — the label a box's default login is keyed by
  grep -q '^project-2=project-2$' <<<"$E" && ok || bad "E4: project-2's default login is the project-2 account: $E"
  grep -q '^hub=hub-gmail$' <<<"$E" && ok || bad "E4: the hub's /root/.claude login is hub-gmail, not the project-6 dir: $E"
  grep -q '^unk=project-9$' <<<"$E" && ok || bad "E4: a box the catalog does not name falls back to its own id: $E"
else
  bad "E0: bin/lib/extra-usage-read.sh does not exist"
fi

# ============================================================================
# R. the REAL bin/cost-rollup.sh
# ============================================================================
HDR25="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id"
# crow <ts> <box> <host> <project> <stage> <runner> <rc> <dur> <cost> <run_id>
#   one cost_rows row as GET /api/metrics/cost-rows answers it (no `raw`, so
#   the reader reconstructs it from the columns).
crow() {
  jq -nc --arg ts "$1" --arg box "$2" --arg host "$3" --arg p "$4" --arg st "$5" --arg rn "$6" \
     --arg rc "$7" --arg d "$8" --arg c "$9" --arg run "${10}" \
    '{ts:$ts, box:$box, host:$host, project:$p, stage:$st, runner:$rn, model:"m-1", rc:($rc|tonumber),
      duration_s:($d|tonumber), input_toks:10, output_toks:20, cache_read:0, cache_write:0,
      cost_usd:($c|tonumber), billing_mode:"metered", auth_fp:"", auth_account:"acct",
      session_id:"", row_source:"agent-call", result_usd:null, ticket:"", job_id:"", pr:"",
      run_id:$run, note:"", row_hash:($ts + $box + $st + $rn + $c + $run)}'
}
rows_json() { jq -sc '{cost_rows: .}'; }

# setup_roll <name> — a scratch harness holding the real rollup and libs; sets RH, FIX.
setup_roll() {
  RH="$T/$1/h"; FIX="$T/$1/fix"
  mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/builds" "$RH/state/cost" "$RH/env" "$RH/catalog" "$FIX"
  cp "$DIR/bin/cost-rollup.sh" "$RH/bin/"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$RH/bin/"
  for l in env-path.sh cost-rows-read.sh builds-of-record.sh extra-usage-read.sh; do
    [ -r "$DIR/bin/lib/$l" ] && cp "$DIR/bin/lib/$l" "$RH/bin/lib/"
  done
  cp "$DIR/catalog/cost-accounts.json" "$RH/catalog/"
  cat > "$RH/bin/jobs-client.sh" <<'JC'
# stub jobs client: the D1 routes answer from $FIX; the ledger feed from $FIX/<p>.<kind>
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FIX/req.log"
  case "$2" in
    /api/metrics/cost-rows*)
      [ -f "$FIX/cost-rows.down" ] && return 1
      cat "$FIX/cost-rows.json" ;;
    /api/metrics/extra-usage*)
      local b="${2#*box=}"; b="${b%%&*}"
      [ -f "$FIX/eu-$b.json" ] || return 1
      cat "$FIX/eu-$b.json" ;;
    *) return 1 ;;
  esac
}
job_artifact_feed() {
  local kind="$1" p="$2" limit="${4:-100}"
  [ -f "$FIX/$p.$kind" ] && head -n "$limit" "$FIX/$p.$kind"
  return 0
}
JC
  # Every box HAS an address: a rollup that still ssh's anything will do it
  # here, and the stub log will say so.
  # TEST-CHANGE (BH-5747): the overage loop reads --box-ids now; the stub
  # answers the boxes R4 names, so its assertions are unchanged.
  printf '#!/bin/bash\ncase "$1" in --tailnet-ip) echo 10.9.9.9 ;; --tailnet-ips) echo 10.9.9.9 ;; --box-ids) printf "project-4\\nproject-3\\nproject-2\\n" ;; *) exit 1 ;; esac\n' > "$RH/bin/fleet-conf.sh"
  chmod +x "$RH/bin/fleet-conf.sh"
  printf 'project-1 -\n' > "$RH/fleet.conf"
  echo '{"cost_rows":[]}' > "$FIX/cost-rows.json"
}
run_roll() {
  env PATH="$T/stub:$PATH" HARNESS="$RH" HARNESS_ENV_DIR="$RH/env" FIX="$FIX" REMOTE_LOG="$RH/remote.log" \
      COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 HARNESS_SECRET= \
      bash "$RH/bin/cost-rollup.sh" > "$RH/run.out" 2>&1
  echo $? > "$RH/run.rc"
}
remote_calls() { cat "$RH/remote.log" 2>/dev/null | grep -c . || true; }

# R1 — the table answers: fleet-cost.csv carries it, nothing is ssh'd
setup_roll r1
{ crow "$NOW" project-2 box-project-2-1 project-2 execute claude 0 60 2.5 project-2-BH-1-x
  crow "$NOW" project-3 box-project-3-1 project-3 review claude 0 60 1.25 project-3-BH-2-x
} | rows_json > "$FIX/cost-rows.json"
run_roll
[ "$(cat "$RH/run.rc")" = 0 ] && ok || bad "R1: rollup exited $(cat "$RH/run.rc"): $(tail -5 "$RH/run.out")"
grep -q 'box-project-2-1' "$RH/state/cost/fleet-cost.csv" 2>/dev/null \
  && grep -q 'box-project-3-1' "$RH/state/cost/fleet-cost.csv" \
  && ok || bad "R1: fleet-cost.csv must carry both boxes' table rows: $(cat "$RH/state/cost/fleet-cost.csv" 2>/dev/null)"
[ "$(remote_calls)" = 0 ] && ok || bad "R1: the rollup reached a box over the tailnet: $(head -3 "$RH/remote.log")"

# R2 — the table is down: no rewrite, one ALERT a day, no ssh
setup_roll r2
touch "$FIX/cost-rows.down"
echo '{"seed":"last good run"}' > "$RH/state/cost/summary.json"
echo 'seed-fleet' > "$RH/state/cost/fleet-cost.csv"
cp "$RH/state/cost/summary.json" "$T/r2-summary.before"
run_roll
[ "$(cat "$RH/run.rc")" = 0 ] && ok || bad "R2: rollup exited $(cat "$RH/run.rc"): $(tail -5 "$RH/run.out")"
cmp -s "$T/r2-summary.before" "$RH/state/cost/summary.json" \
  && ok || bad "R2: summary.json was rewritten from a run that could not read cost_rows: $(head -c 200 "$RH/state/cost/summary.json")"
[ "$(cat "$RH/state/cost/fleet-cost.csv")" = seed-fleet ] \
  && ok || bad "R2: fleet-cost.csv was rewritten from a run that could not read cost_rows"
[ "$(grep -c 'cost_rows is unreadable' "$RH/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "R2: expected exactly one ALERTS line naming the unreadable table: $(cat "$RH/logs/ALERTS.log" 2>/dev/null)"
grep 'cost_rows is unreadable' "$RH/logs/ALERTS.log" 2>/dev/null | grep -q 'cost-rows-push.sh --verify' \
  && ok || bad "R2: the ALERT must say what to run"
run_roll
[ "$(grep -c 'cost_rows is unreadable' "$RH/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "R2: a second run the same day must not add a second ALERT"
[ "$(remote_calls)" = 0 ] && ok || bad "R2: a table outage fell back to the tailnet: $(head -3 "$RH/remote.log")"

# R3 — remote per-PR attribution: run_id + the ledger, nothing else
setup_roll r3
res() { printf '%s\t%s\tbox1\t%s\t2026-09-20T10:00:00Z\t{"build_dir":"%s","key":"%s","job_status":"done"}\n' "$1" "$2" "$4" "$3" "$4"; }
prl() { printf '%s\t%s\tbox1\t-\t2026-09-20T10:00:00Z\t-\n' "$1" "$2"; }
{ res j9 PR_CREATED project-1-BH-9-x BH-9
  res j11 PR_CREATED project-1-BH-11-x BH-11; } > "$FIX/project-1.result"
{ prl j9 https://github.com/o/r/pull/9
  prl j11 https://github.com/o/r/pull/11; } > "$FIX/project-1.pr_url"
# A hub build dir: attributed from its own cost.csv; its table copy must not
# be counted a second time through the run_id path.
mkdir -p "$RH/builds/project-1-BH-11-x"
{ echo "$HDR25"
  echo "$NOW,hub,project-1,execute,claude,m-1,0,60,10,20,0,0,3.00,metered,,acct,,agent-call,,,,,project-1-BH-11-x,,"
} > "$RH/builds/project-1-BH-11-x/cost.csv"
{ crow "$NOW" project-1 box-project-1-1 project-1 execute claude 0 60 1.25 project-1-BH-9-x
  crow "$NOW" project-1 box-project-1-1 project-1 review claude 0 60 2.5 pool-project-1-BH-9-x
  crow "$NOW" project-1 box-project-1-1 project-1 execute claude 0 60 7 project-1-BH-8-x
  crow "$NOW" hub hub project-1 review claude 0 60 3 project-1-BH-11-x
} | rows_json > "$FIX/cost-rows.json"
run_roll
[ "$(cat "$RH/run.rc")" = 0 ] && ok || bad "R3: rollup exited $(cat "$RH/run.rc"): $(tail -5 "$RH/run.out")"
PPR="$RH/state/cost/cost-per-pr.csv"
pr_cost() { python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["pr_url"].endswith("/pull/" + sys.argv[2]): print(r["cost_usd"])' "$PPR" "$1" 2>/dev/null; }
[ "$(pr_cost 9)" = 3.75 ] && ok || bad "R3: a remote build the ledger names must bill its table rows (1.25 + 2.50) to /pull/9, got '$(pr_cost 9)'"
[ "$(pr_cost 11)" = 3.00 ] && ok || bad "R3: a hub build dir bills from its own cost.csv exactly once, got '$(pr_cost 11)'"
grep -q 'BH-8' "$PPR" 2>/dev/null && bad "R3: a run_id the ledger does not name was attributed: $(cat "$PPR")" || ok
[ "$(remote_calls)" = 0 ] && ok || bad "R3: the rollup reached a box over the tailnet: $(head -3 "$RH/remote.log")"

# R4 — each box's meter comes from extra_usage_snapshots
setup_roll r4
{ snap "$EARLIER" 10 ok; snap "$NOW" 12.5 ok; } | jq -s 'reverse' | jq -c '{snapshots: .}' > "$FIX/eu-project-2.json"
{ snap "$NOW" null no-login; snap "$EARLIER" 3 ok; } | eu_json > "$FIX/eu-project-3.json"
run_roll
OD="$RH/state/cost/overage"
[ "$(cat "$RH/run.rc")" = 0 ] && ok || bad "R4: rollup exited $(cat "$RH/run.rc"): $(tail -5 "$RH/run.out")"
[ "$(tail -1 "$OD/project-2.csv" 2>/dev/null | cut -d, -f6)" = 12.5 ] \
  && ok || bad "R4: overage/project-2.csv must end on the newest snapshot's meter: $(cat "$OD/project-2.csv" 2>/dev/null)"
[ "$(jq -r '.overage_accounts.project-2.meter_usd' "$RH/state/cost/summary.json" 2>/dev/null)" = 12.5 ] \
  && ok || bad "R4: summary.json's per-account meter must be the snapshot's: $(jq -c '.overage_accounts.project-2' "$RH/state/cost/summary.json" 2>/dev/null)"
grep -q 'status=no-login' "$OD/project-3.why" 2>/dev/null \
  && ok || bad "R4: a newest snapshot with status no-login must be the box's named reason: $(cat "$OD/project-3.why" 2>/dev/null)"
grep -q 'extra_usage_snapshots unreadable' "$OD/project-4.why" 2>/dev/null && [ ! -e "$OD/project-4.csv" ] \
  && ok || bad "R4: a failed read must be named, never a file: $(cat "$OD/project-4.why" 2>/dev/null)"
grep -qx project-4 "$OD/EXPECTED" 2>/dev/null && grep -qx project-2 "$OD/EXPECTED" \
  && ok || bad "R4: EXPECTED must still list every box"
jq -r '.overage_accounts.project-4.meter_unavailable // empty' "$RH/state/cost/summary.json" 2>/dev/null | grep -q 'unreadable' \
  && ok || bad "R4: summary.json must say WHY project-4 has no meter"
[ "$(remote_calls)" = 0 ] && ok || bad "R4: the rollup reached a box over the tailnet: $(head -3 "$RH/remote.log")"

# ============================================================================
# B. pipeline-health's fleet ceiling with the table unreadable
# ============================================================================
B="$T/b"; mkdir -p "$B/lib" "$B/logs" "$B/state/cost" "$B/flags" "$B/bin"
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$PH" > "$B/blk.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$PH" > "$B/cap.sh"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$B/bin/"
[ -s "$B/blk.sh" ] && ok || bad "B1: could not extract the cost budget block"
cp "$DIR/bin/lib/cost-budget.sh" "$B/lib/"
printf '#!/bin/bash\ncase "$1" in --tailnet-ips) printf "10.0.0.1\\n10.0.0.2\\n" ;; *) exit 1 ;; esac\n' > "$B/bin/fleet-conf.sh"
chmod +x "$B/bin/fleet-conf.sh"
echo '{"projects":{}}' > "$B/state/cost/summary.json"
printf 'default 80 5\nceiling 10\n' > "$B/caps.conf"
{ echo "$HDR25"
  echo "$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ'),hub,alpha,execute,claude,m-1,0,1,1,1,,,50,metered,,,,,,,,,,,"
} > "$B/logs/cost.csv"
drive_b() {
  echo 0 > "$B/state/costbreaker.stamp"; : > "$B/pages.txt"
  ( export B NOW_S="$(date +%s)"
    export HARNESS="$B" COST_CAPS_CONF="$B/caps.conf" MODEL_PRICES="$B/none.json" PATH="$T/stub:$PATH" REMOTE_LOG="$B/remote.log"
    bash -c '
      set -uo pipefail
      H="$B"; NOW="$NOW_S"
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$B/alerts.txt"; }
      page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$B/pages.txt"; }
      flag_set() { return 0; }
      . "$B/cap.sh"; . "$0"' "$B/blk.sh" > "$B/out.txt" 2> "$B/err.txt" )
}
drive_b
L=$(grep '|costceiling:fleet|' "$B/pages.txt" | head -1)
grep -q 'spent \$50.00' <<<"$L" && ok || bad "B1: the hub's own ledger must still brake: '$L' $(tail -3 "$B/err.txt")"
grep -q 'LOCAL ONLY' <<<"$L" && ok || bad "B1: a total taken without cost_rows must say it is LOCAL ONLY: '$L'"
[ ! -s "$B/remote.log" ] && ok || bad "B1: the breaker ssh'd boxes: $(cat "$B/remote.log")"
[ "$(grep -c 'fleet cost ceiling is LOCAL ONLY' "$B/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "B1: one ALERTS line must say the brake is partial: $(cat "$B/logs/ALERTS.log" 2>/dev/null)"
drive_b
[ "$(grep -c 'fleet cost ceiling is LOCAL ONLY' "$B/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "B1: the partial-brake ALERT must fire once a day, not every tick"

# ============================================================================
# C. the REAL bin/cap-loss-detector.sh
# ============================================================================
honours_harness() { grep -q 'HARNESS="\${HARNESS:-/root/harness}"' "$1"; }
DAY=$(date -u -d yesterday '+%Y-%m-%d')
setup_one() { # setup_one <name> <script> — sets SH, FIX
  SH="$T/$1/h"; FIX="$T/$1/fix"
  mkdir -p "$SH/bin/lib" "$SH/logs" "$SH/env" "$FIX"
  cp "$DIR/bin/$2" "$SH/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/cost-rows-read.sh" "$SH/bin/lib/"
  cat "$RH/bin/jobs-client.sh" > "$SH/bin/jobs-client.sh"   # the D1 stub, not the real client
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$HARNESS/beats"\n' > "$SH/bin/beat.sh"
  chmod +x "$SH/bin/beat.sh"
}
run_one() { # run_one <script>
  env PATH="$T/stub:$PATH" HARNESS="$SH" HARNESS_ENV_DIR="$SH/env" FIX="$FIX" REMOTE_LOG="$SH/remote.log" \
      CRONTAB_LOG="$SH/crontab.log" LANE_GATE_DISABLE=1 HARNESS_SECRET= \
      bash "$SH/bin/$1" > "$SH/run.out" 2> "$SH/run.err"
  echo $? > "$SH/run.rc"
}
if honours_harness "$DIR/bin/cap-loss-detector.sh"; then
  ok
  # C1 — failovers and deferred time are cost_rows fields, per host
  setup_one c1 cap-loss-detector.sh
  { for i in 1 2 3; do crow "${DAY}T0$i:00:00Z" project-2 hostA p execute claude 1 5 0 r; done
    crow "${DAY}T05:00:00Z" project-2 hostA p execute codex 0 5000 0 r
    crow "${DAY}T06:00:00Z" project-2 hostA p execute codex 0 4000 0 r
    crow "${DAY}T07:00:00Z" project-3 hostB p execute claude 0 60 0 r
    crow "${DAY}T08:00:00Z" project-3 hostB p execute codex 0 360 0 r
  } | rows_json > "$FIX/cost-rows.json"
  run_one cap-loss-detector.sh
  [ "$(cat "$SH/run.rc")" = 0 ] && ok || bad "C1: exited $(cat "$SH/run.rc"): $(cat "$SH/run.err")"
  grep -q "$DAY :: .*hostA: 3 failovers, 2.5h deferred" "$SH/logs/cap-loss.log" 2>/dev/null \
    && ok || bad "C1: cap-loss.log must read 'hostA: 3 failovers, 2.5h deferred': $(cat "$SH/logs/cap-loss.log" 2>/dev/null)"
  grep -q 'hostB: 0 failovers, 0.1h deferred' "$SH/logs/cap-loss.log" 2>/dev/null \
    && ok || bad "C1: hostB must be measured too: $(cat "$SH/logs/cap-loss.log" 2>/dev/null)"
  grep -q 'Threshold crossed on: hostA' "$SH/beats" 2>/dev/null && ! grep -q 'hostB' <<<"$(grep -o 'Threshold crossed on: [^(]*' "$SH/beats")" \
    && ok || bad "C1: the beat must name hostA only: $(cat "$SH/beats" 2>/dev/null)"
  grep -q "since=${DAY}T00:00:00Z" "$FIX/req.log" && grep -q "until=${DAY}T23:59:59Z" "$FIX/req.log" \
    && ok || bad "C1: the read must be yesterday's window: $(cat "$FIX/req.log")"
  [ ! -s "$SH/remote.log" ] && ok || bad "C1: cap-loss reached a box: $(cat "$SH/remote.log")"
  # C2 — under 2h: measured, no beat
  setup_one c2 cap-loss-detector.sh
  { crow "${DAY}T01:00:00Z" project-2 hostA p execute claude 1 5 0 r
    crow "${DAY}T02:00:00Z" project-2 hostA p execute codex 0 3600 0 r; } | rows_json > "$FIX/cost-rows.json"
  run_one cap-loss-detector.sh
  grep -q 'hostA: 1 failovers, 1.0h deferred' "$SH/logs/cap-loss.log" 2>/dev/null \
    && ok || bad "C2: $(cat "$SH/logs/cap-loss.log" 2>/dev/null)"
  [ ! -s "$SH/beats" ] && ok || bad "C2: under 2h must not beat: $(cat "$SH/beats")"
  # C3 — table down: named, never "0 failovers", no beat
  setup_one c3 cap-loss-detector.sh
  touch "$FIX/cost-rows.down"
  run_one cap-loss-detector.sh
  [ "$(cat "$SH/run.rc")" = 0 ] && ok || bad "C3: exited $(cat "$SH/run.rc")"
  grep -q "$DAY :: cost_rows unreadable — cap-loss NOT measured" "$SH/logs/cap-loss.log" 2>/dev/null \
    && ok || bad "C3: the log must say the day was not measured: $(cat "$SH/logs/cap-loss.log" 2>/dev/null)"
  grep -q 'failovers' "$SH/logs/cap-loss.log" 2>/dev/null && bad "C3: an unreadable table was reported as a failover count" || ok
  [ ! -s "$SH/beats" ] && ok || bad "C3: no beat on an unreadable table"
  grep -q 'cap-loss' "$SH/logs/ALERTS.log" 2>/dev/null && ok || bad "C3: one ALERTS line must name the unmeasured day"
  [ ! -s "$SH/remote.log" ] && ok || bad "C3: cap-loss fell back to the tailnet: $(cat "$SH/remote.log")"
else
  bad "C0: bin/cap-loss-detector.sh pins HARNESS=/root/harness — it cannot be driven in a scratch tree (not run)"
fi

# ============================================================================
# P. the REAL bin/cost-report.sh and bin/cost-readout.sh
# ============================================================================
p_rows() {
  { crow 2026-08-01T01:00:00Z project-2 hostA p execute claude 0 60 10 r
    crow 2026-08-02T01:00:00Z project-2 hostA p execute claude 1 60 0 r
    crow 2026-08-01T02:00:00Z project-3 hostB p review codex 0 60 5 r
  } | rows_json > "$FIX/cost-rows.json"
}
if honours_harness "$DIR/bin/cost-report.sh"; then
  ok
  setup_one p1 cost-report.sh; p_rows
  run_one cost-report.sh
  [ "$(cat "$SH/run.rc")" = 0 ] && ok || bad "P1: cost-report exited $(cat "$SH/run.rc"): $(cat "$SH/run.err")"
  L=$(jq -r '.line' "$SH/beats" 2>/dev/null)
  grep -q 'hostA: \$10 total' <<<"$L" && grep -q 'hostB: \$5 total' <<<"$L" && grep -q '1 claude failures' <<<"$L" \
    && ok || bad "P1: the report beat must name each host from cost_rows: '$L'"
  grep -q 'since=2026-07-29' "$FIX/req.log" && ok || bad "P1: the report must read its window from the table: $(cat "$FIX/req.log")"
  grep -q 'crontab' "$SH/crontab.log" 2>/dev/null && ok || bad "P1: a fired report removes its cron line"
  [ ! -s "$SH/remote.log" ] && ok || bad "P1: cost-report reached a box: $(cat "$SH/remote.log")"
  setup_one p1d cost-report.sh; touch "$FIX/cost-rows.down"
  run_one cost-report.sh
  [ "$(cat "$SH/run.rc")" = 75 ] && ok || bad "P1: an unreadable table must exit 75, got $(cat "$SH/run.rc")"
  [ ! -s "$SH/beats" ] && [ ! -s "$SH/crontab.log" ] && ok \
    || bad "P1: no beat and no cron removal when nothing was read: $(cat "$SH/beats" "$SH/crontab.log" 2>/dev/null)"
  [ ! -s "$SH/remote.log" ] && ok || bad "P1: cost-report fell back to the tailnet: $(cat "$SH/remote.log")"
else
  bad "P0: bin/cost-report.sh pins HARNESS=/root/harness — not run"
fi
# BH-2550 took the model and the cost_rows read out of cost-readout: it renders
# the rollup's state/cost/summary.json and nothing else. What BH-2527 pinned
# here still holds (no box reached, no cron self-removal on a failed read); the
# LLM draft, the per-host cost_rows rollup and rc 75 are gone with the lane, so
# P1 now pins the deterministic contract instead: summary.json rendered, beaten,
# no agent-call, no cost_rows request, and rc 2 with nothing written when there
# is no summary. The script sets H="${HARNESS:-/root/harness}", not HARNESS=.
if grep -qE '^(HARNESS|H)="\$\{HARNESS:-/root/harness\}"' "$DIR/bin/cost-readout.sh"; then
  ok
  ro_setup() {
    setup_one "$1" cost-readout.sh
    mkdir -p "$SH/state/cost"
    printf '#!/bin/bash\nhead -c 200 < <(printf "%%s\\n" "$*") >> "$HARNESS/agent-calls"; echo READOUT > "$5"\n' > "$SH/bin/agent-call.sh"
    chmod +x "$SH/bin/agent-call.sh"
  }
  ro_summary() {
    printf '{"generated_at":"%s","projects":{"project-2":{"cost_24h":10,"cost_7d":12.5},"project-3":{"cost_24h":null}}}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SH/state/cost/summary.json"
  }
  # P1r — the table is readable and holds rows; the read-out still comes from
  # summary.json alone and never asks the table.
  ro_setup p1r; p_rows; ro_summary
  run_one cost-readout.sh
  [ "$(cat "$SH/run.rc")" = 0 ] && ok || bad "P1: cost-readout exited $(cat "$SH/run.rc"): $(cat "$SH/run.err")"
  RO=$(cat "$SH"/logs/cost-readout-*.md 2>/dev/null)
  grep -qF '| project-2 | $10.00 | $12.50 |' <<<"$RO" && grep -qF '| project-3 | unknown |' <<<"$RO" \
    && ok || bad "P1: the read-out must render summary.json's project rows (null = unknown): $RO"
  grep -q 'cost-rows' "$FIX/req.log" 2>/dev/null && bad "P1: cost-readout read cost_rows (BH-2550 renders summary.json): $(cat "$FIX/req.log")" || ok
  grep -q 'cost_readout' "$SH/beats" 2>/dev/null && [ ! -e "$SH/agent-calls" ] && ok \
    || bad "P1: the read-out must be beaten with NO model call: $(cat "$SH/agent-calls" 2>/dev/null)"
  [ ! -s "$SH/crontab.log" ] && ok || bad "P1: cost-readout touched the crontab: $(cat "$SH/crontab.log")"
  [ ! -s "$SH/remote.log" ] && ok || bad "P1: cost-readout reached a box: $(cat "$SH/remote.log")"
  # P1rd — the table is DOWN: irrelevant to the read-out, which still renders.
  ro_setup p1rd; touch "$FIX/cost-rows.down"; ro_summary
  run_one cost-readout.sh
  [ "$(cat "$SH/run.rc")" = 0 ] && ls "$SH"/logs/cost-readout-*.md >/dev/null 2>&1 && ok \
    || bad "P1: an unreadable cost_rows table must not stop the summary.json read-out, rc $(cat "$SH/run.rc")"
  [ ! -s "$SH/remote.log" ] && ok || bad "P1: cost-readout fell back to the tailnet: $(cat "$SH/remote.log")"
  # P1rm — NOTHING TO READ: no summary.json is rc 2, and nothing is written,
  # beaten, bought or removed.
  ro_setup p1rm
  run_one cost-readout.sh
  [ "$(cat "$SH/run.rc")" = 2 ] && ok || bad "P1: cost-readout with no summary.json must exit 2, got $(cat "$SH/run.rc")"
  ! ls "$SH"/logs/cost-readout-*.md >/dev/null 2>&1 && [ ! -e "$SH/agent-calls" ] && [ ! -s "$SH/beats" ] && [ ! -s "$SH/crontab.log" ] && ok \
    || bad "P1: no read-out, no LLM call, no beat, no cron removal when nothing was read"
  [ ! -s "$SH/remote.log" ] && ok || bad "P1: cost-readout fell back to the tailnet: $(cat "$SH/remote.log")"
else
  bad "P0: bin/cost-readout.sh pins HARNESS=/root/harness — not run"
fi

printf 'cost-readers-no-ssh.bh-2527: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
