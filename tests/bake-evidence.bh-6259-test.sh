#!/bin/bash
# tests/bake-evidence.bh-6259-test.sh — BH-6259 slice C0: the hub's bake
# evidence reaches a cromford pool build.
#   E1-E7  bin/bake-evidence.sh: line selection, per-pool cap, none, bad
#          arguments, byte cap, capture step timings without the tail/secrets;
#   R1-R6  the `# >>> bake-evidence relay` block of bin/fly-pool.sh and its
#          call in the dispatch block;
#   P1     prompts/cromford.md points the planner at the digest;
#   N1     the bake timeout stays 1800 s.
#
# Run from anywhere: tests/bake-evidence.bh-6259-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

EV="$DIR/bin/bake-evidence.sh"
[ -f "$EV" ] || bad "bin/bake-evidence.sh is missing"

# Fixture lines in the shape bake_one writes: "$(STAMP) pool <P>: ...".
phase() { # phase <hh:mm> <pool> <build-s>
  printf '2026-10-12 %s:00Z pool %s: bake phases build=%ss push=- record=- total=%ss rc=124\n' "$1" "$2" "$3" "$3"
}
fresh() { rm -rf "$T/h"; mkdir -p "$T/h/logs"; }
run() { HARNESS="$T/h" bash "$EV" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }

# --- E1: three pools, four lines each, all kept in time order -------------
fresh
for i in 1 2 3 4; do
  phase "0$i:10" project-3 "17${i}0" >> "$T/h/logs/fleet-propagate.log"
  phase "0$i:20" project-2 "16${i}0" >> "$T/h/logs/fleet-propagate.log"
  phase "0$i:30" project-1 "15${i}0" >> "$T/h/logs/fleet-propagate.log"
done
run
[ "$(rc)" = 0 ] && ok || bad "E1 rc $(rc), want 0"
sed -n '/^## bake phases/,/^## captures/p' "$T/out" | grep -E ': bake phases ' > "$T/got"
cmp -s "$T/got" "$T/h/logs/fleet-propagate.log" && ok || bad "E1 the 12 phase lines are not all there in time order"
grep -qE '^## bake phases \(last 10 per pool\)$' "$T/out" && ok || bad "E1 no '## bake phases (last 10 per pool)' heading"

# --- E2: kept / not kept, across both log files ---------------------------
fresh
cat > "$T/h/logs/fleet-propagate.log" <<'EOF'
2026-10-12 08:25:00Z pool project-3: bake phases build=1790s push=- record=- total=1800s rc=124
2026-10-12 08:25:01Z pool project-1: outer timeout hit in the build phase (1800s build limit, +300s push grace)
2026-10-12 08:26:00Z pool project-3: a bake of this pool is already running — busy, marked dirty at abc1234
2026-10-12 08:27:00Z project-3: warm layer cold (last ok bake 2026-10-11) — serial lane
2026-10-12 08:28:00Z project-3: image 12m old, under 30m — debounced
2026-10-12 08:29:00Z pool project-3: warm build timed out — image shipped cold, see logs/fly-image-build/project-3-abc1234.log
EOF
cat > "$T/h/logs/fleet-propagate-cron.log" <<'EOF'
2026-10-12 08:25:00Z pool project-3: bake phases build=1790s push=- record=- total=1800s rc=124
2026-10-12 09:37:00Z pool project-2: bake ran 1850s, past the 1800s build limit, finished in its push grace
EOF
run
[ "$(rc)" = 0 ] && ok || bad "E2 rc $(rc), want 0"
for k in 'pool project-3: bake phases build=1790s' 'pool project-1: outer timeout hit' 'pool project-2: bake ran 1850s, past'; do
  grep -qF "$k" "$T/out" && ok || bad "E2 kept line missing: $k"
done
for n in 'already running' 'warm layer cold' 'debounced' 'warm build timed out'; do
  grep -qF "$n" "$T/out" && bad "E2 negative line passed: $n" || ok
done
[ "$(grep -cF 'bake phases build=1790s' "$T/out")" = 1 ] && ok || bad "E2 the line in both logs is not printed once"
grep -qE '^# bake evidence \(BH-6259\) .*sources=.*fleet-propagate\.log.*fleet-propagate-cron\.log' "$T/out" \
  && ok || bad "E2 header does not name both sources"

# --- E3: 12 lines for one pool, --lines 10 keeps the last 10 --------------
fresh
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do phase "$i:00" project-3 "10$i" >> "$T/h/logs/fleet-propagate.log"; done
phase "05:30" project-1 1500 >> "$T/h/logs/fleet-propagate.log"
run --lines 10
[ "$(rc)" = 0 ] && ok || bad "E3 rc $(rc), want 0"
[ "$(grep -c 'pool project-3: bake phases' "$T/out")" = 10 ] && ok || bad "E3 project-3 lines: $(grep -c 'pool project-3: bake phases' "$T/out"), want 10"
grep -qF 'build=1001s' "$T/out" && bad "E3 line 1 survived the cap" || ok
grep -qF 'build=1002s' "$T/out" && bad "E3 line 2 survived the cap" || ok
grep -qF 'build=1003s' "$T/out" && ok || bad "E3 line 3 dropped"
grep -qF 'build=1012s' "$T/out" && ok || bad "E3 line 12 dropped"
grep -qF 'pool project-1: bake phases build=1500s' "$T/out" && ok || bad "E3 another pool lost its line to project-3' cap"
run --lines 3
[ "$(grep -c 'pool project-3: bake phases' "$T/out")" = 3 ] && ok || bad "E3 --lines 3 kept $(grep -c 'pool project-3: bake phases' "$T/out")"

# --- E4: nothing at all -> rc 3 and one `none` line -----------------------
fresh
run
[ "$(rc)" = 3 ] && ok || bad "E4 rc $(rc), want 3"
[ "$(wc -l < "$T/out")" = 1 ] && grep -qE '^# bake evidence \(BH-6259\): none on .+$' "$T/out" && ok || bad "E4 output is not one 'none on <host>' line: $(cat "$T/out")"
# a log with only non-phase lines is also nothing
printf '2026-10-12 08:28:00Z project-3: image 12m old, under 30m — debounced\n' > "$T/h/logs/fleet-propagate.log"
run
[ "$(rc)" = 3 ] && ok || bad "E4 a log of only debounced lines gave rc $(rc), want 3"

# --- E5: bad arguments -> rc 2, nothing on stdout -------------------------
fresh; phase 01:00 project-3 1000 > "$T/h/logs/fleet-propagate.log"
for a in '--lines 0' '--lines x' '--max-bytes -1' '--captures 0' '--lines' '--bogus'; do
  # shellcheck disable=SC2086
  run $a
  [ "$(rc)" = 2 ] && [ ! -s "$T/out" ] && [ -s "$T/err" ] && ok || bad "E5 '$a' gave rc $(rc), stdout $(wc -c < "$T/out") bytes"
done

# --- E6: the byte cap cuts the output and says so -------------------------
fresh
mkdir -p "$T/h/logs/fly-image-build"
for c in 1 2 3 4 5 6; do
  {
    echo "# fleet-propagate bake capture (BH-3463)"
    echo "pool=project-3 sha=abc000$c rc=124 reason=timeout phase=build bake elapsed=1800s phases=build=1800s,push=-,record=-,total=1800s written=2026-10-12 08:25:00Z"
    echo "## step timings"
    for s in $(seq 1 80); do printf '#%d [builder %d/80] RUN npm ci --no-audit --prefer-offline --cache /root/.npm %s\n' "$s" "$s" "$(printf 'x%.0s' $(seq 1 60))"; done
    echo "## last 200 lines"
    echo "tail line"
  } > "$T/h/logs/fly-image-build/project-3-abc000$c.log"
done
run
[ "$(rc)" = 0 ] && ok || bad "E6 rc $(rc), want 0"
TL='# truncated at 24576 bytes'
[ "$(tail -n 1 "$T/out")" = "$TL" ] && ok || bad "E6 last line is not '$TL': $(tail -n 1 "$T/out" | cut -c1-80)"
[ "$(wc -c < "$T/out")" -le $((24576 + ${#TL} + 1)) ] && ok || bad "E6 output is $(wc -c < "$T/out") bytes, past the cap"
run --max-bytes 1000000
[ "$(rc)" = 0 ] && ! grep -q '^# truncated' "$T/out" && ok || bad "E6 an output under the cap says it was truncated"

# --- E7: capture step timings yes, tail and secrets no --------------------
fresh
mkdir -p "$T/h/logs/fly-image-build"
cat > "$T/h/logs/fly-image-build/project-1-def4567.log" <<'EOF'
# fleet-propagate bake capture (BH-3463)
pool=project-1 sha=def4567 rc=124 reason=timeout phase=build bake elapsed=1800s phases=build=1800s,push=-,record=-,total=1800s written=2026-10-12 09:37:00Z
## step timings
#5 [builder 2/9] RUN git clone https://x-access-token:${TOKEN}@github.com/Acme/alpha-os
#7 [builder 4/9] RUN npm ci
#7 DONE 1650.2s
#9 [builder 6/9] RUN git clone https://x-access-token:tok-fixture-leak@github.com/Acme/alpha-os
warm-build: npm ci 1650s ghs_fixtureleak
## last 200 lines
TAIL-ONLY-LINE x-access-token:abc-fixture
TAIL-ONLY-LINE ghs_xyz-fixture
EOF
run
[ "$(rc)" = 0 ] && ok || bad "E7 rc $(rc), want 0 (captures only)"
grep -qE '^## captures \(newest 6, logs/fly-image-build/\)$' "$T/out" && ok || bad "E7 no captures heading"
grep -qxF '### project-1-def4567.log' "$T/out" && ok || bad "E7 no '### <capture>' heading"
grep -qF 'pool=project-1 sha=def4567 rc=124' "$T/out" && ok || bad "E7 the capture header line is missing"
grep -qF '#7 [builder 4/9] RUN npm ci' "$T/out" && grep -qxF '#7 DONE 1650.2s' "$T/out" && ok || bad "E7 step timing lines missing"
grep -qF 'x-access-token:${TOKEN}@' "$T/out" && ok || bad "E7 the literal \${TOKEN} clone line was dropped"
grep -qF 'TAIL-ONLY-LINE' "$T/out" && bad "E7 the '## last 200 lines' tail passed" || ok
grep -qF '## last 200' "$T/out" && bad "E7 the tail heading passed" || ok
grep -qE 'x-access-token:[^$]' "$T/out" && bad "E7 an x-access-token value passed" || ok
grep -qE 'ghs_|ghp_|github_pat_' "$T/out" && bad "E7 a GitHub token string passed" || ok
grep -qE '^# bake evidence \(BH-6259\) host=[^ ]+ at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z sources=' "$T/out" \
  && ok || bad "E7 header has no host=/at=: $(head -n 1 "$T/out")"
# a phase line that carries a token is dropped as well
printf '2026-10-12 01:00:00Z pool project-3: bake phases build=1s push=- record=- total=1s rc=1 ghp_fixture\n' > "$T/h/logs/fleet-propagate.log"
run
grep -qF 'ghp_' "$T/out" && bad "E7 a phase line with a token passed" || ok
# step lines past 80 are cut
fresh; mkdir -p "$T/h/logs/fly-image-build"
{ echo "# fleet-propagate bake capture (BH-3463)"; echo "pool=project-3 sha=a rc=124"; echo "## step timings"
  for s in $(seq 1 100); do echo "#$s DONE ${s}.0s"; done; echo "## last 200 lines"; } > "$T/h/logs/fly-image-build/project-3-a.log"
run
[ "$(grep -c '^#[0-9]* DONE ' "$T/out")" = 80 ] && ok || bad "E7 step lines per capture: $(grep -c '^#[0-9]* DONE ' "$T/out"), want 80"

# --- R1-R5: the relay block ------------------------------------------------
awk '/^# >>> bake-evidence relay/{f=1;next} /^# <<< bake-evidence relay/{exit} f' "$DIR/bin/fly-pool.sh" > "$T/relay.sh"
[ -s "$T/relay.sh" ] || bad "R0 bin/fly-pool.sh has no bake-evidence relay block"
HR="$T/hr"; mkdir -p "$HR/bin/lib" "$HR/logs/fly-image-build" "$T/tmp"
cp "$DIR/bin/bake-evidence.sh" "$HR/bin/" 2>/dev/null && chmod +x "$HR/bin/bake-evidence.sh"
scratch_install_closure bin/lib/deployment.sh "$HR" >/dev/null || bad "R0 could not install bin/lib/deployment.sh"
# TEST-CHANGE (fleet-projects-not-hardcoded): the relay decides "the harness's
# own project" by repo (POOL_SLUG = HARNESS_REPO), not by a project name, so the
# fixture hands it a pool repo. Acme/harness stands in for the harness repo.
HREPO=Acme/harness
relay() { # relay <pool-slug> [mput-rc] — runs push_bake_evidence m-fixture in a subshell
  : > "$T/mput.calls"; : > "$T/say.log"; rm -rf "$T/remote"
  ( export TMPDIR="$T/tmp" HARNESS_REPO="$HREPO"
    HARNESS="$HR" POOL_SLUG="$1" MPUT_RC="${2:-0}"
    say() { echo "$*" >> "$T/say.log"; }
    mput() { echo "$1 $3" >> "$T/mput.calls"; [ "$MPUT_RC" = 0 ] || return 1
             mkdir -p "$T/remote$(dirname "$3")"; cp "$2" "$T/remote$3"; }
    # shellcheck disable=SC1090
    . "$T/relay.sh"
    push_bake_evidence m-fixture )
  echo $? > "$T/rrc"
}
for i in 1 2 3; do
  phase "0$i:10" project-3 "17${i}0" >> "$HR/logs/fleet-propagate.log"
  phase "0$i:20" project-2 "16${i}0" >> "$HR/logs/fleet-propagate.log"
  phase "0$i:30" project-1 "15${i}0" >> "$HR/logs/fleet-propagate.log"
done
cp "$T/h/logs/fly-image-build/project-3-a.log" "$HR/logs/fly-image-build/" 2>/dev/null
printf 'tail-only fixture\n' >> "$HR/logs/fly-image-build/project-3-a.log"

# R1 the harness's own pool with evidence: one mput, the copy holds the lines
relay "$HREPO"
[ "$(cat "$T/rrc")" = 0 ] && ok || bad "R1 push_bake_evidence returned $(cat "$T/rrc")"
[ "$(cat "$T/mput.calls")" = "m-fixture /data/harness/state/bake-evidence.txt" ] && ok || bad "R1 mput calls: $(cat "$T/mput.calls")"
CP="$T/remote/data/harness/state/bake-evidence.txt"
grep -E ': bake phases ' "$CP" 2>/dev/null > "$T/got"
cmp -s "$T/got" "$HR/logs/fleet-propagate.log" && ok || bad "R1 the copy does not hold the 9 fixture phase lines"
grep -qxF '### project-3-a.log' "$CP" 2>/dev/null && grep -qxF '#1 DONE 1.0s' "$CP" && ok || bad "R1 the copy has no capture section"
grep -qF 'tail-only fixture' "$CP" 2>/dev/null && bad "R1 the capture tail reached the copy" || ok
grep -qF 'relayed the hub bake evidence to m-fixture' "$T/say.log" && ok || bad "R1 no relay say line"

# R2 both dispatch paths call it on the line after push_build_note: spawn_one
# ($KEY) and the REAP reuse of a live machine for the next job ($NKEY)
for k in KEY NKEY; do
  awk -v k="$k" 'p { print; exit } $0 ~ "^[[:space:]]*push_build_note \"\\$MID\" \"\\$" k "\"[[:space:]]*$" { p=1 }' "$DIR/bin/fly-pool.sh" > "$T/next"
  grep -qxE '[[:space:]]*push_bake_evidence "\$MID"[[:space:]]*' "$T/next" && ok || bad "R2 the \$$k dispatch path does not call push_bake_evidence \"\$MID\" after push_build_note (next line: $(cat "$T/next"))"
done

# R3 another project's pool: no mput
relay Acme/project-3
[ "$(cat "$T/rrc")" = 0 ] && [ ! -s "$T/mput.calls" ] && ok || bad "R3 project-3 relayed: $(cat "$T/mput.calls")"

# R4 the harness's own pool with no evidence: no mput
mv "$HR/logs" "$HR/logs.off"; mkdir -p "$HR/logs"
relay "$HREPO"
[ "$(cat "$T/rrc")" = 0 ] && [ ! -s "$T/mput.calls" ] && ok || bad "R4 relayed with no evidence: $(cat "$T/mput.calls")"
scratch_rm "$HR/logs"; mv "$HR/logs.off" "$HR/logs"

# R5 a failing mput: returns 0, says so, leaves no temp file
relay "$HREPO" 1
[ "$(cat "$T/rrc")" = 0 ] && ok || bad "R5 a failed mput returned $(cat "$T/rrc")"
[ -s "$T/mput.calls" ] && ok || bad "R5 mput was not tried"
grep -qF 'm-fixture: bake-evidence push FAILED' "$T/say.log" && ok || bad "R5 no FAILED say line"
left=$(find "$T/tmp" -maxdepth 1 -name 'bake-ev-*' | wc -l)
[ "$left" = 0 ] && ok || bad "R5 $left bake-ev-* temp file(s) left behind"

# R6 the repo match ignores case (GitHub slugs do), and no pool repo is no relay
relay "${HREPO^^}"
[ "$(cat "$T/rrc")" = 0 ] && [ -s "$T/mput.calls" ] && ok || bad "R6 an upper-case slug of the harness repo did not relay"
relay ""
[ "$(cat "$T/rrc")" = 0 ] && [ ! -s "$T/mput.calls" ] && ok || bad "R6 an empty POOL_SLUG relayed: $(cat "$T/mput.calls")"

# --- P1 / N1 ---------------------------------------------------------------
grep -qF '/root/harness/state/bake-evidence.txt' "$DIR/prompts/cromford.md" && ok || bad "P1 prompts/cromford.md does not name the digest"
grep -qF 'POOL_BAKE_TIMEOUT_S:-1800' "$DIR/bin/fleet-propagate.sh" && ok || bad "N1 POOL_BAKE_TIMEOUT_S default is no longer 1800"

echo "bake-evidence.bh-6259: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
