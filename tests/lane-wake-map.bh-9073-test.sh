#!/bin/bash
# tests/lane-wake-map.bh-9073-test.sh — BH-9073 (BH-9067.1): the wake
# registry of the model lanes. catalog/lane-wakes.d/<lane>.json (16 lanes),
# their MODE_<LANE> knobs (catalog/lanes.d/_lib.lane-wake-gate.knobs.d/), their
# backstop rings (catalog/lane-calendar.d/<lane>.tsv) and the exemption list
# catalog/lane-wakes.d/_exempt.tsv.
#
#   M1  census coverage: every model lane (catalog/llm-sites.d, non-null lane)
#       with a cron cadence has a registry file or an _exempt.tsv line, never
#       both; the checker bites on a copy with staff.json removed
#   M2  each registry file: lane = file name, scope = project iff the lane's
#       script passes a project to lane_gate_or_exit, kinds valid, mode_knob =
#       MODE_<LANE>, its knob file has default shadow, lwg_mode prints shadow
#   M3  each gated lane has one calendar file; each line parses; hourly lanes
#       ring 24 times a day; run-product rings once a week, Monday 09:00
#   M4  each of the 16 lanes, mode on, no wake: a scheduled lane_gate_or_exit
#       exits 0 before its marker and logs `lwg <lane> <scope> skip`
#   M5  the REAL bin/run-triage.sh, mode on: no wake = skip, 0 agent calls; an
#       issue webhook for the project's repo = run webhook=<id>, 1 call; an
#       issue webhook for another repo = skip, 0 calls; a ring = run wake=<id>
#   M6  the REAL bin/run-triage.sh, mode shadow, no wake: would-skip, the
#       session runs (1 call)
#
# WHAT IS REAL. bin/lib/lane-gate.sh + bin/lib/lane-wake-gate.sh, the worker
# routes lane-wakes.js, wakes.js and settings.js over a node:sqlite file from
# the composed jobs schema (the tests/lane-wake-gate.bh-9072-test.sh pattern),
# and bin/run-triage.sh with its bin/lib/rt/*.sh stages.
# WHAT IS STUBBED. bin/agent-call.sh (one line per call in $T/agentcalls), and
# the triage helpers of tests/run-triage-callguard-skip.bh-4120-test.sh
# (triage-gate.sh answers RUN forced, gate-diff, unblocked-children,
# triage-contract, beat, lane-alert, box-name). `curl` sends every request for
# the fake worker to $T/wdrv.mjs; any other host and `gh` go to $T/net.log and
# fail. The clock is pinned (LANE_GATE_NOW, the worker's FXT_NOW). Each case
# starts from a fresh database copy and an empty state/ and logs/.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-wake-map.bh-9073-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "lane-wake-map: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "lane-wake-map: python3 is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
CASE=""; CASE_FAIL=0
case_end() { [ -z "$CASE" ] || { [ "$FAIL" -eq "$CASE_FAIL" ] && echo "PASS: $CASE" || echo "FAIL-CASE: $CASE"; }; }
case_start() { case_end; CASE="$1"; CASE_FAIL=$FAIL; }

GATED="run-triage review-prs merge-queue postmerge-qa run-product alert-triage alerts-medic archie-cards
component-watch daily-digest dequeue-watch review-rescue sentry-triage staff unblock watchdog-responder"
WAKES="$DIR/catalog/lane-wakes.d"
KNOBD="$DIR/catalog/lanes.d/_lib.lane-wake-gate.knobs.d"
CALD="$DIR/catalog/lane-calendar.d"
knob_of() { printf 'MODE_%s' "$(printf '%s' "${1//-/_}" | tr '[:lower:]' '[:upper:]')"; }

# census_check <repo root> — prints one line per problem: `uncovered <lane>`,
# `both <lane>`, `bad-exempt <line>`. Nothing = every census model lane with
# a cron cadence is either gated or exempt.
census_check() {
  local r="$1" lane cad
  { jq -r '.[]? | .lane // empty' "$r"/catalog/llm-sites.d/*.json 2>/dev/null | sort -u; } | while read -r lane; do
    cad=$(jq -r '.cadence // ""' "$r/catalog/lanes.d/$lane.json" 2>/dev/null)
    # a cron cadence: the first 5 fields are cron fields ("on demand ..." is not)
    python3 -c 'import re,sys; f=sys.argv[1].split(";")[0].split(); sys.exit(0 if len(f)>=5 and all(re.fullmatch(r"[0-9*,/-]+",x) for x in f[:5]) else 1)' "$cad" || continue
    local g=0 e=0 cls
    [ -f "$r/catalog/lane-wakes.d/$lane.json" ] && g=1
    cls=$(awk -F'\t' -v l="$lane" '$1==l {print $2; exit}' "$r/catalog/lane-wakes.d/_exempt.tsv" 2>/dev/null)
    [ -n "$cls" ] && e=1
    [ "$g$e" = 00 ] && echo "uncovered $lane"
    # `owned` = a sibling ticket gates it: its registry file is that ticket's
    # (pm-groom: BH-9072; the calendar lanes: BH-9074), never this one's.
    [ "$g$e" = 11 ] && [ "$cls" != owned ] && echo "both $lane"
  done
  grep -v '^#' "$r/catalog/lane-wakes.d/_exempt.tsv" 2>/dev/null | awk -F'\t' 'NF && ($2 !~ /^(owned|backstop|schedule|box|on-demand)$/ || $3 == "") {print "bad-exempt " $0}'
}

case_start M1
# ═════ M1: census coverage ═══════════════════════════════════════════════════
eq "M1 the exemption list exists" "$([ -f "$WAKES/_exempt.tsv" ] && echo yes)" yes
OUT=$(census_check "$DIR")
eq "M1 every census model lane with a cron cadence is gated or exempt, never both" "$OUT" ""
# pm-groom, the 7 calendar lanes and the 3 schedules are exempt, not gated
for l in pm-groom claude-auth-check archie archie-research rule-miner lookback orc-monitor healthcheck apply-migrations deploy-train lead-review preplan-tick merge-conductor blocked-resolver; do
  eq "M1 $l has an exempt line" "$(awk -F'\t' -v l="$l" '$1==l' "$WAKES/_exempt.tsv" 2>/dev/null | grep -c .)" 1
done
for l in healthcheck apply-migrations deploy-train lead-review preplan-tick merge-conductor blocked-resolver; do
  eq "M1 $l (not owned by a sibling) has no registry file" "$([ -f "$WAKES/$l.json" ] && echo yes || echo no)" no
done
# The checker bites: a copy with staff.json removed reports staff.
C="$T/census"; mkdir -p "$C/catalog/lanes.d" "$C/catalog/lane-wakes.d" "$C/catalog/llm-sites.d"
cp "$DIR"/catalog/llm-sites.d/*.json "$C/catalog/llm-sites.d/"
cp "$DIR"/catalog/lanes.d/*.json "$C/catalog/lanes.d/"
cp "$WAKES"/*.json "$WAKES/_exempt.tsv" "$C/catalog/lane-wakes.d/" 2>/dev/null
rm -f "$C/catalog/lane-wakes.d/staff.json"
eq "M1 negative: staff.json removed is reported" "$(census_check "$C")" "uncovered staff"
cp "$WAKES/staff.json" "$C/catalog/lane-wakes.d/" 2>/dev/null
printf 'staff\tschedule\tfixture: both\n' >> "$C/catalog/lane-wakes.d/_exempt.tsv"
eq "M1 negative: a lane both gated and exempt is reported" "$(census_check "$C")" "both staff"
printf 'web-task\tbogus\tfixture\n' >> "$C/catalog/lane-wakes.d/_exempt.tsv"
eq "M1 negative: an unknown class is reported" "$(census_check "$C" | grep -c '^bad-exempt web-task')" 1

case_start M2
# ═════ M2: each registry file, its scope, kinds and mode knob ════════════════
N=0
for l in $GATED; do
  N=$((N+1))
  f="$WAKES/$l.json"
  [ -f "$f" ] || { bad "M2 $l: no $f"; continue; }
  eq "M2 $l .lane = file name" "$(jq -r .lane "$f")" "$l"
  scr="$DIR/$(jq -r .script "$DIR/catalog/lanes.d/$l.json")"
  if grep -qE "lane_gate_or_exit $l \"\\\$" "$scr"; then want=project; else want=fleet; fi
  grep -qE "lane_gate_or_exit $l( |\$|;)" "$scr" || bad "M2 $l: $scr never calls lane_gate_or_exit $l"
  eq "M2 $l .scope = the script's lane_gate_or_exit call" "$(jq -r .scope "$f")" "$want"
  eq "M2 $l kinds valid (<= 8, ^[a-z_]{1,32}\$, webhook kinds the worker writes)" \
    "$(jq -r '(.kinds | type == "array" and length <= 8 and all(.[]; type == "string" and test("^[a-z_]{1,32}$")
        and IN("issue","pr","checks","push","merge_group","deploy")))' "$f")" true
  [ "$want" = fleet ] && eq "M2 $l fleet scope takes rings only: no kinds" "$(jq -c .kinds "$f")" '[]'
  [ "$want" = project ] && eq "M2 $l project scope names at least one kind" "$(jq '.kinds | length > 0' "$f")" true
  k=$(knob_of "$l")
  eq "M2 $l .mode_knob" "$(jq -r .mode_knob "$f")" "$k"
  eq "M2 $l knob file default shadow" "$(jq -r '.default' "$KNOBD/$k.json" 2>/dev/null)" shadow
  eq "M2 $l knob file reads in the registry file" "$(jq -r '.read_in' "$KNOBD/$k.json" 2>/dev/null)" "catalog/lane-wakes.d/$l.json"
  eq "M2 $l knob note names its row" "$(jq -r '.note' "$KNOBD/$k.json" 2>/dev/null | grep -c "lib.lane-wake-gate.$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')")" 1
done
eq "M2 16 gated lanes" "$N" 16
for l in $(cd "$WAKES" && ls -- *.json | sed 's/\.json$//'); do
  case " $(echo $GATED) " in *" $l "*) ok ;; *)
    eq "M2 a registry file outside the 16 ($l) is a sibling's (exempt owned)" \
      "$(awk -F'\t' -v l="$l" '$1==l {print $2}' "$WAKES/_exempt.tsv")" owned ;;
  esac
done

case_start M3
# ═════ M3: backstop rings ════════════════════════════════════════════════════
# The walk: the same 5-field grammar bin/lane-wake-calendar.sh (BH-9074) reads.
cat > "$T/calwalk.py" <<'PY'
import re, sys, datetime
def field(spec, v, lo, hi):
    hit = False
    for item in spec.split(","):
        step = 1; rng = item
        if "/" in item:
            rng, s = item.split("/"); step = int(s)
            if step < 1: raise ValueError(item)
        if rng == "*": a, b = lo, hi
        elif "-" in rng: a, b = map(int, rng.split("-"))
        else:
            if not re.fullmatch(r"[0-9]{1,2}", rng): raise ValueError(item)
            a = b = int(rng)
        if not (lo <= a <= b <= hi): raise ValueError(item)
        if a <= v <= b and (v - a) % step == 0: hit = True
    return hit
def match(expr, t):
    mi, ho, dm, mo, dw = expr.split()
    dow = (t.weekday() + 1) % 7
    d1 = field(dm, t.day, 1, 31); d2 = field(dw, dow, 0, 7) or (dow == 0 and field(dw, 7, 0, 7))
    day = (d1 or d2) if (not dm.startswith("*") and not dw.startswith("*")) else (d1 and d2)
    return field(mi, t.minute, 0, 59) and field(ho, t.hour, 0, 23) and field(mo, t.month, 1, 12) and day
expr, start, minutes = sys.argv[1], sys.argv[2], int(sys.argv[3])
t = datetime.datetime.strptime(start, "%Y-%m-%dT%H:%M")
hits = []
for i in range(minutes):
    if match(expr, t): hits.append(t)
    t += datetime.timedelta(minutes=1)
hours = sorted({h.strftime("%Y%m%d%H") for h in hits})
print(len(hits), len(hours), " ".join(h.strftime("%a-%H:%M") for h in hits[:3]))
PY
for l in $GATED; do
  f="$CALD/$l.tsv"
  [ -f "$f" ] || { bad "M3 $l: no $f"; continue; }
  eq "M3 $l one calendar line" "$(grep -v '^#' "$f" | grep -c .)" 1
  IFS=$'\t' read -r expr fmt < "$f"
  eq "M3 $l 5 cron fields" "$(awk '{print NF}' <<<"$expr")" 5
  eq "M3 $l key format" "$fmt" '%Y%m%dt%H%M'
  eq "M3 $l the key is a worker dedupe" "$(date -u -d @0 "+cal:$fmt" | grep -cE '^[a-z0-9:#@._-]{1,64}$')" 1
  out=$(python3 "$T/calwalk.py" "$expr" 2026-11-09T00:00 10080 2>&1) || { bad "M3 $l: the expr does not parse: $out"; continue; }
  read -r nweek _ _ <<<"$out"
  [ "$nweek" -ge 1 ] 2>/dev/null && ok || bad "M3 $l fires at least once in 7 days (got $out)"
  if [ "$l" = run-product ]; then
    eq "M3 run-product fires once a week, Monday 09:00" "$out" "1 1 Mon-09:00"
  else
    read -r nday nhours _ <<<"$(python3 "$T/calwalk.py" "$expr" 2026-11-09T00:00 1440)"
    eq "M3 $l fires 24 times in a 24 h walk, once each hour" "$nday/$nhours" "24/24"
  fi
done
eq "M3 the grammar refuses a bad expr" "$(python3 "$T/calwalk.py" '61 * * * *' 2026-11-09T00:00 60 >/dev/null 2>&1; echo $?)" 1

# ═════ the fake worker and the scratch harness (M4-M6) ═══════════════════════
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  case_end
  echo "lane-wake-map: M4-M6 SKIPPED — node with node:sqlite is not installed on this box"
  echo "lane-wake-map: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
NOW=2026-11-09T11:05:00Z           # a Monday, minute 5: no quarter-hour start offset
NOW_S=$(date -u -d "$NOW" +%s)
P=project-3
REPO=example-org/project-3-fixture
cat > "$T/wdrv.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, readFileSync } from 'node:fs';
const W = process.env.LWG_WORKER_DIR;
const { d1 } = await import(`${W}/test/lib/d1-sqlite.bh-1030.js`);
const { matchRoute } = await import(`${W}/src/lib/router.js`);
const routes = [];
for (const f of ['lane-wakes', 'wakes', 'settings', 'model-routes']) routes.push(...(await import(`${W}/src/routes/${f}.js`)).routes);
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
async function answer() {
  let raw = '';
  if (bodyFile) { try { raw = readFileSync(bodyFile, 'utf8'); } catch { raw = ''; } }
  const url = new URL('https://jobs.test' + pathq);
  appendFileSync(`${T}/hits`, `${method} ${url.pathname}\n`);
  let body = null;
  if (raw) { try { body = JSON.parse(raw); } catch { body = null; } }
  const hit = matchRoute(routes, method, url.pathname);
  if (!hit) return [404, JSON.stringify({ error: 'unknown endpoint' })];
  const db = new DatabaseSync(`${T}/d1.sqlite`, { timeout: 10000 });
  const res = await hit.handler({ env: { DB: d1(db) }, url, path: url.pathname, t: process.env.FXT_NOW, body: body || {}, m: hit.m });
  return [res.status, await res.text()];
}
const [code, text] = await answer();
process.stdout.write(text + '\n' + code);
JS
cat > "$T/q.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [sql, ...binds] = process.argv.slice(2);
const st = db.prepare(sql);
if (/^\s*(select|with)|returning/i.test(sql)) console.log(JSON.stringify(st.all(...binds)));
else { st.run(...binds); console.log('[]'); }
JS
cat > "$T/mkdb.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const db = new DatabaseSync(process.argv[2]);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
export FXT="$T" FXT_NOW="$NOW" LWG_WORKER_DIR="$DIR/worker/jobs" NODE_NO_WARNINGS=1
node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err" || { echo "FAIL: the schema does not apply: $(head -3 "$T/mkdb.err")"; exit 1; }
q() { node "$T/q.mjs" "$@"; }

H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/bin/lib/rt" "$H/catalog/lane-wakes.d" "$H/prompts" "$H/fixture" "$T/fakebin"
# The run-triage stubs (the tests/run-triage-callguard-skip.bh-4120-test.sh
# fixture), written BEFORE the closure install so it keeps them.
printf '#!/bin/sh\necho box-%s\n' "$P" > "$H/bin/box-name.sh"
cat > "$H/bin/triage-gate.sh" <<'SH'
#!/bin/bash
printf '{"issues":[{"number":561,"state":"OPEN","title":"a"}],"prs":[]}' > "$HARNESS/state/$1.gate.pending"
[ "${2:-}" = "--pending" ] && exit 0
echo "RUN forced"
exit 0
SH
printf '#!/bin/sh\nexit 2\n' > "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1 $2" >> "$FXT/agentcalls"
echo "tickets=1 triage ran" > "$5"
exit 0
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary|-d|--data) data="$2"; [ "$method" = GET ] && method=POST; shift 2 ;;
    -o|-w|-H|-m|--max-time|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  "$JOBS_URL"/*)
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "$FXT/body.XXXXXX")
      case "$data" in @*) cp "${data#@}" "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/gh"
chmod +x "$H/bin/"*.sh "$T/fakebin/curl" "$T/fakebin/gh"
for L in bin/run-triage.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/lane-wake-gate.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
for l in $GATED; do
  ( cd "$DIR" && scratch_install_closure "$(jq -r .script "catalog/lanes.d/$l.json")" "$H" ) >/dev/null || true
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$H/catalog"
cp "$DIR/catalog/lanes.json" "$H/catalog/"
cp "$WAKES"/*.json "$H/catalog/lane-wakes.d/"
: > "$H/env/global.env"
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
printf '%s %s https://project-3.example.com /api/feature-board 0 local\nacme example-org/acme-fixture https://acme.example.com - 0 local\n' "$P" "$REPO" > "$T/fleet.conf"
: > "$T/net.log"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh9073 \
  FLEET_CONF="$T/fleet.conf" LANE_GATE_NOW="$NOW_S" HARNESS_TEST_SANDBOX=1 JOBS_RETRY_SLEEP=0
unset H_CHECKOUT HARNESS_CHECKOUT MODE_DEFAULT LWG_TIMEOUT_S LWG_FAIL_LOG_EVERY_S LANE_GATE_DISABLE LANE_REGISTRY 2>/dev/null || true

LOGW="$H/logs/lane-wake-gate.log"
setrow() { q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-11-09T00:00:00Z')" "$1" "$2" >/dev/null; }
prime() {
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_settings_refresh' >/dev/null 2>&1
  : > "$T/hits"
}
# reset <lane> <mode|""> — a fresh database, empty state/logs/flags, the row
# lib.lane-wake-gate.mode_<lane> when a mode is given, the settings cache primed.
reset() {
  local p
  for p in hits agentcalls rc out; do scratch_rm "$T/$p" || exit 1; done
  for p in state locks flags logs; do scratch_rm "$H/$p" || exit 1; done
  mkdir -p "$H/logs" "$H/flags" "$H/state" "$H/locks"
  : > "$H/flags/triage-shards-off"
  model_routes_fixture "$H" "$P" >/dev/null || exit 1
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  [ -z "${2:-}" ] || setrow "lib.lane-wake-gate.$(knob_of "$1" | tr '[:upper:]' '[:lower:]')" "$2"
  prime
}
setwm() { mkdir -p "$H/state/lane-wake-gate"; printf '%s\n' "$3" > "$H/state/lane-wake-gate/$1.$2.after"; }
hook()  { local r; r=$(q "INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?, ?, ?, ?, ?, '2026-11-09T10:00:00Z') RETURNING id" \
            "$1" "$2" "$3" "${4:-issues}" "${5:-m-$3}"); jq -r '.[0].id' <<<"$r"; }
ring()  { bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_ring "$@"' _ "$@" 2>/dev/null; }
mode()  { bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_mode "$1"' _ "$1" 2>/dev/null; }
n()     { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls() { n "$T/agentcalls"; }
last()  { tail -1 "$LOGW" 2>/dev/null | cut -d' ' -f2-; }
# triage: one scheduled tick of the REAL bin/run-triage.sh project-3.
triage() { env LANE_SINGLE_RUN=1 bash "$H/bin/run-triage.sh" "$P" > "$T/out" 2>&1; echo $? > "$T/rc"; }

case_start "M2 lwg_mode"
# ═════ M2 (cont.): with no rows, lwg_mode prints each lane's knob default ═════
reset run-triage ""
for l in $GATED; do eq "M2 lwg_mode $l with no rows" "$(mode "$l")" shadow; done

case_start M4
# ═════ M4: each lane, mode on, no wake: a scheduled tick exits at the gate ════
reset run-triage on
for l in $GATED; do setrow "lib.lane-wake-gate.$(knob_of "$l" | tr '[:upper:]' '[:lower:]')" on; done
scratch_rm "$H/state/settings-cache.json" || exit 1; prime
for l in $GATED; do
  s=$(jq -r .scope "$WAKES/$l.json" 2>/dev/null); [ "$s" = project ] && sc=$P || sc=fleet
  setwm "$l" "$sc" 5; : > "$T/hits"
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
           if [ "$2" = fleet ]; then LANE_SINGLE_RUN=1 lane_gate_or_exit "$1"; else LANE_SINGLE_RUN=1 lane_gate_or_exit "$1" "$2"; fi
           echo MARKER' _ "$l" "$sc" > "$T/out" 2>&1
  eq "M4 $l rc 0" "$?" 0
  eq "M4 $l exits before its marker" "$(grep -c MARKER "$T/out")" 0
  eq "M4 $l logs the skip" "$(last)" "lwg $l $sc skip"
  eq "M4 $l the only worker hit before the exit is the take" "$(grep -v '^GET /api/settings' "$T/hits" | head -1)" "POST /api/lane-wakes/take"
done
eq "M4 0 agent calls" "$(calls)" 0

case_start M5
# ═════ M5: the REAL run-triage, mode on ══════════════════════════════════════
reset run-triage on
B0=$(hook "$REPO" issue 1); setwm run-triage "$P" "$B0"
triage
eq "M5 no wake: rc 0 ($(head -3 "$T/out"))" "$(cat "$T/rc")" 0
eq "M5 no wake: skip" "$(last)" "lwg run-triage $P skip"
eq "M5 no wake: 0 agent calls" "$(calls)" 0
WID=$(hook "$REPO" issue 2)
triage
eq "M5 an issue webhook for $REPO: rc 0 ($(head -3 "$T/out"))" "$(cat "$T/rc")" 0
eq "M5 an issue webhook: run webhook=<id>" "$(last)" "lwg run-triage $P run webhook=$WID"
eq "M5 an issue webhook: exactly 1 agent call" "$(calls)" 1
triage
eq "M5 the next tick: skip" "$(last)" "lwg run-triage $P skip"
eq "M5 the next tick: still 1 agent call" "$(calls)" 1
hook example-org/acme-fixture issue 3 >/dev/null
triage
eq "M5 an issue webhook for another repo: skip" "$(last)" "lwg run-triage $P skip"
eq "M5 an issue webhook for another repo: 0 new agent calls" "$(calls)" 1
eq "M5 a ring is stored" "$(ring run-triage "$P" cal:20261109t1107)" inserted=1
RID=$(q "SELECT id FROM wakes WHERE repo='harness/lanes' AND key='run-triage:$P'" | jq -r '.[0].id')
triage
eq "M5 a ring: run wake=<id>" "$(last)" "lwg run-triage $P run wake=$RID"
eq "M5 a ring: 1 more agent call" "$(calls)" 2

case_start M6
# ═════ M6: the REAL run-triage, mode shadow (the shipped default), no wake ═══
reset run-triage ""
setwm run-triage "$P" 5
triage
eq "M6 rc 0 ($(head -3 "$T/out"))" "$(cat "$T/rc")" 0
eq "M6 would-skip" "$(last)" "lwg run-triage $P would-skip"
eq "M6 the session runs: 1 agent call" "$(calls)" 1

case_start "0 network"
eq "the fake curl reached no other host ($(head -3 "$T/net.log"))" "$(n "$T/net.log")" 0
case_end
echo "lane-wake-map: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
