#!/bin/bash
# tests/verdict-status-identity.bh-9287-test.sh — BH-9287: which App writes the
# lead-verdict commit status, and when a failed write is an alert.
#
# A lane-run machine minted the status from its default App (the builders
# App, `statuses: null`), so GitHub answered 403 on every conductor publish,
# and mc_status_unpublished_alert paged once a day per repo even on a repo
# whose .mergify.yml never asks for the status. The text said to fix "the
# hub App", which was not the App that failed.
#
#   P1-P5   vs_publish mints from profile `status` when
#           env/github-app-status.env is readable, and only then; the
#           caller's GH_APP_PROFILE is back after the call
#   D1-D12  vs_mergify_names: which .mergify.yml lines name a context as a
#           success condition
#   N1-N3   vs_mergify_names when the file is unreadable or absent
#   G1-G4   the REAL bin/gh-token.sh --app-slug (scratch tree, a fixture RSA
#           key, a stub curl that answers GET /app by the JWT's iss)
#   A1-A10  mc_status_unpublished_alert: info line or alert, the App name,
#           and mc_enqueue_mergify (the production caller) passing its context
#   E1-E7   the REAL fly/lane-run-entrypoint.sh writes the status profile
#           from GH_APP_STATUS_ID + GH_APP_STATUS_PRIVATE_KEY
# 0 network calls: gh_rest, gh-token.sh, curl and the worker are stubs.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/verdict-status-identity.bh-9287-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || { echo "SKIP: jq or base64 missing"; exit 0; }
unset HARNESS_ENV_DIR GH_TOKEN GH_APP_PROFILE LEAD_VERDICT_CONTEXT
export ETC_HARNESS_ENV="$T/no-etc"

SHA=$(printf 'c%.0s' $(seq 40))
SLUG=example-org/bh9287-fixture
VS="$DIR/bin/lib/verdict-status.sh"

# yml_json <file-with-yml> — a contents API body, GitHub's shape (base64 in
# 60-column lines with \n, as the API sends it).
yml_json() { jq -nc --arg c "$(base64 -w 60 < "$1")" '{type:"file", encoding:"base64", content:($c + "\n")}'; }

# ============================================================================
# Part P — the profile vs_publish mints from.
# ============================================================================
echo "P1-P5: the mint profile"
P="$T/p"; mkdir -p "$P/h/bin" "$P/h/env" "$P/fx"
printf 'GH_APP_ID=9287001\n' > "$P/h/env/github-app.env"
cat > "$P/h/bin/gh-token.sh" <<EOF
#!/bin/bash
printf '%s|%s\n' "\${GH_APP_PROFILE-<unset>}" "\$*" >> "$P/fx/mint.log"
echo ghs_fixture_token_1
EOF
chmod +x "$P/h/bin/gh-token.sh"
out=$(
  export HARNESS="$P/h"
  lane_switch() { return 1; }
  gh_rest() { printf '%s\n' "$*" >> "$P/fx/gh.log"; GH_REST_STATUS=201; echo '{"id":1}'; }
  la_decide() { return 0; }
  # shellcheck source=bin/lib/verdict-status.sh
  . "$VS" || { echo "FAIL P0 verdict-status.sh did not load"; exit 1; }
  profs() { cut -d'|' -f1 "$P/fx/mint.log" 2>/dev/null | sort -u | paste -sd,; }
  # P1: the status profile is present.
  : > "$P/fx/mint.log"; printf 'GH_APP_ID=9287002\n' > "$P/h/env/github-app-status.env"
  vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(profs)" = status ] && [ -s "$P/fx/mint.log" ] && echo "ok P1 github-app-status.env present: rc 0, every mint used profile status" \
    || echo "FAIL P1 rc=$rc profiles='$(profs)'"
  # P2: absent -> today's path.
  rm -f "$P/h/env/github-app-status.env"; : > "$P/fx/mint.log"
  vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(profs)" = '<unset>' ] && echo "ok P2 no github-app-status.env: the minter saw no profile (today's path)" \
    || echo "FAIL P2 rc=$rc profiles='$(profs)'"
  # P3: present but unreadable.
  if [ "$(id -u)" -ne 0 ]; then
    printf 'GH_APP_ID=9287002\n' > "$P/h/env/github-app-status.env"; chmod 000 "$P/h/env/github-app-status.env"; : > "$P/fx/mint.log"
    vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null
    [ "$(profs)" = '<unset>' ] && echo "ok P3 an unreadable status file: no profile" || echo "FAIL P3 profiles='$(profs)'"
    chmod 600 "$P/h/env/github-app-status.env"; rm -f "$P/h/env/github-app-status.env"
  else
    echo "ok P3 SKIPPED as root: root reads a mode-000 file, so the unreadable case cannot be built here"
  fi
  # P4: the caller's GH_APP_PROFILE comes back (set + exported, and unset).
  printf 'GH_APP_ID=9287002\n' > "$P/h/env/github-app-status.env"
  export GH_APP_PROFILE=builders
  vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null
  d=$(declare -p GH_APP_PROFILE 2>&1)
  [ "$d" = 'declare -x GH_APP_PROFILE="builders"' ] && echo "ok P4 a caller's exported builders profile is back after the call" || echo "FAIL P4 after: $d"
  unset GH_APP_PROFILE
  vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null
  if declare -p GH_APP_PROFILE >/dev/null 2>&1; then echo "FAIL P4b an unset GH_APP_PROFILE is set after the call: $(declare -p GH_APP_PROFILE)"
  else echo "ok P4b an unset GH_APP_PROFILE is still unset after the call"; fi
  # P5: no status file, a caller's builders profile reaches the minter unchanged.
  rm -f "$P/h/env/github-app-status.env"; : > "$P/fx/mint.log"
  export GH_APP_PROFILE=builders
  vs_publish "$SLUG" "$SHA" success "fixture" 2>/dev/null
  [ "$(profs)" = builders ] && echo "ok P5 no status file: the caller's builders profile reaches the minter (byte for byte today)" \
    || echo "FAIL P5 profiles='$(profs)'"
  unset GH_APP_PROFILE
  # P6: vs_status_profile is the contract name the entrypoint writes.
  [ "$(vs_status_profile 2>/dev/null)" = status ] && echo "ok P6 vs_status_profile prints status" || echo "FAIL P6 vs_status_profile: '$(vs_status_profile 2>&1)'"
)
while IFS= read -r l; do
  case "$l" in "ok "*) ok "${l#ok }" ;; "FAIL "*) bad "${l#FAIL }" ;; esac
done <<<"$out"

# ============================================================================
# Part D/N — vs_mergify_names over .mergify.yml bodies.
# ============================================================================
echo "D1-D12, N1-N3: does .mergify.yml name the context"
D="$T/d"; mkdir -p "$D"
out=$(
  export HARNESS="$D/h"; mkdir -p "$D/h/env"
  gh_auth_for() { return 1; }
  la_decide() { return 0; }
  # MODE: json (serve $D/body), rc75, rc44, raw (serve $D/body as is).
  gh_rest() {
    printf '%s\n' "$*" >> "$D/gh.log"
    case "$(cat "$D/mode")" in
      json|raw) GH_REST_STATUS=200; cat "$D/body" ;;
      rc75) GH_REST_STATUS=000; GH_REST_REASON=network; return 75 ;;
      rc44) GH_REST_STATUS=404; return 44 ;;
    esac
  }
  # shellcheck source=bin/lib/verdict-status.sh
  . "$VS" || { echo "FAIL D0 verdict-status.sh did not load"; exit 1; }
  # m <want rc> <label> <ctx> <yml body lines...>
  m() {
    local want="$1" label="$2" ctx="$3" rc=0; shift 3
    printf '%s\n' "$@" > "$D/yml"; yml_json "$D/yml" > "$D/body"; echo json > "$D/mode"
    vs_mergify_names "$SLUG" "$ctx" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want" ] && echo "ok $label: rc $rc" || echo "FAIL $label: want rc $want, got $rc"
  }
  Q='queue_rules:'; N='  - name: default'; QC='    queue_conditions:'
  m 0 "D1 - check-success=lead-verdict" lead-verdict "$Q" "$N" "$QC" '      - check-success=lead-verdict'
  m 0 "D2 - \"check-success=lead-verdict\"" lead-verdict "$Q" "$N" "$QC" '      - "check-success=lead-verdict"'
  m 0 "D3 check-success~=^(lead-verdict|harness-verdict)\$ (cromford's form)" lead-verdict "$Q" "$N" "$QC" '      - check-success~=^(lead-verdict|harness-verdict)$'
  m 0 "D4 - status-success=lead-verdict" lead-verdict "$Q" "$N" "$QC" '      - status-success=lead-verdict'
  m 0 "D5 the condition under pull_request_rules:" lead-verdict 'pull_request_rules:' '  - name: queue' '    conditions:' '      - check-success=lead-verdict' '      - label = merge-queue'
  m 0 "D6 harness-verdict in the D3 line" harness-verdict "$Q" "$N" "$QC" '      - check-success~=^(lead-verdict|harness-verdict)$'
  m 1 "D7 no such line (project-6's shape)" lead-verdict "$Q" "$N" "$QC" '      - check-success=ci' '      - "#approved-reviews-by>=1"' 'pull_request_rules:' '  - name: queue' '    conditions:' '      - label = merge-queue'
  m 1 "D8 a commented condition" lead-verdict "$Q" "$N" "$QC" '      # - check-success=lead-verdict' '      - check-success=ci'
  m 1 "D8b a commented condition at column 0" lead-verdict "$Q" "$N" "$QC" '# - check-success=lead-verdict' '      - check-success=ci'
  m 1 "D9 a longer name (lead-verdict-extra)" lead-verdict "$Q" "$N" "$QC" '      - check-success=lead-verdict-extra'
  m 1 "D10 a negated -check-success=" lead-verdict "$Q" "$N" "$QC" '      - -check-success=lead-verdict' '      - check-success=ci'
  m 1 "D11 a check-failure veto, plain and negated" lead-verdict "$Q" "$N" "$QC" '      - check-failure=lead-verdict' '      - -check-failure=lead-verdict'
  m 1 "D12 the name only in a trailing comment" lead-verdict "$Q" "$N" "$QC" '      - check-success=ci  # lead-verdict later'
  m 0 "D13 check-success-or-neutral=lead-verdict" lead-verdict "$Q" "$N" "$QC" '      - check-success-or-neutral=lead-verdict'
  m 1 "D14 a yml naming only lead-verdict, asked for harness-verdict" harness-verdict "$Q" "$N" "$QC" '      - check-success=lead-verdict'
  # N1-N3: unreadable or absent.
  echo rc75 > "$D/mode"; rc=0; vs_mergify_names "$SLUG" lead-verdict >/dev/null 2>&1 || rc=$?
  [ "$rc" = 75 ] && echo "ok N1 gh_rest rc 75: rc 75" || echo "FAIL N1 want 75, got $rc"
  echo rc44 > "$D/mode"; rc=0; vs_mergify_names "$SLUG" lead-verdict >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] && echo "ok N2 a 404 (no .mergify.yml): rc 1" || echo "FAIL N2 want 1, got $rc"
  echo raw > "$D/mode"; echo '{}' > "$D/body"; rc=0; vs_mergify_names "$SLUG" lead-verdict >/dev/null 2>&1 || rc=$?
  [ "$rc" = 75 ] && echo "ok N3 a body with no .content: rc 75" || echo "FAIL N3 want 75, got $rc"
  grep -qx "GET repos/$SLUG/contents/.mergify.yml" "$D/gh.log" && echo "ok N4 the read is GET repos/<slug>/contents/.mergify.yml" \
    || echo "FAIL N4 gh.log: $(head -2 "$D/gh.log")"
)
while IFS= read -r l; do
  case "$l" in "ok "*) ok "${l#ok }" ;; "FAIL "*) bad "${l#FAIL }" ;; esac
done <<<"$out"

# ============================================================================
# Part G — the REAL bin/gh-token.sh --app-slug.
# ============================================================================
echo "G1-G4: gh-token.sh --app-slug"
if command -v openssl >/dev/null 2>&1; then
  G="$T/g"; mkdir -p "$G/env" "$G/state" "$G/logs" "$G/flags" "$T/gbin"
  scratch_install_closure bin/gh-token.sh "$G" >/dev/null || bad "G0 install the gh-token.sh closure"
  openssl genrsa -out "$G/env/github-app.pem" 2048 2>/dev/null
  cp "$G/env/github-app.pem" "$G/env/github-app-status.pem"
  printf 'GH_APP_ID=9287001\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$G/env/github-app.pem" > "$G/env/github-app.env"
  printf 'GH_APP_ID=9287002\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$G/env/github-app-status.pem" > "$G/env/github-app-status.env"
  # The stub curl answers GET /app by the JWT's iss: 9287001 -> the builders
  # App, 9287002 -> the hub App. SLUG_MODE=none answers {}.
  cat > "$T/gbin/curl" <<'SH'
#!/bin/bash
URL=""; JWT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in "Authorization: Bearer "*) JWT="${2#Authorization: Bearer }" ;; esac; shift 2 ;;
    -d|-X|-m) shift 2 ;; -*) shift ;; *) URL="$1"; shift ;;
  esac
done
printf '%s\n' "$URL" >> "$CURL_LOG"
p="${JWT#*.}"; p="${p%%.*}"; p=$(printf '%s' "$p" | tr '_-' '/+')
while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
iss=$(printf '%s' "$p" | base64 -d 2>/dev/null | jq -r '.iss // empty' 2>/dev/null)
case "$URL" in
  */app)
    [ "${SLUG_MODE:-ok}" = none ] && { echo '{}'; exit 0; }
    case "$iss" in
      9287001) echo '{"id":9287001,"slug":"cromford-builders"}' ;;
      9287002) echo '{"id":9287002,"slug":"cromford"}' ;;
      *) echo '{"message":"fixture: unknown iss"}' ;;
    esac ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$T/gbin/curl"
  gs() { env PATH="$T/gbin:$PATH" HARNESS="$G" HARNESS_ENV_DIR="$G/env" GH_APP_API_BASE="http://api.test" CURL_LOG="$T/curl.log" "$@" 2>/dev/null; }
  : > "$T/curl.log"
  o=$(gs bash "$G/bin/gh-token.sh" --app-slug); rc=$?
  [ "$rc" = 0 ] && [ "$o" = cromford-builders ] && ok "G1 --app-slug prints the default App's slug (cromford-builders)" \
    || bad "G1 rc=$rc out='$o'"
  grep -qx 'http://api.test/app' "$T/curl.log" && ok "G1b the slug comes from GET /app" || bad "G1b curl log: $(cat "$T/curl.log")"
  o=$(gs SLUG_MODE=none bash "$G/bin/gh-token.sh" --app-slug); rc=$?
  [ "$rc" = 1 ] && [ -z "$o" ] && ok "G2 GET /app with no slug: rc 1, nothing printed" || bad "G2 rc=$rc out='$o'"
  o=$(gs bash "$G/bin/gh-token.sh" --app status --app-slug); rc=$?
  [ "$rc" = 0 ] && [ "$o" = cromford ] && ok "G4 --app status --app-slug signs with the status App (cromford)" \
    || bad "G4 rc=$rc out='$o'"
  mv "$G/env/github-app.env" "$G/env/off.env"; : > "$T/curl.log"
  o=$(gs bash "$G/bin/gh-token.sh" --app-slug); rc=$?
  [ "$rc" = 1 ] && [ -z "$o" ] && [ ! -s "$T/curl.log" ] && ok "G3 no App configured: rc 1, nothing printed, no curl call" \
    || bad "G3 rc=$rc out='$o' curl=$(cat "$T/curl.log")"
  mv "$G/env/off.env" "$G/env/github-app.env"
  ls "$G/state" > "$T/g-state" 2>/dev/null
  [ ! -s "$T/g-state" ] && ok "G5 --app-slug writes no token cache" || bad "G5 state/ holds: $(cat "$T/g-state")"
else
  echo "  SKIP G1-G5: openssl missing"
fi

# ============================================================================
# Part A — mc_status_unpublished_alert, and its caller mc_enqueue_mergify.
# ============================================================================
echo "A1-A10: info line or alert"
A="$T/a"; mkdir -p "$A/h/bin" "$A/h/env" "$A/h/state/merge-conductor" "$A/fx"
cat > "$A/h/bin/gh-token.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$A/fx/slug-calls"
[ -e "$A/fx/slug-fail" ] && exit 1
case "\$*" in *--app-slug*) echo cromford-builders; exit 0 ;; esac
exit 1
EOF
chmod +x "$A/h/bin/gh-token.sh"
printf '%s\n' 'queue_rules:' '  - name: default' '    queue_conditions:' '      - check-success=ci' \
  'pull_request_rules:' '  - name: queue' '    conditions:' '      - label = merge-queue' > "$A/project-6.yml"
printf '%s\n' 'queue_rules:' '  - name: default' '    queue_conditions:' '      - check-success=lead-verdict' > "$A/names.yml"
out=$(
  export HARNESS="$A/h" MC_STATE_DIR="$A/h/state/merge-conductor" MC_LOCK_DIR="$A/locks" JOBS_URL=http://192.0.2.1 HARNESS_SECRET=fixture-secret
  date() { echo 20261109; }
  setting_get() { return 2; }
  vd_standing() { return 1; }
  lead_carry() { return 1; }
  gh_auth_for() { return 0; }
  la_decide() { return 0; }
  # YML: project-6|names|rc75; POST answers 403.
  gh_rest() {
    printf '%s\n' "$*" >> "$A/fx/gh.log"
    case "$1 $2" in
      "GET repos/"*"/contents/.mergify.yml")
        case "$(cat "$A/fx/yml")" in
          rc75) GH_REST_STATUS=000; return 75 ;;
          *) GH_REST_STATUS=200; yml_json "$A/$(cat "$A/fx/yml").yml" ;;
        esac ;;
      "GET repos/"*"/commits/"*"/status") GH_REST_STATUS=200; echo '{"state":"pending","statuses":[]}' ;;
      POST*) GH_REST_STATUS=403; GH_REST_REASON=forbidden; GH_REST_MESSAGE="Resource not accessible by integration"; return 1 ;;
      *) GH_REST_STATUS=404; return 44 ;;
    esac
  }
  # shellcheck source=bin/lib/verdict-status.sh
  . "$VS" || exit 91
  # shellcheck source=bin/lib/lead-required.sh
  . "$DIR/bin/lib/lead-required.sh" || exit 92
  MC_H="$A/h"
  # shellcheck source=bin/lib/mc/classify.sh
  . "$DIR/bin/lib/mc/classify.sh" || exit 93
  # shellcheck source=bin/lib/mc/settle.sh
  . "$DIR/bin/lib/mc/settle.sh" || exit 94
  # shellcheck source=bin/lib/mc/queue.sh
  . "$DIR/bin/lib/mc/queue.sh" || exit 95
  mc_log() { printf '%s\n' "$*" >> "$A/fx/log"; }
  mc_alert() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$A/fx/alerts"; }
  mc_attempt_has() { grep -qxF "$1" "$A/fx/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$A/fx/attempts"; }
  mc_la_decide() { return 0; }
  n() { if [ -f "$1" ]; then grep -c "${2:-.}" "$1"; else echo 0; fi; }
  reset() { rm -f "$A/fx/log" "$A/fx/alerts" "$A/fx/attempts" "$A/fx/slug-calls" "$A/fx/slug-fail" "$A/fx/gh.log"; scratch_rm "$A/locks"; _LR_MEMO=""; echo "$1" > "$A/fx/yml"; }
  WHY="vs_publish: lead-verdict=success NOT published on $SLUG@cccccccccccc (HTTP 403, forbidden; token=app; GitHub: Resource not accessible by integration)"
  U="https://github.com/$SLUG/pull/41"

  # A1 project-6's shape: no condition names lead-verdict.
  reset project-6
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  [ "$(n "$A/fx/alerts")" = 0 ] && echo "ok A1 a yml that names no lead-verdict condition: 0 alerts" || echo "FAIL A1 $(n "$A/fx/alerts") alert(s): $(head -c 300 "$A/fx/alerts")"
  [ "$(n "$A/fx/log" '^VS_UNPUBLISHED_INFO ')" = 1 ] && grep -q '^VS_UNPUBLISHED_INFO .*lead-verdict.*No alert' "$A/fx/log" \
    && echo "ok A1b exactly 1 VS_UNPUBLISHED_INFO line naming lead-verdict" || echo "FAIL A1b log: $(cat "$A/fx/log" 2>/dev/null)"
  [ "$(n "$A/fx/attempts")" = 0 ] && [ "$(n "$A/fx/slug-calls")" = 0 ] && echo "ok A1c the info path writes no ledger mark and makes no GET /app" \
    || echo "FAIL A1c attempts=$(n "$A/fx/attempts") slug-calls=$(n "$A/fx/slug-calls")"
  # A2 / A4 a yml that names it.
  reset names
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  txt=$(cut -f3 "$A/fx/alerts" 2>/dev/null)
  [ "$(n "$A/fx/alerts")" = 1 ] && grep -q 'cromford-builders' <<<"$txt" && grep -q 'Commit statuses' <<<"$txt" \
    && echo "ok A2 a naming yml: 1 alert that names cromford-builders and Commit statuses" || echo "FAIL A2 $(n "$A/fx/alerts") alert(s): $txt"
  grep -q 'names lead-verdict' <<<"$txt" && echo "ok A2b the alert says the yml names lead-verdict" || echo "FAIL A2b text: $txt"
  [ "$(cat "$A/fx/attempts" 2>/dev/null)" = "status-unpublished $SLUG 20261109" ] && echo "ok A2c the ledger mark is today's shape" \
    || echo "FAIL A2c attempts: $(cat "$A/fx/attempts" 2>/dev/null)"
  if grep -q 'hub App' <<<"$txt"; then echo "FAIL A4 the alert still says 'hub App': $txt"; else echo "ok A4 the alert text has no 'hub App'"; fi
  # A3 a second failure the same day.
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  [ "$(n "$A/fx/alerts")" = 1 ] && [ "$(n "$A/fx/slug-calls")" = 1 ] && echo "ok A3 a second failure the same day: still 1 alert, no second --app-slug call" \
    || echo "FAIL A3 alerts=$(n "$A/fx/alerts") slug-calls=$(n "$A/fx/slug-calls")"
  # A5 the yml cannot be read.
  reset rc75
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  txt=$(cut -f3 "$A/fx/alerts" 2>/dev/null)
  [ "$(n "$A/fx/alerts")" = 1 ] && grep -q 'could not be read' <<<"$txt" && [ "$(n "$A/fx/log" '^VS_UNPUBLISHED_INFO ')" = 0 ] \
    && echo "ok A5 an unreadable yml: 1 alert that says 'could not be read', no info line" || echo "FAIL A5 alerts=$(n "$A/fx/alerts") text=$txt log=$(cat "$A/fx/log" 2>/dev/null)"
  # A6 the failed context is harness-verdict; the yml names lead-verdict only.
  reset names
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" harness-verdict
  [ "$(n "$A/fx/alerts")" = 0 ] && grep -q '^VS_UNPUBLISHED_INFO .*harness-verdict' "$A/fx/log" \
    && echo "ok A6 harness-verdict failed, the yml names lead-verdict only: info line, 0 alerts" || echo "FAIL A6 alerts=$(n "$A/fx/alerts") log=$(cat "$A/fx/log" 2>/dev/null)"
  # A8 GET /app does not answer: the App is 'unnamed', never invented.
  reset names; : > "$A/fx/slug-fail"
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  txt=$(cut -f3 "$A/fx/alerts" 2>/dev/null)
  [ "$(n "$A/fx/alerts")" = 1 ] && grep -q 'unnamed (GET /app did not answer)' <<<"$txt" && ! grep -q 'cromford' <<<"$txt" \
    && echo "ok A8 --app-slug fails: the alert says unnamed and names no App" || echo "FAIL A8 text: $txt"
  # A9 a box with the status profile asks for the status App's name.
  reset names; printf 'GH_APP_ID=9287002\n' > "$A/h/env/github-app-status.env"
  mc_status_unpublished_alert "$SLUG" "$U" "$WHY" lead-verdict
  [ "$(cat "$A/fx/slug-calls" 2>/dev/null)" = "--app status --app-slug" ] && echo "ok A9 with the status profile: gh-token.sh --app status --app-slug" \
    || echo "FAIL A9 slug-calls: $(cat "$A/fx/slug-calls" 2>/dev/null)"
  rm -f "$A/h/env/github-app-status.env"
  # A10 the production caller: mc_enqueue_mergify, a 403 on the POST, a
  # builder-only clearance (harness-verdict) on project-6's shape.
  prr_write() { return 0; }
  mc_mergify_ask_file() { echo "$A/fx/ask"; }
  mc_mergify_ask_due() { return 1; }
  mc_queue_state() { echo queued; }
  mc_mergify_witness() { return 0; }
  qp_enqueue_step() { return 0; }; qff_enqueue_step() { return 0; }; qr_enqueue_step() { return 0; }
  lsr_dismiss_on_enqueue() { return 0; }
  reset project-6
  mc_enqueue_mergify "$SLUG" "$U" "$SHA" >/dev/null 2>"$A/fx/enq.err"
  [ "$(n "$A/fx/alerts")" = 0 ] && grep -q "^VS_UNPUBLISHED_INFO $SLUG: the harness-verdict status" "$A/fx/log" \
    && echo "ok A10 mc_enqueue_mergify: a 403 on project-6's shape gives the harness-verdict info line, 0 alerts" \
    || echo "FAIL A10 alerts=$(n "$A/fx/alerts") log=$(cat "$A/fx/log" 2>/dev/null)"
  # A10c the caller passes the context that failed: harness-verdict on a yml
  # that names lead-verdict only is an info line, not an alert.
  reset names
  mc_enqueue_mergify "$SLUG" "$U" "$SHA" >/dev/null 2>>"$A/fx/enq.err"
  [ "$(n "$A/fx/alerts")" = 0 ] && grep -q "^VS_UNPUBLISHED_INFO $SLUG: the harness-verdict status" "$A/fx/log" \
    && echo "ok A10c mc_enqueue_mergify passes harness-verdict: a yml naming lead-verdict only gives the info line" \
    || echo "FAIL A10c alerts=$(n "$A/fx/alerts") log=$(cat "$A/fx/log" 2>/dev/null)"
  reset names
  vd_standing() { printf 'MERGE\tlead\t12\t2026-11-04T08:00:00Z\t-\t-\n'; }
  mc_enqueue_mergify "$SLUG" "$U" "$SHA" >/dev/null 2>>"$A/fx/enq.err"
  [ "$(n "$A/fx/alerts")" = 1 ] && grep -q 'the lead-verdict commit status' "$A/fx/alerts" \
    && echo "ok A10b mc_enqueue_mergify: a lead MERGE, a 403 and a naming yml: 1 lead-verdict alert" \
    || echo "FAIL A10b alerts=$(n "$A/fx/alerts") $(cat "$A/fx/alerts" 2>/dev/null) log=$(tail -3 "$A/fx/log" 2>/dev/null)"
)
rc=$?
[ "$rc" = 0 ] || bad "A0 the conductor modules did not load (rc $rc)"
while IFS= read -r l; do
  case "$l" in "ok "*) ok "${l#ok }" ;; "FAIL "*) bad "${l#FAIL }" ;; esac
done <<<"$out"

# ============================================================================
# Part E — the REAL fly/lane-run-entrypoint.sh.
# ============================================================================
echo "E1-E7: the lane-run machine gets the status profile"
E="$T/e"; mkdir -p "$E/bin/lib" "$E/env" "$T/home"
( cd "$DIR" && scratch_install_closure fly/lane-run-entrypoint.sh "$E" ) >/dev/null 2>&1 || bad "E0 install the entrypoint closure"
cat > "$E/bin/lane-run-worker.sh" <<EOF
#!/bin/bash
env | cut -d= -f1 | LC_ALL=C sort > "$T/worker-env"
exit 0
EOF
chmod +x "$E/bin/lane-run-worker.sh"
PEM=$'-----BEGIN FIXTURE KEY-----\nfixture-status-key-line\n-----END FIXTURE KEY-----'
ep() { # ep [VAR=value...]; echoes rc
  rm -f "$E/env/github-app-status.env" "$E/env/github-app-status.pem" "$E/env/github-app.env" "$E/env/github-app.pem" "$T/worker-env"
  env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" HARNESS_ENV_DIR="$E/env" ETC_HARNESS_ENV="$T/no-etc" \
    HARNESS_SECRET=fixture-hs JOBS_URL=http://192.0.2.1 FLY_MACHINE_ID=fixture-mid "$@" \
    bash "$E/fly/lane-run-entrypoint.sh" > "$T/ep.out" 2>&1
  echo $?
}
mode() { stat -c %a "$1" 2>/dev/null; }
rc=$(ep GH_APP_ID=9287001 GH_APP_PRIVATE_KEY=fixture-builders-pem GH_APP_INSTALLATION_example-org=9287100 \
        GH_APP_STATUS_ID=9287002 GH_APP_STATUS_PRIVATE_KEY="$PEM")
[ "$rc" = 0 ] && [ "$(mode "$E/env/github-app-status.env")" = 600 ] && [ "$(mode "$E/env/github-app-status.pem")" = 600 ] \
  && ok "E1 both status secrets set: github-app-status.env and .pem, mode 600" || bad "E1 rc=$rc env=$(mode "$E/env/github-app-status.env") pem=$(mode "$E/env/github-app-status.pem") $(cat "$T/ep.out")"
# E3 the round-trip: the reader sources the file.
got=$( set -a; . "$E/env/github-app-status.env" 2>/dev/null; set +a; printf '%s|%s' "${GH_APP_ID:-}" "${GH_APP_PRIVATE_KEY_FILE:-}" )
[ "$got" = "9287002|$E/env/github-app-status.pem" ] && [ "$(cat "$E/env/github-app-status.pem" 2>/dev/null)" = "$PEM" ] \
  && ok "E3 the env file sources to GH_APP_ID=9287002 and a PEM with the fixture text" || bad "E3 got '$got'"
st=$(cat "$E/env/github-app-status.env" 2>/dev/null)
if grep -q 'GH_APP_INSTALLATION_' <<<"$st"; then bad "E6 the status env carries an installation id of the default App: $st"
else ok "E6 the status env carries no GH_APP_INSTALLATION_* (the JWT lookup finds its own)"; fi
hub=$(cat "$E/env/github-app.env" 2>/dev/null)
grep -qx 'GH_APP_ID=9287001' <<<"$hub" && ! grep -q '9287002' <<<"$hub" && ok "E5 github-app.env is the default App, unchanged" || bad "E5 github-app.env: $hub"
we=$(cat "$T/worker-env" 2>/dev/null)
if [ -z "$we" ]; then bad "E4 the worker did not run"
elif grep -qx 'GH_APP_STATUS_PRIVATE_KEY' <<<"$we" || grep -qx 'GH_APP_PRIVATE_KEY' <<<"$we"; then bad "E4 a private key reached the worker env"
else ok "E4 the worker's env has no GH_APP_STATUS_PRIVATE_KEY"; fi
# E2 only one of the two.
rc=$(ep GH_APP_STATUS_ID=9287002)
[ "$rc" = 0 ] && [ ! -e "$E/env/github-app-status.env" ] && [ ! -e "$E/env/github-app-status.pem" ] \
  && ok "E2 only GH_APP_STATUS_ID: no status file" || bad "E2 rc=$rc"
rc=$(ep GH_APP_STATUS_PRIVATE_KEY="$PEM")
[ "$rc" = 0 ] && [ ! -e "$E/env/github-app-status.env" ] && [ ! -e "$E/env/github-app-status.pem" ] \
  && ok "E2b only GH_APP_STATUS_PRIVATE_KEY: no status file" || bad "E2b rc=$rc"
we=$(cat "$T/worker-env" 2>/dev/null)
if grep -qx 'GH_APP_STATUS_PRIVATE_KEY' <<<"$we"; then bad "E4b a lone status key reached the worker env"; else ok "E4b a lone status key is unset before the worker"; fi
# E7 a write failure: exit 78, one line naming the file.
rc=$( rm -f "$E/env/github-app-status.pem"; mkdir -p "$E/env/github-app-status.pem"
  env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" HARNESS_ENV_DIR="$E/env" ETC_HARNESS_ENV="$T/no-etc" \
    HARNESS_SECRET=fixture-hs JOBS_URL=http://192.0.2.1 FLY_MACHINE_ID=fixture-mid GH_APP_STATUS_ID=9287002 GH_APP_STATUS_PRIVATE_KEY="$PEM" \
    bash "$E/fly/lane-run-entrypoint.sh" > "$T/ep.out" 2>&1; echo $? )
rmdir "$E/env/github-app-status.pem" 2>/dev/null
o=$(cat "$T/ep.out")
[ "$rc" = 78 ] && grep -q 'cannot write .*github-app-status.pem' <<<"$o" && ! grep -q 'fixture-status-key-line' <<<"$o" \
  && ok "E7 a write failure: exit 78, one line naming the file, no key text" || bad "E7 rc=$rc out=$o"

echo
echo "verdict-status-identity: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
