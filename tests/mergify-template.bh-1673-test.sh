#!/bin/bash
# tests/mergify-template.bh-1673-test.sh — bin/mergify-template.sh renders,
# compares and checks a repo's .mergify.yml from config/mergify/template.yml +
# config/mergify/repos/<repo>.conf (BH-1673, child BH-1698).
#
# Every case goes through the real CLI ($DIR/bin/mergify-template.sh). Values
# are read out of the PARSED YAML (python3 + PyYAML -> json -> jq, the division
# tests/hotfix-mergify-template-test.sh uses), never grepped from the text.
#
# Without PyYAML the render / marker / bad-conf / fixture-byte sections still
# run, and each YAML-dependent section prints `SKIP (no PyYAML): <section>` on
# its own line. A green run with a SKIP line has not proved compare or --check.
#
# Run from anywhere: tests/mergify-template.bh-1673-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$DIR/bin/mergify-template.sh"
REPOS="$DIR/config/mergify/repos"
TS="$REPOS/project-5.conf"
BHC="$REPOS/cromford.conf"
FIXTURE="$DIR/tests/fixtures/mergify/project-5.mergify.yml"
# TSB: project-5.conf with its queue-tuning keys stripped (BH-3439 set them).
# The cases that APPEND a tuning key to a conf start from it, so each append
# tests the error or default it names, not a `duplicate` key.
TUNED='^(max_parallel_checks|batch_size|max_checks_retries)='
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { echo "SKIP (no PyYAML): $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
HAVE_YAML=0; python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=1

tojson() { # tojson <yaml-file> -> json on stdout, rc 1 when it will not parse
  python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1" 2>/dev/null
}
# want_rc <label> <rc> <cmd...> — run the CLI, keep stdout/stderr in $T/out,$T/err
want_rc() {
  local label=$1 want=$2; shift 2
  "$@" >"$T/out" 2>"$T/err"; local rc=$?
  if [ "$rc" = "$want" ]; then ok
  else bad "$label: rc $rc (want $want) stdout: $(head -c 300 "$T/out") stderr: $(head -c 300 "$T/err")"; fi
}
# the body of a yaml below its leading comment block (the fixture's header)
body() { sed -n '/^merge_queue:/,$p' "$1"; }
# the first fenced yaml block in docs/MERGIFY.md that declares queue_rules:
extract_doc() {
  awk '
    /^```yaml/ { inb=1; buf=""; next }
    inb && /^```/ { if (buf ~ /queue_rules:/) { printf "%s", buf; exit } inb=0; buf=""; next }
    inb { buf = buf $0 "\n" }
  ' "$DIR/docs/MERGIFY.md"
}
# default_batch <in> <out> <n> — the DEFAULT queue's batch_size set to n, only there
default_batch() {
  awk -v n="$3" '/- name: default/ {d=1} /- name: hotfix/ {d=0}
    d && !done && /^ *batch_size: / { sub(/batch_size: .*/, "batch_size: " n); done=1 } { print }' "$1" > "$2"
}

# ---------------------------------------------------------------------------
# A1 / A6 / render bytes: no PyYAML needed
# ---------------------------------------------------------------------------
TSB="$T/ts-base.conf"
grep -Ev "$TUNED" "$TS" > "$TSB"
grep -qE "$TUNED" "$TSB" && bad "TSB still sets a tuning key" || ok
n=0
for c in "$REPOS"/*.conf; do
  [ -f "$c" ] || continue; n=$((n+1)); b=$(basename "$c" .conf)
  want_rc "A1 render $b" 0 "$BIN" render "$c"
  cp "$T/out" "$T/$b.yml"
  [ -s "$T/$b.yml" ] && ok || bad "A1 render $b: empty output"
  grep -q '@@' "$T/$b.yml" && bad "A1 render $b: a token survived: $(grep -m1 '@@' "$T/$b.yml")" || ok
done
[ "$n" -ge 2 ] && ok || bad "config/mergify/repos/*.conf matched $n files (want >=2)"

# A6: a bad conf is rc 2 naming the line, with NOTHING on stdout.
bad_conf() { # bad_conf <label> <conf-file> <stderr-regex>
  "$BIN" render "$2" >"$T/out" 2>"$T/err"; local rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -Eq "$3" "$T/err"; then ok
  else bad "A6 $1: rc $rc (want 2), stdout bytes $(wc -c <"$T/out"), stderr: $(head -c 300 "$T/err")"; fi
}
for extra in 'max_parallel_checks=9' 'colour=red' 'batch_size=abc' 'batch_size=2' 'batch_size=0' 'merge_method=fast' 'max_checks_retries=3' 'max_checks_retries=x'; do
  { cat "$TSB"; [ "$extra" = batch_size=2 ] && echo 'batch_size=3'; echo "$extra"; } > "$T/a6.conf"
  bad_conf "$extra" "$T/a6.conf" ':[0-9]+:'
done
{ cat "$TSB"; echo 'max_parallel_checks=9'; } > "$T/a6.conf"; "$BIN" render "$T/a6.conf" >/dev/null 2>"$T/err"
grep -q 'max_parallel_checks 9 > 8' "$T/err" && ok || bad "A6 max_parallel_checks=9: stderr does not name the cap: $(cat "$T/err")"
{ cat "$TSB"; echo 'max_checks_retries=3'; } > "$T/a6.conf"; "$BIN" render "$T/a6.conf" >/dev/null 2>"$T/err"
grep -q 'max_checks_retries 3 is outside 0..2' "$T/err" && ok || bad "A6 max_checks_retries=3: stderr does not name the range: $(cat "$T/err")"

# A10 (bytes): max_checks_retries defaults to 0, so a conf without the key
# ($TSB) renders byte-identically to the same conf saying 0 ...
want_rc "A10 render ts-base.conf" 0 "$BIN" render "$TSB"
cp "$T/out" "$T/ts-base.yml"
{ cat "$TSB"; echo 'max_checks_retries=0'; } > "$T/a10-0.conf"
want_rc "A10 render ts-base.conf + max_checks_retries=0" 0 "$BIN" render "$T/a10-0.conf"
cmp -s "$T/out" "$T/ts-base.yml" && ok || bad "A10 a conf without max_checks_retries is not byte-identical to one saying 0: $(diff "$T/ts-base.yml" "$T/out" | head -5 | tr '\n' ' ')"
# ... and 1 changes exactly one line: the default queue's max_checks_retries.
{ cat "$TSB"; echo 'max_checks_retries=1'; } > "$T/a10-1.conf"
want_rc "A10 render ts-base.conf + max_checks_retries=1" 0 "$BIN" render "$T/a10-1.conf"
cp "$T/out" "$T/a10-1.yml"
d=$(diff "$T/ts-base.yml" "$T/a10-1.yml" | grep '^[<>]' | tr '\n' '|')
[ "$d" = "<     max_checks_retries: 0|>     max_checks_retries: 1|" ] && ok || bad "A10 max_checks_retries=1 must change only the default queue's line (diff: $d)"
grep -v '^check=' "$TS" > "$T/nocheck.conf"
bad_conf "no check= line" "$T/nocheck.conf" 'no check= line'
grep -v '^slug=' "$TS" > "$T/noslug.conf"
bad_conf "no slug= line" "$T/noslug.conf" 'no slug= line'
bad_conf "unreadable conf" "$T/does-not-exist.conf" 'does-not-exist'

# A8 (bytes): the fixture below its header IS the render of project-5.conf.
if cmp -s <(body "$FIXTURE") "$T/project-5.yml"; then ok
else bad "A8 fixture body differs from render project-5.conf: $(diff <(body "$FIXTURE") "$T/project-5.yml" | head -5 | tr '\n' ' ')"; fi
[ "$(head -c1 "$FIXTURE")" = '#' ] && ok || bad "A8 the fixture lost its header comment"

# marker: shell only, no PyYAML.
cp "$DIR/.mergify.yml" "$T/marked.yml"; echo '# harness-mergify: override kept by hand for BH test' >> "$T/marked.yml"
want_rc "A4 marker with a reason" 0 "$BIN" marker "$T/marked.yml"
[ "$(cat "$T/out")" = "kept by hand for BH test" ] && ok || bad "A4 marker reason: got '$(cat "$T/out")'"
for m in '# harness-mergify: override' '# harness-mergify: override   '; do
  { cat "$T/project-5.yml"; printf '%s\n' "$m"; } > "$T/blank.yml"
  want_rc "A5 marker '$m' (blank reason)" 1 "$BIN" marker "$T/blank.yml"
done
want_rc "A5 no marker" 1 "$BIN" marker "$T/project-5.yml"
want_rc "A5 marker on a missing file" 1 "$BIN" marker "$T/nope.yml"

# No PyYAML: a yaml module that refuses to import. compare is rc 3, never 0.
mkdir -p "$T/noyaml"; echo 'raise ImportError("stubbed out by the test")' > "$T/noyaml/yaml.py"
want_rc "compare without PyYAML" 3 env PYTHONPATH="$T/noyaml" "$BIN" compare "$TS" "$T/project-5.yml"
want_rc "--check without PyYAML" 1 env PYTHONPATH="$T/noyaml" "$BIN" --check
want_rc "render without PyYAML" 0 env PYTHONPATH="$T/noyaml" "$BIN" render "$TS"

if [ "$HAVE_YAML" != 1 ]; then
  for s in A1-parse A1b A2 A3 A10-parse A11 A4-compare A5-compare A7 A8-compare A9; do skip "$s"; done
  echo "mergify-template.bh-1673-test: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# ---------------------------------------------------------------------------
# A1 / A2 / A3 / A7: the parsed renders
# ---------------------------------------------------------------------------
LABEL=$( unset MC_MERGIFY_LABEL; mkdir -p "$T/h"; export HARNESS_ROOT="$T/h"; . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; printf %s "${MC_MERGIFY_LABEL:-}" )
[ -n "$LABEL" ] && ok || bad "A7 MC_MERGIFY_LABEL is empty after sourcing bin/lib/merge-conductor-lib.sh"
for c in "$REPOS"/*.conf; do
  b=$(basename "$c" .conf)
  if ! tojson "$T/$b.yml" > "$T/$b.json"; then bad "A1 render $b does not parse"; continue; fi
  jq -e '[.queue_rules[].name] as $n | ($n|index("hotfix")) != null and ($n|index("default")) != null and ($n|index("hotfix")) < ($n|index("default"))' "$T/$b.json" >/dev/null \
    && ok || bad "A1 $b: hotfix must come before default (got $(jq -c '[.queue_rules[]?.name]' "$T/$b.json"))"
  MERGIFY_FIXTURE="$T/$b.yml" bash "$DIR/tests/hotfix-mergify-template-test.sh" >"$T/a2.out" 2>&1 \
    && ok || bad "A2 $b render fails the hotfix suite: $(grep FAIL "$T/a2.out" | head -3 | tr '\n' ' ')"
  jq -e '[paths | .[-1]] | index("speculative_checks") == null' "$T/$b.json" >/dev/null \
    && ok || bad "A7 $b render carries speculative_checks"
  jq -e --arg l "label=$LABEL" '[.pull_request_rules[].conditions[] | select(startswith("label=merge"))] as $x | ($x|length) == (.pull_request_rules|length) and ($x|length) >= 2 and all($x[]; . == $l)' "$T/$b.json" >/dev/null \
    && ok || bad "A7 $b: pull_request_rules label must be label=$LABEL (got $(jq -c '[.pull_request_rules[].conditions[]]' "$T/$b.json"))"
done
extract_doc > "$T/doc.yml"
tojson "$T/doc.yml" > "$T/doc.json" && jq -e '[paths | .[-1]] | index("speculative_checks") == null' "$T/doc.json" >/dev/null \
  && ok || bad "A7 the docs/MERGIFY.md §2 block carries speculative_checks (or does not parse)"

# A1b: the hotfix queue's values are fixed, whatever the conf says.
for bs in 1 7; do
  { cat "$TSB"; echo "batch_size=$bs"; echo 'batch_max_wait_time=9 min'; } > "$T/a1b.conf"
  "$BIN" render "$T/a1b.conf" > "$T/a1b.yml" 2>"$T/err" && tojson "$T/a1b.yml" > "$T/a1b.json" \
    && jq -e --argjson bs "$bs" '(.queue_rules[]|select(.name=="hotfix")) as $h | (.queue_rules[]|select(.name=="default")) as $d
         | $h.batch_size == 1 and $h.batch_max_wait_time == "0 s" and $h.max_checks_retries == 0
           and $d.batch_size == $bs and $d.batch_max_wait_time == "9 min"' "$T/a1b.json" >/dev/null \
    && ok || bad "A1b batch_size=$bs: hotfix must stay 1 / 0 s / 0 and default must take the conf (got $(jq -c '.queue_rules' "$T/a1b.json" 2>/dev/null))"
done

# A10 (parsed): max_checks_retries=1 lands on the DEFAULT queue only.
tojson "$T/a10-1.yml" > "$T/a10-1.json" \
  && jq -e '(.queue_rules[]|select(.name=="hotfix").max_checks_retries) == 0 and (.queue_rules[]|select(.name=="default").max_checks_retries) == 1' "$T/a10-1.json" >/dev/null \
  && ok || bad "A10 max_checks_retries=1: want hotfix 0, default 1 (got $(jq -c '[.queue_rules[]|{name,max_checks_retries}]' "$T/a10-1.json" 2>/dev/null))"

# A11: cromford's values. Batches of 8, 3 min (the operator, 2026-09-24); 0 retries
# since the corpus runs only in the batch (2026-09-24, PR #2220): a retry costs
# a full corpus run. 3 parallel (the operator, 2026-10-12, BH-6337; was 8 from
# 2026-09-28): a red or dequeued batch restarts every batch above it, a policy
# change, not a weakening. Batches of 6, 2 min (the operator, 2026-10-22, BH-8047).
# 1 parallel (the operator, 2026-10-22, BH-8085, CI cost) until the red-batch rate is under 15%.
# Batches of 3 (the operator, 2026-10-24, BH-8267, CI cost) until the 7-day red-batch
# rate is under 15 percent for a week, then 6 again.
jq -e '.merge_queue.max_parallel_checks == 1
       and (.queue_rules[]|select(.name=="default") | .batch_size == 3 and .batch_max_wait_time == "2 min" and .max_checks_retries == 0 and .checks_timeout == "60 min" and .merge_method == "merge")
       and (.queue_rules[]|select(.name=="hotfix")  | .batch_size == 1 and .batch_max_wait_time == "0 s" and .max_checks_retries == 0)' "$T/cromford.json" >/dev/null \
  && ok || bad "A11 cromford render values (got $(jq -c '{mq:.merge_queue, q:[.queue_rules[]|{name,batch_size,batch_max_wait_time,max_checks_retries}]}' "$T/cromford.json"))"

# A3: project-5's values (BH-3439): 6 in flight, batches of 4, one retry on the
# default queue (what the repo already ran); the hotfix queue stays 1 / 0 retries.
jq -e '.merge_queue.max_parallel_checks == 6
       and (.queue_rules[]|select(.name=="hotfix") | .batch_size == 1 and .max_checks_retries == 0)
       and (.queue_rules[]|select(.name=="default")
       | .batch_size == 4 and .batch_max_wait_time == "3 min" and .checks_timeout == "45 min" and .max_checks_retries == 1
         and .merge_method == "squash" and .merge_conditions == ["#changes-requested-reviews-by=0", "check-success=Build + Unit tests"])' "$T/project-5.json" >/dev/null \
  && ok || bad "A3 project-5 render values (got $(jq -c '{mq:.merge_queue, d:(.queue_rules[]|select(.name=="default"))}' "$T/project-5.json"))"

# A12 (BH-2275): a standing changes-requested review keeps a PR OUT of the
# queue and stops a batch merging it, on EVERY queue rule — the rendered
# template (both repos) and cromford's live .mergify.yml. Mergify reads the
# condition in queue_conditions (a PR with one never enters, and is dequeued if
# one lands) and merge_conditions (a batch holding it cannot merge).
CRC='#changes-requested-reviews-by=0'
for J in "$T/cromford.json" "$T/project-5.json"; do
  jq -e --arg c "$CRC" '[.queue_rules[] | ((.queue_conditions|index($c)) != null) and ((.merge_conditions|index($c)) != null)] | length >= 2 and all' "$J" >/dev/null \
    && ok || bad "A12 $(basename "$J"): every queue rule must carry $CRC in queue_conditions AND merge_conditions (got $(jq -c '[.queue_rules[]|{name,q:.queue_conditions,m:.merge_conditions}]' "$J" 2>/dev/null))"
done
tojson "$DIR/.mergify.yml" > "$T/live.json" \
  && jq -e --arg c "$CRC" '[.queue_rules[] | ([.queue_conditions[], .merge_conditions[]] | map(gsub("\\s";"")) | map(select(. == $c)) | length) == 2] | length >= 2 and all' "$T/live.json" >/dev/null \
  && ok || bad "A12 live .mergify.yml: every queue rule must carry $CRC in both condition lists"

# ---------------------------------------------------------------------------
# A4 / A5: compare
# ---------------------------------------------------------------------------
# The drift value is 5: any value the live default queue does not carry (it
# was 3 until BH-8267 made 3 the live value).
want_rc "A4 compare cromford.conf .mergify.yml" 0 "$BIN" compare "$BHC" "$DIR/.mergify.yml"
default_batch "$DIR/.mergify.yml" "$T/copy.yml" 5
cmp -s "$DIR/.mergify.yml" "$T/copy.yml" && bad "A4 setup: the default batch_size edit changed nothing" || ok
want_rc "A4 compare with default batch_size 5" 1 "$BIN" compare "$BHC" "$T/copy.yml"
grep -q '"batch_size": 5' "$T/out" && ok || bad "A4 drift diff does not show batch_size 5: $(head -c 400 "$T/out")"
grep -q '^+++ ' "$T/out" && ok || bad "A4 drift output is not a unified diff"

TSY="$T/project-5.yml"
same() { # same <label> <file> — compare project-5.conf <file> must be rc 0
  want_rc "A5 $1" 0 "$BIN" compare "$TS" "$2"
}
{ echo '# a comment'; sed 's/^merge_queue:$/merge_queue:  # trailing comment/' "$TSY"; echo '# end'; } > "$T/c.yml"; same "comments" "$T/c.yml"
python3 -c 'import sys,yaml; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])), sort_keys=True, default_flow_style=False), end="")' "$TSY" > "$T/d.yml"
same "safe_dump re-emission (sorted keys, requoted)" "$T/d.yml"
sed 's/base=main/base = main/' "$TSY" > "$T/e.yml"; same "base = main" "$T/e.yml"
sed 's/- "check-success=Build + Unit tests"/- check-success = "Build + Unit tests"/' "$TSY" > "$T/f.yml"
grep -q 'check-success = "Build' "$T/f.yml" && ok || bad "A5 setup: quoted variant not produced"
same "check-success = \"X\"" "$T/f.yml"
printf 'queue_rules: [\n' > "$T/g.yml"; want_rc "A5 unparseable" 3 "$BIN" compare "$TS" "$T/g.yml"
want_rc "A5 missing path" 3 "$BIN" compare "$TS" "$T/missing.yml"
: > "$T/empty.yml"; want_rc "A5 empty file" 3 "$BIN" compare "$TS" "$T/empty.yml"
# adversarial drift: none of these may read as in sync
sed 's/Build + Unit tests/Build + Unit test/' "$TSY" > "$T/h1.yml"; want_rc "A5 check name one char off" 1 "$BIN" compare "$TS" "$T/h1.yml"
python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); d["queue_rules"].reverse(); print(yaml.safe_dump(d), end="")' "$TSY" > "$T/h2.yml"
want_rc "A5 hotfix moved after default" 1 "$BIN" compare "$TS" "$T/h2.yml"
awk '/- name: hotfix/{h=1} /- name: default/{h=0} h && /batch_size: 1/{sub(/1$/,"2")} {print}' "$TSY" > "$T/h3.yml"
want_rc "A5 hotfix batch_size 2" 1 "$BIN" compare "$TS" "$T/h3.yml"
grep -v -- '- -label=fix-main-red' "$TSY" > "$T/h4.yml"; want_rc "A5 dropped -label=fix-main-red" 1 "$BIN" compare "$TS" "$T/h4.yml"
{ cat "$TSB"; echo 'max_parallel_checks=9'; } > "$T/bad.conf"
want_rc "compare with a bad conf" 3 "$BIN" compare "$T/bad.conf" "$TSY"

# ---------------------------------------------------------------------------
# A8: the §2 block and the fixture compare in sync with project-5.conf
# ---------------------------------------------------------------------------
want_rc "A8 docs/MERGIFY.md §2 block" 0 "$BIN" compare "$TS" "$T/doc.yml"
want_rc "A8 fixture" 0 "$BIN" compare "$TS" "$FIXTURE"

# ---------------------------------------------------------------------------
# A9: --check
# ---------------------------------------------------------------------------
want_rc "A9 --check on the repo" 0 "$BIN" --check
mkrepo() { # mkrepo <dir> — a scratch copy of the CLI, its config and the root yaml
  scratch_rm "$1"; mkdir -p "$1/bin" "$1/config"
  cp "$BIN" "$1/bin/"; cp -r "$DIR/config/mergify" "$1/config/"; cp "$DIR/.mergify.yml" "$1/"
}
mkrepo "$T/r"; want_rc "A9 --check on an untouched scratch copy" 0 "$T/r/bin/mergify-template.sh" --check
default_batch "$DIR/.mergify.yml" "$T/r/.mergify.yml" 5
want_rc "A9 --check with a drifted default batch_size" 1 "$T/r/bin/mergify-template.sh" --check
echo '# harness-mergify: override hand-tuned for the A9 case' >> "$T/r/.mergify.yml"
want_rc "A9 --check with drift plus the marker" 0 "$T/r/bin/mergify-template.sh" --check
grep -q 'hand-tuned for the A9 case' "$T/out" && ok || bad "A9 --check did not print the override reason: $(cat "$T/out")"
mkrepo "$T/r2"; cp "$TSB" "$T/r2/config/mergify/repos/project-5.conf"
echo 'max_parallel_checks=9' >> "$T/r2/config/mergify/repos/project-5.conf"
want_rc "A9 --check with a conf holding max_parallel_checks=9" 1 "$T/r2/bin/mergify-template.sh" --check
mkrepo "$T/r3"; rm "$T/r3/config/mergify/repos/"*.conf
want_rc "A9 --check with zero confs" 1 "$T/r3/bin/mergify-template.sh" --check

echo "mergify-template.bh-1673-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
