#!/bin/bash
# tests/load-project-tailnet-ip-test.sh — the registry append carries the
# box's tailnet address when the registry already knows it.
#
# THE INCIDENT THIS PINS (project-6-desktop, 8a1d9bc7c, 2026-10-21). The loader
# appended a 6-column row on box-small, a box whose other five rows
# carry its address in the 7th column. bin/fleet-conf.sh <p> tailnet_ip fails
# closed on that row, and bin/box-register.sh read the empty column as the
# address "-", so tests/box-register.bh-5747-test.sh went red on main.
#
# The real bin/load-project.sh is driven end to end, as in
# tests/load-project-newline-test.sh: gh and the network verbs of git are
# stubs, and the whole fleet lives in $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$T/stub/gh" "$T/stub/git"

# RFC 5737 fixture address: the loader copies the column, it does not validate it.
ROW_A='alpha         Acme/alpha                 -                                    -   2  box-small 192.0.2.7'

mkrepo() { # mkrepo <dir> — a scratch cromford checkout with ROW_A only
  local R="$1"
  mkdir -p "$R/prompts"
  cp -r "$DIR/bin" "$R/bin"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
  printf '%s\n' "$ROW_A" > "$R/fleet.conf"
  ( cd "$R" || exit 1
    "$REAL_GIT" init -q . && "$REAL_GIT" config user.email t@t && "$REAL_GIT" config user.name t
    "$REAL_GIT" add -A && "$REAL_GIT" commit -qm base ) >/dev/null 2>&1
}
load() { # load <repo dir> [args...]
  local R="$1"; shift
  ( cd "$R" && PATH="$T/stub:$PATH" HARNESS="$T/h" bash bin/load-project.sh "$@" ) >"$T/out" 2>&1
  echo $?
}
conf() { FLEET_CONF="$2" "$1/bin/fleet-conf.sh" "${@:3}" 2>/dev/null; }

# ── A. a box the registry knows: the new row carries its address ────────────
mkrepo "$T/a"
RC=$(load "$T/a" acme/widget --project widget --box box-small --no-bootstrap)
eq "A rc" "$RC" "0"
eq "A widget box" "$(conf "$T/a" "$T/a/fleet.conf" widget box)" "box-small"
eq "A widget tailnet_ip" "$(conf "$T/a" "$T/a/fleet.conf" widget tailnet_ip)" "192.0.2.7"
eq "A widget --tailnet-ip" "$(conf "$T/a" "$T/a/fleet.conf" --tailnet-ip widget)" "192.0.2.7"
eq "A alpha untouched" "$(head -1 "$T/a/fleet.conf")" "$ROW_A"

# ── B. a box with no known address: 6 columns, never a "-" placeholder ──────
mkrepo "$T/b"
RC=$(load "$T/b" acme/widget --project widget --box zzz-box --no-bootstrap)
eq "B rc" "$RC" "0"
eq "B widget box" "$(conf "$T/b" "$T/b/fleet.conf" widget box)" "zzz-box"
eq "B widget column count" "$(awk '$1 == "widget" {print NF}' "$T/b/fleet.conf")" "6"
conf "$T/b" "$T/b/fleet.conf" widget tailnet_ip >/dev/null && bad "B tailnet_ip must fail closed" || ok

echo "load-project-tailnet-ip-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
