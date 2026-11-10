#!/bin/bash
# tests/audit-install.bh-9363-test.sh — bin/audit-install.sh renders one
# `-a never,exit -F arch=b64 -S unlink,unlinkat -F dir=$H/state/<path>` rule per
# state dir the composed catalog classes `cache` (plus gh-rest-ledger and
# lane-runs when the catalog classes them `box-local`), after the old never
# rules and before every always rule (BH-9363).
#
# WHY. On bh-hub-2 one 50M audit file held 45 minutes: 45,913 of 46,080 events
# were `unlinkat` of routine cache evictions under state/. Those unlinks are
# churn; a wipe of state/ still leaves the rmdir of each dir, so rmdir stays
# recorded, and nothing under flags/ is ever excluded.
#
# The fixture is a scratch harness tree under $T with a real copy of
# bin/audit-install.sh AND bin/state-paths-build.sh, and a fixture catalog in
# $T/h/catalog/state-paths.d/. The real CLI is driven (--render, --check, the
# install path) with auditctl/augenrules/auditd stubbed on PATH. Each case
# rebuilds the fixture (fresh), so no case reads another case's output.
#
# Cases: A1-A5 (render shape, rmdir/flags, byte-stable, new fragment, install
# and check round trip, fallback load) and D3-D12 (the decision rule and the
# fail-safe exits).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-9363-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin" "$T/etc" "$T/orch" "$T/outside"
S="$T/h/bin/audit-install.sh"

stub() { # stub <name> <body...>
  local n="$1"; shift
  { echo '#!/bin/bash'; echo "T=\"$T\""; printf '%s\n' "$@"; } > "$T/fakebin/$n"
  chmod +x "$T/fakebin/$n"
}
stub auditctl \
  'echo "$*" >> "$T/auditctl.calls"' \
  'case "${1:-}" in' \
  '  -l) [ -f "$T/loaded" ] && cat "$T/loaded"; exit 0 ;;' \
  'esac' \
  'exit 0'
stub augenrules \
  'echo "$*" >> "$T/augenrules.calls"' \
  '[ -f "$T/augfail" ] && { echo "augenrules: no" >&2; exit 1; }' \
  'exit 0'
stub auditd  'exit 0'
stub pgrep   '[ -f "$T/running" ] && exit 0; exit 1'
stub pkill   'exit 0'
stub apt-get 'exit 0'
stub ausearch 'exit 0'
aline() { echo "-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=$1 -F key=harness"; }

ROOTS="$T/h $T/orch"
REDIR=(HARNESS="$T/h"
       AUDIT_RULES_FILE="$T/etc/harness.rules"
       AUDITD_CONF="$T/etc/auditd.conf"
       AUDIT_SUPERVISOR_DIR="$T/nosup"
       AUDIT_SYSTEMD_DIR="$T/nosys"
       AUDIT_ROOTS="$ROOTS"
       AUDIT_LOG_PATH="$T/audit.log"
       AUDIT_PROBE_WAIT_S=1
       AUDIT_SBIN_PATH="")
FULLPATH="$T/fakebin:/usr/bin:/bin"
run()    { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S"; }
render() { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S" --render; }
check()  { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S" --check; }

# fresh — a new harness tree: the two scripts, the state dirs, the catalog.
SD="$T/h/state"
fresh() {
  rm -rf "$T/h" "$T/etc"/* "$T/outside"/* "$T"/*.calls "$T/loaded" "$T/running" "$T/augfail"
  mkdir -p "$T/h/bin" "$T/h/env" "$T/h/logs" "$T/h/locks" "$T/h/tmp" "$T/h/flags" \
           "$T/h/catalog/state-paths.d" "$T/outside/target"
  cp "$DIR/bin/audit-install.sh" "$DIR/bin/state-paths-build.sh" "$T/h/bin/"
  chmod +x "$T/h/bin/"*.sh
  : > "$T/h/env/global.env"
  touch "$T/audit.log"
  mkdir -p "$SD/cache-a" "$SD/cache-b" "$SD/rowsdir" \
           "$SD/gh-rest-ledger" "$SD/scratchy" "$SD/caches-near" "$SD/bad name" "$SD/Cachey"
  : > "$SD/cache-file.json"
  ln -s "$T/outside/target" "$SD/cache-link"
  cat > "$T/h/catalog/state-paths.d/_head.json" <<'EOF'
{
  "version": 1,
  "about": "BH-9363 fixture"
}
EOF
  cat > "$T/h/catalog/state-paths.d/0001-fixture.json" <<'EOF'
[
    {"path": "cache-a",         "class": "cache"},
    {"path": "cache-b",         "class": "cache"},
    {"path": "cache-file.json", "class": "cache"},
    {"path": "cache-missing",   "class": "cache"},
    {"path": "cache-link",      "class": "cache"},
    {"path": "rowsdir",         "class": "rows"},
    {"path": "gh-rest-ledger",  "class": "box-local"},
    {"path": "scratchy",        "class": "box-local"},
    {"path": "caches-near",     "class": "caches"},
    {"path": "Cachey",          "class": "Cache"},
    {"path": "../flags",        "class": "cache"},
    {"path": "bad name",        "class": "cache"}
]
EOF
}
NU="-a never,exit -F arch=b64 -S unlink,unlinkat -F dir="
has()  { grep -qxF -- "$NU$SD/$1" "$2"; }   # has <path> <render file>
newl() { grep -F -- "$NU$SD/" "$1"; }       # the new state/ lines

# ── A1: two cache dirs + gh-rest-ledger, sorted, before every always line ───
fresh
render > "$T/r1" 2>"$T/r1.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A1 --render rc=$RC: $(cat "$T/r1.err")"
WANT=$(printf '%s\n' "$NU$SD/cache-a" "$NU$SD/cache-b" "$NU$SD/gh-rest-ledger")
GOTN=$(newl "$T/r1")
[ "$GOTN" = "$WANT" ] && ok || bad "A1 new never lines must be exactly cache-a, cache-b, gh-rest-ledger in C order: got
$GOTN"
LASTN=$(grep -n '^-a never,exit ' "$T/r1" | tail -n 1 | cut -d: -f1)
FIRSTA=$(grep -n '^-a always,exit ' "$T/r1" | head -n 1 | cut -d: -f1)
[ -n "$LASTN" ] && [ -n "$FIRSTA" ] && [ "$LASTN" -lt "$FIRSTA" ] && ok \
  || bad "A1 every never line comes before the first always line: $(cat "$T/r1")"

# ── A2: no rmdir in a new line, nothing under flags/, the 6 old lines intact ─
[ "$(newl "$T/r1" | grep -c rmdir)" -eq 0 ] && ok || bad "A2 a new line must not carry rmdir: $(newl "$T/r1")"
[ "$(grep -c -- "dir=$T/h/flags" "$T/r1")" -eq 0 ] && ok || bad "A2 nothing under flags/ is excluded: $(cat "$T/r1")"
OLD=$(grep '^-a never,exit ' "$T/r1" | grep -vF -- "$NU$SD/")
WANTOLD=$(for d in state logs locks tmp; do echo "-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$T/h/$d"; done
          for d in locks tmp; do echo "-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=$T/h/$d"; done)
[ "$OLD" = "$WANTOLD" ] && ok || bad "A2 the 6 existing never lines are unchanged: got
$OLD"

# ── A2b: byte-stable ──────────────────────────────────────────────────────
render HOSTNAME=other TZ=America/Chicago > "$T/r2" 2>/dev/null
cmp -s "$T/r1" "$T/r2" && ok || bad "A2b --render must be byte-stable: $(diff "$T/r1" "$T/r2")"

# ── A3: a new cache fragment is picked up with no edit to the script ──────
fresh
mkdir -p "$SD/cache-c"
printf '[\n    {"path": "cache-c", "class": "cache"}\n]\n' > "$T/h/catalog/state-paths.d/0002-new.json"
render > "$T/r3" 2>/dev/null
has cache-c "$T/r3" && ok || bad "A3 a new cache fragment must render a cache-c line: $(newl "$T/r3")"
cmp -s "$DIR/bin/audit-install.sh" "$S" && ok || bad "A3 the script must be the unedited copy"

# ── A4: install writes the render; --check reads it back ──────────────────
fresh
touch "$T/running"
for r in $ROOTS; do aline "$r"; done > "$T/loaded"
run > /dev/null 2>&1
render > "$T/r4" 2>/dev/null
cmp -s "$T/r4" "$T/etc/harness.rules" && ok || bad "A4 the installed rules file must equal --render: $(diff "$T/r4" "$T/etc/harness.rules" 2>&1)"
check > "$T/c4" 2>&1
grep -qxF 'harness rules: present (2 always, 9 never)' "$T/c4" && ok || bad "A4 --check must read 'present (2 always, 9 never)': $(cat "$T/c4")"
grep -qxF 'loaded harness rules: 2 (expected 2)' "$T/c4" && ok || bad "A4 EXPECT is unchanged by the keyless never lines: $(cat "$T/c4")"
grep -qE '^max_log_file = 50$' "$T/etc/auditd.conf" && grep -qE '^num_logs = 5$' "$T/etc/auditd.conf" && ok \
  || bad "A4 auditd.conf keeps max_log_file = 50 and num_logs = 5: $(cat "$T/etc/auditd.conf" 2>&1)"

# ── A5: augenrules fails -> auditctl -d gets each new never line ──────────
fresh
touch "$T/running" "$T/augfail"
for r in $ROOTS; do aline "$r"; done > "$T/loaded"
run > /dev/null 2>&1
for p in cache-a cache-b gh-rest-ledger; do
  grep -qxF -- "-d never,exit -F arch=b64 -S unlink,unlinkat -F dir=$SD/$p" "$T/auditctl.calls" 2>/dev/null && ok \
    || bad "A5 the fallback must delete the $p never line first: $(cat "$T/auditctl.calls" 2>&1)"
done

# ── D3-D8: the decision rule ──────────────────────────────────────────────
fresh
render > "$T/rd" 2>/dev/null
for p in cache-file.json cache-missing cache-link rowsdir scratchy caches-near Cachey "bad name"; do
  [ "$(grep -cF -- "dir=$SD/$p" "$T/rd")" -eq 0 ] && ok || bad "D3-D8 $p must render no line: $(newl "$T/rd")"
done
[ "$(grep -cF -- 'flags' "$T/rd")" -eq 0 ] && ok || bad "D8 ../flags must render no line: $(cat "$T/rd")"
# D7: a lane-runs dir NOT in the catalog gets no line ...
fresh; mkdir -p "$SD/lane-runs"
render > "$T/r7a" 2>/dev/null
[ "$(grep -cF -- "dir=$SD/lane-runs" "$T/r7a")" -eq 0 ] && ok || bad "D7 lane-runs not in the catalog must get no line"
# ... and the same dir classed box-local does.
printf '[\n    {"path": "lane-runs", "class": "box-local"}\n]\n' > "$T/h/catalog/state-paths.d/0002-lane-runs.json"
render > "$T/r7b" 2>/dev/null
has lane-runs "$T/r7b" && ok || bad "D7 lane-runs classed box-local with a dir must get a line: $(newl "$T/r7b")"
# a nested cache dir a/b that exists gets a line
fresh; mkdir -p "$SD/nest/inner"
printf '[\n    {"path": "nest/inner", "class": "cache"},\n    {"path": "a/../cache-a", "class": "cache"},\n    {"path": "./cache-b", "class": "cache"}\n]\n' \
  > "$T/h/catalog/state-paths.d/0002-nest.json"
render > "$T/r7c" 2>/dev/null
has nest/inner "$T/r7c" && ok || bad "D8 a nested cache dir must get a line: $(newl "$T/r7c")"
[ "$(grep -cF -- '..' "$T/r7c")" -eq 0 ] && [ "$(grep -cF -- "/./" "$T/r7c")" -eq 0 ] && ok \
  || bad "D8 a path with a .. or . segment must get no line: $(newl "$T/r7c")"

# ── D9: a refused compose renders only the old rules, rc 0 ────────────────
fresh
render > "$T/base" 2>/dev/null
grep -vF -- "$NU$SD/" "$T/base" > "$T/old"
echo 'not json' > "$T/h/catalog/state-paths.d/0003-broken.json"
render > "$T/r9" 2>"$T/r9.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "D9 --render must exit 0 on a refused compose (rc=$RC)"
cmp -s "$T/r9" "$T/old" && ok || bad "D9 a refused compose renders only the old lines: $(diff "$T/old" "$T/r9")"
[ ! -s "$T/r9.err" ] && ok || bad "D9 --render prints nothing on stderr: $(cat "$T/r9.err")"

# ── D10: no builder -> the old rules ──────────────────────────────────────
fresh
rm -f "$T/h/bin/state-paths-build.sh"
render > "$T/r10" 2>/dev/null; RC=$?
[ "$RC" -eq 0 ] && cmp -s "$T/r10" "$T/old" && ok || bad "D10 no builder renders only the old lines (rc=$RC): $(diff "$T/old" "$T/r10")"

# ── D11: the temp file is removed ─────────────────────────────────────────
fresh
rm -rf "$T/tmpx"; mkdir -p "$T/tmpx"
render TMPDIR="$T/tmpx" > "$T/r11" 2>/dev/null
has cache-a "$T/r11" && ok || bad "D11 the compose must work with TMPDIR=$T/tmpx"
[ -z "$(ls -A "$T/tmpx")" ] && ok || bad "D11 \$TMPDIR must be empty after --render: $(ls -A "$T/tmpx")"

# ── D12: harness root not in AUDIT_ROOTS -> no state/ unlink line ─────────
fresh
render AUDIT_ROOTS="$T/orch" > "$T/r12" 2>/dev/null
[ "$(grep -cF -- "$NU$SD/" "$T/r12")" -eq 0 ] && ok || bad "D12 no state/ line without the harness root: $(cat "$T/r12")"

bash -n "$DIR/bin/audit-install.sh" && ok || bad "bin/audit-install.sh must parse"
echo "audit-install bh-9363: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
