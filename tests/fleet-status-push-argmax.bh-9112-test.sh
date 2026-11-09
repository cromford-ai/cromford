#!/bin/bash
# tests/fleet-status-push-argmax.bh-9112-test.sh — BH-9112: the full fleet
# snapshot must build when one field is bigger than one argv string may be.
#
# On bh-hub-2 (2026-11-05) every run logged `/usr/bin/jq: Argument list too
# long` and pushed the pre-2026-09-14 shape: no hub, no lanes_down, no rules.
# The kernel refuses one execve string over MAX_ARG_STRLEN (128 KiB), and the
# SNAP jq took every fleet-sized value as an --argjson string. This suite drives
# a 30-project fleet with 300 lanes down and a rules answer over 128 KiB:
#   A. no argv error, the full shape, and the size shed drops ONLY the big
#      field (largest first), so lanes_down and harness_heads survive it;
#   B. a fallback that still happens names its cause in the log on every run
#      and in ALERTS.log once per UTC day;
#   C. a pad in a field that cannot be shed still sheds every sheddable key.
# Run from anywhere: tests/fleet-status-push-argmax.bh-9112-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the per-day alert flag is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
REAL_JQ=$(command -v jq)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin" "$T/fakejq"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# alert-line stub: the one sanctioned writer, reduced to its append.
cat > "$T/bin/alert-line.sh" <<SH
#!/bin/bash
while [ \$# -gt 0 ]; do case "\$1" in --severity|--id|--project) [ "\$1" = --id ] && ID="\$2"; shift 2 ;; *) break ;; esac; done
echo "\$(date -u '+%F %TZ') [id:\${ID:-}] \$*" >> "$T/logs/ALERTS.log"
SH
chmod +x "$T/bin/alert-line.sh"
# B1's forced fallback: a jq that fails the full SNAP call (the only call whose
# filter names hub_harness_head:) and is the real jq for every other call.
cat > "$T/fakejq/jq" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in *hub_harness_head:*) exit 5 ;; esac; done
exec "$REAL_JQ" "\$@"
SH
chmod +x "$T/fakejq/jq"

# 30 projects over 6 boxes.
: > "$T/fleet.conf"
for i in $(seq -w 1 30); do
  printf 'p%s-os Org/p%s https://p%s.example /api/board 2 box-%d\n' "$i" "$i" "$i" $(( (10#$i - 1) % 6 + 1 )) >> "$T/fleet.conf"
done

TODAY=$(date -u +%Y%m%d)
YDAY=$(date -u -d yesterday +%Y%m%d 2>/dev/null || date -u -v-1d +%Y%m%d)
# 300 lanes down today, 50 per box, long lane names (~20 KB of lanes_down).
PADL=$(printf 'x%.0s' $(seq 1 50))
for b in 1 2 3 4 5 6; do
  for n in $(seq -w 1 50); do touch "$T/flags/lanedown-box-$b-lane${n}${PADL}-$TODAY"; done
done

# jobs-client stub: safe to source; `rules` answers $RULES_N rows whose
# selector is $RULES_W characters wide.
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
case "${1:-}" in
  rules) w=$(cat "$HARNESS/rules-width"); n=$(cat "$HARNESS/rules-n"); s=$(printf 's%.0s' $(seq 1 "$w"))
         for i in $(seq 1 "$n"); do printf 'project\t%s%d\tbuild\t2\tcap\n' "$s" "$i"; done ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/jobs-client.sh"
rules_size() { echo "$2" > "$T/rules-n"; echo "$1" > "$T/rules-width"; }

run() {
  rm -f "$T/PUSH.json" "$T/BEAT.json"
  PATH="${XPATH:-}$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh" 2>"$T/err"
}
q()   { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }
fell_back_n() { cat "$T/logs/fleet-status-push.log" 2>/dev/null | grep -c 'full snapshot fell back:'; }
alerts_n()    { cat "$T/logs/ALERTS.log" 2>/dev/null | grep -cE 'fleet-status-snap-fallback|full snapshot fell back'; }
last_fb()     { cat "$T/logs/fleet-status-push.log" 2>/dev/null | grep 'full snapshot fell back:' | tail -1; }
SHEDDABLE='["quota","quota_error","gh_quota","rules","ceilings","lanes_down","lanes_down_detail","alert_backlog","remote_results_pending","hub","backups","backup_stale_min","gh_rest_quota","gh_quota_reserve","standby","standby_error","harness_heads","harness_heads_error","ci_timeout_budget","ci_timeout_budget_truncated"]'

# The fixture is the ticket's failure case: one value over one argv string.
rules_size 3000 50
RSZ=$(HARNESS="$T" bash "$T/bin/jobs-client.sh" rules | wc -c)
[ "$RSZ" -gt 131072 ] && ok || bad "fixture: the rules output must be over 131072 bytes (got $RSZ)"

# ─────────────────────────────────────────────────────────────────────────────
# A. a field over 128 KiB: no argv error, full shape, shed only that field
# ─────────────────────────────────────────────────────────────────────────────
run
grep -q 'Argument list too long' "$T/err" \
  && bad "A1: jq must not hit the argv limit (stderr: $(grep -m1 'Argument list' "$T/err"))" || ok
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "A2: the push must be valid JSON"
[ "$(q 'has("hub") and has("harness_heads") and has("lanes_down")')" = true ] \
  && ok || bad "A2: the push must be the full shape (keys: $(q 'keys|join(",")'))"
[ "$(q '[.lanes_down[]] | add | length')" = 300 ] && [ "$(q '.lanes_down | length')" = 6 ] \
  && ok || bad "A2: lanes_down must carry 300 lanes over 6 boxes (got $(q '[.lanes_down[]]|add|length') / $(q '.lanes_down|length'))"
[ "$(fell_back_n)" = 0 ] && ok || bad "A2: a full build must log no fall back (got $(fell_back_n))"
[ "$(q '.snapshot_trimmed')" = size ] && [ "$(q '.snapshot_shed | tojson')" = '["rules"]' ] \
  && ok || bad "A3: the shed must drop only rules (trimmed=$(q '.snapshot_trimmed') shed=$(q '.snapshot_shed|tojson'))"
[ "$(q 'has("rules")')" = false ] && ok || bad "A3: rules must be shed"
[ "$(wc -c < "$T/PUSH.json")" -le 60000 ] && ok || bad "A3: the shed push must fit the cap (got $(wc -c < "$T/PUSH.json"))"
OWNED='[.snapshot_trimmed, .snapshot_shed, has("rules"), .lanes_down, .harness_heads, .hub.load1]'
[ "$(jq -c "$OWNED" "$T/BEAT.json" 2>/dev/null)" = "$(jq -c "$OWNED" "$T/PUSH.json")" ] \
  && [ "$(jq -r .kind "$T/BEAT.json" 2>/dev/null)" = fleet_status ] \
  && ok || bad "A3: the beat must carry the push's shed snapshot plus kind"

# A4. every field small: nothing shed, both lanes_down and rules present.
rules_size 200 10
run
[ "$(q '.rules | length')" = 10 ] && ok || bad "A4: rules must carry 10 rows (got $(q '.rules|length'))"
[ "$(q 'has("lanes_down")')" = true ] && [ "$(q 'has("snapshot_trimmed") or has("snapshot_shed")')" = false ] \
  && ok || bad "A4: a small snapshot is not trimmed (keys: $(q 'keys|join(",")'))"
[ "$(wc -c < "$T/PUSH.json")" -lt 60000 ] && ok || bad "A4: the push must be under 60000 bytes"
# B5. the near miss: a normal run writes no fallback line and no alert.
[ "$(fell_back_n)" = 0 ] && [ "$(alerts_n)" = 0 ] \
  && ok || bad "B5: a normal run must not log or alert a fallback (log $(fell_back_n), alerts $(alerts_n))"

# ─────────────────────────────────────────────────────────────────────────────
# B. a fallback names its cause: a log line per run, an ALERTS line per day
# ─────────────────────────────────────────────────────────────────────────────
XPATH="$T/fakejq:" run
[ "$(q 'has("projects")')" = true ] && [ "$(q 'has("hub")')" = false ] \
  && ok || bad "B1: a failed full SNAP must still push the fallback shape (keys: $(q 'keys|join(",")'))"
[ "$(fell_back_n)" = 1 ] && ok || bad "B1: one fall back log line (got $(fell_back_n))"
L=$(last_fb)
case "$L" in *invalid=none*rc=5*) ok ;; *) bad "B1: the line names invalid=none and rc=5 (got: $L)" ;; esac
case "$L" in *largest=*:[0-9]*env=[0-9]*) ok ;; *) bad "B1: the line names the largest fields and env bytes (got: $L)" ;; esac
[ "$(alerts_n)" = 1 ] && ok || bad "B1: one ALERTS line on the first fallback of the day (got $(alerts_n))"

XPATH="$T/fakejq:" run
[ "$(alerts_n)" = 1 ] && ok || bad "B2: a second fallback the same day must not alert again (got $(alerts_n))"
[ "$(fell_back_n)" = 2 ] && ok || bad "B2: the log names every fallback run (got $(fell_back_n))"

rm -f "$T/flags/alerted-fleet-status-snap-fallback-"*
touch "$T/flags/alerted-fleet-status-snap-fallback-$YDAY"
XPATH="$T/fakejq:" run
[ "$(alerts_n)" = 2 ] && ok || bad "B3: a new day re-arms the alert; yesterday's flag does not suppress it (got $(alerts_n))"

# B4. an invalid field is named.
cp "$T/bin/fleet-fly-block.sh" "$T/fly.aside"
printf '#!/bin/bash\nprintf %%s %s\n' "'{\"x\":'" > "$T/bin/fleet-fly-block.sh"; chmod +x "$T/bin/fleet-fly-block.sh"
run
L=$(last_fb)
case "$L" in *invalid=fly*) ok ;; *) bad "B4: the line names the invalid field (got: $L)" ;; esac
mv "$T/fly.aside" "$T/bin/fleet-fly-block.sh"

# ─────────────────────────────────────────────────────────────────────────────
# C. a pad in a field that cannot be shed still sheds every sheddable key
# ─────────────────────────────────────────────────────────────────────────────
PAD=$(printf 'k%.0s' $(seq 1 61000))
printf '{"%s":{"count":1}}\n' "$PAD" > "$T/state/stale-owed.json"
rm -f "$T/state/stale-owed-reported.json"
run
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "C1: an over-cap snapshot is trimmed (got $(q '.snapshot_trimmed'))"
[ "$(jq -r --argjson s "$SHEDDABLE" '[$s[] as $k | select(has($k))] | length' "$T/PUSH.json" 2>/dev/null)" = 0 ] \
  && ok || bad "C1: no sheddable key may stay (left: $(jq -c --argjson s "$SHEDDABLE" '[$s[] as $k | select(has($k)) | $k]' "$T/PUSH.json"))"
[ "$(q 'has("projects")')" = true ] && ok || bad "C1: the unsheddable fields stay"

echo "fleet-status-push-argmax.bh-9112: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
