#!/bin/bash
# tests/tracker-board-prefix.bh-9966-test.sh — BH-9966: the nightly red at R1
# of tests/tracker-direct-calls-ratchet.bh-7919-test.sh. ca_ticket_url
# (bin/lib/client-approval.sh) read fleet.conf column 4 directly. The read now
# goes through the seam function tracker_board_prefix in bin/lib/tracker.sh.
#
#   P1  a board project prints its prefix, rc 0
#   P2  a GitHub-issues project prints `-`, rc 0
#   P3  an empty project: rc 1, nothing printed
#   P4  fleet-conf.sh refuses (unknown project): rc 1, nothing printed
#   P5  no HARNESS/H: the fleet-conf.sh beside the lib; near miss: a HARNESS
#       with no fleet-conf.sh also uses the one beside the lib
#   P6  ca_ticket_url from a shell that sourced ONLY client-approval.sh builds
#       the URL, and no tracker function leaks into that shell
#   P6b ca_ticket_url with only MC_H set reads $MC_H/bin/fleet-conf.sh
#   P7  ca_ticket_url with no tracker.sh: empty answer, rc 0
#   P8  no code line of bin/lib/client-approval.sh names board_prefix
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tracker-board-prefix.bh-9966-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# mktree <dir> <tag> [nofcs] [notracker] — a scratch harness tree: the real
# closures of tracker.sh and client-approval.sh, and a fake bin/fleet-conf.sh
# whose answers carry <tag> so a case can tell which tree answered.
mktree() {
  local d="$1" tag="$2" f; shift 2
  mkdir -p "$d/bin/lib"
  for f in bin/lib/client-approval.sh bin/lib/tracker.sh; do
    scratch_install_closure "$f" "$d" >/dev/null || { echo "FAIL: closure of $f"; exit 1; }
  done
  rm -f "$d/bin/fleet-conf.sh"
  case " $* " in *" notracker "*) rm -f "$d/bin/lib/tracker.sh" ;; esac
  case " $* " in *" nofcs "*) return 0 ;; esac
  cat > "$d/bin/fleet-conf.sh" <<SH
#!/bin/bash
case "\$1 \$2" in
  "brd board_prefix") echo "/api/$tag" ;;
  "brd prod") echo "https://os.example" ;;
  "gh board_prefix") echo "-" ;;
  "gh prod") echo "https://gh.example" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/bin/fleet-conf.sh"
}

# run_tbp <tree> <env-assignments...> -- <project> — tracker_board_prefix in a
# clean bash; prints `<rc>|<stdout>`.
run_tbp() {
  local tree="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$PATH" "${envs[@]}" bash -c 'set -u
    . "$0/bin/lib/tracker.sh" || exit 9
    out=$(tracker_board_prefix "$1"); rc=$?
    printf "%s|%s" "$rc" "$out"' "$tree" "$1"
}

# P1 / P2 / P3 / P4
A="$T/p1"; mktree "$A" board
eq "P1 board project" "$(run_tbp "$A" HARNESS="$A" -- brd)" "0|/api/board"
A="$T/p2"; mktree "$A" board
eq "P2 github-issues project" "$(run_tbp "$A" HARNESS="$A" -- gh)" "0|-"
A="$T/p3"; mktree "$A" board
eq "P3 empty project" "$(run_tbp "$A" HARNESS="$A" -- "")" "1|"
A="$T/p4"; mktree "$A" board
eq "P4 fleet-conf refuses" "$(run_tbp "$A" HARNESS="$A" -- nope)" "1|"

# P5: no root -> beside the lib; a root with no fleet-conf.sh -> beside the lib
A="$T/p5"; mktree "$A" beside
eq "P5 no HARNESS, no H" "$(run_tbp "$A" -- brd)" "0|/api/beside"
R="$T/p5root"; mktree "$R" rootless nofcs
eq "P5 near miss: HARNESS without fleet-conf.sh" "$(run_tbp "$A" HARNESS="$R" -- brd)" "0|/api/beside"
R2="$T/p5root2"; mktree "$R2" fromroot
eq "P5 HARNESS with fleet-conf.sh wins" "$(run_tbp "$A" HARNESS="$R2" -- brd)" "0|/api/fromroot"

# run_ca <tree> <env-assignments...> -- <project> <id> — ca_ticket_url in a
# clean bash that sourced only client-approval.sh; prints
# `<rc>|<url>|<declare -F tracker_board_prefix rc>`.
run_ca() {
  local tree="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$PATH" "${envs[@]}" bash -c 'set -u
    . "$0/bin/lib/client-approval.sh" || exit 9
    out=$(ca_ticket_url "$1" "$2"); rc=$?
    ca_ticket_url "$1" "$2" >/dev/null
    declare -F tracker_board_prefix >/dev/null 2>&1; leak=$?
    printf "%s|%s|%s" "$rc" "$out" "$leak"' "$tree" "$1" "$2"
}

# P6: URL built, no leak into the calling shell
A="$T/p6"; mktree "$A" board
eq "P6 ca_ticket_url board project" "$(run_ca "$A" HARNESS="$A" -- brd 7)" "0|https://os.example/board?ticket=7|1"
eq "P6 ca_ticket_url github-issues project" "$(run_ca "$A" HARNESS="$A" -- gh 7)" "0||1"

# P6b: only MC_H set — the prefix comes from $MC_H's fleet-conf.sh, as prod does
A="$T/p6b"; mktree "$A" beside
M="$T/p6bmc"; mktree "$M" frommc
eq "P6b ca_ticket_url with only MC_H" "$(run_ca "$A" MC_H="$M" -- brd 7)" "0|https://os.example/frommc?ticket=7|1"

# P7: no tracker.sh anywhere: empty, rc 0, never a guessed URL
A="$T/p7"; mktree "$A" board notracker
eq "P7 no tracker.sh" "$(run_ca "$A" HARNESS="$A" -- brd 7)" "0||1"

# P8: no code line of client-approval.sh reads column 4 directly
hits=$(awk '/^[[:space:]]*#/ { next } /(^|[^A-Za-z0-9_])board_prefix([^A-Za-z0-9_]|$)/ { print }' "$DIR/bin/lib/client-approval.sh")
eq "P8 no direct board_prefix read in client-approval.sh" "$hits" ""

echo "tracker-board-prefix.bh-9966: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
