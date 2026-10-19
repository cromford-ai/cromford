#!/bin/bash
# tests/settings-load-cost.bh-7494-test.sh — BH-7494: the settings-cache loader
# (_lg_sc_load in bin/lib/lane-gate.sh) does a bounded amount of shell work, so
# an empty project's fly-pool tick is not CPU-bound in bash.
#
# Before: ~12 shell commands per cache key (three `read -d ''`, _lg_sc_name,
# two printf -v, two appends to one growing `names` string). On a 3,000-key
# cache that is 36,000+ commands and quadratic copying. After: one jq and one
# eval, so the command count does not depend on the key count.
#
# The bound is a COMMAND COUNT (a DEBUG trap with functrace), never a clock.
#
#   L1 one load of a 3,000-key cache runs at most 200 shell commands.
#   L2 a repeat load of the unchanged file runs at most 60 commands and no jq.
#   L3 a load is exactly 1 jq; 60 reads after it add no jq and at most 1,500
#      commands, in the shell and in $(…) subshells.
#   L4 the memo is unchanged: odd bytes round-trip, nothing in a value runs,
#      false/null rows are present with no value, JSON values are tojson, a key
#      the memo cannot hold is counted in _LG_SK_N and not memoised.
#   L5 corrupt file, non-numeric fetched_at, missing values: fetched 0, no keys.
#   L6 a rewritten file reloads (one more jq) and the old keys are gone.
#
# Run: bash tests/settings-load-cost.bh-7494-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
H="$T/h"; SHIM="$T/shim"; SC="$H/state/settings-cache.json"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$SHIM"
printf '#!/bin/bash\necho x >> "%s/jq-calls"\nexec %s "$@"\n' "$T" "$(command -v jq)" > "$SHIM/jq"
chmod +x "$SHIM/jq"
jqn() { if [ -f "$T/jq-calls" ]; then wc -l < "$T/jq-calls" | tr -d ' '; else echo 0; fi; }

# probe <script> — run <script> in a fresh bash that sources the real library
# with the jq-counting shim first on PATH; prints what the script prints.
probe() {
  PATH="$SHIM:$PATH" HARNESS="$H" bash -c '. "$1"; eval "$2"' _ "$DIR/bin/lib/lane-gate.sh" "$1" 2>&1
}

# A 3,000-key cache: 3,000 memoisable keys, some false/null, long enough to
# make a per-key cost visible.
jq -n '{fetched_at: 1758300000,
        values: ([range(0;3000) | {key: ("lane.fly-pool.knob_\(.)_x.y-z"),
                                   value: (if . % 7 == 0 then false elif . % 11 == 0 then null elif . % 5 == 0 then {a:.} else "v \(.)" end)}]
                 | from_entries)}' > "$SC"

CNT='_C=0; trap '"'"'_C=$((_C+1))'"'"' DEBUG; set -T'

: > "$T/jq-calls"
out=$(probe "$CNT; _lg_sc_load; trap - DEBUG; echo \"cmds=\$_C n=\$_LG_SK_N\"")
cmds=${out##*cmds=}; cmds=${cmds%% *}
case "$cmds" in ''|*[!0-9]*) bad "L1 no command count: $out" ;;
  *) if [ "$cmds" -le 200 ]; then ok; else bad "L1 one load ran $cmds commands (bound 200)"; fi ;;
esac
case "$out" in *"n=3000"*) ok ;; *) bad "L1 _LG_SK_N is not 3000: $out" ;; esac

: > "$T/jq-calls"
out=$(probe "_lg_sc_load; $CNT; _lg_sc_load; _lg_sc_load; trap - DEBUG; echo \"cmds=\$_C\"")
cmds=${out##*cmds=}
case "$cmds" in ''|*[!0-9]*) bad "L2 no command count: $out" ;;
  *) if [ "$cmds" -le 60 ]; then ok; else bad "L2 two repeat loads ran $cmds commands (bound 60)"; fi ;;
esac
[ "$(jqn)" = 1 ] && ok || bad "L2 expected 1 jq for load + repeats, saw $(jqn)"

: > "$T/jq-calls"
out=$(probe "_lg_sc_load; echo J=\$(wc -l < $T/jq-calls); $CNT
  i=0; while [ \$i -lt 60 ]; do
    v=\$(_lg_setting_lookup 'lane.fly-pool.knob_1_x.y-z'); _lg_sc_has 'lane.fly-pool.knob_2_x.y-z'
    i=\$((i+1))
  done; trap - DEBUG; echo \"cmds=\$_C\"; echo J2=\$(wc -l < $T/jq-calls)")
cmds=${out##*cmds=}; cmds=${cmds%%$'\n'*}
case "$cmds" in ''|*[!0-9]*) bad "L3 no command count: $out" ;;
  *) if [ "$cmds" -le 1500 ]; then ok; else bad "L3 60 reads ran $cmds commands (bound 1500)"; fi ;;
esac
j1=$(printf '%s' "$out" | sed -n 's/^J=[ ]*//p'); j2=$(printf '%s' "$out" | sed -n 's/^J2=[ ]*//p')
[ "$j1" = 1 ] && ok || bad "L3 load used $j1 jq, expected 1"
[ "$j2" = 1 ] && ok || bad "L3 reads added jq: $j1 -> $j2"

# L4: the memo, byte for byte.
rm -f "$T/pwn"
jq -n --arg pwn "$T/pwn" '{fetched_at: 1758300123,
  values: {
    "k.spaces": "a  b",
    "k.bslash": "a\\b\\n",
    "k.pipe": "a|b",
    "k.squote": "it'"'"'s",
    "k.cmd": ("$(touch " + $pwn + ")`touch " + $pwn + "`"),
    "k.nl": "line1\nline2",
    "k.num": 7,
    "k.obj": {"a":[1,2]},
    "k.false": false,
    "k.null": null,
    "k.empty": "",
    "k_us-dash.dot": "enc",
    "k_d": "plain-d",
    "has space": "unmemoised",
    "": "emptykey"}}' > "$SC"
out=$(probe '
  _lg_sc_load
  g() { _lg_sc_name "$1" || { echo "$1=NONAME"; return; }
        local s="_LG_SK_$_LG_ENC" v="_LG_SV_$_LG_ENC"
        printf "%s=%s|%s\n" "$1" "${!s-unset}" "${!v-unset}"; }
  for k in k.spaces k.bslash k.pipe k.squote k.cmd k.nl k.num k.obj k.false k.null k.empty k_us-dash.dot k_d "has space"; do g "$k"; done
  echo "N=$_LG_SK_N F=$_LG_SFETCHED"')
want='k.spaces=1|a  b
k.bslash=1|a\b\n
k.pipe=1|a|b
k.squote=1|it'"'"'s
k.cmd=1|$(touch '"$T"'/pwn)`touch '"$T"'/pwn`
k.nl=1|line1
line2
k.num=1|7
k.obj=1|{"a":[1,2]}
k.false=1|unset
k.null=1|unset
k.empty=1|
k_us-dash.dot=1|enc
k_d=1|plain-d
has space=NONAME
N=14 F=1758300123'
[ "$out" = "$want" ] && ok || { bad "L4 memo differs"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$out") | head -20; }
[ ! -e "$T/pwn" ] && ok || bad "L4 a value was executed"
out=$(probe '_lg_sc_load; _lg_sc_has "has space" && echo has; _lg_sc_has k_d && echo hasd; _lg_sc_has nope || echo none')
[ "$out" = "has
hasd
none" ] && ok || bad "L4 _lg_sc_has answers: $out"

# L5: unreadable shapes load as fetched 0, no keys.
for body in 'not json' '{"fetched_at":"soon","values":{"a":"1"}}' '{"fetched_at":5}' '[]'; do
  printf '%s' "$body" > "$SC"
  out=$(probe '_lg_sc_load; echo "rc=$? F=$_LG_SFETCHED N=$_LG_SK_N"')
  case "$body" in
    '{"fetched_at":"soon"'*) want='rc=0 F=0 N=1' ;;
    '{"fetched_at":5}') want='rc=0 F=5 N=0' ;;
    *) want='rc=0 F=0 N=0' ;;
  esac
  [ "$out" = "$want" ] && ok || bad "L5 '$body' -> $out (want $want)"
done

# L6: a rewritten file reloads.
jq -n '{fetched_at: 1, values: {"a.one": "1"}}' > "$SC"
: > "$T/jq-calls"
out=$(probe '
  _lg_sc_load; a=$(_lg_setting_lookup a.one)
  printf "%s" "{\"fetched_at\":2,\"values\":{\"b.two\":\"2\"}}" > "$HARNESS/state/settings-cache.json"
  _lg_setting_lookup a.one >/dev/null && echo "a-still-there"
  b=$(_lg_setting_lookup b.two); echo "a=$a b=$b F=$_LG_SFETCHED"')
[ "$out" = "a=1 b=2 F=2" ] && ok || bad "L6 reload: $out"
[ "$(jqn)" = 2 ] && ok || bad "L6 expected 2 jq (two file states), saw $(jqn)"

echo "settings-load-cost bh-7494: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
