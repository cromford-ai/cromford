#!/bin/bash
# tests/onboard-canary-vendor-budget.bh-9442-test.sh — BH-9442, the
# scalable-tests budget (BH-7563 rule 6) for bin/onboard-canary.sh: a full
# canary cycle in the PR suite makes 0 vendor calls. The only vendor the lane
# reaches is GitHub, through bin/lib/gh-rest.sh (`gh api`). Settings go to a
# file-backed jobs client.
#
#   V1  --hold, then --tick to green, with the gh fake on PATH: 0 lines in
#       vendor.log (no real gh, no curl), the gate row reads released
#   V2  the same cycle with a tripwire gh (it logs `REAL gh <args>` and exits
#       1): the budget check reports red, so V1 is not vacuous
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-canary-vendor-budget.bh-9442-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

H="$T/h"; FX="$T/fx"; ROWS="$T/rows"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$FX" "$ROWS" "$T/stub"
cp "$DIR/bin/onboard-canary.sh" "$H/bin/"
# scratch-closure-allow: gh-rest.sh alone, on purpose: the closure of bin/onboard-canary.sh brings lane-gate.sh, gh-app-auth.sh and the gh-rest etag cache and quota ledger, which would read live knobs and carry cache state between cases
cp "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
case "\$1" in
  setting-get) [ -f "$ROWS/\$2" ] || { echo; exit 2; }; cat "$ROWS/\$2"; echo ;;
  setting-set) printf '%s' "\$3" > "$ROWS/\$2" ;;
  *) exit 2 ;;
esac
EOF
printf '#!/bin/bash\n[ "$2" = repo ] && { echo "Test/$1"; exit 0; }\nexit 0\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
# gh: the fake answers from FX when ONBOARD_TEST_GH_FAKE is set; without it,
# every call is a vendor call and is logged as one (the tripwire).
cat > "$T/stub/gh" <<EOF
#!/bin/bash
if [ -z "\${ONBOARD_TEST_GH_FAKE:-}" ]; then echo "REAL gh \$*" >> "$T/vendor.log"; exit 1; fi
shift; m=GET
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) m="\$2"; shift 2 ;; *) break ;; esac; done
k=\$(printf '%s %s' "\$m" "\$1" | tr -c 'A-Za-z0-9._-' '_')
[ -f "$FX/\$k" ] || { printf 'HTTP/1.1 404 X\r\n\r\n{}'; exit 1; }
printf 'HTTP/1.1 200 X\r\n\r\n'; cat "$FX/\$k"
EOF
printf '#!/bin/bash\necho "REAL curl $*" >> "%s/vendor.log"\nexit 7\n' "$T" > "$T/stub/curl"
chmod +x "$H/bin/"*.sh "$T/stub/"*

fx() { printf '%s' "$3" > "$FX/$(printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')"; }
P=vb; SH=0123456789abcdef0123456789abcdef01234567; BR=harness/onboard-canary-202701150800
fx GET "repos/Test/$P/pulls?state=open&per_page=100" '[]'
fx GET "repos/Test/$P" '{"default_branch":"main"}'
fx GET "repos/Test/$P/git/ref/heads/main" '{"object":{"sha":"b0"}}'
fx POST "repos/Test/$P/git/refs" '{}'
fx PUT "repos/Test/$P/contents/.harness/onboard-canary.md" "{\"commit\":{\"sha\":\"$SH\"}}"
fx POST "repos/Test/$P/pulls" "{\"number\":3,\"html_url\":\"https://github.com/Test/$P/pull/3\",\"head\":{\"sha\":\"$SH\",\"ref\":\"$BR\"}}"
fx GET "repos/Test/$P/pulls/3" "{\"state\":\"open\",\"head\":{\"sha\":\"$SH\",\"ref\":\"$BR\"}}"
fx GET "repos/Test/$P/commits/$SH/check-runs?per_page=100&page=1" '{"total_count":1,"check_runs":[{"id":1,"name":"build","status":"completed","conclusion":"success"}]}'
fx GET "repos/Test/$P/commits/$SH/status" '{"statuses":[]}'
fx PATCH "repos/Test/$P/pulls/3" '{}'
fx DELETE "repos/Test/$P/git/refs/heads/$BR" '{}'

cycle() { # cycle [env...] — one hold + tick on a clean state
  scratch_rm "$H/state/onboard-canary"; rm -f "$ROWS"/*; : > "$T/vendor.log"
  ( cd "$T" && for v in --hold --tick; do
      a=(--hold "$P"); [ "$v" = --tick ] && a=(--tick)
      env -u BUILDER_EXEC -u GH_TOKEN "$@" HARNESS="$H" ONBOARD_CANARY_NOW=1800000000 PATH="$T/stub:$PATH" \
        bash "$H/bin/onboard-canary.sh" "${a[@]}" >/dev/null 2>&1
    done )
}
budget_ok() { [ ! -s "$T/vendor.log" ]; }

# V1
cycle ONBOARD_TEST_GH_FAKE=1
budget_ok && ok "V1 0 vendor calls" || bad "V1 vendor calls: $(head -3 "$T/vendor.log")"
[ "$(cat "$ROWS/onboard.$P.canary_gate" 2>/dev/null)" = released ] && [ "$(jq -r .state "$ROWS/onboard.$P.canary" 2>/dev/null)" = green ] \
  && ok "V1 the cycle ran to green and released" || bad "V1 the cycle did not finish: $(ls "$ROWS") $(cat "$ROWS/onboard.$P.canary" 2>/dev/null)"

# V2
cycle
budget_ok && bad "V2 the tripwire gh must make the budget red" || ok "V2 tripwire: $(wc -l < "$T/vendor.log") real call(s) caught"

echo "onboard-canary-vendor-budget (BH-9442): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
