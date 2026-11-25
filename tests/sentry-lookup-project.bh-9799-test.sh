#!/bin/bash
# tests/sentry-lookup-project.bh-9799-test.sh — BH-9799 T1/T2: bin/sentry-lookup.sh
# "<terms>" [project-slug] reads the project's Sentry source from
# catalog/signal-sources.d/<project>.json (bin/lib/signal-source.sh). A project
# with no row keeps SENTRY_ORG / SENTRY_API_TOKEN.
#
# A fake `curl` first on PATH logs the URL and the Authorization header to
# $FX/curl.log and answers $FX/answer.json. 0 real network calls.
#
#   L1  project-6-os (the real seed row): /organizations/project-6-llc/issues/,
#       project=project-6-os, Bearer <SENTRY_MK_API_TOKEN>
#   L2  project-5 (no row): operator, the global token
#   L3  the output line format is unchanged
#   L4  SENTRY_MK_API_TOKEN unset, no env file: one notice line, rc 0, 0 calls
#   L5  the token only in $H/env/project-6-os.env (quoted, export form)
#   L6  an invalid row (beta.json says project alpha): one notice, rc 0, 0 calls
#   L7  the token is on neither stdout nor stderr; a token in a title is masked
#   R   the seed row holds env NAMES only
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/sentry-lookup-project.bh-9799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "sentry-lookup-project: jq is required"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

for f in "$DIR/bin/sentry-lookup.sh" "$DIR/bin/lib/signal-source.sh" "$DIR/catalog/signal-sources.d/project-6-os.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

H="$T/h"; export FX="$T/fx"
mkdir -p "$H/env" "$H/catalog" "$T/fakebin" "$FX"
scratch_install_closure bin/sentry-lookup.sh "$H" >/dev/null || bad "closure install failed"
cp -r "$DIR/catalog/signal-sources.d" "$H/catalog/" 2>/dev/null

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
out=""; prev=""; auth=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -H) case "$a" in Authorization:*) auth="$a" ;; esac ;; esac
  prev="$a"
done
url="${!#}"
printf 'URL %s\nAUTH %s\nARGV %s\n' "$url" "$auth" "$*" >> "$FX/curl.log"
if [ -n "$out" ]; then cat "$FX/answer.json" > "$out"; else cat "$FX/answer.json"; fi
exit 0
SH
chmod +x "$T/fakebin/curl"

MK_TOK="mk-sentry-fixture-token-1"
GL_TOK="global-sentry-fixture-token-1"
jq -nc '[{shortId: "project-6-os-24", count: "43", lastSeen: "2026-11-17T10:00:00Z", title: "URIError: URI malformed", permalink: "https://sentry.example.com/issues/24/"}]' > "$FX/answer.json"

run() { # run <env...> -- <args...>
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  rm -f "$FX/curl.log"
  env -u SENTRY_MK_API_TOKEN -u SENTRY_API_TOKEN -u SENTRY_ORG -u HARNESS_ENV_DIR \
    HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 "${e[@]}" \
    bash "$H/bin/sentry-lookup.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
calls() { if [ -f "$FX/curl.log" ]; then grep -c '^URL ' "$FX/curl.log"; else echo 0; fi; }
url()  { sed -n 's/^URL //p' "$FX/curl.log" 2>/dev/null | head -1; }
auth() { sed -n 's/^AUTH //p' "$FX/curl.log" 2>/dev/null | head -1; }

# ── L1: project-6-os uses its own org and token ─────────────────────────────
run SENTRY_MK_API_TOKEN="$MK_TOK" SENTRY_API_TOKEN="$GL_TOK" -- "URIError" project-6-os
check "L1 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "L1 one call ($(calls))" '[ "$(calls)" = 1 ]'
check "L1 org project-6-llc [$(url)]" '[[ "$(url)" == https://sentry.io/api/0/organizations/project-6-llc/issues/\?* ]]'
check "L1 project=project-6-os [$(url)]" '[[ "$(url)" == *"&project=project-6-os" ]]'
check "L1 the project token [$(auth)]" '[ "$(auth)" = "Authorization: Bearer $MK_TOK" ]'

# ── L3: the output line format is unchanged ─────────────────────────────────
check "L3 output line [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "project-6-os-24  events=43  last=2026-11-17T10:00:00Z  URIError: URI malformed  https://sentry.example.com/issues/24/" ]'

# ── L2: a project with no row keeps the global org and token ────────────────
run SENTRY_MK_API_TOKEN="$MK_TOK" SENTRY_API_TOKEN="$GL_TOK" -- "x" project-5
check "L2 org operator [$(url)]" '[[ "$(url)" == https://sentry.io/api/0/organizations/operator/issues/\?* ]]'
check "L2 project=project-5" '[[ "$(url)" == *"&project=project-5" ]]'
check "L2 the global token [$(auth)]" '[ "$(auth)" = "Authorization: Bearer $GL_TOK" ]'
# No slug at all: the global path, as before.
run SENTRY_API_TOKEN="$GL_TOK" -- "x"
check "L2 no slug: operator, global token" '[[ "$(url)" == */organizations/operator/issues/\?* ]] && [ "$(auth)" = "Authorization: Bearer $GL_TOK" ]'
run -- "x"
check "L2 no slug, no global token: the old notice" '[ "$(cat "$T/out")" = "(sentry lookup unavailable — SENTRY_API_TOKEN unset)" ] && [ "$(calls)" = 0 ]'

# ── L4: the project token unset, no env file ────────────────────────────────
run SENTRY_API_TOKEN="$GL_TOK" -- "URIError" project-6-os
check "L4 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "L4 exactly one line [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(sentry lookup unavailable — SENTRY_MK_API_TOKEN unset for project-6-os)" ]'
check "L4 no call ($(calls))" '[ "$(calls)" = 0 ]'

# ── L5: the token only in $H/env/project-6-os.env ───────────────────────────
printf 'SENTRY_MK_ORG=project-6-llc\nexport SENTRY_MK_API_TOKEN="%s"\nOTHER=$(touch %s/sourced)\n' "$MK_TOK-env" "$T" > "$H/env/project-6-os.env"
run -- "URIError" project-6-os
check "L5 export+quoted form read [$(auth)]" '[ "$(auth)" = "Authorization: Bearer $MK_TOK-env" ]'
check "L5 the env file is parsed, never sourced" '[ ! -e "$T/sourced" ]'
printf "SENTRY_MK_API_TOKEN='%s'\n" "$MK_TOK-single" > "$H/env/project-6-os.env"
run -- "URIError" project-6-os
check "L5 single-quoted form read [$(auth)]" '[ "$(auth)" = "Authorization: Bearer $MK_TOK-single" ]'
run SENTRY_MK_API_TOKEN="$MK_TOK" -- "URIError" project-6-os
check "L5 the process env wins over the file" '[ "$(auth)" = "Authorization: Bearer $MK_TOK" ]'
rm -f "$H/env/project-6-os.env"

# ── L6: an invalid row ──────────────────────────────────────────────────────
mkdir -p "$T/src"
jq -nc '{project: "alpha", sentry: {org: "example-org", project: "alpha", token_env: "SENTRY_ALPHA_TOKEN"}}' > "$T/src/beta.json"
jq -nc '{project: "gamma", sentry: {org: "bad/org", project: "gamma", token_env: "SENTRY_GAMMA_TOKEN"}}' > "$T/src/gamma.json"
run SIGNAL_SOURCES_DIR="$T/src" SENTRY_API_TOKEN="$GL_TOK" SENTRY_ALPHA_TOKEN=alpha-fixture -- "x" beta
check "L6 project/file mismatch: one notice [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "(sentry lookup unavailable — bad signal source row for beta)" ] && [ "$(cat "$T/rc")" = 0 ]'
check "L6 project/file mismatch: no call" '[ "$(calls)" = 0 ]'
run SIGNAL_SOURCES_DIR="$T/src" SENTRY_API_TOKEN="$GL_TOK" SENTRY_GAMMA_TOKEN=gamma-fixture -- "x" gamma
check "L6 an org with a slash: one notice, no call" '[ "$(cat "$T/out")" = "(sentry lookup unavailable — bad signal source row for gamma)" ] && [ "$(calls)" = 0 ]'
check "L6 the stderr notice names the field, not a value" 'grep -q "org" "$T/err" && ! grep -q "gamma-fixture" "$T/err"'
# SIGNAL_SOURCES_DIR is a sandbox seam only.
env -u SENTRY_MK_API_TOKEN HARNESS="$H" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=0 SIGNAL_SOURCES_DIR="$T/src" \
  SENTRY_API_TOKEN="$GL_TOK" bash "$H/bin/sentry-lookup.sh" x beta > "$T/out" 2>&1
check "L6 outside the sandbox the seam is ignored (beta has no real row: global path)" '[[ "$(url)" == */organizations/operator/* ]]'

# ── L7: the token never reaches stdout or stderr; titles are masked ─────────
STOK="sn""tryu_fixture$(printf 'a%.0s' $(seq 1 40))"
jq -nc --arg t "leaked $STOK here" '[{shortId: "project-6-os-25", count: "3", lastSeen: "2026-11-17T10:00:00Z", title: $t, permalink: "https://sentry.example.com/issues/25/"}]' > "$FX/answer.json"
run SENTRY_MK_API_TOKEN="$MK_TOK" -- "URIError" project-6-os
ALL="$(cat "$T/out" "$T/err")"
check "L7 the project token is not printed" '! grep -qF "$MK_TOK" <<<"$ALL"'
check "L7 a token-shaped title is masked [$(cat "$T/out")]" 'grep -qF "leaked <redacted:sentry-token> here" <<<"$ALL" && ! grep -qF "$STOK" <<<"$ALL"'

# ── R: the registry ─────────────────────────────────────────────────────────
ROW="$DIR/catalog/signal-sources.d/project-6-os.json"
check "R the seed row: project-6-llc / project-6-os / SENTRY_MK_API_TOKEN" \
  '[ "$(jq -r "[.project, .sentry.org, .sentry.project, .sentry.token_env] | join(\" \")" "$ROW" 2>/dev/null)" = "project-6-os project-6-llc project-6-os SENTRY_MK_API_TOKEN" ]'
check "R no value-shaped string in the registry" '! grep -qE "sn""try[a-z]_|p""h[a-z]_" "$ROW"'

echo "sentry-lookup-project: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
