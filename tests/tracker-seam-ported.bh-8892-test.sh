#!/bin/bash
# tests/tracker-seam-ported.bh-8892-test.sh — BH-8892: the two libs the
# tracker-direct-calls ratchet (BH-7919) named on main read the tracker through
# the seam, and a project whose tracker is not github-issues gets no GitHub
# parent read.
#
#   F1-F6   trk_gh_issue_field <n> <filter> (bin/lib/tracker/github-issues.sh):
#           one _gh_rest_field call with repos/<slug>/issues/<n>; its rc 0, 44
#           and 75 pass through; a bad slug, a bad number or an empty filter
#           is rc 1 with no call.
#   K1-K5   _unblock_infra_parent_state <repo> <PARENT> <kind>: github-issues
#           reads the issue (open, closed); jira, linear, board and an empty
#           kind are `unread - - - - -` with 0 gh calls.
#   S1      _unblock_infra_starve on a scratch tree: fleet.conf column 4 is `-`
#           and tracker_adapter answers linear -> `state unread`, 0 gh calls
#           (the near miss the kind seam exists for). S1b: the same tree with
#           github-issues reads the parent once.
#   B       0 non-GET gh calls and 0 curl calls in every case.
#
# MUTATIONS (D1), each tried once by hand: make the parent-state gate
# `[ "$kind" != board ] || return 0` -> K3, K4 (linear), K5 and S1 red; drop the
# filter check in trk_gh_issue_field -> F6 red; drop _trk_gh_ok -> F4, F5 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/tracker-seam-ported.bh-8892-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

P=cromford
R=example-org/cromford
NOWE=1793000000

mkdir -p "$T/pathbin"
printf '#!/bin/bash\necho "curl $*" >> "$CURL_LOG"\nexit 7\n' > "$T/pathbin/curl"
chmod +x "$T/pathbin/curl"
budget() { # budget <case dir> <name>
  check "B $2: 0 non-GET gh calls" "$(grep -vc '^GET ' "$1/gh.log")" 0
  check "B $2: 0 curl calls" "$(grep -c . "$1/curl.log")" 0
}
newcase() { local C="$T/$1"; mkdir -p "$C/tmp"; : > "$C/gh.log"; : > "$C/curl.log"; printf '%s' "$C"; }

# ═════ F1-F6: trk_gh_issue_field ════════════════════════════════════════════
# field <case dir> <stub rc> <slug> <n> <filter> -> "<rc> <stdout>"; the stub
# logs its argv to <case dir>/gh.log.
field() {
  local C="$1"
  (
    export PATH="$T/pathbin:$PATH" CURL_LOG="$C/curl.log" TMPDIR="$C/tmp"
    . "$SRC/bin/lib/tracker/github-issues.sh" || exit 9
    _gh_rest_field() { echo "GET $1 $2" >> "$C/gh.log"; [ "$STUB_RC" = 0 ] && printf 'v12\n'; return "$STUB_RC"; }
    out=$(STUB_RC="$2" TRK_SLUG="$3" trk_gh_issue_field "$4" "$5"); rc=$?
    printf '%s %s' "$rc" "$out"
  )
}
C=$(newcase f1)
check "F1 rc 0 and the stub's value" "$(field "$C" 0 o/r 12 '.body')" "0 v12"
check "F1 one call: repos/o/r/issues/12 .body" "$(cat "$C/gh.log")" "GET repos/o/r/issues/12 .body"
budget "$C" F1
C=$(newcase f2)
check "F2 stub 44 -> 44" "$(field "$C" 44 o/r 12 '.body')" "44 "
C=$(newcase f3)
check "F3 stub 75 -> 75" "$(field "$C" 75 o/r 12 '.body')" "75 "
C=$(newcase f4)
check "F4 bad slug o/r;x: rc 1, 0 calls" "$(field "$C" 0 'o/r;x' 12 '.body') $(grep -c . "$C/gh.log")" "1  0"
C=$(newcase f5)
check "F5 number 12a: rc 1, 0 calls" "$(field "$C" 0 o/r 12a '.body') $(grep -c . "$C/gh.log")" "1  0"
C=$(newcase f6)
check "F6 empty filter: rc 1, 0 calls" "$(field "$C" 0 o/r 12 '') $(grep -c . "$C/gh.log")" "1  0"

# ═════ K1-K5: _unblock_infra_parent_state by tracker kind ═══════════════════
# pstate <case dir> <issue state|-> <kind> -> _UBI_PS[BH-5]; the gh_rest stub
# answers repos/o/r/issues/5 with <issue state> and the pulls query with [].
pstate() {
  local C="$1"
  (
    export PATH="$T/pathbin:$PATH" CURL_LOG="$C/curl.log" TMPDIR="$C/tmp" HARNESS="$SRC" HARNESS_TEST_SANDBOX=1
    . "$SRC/bin/lib/gh-rest.sh" || exit 9
    . "$SRC/bin/lib/unblock/collectors/infra.sh" || exit 9
    gh_rest() {
      echo "$1 $2" >> "$C/gh.log"
      case "$2" in
        repos/o/r/issues/5) printf '{"number":5,"state":"%s","updated_at":"2026-10-28T00:00:00Z"}\n' "$ISTATE" ;;
        repos/o/r/pulls*) printf '[]\n' ;;
        *) return 44 ;;
      esac
    }
    declare -gA _UBI_PS=()
    _UBI_TMP="$C/tmp" _UBI_NOW=$NOWE ISTATE="$2"
    _unblock_infra_parent_state o/r BH-5 "$3"
    printf '%s' "${_UBI_PS[BH-5]}"
  )
}
C=$(newcase k1)
v=$(pstate "$C" open github-issues)
check "K1 github-issues, open parent: state open" "${v%% *}" open
check "K1 one issue GET" "$(grep -c '^GET repos/o/r/issues/5$' "$C/gh.log")" 1
budget "$C" K1
C=$(newcase k2)
check "K2 github-issues, closed parent" "$(pstate "$C" closed github-issues)" "closed - - - - -"
check "K2 one issue GET" "$(grep -c '^GET repos/o/r/issues/5$' "$C/gh.log")" 1
C=$(newcase k3)
check "K3 jira: unread, 0 gh calls" "$(pstate "$C" open jira) $(grep -c . "$C/gh.log")" "unread - - - - - 0"
C=$(newcase k4l)
check "K4 linear: unread, 0 gh calls" "$(pstate "$C" open linear) $(grep -c . "$C/gh.log")" "unread - - - - - 0"
C=$(newcase k4b)
check "K4 board: unread, 0 gh calls" "$(pstate "$C" open board) $(grep -c . "$C/gh.log")" "unread - - - - - 0"
C=$(newcase k5)
check "K5 empty kind: unread, 0 gh calls" "$(pstate "$C" open '') $(grep -c . "$C/gh.log")" "unread - - - - - 0"
budget "$C" K5

# ═════ S1: _unblock_infra_starve with a Linear tracker behind column 4 `-` ══
# The mkc / phl / pool / after shapes are copied from the bh-8766 suite.
mkc() { # mkc <name> -> the case dir
  local C f
  C=$(newcase "$1")
  mkdir -p "$C/h/logs" "$C/h/builds" "$C/h/catalog"
  for f in bin/lib/unblock/collectors/infra.sh bin/lib/gh-rest.sh bin/fleet-conf.sh; do
    scratch_install_closure "$f" "$C/h" >/dev/null || return 1
  done
  printf '%s %s - - 3 hub 192.0.2.10\n' "$P" "$R" > "$C/h/fleet.conf"
  : > "$C/unblock.log"; : > "$C/h/logs/pipeline-health.log"
  printf '%s' "$C"
}
phl() { # phl <case dir> <KEY> <min> <passes>
  local C="$1" k="$2" m="$3" n="$4" i
  for ((i = n - 1; i >= 0; i--)); do
    printf '%s %s %s queued %sm with no spawn — fly-dispatch/pool not picking it up\n' \
      "$(date -u -d "@$((NOWE - i * 600))" '+%Y-%m-%d %H:%M:%SZ')" "$P" "$k" "$((m - i * 10))" >> "$C/h/logs/pipeline-health.log"
  done
}
pool() { # pool <case dir> <KEY> <age_s> <RESULT line> -> the record dir
  local d
  d="$1/h/builds/pool-$P-$2-$(date -u -d "@$((NOWE - $3))" +%Y%m%d%H%M%S)"
  mkdir -p "$d"; printf '%s\n' "$4" > "$d/RESULT"; touch -d "@$((NOWE - $3))" "$d/RESULT"
  printf '%s' "$d"
}
after() { local d="$1" k; shift; for k in "$@"; do printf 'After: %s\n' "$k"; done > "$d/plan-blocked.after"; }
starve() { # starve <case dir> <tracker_adapter answer>
  local C="$1"
  (
    export HARNESS="$C/h" PATH="$T/pathbin:$PATH" CURL_LOG="$C/curl.log" TMPDIR="$C/tmp" HARNESS_TEST_SANDBOX=1 \
      UNBLOCK_NOW="$NOWE" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/infra.sh" || exit 9
    . "$SRC/bin/lib/tracker.sh" || exit 9
    tracker_adapter() { printf '%s\n' "$ADAPTER"; }
    gh_rest() {
      echo "$1 $2" >> "$C/gh.log"
      case "$2" in
        "repos/$R/issues/8324") printf '{"number":8324,"state":"closed","updated_at":"2026-10-28T00:00:00Z"}\n' ;;
        *) return 44 ;;
      esac
    }
    ubt_log() { printf "%s\n" "$*" >> "$C/unblock.log"; }
    ADAPTER="$2" unblock_collect_infra --project "$P" --repo "$R" --family starve > "$C/records.jsonl"; echo "$?" > "$C/rc"
  )
}
C=$(mkc s1) || { echo "FAIL: case setup"; exit 1; }
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "PLAN_BLOCKED: on hold until #8324 merges"); after "$D" BH-8324
starve "$C" linear
check "S1 linear behind column 4 '-': rc 0, 0 records" "$(cat "$C/rc") $(grep -c . "$C/records.jsonl")" "0 0"
check "S1 the skip line says state unread" "$(grep "^starve-skip $P BH-8325: " "$C/unblock.log" | head -n1)" "starve-skip $P BH-8325: waits on parent BH-8324: state unread"
check "S1 0 gh calls" "$(grep -c . "$C/gh.log")" 0
budget "$C" S1

C=$(mkc s1b)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "PLAN_BLOCKED: on hold until #8324 merges"); after "$D" BH-8324
starve "$C" github-issues
check "S1b github-issues: the closed parent is read once, 1 ticket-starved" \
  "$(grep -c "^GET repos/$R/issues/8324\$" "$C/gh.log") $(jq -r 'select(.kind == "ticket-starved") | .ticket' "$C/records.jsonl")" "1 BH-8325"
budget "$C" S1b

echo "tracker-seam-ported.bh-8892: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
