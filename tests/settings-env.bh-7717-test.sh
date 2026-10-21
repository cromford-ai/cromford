#!/bin/bash
# tests/settings-env.bh-7717-test.sh — BH-7717: the settings memo loads from a
# pre-rendered env file (state/lane-gate/settings-cache.env) when that file is bound to
# the exact bytes of state/settings-cache.json, and from today's one jq
# otherwise. The refresh renders the file when it writes a new cache.
#
#   E1  parity: the memo from the env file equals the memo from jq, byte for
#       byte, for string, int, empty, dotted, underscored, dashed, null, false,
#       true, object, UTF-8 and quote/newline values; the env read runs 0 jq.
#       lane_knob gives the same row / env / default answers on both paths.
#   E2  _lg_settings_refresh renders the env file; a changed answer past the
#       TTL re-renders it; a new process reads the new values with 0 jq.
#   E3  a file that is not bound (no file, v0, v2, length off by one, last
#       raw byte changed, trailer cut, cut inside the raw) is refused: 1 jq and
#       the jq-path memo.
#   E4  a value with $(…) or `…` runs on neither path.
#   E5  LANE_GATE_SC_ENV=0: a valid file is ignored and a refresh writes none.
#   E7  _setting_cache_stale rewrites the cache after a render: the file no
#       longer binds, the load sees fetched 0.
#   E8  the env write fails (mktemp, mv, or state/lane-gate is a file): refresh rc 0, the cache is new, no
#       temp file is left, the values read right.
#   E9  a writer swaps v1/v2 (cache, then env) while new processes load: each
#       memo is the v1 memo or the v2 memo, never another.
#   E10 the state-backup manifest does not move when only the env file changes.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/settings-env.bh-7717-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
H="$T/h"; SHIM="$T/shim"; SC="$H/state/settings-cache.json"; EF="$H/state/lane-gate/settings-cache.env"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$SHIM"
# The jq shim counts only the calls whose arguments name the settings cache.
cat > "$SHIM/jq" <<SH
#!/bin/bash
case " \$* " in *settings-cache.json*) echo x >> "$T/jq-calls" ;; esac
exec $(command -v jq) "\$@"
SH
chmod +x "$SHIM/jq"
jqn() { if [ -f "$T/jq-calls" ]; then wc -l < "$T/jq-calls" | tr -d ' '; else echo 0; fi; }

# probe <script> — a fresh bash that sources the real library, shim first on PATH.
probe() {
  PATH="${PROBE_PATH:-$SHIM}:$PATH" HARNESS="$H" bash -c '. "$1"; eval "$2"' _ "$DIR/bin/lib/lane-gate.sh" "$1" 2>&1
}
# The whole memo: every _LG_SK_* / _LG_SV_* (quoted by declare -p), the names
# list, the key count and fetched_at.
DUMP='_lg_sc_load; echo "rc=$?"; for v in $(compgen -v _LG_SK_) $(compgen -v _LG_SV_); do declare -p "$v"; done
  echo "NAMES=$_LG_SC_NAMES"; echo "N=$_LG_SK_N F=$_LG_SFETCHED"'
render() { probe '_LG_SC_RENDER=1 _lg_sc_load' >/dev/null; }
# jqdump — the memo through today's jq path (no env file), and its jq count.
jqdump() { local s; s=$(mktemp "$T/sv.XXXXXX"); [ -f "$EF" ] && mv "$EF" "$s"; : > "$T/jq-calls"
  JQD=$(probe "$DUMP"); JQN=$(jqn); [ -s "$s" ] && mv "$s" "$EF"; rm -f "$s"; }

# ── E1 parity ────────────────────────────────────────────────────────────────
fixture() {
  jq -n --arg pwn "$T/pwn" '{fetched_at: 1758300100, values: {
    "s": "plain string", "i": 5, "e": "", "a.b.c": "dotted", "a_b": "under", "x-y": "dash",
    "n": null, "f": false, "t": true, "o": {"k": [1, "two"]}, "u": "naïve — ünï ✓",
    "q": "it'"'"'s \"q\"\nline2 $HOME", "bad key": "not memoised",
    "lane.t.rowk": "fromrow", "lane.t.bothk": "rowwins",
    "c1": ("$(touch " + $pwn + ")"), "c2": ("`touch " + $pwn + "`")}}'
}
fixture | jq -c . > "$SC"
rm -f "$EF" "$T/pwn"
jqdump
[ "$JQN" = 1 ] && ok || bad "E1 jq path ran $JQN jq (want 1)"
case "$JQD" in *"rc=0"*"_LG_SV_s="*"N=17 F=1758300100"*) ok ;; *) bad "E1 jq-path dump looks wrong: $JQD" ;; esac
render
[ -f "$EF" ] && ok || bad "E1 render wrote no $EF"
: > "$T/jq-calls"
ENVD=$(probe "$DUMP")
[ "$ENVD" = "$JQD" ] && ok || { bad "E1 env-path memo differs from jq-path memo"; diff <(printf '%s\n' "$JQD") <(printf '%s\n' "$ENVD") | head -20; }
[ "$(jqn)" = 0 ] && ok || bad "E1 env path ran $(jqn) jq over the cache (want 0)"
[ ! -e "$T/pwn" ] && ok || bad "E4 a cache value was executed"

# A pretty-printed (multi-line) cache binds too.
fixture > "$SC"; rm -f "$EF"; jqdump; render
: > "$T/jq-calls"; ENVD=$(probe "$DUMP")
[ "$ENVD" = "$JQD" ] && [ "$(jqn)" = 0 ] && ok || bad "E1 pretty cache: env memo differs or ran $(jqn) jq"
[ ! -e "$T/pwn" ] && ok || bad "E4 a cache value was executed (pretty cache)"

# lane_knob: the DB row first, then env, then the registry default.
cat > "$T/reg.json" <<'J'
{"lanes":[{"id":"t","knobs":[{"env":"ROWK","default":"d1"},{"env":"ENVK","default":"d2"},
 {"env":"DEFK","default":"d3"},{"env":"BOTHK","default":"d4"}]}]}
J
KN='printf "%s %s %s %s\n" "$(lane_knob t ROWK)" "$(lane_knob t ENVK)" "$(lane_knob t DEFK)" "$(lane_knob t BOTHK)"'
knobs() { LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW=1758300110 ENVK=fromenv BOTHK=fromenv probe "$KN"; }
fixture | jq -c . > "$SC"; rm -f "$EF"; : > "$T/jq-calls"
KA=$(knobs); KAN=$(jqn)
render; : > "$T/jq-calls"
KB=$(knobs); KBN=$(jqn)
[ "$KA" = "fromrow fromenv d3 rowwins" ] && ok || bad "E1 lane_knob on the jq path: '$KA'"
[ "$KB" = "$KA" ] && ok || bad "E1 lane_knob on the env path: '$KB' (jq path '$KA')"
[ "$KAN" -ge 1 ] && [ "$KBN" = 0 ] && ok || bad "E1 lane_knob jq counts: jq path $KAN, env path $KBN (want >=1, 0)"

# ── E2 refresh renders, a new answer re-renders ──────────────────────────────
resp() { printf '{"settings":[{"key":"r.one","value":"%s","actor":"op"},{"key":"r_two","value":"%s","actor":"op"},{"key":"r.seed","value":"s","actor":"registry-seed"}]}' "$1" "$2" > "$T/resp"; }
REF='_jobs_req() { cat "'"$T"'/resp"; }; _lg_settings_refresh; echo "rrc=$?"; _lg_setting_lookup r.one; echo'
RD='_lg_sc_load; printf "%s|%s|%s\n" "$(_lg_setting_lookup r.one)" "$(_lg_setting_lookup r_two)" "$_LG_SFETCHED"'
rm -f "$SC" "$EF" "$H/state/lane-gate/.settings-miss"; resp v1a v1b
out=$(LANE_GATE_NOW=2000 probe "$REF")
[ "$out" = "rrc=0
v1a" ] && ok || bad "E2 first refresh: $out"
[ -f "$EF" ] && ok || bad "E2 the refresh wrote no env file"
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "v1a|v1b|2000" ] && [ "$(jqn)" = 0 ] && ok || bad "E2 v1 read: '$out' with $(jqn) jq (want 0)"
resp v2a v2b
LANE_GATE_NOW=2030 probe "$REF" >/dev/null
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "v1a|v1b|2000" ] && [ "$(jqn)" = 0 ] && ok || bad "E2 inside the TTL nothing changes: '$out' $(jqn) jq"
out=$(LANE_GATE_NOW=2100 probe "$REF")
[ "$out" = "rrc=0
v2a" ] && ok || bad "E2 second refresh: $out"
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "v2a|v2b|2100" ] && [ "$(jqn)" = 0 ] && ok || bad "E2 v2 read: '$out' with $(jqn) jq (want 0)"
jqdump; : > "$T/jq-calls"; ENVD=$(probe "$DUMP")
[ "$ENVD" = "$JQD" ] && [ "$(jqn)" = 0 ] && ok || bad "E2 the re-rendered memo differs from jq's"
grep -q '^\.settings-cache\.env\.' <<<"$(ls -a "$H/state/lane-gate" 2>/dev/null)" && bad "E2 a temp env file was left" || ok

# ── E3 / E6 a file that is not bound is refused ──────────────────────────────
printf '%s' "$(fixture | jq -c .)" > "$SC"   # no trailing newline: the last raw byte is "}"
rm -f "$EF"; jqdump; render; cp "$EF" "$T/good.env"
NB=$(LC_ALL=C; c=$(cat "$SC"); echo "${#c}")
refused() { # <case> — the load ignores $EF: 1 jq, the jq-path memo
  : > "$T/jq-calls"; local d; d=$(probe "$DUMP")
  [ "$d" = "$JQD" ] && [ "$(jqn)" = 1 ] && ok || bad "E3 $1: memo same=$([ "$d" = "$JQD" ] && echo y || echo n), jq=$(jqn) (want y, 1)"
}
: > "$T/jq-calls"; d=$(probe "$DUMP")
[ "$d" = "$JQD" ] && [ "$(jqn)" = 0 ] && ok || bad "E3 control: the good file is not used (jq=$(jqn))"
rm -f "$EF"; refused "no env file"
sed '1s/ v1 / v0 /' "$T/good.env" > "$EF"; refused "header v0"
sed '1s/ v1 / v2 /' "$T/good.env" > "$EF"; refused "header v2"
sed "1s/ $NB\$/ $((NB-1))/" "$T/good.env" > "$EF"; refused "length one short"
sed "1s/ $NB\$/ $((NB+1))/" "$T/good.env" > "$EF"; refused "length one long"
sed '2s/}$/]/' "$T/good.env" > "$EF"; refused "last raw byte changed"
cmp -s "$EF" "$T/good.env" && bad "E3 the last-byte mutant is the good file" || ok
head -c -8 "$T/good.env" > "$EF"; refused "trailer cut (E6)"
head -c "$(( $(head -1 "$T/good.env" | wc -c) + NB / 2 ))" "$T/good.env" > "$EF"; refused "cut inside the raw (E6)"
printf '' > "$EF"; refused "empty file"

# ── E5 LANE_GATE_SC_ENV=0 ────────────────────────────────────────────────────
cp "$T/good.env" "$EF"
: > "$T/jq-calls"; d=$(LANE_GATE_SC_ENV=0 probe "$DUMP")
[ "$d" = "$JQD" ] && [ "$(jqn)" = 1 ] && ok || bad "E5 LANE_GATE_SC_ENV=0 used the env file (jq=$(jqn))"
rm -f "$SC" "$EF" "$H/state/lane-gate/.settings-miss"; resp off1 off2
out=$(LANE_GATE_SC_ENV=0 LANE_GATE_NOW=3000 probe "$REF")
[ "$out" = "rrc=0
off1" ] && [ ! -e "$EF" ] && ok || bad "E5 LANE_GATE_SC_ENV=0 refresh: '$out', env file $([ -e "$EF" ] && echo written || echo absent)"

# ── E7 _setting_cache_stale after a render ───────────────────────────────────
rm -f "$SC" "$EF" "$H/state/lane-gate/.settings-miss"; resp st1 st2
LANE_GATE_NOW=4000 probe "$REF" >/dev/null
[ -f "$EF" ] && ok || bad "E7 setup: no env file"
JOBS_HARNESS="$H" bash -c '. "$1/bin/lib/jobs/settings.sh"; _setting_cache_stale' _ "$DIR"
[ "$(jq -r .fetched_at "$SC")" = 0 ] && ok || bad "E7 setup: _setting_cache_stale did not zero fetched_at"
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "st1|st2|0" ] && [ "$(jqn)" = 1 ] && ok || bad "E7 after the stale rewrite: '$out' with $(jqn) jq (want st1|st2|0, 1)"

# ── E8 the env write fails ───────────────────────────────────────────────────
FB="$T/failbin"; mkdir -p "$FB"; cp "$SHIM/jq" "$FB/jq"
cat > "$FB/mktemp" <<SH
#!/bin/bash
case "\$*" in *.settings-cache.env.*) exit 1 ;; esac
exec $(command -v mktemp) "\$@"
SH
chmod +x "$FB/mktemp"
rm -f "$SC" "$EF" "$H/state/lane-gate/.settings-miss"; resp mk1 mk2
out=$(PROBE_PATH="$FB" LANE_GATE_NOW=5000 probe "$REF")
[ "$out" = "rrc=0
mk1" ] && [ ! -e "$EF" ] && ok || bad "E8 mktemp fails: '$out', env $([ -e "$EF" ] && echo written || echo absent)"
rm -f "$FB/mktemp"
cat > "$FB/mv" <<SH
#!/bin/bash
case "\${@: -1}" in *settings-cache.env) exit 1 ;; esac
exec $(command -v mv) "\$@"
SH
chmod +x "$FB/mv"
rm -f "$SC" "$EF" "$H/state/lane-gate/.settings-miss"; resp mv1 mv2
out=$(PROBE_PATH="$FB" LANE_GATE_NOW=5100 probe "$REF")
[ "$out" = "rrc=0
mv1" ] && [ ! -e "$EF" ] && ok || bad "E8 mv fails: '$out', env $([ -e "$EF" ] && echo written || echo absent)"
[ "$(jq -r '.values["r.one"]' "$SC")" = mv1 ] && ok || bad "E8 the cache itself was not written"
grep -q '^\.settings-cache\.env\.' <<<"$(ls -a "$H/state/lane-gate" 2>/dev/null)" && bad "E8 a temp env file was left: $(ls -a "$H/state/lane-gate")" || ok
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "mv1|mv2|5100" ] && [ "$(jqn)" = 1 ] && ok || bad "E8 read after a failed render: '$out' $(jqn) jq"
scratch_rm "$FB"
# state/lane-gate is a file, so the env dir cannot be made.
mv "$H/state/lane-gate" "$T/lg-saved"; printf 'x\n' > "$H/state/lane-gate"
rm -f "$SC"; resp dir1 dir2
out=$(LANE_GATE_NOW=5200 probe "$REF")
[ "$out" = "rrc=0
dir1" ] && [ "$(cat "$H/state/lane-gate")" = x ] && ok || bad "E8 state/lane-gate is a file: '$out'"
: > "$T/jq-calls"; out=$(probe "$RD")
[ "$out" = "dir1|dir2|5200" ] && [ "$(jqn)" = 1 ] && ok || bad "E8 read with no env dir: '$out' $(jqn) jq"
rm -f "$H/state/lane-gate"; mv "$T/lg-saved" "$H/state/lane-gate"

# ── E9 concurrent writer and readers ─────────────────────────────────────────
jq -nc '{fetched_at: 7001, values: {"w.v": "one", "w_x": "1"}}' > "$T/v1.json"
jq -nc '{fetched_at: 7002, values: {"w.v": "two", "w-y": "2", "w.z": "z"}}' > "$T/v2.json"
rm -f "$EF"; cp "$T/v1.json" "$SC"; jqdump; D1=$JQD
cp "$T/v2.json" "$SC"; jqdump; D2=$JQD
[ "$D1" != "$D2" ] && ok || bad "E9 setup: the two memos are equal"
WRITER='i=0; while [ $i -lt 200 ]; do
  for v in 1 2; do t=$(mktemp "$HARNESS/state/.settings-cache.XXXXXX"); cp "'"$T"'/v$v.json" "$t"; mv "$t" "$HARNESS/state/settings-cache.json"
    _LG_SC_RENDER=1 _lg_sc_load; done; i=$((i+1)); done'
probe "$WRITER" >/dev/null & WP=$!
BADN=0; SEEN1=0; SEEN2=0; i=0
while [ $i -lt 200 ]; do
  d=$(probe "$DUMP")
  if [ "$d" = "$D1" ]; then SEEN1=$((SEEN1+1)); elif [ "$d" = "$D2" ]; then SEEN2=$((SEEN2+1))
  else BADN=$((BADN+1)); [ "$BADN" = 1 ] && printf 'E9 first odd memo:\n%s\n' "$d"; fi
  i=$((i+1))
done
wait "$WP"
[ "$BADN" = 0 ] && ok || bad "E9 $BADN of 200 loads saw a memo that is neither v1 nor v2 (v1 $SEEN1, v2 $SEEN2)"
echo "E9: 200 loads during 400 re-renders: v1 $SEEN1, v2 $SEEN2, other $BADN"

# ── E10 the backup manifest ignores the env file ─────────────────────────────
MF="$T/manifest.sh"
{ printf 'LOWPRI=(); HENV=%q; OBN=""; CHECKOUT=%q\n' "$T/no-env" "$T/no-checkout"
  sed -n '/^bk_lines() {/,/^}/p; /^bk_manifest() {/,/^}/p' "$DIR/bin/state-backup.sh"
  printf 'bk_manifest\n'; } > "$MF"
grep -q '^bk_manifest() {' "$MF" && ok || bad "E10 bk_manifest not found in bin/state-backup.sh"
rm -f "$EF"; cp "$T/v1.json" "$SC"; render
M1=$(H="$H" bash "$MF")
head -c 40 "$T/good.env" > "$EF"; printf 'more bytes\n' >> "$EF"; touch -d '@1758000000' "$EF"
M2=$(H="$H" bash "$MF")
[ -n "$M1" ] && [ "$M1" = "$M2" ] && ok || bad "E10 the manifest moved when only the env file changed ($M1 -> $M2)"
printf 'x\n' > "$H/state/other-input"; M3=$(H="$H" bash "$MF"); rm -f "$H/state/other-input"
[ "$M3" != "$M1" ] && ok || bad "E10 control: a real input change did not move the manifest"

echo "settings-env bh-7717: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
