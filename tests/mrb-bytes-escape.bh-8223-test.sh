#!/bin/bash
# tests/mrb-bytes-escape.bh-8223-test.sh — BH-8223: gh refuses to print an
# Actions job log that holds ANSI escapes unless the call passes
# --allow-escape-sequences. _mrb_bytes did not pass it, mapped the refusal to
# rc 75, and the bisect logged `forge-unreachable` for a 200 read.
#
#   E1   flag present → rc 0, the bytes (ESC included) in the out file, no why.
#   E1b  the call carries --allow-escape-sequences.
#   E2   404 → rc 44.  E2b 410 → rc 44.
#   E3   the escape message even with the flag → rc 76, `gh-refused: <msg>`.
#   E4   HTTP 502, an empty stderr, a near-miss "escape" text → rc 75, `gh: …`.
#   E5   an old gh (`unknown flag`) → one bare retry → rc 0; exactly 2 calls.
#   E5b  the bare retry answers 404 → rc 44 (its own answer decides).
#   E6   the real mrb_detect_episodes, a flag episode whose job log gh refuses:
#        rc 75, no episode file, its stderr names `rc=76 gh-refused: …`.
#   W1-W5 the real bin/main-red-bisect.sh: http 2xx → `log-read-failed`;
#        000, 5xx, 429 → `forge-unreachable`.
#
# Only `gh` and `curl` are stubs. No network, no clock (commit dates pinned).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mrb-bytes-escape.bh-8223-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
DETECT="$DIR/bin/lib/mrb-detect.sh"
PROBE="$DIR/bin/lib/mrb-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in: ${2:0:400}"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }

REFUSE='the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway'
ESCLOG=$(printf '2026-09-30T10:00:01.1Z \033[32m--- tests/x-test.sh rc=1 3s\033[0m')

# ── stub gh: a REST arm (gh_rest) and a bytes arm driven by $T/mode ──────────
export MRBT="$T"
mkdir -p "$T/bin" "$T/rest"
cp "$DIR/tests/lib/rest-emit.sh" "$T/bin/restpr"; chmod +x "$T/bin/restpr"
printf '%s\n' "$ESCLOG" > "$T/esc.log"
printf '%s\n' "$REFUSE" > "$T/refuse.txt"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MRBT/gh-calls.txt"
[ "${1:-}" = api ] || exit 1
if [ "${2:-}" = -i ]; then           # gh api -i -X GET <path>: gh_rest
  k=$(printf '%s' "${5:-}" | tr -c 'A-Za-z0-9' '_')
  if [ -f "$MRBT/rest/$k" ]; then restpr --raw 200 "$(cat "$MRBT/rest/$k")"; exit 0; fi
  restpr --raw 404 '{"message":"Not Found"}'; exit 1
fi
flag=0; for a; do [ "$a" = --allow-escape-sequences ] && flag=1; done
case "$(cat "$MRBT/mode" 2>/dev/null)" in
  ok)      [ "$flag" = 1 ] && { cat "$MRBT/esc.log"; exit 0; }
           cat "$MRBT/refuse.txt" >&2; exit 1 ;;
  refuse)  cat "$MRBT/refuse.txt" >&2; exit 1 ;;
  404)     echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  410)     echo "gh: Gone (HTTP 410)" >&2; exit 1 ;;
  502)     echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
  empty)   exit 1 ;;
  near)    echo "invalid escape in request path" >&2; exit 1 ;;
  oldgh)   [ "$flag" = 1 ] && { echo "unknown flag: --allow-escape-sequences" >&2; exit 1; }
           cat "$MRBT/esc.log"; exit 0 ;;
  oldgone) [ "$flag" = 1 ] && { echo "unknown flag: --allow-escape-sequences" >&2; exit 1; }
           echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
exit 1
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$MRBT/curl-calls.txt"\nexit 1\n' > "$T/bin/curl"
chmod +x "$T/bin/gh" "$T/bin/curl"

# bytes <mode> — one _mrb_bytes call in a fresh subshell: rc, why, call log
bytes() {
  echo "$1" > "$T/mode"; : > "$T/gh-calls.txt"; rm -f "$T/out.bin"
  ( PATH="$T/bin:$PATH"; . "$DETECT"; _MRB_TMP="$T"; _MRB_BYTES_WHY=stale
    _mrb_bytes "repos/o/r/actions/jobs/1/logs" "$T/out.bin"; rc=$?
    printf '%s' "${_MRB_BYTES_WHY:-}" > "$T/why"; exit "$rc" )
  RC=$?; WHY=$(cat "$T/why"); CALLS=$(cat "$T/gh-calls.txt")
}

# ==== E1 / E1b: the flag lets the bytes through ================================
bytes ok
eq E1-rc "$RC" 0
cmp -s "$T/out.bin" "$T/esc.log" && ok || bad "E1-bytes: the out file is not the fixture log"
grep -q $'\033' "$T/out.bin" && ok || bad "E1-esc: no ESC byte kept"
eq E1-why "$WHY" ""
has E1b-flag "$CALLS" "--allow-escape-sequences"
eq E1b-one-call "$(grep -c . "$T/gh-calls.txt")" 1

# ==== E2 / E2b: gone is still 44 ===============================================
bytes 404; eq E2-rc "$RC" 44
bytes 410; eq E2b-rc "$RC" 44

# ==== E3: the refusal even with the flag gets its own rc and word ===============
bytes refuse
eq E3-rc "$RC" 76
eq E3-why "$WHY" "gh-refused: $REFUSE"

# ==== E4: near misses stay 75 ==================================================
bytes 502;   eq E4-502-rc "$RC" 75;   eq E4-502-why "$WHY" "gh: gh: Server Error (HTTP 502)"
bytes empty; eq E4-empty-rc "$RC" 75; eq E4-empty-why "$WHY" "gh: exit 1"
bytes near;  eq E4-near-rc "$RC" 75;  eq E4-near-why "$WHY" "gh: invalid escape in request path"

# ==== E5: a gh too old to know the flag ========================================
bytes oldgh
eq E5-rc "$RC" 0
cmp -s "$T/out.bin" "$T/esc.log" && ok || bad "E5-bytes: the bare retry wrote no log"
eq E5-two-calls "$(grep -c . "$T/gh-calls.txt")" 2
eq E5-second-bare "$(sed -n 2p "$T/gh-calls.txt")" "api repos/o/r/actions/jobs/1/logs"
eq E5-why "$WHY" ""
# E5b: the bare retry is judged on its own answer, not on "unknown flag"
bytes oldgone
eq E5b-rc "$RC" 44
eq E5b-two-calls "$(grep -c . "$T/gh-calls.txt")" 2

# ==== E6: the real detect, a flag episode whose job log gh refuses =============
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-09-01T00:00:00Z' GIT_COMMITTER_DATE='2026-09-01T00:00:00Z'
git init -q -b main "$T/repo" && echo 0 > "$T/repo/a" && git -C "$T/repo" add a \
  && git -C "$T/repo" commit -qm C0 || { echo "setup: git failed"; exit 1; }
RED=$(git -C "$T/repo" rev-parse HEAD)
mkdir -p "$T/h/flags" "$T/out"
printf 'sha=%s\nworkflow=Harness CI\npath=.github/workflows/harness-ci.yml\njob=Tests, traced (shard 1/4)\nrun=https://github.com/o/r/actions/runs/101\nreason=streak\n' "$RED" > "$T/h/flags/main-red-o-r"
rest() { printf '%s' "$2" > "$T/rest/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
rest "repos/o/r/actions/runs/101" "{\"id\":101,\"head_sha\":\"$RED\",\"head_branch\":\"main\",\"workflow_id\":7,\"name\":\"Harness CI\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\"}"
rest "repos/o/r/actions/runs/101/jobs?filter=latest&per_page=100" '{"total_count":1,"jobs":[{"id":555,"name":"Tests, traced (shard 1/4)","conclusion":"failure"}]}'
echo refuse > "$T/mode"; : > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"
( export PATH="$T/bin:$PATH" GH_ETAG=0 HARNESS="$T/h"; . "$PROBE"; . "$DETECT"
  mrb_detect_episodes o/r "$T/repo" "$T/out" ) 2> "$T/err"
eq E6-rc "$?" 75
eq E6-no-file "$(find "$T/out" -type f | wc -l | tr -d ' ')" 0
has E6-line "$(cat "$T/err")" "mrb-detect: o/r: job 555 log read failed rc=76 gh-refused: $REFUSE"
eq E6-last-line "$(grep '^mrb-detect: ' "$T/err" | tail -1)" "mrb-detect: o/r: job 555 log read failed rc=76 gh-refused: $REFUSE"
grep -q 'actions/jobs/555/logs.*--allow-escape-sequences' "$T/gh-calls.txt" && ok || bad "E6: the job-log read had no flag"
eq E6-no-curl "$(cat "$T/curl-calls.txt")" ""

# ==== W1-W5: the bisect's word follows the REST status =========================
H="$T/hh"
mkdir -p "$H/bin/lib" "$H/state" "$H/flags" "$H/logs" "$H/catalog" "$T/repos/cromford"
scratch_install_closure bin/main-red-bisect.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
printf '#!/bin/bash\n[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 0\n' > "$H/bin/jobs-client.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
echo local > "$H/state/box-name"
cat > "$T/fakes.sh" <<SH
F="$T"
mrb_detect_episodes() {
  echo "mrb-detect: example-org/cromford: job 555 log read failed rc=76 gh-refused: $REFUSE" >&2
  GH_REST_STATUS=\$(cat "\$F/http"); return 75
}
mrb_probe() { echo red; }
mrb_bisect() { echo "aborted - 0"; }
mrb_episode_still_red() { return 0; }
mrb_act_culprit() { return 0; }
mrb_act_notmerge() { return 0; }
SH
SLUG=example-org/cromford
word() { # word <case> <http> <want> <not-want>
  rm -f "$H/logs/main-red-bisect.log"; echo "$2" > "$T/http"
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    MAIN_RED_BISECT_FIXTURE="$T/fakes.sh" REPOS_ROOT="$T/repos" bash "$H/bin/main-red-bisect.sh" >"$T/wout" 2>&1
  local l; l=$(cat "$H/logs/main-red-bisect.log" 2>/dev/null)
  has "$1-word" "$l" "$SLUG $3 rc=75 http=$2 "
  hasnt "$1-not" "$l" "$4"
  has "$1-why" "$l" "why=mrb-detect: $SLUG: job 555 log read failed rc=76 gh-refused: "
}
word W1 200 log-read-failed forge-unreachable
word W2 204 log-read-failed forge-unreachable
word W3 000 forge-unreachable log-read-failed
word W4 502 forge-unreachable log-read-failed
word W5 429 forge-unreachable log-read-failed

echo "mrb-bytes-escape.bh-8223: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
